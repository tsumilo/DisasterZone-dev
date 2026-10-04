if DisasterZoneBoot and DisasterZoneBoot.Run("Core/GroupRules.lua", ...) then return end -- DisasterZone: Core/GroupRules.lua
-- Leader-controlled group loot rules (Addendum D §24-§26 as amended by Addendum E §32/§33). The group's
-- loot authority shares its roll duration, drop quality threshold, dungeon mode switch + 5-man quality and
-- the phase for the group (GS on RAID / PARTY); everyone else reads those values through
-- ns.DB:GetEffective(path) while they are active.
--
-- The authority is computed locally on every client from the live roster and the council lists:
--   raid:  the raid leader; else the master looter; else (1.3) a raid assistant who has the raid log (the raid
--          leaders list, the GM, the guild council), alphabetically. A player outside my guild (a pug) never runs
--          our session: a pug raid leader or master looter counts as one without DisasterZone. (The guild check
--          applies once my guild roster is known and another raid member is in my guild; a pug with DisasterZone
--          among us can't tell, so it keeps the old rule.)
--   party: the party leader if council (GM / guild list) or if they turned dungeon mode on; else a guild
--          council member in the party (lowest guild rank index, then name).
-- Only members known to run a DisasterZone with group rules count (they sent GS or GQ this group session); I
-- always count for myself. The first eligible member who does is the authority.
--
-- Like Util and Dungeon this file is not a lifecycle module (it loads before DB, so it must not shift the
-- module order): it wires itself with ns:RegisterEvent / ns:On and registers its Comm handlers at load.
--
-- Addendum F §38: the raid's authority can lock the BiS lists (GS lk = true, lkAt = its server time when
-- locked; raids only). While locked, BiS refuses edits and council clients watch incoming lists (Store). The
-- lock ends on unlock, when the group disbands or when the authority changes (its rules are cleared).
-- BIS_LOCK_CHANGED(locked) fires whenever GroupRules:IsLocked() changes.
-- 1.3: the lock needs a running raid session with the loot council, and it is that session's lock feature (one
-- truth: the lock button, /dz lock and the raid's Options all change both). Ending the raid or turning the loot
-- council off unlocks; receivers count a lock only with such a session, as the authority's own client does.
--
-- Addendum I §48: the authority can run a raid session (GS rs = session id, rsAt = its start time; raids only).
-- Starting one also locks the BiS lists, ending it unlocks them. Unlike a bare lock, a running session survives a
-- change of authority: the new authority adopts the session (and its lock) it saw from the old one, so control
-- follows the group. RaidLog (Core/RaidLog.lua) records the session.
--
-- Raid features (1.2): in a raid, loot distribution (drops, the council's views, votes, awards) and rolls are OFF
-- until the authority starts a raid session, and the session says which of them it runs (GS rf: the letters l =
-- loot distribution, r = rolls, k = lock the BiS lists; "-" = none). Every module asks GroupRules:IsFeatureOn(name).
-- A session without rf (a raid leader on 1.1 or older) runs everything, as it did then. Parties (dungeon mode),
-- test drops and demo mode are not affected.
--
-- Asking the raid (1.3): WoW writes saved data only on a /reload or a logout, so after a game crash the authority's
-- saved session can be missing or out of date, while the raiders still remember the last GS. An authority that loaded
-- (logged in or reloaded) inside the raid and has not seen the session from anyone first asks the raid (GSQ); each
-- raider answers (GSA) with the session, its features and the lock it last knew, or that none runs, and stays quiet
-- once two others said the same. Two agreeing answers, and more than any other answer got, win over my saved copy;
-- otherwise the saved copy stands, as before. My GS waits for the answers (ASK_WINDOW), so the raid keeps the rules it
-- had (and checks incoming drops and rolls against them) while my client runs on its saved copy. A change I make myself
-- in the meantime ends the question: my choice stands.
local addonName, ns = ...

local GroupRules = {}
ns.GroupRules = GroupRules
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, pcall = type, pairs, ipairs, tonumber, tostring, pcall
local floor, min, abs, random = math.floor, math.min, math.abs, math.random
local tsort, tconcat = table.sort, table.concat

local VALID_DURATIONS = { [15] = true, [20] = true, [30] = true, [45] = true, [60] = true }
local DURATION_STEPS = { 15, 20, 30, 45, 60 }
local FIELD_BY_PATH = {
    ["roll.duration"] = "rd", qualityThreshold = "q", ["dungeon.enabled"] = "dm", ["dungeon.quality"] = "dq",
    phase = "ph",
}
-- Settings whose change the authority shares (the parents too: a whole table may be written at once).
local SHARED_SETTINGS = {
    roll = true, ["roll.duration"] = true, qualityThreshold = true, dungeon = true, ["dungeon.enabled"] = true,
    ["dungeon.quality"] = true, groupPhase = true,
}
local QUALITY_WORDS = { [3] = "rares", [4] = "epics" }
local PARTY_UNITS = { "player", "party1", "party2", "party3", "party4" }

local SEND_INTERVAL = 5        -- at most one GS per 5 s (changes in between are coalesced)
local ANNOUNCE_DELAY = 3       -- GS after becoming the authority (debounced)
local FALLTHROUGH_DELAY = 7    -- ... when a higher-priority eligible member might still answer
local QUERY_DELAY = 3          -- GQ after joining a group / a reload inside one
local EVAL_DELAY = 0.5         -- re-evaluation after roster / loot method / council changes
local MAX_RULES_REV = 2147483647
local MAX_LOCK_AGE = 12 * 3600 -- a saved lock older than this is not restored after a /reload
local LOCK_ANNOUNCE = "DisasterZone: BiS lists are locked for this raid."
local MAX_SESSION_ID = 64
local ASK_WINDOW = 2.5         -- an authority asking the raid which session runs collects answers this long
local ASK_AGREE = 2            -- answers that must agree before they win over my saved session
local ASK_REPLY_MIN, ASK_REPLY_MAX = 0.2, 1.6   -- a raider's random delay before it answers (spread out, so most
                                                -- hear two agreeing answers first and stay quiet)
local ASK_RATE = 10            -- a raider answers one asker at most once per 10 s
local LOGIN_GRACE = 2          -- a group the game shows me in this soon after loading was there before (login /
                               -- reload inside it); a group I join later is a new one
local PLAN_WAIT = 8            -- a raid log member's relink request (GSP) is back in the authority's GS by then

---------------------------------------------------------------------------
-- State (one "group session" = from joining a group until leaving it)
---------------------------------------------------------------------------

local active                   -- { from=, rev=, values={rd,q,dq,dm,ph}, at= } rules received from the authority
local speaks = {}              -- [key] = true: sent GS / GQ this group session (runs DisasterZone with group rules)
local leaderDM = {}            -- [key] = true: this party leader's GS said dungeon mode is on
local printed = {}             -- [key] = true: "loot rules set by" printed this group session
local groupKind                -- "raid" | "party" | nil (no group session)
local wasAuthority = false
local rulesRev = 0
local lastSendAt = -100
local sendTimerPending = false
local lastSig
local memo                     -- { t = GetTime(), auth=, pos=, list= }
local setupDone = false
local myLock                   -- { at = serverTime } while I am the raid's authority and locked the lists
local lastLocked = false       -- GroupRules:IsLocked() as last announced with BIS_LOCK_CHANGED
local mySession                -- { id=, at=, f= } while I am the raid's authority and run a raid session (Addendum I);
                               -- f = its features { loot=, rolls=, lock= } (nil: a session adopted without them = all)
local seenSession              -- { id=, at=, by=, lkAt= } the session last seen from any authority in this raid
local ask                      -- asking the raid which session runs: nil = not yet this group session, false = done,
                               -- { votes = { [sig] = { n=, a= answer } }, from = { [key] = true } } while waiting
local heard = {}               -- [asker] = { [sig] = n }: GSA answers I heard for a GSQ I mean to answer
local loadedAt                 -- GetTime() of my first PLAYER_ENTERING_WORLD (a login or a /reload)
local loadedInGroup = false    -- I was in a group when I loaded (or it showed up within LOGIN_GRACE of it)
local askable = false          -- this group session was already there when I loaded: the raid may know more than me

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Setting(path)
    local DB = ns.DB
    if DB and DB.GetSetting then return DB:GetSetting(path) end
    return nil
end

-- Raid features on the wire: "lrk" letters, "-" when none is on.
local FEATURE_LETTER = { loot = "l", rolls = "r", lock = "k" }
local FEATURE_ORDER = { "loot", "rolls", "lock" }

local function EncodeFeatures(f)
    if type(f) ~= "table" then return nil end
    local s = ""
    for _, name in ipairs(FEATURE_ORDER) do
        if f[name] then s = s .. FEATURE_LETTER[name] end
    end
    return s == "" and "-" or s
end

local function DecodeFeatures(rf)
    if type(rf) ~= "string" then return nil end
    local f = {}
    for _, name in ipairs(FEATURE_ORDER) do
        f[name] = rf:find(FEATURE_LETTER[name], 1, true) ~= nil
    end
    return f
end

-- features from the UI ({ loot=, rolls=, lock= }; nil = everything on) as a clean table. 1.3: the lock needs the loot
-- council.
local function CleanFeatures(features)
    local f = {}
    for _, name in ipairs(FEATURE_ORDER) do
        f[name] = type(features) ~= "table" or features[name] ~= false
    end
    if not f.loot then f.lock = false end
    return f
end

-- The session's features run the loot council (nil: a session from 1.1 or older, which runs everything).
local function LootCouncilIn(f)
    return f == nil or f.loot == true
end

-- The features of my session survive my own /reload: ns.db.groupFeatures = { id = session id, rf = letters }.
local function SaveFeatures()
    local db = ns.db
    if type(db) ~= "table" then return end
    if mySession and mySession.f then
        db.groupFeatures = { id = mySession.id, rf = EncodeFeatures(mySession.f) }
    else
        db.groupFeatures = nil
    end
end

local function SavedFeatures(id)
    local db = ns.db
    local s = type(db) == "table" and db.groupFeatures
    if type(s) == "table" and s.id == id then return DecodeFeatures(s.rf) end
    return nil
end

local function ValidPhase(p)
    local maxP = ns.MAX_PHASE or 5
    if type(p) == "number" and p == floor(p) and p >= 1 and p <= maxP then return p end
    return nil
end

-- A planned raid's occurrence id (Addendum J §61).
local function ValidPlanId(occId)
    return type(occId) == "string" and #occId <= 40 and occId:find("^[%w#]+$") ~= nil
end

local function SnapDuration(d)
    d = tonumber(d) or 30
    local best, bestDiff = 30, math.huge
    for _, s in ipairs(DURATION_STEPS) do
        local diff = abs(s - d)
        if diff < bestDiff then best, bestDiff = s, diff end
    end
    return best
end

local function Quality34(q, default)
    q = tonumber(q) or default
    if q <= 3 then return 3 end
    return 4
end

local function Channel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- A received GS / GQ distribution matches my group (PARTY inside a raid is only a subgroup).
local function GroupDist(dist)
    if dist == "RAID" then return IsInRaid() and true or false end
    if dist == "PARTY" then return (IsInGroup() and not IsInRaid()) and true or false end
    return false
end

local function IsGuildCouncil(key)
    local G = ns.Guild
    if not G then return false end
    if G.IsGuildCouncil then return G:IsGuildCouncil(key) and true or false end
    return (G.IsCouncil and G:IsCouncil(key, true)) and true or false
end

local function RankIndex(key)
    local G = ns.Guild
    local m = G and G.GetMember and G:GetMember(key, true)
    return m and tonumber(m.rankIndex) or 99
end

-- The party leader turned dungeon mode on for the group: my own switch, their GS, or (older clients)
-- their DM.
local function LeaderDungeonOn(key)
    if Util.IsMe(key) then return Setting("dungeon.enabled") == true end
    if leaderDM[key] then return true end
    local D = ns.Dungeon
    return type(D) == "table" and D.groupEnabledBy == key
end

local function CouncilOrder(a, b)
    local ra, rb = RankIndex(a), RankIndex(b)
    if ra ~= rb then return ra < rb end
    return a < b
end

-- 1.3: is this raid one of my guild's (the guild check of the raid's authority applies)? My guild roster is known and
-- another raid member is in my guild. A pug with DisasterZone (or the guild's only member here) can't tell who is a pug.
local function GuildRaid(members)
    local G = ns.Guild
    if not (G and G.IsReady and G.IsInGuild and IsInGuild() and G:IsReady()) then return false end
    for _, key in ipairs(members) do
        if not Util.IsMe(key) and G:IsInGuild(key, true) then return true end
    end
    return false
end

-- Eligible members in priority order, from live roster data.
local function Candidates()
    local list = {}
    if IsInRaid() then
        local leader, ml
        local assists, members = {}, {}
        local n = min(tonumber(GetNumGroupMembers()) or 0, 40)
        for i = 1, n do
            local name, rank, _, _, _, _, _, _, _, _, isML = GetRaidRosterInfo(i)
            if type(name) == "string" and name ~= "" and name ~= UNKNOWNOBJECT then
                local key = Util.NormalizeName(name)
                members[#members + 1] = key
                if rank == 2 then leader = key elseif rank == 1 then assists[#assists + 1] = key end
                if isML then ml = key end
            end
        end
        local G = ns.Guild
        local guildRaid = GuildRaid(members)
        -- a pug (not in my guild) never runs our session: as if they had no DisasterZone
        if leader and guildRaid and not G:IsInGuild(leader, true) then leader = nil end
        if ml and guildRaid and not G:IsInGuild(ml, true) then ml = nil end
        if leader then list[1] = leader end
        if ml and ml ~= leader then list[#list + 1] = ml end
        if guildRaid and G.IsRaidLogMember then
            -- 1.3: neither runs DisasterZone (a pug-led raid): a raid assistant of the guild with the raid log (raid
            -- leaders list, GM, guild council), alphabetically; the same order on every client
            local extra = {}
            for _, key in ipairs(assists) do
                if key ~= ml and G:IsInGuild(key, true) and G:IsRaidLogMember(key) then extra[#extra + 1] = key end
            end
            tsort(extra)
            for _, key in ipairs(extra) do list[#list + 1] = key end
        end
    elseif IsInGroup() then
        local leader
        local council = {}
        for _, unit in ipairs(PARTY_UNITS) do
            if UnitExists(unit) then
                local key = Util.UnitKey(unit)
                if key then
                    if UnitIsGroupLeader(unit) then leader = key end
                    if IsGuildCouncil(key) then council[#council + 1] = key end
                end
            end
        end
        if leader and (IsGuildCouncil(leader) or LeaderDungeonOn(leader)) then list[1] = leader end
        tsort(council, CouncilOrder)
        for _, key in ipairs(council) do
            if key ~= leader then list[#list + 1] = key end
        end
    end
    return list
end

local function Invalidate()
    memo = nil
end

-- authority key, its position in the candidate list, the list. Memoized per frame (GetTime()).
local function Resolve()
    local now = GetTime()
    if memo and memo.t == now then return memo.auth, memo.pos, memo.list end
    local list = Candidates()
    local auth, pos
    for i, key in ipairs(list) do
        if Util.IsMe(key) or speaks[key] then
            auth, pos = key, i
            break
        end
    end
    memo = { t = now, auth = auth, pos = pos, list = list }
    return auth, pos, list
end

local function PositionOf(list, key)
    for i, k in ipairs(list) do
        if k == key then return i end
    end
    return nil
end

local function AmAuthority()
    if not IsInGroup() then return false end
    local auth = Resolve()
    return auth ~= nil and Util.IsMe(auth)
end

local function Describe(v)
    local parts = { "rolls " .. tostring(v.rd) .. "s", (QUALITY_WORDS[v.q] or tostring(v.q)) .. "+" }
    if v.dm == true then
        parts[#parts + 1] = "dungeon mode on, " .. (QUALITY_WORDS[v.dq] or tostring(v.dq)) .. "+"
    elseif v.dm == false then
        parts[#parts + 1] = "dungeon mode off"
    end
    if v.ph then parts[#parts + 1] = "phase " .. tostring(v.ph) end
    return tconcat(parts, ", ")
end

-- My values as the group's rules (clamped to what receivers accept).
local function MyValues()
    local v = {
        rd = SnapDuration(Setting("roll.duration")),
        q = Quality34(Setting("qualityThreshold"), 4),
        dq = Quality34(Setting("dungeon.quality"), 3),
        ph = ValidPhase(Setting("groupPhase")),
    }
    if not IsInRaid() then
        v.dm = Setting("dungeon.enabled") == true   -- dungeon mode: parties only
    else
        if myLock then
            v.lk = true                             -- Addendum F §38: BiS lists locked (raids only)
            v.lkAt = myLock.at
        end
        if mySession then
            v.rs = mySession.id                     -- Addendum I §48: raid session
            v.rsAt = mySession.at
            v.rf = EncodeFeatures(mySession.f)      -- its features (nil: all, as before 1.2)
            if mySession.rpAt then
                v.rp = mySession.rp                 -- Addendum J §61: the planned raid it is linked to (1.3: rpAt
                v.rpAt = mySession.rpAt             -- without rp = unlinked on purpose; older clients drop it)
            end
        end
    end
    return v
end

-- The optional lock and raid session fields of a GS (or of a GSA, the raid's answer which session runs) as
-- { lk, lkAt, rs, rsAt, rp, rpAt, rf }. A malformed field is dropped rather than rejecting the message.
local function ValidateSessionFields(msg)
    local lk = (msg.lk == true) or nil
    local lkAt = msg.lkAt
    if not (lk and type(lkAt) == "number" and lkAt == floor(lkAt) and lkAt > 0 and lkAt <= MAX_RULES_REV) then
        lkAt = nil
    end
    -- Addendum I §48: the raid session is optional too; a malformed one is dropped.
    local rs, rsAt = msg.rs, msg.rsAt
    if not (type(rs) == "string" and rs ~= "" and #rs <= MAX_SESSION_ID and not rs:find("[%c|]")
            and type(rsAt) == "number" and rsAt == floor(rsAt) and rsAt > 0 and rsAt <= MAX_RULES_REV) then
        rs, rsAt = nil, nil
    end
    -- Addendum J §61: the planned raid the session is linked to (optional; needs a session). 1.3: rpAt alone = the
    -- session was unlinked on purpose at that time.
    local rp, rpAt = msg.rp, msg.rpAt
    if not (rs and (rp == nil or ValidPlanId(rp))
            and type(rpAt) == "number" and rpAt == floor(rpAt) and rpAt > 0 and rpAt <= MAX_RULES_REV) then
        rp, rpAt = nil, nil
    end
    -- The session's features (optional; needs a session): letters of "lrk", or "-".
    local rf = msg.rf
    if not (rs and type(rf) == "string" and #rf >= 1 and #rf <= 8 and rf:find("^[lrk%-]+$")) then rf = nil end
    return { lk = lk, lkAt = lkAt, rs = rs, rsAt = rsAt, rp = rp, rpAt = rpAt, rf = rf }
end

-- values, rev of a well-formed GS; nil when any field is out of range. The lock fields (Addendum F) are
-- optional: a malformed lk / lkAt is dropped rather than rejecting the rules.
local function ValidateRules(msg)
    if type(msg) ~= "table" then return nil end
    local rd, q, dq, dm, ph, rev = msg.rd, msg.q, msg.dq, msg.dm, msg.ph, msg.v
    if type(rd) ~= "number" or not VALID_DURATIONS[rd] then return nil end
    if q ~= 3 and q ~= 4 then return nil end
    if dq ~= 3 and dq ~= 4 then return nil end
    if dm ~= nil and dm ~= true and dm ~= false then return nil end
    if ph ~= nil and not ValidPhase(ph) then return nil end
    if rev ~= nil and not (type(rev) == "number" and rev == floor(rev) and rev >= 0 and rev <= MAX_RULES_REV) then
        return nil
    end
    local v = ValidateSessionFields(msg)
    v.rd, v.q, v.dq, v.dm, v.ph = rd, q, dq, dm, ph
    return v, rev
end

---------------------------------------------------------------------------
-- Lock persistence (Addendum F §38): the authority's lock survives its own /reload
---------------------------------------------------------------------------

-- ns.db.groupLock = { by = my key, at = serverTime } while I hold a lock; nil otherwise.
local function SaveLock()
    local db = ns.db
    if type(db) ~= "table" then return end
    if myLock then
        db.groupLock = { by = Util.PlayerKey(), at = myLock.at }
    else
        db.groupLock = nil
    end
end

-- The saved lock time when it is mine and recent, else nil.
local function SavedLockAt()
    local db = ns.db
    local s = type(db) == "table" and db.groupLock
    if type(s) ~= "table" or type(s.at) ~= "number" or not Util.IsMe(s.by) then return nil end
    local now = GetServerTime()
    if s.at > now + 300 or now - s.at > MAX_LOCK_AGE then return nil end
    return s.at
end

local function DropLock()
    if myLock then myLock = nil end
    SaveLock()
end

-- 1.3: my lock and my session's lock feature are one truth, and the lock needs the session's loot council: no session
-- (or no loot council) means no lock. A session adopted without features (1.1 or older) keeps the lock as it is.
local function SyncLock()
    if myLock and not (mySession and LootCouncilIn(mySession.f)) then myLock = nil end
    if mySession and mySession.f then mySession.f.lock = myLock ~= nil end
end

---------------------------------------------------------------------------
-- Change notification
---------------------------------------------------------------------------

local function StatusSignature()
    local status, from = GroupRules:GetStatus()
    local parts = { status, tostring(from) }
    if status == "remote" and active then
        local v = active.values
        parts[#parts + 1] = tconcat({ tostring(v.rd), tostring(v.q), tostring(v.dq), tostring(v.dm), tostring(v.ph) }, ",")
    elseif status == "mine" then
        parts[#parts + 1] = tostring(Setting("groupPhase"))
    end
    local auth = IsInGroup() and Resolve() or nil
    parts[#parts + 1] = tostring(auth)
    parts[#parts + 1] = tostring(GroupRules:IsLocked())
    local sess = GroupRules:GetSession()
    parts[#parts + 1] = sess and sess.id or "-"
    parts[#parts + 1] = sess and (tostring(sess.rp) .. "@" .. tostring(sess.rpAt)) or "-"   -- Addendum J §61 link
    parts[#parts + 1] = sess and (EncodeFeatures(sess.f) or "all") or "-"
    return tconcat(parts, "|")
end

-- BIS_LOCK_CHANGED(locked) + a chat line whenever the effective lock changes.
local function CheckLock()
    local locked = GroupRules:IsLocked()
    if locked == lastLocked then return end
    lastLocked = locked
    if locked then
        local info = GroupRules:GetLockInfo()
        local by = info and info.by
        if by and Util.IsMe(by) then
            ns:Print("you locked the BiS lists for this raid (/dz unlock to undo).")
        else
            ns:Print("BiS lists are locked by %s for this raid.", by and Util.ShortName(by) or "the raid leader")
        end
    else
        ns:Print("BiS lists are unlocked.")
    end
    ns:Fire("BIS_LOCK_CHANGED", locked)
end

-- Remembers the session the authority runs (for adoption by a later authority); forgets it when the authority
-- ends it.
local function TrackSession()
    if not IsInRaid() then
        seenSession = nil
        return
    end
    if GroupRules:GetStatus() == "own" then return end   -- no authority rules right now: nothing to learn
    local s = GroupRules:GetSession()
    if s then
        local lock = GroupRules:GetLockInfo()
        seenSession = { id = s.id, at = s.at, by = s.by, lkAt = lock and lock.at or nil, rp = s.rp, rpAt = s.rpAt,
                        f = s.f }
    else
        seenSession = nil
    end
end

local function Changed()
    TrackSession()
    local sig = StatusSignature()
    if sig ~= lastSig then
        lastSig = sig
        ns:Fire("GROUP_RULES_CHANGED")
    end
    CheckLock()
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

-- final: send although I am no longer the authority (I just gave it up; the group must drop my rules).
local function DoSend(final)
    local ch = Channel()
    local Comm = ns.Comm
    if not ch or not (Comm and Comm.Send) then return false end
    if not final and not AmAuthority() then return false end
    if not final and type(ask) == "table" then return false end   -- asking the raid: my GS waits for its answers
    rulesRev = rulesRev + 1
    local msg = MyValues()
    msg.t = "GS"
    msg.v = rulesRev
    local ok = Comm:Send(msg, ch, nil, "alert") and true or false
    if ok then lastSendAt = GetTime() end
    return ok
end

-- At most one GS per 5 s; changes in between go out together at the next slot.
local function SendRules()
    if sendTimerPending then return end
    local wait = lastSendAt + SEND_INTERVAL - GetTime()
    if wait <= 0 then
        DoSend(false)
        return
    end
    sendTimerPending = true
    Util.After(wait, function()
        sendTimerPending = false
        DoSend(false)
    end)
end

local function SendQuery()
    local ch = Channel()
    local Comm = ns.Comm
    if ch and Comm and Comm.Send then Comm:Send({ t = "GQ" }, ch, nil, "alert") end
end

---------------------------------------------------------------------------
-- Asking the raid which session runs (1.3: GSQ / GSA)
---------------------------------------------------------------------------

-- What an answer says, as one string: two answers agree when it is the same.
local function AnswerSig(a)
    return tconcat({ a.rs or "-", a.rs and (a.rf or "*") or "", a.lk and "k" or "", a.rp or "" }, "|")
end

-- What I know of the raid's session, as GSA fields; nil when I know nothing (no authority rules, no session seen).
local function MyAnswer()
    if not IsInRaid() then return nil end
    local s, lock
    if GroupRules:GetStatus() ~= "own" then
        s, lock = GroupRules:GetSession(), GroupRules:GetLockInfo()
    elseif seenSession then
        s, lock = seenSession, seenSession.lkAt and { at = seenSession.lkAt } or nil
    else
        return nil
    end
    local m = {}
    if s then m.rs, m.rsAt, m.rf, m.rp, m.rpAt = s.id, s.at, EncodeFeatures(s.f), s.rp, s.rpAt end
    if lock then m.lk, m.lkAt = true, lock.at end
    return m
end

-- My own session and lock as an answer (to tell whether the raid's answer changes anything).
local function MySig()
    return AnswerSig({ rs = mySession and mySession.id, rf = mySession and EncodeFeatures(mySession.f),
                       lk = myLock and true, rp = mySession and mySession.rp })
end

-- The answers are in: two that agree, and more than any other answer got, set my session, its features and the
-- lock; otherwise my saved copy stands. Then my GS goes out.
local function ResolveAsk()
    local a = ask
    if type(a) ~= "table" then return end
    ask = false
    Util.CancelDebounce("cdl-gr-ask")
    if IsInRaid() and AmAuthority() then
        local best, bestN, tie = nil, 0, false
        for _, v in pairs(a.votes) do
            if v.n > bestN then
                best, bestN, tie = v.a, v.n, false
            elseif v.n == bestN then
                tie = true
            end
        end
        if best and bestN >= ASK_AGREE and not tie and AnswerSig(best) ~= MySig() then
            if best.rs then
                mySession = { id = best.rs, at = best.rsAt, rp = best.rp, rpAt = best.rpAt, f = DecodeFeatures(best.rf) }
            else
                mySession = nil
            end
            myLock = best.lk and { at = best.lkAt or (myLock and myLock.at) or GetServerTime() } or nil
            SyncLock()
            SaveLock()
            SaveFeatures()
            if mySession then
                local SB = ns.SessionBar
                local f = mySession.f and CleanFeatures(mySession.f)
                ns:Print("picked up the raid session from what the raid last heard (%s).",
                    (f and SB and SB.DescribeFeatures) and SB:DescribeFeatures(f) or "everything on")
            else
                ns:Print("the raid says its raid session has ended, so it was not resumed.")
            end
        end
        Util.Debounce("cdl-gr-announce", 0.1, function()
            if AmAuthority() then SendRules() end
        end)
    end
    Changed()
end

-- GSQ to the raid; the answers are counted for ASK_WINDOW. Returns false when it could not be sent.
local function StartAsk()
    ask = { votes = {}, from = {} }
    local Comm = ns.Comm
    if not (Comm and Comm.Send and Comm:Send({ t = "GSQ" }, "RAID", nil, "alert")) then
        ask = false
        return false
    end
    Util.Debounce("cdl-gr-ask", ASK_WINDOW, ResolveAsk)
    return true
end

-- A change I make (or another authority's rules) while asking: that stands, the answers no longer matter.
local function EndAsk()
    if type(ask) ~= "table" then return end
    ask = false
    Util.CancelDebounce("cdl-gr-ask")
end

---------------------------------------------------------------------------
-- Evaluation
---------------------------------------------------------------------------

local function ResetSession()
    active = nil
    speaks, leaderDM, printed = {}, {}, {}
    rulesRev = 0
    wasAuthority = false
    groupKind = nil
    mySession, seenSession = nil, nil
    ask, heard, askable, loadedInGroup = nil, {}, false, false
    DropLock()   -- the group is gone: so is its lock
    Util.CancelDebounce("cdl-gr-ask")
    Util.CancelDebounce("cdl-gr-announce")
    Util.CancelDebounce("cdl-gr-query")
    Util.CancelDebounce("cdl-gr-reply")
    Invalidate()
end

local function Evaluate()
    if not ns.loggedIn then return end
    Invalidate()
    if not IsInGroup() then
        if groupKind then ResetSession() end
        DropLock()   -- (also a lock saved before logging out of a group that is gone now)
        Changed()
        return
    end
    local kind = IsInRaid() and "raid" or "party"
    local joined = groupKind == nil
    local kindChanged = groupKind ~= nil and groupKind ~= kind
    groupKind = kind
    if joined then askable = loadedInGroup end
    if kindChanged then askable = false end   -- a raid that was a party a moment ago runs no session
    local auth, pos, list = Resolve()
    local mine = auth ~= nil and Util.IsMe(auth)
    if mine and kind == "raid" then
        -- 1.3: I loaded inside this raid and have not seen its session from anyone: ask the raid which one runs, my
        -- saved copy may be out of date after a game crash. The saved copy below stands in meanwhile.
        if askable and ask == nil and not seenSession and not mySession then StartAsk() end
        -- Addendum F §38: my lock from before a /reload inside this raid.
        if not myLock then
            local at = SavedLockAt()
            if at then myLock = { at = at } end
        end
        -- Addendum I §48: a running raid session (and its lock) passes to me as the new authority: the one the
        -- old authority announced, else the one my raid log still has open (after my own /reload).
        if not mySession then
            local adopt = seenSession
            if not adopt then
                local RL = ns.RaidLog
                local open = RL and RL.GetResumable and RL:GetResumable()
                if open then adopt = { id = open.id, at = open.start, rp = open.pl, rpAt = open.plAt } end
            end
            if adopt then
                mySession = { id = adopt.id, at = adopt.at, rp = adopt.rp, rpAt = adopt.rpAt,
                              f = adopt.f or SavedFeatures(adopt.id) }
                SaveFeatures()   -- an adopted session's features must survive my /reload too (else: all on)
                if not myLock and adopt.lkAt then
                    myLock = { at = adopt.lkAt }
                    SaveLock()
                end
            end
        end
        -- 1.3: no session with the loot council, no lock (also a lock saved before a /reload); the lock feature follows
        local hadLock, hadFeature = myLock ~= nil, mySession and mySession.f and mySession.f.lock
        SyncLock()
        if hadLock ~= (myLock ~= nil) then SaveLock() end
        if mySession and mySession.f and hadFeature ~= mySession.f.lock then SaveFeatures() end
    else
        if myLock then
            DropLock()   -- lost the authority, or the raid became a party: the lock ends
        end
        mySession = nil  -- (a raid session carries on with the next authority)
    end
    if mine then
        active = nil
        if not wasAuthority or kindChanged then
            -- Became the authority (or the raid became a party / the party a raid): announce once the
            -- group has settled; wait longer when a higher-priority member might still speak up.
            Util.Debounce("cdl-gr-announce", (pos == 1) and ANNOUNCE_DELAY or FALLTHROUGH_DELAY, function()
                if AmAuthority() then SendRules() end
            end)
        end
    else
        Util.CancelDebounce("cdl-gr-announce")
        if active and not PositionOf(list, active.from) then
            active = nil   -- the source left, lost the lead / master loot, or is no longer council
        end
    end
    wasAuthority = mine
    if joined and not active and not (mine and pos == 1) then
        -- Joined a group (or reloaded inside one): ask the authority for its rules.
        Util.Debounce("cdl-gr-query", QUERY_DELAY + random(), function()
            if not IsInGroup() or active then return end
            local a, p = Resolve()
            if not (a and Util.IsMe(a) and p == 1) then SendQuery() end
        end)
    end
    Changed()
end

local function ScheduleEvaluate()
    Invalidate()
    Util.Debounce("cdl-gr-eval", EVAL_DELAY, Evaluate)
end

---------------------------------------------------------------------------
-- GS {v, rd, q, dq, dm, ph} and GQ (RAID / PARTY, alert)
---------------------------------------------------------------------------

-- Accepted only from the member who is the authority in my view once it is known to speak GS: an
-- eligible member (§24) with a priority at least that of the current authority.
local function OnRules(sender, msg, dist)
    if not GroupDist(dist) or type(sender) ~= "string" then return end
    local values, rev = ValidateRules(msg)
    if not values then
        ns:Debug("GroupRules: invalid GS from %s ignored", sender)
        return
    end
    speaks[sender] = true
    if not IsInRaid() then
        local rank = Util.GetGroupRole and Util.GetGroupRole(sender)
        if rank == 2 then leaderDM[sender] = (values.dm == true) or nil end
    end
    Invalidate()
    local auth, _, list = Resolve()
    if auth ~= sender then
        if active and active.from == sender and not PositionOf(list, sender) then
            -- It gave the authority up (e.g. a party leader who is not council turned dungeon mode off).
            active = nil
            Changed()
            ScheduleEvaluate()
        else
            ns:Debug("GroupRules: GS from %s ignored (not the loot authority)", sender)
        end
        return
    end
    local first = not active or active.from ~= sender
    -- Addendum F §38: a lock only counts in a raid; without lkAt the time it was first seen stands in.
    if values.lk and dist ~= "RAID" then values.lk = nil end
    if values.rs and dist ~= "RAID" then values.rs, values.rsAt = nil, nil end
    if not values.rs then values.rp, values.rpAt = nil, nil end
    if not values.lk then
        values.lkAt = nil
    elseif not values.lkAt then
        local prev = not first and active.values
        values.lkAt = (prev and prev.lk and prev.lkAt) or GetServerTime()
    end
    active = { from = sender, rev = rev or 0, values = values, at = GetTime() }
    wasAuthority = false
    EndAsk()   -- (I asked as a stand-in authority: the raid's authority has spoken)
    if myLock or (ns.db and ns.db.groupLock) then DropLock() end   -- someone else holds the authority now
    Util.CancelDebounce("cdl-gr-announce")
    Util.CancelDebounce("cdl-gr-query")
    if first and not printed[sender] then
        printed[sender] = true
        ns:Print("loot rules set by %s (%s)", Util.ShortName(sender), Describe(values))
    end
    Changed()
end

-- GQ: someone joined / reloaded without rules. The authority answers (throttled to one GS per 5 s).
local replyPending = false
local function OnQuery(sender, _, dist)
    if not GroupDist(dist) or type(sender) ~= "string" then return end
    if not speaks[sender] then
        speaks[sender] = true   -- a GQ proves the sender speaks GS: it may be a higher-priority authority
        ScheduleEvaluate()
    end
    -- Leading-edge: the first query schedules the reply; later ones never postpone it (a stream of GQ from
    -- one member must not keep the authority from ever answering).
    if AmAuthority() and not replyPending then
        replyPending = true
        Util.After(0.3 + random() * 0.5, function()
            replyPending = false
            if AmAuthority() then SendRules() end
        end)
    end
end

-- GSQ (RAID): an authority that has not seen the raid's session asks which one runs. Answered only for the raid
-- leader / master looter, once per asker and ASK_RATE, after a random delay, and not once two others said the same.
local function OnSessionAsk(sender, _, dist)
    if dist ~= "RAID" or not IsInRaid() or type(sender) ~= "string" then return end
    if not speaks[sender] then
        speaks[sender] = true   -- like a GQ: the sender runs DisasterZone with group rules
        ScheduleEvaluate()
    end
    Invalidate()
    local _, _, list = Resolve()
    local Comm = ns.Comm
    if not PositionOf(list, sender) or not (Comm and Comm.Send and Comm.RateLimit) then return end
    if not MyAnswer() or not Comm:RateLimit("gr-ask:" .. sender, ASK_RATE) then return end
    heard[sender] = {}
    Util.After(ASK_REPLY_MIN + random() * (ASK_REPLY_MAX - ASK_REPLY_MIN), function()
        local h = heard[sender]
        heard[sender] = nil
        local m = MyAnswer()
        if not m or (h and h[AnswerSig(m)] or 0) >= ASK_AGREE then return end
        m.t, m.to = "GSA", sender
        Comm:Send(m, "RAID", nil, "alert")
    end)
end

-- GSA (RAID): a raider's answer to someone's GSQ. Everyone counts the answers to a GSQ they mean to answer; the
-- asker counts one answer per raider.
local function OnSessionAnswer(sender, msg, dist)
    if dist ~= "RAID" or not IsInRaid() or type(sender) ~= "string" or type(msg) ~= "table" then return end
    local to = type(msg.to) == "string" and Util.NormalizeName(msg.to)
    if not to then return end
    local a = ValidateSessionFields(msg)
    local sig = AnswerSig(a)
    local h = heard[to]
    if h then h[sig] = (h[sig] or 0) + 1 end
    if type(ask) ~= "table" or not Util.IsMe(to) or ask.from[sender] then return end
    ask.from[sender] = true
    local v = ask.votes[sig]
    if not v then
        v = { n = 0, a = a }
        ask.votes[sig] = v
    end
    v.n = v.n + 1
end

-- GSP {rs, rp} (whisper, 1.3): a raid log member asks me, the raid's authority, to link the running session to
-- another planned raid (no rp: unlink it). Checked with real roles: the sender has the raid log (the raid leaders list,
-- the GM, the guild council) and is in my raid.
local function OnPlanRequest(sender, msg, dist)
    if dist ~= "WHISPER" or type(sender) ~= "string" or type(msg) ~= "table" or not IsInRaid() then return end
    Invalidate()
    if not AmAuthority() or not mySession or msg.rs ~= mySession.id then return end
    local rp = msg.rp
    if rp ~= nil and not ValidPlanId(rp) then return end
    local G = ns.Guild
    if not Util.GetGroupRole(sender) or not (G and G.IsRaidLogMember and G:IsRaidLogMember(sender)) then
        ns:Debug("GroupRules: planned raid request from %s ignored", sender)
        return
    end
    local Comm = ns.Comm
    if Comm and Comm.RateLimit and not Comm:RateLimit("gr-plan:" .. sender, 2) then return end
    if mySession.rp == rp and (rp ~= nil or mySession.rpAt) then return end
    if not GroupRules:SetSessionPlan(rp) then return end
    local RP = ns.RaidPlan
    local v = rp and RP and RP.GetRaid and RP:GetRaid(rp)
    if rp then
        ns:Print("%s linked this raid to the planned raid %s.", Util.ShortName(sender),
            v and (RP:GetRaidName(v) .. " (" .. date("%a %d %b %H:%M", v.t) .. ")") or "?")
    else
        ns:Print("%s unlinked this raid from its planned raid.", Util.ShortName(sender))
    end
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

local function OnSettingChanged(path)
    if type(path) ~= "string" or not SHARED_SETTINGS[path] then return end
    Invalidate()
    if IsInGroup() then
        if AmAuthority() then
            SendRules()
            wasAuthority = true   -- this GS is the announcement
        elseif wasAuthority and (path == "dungeon" or path == "dungeon.enabled") then
            -- I just gave the authority up (a party leader who is not council turned dungeon mode off):
            -- tell the group once so it drops my rules.
            DoSend(true)
            wasAuthority = false
        end
        ScheduleEvaluate()
    end
    Changed()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- The group's loot authority (key), or nil when there is none / I am not in a group.
function GroupRules:GetAuthority()
    if not IsInGroup() then return nil end
    return (Resolve())
end

-- I am the authority: my own values are the group's rules.
function GroupRules:IsAuthority()
    return AmAuthority()
end

-- The rules received from the authority (a copy { from, rev, values = {rd, q, dq, dm, ph, lk, lkAt}, at }),
-- or nil.
function GroupRules:GetActive()
    if not active or not IsInGroup() then return nil end
    local v = active.values
    return { from = active.from, rev = active.rev, at = active.at,
        values = { rd = v.rd, q = v.q, dq = v.dq, dm = v.dm, ph = v.ph, lk = v.lk, lkAt = v.lkAt, rs = v.rs,
            rsAt = v.rsAt, rp = v.rp, rpAt = v.rpAt } }
end

---------------------------------------------------------------------------
-- BiS list lock (Addendum F §38)
---------------------------------------------------------------------------

-- The authority's rules lock the lists: 1.3: only with its running session's loot council (as its own client
-- enforces; a lock from an older raid leader without one doesn't count).
local function RemoteLocked()
    local v = active and active.values
    if not (v and v.lk == true and v.rs) then return false end
    return LootCouncilIn(DecodeFeatures(v.rf))
end

-- The raid's BiS lists are locked (by me as the authority, or by the authority's rules). Raids only.
function GroupRules:IsLocked()
    if not IsInRaid() then return false end
    if AmAuthority() then return myLock ~= nil end
    return RemoteLocked()
end

-- 1.3: may I lock the raid's BiS lists now? The raid's loot authority in a running raid session with the loot council
-- (a lock I hold can always be undone). Returns ok, reason.
function GroupRules:CanLock()
    if not IsInRaid() then return false, "BiS lists can only be locked in a raid." end
    if not AmAuthority() then
        return false, "only the raid leader (the raid's loot authority) can lock or unlock BiS lists."
    end
    if myLock then return true end
    if not mySession then
        return false, "BiS lists can only be locked while the raid runs: start the raid (with the loot council) first."
    end
    if not LootCouncilIn(mySession.f) then
        return false, "the BiS lock needs the loot council: turn it on in the raid's Options first."
    end
    return true
end

-- 1.3: the raid's loot council runs: a raid session with the loot council (a session from 1.1 or older runs
-- everything). Raids only. The BiS lock and the raid-scope council's copies of the raiders' BiS lists need it.
function GroupRules:IsLootCouncilOn()
    if not IsInRaid() then return false end
    local s = self:GetSession()
    return s ~= nil and LootCouncilIn(s.f)
end

-- { by = key, at = serverTime } of the current lock, or nil.
function GroupRules:GetLockInfo()
    if not self:IsLocked() then return nil end
    if AmAuthority() then return { by = Util.PlayerKey(), at = myLock.at } end
    return { by = active.from, at = active.values.lkAt }
end

-- Locks / unlocks the raid's BiS lists. Only the raid's loot authority (the raid leader, else the master
-- looter; §33) can: returns ok, err. The GS goes out at once (a deliberate toggle, not a settings burst:
-- raiders must learn the lock before they could edit); locking also posts one raid chat line when roll
-- announcements are on. 1.3: locking needs a running raid session with the loot council (CanLock), and the
-- session's lock feature follows (the raid's Options show it).
function GroupRules:SetLocked(locked)
    locked = locked and true or false
    if not IsInRaid() then return false, "BiS lists can only be locked in a raid." end
    Invalidate()
    if not AmAuthority() then
        return false, "only the raid leader (the raid's loot authority) can lock or unlock BiS lists."
    end
    if locked == (myLock ~= nil) then return true end
    if locked then
        local ok, why = self:CanLock()
        if not ok then return false, why end
    end
    EndAsk()   -- my choice stands over what the raid would answer
    myLock = locked and { at = GetServerTime() } or nil
    SyncLock()
    SaveLock()
    SaveFeatures()
    DoSend(false)
    wasAuthority = true   -- this GS is the announcement
    Changed()
    if locked and Setting("roll.announce") ~= false then
        local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
        if send then pcall(send, LOCK_ANNOUNCE, "RAID") end
    end
    return true
end

---------------------------------------------------------------------------
-- Raid session (Addendum I §48)
---------------------------------------------------------------------------

-- { id, at, by } of the raid session the authority runs, or nil (none, not in a raid, or no authority rules yet).
function GroupRules:GetSession()
    if not IsInRaid() then return nil end
    if AmAuthority() then
        return mySession and { id = mySession.id, at = mySession.at, by = Util.PlayerKey(), rp = mySession.rp,
                               rpAt = mySession.rpAt, f = mySession.f and CleanFeatures(mySession.f) or nil } or nil
    end
    if active and active.values.rs then
        local f = DecodeFeatures(active.values.rf)
        if f then f.lock = RemoteLocked() end   -- 1.3: the lock feature and the lock are one truth
        return { id = active.values.rs, at = active.values.rsAt, by = active.from, rp = active.values.rp,
                 rpAt = active.values.rpAt, f = f }
    end
    return nil
end

-- Is a raid feature running for me: "loot" (the loot council: BiS candidates, the council's views, votes; 1.3: drops
-- also run for "rolls", and handed-out loot is recorded either way) or
-- "rolls"? In a raid only while the authority runs a raid session with that feature (a session that names no
-- features, from a raid leader on 1.1 or older, runs them all). Outside raids always true: parties have dungeon
-- mode, and test drops / demo mode never ask.
-- incoming = true (a drop or a roll somebody in the raid just announced): also true while I don't know the raid's
-- rules yet (the first seconds after joining or a /reload, also when I am only the stand-in authority because the
-- raid leader's addon has not spoken yet): the sender's client checked the feature itself.
function GroupRules:IsFeatureOn(name, incoming)
    if not IsInRaid() then return true end
    if incoming and not active then
        local auth, pos = Resolve()
        if not (auth ~= nil and Util.IsMe(auth) and pos == 1) then return true end
    end
    local s = self:GetSession()
    if not s then return false end
    return s.f == nil or s.f[name] == true
end

-- The features of the running session { loot=, rolls=, lock= } (all true for a session that names none), or nil
-- without a session.
function GroupRules:GetSessionFeatures()
    local s = self:GetSession()
    if not s then return nil end
    return s.f or CleanFeatures(nil)
end

-- Changes the features of the running session (the authority only). Returns ok, err.
function GroupRules:SetSessionFeatures(features)
    if not IsInRaid() then return false, "not in a raid." end
    Invalidate()
    if not AmAuthority() or not mySession then return false, "only the raid leader of a running raid session can." end
    EndAsk()   -- my choice stands over what the raid would answer
    local f = CleanFeatures(features)
    mySession.f = f
    local announce = false
    if f.lock and not myLock then
        myLock = { at = GetServerTime() }
        announce = true
    elseif not f.lock then
        myLock = nil
    end
    SyncLock()
    SaveLock()
    SaveFeatures()
    DoSend(false)
    Changed()
    if announce and Setting("roll.announce") ~= false then
        local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
        if send then pcall(send, LOCK_ANNOUNCE, "RAID") end
    end
    return true
end

-- Addendum J §61: links the running raid session to a planned raid (occurrence id; nil unlinks, which also stops the
-- automatic link). The authority only; the link rides on GS (rp / rpAt), so every raider records the same one.
-- Returns ok, err.
function GroupRules:SetSessionPlan(occId)
    if not IsInRaid() then return false, "not in a raid." end
    Invalidate()
    if not AmAuthority() or not mySession then return false, "only the raid leader of a running raid session can." end
    if occId ~= nil and not ValidPlanId(occId) then return false, "invalid raid" end
    if mySession.rp == occId and (occId ~= nil or mySession.rpAt) then return true end
    EndAsk()   -- my choice stands over what the raid would answer
    mySession.rp, mySession.rpAt = occId, GetServerTime()
    DoSend(false)
    Changed()
    return true
end

-- 1.3: a raid log member (the raid leaders list, the GM, the guild council) in the raid changes the running session's
-- planned raid for the whole raid: the request (GSP, a whisper) goes to the raid's authority, which takes it into the
-- session (GS rp / rpAt), so every raider's raid log, the strategy reminders and the auto guests follow. The authority
-- itself just sets it. Returns ok, err.
function GroupRules:RequestSessionPlan(occId)
    if not IsInRaid() then return false, "not in a raid." end
    Invalidate()
    if AmAuthority() then return self:SetSessionPlan(occId) end
    if occId ~= nil and not ValidPlanId(occId) then return false, "invalid raid" end
    local s = self:GetSession()
    if not (s and s.by) then return false, "no raid session is running." end
    local G = ns.Guild
    if not (G and G.IsRaidLogMember and G:IsRaidLogMember(Util.PlayerKey())) then
        return false, "only the raid leaders and the guild council can change the raid's planned raid."
    end
    local Comm = ns.Comm
    if not (Comm and Comm.Send and Comm:Send({ t = "GSP", rs = s.id, rp = occId }, "WHISPER", s.by, "alert")) then
        return false, "could not reach " .. Util.ShortName(s.by) .. "."
    end
    -- the authority's GS brings the change back; an authority on an older DisasterZone ignores the request
    Util.Debounce("cdl-gr-plan", PLAN_WAIT, function()
        local now = GroupRules:GetSession()
        if now and now.id == s.id and now.rp ~= occId then
            ns:Print("%s's DisasterZone did not take the change (an older version?). They can change it in the Raid log.",
                Util.ShortName(s.by))
        end
    end)
    return true
end

-- Starts (on = true) or ends the raid session. Only the raid's loot authority can: returns ok, err. features
-- (optional): { loot=, rolls=, lock= }, what the session runs (nil: everything). With lock, starting also locks
-- the BiS lists (with the usual raid chat line); ending unlocks them. startAt (optional): an earlier start time (a
-- session started late, e.g. from the boss pull prompt).
function GroupRules:SetSession(on, startAt, features)
    on = on and true or false
    if not IsInRaid() then return false, "a raid session can only run in a raid." end
    Invalidate()
    if not AmAuthority() then
        return false, "only the raid leader (the raid's loot authority) can start or end the raid."
    end
    if on == (mySession ~= nil) then return true end
    EndAsk()   -- my choice stands over what the raid would answer
    local announce = false
    if on then
        local now = GetServerTime()
        local at = tonumber(startAt)
        if not at or at > now or at < now - MAX_LOCK_AGE then at = now end
        at = floor(at)
        mySession = { id = ((Util.PlayerKey() or "?") .. "-" .. at):sub(1, MAX_SESSION_ID), at = at,
                      f = CleanFeatures(features) }
        if mySession.f.lock and not myLock then
            myLock = { at = now }
            announce = true
        elseif not mySession.f.lock then
            myLock = nil
        end
    else
        mySession = nil
        myLock = nil
    end
    SyncLock()
    SaveLock()
    SaveFeatures()
    DoSend(false)
    wasAuthority = true   -- this GS is the announcement
    Changed()
    if announce and Setting("roll.announce") ~= false then
        local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
        if send then pcall(send, LOCK_ANNOUNCE, "RAID") end
    end
    return true
end

-- "own" (my own settings: no group / no authority with DisasterZone), "mine" (I set them for my group) or
-- "remote" (set by fromKey); second return: the source key.
function GroupRules:GetStatus()
    if not IsInGroup() then return "own", nil end
    if AmAuthority() then return "mine", Util.PlayerKey() end
    if active then return "remote", active.from end
    return "own", nil
end

-- For DB:GetEffective: the active group value of a group-rule path ("roll.duration", "qualityThreshold",
-- "dungeon.enabled", "dungeon.quality"), or nil when no rules from someone else apply.
function GroupRules:GetRemoteValue(path)
    local field = FIELD_BY_PATH[path]
    if not field or not active or not IsInGroup() then return nil end
    return active.values[field]
end

-- For DB:GetEffective("phase"): the group's phase (the authority's ph, or my "groupPhase" while I am the
-- authority), or nil (use the guild phase).
function GroupRules:GetRulePhase()
    if not IsInGroup() then return nil end
    if AmAuthority() then return ValidPhase(Setting("groupPhase")) end
    if active then return active.values.ph end
    return nil
end

-- DisasterZone extension: key sent GS / GQ in this group session (runs a DisasterZone with group rules).
function GroupRules:IsSpeaker(key)
    return type(key) == "string" and speaks[key] == true
end

-- DisasterZone extension, called by Dungeon for a DM that passed its gate: the sender switched dungeon mode for
-- the party. A party leader's switch decides their eligibility; from the current rules' source it changes
-- the active dm rule at once.
function GroupRules:OnDungeonSwitch(sender, on, isLeader)
    if type(sender) ~= "string" or IsInRaid() or not IsInGroup() then return end
    on = on and true or false
    if isLeader then leaderDM[sender] = on or nil end
    Invalidate()
    if active and active.from == sender and active.values.dm ~= on then
        active.values.dm = on
        Changed()
    end
    ScheduleEvaluate()
end

---------------------------------------------------------------------------
-- Slash: /dz rules
---------------------------------------------------------------------------

local function SlashRules()
    local status, from = GroupRules:GetStatus()
    local DB = ns.DB
    if not (DB and DB.GetEffective and ns.db) then
        ns:Print("settings are not loaded yet.")
        return
    end
    local src
    if status == "remote" then
        src = "set by " .. Util.ShortName(from) .. " for this group"
    elseif status == "mine" then
        src = "you set these for your group"
    elseif IsInGroup() then
        src = "your own settings (no loot leader with DisasterZone in this group)"
    else
        src = "your own settings (not in a group)"
    end
    local q = tonumber(DB:GetEffective("qualityThreshold")) or 4
    local dq = tonumber(DB:GetEffective("dungeon.quality")) or 3
    local dm = DB:GetEffective("dungeon.enabled") == true
    ns:Print("loot rules: %s.", src)
    ns:Print("  rolls %ss, drops %s+, dungeon mode %s (%s+ in 5-man dungeons), phase %s.",
        tostring(DB:GetEffective("roll.duration")), QUALITY_WORDS[q] or tostring(q), dm and "on" or "off",
        QUALITY_WORDS[dq] or tostring(dq), tostring(DB:GetEffective("phase")))
    local lock = GroupRules:GetLockInfo()
    if lock then
        ns:Print("  BiS lists are locked by %s.", Util.IsMe(lock.by) and "you" or Util.ShortName(lock.by))
    end
end

ns:RegisterSlash("rules", SlashRules, "show the group's loot rules (roll time, quality, dungeon mode, phase) and who set them")

---------------------------------------------------------------------------
-- Slash: /dz lock, /dz unlock (Addendum F §38)
---------------------------------------------------------------------------

local function SlashLock(locked)
    if locked == GroupRules:IsLocked() and (not locked or GroupRules:IsAuthority()) then
        ns:Print(locked and "BiS lists are already locked." or "BiS lists are not locked.")
        return
    end
    local ok, err = GroupRules:SetLocked(locked)
    if not ok then ns:Print("%s", tostring(err)) end
end

ns:RegisterSlash("lock", function() SlashLock(true) end, "lock every raid member's BiS list for this raid (raid leader)")
ns:RegisterSlash("unlock", function() SlashLock(false) end, "unlock the raid's BiS lists (raid leader)")

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

local function Setup()
    if setupDone then return end
    local Comm = ns.Comm
    if not (Comm and Comm.Register) then return end
    setupDone = true
    Comm:Register("GS", OnRules)
    Comm:Register("GQ", OnQuery)
    Comm:Register("GSQ", OnSessionAsk)
    Comm:Register("GSA", OnSessionAnswer)
    Comm:Register("GSP", OnPlanRequest)
end

ns:On("SETTINGS_CHANGED", OnSettingChanged)
ns:On("GROUP_UPDATED", ScheduleEvaluate)
ns:On("CONFIG_UPDATED", ScheduleEvaluate)
ns:On("DUNGEON_MODE_CHANGED", ScheduleEvaluate)
ns:On("ROSTER_UPDATED", ScheduleEvaluate)       -- guild rank order among council members of a party
-- The group I was in when I loaded (shown by the game at once, or within LOGIN_GRACE): set when the game says so,
-- not when the (debounced) evaluation gets to it.
local function NoteLoadGroup()
    if loadedAt and not loadedInGroup and not groupKind and GetTime() - loadedAt <= LOGIN_GRACE and IsInGroup() then
        loadedInGroup = true
    end
end
ns:RegisterEvent("GROUP_ROSTER_UPDATE", function()
    NoteLoadGroup()
    ScheduleEvaluate()
end)
ns:RegisterEvent("PARTY_LEADER_CHANGED", ScheduleEvaluate)
ns:RegisterEvent("PARTY_LOOT_METHOD_CHANGED", ScheduleEvaluate)
local function OnAddonLoaded(_, name)
    if name ~= addonName then return end
    ns:UnregisterEvent("ADDON_LOADED", OnAddonLoaded)
    Setup()
end
ns:RegisterEvent("ADDON_LOADED", OnAddonLoaded)
ns:RegisterEvent("PLAYER_LOGIN", Setup)
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if not loadedAt then loadedAt = GetTime() end
    NoteLoadGroup()
    Setup()
    ScheduleEvaluate()
end)

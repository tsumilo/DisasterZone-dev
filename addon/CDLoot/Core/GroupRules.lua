-- CDLoot: Core/GroupRules.lua
-- Leader-controlled group loot rules (Addendum D §24-§26 as amended by Addendum E §32/§33). The group's
-- loot authority shares its roll duration, drop quality threshold, dungeon mode switch + 5-man quality and
-- the phase for the group (GS on RAID / PARTY); everyone else reads those values through
-- ns.DB:GetEffective(path) while they are active.
--
-- The authority is computed locally on every client from the live roster and the council lists:
--   raid:  the raid leader; else the master looter.
--   party: the party leader if council (GM / guild list) or if they turned dungeon mode on; else a guild
--          council member in the party (lowest guild rank index, then name).
-- Only members known to run a CDLoot with group rules count (they sent GS or GQ this group session); I
-- always count for myself. The first eligible member who does is the authority.
--
-- Like Util and Dungeon this file is not a lifecycle module (it loads before DB, so it must not shift the
-- module order): it wires itself with ns:RegisterEvent / ns:On and registers its Comm handlers at load.
--
-- Addendum F §38: the raid's authority can lock the BiS lists (GS lk = true, lkAt = its server time when
-- locked; raids only). While locked, BiS refuses edits and council clients watch incoming lists (Store). The
-- lock ends on unlock, when the group disbands or when the authority changes (its rules are cleared).
-- BIS_LOCK_CHANGED(locked) fires whenever GroupRules:IsLocked() changes.
--
-- Addendum I §48: the authority can run a raid session (GS rs = session id, rsAt = its start time; raids only).
-- Starting one also locks the BiS lists, ending it unlocks them. Unlike a bare lock, a running session survives a
-- change of authority: the new authority adopts the session (and its lock) it saw from the old one, so control
-- follows the group. RaidLog (Core/RaidLog.lua) records the session.
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
local LOCK_ANNOUNCE = "CDLoot: BiS lists are locked for this raid."
local MAX_SESSION_ID = 64

---------------------------------------------------------------------------
-- State (one "group session" = from joining a group until leaving it)
---------------------------------------------------------------------------

local active                   -- { from=, rev=, values={rd,q,dq,dm,ph}, at= } rules received from the authority
local speaks = {}              -- [key] = true: sent GS / GQ this group session (runs CDLoot with group rules)
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
local mySession                -- { id=, at= } while I am the raid's authority and run a raid session (Addendum I)
local seenSession              -- { id=, at=, by=, lkAt= } the session last seen from any authority in this raid

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Setting(path)
    local DB = ns.DB
    if DB and DB.GetSetting then return DB:GetSetting(path) end
    return nil
end

local function ValidPhase(p)
    local maxP = ns.MAX_PHASE or 5
    if type(p) == "number" and p == floor(p) and p >= 1 and p <= maxP then return p end
    return nil
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

-- Eligible members in priority order, from live roster data.
local function Candidates()
    local list = {}
    if IsInRaid() then
        local leader, ml
        local n = min(tonumber(GetNumGroupMembers()) or 0, 40)
        for i = 1, n do
            local name, rank, _, _, _, _, _, _, _, _, isML = GetRaidRosterInfo(i)
            if type(name) == "string" and name ~= "" and name ~= UNKNOWNOBJECT then
                local key = Util.NormalizeName(name)
                if rank == 2 then leader = key end
                if isML then ml = key end
            end
        end
        if leader then list[1] = leader end
        if ml and ml ~= leader then list[#list + 1] = ml end
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
        end
    end
    return v
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
    return { rd = rd, q = q, dq = dq, dm = dm, ph = ph, lk = lk, lkAt = lkAt, rs = rs, rsAt = rsAt }, rev
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
            ns:Print("you locked the BiS lists for this raid (/cdl unlock to undo).")
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
        seenSession = { id = s.id, at = s.at, by = s.by, lkAt = lock and lock.at or nil }
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
-- Evaluation
---------------------------------------------------------------------------

local function ResetSession()
    active = nil
    speaks, leaderDM, printed = {}, {}, {}
    rulesRev = 0
    wasAuthority = false
    groupKind = nil
    mySession, seenSession = nil, nil
    DropLock()   -- the group is gone: so is its lock
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
    local auth, pos, list = Resolve()
    local mine = auth ~= nil and Util.IsMe(auth)
    if mine and kind == "raid" then
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
                if open then adopt = { id = open.id, at = open.start } end
            end
            if adopt then
                mySession = { id = adopt.id, at = adopt.at }
                if not myLock and adopt.lkAt then
                    myLock = { at = adopt.lkAt }
                    SaveLock()
                end
            end
        end
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
    if not values.lk then
        values.lkAt = nil
    elseif not values.lkAt then
        local prev = not first and active.values
        values.lkAt = (prev and prev.lk and prev.lkAt) or GetServerTime()
    end
    active = { from = sender, rev = rev or 0, values = values, at = GetTime() }
    wasAuthority = false
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
            rsAt = v.rsAt } }
end

---------------------------------------------------------------------------
-- BiS list lock (Addendum F §38)
---------------------------------------------------------------------------

-- The raid's BiS lists are locked (by me as the authority, or by the authority's rules). Raids only.
function GroupRules:IsLocked()
    if not IsInRaid() then return false end
    if AmAuthority() then return myLock ~= nil end
    return (active ~= nil and active.values.lk == true) and true or false
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
-- announcements are on.
function GroupRules:SetLocked(locked)
    locked = locked and true or false
    if not IsInRaid() then return false, "BiS lists can only be locked in a raid." end
    Invalidate()
    if not AmAuthority() then
        return false, "only the raid leader (the raid's loot authority) can lock or unlock BiS lists."
    end
    if locked == (myLock ~= nil) then return true end
    myLock = locked and { at = GetServerTime() } or nil
    SaveLock()
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
        return mySession and { id = mySession.id, at = mySession.at, by = Util.PlayerKey() } or nil
    end
    if active and active.values.rs then
        return { id = active.values.rs, at = active.values.rsAt, by = active.from }
    end
    return nil
end

-- Starts (on = true) or ends the raid session. Only the raid's loot authority can: returns ok, err. Starting
-- also locks the BiS lists (with the usual raid chat line); ending unlocks them. startAt (optional): an earlier
-- start time (a session started late, e.g. from the boss pull prompt).
function GroupRules:SetSession(on, startAt)
    on = on and true or false
    if not IsInRaid() then return false, "a raid session can only run in a raid." end
    Invalidate()
    if not AmAuthority() then
        return false, "only the raid leader (the raid's loot authority) can start or end the raid."
    end
    if on == (mySession ~= nil) then return true end
    local announce = false
    if on then
        local now = GetServerTime()
        local at = tonumber(startAt)
        if not at or at > now or at < now - MAX_LOCK_AGE then at = now end
        at = floor(at)
        mySession = { id = ((Util.PlayerKey() or "?") .. "-" .. at):sub(1, MAX_SESSION_ID), at = at }
        if not myLock then
            myLock = { at = now }
            announce = true
        end
    else
        mySession = nil
        myLock = nil
    end
    SaveLock()
    DoSend(false)
    wasAuthority = true   -- this GS is the announcement
    Changed()
    if announce and Setting("roll.announce") ~= false then
        local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
        if send then pcall(send, LOCK_ANNOUNCE, "RAID") end
    end
    return true
end

-- "own" (my own settings: no group / no authority with CDLoot), "mine" (I set them for my group) or
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

-- CDLoot extension: key sent GS / GQ in this group session (runs a CDLoot with group rules).
function GroupRules:IsSpeaker(key)
    return type(key) == "string" and speaks[key] == true
end

-- CDLoot extension, called by Dungeon for a DM that passed its gate: the sender switched dungeon mode for
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
-- Slash: /cdl rules
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
        src = "your own settings (no loot leader with CDLoot in this group)"
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
-- Slash: /cdl lock, /cdl unlock (Addendum F §38)
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
end

ns:On("SETTINGS_CHANGED", OnSettingChanged)
ns:On("GROUP_UPDATED", ScheduleEvaluate)
ns:On("CONFIG_UPDATED", ScheduleEvaluate)
ns:On("DUNGEON_MODE_CHANGED", ScheduleEvaluate)
ns:On("ROSTER_UPDATED", ScheduleEvaluate)       -- guild rank order among council members of a party
ns:RegisterEvent("GROUP_ROSTER_UPDATE", ScheduleEvaluate)
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
    Setup()
    ScheduleEvaluate()
end)

if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Roll.lua", ...) then return end -- DisasterZone: Core/Roll.lua
-- Roll sessions (Addendum A §19): one open roll at a time (others wait in a queue), RS/RR/RE/RW
-- raid messages, /roll parsing from CHAT_MSG_SYSTEM, a BiS-aware winner suggestion and the award
-- flow (master-loot hand-out or confirm, then record + announce). Sessions live in memory only.
-- Dungeon mode (Addendum B §22.2): in a 5-man party the same messages run on PARTY.
-- Addendum C §23: a loot message for a rolled item resolves its session on every client
-- (Roll:OnItemLooted, via = "loot"), and awards made outside the roll UI go through
-- Roll:MarkAwardedExternally.
-- Addendum G: council members vote on every roll (RV on the group channel, one vote each, voter names visible);
-- once anyone voted, the most-voted player still in the group is suggested (ties: BiS tier, then the roll).
-- Awards carry a reason (ns.AWARD_REASONS: the awarder's choice, else the winner's BiS tier) in RW and the log.
-- 1.3: a raid that runs rolls without the loot council rolls plain (ses.plain, RS pl): the highest roll is suggested,
-- BiS tiers and votes don't count, and the winner gets no tier reason.
-- 1.3 loot rights in a raid (see IManage / Manages): with the loot council on, only the council votes, awards and ends
-- rolls (a master looter from the guild is council of the raid then); the master looter can always start rolls and
-- hand items out. Rolling plain, the master looter also ends rolls and awards the winner. Raid assistants who are
-- neither have no loot rights; pugs are never council (Guild).
local addonName, ns = ...

local Roll = ns:NewModule("Roll")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, pcall = type, pairs, ipairs, tonumber, tostring, pcall
local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local tsort, tremove, tinsert = table.sort, table.remove, table.insert
local strformat = string.format

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local GRACE = 2                  -- a roll still counts this long after endsAt
local REMOTE_CLOSE_SLACK = 3     -- non-starters close at endsAt + 3s when RE never arrives
local QUEUE_DELAY = 2            -- the next queued roll starts 2s after a roll closes ...
local QUEUE_JITTER = 2           -- ... plus up to 2s when it was someone else's roll
local EARLY_WINDOW = 2           -- rolls up to 2s before an RS arrived are replayed into it
local ANNOUNCE_DELAY = 0.5       -- chat line waits a moment (a simultaneous start may cancel it)
local PRUNE_AGE = 2 * 3600
local MAX_SESSIONS = 200
local MAX_EARLY = 40
local MAX_PENDING_RR = 50
local PENDING_RR_AGE = 15
local MIN_DURATION, MAX_DURATION, DEFAULT_DURATION = 10, 120, 30
local MIN_REMOTE_DURATION = 5
local MAX_ID_LEN = 64
local MAX_SOURCE_LEN = 96
local MAX_BOSS_LEN = 64
local MAX_COPIES = 16
local MAX_TS_SKEW = 300          -- (unused since 0.5; kept for reference)
local RS_TS_PAST, RS_TS_FUTURE = 60, 10   -- an RS start time outside [now - 60, now + 10] is taken as "now"
local PREEMPT_WINDOW = 10        -- a roll open here longer than this is never pre-empted by a "simultaneous" start
local RW_CROSS_WINDOW = 30       -- two awards of one session "crossed" only when they are this close
local RW_AT_PAST, RW_AT_FUTURE = 60, 60   -- an RW award time outside [start - 60, now + 60] is unknown
local ROLL_MIN, ROLL_MAX = 1, 100
local WON_WINDOW = 6 * 3600
local SLASH_DROP_AGE = 1800      -- /dz roll <link>: reuse a drop of the last 30 min holding the item
local ROLL_FORMAT_FALLBACK = "%s rolls %d (%d-%d)"   -- enUS RANDOM_ROLL_RESULT
local MAX_RT_ENTRIES = 40        -- tiers per RT message
local MAX_NOTE_LEN = 64
local LOOT_MATCH_AGE = 15 * 60   -- a loot message resolves sessions created at most 15 min ago

local MAX_VOTES = 40             -- voters per session (one vote per council member in the group)

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local sessions = {}      -- [id] = session
local seqCounter = 0     -- local creation order ("latest" session)
local idCounter = 0      -- per-login counter inside local session ids
local queue = {}         -- my queued sessions (state "queued"), first = next
local advancePending = false
local earlyRolls = {}    -- { {key=, roll=, min=, max=, at=, st=} } rolls no session could take
local pendingRR = {}     -- [id] = { at=, r = {[key] = "roll"|"pass"} } responses that beat their RS
local rollPattern        -- built lazily from RANDOM_ROLL_RESULT (false = unusable)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function DemoOn()
    local Demo = ns.Demo
    return (Demo and Demo.IsEnabled and Demo:IsEnabled()) and true or false
end

local function IsValidItemID(id)
    return type(id) == "number" and id == floor(id) and id >= 1 and id <= 200000
end

local function Setting(path, default)
    local DB = ns.DB
    local v = DB and DB.GetSetting and DB:GetSetting(path)
    if v == nil then return default end
    return v
end

-- The effective roll.duration (Addendum D §26): the group's rule while group rules are active.
local function Duration()
    local DB = ns.DB
    local d = DB and DB.GetEffective and tonumber(DB:GetEffective("roll.duration"))
    d = d or tonumber(Setting("roll.duration", DEFAULT_DURATION)) or DEFAULT_DURATION
    return max(MIN_DURATION, min(MAX_DURATION, floor(d)))
end

local function AnnounceOn()
    return Setting("roll.announce", true) and true or false
end

local function AmRealCouncil()
    local Guild = ns.Guild
    return (Guild and Guild.AmICouncil and Guild:AmICouncil(true)) and true or false
end

local function IsRealCouncil(key)
    local Guild = ns.Guild
    return (Guild and Guild.IsCouncil and Guild:IsCouncil(key, true)) and true or false
end

-- rank (0/1/2), isML of a raid member straight from GetRaidRosterInfo (the group cache refreshes
-- on a short debounce); in a 5-man party: 2 for the party leader, isML from the loot method.
-- nil when not found.
local function GroupRole(key)
    if type(key) ~= "string" then return nil end
    if Util.GetGroupRole then return Util.GetGroupRole(key) end
    if not IsInRaid() then return nil end
    local n = min(tonumber(GetNumGroupMembers()) or 0, 40)
    for i = 1, n do
        local name, rank, _, _, _, _, _, _, _, _, isML = GetRaidRosterInfo(i)
        if type(name) == "string" and Util.NormalizeName(name) == key then
            return tonumber(rank) or 0, isML and true or false
        end
    end
    return nil
end

-- Raid leader / assistant / master looter; in a 5-man party: party leader / master looter.
local function IsLeadOrML(key)
    local rank, isML = GroupRole(key)
    return rank ~= nil and (rank >= 1 or isML)
end

-- The master looter of my group, per the live roster.
local function IsMasterLooter(key)
    local _, isML = GroupRole(key)
    return isML and true or false
end

-- Addendum B §22: in a 5-man party with dungeon mode on.
local function DungeonActive()
    return (Util.IsDungeonModeActive and Util.IsDungeonModeActive()) and true or false
end

-- "RAID", "PARTY" (dungeon mode) or nil: where roll traffic goes.
local function GroupChannel()
    if Util.GetGroupChannel then return Util.GetGroupChannel() end
    return IsInRaid() and "RAID" or nil
end

-- A received roll message's distribution is acceptable: RAID, or PARTY while dungeon mode is active.
local function GroupDist(dist)
    if dist == "RAID" then return true end
    return dist == "PARTY" and DungeonActive()
end

-- 1.3: a raid that runs rolls without the loot council rolls plain: the highest roll wins, BiS lists and council
-- votes don't count. Decided by the starter when the roll opens (RS pl = 1).
local function PlainRaid()
    if not IsInRaid() then return false end
    local GR = ns.GroupRules
    return (GR and GR.IsFeatureOn and not GR:IsFeatureOn("loot")) and true or false
end

-- 1.3: may I end and award a roll of this kind (plain: rolled without the loot council in a raid; party: a dungeon-mode
-- roll)? The council; rolling plain also the master looter; in a 5-man party also the master looter and the party
-- leader. Receivers check the sender with Manages, the same rules.
local function IManage(plain, party)
    if AmRealCouncil() then return true end
    if party then return Util.IsPlayerMasterLooter() or (UnitIsGroupLeader("player") and true or false) end
    return (plain and Util.IsPlayerMasterLooter()) and true or false
end

-- IManage for a sender, from the live group roster (a 5-man party has no assistants: rank 1+ is its leader).
local function Manages(key, plain, party)
    if IsRealCouncil(key) then return true end
    if party then return IsLeadOrML(key) and true or false end
    return (plain and IsMasterLooter(key)) and true or false
end

-- real: the message belongs to a real (non-demo) session and may go out while demo mode is on
-- (a real roll awarded in demo mode must still reach the raid).
local function Send(msg, real)
    if DemoOn() and not real then return false end
    local channel = GroupChannel()
    if not channel then return false end
    local Comm = ns.Comm
    if not (Comm and Comm.Send) then return false end
    return Comm:Send(msg, channel, nil, "alert") and true or false
end

-- Why I cannot start a roll right now (printed by /dz roll, the drop panel's Roll buttons).
local function CannotStartText()
    if IsInGroup() and not IsInRaid() then
        if not DungeonActive() then
            return "Rolls in a 5-man party need dungeon mode: /dz dungeon on (party leader or loot council)."
        end
        return "Only the party leader, the master looter or a loot council member can start rolls."
    end
    local GR = ns.GroupRules
    if IsInRaid() and GR and GR.IsFeatureOn and not GR:IsFeatureOn("rolls") then
        return GR:GetSession() and "Rolls are off for this raid (the raid leader turns them on: session bar > Options)."
            or "Rolls start working when the raid leader starts the raid (Start raid)."
    end
    return "Only the loot council (the raid leader counts) or the master looter can start rolls in a raid."
end

-- Why I cannot award / end a roll of this kind (plain, party: like IManage).
local function CannotAwardText(plain, party)
    if party then return "Only the party leader, the master looter or a loot council member can award this roll." end
    if plain then return "Only the master looter or the loot council can award this roll." end
    return "Only the loot council can award loot in this raid (the master looter hands it out)."
end

local function Updated(ses)
    ns:Fire("ROLL_UPDATED", ses.id)
end

local function ItemText(ses)
    if type(ses.link) == "string" and ses.link ~= "" then return ses.link end
    local db = ns.ItemDB
    local link = db and db.GetLink and db:GetLink(ses.i)
    if link then return link end
    local name = db and db.GetName and db:GetName(ses.i)
    return name and ("[" .. name .. "]") or ("item " .. tostring(ses.i))
end

local function ClassOf(key)
    local Guild = ns.Guild
    local cf = Guild and Guild.GetClass and Guild:GetClass(key)
    if cf then return cf end
    local g = Util.group and Util.group[key]
    if g and g.classFile then return g.classFile end
    local Store = ns.Store
    local rec = Store and Store.Get and Store:Get(key)
    local data = type(rec) == "table" and rec.data
    if type(data) == "table" and type(data.cl) == "string" and data.cl ~= "" then return data.cl end
    return nil
end

local function SpecOf(key)
    local Store = ns.Store
    local rec = Store and Store.Get and Store:Get(key)
    local data = type(rec) == "table" and rec.data
    if type(data) == "table" and type(data.sp) == "string" and data.sp ~= "" then return data.sp end
    return nil
end

local function NameText(key)
    return "|c" .. Util.ClassColorHex(ClassOf(key)) .. Util.ShortName(key) .. "|r"
end

-- body = the line without the "DisasterZone: " prefix. Raid chat gets the prefix; local output
-- (demo, announcements off) gets it from ns:Print. The default fonts have no arrow glyph: use "->".
local function Announce(body, localOnly, suffix)
    if not localOnly and IsInGroup() then
        local UI = ns.UI
        if UI and UI.AnnounceLine then
            local ok = ns.SafeCall(UI.AnnounceLine, UI, "DisasterZone: " .. body)
            if ok then return end
        end
    end
    ns:Print("%s%s", body, suffix or "")
end

-- Chat lines want a real item link: wait (up to ~2s) for the item data when it is not cached.
local function WhenItemReady(ses, fn, tries)
    tries = tries or 0
    local db = ns.ItemDB
    local ready = (type(ses.link) == "string") or not (db and db.GetLink) or db:GetLink(ses.i) ~= nil
    if ready or tries >= 4 then
        fn()
        return
    end
    Util.After(0.5, function() WhenItemReady(ses, fn, tries + 1) end)
end

-- Session ordering for "who started first" (identical on every client: the starter's server
-- time travels in RS, ties are broken by id).
local function Earlier(a, b)
    local ta, tb = a.startedAt or 0, b.startedAt or 0
    if ta ~= tb then return ta < tb end
    return tostring(a.id) < tostring(b.id)
end

local function NewSession(f)
    seqCounter = seqCounter + 1
    local ses = {
        id = f.id, i = f.i, s = f.s or "", b = f.b or "", c = f.c or 1,
        starter = f.starter, startedAt = nil, duration = nil, endsAt = nil,
        state = f.state or "queued",
        rolls = {}, responses = {},
        votes = {},              -- [council voter key] = candidate key (Addendum G)
        winner = nil, given = false,
        -- DisasterZone extras
        seq = seqCounter, createdAt = GetTime(), isLocal = f.isLocal and true or false,
        demo = f.demo and true or false, link = f.link,
    }
    sessions[ses.id] = ses
    return ses
end

local function NewLocalSession(itemID, s, b, c, demo, link)
    local me = Util.PlayerKey() or "?"
    idCounter = idCounter + 1
    local id = Util.ShortName(me) .. "-" .. tostring(GetServerTime()) .. "-" .. idCounter
    while sessions[id] do
        idCounter = idCounter + 1
        id = Util.ShortName(me) .. "-" .. tostring(GetServerTime()) .. "-" .. idCounter
    end
    return NewSession({
        id = id, i = itemID, s = s, b = b, c = c, starter = me, state = "queued",
        isLocal = true, demo = demo, link = link,
    })
end

-- Latest non-cancelled session for (item, drop source, copy); copy nil = any copy.
local function Latest(itemID, s, c)
    local best
    for _, ses in pairs(sessions) do
        if ses.i == itemID and ses.s == s and (c == nil or ses.c == c) and ses.state ~= "cancelled"
            and (not best or ses.seq > best.seq) then
            best = ses
        end
    end
    return best
end

local function RemoveFromQueue(ses)
    for i = #queue, 1, -1 do
        if queue[i] == ses then tremove(queue, i) end
    end
end

local function Prune()
    local now = GetTime()
    local count, old = 0, {}
    for id, ses in pairs(sessions) do
        if ses.state ~= "open" and ses.state ~= "queued" then
            if now - (ses.createdAt or now) > PRUNE_AGE then
                sessions[id] = nil
            else
                count = count + 1
                old[#old + 1] = ses
            end
        else
            count = count + 1
        end
    end
    if count > MAX_SESSIONS then
        tsort(old, function(a, b) return a.seq < b.seq end)
        for i = 1, min(#old, count - MAX_SESSIONS) do
            sessions[old[i].id] = nil
        end
    end
end

-- A session that still takes rolls: open, or closed / awarded less than GRACE seconds ago.
-- Open sessions win; otherwise the one that ended last.
local function AcceptingSession()
    local now = GetTime()
    local best
    for _, ses in pairs(sessions) do
        local st = ses.state
        if (st == "open" or st == "closed" or st == "awarded") and ses.endsAt and now <= ses.endsAt + GRACE then
            if not best
                or (st == "open" and best.state ~= "open")
                or ((st == "open") == (best.state == "open") and ses.endsAt > best.endsAt) then
                best = ses
            end
        end
    end
    return best
end

local function IsAccepting(ses)
    local st = ses.state
    if st ~= "open" and st ~= "closed" and st ~= "awarded" then return false end
    return ses.endsAt ~= nil and GetTime() <= ses.endsAt + GRACE
end

-- A closed / awarded session still inside its grace period (blocks the next start).
local function GraceSession()
    local now = GetTime()
    local best
    for _, ses in pairs(sessions) do
        if (ses.state == "closed" or ses.state == "awarded") and ses.endsAt and now < ses.endsAt + GRACE
            and (not best or ses.endsAt > best.endsAt) then
            best = ses
        end
    end
    return best
end

---------------------------------------------------------------------------
-- Roll parsing
---------------------------------------------------------------------------

-- Blizzard format string -> anchored Lua pattern (%s -> (.+), %d -> (%d+), magic chars escaped).
local function FormatToPattern(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    fmt = fmt:gsub("%%%d+%$", "%%")
    local out, i, n = {}, 1, #fmt
    while i <= n do
        local c = fmt:sub(i, i)
        if c == "%" then
            local nx = fmt:sub(i + 1, i + 1)
            if nx == "s" then
                out[#out + 1] = "(.+)"
                i = i + 2
            elseif nx == "d" then
                out[#out + 1] = "(%d+)"
                i = i + 2
            else
                out[#out + 1] = "%%"
                i = i + ((nx == "%") and 2 or 1)
            end
        elseif c:find("^[%^%$%(%)%.%[%]%*%+%-%?]$") then
            out[#out + 1] = "%" .. c
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return "^" .. table.concat(out) .. "$"
end

local function GetRollPattern()
    if rollPattern == nil then
        local fmt = (type(RANDOM_ROLL_RESULT) == "string" and RANDOM_ROLL_RESULT ~= "") and RANDOM_ROLL_RESULT
            or ROLL_FORMAT_FALLBACK
        local pat = FormatToPattern(fmt)
        if pat and pcall(string.match, "", pat) then
            rollPattern = pat
        else
            rollPattern = false
        end
    end
    return rollPattern or nil
end

-- Roll lines carry no realm. Own-realm name first, then a unique cross-realm group member with
-- that name. nil when the roller is not in my group.
local function ResolveRoller(name)
    local key = Util.NormalizeName(name)
    if key and Util.IsInMyGroup(key) then return key end
    local base = type(name) == "string" and name:match("^([^%-]+)")
    if not base then return nil end
    local found
    for _, k in ipairs(Util.GetGroupKeys()) do
        if type(k) == "string" and k:match("^([^%-]+)") == base then
            if found then return nil end   -- two members share the name: can't tell
            found = k
        end
    end
    return found
end

local function AddRoll(ses, key, value, lo, hi)
    local valid = (lo == ROLL_MIN and hi == ROLL_MAX)
    local r = ses.rolls[key]
    if r then
        r.count = (r.count or 1) + 1
        -- Keep the first roll; only a first out-of-range roll is replaced by the first valid one.
        if r.invalid and valid then
            r.roll, r.min, r.max, r.invalid, r.at = value, lo, hi, false, GetTime()
        end
    else
        ses.rolls[key] = { roll = value, min = lo, max = hi, at = GetTime(), count = 1, invalid = not valid }
    end
    if ses.responses[key] == "pass" then ses.responses[key] = "roll" end   -- rolled after all
    if ses.state == "awarded" then ses.final = nil end
    Updated(ses)
end

local function RememberEarly(key, value, lo, hi)
    if DemoOn() or not GroupChannel() then return end
    local now = GetTime()
    local keep = {}
    for _, e in ipairs(earlyRolls) do
        if now - e.at <= EARLY_WINDOW then keep[#keep + 1] = e end
    end
    if #keep >= MAX_EARLY then tremove(keep, 1) end
    keep[#keep + 1] = { key = key, roll = value, min = lo, max = hi, at = now, st = GetServerTime() }
    earlyRolls = keep
end

-- Rolls that arrived just before this session's RS (and not before its start second).
local function ReplayEarly(ses)
    local list = earlyRolls
    earlyRolls = {}
    local now = GetTime()
    for _, e in ipairs(list) do
        if now - e.at <= EARLY_WINDOW and e.st >= (ses.startedAt or 0) then
            AddRoll(ses, e.key, e.roll, e.min, e.max)
        end
    end
end

---------------------------------------------------------------------------
-- Session lifecycle
---------------------------------------------------------------------------

local AdvanceQueue   -- forward declaration
local SnapshotTiers  -- forward declaration (Results section)
local SendTiers      -- forward declaration (Network section)
local WithHoldings   -- forward declaration (raider responses)
local SiblingWinners, CantUse   -- forward declarations (Results section)

local function ScheduleAdvance(delay)
    if advancePending then return end
    advancePending = true
    Util.After(delay, function()
        advancePending = false
        AdvanceQueue()
    end)
end

-- Called whenever a session stops being open: the next queued roll of mine may start.
local function OnSessionFinished(ses)
    if #queue == 0 then return end
    local delay = QUEUE_DELAY
    if not ses.isLocal then delay = delay + math.random() * QUEUE_JITTER end
    ScheduleAdvance(delay)
end

local function CloseSession(ses)
    if ses.state ~= "open" then return false end
    ses.state = "closed"
    local now = GetTime()
    if not ses.endsAt or ses.endsAt > now then ses.endsAt = now end
    ses.closedAt = now
    Updated(ses)
    OnSessionFinished(ses)
    return true
end

local function CancelSession(ses)
    if ses.state == "cancelled" then return false end
    local wasOpen = ses.state == "open"
    ses.state = "cancelled"
    RemoveFromQueue(ses)
    if wasOpen then
        local now = GetTime()
        if not ses.endsAt or ses.endsAt > now then ses.endsAt = now end
    end
    Updated(ses)
    if wasOpen then OnSessionFinished(ses) end
    return true
end

local function CancelQueue(reason)
    local list = queue
    queue = {}
    for _, ses in ipairs(list) do
        CancelSession(ses)
    end
    if #list > 0 and reason then
        ns:Print("%d queued roll(s) cancelled: %s.", #list, reason)
    end
end

local function OtherOpen(ses)
    for _, other in pairs(sessions) do
        if other ~= ses and other.state == "open" then return other end
    end
    return nil
end

-- My session lost a simultaneous start: it is cancelled everywhere; I run it again afterwards
-- unless the winner is a roll for the very same item.
local function Preempt(loser, winner)
    CancelSession(loser)
    if not loser.isLocal or loser.demo then return end
    -- Everyone resolves the clash the same way; this RE only helps clients that missed the winner's RS.
    Send({ t = "RE", id = loser.id, x = true })
    local same = winner.i == loser.i and winner.s == loser.s and winner.c == loser.c
    if same then
        ns:Print("%s started the same roll for %s at the same moment; theirs is used.",
            Util.ShortName(winner.starter), ItemText(loser))
        return
    end
    local again = NewLocalSession(loser.i, loser.s, loser.b, loser.c, false, loser.link)
    tinsert(queue, 1, again)
    Updated(again)
    ns:Print("Your roll for %s was postponed: %s started a roll at the same moment. It restarts afterwards.",
        ItemText(loser), Util.ShortName(winner.starter))
    OnSessionFinished(loser)
end

local function StarterTimeout(id)
    local ses = sessions[id]
    if not ses or ses.state ~= "open" then return end
    CloseSession(ses)
    if not ses.demo then Send({ t = "RE", id = id }) end
end

-- Opens one of my sessions: RS, chat line, timer, popup.
local function OpenLocal(ses)
    local channel = GroupChannel()
    if not ses.demo and not channel then
        CancelSession(ses)
        return false
    end
    ses.party = (not ses.demo and channel == "PARTY") or nil   -- a dungeon-mode (5-man party) roll
    ses.plain = (not ses.demo and not ses.party and PlainRaid()) or nil
    ses.state = "open"
    ses.startedAt = GetServerTime()
    ses.duration = Duration()
    ses.endsAt = GetTime() + ses.duration
    ses.openedAt = GetTime()
    SnapshotTiers(ses)
    local id = ses.id
    if not ses.demo then
        -- pl (1.3, ignored by older clients): 1 = a plain roll, every client suggests the highest roll; 0 = a loot
        -- council roll. Always said in a raid: a receiver that just reloaded does not know the raid's rules yet.
        Send({ t = "RS", id = id, i = ses.i, s = ses.s, b = ses.b, d = ses.duration, ts = ses.startedAt, c = ses.c,
               pl = (not ses.party) and (ses.plain and 1 or 0) or nil })
        -- A council starter tells a non-council master looter the tiers too (it may be the only council member in
        -- the raid). A moment later, so the RS is there first.
        Util.After(0.5, function()
            if ses.state == "open" then SendTiers(ses) end
        end)
    end
    if ns.ItemDB and ns.ItemDB.GetLink then ns.ItemDB:GetLink(ses.i) end   -- requests the item data
    Util.After(ANNOUNCE_DELAY, function()
        WhenItemReady(ses, function()
            if ses.state ~= "open" then return end
            local body = strformat("Roll for %s now — /roll (%ds)", ItemText(ses), ses.duration)
            if ses.demo then
                Announce(body, true, " |cff999999(demo: only shown to you)|r")
            elseif AnnounceOn() then
                Announce(body)
            end
        end)
    end)
    Util.After(ses.duration, function() StarterTimeout(id) end)
    ns:Fire("ROLL_STARTED", ses)
    Updated(ses)
    if ses.demo and ns.Demo and ns.Demo.SimulateRolls then
        ns.SafeCall(ns.Demo.SimulateRolls, ns.Demo, ses)
    end
    return true
end

AdvanceQueue = function()
    while #queue > 0 do
        if Roll:GetActive() then return end   -- another roll runs; its close triggers us again
        local grace = GraceSession()
        if grace then
            ScheduleAdvance(max(0.1, grace.endsAt + GRACE - GetTime()))
            return
        end
        local ses = tremove(queue, 1)
        if ses.state == "queued" then
            local newest = Latest(ses.i, ses.s, ses.c)
            if newest and newest ~= ses and newest.seq > ses.seq then
                CancelSession(ses)   -- someone rolled this item meanwhile
            elseif not Roll:CanStart() then
                tinsert(queue, 1, ses)
                CancelQueue("you can no longer start rolls")
                return
            else
                OpenLocal(ses)
                return
            end
        end
    end
end

-- Something is running, queued, about to start, or still in its grace period.
local function IsBusy()
    return Roll:GetActive() ~= nil or #queue > 0 or advancePending or GraceSession() ~= nil
end

local function EnsureAdvance()
    if advancePending or #queue == 0 or Roll:GetActive() then return end
    local grace = GraceSession()
    ScheduleAdvance(grace and max(0.1, grace.endsAt + GRACE - GetTime()) or 0.1)
end

---------------------------------------------------------------------------
-- Results / suggestion
---------------------------------------------------------------------------

-- Tiers: 1 main-spec BiS, 2 main-spec alt, 3 off-spec list (Addendum H), 4 everyone else.
local TIER_OTHER = 4
local MAT_NONE = 1000   -- (a crafting material: "still missing" of someone who has no craft that uses it)

local function TierOf(w, ses)
    if type(w) ~= "table" then return TIER_OTHER end
    if w.cantUse then return TIER_OTHER end   -- (0.5) the player's class cannot use it (a class-restricted item / token)
    -- An award of this very session does not demote its winner.
    local got = w.obtained or (w.awarded and w.key ~= ses.winner)
    if got then return TIER_OTHER end
    if w.os then return 3 end
    if w.which == "main" then return 1 end
    if w.which == "alt" then return 2 end
    return TIER_OTHER
end

local function EquippedFor(key, itemID)
    local ItemDB, Store = ns.ItemDB, ns.Store
    if not (ItemDB and ItemDB.GetSlotsForItem and Store and Store.GetEquippedList) then return {} end
    local sids = ItemDB:GetSlotsForItem(itemID)
    local sid = type(sids) == "table" and sids[1]
    if not sid then return {} end
    local list = Store:GetEquippedList(key, sid)
    return type(list) == "table" and list or {}
end

local function WonTonight(key)
    local Ledger = ns.Ledger
    if not (Ledger and Ledger.CountSince) then return 0 end
    return tonumber(Ledger:CountSince(key, GetServerTime() - WON_WINDOW)) or 0
end

-- A roll of a player who left the group is shown but never suggested (they cannot get the item).
local function BaseRowGroup(r)
    -- (a class that can't use the item sits at the bottom with the passes: never suggested, votes or not)
    if r.response == "pass" or r.cantUse then return 3 end
    if r.roll and not r.invalid and r.inRaid then return 1 end
    return 2
end

local function InRealGroup(key)
    return type(Util.group) == "table" and Util.group[key] ~= nil
end

-- Addendum F §38: ts when key's BiS list changed while the raid's lists were locked (council cache), or
-- true when a council member told me so (RT lc, I am a non-council starter / master looter); nil otherwise.
local function LockFlag(ses, key)
    local Store = ns.Store
    local ts = Store and Store.GetLockFlag and Store:GetLockFlag(key)
    if ts then return ts end
    local remote = not ses.demo and ses.remoteLock
    if not (remote and remote[key]) then return nil end
    local GR = ns.GroupRules
    return (GR and GR.IsLocked and GR:IsLocked()) and true or nil   -- the flags end with the lock
end

-- Group membership for a session: the demo raid for demo sessions, the real group otherwise.
local function InGroupFor(ses, key)
    if ses.demo then return Util.IsInMyGroup(key) end
    return InRealGroup(key)
end

-- Best BiS entry per player from the Store (lowest tier; GetWanters is already sorted by relevance).
local function LiveWanters(ses)
    local best = {}
    local Store = ns.Store
    -- The group's phase (group rules / guild council phase): never my personal view-phase override, or council
    -- clients would rank the same rollers differently (and hand that to a non-council master looter via RT).
    local Guild = ns.Guild
    local phase = Guild and Guild.GetGuildPhase and Guild:GetGuildPhase() or nil
    local wanters = Store and Store.GetWanters and Store:GetWanters(ses.i, { includeObtained = true, viewPhase = phase, list = "both" }) or {}
    for _, w in ipairs(type(wanters) == "table" and wanters or {}) do
        if type(w) == "table" and type(w.key) == "string" then
            local t = TierOf(w, ses)
            local cur = best[w.key]
            if not cur or t < cur.tier then best[w.key] = { entry = w, tier = t } end
        end
    end
    -- A crafting material (Materials): the players with a craft that uses it on a list, at that list's tier.
    local M = ns.Materials
    if next(best) == nil and M and M.IsMaterial and M:IsMaterial(ses.i) then
        for key, w in pairs(M:GetWants(ses.i, { viewPhase = phase }).byKey) do
            best[key] = { entry = w, tier = TierOf(w, ses) }
        end
    end
    return best
end

-- The tier inputs are frozen when the session opens: handing the item out before the award is
-- confirmed (loot message -> ledger entry, the winner's bag scan -> obtained) must not demote the
-- player it was handed to. Players missing from the snapshot (list arrived later) use live data.
SnapshotTiers = function(ses)
    local snap = {}
    if ses.plain then
        ses.snap = snap
        return
    end
    for key, b in pairs(LiveWanters(ses)) do
        local w = b.entry
        snap[key] = { tier = b.tier, which = w.which, phase = w.phase, os = w.os and true or nil,
                      obtained = w.obtained and true or false, awarded = w.awarded and true or false }
    end
    ses.snap = snap
end

-- The winners of the other copies of ses's item from the same drop (awarded, also loot-marked): { [key] = true }.
SiblingWinners = function(ses)
    local set
    for _, other in pairs(sessions) do
        if other ~= ses and other.state == "awarded" and type(other.winner) == "string"
            and other.i == ses.i and other.s == ses.s and (other.demo and true or false) == (ses.demo and true or false) then
            set = set or {}
            set[other.winner] = true
        end
    end
    return set
end

-- The class cannot use the dropped item (class-restricted item, a token of other classes).
CantUse = function(itemID, classFile)
    local db = ns.ItemDB
    return (db and db.CanClassUse and db:CanClassUse(itemID, classFile) == false) and true or false
end

local function BuildResults(ses)
    local rows, order = {}, {}
    local function Row(key)
        local r = rows[key]
        if not r then
            r = { key = key }
            rows[key] = r
            order[#order + 1] = key
        end
        return r
    end
    for key in pairs(ses.rolls) do Row(key) end
    for key in pairs(ses.responses) do Row(key) end

    -- A plain roll (1.3) lists only who rolled or passed: no BiS tiers, no council votes.
    local plain = ses.plain
    local best = plain and {} or LiveWanters(ses)
    local snap = not plain and ses.snap or nil
    -- Tiers from a council member (RT): I am a non-council starter / master looter without the lists.
    local remote = (not plain and not ses.demo and not AmRealCouncil()) and ses.remoteTiers or nil
    -- Winners of the other copies of this item from this drop: the tiers are frozen when a copy opens, so the
    -- winner of copy 1 (awarded after copy 2 opened) would still be suggested for copy 2.
    local sibWon = SiblingWinners(ses)
    -- A crafting material: whoever this one completes a craft for comes first, then whoever is closest to one.
    local M = ns.Materials
    local mat = not plain and M and M.IsMaterial and M:IsMaterial(ses.i)
        and M:GetWants(ses.i, { viewPhase = ns.Guild and ns.Guild.GetGuildPhase and ns.Guild:GetGuildPhase() or nil })
        or nil
    for key, b in pairs(best) do
        if b.entry.inRaid then Row(key) end
    end
    for key, s in pairs(snap or {}) do
        if s.tier < TIER_OTHER and InGroupFor(ses, key) then Row(key) end
    end
    for key in pairs(remote or {}) do
        if InGroupFor(ses, key) then Row(key) end
    end
    -- Council votes (Addendum G): only voters who are (still) council count; demo votes always do.
    local tally, voters = {}, {}
    for voter, cand in pairs(not plain and ses.votes or {}) do
        if type(cand) == "string" and (ses.demo or IsRealCouncil(voter)) then
            tally[cand] = (tally[cand] or 0) + 1
            local list = voters[cand]
            if not list then
                list = {}
                voters[cand] = list
            end
            list[#list + 1] = voter
        end
    end
    for cand in pairs(tally) do
        if InGroupFor(ses, cand) then Row(cand) end
    end

    local out = {}
    for _, key in ipairs(order) do
        local r = rows[key]
        local roll = ses.rolls[key]
        local b = best[key]
        local w = b and b.entry
        local s = snap and snap[key]
        r.roll = roll and roll.roll or nil
        r.min = roll and roll.min or nil
        r.max = roll and roll.max or nil
        r.invalid = (roll and roll.invalid) and true or false
        r.count = roll and roll.count or 0
        r.response = ses.responses[key]
        if s then
            r.tier, r.which, r.phase, r.obtained, r.awarded = s.tier, s.which, s.phase, s.obtained, s.awarded
            r.os = s.os
        else
            r.tier = b and b.tier or TIER_OTHER
            r.os = (w and w.os) and true or nil
            r.which = w and w.which or nil
            r.phase = w and w.phase or nil
            r.obtained = (w and w.obtained) and true or false
            r.awarded = (w and w.awarded) and true or false
        end
        local rt = remote and remote[key]
        if rt and rt < r.tier then
            r.tier = rt
            r.which = r.which or ((rt == 1) and "main" or "alt")
            r.os = (rt == 3) or nil
        end
        if sibWon and sibWon[key] and key ~= ses.winner then
            r.tier = TIER_OTHER
            r.awarded = true
            r.wonCopy = true
        end
        r.inRaid = InGroupFor(ses, key)
        r.classFile = (w and w.classFile) or ClassOf(key)
        -- (0.5) A class that cannot use the item is never a BiS wanter (also against an older council's RT).
        if r.classFile and CantUse(ses.i, r.classFile) then
            r.tier = TIER_OTHER
            r.cantUse = true
        end
        r.spec = (w and w.spec) or SpecOf(key)
        if mat then
            -- the craft they want the material for: how many it takes, how many they hold, what is left after this one
            local m = mat.byKey[key]
            if m and r.tier < TIER_OTHER then
                r.craft, r.need, r.held, r.heldSrc, r.left, r.completes = m.craft, m.need, m.held, m.heldSrc, m.left,
                    m.completes
            end
        end
        r.equippedList = (w and type(w.equippedList) == "table") and w.equippedList or EquippedFor(key, ses.i)
        r.wonTonight = (w and tonumber(w.wonTonight)) or WonTonight(key)
        r.lockChanged = not plain and LockFlag(ses, key) or nil   -- never suggested (Addendum F §38)
        r.votes = tally[key] or 0
        local vl = voters[key] or {}
        tsort(vl)
        r.voters = vl
        r.myVote = ses.votes[Util.PlayerKey() or ""] == key
        r.suggested = false
        r.suggestedBy = nil
        r.tie = false
        r.isMe = Util.IsMe(key)
        r.isWinner = (ses.winner == key)
        r.name = Util.ShortName(key)
        out[#out + 1] = r
    end

    -- 1.3.5: a prized item (Core/Prized.lua) and the guild's loot rules (Council > Rules) order the rows: Roll:RankRows.
    local P = ns.Prized
    local przRec = not plain and P and P.ForItem and P:ForItem(ses.i) or nil
    if not plain then
        local RL, Att, Store, G = ns.RaidLog, ns.Attendance, ns.Store, ns.Guild
        -- longevity (Longest use): phases each player keeps it on their list, up to the GM's last phase counted
        local LR = G and G.GetLootRules and G:GetLootRules()
        local lastPhase = LR and (tonumber(LR.o) or 0) > 0 and Store and Store.Longevity and tonumber(LR.o) or nil
        for _, r in ipairs(out) do
            r.att = RL and RL.GetAttendance and (RL:GetAttendance(r.key)) or nil
            local d = Att and Att.GetDryStreak and Att:GetDryStreak(r.key)
            r.dry = d and d.nights or nil
            if lastPhase then
                local _
                r.longevity, _, r.longevityTo = Store:Longevity(r.key, ses.i, nil, lastPhase)
            end
        end
    end
    return Roll:RankRows(out, { plain = plain, mat = mat, prized = przRec })
end

-- Orders result rows and marks the suggestion (suggested / suggestedBy / tie / split), in place; returns them.
-- ctx = { plain = a plain roll, mat = crafting material wants, prized = the item's prized record, rules = the loot rules
-- (default: the guild's, Guild:GetLootRules) }. Rows need: key, name, roll, invalid, response, inRaid, votes, tier,
-- cantUse, lockChanged, wonCopy, left; att (attendance %), dry (raids without loot) and longevity (phases on the list)
-- when the guild uses them.
-- Council > Rules' preview ranks made-up rows with it.
function Roll:RankRows(out, ctx)
    ctx = ctx or {}
    local plain, mat = ctx.plain, ctx.mat
    local G = ns.Guild
    local R = ctx.rules or (G and G.GetLootRules and G:GetLootRules()) or { f = 0, s = "r", l = "l", w = "r", y = "n" }
    if plain then R = { f = 0, s = "r", l = "l", w = "r", y = "n" } end
    -- the attendance floor: below it a player is listed but never suggested
    local floorPct = tonumber(R.f) or 0
    for _, r in ipairs(out) do
        r.lowAtt = (floorPct > 0 and tonumber(r.att) and r.att < floorPct) and floorPct or nil   -- (the floor)
        r.split = nil
    end
    local function RowGroup(r)
        if r.lowAtt and r.response ~= "pass" then return 2 end
        return BaseRowGroup(r)
    end
    -- 1.3.5: a prized item (Core/Prized.lua): each row says how the player stands against its loot rules (r.prz);
    -- the players who meet them come first, in the rules' priority order.
    local P = ns.Prized
    local przRec = ctx.prized
    if przRec then
        local present = {}
        for _, r in ipairs(out) do
            if r.inRaid and r.response ~= "pass" then present[r.key] = true end
        end
        for _, r in ipairs(out) do r.prz = P:Check(przRec, r.key, { present = present, hint = r }) end
    end

    -- Votes that count for the suggestion: for a player still in the group who did not pass (and is not under the
    -- guild's attendance floor).
    local function VoteRank(r)
        if r.votes > 0 and r.inRaid and r.response ~= "pass" and not r.lowAtt and not r.cantUse then return r.votes end
        return 0
    end
    local function ValidRoll(r)
        return (r.roll and not r.invalid) and r.roll or nil
    end
    tsort(out, function(a, b)
        if przRec then
            local first = P:Before(a.prz, b.prz)
            if first ~= nil then return first end
        end
        -- Voted players first (most votes; then whoever rolled, the higher roll: 1.3.5, the list tier no longer
        -- breaks a split vote, so a player who did not roll never wins one quietly).
        local va, vb = VoteRank(a), VoteRank(b)
        if va ~= vb then return va > vb end
        if va > 0 then
            local ra, rb = ValidRoll(a), ValidRoll(b)
            if (ra ~= nil) ~= (rb ~= nil) then return ra ~= nil end
            if ra and ra ~= rb then return ra > rb end
        end
        local ga, gb = RowGroup(a), RowGroup(b)
        if ga ~= gb then return ga < gb end
        if mat then
            local la, lb = a.left or MAT_NONE, b.left or MAT_NONE
            if la ~= lb then return la < lb end
        end
        -- (the guild's loot rules: lists first or the roll only; then, each when it is on: the longest use (who keeps
        -- it on their list for more phases, Store:Longevity), the driest first; then the highest roll)
        if R.l ~= "r" and a.tier ~= b.tier then return a.tier < b.tier end
        if (tonumber(R.o) or 0) > 0 and ga == 1 then
            local oa, ob = tonumber(a.longevity) or 0, tonumber(b.longevity) or 0
            if oa ~= ob then return oa > ob end
        end
        if R.w == "d" and ga == 1 then
            local da, db = tonumber(a.dry) or 0, tonumber(b.dry) or 0
            if da ~= db then return da > db end
        end
        if ga == 1 and a.roll ~= b.roll then return a.roll > b.roll end
        if ga == 2 then
            local ia, ib = a.roll ~= nil, b.roll ~= nil   -- out-of-range rolls before "no roll"
            if ia ~= ib then return ia end
        end
        if a.name ~= b.name then return a.name < b.name end
        return a.key < b.key
    end)

    -- The suggestion: the best valid roll of a player still in the group, skipping players whose BiS list
    -- changed while the lists were locked, players whose class can't use the item, and the winner of
    -- another copy (they stay listed; the council can still award them by hand). If only such players
    -- rolled, there is no suggestion.
    local function Suggestible(r)
        return not r.lockChanged and not r.cantUse and not r.wonCopy and not r.lowAtt
            and not (r.prz and r.prz.ok == false)
    end
    -- A prized item: the most-voted player who meets the rules; when the council decides (its vote rule), never a
    -- roll (no votes yet: no suggestion).
    if przRec then
        local best
        for _, r in ipairs(out) do
            if VoteRank(r) > 0 and Suggestible(r) and (not best or VoteRank(r) > VoteRank(best)) then best = r end
        end
        if best then
            best.suggested = true
            best.suggestedBy = "votes"
            return out
        end
        if P:CouncilDecides(przRec) then return out end
    end
    -- Addendum G: once a council member voted, the vote decides: the most-voted player still in the group who did
    -- not pass (the council chose them knowingly, so the roll rules above don't apply); ties as sorted above.
    -- 1.3.5: a split vote (several players with the most votes) is marked r.split; the guild's rules say whether the
    -- highest roll among them is suggested (whoever did not roll never is) or the council picks one (no suggestion).
    local top = out[1]
    if przRec then top = nil end
    if top and VoteRank(top) > 0 then
        local most = VoteRank(top)
        local split = {}
        for _, r in ipairs(out) do
            if VoteRank(r) == most then split[#split + 1] = r end
        end
        if #split == 1 then
            top.suggested = true
            top.suggestedBy = "votes"
            return out
        end
        for _, r in ipairs(split) do r.split = true end
        if R.s == "p" then return out end
        local pick
        for _, r in ipairs(split) do
            if ValidRoll(r) then
                pick = r
                break
            end
        end
        if not pick then return out end   -- (none of them rolled: the council picks)
        pick.suggested = true
        pick.suggestedBy = "votes"
        local tied = {}
        for _, r in ipairs(split) do
            if ValidRoll(r) == ValidRoll(pick) then tied[#tied + 1] = r end
        end
        if #tied > 1 then
            for _, r in ipairs(tied) do r.tie = true end
        end
        return out
    end
    top = nil
    for _, r in ipairs(out) do
        if RowGroup(r) ~= 1 then break end
        if Suggestible(r) then
            top = r
            break
        end
    end
    if top then
        top.suggested = true
        top.suggestedBy = "roll"
        local tied = {}
        for _, r in ipairs(out) do
            if RowGroup(r) == 1 and Suggestible(r) and r.tier == top.tier and r.roll == top.roll and r.left == top.left then
                tied[#tied + 1] = r
            end
        end
        if #tied > 1 then
            for _, r in ipairs(tied) do r.tie = true end
        end
    end
    return out
end

local function CopyRows(rows)
    local out = {}
    for i, r in ipairs(rows) do
        local c = {}
        for k, v in pairs(r) do c[k] = v end
        out[i] = c
    end
    return out
end

---------------------------------------------------------------------------
-- Public API: queries
---------------------------------------------------------------------------

function Roll:Get(id)
    return type(id) == "string" and sessions[id] or nil
end

-- 1.3: does a roll started now in my raid roll plain (rolls on, loot council off)?
function Roll:IsPlainRaid()
    return PlainRaid()
end

-- The open session (the earliest started if, briefly, there are two) or nil.
function Roll:GetActive()
    local best
    for _, ses in pairs(sessions) do
        if ses.state == "open" and (not best or Earlier(ses, best)) then best = ses end
    end
    return best
end

-- Latest non-cancelled session for an item of a drop. copyIndex (DisasterZone extension, optional):
-- the k-th copy of itemID in drop.i (two identical tokens = copies 1 and 2); nil = any copy.
function Roll:GetForItem(itemID, dropS, copyIndex)
    itemID = tonumber(itemID)
    if not itemID then return nil end
    local s = type(dropS) == "string" and dropS or ""
    local c = tonumber(copyIndex)
    return Latest(itemID, s, c and floor(c) or nil)
end

-- My queued sessions in start order (state "queued"; a new array).
function Roll:GetQueue()
    local out = {}
    for i, ses in ipairs(queue) do out[i] = ses end
    return out
end

-- Seconds left while open (0 otherwise).
function Roll:GetTimeLeft(id)
    local ses = self:Get(id)
    if not ses or ses.state ~= "open" or not ses.endsAt then return 0 end
    return max(0, ses.endsAt - GetTime())
end

-- Sorted result rows (see §19.1). Awarded sessions return the rows as they were at the award.
-- Extra fields: min, max, awarded, isMe, isWinner, name (short name).
function Roll:GetResults(id)
    local ses = self:Get(id)
    if not ses then return {} end
    if ses.state == "awarded" then
        if not ses.final then ses.final = BuildResults(ses) end
        return CopyRows(ses.final)
    end
    return BuildResults(ses)
end

-- Raid: council (the raid leader of my guild counts) or the master looter (1.3: no raid assistants). 5-man party
-- with dungeon mode on: party leader, master looter or council. Demo mode: anyone (local only).
function Roll:CanStart()
    if DemoOn() then return true end
    if IsInRaid() then
        -- rolls run only while the raid leader's raid session has them on (GroupRules, 1.2)
        local GR = ns.GroupRules
        if GR and GR.IsFeatureOn and not GR:IsFeatureOn("rolls") then return false end
        return AmRealCouncil() or Util.IsPlayerMasterLooter()
    end
    if DungeonActive() then
        return AmRealCouncil() or Util.IsPlayerMasterLooter() or (UnitIsGroupLeader("player") and true or false)
    end
    return false
end

-- May I award a roll started now (IManage for my group as it is).
local function RealCanAward()
    if IsInRaid() then return IManage(PlainRaid(), false) end
    return IManage(false, DungeonActive())
end

-- May I award / end this (real) session: IManage for the kind of roll it was started as.
local function CanManage(ses)
    return IManage(ses.plain, ses.party)
end

-- DisasterZone extension: may award (demo: anyone). id (optional, 1.3): that roll's rules (a plain roll's master
-- looter may); without it, a roll started now.
function Roll:CanAward(id)
    if DemoOn() then return true end
    local ses = id ~= nil and self:Get(id) or nil
    if ses and not ses.demo then return CanManage(ses) end
    return RealCanAward()
end

-- DisasterZone extension: may end / unqueue this session (its starter, a council member; 1.3: whoever may award it,
-- the master looter of a plain roll).
function Roll:CanEnd(id)
    local ses = self:Get(id)
    if not ses then return false end
    return DemoOn() or ses.isLocal or (not ses.demo and CanManage(ses))
end

---------------------------------------------------------------------------
-- Public API: starting and ending
---------------------------------------------------------------------------

local function CopyCount(drop, itemID)
    local n = 0
    if type(drop) == "table" and type(drop.i) == "table" then
        for k = 1, MAX_COPIES do
            local id = drop.i[k]
            if id == nil then break end
            if tonumber(id) == itemID then n = n + 1 end
        end
    end
    return max(1, n)
end

-- Lowest copy without a (non-cancelled) session, else nil.
local function FreeCopy(itemID, s, copies)
    for c = 1, copies do
        if not Latest(itemID, s, c) then return c end
    end
    return nil
end

local function DropFields(drop)
    local s, b = "", nil
    if type(drop) == "table" then
        s = (type(drop.s) == "string" and #drop.s <= MAX_SOURCE_LEN) and drop.s or ""
        b = (type(drop.b) == "string" and #drop.b <= MAX_BOSS_LEN) and drop.b or ""
    end
    if b == nil then
        local Loot = ns.Loot
        b = (Loot and Loot.GetRecentBossKey and Loot:GetRecentBossKey()) or ""
    end
    return s, b
end

local function StartInternal(itemID, drop, copyIndex, link, quiet)
    itemID = tonumber(itemID)
    if not IsValidItemID(itemID) then return nil end
    if not Roll:CanStart() then
        if not quiet then
            ns:Print("%s", CannotStartText())
        end
        return nil
    end
    local s, b = DropFields(drop)
    local c = tonumber(copyIndex)
    if c then
        c = max(1, min(MAX_COPIES, floor(c)))
    else
        local copies = CopyCount(drop, itemID)
        c = FreeCopy(itemID, s, copies)
        if not c then
            -- Every copy already has a session: re-roll the first one that closed without a winner.
            for k = 1, copies do
                local last = Latest(itemID, s, k)
                if last and last.state == "closed" then
                    c = k
                    break
                end
            end
            if not c and s == "" then c = 1 end   -- no drop identity: simply a new roll
            if not c then return Latest(itemID, s, nil) end   -- rolling / queued / awarded already
        end
    end
    local cur = Latest(itemID, s, c)
    if cur then
        if cur.state == "open" or cur.state == "queued" then return cur end
        if cur.state == "awarded" and s ~= "" then
            if not quiet then
                ns:Print("%s was already awarded to %s.", ItemText(cur), Util.ShortName(cur.winner))
            end
            return nil
        end
        -- closed: a re-roll (for example to break a tie) runs as a fresh session
    end
    Prune()
    local ses = NewLocalSession(itemID, s, b, c, DemoOn(), link)
    if IsBusy() then
        ses.state = "queued"
        queue[#queue + 1] = ses
        Updated(ses)
        if not quiet then
            ns:Print("Queued the roll for %s (%d waiting).", ItemText(ses), #queue)
        end
        EnsureAdvance()
        return ses
    end
    OpenLocal(ses)
    return ses
end

-- Starts a roll for itemID of `drop` (nil: no drop, source ""), or queues it while another roll
-- is open. copyIndex (DisasterZone extension, optional): which copy when drop.i holds the item more
-- than once; nil picks the first copy without a session. Returns the session (or nil).
function Roll:Start(itemID, drop, copyIndex)
    return StartInternal(itemID, drop, copyIndex, nil, false)
end

-- Ledger awards of a drop's items that did not come from a roll (Award menu, loot chat). The same drop-scoped
-- matching as the drop panel (Ledger:AwardsForDrop): another raid group's award of the item is not this drop's.
local function OutsideAwards(drop, s)
    local counts = {}
    local Ledger = ns.Ledger
    if not (Ledger and Ledger.AwardsForDrop) then return counts end
    for itemID, list in pairs(Ledger:AwardsForDrop(drop) or {}) do
        counts[itemID] = #list
    end
    for _, ses in pairs(sessions) do
        if ses.s == s and ses.state == "awarded" and counts[ses.i] then
            counts[ses.i] = counts[ses.i] - 1
        end
    end
    return counts
end

-- Queues a roll for every item (every copy) of a drop that has no roll yet and was not awarded.
-- Returns the number of rolls started or queued.
function Roll:StartAll(drop)
    if type(drop) ~= "table" or type(drop.i) ~= "table" then return 0 end
    if not self:CanStart() then
        ns:Print("%s", CannotStartText())
        return 0
    end
    local s = DropFields(drop)
    local outside = OutsideAwards(drop, s)
    local seen, n = {}, 0
    for k = 1, MAX_COPIES do
        local raw = drop.i[k]
        if raw == nil then break end
        local id = tonumber(raw)
        if IsValidItemID(id) then
            seen[id] = (seen[id] or 0) + 1
            local c = seen[id]
            local skip = Latest(id, s, c) ~= nil
            if not skip and (outside[id] or 0) > 0 then
                outside[id] = outside[id] - 1
                skip = true
            end
            if not skip and StartInternal(id, drop, c, nil, true) then n = n + 1 end
        end
    end
    if n > 0 then
        ns:Print("Rolling %d item(s), one after another.", n)
    else
        ns:Print("Nothing left to roll for in this drop.")
    end
    return n
end

-- Ends an open roll early (starter / council; a plain roll's master looter), or removes a queued one.
function Roll:End(id)
    local ses = self:Get(id)
    if not ses then return false end
    if not self:CanEnd(id) then
        ns:Print("Only the player who started the roll or the loot council can end it%s.",
            ses.plain and " (or the master looter)" or "")
        return false
    end
    if ses.state == "queued" then return CancelSession(ses) end
    if ses.state ~= "open" then return false end
    CloseSession(ses)
    if not ses.demo then Send({ t = "RE", id = ses.id }) end
    return true
end

---------------------------------------------------------------------------
-- Public API: raider responses and rolls
---------------------------------------------------------------------------

-- A crafting material (Materials): the RR also says how many I hold (h) and the craft I want it for (f). Older
-- clients ignore the two fields.
WithHoldings = function(msg, ses)
    local M = ns.Materials
    if not (M and M.OwnReport and M:IsMaterial(ses.i)) then return msg end
    local h, f = M:OwnReport(ses.i)
    if h then msg.h, msg.f = h, f end
    return msg
end

-- Roll button: /roll 1-100 plus RR "roll". The roll itself is read back from the system message.
function Roll:RespondRoll(id)
    local ses = self:Get(id)
    local me = Util.PlayerKey()
    if not ses or ses.state ~= "open" or not me then return false end
    ses.responses[me] = "roll"
    if not ses.demo then Send(WithHoldings({ t = "RR", id = ses.id, r = "roll" }, ses)) end
    Updated(ses)
    if type(RandomRoll) == "function" then
        local ok, err = pcall(RandomRoll, ROLL_MIN, ROLL_MAX)
        if not ok then ns:Debug("RandomRoll failed: %s", tostring(err)) end
    end
    return true
end

function Roll:RespondPass(id)
    local ses = self:Get(id)
    local me = Util.PlayerKey()
    if not ses or not me or not IsAccepting(ses) then return false end
    ses.responses[me] = "pass"
    if not ses.demo then Send(WithHoldings({ t = "RR", id = ses.id, r = "pass" }, ses)) end
    Updated(ses)
    return true
end

-- An addon user's intent (RR), or a demo member's pass. Returns true if recorded.
function Roll:OnResponse(key, id, r)
    key = Util.NormalizeName(key)
    local ses = self:Get(id)
    if not key or not ses or (r ~= "roll" and r ~= "pass") then return false end
    if not IsAccepting(ses) or not Util.IsInMyGroup(key) then return false end
    if ses.responses[key] ~= r then
        ses.responses[key] = r
        if ses.state == "awarded" then ses.final = nil end
        Updated(ses)
    end
    return true
end

-- Parses a /roll CHAT_MSG_SYSTEM line without recording it (used by the minigames).
-- Returns key, value, lo, hi or nil (not a roll line, or the roller is not in my group).
function Roll:ParseRollLine(text)
    if type(text) ~= "string" or text == "" or #text > 255 then return nil end
    local pat = GetRollPattern()
    if not pat then return nil end
    local name, v, lo, hi = text:match(pat)
    v, lo, hi = tonumber(v), tonumber(lo), tonumber(hi)
    if not name or not v or not lo or not hi then return nil end
    local key = ResolveRoller(name)
    if not key and Util.NormalizeName(name) == Util.PlayerKey() then key = Util.PlayerKey() end   -- solo
    if not key then return nil end
    return key, v, lo, hi
end

-- Parses a CHAT_MSG_SYSTEM line; a /roll counts for the open session (or the one that closed
-- less than 2s ago). Returns true if the roll was recorded.
function Roll:OnSystemMessage(text)
    if type(text) ~= "string" or text == "" or #text > 255 then return false end
    local pat = GetRollPattern()
    if not pat then return false end
    local name, v, lo, hi = text:match(pat)
    v, lo, hi = tonumber(v), tonumber(lo), tonumber(hi)
    if not name or not v or not lo or not hi then return false end
    local key = ResolveRoller(name)
    if not key then return false end
    local ses = AcceptingSession()
    if ses then
        AddRoll(ses, key, v, lo, hi)
        return true
    end
    RememberEarly(key, v, lo, hi)   -- the RS may still be on its way
    return false
end

---------------------------------------------------------------------------
-- Public API: award
---------------------------------------------------------------------------

-- areason (optional): the award reason chosen with the award (Addendum G), carried to Finish.
local function ShowPopup(which, ses, key, areason)
    if not ns.Popup then return false end
    local label = ns.ReasonLabel(areason)
    ns.Popup:Show(which, ItemText(ses), NameText(key) .. (label and (" (" .. label .. ")") or ""),
        { id = ses.id, key = key, itemID = ses.i, reason = areason })
    return true
end

-- 1.3.5, prized items (Core/Prized.lua): may this award go ahead? A player who breaks a required loot rule needs a
-- reason everyone sees (the override pop-up asks for it, then `retry(why)` awards again); the item's agree count
-- (its vote rule, of the council members in the raid; an override: every one of them without a vote rule) must be
-- reached by the council's votes for that player. Disenchant / guild bank hand-outs skip the rules. On success the
-- award's facts wait on the session (ses.prized) until Finish records them.
local function PrizedGate(ses, key, areason, why, retry)
    ses.prized = nil
    local P = ns.Prized
    local rec = not ses.plain and P and P.ForItem and P:ForItem(ses.i) or nil
    if not rec or areason == "de" or areason == "bank" then return true end
    local row
    for _, r in ipairs(BuildResults(ses)) do
        if r.key == key then row = r break end
    end
    local check = (row and row.prz) or P:Check(rec, key, {})
    local broken = check.ok == false
    if broken and not why then
        if ns.Popup and retry then
            ses.przRetry = retry
            ns.Popup:Show("DISASTERZONE_PRIZED_OVERRIDE", ItemText(ses), NameText(key) .. "?\n\nBreaks: " ..
                tostring(check.fail or "a loot rule"), { id = ses.id, key = key })
        end
        return false
    end
    local present = P:PresentCouncil()
    local need = P:NeededVotes(rec, #present, broken)
    local votes = row and row.votes or 0
    if need > 0 and votes < need then
        ns:Print("%s: %s needs %d of the %d council members here to vote for them (%d so far).", ItemText(ses),
            Util.ShortName(key), need, #present, votes)
        return false
    end
    ses.prized = { ov = broken and P:Broken(check) or nil, why = broken and why or nil, ag = votes, of = #present }
    return true
end

-- Resolved only by a loot message (Addendum C): the item was handed out, but nobody has recorded /
-- announced the award yet. An explicit award (Roll:Award, MarkAwardedExternally, RW) still goes through.
local function LootMarked(ses)
    return ses.state == "awarded" and ses.via == "loot"
end

-- Copies of ses's item in its drop that no award of this item from that drop accounts for (0 or more). A loot
-- message naming someone other than the recorded winner is only a conflict when no copy is left over (with two
-- copies and one roll, the other copy simply went to someone else).
local function SpareCopies(ses)
    local copies = 1
    local Loot = ns.Loot
    if type(ses.s) == "string" and ses.s ~= "" and Loot and Loot.GetHistory then
        local hist = Loot:GetHistory()
        for k = #hist, 1, -1 do
            local d = hist[k]
            if type(d) == "table" and d.s == ses.s and type(d.i) == "table" then
                local n = 0
                for _, id in ipairs(d.i) do
                    if tonumber(id) == ses.i then n = n + 1 end
                end
                copies = math.max(1, n)
                break
            end
        end
    end
    local awarded = 0
    for _, o in pairs(sessions) do
        if o.i == ses.i and o.s == ses.s and o.state == "awarded" and (o.demo and true or false) == (ses.demo and true or false) then
            awarded = awarded + 1
        end
    end
    return copies - awarded
end

-- (0.5) The loot message says `other` received the item of an award to someone else, and no copy is left over:
-- remember it on the session (the drop panel offers the fix) and tell the council / master looter.
local NoteLootConflict   -- forward declaration (loot-message resolution)

local function FlagLootConflict(ses, other)
    if ses.demo or type(other) ~= "string" or other == ses.winner or SpareCopies(ses) > 0 then return end
    ses.lootOther = other
    ses.lootOtherTs = GetServerTime()
    if AmRealCouncil() or Util.IsPlayerMasterLooter() then
        ns:Print("%s The loot message says %s received %s, but it was awarded to %s. Fix the loot log in the drop "
            .. "panel (Award... menu of that item).", "|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:0|t",
            Util.ShortName(other), ItemText(ses), Util.ShortName(ses.winner))
    end
end

-- Bag loot (Loot.lua): key picked a copy of itemID up under Free for All and holds it for the council.
local function HeldBy(itemID, key)
    local Loot = ns.Loot
    return (Loot and Loot.IsHeldBy and Loot:IsHeldBy(itemID, key)) and true or false
end

-- Session still awardable for a popup's data (someone else may have awarded it meanwhile).
local function CheckAwardable(data)
    if type(data) ~= "table" then return nil end
    local ses = Roll:Get(data.id)
    if not ses or type(data.key) ~= "string" then return nil end
    if ses.state == "awarded" and not LootMarked(ses) then
        ns:Print("%s was already awarded to %s.", ItemText(ses), Util.ShortName(ses.winner))
        return nil
    end
    if ses.state ~= "closed" and ses.state ~= "open" and not LootMarked(ses) then return nil end
    return ses
end

-- An explicit award of ses to key while a loot message for key was matched to a sibling (another copy
-- of the same item and drop): that message was this award's hand-out. The sibling goes back to the
-- state it had before (closed; a queued roll of mine is queued again).
local function ReclaimLoot(ses, key)
    if ses.looted then return end
    for _, other in pairs(sessions) do
        if other ~= ses and other.i == ses.i and other.s == ses.s and LootMarked(other) and other.winner == key then
            other.winner, other.given, other.via, other.looted = nil, false, nil, nil
            other.final, other.awardedAt = nil, nil
            if other.lootPrev == "queued" and other.isLocal then
                other.state = "queued"
                tinsert(queue, 1, other)
            else
                other.state = "closed"
            end
            other.lootPrev = nil
            ses.looted = true
            Updated(other)
            if other.state == "queued" then EnsureAdvance() end
            return
        end
    end
end

-- First n bytes of s without a cut-off UTF-8 sequence at the end.
local function CutUtf8(s, n)
    if #s <= n then return s end
    s = s:sub(1, n)
    for i = #s, max(1, #s - 3), -1 do
        local b = s:byte(i)
        if b < 128 then break end
        if b >= 192 then
            local need = (b >= 240 and 4) or (b >= 224 and 3) or 2
            if #s - i + 1 < need then s = s:sub(1, i - 1) end
            break
        end
    end
    return s
end

-- A note typed with an award (the drop panel's "Someone else..." dialog): one line, no escape codes.
local function CleanNote(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("[%c|]", " ")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

-- extraNote (optional, cleaned): the awarder's own note; the ledger / RW note becomes "<note>; roll 80"
-- (at most MAX_NOTE_LEN bytes, the roll part is kept).
-- areason (optional): the award reason (Addendum G); nil = from the winner's BiS tier.
local function Finish(ses, key, given, extraNote, areason)
    local fromLoot = LootMarked(ses)
    if (ses.state == "awarded" and not fromLoot) or ses.state == "cancelled" or ses.state == "queued" then return false end
    if ses.state == "open" then CloseSession(ses) end
    local me = Util.PlayerKey()
    -- Upgrading a loot mark: the item already went to that player (hand-out counts as given).
    if fromLoot and ses.winner == key then given = true end
    -- Bag loot (Free for All): the winner picked the item up themselves and holds it already.
    local heldByWinner = not ses.demo and HeldBy(ses.i, key)
    if heldByWinner then given = true end
    -- The loot message named someone else (a misclick in the master-loot menu, or a trade to follow).
    local lootWinner = (fromLoot and ses.winner ~= key) and ses.winner or nil
    if not fromLoot then ReclaimLoot(ses, key) end

    -- Tier and votes of the winner before the award is recorded (the award would demote them).
    local tier, votes = TIER_OTHER, 0
    for _, r in ipairs(BuildResults(ses)) do
        if r.key == key then
            tier, votes = r.tier, r.votes or 0
            break
        end
    end
    -- A plain roll's winner has no BiS tier: no reason unless the awarder picked one ("roll" in the chat line).
    local reason = ns.AWARD_REASON[areason] and areason or (not ses.plain and ns.ReasonForTier(tier) or nil)
    -- A prized item given against a rule: the loot log's note starts with the reason (the item's history has it whole).
    local przInfo = ses.prized
    ses.prized = nil
    if przInfo and przInfo.why and not extraNote then extraNote = "override: " .. przInfo.why end
    local rr = ses.rolls[key]
    local rollText, note
    if rr and rr.roll then
        rollText = "rolled " .. rr.roll
        note = "roll " .. rr.roll
        if rr.invalid then
            local range = " (" .. tostring(rr.min) .. "-" .. tostring(rr.max) .. ")"
            rollText = rollText .. range
            note = note .. range
        end
    else
        rollText = "no roll"
        note = "roll: no roll"
    end
    if votes > 0 then
        local vt = votes == 1 and "1 vote" or (votes .. " votes")
        rollText = (rr and rr.roll) and (vt .. ", " .. rollText) or vt
        note = note .. "; " .. vt
    end
    if extraNote then
        local room = MAX_NOTE_LEN - #note - 2
        local own = room > 0 and CutUtf8(extraNote, room) or ""
        if own ~= "" then note = own .. "; " .. note end
    end

    ses.state = "awarded"
    ses.winner = key
    ses.given = given and true or false
    ses.via = nil
    ses.looted = (ses.looted or fromLoot or heldByWinner) or nil
    ses.lootPrev = nil
    ses.awardedBy = me
    ses.awardedAt = GetTime()
    ses.awardTs = GetServerTime()
    ses.reason = reason
    ses.final = nil

    -- The ledger is council-only. Demo sessions use the in-memory demo ledger; real sessions always
    -- the real one (also while demo mode is on), under an id every council client derives from RW.
    -- Party (dungeon mode) rolls are 5-man loot: dg on every council client alike.
    local Ledger = ns.Ledger
    if ses.demo then
        if Ledger and Ledger.Award then Ledger:Award(ses.i, key, ses.b, note, nil, reason) end
    elseif Ledger and Ledger.RecordRollAward and AmRealCouncil() then
        Ledger:RecordRollAward(ses.id, ses.i, key, ses.b, note, me, ses.awardTs, true, ses.party and true or false,
            reason)
    end
    -- 1.3.5: a prized item's hand-out goes to the whole guild (its cooldown, queue and pair rules and its history).
    local P = ns.Prized
    if not ses.plain and P and P.ForItem and P:ForItem(ses.i) and reason ~= "de" and reason ~= "bank" then
        local info = przInfo or {}
        P:RecordGiven(ses.i, key, { ov = info.ov, why = info.why, ag = info.ag or votes, of = info.of })
    end
    if not ses.demo then
        -- r (Addendum G, ignored by older clients): the award reason, so every council client logs the same one.
        Send({ t = "RW", id = ses.id, w = key, g = ses.given, at = ses.awardTs, n = note, r = reason }, true)
    end
    local body = strformat("%s -> %s (%s, %s)", ItemText(ses), Util.ShortName(key), rollText,
        ns.ReasonLabel(reason) or "roll")
    if ses.demo then
        Announce(body, true, " |cff999999(demo: only shown to you)|r")
    else
        Announce(body, not AnnounceOn())
    end
    if type(lootWinner) == "string" then
        ns:Print("Note: the loot message says %s received %s; recorded as awarded to %s.",
            Util.ShortName(lootWinner), ItemText(ses), Util.ShortName(key))
        FlagLootConflict(ses, lootWinner)
    end
    ses.final = BuildResults(ses)
    Updated(ses)
    return true
end

-- why: the hand-out failure; areason: the award reason to keep for the "award anyway" popup.
local function FallbackConfirm(ses, key, why, areason)
    ns:Print("Could not hand %s to %s: %s.", ItemText(ses), Util.ShortName(key), tostring(why or "unknown error"))
    Util.After(0.1, function()
        if ses.state == "closed" or LootMarked(ses) then ShowPopup("DISASTERZONE_CONFIRM_AWARD", ses, key, areason) end
    end)
end

-- DISASTERZONE_GIVE_ITEM accepted: master-loot the item, then record; on failure ask to award anyway.
function Roll:ConfirmGive(data)
    local ses = CheckAwardable(data)
    if not ses then return end
    local key = data.key
    local areason = data.reason
    if LootMarked(ses) then
        -- Handed out meanwhile (loot message): record the award, never give a second copy.
        Finish(ses, key, false, nil, areason)
        return
    end
    local Loot = ns.Loot
    if not (Loot and Loot.GiveItem) then
        FallbackConfirm(ses, key, "master loot is not available", areason)
        return
    end
    -- The award is recorded, sent (RW) and announced only once the server handed the item over; a refused
    -- hand-out (bags full, unique item, out of range) offers to record the award without it.
    local ok, reason = Loot:GiveItem(ses.i, key, function(done, why)
        if ses.state == "awarded" and not LootMarked(ses) then
            if not done then return end
            if ses.winner == key then
                -- Someone recorded the same award meanwhile: it is handed out now.
                if not ses.given then
                    ses.given = true
                    Updated(ses)
                end
                return
            end
            -- Another award crossed my hand-out: the item physically went to key, so that one stands.
            local lost = ses.winner
            local Ledger = ns.Ledger
            if AmRealCouncil() and Ledger and Ledger.VoidRollAward then Ledger:VoidRollAward(ses.id, lost) end
            ns:Print("Two awards of %s crossed: it goes to %s (handed out), not %s.", ItemText(ses),
                Util.ShortName(key), Util.ShortName(lost))
            ses.state, ses.winner, ses.given, ses.via, ses.final = "closed", nil, false, nil, nil
        end
        if done then
            Finish(ses, key, true, nil, areason)
        else
            FallbackConfirm(ses, key, why, areason)
        end
    end)
    if ok == false then
        FallbackConfirm(ses, key, reason, areason)
    end
    -- ok == nil: GiveMasterLoot was sent; the callback finishes (or falls back) once the server answered.
end

-- DISASTERZONE_CONFIRM_AWARD accepted: record and announce (the item is handed out by hand).
function Roll:ConfirmAward(data)
    local ses = CheckAwardable(data)
    if ses then Finish(ses, data.key, false, nil, data.reason) end
end

-- Awards a session's item to key (CanManage: the council; a plain roll's master looter). Closes an open session
-- first, then asks for confirmation: DISASTERZONE_GIVE_ITEM when I can master-loot it right now, else
-- DISASTERZONE_CONFIRM_AWARD.
-- areason (optional, Addendum G): the award reason (an ns.AWARD_REASONS key); nil = from the winner's BiS tier.
-- why (optional, 1.3.5): the reason for awarding a prized item against its loot rules (the override pop-up's).
function Roll:Award(id, key, areason, why)
    local ses = self:Get(id)
    key = Util.NormalizeName(key)
    if not ses or not key then return false end
    if not (ses.demo and self:CanAward() or (not ses.demo and CanManage(ses))) then
        ns:Print("%s", CannotAwardText(ses.plain, ses.party))
        return false
    end
    if ses.state == "awarded" and not LootMarked(ses) then
        ns:Print("%s was already awarded to %s.", ItemText(ses), Util.ShortName(ses.winner))
        return false
    end
    if ses.state ~= "open" and ses.state ~= "closed" and not LootMarked(ses) then return false end
    if not ns.AWARD_REASON[areason] then areason = nil end
    if not PrizedGate(ses, key, areason, why, function(w) Roll:Award(id, key, areason, w) end) then return false end
    if ses.state == "open" then
        CloseSession(ses)
        if not ses.demo then Send({ t = "RE", id = ses.id }) end
    end
    local Loot = ns.Loot
    -- A loot-marked session was already handed out: never master-loot another copy for it.
    local canGive = not ses.demo and not LootMarked(ses) and Loot and Loot.CanGiveItem and Loot:CanGiveItem(ses.i)
    if not ns.AWARD_REASON[areason] then areason = nil end
    if canGive then
        local candidate = Loot.IsLootCandidate and Loot:IsLootCandidate(ses.i, key)
        if candidate == false then
            ns:Print("%s is not eligible for this loot (out of range or not in the raid).", Util.ShortName(key))
            return ShowPopup("DISASTERZONE_CONFIRM_AWARD", ses, key, areason)
        end
        return ShowPopup("DISASTERZONE_GIVE_ITEM", ses, key, areason)
    end
    return ShowPopup("DISASTERZONE_CONFIRM_AWARD", ses, key, areason)
end

-- Addendum C §23.2: an award made outside the roll UI (the drop panel's plain "Award..." menu /
-- "Someone else...") for an item that has a roll session. Same state change as Roll:Award's final step
-- (ledger entry on council clients, RW, announce respecting roll.announce) without the give / confirm
-- popups: the caller already confirmed.
-- Returns true when the award went through the roll; the ledger entry is written here (or already
-- exists), so the caller must NOT also call Ledger:Award. Returns false, reason when the caller should
-- record the award itself: "unknown" (no such session / bad key), "denied" (no permission), "queued"
-- (the roll had not started; it is removed from the queue), "cancelled", "awarded" (already awarded to
-- someone else).
-- note (optional): the awarder's note, kept in front of the roll note ("offspec; roll 80").
-- areason (optional, Addendum G): the award reason; nil = from the winner's BiS tier.
function Roll:MarkAwardedExternally(id, key, note, areason)
    local ses = self:Get(id)
    key = Util.NormalizeName(key)
    if not ses or not key then return false, "unknown" end
    if not (ses.demo and self:CanAward() or (not ses.demo and CanManage(ses))) then return false, "denied" end
    if ses.state == "queued" then
        CancelSession(ses)
        return false, "queued"
    end
    if ses.state == "cancelled" then return false, "cancelled" end
    if ses.state == "awarded" and not LootMarked(ses) then
        if ses.winner == key then return true end   -- already recorded (my click or someone's RW)
        return false, "awarded"
    end
    -- 1.3.5: a prized item's rules and agree count (an override asks why, then awards through Roll:Award)
    if not ns.AWARD_REASON[areason] then areason = nil end
    if not PrizedGate(ses, key, areason, nil, function(w) Roll:Award(id, key, areason, w) end) then
        return false, "prized"
    end
    if ses.state == "open" then
        CloseSession(ses)
        if not ses.demo then Send({ t = "RE", id = ses.id }) end
    end
    if Finish(ses, key, false, CleanNote(note), areason) then return true end
    return false, "unknown"
end

---------------------------------------------------------------------------
-- Council votes (Addendum G §42)
---------------------------------------------------------------------------

-- May I vote on this session: a real council member in its group (demo sessions: anyone), while the roll is open
-- or closed and not awarded yet.
function Roll:CanVote(id)
    local ses = self:Get(id)
    if not ses or (ses.state ~= "open" and ses.state ~= "closed") or ses.plain then return false end
    if ses.demo then return DemoOn() end
    return AmRealCouncil() and GroupChannel() ~= nil
end

-- The candidate I voted for (a key), or nil.
function Roll:GetMyVote(id)
    local ses = self:Get(id)
    local me = Util.PlayerKey()
    return ses and me and ses.votes[me] or nil
end

-- Records voter's vote for key (nil = the vote is withdrawn). Checks the session and the candidate, not the
-- voter's council seat (the RV handler and the local API do). Returns true if it changed anything.
local function RecordVote(ses, voter, key)
    if ses.state ~= "open" and ses.state ~= "closed" then return false end
    if key ~= nil and not InGroupFor(ses, key) then return false end
    if ses.votes[voter] == key then return false end
    if key ~= nil and ses.votes[voter] == nil then
        local n = 0
        for _ in pairs(ses.votes) do n = n + 1 end
        if n >= MAX_VOTES then return false end
    end
    ses.votes[voter] = key
    Updated(ses)
    return true
end

-- Votes for key (council, a member of the group), or withdraws my vote (key nil, or voting for my current pick
-- again). One vote per council member; it can be moved until the item is awarded. Sent to the group (RV).
function Roll:Vote(id, key)
    local ses = self:Get(id)
    local me = Util.PlayerKey()
    if not ses or not me then return false end
    if not self:CanVote(id) then
        if ses.state == "open" or ses.state == "closed" then ns:Print("Only loot council members can vote.") end
        return false
    end
    key = key and Util.NormalizeName(key) or nil
    if key and ses.votes[me] == key then key = nil end
    if not RecordVote(ses, me, key) then return false end
    if not ses.demo then Send({ t = "RV", id = ses.id, k = key or "" }) end
    return true
end

-- A demo council member's vote (Demo:SimulateRolls): the same path as a real vote, never sent.
function Roll:OnDemoVote(voter, id, key)
    local ses = self:Get(id)
    if not ses or not ses.demo or not DemoOn() then return false end
    return RecordVote(ses, voter, key and Util.NormalizeName(key) or nil)
end

-- Loot-message resolution (Addendum C §23.1): state "awarded", winner, given, via = "loot", results
-- frozen. An open session is closed on the spot (no RE: every client sees the same loot message).
-- Nothing is recorded here (council clients record the loot line themselves) and no RW is sent.
local function MarkAwarded(ses, key, given, via)
    local prev = ses.state
    if prev == "open" then
        local now = GetTime()
        if not ses.endsAt or ses.endsAt > now then ses.endsAt = now end
        ses.closedAt = now
    elseif prev == "queued" then
        RemoveFromQueue(ses)
    end
    ses.lootPrev = prev
    ses.state = "awarded"
    ses.winner = key
    ses.given = given and true or false
    ses.via = via
    ses.looted = (via == "loot") or nil
    ses.awardedBy = nil
    ses.awardedAt = GetTime()
    ses.awardTs = nil
    ses.final = BuildResults(ses)
    Updated(ses)
    if prev == "open" then OnSessionFinished(ses) end
end

local STATE_PREF = { open = 1, closed = 2, queued = 3 }

-- A loot message matched no unresolved session: when it contradicts a recent explicit award of that item (someone
-- else received it and no copy is left over), flag that award.
NoteLootConflict = function(itemID, key)
    local now = GetTime()
    local best
    for _, ses in pairs(sessions) do
        if not ses.demo and ses.i == itemID and ses.state == "awarded" and ses.via ~= "loot" and not ses.looted
            and ses.winner ~= key and now - (ses.createdAt or now) <= LOOT_MATCH_AGE
            and (not best or ses.seq > best.seq) then
            best = ses
        end
    end
    if best then
        FlagLootConflict(best, key)
        Updated(best)
    end
end

-- DisasterZone 0.5: settles a flagged loot-message conflict (session.lootOther). choice "passing": the player named by
-- the loot message passes the item on to the recorded winner (their auto entries of it are voided); "keeps": they
-- keep it (the roll award is voided, the session shows them as the winner). Council only (log writes).
function Roll:ResolveLootConflict(id, choice)
    local ses = self:Get(id)
    if not ses or type(ses.lootOther) ~= "string" or ses.state ~= "awarded" then return false end
    local Ledger = ns.Ledger
    if not (AmRealCouncil() and Ledger) then
        ns:Print("Only loot council members can fix the loot log.")
        return false
    end
    local other = ses.lootOther
    if choice == "passing" then
        if Ledger.VoidAutoNear then Ledger:VoidAutoNear(other, ses.i, ses.lootOtherTs or GetServerTime()) end
        ns:Print("Loot log: %s stays awarded to %s (%s passes it on).", ItemText(ses), Util.ShortName(ses.winner),
            Util.ShortName(other))
    elseif choice == "keeps" then
        if Ledger.VoidRollAward then Ledger:VoidRollAward(ses.id, ses.winner) end
        ns:Print("Loot log: %s goes to %s (the award to %s was voided).", ItemText(ses), Util.ShortName(other),
            Util.ShortName(ses.winner))
        ses.winner, ses.via, ses.looted, ses.given = other, "loot", true, true
        ses.final = BuildResults(ses)
    else
        return false
    end
    ses.lootOther, ses.lootOtherTs = nil, nil
    Updated(ses)
    return true
end

-- Bag loot: the awards to key that are not handed out yet, as item ids (one per award, oldest first).
function Roll:GetOwed(key)
    key = Util.NormalizeName(key)
    local list, out = {}, {}
    if not key then return out end
    for _, ses in pairs(sessions) do
        if not ses.demo and ses.state == "awarded" and ses.via ~= "loot" and not ses.given and ses.winner == key then
            list[#list + 1] = ses
        end
    end
    tsort(list, function(a, b) return a.seq < b.seq end)
    for k, ses in ipairs(list) do out[k] = ses.i end
    return out
end

-- Bag loot: key received itemID (traded by its holder, or picked up after it was awarded to them). The oldest
-- award of it to key that is not handed out yet becomes handed out. tell: I traded it myself, so the raid is told
-- (the same RW again with g set; 1.3: also when I am a plain raider holding it: receivers take only the "handed out"
-- flag from the holder, and forget that I hold it). Returns the session, or nil when no award matched.
function Roll:MarkGiven(itemID, key, tell)
    itemID = tonumber(itemID)
    key = Util.NormalizeName(key)
    if not itemID or not key then return nil end
    local me = Util.PlayerKey()
    local holder = tell and me ~= nil and HeldBy(itemID, me)   -- (read before the trade drops my held entry)
    local pick
    for _, ses in pairs(sessions) do
        if not ses.demo and ses.i == itemID and ses.state == "awarded" and ses.via ~= "loot" and not ses.given
            and ses.winner == key and (not pick or ses.seq < pick.seq) then
            pick = ses
        end
    end
    if not pick then return nil end
    pick.given = true
    pick.looted = true
    pick.lootOther, pick.lootOtherTs = nil, nil
    Updated(pick)
    if tell and (holder or CanManage(pick)) then
        Send({ t = "RW", id = pick.id, w = key, g = true, at = pick.awardTs, r = pick.reason }, true)
    end
    return pick
end

-- Sessions of one drop share a group; a session without a drop identity is its own group.
local function DropGroup(ses)
    if type(ses.s) == "string" and ses.s ~= "" then return "s:" .. ses.s end
    return "id:" .. tostring(ses.id)
end

-- A loot message says `key` received itemID (every client, council or not). Resolves the most relevant
-- session of that item: an award to key no loot message has matched yet (this is its hand-out), else
-- the best unresolved session started in the last 15 minutes (open, then closed, then queued; newest
-- drop first; among copies of a drop the lowest copy), which is marked awarded via "loot". Queued
-- re-rolls of the same copy are cancelled. Tokens: the loot line names the rolled token itself.
-- Returns the session, or nil when nothing matched.
function Roll:OnItemLooted(itemID, key)
    itemID = tonumber(itemID)
    key = Util.NormalizeName(key)
    if not IsValidItemID(itemID) or not key then return nil end
    local now = GetTime()
    local function Recent(ses)
        return not ses.demo and ses.i == itemID and now - (ses.createdAt or now) <= LOOT_MATCH_AGE
    end

    local awarded
    for _, ses in pairs(sessions) do
        if Recent(ses) and ses.state == "awarded" and ses.via ~= "loot" and not ses.looted and ses.winner == key
            and (not awarded or ses.seq < awarded.seq) then
            awarded = ses
        end
    end
    if awarded then
        awarded.looted = true
        return awarded
    end

    local cands, newest = {}, {}
    for _, ses in pairs(sessions) do
        if Recent(ses) and STATE_PREF[ses.state] then
            cands[#cands + 1] = ses
            local g = DropGroup(ses)
            if not newest[g] or ses.seq > newest[g] then newest[g] = ses.seq end
        end
    end
    if #cands == 0 then
        NoteLootConflict(itemID, key)
        return nil
    end
    tsort(cands, function(a, b)
        local pa, pb = STATE_PREF[a.state], STATE_PREF[b.state]
        if pa ~= pb then return pa < pb end
        local na, nb = newest[DropGroup(a)], newest[DropGroup(b)]
        if na ~= nb then return na > nb end
        if a.c ~= b.c then return (a.c or 1) < (b.c or 1) end
        return a.seq > b.seq
    end)
    local pick = cands[1]
    MarkAwarded(pick, key, true, "loot")
    for _, ses in pairs(sessions) do
        if ses ~= pick and ses.state == "queued" and ses.i == pick.i and ses.s == pick.s and ses.c == pick.c then
            CancelSession(ses)
        end
    end
    return pick
end

---------------------------------------------------------------------------
-- Network (§19.1 message table). All RAID / alert class.
---------------------------------------------------------------------------

local function ValidId(id)
    return type(id) == "string" and id ~= "" and #id <= MAX_ID_LEN
end

-- The master looter, read live in a raid (the loot method can change without a roster update).
local function MasterLooterKey()
    if IsInRaid() then
        local n = min(tonumber((GetNumGroupMembers())) or 0, 40)
        for i = 1, n do
            local name, _, _, _, _, _, _, _, _, _, isML = GetRaidRosterInfo(i)
            if isML and type(name) == "string" and name ~= "" and name ~= UNKNOWNOBJECT then
                return Util.NormalizeName(name)
            end
        end
        return nil
    end
    for key, g in pairs(type(Util.group) == "table" and Util.group or {}) do
        if type(g) == "table" and g.isML then return key end
    end
    return nil
end

-- RT {id, k = {[key] = tier}} (DisasterZone 0.2): a council client tells a non-council starter / master
-- looter the BiS tiers (1 main, 2 alt, 3 off spec) of this item's wanters in the raid, so its suggestion follows
-- the same priority. Only they are told; the lists themselves stay with the council.
SendTiers = function(ses)
    if ses.demo or ses.plain or DemoOn() or not AmRealCouncil() or type(ses.snap) ~= "table" then return end
    local targets = {}
    if ses.starter and not IsRealCouncil(ses.starter) then targets[ses.starter] = true end
    local ml = MasterLooterKey()
    if ml and not IsRealCouncil(ml) then targets[ml] = true end
    if next(targets) == nil then return end
    local k, n = {}, 0
    local sibWon = SiblingWinners(ses) or {}
    for key, s in pairs(ses.snap) do
        if s.tier < TIER_OTHER and n < MAX_RT_ENTRIES and InGroupFor(ses, key) and not sibWon[key] then
            k[key] = s.tier
            n = n + 1
        end
    end
    -- Addendum F §38 (DisasterZone 0.4, ignored by older clients): lc = {[key] = 1} for players whose BiS list
    -- changed while the raid's lists were locked, so the starter's suggestion skips them too.
    local lc, nlc = nil, 0
    local Store = ns.Store
    if Store and Store.GetLockFlags then
        for key in pairs(Store:GetLockFlags()) do
            if nlc < MAX_RT_ENTRIES and InGroupFor(ses, key) then
                lc = lc or {}
                lc[key] = 1
                nlc = nlc + 1
            end
        end
    end
    if n == 0 and nlc == 0 then return end
    local Comm = ns.Comm
    for target in pairs(targets) do
        if not Util.IsMe(target) and Comm and Comm.Send then
            Comm:Send({ t = "RT", id = ses.id, k = k, lc = lc }, "WHISPER", target, "alert")
        end
    end
end

local function OnRollTiers(sender, msg, dist)
    if DemoOn() or dist ~= "WHISPER" or type(msg) ~= "table" or not ValidId(msg.id) then return end
    if AmRealCouncil() or not IsRealCouncil(sender) or not InRealGroup(sender) then return end
    local ses = sessions[msg.id]
    if not ses or ses.demo or type(msg.k) ~= "table" then return end
    local tiers = ses.remoteTiers or {}
    local n, changed = 0, false
    local function Key(k)
        return (type(k) == "string" and #k <= MAX_ID_LEN and not k:find("[%c|]")) and Util.NormalizeName(k) or nil
    end
    for k, t in pairs(msg.k) do
        n = n + 1
        if n > MAX_RT_ENTRIES then break end
        local key = Key(k)
        -- (t == 3 = off-spec list, Addendum H; older senders only send 1 / 2, older receivers skip 3)
        if key and (t == 1 or t == 2 or t == 3) and (not tiers[key] or t < tiers[key]) then
            tiers[key] = t
            changed = true
        end
    end
    -- lc (Addendum F §38): players flagged "changed during lock" by that council member.
    if type(msg.lc) == "table" then
        local lock = ses.remoteLock or {}
        n = 0
        for k, v in pairs(msg.lc) do
            n = n + 1
            if n > MAX_RT_ENTRIES then break end
            local key = Key(k)
            if key and v == 1 and not lock[key] then
                lock[key] = true
                changed = true
            end
        end
        ses.remoteLock = lock
    end
    if changed then
        ses.remoteTiers = tiers
        Updated(ses)
    end
end

-- RS {id, i, s, b, d, ts, c, pl}: sender in my group; in a raid the council or the master looter (1.3: like
-- Roll:CanStart, no raid assistants), in a 5-man party also the party leader.
local function OnRollStart(sender, msg, dist)
    if DemoOn() or not GroupDist(dist) or type(msg) ~= "table" then return end
    if dist == "RAID" then
        if not (IsRealCouncil(sender) or IsMasterLooter(sender)) then return end
        local GR = ns.GroupRules
        if GR and GR.IsFeatureOn and not GR:IsFeatureOn("rolls", true) then return end
    elseif not (IsRealCouncil(sender) or IsLeadOrML(sender)) then
        return
    end
    local id = msg.id
    if not ValidId(id) or sessions[id] then return end
    local itemID = tonumber(msg.i)
    if not IsValidItemID(itemID) then return end
    local s = (type(msg.s) == "string" and #msg.s <= MAX_SOURCE_LEN) and msg.s or ""
    local b = (type(msg.b) == "string" and #msg.b <= MAX_BOSS_LEN) and msg.b or ""
    if b ~= "" and not (ns.ItemDB and ns.ItemDB.GetBossRef and ns.ItemDB:GetBossRef(b)) then b = "" end
    local d = tonumber(msg.d)
    d = d and max(MIN_REMOTE_DURATION, min(MAX_DURATION, floor(d))) or DEFAULT_DURATION
    local c = tonumber(msg.c)
    c = c and max(1, min(MAX_COPIES, floor(c))) or 1
    local now = GetServerTime()
    local ts = tonumber(msg.ts)
    -- Clash resolution only needs same-moment starts: a claimed start far in the past (or NaN) would let any
    -- council member / master looter pre-empt the running roll everywhere.
    if not ts or ts ~= ts or ts < now - RS_TS_PAST or ts > now + RS_TS_FUTURE then ts = now end

    Prune()
    local ses = NewSession({ id = id, i = itemID, s = s, b = b, c = c, starter = sender, state = "open" })
    ses.party = (dist == "PARTY") or nil   -- a dungeon-mode (5-man party) roll
    -- A plain roll (1.3): the starter's pl decides (1 plain, 0 loot council). Only a starter that doesn't say (an older
    -- client) leaves it to the raid's rules as I know them: right after a /reload or joining I may not know them yet.
    local pl = msg.pl
    if pl == 1 or pl == 0 then
        ses.plain = (dist == "RAID" and pl == 1) or nil
    else
        ses.plain = (dist == "RAID" and PlainRaid()) or nil
    end
    ses.startedAt = floor(ts)
    ses.duration = d
    ses.endsAt = GetTime() + d
    ses.openedAt = GetTime()
    SnapshotTiers(ses)

    -- The same player starts another roll while their previous one is still open here: they lost it
    -- (/reload, crash, relog), so theirs is stale. The same item is re-rolled; another item closes.
    local other = OtherOpen(ses)
    if other and other.starter == sender and not other.isLocal then
        if other.i == ses.i and other.s == ses.s and other.c == ses.c then
            CancelSession(other)
        else
            CloseSession(other)
        end
        other = OtherOpen(ses)
    end

    -- One open roll at a time: of two simultaneous starts the earlier wins on every client. A roll that has been
    -- open here for a while was not a simultaneous start: it stays, the new one is dropped.
    if other then
        local settled = other.openedAt ~= nil and GetTime() - other.openedAt > PREEMPT_WINDOW
        if settled or Earlier(other, ses) then
            ses.state = "cancelled"
            ses.endsAt = GetTime()
            Updated(ses)
            return
        end
        Preempt(other, ses)
    end

    -- My queued roll for the very same item is no longer needed.
    for i = #queue, 1, -1 do
        local q = queue[i]
        if q.i == ses.i and q.s == ses.s and q.c == ses.c then CancelSession(q) end
    end

    local p = pendingRR[id]
    pendingRR[id] = nil
    if p then
        for key, r in pairs(p.r) do
            if Util.IsInMyGroup(key) then ses.responses[key] = r end
        end
    end
    ReplayEarly(ses)

    Util.After(d + REMOTE_CLOSE_SLACK, function()
        if ses.state == "open" then CloseSession(ses) end
    end)
    SendTiers(ses)
    ns:Fire("ROLL_STARTED", ses)
    Updated(ses)
end

local function BufferResponse(id, sender, r)
    local now = GetTime()
    local count = 0
    for pid, p in pairs(pendingRR) do
        if now - p.at > PENDING_RR_AGE then
            pendingRR[pid] = nil
        else
            count = count + 1
        end
    end
    local p = pendingRR[id]
    if not p then
        if count >= MAX_PENDING_RR then return end
        p = { at = now, r = {} }
        pendingRR[id] = p
    end
    p.r[sender] = r
end

-- RR {id, r}: sender in my raid (checked by Comm for RAID messages).
local function OnRollResponse(sender, msg, dist)
    if DemoOn() or not GroupDist(dist) or type(msg) ~= "table" then return end
    local id, r = msg.id, msg.r
    if not ValidId(id) or (r ~= "roll" and r ~= "pass") then return end
    if not sessions[id] then
        BufferResponse(id, sender, r)
        return
    end
    if Roll:OnResponse(sender, id, r) and msg.h ~= nil and ns.Materials and ns.Materials.OnReport then
        ns.Materials:OnReport(sender, sessions[id].i, msg.h, msg.f)
    end
end

-- RE {id, x}: from the starter or whoever may award the roll (Manages: a council member; 1.3: the master looter of a
-- plain roll, whose End roll / award ended it only on its own screen before). x = the session was cancelled (lost a
-- simultaneous start) rather than closed.
local function OnRollEnd(sender, msg, dist)
    if DemoOn() or not GroupDist(dist) or type(msg) ~= "table" or not ValidId(msg.id) then return end
    local ses = sessions[msg.id]
    if not ses then return end
    if sender ~= ses.starter and not Manages(sender, ses.plain, ses.party) then return end
    if msg.x then
        if ses.state == "open" or ses.state == "closed" then CancelSession(ses) end
    else
        CloseSession(ses)
    end
end

-- Deterministic choice between two conflicting awards of one session (every client picks the same):
-- a master-loot hand-out beats a recorded award, then the earlier award (server time; unknown = last),
-- then the smaller awarder key.
local function AwardBeats(given, at, by, ses)
    local g1, g2 = given and 0 or 1, ses.given and 0 or 1
    if g1 ~= g2 then return g1 < g2 end
    local t1, t2 = at or math.huge, ses.awardTs or math.huge
    if t1 ~= t2 then return t1 < t2 end
    return tostring(by) < tostring(ses.awardedBy or "")
end

-- Bag loot: `holder` traded ses's item to its winner (their RW with g, Roll:MarkGiven): handed out, and the holder
-- no longer holds that copy (a later award of the same item to them must not count as handed out at once).
local function HandedOutByHolder(ses, holder)
    local Loot = ns.Loot
    if Loot and Loot.ReleaseHeld then Loot:ReleaseHeld(ses.i, holder) end
    if ses.given then return end
    ses.given = true
    ses.looted = true
    ses.lootOther, ses.lootOtherTs = nil, nil
    Updated(ses)
end

-- RW {id, w, g, at, n}: from whoever may award the roll (Manages: a council member; a plain roll's master looter;
-- in a 5-man party the party leader / ML; 1.3: no raid assistants, no starter that may not award).
-- at (award server time) and n (ledger note) are DisasterZone 0.2 additions.
-- A session resolved only by a loot message (via "loot") takes the RW as its real award (no conflict).
-- 1.3: under bag loot the holder of the item (any raider) sends the RW of the award again with g once they traded it:
-- from them only the "handed out" flag of that very award counts.
local function OnRollWin(sender, msg, dist)
    if DemoOn() or not GroupDist(dist) or type(msg) ~= "table" or not ValidId(msg.id) then return end
    local ses = sessions[msg.id]
    if not ses or (ses.state ~= "open" and ses.state ~= "closed" and ses.state ~= "awarded") then return end
    local w = type(msg.w) == "string" and #msg.w <= MAX_ID_LEN and Util.NormalizeName(msg.w) or nil
    if not w then return end
    if not Manages(sender, ses.plain, ses.party) then
        if msg.g and ses.state == "awarded" and ses.via ~= "loot" and ses.winner == w and HeldBy(ses.i, sender) then
            HandedOutByHolder(ses, sender)
        end
        return
    end
    local nowTs = GetServerTime()
    local at = tonumber(msg.at)
    if at and (at ~= floor(at) or at < (ses.startedAt or nowTs) - RW_AT_PAST or at > nowTs + RW_AT_FUTURE) then
        at = nil   -- unknown: never wins a clash, and the ledger uses the receive time
    end
    local fromLoot = LootMarked(ses)
    -- "Handed out" (g) only counts from the master looter (the only one who can hand an item out), when the
    -- loot message already says the item went to that player, or under bag loot: from the holder (who traded it)
    -- or for a winner who holds it already.
    local _, senderML = GroupRole(sender)
    local given = (msg.g and (senderML or (fromLoot and ses.winner == w) or HeldBy(ses.i, sender) or HeldBy(ses.i, w)))
        and true or false
    local Ledger = ns.Ledger
    local council = AmRealCouncil() and Ledger ~= nil and Ledger.RecordRollAward ~= nil
    if fromLoot then
        ses.looted = true
    elseif ses.state ~= "awarded" then
        ReclaimLoot(ses, w)
    end
    if ses.state == "awarded" and not fromLoot then
        if ses.winner == w then
            -- the same award again, now handed out (the holder traded the item: Roll:MarkGiven)
            if given and HeldBy(ses.i, sender) then
                HandedOutByHolder(ses, sender)
            elseif given and not ses.given then
                ses.given = true
                Updated(ses)
            end
            return
        end
        -- Only awards that really crossed are resolved; a later RW for an awarded session is a re-award attempt.
        local crossed = GetTime() - (ses.awardedAt or 0) <= RW_CROSS_WINDOW
            and not (at and ses.awardTs and abs(at - ses.awardTs) > RW_CROSS_WINDOW)
        if not crossed then
            if council or AmRealCouncil() then
                ns:Print("%s tried to re-award %s to %s after it was awarded to %s; ignored.", Util.ShortName(sender),
                    ItemText(ses), Util.ShortName(w), Util.ShortName(ses.winner))
            end
            return
        end
        -- Two awards crossed: every client keeps the same one (AwardBeats); the loser's entry is voided.
        if not AwardBeats(given, at, sender, ses) then
            if council then Ledger:VoidRollAward(ses.id, w) end
            return
        end
        local lost = ses.winner
        if council then Ledger:VoidRollAward(ses.id, lost) end
        ns:Print("Two awards of %s crossed: it goes to %s (awarded first by %s), not %s.",
            ItemText(ses), Util.ShortName(w), Util.ShortName(sender), Util.ShortName(lost))
    end
    local lootWas = fromLoot and ses.winner or nil
    if ses.state == "open" then CloseSession(ses) end
    ses.state = "awarded"
    ses.winner = w
    ses.given = given
    ses.via = nil
    ses.lootPrev = nil
    ses.awardedBy = sender
    ses.awardedAt = GetTime()
    ses.awardTs = at
    -- r (Addendum G): the award reason; an older sender has none (the log then shows no reason).
    local reason = (type(msg.r) == "string" and ns.AWARD_REASON[msg.r]) and msg.r or nil
    ses.reason = reason
    ses.final = BuildResults(ses)
    if lootWas and lootWas ~= w then FlagLootConflict(ses, lootWas) end
    -- Every council client records it: a non-council master looter / leader cannot write the ledger.
    if council then
        local note = (type(msg.n) == "string" and #msg.n <= MAX_NOTE_LEN and not msg.n:find("[%c|]")) and msg.n or nil
        Ledger:RecordRollAward(ses.id, ses.i, w, ses.b, note, sender, at, false, ses.party and true or false, reason)
    end
    Updated(ses)
end

-- RV {id, k} (Addendum G): a council member's vote on the group channel; k = the candidate key, "" = withdrawn.
-- The sender must be council (a raid council member counts: the group channel only reaches the raid); the
-- candidate must be in my group. One vote per sender (the latest counts).
local function OnRollVote(sender, msg, dist)
    if DemoOn() or not GroupDist(dist) or type(msg) ~= "table" or not ValidId(msg.id) then return end
    local ses = sessions[msg.id]
    if not ses or ses.demo or not IsRealCouncil(sender) then return end
    local k, key = msg.k, nil
    if k ~= nil and k ~= "" then
        if type(k) ~= "string" or #k > MAX_ID_LEN or k:find("[%c|]") then return end
        key = Util.NormalizeName(k)
        if not key then return end
    end
    RecordVote(ses, sender, key)
end

---------------------------------------------------------------------------
-- Demo toggle / group changes
---------------------------------------------------------------------------

-- Demo sessions never survive a toggle; open / queued real ones are cancelled too (demo mode
-- ignores the network, so they could not finish properly).
local function OnDemoToggled()
    queue = {}
    earlyRolls = {}
    pendingRR = {}
    local changed = {}
    for _, ses in pairs(sessions) do
        local live = ses.state == "open" or ses.state == "queued"
        if live then
            ses.state = "cancelled"
            if ses.endsAt == nil or ses.endsAt > GetTime() then ses.endsAt = GetTime() end
        end
        if live or ses.demo then changed[#changed + 1] = ses end
    end
    for _, ses in ipairs(changed) do
        if ses.demo then ses.state = "cancelled" end
        Updated(ses)
    end
    for _, ses in ipairs(changed) do
        if ses.demo then sessions[ses.id] = nil end
    end
end

-- GROUP_UPDATED / DUNGEON_MODE_CHANGED: without a group channel (left the raid, left the party, or
-- dungeon mode ended in a 5-man party) nothing can be announced or synced any more.
local function OnGroupUpdated()
    if DemoOn() or GroupChannel() then return end
    for _, ses in pairs(sessions) do
        if ses.state == "open" then CloseSession(ses) end
    end
    if #queue > 0 then
        CancelQueue(IsInGroup() and "dungeon mode is off" or "you left the group")
    end
end

---------------------------------------------------------------------------
-- Slash: /dz roll <item link(s)> | end
---------------------------------------------------------------------------

-- The newest recent drop that holds itemID (so a slash roll matches the drop panel), or nil.
local function RecentDropWith(itemID)
    local Loot = ns.Loot
    local hist = Loot and Loot.GetHistory and Loot:GetHistory()
    if type(hist) ~= "table" then return nil end
    local cutoff = GetServerTime() - SLASH_DROP_AGE
    for k = #hist, 1, -1 do
        local d = hist[k]
        if type(d) == "table" and type(d.i) == "table" and (tonumber(d.ts) or 0) >= cutoff then
            for _, id in ipairs(d.i) do
                if tonumber(id) == itemID then return d end
            end
        end
    end
    return nil
end

local function SlashRoll(rest)
    rest = type(rest) == "string" and rest or ""
    local lower = rest:lower():match("^%s*(%S*)")
    if lower == "end" or lower == "stop" then
        local active = Roll:GetActive()
        if active then
            Roll:End(active.id)
        else
            ns:Print("No roll is running.")
        end
        return
    end
    local items = {}
    for link in rest:gmatch("|c%x+|Hitem:.-|h.-|h|r") do
        local id = Util.ItemIDFromLink(link)
        if id and IsValidItemID(id) then items[#items + 1] = { id = id, link = link } end
    end
    if #items == 0 then
        for _, id in ipairs(Util.ItemIDsFromText(rest)) do
            if IsValidItemID(id) then items[#items + 1] = { id = id } end
        end
    end
    if #items == 0 then
        local num = tonumber(rest:match("^%s*(%d+)%s*$"))
        if num and IsValidItemID(num) then items[1] = { id = num } end
    end
    if #items == 0 then
        ns:Print("Usage: /dz roll [item link] (shift-click the item) — starts a raid roll; /dz roll end — ends the running roll.")
        return
    end
    if not Roll:CanStart() then
        ns:Print("%s", CannotStartText())
        return
    end
    for k = 1, min(#items, MAX_COPIES) do
        local it = items[k]
        StartInternal(it.id, RecentDropWith(it.id), nil, it.link, false)
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function Guarded(fn)
    return function(...)
        if ns.SafeCall then ns.SafeCall(fn, ...) else fn(...) end
    end
end

function Roll:OnInit()
    ns:RegisterEvent("CHAT_MSG_SYSTEM", function(_, text) Roll:OnSystemMessage(text) end)
    ns:On("DEMO_TOGGLED", OnDemoToggled)
    ns:On("GROUP_UPDATED", OnGroupUpdated)
    ns:On("DUNGEON_MODE_CHANGED", OnGroupUpdated)
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("RS", OnRollStart)
        Comm:Register("RR", OnRollResponse)
        Comm:Register("RE", OnRollEnd)
        Comm:Register("RW", OnRollWin)
        Comm:Register("RT", OnRollTiers)
        Comm:Register("RV", OnRollVote)
    end
    ns:RegisterSlash("roll", SlashRoll, "<item link> - start a raid roll for an item (loot council / master looter); 'end' ends it")

    if ns.Popup.dialogs then
        ns.Popup.dialogs["DISASTERZONE_GIVE_ITEM"] = {
            title = "Give item",
            text = "Give %s to %s?",
            button1 = "Give",
            button2 = CANCEL or "Cancel",
            OnAccept = Guarded(function(_, data) Roll:ConfirmGive(data) end),
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        -- 1.3.5: awarding a prized item to a player who breaks one of its loot rules: why (everyone sees it)
        local function OverrideAccept(text, data)
            local why = type(text) == "string" and text or ""
            why = why:gsub("[%c|]", " "):gsub("^%s+", ""):gsub("%s+$", "")
            local ses = type(data) == "table" and Roll:Get(data.id)
            if not ses then return end
            if why == "" then
                ns:Print("Write why first: the guild sees the reason with the award.")
                Util.After(0.05, function()
                    ns.Popup:Show("DISASTERZONE_PRIZED_OVERRIDE", ItemText(ses), NameText(data.key) .. "?", data)
                end)
                return
            end
            local retry = ses.przRetry
            ses.przRetry = nil
            if retry then retry(why) end
        end
        ns.Popup.dialogs["DISASTERZONE_PRIZED_OVERRIDE"] = {
            title = "Award against the loot rules",
            text = "Give %s to %s\n\nWhy? Everyone sees this reason in the item's history.",
            button1 = "Award anyway",
            button2 = CANCEL or "Cancel",
            hasEditBox = 1,
            maxLetters = 140,
            OnAccept = Guarded(function(self, data)
                local eb = self.GetEditBox and self:GetEditBox() or self.editBox
                OverrideAccept(eb and eb:GetText(), data)
            end),
            EditBoxOnEnterPressed = function(eb)
                local popup = eb:GetParent()
                local data, text = popup and popup.data, eb:GetText()
                if popup then popup:Hide() end
                OverrideAccept(text, data)
            end,
            EditBoxOnEscapePressed = function(eb)
                local popup = eb:GetParent()
                if popup then popup:Hide() end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        ns.Popup.dialogs["DISASTERZONE_CONFIRM_AWARD"] = {
            title = "Award item",
            text = "Award %s to %s?\n(hand it out via master loot or trade)",
            button1 = "Award",
            button2 = CANCEL or "Cancel",
            OnAccept = Guarded(function(_, data) Roll:ConfirmAward(data) end),
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
end

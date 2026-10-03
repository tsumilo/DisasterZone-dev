if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Guild.lua", ...) then return end -- DisasterZone: guild roster cache and the loot council (Addendum E §29-§33). The council is the Guild Master,
-- the guild council list the GM picks (CG / CQ on GUILD, relayed by council members), the current raid
-- leader and the raid council that leader picks (CR / CRQ on RAID, kept in memory for that raid only).
-- Every other module asks ns.Guild who is council and who is online. DisasterZone no longer reads or writes
-- the Guild Information text.
local addonName, ns = ...

local Guild = ns:NewModule("Guild")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, next = type, pairs, ipairs, tonumber, tostring, next
local floor, min, max, random = math.floor, math.min, math.max, math.random
local tsort, tconcat = table.sort, table.concat

local DEFAULT_PHASE = 1
local ROSTER_REQUEST_INTERVAL = 15
local ROSTER_POLL_INTERVAL = 60
local ROSTER_RETRY_DELAY = 10   -- while the roster is still empty after login

local MAX_COUNCIL = 40          -- names per council list (CG m / CR m)
local MAX_KEY_LEN = 48          -- bytes per name on the wire
local MAX_REV = 2147483647
local FUTURE_SLACK = 60         -- a CG rev more than 1 minute past the server time is implausible (a real rev is
                                -- max(now, prev + 1); the slack only covers server-time skew between clients)
local LIST_MAX_AGE = 7 * 86400  -- the login CQ goes out when the stored guild list is older than this
local CQ_MIN_DELAY, CQ_MAX_DELAY = 20, 40
local CQ_REPLY_LIMIT = 60       -- one CG reply per requester per 60 s
local GM_REPLY_MIN, GM_REPLY_MAX = 0.2, 1
local RELAY_REPLY_MIN, RELAY_REPLY_MAX = 2, 8
local CQ_INFLIGHT = 30          -- a piggyback CQ for a rev is not repeated within this
local LEAD_CR_DELAY = 3         -- CR after becoming the leader of a raid (debounced)
local CRQ_DELAY = 3             -- CRQ after joining a raid / a reload inside one
local CRQ_LEADER_CHANGE_DELAY = 7   -- fallback CRQ when a new leader's CR did not arrive
local CR_REPLY_DELAY = 1
local CR_REPLY_MIN_GAP = 5      -- at most one CR answer to raid members' CRQs per 5 s

local LEGACY_TAG_NOTICE = "DisasterZone no longer uses the Guild Information text. You can delete the CDL{...} line from your Guild Info."

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local roster = {}               -- [key] = { rankIndex, rankName, classFile, online, level, status (1 AFK, 2 DND) }
local ready = false
local guildName                 -- cached guild name
local gmKey                     -- the Guild Master per the live roster (rankIndex 0)
local lastRequest = -1000
local pollTicker

local guildList                 -- db.council.guild when it is valid for my current guild, else nil
local inRaid = false
local raidLeader                -- current raid leader key (cached from GetRaidRosterInfo); nil outside raids
local raidCouncil               -- { leader=, rev=, members={} } accepted for my current raid (memory only)
local configSignature           -- effective council set + my status + phase + GM; change => CONFIG_UPDATED
local cgSeen = {}               -- [rev] = GetTime() a trusted CG with this rev was seen / sent on GUILD
local cqInFlight                -- { rev=, at= } the last piggyback CQ
local loginQueryScheduled = false
local loginQueryGuild           -- guild key the login CQ was scheduled for (a guild change re-arms it)
local rosterGen = 0             -- BuildRoster generation (entries are updated in place)
local keyReadyFired             -- guild key GUILD_KEY_READY was fired for
local gmRelayNoted = false      -- the "your list is not on this PC" hint was printed (GM only)
local crReplyPending = false
local raidSince                 -- server time I joined my current raid (raid-scope council sees its awards only)
local lastCrReply = -1000

local function MaxPhase()
    return ns.MAX_PHASE or 5
end

local function Now()
    return (GetServerTime and GetServerTime()) or time()
end

local function IsInt(n, lo, hi)
    return type(n) == "number" and n == floor(n) and n >= lo and n <= hi
end

local function DemoOn()
    local Demo = ns.Demo
    return (Demo and Demo.IsEnabled and Demo:IsEnabled()) and true or false
end

local function DemoRoster()
    local Demo = ns.Demo
    if DemoOn() and Demo.GetRoster then
        local r = Demo:GetRoster()
        if type(r) == "table" then return r end
    end
    return nil
end

-- Demo mode only: the fake officers (rank index <= 1) look like guild council in the UI.
local function DemoCouncil(key)
    local demo = DemoRoster()
    local d = demo and not roster[key] and demo[key]
    return type(d) == "table" and (tonumber(d.rankIndex) or 99) <= 1
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

---------------------------------------------------------------------------
-- Name lists
---------------------------------------------------------------------------

-- A name as sent / picked: a string of 1..48 bytes without control or escape characters -> name key.
local function WireKey(s)
    if type(s) ~= "string" or s == "" or #s > MAX_KEY_LEN or s:find("[%c|]") then return nil end
    return Util.NormalizeName(s)
end

-- A list from the network: an array of at most 40 names. Returns a set, or nil when anything is off.
local function ParseWireList(m)
    if type(m) ~= "table" then return nil end
    local set, n = {}, 0
    for k, v in pairs(m) do
        n = n + 1
        if n > MAX_COUNCIL or type(k) ~= "number" then return nil end
        local key = WireKey(v)
        if not key then return nil end
        set[key] = true
    end
    return set
end

-- A typed name ("rai", "RAI-Thunderstrike") -> the roster's / my group's spelling of that key, if one matches
-- case-insensitively (the picker always passes exact keys; slash / API callers may not).
local function CanonicalKey(key)
    if roster[key] then return key end
    local g = Util.group
    if type(g) == "table" and g[key] then return key end
    local low = key:lower()
    for k in pairs(roster) do
        if k:lower() == low then return k end
    end
    if type(g) == "table" then
        for k in pairs(g) do
            if type(k) == "string" and k:lower() == low then return k end
        end
    end
    return key
end

-- A list from the UI: a set {[key] = true} or an array {key, ...}. Returns set or nil, error.
local function ToSet(list)
    if list == nil then return {} end
    if type(list) ~= "table" then return nil, "invalid list" end
    local set, n = {}, 0
    for k, v in pairs(list) do
        local name
        if type(k) == "string" then
            if v then name = k end        -- set form; false = not a member
        elseif type(v) == "string" then
            name = v                      -- array form
        end
        if name then
            local key = WireKey(name)
            if not key then return nil, "invalid name: " .. tostring(name) end
            key = CanonicalKey(key)
            if not set[key] then
                n = n + 1
                if n > MAX_COUNCIL then return nil, "too many names (at most " .. MAX_COUNCIL .. ")" end
                set[key] = true
            end
        end
    end
    return set
end

local function SetToArray(set)
    local out = {}
    if type(set) == "table" then
        for k, v in pairs(set) do
            if v then out[#out + 1] = k end
        end
    end
    tsort(out)
    return out
end

local function CopySet(set)
    local out = {}
    if type(set) == "table" then
        for k, v in pairs(set) do
            if v then out[k] = true end
        end
    end
    return out
end

local function SameSet(a, b)
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end

-- Addendum G §41: the loot targets (disenchanter / guild bank character) riding on the council lists.
-- Wire fields de / bk; stored as rec.de / rec.bank. A malformed name drops the whole message like a bad list.
local TARGET_KINDS = { de = "de", bank = "bk" }   -- [stored field] = wire field

-- Returns ok, { de = key|nil, bank = key|nil } from a CG / CR message.
local function ParseWireTargets(msg)
    local out = {}
    for field, wire in pairs(TARGET_KINDS) do
        local v = msg[wire]
        if v ~= nil and v ~= "" then
            local key = WireKey(v)
            if not key then return false end
            out[field] = key
        end
    end
    return true, out
end

-- Adds the wire fields of rec's targets to msg.
local function AddWireTargets(msg, rec)
    if type(rec) ~= "table" then return msg end
    for field, wire in pairs(TARGET_KINDS) do
        if type(rec[field]) == "string" then msg[wire] = rec[field] end
    end
    return msg
end

-- targets from the UI: { de = key | false, bank = key | false } (nil = keep cur's). Returns { de=, bank= } or
-- nil, error.
local function MergeTargets(targets, cur)
    local out = {}
    for field in pairs(TARGET_KINDS) do
        local v
        if type(targets) == "table" then v = targets[field] end
        if v == nil then
            out[field] = type(cur) == "table" and type(cur[field]) == "string" and cur[field] or nil
        elseif v ~= false and v ~= "" then
            local key = WireKey(v)
            if not key then return nil, "invalid name: " .. tostring(v) end
            out[field] = CanonicalKey(key)
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Roster
---------------------------------------------------------------------------

local guildKeyName, guildKeyCache   -- GuildKey() is read on every award-log query: cached per guild name

local function GuildKey()
    if not guildName then return nil end
    if guildKeyName == guildName then return guildKeyCache end
    local realm = Util.GetPlayerRealm() or ""
    local key = guildName .. "-" .. realm
    if realm ~= "" then guildKeyName, guildKeyCache = guildName, key end
    return key
end

local function RefreshGuildName()
    if IsInGuild() and GetGuildInfo then
        local name = GetGuildInfo("player")
        if type(name) == "string" and name ~= "" then
            guildName = name
            -- GetGuildInfo("player") can stay nil for a few seconds after a login; modules that cached data
            -- scoped by the guild key (the award log view) rebuild when it arrives. Deferred: this runs inside
            -- GetGuildKey calls from those very modules.
            local gk = GuildKey()
            if ns.loggedIn and keyReadyFired ~= gk then
                keyReadyFired = gk
                Util.After(0, function() ns:Fire("GUILD_KEY_READY", gk) end)
            end
        end
    end
end

local function CouncilDB()
    local db = ns.db
    if not db then return nil end
    if type(db.council) ~= "table" then db.council = {} end
    return db.council
end

-- The Guild Master: the rank-0 member of the roster. With "Show Offline Members" unchecked the client
-- hides offline rows, so an offline GM may be missing: then the last GM seen in this guild counts, unless
-- that character is visible now with another rank.
local function ResolveGM(newRoster, visibleGM)
    local c = CouncilDB()
    local gk = GuildKey()
    if visibleGM then
        if c and gk and not (type(c.gm) == "table" and c.gm.key == visibleGM and c.gm.g == gk) then
            c.gm = { key = visibleGM, g = gk }
        end
        return visibleGM
    end
    local last = c and c.gm
    if type(last) == "table" and type(last.key) == "string" and gk and last.g == gk and not newRoster[last.key] then
        return last.key
    end
    return nil
end

-- Updates `roster` (and the Guild Master) from the client's guild roster, in place (the roster is polled every
-- 15-60 s; a fresh table per member per update was pure garbage). Returns changed, membersChanged: anything
-- changed / the set of member keys changed (a join, a leave, the first build).
local function BuildRoster()
    local total = GetNumGuildMembers and GetNumGuildMembers()
    total = tonumber(total) or 0
    if total <= 0 then return false, false end

    rosterGen = rosterGen + 1
    local gen = rosterGen
    local count, gm = 0, nil
    local changed, membersChanged = not ready, not ready
    for i = 1, total do
        local name, rankName, rankIndex, level, _, _, _, _, isOnline, status, classFile = GetGuildRosterInfo(i)
        local key = type(name) == "string" and Util.NormalizeName(name) or nil
        if key then
            count = count + 1
            local ri = tonumber(rankIndex) or 99
            local online = isOnline and true or false
            level = tonumber(level)
            status = online and tonumber(status) or 0   -- (0 / nil: available)
            if status ~= 1 and status ~= 2 then status = nil end
            local e = roster[key]
            if not e then
                e = {}
                roster[key] = e
                membersChanged, changed = true, true
            elseif e.rankIndex ~= ri or e.rankName ~= rankName or e.classFile ~= classFile or e.online ~= online
                or e.level ~= level or e.status ~= status then
                changed = true
            end
            e.rankIndex, e.rankName, e.classFile, e.online, e.level, e.gen = ri, rankName, classFile, online, level, gen
            e.status = status
            if ri == 0 and (not gm or key < gm) then gm = key end
        end
    end
    if count == 0 then return false, false end   -- (nothing was touched: no row had a name)
    for key, e in pairs(roster) do
        if e.gen ~= gen then
            roster[key] = nil
            membersChanged, changed = true, true
        end
    end
    gm = ResolveGM(roster, gm)
    if gm ~= gmKey then changed = true end
    gmKey = gm
    ready = true
    return changed, membersChanged
end

---------------------------------------------------------------------------
-- Stored lists (SavedVariables: db.council)
---------------------------------------------------------------------------

-- Re-reads db.council.guild: valid when well-formed and made for my current guild (SavedVariables are
-- account-wide; an alt in another guild must not use this guild's list).
local MAX_OTHER_GUILDS = 5

local function RefreshGuildList()
    guildList = nil
    local c = CouncilDB()
    if not c or not IsInGuild() then return nil end
    local gk = GuildKey()
    local rec = c.guild
    if gk and (type(rec) ~= "table" or (rec.g ~= nil and rec.g ~= gk)) then
        -- Another character of this account is in another guild: park that guild's list and take this
        -- guild's parked one (if any), so switching characters does not refetch (and re-trust) each time.
        local other = type(c.otherGuilds) == "table" and c.otherGuilds or {}
        if type(rec) == "table" and type(rec.g) == "string" then
            other[rec.g] = rec
        end
        rec = other[gk]
        other[gk] = nil
        local n, oldestKey, oldestRev = 0, nil, nil
        for k, r in pairs(other) do
            n = n + 1
            local rv = type(r) == "table" and tonumber(r.recvAt) or 0
            if not oldestRev or rv < oldestRev then oldestKey, oldestRev = k, rv end
        end
        if n > MAX_OTHER_GUILDS and oldestKey then other[oldestKey] = nil end
        c.otherGuilds = next(other) ~= nil and other or nil
        c.guild = rec
    end
    if type(rec) ~= "table" or type(rec.members) ~= "table" or not IsInt(rec.rev, 1, MAX_REV) then
        return nil
    end
    if rec.g == nil and gk ~= nil then rec.g = gk end
    -- A list stored by DisasterZone 0.3 / 0.4 (no src) whose rev is still in the future was never saved by a GM (a real
    -- rev is max(now, prev + 1)): it came from a forged relay (0.4 accepted revs up to now + 300 s). Keep it only
    -- as unconfirmed, so the GM's own CG replaces it whatever its rev.
    if rec.src == nil and rec.rev > Now() + 5 then rec.src = "tofu" end
    guildList = rec
    return rec
end

local function MyRaidList()
    local c = CouncilDB()
    local rec = c and c.myRaidList
    if type(rec) ~= "table" or type(rec.members) ~= "table" or not IsInt(rec.rev, 0, MAX_REV) then return nil end
    return rec
end

---------------------------------------------------------------------------
-- Raid leader / raid council
---------------------------------------------------------------------------

local function LiveRaidLeader()
    if not IsInRaid() then return nil end
    local n = min(tonumber(GetNumGroupMembers()) or 0, 40)
    for i = 1, n do
        local name, rank = GetRaidRosterInfo(i)
        if rank == 2 and type(name) == "string" and name ~= "" and name ~= UNKNOWNOBJECT then
            return Util.NormalizeName(name)
        end
    end
    return nil
end

local function CurrentRaidLeader()
    if not IsInRaid() then return nil end
    if raidLeader == nil then raidLeader = LiveRaidLeader() end
    return raidLeader
end

local function AmILeadingRaid()
    return (IsInRaid() and UnitIsGroupLeader("player")) and true or false
end

-- key is a member of my current raid (the real one; demo raid members don't count).
local function InMyRaid(key)
    if type(key) ~= "string" or not IsInRaid() then return false end
    if Util.IsMe(key) then return true end
    local g = Util.group
    if type(g) == "table" and g[key] then return true end
    local unitName = (Ambiguate and Ambiguate(key, "none")) or key
    return (UnitInRaid and UnitInRaid(unitName)) and true or false
end

-- My own raid list as the council of the raid I lead.
local function OwnRaidCouncil()
    local mine = MyRaidList()
    return { leader = Util.PlayerKey(), rev = mine and mine.rev or 0, members = CopySet(mine and mine.members),
             de = mine and mine.de or nil, bank = mine and mine.bank or nil }
end

---------------------------------------------------------------------------
-- Council checks
---------------------------------------------------------------------------

-- Accounts (a player's characters share their roles; defined with the raid leaders list below).
local Principals, IsGMKey, AddAlts, InvalidateAccounts, NoteOwnCharacter

-- "gm" | "guild" | "raidleader" | "raid" | nil, from real data only (no demo).
---------------------------------------------------------------------------
-- Debug roles (for the addon's developer only): the character named DEBUG_CHAR can pretend to have another role with
-- /dz role, to look at the addon as a GM, officer, council member, raid leader or plain raider. It only changes what
-- MY client thinks my role is (UI and my own checks); every other client still checks my real rank and lists, so
-- nothing I'm not really entitled to is sent to me. Saved in db.debugRole.
---------------------------------------------------------------------------

local DEBUG_CHAR = "Tsumil"
local DEBUG_ROLES = { gm = true, officer = true, council = true, raidleader = true, raider = true }

local function DebugAllowed()
    local name = UnitName and UnitName("player")
    return name == DEBUG_CHAR
end

-- My pretend role, or nil.
local function DebugRole(key)
    if key ~= nil and not Util.IsMe(key) then return nil end
    local db = ns.db
    local r = db and db.debugRole
    if r and DEBUG_ROLES[r] and DebugAllowed() then return r end
    return nil
end

local function RealSource(key)
    if type(key) ~= "string" then return nil end
    local role = DebugRole(key)
    if role == "gm" then return "gm" end
    if role == "council" then return "guild" end
    if not role then
        if gmKey and key == gmKey then return "gm" end
        local list = guildList
        if list and list.members[key] and roster[key] then return "guild" end
        -- another character of the same player is the GM / on the guild list
        local mains = roster[key] and Principals(key)
        if mains then
            local viaList = false
            for _, m in ipairs(mains) do
                if m == gmKey then return "gm" end
                if list and list.members[m] and roster[m] then viaList = true end
            end
            if viaList then return "guild" end
        end
    end
    if IsInRaid() then
        local leader = CurrentRaidLeader()
        if leader then
            if key == leader then return "raidleader" end
            local rc = raidCouncil
            if rc and rc.leader == leader and rc.members[key] and InMyRaid(key) then return "raid" end
        end
    end
    return nil
end

-- Every effective (real) council member as a set.
local function EffectiveCouncilSet()
    local set = {}
    if gmKey then
        set[gmKey] = true
        AddAlts(set, gmKey)
    end
    if guildList then
        for key in pairs(guildList.members) do
            if roster[key] then
                set[key] = true
                AddAlts(set, key)
            end
        end
    end
    if IsInRaid() then
        local leader = CurrentRaidLeader()
        if leader then
            set[leader] = true
            local rc = raidCouncil
            if rc and rc.leader == leader then
                for key in pairs(rc.members) do
                    if InMyRaid(key) then set[key] = true end
                end
            end
        end
    end
    return set
end

local function Snapshot()
    local me = Util.PlayerKey()
    return {
        phase = Guild:GetGuildPhase(),
        gm = gmKey,
        guild = Guild:GetGuildCouncil(),
        raid = Guild:GetRaidCouncil(),
        council = me ~= nil and RealSource(me) ~= nil,
    }
end

-- Fires CONFIG_UPDATED when the effective council set, my own status, the phase or the GM changed.
local function Recompute()
    if not ns.loggedIn then return end
    InvalidateAccounts()   -- (ranks and lists decide which vouches count)
    local me = Util.PlayerKey()
    local sig = tconcat(SetToArray(EffectiveCouncilSet()), ",")
        .. "|" .. tostring(me ~= nil and RealSource(me) ~= nil)
        .. "|" .. tostring(Guild:GetGuildPhase())
        .. "|" .. tostring(gmKey)
        .. "|" .. tostring((Guild:GetLootTarget("de"))) .. "|" .. tostring((Guild:GetLootTarget("bank")))
        .. "|rl:" .. tconcat(Guild:GetRaidLeaders(), ",")
    if sig ~= configSignature then
        configSignature = sig
        ns:Fire("CONFIG_UPDATED", Snapshot())
    end
end

---------------------------------------------------------------------------
-- CG / CQ: the guild council list (GUILD, ctrl)
---------------------------------------------------------------------------

-- src of the stored guild list (DisasterZone 0.5): "self" (the GM saved it on this client), "gm" (received directly from
-- the live-roster GM), "relay" (relayed by a council member of a confirmed list), "tofu" (trust on first use: no
-- list yet and the relayed list named its relayer; unconfirmed). nil = a list stored by DisasterZone 0.3 / 0.4.
-- An unconfirmed list is never re-served (CQ answers, cg in HELLO / STATE), is re-queried at every login, and any
-- CG straight from the GM replaces it whatever its rev.
local function IsTofu(rec) return type(rec) == "table" and rec.src == "tofu" end

local function SendCG(rec, target)
    if type(rec) ~= "table" then return false end
    local msg = { t = "CG", rev = rec.rev, m = SetToArray(rec.members), ph = rec.phase or DEFAULT_PHASE, by = rec.by }
    AddWireTargets(msg, rec)   -- (Addendum G; older clients ignore de / bk)
    if target then return Send(msg, "WHISPER", target, "ctrl") end
    local ok = Send(msg, "GUILD", nil, "ctrl")
    if ok then cgSeen[rec.rev] = GetTime() end
    return ok
end

local function SendCQ(dist, target)
    local rec = guildList
    -- r = 0 while unconfirmed: the GM answers with its list even when the stored (forged) rev is higher.
    return Send({ t = "CQ", r = (rec and not IsTofu(rec)) and rec.rev or 0 }, dist, target, "ctrl")
end

local function StoreGuildList(v, by, src)
    local c = CouncilDB()
    if not c then return end
    c.guild = { rev = v.rev, members = v.members, phase = v.phase, by = by, recvAt = Now(), g = GuildKey(), src = src,
                de = v.de, bank = v.bank }
    RefreshGuildList()
end

-- { rev, members (set), phase, by, de, bank } of a well-formed CG, else nil.
local function ValidateCG(msg)
    if type(msg) ~= "table" or not IsInt(msg.rev, 1, MAX_REV) then return nil end
    local set = ParseWireList(msg.m)
    if not set then return nil end
    local ph = msg.ph
    if ph == nil then ph = DEFAULT_PHASE end
    if not IsInt(ph, 1, MaxPhase()) then return nil end
    local by
    if msg.by ~= nil then
        by = WireKey(msg.by)
        if not by then return nil end
    end
    local ok, targets = ParseWireTargets(msg)
    if not ok then return nil end
    return { rev = msg.rev, members = set, phase = ph, by = by, de = targets.de, bank = targets.bank }
end

-- CG {rev, m, ph, by}. Taken directly from the Guild Master (per the live roster), or as a relayed copy
-- when it was made by the current GM and the relaying member is council under my current (confirmed) guild
-- list, or - trust on first use - I have no confirmed list and the relayed list names the relaying member
-- (then it stays unconfirmed until the GM's own CG arrives, see IsTofu). The GM's own client never takes a
-- relayed copy of "its" list: only its own saves count there.
local function OnGuildCouncil(sender, msg, dist)
    if (dist ~= "GUILD" and dist ~= "WHISPER") or not ready then return end
    local v = ValidateCG(msg)
    if not v then
        ns:Debug("Guild: malformed CG from %s ignored", tostring(sender))
        return
    end
    -- Relayed revs are always in the past; only a CG straight from the GM may be a moment ahead (prev + 1).
    local gmDirect = IsGMKey(sender)   -- (the GM, or a character the GM vouches for)
    if v.rev > Now() + (gmDirect and FUTURE_SLACK or 5) then
        ns:Debug("Guild: CG from %s with a future rev ignored", tostring(sender))
        return
    end
    local stored = guildList
    local by, src
    if gmDirect then
        by, src = sender, "gm"
    else
        if not gmKey or not IsGMKey(v.by) then return end
        if IsGMKey(Util.PlayerKey()) then
            -- I am the GM: a copy of my list from someone else is never trusted (it may be forged).
            if not stored and not gmRelayNoted then
                gmRelayNoted = true
                ns:Print("Your guild council list is not saved on this PC: open Council > Loot Council and save it "
                    .. "again (a copy relayed by %s was not taken).", Util.ShortName(sender))
            end
            return
        end
        local vouched
        if stored and not IsTofu(stored) then
            vouched = stored.members[sender] and roster[sender] and true or false
            src = "relay"
        else
            vouched = v.members[sender] and true or false
            src = "tofu"
        end
        if not vouched then
            ns:Debug("Guild: relayed CG from %s ignored (not council under my list)", tostring(sender))
            return
        end
        by = v.by
    end
    local storedRev = stored and stored.rev or 0
    local same = stored ~= nil and SameSet(stored.members, v.members) and stored.phase == v.phase
        and stored.de == v.de and stored.bank == v.bank
    if gmDirect and IsTofu(stored) then
        -- The GM outranks an unconfirmed list whatever its rev: confirm it, or replace it.
        if dist == "GUILD" then cgSeen[v.rev] = GetTime() end
        if same and v.rev == storedRev then
            stored.src, stored.recvAt = "gm", Now()
            Recompute()
            return
        end
        StoreGuildList(v, by, src)
        Recompute()
        return
    end
    if v.rev < storedRev then return end
    if dist == "GUILD" then cgSeen[v.rev] = GetTime() end
    if v.rev == storedRev then
        -- The same list, confirmed by a trusted source: still current (restarts the 7-day query timer).
        if same then
            stored.recvAt = Now()
            if gmDirect and stored.src ~= "self" then stored.src = "gm" end
        end
        return
    end
    StoreGuildList(v, by, src)
    Recompute()
end

-- CQ {r = the requester's rev}. The GM answers at once; a council member of the list answers after 2-8 s
-- unless someone answered on GUILD meanwhile. A whispered CQ is answered by whisper.
local function OnGuildCouncilQuery(sender, msg, dist)
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    local rec = guildList
    if not rec or IsTofu(rec) then return end   -- an unconfirmed list is never re-served
    local me = Util.PlayerKey()
    local amGM = me ~= nil and IsGMKey(me)
    if not amGM then
        -- Receivers only take relays of the current GM's list from its council members.
        if not (me and rec.members[me] and roster[me]) or not gmKey or not IsGMKey(rec.by) then return end
    end
    local theirs = type(msg) == "table" and tonumber(msg.r) or 0
    if not theirs or theirs > rec.rev then return end
    -- One reply per requester and list rev per 60 s: a list saved since the last reply is answered again.
    if not RateLimit("cg-reply:" .. sender .. ":" .. tostring(rec.rev), CQ_REPLY_LIMIT) then return end
    local arrived = GetTime()
    local lo, hi = GM_REPLY_MIN, GM_REPLY_MAX
    if not amGM then lo, hi = RELAY_REPLY_MIN, RELAY_REPLY_MAX end
    Util.RandomDelay(lo, hi, function()
        local cur = guildList
        if not cur or IsTofu(cur) or cur.rev < theirs then return end
        if dist == "WHISPER" then
            SendCG(cur, sender)
            return
        end
        local seen = cgSeen[cur.rev]
        if seen and seen >= arrived then return end   -- already answered on GUILD
        SendCG(cur)
    end)
end

local function ScheduleLoginQuery()
    local gk = GuildKey()
    if loginQueryScheduled and loginQueryGuild == gk then return end
    loginQueryScheduled = true
    loginQueryGuild = gk
    -- Debounced: joining another guild while the login query still waits replaces it.
    Util.Debounce("cdl-guild-cq", CQ_MIN_DELAY + random() * (CQ_MAX_DELAY - CQ_MIN_DELAY), function()
        if not IsInGuild() then
            loginQueryScheduled = false
            return
        end
        local rec = guildList
        if rec and not IsTofu(rec) then   -- an unconfirmed list is re-queried at every login
            if Guild:IsGM(Util.PlayerKey()) then return end   -- the GM's own list is the source
            if Now() - (tonumber(rec.recvAt) or 0) < LIST_MAX_AGE then return end
        end
        SendCQ("GUILD")
    end)
end

---------------------------------------------------------------------------
-- CR / CRQ: the raid council (RAID)
---------------------------------------------------------------------------

local function SendCRNow()
    if not AmILeadingRaid() then return false end
    local mine = MyRaidList()
    local msg = AddWireTargets({ t = "CR", rev = mine and mine.rev or 0, m = SetToArray(mine and mine.members) }, mine)
    return Send(msg, "RAID", nil, "alert")
end

local function ScheduleCR(delay)
    Util.Debounce("cdl-guild-cr", delay, SendCRNow)
end

local function ScheduleCRQ(delay)
    Util.Debounce("cdl-guild-crq", delay + random(), function()
        if IsInRaid() and not raidCouncil and not AmILeadingRaid() then
            Send({ t = "CRQ" }, "RAID", nil, "ctrl")
        end
    end)
end

-- CR {rev, m}: only from the current raid leader per GetRaidRosterInfo. Replaces the raid council.
local function OnRaidCouncil(sender, msg, dist)
    if dist ~= "RAID" or type(msg) ~= "table" or not IsInRaid() then return end
    local rank = Util.GetGroupRole and Util.GetGroupRole(sender)
    if rank ~= 2 then
        ns:Debug("Guild: CR from %s ignored (not the raid leader)", tostring(sender))
        return
    end
    local rev = msg.rev
    if rev == nil then rev = 0 end
    if not IsInt(rev, 0, MAX_REV) then return end
    local set = ParseWireList(msg.m == nil and {} or msg.m)
    if not set then return end
    local ok, targets = ParseWireTargets(msg)
    if not ok then return end
    raidLeader = sender
    inRaid = true
    raidCouncil = { leader = sender, rev = rev, members = set, de = targets.de, bank = targets.bank }
    Util.CancelDebounce("cdl-guild-crq")
    Recompute()
end

-- CRQ: a raid member without the raid council asks; the leader answers with CR on RAID. Leading-edge and at most
-- once per CR_REPLY_MIN_GAP: queries never postpone the answer (nor my own list-change CR, which has its own timer).
local function OnRaidCouncilQuery(_, _, dist)
    if dist ~= "RAID" or not AmILeadingRaid() or crReplyPending then return end
    crReplyPending = true
    Util.After(max(CR_REPLY_DELAY, lastCrReply + CR_REPLY_MIN_GAP - GetTime()), function()
        crReplyPending = false
        lastCrReply = GetTime()
        SendCRNow()
    end)
end

-- Joined / left a raid, or the leader changed (GROUP_ROSTER_UPDATE, PARTY_LEADER_CHANGED, login).
local function RefreshRaidState()
    if not ns.loggedIn then return end
    local nowInRaid = IsInRaid() and true or false
    local leader = nowInRaid and LiveRaidLeader() or nil
    if nowInRaid and not leader then leader = raidLeader end   -- roster still loading: keep what we had
    local joined = nowInRaid and not inRaid
    local changed = leader ~= raidLeader
    inRaid, raidLeader = nowInRaid, leader
    if joined then raidSince = Now() elseif not nowInRaid then raidSince = nil end
    if not nowInRaid then
        raidCouncil = nil
        Util.CancelDebounce("cdl-guild-cr")
        Util.CancelDebounce("cdl-guild-crq")
    else
        if raidCouncil and raidCouncil.leader ~= leader then raidCouncil = nil end
        if leader and Util.IsMe(leader) then
            if joined or changed or not raidCouncil then
                raidCouncil = OwnRaidCouncil()
                ScheduleCR(LEAD_CR_DELAY)   -- re-shared each time I lead a raid
            end
        elseif not raidCouncil then
            if joined then
                ScheduleCRQ(CRQ_DELAY)
            elseif changed then
                ScheduleCRQ(CRQ_LEADER_CHANGE_DELAY)
            end
        end
    end
    Recompute()
end

---------------------------------------------------------------------------
-- Guild events
---------------------------------------------------------------------------

local function ResetGuild()
    local hadData = ready or next(roster) ~= nil
    roster = {}
    ready = false
    guildName = nil
    gmKey = nil
    guildList = nil
    if hadData then
        ns:Fire("ROSTER_UPDATED")
    end
    Recompute()
end

local function OnRosterUpdate(_, canRequestRosterUpdate)
    if not ns.loggedIn then return end
    if not IsInGuild() then
        if ready then ResetGuild() end
        return
    end
    RefreshGuildName()
    local changed, membersChanged = BuildRoster()
    if not ready then
        -- The roster can come back empty right after login; keep asking until it is filled.
        Util.Debounce("guild-roster-retry", ROSTER_RETRY_DELAY, function()
            if not ready and IsInGuild() then Guild:RequestRoster(true) end
        end)
        return
    end
    RefreshGuildList()
    NoteOwnCharacter()
    if changed then
        -- membersChanged (DisasterZone 0.5): false when only online / rank / level flags changed.
        ns:Fire("ROSTER_UPDATED", membersChanged and true or false)
    end
    Recompute()
    if canRequestRosterUpdate then
        Guild:RequestRoster()
    end
end

local function OnGuildChanged(_, unit)
    if not ns.loggedIn then return end
    if unit ~= nil and unit ~= "player" then return end
    if not IsInGuild() then
        ResetGuild()
    else
        RefreshGuildName()
        RefreshGuildList()
        Guild:RequestRoster(true)
        ScheduleLoginQuery()
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Raid leaders (Addendum J §62): a list officers (rank 0-1: the GM and the rank below) keep. Raid leaders and the GM
-- plan raids; the raid log is also open to the guild council. No loot council access comes with the list.
--
-- Its own message RLL { rev, m, by } (GUILD, or WHISPER as an answer): accepted only from an officer per the live
-- roster (the author, or an officer passing it on), newer rev wins (the same rev: the larger name list). HELLO carries
-- my rev (rlr); an officer answers an older one with the list, and asks (RLQ) an officer who has a newer one. An
-- officer also shares it once after logging in, for members who logged in while no officer was online.
---------------------------------------------------------------------------

local OFFICER_RANK = 1          -- rank index 0 (GM) and 1 are officers
local RLL_REPLY_LIMIT = 30
local RLL_LOGIN_MIN, RLL_LOGIN_MAX = 20, 40

-- db.raidLeaders[guildKey] = { rev, m = { [key] = true }, by }
local function LeadersRec(create)
    local db = ns.db
    local g = GuildKey()
    if not db or not g then return nil end
    if type(db.raidLeaders) ~= "table" then
        if not create then return nil end
        db.raidLeaders = {}
    end
    local rec = db.raidLeaders[g]
    if type(rec) ~= "table" or type(rec.m) ~= "table" or not IsInt(rec.rev, 0, MAX_REV) then
        if not create then return nil end
        rec = { rev = 0, m = {} }
        db.raidLeaders[g] = rec
    end
    return rec
end

---------------------------------------------------------------------------
-- Accounts: a player's characters share their roles.
--
-- Every client knows which characters of its guild logged in on its own account (the saved variables are per
-- account), and each character vouches for the others: "these are my player's characters too". A character has the
-- roles of every guild member that vouches for it: the alt of the Guild Master counts as the Guild Master, the alt
-- of a guild council member as guild council, of an officer as an officer, of a listed raid leader as a raid leader.
-- Roles are never passed on twice: only what the vouching character itself is (its rank, the lists it is on) counts.
--
-- What makes it safe: a vouch only counts when it was heard from the vouching character itself (the game names the
-- sender of an addon message; that cannot be forged), or passed on by the GM, an officer or a guild council member
-- who holds every role the vouching character has. Somebody who passes on a made-up vouch can so only hand out roles
-- they could hand to their own alt anyway; nobody can make themselves the alt of someone above them.
--
-- Message ACB { l = { { k = voucher, v = rev, m = { key, ... } }, ... } } (GUILD or WHISPER): each character sends
-- its own entry once after logging in. HELLO carries a hash of what I hold (av); the GM, an officer or a council
-- member who holds something else answers once with all of it, for members who were offline when a main spoke.
-- Data: db.accounts[guildKey] = { mine = { [key] = true }, v = { [voucher] = { rev, m = { [key] = true }, src } } }
-- (src: who I heard it from; the voucher itself, or the one who passed it on).
---------------------------------------------------------------------------

local MAX_ACCOUNT_CHARS = 12    -- other characters one character vouches for
local MAX_VOUCHERS = 300        -- vouching characters stored per guild
local ACB_PART = 25             -- entries per ACB message
local ACC_LOGIN_MIN, ACC_LOGIN_SPREAD = 25, 20   -- my own entry goes out 25-45 s after login
local ACB_REPLY_MIN, ACB_REPLY_SPREAD = 1, 5
local ACB_GAP = 30              -- at most one passed-on batch per 30 s (mine, or anybody's seen on GUILD)
local ACB_PER_MEMBER = 600      -- one answer per member per 10 minutes

local vouchedBy                 -- [key] = { voucher, ... } (valid vouches only); nil = rebuild
local batchSeenAt = -1000       -- GetTime() a passed-on batch was last sent / seen on GUILD

-- A delay within [lo, lo + spread) that differs per character but draws nothing from math.random (rolls and the
-- games share that sequence).
local function OwnJitter(lo, spread, salt)
    local n = Util.Adler32((Util.PlayerKey() or "?") .. salt .. tostring(Now()))
    return lo + (n % 1000) / 1000 * spread
end

local function AccountsDB(create)
    local db, gk = ns.db, GuildKey()
    if not db or not gk then return nil end
    if type(db.accounts) ~= "table" then
        if not create then return nil end
        db.accounts = {}
    end
    local rec = db.accounts[gk]
    if type(rec) ~= "table" then
        if not create then return nil end
        rec = {}
        db.accounts[gk] = rec
    end
    if type(rec.mine) ~= "table" then rec.mine = {} end
    if type(rec.v) ~= "table" then rec.v = {} end
    return rec
end

-- gm, officer, council, raid leader: what the character itself is (its rank, the lists it is on). No debug role,
-- nothing shared by another character.
local function OwnRoles(key)
    local e = roster[key]
    local gm = gmKey ~= nil and key == gmKey
    local officer = e ~= nil and (tonumber(e.rankIndex) or 99) <= OFFICER_RANK
    local list = guildList
    local council = e ~= nil and list ~= nil and not IsTofu(list) and list.members[key] == true
    local lrec = LeadersRec(false)
    local leader = e ~= nil and lrec ~= nil and lrec.m[key] == true
    return gm, officer, council, leader
end

-- May `relay` pass on a vouch of `voucher`? Only the GM, officers and the guild council pass vouches on, and only
-- of characters that have no role the relay lacks.
local function CoversRoles(relay, voucher)
    if relay == voucher then return true end
    local rg, ro, rc, rl = OwnRoles(relay)
    if rg then return true end
    if not (ro or rc) then return false end
    local vg, vo, vc, vl = OwnRoles(voucher)
    if vg or (vo and not ro) or (vc and not rc) or (vl and not (ro or rl)) then return false end
    return true
end

local function ValidEntry(voucher, e)
    return type(voucher) == "string" and type(e) == "table" and type(e.m) == "table"
        and IsInt(e.rev, 1, MAX_REV) and type(e.src) == "string"
end

local function VouchIndex()
    if vouchedBy then return vouchedBy end
    local idx = {}
    local rec = AccountsDB(false)
    if not rec then return idx end          -- (the guild is not known yet: not cached)
    for voucher, e in pairs(rec.v) do
        if ValidEntry(voucher, e) and roster[voucher] and CoversRoles(e.src, voucher) then
            for key, on in pairs(e.m) do
                if on == true and type(key) == "string" and key ~= voucher and roster[key] then
                    local list = idx[key]
                    if not list then
                        list = {}
                        idx[key] = list
                    end
                    list[#list + 1] = voucher
                end
            end
        end
    end
    vouchedBy = idx
    return idx
end

-- The guild members that vouch for `key` (its player's other characters), or nil.
function Principals(key)
    if type(key) ~= "string" then return nil end
    return VouchIndex()[key]
end

-- The Guild Master, or a character the Guild Master vouches for.
function IsGMKey(key)
    if type(key) ~= "string" or not gmKey then return false end
    if key == gmKey then return true end
    for _, m in ipairs(Principals(key) or {}) do
        if m == gmKey then return true end
    end
    return false
end

-- Adds the characters `voucher` vouches for to a set.
function AddAlts(set, voucher)
    local rec = AccountsDB(false)
    local e = rec and rec.v[voucher]
    if not ValidEntry(voucher, e) or not CoversRoles(e.src, voucher) then return end
    for key, on in pairs(e.m) do
        if on == true and roster[key] then set[key] = true end
    end
end

function InvalidateAccounts()
    vouchedBy = nil
end

-- This character logged in on this account, in this guild (called once the guild roster is there).
function NoteOwnCharacter()
    local me = Util.PlayerKey()
    local rec = me and AccountsDB(true)
    if rec and rec.mine[me] == nil then rec.mine[me] = true end
end

-- My own entry, brought up to date: the characters of this account in this guild (they logged in here; the Members
-- tab's own characters count too). nil while there is nothing to say.
local function MyVouch()
    local rec = AccountsDB(true)
    local me = Util.PlayerKey()
    if not rec or not me or not ready then return nil end
    rec.mine[me] = true
    local prof = ns.db.prof and ns.db.prof[GuildKey()]
    for key, r in pairs(type(prof) == "table" and prof or {}) do
        if type(key) == "string" and type(r) == "table" and r.own == true and rec.mine[key] == nil then
            rec.mine[key] = true
        end
    end
    local names = {}
    for key, on in pairs(rec.mine) do
        if on == true and type(key) == "string" and key ~= me and roster[key] and WireKey(key) == key then
            names[#names + 1] = key
        end
    end
    tsort(names)
    local set = {}
    for i = 1, min(#names, MAX_ACCOUNT_CHARS) do set[names[i]] = true end
    local cur = rec.v[me]
    if not ValidEntry(me, cur) then cur = nil end
    if not cur and next(set) == nil then return nil end
    if not cur or cur.src ~= me or not SameSet(cur.m, set) then
        rec.v[me] = { rev = min(max(floor(Now()), (cur and cur.rev or 0) + 1), MAX_REV), m = set, src = me }
        vouchedBy = nil
    end
    return rec.v[me]
end

local function WireEntry(voucher, e)
    return { k = voucher, v = e.rev, m = SetToArray(e.m) }
end

local function SendOwnVouch()
    local me = Util.PlayerKey()
    local e = MyVouch()
    Recompute()
    if not e or not me then return false end
    return Send({ t = "ACB", l = { WireEntry(me, e) } }, "GUILD", nil, "ctrl")
end

-- Everything I hold and may pass on, in parts.
local function SendVouchBatch()
    local rec = AccountsDB(false)
    local me = Util.PlayerKey()
    if not rec or not me then return end
    local keys = {}
    for voucher, e in pairs(rec.v) do
        if ValidEntry(voucher, e) and roster[voucher] and CoversRoles(e.src, voucher) and CoversRoles(me, voucher) then
            keys[#keys + 1] = voucher
        end
    end
    tsort(keys)
    for i = 1, #keys, ACB_PART do
        local l = {}
        for j = i, min(i + ACB_PART - 1, #keys) do l[#l + 1] = WireEntry(keys[j], rec.v[keys[j]]) end
        Send({ t = "ACB", l = l }, "GUILD", nil, "data")
    end
    batchSeenAt = GetTime()
end

local function OnAccounts(sender, msg, dist)
    if (dist ~= "GUILD" and dist ~= "WHISPER") or not ready or type(msg.l) ~= "table" or not roster[sender] then return end
    local rec = AccountsDB(true)
    if not rec then return end
    local changed, n, passedOn = false, 0, false
    for _, raw in pairs(msg.l) do
        n = n + 1
        if n > ACB_PART then break end
        local voucher = type(raw) == "table" and WireKey(raw.k)
        local set = voucher and IsInt(raw.v, 1, min(MAX_REV, Now() + FUTURE_SLACK)) and ParseWireList(raw.m)
        if set then
            set[voucher] = nil
            local count = 0
            for _ in pairs(set) do count = count + 1 end
            if voucher ~= sender then passedOn = true end
            if count > MAX_ACCOUNT_CHARS or not roster[voucher] then
                -- (too long, or not a guild member: dropped)
            elseif Util.IsMe(voucher) then
                -- Somebody holds an entry of me that is not older than mine and says something else (an old
                -- install, a forgery): mine wins, with a newer rev.
                local mine = MyVouch()
                if not Util.IsMe(sender) and raw.v >= (mine and mine.rev or 0) and not (mine and SameSet(mine.m, set)) then
                    rec.v[voucher] = { rev = min(max(floor(Now()), raw.v + 1), MAX_REV), m = mine and mine.m or {},
                                       src = voucher }
                    changed = true
                    Util.Debounce("cdl-acc-own", 2, SendOwnVouch)
                end
            elseif voucher == sender or CoversRoles(sender, voucher) then
                local cur = rec.v[voucher]
                if not ValidEntry(voucher, cur) then cur = nil end
                if not cur then
                    local stored = 0
                    for _ in pairs(rec.v) do stored = stored + 1 end
                    if stored < MAX_VOUCHERS then
                        rec.v[voucher] = { rev = raw.v, m = set, src = sender }
                        changed = true
                    end
                elseif raw.v > cur.rev or (raw.v == cur.rev and voucher == sender and not SameSet(cur.m, set)) then
                    rec.v[voucher] = { rev = raw.v, m = set, src = sender }
                    changed = true
                elseif raw.v == cur.rev and SameSet(cur.m, set) and cur.src ~= voucher
                    and (voucher == sender or not CoversRoles(cur.src, voucher)) then
                    cur.src = sender        -- the same entry from a better source (the character itself)
                    changed = true
                end
            end
        end
    end
    if passedOn and dist == "GUILD" then batchSeenAt = GetTime() end
    if changed then
        vouchedBy = nil
        Recompute()
        ns:Fire("ACCOUNTS_UPDATED")
    end
end

-- Hash of the entries I hold (Sync puts it in HELLO as av); "" while I hold none.
function Guild:GetAccountsHash()
    local rec = AccountsDB(false)
    local list = {}
    for voucher, e in pairs(rec and rec.v or {}) do
        if ValidEntry(voucher, e) and roster[voucher] then list[#list + 1] = voucher .. ":" .. e.rev end
    end
    if #list == 0 then return "" end
    tsort(list)
    return Util.Hash(list)
end

-- Sync calls this for every HELLO (av = the sender's hash; nil from clients before 1.2). The GM, an officer or a
-- guild council member who holds something else answers with what it holds, on GUILD so the others stay quiet.
function Guild:OnAccountsSeen(sender, av)
    if type(av) ~= "string" or type(sender) ~= "string" or not ready or Util.IsMe(sender) then return end
    local me = Util.PlayerKey()
    if not me then return end
    local gm, officer, council = OwnRoles(me)
    if not (gm or officer or council) then return end
    local mine = Guild:GetAccountsHash()
    if mine == "" or mine == av then return end
    if not RateLimit("acb:" .. sender, ACB_PER_MEMBER) then return end
    local asked = GetTime()
    Util.After(OwnJitter(ACB_REPLY_MIN, ACB_REPLY_SPREAD, sender), function()
        if batchSeenAt >= asked or GetTime() - batchSeenAt < ACB_GAP then return end
        SendVouchBatch()
    end)
end

-- The other characters of the player behind `key` that share roles with it: the guild members that vouch for it
-- (sorted), or an empty table.
function Guild:GetAccountMains(key)
    local out = {}
    for _, m in ipairs(Principals(key) or {}) do out[#out + 1] = m end
    tsort(out)
    return out
end

-- My account's characters in this guild as this client knows them (sorted; without me).
function Guild:GetMyCharacters()
    local e = MyVouch()
    return SetToArray(e and e.m)
end

-- Do the two characters belong to one player? Only when each vouches for the other: one character naming another
-- is not enough to answer raids in its name, or to share its blacklist entry.
function Guild:SameAccount(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if a == b then return true end
    local idx = VouchIndex()
    local function vouches(voucher, key)
        for _, m in ipairs(idx[key] or {}) do
            if m == voucher then return true end
        end
        return false
    end
    return vouches(a, b) and vouches(b, a)
end

-- The other characters of the player behind `key` (each vouches for the other; sorted, without `key`).
function Guild:GetLinkedCharacters(key)
    local out = {}
    for _, m in ipairs(Principals(key) or {}) do
        if Guild:SameAccount(key, m) then out[#out + 1] = m end
    end
    tsort(out)
    return out
end

-- /dz account [forget <name>]: which of my characters share their roles; forget one that is not mine any more.
local function SlashAccount(rest)
    local rec = AccountsDB(true)
    if not rec or not ready then
        ns:Print("Your guild is not loaded yet; try again in a moment.")
        return
    end
    local cmd, name = Util.Trim(rest or ""):match("^(%S*)%s*(.-)$")
    if cmd:lower() == "forget" and name ~= "" then
        local key = WireKey(name)
        key = key and CanonicalKey(key)
        if not key or Util.IsMe(key) or not rec.mine[key] then
            ns:Print("'%s' is not one of the other characters of your account here.", name)
            return
        end
        rec.mine[key] = false       -- (false, not nil: the Members tab's own characters don't bring it back)
        SendOwnVouch()
        ns:Fire("ACCOUNTS_UPDATED")
        ns:Print("%s no longer shares your roles.", Util.ShortName(key))
        return
    end
    local mine = Guild:GetMyCharacters()
    if #mine == 0 then
        ns:Print("No other character of your account is known in this guild yet. Log in on each of them once: "
            .. "your characters then share their roles (Guild Master, officer, council, raid leader).")
    else
        local names = {}
        for i, key in ipairs(mine) do names[i] = Util.ShortName(key) end
        ns:Print("Your characters here share their roles: %s. (/dz account forget <name> takes one off.)",
            tconcat(names, ", "))
    end
    local via = Guild:GetAccountMains(Util.PlayerKey())
    if #via > 0 then
        local names = {}
        for i, key in ipairs(via) do names[i] = Util.ShortName(key) end
        ns:Print("This character has the roles of: %s.", tconcat(names, ", "))
    end
end

local function ShareAccountAfterLogin()
    Util.After(OwnJitter(ACC_LOGIN_MIN, ACC_LOGIN_SPREAD, "acc"), function()
        if IsInGuild() and ready then SendOwnVouch() end
    end)
end

-- `real` (optional): ignore my debug role (network code: what the other clients see is my real rank).
-- An officer's other characters are officers too (Accounts above).
function Guild:IsOfficer(key, real)
    local role = not real and type(key) == "string" and DebugRole(key)
    if role then return role == "gm" or role == "officer" end
    local e = type(key) == "string" and roster[key]
    if not e then return false end
    if (tonumber(e.rankIndex) or 99) <= OFFICER_RANK then return true end
    for _, m in ipairs(Principals(key) or {}) do
        local me = roster[m]
        if me and (tonumber(me.rankIndex) or 99) <= OFFICER_RANK then return true end
    end
    return false
end

function Guild:CanEditRaidLeaders()
    return (IsInGuild() and ready and Guild:IsOfficer(Util.PlayerKey())) and true or false
end

-- On the raid leaders list (and in the guild).
function Guild:IsListedRaidLeader(key)
    local role = type(key) == "string" and DebugRole(key)
    if role then return role == "raidleader" end
    local rec = LeadersRec(false)
    if type(key) ~= "string" or rec == nil or not roster[key] then return false end
    if rec.m[key] then return true end
    for _, m in ipairs(Principals(key) or {}) do       -- another character of a listed raid leader
        if rec.m[m] and roster[m] then return true end
    end
    return false
end

-- Plans raids (raids, teams, groups): the GM and the raid leaders list.
function Guild:IsRaidPlanner(key)
    return type(key) == "string" and (Guild:IsGM(key) or Guild:IsListedRaidLeader(key)) and true or false
end

function Guild:AmIRaidPlanner()
    return Guild:IsRaidPlanner(Util.PlayerKey())
end

-- Sees and shares the raid log (attendance, bench, no-shows): raid planners and the guild council.
function Guild:IsRaidLogMember(key)
    return type(key) == "string" and (Guild:IsRaidPlanner(key) or Guild:IsGuildCouncil(key)) and true or false
end

function Guild:AmIRaidLogMember()
    return Guild:IsRaidLogMember(Util.PlayerKey())
end

-- Sorted array of the listed raid leaders (in the guild).
function Guild:GetRaidLeaders()
    local out = {}
    local rec = LeadersRec(false)
    for key in pairs(rec and rec.m or {}) do
        if roster[key] then out[#out + 1] = key end
    end
    tsort(out)
    return out
end

function Guild:GetRaidLeadersRev()
    local rec = LeadersRec(false)
    return rec and rec.rev or 0
end

-- { rev, by, members = { key, ... } } or nil.
function Guild:GetRaidLeadersInfo()
    local rec = LeadersRec(false)
    if not rec or rec.rev == 0 then return nil end
    return { rev = rec.rev, by = rec.by, members = SetToArray(rec.m) }
end

local function SendRLL(target)
    local rec = LeadersRec(false)
    if not rec or rec.rev == 0 then return false end
    local msg = { t = "RLL", rev = rec.rev, m = SetToArray(rec.m), by = rec.by }
    if target then return Send(msg, "WHISPER", target, "ctrl") end
    return Send(msg, "GUILD", nil, "ctrl")
end

-- Officers only: saves the raid leaders list (a set or an array, at most 40) and shares it. Returns ok, err.
function Guild:SetRaidLeaders(list)
    if not ns.loggedIn or not IsInGuild() then return false, "not in a guild" end
    if not ready then return false, "the guild roster has not loaded yet" end
    if not Guild:CanEditRaidLeaders() then return false, "only officers and the Guild Master can change the raid leaders" end
    local set, err = ToSet(list)
    if not set then return false, err end
    local rec = LeadersRec(true)
    if not rec then return false, "your guild is not known yet" end
    rec.rev = max(floor(Now()), rec.rev + 1)
    rec.m, rec.by = set, Util.PlayerKey()
    SendRLL()
    Recompute()
    return true
end

local function OnRaidLeaders(sender, msg, dist)
    if (dist ~= "GUILD" and dist ~= "WHISPER") or not ready or not Guild:IsOfficer(sender) then return end
    if not IsInt(msg.rev, 1, Now() + FUTURE_SLACK) then return end
    local set = ParseWireList(msg.m)
    if not set then return end
    local by = msg.by ~= nil and WireKey(msg.by) or sender
    if not by then return end
    local rec = LeadersRec(true)
    if not rec then return end
    if msg.rev < rec.rev then return end
    if msg.rev == rec.rev then
        local a, b = tconcat(SetToArray(set), ","), tconcat(SetToArray(rec.m), ",")
        if a <= b then return end                      -- the same (or the smaller) list: keep mine
    end
    rec.rev, rec.m, rec.by = msg.rev, set, by
    Recompute()
end

local function OnRaidLeadersQuery(sender, msg, dist)
    if dist ~= "WHISPER" or not Guild:IsOfficer(Util.PlayerKey()) then return end
    if not RateLimit("rlq:" .. sender, RLL_REPLY_LIMIT) then return end
    SendRLL(sender)
end

-- Sync calls this for every HELLO (rlr = the sender's list rev; nil from clients before 0.7).
function Guild:OnRaidLeadersRevSeen(sender, rlr)
    if type(rlr) ~= "number" or type(sender) ~= "string" then return end
    local mine = Guild:GetRaidLeadersRev()
    if rlr < mine and Guild:IsOfficer(Util.PlayerKey()) then
        if RateLimit("rll-reply:" .. sender, RLL_REPLY_LIMIT) then
            Util.RandomDelay(0.5, 3, function() SendRLL(sender) end)
        end
    elseif rlr > mine and Guild:IsOfficer(sender) then
        if RateLimit("rlq-ask:" .. sender, RLL_REPLY_LIMIT) then
            Send({ t = "RLQ" }, "WHISPER", sender, "ctrl")
        end
    end
end

local function ShareRaidLeadersAfterLogin()
    Util.RandomDelay(RLL_LOGIN_MIN, RLL_LOGIN_MAX, function()
        if Guild:IsOfficer(Util.PlayerKey()) and Guild:GetRaidLeadersRev() > 0 then SendRLL() end
    end)
end

local ROLE_HELP = "gm | officer | council | raidleader | raider | off"
local ROLE_TEXT = {
    gm = "Guild Master", officer = "officer (picks raid leaders)", council = "guild / loot council",
    raidleader = "raid leader (on the list)", raider = "plain raider",
}

local function SlashRole(rest)
    local want = Util.Trim(rest or ""):lower()
    local db = ns.db
    if not db then return end
    if want == "" then
        local r = DebugRole()
        ns:Print("Debug role: %s. Usage: /dz role %s", r and ROLE_TEXT[r] or "off (your real role)", ROLE_HELP)
        return
    end
    if want == "off" then
        db.debugRole = nil
    elseif DEBUG_ROLES[want] then
        db.debugRole = want
    else
        ns:Print("Unknown role '%s'. Usage: /dz role %s", want, ROLE_HELP)
        return
    end
    ns:Print("Debug role: %s. This only changes your own screen: other players' addons still use your real rank "
        .. "and lists, so data your real role doesn't get won't arrive.", db.debugRole and ROLE_TEXT[db.debugRole] or "off")
    Recompute()
    ns:Fire("CONFIG_UPDATED", Snapshot())   -- repaint even when the effective council set didn't change
end

function Guild:GetDebugRole() return DebugRole() end

function Guild:OnInit()
    if DebugAllowed() then ns:RegisterSlash("role", SlashRole, "(debug) pretend to be: " .. ROLE_HELP) end
    ns:RegisterSlash("account", SlashAccount, "which of your characters share their roles (forget <name> takes one off)")
    CouncilDB()
    ns:RegisterEvent("GUILD_ROSTER_UPDATE", OnRosterUpdate)
    ns:RegisterEvent("PLAYER_GUILD_UPDATE", OnGuildChanged)
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", RefreshRaidState)
    ns:RegisterEvent("PARTY_LEADER_CHANGED", RefreshRaidState)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", RefreshRaidState)
    ns:On("GROUP_UPDATED", Recompute)          -- raid council members joining / leaving the raid
    ns:On("GROUP_RULES_CHANGED", Recompute)    -- the group's phase
    ns:On("SETTINGS_CHANGED", function(path)
        if path == "groupPhase" then Recompute() end
    end)
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("CG", OnGuildCouncil)
        Comm:Register("CQ", OnGuildCouncilQuery)
        Comm:Register("CR", OnRaidCouncil)
        Comm:Register("CRQ", OnRaidCouncilQuery)
    end
    if ns.Comm and ns.Comm.Register then
        ns.Comm:Register("RLL", OnRaidLeaders)          -- Addendum J §62
        ns.Comm:Register("RLQ", OnRaidLeadersQuery)
        ns.Comm:Register("ACB", OnAccounts)             -- accounts: a player's characters share their roles
    end
end

function Guild:OnLogin()
    if DebugRole() then
        Util.After(8, function()
            local r = DebugRole()
            if r then ns:Print("Debug role active: %s (/dz role off to stop).", ROLE_TEXT[r]) end
        end)
    end
    RefreshGuildName()
    RefreshGuildList()
    local DB = ns.DB
    if DB and DB.legacyTagNotice then
        DB.legacyTagNotice = nil
        ns:Print("%s", LEGACY_TAG_NOTICE)
    end
    if IsInGuild() then
        Guild:RequestRoster(true)
        Util.Debounce("guild-roster-retry", ROSTER_RETRY_DELAY, function()
            if not ready and IsInGuild() then Guild:RequestRoster(true) end
        end)
        ScheduleLoginQuery()
    end
    if not pollTicker and C_Timer and C_Timer.NewTicker then
        -- Keeps online flags fresh; the request itself is cheap and throttled.
        pollTicker = C_Timer.NewTicker(ROSTER_POLL_INTERVAL, function()
            if IsInGuild() then Guild:RequestRoster() end
        end)
    end
    RefreshRaidState()
    ShareRaidLeadersAfterLogin()
    ShareAccountAfterLogin()
end

---------------------------------------------------------------------------
-- Public API: roster
---------------------------------------------------------------------------

-- Asks the server for a fresh roster (at most every 15s unless forced).
function Guild:RequestRoster(force)
    if not IsInGuild() then return false end
    local now = GetTime()
    if not force and now - lastRequest < ROSTER_REQUEST_INTERVAL then return false end
    lastRequest = now
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
        return true
    end
    return false
end

function Guild:IsReady()
    return ready
end

function Guild:GetGuildName()
    if not guildName then RefreshGuildName() end
    return guildName
end

-- "Guild Name-Realm" of the player's current guild, or nil (scopes account-wide data per guild).
function Guild:GetGuildKey()
    if not guildName then RefreshGuildName() end
    return GuildKey()
end

-- `real` (optional, DisasterZone extension): ignore Demo data. Network code always passes true.
function Guild:GetMember(key, real)
    if type(key) ~= "string" then return nil end
    local m = roster[key]
    if m then return m end
    if not real then
        local demo = DemoRoster()
        local d = demo and demo[key]
        if type(d) == "table" then return d end
    end
    return nil
end

function Guild:IsInGuild(key, real)
    return Guild:GetMember(key, real) ~= nil
end

function Guild:IsOnline(key, real)
    if type(key) ~= "string" then return false end
    if Util.IsMe(key) then return true end
    local m = Guild:GetMember(key, real)
    return (m and m.online) and true or false
end

function Guild:GetClass(key)
    local m = Guild:GetMember(key)
    return m and m.classFile or nil
end

function Guild:GetRankName(key)
    local m = Guild:GetMember(key)
    return m and m.rankName or nil
end

function Guild:GetMembers()
    local keys = {}
    for key in pairs(roster) do keys[#keys + 1] = key end
    local demo = DemoRoster()
    if demo then
        for key in pairs(demo) do
            if type(key) == "string" and not roster[key] then keys[#keys + 1] = key end
        end
    end
    tsort(keys)
    return keys
end

-- Sorted keys of the online guild members (real roster; I count as online). For the council picker.
function Guild:GetOnlineMembers()
    local out = {}
    local me = Util.PlayerKey()
    for key, m in pairs(roster) do
        if m.online or key == me then out[#out + 1] = key end
    end
    tsort(out)
    return out
end

-- DisasterZone extensions used by Comm (not in the spec): a whisper/addon message from someone proves
-- they are online; a "No player named ..." system message proves they are not.
function Guild:MarkOnline(key)
    local m = type(key) == "string" and roster[key]
    if m then m.online = true end
end

function Guild:MarkOffline(key)
    local m = type(key) == "string" and roster[key]
    if m then m.online = false end
end

---------------------------------------------------------------------------
-- Public API: council (Addendum E §29)
---------------------------------------------------------------------------

function Guild:GetGM()
    return gmKey
end

function Guild:IsGM(key)
    local role = DebugRole(key)
    if role then return role == "gm" end
    return IsGMKey(key)
end

-- GM, or on the guild list, or (in a raid) the raid leader / on the raid's council list.
-- `real` (DisasterZone extension): ignore demo mode. Demo mode makes me (and the fake officers) council.
function Guild:IsCouncil(key, real)
    if type(key) ~= "string" then return false end
    if not real and DemoOn() then
        if Util.IsMe(key) or DemoCouncil(key) then return true end
    end
    return RealSource(key) ~= nil
end

function Guild:AmICouncil(real)
    local me = Util.PlayerKey()
    return me ~= nil and Guild:IsCouncil(me, real)
end

-- "gm" | "guild" | "raidleader" | "raid" | nil (for UI labels).
function Guild:GetCouncilSource(key)
    local s = RealSource(key)
    if s then return s end
    if type(key) == "string" and DemoOn() and DemoCouncil(key) then return "guild" end
    return nil
end

-- DisasterZone extension: guild-wide council (the GM or on the guild list), not raid-scope.
function Guild:IsGuildCouncil(key)
    local s = RealSource(key)
    return s == "gm" or s == "guild"
end

-- Sorted array of every council member (demo mode adds me and the fake officers).
function Guild:GetCouncilMembers()
    local set = EffectiveCouncilSet()
    if DemoOn() then
        local me = Util.PlayerKey()
        if me then set[me] = true end
        for key in pairs(DemoRoster() or {}) do
            if type(key) == "string" and DemoCouncil(key) then set[key] = true end
        end
    end
    return SetToArray(set)
end

-- The guild council list as accepted (a copy), or nil.
function Guild:GetGuildCouncil()
    local rec = guildList
    if not rec then return nil end
    return { rev = rec.rev, members = CopySet(rec.members), phase = rec.phase, by = rec.by, recvAt = rec.recvAt,
             de = rec.de, bank = rec.bank }
end


-- DisasterZone extension: rev of my accepted guild list (0 = none). Sent in HELLO / STATE as `cg`.
function Guild:GetGuildCouncilRev()
    return guildList and guildList.rev or 0
end

-- DisasterZone 0.5: true while my guild list came by trust on first use and no CG from the GM confirmed it yet
-- (Sync then advertises no cg: the list is not re-served).
function Guild:IsGuildCouncilUnconfirmed()
    return IsTofu(guildList)
end

function Guild:CanEditGuildCouncil()
    return (IsInGuild() and ready and Guild:IsGM(Util.PlayerKey())) and true or false
end

-- GM only: saves the guild council list (a set {[key]=true} or an array of keys, at most 40), the
-- guild phase (1..5; nil keeps the current one) and the loot targets (Addendum G: { de = key | false,
-- bank = key | false }, nil / a missing field keeps the current one), then shares it on GUILD. Returns ok, err.
function Guild:SetGuildCouncil(membersSet, phase, targets)
    if not ns.loggedIn or not IsInGuild() then return false, "not in a guild" end
    if not ready then return false, "the guild roster has not loaded yet" end
    if not Guild:CanEditGuildCouncil() then return false, "only the Guild Master can change the guild council" end
    local set, err = ToSet(membersSet)
    if not set then return false, err end
    local cur = guildList
    if phase == nil then phase = cur and cur.phase or DEFAULT_PHASE end
    phase = tonumber(phase)
    if not IsInt(phase, 1, MaxPhase()) then return false, "invalid phase" end
    local tg, terr = MergeTargets(targets, cur)
    if not tg then return false, terr end
    local rev = max(floor(Now()), (cur and cur.rev or 0) + 1)
    StoreGuildList({ rev = rev, members = set, phase = phase, de = tg.de, bank = tg.bank }, Util.PlayerKey(), "self")
    if not guildList then return false, "could not save the list" end
    SendCG(guildList)
    Recompute()
    return true
end

-- The raid council accepted for my CURRENT raid (a copy { leader, rev, members }), or nil. While I lead
-- the raid it is my own raid list.
-- Server time I joined my current raid, or nil.
function Guild:GetRaidSince()
    return raidSince
end

function Guild:GetRaidCouncil()
    if not IsInRaid() then return nil end
    local leader = CurrentRaidLeader()
    local rc = raidCouncil
    if not rc or rc.leader ~= leader then
        if AmILeadingRaid() then
            rc = OwnRaidCouncil()
        else
            return nil
        end
    end
    return { leader = rc.leader, rev = rc.rev, members = CopySet(rc.members), de = rc.de, bank = rc.bank }
end

-- My own saved raid list (a copy { rev, members, de, bank }), or nil.
function Guild:GetMyRaidList()
    local rec = MyRaidList()
    if not rec then return nil end
    return { rev = rec.rev, members = CopySet(rec.members), de = rec.de, bank = rec.bank }
end

-- Saves my raid list "until changed" (a set or an array of keys, at most 40; raid members of any guild) and
-- the raid's loot targets (Addendum G; like SetGuildCouncil's `targets`). While I lead a raid it becomes that
-- raid's council at once and is shared (CR). Returns ok, err.
function Guild:SetMyRaidList(membersSet, targets)
    local c = CouncilDB()
    if not c then return false, "settings are not loaded yet" end
    local set, err = ToSet(membersSet)
    if not set then return false, err end
    local cur = MyRaidList()
    local tg, terr = MergeTargets(targets, cur)
    if not tg then return false, terr end
    c.myRaidList = { rev = max(floor(Now()), (cur and cur.rev or 0) + 1), members = set, de = tg.de, bank = tg.bank }
    if AmILeadingRaid() then
        raidLeader = Util.PlayerKey()
        inRaid = true
        raidCouncil = OwnRaidCouncil()
        ScheduleCR(0.1)
    end
    Recompute()
    return true
end

-- Addendum G §41: the character that gets "de" (disenchant) or "bank" (guild bank) awards, and where that comes
-- from: key, "raid" (the current raid leader's pick for this raid) | "guild" (the GM's pick). nil when unset.
-- The raid's pick wins while I am in that raid; demo mode picks a fake raider so the buttons can be tried.
function Guild:GetLootTarget(kind)
    if not TARGET_KINDS[kind] then return nil end
    if IsInRaid() then
        local leader = CurrentRaidLeader()
        local rc = raidCouncil
        if leader and Util.IsMe(leader) then rc = OwnRaidCouncil() end
        if rc and rc.leader == leader and type(rc[kind]) == "string" then return rc[kind], "raid" end
    end
    local rec = guildList
    if rec and type(rec[kind]) == "string" then return rec[kind], "guild" end
    if DemoOn() and ns.Demo and ns.Demo.GetLootTarget then
        local key = ns.Demo:GetLootTarget(kind)
        if key then return key, "demo" end
    end
    return nil
end

function Guild:IsRaidLeader(key)
    if type(key) ~= "string" or not IsInRaid() then return false end
    if Util.IsMe(key) then return AmILeadingRaid() end
    return key == CurrentRaidLeader()
end

function Guild:AmIRaidLeader()
    return AmILeadingRaid()
end

-- HELLO / STATE piggyback (Addendum E §31): a council member holds guild list rev `rev`. When mine is
-- older, ask that member by whisper (CQ). Returns true when a query was sent.
function Guild:OnCouncilRevSeen(sender, rev)
    if type(sender) ~= "string" or not IsInt(rev, 1, MAX_REV) or rev > Now() + FUTURE_SLACK then return false end
    if not IsInGuild() or Util.IsMe(sender) or not roster[sender] then return false end   -- guild members only
    -- An unconfirmed list asks the GM whenever the GM advertises another rev (the GM's CG then replaces it).
    local tofuVsGM = IsTofu(guildList) and sender == gmKey and rev ~= guildList.rev
    if rev <= (guildList and guildList.rev or 0) and not tofuVsGM then return false end
    local now = GetTime()
    if cqInFlight and cqInFlight.rev >= rev and now - cqInFlight.at < CQ_INFLIGHT and not tofuVsGM then
        return false
    end
    if not RateLimit("cq-w:" .. sender, CQ_REPLY_LIMIT) then return false end
    cqInFlight = { rev = rev, at = now }
    Util.RandomDelay(0.5, 2, function()
        if (guildList and guildList.rev or 0) < rev or (IsTofu(guildList) and sender == gmKey) then
            SendCQ("WHISPER", sender)
        end
    end)
    return true
end

---------------------------------------------------------------------------
-- Public API: phase (Addendum E §32)
---------------------------------------------------------------------------

-- DisasterZone extension: the guild council phase (set by the GM with the list), else 1. No group rules.
function Guild:GetCouncilPhase()
    local p = guildList and guildList.phase
    if IsInt(p, 1, MaxPhase()) then return p end
    return DEFAULT_PHASE
end

-- The group-rules phase while in a group with rules, else the guild council phase, else 1.
function Guild:GetGuildPhase()
    local DB = ns.DB
    local p = DB and DB.GetEffective and tonumber(DB:GetEffective("phase"))
    if not p then p = Guild:GetCouncilPhase() end
    p = floor(p)
    if p < 1 then p = 1 elseif p > MaxPhase() then p = MaxPhase() end
    return p
end

-- The personal phase override (settings.viewPhase) on top of GetGuildPhase().
function Guild:GetViewPhase()
    local settings = ns.db and ns.db.settings
    local vp = settings and tonumber(settings.viewPhase)
    if vp and vp >= 1 and vp <= MaxPhase() and vp == floor(vp) then
        return vp
    end
    return Guild:GetGuildPhase()
end

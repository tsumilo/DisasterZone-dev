if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Sync.lua", ...) then return end -- DisasterZone: sync protocol between guild members and the loot council.
-- HELLO / STATE / MANIFEST / WANT / LIST / RELAY flows, peer tracking, restore of a lost list.
-- Owners are the only writers of their list (rev numbers); council clients cache and relay.
-- Addendum E: council members carry the rev of their guild council list in HELLO / STATE ("cg") so an
-- outdated client asks them for it (Guild CQ). Everyone's lists and the award log are exchanged between
-- guild-wide council members (the GM and the guild list); a raid-scope council member (raid leader / raid
-- list) receives the lists of the raid's members from the members themselves. 1.3: only while the raid runs with the
-- loot council (after Start raid, GroupRules:IsLootCouncilOn), and only for that raid session: their copies are
-- dropped on their own client afterwards (Store), so each raid session gets the lists again.
local addonName, ns = ...

local Sync = ns:NewModule("Sync")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local floor, max, min, random = math.floor, math.max, math.min, math.random
local tsort = table.sort
local strformat = string.format

local HELLO_RATE = 30              -- seconds between HELLOs
local REPLY_RATE = 20              -- seconds between our S/M replies to the same HELLO sender
local STATE_GAP = 2                -- seconds between two S replies when several wait (a login wave): half of the
                                   -- server's allowance for the control prefix stays free for everything else
local WANT_BATCH = 40              -- names per W
local RELAY_BATCH = 8              -- entries per R
local MAX_WANT_NAMES = 40
local MAX_RELAY_ENTRIES = 20
local MAX_MANIFEST_ENTRIES = 2000
local MAX_PENDING_WANT = 400
local MAX_REV = ns.MAX_REV or 2147483647
local MAX_REV_JUMP = 100000        -- a council rev of my own list this far above mine is implausible
local REQUEST_STALE = 60           -- a WANT without answer is forgotten after this
local RESTORE_WINDOW = 60          -- seconds a restore request stays open
local PUSH_REPEAT_GUARD = 30       -- do not re-push the same rev to the same peer within this
local PERIODIC_INTERVAL = 600      -- council <-> council manifest exchange
local PEER_FORGET = 90 * 86400
local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"   -- the default font has no check glyph

local peersDB                      -- ns.db.peers: [key] = { v=, c=, lastSeen= } (+ sharedRev/sharedTs for me)
local sessionSeen = {}             -- [key] = true: sent us H/S/M/R this session
local pushed = {}                  -- [councilKey] = { rev=, at= }
local requested = {}               -- [ownerKey] = rev asked for with W
local requestedAt = {}             -- [ownerKey] = GetTime()
local pendingWant = {}             -- [requester] = { names = {[key]=true}, count=, scheduled= }
local restorePending               -- { from=, rev=, at= }
local restoreOffer                 -- best offer seen: { from=, rev= }
local restoreAsked = {}            -- [key] = true: I sent that peer a restore W in the current restore window
local restorePopupShown = false
local incompatible = {}            -- [key] = protocol major
local protocolNoted = {}           -- [key] = true: incompatible-version notice already printed
local sessionNonce                 -- sent in H so a /reload within REPLY_RATE still gets its S/M replies
local newerVersionNoted = false
local sharedRev, lastSharedTs
local helloScheduledFor            -- guild name the automatic HELLO was scheduled for
local wasCouncil
local periodicTicker
local councilHelloAt = {}          -- [key] = GetTime() of their last HELLO with c = true
local raidShared = {}              -- [key] = raid session id: a raid-scope council member my list is for in that session
local RAID_PUSH_MIN, RAID_PUSH_MAX = 10, 15   -- push to a newly picked raid-scope council member (unless
                                              -- their promotion HELLO arrived meanwhile)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function IsRev(x)
    return type(x) == "number" and x == floor(x) and x >= 0 and x <= MAX_REV
end

local function NormKey(s)
    if type(s) ~= "string" or s == "" or #s > 64 or s:find("[%c|]") then return nil end
    return Util.NormalizeName(s)
end

local function AmCouncil()
    return ns.Guild ~= nil and ns.Guild:AmICouncil(true)
end

local function IsCouncil(key)
    return ns.Guild ~= nil and ns.Guild:IsCouncil(key, true)
end

-- Guild-wide council: the GM or on the guild council list (not raid-scope).
local function IsGuildCouncil(key)
    local Guild = ns.Guild
    if not Guild then return false end
    if Guild.IsGuildCouncil then return Guild:IsGuildCouncil(key) and true or false end
    return Guild:IsCouncil(key, true) and true or false
end

local function AmGuildCouncil()
    local me = Util.PlayerKey()
    return me ~= nil and IsGuildCouncil(me)
end

-- Manifests, pulls, relays of other members' lists and the award log run between guild-wide council
-- members only (Addendum E §29: raid-scope council is council for that raid only).
local function FullPair(key)
    return IsGuildCouncil(key) and AmGuildCouncil()
end

-- 1.3: the raid runs with the loot council (a raid session after Start raid with it on): only then do raid-scope
-- council members get the raiders' lists.
local function RaidListsOpen()
    local GR = ns.GroupRules
    return (GR and GR.IsLootCouncilOn and GR:IsLootCouncilOn()) and true or false
end

-- May key (a council member in my view) get BiS lists now? The guild council always; a raid-scope council member
-- (raid leader, raid list) only while the raid runs with the loot council.
local function ListsFor(key)
    return IsGuildCouncil(key) or RaidListsOpen()
end

-- A member of my current (real) raid.
local function InMyRaid(key)
    if type(key) ~= "string" or not IsInRaid() then return false end
    if Util.IsMe(key) then return true end
    local g = Util.group
    return type(g) == "table" and g[key] ~= nil
end

-- May I relay owner's cached list to requester (a council member in my view)?
local function MayRelay(requester, owner)
    if FullPair(requester) then return true end
    return InMyRaid(requester) and InMyRaid(owner) and ListsFor(requester)
end

-- My guild council list rev for HELLO / STATE ("cg"), when I can relay that list (GM / guild list).
local function OwnCouncilRev()
    local Guild = ns.Guild
    if not (Guild and Guild.GetGuildCouncilRev) or not AmGuildCouncil() then return nil end
    -- A list taken on trust (not confirmed by the GM yet) is never advertised / re-served (DisasterZone 0.5).
    if Guild.IsGuildCouncilUnconfirmed and Guild:IsGuildCouncilUnconfirmed() then return nil end
    local rev = Guild:GetGuildCouncilRev()
    return (type(rev) == "number" and rev > 0) and rev or nil
end

-- A council member holds guild list rev cg: Guild asks for it when mine is older.
local function NoteCouncilRev(sender, cg)
    local Guild = ns.Guild
    if type(cg) == "number" and Guild and Guild.OnCouncilRevSeen then
        Guild:OnCouncilRevSeen(sender, cg)
    end
end

local function OwnRecord()
    local BiS = ns.BiS
    if BiS and BiS.GetRecord then return BiS:GetRecord() end
    return nil
end

local function OwnRev()
    local rec = OwnRecord()
    return (rec and IsRev(rec.rev)) and rec.rev or 0
end

local function Send(msg, dist, target, class)
    local Comm = ns.Comm
    return Comm ~= nil and Comm:Send(msg, dist, target, class)
end

local function RateLimit(key, seconds)
    local Comm = ns.Comm
    return Comm ~= nil and Comm:RateLimit(key, seconds)
end

local function LedgerDigest()
    local Ledger = ns.Ledger
    if Ledger and Ledger.GetDigest then return Ledger:GetDigest() end
    return nil
end

-- Addendum I §50: the raid log's digest rides along with the ledger's.
-- (1.3.5: rd stays what older clients compare, without the attendance fields; rd2 has them)
local function RaidDigest()
    local RL = ns.RaidLog
    if RL and RL.GetDigest then return RL:GetDigest(true) end
    return nil
end

local function RaidDigest2()
    local RL = ns.RaidLog
    if RL and RL.GetDigest then return RL:GetDigest() end
    return nil
end

local function RaidSync(sender, digest)
    local RL = ns.RaidLog
    if type(digest) == "table" and RL and RL.SyncFromDigest then RL:SyncFromDigest(sender, digest) end
end

local function LedgerSync(sender, digest)
    local Ledger = ns.Ledger
    if type(digest) == "table" and Ledger and Ledger.SyncFromDigest then
        Ledger:SyncFromDigest(sender, digest)
    end
end

local function SlotsHavePicks(slots)
    if type(slots) ~= "table" then return false end
    for _, pair in pairs(slots) do
        if type(pair) == "table" and ((tonumber(pair[1]) or 0) > 0 or (tonumber(pair[2]) or 0) > 0) then
            return true
        end
    end
    return false
end

-- Any pick on my lists: every raid phase of both specs (ph / op) and the Pre-raid lists (pr / opr). A list with
-- picks only there is not a fresh install, so a newer council copy asks before it replaces it.
local function HasAnyPicks(data)
    if type(data) ~= "table" then return false end
    for _, ph in ipairs({ data.ph or false, data.op or false }) do
        if type(ph) == "table" then
            for _, slots in pairs(ph) do
                if SlotsHavePicks(slots) then return true end
            end
        end
    end
    return SlotsHavePicks(data.pr) or SlotsHavePicks(data.opr)
end

-- Snapshot of my committed list in wire shape {r, ts, h, d}, or nil if there is nothing to send.
-- Pending edits are committed first so the hash always matches the data we send.
local function OwnEntry()
    local BiS = ns.BiS
    local rec = OwnRecord()
    if not rec then return nil end
    if BiS.IsDirty and BiS:IsDirty() and BiS.Commit then
        BiS:Commit()
    end
    if not IsRev(rec.rev) or rec.rev <= 0 or type(rec.data) ~= "table" or type(rec.hash) ~= "string" then
        return nil
    end
    if Util.Hash(rec.data) ~= rec.hash then
        ns:Debug("Sync: own list hash is out of date; not sending")
        return nil
    end
    return { r = rec.rev, ts = tonumber(rec.ts) or 0, h = rec.hash, d = rec.data }
end

---------------------------------------------------------------------------
-- Peers & status
---------------------------------------------------------------------------

local function FirePeersUpdated()
    Util.Debounce("sync-peers", 0.3, function() ns:Fire("PEERS_UPDATED") end)
end

local function NotePeer(key, v, c)
    if not peersDB then return end
    local p = peersDB[key]
    if type(p) ~= "table" then
        p = {}
        peersDB[key] = p
    end
    if type(v) == "string" and #v <= 24 and not v:find("[%c|]") then
        p.v = v
        if not newerVersionNoted and Util.CompareVersions(v, ns.version) > 0 then
            newerVersionNoted = true
            local Boot = ns.Boot
            if Boot and not Boot.isDev and Boot.svFirst ~= false then
                -- (Core/Patch.lua fetches it when it is an in-game update; the popup follows)
                ns:Print("A newer DisasterZone version (%s) is in use by %s. If it is an in-game update you get it by itself "
                    .. "in a moment (/dz update shows the progress); if nothing arrives, please download it.",
                    v, Util.ShortName(key))
            else
                ns:Print("A newer DisasterZone version (%s) is in use by %s. Please update.", v, Util.ShortName(key))
            end
        end
    end
    if c ~= nil then p.c = c and true or false end
    p.lastSeen = GetServerTime()
end

-- A council rev of my own list is accepted unless it is absurdly far above mine (buggy / hostile
-- peer); a fresh install (rev 0) accepts any valid rev so it can be restored.
local function PlausibleOwnRev(rev)
    local mine = OwnRev()
    return mine == 0 or rev <= mine + MAX_REV_JUMP
end

local function OwnHash()
    local rec = OwnRecord()
    return rec and type(rec.hash) == "string" and rec.hash or nil
end

local function MarkSeen(key, v, c)
    local wasSeen = sessionSeen[key]
    sessionSeen[key] = true
    NotePeer(key, v, c)
    FirePeersUpdated()
    if not wasSeen then ns:Fire("SYNC_STATUS") end
end

-- A council peer holds exactly my current rev (or I just pushed it).
local function MarkShared(rev)
    if not IsRev(rev) or rev <= 0 or rev ~= OwnRev() then return end
    sharedRev = rev
    lastSharedTs = GetServerTime()
    local me = Util.PlayerKey()
    if peersDB and me then
        local p = type(peersDB[me]) == "table" and peersDB[me] or {}
        p.v = ns.version
        p.sharedRev, p.sharedTs = sharedRev, lastSharedTs
        p.lastSeen = lastSharedTs   -- keeps the 90-day peer prune from dropping my own marker
        peersDB[me] = p
    end
    ns:Fire("SYNC_STATUS")
end

function Sync:GetOnlineCouncilPeers()
    local out = {}
    local Guild = ns.Guild
    if not Guild then return out end
    local me = Util.PlayerKey()
    for key in pairs(sessionSeen) do
        if key ~= me and Guild:IsCouncil(key, true) and Guild:IsOnline(key, true) then
            out[#out + 1] = key
        end
    end
    tsort(out)
    return out
end

function Sync:GetPeer(key)
    if not peersDB or type(key) ~= "string" then return nil end
    if Util.IsMe(key) then
        return { v = ns.version, c = AmCouncil(), lastSeen = GetServerTime() }
    end
    local p = peersDB[key]
    return type(p) == "table" and p or nil
end

-- kind: "none" (no guild), "busy" (waiting or sending), "ok" (shared), "warn" (not shared: no council online)
local function Status()
    if not IsInGuild() then return "none", "Not in a guild" end
    local Guild = ns.Guild
    if not (Guild and Guild:IsReady()) then return "busy", "Waiting for guild roster…" end
    local BiS = ns.BiS
    if BiS and BiS.IsDirty and BiS:IsDirty() then return "busy", "Changes pending…" end
    local rev = OwnRev()
    if rev > 0 and sharedRev == rev and lastSharedTs then
        return "ok", "Shared with council " .. CHECK .. " " .. Util.FormatAgo(lastSharedTs)
    end
    if #Sync:GetOnlineCouncilPeers() == 0 then
        return "warn", "Not shared yet — no council member online"
    end
    return "busy", "Sharing with council…"
end

function Sync:GetStatusText()
    local _, text = Status()
    return text
end

-- Returns kind, text (kinds as in Status above).
function Sync:GetStatus()
    return Status()
end

function Sync:GetVersions()
    local out = {}
    local Guild = ns.Guild
    local me = Util.PlayerKey()
    if me then
        out[#out + 1] = { key = me, v = ns.version, lastSeen = GetServerTime(), online = true, c = AmCouncil() }
    end
    if peersDB then
        for key, p in pairs(peersDB) do
            if key ~= me and type(p) == "table" and (not Guild or not Guild:IsReady() or Guild:IsInGuild(key, true)) then
                out[#out + 1] = {
                    key = key, v = p.v, lastSeen = p.lastSeen,
                    online = (sessionSeen[key] and Guild and Guild:IsOnline(key, true)) and true or false,
                    c = Guild and Guild:IsCouncil(key, true) or false,
                    incompatible = incompatible[key],
                }
            end
        end
    end
    tsort(out, function(a, b) return a.key < b.key end)
    for _, e in ipairs(out) do
        e[1], e[2], e[3], e[4] = e.key, e.v, e.lastSeen, e.online   -- positional form as well
    end
    return out
end

function Sync:NotePeerProtocol(key, major)
    if type(key) ~= "string" then return end
    major = tostring(major or "?")
    if not major:find("^[0-9A-Za-z]$") then major = "?" end
    if incompatible[key] ~= major then
        incompatible[key] = major
        FirePeersUpdated()
    end
    if protocolNoted[key] then return end   -- one notice per sender per session
    protocolNoted[key] = true
    ns:Print("%s uses an incompatible DisasterZone version (protocol %s, yours %s). One of you should update.",
        Util.ShortName(key), major, tostring(ns.PROTO))
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

-- force: skip the HELLO rate limit (used once for the promotion HELLO, which must not be lost).
function Sync:SendHello(force)
    if not ns.loggedIn or not IsInGuild() then return false end
    local Guild = ns.Guild
    if not (Guild and Guild:IsReady()) then return false end
    if force then
        RateLimit("hello", 0)   -- record it for the next rate check
    elseif not RateLimit("hello", HELLO_RATE) then
        return false
    end
    local msg = { t = "H", r = OwnRev(), v = ns.version, n = sessionNonce }
    msg.cg = OwnCouncilRev()   -- DisasterZone 0.3 (Addendum E §31): my guild council list rev
    if AmCouncil() then
        msg.c = true
        msg.m = ns.Store and ns.Store:GetManifest() or {}
        -- DisasterZone 0.2: hashes too, so an online owner spots a same-rev copy with other data (only in the
        -- login HELLO; STATE carries the hash for the owner's own login).
        msg.mh = ns.Store and ns.Store.GetManifestHashes and ns.Store:GetManifestHashes(msg.m) or nil
        msg.ld = LedgerDigest()
        msg.rd = RaidDigest()
        msg.rd2 = RaidDigest2()
    elseif (Guild.AmIRaidLogReader and Guild:AmIRaidLogReader()) or (Guild.AmIRaidLogMember and Guild:AmIRaidLogMember()) then
        -- Addendum J §62: raid leaders exchange the raid log (never lists or the award log); 1.3.5: officers too
        msg.rd = RaidDigest()
        msg.rd2 = RaidDigest2()
    end
    if Guild.GetRaidLeadersRev then msg.rlr = Guild:GetRaidLeadersRev() end   -- Addendum J §62
    if Guild.GetAccountsHash then msg.av = Guild:GetAccountsHash() end        -- accounts (Guild.lua)
    -- Addendum J §56: everyone carries the hash of their raid plan data (0.6 clients ignore it).
    local RaidPlan = ns.RaidPlan
    if RaidPlan and RaidPlan.GetDigestHash then msg.pd = RaidPlan:GetDigestHash() end
    if RaidPlan and RaidPlan.GetBlacklistRev then msg.blr = RaidPlan:GetBlacklistRev() end   -- the raid blacklist
    local GuestBook = ns.GuestBook
    if GuestBook and GuestBook.GetNotesRev then msg.gnr = GuestBook:GetNotesRev() end   -- the guest book's notes (1.3)
    -- Addendum K: the hash of my strategy boards and raid assignments (older clients ignore it).
    local Strategy = ns.Strategy
    if Strategy and Strategy.GetDigestHash then msg.sd = Strategy:GetDigestHash() end
    -- 1.3.2: the hash of the guild's events (library, calendar, results, season; Core/Events.lua)
    local Events = ns.Events
    if Events and Events.GetDigestHash then msg.ed = Events:GetDigestHash() end
    -- 1.3.4: the hash of the guild's polls (Core/Polls.lua)
    local Polls = ns.Polls
    if Polls and Polls.GetDigestHash then msg.od = Polls:GetDigestHash() end
    -- 1.3.5: the hash of the guild's prized items and their loot rules (Core/Prized.lua)
    local Prized = ns.Prized
    if Prized and Prized.GetDigestHash then msg.zd = Prized:GetDigestHash() end
    return Send(msg, "GUILD", nil, "ctrl")
end

-- "Request sync" (slash command and buttons). Prints the outcome; true if a HELLO was sent.
function Sync:RequestSync()
    if not IsInGuild() then
        ns:Print("You are not in a guild; there is nothing to sync.")
        return false
    end
    if not (ns.Guild and ns.Guild:IsReady()) then
        ns:Print("Waiting for the guild roster; try again in a moment.")
        if ns.Guild then ns.Guild:RequestRoster(true) end
        return false
    end
    if Sync:SendHello() then
        ns:Print("Sync requested.")
        return true
    end
    ns:Print("A sync was requested less than %d seconds ago; please wait.", HELLO_RATE)
    return false
end

local function SendManifest(target, query)
    if not AmCouncil() or not ns.Store then return false end
    local msg = { t = "M", m = ns.Store:GetManifest(), ld = LedgerDigest(), rd = RaidDigest(), rd2 = RaidDigest2() }
    if query then msg.q = true end   -- DisasterZone extension: "please answer with your manifest"
    return Send(msg, "WHISPER", target, "ctrl")
end

-- Pushes my list to one council member. `evidence` = the peer just told us it lacks this rev,
-- so a push remembered from earlier (maybe lost with a crash) may be repeated.
function Sync:PushListTo(key, evidence)
    if type(key) ~= "string" or Util.IsMe(key) or not IsInGuild() then return false end
    if not IsCouncil(key) then return false end   -- lists only go to the council
    if not ListsFor(key) then return false end    -- 1.3: raid-scope council only while the loot council runs
    local entry = OwnEntry()
    if not entry then return false end
    local p = pushed[key]
    if p and p.rev == entry.r and (not evidence or GetTime() - p.at < PUSH_REPEAT_GUARD) then
        return false
    end
    entry.t = "L"
    if not Send(entry, "WHISPER", key, "data") then return false end
    pushed[key] = { rev = entry.r, at = GetTime() }
    MarkShared(entry.r)
    return true
end

-- Requests (in batches) every list the peer has newer than my cache.
function Sync:PullFrom(sender, manifest)
    if type(manifest) ~= "table" or not AmCouncil() or not ns.Store then return 0 end
    local Guild = ns.Guild
    local me = Util.PlayerKey()
    local now = GetTime()
    local want, seen = {}, 0
    for k, rev in pairs(manifest) do
        seen = seen + 1
        if seen > MAX_MANIFEST_ENTRIES then break end
        local key = NormKey(k)
        if key and key ~= me and IsRev(rev) and rev > 0 and Guild:IsInGuild(key, true) then
            local cur = ns.Store:GetCached(key)
            local have = cur and tonumber(cur.rev) or 0
            local req = requested[key]
            if req and now - (requestedAt[key] or 0) > REQUEST_STALE then
                req = nil
                requested[key], requestedAt[key] = nil, nil
            end
            if rev > have and not (req and req >= rev) and not (have > 0 and rev > have + MAX_REV_JUMP) then
                want[#want + 1] = key
                requested[key], requestedAt[key] = rev, now
            end
        end
    end
    if #want == 0 then return 0 end
    tsort(want)
    for i = 1, #want, WANT_BATCH do
        local batch = {}
        for j = i, min(i + WANT_BATCH - 1, #want) do batch[#batch + 1] = want[j] end
        Send({ t = "W", n = batch }, "WHISPER", sender, "ctrl")
    end
    return #want
end

---------------------------------------------------------------------------
-- Restore
---------------------------------------------------------------------------

function Sync:RequestRestore(from, rev)
    local me = Util.PlayerKey()
    if type(from) ~= "string" or not me then return false end
    if not restorePending or GetTime() - restorePending.at >= RESTORE_WINDOW then restoreAsked = {} end
    restorePending = { from = from, rev = tonumber(rev) or 0, at = GetTime() }
    restoreAsked[from] = true   -- only a peer I asked may restore my list
    return Send({ t = "W", n = { me } }, "WHISPER", from, "ctrl")
end

-- "Keep mine": supersede the council's copy with a new rev of my current list.
function Sync:KeepMine()
    local BiS = ns.BiS
    restoreOffer = nil
    if not BiS then return end
    if BiS.Commit and BiS:Commit() then return end
    if BiS.ForceBump then
        BiS:ForceBump()
        return
    end
    -- Fallback with the documented ForceBump semantics.
    local rec = BiS:GetRecord()
    if not rec then return end
    rec.rev = max(tonumber(rec.rev) or 0, tonumber(rec.highestSeenRev) or 0) + 1
    rec.highestSeenRev = rec.rev
    rec.ts = GetServerTime()
    ns:Fire("MYLIST_COMMITTED", rec)
end

local function ShowRestorePopup()
    local offer, rec = restoreOffer, OwnRecord()
    if not offer or not rec or offer.rev <= OwnRev() then return end
    if not ns.Popup then return end
    ns.Popup:Show("DISASTERZONE_RESTORE", Util.ShortName(offer.from),
        strformat("rev %d, yours %d", offer.rev, OwnRev()), { from = offer.from, rev = offer.rev })
end

-- A council member reports a newer rev of my own list than I have.
function Sync:OnCouncilHasNewer(from, rev)
    if type(from) ~= "string" or not IsRev(rev) or rev <= 0 then return end
    local BiS = ns.BiS
    if not BiS then return end
    if not PlausibleOwnRev(rev) then
        ns:Debug("Sync: ignoring implausible rev %d of my list from %s (mine %d)", rev, from, OwnRev())
        return
    end
    if BiS.NoteSeenRev then BiS:NoteSeenRev(rev) end
    local rec = OwnRecord()
    if not rec or rev <= OwnRev() then return end
    -- Restores (and the restore popup) only from guild-wide council: a raid-scope council member's copy came from
    -- my own push and the guild council holds it too (a raid leader must not be able to hand me a forged list).
    if not IsGuildCouncil(from) then return end

    if not restoreOffer or rev > restoreOffer.rev then
        restoreOffer = { from = from, rev = rev }
    end
    local now = GetTime()
    if restorePending and now - restorePending.at < RESTORE_WINDOW then
        -- A restore is in flight; if this peer has an even newer copy, ask it too.
        if rev > restorePending.rev then Sync:RequestRestore(from, rev) end
        return
    end
    if OwnRev() == 0 or not HasAnyPicks(rec.data) then
        -- Fresh install / lost data: collect offers for a moment, then restore the newest copy.
        Util.Debounce("sync-restore", 3, function()
            local offer = restoreOffer
            if offer and offer.rev > OwnRev() then Sync:RequestRestore(offer.from, offer.rev) end
        end)
        return
    end
    if restorePopupShown then return end   -- ask once per session
    restorePopupShown = true
    Util.Debounce("sync-restore-popup", 3, ShowRestorePopup)
end

---------------------------------------------------------------------------
-- Own-list check shared by H / S / M
---------------------------------------------------------------------------

-- theirHash (optional): the peer's hash of that rev. Equal revs with different data happen when
-- the owner edited on two PCs with different SavedVariables; the owner's copy wins.
local function CheckOwnAgainst(sender, their, delayed, theirHash)
    if not OwnRecord() then return end
    if not IsRev(their) then their = 0 end
    local mine = OwnRev()
    local push = mine > their and mine > 0
    if not push and mine > 0 and their == mine and type(theirHash) == "string" then
        local own = OwnHash()
        push = own ~= nil and theirHash ~= own
    end
    -- A council copy of my list implausibly far above mine is bogus (a forged relay): push mine, so my direct L
    -- replaces it there (Store accepts the owner's lower rev over such a relayed copy).
    if not push and their > mine and mine > 0 and not PlausibleOwnRev(their) then push = true end
    if push then
        if delayed then
            Util.RandomDelay(2, 10, function() Sync:PushListTo(sender, true) end)
        else
            Sync:PushListTo(sender, true)
        end
    elseif their > mine then
        Sync:OnCouncilHasNewer(sender, their)
    elseif mine > 0 then
        MarkShared(mine)
    end
end

-- The peer's hash for my own list from an optional manifest-hash table.
local function OwnHashIn(mh)
    local me = Util.PlayerKey()
    local h = type(mh) == "table" and me and mh[me]
    return (type(h) == "string" and #h <= 16) and h or nil
end

---------------------------------------------------------------------------
-- WANT serving
---------------------------------------------------------------------------

local function FlushWant(requester)
    local p = pendingWant[requester]
    pendingWant[requester] = nil
    if not p then return end
    RateLimit("W:" .. requester, 0)   -- record this answer for the rate limit
    local Guild, Store = ns.Guild, ns.Store
    local me = Util.PlayerKey()
    local requesterCouncil = IsCouncil(requester) and ListsFor(requester)   -- (1.3: raid council: loot council on)
    local amCouncil = AmCouncil()

    local keys = {}
    for key in pairs(p.names) do keys[#keys + 1] = key end
    tsort(keys)
    local entries = {}
    for _, key in ipairs(keys) do
        local e
        if key == me then
            if requesterCouncil then
                e = OwnEntry()
                if e then e.o = me end
            end
        elseif amCouncil and Store and Guild:IsInGuild(key, true)
            and (key == requester or (requesterCouncil and MayRelay(requester, key))) then
            local rec = Store:GetCached(key)
            if rec and IsRev(rec.rev) and rec.rev > 0 and type(rec.data) == "table" and type(rec.hash) == "string" then
                e = { o = key, r = rec.rev, ts = tonumber(rec.ts) or 0, h = rec.hash, d = rec.data }
            end
        end
        if e then entries[#entries + 1] = e end
    end

    for i = 1, #entries, RELAY_BATCH do
        local batch = {}
        for j = i, min(i + RELAY_BATCH - 1, #entries) do batch[#batch + 1] = entries[j] end
        Send({ t = "R", e = batch }, "WHISPER", requester, "data")
    end
end

local function QueueWant(requester, names)
    local p = pendingWant[requester]
    if not p then
        p = { names = {}, count = 0 }
        pendingWant[requester] = p
    end
    for _, key in ipairs(names) do
        if not p.names[key] and p.count < MAX_PENDING_WANT then
            p.names[key] = true
            p.count = p.count + 1
        end
    end
    if p.scheduled then return end
    if RateLimit("W:" .. requester, 3) then
        FlushWant(requester)
    else
        p.scheduled = true
        Util.After(3, function() FlushWant(requester) end)
    end
end

---------------------------------------------------------------------------
-- STATE replies (one per HELLO sender, paced)
---------------------------------------------------------------------------

local stateQueue = {}              -- { key, ... } in the order the HELLOs arrived
local stateReadyAt = {}            -- [key] = GetTime() from which the reply may go out
local stateTimer = false
local lastStateAt = -1000

local ScheduleStates

local function DrainStates()
    stateTimer = false
    local key = stateQueue[1]
    if not key then return end
    local now = GetTime()
    if stateReadyAt[key] <= now + 0.01 and now - lastStateAt >= STATE_GAP - 0.01 then
        table.remove(stateQueue, 1)
        stateReadyAt[key] = nil
        lastStateAt = now
        if AmCouncil() then
            local cached = ns.Store and ns.Store:GetCached(key)
            local r = (cached and IsRev(cached.rev)) and cached.rev or 0
            local h = (r > 0 and type(cached.hash) == "string") and cached.hash or nil
            Send({ t = "S", r = r, h = h, cg = OwnCouncilRev() }, "WHISPER", key, "ctrl")
        end
    end
    ScheduleStates()
end

ScheduleStates = function()
    local key = stateQueue[1]
    if stateTimer or not key then return end
    stateTimer = true
    local now = GetTime()
    Util.After(max(stateReadyAt[key], lastStateAt + STATE_GAP) - now, DrainStates)
end

-- Answers a HELLO with my copy of the sender's list (S) after the usual short random delay; in a login wave the
-- replies leave one every STATE_GAP seconds instead of filling the control prefix for a minute.
local function QueueState(sender)
    if stateReadyAt[sender] then return end
    stateQueue[#stateQueue + 1] = sender
    stateReadyAt[sender] = GetTime() + 0.5 + random() * 3.5
    ScheduleStates()
end

---------------------------------------------------------------------------
-- Message handlers (sender = transport-verified name key)
---------------------------------------------------------------------------

local function OnHello(sender, msg, dist)
    if dist ~= "GUILD" then return end
    MarkSeen(sender, msg.v, msg.c and true or false)
    local RaidPlan = ns.RaidPlan
    if RaidPlan and RaidPlan.OnHelloDigest then RaidPlan:OnHelloDigest(sender, msg.pd) end
    if RaidPlan and RaidPlan.OnBlacklistRevSeen then RaidPlan:OnBlacklistRevSeen(sender, msg.blr) end
    local GuestBook = ns.GuestBook
    if GuestBook and GuestBook.OnNotesRevSeen then GuestBook:OnNotesRevSeen(sender, msg.gnr) end
    local Strategy = ns.Strategy
    if Strategy and Strategy.OnHelloDigest then Strategy:OnHelloDigest(sender, msg.sd) end
    local Events = ns.Events
    if Events and Events.OnHelloDigest then Events:OnHelloDigest(sender, msg.ed) end
    local Polls = ns.Polls
    if Polls and Polls.OnHelloDigest then Polls:OnHelloDigest(sender, msg.od) end
    local Prized = ns.Prized
    if Prized and Prized.OnHelloDigest then Prized:OnHelloDigest(sender, msg.zd) end
    local G = ns.Guild
    if G and G.OnRaidLeadersRevSeen then G:OnRaidLeadersRevSeen(sender, msg.rlr) end
    if G and G.OnAccountsSeen then G:OnAccountsSeen(sender, msg.av) end
    if msg.c then
        councilHelloAt[sender] = GetTime()
        NoteCouncilRev(sender, msg.cg)
    end
    local amCouncil = AmCouncil()
    -- Replies are rate-limited per sender SESSION (nonce), so a quick second /reload is still answered;
    -- the short per-sender cap bounds what a spammer with changing nonces can trigger.
    local n = msg.n
    local session = sender .. ":" .. ((type(n) == "number" and n == floor(n)) and tostring(n) or "")

    if amCouncil and RateLimit("Hx:" .. sender, 5) and RateLimit("Hs:" .. session, REPLY_RATE) then
        QueueState(sender)
    end

    if msg.c and IsCouncil(sender) then
        local manifest = type(msg.m) == "table" and msg.m or nil
        local me = Util.PlayerKey()
        CheckOwnAgainst(sender, manifest and me and manifest[me] or 0, true, OwnHashIn(msg.mh))
        if amCouncil and FullPair(sender) and RateLimit("Hm:" .. session, REPLY_RATE) then
            local digest, rdigest = msg.ld, msg.rd2 or msg.rd
            Util.RandomDelay(1, 5, function()
                SendManifest(sender, false)
                Sync:PullFrom(sender, manifest)
                LedgerSync(sender, digest)
                RaidSync(sender, rdigest)
            end)
            return
        end
    end
    -- Addendum J §62: a raid planner pair where one side isn't guild council: the raid log only.
    local RL = ns.RaidLog
    if type(msg.rd) == "table" and not (msg.c and FullPair(sender)) and RL and RL.OnPlannerHello then
        RL:OnPlannerHello(sender, type(msg.rd2) == "table" and msg.rd2 or msg.rd)
    end
end

local function OnState(sender, msg, dist)
    if dist ~= "WHISPER" then return end
    -- The guild council list rev piggyback (Addendum E §31) must also reach a member without a list yet
    -- (who cannot know the sender is council): the CG answering the CQ passes Guild's trust rules.
    NoteCouncilRev(sender, msg.cg)
    if not IsCouncil(sender) then
        -- A guild member answering my HELLO is online with DisasterZone: remember that for when the council list
        -- that names them arrives (e.g. right after joining a guild); the council gates still apply.
        local Guild = ns.Guild
        if Guild and Guild.IsInGuild and Guild:IsInGuild(sender, true) then MarkSeen(sender, nil, nil) end
        return
    end
    MarkSeen(sender, nil, true)
    local h = (type(msg.h) == "string" and #msg.h <= 16) and msg.h or nil
    CheckOwnAgainst(sender, IsRev(msg.r) and msg.r or 0, false, h)
end

local function OnManifest(sender, msg, dist)
    if dist ~= "WHISPER" or not IsCouncil(sender) or not AmCouncil() then return end
    MarkSeen(sender, nil, true)
    local manifest = type(msg.m) == "table" and msg.m or nil
    local me = Util.PlayerKey()
    CheckOwnAgainst(sender, manifest and me and manifest[me] or 0, true)
    if not FullPair(sender) then return end   -- raid-scope council: own lists only
    Sync:PullFrom(sender, manifest)
    LedgerSync(sender, msg.ld)
    RaidSync(sender, type(msg.rd2) == "table" and msg.rd2 or msg.rd)
    if msg.q and RateLimit("Mq:" .. sender, 60) then
        Util.RandomDelay(1, 4, function() SendManifest(sender, false) end)
    end
end

local function OnWant(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg.n) ~= "table" then return end
    local names = {}
    for i = 1, MAX_WANT_NAMES do
        local key = NormKey(msg.n[i])
        if key then names[#names + 1] = key end
    end
    if #names == 0 then return end
    local isRestore = (#names == 1 and names[1] == sender)
    if not IsCouncil(sender) and not (isRestore and AmCouncil()) then return end
    QueueWant(sender, names)
end

local function OnList(sender, msg, dist)
    if dist ~= "WHISPER" or not AmCouncil() or not ns.Store then return end
    ns.Store:Put(sender, msg, "direct")
    local cur = ns.Store:GetCached(sender)
    if requested[sender] and cur and (tonumber(cur.rev) or 0) >= requested[sender] then
        requested[sender], requestedAt[sender] = nil, nil
    end
end

local function OnOwnRelay(e, sender)
    local BiS = ns.BiS
    if not BiS or not IsRev(e.r) or e.r <= 0 then return end
    local mine = OwnRev()
    if restorePending and GetTime() - restorePending.at >= RESTORE_WINDOW then
        restorePending = nil
        restoreAsked = {}
    end
    -- Only a copy from a peer I asked for it (RequestRestore) restores my list.
    if restorePending and restoreAsked[sender] and e.r > mine and BiS.AdoptRestored then
        local ok = ns.Store and ns.Store:ValidateData(e.d)
        if ok and type(e.h) == "string" and Util.Hash(e.d) == e.h then
            BiS:AdoptRestored({ r = e.r, ts = tonumber(e.ts) or 0, h = e.h, d = e.d })
            restoreOffer = nil
            restoreAsked[sender] = nil
            MarkShared(e.r)
        else
            ns:Debug("Sync: restore copy rejected (invalid data)")
        end
        return
    end
    if not PlausibleOwnRev(e.r) then return end
    if BiS.NoteSeenRev then BiS:NoteSeenRev(e.r) end
    if e.r == mine and e.h == OwnHash() then MarkShared(mine) end
end

local function OnRelay(sender, msg, dist)
    if dist ~= "WHISPER" or not IsCouncil(sender) or type(msg.e) ~= "table" then return end
    MarkSeen(sender, nil, true)
    local me = Util.PlayerKey()
    local amCouncil = AmCouncil()
    local Store = ns.Store
    for i = 1, MAX_RELAY_ENTRIES do
        local e = msg.e[i]
        if type(e) ~= "table" then break end
        local owner = NormKey(e.o)
        if owner and owner == me then
            OnOwnRelay(e, sender)
        elseif owner and amCouncil and Store and FullPair(sender) then
            -- Other members' lists only between guild-wide council (Addendum E §29, like MayRelay / PullFrom): a
            -- raid-scope council member never relays, so an unsolicited R from one is ignored.
            Store:Put(owner, e, sender)
            local cur = Store:GetCached(owner)
            if requested[owner] and cur and (tonumber(cur.rev) or 0) >= requested[owner] then
                requested[owner], requestedAt[owner] = nil, nil
            end
        end
    end
end

---------------------------------------------------------------------------
-- Internal events
---------------------------------------------------------------------------

local function OnCommitted()
    local peers = Sync:GetOnlineCouncilPeers()
    for i, key in ipairs(peers) do
        Util.After(0.1 + (i - 1) * 0.3, function() Sync:PushListTo(key) end)
    end
    ns:Fire("SYNC_STATUS")
end

local function MaybeScheduleHello()
    if not ns.loggedIn or not IsInGuild() then return end
    local Guild = ns.Guild
    if not (Guild and Guild:IsReady()) then return end
    local gname = Guild:GetGuildName() or "?"
    if helloScheduledFor == gname then return end
    helloScheduledFor = gname
    Util.RandomDelay(8, 20, function() Sync:SendHello() end)
    ns:Fire("SYNC_STATUS")
end

-- A raid member I now see as raid-scope council (picked by the raid leader, or I joined their raid after
-- the pick) gets my list, unless their promotion HELLO arrives meanwhile (that exchange covers it). 1.3: only while
-- the raid runs with the loot council, once per raid session: their copy is dropped on their client when the session
-- is over (Store), so a later session (the same evening too) sends it again.
local function PushToNewRaidCouncil()
    local Guild, GR = ns.Guild, ns.GroupRules
    -- (the raid's rules unknown for a moment: a /reload, the authority changing hands: nothing changes)
    if IsInRaid() and GR and GR.GetStatus and GR:GetStatus() == "own" then return end
    local s = IsInGuild() and IsInRaid() and GR and GR.GetSession and GR:GetSession()
    local sid = s and s.id or nil
    for key, id in pairs(raidShared) do
        if id ~= sid then
            raidShared[key] = nil
            if not IsGuildCouncil(key) then pushed[key] = nil end   -- (the push guard: a new session sends again)
        end
    end
    if not (Guild and sid and RaidListsOpen()) then return end
    local me = Util.PlayerKey()
    local since = GetTime()
    for key in pairs(type(Util.group) == "table" and Util.group or {}) do
        if key ~= me and not raidShared[key] and IsCouncil(key) and not IsGuildCouncil(key)
            and Guild:IsInGuild(key, true) then
            raidShared[key] = sid
            pushed[key] = nil
            Util.RandomDelay(RAID_PUSH_MIN, RAID_PUSH_MAX, function()
                local h = councilHelloAt[key]
                if h and h >= since then return end
                if IsCouncil(key) and Guild:IsOnline(key, true) then Sync:PushListTo(key) end
            end)
        end
    end
end

local function OnConfigUpdated()
    MaybeScheduleHello()
    local now = AmCouncil()
    -- Promoted mid-session (picked by the GM or a raid leader, or I lead a raid now): announce so the
    -- members start sharing with us.
    if wasCouncil == false and now and helloScheduledFor then
        Util.RandomDelay(3, 8, function() Sync:SendHello(true) end)
    end
    wasCouncil = now
    PushToNewRaidCouncil()
    ns:Fire("SYNC_STATUS")
end

local function PeriodicCheck()
    if not IsInGuild() or not AmGuildCouncil() then return end
    if InCombatLockdown and InCombatLockdown() then return end
    local peers = {}
    for _, key in ipairs(Sync:GetOnlineCouncilPeers()) do
        if IsGuildCouncil(key) then peers[#peers + 1] = key end
    end
    if #peers == 0 then return end
    SendManifest(peers[random(#peers)], true)
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function SlashSync()
    Sync:RequestSync()
end

local function SlashVersion()
    local list = Sync:GetVersions()
    ns:Print("DisasterZone %s (protocol %s). Addon users seen: %d", tostring(ns.version), tostring(ns.PROTO), max(0, #list - 1))
    local frame = DEFAULT_CHAT_FRAME
    if not frame then return end
    for i, e in ipairs(list) do
        if i > 40 then
            frame:AddMessage(strformat("  ... and %d more", #list - 40))
            break
        end
        local state = e.online and "|cff40ff40online|r" or ("last seen " .. Util.FormatAgo(e.lastSeen))
        local extra = e.c and ", council" or ""
        if e.incompatible then extra = extra .. ", |cffff5050incompatible|r" end
        frame:AddMessage(strformat("  %s  %s  (%s%s)", Util.ShortName(e.key), tostring(e.v or "?"), state, extra))
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Sync:OnInit()
    -- Unique per session of this character (a /reload takes seconds, GetTime() keeps counting).
    sessionNonce = (GetServerTime() % 1000000) * 10 + floor(GetTime() * 10) % 10
    local db = ns.db
    if db then
        if type(db.peers) ~= "table" then db.peers = {} end
        peersDB = db.peers
        local now = GetServerTime()
        for key, p in pairs(peersDB) do
            if type(p) ~= "table" or (tonumber(p.lastSeen) or 0) < now - PEER_FORGET then
                peersDB[key] = nil
            end
        end
    end

    local Comm = ns.Comm
    if Comm then
        Comm:Register("H", OnHello)
        Comm:Register("S", OnState)
        Comm:Register("M", OnManifest)
        Comm:Register("W", OnWant)
        Comm:Register("L", OnList)
        Comm:Register("R", OnRelay)
    end

    ns:On("MYLIST_COMMITTED", OnCommitted)
    ns:On("ROSTER_UPDATED", MaybeScheduleHello)
    ns:On("CONFIG_UPDATED", OnConfigUpdated)
    -- 1.3: Start raid with the loot council (or switching it on) opens the raid council's lists; End raid closes them
    ns:On("GROUP_RULES_CHANGED", PushToNewRaidCouncil)
    ns:On("GROUP_UPDATED", PushToNewRaidCouncil)

    ns:RegisterSlash("sync", SlashSync, "ask the guild / council to sync BiS lists now")
    ns:RegisterSlash("version", SlashVersion, "list DisasterZone versions seen in the guild")

    if ns.Popup.dialogs then
        ns.Popup.dialogs["DISASTERZONE_RESTORE"] = {
            title = "Restore your BiS list",
            text = "A council member (%s) has a newer copy of your BiS list (%s). Restore it?",
            button1 = "Restore",
            button2 = "Keep mine",
            OnAccept = function(_, data)
                if type(data) == "table" then Sync:RequestRestore(data.from, data.rev) end
            end,
            -- Only a real click on "Keep mine" supersedes the council's copy: Escape just closes the popup
            -- (noCancelOnEscape; Blizzard's StaticPopup_EscapePressed passes "clicked" too), and a popup that
            -- was never shown (OnCancel(nil, data): all dialogs busy, cinematic) or was replaced does nothing.
            OnCancel = function(_, _, reason)
                if reason == "clicked" then Sync:KeepMine() end
            end,
            noCancelOnEscape = true,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
end

function Sync:OnLogin()
    -- Restore the persisted "shared" marker for this character.
    local me = Util.PlayerKey()
    local p = me and peersDB and peersDB[me]
    if type(p) == "table" and IsRev(p.sharedRev) and p.sharedRev == OwnRev() then
        sharedRev, lastSharedTs = p.sharedRev, tonumber(p.sharedTs)
    end
    if not periodicTicker and C_Timer and C_Timer.NewTicker then
        periodicTicker = C_Timer.NewTicker(PERIODIC_INTERVAL + random(0, 60), function()
            if ns.SafeCall then ns.SafeCall(PeriodicCheck) else PeriodicCheck() end
        end)
    end
    MaybeScheduleHello()
end

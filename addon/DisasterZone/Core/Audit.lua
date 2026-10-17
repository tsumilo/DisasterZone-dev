if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Audit.lua", ...) then return end -- DisasterZone: the audit log (Guild Council and Guild Master).
-- Every change to what the guild shares (raids, loot, strategies, notes, roles, ...), who made it, what it was
-- before and after, and when. Only the Guild Master and the guild council keep it, see it and receive it.
--
-- Recording: each module calls Audit:Saw(kind, old, new, ctx) where a record changes on my client (my own edit:
-- ctx.mine; a peer's version merged: ctx.via = sender). Core/AuditKinds.lua turns old/new into entries per kind.
-- Nothing is recorded unless I am the GM or on the confirmed guild council (debug role off, demo off), and nothing
-- older than the moment I started recording (`since`): the first sync of a new council member would otherwise log
-- every record it receives as "added". Entries a peer recorded before that reach me by sync.
--
-- An entry (saved and sent as is):
--   { id, t (server time of the change), w (author key, or nil when not known), a (area), v ("add" | "chg" | "rem" |
--     "back"), o (thing key), n (thing name), k (thing kind), x (art hint), f = { field, ... } (see AuditKinds),
--     s (summary line, optional), b (big change code, optional), sk (sub key, optional), u (the entry a "back"
--     answers, optional), p (snapshot for Put back, optional) }
-- id = hash of o, sk, v, t: every client that sees the same change makes the same id, so copies fold into one.
-- Entries are never edited or removed by anyone; they drop after KEEP_DAYS. Data: db.audit[guild key] =
-- { since, e = { [id] = entry }, seen = { [char key] = time } }.
--
-- Messages (WHISPER, class "audit" = prefix CDLz, only between the GM and guild council members, both ends checked):
--   AUE { e = { entry, ... } }      entries: my own changes as they happen, or what a peer's digest lacked
--   AUD { d = { [day] = hash }, r }  my per-day digest (90 days); the receiver gives the days that differ and, unless
--                                    r, sends its own digest back (so both ends end up with the union)
local addonName, ns = ...

local Audit = ns:NewModule("Audit")
local Util = ns.Util

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local DAY = 86400
local KEEP_DAYS = 90
local MAX_ENTRIES = 6000          -- oldest drop first past this
local FUTURE_SLACK = 300
local PUSH_DELAY = 3              -- my own changes are batched this long before they go out
local LOGIN_DELAY = 40
local DIGEST_EVERY = 30 * 60      -- a digest round with one online peer this often
local REPLY_LIMIT = 30            -- one answer per peer per this many seconds
local MAX_WIRE = 3600             -- a message stays under a member's cap (4000): a peer with an unconfirmed list
                                  -- counts me as a plain member
local MAX_GIVE = 900              -- entries given for one digest at most (newest days first)
local MAX_TAKE = 400              -- entries taken from one message at most
local SNAP_MAX = 2400             -- a Put back snapshot bigger than this (canonical text) is not sent or taken
local SNAP_KEEP = 16000           -- (my own, from what my client saw removed, kept up to this size)

Audit.KEEP_DAYS = KEEP_DAYS
Audit.AREAS = { "raids", "loot", "strat", "members", "guests", "events", "recruit", "roles", "addon" }
local AREA_SET = {}
for _, a in ipairs(Audit.AREAS) do AREA_SET[a] = true end
local VERB_SET = { add = true, chg = true, rem = true, back = true }

local Now, IsInt, DemoOn = Util.Now, Util.IsInt, Util.DemoOn

local KINDS = {}                  -- [kind] = { describe, canPutBack, putBack }
local demoStore                   -- demo mode's log (made up by AuditDemo, in memory only)
local pushQueue = {}              -- ids of my own new entries, sent after PUSH_DELAY
local sharedWith = {}             -- [peer] = true once my digest went to them this session
local putting                     -- the Put back being done right now: { e = entry }
local sortedCache                 -- newest-first list, rebuilt after a change

local function G() return ns.Guild end

---------------------------------------------------------------------------
-- Who keeps it
---------------------------------------------------------------------------

local function IsStaffKey(key)
    local Guild = G()
    if type(key) ~= "string" or not Guild then return false end
    return (Guild:IsGM(key) or Guild:IsGuildCouncil(key)) and true or false
end

-- I may see the page: the GM or on the guild council (demo mode shows everyone its made-up log).
function Audit:CanSee()
    if DemoOn() then return true end
    if not IsInGuild() then return false end
    return IsStaffKey(Util.PlayerKey())
end

-- My client records and syncs: as CanSee, but never in demo mode or while a debug role pretends.
function Audit:IsRecording()
    if DemoOn() or not ns.db or not IsInGuild() then return false end
    local Guild = G()
    if not Guild or (Guild.GetDebugRole and Guild:GetDebugRole() ~= nil) then return false end
    if Guild.IsReady and not Guild:IsReady() then return false end
    return IsStaffKey(Util.PlayerKey())
end

local function Store(create)
    if DemoOn() then
        if not demoStore then
            demoStore = { since = 0, e = {}, seen = {} }
            if ns.AuditDemo and ns.AuditDemo.Fill then ns.AuditDemo:Fill(demoStore) end
        end
        return demoStore
    end
    if not ns.db or not IsInGuild() then return nil end
    local b = ns.DB:GuildBucket("audit", create)
    if not b then return nil end
    if type(b.e) ~= "table" then b.e = {} end
    if type(b.seen) ~= "table" then b.seen = {} end
    return b
end
Audit._Store = Store

local function Changed()
    sortedCache = nil
    Util.Debounce("audit-updated", 0.2, function() ns:Fire("AUDIT_UPDATED") end)
end

---------------------------------------------------------------------------
-- Kinds (Core/AuditKinds.lua)
---------------------------------------------------------------------------

-- def = { describe = fn(old, new, ctx) -> entry | { entry, ... } | nil, canPutBack = fn(e), putBack = fn(e),
--         audience = fn(key) (optional: who of the council may hold its entries; officer notes go to officers only) }
function Audit:Kind(kind, def)
    KINDS[kind] = def
end

-- May key hold entry e (its kind's audience; everyone on the council by default)?
local function MayHold(e, key)
    local def = KINDS[e.k or ""]
    if not (def and def.audience) then return true end
    local ok, res = pcall(def.audience, key)
    return ok and res and true or false
end
Audit._MayHold = MayHold

function Audit:GetKind(kind)
    return KINDS[kind]
end

---------------------------------------------------------------------------
-- Entries
---------------------------------------------------------------------------

local function EntryId(e)
    return Util.Hash({ e.o or "", e.sk or "", e.v or "", e.t or 0 })
end
Audit.EntryId = EntryId

-- A plain copy of an untrusted value: strings (cut at maxLen), numbers, booleans and tables of those, at most
-- maxN pairs per table and depth levels deep. nil for anything else.
local function CleanValue(v, depth, maxLen, maxN)
    local tv = type(v)
    if tv == "string" then return #v > maxLen and v:sub(1, maxLen) or v end
    if tv == "number" then return (v == v and v ~= math.huge and v ~= -math.huge) and v or nil end
    if tv == "boolean" then return v end
    if tv ~= "table" or depth <= 0 then return nil end
    local out, n = {}, 0
    for k, x in pairs(v) do
        n = n + 1
        if n > maxN then break end
        local tk = type(k)
        if (tk == "string" and #k <= 32) or (tk == "number" and IsInt(k, 1, 999)) then
            local c = CleanValue(x, depth - 1, maxLen, maxN)
            if c ~= nil then out[k] = c end
        end
    end
    return out
end

local function Str(s, n)
    if type(s) ~= "string" or s == "" then return nil end
    return #s > n and s:sub(1, n) or s
end

-- A clean copy of e (mine or from the wire), or nil when it is not a usable entry. checkId: the id must be the one
-- its fields give (a peer cannot overwrite another entry).
local function Clean(e, checkId, snapMax)
    if type(e) ~= "table" then return nil end
    local now = Now()
    if not IsInt(e.t, now - (KEEP_DAYS + 1) * DAY, now + FUTURE_SLACK) then return nil end
    if not AREA_SET[e.a] or not VERB_SET[e.v] then return nil end
    local o = Str(e.o, 96)
    if not o then return nil end
    local c = {
        t = e.t, a = e.a, v = e.v, o = o,
        w = Str(e.w, 48), n = Str(e.n, 96) or "?", k = Str(e.k, 24), sk = Str(e.sk, 64),
        s = Str(e.s, 240), b = Str(e.b, 16), u = Str(e.u, 16), c = Str(e.c, 160),
    }
    if type(e.x) == "number" and IsInt(e.x, 0, 2 ^ 31) then c.x = e.x else c.x = Str(e.x, 48) end
    if type(e.f) == "table" then
        local f = CleanValue(e.f, 4, 300, 40)
        if f and next(f) then c.f = f end
    end
    if type(e.p) == "table" then
        -- (my own snapshot is my module's record: kept as it is; one from the wire only as plain small values)
        local p = (snapMax == SNAP_KEEP) and Util.CopyTable(e.p) or CleanValue(e.p, 8, 400, 200)
        if p and #Util.Canonical(p) <= (snapMax or SNAP_MAX) then c.p = p end
    end
    c.id = EntryId(c)
    if checkId and e.id ~= c.id then return nil end
    return c
end
Audit._Clean = Clean

-- Stores a clean entry; true when it is new (or improved a copy that did not know its author).
local function Insert(b, c)
    local cur = b.e[c.id]
    if cur then
        if cur.w or not c.w then return false end
    end
    b.e[c.id] = c
    return true
end

local function Day(t) return floor(t / DAY) end

-- Drops what is older than KEEP_DAYS, then the oldest past MAX_ENTRIES.
function Audit:Prune()
    local b = Store(false)
    if not b or b == demoStore then return end
    local cut, n = Now() - KEEP_DAYS * DAY, 0
    for id, e in pairs(b.e) do
        if type(e) ~= "table" or not IsInt(e.t) or e.t < cut then b.e[id] = nil else n = n + 1 end
    end
    if n > MAX_ENTRIES then
        local list = {}
        for id, e in pairs(b.e) do list[#list + 1] = { id, e.t } end
        tsort(list, function(x, y) if x[2] ~= y[2] then return x[2] < y[2] end return x[1] < y[1] end)
        for i = 1, n - MAX_ENTRIES do b.e[list[i][1]] = nil end
    end
    Changed()
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

local EMPTY = {}

-- Adds one described entry (from Saw); ctx.mine: my own change (I am the author, it goes to my peers).
local function Record(e, ctx)
    local b = Store(true)
    if not b then return end
    local now = Now()
    if not IsInt(b.since) then b.since = now end
    if ctx.mine then e.w = e.w or Util.PlayerKey() end
    if not IsInt(e.t) then e.t = now end
    if e.t > now + FUTURE_SLACK then e.t = now end
    -- (a change older than my recording: the first sync of a record I never had; a peer may have logged it)
    if not ctx.mine and e.t < b.since - 60 then return end
    if putting and ctx.mine and (e.o == putting.e.o or putting.any) then
        e.v, e.u = "back", putting.e.id
        e.b = nil
    end
    local c = Clean(e, false, SNAP_KEEP)
    if not c then return end
    if Insert(b, c) then
        Changed()
        if ctx.mine then
            pushQueue[#pushQueue + 1] = c.id
            Util.Debounce("audit-push", PUSH_DELAY, function() Audit:Flush() end)
        end
        if Audit.OnNew then Audit.OnNew(c, ctx) end
    end
end

-- A record of `kind` went from old to new on my client (either may be nil: added / removed). ctx: { mine = true }
-- for my own edit, { via = sender } for a peer's version; describers may read more fields from it. Never throws.
function Audit:Saw(kind, old, new, ctx)
    if old == nil and new == nil then return end
    if not self:IsRecording() then return end
    local def = KINDS[kind]
    if not def or not def.describe then return end
    ctx = ctx or EMPTY
    local ok, res = pcall(def.describe, old, new, ctx)
    if not ok then
        ns:Debug("Audit %s: %s", tostring(kind), tostring(res))
        return
    end
    if type(res) ~= "table" then return end
    if res.o then
        Record(res, ctx)
    else
        for _, e in ipairs(res) do Record(e, ctx) end
    end
end

-- Sugar for the hooks: Audit:Saw when the audit module is loaded (modules call ns.Audit and Audit may be absent in
-- an old in-game update).
function ns.AuditSaw(kind, old, new, ctx)
    local A = ns.Audit
    if A and A.Saw then A:Saw(kind, old, new, ctx) end
end

-- A shallow copy (one level of tables copied too): the "old" side of a record a module changes in place.
function Audit.Snap(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            local c = {}
            for k2, v2 in pairs(v) do c[k2] = v2 end
            out[k] = c
        else
            out[k] = v
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Reading (the page)
---------------------------------------------------------------------------

-- Every entry, newest first (a shared list: do not change it).
function Audit:Entries()
    if sortedCache then return sortedCache end
    local b = Store(false)
    local list = {}
    if b then
        for _, e in pairs(b.e) do list[#list + 1] = e end
    end
    tsort(list, function(x, y)
        if x.t ~= y.t then return x.t > y.t end
        return x.id > y.id
    end)
    sortedCache = list
    return list
end

function Audit:Get(id)
    local b = Store(false)
    return b and b.e[id] or nil
end

-- Every entry about thing o, newest first.
function Audit:ForThing(o)
    local out = {}
    for _, e in ipairs(self:Entries()) do
        if e.o == o then out[#out + 1] = e end
    end
    return out
end

-- The entry that put e back (a "back" entry answering it), or nil.
function Audit:PutBackOf(e)
    if not e or e.v ~= "rem" then return nil end
    for _, x in ipairs(self:ForThing(e.o)) do
        if x.v == "back" and x.u == e.id then return x end
    end
    return nil
end

-- When I last looked (the gold "new" dot is on what came after), 0 = never.
function Audit:LastSeen()
    local b = Store(false)
    local me = Util.PlayerKey()
    return (b and me and tonumber(b.seen[me])) or 0
end

function Audit:MarkSeen()
    local b = Store(DemoOn() or self:IsRecording())   -- (someone who keeps no log gets none made by a look)
    local me = Util.PlayerKey()
    if not b or not me then return end
    local newest = 0
    for _, e in pairs(b.e) do if e.t > newest then newest = e.t end end
    b.seen[me] = max(tonumber(b.seen[me]) or 0, newest)
    Changed()
end

-- New since I looked: not mine, later than my last look.
function Audit:IsNew(e)
    if not e then return false end
    if e.w and Util.IsMe(e.w) then return false end
    return e.t > self:LastSeen()
end

function Audit:NewCount()
    local n, big = 0, 0
    for _, e in ipairs(self:Entries()) do
        if self:IsNew(e) then
            n = n + 1
            if e.b then big = big + 1 end
        end
    end
    return n, big
end

---------------------------------------------------------------------------
-- Put back
---------------------------------------------------------------------------

function Audit:CanPutBack(e)
    if not e or e.v ~= "rem" or self:PutBackOf(e) then return false end
    if DemoOn() then return e.p ~= nil end
    local def = KINDS[e.k or ""]
    if not def or not def.putBack then return false end
    if def.canPutBack then
        local ok, res = pcall(def.canPutBack, e)
        return ok and res and true or false
    end
    return true
end

-- Puts back what e removed (as my own change, logged as "put back"). Returns ok, error text.
function Audit:PutBack(e)
    if not self:CanPutBack(e) then return false, "This can't be put back." end
    if DemoOn() then
        local b = Store(true)
        local c = Clean({ t = Now(), w = Util.PlayerKey(), a = e.a, v = "back", o = e.o, n = e.n, k = e.k, x = e.x,
            u = e.id, f = e.f, s = e.s }, false)
        if c then Insert(b, c); Changed() end
        return true
    end
    local def = KINDS[e.k]
    putting = { e = e }
    local ok, res, err = pcall(def.putBack, e)
    putting = nil
    if not ok then return false, tostring(res) end
    if not res then return false, err or "This can't be put back." end
    return true
end

-- While fn runs, my changes count as putting e back (for kinds whose restore lands on another thing key).
function Audit:PuttingBack(e, fn)
    putting = { e = e, any = true }
    local ok, a, b = pcall(fn)
    putting = nil
    if not ok then return false, tostring(a) end
    return a, b
end

---------------------------------------------------------------------------
-- Sync (GM + guild council, by whisper)
---------------------------------------------------------------------------

local function Send(msg, target)
    local Comm = ns.Comm
    if not (Comm and Comm.Send) or DemoOn() then return false end
    return Comm:Send(msg, "WHISPER", target, "audit") and true or false
end

local function OnlinePeers()
    local out = {}
    local Guild = G()
    if not Guild or not Audit:IsRecording() then return out end
    for _, key in ipairs(Guild:GetOnlineMembers()) do
        if not Util.IsMe(key) and IsStaffKey(key) then out[#out + 1] = key end
    end
    return out
end
Audit._OnlinePeers = OnlinePeers

-- The copy of e that goes on the wire and its size there: without a snapshot too big to send, and smaller still
-- when one entry alone would not fit a message (no fields, then nothing: never a message a peer must drop).
local function Wire(e)
    local Comm = ns.Comm
    local w = e
    if e.p and #Util.Canonical(e.p) > SNAP_MAX then
        w = {}
        for k, v in pairs(e) do if k ~= "p" then w[k] = v end end
    end
    if not (Comm and Comm.Fits) then return w, 0 end
    local _, len = Comm:Fits({ t = "AUE", e = { w } })
    if (len or 0) <= MAX_WIRE then return w, len or 0 end
    local slim = {}
    for k, v in pairs(w) do if k ~= "p" and k ~= "f" then slim[k] = v end end
    _, len = Comm:Fits({ t = "AUE", e = { slim } })
    if (len or 0) <= MAX_WIRE then return slim, len or 0 end
    return nil, 0
end

-- Sends entries (a list) to target in messages that fit (each entry's own size summed: a batch compresses at least
-- as well as its entries one by one).
local function Give(list, target)
    local batch, size, sent = {}, 0, 0
    local function flush()
        if #batch == 0 then return end
        if Send({ t = "AUE", e = batch }, target) then sent = sent + #batch end
        batch, size = {}, 0
    end
    for _, full in ipairs(list) do
        local e, len
        if MayHold(full, target) then e, len = Wire(full) end
        if e then
            if #batch > 0 and size + len > MAX_WIRE then flush() end
            batch[#batch + 1] = e
            size = size + len
        end
    end
    flush()
    return sent
end

-- My own new entries go to every online peer.
function Audit:Flush()
    if #pushQueue == 0 then return end
    local b = Store(false)
    local list = {}
    for _, id in ipairs(pushQueue) do
        local e = b and b.e[id]
        if e then list[#list + 1] = e end
    end
    pushQueue = {}
    if #list == 0 then return end
    for _, peer in ipairs(OnlinePeers()) do Give(list, peer) end
end

-- { [day] = hash } over the last KEEP_DAYS days.
local function Digest()
    local b = Store(false)
    local per = {}
    if b then
        for id, e in pairs(b.e) do
            local d = Day(e.t)
            per[d] = per[d] or {}
            per[d][#per[d] + 1] = id
        end
    end
    return ns.DigestSync.BucketDigest(per, function(list) return Util.Hash(list):sub(1, 8) end)
end
Audit._Digest = Digest

local function SendDigest(target, isReply)
    if not Audit:IsRecording() then return end
    Send({ t = "AUD", d = Digest(), r = isReply and 1 or nil }, target)
end

-- Both ends must be the GM or on the guild council, by whisper, while I record.
local function Trusted(sender, dist)
    return dist == "WHISPER" and Audit:IsRecording() and IsStaffKey(sender)
end

local function OnEntries(sender, msg, dist)
    if not Trusted(sender, dist) or type(msg.e) ~= "table" then return end
    local b = Store(true)
    if not b then return end
    if not IsInt(b.since) then b.since = Now() end
    local added, n = 0, 0
    for _, e in ipairs(msg.e) do
        n = n + 1
        if n > MAX_TAKE then break end
        local c = Clean(e, true)
        if c and MayHold(c, Util.PlayerKey()) and Insert(b, c) then
            added = added + 1
            if Audit.OnNew then Audit.OnNew(c, { via = sender }) end
        end
    end
    if added > 0 then Changed() end
end

local function OnDigest(sender, msg, dist)
    if not Trusted(sender, dist) or type(msg.d) ~= "table" then return end
    if not Util.RateLimit("aud:" .. sender, REPLY_LIMIT) then return end
    local today = Day(Now())
    local mine = Digest()
    local days = ns.DigestSync.DiffBuckets(msg.d, mine, {
        maxSeen = KEEP_DAYS + 10, lo = today - KEEP_DAYS, hi = today + 1,
        hashOk = function(h) return type(h) == "string" and #h <= 8 end,
    })
    -- (days I have and they do not show up in neither digest's diff from their side: add mine missing in theirs)
    for d in pairs(mine) do
        if msg.d[d] == nil and d >= today - KEEP_DAYS then days[#days + 1] = d end
    end
    if #days == 0 then return end
    local want = {}
    for _, d in ipairs(days) do want[d] = true end
    local list = {}
    for _, e in ipairs(Audit:Entries()) do
        if want[Day(e.t)] then
            list[#list + 1] = e
            if #list >= MAX_GIVE then break end
        end
    end
    Give(list, sender)
    if msg.r ~= 1 then SendDigest(sender, true) end
end

-- My digest to every online peer not sent to yet this session (at login, when people come online).
function Audit:Share(all)
    if not self:IsRecording() then return end
    for _, peer in ipairs(OnlinePeers()) do
        if all or not sharedWith[peer] then
            sharedWith[peer] = true
            SendDigest(peer, false)
        end
    end
end

-- Every DIGEST_EVERY: one round with one online peer (each in turn), for what I only saw arrive elsewhere.
local roundIndex = 0
local function Round()
    Util.After(DIGEST_EVERY, Round)
    if not Audit:IsRecording() then return end
    local peers = OnlinePeers()
    if #peers == 0 then return end
    roundIndex = roundIndex % #peers + 1
    SendDigest(peers[roundIndex], false)
end

---------------------------------------------------------------------------
-- Life
---------------------------------------------------------------------------

function Audit:OnInit()
    local Comm = ns.Comm
    Comm:Register("AUE", OnEntries)
    Comm:Register("AUD", OnDigest)
    ns:On("DEMO_TOGGLED", function()
        demoStore = nil
        Changed()
    end)
end

function Audit:OnLogin()
    Util.After(LOGIN_DELAY + Util.Jitter("audit", 10), function()
        local b = Store(Audit:IsRecording())
        if b and Audit:IsRecording() and not IsInt(b.since) then b.since = Now() end
        Audit:Prune()
        Audit:Share()
    end)
    Util.After(DIGEST_EVERY + Util.Jitter("audit-round", 300), Round)
    ns:On("ROSTER_UPDATED", function()
        Util.Debounce("audit-share", LOGIN_DELAY, function() Audit:Share() end)
    end)
    ns:On("CONFIG_UPDATED", function()
        local b = Store(false)
        if Audit:IsRecording() then
            b = b or Store(true)
            if b and not IsInt(b.since) then b.since = Now() end
            Util.Debounce("audit-share", 5, function() Audit:Share() end)
        end
        Changed()
    end)
end

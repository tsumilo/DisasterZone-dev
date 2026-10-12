if DisasterZoneBoot and DisasterZoneBoot.Run("Core/DigestSync.lua", ...) then return end -- DisasterZone Core/DigestSync.lua
-- shared digest / want / give sync engine, set up per module (refactor phase 5).
local addonName, ns = ...
-- Events, Polls, Prized, RaidPlan and Strategy keep their records in one table per guild (db[bucket][guild key], a
-- table per record kind) and sync them the same way, each under its own two-letter message prefix XX:
--   the guild HELLO carries a hash over the module's digest (Sync:RegisterHelloField). A member whose hash differs
--   from the HELLO's answers once per round, after a short random delay (writers first, later when the data queue is
--   busy): a claim XXK { to } on the live prefix (the others stay quiet for that round), then the digest
--   XXD { to, h, d = { ["K:id"] = 6-hex hash } } on the data prefix. The newcomer takes the first digest of its round
--   only: it asks for what differs (XXW { w = items }, a whisper) and is sent what it lacks (XXG, a whisper). A live
--   change goes to the guild at once (XXU { k, r }); each module checks those and XXG itself.
-- A digest is capped (maxItems): clients drop a bigger one whole, so the cap never goes down. Everything about the
-- wire (types, fields, their order, the caps, the hashes) is the modules' own from before this engine; it only keeps
-- one copy of the code.
-- Also here: DigestSync.RevList, the rev handshake of a list a few writers keep whole (the raid blacklist, the guest
-- book's notes), and DigestSync.BucketDigest / DiffBuckets, the per-bucket digests of the Ledger (days) and the raid
-- log (weeks).
--
-- local sync = ns.DigestSync.New({
--     module = Events, bucket = "events", kinds = { "D", "K", ... }, prefix = "EV",
--     maxItems = 1200,                 -- digest items (sent and taken)
--     maxItemLen = 91,                 -- the longest item taken in a digest or a want
--     itemPattern = "^%u:",            -- what an item must look like in a digest taken
--     helloField = "ed", helloOrder = 50,
--     delay = function() return { 0.5, 2.5 } end,   -- the answer's random delay range
--     wireKey = WireKey,               -- the module's check of a player key on the wire (a digest's / claim's "to")
--     -- optional:
--     root = function(create) end,                   -- the module's own Root (default: DB:GuildBucket + kinds)
--     items = function(root) return list end,        -- the digest's items in cap order (default: every kind's, sorted)
--     itemHash = function(root, item) end,           -- an item's short hash (default: its record's)
--     sendItem = function(root, item, target) end,   -- one item to a member (default: XXG { k, r })
--     giveSort = function(a, b) end,                 -- the order items are given in (default: sorted)
--     large = true,                                  -- XXU / XXG / XXD may be as large as a council member's
--     send = function(msg, dist, target, class) end, -- the module's own sending (default: nothing in demo mode)
--     keepHash = true,                               -- round notes keep the digest's hash (RaidPlan, Strategy)
--     -- records (Commit / StoreRecord):
--     clean = function(kind, r) end, merge = function(root, kind, rec, live) end, changed = function() end,
--     state = function() end,                        -- demo mode's data (Commit in demo mode)
--     prepare = function(kind, rec) end,             -- just before a commit's record is cleaned (has its rev)
--     demoCheck = function(state, kind, clean) end,  -- false: the demo commit is refused
--     tooBig = "text",                               -- printed when a commit would not fit one message
-- })

local DigestSync = {}
ns.DigestSync = DigestSync

local type, pairs, ipairs, tonumber = type, pairs, ipairs, tonumber
local tsort = table.sort
local floor, max, min = math.floor, math.max, math.min
local strformat = string.format

local ROUND_WINDOW = 20          -- seconds one client's round lasts (one answer, others keep quiet)
local SIZE_HEADROOM = 0.1        -- a commit leaves this much of a message free (whoever relays it adds fields)
local HASH_MAX = 8               -- longest hash taken (a digest entry, a HELLO field)

local Util = ns.Util

local Now, DemoOn = Util.Now, Util.DemoOn


local Engine = {}
Engine.__index = Engine

---------------------------------------------------------------------------
-- Records
---------------------------------------------------------------------------

-- This guild's saved table (db[bucket][guild key]) with a table for every record kind; nil while the guild is
-- unknown, or (without create) when nothing is stored yet.
function Engine:Root(create)
    if self.cfg.root then return self.cfg.root(create) end
    local r = ns.DB:GuildBucket(self.bucket, create)
    if not r then return nil end
    for _, k in ipairs(self.kinds) do
        if type(r[k]) ~= "table" then r[k] = {} end
    end
    return r
end

-- The rev for a new version of cur: now, or one past cur's when that is later (a clock behind).
function Engine.NextRev(cur)
    local prev = type(cur) == "table" and tonumber(cur.rev) or 0
    return max(Now(), prev + 1)
end

-- A new record id: prefix .. hex time .. 4 hex.
function Engine:NewId(prefix)
    self.idCounter = self.idCounter + 1
    local now = Now()
    return (prefix or "") .. strformat("%x", now)
        .. Util.Hash({ Util.PlayerKey() or "", now, self.idCounter, GetTime() }):sub(1, 4)
end

-- Higher rev wins; the same rev settles on the larger hash (every client picks the same one).
function Engine.Newer(a, b)
    if not b then return true end
    if a.rev ~= b.rev then return a.rev > b.rev end
    return Util.Hash(a) > Util.Hash(b)
end

-- (demo mode sends nothing; a module whose own data is never demo data passes its own send)
function Engine:Send(msg, dist, target, class)
    if self.cfg.send then return self.cfg.send(msg, dist, target, class) end
    if DemoOn() then return false end
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, dist, target, class)) and true or false
end

local function RateLimit(key, seconds)
    local Comm = ns.Comm
    if not (Comm and Comm.RateLimit) then return true end
    return Comm:RateLimit(key, seconds)
end

-- A record from a member (live: their own change, checked against what is true now; else relayed from a store).
-- Returns stored, the clean record.
function Engine:StoreRecord(kind, r, live)
    if not self.kindSet[kind] then return false end
    local root = self:Root(true)
    if not root then return false end
    local rec = self.cfg.clean(kind, r)
    if not rec then return false end
    return self.cfg.merge(root, kind, rec, live), rec
end

-- My own change: stored (merged like anyone's), then sent to the guild (XXU). Demo mode changes its own data only.
-- Returns ok, the clean record.
function Engine:Commit(kind, rec)
    local cfg = self.cfg
    rec.by = rec.by or Util.PlayerKey()
    if DemoOn() then
        local st = cfg.state()
        rec.rev = self.NextRev(st[kind][rec.id])
        if cfg.prepare then cfg.prepare(kind, rec) end
        local clean = cfg.clean(kind, rec)
        if not clean then return false end
        if cfg.demoCheck and not cfg.demoCheck(st, kind, clean) then return false end
        st[kind][rec.id] = clean
        cfg.changed()
        return true, clean
    end
    local root = self:Root(true)
    if not root then return false end      -- (the guild key is not known yet: GetGuildInfo lags after a login)
    rec.rev = self.NextRev(root[kind][rec.id])
    if cfg.prepare then cfg.prepare(kind, rec) end
    local clean = cfg.clean(kind, rec)
    if not clean then return false end
    local Comm = ns.Comm
    if Comm and Comm.Fits and not Comm:Fits({ t = self.T.U, k = kind, r = clean }, SIZE_HEADROOM) then
        ns:Print(cfg.tooBig)
        return false
    end
    if not cfg.merge(root, kind, clean, true) then return false end
    self:Send({ t = self.T.U, k = kind, r = clean }, "GUILD", nil, "data")
    cfg.changed()
    return true, clean
end

---------------------------------------------------------------------------
-- Digest
---------------------------------------------------------------------------

local function DefaultItems(self, root)
    local items = {}
    for _, kind in ipairs(self.kinds) do
        for id in pairs(root[kind]) do items[#items + 1] = kind .. ":" .. id end
    end
    tsort(items)
    return items
end

local function DefaultItemHash(root, item)
    local kind, id = item:match("^(%u):(.+)$")
    local rec = kind and root[kind] and root[kind][id]
    return rec and Util.Hash(rec):sub(1, 6) or nil
end

-- { [item] = short hash } of everything I hold for my guild, the first maxItems items (clients drop a bigger digest).
function Engine:GetDigest()
    local out = {}
    local root = self:Root(false)
    if not root then return out end
    local items = self.cfg.items and self.cfg.items(root) or DefaultItems(self, root)
    local itemHash = self.cfg.itemHash or DefaultItemHash
    local n = 0
    for _, item in ipairs(items) do
        local h = itemHash(root, item)
        if h then
            n = n + 1
            if n > self.maxItems then break end
            out[item] = h
        end
    end
    return out
end

-- One hash over the digest ("0" = I hold nothing). Sent in the HELLO.
function Engine:GetDigestHash()
    local d = self.module:GetDigest()
    local list = {}
    for item, h in pairs(d) do list[#list + 1] = item .. "=" .. h end
    if #list == 0 then return "0" end
    tsort(list)
    return Util.Hash(list)
end

-- One item to a member (XXG, a whisper).
function Engine:SendItem(root, item, target)
    if self.cfg.sendItem then return self.cfg.sendItem(root, item, target) end
    local kind, id = item:match("^(%u):(.+)$")
    if kind and self.kindSet[kind] and root[kind][id] then
        self:Send({ t = self.T.G, k = kind, r = root[kind][id] }, "WHISPER", target, "data")
    end
end

function Engine:CleanDigest(d)
    if type(d) ~= "table" then return nil end
    local out, n = {}, 0
    for item, h in pairs(d) do
        n = n + 1
        if n > self.maxItems then return nil end
        if type(item) ~= "string" or #item > self.maxItemLen or not item:find(self.itemPattern) then return nil end
        if type(h) ~= "string" or #h > HASH_MAX then return nil end
        out[item] = h
    end
    return out
end

---------------------------------------------------------------------------
-- Handlers
---------------------------------------------------------------------------

-- XXW { w = { item, ... } }: the items a member wants from me.
function Engine:OnWant(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg.w) ~= "table" or not RateLimit(self.T.W .. ":" .. sender, 5) then return end
    local root = self:Root(false)
    if not root then return end
    for i = 1, self.maxItems do
        local item = msg.w[i]
        if item == nil then break end
        if type(item) == "string" and #item <= self.maxItemLen then self:SendItem(root, item, sender) end
    end
end

-- XXD { to, h, d }: an answer to someone's HELLO. Mine: sync with the responder (the first answer of my round only).
-- Someone else's: remember it, so I don't answer the same round.
function Engine:OnDigest(sender, msg, dist)
    if dist ~= "GUILD" then return end
    local to = self.cfg.wireKey(msg.to)
    if not to then return end
    if not Util.IsMe(to) then
        if not self.keepHash then
            self.roundSeen[to] = { at = GetTime() }
        elseif type(msg.h) == "string" then
            self.roundSeen[to] = { h = msg.h, at = GetTime() }
        end
        return
    end
    if GetTime() - self.answeredAt < ROUND_WINDOW then return end
    local theirs = self:CleanDigest(msg.d)
    if not theirs then return end
    self.answeredAt = GetTime()
    local root = self:Root(true)
    if not root then return end
    local mine = self.module:GetDigest()
    local want, give = {}, {}
    for item, h in pairs(theirs) do
        if mine[item] ~= h then want[#want + 1] = item end
    end
    for item, h in pairs(mine) do
        if theirs[item] ~= h then give[#give + 1] = item end
    end
    tsort(want)
    if self.cfg.giveSort then tsort(give, self.cfg.giveSort) else tsort(give) end
    if #want > 0 then self:Send({ t = self.T.W, w = want }, "WHISPER", sender, "ctrl") end
    for _, item in ipairs(give) do self:SendItem(root, item, sender) end
end

-- XXK { to }: someone is about to answer that client's HELLO with a digest.
function Engine:OnClaim(sender, msg, dist)
    if dist ~= "GUILD" then return end
    local to = self.cfg.wireKey(msg.to)
    if to and not Util.IsMe(to) then self.roundSeen[to] = self.keepHash and { h = "", at = GetTime() } or { at = GetTime() } end
end

-- Sync calls this for every HELLO on GUILD (hash = the sender's digest hash; nil from older clients).
function Engine:OnHelloDigest(sender, hash)
    if type(hash) ~= "string" or #hash > HASH_MAX or type(sender) ~= "string" then return end
    local M = self.module
    local mine = M:GetDigestHash()
    if mine == "0" or hash == mine then return end
    if not RateLimit(self.T.D .. "h:" .. sender, ROUND_WINDOW) then return end
    local delay = self.cfg.delay()
    -- With item data still waiting in my queue the digest (and what the newcomer then asks for) would wait behind
    -- it: answer after the members whose queue is empty had their turn (they serve the newcomer faster).
    local Comm = ns.Comm
    local queued = Comm and Comm.Backlog and Comm:Backlog("data") or 0
    local busy = queued > 0 and min(12, 6 + queued / 240) or 0
    -- Still catching up myself (my own round was answered moments ago): what I hold is incomplete, so I only answer
    -- once that settled, if nobody else did.
    busy = max(busy, ROUND_WINDOW - (GetTime() - self.answeredAt))
    Util.RandomDelay(delay[1] + busy, delay[2] + busy, function()
        local h = M:GetDigestHash()
        local seen = self.roundSeen[sender]
        -- Somebody answered this round already (whatever their hash): the newcomer syncs with the first answer only
        -- (answeredAt in OnDigest), so one more is noise.
        if h == "0" or (seen and GetTime() - seen.at < ROUND_WINDOW) then return end
        self.roundSeen[sender] = self.keepHash and { h = h, at = GetTime() } or { at = GetTime() }
        -- The digest waits in the bulk queue behind item data; this short claim on the (mostly idle) live prefix tells
        -- the others right away that the round is answered (older clients have no handler for it and ignore it).
        self:Send({ t = self.T.K, to = sender }, "GUILD", nil, "live")
        self:Send({ t = self.T.D, to = sender, h = h, d = M:GetDigest() }, "GUILD", nil, "data")
    end)
end

-- Registers the digest's messages (XXD, XXK, XXW) and, when given, the module's own XXU / XXG handlers; with
-- cfg.large, XXU / XXG / XXD may be as large as a council member's message. Then the HELLO field. Called from the
-- module's OnInit.
function Engine:Register(onUpdate, onGive)
    local T = self.T
    local Comm = ns.Comm
    if Comm and Comm.Register then
        if onUpdate then Comm:Register(T.U, onUpdate) end
        Comm:Register(T.D, function(sender, msg, dist) self:OnDigest(sender, msg, dist) end)
        Comm:Register(T.K, function(sender, msg, dist) self:OnClaim(sender, msg, dist) end)
        Comm:Register(T.W, function(sender, msg, dist) self:OnWant(sender, msg, dist) end)
        if onGive then Comm:Register(T.G, onGive) end
        if self.cfg.large and Comm.AllowLarge then
            for _, t in ipairs({ T.U, T.G, T.D }) do Comm:AllowLarge(t, "data") end
        end
    end
    local Sync = ns.Sync
    if self.helloField and Sync and Sync.RegisterHelloField then
        local M = self.module
        Sync:RegisterHelloField(self.helloField, self.helloOrder,
            function() return M:GetDigestHash() end,
            function(sender, v) M:OnHelloDigest(sender, v) end)
    end
end

---------------------------------------------------------------------------
-- Lists kept whole by a few writers, with one rev (the raid blacklist, the guest book's notes)
---------------------------------------------------------------------------

-- The rev rides in the HELLO (o.field, at o.order): a writer who holds a newer list than a member's sends it to them
-- after a short random delay; a member who holds an older one than a writer's asks that writer for it (o.query, a
-- whisper), and a writer answers that question with the list. One answer per member and o.limit seconds each way.
-- o: field, order, query (message type), rev() (my list's rev), serve() (may I send the list), writer(key) (may that
-- member write it), sendList(target), send(msg, dist, target, class), replyKey, askKey, queryKey (rate-limit key
-- prefixes), limit (seconds). Returns { Seen(sender, rev), OnQuery(sender, msg, dist), Register() }.
function DigestSync.RevList(o)
    local rl = {}

    -- Sync calls this for every HELLO (rev = the sender's rev; nil from clients without the field).
    function rl.Seen(sender, rev)
        if type(rev) ~= "number" or type(sender) ~= "string" then return end
        local mine = o.rev()
        if rev < mine and o.serve() then
            if RateLimit(o.replyKey .. sender, o.limit) then
                Util.RandomDelay(0.5, 3, function() o.sendList(sender) end)
            end
        elseif rev > mine and o.writer(sender) then
            if RateLimit(o.askKey .. sender, o.limit) then
                o.send({ t = o.query }, "WHISPER", sender, "ctrl")
            end
        end
    end

    -- o.query { }: a member asks me for the list.
    function rl.OnQuery(sender, _, dist)
        if dist ~= "WHISPER" or not o.serve() then return end
        if not RateLimit(o.queryKey .. sender, o.limit) then return end
        o.sendList(sender)
    end

    -- The question's handler and the HELLO field (from the module's OnInit).
    function rl.Register()
        local Comm = ns.Comm
        if Comm and Comm.Register then Comm:Register(o.query, rl.OnQuery) end
        local Sync = ns.Sync
        if Sync and Sync.RegisterHelloField then Sync:RegisterHelloField(o.field, o.order, o.rev, rl.Seen) end
    end

    return rl
end

---------------------------------------------------------------------------
-- Bucket digests (the Ledger's days, the raid log's weeks)
---------------------------------------------------------------------------

-- { [bucket] = hash(list) } of { [bucket] = { item string, ... } } (each list sorted first, in place).
function DigestSync.BucketDigest(perBucket, hash)
    local out = {}
    for b, list in pairs(perBucket) do
        tsort(list)
        out[b] = hash(list)
    end
    return out
end

-- The buckets of a peer's digest whose hash differs from mine (in the order pairs gives them). Looks at o.maxSeen
-- entries at most (an untrusted table); a bucket counts when it is a whole number from o.lo to o.hi and its hash
-- passes o.hashOk(h); o.accept(bucket), when given, may still leave it out; stops after o.maxPick buckets.
function DigestSync.DiffBuckets(theirs, mine, o)
    local out, seen = {}, 0
    for b, h in pairs(theirs) do
        seen = seen + 1
        if seen > o.maxSeen then break end
        if type(b) == "number" and b == floor(b) and b >= o.lo and b <= o.hi and o.hashOk(h) and mine[b] ~= h
            and (not o.accept or o.accept(b)) then
            out[#out + 1] = b
            if o.maxPick and #out >= o.maxPick then break end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Set-up
---------------------------------------------------------------------------

-- A sync engine for one module (the fields at the top of this file). Installs GetDigest, GetDigestHash and
-- OnHelloDigest on the module unless it has its own.
function DigestSync.New(cfg)
    local p = cfg.prefix
    local self = setmetatable({
        cfg = cfg,
        module = cfg.module,
        bucket = cfg.bucket,
        kinds = cfg.kinds,
        kindSet = {},
        T = { U = p .. "U", D = p .. "D", K = p .. "K", W = p .. "W", G = p .. "G" },
        maxItems = cfg.maxItems,
        maxItemLen = cfg.maxItemLen,
        itemPattern = cfg.itemPattern,
        keepHash = cfg.keepHash and true or false,
        helloField = cfg.helloField,
        helloOrder = cfg.helloOrder,
        roundSeen = {},          -- [key] = { at = GetTime() (, h) }: a digest to that client was seen / claimed
        answeredAt = -1000,      -- GetTime() I answered the first digest of my own round
        idCounter = 0,
    }, Engine)
    for _, k in ipairs(cfg.kinds) do self.kindSet[k] = true end
    local M = cfg.module
    if M then
        local eng = self
        if not M.GetDigest then M.GetDigest = function() return eng:GetDigest() end end
        if not M.GetDigestHash then M.GetDigestHash = function() return eng:GetDigestHash() end end
        if not M.OnHelloDigest then
            M.OnHelloDigest = function(_, sender, hash) return eng:OnHelloDigest(sender, hash) end
        end
    end
    return self
end

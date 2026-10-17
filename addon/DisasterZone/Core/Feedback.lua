if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Feedback.lua", ...) then return end -- DisasterZone: feedback to the developer.
-- Members tell the addon's developer (DEV_NAME, Tsumil) about bugs, ideas, changes they want and things they love. A
-- WoW addon can't reach the internet, so feedback travels inside the guild: every client keeps the guild's feedback
-- and passes it on, so an item reaches the developer the next time the developer and anyone who holds it are online
-- together. Everyone in the guild sees every item and may add a "me too"; the developer, the Guild Master and the
-- officers ("staff") answer, set a status and merge duplicates. The developer's client numbers each item (#42) when it
-- first sees it: that is "Tsumil has it" for the author, and the number a changelog line names (Data/Changelog.lua:
-- a line { "text", fb = { 42 }, by = { "Name" }, k = "bug" }); a release whose notes name an item is its "Fixed in".
--
-- Data (SavedVariables db.feedback[guildKey], account wide):
--   r   = { [id] = record }   every record, of five kinds (k):
--     "i" item    id "<author>#<n>"           { a, n, kd = kind, x = text, ab = about, rf = page ref, c = context,
--                                               e = error { m, s = stack, n = times, v = version, p = pasted
--                                               text (a BugSack copy, the whole of it) }, t = created, an = 1 (no name in the changelog), d = 1
--                                               (withdrawn), au = 1 (a Lua error that reported itself), rv }
--     "v" me too  id "<item>+<voter>"          { i, a, d = 1 (taken back), rv }
--     "r" reply   id "<item>@<author>#<n>"     { i, a, n, x, t, d, rv }
--     "s" status  id "<item>!"                 { i, a = who set it, s = state, dp = item it duplicates, v = version
--                                               (shipped), rv }
--     "n" number  id "<item>="                 { i, a = the developer, no, rv }
--   seq = { [author] = last n }   numbers of my characters' items and replies
--   no  = last item number given (the developer's account only)
-- A record is replaced only by one with a higher rv (ties: the larger canonical text), so every client ends with the
-- same set. Items, me-toos and replies come from anyone; a status, a number and a staff member's reply are taken only
-- from staff (they could be made up by anyone passing them on). An item closed (or withdrawn) long ago is "archived":
-- out of the sync, and dropped except on the developer's account (dev/tools/feedback.py reads the developer's file).
--
-- Messages (prefix CDLb, class "fb"):
--   FBN { r = { [id] = rec } }               GUILD: new or changed records
--   FBH { h = { bucket hashes } }             WHISPER, after login, to one member: what I hold
--   FBI { b = { [bucket] = { [id] = rv } }, h = { hashes } }   WHISPER: the answer, the buckets that differ
--   FBQ { q = { id, ... } }                   WHISPER: send me these
--   FBR { r = { [id] = rec } }                WHISPER: the records asked for
-- The member asked at login answers with its index of the buckets that differ; the newcomer asks for what it lacks and
-- sends the guild (FBN) what the other one lacked, so feedback written while nobody was online spreads at the next login.
local addonName, ns = ...

local Feedback = ns:NewModule("Feedback")
local Util = ns.Util

local type, pairs, ipairs, tostring, tonumber, next = type, pairs, ipairs, tostring, tonumber, next
local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat
local strlower, strsub, strfind, strmatch, strgsub = string.lower, string.sub, string.find, string.match, string.gsub

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local DEV_NAME = "Tsumil"
Feedback.DEV_NAME = DEV_NAME

local KINDS = { "bug", "idea", "change", "love" }
local KIND_OK = { bug = true, idea = true, change = true, love = true }
Feedback.KINDS = KINDS
Feedback.KIND_INFO = {
    bug    = { label = "Something broke", short = "Bug",    icon = 136045, color = { 0.92, 0.42, 0.38 } },
    idea   = { label = "I have an idea",  short = "Idea",   icon = 134249, color = { 0.98, 0.78, 0.30 } },
    change = { label = "Change something", short = "Change", icon = 134520, color = { 0.40, 0.66, 0.95 } },
    love   = { label = "I love this",     short = "Love",   icon = 135451, color = { 0.95, 0.50, 0.68 } },
}

-- States a status record may hold. Open: "open" (reopened) and "planned". Closed: the rest ("done" = shipped).
local STATES = { open = true, planned = true, done = true, exists = true, notnow = true, dup = true, removed = true }
local CLOSED = { done = true, exists = true, notnow = true, dup = true, removed = true }
Feedback.STATE_LABEL = {
    open = "Open", planned = "Planned", done = "Fixed", exists = "Already in the addon", notnow = "Not planned",
    dup = "Same as another", removed = "Removed",
}

local TEXT_MAX = 400            -- an item
local REPLY_MAX = 300
local ABOUT_MAX = 60
local REF_MAX = 60
local ERR_MSG_MAX = 300
local ERR_STACK_MAX = 900
local PASTE_MAX = 3000          -- an error pasted into a bug (e.p; older clients pass it on unread)
local KEY_MAX = 48
local ID_MAX = 140
local OPEN_PER_AUTHOR = 25      -- open items one character may have
local MAX_RECORDS = 4000        -- records kept (others refused)
local ARCHIVE_CLOSED = 120 * 86400   -- a closed item leaves the sync this long after it was closed
local ARCHIVE_GONE = 30 * 86400      -- a withdrawn one after this long
local FUTURE_SLACK = 300
local MAX_REV = 2147483647
local BUCKETS = 16
local BATCH = 2400              -- canonical bytes of records per message (wire caps: 4000 encoded, 16 KB inflated)
local LOGIN_DELAY = 25
local ANSWER_LIMIT = 60         -- seconds between two answers to one member's FBH
local ASK_LIMIT = 3000          -- ids one member may ask me for in a session

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local Now, IsInt = Util.Now, Util.IsInt

local function G() return ns.Guild end

local function Me() return Util.PlayerKey() end

-- One line of plain text: no escape codes or links; line breaks kept (multi) or turned into spaces.
local function Clean(text, maxLen, multi)
    if type(text) ~= "string" then return nil end
    text = text:gsub("\r", "")
    if not multi then text = text:gsub("\n", " ") end
    text = text:gsub("[%z\1-\9\11-\31]", ""):gsub("|", "/")
    text = Util.Trim(text:gsub("\n\n\n+", "\n\n"))
    if maxLen and #text > maxLen then
        text = strsub(text, 1, maxLen)
        -- (never end inside a UTF-8 character)
        text = text:gsub("[\192-\255][\128-\191]*$", "")
    end
    return text
end

local function WireKey(s)
    if type(s) ~= "string" or s == "" or #s > KEY_MAX or s:find("[%c|#@+!=]") then return nil end
    return Util.NormalizeName(s)
end

local function Short(key) return Util.ShortName(key) end

-- A short deterministic delay (0..span) for this character: no math.random (it would shift other modules' draws).
local function Jitter(span, salt) return Util.Jitter(salt, span) end

---------------------------------------------------------------------------
-- Who is who
---------------------------------------------------------------------------

-- The developer's character in the guild roster (DEV_NAME on my realm), or nil.
local function DevKey()
    local key = Util.NormalizeName(DEV_NAME)
    local Guild = G()
    if Guild and Guild.IsInGuild and key and Guild:IsInGuild(key, true) then return key end
    return key
end

-- Is key the developer (DEV_NAME, or a character the developer's account vouches for)?
function Feedback:IsDev(key)
    if type(key) ~= "string" then return false end
    local name = strmatch(key, "^([^%-]+)")
    if name == DEV_NAME then return true end
    local dev = DevKey()
    local Guild = G()
    return (dev and Guild and Guild.SameAccount and Guild:SameAccount(key, dev)) and true or false
end

function Feedback:AmIDev()
    local me = Me()
    if not me then return false end
    if self:IsDev(me) then return true end
    -- another character of my account is the developer (the saved data is account wide)
    local db = ns.db
    for key in pairs(db and type(db.chars) == "table" and db.chars or {}) do
        if type(key) == "string" and strmatch(key, "^([^%-]+)") == DEV_NAME then return true end
    end
    return false
end

local DemoOn = Util.DemoOn
Feedback.DemoOn = DemoOn

-- The Guild Master and the officers by the real guild roster (never a debug role), and the developer. In demo mode the
-- demo guild's officers too (their names never come over the wire).
function Feedback:IsStaff(key)
    if type(key) ~= "string" then return false end
    if self:IsDev(key) then return true end
    local Guild = G()
    if not (Guild and Guild:IsReady()) then return false end
    if Guild:IsOfficer(key, true) then return true end
    if DemoOn() then
        local r = ns.Demo:GetRoster()[key]
        return (r and (tonumber(r.rankIndex) or 99) <= 1) and true or false
    end
    return false
end

function Feedback:AmIStaff()
    if self:AmIDev() or DemoOn() then return true end
    -- the developer's debug role (/dz role officer) shows the staff views without any rights on the wire
    local Guild = G()
    local me = Me()
    return (me and (self:IsStaff(me) or (Guild and Guild:IsReady() and Guild:IsOfficer(me)))) and true or false
end

---------------------------------------------------------------------------
-- Store
---------------------------------------------------------------------------

local cache = { dirty = true }   -- views built from the records (Rebuild)

local function GuildKey()
    return IsInGuild() and Util.GuildKey() or nil
end

local demoStore     -- demo mode's feedback (Feedback:DemoStore below): in memory only, never saved, never sent

-- The store I read and write: demo mode's while it is on, unless real (the sync and the developer's side always work
-- on the real one, so the guild's feedback keeps flowing while I look at the demo).
local function Store(create, real)
    if not real and DemoOn() then return Feedback:DemoStore() end
    local gk = GuildKey()
    if not gk then return nil end
    local s = ns.DB:GuildBucket("feedback", create, gk)
    if not s then return nil end
    if type(s.r) ~= "table" then s.r = {} end
    if type(s.seq) ~= "table" then s.seq = {} end
    return s
end

local function Records(real)
    local s = Store(false, real)
    return s and s.r or {}
end

local function Changed()
    cache.dirty = true
    cache.hashes = nil
    ns:Fire("FEEDBACK_UPDATED")
end

---------------------------------------------------------------------------
-- Records: shape checks
---------------------------------------------------------------------------

local function ItemIdOf(author, n) return author .. "#" .. n end

-- The item id a record belongs to (its own id for an item).
local function ItemOf(id, rec)
    if rec.k == "i" then return id end
    return rec.i
end

local function ValidContext(c)
    if c == nil then return true end
    if type(c) ~= "table" then return false end
    for k, v in pairs(c) do
        if type(k) ~= "string" or #k > 4 or type(v) ~= "string" or #v > 60 then return false end
    end
    return true
end

local function ValidError(e)
    if e == nil then return true end
    return type(e) == "table" and type(e.m) == "string" and #e.m <= ERR_MSG_MAX
        and (e.s == nil or (type(e.s) == "string" and #e.s <= ERR_STACK_MAX))
        and (e.p == nil or (type(e.p) == "string" and e.p ~= "" and #e.p <= PASTE_MAX))
        and (e.n == nil or IsInt(e.n, 1, 1000000)) and (e.v == nil or (type(e.v) == "string" and #e.v <= 20))
end

-- Is rec a well-formed record for id? (Not who may send it: Trusted.)
local function Valid(id, rec, now)
    if type(id) ~= "string" or #id > ID_MAX or type(rec) ~= "table" then return false end
    if not IsInt(rec.rv, 1, (now or Now()) + FUTURE_SLACK) then return false end
    local a = WireKey(rec.a)
    if not a or a ~= rec.a then return false end
    if rec.d ~= nil and rec.d ~= 1 then return false end
    local k = rec.k
    if k == "i" then
        if not IsInt(rec.n, 1, 1000000) or id ~= ItemIdOf(a, rec.n) then return false end
        if rec.d == 1 then return true end   -- (a withdrawn item keeps only its id, author and number)
        return KIND_OK[rec.kd] and type(rec.x) == "string" and rec.x ~= "" and #rec.x <= TEXT_MAX
            and (rec.ab == nil or (type(rec.ab) == "string" and #rec.ab <= ABOUT_MAX))
            and (rec.rf == nil or (type(rec.rf) == "string" and #rec.rf <= REF_MAX))
            and IsInt(rec.t, 1, MAX_REV) and (rec.an == nil or rec.an == 1) and (rec.au == nil or rec.au == 1)
            and ValidContext(rec.c) and ValidError(rec.e) and true or false
    end
    if type(rec.i) ~= "string" or #rec.i > ID_MAX or not strfind(rec.i, "#%d+$") then return false end
    if k == "v" then
        return id == rec.i .. "+" .. a
    elseif k == "r" then
        if not IsInt(rec.n, 1, 1000000) or id ~= rec.i .. "@" .. a .. "#" .. rec.n then return false end
        if rec.d == 1 then return true end
        return type(rec.x) == "string" and rec.x ~= "" and #rec.x <= REPLY_MAX and IsInt(rec.t, 1, MAX_REV)
    elseif k == "s" then
        return id == rec.i .. "!" and STATES[rec.s] and (rec.dp == nil or (type(rec.dp) == "string" and #rec.dp
            <= ID_MAX)) and (rec.v == nil or (type(rec.v) == "string" and #rec.v <= 20)) and true or false
    elseif k == "n" then
        return id == rec.i .. "=" and IsInt(rec.no, 1, 1000000)
    end
    return false
end

-- May this record come to me from sender? Statuses, numbers and staff replies only from staff (anyone passing them
-- on could have made them up); the rest from anyone in the guild (Comm already checked that).
local function Trusted(rec, sender)
    if rec.k == "n" then
        if not Feedback:IsDev(rec.a) then return false end
        return sender == nil or sender == rec.a or Feedback:IsStaff(sender)
    end
    if rec.k == "s" or (rec.k == "r" and Feedback:IsStaff(rec.a)) then
        if not Feedback:IsStaff(rec.a) then return false end
        return sender == nil or sender == rec.a or Feedback:IsStaff(sender)
    end
    return true
end

local function Newer(a, b)
    if a.rv ~= b.rv then return a.rv > b.rv end
    return Util.Canonical(a) > Util.Canonical(b)
end

local recordCount = 0

local function CountRecords()
    local n = 0
    for _ in pairs(Records(true)) do n = n + 1 end
    recordCount = n
    return n
end

-- Takes a record (from me: sender nil). real: into the real store even in demo mode (anything from the network is
-- real). Returns true when it changed what I hold.
local function Put(id, rec, sender, real)
    if not Valid(id, rec) or not Trusted(rec, sender) then return false end
    real = real or sender ~= nil or not DemoOn()
    local s = Store(true, real)
    if not s then return false end
    local old = s.r[id]
    if old then
        if not Newer(rec, old) then return false end
    elseif real then
        if recordCount >= MAX_RECORDS then return false end
        recordCount = recordCount + 1
    end
    s.r[id] = rec
    return true
end

---------------------------------------------------------------------------
-- Archive (closed long ago: out of the sync; dropped except by the developer)
---------------------------------------------------------------------------

local function ArchivedItems(r, now)
    now = now or Now()
    local out = {}
    for id, rec in pairs(r) do
        if rec.k == "i" and rec.d == 1 and now - rec.rv > ARCHIVE_GONE then out[id] = true end
        if rec.k == "s" and CLOSED[rec.s] and now - rec.rv > ARCHIVE_CLOSED then out[rec.i] = true end
    end
    return out
end

local function Prune()
    local s = Store(false, true)
    if not s or Feedback:AmIDev() then return end
    local gone = ArchivedItems(s.r)
    if not next(gone) then return end
    for id, rec in pairs(s.r) do
        if gone[ItemOf(id, rec)] then s.r[id] = nil end
    end
    CountRecords()
    Changed()
end

---------------------------------------------------------------------------
-- Digest
---------------------------------------------------------------------------

local function BucketOf(id)
    return Util.Adler32(id) % BUCKETS + 1
end

-- { [bucket] = { [id] = rv } } of what I share (archived items left out).
local function Index()
    local r = Records(true)
    local gone = ArchivedItems(r)
    local out = {}
    for id, rec in pairs(r) do
        if not gone[ItemOf(id, rec)] then
            local b = BucketOf(id)
            out[b] = out[b] or {}
            out[b][id] = rec.rv
        end
    end
    return out
end

local function BucketHash(list)
    if not list then return 0 end
    local keys = {}
    for id in pairs(list) do keys[#keys + 1] = id end
    tsort(keys)
    local parts = {}
    for i, id in ipairs(keys) do parts[i] = id .. "=" .. list[id] end
    return Util.Adler32(tconcat(parts, ";"))
end

local function Hashes()
    if cache.hashes then return cache.hashes, cache.index end
    local idx = Index()
    local h = {}
    for b = 1, BUCKETS do h[b] = BucketHash(idx[b]) end
    cache.hashes, cache.index = h, idx
    return h, idx
end

---------------------------------------------------------------------------
-- Network
---------------------------------------------------------------------------

local function Comm() return ns.Comm end

local function Send(msg, dist, target)
    local C = Comm()
    return (C and C.Send and C:Send(msg, dist, target, "fb")) and true or false
end

-- Splits { [id] = rec } into messages of at most BATCH canonical bytes and sends them.
local function SendRecords(t, ids, dist, target)
    local batch, size = {}, 0
    local sent = 0
    local function flush()
        if next(batch) then
            if Send({ t = t, r = batch }, dist, target) then sent = sent + 1 end
            batch, size = {}, 0
        end
    end
    local r = Records(true)
    for _, id in ipairs(ids) do
        local rec = r[id]
        if rec then
            local n = #Util.Canonical(rec) + #id + 4
            if size > 0 and size + n > BATCH then flush() end
            batch[id] = rec
            size = size + n
        end
    end
    flush()
    return sent
end

-- Tells the guild about records I made or changed (real: also in demo mode, the sync's and the developer's).
local function Announce(ids, real)
    if not real and DemoOn() then return end
    if type(ids) == "string" then ids = { ids } end
    SendRecords("FBN", ids, "GUILD")
end

local function TakeRecords(msg, sender)
    if type(msg.r) ~= "table" then return 0 end
    local n, changed = 0, false
    for id, rec in pairs(msg.r) do
        n = n + 1
        if n > 200 then break end
        if Put(id, rec, sender) then changed = true end
    end
    if changed then
        Changed()
        Feedback:OnNewRecords()
    end
    return changed
end

local function OnNew(sender, msg, dist)
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    TakeRecords(msg, sender)
end

local function OnRecords(sender, msg, dist)
    if dist ~= "WHISPER" then return end
    TakeRecords(msg, sender)
end

local answered = {}     -- [sender] = GetTime() of my last FBI
local helloSent = {}    -- [target] = GetTime() of my FBH (only an answer to one is taken)
local asked = {}        -- [sender] = ids they asked me for this session

-- Somebody logged in and says what they hold: my index of the buckets that differ.
local function OnHello(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg.h) ~= "table" then return end
    local now = GetTime()
    if answered[sender] and now - answered[sender] < ANSWER_LIMIT then return end
    answered[sender] = now
    local h, idx = Hashes()
    local diff = {}
    for b = 1, BUCKETS do
        if tonumber(msg.h[b]) ~= h[b] then diff[#diff + 1] = b end
    end
    -- (always answer, even when nothing differs: the asker then knows the exchange is done)
    local part, size = {}, 0
    local function flush(last)
        Send({ t = "FBI", b = part, h = last and h or nil }, "WHISPER", sender)
        part, size = {}, 0
    end
    for _, b in ipairs(diff) do
        local list = idx[b] or {}
        local chunk = {}
        part[b] = chunk
        for id, rv in pairs(list) do
            local n = #id + 12
            if size > 0 and size + n > BATCH then
                flush(false)
                chunk = {}
                part[b] = chunk
            end
            chunk[id] = rv
            size = size + n
        end
    end
    flush(true)
end

-- The answer to my FBH (in one or more parts, the last with h): ask for what I lack; at the last part, tell the
-- guild what the other one lacked in the buckets that differ.
local pending = {}      -- [sender] = { buckets = { [b] = true }, seen = { [id] = rv } } while an answer comes in

local function OnIndex(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg.b) ~= "table" then return end
    if not helloSent[sender] then return end
    local mine = Records(true)
    local st = pending[sender] or { buckets = {}, seen = {}, n = 0 }
    pending[sender] = st
    local want = {}
    for b, list in pairs(msg.b) do
        if IsInt(b, 1, BUCKETS) and type(list) == "table" then
            st.buckets[b] = true
            for id, rv in pairs(list) do
                st.n = st.n + 1
                if st.n > 5000 then break end
                if type(id) == "string" and #id <= ID_MAX and IsInt(rv, 1, MAX_REV) then
                    st.seen[id] = rv
                    local rec = mine[id]
                    if not rec or rec.rv < rv then want[#want + 1] = id end
                end
            end
        end
    end
    tsort(want)
    local part, size = {}, 0
    for _, id in ipairs(want) do
        if size > 0 and size + #id + 3 > BATCH then
            Send({ t = "FBQ", q = part }, "WHISPER", sender)
            part, size = {}, 0
        end
        part[#part + 1] = id
        size = size + #id + 3
    end
    if #part > 0 then Send({ t = "FBQ", q = part }, "WHISPER", sender) end
    if msg.h then
        pending[sender] = nil
        helloSent[sender] = nil
        local _, idx = Hashes()
        local give = {}
        for b in pairs(st.buckets) do
            for id, rv in pairs(idx[b] or {}) do
                local theirs = st.seen[id]
                if not (theirs and theirs >= rv) then give[#give + 1] = id end
            end
        end
        tsort(give)
        if #give > 0 then Announce(give, true) end
    end
end

local function OnQuery(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg.q) ~= "table" then return end
    local ids = {}
    local r = Records(true)
    local gone = ArchivedItems(r)
    for i, id in ipairs(msg.q) do
        if i > 500 then break end
        local rec = type(id) == "string" and r[id]
        if rec and not gone[ItemOf(id, rec)] then ids[#ids + 1] = id end
    end
    asked[sender] = (asked[sender] or 0) + #ids
    if asked[sender] > ASK_LIMIT then return end
    SendRecords("FBR", ids, "WHISPER", sender)
end

-- Whom to ask at login: the developer, else staff, else the member seen most recently (online, running the addon).
local function PickPeer()
    local Guild = G()
    if not (Guild and Guild:IsReady()) then return nil end
    local Sync = ns.Sync
    local best, bestScore
    for _, key in ipairs(Guild:GetOnlineMembers()) do
        if not Util.IsMe(key) then
            local p = Sync and Sync.GetPeer and Sync:GetPeer(key)
            if p then
                local score = (Feedback:IsDev(key) and 3e9 or 0) + (Feedback:IsStaff(key) and 2e9 or 0)
                    + (tonumber(p.lastSeen) or 0) / 2
                if not bestScore or score > bestScore or (score == bestScore and key < best) then
                    best, bestScore = key, score
                end
            end
        end
    end
    return best
end

-- Compares what I hold with one member online. Returns the member, or nil.
function Feedback:SyncNow(target)
    target = target or PickPeer()
    if not target or not Store(true, true) then return nil end
    helloSent[target] = GetTime()
    Send({ t = "FBH", h = (Hashes()) }, "WHISPER", target)
    return target
end

---------------------------------------------------------------------------
-- The developer's side: numbers, shipped items
---------------------------------------------------------------------------

-- Numbers every item I (the developer) hold without one, oldest first. Returns the ids numbered.
local function NumberNew()
    if not Feedback:AmIDev() then return {} end
    local s = Store(true, true)
    if not s then return {} end
    local me = Me()
    local todo = {}
    local used = {}
    for id, rec in pairs(s.r) do
        if rec.k == "n" then used[rec.i] = true end
    end
    for id, rec in pairs(s.r) do
        if rec.k == "i" and rec.d ~= 1 and not used[id] then todo[#todo + 1] = rec end
    end
    tsort(todo, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return ItemIdOf(a.a, a.n) < ItemIdOf(b.a, b.n)
    end)
    local last = tonumber(s.no) or 0
    for _, rec in pairs(s.r) do
        if rec.k == "n" and rec.no > last then last = rec.no end
    end
    local ids = {}
    for _, item in ipairs(todo) do
        last = last + 1
        local iid = ItemIdOf(item.a, item.n)
        local id = iid .. "="
        if Put(id, { k = "n", i = iid, a = me, no = last, rv = Now() }, nil, true) then ids[#ids + 1] = id end
    end
    s.no = last
    return ids
end

-- Changelog numbers: { [no] = { version, line } } (the oldest release naming each number).
local function ChangelogNumbers()
    local out = {}
    for _, e in ipairs(ns.CHANGELOG or {}) do
        for _, sec in ipairs(e.sections or {}) do
            for _, line in ipairs(sec.lines or {}) do
                if type(line) == "table" and type(line.fb) == "table" then
                    for _, no in ipairs(line.fb) do
                        if type(no) == "number" then out[no] = { version = e.version, line = line } end
                    end
                end
            end
        end
    end
    return out
end
Feedback.ChangelogNumbers = ChangelogNumbers

-- The developer runs the release first: items its notes name become "done" for everyone (members on an older
-- version then read "Fixed in 1.3.5").
local function MarkShipped()
    if not Feedback:AmIDev() then return {} end
    local nums = ChangelogNumbers()
    local byNo = {}
    for id, rec in pairs(Records(true)) do
        if rec.k == "n" then byNo[rec.no] = rec.i end
    end
    local ids = {}
    local me = Me()
    for no, at in pairs(nums) do
        local iid = byNo[no]
        if iid and Util.CompareVersions(at.version, ns.version) <= 0 then
            local cur = Records(true)[iid .. "!"]
            if not (cur and cur.s == "done" and cur.v == at.version) then
                local rv = max(Now(), cur and cur.rv + 1 or 0)
                if Put(iid .. "!", { k = "s", i = iid, a = me, s = "done", v = at.version, rv = rv }, nil, true) then
                    ids[#ids + 1] = iid .. "!"
                end
            end
        end
    end
    return ids
end

-- After records came in: the developer numbers what is new and tells the guild.
function Feedback:OnNewRecords()
    if not self:AmIDev() then return end
    Util.Debounce("feedback-number", 2, function()
        local ids = NumberNew()
        if #ids > 0 then
            Changed()
            Announce(ids, true)
        end
    end)
end

---------------------------------------------------------------------------
-- Lua errors in DisasterZone: kept for a bug, and reported by themselves (Settings > Notifications > Feedback:
-- settings.feedbackAuto, on unless false). A report is a bug item like any other, sent as the player: its text says
-- what broke, its error (e.p) holds the whole report (the error, the stack, what was going on, the locals, the other
-- addons), and au = 1 marks it as sent by itself. Somebody else's open report of the same error gets a me too
-- instead; one fixed in a newer release, or closed by staff, gets nothing. The developer's own errors stay out of
-- the guild's list (BugSack shows them); in demo mode they go to the demo list, never sent.
---------------------------------------------------------------------------

local errors = {}           -- recent DisasterZone errors, newest last: { m, s, n, at, v, c = context, w = what was going
                            -- on (lines), d = the same in a few words, l = locals; f = the item it went into, how,
                            -- x = why it was not reported }
local ERRORS_KEPT = 5
local AUTO_DELAY = 8        -- seconds from an error to its report (repeats count up meanwhile) ...
local AUTO_SPREAD = 30      -- ... plus up to this much per character: a raid that hits it at once reports it once
local AUTO_PER_SESSION = 3  -- reports one session files (me-toos don't count)
local AUTO_KEPT = 60        -- errors remembered as reported (db.feedbackAuto)
local LOCALS_MAX = 900
local ADDONS_MAX = 400
local autoFiled = 0
local loginDone = false     -- (the login sync ran: the guild's reports are known before mine goes out)
local loginAt               -- GetTime() at login (how long the session ran before an error)
local demoReported = {}     -- demo mode's db.feedbackAuto (never saved)

local function IsOurs(text)
    return type(text) == "string" and (strfind(text, "DisasterZone", 1, true) ~= nil)
end

-- An error's message without its "3x " count, the folders up to the addon's and the [string "@..."] wrapper.
local function Bare(m)
    m = m:gsub("\\", "/"):gsub("^%d+x ", ""):gsub('%[string "@?([^"]*)"%]', "%1")
    return (m:gsub("^[^:]-[Ii]nterface/[Aa]dd[Oo]ns/", ""))
end

-- The same error compares as the same key (a pasted copy too).
local function ErrorKey(m)
    if type(m) ~= "string" or m == "" then return nil end
    return strlower(Util.Trim(Bare(m)))
end
Feedback.ErrorKey = ErrorKey

-- "UI/RollFrame.lua:412", "attempt to index ..." (where: nil when the message names no file).
local function ErrorParts(m)
    local b = Bare(m)
    local where, what = strmatch(b, "^(.-%.lua:%d+): (.*)$")
    if not where then return nil, b end
    return (where:gsub("^DisasterZone/", "")), what
end

local function Ago(seconds)
    seconds = max(0, floor(seconds + 0.5))
    if seconds < 120 then return seconds .. " s" end
    if seconds < 7200 then return floor(seconds / 60) .. " min" end
    return floor(seconds / 3600) .. " h"
end

-- What was going on when an error hit: short lines for its report, and a few words for its text ("Raids page open,
-- in combat, raid of 25").
local function Happening()
    local out, words = {}, {}
    local MF = ns.MainFrame
    local open = MF and MF.IsShown and MF:IsShown()
    local page = open and MF.GetSelectedTab and MF:GetSelectedTab()
    out[#out + 1] = "Window: " .. (open and ("open on " .. tostring(page or "?")) or "closed")
    if page then
        local label = MF.GetPageLabel and MF:GetPageLabel(page)
        words[#words + 1] = (type(label) == "string" and label ~= "" and label or page) .. " page open"
    end
    local fight = InCombatLockdown and InCombatLockdown()
    out[#out + 1] = "In combat: " .. (fight and "yes" or "no")
    if fight then words[#words + 1] = "in combat" end
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    local group = (IsInRaid and IsInRaid()) and ("raid of " .. n) or (n > 0 and ("party of " .. n)) or nil
    out[#out + 1] = "Group: " .. (group or "none")
    if group then words[#words + 1] = "in a " .. group end
    if GetInstanceInfo then
        local name, kind, _, diff = GetInstanceInfo()
        if type(kind) == "string" and kind ~= "none" then
            out[#out + 1] = "Instance: " .. tostring(name) .. " (" .. ((type(diff) == "string" and diff ~= "") and diff or kind) .. ")"
        end
    end
    if DemoOn() then out[#out + 1] = "Demo mode: on" end
    local now = GetTime and GetTime() or 0
    if loginAt then out[#out + 1] = "Since login or /reload: " .. Ago(now - loginAt) end
    local trail = ns.GetTrail and ns:GetTrail() or {}
    if #trail > 0 then
        out[#out + 1] = "Last steps (newest last):"
        for _, st in ipairs(trail) do
            out[#out + 1] = "  " .. Ago(now - st.at) .. " before: " .. st.text .. (st.n > 1 and (" (x" .. st.n .. ")") or "")
        end
    end
    return out, tconcat(words, ", ")
end

-- The other addons loaded, as one line (ADDONS_MAX at most), or nil.
local function AddonList()
    local A = C_AddOns
    local num, info, loaded = A and A.GetNumAddOns, A and A.GetAddOnInfo, A and A.IsAddOnLoaded
    if not (num and info and loaded) then return nil end
    local names = {}
    for i = 1, num() do
        local name = info(i)
        if type(name) == "string" and not strfind(name, "^DisasterZone") and loaded(name) then names[#names + 1] = name end
    end
    tsort(names)
    local text = "Other addons (" .. #names .. "): " .. (#names > 0 and tconcat(names, ", ") or "none")
    if #text > ADDONS_MAX then text = strsub(text, 1, ADDONS_MAX - 3) .. "..." end
    return text
end

local CleanPaste    -- (below, with Submit)

-- An error's whole report as plain text (PASTE_MAX at most): what BugSack shows, what was going on, the locals,
-- the other addons loaded.
local function Report(e)
    local parts = { (e.n or 1) .. "x " .. e.m }
    if type(e.s) == "string" and e.s ~= "" then parts[#parts + 1] = e.s end
    if type(e.w) == "table" and #e.w > 0 then parts[#parts + 1] = "\nWhat was going on:\n" .. tconcat(e.w, "\n") end
    if type(e.l) == "string" and e.l ~= "" then parts[#parts + 1] = "\nLocals:\n" .. e.l end
    local ok, addons = pcall(AddonList)
    if ok and addons then parts[#parts + 1] = "\n" .. addons end
    return CleanPaste(tconcat(parts, "\n"))
end
Feedback.Report = function(_, e) return Report(e) end

local ScheduleReports   -- (below)

local function NoteError(msg, stack, count, locals)
    if type(msg) ~= "string" then msg = tostring(msg) end
    if not (IsOurs(msg) or IsOurs(stack)) then return end
    msg = Clean(msg, ERR_MSG_MAX) or "?"
    for _, e in ipairs(errors) do
        if e.m == msg then
            e.n = e.n + 1
            e.at = time()
            return
        end
    end
    local e = { m = msg, s = Clean(type(stack) == "string" and stack or "", ERR_STACK_MAX, true), n = tonumber(count) or 1,
                at = time(), v = ns.version }
    -- what was going on, for the report (none of it ever stops the note)
    local ok, c = pcall(Feedback.Context, Feedback)
    if ok then e.c = c end
    local ok2, w, words = pcall(Happening)
    if ok2 then e.w, e.d = w, words end
    if type(locals) == "string" and locals ~= "" then e.l = Clean((locals:gsub("\t", "    ")), LOCALS_MAX, true) end
    errors[#errors + 1] = e
    while #errors > ERRORS_KEPT do table.remove(errors, 1) end
    local db = ns.db
    if db then db.feedbackErrors = errors end
    ns:Fire("FEEDBACK_ERROR", e)
    ScheduleReports()
end
Feedback.NoteError = NoteError

-- Recent DisasterZone errors (newest last), this session's and the last session's.
function Feedback:GetErrors()
    return errors
end

-- The newest error worth attaching to a bug (in the last 30 minutes, and not reported by itself already), or nil.
function Feedback:RecentError()
    local e = errors[#errors]
    if e and not e.f and time() - (e.at or 0) <= 1800 then return e end
    return nil
end

local function HookErrors()
    -- BugGrabber (BugSack) owns the error handler when it is installed: its callback hands us each error
    local BG = BugGrabber
    if type(BG) == "table" and type(BG.RegisterCallback) == "function" then
        local ok = pcall(BG.RegisterCallback, Feedback, "BugGrabber_BugGrabbed", function(_, bug)
            if type(bug) == "table" then pcall(NoteError, bug.message, bug.stack, bug.counter, bug.locals) end
        end)
        if ok then return "buggrabber" end
    end
    if not (geterrorhandler and seterrorhandler) then return nil end
    local prev = geterrorhandler()
    local busy = false      -- (never into ourselves: a handler that calls back would loop)
    local last              -- (the locals only for a message not seen just before: an error every frame stays cheap)
    seterrorhandler(function(msg, ...)
        if busy then return msg end
        busy = true
        local locals
        if msg ~= last and debuglocals then
            last = msg
            local ok, l = pcall(debuglocals, 3)
            if ok then locals = l end
        end
        pcall(NoteError, msg, debugstack and debugstack(3, 12, 0) or nil, nil, locals)
        busy = false
        if prev then return prev(msg, ...) end
        return msg
    end)
    return "handler"
end

-- Is reporting by itself on (Settings > Notifications > Feedback)?
function Feedback:AutoOn()
    local DB = ns.DB
    return not (ns.db and DB and DB.GetSetting and DB:GetSetting("feedbackAuto") == false)
end

-- Will this error be reported by itself (FEEDBACK_AUTO follows), so the UI waits instead of offering the form?
function Feedback:WillReport(e)
    return type(e) == "table" and self:AutoOn() and e.v == ns.version and (DemoOn() or not self:AmIDev())
        and IsInGuild() and true or false
end

---------------------------------------------------------------------------
-- Views
---------------------------------------------------------------------------

-- Rebuilds the item views from the records: { [itemId] = view }.
local function Rebuild()
    if not cache.dirty and cache.items then return cache.items end
    local r = Records()
    local items, byNo = {}, {}
    for id, rec in pairs(r) do
        if rec.k == "i" then
            items[id] = {
                id = id, author = rec.a, n = rec.n, kind = rec.kd, text = rec.x, about = rec.ab, ref = rec.rf,
                ctx = rec.c, err = rec.e, at = rec.t, rv = rec.rv, anon = rec.an == 1, gone = rec.d == 1, auto = rec.au == 1,
                votes = {}, replies = {}, voteCount = 0,
            }
        end
    end
    for id, rec in pairs(r) do
        local item = rec.k ~= "i" and items[rec.i]
        if item then
            if rec.k == "v" and rec.d ~= 1 and rec.a ~= item.author then
                item.votes[rec.a] = true
                item.voteCount = item.voteCount + 1
            elseif rec.k == "r" and rec.d ~= 1 and (rec.a == item.author or Feedback:IsStaff(rec.a)) then
                item.replies[#item.replies + 1] = { id = id, author = rec.a, text = rec.x, at = rec.t,
                    staff = Feedback:IsStaff(rec.a) and rec.a ~= item.author }
            elseif rec.k == "s" then
                item.state, item.stateBy, item.stateAt, item.dup, item.shipped = rec.s, rec.a, rec.rv, rec.dp, rec.v
            elseif rec.k == "n" then
                item.no = rec.no
                item.seenAt = rec.rv
                byNo[rec.no] = item
            end
        end
    end
    -- what the changelog says beats the records: the release notes name the number
    local nums = ChangelogNumbers()
    for _, item in pairs(items) do
        tsort(item.replies, function(a, b)
            if a.at ~= b.at then return a.at < b.at end
            return a.id < b.id
        end)
        local at = item.no and nums[item.no]
        if at then
            item.shipped = at.version
            item.shippedLine = at.line
            item.state = "done"
        end
        item.closed = CLOSED[item.state] and true or false
        item.answered = false      -- (staff answered it: out of the Inbox)
        for _, rep in ipairs(item.replies) do
            if rep.staff then item.answered = true end
        end
    end
    cache.items, cache.byNo, cache.dirty = items, byNo, false
    return items
end

-- How far the item got, for the author's tracker: 1 sent, 2 the developer has it, 3 planned, 4 shipped (or
-- installed: "Fixed in"). closed = the closing state when it ended any other way.
function Feedback:Stage(item)
    if item.state == "done" then return 4 end
    if item.state == "planned" then return 3 end
    if item.no then return 2 end
    return 1
end

-- "Fixed in 1.3.5" | "Coming in 1.3.5" (a release newer than mine) | nil.
function Feedback:ShippedText(item)
    if not item.shipped then return nil end
    local verb = item.kind == "bug" and "Fixed" or "Added"
    if item.kind == "change" then verb = "Changed" end
    if Util.CompareVersions(item.shipped, ns.version) > 0 then return "Coming in " .. item.shipped end
    return verb .. " in " .. item.shipped
end

function Feedback:Get(id)
    local items = Rebuild()
    local item = items[id]
    if item and item.gone then return nil end
    if item then item.mine = self:IsMine(item.author) ; item.voted = item.votes[Me() or ""] or false end
    return item
end

function Feedback:GetByNumber(no)
    Rebuild()
    return cache.byNo and cache.byNo[no] or nil
end

-- Is key one of my characters (the saved data is account wide)?
function Feedback:IsMine(key)
    if type(key) ~= "string" then return false end
    if Util.IsMe(key) then return true end
    local db = ns.db
    return (db and type(db.chars) == "table" and db.chars[key] ~= nil) and true or false
end

-- filter: { mine = true, inbox = true (staff: open and not answered), kind = "bug", open = true, text = "search" }.
-- sort: "asked" (most me-toos first) | "new". Returns an array of views.
function Feedback:List(filter, sort)
    filter = filter or {}
    local out = {}
    local me = Me() or ""
    local needle = type(filter.text) == "string" and filter.text ~= "" and strlower(filter.text) or nil
    for _, item in pairs(Rebuild()) do
        if not item.gone and (item.state ~= "removed" or filter.inbox) then
            item.mine = self:IsMine(item.author)
            item.voted = item.votes[me] or false
            local ok = true
            if filter.mine and not (item.mine or item.voted) then ok = false end
            if filter.kind and item.kind ~= filter.kind then ok = false end
            if filter.open and item.closed then ok = false end
            if filter.inbox and (item.closed or item.state == "planned" or item.answered) then ok = false end
            if ok and needle and not (strfind(strlower(item.text or ""), needle, 1, true)
                or strfind(strlower(item.about or ""), needle, 1, true)
                or strfind(strlower(Short(item.author)), needle, 1, true)
                or (item.no and tostring(item.no) == (needle:gsub("^#", "")))) then ok = false end
            if ok then out[#out + 1] = item end
        end
    end
    tsort(out, function(a, b)
        if sort == "asked" then
            if a.closed ~= b.closed then return not a.closed end
            if a.voteCount ~= b.voteCount then return a.voteCount > b.voteCount end
        end
        if a.at ~= b.at then return a.at > b.at end
        return a.id < b.id
    end)
    return out
end

-- The banner's numbers: { open, planned, shipped, total } over the items everyone sees.
function Feedback:Counts()
    local c = { open = 0, planned = 0, shipped = 0, total = 0 }
    for _, item in pairs(Rebuild()) do
        if not item.gone and item.state ~= "removed" then
            c.total = c.total + 1
            if item.state == "done" then c.shipped = c.shipped + 1 end
            if not item.closed then
                c.open = c.open + 1
                if item.state == "planned" then c.planned = c.planned + 1 end
            end
        end
    end
    return c
end

-- Items waiting for staff (open, not planned yet).
function Feedback:InboxCount()
    return #self:List({ inbox = true })
end

-- Words of a text for "is this the same thing?" (3+ letters, a few common words left out).
local STOP = { the = true, ["and"] = true, ["for"] = true, ["with"] = true, ["this"] = true, ["that"] = true,
    ["when"] = true, ["would"] = true, ["could"] = true, ["should"] = true, ["have"] = true, ["from"] = true,
    ["into"] = true, ["there"] = true, ["they"] = true, ["what"] = true, ["just"] = true, ["like"] = true,
    ["make"] = true, ["also"] = true, ["some"] = true, ["more"] = true, ["only"] = true, ["very"] = true,
    ["it's"] = true, ["can't"] = true, ["don't"] = true, ["are"] = true, ["was"] = true, ["you"] = true,
    ["but"] = true, ["not"] = true, ["all"] = true, ["any"] = true, ["its"] = true, ["has"] = true }

local function Words(text)
    local set, n = {}, 0
    for w in strlower(text or ""):gmatch("[%a']+") do
        w = w:gsub("'s$", "")
        if #w >= 3 and not STOP[w] then
            if #w > 4 then w = w:gsub("ing$", ""):gsub("ed$", ""):gsub("s$", "") end
            if not set[w] then set[w] = true; n = n + 1 end
        end
    end
    return set, n
end

-- Open items like text (and about), best first: up to `limit` (default 2) views with a score.
function Feedback:Similar(text, about, limit)
    local words, n = Words((text or "") .. " " .. (about or ""))
    if n < 2 then return {} end
    local out = {}
    for _, item in ipairs(self:List({ open = true })) do
        if not item.mine then
            local other, m = Words((item.text or "") .. " " .. (item.about or ""))
            local both = 0
            for w in pairs(words) do if other[w] then both = both + 1 end end
            local score = both / max(1, min(n, m))
            if both >= 2 and score >= 0.34 then out[#out + 1] = { item = item, score = score } end
        end
    end
    tsort(out, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.item.id < b.item.id
    end)
    local res = {}
    for i = 1, min(limit or 2, #out) do res[i] = out[i].item end
    return res
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function NextSeq(s, key)
    local n = (tonumber(s.seq[key]) or 0) + 1
    -- (never reuse a number another of my records already holds, e.g. after the saved data was reset)
    while s.r[ItemIdOf(key, n)] do n = n + 1 end
    s.seq[key] = n
    return n
end

-- What is attached to an item automatically: version, build, zone, class / spec, the page open.
function Feedback:Context()
    local c = { v = tostring(ns.version or "?") }
    local Boot = DisasterZoneBoot
    local build = Boot and Boot.buildId
    if type(build) == "string" and build ~= "" then c.b = strsub(build, 1, 16) end
    local zone = GetRealZoneText and GetRealZoneText()
    local sub = GetSubZoneText and GetSubZoneText()
    if type(zone) == "string" and zone ~= "" then
        c.z = strsub(zone .. ((type(sub) == "string" and sub ~= "" and sub ~= zone) and (" · " .. sub) or ""), 1, 60)
    end
    if UnitClass then
        local _, cls = UnitClass("player")
        if type(cls) == "string" then c.cl = cls end
    end
    local spec = ns.BiS and ns.BiS.DetectSpec and ns.BiS:DetectSpec()
    if type(spec) == "string" and spec ~= "" then c.sp = strsub(spec, 1, 30) end
    local MF = ns.MainFrame
    local page = MF and MF.GetSelectedTab and MF:GetSelectedTab()
    if page then c.p = strsub(page, 1, 30) end
    local locale = GetLocale and GetLocale()
    if type(locale) == "string" then c.lo = locale end
    return c
end

-- An error pasted by the player (a BugSack copy): colour codes, textures and links taken out, plain text kept, cut at
-- PASTE_MAX. nil when nothing is left.
CleanPaste = function(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("||", "|"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|H.-|h(.-)|h", "%1")
    text = text:gsub("\t", "    ")
    text = Clean(text, PASTE_MAX, true)
    return text ~= "" and text or nil
end
Feedback.CleanPaste = CleanPaste
Feedback.PASTE_MAX = PASTE_MAX

-- The whole error text of an item (what was pasted, else the message and the stack), or nil.
function Feedback:ErrorText(item)
    local e = item and item.err
    if not e then return nil end
    if e.p then return e.p end
    return e.s and (e.m .. "\n\n" .. e.s) or e.m
end

-- Sends feedback. kind: "bug" | "idea" | "change" | "love"; opts: { about = label, ref = page ref, anon = true,
-- err = error table (Feedback:RecentError()), paste = error text the player pasted (a bug: it replaces err),
-- ctx = context (default Feedback:Context()), auto = true (a Lua error reporting itself: paste is its report) }.
-- Returns id or nil, err.
function Feedback:Submit(kind, text, opts)
    opts = opts or {}
    if not KIND_OK[kind] then return nil, "pick what kind of feedback it is" end
    text = Clean(text, TEXT_MAX, true)
    if not text or text == "" then return nil, "write a few words first" end
    if not IsInGuild() then return nil, "feedback travels through the guild: you are not in one" end
    local s = Store(true)
    local me = Me()
    if not (s and me) then return nil, "your guild is not known yet, try again in a moment" end
    local open = 0
    for _, item in pairs(Rebuild()) do
        if item.author == me and not item.gone and not item.closed then open = open + 1 end
    end
    if open >= OPEN_PER_AUTHOR then
        return nil, ("you have %d open items: withdraw one first"):format(open)
    end
    local n = NextSeq(s, me)
    local id = ItemIdOf(me, n)
    local e = opts.err
    local err = (type(e) == "table" and type(e.m) == "string") and { m = Clean(e.m, ERR_MSG_MAX),
        s = Clean(e.s or "", ERR_STACK_MAX, true), n = IsInt(e.n, 1, 1000000) and e.n or nil,
        v = type(e.v) == "string" and strsub(e.v, 1, 20) or nil } or nil
    if err and err.s == "" then err.s = nil end
    local paste = kind == "bug" and CleanPaste(opts.paste)
    if paste then
        -- (m: the first line, what older clients and the tooltips show; a report by itself keeps its error's message
        -- and count)
        local first = strmatch(paste, "^[^\n]+") or paste
        local own = opts.auto and err
        err = { m = own and err.m or Clean(first, ERR_MSG_MAX), p = paste, n = own and err.n or nil,
                v = type(ns.version) == "string" and strsub(ns.version, 1, 20) or nil }
    end
    local rec = {
        k = "i", a = me, n = n, kd = kind, x = text, t = Now(), rv = Now(),
        ab = Clean(opts.about, ABOUT_MAX) or nil, rf = type(opts.ref) == "string" and strsub(opts.ref, 1, REF_MAX) or nil,
        c = opts.ctx or self:Context(), e = err, an = opts.anon and 1 or nil,
        au = (opts.auto and kind == "bug") and 1 or nil,
    }
    if rec.ab == "" then rec.ab = nil end
    if not Put(id, rec) then return nil, "could not save it" end
    Changed()
    Announce(id)
    if DemoOn() then
        Util.After(3, function() Feedback:DemoNumber(id) end)
    else
        self:OnNewRecords()
    end
    return id
end

-- Withdraws one of my items (it stays as a tombstone so it never comes back from another client).
function Feedback:Withdraw(id)
    local s = Store(false)
    local rec = s and s.r[id]
    if not (rec and rec.k == "i" and self:IsMine(rec.a)) then return false, "not your item" end
    if rec.d == 1 then return true end
    local new = { k = "i", a = rec.a, n = rec.n, d = 1, rv = max(Now(), rec.rv + 1) }
    if not Put(id, new) then return false, "could not withdraw it" end
    Changed()
    Announce(id)
    return true
end

-- Me too (on = true) or take it back. Returns ok, err.
function Feedback:Vote(id, on)
    local item = self:Get(id)
    if not item then return false, "unknown item" end
    local me = Me()
    if item.author == me then return false, "it's your own" end
    local vid = id .. "+" .. me
    local old = Records()[vid]
    local was = old and old.d ~= 1
    if (on and true or false) == (was and true or false) then return true end
    local rec = { k = "v", i = id, a = me, d = (not on) and 1 or nil, rv = max(Now(), old and old.rv + 1 or 0) }
    if not Put(vid, rec) then return false, "could not save it" end
    Changed()
    Announce(vid)
    return true
end

-- May I reply on this item? Its author and staff.
function Feedback:CanReply(item)
    if not item then return false end
    return self:IsMine(item.author) or self:AmIStaff()
end

function Feedback:Reply(id, text)
    local item = self:Get(id)
    if not item then return nil, "unknown item" end
    if not self:CanReply(item) then return nil, "only the author and the officers answer here" end
    text = Clean(text, REPLY_MAX, true)
    if not text or text == "" then return nil, "write a few words first" end
    local s = Store(true)
    local me = Me()
    -- (an officer's debug role has no rights on the wire: Trusted refuses it, so the reply stays mine alone)
    local n = NextSeq(s, me)
    local rid = id .. "@" .. me .. "#" .. n
    local rec = { k = "r", i = id, a = me, n = n, x = text, t = Now(), rv = Now() }
    if not Put(rid, rec) then return nil, "only the author and the officers answer here" end
    Changed()
    Announce(rid)
    return rid
end

-- Staff: sets an item's state ("planned", "exists", "notnow", "dup", "removed", "done"; nil = open again). dup:
-- the item it repeats. A reply text goes with it when given. Returns ok, err.
function Feedback:SetState(id, state, opts)
    opts = opts or {}
    if not self:AmIStaff() then return false, "only the officers and the developer set a status" end
    local item = self:Get(id)
    if not item then return false, "unknown item" end
    if state ~= nil and not STATES[state] then return false, "unknown status" end
    if state == "dup" and not (type(opts.dup) == "string" and opts.dup ~= id and self:Get(opts.dup)) then
        return false, "pick the item it repeats"
    end
    local sid = id .. "!"
    local old = Records()[sid]
    local me = Me()
    local ids = {}
    if state == nil then
        if not old then return true end
        state = "open"
    end
    local rec = { k = "s", i = id, a = me, s = state, dp = state == "dup" and opts.dup or nil,
                  v = state == "done" and type(opts.version) == "string" and opts.version or nil,
                  rv = max(Now(), old and old.rv + 1 or 0) }
    if not Put(sid, rec) then return false, "your rank does not let you set a status" end
    ids[#ids + 1] = sid
    if type(opts.reply) == "string" and Util.Trim(opts.reply) ~= "" then
        local rid = self:Reply(id, opts.reply)
        if rid then ids[#ids + 1] = rid end
    end
    Changed()
    Announce(ids)
    return true
end

---------------------------------------------------------------------------
-- Errors that report themselves (the notes above, Lua errors in DisasterZone)
---------------------------------------------------------------------------

-- Errors this account reported: { [key] = { v = version, i = item, t = when } } (demo mode: in memory).
local function Reported()
    if DemoOn() then return demoReported end
    local db = ns.db
    if not db then return {} end
    if type(db.feedbackAuto) ~= "table" then db.feedbackAuto = {} end
    return db.feedbackAuto
end

local function Remember(key, id)
    local seen = Reported()
    seen[key] = { v = ns.version, i = id, t = time() }
    local keys = {}
    for k in pairs(seen) do keys[#keys + 1] = k end
    if #keys <= AUTO_KEPT then return end
    local function T(k) return type(seen[k]) == "table" and tonumber(seen[k].t) or 0 end
    tsort(keys, function(a, b) return T(a) < T(b) end)
    for i = 1, #keys - AUTO_KEPT do seen[keys[i]] = nil end
end

-- The guild's report of the same error: an open one (the oldest), else the closed one closed last; or nil.
local function SameErrorItem(key)
    local open, closed
    for _, item in pairs(Rebuild()) do
        if not item.gone and item.err and ErrorKey(item.err.m) == key then
            if not item.closed then
                if not open or item.at < open.at then open = item end
            elseif not closed or (item.stateAt or item.at) > (closed.stateAt or closed.at) then
                closed = item
            end
        end
    end
    return open or closed
end

-- Reports one error by itself. Returns how, id: "filed" (a new bug), "joined" (a me too on somebody's open report),
-- "fixed" (fixed in a release newer than mine), "known" (reported before, mine, or closed by staff); or nil, why not
-- ("wait": the guild's feedback isn't in yet, the next login look tries again).
local function AutoReport(e)
    if not Feedback:WillReport(e) then return nil, "off" end
    if time() - (tonumber(e.at) or 0) > 86400 then return nil, "old" end
    if not DemoOn() and not (loginDone and Store(true, true)) then return nil, "wait" end
    local key = ErrorKey(e.m)
    if not key then return nil, "old" end
    local before = Reported()[key]
    if type(before) == "table" and before.v == ns.version then return "known", before.i end
    local same = SameErrorItem(key)
    if same then
        if not same.closed then
            if Feedback:IsMine(same.author) then return "known", same.id end
            Feedback:Vote(same.id, true)
            return "joined", same.id
        end
        if same.state == "done" and same.shipped and Util.CompareVersions(same.shipped, ns.version) > 0 then
            return "fixed", same.id
        end
        -- (closed by staff: not again; fixed in my release or before and back again: a new report)
        if same.state ~= "done" then return "known", same.id end
    end
    if autoFiled >= AUTO_PER_SESSION then return nil, "enough" end
    local where, what = ErrorParts(e.m)
    local text = "Lua error: " .. what .. "\n\nIt reported itself when it happened"
        .. ((type(e.d) == "string" and e.d ~= "") and (": " .. e.d) or "") .. "."
    local id, why = Feedback:Submit("bug", text, { about = where, err = e, paste = Report(e), auto = true,
        ctx = type(e.c) == "table" and e.c or nil })
    if not id then return nil, why end
    autoFiled = autoFiled + 1
    return "filed", id
end

-- Reasons the player is never told about: reporting is off (the form was offered at once), the error is old.
local QUIET = { off = true, old = true }

-- Reports the errors not reported yet. FEEDBACK_AUTO (error, how, id) for each one handled, (error, nil, why) for
-- one that should have gone and couldn't (the UI offers the form then).
local function Flush()
    for _, e in ipairs(errors) do
        if not (e.f or e.x) then
            local ok, how, id = pcall(AutoReport, e)
            if not ok then
                e.x = "error"        -- (never again: it would only fail again)
            elseif how then
                e.f, e.how = id or true, how
                local key = ErrorKey(e.m)
                if key then Remember(key, id) end
                ns:Fire("FEEDBACK_AUTO", e, how, id)
            elseif id ~= "wait" then
                e.x = id or "?"
                if not QUIET[e.x] then ns:Fire("FEEDBACK_AUTO", e, nil, e.x) end
            end
        end
    end
end
Feedback.FlushReports = Flush

ScheduleReports = function()
    Util.Debounce("feedback-auto", AUTO_DELAY + Jitter(AUTO_SPREAD, "fbauto"), Flush)
end

---------------------------------------------------------------------------
-- Credits (the changelog) and the "your idea shipped" note
---------------------------------------------------------------------------

-- Is one of my characters named in a changelog line's credits (by = { "Name", ... })?
function Feedback:LineIsMine(line)
    if type(line) ~= "table" or type(line.by) ~= "table" then return false end
    local mine = {}
    local db = ns.db
    for key in pairs(db and type(db.chars) == "table" and db.chars or {}) do
        mine[strmatch(key, "^([^%-]+)") or key] = true
    end
    local me = Me()
    if me then mine[strmatch(me, "^([^%-]+)") or me] = true end
    for _, name in ipairs(line.by) do
        if type(name) == "string" and mine[strmatch(name, "^([^%-]+)") or name] then return true end
    end
    -- a me too on a numbered item counts too
    if type(line.fb) == "table" then
        for _, no in ipairs(line.fb) do
            local item = self:GetByNumber(no)
            if item and (item.votes[me or ""] or self:IsMine(item.author)) then return true end
        end
    end
    return false
end

-- Lines of installed releases I haven't been told about that credit me: { { version, line }, ... }.
function Feedback:UntoldShipped()
    local s = ns.db and ns.db.settings
    local told = s and type(s.feedbackTold) == "string" and s.feedbackTold or nil
    local out = {}
    for _, e in ipairs(ns.CHANGELOG or {}) do
        if Util.CompareVersions(e.version, ns.version) <= 0 and (not told or Util.CompareVersions(e.version, told) > 0) then
            for _, sec in ipairs(e.sections or {}) do
                for _, line in ipairs(sec.lines or {}) do
                    if self:LineIsMine(line) then out[#out + 1] = { version = e.version, line = line } end
                end
            end
        end
    end
    return out
end

function Feedback:MarkToldShipped()
    local s = ns.db and ns.db.settings
    if s then s.feedbackTold = ns.version end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function AfterLogin()
    if loginDone or not IsInGuild() then return end
    local Guild = G()
    if not (Guild and Guild:IsReady() and GuildKey()) then return end
    loginDone = true
    CountRecords()
    Prune()
    local ids = {}
    for _, id in ipairs(NumberNew()) do ids[#ids + 1] = id end
    for _, id in ipairs(MarkShipped()) do ids[#ids + 1] = id end
    if #ids > 0 then
        Changed()
        Announce(ids, true)
    end
    Feedback:SyncNow()
    ns:Fire("FEEDBACK_UPDATED")
    -- errors that waited for the guild's feedback (this session's, or the last one's before a /reload)
    ScheduleReports()
end

function Feedback:OnInit()
    local C = Comm()
    if C and C.Register then
        C:Register("FBN", OnNew)
        C:Register("FBH", OnHello)
        C:Register("FBI", OnIndex)
        C:Register("FBQ", OnQuery)
        C:Register("FBR", OnRecords)
    end
    -- the last session's errors (a /reload: the error may be what the member wants to tell)
    local db = ns.db
    if db and type(db.feedbackErrors) == "table" then
        for _, e in ipairs(db.feedbackErrors) do
            if type(e) == "table" and type(e.m) == "string" then errors[#errors + 1] = e end
        end
        while #errors > ERRORS_KEPT do table.remove(errors, 1) end
    end
    Feedback.errorHook = HookErrors()
    -- the last steps an error's report tells (pages and slash commands note themselves, Core/Init.lua ns:Trail)
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function() ns:Trail("fight started") end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() ns:Trail("fight ended") end)
    ns:RegisterEvent("ENCOUNTER_START", function(_, _, name) ns:Trail("pull " .. tostring(name)) end)
    ns:RegisterEvent("ENCOUNTER_END", function(_, _, name, _, _, won)
        ns:Trail(tostring(name) .. (won == 1 and " killed" or " wipe"))
    end)
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
        ns:Trail("zone " .. tostring(GetRealZoneText and GetRealZoneText() or "?"))
    end)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function() ns:Trail("loading screen") end)
    ns:RegisterEvent("GROUP_JOINED", function() ns:Trail("joined a group") end)
    ns:RegisterEvent("GROUP_LEFT", function() ns:Trail("left the group") end)
    ns:RegisterEvent("LOOT_OPENED", function() ns:Trail("loot window") end)
    ns:On("CONFIG_UPDATED", function() Changed() end)
    ns:On("DEMO_TOGGLED", function() Changed() end)
    ns:On("GUILD_KEY_READY", function() cache.dirty = true end)
end

function Feedback:OnLogin()
    loginAt = GetTime()
    Util.After(LOGIN_DELAY + Jitter(10, "fb"), AfterLogin)
    ns:On("ROSTER_UPDATED", function()
        if not loginDone then Util.Debounce("feedback-login", LOGIN_DELAY, AfterLogin) end
    end)
end

---------------------------------------------------------------------------
-- Demo mode: the demo guild's feedback (in memory, never saved, never sent)
---------------------------------------------------------------------------

local DEMO_DAY = 86400

-- Builds the demo store on first use: eleven items from the demo guild at every stage (one is mine, one an error that
-- reported itself).
function Feedback:DemoStore()
    if demoStore then return demoStore end
    demoStore = { r = {}, seq = {}, no = 19 }
    local realm = Util.GetPlayerRealm()
    local function K(name) return name .. "-" .. realm end
    local me = Me() or K("You")
    local dev = K(DEV_NAME)
    local now = Now()
    local r = demoStore.r
    local function item(author, n, kind, text, ago, about, ctx, no, extra)
        local id = ItemIdOf(author, n)
        local rec = { k = "i", a = author, n = n, kd = kind, x = text, t = now - ago, rv = now - ago, ab = about, c = ctx }
        for k, v in pairs(extra or {}) do rec[k] = v end
        r[id] = rec
        if no then r[id .. "="] = { k = "n", i = id, a = dev, no = no, rv = now - ago + 600 } end
        return id
    end
    local function votes(id, names)
        for _, who in ipairs(names) do
            local key = who == "me" and me or K(who)
            r[id .. "+" .. key] = { k = "v", i = id, a = key, rv = now - 3600 }
        end
    end
    local function status(id, by, s, ago, v)
        r[id .. "!"] = { k = "s", i = id, a = by, s = s, v = v, rv = now - ago }
    end
    local seqs = {}
    local function answer(id, by, text, ago)
        seqs[by] = (seqs[by] or 100) + 1
        local rid = id .. "@" .. by .. "#" .. seqs[by]
        r[rid] = { k = "r", i = id, a = by, n = seqs[by], x = text, t = now - ago, rv = now - ago }
    end
    local v = tostring(ns.version or "1.3.4")
    local function ctx(z, cl, sp) return { v = v, z = z, cl = cl, sp = sp } end

    local isolde = item(K("Isolde"), 3, "idea", "Show who still needs a token on the boss tiles of a raid's page.",
        2 * DEMO_DAY, "Raids › Boss tiles", ctx("Shattrath City", "PRIEST", "Holy"), 14)
    votes(isolde, { "me", "Grimtusk", "Caelith", "Kaelyn", "Quillon", "Elowen" })
    local orinel = item(K("Orinel"), 1, "idea", "Whisper the crafter straight from the Atlas shopping list.",
        4 * DEMO_DAY, "Atlas › Shopping list", ctx("Shattrath City", "WARLOCK", "Destruction"), 13)
    votes(orinel, { "Aldrin", "Brakka", "Isolde", "Kaelyn", "Quillon" })
    status(orinel, dev, "planned", 3 * DEMO_DAY)
    local elowen = item(K("Elowen"), 2, "love", "The 3D strategy board is amazing. Our raid finally gets Vashj's phases!",
        5 * DEMO_DAY, "Raids › Strategy board", ctx("Serpentshrine Cavern", "HUNTER", "Beast Mastery"), 9)
    votes(elowen, { "Aldrin", "Caelith", "Isolde", "Orinel" })
    answer(elowen, dev, "That made my week. Thank you!", 4 * DEMO_DAY)
    local grim = item(K("Grimtusk"), 4, "bug", "The roll popup closed by itself when I entered combat, and I missed the "
        .. "roll on the Belt of Blasting.", 3 * DEMO_DAY, "Roll popup › Need",
        ctx("Serpentshrine Cavern · Lady Vashj", "ROGUE", "Combat"), 12, {
            e = { m = "Interface/AddOns/DisasterZone/UI/RollFrame.lua:412: attempt to index field 'session' (a nil value)",
                  s = "[string \"@Interface/AddOns/DisasterZone/UI/RollFrame.lua\"]:412: in function 'Refresh'\n"
                      .. "[string \"@Interface/AddOns/DisasterZone/UI/RollFrame.lua\"]:388: in function <...>",
                  n = 2, v = v } })
    votes(grim, { "me", "Orinel", "Kaelyn" })
    status(grim, dev, "planned", 2 * DEMO_DAY)
    answer(grim, dev, "Good catch! The popup will wait until you leave combat. It's in the next release.", 2 * DEMO_DAY)
    local paste = table.concat({
        "1x DisasterZone/UI/Members.lua:233: attempt to compare nil with number",
        "[string \"@Interface/AddOns/DisasterZone/UI/Members.lua\"]:233: in function 'SortRows'",
        "[string \"@Interface/AddOns/DisasterZone/UI/Members.lua\"]:301: in function 'Refresh'",
        "[string \"@Interface/AddOns/DisasterZone/UI/MainFrame.lua\"]:540: in function 'ShowTab'",
        "", "Locals:", "a = <table> {", "  name = \"Brakka\"", "  level = 70", "}", "b = <table> {",
        "  name = \"Newbie\"", "}", "(*temporary) = nil", "(*temporary) = 70",
        "(*temporary) = \"attempt to compare nil with number\"",
    }, "\n")
    item(K("Caelith"), 3, "bug", "Members tab throws an error when I sort by level.", 5400, "Guild › Members",
        ctx("Shattrath City", "MAGE", "Arcane"), 19, { e = { m = "1x DisasterZone/UI/Members.lua:233: attempt to "
            .. "compare nil with number", p = paste, v = v } })
    -- a Lua error that reported itself, and a me too from another member who hit it
    local report = table.concat({
        "3x DisasterZone/UI/RaidSheet.lua:1087: attempt to perform arithmetic on field 'expires' (a nil value)",
        "[string \"@Interface/AddOns/DisasterZone/UI/RaidSheet.lua\"]:1087: in function 'Refresh'",
        "[string \"@Interface/AddOns/DisasterZone/UI/RaidSheet.lua\"]:960: in function <...>",
        "", "What was going on:", "Window: open on raids", "In combat: no", "Group: raid of 25",
        "Instance: Black Temple (25 Player)", "Since login or /reload: 48 min", "Last steps (newest last):",
        "  6 min before: pull High Warlord Naj'entus", "  4 min before: High Warlord Naj'entus killed",
        "  2 min before: loot window", "  40 s before: page raids", "  3 s before: /dz raid",
        "", "Locals:", "self = <table> {", "}", "(*temporary) = nil",
        "", "Other addons (6): BugGrabber, BugSack, DBM-Core, Details, Questie, WeakAuras",
    }, "\n")
    local auto = item(K("Orinel"), 2, "bug", "Lua error: attempt to perform arithmetic on field 'expires' (a nil value)"
        .. "\n\nIt reported itself when it happened: Raids page open, in a raid of 25.", 2 * 3600, "UI/RaidSheet.lua:1087",
        ctx("Black Temple", "WARLOCK", "Destruction"), nil, { au = 1, e = { m = "Interface/AddOns/DisasterZone/UI/"
            .. "RaidSheet.lua:1087: attempt to perform arithmetic on field 'expires' (a nil value)", n = 3, p = report, v = v } })
    votes(auto, { "Grimtusk" })
    item(K("Brakka"), 1, "bug", "Atlas shows Sunwell items when I filter by phase 2.", 600, "Atlas",
        ctx("Ironforge", "WARRIOR", "Protection"), nil)
    local kaelyn = item(K("Kaelyn"), 2, "bug", "Gems on My BiS reset after a /reload.", 14 * DEMO_DAY, "My BiS › Gems",
        ctx("Shattrath City", "SHAMAN", "Restoration"), 8)
    votes(kaelyn, { "me", "Isolde" })
    status(kaelyn, dev, "done", 6 * DEMO_DAY, v)
    local mine = item(me, 1, "change", "The swing timer bar is too tall for 10-man raids. Could it be thinner?",
        6 * DEMO_DAY, "Swing timer", ctx("Karazhan", "PALADIN", "Retribution"), 16)
    votes(mine, { "Brakka", "Elowen" })
    status(mine, K("Caelith"), "exists", 5 * DEMO_DAY)
    answer(mine, K("Caelith"), "Settings > Swing timer has a Size option: a smaller size makes the bar thinner.",
        5 * DEMO_DAY)
    local quillon = item(K("Quillon"), 1, "idea", "An attendance chart for each member on the Members page.",
        21 * DEMO_DAY, "Members", ctx("Shattrath City", "DRUID", "Balance"), 11)
    votes(quillon, { "Aldrin" })
    status(quillon, dev, "notnow", 18 * DEMO_DAY)
    answer(quillon, dev, "Not now: attendance lives in the Raid log for the moment.", 18 * DEMO_DAY)
    local aldrin = item(K("Aldrin"), 1, "change", "Let officers move teams around on the raid calendar.",
        22 * DEMO_DAY, "Raids › Calendar", ctx("Shattrath City", "WARRIOR", "Arms"), 10)
    status(aldrin, dev, "done", 9 * DEMO_DAY, v)
    demoStore.seq[me] = 1
    return demoStore
end

-- Demo: "Tsumil has it" for an item I just sent, a moment later (as the developer's client would).
function Feedback:DemoNumber(id)
    if not (DemoOn() and demoStore and demoStore.r[id]) then return end
    demoStore.no = (demoStore.no or 18) + 1
    demoStore.r[id .. "="] = { k = "n", i = id, a = DEV_NAME .. "-" .. Util.GetPlayerRealm(), no = demoStore.no,
        rv = Now() }
    Changed()
end

-- For the harness and /dump.
function Feedback:Debug()
    return { records = CountRecords(), hashes = (Hashes()), errors = #errors, hook = Feedback.errorHook, reported = autoFiled }
end

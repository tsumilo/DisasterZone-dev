if CDLootBoot and CDLootBoot.Run("Core/Patch.lua", ...) then return end -- CDLoot: in-game updates. Downloads, verifies, stores and serves the patch that Core/Boot.lua applies.
--
-- A patch is published by one person (dev/tools/release.py signs it; /cdl publish announces it) and spreads over
-- the guild addon channel. Every client that holds it complete can serve it, so the publisher need not stay online.
--
-- Trust: only the signature counts. The manifest (version, target build, and for every file its length, Adler-32
-- and the SHA-256 of its encoded text) is signed with a hash-based one-time signature (W-OTS under a Merkle
-- tree, public key in Core/PatchKey.lua); a file is inflated only after its encoded text matched the signed
-- hash. Who sent a chunk does not matter, except that a sender whose data fails a check is ignored afterwards.
-- Manifest sequence numbers only go up: an older signed patch cannot be replayed over a newer one.
--
-- Wire (own prefixes, GUILD only, plain text; A and W on the control prefix, C on the three data prefixes):
--   A:<seq>:<build>:<n0>          "I hold patch <seq> for <build>" (seq 0: none; n0 is informational, nobody
--                                 relies on it: the manifest ends with its first chunk shorter than CHUNK, an
--                                 empty one if need be). Sent at login, when a patch
--                                 completes, and (after a random delay, once) to answer someone who is behind.
--   W:<seq>:<item>:<ranges>       "send me these chunks": item 0 = signature + manifest, item i = i-th file.
--   W:<seq>:m:<ranges>            whole files, by ranges of file numbers.   W:<seq>:all   every file.
--     ...!<name>,<name>           (suffix) "not from these": holders whose data failed my checks. They stay
--                                 silent for this request and re-check their copy; others do not wait for them.
--   C:<seq>:<item>:<idx>:<data>   one chunk (CHUNK bytes of the item's printable encoding, the last one shorter).
-- A holder answers W after a random delay unless it hears another holder's chunks first, so one client serves
-- and everybody who is downloading listens to the same stream.
local addonName, ns = ...

local Patch = ns:NewModule("Patch")
local Util = ns.Util
local Sha = ns.Sha256
local Boot = ns.Boot

local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local byte, char, sub, match, gmatch, lower = string.byte, string.char, string.sub, string.match, string.gmatch, string.lower
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local tconcat = table.concat

local AceComm = LibStub and LibStub("AceComm-3.0", true)
local LibDeflate = LibStub and LibStub("LibDeflate", true)
if AceComm then AceComm:Embed(Patch) end

-- Chunks never use the control prefix: the server allows each prefix 10 messages and then one per second, and a
-- stream that used up the control prefix's allowance would hold back the sender's own announcements (and, through
-- ChatThrottleLib's sharing between priorities, halve the stream).
local CONTROL = "CDLp1"
local DATA = { "CDLp2", "CDLp3", "CDLp4" }
local CHUNK = 236                    -- encoded bytes per chunk (dev/tools/patchlib.py CHUNK)
local SIG_CHAINS = 67                -- W-OTS chains (64 digest nibbles + 3 checksum nibbles)
local MAX_FILES = 300
local MAX_FILE_LEN = 1048576
local MAX_TOTAL_LEN = 4194304
local MAX_TOTAL_ZLEN = 1572864
local MAX_MANIFEST_LEN = 49152
local MAX_SIG_LEN = 4 + (SIG_CHAINS + 16) * 32
local MAX_Z0 = ceil((MAX_SIG_LEN + MAX_MANIFEST_LEN) * 4 / 3) + 8
local MAX_N0 = ceil(MAX_Z0 / CHUNK)
local MAX_EARLY_IDX = ceil(MAX_TOTAL_ZLEN / CHUNK)
local MAX_SEQ = 65535                -- the key signs at most 2^16 updates; larger numbers off the wire are noise

local IDLE = 4                       -- seconds without chunks before a downloader asks (again)
local WANT_GAP = 8                   -- base seconds between two rounds of requests
local MAX_INFLIGHT = 3               -- chunks handed to ChatThrottleLib and not sent yet
local BUCKET = 10                    -- server allowance per prefix: 10 messages, +1 per second
local MAX_FAILURES = 40              -- failed verifications before downloads stop for the session
local REANNOUNCE = 1800              -- seconds between two "this is what I have" messages

local PROTECTED = {                  -- never part of a patch
    ["Core/Boot.lua"] = true, ["Core/BuildInfo.lua"] = true, ["Core/BootEnd.lua"] = true, ["Core/Outbox.lua"] = true,
}

local held          -- the complete patch I can serve: { seq, base, version, z0, n0, z = { encoded text per item } }
local dl            -- the download in progress (NewDownload)
local candidates = {}   -- [seq] = true: announced for my build this session
local strikes = {}  -- [senderKey] = chunks that contradicted the signed manifest (3 = distrust)
local dead = {}     -- [seq] = true: announced but nobody served a valid manifest (or it is for another build)
local distrust = {} -- [senderKey] = true: sent data that failed verification
local flow = {}     -- [seq] = GetTime() of the last chunk heard from somebody else (whose data I do not distrust)
local flowFrom = {} -- [seq] = who sent it
local excluded = {} -- [senderKey] = GetTime() a downloader last named this holder as sending bad data
local distrustList = {}   -- distrust, in the order it was found (the newest names go into my requests)
local selfChecked = false
local heardAnnounce = {}   -- [base] = { seq =, at = }: newest announce heard (suppresses my own answer)
local wantLog = {}  -- [senderKey] = { GetTime() of recent W messages }
local heardWant = {}   -- [seq .. ":all" | seq .. ":0:*"] = GetTime() somebody else asked for exactly that
local lastNudge = -1000
local failures = 0
local inEncounter = false
local publishedHere = false

Patch.ready = nil   -- { seq =, version = } once a patch newer than the running one is stored (reload applies it)

local function DB()
    return Boot.DB()
end

local function Key()
    local k = ns.PatchKey
    if type(k) ~= "table" or type(k.seed) ~= "string" or #k.seed ~= 32 or type(k.root) ~= "string" or #k.root ~= 64
        or type(k.h) ~= "number" or k.h < 1 or k.h > 16 or k.h ~= floor(k.h) then
        return nil
    end
    return k
end

local function Available()
    return Boot ~= nil and Sha ~= nil and AceComm ~= nil and LibDeflate ~= nil and Key() ~= nil
end

-- Own jitter source: the delays below only need to differ between clients, and drawing them from math.random
-- would shift the random sequence every other module (and its tests) sees.
local randState

local function Rand()
    if not randState then
        randState = (Boot.Adler32(tostring(Util.PlayerKey())) + floor(GetTime() * 1000)) % 2147483648
    end
    randState = (randState * 1103515245 + 12345) % 2147483648
    return randState / 2147483648
end

local function RandomDelay(minSec, maxSec, fn)
    Util.After(minSec + Rand() * (maxSec - minSec), fn)
end

local function Changed()
    Util.Debounce("patch-updated", 0.2, function() ns:Fire("PATCH_UPDATED") end)
end

---------------------------------------------------------------------------
-- Background jobs: one at a time, spread over frames, never during combat
---------------------------------------------------------------------------

local jobs = {}          -- queue of functions
local jobRunning = false
local sliceStart = 0

-- Called from inside a job at safe points: yields when the frame's time slice is used up.
local function Breathe()
    if Patch.forceYield or debugprofilestop() - sliceStart > 8 then
        coroutine.yield()
    end
end

local RunNextJob

local function StepJob(co)
    if InCombatLockdown and InCombatLockdown() then
        Util.After(2, function() StepJob(co) end)
        return
    end
    sliceStart = debugprofilestop()
    local ok, err = coroutine.resume(co)
    if not ok then
        local handler = geterrorhandler and geterrorhandler()
        if handler then handler(err) end
    end
    if ok and coroutine.status(co) ~= "dead" then
        Util.After(0, function() StepJob(co) end)
    else
        jobRunning = false
        RunNextJob()
    end
end

RunNextJob = function()
    if jobRunning then return end
    local fn = table.remove(jobs, 1)
    if not fn then return end
    jobRunning = true
    StepJob(coroutine.create(fn))
end

local function Job(fn)
    jobs[#jobs + 1] = fn
    RunNextJob()
end

---------------------------------------------------------------------------
-- Signature (W-OTS + Merkle; dev/tools/patchlib.py is the signing side)
---------------------------------------------------------------------------

local function U32(n)
    return char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

-- Returns the leaf (= sequence number) the signature was made with, or nil when it does not verify.
local function VerifySignature(message, sig, key, breathe)
    local seed = Sha.FromHex(key.seed)
    local h = key.h
    if not seed or #sig ~= 4 + (SIG_CHAINS + h) * 32 then return nil end
    local l1, l2, l3, l4 = byte(sig, 1, 4)
    local leaf = ((l1 * 256 + l2) * 256 + l3) * 256 + l4
    if leaf >= 2 ^ h then return nil end
    local leafBytes = sub(sig, 1, 4)

    local digest = Sha.Sum(seed .. "M" .. leafBytes .. message)
    local digits = {}
    local csum = 0
    for i = 1, 32 do
        local b = byte(digest, i)
        local hi, lo = floor(b / 16), b % 16
        digits[2 * i - 1], digits[2 * i] = hi, lo
        csum = csum + (15 - hi) + (15 - lo)
    end
    digits[65], digits[66], digits[67] = floor(csum / 256) % 16, floor(csum / 16) % 16, csum % 16

    local st = Sha.New()
    Sha.Update(st, seed .. "L" .. leafBytes)
    local head = seed .. "C" .. leafBytes
    for c = 0, SIG_CHAINS - 1 do
        local x = sub(sig, 5 + c * 32, 4 + (c + 1) * 32)
        local chainHead = head .. char(c)
        for step = digits[c + 1], 14 do
            x = Sha.Sum(chainHead .. char(step) .. x)
        end
        Sha.Update(st, x)
        if breathe then breathe() end
    end
    local node = Sha.Final(st)

    local idx = leaf
    local off = 4 + SIG_CHAINS * 32
    for height = 1, h do
        local sibling = sub(sig, off + (height - 1) * 32 + 1, off + height * 32)
        local parent = floor(idx / 2)
        local nodeHead = seed .. "N" .. char(height) .. U32(parent)
        if idx % 2 == 1 then
            node = Sha.Sum(nodeHead .. sibling .. node)
        else
            node = Sha.Sum(nodeHead .. node .. sibling)
        end
        idx = parent
    end
    if Sha.Hex(node) ~= lower(key.root) then return nil end
    return leaf
end
Patch.VerifySignature = VerifySignature   -- (tests)

---------------------------------------------------------------------------
-- Manifest
---------------------------------------------------------------------------

local function ValidPath(path)
    if type(path) ~= "string" or #path > 100 or not match(path, "^[%w_%-/]+%.lua$") then return false end
    if match(path, "^/") or path:find("//", 1, true) then return false end
    if PROTECTED[path] or match(path, "^Libs/") then return false end
    return true
end

local function Int(s, limit)
    if type(s) ~= "string" or not match(s, "^%d+$") or #s > 12 then return nil end
    local n = tonumber(s)
    if not n or (limit and n > limit) then return nil end
    return n
end

-- Parses and validates signed manifest text. Returns the manifest or nil, reason.
--   { seq, version, base, pack, entries = { { k, p, len, adler, zlen, zsha, b, n } ... }, items = { F/N entries } }
local function ParseManifest(text)
    if type(text) ~= "string" or #text > MAX_MANIFEST_LEN then return nil, "size" end
    if sub(text, -1) ~= "\n" then return nil, "format" end
    local lines = {}
    for line in gmatch(text, "([^\n]*)\n") do lines[#lines + 1] = line end
    if lines[1] ~= "CDLP1" or #lines < 5 then return nil, "format" end
    local m = { entries = {}, items = {} }
    m.seq = Int(match(lines[2], "^seq=(%d+)$"), 2147483647)
    m.version = match(lines[3], "^version=([%w%.%-]+)$")
    m.base = match(lines[4], "^base=(%w+)$")
    m.pack = Int(match(lines[5], "^pack=(%d+)$"), 1000000)
    if not m.seq or m.seq < 1 or not m.version or #m.version > 24 or not m.base or #m.base > 32 or not m.pack then
        return nil, "header"
    end
    if #lines - 5 > MAX_FILES then return nil, "too many files" end
    local seen = {}
    local total, ztotal = 0, 0
    for i = 6, #lines do
        local f = {}
        for field in gmatch(lines[i] .. "\t", "([^\t]*)\t") do f[#f + 1] = field end
        local kind, path = f[1], f[2]
        if not ValidPath(path) or seen[path] then return nil, "path" end
        seen[path] = true
        local e = { k = kind, p = path }
        if kind == "D" then
            if #f ~= 2 then return nil, "entry" end
        elseif kind == "F" or kind == "N" then
            if #f ~= (kind == "N" and 7 or 6) then return nil, "entry" end
            e.len = Int(f[3], MAX_FILE_LEN)
            e.adler = Int(f[4], 4294967295)
            e.zlen = Int(f[5], MAX_TOTAL_ZLEN)
            e.zsha = f[6]
            if not e.len or not e.adler or not e.zlen or e.zlen < 1 or #e.zsha ~= 64 or e.zsha:find("[^0-9a-f]") then
                return nil, "entry"
            end
            if kind == "N" then
                e.b = f[7]
                if e.b ~= "" and not ValidPath(e.b) then return nil, "slot" end
            end
            e.n = ceil(e.zlen / CHUNK)
            total = total + e.len
            ztotal = ztotal + e.zlen
            m.items[#m.items + 1] = e
        else
            return nil, "entry"
        end
        m.entries[#m.entries + 1] = e
    end
    if total > MAX_TOTAL_LEN or ztotal > MAX_TOTAL_ZLEN then return nil, "too large" end
    m.total, m.ztotal = total, ztotal
    return m
end
Patch.ParseManifest = ParseManifest   -- (tests)
function Patch._dl() return dl end    -- (tests) the download in progress

-- Job step: decodes item 0 (signature + manifest), checks the signature and parses. Returns manifest or nil, reason.
local function CheckManifestBlob(z0)
    local key = Key()
    if not key then return nil, "no key" end
    if type(z0) ~= "string" or #z0 > MAX_Z0 then return nil, "size" end
    local raw = LibDeflate:DecodeForPrint(z0)
    local sigLen = 4 + (SIG_CHAINS + key.h) * 32
    if not raw or #raw <= sigLen then return nil, "encoding" end
    local sig, text = sub(raw, 1, sigLen), sub(raw, sigLen + 1)
    local leaf = VerifySignature(text, sig, key, Breathe)
    if not leaf then return nil, "signature" end
    local m, why = ParseManifest(text)
    if not m then return nil, "manifest " .. tostring(why) end
    if m.seq ~= leaf then return nil, "sequence" end
    return m
end

-- Job step: checks one file's encoded text against the manifest and inflates it. Returns the source or nil.
local function CheckItem(entry, z)
    if type(z) ~= "string" or #z ~= entry.zlen then return nil end
    local st = Sha.New()
    for pos = 1, #z, 4096 do
        Sha.Update(st, sub(z, pos, pos + 4095))
        Breathe()
    end
    if Sha.Hex(Sha.Final(st)) ~= entry.zsha then return nil end
    local raw = LibDeflate:DecodeForPrint(z)
    if not raw then return nil end
    Breathe()
    local src = LibDeflate:DecompressDeflate(raw)
    if type(src) ~= "string" or #src ~= entry.len or Boot.Adler32(src) ~= entry.adler then return nil end
    Breathe()
    return src
end

---------------------------------------------------------------------------
-- Stored patch
---------------------------------------------------------------------------

local StopServing   -- (defined with the serving code)
local sentAt = {}   -- [chunk key] = GetTime() it was last sent (chunks of the patch held now)

local function HeldSeq()
    return held and held.seq or 0
end

local function Floor()
    return tonumber(DB().seq) or 0
end

local function IsBad(seq)
    local bad = DB().bad
    return type(bad) == "table" and bad[seq] ~= nil
end

-- The serving view of a stored patch, or nil when the record is not complete.
local function BuildHeld(p)
    if type(p) ~= "table" or type(p.seq) ~= "number" or type(p.base) ~= "string" or type(p.z0) ~= "string"
        or type(p.z) ~= "table" or type(p.list) ~= "table" then
        return nil
    end
    local files = 0
    for _, e in ipairs(p.list) do
        if type(e) == "table" and e.k ~= "D" then files = files + 1 end
    end
    if #p.z ~= files then return nil end
    for i = 1, files do
        if type(p.z[i]) ~= "string" or p.z[i] == "" then return nil end
    end
    -- n0: chunks of the manifest item. Its last chunk is always shorter than CHUNK (possibly empty), which is
    -- how a downloader recognises the end without trusting anybody's count.
    return { seq = p.seq, base = p.base, version = p.version, z0 = p.z0, n0 = floor(#p.z0 / CHUNK) + 1, z = p.z }
end

local function UpdateReady()
    local p = DB().active
    local applied = Boot.applied
    Patch.ready = nil
    if type(p) == "table" and p.base == Boot.buildId and not Boot.isDev and not IsBad(p.seq)
        and not (applied and applied.seq == p.seq) and not DB().off and Boot.svFirst ~= false then
        Patch.ready = { seq = p.seq, version = p.version }
    end
end

-- Stores a fully verified patch: it applies from the next load on, and I can serve it.
local function Stage(m, z0, zs, srcs)
    local files, sums, list = {}, {}, {}
    local i = 0
    for _, e in ipairs(m.entries) do
        if e.k == "D" then
            list[#list + 1] = { k = "D", p = e.p }
        else
            i = i + 1
            files[e.p] = srcs[i]
            sums[e.p] = e.adler
            list[#list + 1] = { k = e.k, p = e.p, b = (e.k == "N") and e.b or nil }
        end
    end
    local z = {}
    for j = 1, i do z[j] = zs[j] end
    local db = DB()
    db.active = { seq = m.seq, version = m.version, base = m.base, pack = m.pack, z0 = z0,
                  files = files, sums = sums, list = list, z = z }
    db.partial = nil
    if m.seq > (tonumber(db.seq) or 0) then db.seq = m.seq end
    failures = 0
    StopServing()                  -- the queue refers to the patch held until now
    sentAt = {}
    held = BuildHeld(db.active)
    UpdateReady()
    Changed()
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function CanTalk()
    return ns.loggedIn and Available() and IsInGuild and IsInGuild() and not DB().off
end

local function SendControl(text)
    if not CanTalk() then return false end
    Patch:SendCommMessage(CONTROL, text, "GUILD", nil, "NORMAL")
    return true
end

local function SendAnnounce()
    local seq, base, n0 = 0, Boot.buildId, 0
    if held then seq, base, n0 = held.seq, held.base, held.n0 end
    SendControl("A:" .. seq .. ":" .. base .. ":" .. n0)
end

local announcePending = false

-- Tells the guild what I hold, after a random delay, unless somebody else said the same (or newer) meanwhile.
local function ScheduleAnnounce(minSec, maxSec)
    if announcePending or not held then return end
    announcePending = true
    RandomDelay(minSec, maxSec, function()
        announcePending = false
        if not held then return end
        local heard = heardAnnounce[held.base]
        if heard and heard.seq >= held.seq and GetTime() - heard.at < 8 then return end
        SendAnnounce()
    end)
end

---------------------------------------------------------------------------
-- Serving
---------------------------------------------------------------------------

-- Two FIFO queues of chunk keys (item * 65536 + idx): [1] manifest chunks, served first because a downloader
-- can only place file chunks once it has the manifest; [2] file chunks.
local queues, inQueue
local serving = false
local electionPending = false
local inFlight = 0
local tokens, tokenTime = {}, {}
local pumpRetryPending = false
local lastSend = 0       -- GetTime() of the last chunk handed to the send queue
local RESEND_GAP = 3     -- a request for a chunk sent less than this long ago is an echo of the same round, not a
                         -- loss: downloaders only ask again after IDLE seconds of silence

local function CanSeed()
    return held ~= nil and CanTalk() and not inEncounter and not (InCombatLockdown and InCombatLockdown())
end

local function Excluded(senderKey)
    local t = excluded[senderKey]
    return t ~= nil and GetTime() - t < 60
end

-- True while another holder is serving `seq` (one whose data nobody just complained about).
local function FlowActive(seq)
    local t = flow[seq]
    return t ~= nil and GetTime() - t < 3 and not Excluded(flowFrom[seq])
end

local function ClearQueue()
    queues = { { list = {}, head = 1, tail = 0 }, { list = {}, head = 1, tail = 0 } }
    inQueue = {}
end
ClearQueue()

local function QueueEmpty()
    return queues[1].head > queues[1].tail and queues[2].head > queues[2].tail
end

local function Push(key)
    local q = queues[(key < 65536) and 1 or 2]
    q.tail = q.tail + 1
    q.list[q.tail] = key
    inQueue[key] = true
end

local function Pop()
    for i = 1, 2 do
        local q = queues[i]
        if q.head <= q.tail then
            local key = q.list[q.head]
            q.list[q.head] = nil
            q.head = q.head + 1
            inQueue[key] = nil
            return key
        end
    end
end

StopServing = function()
    serving = false
    ClearQueue()
end

local function TakeToken()
    local now = GetTime()
    for i = 1, #DATA do
        local t = tokens[i] or BUCKET
        local last = tokenTime[i] or now
        t = min(BUCKET, t + (now - last))
        tokenTime[i] = now
        if t >= 1 then
            tokens[i] = t - 1
            return i
        end
        tokens[i] = t
    end
    return nil
end

local Pump

local function OnChunkSent()
    inFlight = max(0, inFlight - 1)
    Pump()
end

Pump = function()
    if not serving then return end
    if not CanSeed() then
        StopServing()
        return
    end
    while inFlight < MAX_INFLIGHT and not QueueEmpty() do
        local pi = TakeToken()
        if not pi then
            if not pumpRetryPending then
                pumpRetryPending = true
                Util.After(0.25, function()
                    pumpRetryPending = false
                    Pump()
                end)
            end
            return
        end
        local key = Pop()
        local item, idx = floor(key / 65536), key % 65536
        local blob = (item == 0) and held.z0 or held.z[item]
        if blob then
            local data = sub(blob, (idx - 1) * CHUNK + 1, idx * CHUNK)
            if data ~= "" or (item == 0 and idx == held.n0) then
                lastSend = GetTime()
                sentAt[key] = lastSend
                inFlight = inFlight + 1
                Patch:SendCommMessage(DATA[pi], "C:" .. held.seq .. ":" .. item .. ":" .. idx .. ":" .. data,
                    "GUILD", nil, "BULK", OnChunkSent)
            end
        end
    end
    if QueueEmpty() and inFlight == 0 then
        StopServing()
    end
end

local function Enqueue(item, first, last)
    local blob = (item == 0) and held.z0 or held.z[item]
    if not blob then return end
    local n = (item == 0) and held.n0 or ceil(#blob / CHUNK)
    first, last = max(1, first), min(n, last)
    local now = GetTime()
    for idx = first, last do
        local key = item * 65536 + idx
        local sent = sentAt[key]
        if not inQueue[key] and not (sent and now - sent < RESEND_GAP) then
            Push(key)
        end
    end
end

local function Elect()
    electionPending = false
    if serving or QueueEmpty() then return end
    if not CanSeed() or FlowActive(held.seq) then
        ClearQueue()
        return
    end
    serving = true
    Pump()
end

local SelfCheck   -- (defined below)

local function OnWant(senderKey, seq, spec, ranges, notFrom)
    if not held or held.seq ~= seq or not CanSeed() then return end
    if notFrom and notFrom ~= "" then
        local me = Util.PlayerKey()
        local named = false
        local n = 0
        for name in gmatch(notFrom, "[^,]+") do
            n = n + 1
            if n > 3 then break end
            local key = Util.NormalizeName(name)
            if key then
                excluded[key] = GetTime()
                if key == me then named = true end
            end
        end
        if named then
            if serving then StopServing() end
            SelfCheck()                -- a downloader says my data failed its checks: look at my copy
            return
        end
    end
    -- a single sender may not keep everybody serving: 6 requests per 10 seconds
    local now = GetTime()
    local log = wantLog[senderKey]
    if not log then log = {}; wantLog[senderKey] = log end
    while log[1] and now - log[1] > 10 do table.remove(log, 1) end
    if #log >= 6 then return end
    log[#log + 1] = now

    local function EachRange(text, fn)
        for part in gmatch(text, "[^,]+") do
            local a, b = match(part, "^(%d+)%-(%d+)$")
            if not a then a = match(part, "^(%d+)$"); b = a end
            a, b = tonumber(a), tonumber(b)
            if a and b and b >= a and b - a < 65535 then fn(a, b) end
        end
    end
    if spec == "all" then
        for item = 1, #held.z do Enqueue(item, 1, 65535) end
    elseif spec == "m" then              -- whole files, by ranges of file numbers
        EachRange(ranges or "", function(a, b)
            for item = max(1, a), min(#held.z, b) do Enqueue(item, 1, 65535) end
        end)
    else
        local item = tonumber(spec)
        if not item or item < 0 or item > #held.z then return end
        if ranges == "*" then
            Enqueue(item, 1, 65535)
        elseif type(ranges) == "string" then
            EachRange(ranges, function(a, b) Enqueue(item, a, b) end)
        end
    end
    if serving and now - lastSend > 20 then
        inFlight = 0               -- the send queue never reported back (left the guild, disconnected ...)
        serving = false
    end
    if serving then
        Pump()
        return
    end
    if FlowActive(seq) then      -- another holder is serving and heard the same request
        ClearQueue()
        return
    end
    if not electionPending and not QueueEmpty() then
        electionPending = true
        local lo, hi = 0.5, 3.0
        if publishedHere then
            lo, hi = 0.1, 0.4
        elseif IsInInstance and IsInInstance() then
            lo, hi = 3.0, 5.5
        end
        RandomDelay(lo, hi, Elect)
    end
end

---------------------------------------------------------------------------
-- Downloading
---------------------------------------------------------------------------

local function CanDownload()
    return CanTalk() and not Boot.isDev and Boot.svFirst ~= false and failures < MAX_FAILURES
end

-- n = number of chunks; nil for the manifest until its last (short) chunk has been seen. top = highest index held.
local function NewSlot(n)
    return { n = n, fixed = n ~= nil, got = {}, have = 0, top = 0, from = {}, state = "open" }
end

local function ResetSlot(slot)
    slot.got, slot.have, slot.top, slot.from, slot.state = {}, 0, 0, {}, "open"
    if not slot.fixed then slot.n = nil end
end

local function Distrust(senderKey)
    if not distrust[senderKey] then distrustList[#distrustList + 1] = senderKey end
    distrust[senderKey] = true
end

-- A slot's data failed verification: with one contributor that sender is ignored from now on; with several,
-- the slot is refilled from one sender at a time until the bad one is found.
local function Blame(slot)
    failures = failures + 1
    local n, only = 0, nil
    for key in pairs(slot.from) do n = n + 1; only = key end
    if n == 1 then
        Distrust(only)
        slot.pinned = nil
    else
        slot.pin = true
    end
    ResetSlot(slot)
end

local tickPending = false
local Tick

-- (the first tick of a download comes after a random part of a second, so clients are not in step)
local function ScheduleTick(delay)
    if tickPending then return end
    tickPending = true
    Util.After(delay or 1, function()
        tickPending = false
        Tick()
    end)
end

local StartDownload   -- (defined below: needs the verification steps)

local VerifyManifestJob, VerifyItemJob   -- (defined below)

local function NewDownload(seq)
    dl = {
        seq = seq,
        items = { [0] = NewSlot(nil) },
        m = nil, z0 = nil, z = {}, src = {}, done = 0,
        early = {}, earlyBytes = 0,      -- file chunks heard before the manifest: [item][idx] = { data, sender }
        last0 = nil,                     -- GetTime() of the last manifest chunk taken
        nextWant = GetTime() + 0.5 + Rand() * 2,
        stale = 0, asked = false, progress = false,
    }
    ScheduleTick(Rand())
    Changed()
end

local function PickCandidate()
    if dl or not CanDownload() then return end
    local best
    for seq in pairs(candidates) do
        if seq > HeldSeq() and seq >= Floor() and not dead[seq] and not IsBad(seq) and (not best or seq > best) then
            best = seq
        end
    end
    if best then StartDownload(best) end
end

local function AbandonDownload(markDead)
    if not dl then return end
    if markDead then dead[dl.seq] = true end
    dl = nil
    Changed()
    PickCandidate()
end

local function SavePartial()
    local db = DB()
    db.partial = { seq = dl.seq, base = dl.m.base, z0 = dl.z0, z = dl.z, src = dl.src }
end

local function FinishIfComplete(mine)
    if dl ~= mine or not mine.m or mine.done < #mine.m.items then return end
    local zs, srcs = {}, {}
    for i = 1, #mine.m.items do zs[i], srcs[i] = mine.z[i], mine.src[i] end
    dl = nil
    Stage(mine.m, mine.z0, zs, srcs)
    if Patch.ready then
        ns:Print("update %s is downloaded. Reload the interface (/reload) to use it.", tostring(mine.m.version))
    end
    ScheduleAnnounce(1, 5)
end

-- Puts one chunk into its slot when it belongs there; starts the verification when the slot is full.
-- Returns true when the chunk was taken; false, true when it contradicts what is known about the slot.
local function Place(mine, item, idx, data, senderKey)
    local slot = mine.items[item]
    if not slot or slot.state ~= "open" or idx < 1 then return false end
    if slot.got[idx] then return false end
    if slot.pin and slot.pinned and slot.pinned ~= senderKey then return false end
    if item == 0 then
        -- The manifest's length is not known beforehand: its last chunk is the one shorter than CHUNK.
        if idx > MAX_N0 then return false, true end
        if #data < CHUNK then
            if slot.n or idx < slot.top then return false, true end    -- a second end, or an end below a held chunk
            slot.n = idx
        elseif slot.n and idx > slot.n then
            return false, true                                         -- a chunk beyond the end
        end
    else
        if idx > slot.n then return false, true end
        local expect = CHUNK
        if idx == slot.n then expect = mine.m.items[item].zlen - (slot.n - 1) * CHUNK end
        if #data ~= expect then return false, true end
    end
    if slot.pin and not slot.pinned then slot.pinned = senderKey end
    slot.got[idx] = data
    slot.have = slot.have + 1
    if idx > slot.top then slot.top = idx end
    slot.from[senderKey] = true
    if slot.n and slot.have == slot.n then
        slot.state = "verifying"
        if item == 0 then
            Job(function() VerifyManifestJob(mine) end)
        else
            Job(function() VerifyItemJob(mine, item) end)
        end
    end
    return true
end

-- A chunk that cannot be right. For a file (length and count are in the signed manifest) the sender is at fault:
-- three of those and it is ignored. For the manifest the fault may lie with an earlier chunk: the slot starts over
-- the way a failed verification does.
local function Contradiction(mine, item, senderKey)
    if item == 0 then
        local slot = mine.items[0]
        slot.from[senderKey] = true
        Blame(slot)
    else
        strikes[senderKey] = (strikes[senderKey] or 0) + 1
        if strikes[senderKey] >= 3 then Distrust(senderKey) end
    end
end

-- The manifest of download `mine` verified: set up the file slots, reusing what an earlier session stored.
local function AdoptManifest(mine, m, z0)
    mine.m, mine.z0 = m, z0
    mine.items[0].state = "done"
    local db = DB()
    if m.seq > (tonumber(db.seq) or 0) then db.seq = m.seq end
    local old = db.partial
    local reuse = type(old) == "table" and old.seq == m.seq and type(old.z) == "table" and type(old.src) == "table"
    for i, e in ipairs(m.items) do
        local slot = NewSlot(e.n)
        mine.items[i] = slot
        if reuse and type(old.z[i]) == "string" and #old.z[i] == e.zlen and type(old.src[i]) == "string"
            and #old.src[i] == e.len and Boot.Adler32(old.src[i]) == e.adler then
            slot.state = "done"
            mine.z[i], mine.src[i] = old.z[i], old.src[i]
            mine.done = mine.done + 1
        end
    end
    -- file chunks that were overheard while the manifest was still on its way
    local early = mine.early
    mine.early, mine.earlyBytes = {}, 0
    for item, chunks in pairs(early) do
        for idx, c in pairs(chunks) do
            if not distrust[c[2]] then
                local ok, wrong = Place(mine, item, idx, c[1], c[2])
                if ok then
                    mine.progress = true
                elseif wrong then
                    Contradiction(mine, item, c[2])
                end
            end
        end
    end
    SavePartial()
    Changed()
end

VerifyManifestJob = function(mine)
    local slot = mine.items[0]
    local z0 = tconcat(slot.got, "", 1, slot.n)
    local m, why = CheckManifestBlob(z0)
    if dl ~= mine then return end
    if m and m.seq ~= mine.seq then m, why = nil, "sequence" end
    if not m then
        ns:Debug("Patch: manifest #%s rejected (%s)", tostring(mine.seq), tostring(why))
        Blame(slot)
        return
    end
    if m.base ~= Boot.buildId or m.seq < Floor() then
        AbandonDownload(true)      -- genuine, but not for this build (or older than what I already saw)
        return
    end
    AdoptManifest(mine, m, z0)
    FinishIfComplete(mine)
end

VerifyItemJob = function(mine, i)
    local slot = mine.items[i]
    local entry = mine.m.items[i]
    local z = tconcat(slot.got, "", 1, slot.n)
    local src = CheckItem(entry, z)
    if dl ~= mine then return end
    if not src then
        ns:Debug("Patch: %s failed verification", tostring(entry.p))
        Blame(slot)
        return
    end
    slot.state = "done"
    slot.got = {}
    mine.z[i], mine.src[i] = z, src
    mine.done = mine.done + 1
    SavePartial()
    Changed()
    FinishIfComplete(mine)
end

-- Starts downloading patch `seq`. When an earlier attempt already stored its manifest (and maybe some files),
-- that is checked again and reused, and only the missing files are asked for.
StartDownload = function(seq)
    local part = DB().partial
    if type(part) == "table" and part.seq == seq and type(part.z0) == "string" then
        local z0 = part.z0
        NewDownload(seq)
        local mine = dl
        mine.items[0].state = "verifying"
        Job(function()
            local m = CheckManifestBlob(z0)
            if dl ~= mine then return end
            if not m or m.seq ~= mine.seq or m.base ~= Boot.buildId then
                DB().partial = nil
                -- damaged store: fetch it again from the guild; a manifest for another build is of no use
                AbandonDownload(m ~= nil and m.seq == mine.seq)
                return
            end
            AdoptManifest(mine, m, z0)
            FinishIfComplete(mine)
        end)
    else
        NewDownload(seq)
    end
end

-- Somebody is sending or asking for a patch newer than anything I know of: say what I have now (instead of
-- at the usual login delay), so a holder tells me about it.
local function Nudge(seq)
    if dl or seq <= HeldSeq() or candidates[seq] or dead[seq] or not CanDownload() then return end
    local now = GetTime()
    if now - lastNudge < 30 then return end
    lastNudge = now
    RandomDelay(0.2, 1.5, function()
        if not dl then SendAnnounce() end
    end)
end

local function OnChunk(senderKey, seq, item, idx, data)
    if not distrust[senderKey] then
        flow[seq], flowFrom[seq] = GetTime(), senderKey
    end
    if serving and held and held.seq == seq and senderKey < Util.PlayerKey() and not Excluded(senderKey) then
        StopServing()              -- two holders answered at once: the lower name keeps serving
    end
    local mine = dl
    if not mine then
        Nudge(seq)
        return
    end
    if mine.seq ~= seq or distrust[senderKey] then return end
    if #data > CHUNK or (#data < 1 and item ~= 0) or data:find("[^%w%(%)]") then return end
    if item >= 1 and not mine.m then
        -- A file chunk, but the manifest is not here yet (I joined while a stream was running): keep it, within
        -- the size an update may have, and sort it in once the manifest says what it is.
        if item > MAX_FILES or idx < 1 or idx > MAX_EARLY_IDX then return end
        local chunks = mine.early[item]
        if not chunks then chunks = {}; mine.early[item] = chunks end
        if chunks[idx] or mine.earlyBytes + #data > MAX_TOTAL_ZLEN then return end
        chunks[idx] = { data, senderKey }
        mine.earlyBytes = mine.earlyBytes + #data
        return
    end
    local ok, wrong = Place(mine, item, idx, data, senderKey)
    if ok then
        if item == 0 then mine.last0 = GetTime() end
        mine.progress = true
        Changed()
    elseif wrong then
        Contradiction(mine, item, senderKey)
    end
end

-- "3-7,9,12-40" for the chunks a slot still lacks ("*" when it has none), cut to fit one message. While the
-- end of the manifest is unknown, everything above the highest chunk held is asked for as well.
local function MissingRanges(slot)
    if slot.have == 0 then return "*" end
    local parts, len = {}, 0
    local last = slot.n or slot.top
    local idx = 1
    while idx <= last do
        if slot.got[idx] then
            idx = idx + 1
        else
            local stop = idx
            while stop < last and not slot.got[stop + 1] do stop = stop + 1 end
            local part = (stop == idx) and tostring(idx) or (idx .. "-" .. stop)
            if len + #part + 1 > 170 then break end
            parts[#parts + 1] = part
            len = len + #part + 1
            idx = stop + 1
        end
    end
    if not slot.n then parts[#parts + 1] = (slot.top + 1) .. "-" .. MAX_N0 end
    return tconcat(parts, ",")
end

-- "1-4,9" for a sorted list of numbers, cut to fit one message.
local function IndexRanges(list)
    local parts, len = {}, 0
    local i = 1
    while i <= #list do
        local j = i
        while j < #list and list[j + 1] == list[j] + 1 do j = j + 1 end
        local part = (j == i) and tostring(list[i]) or (list[i] .. "-" .. list[j])
        if len + #part + 1 > 180 then break end
        parts[#parts + 1] = part
        len = len + #part + 1
        i = j + 1
    end
    return tconcat(parts, ",")
end

-- True when somebody else asked for exactly `what` a moment ago: the answer is already on its way to everybody.
local function AskedByOthers(seq, what)
    local t = heardWant[seq .. ":" .. what]
    return t ~= nil and GetTime() - t < 6
end

-- "!Name-Realm,Name-Realm": the (up to three, newest) holders whose data failed my checks; "" when there are none.
local function NotFromSuffix()
    local n = #distrustList
    if n == 0 then return "" end
    local names = {}
    for i = n, max(1, n - 2), -1 do names[#names + 1] = distrustList[i] end
    return "!" .. tconcat(names, ",")
end

-- Asks for what is still missing. Returns the number of requests made (or left to somebody else's identical one).
local function SendWants()
    local mine = dl
    local head = "W:" .. mine.seq .. ":"
    local tail = NotFromSuffix()
    local function Ask(what)
        local text = head .. what .. tail
        if #text > 250 then text = head .. what end
        SendControl(text)
    end
    if not mine.m then
        local slot = mine.items[0]
        if slot.state ~= "open" then return 0 end
        local what = "0:" .. MissingRanges(slot)
        if not (what == "0:*" and tail == "" and AskedByOthers(mine.seq, what)) then
            Ask(what)
        end
        return 1
    end
    -- files nothing has arrived of go into one request by file number; partly received files get one each
    local whole, partial = {}, {}
    for i = 1, #mine.m.items do
        local slot = mine.items[i]
        if slot.state == "open" then
            if slot.have == 0 then whole[#whole + 1] = i else partial[#partial + 1] = i end
        end
    end
    if #whole + #partial == 0 then return 0 end
    if #whole == #mine.m.items then
        if not (tail == "" and AskedByOthers(mine.seq, "all")) then Ask("all") end
        return 1
    end
    local sent = 0
    if #whole > 0 then
        Ask("m:" .. IndexRanges(whole))
        sent = 1
    end
    for _, i in ipairs(partial) do
        if sent >= 4 then break end
        Ask(i .. ":" .. MissingRanges(mine.items[i]))
        sent = sent + 1
    end
    return sent
end

Tick = function()
    local mine = dl
    if not mine then return end
    if not CanDownload() then
        dl = nil
        Changed()
        return
    end
    local now = GetTime()
    -- Files: ask once the stream has been silent for a moment (what is streaming may be what I lack).
    -- The manifest is never part of a file stream, so it is asked for even while one is running.
    local quiet
    if mine.m then
        quiet = now - (flow[mine.seq] or -1000) >= IDLE
    else
        quiet = now - (mine.last0 or -1000) >= IDLE
    end
    if quiet and now >= mine.nextWant then
        if mine.asked and not mine.progress then
            mine.stale = mine.stale + 1
        elseif mine.progress then
            mine.stale = 0
        end
        if not mine.m and mine.stale >= 3 then
            AbandonDownload(true)      -- announced, but nobody serves it
            return
        end
        if SendWants() > 0 then
            mine.asked = true
            mine.progress = false
        end
        mine.nextWant = now + min(300, WANT_GAP * 2 ^ mine.stale) + Rand() * 3
    end
    ScheduleTick()
end

local function OnAnnounce(senderKey, seq, base, n0)
    local heard = heardAnnounce[base]
    if not heard or seq >= heard.seq then
        heardAnnounce[base] = { seq = seq, at = GetTime() }
    end
    if held and held.base == base and held.seq > seq then
        ScheduleAnnounce(1, 6)         -- they are behind: tell them (once, whoever is first)
        return
    end
    if base ~= Boot.buildId or not CanDownload() then return end
    if seq <= HeldSeq() or seq < Floor() or dead[seq] or IsBad(seq) then return end
    candidates[seq] = true
    if dl then
        if seq <= dl.seq then return end
        dl = nil                       -- something newer exists: go for that
    end
    PickCandidate()
end

function Patch:OnPatchComm(prefix, text, distribution, sender)
    if distribution ~= "GUILD" or type(text) ~= "string" or type(sender) ~= "string" then return end
    if not ns.loggedIn or not Available() or DB().off then return end
    local senderKey = Util.NormalizeName(sender)
    if not senderKey or Util.IsMe(senderKey) then return end
    local kind = sub(text, 1, 2)
    if kind == "C:" then
        local seq, item, idx, data = match(text, "^C:(%d+):(%d+):(%d+):(.*)$")
        seq, item, idx = tonumber(seq), tonumber(item), tonumber(idx)
        if seq and item and idx and seq <= MAX_SEQ and item <= MAX_FILES and idx <= 65535 then
            OnChunk(senderKey, seq, item, idx, data)
        end
    elseif kind == "A:" then
        local seq, base, n0 = match(text, "^A:(%d+):(%w+):(%d+)$")
        seq, n0 = tonumber(seq), tonumber(n0)
        if seq and n0 and seq <= MAX_SEQ and n0 <= MAX_N0 and #base <= 32 then
            OnAnnounce(senderKey, seq, base, n0)
        end
    elseif kind == "W:" then
        local request, notFrom = match(text, "^([^!]*)!?(.*)$")
        local seq, spec, ranges = match(request, "^W:(%d+):(%w+):?([%d,%-%*]*)$")
        seq = tonumber(seq)
        if seq and seq <= MAX_SEQ and #text <= 255 then
            if notFrom == "" then
                if spec == "all" then
                    heardWant[seq .. ":all"] = GetTime()
                elseif spec == "0" and ranges == "*" then
                    heardWant[seq .. ":0:*"] = GetTime()
                end
            end
            Nudge(seq)
            OnWant(senderKey, seq, spec, ranges, notFrom)
        end
    end
end

---------------------------------------------------------------------------
-- Checking my own copy
---------------------------------------------------------------------------

-- Once per session, when a downloader reports that what I served failed its checks: verify the copy I serve
-- against its own signed manifest. A damaged copy is no longer served, and is fetched afresh after the next login
-- (the text the loader runs has its own checksums and is not affected).
SelfCheck = function()
    if selfChecked or not held then return end
    selfChecked = true
    local mine = held
    Job(function()
        local ok = false
        local m = CheckManifestBlob(mine.z0)
        if m and m.seq == mine.seq and #m.items == #mine.z then
            ok = true
            for i, e in ipairs(m.items) do
                if not CheckItem(e, mine.z[i]) then
                    ok = false
                    break
                end
            end
        end
        if ok or held ~= mine then return end
        ns:Debug("Patch: my stored copy of #%d is damaged; no longer serving it", mine.seq)
        StopServing()
        held = nil
        local p = DB().active
        if type(p) == "table" and p.seq == mine.seq then p.z = nil end
        Changed()
    end)
end

---------------------------------------------------------------------------
-- Publishing (the outbox written by dev/tools/release.py)
---------------------------------------------------------------------------

function Patch:Publish()
    if not Available() then
        ns:Print("in-game updates are not available (libraries or the public key are missing).")
        return
    end
    local box = CDLootOutbox
    if type(box) ~= "table" or type(box.z0) ~= "string" or type(box.z) ~= "table" then
        ns:Print("nothing to publish. Build an update first (dev\\tools\\release.py patch), then /reload.")
        return
    end
    ns:Print("checking the update...")
    Job(function()
        local m, why = CheckManifestBlob(box.z0)
        if not m then
            ns:Print("the update in the outbox is not valid (%s).", tostring(why))
            return
        end
        if held and held.seq == m.seq then
            publishedHere = true
            SendAnnounce()
            ns:Print("update %s (#%d) is already published; announced it again.", m.version, m.seq)
            return
        end
        if m.seq <= HeldSeq() or m.seq < Floor() then
            ns:Print("the outbox holds #%d, but #%d is already out. Build a new update.", m.seq, max(HeldSeq(), Floor()))
            return
        end
        if #box.z ~= #m.items then
            ns:Print("the update in the outbox is incomplete.")
            return
        end
        local srcs = {}
        for i, e in ipairs(m.items) do
            local src = CheckItem(e, box.z[i])
            if not src then
                ns:Print("the update in the outbox is damaged (%s).", e.p)
                return
            end
            srcs[i] = src
        end
        dl = nil
        Stage(m, box.z0, box.z, srcs)
        publishedHere = true
        SendAnnounce()
        ns:Print("published update %s (#%d): %d file(s), %d KB to send. Guild members who are online get it now; "
            .. "everybody else when they log in.", m.version, m.seq, #m.items, ceil((m.ztotal + #box.z0) / 1024))
    end)
end

---------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------

-- { applied = { seq, version, pack, files } | nil, state =, ready = { seq, version } | nil,
--   downloading = { seq =, version =, have =, total = } | nil, held = seq | nil, newArt = bool }
function Patch:GetStatus()
    local out = { applied = Boot.applied, state = Boot.state, ready = Patch.ready, held = held and held.seq or nil }
    if dl then
        local have, total = 0, 0
        for i = 0, dl.m and #dl.m.items or 0 do
            local slot = dl.items[i]
            local n = slot.n or max(slot.top, 1)
            total = total + n
            have = have + ((slot.state == "open") and slot.have or n)
        end
        out.downloading = { seq = dl.seq, version = dl.m and dl.m.version or nil, have = have, total = total,
                            known = dl.m ~= nil }
    end
    out.newArt = (Boot.applied ~= nil and (Boot.applied.pack or 0) > Boot.assetPack) or false
    return out
end

function Patch:PrintStatus()
    ns:Print("version %s%s.", tostring(ns.version),
        (Boot.applied and (Boot.applied.files or 0) > 0)
            and (" (in-game update #" .. Boot.applied.seq .. " on top of " .. tostring(ns.diskVersion) .. ")") or "")
    for _, line in ipairs(Boot.StatusLines()) do ns:Print("%s", line) end
    local s = self:GetStatus()
    if s.ready then
        ns:Print("update %s is downloaded: reload the interface (/reload) to use it.", tostring(s.ready.version))
    end
    if s.downloading then
        local d = s.downloading
        if d.known then
            ns:Print("downloading update %s: %d%%.", tostring(d.version), floor(100 * d.have / max(1, d.total)))
        else
            ns:Print("looking for update #%d...", d.seq)
        end
    end
    if s.newArt then
        ns:Print("this update has new art you do not have yet. Download the full CDLoot %s to see it.", tostring(ns.version))
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Patch:OnInit()
    if not Available() then return end
    Patch:RegisterComm(CONTROL, "OnPatchComm")
    for _, prefix in ipairs(DATA) do
        Patch:RegisterComm(prefix, "OnPatchComm")
    end
    ns:RegisterEvent("ENCOUNTER_START", function() inEncounter = true end)
    ns:RegisterEvent("ENCOUNTER_END", function() inEncounter = false end)
    ns:RegisterSlash("publish", function() Patch:Publish() end, "send the in-game update in the outbox to the guild")
    ns:RegisterSlash("update", function() Patch:PrintStatus() end, "in-game update status")
end

function Patch:OnLogin()
    if not Available() then return end
    local db = DB()
    -- A stored patch for another build (the addon folder was replaced since) or one marked bad is dropped.
    local p = db.active
    if type(p) == "table" then
        if not BuildHeld(p) or (not Boot.isDev and p.base ~= Boot.buildId) or IsBad(p.seq) then
            db.active = nil
        end
    elseif p ~= nil then
        db.active = nil
    end
    held = BuildHeld(db.active)
    local part = db.partial
    if type(part) ~= "table" or type(part.seq) ~= "number" or type(part.z0) ~= "string"
        or part.base ~= Boot.buildId or part.seq <= HeldSeq() or part.seq < Floor() or IsBad(part.seq) then
        db.partial = nil
        part = nil
    end
    UpdateReady()

    -- Resume an unfinished download from what was stored.
    if part and CanDownload() then
        candidates[part.seq] = true
        PickCandidate()
    end

    -- "this is what I have": once after login and then every half hour, unless a download is under way
    -- (then the guild already knows I am behind and somebody answered)
    local function Routine()
        if not dl then SendAnnounce() end
    end
    RandomDelay(12, 25, Routine)
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(REANNOUNCE, function()
            RandomDelay(0, 60, Routine)
        end)
    end
    if Patch.ready then Changed() end
end

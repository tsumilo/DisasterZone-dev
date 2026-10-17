if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Bridge.lua", ...) then return end -- DisasterZone: Discord bridge (ns.Bridge).
-- The guild's Discord bot runs on a server (launcher/server). A WoW addon can't reach the network, so every member's
-- launcher syncs with it through files:
--   launcher -> Interface/AddOns/DisasterZone_Bridge/Inbox.lua (the global DZBridge, rewritten by the launcher; the
--               folder exists only on PCs whose launcher is linked, it is not part of a release)
--   addon    -> DisasterZoneBridgeDB (SavedVariables/DisasterZone.lua): the records it took (applied) and what the bot
--               shows (snap), uploaded by the launcher after each save
-- Records are read at login or /reload, by whoever loads them first. Each one is signed by the bot's server (W-OTS +
-- Merkle, the hot patches' scheme; public key in Core/BridgeKey.lua, launcher/proto documents the signed bytes), so
-- an edited Inbox.lua does nothing. A taken record is relayed to the guild (DZR) with its signature: online members
-- check it and apply it too; the rest get the result through the normal guild sync.
--
-- DZBridge = { v = 2, written = <epoch>, user = <Discord name the launcher is linked as>,
--              records = { { id, type, at, by, body = { ... }, discord, sig = <hex> }, ... },
--              channels = { { id = "<snowflake>", name = "raids" }, ... } (the Discord server's text channels),
--              links = { ... } (unused: the signed "links" record carries the badges) }
--
-- Who is who: a Discord user makes their character in Discord once (name, class, spec); the bot keeps it. No proof
-- is asked: the guild trusts its Discord. A name in the guild roster signs up as that member (the roster's class
-- counts); any other name is a guest (pug) of the raid.
-- DisasterZoneBridgeDB = { applied = { [id] = { t = <when applied>, ok = true|false, why = <text> } },
--                          loaded = <epoch of the last read>, inbox = <the inbox's written stamp>,
--                          snap = <what the bot shows, written at logout where a launcher syncs: see Snapshot> }
-- A section handles its record type with Bridge:RegisterType(type, fn(record, how) -> ok, why), how = "inbox" (from
-- this PC's launcher) or "relay" (from a guild member). Returning "defer" leaves the record for someone else (a
-- guest needs a raid manager, a list kept for a member without the addon needs the council). Unknown types are
-- marked not ok, so a newer bot's records never pile up in its queue.
local addonName, ns = ...

local Bridge = ns:NewModule("Bridge")

local type, pairs, ipairs, tostring, pcall, time = type, pairs, ipairs, tostring, pcall, time
local floor, tsort, strformat, concat = math.floor, table.sort, string.format, table.concat

local KEEP_DAYS = 14   -- applied marks outlive their records this long (the launcher reads them at the next save)
local MAX_RECORD_TEXT = 4000   -- a relayed record's signed text (Discord's own limits keep real ones far smaller)
local RELAY_VERIFY_PER_MIN = 20   -- signatures checked for one sender per minute (each is ~1000 hashes)

local handlers = {}

function Bridge:RegisterType(kind, fn)
    handlers[kind] = fn
end

local function DB()
    DisasterZoneBridgeDB = type(DisasterZoneBridgeDB) == "table" and DisasterZoneBridgeDB or {}
    local db = DisasterZoneBridgeDB
    db.applied = type(db.applied) == "table" and db.applied or {}
    return db
end

local function Inbox()
    return type(DZBridge) == "table" and DZBridge or nil
end

-- Is this PC's launcher linked with the guild's bot (it writes the inbox here)?
function Bridge:HasLauncher()
    return Inbox() ~= nil
end

-- The Discord server's text channels { { id, name }, ... } (from this PC's launcher; empty without one).
function Bridge:GetChannels()
    local out = {}
    local list = Inbox() and DZBridge.channels
    for _, c in ipairs(type(list) == "table" and list or {}) do
        if type(c) == "table" and type(c.id) == "string" and type(c.name) == "string" then
            out[#out + 1] = { id = c.id, name = c.name }
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Signatures
---------------------------------------------------------------------------

-- The bytes the bot signed (dz_proto Record::message): "DZB1" S(id) S(type) I(at) S(by) S(discord) V(body), S(x) =
-- "s" len ":" x, I(n) = "i" n ";", V = S / I / "t" / "f" / "n" / "{" S(key) V(value) ... "}" with keys in byte order.
-- Returns nil for a record that can't have been signed (fractions, lists, non-string keys).
local function S(s) return "s" .. #s .. ":" .. s end

local function Num(n)
    if n ~= n or n ~= floor(n) or n >= 2 ^ 53 or n <= -2 ^ 53 then return nil end
    return "i" .. strformat("%.0f", n) .. ";"
end

local function Put(v, out, depth)
    local t = type(v)
    if v == nil then out[#out + 1] = "n"
    elseif t == "boolean" then out[#out + 1] = v and "t" or "f"
    elseif t == "number" then
        local s = Num(v)
        if not s then return false end
        out[#out + 1] = s
    elseif t == "string" then out[#out + 1] = S(v)
    elseif t == "table" then
        if depth > 6 then return false end
        local keys = {}
        for k in pairs(v) do
            if type(k) ~= "string" then return false end
            keys[#keys + 1] = k
        end
        tsort(keys)
        out[#out + 1] = "{"
        for _, k in ipairs(keys) do
            out[#out + 1] = S(k)
            if not Put(v[k], out, depth + 1) then return false end
        end
        out[#out + 1] = "}"
    else
        return false
    end
    return true
end

function Bridge.Message(r)
    if type(r) ~= "table" or type(r.id) ~= "string" or type(r.type) ~= "string" or type(r.at) ~= "number"
        or type(r.by) ~= "string" or (r.discord ~= nil and type(r.discord) ~= "string") then
        return nil
    end
    local at = Num(r.at)
    if not at then return nil end
    local out = { "DZB1", S(r.id), S(r.type), at, S(r.by), S(r.discord or "") }
    if not Put(r.body, out, 0) then return nil end
    return concat(out)
end

-- Signatures already checked: [message .. sig] = true/false (an inbox record and its relay are checked once).
local checked = {}
local jobs, jobRunning, sliceStart = {}, false, 0

local function Breathe()
    if debugprofilestop() - sliceStart > 6 then coroutine.yield() end
end

local function Step(co)
    sliceStart = debugprofilestop()
    local ok, err = coroutine.resume(co)
    if not ok then
        local handler = geterrorhandler and geterrorhandler()
        if handler then handler(err) end
    end
    if ok and coroutine.status(co) ~= "dead" then
        C_Timer.After(0, function() Step(co) end)
    else
        jobRunning = false
        local nextJob = table.remove(jobs, 1)
        if nextJob then
            jobRunning = true
            Step(coroutine.create(nextJob))
        end
    end
end

local function Job(fn)
    if jobRunning then jobs[#jobs + 1] = fn; return end
    jobRunning = true
    Step(coroutine.create(fn))
end

-- Is `sig` (binary) the bot's signature over `message`? Spread over frames (the check is ~1000 hashes).
local function Verify(message, sig, done)
    local key = ns.BridgeKey
    local P = ns.Patch
    if not (key and P and P.VerifySignature) or type(sig) ~= "string" then return done(false) end
    local id = message .. "\0" .. sig
    if checked[id] ~= nil then return done(checked[id]) end
    Job(function()
        local ok = P.VerifySignature(message, sig, key, Breathe) ~= nil
        checked[id] = ok
        done(ok)
    end)
end
Bridge.Verify = Verify   -- (tests)

---------------------------------------------------------------------------
-- Taking records
---------------------------------------------------------------------------

-- Run a record's handler: ok, why, or "defer".
local function Handle(r, how, sig)
    local fn = handlers[r.type]
    if not fn then return false, "unknown type " .. tostring(r.type) end
    local fine, a, b = pcall(fn, r, how, sig)
    if not fine then return false, tostring(a) end
    if a == "defer" then return "defer", b end
    return a ~= false, b
end

local function Wire(r, sig)
    return { id = r.id, type = r.type, at = r.at, by = r.by, body = r.body, discord = r.discord, sig = sig }
end

-- A record I took is passed on to the guild with its signature (DZR): online members apply it themselves.
local function Relay(r, sig, target)
    if not ns.Comm then return end
    ns.Comm:Send({ t = "DZR", r = Wire(r, sig) }, target and "WHISPER" or "GUILD", target, "data")
end

-- Take every new record of `inbox` into `applied` (a table of marks). Each one is checked first, so this runs over a
-- few frames; done(n) gets how many were taken. A record whose signature fails is left alone (not marked: a key
-- mismatch must not make the bot drop the guild's changes).
function Bridge:Apply(inbox, applied, done, relay)
    local records = type(inbox) == "table" and type(inbox.records) == "table" and inbox.records or {}
    local todo = {}
    for _, r in ipairs(records) do
        if type(r) == "table" and type(r.id) == "string" and not applied[r.id] then todo[#todo + 1] = r end
    end
    local n, i = 0, 0
    local function nextOne()
        i = i + 1
        local r = todo[i]
        if not r then return done and done(n) end
        local message = Bridge.Message(r)
        local sig = type(r.sig) == "string" and ns.Sha256.FromHex(r.sig) or nil
        if not message or not sig then return nextOne() end
        Verify(message, sig, function(good)
            if good and not applied[r.id] then
                local ok, why = Handle(r, "inbox", sig)
                if ok ~= "defer" then
                    applied[r.id] = { t = time(), ok = ok, why = why }
                    n = n + 1
                    if ok and relay ~= false then Relay(r, sig) end
                end
            elseif not good then
                ns:Debug("Bridge: %s has a bad signature (is Core/BridgeKey.lua the bot's key?)", r.id)
            end
            nextOne()
        end)
    end
    nextOne()
end

-- Forget marks older than KEEP_DAYS whose record has left the inbox.
function Bridge:Prune(inbox, applied)
    local inInbox = {}
    for _, r in ipairs(type(inbox) == "table" and type(inbox.records) == "table" and inbox.records or {}) do
        if type(r) == "table" and r.id then inInbox[r.id] = true end
    end
    local cut = time() - KEEP_DAYS * 86400
    for id, m in pairs(applied) do
        if not inInbox[id] and (type(m) ~= "table" or (m.t or 0) < cut) then applied[id] = nil end
    end
end

-- Signatures one sender may make me check this minute (each check is ~1000 hashes).
local checks = {}
local function CanCheck(sender)
    local minute = floor(GetTime() / 60)
    local c = checks[sender]
    if not c or c.m ~= minute then c = { m = minute, n = 0 }; checks[sender] = c end
    c.n = c.n + 1
    return c.n <= RELAY_VERIFY_PER_MIN
end

-- DZR { r }: a record a guild member took (GUILD), or one meant for me (WHISPER: a BiS edit of my list).
local function OnRelay(sender, msg, dist)
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    local r = type(msg.r) == "table" and msg.r
    local message = r and Bridge.Message(r)
    if not message or #message > MAX_RECORD_TEXT or type(r.sig) ~= "string" then return end
    local applied = DB().applied
    if applied[r.id] then
        if dist == "WHISPER" and ns.Comm then ns.Comm:Send({ t = "BDA", ids = { r.id } }, "WHISPER", sender, "ctrl") end
        return
    end
    if checked[message .. "\0" .. r.sig] == nil and not CanCheck(sender) then return end
    Verify(message, r.sig, function(good)
        if not good or applied[r.id] then return end
        local ok, why = Handle(r, "relay", r.sig)
        if ok == "defer" then return end
        applied[r.id] = { t = time(), ok = ok, why = why }
        if dist == "WHISPER" and ns.Comm then ns.Comm:Send({ t = "BDA", ids = { r.id } }, "WHISPER", sender, "ctrl") end
    end)
end

---------------------------------------------------------------------------
-- Discord links: which guild members made their character in Discord (a badge after their name, UI:DiscordTag).
-- The bot sends a signed "links" record { rev, l = { [character name] = Discord name } } whenever they change. Whoever
-- takes it keeps db.discordLinks[guildKey] = { rev, l = { [key] = Discord name }, r = <the signed record> } and
-- shares the record: DCL { r } (GUILD, or WHISPER to one member). Its rev rides in the HELLO (dcr): a member with an
-- older one asks (DCQ); anyone holding a newer signed record answers.
---------------------------------------------------------------------------

local MAX_LINKS = 400

local function LinksRec(create)
    local G = ns.Guild
    local gk = G and G.GetGuildKey and G:GetGuildKey()
    local rec = gk and ns.DB:GuildBucket("discordLinks", create, gk)
    if not rec then return nil end
    if type(rec.l) ~= "table" or type(rec.rev) ~= "number" then
        if not create then return nil end
        rec.rev, rec.l = 0, {}
    end
    return rec
end

local function SendLinks(target)
    local rec = LinksRec(false)
    if not rec or type(rec.r) ~= "table" or not ns.Comm then return end
    ns.Comm:Send({ t = "DCL", r = rec.r }, target and "WHISPER" or "GUILD", target, "data")
end

-- The Discord name of the player who made `key` in Discord, or nil.
function Bridge:GetDiscordName(key)
    local rec = type(key) == "string" and LinksRec(false)
    return rec and rec.l[key] or nil
end

-- A checked "links" record: its names as guild members' keys (names not in the guild are left out).
local function TakeLinks(r, sig)
    local b = type(r.body) == "table" and r.body or {}
    local rev = tonumber(b.rev)
    if not rev or type(b.l) ~= "table" then return false, "bad links" end
    local rec = LinksRec(true)
    if not rec then return "defer" end
    if rev <= rec.rev then return true end
    local l, n = {}, 0
    for name, discord in pairs(b.l) do
        n = n + 1
        if n > MAX_LINKS then break end
        local key = type(name) == "string" and Bridge:FindMember(name)
        if key and type(discord) == "string" then l[key] = discord:sub(1, 40):gsub("[%c|]", "") end
    end
    rec.rev, rec.l, rec.r = rev, l, Wire(r, sig)
    ns:Fire("DISCORD_LINKS_CHANGED")
    return true
end

Bridge:RegisterType("links", function(r, _, sig)
    return TakeLinks(r, sig)
end)

local function OnLinks(sender, msg, dist)
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    local r = type(msg.r) == "table" and msg.r
    local message = r and r.type == "links" and Bridge.Message(r)
    if not message or type(r.sig) ~= "string" then return end
    local rec = LinksRec(false)
    local b = type(r.body) == "table" and r.body or {}
    if rec and (tonumber(b.rev) or 0) <= rec.rev then return end
    if not CanCheck(sender) then return end
    Verify(message, r.sig, function(good)
        if good then TakeLinks(r, r.sig) end
    end)
end

local linksSync = ns.DigestSync and ns.DigestSync.RevList({
    field = "dcr", order = 95, query = "DCQ", limit = 60,
    send = function(...) return ns.Comm and ns.Comm:Send(...) end,
    replyKey = "dcl-reply:", askKey = "dcq-ask:", queryKey = "dcq:",
    rev = function() local r = LinksRec(false); return r and r.rev or 0 end,
    serve = function() local r = LinksRec(false); return r ~= nil and type(r.r) == "table" end,
    -- (anyone may hold the newest list: what they send is checked against the bot's key)
    writer = function() return true end,
    sendList = function(target) SendLinks(target) end,
})

---------------------------------------------------------------------------
-- BiS edits from Discord: record "bis" { name, phase, sid, item (0 = clear), which = "main"|"alt", list = "os" }.
-- The game that takes it from its inbox routes it:
--   my own character      -> my list (BiS:SetSlot)
--   a member with the addon (Sync:GetPeer) -> db.bisOut[key] = { signed records }, whispered to them while they are
--                            online (DZR); their addon checks and applies it and answers (BDA { ids })
--   a member without it   -> the council keeps their list (a Store copy): only a council member's game does this
-- A relayed copy only changes the list of the member it is for.
---------------------------------------------------------------------------

local function Pending()
    local db = DB()
    db.bisOut = type(db.bisOut) == "table" and db.bisOut or {}
    return db.bisOut
end

function Bridge:DeliverBis()
    if not ns.Comm then return end
    for key, list in pairs(Pending()) do
        if #list == 0 then Pending()[key] = nil
        elseif ns.Guild:IsOnline(key) and ns.Comm:RateLimit("dzr-out:" .. key, 300) then
            for i = 1, math.min(#list, 10) do
                if type(list[i]) == "table" and list[i].sig then ns.Comm:Send({ t = "DZR", r = list[i] }, "WHISPER", key, "data") end
            end
        end
    end
end

-- A list the council keeps for a member without the addon: one slot changed (the council's copy, a higher rev).
local function EditHostList(key, phase, sid, item, which, list)
    local S, Util = ns.Store, ns.Util
    if not (S and S.Put) then return false, "BiS lists not loaded" end
    local cur = S:Get(key)
    local d = type(cur) == "table" and type(cur.data) == "table" and Util.CopyTable(cur.data)
        or { v = ns.LIST_VERSION or 1, cl = ns.Guild:GetClass(key) or "", sp = "", ph = {}, ob = {}, eq = {} }
    -- (the off spec's lists sit flat next to the main spec's: op / opr, like ph / pr; Core/BiS.lua)
    local PH, PR = list == "os" and "op" or "ph", list == "os" and "opr" or "pr"
    if list == "os" and type(d.os) ~= "string" then d.os = "" end
    local slots
    if phase == 0 then
        d[PR] = type(d[PR]) == "table" and d[PR] or {}
        slots = d[PR]
    else
        d[PH] = type(d[PH]) == "table" and d[PH] or {}
        d[PH][phase] = type(d[PH][phase]) == "table" and d[PH][phase] or {}
        slots = d[PH][phase]
    end
    local pair = type(slots[sid]) == "table" and slots[sid] or {}
    local main, alt = tonumber(pair[1]) or 0, tonumber(pair[2]) or 0
    if which == "alt" then
        if item ~= 0 and item == main then main = alt end
        alt = item
    else
        if item ~= 0 and item == alt then alt = main end
        main = item
    end
    if main ~= 0 and main == alt then alt = 0 end
    slots[sid] = (main ~= 0 or alt ~= 0) and { main, alt } or nil
    if phase ~= 0 and next(slots) == nil then d[PH][phase] = nil end
    local rev = (type(cur) == "table" and tonumber(cur.rev) or 0) + 1
    if not S:Put(key, { r = rev, ts = Util.Now(), h = Util.Hash(d), d = d }, "discord") then
        return false, "the list could not be saved"
    end
    return true
end

Bridge:RegisterType("bis", function(r, how, sig)
    local b = type(r.body) == "table" and r.body or {}
    local key = Bridge:FindMember(b.name)
    if not key then
        if how == "relay" then return true end
        return false, tostring(b.name) .. " is not in the guild."
    end
    local phase, sid, which = tonumber(b.phase), tonumber(b.sid), b.which == "alt" and "alt" or "main"
    local list = b.list == "os" and "os" or nil
    if not phase or phase < 0 or phase > 5 then return false, "unknown phase" end
    local item = tonumber(b.item) or 0
    if item ~= 0 then
        local why
        item, why = ns.BiS:CheckPick(item, sid)
        if not item then return false, why end
    end
    if ns.Util.IsMe(key) then
        if list and not ns.BiS:HasOffSpec() then ns.BiS:AddOffSpec("") end
        if not ns.BiS:SetSlot(phase, sid, which, item, list) then return false, "the list is locked for the raid" end
        ns.BiS:Commit()
        if how == "relay" then
            ns:Print("Your BiS list was changed in Discord (%s).", ns.SLOTS[sid] and ns.SLOTS[sid].label or "a slot")
        end
        return true
    end
    -- (a relayed copy for someone else: their own game, or the inbox's taker, does it)
    if how == "relay" then return true end
    if ns.Sync and ns.Sync.GetPeer and ns.Sync:GetPeer(key) then
        local pend = Pending()[key] or {}
        pend[#pend + 1] = Wire(r, sig)
        Pending()[key] = pend
        Bridge:DeliverBis()
        return true
    end
    if not (ns.Guild.AmICouncil and ns.Guild:AmICouncil(true)) then return "defer" end
    return EditHostList(key, phase, sid, item, which, list)
end)

-- BDA { ids }: a member's addon took these edits.
local function OnBisAck(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg.ids) ~= "table" then return end
    local list = Pending()[sender]
    if not list then return end
    local took = {}
    for _, id in ipairs(msg.ids) do took[id] = true end
    for i = #list, 1, -1 do
        if type(list[i]) ~= "table" or took[list[i].id] then table.remove(list, i) end
    end
    if #list == 0 then Pending()[sender] = nil end
end

function Bridge:OnInit()
    if ns.Comm then
        ns.Comm:Register("DCL", OnLinks)
        ns.Comm:Register("DZR", OnRelay)
        ns.Comm:Register("BDA", OnBisAck)
        -- (a signature is 2.6 KB: any member relays records, so they may send them large)
        if ns.Comm.AllowLarge then
            ns.Comm:AllowLarge("DZR", "data")
            ns.Comm:AllowLarge("DCL", "data")
        end
    end
    if linksSync then linksSync.Register() end
    ns:On("ROSTER_UPDATED", function() ns.Util.Debounce("bridge-bis", 10, function() Bridge:DeliverBis() end) end)
end

---------------------------------------------------------------------------
-- Snapshot
---------------------------------------------------------------------------

local SNAP_BACK, SNAP_AHEAD = 6 * 3600, 14 * 86400
local ST_WORD = { A = "accept", T = "tentative", B = "bench", X = "absent" }
local loginAt

-- What the bot needs, uploaded by the launcher from SavedVariables (it can't run the addon's raid logic itself). The
-- bot merges many members' snapshots (launcher/server merge.rs): sign-ups by rev, lists by r, the rest from the
-- newest game that had been up a while (up).
-- { at, up = <seconds since login>, me, guild, dc = { guild, week, loot, teams }, teams = { [id] = name },
--   roster = { { key, class }, ... }, phase,
--   bis = { [key] = { r, class, spec, ph, os, oph, slots = { { sid, slot, id, got, alt, altGot }, ... } } },
--   items = { [id] = { n, s, q } },
--   raids = { { id, t, name, title, note, size, teams = { id, ... }, locked, cancelled, leader, need, inst,
--               signups = { { key, st = "accept"|..., class, spec, role, guest, at, rev }, ... } }, ... } }
-- Private raids are left out: the bot posts in public channels.
local function SnapRaids(RP, now)
    local raids = {}
    for _, v in ipairs(RP:GetRaids(now - SNAP_BACK, now + SNAP_AHEAD, true)) do
        if not v.pv then
            local su = {}
            for key, s in pairs(RP:GetSignups(v.id)) do
                local specs = s.c and ns.SPECS[s.c]
                local spec = specs and s.sp and specs[s.sp]
                su[#su + 1] = { key = key, st = ST_WORD[s.st] or s.st, class = s.c, spec = spec and spec.label or nil,
                                role = ns.RaidComp and ns.RaidComp:RoleOf(s.c, s.sp) or nil, guest = s.guest or nil,
                                at = s.at, rev = s.rev }
            end
            table.sort(su, function(a, b) return (a.at or 0) < (b.at or 0) end)
            -- the comp the raid aims for: its team lineup's target comp (tanks, healers, damage), if it has one
            local need
            local tid = v.tm and v.tm[1]
            local l = tid and RP.GetRaidLineup and RP:GetRaidLineup(v, tid)
            if l and l.comp and ns.RaidComp then
                local rc = ns.RaidComp:RoleCounts(l.comp)
                if rc.tank + rc.healer + rc.melee + rc.ranged > 0 then
                    need = { tank = rc.tank, heal = rc.healer, dps = rc.melee + rc.ranged }
                end
            end
            raids[#raids + 1] = {
                id = v.id, t = v.t, name = RP:GetRaidName(v), title = v.ti, note = v.no, size = v.sz,
                teams = v.tm or {}, locked = v.lk or nil, cancelled = v.cancelled or nil,
                leader = RP.GetRaidLeader and RP:GetRaidLeader(v.id) or nil, signups = su, need = need,
                inst = v.i,
            }
        end
    end
    return raids
end

-- For the DisasterZone launcher's Home on every PC, linked or not (launcher/src-tauri/src/core/player.rs): the
-- guild's next raids as the snapshot has them, kept in DisasterZoneDB (which no launcher uploads).
-- db.launcher = { at, me, raids = <as in the snapshot> }
function Bridge:LauncherHome()
    local RP, Util = ns.RaidPlan, ns.Util
    local now = Util.Now()
    return { at = now, me = Util.PlayerKey(), raids = RP and SnapRaids(RP, now) or {} }
end

function Bridge:Snapshot()
    local RP, G, Util = ns.RaidPlan, ns.Guild, ns.Util
    local now = Util.Now()
    local d = G and G.GetDiscord and G:GetDiscord() or {}
    local out = { at = now, up = loginAt and floor(GetTime() - loginAt) or 0, me = Util.PlayerKey(),
                  guild = G and G.GetGuildKey and G:GetGuildKey() or nil,
                  dc = { guild = d.guild, week = d.week, loot = d.loot, teams = d.teams or {} },
                  teams = {}, raids = {} }
    if not RP then return out end
    for _, t in ipairs(RP:GetTeams()) do out.teams[t.id] = t.name end
    -- the guild's members and their classes: the bot fills in a member's class from it
    out.roster = {}
    for _, key in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        local class = G:GetClass(key)
        if class then out.roster[#out.roster + 1] = { key = key, class = class } end
    end
    -- the BiS lists I hold (mine; everyone's on the guild council), the guild's phase, main spec
    local phase = G and G.GetGuildPhase and G:GetGuildPhase() or 1
    out.phase, out.bis = phase, {}
    -- every phase (0 = Pre-raid), main and off spec; item names, sources and quality once, in out.items
    local S, I = ns.Store, ns.ItemDB
    out.items = {}
    local function item(id)
        if id > 0 and not out.items[id] then
            out.items[id] = { n = I and I.GetName and I:GetName(id) or nil, s = I and I.GetSourceText and I:GetSourceText(id) or nil,
                              q = I and I.GetQuality and I:GetQuality(id) or nil }
        end
    end
    local function slotsOf(key, slots)
        local list = {}
        for sid = 1, ns.NUM_SLOTS do
            local pair = type(slots) == "table" and type(slots[sid]) == "table" and slots[sid] or {}
            local id, alt = tonumber(pair[1]) or 0, tonumber(pair[2]) or 0
            if id > 0 or alt > 0 then
                local e = { sid = sid, slot = ns.SLOTS[sid].label }
                if id > 0 then e.id, e.got = id, S.IsObtainedBy and S:IsObtainedBy(key, id) or nil end
                if alt > 0 then e.alt, e.altGot = alt, S.IsObtainedBy and S:IsObtainedBy(key, alt) or nil end
                item(id); item(alt)
                list[#list + 1] = e
            end
        end
        return list
    end
    local function phasesOf(key, ph, pr)
        local out2, any = {}, false
        for p = 0, 5 do
            local slots = p == 0 and pr or (type(ph) == "table" and ph[p])
            local l = slotsOf(key, slots)
            if #l > 0 then out2[tostring(p)] = l; any = true end
        end
        return any and out2 or nil
    end
    for _, key in ipairs(S and S.GetAllKeys and S:GetAllKeys() or {}) do
        local rec = S:Get(key)
        local data = type(rec) == "table" and type(rec.data) == "table" and rec.data
        if data then
            local ms = phasesOf(key, data.ph, data.pr)
            local os = data.os and phasesOf(key, data.op, data.opr) or nil
            if ms or os then
                out.bis[key] = { r = tonumber(rec.rev) or 0,
                                 class = data.cl ~= "" and data.cl or (G and G.GetClass and G:GetClass(key)) or nil,
                                 spec = data.sp ~= "" and data.sp or nil, ph = ms or {},
                                 os = data.os and data.os ~= "" and data.os or (os and "Off spec") or nil, oph = os,
                                 slots = ms and ms[tostring(phase)] or {} }
            end
        end
    end
    out.raids = SnapRaids(RP, now)
    return out
end

function Bridge:OnLogin()
    loginAt = GetTime()
    local inbox = Inbox()
    -- (saved variables are written at logout / reload: what launchers read is made then. Every PC gets the
    -- launcher's Home (db.launcher); the snapshot only where a launcher is linked, which uploads it)
    ns:RegisterEvent("PLAYER_LOGOUT", function()
        if type(ns.db) == "table" then
            local ok, home = pcall(Bridge.LauncherHome, Bridge)
            ns.db.launcher = ok and home or nil
        end
        if inbox then
            local ok, snap = pcall(Bridge.Snapshot, Bridge)
            DB().snap = ok and snap or { at = time(), error = tostring(snap) }
        end
    end)
    if not inbox then return end   -- (no launcher linked on this PC)
    -- (records name guild members: they wait for the guild roster, which comes in a moment after login)
    local started = false
    local function apply()
        if started or not (ns.Guild and ns.Guild.IsReady and ns.Guild:IsReady()) then return end
        started = true
        local db = DB()
        Bridge:Prune(inbox, db.applied)
        db.claims = nil   -- (1.4.2 dev builds linked with codes)
        Bridge:Apply(inbox, db.applied, function(n)
            db.loaded, db.inbox = time(), inbox.written
            if n > 0 then ns:Print("Loaded %d update%s from Discord.", n, n == 1 and "" or "s") end
        end)
    end
    apply()
    ns:On("ROSTER_UPDATED", apply)
end

-- The guild member a name typed in Discord is ("lee", "Lee-Thunderstrike"), or nil.
function Bridge:FindMember(name)
    if type(name) ~= "string" or name == "" then return nil end
    local G = ns.Guild
    local want = name:lower()
    local short = not want:find("-", 1, true)
    local me = ns.Util.PlayerKey()
    if me and (me:lower() == want or (short and me:lower():match("^([^%-]+)") == want)) then return me end
    for _, key in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        local k = key:lower()
        if k == want or (short and k:match("^([^%-]+)") == want) then return key end
    end
    return nil
end

-- A sign-up given in Discord: body { raid, name, class, sp, st = "A"|"T"|"X", note }  (note: "late 15 min" from a
-- reminder's Running late; absent = the note stays as it was). A guild member signs up as themselves
-- (RaidPlan:SignUpFor, their roster class); anyone else joins as a guest (accept only), which needs someone who may
-- run the raid.
Bridge:RegisterType("signup", function(r)
    local b = type(r.body) == "table" and r.body or {}
    local RP = ns.RaidPlan
    if not RP then return false, "raid plans not loaded" end
    local sp = tonumber(b.sp)
    local key = Bridge:FindMember(b.name)
    if key then
        -- (a spec picked for another class than the roster's is dropped: their last one counts)
        if b.class and ns.Guild:GetClass(key) ~= b.class then sp = nil end
        return RP:SignUpFor(b.raid, key, b.st, sp, type(b.note) == "string" and b.note or nil)
    end
    if b.st ~= "A" then return false, "Guests can only accept (" .. tostring(b.name) .. " is not in the guild)." end
    if not (RP.CanManageRaid and RP:CanManageRaid(b.raid)) then return "defer" end
    return RP:AddGuest(b.raid, b.name, b.class, sp)
end)

-- /bridgetest in Discord -> a chat line in every game that takes it.
Bridge:RegisterType("test", function(r)
    local b = type(r.body) == "table" and r.body or {}
    -- (| starts a text escape in WoW: show a Discord message as typed, never as colors or links)
    local text = tostring(b.text or ""):gsub("|", "||")
    ns:Print("Discord test from %s: %s", tostring(r.by or "?"):gsub("|", "||"), text)
    return true
end)

ns:RegisterSlash("bridge", function(arg)
    if arg == "demo" then
        -- made-up records into a throwaway table: nothing is saved, nothing is sent, the launcher never sees it.
        -- (unsigned, so they show the check refusing them; the demo then runs the handlers directly)
        local scratch = {}
        local ok1, why1 = Handle({ id = "demo1", type = "test", by = "Demo", body = { text = "hello from Discord" } }, "inbox")
        local ok2, why2 = Handle({ id = "demo2", type = "nope", by = "Demo" }, "inbox")
        Bridge:Apply({ records = { { id = "demo3", type = "test", at = 1, by = "Demo", sig = "00" } } }, scratch, function(n)
            ns:Print("Demo: demo1 %s, demo2 %s, an unsigned record %s.", ok1 and "taken" or tostring(why1),
                ok2 and "taken" or ("refused: " .. tostring(why2)), n == 0 and "ignored" or "taken")
        end, false)
        return
    end
    local inbox = Inbox()
    if not inbox then
        ns:Print("Discord bridge: no launcher linked on this PC (launcher > Settings > Discord).")
        return
    end
    local db, total, taken = DB(), 0, 0
    for _, r in ipairs(inbox.records or {}) do
        total = total + 1
        if db.applied[r.id] then taken = taken + 1 end
    end
    ns:Print("Discord bridge: linked as %s; %d record%s in the inbox, %d applied.", tostring(inbox.user or "?"):gsub("|", "||"),
        total, total == 1 and "" or "s", taken)
end, "Discord bridge status (demo: try it with made-up records)")

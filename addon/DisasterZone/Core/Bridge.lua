if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Bridge.lua", ...) then return end -- DisasterZone: Discord bridge (ns.Bridge).
-- The guild's Discord bot runs inside one launcher, on the host's PC (launcher src-tauri/src/bot.rs). A WoW addon
-- can't reach the network, so changes made in Discord travel through files:
--   launcher -> Interface/AddOns/DisasterZone_Bridge/Inbox.lua (the global DZBridgeInbox, written by the host's
--               launcher; the folder exists only on the host's PC and is not part of a release)
--   addon    -> DisasterZoneBridgeDB.applied (in SavedVariables/DisasterZone.lua): which inbox records were taken,
--               so the launcher can drop them from its queue at the next save.
-- Records are read once, at login or /reload. Everyone else gets the result through the normal guild sync.
--
-- DZBridgeInbox = { v = 1, written = <epoch>, records = { { id, type, at, by, body = { ... } }, ... },
--                  channels = { { id = "<snowflake>", name = "raids" }, ... } (the Discord server's text channels),
--                  links = { { name = "Lee", discord = "Tsumi" }, ... } (the characters made in Discord) }
--
-- Who is who: a Discord user makes their character in Discord once (name, class, spec); the launcher keeps it. No
-- proof is asked: the guild trusts its Discord. A name in the guild roster signs up as that member (the roster's
-- class counts); any other name is a guest (pug) of the raid.
-- DisasterZoneBridgeDB = { applied = { [id] = { t = <when applied>, ok = true|false, why = <text> } },
--                          loaded = <epoch of the last read>, inbox = <the inbox's written stamp>,
--                          snap = <what the bot shows, written at logout on the host PC: see Snapshot> }
-- A section handles its record type with Bridge:RegisterType(type, fn(record) -> ok, why). Unknown types are
-- marked not ok, so a newer launcher's records never pile up in its queue.
local addonName, ns = ...

local Bridge = ns:NewModule("Bridge")

local type, pairs, ipairs, tostring, pcall, time = type, pairs, ipairs, tostring, pcall, time

local KEEP_DAYS = 14   -- applied marks outlive their records this long (the launcher reads them at the next save)

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

-- Take every new record of `inbox` into `applied` (a table of marks); returns how many were new.
function Bridge:Apply(inbox, applied)
    local records = type(inbox) == "table" and type(inbox.records) == "table" and inbox.records or {}
    local now, n = time(), 0
    for _, r in ipairs(records) do
        local id = type(r) == "table" and r.id
        if type(id) == "string" and not applied[id] then
            local fn = handlers[r.type]
            local ok, why
            if not fn then
                ok, why = false, "unknown type " .. tostring(r.type)
            else
                local fine, a, b = pcall(fn, r)
                if fine then ok, why = a ~= false, b else ok, why = false, tostring(a) end
            end
            applied[id] = { t = now, ok = ok, why = why }
            n = n + 1
        end
    end
    return n
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

-- Is this PC the host's (the launcher writes the inbox here)?
function Bridge:IsHostPC()
    return type(DZBridgeInbox) == "table"
end

-- The Discord server's text channels { { id, name }, ... } (the host's PC only; empty elsewhere).
function Bridge:GetChannels()
    local out = {}
    local list = type(DZBridgeInbox) == "table" and DZBridgeInbox.channels
    for _, c in ipairs(type(list) == "table" and list or {}) do
        if type(c) == "table" and type(c.id) == "string" and type(c.name) == "string" then
            out[#out + 1] = { id = c.id, name = c.name }
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Discord links: which guild members made their character in Discord (a badge after their name, UI:DiscordTag).
-- The host's addon turns the inbox's links into db.discordLinks[guildKey] = { rev, l = { [key] = Discord name } }
-- and shares it: DCL { rev, l } (GUILD, or WHISPER to one member). Only the Discord host's list counts. Its rev
-- rides in the HELLO (dcr): the host answers an older one, a member asks the host for a newer one (DCQ).
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

local function CleanLinks(l)
    if type(l) ~= "table" then return nil end
    local out, n = {}, 0
    for k, v in pairs(l) do
        n = n + 1
        if n > MAX_LINKS then return nil end
        if type(k) == "string" and #k <= 48 and not k:find("[%c|]") and type(v) == "string" and #v <= 40
            and not v:find("[%c|]") then
            out[ns.Util.NormalizeName(k) or k] = v
        end
    end
    return out
end

local function SameLinks(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function SendLinks(target)
    local rec = LinksRec(false)
    if not rec or rec.rev == 0 or not ns.Comm then return end
    ns.Comm:Send({ t = "DCL", rev = rec.rev, l = rec.l }, target and "WHISPER" or "GUILD", target, "data")
end

local function AmHost()
    return ns.Guild and ns.Guild.IsDiscordHost and ns.Guild:IsDiscordHost(ns.Util.PlayerKey()) or false
end

-- The Discord name of the player who made `key` in Discord, or nil.
function Bridge:GetDiscordName(key)
    local rec = type(key) == "string" and LinksRec(false)
    return rec and rec.l[key] or nil
end

-- The host only: the inbox's links, as guild members' keys (names not in the guild are left out).
function Bridge:TakeLinks(list)
    if not AmHost() or type(list) ~= "table" then return false end
    local l = {}
    for _, e in ipairs(list) do
        local key = type(e) == "table" and self:FindMember(e.name)
        if key and type(e.discord) == "string" then l[key] = e.discord:sub(1, 40):gsub("[%c|]", "") end
    end
    local rec = LinksRec(true)
    if not rec or SameLinks(l, rec.l) then return false end
    rec.rev, rec.l = math.max(ns.Util.Now(), rec.rev + 1), l
    SendLinks()
    ns:Fire("DISCORD_LINKS_CHANGED")
    return true
end

local function OnLinks(sender, msg, dist)
    if (dist ~= "GUILD" and dist ~= "WHISPER") or not ns.Guild:IsDiscordHost(sender) then return end
    local l = CleanLinks(msg.l)
    if not l or type(msg.rev) ~= "number" or msg.rev > ns.Util.Now() + 600 then return end
    local rec = LinksRec(true)
    if not rec or msg.rev <= rec.rev then return end
    rec.rev, rec.l = msg.rev, l
    ns:Fire("DISCORD_LINKS_CHANGED")
end

local linksSync = ns.DigestSync and ns.DigestSync.RevList({
    field = "dcr", order = 95, query = "DCQ", limit = 60,
    send = function(...) return ns.Comm and ns.Comm:Send(...) end,
    replyKey = "dcl-reply:", askKey = "dcq-ask:", queryKey = "dcq:",
    rev = function() local r = LinksRec(false); return r and r.rev or 0 end,
    serve = function() return AmHost() end,
    writer = function(key) return ns.Guild:IsDiscordHost(key) end,
    sendList = function(target) SendLinks(target) end,
})

function Bridge:OnInit()
    if ns.Comm then ns.Comm:Register("DCL", OnLinks) end
    if linksSync then linksSync.Register() end
end

---------------------------------------------------------------------------
-- Snapshot
---------------------------------------------------------------------------

local SNAP_BACK, SNAP_AHEAD = 6 * 3600, 14 * 86400
local ST_WORD = { A = "accept", T = "tentative", B = "bench", X = "absent" }

-- What the bot needs, read by the launcher from SavedVariables (it can't run the addon's raid logic itself):
-- { at, me, guild, dc = { host, guild, teams }, teams = { [id] = name }, roster = { { key, class }, ... },
--   raids = { { id, t, name, title, note, size, teams = { id, ... }, locked, cancelled, leader,
--               signups = { { key, st = "accept"|..., class, spec, role, guest }, ... } }, ... } }
-- Private raids are left out: the bot posts in public channels.
function Bridge:Snapshot()
    local RP, G, Util = ns.RaidPlan, ns.Guild, ns.Util
    local now = Util.Now()
    local d = G and G.GetDiscord and G:GetDiscord() or {}
    local out = { at = now, me = Util.PlayerKey(), guild = G and G.GetGuildKey and G:GetGuildKey() or nil,
                  dc = { host = d.host, guild = d.guild, teams = d.teams or {} }, teams = {}, raids = {} }
    if not RP then return out end
    for _, t in ipairs(RP:GetTeams()) do out.teams[t.id] = t.name end
    -- the guild's members and their classes: the bot fills in a member's class from it
    out.roster = {}
    for _, key in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        local class = G:GetClass(key)
        if class then out.roster[#out.roster + 1] = { key = key, class = class } end
    end
    for _, v in ipairs(RP:GetRaids(now - SNAP_BACK, now + SNAP_AHEAD, true)) do
        if not v.pv then
            local su = {}
            for key, s in pairs(RP:GetSignups(v.id)) do
                local specs = s.c and ns.SPECS[s.c]
                local spec = specs and s.sp and specs[s.sp]
                su[#su + 1] = { key = key, st = ST_WORD[s.st] or s.st, class = s.c, spec = spec and spec.label or nil,
                                role = ns.RaidComp and ns.RaidComp:RoleOf(s.c, s.sp) or nil, guest = s.guest or nil,
                                at = s.at }
            end
            table.sort(su, function(a, b) return (a.at or 0) < (b.at or 0) end)
            out.raids[#out.raids + 1] = {
                id = v.id, t = v.t, name = RP:GetRaidName(v), title = v.ti, note = v.no, size = v.sz,
                teams = v.tm or {}, locked = v.lk or nil, cancelled = v.cancelled or nil,
                leader = RP.GetRaidLeader and RP:GetRaidLeader(v.id) or nil, signups = su,
            }
        end
    end
    return out
end

function Bridge:OnLogin()
    local inbox = DZBridgeInbox
    if type(inbox) ~= "table" then return end   -- not the host (no DisasterZone_Bridge folder)
    local db = DB()
    self:Prune(inbox, db.applied)
    local n = self:Apply(inbox, db.applied)
    db.loaded, db.inbox = time(), inbox.written
    db.claims = nil   -- (1.4.2 dev builds linked with codes)
    if n > 0 then ns:Print("Loaded %d update%s from Discord.", n, n == 1 and "" or "s") end
    -- (the roster may not be in yet at login: the links are taken once it is)
    if type(inbox.links) == "table" then
        local function take() Bridge:TakeLinks(inbox.links) end
        take()
        ns:On("ROSTER_UPDATED", function() ns.Util.Debounce("bridge-links", 3, take) end)
    end
    -- (saved variables are written at logout / reload: the snapshot is made then, on the host's PC only)
    ns:RegisterEvent("PLAYER_LOGOUT", function()
        local ok, snap = pcall(Bridge.Snapshot, Bridge)
        DB().snap = ok and snap or { at = time(), error = tostring(snap) }
    end)
end

-- The guild member a name typed in Discord is ("lee", "Lee-Thunderstrike"), or nil.
function Bridge:FindMember(name)
    if type(name) ~= "string" or name == "" then return nil end
    local G = ns.Guild
    local want = name:lower()
    local short = not want:find("-", 1, true)
    for _, key in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        local k = key:lower()
        if k == want or (short and k:match("^([^%-]+)") == want) then return key end
    end
    return nil
end

-- A sign-up given in Discord: body { raid, name, class, sp, st = "A"|"T"|"X" }. A guild member signs up as
-- themselves (RaidPlan:SignUpFor, their roster class); anyone else joins as a guest (accept only).
Bridge:RegisterType("signup", function(r)
    local b = type(r.body) == "table" and r.body or {}
    local RP = ns.RaidPlan
    if not RP then return false, "raid plans not loaded" end
    local sp = tonumber(b.sp)
    local key = Bridge:FindMember(b.name)
    if key then
        -- (a spec picked for another class than the roster's is dropped: their last one counts)
        if b.class and ns.Guild:GetClass(key) ~= b.class then sp = nil end
        return RP:SignUpFor(b.raid, key, b.st, sp)
    end
    if b.st ~= "A" then return false, "Guests can only accept (" .. tostring(b.name) .. " is not in the guild)." end
    return RP:AddGuest(b.raid, b.name, b.class, sp)
end)

-- P1 test record: /bridgetest in Discord -> a chat line here after /reload.
Bridge:RegisterType("test", function(r)
    local b = type(r.body) == "table" and r.body or {}
    -- (| starts a text escape in WoW: show a Discord message as typed, never as colors or links)
    local text = tostring(b.text or ""):gsub("|", "||")
    ns:Print("Discord test from %s: %s", tostring(r.by or "?"):gsub("|", "||"), text)
    return true
end)

ns:RegisterSlash("bridge", function(arg)
    if arg == "demo" then
        -- made-up inbox into a throwaway table: nothing is saved, the launcher never sees it
        local scratch = {}
        local n = Bridge:Apply({ records = {
            { id = "demo1", type = "test", by = "Demo", body = { text = "hello from Discord" } },
            { id = "demo2", type = "nope", by = "Demo" },
        } }, scratch)
        ns:Print("Demo: %d records, demo2 %s.", n, scratch.demo2.ok and "taken" or ("refused: " .. scratch.demo2.why))
        return
    end
    if type(DZBridgeInbox) ~= "table" then
        ns:Print("Discord bridge: not set up on this PC (only the host's launcher writes the inbox).")
        return
    end
    local db, total, taken = DB(), 0, 0
    for _, r in ipairs(DZBridgeInbox.records or {}) do
        total = total + 1
        if db.applied[r.id] then taken = taken + 1 end
    end
    ns:Print("Discord bridge: %d record%s in the inbox, %d applied.", total, total == 1 and "" or "s", taken)
end, "Discord bridge status (demo: try it with made-up records)")

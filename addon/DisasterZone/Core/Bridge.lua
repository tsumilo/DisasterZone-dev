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
--                  linked = { key, ... } (characters linked to a Discord user: the snapshot lists their characters) }
--
-- Linking (who a Discord user is): /link in Discord gives a code; the member types /dz link CODE in game on their
-- character; their addon whispers it to the Discord host (BLK { c }) whenever the host is online, and the host's addon
-- keeps it in DisasterZoneBridgeDB.claims[code] = { k = sender, t } (the game names the sender: it can't be forged).
-- The host's launcher matches the code and links the Discord user to that character. BLA { c } confirms.
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
-- Linking
---------------------------------------------------------------------------

local LINK_DAYS = 7

local function HostKey()
    local G = ns.Guild
    return G and G.GetDiscord and G:GetDiscord().host or nil
end

local function Claim(code, key)
    local db = DB()
    db.claims = type(db.claims) == "table" and db.claims or {}
    db.claims[code] = { k = key, t = time() }
end

-- Send my pending code to the host when it is online (or keep it myself when I am the host).
function Bridge:DeliverLink()
    local db = type(DisasterZoneBridgeDB) == "table" and DisasterZoneBridgeDB
    local p = db and db.link
    if type(p) ~= "table" then return end
    if (p.t or 0) < time() - LINK_DAYS * 86400 then db.link = nil return end
    local host = HostKey()
    if not host then return end
    local me = ns.Util.PlayerKey()
    if ns.Guild:IsDiscordHost(me) then
        Claim(p.c, p.k)
        db.link = nil
        ns:Print("Linked. Finish in Discord: the bot knows you after the next /reload.")
        return
    end
    if ns.Guild:IsOnline(host) and ns.Comm then ns.Comm:Send({ t = "BLK", c = p.c, k = p.k }, "WHISPER", host, "ctrl") end
end

local function OnLinkClaim(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg.c) ~= "string" or not msg.c:match("^%w%w%w%w%w%w$") then return end
    if not ns.Guild:IsDiscordHost(ns.Util.PlayerKey()) then return end
    -- (the code is for the sending character; an alt of it may have typed it for its main: SameAccount)
    local key = type(msg.k) == "string" and msg.k or sender
    if key ~= sender and not ns.Guild:SameAccount(sender, key) then key = sender end
    Claim(msg.c:upper(), key)
    ns.Comm:Send({ t = "BLA", c = msg.c }, "WHISPER", sender, "ctrl")
end

local function OnLinkAck(sender, msg, dist)
    local db = type(DisasterZoneBridgeDB) == "table" and DisasterZoneBridgeDB
    if dist ~= "WHISPER" or not (db and type(db.link) == "table") or msg.c ~= db.link.c then return end
    if sender ~= HostKey() and not ns.Guild:IsDiscordHost(sender) then return end
    db.link = nil
    ns:Print("The Discord host got your code. The bot links you after its next /reload.")
end

local function SlashLink(code)
    code = type(code) == "string" and code:upper():match("^%s*(%w%w%w%w%w%w)%s*$")
    if not code then
        ns:Print("Type /link in the guild's Discord: the bot gives you a code. Then /dz link CODE here.")
        return
    end
    DB().link = { c = code, k = ns.Util.PlayerKey(), t = time() }
    if not HostKey() then
        ns:Print("Your guild has no Discord host yet (the Guild Master sets one in Settings > Discord).")
        return
    end
    ns:Print("Code saved. It goes to the Discord host (%s) the next time you are both online.", HostKey())
    Bridge:DeliverLink()
end

---------------------------------------------------------------------------
-- Snapshot
---------------------------------------------------------------------------

local SNAP_BACK, SNAP_AHEAD = 6 * 3600, 14 * 86400
local ST_WORD = { A = "accept", T = "tentative", B = "bench", X = "absent" }

-- What the bot needs, read by the launcher from SavedVariables (it can't run the addon's raid logic itself):
-- { at, me, guild, dc = { host, guild, teams }, teams = { [id] = name },
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
    -- the linked characters and their alts: class, specs, the spec they last signed up with (the bot's spec picker)
    out.chars = {}
    local linked = type(DZBridgeInbox) == "table" and type(DZBridgeInbox.linked) == "table" and DZBridgeInbox.linked or {}
    for _, key in ipairs(linked) do
        local list = { key }
        for _, alt in ipairs(G and G.GetLinkedCharacters and G:GetLinkedCharacters(key) or {}) do list[#list + 1] = alt end
        local alts = {}
        for _, k in ipairs(list) do
            local class = G and G.GetClass and G:GetClass(k)
            if class and ns.SPECS[class] and not out.chars[k] then
                local specs = {}
                for i, sp in ipairs(ns.SPECS[class]) do specs[i] = sp.label end
                out.chars[k] = { class = class, specs = specs, last = RP:GetLastSpec(k) }
            end
            if out.chars[k] then alts[#alts + 1] = k end
        end
        if out.chars[key] then out.chars[key].alts = alts end
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

function Bridge:OnInit()
    if ns.Comm then
        ns.Comm:Register("BLK", OnLinkClaim)
        ns.Comm:Register("BLA", OnLinkAck)
    end
    ns:RegisterSlash("link", SlashLink, "link your character to the guild's Discord (/link in Discord gives the code)")
    -- a pending code goes out when the host comes online (the roster says so)
    ns:On("ROSTER_UPDATED", function() ns.Util.Debounce("bridge-link", 5, function() Bridge:DeliverLink() end) end)
end

function Bridge:OnLogin()
    C_Timer.After(15, function() Bridge:DeliverLink() end)
    local inbox = DZBridgeInbox
    if type(inbox) ~= "table" then return end   -- not the host (no DisasterZone_Bridge folder)
    local db = DB()
    self:Prune(inbox, db.applied)
    local n = self:Apply(inbox, db.applied)
    db.loaded, db.inbox = time(), inbox.written
    if type(db.claims) == "table" then
        for code, c in pairs(db.claims) do
            if type(c) ~= "table" or (c.t or 0) < time() - LINK_DAYS * 86400 then db.claims[code] = nil end
        end
    end
    if n > 0 then ns:Print("Loaded %d update%s from Discord.", n, n == 1 and "" or "s") end
    -- (saved variables are written at logout / reload: the snapshot is made then, on the host's PC only)
    ns:RegisterEvent("PLAYER_LOGOUT", function()
        local ok, snap = pcall(Bridge.Snapshot, Bridge)
        DB().snap = ok and snap or { at = time(), error = tostring(snap) }
    end)
end

-- A sign-up given in Discord: body { raid, key, st = "A"|"T"|"X", sp }.
Bridge:RegisterType("signup", function(r)
    local b = type(r.body) == "table" and r.body or {}
    if not ns.RaidPlan then return false, "raid plans not loaded" end
    return ns.RaidPlan:SignUpFor(b.raid, b.key, b.st, tonumber(b.sp))
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

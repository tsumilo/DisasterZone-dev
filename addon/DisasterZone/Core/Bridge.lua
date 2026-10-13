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
--                  channels = { { id = "<snowflake>", name = "raids" }, ... } (the Discord server's text channels) }
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
    if n > 0 then ns:Print("Loaded %d update%s from Discord.", n, n == 1 and "" or "s") end
    -- (saved variables are written at logout / reload: the snapshot is made then, on the host's PC only)
    ns:RegisterEvent("PLAYER_LOGOUT", function()
        local ok, snap = pcall(Bridge.Snapshot, Bridge)
        DB().snap = ok and snap or { at = time(), error = tostring(snap) }
    end)
end

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

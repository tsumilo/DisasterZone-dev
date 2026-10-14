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

---------------------------------------------------------------------------
-- BiS edits from Discord: record "bis" { name, phase, sid, item (0 = clear), which = "main"|"alt" }. The host's
-- addon routes each one:
--   my own character      -> my list (BiS:SetSlot)
--   a member with the addon (Sync:GetPeer) -> db.bisOut[key] = { { id, p, s, i, w }, ... }, whispered to them while
--                            they are online (BDE { e }); their addon applies it to its own list and answers (BDA { ids })
--   a member without it   -> the host keeps their list (a Store copy, shared with the council like any list)
---------------------------------------------------------------------------

local function Pending()
    local db = DB()
    db.bisOut = type(db.bisOut) == "table" and db.bisOut or {}
    return db.bisOut
end

function Bridge:DeliverBis()
    if not AmHost() or not ns.Comm then return end
    for key, list in pairs(Pending()) do
        if #list == 0 then Pending()[key] = nil
        elseif ns.Guild:IsOnline(key) then ns.Comm:Send({ t = "BDE", e = list }, "WHISPER", key, "data") end
    end
end

-- A list the host keeps for a member without the addon: one slot changed (the council's copy, a higher rev).
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

Bridge:RegisterType("bis", function(r)
    local b = type(r.body) == "table" and r.body or {}
    local key = Bridge:FindMember(b.name)
    if not key then return false, tostring(b.name) .. " is not in the guild." end
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
        return true
    end
    if ns.Sync and ns.Sync.GetPeer and ns.Sync:GetPeer(key) then
        local list = Pending()[key] or {}
        list[#list + 1] = { id = r.id, p = phase, s = sid, i = item, w = which, l = b.list == "os" and "os" or nil }
        Pending()[key] = list
        Bridge:DeliverBis()
        return true
    end
    return EditHostList(key, phase, sid, item, which, list)
end)

-- BDE { e = { { id, p, s, i, w }, ... } }: my list changed in Discord (from the Discord host only).
local function OnBisEdits(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg.e) ~= "table" or not ns.Guild:IsDiscordHost(sender) then return end
    local done, changed = {}, 0
    for i = 1, 40 do
        local e = msg.e[i]
        if type(e) ~= "table" then break end
        local p, s, item = tonumber(e.p), tonumber(e.s), tonumber(e.i) or 0
        if type(e.id) == "string" and p and s then
            local l = e.l == "os" and "os" or nil
            if l and not ns.BiS:HasOffSpec() then ns.BiS:AddOffSpec("") end
            if ns.BiS:SetSlot(p, s, e.w == "alt" and "alt" or "main", item, l) then changed = changed + 1 end
            done[#done + 1] = e.id
        end
    end
    if changed > 0 then
        ns.BiS:Commit()
        ns:Print("Your BiS list was changed in Discord (%d slot%s).", changed, changed == 1 and "" or "s")
    end
    if #done > 0 then ns.Comm:Send({ t = "BDA", ids = done }, "WHISPER", sender, "ctrl") end
end

-- BDA { ids }: a member's addon took these edits.
local function OnBisAck(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg.ids) ~= "table" or not AmHost() then return end
    local list = Pending()[sender]
    if not list then return end
    local took = {}
    for _, id in ipairs(msg.ids) do took[id] = true end
    for i = #list, 1, -1 do
        if took[list[i].id] then table.remove(list, i) end
    end
    if #list == 0 then Pending()[sender] = nil end
end

function Bridge:OnInit()
    if ns.Comm then
        ns.Comm:Register("DCL", OnLinks)
        ns.Comm:Register("BDE", OnBisEdits)
        ns.Comm:Register("BDA", OnBisAck)
    end
    if linksSync then linksSync.Register() end
    ns:On("ROSTER_UPDATED", function() ns.Util.Debounce("bridge-bis", 10, function() Bridge:DeliverBis() end) end)
end

---------------------------------------------------------------------------
-- Snapshot
---------------------------------------------------------------------------

local SNAP_BACK, SNAP_AHEAD = 6 * 3600, 14 * 86400
local ST_WORD = { A = "accept", T = "tentative", B = "bench", X = "absent" }

-- What the bot needs, read by the launcher from SavedVariables (it can't run the addon's raid logic itself):
-- { at, me, guild, dc = { host, guild, teams }, teams = { [id] = name }, roster = { { key, class }, ... },
--   phase, bis = { [key] = { spec, slots = { { sid, slot, id, name, got, alt, altName, altGot }, ... } } }
--   (the lists I hold, this phase: main pick and alternative),
--   raids = { { id, t, name, title, note, size, teams = { id, ... }, locked, cancelled, leader,
--               signups = { { key, st = "accept"|..., class, spec, role, guest }, ... } }, ... } }
-- Private raids are left out: the bot posts in public channels.
function Bridge:Snapshot()
    local RP, G, Util = ns.RaidPlan, ns.Guild, ns.Util
    local now = Util.Now()
    local d = G and G.GetDiscord and G:GetDiscord() or {}
    local out = { at = now, me = Util.PlayerKey(), guild = G and G.GetGuildKey and G:GetGuildKey() or nil,
                  dc = { host = d.host, guild = d.guild, week = d.week, loot = d.loot, teams = d.teams or {} },
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
                out.bis[key] = { class = data.cl ~= "" and data.cl or (G and G.GetClass and G:GetClass(key)) or nil,
                                 spec = data.sp ~= "" and data.sp or nil, ph = ms or {},
                                 os = data.os and data.os ~= "" and data.os or (os and "Off spec") or nil, oph = os,
                                 slots = ms and ms[tostring(phase)] or {} }
            end
        end
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
            out.raids[#out.raids + 1] = {
                id = v.id, t = v.t, name = RP:GetRaidName(v), title = v.ti, note = v.no, size = v.sz,
                teams = v.tm or {}, locked = v.lk or nil, cancelled = v.cancelled or nil,
                leader = RP.GetRaidLeader and RP:GetRaidLeader(v.id) or nil, signups = su, need = need,
                inst = v.i,
            }
        end
    end
    return out
end

function Bridge:OnLogin()
    local inbox = DZBridgeInbox
    if type(inbox) ~= "table" then return end   -- not the host (no DisasterZone_Bridge folder)
    -- (records name guild members: they wait for the guild roster, which comes in a moment after login)
    local applied = false
    local function apply()
        if applied or not (ns.Guild and ns.Guild.IsReady and ns.Guild:IsReady()) then return end
        applied = true
        local db = DB()
        Bridge:Prune(inbox, db.applied)
        local n = Bridge:Apply(inbox, db.applied)
        db.loaded, db.inbox = time(), inbox.written
        db.claims = nil   -- (1.4.2 dev builds linked with codes)
        if n > 0 then ns:Print("Loaded %d update%s from Discord.", n, n == 1 and "" or "s") end
    end
    apply()
    ns:On("ROSTER_UPDATED", apply)
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
    local me = ns.Util.PlayerKey()
    if me and (me:lower() == want or (short and me:lower():match("^([^%-]+)") == want)) then return me end
    for _, key in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        local k = key:lower()
        if k == want or (short and k:match("^([^%-]+)") == want) then return key end
    end
    return nil
end

-- A sign-up given in Discord: body { raid, name, class, sp, st = "A"|"T"|"X", note }  (note: "late 15 min" from a
-- reminder's Running late; absent = the note stays as it was). A guild member signs up as
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
        return RP:SignUpFor(b.raid, key, b.st, sp, type(b.note) == "string" and b.note or nil)
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

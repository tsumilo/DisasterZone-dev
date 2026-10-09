if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/Party.lua", ...) then return end -- DisasterZone Games/Disastercraft/Party.lua
-- Craft.Party: Disastercraft together - one world for the whole guild, like WoW's.
--
-- Everyone playing tells the guild, about once a second while something happens (every ten seconds otherwise),
-- where they are (the last second's path in four steps), how they are (health, mana, level, gear, target, cast,
-- auras) and the creatures they run (DCS on the "craft" prefix). What they do goes out apart (DCE on "craftev",
-- at most once a second): casts begun, finished and broken, hits, heals, auras, kills. The rest - parties, chat,
-- loot - on the shared "game" prefix (DCP, DCC, DCL). The server lets about one message a second through per
-- prefix: hence the batching, and the small numbers (positions in hundredths of a tile).
--
-- Creatures: idle ones are the same for everyone without a word (World.IdlePos: spawn + realm clock). One that
-- fights is run by one client - whoever pulled it (it aggroed on them, or they hit it first): rec.owner. The owner
-- runs its brain, applies the damage done to it, rolls its loot and tells everyone its state and its death; the
-- others show what they hear and send their hits to the owner (WoW's tapping: the first to hurt it tags it for
-- their party). Two who pull at once: the earlier claim keeps it, the other hands over (and sends what it dealt).
-- An owner gone silent for a few seconds lets go: the creature goes home.
--
-- Players: each client owns its own hero. A remote hero is a unit of kind "remote" fed from its DCS; damage, heals
-- and auras for it go to its client, which applies them and tells everyone the result.
--
-- Parties (WoW's): up to five; the leader invites, kicks and promotes; leaving hands the lead on. A party shares
-- the kill's experience (WoW's group formula, Loot.KillXP), its quest credit and its loot (free for all; quest
-- drops for everyone who needs them; money split among the members near the kill). Party chat, say and emotes.
local addonName, ns = ...

local Craft = ns.Craft
local D = Craft.D
local Combat = Craft.Combat
local Party = {}
Craft.Party = Party

local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt
local Now = Craft.Now

Party.TICK = 1.0                -- seconds between state messages while something happens
Party.HEARTBEAT = 10            -- ... and while nothing does
Party.SAMPLE = 0.25             -- a path point every this many seconds
Party.DELAY = 1.1               -- a remote hero is shown this far behind what it sent (its path plays smoothly)
Party.TIMEOUT = 25              -- a player not heard from this long is gone
Party.OWNER_TIMEOUT = 6         -- a creature's owner not heard from this long lets go of it
Party.MAX = 5
Party.SAY_RANGE = 25            -- yards: /say and emotes reach this far

Party.peers = {}                -- key -> { key, name, class, level, sex, seen, party, ... }: everyone playing
Party.group = nil               -- { id, leader, members = { key, ... } } or nil (alone)
Party.invite = nil              -- a pending invite to me: { from, id, at }

local events = {}               -- this client's events waiting for the next DCE
local samples = {}              -- this second's path points
local sampleAt, stateAt, eventsAt, lastSent = 0, 0, 0, 0
local lastPos, lastGear, sentFull

local function Me() return ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey() or "me" end
Party.Me = Me
local function Short(key) return ns.Util and ns.Util.ShortName and ns.Util.ShortName(key) or key end

local function Comm() return ns.Comm end

-- a unit's player key (heroes: "P:<key>"), or nil
local function KeyOf(u)
    if not u or not u.guid then return nil end
    return u.guid:match("^P:(.+)$")
end
Party.KeyOf = KeyOf

local function Int(v) return floor(v * 100 + 0.5) end
local function Unint(v) return (tonumber(v) or 0) / 100 end

---------------------------------------------------------------------------
-- The party
---------------------------------------------------------------------------

function Party.InParty() return Party.group ~= nil end

-- is player key `key` in my party (me included)?
function Party.HasMember(key)
    local g = Party.group
    if not g then return key == Me() end
    for _, k in ipairs(g.members) do if k == key then return true end end
    return false
end

-- unit u (a hero) is in my party (me excluded)
function Party.IsMember(u)
    local k = KeyOf(u)
    return k ~= nil and k ~= Me() and Party.group ~= nil and Party.HasMember(k)
end

-- the party id of a hero (for a creature's tag)
function Party.IdOf(u)
    local k = KeyOf(u)
    if not k then return nil end
    if k == Me() then return Party.group and Party.group.id end
    local peer = Party.peers[k]
    return peer and peer.party
end

-- a creature tagged by guid `tapper`: is that me or someone in my party?
function Party.InMyParty(tapper)
    local k = tapper and tapper:match("^P:(.+)$")
    return k ~= nil and Party.HasMember(k)
end

function Party.IsLeader() return Party.group == nil or Party.group.leader == Me() end

-- the party's heroes within yd of creature u (alive or dead, as WoW's kill share), me included when I am
function Party.MembersNear(u, yd)
    local out = {}
    local p = Craft.player
    if not p then return out end
    if not Party.group then return { p } end
    for _, k in ipairs(Party.group.members) do
        local m = (k == Me()) and p or Combat.units["P:" .. k]
        if m and m.map == u.map and not m.ghost and Craft.UnitDist(m, u) <= yd then out[#out + 1] = m end
    end
    return out
end

-- the heroes of my party in this world (me first), for the party frames
function Party.Members()
    local out = {}
    if not Party.group then return out end
    for _, k in ipairs(Party.group.members) do
        if k ~= Me() then out[#out + 1] = { key = k, unit = Combat.units["P:" .. k], peer = Party.peers[k] } end
    end
    return out
end

local function SendParty(msg)
    msg.t = "DCP"
    local C = Comm()
    if C then C:Send(msg, "GUILD", nil, "game") end
end

local function SetGroup(g)
    Party.group = g
    if g and #g.members <= 1 then Party.group = nil end
    Craft:Emit("party")
end

-- the leader tells the party who is in it
local function Roster()
    local g = Party.group
    if not g or g.leader ~= Me() then return end
    SendParty({ op = "roster", id = g.id, leader = g.leader, members = g.members })
end

-- finds a player by their hero's name or their WoW name (the closest match), among those playing
local function FindPlayer(name)
    if not name or name == "" then return nil end
    local lname = name:lower()
    for k, peer in pairs(Party.peers) do
        if (peer.name and peer.name:lower() == lname) or Short(k):lower() == lname or k:lower() == lname then return k end
    end
    return nil
end
Party.FindPlayer = FindPlayer

-- /invite name, or a right-click on a hero
function Party.Invite(who)
    local key = type(who) == "table" and KeyOf(who) or FindPlayer(who)
    if not key then Craft:Error(type(who) == "string" and who ~= "" and ("Cannot find player '" .. who .. "'.") or "No player to invite.") return false end
    if key == Me() then Craft:Error("You can't invite yourself.") return false end
    local g = Party.group
    if g and g.leader ~= Me() then Craft:Error("You are not the party leader.") return false end
    if g and #g.members >= Party.MAX then Craft:Error("Your party is full.") return false end
    if Party.HasMember(key) and g then Craft:Error(Party.NameOf(key) .. " is already in your party.") return false end
    local peer = Party.peers[key]
    if peer and peer.party and peer.party ~= (g and g.id) then
        Craft:Error(Party.NameOf(key) .. " is already in a group.") return false
    end
    if not g then
        g = { id = Me() .. ":" .. floor(Craft.Time()), leader = Me(), members = { Me() } }
        Party.group = g
        Party.pendingSolo = true
    end
    SendParty({ op = "inv", id = g.id, to = key, n = Craft.char and Craft.char.name })
    Craft:Msg("You have invited " .. Party.NameOf(key) .. " to join your group.", "system")
    return true
end

function Party.NameOf(key)
    local peer = Party.peers[key]
    if key == Me() then return Craft.char and Craft.char.name or Short(key) end
    return peer and peer.name or Short(key)
end

function Party.AcceptInvite()
    local inv = Party.invite
    Party.invite = nil
    if not inv then return end
    if Party.group then Party.Leave(true) end
    SendParty({ op = "acc", id = inv.id, to = inv.from })
    Craft:Emit("partyinvite", nil)
end

function Party.DeclineInvite()
    local inv = Party.invite
    Party.invite = nil
    if not inv then return end
    SendParty({ op = "dec", id = inv.id, to = inv.from })
    Craft:Emit("partyinvite", nil)
end

function Party.Leave(quiet)
    local g = Party.group
    if not g then
        if not quiet then Craft:Error("You aren't in a party.") end
        return
    end
    SendParty({ op = "leave", id = g.id })
    if not quiet then Craft:Msg("You leave the group.", "system") end
    SetGroup(nil)
end

function Party.Kick(key)
    local g = Party.group
    if not g or g.leader ~= Me() or key == Me() then return end
    for i, k in ipairs(g.members) do
        if k == key then
            table.remove(g.members, i)
            SendParty({ op = "kick", id = g.id, who = key })
            Craft:Msg(Party.NameOf(key) .. " has been removed from the group.", "system")
            Roster()
            SetGroup(g)
            return
        end
    end
end

function Party.Promote(key)
    local g = Party.group
    if not g or g.leader ~= Me() or not Party.HasMember(key) then return end
    g.leader = key
    SendParty({ op = "roster", id = g.id, leader = key, members = g.members, by = Me() })
    Craft:Msg(Party.NameOf(key) .. " is now the group leader.", "system")
    SetGroup(g)
end

local function OnParty(sender, m)
    local g = Party.group
    local me = Me()
    if m.op == "inv" then
        if m.to ~= me or not Craft.player then return end
        if g then SendParty({ op = "busy", id = m.id, to = sender }) return end
        Party.invite = { from = sender, id = m.id, at = Now(), name = m.n }
        Craft:Emit("partyinvite", Party.invite)
    elseif m.op == "acc" then
        if m.to ~= me or not g or g.id ~= m.id or g.leader ~= me then return end
        if #g.members >= Party.MAX then return end
        if not Party.HasMember(sender) then g.members[#g.members + 1] = sender end
        Party.pendingSolo = nil
        Craft:Msg(Party.NameOf(sender) .. " joins the party.", "system")
        Roster()
        SetGroup(g)
    elseif m.op == "dec" or m.op == "busy" then
        if m.to ~= me then return end
        Craft:Msg(Party.NameOf(sender) .. (m.op == "busy" and " is already in a group." or " declines your group invitation."), "system")
        if g and Party.pendingSolo and #g.members <= 1 then SetGroup(nil) end
    elseif m.op == "roster" then
        if type(m.members) ~= "table" then return end
        local inIt = false
        for _, k in ipairs(m.members) do if k == me then inIt = true end end
        -- (only the party's leader - or the one handing the lead on - speaks for it)
        if g and g.id == m.id and sender ~= g.leader then return end
        if not inIt then
            if g and g.id == m.id then SetGroup(nil) end
            return
        end
        if g and g.id ~= m.id then return end
        local was = g and g.leader
        local members = {}
        for i, k in ipairs(m.members) do if type(k) == "string" and i <= Party.MAX then members[#members + 1] = k end end
        local new = { id = m.id, leader = m.leader, members = members }
        if not g then Craft:Msg("You join " .. Party.NameOf(m.leader) .. "'s party.", "system") end
        if was and was ~= m.leader then Craft:Msg(Party.NameOf(m.leader) .. " is now the group leader.", "system") end
        SetGroup(new)
    elseif m.op == "leave" then
        if not g or g.id ~= m.id then return end
        for i, k in ipairs(g.members) do
            if k == sender then
                table.remove(g.members, i)
                Craft:Msg(Party.NameOf(sender) .. " leaves the party.", "system")
                break
            end
        end
        -- (the leader left: the next one takes over)
        if g.leader == sender then
            g.leader = g.members[1]
            if g.leader == me then Roster() end
        elseif g.leader == me then
            Roster()
        end
        SetGroup(g)
    elseif m.op == "kick" then
        if not g or g.id ~= m.id or sender ~= g.leader then return end
        if m.who == me then
            Craft:Msg("You have been removed from the group.", "system")
            SetGroup(nil)
        end
    end
end

---------------------------------------------------------------------------
-- Chat
---------------------------------------------------------------------------

-- what I say goes out: party chat to the party, say and emotes to those near
function Party.Chat(kind, msg)
    local p = Craft.player
    if not p or not msg or msg == "" then return end
    if kind == "party" and not Party.group then Craft:Error("You aren't in a party.") return end
    local C = Comm()
    if not C then return end
    C:Send({ t = "DCC", k = kind, n = Craft.char.name, m = msg:sub(1, 255), x = Int(p.x), y = Int(p.y),
             pa = Party.group and Party.group.id }, "GUILD", nil, "game")
end

local function OnChat(sender, m)
    local p = Craft.player
    if not p or sender == Me() or type(m.m) ~= "string" then return end
    local name = (type(m.n) == "string" and m.n) or Short(sender)
    if m.k == "party" then
        if Party.group and m.pa == Party.group.id and Party.HasMember(sender) then
            Craft:Msg("[Party] " .. name .. ": " .. m.m, "party")
        end
        return
    end
    local d = Craft.Dist(p.x, p.y, Unint(m.x), Unint(m.y))
    if d > Party.SAY_RANGE then return end
    if m.k == "emote" then
        Craft:Msg(name .. " " .. m.m, "emote")
    else
        Craft:Msg(name .. " says: " .. m.m, "say")
        local u = Combat.units["P:" .. sender]
        if u then Craft:Emit("bubble", u, m.m) end
    end
end

---------------------------------------------------------------------------
-- Remote heroes
---------------------------------------------------------------------------

local function RemoteUnit(key, peer)
    local guid = "P:" .. key
    local u = Combat.units[guid]
    if u then return u end
    local c = { name = peer.name, class = peer.class, level = peer.level, sex = peer.sex, equip = peer.equip or {},
                spells = {} }
    u = { guid = guid, kind = "remote", name = peer.name, level = peer.level or 1, class = peer.class or 1, char = c,
          spells = c.spells, map = "world", x = peer.x or 0, y = peer.y or 0, face = peer.face or "down",
          path = {}, sex = peer.sex }
    Combat.Add(u)
    Combat.Recalc(u)
    u.hp = peer.hp or u.hpMax
    u.power = peer.power or u.powerMax
    Craft:Emit("remote", u, true)
    return u
end

Party.RemoteUnit = RemoteUnit                -- (for the test suites and the audit)

local function DropRemote(key)
    local u = Combat.units["P:" .. key]
    if u then
        Combat.Remove(u)
        Craft:Emit("remote", u, false)
    end
end

local FLAGS = { d = "dead", g = "ghost", s = "sitting", c = "inCombat" }

-- a remote hero's state, from its DCS
local function ApplyState(key, peer, m)
    local u = RemoteUnit(key, peer)
    u.name, u.level, u.class = peer.name, peer.level or u.level, peer.class or u.class
    local c = u.char
    c.name, c.level, c.class, c.sex = u.name, u.level, u.class, peer.sex
    local gearChanged = false
    if type(m.eq) == "table" then
        local eq = {}
        for slot, id in pairs(m.eq) do if tonumber(slot) and tonumber(id) then eq[tonumber(slot)] = tonumber(id) end end
        c.equip = eq
        gearChanged = true
    end
    if gearChanged or u.lastLevel ~= u.level then
        u.lastLevel = u.level
        Combat.Recalc(u)
    end
    u.hpMax = tonumber(m.H) or u.hpMax
    u.hp = min(u.hpMax, tonumber(m.h) or u.hp)
    u.powerMax = tonumber(m.W) or u.powerMax
    u.power = tonumber(m.w) or u.power
    u.powerType = tonumber(m.pt) or u.powerType
    local st = type(m.st) == "string" and m.st or ""
    for ch, field in pairs(FLAGS) do u[field] = st:find(ch, 1, true) and true or nil end
    u.inCombat = u.inCombat or false
    -- the path: points every SAMPLE seconds, played DELAY behind (a jump - a hearthstone, a long gap - is a jump)
    local now = Now()
    local pts = type(m.p) == "table" and m.p or { m.x, m.y }
    local n = floor(#pts / 2)
    for i = 1, n do
        local x, y = Unint(pts[2 * i - 1]), Unint(pts[2 * i])
        local at = now + Party.DELAY - (n - i) * Party.SAMPLE
        local last = u.path[#u.path]
        if last and at <= last.at then at = last.at + 0.05 end
        u.path[#u.path + 1] = { at = at, x = x, y = y }
    end
    while #u.path > 24 do table.remove(u.path, 1) end
    if m.f and Craft.FACE_ROW[m.f] then u.netFace = m.f end
    u.netE = tonumber(m.e)                         -- (its height in a building: the floor it stands on)
    u.target = type(m.tg) == "string" and Combat.units[m.tg] or nil
    u.party = m.pa
    -- (its auras, for the party frames and the target frame: spell ids, helpful first)
    if type(m.au) == "table" then u.netAuras = m.au end
end

local function Lerp(a, b, t) return a + (b - a) * t end

-- remote heroes walk their path
local function MoveRemotes(dt)
    local now = Now()
    for key, peer in pairs(Party.peers) do
        local u = Combat.units["P:" .. key]
        if u and u.path then
            local path = u.path
            -- drop points already passed (keep one behind now)
            while #path >= 2 and path[2].at <= now do table.remove(path, 1) end
            local a, b = path[1], path[2]
            local ox, oy = u.x, u.y
            if a and b and now >= a.at then
                local t = (now - a.at) / max(0.001, b.at - a.at)
                u.x, u.y = Lerp(a.x, b.x, t), Lerp(a.y, b.y, t)
            elseif a and now >= a.at then
                u.x, u.y = a.x, a.y
            end
            local dx, dy = u.x - ox, u.y - oy
            local moved = sqrt(dx * dx + dy * dy)
            if moved > 0.15 then                          -- (a jump: no walking through the world)
                u.moving = false
            else
                u.moving = moved > 0.0005
                if u.moving then u.face = Craft.FaceOf(dx, dy) end
            end
            if not u.moving and u.netFace then u.face = u.netFace end
            Craft.World.Settle(u, u.netE)
        end
    end
end

---------------------------------------------------------------------------
-- Creatures run by someone else
---------------------------------------------------------------------------

local STATES = { [0] = "idle", [1] = "combat", [2] = "evade", [3] = "flee", [4] = "return" }
local STATE_CODE = { idle = 0, combat = 1, evade = 2, flee = 3, ["return"] = 4 }

function Party.Owner(rec) return rec and rec.owner end
-- does this client run creature rec? (no one does an idle one: everyone shows it the same)
function Party.OwnsRec(rec)
    return not rec or not rec.owner or rec.owner == Me()
end

-- a creature fight this client starts: it is mine (unless someone else runs it already)
function Party.Claim(rec)
    if not rec then return true end
    if rec.owner and rec.owner ~= Me() then return false end
    if not rec.owner then
        rec.owner = Me()
        rec.claimT = Craft.World.Clock()
        rec.netAt = Now()
    end
    return true
end

-- let go of creature rec (it went home, or I left)
function Party.Release(rec)
    if rec and rec.owner == Me() then
        rec.owner, rec.claimT = nil, nil
        rec.sentIdle = true
    end
end

local function MobUnit(g) local rec = Craft.World.recs["C:" .. tostring(g)] return rec, rec and rec.unit end

-- an owner's word on its creature
local function ApplyMob(sender, e)
    local g, hp, x, y, fi, st = e[1], e[2], e[3], e[4], e[5], e[6]
    local rec, u = MobUnit(g)
    if not rec or not u then return end
    local me = Me()
    if rec.owner == me then
        -- two claims: the earlier keeps it (a tie: the lower key); the other hands over what it dealt
        local theirs, mine = tonumber(e[9]) or 0, rec.claimT or 0
        if mine < theirs or (mine == theirs and me < sender) then return end
        local dealt = rec.myDealt or 0
        rec.owner, rec.myDealt = sender, 0
        if dealt > 0 and Craft.player then
            Party.Event({ "dm", Craft.player.guid, u.guid, dealt, "melee", 1 })
        end
    end
    if u.dead then return end
    rec.owner = sender
    rec.netAt = Now()
    local state = STATES[tonumber(st) or 0] or "combat"
    if state == "idle" then
        -- (the owner is done with it: everyone walks it home and it wanders as before)
        rec.owner, rec.claimT = nil, nil
        rec.state = "return"
        u.inCombat, u.target, u.threat = false, nil, {}
        return
    end
    rec.state = state
    u.level = tonumber(e[7]) or u.level
    u.hpMax = tonumber(e[8]) or u.hpMax
    u.hp = min(u.hpMax, max(1, tonumber(hp) or u.hp))
    rec.netX, rec.netY = Unint(x), Unint(y)
    rec.netFace = Craft.FACES[(tonumber(fi) or 0) + 1]
    u.target = type(e[10]) == "string" and Combat.units[e[10]] or nil
    u.inCombat = true
    u.tapper = type(e[11]) == "string" and e[11] ~= "" and e[11] or u.tapper
    u.tapParty = e[12] or u.tapParty
end

-- creatures run elsewhere glide to where their owner said (a run's worth a second)
local function MoveMobs(dt)
    local now = Now()
    for _, rec in pairs(Craft.World.recs) do
        local u = rec.unit
        if u and rec.owner and rec.owner ~= Me() then
            if now - (rec.netAt or 0) > Party.OWNER_TIMEOUT then
                -- (its owner went quiet: it gives up the fight and goes home)
                rec.owner = nil
                if not u.dead then Craft.World.Evade(u) end
            elseif rec.netX and not u.dead then
                local dx, dy = rec.netX - u.x, rec.netY - u.y
                local d = sqrt(dx * dx + dy * dy)
                if d > 6 then
                    u.x, u.y = rec.netX, rec.netY
                    u.moving = false
                elseif d > 0.02 then
                    local step = min(d, max(d * dt * 3, Craft.RUN_SPEED / Craft.YARDS * dt))
                    u.x, u.y = u.x + dx / d * step, u.y + dy / d * step
                    u.moving = true
                    u.face = Craft.FaceOf(dx, dy)
                else
                    u.moving = false
                    if rec.netFace then u.face = rec.netFace end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Events: what this client does that others must know (or apply)
---------------------------------------------------------------------------

function Party.Event(e)
    if not Craft.player then return end
    events[#events + 1] = e
    if #events > 60 then table.remove(events, 1) end
end

-- is unit u ours to tell others about? (my hero, a creature I run)
local function Ours(u)
    return u and (u.kind == "player" or (Combat.IsCreature(u) and u.rec and u.rec.owner == Me()))
end

local function Others()
    for _ in pairs(Party.peers) do return true end
    return false
end

-- Combat's hooks (Combat.Net): called for units of mine acting, and for my hits on units of others
local Net = {}
Combat.Net = Net

function Net.Cast(u, id, target, castTime, channel)
    if not Ours(u) or not Others() then return end
    if castTime and castTime > 0 then
        Party.Event({ "c", u.guid, id, target and target.guid or "", floor(castTime * 100), channel and 1 or 0 })
    else
        Party.Event({ "ci", u.guid, id })
    end
end

function Net.CastDone(u, id, target)
    if not Ours(u) or not Others() then return end
    Party.Event({ "cd", u.guid, id, target and target.guid or "" })
end

local KINDS = { melee = 1, spell = 2, dot = 3, ranged = 4, hot = 5 }
local KIND_NAMES = { "melee", "spell", "dot", "ranged", "hot" }

-- damage on a unit someone else owns: it goes to its owner (who applies it); everyone sees it
function Net.Damage(src, dst, amount, info)
    if not Others() then return end
    if src and src.kind == "player" and dst.rec then dst.rec.myDealt = (dst.rec.myDealt or 0) + amount end
    Party.Event({ "dm", src and src.guid or "", dst.guid, amount, KINDS[info.kind] or 2, info.school or 1,
                  info.result or "", info.crit and 1 or 0, info.spell or 0 })
end

function Net.Heal(src, dst, amount, info)
    if not Others() then return end
    Party.Event({ "hl", src and src.guid or "", dst.guid, amount, info.spell or 0, info.crit and 1 or 0 })
end

-- an aura I put on a unit someone else owns (or my creature on a hero): its numbers, so theirs match
function Net.Aura(u, t, id, a)
    if not Others() or not a then return end
    local amts = {}
    for i, x in ipairs(a.fx) do amts[i] = floor((x.amount or 0) + 0.5) end
    Party.Event({ "au", u.guid, t.guid, id, a.helpful and 1 or 0, amts })
end

-- what my units do that shows for everyone (a hit by my hero on my own creature, my creature on my hero)
Craft:On("damage", function(src, dst, amount, info)
    if info and (info.net or info.display) then return end
    if not Others() or not dst then return end
    if Combat.Owns(dst) and (Ours(src) or Ours(dst)) then
        Party.Event({ "dm", src and src.guid or "", dst.guid, amount, KINDS[info.kind] or 2, info.school or 1,
                      info.result or "", info.crit and 1 or 0, info.spell or 0, 1 })
    end
end)

Craft:On("heal", function(src, dst, amount, info)
    if info and (info.net or info.display) then return end
    if not Others() or not dst or not Combat.Owns(dst) then return end
    if Ours(src) then Party.Event({ "hl", src and src.guid or "", dst.guid, amount, info.spell or 0, info.crit and 1 or 0, 1 }) end
end)

-- a creature of mine dies: everyone hears who killed it, its tag, and - for the tagging party - its loot
Craft:On("death", function(u, killer)
    if not u or u.netDeath or not Others() then return end
    if Combat.IsCreature(u) and u.rec and (u.rec.owner == Me() or not u.rec.owner) and (u.tapper or u.rec.owner) then
        local rec = u.rec
        local loot
        if rec.loot then
            loot = { rec.loot.money or 0 }
            for _, it in ipairs(rec.loot.items) do loot[#loot + 1] = { it.id, it.n, it.quest and 1 or 0 } end
        end
        local near = {}
        for _, m in ipairs(Party.MembersNear(u, 74)) do near[#near + 1] = KeyOf(m) end
        rec.lootNear = near
        Party.Event({ "dd", u.guid, killer and killer.guid or "", u.tapper or "", u.tapParty or "", loot, near })
        Party.Release(rec)
        rec.state = "dead"
    end
end)

-- a hero's damage, heal, aura from the net: applied when the unit is mine, shown otherwise
local function Display(kind, src, dst, amount, info)
    info.display = true
    Craft:Emit(kind, src, dst, amount, info)
end

local function OnEvents(sender, list)
    local p = Craft.player
    if not p or type(list) ~= "table" then return end
    local me = Me()
    for _, e in ipairs(list) do
        if type(e) == "table" then
            local kind = e[1]
            local src = type(e[2]) == "string" and Combat.units[e[2]] or nil
            if kind == "c" and src and src.kind ~= "player" then
                local tgt = Combat.units[e[4] or ""]
                local t = (tonumber(e[5]) or 0) / 100
                src.casting = { spell = e[3], target = tgt, start = Now(), ends = Now() + t, channel = e[6] == 1,
                                net = true, push = 0, opts = {} }
                Craft:Emit("cast", src, e[3], e[6] == 1 and "channel" or "start", tgt)
            elseif (kind == "cd" or kind == "ci") and src and src.kind ~= "player" then
                local c = src.casting
                src.casting = nil
                local tgt = Combat.units[e[4] or ""] or (c and c.target)
                if kind == "ci" then
                    Craft:Emit("cast", src, e[3], "interrupted", tgt)
                else
                    Craft:Emit("cast", src, e[3], "done", tgt)
                    -- (a missile flies for everyone to see; it lands where its caster's client says)
                    local sp = D.spells[e[3]]
                    if sp and sp.speed and sp.speed > 0 and tgt and tgt ~= src then
                        local m = { spell = e[3], src = src, dst = tgt, from = { src.x, src.y }, start = Now(),
                                    arrive = Now() + Craft.UnitDist(src, tgt) / sp.speed, opts = {}, net = true }
                        Combat.missiles[#Combat.missiles + 1] = m
                        Craft:Emit("missile", m)
                    end
                end
            elseif kind == "dm" or kind == "hl" then
                local dst = Combat.units[e[3] or ""]
                local amount = tonumber(e[4]) or 0
                if dst then
                    local info
                    if kind == "dm" then
                        info = { kind = KIND_NAMES[tonumber(e[5]) or 2], school = tonumber(e[6]) or 1,
                                 result = e[7] ~= "" and e[7] or nil, crit = e[8] == 1 or nil,
                                 spell = (tonumber(e[9]) or 0) > 0 and tonumber(e[9]) or nil }
                    else
                        info = { kind = "spell", spell = (tonumber(e[5]) or 0) > 0 and tonumber(e[5]) or nil,
                                 crit = e[6] == 1 or nil }
                    end
                    local done = e[10] == 1 or (kind == "hl" and e[7] == 1)
                    local mine = dst == p or (Combat.IsCreature(dst) and dst.rec and dst.rec.owner == me)
                    if not done and mine then
                        -- (mine: it lands here, and the result goes out with my state)
                        info.net = true
                        if kind == "dm" then
                            if info.result and amount == 0 then
                                Display("damage", src, dst, 0, info)
                                if Combat.IsCreature(dst) and src then Combat.AddThreat(dst, src, 0) end
                            else
                                Combat.Damage(src, dst, amount, info)
                            end
                        else
                            Combat.Heal(src, dst, amount, info)
                        end
                    elseif sender ~= me then
                        Display(kind == "dm" and "damage" or "heal", src, dst, amount, info)
                    end
                end
            elseif kind == "au" then
                local dst = Combat.units[e[3] or ""]
                if dst and src and not dst.dead then
                    local a = Combat.ApplyAura(src, dst, e[4], e[5] == 1)
                    if a then
                        a.net = true
                        for i, x in ipairs(a.fx) do
                            local v = type(e[6]) == "table" and tonumber(e[6][i])
                            if v then x.amount = v end
                        end
                        Combat.Recalc(dst)
                    end
                end
            elseif kind == "ar" then
                local dst = Combat.units[e[3] or ""]
                local a = dst and Combat.FindAura(dst, e[4])
                if a then Combat.RemoveAura(dst, a, "net") end
            elseif kind == "dd" then
                local u = Combat.units[e[2] or ""]
                if u and Combat.IsCreature(u) and not u.dead then
                    u.tapper = e[4] ~= "" and e[4] or u.tapper
                    u.tapParty = e[5] ~= "" and e[5] or u.tapParty
                    u.netDeath = true
                    if u.rec then u.rec.owner = nil end
                    Combat.Die(u, Combat.units[e[3] or ""])
                    u.netDeath = nil
                    -- (the tagging party's loot, as its owner rolled it)
                    if u.rec and type(e[6]) == "table" and Craft.Loot.Mine(u) then
                        local l = { money = tonumber(e[6][1]) or 0, items = {}, from = sender }
                        for i = 2, #e[6] do
                            local it = e[6][i]
                            if type(it) == "table" then
                                l.items[#l.items + 1] = { id = it[1], n = it[2] or 1, quest = it[3] == 1 or nil }
                            end
                        end
                        u.rec.loot = l
                        u.rec.lootNear = type(e[7]) == "table" and e[7] or {}
                        u.rec.corpseUntil = Now() + 300
                    end
                end
            elseif kind == "lt" then
                -- an item taken from a corpse (quest drops: each who needs one takes their own)
                local u = Combat.units[e[2] or ""]
                local l = u and u.rec and u.rec.loot
                local it = l and l.items[tonumber(e[3]) or 0]
                if it and not it.quest then it.taken = true Craft:Emit("lootupdate") end
                if l and e[4] == "money" then l.money = 0 Craft:Emit("lootupdate") end
            elseif kind == "share" then
                -- my share of a corpse's money
                local share = type(e[3]) == "table" and tonumber(e[3][me])
                if share and share > 0 then Craft:AddMoney(share, "loot") end
            elseif kind == "rs" then
                -- a resurrection for me
                if e[3] == me and p.dead then
                    Party.resOffer = { from = e[2], name = e[4], hp = tonumber(e[5]) or 0, at = Now() }
                    Craft:Emit("resoffer", Party.resOffer)
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Loot in a party: free for all - an item goes to whoever takes it first, quest drops to each who needs one, the
-- money split among the party members near the kill
---------------------------------------------------------------------------

-- Loot.Take's hook: true when handled here
function Party.TakeLoot(u, i, it)
    local l = u and u.rec and u.rec.loot
    if not l or not l.from or not Party.group then return false end
    -- (someone else's corpse: take it here; the owner hears and tells everyone it is gone)
    local left = Craft.Items.Add(it.id, it.n, "loot")
    if left >= it.n then return true end
    if not it.quest then it.taken = true end
    if it.quest then it.mineTaken = true it.taken = true end
    local C = Comm()
    if C then C:Send({ t = "DCL", op = "take", g = u.guid, i = i, to = l.from }, "GUILD", nil, "game") end
    return true
end

-- Loot.TakeMoney's hook: in a party, the money is split
function Party.SplitMoney(u, money)
    if not Party.group or not u or not u.rec then return false end
    local l = u.rec.loot
    local near = u.rec.lootNear or {}
    if #near <= 1 then return false end
    if l and l.from and l.from ~= Me() then
        local C = Comm()
        if C then C:Send({ t = "DCL", op = "money", g = u.guid, to = l.from }, "GUILD", nil, "game") end
        return true
    end
    Party.ShareMoney(u, money, near)
    return true
end

function Party.ShareMoney(u, money, near)
    local shares, each = {}, floor(money / #near)
    local rest = money - each * #near
    for i, k in ipairs(near) do shares[k] = each + (i == 1 and rest or 0) end
    Party.Event({ "share", u.guid, shares })
    Party.Event({ "lt", u.guid, 0, "money" })
    local mine = shares[Me()]
    if mine and mine > 0 then Craft:AddMoney(mine, "loot") end
end

local function OnLoot(sender, m)
    local p = Craft.player
    if not p or m.to ~= Me() then return end
    local u = Combat.units[m.g or ""]
    local l = u and u.rec and u.rec.loot
    if not l then return end
    if m.op == "take" then
        local i = tonumber(m.i)
        local it = i and l.items[i]
        if it and not it.quest then it.taken = true Craft:Emit("lootupdate") end
        Party.Event({ "lt", u.guid, i or 0 })
    elseif m.op == "money" then
        if (l.money or 0) > 0 then
            local money = l.money
            l.money = 0
            Party.ShareMoney(u, money, u.rec.lootNear or { sender })
            Craft:Emit("lootupdate")
        end
    end
end

-- someone resurrects my corpse: the popup (UI), accepting brings me back with their health
function Party.OfferResurrect(u, target, value)
    if target == Craft.player then return end
    local k = KeyOf(target)
    if not k then return end
    Party.Event({ "rs", u.guid, k, Craft.char and Craft.char.name or "", floor(value or 0) })
end

function Party.AcceptResurrect()
    local r = Party.resOffer
    Party.resOffer = nil
    local p = Craft.player
    if not r or not p or not p.dead then return end
    Craft.World.Revive(true)
    if r.hp > 0 then p.hp = min(p.hpMax, max(1, r.hp)) end
end

---------------------------------------------------------------------------
-- My state, sent
---------------------------------------------------------------------------

local function GearList(c)
    local out = {}
    for slot, id in pairs(c.equip or {}) do out[slot] = id end
    return out
end

local function GearKey(c)
    local ks = {}
    for slot = 1, 19 do ks[#ks + 1] = tostring(c.equip and c.equip[slot] or 0) end
    return table.concat(ks, ",")
end

local function MyMobs()
    local out = {}
    for _, rec in pairs(Craft.World.recs) do
        local u = rec.unit
        if u and rec.owner == Me() and not u.dead then
            local code = STATE_CODE[rec.state] or 1
            out[#out + 1] = { tonumber((u.guid:match("^C:(%d+)"))) or 0, floor(u.hp), Int(u.x), Int(u.y),
                              (Craft.FACE_ROW[u.face] or 0), code, u.level, u.hpMax, rec.claimT or 0,
                              u.target and u.target.guid or "", u.tapper or "", u.tapParty or "" }
            if code == 0 or code == 4 then
                -- (home again: this is the last word on it)
                out[#out][6] = 0
                Party.Release(rec)
            end
        end
    end
    return out
end

local function SendState(full)
    local p, c = Craft.player, Craft.char
    local C = Comm()
    if not p or not c or not C then return end
    local st = (p.dead and "d" or "") .. (p.ghost and "g" or "") .. (p.sitting and "s" or "") .. (p.inCombat and "c" or "")
    local m = { t = "DCS", v = 1, n = c.name, c = c.class, s = c.sex or 0, l = c.level, x = Int(p.x), y = Int(p.y),
                f = p.face, h = floor(p.hp), H = p.hpMax, w = floor(p.power or 0), W = p.powerMax, pt = p.powerType,
                st = st, tg = p.target and p.target.guid or nil, pa = Party.group and Party.group.id or nil,
                e = p.bld and p.e or nil, b = p.bld and p.bld.id or nil }
    if #samples > 0 then
        local pts = {}
        for _, s in ipairs(samples) do pts[#pts + 1] = s[1] pts[#pts + 1] = s[2] end
        m.p = pts
    end
    local gk = GearKey(c)
    if full or gk ~= lastGear then
        m.eq = GearList(c)
        lastGear = gk
    end
    local au = {}
    for _, a in ipairs(p.auras) do
        if not a.passive and #au < 16 then au[#au + 1] = a.helpful and a.spell or -a.spell end
    end
    if #au > 0 then m.au = au end
    local mobs = MyMobs()
    if #mobs > 0 then m.mo = mobs end
    if full then m.full = 1 end
    if Party.wantHello then m.hi = 1 Party.wantHello = nil end
    C:Send(m, "GUILD", nil, "craft")
    samples = {}
    lastSent = Now()
end

local function SendEvents()
    if #events == 0 then return end
    local C = Comm()
    if not C then events = {} return end
    -- (a message stays small: the server splits long ones into parts, each costing a message)
    local batch = {}
    for i = 1, min(#events, 12) do batch[i] = events[i] end
    for i = 1, #batch do table.remove(events, 1) end
    C:Send({ t = "DCE", v = 1, ev = batch }, "GUILD", nil, "craftev")
end

---------------------------------------------------------------------------
-- Received
---------------------------------------------------------------------------

local function Peer(key)
    local peer = Party.peers[key]
    if not peer then peer = { key = key } Party.peers[key] = peer end
    return peer
end

local function OnState(sender, m)
    if sender == Me() or type(m) ~= "table" then return end
    if m.bye then
        Party.peers[sender] = nil
        DropRemote(sender)
        Craft:Emit("peers")
        return
    end
    local peer = Peer(sender)
    local fresh = not peer.seen
    peer.seen = Now()
    peer.name = type(m.n) == "string" and m.n or peer.name
    peer.class, peer.level, peer.sex = tonumber(m.c) or peer.class, tonumber(m.l) or peer.level, tonumber(m.s) or peer.sex
    peer.party = m.pa
    peer.x, peer.y = Unint(m.x), Unint(m.y)
    peer.hp, peer.hpMax = tonumber(m.h), tonumber(m.H)
    if type(m.eq) == "table" then peer.equip = m.eq end
    if fresh then Craft:Emit("peers") end
    -- (someone new: they see me at once, not at my next heartbeat)
    if m.hi and Craft.player then stateAt = min(stateAt, Now() + 0.3 + math.random() * 0.7) sentFull = false end
    local p = Craft.player
    if not p then return end
    ApplyState(sender, peer, m)
    if type(m.mo) == "table" then
        for _, e in ipairs(m.mo) do if type(e) == "table" then ApplyMob(sender, e) end end
    end
end

---------------------------------------------------------------------------
-- The clock
---------------------------------------------------------------------------

local function Busy(p)
    if p.moving or p.inCombat or p.casting or #samples > 0 then return true end
    for _, rec in pairs(Craft.World.recs) do if rec.owner == Me() then return true end end
    return false
end

function Party.Update(dt)
    local now = Now()
    -- the gone (no word for TIMEOUT)
    for key, peer in pairs(Party.peers) do
        if now - (peer.seen or 0) > Party.TIMEOUT then
            Party.peers[key] = nil
            DropRemote(key)
            Craft:Emit("peers")
        end
    end
    local p = Craft.player
    if not p then return end
    MoveRemotes(dt)
    MoveMobs(dt)
    -- the leader gone: the next member takes over
    local g = Party.group
    if g and g.leader ~= Me() and not Party.peers[g.leader] and (now - (g.since or now)) > Party.TIMEOUT then
        for i, k in ipairs(g.members) do if k == g.leader then table.remove(g.members, i) break end end
        g.leader = g.members[1]
        if g.leader == Me() then Roster() end
        SetGroup(g)
    end
    if g then g.since = g.since or now end
    if not ns.Comm then return end
    -- my path, a point every SAMPLE seconds while I move
    if now >= sampleAt then
        sampleAt = now + Party.SAMPLE
        local x, y = Int(p.x), Int(p.y)
        if not lastPos or lastPos[1] ~= x or lastPos[2] ~= y then
            samples[#samples + 1] = { x, y }
            lastPos = { x, y }
            if #samples > 6 then table.remove(samples, 1) end
        end
    end
    if now >= stateAt then
        local busy = Busy(p)
        if busy or now - lastSent >= Party.HEARTBEAT or not sentFull then
            -- (my queue on this prefix still full: the next second)
            if (ns.Comm.Backlog and ns.Comm:Backlog("craft") or 0) == 0 then
                SendState(not sentFull or now - lastSent >= Party.HEARTBEAT)
                sentFull = true
            end
        end
        stateAt = now + Party.TICK
    end
    if now >= eventsAt and #events > 0 then
        if (ns.Comm.Backlog and ns.Comm:Backlog("craftev") or 0) == 0 then SendEvents() end
        eventsAt = now + Party.TICK
    end
end

-- entering the world: everyone hears of me now (and answers with theirs)
function Party.OnEnterWorld()
    sentFull, lastGear, lastPos, samples, events = false, nil, nil, {}, {}
    Party.wantHello = true
    stateAt, eventsAt, sampleAt = 0, 0, 0
    for key, peer in pairs(Party.peers) do
        if peer.seen and Now() - peer.seen < Party.TIMEOUT then RemoteUnit(key, peer) end
    end
end

-- leaving: they forget me, my creatures are let go, my party keeps going without me only when I quit it
function Party.OnLeaveWorld()
    for _, rec in pairs(Craft.World.recs) do
        if rec.owner == Me() and rec.unit and not rec.unit.dead then Craft.World.Evade(rec.unit) end
        if rec.owner == Me() then rec.owner = nil end
    end
    local C = Comm()
    if C and Craft.char then C:Send({ t = "DCS", v = 1, bye = 1 }, "GUILD", nil, "craft") end
    for key in pairs(Party.peers) do DropRemote(key) end
    events, samples = {}, {}
end

-- for the hub: who plays now (me too)
function Party.PlayingKeys()
    local out = {}
    if Craft.player then out[#out + 1] = Me() end
    for key, peer in pairs(Party.peers) do
        if peer.seen and Now() - peer.seen < Party.TIMEOUT then out[#out + 1] = key end
    end
    table.sort(out)
    return out
end

function Party.PlayingCount() return #Party.PlayingKeys() end

-- (Comm keeps the handlers until messages come: registered as the file loads)
if ns.Comm and ns.Comm.Register then
    local C = ns.Comm
    C:Register("DCS", function(sender, m) OnState(sender, m) end)
    C:Register("DCE", function(sender, m) if sender ~= Me() then OnEvents(sender, m.ev) end end)
    C:Register("DCP", function(sender, m) if sender ~= Me() then OnParty(sender, m) end end)
    C:Register("DCC", function(sender, m) OnChat(sender, m) end)
    C:Register("DCL", function(sender, m) if sender ~= Me() then OnLoot(sender, m) end end)
end

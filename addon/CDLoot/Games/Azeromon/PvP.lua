-- CDLoot Games/Azeromon/PvP.lua
-- ns.AzeroPvP: battles between guildmates. Lockstep: both clients run the same Battle from the same seed and
-- only exchange their chosen action each turn (see Battle.lua, "Player battles").
-- Whispers on the game prefix (CDLg):
--   AZC { id, v, seed, team }        challenge (with the challenger's team)
--   AZA { id, ok, why, team }        answer (with the defender's team when accepted)
--   AZM { id, turn, a }              my action for turn n
--   AZF { id }                       challenge withdrawn
-- Spectators (Watch.lua) ask either player; that player's client answers and then relays every turn:
--   AZW { op = "ask", v }            may I watch?                          (spectator -> player)
--   AZW { op = "leave" }             I stopped watching
--   AZV { op = "start", id, v, seed, p1, p2, t1, t2, log }  the match so far (p1 = challenger, t1/t2 = the teams
--                                    as sent, log = every resolved turn as "a1/a2", see P.EncodeAct)
--   AZV { op = "no", why }           "over" (no match any more) | "full" | "version"
--   AZV { op = "turn", id, n, a }    turn n resolved: a = "a1/a2"
-- Rules: both teams fully healed for the match and untouched afterwards (the battle uses copies), no items or
-- flasks (gear counts: it's part of the beast),
-- no exp or money, real levels. A player who does not act within TURN_TIMEOUT seconds forfeits.
local addonName, ns = ...

local P = ns:NewModule("AzeroPvP")
local G = ns.Azero
local D = ns.AzeroData
local M = ns.AzeroMon

P.VERSION = 1
P.ANSWER_TIMEOUT = 30
P.TURN_TIMEOUT = 60
P.MAX_WATCHERS = 10

local outgoing = nil       -- { id, to, at }            my open challenge
local match = nil          -- { id, opp, name, host, battle, since, seed, t1, t2, log, watchers }

local function Now() return GetTime() end
local function ShortName(key) return (Ambiguate and Ambiguate(key, "short")) or (key:match("^[^-]+") or key) end

local function Whisper(to, msg)
    return ns.Comm and ns.Comm:Send(msg, "WHISPER", to, "game")
end

---------------------------------------------------------------------------
-- Teams and the shared random numbers
---------------------------------------------------------------------------

-- The wire form of my party (species, level, ivs, move ids).
function P.PackTeam(party)
    local out = {}
    for i, mon in ipairs(party) do
        if i > D.MAX_PARTY then break end
        local moves = {}
        for j, mv in ipairs(mon.moves) do moves[j] = mv.id end
        local gear
        if type(mon.gear) == "table" then
            gear = {}
            for slot, id in pairs(mon.gear) do gear[slot] = id end
        end
        out[i] = { sp = mon.sp, lvl = mon.lvl, ivs = mon.ivs, moves = moves, shiny = mon.shiny or nil, gear = gear }
    end
    return out
end

-- Rebuilds a team for battle: validated, fully healed. nil when unusable.
function P.UnpackTeam(list)
    if type(list) ~= "table" then return nil end
    local team = {}
    for i = 1, math.min(#list, D.MAX_PARTY) do
        local t = list[i]
        if type(t) == "table" then
            local moves = {}
            if type(t.moves) == "table" then
                for j, id in ipairs(t.moves) do moves[j] = { id = id, pp = 99 } end
            end
            local ivs = {}
            for k = 1, 6 do ivs[k] = math.max(0, math.min(31, math.floor(tonumber(type(t.ivs) == "table" and t.ivs[k]) or 0))) end
            local mon = M.Sanitize({ sp = t.sp, lvl = t.lvl, ivs = ivs, moves = moves, hp = 1, shiny = t.shiny,
                                     gear = type(t.gear) == "table" and t.gear or nil })
            if mon then
                M.Heal(mon)
                team[#team + 1] = mon
            end
        end
    end
    if #team == 0 then return nil end
    return team
end

-- A small seeded generator (the same on every client), called like math.random(a, b).
function P.NewRng(seed)
    local s = math.floor(tonumber(seed) or 1) % 2147483648
    return function(a, b)
        s = (s * 1103515245 + 12345) % 2147483648
        local r = s / 2147483648
        if not b then a, b = 1, a end
        return a + math.floor(r * (b - a + 1))
    end
end

-- A resolved action as a few characters for spectators: "m2" (move 2, "m0" = struggle), "s3" (switch to 3), "f".
function P.EncodeAct(a)
    if a.kind == "forfeit" then return "f" end
    return (a.kind == "switch" and "s" or "m") .. tostring(math.floor(tonumber(a.idx) or 0))
end

function P.DecodeAct(code)
    if type(code) ~= "string" then return {} end
    if code == "f" then return { kind = "forfeit" } end
    local k, idx = code:match("^([ms])(%d)$")
    if not k then return {} end
    return { kind = k == "s" and "switch" or "move", idx = tonumber(idx) }
end

-- "a1/a2" -> the two actions (anything malformed becomes {}, which ValidPvP turns into a move).
function P.DecodeTurn(pair)
    local a1, a2 = (type(pair) == "string" and pair or ""):match("^([^/]*)/([^/]*)$")
    return P.DecodeAct(a1), P.DecodeAct(a2)
end

---------------------------------------------------------------------------
-- Challenging (called from the overworld script when pressing A on a player)
---------------------------------------------------------------------------

function P:Challenge(g, peer, asked)
    if not asked and not g:YesNo(string.format("Challenge %s to a battle?", peer.name)) then return end
    if not M.FirstUsable(g.save.party) then
        g:Say("You need a beast that can fight first.")
        return
    end
    local id = string.format("%d%04d", math.floor(Now() * 10) % 1000000, math.random(0, 9999))
    local seed = math.random(1, 2147483646)
    local team = P.PackTeam(g.save.party)
    outgoing = { id = id, to = peer.key, at = Now(), seed = seed, team = team }
    if not Whisper(peer.key, { t = "AZC", id = id, v = P.VERSION, seed = seed, team = team }) then
        outgoing = nil
        g:Say(peer.name .. " can't be reached right now.")
        return
    end
    local answer = g:Wait({ kind = "netwait", text = string.format("Waiting for %s to answer...\n(X to cancel)", peer.name) })
    local out = outgoing
    outgoing = nil
    if type(answer) == "table" and answer.ok then
        P:Play(g, out.id, peer.key, true, out.seed, answer.team, out.team)
        return
    end
    if answer == "cancel" then
        Whisper(peer.key, { t = "AZF", id = out.id })
        g:Say("You withdrew the challenge.")
    elseif answer == "timeout" then
        g:Say(peer.name .. " didn't answer.")
    elseif type(answer) == "table" and answer.why == "busy" then
        g:Say(peer.name .. " is busy right now.")
    else
        g:Say(peer.name .. " declined the battle.")
    end
end

local function OnChallenge(sender, msg)
    if type(msg.id) ~= "string" or msg.v ~= P.VERSION then
        if msg.v ~= P.VERSION then Whisper(sender, { t = "AZA", id = msg.id, ok = false, why = "version" }) end
        return
    end
    local busy = not G.started or not G:IsFree() or match ~= nil or outgoing ~= nil
        or not (ns.AzeroNet and ns.AzeroNet:IsActive()) or not M.FirstUsable(G.save.party)
    local theirTeam = P.UnpackTeam(msg.team)
    if busy or not theirTeam then
        Whisper(sender, { t = "AZA", id = msg.id, ok = false, why = "busy" })
        return
    end
    local name = ShortName(sender)
    local id, seed = msg.id, msg.seed
    P.incoming = { id = id, from = sender }
    G:Run(function(g)
        local yes = g:YesNo(string.format("%s challenges you to a battle! Accept?", name))
        local still = P.incoming and P.incoming.id == id
        P.incoming = nil
        if not still then
            g:Say(name .. " withdrew the challenge.")
            return
        end
        if not yes then
            Whisper(sender, { t = "AZA", id = id, ok = false, why = "no" })
            return
        end
        local team = P.PackTeam(g.save.party)
        Whisper(sender, { t = "AZA", id = id, ok = true, team = team })
        P:Play(g, id, sender, false, seed, msg.team, team)
    end)
end

local function OnAnswer(sender, msg)
    if not outgoing or msg.id ~= outgoing.id or sender ~= outgoing.to then return end
    if G.pending and G.pending.kind == "netwait" then G:Advance(msg) end
end

local function OnWithdraw(sender, msg)
    if P.incoming and P.incoming.id == msg.id and P.incoming.from == sender then
        P.incoming = nil
        -- the Yes/No prompt stays up; answering it then says the challenge was withdrawn
    end
end

---------------------------------------------------------------------------
-- The match
---------------------------------------------------------------------------

-- myTeamWire: my team exactly as the other side (and any spectator) received it. My side of the battle is
-- rebuilt from it the same way theirs is, so all copies of the match have the same beasts (gear included).
function P:Play(g, id, opp, host, seed, theirTeamWire, myTeamWire)
    local foes = P.UnpackTeam(theirTeamWire)
    local mine = P.UnpackTeam(myTeamWire)
    if not foes or not mine then
        g:Say("Something went wrong with the other team. The battle was called off.")
        return
    end
    local name = ShortName(opp)
    -- the seed is the challenger's; both sides use it, so every roll matches
    local b = ns.AzeroBattle.New({
        party = mine, foes = foes, rng = P.NewRng(seed),
        onSeen = function(sp) g.save.seen[sp] = true g:Emit("seen", { sp = sp }) end,
        pvp = { host = host, name = name, onAction = function(a)
            Whisper(opp, { t = "AZM", id = id, turn = match and match.battle.turn + 1 or 1, a = a })
            if match then match.since = Now() end
        end, onResolve = function(a1, a2) P:Relay(a1, a2) end },
    })
    local me = ns.Util.PlayerKey() or "?"
    match = { id = id, opp = opp, name = name, host = host, battle = b, since = Now(), early = {}, seed = seed,
              p1 = host and me or opp, p2 = host and opp or me,
              t1 = host and myTeamWire or theirTeamWire, t2 = host and theirTeamWire or myTeamWire,
              log = {}, watchers = {} }
    g.battle = b
    local result = g:Wait({ kind = "battle", battle = b }) or b.result
    g.battle = nil
    match = nil               -- spectators already have the last turn, and end on it by themselves
    local rec = g:Data()
    if type(rec.pvp) ~= "table" then rec.pvp = {} end
    local r = rec.pvp[opp] or { w = 0, l = 0, d = 0 }
    if result == "win" then r.w = r.w + 1 elseif result == "lose" then r.l = r.l + 1 else r.d = r.d + 1 end
    rec.pvp[opp] = r
    g:Emit("pvp", { result = result, opp = opp })
    g:Say(string.format("Your record against %s: %d won, %d lost, %d drawn.", name, r.w, r.l, r.d))
end

local function OnMove(sender, msg)
    if not match or msg.id ~= match.id or sender ~= match.opp then return end
    local b = match.battle
    local turn = tonumber(msg.turn)
    if turn ~= b.turn + 1 then return end
    if b:ReceivePvP(msg.a) then match.since = Now() end
end

-- Timeouts (called every frame by the UI, and by the tests).
function P:Update()
    local now = Now()
    if outgoing and now - outgoing.at > P.ANSWER_TIMEOUT and G.pending and G.pending.kind == "netwait" then
        G:Advance("timeout")
    end
    if match then
        local b = match.battle
        if b.need ~= match.lastNeed then            -- the clock restarts whenever the battle's state changes
            match.lastNeed, match.since = b.need, now
        end
        if b.need == "wait" and now - match.since > P.TURN_TIMEOUT then
            b:ReceivePvP({ kind = "forfeit" })            -- they never answered: they forfeit
        elseif b.need == "action" and not b.theirs and now - match.since > P.TURN_TIMEOUT then
            b:Act({ kind = "forfeit" })                   -- I never chose: I forfeit (they see the same)
        end
    end
end

---------------------------------------------------------------------------
-- Spectators
---------------------------------------------------------------------------

-- A turn just resolved (Battle calls this through pvp.onResolve): log it and pass it on.
function P:Relay(a1, a2)
    if not match then return end
    local pair = P.EncodeAct(a1) .. "/" .. P.EncodeAct(a2)
    match.log[#match.log + 1] = pair
    for key in pairs(match.watchers) do
        Whisper(key, { t = "AZV", op = "turn", id = match.id, n = #match.log, a = pair })
    end
end

local function OnWatchRequest(sender, msg)
    if type(msg) ~= "table" then return end
    if msg.op == "leave" then
        if match then match.watchers[sender] = nil end
        return
    end
    if msg.op ~= "ask" then return end
    if msg.v ~= P.VERSION then
        Whisper(sender, { t = "AZV", op = "no", why = "version" })
        return
    end
    if not match or match.battle.need == "done" or sender == match.opp then
        Whisper(sender, { t = "AZV", op = "no", why = "over" })
        return
    end
    if not match.watchers[sender] and P:WatcherCount() >= P.MAX_WATCHERS then
        Whisper(sender, { t = "AZV", op = "no", why = "full" })
        return
    end
    match.watchers[sender] = true
    Whisper(sender, { t = "AZV", op = "start", id = match.id, v = P.VERSION, seed = match.seed, p1 = match.p1,
                      p2 = match.p2, t1 = match.t1, t2 = match.t2, log = match.log })
end

function P:WatcherCount()
    local n = 0
    for _ in pairs(match and match.watchers or {}) do n = n + 1 end
    return n
end

function P:InMatch() return match ~= nil end
function P:Match() return match end

function P:OnInit()
    if not ns.Comm then return end
    ns.Comm:Register("AZC", OnChallenge)
    ns.Comm:Register("AZA", OnAnswer)
    ns.Comm:Register("AZF", OnWithdraw)
    ns.Comm:Register("AZM", OnMove)
    ns.Comm:Register("AZW", OnWatchRequest)
end

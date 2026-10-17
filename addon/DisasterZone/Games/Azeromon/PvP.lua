if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/PvP.lua", ...) then return end -- DisasterZone Games/Azeromon/PvP.lua
-- ns.AzeroPvP: battles between guildmates. Lockstep: both clients run the same Battle from the same seed and
-- only exchange their chosen action each turn (see Battle.lua, "Player battles").
-- Whispers on the game prefix (CDLg):
--   AZC { id, v, fp, seed, team }    challenge (with the challenger's team; fp = P.Fingerprint(), the battle data)
--   AZA { id, ok, why, fp, team }    answer (with the defender's team when accepted; why = "busy" | "no" | "version")
--   AZG { id }                       go: the challenger got the yes and starts; the defender starts only on this
--   AZM { id, turn, a }              my action for turn n
--   AZF { id, quit, timeout }        before a match: the challenge is off (withdrawn, unanswered, a late yes).
--                                    In a match: quit = I left (I lose), timeout = you ran out of time (you lose),
--                                    neither = called off before it really started (nobody wins)
-- Spectators (Watch.lua) ask either player; that player's client answers and then relays every turn:
--   AZW { op = "ask", v, fp }        may I watch?                          (spectator -> player)
--   AZW { op = "here" }              still watching (every KEEPALIVE seconds)
--   AZW { op = "leave" }             I stopped watching
--   AZV { op = "start", id, v, seed, p1, p2, t1, t2, log }  the match so far (p1 = challenger, t1/t2 = the teams
--                                    as sent, log = every resolved turn as "a1/a2", see P.EncodeAct)
--   AZV { op = "no", why }           "over" (no match any more) | "full" | "version"
--   AZV { op = "turn", id, n, a }    turn n resolved: a = "a1/a2"
--   AZV { op = "alive", id }         nothing to relay for a while, the match goes on
--   AZV { op = "off", id }           the match was called off
-- Rules: both teams fully healed for the match and untouched afterwards (the battle uses copies), no items or
-- flasks (gear counts: it's part of the beast),
-- no exp or money, real levels. A player who does not act within TURN_TIMEOUT seconds forfeits; leaving the
-- match (closing the game, a /reload, a disconnect) is a forfeit too.
local addonName, ns = ...

local P = ns:NewModule("AzeroPvP")
local G = ns.Azero
local D = ns.AzeroData
local M = ns.AzeroMon

P.VERSION = 3              -- 2: Park-Miller random numbers, the go handshake, the data fingerprint; 3: 0.37 battle rules
P.ANSWER_TIMEOUT = 30
P.START_TIMEOUT = 15       -- after my yes, how long I wait for the challenger's go
P.TURN_TIMEOUT = 60
P.TURN_GRACE = 15          -- the waiting side calls a timeout this much later: the slow player's own clock comes first
P.MAX_WATCHERS = 10
P.KEEPALIVE = 20           -- a word to spectators (and from them) when nothing else went out for this long
P.WATCHER_TIMEOUT = 60     -- a spectator not heard from for this long is dropped (a /reload, a disconnect)
P.RELAY_HOLD = 5           -- while I choose, spectators' turns wait up to this long, so my action goes out first
P.RECENT = 600             -- a match left by a /reload this recently: the opponent is told on the next login

local outgoing = nil       -- { id, to, at, seed, team }   my open challenge
local match = nil          -- { id, opp, name, host, battle, seed, t1, t2, log, watchers = { [key] = seen },
                           --   turnAt, lastTurn, relays, relayAt, settled }
P.incoming = nil           -- a challenge waiting for my Yes / No { id, from, at, gone = nil | "withdrew" | "expired" }
P.starting = nil           -- I said yes and wait for the go { id, from, at }
local owed = nil           -- { id, opp, by }: a match I left by a /reload; the opponent hears it once I can whisper

local function Now() return GetTime() end
local function Clock() return (time and time()) or 0 end

-- What another player already saw happen stays across a /reload (Game.lua rolls a script back otherwise).
local function Checkpoint() if G.Checkpoint then G:Checkpoint() end end

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
                                     gear = type(t.gear) == "table" and t.gear or nil }, true)
            if mon then
                M.Heal(mon)
                team[#team + 1] = mon
            end
        end
    end
    if #team == 0 then return nil end
    return team
end

-- A small seeded generator (the same on every client), called like math.random(a, b). Park-Miller's "minimal
-- standard" (s = 16807 * s mod 2^31 - 1): every product stays below 2^46, so plain doubles keep it exact.
local MOD = 2147483647
function P.NewRng(seed)
    local n = tonumber(seed) or 1
    if n ~= n or n == math.huge or n == -math.huge then n = 1 end
    local s = math.floor(n) % MOD
    if s == 0 then s = 1 end
    for _ = 1, 3 do s = (s * 16807) % MOD end       -- small seeds start small: stir a little first
    return function(a, b)
        s = (s * 16807) % MOD
        local r = (s - 1) / (MOD - 1)               -- [0, 1)
        if not b then a, b = 1, a end
        return a + math.floor(r * (b - a + 1))
    end
end

-- Everything a battle's outcome depends on in Data.lua (moves, species, the type chart, gear), as one short
-- hash: two clients with different data would split the lockstep battle, so they don't battle at all.
local fingerprint = nil
local function Flat(v, out)
    local tv = type(v)
    if tv == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if type(a) ~= type(b) then return type(a) < type(b) end
            return a < b
        end)
        out[#out + 1] = "{"
        for _, k in ipairs(keys) do
            out[#out + 1] = tostring(k) .. "="
            Flat(v[k], out)
        end
        out[#out + 1] = "}"
    elseif tv == "number" then
        out[#out + 1] = string.format("%.10g;", v)
    else
        out[#out + 1] = tostring(v) .. ";"
    end
end

local function SortedKeys(t, keep)
    local ids = {}
    for id, v in pairs(t or {}) do if not keep or keep(v) then ids[#ids + 1] = id end end
    table.sort(ids)
    return ids
end

function P.Fingerprint()
    if fingerprint then return fingerprint end
    local out = { "v", tostring(P.VERSION), ";" }
    for _, id in ipairs(SortedKeys(D.moves)) do
        local mv = D.moves[id]
        out[#out + 1] = id
        Flat({ mv.type or false, mv.power or false, mv.acc or false, mv.pp or false, mv.prio or 0,
               mv.effect or false }, out)
    end
    for _, id in ipairs(SortedKeys(D.species)) do
        local sp = D.species[id]
        out[#out + 1] = id
        Flat({ sp.type or false, sp.base or false, sp.learn or false, sp.evolve or false, sp.boss or false }, out)
    end
    Flat(D.chart or false, out)
    for _, t in ipairs(D.typeOrder or {}) do out[#out + 1] = t .. (D.types[t] and D.types[t].physical and "p" or "s") end
    for _, slot in ipairs(D.gearSlots or {}) do out[#out + 1] = tostring(slot.id) end
    for _, id in ipairs(SortedKeys(D.items, function(it) return it.use == "gear" end)) do
        out[#out + 1] = id
        local it = D.items[id]
        Flat({ it.slot or false, it.bonus or false, it.resist or false, it.typePower or false, it.regen or false,
               it.stun or false }, out)
    end
    local str = table.concat(out)
    local h = 5381
    for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
    fingerprint = string.format("%08x", h)
    return fingerprint
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
-- Records (account-wide game data, so a /reload can't undo them)
---------------------------------------------------------------------------

local function Record(opp, result)
    local d = G:Data()
    if type(d.pvp) ~= "table" then d.pvp = {} end
    local r = d.pvp[opp] or { w = 0, l = 0, d = 0 }
    if result == "win" then r.w = r.w + 1 elseif result == "lose" then r.l = r.l + 1 else r.d = r.d + 1 end
    d.pvp[opp] = r
    return r
end

-- The match is decided: count it right away (not when the screen has caught up), once.
local function Settle(m)
    if m.settled or m.battle.need ~= "done" then return end
    m.settled = true
    local d = G:Data()
    if type(d.pvpOpen) == "table" and d.pvpOpen.id == m.id then d.pvpOpen = nil end
    local result = m.battle.result
    if result == "win" or result == "lose" or result == "draw" then
        m.record = Record(m.opp, result)
        G:Emit("pvp", { result = result, opp = m.opp })
    end
    Checkpoint()
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
    local ask = { t = "AZC", id = id, v = P.VERSION, fp = P.Fingerprint(), seed = seed, team = team }
    if not ns.Games:Send(G.GAME_ID, ask, "WHISPER", peer.key) then
        outgoing = nil
        g:Say(peer.name .. " can't be reached right now.")
        return
    end
    local answer = g:Wait({ kind = "netwait", text = string.format("Waiting for %s to answer...\n(X to cancel)", peer.name) })
    local out = outgoing
    outgoing = nil
    if type(answer) == "table" and answer.ok then
        local bad = (answer.fp ~= P.Fingerprint() and "version") or (not P.UnpackTeam(answer.team) and "team") or nil
        if bad then
            ns.Games:Send(G.GAME_ID, { t = "AZF", id = out.id }, "WHISPER", peer.key)  -- they wait for the go: tell them it's off
            g:Say(bad == "version" and (peer.name .. " has a different game version.")
                or "Something went wrong with the other team. The battle was called off.")
            return
        end
        ns.Games:Send(G.GAME_ID, { t = "AZG", id = out.id }, "WHISPER", peer.key)
        P:Play(g, out.id, peer.key, true, out.seed, answer.team, out.team)
        return
    end
    if answer == "cancel" or answer == "timeout" then
        ns.Games:Send(G.GAME_ID, { t = "AZF", id = out.id }, "WHISPER", peer.key)  -- their prompt closes: a late yes starts nothing
        g:Say(answer == "cancel" and "You withdrew the challenge." or (peer.name .. " didn't answer."))
    elseif type(answer) == "table" and answer.why == "busy" then
        g:Say(peer.name .. " is busy right now.")
    elseif type(answer) == "table" and answer.why == "version" then
        g:Say(peer.name .. " has a different game version.")
    else
        g:Say(peer.name .. " declined the battle.")
    end
end

local function OnChallenge(sender, msg)
    if type(msg.id) ~= "string" then return end
    if msg.v ~= P.VERSION or msg.fp ~= P.Fingerprint() then
        ns.Games:Send(G.GAME_ID, { t = "AZA", id = msg.id, ok = false, why = "version" }, "WHISPER", sender)
        return
    end
    local busy = not G.started or not G:IsFree() or match ~= nil or outgoing ~= nil or P.incoming ~= nil
        or P.starting ~= nil or not (ns.AzeroNet and ns.AzeroNet:IsActive()) or not M.FirstUsable(G.save.party)
    local theirTeam = P.UnpackTeam(msg.team)
    if busy or not theirTeam then
        ns.Games:Send(G.GAME_ID, { t = "AZA", id = msg.id, ok = false, why = "busy" }, "WHISPER", sender)
        return
    end
    local name = ns.Util.ShortName(sender, true)
    local id, seed = msg.id, msg.seed
    P.incoming = { id = id, from = sender, at = Now() }
    G:Run(function(g)
        g:Sfx("request")
        local yes = g:YesNo(string.format("%s challenges you to a battle! Accept?", name))
        local inc = P.incoming
        P.incoming = nil
        local gone = (not inc or inc.id ~= id) and "withdrew" or inc.gone
        if gone == "expired" then
            g:Say("The challenge from " .. name .. " expired.")
            return
        elseif gone then
            g:Say(name .. " withdrew the challenge.")
            return
        end
        if not yes then
            ns.Games:Send(G.GAME_ID, { t = "AZA", id = id, ok = false, why = "no" }, "WHISPER", sender)
            return
        end
        local team = P.PackTeam(g.save.party)
        ns.Games:Send(G.GAME_ID, { t = "AZA", id = id, ok = true, fp = P.Fingerprint(), team = team }, "WHISPER", sender)
        -- the battle starts only once the challenger confirms it is still there
        P.starting = { id = id, from = sender, at = Now() }
        local go = g:Wait({ kind = "netwait",
                            text = string.format("Starting the battle with %s...\n(X to cancel)", name) })
        P.starting = nil
        if go == "go" then
            P:Play(g, id, sender, false, seed, msg.team, team)
            return
        end
        ns.Games:Send(G.GAME_ID, { t = "AZF", id = id }, "WHISPER", sender)  -- (a go crossing this: they call it off too)
        if go == "cancel" then
            g:Say("You called off the battle.")
        elseif go == "withdrawn" then
            g:Say(name .. " withdrew the challenge.")
        else
            g:Say(name .. " didn't answer.")
        end
    end)
end

local function OnAnswer(sender, msg)
    if outgoing and msg.id == outgoing.id and sender == outgoing.to then
        if G.pending and G.pending.kind == "netwait" then G:Advance(msg) end
    elseif msg.ok and type(msg.id) == "string" then
        ns.Games:Send(G.GAME_ID, { t = "AZF", id = msg.id }, "WHISPER", sender)  -- a yes I'm no longer waiting for: they back out
    end
end

local function OnGo(sender, msg)
    local st = P.starting
    if st and st.id == msg.id and st.from == sender and G.pending and G.pending.kind == "netwait" then
        G:Advance("go")
    end
end

---------------------------------------------------------------------------
-- The match
---------------------------------------------------------------------------

-- Any move I may use (answering an opponent's forfeit: the turn resolves at once).
local function AnyMove(b)
    for i, mv in ipairs(b.ally.mon.moves) do
        if mv.pp > 0 then return { kind = "move", idx = i } end
    end
    return { kind = "move", idx = 1 }
end

-- Sends spectators the turns waiting for them.
local function FlushRelays(m)
    if #m.relays == 0 then return end
    for key in pairs(m.watchers) do
        for _, r in ipairs(m.relays) do
            ns.Games:Send(G.GAME_ID, { t = "AZV", op = "turn", id = m.id, n = r.n, a = r.a }, "WHISPER", key)
        end
    end
    m.relays = {}
    m.relayAt = Now()
end

local function QueueRelay(m, a1, a2)
    local pair = P.EncodeAct(a1) .. "/" .. P.EncodeAct(a2)
    m.log[#m.log + 1] = pair
    m.relays[#m.relays + 1] = { n = #m.log, a = pair }
end

-- Ends my match from outside the turns (someone left, a timeout, called off). Spectators see the loser forfeit.
local function EndMatch(m, result, text)
    local b = m.battle
    if b.need == "done" then return end
    if result == "win" or result == "lose" then
        local quit, stay = { kind = "forfeit" }, { kind = "move", idx = 1 }
        local mine, theirs = stay, quit
        if result == "lose" then mine, theirs = quit, stay end
        if m.host then QueueRelay(m, mine, theirs) else QueueRelay(m, theirs, mine) end
        FlushRelays(m)
    else
        for key in pairs(m.watchers) do ns.Games:Send(G.GAME_ID, { t = "AZV", op = "off", id = m.id }, "WHISPER", key) end
    end
    b:Say("%s", text)
    b:Finish(result)
    Settle(m)
end

-- myTeamWire: my team exactly as the other side (and any spectator) received it. My side of the battle is
-- rebuilt from it the same way theirs is, so all copies of the match have the same beasts (gear included).
function P:Play(g, id, opp, host, seed, theirTeamWire, myTeamWire)
    local foes = P.UnpackTeam(theirTeamWire)
    local mine = P.UnpackTeam(myTeamWire)
    if not foes or not mine then
        ns.Games:Send(G.GAME_ID, { t = "AZF", id = id }, "WHISPER", opp)  -- they must not wait in a match alone
        g:Say("Something went wrong with the other team. The battle was called off.")
        return
    end
    local name = ns.Util.ShortName(opp, true)
    local m
    -- the seed is the challenger's; both sides use it, so every roll matches
    local b = ns.AzeroBattle.New({
        party = mine, foes = foes, rng = P.NewRng(seed),
        onSeen = function(sp) g.save.seen[sp] = true g:Emit("seen", { sp = sp }) end,
        pvp = { host = host, name = name, onAction = function(a)
            if not m then return end
            ns.Games:Send(G.GAME_ID, { t = "AZM", id = id, turn = m.battle.turn + 1, a = a }, "WHISPER", opp)
            -- my forfeit ends the match now, whatever they would have done this turn
            if a.kind == "forfeit" then m.battle:ReceivePvP({ kind = "move", idx = 1 }) end
        end, onResolve = function(a1, a2) if m then QueueRelay(m, a1, a2) end end },
    })
    local me = ns.Util.PlayerKey() or "?"
    m = { id = id, opp = opp, name = name, host = host, battle = b, seed = seed,
          p1 = host and me or opp, p2 = host and opp or me,
          t1 = host and myTeamWire or theirTeamWire, t2 = host and theirTeamWire or myTeamWire,
          log = {}, watchers = {}, relays = {}, relayAt = Now(), turnAt = Now(), lastTurn = b.turn }
    match = m
    -- leaving now (a /reload, a disconnect) counts as a loss on the next login (P:OnLogin)
    g:Data().pvpOpen = { id = id, opp = opp, at = Clock() }
    g.battle = b
    local result = g:Wait({ kind = "battle", battle = b }) or b.result
    g.battle = nil
    if b.need ~= "done" then b:Finish(result or "lose") end
    Settle(m)
    FlushRelays(m)
    if match == m then match = nil end     -- spectators already have the last turn, and end on it by themselves
    local r = m.record
    if r then g:Say(string.format("Your record against %s: %d won, %d lost, %d drawn.", name, r.w, r.l, r.d)) end
end

local function OnMove(sender, msg)
    local m = match
    if not m or msg.id ~= m.id or sender ~= m.opp then return end
    local b = m.battle
    local turn = tonumber(msg.turn)
    if turn ~= b.turn + 1 then return end
    if b:ReceivePvP(msg.a) then
        -- their forfeit ends the match at once: answer it with any move instead of waiting for my choice
        if b.need == "action" and b.theirs and b.theirs.kind == "forfeit" then b:Act(AnyMove(b)) end
        Settle(m)
    end
end

local function OnWithdraw(sender, msg)
    local inc = P.incoming
    if inc and inc.id == msg.id and inc.from == sender then
        inc.gone = "withdrew"              -- the Yes/No prompt stays up; answering it then says so
        return
    end
    local st = P.starting
    if st and st.id == msg.id and st.from == sender then
        if G.pending and G.pending.kind == "netwait" then G:Advance("withdrawn") end
        return
    end
    local m = match
    if not m or msg.id ~= m.id or sender ~= m.opp or m.battle.need == "done" then return end
    if msg.timeout then
        EndMatch(m, "lose", string.format("You ran out of time. %s wins the match.", m.name))
    elseif msg.quit then
        EndMatch(m, "win", string.format("%s left the match. You win!", m.name))
    else                                   -- (their team was unusable, or they never got my go)
        EndMatch(m, "off", string.format("%s backed out. The battle was called off.", m.name))
    end
end

-- The game window closed mid-match: I leave, which is a forfeit, and the opponent hears it at once.
function P:Leave()
    local m = match
    if not m or m.battle.need == "done" then return end
    ns.Games:Send(G.GAME_ID, { t = "AZF", id = m.id, quit = true }, "WHISPER", m.opp)
    EndMatch(m, "lose", "You left the match.")
end

local function PayOwed()
    if owed and (Now() > owed.by
                 or ns.Games:Send(G.GAME_ID, { t = "AZF", id = owed.id, quit = true }, "WHISPER", owed.opp)) then
        owed = nil
    end
end

-- Timeouts (called every frame by the UI, and by the tests).
function P:Update()
    local now = Now()
    PayOwed()
    if outgoing and now - outgoing.at > P.ANSWER_TIMEOUT and G.pending and G.pending.kind == "netwait" then
        G:Advance("timeout")
    end
    local inc = P.incoming
    if inc and not inc.gone and now - inc.at > P.ANSWER_TIMEOUT then inc.gone = "expired" end   -- they gave up too
    local st = P.starting
    if st and now - st.at > P.START_TIMEOUT and G.pending and G.pending.kind == "netwait" then G:Advance("timeout") end
    local m = match
    if not m then return end
    local b = m.battle
    if b.turn ~= m.lastTurn then m.lastTurn, m.turnAt = b.turn, now end   -- both clocks start when a turn resolves
    if b.need == "action" and now - m.turnAt > P.TURN_TIMEOUT then
        b:Act({ kind = "forfeit" })                   -- I never chose: I forfeit (they see the same)
    elseif b.need == "wait" and now - m.turnAt > P.TURN_TIMEOUT + P.TURN_GRACE then
        b:ReceivePvP({ kind = "forfeit" })            -- they never answered: they forfeit, and are told so
        ns.Games:Send(G.GAME_ID, { t = "AZF", id = m.id, timeout = true }, "WHISPER", m.opp)
    end
    Settle(m)
    -- spectators: my action goes out before their turns; quiet ones are dropped; the rest hear we're still on
    if b.need ~= "action" or now - m.turnAt >= P.RELAY_HOLD then FlushRelays(m) end
    for key, seen in pairs(m.watchers) do
        if now - seen > P.WATCHER_TIMEOUT then m.watchers[key] = nil end
    end
    if next(m.watchers) and now - m.relayAt > P.KEEPALIVE then
        m.relayAt = now
        for key in pairs(m.watchers) do ns.Games:Send(G.GAME_ID, { t = "AZV", op = "alive", id = m.id }, "WHISPER", key) end
    end
end

---------------------------------------------------------------------------
-- Spectators
---------------------------------------------------------------------------

-- A turn just resolved: log it and pass it on (P:Update sends it).
function P:Relay(a1, a2)
    if match then QueueRelay(match, a1, a2) end
end

local function OnWatchRequest(sender, msg)
    if type(msg) ~= "table" then return end
    local m = match
    if msg.op == "leave" then
        if m then m.watchers[sender] = nil end
        return
    elseif msg.op == "here" then
        if m and m.watchers[sender] then m.watchers[sender] = Now() end
        return
    end
    if msg.op ~= "ask" then return end
    if msg.v ~= P.VERSION or msg.fp ~= P.Fingerprint() then
        ns.Games:Send(G.GAME_ID, { t = "AZV", op = "no", why = "version" }, "WHISPER", sender)
        return
    end
    if not m or m.battle.need == "done" or sender == m.opp then
        ns.Games:Send(G.GAME_ID, { t = "AZV", op = "no", why = "over" }, "WHISPER", sender)
        return
    end
    if not m.watchers[sender] and P:WatcherCount() >= P.MAX_WATCHERS then
        ns.Games:Send(G.GAME_ID, { t = "AZV", op = "no", why = "full" }, "WHISPER", sender)
        return
    end
    FlushRelays(m)                         -- (the log below has them; nobody gets a turn twice out of order)
    m.watchers[sender] = Now()
    ns.Games:Send(G.GAME_ID, { t = "AZV", op = "start", id = m.id, v = P.VERSION, seed = m.seed, p1 = m.p1,
                               p2 = m.p2, t1 = m.t1, t2 = m.t2, log = m.log }, "WHISPER", sender)
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
    ns.Comm:Register("AZG", OnGo)
    ns.Comm:Register("AZF", OnWithdraw)
    ns.Comm:Register("AZM", OnMove)
    ns.Comm:Register("AZW", OnWatchRequest)
    ns:On("ROSTER_UPDATED", PayOwed)       -- (right after login the guild roster isn't there to whisper yet)
end

-- A match still open from the last session (a /reload, a disconnect, a crash): it counts as lost, and a recent one
-- tells the opponent, who would otherwise wait for the turn timer.
function P:OnLogin()
    local d = G:Data()
    local open = d.pvpOpen
    if type(open) ~= "table" then return end
    d.pvpOpen = nil
    if type(open.opp) ~= "string" then return end
    local r = Record(open.opp, "lose")
    if type(open.id) == "string" and Clock() - (tonumber(open.at) or 0) <= P.RECENT then
        owed = { id = open.id, opp = open.opp, by = Now() + 120 }
        PayOwed()
    end
    if ns.Print then
        ns:Print("|cffffd200Azeromon:|r you left the battle with %s, so it counts as a loss "
            .. "(%d won, %d lost, %d drawn).", ns.Util.ShortName(open.opp, true), r.w, r.l, r.d)
    end
end

-- For tests
P._Reset = function() outgoing, match, P.incoming, P.starting, owed = nil, nil, nil, nil, nil end

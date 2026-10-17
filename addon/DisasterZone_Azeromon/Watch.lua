if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/Watch.lua", ...) then return end -- DisasterZone_Azeromon/Watch.lua
-- ns.AzeroWatch: watching a battle between two guildmates (A on either player while they battle).
-- Player battles are lockstep (PvP.lua), so a spectator needs no pictures of the fight: the player it asked sends
-- the seed, both teams and every turn so far (AZV start), then each turn as it resolves (AZV turn). The spectator
-- runs its own copy of the battle from p1's side, catches up silently and plays the rest like any battle.
-- Protocol: see PvP.lua (AZW / AZV). Watching changes nothing on either player's side; B stops watching.
-- Liveness comes from the player I asked (turns, or a keepalive when a turn is slow), not from world presence,
-- which stops during WoW combat; I tell that player I'm still here the same way, so a /reload frees my slot.
local addonName, ns = ...

local W = ns:NewModule("AzeroWatch")
local G = ns.Azero
local P = ns.AzeroPvP

W.ANSWER_TIMEOUT = 15
-- nothing from the player for this long: the relay is lost. Longer than the longest legal wait for a turn (the
-- turn timer plus the grace before a timeout is called), and the player sends a keepalive every P.KEEPALIVE.
W.SILENCE = P.TURN_TIMEOUT + P.TURN_GRACE + 30

local asking = nil             -- { to, at }                      waiting for AZV start
local session = nil            -- { id, from, battle, applied, early = { [n] = pair }, heard, said }

local function Now() return GetTime() end

-- The spectator's copy of the match, caught up to the last resolved turn. nil when the message is unusable.
function W.Build(msg)
    if type(msg.p1) ~= "string" or type(msg.p2) ~= "string" or type(msg.id) ~= "string" then return nil end
    local t1, t2 = P.UnpackTeam(msg.t1), P.UnpackTeam(msg.t2)
    if not t1 or not t2 then return nil end
    local n1, n2 = ns.Util.ShortName(msg.p1, true), ns.Util.ShortName(msg.p2, true)
    local b = ns.AzeroBattle.New({ party = t1, foes = t2, rng = P.NewRng(msg.seed),
                                   pvp = { host = true, name = n2, watch = { ally = n1, foe = n2 } } })
    local log = type(msg.log) == "table" and msg.log or {}
    for _, pair in ipairs(log) do
        if not b:WatchTurn(P.DecodeTurn(pair)) then break end
    end
    b:WatchIntro()
    return b, #log
end

function W:Watch(g, peer)
    asking = { to = peer.key, at = Now() }
    if not ns.Games:Send(G.GAME_ID, { t = "AZW", op = "ask", v = P.VERSION, fp = P.Fingerprint() }, "WHISPER", peer.key) then
        asking = nil
        g:Say(peer.name .. " can't be reached right now.")
        return
    end
    local answer = g:Wait({ kind = "netwait", text = string.format("Asking %s if you can watch...\n(X to cancel)", peer.name) })
    asking = nil
    if type(answer) ~= "table" or answer.op ~= "start" then
        if answer == "cancel" then
            ns.Games:Send(G.GAME_ID, { t = "AZW", op = "leave" }, "WHISPER", peer.key)  -- in case the yes crosses the cancel
        elseif answer == "timeout" then
            g:Say(peer.name .. " didn't answer.")
        elseif type(answer) == "table" and answer.why == "full" then
            g:Say("Too many guildmates are watching that battle already.")
        elseif type(answer) == "table" and answer.why == "version" then
            g:Say(peer.name .. " has a different version of Azeromon.")
        else
            g:Say("That battle is already over.")
        end
        return
    end
    local b, applied = W.Build(answer)
    if not b then
        ns.Games:Send(G.GAME_ID, { t = "AZW", op = "leave" }, "WHISPER", peer.key)
        g:Say("Something went wrong with that battle. You can't watch it.")
        return
    end
    session = { id = answer.id, from = peer.key, battle = b, applied = applied, early = {}, heard = Now(),
                said = Now() }
    g.battle = b
    local result = g:Wait({ kind = "battle", battle = b }) or b.result
    g.battle = nil
    session = nil
    if result == "left" then
        ns.Games:Send(G.GAME_ID, { t = "AZW", op = "leave" }, "WHISPER", peer.key)
    end
    g:Emit("watch", { result = result })
end

-- B while watching.
function W:Stop()
    if session then session.battle:EndWatch("left", "You stopped watching.") end
end

function W:Watching() return session ~= nil end

local function OnReply(sender, msg)
    if type(msg) ~= "table" then return end
    if msg.op == "alive" or msg.op == "off" then
        local s = session
        if not s or sender ~= s.from or msg.id ~= s.id then return end
        s.heard = Now()
        if msg.op == "off" then s.battle:EndWatch("lost", "The battle was called off.") end
        return
    end
    if msg.op == "turn" then
        local s = session
        if not s or sender ~= s.from or msg.id ~= s.id then return end
        local n = tonumber(msg.n)
        if not n or n <= s.applied or n > s.applied + 200 then return end
        s.heard = Now()
        s.early[n] = msg.a
        while s.early[s.applied + 1] do             -- whispers can overtake each other: play them in order
            local pair = s.early[s.applied + 1]
            s.early[s.applied + 1] = nil
            s.applied = s.applied + 1
            s.battle:WatchTurn(P.DecodeTurn(pair))
        end
        return
    end
    if (msg.op == "start" or msg.op == "no") and asking and sender == asking.to
        and G.pending and G.pending.kind == "netwait" then
        G:Advance(msg)
    elseif msg.op == "start" then
        ns.Games:Send(G.GAME_ID, { t = "AZW", op = "leave" }, "WHISPER", sender)  -- an answer I'm no longer waiting for
    end
end

-- Timeouts (called every frame by the UI, and by the tests).
function W:Update()
    local now = Now()
    if asking and now - asking.at > W.ANSWER_TIMEOUT and G.pending and G.pending.kind == "netwait" then
        G:Advance("timeout")
    end
    local s = session
    if s and s.battle.need ~= "done" then
        local name = ns.Util.ShortName(s.from, true)
        if ns.AzeroNet and ns.AzeroNet:HasLeft(s.from) then
            s.battle:EndWatch("lost", string.format("%s left, so the battle can't be followed any more.", name))
        elseif now - s.heard > W.SILENCE then
            s.battle:EndWatch("lost", string.format("Lost touch with %s, so the battle can't be followed any more.",
                name))
        elseif now - s.said > P.KEEPALIVE then
            s.said = now
            ns.Games:Send(G.GAME_ID, { t = "AZW", op = "here" }, "WHISPER", s.from)
        end
    end
end

function W:OnInit()
    if ns.Comm then ns.Comm:Register("AZV", OnReply) end
end

-- For tests
W._Reset = function() asking, session = nil, nil end

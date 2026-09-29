-- CDLoot Games/Azeromon/Trade.lua
-- ns.AzeroTrade: trading beasts with a guildmate you meet in the world (A on them, then "Trade").
-- Whispers on the game prefix (CDLg), one message type with an op:
--   AZT { op = "ask",     id, v }        would you like to trade?
--   AZT { op = "answer",  id, ok, why }  yes / no (why = "busy" | "no" | "version")
--   AZT { op = "offer",   id, mon }      the beast I offer (T.Pack); a new offer clears both acceptances
--   AZT { op = "confirm", id, h }        I accept this pair (h = checksum of both offers in player-key order)
--   AZT { op = "commit",  id, h }        the host (smaller player key) had both acceptances and swapped: swap too
--   AZT { op = "cancel",  id }           I left the trade
-- Only the host decides, so a trade can't half-happen because one side cancelled at the last moment: the other
-- side honours a commit for the pair it accepted even if it cancelled meanwhile.
-- A beast keeps its original trainer (ot); a traded beast earns boosted exp, and a Kobold Tunneler evolves when
-- traded (D.species[..].evolve.trade).
local addonName, ns = ...

local T = ns:NewModule("AzeroTrade")
local G = ns.Azero
local D = ns.AzeroData
local M = ns.AzeroMon

T.VERSION = 1
T.ANSWER_TIMEOUT = 30
T.IDLE_TIMEOUT = 180          -- no word from the other side for this long closes the trade
T.LATE_COMMIT = 60            -- how long a cancelled trade still honours the host's commit

local ask = nil               -- my open request { id, to, at }
T.session = nil               -- { id, peer, name, host, mine, mineWire, theirs, theirsWire, myOk, theirOk, heard, state }
T.incoming = nil              -- a request waiting for my Yes / No { id, from }
T.last = nil                  -- the trade I accepted and then left { session, at } (see LATE_COMMIT)
T.onChange = nil              -- the UI's refresh

local function Now() return GetTime() end
local function ShortName(key) return (Ambiguate and Ambiguate(key, "short")) or (key:match("^[^-]+") or key) end
local function MyKey() return ns.Util.PlayerKey() end

local function Whisper(to, msg)
    msg.t = "AZT"
    return ns.Comm and ns.Comm:Send(msg, "WHISPER", to, "game")
end

function T:Changed()
    if T.onChange then T.onChange(T.session) end
end

---------------------------------------------------------------------------
-- Beasts on the wire
---------------------------------------------------------------------------

function T.Pack(mon)
    local moves, ivs = {}, {}
    local gear
    if type(mon.gear) == "table" then
        gear = {}
        for slot, id in pairs(mon.gear) do gear[slot] = id end
    end
    for i, mv in ipairs(mon.moves) do moves[i] = { id = mv.id, pp = mv.pp } end
    for i = 1, 6 do ivs[i] = (type(mon.ivs) == "table" and tonumber(mon.ivs[i])) or 0 end
    return { sp = mon.sp, lvl = mon.lvl, exp = mon.exp, ivs = ivs, moves = moves, hp = mon.hp, status = mon.status,
             shiny = mon.shiny or nil, ot = mon.ot or G:PlayerName(), gear = gear,
             flask = mon.flask and { id = mon.flask.id, n = mon.flask.n } or nil }
end

-- A received beast, validated; nil when it isn't a tradeable beast.
function T.Unpack(w)
    if type(w) ~= "table" then return nil end
    local ivs, moves = {}, {}
    for k = 1, 6 do
        ivs[k] = math.max(0, math.min(31, math.floor(tonumber(type(w.ivs) == "table" and w.ivs[k]) or 0)))
    end
    if type(w.moves) == "table" then
        for _, mv in ipairs(w.moves) do
            if type(mv) == "table" then moves[#moves + 1] = { id = mv.id, pp = mv.pp } end
        end
    end
    local mon = M.Sanitize({ sp = w.sp, lvl = w.lvl, exp = w.exp, ivs = ivs, moves = moves, hp = w.hp,
                             status = w.status, shiny = w.shiny,
                             gear = type(w.gear) == "table" and w.gear or nil,
                             flask = type(w.flask) == "table" and { id = w.flask.id, n = w.flask.n } or nil,
                             ot = type(w.ot) == "string" and w.ot ~= "" and w.ot:sub(1, 24) or nil })
    if not mon or D.species[mon.sp].boss then return nil end
    if mon.lvl < D.MAX_LEVEL then mon.exp = math.min(mon.exp, M.ExpForLevel(mon.lvl + 1) - 1) end
    return mon
end

local function Str(v)
    if type(v) == "number" then return string.format("%d", v) end
    return tostring(v)
end

local function WireKey(w)
    if type(w) ~= "table" then return "-" end
    local parts = { Str(w.sp), Str(w.lvl), Str(w.exp), Str(w.hp), Str(w.status), Str(w.shiny), Str(w.ot),
                    Str(type(w.flask) == "table" and w.flask.id), Str(type(w.flask) == "table" and w.flask.n) }
    for _, slot in ipairs(D.gearSlots or {}) do parts[#parts + 1] = Str(type(w.gear) == "table" and w.gear[slot.id]) end
    for i = 1, 6 do parts[#parts + 1] = Str(type(w.ivs) == "table" and w.ivs[i]) end
    for _, mv in ipairs(type(w.moves) == "table" and w.moves or {}) do
        parts[#parts + 1] = Str(type(mv) == "table" and mv.id) .. "/" .. Str(type(mv) == "table" and mv.pp)
    end
    return table.concat(parts, ",")
end

local function Checksum(str)
    local h = 5381
    for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
    return h
end

-- The same number on both sides: the two offers in player-key order.
function T.PairHash(s)
    local a, b = WireKey(s.mineWire), WireKey(s.theirsWire)
    if not s.host then a, b = b, a end
    return Checksum(a .. "|" .. b)
end

---------------------------------------------------------------------------
-- Asking (from the overworld script) and being asked
---------------------------------------------------------------------------

function T:Busy() return T.session ~= nil or ask ~= nil or T.incoming ~= nil end

function T:Ask(g, peer)
    if #g.save.party == 0 then
        g:Say("You have no beasts to trade.")
        return
    end
    local id = string.format("%d%04d", math.floor(Now() * 10) % 1000000, math.random(0, 9999))
    ask = { id = id, to = peer.key, at = Now() }
    if not Whisper(peer.key, { op = "ask", id = id, v = T.VERSION }) then
        ask = nil
        g:Say(peer.name .. " can't be reached right now.")
        return
    end
    local answer = g:Wait({ kind = "netwait", text = string.format("Waiting for %s to answer...\n(X to cancel)", peer.name) })
    local a = ask
    ask = nil
    if type(answer) == "table" and answer.ok then
        T:Open(g, a.id, peer.key)
    elseif answer == "cancel" then
        Whisper(peer.key, { op = "cancel", id = a.id })
        g:Say("You called off the trade.")
    elseif answer == "timeout" then
        g:Say(peer.name .. " didn't answer.")
    elseif type(answer) == "table" and answer.why == "busy" then
        g:Say(peer.name .. " is busy right now.")
    else
        g:Say(peer.name .. " doesn't want to trade right now.")
    end
end

local function OnAsk(sender, msg)
    if type(msg.id) ~= "string" then return end
    if msg.v ~= T.VERSION then
        Whisper(sender, { op = "answer", id = msg.id, ok = false, why = "version" })
        return
    end
    local P = ns.AzeroPvP
    local busy = not G.started or not G:IsFree() or T:Busy() or (P and (P:InMatch() or P.incoming))
        or not (ns.AzeroNet and ns.AzeroNet:IsActive()) or #G.save.party == 0
    if busy then
        Whisper(sender, { op = "answer", id = msg.id, ok = false, why = "busy" })
        return
    end
    local name, id = ShortName(sender), msg.id
    T.incoming = { id = id, from = sender }
    G:Run(function(g)
        local yes = g:YesNo(string.format("%s would like to trade beasts. Accept?", name))
        local still = T.incoming and T.incoming.id == id
        T.incoming = nil
        if not still then
            g:Say(name .. " called off the trade.")
            return
        end
        if not yes then
            Whisper(sender, { op = "answer", id = id, ok = false, why = "no" })
            return
        end
        Whisper(sender, { op = "answer", id = id, ok = true })
        T:Open(g, id, sender)
    end)
end

local function OnAnswer(sender, msg)
    if not ask or msg.id ~= ask.id or sender ~= ask.to then return end
    if G.pending and G.pending.kind == "netwait" then G:Advance({ ok = msg.ok == true, why = msg.why }) end
end

---------------------------------------------------------------------------
-- The trade itself (the UI shows G.pending.kind == "trade" and calls Offer / Confirm / Cancel)
---------------------------------------------------------------------------

function T:Open(g, id, peer)
    local s = { id = id, peer = peer, name = ShortName(peer), host = MyKey() < peer, heard = Now(), state = "open" }
    T.session = s
    local result = g:Wait({ kind = "trade", session = s })
    if T.session == s then T.session = nil end
    if result == "done" and s.received then
        g:Say(string.format("You sent %s to %s.", M.Name(s.sent), s.name))
        g:Say(string.format("%s sent over %s! Take good care of it.", s.name, M.Name(s.received)))
        local into = M.TradeEvolution(s.received)
        if into then g:EvolveNow(s.received, into) end
    elseif s.why == "them" then
        g:Say(s.name .. " left the trade.")
    elseif s.why == "timeout" then
        g:Say("The trade was called off: no word from " .. s.name .. ".")
    elseif s.why == "invalid" then
        g:Say("Something went wrong with that trade. Nothing changed hands.")
    else
        g:Say("The trade was cancelled.")
    end
end

local function Close(s, result, why)
    s.state, s.why = result, why
    if result ~= "done" and s.myOk then T.last = { session = s, at = Now() } end
    T:Changed()
    if G.pending and G.pending.kind == "trade" and G.pending.session == s then G:Advance(result) end
end

-- Offer party beast `idx`.
function T:Offer(idx)
    local s = T.session
    local mon = G.save and G.save.party[idx]
    if not s or s.state ~= "open" or not mon or s.myOk then return false end
    s.mine, s.mineWire = mon, T.Pack(mon)
    s.myOk, s.theirOk = nil, nil
    Whisper(s.peer, { op = "offer", id = s.id, mon = s.mineWire })
    T:Changed()
    return true
end

-- Swap the two beasts in my save: theirs takes my offered beast's place in the party.
local function Swap(s)
    local party = G.save.party
    local slot
    for i, m in ipairs(party) do if m == s.mine then slot = i end end
    local got = T.Unpack(s.theirsWire)
    if not slot or not got then return false end
    got.traded = (got.ot ~= G:PlayerName()) or nil
    party[slot] = got
    s.sent, s.received = s.mine, got
    local save = G.save
    save.seen[got.sp], save.caught[got.sp] = true, true
    if got.shiny then
        if type(save.shinyCaught) ~= "table" then save.shinyCaught = {} end
        save.shinyCaught[got.sp] = true
    end
    local d = G:Data()
    if type(d.trades) ~= "table" then d.trades = {} end
    d.trades[s.peer] = (d.trades[s.peer] or 0) + 1
    G:Emit("tame", { mon = got, how = "traded" })
    G:Emit("trade", { mon = got, sent = s.mine, peer = s.peer })
    return true
end

local function TryCommit(s)
    if not s.host or s.state ~= "open" or not s.myOk or s.myOk ~= s.theirOk then return false end
    if not Swap(s) then
        Whisper(s.peer, { op = "cancel", id = s.id })
        Close(s, "cancel", "invalid")
        return false
    end
    Whisper(s.peer, { op = "commit", id = s.id, h = s.myOk })
    Close(s, "done")
    return true
end

-- Accept the pair on the table.
function T:Confirm()
    local s = T.session
    if not s or s.state ~= "open" or not s.mineWire or not s.theirsWire or s.myOk then return false end
    s.myOk = T.PairHash(s)
    Whisper(s.peer, { op = "confirm", id = s.id, h = s.myOk })
    TryCommit(s)
    T:Changed()
    return true
end

function T:Cancel(why)
    local s = T.session
    if not s or s.state ~= "open" then return false end
    Whisper(s.peer, { op = "cancel", id = s.id })
    Close(s, "cancel", why or "me")
    return true
end

local function Current(sender, msg)
    local s = T.session
    if s and s.id == msg.id and s.peer == sender and s.state == "open" then
        s.heard = Now()
        return s
    end
end

local function OnOffer(sender, msg)
    local s = Current(sender, msg)
    if not s then return end
    local mon = T.Unpack(msg.mon)
    s.theirs, s.theirsWire = mon, mon and msg.mon or nil
    s.myOk, s.theirOk = nil, nil
    T:Changed()
end

local function OnConfirm(sender, msg)
    local s = Current(sender, msg)
    if not s then return end
    s.theirOk = tonumber(msg.h)
    TryCommit(s)
    T:Changed()
end

local function OnCommit(sender, msg)
    local h = tonumber(msg.h)
    local s = Current(sender, msg)
    if s then
        if s.host or not s.myOk or s.myOk ~= h then return end
        if Swap(s) then Close(s, "done") else Close(s, "cancel", "invalid") end
        return
    end
    -- a commit for a trade I accepted and then left: it went through on the host's side, so it does here too
    local last = T.last
    if last and last.session.id == msg.id and last.session.peer == sender and last.session.myOk == h
        and Now() - last.at <= T.LATE_COMMIT then
        T.last = nil
        local ls = last.session
        if Swap(ls) then
            ls.state = "done"
            if ns.Print then
                ns:Print("|cffffd200Azeromon:|r the trade with %s went through after all: you received %s.", ls.name,
                    M.Name(ls.received))
            end
        end
    end
end

local function OnCancel(sender, msg)
    if T.incoming and T.incoming.id == msg.id and T.incoming.from == sender then
        T.incoming = nil                  -- the Yes / No stays up; answering it says they called it off
        return
    end
    local s = T.session
    if s and s.id == msg.id and s.peer == sender and s.state == "open" then Close(s, "cancel", "them") end
end

local HANDLERS = { ask = OnAsk, answer = OnAnswer, offer = OnOffer, confirm = OnConfirm, commit = OnCommit,
                   cancel = OnCancel }

local function OnMessage(sender, msg)
    if type(msg) ~= "table" then return end
    local fn = HANDLERS[msg.op]
    if fn then fn(sender, msg) end
end

---------------------------------------------------------------------------
-- Timeouts, lifecycle
---------------------------------------------------------------------------

function T:Update()
    local now = Now()
    if ask and now - ask.at > T.ANSWER_TIMEOUT and G.pending and G.pending.kind == "netwait" then
        G:Advance("timeout")
    end
    local s = T.session
    if s and s.state == "open" and now - s.heard > T.IDLE_TIMEOUT then
        Whisper(s.peer, { op = "cancel", id = s.id })
        Close(s, "cancel", "timeout")
    end
end

function T:OnInit()
    if ns.Comm then ns.Comm:Register("AZT", OnMessage) end
end

-- For tests
T._Reset = function() ask, T.session, T.incoming, T.last = nil, nil, nil, nil end

if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Trade.lua", ...) then return end -- DisasterZone Games/Azeromon/Trade.lua
-- ns.AzeroTrade: trading beasts and items with a guildmate you meet in the world (A on them, then "Trade").
-- Each side offers a beast, items (up to MAX_STACKS kinds), both, or nothing (a gift); both accept the whole table.
-- Whispers on the game prefix (CDLg), one message type with an op:
--   AZT { op = "ask",     id, v }        would you like to trade?
--   AZT { op = "answer",  id, ok, why }  yes / no (why = "busy" | "no" | "version")
--   AZT { op = "go",      id }           the asker got the yes and opens the trade; the other side opens only on this
--   AZT { op = "offer",   id, mon, items }  what I offer: a beast (T.Pack) or none, items { id = count };
--                                           a new offer clears both acceptances
--   AZT { op = "confirm", id, h }        I accept this pair (h = checksum of both offers in player-key order)
--   AZT { op = "commit",  id, h }        host -> other side: both accepted; carry it out and answer (repeated
--                                        until answered, also after a /reload)
--   AZT { op = "ack",     id, h, ok, wait }  other side -> host: done (ok) / refused, nothing changed (not ok) /
--                                        busy right now, will do it when free (wait)
--   AZT { op = "cancel",  id }           I left the trade (or the request is off)
-- Two phases, so a /reload or a disconnect can't leave a beast on both sides: the host (smaller player key) puts its
-- side in escrow (out of its save, into the account's trade log) and sends commit; the other side swaps, logs it and
-- acks; only then does the host take the other side's goods (on a refusal its own come back). The other side
-- answers a repeated commit from its log, so a late or repeated one never swaps twice, and refuses a commit it no
-- longer knows (it reloaded first): then nothing has changed hands anywhere.
-- A beast keeps its original trainer (ot); a traded beast earns boosted exp, and a Kobold Tunneler evolves when
-- traded (D.species[..].evolve.trade).
local addonName, ns = ...

local T = ns:NewModule("AzeroTrade")
local G = ns.Azero
local D = ns.AzeroData
local M = ns.AzeroMon

T.VERSION = 2                 -- 2: the two-phase commit (escrow + ack) and the go handshake
T.ANSWER_TIMEOUT = 30
T.START_TIMEOUT = 15          -- after my yes, how long I wait for the asker's go
T.IDLE_TIMEOUT = 180          -- no word from the other side for this long closes the trade
T.LATE_COMMIT = 60            -- how long a trade I accepted and then left still takes the host's commit
T.DEFER_MAX = 600             -- a commit held while I was busy (a battle, another trade) is refused after this long
T.COMMIT_WAIT = 30            -- the host's trade screen waits this long for the answer, then the log carries on
T.RETRY_LIVE = 3              -- the host repeats its commit this often while the screen waits
T.RETRY = 30                  -- ... and this often afterwards (while the game is open)
T.ESCROW_DAYS = 14            -- no answer at all for this long: the host's goods come back
T.LOG_DAYS = 30               -- how long the other side remembers a trade it carried out
T.MAX_STACKS = 6              -- kinds of item one side can put on the table

local ask = nil               -- my open request { id, to, at }
T.session = nil               -- { id, peer, name, host, mine, mineWire, theirs, theirsWire, myOk, theirOk, heard,
                              --   state, committing (host: commit sent, waiting for the ack) }
T.incoming = nil              -- a request waiting for my Yes / No { id, from, at, gone = nil | "them" | "expired" }
T.starting = nil              -- I said yes and wait for the go { id, from, at }
T.last = nil                  -- the trade I accepted and then left { session, at, deferred } (see LATE_COMMIT)
T.onChange = nil              -- the UI's refresh

local tried = {}              -- [trade id] = when the host last sent its commit (this session)

local function Now() return GetTime() end
local function Clock() return (time and time()) or 0 end
local function MyKey() return ns.Util.PlayerKey() end
local function Checkpoint() if G.Checkpoint then G:Checkpoint() end end

local function Print(fmt, ...)
    if ns.Print then ns:Print("|cffffd200Azeromon:|r " .. fmt, ...) end
end

function T:Changed()
    if T.onChange then T.onChange(T.session) end
end

-- The trade log, in the account's game data (not the save, which a /reload mid-script rolls back):
--   [id] = { peer, h, st = "done", at }                                      I'm the other side and carried it out
--   [id] = { peer, name, h, st = "sent" | "ok" | "no", at, slot, mon, items, theirs, theirItems }   I'm the host:
--          my side in escrow; "ok" / "no" = answered, waiting until I'm free to take theirs / have mine back
local function Log()
    local d = G:Data()
    if type(d.tradeLog) ~= "table" then d.tradeLog = {} end
    return d.tradeLog
end

local function Copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
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
                             ot = type(w.ot) == "string" and w.ot ~= "" and w.ot:sub(1, 24) or nil }, true)
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

local function ItemsKey(items)
    local ids = {}
    for id in pairs(items or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    for i, id in ipairs(ids) do ids[i] = id .. "x" .. Str(items[id]) end
    return table.concat(ids, ",")
end

-- The same number on both sides: the two offers (beast and items) in player-key order.
function T.PairHash(s)
    local a = WireKey(s.mineWire) .. "+" .. ItemsKey(s.myItems)
    local b = WireKey(s.theirsWire) .. "+" .. ItemsKey(s.theirItems)
    if not s.host then a, b = b, a end
    return Checksum(a .. "|" .. b)
end

-- Items received on the wire: known items, 1 - 99 each, at most MAX_STACKS kinds.
function T.CleanItems(list)
    local out, n = {}, 0
    if type(list) ~= "table" then return out end
    for id, cnt in pairs(list) do
        cnt = math.floor(tonumber(cnt) or 0)
        if type(id) == "string" and D.items[id] and cnt >= 1 and n < T.MAX_STACKS then
            out[id] = math.min(99, cnt)
            n = n + 1
        end
    end
    return out
end

-- "Copper Bar x5, Peacebloom x3"
function T.ItemsText(items)
    local ids = {}
    for id in pairs(items or {}) do if D.items[id] then ids[#ids + 1] = id end end
    table.sort(ids, function(a, b) return D.items[a].name < D.items[b].name end)
    for i, id in ipairs(ids) do ids[i] = D.items[id].name .. (items[id] > 1 and (" x" .. items[id]) or "") end
    return table.concat(ids, ", ")
end

-- A host trade still waiting for its answer (my side in escrow)? Returns the record.
function T:Unfinished()
    for _, rec in pairs(Log()) do
        if type(rec) == "table" and rec.st ~= "done" then return rec end
    end
end

---------------------------------------------------------------------------
-- Asking (from the overworld script) and being asked
---------------------------------------------------------------------------

function T:Busy() return T.session ~= nil or ask ~= nil or T.incoming ~= nil or T.starting ~= nil end

function T:Ask(g, peer)
    if #g.save.party == 0 then
        g:Say("You have no beasts to trade.")
        return
    end
    local open = T:Unfinished()
    if open then
        g:Say(string.format("Your last trade with %s isn't finished yet. It completes when you're both online.",
            open.name or ns.Util.ShortName(open.peer, true)))
        return
    end
    local id = string.format("%d%04d", math.floor(Now() * 10) % 1000000, math.random(0, 9999))
    ask = { id = id, to = peer.key, at = Now() }
    if not ns.Games:Send(G.GAME_ID, { t = "AZT", op = "ask", id = id, v = T.VERSION }, "WHISPER", peer.key) then
        ask = nil
        g:Say(peer.name .. " can't be reached right now.")
        return
    end
    local answer = g:Wait({ kind = "netwait", text = string.format("Waiting for %s to answer...\n(X to cancel)", peer.name) })
    local a = ask
    ask = nil
    if type(answer) == "table" and answer.ok then
        ns.Games:Send(G.GAME_ID, { t = "AZT", op = "go", id = a.id }, "WHISPER", peer.key)
        T:Open(g, a.id, peer.key)
    elseif answer == "cancel" or answer == "timeout" then
        -- their prompt closes: a late yes opens nothing
        ns.Games:Send(G.GAME_ID, { t = "AZT", op = "cancel", id = a.id }, "WHISPER", peer.key)
        g:Say(answer == "cancel" and "You called off the trade." or (peer.name .. " didn't answer."))
    elseif type(answer) == "table" and answer.why == "busy" then
        g:Say(peer.name .. " is busy right now.")
    elseif type(answer) == "table" and answer.why == "version" then
        g:Say(peer.name .. " has a different game version.")
    else
        g:Say(peer.name .. " doesn't want to trade right now.")
    end
end

local function OnAsk(sender, msg)
    if type(msg.id) ~= "string" then return end
    if msg.v ~= T.VERSION then
        ns.Games:Send(G.GAME_ID, { t = "AZT", op = "answer", id = msg.id, ok = false, why = "version" }, "WHISPER", sender)
        return
    end
    local P = ns.AzeroPvP
    local busy = not G.started or not G:IsFree() or T:Busy() or (P and (P:InMatch() or P.incoming or P.starting))
        or not (ns.AzeroNet and ns.AzeroNet:IsActive()) or #G.save.party == 0 or T:Unfinished() ~= nil
    if busy then
        ns.Games:Send(G.GAME_ID, { t = "AZT", op = "answer", id = msg.id, ok = false, why = "busy" }, "WHISPER", sender)
        return
    end
    local name, id = ns.Util.ShortName(sender, true), msg.id
    T.incoming = { id = id, from = sender, at = Now() }
    G:Run(function(g)
        g:Sfx("request")
        local yes = g:YesNo(string.format("%s would like to trade beasts. Accept?", name))
        local inc = T.incoming
        T.incoming = nil
        local gone = (not inc or inc.id ~= id) and "them" or inc.gone
        if gone == "expired" then
            g:Say("The trade request from " .. name .. " expired.")
            return
        elseif gone then
            g:Say(name .. " called off the trade.")
            return
        end
        if not yes then
            ns.Games:Send(G.GAME_ID, { t = "AZT", op = "answer", id = id, ok = false, why = "no" }, "WHISPER", sender)
            return
        end
        ns.Games:Send(G.GAME_ID, { t = "AZT", op = "answer", id = id, ok = true }, "WHISPER", sender)
        -- the trade opens only once the asker confirms it is still there
        T.starting = { id = id, from = sender, at = Now() }
        local go = g:Wait({ kind = "netwait",
                            text = string.format("Opening the trade with %s...\n(X to cancel)", name) })
        T.starting = nil
        if go == "go" then
            T:Open(g, id, sender)
            return
        end
        ns.Games:Send(G.GAME_ID, { t = "AZT", op = "cancel", id = id }, "WHISPER", sender)
        if go == "cancel" then
            g:Say("You called off the trade.")
        elseif go == "withdrawn" then
            g:Say(name .. " called off the trade.")
        else
            g:Say(name .. " didn't answer.")
        end
    end)
end

local function OnAnswer(sender, msg)
    if ask and msg.id == ask.id and sender == ask.to then
        if G.pending and G.pending.kind == "netwait" then G:Advance({ ok = msg.ok == true, why = msg.why }) end
    elseif msg.ok == true and type(msg.id) == "string" then
        -- a yes I'm no longer waiting for: they back out
        ns.Games:Send(G.GAME_ID, { t = "AZT", op = "cancel", id = msg.id }, "WHISPER", sender)
    end
end

local function OnGo(sender, msg)
    local st = T.starting
    if st and st.id == msg.id and st.from == sender and G.pending and G.pending.kind == "netwait" then
        G:Advance("go")
    end
end

---------------------------------------------------------------------------
-- The trade itself (the UI shows G.pending.kind == "trade" and calls Offer / Confirm / Cancel)
---------------------------------------------------------------------------

function T:Open(g, id, peer)
    local s = { id = id, peer = peer, name = ns.Util.ShortName(peer, true), host = MyKey() < peer, heard = Now(), state = "open",
                myItems = {}, theirItems = {} }
    T.session = s
    local result = g:Wait({ kind = "trade", session = s })
    if T.session == s then T.session = nil end
    if result == "done" then
        if s.sent then g:Say(string.format("You sent %s to %s.", M.Name(s.sent), s.name)) end
        if next(s.gaveItems or {}) then g:Say(string.format("You gave %s: %s.", s.name, T.ItemsText(s.gaveItems))) end
        if next(s.gotItems or {}) then g:Say(string.format("%s gave you %s.", s.name, T.ItemsText(s.gotItems))) end
        if s.received then
            g:Say(string.format("%s sent over %s! Take good care of it.", s.name, M.Name(s.received)))
            local into = M.TradeEvolution(s.received)
            if into then g:EvolveNow(s.received, into) end
        end
    elseif result == "pending" then
        g:Say(string.format("No answer from %s yet. Your side of the trade is held safely and the trade completes "
            .. "as soon as you are both online.", s.name))
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
    if result ~= "done" and result ~= "pending" and s.myOk and not s.host then T.last = { session = s, at = Now() } end
    T:Changed()
    if G.pending and G.pending.kind == "trade" and G.pending.session == s then G:Advance(result) end
end

local function SendOffer(s)
    s.myOk, s.theirOk = nil, nil
    ns.Games:Send(G.GAME_ID, { t = "AZT", op = "offer", id = s.id, mon = s.mineWire, items = s.myItems }, "WHISPER", s.peer)
    T:Changed()
end

-- Offer party beast `idx` (the one already offered again: take it back).
function T:Offer(idx)
    local s = T.session
    local mon = G.save and G.save.party[idx]
    if not s or s.state ~= "open" or not mon or s.myOk then return false end
    if s.mine == mon then
        s.mine, s.mineWire = nil, nil
    else
        s.mine, s.mineWire = mon, T.Pack(mon)
    end
    SendOffer(s)
    return true
end

-- Put `delta` more of an item on the table (negative takes some back); returns the count now offered.
function T:OfferItem(id, delta)
    local s = T.session
    if not s or s.state ~= "open" or s.myOk or not D.items[id] then return nil end
    local have = G.save.bag[id] or 0
    local n = math.max(0, math.min(have, math.min(99, (s.myItems[id] or 0) + delta)))
    local kinds = 0
    for k in pairs(s.myItems) do if k ~= id then kinds = kinds + 1 end end
    if n > 0 and kinds >= T.MAX_STACKS then return s.myItems[id] or 0 end
    s.myItems[id] = n > 0 and n or nil
    SendOffer(s)
    return n
end

function T:TakeBackItems()
    local s = T.session
    if not s or s.state ~= "open" or s.myOk then return false end
    s.myItems = {}
    SendOffer(s)
    return true
end

---------------------------------------------------------------------------
-- Carrying it out
---------------------------------------------------------------------------

-- My side leaves my save: the offered beast and items. Returns ok, the beast's old party slot. Nothing changes
-- unless my side is all still here (and their beast is one I can take).
local function Give(s)
    local save = G.save
    local party, bag = save.party, save.bag
    local slot
    if s.mine then
        for i, m in ipairs(party) do if m == s.mine then slot = i end end
        if not slot then return false end
    end
    for id, n in pairs(s.myItems or {}) do if (bag[id] or 0) < n then return false end end
    if s.theirsWire and not T.Unpack(s.theirsWire) then return false end
    for id, n in pairs(s.myItems or {}) do
        bag[id] = bag[id] - n
        if bag[id] <= 0 then bag[id] = nil end
    end
    if slot then table.remove(party, slot) end
    return true, slot
end

-- Their side arrives: their beast takes my beast's old party slot (else the next free one, else the stable),
-- their items go to my bag. t = { peer, theirs (wire), theirItems, slot, sent, gave }. Returns the beast.
local function Receive(t)
    local save = G.save
    local party, bag = save.party, save.bag
    local got = t.theirs and T.Unpack(t.theirs)
    for id, n in pairs(t.theirItems or {}) do
        if D.items[id] then bag[id] = (bag[id] or 0) + n end
    end
    if got then
        if #party < D.MAX_PARTY then
            table.insert(party, math.min(t.slot or (#party + 1), #party + 1), got)
        else
            table.insert(save.box, got)
        end
        got.traded = (got.ot ~= G:PlayerName()) or nil
        got.tradeEvo = M.TradeEvolution(got)        -- kept until it evolves (an evolution cut short comes back)
        save.seen[got.sp], save.caught[got.sp] = true, true
        if got.shiny then
            if type(save.shinyCaught) ~= "table" then save.shinyCaught = {} end
            save.shinyCaught[got.sp] = true
        end
        G:Emit("tame", { mon = got, how = "traded" })
    end
    local d = G:Data()
    if type(d.trades) ~= "table" then d.trades = {} end
    d.trades[t.peer] = (d.trades[t.peer] or 0) + 1
    G:Emit("trade", { mon = got, sent = t.sent, peer = t.peer, gave = t.gave, got = t.theirItems })
    return got
end

-- My side back from escrow (the other side refused, or never answered).
local function Return(rec)
    local save = G.save
    local mon = type(rec.mon) == "table" and M.Sanitize(rec.mon)
    if mon then
        if #save.party < D.MAX_PARTY then
            table.insert(save.party, math.min(tonumber(rec.slot) or (#save.party + 1), #save.party + 1), mon)
        else
            table.insert(save.box, mon)
        end
    end
    for id, n in pairs(type(rec.items) == "table" and rec.items or {}) do
        if D.items[id] and tonumber(n) then save.bag[id] = (save.bag[id] or 0) + n end
    end
    return mon
end

-- The other side carries out the whole swap at once (on the host's commit).
local function Swap(s)
    local ok, slot = Give(s)
    if not ok then return false end
    s.gaveItems, s.gotItems, s.sent = s.myItems, s.theirItems, s.mine
    s.received = Receive({ peer = s.peer, theirs = s.theirsWire, theirItems = s.theirItems, slot = slot,
                           sent = s.mine, gave = s.myItems })
    return true
end

-- Other side: carry out the commit for session s and answer it. Logged before the answer, so a repeated commit
-- (a lost ack, the host's /reload) is answered from the log and never swaps twice.
local function Apply(s, h)
    if not Swap(s) then
        ns.Games:Send(G.GAME_ID, { t = "AZT", op = "ack", id = s.id, h = h, ok = false }, "WHISPER", s.peer)
        return false
    end
    Log()[s.id] = { peer = s.peer, h = h, st = "done", at = Clock() }
    Checkpoint()
    ns.Games:Send(G.GAME_ID, { t = "AZT", op = "ack", id = s.id, h = h, ok = true }, "WHISPER", s.peer)
    return true
end

-- Host: both accepted. My side goes into escrow (persisted, so a /reload can't bring it back while the other side
-- may already have it), then the commit goes out; their side arrives with the ack (Settle).
local function TryCommit(s)
    if not s.host or s.state ~= "open" or s.committing or not s.myOk or s.myOk ~= s.theirOk then return false end
    local ok, slot = Give(s)
    if not ok then
        ns.Games:Send(G.GAME_ID, { t = "AZT", op = "cancel", id = s.id }, "WHISPER", s.peer)
        Close(s, "cancel", "invalid")
        return false
    end
    Log()[s.id] = { peer = s.peer, name = s.name, h = s.myOk, st = "sent", at = Clock(), slot = slot, mon = s.mine,
                    items = Copy(s.myItems), theirs = s.theirsWire, theirItems = Copy(s.theirItems) }
    Checkpoint()
    s.committing, s.commitAt = true, Now()
    tried[s.id] = Now()
    ns.Games:Send(G.GAME_ID, { t = "AZT", op = "commit", id = s.id, h = s.myOk }, "WHISPER", s.peer)
    T:Changed()
    return true
end

-- Host: an answered commit (rec.st "ok" / "no") is finished here: in the open trade screen right away, otherwise
-- once the game is free (never under a battle or another trade, which hold the party).
local function Settle(id)
    local log = Log()
    local rec = log[id]
    if type(rec) ~= "table" or (rec.st ~= "ok" and rec.st ~= "no") then return end
    local s = T.session
    local live = s and s.id == id and s.committing and s.state == "open"
    if not live and not G:IsFree() then return end
    log[id] = nil
    tried[id] = nil
    if rec.st == "ok" then
        local got = Receive({ peer = rec.peer, theirs = rec.theirs, theirItems = rec.theirItems, slot = rec.slot,
                              sent = rec.mon, gave = rec.items })
        Checkpoint()
        if live then
            s.gaveItems, s.gotItems, s.sent, s.received = s.myItems, s.theirItems, s.mine, got
            Close(s, "done")
        else
            local what = got and M.Name(got) or T.ItemsText(rec.theirItems)
            Print("the trade with %s went through: you received %s.", rec.name or ns.Util.ShortName(rec.peer, true),
                what ~= "" and what or "nothing")
        end
    else
        Return(rec)
        Checkpoint()
        if live then
            Close(s, "cancel", "invalid")
        else
            Print("the trade with %s didn't go through%s. Your side is back with you.", rec.name or ns.Util.ShortName(rec.peer, true),
                rec.expired and " (no answer for days)" or "")
        end
    end
end

-- Accept what's on the table. Returns false and why: "empty" (nothing either side), "last" (my last beast would go
-- with nothing coming back).
function T:Confirm()
    local s = T.session
    if not s or s.state ~= "open" or s.myOk then return false end
    local mine = s.mineWire or next(s.myItems)
    local theirs = s.theirsWire or next(s.theirItems)
    if not mine and not theirs then return false, "empty" end
    if s.mine and not s.theirsWire and #G.save.party <= 1 then return false, "last" end
    s.myOk = T.PairHash(s)
    ns.Games:Send(G.GAME_ID, { t = "AZT", op = "confirm", id = s.id, h = s.myOk }, "WHISPER", s.peer)
    TryCommit(s)
    T:Changed()
    return true
end

-- Leave the trade (not once the host's commit is out: the answer decides it then).
function T:Cancel(why)
    local s = T.session
    if not s or s.state ~= "open" or s.committing then return false end
    ns.Games:Send(G.GAME_ID, { t = "AZT", op = "cancel", id = s.id }, "WHISPER", s.peer)
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
    if not s or s.committing then return end
    local mon = T.Unpack(msg.mon)
    s.theirs, s.theirsWire = mon, mon and msg.mon or nil
    s.theirItems = T.CleanItems(msg.items)
    s.myOk, s.theirOk = nil, nil
    T:Changed()
end

local function OnConfirm(sender, msg)
    local s = Current(sender, msg)
    if not s or s.committing then return end
    s.theirOk = tonumber(msg.h)
    TryCommit(s)
    T:Changed()
end

-- Other side: the host's commit. Only ever carried out here (a host never swaps on a commit), at most once.
local function OnCommit(sender, msg)
    local h, id = tonumber(msg.h), msg.id
    if type(id) ~= "string" then return end
    local rec = Log()[id]
    if type(rec) == "table" then
        if rec.st == "done" and rec.peer == sender then
            ns.Games:Send(G.GAME_ID, { t = "AZT", op = "ack", id = id, h = rec.h, ok = true }, "WHISPER", sender)
        end
        return                                     -- (or my own escrow as the host: never applied from a commit)
    end
    local s = T.session
    if s and s.id == id and s.peer == sender and s.state == "open" then
        if s.host then return end
        s.heard = Now()
        if not s.myOk or s.myOk ~= h then          -- not the pair I accepted (crossed with a new offer)
            ns.Games:Send(G.GAME_ID, { t = "AZT", op = "ack", id = id, h = h, ok = false }, "WHISPER", sender)
            Close(s, "cancel", "invalid")
            return
        end
        if Apply(s, h) then Close(s, "done") else Close(s, "cancel", "invalid") end
        return
    end
    -- a commit for a trade I accepted and then left: it still goes through, once I'm free
    local last = T.last
    if last and last.session.id == id and last.session.peer == sender and not last.session.host then
        local ls = last.session
        if ls.myOk ~= h or (not last.deferred and Now() - last.at > T.LATE_COMMIT) then
            T.last = nil
            ns.Games:Send(G.GAME_ID, { t = "AZT", op = "ack", id = id, h = h, ok = false }, "WHISPER", sender)
            return
        end
        if not G:IsFree() then
            last.deferred = last.deferred or Now()
            ns.Games:Send(G.GAME_ID, { t = "AZT", op = "ack", id = id, h = h, wait = true }, "WHISPER", sender)
            return
        end
        T.last = nil
        if Apply(ls, h) then
            ls.state = "done"
            local what = ls.received and M.Name(ls.received) or T.ItemsText(ls.gotItems)
            Print("the trade with %s went through after all: you received %s.", ls.name,
                what ~= "" and what or "nothing")
        else
            Print("the trade with %s couldn't go through: your side of it had changed. Nothing changed hands.", ls.name)
        end
        return
    end
    -- a trade I don't know (I reloaded before it was carried out): refuse, nothing changed hands on either side
    ns.Games:Send(G.GAME_ID, { t = "AZT", op = "ack", id = id, h = h, ok = false }, "WHISPER", sender)
end

-- Host: the answer to my commit.
local function OnAck(sender, msg)
    local rec = type(msg.id) == "string" and Log()[msg.id]
    if type(rec) ~= "table" or rec.st ~= "sent" or rec.peer ~= sender or rec.h ~= tonumber(msg.h) then return end
    if msg.wait then return end                    -- they're busy: my commit is repeated until they answer
    rec.st = msg.ok == true and "ok" or "no"
    Settle(msg.id)
end

local function OnCancel(sender, msg)
    if T.incoming and T.incoming.id == msg.id and T.incoming.from == sender then
        T.incoming.gone = "them"           -- the Yes / No stays up; answering it says they called it off
        return
    end
    local st = T.starting
    if st and st.id == msg.id and st.from == sender then
        if G.pending and G.pending.kind == "netwait" then G:Advance("withdrawn") end
        return
    end
    local s = T.session
    if s and s.id == msg.id and s.peer == sender and s.state == "open" and not s.committing then
        Close(s, "cancel", "them")
    end
end

local HANDLERS = { ask = OnAsk, answer = OnAnswer, go = OnGo, offer = OnOffer, confirm = OnConfirm,
                   commit = OnCommit, ack = OnAck, cancel = OnCancel }

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
    local inc = T.incoming
    if inc and not inc.gone and now - inc.at > T.ANSWER_TIMEOUT then inc.gone = "expired" end   -- they gave up too
    local st = T.starting
    if st and now - st.at > T.START_TIMEOUT and G.pending and G.pending.kind == "netwait" then G:Advance("timeout") end
    local s = T.session
    if s and s.state == "open" and not s.committing and now - s.heard > T.IDLE_TIMEOUT then
        ns.Games:Send(G.GAME_ID, { t = "AZT", op = "cancel", id = s.id }, "WHISPER", s.peer)
        Close(s, "cancel", "timeout")
    end
    -- other side: a commit held while I was busy
    local last = T.last
    if last and last.deferred then
        local ls = last.session
        if now - last.deferred > T.DEFER_MAX then
            T.last = nil
            ns.Games:Send(G.GAME_ID, { t = "AZT", op = "ack", id = ls.id, h = ls.myOk, ok = false }, "WHISPER", ls.peer)
            Print("the trade with %s was called off: you were busy for too long. Nothing changed hands.", ls.name)
        elseif G:IsFree() then
            OnCommit(ls.peer, { id = ls.id, h = ls.myOk })
        end
    end
    -- host: my commits waiting for an answer
    local clock = Clock()
    for id, rec in pairs(Log()) do
        if type(rec) ~= "table" then
            Log()[id] = nil
        elseif rec.st == "sent" then
            local live = s and s.id == id and s.committing and s.state == "open"
            if live and now - s.commitAt > T.COMMIT_WAIT then
                Close(s, "pending")                    -- the screen closes; the log carries on
                live = false
            end
            if clock - (tonumber(rec.at) or 0) > T.ESCROW_DAYS * 86400 then
                rec.st, rec.expired = "no", true
            elseif now - (tried[id] or -1e9) >= (live and T.RETRY_LIVE or T.RETRY) then
                tried[id] = now
                ns.Games:Send(G.GAME_ID, { t = "AZT", op = "commit", id = id, h = rec.h }, "WHISPER", rec.peer)
            end
        end
        if type(rec) == "table" and (rec.st == "ok" or rec.st == "no") then Settle(id) end
    end
end

-- Old "done" entries are forgotten (the host stops asking long before).
function T:OnLogin()
    local log, clock = Log(), Clock()
    for id, rec in pairs(log) do
        if type(rec) ~= "table" or (rec.st == "done" and clock - (tonumber(rec.at) or 0) > T.LOG_DAYS * 86400) then
            log[id] = nil
        end
    end
end

function T:OnInit()
    if ns.Comm then ns.Comm:Register("AZT", OnMessage) end
end

-- For tests
T._Reset = function() ask, T.session, T.incoming, T.starting, T.last = nil, nil, nil, nil, nil tried = {} end

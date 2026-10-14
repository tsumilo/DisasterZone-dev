if DisasterZoneBoot and DisasterZoneBoot.Run("Core/StrategyCollab.lua", ...) then return end -- DisasterZone: Core/StrategyCollab.lua
-- Strategy boards, together: who has a strategy open, and editing one board with several members at once.
--
-- Presence (SBP on GUILD, the "live" prefix): a client with a saved strategy on its board says so now and then
-- ({ id, m = "e" editing | "v" looking, k = its edit session, pg = its page }); x = it closed the board, q = "who
-- else?" (answered by the clients that have that strategy, or with no id any strategy, open). An entry not heard
-- for PRESENCE_TTL seconds is gone.
--
-- An edit session (k) is the group of editors of one strategy whose boards are the same board. The first editor
-- starts one; a later editor joins the oldest one it hears of: it asks one of its editors for the board (SBJ) and
-- gets it in parts (SBS). From then on every finished action travels as the fields it changed (SBO, whispered to
-- the session's editors): a path into the strategy and the new value. Pages and tables are addressed by their id,
-- drawings by a session id (_u; never saved). Two changes of the same field: the later one (a Lamport clock, then
-- the name) wins everywhere. Each editor's presence carries a hash of its board; two that stay different while both
-- are idle make the one with the later name fetch the board again, which also heals a lost message.
-- Undo / redo of a live board take back my own actions only (the fields I changed), not the board as it was.
-- What is selected travels too (SBC), drawn on the others' maps in the member's class colour.
--
-- Saving stays what it was (the whole strategy on GUILD). A board that turns out equal to the saved strategy has
-- nothing unsaved any more, so one editor's Save settles it for all of them.
--
-- Walking together (SWK on GUILD, the "walk" prefix, its own server budget): someone walking in a strategy's 3D room
-- (UI/StrategyMap3D.lua) says where about once a second, and at once when they start, stop running, jump or turn
-- ({ id, r = the room, x, y, z = their feet in room yards, f = facing, vx, vy = yd/s, s = 1 moving + 2 backward +
-- 4 falling + 8 swimming, d = how they look: a player race's creature display }); { id, off = true } when they stop
-- walking. Only while someone else has that strategy open. The others who have it open show them there, guessing
-- between messages from the speed; one not heard from for WALK_TTL seconds is gone.
local addonName, ns = ...

local Collab = ns:NewModule("StrategyCollab")
local Util = ns.Util

local type, pairs, ipairs, tostring, next = type, pairs, ipairs, tostring, next
local floor, max = math.floor, math.max
local tconcat, tremove = table.concat, table.remove
local strformat = string.format

local PRESENCE_TTL = 40
local HEARTBEAT = 15
local PROBE = 1.5            -- seconds a new editor listens for a session before it starts its own
local JOIN_TIMEOUT = 12      -- seconds without a part of the board before a joiner gives up
local FLUSH = 0.2            -- my actions travel together when they follow each other this closely
local FLUSH_BUSY = 1.5       -- ... and this closely once the channel's budget runs low
-- The server lets an addon prefix send a burst of 10 messages and then one per second: past BUSY messages in
-- BUSY_WINDOW seconds my changes wait for each other and travel in fewer, larger messages.
local BUSY, BUSY_WINDOW = 6, 10
local PART_BYTES = 3000      -- serialized size of one message of a board sent to a joiner (the wire cap is 4000)
local SETTLE = 5             -- an editor is idle this long after the last change (hashes compare only then)
local MAX_OPS = 40           -- per message
local MAX_BATCH = 400        -- ops accepted from one message
local MAX_PATH = 8
local MAX_NODES = 4000       -- values of one op
local MAX_ITEMS = 200        -- drawings / tables / pages a list takes from the wire
local MAX_SEL = 40
local MAX_PARTS = 400        -- of a board sent to a joiner
local MAX_MESSAGES = 60      -- ... and the messages they travel in
local SNAP_ELEMENTS = 30     -- drawings per part
local HISTORY_MAX = 60
local WALK_TTL = 4             -- seconds a walker stays without word from them
local WALK_MAX = 2000          -- yd: a room point further than this from 0 is no room point

local pres = {}              -- [strategy id] = { [member key] = { m, k, pg, sel, at, h, c, idle } }
local mine                   -- what my board shows: { id, m, pg }
local sess                   -- my edit session (see EnterEdit)
local uidCounter = 0
local walkers = {}           -- [member key] = { id, r, x, y, z, f, vx, vy, s, d, at } (Collab:RemoteWalkers)

local function S() return ns.Strategy end
local function Board() return ns.StrategyBoard end

local function State()
    local B = Board()
    return B and B.GetState and B:GetState() or nil
end

local sentAt = {}             -- GetTime() of my latest messages (a ring of BUSY)
local sentI = 0

local function Send(msg, dist, target)
    local Comm = ns.Comm
    sentI = sentI % BUSY + 1
    sentAt[sentI] = GetTime()
    return (Comm and Comm.Send and Comm:Send(msg, dist, target, "live")) and true or false
end

-- Did I send so much lately that the server is about to make my messages wait?
local function Busy()
    local oldest = sentAt[sentI % BUSY + 1]
    return oldest ~= nil and GetTime() - oldest < BUSY_WINDOW
end

local function SerializedSize(v)
    local lib = LibStub and LibStub("LibSerialize", true)
    if not lib then return 0 end
    local ok, text = pcall(lib.Serialize, lib, v)
    return ok and type(text) == "string" and #text or PART_BYTES
end

local function PresenceChanged()
    ns:Fire("STRATEGY_PRESENCE_CHANGED")
end

-- A small delay that differs per member (answers to a question on GUILD should not all leave at once).
local function Stagger(base, spread)
    local me = Util.PlayerKey() or ""
    local n = 0
    for i = 1, #me do n = (n + me:byte(i) * i) % 97 end
    return base + spread * n / 97
end

---------------------------------------------------------------------------
-- Copies, hashes
---------------------------------------------------------------------------

-- A copy without the keys the board keeps for itself ("_w", ...); keepU: the drawings keep their session id.
local function Plain(v, keepU)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do
        if type(k) ~= "string" or k:sub(1, 1) ~= "_" or (keepU and k == "_u") then out[k] = Plain(x, keepU) end
    end
    return out
end

-- Plain, and without empty tables (a cleared cell leaves one behind on one board and not on another).
local function Norm(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do
        if type(k) ~= "string" or k:sub(1, 1) ~= "_" or k == "_u" then
            local c = Norm(x)
            if type(c) ~= "table" or next(c) ~= nil then out[k] = c end
        end
    end
    return out
end

-- What a strategy says (its name, pages and auto-marking), whoever saved it and whenever: equal for a draft and the
-- saved strategy it would become.
function Collab:ContentHash(s)
    if type(s) ~= "table" then return nil end
    local clean = S() and S():Validate(s) or nil
    local src = clean or Plain(s)
    return Util.Hash({ n = src.n, am = src.am == false and 0 or 1, p = Norm(src.p) })
end

function Collab:SameContent(a, b)
    local ha = self:ContentHash(a)
    return ha ~= nil and ha == self:ContentHash(b)
end

-- The board of a session, session ids included.
local function BoardHash(s)
    return Util.Hash({ n = s.n, am = s.am == false and 0 or 1, p = Norm(s.p) })
end

local function NewUid()
    uidCounter = uidCounter + 1
    return "r" .. Util.Hash({ Util.PlayerKey() or "", GetTime(), uidCounter }):sub(1, 5)
end

-- Every drawing gets a session id, unique on its page. byPlace: a drawing without one is named after its place
-- (boards that start from the same saved strategy then agree); otherwise it is new and mine.
local function EnsureUids(strat, byPlace)
    for _, p in ipairs(type(strat) == "table" and type(strat.p) == "table" and strat.p or {}) do
        if type(p) == "table" and type(p.e) == "table" then
            local seen, todo = {}, {}
            for i, e in ipairs(p.e) do
                if type(e) == "table" then
                    local u = e._u
                    if type(u) == "string" and u ~= "" and not seen[u] then
                        seen[u] = true
                    else
                        todo[#todo + 1] = i
                    end
                end
            end
            for _, i in ipairs(todo) do
                local u = byPlace and ("s" .. i) or NewUid()
                while seen[u] do u = NewUid() end
                seen[u] = true
                p.e[i]._u = u
            end
        end
    end
end

---------------------------------------------------------------------------
-- Changes as paths: diff, apply
---------------------------------------------------------------------------

-- The lists whose members have a name: the pages (root.p, by id), a page's drawings (.e, by _u) and tables (.k, id).
local function ListField(path, n)
    if n == 1 and path[1] == "p" then return "id" end
    if n == 3 and path[1] == "p" then
        if path[3] == "e" then return "_u" end
        if path[3] == "k" then return "id" end
    end
    return nil
end

local function Extend(path, n, key)
    local out = {}
    for i = 1, n do out[i] = path[i] end
    out[n + 1] = key
    return out
end

local function Equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if (type(k) ~= "string" or k:sub(1, 1) ~= "_") and not Equal(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if (type(k) ~= "string" or k:sub(1, 1) ~= "_") and a[k] == nil then return false end
    end
    return true
end

local Diff

local function DiffList(la, lb, path, n, field, out)
    local inA, inB = {}, {}
    for _, x in ipairs(la) do
        if type(x) == "table" and x[field] ~= nil then inA[x[field]] = x end
    end
    for _, x in ipairs(lb) do
        if type(x) == "table" and x[field] ~= nil then inB[x[field]] = x end
    end
    local expect = {}
    for _, x in ipairs(la) do
        local id = type(x) == "table" and x[field]
        if id ~= nil and inA[id] == x then
            if inB[id] then
                expect[#expect + 1] = id
            else
                out[#out + 1] = { p = Extend(path, n, id), d = 1 }
            end
        end
    end
    local order = {}
    for _, x in ipairs(lb) do
        local id = type(x) == "table" and x[field]
        if id ~= nil and inB[id] == x then
            order[#order + 1] = id
            if inA[id] then
                Diff(inA[id], x, Extend(path, n, id), n + 1, out)
            else
                out[#out + 1] = { p = Extend(path, n, id), v = Plain(x, true) }
                expect[#expect + 1] = id
            end
        end
    end
    for i = 1, max(#order, #expect) do
        if order[i] ~= expect[i] then
            out[#out + 1] = { p = Extend(path, n, nil), o = order }
            break
        end
    end
end

-- The changes that turn a into b, appended to out: { p = path, v = value } (set), { p, d = 1 } (gone) and
-- { p = a named list, o = its order }.
Diff = function(a, b, path, n, out)
    local keys = {}
    for k in pairs(a) do keys[k] = true end
    for k in pairs(b) do keys[k] = true end
    for k in pairs(keys) do
        if type(k) ~= "string" or k:sub(1, 1) ~= "_" then
            local va, vb = a[k], b[k]
            local sub = Extend(path, n, k)
            local field = ListField(sub, n + 1)
            if field and (va == nil or type(va) == "table") and type(vb) == "table" then
                DiffList(va or {}, vb, sub, n + 1, field, out)
            elseif type(va) == "table" and type(vb) == "table" and #va == #vb and n + 1 < MAX_PATH then
                Diff(va, vb, sub, n + 1, out)
            elseif not Equal(va, vb) then
                if vb == nil then
                    out[#out + 1] = { p = sub, d = 1 }
                else
                    out[#out + 1] = { p = sub, v = Plain(vb, true) }
                end
            end
        end
    end
    return out
end

local function DiffStrategies(a, b)
    return Diff({ n = a.n, am = a.am, p = a.p }, { n = b.n, am = b.am, p = b.p }, {}, 0, {})
end

local function Find(list, field, id)
    for i, x in ipairs(list) do
        if type(x) == "table" and x[field] == id then return x, i end
    end
    return nil
end

local function CountNodes(v, depth)
    if type(v) ~= "table" then return 1 end
    if depth > 10 then return MAX_NODES + 1 end
    local n = 1
    for k, x in pairs(v) do
        local tk = type(k)
        if tk ~= "string" and tk ~= "number" then return MAX_NODES + 1 end
        n = n + CountNodes(x, depth + 1)
        if n > MAX_NODES then return n end
    end
    return n
end

-- Is this a change a board can take (from the wire)?
local function ValidOp(op)
    if type(op) ~= "table" or type(op.p) ~= "table" then return false end
    local p = op.p
    local n = #p
    if n < 1 or n > MAX_PATH then return false end
    for i = 1, n do
        local t = p[i]
        if type(t) == "string" then
            if #t > 24 or t == "" or (t:sub(1, 1) == "_" and t ~= "_u") then return false end
        elseif type(t) ~= "number" or t ~= floor(t) or t < 1 or t > 9999 then
            return false
        end
    end
    local root = p[1]
    if root ~= "n" and root ~= "am" and root ~= "p" then return false end
    if op.o ~= nil then
        if type(op.o) ~= "table" or #op.o > MAX_ITEMS or not ListField(p, n) then return false end
        for _, id in ipairs(op.o) do
            if type(id) ~= "string" or #id > 24 then return false end
        end
        return true
    end
    if root == "n" then return n == 1 and type(op.v) == "string" and #op.v <= 64 end
    if root == "am" then return n == 1 and (op.d == 1 or op.v == false or op.v == true) end
    if n == 1 then return false end                 -- the page list itself only takes an order
    if op.d == 1 then return true end
    if op.v == nil then return false end
    if ListField(p, n - 1) then
        -- a whole page / drawing / table: it carries its own name
        local field = ListField(p, n - 1)
        if type(op.v) ~= "table" or op.v[field] ~= p[n] then return false end
        if n == 2 and not (type(op.v.e) == "table" and type(op.v.k) == "table") then return false end
    end
    return CountNodes(op.v, 0) <= MAX_NODES
end

-- Makes the change on a strategy (in place: a drawing that is selected or dragged stays the same table). Returns
-- false when what it addresses is gone.
local function Apply(strat, op)
    local p = op.p
    local n = #p
    local node = strat
    for i = 1, n - 1 do
        local field = ListField(p, i - 1)
        local nxt
        if field then
            nxt = Find(node, field, p[i])
            if not nxt then return false end
        else
            nxt = node[p[i]]
            if type(nxt) ~= "table" then
                if op.d == 1 or op.o then return false end
                nxt = {}
                node[p[i]] = nxt
            end
        end
        node = nxt
    end
    local key = p[n]
    if op.o then
        local list = node[key]
        local field = ListField(p, n)
        if type(list) ~= "table" or not field then return false end
        local rank = {}
        for i, id in ipairs(op.o) do rank[id] = i end
        local items = {}
        for i, x in ipairs(list) do
            items[i] = { x = x, r = type(x) == "table" and rank[x[field]] or nil, i = i }
        end
        table.sort(items, function(a, b)
            if a.r and b.r then return a.r < b.r end
            if a.r or b.r then return a.r ~= nil end
            return a.i < b.i
        end)
        for i, it in ipairs(items) do list[i] = it.x end
        return true
    end
    local field = ListField(p, n - 1)
    if field then
        local cur, at = Find(node, field, key)
        if op.d == 1 then
            if not cur then return false end
            tremove(node, at)
            return true
        end
        if cur then
            for k in pairs(cur) do
                if type(k) ~= "string" or k:sub(1, 1) ~= "_" or k == "_u" then cur[k] = nil end
            end
            for k, v in pairs(op.v) do cur[k] = Plain(v, true) end
        else
            if #node >= MAX_ITEMS then return false end
            node[#node + 1] = Plain(op.v, true)
        end
        return true
    end
    if op.d == 1 then
        node[key] = nil
    else
        node[key] = Plain(op.v, true)
    end
    return true
end

Collab._Diff, Collab._Apply, Collab._ValidOp = DiffStrategies, Apply, ValidOp   -- for tests

---------------------------------------------------------------------------
-- Who wins: stamps
---------------------------------------------------------------------------

local function StampKey(p, n, order)
    local parts = {}
    for i = 1, n do parts[i] = tostring(p[i]) end
    return tconcat(parts, "\1") .. (order and "\1#" or "")
end

-- May a change stamped (c, who) still land? Not when the field, or something it sits in, changed later.
local function Accept(op, c, who)
    local p = op.p
    local n = #p
    for i = 1, n do
        local s = sess.stamps[StampKey(p, i, i == n and op.o ~= nil)]
        if s and (s.c > c or (s.c == c and s.w > who)) then return false end
    end
    sess.stamps[StampKey(p, n, op.o ~= nil)] = { c = c, w = who }
    return true
end

---------------------------------------------------------------------------
-- Presence
---------------------------------------------------------------------------

local function PageId(st)
    local p = st and st.strat and st.strat.p and st.strat.p[st.page]
    return type(p) == "table" and p.id or nil
end

local function CanEdit(id, key)
    return S() ~= nil and S():CanEditStrategy(id, key)
end

local function Announce(ask)
    if not mine then return end
    local st = State()
    local msg = { t = "SBP", id = mine.id, m = mine.m, pg = mine.pg }
    if ask then msg.q = true end
    if sess and sess.id == mine.id then
        msg.k = sess.k
        if sess.join then
            msg.j = true
        elseif sess.live and st and st.strat then
            msg.h, msg.c = BoardHash(st.strat), sess.clock
            msg.i = (GetTime() - (sess.lastOp or 0)) >= SETTLE - 1 or nil
        end
    end
    mine.sent = GetTime()
    Send(msg, "GUILD")
end

local function AnnounceSoon()
    Util.Debounce("strategy-collab-announce", 0.3, function() Announce(false) end)
end

-- Asks who has strategies open (the list of strategies does, when it opens).
function Collab:Query()
    local Comm = ns.Comm
    if Comm and Comm.RateLimit and not Comm:RateLimit("SBP:query", 20) then return end
    Send({ t = "SBP", q = true }, "GUILD")
end

-- Who else has this strategy open: { key, m = "e" | "v", pg = page id, live = shares my board }, editors first. Only
-- who may change it now shows as editing (a collaborator the owner took off is looking, whatever their board says).
function Collab:GetPresence(id)
    local out = {}
    local now = GetTime()
    for key, e in pairs(pres[id] or {}) do
        if now - e.at <= PRESENCE_TTL then
            local editing = e.m == "e" and CanEdit(id, key)
            out[#out + 1] = { key = key, m = editing and "e" or "v", pg = e.pg,
                live = (editing and sess ~= nil and sess.id == id and sess.peers[key] ~= nil) or nil }
        end
    end
    table.sort(out, function(a, b)
        if a.m ~= b.m then return a.m == "e" end
        return a.key < b.key
    end)
    return out
end

-- The members editing a strategy right now (keys, sorted).
function Collab:GetEditors(id)
    local out = {}
    for _, e in ipairs(self:GetPresence(id)) do
        if e.m == "e" then out[#out + 1] = e.key end
    end
    return out
end

local PALETTE = { { 0.35, 0.8, 1 }, { 1, 0.45, 0.75 }, { 0.5, 1, 0.5 }, { 1, 0.6, 0.25 }, { 0.75, 0.6, 1 } }

-- A member's colour on the board: the class colour, else one of a few.
function Collab:ColorOf(key)
    local G = ns.Guild
    local class = G and G.GetClass and G:GetClass(key)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    local n = 0
    for i = 1, #key do n = (n + key:byte(i)) % #PALETTE end
    local p = PALETTE[n + 1]
    return p[1], p[2], p[3]
end

-- What the editors who share my board have selected on a page: { { key, r, g, b, sel = { [_u] = true } } }.
function Collab:RemoteSelections(pageId)
    local out = {}
    if not (sess and sess.live and pageId) then return out end
    for key in pairs(sess.peers) do
        local e = pres[sess.id] and pres[sess.id][key]
        if e and e.pg == pageId and e.sel and next(e.sel) then
            local r, g, b = self:ColorOf(key)
            out[#out + 1] = { key = key, r = r, g = g, b = b, sel = e.sel }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

---------------------------------------------------------------------------
-- The session
---------------------------------------------------------------------------

local function NewK()
    local now = Util.Now()
    return strformat("%010d", now) .. Util.Hash({ Util.PlayerKey() or "", GetTime() }):sub(1, 4)
end

local function SendPeers(msg)
    for key in pairs(sess.peers) do Send(msg, "WHISPER", key) end
end

-- My pending actions leave (one message per MAX_OPS changes).
local function Flush()
    if not (sess and sess.out and #sess.out > 0) then
        if sess then sess.out = nil end
        return
    end
    local ops, c = sess.out, sess.outC
    sess.out, sess.outC = nil, nil
    if not next(sess.peers) then return end
    for i = 1, #ops, MAX_OPS do
        local part = {}
        for j = i, math.min(i + MAX_OPS - 1, #ops) do part[#part + 1] = ops[j] end
        SendPeers({ t = "SBO", id = sess.id, k = sess.k, c = c, o = part })
    end
end

local function Touch()
    sess.lastOp = GetTime()
    -- once the board is quiet again its hash goes out, so a board that drifted is noticed soon
    Util.Debounce("strategy-collab-settle", SETTLE, function()
        if sess and sess.live then Announce(false) end
    end)
end

-- The board becomes a shared one: its drawings get their names and my changes are followed from here on.
local function GoLive()
    if not sess or sess.live then return end
    local st = State()
    if not (st and st.strat) then return end
    EnsureUids(st.strat, true)
    sess.live = true
    sess.shadow = Plain(st.strat, true)
    sess.stamps, sess.hist, sess.histI = {}, {}, 0
    st.liveK = sess.k
    st.hist, st.histI = nil, nil
end

-- What changed on my board since the last look travels to the others. undoable: it is an action of mine to take
-- back later (not when it is itself an undo / redo).
local function Commit(undoable)
    local st = State()
    if not (sess and sess.live and st and st.strat) then return false end
    EnsureUids(st.strat, false)
    local ops = DiffStrategies(sess.shadow, st.strat)
    if #ops == 0 then return false end
    if undoable then
        local h = sess.hist
        for i = #h, sess.histI + 1, -1 do h[i] = nil end
        h[#h + 1] = { f = ops, i = DiffStrategies(st.strat, sess.shadow) }
        if #h > HISTORY_MAX then tremove(h, 1) end
        sess.histI = #h
    end
    sess.shadow = Plain(st.strat, true)
    if not sess.out then
        sess.clock = sess.clock + 1
        sess.out, sess.outC = {}, sess.clock
        Util.After(Busy() and FLUSH_BUSY or FLUSH, function() if sess then Flush() end end)
    end
    local me = Util.PlayerKey() or ""
    for _, op in ipairs(ops) do
        sess.stamps[StampKey(op.p, #op.p, op.o ~= nil)] = { c = sess.outC, w = me }
        sess.out[#sess.out + 1] = op
    end
    Touch()
    return true
end

local function LeaveSession()
    if not sess then return end
    Flush()
    sess = nil
end

local function RefreshBoard()
    Util.Debounce("strategy-collab-board", 0.05, function()
        local B = Board()
        if B and B.IsShown and B:IsShown() then B:Refresh() end
    end)
end

local function StartOwn()
    if not sess or sess.k then return end
    sess.k = NewK()
    AnnounceSoon()
end

local Join

-- The oldest session of my strategy that is not mine: its key and one of its editors.
local function OtherSession()
    local bestK, bestKey
    for key, e in pairs(pres[sess.id] or {}) do
        if e.m == "e" and e.k and not e.j and e.k ~= sess.k and GetTime() - e.at <= PRESENCE_TTL
            and CanEdit(sess.id, key) then
            if not bestK or e.k < bestK or (e.k == bestK and key < bestKey) then bestK, bestKey = e.k, key end
        end
    end
    return bestK, bestKey
end

-- Joins the older session there is, or starts mine.
local function Decide()
    if not sess or sess.join then return end
    local st = State()
    if not (st and st.strat) then return end
    local k, key = OtherSession()
    if not k or (sess.k and sess.k < k) then return StartOwn() end
    if sess.asked[k] then return StartOwn() end
    sess.asked[k] = true
    -- my unsaved work was never part of that board: joining drops it, so ask
    if st.dirty and st.liveK ~= k then
        StartOwn()
        local id = sess.id
        local PlanUI = ns.RaidPlanUI
        if PlanUI and PlanUI.Confirm then
            PlanUI:Confirm(("%s is editing this strategy right now. Join that board? Your own unsaved changes to it are dropped.")
                :format(Util.ShortName(key)), function()
                if sess and sess.id == id and not sess.join then Join(key, k) end
            end)
        end
        return
    end
    Join(key, k)
end

Join = function(key, k)
    Flush()
    sess.k = k
    sess.join = { from = key, at = GetTime(), buf = {}, parts = {} }
    sess.peers = {}
    for other, e in pairs(pres[sess.id] or {}) do
        if e.m == "e" and e.k == k then sess.peers[other] = true end
    end
    sess.peers[key] = true
    Announce(false)
    Send({ t = "SBJ", id = sess.id, k = k }, "WHISPER", key)
    local token = sess.join
    local function check()
        if not (sess and sess.join == token) then return end
        local left = JOIN_TIMEOUT - (GetTime() - token.at)
        if left > 0 then return Util.After(left + 0.1, check) end
        -- nobody answered (or the board stopped coming): go on alone
        sess.join, sess.k, sess.peers = nil, nil, {}
        StartOwn()
        ns:Print("The live board did not answer; you are editing on your own.")
        RefreshBoard()
    end
    Util.After(JOIN_TIMEOUT, check)
    PresenceChanged()
end

local function EnterEdit(id)
    if sess and sess.id == id then return end
    LeaveSession()
    sess = { id = id, k = nil, peers = {}, clock = 0, stamps = {}, hist = {}, histI = 0, asked = {}, miss = {},
        lastOp = 0 }
    local token = sess
    Util.After(PROBE, function()
        if sess == token then Decide() end
    end)
end

-- The board shows something else (or nothing): my presence and my session follow. Cheap; called on every refresh.
function Collab:BoardChanged()
    local B = Board()
    local st = State()
    local shown = B and B.IsShown and B:IsShown()
    local id = shown and st and st.strat and st.strat.id or nil
    if not id then
        if mine then
            Send({ t = "SBP", id = mine.id, x = true }, "GUILD")
            mine = nil
            LeaveSession()
        end
        return
    end
    local m = (st.mode == "edit" and not st.occ) and "e" or "v"
    local pg = PageId(st)
    if not mine or mine.id ~= id or mine.m ~= m then
        if mine and mine.id ~= id then Send({ t = "SBP", id = mine.id, x = true }, "GUILD") end
        local fresh = not mine or mine.id ~= id
        mine = { id = id, m = m, pg = pg }
        if m == "e" then EnterEdit(id) else LeaveSession() end
        Announce(fresh or m == "e")
    elseif mine.pg ~= pg then
        mine.pg = pg
        AnnounceSoon()
        self:SetSelection(nil)
    end
end

-- The board holds another copy of the strategy (the saved one replaced it): a live board starts over from it.
function Collab:Adopted()
    local st = State()
    if not (sess and sess.live and st and st.strat) then return end
    EnsureUids(st.strat, true)
    sess.shadow = Plain(st.strat, true)
    sess.stamps, sess.hist, sess.histI = {}, {}, 0
    Touch()
end

function Collab:IsLive()
    return sess ~= nil and sess.live == true
end

-- Am I fetching the board of the session I am joining? progress: the share of it that arrived (0-1).
function Collab:IsJoining()
    local j = sess and sess.join
    if not j then return false end
    local got = 0
    for _ in pairs(j.parts) do got = got + 1 end
    return true, j.of and got / j.of or 0
end

-- The key of my edit session (nil: not editing a saved strategy, or still listening for one).
function Collab:GetSession()
    return sess and sess.k or nil
end

-- The members whose board is mine (keys).
function Collab:GetPeers()
    local out = {}
    for key in pairs(sess and sess.peers or {}) do out[#out + 1] = key end
    table.sort(out)
    return out
end

-- An action on the board finished (Board:MarkDirty).
function Collab:LocalChange()
    if sess and sess.live and not sess.join then Commit(true) end
end

local function Replay(ops)
    local st = State()
    if not (st and st.strat) then return false end
    for _, op in ipairs(ops) do Apply(st.strat, op) end
    Commit(false)
    st.dirty = true
    if not st.strat.p[st.page] then st.page = 1 end
    local B = Board()
    if B then B:Refresh() end
    return true
end

function Collab:CanUndo() return sess ~= nil and sess.live and sess.histI >= 1 end
function Collab:CanRedo() return sess ~= nil and sess.live and sess.histI < #sess.hist end

-- Takes my last action back (the fields it changed; what the others did stays).
function Collab:Undo()
    if not self:CanUndo() then return false end
    local h = sess.hist[sess.histI]
    sess.histI = sess.histI - 1
    return Replay(h.i)
end

function Collab:Redo()
    if not self:CanRedo() then return false end
    sess.histI = sess.histI + 1
    return Replay(sess.hist[sess.histI].f)
end

-- What I have selected (session ids of drawings on my page; nil: nothing).
function Collab:SetSelection(uids)
    if not (sess and sess.live) then return end
    local list = {}
    for i, u in ipairs(uids or {}) do
        if i > MAX_SEL then break end
        if type(u) == "string" then list[#list + 1] = u end
    end
    table.sort(list)
    local sig = (mine and mine.pg or "") .. ":" .. tconcat(list, ",")
    if sess.selSig == sig then return end
    sess.selSig = sig
    sess.selOut = list
    local function send()
        if not (sess and sess.live and sess.selOut and next(sess.peers)) then return end
        if Busy() then
            -- the changes themselves go first
            Util.Debounce("strategy-collab-sel", FLUSH_BUSY, send)
            return
        end
        SendPeers({ t = "SBC", id = sess.id, k = sess.k, pg = mine and mine.pg, s = sess.selOut })
    end
    Util.Debounce("strategy-collab-sel", 0.4, send)
end

---------------------------------------------------------------------------
-- Walking together
---------------------------------------------------------------------------

local function Num(v, lo, hi)
    return type(v) == "number" and v == v and v >= lo and v <= hi
end

-- Tells the others who have my board's strategy open where I walk in its room (w: { r, x, y, z, f, vx, vy, s, d }),
-- or that I stopped (nil). -> true when it went out.
function Collab:SendWalk(w)
    if not (mine and mine.id) then return false end
    local others = pres[mine.id]
    if not (others and next(others)) then return false end
    local msg
    if w then
        local function r2(v) return floor((v or 0) * 100 + 0.5) / 100 end
        msg = { t = "SWK", id = mine.id, r = w.r, x = r2(w.x), y = r2(w.y), z = r2(w.z), f = r2(w.f), vx = r2(w.vx),
                vy = r2(w.vy), s = w.s or 0, d = w.d, ts = r2(GetTime()) }
    else
        msg = { t = "SWK", id = mine.id, off = true }
    end
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, "GUILD", nil, "walk")) and true or false
end

-- SWK: someone walking in a strategy's room (see the top of the file).
local function OnWalk(sender, msg, dist)
    if dist ~= "GUILD" or type(msg.id) ~= "string" or #msg.id > 40 then return end
    if msg.off then
        walkers[sender] = nil
        return
    end
    if type(msg.r) ~= "string" or #msg.r > 60 then return end
    if not (Num(msg.x, -WALK_MAX, WALK_MAX) and Num(msg.y, -WALK_MAX, WALK_MAX) and Num(msg.z, -WALK_MAX, WALK_MAX)
            and Num(msg.f, -1000, 1000) and Num(msg.vx, -100, 100) and Num(msg.vy, -100, 100)) then return end
    -- when they were there, on my clock: a word held up in the send queue is older than its arrival says, and
    -- counted from the arrival it drew them behind, then ahead at the next one (to and fro). Their clock's offset
    -- from mine is the smallest gap yet between their stamp and my arrival (it creeps up 0.05 s a word, for a
    -- clock that moved); a member on an older version sends no stamp: from the arrival, as before
    local now, at, gap = GetTime(), nil, nil
    if Num(msg.ts, 0, 1e9) then
        local old = walkers[sender]
        gap = now - msg.ts
        if old and old.gap then gap = math.min(gap, old.gap + 0.05) end
        at = math.min(now, msg.ts + gap)
    end
    walkers[sender] = { id = msg.id, r = msg.r, x = msg.x, y = msg.y, z = msg.z, f = msg.f, vx = msg.vx, vy = msg.vy,
                        s = Num(msg.s, 0, 15) and floor(msg.s) or 0, d = Num(msg.d, 1, 1e7) and floor(msg.d) or nil,
                        at = at or now, gap = gap, heard = now }
end

-- Who walks in strategy `id`'s room `roomKey` now (not me): { key, x, y, z, f, vx, vy, s, d, age (seconds since
-- they were where their last word says, sent time on my clock), r, g, b (their class colour) }, by name.
function Collab:RemoteWalkers(id, roomKey)
    local out, now = {}, GetTime()
    for key, w in pairs(walkers) do
        if now - w.heard > WALK_TTL then
            walkers[key] = nil
        elseif w.id == id and w.r == roomKey then
            local r, g, b = self:ColorOf(key)
            out[#out + 1] = { key = key, x = w.x, y = w.y, z = w.z, f = w.f, vx = w.vx, vy = w.vy, s = w.s, d = w.d,
                              age = now - w.at, r = r, g = g, b = b }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------

local function DropPeer(key)
    if sess and sess.peers[key] then
        sess.peers[key] = nil
        sess.miss[key] = nil
    end
end

local function ApplyRemote(sender, c, ops)
    local st = State()
    if not (st and st.strat) then return end
    Flush()
    sess.clock = max(sess.clock, c)
    local any = false
    for i = 1, #ops do
        local op = ops[i]
        if ValidOp(op) and Accept(op, c, sender) then
            Apply(sess.shadow, op)
            if Apply(st.strat, op) then any = true end
        end
    end
    Touch()
    if any then
        if not st.strat.p[st.page] then st.page = 1 end
        st.dirty = true
        RefreshBoard()
    end
end

-- SBO { id, k, c, o }: an editor's changes.
local function OnOps(sender, msg, dist)
    if dist ~= "WHISPER" or not sess or msg.id ~= sess.id or msg.k ~= sess.k or not sess.k then return end
    if type(msg.c) ~= "number" or type(msg.o) ~= "table" or #msg.o > MAX_BATCH then return end
    if not CanEdit(sess.id, sender) then return end
    if sess.join then
        if #sess.join.buf < 200 then sess.join.buf[#sess.join.buf + 1] = { w = sender, c = msg.c, o = msg.o } end
        return
    end
    if not sess.peers[sender] then sess.peers[sender] = true end
    GoLive()
    ApplyRemote(sender, msg.c, msg.o)
end

-- SBC { id, k, pg, s }: what an editor has selected.
local function OnSelection(sender, msg, dist)
    if dist ~= "WHISPER" or not sess or msg.id ~= sess.id or msg.k ~= sess.k then return end
    local e = pres[sess.id] and pres[sess.id][sender]
    if not e or type(msg.s) ~= "table" then return end
    local sel = {}
    for i = 1, MAX_SEL do
        local u = msg.s[i]
        if u == nil then break end
        if type(u) == "string" and #u <= 24 then sel[u] = true end
    end
    e.sel = sel
    if type(msg.pg) == "string" and #msg.pg <= 24 then e.pg = msg.pg end
    PresenceChanged()
end

-- SBJ { id, k }: an editor wants my board. It leaves in parts: the head, then per page its fields, its drawings (a
-- few per part) and its tables (one per part).
local function OnJoin(sender, msg, dist)
    if dist ~= "WHISPER" or not sess or sess.join or msg.id ~= sess.id or not sess.k or msg.k ~= sess.k then return end
    if not CanEdit(sess.id, sender) then return end
    local Comm = ns.Comm
    if Comm and Comm.RateLimit and not Comm:RateLimit("SBJ:" .. sender, 3) then return end
    local st = State()
    if not (st and st.strat) then return end
    GoLive()
    Flush()
    sess.peers[sender] = true
    local s = st.strat
    local parts = {}
    for i, p in ipairs(s.p) do
        local head = {}
        for k, v in pairs(p) do
            if k ~= "e" and k ~= "k" and (type(k) ~= "string" or k:sub(1, 1) ~= "_") then head[k] = Plain(v, true) end
        end
        parts[#parts + 1] = { pi = i, p = head }
        local e = p.e or {}
        for from = 1, #e, SNAP_ELEMENTS do
            local chunk = {}
            for j = from, math.min(from + SNAP_ELEMENTS - 1, #e) do chunk[#chunk + 1] = Plain(e[j], true) end
            parts[#parts + 1] = { pi = i, e = chunk }
        end
        for _, k in ipairs(p.k or {}) do parts[#parts + 1] = { pi = i, b = Plain(k, true) } end
    end
    -- as few messages as the wire cap allows (every message costs the channel's budget, however small)
    local messages, cur, size = {}, nil, 0
    for _, part in ipairs(parts) do
        local n = SerializedSize(part)
        if not cur or size + n > PART_BYTES then
            cur, size = {}, 60
            messages[#messages + 1] = cur
        end
        cur[#cur + 1] = part
        size = size + n
    end
    for i, list in ipairs(messages) do
        local msg = { t = "SBS", id = sess.id, k = sess.k, s = i, of = #messages, l = list }
        if i == 1 then msg.h = { n = s.n, am = s.am, c = sess.clock } end
        Send(msg, "WHISPER", sender)
    end
    AnnounceSoon()
    PresenceChanged()
end

-- The board I asked for is complete: it replaces mine.
local function Assemble()
    local j = sess.join
    local head = j.head
    local st = State()
    if not (st and st.strat) then return end
    local parts = {}
    for i = 1, j.of do
        for _, part in ipairs(j.parts[i]) do
            if type(part) ~= "table" or #parts >= MAX_PARTS then return false end
            parts[#parts + 1] = part
        end
    end
    local pages = {}
    for _, part in ipairs(parts) do
        local pi = part.pi
        if type(pi) ~= "number" or pi < 1 or pi > S().MAX_PAGES then return false end
        if type(part.p) == "table" then
            if pages[pi] or type(part.p.id) ~= "string" then return false end
            pages[pi] = Plain(part.p, true)
            pages[pi].e, pages[pi].k = {}, {}
        elseif not pages[pi] then
            return false
        elseif type(part.e) == "table" then
            for _, e in ipairs(part.e) do
                if type(e) == "table" and #pages[pi].e < MAX_ITEMS then
                    pages[pi].e[#pages[pi].e + 1] = Plain(e, true)
                end
            end
        elseif type(part.b) == "table" and type(part.b.id) == "string" then
            pages[pi].k[#pages[pi].k + 1] = Plain(part.b, true)
        end
    end
    if #pages == 0 then return false end
    for i = 1, #pages do
        if not pages[i] then return false end
    end
    local old = st.strat
    local s = { id = old.id, b = old.b, rev = old.rev, by = old.by, ow = old.ow, co = old.co,
        n = type(head.n) == "string" and head.n or old.n, p = pages }
    if head.am == false then s.am = false end
    EnsureUids(s, true)
    st.strat = s
    if not s.p[st.page] then st.page = 1 end
    sess.join = nil
    sess.live = true
    sess.shadow = Plain(s, true)
    sess.stamps, sess.hist, sess.histI = {}, {}, 0
    sess.clock = max(sess.clock, type(head.c) == "number" and head.c or 0)
    sess.miss = {}
    st.liveK = sess.k
    st.hist, st.histI = nil, nil
    local saved = S():GetStrategy(s.id)
    st.dirty = not (saved and Collab:SameContent(saved, s))
    -- what the others did while the board was on its way
    for _, b in ipairs(j.buf) do
        if b.c > (head.c or 0) then ApplyRemote(b.w, b.c, b.o) end
    end
    Touch()
    Announce(false)
    PresenceChanged()
    local B = Board()
    if B then B:Refresh() end
    return true
end

-- SBS { id, k, s, of, l, h }: message s of `of` of the board I asked for (l = its parts; h = the head: name,
-- auto-marking and the sender's clock, in the first).
local function OnSnapshot(sender, msg, dist)
    if dist ~= "WHISPER" or not sess or not sess.join or sender ~= sess.join.from then return end
    if msg.id ~= sess.id or msg.k ~= sess.k or type(msg.l) ~= "table" then return end
    local j = sess.join
    local i, of = msg.s, msg.of
    if type(i) ~= "number" or type(of) ~= "number" or of ~= floor(of) or i ~= floor(i) then return end
    if of < 1 or of > MAX_MESSAGES or i < 1 or i > of or (j.of and j.of ~= of) then return end
    j.of = of
    j.parts[i] = msg.l
    j.at = GetTime()
    if i == 1 and type(msg.h) == "table" then j.head = msg.h end
    for n = 1, of do
        if not j.parts[n] then
            RefreshBoard()
            return
        end
    end
    if not j.head or Assemble() == false then
        sess.join, sess.k, sess.peers = nil, nil, {}
        StartOwn()
        ns:Print("The live board could not be read; you are editing on your own.")
        RefreshBoard()
    end
end

-- Two boards of one session that stay different while nobody touches them: the later name fetches the other's.
local function CompareBoards(sender, msg)
    if not (sess.live and msg.h and msg.i) or sess.join then return end
    if GetTime() - (sess.lastOp or 0) < SETTLE - 1 or sess.out then return end
    local st = State()
    if not (st and st.strat) then return end
    if msg.h == BoardHash(st.strat) then
        sess.miss[sender] = nil
        return
    end
    sess.miss[sender] = (sess.miss[sender] or 0) + 1
    if sess.miss[sender] >= 2 and (Util.PlayerKey() or "") > sender then
        sess.miss[sender] = nil
        ns:Debug("StrategyCollab: my board differs from %s's, fetching theirs", sender)
        Join(sender, sess.k)
    end
end

-- SBP: who has what open.
local function OnPresence(sender, msg, dist)
    if dist ~= "GUILD" then return end
    local id = msg.id
    if id == nil then
        if msg.q and mine then Util.After(Stagger(0.2, 1.5), function() Announce(false) end) end
        return
    end
    if type(id) ~= "string" or #id > 24 then return end
    if msg.x then
        walkers[sender] = nil
        if pres[id] and pres[id][sender] then
            pres[id][sender] = nil
            if not next(pres[id]) then pres[id] = nil end
            if sess and sess.id == id then DropPeer(sender) end
            PresenceChanged()
        end
        return
    end
    local m = msg.m == "e" and "e" or "v"
    -- a board shows one strategy
    for other, list in pairs(pres) do
        if other ~= id and list[sender] then
            list[sender] = nil
            if not next(list) then pres[other] = nil end
            if sess and sess.id == other then DropPeer(sender) end
        end
    end
    pres[id] = pres[id] or {}
    local old = pres[id][sender]
    local e = { m = m, at = GetTime() }
    if m == "e" and type(msg.k) == "string" and #msg.k <= 16 then e.k, e.j = msg.k, msg.j and true or nil end
    if type(msg.pg) == "string" and #msg.pg <= 24 then e.pg = msg.pg end
    if old and old.pg == e.pg and old.k == e.k then e.sel = old.sel end
    pres[id][sender] = e
    if not old or old.m ~= e.m or old.k ~= e.k or old.pg ~= e.pg then PresenceChanged() end

    if msg.q and mine and mine.id == id then
        Util.After(Stagger(0.1, 0.5), function() Announce(false) end)
    end
    if not (sess and sess.id == id) then return end
    if e.k and sess.k and e.k == sess.k and CanEdit(id, sender) then
        if not sess.join then
            if not sess.peers[sender] then
                sess.peers[sender] = true
                GoLive()
                PresenceChanged()
                RefreshBoard()
            end
            if not e.j then CompareBoards(sender, msg) end
        end
    else
        DropPeer(sender)
        -- another session of my strategy: the older one is the one to be in
        if e.k and not e.j and sess.k and not sess.join and e.k < sess.k then
            Util.Debounce("strategy-collab-decide", 0.3, Decide)
        end
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function Tick()
    local now = GetTime()
    local changed = false
    for id, list in pairs(pres) do
        for key, e in pairs(list) do
            if now - e.at > PRESENCE_TTL then
                list[key] = nil
                if sess and sess.id == id then DropPeer(key) end
                changed = true
            end
        end
        if not next(list) then pres[id] = nil end
    end
    if changed then PresenceChanged() end
    if mine and now - (mine.sent or 0) >= HEARTBEAT then Announce(false) end
end

function Collab:OnInit()
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("SBP", OnPresence)
        Comm:Register("SBJ", OnJoin)
        Comm:Register("SBS", OnSnapshot)
        Comm:Register("SBO", OnOps)
        Comm:Register("SBC", OnSelection)
        Comm:Register("SWK", OnWalk)
        -- one action can carry a whole page (a pasted / duplicated one): as large as a saved strategy may be
        if Comm.AllowLarge then Comm:AllowLarge("SBO", "live") end
    end
end

function Collab:OnLogin()
    if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(5, function() ns.SafeCall(Tick) end) end
end

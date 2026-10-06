if DisasterZoneBoot and DisasterZoneBoot.Run("Core/EventEngine.lua", ...) then return end -- DisasterZone: runs an event's pieces.
-- The interpreter of an event (Core/EventBlocks.lua's pieces) and its smart blocks. A run belongs to its host's client
-- (or to the builder's practice run): stages, scripts, timers, the Sign-up and Bracket blocks, variables, stats,
-- badges, moments. It knows nothing of the network: everything it does to the world goes through an output adapter
-- (opts.out: say, whisper, announce, ...), facts come in through run:Duel / Join / SetReady / SetOnline / Answer, and
-- its state is one plain table (run:Snapshot) that the live layer (Core/EventLive.lua) sends to everyone and a new
-- host restores (E:Restore) when the old one is gone.
--
-- Scripts run as coroutines: "wait", "ask ... who won" and "wait until" pause their own script only. Every trigger is
-- queued and handled in order (a script that fires an event, e.g. "go to stage", finishes first). A script that runs
-- more than STEP_LIMIT pieces without waiting is stopped (an endless loop), as are scripts past THREAD_LIMIT at once.
local addonName, ns = ...

local E = ns:NewModule("EventEngine")

local type, pairs, ipairs, tostring, tonumber, next, select = type, pairs, ipairs, tostring, tonumber, next, select
local tinsert, tremove, tconcat, tsort = table.insert, table.remove, table.concat, table.sort
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local strformat, strlower, strfind = string.format, string.lower, string.find
local cocreate, coresume, costatus, coyield = coroutine.create, coroutine.resume, coroutine.status, coroutine.yield

local STEP_LIMIT = 2000      -- pieces one script may run before it waits
local THREAD_LIMIT = 60      -- scripts running (waiting) at once
local TIMER_LIMIT = 64
local MOMENT_LIMIT = 30
local ASK_SECONDS = 60       -- "ask ... who won" waits this long for the answers
local QUEUE_LIMIT = 500      -- events handled in one go (a chain of "go to stage" ping-pong stops here)

local function B() return ns.EventBlocks end
local Copy = function(v) return ns.EventBlocks.Copy(v) end

local function Contains(list, v)
    for i = 1, #list do if list[i] == v then return i end end
    return nil
end

local Run = {}
Run.__index = Run

---------------------------------------------------------------------------
-- Random numbers: the run's own (its state travels with the snapshot, so a new host goes on the same way)
---------------------------------------------------------------------------

local function Rand(st, lo, hi)
    st.rng = (st.rng * 1103515245 + 12345) % 2147483648
    if not lo then return st.rng / 2147483648 end
    return lo + floor(st.rng / 2147483648 * (hi - lo + 1))
end

local function Shuffle(st, list)
    for i = #list, 2, -1 do
        local j = Rand(st, 1, i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

local function SeedFrom(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 2147483647 end
    return h
end

---------------------------------------------------------------------------
-- New / restore
---------------------------------------------------------------------------

-- opts: { id, host, out, practice, signups = { key ... } (sign-up order), entrants (no Sign-up block), now = fn,
--         rankOf = fn(key) -> season rank | nil, nameOf = fn(key) -> display name }
function E:New(def, opts)
    opts = opts or {}
    local id = opts.id or "run"
    local st = {
        v = 1, id = id, host = opts.host, phase = "ready", seq = 0, rng = SeedFrom(id),
        stage = nil, t0 = nil, t1 = nil,
        entrants = {}, signups = Copy(opts.signups or {}), ready = {}, off = {},
        vars = {}, stats = {}, timers = {}, blocks = {}, moments = {}, awards = {}, asks = {},
        ann = nil, cd = nil, everyAt = {}, askSeq = 0, practice = opts.practice and true or nil,
    }
    for _, k in ipairs(opts.entrants or opts.signups or {}) do st.entrants[#st.entrants + 1] = k end
    return self:Restore(def, st, opts)
end

-- A run from a snapshot (a new host, or a /reload of the host): its scripts that were waiting are gone, everything
-- else (timers, matches, stats, the stage) goes on.
function E:Restore(def, st, opts)
    opts = opts or {}
    -- a state from another client: every part it must have (a broken one would stop the run each second)
    for _, k in ipairs({ "entrants", "signups", "ready", "off", "vars", "stats", "timers", "blocks", "moments", "awards",
                         "asks", "everyAt" }) do
        if type(st[k]) ~= "table" then st[k] = {} end
    end
    if type(st.seq) ~= "number" then st.seq = 0 end
    if type(st.askSeq) ~= "number" then st.askSeq = 0 end
    if type(st.rng) ~= "number" then st.rng = SeedFrom(tostring(st.id or "run")) end
    for i = #st.timers, 1, -1 do
        local t = st.timers[i]
        if type(t) ~= "table" or type(t.n) ~= "string" or type(t.at) ~= "number" then tremove(st.timers, i) end
    end
    -- the scripts waiting for answers are gone, and with them their questions (they'd be on screens for good)
    for id in pairs(st.asks) do st.asks[id] = nil end
    local run = setmetatable({}, Run)
    run.def = Copy(def)
    run.st = st
    run.out = opts.out or {}
    run.now = opts.now or function() return (GetServerTime and GetServerTime()) or time() end
    run.rankOf = opts.rankOf
    run.nameOf = opts.nameOf
    run.threads = {}
    run.queue = {}
    run.log = {}
    run:IndexScripts()
    return run
end

function Run:Snapshot()
    return Copy(self.st)
end

-- Scripts by their hat's key: user scripts, then each smart block's own (its copy, or the built-in ones).
function Run:IndexScripts()
    local by = {}
    local function add(s, block)
        local top = s.top
        if type(top) ~= "table" or not top.k then return end
        local pd = B().PIECES[top.k]
        if not pd or pd.shape ~= "hat" then return end
        by[top.k] = by[top.k] or {}
        tinsert(by[top.k], { id = s.id, st = s.st or "*", top = top, block = block })
    end
    for _, s in ipairs(self.def.scripts or {}) do add(s, nil) end
    for bid, b in pairs(self.def.blocks or {}) do
        local inner = b.inner
        if not inner and b.kind == "bracket" then inner = B():BracketInner() end
        for _, s in ipairs(inner or {}) do add(s, bid) end
    end
    self.byHat = by
end

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------

function Run:Name(key)
    if not key then return "nobody" end
    if self.nameOf then return self.nameOf(key) or key end
    if ns.Util and ns.Util.ShortName then return ns.Util.ShortName(key) end
    return key
end

function Run:Log(kind, text, extra)
    local now = self.now()
    tinsert(self.log, { at = now, kind = kind, text = text, extra = extra })
    if #self.log > 200 then tremove(self.log, 1) end
    if self.out.log then self.out.log(kind, text, extra) end
end

function Run:Changed()
    self.st.seq = self.st.seq + 1
    if self.out.changed then self.out.changed(self) end
end

local function Out(run, fn, ...)
    local f = run.out[fn]
    if f then return f(...) end
end

---------------------------------------------------------------------------
-- Values: what a blank holds, turned into a player key, a list, a number, text or yes / no
---------------------------------------------------------------------------

local Eval   -- (run, th, arg) -> value

local function IsList(v) return type(v) == "table" and v.list end
local function List(t) return { list = true, unpack(t) } end

local function ToList(v)
    if type(v) == "table" and v.list then
        local out = {}
        for i = 1, #v do out[i] = v[i] end
        return out
    end
    if type(v) == "string" and v ~= "" then return { v } end
    return {}
end

local function IsPlayer(run, v)
    return type(v) == "string" and v:find("%-") ~= nil
end

function Run:Text(v)
    if v == nil then return "" end
    if type(v) == "boolean" then return v and "yes" or "no" end
    if type(v) == "number" then
        if v == floor(v) then return tostring(v) end
        return strformat("%.1f", v)
    end
    if type(v) == "table" and v.list then
        local names = {}
        for i = 1, #v do names[i] = self:Name(v[i]) end
        return tconcat(names, ", ")
    end
    if type(v) == "string" and self:IsPerson(v) then return self:Name(v) end
    return tostring(v)
end

-- Is v one of the event's people (an entrant, a sign-up or the host)? Text shows their name, not their key.
function Run:IsPerson(v)
    if v == self.st.host then return true end
    if Contains(self.st.entrants, v) or Contains(self.st.signups or {}, v) then return true end
    return IsPlayer(self, v) and v:find("^[^%s%d][^%s]*%-%a") ~= nil
end

-- A number from anything. Never NaN or endless (1e308 + 1e308): they show as "nan" / "inf" and break sorting.
local function Num(v)
    if type(v) == "boolean" then return v and 1 or 0 end
    v = tonumber(v) or 0
    if v ~= v then return 0 end
    return max(-1e9, min(1e9, v))
end

-- Text for chat and screens: no escape codes ("|" starts colours, links and textures) or line breaks, at most
-- `limit` bytes (a chat line takes 255), cut between two letters (a UTF-8 letter is never split).
local function Clean(text, limit)
    text = tostring(text or ""):gsub("%c", " "):gsub("|", "")
    if #text > limit then
        local cut = limit
        while cut > 0 and (text:byte(cut + 1) or 0) >= 0x80 and text:byte(cut + 1) < 0xC0 do cut = cut - 1 end
        text = text:sub(1, cut)
    end
    return text
end
E.Clean = Clean
local CHAT_LEN, MOMENT_LEN, REASON_LEN = 250, 200, 80   -- (a moment / a reason as the result keeps it)

-- The channels "say" may use (the builder's choices): anything else says it in guild.
local function Channel(ch)
    for _, c in ipairs(B().CHANNELS) do
        if c[1] == ch then return ch end
    end
    return "GUILD"
end

local function Same(a, b)
    if a == nil then a = "" end
    if b == nil then b = "" end
    if type(a) == "number" or type(b) == "number" then
        local x, y = tonumber(a), tonumber(b)
        if x and y then return x == y end
    end
    return tostring(a) == tostring(b)
end

---------------------------------------------------------------------------
-- Stats, variables, timers, moments
---------------------------------------------------------------------------

function Run:AddStat(stat, key, n)
    if type(key) ~= "string" or type(stat) ~= "string" then return end
    local s = self.st.stats[stat]
    if not s then s = {}; self.st.stats[stat] = s end
    s[key] = (s[key] or 0) + (tonumber(n) or 0)
end

function Run:GetStat(stat, key)
    local s = self.st.stats[stat]
    return s and s[key] or 0
end

local function CtxCopy(ctx)
    local out = {}
    for k, v in pairs(ctx or {}) do
        if type(v) ~= "table" or v.list then out[k] = Copy(v) end
    end
    return out
end

-- One timer per name, player, block and match: starting it again restarts it (two matches' no-show timers are two).
function Run:StartTimer(name, sec, player, ctx, block)
    if type(name) ~= "string" or name == "" then return end
    local timers = self.st.timers
    local mid = ctx and ctx.match or false
    for i = #timers, 1, -1 do
        local t = timers[i]
        if t.n == name and (t.p or false) == (player or false) and t.b == block and (t.m or false) == mid then
            tremove(timers, i)
        end
    end
    if #timers >= TIMER_LIMIT then tremove(timers, 1) end
    tinsert(timers, { n = name, p = player or false, at = self.now() + max(0, Num(sec)), ctx = CtxCopy(ctx), b = block,
        m = mid })
end

-- A finished match's timers (its no-show) are of no use any more.
function Run:StopMatchTimers(bid, mid)
    local timers = self.st.timers
    for i = #timers, 1, -1 do
        if timers[i].b == bid and timers[i].m == mid then tremove(timers, i) end
    end
end

function Run:StopTimer(name)
    local timers = self.st.timers
    for i = #timers, 1, -1 do
        if timers[i].n == name then tremove(timers, i) end
    end
end

function Run:TimerLeft(name)
    local now = self.now()
    for _, t in ipairs(self.st.timers) do
        if t.n == name then return max(0, t.at - now) end
    end
    return 0
end

function Run:Moment(text, icon)
    local m = self.st.moments
    tinsert(m, { at = self.now(), text = text, i = icon })
    while #m > MOMENT_LIMIT do tremove(m, 1) end
    self:Log("moment", text)
end

---------------------------------------------------------------------------
-- Smart block: Sign-up
---------------------------------------------------------------------------

function Run:SignupState(bid)
    local b = self.st.blocks[bid]
    if not b then
        b = { kind = "signup", list = {}, open = true }
        for _, k in ipairs(self.st.signups or {}) do b.list[#b.list + 1] = k end
        self.st.blocks[bid] = b
    end
    return b
end

function Run:CloseSignup(bid)
    local b = self:SignupState(bid)
    if not b.open then return end
    b.open = false
    local spots = B():SmartSetting(self.def.blocks[bid], "spots") or 40
    while #b.list > spots do tremove(b.list) end
    -- the event's entrants are who signed up (the first Sign-up block that closes decides)
    if not self.st.entrantsSet then
        self.st.entrants = {}
        for i, k in ipairs(b.list) do self.st.entrants[i] = k end
        self.st.entrantsSet = true
    end
    self:Log("block", "Sign-up closes: " .. #b.list .. " players")
    self:Fire("su.close", { }, bid)
end

-- A player joins (live). In every open Sign-up block; nothing when all are closed or full.
function Run:Join(key)
    if self.st.phase ~= "live" or type(key) ~= "string" then return false end
    local joined = false
    for _, bid in ipairs(B():BlocksOf(self.def, "signup")) do
        local b = self:SignupState(bid)
        local spots = B():SmartSetting(self.def.blocks[bid], "spots") or 40
        if b.open and not Contains(b.list, key) and #b.list < spots then
            tinsert(b.list, key)
            joined = true
            self:Fire("su.join", { player = key }, bid)
        end
    end
    if joined and not self.st.entrantsSet and not Contains(self.st.entrants, key) then tinsert(self.st.entrants, key) end
    if joined then self:Pump() end
    return joined
end

function Run:Leave(key)
    if self.st.phase ~= "live" then return false end
    local left = false
    for _, bid in ipairs(B():BlocksOf(self.def, "signup")) do
        local b = self:SignupState(bid)
        local i = b.open and Contains(b.list, key)
        if i then
            tremove(b.list, i)
            left = true
            self:Fire("su.leave", { player = key }, bid)
        end
    end
    if left and not self.st.entrantsSet then
        local i = Contains(self.st.entrants, key)
        if i then tremove(self.st.entrants, i) end
    end
    -- after the sign-up closed (or with none): out of the event, their match now lost, later ones walkovers
    if not left and Contains(self.st.entrants, key) then
        self:BracketOut(key)
        tremove(self.st.entrants, Contains(self.st.entrants, key))
        self:Log("block", self:Name(key) .. " left the event")
        left = true
    end
    if left then self:Pump() end
    return left
end

---------------------------------------------------------------------------
-- Smart block: Bracket
---------------------------------------------------------------------------

-- Slots of a single elimination bracket of `size` (a power of two): seed numbers so that 1 and 2 meet in the final.
local function SeedOrder(size)
    local a = { 1 }
    while #a < size do
        local n, out = #a * 2, {}
        for _, s in ipairs(a) do
            out[#out + 1] = s
            out[#out + 1] = n + 1 - s
        end
        a = out
    end
    return a
end
E.SeedOrder = SeedOrder

function Run:Seeds(bid)
    local b = self.def.blocks[bid]
    local seed = B():SmartSetting(b, "seed")
    local list = {}
    for i, k in ipairs(self.st.entrants) do list[i] = k end
    if seed == "random" then
        Shuffle(self.st, list)
    elseif seed == "season" then
        local order = {}
        for i, k in ipairs(list) do order[k] = i end
        local rankOf = self.rankOf
        tsort(list, function(x, y)
            local rx, ry = rankOf and rankOf(x), rankOf and rankOf(y)
            if rx and ry and rx ~= ry then return rx < ry end
            if rx and not ry then return true end
            if ry and not rx then return false end
            return order[x] < order[y]
        end)
    end
    return list
end

local function NewMatch(bk, r, i, a, b)
    bk.n = (bk.n or 0) + 1
    local m = { id = bk.n, r = r, i = i, a = a or false, b = b or false, wa = 0, wb = 0, g = 0, st = "wait" }
    bk.m[m.id] = m
    bk.rounds[r] = bk.rounds[r] or {}
    tinsert(bk.rounds[r], m.id)
    return m
end

function Run:BracketCreate(bid)
    local blk = self.def.blocks[bid]
    local set = function(k) return B():SmartSetting(blk, k) end
    local seeds = self:Seeds(bid)
    local bk = { kind = "bracket", fmt = set("fmt"), bo = set("bo"), fbo = set("fbo"), noshow = set("noshow"),
        atonce = set("atonce"), bronze = set("bronze") and true or false, seeds = seeds, rounds = {}, m = {}, r = 0,
        out = {}, done = false }
    self.st.blocks[bid] = bk
    local n = #seeds
    if n < 2 then
        -- nothing to play (and nobody won: one player alone is no champion); its "is done" scripts go on with the event
        bk.done = true
        self:Log("block", "Bracket: not enough players")
        self:Fire("bk.done", {}, bid)
        return bk
    end
    if bk.fmt == "robin" then
        local list = {}
        for i, k in ipairs(seeds) do list[i] = k end
        if #list % 2 == 1 then list[#list + 1] = false end
        local count = #list
        for r = 1, count - 1 do
            for i = 1, count / 2 do
                local a, b = list[i], list[count + 1 - i]
                if a and b then
                    NewMatch(bk, r, i, a, b)
                end
            end
            -- the circle method: the first stays, the rest turn
            local last = tremove(list)
            tinsert(list, 2, last)
        end
        bk.last = count - 1
    else
        local size = 2
        while size < n do size = size * 2 end
        local order = SeedOrder(size)
        local rounds = 0
        local s = size
        while s > 1 do rounds = rounds + 1; s = s / 2 end
        bk.last = rounds
        -- round 1 from the seed order (seeds past n are byes)
        for i = 1, size / 2 do
            local a, b = seeds[order[2 * i - 1]], seeds[order[2 * i]]
            local m = NewMatch(bk, 1, i, a, b)
            if not (a and b) then
                m.st = "bye"
                m.win = a or b
            end
        end
        for r = 2, rounds do
            local prev = bk.rounds[r - 1]
            for i = 1, #prev / 2 do
                local m = NewMatch(bk, r, i)
                m.fa, m.fb = prev[2 * i - 1], prev[2 * i]
                if r == rounds then m.final = true end
            end
        end
        if bk.bronze and rounds >= 2 then
            local semis = bk.rounds[rounds - 1]
            local m = NewMatch(bk, rounds, 2)
            m.la, m.lb = semis[1], semis[2]
            m.bronze = true
        end
        if rounds == 1 then bk.m[bk.rounds[1][1]].final = true end
        -- byes move on now
        for _, mid in ipairs(bk.rounds[1]) do
            local m = bk.m[mid]
            if m.st == "bye" then self:BracketPropagate(bid, m) end
        end
    end
    self:Log("block", "Bracket: " .. n .. " players, " .. bk.last .. " rounds")
    return bk
end

function Run:Bracket(bid)
    local bk = self.st.blocks[bid]
    if bk and bk.kind == "bracket" then return bk end
    return nil
end

-- A finished (or bye) match's players go to the matches they feed.
function Run:BracketPropagate(bid, m)
    local bk = self:Bracket(bid)
    -- (not "win == a and b or a": a bye's empty side is false, which would make its winner the loser too)
    local loser
    if m.win == m.a then loser = m.b else loser = m.a end
    for _, x in pairs(bk.m) do
        if x.fa == m.id then x.a = m.win or false end
        if x.fb == m.id then x.b = m.win or false end
        if x.la == m.id then x.a = loser or false end
        if x.lb == m.id then x.b = loser or false end
    end
end

function Run:BracketMatchOf(bid, key, states)
    local bk = self:Bracket(bid)
    if not bk then return nil end
    for _, mid in ipairs(bk.rounds[bk.r] or {}) do
        local m = bk.m[mid]
        if (m.a == key or m.b == key) and (not states or states[m.st]) then return m end
    end
    return nil
end

-- Any bracket's current match of a player that is not over yet: block id, match.
function Run:MatchOf(key)
    for _, bid in ipairs(B():BlocksOf(self.def, "bracket")) do
        local m = self:BracketMatchOf(bid, key, { play = true, wait = true })
        if m then return bid, m end
    end
    return nil
end

local function MatchCtx(m)
    return { player1 = m.a or nil, player2 = m.b or nil, both = List({ m.a or nil, m.b or nil }), match = m.id, round = m.r }
end

function Run:BracketStartRound(bid, r)
    local bk = self:Bracket(bid)
    bk.r = r
    -- a player taken out loses a match that has not started
    for _, mid in ipairs(bk.rounds[r] or {}) do
        local m = bk.m[mid]
        if m.st == "wait" then
            if not (m.a and m.b) then
                m.st = "bye"
                m.win = m.a or m.b or nil
                if m.win then self:BracketPropagate(bid, m) end
            elseif bk.out[m.a] or bk.out[m.b] then
                self:BracketFinish(bid, m, bk.out[m.a] and m.b or m.a, true)
            end
        end
    end
    local final
    for _, mid in ipairs(bk.rounds[r] or {}) do
        if bk.m[mid].final then final = bk.m[mid] end
    end
    if final and final.a and final.b and bk.fmt ~= "robin" then
        bk.fin = { final.a, final.b }
        self:Fire("bk.final", { finalist1 = final.a, finalist2 = final.b }, bid)
    end
    self:BracketSchedule(bid)
    self:BracketCheckRound(bid)
end

-- Starts waiting matches of the current round while fewer than "at once" are being played.
function Run:BracketSchedule(bid)
    local bk = self:Bracket(bid)
    if not bk or bk.done then return end
    local playing = 0
    for _, mid in ipairs(bk.rounds[bk.r] or {}) do
        if bk.m[mid].st == "play" then playing = playing + 1 end
    end
    for _, mid in ipairs(bk.rounds[bk.r] or {}) do
        if playing >= (tonumber(bk.atonce) or 2) then break end
        local m = bk.m[mid]
        if m.st == "wait" and m.a and m.b then
            self:BracketPlay(bid, m)
            playing = playing + 1
        end
    end
end

function Run:BracketPlay(bid, m)
    if m.st ~= "wait" or not (m.a and m.b) then return end   -- (both players known: not a match still being fed)
    m.st = "play"
    m.t = self.now()
    -- ready is per match: Ready on the tracker, or a duel between the two
    self.st.ready[m.a] = nil
    self.st.ready[m.b] = nil
    m.bo = (m.final or m.bronze) and self:Bracket(bid).fbo or self:Bracket(bid).bo
    self:Log("block", strformat("Match %d: %s vs %s", m.id, self:Name(m.a), self:Name(m.b)))
    local ctx = MatchCtx(m)
    self:Fire("bk.istart", ctx, bid, true)
    self:Fire("bk.start", ctx, bid)
end

function Run:BracketNeed(bid, m)
    local bo = m.bo or self:Bracket(bid).bo or 1
    return floor(bo / 2) + 1
end

function Run:BracketGameWin(bid, m, key)
    if m.st ~= "play" then return end
    if key ~= m.a and key ~= m.b then return end
    if key == m.a then m.wa = m.wa + 1 else m.wb = m.wb + 1 end
    m.g = m.g + 1
    local loser = key == m.a and m.b or m.a
    local mine, theirs = (key == m.a) and m.wa or m.wb, (key == m.a) and m.wb or m.wa
    self:Log("block", strformat("Game %d to %s (%d-%d)", m.g, self:Name(key), mine, theirs))
    self:Fire("bk.game", { winner = key, loser = loser, score = mine .. "-" .. theirs, game = m.g, match = m.id }, bid)
    self:Fire("bk.iwin", { player = key, match = m.id, player1 = m.a, player2 = m.b, both = List({ m.a, m.b }) }, bid, true)
end

function Run:BracketFinish(bid, m, key, walkover)
    if m.st == "done" or m.st == "bye" or not (m.a and m.b) then return end
    if key ~= m.a and key ~= m.b then return end
    m.st = "done"
    m.win = key
    m.wo = walkover and true or nil
    m.te = self.now()
    self:StopMatchTimers(bid, m.id)
    -- its open questions (who won) go at once; the scripts asking them stop when they wake
    for id, a in pairs(self.st.asks) do
        if a.match == m.id and a.b == bid then
            a.done = true
            self.st.asks[id] = nil
        end
    end
    local loser = key == m.a and m.b or m.a
    local mine, theirs = (key == m.a) and m.wa or m.wb, (key == m.a) and m.wb or m.wa
    self:BracketPropagate(bid, m)
    local bk = self:Bracket(bid)
    if bk.fmt ~= "robin" and not m.bronze and loser then bk.elim = bk.elim or {}; bk.elim[loser] = m.r end
    self:Log("block", strformat("%s beats %s %d-%d", self:Name(key), self:Name(loser), mine, theirs))
    self:Fire("bk.end", { winner = key, loser = loser, score = mine .. "-" .. theirs, match = m.id, round = m.r }, bid)
    self:BracketSchedule(bid)
    self:BracketCheckRound(bid)
end

function Run:BracketCheckRound(bid)
    local bk = self:Bracket(bid)
    if not bk or bk.done or bk.r == 0 or bk.roundDone == bk.r then return end
    for _, mid in ipairs(bk.rounds[bk.r] or {}) do
        local st = bk.m[mid].st
        if st ~= "done" and st ~= "bye" then return end
    end
    bk.roundDone = bk.r
    self:Fire("bk.iround", { round = bk.r }, bid, true)
end

function Run:BracketNext(bid)
    local bk = self:Bracket(bid)
    if not bk or bk.done or bk.r >= bk.last then return end
    self:BracketStartRound(bid, bk.r + 1)
end

-- Standings of a round robin: match wins, then games won minus lost, then seed.
function Run:RobinTable(bid)
    local bk = self:Bracket(bid)
    local rows = {}
    for i, k in ipairs(bk.seeds) do rows[k] = { k = k, w = 0, d = 0, s = i } end
    for _, m in pairs(bk.m) do
        if m.st == "done" and m.a and m.b then
            local w = m.win
            local l = (w == m.a) and m.b or m.a
            if rows[w] then rows[w].w = rows[w].w + 1 end
            local gw, gl = (w == m.a) and m.wa or m.wb, (w == m.a) and m.wb or m.wa
            if rows[w] then rows[w].d = rows[w].d + gw - gl end
            if rows[l] then rows[l].d = rows[l].d + gl - gw end
        end
    end
    local out = {}
    for _, r in pairs(rows) do out[#out + 1] = r end
    tsort(out, function(x, y)
        if x.w ~= y.w then return x.w > y.w end
        if x.d ~= y.d then return x.d > y.d end
        return x.s < y.s
    end)
    return out
end

function Run:BracketClose(bid)
    local bk = self:Bracket(bid)
    if not bk or bk.done then return end
    bk.done = true
    if bk.fmt == "robin" then
        local t = self:RobinTable(bid)
        bk.champ, bk.second, bk.third = t[1] and t[1].k, t[2] and t[2].k, t[3] and t[3].k
    else
        for _, mid in ipairs(bk.rounds[bk.last] or {}) do
            local m = bk.m[mid]
            if m.final then
                bk.champ = m.win
                if m.win == m.a then bk.second = m.b or nil else bk.second = m.a or nil end
            elseif m.bronze then
                bk.third = m.win
            end
        end
    end
    self:Log("block", "Bracket done: " .. self:Name(bk.champ) .. " wins")
    self:Fire("bk.done", { champion = bk.champ, runnerup = bk.second, third = bk.third }, bid)
end

-- Takes a player out (left, or the host's call): their current match is lost, later ones are walkovers.
function Run:BracketOut(key)
    for _, bid in ipairs(B():BlocksOf(self.def, "bracket")) do
        local bk = self:Bracket(bid)
        if bk and not bk.done then
            bk.out[key] = true
            local m = self:BracketMatchOf(bid, key, { play = true, wait = true })
            if m and m.a and m.b then self:BracketFinish(bid, m, m.a == key and m.b or m.a, true) end
        end
    end
end

-- A duel between two entrants (agree: both their games saw it, or only the loser's said so).
function Run:Duel(winner, loser, agree)
    if self.st.phase ~= "live" or type(winner) ~= "string" or type(loser) ~= "string" then return end
    self:Fire("ev.duel", { winner = winner, loser = loser })
    for _, bid in ipairs(B():BlocksOf(self.def, "bracket")) do
        local bk = self:Bracket(bid)
        if bk and not bk.done then
            local m = self:BracketMatchOf(bid, winner, { play = true, wait = true })
            if m and (m.a == loser or m.b == loser) then
                if m.st == "wait" then self:BracketPlay(bid, m) end
                self:Fire("bk.iduel", { winner = winner, loser = loser, both = List({ m.a, m.b }), match = m.id,
                    player1 = m.a, player2 = m.b, agree = agree and true or false }, bid, true)
            end
        end
    end
    -- both are here (set after a match this duel started: its start clears ready)
    self.st.ready[winner] = true
    self.st.ready[loser] = true
    self:Pump()
end

function Run:SetReady(key)
    if self.st.phase ~= "live" or self.st.ready[key] then return end
    self.st.ready[key] = true
    self:Fire("ev.ready", { player = key })
    self:Pump()
end

function Run:SetOnline(key, online)
    if self.st.phase ~= "live" or not Contains(self.st.entrants, key) then return end
    local was = not self.st.off[key]
    if was == (online and true or false) then return end
    self.st.off[key] = (not online) or nil
    self:Fire(online and "ev.on" or "ev.off", { player = key })
    self:Pump()
end

-- A player's answer to an ask (who won): answer = a player key.
function Run:Answer(askId, key, answer)
    local a = self.st.asks[askId]
    if not a or a.done then return end
    if not Contains(a.to, key) then return end
    if answer ~= nil and not Contains(a.opts, answer) then return end
    a.ans[key] = answer or false
    self:Log("ask", self:Name(key) .. " says " .. self:Name(answer))
    self:Changed()
    self:Resume()
end

---------------------------------------------------------------------------
-- Stages
---------------------------------------------------------------------------

function Run:BlockActive(bid)
    local b = self.def.blocks[bid]
    if not b then return false end
    local _, si = B():Stage(self.def, b.stage)
    local _, ci = B():Stage(self.def, self.st.stage)
    return si and ci and ci >= si or false
end

function Run:EnterStage(id)
    local s, index = B():Stage(self.def, id)
    if not s or self.st.phase ~= "live" then return end
    self.st.stage = id
    self.st.everyAt = {}
    self:Log("stage", "Stage " .. index .. ": " .. s.name)
    -- this stage's smart blocks start now (and those of stages that were skipped)
    for _, bid in ipairs(B():BlocksOf(self.def)) do
        local b = self.def.blocks[bid]
        local _, bi = B():Stage(self.def, b.stage)
        if bi and bi <= index and not self.st.blocks[bid] then
            if b.kind == "signup" then
                self:SignupState(bid)
            elseif b.kind == "bracket" then
                -- the entrants are known now: the sign-ups if nothing closed them
                if not self.st.entrantsSet then
                    for _, sb in ipairs(B():BlocksOf(self.def, "signup")) do self:CloseSignup(sb) end
                    self.st.entrantsSet = true
                end
                self:BracketCreate(bid)
                if not self.st.blocks[bid].done then self:BracketStartRound(bid, 1) end
            end
        end
    end
    self:Fire("ev.start", {})
    -- a Sign-up that closes when the event starts closes once its stage's "when this stage starts" ran
    if index == 1 then
        for _, sb in ipairs(B():BlocksOf(self.def, "signup")) do
            local closes = B():SmartSetting(self.def.blocks[sb], "closes")
            if closes == "start" or closes == "early" then
                self:Queue(function() self:CloseSignup(sb) end)
            end
        end
    end
    self:Changed()
end

function Run:Start()
    if self.st.phase ~= "ready" then return end
    self.st.phase = "live"
    self.st.t0 = self.now()
    local first = self.def.stages and self.def.stages[1]
    if not first then return end
    self:Queue(function() self:EnterStage(first.id) end)
    self:Pump()
end

function Run:GoStage(id)
    self:Queue(function() self:EnterStage(id) end)
end

function Run:NextStage()
    local _, i = B():Stage(self.def, self.st.stage)
    local s = i and self.def.stages[i + 1]
    if s then self:GoStage(s.id) else self:End() end
end

-- What the event decided (stored with the result): placings of the first bracket, points, badges.
function Run:Result()
    local res = { champ = nil, second = nil, third = nil, points = {}, badges = Copy(self.st.awards), stats = Copy(self.st.stats) }
    for _, bid in ipairs(B():BlocksOf(self.def, "bracket")) do
        local bk = self:Bracket(bid)
        if bk then
            res.champ, res.second, res.third = bk.champ, bk.second, bk.third
            break
        end
    end
    for k, n in pairs(self.st.stats[B().SEASON] or {}) do
        if n ~= 0 then res.points[k] = n end
    end
    return res
end

function Run:End()
    if self.st.phase ~= "live" then return end
    self.st.phase = "done"
    self.st.t1 = self.now()
    self.st.timers = {}
    self.threads = {}
    self.queue = {}
    self:Log("stage", "The event is over")
    self:Changed()
    Out(self, "ended", self)
end

function Run:Cancel(reason)
    if self.st.phase ~= "live" and self.st.phase ~= "ready" then return end
    self.st.phase = "cancelled"
    self.st.reason = reason
    self.st.t1 = self.now()
    self.st.timers = {}
    self.threads = {}
    self.queue = {}
    self:Log("stage", "Cancelled: " .. tostring(reason or ""))
    self:Changed()
    Out(self, "ended", self)
end

---------------------------------------------------------------------------
-- Triggers and threads
---------------------------------------------------------------------------

function Run:Queue(fn)
    if #self.queue >= QUEUE_LIMIT then return end
    tinsert(self.queue, fn)
end

-- Fires the scripts whose hat is `key` (queued): ctx = the values it gives. bid: the smart block it comes from (its
-- user scripts must name that block; its own scripts run only for it). inner: only that block's own scripts.
function Run:Fire(key, ctx, bid, inner)
    self:Queue(function()
        local list = self.byHat[key]
        if not list then return end
        local hatArg = B().PIECES[key] and B().PIECES[key].args[1]
        for _, s in ipairs(list) do
            local ok
            if key == "ev.timer" then
                -- a timer reaches the scripts of the block that started it, and every user script of the stage
                ok = s.top.a and s.top.a[1] == (ctx and ctx._timer)
                if ok and s.block then ok = s.block == (ctx and ctx._block) end
                if ok and not s.block then ok = s.st == "*" or s.st == self.st.stage end
            elseif s.block then
                ok = inner and s.block == bid
            else
                ok = not inner and (s.st == "*" or s.st == self.st.stage)
                if ok and hatArg and hatArg.t == "block" then ok = s.top.a and s.top.a[1] == bid end
            end
            if ok then self:Spawn(s, ctx, bid) end
        end
    end)
end

function Run:Spawn(s, ctx, bid)
    if self.st.phase ~= "live" then return end
    local alive = 0
    for _ in pairs(self.threads) do alive = alive + 1 end
    if alive >= THREAD_LIMIT then
        self:Log("error", "Too many scripts at once: one was skipped")
        return
    end
    local th = { s = s, ctx = CtxCopy(ctx), block = s.block or bid, steps = 0 }
    th.ctx._timer, th.ctx._block = nil, nil
    -- the values a script last ran with (the builder's practice run shows them in its pieces)
    self.lastCtx = self.lastCtx or {}
    self.lastCtx[(s.block and (s.block .. "/") or "") .. s.id] = th.ctx
    th.co = cocreate(function() self:Exec(th, s.top.n) end)
    self.threads[th] = true
    self:Log("script", (B().PIECES[s.top.k].text:gsub("{%d}", "...")), { script = s.id, block = s.block })
    if self.out.ran then self.out.ran(s.id, s.block) end
    self:Step(th)
end

function Run:Step(th)
    if not self.threads[th] then return end
    local ok, why = coresume(th.co)
    if not ok then
        self.threads[th] = nil
        self:Log("error", "A script stopped: " .. tostring(why))
        if ns.Debug then ns:Debug("Event script error: %s", tostring(why)) end
        return
    end
    if costatus(th.co) == "dead" then
        self.threads[th] = nil
    end
    self.dirty = true
end

-- Handles the queue: every event in order, each script until it waits or ends.
function Run:Pump()
    if self.pumping then return end
    self.pumping = true
    local n = 0
    while #self.queue > 0 and n < QUEUE_LIMIT do
        n = n + 1
        local fn = tremove(self.queue, 1)
        local ok, err = pcall(fn)
        if not ok then self:Log("error", tostring(err)) end
    end
    if n >= QUEUE_LIMIT then
        self.queue = {}
        self:Log("error", "Too many events at once: the rest were dropped")
    end
    self.pumping = false
    if n > 0 or self.dirty then
        self.dirty = false
        self:Changed()
    end
end

-- Wakes scripts whose wait is over (and those waiting for answers). While the host pauses, time stands still: only
-- answers wake a script.
function Run:Resume()
    local now = self.now()
    local paused = self.st.paused
    local list = {}
    for th in pairs(self.threads) do
        local w = th.wait
        if w then
            local due = (w.at and not paused and now >= w.at) or (w.cond and w.cond())
            if due then list[#list + 1] = th end
        end
    end
    for _, th in ipairs(list) do
        th.wait = nil
        self:Step(th)
    end
    self:Pump()
end

-- Every second or so: timers that ran out, "every" pieces, waits.
function Run:Tick()
    if self.st.phase ~= "live" then return end
    local now = self.now()
    local timers = self.st.timers
    local due = {}
    for i = #timers, 1, -1 do
        if timers[i].at <= now then
            tinsert(due, 1, tremove(timers, i))
        end
    end
    for _, t in ipairs(due) do
        local ctx = CtxCopy(t.ctx)
        if t.p then ctx.player = t.p end
        ctx._timer, ctx._block = t.n, t.b
        self:Fire("ev.timer", ctx, t.b)
    end
    for _, s in ipairs(self.byHat["ev.every"] or {}) do
        if s.st == "*" or s.st == self.st.stage then
            local sec = max(10, Num(s.top.a and s.top.a[1]))
            local last = self.st.everyAt[s.id] or self.st.t0 or now
            if now - last >= sec then
                self.st.everyAt[s.id] = now
                self:Spawn(s, {}, nil)
            elseif not self.st.everyAt[s.id] then
                self.st.everyAt[s.id] = last
            end
        end
    end
    self:Resume()
end

local function Wait(th, w)
    th.wait = w
    coyield()
    th.steps = 0   -- STEP_LIMIT counts the pieces run since the last wait
end

---------------------------------------------------------------------------
-- The interpreter
---------------------------------------------------------------------------

local function arg(p, i) return p.a and p.a[i] end

local function Bump(run, th)
    th.steps = th.steps + 1
    if th.steps > STEP_LIMIT then error("this script ran too long without waiting (an endless loop?)", 0) end
end

local function Players(run, th, v)
    local list = ToList(Eval(run, th, v))
    local out = {}
    for _, k in ipairs(list) do
        if type(k) == "string" and k ~= "" then out[#out + 1] = k end
    end
    return out
end

local function PlayerOf(run, th, v)
    local x = Eval(run, th, v)
    if type(x) == "table" and x.list then x = x[1] end
    if type(x) == "string" and x ~= "" then return x end
    return nil
end

local function BlockOf(run, th, v)
    if type(v) == "string" and run.def.blocks[v] then return v end
    return th.block
end

local function MatchOfThread(run, th)
    local bid = th.block
    local bk = bid and run:Bracket(bid)
    local mid = th.ctx.match
    if bk and mid then return bid, bk.m[mid] end
    return nil
end

-- Text with values in it (or a plain blank).
local function TextOf(run, th, v)
    if type(v) == "table" and v.j then
        local parts = {}
        for _, x in ipairs(v.j) do
            if type(x) == "table" then parts[#parts + 1] = run:Text(Eval(run, th, x)) else parts[#parts + 1] = tostring(x) end
        end
        return tconcat(parts)
    end
    return run:Text(Eval(run, th, v))
end

local VALUE = {}
local DO = {}

Eval = function(run, th, v)
    if type(v) ~= "table" then return v end
    if v.j then return TextOf(run, th, v) end
    if not v.k then return nil end
    Bump(run, th)
    local f = VALUE[v.k]
    if not f then return nil end
    return f(run, th, v)
end

local function Bool(run, th, v) return Eval(run, th, v) and true or false end

VALUE["ctx"] = function(run, th, p)
    local name = arg(p, 1)
    if name == "opponent" and th.ctx.opponent == nil then
        -- the other player of the match, from player 1's side (a whisper to both sets it per player)
        return th.ctx.player2
    end
    return th.ctx[name]
end
VALUE["var"] = function(run, th, p) return run.st.vars[arg(p, 1)] end
VALUE["pl.host"] = function(run) return run.st.host end
VALUE["pl.all"] = function(run) return List(run.st.entrants) end
VALUE["pl.rand"] = function(run)
    local e = run.st.entrants
    if #e == 0 then return nil end
    return e[Rand(run.st, 1, #e)]
end
VALUE["pl.count"] = function(run) return #run.st.entrants end
VALUE["pl.seed"] = function(run, th, p)
    local n = floor(Num(Eval(run, th, arg(p, 1))))
    for _, bid in ipairs(B():BlocksOf(run.def, "bracket")) do
        local bk = run:Bracket(bid)
        if bk then return bk.seeds[n] end
    end
    return run.st.entrants[n]
end
VALUE["pl.online"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    if not k then return false end
    if run.st.off[k] then return false end
    if run.out.isOnline then return run.out.isOnline(k) and true or false end
    return true
end
VALUE["pl.ready"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    return k and run.st.ready[k] and true or false
end
VALUE["pl.notready"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    return not (k and run.st.ready[k])
end
VALUE["pl.is"] = function(run, th, p)
    local a, b = PlayerOf(run, th, arg(p, 1)), PlayerOf(run, th, arg(p, 2))
    return a ~= nil and a == b
end
VALUE["pl.in"] = function(run, th, p)
    local a = PlayerOf(run, th, arg(p, 1))
    return a ~= nil and Contains(Players(run, th, arg(p, 2)), a) ~= nil
end
local function SeedOf(run, key)
    for _, bid in ipairs(B():BlocksOf(run.def, "bracket")) do
        local bk = run:Bracket(bid)
        if bk then return Contains(bk.seeds, key) end
    end
    return Contains(run.st.entrants, key)
end
VALUE["pl.below"] = function(run, th, p)
    local a, b = PlayerOf(run, th, arg(p, 1)), PlayerOf(run, th, arg(p, 3))
    local n = Num(Eval(run, th, arg(p, 2)))
    local sa, sb = a and SeedOf(run, a), b and SeedOf(run, b)
    return (sa and sb and sa - sb >= n) and true or false
end
VALUE["pl.top"] = function(run, th, p)
    local n = floor(Num(Eval(run, th, arg(p, 1))))
    local stat = Eval(run, th, arg(p, 2))
    local list = {}
    for i, k in ipairs(run.st.entrants) do list[i] = k end
    local order = {}
    for i, k in ipairs(list) do order[k] = i end
    tsort(list, function(x, y)
        local a, b = run:GetStat(stat, x), run:GetStat(stat, y)
        if a ~= b then return a > b end
        return order[x] < order[y]
    end)
    local out = {}
    for i = 1, min(n, #list) do out[i] = list[i] end
    return List(out)
end
VALUE["pt.get"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    return k and run:GetStat(Eval(run, th, arg(p, 2)), k) or 0
end
VALUE["lo.and"] = function(run, th, p) return Bool(run, th, arg(p, 1)) and Bool(run, th, arg(p, 2)) end
VALUE["lo.or"] = function(run, th, p) return Bool(run, th, arg(p, 1)) or Bool(run, th, arg(p, 2)) end
VALUE["lo.not"] = function(run, th, p) return not Bool(run, th, arg(p, 1)) end
VALUE["lo.gt"] = function(run, th, p) return Num(Eval(run, th, arg(p, 1))) > Num(Eval(run, th, arg(p, 2))) end
VALUE["lo.lt"] = function(run, th, p) return Num(Eval(run, th, arg(p, 1))) < Num(Eval(run, th, arg(p, 2))) end
VALUE["lo.eq"] = function(run, th, p) return Same(Eval(run, th, arg(p, 1)), Eval(run, th, arg(p, 2))) end
VALUE["lo.set"] = function(run, th, p)
    local v = Eval(run, th, arg(p, 1))
    if type(v) == "table" and v.list then return #v > 0 end
    return v ~= nil and v ~= "" and v ~= false
end
VALUE["lo.add"] = function(run, th, p) return Num(Eval(run, th, arg(p, 1))) + Num(Eval(run, th, arg(p, 2))) end
VALUE["lo.sub"] = function(run, th, p) return Num(Eval(run, th, arg(p, 1))) - Num(Eval(run, th, arg(p, 2))) end
VALUE["lo.rand"] = function(run, th, p)
    local a, b = floor(Num(Eval(run, th, arg(p, 1)))), floor(Num(Eval(run, th, arg(p, 2))))
    if b < a then a, b = b, a end
    return Rand(run.st, a, b)
end
VALUE["tm.left"] = function(run, th, p) return run:TimerLeft(Eval(run, th, arg(p, 1))) end
VALUE["wo.zone"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    local want = strlower(TextOf(run, th, arg(p, 2)) or "")
    local zone = k and run.out.zoneOf and run.out.zoneOf(k)
    if not zone or want == "" then return false end
    return strfind(strlower(zone), want, 1, true) ~= nil
end
VALUE["su.list"] = function(run, th, p)
    local bid = BlockOf(run, th, arg(p, 1))
    local b = bid and run.st.blocks[bid]
    if b and b.kind == "signup" then return List(b.list) end
    return List(run.st.signups or {})
end
VALUE["su.count"] = function(run, th, p)
    local bid = BlockOf(run, th, arg(p, 1))
    local b = bid and run.st.blocks[bid]
    if b and b.kind == "signup" then return #b.list end
    return #(run.st.signups or {})
end
local function BkField(field)
    return function(run, th, p)
        local bid = BlockOf(run, th, arg(p, 1))
        local bk = bid and run:Bracket(bid)
        return bk and bk[field] or nil
    end
end
VALUE["bk.champ"] = BkField("champ")
VALUE["bk.second"] = BkField("second")
VALUE["bk.third"] = BkField("third")
VALUE["bk.fin1"] = function(run, th, p)
    local bid = BlockOf(run, th, arg(p, 1))
    local bk = bid and run:Bracket(bid)
    return bk and bk.fin and bk.fin[1] or nil
end
VALUE["bk.fin2"] = function(run, th, p)
    local bid = BlockOf(run, th, arg(p, 1))
    local bk = bid and run:Bracket(bid)
    return bk and bk.fin and bk.fin[2] or nil
end
VALUE["bk.round"] = function(run, th, p)
    local bid = BlockOf(run, th, arg(p, 1))
    local bk = bid and run:Bracket(bid)
    return bk and bk.r or 0
end
VALUE["bk.left"] = function(run, th, p)
    local bid = BlockOf(run, th, arg(p, 1))
    local bk = bid and run:Bracket(bid)
    local out = {}
    if bk then
        for _, k in ipairs(bk.seeds) do
            if not bk.out[k] and not (bk.elim and bk.elim[k]) then out[#out + 1] = k end
        end
    end
    return List(out)
end
VALUE["bk.still"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    local bid = BlockOf(run, th, arg(p, 2))
    local bk = bid and run:Bracket(bid)
    if not (k and bk) then return false end
    return Contains(bk.seeds, k) ~= nil and not bk.out[k] and not (bk.elim and bk.elim[k])
end
VALUE["bk.agree"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    return th.ctx.agree and k ~= nil and th.ctx.winner == k or false
end
VALUE["bk.asked"] = function(run, th) return th.asked and true or false end
VALUE["bk.wins"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    local _, m = MatchOfThread(run, th)
    if not (k and m) then return false end
    local w = (k == m.a) and m.wa or ((k == m.b) and m.wb or 0)
    return w >= Num(Eval(run, th, arg(p, 2)))
end
VALUE["bk.need"] = function(run, th)
    local bid, m = MatchOfThread(run, th)
    if not m then return 2 end
    return run:BracketNeed(bid, m)
end
VALUE["bk.noshow"] = function(run, th)
    local bk = th.block and run:Bracket(th.block)
    return bk and tonumber(bk.noshow) or 300
end
VALUE["bk.last"] = function(run, th)
    local bk = th.block and run:Bracket(th.block)
    return bk and bk.r >= bk.last or false
end

-- Statements --------------------------------------------------------------

DO["sg.go"] = function(run, th, p) run:GoStage(arg(p, 1)); return "stop" end
DO["sg.next"] = function(run) run:Queue(function() run:NextStage() end); return "stop" end
DO["sg.end"] = function(run) run:Queue(function() run:End() end); return "stop" end
DO["sg.cancel"] = function(run, th, p)
    local why = Clean(TextOf(run, th, arg(p, 1)), REASON_LEN)
    run:Queue(function() run:Cancel(why) end)
    return "stop"
end
DO["lo.stop"] = function() return "stop" end

DO["lo.if"] = function(run, th, p)
    if Bool(run, th, arg(p, 1)) then return run:Exec(th, p.c1, true) end
end
DO["lo.ifelse"] = function(run, th, p)
    if Bool(run, th, arg(p, 1)) then return run:Exec(th, p.c1, true) end
    return run:Exec(th, p.c2, true)
end
DO["lo.rep"] = function(run, th, p)
    local n = min(100, floor(Num(Eval(run, th, arg(p, 1)))))
    for _ = 1, n do
        local r = run:Exec(th, p.c1, true)
        if r == "stop" then return r end
    end
end
DO["lo.each"] = function(run, th, p)
    local list = Players(run, th, arg(p, 1))
    local saved = th.ctx.each
    for _, k in ipairs(list) do
        th.ctx.each = k
        local r = run:Exec(th, p.c1, true)
        if r == "stop" then th.ctx.each = saved; return r end
    end
    th.ctx.each = saved
end

-- One grant of season points is at most SEASON_CAP either way (the review checks typed numbers; this holds the
-- worked-out ones too).
local function Grant(stat, n)
    if stat ~= B().SEASON then return n end
    local cap = B().SEASON_CAP
    return max(-cap, min(cap, n))
end

DO["pt.add"] = function(run, th, p)
    local n = Num(Eval(run, th, arg(p, 1)))
    local stat = Eval(run, th, arg(p, 2))
    n = Grant(stat, n)
    for _, k in ipairs(Players(run, th, arg(p, 3))) do
        run:AddStat(stat, k, n)
        run:Log("points", strformat("%s %s%s %s", run:Name(k), n >= 0 and "+" or "", run:Text(n), tostring(stat)))
    end
end
DO["pt.set"] = function(run, th, p)
    local stat = Eval(run, th, arg(p, 1))
    local k = PlayerOf(run, th, arg(p, 2))
    if not (k and type(stat) == "string") then return end
    local s = run.st.stats[stat]
    if not s then s = {}; run.st.stats[stat] = s end
    s[k] = Grant(stat, Num(Eval(run, th, arg(p, 3))))
end
DO["pt.vset"] = function(run, th, p)
    local name = arg(p, 1)
    if type(name) ~= "string" then return end
    local v = Eval(run, th, arg(p, 2))
    if type(v) == "table" and v.list then v = v[1] end
    run.st.vars[name] = v
    run:Log("var", name .. " = " .. run:Text(v))
end
DO["pt.badge"] = function(run, th, p)
    local bid = arg(p, 1)
    if not (run.def.badges and run.def.badges[bid]) then return end
    for _, k in ipairs(Players(run, th, arg(p, 2))) do
        local dup = false
        for _, a in ipairs(run.st.awards) do
            if a.p == k and a.b == bid then dup = true end
        end
        if not dup then
            tinsert(run.st.awards, { p = k, b = bid })
            run:Log("badge", run:Name(k) .. " gets " .. tostring(run.def.badges[bid].n))
        end
    end
end

-- What a text blank says, ready for chat ("" when there is nothing to say).
local function Said(run, th, v, limit)
    local text = Clean(TextOf(run, th, v), limit)
    if not text:find("%S") then return "" end
    return text
end

DO["ch.say"] = function(run, th, p)
    local text = Said(run, th, arg(p, 1), CHAT_LEN)
    if text == "" then return end
    local ch = Channel(arg(p, 2))
    run:Log("say", text, { channel = ch })
    Out(run, "say", ch, text)
end
DO["ch.wh"] = function(run, th, p)
    local to = Players(run, th, arg(p, 1))
    local saved = th.ctx.opponent
    for _, k in ipairs(to) do
        -- "opponent" in a whisper to a match's players is each one's own opponent
        if th.ctx.player1 and th.ctx.player2 then
            th.ctx.opponent = (k == th.ctx.player1) and th.ctx.player2 or th.ctx.player1
        end
        local text = Said(run, th, arg(p, 2), CHAT_LEN)
        if text ~= "" then
            run:Log("whisper", run:Name(k) .. ": " .. text, { to = k })
            Out(run, "whisper", k, text)
        end
    end
    th.ctx.opponent = saved
end
DO["ch.rw"] = function(run, th, p)
    local text = Said(run, th, arg(p, 1), CHAT_LEN)
    if text == "" then return end
    run.st.annSeq = (run.st.annSeq or 0) + 1
    run.st.ann = { s = run.st.annSeq, text = text, at = run.now() }
    run:Log("warning", text)
    Out(run, "announce", text)
end
DO["ch.moment"] = function(run, th, p)
    local text = Said(run, th, arg(p, 1), MOMENT_LEN)
    if text ~= "" then run:Moment(text) end
end

DO["tm.wait"] = function(run, th, p)
    local sec = max(0, min(3600, Num(Eval(run, th, arg(p, 1)))))
    Wait(th, { at = run.now() + sec })
end
DO["tm.start"] = function(run, th, p)
    run:StartTimer(Eval(run, th, arg(p, 2)), Eval(run, th, arg(p, 1)), nil, th.ctx, th.block)
end
DO["tm.startp"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 3))
    if k then run:StartTimer(Eval(run, th, arg(p, 2)), Eval(run, th, arg(p, 1)), k, th.ctx, th.block) end
end
DO["tm.stop"] = function(run, th, p) run:StopTimer(Eval(run, th, arg(p, 1))) end
DO["tm.count"] = function(run, th, p)
    local n = max(1, min(60, floor(Num(Eval(run, th, arg(p, 1))))))
    local to = Players(run, th, arg(p, 2))
    run.st.cdSeq = (run.st.cdSeq or 0) + 1
    run.st.cd = { s = run.st.cdSeq, n = n, at = run.now(), to = to }
    run:Log("countdown", "Count down " .. n)
end

DO["wo.inv"] = function(run, th, p)
    local to = Players(run, th, arg(p, 1))
    run:Log("invite", run:Text(List(to)))
    Out(run, "invite", to)
end
DO["wo.mark"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    local n = tonumber(arg(p, 2)) or 8
    if k then
        run:Log("mark", run:Name(k))
        Out(run, "mark", k, n)
    end
end

DO["su.closeit"] = function(run, th, p)
    local bid = BlockOf(run, th, arg(p, 1))
    if bid and run.def.blocks[bid] and run.def.blocks[bid].kind == "signup" then
        run:Queue(function() run:CloseSignup(bid) end)
    end
end
DO["bk.award"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    if not k then return end
    -- the script's own match when it has one (a no-show timer of a match that is over awards nothing)
    local bid, m = MatchOfThread(run, th)
    if m then
        if m.st == "done" or m.st == "bye" or (m.a ~= k and m.b ~= k) then return end
    else
        bid, m = run:MatchOf(k)
    end
    if m and m.a and m.b then
        if m.st == "wait" then run:BracketPlay(bid, m) end
        run:BracketFinish(bid, m, k, true)
    end
end
DO["bk.out"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    if k then run:BracketOut(k) end
end
DO["bk.gwin"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    local bid, m = MatchOfThread(run, th)
    if k and m then run:BracketGameWin(bid, m, k) end
end
DO["bk.finish"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    local bid, m = MatchOfThread(run, th)
    if k and m then run:BracketFinish(bid, m, k) end
end
DO["bk.next"] = function(run, th)
    local bid = th.block
    if bid then run:Queue(function() run:BracketNext(bid) end) end
end
DO["bk.close"] = function(run, th)
    local bid = th.block
    if bid then run:Queue(function() run:BracketClose(bid) end) end
    return "stop"
end
DO["bk.ask"] = function(run, th, p)
    local to = Players(run, th, arg(p, 1))
    local bid, m = MatchOfThread(run, th)
    if #to == 0 or not m then return end
    if m.st ~= "play" then return "stop" end   -- decided meanwhile (the host's call, a walkover): nothing to ask
    run.st.askSeq = run.st.askSeq + 1
    local id = run.st.askSeq
    local a = { id = id, to = to, opts = { m.a, m.b }, ans = {}, at = run.now(), match = m.id, b = bid, g = m.g + 1,
        q = "Who won game " .. (m.g + 1) .. "?", claims = th.lastClaims }
    run.st.asks[id] = a
    run:Log("ask", "Asks " .. run:Text(List(to)) .. ": " .. a.q)
    run:Changed()
    Out(run, "ask", a)
    Wait(th, { at = run.now() + ASK_SECONDS, cond = function()
        if m.st ~= "play" then return true end
        for _, k in ipairs(a.to) do
            if a.ans[k] == nil then return false end
        end
        return true
    end })
    a.done = true
    run.st.asks[id] = nil
    -- the match ended while it waited: the question is gone (not passed on to the host)
    if m.st ~= "play" then
        run:Changed()
        return "stop"
    end
    th.lastClaims = Copy(a.ans)   -- (an ask to the host after this one shows what the players said)
    -- the answers: all the same (and someone answered) = agreed
    local first, agree = nil, true
    for _, k in ipairs(a.to) do
        local v = a.ans[k]
        if v then
            if first == nil then first = v elseif first ~= v then agree = false end
        end
    end
    th.asked = agree and first ~= nil
    th.ctx.answer = first
    run:Changed()
end

-- Runs a stack from piece p. inner: a C piece's insides (a "stop" there ends the whole script).
function Run:Exec(th, p, inner)
    while p do
        Bump(self, th)
        local f = DO[p.k]
        if f then
            local r = f(self, th, p)
            if r == "stop" then return "stop" end
        end
        p = p.n
    end
    return nil
end

---------------------------------------------------------------------------
-- What the board and the tracker show
---------------------------------------------------------------------------

-- The first bracket's state (or nil).
function Run:MainBracket()
    for _, bid in ipairs(B():BlocksOf(self.def, "bracket")) do
        local bk = self:Bracket(bid)
        if bk then return bk, bid end
    end
    return nil
end

-- Reads a snapshot without a run: the first bracket block's state in it.
function E:BracketOf(def, st)
    for _, bid in ipairs(ns.EventBlocks:BlocksOf(def, "bracket")) do
        local bk = st and st.blocks and st.blocks[bid]
        if bk and bk.kind == "bracket" then return bk, bid end
    end
    return nil
end

-- A player's match in a snapshot: match, bracket (the current round's, not done), or nil.
function E:MatchFor(def, st, key)
    local bk = self:BracketOf(def, st)
    if not bk then return nil end
    for _, mid in ipairs(bk.rounds[bk.r] or {}) do
        local m = bk.m[mid]
        if (m.a == key or m.b == key) and (m.st == "play" or m.st == "wait") then return m, bk end
    end
    return nil, bk
end

function E:OnInit() end

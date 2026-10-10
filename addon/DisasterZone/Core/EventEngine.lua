if DisasterZoneBoot and DisasterZoneBoot.Run("Core/EventEngine.lua", ...) then return end -- DisasterZone: runs an event's pieces.
-- The interpreter of an event (Core/EventBlocks.lua's pieces) and its smart blocks. A run belongs to its host's client
-- (or to the builder's practice run): stages, scripts, timers, the Sign-up and Matches blocks, variables, tags, scores,
-- lists walked per player, asks, buttons, the arrow's places, badges, moments. It knows nothing of the network:
-- everything it does to the world goes through an output adapter (opts.out: show, tell, sound, guild, plates, invite,
-- mark, ...), facts come in through the run inputs (Duel / Join / SetReady / SetOnline / Answer, and Happen / Place /
-- Touch / Radar / Pos / AskAnswer / Press), and its state is one plain table (run:Snapshot) that the live layer
-- (Core/EventLive.lua) sends to everyone and a new host restores (E:Restore) when the old one is gone.
--
-- Scripts run as coroutines: "wait", "ask" and "ask ... who won" pause their own script only. Every trigger is queued
-- and handled in order (a script that fires an event, e.g. "go to stage", finishes first). A script that runs more
-- than STEP_LIMIT pieces without waiting is stopped (an endless loop), as are scripts past THREAD_LIMIT at once.
local addonName, ns = ...

local E = ns:NewModule("EventEngine")

local type, pairs, ipairs, tostring, tonumber, next, select = type, pairs, ipairs, tostring, tonumber, next, select
local tinsert, tremove, tconcat, tsort = table.insert, table.remove, table.concat, table.sort
local floor, ceil, max, min, sqrt, abs = math.floor, math.ceil, math.max, math.min, math.sqrt, math.abs
local strformat, strlower, strupper, strfind = string.format, string.lower, string.upper, string.find
local cocreate, coresume, costatus, coyield = coroutine.create, coroutine.resume, coroutine.status, coroutine.yield

local STEP_LIMIT = 2000      -- pieces one script may run before it waits
local THREAD_LIMIT = 60      -- scripts running (waiting) at once
local TIMER_LIMIT = 64
local MOMENT_LIMIT = 30
local ASK_SECONDS = 60       -- "ask ... who won" waits this long for the answers
local QUEUE_LIMIT = 500      -- events handled in one go (a chain of "go to stage" ping-pong stops here)
local GUILD_LIMIT = 20       -- posts in guild chat an event (EventLive spaces them 10 s apart)
local BUTTON_LIMIT = 12      -- buttons an event hands out at once
local WARM_SAME = 5          -- yards: closer or further by less is "the same"
local UNKNOWN_YARDS = 9999   -- "yards from" when a position isn't known

local function B() return ns.EventBlocks end
local Copy = function(v) return ns.EventBlocks.Copy(v) end

local function Contains(list, v)
    for i = 1, #list do if list[i] == v then return i end end
    return nil
end

local Run = {}
Run.__index = Run
E.Run = Run

---------------------------------------------------------------------------
-- Random numbers: the run's own (its state travels with the snapshot, so a new host goes on the same way)
---------------------------------------------------------------------------

-- Park-Miller (16807 mod 2^31 - 1): the products stay under 2^46, so every client's doubles get the exact same
-- numbers (the old 1103515245 multiplier went past 2^53 and lost its low bits: every seed fell into one short
-- cycle). Any state number works, one from an older client's snapshot too.
local RAND_MOD = 2147483647

local function Rand(st, lo, hi)
    local s = floor(tonumber(st.rng) or 1) % RAND_MOD
    if not (s >= 1) then s = 1 end                -- (0, or not a number at all)
    s = (s * 16807) % RAND_MOD
    st.rng = s
    local r = (s - 1) / (RAND_MOD - 1)            -- [0, 1)
    if not lo then return r end
    return lo + floor(r * (hi - lo + 1))
end
E.Rand = Rand

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

-- The parts of a state (a broken one from another client gets the ones it lacks). Host only: never in a snapshot
-- that goes out (positions, who is inside which place, hot / cold, mounted / moving / ...).
local STATE_TABLES = { "entrants", "signups", "ready", "off", "vars", "stats", "timers", "blocks", "moments", "awards",
    "asks", "everyAt", "tags", "scores", "lists", "qa", "buttons", "point", "shown", "plates", "tstart", "lead",
    "pos", "inplace", "warm", "flags", "lt", "last" }
local HOST_ONLY = { "pos", "inplace", "warm", "flags" }

-- opts: { id, host, out, practice, signups = { key ... } (sign-up order), entrants (no Sign-up block), now = fn,
--         rankOf = fn(key) -> season rank | nil, nameOf = fn(key) -> display name,
--         worldPos = fn(map, x, y) -> continent, wx, wy (yards; default: the client's C_Map) }
function E:New(def, opts)
    opts = opts or {}
    local id = opts.id or "run"
    local st = {
        v = 2, id = id, host = opts.host, phase = "ready", seq = 0, rng = SeedFrom(id),
        stage = nil, t0 = nil, t1 = nil,
        entrants = {}, signups = Copy(opts.signups or {}), ready = {}, off = {},
        vars = {}, stats = {}, timers = {}, blocks = {}, moments = {}, awards = {}, asks = {},
        ann = nil, cd = nil, everyAt = {}, askSeq = 0, practice = opts.practice and true or nil,
    }
    for _, k in ipairs(opts.entrants or opts.signups or {}) do st.entrants[#st.entrants + 1] = k end
    return self:Restore(def, st, opts)
end

-- A run from a snapshot (a new host, or a /reload of the host): everything goes on (timers, matches, stats, the
-- stage, open asks), and so do the scripts that were waiting (st.waits: Run:Revive), each where it was; part 1's
-- questions who won are dropped (the host decides the match).
function E:Restore(def, st, opts)
    opts = opts or {}
    -- a state from another client: every part it must have (a broken one would stop the run each second)
    for _, k in ipairs(STATE_TABLES) do
        if type(st[k]) ~= "table" then st[k] = {} end
    end
    if type(st.seq) ~= "number" then st.seq = 0 end
    if type(st.askSeq) ~= "number" then st.askSeq = 0 end
    if type(st.qaSeq) ~= "number" then st.qaSeq = 0 end
    if type(st.gp) ~= "number" then st.gp = 0 end
    if type(st.rng) ~= "number" then st.rng = SeedFrom(tostring(st.id or "run")) end
    for i = #st.timers, 1, -1 do
        local t = st.timers[i]
        if type(t) ~= "table" or type(t.n) ~= "string" or type(t.at) ~= "number" then tremove(st.timers, i) end
    end
    -- the parts of part 2 inside: what isn't of its shape goes (a tag that isn't a set, an answer list that isn't one)
    for _, k in ipairs({ "tags", "scores", "lists", "buttons", "inplace" }) do
        for id, set in pairs(st[k]) do
            if type(set) ~= "table" then st[k][id] = nil end
        end
    end
    for _, t in pairs(st.scores) do
        for key, n in pairs(t) do if type(n) ~= "number" or n ~= n then t[key] = nil end end
    end
    for _, t in pairs(st.lists) do
        for key, i in pairs(t) do if type(i) ~= "number" then t[key] = nil end end
    end
    for key, pid in pairs(st.point) do if type(pid) ~= "string" then st.point[key] = nil end end
    for timer in pairs(st.shown) do if type(timer) ~= "string" then st.shown[timer] = nil end end
    for key, p in pairs(st.pos) do if type(p) ~= "table" then st.pos[key] = nil end end
    for lid, t in pairs(st.lt) do
        if type(t) ~= "table" then st.lt[lid] = nil else
            for key, times in pairs(t) do if type(times) ~= "table" then t[key] = nil end end
        end
    end
    for key, l in pairs(st.last) do if type(l) ~= "table" then st.last[key] = nil end end
    for key, f in pairs(st.flags) do if type(f) ~= "table" then st.flags[key] = nil end end
    -- part 1's questions who won are dropped (the scripts asking them don't come back; the host decides the match)
    for id in pairs(st.asks) do st.asks[id] = nil end
    -- an open ask stays open until it would have closed (its script, waiting for it, comes back: Revive). A state
    -- that went out showed a secret one's answers as only "answered": they stay answered, but nobody knows what
    -- (lost: not counted, not anyone's answer)
    for aid, a in pairs(st.qa) do
        if type(a) ~= "table" then
            st.qa[aid] = nil
        else
            if type(a.who) ~= "table" then a.who = {} end
            if type(a.ans) ~= "table" then a.ans = {} end
            if type(a.order) ~= "table" then a.order = {} end
            if type(a.lost) ~= "table" then a.lost = nil end
            if a.hid then
                a.lost = a.lost or {}
                for k in pairs(a.ans) do a.lost[k] = true end
                a.hid = nil
            end
            if a.open and not (tonumber(a.ends) and type(a.id) == "number") then a.open = false end
        end
    end
    local waits = st.waits
    st.waits = nil
    local run = setmetatable({}, Run)
    run.def = Copy(def)
    B():Migrate(run.def)
    run.st = st
    run.out = opts.out or {}
    run.now = opts.now or function() return (GetServerTime and GetServerTime()) or time() end
    run.rankOf = opts.rankOf
    run.nameOf = opts.nameOf
    run.worldPos = opts.worldPos
    run.threads = {}
    run.queue = {}
    run.log = {}
    run:IndexScripts()
    if st.phase == "live" then run:Revive(waits) end
    return run
end

-- The state as it goes out (full: also what only the host keeps, for its own /reload). A secret ask's answers stay
-- hidden while it's open: only that someone answered shows.
function Run:Snapshot(full)
    local st = Copy(self.st)
    if not full then
        for _, k in ipairs(HOST_ONLY) do st[k] = nil end
        for aid, a in pairs(st.qa or {}) do
            local ad = self.def.asks and self.def.asks[aid]
            if a.open and ad and ad.secret then
                for k in pairs(a.ans or {}) do a.ans[k] = true end
                a.hid = true   -- (a taker of this state knows who answered, not what: Restore)
            end
        end
    end
    -- the scripts that wait (a wait, an ask): where each one is, so a restored run goes on from there
    st.waits = self:Waits()
    return st
end

-- The host paused for `sec`: timers, waits, "every" pieces and asks end that much later, "seconds since" don't count
-- it. (EventLive's SetPaused calls it.)
function Run:Shift(sec)
    sec = tonumber(sec) or 0
    if sec <= 0 then return end
    local st = self.st
    for _, t in ipairs(st.timers) do t.at = t.at + sec end
    for th in pairs(self.threads) do
        if th.wait and th.wait.at then th.wait.at = th.wait.at + sec end
    end
    for id, at in pairs(st.everyAt) do st.everyAt[id] = at + sec end
    for _, a in pairs(st.qa) do if a.open and a.ends then a.ends = a.ends + sec end end
    for n, at in pairs(st.tstart) do st.tstart[n] = at + sec end
    if st.stageAt then st.stageAt = st.stageAt + sec end
end

-- Scripts by their hat's key: user scripts, then each smart block's own (its copy, or the built-in ones).
function Run:IndexScripts()
    local by, scripts = {}, {}
    local function add(s, block)
        local top = s.top
        if type(top) ~= "table" or not top.k then return end
        local pd = B().PIECES[top.k]
        if not pd or pd.shape ~= "hat" then return end
        by[top.k] = by[top.k] or {}
        local e = { id = s.id, st = s.st or "*", top = top, block = block }
        tinsert(by[top.k], e)
        scripts[(block or "") .. "/" .. tostring(s.id)] = e
    end
    self.scripts = scripts
    for _, s in ipairs(self.def.scripts or {}) do add(s, nil) end
    for _, bid in ipairs(B():BlocksOf(self.def)) do
        local b = self.def.blocks[bid]
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

-- A question of a list (an item value): { ql = list id, qi = its number, q = the question, pts }.
local function IsQuestion(v) return type(v) == "table" and v.ql ~= nil end

function Run:Text(v)
    if v == nil then return "" end
    if type(v) == "boolean" then return v and "yes" or "no" end
    if type(v) == "number" then
        if v == floor(v) then return tostring(v) end
        return strformat("%.1f", v)
    end
    if type(v) == "table" and v.list then
        local names = {}
        for i = 1, #v do names[i] = self:Text(v[i]) end
        return tconcat(names, ", ")
    end
    if IsQuestion(v) then return tostring(v.q or "") end
    if type(v) == "table" then return "" end
    if type(v) == "string" and self:IsPerson(v) then return self:Name(v) end
    -- a place's id reads as its name
    local pl = type(v) == "string" and self.def.places and self.def.places[v]
    if type(pl) == "table" and pl.n then return tostring(pl.n) end
    return tostring(v)
end

-- Is v one of the event's people (an entrant, a sign-up or the host)? Text shows their name, not their key.
function Run:IsPerson(v)
    if v == self.st.host then return true end
    if Contains(self.st.entrants, v) or Contains(self.st.signups or {}, v) then return true end
    return IsPlayer(self, v) and v:find("^[^%s%d][^%s]*%-%a") ~= nil
end

-- A number from anything. Never NaN or endless (1e308 + 1e308): they show as "nan" / "inf" and break sorting.
-- (A question reads as its points.)
local function Num(v)
    if type(v) == "boolean" then return v and 1 or 0 end
    if IsQuestion(v) then v = v.pts or 1 end
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
local SHOW_LEN, ANSWER_LEN, NAME_LEN = 200, 120, 60      -- a banner or tracker line, a typed answer, a creature / item

local function Trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- A button's label as the run keeps it (nil: nothing to show).
local function Label(v)
    if type(v) ~= "string" and type(v) ~= "number" then return nil end
    local s = Trim(Clean(v, B().LIMITS.label))
    return s ~= "" and s or nil
end

local function Same(a, b)
    if a == nil then a = "" end
    if b == nil then b = "" end
    if IsQuestion(a) and IsQuestion(b) then return a.ql == b.ql and a.qi == b.qi end
    if type(a) == "number" or type(b) == "number" then
        local x, y = tonumber(a), tonumber(b)
        if x and y then return x == y end
    end
    if type(a) == "table" or type(b) == "table" then return false end
    return tostring(a) == tostring(b)
end

-- Text for "matches": capitals and spaces don't count.
local function Plain(s) return (strlower(tostring(s or "")):gsub("%s+", "")) end

---------------------------------------------------------------------------
-- Scores (Season points are part 1's capped stat), variables, timers, moments
---------------------------------------------------------------------------

-- A score's id from a part 1 stat name ("Wins": the event's score of that name), else as it is.
function Run:ScoreId(s)
    if type(s) ~= "string" or s == B().SEASON then return s end
    local sc = self.def.scores
    if type(sc) == "table" and sc[s] then return s end
    for id, x in pairs(type(sc) == "table" and sc or {}) do
        if type(x) == "table" and x.n == s then return id end
    end
    return s
end

function Run:ScoreName(sid) return B():DefinitionName(self.def, "scores", sid) end

-- A player's score (nil: never set).
function Run:GetScore(sid, key)
    sid = self:ScoreId(sid)
    if type(sid) ~= "string" then return nil end
    local t = sid == B().SEASON and self.st.stats[sid] or self.st.scores[sid] or self.st.stats[sid]
    return t and t[key]
end

-- (part 1's API: a stat's value, 0 when unset)
function Run:GetStat(stat, key) return self:GetScore(stat, key) or 0 end
function Run:AddStat(stat, key, n) self:SetScore(stat, key, n, true) end

-- One grant of season points is at most SEASON_CAP either way (the review checks typed numbers; this holds the
-- worked-out ones too). A score with a cap stays within it.
local function Grant(run, sid, n)
    if sid == B().SEASON then
        local cap = B().SEASON_CAP
        return max(-cap, min(cap, n))
    end
    return n
end

-- Sets (add: adds to) a player's score; the "reaches" and "the lead changes" hats hear it.
function Run:SetScore(sid, key, n, add)
    sid = self:ScoreId(sid)
    if type(sid) ~= "string" or type(key) ~= "string" or key == "" then return end
    -- (only who is in the event: one who left has no scores, gets no prizes)
    if not self:InEvent(key) then return end
    local SEASON = B().SEASON
    if sid ~= SEASON and not B():Definition(self.def, "scores", sid) then return end
    n = Grant(self, sid, Num(n))
    local store = sid == SEASON and self.st.stats or self.st.scores
    local t = store[sid]
    if not t then t = {}; store[sid] = t end
    local old = t[key]
    local v = add and ((old or 0) + n) or n
    local sc = sid ~= SEASON and self.def.scores[sid]
    local cap = sc and tonumber(sc.cap)
    if cap and cap > 0 then v = max(-cap, min(cap, v)) end
    v = Num(v)
    t[key] = v
    if add then
        self:Log("points", strformat("%s %s%s %s", self:Name(key), n >= 0 and "+" or "", self:Text(n), self:ScoreName(sid)))
    else
        self:Log("points", strformat("%s %s = %s", self:Name(key), self:ScoreName(sid), self:Text(v)))
    end
    if old ~= v then self:ScoreChanged(sid, key, old, v) end
end

-- The players who have a score, best first ({ key, n }): higher wins unless the score says lower; ties in entrant order.
function Run:Ranked(sid)
    sid = self:ScoreId(sid)
    local SEASON = B().SEASON
    local t = type(sid) == "string" and (sid == SEASON and self.st.stats[sid] or self.st.scores[sid] or self.st.stats[sid])
    local sc = B():Definition(self.def, "scores", sid)
    local low = sc and sc.high == false
    local order = {}
    for i, k in ipairs(self.st.entrants) do order[k] = i end
    local list = {}
    for k, n in pairs(t or {}) do list[#list + 1] = { key = k, n = n } end
    tsort(list, function(a, b)
        if a.n ~= b.n then
            if low then return a.n < b.n end
            return a.n > b.n
        end
        local oa, ob = order[a.key] or 1e6, order[b.key] or 1e6
        if oa ~= ob then return oa < ob end
        return a.key < b.key
    end)
    return list, low
end

-- A player's place by a score (1, 2, 2, 4 ...), 0 without one.
function Run:PlaceBy(sid, key)
    local list, low = self:Ranked(sid)
    local mine
    for _, r in ipairs(list) do if r.key == key then mine = r.n end end
    if mine == nil then return 0 end
    local better = 0
    for _, r in ipairs(list) do
        if (low and r.n < mine) or (not low and r.n > mine) then better = better + 1 end
    end
    return better + 1
end

local HatThread   -- (run, s) -> a thread to work out a hat's blanks with

function Run:ScoreChanged(sid, key, old, new)
    -- "when someone's X reaches n": crossing it (from below)
    if self.byHat["pt.reach"] then
        local was = old or 0
        self:Fire("pt.reach", { player = key }, nil, nil, function(s)
            if s.top.a[1] ~= sid then return false end
            local n = Num(Eval(self, HatThread(self, s), s.top.a[2]))
            return was < n and new >= n
        end)
    end
    -- "when the lead in X changes": a new leader (a tie keeps the one who got there first)
    if self.byHat["pt.lead"] then
        local list = self:Ranked(sid)
        local best = list[1]
        local cur = self.st.lead[sid]
        if best and best.key ~= cur then
            local curN = cur and self:GetScore(sid, cur)
            if curN == nil or curN ~= best.n then
                self.st.lead[sid] = best.key
                self:Fire("pt.lead", { player = best.key }, nil, nil, function(s) return s.top.a[1] == sid end)
            end
        end
    end
end

local function CtxCopy(ctx)
    local out = {}
    for k, v in pairs(ctx or {}) do
        if type(v) ~= "table" or v.list or IsQuestion(v) then out[k] = Copy(v) end
    end
    return out
end

local WAIT_SAVE = 24   -- waiting scripts a state keeps (the oldest first)

-- The waiting scripts as a state keeps them: { { s = script id, b = its block, tb = the thread's block, ctx, path } }.
-- (Part 1's question who won isn't kept: a restored run drops it, the host decides the match.)
function Run:Waits()
    local list = {}
    for th in pairs(self.threads) do
        local path = th.path
        local leaf = th.wait and path and path[#path]
        if leaf and leaf.k ~= "bk.ask" and th.s and th.s.id ~= nil then list[#list + 1] = th end
    end
    tsort(list, function(a, b) return (a.n or 0) < (b.n or 0) end)
    local out = {}
    for i = 1, min(#list, WAIT_SAVE) do
        local th = list[i]
        out[i] = { s = th.s.id, b = th.s.block, tb = th.block, ctx = CtxCopy(th.ctx), path = Copy(th.path) }
    end
    return out
end

-- A restored run's waiting scripts go on where they were (each waits again for what it waited for: a wait to its
-- end, an open ask to its closing; one that ended meanwhile goes on at the next tick). A script the def doesn't have
-- any more, or one that changed, doesn't come back.
function Run:Revive(waits)
    if type(waits) ~= "table" then return end
    for i = 1, min(#waits, WAIT_SAVE) do
        local w = waits[i]
        local s = type(w) == "table" and self.scripts[(type(w.b) == "string" and w.b or "") .. "/" .. tostring(w.s)]
        if s and type(w.path) == "table" and #w.path > 0 then
            self.spawnSeq = (self.spawnSeq or 0) + 1
            local block = type(w.tb) == "string" and self.def.blocks[w.tb] and w.tb or s.block
            local th = { s = s, ctx = type(w.ctx) == "table" and CtxCopy(w.ctx) or {}, block = block, steps = 0, path = {},
                n = self.spawnSeq }
            local path = w.path
            th.co = cocreate(function() self:Exec(th, s.top.n, nil, path) end)
            self.threads[th] = true
            -- (it runs to its wait: nothing before it runs again)
            self:Step(th)
        elseif type(w) == "table" then
            self:Log("error", "A script that was waiting couldn't go on")
        end
    end
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
    if not player then self.st.tstart[name] = self.now() end
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
-- Tags
---------------------------------------------------------------------------

-- May this key be tagged, told, asked ...: an entrant or the host.
function Run:InEvent(key)
    return type(key) == "string" and key ~= "" and (Contains(self.st.entrants, key) ~= nil or key == self.st.host)
end

function Run:HasTag(tid, key)
    if tid == B().ENTRANTS then return Contains(self.st.entrants, key) ~= nil end
    local t = self.st.tags[tid]
    return t and t[key] and true or false
end

-- The players with a tag, in entrant order.
function Run:Tagged(tid)
    if tid == B().ENTRANTS then
        local out = {}
        for i, k in ipairs(self.st.entrants) do out[i] = k end
        return out
    end
    local t = self.st.tags[tid] or {}
    local order = {}
    for i, k in ipairs(self.st.entrants) do order[k] = i end
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    tsort(out, function(a, b)
        local oa, ob = order[a] or 1e6, order[b] or 1e6
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    return out
end

local function TagOK(run, tid)
    return type(tid) == "string" and tid ~= B().ENTRANTS and run.def.tags and run.def.tags[tid] ~= nil
end

function Run:Tag(tid, keys)
    if not TagOK(self, tid) then return end
    local t = self.st.tags[tid]
    if not t then t = {}; self.st.tags[tid] = t end
    for _, k in ipairs(keys) do
        if self:InEvent(k) and not t[k] then
            t[k] = true
            self:Log("tag", self:Name(k) .. " is " .. B():DefinitionName(self.def, "tags", tid))
            self:Fire("pl.gettag", { player = k }, nil, nil, function(s) return s.top.a[1] == tid end)
        end
    end
end

-- "when no one has tag X": the last one lost it.
function Run:NoTagCheck(tid, before)
    if before > 0 and next(self.st.tags[tid] or {}) == nil then
        self:Fire("pl.notag", {}, nil, nil, function(s) return s.top.a[1] == tid end)
    end
end

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

function Run:Untag(tid, keys)
    if not TagOK(self, tid) then return end
    local t = self.st.tags[tid]
    if not t then return end
    local before = Count(t)
    for _, k in ipairs(keys) do
        if t[k] then
            t[k] = nil
            self:Log("tag", self:Name(k) .. " isn't " .. B():DefinitionName(self.def, "tags", tid) .. " any more")
        end
    end
    self:NoTagCheck(tid, before)
end

-- Into two tags, evenly and at random (the first gets the odd one).
function Run:Split(keys, a, b)
    if not (TagOK(self, a) and TagOK(self, b)) or a == b then return end
    local list = {}
    for _, k in ipairs(keys) do if self:InEvent(k) and not Contains(list, k) then list[#list + 1] = k end end
    Shuffle(self.st, list)
    local half = ceil(#list / 2)
    local first, second = {}, {}
    for i, k in ipairs(list) do
        if i <= half then first[#first + 1] = k else second[#second + 1] = k end
    end
    -- (only who changes side loses the other tag: "gets tag" and "no one has" hear the real changes)
    local tags = self.st.tags
    local beforeA, beforeB = Count(tags[a]), Count(tags[b])
    for _, k in ipairs(first) do if tags[b] then tags[b][k] = nil end end
    for _, k in ipairs(second) do if tags[a] then tags[a][k] = nil end end
    self:Tag(a, first)
    self:Tag(b, second)
    self:NoTagCheck(a, beforeA)
    self:NoTagCheck(b, beforeB)
end

-- A player who left the event: no tags, scores, buttons, arrow or place any more (and their asks don't wait for
-- them). (Season points they won stay: part 1's rule.)
function Run:DropPlayer(key)
    for tid in pairs(self.st.tags) do
        if self.st.tags[tid][key] then self:Untag(tid, { key }) end
    end
    for sid, t in pairs(self.st.scores) do
        if t[key] ~= nil then
            t[key] = nil
            -- (the lead goes to whoever is best now: "the lead changes")
            if self.st.lead[sid] == key then
                local best = self:Ranked(sid)[1]
                self.st.lead[sid] = best and best.key or nil
                if best then
                    self:Fire("pt.lead", { player = best.key }, nil, nil, function(s) return s.top.a[1] == sid end)
                end
            end
        end
    end
    for _, holders in pairs(self.st.buttons) do holders[key] = nil end
    self.st.point[key] = nil
    for _, set in pairs(self.st.inplace) do set[key] = nil end
    self.st.pos[key] = nil
    for aid, a in pairs(self.st.qa) do
        if a.open and a.who[key] and a.ans[key] == nil then
            a.who[key] = nil
            if self:AllAnswered(a) then self:CloseAsk(aid) end
        end
    end
end

---------------------------------------------------------------------------
-- Lists (a list walked per player: a route, a riddle chain)
---------------------------------------------------------------------------

function Run:ListItems(lid)
    local l = type(lid) == "string" and self.def.lists and self.def.lists[lid]
    return type(l) == "table" and type(l.items) == "table" and l.items or {}, l
end

-- Item i of a list as a value: a text, a place's id, or a question.
function Run:ItemValue(lid, i)
    local items, l = self:ListItems(lid)
    local it = items[i]
    if it == nil then return nil end
    if l.kind == "question" or type(it) == "table" then
        if type(it) ~= "table" then return nil end
        return { ql = lid, qi = i, q = Clean(it.q, B().LIMITS.question), pts = tonumber(it.pts) or 1 }
    end
    return it
end

function Run:ListPos(lid, key)
    local t = self.st.lists[lid]
    return t and t[key] or 1
end

function Run:ListNext(lid, key)
    local items = self:ListItems(lid)
    if #items == 0 or not self:InEvent(key) then return end
    local t = self.st.lists[lid]
    if not t then t = {}; self.st.lists[lid] = t end
    local i = t[key] or 1
    if i > #items then return end   -- at the end already
    i = i + 1
    t[key] = i
    -- (when: seconds since the run began, for the board's splits and gaps; one a list item)
    local lt = self.st.lt[lid]
    if not lt then lt = {}; self.st.lt[lid] = lt end
    local mine = lt[key] or {}
    lt[key] = mine
    mine[i - 1] = floor(self.now() - (self.st.t0 or self.now()) + 0.5)
    self:Log("list", strformat("%s: %d of %d", self:Name(key), min(i - 1, #items), #items))
    if i > #items then
        self:Fire("lo.lend", { player = key }, nil, nil, function(s) return s.top.a[1] == lid end)
    end
end

---------------------------------------------------------------------------
-- Asks (the addon asks: a card for the players asked, closes by itself) and buttons
---------------------------------------------------------------------------

-- Everyone asked has answered (who is offline isn't waited for: they may still answer while it's open).
function Run:AllAnswered(a)
    for k in pairs(a.who) do
        if a.ans[k] == nil and not self.st.off[k] then return false end
    end
    return true
end

-- Opens an ask (an open one of the same ask closes first): the ask's state, or nil when nobody was asked.
function Run:OpenAsk(aid, keys, q, item)
    local ad = type(aid) == "string" and self.def.asks and self.def.asks[aid]
    if type(ad) ~= "table" then return nil end
    local who, n = {}, 0
    for _, k in ipairs(keys) do
        if self:InEvent(k) and not who[k] then who[k] = true; n = n + 1 end
    end
    if n == 0 then return nil end
    if self.st.qa[aid] and self.st.qa[aid].open then self:CloseAsk(aid) end
    local now = self.now()
    local time = max(5, min(600, tonumber(ad.time) or ASK_SECONDS))
    self.st.qaSeq = self.st.qaSeq + 1
    local a = { open = true, who = who, n = n, q = q, at = now, ends = now + time, ans = {}, order = {},
        id = self.st.qaSeq, kind = ad.kind or "player", item = item }
    self.st.qa[aid] = a
    self:Log("ask", "Asks " .. self:Text(List(keys)) .. ": " .. tostring(q))
    Out(self, "asked", aid, a)
    self:Changed()
    return a
end

function Run:CloseAsk(aid)
    local a = self.st.qa[aid]
    if not (a and a.open) then return end
    a.open = false
    a.closed = self.now()
    self:Log("ask", B():DefinitionName(self.def, "asks", aid) .. " closes: " .. Count(a.ans) .. " answered")
    self:Fire("as.closed", {}, nil, nil, function(s) return s.top.a[1] == aid end)
    self:Changed()
end

-- An answer as the ask takes it (nil: not a valid one). player: a player key (several: a list); choice: one of its
-- choices (several: a list); text: typed text; yesno: true / false; number: 1 to 10.
function Run:CheckAnswer(ad, key, v)
    local kind = ad.kind or "player"
    local votes = max(1, min(3, floor(tonumber(ad.votes) or 1)))
    local function many(fn)
        local list = type(v) == "table" and ToList(v) or { v }
        if type(v) == "table" and not v.list then
            list = {}
            for i = 1, #v do list[i] = v[i] end
        end
        local out, seen = {}, {}
        for _, x in ipairs(list) do
            x = fn(x)
            if x == nil then return nil end
            if not seen[x] then seen[x] = true; out[#out + 1] = x end
        end
        if #out == 0 or #out > votes then return nil end
        if votes == 1 then return out[1] end
        return List(out)
    end
    if kind == "player" then
        local from = ad.from
        return many(function(x)
            if type(x) ~= "string" then return nil end
            if x == key and not ad.self then return nil end
            if from and from ~= "entrants" and from ~= B().ENTRANTS then
                if not self:HasTag(from, x) then return nil end
            elseif not Contains(self.st.entrants, x) then
                return nil
            end
            return x
        end)
    elseif kind == "choice" then
        return many(function(x)
            for _, c in ipairs(type(ad.choices) == "table" and ad.choices or {}) do
                if Same(c, x) or (type(x) == "string" and Plain(c) == Plain(x)) then return c end
            end
            return nil
        end)
    elseif kind == "text" then
        if type(v) ~= "string" and type(v) ~= "number" then return nil end
        local s = Trim(Clean(v, ANSWER_LEN))
        return s ~= "" and s or nil
    elseif kind == "yesno" then
        if v == true or v == "yes" or v == 1 then return true end
        if v == false or v == "no" or v == 0 then return false end
        return nil
    elseif kind == "number" then
        local n = tonumber(v)
        if not n or n ~= floor(n) or n < 1 or n > 10 then return nil end
        return n
    end
    return nil
end

-- A player's answer to an ask (live; the host's own too). One answer each: the first stands.
function Run:AskAnswer(aid, key, value)
    if self.st.phase ~= "live" then return false end
    local a = self.st.qa[aid]
    local ad = self.def.asks and self.def.asks[aid]
    if not (a and a.open and ad and a.who[key]) or a.ans[key] ~= nil then return false end
    value = self:CheckAnswer(ad, key, value)
    if value == nil then return false end
    a.ans[key] = value
    a.order[#a.order + 1] = key
    self:Log("ask", self:Name(key) .. " answers " .. (ad.secret and "(secret)" or self:Text(value)))
    self:Fire("as.on", { player = key, answer = value }, nil, nil, function(s) return s.top.a[1] == aid end)
    -- ("when someone answers" and "when ... closes" run before the script that asked goes on)
    self:Pump()
    if self:AllAnswered(a) then
        self:CloseAsk(aid)
        self:Pump()
    end
    self:Changed()
    self:Resume()
    return true
end

-- The answers of an ask (open or the last one), counted: { { v, n } } most first (a tie: the one picked first).
function Run:Tally(aid)
    local a = self.st.qa[aid]
    local out, at = {}, {}
    if not a then return out end
    local function count(v)
        local key = IsQuestion(v) and (v.ql .. "#" .. v.qi) or (type(v) .. ":" .. tostring(v))
        local r = at[key]
        if not r then r = { v = v, n = 0, i = #out + 1 }; at[key] = r; out[#out + 1] = r end
        r.n = r.n + 1
    end
    local lost = type(a.lost) == "table" and a.lost or {}
    for _, k in ipairs(a.order or {}) do
        local v = a.ans[k]
        if lost[k] then
            -- (answered before a takeover: not known)
        elseif IsList(v) then
            for i = 1, #v do count(v[i]) end
        elseif v ~= nil then
            count(v)
        end
    end
    tsort(out, function(x, y)
        if x.n ~= y.n then return x.n > y.n end
        return x.i < y.i
    end)
    return out
end

function Run:GiveButton(label, keys)
    label = Label(label)
    if not label then return end
    local holders = self.st.buttons[label]
    if not holders then
        if Count(self.st.buttons) >= BUTTON_LIMIT then return end
        holders = {}
        self.st.buttons[label] = holders
    end
    for _, k in ipairs(keys) do
        if self:InEvent(k) then holders[k] = true end
    end
    self:Log("button", label .. ": " .. self:Text(List(keys)))
end

function Run:TakeButton(label, keys)
    label = Label(label)
    local holders = label and self.st.buttons[label]
    if not holders then return end
    for _, k in ipairs(keys) do holders[k] = nil end
    if next(holders) == nil then self.st.buttons[label] = nil end
end

-- A player pressed a button they have.
function Run:Press(key, label)
    if self.st.phase ~= "live" then return false end
    label = Label(label)
    local holders = label and self.st.buttons[label]
    if not (holders and holders[key]) then return false end
    self:Log("button", self:Name(key) .. " presses " .. label)
    self:Fire("as.press", { player = key }, nil, nil, function(s) return Label(s.top.a[1]) == label end)
    self:Pump()
    return true
end

---------------------------------------------------------------------------
-- Things that happen, places, touches (facts from the entrants' clients)
---------------------------------------------------------------------------

local function FilterOK(filterType, want, ctx, data)
    if want == nil or want == "" then return true end
    if filterType == "creature" then
        return Plain(want) == Plain(ctx.creature)
    elseif filterType == "item" then
        if type(want) == "number" or tostring(want):find("^%d+$") then
            return tonumber(want) == tonumber(data.item)
        end
        return Plain(want) == Plain(data.name or ctx.item)
    elseif filterType == "emote" then
        return strupper(tostring(want)) == strupper(tostring(ctx.emote or ""))
    end
    return true
end

local FLAG_OF = { mount = { "mounted", true }, dismount = { "mounted", false }, move = { "moving", true },
    stop = { "moving", false }, die = { "dead", true } }

-- Something an entrant did: what = a B.HAPPEN key; data: other, item (id), name (item name), count, creature, emote.
-- "wins / loses a duel" go through Duel, "goes offline / comes back" through SetOnline, "is ready" through SetReady.
function Run:Happen(key, what, data)
    if self.st.phase ~= "live" or not Contains(self.st.entrants, key) then return false end
    local h = B().HAPPEN_BY[what]
    if not h then return false end
    data = type(data) == "table" and data or {}
    local other = type(data.other) == "string" and data.other ~= "" and data.other or nil
    if what == "duel" or what == "lose" then
        if not (other and Contains(self.st.entrants, other)) then return false end
        if what == "duel" then self:Duel(key, other, true) else self:Duel(other, key, true) end
        return true
    elseif what == "off" or what == "on" then
        self:SetOnline(key, what == "on")
        return true
    elseif what == "ready" then
        self:SetReady(key)
        return true
    end
    local f = FLAG_OF[what]
    if f then
        local fl = self.st.flags[key] or {}
        self.st.flags[key] = fl
        fl[f[1]] = f[2]
    end
    local ctx = { player = key }
    if what == "kill" then ctx.creature = Clean(data.creature or data.name or "", NAME_LEN) end
    if what == "loot" or what == "fish" then
        ctx.item = data.name and Clean(data.name, NAME_LEN) or tonumber(data.item)
        ctx.count = max(1, floor(Num(data.count ~= nil and data.count or 1)))
    end
    if what == "emote" then
        ctx.emote = strupper(Clean(data.emote or "", 24))
        ctx.other = other
    end
    -- the board's "last catch": what an entrant last caught, looted or killed (at: seconds since the run began)
    if what == "fish" or what == "loot" or what == "kill" then
        self.st.last[key] = { w = what, i = tonumber(data.item), n = what == "kill" and ctx.creature
            or (data.name and Clean(data.name, NAME_LEN)) or nil, at = floor(self.now() - (self.st.t0 or self.now()) + 0.5) }
    end
    self:Fire("ev.happen", ctx, nil, nil, function(s)
        return s.top.a[1] == what and FilterOK(h.filter, s.top.a[2], ctx, data)
    end)
    self:Pump()
    return true
end

-- An entrant entered (inside) or left one of the event's places.
function Run:Place(key, pid, inside)
    if self.st.phase ~= "live" or not Contains(self.st.entrants, key) then return false end
    if type(pid) ~= "string" or not (self.def.places and self.def.places[pid]) then return false end
    inside = inside and true or false
    local set = self.st.inplace[pid]
    if not set then set = {}; self.st.inplace[pid] = set end
    if (set[key] or false) == inside then return false end
    set[key] = inside or nil
    if inside and self.st.point[key] == pid then self.st.point[key] = nil end
    self:Fire(inside and "pc.enter" or "pc.leave", { player = key, place = pid }, nil, nil, function(s)
        local want = s.top.a[1]
        return want == nil or want == "" or want == pid
    end)
    self:Pump()
    return true
end

-- A hat's blanks are worked out when it fires: a thread of its own to do it with.
HatThread = function(run, s)
    return { s = s, ctx = {}, steps = 0, block = s.block }
end

-- The player keys a blank holds (a player, a list of them).
local function Players(run, th, v)
    local list = ToList(Eval(run, th, v))
    local out = {}
    for _, k in ipairs(list) do
        if type(k) == "string" and k ~= "" then out[#out + 1] = k end
    end
    return out
end

-- "one of {players}": an empty blank is anyone in the event (the host too: "find the host").
local function OneOf(run, s, slot, key)
    local v = s.top.a[slot]
    if v == nil or v == "" then return run:InEvent(key) end
    return Contains(Players(run, HatThread(run, s), v), key) ~= nil
end

-- who touched whom up close (how: click, point, emote; emote: the emote's token). EventLive passes touches up close
-- only (a click within about 10 yards, a /point or an emote at them). whom: an entrant or the host ("find the host").
function Run:Touch(who, whom, how, emote)
    if self.st.phase ~= "live" or who == whom then return false end
    if not (Contains(self.st.entrants, who) and self:InEvent(whom)) then return false end
    if not B().TOUCH_BY[how] then return false end
    emote = emote and strupper(tostring(emote)) or nil
    self:Fire("pl.touch", { toucher = who, touched = whom }, nil, nil, function(s)
        local a = s.top.a
        if (a[3] or "click") ~= how then return false end
        if how == "emote" and a[4] ~= nil and a[4] ~= "" and strupper(tostring(a[4])) ~= emote then return false end
        return OneOf(self, s, 1, who) and OneOf(self, s, 2, whom)
    end)
    self:Pump()
    return true
end

-- who targeted whom without clicking (a macro, tab): the radar.
function Run:Radar(who, whom)
    if self.st.phase ~= "live" or who == whom then return false end
    if not (Contains(self.st.entrants, who) and self:InEvent(whom)) then return false end
    self:Fire("pl.radar", { who = who, whom = whom }, nil, nil, function(s)
        return OneOf(self, s, 1, who) and OneOf(self, s, 2, whom)
    end)
    self:Pump()
    return true
end

-- Where an entrant is (host only, never sent on): map, x, y (0..1), wx, wy, cont (world yards, when the sensor has
-- them), z, sz (zone, subzone), items = { [item] = count }, gold (copper gained since the event began), and flags
-- fl (flying), sw (swimming), cb (in combat), mt (mounted), mv (moving), dd (dead). A fact may carry some of them.
local POS_FLAGS = { fl = "flying", sw = "swimming", cb = "combat", mt = "mounted", mv = "moving", dd = "dead" }
function Run:Pos(key, pos)
    if self.st.phase ~= "live" or not Contains(self.st.entrants, key) or type(pos) ~= "table" then return false end
    local p = self.st.pos[key] or {}
    local function n01(v) v = tonumber(v); return v and v == v and max(0, min(1, v)) or nil end
    local function fin(v) v = tonumber(v); return v and v == v and abs(v) < 1e7 and v or nil end
    if pos.inst then
        -- in an instance: where they are isn't known (not where they were before it)
        p.map, p.x, p.y, p.wx, p.wy, p.cont = nil, nil, nil, nil, nil, nil
    elseif tonumber(pos.map) then
        p.map, p.x, p.y = floor(tonumber(pos.map)), n01(pos.x), n01(pos.y)
        p.wx, p.wy, p.cont = fin(pos.wx), fin(pos.wy), tonumber(pos.cont)
    elseif fin(pos.wx) and fin(pos.wy) then
        p.wx, p.wy, p.cont = fin(pos.wx), fin(pos.wy), tonumber(pos.cont)
    end
    if pos.z ~= nil then p.z = Clean(pos.z, NAME_LEN) end
    if pos.sz ~= nil then p.sz = Clean(pos.sz, NAME_LEN) end
    if type(pos.items) == "table" then
        local items, n = {}, 0
        for item, c in pairs(pos.items) do
            n = n + 1
            if n > 24 then break end
            items[tostring(item)] = max(0, floor(Num(c)))
        end
        p.items = items
    end
    if pos.gold ~= nil then p.gold = floor(Num(pos.gold)) end
    p.at = self.now()
    self.st.pos[key] = p
    local fl = self.st.flags[key] or {}
    for f, name in pairs(POS_FLAGS) do
        if pos[f] ~= nil then fl[name] = pos[f] and true or false end
    end
    self.st.flags[key] = fl
    return true
end

-- World yards of a map point: continent, x, y (nil: not known).
function Run:WorldOf(map, x, y)
    map, x, y = tonumber(map), tonumber(x), tonumber(y)
    if not (map and x and y) then return nil end
    self.worldCache = self.worldCache or {}
    local ck = map .. ":" .. x .. ":" .. y
    local c = self.worldCache[ck]
    if c then return c[1], c[2], c[3] end
    local cont, wx, wy
    local Sensors = ns.EventSensors
    if self.worldPos then
        cont, wx, wy = self.worldPos(map, x, y)
    elseif Sensors and Sensors.World then
        -- (the same map -> world as the entrants' clients use for their positions and the tracker's arrow)
        cont, wx, wy = Sensors.World(map, x, y)
    elseif C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D then
        local ok, ct, v = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
        if ok and ct and v and v.GetXY then cont = ct; wx, wy = v:GetXY() end
    end
    if not (wx and wy) then return nil end
    self.worldCache[ck] = { cont, wx, wy }
    return cont, wx, wy
end

-- Where a player or a place is in world yards: continent, x, y (nil: not known).
function Run:Where(v)
    if type(v) ~= "string" then return nil end
    local pl = self.def.places and self.def.places[v]
    if type(pl) == "table" then return self:WorldOf(pl.map, pl.x, pl.y) end
    local p = self.st.pos[v]
    if not p then return nil end
    if p.wx and p.wy then return p.cont, p.wx, p.wy end
    return self:WorldOf(p.map, p.x, p.y)
end

-- Yards between two players / places (nil: not known, or on another continent).
function Run:Yards(a, b)
    local ca, xa, ya = self:Where(a)
    local cb, xb, yb = self:Where(b)
    if not (xa and xb) then return nil end
    if ca and cb and ca ~= cb then return nil end
    return sqrt((xa - xb) ^ 2 + (ya - yb) ^ 2)
end

-- Is a player in a place: what their client said (enters / leaves), else (no word of that place yet) their position:
-- within its size, or in its subzone (zone) for a place set by that alone.
function Run:InPlace(key, pid)
    local set = self.st.inplace[pid]
    if set and set[key] then return true end
    local pl = self.def.places and self.def.places[pid]
    local pos = self.st.pos[key]
    if set == nil and type(pl) == "table" and pos then
        if tonumber(pl.map) and tonumber(pl.x) and tonumber(pl.y) then
            local y = self:Yards(key, pid)
            return y ~= nil and y <= (tonumber(pl.r) or 30)
        end
        if pl.sz and pl.sz ~= "" then return Plain(pos.sz) == Plain(pl.sz) end
        if pl.z and pl.z ~= "" then return Plain(pos.z) == Plain(pl.z) end
    end
    return false
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
    if left and not Contains(self.st.entrants, key) then self:DropPlayer(key) end
    if left then self:Pump() end
    return left
end

---------------------------------------------------------------------------
-- Smart block: Matches (part 1's Bracket)
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
        atonce = set("atonce"), bronze = set("bronze") and true or false, win = set("win"), seeds = seeds, rounds = {},
        m = {}, r = 0, out = {}, done = false }
    self.st.blocks[bid] = bk
    local n = #seeds
    if n < 2 then
        -- nothing to play (and nobody won: one player alone is no champion); its "is done" scripts go on with the event
        bk.done = true
        self:Log("block", "Matches: not enough players")
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
    self:Log("block", "Matches: " .. n .. " players, " .. bk.last .. " rounds")
    return bk
end

function Run:Bracket(bid)
    local bk = self.st.blocks[bid]
    if bk and bk.kind == "bracket" then return bk end
    return nil
end

-- Is this Matches block won by duels (part 1) or by the pieces ("award the match to")?
function Run:ByPieces(bid)
    return B():SmartSetting(self.def.blocks[bid], "win") == "pieces"
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
        self:Fire("bk.final", { player1 = final.a, player2 = final.b, both = List({ final.a, final.b }),
            finalist1 = final.a, finalist2 = final.b }, bid)
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
    self:Log("block", "Matches done: " .. self:Name(bk.champ) .. " wins")
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

-- A duel between two entrants (agree: both their games saw it, or only the loser's said so). It fires "wins a duel"
-- and "loses a duel"; matches won by a duel count it.
function Run:Duel(winner, loser, agree)
    if self.st.phase ~= "live" or type(winner) ~= "string" or type(loser) ~= "string" then return end
    if Contains(self.st.entrants, winner) then
        self:Fire("ev.happen", { player = winner, other = loser }, nil, nil, function(s) return s.top.a[1] == "duel" end)
    end
    if Contains(self.st.entrants, loser) then
        self:Fire("ev.happen", { player = loser, other = winner }, nil, nil, function(s) return s.top.a[1] == "lose" end)
    end
    for _, bid in ipairs(B():BlocksOf(self.def, "bracket")) do
        local bk = self:Bracket(bid)
        if bk and not bk.done and not self:ByPieces(bid) then
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
    self:Fire("ev.happen", { player = key }, nil, nil, function(s) return s.top.a[1] == "ready" end)
    self:Pump()
end

function Run:SetOnline(key, online)
    if self.st.phase ~= "live" or not Contains(self.st.entrants, key) then return end
    local was = not self.st.off[key]
    if was == (online and true or false) then return end
    self.st.off[key] = (not online) or nil
    local what = online and "on" or "off"
    self:Fire("ev.happen", { player = key }, nil, nil, function(s) return s.top.a[1] == what end)
    self:Pump()
    -- (an ask that waited only for them closes: the others have answered)
    if not online then
        local closed = false
        for aid, a in pairs(self.st.qa) do
            if a.open and a.who[key] and a.ans[key] == nil and self:AllAnswered(a) then
                self:CloseAsk(aid)
                closed = true
            end
        end
        if closed then
            self:Pump()
            self:Resume()
        end
    end
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
    self.st.stageAt = self.now()
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

-- What the event decided (stored with the result): placings (of the first Matches block, else of the first score on
-- the board), season points, badges, the scores and tags.
function Run:Result()
    local res = { champ = nil, second = nil, third = nil, points = {}, badges = Copy(self.st.awards), stats = Copy(self.st.stats),
        scores = Copy(self.st.scores), tags = Copy(self.st.tags) }
    local placed = false
    for _, bid in ipairs(B():BlocksOf(self.def, "bracket")) do
        local bk = self:Bracket(bid)
        if bk then
            res.champ, res.second, res.third = bk.champ, bk.second, bk.third
            placed = true
            break
        end
    end
    if not placed and #B():BlocksOf(self.def, "bracket") == 0 then
        for _, sc in ipairs(B():Defs(self.def, "scores", true)) do
            if sc.board then
                local list = self:Ranked(sc.id)
                res.champ = list[1] and list[1].key
                res.second = list[2] and list[2].key
                res.third = list[3] and list[3].key
                res.by = sc.id
                break
            end
        end
    end
    for k, n in pairs(self.st.stats[B().SEASON] or {}) do
        if n ~= 0 then res.points[k] = n end
    end
    return res
end

-- The end of a run (over or cancelled): asks close, nameplates come back.
function Run:Wrap()
    self.st.timers = {}
    self.threads = {}
    self.queue = {}
    for _, a in pairs(self.st.qa) do if a.open then a.open = false end end
    local plates = {}
    for k in pairs(self.st.plates) do plates[#plates + 1] = k end
    if #plates > 0 then
        tsort(plates)
        self.st.plates = {}
        Out(self, "plates", plates, false)
    end
end

function Run:End()
    if self.st.phase ~= "live" then return end
    self.st.phase = "done"
    self.st.t1 = self.now()
    self:Wrap()
    self:Log("stage", "The event is over")
    self:Changed()
    Out(self, "ended", self)
end

function Run:Cancel(reason)
    if self.st.phase ~= "live" and self.st.phase ~= "ready" then return end
    self.st.phase = "cancelled"
    self.st.reason = reason
    self.st.t1 = self.now()
    self:Wrap()
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
-- match(s): the hat's own blanks say yes (a tag, a score, an ask, "kills {Hogger}" ...).
function Run:Fire(key, ctx, bid, inner, match)
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
            if ok and match then
                s.top.a = s.top.a or {}
                local good, yes = pcall(match, s)
                ok = good and yes and true or false
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
    self.spawnSeq = (self.spawnSeq or 0) + 1
    local th = { s = s, ctx = CtxCopy(ctx), block = s.block or bid, steps = 0, path = {}, n = self.spawnSeq }
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
    -- (in the order they started: two waits ending in the same second go on the same way every time)
    tsort(list, function(a, b) return (a.n or 0) < (b.n or 0) end)
    for _, th in ipairs(list) do
        th.wait = nil
        self:Step(th)
    end
    self:Pump()
end

-- Every second or so: timers that ran out, "every" pieces, waits, asks whose time is up.
function Run:Tick()
    if self.st.phase ~= "live" then return end
    local now = self.now()
    -- (an ask closes at its time even when the script that asked it isn't there to close it: a restored run's)
    local ended = {}
    for aid, a in pairs(self.st.paused and {} or self.st.qa) do
        if type(a) == "table" and a.open and tonumber(a.ends) and a.ends <= now then ended[#ended + 1] = aid end
    end
    tsort(ended)
    for _, aid in ipairs(ended) do self:CloseAsk(aid) end
    -- ("when ... closes" runs before the script that asked goes on, as when the last answer closes it)
    if ended[1] then self:Pump() end
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

local function PlayerOf(run, th, v)
    local x = Eval(run, th, v)
    if type(x) == "table" and x.list then x = x[1] end
    if type(x) == "string" and x ~= "" then return x end
    return nil
end

-- A place's id from a blank (a typed one, or a value: a list's item, the "place" a hat gave).
local function PlaceOf(run, th, v)
    local x = Eval(run, th, v)
    if type(x) == "string" and run.def.places and run.def.places[x] then return x end
    return nil
end

-- A place's id or a player's key ("yards from ... to ...").
local function WhereOf(run, th, v)
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
-- How a piece goes on where its script was when the run was saved (a /reload of the host, a takeover): the waits
-- (wait, ask) and the C pieces holding them. RESUME[k](run, th, p, frame, frames) -> as DO.
local RESUME = {}

-- Where a script is, so that a restored run can go on from there (Run:Waits, Run:Revive): th.path holds a frame for
-- each stack being run (the script's own, then each C piece's inside): { i = the piece's place in its stack, k = its
-- key, and what that piece keeps: br (if: the branch taken), li (a loop's turn), n (repeat's count), list (for each's
-- players), sv (the loop's value before it), at (wait: when it ends), aid / q (ask: which, and its number) }.
local function Frame(th)
    local path = th.path
    return path and path[#path] or {}
end

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
        -- the other player of the match, from player 1's side (a message to both sets it per player)
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
-- the best n by a score (only who has it: an angler with no fish isn't third)
VALUE["pl.top"] = function(run, th, p)
    local n = floor(Num(Eval(run, th, arg(p, 1))))
    local list = run:Ranked(Eval(run, th, arg(p, 2)))
    local out = {}
    for i = 1, min(n, #list) do out[i] = list[i].key end
    return List(out)
end
VALUE["pl.tagged"] = function(run, th, p) return List(run:Tagged(arg(p, 1))) end
VALUE["pl.howmany"] = function(run, th, p) return #Players(run, th, arg(p, 1)) end
VALUE["pl.has"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    return k ~= nil and run:HasTag(arg(p, 2), k)
end
VALUE["pt.get"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    return k and run:GetScore(Eval(run, th, arg(p, 2)), k) or 0
end
VALUE["pt.place"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    return k and run:PlaceBy(Eval(run, th, arg(p, 2)), k) or 0
end
VALUE["pt.total"] = function(run, th, p)
    local sid = Eval(run, th, arg(p, 1))
    local sum = 0
    for _, k in ipairs(Players(run, th, arg(p, 2))) do sum = sum + (run:GetScore(sid, k) or 0) end
    return Num(sum)
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
VALUE["lo.add"] = function(run, th, p) return Num(Num(Eval(run, th, arg(p, 1))) + Num(Eval(run, th, arg(p, 2)))) end
VALUE["lo.sub"] = function(run, th, p) return Num(Num(Eval(run, th, arg(p, 1))) - Num(Eval(run, th, arg(p, 2)))) end
VALUE["lo.rand"] = function(run, th, p)
    local a, b = floor(Num(Eval(run, th, arg(p, 1)))), floor(Num(Eval(run, th, arg(p, 2))))
    if b < a then a, b = b, a end
    return Rand(run.st, a, b)
end
-- lists
VALUE["lo.litem"] = function(run, th, p)
    return run:ItemValue(arg(p, 2), floor(Num(Eval(run, th, arg(p, 1)))))
end
VALUE["lo.lrand"] = function(run, th, p)
    local items = run:ListItems(arg(p, 1))
    if #items == 0 then return nil end
    return run:ItemValue(arg(p, 1), Rand(run.st, 1, #items))
end
VALUE["lo.lcount"] = function(run, th, p) return #run:ListItems(arg(p, 1)) end
VALUE["lo.lmine"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    if not k then return nil end
    return run:ItemValue(arg(p, 2), run:ListPos(arg(p, 2), k))
end
VALUE["lo.lpos"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    return k and run:ListPos(arg(p, 2), k) or 0
end
-- "{text} matches {answers}": a question's answers, or "a / b / c"; capitals and spaces don't count
VALUE["lo.match"] = function(run, th, p)
    local text = Plain(TextOf(run, th, arg(p, 1)))
    if text == "" then return false end
    local want = Eval(run, th, arg(p, 2))
    local answers = {}
    if IsQuestion(want) then
        local items = run:ListItems(want.ql)
        local it = items[want.qi]
        for _, a in ipairs(type(it) == "table" and type(it.a) == "table" and it.a or {}) do answers[#answers + 1] = a end
    elseif IsList(want) then
        for i = 1, #want do answers[#answers + 1] = run:Text(want[i]) end
    elseif want ~= nil then
        for part in (run:Text(want) .. "/"):gmatch("([^/]*)/") do answers[#answers + 1] = part end
    end
    for _, a in ipairs(answers) do
        local x = Plain(a)
        if x ~= "" and x == text then return true end
    end
    return false
end
VALUE["tm.left"] = function(run, th, p) return run:TimerLeft(Eval(run, th, arg(p, 1))) end
VALUE["tm.since"] = function(run, th, p)
    local name = Eval(run, th, arg(p, 1))
    local now = run.now()
    if name == nil or name == "stage" then return max(0, now - (run.st.stageAt or run.st.t0 or now)) end
    local at = run.st.tstart[name]
    return at and max(0, now - at) or 0
end
VALUE["wo.zone"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    local want = strlower(TextOf(run, th, arg(p, 2)) or "")
    local zone = k and run.out.zoneOf and run.out.zoneOf(k)
    if not zone or want == "" then return false end
    return strfind(strlower(zone), want, 1, true) ~= nil
end
local STATE_FLAG = { mounted = "mounted", flying = "flying", swimming = "swimming", dead = "dead", combat = "combat",
    moving = "moving" }
VALUE["wo.is"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    local f = STATE_FLAG[arg(p, 2) or "mounted"]
    local fl = k and run.st.flags[k]
    return fl and f and fl[f] and true or false
end
VALUE["wo.items"] = function(run, th, p)
    local item = Eval(run, th, arg(p, 1))
    local k = PlayerOf(run, th, arg(p, 2))
    local pos = k and run.st.pos[k]
    local items = pos and pos.items
    if not (items and item ~= nil) then return 0 end
    return items[tostring(item)] or 0
end
VALUE["wo.gold"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    local pos = k and run.st.pos[k]
    return pos and pos.gold or 0
end
-- places
VALUE["pc.in"] = function(run, th, p)
    local k, pid = PlayerOf(run, th, arg(p, 1)), PlaceOf(run, th, arg(p, 2))
    return k ~= nil and pid ~= nil and run:InPlace(k, pid)
end
VALUE["pc.yards"] = function(run, th, p)
    local k, w = PlayerOf(run, th, arg(p, 1)), WhereOf(run, th, arg(p, 2))
    local y = k and w and run:Yards(k, w)
    if not y then return UNKNOWN_YARDS end
    return floor(y + 0.5)
end
VALUE["pc.near"] = function(run, th, p)
    local to = PlayerOf(run, th, arg(p, 2))
    if not to then return nil end
    local best, bestY
    for _, k in ipairs(Players(run, th, arg(p, 1))) do
        if k ~= to then
            local y = run:Yards(k, to)
            if y and (not bestY or y < bestY) then best, bestY = k, y end
        end
    end
    return best
end
VALUE["pc.sub"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    local pos = k and run.st.pos[k]
    return pos and pos.sz ~= "" and pos.sz or nil
end
VALUE["pc.zone"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    local pos = k and run.st.pos[k]
    if pos and pos.z and pos.z ~= "" then return pos.z end
    return k and run.out.zoneOf and run.out.zoneOf(k) or nil
end
-- warmer / colder / the same, since this piece last asked about that pair
VALUE["pc.warm"] = function(run, th, p)
    local k, w = PlayerOf(run, th, arg(p, 1)), WhereOf(run, th, arg(p, 2))
    local y = k and w and run:Yards(k, w)
    if not y then return nil end
    local pair = k .. ">" .. w
    local last = run.st.warm[pair]
    run.st.warm[pair] = y
    if not last or abs(y - last) < WARM_SAME then return "the same" end
    return y < last and "warmer" or "colder"
end
-- asks
VALUE["as.answer"] = function(run, th, p)
    local k = PlayerOf(run, th, arg(p, 1))
    local a = run.st.qa[arg(p, 2)]
    if not (k and a) or (type(a.lost) == "table" and a.lost[k]) then return nil end
    return Copy(a.ans[k])
end
VALUE["as.top"] = function(run, th, p)
    local t = run:Tally(arg(p, 1))
    return t[1] and Copy(t[1].v) or nil
end
VALUE["as.count"] = function(run, th, p)
    local want = Eval(run, th, arg(p, 1))
    if type(want) == "table" and want.list then want = want[1] end
    for _, r in ipairs(run:Tally(arg(p, 2))) do
        if Same(r.v, want) then return r.n end
    end
    return 0
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

-- (C pieces note in their frame what they're doing - the branch, the loop's turn - so a restored run can go on
-- inside them: RESUME, Run:Exec)
DO["lo.if"] = function(run, th, p)
    if Bool(run, th, arg(p, 1)) then
        Frame(th).br = "c1"
        return run:Exec(th, p.c1, true)
    end
end
DO["lo.ifelse"] = function(run, th, p)
    local br = Bool(run, th, arg(p, 1)) and "c1" or "c2"
    Frame(th).br = br
    return run:Exec(th, p[br], true)
end
RESUME["lo.if"] = function(run, th, p, fr, rs) return run:Exec(th, p[fr.br == "c2" and "c2" or "c1"], true, rs) end
RESUME["lo.ifelse"] = RESUME["lo.if"]

local function Repeat(run, th, p, n, from, rs)
    local fr = Frame(th)
    fr.n = n
    for li = from, n do
        fr.li = li
        local r = run:Exec(th, p.c1, true, li == from and rs or nil)
        if r == "stop" then return r end
    end
end
DO["lo.rep"] = function(run, th, p) return Repeat(run, th, p, min(100, floor(Num(Eval(run, th, arg(p, 1))))), 1) end
RESUME["lo.rep"] = function(run, th, p, fr, rs)
    local n = max(0, min(100, floor(Num(fr.n))))
    return Repeat(run, th, p, n, max(1, min(n, floor(Num(fr.li)))), rs)
end

local function EachFrom(run, th, p, list, from, saved, rs)
    local fr = Frame(th)
    fr.list, fr.sv = list, saved
    for li = from, #list do
        fr.li = li
        th.ctx.each = list[li]
        local r = run:Exec(th, p.c1, true, li == from and rs or nil)
        if r == "stop" then th.ctx.each = saved; return r end
    end
    th.ctx.each = saved
end
DO["lo.each"] = function(run, th, p) return EachFrom(run, th, p, Players(run, th, arg(p, 1)), 1, th.ctx.each) end
RESUME["lo.each"] = function(run, th, p, fr, rs)
    local list = {}
    for i = 1, min(type(fr.list) == "table" and #fr.list or 0, 40) do
        if type(fr.list[i]) == "string" then list[#list + 1] = fr.list[i] end
    end
    if #list == 0 then error("this script can't go on where it was", 0) end
    local sv = fr.sv
    if type(sv) ~= "string" then sv = nil end
    return EachFrom(run, th, p, list, max(1, min(#list, floor(Num(fr.li)))), sv, rs)
end

local function ForFrom(run, th, p, from, saved, rs)
    local lid = arg(p, 1)
    local items = run:ListItems(lid)
    local fr = Frame(th)
    fr.sv = saved
    for i = from, min(#items, B().LIMITS.items * 2) do
        fr.li = i
        th.ctx.item = run:ItemValue(lid, i)
        local r = run:Exec(th, p.c1, true, i == from and rs or nil)
        if r == "stop" then th.ctx.item = saved; return r end
    end
    th.ctx.item = saved
end
DO["lo.lfor"] = function(run, th, p) return ForFrom(run, th, p, 1, th.ctx.item) end
RESUME["lo.lfor"] = function(run, th, p, fr, rs)
    local sv = fr.sv
    if type(sv) == "table" and not IsQuestion(sv) then sv = nil end
    return ForFrom(run, th, p, max(1, floor(Num(fr.li))), sv, rs)
end
DO["lo.vset"] = function(run, th, p)
    local name = arg(p, 1)
    if type(name) ~= "string" then return end
    local v = Eval(run, th, arg(p, 2))
    if type(v) == "table" and v.list then v = v[1] end
    if type(v) == "table" and not IsQuestion(v) then v = nil end
    run.st.vars[name] = Copy(v)
    run:Log("var", name .. " = " .. run:Text(v))
end
DO["lo.lnext"] = function(run, th, p)
    for _, k in ipairs(Players(run, th, arg(p, 1))) do run:ListNext(arg(p, 2), k) end
end

DO["pt.add"] = function(run, th, p)
    local n = Num(Eval(run, th, arg(p, 1)))
    local sid = Eval(run, th, arg(p, 2))
    for _, k in ipairs(Players(run, th, arg(p, 3))) do
        run:SetScore(sid, k, n, true)
    end
end
DO["pt.set"] = function(run, th, p)
    local sid = Eval(run, th, arg(p, 1))
    local list = Players(run, th, arg(p, 2))
    if #list == 0 then return end
    local n = Num(Eval(run, th, arg(p, 3)))
    for _, k in ipairs(list) do run:SetScore(sid, k, n, false) end
end
DO["pt.badge"] = function(run, th, p)
    local bid = arg(p, 1)
    if not (run.def.badges and run.def.badges[bid]) then return end
    for _, k in ipairs(Players(run, th, arg(p, 2))) do
        local dup = not run:InEvent(k)   -- (one who left the event gets no badge)
        for _, a in ipairs(run.st.awards) do
            if a.p == k and a.b == bid then dup = true end
        end
        if not dup then
            tinsert(run.st.awards, { p = k, b = bid })
            run:Log("badge", run:Name(k) .. " gets " .. tostring(run.def.badges[bid].n))
        end
    end
end

-- tags
DO["pl.tag"] = function(run, th, p) run:Tag(arg(p, 2), Players(run, th, arg(p, 1))) end
DO["pl.untag"] = function(run, th, p) run:Untag(arg(p, 2), Players(run, th, arg(p, 1))) end
DO["pl.split"] = function(run, th, p) run:Split(Players(run, th, arg(p, 1)), arg(p, 2), arg(p, 3)) end

-- places: the tracker's arrow
DO["pc.point"] = function(run, th, p)
    local pid = PlaceOf(run, th, arg(p, 2))
    for _, k in ipairs(Players(run, th, arg(p, 1))) do
        -- (one who is there already has nowhere to go: as when they get there)
        if run:InEvent(k) then run.st.point[k] = not (pid and run:InPlace(k, pid)) and pid or nil end
    end
    if pid then run:Log("point", run:Text(pid)) end
end
DO["pc.unpoint"] = function(run, th, p)
    for _, k in ipairs(Players(run, th, arg(p, 1))) do run.st.point[k] = nil end
end

-- asks: the script waits until the ask closes (time up, everyone answered, or "close")
local function AskWait(run, th, aid, a)
    local fr = Frame(th)
    fr.aid, fr.q = aid, a.id
    Wait(th, { at = a.ends, cond = function() return not a.open or run.st.qa[aid] ~= a end })
    if a.open and run.st.qa[aid] == a then run:CloseAsk(aid) end
end
local function AskAndWait(run, th, aid, to, q, item)
    local a = run:OpenAsk(aid, to, q, item)
    if a then AskWait(run, th, aid, a) end
end
-- (restored: the ask still open waits on; one that closed meanwhile goes on at the next tick)
RESUME["as.ask"] = function(run, th, p, fr)
    local aid = fr.aid
    local a = type(aid) == "string" and run.st.qa[aid]
    if type(a) == "table" and a.open and a.id == fr.q then
        AskWait(run, th, aid, a)
    else
        Wait(th, { at = 0 })
    end
end
RESUME["as.askq"] = RESUME["as.ask"]
DO["as.ask"] = function(run, th, p)
    local aid = arg(p, 2)
    local ad = type(aid) == "string" and run.def.asks and run.def.asks[aid]
    if type(ad) ~= "table" then return end
    local q = Trim(Clean(ad.q or "", B().LIMITS.question))
    if q == "" then q = tostring(ad.n or "?") end
    AskAndWait(run, th, aid, Players(run, th, arg(p, 1)), q)
end
DO["as.askq"] = function(run, th, p)
    local aid = arg(p, 2)
    if not (type(aid) == "string" and run.def.asks and run.def.asks[aid]) then return end
    local v = Eval(run, th, arg(p, 3))
    local q = Trim(Clean(run:Text(v), B().LIMITS.question))
    if q == "" then q = Trim(Clean(run.def.asks[aid].q or run.def.asks[aid].n or "?", B().LIMITS.question)) end
    AskAndWait(run, th, aid, Players(run, th, arg(p, 1)), q, IsQuestion(v) and Copy(v) or nil)
end
DO["as.close"] = function(run, th, p) run:CloseAsk(arg(p, 1)) end
DO["as.give"] = function(run, th, p) run:GiveButton(Eval(run, th, arg(p, 2)), Players(run, th, arg(p, 1))) end
DO["as.take"] = function(run, th, p) run:TakeButton(Eval(run, th, arg(p, 1)), Players(run, th, arg(p, 2))) end

-- What a text blank says, ready for chat ("" when there is nothing to say).
local function Said(run, th, v, limit)
    local text = Clean(TextOf(run, th, v), limit)
    if not text:find("%S") then return "" end
    return text
end

-- Does a text blank say "opponent" (worked out per player of a match)?
local function SaysOpponent(v)
    local found = false
    if type(v) == "table" then
        local list = v.j or { v }
        for _, x in ipairs(list) do
            B():Walk(type(x) == "table" and x.k and x or nil, function(q)
                if q.k == "ctx" and q.a and q.a[1] == "opponent" then found = true end
            end)
        end
    end
    return found
end

-- The players a message is for (in the event) and its text: { { keys, text } } (one group a text: "opponent" in a
-- message to both players of a match is each one's own opponent).
local function Messages(run, th, toArg, textArg, limit)
    local to = {}
    for _, k in ipairs(Players(run, th, toArg)) do
        if run:InEvent(k) and not Contains(to, k) then to[#to + 1] = k end
    end
    local groups = {}
    if #to == 0 then return groups end
    if not SaysOpponent(textArg) then
        local text = Said(run, th, textArg, limit)
        if text ~= "" then groups[1] = { keys = to, text = text } end
        return groups
    end
    local saved, byText = th.ctx.opponent, {}
    for _, k in ipairs(to) do
        if th.ctx.player1 and th.ctx.player2 then
            th.ctx.opponent = (k == th.ctx.player1) and th.ctx.player2 or th.ctx.player1
        end
        local text = Said(run, th, textArg, limit)
        if text ~= "" then
            local g = byText[text]
            if not g then g = { keys = {}, text = text }; byText[text] = g; groups[#groups + 1] = g end
            g.keys[#g.keys + 1] = k
        end
    end
    th.ctx.opponent = saved
    return groups
end

DO["ch.show"] = function(run, th, p)
    for _, g in ipairs(Messages(run, th, arg(p, 1), arg(p, 2), SHOW_LEN)) do
        run:Log("show", g.text, { to = g.keys })
        Out(run, "show", g.keys, g.text)
    end
end
DO["ch.tell"] = function(run, th, p)
    for _, g in ipairs(Messages(run, th, arg(p, 1), arg(p, 2), SHOW_LEN)) do
        run:Log("tell", run:Text(List(g.keys)) .. ": " .. g.text, { to = g.keys })
        Out(run, "tell", g.keys, g.text)
    end
end
DO["ch.moment"] = function(run, th, p)
    local text = Said(run, th, arg(p, 1), MOMENT_LEN)
    if text ~= "" then run:Moment(text) end
end
DO["ch.sound"] = function(run, th, p)
    local sound = arg(p, 1)
    if not B().SOUND_BY[sound] then return end
    local to = {}
    for _, k in ipairs(Players(run, th, arg(p, 2))) do
        if run:InEvent(k) and not Contains(to, k) then to[#to + 1] = k end
    end
    if #to == 0 then return end
    run:Log("sound", B().SOUND_BY[sound][2], { to = to })
    Out(run, "sound", to, sound)
end
-- for the people outside the event: only the host sends it (EventLive spaces them), 20 an event, never in practice
DO["ch.guild"] = function(run, th, p)
    local text = Said(run, th, arg(p, 1), CHAT_LEN)
    if text == "" or run.st.gp >= GUILD_LIMIT then return end
    run.st.gp = run.st.gp + 1
    run:Log("guild", text)
    if not run.st.practice then Out(run, "guild", text) end
end

DO["tm.wait"] = function(run, th, p)
    local sec = max(0, min(3600, Num(Eval(run, th, arg(p, 1)))))
    local at = run.now() + sec
    Frame(th).at = at
    Wait(th, { at = at })
end
-- (restored: the wait ends when it would have; past that, at the next tick)
RESUME["tm.wait"] = function(run, th, p, fr)
    local at = tonumber(fr.at)   -- (a server time: not Num, which holds numbers to +-1e9)
    Wait(th, { at = (at and at == at) and at or 0 })
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
DO["tm.show"] = function(run, th, p)
    local name = Eval(run, th, arg(p, 1))
    if type(name) == "string" and name ~= "" then run.st.shown[name] = true end
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
-- friendly nameplates off (they come back when the event ends)
DO["wo.plates"] = function(run, th, p)
    local to = {}
    for _, k in ipairs(Players(run, th, arg(p, 1))) do
        if run:InEvent(k) and not run.st.plates[k] then run.st.plates[k] = true; to[#to + 1] = k end
    end
    if #to == 0 then return end
    run:Log("plates", run:Text(List(to)))
    Out(run, "plates", to, true)
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
        -- won by the pieces: the event's own rule decides it (a real win, 1-0); else (and a no-show) a walkover
        local pieces = run:ByPieces(bid) and not th.s.block
        if pieces and m.wa == 0 and m.wb == 0 then
            if k == m.a then m.wa = 1 else m.wb = 1 end
        end
        run:BracketFinish(bid, m, k, not pieces)
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
-- (part 1's rule: a restored run drops the question who won, and the script asking it; the host decides the match)
RESUME["bk.ask"] = function() return "stop" end

-- Runs a stack from piece p. inner: a C piece's insides (a "stop" there ends the whole script). resume: the frames
-- of a script that was waiting (Run:Revive): the pieces before the one each frame names ran already and are skipped,
-- that one goes on where it was (RESUME); a script that changed since (not the same piece there) stops.
function Run:Exec(th, p, inner, resume)
    local path = th.path
    if not path then
        path = {}
        th.path = path
    end
    local depth = #path + 1
    local want = resume and resume[depth]
    if resume and type(want) ~= "table" then error("this script can't go on where it was", 0) end
    local i, out = 0, nil
    while p do
        i = i + 1
        if want and i < Num(want.i) then
            p = p.n
        else
            Bump(self, th)
            local fr = { i = i, k = p.k }
            path[depth] = fr
            local r
            if want then
                if p.k ~= want.k or not RESUME[p.k] then error("this script changed: it can't go on where it was", 0) end
                for k, v in pairs(want) do
                    if fr[k] == nil and type(k) == "string" then fr[k] = Copy(v) end
                end
                want = nil
                r = RESUME[p.k](self, th, p, fr, resume)
            else
                local f = DO[p.k]
                if f then r = f(self, th, p) end
            end
            if r == "stop" then
                out = "stop"
                break
            end
            p = p.n
        end
    end
    if want then error("this script changed: it can't go on where it was", 0) end
    path[depth] = nil
    return out
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

-- A snapshot read without a run (EventLive's MyTags / MyScores / MyAsks / MyButtons / MyPoint, the board): a run
-- over it that does nothing (no out, never started).
function E:Reader(def, st)
    local run = setmetatable({ def = def, st = st, out = {}, now = function() return (GetServerTime and GetServerTime()) or time() end,
        threads = {}, queue = {}, log = {}, byHat = {} }, Run)
    for _, k in ipairs(STATE_TABLES) do if type(st[k]) ~= "table" then st[k] = {} end end
    return run
end

-- A player's tags in a snapshot: { tid ... } (the tag's `shown` says who may see it: the UI keeps to it).
function E:TagsOf(def, st, key)
    local out = {}
    for _, t in ipairs(ns.EventBlocks:Defs(def, "tags", true)) do
        local set = st and st.tags and st.tags[t.id]
        if set and set[key] then out[#out + 1] = t.id end
    end
    return out
end

-- A player's scores on the board in a snapshot: { { sid, n, place } } (the event's scores with `board`, in name order).
function E:ScoresOf(def, st, key)
    local out = {}
    local r = self:Reader(def, st)
    for _, sc in ipairs(ns.EventBlocks:Defs(def, "scores", true)) do
        local n = sc.board and r:GetScore(sc.id, key)
        if n ~= nil then out[#out + 1] = { sid = sc.id, n = n, place = r:PlaceBy(sc.id, key) } end
    end
    return out
end

-- A player's open asks in a snapshot, not answered yet: { { aid, a } } (oldest first).
function E:AsksFor(st, key)
    local out = {}
    for aid, a in pairs(st and st.qa or {}) do
        if type(a) == "table" and a.open and a.who and a.who[key] and (a.ans or {})[key] == nil then
            out[#out + 1] = { aid = aid, a = a }
        end
    end
    tsort(out, function(x, y) return (x.a.id or 0) < (y.a.id or 0) end)
    return out
end

-- A player's buttons in a snapshot: { label ... } (sorted).
function E:ButtonsOf(st, key)
    local out = {}
    for label, holders in pairs(st and st.buttons or {}) do
        if type(holders) == "table" and holders[key] then out[#out + 1] = label end
    end
    tsort(out)
    return out
end

-- The place a player's arrow points to in a snapshot (nil: none).
function E:PointOf(st, key) return st and st.point and st.point[key] or nil end

function E:OnInit() end

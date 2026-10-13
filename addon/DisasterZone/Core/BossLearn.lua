if DisasterZoneBoot and DisasterZoneBoot.Run("Core/BossLearn.lua", ...) then return end -- DisasterZone Core/BossLearn.lua
-- Boss mods that learn from the guild's own pulls (ns.BossLearn). The timers in Data/BossMods come from DBM, BigWigs and
-- cmangos; this measures what each boss really does in our raids and tightens them (the rules: Core/BossLearnMath.lua;
-- the saved format: dev/docs/bossmods/LEARNING.md in the dev kit). Approved mockup: cleanup_template.html section 3.
--   recorder   during a boss fight only (a real ENCOUNTER_START, not Try it, not a /reload pick-up): the times each
--              learnable bar's event happened, phase changes, and for the developer's review the hostile casts the
--              data doesn't know (12 a pull) and the boss lines no trigger matched (6). A combat-log subscriber of
--              its own, after the alerts', every call inside a pcall: an error, or 2,000 recorded events, stops the
--              recording for that pull (one line in /dz debug and in the saved log); the alerts never notice.
--   learning   after the fight's end only (ENCOUNTER_END): the pull is stored, the boss's windows worked out again.
--              A pull uses what was learned when it started (BossMod's snapshot at ENCOUNTER_START): nothing learned
--              changes a running pull. Setting bossmods.learn (on) - off = the data files' numbers.
--   sharing    3-12 s after the end, never in a fight: a few hundred bytes of the pull to the guild (bossmods.learnShare,
--              on), skipped when a guildmate already sent the same pull with as much in it. What arrives is checked
--              (format, version, the boss's data signature, every time within the pull, caps) and dropped whole when
--              anything is odd; it waits while I'm in a fight.
--   review     the developer only (Tsumil: Perf:IsDev / Feedback:AmIDev): an alert that never fires while the boss
--              casts a spell of the same name under another id ("Use 36240" / "Ignore"), frequent unknown casts and
--              unknown yells. Decisions are saved for the dev kit (tools/bossmods_learned.py) to bake into the data;
--              Use only changes the developer's own client.
-- Saved: DisasterZoneBossLearnDB (its own SavedVariables, account wide).
local addonName, ns = ...

local BL = ns:NewModule("BossLearn")
local Math = ns.BossLearnMath
local Util = ns.Util

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local pairs, ipairs, type, tonumber, tostring, next, pcall = pairs, ipairs, type, tonumber, tostring, next, pcall
local strlower, strfind, strsub, tsort, tremove = string.lower, string.find, string.sub, table.sort, table.remove
local band = bit and bit.band

local MAX_EVENTS = 2000           -- recorded events a pull (then it stops: not clean)
local MAX_UNK, MAX_YELL, YELL_LEN = 12, 6, 120
local CAP_BOSS, CAP_ALL = 30, 2000
local CAST_MAX = 10               -- s: a SPELL_CAST_SUCCESS this soon after the START is the same cast
local SAME_PULL = 20              -- s: summaries of one boss and leader this close are one pull
local MERGE_TOL = 0.5
local SEND_MIN, SEND_SPREAD = 3, 9
local REPORT_AFTER = 15           -- s after the end: the "what we learned" pop-up (after the guild's summaries)
local MIN_ADDON = "1.4.1"         -- the oldest DisasterZone whose summaries are taken (the first that sends them)
local MAX_OBS_ALERT = 400
local MAX_INBOX = 30
local MAX_LOG = 20
local HOSTILE_NPC = 0x840         -- COMBATLOG_OBJECT_TYPE_NPC (0x800) + COMBATLOG_OBJECT_REACTION_HOSTILE (0x40)
local PLAYER_CTRL = 0x100         -- COMBATLOG_OBJECT_CONTROL_PLAYER
local UNK_SUB = { SPELL_CAST_START = true, SPELL_CAST_SUCCESS = true, SPELL_AURA_APPLIED = true }
local MSG, CLASS = "BL", "boss"
BL.MSG, BL.CAP_BOSS, BL.CAP_ALL, BL.MAX_EVENTS = MSG, CAP_BOSS, CAP_ALL, MAX_EVENTS

local Round1 = Math.Round1
local function BM() return ns.BossMod end
local function Clock() return GetTime() end

---------------------------------------------------------------------------
-- Settings, who I am
---------------------------------------------------------------------------

local function Setting(path, default)
    local bm = BM()
    if not (bm and bm.Get) then return default end
    return bm.Get(path, default)
end

-- Learning runs (records, applies) while boss mods and "Learn from our pulls" are on.
function BL:Enabled()
    local bm = BM()
    return (bm and bm:IsOn() and Setting("learn", true)) and true or false
end

-- Pulls go to and come from the guild while learning and "Share what we learn" are on (not in demo mode: the fake
-- guild of Core/Demo.lua never sends or takes anything).
function BL:Sharing()
    return (self:Enabled() and Setting("learnShare", true) and not Util.DemoOn()) and true or false
end

-- (asked every frame by the recording line: the answer is kept a minute)
local devIs, devAt = nil, -99
function BL:IsDev()
    local t = GetTime()
    if devIs ~= nil and t - devAt < 60 then return devIs end
    local yes = false
    local P = ns.Perf
    if P and P.IsDev and P:IsDev() then yes = true end
    local F = ns.Feedback
    if not yes and F and F.AmIDev then
        local ok, v = pcall(F.AmIDev, F)
        yes = (ok and v) and true or false
    end
    devIs, devAt = yes, t
    return yes
end

local function InFight()
    if InCombatLockdown and InCombatLockdown() then return true end
    if IsEncounterInProgress and IsEncounterInProgress() then return true end
    local bm = BM()
    return (bm and bm.Active and bm:Active() ~= nil) and true or false
end
BL.InFight = InFight

-- The group's leader (the pull's identity: boss + leader + when), as a full name.
local function Leader()
    if IsInRaid and IsInRaid() and GetRaidRosterInfo then
        for i = 1, (GetNumGroupMembers and GetNumGroupMembers() or 0) do
            local name, rank = GetRaidRosterInfo(i)
            if rank == 2 and type(name) == "string" then return Util.NormalizeName(name) or name end
        end
    elseif IsInGroup and IsInGroup() and UnitIsGroupLeader then
        if UnitIsGroupLeader("player") then return Util.PlayerKey() or "?" end
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists and UnitExists(u) and UnitIsGroupLeader(u) then
                local n, r = UnitName(u)
                if type(n) == "string" then return Util.NormalizeName((r and r ~= "") and (n .. "-" .. r) or n) or n end
            end
        end
    end
    return Util.PlayerKey() or "?"
end
BL.Leader = Leader

---------------------------------------------------------------------------
-- The saved data (format: dev/docs/bossmods/LEARNING.md)
---------------------------------------------------------------------------

local function Store()
    local db = DisasterZoneBossLearnDB
    if type(db) ~= "table" or db.v ~= Math.FORMAT then
        db = { v = Math.FORMAT }
        DisasterZoneBossLearnDB = db
    end
    if type(db.pulls) ~= "table" then db.pulls = {} end
    if type(db.learned) ~= "table" then db.learned = {} end
    if type(db.review) ~= "table" then db.review = {} end
    if type(db.review.decisions) ~= "table" then db.review.decisions = {} end
    if type(db.review.suggest) ~= "table" then db.review.suggest = {} end
    if type(db.log) ~= "table" then db.log = {} end
    return db
end
BL.Store = Store

-- One line in /dz debug and in the saved log (the last MAX_LOG).
local function Log(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    line = ok and line or tostring(fmt)
    if ns.Debug then ns:Debug("boss learning: %s", line) end
    local log = Store().log
    log[#log + 1] = (date and date("%Y-%m-%d %H:%M ") or "") .. line
    while #log > MAX_LOG do tremove(log, 1) end
end
BL.Log = Log

function BL:Pulls(boss)
    local l = Store().pulls[boss]
    return type(l) == "table" and l or {}
end

---------------------------------------------------------------------------
-- Plans: what the recorder looks for, per boss (made once, again after a developer's spell fix)
---------------------------------------------------------------------------

local plans = {}
local aliasGen = 0

local function Add(map, sub, id, v)
    map[sub] = map[sub] or {}
    local l = map[sub][id]
    if not l then l = {}; map[sub][id] = l end
    for _, x in ipairs(l) do if x == v then return end end
    l[#l + 1] = v
end

-- The developer's "Use <id>" fixes for a boss: { [alert key] = { from = id, use = id } }.
local function Fixes(boss)
    local out = {}
    if not BL:IsDev() then return out end
    local dec = Store().review.decisions[boss]
    for _, d in pairs(type(dec) == "table" and dec or {}) do
        if type(d) == "table" and type(d.use) == "number" and type(d.alert) == "string" then
            out[d.alert] = { from = d.from, use = d.use }
        end
    end
    return out
end

local function Plan(def)
    local p = plans[def.key]
    if p and p.def == def and p.gen == aliasGen then return p end
    p = { def = def, gen = aliasGen, specs = {}, byKey = {}, watch = {}, trig = {}, known = {}, checks = {}, ov = {} }
    p.ds = Math.Signature(def)
    local SUB = BM().SUB
    local fixes = Fixes(def.key)
    for _, a in ipairs(def.alerts or {}) do
        local s = Math.Spec(a)
        if s then
            p.specs[#p.specs + 1] = s
            s.i = #p.specs
            p.byKey[s.key] = s
            if type(a.src) == "table" then s.src = {}; for _, id in ipairs(a.src) do s.src[id] = true end end
            local fix = fixes[s.key]
            if s.mode == "own" then
                for word, ids in pairs(s.own) do
                    for _, sub in ipairs(SUB[word] or {}) do
                        for _, id in ipairs(ids) do
                            Add(p.watch, sub, id, { s = s })
                            if fix and fix.from == id then Add(p.watch, sub, fix.use, { s = s }); p.ov[s.key] = true end
                        end
                    end
                end
            else
                local st, su = { s = s, start = true }, { s = s, success = true }
                Add(p.watch, "SPELL_CAST_START", a.spell, st)
                Add(p.watch, "SPELL_CAST_SUCCESS", a.spell, su)
                if fix and fix.from == a.spell then
                    Add(p.watch, "SPELL_CAST_START", fix.use, st)
                    Add(p.watch, "SPELL_CAST_SUCCESS", fix.use, su)
                    p.ov[s.key] = true
                end
            end
        end
    end
    -- every alert's own combat-log and yell triggers (to see one that never fires), every spell id the data names
    for sub, map in pairs(def._t and def._t.cleu or {}) do
        for id, list in pairs(map) do
            p.known[id] = true
            for _, e in ipairs(list) do
                if e.f == "on" and e.a and e.a.key then
                    Add(p.trig, sub, id, e.a.key)
                    p.checks[e.a.key] = true
                end
            end
        end
    end
    for _, kind in ipairs({ "yell", "emote" }) do
        for _, e in ipairs(def._t and def._t[kind] or {}) do
            if e.f == "on" and e.a and e.a.key then p.checks[e.a.key] = true end
        end
    end
    for _, map in pairs(def._e and def._e.cleu or {}) do for id in pairs(map) do p.known[id] = true end end
    for _, a in ipairs(def.alerts or {}) do
        if type(a.spell) == "number" then p.known[a.spell] = true end
        if type(a.icon) == "number" then p.known[a.icon] = true end
    end
    plans[def.key] = p
    return p
end
BL.Plan = Plan

---------------------------------------------------------------------------
-- The recorder
---------------------------------------------------------------------------

local recs = {}                   -- the pulls being recorded (one per recorded fight)
local enteredAt = -99             -- GetTime of the last PLAYER_ENTERING_WORLD (login, reload, a new zone)
BL.recs = recs
local listening = false
local OnLog, OnYell, OnBossEmote, OnEmote

local function Listen()
    local any = false
    for _, r in ipairs(recs) do if r.on then any = true break end end
    if any == listening then return end
    listening = any
    if ns.CombatLog then ns.CombatLog:SetSubscribed("bosslearn", OnLog, any) end
    local ev = { { "CHAT_MSG_MONSTER_YELL", OnYell }, { "CHAT_MSG_RAID_BOSS_EMOTE", OnBossEmote },
                 { "CHAT_MSG_MONSTER_EMOTE", OnEmote } }
    for _, e in ipairs(ev) do
        if any then ns:RegisterEvent(e[1], e[2]) else ns:UnregisterEvent(e[1], e[2]) end
    end
end

-- Recording stops for the rest of this pull (it is then not clean: never learned from, never shared).
local function Stop(r, why)
    if not r.on then return end
    r.on = false
    r.stop = tostring(why or "stopped"):sub(1, 200)
    Log("%s pull %d: recording stopped (%s)", tostring(r.boss), r.num or 0, r.stop)
    Listen()
end

local function Fail(r, err) Stop(r, "error: " .. tostring(err)) end

-- One recorded time (s from the pull, a tenth).
local function Append(r, list, t)
    if r.n >= MAX_EVENTS then Stop(r, "2,000 events") return end
    r.n = r.n + 1
    list[#list + 1] = floor(t * 10 + 0.5) / 10
end

local function NpcOf(guid)
    local f = BM() and BM().NpcOf
    return f and f(guid) or nil
end

local function Record(r, sub, srcGUID, srcFlags, id, name)
    if not id then return end
    local P = r.plan
    local tm = P.trig[sub]
    local l = tm and tm[id]
    if l then
        local f = r.fired
        for i = 1, #l do local k = l[i]; f[k] = (f[k] or 0) + 1 end
    end
    local wm = P.watch[sub]
    l = wm and wm[id]
    if l then
        local t = Clock() - r.t0
        local player = band and type(srcFlags) == "number" and band(srcFlags, PLAYER_CTRL) ~= 0
        if not player then
            for i = 1, #l do
                local w = l[i]
                local s = w.s
                if not s.src or s.src[NpcOf(srcGUID) or -1] then
                    local k = s.i
                    if w.success and t - r.pend[k] <= CAST_MAX then
                        r.pend[k] = -99           -- (the end of a cast whose start was counted)
                    else
                        if t - r.lastObs[k] >= Math.DEBOUNCE then
                            r.lastObs[k] = t
                            Append(r, r.o[k], t)
                        end
                        if w.start then r.pend[k] = t end
                    end
                end
            end
        end
    end
    if UNK_SUB[sub] and not P.known[id] and band and type(srcFlags) == "number"
        and band(srcFlags, HOSTILE_NPC) == HOSTILE_NPC then
        local u = r.uBy[id]
        if u then
            u.n = u.n + 1
        elseif #r.u < MAX_UNK and r.n < MAX_EVENTS then
            r.n = r.n + 1
            u = { id = id, n = 1, t = Round1(Clock() - r.t0), name = type(name) == "string" and strsub(name, 1, 60) or nil }
            r.u[#r.u + 1] = u
            r.uBy[id] = u
        end
    end
end

OnLog = function(_, _, sub, _, srcGUID, _, srcFlags, _, _, _, _, _, spellId, spellName)
    for i = 1, #recs do
        local r = recs[i]
        if r.on then
            local ok, err = pcall(Record, r, sub, srcGUID, srcFlags, spellId, spellName)
            if not ok then Fail(r, err) end
        end
    end
end
BL.OnLog = OnLog

-- A boss line: the alerts it fires count as fired; a line no trigger knows is kept for the review.
local function CleanText(s)
    s = tostring(s):gsub("|", "/"):gsub("[%z\1-\31]", " ")
    if #s > YELL_LEN then s = strsub(s, 1, YELL_LEN):gsub("[\192-\255][\128-\191]*$", "") end
    return s
end

local function Chat(r, kind, text, keep)
    if type(text) ~= "string" then return end
    local low = strlower(text)
    local matched = false
    local T, E = r.def._t, r.def._e
    for _, e in ipairs(T and T[kind] or {}) do
        if e.text and strfind(low, e.text, 1, true) then
            matched = true
            if e.a and e.a.key and r.fired[e.a.key] then r.fired[e.a.key] = r.fired[e.a.key] + 1 end
        end
    end
    for _, e in ipairs(E and E[kind] or {}) do
        if e.text and strfind(low, e.text, 1, true) then matched = true end
    end
    if matched or not keep then return end
    local clean = CleanText(text)
    local y = r.yBy[clean]
    if y then
        y.n = y.n + 1
    elseif #r.y < MAX_YELL and r.n < MAX_EVENTS then
        r.n = r.n + 1
        y = { t = Round1(Clock() - r.t0), n = 1, text = clean, kind = kind }
        r.y[#r.y + 1] = y
        r.yBy[clean] = y
    end
end

local function ChatAll(kind, text, keep)
    for i = 1, #recs do
        local r = recs[i]
        if r.on then
            local ok, err = pcall(Chat, r, kind, text, keep)
            if not ok then Fail(r, err) end
        end
    end
end
OnYell = function(_, text) ChatAll("yell", text, true) end
OnBossEmote = function(_, text) ChatAll("emote", text, true) end
OnEmote = function(_, text) ChatAll("emote", text, false) end
BL.OnYell, BL.OnBossEmote = OnYell, OnBossEmote

-- What the engine tells the recorder (Core/BossMod.lua, inside its own pcall): "bar" a bar (re)started by its trigger
-- (x = the alert), "phase" the fight moved to phase x, "hook" a fight script started the alert x's bar.
local function NoteInner(r, kind, m, x, t)
    local rel = (t or Clock()) - r.t0
    if kind == "bar" then
        local s = x and r.plan.byKey[x.key]
        local list = s and r.g[s.i]
        if not list then return end
        if #list > 0 and rel - r.lastG[s.i] < Math.DEBOUNCE then
            list[#list] = floor(rel * 10 + 0.5) / 10      -- (the latest restart is the one the bar runs from)
        else
            Append(r, list, rel)
        end
        r.lastG[s.i] = rel
    elseif kind == "phase" then
        if type(x) == "number" then
            if r.n >= MAX_EVENTS then Stop(r, "2,000 events") return end
            r.n = r.n + 1
            r.ph[#r.ph + 1] = { n = x, t = Round1(rel) }
        end
    elseif kind == "hook" then
        if x and x.key and r.plan.byKey[x.key] then
            r.hk = r.hk or {}
            r.hk[x.key] = true
        end
    end
end

local function Note(r, kind, m, x, t)
    if not r.on then return end
    local ok, err = pcall(NoteInner, r, kind, m, x, t)
    if not ok then Fail(r, err) end
end

-- A fight started (Core/BossMod.lua StartFight, after the alerts are set up): record it when it is a real pull.
function BL:Begin(m)
    if not (m and m.def and m.live) or m.demo or m.resumed or not m.enc then return end
    if not self:Enabled() then return end
    local def = m.def
    -- (a fight that "starts" as I come into the world started without me: its clock is not the pull's)
    if Clock() - enteredAt < 2 then
        Log("%s: not recorded (the fight started as I came in)", tostring(def.key))
        return
    end
    local p = Plan(def)
    local r = { on = true, m = m, def = def, plan = p, boss = def.key, t0 = m.t0 or Clock(), at = Util.Now(),
                leader = Leader(), n = 0, o = {}, g = {}, lastObs = {}, lastG = {}, pend = {}, ph = {}, u = {}, uBy = {},
                y = {}, yBy = {}, fired = {}, Note = Note }
    for i, s in ipairs(p.specs) do
        r.o[i] = {}
        r.lastObs[i], r.lastG[i], r.pend[i] = -99, -99, -99
        if s.mode == "cast" or s.mixed then r.g[i] = {} end
    end
    for k in pairs(p.checks) do r.fired[k] = 0 end
    r.num = #self:Pulls(def.key) + 1
    m.rec = r
    recs[#recs + 1] = r
    Listen()
    return r
end

-- The recording's line over the bars (asked every frame: no table made): the pull's number ("Recording pull 7"), its
-- boss, and how many unknown casts it noted (the developer sees that); nil when nothing is recorded.
function BL:Status()
    for _, r in ipairs(recs) do
        if r.on then return r.num, r.boss, #r.u end
    end
    return nil
end

local function ObsCount(rec)
    local n = 0
    for _, l in pairs(type(rec.o) == "table" and rec.o or {}) do n = n + #l end
    return n
end
BL.ObsCount = ObsCount

-- The recording as the pull record that is saved (and shared).
local function Freeze(r, dur, kill, clean)
    local rec = { id = r.boss .. "|" .. tostring(r.leader) .. "|" .. tostring(r.at), at = r.at, leader = r.leader,
                  dur = Round1(dur), kill = kill and true or false, clean = clean and true or false, ds = r.plan.ds,
                  av = ns.version, from = "me", src = 1, o = {}, g = {} }
    -- (a pull that is not clean keeps no times: it is never learned from, only kept for the developer to see)
    for i, s in ipairs(clean and r.plan.specs or {}) do
        if #r.o[i] > 0 then rec.o[s.key] = r.o[i] end
        if r.g[i] and #r.g[i] > 0 then rec.g[s.key] = r.g[i] end
    end
    if not next(rec.g) then rec.g = nil end
    if not clean then rec.n = r.n end
    if #r.ph > 0 then rec.ph = r.ph end
    local nf = {}
    for k, n in pairs(r.fired) do if n == 0 then nf[#nf + 1] = k end end
    tsort(nf)
    rec.nf = nf
    if #r.u > 0 then rec.u = r.u end
    if #r.y > 0 then rec.y = r.y end
    if r.hk then rec.hk = r.hk end
    if next(r.plan.ov) then rec.ov = {}; for k in pairs(r.plan.ov) do rec.ov[k] = true end end
    if r.stop then rec.stop = r.stop end
    rec.mine = ObsCount(rec)
    return rec
end

-- The fight ended (Core/BossMod.lua EndFight, first thing): the record is closed; the learning comes a frame later.
function BL:Finish(m)
    local r = m and m.rec
    if not r then return end
    m.rec = nil
    for i = #recs, 1, -1 do if recs[i] == r then tremove(recs, i) end end
    local wasOn = r.on and true or false
    r.on = false
    Listen()
    local dur = Clock() - r.t0
    if dur < Math.MIN_PULL then return end            -- (a wipe on the pull, a reset: not counted, not kept)
    local clean = wasOn and m.ended == "encounter" and not r.stop
    local rec = Freeze(r, dur, m.kill, clean)
    local before = m.lw or {}
    -- (after the pull, and guarded: a fault in storing or learning is logged, never thrown)
    local function after()
        local ok, err = pcall(BL.AfterPull, BL, r.boss, rec, before)
        if not ok then Log("%s: after the pull: %s", tostring(r.boss), tostring(err)) end
    end
    if C_Timer and C_Timer.After then C_Timer.After(0, after) else after() end
    return rec
end

---------------------------------------------------------------------------
-- Storing pulls
---------------------------------------------------------------------------

local function MergeLists(a, b)
    local out = {}
    for k, l in pairs(type(a) == "table" and a or {}) do out[k] = l end
    for k, l in pairs(type(b) == "table" and b or {}) do
        out[k] = Math.Union(out[k], l, MERGE_TOL)
        while #out[k] > MAX_OBS_ALERT * 2 do tremove(out[k]) end
    end
    return out
end

-- b's observations into a (the same pull seen by two of us).
local function Merge(a, b)
    a.src = (tonumber(a.src) or 1) + 1
    -- (a recording that stopped adds nothing to a clean record: not its times, its silent alerts or its casts)
    if not b.clean then return end
    if not a.clean then
        -- (mine stopped, a guildmate's is whole: theirs is the record now)
        a.o, a.g, a.ph, a.nf, a.u, a.y, a.hk, a.clean = {}, nil, nil, nil, nil, nil, nil, true
    end
    a.o = MergeLists(a.o, b.o)
    a.g = MergeLists(a.g, b.g)
    if next(a.g) == nil then a.g = nil end
    local ph = {}
    for _, p in ipairs(type(a.ph) == "table" and a.ph or {}) do ph[#ph + 1] = p end
    for _, p in ipairs(type(b.ph) == "table" and b.ph or {}) do
        local near = false
        for _, q in ipairs(ph) do if q.n == p.n and abs(q.t - p.t) <= 2 then near = true break end end
        if not near and #ph < 30 then ph[#ph + 1] = { n = p.n, t = p.t } end
    end
    tsort(ph, function(p, q) return p.t < q.t end)
    a.ph = #ph > 0 and ph or nil
    if type(a.nf) == "table" and type(b.nf) == "table" then
        local inB, nf = {}, {}
        for _, k in ipairs(b.nf) do inB[k] = true end
        for _, k in ipairs(a.nf) do if inB[k] then nf[#nf + 1] = k end end
        a.nf = nf
    elseif type(b.nf) == "table" then
        a.nf = b.nf
    end
    local byId = {}
    a.u = type(a.u) == "table" and a.u or {}
    for _, u in ipairs(a.u) do byId[u.id] = u end
    for _, u in ipairs(type(b.u) == "table" and b.u or {}) do
        local x = byId[u.id]
        if x then
            x.n = max(x.n or 0, u.n or 0)
            if u.t and (not x.t or u.t < x.t) then x.t = u.t end
            x.name = x.name or u.name
        elseif #a.u < MAX_UNK then
            a.u[#a.u + 1] = { id = u.id, n = u.n, t = u.t, name = u.name }
        end
    end
    if #a.u == 0 then a.u = nil end
    local byText = {}
    a.y = type(a.y) == "table" and a.y or {}
    for _, y in ipairs(a.y) do byText[y.text] = y end
    for _, y in ipairs(type(b.y) == "table" and b.y or {}) do
        local x = byText[y.text]
        if x then
            x.n = max(x.n or 0, y.n or 0)
        elseif #a.y < MAX_YELL then
            a.y[#a.y + 1] = { t = y.t, n = y.n, text = y.text, kind = y.kind }
        end
    end
    if #a.y == 0 then a.y = nil end
    if type(b.hk) == "table" then a.hk = a.hk or {}; for k in pairs(b.hk) do a.hk[k] = true end end
    a.dur = max(tonumber(a.dur) or 0, tonumber(b.dur) or 0)
    a.kill = (a.kill or b.kill) and true or false
    if b.from == "me" then a.mine, a.from = b.mine, "me" end
end
BL.Merge = Merge

local function Total(db)
    local n = 0
    for _, l in pairs(db.pulls) do if type(l) == "table" then n = n + #l end end
    return n
end

-- The stored record of the same pull as rec (same boss and leader, within SAME_PULL s), or nil.
local function Match(boss, rec)
    local list = Store().pulls[boss]
    for _, x in ipairs(type(list) == "table" and list or {}) do
        if x.leader == rec.leader and abs((tonumber(x.at) or 0) - (tonumber(rec.at) or 0)) <= SAME_PULL then
            return x
        end
    end
    return nil
end

-- How far b's clock runs from a's on the same pull: the median gap from each of b's times to a's nearest one of the
-- same alert (within 3 s), and how many pairs that took. Observers of one pull agree within their latency.
local function Offset(a, b)
    local gaps = {}
    for key, l in pairs(type(b.o) == "table" and b.o or {}) do
        local mine = type(a.o) == "table" and a.o[key]
        if type(mine) == "table" then
            for _, t in ipairs(l) do
                local best
                for _, u in ipairs(mine) do
                    if abs(t - u) <= 3 and (not best or abs(t - u) < abs(best)) then best = t - u end
                end
                if best then gaps[#gaps + 1] = best end
            end
        end
    end
    tsort(gaps)
    return Math.Median(gaps) or 0, #gaps
end
BL.Offset = Offset

-- Keeps a pull (or merges it into the record of the same pull). Returns the stored record and whether it was merged.
function BL:AddPull(boss, rec)
    local db = Store()
    local list = db.pulls[boss]
    if type(list) ~= "table" then list = {}; db.pulls[boss] = list end
    local x = Match(boss, rec)
    if x then
        Merge(x, rec)
        return x, true
    end
    list[#list + 1] = rec
    tsort(list, function(p, q) return (tonumber(p.at) or 0) < (tonumber(q.at) or 0) end)
    while #list > CAP_BOSS do tremove(list, 1) end
    -- (all bosses together: the oldest pull anywhere goes)
    local total = Total(db)
    while total > CAP_ALL do
        local oldK, oldAt
        for k, l in pairs(db.pulls) do
            if type(l) == "table" and l[1] and (not oldAt or (tonumber(l[1].at) or 0) < oldAt) then
                oldK, oldAt = k, tonumber(l[1].at) or 0
            end
        end
        if not oldK then break end
        tremove(db.pulls[oldK], 1)
        if #db.pulls[oldK] == 0 then db.pulls[oldK] = nil end
        total = total - 1
    end
    return rec, false
end

---------------------------------------------------------------------------
-- Learning (never during a pull: after the end, and for what the guild sent once out of the fight)
---------------------------------------------------------------------------

function BL:Relearn(boss)
    local bm = BM()
    local def = bm and bm:Mod(boss)
    if not def then return nil end
    local p = Plan(def)
    local db = Store()
    local alerts, used = Math.LearnBoss(def, db.pulls[boss], p.ds)
    db.learned[boss] = { ds = p.ds, at = Util.Now(), pulls = used, alerts = alerts }
    if self:IsDev() then self:Review(boss) end
    ns:Fire("BOSSLEARN_CHANGED", boss)
    return db.learned[boss]
end

function BL:RelearnAll()
    local db = Store()
    local keys = {}
    for boss in pairs(db.pulls) do keys[#keys + 1] = boss end
    tsort(keys)
    for _, boss in ipairs(keys) do self:Relearn(boss) end
end

local function ValidWindow(lo, hi, src)
    if type(lo) ~= "number" or type(hi) ~= "number" or lo <= 0 or hi < lo or hi > 3600 then return false end
    if src and (lo < Math.CLAMP_LO * src[1] - 1e-6 or hi > Math.CLAMP_HI * src[2] + 1e-6) then return false end
    return true
end

-- The learned numbers a fight starts with (Core/BossMod.lua StartFight; the fight keeps its own copy, so nothing
-- learned later reaches it): { [alert key] = { start = n | { lo, hi }, cd = ... } } or nil.
function BL:Snapshot(def)
    if not (def and def.key) or not self:Enabled() then return nil end
    local L = Store().learned[def.key]
    if type(L) ~= "table" or type(L.alerts) ~= "table" then return nil end
    local p = Plan(def)
    if L.ds ~= p.ds then return nil end
    local out
    for _, s in ipairs(p.specs) do
        local e = L.alerts[s.key]
        if type(e) == "table" and not s.fixed then
            for _, f in ipairs({ "start", "cd" }) do
                local w = e[f]
                if s[f] and type(w) == "table" and w.applied and ValidWindow(w.lo, w.hi, s[f]) then
                    out = out or {}
                    out[s.key] = out[s.key] or {}
                    out[s.key][f] = (w.lo == w.hi) and w.lo or { w.lo, w.hi }
                end
            end
        end
    end
    return out
end

-- The applied windows of a boss now (to compare with what a pull started with).
local function Applied(boss)
    local L = Store().learned[boss]
    local out = {}
    for key, e in pairs(type(L) == "table" and type(L.alerts) == "table" and L.alerts or {}) do
        for _, f in ipairs({ "start", "cd" }) do
            local w = e[f]
            if type(w) == "table" and w.applied then
                out[key] = out[key] or {}
                out[key][f] = (w.lo == w.hi) and w.lo or { w.lo, w.hi }
            end
        end
    end
    return out
end

local function Same(a, b)
    if type(a) == "number" and type(b) == "number" then return a == b end
    if type(a) == "table" and type(b) == "table" then return a[1] == b[1] and a[2] == b[2] end
    return a == nil and b == nil
end

-- What changed for a boss since `before` (a fight's snapshot): { { key, field, from = window | nil (the data's),
-- to = window | nil (back to the data's) } }.
function BL:Changes(boss, before)
    local now = Applied(boss)
    local out = {}
    local bm = BM()
    local def = bm and bm:Mod(boss)
    for _, a in ipairs(def and def.alerts or {}) do
        for _, f in ipairs({ "start", "cd" }) do
            local was = before and before[a.key] and before[a.key][f]
            local is = now[a.key] and now[a.key][f]
            -- (only what a bar really runs on: newly learned as the data says is no change)
            if (was or is) and not Same(was, is) and not Same(was or a[f], is or a[f]) then
                out[#out + 1] = { key = a.key, field = f, from = was, to = is, src = a[f] }
            end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- After a pull
---------------------------------------------------------------------------

-- Runs fn later, guarded: anything learning does after a pull logs its faults instead of throwing them.
local function Later(sec, fn)
    local function run()
        local ok, err = pcall(fn)
        if not ok then Log("later: %s", tostring(err)) end
    end
    if C_Timer and C_Timer.After then C_Timer.After(sec, run) else run() end
end

function BL:AfterPull(boss, rec, before)
    local stored = self:AddPull(boss, rec)
    self:Relearn(boss)
    if rec.clean and rec.from == "me" then
        local wait = SEND_MIN + (Util.Jitter and Util.Jitter(rec.id, SEND_SPREAD) or 0)
        Later(wait, function() BL:SendPull(boss, stored) end)
    end
    local tries = 0
    local function report()
        if InFight() and tries < 24 then
            tries = tries + 1
            Later(5, report)
            return
        end
        BL:Report(boss, before)
    end
    Later(REPORT_AFTER, report)
end

-- The "what we learned" note after a pull: ns message BOSSLEARN_REPORT (the screen side posts it).
function BL:Report(boss, before)
    local changes = self:Changes(boss, before)
    local review = {}
    if self:IsDev() then review = self:Suggestions(boss) end
    if #changes == 0 and #review == 0 then return nil end
    local info = { boss = boss, changes = changes, review = review, pulls = #self:Pulls(boss) }
    ns:Fire("BOSSLEARN_REPORT", info)
    return info
end

---------------------------------------------------------------------------
-- Sharing with the guild
---------------------------------------------------------------------------

local heard = {}                  -- [stored pull id] = the most observations a guildmate's summary of it had
local inbox = {}                  -- summaries that came during a fight: handled after it
BL.heard, BL.inbox = heard, inbox

local function Deltas(list)
    local out, last = {}, 0
    for _, t in ipairs(list) do
        local x = floor(t * 10 + 0.5)
        out[#out + 1] = x - last
        last = x
    end
    return out
end

-- The pull as a guild message: times in tenths of a second, each list as steps from the one before.
function BL:Summary(boss, rec)
    local msg = { t = MSG, v = Math.FORMAT, av = tostring(ns.version or "0"), b = boss, ds = rec.ds, at = rec.at,
                  l = rec.leader, d = floor((tonumber(rec.dur) or 0) * 10 + 0.5), k = rec.kill and 1 or 0, o = {} }
    local ov = type(rec.ov) == "table" and rec.ov or {}
    for key, l in pairs(type(rec.o) == "table" and rec.o or {}) do if not ov[key] then msg.o[key] = Deltas(l) end end
    for key, l in pairs(type(rec.g) == "table" and rec.g or {}) do
        if not ov[key] then msg.g = msg.g or {}; msg.g[key] = Deltas(l) end
    end
    if type(rec.ph) == "table" and #rec.ph > 0 then
        msg.ph = {}
        for _, p in ipairs(rec.ph) do msg.ph[#msg.ph + 1] = p.n; msg.ph[#msg.ph + 1] = floor(p.t * 10 + 0.5) end
    end
    if type(rec.nf) == "table" then msg.nf = rec.nf end
    if type(rec.u) == "table" and #rec.u > 0 then
        msg.u = {}
        for _, u in ipairs(rec.u) do
            msg.u[#msg.u + 1] = u.id; msg.u[#msg.u + 1] = u.n; msg.u[#msg.u + 1] = floor((u.t or 0) * 10 + 0.5)
        end
    end
    if type(rec.y) == "table" and #rec.y > 0 then
        msg.y = {}
        for _, y in ipairs(rec.y) do
            msg.y[#msg.y + 1] = floor((y.t or 0) * 10 + 0.5); msg.y[#msg.y + 1] = y.n; msg.y[#msg.y + 1] = y.text
        end
    end
    if type(rec.hk) == "table" and next(rec.hk) then
        msg.hk = {}
        for k in pairs(rec.hk) do msg.hk[#msg.hk + 1] = k end
        tsort(msg.hk)
    end
    return msg
end

function BL:SendPull(boss, rec, tries)
    tries = tries or 0
    if not (rec and rec.clean and rec.from == "me") or rec.sent then return false end
    if not self:Sharing() or not (IsInGuild and IsInGuild()) then return false end
    if InFight() or not Util.RateLimit("bosslearn:send", 2) then
        if tries < 24 then Later(5, function() BL:SendPull(boss, rec, tries + 1) end) end
        return false
    end
    if (heard[rec.id] or -1) >= (tonumber(rec.mine) or ObsCount(rec)) then
        rec.sent = "heard"
        return false
    end
    local Comm = ns.Comm
    if not (Comm and Comm.Send) then return false end
    local ok = Comm:Send(self:Summary(boss, rec), "GUILD", nil, CLASS)
    if ok then rec.sent = true end
    return ok
end

-- Undoes Deltas, checking every step: nil when anything is not a whole number >= 0 or the total passes `limit`.
local function Undelta(l, limit, cap)
    if type(l) ~= "table" or #l > cap then return nil end
    local out, x = {}, 0
    for i = 1, #l do
        local d = l[i]
        if not Util.IsInt(d, 0, 36000) then return nil end
        x = x + d
        if x > limit then return nil end
        out[i] = x / 10
    end
    for k in pairs(l) do if type(k) ~= "number" or k < 1 or k > #l then return nil end end
    return out
end

local function KnownKeys(def)
    local p = Plan(def)
    local keys = {}
    for _, s in ipairs(p.specs) do keys[s.key] = s end
    return keys
end

-- A guild summary checked field by field; the pull record it makes, or nil and why. Anything odd drops it whole.
function BL:Validate(msg)
    if type(msg) ~= "table" then return nil, "not a table" end
    if msg.v ~= Math.FORMAT then return nil, "format " .. tostring(msg.v) end
    if type(msg.av) ~= "string" or #msg.av > 20 or Util.CompareVersions(msg.av, MIN_ADDON) < 0 then
        return nil, "version " .. tostring(msg.av)
    end
    local bm = BM()
    local def = type(msg.b) == "string" and bm and bm:Mod(msg.b)
    if not def then return nil, "boss " .. tostring(msg.b) end
    if msg.ds ~= Plan(def).ds then return nil, "data signature" end
    local now = Util.Now()
    if not Util.IsInt(msg.at, now - 30 * 86400, now + 86400) then return nil, "time" end
    if type(msg.l) ~= "string" or msg.l == "" or #msg.l > 64 or msg.l:find("[%c|]") then return nil, "leader" end
    if not Util.IsInt(msg.d, Math.MIN_PULL * 10, 36000) then return nil, "duration" end
    if msg.k ~= 0 and msg.k ~= 1 then return nil, "kill" end
    local d = msg.d
    local keys = KnownKeys(def)
    local rec = { id = msg.b .. "|" .. msg.l .. "|" .. msg.at, at = msg.at, leader = msg.l, dur = d / 10,
                  kill = msg.k == 1, clean = true, ds = msg.ds, av = msg.av, src = 1, o = {} }
    local total, obs = 0, 0
    if type(msg.o) ~= "table" then return nil, "observations" end
    for key, l in pairs(msg.o) do
        if type(key) ~= "string" or not keys[key] then return nil, "alert " .. tostring(key) end
        local t = Undelta(l, d, MAX_OBS_ALERT)
        if not t then return nil, "times of " .. key end
        total, obs = total + #t, obs + #t
        if #t > 0 then rec.o[key] = t end
    end
    if msg.g ~= nil then
        if type(msg.g) ~= "table" then return nil, "bar starts" end
        rec.g = {}
        for key, l in pairs(msg.g) do
            local s = type(key) == "string" and keys[key]
            if not s or not (s.mode == "cast" or s.mixed) then return nil, "bar starts of " .. tostring(key) end
            local t = Undelta(l, d, MAX_OBS_ALERT)
            if not t then return nil, "bar starts of " .. key end
            total = total + #t
            if #t > 0 then rec.g[key] = t end
        end
    end
    if total > MAX_EVENTS then return nil, "too many" end
    if msg.ph ~= nil then
        local ph = msg.ph
        if type(ph) ~= "table" or #ph % 2 ~= 0 or #ph > 60 then return nil, "phases" end
        rec.ph = {}
        for i = 1, #ph, 2 do
            if not Util.IsInt(ph[i], 1, 20) or not Util.IsInt(ph[i + 1], 0, d) then return nil, "phases" end
            rec.ph[#rec.ph + 1] = { n = ph[i], t = ph[i + 1] / 10 }
        end
    end
    if msg.nf ~= nil then
        if type(msg.nf) ~= "table" or #msg.nf > 60 then return nil, "never fired" end
        local alertKeys = {}
        for _, a in ipairs(def.alerts or {}) do alertKeys[a.key] = true end
        rec.nf = {}
        for _, k in ipairs(msg.nf) do
            if type(k) ~= "string" or not alertKeys[k] then return nil, "never fired" end
            rec.nf[#rec.nf + 1] = k
        end
    end
    if msg.u ~= nil then
        local u = msg.u
        if type(u) ~= "table" or #u % 3 ~= 0 or #u > MAX_UNK * 3 then return nil, "casts" end
        rec.u = {}
        for i = 1, #u, 3 do
            if not Util.IsInt(u[i], 1, 2147483647) or not Util.IsInt(u[i + 1], 1, 100000)
                or not Util.IsInt(u[i + 2], 0, d) then return nil, "casts" end
            rec.u[#rec.u + 1] = { id = u[i], n = u[i + 1], t = u[i + 2] / 10 }
        end
    end
    if msg.y ~= nil then
        local y = msg.y
        if type(y) ~= "table" or #y % 3 ~= 0 or #y > MAX_YELL * 3 then return nil, "yells" end
        rec.y = {}
        for i = 1, #y, 3 do
            local text = y[i + 2]
            if not Util.IsInt(y[i], 0, d) or not Util.IsInt(y[i + 1], 1, 100000) or type(text) ~= "string"
                or #text > YELL_LEN or text:find("[%z\1-\31|]") then return nil, "yells" end
            rec.y[#rec.y + 1] = { t = y[i] / 10, n = y[i + 1], text = text }
        end
    end
    if msg.hk ~= nil then
        if type(msg.hk) ~= "table" or #msg.hk > 60 then return nil, "scripts" end
        rec.hk = {}
        for _, k in ipairs(msg.hk) do
            if type(k) ~= "string" or not keys[k] then return nil, "scripts" end
            rec.hk[k] = true
        end
    end
    return rec, nil, obs
end

-- A guild summary came (or waited out a fight): stored and learned from.
function BL:Accept(sender, msg)
    local rec, why, total = self:Validate(msg)
    if not rec then
        Log("dropped a pull from %s: %s", tostring(sender), tostring(why))
        return false, why
    end
    rec.from = sender
    -- (the same pull timed from another start: someone who came in mid-pull, a client that lagged at the pull)
    local same = Match(msg.b, rec)
    if same and same.clean then
        local off, n = Offset(same, rec)
        if n >= 3 and abs(off) > MERGE_TOL then
            Log("dropped a pull from %s: its clock is %.1f s off ours", tostring(sender), off)
            return false, "clock"
        end
    end
    local stored = self:AddPull(msg.b, rec)
    heard[stored.id] = max(heard[stored.id] or -1, total or 0)
    return true, msg.b
end

local draining = false
local function Drain()
    draining = false
    if #inbox == 0 then return end
    if InFight() then
        draining = true
        Later(5, Drain)
        return
    end
    local touched = {}
    while #inbox > 0 do
        local e = tremove(inbox, 1)
        -- (one odd summary is dropped and logged; the rest still count)
        local ran, ok, boss = pcall(BL.Accept, BL, e[1], e[2])
        if not ran then Log("dropped a pull from %s: %s", tostring(e[1]), tostring(ok))
        elseif ok then touched[boss] = true end
    end
    for boss in pairs(touched) do
        local ran, err = pcall(BL.Relearn, BL, boss)
        if not ran then Log("%s: relearning: %s", tostring(boss), tostring(err)) end
    end
end
BL.Drain = Drain

function BL:OnMessage(sender, msg, distribution)
    if distribution ~= "GUILD" or not self:Sharing() then return end
    if #inbox >= MAX_INBOX then return end
    inbox[#inbox + 1] = { sender, msg }
    if not draining then
        draining = true
        Later(InFight() and 5 or 0, Drain)
    end
end

---------------------------------------------------------------------------
-- The developer's review
---------------------------------------------------------------------------

local function SpellName(id)
    if type(id) ~= "number" or not GetSpellInfo then return nil end
    local n = GetSpellInfo(id)
    return type(n) == "string" and n or nil
end
BL.SpellName = SpellName

-- The combat-log ids an alert's own triggers name: { [id] = true }, the first one.
local function TriggerIds(a)
    local ids, first = {}, nil
    for _, t in ipairs(Math.Triggers(a.on)) do
        local word, list = Math.Ids(t)
        if word and Math.SUBWORD[word] then
            for _, id in ipairs(list) do ids[id] = true; first = first or id end
        end
    end
    return ids, first
end

-- Works out the review of a boss (developer only): stored in review.suggest[boss] and returned.
function BL:Review(boss)
    local bm = BM()
    local def = bm and bm:Mod(boss)
    if not def or not self:IsDev() then return {} end
    local db = Store()
    local p = Plan(def)
    local pulls = db.pulls[boss]
    local dec = type(db.review.decisions[boss]) == "table" and db.review.decisions[boss] or {}
    local never = Math.NeverFired(pulls, p.ds, 2)
    local unk = Math.Unknown(pulls, p.ds)
    local out, taken = {}, {}
    for _, a in ipairs(def.alerts or {}) do
        local n = never[a.key]
        local ids, first = TriggerIds(a)
        if n and first then
            local names = {}
            for id in pairs(ids) do local nm = SpellName(id); if nm then names[strlower(nm)] = true end end
            local own = SpellName(a.spell)
            if own then names[strlower(own)] = true end
            for _, u in ipairs(unk) do
                local nm = u.name or SpellName(u.id)
                if nm and names[strlower(nm)] and not ids[u.id] then
                    local key = "spell:" .. a.key
                    taken[u.id] = true
                    if not dec[key] then
                        out[#out + 1] = { kind = "spell", key = key, alert = a.key, from = first, use = u.id, name = nm,
                                          pulls = n, seen = u.pulls }
                    end
                    break
                end
            end
        end
    end
    local usable = 0
    for _, rec in ipairs(type(pulls) == "table" and pulls or {}) do if Math.Usable(rec, p.ds) then usable = usable + 1 end end
    local casts = 0
    for _, u in ipairs(unk) do
        if casts >= 5 then break end
        if not taken[u.id] and u.pulls >= 2 and u.pulls * 2 >= usable and not dec["cast:" .. u.id] then
            casts = casts + 1
            out[#out + 1] = { kind = "cast", key = "cast:" .. u.id, id = u.id, name = u.name or SpellName(u.id),
                              pulls = u.pulls, n = u.n }
        end
    end
    local lines = 0
    for _, y in ipairs(Math.Yells(pulls, p.ds)) do
        if lines >= 3 then break end
        if y.pulls >= 2 and not dec["yell:" .. y.text] then
            lines = lines + 1
            out[#out + 1] = { kind = "yell", key = "yell:" .. y.text, text = y.text, pulls = y.pulls }
        end
    end
    db.review.suggest[boss] = #out > 0 and out or nil
    db.review.never = type(db.review.never) == "table" and db.review.never or {}
    db.review.never[boss] = next(never) and never or nil
    return out
end

-- The developer's open suggestions for a boss (nothing for anyone else).
function BL:Suggestions(boss)
    if not self:IsDev() then return {} end
    local s = Store().review.suggest[boss]
    return type(s) == "table" and s or {}
end

-- Alerts that never fired in the stored pulls ({ [key] = pulls }), for the developer's page.
function BL:NeverFired(boss)
    if not self:IsDev() then return {} end
    local n = Store().review.never
    return type(n) == "table" and type(n[boss]) == "table" and n[boss] or {}
end

-- A "Use <id>" fix: the alert's triggers for the old id also listen to the new one (this client only). Applied at
-- login and after a decision, never during a fight.
local applied = {}
function BL:ApplyFixes()
    if not self:IsDev() or InFight() then return false end
    local bm = BM()
    local changed = false
    for boss, dec in pairs(Store().review.decisions) do
        local def = bm and bm:Mod(boss)
        for _, d in pairs(type(dec) == "table" and dec or {}) do
            local a = def and type(d) == "table" and type(d.use) == "number" and def.byKey[d.alert]
            local tag = boss .. ":" .. tostring(d.alert) .. ":" .. tostring(d.use)
            if a and type(d.from) == "number" and not applied[tag] then
                applied[tag] = true
                for _, map in pairs(def._t.cleu) do
                    local l = map[d.from]
                    for _, e in ipairs(type(l) == "table" and l or {}) do
                        if e.a == a then
                            map[d.use] = map[d.use] or {}
                            local have = false
                            for _, x in ipairs(map[d.use]) do if x == e then have = true end end
                            if not have then map[d.use][#map[d.use] + 1] = e; changed = true end
                        end
                    end
                end
            end
        end
    end
    if changed then aliasGen = aliasGen + 1 end
    return changed
end

-- The developer decides on a suggestion: "use" (the new id, this client) or "ignore". Saved in review.decisions.
function BL:Decide(boss, key, how)
    if not self:IsDev() then return false end
    local sug
    for _, s in ipairs(self:Suggestions(boss)) do if s.key == key then sug = s break end end
    if not sug or (how ~= "use" and how ~= "ignore") or (how == "use" and sug.kind ~= "spell") then return false end
    local db = Store()
    db.review.decisions[boss] = type(db.review.decisions[boss]) == "table" and db.review.decisions[boss] or {}
    local d = { at = Util.Now(), by = Util.PlayerKey() }
    if how == "use" then
        d.use, d.from, d.alert, d.name = sug.use, sug.from, sug.alert, sug.name
    else
        d.ignore, d.what = true, sug.name or sug.text
    end
    db.review.decisions[boss][key] = d
    if how == "use" then
        if InFight() then
            local function later() if InFight() then Later(5, later) else BL:ApplyFixes() end end
            Later(5, later)
        else
            self:ApplyFixes()
        end
    end
    self:Review(boss)
    ns:Fire("BOSSLEARN_CHANGED", boss)
    return true
end

---------------------------------------------------------------------------
-- For the screens: a boss's state and its rows
---------------------------------------------------------------------------

-- { pulls = stored, usable = clean ones that count, learned = applied fields, fixes = (developer) open suggestions,
--   state = "learned" | "learning" | nil (never pulled) }
function BL:BossStatus(boss)
    local bm = BM()
    local def = bm and bm:Mod(boss)
    local pulls = self:Pulls(boss)
    local out = { pulls = #pulls, usable = 0, learned = 0, fixes = #self:Suggestions(boss) }
    if not def or #pulls == 0 then return out end
    local p = Plan(def)
    for _, rec in ipairs(pulls) do if Math.Usable(rec, p.ds) then out.usable = out.usable + 1 end end
    local L = Store().learned[boss]
    for _, e in pairs(type(L) == "table" and L.ds == p.ds and type(L.alerts) == "table" and L.alerts or {}) do
        for _, f in ipairs({ "start", "cd" }) do
            if type(e[f]) == "table" and e[f].applied then out.learned = out.learned + 1 end
        end
    end
    out.state = out.learned > 0 and "learned" or "learning"
    out.last = pulls[#pulls] and pulls[#pulls].at
    return out
end

-- The learned entry of one alert's field (start | cd), or nil.
function BL:Fit(boss, key, field)
    local L = Store().learned[boss]
    local e = type(L) == "table" and type(L.alerts) == "table" and L.alerts[key]
    return type(e) == "table" and e[field] or nil
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function BL:OnLogin()
    Store()
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register(MSG, function(sender, msg, distribution) BL:OnMessage(sender, msg, distribution) end)
    end
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() if #inbox > 0 then Drain() end end)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function() enteredAt = Clock() end)
    -- (what is stored is worked out again once after login: the data may be newer than the last time)
    Later(3, function()
        if InFight() then return end
        BL:ApplyFixes()
        BL:RelearnAll()
    end)
end

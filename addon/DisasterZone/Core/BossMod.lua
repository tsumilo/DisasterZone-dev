if DisasterZoneBoot and DisasterZoneBoot.Run("Core/BossMod.lua", ...) then return end -- DisasterZone Core/BossMod.lua
-- Boss mods (ns.BossMod): timer bars, warnings and the range frame for the TBC raid bosses, from the data files in
-- Data/BossMods/<Raid>.lua (format: dev/docs/bossmods/DATA_FORMAT.md in the dev kit). The screen side is
-- UI/BossModUI.lua; this file runs the fights and hands it bars (BossMod:Bars), warnings (BOSSMOD_WARN), the
-- range frame (BossMod:Range) and the pull countdown (BossMod:Countdown).
-- Off by default: Settings > Combat > Boss mods (bossmods.on). Nothing is read while it is off, and while it is on
-- the combat log is only read during a boss fight (Core/CombatLog.lua's shared reader).
--   a fight    starts on ENCOUNTER_START (the data's encounter ids); a boss with `engage` triggers (the Opera's three
--              plays, Hyjal's waves) waits for one of them. Ends on ENCOUNTER_END, or when it can't have: 5 s out of
--              the raid it started in (a wipe while I was released, whose ENCOUNTER_END I never got), or the boss's
--              next ENCOUNTER_START. After a /reload mid-pull it picks the boss up again from its unit (no first
--              timers then: they come back with the next casts).
--   alerts     each data alert is one Settings switch (bossmods.off.<boss>.<key>); tank and healer alerts show only
--              for that role unless "Alerts for other roles" is on (bossmods.roles); my role: bossmods.role
--              ("auto": the raid's main tank flag, else my talents; Feral by form).
--   windows    a timer the sources disagree on is { min, max }: the bar counts to min, then says "any moment" up to max.
--   pull       the game's own countdown (C_PartyInfo.DoCountdown / START_PLAYER_COUNTDOWN): DBM and BigWigs use it
--              too, so one /pull reaches everyone. /dz pull 10, /dz pull 0 cancels.
--   break      DBM's and BigWigs' break messages, read and sent (D5 "BT", BigWigs "P^Break"): /dz break 5 (minutes).
-- Pull and break timers you send work with boss mods off; you see them only with boss mods on.
-- Learning (Core/BossLearn.lua): a fight starts with what was learned from our pulls (m.lw, a copy taken at its start:
-- nothing changes it during the pull; the engine's own start / cd bars use it), and tells the recorder of bar starts,
-- phase changes and bars a fight script started (Note: inside a pcall, never in the alerts' way).
local addonName, ns = ...

local BM = ns:NewModule("BossMod")

local floor, max, min = math.floor, math.max, math.min
local pairs, ipairs, type, tonumber, tostring, select, next = pairs, ipairs, type, tonumber, tostring, select, next
local strsplit, strlower, strfind, gsub = strsplit, string.lower, string.find, string.gsub

local DBM_PREFIX, BW_PREFIX = "D5", "BigWigs"
local GRACE = 1.5                 -- s a window bar stays after its max before it goes
local WARN_THROTTLE = 2
local BREAK_MAX = 3600
local BACK_GAP = 20               -- s without a sign of a creature before BACK <npc> fires on its next one
local OUT_END = 5                 -- s out of the raid a fight started in before it ends
local RESTART = 10                -- s: an ENCOUNTER_START this long into a fight of the same boss is its next pull

local function Now() return GetTime() end
local function Get(path, default)
    local v = ns.DB and ns.DB:GetSetting("bossmods." .. path)
    if v == nil then return default end
    return v
end
BM.Get = Get
local function Set(path, v) if ns.DB then ns.DB:SetSetting("bossmods." .. path, v) end end

---------------------------------------------------------------------------
-- The data: compiled once (triggers -> lookup tables)
---------------------------------------------------------------------------

local SUB = {
    CAST = { "SPELL_CAST_START" }, SUCCESS = { "SPELL_CAST_SUCCESS" },
    AURA = { "SPELL_AURA_APPLIED", "SPELL_AURA_APPLIED_DOSE" }, AURAGONE = { "SPELL_AURA_REMOVED" },
    SUMMON = { "SPELL_SUMMON" }, HIT = { "SPELL_DAMAGE", "SPELL_MISSED" }, HEAL = { "SPELL_HEAL" },
}
BM.SUB = SUB

local mods = {}                   -- [boss key] = def (compiled)
local byEnc = {}                  -- [encounter id] = { def, ... }
local byNpc = {}                  -- [creature id] = def (the boss itself: the reload pickup)
local list = {}                   -- defs in load order
local compiled = false

local function Triggers(v)
    if v == nil then return {} end
    if type(v) == "string" then return { v } end
    return v
end

-- The trigger words keyed by one id each (DIES <npc>, WIDGET <id>, UCAST <spell>, SPAWN <npc>, BACK <npc>): their table.
local BYID = { DIES = "dies", WIDGET = "widget", UCAST = "ucast", SPAWN = "spawn", BACK = "back" }

-- Adds entry e (fields: a = alert, f = "on" | "stop" | "engage", hook = fn) under the trigger string t.
local function AddTrigger(def, t, e)
    local word, rest = t:match("^(%u+)%s*(.*)$")
    if not word then return end
    local T = def._t
    if SUB[word] then
        for id in rest:gmatch("%d+") do
            id = tonumber(id)
            for _, sub in ipairs(SUB[word]) do
                T.cleu[sub] = T.cleu[sub] or {}
                local l = T.cleu[sub][id] or {}
                T.cleu[sub][id] = l
                l[#l + 1] = e
            end
        end
    elseif BYID[word] then
        local map = T[BYID[word]]
        for id in rest:gmatch("%d+") do
            id = tonumber(id)
            map[id] = map[id] or {}
            local l = map[id]
            l[#l + 1] = e
        end
    elseif word == "HP" then
        local pct, npc = rest:match("^(%d+)%s*(%d*)$")
        e.pct, e.npc = tonumber(pct), tonumber(npc) or (def.npc and def.npc[1])
        T.hp[#T.hp + 1] = e
    elseif word == "YELL" or word == "EMOTE" then
        e.text = strlower(rest)
        local l = word == "YELL" and T.yell or T.emote
        l[#l + 1] = e
    elseif word == "ENGAGE" then
        T.engage[#T.engage + 1] = e
    elseif word == "PHASE" then
        local n = tonumber(rest)
        if n then
            T.phase[n] = T.phase[n] or {}
            local l = T.phase[n]
            l[#l + 1] = e
        end
    end
end

local function Compile(key, def)
    def.key = key
    def._t = { cleu = {}, dies = {}, hp = {}, yell = {}, emote = {}, engage = {}, phase = {}, widget = {}, ucast = {},
               spawn = {}, back = {} }
    def._e = { cleu = {}, dies = {}, hp = {}, yell = {}, emote = {}, engage = {}, phase = {}, widget = {}, ucast = {},
               spawn = {}, back = {} }   -- (its own engage)
    def.byKey = {}
    for _, a in ipairs(def.alerts or {}) do
        def.byKey[a.key] = a
        if type(a.phase) == "number" then a._ph = { [a.phase] = true }
        elseif type(a.phase) == "table" then a._ph = {}; for _, p in ipairs(a.phase) do a._ph[p] = true end end
        if a.src then a._src = {}; for _, s in ipairs(a.src) do a._src[s] = true end end
        for _, t in ipairs(Triggers(a.on)) do AddTrigger(def, t, { a = a, f = "on" }) end
        for _, t in ipairs(Triggers(a.stop)) do AddTrigger(def, t, { a = a, f = "stop" }) end
    end
    if type(def.fn) == "table" then
        for t, fn in pairs(def.fn) do
            if type(fn) == "function" then AddTrigger(def, t, { hook = fn, f = "hook" }) end
        end
    end
    if def.engage then
        local real = def._t
        def._t = def._e
        for _, t in ipairs(Triggers(def.engage)) do AddTrigger(def, t, { f = "engage" }) end
        def._t = real
    end
    for _, id in ipairs(def.enc or {}) do
        byEnc[id] = byEnc[id] or {}
        local l = byEnc[id]
        l[#l + 1] = def
    end
    if def.npc and def.npc[1] then byNpc[def.npc[1]] = byNpc[def.npc[1]] or def end
    mods[key] = def
    list[#list + 1] = def
end

function BM:Compile()
    if compiled then return end
    compiled = true
    local data = ns.Data and ns.Data.BossMods or {}
    local keys = {}
    for k in pairs(data) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do Compile(k, data[k]) end
    -- (encounter ids Data/Items.lua knows that the data files didn't list)
    if ns.Data and ns.Data.Raids then
        for _, raid in ipairs(ns.Data.Raids) do
            for _, b in ipairs(raid.bosses or {}) do
                local d = mods[raid.key .. ":" .. b.key]
                if d and b.encounterID and not byEnc[b.encounterID] then byEnc[b.encounterID] = { d } end
                if d then d.name = d.name or b.name end
            end
        end
    end
end

function BM:Mod(key) self:Compile(); return mods[key] end
function BM:Mods() self:Compile(); return list end

---------------------------------------------------------------------------
-- Settings, my role
---------------------------------------------------------------------------

function BM:IsOn() return Get("on", false) and true or false end
function BM:AlertOn(bossKey, key) return not Get("off." .. bossKey .. "." .. key, false) end
function BM:SetAlertOn(bossKey, key, on) Set("off." .. bossKey .. "." .. key, (not on) and true or nil) end

local roleCache, roleAt = nil, 0
function BM:MyRole()
    local r = Get("role", "auto")
    if r == "tank" or r == "healer" or r == "dps" then return r end
    local t = Now()
    if roleCache and t - roleAt < 5 then return roleCache end
    roleAt = t
    if ns.Tanks and ns.Tanks:IsMe() then
        roleCache = "tank"
        return roleCache
    end
    local cls = ns.ClassKit and ns.ClassKit:MyClass()
    local tab = ns.ClassKit and ns.ClassKit:MyTab()
    roleCache = "dps"
    if cls and tab and ns.SPECS and ns.SPECS[cls] then
        local roles = {}
        for _, s in ipairs(ns.SPECS[cls]) do if s.tab == tab then roles[#roles + 1] = s.role end end
        if #roles == 1 then
            roleCache = roles[1] == "tank" and "tank" or roles[1] == "healer" and "healer" or "dps"
        elseif #roles > 1 then    -- (Feral: bear form tanks)
            local form = GetShapeshiftFormID and GetShapeshiftFormID()
            roleCache = (form == 5 or form == 8) and "tank" or "dps"
        end
    end
    return roleCache
end

-- True when alert a should reach me (its switch, my role).
function BM:Shown(def, a)
    if not self:AlertOn(def.key, a.key) then return false end
    if a.role and not Get("roles", false) and not self.preview then
        local r = self:MyRole()
        if a.role == "T" and r ~= "tank" then return false end
        if a.role == "H" and r ~= "healer" then return false end
    end
    return true
end

---------------------------------------------------------------------------
-- Fights
---------------------------------------------------------------------------

local active = {}                 -- the running fights (a boss, and Hyjal's waves beside it)
local armed = {}                  -- defs waiting for their own engage trigger: { def, enc = id }
local bars = {}                   -- every bar: fights' and the pull / break timers
local ranges = {}                 -- open range frames: { m, a, untilT }
local countEnd = nil              -- the pull countdown's end (GetTime)
local ev = {}                     -- the event handed to alerts and hooks (reused)
local playerGUID
BM.active, BM.armed = active, armed

local M = {}                      -- the fight object's methods (data hooks call them)
-- (m.t: seconds since the pull, read like a field)
M.__index = function(m, k)
    if k == "t" then return GetTime() - (rawget(m, "t0") or GetTime()) end
    return M[k]
end

local function NpcOf(guid)
    if type(guid) ~= "string" then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
    return nil
end
BM.NpcOf = NpcOf

local function SpellName(id)
    if not id then return nil end
    local n = GetSpellInfo and GetSpellInfo(id)
    return n
end
local function SpellIcon(id)
    if not id then return nil end
    if GetSpellTexture then
        local t = GetSpellTexture(id)
        if t then return t end
    end
    local _, _, icon = GetSpellInfo and GetSpellInfo(id)
    return icon
end
BM.SpellIcon = SpellIcon

local function ShortName(n)
    if type(n) ~= "string" then return "" end
    return (n:gsub("%-.*$", ""))
end

-- An alert's text with %s (spell), %n (count), %t (target).
local function Format(m, a, s, e)
    s = s or a.text or SpellName(a.spell) or a.key
    if not strfind(s, "%", 1, true) then return s end
    local n = m and m.counts[a.key] or 0
    if a.count == "next" then n = ((e and e.amount) or n) + 1
    elseif a.count == "stack" then n = (e and e.amount) or 1 end
    s = gsub(s, "%%s", function() return SpellName(a.spell) or "" end)
    s = gsub(s, "%%n", tostring(n))
    s = gsub(s, "%%t", function() return ShortName(e and e.dstName) end)
    s = gsub(s, "%%p", tostring(m and m.phase or 1))
    return s
end
BM.Format = Format

local function PhaseOK(m, a) return not a._ph or a._ph[m.phase] or false end

-- Learning (Core/BossLearn.lua): the recorder hears of bar starts, phase changes and bars a fight script started. It
-- never changes the fight: its own pcall, and it stops itself for the rest of the pull on any error.
local function Note(m, kind, x)
    local r = m.rec
    if r and r.on and r.Note then pcall(r.Note, r, kind, m, x, Now()) end
end

-- The learned numbers a fight starts with (BossLearn's snapshot at the pull: a copy that nothing changes until the
-- next pull), or nil = the data's.
local function Learned(def)
    local L = ns.BossLearn
    if not (L and L.Snapshot) then return nil end
    local ok, lw = pcall(L.Snapshot, L, def)
    return ok and type(lw) == "table" and lw or nil
end

-- Bars
local function Window(secs)
    if type(secs) == "table" then return secs[1], secs[2] end
    return secs, secs
end

function M:Bar(key, secs, text)
    local a = self.def.byKey[key]
    if not a then return end
    secs = secs or a.cd or a.start
    if not secs then return end
    local lo, hi = Window(secs)
    local t = Now()
    local b = bars[self.id .. key]
    if not b then
        b = { id = self.id .. key }
        bars[b.id] = b
    end
    b.m, b.a, b.key, b.boss = self, a, key, self.def.key
    b.t0, b.lo, b.hi = t, t + lo, t + hi
    b.text = text or Format(self, a, nil, self.lastEv)
    b.icon = SpellIcon(a.icon or a.spell)
    b.role = a.role
    b.kind, b.learned = nil, nil
    if self.inHook then Note(self, "hook", a) end
    ns:Fire("BOSSMOD_BARS")
end

-- A bar the engine itself (re)starts from the data's `start` or `cd`: the fight's learned number when it has one.
local function EngineBar(m, a, f)
    local lw = m.lw and m.lw[a.key]
    local v = lw and lw[f]
    m:Bar(a.key, v or a[f])
    if v then
        local b = bars[m.id .. a.key]
        if b then b.learned = true end
    end
end

function M:Stop(key)
    if bars[self.id .. key] then
        bars[self.id .. key] = nil
        ns:Fire("BOSSMOD_BARS")
    end
end

function M:Warn(key, text, sub, asYou)
    local a = self.def.byKey[key]
    if not a or not BM:Shown(self.def, a) or not Get("warns", true) then return end
    local e = self.lastEv
    local kind = a.kind == "range" and "warn" or a.kind
    if asYou then kind = "you" end
    ns:Fire("BOSSMOD_WARN", { kind = kind, text = text or Format(self, a, nil, e), sub = sub or (a.sub and Format(self, a, a.sub, e)),
                              icon = SpellIcon(a.icon or a.spell), key = key, boss = self.def.key, t = Now() })
end

function M:Range(key, open)
    local a = self.def.byKey[key]
    if not a then return end
    local id = self.id .. key
    if open then
        ranges[id] = ranges[id] or { m = self, a = a, at = Now() }
        ranges[id].untilT = a.dur and (Now() + a.dur) or nil
    elseif ranges[id] then
        local r = ranges[id]
        if a.after and a.after > 0 then r.untilT = Now() + a.after else ranges[id] = nil end
    end
    ns:Fire("BOSSMOD_RANGE")
end

function M:Count(key) return self.counts[key] or 0 end

function M:Phase(n)
    if self.phase == n then return end
    self.phase = n
    Note(self, "phase", n)
    for _, a in ipairs(self.def.alerts or {}) do
        if a._ph and not a._ph[n] then
            if a.kind == "bar" then self:Stop(a.key) end
            if a.kind == "range" then ranges[self.id .. a.key] = nil end
        end
        if a.start and a._ph and a._ph[n] and a.kind == "bar" and not self.resumed then EngineBar(self, a, "start") end
    end
    BM:Dispatch(self, self.def._t.phase[n], nil)
end

function M:End() BM:EndFight(self) end

-- One trigger entry fired.
local function Fire(m, e, x)
    if e.f == "hook" then
        m.lastEv = x
        m.inHook = true
        local ok, err = pcall(e.hook, m, x or ev)
        m.inHook = nil
        if not ok and ns.Debug then ns:Debug("boss mod hook %s: %s", m.def.key, tostring(err)) end
        return
    end
    local a = e.a
    if not a or not PhaseOK(m, a) then return end
    if x then
        if a._src and not (x.srcNpc and a._src[x.srcNpc]) then return end
        if a.me and not x.me then return end
    end
    if e.f == "stop" then
        if a.kind == "bar" then m:Stop(a.key) elseif a.kind == "range" then m:Range(a.key, false) end
        return
    end
    local t = Now()
    if a.once and m.once[a.key] then return end
    local th = a.throttle or (a.kind ~= "bar" and WARN_THROTTLE or 0)
    if th > 0 and t - (m.last[a.key] or -99) < th then return end
    m.last[a.key], m.once[a.key] = t, true
    m.counts[a.key] = (m.counts[a.key] or 0) + 1
    m.lastEv = x
    if a.kind == "bar" then
        if a.cd then
            EngineBar(m, a, "cd")
            Note(m, "bar", a)
        end
    elseif a.kind == "range" then
        m:Range(a.key, true)
    else
        local asYou = x and x.me and a.meText ~= nil
        local text = asYou and Format(m, a, a.meText, x) or nil
        if a.delay and a.delay > 0 and C_Timer then
            C_Timer.After(a.delay, function() if m.live then m:Warn(a.key, text, nil, asYou) end end)
        else
            m:Warn(a.key, text, nil, asYou)
        end
    end
    if a.setPhase then m:Phase(a.setPhase) end
end

function BM:Dispatch(m, l, x)
    if not l then return end
    for i = 1, #l do Fire(m, l[i], x) end
end

local seq = 0
local guidNpc, castSeen = {}, {}  -- (while fights run: creature id per GUID, unit casts already taken by their GUID)

function BM:StartFight(def, opts)
    opts = opts or {}
    for i = #active, 1, -1 do
        local m = active[i]
        if m.def == def then
            -- (the boss's next ENCOUNTER_START while its last pull still runs: that pull ended without me hearing it)
            if not (opts.enc and m.enc and not m.demo and Now() - m.t0 >= RESTART) then return m end
            self:EndFight(m)
        end
    end
    seq = seq + 1
    local m = setmetatable({ def = def, id = "f" .. seq .. ":", t0 = opts.t0 or Now(), phase = 1, counts = {}, last = {},
                             once = {}, hpDone = {}, live = true, resumed = opts.resumed, demo = opts.demo,
                             enc = opts.enc, spawned = {}, seenAt = {},
                             inside = (IsInInstance and IsInInstance()) and true or nil }, M)
    active[#active + 1] = m
    if not m.demo then m.lw = Learned(def) end
    for _, a in ipairs(def.alerts or {}) do
        if a.kind == "bar" and a.start and PhaseOK(m, a) and not m.resumed then EngineBar(m, a, "start") end
    end
    self:Dispatch(m, def._t.engage, nil)
    self:Listen()
    local L = ns.BossLearn
    if L and L.Begin and not m.demo then pcall(L.Begin, L, m) end
    ns:Fire("BOSSMOD_FIGHT", def.key, true)
    return m
end

function BM:EndFight(m)
    if not m or not m.live then return end
    local L = ns.BossLearn
    if m.rec and L and L.Finish then pcall(L.Finish, L, m) end
    m.live = false
    for i = #active, 1, -1 do if active[i] == m then table.remove(active, i) end end
    for id, b in pairs(bars) do if b.m == m then bars[id] = nil end end
    for id, r in pairs(ranges) do if r.m == m then ranges[id] = nil end end
    if #active == 0 then guidNpc, castSeen = {}, {} end
    self:Listen()
    ns:Fire("BOSSMOD_BARS")
    ns:Fire("BOSSMOD_RANGE")
    ns:Fire("BOSSMOD_FIGHT", m.def.key, false)
end

function BM:EndAll()
    for i = #active, 1, -1 do self:EndFight(active[i]) end
    for i = #armed, 1, -1 do armed[i] = nil end
    self:Listen()
end

function BM:Active() return active[1] end
function BM:Fights() return active end

---------------------------------------------------------------------------
-- Events in: the combat log, health, yells, encounters
---------------------------------------------------------------------------

local function Each(fn)
    for i = #active, 1, -1 do local m = active[i]; if m then fn(m, m.def._t) end end
end

local function Creature(m, l, guid, name, npc)
    ev.spell, ev.src, ev.srcName, ev.srcNpc, ev.dst, ev.dstName, ev.me, ev.amount, ev.npc, ev.text =
        nil, guid, name, npc, nil, nil, false, nil, npc, nil
    BM:Dispatch(m, l, ev)
end

-- SPAWN <npc>: a creature of that id in the combat log for the first time (each one, by its GUID: the Lurker's adds
-- coming up). BACK <npc>: one again after BACK_GAP s without any sign of it (the Lurker emerging). Read only while a
-- running fight has such a trigger.
local watchNpcs = false
local function Seen(guid, name)
    if not guid then return end
    local npc = guidNpc[guid]
    if npc == nil then npc = NpcOf(guid) or false; guidNpc[guid] = npc end
    if not npc then return end
    local t = Now()
    for i = #active, 1, -1 do
        local m = active[i]
        local T = m and m.def._t
        if T and T.spawn[npc] and not m.spawned[guid] then
            m.spawned[guid] = true
            Creature(m, T.spawn[npc], guid, name, npc)
        end
        if T and T.back[npc] then
            local last = m.seenAt[npc]
            m.seenAt[npc] = t
            if last and t - last >= BACK_GAP then Creature(m, T.back[npc], guid, name, npc) end
        end
    end
end

local function OnLog(_, _, sub, _, srcGUID, srcName, _, _, dstGUID, dstName, _, _, spellId, _, _, a15, a16)
    if watchNpcs then
        Seen(srcGUID, srcName)
        Seen(dstGUID, dstName)
    end
    if sub == "UNIT_DIED" then
        local npc = NpcOf(dstGUID)
        if not npc then return end
        ev.spell, ev.src, ev.srcName, ev.srcNpc, ev.dst, ev.dstName, ev.me, ev.amount, ev.npc, ev.text =
            nil, nil, nil, nil, dstGUID, dstName, false, nil, npc, nil
        Each(function(m, T) BM:Dispatch(m, T.dies[npc], ev) end)
        for i = #armed, 1, -1 do local d = armed[i]; if d and d.def._e.dies[npc] then BM:Engage(d) end end
        return
    end
    local ids = nil
    -- (a quick look before building the event: is any running or waiting boss listening to this sub-event and spell?)
    for i = 1, #active do
        local c = active[i].def._t.cleu[sub]
        if c and c[spellId] then ids = true break end
    end
    if not ids then
        for i = 1, #armed do
            local c = armed[i].def._e.cleu[sub]
            if c and c[spellId] then ids = true break end
        end
    end
    if not ids then return end
    playerGUID = playerGUID or (UnitGUID and UnitGUID("player"))
    ev.spell, ev.src, ev.srcName, ev.srcNpc, ev.dst, ev.dstName = spellId, srcGUID, srcName, NpcOf(srcGUID), dstGUID, dstName
    ev.me = dstGUID ~= nil and dstGUID == playerGUID
    ev.amount = (sub == "SPELL_AURA_APPLIED_DOSE") and tonumber(a16) or nil
    ev.npc, ev.text = ev.srcNpc, nil
    Each(function(m, T) local c = T.cleu[sub]; BM:Dispatch(m, c and c[spellId], ev) end)
    for i = #armed, 1, -1 do
        local d = armed[i]
        local c = d and d.def._e.cleu[sub]
        if c and c[spellId] then BM:Engage(d) end
    end
end
BM.OnLog = OnLog

local UNITS = { "boss1", "boss2", "boss3", "boss4", "boss5", "target", "focus", "mouseover" }
local function CheckHealth(unit)
    if #active == 0 then return end
    local npc = NpcOf(UnitGUID and UnitGUID(unit))
    if not npc then return end
    local hmax = UnitHealthMax(unit) or 0
    if hmax <= 0 then return end
    local pct = (UnitHealth(unit) or 0) / hmax * 100
    for _, m in ipairs(active) do
        for i, e in ipairs(m.def._t.hp) do
            if not m.hpDone[i] and e.npc == npc and pct <= e.pct then
                m.hpDone[i] = true
                ev.spell, ev.src, ev.srcName, ev.srcNpc, ev.dst, ev.dstName, ev.me, ev.amount, ev.npc, ev.text =
                    nil, nil, nil, npc, nil, nil, false, nil, npc, nil
                Fire(m, e, ev)
            end
        end
    end
end
BM.CheckHealth = CheckHealth
BM.UNITS = UNITS

-- UCAST <spell>: UNIT_SPELLCAST_SUCCEEDED of a creature I can see as a unit (boss frames, target, focus, mouseover,
-- nameplates): casts the combat log never shows, like the Lurker's Submerge Visual. One cast seen through two units
-- (boss1 and my target) counts once.
local UCAST_UNIT = {}
for _, u in ipairs(UNITS) do UCAST_UNIT[u] = true end
local function OnUnitCast(_, unit, castGUID, spellId)
    if type(unit) ~= "string" or not (UCAST_UNIT[unit] or strfind(unit, "^nameplate")) then return end
    local guid = UnitGUID and UnitGUID(unit)
    local npc = NpcOf(guid)
    if not npc then return end
    if castGUID then
        if castSeen[castGUID] then return end
        castSeen[castGUID] = true
    end
    ev.spell, ev.src, ev.srcName, ev.srcNpc, ev.dst, ev.dstName, ev.me, ev.amount, ev.npc, ev.text =
        spellId, guid, UnitName and UnitName(unit), npc, nil, nil, false, nil, npc, nil
    Each(function(m, T) BM:Dispatch(m, T.ucast[spellId], ev) end)
end
BM.OnUnitCast = OnUnitCast

local function OnChat(kind, text, target)
    if type(text) ~= "string" then return end
    local low = strlower(text)
    if type(target) ~= "string" or target == "" then target = nil end
    ev.spell, ev.src, ev.srcName, ev.srcNpc, ev.dst, ev.dstName, ev.me, ev.amount, ev.npc, ev.text =
        nil, nil, nil, nil, nil, target, target ~= nil and ShortName(target) == (UnitName and UnitName("player")), nil, nil, text
    Each(function(m, T)
        for _, e in ipairs(T[kind]) do
            if strfind(low, e.text, 1, true) then Fire(m, e, ev) end
        end
    end)
    for i = #armed, 1, -1 do
        local d = armed[i]
        for _, e in ipairs(d and d.def._e[kind] or {}) do
            if strfind(low, e.text, 1, true) then BM:Engage(d) break end
        end
    end
end
BM.OnChat = OnChat

-- An armed boss's own engage trigger fired: its fight starts (the other plays of an Opera evening stand down).
function BM:Engage(d)
    for i = #armed, 1, -1 do
        if armed[i] == d or (d.enc and armed[i].enc == d.enc) then table.remove(armed, i) end
    end
    return self:StartFight(d.def, { enc = d.enc })
end

-- Waiting bosses: armed on ENCOUNTER_START (a shared encounter id) or by zone (Hyjal's waves: no encounter at all).
local function Arm(def, enc)
    for _, d in ipairs(armed) do if d.def == def then return end end
    armed[#armed + 1] = { def = def, enc = enc }
end

local listening = {}
local function Want(event, fn, on)
    if on and not listening[event] then ns:RegisterEvent(event, fn); listening[event] = fn
    elseif not on and listening[event] then ns:UnregisterEvent(event, listening[event]); listening[event] = nil end
end

local function OnHealth(_, unit) CheckHealth(unit) end

-- WIDGET <id>: a UI widget's text changed (Hyjal's wave counter): ev.spell = the widget, ev.amount = the first number
-- in its text, ev.text = the text. A waiting boss engages on it once the number is 1 or more.
local widgetText = {}
local function OnWidget(_, info)
    local id = type(info) == "table" and info.widgetID
    if not id then return end
    local any = false
    for _, m in ipairs(active) do if m.def._t.widget[id] then any = true break end end
    for _, d in ipairs(armed) do if d.def._e.widget[id] then any = true break end end
    if not any then return end
    local W = C_UIWidgetManager
    local vis = W and W.GetIconAndTextWidgetVisualizationInfo and W.GetIconAndTextWidgetVisualizationInfo(id)
    local text = vis and vis.text
    if type(text) ~= "string" or text == widgetText[id] then return end
    widgetText[id] = text
    local n = tonumber(text:match("(%d+)"))
    ev.spell, ev.src, ev.srcName, ev.srcNpc, ev.dst, ev.dstName, ev.me, ev.amount, ev.npc, ev.text =
        id, nil, nil, nil, nil, nil, false, n, nil, text
    Each(function(m, T) BM:Dispatch(m, T.widget[id], ev) end)
    if n and n >= 1 then
        for i = #armed, 1, -1 do
            local d = armed[i]
            if d and d.def._e.widget[id] then
                local m = BM:Engage(d)
                if m then BM:Dispatch(m, m.def._t.widget[id], ev) end
            end
        end
    end
end
BM.OnWidget = OnWidget
-- (CHAT_MSG_*: text, sender, language, channel, target)
local function OnYell(_, text, _, _, _, target) OnChat("yell", text, target) end
local function OnEmote(_, text, _, _, _, target) OnChat("emote", text, target) end

-- Reads what the running and waiting bosses need, and nothing while there are none.
function BM:Listen()
    local fight = #active > 0
    local any = fight or #armed > 0
    local demo = fight and active[1].demo and #active == 1
    local ucast, npcs = false, false
    for _, m in ipairs(active) do
        if not m.demo then
            local T = m.def._t
            ucast = ucast or next(T.ucast) ~= nil
            npcs = npcs or next(T.spawn) ~= nil or next(T.back) ~= nil
        end
    end
    watchNpcs = npcs
    if ns.CombatLog then ns.CombatLog:SetSubscribed("bossmods", OnLog, any and not demo) end
    Want("UNIT_SPELLCAST_SUCCEEDED", OnUnitCast, ucast)
    Want("UNIT_HEALTH", OnHealth, fight and not demo)
    Want("CHAT_MSG_MONSTER_YELL", OnYell, any and not demo)
    Want("CHAT_MSG_RAID_BOSS_EMOTE", OnEmote, any and not demo)
    Want("CHAT_MSG_MONSTER_EMOTE", OnEmote, any and not demo)
    Want("UPDATE_UI_WIDGET", OnWidget, any and not demo)
    self:Tick(fight or next(bars) ~= nil or countEnd ~= nil)
end

function BM:OnEncounterStart(id, name)
    if not self:IsOn() then return end
    self:Compile()
    local l = byEnc[tonumber(id) or -1]
    if not l and type(name) == "string" then
        for _, d in ipairs(list) do if d.name == name then l = { d } break end end
    end
    if not l then return end
    if #l == 1 and not l[1].engage then
        self:StartFight(l[1], { enc = id })
        return
    end
    for _, d in ipairs(l) do
        if d.engage then Arm(d, id) else self:StartFight(d, { enc = id }) end
    end
    self:Listen()
end

function BM:OnEncounterEnd(id, success)
    id = tonumber(id)
    for i = #active, 1, -1 do
        local m = active[i]
        if m.enc == nil or m.enc == id or not id then
            m.ended, m.kill = "encounter", tonumber(success) == 1
            if m.enc ~= nil or not m.def.engage then self:EndFight(m) end
        end
    end
    for i = #armed, 1, -1 do if armed[i].enc == id then table.remove(armed, i) end end
    self:Listen()
end

-- Waves and other zone-armed mods: a boss with `engage` and no encounter id waits whenever I'm in its raid.
function BM:ArmZone()
    if not self:IsOn() then return end
    self:Compile()
    local _, itype, _, _, _, _, _, instanceID = GetInstanceInfo()
    for _, d in ipairs(list) do
        if d.engage and not (d.enc and d.enc[1]) then
            local raid = d.key:match("^(%w+):")
            local meta = ns.Data and ns.Data.RaidMeta and ns.Data.RaidMeta[raid]
            if meta and meta.instanceID == instanceID and itype == "raid" then Arm(d, nil)
            else
                for i = #armed, 1, -1 do if armed[i].def == d then table.remove(armed, i) end end
                for _, m in ipairs(active) do if m.def == d then self:EndFight(m) break end end
            end
        end
    end
    self:Listen()
end

-- A /reload mid-pull: find the boss from its unit and pick the fight up (no first timers).
function BM:Resume()
    if not self:IsOn() or #active > 0 then return end
    if not (IsEncounterInProgress and IsEncounterInProgress()) then return end
    self:Compile()
    for _, u in ipairs(UNITS) do
        local d = byNpc[NpcOf(UnitGUID and UnitGUID(u)) or -1]
        if d and not d.engage then self:StartFight(d, { resumed = true }) return true end
    end
    if C_Timer and (self.resumeTries or 0) < 10 then
        self.resumeTries = (self.resumeTries or 0) + 1
        C_Timer.After(1, function() BM:Resume() end)
    end
end

---------------------------------------------------------------------------
-- What the screen draws
---------------------------------------------------------------------------

local out = {}
local function ByEnd(p, q)
    if p.lo ~= q.lo then return p.lo < q.lo end
    return p.id < q.id
end

-- A bar past its end goes; a looping one (an add that comes on its own timer) starts its next round.
function BM:Expire(id, b)
    bars[id] = nil
    local a = b.a
    if a and a.loop and a.cd and b.m and b.m.live then
        b.m:Bar(b.key, a.cd)
        -- (from the moment it ran out, not when the ticker saw it: a loop must not drift over the rounds)
        local nb, late = bars[id], Now() - b.hi
        if nb and late > 0 then nb.t0, nb.lo, nb.hi = nb.t0 - late, nb.lo - late, nb.hi - late end
    end
end

-- The bars to show now, soonest first: { text, icon, rem, total, win (s left of its window, nil = none), role,
-- kind (nil | "pull" | "break" | "wave"), key, boss }. Reused tables: read, don't keep.
function BM:Bars(t)
    t = t or Now()
    for i = #out, 1, -1 do out[i] = nil end
    if not (self:IsOn() or self.preview) or not Get("bars", true) then return out end
    for id, b in pairs(bars) do
        if t > b.hi + (b.hi > b.lo and GRACE or 0) then
            BM:Expire(id, b)
        elseif not b.a or (b.m and BM:Shown(b.m.def, b.a)) then
            out[#out + 1] = b
        end
    end
    table.sort(out, ByEnd)
    for _, b in ipairs(out) do
        b.rem = max(0, b.lo - t)
        b.total = max(0.001, b.lo - b.t0)
        b.win = (b.hi > b.lo and t >= b.lo) and max(0, b.hi - t) or nil
    end
    return out
end

-- The open range frames: { yd, text, at } (the dots come from UI/BossModUI.lua's measuring).
local rout = {}
function BM:Ranges(t)
    t = t or Now()
    for i = #rout, 1, -1 do rout[i] = nil end
    if not (self:IsOn() or self.preview) or Get("range", "auto") == "never" then return rout end
    for id, r in pairs(ranges) do
        if r.untilT and t > r.untilT then ranges[id] = nil
        elseif BM:Shown(r.m.def, r.a) then rout[#rout + 1] = r end
    end
    return rout
end

function BM:Countdown(t)
    if not countEnd then return nil end
    t = t or Now()
    if t >= countEnd then countEnd = nil return nil end
    return countEnd - t
end

-- A ticker while anything runs: drops spent bars, ends a fight the game forgot to end (no ENCOUNTER_END after a
-- wipe while released: a picked-up fight once no encounter is in progress, an encounter's once I have been out of
-- its raid OUT_END s), and lets the screen sleep when nothing is left.
local ticker
function BM:Tick(on)
    if on and not ticker and C_Timer and C_Timer.NewTicker then
        ticker = C_Timer.NewTicker(0.5, function() BM:OnTick() end)
    elseif not on and ticker then
        ticker:Cancel()
        ticker = nil
    end
end

function BM:OnTick()
    local t = Now()
    for id, b in pairs(bars) do
        if t > b.hi + (b.hi > b.lo and GRACE or 0) then
            BM:Expire(id, b)
            if b.kind == "break" and b.hi - b.t0 >= 30 then
                ns:Fire("BOSSMOD_WARN", { kind = "info", text = "Break is over", icon = b.icon, t = t })
            end
        end
    end
    if countEnd and t >= countEnd then countEnd = nil end
    local inside = IsInInstance and IsInInstance()
    for i = #active, 1, -1 do
        local m = active[i]
        if m and not m.demo then
            if m.enc and m.inside and not inside then
                m.outAt = m.outAt or t
                if t - m.outAt >= OUT_END then self:EndFight(m) end
            elseif not m.enc and not m.def.engage and not (IsEncounterInProgress and IsEncounterInProgress()) then
                self:EndFight(m)
            else
                m.outAt = nil
            end
        end
    end
    if #active == 0 and not next(bars) and not countEnd then self:Tick(false) end
end

---------------------------------------------------------------------------
-- Pull and break timers
---------------------------------------------------------------------------

local function UserBar(id, text, icon, secs, kind)
    if secs <= 0 then
        if bars[id] then bars[id] = nil; ns:Fire("BOSSMOD_BARS") end
        return
    end
    local t = Now()
    bars[id] = { id = id, key = id, text = text, icon = icon, t0 = t, lo = t + secs, hi = t + secs, kind = kind }
    ns:Fire("BOSSMOD_BARS")
    BM:Listen()
end
BM.UserBar = UserBar

local PULL_ICON, BREAK_ICON = 132337, 134062

local function SenderName(who)
    if type(who) ~= "string" or who == "" then return nil end
    if who:find("^Player%-") and GetPlayerInfoByGUID then
        local _, _, _, _, _, name = GetPlayerInfoByGUID(who)
        return name
    end
    return ShortName(who)
end

function BM:OnCountdown(...)
    local secs, who
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "number" and not secs then secs = v
        elseif type(v) == "string" and not who then who = v end
    end
    if not secs then return end
    local name = SenderName(who)
    if secs <= 0 then self:OnCountdownCancel() return end
    countEnd = Now() + secs
    UserBar("pull", name and ("Pull · " .. name) or "Pull", PULL_ICON, secs, "pull")
end

function BM:OnCountdownCancel()
    countEnd = nil
    UserBar("pull", "", nil, 0)
end

local lastBreak = {}
function BM:StartBreak(secs, who)
    secs = tonumber(secs) or 0
    if secs > BREAK_MAX then return end
    local key = who or "?"
    local t = Now()
    if secs > 0 and lastBreak[key] and t - lastBreak[key] < 2 then return end    -- (one sender, both formats)
    lastBreak[key] = t
    UserBar("break", who and ("Break · " .. ShortName(who)) or "Break", BREAK_ICON, secs, "break")
    if secs > 0 then
        local m = floor(secs / 60 + 0.5)
        ns:Fire("BOSSMOD_WARN", { kind = "info", text = m >= 1 and ("Break for " .. m .. (m == 1 and " minute" or " minutes")) or ("Break for " .. secs .. " s"),
                                  sub = who and ShortName(who) or nil, icon = BREAK_ICON, t = t })
    end
end

local function CanLead()
    if not (IsInGroup and IsInGroup()) then return true end
    return (UnitIsGroupLeader and UnitIsGroupLeader("player")) or (UnitIsGroupAssistant and UnitIsGroupAssistant("player")) or false
end
BM.CanLead = CanLead

local function SenderLeads(sender)
    if not (IsInGroup and IsInGroup()) then return true end
    local n = ShortName(sender)
    return (UnitIsGroupLeader and UnitIsGroupLeader(n)) or (UnitIsGroupAssistant and UnitIsGroupAssistant(n)) or false
end

local function GroupChannel()
    if IsInGroup and IsInGroup(2) then return "INSTANCE_CHAT" end
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    return nil
end

function BM:SendPull(secs)
    secs = tonumber(secs) or 10
    if not CanLead() then ns:Print("only the leader or an assist can start a pull timer.") return end
    if IsEncounterInProgress and IsEncounterInProgress() then ns:Print("not during a boss fight.") return end
    if secs > 0 and secs < 3 then secs = 3 end
    if C_PartyInfo and C_PartyInfo.DoCountdown then
        local ok = pcall(C_PartyInfo.DoCountdown, secs)
        if ok then return true end
    end
    -- (no game countdown on this client: show it here only)
    if secs > 0 then self:OnCountdown(secs, UnitName and UnitName("player")) else self:OnCountdownCancel() end
end

function BM:SendBreak(minutes)
    minutes = tonumber(minutes) or 5
    if minutes < 0 or minutes > 60 then ns:Print("a break is 1 to 60 minutes (0 ends it).") return end
    if not CanLead() then ns:Print("only the leader or an assist can start a break.") return end
    if IsEncounterInProgress and IsEncounterInProgress() then ns:Print("not during a boss fight.") return end
    local secs = floor(minutes * 60)
    local me = UnitName and UnitName("player") or "?"
    self:StartBreak(secs, me)
    local ch = GroupChannel()
    if ch and C_ChatInfo and C_ChatInfo.SendAddonMessage and Get("dbm", true) then
        local realm = (GetRealmName and GetRealmName() or ""):gsub("[%s%-]+", "")
        pcall(C_ChatInfo.SendAddonMessage, DBM_PREFIX, ("%s-%s\t1\tBT\t%d"):format(me, realm, secs), ch)
        pcall(C_ChatInfo.SendAddonMessage, BW_PREFIX, "P^Break^" .. secs, ch)
    end
    return true
end

function BM:OnAddonMessage(prefix, text, channel, sender)
    if not Get("dbm", true) or type(text) ~= "string" then return end
    if channel ~= "RAID" and channel ~= "PARTY" and channel ~= "INSTANCE_CHAT" then return end
    local me = UnitName and UnitName("player")
    if ShortName(sender) == me then return end
    if prefix == DBM_PREFIX then
        local _, _, sub, secs = strsplit("\t", text)
        if sub == "BT" and SenderLeads(sender) and not (IsEncounterInProgress and IsEncounterInProgress()) then
            self:StartBreak(secs, ShortName(sender))
        end
    elseif prefix == BW_PREFIX then
        local p, msg, secs = strsplit("^", text)
        if p == "P" and msg == "Break" and SenderLeads(sender) and not (IsEncounterInProgress and IsEncounterInProgress()) then
            self:StartBreak(secs, ShortName(sender))
        end
    end
end

---------------------------------------------------------------------------
-- Try it: a made-up Gruul pull through the real engine (UI/BossModUI.lua plays it; nothing is read or sent)
---------------------------------------------------------------------------

-- Fires a trigger on a running fight as if the game had sent it (Try it, the tests): the trigger's first id (an HP
-- trigger's number is the health it drops to). fields: me, dstName, amount, srcNpc, text.
function BM:Inject(m, trigger, fields)
    if not (m and m.live) or type(trigger) ~= "string" then return end
    local word, rest = trigger:match("^(%u+)%s*(.*)$")
    if not word then return end
    local id = tonumber(rest:match("%d+"))
    fields = fields or {}
    local me = fields.me and true or false
    ev.spell, ev.src, ev.srcName, ev.srcNpc, ev.dst, ev.dstName, ev.me, ev.amount, ev.npc, ev.text =
        id, nil, nil, fields.srcNpc or (m.def.npc and m.def.npc[1]), nil,
        fields.dstName or (me and UnitName and UnitName("player")) or nil, me, fields.amount, nil, fields.text
    ev.npc = ev.srcNpc
    local T = m.def._t
    if SUB[word] then
        for _, sub in ipairs(SUB[word]) do
            local c = T.cleu[sub]
            if c and c[id] then self:Dispatch(m, c[id], ev) break end
        end
    elseif word == "DIES" then
        ev.npc = id
        self:Dispatch(m, T.dies[id], ev)
    elseif word == "UCAST" then
        self:Dispatch(m, T.ucast[id], ev)
    elseif word == "SPAWN" or word == "BACK" then
        ev.spell, ev.srcNpc, ev.npc = nil, id, id
        self:Dispatch(m, T[BYID[word]][id], ev)
    elseif word == "WIDGET" then
        ev.amount = fields.amount or 3
        ev.text = fields.text or ("Wave " .. ev.amount .. " of 8")
        self:Dispatch(m, T.widget[id], ev)
    elseif word == "HP" then
        for i, e in ipairs(T.hp) do
            if not m.hpDone[i] and id and id <= e.pct then m.hpDone[i] = true; Fire(m, e, ev) end
        end
    elseif word == "YELL" or word == "EMOTE" then
        local low = strlower(rest)
        ev.text = fields.text or rest
        for _, e in ipairs(word == "YELL" and T.yell or T.emote) do
            if strfind(low, e.text, 1, true) then Fire(m, e, ev) end
        end
    elseif word == "PHASE" and id then
        m:Phase(id)
    end
end

---------------------------------------------------------------------------
-- Slash commands, events
---------------------------------------------------------------------------

ns:RegisterSlash("pull", function(rest)
    local s = tonumber((rest or ""):match("%-?%d+")) or 10
    BM:SendPull(s)
end, "pull timer for the raid (leader / assist): /dz pull 10, /dz pull 0 cancels")
ns:RegisterSlash("break", function(rest)
    local m = tonumber((rest or ""):match("%-?%d+%.?%d*")) or 5
    BM:SendBreak(m)
end, "break timer for the raid (leader / assist): /dz break 5 (minutes), /dz break 0 ends it")

function BM:OnLogin()
    self:Compile()
    playerGUID = UnitGUID and UnitGUID("player")
    ns:RegisterEvent("ENCOUNTER_START", function(_, id, name) BM:OnEncounterStart(id, name) end)
    ns:RegisterEvent("ENCOUNTER_END", function(_, id, _, _, _, success) BM:OnEncounterEnd(id, success) end)
    ns:RegisterEvent("START_PLAYER_COUNTDOWN", function(_, ...) BM:OnCountdown(...) end)
    ns:RegisterEvent("CANCEL_PLAYER_COUNTDOWN", function() BM:OnCountdownCancel() end)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function() BM:ArmZone(); BM:Resume() end)
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", function() BM:ArmZone() end)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(DBM_PREFIX)
        C_ChatInfo.RegisterAddonMessagePrefix(BW_PREFIX)
    end
    ns:RegisterEvent("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender)
        if prefix == DBM_PREFIX or prefix == BW_PREFIX then BM:OnAddonMessage(prefix, text, channel, sender) end
    end)
    ns:On("SETTINGS_CHANGED", function(path)
        if path == "bossmods.on" or path == "bossmods" then
            if not BM:IsOn() then BM:EndAll() else BM:ArmZone() end
        end
    end)
end

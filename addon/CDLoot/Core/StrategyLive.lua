-- CDLoot: Core/StrategyLive.lua
-- The strategy boards in the actual encounter (Addendum K, encounter helpers):
--   * which plan applies: the raid session's linked planned raid -> its strategy + names for the boss (else the
--     guild's only strategy of that boss, without names);
--   * "near the boss": this client sees one of the encounter's creatures (a nameplate, its target, the mouseover),
--     or the encounter starts;
--   * auto-marking (the raid leader's client only, setting + per strategy): the raid marks drawn as badges on the
--     board's portraits go on the matching mobs as their nameplates appear; the plan wins over other marks, per mob;
--   * tracked tables (block.tr), followed from each client's own combat log:
--       rot    interrupt rotation: the designated kickers in order, backups (block.bk rows) when a designated
--              kicker's interrupt won't be ready for the boss' next cast (its rhythm is learnt from its casts);
--              who used theirs (hit or miss), the target casting
--       md/bl  once per pull: Misdirection, Bloodlust / Heroism (done or not; Bloodlust's "When" countdown)
--       pi/iv  a cooldown on a target: Power Infusion, Innervate (ready / on cooldown)
--       curse  keep a curse up: the curse named in each row's target cell, on that row's boss
-- The reminder panel (UI/StrategyReminder.lua) draws GetCurrent(); every change fires STRATEGY_LIVE.
local addonName, ns = ...

local Live = ns:NewModule("StrategyLive")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, next = type, pairs, ipairs, tonumber, tostring, next
local floor, max, min = math.floor, math.max, math.min
local strsplit = strsplit or function(sep, s)
    local out = {}
    for part in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end
    return unpack(out)
end

local FADE_AFTER_END = 10          -- seconds the reminder stays after the encounter ended
local FORGET_AFTER = 15 * 60       -- a boss seen but not pulled is forgotten after this long
local REMARK_GAP = 1.5             -- seconds between two re-marks of the same mob (another addon fighting back)
local REMARK_MAX = 6               -- re-marks per mob per boss (then the other addon wins)
local TURN_TIMEOUT = 3             -- the rotation's current player has this long to kick a cast before it moves on
local MISS_DEDUPE = 1              -- a cast + a miss of the same kick within this many seconds count once
Live.PULL_WINDOW = 10              -- a pull-time job (Misdirection) not cast this long after the pull: "not cast"

local function S() return ns.Strategy end

---------------------------------------------------------------------------
-- Spells (matched by name: the combat log's spell ids differ per rank)
---------------------------------------------------------------------------

-- base spell id -> cooldown (seconds) per kind
local SPELLS = {
    rot = { [1766] = 10, [6552] = 10, [72] = 12, [8042] = 6, [2139] = 24, [19244] = 24, [16979] = 15, [28730] = 120 },
    md = { [34477] = 120 },
    bl = { [2825] = 600, [32182] = 600 },
    pi = { [10060] = 180 },
    iv = { [29166] = 360 },
    curse = { [1714] = 0, [702] = 0, [1490] = 0, [704] = 0, [603] = 0, [980] = 0, [17862] = 0 },
}
Live.SPELLS = SPELLS

-- Buffs that make a creature immune to one kind of interrupt: phys (Kick, Pummel, Shield Bash, Feral Charge
-- can't land), spell (Earth Shock, Counterspell, Spell Lock can't), all.
local IMMUNE = {
    [41450] = "phys", [1022] = "phys", [5599] = "phys", [10278] = "phys",       -- Blessing of Protection
    [41451] = "spell",                                                          -- Blessing of Spell Warding
    [642] = "all", [1020] = "all", [498] = "all", [5573] = "all",               -- Divine Shield / Protection
}
Live.IMMUNE = IMMUNE

-- The school of each interrupt (by base id): physical ones fail on a physically immune target, and the other way.
local INTERRUPT_SCHOOL = { [1766] = "phys", [6552] = "phys", [72] = "phys", [16979] = "phys",
                           [8042] = "spell", [2139] = "spell", [19244] = "spell", [28730] = "spell" }
local CLASS_SCHOOL = { ROGUE = "phys", WARRIOR = "phys", DRUID = "phys", SHAMAN = "spell", MAGE = "spell",
                       WARLOCK = "spell", PRIEST = "spell", PALADIN = "spell", HUNTER = "phys" }

local KIND_NAME = { rot = "Interrupt rotation", md = "Misdirection", bl = "Bloodlust / Heroism",
                    pi = "Power Infusion", iv = "Innervate", curse = "Curses (keep up)" }
Live.KIND_NAME = KIND_NAME
Live.KIND_ORDER = { "rot", "md", "bl", "pi", "iv", "curse" }

local spellNames      -- [kind] = { [lower name] = cooldown }
local function Names()
    if spellNames then return spellNames end
    spellNames = {}
    for kind, list in pairs(SPELLS) do
        spellNames[kind] = {}
        for id, cd in pairs(list) do
            local name = GetSpellInfo and GetSpellInfo(id)
            if type(name) == "string" then spellNames[kind][name:lower()] = cd end
        end
    end
    return spellNames
end

-- The kind(s) a spell name belongs to: cooldown or nil.
local function SpellIn(kind, name)
    if type(name) ~= "string" then return nil end
    return Names()[kind][name:lower()]
end

local schoolByName
-- The school of an interrupt by its name ("phys" | "spell" | nil).
local function InterruptSchool(name)
    if not schoolByName then
        schoolByName = {}
        for id, school in pairs(INTERRUPT_SCHOOL) do
            local n = GetSpellInfo and GetSpellInfo(id)
            if type(n) == "string" then schoolByName[n:lower()] = school end
        end
    end
    return type(name) == "string" and schoolByName[name:lower()] or nil
end

-- A condition string ("a:<id>" | "hp:<pct>") -> { kind = "aura", id } | { kind = "hp", v } | nil.
local function ParseCond(w)
    if type(w) ~= "string" then return nil end
    local id = w:match("^a:(%d+)$")
    if id then return { kind = "aura", id = tonumber(id) } end
    local v = w:match("^hp:(%d+)$")
    if v then return { kind = "hp", v = tonumber(v) } end
    return nil
end
Live.ParseCond = ParseCond

-- A short name for a condition: "BoP" for Blessing of Protection, "< 30%" for health.
function Live:CondShort(c)
    if not c then return nil end
    if c.kind == "hp" then return "< " .. c.v .. "%" end
    local name = GetSpellInfo and GetSpellInfo(c.id) or ("spell " .. c.id)
    local words = {}
    for w in tostring(name):gmatch("%S+") do words[#words + 1] = w end
    if #words >= 3 then
        local out = ""
        for _, w in ipairs(words) do out = out .. (w:lower() == "of" and "o" or w:sub(1, 1):upper()) end
        return out
    end
    return name
end

---------------------------------------------------------------------------
-- Creatures: npc id <-> boss, display id -> npc id
---------------------------------------------------------------------------

local npcBoss, dispNpc      -- [npcID] = bossRef; [bossRef] = { [displayID] = npcID }

local function BuildIndex()
    if npcBoss then return end
    npcBoss, dispNpc = {}, {}
    for ref, list in pairs(ns.Data and ns.Data.BossPortraits or {}) do
        dispNpc[ref] = {}
        for _, c in ipairs(list) do
            if c.id then
                npcBoss[c.id] = npcBoss[c.id] or ref
                if c.d then dispNpc[ref][c.d] = c.id end
            end
        end
    end
    local ItemDB = ns.ItemDB
    for _, raid in ipairs(ItemDB and ItemDB:GetRaids() or {}) do
        for _, b in ipairs(raid.bosses or {}) do
            for _, id in ipairs(b.npcIDs or {}) do npcBoss[id] = npcBoss[id] or (raid.key .. ":" .. b.key) end
        end
    end
end

-- The npc id of a creature GUID ("Creature-0-server-instance-zone-<npcID>-spawn"), or nil.
local function NpcOf(guid)
    if type(guid) ~= "string" then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
    return tonumber(id)
end
Live.NpcOf = NpcOf

function Live:BossOfNpc(npcID)
    BuildIndex()
    return npcBoss[npcID]
end

-- The npc id behind a portrait icon key of a boss' strategy ("boss:<displayID>").
local function NpcOfIcon(bossRef, key)
    BuildIndex()
    local d = type(key) == "string" and tonumber(key:match("^boss:(%d+)$"))
    if not d then return nil end
    local m = dispNpc[bossRef]
    if m and m[d] then return m[d] end
    for _, map in pairs(dispNpc) do
        if map[d] then return map[d] end
    end
    return nil
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local cur                  -- the current encounter context (see Build)
local debugOn = false
local generation = 0       -- bumps whenever cur is replaced (stale timers check it)

local function Debug(fmt, ...)
    if debugOn then ns:Print("|cff66ccff[strat]|r " .. fmt, ...) end
end

local function Changed()
    ns:Fire("STRATEGY_LIVE")
end

local function Setting(path, default)
    local DB = ns.DB
    local v = DB and DB.GetSetting and DB:GetSetting(path)
    if v == nil then return default end
    return v
end

local function Me() return Util.PlayerKey() end

-- A combat log unit name -> name key (players only).
local function KeyOf(guid, name)
    if type(guid) ~= "string" or not guid:find("^Player%-") or type(name) ~= "string" then return nil end
    return Util.NormalizeName(name)
end

-- The planned raid of the running raid session (nil without one).
local function SessionOcc()
    local GR = ns.GroupRules
    local s = GR and GR.GetSession and GR:GetSession()
    return s and s.rp or nil
end

---------------------------------------------------------------------------
-- Building the context of a boss
---------------------------------------------------------------------------

-- A row's cells: the player (first player column), a second player (the "Onto" column), the target cell.
local function RowInfo(k, row, a)
    local info = { row = row }
    local d = k.d and k.d[row] or {}
    for ci, col in ipairs(k.c) do
        if col.t == "p" then
            local key = a[S().SlotRef(k.id, row, ci)]
            if info.pcol == nil then
                info.pcol, info.player = ci, key
            elseif info.onto == nil then
                info.onto = key
            end
        elseif col.t == "g" and info.target == nil and type(d[ci]) == "table" then
            info.target = d[ci]
        elseif col.t == "x" and info.text == nil and type(d[ci]) == "string" then
            info.text = (d[ci]:gsub("\n", " "))
        end
    end
    local t = info.target
    if t then
        info.label = t.l
        if t.s then info.onto = info.onto or a[t.s] end
    end
    info.label = info.label or info.text
    return info
end

local function BuildTracker(bossRef, k, a)
    local kind = S().TrackKind(k)
    local tr = { id = k.id, name = k.n, kind = kind, icon = k.i, rows = {}, order = {}, backups = {}, cur = 1 }
    local bk = {}
    for _, row in ipairs(k.bk or {}) do bk[row] = true end
    for row = 1, k.r do
        local r = RowInfo(k, row, a)
        r.npc = r.target and NpcOfIcon(bossRef, r.target.i) or nil
        if kind == "curse" then
            -- the curse picked in the row's target cell (a spell id), else the one named in its label / text
            for _, id in ipairs(r.target and r.target.a or {}) do
                local name = not r.curse and GetSpellInfo and GetSpellInfo(id)
                if type(name) == "string" then r.curse, r.curseId = name:lower(), id end
            end
            if not r.curse then
                local lower = ((r.label or "") .. " " .. (r.text or "")):lower()
                for name in pairs(Names().curse) do
                    if lower:find(name, 1, true) then r.curse = name end
                end
            end
        end
        tr.rows[#tr.rows + 1] = r
        r.backup = (kind == "rot" and bk[row]) or nil
        -- the boss abilities this row is for (ids + names, as the combat log may give either)
        if r.target and r.target.a and kind ~= "curse" then
            r.spells = {}
            for _, id in ipairs(r.target.a) do
                r.spells[id] = true
                local name = GetSpellInfo and GetSpellInfo(id)
                if type(name) == "string" then r.spells[name:lower()] = true end
                tr.spells = tr.spells or {}
                tr.spells[id] = true
                if type(name) == "string" then tr.spells[name:lower()] = true end
                tr.abilityIds = tr.abilityIds or {}
                tr.abilityIds[#tr.abilityIds + 1] = id
            end
        end
        r.cond = r.target and ParseCond(r.target.w) or nil
        if r.player then
            if r.backup then tr.backups[#tr.backups + 1] = r else tr.order[#tr.order + 1] = r end
        end
    end
    -- the rotation's target: the first row's boss
    for _, r in ipairs(tr.rows) do
        if r.npc then tr.npc = tr.npc or r.npc end
    end
    -- a first rhythm before two casts were seen: DBM's cooldown of those abilities (Data/BossAbilities.lua)
    local known = ns.Data and ns.Data.BossAbilities and ns.Data.BossAbilities[bossRef]
    for _, c in ipairs(known and known.c or {}) do
        if c.cd and (not tr.spells or tr.spells[c.id]) and (c.int or tr.spells) then
            tr.seedCd = tr.seedCd and min(tr.seedCd, c.cd) or c.cd
        end
    end
    return tr
end

-- The marks of a strategy: { [npcID] = { mark, ... } } from the portraits with a raid mark badge (every page).
local function MarkPlan(s)
    local plan, used = {}, {}
    for _, p in ipairs(s and s.p or {}) do
        for _, e in ipairs(p.e or {}) do
            if e.t == "i" and e.rm then
                local npc = NpcOfIcon(s.b, e.i)
                if npc and not used[npc .. ":" .. e.rm] then
                    used[npc .. ":" .. e.rm] = true
                    plan[npc] = plan[npc] or {}
                    plan[npc][#plan[npc] + 1] = e.rm
                end
            end
        end
    end
    return plan
end

-- fixed = { s, a } builds from a given strategy + names (Practice) instead of the raid's plan.
local function Build(bossRef, fixed)
    local Str = S()
    if not Str then return nil end
    local occ = not fixed and SessionOcc() or nil
    local s, fill, a
    if fixed then
        s, a = fixed.s, fixed.a
    elseif occ then
        s, fill = Str:GetRaidStrategy(occ, bossRef)
    else
        s = Str:GetStrategies(bossRef)[1]
    end
    if not s then return nil end
    a = a or ((fill and fill.s == s.id) and Str:ValidAssignments(s, fill.a) or {})
    local c = {
        boss = bossRef, name = Str:GetBossName(bossRef), occ = occ, s = s, a = a, trackers = {},
        marks = MarkPlan(s), assigned = {}, owner = {}, remarks = {}, seenAt = GetTime(), engaged = false,
        auras = {}, hp = {},       -- [npcID] = { [spellID] = true } buffs on the boss creatures; [npcID] = health %
        fixed = fixed, practice = fixed and fixed.practice or nil,
    }
    for _, p in ipairs(s.p or {}) do
        for _, k in ipairs(p.k or {}) do
            if S().TrackKind(k) then c.trackers[#c.trackers + 1] = BuildTracker(bossRef, k, a) end
        end
    end
    return c
end

---------------------------------------------------------------------------
-- Reading (the reminder panel)
---------------------------------------------------------------------------

function Live:GetCurrent() return cur end

-- Am I the one who marks (the raid leader; the party leader in a party)?
function Live:IsMarker()
    if not IsInGroup() then return false end
    return UnitIsGroupLeader("player") and true or false
end

-- My slots in the current plan: { slot (from Strategy:GetSlots), ... }.
function Live:MySlots()
    if not cur then return {} end
    return S():GetPlayerSlots(cur.s, cur.a, Me())
end

-- Seconds until a kicker's interrupt is ready again (0 = ready).
local function CdLeft(r, now)
    if not r.last or not r.cd then return 0 end
    return max(0, r.last + r.cd - (now or GetTime()))
end
Live.CdLeft = CdLeft

-- The rotation target's next cast, in seconds from now: 0 while it casts, nil while its rhythm isn't known (fewer
-- than two casts seen). The rhythm is the average of its last gaps between casts.
function Live:NextCastIn(tr)
    if tr.castStart then return 0 end
    local t = tr.casts
    if t and #t == 1 and tr.seedCd then return max(0, t[1] + tr.seedCd - GetTime()) end
    if not t or #t < 2 then return nil end
    local n = min(#t - 1, 4)
    local sum = 0
    for i = #t - n + 1, #t do sum = sum + (t[i] - t[i - 1]) end
    return max(0, t[#t] + sum / n - GetTime())
end

-- The immunities on a creature now: { phys = true, spell = true } (all = both).
function Live:Immunities(npc)
    local out = {}
    for id in pairs(cur and npc and cur.auras[npc] or {}) do
        local kind = IMMUNE[id]
        if kind == "all" then out.phys, out.spell = true, true elseif kind then out[kind] = true end
    end
    return out
end

-- A curse row of a player for this aura (by name: the combat log's ids differ per rank).
local function CurseRow(who, spellName)
    if not cur or type(spellName) ~= "string" then return nil end
    local lower = spellName:lower()
    for _, tr in ipairs(cur.trackers) do
        if tr.kind == "curse" then
            for _, r in ipairs(tr.rows) do
                if r.player == who and r.curse == lower then return r end
            end
        end
    end
end

-- Does a row's condition hold now?
function Live:CondHolds(r, tr)
    local c = r.cond
    if not c or not cur then return c == nil end
    local npc = r.npc or tr.npc
    if c.kind == "aura" then
        if npc then return cur.auras[npc] ~= nil and cur.auras[npc][c.id] == true end
        for _, set in pairs(cur.auras) do
            if set[c.id] then return true end
        end
        return false
    end
    local hp = npc and cur.hp[npc]
    return hp ~= nil and hp <= c.v
end

-- The school of a kicker's interrupt: the one they used, else their class'.
local function School(r)
    if r.school then return r.school end
    local class = ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(r.player)
    if not class and r.player == Me() then class = select(2, UnitClass("player")) end
    return class and CLASS_SCHOOL[class] or nil
end
Live.School = School

-- Who takes the target's next cast (castSpell: the cast's lower-case name or id when it's casting):
--   1. a row whose condition holds (it exists for that moment, e.g. "when she has Blessing of Protection");
--   2. the designated kicker whose turn it is, else the next designated one;
--   3. a backup;
-- each only when their interrupt is ready by the next cast, they're alive, the cast is one of their abilities, and
-- the target isn't immune to their kind of interrupt. Else whoever is ready soonest ("late").
-- Returns the row and "cond" | "main" | "backup" | "late".
function Live:Pick(tr, castSpell)
    local now = GetTime()
    local within = self:NextCastIn(tr) or 0
    local immune = self:Immunities(tr.npc)
    local function can(r)
        if r.dead or CdLeft(r, now) > within then return false end
        if castSpell and r.spells and not r.spells[castSpell] then return false end
        local school = School(r)
        if school and immune[school] then return false end
        return true
    end
    for _, list in ipairs({ tr.order, tr.backups }) do
        for _, r in ipairs(list) do
            if r.cond and self:CondHolds(r, tr) and can(r) then return r, "cond" end
        end
    end
    local n = #tr.order
    for step = 0, n - 1 do
        local r = tr.order[((tr.cur - 1 + step) % n) + 1]
        if not r.cond and can(r) then return r, "main" end
    end
    for _, r in ipairs(tr.backups) do
        if not r.cond and can(r) then return r, "backup" end
    end
    local best
    for _, list in ipairs({ tr.order, tr.backups }) do
        for _, r in ipairs(list) do
            if not r.dead and (not r.cond or self:CondHolds(r, tr)) and (not best or CdLeft(r, now) < CdLeft(best, now)) then
                best = r
            end
        end
    end
    return best, "late"
end

-- Whose kick is next in a rotation (during a cast: the one it was given to). Returns the row and how (see Pick).
function Live:Turn(tr)
    if tr.castStart and tr.pick then return tr.pick, tr.pickHow end
    return self:Pick(tr)
end

-- Seconds left of a row's cooldown (0 = ready), for pi / iv / md / bl.
function Live:Cooldown(r)
    if not r.last or not r.cd then return 0 end
    return max(0, r.cd - (GetTime() - r.last))
end

-- Bloodlust's planned moment: seconds after the pull from the row text ("15 s after the pull"), or nil.
function Live:PlannedAt(r)
    local n = (r.text or r.label or ""):match("(%d+)%s*s")
    return n and tonumber(n) or nil
end

---------------------------------------------------------------------------
-- Near the boss
---------------------------------------------------------------------------

local function SetCurrent(c)
    generation = generation + 1
    cur = c
    Changed()
end

-- The boss of a creature was seen (or pulled). Returns the context (nil without a strategy).
function Live:Approach(bossRef, engaged)
    if cur and cur.practice then return cur end    -- a practice run owns the panel until it ends
    if cur and cur.boss == bossRef then
        cur.seenAt = GetTime()
        if engaged and not cur.engaged then self:Engage() end
        return cur
    end
    if cur and cur.engaged then return cur end     -- never switch in the middle of a fight
    local c = Build(bossRef)
    if not c then return nil end
    Debug("near %s (%s), plan %s%s", c.name, bossRef, c.s.n, c.occ and (" for raid " .. c.occ) or " (no raid linked)")
    SetCurrent(c)
    if engaged then self:Engage() end
    return c
end

-- Forget the current boss (tests, leaving the group).
function Live:Reset()
    SetCurrent(nil)
end

-- Practice (Core/StrategyPractice.lua): a context from a given strategy and names, owning the panel.
function Live:StartPractice(s, a)
    local c = Build(s.b, { s = s, a = a, practice = true })
    if not c then return nil end
    SetCurrent(c)
    return c
end

-- The marks of the current plan in board order (Practice marks whatever the player targets with them).
function Live:MarkOrder()
    local out, seen = {}, {}
    for _, p in ipairs(cur and cur.s.p or {}) do
        for _, e in ipairs(p.e or {}) do
            if e.t == "i" and e.rm and not seen[e.rm] then
                seen[e.rm] = true
                out[#out + 1] = e.rm
            end
        end
    end
    return out
end

function Live:Engage()
    if not cur then return end
    cur.engaged, cur.pullAt, cur.ended = true, GetTime(), nil
    -- a new pull: trackers start over (names / plan may have changed since it was seen)
    local fresh = Build(cur.boss, cur.fixed)
    if fresh then
        cur.trackers, cur.a = fresh.trackers, fresh.a
    end
    cur.auras = {}
    Debug("engaged %s", cur.name)
    Changed()
end

function Live:EndEncounter(success)
    if not cur then return end
    cur.engaged, cur.ended, cur.success = false, GetTime(), success and true or false
    Changed()
    local gen = generation
    Util.After(FADE_AFTER_END, function()
        if generation == gen and cur and cur.ended then SetCurrent(nil) end
    end)
end

---------------------------------------------------------------------------
-- Marking (the raid leader)
---------------------------------------------------------------------------

local function MarkingOn()
    return cur ~= nil and cur.s.am ~= false and Setting("strategy.autoMark", true) and Live:IsMarker()
end

-- A unit of a planned creature: give it its mark (or put it back).
local function MarkUnit(unit, guid, npc)
    if not MarkingOn() then return end
    local plan = cur.marks[npc]
    if not plan then return end
    if UnitIsDead and UnitIsDead(unit) then return end
    local want = cur.assigned[guid]
    if not want then
        for _, m in ipairs(plan) do
            local owner = cur.owner[m]
            if not owner or owner == guid then
                want = m
                break
            end
        end
        if not want then return end               -- every mark of that creature is taken (more mobs than marks)
        cur.assigned[guid], cur.owner[want] = want, guid
    end
    local have = GetRaidTargetIndex(unit)
    if have == want then return end
    local r = cur.remarks[guid] or { n = 0, at = -100 }
    if have ~= nil then
        -- someone / something changed it: the plan wins, but don't fight forever
        if r.n >= REMARK_MAX then return end
        if GetTime() - r.at < REMARK_GAP then
            -- too soon after the last mark: look again once the gap has passed
            if not r.pending then
                r.pending = true
                cur.remarks[guid] = r
                local gen = generation
                Util.After(REMARK_GAP, function()
                    r.pending = nil
                    if generation == gen then Live:Rescan() end
                end)
            end
            return
        end
        r.n = r.n + 1
    end
    r.at = GetTime()
    cur.remarks[guid] = r
    Debug("mark %s -> %d", tostring(UnitName(unit)), want)
    SetRaidTarget(unit, want)
end

-- Every unit this client can see now (nameplates, target, mouseover).
local function EachUnit(fn)
    local seen = {}
    local function try(unit)
        local guid = UnitGUID(unit)
        if guid and not seen[guid] then
            seen[guid] = true
            fn(unit, guid)
        end
    end
    -- the nameplate unit tokens themselves (whatever fields the client's plate frames carry)
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) then try(unit) end
    end
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
            local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if unit then try(unit) end
        end
    end
    try("target")
    try("mouseover")
end

-- The health of the boss creatures this client can see now (nameplates, target, mouseover).
function Live:UpdateHealth()
    if not cur then return false end
    local changed = false
    EachUnit(function(unit, guid)
        local npc = NpcOf(guid)
        local max = npc and UnitHealthMax(unit) or 0
        if npc and max > 0 then
            local pct = floor(UnitHealth(unit) / max * 100 + 0.5)
            if cur.hp[npc] ~= pct then
                cur.hp[npc] = pct
                changed = true
            end
        end
    end)
    if changed then Changed() end
    return changed
end

-- A unit became visible: near its boss? then mark it.
function Live:OnUnit(unit)
    local guid = UnitGUID(unit)
    local npc = NpcOf(guid)
    if not npc then return end
    local bossRef = self:BossOfNpc(npc)
    if not bossRef then return end
    if UnitIsDead and UnitIsDead(unit) then return end
    if Setting("strategy.reminder", true) or self:IsMarker() then self:Approach(bossRef) end
    if cur and cur.boss == bossRef then MarkUnit(unit, guid, npc) end
end

function Live:Rescan()
    EachUnit(function(unit) self:OnUnit(unit) end)
end

---------------------------------------------------------------------------
-- Combat log
---------------------------------------------------------------------------

local function Tracked(kind)
    local out = {}
    for _, tr in ipairs(cur and cur.trackers or {}) do
        if tr.kind == kind then out[#out + 1] = tr end
    end
    return out
end

local function IndexIn(order, key)
    for i, r in ipairs(order) do
        if r.player == key then return i end
    end
    return nil
end

-- The rotation moves past designated kicker `i` (who just used theirs, or whose turn timed out).
local function Advance(tr, i)
    if #tr.order > 0 then tr.cur = (i % #tr.order) + 1 end
    tr.castStart, tr.flash, tr.pick, tr.pickHow = nil, nil, nil, nil
end

-- The kicker a cast was given to didn't kick in time: a designated kicker loses the turn.
local function TurnTimeout(tr, gen, castId)
    Util.After(TURN_TIMEOUT, function()
        if generation ~= gen or tr.castId ~= castId or not tr.castStart then return end
        local r = tr.pick
        if r then
            r.skipped = GetTime()
            Debug("rotation %s: %s missed the turn", tr.name, tostring(r.player))
            local i = IndexIn(tr.order, r.player)
            if i then Advance(tr, i) else tr.castStart, tr.flash, tr.pick, tr.pickHow = nil, nil, nil, nil end
            Changed()
        end
    end)
end

-- A dead player's turn goes to the next one.
local function SkipDead(tr)
    for _ = 1, #tr.order do
        local r = tr.order[tr.cur]
        if not (r and r.dead) then return end
        Advance(tr, tr.cur)
    end
end

function Live:OnCombatLog()
    if not cur then return end
    local _, sub, _, srcGUID, srcName, _, _, dstGUID, dstName, _, _, spellId, spellName = CombatLogGetCurrentEventInfo()
    self:Handle(sub, srcGUID, srcName, dstGUID, dstName, spellName, spellId)
end

-- Does a cast belong to a rotation's abilities (all casts when the table picks none)?
local function IsAbility(tr, spellName, spellId)
    if not tr.spells then return true end
    return (spellId and tr.spells[spellId]) or (type(spellName) == "string" and tr.spells[spellName:lower()]) or false
end

-- One combat log event (from the client, or scripted by Practice).
function Live:Handle(sub, srcGUID, srcName, dstGUID, dstName, spellName, spellId)
    if not cur then return end
    local now = GetTime()
    local who = KeyOf(srcGUID, srcName)
    local dstNpc = NpcOf(dstGUID)
    local changed = false

    if sub == "SPELL_CAST_SUCCESS" or sub == "SPELL_MISSED" then
        -- interrupts: the caster's turn is used, hit or miss
        if who and SpellIn("rot", spellName) then
            for _, tr in ipairs(Tracked("rot")) do
                local i = IndexIn(tr.order, who)
                local r = i and tr.order[i]
                if not r then
                    for _, b in ipairs(tr.backups) do
                        if b.player == who then r = b end
                    end
                end
                if r and (not tr.npc or not dstNpc or dstNpc == tr.npc or cur.practice) then
                    if not (r.used and now - r.used < MISS_DEDUPE) then
                        r.used, r.cd, r.last = now, SpellIn("rot", spellName), now
                        r.school = InterruptSchool(spellName) or r.school
                        r.missed = sub == "SPELL_MISSED" or nil
                        Debug("rotation %s: %s used %s%s%s", tr.name, who, spellName, r.missed and " (missed)" or "",
                            r.backup and " (backup)" or "")
                        if i then
                            Advance(tr, i)
                        else
                            -- a backup's kick: the designated kicker keeps the turn for when they're ready
                            tr.castStart, tr.flash, tr.pick, tr.pickHow = nil, nil, nil, nil
                        end
                        SkipDead(tr)
                        changed = true
                    end
                end
            end
        end
        if sub == "SPELL_CAST_SUCCESS" and who then
            for _, kind in ipairs({ "md", "bl", "pi", "iv" }) do
                local cd = SpellIn(kind, spellName)
                if cd then
                    for _, tr in ipairs(Tracked(kind)) do
                        for _, r in ipairs(tr.rows) do
                            if r.player == who then
                                r.done, r.last, r.cd = true, now, cd
                                -- who it went to (a misdirect onto the planned tank or not)
                                r.dest = KeyOf(dstGUID, dstName)
                                Debug("%s: %s cast %s%s", tr.name, who, spellName,
                                    r.dest and (" on " .. r.dest) or "")
                                changed = true
                            end
                        end
                    end
                end
            end
        end
    elseif sub == "SPELL_CAST_START" then
        -- the rotation's target starts a cast: the current player's moment
        local npc = NpcOf(srcGUID)
        if npc then
            for _, tr in ipairs(Tracked("rot")) do
                if (tr.npc == npc or (cur.practice and npc == 0)) and #tr.order + #tr.backups > 0
                    and IsAbility(tr, spellName, spellId) then
                    SkipDead(tr)
                    tr.casts = tr.casts or {}
                    tr.casts[#tr.casts + 1] = now
                    if #tr.casts > 6 then table.remove(tr.casts, 1) end
                    tr.castStart, tr.castName = now, spellName
                    tr.castId = (tr.castId or 0) + 1
                    local castKey = (spellId and tr.spells and tr.spells[spellId] and spellId)
                        or (type(spellName) == "string" and spellName:lower()) or nil
                    local r, how = Live:Pick(tr, castKey)
                    tr.pick, tr.pickHow = r, how
                    tr.flash = r and r.player == Me() or nil
                    Debug("rotation %s: target casts %s, kick: %s (%s)", tr.name, tostring(spellName),
                        tostring(r and r.player), tostring(how))
                    TurnTimeout(tr, generation, tr.castId)
                    changed = true
                end
            end
        end
    elseif sub == "SPELL_INTERRUPT" or sub == "SPELL_CAST_FAILED" then
        local npc = NpcOf(sub == "SPELL_INTERRUPT" and dstGUID or srcGUID)
        for _, tr in ipairs(Tracked("rot")) do
            if npc and tr.npc == npc and tr.castStart then
                tr.castStart, tr.flash, tr.pick, tr.pickHow = nil, nil, nil, nil
                changed = true
            end
        end
    elseif sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_REFRESH" or sub == "SPELL_AURA_REMOVED" then
        -- the buffs on the boss' creatures (conditions, immunities)
        if dstNpc and (cur.practice or self:BossOfNpc(dstNpc) == cur.boss) then
            local id = spellId
            if not id and type(spellName) == "string" then
                for aid in pairs(IMMUNE) do
                    if GetSpellInfo(aid) == spellName then id = aid end
                end
            end
            if id then
                cur.auras[dstNpc] = cur.auras[dstNpc] or {}
                local has = sub ~= "SPELL_AURA_REMOVED" or nil
                if cur.auras[dstNpc][id] ~= has then
                    cur.auras[dstNpc][id] = has
                    Debug("%s %s %s", tostring(dstName), has and "gains" or "loses", tostring(spellName))
                    changed = true
                end
            end
        end
        -- a known curse, or one a row picked by spell id
        if who and (SpellIn("curse", spellName) or CurseRow(who, spellName)) then
            for _, tr in ipairs(Tracked("curse")) do
                for _, r in ipairs(tr.rows) do
                    if r.player == who and r.curse == spellName:lower() and (not r.npc or r.npc == dstNpc or cur.practice) then
                        local up = sub ~= "SPELL_AURA_REMOVED"
                        if r.up ~= up then
                            r.up = up
                            r.fellAt = (not up) and now or nil
                            Debug("%s: %s %s on %s", tr.name, spellName, up and "up" or "fell off", tostring(dstName))
                            changed = true
                        end
                    end
                end
            end
        end
    elseif sub == "UNIT_DIED" then
        local key = KeyOf(dstGUID, dstName)
        if key then
            for _, tr in ipairs(Tracked("rot")) do
                for _, list in ipairs({ tr.order, tr.backups }) do
                    for _, r in ipairs(list) do
                        if r.player == key then r.dead = true; changed = true end
                    end
                end
                SkipDead(tr)
            end
        elseif dstGUID and cur.assigned[dstGUID] then
            cur.owner[cur.assigned[dstGUID]] = nil     -- its mark may go to the next one of that creature
            cur.assigned[dstGUID] = nil
        end
    end
    if changed then Changed() end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function OnEncounterStart(encounterID)
    local ItemDB = ns.ItemDB
    local ref = ItemDB and ItemDB.GetBossByEncounter and ItemDB:GetBossByEncounter(encounterID)
    local bossRef = ref and ref.key
    if bossRef then Live:Approach(bossRef, true) end
end

local function OnEncounterEnd(encounterID, _, _, _, success)
    if not cur then return end
    local ItemDB = ns.ItemDB
    local ref = ItemDB and ItemDB.GetBossByEncounter and ItemDB:GetBossByEncounter(encounterID)
    if ref and ref.key ~= cur.boss then return end
    Live:EndEncounter(success == 1 or success == true)
end

-- /cdl strat check: everything the helpers depend on, checkable alone outside a raid.
function Live:Check()
    local P = function(...) ns:Print(...) end
    local function yes(b) return b and "|cff33ff66yes|r" or "|cffff5050no|r" end
    P("Encounter helpers check:")
    P("  Settings: auto-mark %s, reminder %s", yes(Setting("strategy.autoMark", true)), yes(Setting("strategy.reminder", true)))
    P("  You lead the group (only the raid leader marks): %s", yes(self:IsMarker()))
    local plates = GetCVar and GetCVar("nameplateShowEnemies")
    P("  Enemy nameplates on (needed to mark): %s", plates == nil and "?" or yes(plates == "1"))
    -- the spells, by name, as this client knows them
    local missing = {}
    for kind, list in pairs(SPELLS) do
        for id in pairs(list) do
            local name = GetSpellInfo and GetSpellInfo(id)
            if type(name) ~= "string" or name == "" then missing[#missing + 1] = kind .. ":" .. id end
        end
    end
    P("  Tracked spells known to this client: %s", #missing == 0 and "|cff33ff66all|r" or ("|cffff5050missing " .. table.concat(missing, ", ") .. "|r"))
    -- the plan
    local occ = SessionOcc()
    local RP = ns.RaidPlan
    local v = occ and RP and RP:GetRaid(occ)
    P("  Raid session linked to a planned raid: %s", v and ("|cff33ff66" .. RP:GetRaidName(v) .. " " .. date("%a %d %b %H:%M", v.t) .. "|r") or "|cffff5050no|r (plans without names)")
    local bosses = v and S():GetBosses(v.i) or {}
    if not v then
        for _, raid in ipairs(S():GetRaidTree()) do
            for _, b in ipairs(raid.bosses) do
                if #S():GetStrategies(b.ref) > 0 then bosses[#bosses + 1] = b end
            end
        end
    end
    local any = false
    for _, b in ipairs(bosses) do
        local c = Build(b.ref)
        if c then
            any = true
            local nMarks, unknown = 0, 0
            for _ in pairs(c.marks) do nMarks = nMarks + 1 end
            for _, p in ipairs(c.s.p or {}) do
                for _, e in ipairs(p.e or {}) do
                    if e.t == "i" and e.rm and not NpcOfIcon(b.ref, e.i) then unknown = unknown + 1 end
                end
            end
            local names = 0
            for _ in pairs(c.a) do names = names + 1 end
            local mine = #S():GetPlayerSlots(c.s, c.a, Me())
            P("  %s: \"%s\" - marks %d creature(s)%s, %d tracked table(s), %d name(s), your jobs: %d", b.name, c.s.n,
                nMarks, unknown > 0 and (" |cffff9933(" .. unknown .. " marked icon(s) aren't creatures)|r") or "",
                #c.trackers, names, mine)
        end
    end
    if not any then P("  No strategies for this raid's bosses yet.") end
end

local function Slash(rest)
    local raw = Util.Trim(rest or "")
    rest = raw:lower()
    local P = ns.StrategyPractice
    if P and (rest == "stop" or rest:find("^practice")) then
        P.Slash(rest == "stop" and "stop" or Util.Trim(raw:sub(9)))
        return
    end
    if rest == "draft" then
        if ns.StrategyBoard then ns.StrategyBoard:OpenDraft() end
    elseif rest == "check" then
        Live:Check()
    elseif rest == "debug" then
        debugOn = not debugOn
        ns:Print("Strategy board encounter debug %s.", debugOn and "on (events print to chat)" or "off")
    elseif rest == "reset" then
        Live:Reset()
        ns:Print("Encounter helpers reset.")
    else
        if cur then
            ns:Print("Near %s: plan \"%s\"%s; %d tracked tables, marks for %d creatures.", cur.name, cur.s.n,
                cur.occ and "" or " (no planned raid linked: no names)", #cur.trackers,
                (function() local n = 0; for _ in pairs(cur.marks) do n = n + 1 end; return n end)())
        else
            ns:Print("No boss nearby. The helpers start when you see a planned boss (or the pull).")
        end
        ns:Print("/cdl strat practice [boss] - try it solo (a target dummy is ideal); /cdl strat stop; "
            .. "/cdl strat check - test the setup; /cdl strat debug - print what the helpers see; "
            .. "/cdl strat reset - forget the current boss; /cdl strat draft - back to your unsaved strategy.")
    end
end

function Live:OnInit()
    ns:RegisterSlash("strat", Slash, "strategy board encounter helpers (debug / reset)")
    local f = CreateFrame("Frame")
    f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    f:RegisterEvent("PLAYER_TARGET_CHANGED")
    f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    f:RegisterEvent("RAID_TARGET_UPDATE")
    f:RegisterEvent("ENCOUNTER_START")
    f:RegisterEvent("ENCOUNTER_END")
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    f:RegisterEvent("GROUP_LEFT")
    f:SetScript("OnEvent", function(_, event, ...)
        if event == "NAME_PLATE_UNIT_ADDED" then
            Live:OnUnit((...))
        elseif event == "PLAYER_TARGET_CHANGED" then
            Live:OnUnit("target")
        elseif event == "UPDATE_MOUSEOVER_UNIT" then
            Live:OnUnit("mouseover")
        elseif event == "RAID_TARGET_UPDATE" then
            if MarkingOn() then Live:Rescan() end
        elseif event == "ENCOUNTER_START" then
            OnEncounterStart(...)
        elseif event == "ENCOUNTER_END" then
            OnEncounterEnd(...)
        elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
            Live:OnCombatLog()
        elseif event == "GROUP_LEFT" then
            Live:Reset()
        end
    end)
    -- a boss seen long ago and never pulled is forgotten; during a fight the bosses' health is read twice a second
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(30, function()
            if cur and not cur.engaged and not cur.ended and GetTime() - cur.seenAt > FORGET_AFTER then Live:Reset() end
        end)
        C_Timer.NewTicker(0.5, function()
            if cur and cur.engaged then Live:UpdateHealth() end
        end)
    end
    ns:On("STRATEGY_CHANGED", function()
        -- a new plan / new names reach a boss that is only near (never rebuilt mid-fight)
        if cur and not cur.engaged and not cur.ended and not cur.practice then
            local fresh = Build(cur.boss)
            if fresh then
                fresh.assigned, fresh.owner, fresh.remarks, fresh.seenAt = cur.assigned, cur.owner, cur.remarks, cur.seenAt
                cur = fresh
                Changed()
            end
        end
    end)
end

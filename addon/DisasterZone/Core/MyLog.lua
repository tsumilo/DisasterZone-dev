if DisasterZoneBoot and DisasterZoneBoot.Run("Core/MyLog.lua", ...) then return end -- DisasterZone: My Log (personal combat log).
-- An opt-in recorder of my own play in every boss pull, kept for me alone: it never sends anything, nobody else can
-- read it and the loot council never sees it. Off until the player turns it on (Settings > My Log, mylog.enabled).
--
-- What a pull records (everything, for every role; the UI picks which numbers lead by role):
--   damage done per ability (mine and my pets', guardians' and totems'), healing and overhealing, my shields'
--   absorbs, damage taken per source ability (with resists, blocks, absorbs, crits, crushes), avoidance (dodge, parry,
--   miss, block), healing received per healer, casts, interrupts, dispels, resource gains, buff uptime on me and my
--   debuff uptime on enemies, damage per target, a 5-second timeline (damage, healing, taken, resource %), active time
--   with every idle gap over 2 s, and death recaps (the last 10 s of events, health after each).
--
-- Counting (matches the client's combat log fields, COMBAT_LOG_EVENT_UNFILTERED, 2.5.x layout):
--   damage done   = amount - overkill + absorbed   (the hit as the target felt it, shields included)
--   healing done  = amount - overhealing           (effective), overhealing kept apart; shield absorbs kept apart
--   damage taken  = amount (health lost) + absorbed (what shields took), overkill counted on my death blow only
-- Mine = the source flags' AFFILIATION_MINE bit, so pets, guardians and totems need no bookkeeping.
-- The fight clock runs from ENCOUNTER_START to ENCOUNTER_END (GetTime). A /reload or logout mid-pull stores the pull
-- as cut short (cut = true); comparisons leave it out.
--
-- Data (SavedVariables DisasterZoneLogDB, its own file, never synced):
--   { v = 1, chars = { [charKey] = { n = last pull id, pulls = { pull, ... } (oldest first) } } }
--   pull = { id, at (server time), enc, boss, zone, iid (instance id), diff, size, kill, cut, dur (s), heroic,
--            cls, spec, role, tal = "41/20/0", ilvl, buffs = { spellId } (at the pull), pct (boss health % at the end,
--            wipes), s = summary (always kept), and the detail tables below (dropped when the pull ages out):
--            dmg / pet / heal / shield / taken / [key] = stat, names [key] = name, avoid [missType] = n,
--            healIn [healer] = n, casts / kicks / disp / gain [spellId] = n | { n, a, o }, up = { me = { [id] = s },
--            out = { [id] = s } }, tgt [npcId] = { n = name, a = damage }, tl = { d, h, t, p } (5 s buckets),
--            gaps = { { at, len } }, dead (s into the fight), deaths = { { t, by, ring } } }
--   s = { d, h, oh, sh, t, act (0..1), dc (deaths), dps, hps, dtps }
-- Detail is kept for the last DETAIL_KILLS kills and DETAIL_PULLS pulls of each boss; older pulls keep pull info and
-- s. Pulls older than mylog.keepWeeks are dropped.
local addonName, ns = ...

local MyLog = ns:NewModule("MyLog")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, select, next = type, pairs, ipairs, tonumber, tostring, select, next
local floor, max, min = math.floor, math.max, math.min
local strmatch, strsub, strformat = string.match, string.sub, string.format
local band = bit and bit.band
local GetItemInfo = C_Item and C_Item.GetItemInfo

local BUCKET = 5                 -- timeline bucket, seconds
local GAP_MIN = 2                -- idle gaps at least this long are listed
local GAPS_MAX = 60
local RING = 64                  -- death recap ring (events to or from me)
local RECAP = 10                 -- seconds of recap kept per death
local DEATHS_MAX = 10
local DETAIL_KILLS, DETAIL_PULLS = 3, 5
local AFFIL_MINE = 0x00000001    -- COMBATLOG_OBJECT_AFFILIATION_MINE
local DEFAULT_GCD = 1.5
local ENERGY_GCD = 1.0           -- rogues, cat form
local WEEK = 7 * 86400

-- Pull state while recording (nil otherwise)
local cur                        -- the pull record being filled
local t0                         -- GetTime() at ENCOUNTER_START
local myGUID
local ring, ringPos = {}, 0
local auraOn = { me = {}, out = {} }     -- [spellId] = { since, count } while up
local busyUntil, covered, lastCastStart, castCover, castGcd   -- active time (see Cover)
local ticker

---------------------------------------------------------------------------
-- Settings and storage
---------------------------------------------------------------------------

local function Setting(path, default)
    local v = ns.DB and ns.DB.GetSetting and ns.DB:GetSetting(path)
    if v == nil then return default end
    return v
end

function MyLog:IsEnabled() return Setting("mylog.enabled", false) and true or false end
function MyLog:HeroicsOn() return Setting("mylog.heroics", false) and true or false end
function MyLog:KeepWeeks() return tonumber(Setting("mylog.keepWeeks", 12)) or 12 end

local function Store()
    if type(DisasterZoneLogDB) ~= "table" then DisasterZoneLogDB = {} end
    local db = DisasterZoneLogDB
    db.v = db.v or 1
    if type(db.chars) ~= "table" then db.chars = {} end
    return db
end

local function CharKey() return Util.PlayerKey() end

local function MyChar(create)
    local key = CharKey()
    if not key then return nil end
    local chars = Store().chars
    local c = chars[key]
    if not c and create then
        c = { n = 0, pulls = {} }
        chars[key] = c
    end
    return c
end

-- My pulls, oldest first (another character's with charKey). While demo mode is on: the demo pulls
-- (Core/MyLogDemo.lua) instead; recording still goes to the real log.
function MyLog:GetPulls(charKey)
    if not charKey and ns.MyLogDemo and ns.MyLogDemo:IsActive() then return ns.MyLogDemo:GetPulls() end
    local c = (Store().chars)[charKey or CharKey() or ""]
    return c and c.pulls or {}
end

function MyLog:IsDemo() return ns.MyLogDemo and ns.MyLogDemo:IsActive() or false end

-- Boss abilities a player can stay out of (spell ids). Hand-picked from the strategy board's ability data; damage
-- taken from these is "avoidable". Not yet checked against real logs: fix a wrong one here.
MyLog.AVOIDABLE = {
    [29946] = true,   -- Flame Wreath (Shade of Aran): moving while it is up
    [30129] = true,   -- Charred Earth (Nightbane)
    [30859] = true,   -- Hellfire (Prince Malchezaar's infernals)
    [37433] = true,   -- Spout (The Lurker Below)
    [37640] = true,   -- Whirlwind (Leotheras the Blind)
    [38575] = true,   -- Toxic Spores (Lady Vashj)
    [35383] = true,   -- Flame Patch (Al'ar)
}

function MyLog:IsAvoidable(key)
    local id = tonumber(key)
    return id and self.AVOIDABLE[id] or false
end

function MyLog:GetPull(id, charKey)
    for _, p in ipairs(self:GetPulls(charKey)) do
        if p.id == id then return p end
    end
    return nil
end

function MyLog:IsRecording() return cur ~= nil end
function MyLog:GetCurrent() return cur end

-- Deletes every stored pull of every character (Settings > My Log > Delete). Stops a running pull without saving it.
function MyLog:DeleteAll()
    if cur then self:Stop(true) end
    DisasterZoneLogDB = { v = 1, chars = {} }
    ns:Fire("MYLOG_CHANGED")
end

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function Now() return GetTime() end

local function NpcId(guid)
    if type(guid) ~= "string" then return nil end
    local kind, id = strmatch(guid, "^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
    return nil
end

local function Bucket(now)
    return floor((now - t0) / BUCKET) + 1
end

local function AddTl(field, amount, now)
    local tl = cur.tl[field]
    local b = Bucket(now)
    tl[b] = (tl[b] or 0) + amount
end

local function Name(key, name)
    if name and cur.names[key] == nil then cur.names[key] = name end
end

-- A stat for a hit: n hits, c crits, a amount, ca crit amount, mx biggest, o overkill, r resisted, b blocked,
-- ab absorbed, g glancing, cr crushing, m = { [missType] = n }, ma (amount on partial-miss types)
local function Stat(tbl, key)
    local s = tbl[key]
    if not s then
        s = { n = 0, c = 0, a = 0 }
        tbl[key] = s
    end
    return s
end

local function AddHit(s, amount, overkill, resisted, blocked, absorbed, crit, glancing, crushing)
    s.n = s.n + 1
    s.a = s.a + amount
    if crit then
        s.c = s.c + 1
        s.ca = (s.ca or 0) + amount
    end
    if amount > (s.mx or 0) then s.mx = amount end
    if overkill and overkill > 0 then s.o = (s.o or 0) + overkill end
    if resisted and resisted > 0 then s.r = (s.r or 0) + resisted end
    if blocked and blocked > 0 then s.b = (s.b or 0) + blocked end
    if absorbed and absorbed > 0 then s.ab = (s.ab or 0) + absorbed end
    if glancing then s.g = (s.g or 0) + 1 end
    if crushing then s.cr = (s.cr or 0) + 1 end
end

local function AddMiss(s, missType, amountMissed)
    local m = s.m
    if not m then m = {}; s.m = m end
    missType = missType or "MISS"
    m[missType] = (m[missType] or 0) + 1
    if amountMissed and amountMissed > 0 then
        s.ma = (s.ma or 0) + amountMissed
        if missType == "ABSORB" then s.mab = (s.mab or 0) + amountMissed end
    end
end

local function PushRing(now, kind, key, amount, who, extra)
    ringPos = ringPos % RING + 1
    local hp = UnitHealth and UnitHealth("player") or 0
    ring[ringPos] = { now - t0, kind, key, amount, hp, who, extra }
end

---------------------------------------------------------------------------
-- Active time: the union of my casts, channels, global cooldowns and auto-attack swings. Intervals arrive almost in
-- order, so the union is kept incrementally: covered grows by the part of [a, b] past busyUntil, and a start past
-- busyUntil is an idle gap. A cast is covered to its expected end when it starts; an interrupted or failed cast hands
-- back the part not cast, while it is still the last thing covered (castCover).
---------------------------------------------------------------------------

local function Cover(a, b)
    if not cur or b <= a then return end
    if cur.dead then return end
    a = max(a, t0)
    if b <= a then return end
    if a > busyUntil then
        local gap = a - busyUntil
        if gap >= GAP_MIN and #cur.gaps < GAPS_MAX then
            cur.gaps[#cur.gaps + 1] = { at = floor((busyUntil - t0) * 10 + 0.5) / 10, len = floor(gap * 10 + 0.5) / 10 }
        end
        covered = covered + (b - a)
        busyUntil = b
    elseif b > busyUntil then
        covered = covered + (b - busyUntil)
        busyUntil = b
    end
end

local function GcdFor(spellId)
    local cls = cur and cur.cls
    local base = DEFAULT_GCD
    if cls == "ROGUE" or (cls == "DRUID" and GetShapeshiftFormID and GetShapeshiftFormID() == 1) then
        base = ENERGY_GCD
    end
    if GetSpellCooldown and spellId then
        local start, duration = GetSpellCooldown(spellId)
        duration = tonumber(duration)
        if start and start > 0 and duration and duration > 0 and duration <= DEFAULT_GCD then return duration end
    end
    return base
end

local function CastEnd(endMS)
    endMS = tonumber(endMS)
    if not endMS then return nil end
    return endMS / 1000
end

local function OnCastStart(_, unit)
    if unit ~= "player" or not cur then return end
    local now = Now()
    local _, _, _, _, endMS, _, _, _, spellId = UnitCastingInfo("player")
    local stop = CastEnd(endMS) or (now + DEFAULT_GCD)
    castGcd = GcdFor(spellId)
    stop = max(stop, now + castGcd)
    lastCastStart = now
    Cover(now, stop)
    castCover = stop
end

local function OnCastDelayed(_, unit)
    if unit ~= "player" or not cur then return end
    local _, _, _, _, endMS = UnitCastingInfo("player")
    local stop = CastEnd(endMS)
    if stop then
        Cover(Now(), stop)
        castCover = stop
    end
end

local function OnChannelStart(_, unit)
    if unit ~= "player" or not cur then return end
    local now = Now()
    local _, _, _, _, endMS = UnitChannelInfo("player")
    local stop = CastEnd(endMS) or (now + DEFAULT_GCD)
    castGcd = DEFAULT_GCD
    lastCastStart = now
    Cover(now, stop)
    castCover = stop
end

-- The cast or channel ended before its expected end: hand back the rest (the global cooldown it started stays).
-- FAILED also fires for a refused second cast while the first goes on: only a player no longer casting is cut.
local function OnCastCut(_, unit)
    if unit ~= "player" or not cur or not castCover then return end
    if UnitCastingInfo("player") or UnitChannelInfo("player") then return end
    local now = Now()
    local keep = max(now, (lastCastStart or now) + (castGcd or 0))
    if busyUntil == castCover and keep < busyUntil then
        covered = covered - (busyUntil - keep)
        busyUntil = keep
    end
    castCover = nil
end

local function OnCastSucceeded(_, unit, _, spellId)
    if unit ~= "player" or not cur then return end
    local now = Now()
    if castCover and castCover > now then
        castCover = nil      -- a cast finished on time (its cover stands)
        return
    end
    castCover = nil
    Cover(now, now + GcdFor(spellId))
end

local function SwingSpeed(ranged)
    if ranged then
        local speed = UnitRangedDamage and UnitRangedDamage("player")
        return tonumber(speed) or 2
    end
    local main = UnitAttackSpeed and UnitAttackSpeed("player")
    return tonumber(main) or 2
end

---------------------------------------------------------------------------
-- Auras: uptime of buffs on me (me) and of my debuffs on enemies (out, "up on at least one enemy").
---------------------------------------------------------------------------

local function AuraUp(side, spellId, now)
    local a = auraOn[side][spellId]
    if not a then
        auraOn[side][spellId] = { since = now, count = 1 }
    else
        if a.count == 0 then a.since = now end
        a.count = a.count + 1
    end
end

local function AuraDown(side, spellId, now)
    local a = auraOn[side][spellId]
    if not a or a.count == 0 then return end
    a.count = a.count - 1
    if a.count == 0 then
        local up = cur.up[side]
        up[spellId] = (up[spellId] or 0) + (now - a.since)
    end
end

local function CloseAuras(now)
    for side, list in pairs(auraOn) do
        for spellId, a in pairs(list) do
            if a.count > 0 then
                local up = cur.up[side]
                up[spellId] = (up[spellId] or 0) + (now - a.since)
                a.count = 0
            end
        end
    end
end

local function SeedMyAuras(now)
    if not UnitAura then return end
    for i = 1, 40 do
        local name, _, _, _, _, _, _, _, _, spellId = UnitAura("player", i, "HELPFUL")
        if not name then break end
        spellId = tonumber(spellId)
        if spellId then
            cur.buffs[#cur.buffs + 1] = spellId
            AuraUp("me", spellId, now)
        end
    end
end

---------------------------------------------------------------------------
-- Combat log
---------------------------------------------------------------------------

local function DamageDone(now, srcGUID, srcName, dstGUID, dstName, key, isPet, amount, overkill, resisted, blocked,
                          absorbed, crit, glancing, crushing)
    amount = amount or 0
    local tbl = isPet and cur.pet or cur.dmg
    AddHit(Stat(tbl, key), amount, overkill, resisted, blocked, absorbed, crit, glancing, crushing)
    local useful = amount - max(overkill or 0, 0) + (absorbed or 0)
    if useful < 0 then useful = 0 end
    AddTl("d", useful, now)
    local npc = NpcId(dstGUID)
    if npc then
        local t = cur.tgt[npc]
        if not t then t = { n = dstName, a = 0 }; cur.tgt[npc] = t end
        t.a = t.a + useful
    end
end

local function DamageTaken(now, srcName, key, amount, overkill, resisted, blocked, absorbed, crit, crushing)
    amount = amount or 0
    local s = Stat(cur.taken, key)
    AddHit(s, amount, overkill, resisted, blocked, absorbed, crit, nil, crushing)
    if srcName and not s.src then s.src = srcName end
    local hpLost = amount - max(overkill or 0, 0)
    AddTl("t", hpLost + (absorbed or 0), now)
    PushRing(now, "d", key, amount, srcName, (absorbed and absorbed > 0) and absorbed or nil)
end

local SPELL_DAMAGE = {
    SPELL_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true, RANGE_DAMAGE = true, DAMAGE_SHIELD = true,
    DAMAGE_SPLIT = true, SPELL_BUILDING_DAMAGE = true,
}
local SPELL_MISSED = {
    SPELL_MISSED = true, SPELL_PERIODIC_MISSED = true, RANGE_MISSED = true, DAMAGE_SHIELD_MISSED = true,
}
local HEAL = { SPELL_HEAL = true, SPELL_PERIODIC_HEAL = true }
local ENERGIZE = { SPELL_ENERGIZE = true, SPELL_PERIODIC_ENERGIZE = true }

local function SpellKey(spellId, name, prefix)
    local key = (prefix or "") .. tostring(spellId or 0)
    Name(key, name)
    return key
end

local function OnCombatLog()
    if not cur then return end
    local _, sub, _, srcGUID, srcName, srcFlags, _, dstGUID, dstName, _, _, a12, a13, a14, a15, a16, a17, a18, a19,
          a20, a21, a22, a23 = CombatLogGetCurrentEventInfo()
    local fromMe = srcGUID == myGUID
    local mine = fromMe or (band and srcFlags and band(srcFlags, AFFIL_MINE) ~= 0 and srcGUID ~= myGUID
        and srcGUID ~= nil and strsub(srcGUID, 1, 7) ~= "Player-")
    local toMe = dstGUID == myGUID
    if not (fromMe or mine or toMe or sub == "SPELL_ABSORBED") then return end
    local now = Now()
    local isPet = mine and not fromMe

    -- Damage
    if sub == "SWING_DAMAGE" then
        if fromMe or isPet then
            local key = isPet and "p0" or "0"
            Name(key, isPet and ((srcName or "Pet") .. " melee") or "Melee")
            DamageDone(now, srcGUID, srcName, dstGUID, dstName, key, isPet, a12, a13, a15, a16, a17, a18, a19, a20)
            if fromMe then Cover(now, now + SwingSpeed(false)) end
        end
        if toMe then
            local npc = NpcId(srcGUID)
            local key = "m" .. tostring(npc or 0)
            Name(key, (srcName or "?") .. " melee")
            DamageTaken(now, srcName, key, a12, a13, a15, a16, a17, a18, a20)
        end
        return
    elseif SPELL_DAMAGE[sub] then
        if fromMe or isPet then
            local key = SpellKey(a12, a13, isPet and "p" or nil)
            DamageDone(now, srcGUID, srcName, dstGUID, dstName, key, isPet, a15, a16, a18, a19, a20, a21, a22, a23)
            if fromMe and sub == "RANGE_DAMAGE" then Cover(now, now + SwingSpeed(true)) end
        end
        if toMe then
            local key = SpellKey(a12, a13)
            DamageTaken(now, srcName, key, a15, a16, a18, a19, a20, a21, a23)
        end
        return
    elseif sub == "ENVIRONMENTAL_DAMAGE" then
        if toMe then
            local key = "e" .. tostring(a12 or "?")
            Name(key, tostring(a12 or "Environment"))
            DamageTaken(now, a12, key, a13, a14, a16, a17, a18, a19, a21)
        end
        return
    elseif sub == "SWING_MISSED" then
        if fromMe or isPet then
            local key = isPet and "p0" or "0"
            Name(key, isPet and ((srcName or "Pet") .. " melee") or "Melee")
            AddMiss(Stat(isPet and cur.pet or cur.dmg, key), a12, a14)
            if fromMe then Cover(now, now + SwingSpeed(false)) end
        end
        if toMe then
            local npc = NpcId(srcGUID)
            local key = "m" .. tostring(npc or 0)
            Name(key, (srcName or "?") .. " melee")
            local s = Stat(cur.taken, key)
            if srcName and not s.src then s.src = srcName end
            AddMiss(s, a12, a14)
            cur.avoid[a12 or "MISS"] = (cur.avoid[a12 or "MISS"] or 0) + 1
            if a12 == "ABSORB" and a14 then AddTl("t", a14, now) end
            PushRing(now, "m", key, a14, srcName, a12)
        end
        return
    elseif SPELL_MISSED[sub] then
        if fromMe or isPet then
            AddMiss(Stat(isPet and cur.pet or cur.dmg, SpellKey(a12, a13, isPet and "p" or nil)), a15, a17)
            if fromMe and sub == "RANGE_MISSED" then Cover(now, now + SwingSpeed(true)) end
        end
        if toMe then
            local key = SpellKey(a12, a13)
            local s = Stat(cur.taken, key)
            if srcName and not s.src then s.src = srcName end
            AddMiss(s, a15, a17)
            cur.avoid[a15 or "MISS"] = (cur.avoid[a15 or "MISS"] or 0) + 1
            if a15 == "ABSORB" and a17 then AddTl("t", a17, now) end
            PushRing(now, "m", key, a17, srcName, a15)
        end
        return
    end

    -- Healing
    if HEAL[sub] then
        local amount, over = a15 or 0, a16 or 0
        local eff = amount - over
        if eff < 0 then eff = 0 end
        if fromMe or isPet then
            local s = Stat(cur.heal, SpellKey(a12, a13, isPet and "p" or nil))
            s.n = s.n + 1
            s.a = s.a + eff
            if over > 0 then s.oh = (s.oh or 0) + over end
            if a17 and a17 > 0 then s.ab = (s.ab or 0) + a17 end
            if a18 then s.c = s.c + 1; s.ca = (s.ca or 0) + eff end
            if amount > (s.mx or 0) then s.mx = amount end
            AddTl("h", eff, now)
        end
        if toMe then
            local who = srcName or "?"
            cur.healIn[who] = (cur.healIn[who] or 0) + eff
            PushRing(now, "h", SpellKey(a12, a13), eff, srcName, over > 0 and over or nil)
        end
        return
    end

    -- Shields: SPELL_ABSORBED (swing form: caster at 12; spell form: the hit's spell at 12-14, caster at 15)
    if sub == "SPELL_ABSORBED" then
        local cGUID, cFlags, absId, absName, amount
        if type(a12) == "string" then
            cGUID, cFlags, absId, absName, amount = a12, a14, a16, a17, a19
        else
            cGUID, cFlags, absId, absName, amount = a15, a17, a19, a20, a22
        end
        local cMine = cGUID == myGUID or (band and cFlags and band(cFlags, AFFIL_MINE) ~= 0)
        if cMine and amount then
            local s = Stat(cur.shield, SpellKey(absId, absName))
            s.n = s.n + 1
            s.a = s.a + amount
            AddTl("h", amount, now)
        end
        return
    end

    -- Everything else is about me (casts, auras, resources, deaths)
    if sub == "SPELL_CAST_SUCCESS" then
        if fromMe then
            local id = tonumber(a12) or 0
            Name(tostring(id), a13)
            cur.casts[id] = (cur.casts[id] or 0) + 1
            PushRing(now, "c", tostring(id), nil, nil, nil)
        end
    elseif sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_REMOVED" then
        local id = tonumber(a12)
        if not id then return end
        local side
        if toMe and a15 == "BUFF" then
            side = "me"
        elseif fromMe and not toMe and a15 == "DEBUFF" then
            side = "out"
        end
        if side then
            Name(tostring(id), a13)
            if sub == "SPELL_AURA_APPLIED" then AuraUp(side, id, now) else AuraDown(side, id, now) end
        end
    elseif ENERGIZE[sub] then
        if toMe then
            local id = tonumber(a12) or 0
            Name(tostring(id), a13)
            local g = cur.gain[id]
            if not g then g = { n = 0, a = 0 }; cur.gain[id] = g end
            g.n = g.n + 1
            g.a = g.a + (a15 or 0)
            if type(a16) == "number" and a16 > 0 then g.o = (g.o or 0) + a16 end
        end
    elseif sub == "SPELL_INTERRUPT" then
        if fromMe or isPet then
            local id = tonumber(a15) or 0
            Name(tostring(id), a16)
            cur.kicks[id] = (cur.kicks[id] or 0) + 1
        end
    elseif sub == "SPELL_DISPEL" or sub == "SPELL_STOLEN" then
        if fromMe or isPet then
            local id = tonumber(a15) or 0
            Name(tostring(id), a16)
            cur.disp[id] = (cur.disp[id] or 0) + 1
        end
    elseif sub == "UNIT_DIED" then
        if toMe then
            if UnitIsFeignDeath and UnitIsFeignDeath("player") then return end
            MyLog:NoteDeath(now)
        end
    end
end

function MyLog:NoteDeath(now)
    if not cur then return end
    local t = now - t0
    local recap = {}
    local by
    for i = 1, RING do
        local idx = (ringPos + i - 1) % RING + 1   -- oldest first
        local e = ring[idx]
        if e and e[1] >= t - RECAP and e[1] <= t + 0.001 then
            recap[#recap + 1] = { floor((e[1] - t) * 100 + 0.5) / 100, e[2], e[3], e[4], e[5], e[6], e[7] }
            if e[2] == "d" then by = e[3] end
        end
    end
    if #cur.deaths < DEATHS_MAX then
        cur.deaths[#cur.deaths + 1] = { t = floor(t * 10 + 0.5) / 10, by = by, ring = recap }
    end
    if not cur.dead then
        -- alive time ends: the rest of the fight is not idle time
        cur.dead = floor(t * 10 + 0.5) / 10
        if busyUntil < now then busyUntil = now end
    end
    ring, ringPos = {}, 0
end

-- Resurrected (battle res, Soulstone, Reincarnation) during the pull: alive time continues.
local function OnAlive()
    if not cur or not cur.dead then return end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return end
    cur.deadFor = (cur.deadFor or 0) + ((Now() - t0) - cur.dead)
    cur.dead = nil
    busyUntil = Now()
end

---------------------------------------------------------------------------
-- Pull context: spec, role, talents, item level, boss health
---------------------------------------------------------------------------

local function TabPoints(tab)
    if not GetTalentTabInfo then return 0 end
    local r1, _, r3, _, r5 = GetTalentTabInfo(tab)
    local p = (type(r1) == "string") and tonumber(r3) or tonumber(r5)
    return p or 0
end

local function TalentString()
    local parts = {}
    local n = (GetNumTalentTabs and GetNumTalentTabs()) or 3
    for tab = 1, n do parts[#parts + 1] = tostring(TabPoints(tab)) end
    return table.concat(parts, "/")
end

local function MySpec(cls)
    local spec = ns.BiS and ns.BiS.DetectSpec and ns.BiS:DetectSpec() or ""
    if cls == "DRUID" and strsub(spec, 1, 5) == "Feral" and GetShapeshiftFormID then
        local form = GetShapeshiftFormID()
        if form == 5 or form == 8 then spec = "Feral (Bear)" else spec = "Feral (Cat)" end
    end
    return spec
end

-- Equipped item level: the average over the 17 gear slots (a two-hander counts twice when the off hand is empty, an
-- empty slot counts 0). nil while an item is not in the cache.
local GEAR_SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }
local function ItemLevel()
    if not (GetInventoryItemLink and GetItemInfo) then return nil end
    local total, count = 0, 0
    local mainLevel, mainTwoHand
    for _, slot in ipairs(GEAR_SLOTS) do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local _, _, _, ilvl, _, _, _, _, equipLoc = GetItemInfo(link)
            ilvl = tonumber(ilvl)
            if not ilvl then return nil end   -- not cached yet: no number beats a wrong one
            total = total + ilvl
            count = count + 1
            if slot == 16 then mainLevel, mainTwoHand = ilvl, equipLoc == "INVTYPE_2HWEAPON" end
        end
    end
    if count == 0 then return nil end
    local offhand = GetInventoryItemLink("player", 17)
    if mainTwoHand and not offhand then total = total + mainLevel end
    return floor(total / #GEAR_SLOTS * 10 + 0.5) / 10
end

local BOSS_UNITS = { "boss1", "boss2", "boss3", "boss4", "boss5" }
local function SampleBoss()
    if not cur or not UnitExists then return end
    local low
    for _, u in ipairs(BOSS_UNITS) do
        if UnitExists(u) then
            local hp, mx = UnitHealth(u), UnitHealthMax(u)
            if mx and mx > 0 and hp then
                local pct = hp / mx * 100
                if not low or pct < low then low = pct end
            end
        end
    end
    if low then cur.pct = floor(low * 10 + 0.5) / 10 end
end

local function SamplePower(now)
    if not cur or not UnitPower then return end
    local p, m = UnitPower("player"), UnitPowerMax("player")
    if m and m > 0 then cur.tl.p[Bucket(now)] = floor(p / m * 100 + 0.5) end
end

local function OnTick()
    if not cur then return end
    local now = Now()
    SamplePower(now)
    SampleBoss()
end

---------------------------------------------------------------------------
-- Pull lifecycle
---------------------------------------------------------------------------

-- Whether this instance is one I record: raids always, heroic 5-mans when mylog.heroics is on.
function MyLog:ShouldRecord()
    if not self:IsEnabled() or not GetInstanceInfo then return false end
    local _, instanceType, difficultyID = GetInstanceInfo()
    if instanceType == "raid" then return true end
    if instanceType == "party" and self:HeroicsOn() then
        return difficultyID == 2
    end
    return false
end

local listening = false
local function Listen(on)
    if on == listening then return end
    listening = on
    local fn = on and ns.RegisterEvent or ns.UnregisterEvent
    fn(ns, "COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)
    fn(ns, "UNIT_SPELLCAST_START", OnCastStart)
    fn(ns, "UNIT_SPELLCAST_DELAYED", OnCastDelayed)
    fn(ns, "UNIT_SPELLCAST_CHANNEL_START", OnChannelStart)
    fn(ns, "UNIT_SPELLCAST_CHANNEL_UPDATE", OnCastDelayed)
    fn(ns, "UNIT_SPELLCAST_INTERRUPTED", OnCastCut)
    fn(ns, "UNIT_SPELLCAST_FAILED", OnCastCut)
    fn(ns, "UNIT_SPELLCAST_CHANNEL_STOP", OnCastCut)
    fn(ns, "UNIT_SPELLCAST_SUCCEEDED", OnCastSucceeded)
    fn(ns, "PLAYER_ALIVE", OnAlive)
    fn(ns, "PLAYER_UNGHOST", OnAlive)
end

function MyLog:Start(encounterID, encounterName, difficultyID, groupSize)
    if cur then self:Stop(false) end
    myGUID = UnitGUID("player")
    local now = Now()
    t0 = now
    local name, instanceType, _, _, _, _, _, instanceID = GetInstanceInfo()
    local _, cls = UnitClass("player")
    cur = {
        at = GetServerTime(), enc = tonumber(encounterID), boss = encounterName, zone = name,
        iid = tonumber(instanceID), diff = tonumber(difficultyID), size = tonumber(groupSize),
        heroic = (instanceType == "party") or nil,
        cls = cls, spec = MySpec(cls), tal = TalentString(), ilvl = ItemLevel(), buffs = {},
        dmg = {}, pet = {}, heal = {}, shield = {}, taken = {}, names = {}, avoid = {}, healIn = {},
        casts = {}, kicks = {}, disp = {}, gain = {}, up = { me = {}, out = {} }, tgt = {},
        tl = { d = {}, h = {}, t = {}, p = {} }, gaps = {}, deaths = {},
    }
    cur.role = ns.GetSpecRole and ns.GetSpecRole(cls, cur.spec) or nil
    ring, ringPos = {}, 0
    auraOn = { me = {}, out = {} }
    busyUntil, covered, lastCastStart, castCover, castGcd = now, 0, nil, nil, nil
    SeedMyAuras(now)
    SamplePower(now)
    Listen(true)
    if C_Timer and C_Timer.NewTicker then ticker = C_Timer.NewTicker(1, OnTick) end
    ns:Fire("MYLOG_RECORDING", true)
end

local function Round(x, d)
    local m = 10 ^ (d or 0)
    return floor(x * m + 0.5) / m
end

local function Sum(tbl, field)
    local n = 0
    for _, s in pairs(tbl) do n = n + (s[field] or 0) end
    return n
end

-- Fills pull.s from the detail tables.
function MyLog:Summarize(p)
    local d = 0
    for _, tbl in ipairs({ p.dmg, p.pet }) do
        for _, s in pairs(tbl) do d = d + s.a - (s.o or 0) + (s.ab or 0) end
    end
    local h, oh, sh = Sum(p.heal, "a"), Sum(p.heal, "oh"), Sum(p.shield, "a")
    local t = 0
    local av = 0
    for key, s in pairs(p.taken) do
        local one = s.a - (s.o or 0) + (s.ab or 0)
        if s.m and s.m.ABSORB and s.mab then one = one + s.mab end   -- hits a shield took whole (MISSED ABSORB)
        t = t + one
        if MyLog:IsAvoidable(key) then av = av + one end
    end
    local dur = p.dur or 0
    local alive = max(dur - (p.deadFor or 0) - (p.dead and (dur - p.dead) or 0), 0.001)
    local casts = 0
    for _, n in pairs(p.casts or {}) do casts = casts + n end
    -- melee swings at me and how many I dodged, parried or that missed (blocks still hit)
    local swings, avoided = 0, 0
    for key, st in pairs(p.taken) do
        if strsub(key, 1, 1) == "m" then
            swings = swings + st.n
            for kind, n in pairs(st.m or {}) do
                swings = swings + n
                if kind == "DODGE" or kind == "PARRY" or kind == "MISS" then avoided = avoided + n end
            end
        end
    end
    p.s = {
        cpm = dur > 0 and Round(casts / dur * 60, 1) or 0, sw = swings, avd = avoided, av = Round(av),
        d = Round(d), h = Round(h), oh = Round(oh), sh = Round(sh), t = Round(t),
        act = p.actSec and Round(min(p.actSec / alive, 1), 4) or nil, dc = #p.deaths,
        dps = dur > 0 and Round(d / dur, 1) or 0, hps = dur > 0 and Round((h + sh) / dur, 1) or 0,
        dtps = dur > 0 and Round(t / dur, 1) or 0,
    }
    return p.s
end

-- Ends the pull. kill: true / false (wipe); cut: a /reload or logout ended it; discard: drop it unsaved.
function MyLog:Stop(discard, kill, cut)
    if not cur then return end
    local now = Now()
    if ticker then ticker:Cancel(); ticker = nil end
    Listen(false)
    local p = cur
    CloseAuras(now)
    SamplePower(now)
    SampleBoss()
    p.dur = Round(now - t0, 1)
    -- idle time at the end of the fight
    if not p.dead and now - busyUntil >= GAP_MIN and #p.gaps < GAPS_MAX then
        p.gaps[#p.gaps + 1] = { at = Round(busyUntil - t0, 1), len = Round(now - busyUntil, 1) }
    end
    p.actSec = Round(covered - max(busyUntil - now, 0), 1)
    for side, list in pairs(p.up) do
        for id, secs in pairs(list) do list[id] = Round(secs, 1) end
    end
    cur = nil
    if discard then
        ns:Fire("MYLOG_RECORDING", false)
        return
    end
    p.kill = kill and true or false
    p.cut = cut or nil
    if kill then p.pct = 0 end
    self:Summarize(p)
    local c = MyChar(true)
    c.n = (c.n or 0) + 1
    p.id = c.n
    c.pulls[#c.pulls + 1] = p
    self:Trim(c)
    ns:Fire("MYLOG_RECORDING", false)
    ns:Fire("MYLOG_CHANGED", p.id)
end

local DETAIL_FIELDS = { "dmg", "pet", "heal", "shield", "taken", "names", "avoid", "healIn", "casts", "kicks",
    "disp", "gain", "up", "tgt", "tl", "gaps", "deaths" }

-- Drops pulls older than keepWeeks and the detail of pulls past the newest DETAIL_KILLS kills / DETAIL_PULLS pulls of
-- their boss.
function MyLog:Trim(c)
    c = c or MyChar(false)
    if not c then return end
    local limit = GetServerTime() - self:KeepWeeks() * WEEK
    local kept = {}
    for _, p in ipairs(c.pulls) do
        if (p.at or 0) >= limit then kept[#kept + 1] = p end
    end
    c.pulls = kept
    local kills, pulls = {}, {}
    for i = #kept, 1, -1 do
        local p = kept[i]
        if p.dmg then
            local boss = p.enc or p.boss or "?"
            pulls[boss] = (pulls[boss] or 0) + 1
            if p.kill then kills[boss] = (kills[boss] or 0) + 1 end
            local keep = pulls[boss] <= DETAIL_PULLS or (p.kill and kills[boss] <= DETAIL_KILLS)
            if not keep then
                for _, f in ipairs(DETAIL_FIELDS) do p[f] = nil end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Queries for the My Log page: instances, runs (raid nights), boss rows, headline numbers
---------------------------------------------------------------------------

local RUN_BREAK = 6 * 3600        -- pulls of one instance further apart than this are different runs

-- The view a role leads with: "damage" | "healing" | "tanking".
local VIEW_OF_ROLE = { healer = "healing", tank = "tanking" }
function MyLog:ViewForRole(role) return VIEW_OF_ROLE[role or ""] or "damage" end

local function InstanceKey(p) return p.iid or p.zone or "?" end

-- Instances I have pulls in, newest first: { { key, name, at (last pull), heroic } }
function MyLog:GetInstances(charKey)
    local byKey, out = {}, {}
    for _, p in ipairs(self:GetPulls(charKey)) do
        local k = InstanceKey(p)
        local e = byKey[k]
        if not e then
            e = { key = k, name = p.zone or "?", at = 0, heroic = p.heroic }
            byKey[k] = e
            out[#out + 1] = e
        end
        if (p.at or 0) >= e.at then e.at = p.at or 0 end
    end
    table.sort(out, function(a, b) return a.at > b.at end)
    return out
end

-- Runs of one instance, newest first: { { at (first pull), last, pulls = { pull, ... } (in order), kills, wipes } }
function MyLog:GetRuns(instKey, charKey)
    local runs, cur = {}, nil
    for _, p in ipairs(self:GetPulls(charKey)) do
        if InstanceKey(p) == instKey then
            if not cur or (p.at or 0) - cur.last > RUN_BREAK then
                cur = { at = p.at or 0, last = p.at or 0, pulls = {}, kills = 0, wipes = 0 }
                runs[#runs + 1] = cur
            end
            cur.pulls[#cur.pulls + 1] = p
            cur.last = p.at or cur.last
            if p.kill then cur.kills = cur.kills + 1 elseif not p.cut then cur.wipes = cur.wipes + 1 end
        end
    end
    local out = {}
    for i = #runs, 1, -1 do out[#out + 1] = runs[i] end
    return out
end

-- The headline value of a pull for a view: damage = DPS, healing = HPS (heals + shields), tanking = damage taken
-- per second.
local METRIC = { damage = "dps", healing = "hps", tanking = "dtps" }
function MyLog:Metric(p, view)
    local s = p and p.s
    return s and s[METRIC[view] or "dps"] or nil
end

local function BossKey(p) return p.enc or p.boss or "?" end

-- Kills of p's boss before p (oldest first): those of p's spec when there are any (sameSpec = true), else all.
local function EarlierKills(pulls, p)
    local same, any = {}, {}
    for _, q in ipairs(pulls) do
        if q == p then break end
        if q.kill and not q.cut and BossKey(q) == BossKey(p) then
            any[#any + 1] = q
            if q.spec == p.spec then same[#same + 1] = q end
        end
    end
    if #same > 0 then return same, true end
    return any, #any == 0
end

local function Change(now, before)
    if not now or not before or before == 0 then return nil end
    return (now - before) / before * 100
end

-- One row per boss of a run (in first-pull order): { boss, enc, pulls (count), deaths, kill (the run's last kill |
-- nil), value, prev (the kill compared with), change (%), sameSpec, active (0..1), cpm, spark = { values of up to
-- 8 kills, this one last }, best (lowest boss % of the wipes, when there was no kill) }
function MyLog:BossRows(run, view, charKey)
    local all = self:GetPulls(charKey)
    local rows, byBoss = {}, {}
    for _, p in ipairs(run.pulls) do
        local k = BossKey(p)
        local r = byBoss[k]
        if not r then
            r = { boss = p.boss or "?", enc = p.enc, pulls = 0, deaths = 0 }
            byBoss[k] = r
            rows[#rows + 1] = r
        end
        r.pulls = r.pulls + 1
        r.deaths = r.deaths + ((p.s and p.s.dc) or 0)
        if p.kill and not p.cut then
            r.kill = p
        elseif not p.cut and p.pct and (not r.best or p.pct < r.best) then
            r.best = p.pct
        end
    end
    for _, r in ipairs(rows) do
        local p = r.kill
        if p then
            r.value = self:Metric(p, view)
            r.active = p.s and p.s.act
            r.cpm = p.s and p.s.cpm
            local earlier, sameSpec = EarlierKills(all, p)
            r.sameSpec = sameSpec
            r.prev = earlier[#earlier]
            r.change = r.prev and Change(r.value, self:Metric(r.prev, view)) or nil
            local spark = {}
            for i = max(1, #earlier - 6), #earlier do spark[#spark + 1] = self:Metric(earlier[i], view) end
            spark[#spark + 1] = r.value
            r.spark = spark
        end
    end
    return rows
end

local function AverageOf(pulls, fn)
    local total, n = 0, 0
    for _, p in ipairs(pulls) do
        local v = fn(p)
        if v then total = total + v; n = n + 1 end
    end
    return n > 0 and total / n or nil
end

-- A run's numbers: { value (average over its kills), active, taken (DTPS), overheal (0..1), avoid (0..1), deaths,
-- avoidable (damage from AVOIDABLE abilities, every pull), ilvl, kills }
function MyLog:RunNumbers(run, view)
    local kills = {}
    local deaths, swings, avoided, h, oh, av = 0, 0, 0, 0, 0, 0
    for _, p in ipairs(run.pulls) do
        if not p.cut and p.s then
            if p.kill then
                kills[#kills + 1] = p
                h = h + (p.s.h or 0) + (p.s.sh or 0)
                oh = oh + (p.s.oh or 0)
            end
            deaths = deaths + (p.s.dc or 0)
            av = av + (p.s.av or 0)
            swings = swings + (p.s.sw or 0)
            avoided = avoided + (p.s.avd or 0)
        end
    end
    return {
        value = AverageOf(kills, function(p) return self:Metric(p, view) end),
        active = AverageOf(kills, function(p) return p.s.act end),
        taken = AverageOf(kills, function(p) return p.s.dtps end),
        overheal = (h + oh) > 0 and oh / (h + oh) or nil,
        avoid = swings > 0 and avoided / swings or nil,
        deaths = deaths,
        avoidable = av,
        ilvl = AverageOf(run.pulls, function(p) return p.ilvl end),
        kills = #kills,
    }
end

-- The spec I played most in a run, and its role.
function MyLog:RunSpec(run)
    local count, best, bestN = {}, nil, 0
    for _, p in ipairs(run.pulls) do
        local k = p.spec or ""
        count[k] = (count[k] or 0) + 1
        if count[k] > bestN then best, bestN = p, count[k] end
    end
    return best and best.spec, best and best.role
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function OnEncounterStart(_, encounterID, encounterName, difficultyID, groupSize)
    if not MyLog:ShouldRecord() then return end
    MyLog:Start(encounterID, encounterName, difficultyID, groupSize)
end

local function OnEncounterEnd(_, encounterID, _, _, _, success)
    if not cur then return end
    if cur.enc and encounterID and tonumber(encounterID) ~= cur.enc then return end
    MyLog:Stop(false, success == 1 or success == true)
end

function MyLog:OnInit()
    Store()
end

function MyLog:OnLogin()
    ns:RegisterEvent("ENCOUNTER_START", OnEncounterStart)
    ns:RegisterEvent("ENCOUNTER_END", OnEncounterEnd)
    ns:RegisterEvent("PLAYER_LOGOUT", function()
        if cur then MyLog:Stop(false, false, true) end
    end)
    ns:On("SETTINGS_CHANGED", function(path)
        if path == "mylog.enabled" and not MyLog:IsEnabled() and cur then MyLog:Stop(true) end
    end)
    self:Trim()
end

---------------------------------------------------------------------------
-- Slash: /dz mylog [on | off | last]
---------------------------------------------------------------------------

local function Short(n)
    n = tonumber(n) or 0
    if n >= 1e6 then return strformat("%.2fm", n / 1e6) end
    if n >= 1e4 then return strformat("%.1fk", n / 1e3) end
    return tostring(floor(n + 0.5))
end

function MyLog:Describe(p)
    local s = p.s or {}
    local result = p.kill and "kill" or (p.cut and "cut short" or strformat("wipe at %s%%", tostring(p.pct or "?")))
    return strformat("%s (%s, %ds): %s DPS, %s HPS (+%s overheal), %s taken, %s%% active, %d death(s)",
        tostring(p.boss or "?"), result, floor(p.dur or 0), Short(s.dps), Short(s.hps), Short(s.oh), Short(s.t),
        s.act and strformat("%.1f", s.act * 100) or "?", s.dc or 0)
end

ns:RegisterSlash("mylog", function(rest)
    rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "on" or rest == "off" then
        ns.DB:SetSetting("mylog.enabled", rest == "on")
        ns:Print("My Log is %s.", rest == "on" and "on: boss pulls are recorded for you alone" or "off")
        return
    end
    local pulls = MyLog:GetPulls()
    if rest == "last" then
        local p = pulls[#pulls]
        if not p then ns:Print("My Log has no pulls yet.") return end
        ns:Print(MyLog:Describe(p))
        return
    end
    ns:Print("My Log is %s. %d pull(s) stored for this character. /dz mylog on | off | last",
        MyLog:IsEnabled() and "on" or "off", #pulls)
end, "My Log: your own boss-pull records (on | off | last)")

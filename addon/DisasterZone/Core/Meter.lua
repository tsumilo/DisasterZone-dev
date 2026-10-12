if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Meter.lua", ...) then return end -- DisasterZone: damage meter recorder.
-- Counts what the client's combat log sees for everyone in my group, fight by fight: damage done, healing (with
-- overhealing and shields), damage taken, deaths (with a recap), interrupts, dispels and active time. The panels are
-- UI/MeterPanels.lua, the breakdown and death recap UI/MeterDetail.lua. Off until the player turns it on (Settings >
-- Meters, meters.dmg). Nothing is ever sent or posted: each client counts its own combat log.
--
-- Counting (Details' rules, so the numbers match what raiders are used to; checked in game 2026-10-10):
--   damage done   = amount + absorbed (the whole hit, overkill included, shields included); hits on other group
--                   members (Seal of Blood's self damage, ...) never count as damage done. (My Log counts the same
--                   way since 1.4: overkill counts in damage everywhere.)
--   healing       = amount - overhealing (effective) + shield absorbs (SPELL_ABSORBED, credited to the caster);
--                   overhealing kept apart
--   damage taken  = amount + absorbed, and hits a shield took whole (MISSED ABSORB)
-- Who: group members by GUID (the roster, rebuilt on GROUP_ROSTER_UPDATE); pets, guardians and totems count for their
-- owner (raidNpet / partyNpet / pet, and SPELL_SUMMON from a member or one of their pets). Another player's pet whose
-- owner is unknown is left out rather than guessed.
-- Active time (Details' activity time): the gaps between a player's own actions up to IDLE seconds count, longer
-- gaps do not. Per second divides by the fight's length (meters.rate "fight", the default) or by it ("active").
-- A fight's clock runs from its first hit to its last (a boss fight: ENCOUNTER_START to ENCOUNTER_END).
-- Spec: guessed from signature spells (SIG: talents or spells only one spec casts), remembered by name.
--
-- The combat log comes from Core/CombatLog.lua (one reader for Meters, My Log and the swing timer), and so does the
-- death recap's ring.
--
-- Fights: one starts when a group member hits or is hit by an enemy (or I enter combat) and ends when the whole group
-- has been out of combat END_QUIET seconds. A boss fight runs from ENCOUNTER_START to ENCOUNTER_END (a trash fight
-- that began at most MERGE_START seconds before the pull becomes the boss fight). With meters.split = "boss" the
-- trash between two bosses adds up in one fight. "Whole raid" (all) adds up every fight inside the same instance (a
-- new instance starts a new one).
--
-- Data (SavedVariables DisasterZoneMeterDB, never synced):
--   { v = 1, segs = { seg, ... } (oldest first, at most meters.keep), all = seg, specs = { [name] = spec } }
--   seg = { id, kind = "boss" | "trash" | "all", name, enc, kill, pct (boss health % at a wipe), at (server time),
--           zone, iid, itype (instance type), dur (s), live (being recorded), cut (a /reload ended it),
--           actors = { [guid] = actor }, foes = { [name] = damage }, deaths = { death, ... } }
--   actor = { n (name), c (class file), s (spec label), d, h, oh, t, k, dp, act (s), (a stat's nc: it cannot crit)
--             sp = { [key] = { n, c, a, ca, g, ga, mx, m = { [missType] = n } } } damage by ability (key: spell id,
--                  0 = melee, "p<id>" a pet's), pn = { [key] = pet name }, hs = { [key] = { n, c, a, oh, mx, sh } }
--                  healing by spell (sh: a shield), ts = { [key] = { n, a, mx, src } } taken by ability, tg = { [name] =
--                  damage } by target, tl / hl = { [5 s bucket] = damage / healing }, ks / kx = { [spell id] = n }
--                  interrupts by my spell / by the spell cut, ds / dx = dispels by my spell / by the aura removed }
--   death = { t (s into the fight), g, n, c, by (key), byName, src, hpMax, ev = { { dt, kind "d" | "h", key, amount,
--             src, hp, extra (overkill / overheal) } } (the last RECAP seconds, oldest first) }
local addonName, ns = ...

local Meter = ns:NewModule("Meter")
local CL = ns.CombatLog
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, next, select = type, pairs, ipairs, tonumber, tostring, next, select
local floor, max, min = math.floor, math.max, math.min
local strsub, strformat = string.sub, string.format
local tsort, tremove = table.sort, table.remove
local band = bit and bit.band

local BUCKET = 5                  -- timeline bucket, seconds
local IDLE = 5                    -- active time: gaps up to this long count (3.5 cut slow two-handers' swing gaps)
local RING = 48                   -- death recap: events per player kept while fighting
local RECAP = 10                  -- seconds a recap shows
local DEATHS_MAX = 60             -- deaths kept per fight
local MERGE_START = 4             -- ENCOUNTER_START this soon after a trash fight began: it becomes the boss fight
local END_QUIET = 2               -- the group out of combat this long ends a trash fight
local BOSS_QUIET = 12             -- ... and a boss fight that never got its ENCOUNTER_END (a reset)
local TICK = 0.5
Meter.BUCKET, Meter.RECAP = BUCKET, RECAP

-- Combat log flags
local AFFIL_GROUP = 0x00000007    -- mine | party | raid
local TYPE_PLAYER = 0x00000400

-- Modes the window shows (key, label, icon)
Meter.MODES = {
    { key = "damage", label = "Damage done", icon = "Interface\\Icons\\Ability_Warrior_SavageBlow" },
    { key = "dps", label = "DPS", icon = "Interface\\Icons\\Spell_Nature_BloodLust" },
    { key = "healing", label = "Healing", icon = "Interface\\Icons\\Spell_Holy_FlashHeal", group = true },
    { key = "taken", label = "Damage taken", icon = "Interface\\Icons\\Ability_Warrior_DefensiveStance", group = true },
    { key = "deaths", label = "Deaths", icon = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01" },
    { key = "kicks", label = "Interrupts", icon = "Interface\\Icons\\Ability_Kick", group = true },
    { key = "dispels", label = "Dispels", icon = "Interface\\Icons\\Spell_Holy_DispelMagic" },
    { key = "active", label = "Active time", icon = "Interface\\Icons\\Spell_Holy_BlessingOfStrength" },
}
Meter.MODE = {}
for _, m in ipairs(Meter.MODES) do Meter.MODE[m.key] = m end

-- Signature spells (rank 1 ids; matched by their localized names): the spec of whoever casts them
local SIG = {
    WARRIOR = { [12294] = "Arms", [23881] = "Fury", [29801] = "Fury", [23922] = "Protection", [20243] = "Protection" },
    PALADIN = { [35395] = "Retribution", [20066] = "Retribution", [20375] = "Retribution", [20473] = "Holy",
                [31935] = "Protection", [20925] = "Protection" },
    HUNTER = { [19574] = "Beast Mastery", [34692] = "Beast Mastery", [19506] = "Marksmanship", [34490] = "Marksmanship",
               [19386] = "Survival", [34503] = "Survival" },
    ROGUE = { [1329] = "Assassination", [14177] = "Assassination", [13877] = "Combat", [13750] = "Combat",
              [16511] = "Subtlety", [36554] = "Subtlety" },
    PRIEST = { [15473] = "Shadow", [34914] = "Shadow", [15407] = "Shadow", [34861] = "Holy", [33206] = "Discipline",
               [10060] = "Discipline" },
    SHAMAN = { [17364] = "Enhancement", [30823] = "Enhancement", [16166] = "Elemental", [30706] = "Elemental",
               [974] = "Restoration", [16190] = "Restoration" },
    MAGE = { [12042] = "Arcane", [31589] = "Arcane", [11129] = "Fire", [31661] = "Fire", [11113] = "Fire",
             [12472] = "Frost", [31687] = "Frost", [11426] = "Frost" },
    WARLOCK = { [30108] = "Affliction", [18265] = "Affliction", [30146] = "Demonology", [19028] = "Demonology",
                [17962] = "Destruction", [17877] = "Destruction", [30283] = "Destruction" },
    DRUID = { [33876] = "Feral (Cat)", [5221] = "Feral (Cat)", [33878] = "Feral (Bear)", [6807] = "Feral (Bear)",
              [33745] = "Feral (Bear)", [24858] = "Balance", [2912] = "Balance", [18562] = "Restoration",
              [33763] = "Restoration", [33891] = "Restoration" },
}
local sigByName                   -- [class] = { [localized name] = spec }, built on first use

-- State (while listening)
local roster = {}                 -- [guid] = { unit, name, cls }
local owner = {}                  -- [pet / guardian guid] = owner guid
local live                        -- the fight being recorded (also the newest of db.segs)
local rings = {}                  -- [guid] = the death recap's ring (CL.NewRing)
local quiet = 0
local ticker
local listening = false
local listeners = {}

---------------------------------------------------------------------------
-- Settings and storage
---------------------------------------------------------------------------

local function Setting(path, default)
    local v = ns.DB and ns.DB.GetSetting and ns.DB:GetSetting("meters." .. path)
    if v == nil then return default end
    return v
end
Meter.Setting = Setting

function Meter:IsEnabled() return Setting("dmg", false) and true or false end
function Meter:IsDemo() return Util.DemoOn() and ns.MeterDemo ~= nil end

local function Store()
    if type(DisasterZoneMeterDB) ~= "table" or DisasterZoneMeterDB.v ~= 1 then
        DisasterZoneMeterDB = { v = 1, segs = {}, specs = {} }
    end
    local db = DisasterZoneMeterDB
    if type(db.segs) ~= "table" then db.segs = {} end
    if type(db.specs) ~= "table" then db.specs = {} end
    return db
end

-- What the window shows: my fights, or the demo's while demo mode is on.
function Meter:Data()
    if self:IsDemo() then return ns.MeterDemo:Data() end
    return Store()
end

function Meter:OnChange(fn) listeners[#listeners + 1] = fn end
local function Changed(what)
    for _, fn in ipairs(listeners) do pcall(fn, what) end
end
Meter.Changed = Changed

---------------------------------------------------------------------------
-- Fights
---------------------------------------------------------------------------

local Now = CL.Now
local ServerTime = Util.Now

local function NewSeg(kind)
    local db = Store()
    db.n = (db.n or 0) + 1
    local inInst, itype = false, nil
    if IsInInstance then inInst, itype = IsInInstance() end
    local zone, iid
    if GetInstanceInfo then
        local name, _, _, _, _, _, _, id = GetInstanceInfo()
        zone, iid = name, id
    end
    return { id = db.n, kind = kind, at = ServerTime(), zone = zone or (GetRealZoneText and GetRealZoneText()),
             iid = inInst and iid or nil, itype = inInst and itype or nil, dur = 0, actors = {}, foes = {},
             deaths = {}, size = GetNumGroupMembers and max(1, GetNumGroupMembers()) or 1 }
end

-- The seconds a fight has run (a live one: up to now).
function Meter:Duration(seg)
    if not seg then return 0 end
    if seg.live and seg._t0 then return max(0.001, Now() - seg._t0) end
    local d = tonumber(seg.dur) or 0
    if seg.kind == "all" and live and live._t0 and seg == Store().all then
        d = d + max(0, Now() - live._t0 - (live._base or 0))           -- the fight running now counts too
    end
    return max(0.001, d)
end

function Meter:GetLive()
    if self:IsDemo() then return nil end
    return live
end

-- Fights for the menu: newest first (the live one on top), then "all".
function Meter:GetFights()
    local d = self:Data()
    local out = {}
    for i = #(d.segs or {}), 1, -1 do out[#out + 1] = d.segs[i] end
    return out, d.all
end

-- sel: "cur" (the live fight, else the newest), "all", or a fight id.
function Meter:GetSegment(sel)
    local d = self:Data()
    local segs = d.segs or {}
    if sel == "all" then return d.all end
    if sel == nil or sel == "cur" then return segs[#segs] end
    for i = #segs, 1, -1 do if segs[i].id == sel then return segs[i] end end
    return segs[#segs]
end

-- A fight's name: the boss, else the enemy that took the most damage (+n other kinds).
function Meter:SegName(seg)
    if not seg then return "No fights yet" end
    if seg.kind == "all" then
        if seg.itype == "raid" then return "Whole raid" end
        if seg.itype == "party" then return "Whole dungeon" end
        return "All fights"
    end
    if seg.kind == "boss" then return seg.name or "Boss" end
    local top, topV, n = nil, -1, 0
    for name, v in pairs(seg.foes or {}) do
        n = n + 1
        if v > topV then top, topV = name, v end
    end
    if not top then return "Trash" end
    if n > 1 then return strformat("%s +%d", top, n - 1) end
    return top
end

local function Trim(db)
    local keep = tonumber(Setting("keep", 25)) or 25
    while #db.segs > keep do
        if db.segs[1].live then break end
        tremove(db.segs, 1)
    end
end

local function InstanceKey()
    local inInst = IsInInstance and IsInInstance()
    if not inInst then return "world" end
    local _, _, _, _, _, _, _, id = GetInstanceInfo()
    return id or "?"
end

local function EnsureAll(db)
    local key = InstanceKey()
    if not db.all or db.all.key ~= key then
        db.all = NewSeg("all")
        db.all.key = key
        db.all.noTl = true
    end
    return db.all
end

local function Begin(kind)
    local db = Store()
    local all = EnsureAll(db)
    local last = db.segs[#db.segs]
    if kind == "trash" and Setting("split", "all") == "boss" and last and last.kind == "trash" and not last.live
        and (last.iid or "world") == InstanceKey() then
        live = last                                   -- the trash between two bosses adds up in one fight
        live._t0 = Now() - (last.dur or 0)
        live._base = last.dur or 0
        live._fresh = true
    else
        live = NewSeg(kind)
        live._t0 = Now()
        live._base = 0
        live._fresh = kind == "trash"           -- a trash fight's clock starts at its first hit
        db.segs[#db.segs + 1] = live
    end
    live.live = true
    quiet = 0
    Trim(db)
    Changed("start")
    return live
end

local function Strip(seg)
    seg._t0, seg._base, seg._last, seg._fresh = nil, nil, nil, nil
    for _, a in pairs(seg.actors) do a._l = nil end
end

local function BossPct()
    if UnitExists and UnitExists("boss1") and UnitHealthMax then
        local m = UnitHealthMax("boss1") or 0
        if m > 0 then return floor((UnitHealth("boss1") or 0) / m * 1000 + 0.5) / 10 end
    end
    return nil
end

function Meter:Finish(kill, cut)
    if not live then return end
    local db = Store()
    local seg = live
    live = nil
    local stop = (not cut and seg.kind ~= "boss" and seg._last) or Now()   -- trash: up to the last hit
    local dur = max(0, stop - (seg._t0 or stop))
    local added = dur - (seg._base or 0)
    seg.dur = floor(dur * 10 + 0.5) / 10
    seg.live = nil
    if cut then seg.cut = true end
    if seg.kind == "boss" then
        seg.kill = kill and true or false
        if not kill then seg.pct = seg.pct or BossPct() end
    end
    Strip(seg)
    if db.all then
        db.all.dur = (db.all.dur or 0) + max(0, added)
        Strip(db.all)
    end
    -- a trash fight nobody hit anything in (a pull that went nowhere) is dropped
    if seg.kind == "trash" and not next(seg.foes) and #seg.deaths == 0 then
        for i = #db.segs, 1, -1 do if db.segs[i] == seg then tremove(db.segs, i) break end end
    end
    wipe(rings)
    Changed("end")
end

function Meter:IsRecording() return live ~= nil end

function Meter:ClearAll()
    local db = Store()
    local keepLive = live
    db.segs = keepLive and { keepLive } or {}
    db.all = nil
    if keepLive then EnsureAll(db) end
    Changed("clear")
end

---------------------------------------------------------------------------
-- The group
---------------------------------------------------------------------------

local function AddUnit(unit)
    local guid = UnitGUID and UnitGUID(unit)
    if not guid then return end
    local name = UnitName(unit)
    local _, cls = UnitClass(unit)
    roster[guid] = { unit = unit, name = name, cls = cls }
    local petUnit = (unit == "player") and "pet" or (unit:gsub("^(%a+)(%d+)$", "%1pet%2"))
    local pg = UnitGUID and UnitGUID(petUnit)
    if pg then owner[pg] = guid end
end

function Meter:RebuildRoster()
    wipe(roster)
    AddUnit("player")
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    if IsInRaid and IsInRaid() then
        for i = 1, n do AddUnit("raid" .. i) end
    elseif n > 0 then
        for i = 1, n - 1 do AddUnit("party" .. i) end
    end
end
function Meter:GetRoster() return roster end

-- The actor GUID an event's source counts for (a group member, or the owner of their pet), and whether it was a pet.
local function Who(guid)
    if not guid then return nil end
    if roster[guid] then return guid, false end
    local o = owner[guid]
    local depth = 0
    while o and not roster[o] and depth < 3 do o = owner[o]; depth = depth + 1 end
    if o and roster[o] then return o, true end
    return nil
end
Meter.Who = Who

local function InGroup(guid) return guid ~= nil and (roster[guid] ~= nil or owner[guid] ~= nil) end

local function GroupInCombat()
    if UnitAffectingCombat and UnitAffectingCombat("player") then return true end
    for _, r in pairs(roster) do
        if r.unit ~= "player" and UnitAffectingCombat(r.unit) then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Spec from signature spells
---------------------------------------------------------------------------

local function SigNames(cls)
    if not sigByName then
        sigByName = {}
        for c, list in pairs(SIG) do
            local t = {}
            for id, spec in pairs(list) do
                local n = GetSpellInfo and GetSpellInfo(id)
                if n then t[n] = spec end
            end
            sigByName[c] = t
        end
    end
    return sigByName[cls]
end

local function NoteSpell(guid, spellName)
    local r = roster[guid]
    if not r or not spellName then return end
    local db = Store()
    if db.specs[r.name] and r.spec then return end
    local t = r.cls and SigNames(r.cls)
    local spec = t and t[spellName]
    if spec and r.spec ~= spec then
        r.spec = spec
        db.specs[r.name] = spec
        if live and live.actors[guid] then live.actors[guid].s = spec end
        if db.all and db.all.actors[guid] then db.all.actors[guid].s = spec end
    end
end

function Meter:SpecOf(name)
    local db = Store()
    return db.specs[name]
end

---------------------------------------------------------------------------
-- Counting
---------------------------------------------------------------------------

local function Actor(seg, guid)
    local a = seg.actors[guid]
    if not a then
        local r = roster[guid]
        local db = Store()
        a = { n = r and r.name or "?", c = r and r.cls, s = r and (r.spec or db.specs[r.name]), d = 0, h = 0, oh = 0,
              t = 0, k = 0, dp = 0, act = 0, sp = {}, hs = {}, ts = {}, tg = {}, tl = {}, hl = {} }
        -- the main hand's icon for the Melee row (other players' only when the client has seen their gear)
        local wi = r and GetInventoryItemTexture and GetInventoryItemTexture(r.unit, 16)
        if wi then a.wi = wi end
        seg.actors[guid] = a
    end
    return a
end

local function Touch(a, now)
    local last = a._l
    if last and now - last <= IDLE then a.act = a.act + (now - last) end
    a._l = now
end

local function Bucket(seg, now) return floor((now - (seg._t0 or now)) / BUCKET) + 1 end

local function Each(fn, ...)
    if live then fn(live, ...) end
    local all = Store().all
    if all then fn(all, ...) end
end

local function DoneTo(seg, g, isPet, petName, key, amount, overkill, absorbed, crit, glancing, dstName, now, noCrit)
    local a = Actor(seg, g)
    amount = amount or 0
    local useful = amount + (absorbed or 0)
    if useful < 0 then useful = 0 end
    a.d = a.d + useful
    if isPet then key = "p" .. tostring(key) end
    local s = a.sp[key]
    if not s then
        s = { n = 0, c = 0, a = 0 }
        a.sp[key] = s
        if isPet then a.pn = a.pn or {}; a.pn[key] = petName end
    end
    s.n = s.n + 1
    s.a = s.a + useful
    if crit then s.c = s.c + 1; s.ca = (s.ca or 0) + useful end
    if glancing then s.g = (s.g or 0) + 1; s.ga = (s.ga or 0) + useful end
    if noCrit then s.nc = true end
    if useful > (s.mx or 0) then s.mx = useful end
    if dstName then
        a.tg[dstName] = (a.tg[dstName] or 0) + useful
        seg.foes[dstName] = (seg.foes[dstName] or 0) + useful
    end
    if not seg.noTl then
        local b = Bucket(seg, now)
        a.tl[b] = (a.tl[b] or 0) + useful
    end
    Touch(a, now)
end

local function MissedBy(seg, g, isPet, petName, key, missType, now)
    local a = Actor(seg, g)
    if isPet then key = "p" .. tostring(key) end
    local s = a.sp[key]
    if not s then
        s = { n = 0, c = 0, a = 0 }
        a.sp[key] = s
        if isPet then a.pn = a.pn or {}; a.pn[key] = petName end
    end
    s.m = s.m or {}
    missType = missType or "MISS"
    s.m[missType] = (s.m[missType] or 0) + 1
    Touch(a, now)
end

local function HealBy(seg, g, isPet, petName, key, eff, over, crit, now, shield, noCrit)
    local a = Actor(seg, g)
    a.h = a.h + eff
    a.oh = a.oh + (over or 0)
    if isPet then key = "p" .. tostring(key) end
    local s = a.hs[key]
    if not s then
        s = { n = 0, c = 0, a = 0, oh = 0 }
        a.hs[key] = s
        if isPet then a.pn = a.pn or {}; a.pn[key] = petName end
    end
    s.n = s.n + 1
    s.a = s.a + eff
    s.oh = s.oh + (over or 0)
    if shield then s.sh = true end
    if noCrit then s.nc = true end
    if crit then s.c = s.c + 1 end
    if eff > (s.mx or 0) then s.mx = eff end
    if not seg.noTl then
        local b = Bucket(seg, now)
        a.hl[b] = (a.hl[b] or 0) + eff
    end
    if not shield then Touch(a, now) end
end

local function TakenBy(seg, g, key, amount, srcName)
    local a = Actor(seg, g)
    a.t = a.t + amount
    local s = a.ts[key]
    if not s then s = { n = 0, a = 0 }; a.ts[key] = s end
    s.n = s.n + 1
    s.a = s.a + amount
    if amount > (s.mx or 0) then s.mx = amount end
    if srcName and not s.src then s.src = srcName end
end

local function CountIn(seg, g, field, byField, byKey, cutField, cutKey, now)
    local a = Actor(seg, g)
    a[field] = a[field] + 1
    a[byField] = a[byField] or {}
    a[byField][byKey] = (a[byField][byKey] or 0) + 1
    if cutKey then
        a[cutField] = a[cutField] or {}
        a[cutField][cutKey] = (a[cutField][cutKey] or 0) + 1
    end
    Touch(a, now)
end

-- The death recap's ring: what happened to a group member (damage taken, heals received) with their health after.
local function Push(guid, now, kind, key, amount, srcName, extra)
    local r = roster[guid]
    if not r then return end
    local ring = rings[guid]
    if not ring then ring = CL.NewRing(RING); rings[guid] = ring end
    CL.Push(ring, now, kind, key, amount, srcName, UnitHealth and UnitHealth(r.unit) or 0, extra)
end

local function NoteDeath(guid, now)
    local r = roster[guid]
    if not r or not live then return end
    if UnitIsFeignDeath and UnitIsFeignDeath(r.unit) then return end
    local ring = rings[guid]
    local ev, by, src
    if ring then
        ev, by, src = CL.Recap(ring, now, RECAP + 0.05, 10)       -- oldest first, times to the tenth
        rings[guid] = nil
    else
        ev = {}
    end
    local hpMax = UnitHealthMax and UnitHealthMax(r.unit) or 0
    Each(function(seg)
        if #seg.deaths >= DEATHS_MAX then return end
        local t = seg._t0 and (now - seg._t0) or 0
        if seg.kind == "all" then t = Meter:Duration(seg) end
        seg.deaths[#seg.deaths + 1] = { t = floor(t * 10 + 0.5) / 10, g = guid, n = r.name, c = r.cls, by = by,
            src = src, hpMax = hpMax, ev = ev }
    end)
end

local SPELL_DAMAGE = {
    SPELL_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true, RANGE_DAMAGE = true, DAMAGE_SHIELD = true,
    DAMAGE_SPLIT = true, SPELL_BUILDING_DAMAGE = true,
}
local SPELL_MISSED = {
    SPELL_MISSED = true, SPELL_PERIODIC_MISSED = true, RANGE_MISSED = true, DAMAGE_SHIELD_MISSED = true,
}
local HEAL = { SPELL_HEAL = true, SPELL_PERIODIC_HEAL = true }
-- Hits that cannot crit in TBC (left out of the crit chance, marked "can't crit"): periodic ticks (DoTs, HoTs, Ignite,
-- Deep Wounds, channels), damage shields (Retribution Aura, Thorns) and Consecration.
local NO_CRIT_SUB = { SPELL_PERIODIC_DAMAGE = true, DAMAGE_SHIELD = true, SPELL_PERIODIC_HEAL = true }
local noCritNames
local function CannotCrit(sub, spellName)
    if NO_CRIT_SUB[sub] then return true end
    if not noCritNames then
        noCritNames = {}
        local n = GetSpellInfo and GetSpellInfo(26573)              -- Consecration
        if n then noCritNames[n] = true end
    end
    return spellName ~= nil and noCritNames[spellName] == true
end
Meter.CannotCrit = CannotCrit
local CAST = { SPELL_CAST_SUCCESS = true, SPELL_AURA_APPLIED = true, SPELL_CAST_START = true }

local function IsHostileHit(sub)
    return sub == "SWING_DAMAGE" or SPELL_DAMAGE[sub] or sub == "SWING_MISSED" or SPELL_MISSED[sub]
end

-- One combat-log event (a Core/CombatLog.lua subscriber: the event name, then the client's payload).
local function OnCLEU(_, _, sub, _, srcGUID, srcName, srcFlags, _, dstGUID, dstName, dstFlags, _, a12, a13, a14, a15,
                      a16, a17, a18, a19, a20, a21, a22, a23)
    local g, isPet = Who(srcGUID)
    local toMember = dstGUID ~= nil and roster[dstGUID] ~= nil
    if sub == "SPELL_SUMMON" then
        if g and dstGUID then owner[dstGUID] = srcGUID end
        return
    end
    if not g and not toMember then return end
    -- a fight starts with the first hit between the group and someone outside it
    if not live then
        if not IsHostileHit(sub) then return end
        if g and InGroup(dstGUID) then return end
        if toMember and not g and InGroup(srcGUID) then return end
        Begin("trash")
    end
    local now = Now()
    if live._fresh then
        live._t0 = now - (live._base or 0)
        live._fresh = nil
    end
    live._last = now
    local petName = isPet and srcName or nil
    local dstOut = not InGroup(dstGUID)

    if sub == "SWING_DAMAGE" then
        if g and dstOut then Each(DoneTo, g, isPet, petName, 0, a12, a13, a17, a18, a19, dstName, now) end
        if toMember then
            local amt = (a12 or 0) + (a17 or 0)
            local key = "m" .. tostring(srcName or "?")
            Each(TakenBy, dstGUID, key, amt, srcName)
            Push(dstGUID, now, "d", key, a12 or 0, srcName, (a13 and a13 > 0) and a13 or nil)
        end
    elseif SPELL_DAMAGE[sub] then
        if g and dstOut then
            Each(DoneTo, g, isPet, petName, a12 or 0, a15, a16, a20, a21, a22, dstName, now, CannotCrit(sub, a13))
            if not isPet then NoteSpell(g, a13) end
        end
        if toMember then
            local amt = (a15 or 0) + (a20 or 0)
            local key = a12 or 0
            Each(TakenBy, dstGUID, key, amt, srcName)
            Push(dstGUID, now, "d", key, a15 or 0, srcName, (a16 and a16 > 0) and a16 or nil)
        end
    elseif sub == "ENVIRONMENTAL_DAMAGE" then
        if toMember then
            local amt = (a13 or 0) + (a18 or 0)
            local key = "e" .. tostring(a12 or "?")
            Each(TakenBy, dstGUID, key, amt, nil)
            Push(dstGUID, now, "d", key, a13 or 0, nil, (a14 and a14 > 0) and a14 or nil)
        end
    elseif sub == "SWING_MISSED" then
        if g and dstOut then Each(MissedBy, g, isPet, petName, 0, a12, now) end
        if toMember and a12 == "ABSORB" and a14 then
            Each(TakenBy, dstGUID, "m" .. tostring(srcName or "?"), a14, srcName)
        end
    elseif SPELL_MISSED[sub] then
        if g and dstOut then Each(MissedBy, g, isPet, petName, a12 or 0, a15, now) end
        if toMember and a15 == "ABSORB" and a17 then Each(TakenBy, dstGUID, a12 or 0, a17, srcName) end
    elseif HEAL[sub] then
        local amount, over = a15 or 0, a16 or 0
        local eff = amount - over
        if eff < 0 then eff = 0 end
        if g then
            Each(HealBy, g, isPet, petName, a12 or 0, eff, over, a18, now, nil, CannotCrit(sub, a13))
            if not isPet then NoteSpell(g, a13) end
        end
        if toMember and eff > 0 then Push(dstGUID, now, "h", a12 or 0, eff, srcName, over > 0 and over or nil) end
    elseif sub == "SPELL_ABSORBED" then
        local cGUID, absId, amount
        if type(a12) == "string" then cGUID, absId, amount = a12, a16, a19
        else cGUID, absId, amount = a15, a19, a22 end
        local cg, cPet = Who(cGUID)
        if cg and amount and amount > 0 then Each(HealBy, cg, cPet, nil, absId or 0, amount, 0, false, now, true) end
    elseif sub == "SPELL_INTERRUPT" then
        if g then Each(CountIn, g, "k", "ks", a12 or 0, "kx", a15, now) end
    elseif sub == "SPELL_DISPEL" or sub == "SPELL_STOLEN" then
        if g then Each(CountIn, g, "dp", "ds", a12 or 0, "dx", a15, now) end
    elseif CAST[sub] then
        if g and not isPet then
            NoteSpell(g, a13)
            if sub == "SPELL_CAST_SUCCESS" then
                -- a cast is activity in the fight and in Whole raid alike (only counting it in the fight made Whole
                -- raid's active time shorter, so its DPS came out above every single fight's; in-game report)
                Each(function(seg) local a = seg.actors[g]; if a then Touch(a, now) end end)
            end
        end
    elseif sub == "UNIT_DIED" then
        if toMember and dstFlags and band and band(dstFlags, TYPE_PLAYER) ~= 0 then NoteDeath(dstGUID, now) end
    end
end

-- The event the client is handing out now, counted (what the reader does for every event).
function Meter:OnCombatLog() return OnCLEU(CL.EVENT, CombatLogGetCurrentEventInfo()) end

---------------------------------------------------------------------------
-- Rows for the window
---------------------------------------------------------------------------

-- The rows of a mode: { { g, a (actor), v (sorted value), ext (overhealing), d (death) } }, highest first, and the
-- fight's total. Kept here so the window and the tests read the same numbers.
function Meter:Rows(seg, mode)
    local rows = {}
    if not seg then return rows, 0 end
    local dur = self:Duration(seg)
    local total = 0
    if mode == "deaths" then
        for i = #seg.deaths, 1, -1 do
            local d = seg.deaths[i]
            local a = seg.actors[d.g] or { n = d.n, c = d.c }
            rows[#rows + 1] = { g = d.g, a = a, v = d.t, d = d }
        end
        return rows, #seg.deaths
    end
    for g, a in pairs(seg.actors) do
        local v, ext
        if mode == "damage" then v = a.d
        elseif mode == "dps" then v = (a.d or 0) > 0 and a.d / self:RateTime(seg, a) or 0
        elseif mode == "healing" then v, ext = a.h, a.oh
        elseif mode == "taken" then v = a.t
        elseif mode == "kicks" then v = a.k
        elseif mode == "dispels" then v = a.dp
        elseif mode == "active" then v = min(dur, a.act or 0)
        end
        if v and v > 0 then
            rows[#rows + 1] = { g = g, a = a, v = v, ext = ext }
            total = total + v
        end
    end
    tsort(rows, function(x, y)
        if x.v ~= y.v then return x.v > y.v end
        return (x.a.n or "") < (y.a.n or "")
    end)
    if mode == "active" then
        local n = #rows
        total = n > 0 and (total / n) or 0           -- the average
    end
    return rows, total
end

function Meter:Find(seg, guid) return seg and seg.actors[guid] end

-- A player's active seconds in a fight (at least 1).
function Meter:ActiveTime(seg, a)
    return max(1, min(self:Duration(seg), (a and a.act) or 0))
end

-- What a player's DPS / HPS divide by (meters.rate): "fight" = the fight's length for everyone (Warcraft Logs; the
-- default, so per second always ranks like the totals), "active" = their own active time (Details' activity time).
-- Active time made a raid's bars disagree (a slow two-hander's swing gaps fell out of it, a hunter's Auto Shot kept
-- him active throughout; in-game report 2026-10-10).
function Meter:RateTime(seg, a)
    if Setting("rate", "fight") == "active" then return self:ActiveTime(seg, a) end
    return max(1, self:Duration(seg))
end

-- Did this player die in the fight?
function Meter:IsDead(seg, guid)
    if not seg or not seg.deaths then return false end
    for _, d in ipairs(seg.deaths) do if d.g == guid then return true end end
    return false
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function OnTick()
    if not live then return end
    live.dur = floor((Now() - (live._t0 or Now())) * 10 + 0.5) / 10   -- kept current: a crash keeps the length
    if GroupInCombat() then
        quiet = 0
    else
        quiet = quiet + TICK
        if live.kind ~= "boss" and quiet >= END_QUIET then Meter:Finish(nil)
        elseif live.kind == "boss" and quiet >= BOSS_QUIET then Meter:Finish(false) end
    end
    if live then Changed("tick") end
end

local function OnEncounterStart(_, encounterID, encounterName)
    if not listening then return end
    if live and live.kind == "trash" and live._t0 and Now() - live._t0 <= MERGE_START and (live._base or 0) == 0 then
        live.kind = "boss"
    else
        if live then Meter:Finish(nil) end
        Begin("boss")
    end
    live.name, live.enc = encounterName, encounterID
    Changed("boss")
end

local function OnEncounterEnd(_, encounterID, encounterName, _, _, success)
    if not listening or not live or live.kind ~= "boss" then return end
    Meter:Finish(success == 1 or success == true)
end

local function OnRegenDisabled()
    if listening and not live then Begin("trash") end
end

local function OnRoster() Meter:RebuildRoster() end
local function OnPet(_, unit)
    local pg = unit and UnitGUID and UnitGUID(unit == "player" and "pet" or (unit:gsub("^(%a+)(%d+)$", "%1pet%2")))
    local og = unit and UnitGUID and UnitGUID(unit)
    if pg and og then owner[pg] = og end
end
local function OnWorld()
    Meter:RebuildRoster()
    if live and not GroupInCombat() then Meter:Finish(nil) end
end

local function Listen(on)
    if on == listening then return end
    listening = on
    local fn = on and ns.RegisterEvent or ns.UnregisterEvent
    CL:SetSubscribed("meter", OnCLEU, on)
    fn(ns, "ENCOUNTER_START", OnEncounterStart)
    fn(ns, "ENCOUNTER_END", OnEncounterEnd)
    fn(ns, "PLAYER_REGEN_DISABLED", OnRegenDisabled)
    fn(ns, "GROUP_ROSTER_UPDATE", OnRoster)
    fn(ns, "UNIT_PET", OnPet)
    fn(ns, "PLAYER_ENTERING_WORLD", OnWorld)
    if on then
        Meter:RebuildRoster()
        if not ticker and C_Timer and C_Timer.NewTicker then ticker = C_Timer.NewTicker(TICK, OnTick) end
    else
        if live then Meter:Finish(nil) end
        if ticker then ticker:Cancel(); ticker = nil end
    end
end

function Meter:Refresh()
    Listen(self:IsEnabled())
end

function Meter:OnLogin()
    local db = Store()
    -- a fight still marked live was cut short by a /reload, logout or crash
    for _, s in ipairs(db.segs) do
        if s.live then s.live = nil; s.cut = true; Strip(s) end
    end
    if db.all then Strip(db.all) end
    for name, spec in pairs(db.specs) do
        if type(spec) ~= "string" then db.specs[name] = nil end
    end
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and path:sub(1, 7) == "meters." then Meter:Refresh() end
    end)
    ns:RegisterEvent("PLAYER_LOGOUT", function()
        if live then Meter:Finish(nil, true) end
    end)
    ns:RegisterSlash("meter", function(arg)
        arg = (arg or ""):lower()
        if arg == "reset" or arg == "clear" then
            Meter:ClearAll()
            ns:Print("meter: all fights cleared.")
        elseif arg == "on" or arg == "off" then
            ns.DB:SetSetting("meters.dmg", arg == "on")
        elseif ns.MeterWindow then
            ns.MeterWindow:Toggle()
        end
    end, "show or hide the damage meter (on | off | reset)")
    self:Refresh()
end

-- Test hooks
Meter._State = function() return { live = live, roster = roster, owner = owner, listening = listening } end
Meter._Tick = OnTick

if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Totems.lua", ...) then return end -- DisasterZone: shaman totems.
-- The shaman Totem planner (a class tool, Core/ClassKit.lua, for every shaman spec): which totem each shaman drops
-- for each element, Windfury twisted with Grace of Air, who gets Earth Shield, when to use Heroism, and totems that
-- change for one boss. Totems only reach the shaman's own party, so the planner also shows each shaman's raid group
-- and the groups no shaman covers. Heroism reaches the whole raid (Anniversary): one shaman casts it, one backs up. The window is UI/TotemsUI.lua, the in-raid bar
-- UI/TotemBar.lua; mockup dev/art/casc/totem_mockup.
--
-- Sync speaks ShamanPower's wire protocol (prefix SHPWR, plain text; dev/docs/research/shamanpower.md), so
-- DisasterZone and ShamanPower users in one raid share one plan: SELF, ASSIGN, PASSIGN, MASSIGN, TWIST, ESASSIGN,
-- CLEAR, FREEASSIGN, REQ. Nothing of ShamanPower's code is used. What ShamanPower has no word for (Heroism timing,
-- boss changes) goes on the same prefix as DZHERO / DZBOSS, which ShamanPower ignores.
--
-- Who may change what (as ShamanPower / Pally Power): my own row always; anyone's while I am the raid leader or an
-- assistant (the party leader in a party); a shaman who allows "anyone may assign me" (FREEASSIGN YES).
--
-- Saved (account wide): db.totems.assign / twist / es / hero / boss.
local addonName, ns = ...

local Totems = ns:NewModule("Totems")
local Util = ns.Util
local D = ns.ClassData.SHAMAN

local type, pairs, ipairs, tonumber, tostring, select, next = type, pairs, ipairs, tonumber, tostring, select, next
local floor, max, min = math.floor, math.max, math.min
local strformat, strsub, strmatch, strfind, gmatch = string.format, string.sub, string.match, string.find, string.gmatch
local tinsert, tconcat, tsort = table.insert, table.concat, table.sort
local wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end

local PREFIX = "SHPWR"
local NEL = 4
local SEND_DELAY = 0.8
local BOSS_PER_MSG = 5

Totems.PREFIX = PREFIX
Totems.D = D

-- spell id -> { element, index }, for every totem
local BY_ID = {}
for el, list in ipairs(D.TOTEMS) do
    for i, t in ipairs(list) do BY_ID[t.id] = { el, i } end
end
Totems.BY_ID = BY_ID

Totems.shamans = {}              -- [wire name] = shaman record (see NewShaman)

local demo                       -- demo mode's made-up raid (BuildDemo), in memory only

-- (created at login, so turning demo mode on and off leaves the saved data as it was)
local function RealDB()
    local db = ns.db
    if not db then return nil end
    db.totems = db.totems or {}
    local t = db.totems
    t.assign = t.assign or {}
    t.twist = t.twist or {}
    t.es = t.es or {}
    t.hero = t.hero or {}
    t.boss = t.boss or {}
    return t
end

local function DB()
    if demo and Totems:IsDemo() then return demo.store end
    return RealDB()
end
Totems.Store = DB

local function Setting(path, default)
    local v = ns.DB and ns.DB:GetSetting("totems." .. path)
    if v == nil then return default end
    return v
end
Totems.Setting = Setting

local changedQueued = false
local function Changed()
    if changedQueued then return end
    changedQueued = true
    local function fire()
        changedQueued = false
        ns:Fire("TOTEMS_CHANGED")
    end
    if C_Timer and C_Timer.After then C_Timer.After(0, fire) else fire() end
end
Totems.Changed = Changed

-- ---------------------------------------------------------------------------------------------------------------
-- Names, spells
-- ---------------------------------------------------------------------------------------------------------------
-- A player's name as ShamanPower sends it: Name on my realm, Name-Realm otherwise.
local function Wire(nameOrKey)
    local key = Util.NormalizeName(nameOrKey)
    return key and Util.ShortName(key) or nil
end
Totems.Wire = Wire

function Totems:Me()
    local k = Util.PlayerKey()
    return k and Util.ShortName(k) or nil
end

function Totems:IsDemo()
    return ns.ClassKit and ns.ClassKit:IsDemo() or false
end

function Totems:IsShaman()
    if self:IsDemo() then return true end
    local _, cls = UnitClass("player")
    return cls == "SHAMAN"
end

function Totems:InGroup()
    return self:IsDemo() or IsInGroup()
end

function Totems:Totem(el, idx)
    local list = D.TOTEMS[el]
    return list and list[idx] or nil
end

-- A totem's localized name (by its first rank; the cast picks the best rank known).
function Totems:TotemName(el, idx)
    local t = self:Totem(el, idx)
    if not t then return nil end
    return (GetSpellInfo and GetSpellInfo(t.id)) or (t.short .. " Totem")
end

function Totems:TotemIcon(el, idx)
    local t = self:Totem(el, idx)
    return t and t.icon or nil
end

function Totems:TotemShort(el, idx)
    local t = self:Totem(el, idx)
    return t and t.short or nil
end

-- Heroism for the Alliance, Bloodlust for the Horde (the one I know; else by faction).
function Totems:HeroSpell()
    if IsSpellKnown then
        if IsSpellKnown(D.BLOODLUST) then return D.BLOODLUST, D.BLOODLUST_ICON end
        if IsSpellKnown(D.HEROISM) then return D.HEROISM, D.HEROISM_ICON end
    end
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    if faction == "Horde" then return D.BLOODLUST, D.BLOODLUST_ICON end
    return D.HEROISM, D.HEROISM_ICON
end

function Totems:HeroName()
    local id = self:HeroSpell()
    return (GetSpellInfo and GetSpellInfo(id)) or (id == D.BLOODLUST and "Bloodlust" or "Heroism")
end

function Totems:ESName()
    return (GetSpellInfo and GetSpellInfo(D.EARTH_SHIELD)) or "Earth Shield"
end

-- ---------------------------------------------------------------------------------------------------------------
-- Shamans
-- ---------------------------------------------------------------------------------------------------------------
local function NewShaman(name)
    return { name = name, known = { {}, {}, {}, {} }, es = false, free = false, seen = GetTime() }
end

local function Shaman(name, create)
    local s = Totems.shamans[name]
    if not s and create then
        s = NewShaman(name)
        Totems.shamans[name] = s
    end
    return s
end
Totems.Shaman = Shaman

function Totems:Knows(name, el, idx)
    local s = self.shamans[name]
    return s and s.known[el] and s.known[el][idx] or false
end

-- Reads which totems I know (and Earth Shield) into my record; true when anything changed.
function Totems:ScanSelf()
    if self:IsDemo() then return false end
    local me = self:Me()
    if not me or not self:IsShaman() then return false end
    local s = Shaman(me, true)
    local before = self:EncodeSelf()
    for el, list in ipairs(D.TOTEMS) do
        s.known[el] = {}
        for i, t in ipairs(list) do
            if IsSpellKnown and IsSpellKnown(t.id) then s.known[el][i] = true end
        end
    end
    s.es = (IsSpellKnown and IsSpellKnown(D.EARTH_SHIELD)) and true or false
    s.free = Setting("free", false) and true or false
    s.seen = GetTime()
    s.me = true
    return self:EncodeSelf() ~= before
end

-- The spec a shaman plays, best guess: mine from my talents, others from the raid plan, else from what they know
-- (Totem of Wrath = Elemental, Earth Shield or Mana Tide = Restoration, else Enhancement).
local function SpecLabel(cls, sp)
    if type(sp) == "string" then return sp end
    local list = ns.SPECS and ns.SPECS[cls]
    return (type(sp) == "number" and list and list[sp]) and list[sp].label or nil
end

local function PlanSpec(name, cls)
    local key = Util.NormalizeName(name)
    if not (key and ns.RaidPlan and ns.RaidPlan.GetMemberSpec) then return nil end
    local ok, sp, c = pcall(ns.RaidPlan.GetMemberSpec, ns.RaidPlan, key)
    if not ok then return nil end
    return SpecLabel(c or cls, sp)
end

function Totems:SpecOf(name)
    if self:IsDemo() and demo and demo.specs[name] then return demo.specs[name] end
    if name == self:Me() then
        local mine = ns.ClassKit and ns.ClassKit:MySpecs()
        if mine and mine[1] then return mine[1] end
    end
    local sp = PlanSpec(name, "SHAMAN")
    if sp then return sp end
    local s = self.shamans[name]
    if s then
        if s.known[2][1] then return "Elemental" end
        if s.es or s.known[3][3] then return "Restoration" end
    end
    return "Enhancement"
end

-- The talents a shaman's card shows: "Totem of Wrath", "Earth Shield · Mana Tide", "Unleashed Rage".
function Totems:TalentLine(name)
    local s = self.shamans[name]
    if not s then return "" end
    local out = {}
    if s.known[2][1] then out[#out + 1] = "Totem of Wrath" end
    if s.es then out[#out + 1] = "Earth Shield" end
    if s.known[3][3] then out[#out + 1] = "Mana Tide" end
    if #out == 0 and self:SpecOf(name) == "Enhancement" then out[1] = "Windfury twisting" end
    return tconcat(out, " · ")
end

-- Shamans in the group without DisasterZone or ShamanPower still get a row (a leader can plan for them and Report
-- it): every totem anyone trains, plus the talent ones their spec in the raid plan gives (Totem of Wrath for
-- Elemental, Mana Tide and Earth Shield for Restoration). Their own SELF replaces the guess.
function Totems:EnsureRosterShamans(roster)
    if self:IsDemo() then return end
    for _, m in ipairs(roster) do
        if m.class == "SHAMAN" and not self.shamans[m.name] then
            local s = NewShaman(m.name)
            s.noAddon = true
            local spec = PlanSpec(m.name, "SHAMAN")
            for el, list in ipairs(D.TOTEMS) do
                for i in ipairs(list) do s.known[el][i] = true end
            end
            if spec ~= "Elemental" then s.known[2][1] = nil end
            if spec ~= "Restoration" then s.known[3][3] = nil end
            s.es = spec == "Restoration"
            self.shamans[m.name] = s
        end
    end
end

-- Known shamans: by raid group, then name (me first among equals).
function Totems:Shamans(roster)
    roster = roster or self:Roster()
    self:EnsureRosterShamans(roster)
    local sub = {}
    for _, m in ipairs(roster) do sub[m.name] = m.subgroup end
    local out, me = {}, self:Me()
    for _, s in pairs(self.shamans) do out[#out + 1] = s end
    tsort(out, function(a, b)
        local ga, gb = sub[a.name] or 9, sub[b.name] or 9
        if ga ~= gb then return ga < gb end
        if (a.name == me) ~= (b.name == me) then return a.name == me end
        return a.name < b.name
    end)
    return out
end

-- ---------------------------------------------------------------------------------------------------------------
-- The group
-- ---------------------------------------------------------------------------------------------------------------
local function InInstanceGroup()
    return LE_PARTY_CATEGORY_INSTANCE and IsInGroup and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and IsInInstance
        and IsInInstance() and true or false
end

function Totems:IsLeader(name)
    if self:IsDemo() then return name ~= nil and name == self:Me() end
    if not name or InInstanceGroup() then return false end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local n, rank = GetRaidRosterInfo(i)
            if n and Wire(n) == name then return (rank or 0) > 0 end
        end
        return false
    end
    if name == self:Me() then return UnitIsGroupLeader("player") and true or false end
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) and Wire(GetUnitName(u, true)) == name then return UnitIsGroupLeader(u) and true or false end
    end
    return false
end

function Totems:AmLeader() return self:IsLeader(self:Me()) end

function Totems:LeaderName()
    if self:IsDemo() then return self:Me() end
    if not IsInGroup() then return nil end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local n, rank = GetRaidRosterInfo(i)
            if n and rank == 2 then return Wire(n) end
        end
        return nil
    end
    if UnitIsGroupLeader("player") then return self:Me() end
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) and UnitIsGroupLeader(u) then return Wire(GetUnitName(u, true)) end
    end
    return nil
end

function Totems:CanEdit(name)
    if not name then return false end
    if self:IsDemo() then return true end
    if name == self:Me() then return true end
    local s = self.shamans[name]
    if InInstanceGroup() then return s and s.free or false end
    if Util.IsPlayerLeaderOrAssist() and IsInGroup() then return true end
    return s and s.free or false
end

function Totems:CanEditAny()
    for name in pairs(self.shamans) do
        if self:CanEdit(name) then return true end
    end
    return false
end

-- May I move players between raid groups (leader or assistant, in a raid, out of combat)?
function Totems:CanMove()
    if self:IsDemo() then return true end
    return IsInRaid() and Util.IsPlayerLeaderOrAssist() and not InCombatLockdown()
end

-- What a member is there for: "tank" | "melee" | "ranged" | "caster" | "healer".
local CLASS_ROLE = { WARRIOR = "melee", ROGUE = "melee", HUNTER = "ranged", MAGE = "caster", WARLOCK = "caster",
    PRIEST = "healer", DRUID = "healer", PALADIN = "healer", SHAMAN = "healer" }

local function RoleOf(m)
    if m.tank then return "tank" end
    local spec
    if Totems:IsDemo() and demo then spec = demo.specs[m.name] end
    if not spec and m.class == "SHAMAN" then spec = Totems:SpecOf(m.name) end
    if not spec then spec = PlanSpec(m.name, m.class) end
    local role = spec and ns.GetSpecRole and ns.GetSpecRole(m.class, spec)
    return role or CLASS_ROLE[m.class] or "melee"
end
Totems.RoleOf = RoleOf

-- Group members (no pets): { unit, name, class, subgroup, level, tank, role, online, dead }, in roster order.
function Totems:Roster()
    if self:IsDemo() and demo then return demo.roster end
    local out = {}
    local function add(unit, subgroup, rrole)
        if not UnitExists(unit) then return end
        local cls = UnitClassBase and UnitClassBase(unit) or select(2, UnitClass(unit))
        local name = GetUnitName(unit, true)
        if not (cls and name) then return end
        local m = { unit = unit, name = Wire(name) or name, class = cls, subgroup = subgroup or 1,
            level = UnitLevel(unit) or 70, tank = rrole == "MAINTANK" or nil,
            online = UnitIsConnected(unit) and true or false, dead = UnitIsDeadOrGhost(unit) and true or false }
        if not m.tank and UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit) == "TANK" then m.tank = true end
        out[#out + 1] = m
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local _, _, subgroup, _, _, _, _, _, _, rrole = GetRaidRosterInfo(i)
            add("raid" .. i, subgroup, rrole)
            if out[#out] and out[#out].unit == "raid" .. i then out[#out].raidIndex = i end
        end
    else
        add("player", 1)
        if IsInGroup() then
            for i = 1, 4 do add("party" .. i, 1) end
        end
    end
    for _, m in ipairs(out) do m.role = RoleOf(m) end
    return out
end

-- What a party wants from its shaman, by what most of it is there for.
local GROUP_KIND = {
    tank = { label = "Tanks", needs = { { 1, 1 }, { 4, 1 } } },
    melee = { label = "Melee", needs = { { 1, 1 }, { 4, 1 }, { 4, 2 } } },
    ranged = { label = "Hunters", needs = { { 4, 2 }, { 1, 1 } } },
    caster = { label = "Casters", needs = { { 4, 3 }, { 2, 1 }, { 3, 1 } } },
    healer = { label = "Healers", needs = { { 3, 1 }, { 4, 3 } } },
}
Totems.GROUP_KIND = GROUP_KIND
-- how much a party loses without a shaman (who moves when one has none)
local KIND_WEIGHT = { melee = 5, caster = 4, tank = 3, ranged = 2, healer = 1 }

-- Raid groups: { [sub] = { sub, members = {}, shamans = { name }, kind } }, and the list of subgroups in order.
function Totems:Groups(roster)
    roster = roster or self:Roster()
    local by, order = {}, {}
    for _, m in ipairs(roster) do
        local g = by[m.subgroup]
        if not g then
            g = { sub = m.subgroup, members = {}, shamans = {} }
            by[m.subgroup] = g
            order[#order + 1] = m.subgroup
        end
        g.members[#g.members + 1] = m
        if m.class == "SHAMAN" then g.shamans[#g.shamans + 1] = m.name end
    end
    tsort(order)
    for _, g in pairs(by) do
        local count = {}
        local tank = false
        for _, m in ipairs(g.members) do
            local r = m.role or RoleOf(m)
            if r == "tank" then tank = true end
            -- (the shaman counts for what they bring, not what they want)
            if m.class ~= "SHAMAN" then count[r] = (count[r] or 0) + 1 end
        end
        local best, bestN = "melee", -1
        for _, r in ipairs({ "ranged", "melee", "caster", "healer" }) do   -- (a tie: hunters want their own shaman most)
            if (count[r] or 0) > bestN then best, bestN = r, count[r] or 0 end
        end
        g.kind = tank and "tank" or best
    end
    return by, order
end

function Totems:SubgroupOf(name, roster)
    for _, m in ipairs(roster or self:Roster()) do
        if m.name == name then return m.subgroup end
    end
    return nil
end

-- What a group without a shaman misses, as words: "Strength of Earth, Windfury, Grace of Air".
function Totems:MissesText(g)
    local parts = {}
    for _, n in ipairs(GROUP_KIND[g.kind].needs) do parts[#parts + 1] = D.TOTEMS[n[1]][n[2]].short end
    return tconcat(parts, ", ")
end

-- ---------------------------------------------------------------------------------------------------------------
-- Assignments
-- ---------------------------------------------------------------------------------------------------------------
function Totems:GetAssign(name, el)
    local s = DB()
    local row = s and s.assign[name]
    local idx = row and row[el]
    return (idx and idx > 0) and idx or nil
end

function Totems:GetTwist(name)
    local s = DB()
    return s and s.twist[name] and true or false
end

function Totems:GetES(name)
    local s = DB()
    local t = s and s.es[name]
    return (t and t ~= "" and t ~= "NONE") and t or nil
end

-- When shaman `name` uses Heroism: "pull" | "execute" | "call" | "backup" | "none" (the default: someone else does).
function Totems:GetHero(name)
    local s = DB()
    return s and s.hero[name] or "none"
end

function Totems:HeroCasts(key)
    for _, h in ipairs(D.HERO_WHEN) do
        if h.key == key then return h.casts and true or false end
    end
    return false
end

-- The shamans set to cast Heroism (more than one: all but one are wasted, Exhaustion), and the backups.
function Totems:HeroCasters(roster)
    local casters, backups = {}, {}
    for _, s in ipairs(self:Shamans(roster)) do
        local h = self:GetHero(s.name)
        if self:HeroCasts(h) then casters[#casters + 1] = s.name
        elseif h == "backup" then backups[#backups + 1] = s.name end
    end
    return casters, backups
end

-- A boss change: { i = index, alt = true when it is the second one (right-click on the bar) } or nil.
function Totems:GetBoss(bossKey, name, el)
    local s = DB()
    local b = s and bossKey and s.boss[bossKey]
    local row = b and b[name]
    return row and row[el] or nil
end

-- Every boss change of this raid, one per boss + element + totem (+ second or not): { boss, el, i, alt, was,
-- names = { shaman } }, in the raid's boss order. `was` is the All bosses totem most of those shamans have there.
function Totems:BossChanges(raidKey)
    local out = {}
    local s = DB()
    if not s then return out end
    for _, b in ipairs(self:Bosses(raidKey)) do
        local byKey, order = {}, {}
        for name, row in pairs(s.boss[b.key] or {}) do
            if self.shamans[name] then
                for el, o in pairs(row) do
                    local k = strformat("%d:%d:%s", el, o.i, o.alt and "2" or "1")
                    local e = byKey[k]
                    if not e then
                        e = { boss = b.key, short = b.short, bossName = b.name, el = el, i = o.i, alt = o.alt or false,
                            names = {}, wasCount = {} }
                        byKey[k] = e
                        order[#order + 1] = e
                    end
                    e.names[#e.names + 1] = name
                    local base = self:GetAssign(name, el)
                    if base then e.wasCount[base] = (e.wasCount[base] or 0) + 1 end
                end
            end
        end
        tsort(order, function(a, c)
            if a.alt ~= c.alt then return not a.alt end
            return a.el < c.el
        end)
        for _, e in ipairs(order) do
            local best, n = nil, 0
            for idx, k in pairs(e.wasCount) do
                if k > n or (k == n and idx < best) then best, n = idx, k end
            end
            e.was, e.wasCount = best, nil
            tsort(e.names)
            out[#out + 1] = e
        end
    end
    return out
end

function Totems:BossHasChanges(bossKey)
    local s = DB()
    local b = s and s.boss[bossKey]
    if not b then return false end
    for name, row in pairs(b) do
        if self.shamans[name] and next(row) then return true end
    end
    return false
end

-- The two totems the bar offers for an element: main (click) and alt (right-click), with the boss's changes;
-- Air with twisting on: Windfury and the twist partner.
function Totems:Effective(name, el, bossKey)
    local base = self:GetAssign(name, el)
    local o = self:GetBoss(bossKey, name, el)
    if o and o.i then
        if o.alt then return base, o.i, "boss2" end
        return o.i, (base ~= o.i) and base or nil, "boss1"
    end
    if el == 4 and base == D.WINDFURY[2] and self:GetTwist(name) then
        local partner = tonumber(Setting("twistWith", 2)) or 2
        if partner ~= base then return base, partner, "twist" end
    end
    return base, nil, nil
end

local function SetAssignRaw(name, el, idx)
    local s = DB()
    s.assign[name] = s.assign[name] or {}
    s.assign[name][el] = (idx and idx > 0) and idx or nil
end

local function SetBossRaw(bossKey, name, el, idx, alt)
    local s = DB()
    if not (bossKey and name and el) then return end
    s.boss[bossKey] = s.boss[bossKey] or {}
    local b = s.boss[bossKey]
    b[name] = b[name] or {}
    b[name][el] = (idx and idx > 0) and { i = idx, alt = alt and true or nil } or nil
    if not next(b[name]) then b[name] = nil end
    if not next(b) then s.boss[bossKey] = nil end
end

-- Edits (permission checked, sent to the group a moment later)
local pending, pendingOrder, flushQueued = {}, {}, false

local function Flush()
    flushQueued = false
    local list = pendingOrder
    pendingOrder = {}
    for _, k in ipairs(list) do
        local msg = pending[k]
        pending[k] = nil
        if msg then Totems:SendRaw(msg) end
    end
end
Totems.Flush = Flush

local function Queue(k, msg)
    if not pending[k] then pendingOrder[#pendingOrder + 1] = k end
    pending[k] = msg
    if not flushQueued then
        flushQueued = true
        if C_Timer and C_Timer.After then C_Timer.After(SEND_DELAY, Flush) else Flush() end
    end
end

function Totems:SetAssign(name, el, idx)
    if not self:CanEdit(name) or not D.TOTEMS[el] then return false end
    idx = (idx and idx > 0 and D.TOTEMS[el][idx]) and idx or 0
    SetAssignRaw(name, el, idx)
    Queue("A" .. name .. el, strformat("ASSIGN %s %d %d", name, el, idx))
    Changed()
    return true
end

function Totems:SetTwist(name, on)
    if not self:CanEdit(name) then return false end
    DB().twist[name] = on and true or nil
    Queue("T" .. name, strformat("TWIST %s %d", name, on and 1 or 0))
    Changed()
    return true
end

function Totems:SetES(name, target)
    if not self:CanEdit(name) then return false end
    target = (type(target) == "string" and target ~= "") and target or nil
    DB().es[name] = target
    Queue("E" .. name, strformat("ESASSIGN %s %s", name, target or "NONE"))
    Changed()
    return true
end

function Totems:SetHero(name, key)
    if not self:CanEdit(name) then return false end
    local ok = false
    for _, h in ipairs(D.HERO_WHEN) do if h.key == key then ok = true end end
    if not ok then return false end
    DB().hero[name] = (key ~= "none") and key or nil
    Queue("H" .. name, strformat("DZHERO %s %s", name, key))
    Changed()
    return true
end

function Totems:SetBoss(bossKey, name, el, idx, alt)
    if not self:CanEdit(name) or not D.TOTEMS[el] or type(bossKey) ~= "string" or bossKey:find("[%s@]") then
        return false
    end
    idx = (idx and idx > 0 and D.TOTEMS[el][idx]) and idx or 0
    SetBossRaw(bossKey, name, el, idx, alt)
    Queue("B" .. bossKey .. name .. el, strformat("DZBOSS %s %s %d %d %d", name, bossKey, el, idx, alt and 1 or 0))
    Changed()
    return true
end

-- Applies a whole plan { assign = {[name]={[el]=idx}}, twist = {[name]=bool}, es = {[name]=target|false},
-- hero = {[name]=key} } to the shamans I may change.
function Totems:Apply(plan)
    for _, s in ipairs(self:Shamans()) do
        local name = s.name
        if self:CanEdit(name) then
            local row = plan.assign and plan.assign[name]
            if row then
                local chars = {}
                for el = 1, NEL do
                    SetAssignRaw(name, el, row[el])
                    chars[el] = (row[el] and row[el] > 0) and tostring(row[el]) or "n"
                    pending["A" .. name .. el] = nil
                end
                Queue("P" .. name, "PASSIGN " .. name .. "@" .. tconcat(chars))
            end
            if plan.twist and plan.twist[name] ~= nil then
                DB().twist[name] = plan.twist[name] and true or nil
                Queue("T" .. name, strformat("TWIST %s %d", name, plan.twist[name] and 1 or 0))
            end
            if plan.es and plan.es[name] ~= nil then
                local t = plan.es[name] or nil
                DB().es[name] = t
                Queue("E" .. name, strformat("ESASSIGN %s %s", name, t or "NONE"))
            end
            if plan.hero and plan.hero[name] then
                DB().hero[name] = (plan.hero[name] ~= "none") and plan.hero[name] or nil
                Queue("H" .. name, strformat("DZHERO %s %s", name, plan.hero[name]))
            end
        end
    end
    Changed()
end

-- Clears every shaman I may change (and their boss changes).
function Totems:ClearAll()
    local plan = { assign = {}, twist = {}, es = {} }
    for _, s in ipairs(self:Shamans()) do
        if self:CanEdit(s.name) then
            plan.assign[s.name], plan.twist[s.name], plan.es[s.name] = {}, false, false
            for bossKey, b in pairs(DB().boss) do
                for el in pairs(b[s.name] or {}) do self:SetBoss(bossKey, s.name, el, 0) end
            end
        end
    end
    self:Apply(plan)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Auto-assign
-- ---------------------------------------------------------------------------------------------------------------
-- Per party kind, each element's totems best first (indexes); a second shaman in a party takes the next one.
local PREF = {
    tank = { { 1, 2, 3 }, { 2, 5, 1 }, { 1, 2 }, { 1, 2, 4 } },
    melee = { { 1, 2, 3 }, { 2, 5, 1 }, { 1, 2 }, { 1, 2, 4 } },
    ranged = { { 1, 2, 3 }, { 2, 5, 1 }, { 1, 2 }, { 2, 1, 4 } },
    caster = { { 2, 1, 3 }, { 1, 5, 2 }, { 1, 2 }, { 3, 4, 2 } },
    healer = { { 2, 1, 3 }, { 1, 2, 5 }, { 1, 2 }, { 3, 4, 2 } },
}
Totems.PREF = PREF

-- A plan for the shamans I may change (the others keep theirs and count as given in their party).
function Totems:AutoPlan(roster)
    roster = roster or self:Roster()
    local groups = self:Groups(roster)
    local subOf = {}
    for _, m in ipairs(roster) do subOf[m.name] = m.subgroup end
    local plan = { assign = {}, twist = {}, es = {}, hero = {} }
    local taken = {}                 -- [sub][el][idx] = true
    local function take(sub, el, idx)
        taken[sub] = taken[sub] or { {}, {}, {}, {} }
        taken[sub][el][idx] = true
    end
    local function isTaken(sub, el, idx) return taken[sub] and taken[sub][el][idx] end
    local mine = {}
    for _, s in ipairs(self:Shamans(roster)) do
        local sub = subOf[s.name] or 1
        if self:CanEdit(s.name) then
            mine[#mine + 1] = s
        else
            for el = 1, NEL do
                local idx = self:GetAssign(s.name, el)
                if idx then take(sub, el, idx) end
            end
        end
    end
    for _, s in ipairs(mine) do
        local sub = subOf[s.name] or 1
        local kind = groups[sub] and groups[sub].kind or "melee"
        local row = {}
        for el = 1, NEL do
            local prefs = PREF[kind][el]
            -- (an Elemental drops Totem of Wrath wherever they stand: their own spells want it)
            if el == D.TOTEM_OF_WRATH[1] and s.known[el][D.TOTEM_OF_WRATH[2]] then
                prefs = { D.TOTEM_OF_WRATH[2], unpack(prefs) }
            end
            for _, idx in ipairs(prefs) do
                if s.known[el][idx] and not isTaken(sub, el, idx) then
                    row[el] = idx
                    take(sub, el, idx)
                    break
                end
            end
        end
        plan.assign[s.name] = row
        plan.twist[s.name] = (row[4] == D.WINDFURY[2] and self:SpecOf(s.name) == "Enhancement" and s.known[4][2]) and true or false
        plan.hero[s.name] = "none"
    end
    -- Heroism: one caster for the whole raid and one backup. A caster already set (mine to change or not) stays;
    -- else Enhancement, then Elemental, then Restoration (healers have their hands full), by name.
    local caster, backup
    for _, s in ipairs(self:Shamans(roster)) do
        local h = self:GetHero(s.name)
        if self:HeroCasts(h) and not caster then caster = s.name end
        if h == "backup" and not backup then backup = s.name end
    end
    local SPEC_ORDER = { Enhancement = 1, Elemental = 2, Restoration = 3 }
    local pool = {}
    for _, s in ipairs(mine) do pool[#pool + 1] = s end
    tsort(pool, function(a, b)
        local x, y = SPEC_ORDER[self:SpecOf(a.name)] or 4, SPEC_ORDER[self:SpecOf(b.name)] or 4
        if x ~= y then return x < y end
        return a.name < b.name
    end)
    for _, s in ipairs(pool) do
        if not caster then
            caster = s.name
            plan.hero[s.name] = "pull"
        elseif not backup and s.name ~= caster then
            backup = s.name
            plan.hero[s.name] = "backup"
        end
    end
    if caster and plan.hero[caster] then plan.hero[caster] = self:GetHero(caster) ~= "none" and self:HeroCasts(self:GetHero(caster))
        and self:GetHero(caster) or "pull" end
    if backup and plan.hero[backup] then plan.hero[backup] = "backup" end
    -- Earth Shield: each Restoration shaman on a different tank (main tanks first), else nobody
    local tanks, used = {}, {}
    for _, m in ipairs(roster) do
        if m.tank then tanks[#tanks + 1] = m.name end
    end
    for _, s in ipairs(self:Shamans(roster)) do
        local t = self:GetES(s.name)
        if t and not self:CanEdit(s.name) then used[t] = true end
    end
    for _, s in ipairs(mine) do
        local pick = false
        if s.es then
            for _, t in ipairs(tanks) do
                if not used[t] then pick = t break end
            end
            if pick then used[pick] = true end
        end
        plan.es[s.name] = pick
    end
    return plan
end

function Totems:AutoAssign()
    if not self:CanEditAny() then return false end
    self:Apply(self:AutoPlan())
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Moving shamans between raid groups
-- ---------------------------------------------------------------------------------------------------------------
-- Who to move into group `sub` (it has no shaman): a party with two first, else the one whose party loses least
-- (only when that party matters less than this one). Returns a shaman name or nil.
function Totems:SwapSuggestion(sub, roster)
    roster = roster or self:Roster()
    local groups = self:Groups(roster)
    local target = groups[sub]
    if not target then return nil end
    local best, bestW
    for _, g in pairs(groups) do
        if g.sub ~= sub and #g.shamans > 0 then
            local w = (#g.shamans > 1) and -1 or KIND_WEIGHT[g.kind]
            if w < KIND_WEIGHT[target.kind] and (not bestW or w < bestW) then best, bestW = g.shamans[#g.shamans], w end
        end
    end
    return best
end

-- Swaps shaman `name` with a player of group `sub` (the one fitting the shaman's old party best). Leader or
-- assistant, out of combat.
function Totems:MoveShaman(name, sub)
    if not self:CanMove() then return false end
    local roster = self:Roster()
    local from, me
    for _, m in ipairs(roster) do
        if m.name == name then me = m; from = m.subgroup end
    end
    if not me or from == sub then return false end
    local groups = self:Groups(roster)
    local oldKind = groups[from] and groups[from].kind
    local other, fallback
    for _, m in ipairs(roster) do
        if m.subgroup == sub and m.class ~= "SHAMAN" then
            fallback = m
            if (m.role or RoleOf(m)) == oldKind or (oldKind == "tank" and m.tank) then other = m end
        end
    end
    other = other or fallback
    if self:IsDemo() then
        me.subgroup = sub
        if other then other.subgroup = from end
        Changed()
        return true
    end
    if other and other.raidIndex and SwapRaidSubgroup then
        SwapRaidSubgroup(me.raidIndex, other.raidIndex)
    elseif me.raidIndex and SetRaidSubgroup then
        SetRaidSubgroup(me.raidIndex, sub)
    else
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Bosses
-- ---------------------------------------------------------------------------------------------------------------
local function RaidData(key)
    for _, r in ipairs((ns.Data and ns.Data.Raids) or {}) do
        if r.key == key then return r end
    end
    return nil
end

local function RaidByInstance(id)
    for _, r in ipairs((ns.Data and ns.Data.Raids) or {}) do
        if r.instanceID and r.instanceID == id then return r end
    end
    return nil
end

-- The raid the planner shows: the one I am in, else the one picked (setting), else Serpentshrine Cavern.
function Totems:RaidKey()
    if self:IsDemo() then return "SerpentshrineCavern" end
    local id = select(8, GetInstanceInfo())
    local r = RaidByInstance(tonumber(id) or 0)
    if r and r.bosses then return r.key end
    local pick = Setting("raid", nil)
    if pick and RaidData(pick) then return pick end
    return "SerpentshrineCavern"
end

function Totems:RaidName(key)
    local r = RaidData(key or self:RaidKey())
    return r and r.name or ""
end

-- Raids with bosses one can plan for (no world bosses): { { key, name } }
function Totems:Raids()
    local out = {}
    for _, r in ipairs((ns.Data and ns.Data.Raids) or {}) do
        if r.instanceID and r.bosses and #r.bosses > 0 then out[#out + 1] = { key = r.key, name = r.name } end
    end
    return out
end

-- A raid's bosses: { { key = "SerpentshrineCavern:Hydross", short = "Hydross", name, npcIDs, encounterID } }
function Totems:Bosses(raidKey)
    local r = RaidData(raidKey or self:RaidKey())
    local out = {}
    if not r then return out end
    for _, b in ipairs(r.bosses or {}) do
        if not b.isTrash and not b.isChest then
            out[#out + 1] = { key = r.key .. ":" .. b.key, short = b.key, name = b.name, npcIDs = b.npcIDs,
                encounterID = b.encounterID }
        end
    end
    return out
end

local function NpcID(unit)
    local guid = UnitGUID and UnitGUID(unit)
    if not guid then return nil end
    return tonumber(select(6, strsplit("-", guid)) or "")
end

-- The boss the bar plans for now: the running encounter, else boss1 or my target if it is one of this raid's.
local encounterBoss
function Totems:CurrentBoss()
    if encounterBoss then return encounterBoss end
    local bosses = self:Bosses()
    for _, unit in ipairs({ "boss1", "target" }) do
        local id = UnitExists and UnitExists(unit) and NpcID(unit)
        if id then
            for _, b in ipairs(bosses) do
                for _, n in ipairs(b.npcIDs or {}) do
                    if n == id then return b.key end
                end
            end
        end
    end
    return nil
end

function Totems:BossName(bossKey)
    for _, b in ipairs(self:Bosses((bossKey or ""):match("^([^:]+)"))) do
        if b.key == bossKey then return b.name, b.short end
    end
    return bossKey, bossKey
end

-- ---------------------------------------------------------------------------------------------------------------
-- Live state
-- ---------------------------------------------------------------------------------------------------------------
-- The buff a totem puts on the party, as its name shows on players: the totem's name without " Totem".
local function AuraName(el, idx)
    local n = Totems:TotemName(el, idx)
    if not n then return nil end
    return (n:gsub("%s*[Tt]otem$", ""))
end

-- Does unit carry the buff of totem (el, idx)?
function Totems:HasTotemBuff(unit, el, idx)
    if self:IsDemo() and demo then return demo.hasBuff(unit, el, idx) end
    local want = AuraName(el, idx)
    if not (want and UnitAura) then return false end
    for i = 1, 40 do
        local name = UnitAura(unit, i, "HELPFUL")
        if not name then break end
        if strfind(name, want, 1, true) then return true end
    end
    return false
end

-- A shaman's party and totem (el, idx): { total, have, missing = { member } }. Only counts once somebody has it
-- (no totem down = nothing to say).
function Totems:PartyState(name, el, idx, roster)
    local st = { total = 0, have = 0, missing = {} }
    local t = self:Totem(el, idx)
    if not (t and t.aura) then return st end
    roster = roster or self:Roster()
    local sub = self:SubgroupOf(name, roster)
    if not sub then return st end
    for _, m in ipairs(roster) do
        if m.subgroup == sub and m.online and not m.dead then
            st.total = st.total + 1
            if self:HasTotemBuff(m.unit, el, idx) then st.have = st.have + 1
            else st.missing[#st.missing + 1] = m end
        end
    end
    if st.have == 0 then st.missing = {} end
    return st
end

-- Earth Shield on target: charges left (0 when missing), and who cast it.
function Totems:ESCharges(target)
    if self:IsDemo() and demo then return demo.esCharges(target) end
    if not target then return 0 end
    local unit
    for _, m in ipairs(self:Roster()) do
        if m.name == target then unit = m.unit end
    end
    if not unit or not UnitAura then return 0 end
    local want = self:ESName()
    for i = 1, 40 do
        local name, _, count, _, _, _, source = UnitAura(unit, i, "HELPFUL")
        if not name then break end
        if name == want then return (tonumber(count) or 0) > 0 and count or 1, source end
    end
    return 0
end

-- My own totem in an element's slot: name, start, duration (nil when none is down).
function Totems:MyTotem(el)
    if self:IsDemo() and demo then return demo.myTotem(el) end
    if not GetTotemInfo then return nil end
    local have, name, start, duration = GetTotemInfo(D.ELEMENTS[el].slot)
    if have and name and name ~= "" and (duration or 0) > 0 then return name, start, duration end
    return nil
end

-- When I last dropped Windfury (the twist ring counts from it).
Totems.wfAt = nil
function Totems:WindfuryLeft()
    if self:IsDemo() and demo then return demo.wfLeft() end
    if not self.wfAt then return nil end
    local left = D.TWIST_WINDOW - (GetTime() - self.wfAt)
    return left > 0 and left or nil
end

-- ---------------------------------------------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------------------------------------------
function Totems:ReportLines()
    local lines = { "Totems:" }
    local roster = self:Roster()
    for _, s in ipairs(self:Shamans(roster)) do
        local parts = {}
        for el = 1, NEL do
            local idx = self:GetAssign(s.name, el)
            if idx then
                local text = D.TOTEMS[el][idx].short
                if el == 4 and self:GetTwist(s.name) then
                    local p = tonumber(Setting("twistWith", 2)) or 2
                    text = text .. " + " .. D.TOTEMS[4][p].short
                end
                parts[#parts + 1] = text
            end
        end
        local es = self:GetES(s.name)
        if es then parts[#parts + 1] = "Earth Shield on " .. es end
        local sub = self:SubgroupOf(s.name, roster)
        lines[#lines + 1] = strformat("%s%s: %s", s.name, sub and strformat(" (group %d)", sub) or "",
            #parts > 0 and tconcat(parts, ", ") or "nothing")
    end
    local by, order = self:Groups(roster)
    local none = {}
    for _, sub in ipairs(order) do
        if #by[sub].shamans == 0 then none[#none + 1] = tostring(sub) end
    end
    if IsInRaid() and #none > 0 then lines[#lines + 1] = "No shaman in group " .. tconcat(none, ", ") end
    local casters, backups = self:HeroCasters(roster)
    if #casters > 0 then
        local h = self:GetHero(casters[1])
        local when = ""
        for _, x in ipairs(D.HERO_WHEN) do if x.key == h then when = x.long:gsub("^Casts it ", "") end end
        lines[#lines + 1] = strformat("%s: %s %s%s", self:HeroName(), casters[1], when,
            #backups > 0 and (", backup " .. backups[1]) or "")
    end
    return lines
end

function Totems:Report()
    if self:IsDemo() then
        for _, line in ipairs(self:ReportLines()) do ns:Print("(demo) %s", line) end
        return true
    end
    if not IsInGroup() then return false end
    local chan = IsInRaid() and "RAID" or "PARTY"
    if InInstanceGroup() then chan = "INSTANCE_CHAT" end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    for _, line in ipairs(self:ReportLines()) do send(line, chan) end
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Wire (ShamanPower's protocol)
-- ---------------------------------------------------------------------------------------------------------------
function Totems:Channel()
    if InInstanceGroup() then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

function Totems:SendRaw(msg, target)
    if self:IsDemo() then return false end
    local chan = target and "WHISPER" or self:Channel()
    if not chan then return false end
    if #msg > 255 then msg = strsub(msg, 1, 255) end
    local CTL = _G.ChatThrottleLib
    if CTL and CTL.SendAddonMessage then
        CTL:SendAddonMessage("NORMAL", PREFIX, msg, chan, target)
    elseif C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, msg, chan, target)
    else
        return false
    end
    return true
end

-- "SELF <known earth>|<fire>|<water>|<air>|@<4 assignment chars>#<has ES 0/1>:<ES target>$<free 0/1>"
function Totems:EncodeSelf()
    local me = self:Me()
    local s = me and self.shamans[me]
    if not s then return "" end
    local known = {}
    for el = 1, NEL do
        local digits = {}
        for i = 1, #D.TOTEMS[el] do
            if s.known[el][i] then digits[#digits + 1] = tostring(i) end
        end
        known[el] = #digits > 0 and tconcat(digits) or "n"
    end
    local assign = {}
    for el = 1, NEL do
        local idx = self:GetAssign(me, el)
        assign[el] = idx and tostring(idx) or "n"
    end
    return strformat("SELF %s|@%s#%d:%s$%d", tconcat(known, "|"), tconcat(assign), s.es and 1 or 0,
        self:GetES(me) or "", s.free and 1 or 0)
end

-- The DisasterZone extras for one shaman: DZHERO, then their boss changes in chunks.
function Totems:SendExtras(name, target)
    local h = self:GetHero(name)
    if h and h ~= "none" then self:SendRaw(strformat("DZHERO %s %s", name, h), target) end
    local entries = {}
    for bossKey, b in pairs(DB().boss) do
        for el, o in pairs(b[name] or {}) do
            entries[#entries + 1] = strformat("%s %s %d %d %d", name, bossKey, el, o.i, o.alt and 1 or 0)
        end
    end
    tsort(entries)
    for i = 1, #entries, BOSS_PER_MSG do
        local chunk = {}
        for j = i, min(i + BOSS_PER_MSG - 1, #entries) do chunk[#chunk + 1] = entries[j] end
        self:SendRaw("DZBOSS " .. tconcat(chunk, "@"), target)
    end
end

-- Tells the group (or one player) who I am: SELF (shamans), TWIST, my extras; a leader also every shaman's extras.
function Totems:SendSelf(target)
    if not IsInGroup() then return end
    local me = self:Me()
    if not me then return end
    if self:IsShaman() then
        self:ScanSelf()
        self:SendRaw(self:EncodeSelf(), target)
        if self:GetTwist(me) then self:SendRaw(strformat("TWIST %s 1", me), target) end
        self:SendExtras(me, target)
    end
    if self:AmLeader() then
        for name in pairs(self.shamans) do
            if name ~= me then self:SendExtras(name, target) end
        end
    end
end

local selfQueued = false
function Totems:QueueSelf()
    if selfQueued then return end
    selfQueued = true
    local function go()
        selfQueued = false
        Totems:SendSelf()
    end
    if C_Timer and C_Timer.After then C_Timer.After(1 + math.random() * 2, go) else go() end
end

local function MayEdit(sender, name)
    if not name or name == "" then return false end
    if name == sender then return true end
    if Totems:IsLeader(sender) then return true end
    local s = Totems.shamans[name]
    return s and s.free or false
end
Totems.MayEdit = MayEdit

local HANDLERS = {}

HANDLERS.SELF = function(sender, msg)
    local knownPart, rest = strmatch(msg, "^SELF ([^@]*)@(.*)$")
    if not knownPart then return end
    local s = NewShaman(sender)
    local old = Totems.shamans[sender]
    if old then s.free = old.free end
    Totems.shamans[sender] = s
    local el = 0
    for group in gmatch(knownPart .. "|", "([^|]*)|") do
        el = el + 1
        if el > NEL then break end
        for d in gmatch(group, "%d") do
            local i = tonumber(d)
            if D.TOTEMS[el][i] then s.known[el][i] = true end
        end
    end
    local assign = strmatch(rest, "^([0-9n]*)") or ""
    local st = DB()
    st.assign[sender] = {}
    for e = 1, NEL do
        local idx = tonumber(strsub(assign, e, e))
        st.assign[sender][e] = (idx and idx > 0 and D.TOTEMS[e][idx]) and idx or nil
    end
    local hasES, target = strmatch(rest, "#([01]):([^$]*)")
    if hasES then
        s.es = hasES == "1"
        st.es[sender] = (target and target ~= "" and target ~= "NONE") and target or nil
    end
    local free = strmatch(rest, "%$([01])")
    if free then s.free = free == "1" end
    Changed()
end

HANDLERS.ASSIGN = function(sender, msg)
    local name, el, idx = strmatch(msg, "^ASSIGN (.+) (%d+) (%d+)$")
    el, idx = tonumber(el), tonumber(idx)
    if not (el and idx and D.TOTEMS[el]) or not MayEdit(sender, name) then return end
    SetAssignRaw(name, el, D.TOTEMS[el][idx] and idx or 0)
    Changed()
end

HANDLERS.PASSIGN = function(sender, msg)
    local name, chars = strmatch(msg, "^PASSIGN (.+)@([0-9n]*)")
    if not name or not MayEdit(sender, name) then return end
    for el = 1, NEL do
        local idx = tonumber(strsub(chars, el, el)) or 0
        SetAssignRaw(name, el, D.TOTEMS[el][idx] and idx or 0)
    end
    Changed()
end

HANDLERS.MASSIGN = function(sender, msg)
    local name, idx = strmatch(msg, "^MASSIGN (.+) (%d+)$")
    idx = tonumber(idx)
    if not idx or not MayEdit(sender, name) then return end
    for el = 1, NEL do SetAssignRaw(name, el, D.TOTEMS[el][idx] and idx or 0) end
    Changed()
end

HANDLERS.TWIST = function(sender, msg)
    local name, on = strmatch(msg, "^TWIST (.+) ([01])$")
    if not name or not MayEdit(sender, name) then return end
    DB().twist[name] = (on == "1") or nil
    Changed()
end

HANDLERS.ESASSIGN = function(sender, msg)
    local name, target = strmatch(msg, "^ESASSIGN|([^|]+)|(.+)$")
    if not name then name, target = strmatch(msg, "^ESASSIGN (%S+) (.+)$") end
    if not name or not MayEdit(sender, name) then return end
    DB().es[name] = (target and target ~= "NONE" and target ~= "") and target or nil
    Changed()
end

HANDLERS.CLEAR = function(sender)
    local function clear(name)
        DB().assign[name] = {}
        DB().twist[name] = nil
        DB().es[name] = nil
    end
    if Totems:IsLeader(sender) then
        for name in pairs(Totems.shamans) do clear(name) end
    else
        clear(sender)
    end
    Changed()
end

HANDLERS.FREEASSIGN = function(sender, msg)
    local s = Totems.shamans[sender]
    if not s then return end
    if strfind(msg, "FREEASSIGN YES") then s.free = true elseif strfind(msg, "FREEASSIGN NO") then s.free = false end
    Changed()
end

HANDLERS.DZHERO = function(sender, msg)
    local name, key = strmatch(msg, "^DZHERO (%S+) (%a+)$")
    if not name or not MayEdit(sender, name) then return end
    for _, h in ipairs(D.HERO_WHEN) do
        if h.key == key then DB().hero[name] = (key ~= "none") and key or nil end
    end
    Changed()
end

HANDLERS.DZBOSS = function(sender, msg)
    for name, bossKey, el, idx, alt in gmatch(strsub(msg, 8), "([^@ ]+) ([^@ ]+) (%d) (%d+) ([01])") do
        if MayEdit(sender, name) then
            el, idx = tonumber(el), tonumber(idx)
            if D.TOTEMS[el] then SetBossRaw(bossKey, name, el, D.TOTEMS[el][idx] and idx or 0, alt == "1") end
        end
    end
    Changed()
end

function Totems:OnMessage(text, channel, senderFull)
    if type(text) ~= "string" or type(senderFull) ~= "string" then return end
    if channel ~= "RAID" and channel ~= "PARTY" and channel ~= "INSTANCE_CHAT" and channel ~= "WHISPER" then return end
    local key = Util.NormalizeName(senderFull)
    if not key or Util.IsMe(key) then return end
    if not Util.IsInMyGroup(key) then return end
    local sender = Util.ShortName(key)
    local kind = strmatch(text, "^(%u+)")
    if kind == "REQ" then
        if Totems:IsShaman() or Totems:AmLeader() then Totems:QueueSelf() end
        return
    end
    local fn = kind and HANDLERS[kind]
    if fn then fn(sender, text) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Demo mode: the mockup's 25-man Serpentshrine raid. Four shamans, me as the Enhancement one (leading, twisting),
-- group 4 (hunters) has no shaman, Sunniva stands out of Mana Spring's range, Earth Shield on Caelith runs low,
-- Hydross changes two totems. Edits stay in memory; nothing is sent, scanned or cast.
-- ---------------------------------------------------------------------------------------------------------------
local DEMO_GROUPS = {
    { { "Victhar", "WARRIOR", "Protection", true }, { "Caelith", "PALADIN", "Protection", true },
      { "Moonwhisper", "DRUID", "Feral (Bear)", true }, { "Isolde", "PRIEST", "Holy" }, { "Ornaar", "SHAMAN", "Restoration" } },
    { { "Brakka", "WARRIOR", "Fury" }, { "Kordan", "WARRIOR", "Fury" }, { "Vexis", "ROGUE", "Combat" },
      { "Sunniva", "PALADIN", "Retribution" }, { "@me", "SHAMAN", "Enhancement" } },
    { { "Embera", "MAGE", "Fire" }, { "Frostweaver", "MAGE", "Frost" }, { "Grumpykat", "WARLOCK", "Destruction" },
      { "Nyxa", "PRIEST", "Shadow" }, { "Iridi", "SHAMAN", "Elemental" } },
    { { "Faelar", "HUNTER", "Beast Mastery" }, { "Tarrow", "HUNTER", "Beast Mastery" },
      { "Shadowmelder", "ROGUE", "Combat" }, { "Rhosyn", "DRUID", "Balance" }, { "Ulfric", "WARRIOR", "Arms" } },
    { { "Seraphel", "PRIEST", "Holy" }, { "Gina", "PALADIN", "Holy" }, { "Lightbringer", "PALADIN", "Holy" },
      { "Quillon", "DRUID", "Restoration" }, { "Velaara", "SHAMAN", "Restoration" } },
}

local function BuildDemo()
    local me = Totems:Me() or "You"
    local function nm(n)
        if n == "@me" then return me end
        if n == me then return "Thrallen" end           -- (my own name is taken by my shaman)
        return n
    end
    local d = { shamans = {}, roster = {}, byUnit = {}, specs = {}, started = GetTime(),
        store = { assign = {}, twist = {}, es = {}, hero = {}, boss = {} } }
    local i = 0
    for g, list in ipairs(DEMO_GROUPS) do
        for _, e in ipairs(list) do
            i = i + 1
            local m = { unit = "dzdemo" .. i, name = nm(e[1]), class = e[2], subgroup = g, level = 70, online = true,
                dead = false, demo = true, tank = e[4] or nil }
            d.specs[m.name] = e[3]
            d.roster[#d.roster + 1] = m
            d.byUnit[m.unit] = m
        end
    end
    for _, m in ipairs(d.roster) do m.role = RoleOf(m) end
    local function all(list)
        local t = {}
        for idx in ipairs(list) do t[idx] = true end
        return t
    end
    local function shaman(name, spec, opts)
        local s = { name = name, known = { all(D.TOTEMS[1]), all(D.TOTEMS[2]), all(D.TOTEMS[3]), all(D.TOTEMS[4]) },
            es = opts.es or false, free = false, seen = GetTime(), me = name == me or nil }
        if not opts.tow then s.known[2][1] = nil end
        if not opts.tide then s.known[3][3] = nil end
        d.shamans[name] = s
        d.specs[name] = spec
    end
    shaman("Ornaar", "Restoration", { es = true, tide = true })
    shaman(me, "Enhancement", {})
    shaman("Iridi", "Elemental", { tow = true })
    shaman("Velaara", "Restoration", { es = true, tide = true })
    local s = d.store
    s.assign.Ornaar = { 1, 2, 1, 1 }
    s.assign[me] = { 1, 2, 1, 1 }
    s.assign.Iridi = { 2, 1, 1, 3 }
    s.assign.Velaara = { 2, 2, 1, 3 }
    s.twist[me] = true
    s.hero[me], s.hero.Velaara = "pull", "backup"
    s.es.Ornaar, s.es.Velaara = "Victhar", "Caelith"
    s.boss["SerpentshrineCavern:Hydross"] = {}
    for _, n in ipairs({ "Ornaar", me, "Iridi", "Velaara" }) do
        s.boss["SerpentshrineCavern:Hydross"][n] = { [2] = { i = 6 }, [4] = { i = 6, alt = true } }
    end
    -- who has what: Sunniva stands out of Mana Spring; the rest of each party has their shaman's buffs
    d.hasBuff = function(unit, el, idx)
        local m = d.byUnit[unit]
        if not m then return false end
        if m.name == "Sunniva" and el == 3 then return false end
        for _, o in ipairs(d.roster) do
            if o.subgroup == m.subgroup and d.shamans[o.name] and s.assign[o.name] and s.assign[o.name][el] == idx then
                return true
            end
        end
        return false
    end
    d.esCharges = function(target)
        if target == "Caelith" then return 2, "Velaara" end
        if target == "Victhar" then return 6, "Ornaar" end
        return 0
    end
    -- my totems: dropped at different moments a while ago, so the rings sit at different places
    local DROPPED = { 46, 41, 30, 0 }
    d.myTotem = function(el)
        local idx = s.assign[me] and s.assign[me][el]
        if not idx then return nil end
        local t = D.TOTEMS[el][idx]
        local dur = t.dur or 120
        local age = (GetTime() - d.started + DROPPED[el]) % dur
        return Totems:TotemName(el, idx), GetTime() - age, dur
    end
    -- Windfury twisted every 10 s: 9.4 s since the last drop when the demo opens, so "drop now" shows first
    d.wfLeft = function()
        local age = (GetTime() - d.started + 9.4) % D.TWIST_WINDOW
        return D.TWIST_WINDOW - age
    end
    d.manaTide = function() return d.started - 120, 300 end
    return d
end

local realShamans
function Totems:OnDemoToggled(on)
    if on then
        demo = BuildDemo()
        realShamans = realShamans or self.shamans
        self.shamans = demo.shamans
    else
        if realShamans then self.shamans = realShamans end
        realShamans, demo = nil, nil
    end
    Changed()
end

function Totems:DemoState() return demo end

-- ---------------------------------------------------------------------------------------------------------------
-- Group changes
-- ---------------------------------------------------------------------------------------------------------------
function Totems:PruneRoster()
    local here = {}
    for _, m in ipairs(self:Roster()) do here[m.name] = true end
    local me = self:Me()
    local changed = false
    for name in pairs(self.shamans) do
        if name ~= me and not here[name] then
            self.shamans[name] = nil
            changed = true
        end
    end
    if changed then Changed() end
end

local function Hello(force)
    if Totems:IsDemo() or not IsInGroup() then return end
    Totems:SendSelf()
    local planner = ns.TotemsUI and ns.TotemsUI:IsShown()
    if force or planner or Totems:IsShaman() or Util.IsPlayerLeaderOrAssist() then Totems:SendRaw("REQ") end
end
Totems.Hello = Hello

function Totems:OnGroupLeft()
    local me = self:Me()
    local s = DB()
    for name in pairs(self.shamans) do
        if name ~= me then self.shamans[name] = nil end
    end
    -- (rows of shamans who are not me or in my guild go)
    for name in pairs(s.assign) do
        local key = Util.NormalizeName(name)
        local guildie = key and ns.Guild and ns.Guild.IsInGuild and ns.Guild:IsInGuild(key)
        if name ~= me and not guildie then
            s.assign[name], s.twist[name], s.es[name], s.hero[name] = nil, nil, nil, nil
        end
    end
    Changed()
end

function Totems:OnLogin()
    RealDB()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end
    ns:RegisterEvent("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender)
        if prefix == PREFIX then Totems:OnMessage(text, channel, sender) end
    end)
    if self:IsShaman() then self:ScanSelf() end
    ns:On("DEMO_TOGGLED", function(on) Totems:OnDemoToggled(on) end)
    if self:IsDemo() then self:OnDemoToggled(true) end
    local wasInGroup = IsInGroup()
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        local now = IsInGroup()
        if now and not wasInGroup then
            if C_Timer then C_Timer.After(2 + math.random() * 2, Hello) else Hello() end
        elseif not now and wasInGroup then
            Totems:OnGroupLeft()
        end
        wasInGroup = now
        if now then Util.Debounce("dz-totem-prune", 0.5, function() Totems:PruneRoster() end) end
        Changed()
    end)
    ns:RegisterEvent("SPELLS_CHANGED", function()
        if not Totems:IsShaman() or Totems:IsDemo() then return end
        Util.Debounce("dz-totem-spells", 1, function()
            if Totems:ScanSelf() then Totems:SendSelf() end
            Changed()
        end)
    end)
    -- my Windfury drops (the twist clock)
    ns:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellId)
        if unit ~= "player" then return end
        local t = spellId and BY_ID[spellId]
        if not t and spellId and GetSpellInfo then
            local name = GetSpellInfo(spellId)
            if name and name == Totems:TotemName(D.WINDFURY[1], D.WINDFURY[2]) then t = D.WINDFURY end
        end
        if t and t[1] == D.WINDFURY[1] and t[2] == D.WINDFURY[2] then Totems.wfAt = GetTime() end
        if t then ns:Fire("TOTEMS_LIVE") end
    end)
    ns:RegisterEvent("ENCOUNTER_START", function(_, encounterID)
        for _, b in ipairs(Totems:Bosses()) do
            if b.encounterID == encounterID then encounterBoss = b.key end
        end
    end)
    ns:RegisterEvent("ENCOUNTER_END", function() encounterBoss = nil end)
    ns:On("SETTINGS_CHANGED", function(path)
        if path == "totems.free" and Totems:IsShaman() then
            Totems:ScanSelf()
            local s = Totems.shamans[Totems:Me()]
            if s then Totems:SendRaw("FREEASSIGN " .. (s.free and "YES" or "NO")) end
            Changed()
        elseif type(path) == "string" and path:find("^totems") then
            Changed()
        end
    end)
    if IsInGroup() then
        if C_Timer then C_Timer.After(6 + math.random() * 6, Hello) else Hello() end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The class tool and /dz totems
-- ---------------------------------------------------------------------------------------------------------------
ns.ClassKit:Register({ key = "totems", label = "Totems", class = "SHAMAN", order = 10, icon = 8512 })

ns:RegisterSlash("totems", function(rest)
    rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "report" then
        if not Totems:Report() then ns:Print("Not in a group.") end
    elseif rest == "auto" then
        if not Totems:AutoAssign() then ns:Print("You can't assign any shaman here.") end
    elseif rest == "unlock" or rest == "lock" then
        ns.DB:SetSetting("totems.locked", rest == "lock")
    elseif ns.TotemsUI then
        ns.TotemsUI:Toggle()
    end
end, "Shaman totem planner (report | auto | unlock | lock)")

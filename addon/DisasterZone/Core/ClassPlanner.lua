if DisasterZoneBoot and DisasterZoneBoot.Run("Core/ClassPlanner.lua", ...) then return end -- DisasterZone Core/ClassPlanner.lua
-- shared core of the class planners (Blessings, Totems) (refactor phase 4).
local addonName, ns = ...

-- A class planner (Core/Blessings.lua for paladins, Core/Totems.lua for shamans) is one plan the class's players in a
-- group share over another addon's wire protocol (Pally Power's PLPWR, ShamanPower's SHPWR): who gives what. Both
-- planners are the same machine around their own plan; this file is that machine, the class files keep their plan,
-- their messages (encoders and handlers, byte for byte the other addon's) and their planning logic.
--
--   local P = ns.ClassPlanner:Define(Module, kind)    installs the shared parts on Module, returns its planner record
--
-- kind (the planner kind; hooks may be set on the returned record later, before login):
--   class      "PALADIN"        the class the planner is for
--   isClass    "IsPaladin"      the module's "am I that class" method (demo mode: always)
--   records    "pals"           the module's table of the class's players: [wire name] = record (.free, .me ...)
--   prefix     "PLPWR"          the addon-message prefix
--   setting    "bless"          the settings' prefix ("bless.free", "bless.pets" ...)
--   event      "BLESSINGS_CHANGED"   fired (once per frame) when anything changed
--   tag        "dz-bless"       the debounce keys' prefix
--   ui         "BlessingsUI"    the planner window's module (Hello asks the others while it is open)
--   kit        ClassKit:Register's entry; slash, slashHelp, noneToAssign: /dz <slash> (report | auto | unlock | lock)
--   storeAtLogin   create the saved store at login (Totems)
--   skipSpellsInDemo   SPELLS_CHANGED does nothing in demo mode (Totems)
-- hooks on the record:
--   realStore()        the saved store (account wide, created on first use)
--   handlers           [message kind] = function(sender, text): the class's wire
--   buildDemo()        demo mode's made-up raid: { [records] = ..., store = ..., ... } (record.demo while on)
--   forget(store, name)    leaving a group: drop a player who is neither me nor in my guild
--   groupLeft(store)       leaving a group: what else goes (Blessings: every single blessing)
--   onLogin(Module)        the class's own events, registered after the shared ones
--
-- What the module gets:
--   plain functions  Store(), Setting(path, default), Changed(), Wire(name), Queue(key, msg, now), Unqueue(key),
--                    Flush(), MayEdit(sender, name), Hello(force)
--   methods          Me, IsDemo, InGroup, <isClass>, IsLeader, AmLeader, LeaderName, CanEdit, CanEditAny, Channel,
--                    SendRaw, QueueSelf, OnMessage, Report, ScanRoster, PruneRoster, OnGroupLeft, OnDemoToggled,
--                    DemoState, OnLogin
--   The module itself provides SendSelf, ScanSelf, ReportLines, AutoAssign and Roster (built on ScanRoster).
-- Every shared method calls the others through the module (self:CanEdit ...), so a stub on the module (the UI audit's
-- seeded raid) is what the shared code sees too.
--
-- Who may change what (as Pally Power / ShamanPower): my own row always; anyone's while I am the raid leader or an
-- assistant (the party leader in a party; nobody in a battleground); a player who allows "anyone may assign me"
-- (FREEASSIGN YES). Received edits are taken from the player themselves, a leader, or for a player who allows anyone.

local CP = {}
ns.ClassPlanner = CP

local Util = ns.Util

local type, pairs, ipairs, select = type, pairs, ipairs, select
local strsub, strmatch = string.sub, string.match

local SEND_DELAY = 0.8           -- edits go out this long after the last click on the same cell (Pally Power: 2 s)

-- In a battleground / instance group (nobody leads there, as the other addons count it)?
local function InInstanceGroup()
    return LE_PARTY_CATEGORY_INSTANCE and IsInGroup and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and IsInInstance
        and IsInInstance() and true or false
end
CP.InInstanceGroup = InInstanceGroup

-- A player's name as the other addons send it: Name on my realm, Name-Realm otherwise.
local function Wire(nameOrKey)
    local key = Util.NormalizeName(nameOrKey)
    return key and Util.ShortName(key) or nil
end
CP.Wire = Wire

local function After(sec, fn)
    if C_Timer and C_Timer.After then C_Timer.After(sec, fn) else fn() end
end

local M = {}               -- the shared methods (copied onto each module)

function M:Me()
    local k = Util.PlayerKey()
    return k and Util.ShortName(k) or nil
end

-- Demo mode (Core/Demo.lua): a made-up raid with me among the class's players and leading. Edits stay in memory;
-- nothing is sent, scanned or cast.
function M:IsDemo()
    return ns.ClassKit and ns.ClassKit:IsDemo() or false
end

-- In a group (or the demo's raid)?
function M:InGroup()
    return self:IsDemo() or IsInGroup()
end

function M:IsMyClass()
    if self:IsDemo() then return true end
    local _, cls = UnitClass("player")
    return cls == self.planner.class
end

-- Who leads, as Pally Power counts it: raid leader and assistants in a raid, the party leader in a party, nobody
-- in a battleground.
function M:IsLeader(name)
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

function M:AmLeader() return self:IsLeader(self:Me()) end

-- The leader's name (raid leader or party leader), for "X assigns".
function M:LeaderName()
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

-- May I change this player's plan?
function M:CanEdit(name)
    if not name then return false end
    if self:IsDemo() then return true end
    if name == self:Me() then return true end
    local r = self[self.planner.records][name]
    if InInstanceGroup() then return r and r.free or false end
    if Util.IsPlayerLeaderOrAssist() and IsInGroup() then return true end
    return r and r.free or false
end

function M:CanEditAny()
    for name in pairs(self[self.planner.records]) do
        if self:CanEdit(name) then return true end
    end
    return false
end

-- Group members (pets too when asked): { unit, name, class, subgroup, level, pet, tank, online, dead, raidIndex }, in
-- roster order. accept(classFile) -> false drops a member (a class the planner has no column for).
function M:ScanRoster(pets, accept)
    local out = {}
    local function add(unit, subgroup, rrole, isPet, raidIndex)
        if not UnitExists(unit) then return end
        local cls = UnitClassBase and UnitClassBase(unit) or select(2, UnitClass(unit))
        if not cls or (accept and not accept(cls)) then return end
        local name = GetUnitName(unit, true)
        if not name then return end
        out[#out + 1] = { unit = unit, name = Wire(name) or name, class = cls, subgroup = subgroup or 1,
            level = UnitLevel(unit) or 70, pet = isPet or nil, tank = rrole == "MAINTANK" or nil,
            online = UnitIsConnected(unit) and true or false, dead = UnitIsDeadOrGhost(unit) and true or false,
            raidIndex = raidIndex }
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local _, _, subgroup, _, _, _, _, _, _, rrole = GetRaidRosterInfo(i)
            add("raid" .. i, subgroup, rrole, nil, i)
            if pets then add("raidpet" .. i, subgroup, nil, true) end
        end
    else
        add("player", 1)
        if pets then add("pet", 1, nil, true) end
        if IsInGroup() then
            for i = 1, 4 do
                add("party" .. i, 1)
                if pets then add("partypet" .. i, 1, nil, true) end
            end
        end
    end
    -- nobody set as a main tank yet: the plan's tanks for this boss (Core/Tanks.lua)
    local flagged = false
    for _, m in ipairs(out) do if m.tank then flagged = true break end end
    if not flagged and ns.Tanks and ns.Util then
        for _, m in ipairs(out) do
            if not m.pet and ns.Tanks:PlanFor(ns.Util.NormalizeName(m.name)) then m.tank = true end
        end
    end
    -- tanks the group roles name too
    for _, m in ipairs(out) do
        if not m.tank and not m.pet then
            local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(m.unit)
            if role == "TANK" then m.tank = true end
        end
    end
    return out
end

-- The plan as chat lines (ReportLines) to the raid or party; in demo mode only to me.
function M:Report()
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
-- Wire
-- ---------------------------------------------------------------------------------------------------------------
function M:Channel()
    if InInstanceGroup() then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

function M:SendRaw(msg, target)
    if self:IsDemo() then return false end
    local chan = target and "WHISPER" or self:Channel()
    if not chan then return false end
    if #msg > 255 then msg = strsub(msg, 1, 255) end
    local prefix = self.planner.prefix
    local CTL = _G.ChatThrottleLib     -- (comes with AceComm-3.0)
    if CTL and CTL.SendAddonMessage then
        CTL:SendAddonMessage("NORMAL", prefix, msg, chan, target)
    elseif C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(prefix, msg, chan, target)
    else
        return false
    end
    return true
end

-- Sends SELF to the group once, 1-3 s from now (later calls in the meantime ride along).
function M:QueueSelf()
    local P = self.planner
    if P.selfQueued then return end
    P.selfQueued = true
    local mod = self
    After(1 + math.random() * 2, function()
        P.selfQueued = false
        mod:SendSelf()
    end)
end

function M:OnMessage(text, channel, senderFull)
    if type(text) ~= "string" or type(senderFull) ~= "string" then return end
    if channel ~= "RAID" and channel ~= "PARTY" and channel ~= "INSTANCE_CHAT" and channel ~= "WHISPER" then return end
    local key = Util.NormalizeName(senderFull)
    if not key or Util.IsMe(key) then return end
    if not Util.IsInMyGroup(key) then return end        -- only group members (whispers too)
    local sender = Util.ShortName(key)
    local kind = strmatch(text, "^(%u+)")
    local P = self.planner
    if kind == "REQ" then
        -- (the other addons whisper every asker; one broadcast a moment later answers everyone who asked meanwhile,
        -- their users included, without a whisper per player per asker)
        if self[P.isClass](self) or self:AmLeader() then self:QueueSelf() end
        return
    end
    local fn = kind and P.handlers and P.handlers[kind]
    if fn then fn(sender, text) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Demo mode and group changes
-- ---------------------------------------------------------------------------------------------------------------
function M:OnDemoToggled(on)
    local P = self.planner
    if on then
        P.demo = P.buildDemo()
        P.real = P.real or self[P.records]
        self[P.records] = P.demo[P.records]
    else
        if P.real then self[P.records] = P.real end
        P.real, P.demo = nil, nil
    end
    self.Changed()
end

function M:DemoState() return self.planner.demo end

-- Drops players who left; keeps me.
function M:PruneRoster()
    local here = {}
    for _, m in ipairs(self:Roster()) do
        if not m.pet then here[m.name] = true end
    end
    local me = self:Me()
    local recs = self[self.planner.records]
    local changed = false
    for name in pairs(recs) do
        if name ~= me and not here[name] then
            recs[name] = nil
            changed = true
        end
    end
    if changed then self.Changed() end
end

-- Leaving the group: the others go; the plan of players who are neither me nor in my guild goes (as Pally Power).
function M:OnGroupLeft()
    local P = self.planner
    local me = self:Me()
    local s = self.Store()
    local recs = self[P.records]
    for name in pairs(recs) do
        if name ~= me then recs[name] = nil end
    end
    if P.groupLeft then P.groupLeft(s) end
    for name in pairs(s.assign) do
        local key = Util.NormalizeName(name)
        local guildie = key and ns.Guild and ns.Guild.IsInGuild and ns.Guild:IsInGuild(key)
        if name ~= me and not guildie then P.forget(s, name) end
    end
    self.Changed()
end

function M:OnLogin()
    local mod, P = self, self.planner
    local Changed = self.Changed
    if P.storeAtLogin then P.realStore() end
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(P.prefix) end
    ns:RegisterEvent("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender)
        if prefix == P.prefix then mod:OnMessage(text, channel, sender) end
    end)
    if mod[P.isClass](mod) then mod:ScanSelf() end
    ns:On("DEMO_TOGGLED", function(on) mod:OnDemoToggled(on) end)
    if mod:IsDemo() then mod:OnDemoToggled(true) end
    local wasInGroup = IsInGroup()
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        local now = IsInGroup()
        if now and not wasInGroup then
            if C_Timer then C_Timer.After(2 + math.random() * 2, mod.Hello) else mod.Hello() end
        elseif not now and wasInGroup then
            mod:OnGroupLeft()
        end
        wasInGroup = now
        if now then Util.Debounce(P.tag .. "-prune", 0.5, function() mod:PruneRoster() end) end
        Changed()
    end)
    ns:RegisterEvent("SPELLS_CHANGED", function()
        if not mod[P.isClass](mod) or (P.skipSpellsInDemo and mod:IsDemo()) then return end
        Util.Debounce(P.tag .. "-spells", 1, function()
            if mod:ScanSelf() then mod:SendSelf() end
            Changed()
        end)
    end)
    if P.onLogin then P.onLogin(mod) end
    local free = P.setting .. ".free"
    local pattern = "^" .. P.setting
    ns:On("SETTINGS_CHANGED", function(path)
        if path == free and mod[P.isClass](mod) then
            mod:ScanSelf()
            local r = mod[P.records][mod:Me()]
            if r then mod:SendRaw("FREEASSIGN " .. (r.free and "YES" or "NO")) end
            Changed()
        elseif type(path) == "string" and path:find(pattern) then
            Changed()
        end
    end)
    if IsInGroup() then
        -- (after a login or /reload in a group: after ChatThrottleLib's quiet first seconds, spread out)
        if C_Timer then C_Timer.After(6 + math.random() * 6, mod.Hello) else mod.Hello() end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Define
-- ---------------------------------------------------------------------------------------------------------------
function CP:Define(mod, kind)
    local P = {}
    for k, v in pairs(kind) do P[k] = v end
    P.pending, P.order = {}, {}
    mod.planner = P
    mod.PREFIX = P.prefix
    for name, fn in pairs(M) do mod[name] = fn end
    mod[P.isClass] = M.IsMyClass

    -- the store: demo mode's (in memory) while it is on, else the saved one
    function mod.Store()
        local d = P.demo
        if d and mod:IsDemo() then return d.store end
        return P.realStore()
    end

    function mod.Setting(path, default)
        local v = ns.DB and ns.DB:GetSetting(P.setting .. "." .. path)
        if v == nil then return default end
        return v
    end

    -- (once per frame however many changes come)
    local function fire()
        P.changedQueued = false
        ns:Fire(P.event)
    end
    function mod.Changed()
        if P.changedQueued then return end
        P.changedQueued = true
        After(0, fire)
    end

    mod.Wire = Wire

    -- Edits (permission checked by the caller) go to the group a moment later; a later edit of the same cell (key)
    -- replaces the one waiting.
    local function Flush()
        P.flushQueued = false
        local list = P.order
        P.order = {}
        for _, k in ipairs(list) do
            local msg = P.pending[k]
            P.pending[k] = nil
            if msg then mod:SendRaw(msg) end
        end
    end
    mod.Flush = Flush

    function mod.Queue(k, msg, now)
        if not P.pending[k] then P.order[#P.order + 1] = k end
        P.pending[k] = msg
        if now then Flush() return end
        if not P.flushQueued then
            P.flushQueued = true
            After(SEND_DELAY, Flush)
        end
    end

    function mod.Unqueue(k) P.pending[k] = nil end

    -- Accepts an edit of player name from sender: their own, a leader's, or for a player who lets anyone assign.
    function mod.MayEdit(sender, name)
        if not name or name == "" then return false end
        if name == sender then return true end
        if mod:IsLeader(sender) then return true end
        local r = mod[P.records][name]
        return r and r.free or false
    end

    -- Says hello on joining a group: who I am, and (the class, leaders, or with the planner open) asks the others.
    -- Every player of the class answers a REQ, so the rest of the raid does not ask until it looks.
    function mod.Hello(force)
        if mod:IsDemo() or not IsInGroup() then return end
        mod:SendSelf()
        local ui = ns[P.ui]
        local planner = ui and ui:IsShown()
        if force or planner or mod[P.isClass](mod) or Util.IsPlayerLeaderOrAssist() then mod:SendRaw("REQ") end
    end

    -- the class tool and /dz <slash>
    if P.kit and ns.ClassKit then ns.ClassKit:Register(P.kit) end
    if P.slash then
        ns:RegisterSlash(P.slash, function(rest)
            rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
            if rest == "report" then
                if not mod:Report() then ns:Print("Not in a group.") end
            elseif rest == "auto" then
                if not mod:AutoAssign() then ns:Print(P.noneToAssign) end
            elseif rest == "move" or rest == "unlock" then
                if ns.EditMode then ns.EditMode:Open() end      -- (the bar moves in Edit layout)
            elseif ns[P.ui] then
                ns[P.ui]:Toggle()
            end
        end, P.slashHelp)
    end
    return P
end

if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Blessings.lua", ...) then return end -- DisasterZone: paladin blessings.
-- The paladin Blessings planner (a class tool, Core/ClassKit.lua, for every paladin spec): who gives which Greater
-- Blessing to which class, single blessings for one player instead of the class one ("exceptions", e.g. tanks get
-- Light instead of Salvation), and each paladin's aura. The window is UI/BlessingsUI.lua, the in-raid buff bar
-- UI/BlessingsBar.lua.
--
-- Sync speaks Pally Power's own wire protocol (prefix PLPWR, plain text; dev/docs/research/pallypower.md), so
-- DisasterZone and Pally Power users in one raid share one plan. Nothing of Pally Power's code is used. Everyone keeps
-- a copy of every paladin's assignments by the paladin's name as Pally Power writes it (Name on my realm, Name-Realm
-- otherwise). A paladin's own SELF message is the truth for their row.
--
-- Who may change what (as Pally Power): my own row always; anyone's while I am the raid leader or an assistant (the
-- party leader in a party; nobody in a battleground); a paladin who allows "anyone may assign me" (FREEASSIGN YES).
-- Received edits are taken from the paladin themselves, a leader, or for a paladin who allows anyone.
--
-- Saved (account wide, as Pally Power): db.blessings.assign / single / aura, kept over a /reload, and the presets.
local addonName, ns = ...

local Blessings = ns:NewModule("Blessings")
local Util = ns.Util
local D = ns.ClassData.PALADIN

local type, pairs, ipairs, tonumber, tostring, select, next = type, pairs, ipairs, tonumber, tostring, select, next
local floor, max, min = math.floor, math.max, math.min
local strformat, strsub, strmatch, strfind, gmatch = string.format, string.sub, string.match, string.find, string.gmatch
local tinsert, tconcat, tsort, wipe = table.insert, table.concat, table.sort, wipe or function(t) for k in pairs(t) do t[k] = nil end return t end

local PREFIX = "PLPWR"
local NCLASS, NGREATER, NBLESS, NAURA = #D.CLASSES, D.GREATER_MAX, #D.BLESSINGS, #D.AURAS
local SEND_DELAY = 0.8           -- edits go out this long after the last click on the same cell (Pally Power: 2 s)
local NASSIGN_PER_MSG = 5

Blessings.PREFIX = PREFIX
Blessings.D = D

local CLASS_INDEX = {}           -- class token -> Pally Power index
for i, c in ipairs(D.CLASSES) do CLASS_INDEX[c] = i end
Blessings.CLASS_INDEX = CLASS_INDEX

-- every rank's spell id -> blessing index, and which are Greater
local BLESS_BY_ID, GREATER_ID = {}, {}
for bi, b in ipairs(D.BLESSINGS) do
    for _, r in ipairs(b.ranks) do BLESS_BY_ID[r[1]] = bi end
    for _, r in ipairs(b.granks or {}) do BLESS_BY_ID[r[1]] = bi; GREATER_ID[r[1]] = true end
end
local AURA_BY_ID = {}
for ai, a in ipairs(D.AURAS) do
    for _, id in ipairs(a.ranks) do AURA_BY_ID[id] = ai end
end
Blessings.BLESS_BY_ID, Blessings.AURA_BY_ID = BLESS_BY_ID, AURA_BY_ID

Blessings.pals = {}              -- [wire name] = paladin record (see NewPal)
Blessings.ppLeader = false       -- a leader of the group announced Pally Power (PPLEADER)

local demo                       -- demo mode's made-up raid (BuildDemo), in memory only

local function DB()
    if demo and Blessings:IsDemo() then return demo.store end
    local db = ns.db
    if not db then return nil end
    db.blessings = db.blessings or {}
    local b = db.blessings
    b.assign = b.assign or {}
    b.single = b.single or {}
    b.aura = b.aura or {}
    b.presets = b.presets or {}
    return b
end
Blessings.Store = DB

local function Setting(path, default)
    local v = ns.DB and ns.DB:GetSetting("bless." .. path)
    if v == nil then return default end
    return v
end
Blessings.Setting = Setting

local changedQueued = false
local function Changed()
    if changedQueued then return end
    changedQueued = true
    local function fire()
        changedQueued = false
        ns:Fire("BLESSINGS_CHANGED")
    end
    if C_Timer and C_Timer.After then C_Timer.After(0, fire) else fire() end
end
Blessings.Changed = Changed

-- ---------------------------------------------------------------------------------------------------------------
-- Names, spells
-- ---------------------------------------------------------------------------------------------------------------
-- A player's name as Pally Power sends it: Name on my realm, Name-Realm otherwise.
local function Wire(nameOrKey)
    local key = Util.NormalizeName(nameOrKey)
    return key and Util.ShortName(key) or nil
end
Blessings.Wire = Wire

function Blessings:Me()
    local k = Util.PlayerKey()
    return k and Util.ShortName(k) or nil
end

function Blessings:IsPaladin()
    if self:IsDemo() then return true end
    local _, cls = UnitClass("player")
    return cls == "PALADIN"
end

-- Demo mode (Core/Demo.lua): a made-up 25-man raid with four paladins, me one of them and leading. Edits stay in
-- memory; nothing is sent, scanned or cast.
function Blessings:IsDemo()
    return ns.ClassKit and ns.ClassKit:IsDemo() or false
end

-- In a group (or the demo's raid)?
function Blessings:InGroup()
    return self:IsDemo() or IsInGroup()
end

local function SpellName(id)
    local n = GetSpellInfo and GetSpellInfo(id)
    return n
end

-- A blessing's (or with greater=true its Greater's) localized name, by the first rank.
function Blessings:BlessingName(bi, greater)
    local b = D.BLESSINGS[bi]
    if not b then return nil end
    local ranks = greater and b.granks or b.ranks
    local n = ranks and ranks[1] and SpellName(ranks[1][1])
    return n or ((greater and "Greater " or "") .. "Blessing of " .. b.short)
end

function Blessings:AuraName(ai)
    local a = D.AURAS[ai]
    if not a then return nil end
    return SpellName(a.ranks[1]) or (a.short .. " Aura")
end

-- (the client's own icon files, Data/Classes/Paladin.lua; the spell's texture only when a blessing has none there)
function Blessings:BlessingIcon(bi, greater)
    local b = D.BLESSINGS[bi]
    if not b then return nil end
    if greater and b.gicon then return b.gicon end
    if b.icon then return b.icon end
    local ranks = greater and b.granks or b.ranks
    return ranks and ranks[1] and GetSpellTexture and GetSpellTexture(ranks[1][1])
end

function Blessings:AuraIcon(ai)
    local a = D.AURAS[ai]
    if not a then return nil end
    return a.icon or (GetSpellTexture and GetSpellTexture(a.ranks[1]))
end

-- ---------------------------------------------------------------------------------------------------------------
-- Paladins
-- ---------------------------------------------------------------------------------------------------------------
local function NewPal(name)
    return { name = name, bless = {}, aura = {}, symbols = nil, free = false, cd = {}, seen = GetTime() }
end

local function Pal(name, create)
    local p = Blessings.pals[name]
    if not p and create then
        p = NewPal(name)
        Blessings.pals[name] = p
    end
    return p
end
Blessings.Pal = Pal

-- Known paladins: me first, then by name.
function Blessings:Paladins()
    local out, me = {}, self:Me()
    for _, p in pairs(self.pals) do out[#out + 1] = p end
    tsort(out, function(a, b)
        if (a.name == me) ~= (b.name == me) then return a.name == me end
        return a.name < b.name
    end)
    return out
end

-- Rank (1..n, nil = not known) of the highest known rank.
local function KnownRank(ranks)
    if not IsSpellKnown then return nil end
    for i = #ranks, 1, -1 do
        local id = type(ranks[i]) == "table" and ranks[i][1] or ranks[i]
        if IsSpellKnown(id) then return i end
    end
    return nil
end

-- Talent ranks by the talent's icon (Pally Power's way: a talent shares its spell's icon).
local function TalentsByIcon()
    local map = {}
    if not (GetNumTalentTabs and GetNumTalents and GetTalentInfo) then return map end
    for t = 1, GetNumTalentTabs() or 0 do
        for i = 1, GetNumTalents(t) or 0 do
            local _, icon, _, _, rank = GetTalentInfo(t, i)
            if icon then map[icon] = tonumber(rank) or 0 end
        end
    end
    return map
end

-- Reads my own blessings, auras, talents and Symbols into my paladin record; true when anything changed.
function Blessings:ScanSelf()
    if self:IsDemo() then return false end
    local me = self:Me()
    if not me or not self:IsPaladin() then return false end
    local p = Pal(me, true)
    local talents = TalentsByIcon()
    local before = self:EncodeSelf() .. (p.symbols or "")
    for bi = 1, NBLESS do
        local b = D.BLESSINGS[bi]
        local rank = KnownRank(b.ranks)
        if rank then
            local t = 0
            if D.BLESSING_TALENTS[bi] then
                local icon = GetSpellTexture and GetSpellTexture(b.ranks[1][1])
                t = icon and talents[icon] or 0
            end
            p.bless[bi] = { rank, t }
        else
            p.bless[bi] = nil
        end
    end
    for ai = 1, NAURA do
        local a = D.AURAS[ai]
        local rank = KnownRank(a.ranks)
        if rank then
            local t = 0
            if D.AURA_TALENTS[ai] then
                local icon = GetSpellTexture and GetSpellTexture(a.ranks[1])
                t = icon and talents[icon] or 0
            end
            p.aura[ai] = { rank, t }
        else
            p.aura[ai] = nil
        end
    end
    p.symbols = GetItemCount and GetItemCount(D.SYMBOL_OF_KINGS) or 0
    p.free = Setting("free", false) and true or false
    p.seen = GetTime()
    p.me = true
    return (self:EncodeSelf() .. (p.symbols or "")) ~= before
end

function Blessings:Can(name, bi)
    local p = self.pals[name]
    return p and p.bless[bi] ~= nil or false
end

function Blessings:CanAura(name, ai)
    local p = self.pals[name]
    return p and p.aura[ai] ~= nil or false
end

-- The talents a paladin's card shows: "Kings · Sanctuary", "Imp. Might 5/5", "Imp. Wisdom 2/2" ...
function Blessings:TalentLine(name)
    local p = self.pals[name]
    if not p then return "" end
    local out = {}
    local function t(bi) return p.bless[bi] and p.bless[bi][2] or 0 end
    if p.bless[3] then out[#out + 1] = "Kings" end
    if p.bless[6] then out[#out + 1] = "Sanctuary" end
    if t(2) > 0 then out[#out + 1] = strformat("Imp. Might %d/5", t(2)) end
    if t(1) > 0 then out[#out + 1] = strformat("Imp. Wisdom %d/2", t(1)) end
    return tconcat(out, " · ")
end

-- The spec a paladin plays, best guess: mine from my talents, others from the raid plan, else from what their
-- blessings say (Sanctuary = Protection, Improved Might 3+ = Retribution, else Holy).
function Blessings:SpecOf(name)
    if self:IsDemo() and demo and demo.specs[name] then return demo.specs[name] end
    if name == self:Me() then
        local mine = ns.ClassKit and ns.ClassKit:MySpecs()
        if mine and mine[1] then return mine[1] end
    end
    local key = Util.NormalizeName(name)
    if key and ns.RaidPlan and ns.RaidPlan.GetMemberSpec then
        local ok, sp = pcall(ns.RaidPlan.GetMemberSpec, ns.RaidPlan, key)
        if ok and type(sp) == "string" and sp ~= "" then return sp end
    end
    local p = self.pals[name]
    if p then
        if p.bless[6] then return "Protection" end
        if p.bless[2] and (p.bless[2][2] or 0) >= 3 then return "Retribution" end
    end
    return "Holy"
end

-- ---------------------------------------------------------------------------------------------------------------
-- The group
-- ---------------------------------------------------------------------------------------------------------------
local function InInstanceGroup()
    return LE_PARTY_CATEGORY_INSTANCE and IsInGroup and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and IsInInstance
        and IsInInstance() and true or false
end

-- Who leads, as Pally Power counts it: raid leader and assistants in a raid, the party leader in a party, nobody
-- in a battleground.
function Blessings:IsLeader(name)
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

function Blessings:AmLeader() return self:IsLeader(self:Me()) end

-- The leader's name (raid leader or party leader), for "X assigns".
function Blessings:LeaderName()
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

-- May I change this paladin's assignments?
function Blessings:CanEdit(name)
    if not name then return false end
    if self:IsDemo() then return true end
    if name == self:Me() then return true end
    local p = self.pals[name]
    if InInstanceGroup() then return p and p.free or false end
    if Util.IsPlayerLeaderOrAssist() and IsInGroup() then return true end
    return p and p.free or false
end

function Blessings:CanEditAny()
    for name in pairs(self.pals) do
        if self:CanEdit(name) then return true end
    end
    return false
end

-- Group members (and pets): { unit, name, class, ci, subgroup, level, pet, tank, online, dead }, in roster order.
function Blessings:Roster()
    if self:IsDemo() and demo then return demo.roster end
    local out = {}
    local pets = Setting("pets", true)
    local function add(unit, subgroup, role, isPet)
        if not UnitExists(unit) then return end
        local cls = UnitClassBase and UnitClassBase(unit) or select(2, UnitClass(unit))
        local ci = cls and CLASS_INDEX[cls]
        if not ci then return end
        local name = GetUnitName(unit, true)
        if not name then return end
        out[#out + 1] = { unit = unit, name = Wire(name) or name, class = cls, ci = ci, subgroup = subgroup or 1,
            level = UnitLevel(unit) or 70, pet = isPet or nil, tank = role == "MAINTANK" or nil,
            online = UnitIsConnected(unit) and true or false, dead = UnitIsDeadOrGhost(unit) and true or false }
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local _, _, subgroup, _, _, _, _, _, _, role = GetRaidRosterInfo(i)
            add("raid" .. i, subgroup, role)
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
    -- tanks the raid plan or the group roles name too
    for _, m in ipairs(out) do
        if not m.tank and not m.pet then
            local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(m.unit)
            if role == "TANK" then m.tank = true end
        end
    end
    return out
end

-- Members per class index: { [ci] = { member, ... } }
function Blessings:ByClass(roster)
    local by = {}
    for ci = 1, NCLASS do by[ci] = {} end
    for _, m in ipairs(roster or self:Roster()) do tinsert(by[m.ci], m) end
    return by
end

-- ---------------------------------------------------------------------------------------------------------------
-- Assignments
-- ---------------------------------------------------------------------------------------------------------------
function Blessings:GetAssign(name, ci)
    local s = DB()
    local row = s and s.assign[name]
    local bi = row and row[ci]
    return (bi and bi > 0) and bi or nil
end

function Blessings:GetAura(name)
    local s = DB()
    local ai = s and s.aura[name]
    return (ai and ai > 0) and ai or nil
end

-- name's single blessings: { [ci] = { [target] = bi } } (read only)
function Blessings:GetSingles(name)
    local s = DB()
    return s and s.single[name] or {}
end

function Blessings:GetSingle(name, ci, target)
    local row = self:GetSingles(name)[ci]
    local bi = row and row[target]
    return (bi and bi > 0) and bi or nil
end

-- Every exception: { { pal, ci, target, bi }, ... } for the paladins known, sorted by target.
function Blessings:Exceptions()
    local out = {}
    local s = DB()
    if not s then return out end
    for pal, byClass in pairs(s.single) do
        if self.pals[pal] then
            for ci, targets in pairs(byClass) do
                for target, bi in pairs(targets) do
                    if bi and bi > 0 then out[#out + 1] = { pal = pal, ci = ci, target = target, bi = bi } end
                end
            end
        end
    end
    tsort(out, function(a, b)
        if a.target ~= b.target then return a.target < b.target end
        return a.pal < b.pal
    end)
    return out
end

-- Who gives class ci blessing bi (nil when nobody does).
function Blessings:Giver(ci, bi)
    for _, p in ipairs(self:Paladins()) do
        if self:GetAssign(p.name, ci) == bi then return p.name end
    end
    return nil
end

local function SetAssignRaw(name, ci, bi)
    local s = DB()
    s.assign[name] = s.assign[name] or {}
    s.assign[name][ci] = (bi and bi > 0) and bi or nil
end

local function SetSingleRaw(name, ci, target, bi)
    local s = DB()
    s.single[name] = s.single[name] or {}
    s.single[name][ci] = s.single[name][ci] or {}
    s.single[name][ci][target] = (bi and bi > 0) and bi or nil
    if not next(s.single[name][ci]) then s.single[name][ci] = nil end
end

local function SetAuraRaw(name, ai)
    DB().aura[name] = (ai and ai > 0) and ai or nil
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
        if msg then Blessings:SendRaw(msg) end
    end
end

-- Queues msg under key k (a later edit of the same cell replaces it).
local function Queue(k, msg, now)
    if not pending[k] then pendingOrder[#pendingOrder + 1] = k end
    pending[k] = msg
    if now then Flush() return end
    if not flushQueued then
        flushQueued = true
        if C_Timer and C_Timer.After then C_Timer.After(SEND_DELAY, Flush) else Flush() end
    end
end
Blessings.Flush = Flush

function Blessings:SetAssign(name, ci, bi)
    if not self:CanEdit(name) or not D.CLASSES[ci] then return false end
    bi = (bi and bi > 0 and bi <= NGREATER) and bi or 0
    SetAssignRaw(name, ci, bi)
    Queue("A" .. name .. ci, strformat("ASSIGN %s %d %d", name, ci, bi))
    Changed()
    return true
end

-- One blessing for every class (Pally Power's Shift-click).
function Blessings:SetRow(name, bi)
    if not self:CanEdit(name) then return false end
    bi = (bi and bi > 0 and bi <= NGREATER) and bi or 0
    for ci = 1, NCLASS do
        SetAssignRaw(name, ci, bi)
        pending["A" .. name .. ci] = nil
    end
    Queue("M" .. name, strformat("MASSIGN %s %d", name, bi))
    Changed()
    return true
end

function Blessings:SetSingle(name, ci, target, bi)
    if not self:CanEdit(name) or not D.CLASSES[ci] or type(target) ~= "string" then return false end
    bi = (bi and bi > 0 and bi <= NBLESS) and bi or 0
    if bi == 7 and target == name then return false end     -- no Sacrifice on yourself
    SetSingleRaw(name, ci, target, bi)
    Queue("N" .. name .. ci .. target, strformat("NASSIGN %s %d %s %d", name, ci, target, bi))
    Changed()
    return true
end

function Blessings:SetAura(name, ai)
    if not self:CanEdit(name) then return false end
    ai = (ai and ai > 0 and ai <= NAURA) and ai or 0
    SetAuraRaw(name, ai)
    Queue("U" .. name, strformat("AASSIGN %s %d", name, ai))
    Changed()
    return true
end

-- Applies a whole plan { assign = {[name]={[ci]=bi}}, single = {[name]={[ci]={[target]=bi}}}, aura = {[name]=ai} }
-- to the paladins I may change: their rows (PASSIGN), singles (NASSIGN, old ones cleared) and auras (AASSIGN).
function Blessings:Apply(plan)
    local s = DB()
    for _, p in ipairs(self:Paladins()) do
        local name = p.name
        if self:CanEdit(name) then
            local row = plan.assign and plan.assign[name]
            if row then
                local chars = {}
                for ci = 1, NCLASS do
                    local bi = row[ci]
                    SetAssignRaw(name, ci, bi)
                    chars[ci] = (bi and bi > 0) and tostring(bi) or "n"
                end
                Queue("P" .. name, "PASSIGN " .. name .. "@" .. tconcat(chars))
            end
            if plan.single then
                local want = plan.single[name] or {}
                -- clear singles the plan drops, then set the plan's
                for ci, targets in pairs(s.single[name] or {}) do
                    for target in pairs(targets) do
                        if not (want[ci] and want[ci][target]) then
                            SetSingleRaw(name, ci, target, 0)
                            Queue("N" .. name .. ci .. target, strformat("NASSIGN %s %d %s 0", name, ci, target))
                        end
                    end
                end
                for ci, targets in pairs(want) do
                    for target, bi in pairs(targets) do
                        SetSingleRaw(name, ci, target, bi)
                        Queue("N" .. name .. ci .. target, strformat("NASSIGN %s %d %s %d", name, ci, target, bi))
                    end
                end
            end
            if plan.aura and plan.aura[name] ~= nil then
                SetAuraRaw(name, plan.aura[name])
                Queue("U" .. name, strformat("AASSIGN %s %d", name, plan.aura[name] or 0))
            end
        end
    end
    Changed()
end

-- Clears every assignment I may change (a leader also tells Pally Power: CLEAR).
function Blessings:ClearAll()
    local plan = { assign = {}, single = {}, aura = {} }
    for _, p in ipairs(self:Paladins()) do
        if self:CanEdit(p.name) then
            plan.assign[p.name] = {}
            plan.single[p.name] = {}
            plan.aura[p.name] = 0
        end
    end
    self:Apply(plan)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Auto-assign
-- ---------------------------------------------------------------------------------------------------------------
-- What each class wants, best first (blessing indexes). Hybrids keep Salvation ahead of Might: their healers want it.
local WANT = {
    WARRIOR = { 3, 2, 4, 5, 6 }, ROGUE = { 3, 2, 4, 5, 6 }, HUNTER = { 3, 2, 4, 1, 5 },
    DRUID = { 3, 1, 4, 2, 5 }, SHAMAN = { 3, 1, 4, 2, 5 }, PALADIN = { 3, 1, 4, 2, 5 },
    PRIEST = { 3, 1, 4, 5, 6 }, MAGE = { 3, 1, 4, 5, 6 }, WARLOCK = { 3, 1, 4, 5, 6 },
}
Blessings.WANT = WANT
-- A tank's single blessing instead of Salvation, best first
local TANK_SWAP = { 6, 5, 2, 1, 3 }

-- rank + talent (Pally Power's score); a half point more for the spec it suits when that is all that differs
local function Score(p, bi)
    local b = p.bless[bi]
    if not b then return nil end
    local s = (b[1] or 0) + (b[2] or 0)
    if bi == 2 or bi == 1 then
        local spec = Blessings:SpecOf(p.name)
        if (bi == 2 and spec == "Retribution") or (bi == 1 and spec == "Holy") then s = s + 0.5 end
    end
    return s
end

-- A plan for the paladins I may change (the others keep theirs and count as given). Returns the plan Apply takes.
function Blessings:AutoPlan(roster)
    roster = roster or self:Roster()
    local pals, fixed = {}, {}
    for ci = 1, NCLASS do fixed[ci] = {} end
    for _, p in ipairs(self:Paladins()) do
        if self:CanEdit(p.name) then
            pals[#pals + 1] = p
        else
            for ci = 1, NCLASS do
                local bi = self:GetAssign(p.name, ci)
                if bi then fixed[ci][bi] = true end
            end
        end
    end
    local plan = { assign = {}, single = {}, aura = {} }
    if #pals == 0 then return plan end

    -- 1. a main blessing per paladin: Kings, then the best Might, the best Wisdom, Salvation, Light, Sanctuary
    local main, taken = {}, {}
    local order = { 3, 2, 1, 4, 5, 6 }
    for _, bi in ipairs(order) do
        local best, bestScore
        for _, p in ipairs(pals) do
            if not main[p.name] and p.bless[bi] then
                local s = Score(p, bi)
                if bi == 3 or bi == 4 or bi == 5 then
                    -- the paladin who loses least by giving it: low Might / Wisdom talents
                    s = -((Score(p, 2) or 0) + (Score(p, 1) or 0))
                    if bi == 3 and p.bless[6] then s = s + 100 end      -- Protection (Kings and Sanctuary) gives Kings
                end
                if not bestScore or s > bestScore or (s == bestScore and p.name < best.name) then
                    best, bestScore = p, s
                end
            end
        end
        if best and not taken[bi] then
            main[best.name] = bi
            taken[bi] = true
        end
    end

    -- 2. per class: each paladin gives their main blessing when the class wants it, else the class's next want
    for ci, cls in ipairs(D.CLASSES) do
        local want = WANT[cls]
        local given = {}
        for bi in pairs(fixed[ci]) do given[bi] = true end
        local rows = {}
        local function wants(bi)
            for _, w in ipairs(want) do if w == bi then return true end end
            return false
        end
        for _, p in ipairs(pals) do
            local bi = main[p.name]
            if bi and wants(bi) and not given[bi] then
                rows[p.name] = bi
                given[bi] = true
            end
        end
        for _, p in ipairs(pals) do
            if not rows[p.name] then
                for _, bi in ipairs(want) do
                    if not given[bi] and p.bless[bi] then
                        rows[p.name] = bi
                        given[bi] = true
                        break
                    end
                end
            end
        end
        for _, p in ipairs(pals) do
            plan.assign[p.name] = plan.assign[p.name] or {}
            plan.assign[p.name][ci] = rows[p.name]
        end
    end

    -- 3. tanks: no Salvation; the paladin giving it gives them something else
    for _, m in ipairs(roster) do
        if m.tank and not m.pet then
            for _, p in ipairs(pals) do
                if plan.assign[p.name][m.ci] == 4 then
                    -- the first that nobody gives this class yet, else the first this paladin has (Wisdom only for
                    -- a paladin tank)
                    local swap, fallback
                    for _, bi in ipairs(TANK_SWAP) do
                        if p.bless[bi] and (bi ~= 1 or m.class == "PALADIN") then
                            local dup = false
                            for _, q in ipairs(pals) do
                                if q ~= p and plan.assign[q.name][m.ci] == bi then dup = true end
                            end
                            if not dup then swap = bi break end
                            fallback = fallback or bi
                        end
                    end
                    swap = swap or fallback
                    if swap then
                        plan.single[p.name] = plan.single[p.name] or {}
                        plan.single[p.name][m.ci] = plan.single[p.name][m.ci] or {}
                        plan.single[p.name][m.ci][m.name] = swap
                    end
                end
            end
        end
    end
    for _, p in ipairs(pals) do plan.single[p.name] = plan.single[p.name] or {} end

    -- 4. auras: one of each per party, Sanctity for those with the talent, Devotion for Protection, Concentration
    -- for Holy, then Retribution and the resistances
    local bySub = {}
    local subOf = {}
    for _, m in ipairs(roster) do
        if not m.pet then subOf[m.name] = m.subgroup end
    end
    local AURA_ORDER = { 7, 1, 3, 2, 6, 4, 5, 8 }
    local function pref(p)
        local spec = self:SpecOf(p.name)
        if p.aura[7] and spec == "Retribution" then return 7 end
        if spec == "Protection" and p.aura[1] then return 1 end
        if spec == "Holy" and p.aura[3] then return 3 end
        return nil
    end
    for _, p in ipairs(pals) do
        local sub = subOf[p.name] or 1
        bySub[sub] = bySub[sub] or {}
        local used = bySub[sub]
        local ai = pref(p)
        if ai and used[ai] then ai = nil end
        if not ai then
            for _, a in ipairs(AURA_ORDER) do
                if p.aura[a] and not used[a] then ai = a break end
            end
        end
        if ai then used[ai] = true end
        plan.aura[p.name] = ai or 0
    end
    return plan
end

function Blessings:AutoAssign()
    if not self:CanEditAny() then return false end
    self:Apply(self:AutoPlan())
    return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Who has what (live)
-- ---------------------------------------------------------------------------------------------------------------
-- Seconds left of blessing bi on unit (normal or Greater, any caster), nil when it has none; isGreater.
function Blessings:BuffLeft(unit, bi)
    if self:IsDemo() and demo then return demo.buff(unit, bi) end
    if not UnitAura then return nil end
    for i = 1, 40 do
        local name, _, _, _, _, expires, _, _, _, spellId = UnitAura(unit, i, "HELPFUL")
        if not name then break end
        if spellId and BLESS_BY_ID[spellId] == bi then
            local left = (expires and expires > 0) and (expires - GetTime()) or D.GDURATION
            return left, GREATER_ID[spellId] or false
        end
    end
    return nil
end

-- What a paladin's assignment for class ci looks like now: { total, have, missing = { member }, left (lowest
-- seconds), single = n players on exceptions }. Each member is checked for the blessing that paladin owes them
-- (their single blessing, else the class's Greater).
function Blessings:ClassState(name, ci, byClass)
    byClass = byClass or self:ByClass()
    local st = { total = 0, have = 0, missing = {}, left = nil, single = 0 }
    local greater = self:GetAssign(name, ci)
    for _, m in ipairs(byClass[ci] or {}) do
        local bi = self:GetSingle(name, ci, m.name)
        if bi then st.single = st.single + 1 end
        bi = bi or greater
        if bi then
            st.total = st.total + 1
            local left = (m.online and not m.dead) and self:BuffLeft(m.unit, bi) or nil
            if left or not m.online or m.dead then
                st.have = st.have + 1
                if left and (not st.left or left < st.left) then st.left = left end
            else
                st.missing[#st.missing + 1] = m
            end
        end
    end
    return st
end

-- ---------------------------------------------------------------------------------------------------------------
-- Report and presets
-- ---------------------------------------------------------------------------------------------------------------
local function ClassName(cls)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls]) or cls
end

-- The plan as chat lines: one per paladin ("Caelith: Kings to everyone · Devotion Aura"), then the exceptions.
function Blessings:ReportLines()
    local lines = { "Blessings:" }
    for _, p in ipairs(self:Paladins()) do
        local byBless, order = {}, {}
        for _, cls in ipairs(D.DISPLAY) do
            local ci = CLASS_INDEX[cls]
            local bi = self:GetAssign(p.name, ci)
            if bi then
                if not byBless[bi] then byBless[bi] = {}; order[#order + 1] = bi end
                tinsert(byBless[bi], ClassName(cls))
            end
        end
        local parts = {}
        for _, bi in ipairs(order) do
            local who = #byBless[bi] == NCLASS and "everyone" or tconcat(byBless[bi], ", ")
            parts[#parts + 1] = D.BLESSINGS[bi].short .. " to " .. who
        end
        local ai = self:GetAura(p.name)
        if ai then parts[#parts + 1] = self:AuraName(ai) end
        lines[#lines + 1] = strformat("%s: %s", p.name, #parts > 0 and tconcat(parts, " · ") or "nothing")
    end
    local ex = self:Exceptions()
    if #ex > 0 then
        local parts = {}
        for _, e in ipairs(ex) do
            parts[#parts + 1] = strformat("%s %s (%s)", e.target, D.BLESSINGS[e.bi].short, e.pal)
        end
        lines[#lines + 1] = "Instead: " .. tconcat(parts, ", ")
    end
    return lines
end

function Blessings:Report()
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

function Blessings:Presets()
    local out = {}
    for name in pairs(DB().presets) do out[#out + 1] = name end
    tsort(out)
    return out
end

-- Saves the current plan (every known paladin) under name.
function Blessings:SavePreset(name)
    if type(name) ~= "string" or name == "" then return false end
    local s = DB()
    local p = { assign = {}, single = {}, aura = {}, at = time() }
    for pal in pairs(self.pals) do
        p.assign[pal] = {}
        for ci = 1, NCLASS do p.assign[pal][ci] = self:GetAssign(pal, ci) end
        p.single[pal] = {}
        for ci, targets in pairs(self:GetSingles(pal)) do
            p.single[pal][ci] = {}
            for t, bi in pairs(targets) do p.single[pal][ci][t] = bi end
        end
        p.aura[pal] = self:GetAura(pal) or 0
    end
    s.presets[name] = p
    Changed()
    return true
end

function Blessings:LoadPreset(name)
    local p = DB().presets[name]
    if not p then return false end
    self:Apply(p)
    return true
end

function Blessings:DeletePreset(name)
    DB().presets[name] = nil
    Changed()
end

-- A good preset name: the raid instance I am in, else "Raid".
function Blessings:PresetSuggestion()
    local name, kind = GetInstanceInfo()
    if kind == "raid" and type(name) == "string" and name ~= "" then return name end
    return IsInRaid() and "Raid" or "Party"
end

-- ---------------------------------------------------------------------------------------------------------------
-- Wire (Pally Power's protocol)
-- ---------------------------------------------------------------------------------------------------------------
function Blessings:Channel()
    if InInstanceGroup() then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

function Blessings:SendRaw(msg, target)
    if self:IsDemo() then return false end
    local chan = target and "WHISPER" or self:Channel()
    if not chan then return false end
    if #msg > 255 then msg = strsub(msg, 1, 255) end
    local CTL = _G.ChatThrottleLib     -- (comes with AceComm-3.0)
    if CTL and CTL.SendAddonMessage then
        CTL:SendAddonMessage("NORMAL", PREFIX, msg, chan, target)
    elseif C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, msg, chan, target)
    else
        return false
    end
    return true
end

-- "SELF <6 x rank+talent hex>@<9 class chars>"
function Blessings:EncodeSelf()
    local me = self:Me()
    local p = me and self.pals[me]
    if not p then return "" end
    local nums = {}
    for bi = 1, NGREATER do
        local b = p.bless[bi]
        nums[bi] = b and strformat("%x%x", min(b[1], 15), min(b[2] or 0, 15)) or "nn"
    end
    local cls = {}
    for ci = 1, NCLASS do
        local bi = self:GetAssign(me, ci)
        cls[ci] = bi and tostring(bi) or "n"
    end
    return "SELF " .. tconcat(nums) .. "@" .. tconcat(cls)
end

function Blessings:EncodeAuraSelf()
    local me = self:Me()
    local p = me and self.pals[me]
    if not p then return "" end
    local nums = {}
    for ai = 1, NAURA do
        local a = p.aura[ai]
        nums[ai] = a and strformat("%x%x", min(a[1], 15), min(a[2] or 0, 15)) or "nn"
    end
    return "ASELF " .. tconcat(nums) .. "@" .. tostring(self:GetAura(me) or 0)
end

-- Tells the group (or one player) who I am: PPLEADER (when I lead), SELF, ASELF, my singles, my Free/Symbols line.
function Blessings:SendSelf(target)
    if not IsInGroup() then return end
    local me = self:Me()
    if not me then return end
    if self:AmLeader() then self:SendRaw("PPLEADER " .. me) end
    if not self:IsPaladin() then return end
    self:ScanSelf()
    self:SendRaw(self:EncodeSelf(), target)
    self:SendRaw(self:EncodeAuraSelf(), target)
    local entries = {}
    for ci, targets in pairs(self:GetSingles(me)) do
        for t, bi in pairs(targets) do
            if bi and bi > 0 then entries[#entries + 1] = strformat("%s %d %s %d", me, ci, t, bi) end
        end
    end
    tsort(entries)
    for i = 1, #entries, NASSIGN_PER_MSG do
        local chunk = {}
        for j = i, min(i + NASSIGN_PER_MSG - 1, #entries) do chunk[#chunk + 1] = entries[j] end
        self:SendRaw("NASSIGN " .. tconcat(chunk, "@"), target)
    end
    local p = self.pals[me]
    self:SendRaw(strformat("FREEASSIGN %s | SYMCOUNT %d | COOLDOWNS:n:n:n:n", p.free and "YES" or "NO",
        p.symbols or 0), target)
end

-- Sends SELF to the group once, 1-3 s from now (later calls in the meantime ride along).
local selfQueued = false
function Blessings:QueueSelf()
    if selfQueued then return end
    selfQueued = true
    local function go()
        selfQueued = false
        Blessings:SendSelf()
    end
    if C_Timer and C_Timer.After then C_Timer.After(1 + math.random() * 2, go) else go() end
end

-- Accepts an edit of paladin name from sender: their own, a leader's, or for a paladin who lets anyone assign.
local function MayEdit(sender, name)
    if not name or name == "" then return false end
    if name == sender then return true end
    if Blessings:IsLeader(sender) then return true end
    local p = Blessings.pals[name]
    return p and p.free or false
end
Blessings.MayEdit = MayEdit

local HANDLERS = {}

-- REQ: answered in OnMessage (a whisper back to whoever asked, unless they lead or this is a battleground)
HANDLERS.REQ = function() end

HANDLERS.PPLEADER = function(sender, msg)
    local name = strmatch(msg, "^PPLEADER (.+)$")
    if name and Blessings:IsLeader(Wire(name)) then Blessings.ppLeader = true end
end

HANDLERS.SELF = function(sender, msg)
    local nums, cls = strmatch(msg, "^SELF ([0-9a-fn]*)@([0-9n]*)")
    if not nums then return end
    local p = NewPal(sender)
    local old = Blessings.pals[sender]
    if old then p.aura, p.symbols, p.free, p.cd = old.aura, old.symbols, old.free, old.cd end
    Blessings.pals[sender] = p
    for bi = 1, NGREATER do
        local r, t = strsub(nums, bi * 2 - 1, bi * 2 - 1), strsub(nums, bi * 2, bi * 2)
        if r ~= "" and r ~= "n" then
            p.bless[bi] = { tonumber(r, 16) or 1, tonumber(t) or tonumber(t, 16) or 0 }
        end
    end
    local s = DB()
    s.assign[sender] = {}
    for ci = 1, NCLASS do
        local c = strsub(cls, ci, ci)
        local bi = tonumber(c)
        s.assign[sender][ci] = (bi and bi > 0) and bi or nil
    end
    Changed()
end

HANDLERS.ASELF = function(sender, msg)
    local p = Blessings.pals[sender]
    if not p then return end
    local nums, ai = strmatch(msg, "^ASELF ([0-9a-fn]*)@([0-9n]*)")
    if not nums then return end
    p.aura = {}
    for i = 1, min(NAURA, floor(#nums / 2)) do
        local r, t = strsub(nums, i * 2 - 1, i * 2 - 1), strsub(nums, i * 2, i * 2)
        if r ~= "n" then p.aura[i] = { tonumber(r, 16) or 1, tonumber(t) or 0 } end
    end
    SetAuraRaw(sender, tonumber(ai) or 0)
    Changed()
end

HANDLERS.ASSIGN = function(sender, msg)
    local name, ci, bi = strmatch(msg, "^ASSIGN (.*) (.*) (.*)")
    ci, bi = tonumber(ci), tonumber(bi)
    if not (ci and bi and D.CLASSES[ci]) or not MayEdit(sender, name) then return end
    SetAssignRaw(name, ci, bi)
    Changed()
end

HANDLERS.MASSIGN = function(sender, msg)
    local name, bi = strmatch(msg, "^MASSIGN (.*) (.*)")
    bi = tonumber(bi)
    if not bi or not MayEdit(sender, name) then return end
    for ci = 1, NCLASS do SetAssignRaw(name, ci, bi) end
    Changed()
end

HANDLERS.PASSIGN = function(sender, msg)
    local name, cls = strmatch(msg, "^PASSIGN (.*)@([0-9n]*)")
    if not name or not MayEdit(sender, name) then return end
    for ci = 1, NCLASS do SetAssignRaw(name, ci, tonumber(strsub(cls, ci, ci)) or 0) end
    Changed()
end

HANDLERS.NASSIGN = function(sender, msg)
    for name, ci, target, bi in gmatch(strsub(msg, 9), "([^@]*) ([^@]*) ([^@]*) ([^@]*)") do
        if not MayEdit(sender, name) then return end      -- (Pally Power stops at the first refused entry too)
        ci, bi = tonumber(ci), tonumber(bi)
        if ci and bi and D.CLASSES[ci] then SetSingleRaw(name, ci, target, bi) end
    end
    Changed()
end

HANDLERS.AASSIGN = function(sender, msg)
    local name, ai = strmatch(msg, "^AASSIGN (.*) (.*)")
    ai = tonumber(ai)
    if not ai or not MayEdit(sender, name) then return end
    SetAuraRaw(name, ai)
    Changed()
end

HANDLERS.CLEAR = function(sender, msg)
    local skip = strfind(msg, "SKIP") ~= nil
    local function clear(name)
        DB().assign[name] = {}
        DB().single[name] = nil
        if not skip then SetAuraRaw(name, 0) end
    end
    if Blessings:IsLeader(sender) then
        for name in pairs(Blessings.pals) do clear(name) end
    else
        clear(sender)
    end
    Changed()
end

-- "FREEASSIGN YES | SYMCOUNT 12 | COOLDOWNS:..." (each part may come alone)
local function StatusLine(sender, msg)
    local p = Blessings.pals[sender]
    if not p then return end
    if strfind(msg, "FREEASSIGN YES") then p.free = true elseif strfind(msg, "FREEASSIGN NO") then p.free = false end
    local sym = strmatch(msg, "SYMCOUNT ([0-9]+)")
    if sym then p.symbols = tonumber(sym) end
    Changed()
end
HANDLERS.FREEASSIGN = StatusLine
HANDLERS.SYMCOUNT = StatusLine

function Blessings:OnMessage(text, channel, senderFull)
    if type(text) ~= "string" or type(senderFull) ~= "string" then return end
    if channel ~= "RAID" and channel ~= "PARTY" and channel ~= "INSTANCE_CHAT" and channel ~= "WHISPER" then return end
    local key = Util.NormalizeName(senderFull)
    if not key or Util.IsMe(key) then return end
    if not Util.IsInMyGroup(key) then return end        -- only group members (whispers too)
    local sender = Util.ShortName(key)
    local kind = strmatch(text, "^(%u+)")
    local fn = kind and HANDLERS[kind]
    if kind == "REQ" then
        -- (Pally Power whispers every asker; one broadcast a moment later answers everyone who asked meanwhile,
        -- Pally Power users included, without a whisper per paladin per asker)
        if Blessings:IsPaladin() or Blessings:AmLeader() then Blessings:QueueSelf() end
    elseif fn then
        fn(sender, text)
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Demo mode: a made-up 25-man Black Temple raid (the mockup's): four paladins with me as Gina's stand-in and the
-- leader, tanks on Light instead of Salvation, a hunter missing Might, two mages missing Salvation, the priests'
-- Wisdom running out, two paladins on Devotion in one party
-- ---------------------------------------------------------------------------------------------------------------
local DEMO_CLASSES = {
    { "WARRIOR", { "Victhar", "Brakka", "Kordan", "Ulfric" } }, { "ROGUE", { "Shadowmelder", "Vexis" } },
    { "HUNTER", { "Faelar", "Tarrow" } }, { "DRUID", { "Moonwhisper", "Rhosyn", "Quillon" } },
    { "SHAMAN", { "Stormfist", "Thunderhoofx" } }, { "PALADIN", { "Caelith", "Lightbringer", "Sunniva", "@me" } },
    { "PRIEST", { "Isolde", "Nyxa", "Seraphel" } }, { "MAGE", { "Embera", "Frostweaver", "Kaelwyn" } },
    { "WARLOCK", { "Grumpykat", "Morrigan" } },
}

local function BuildDemo()
    local me = Blessings:Me() or "You"
    local d = { pals = {}, roster = {}, byUnit = {}, specs = {}, started = GetTime(),
        store = { assign = {}, single = {}, aura = {}, presets = {} } }
    local i = 0
    for _, e in ipairs(DEMO_CLASSES) do
        for _, n in ipairs(e[2]) do
            local orig = n
            n = (n == "@me") and me or (n == me and "Thorgrim") or n   -- (my own name is taken by my paladin)
            i = i + 1
            local m = { unit = "dzdemo" .. i, name = n, class = e[1], ci = CLASS_INDEX[e[1]],
                subgroup = floor((i - 1) / 5) + 1, level = 70, online = true, dead = false, demo = true,
                tank = (orig == "Victhar" or orig == "Caelith" or orig == "Moonwhisper") or nil }
            if n == "Caelith" or n == "Lightbringer" then m.subgroup = 1 end
            d.roster[#d.roster + 1] = m
            d.byUnit[m.unit] = m
        end
    end
    -- who has what: everyone 25 min left, but for the gaps above (the priests' Wisdom ticks down with the clock)
    d.buff = function(unit, bi)
        local m = d.byUnit[unit]
        if not m then return nil end
        if m.name == "Tarrow" and bi == 2 then return nil end
        if (m.name == "Embera" or m.name == "Kaelwyn") and bi == 4 then return nil end
        if m.class == "PRIEST" and bi == 1 then return max(5, 185 - (GetTime() - d.started)) end
        return 1500 - ((GetTime() - d.started) % 600)
    end
    local function pal(name, spec, bless, aura, sym)
        d.pals[name] = { name = name, bless = bless, aura = aura, symbols = sym, free = false, cd = {}, seen = GetTime(),
            me = name == me or nil }
        d.specs[name] = spec
    end
    pal("Caelith", "Protection", { { 7, 0 }, { 8, 0 }, { 1, 0 }, { 1, 0 }, { 4, 0 }, { 5, 1 } },
        { { 8, 5 }, { 6, 0 }, { 1, 0 }, { 4, 0 }, { 4, 0 }, { 4, 0 } }, 142)
    pal("Sunniva", "Retribution", { { 7, 0 }, { 8, 5 }, nil, { 1, 0 }, { 4, 0 } },
        { { 8, 0 }, { 6, 0 }, { 1, 0 }, [7] = { 1, 0 } }, 88)
    pal(me, "Holy", { { 7, 2 }, { 8, 0 }, nil, { 1, 0 }, { 4, 0 } }, { { 8, 0 }, { 6, 0 }, { 1, 3 } }, 196)
    pal("Lightbringer", "Holy", { { 7, 1 }, { 8, 0 }, nil, { 1, 0 }, { 4, 0 } }, { { 8, 0 }, { 6, 0 }, { 1, 0 } }, 12)
    local s = d.store
    local function row(name, list)
        s.assign[name] = {}
        for j, cls in ipairs(D.DISPLAY) do s.assign[name][CLASS_INDEX[cls]] = list[j] end
    end
    row("Caelith", { 3, 3, 3, 3, 3, 3, 3, 3, 3 })
    row("Sunniva", { 2, 2, 2, 2, 2, 2, 5, 5, 5 })
    row(me, { 5, 5, 1, 1, 1, 1, 1, 1, 1 })
    row("Lightbringer", { 4, 4, 4, 4, 4, 4, 4, 4, 4 })
    local function demoName(n) return n == me and "Thorgrim" or n end
    s.single.Lightbringer = { [1] = { [demoName("Victhar")] = 5 }, [5] = { Caelith = 5 }, [4] = { [demoName("Moonwhisper")] = 5 } }
    s.aura = { Caelith = 1, Sunniva = 7, [me] = 3, Lightbringer = 1 }
    return d
end

local realPals
function Blessings:OnDemoToggled(on)
    if on then
        demo = BuildDemo()
        realPals = realPals or self.pals
        self.pals = demo.pals
    else
        if realPals then self.pals = realPals end
        realPals, demo = nil, nil
    end
    Changed()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Group changes
-- ---------------------------------------------------------------------------------------------------------------
-- Drops paladins who left; keeps me.
function Blessings:PruneRoster()
    local here = {}
    for _, m in ipairs(self:Roster()) do
        if not m.pet then here[m.name] = true end
    end
    local me = self:Me()
    local changed = false
    for name in pairs(self.pals) do
        if name ~= me and not here[name] then
            self.pals[name] = nil
            changed = true
        end
    end
    if changed then Changed() end
end

-- Says hello on joining a group: who I am, and (paladins, leaders, or with the planner open) asks the others. Every
-- paladin answers a REQ with a whisper, so the rest of the raid does not ask until it looks.
local function Hello(force)
    if Blessings:IsDemo() or not IsInGroup() then return end
    Blessings:SendSelf()
    local planner = ns.BlessingsUI and ns.BlessingsUI:IsShown()
    if force or planner or Blessings:IsPaladin() or Util.IsPlayerLeaderOrAssist() then Blessings:SendRaw("REQ") end
end
Blessings.Hello = Hello

function Blessings:OnGroupLeft()
    local me = self:Me()
    local s = DB()
    for name in pairs(self.pals) do
        if name ~= me then self.pals[name] = nil end
    end
    -- (as Pally Power: singles go; rows of paladins who are not me or in my guild go)
    wipe(s.single)
    for name in pairs(s.assign) do
        local key = Util.NormalizeName(name)
        local guildie = key and ns.Guild and ns.Guild.IsInGuild and ns.Guild:IsInGuild(key)
        if name ~= me and not guildie then s.assign[name] = nil; s.aura[name] = nil end
    end
    self.ppLeader = false
    Changed()
end

function Blessings:OnLogin()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end
    ns:RegisterEvent("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender)
        if prefix == PREFIX then Blessings:OnMessage(text, channel, sender) end
    end)
    if self:IsPaladin() then self:ScanSelf() end
    ns:On("DEMO_TOGGLED", function(on) Blessings:OnDemoToggled(on) end)
    if self:IsDemo() then self:OnDemoToggled(true) end
    local wasInGroup = IsInGroup()
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        local now = IsInGroup()
        if now and not wasInGroup then
            if C_Timer then C_Timer.After(2 + math.random() * 2, Hello) else Hello() end
        elseif not now and wasInGroup then
            Blessings:OnGroupLeft()
        end
        wasInGroup = now
        if now then Util.Debounce("dz-bless-prune", 0.5, function() Blessings:PruneRoster() end) end
        Changed()
    end)
    ns:RegisterEvent("SPELLS_CHANGED", function()
        if not Blessings:IsPaladin() then return end
        Util.Debounce("dz-bless-spells", 1, function()
            if Blessings:ScanSelf() then Blessings:SendSelf() end
            Changed()
        end)
    end)
    ns:RegisterEvent("BAG_UPDATE", function()
        if not Blessings:IsPaladin() then return end
        Util.Debounce("dz-bless-bags", 2, function()
            local me = Blessings:Me()
            local p = me and Blessings.pals[me]
            if not p then return end
            local n = GetItemCount and GetItemCount(D.SYMBOL_OF_KINGS) or 0
            if n ~= p.symbols then
                p.symbols = n
                Changed()
            end
        end)
    end)
    ns:RegisterEvent("UNIT_AURA", function()
        Util.Debounce("dz-bless-aura", 0.5, Changed)
    end)
    ns:On("SETTINGS_CHANGED", function(path)
        if path == "bless.free" and Blessings:IsPaladin() then
            Blessings:ScanSelf()
            local p = Blessings.pals[Blessings:Me()]
            if p then Blessings:SendRaw("FREEASSIGN " .. (p.free and "YES" or "NO")) end
            Changed()
        elseif type(path) == "string" and path:find("^bless") then
            Changed()
        end
    end)
    if IsInGroup() then
        -- (after a login or /reload in a group: after ChatThrottleLib's quiet first seconds, spread out)
        if C_Timer then C_Timer.After(6 + math.random() * 6, Hello) else Hello() end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The class tool and /dz bless
-- ---------------------------------------------------------------------------------------------------------------
ns.ClassKit:Register({ key = "bless", label = "Blessings", class = "PALADIN", order = 10, icon = 25898 })

ns:RegisterSlash("bless", function(rest)
    rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "report" then
        if not Blessings:Report() then ns:Print("Not in a group.") end
    elseif rest == "auto" then
        if not Blessings:AutoAssign() then ns:Print("You can't assign any paladin here.") end
    elseif rest == "unlock" or rest == "lock" then
        ns.DB:SetSetting("bless.locked", rest == "lock")
    elseif ns.BlessingsUI then
        ns.BlessingsUI:Toggle()
    end
end, "Paladin blessings planner (report | auto | unlock | lock)")

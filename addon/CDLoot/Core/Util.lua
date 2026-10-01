if CDLootBoot and CDLootBoot.Run("Core/Util.lua", ...) then return end -- CDLoot: shared helpers (ns.Util).
-- Name keys, timers / debounce, table helpers, canonical encoding + hash, formatting,
-- group (raid / party) tracking which fires GROUP_UPDATED, and the effective dungeon-mode checks
-- (Util.IsDungeonModeActive / Util.GetGroupChannel, Addendum B §22.1, group rules: Addendum D §26).
local addonName, ns = ...

local Util = {}
ns.Util = Util

local type, pairs, ipairs, tostring, tonumber, select = type, pairs, ipairs, tostring, tonumber, select
local floor, abs, random = math.floor, math.abs, math.random
local strformat, strlower, strmatch, strgsub, strsub = string.format, string.lower, string.match, string.gsub, string.sub
local tsort, tconcat = table.sort, table.concat

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------

local cachedRealm

function Util.GetPlayerRealm()
    if cachedRealm then return cachedRealm end
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if type(realm) ~= "string" or realm == "" then
        realm = strgsub((GetRealmName and GetRealmName()) or "", "[%s%-]", "")
    end
    if realm ~= "" then
        cachedRealm = realm
    end
    return realm
end

function Util.Trim(s)
    if type(s) ~= "string" then return s end
    return (strmatch(s, "^%s*(.-)%s*$"))
end

-- "Name" -> "Name-OwnRealm"; "Name-Some Realm" -> "Name-SomeRealm". nil for nil / "".
function Util.NormalizeName(name)
    if type(name) ~= "string" then return nil end
    name = Util.Trim(name)
    if name == "" then return nil end
    local base, realm = strmatch(name, "^([^%-]+)%-(.*)$")
    if base then
        realm = strgsub(realm, "%s", "")
        if realm ~= "" then
            return base .. "-" .. realm
        end
        name = base
    end
    local own = Util.GetPlayerRealm()
    if own == "" then return name end
    return name .. "-" .. own
end

-- Case fold for comparing typed names: ASCII A-Z plus the Latin-1 accented capitals (UTF-8 C3 80-9E -> C3 A0-BE),
-- byte by byte on purpose: string.lower follows the C locale and may rewrite UTF-8 lead bytes ("Élise" and "élise"
-- must fold alike).
local C3 = string.char(195)
local LATIN1_UPPER = C3 .. "([" .. string.char(128) .. "-" .. string.char(158) .. "])"
local function AsciiLower(c) return string.char(c:byte() + 32) end
local function Latin1Lower(c) return C3 .. string.char(c:byte() + 32) end

function Util.FoldCase(s)
    if type(s) ~= "string" then return s end
    s = strgsub(s, "[A-Z]", AsciiLower)
    return (strgsub(s, LATIN1_UPPER, Latin1Lower))
end

-- "élise" -> "Élise", "bob" -> "Bob": first letter upper case (ASCII or Latin-1 UTF-8), the rest folded.
function Util.CapitalizeName(s)
    if type(s) ~= "string" or s == "" then return s end
    s = Util.FoldCase(s)
    local b1, b2 = s:byte(1, 2)
    if b1 == 195 and b2 and b2 >= 160 and b2 <= 190 and b2 ~= 183 then
        return C3 .. string.char(b2 - 32) .. strsub(s, 3)
    end
    if b1 >= 97 and b1 <= 122 then return string.char(b1 - 32) .. strsub(s, 2) end
    return s
end

-- Strips "-<own realm>"; foreign realms are kept.
function Util.ShortName(key)
    if type(key) ~= "string" then return "" end
    local own = Util.GetPlayerRealm()
    if own ~= "" then
        local suffix = "-" .. own
        if #key > #suffix and strsub(key, -#suffix) == suffix then
            return strsub(key, 1, #key - #suffix)
        end
    end
    return key
end

local playerKey

-- Own name key. Reliable only after PLAYER_LOGIN (cached from then on).
function Util.PlayerKey()
    if playerKey then return playerKey end
    local name = (UnitNameUnmodified and UnitNameUnmodified("player")) or (UnitName and UnitName("player"))
    if type(name) ~= "string" or name == "" or name == UNKNOWNOBJECT then
        return nil
    end
    local realm = Util.GetPlayerRealm()
    if realm == "" then return nil end
    local key = name .. "-" .. realm
    if ns.loggedIn then
        playerKey = key
    end
    return key
end

function Util.IsMe(key)
    if type(key) ~= "string" then return false end
    return key == Util.PlayerKey()
end

---------------------------------------------------------------------------
-- Timers
---------------------------------------------------------------------------

local function Protected(fn)
    return function()
        if ns.SafeCall then
            ns.SafeCall(fn)
        else
            fn()
        end
    end
end

local function NewTimer(sec, fn)
    if C_Timer.NewTimer then
        return C_Timer.NewTimer(sec, fn)
    end
    -- Fallback for clients without NewTimer: a cancellable wrapper around After.
    local t = { cancelled = false }
    function t:Cancel() self.cancelled = true end
    C_Timer.After(sec, function()
        if not t.cancelled then fn() end
    end)
    return t
end

function Util.After(sec, fn)
    sec = tonumber(sec) or 0
    if sec < 0 then sec = 0 end
    C_Timer.After(sec, Protected(fn))
end

local debounceTimers = {}   -- [key] = timer

-- (Re)starts the named timer: fn runs once, `sec` seconds after the LAST call.
function Util.Debounce(key, sec, fn)
    sec = tonumber(sec) or 0
    if sec < 0 then sec = 0 end
    local old = debounceTimers[key]
    if old then old:Cancel() end
    local timer
    timer = NewTimer(sec, function()
        if debounceTimers[key] == timer then
            debounceTimers[key] = nil
        end
        if ns.SafeCall then ns.SafeCall(fn) else fn() end
    end)
    debounceTimers[key] = timer
    return timer
end

function Util.CancelDebounce(key)
    local t = debounceTimers[key]
    if t then
        t:Cancel()
        debounceTimers[key] = nil
        return true
    end
    return false
end

-- Extra (not in the spec's list): true while a named debounce timer is waiting.
function Util.IsDebouncePending(key)
    return debounceTimers[key] ~= nil
end

function Util.RandomDelay(minSec, maxSec, fn)
    minSec = tonumber(minSec) or 0
    maxSec = tonumber(maxSec) or minSec
    if maxSec < minSec then minSec, maxSec = maxSec, minSec end
    Util.After(minSec + random() * (maxSec - minSec), fn)
end

---------------------------------------------------------------------------
-- Tables
---------------------------------------------------------------------------

local function CopyTable(t, seen)
    if type(t) ~= "table" then return t end
    if seen[t] then return seen[t] end
    local out = {}
    seen[t] = out
    for k, v in pairs(t) do
        out[CopyTable(k, seen)] = CopyTable(v, seen)
    end
    return out
end

function Util.CopyTable(t)
    return CopyTable(t, {})
end

function Util.Count(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local TYPE_RANK = { number = 1, string = 2, boolean = 3 }

-- Numbers ascending, then strings ascending, then booleans (false first), then anything else.
local function KeyLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then
        return (TYPE_RANK[ta] or 9) < (TYPE_RANK[tb] or 9)
    end
    if ta == "number" or ta == "string" then
        return a < b
    end
    if ta == "boolean" then
        return (not a) and b
    end
    return tostring(a) < tostring(b)
end
Util.KeyLess = KeyLess

function Util.Keys(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k in pairs(t) do out[#out + 1] = k end
    tsort(out, KeyLess)
    return out
end

function Util.Contains(array, value)
    if type(array) ~= "table" then return false end
    for i = 1, #array do
        if array[i] == value then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Canonical encoding + hash
---------------------------------------------------------------------------

local TWO31 = 2147483648

-- Deterministic across clients: %d is only used where a 32-bit C long is safe.
local function EncodeNumber(v)
    if v ~= v then return "nan" end
    if v == math.huge then return "inf" end
    if v == -math.huge then return "-inf" end
    if v == floor(v) then
        if abs(v) < TWO31 then
            return strformat("%d", v)
        end
        return strformat("%.0f", v)
    end
    return strformat("%.6f", v)
end

local function EncodeValue(v, out, stack)
    local tv = type(v)
    if tv == "number" then
        out[#out + 1] = EncodeNumber(v)
    elseif tv == "string" then
        out[#out + 1] = strformat("%q", v)
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "nil" then
        out[#out + 1] = "nil"
    elseif tv == "table" then
        if stack[v] then
            error("Util.Canonical: cyclic table", 0)
        end
        stack[v] = true
        local keys = {}
        for k in pairs(v) do
            local tk = type(k)
            if tk ~= "number" and tk ~= "string" and tk ~= "boolean" then
                error("Util.Canonical: cannot encode a " .. tk .. " key", 0)
            end
            keys[#keys + 1] = k
        end
        tsort(keys, KeyLess)
        out[#out + 1] = "{"
        for i = 1, #keys do
            local k = keys[i]
            if i > 1 then out[#out + 1] = "," end
            EncodeValue(k, out, stack)
            out[#out + 1] = "="
            EncodeValue(v[k], out, stack)
        end
        out[#out + 1] = "}"
        stack[v] = nil
    else
        error("Util.Canonical: cannot encode a " .. tv, 0)
    end
end

function Util.Canonical(v)
    local out = {}
    EncodeValue(v, out, {})
    return tconcat(out)
end

-- 32-bit value -> 8 lowercase hex digits, without relying on the platform's %x width.
function Util.Hex32(n)
    n = floor(tonumber(n) or 0) % 4294967296
    return strformat("%04x%04x", floor(n / 65536), n % 65536)
end

local function Adler32Lua(str)
    local a, b = 1, 0
    for i = 1, #str do
        a = (a + str:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

local libDeflate
function Util.Adler32(str)
    if libDeflate == nil then
        libDeflate = (LibStub and LibStub("LibDeflate", true)) or false
    end
    if libDeflate then
        return libDeflate:Adler32(str)
    end
    return Adler32Lua(str)
end

function Util.Hash(v)
    return Util.Hex32(Util.Adler32(Util.Canonical(v)))
end

---------------------------------------------------------------------------
-- Item links / versions
---------------------------------------------------------------------------

function Util.ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    local id = tonumber(strmatch(link, "item:(%d+)"))
    if id and id > 0 then return id end
    return nil
end

function Util.ItemIDsFromText(text)
    local out = {}
    if type(text) ~= "string" then return out end
    for id in text:gmatch("item:(%d+)") do
        id = tonumber(id)
        if id and id > 0 then out[#out + 1] = id end
    end
    return out
end

-- Numeric dotted compare: "0.10.0" > "0.9.3". Missing / non-numeric parts count as 0.
function Util.CompareVersions(a, b)
    local pa, pb = {}, {}
    for part in tostring(a or ""):gmatch("[^%.]+") do pa[#pa + 1] = tonumber(strmatch(part, "^%d+")) or 0 end
    for part in tostring(b or ""):gmatch("[^%.]+") do pb[#pb + 1] = tonumber(strmatch(part, "^%d+")) or 0 end
    local n = (#pa > #pb) and #pa or #pb
    for i = 1, n do
        local x, y = pa[i] or 0, pb[i] or 0
        if x < y then return -1 end
        if x > y then return 1 end
    end
    return 0
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local function Now()
    return (GetServerTime and GetServerTime()) or time()
end

function Util.FormatAgo(ts)
    ts = tonumber(ts)
    if not ts or ts <= 0 then return "never" end
    local diff = Now() - ts
    if diff < 60 then return "just now" end
    if diff < 3600 then return floor(diff / 60) .. "m ago" end
    if diff < 86400 then return floor(diff / 3600) .. "h ago" end
    return floor(diff / 86400) .. "d ago"
end

local function ToByte(x)
    x = tonumber(x) or 1
    if x < 0 then x = 0 elseif x > 1 then x = 1 end
    return floor(x * 255 + 0.5)
end

-- Util.ColorText(text, r, g, b) or Util.ColorText(text, {r, g, b}).
function Util.ColorText(text, r, g, b)
    if type(r) == "table" then
        r, g, b = r[1] or r.r, r[2] or r.g, r[3] or r.b
    end
    return strformat("|cff%02x%02x%02x%s|r", ToByte(r), ToByte(g), ToByte(b), tostring(text))
end

-- "ffrrggbb" for a class file (white when unknown).
function Util.ClassColorHex(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if not c then return "ffffffff" end
    if type(c.colorStr) == "string" and #c.colorStr == 8 then
        return c.colorStr
    end
    return strformat("ff%02x%02x%02x", ToByte(c.r), ToByte(c.g), ToByte(c.b))
end

---------------------------------------------------------------------------
-- Group tracking
---------------------------------------------------------------------------

Util.group = {}   -- [key] = { classFile=, rank=, subgroup=, online=, isML= }
local groupSignature = ""
local retryPending = false

local function DemoEnabled()
    return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()
end

local function LootMethod()
    if C_PartyInfo and C_PartyInfo.GetLootMethod then
        return C_PartyInfo.GetLootMethod()
    end
    return nil
end

local function MasterLooterMethod()
    return (Enum and Enum.LootMethod and Enum.LootMethod.Masterlooter) or 2
end

local function UnitKey(unit)
    local name, realm = UnitName(unit)
    if type(name) ~= "string" or name == "" or name == UNKNOWNOBJECT then return nil end
    if type(realm) == "string" and realm ~= "" then
        return Util.NormalizeName(name .. "-" .. realm)
    end
    return Util.NormalizeName(name)
end

function Util.RefreshGroup()
    local newGroup = {}
    local incomplete = false

    if IsInRaid() then
        for i = 1, (GetNumGroupMembers() or 0) do
            local name, rank, subgroup, _, _, fileName, _, online, _, _, isML = GetRaidRosterInfo(i)
            local key = (name ~= UNKNOWNOBJECT) and Util.NormalizeName(name) or nil
            if key then
                newGroup[key] = {
                    classFile = fileName,
                    rank = tonumber(rank) or 0,
                    subgroup = tonumber(subgroup) or 1,
                    online = online and true or false,
                    isML = isML and true or false,
                }
            else
                incomplete = true
            end
        end
    elseif IsInGroup() then
        local method, mlPartyID = LootMethod()
        local isMLMethod = method == MasterLooterMethod()
        local units = { "player", "party1", "party2", "party3", "party4" }
        for idx, unit in ipairs(units) do
            if UnitExists(unit) then
                local key = UnitKey(unit)
                if key then
                    local _, classFile = UnitClass(unit)
                    newGroup[key] = {
                        classFile = classFile,
                        rank = UnitIsGroupLeader(unit) and 2 or ((UnitIsGroupAssistant and UnitIsGroupAssistant(unit)) and 1 or 0),
                        subgroup = 1,
                        online = UnitIsConnected(unit) and true or false,
                        isML = (isMLMethod and mlPartyID == idx - 1) and true or false,
                    }
                else
                    incomplete = true
                end
            end
        end
    end

    local keys = Util.Keys(newGroup)
    local signature = tconcat(keys, ",")
    Util.group = newGroup
    if signature ~= groupSignature then
        groupSignature = signature
        ns:Fire("GROUP_UPDATED")
    end

    -- Names can be "Unknown" while the roster is still loading; look again shortly.
    if incomplete and not retryPending then
        retryPending = true
        Util.After(2, function()
            retryPending = false
            Util.RefreshGroup()
        end)
    end
end

function Util.IsInMyGroup(key)
    if type(key) ~= "string" then return false end
    if DemoEnabled() then
        return ns.Demo:IsInDemoRaid(key) and true or false
    end
    return Util.group[key] ~= nil
end

function Util.GetGroupKeys()
    if DemoEnabled() and ns.Demo.GetRaidKeys then
        return ns.Demo:GetRaidKeys()
    end
    return Util.Keys(Util.group)
end

function Util.IsPlayerMasterLooter()
    local method, partyID, raidID = LootMethod()
    if method == nil or method ~= MasterLooterMethod() then return false end
    if raidID then
        return UnitIsUnit("raid" .. raidID, "player") and true or false
    end
    return partyID == 0
end

function Util.IsPlayerLeaderOrAssist()
    return (UnitIsGroupLeader("player") or (UnitIsGroupAssistant and UnitIsGroupAssistant("player"))) and true or false
end

function Util.InRaidInstance()
    local inInstance, instanceType = IsInInstance()
    return (inInstance and instanceType == "raid") and true or false
end

-- Inside a 5-man dungeon (IsInInstance() type "party").
function Util.InPartyInstance()
    local inInstance, instanceType = IsInInstance()
    return (inInstance and instanceType == "party") and true or false
end

-- Name key of a unit token ("player", "party2", "raid7", ...), or nil.
function Util.UnitKey(unit)
    if type(unit) ~= "string" or not UnitExists(unit) then return nil end
    return UnitKey(unit)
end

local PARTY_UNITS = { "player", "party1", "party2", "party3", "party4" }

-- Unit token ("player" / "partyN") of a member of my 5-man party, or nil (also nil in a raid).
function Util.GetPartyUnit(key)
    if type(key) ~= "string" or IsInRaid() or not IsInGroup() then return nil end
    for _, unit in ipairs(PARTY_UNITS) do
        if UnitExists(unit) and UnitKey(unit) == key then return unit end
    end
    return nil
end

-- rank (0 member, 1 assistant, 2 leader) and isML of a raid or party member, read straight from the
-- client (the Util.group cache refreshes on a short debounce). nil when key is not in my group.
function Util.GetGroupRole(key)
    if type(key) ~= "string" then return nil end
    if IsInRaid() then
        local n = tonumber(GetNumGroupMembers()) or 0
        if n > 40 then n = 40 end
        for i = 1, n do
            local name, rank, _, _, _, _, _, _, _, _, isML = GetRaidRosterInfo(i)
            if type(name) == "string" and name ~= UNKNOWNOBJECT and Util.NormalizeName(name) == key then
                return tonumber(rank) or 0, isML and true or false
            end
        end
        return nil
    end
    if not IsInGroup() then return nil end
    local method, mlPartyID = LootMethod()
    local isMLMethod = method == MasterLooterMethod()
    for idx, unit in ipairs(PARTY_UNITS) do
        if UnitExists(unit) and UnitKey(unit) == key then
            local rank = UnitIsGroupLeader(unit) and 2
                or ((UnitIsGroupAssistant and UnitIsGroupAssistant(unit)) and 1 or 0)
            return rank, (isMLMethod and mlPartyID == idx - 1) and true or false
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Dungeon mode (Addendum B §22.1). The switch itself lives in Core/Dungeon.lua (DM messages,
-- /cdl dungeon); these two are the effective checks every module uses.
---------------------------------------------------------------------------

-- The effective dungeon.enabled (Addendum D §26): the loot authority's switch while group rules are
-- active, else my own setting.
local function DungeonSettingOn()
    local DB = ns.DB
    if DB and DB.GetEffective then
        return DB:GetEffective("dungeon.enabled") == true
    end
    local db = ns.db
    local s = db and db.settings
    local d = type(s) == "table" and s.dungeon
    return type(d) == "table" and d.enabled == true
end

-- In a 5-man party (not a raid) with dungeon mode on: the effective setting (the group's rule, or my
-- own), or turned on for the group by a CDLoot 0.2 party leader / council member (DM, session only).
function Util.IsDungeonModeActive()
    if IsInRaid() or not IsInGroup() then return false end
    if DungeonSettingOn() then return true end
    local D = ns.Dungeon
    local by = type(D) == "table" and D.groupEnabledBy
    if not by then return false end
    -- The legacy switch only counts for an enabler without group rules (CDLoot 0.2); a member that speaks
    -- GS decides through the group rules (its DM only mirrors them for 0.2 clients).
    local GR = ns.GroupRules
    if GR and GR.IsSpeaker and GR:IsSpeaker(by) then return false end
    return true
end

-- Channel for group traffic (drops, rolls): "RAID" in a raid, "PARTY" in a party with dungeon mode
-- active, else nil (nothing is sent).
function Util.GetGroupChannel()
    if IsInRaid() then return "RAID" end
    if Util.IsDungeonModeActive() then return "PARTY" end
    return nil
end

local function OnGroupEvent()
    Util.Debounce("cdl-group", 0.3, Util.RefreshGroup)
end

ns:RegisterEvent("GROUP_ROSTER_UPDATE", OnGroupEvent)
ns:RegisterEvent("PLAYER_ENTERING_WORLD", OnGroupEvent)
-- The master looter / leader can change without a roster change: isML / rank in Util.group must follow.
ns:RegisterEvent("PARTY_LOOT_METHOD_CHANGED", OnGroupEvent)
ns:RegisterEvent("PARTY_LEADER_CHANGED", OnGroupEvent)

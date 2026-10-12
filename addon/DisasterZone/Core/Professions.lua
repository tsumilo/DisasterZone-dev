if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Professions.lua", ...) then return end -- DisasterZone: guild professions (the Members tab's data).
-- The client can only read its OWN character's professions (skill lines) and, while a profession window is open, that
-- profession's recipes. Every DisasterZone client shares those with the guild and keeps what the others shared, so the
-- Members tab can show who has which profession and who can craft what. Nothing here touches loot state.
--
-- Data (SavedVariables: db.prof[guildKey][charKey]):
--   rec = { rev, p = { [profId] = { r = rank, m = max rank, s = specialisation spell | nil, e = epoch, rr, n } },
--           R = { [profId] = { e = epoch, rr = recipe rev, n = count, d = packed recipes } }, own = true | nil, src,
--           t = { a, b, c [, a2, b2, c2] } talent points per tab of the primary (and secondary) talents,
--           ms / os = the main / off spec picked in My BiS (index into ns.SPECS[class]); the talents only fill in
--           when My BiS has none (somebody's primary talents can be their off spec),
--           a = key of the player's main when this character is an alt,
--           g = { itemID or 0, ... } the gear worn, one per ns.SLOTS slot (1.3; the whole guild sees it: the BiS lists
--               stay with the loot council) }
--   own   a character of this account (it logged in here): only this account says which of them is the main
--   rev   server time of the last change of anything in the record (newer wins)
--   e     server time the owner's client first saw the profession: dropping and relearning one starts a new epoch,
--         and recipes of an older epoch are thrown away
--   rr/n  rev and number of the owner's recipes (in the summary, so a receiver knows what it is missing)
--   Recipes only grow within an epoch (nobody unlearns a recipe), so parts and relays are merged as a union.
--
-- Messages (their own prefix, class "member", so a long recipe transfer never delays council traffic):
--   PFI { i = { [key] = rev }, a, b }  GUILD, once after login: what I have (keys in (a, b], in parts of 150)
--   PFB { l = { { k, v, p = { { id, r, m, s, e, rr, n }, ... }, ts, ms, os, a, g }, ... } }   summaries, GUILD (or WHISPER)
--   PFR { k, i = profId, e, rr, d }    one part (at most 250 recipes) of a character's recipes
--   PFW { s = { key, ... }, r = { { key, profId }, ... } }   WHISPER: send me these summaries / recipes
-- Anyone in the guild may pass on anyone's record (that is how offline members' professions are known); the owner's
-- own client always wins for its own character.
local addonName, ns = ...

local Prof = ns:NewModule("Professions")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, next = type, pairs, ipairs, tonumber, tostring, next
local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat
local strbyte, strchar, strsub = string.byte, string.char, string.sub

---------------------------------------------------------------------------
-- The professions (id = the skill line id; the same on every locale)
---------------------------------------------------------------------------

local ICONS = "Interface\\Icons\\"
-- spell: a spell whose name is the profession's name on this client's locale (the skill list only has names)
local LIST = {
    { id = 171, name = "Alchemy",        spell = 2259,  icon = ICONS .. "Trade_Alchemy",            primary = true, crafts = true },
    { id = 164, name = "Blacksmithing",  spell = 2018,  icon = ICONS .. "Trade_BlackSmithing",      primary = true, crafts = true },
    { id = 333, name = "Enchanting",     spell = 7411,  icon = ICONS .. "Trade_Engraving",          primary = true, crafts = true },
    { id = 202, name = "Engineering",    spell = 4036,  icon = ICONS .. "Trade_Engineering",        primary = true, crafts = true },
    { id = 755, name = "Jewelcrafting",  spell = 25229, icon = ICONS .. "INV_Misc_Gem_01",          primary = true, crafts = true },
    { id = 165, name = "Leatherworking", spell = 2108,  icon = ICONS .. "Trade_LeatherWorking",     primary = true, crafts = true },
    { id = 197, name = "Tailoring",      spell = 3908,  icon = ICONS .. "Trade_Tailoring",          primary = true, crafts = true },
    { id = 186, name = "Mining",         spell = 2575,  icon = ICONS .. "Trade_Mining",             primary = true, crafts = true,
      alias = 2656 },   -- (the smelting window)
    { id = 182, name = "Herbalism",                     icon = ICONS .. "Trade_Herbalism",          primary = true },
    { id = 393, name = "Skinning",       spell = 8613,  icon = ICONS .. "INV_Misc_Pelt_Wolf_01",    primary = true },
    { id = 185, name = "Cooking",        spell = 2550,  icon = ICONS .. "INV_Misc_Food_15",         crafts = true },
    { id = 129, name = "First Aid",      spell = 3273,  icon = ICONS .. "Spell_Holy_SealOfSacrifice", crafts = true },
    { id = 356, name = "Fishing",        spell = 7620,  icon = ICONS .. "Trade_Fishing" },
}
local BY_ID = {}
for i, def in ipairs(LIST) do
    def.order = i
    BY_ID[def.id] = def
end

-- The specialisations, as the spell a character knows. Checked in this order (the weapon branches before Weaponsmith).
local SPECS = {
    [171] = { 28675, 28677, 28672 },             -- Potion / Elixir / Transmutation Master
    [164] = { 17039, 17040, 17041, 9787, 9788 }, -- Sword- / Hammer- / Axesmith, Weaponsmith, Armorsmith
    [202] = { 20219, 20222 },                    -- Gnomish / Goblin Engineer
    [165] = { 10656, 10658, 10660 },             -- Dragonscale / Elemental / Tribal Leatherworking
    [197] = { 26797, 26798, 26801 },             -- Spellfire / Mooncloth / Shadoweave Tailoring
}
local SPEC_OK = {}
for id, list in pairs(SPECS) do
    for _, spell in ipairs(list) do SPEC_OK[spell] = id end
end

local NO_GUILD = "~"            -- bucket of a guildless character
local MAX_REV = 2147483647
local FUTURE_SLACK = 60         -- a rev more than a minute past the server time is not plausible
local MAX_RANK = 1000
local MAX_RECIPES = 2000        -- per character and profession
local MAX_PACKED = 16000        -- bytes of a stored recipe set
local MAX_SPELL = 16777215
local PART_RECIPES = 250        -- recipes per PFR
local BATCH = 20                -- summaries per PFB
local INDEX_PART = 150          -- keys per PFI
local MAX_KEY_LEN = 48
local MAX_SPEC = 8              -- spec index (ns.SPECS[class] has 3 or 4)
local MAX_ITEM = 2147483647

local SCAN_DELAY = 2            -- after a skill change / a profession window update
local OWN_SEND_DELAY = 15       -- my own changes are shared this long after the last one ...
local OWN_SEND_GAP = 120        -- ... and at most this often (skill-ups come in bursts)
local INDEX_MIN, INDEX_MAX = 45, 90      -- the login PFI
local REPLY_OWN_MIN, REPLY_OWN_MAX = 1, 3        -- answering a PFI with my own record
local REPLY_MIN, REPLY_MAX = 4, 15       -- ... with records of others (whoever is first; the rest stay quiet)
local WANT_TICK = 8             -- recipe requests go out in small steps
local WANT_PER_TICK = 4
local WANT_RETRY = 90
local WANT_TRIES = 5

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local nameToId              -- [profession name on this client] = id
local guildSeen = {}        -- [key] = { v = rev, at = GetTime() } a summary seen (or sent) on GUILD
local peers = {}            -- [key] = GetTime() of their last profession message this session
local wants = {}            -- ["key\001id"] = { key, id, tries, nextAt }
local wantTicker
local dirtyRecipes = {}     -- [profId] = true: my recipes changed since they were last shared
local lastOwnSend = -1000
local indexSent = false
local index                 -- the recipe index for the UI (nil = rebuild)
local nameTries = 0         -- rebuilds made only because recipe names were still loading
local nameRequested = {}    -- [spell] = true: the client was asked to load the spell's name
local ownDirty = {}         -- [key] = true: records of my other characters to share (a new main)
local sanitized = {}        -- [bucket key] = true

local Now, IsInt = Util.Now, Util.IsInt

local function Send(msg, dist, target)
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, dist, target, "member")) and true or false
end

local RateLimit = Util.RateLimit

local function WireKey(s)
    if type(s) ~= "string" or s == "" or #s > MAX_KEY_LEN or s:find("[%c|]") then return nil end
    return Util.NormalizeName(s)
end

local function InGuild(key)
    local Guild = ns.Guild
    return (Guild and Guild:IsInGuild(key, true)) and true or false
end

local function IsOnline(key)
    local Guild = ns.Guild
    return (Guild and Guild:IsOnline(key, true)) and true or false
end

-- Delays come from their own sequence: math.random is shared with rolls and the games.
local jitterSeed
local function Jitter()
    if not jitterSeed then
        jitterSeed = ((tonumber(Util.Adler32(Util.PlayerKey() or "")) or 1) + floor(GetTime() * 1000)) % 2147483647
    end
    jitterSeed = (jitterSeed * 16807 + 12345) % 2147483647
    return jitterSeed / 2147483647
end

local function JitterDelay(lo, hi, fn)
    Util.After(lo + Jitter() * (hi - lo), fn)
end

local function Changed()
    index = nil
    nameTries = 0
    Util.Debounce("prof-updated", 0.3, function() ns:Fire("PROFESSIONS_UPDATED") end)
end

---------------------------------------------------------------------------
-- Recipe sets as text: recipes sorted by spell id, each as two numbers (the spell id as the difference to the one
-- before; the crafted item as 0 = none, else the zigzag difference to the last item + 1), every number in base 32
-- with a "more follows" bit, one printable character per digit. Text survives SavedVariables and deflates well.
---------------------------------------------------------------------------

local DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
local DIGIT_OF = {}
for i = 1, #DIGITS do DIGIT_OF[strbyte(DIGITS, i)] = i - 1 end

local function PutNumber(buf, n)
    repeat
        local d = n % 32
        n = (n - d) / 32
        if n > 0 then d = d + 32 end
        buf[#buf + 1] = strsub(DIGITS, d + 1, d + 1)
    until n == 0
end

-- map = { [spell] = item (0 = none) } -> sorted spell array
local function SortedSpells(map)
    local spells = {}
    for spell in pairs(map) do spells[#spells + 1] = spell end
    tsort(spells)
    return spells
end

-- Packs spells[from..to] (sorted) of map.
local function Pack(map, spells, from, to)
    spells = spells or SortedSpells(map)
    local buf = {}
    local prevSpell, prevItem = 0, 0
    for i = from or 1, to or #spells do
        local spell = spells[i]
        local item = map[spell] or 0
        PutNumber(buf, spell - prevSpell)
        prevSpell = spell
        if item > 0 then
            local diff = item - prevItem
            PutNumber(buf, (diff >= 0 and diff * 2 or (-diff * 2 - 1)) + 1)
            prevItem = item
        else
            PutNumber(buf, 0)
        end
    end
    return tconcat(buf)
end

-- Calls fn(spell, item) for every recipe in a packed set. Returns the number of recipes, or nil when the text is
-- malformed (then fn may have been called for the recipes before the damage).
local function Unpack(text, fn)
    if type(text) ~= "string" or #text > MAX_PACKED then return nil end
    local pos, len = 1, #text
    local function number()
        local n, mult = 0, 1
        while true do
            local d = DIGIT_OF[strbyte(text, pos)]
            if not d then return nil end
            pos = pos + 1
            if d >= 32 then
                n = n + (d - 32) * mult
                mult = mult * 32
                if mult > 33554432 then return nil end
            else
                return n + d * mult
            end
        end
    end
    local count, spell, lastItem = 0, 0, 0
    while pos <= len do
        local ds = number()
        local z = ds and number()
        if not z or ds < 1 then return nil end
        spell = spell + ds
        local item = 0
        if z > 0 then
            z = z - 1
            item = lastItem + ((z % 2 == 0) and (z / 2) or (-(z + 1) / 2))
            lastItem = item
        end
        count = count + 1
        if spell > MAX_SPELL or item < 0 or item > MAX_SPELL or count > MAX_RECIPES then return nil end
        if fn then fn(spell, item) end
    end
    return count
end

local function ToMap(text)
    local map = {}
    local n = Unpack(text, function(spell, item) map[spell] = item end)
    return n and map or nil, n
end

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

-- The worn gear: one item id (0 = nothing) per ns.SLOTS slot.
local function ValidGear(g)
    local n = ns.SLOTS and #ns.SLOTS or 0
    if type(g) ~= "table" or #g ~= n or n == 0 then return false end
    for i = 1, n do
        if not IsInt(g[i], 0, MAX_ITEM) then return false end
    end
    return true
end

local function ValidRecord(rec)
    if type(rec) ~= "table" or not IsInt(rec.rev, 0, MAX_REV) or type(rec.p) ~= "table" then return false end
    for id, e in pairs(rec.p) do
        if not BY_ID[id] or type(e) ~= "table" or not IsInt(e.r, 0, MAX_RANK) or not IsInt(e.m, 0, MAX_RANK)
            or not IsInt(e.e, 0, MAX_REV) then
            return false
        end
        if not IsInt(e.rr, 0, MAX_REV) then e.rr = 0 end
        if not IsInt(e.n, 0, MAX_RECIPES) then e.n = 0 end
        if e.s ~= nil and SPEC_OK[e.s] ~= id then e.s = nil end
    end
    if rec.t ~= nil then
        local ok = type(rec.t) == "table" and (#rec.t == 3 or #rec.t == 6)
        for i = 1, ok and #rec.t or 0 do
            if not IsInt(rec.t[i], 0, 100) then ok = false end
        end
        if not ok then rec.t = nil end
    end
    if rec.a ~= nil and type(rec.a) ~= "string" then rec.a = nil end
    if rec.g ~= nil and not ValidGear(rec.g) then rec.g = nil end
    if not IsInt(rec.ms, 1, MAX_SPEC) then rec.ms = nil end
    if not IsInt(rec.os, 1, MAX_SPEC) then rec.os = nil end
    if type(rec.R) ~= "table" then rec.R = {} end
    for id, set in pairs(rec.R) do
        if not BY_ID[id] or type(set) ~= "table" or not IsInt(set.e, 0, MAX_REV) or not IsInt(set.rr, 0, MAX_REV)
            or type(set.d) ~= "string" or not IsInt(set.n, 0, MAX_RECIPES) then
            rec.R[id] = nil
        end
    end
    return true
end

-- The records of my current guild: { [charKey] = rec }, and the bucket key. nil while the guild's name is not known
-- yet (a moment after login), and while nothing was stored for the guild (unless `create`: reading saves nothing).
local function Bucket(create)
    local db = ns.db
    if not db then return nil end
    if type(db.prof) ~= "table" then db.prof = {} end
    local gk = NO_GUILD
    if IsInGuild() then
        gk = ns.Guild and ns.Guild.GetGuildKey and ns.Guild:GetGuildKey()
        if type(gk) ~= "string" then return nil end
    end
    local b = ns.DB:GuildBucket("prof", create, gk)
    if not b then return nil, gk end
    if not sanitized[gk] then
        sanitized[gk] = true
        for key, rec in pairs(b) do
            if type(key) ~= "string" or not ValidRecord(rec) then b[key] = nil end
        end
    end
    return b, gk
end

local function GetRec(key)
    local b = Bucket()
    return b and b[key] or nil
end

-- My own record. A character that changed guild takes its record along.
local function OwnRec(create)
    local b, gk = Bucket(create)
    local me = Util.PlayerKey()
    if not me or not gk then return nil end
    local rec = b and b[me]
    if not rec then
        for otherKey, other in pairs(ns.db.prof) do
            if otherKey ~= gk and type(other) == "table" and ValidRecord(other[me]) and other[me].own then
                rec = other[me]
                other[me] = nil
                b = b or Bucket(true)
                b[me] = rec
                break
            end
        end
    end
    if not rec then
        if not create then return nil end
        rec = { rev = 0, p = {}, R = {} }
        b[me] = rec
    end
    rec.own = true
    return rec, me
end

local function Bump(rec)
    rec.rev = max(Now(), rec.rev + 1)
end

-- A character that logs in on this account for the first time joins the account's main: picking a main links every
-- character, the later ones too. nil while the account has no main (or its characters disagree).
local function AccountMain(b, me)
    local main
    for key, rec in pairs(b or {}) do
        if key ~= me and rec.own and rec.a ~= nil then
            if main ~= nil and main ~= rec.a then return nil end
            main = rec.a
        end
    end
    local mrec = main and b[main]
    if main == me or (mrec and mrec.a ~= nil) then return nil end
    return main
end

-- Every character of mine here an alt of `mainKey` (the main itself none). Returns whether a record changed.
local function ApplyMain(b, mainKey)
    local changed = false
    for key, rec in pairs(b) do
        if rec.own then
            local want = key ~= mainKey and mainKey or nil
            if rec.a ~= want then
                rec.a = want
                Bump(rec)
                ownDirty[key] = true
                changed = true
            end
        end
    end
    return changed
end

-- An account with two or more characters here and no main yet gets one: the highest level, then the first by name
-- (the player can pick another outside raids). nil while there is nothing to pick or the roster isn't read.
local function DefaultMain(b)
    local Guild = ns.Guild
    if not (Guild and Guild.IsReady and Guild:IsReady()) then return nil end
    local best, bestLevel, n = nil, -1, 0
    for key, rec in pairs(b or {}) do
        if rec.own then
            if rec.a ~= nil then return nil end   -- (a main is picked)
            local m = Guild:GetMember(key, true)
            if m or Util.IsMe(key) then
                n = n + 1
                local level = tonumber(m and m.level) or (Util.IsMe(key) and UnitLevel and tonumber(UnitLevel("player"))) or 0
                if level > bestLevel or (level == bestLevel and key < best) then best, bestLevel = key, level end
            end
        end
    end
    return n >= 2 and best or nil
end

-- A record I pass on: of a character in my guild's roster.
local function Shareable(key, rec)
    return rec.rev > 0 and InGuild(key)
end

---------------------------------------------------------------------------
-- Reading my own professions
---------------------------------------------------------------------------

local function BuildNames()
    nameToId = {}
    for _, def in ipairs(LIST) do
        nameToId[def.name] = def.id
        for _, spell in ipairs({ def.spell, def.alias }) do
            local name = GetSpellInfo and GetSpellInfo(spell)
            if type(name) == "string" and name ~= "" then nameToId[name] = def.id end
        end
    end
end

local function IdByName(name)
    if type(name) ~= "string" then return nil end
    if not nameToId then BuildNames() end
    return nameToId[name]
end

local function KnowsSpell(spell)
    if IsPlayerSpell and IsPlayerSpell(spell) then return true end
    if IsSpellKnown and IsSpellKnown(spell) then return true end
    return false
end

local function OwnSpec(id)
    for _, spell in ipairs(SPECS[id] or {}) do
        if KnowsSpell(spell) then return spell end
    end
    return nil
end

-- { [id] = { r, m } } from the skill list, or nil while the list is not loaded.
local function ReadSkills()
    if not (GetNumSkillLines and GetSkillLineInfo) then return nil end
    local n = tonumber(GetNumSkillLines()) or 0
    if n == 0 then return nil end
    -- lines under a collapsed header are hidden: a profession there would look dropped
    for i = 1, n do
        local _, isHeader, isExpanded = GetSkillLineInfo(i)
        if isHeader and not isExpanded then
            if ExpandSkillHeader then ExpandSkillHeader(0) end
            n = tonumber(GetNumSkillLines()) or 0
            break
        end
    end
    local out = {}
    for i = 1, n do
        local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
        local id = not isHeader and IdByName(name)
        if id then
            out[id] = { r = min(max(floor(tonumber(rank) or 0), 0), MAX_RANK),
                        m = min(max(floor(tonumber(maxRank) or 0), 0), MAX_RANK) }
        end
    end
    return out
end

-- Talent points per tab of talent group 1 (primary) and, with dual talents, 2 (secondary): { a, b, c [, a2, b2, c2] }.
-- nil while the client can't tell.
local function TabPoints(tab, group)
    local C = C_SpecializationInfo
    if C and C.GetSpecializationInfo then
        local ok, _, _, _, _, _, _, points = pcall(C.GetSpecializationInfo, tab, false, false, nil, nil, group)
        if ok and tonumber(points) then return tonumber(points) end
    end
    if GetTalentTabInfo then
        local ok, r1, _, r3, _, r5 = pcall(GetTalentTabInfo, tab, false, false, group)
        if ok then return (type(r1) == "string") and tonumber(r3) or tonumber(r5) end
    end
    return nil
end

local function ReadTalents()
    local groups = (GetNumTalentGroups and tonumber(GetNumTalentGroups())) or 1
    local out = {}
    for group = 1, min(max(groups, 1), 2) do
        local total = 0
        for tab = 1, 3 do
            local points = TabPoints(tab, group)
            if not points then return nil end
            points = min(max(floor(points), 0), 100)
            out[#out + 1] = points
            total = total + points
        end
        -- an empty secondary set is no off spec
        if group == 2 and total == 0 then out[4], out[5], out[6] = nil, nil, nil end
    end
    return out
end

-- The main / off spec picked in My BiS, as indexes into ns.SPECS[my class] (nil: none picked).
local function BiSSpecs()
    local BiS = ns.BiS
    local classFile = UnitClass and select(2, UnitClass("player"))
    local specs = ns.SPECS and classFile and ns.SPECS[classFile]
    if not (BiS and BiS.GetSpec and specs) then return nil, nil end
    local function index(list)
        local ok, label = pcall(BiS.GetSpec, BiS, list)
        if not ok or type(label) ~= "string" or label == "" then return nil end
        for i, spec in ipairs(specs) do
            if spec.label == label then return i end
        end
        return nil
    end
    return index(nil), index("os")
end

local function SameList(a, b)
    if a == nil or b == nil then return a == b end
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- The gear I wear, as stored in rec.g (nil before login / without the slot table).
local function ReadGear()
    if not (ns.loggedIn and ns.SLOTS and GetInventoryItemID) then return nil end
    local g = {}
    for sid, slot in ipairs(ns.SLOTS) do
        local id = GetInventoryItemID("player", slot.invSlot)   -- (two returns on this client; the first is the id)
        g[sid] = IsInt(id, 1, MAX_ITEM) and id or 0
    end
    return g
end

local ScheduleOwnSend   -- forward

local function UpdateOwn()
    if not ns.loggedIn then return end
    local skills = ReadSkills()
    if not skills then return end
    local rec = OwnRec(true)
    if not rec then return end
    local changed = false
    for id, s in pairs(skills) do
        local e = rec.p[id]
        if not e then
            e = { e = Now(), rr = 0, n = 0 }
            rec.p[id] = e
            rec.R[id] = nil
            changed = true
        end
        local spec = OwnSpec(id)
        if e.r ~= s.r or e.m ~= s.m or e.s ~= spec then
            e.r, e.m, e.s = s.r, s.m, spec
            changed = true
        end
    end
    for id in pairs(rec.p) do
        if not skills[id] then
            rec.p[id] = nil
            rec.R[id] = nil
            dirtyRecipes[id] = nil
            changed = true
        end
    end
    local talents = ReadTalents()
    if talents and not SameList(talents, rec.t) then
        rec.t = talents
        changed = true
    end
    local ms, os = BiSSpecs()
    if rec.ms ~= ms or rec.os ~= os then
        rec.ms, rec.os = ms, os
        changed = true
    end
    local gear = ReadGear()
    if gear and not SameList(gear, rec.g) then
        rec.g = gear
        changed = true
    end
    local main = rec.a == nil and AccountMain(Bucket(), Util.PlayerKey())
    if main then
        rec.a = main
        changed = true
    elseif rec.a == nil then
        local pick = DefaultMain(Bucket())
        if pick and ApplyMain(Bucket(), pick) then
            lastOwnSend = -1000
            changed = true
        end
    end
    if changed or rec.rev == 0 then
        Bump(rec)
        Changed()
        ScheduleOwnSend()
    end
end

-- Recipes read from an open profession window: found = { [spell] = item }. They are added to what is known (a
-- filtered or collapsed window shows only a part).
local function MergeOwnRecipes(id, found)
    if not next(found) then return end
    UpdateOwn()
    local rec = OwnRec(false)
    local e = rec and rec.p[id]
    if not e then return end
    local set = rec.R[id]
    local map = set and set.e == e.e and ToMap(set.d) or {}
    local added = false
    for spell, item in pairs(found) do
        if map[spell] == nil or (map[spell] == 0 and item > 0) then
            map[spell] = item
            added = true
        end
    end
    if not added and set and set.e == e.e then return end
    local spells = SortedSpells(map)
    while #spells > MAX_RECIPES do
        map[spells[#spells]] = nil
        spells[#spells] = nil
    end
    Bump(rec)
    rec.R[id] = { e = e.e, rr = rec.rev, n = #spells, d = Pack(map, spells) }
    e.rr, e.n = rec.rev, #spells
    dirtyRecipes[id] = true
    Changed()
    ScheduleOwnSend()
end

local function LinkId(link, kinds)
    if type(link) ~= "string" then return nil end
    for _, kind in ipairs(kinds) do
        local id = tonumber(link:match(kind .. ":(%d+)"))
        if id and id > 0 and id <= MAX_SPELL then return id end
    end
    return nil
end

local RECIPE_KINDS = { "enchant", "spell" }
local ITEM_KINDS = { "item" }

-- The trade skill window (every profession but, on this client, Enchanting).
local function ScanTradeSkill()
    if not (GetTradeSkillLine and GetNumTradeSkills and GetTradeSkillInfo) then return end
    if IsTradeSkillLinked and IsTradeSkillLinked() then return end   -- somebody else's profession link
    local id = IdByName((GetTradeSkillLine()))
    if not id then return end
    local found = {}
    for i = 1, tonumber(GetNumTradeSkills()) or 0 do
        local name, kind = GetTradeSkillInfo(i)
        if name and kind ~= "header" and kind ~= "subheader" then
            local itemLink = GetTradeSkillItemLink and GetTradeSkillItemLink(i)
            local spell = LinkId(GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(i), RECIPE_KINDS)
                or LinkId(itemLink, RECIPE_KINDS)
            if spell then found[spell] = LinkId(itemLink, ITEM_KINDS) or 0 end
        end
    end
    MergeOwnRecipes(id, found)
end

-- The craft window (Enchanting; also the hunter's Beast Training, which has no profession line).
local function ScanCraft()
    if not (GetNumCrafts and GetCraftInfo and GetCraftDisplaySkillLine) then return end
    local id = IdByName((GetCraftDisplaySkillLine()))
    if not id then return end
    local found = {}
    for i = 1, tonumber(GetNumCrafts()) or 0 do
        local name, _, kind = GetCraftInfo(i)
        if name and kind ~= "header" then
            local itemLink = GetCraftItemLink and GetCraftItemLink(i)
            local spell = LinkId(GetCraftRecipeLink and GetCraftRecipeLink(i), RECIPE_KINDS)
                or LinkId(itemLink, RECIPE_KINDS)
            if spell then found[spell] = LinkId(itemLink, ITEM_KINDS) or 0 end
        end
    end
    MergeOwnRecipes(id, found)
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function Summary(key, rec)
    local p = {}
    for id, e in pairs(rec.p) do
        p[#p + 1] = { id, e.r, e.m, e.s or 0, e.e, e.rr or 0, e.n or 0 }
    end
    tsort(p, function(a, b) return a[1] < b[1] end)
    return { k = key, v = rec.rev, p = p, ts = rec.t, ms = rec.ms, os = rec.os, a = rec.a, g = rec.g }
end

-- Summaries of `keys`, in batches. Returns the number of messages.
local function SendSummaries(keys, dist, target)
    local b = Bucket()
    if not b then return 0 end
    local sent, batch = 0, {}
    local function flush()
        if #batch > 0 and Send({ t = "PFB", l = batch }, dist, target) then sent = sent + 1 end
        batch = {}
    end
    for _, key in ipairs(keys) do
        local rec = b[key]
        if rec then
            batch[#batch + 1] = Summary(key, rec)
            if dist == "GUILD" then guildSeen[key] = { v = rec.rev, at = GetTime() } end
            if #batch >= BATCH then flush() end
        end
    end
    flush()
    return sent
end

local function SendRecipes(key, id, dist, target)
    local rec = GetRec(key)
    local set = rec and rec.R[id]
    if not set then return false end
    local map = ToMap(set.d)
    if not map then return false end
    local spells = SortedSpells(map)
    for from = 1, #spells, PART_RECIPES do
        Send({ t = "PFR", k = key, i = id, e = set.e, rr = set.rr,
               d = Pack(map, spells, from, min(from + PART_RECIPES - 1, #spells)) }, dist, target)
    end
    return true
end

local function SendOwn()
    if not IsInGuild() then return end
    local rec, me = OwnRec(false)
    if not rec or rec.rev == 0 then return end
    local wait = lastOwnSend + OWN_SEND_GAP - GetTime()
    if wait > 0 then
        Util.Debounce("prof-own-send", wait + 0.1, SendOwn)
        return
    end
    lastOwnSend = GetTime()
    local keys = { me }
    for key in pairs(ownDirty) do
        local other = GetRec(key)
        if key ~= me and other and Shareable(key, other) then keys[#keys + 1] = key end
    end
    ownDirty = {}
    SendSummaries(keys, "GUILD")
    for id in pairs(dirtyRecipes) do
        SendRecipes(me, id, "GUILD")
    end
    dirtyRecipes = {}
end

ScheduleOwnSend = function()
    if not ns.loggedIn then return end
    Util.Debounce("prof-own-send", OWN_SEND_DELAY, SendOwn)
end

-- What I have, for everyone online: they send what I miss and ask for what they miss.
local function SendIndex()
    local b, gk = Bucket()
    if not gk or not IsInGuild() then return end
    b = b or {}
    local keys = {}
    for key, rec in pairs(b) do
        if Shareable(key, rec) then keys[#keys + 1] = key end
    end
    tsort(keys)
    local from, lower = 1, nil
    repeat
        local to = min(from + INDEX_PART - 1, #keys)
        local i = {}
        for n = from, to do i[keys[n]] = b[keys[n]].rev end
        local upper = to < #keys and keys[to] or nil
        Send({ t = "PFI", i = i, a = lower, b = upper }, "GUILD")
        lower = upper
        from = to + 1
    until from > #keys
    indexSent = true
end

---------------------------------------------------------------------------
-- Asking for recipes (in small steps, from whoever is online and has them)
---------------------------------------------------------------------------

local function NeedsRecipes(key, id)
    local rec = GetRec(key)
    local e = rec and not Util.IsMe(key) and rec.p[id]
    if not e or (e.n or 0) == 0 then return false end
    local set = rec.R[id]
    return not set or set.e < e.e or set.rr < e.rr or set.n < e.n
end

local function WantSource(w)
    local rec = GetRec(w.key)
    if w.tries < 2 and IsOnline(w.key) and not Util.IsMe(w.key) then return w.key end
    local src = rec and rec.src
    if w.tries < 3 and type(src) == "string" and IsOnline(src) and not Util.IsMe(src) then return src end
    local online = {}
    for key in pairs(peers) do
        if IsOnline(key) then online[#online + 1] = key end
    end
    if #online == 0 then return nil end
    tsort(online)
    return online[(w.tries % #online) + 1]
end

local function ProcessWants()
    local now = GetTime()
    local byTarget, picked, pending = {}, 0, false
    for k, w in pairs(wants) do
        if not NeedsRecipes(w.key, w.id) then
            wants[k] = nil
        elseif w.tries < WANT_TRIES then
            pending = true
            if w.nextAt <= now and picked < WANT_PER_TICK then
                local target = WantSource(w)
                if target then
                    byTarget[target] = byTarget[target] or {}
                    local list = byTarget[target]
                    list[#list + 1] = { w.key, w.id }
                    picked = picked + 1
                end
                w.tries = w.tries + 1
                w.nextAt = now + WANT_RETRY
            end
        end
    end
    for target, list in pairs(byTarget) do
        Send({ t = "PFW", r = list }, "WHISPER", target)
    end
    if not pending and wantTicker then
        wantTicker:Cancel()
        wantTicker = nil
    end
end

local function StartWants()
    if wantTicker or not (C_Timer and C_Timer.NewTicker) then return end
    wantTicker = C_Timer.NewTicker(WANT_TICK, ProcessWants)
end

local function QueueWants(key)
    local rec = GetRec(key)
    if not rec then return end
    for id in pairs(rec.p) do
        local k = key .. "\001" .. id
        if NeedsRecipes(key, id) then
            if not wants[k] then wants[k] = { key = key, id = id, tries = 0, nextAt = 0 } end
            StartWants()
        end
    end
end

-- A peer not seen before this session may have what earlier requests did not find.
local function NotePeer(key)
    if peers[key] == nil then
        for _, w in pairs(wants) do
            if w.tries >= WANT_TRIES then w.tries, w.nextAt = 0, 0 end
        end
        if next(wants) then StartWants() end
    end
    peers[key] = GetTime()
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

-- { key, rev, p = { [id] = { r, m, s, e, rr, n } } } of a well-formed wire summary, else nil.
local function ParseSummary(s)
    if type(s) ~= "table" then return nil end
    local key = WireKey(s.k)
    if not key or not IsInt(s.v, 1, min(MAX_REV, Now() + FUTURE_SLACK)) or type(s.p) ~= "table" then return nil end
    local p, n = {}, 0
    for _, row in pairs(s.p) do
        n = n + 1
        if n > #LIST or type(row) ~= "table" then return nil end
        local id, r, m, spec, e, rr, cnt = row[1], row[2], row[3], row[4], row[5], row[6], row[7]
        if not BY_ID[id] or p[id] or not IsInt(r, 0, MAX_RANK) or not IsInt(m, 0, MAX_RANK)
            or not IsInt(e, 0, s.v) or not IsInt(rr, 0, s.v) or not IsInt(cnt, 0, MAX_RECIPES) then
            return nil
        end
        if spec == 0 then spec = nil end
        if spec ~= nil and SPEC_OK[spec] ~= id then return nil end
        p[id] = { r = r, m = m, s = spec, e = e, rr = rr, n = cnt }
    end
    local t
    if s.ts ~= nil then
        if type(s.ts) ~= "table" or (#s.ts ~= 3 and #s.ts ~= 6) then return nil end
        t = {}
        for i = 1, #s.ts do
            if not IsInt(s.ts[i], 0, 100) then return nil end
            t[i] = s.ts[i]
        end
    end
    local main
    if s.a ~= nil then
        main = WireKey(s.a)
        if not main or main == key then return nil end
    end
    if (s.ms ~= nil and not IsInt(s.ms, 1, MAX_SPEC)) or (s.os ~= nil and not IsInt(s.os, 1, MAX_SPEC)) then return nil end
    local gear
    if s.g ~= nil then
        if not ValidGear(s.g) then return nil end
        gear = {}
        for i = 1, #s.g do gear[i] = s.g[i] end
    end
    return { key = key, rev = s.v, p = p, t = t, a = main, ms = s.ms, os = s.os, g = gear }
end

-- Returns true when the record changed.
local function ApplySummary(s, sender)
    local b = Bucket(true)
    if not b or not InGuild(s.key) then return false end
    if Util.IsMe(s.key) then
        -- Somebody holds a record of me that claims to be newer than mine (an old install, a forgery): mine wins.
        local rec = OwnRec(false)
        if rec and s.rev > rec.rev then
            rec.rev = max(Now(), s.rev + 1)
            ScheduleOwnSend()
        end
        return false
    end
    local rec = b[s.key]
    -- the same version passed on by a client from before 1.3 had no gear: the owner's copy fills it in
    if rec and rec.rev == s.rev and rec.g == nil and s.g ~= nil then
        rec.g = s.g
        return true
    end
    if rec and rec.rev >= s.rev then return false end
    local R = rec and rec.R or {}
    for id, set in pairs(R) do
        local e = s.p[id]
        if not e or set.e < e.e then R[id] = nil end
    end
    b[s.key] = { rev = s.rev, p = s.p, R = R, src = sender, own = rec and rec.own or nil, t = s.t, a = s.a,
                 ms = s.ms, os = s.os, g = s.g }
    QueueWants(s.key)
    return true
end

local function OnBatch(sender, msg, dist)
    if (dist ~= "GUILD" and dist ~= "WHISPER") or type(msg.l) ~= "table" then return end
    NotePeer(sender)
    local changed, n = false, 0
    for _, raw in pairs(msg.l) do
        n = n + 1
        if n > 2 * BATCH then break end
        local s = ParseSummary(raw)
        if s then
            if dist == "GUILD" then
                local seen = guildSeen[s.key]
                if not seen or seen.v <= s.rev then guildSeen[s.key] = { v = s.rev, at = GetTime() } end
            end
            if ApplySummary(s, sender) then changed = true end
        end
    end
    if changed then Changed() end
end

local function OnRecipes(sender, msg, dist)
    if dist ~= "GUILD" and dist ~= "WHISPER" then return end
    NotePeer(sender)
    local key = WireKey(msg.k)
    local id = msg.i
    local limit = min(MAX_REV, Now() + FUTURE_SLACK)
    if not key or Util.IsMe(key) or not BY_ID[id] or not IsInt(msg.e, 0, limit) or not IsInt(msg.rr, 0, limit) then return end
    local b = Bucket(true)
    if not b or not InGuild(key) then return end
    local got, count = ToMap(msg.d)
    if not got or count == 0 or count > PART_RECIPES then return end
    local rec = b[key]
    if not rec then
        rec = { rev = 0, p = {}, R = {}, src = sender }
        b[key] = rec
    end
    local set = rec.R[id]
    if set and set.e > msg.e then return end   -- recipes of a profession that was dropped and relearned since
    local map = set and set.e == msg.e and ToMap(set.d) or {}
    for spell, item in pairs(got) do
        if map[spell] == nil or (map[spell] == 0 and item > 0) then map[spell] = item end
    end
    local spells = SortedSpells(map)
    if #spells > MAX_RECIPES then return end
    rec.R[id] = { e = msg.e, rr = max(set and set.e == msg.e and set.rr or 0, msg.rr), n = #spells, d = Pack(map, spells) }
    Changed()
end

local function OnIndex(sender, msg, dist)
    if dist ~= "GUILD" or type(msg.i) ~= "table" then return end
    NotePeer(sender)
    local b, gk = Bucket()
    if not gk then return end
    b = b or {}
    local lower = type(msg.a) == "string" and msg.a or nil
    local upper = type(msg.b) == "string" and msg.b or nil
    local arrived = GetTime()

    -- what the sender misses (within the key range this part covers)
    local own, others = {}, {}
    for key, rec in pairs(b) do
        if Shareable(key, rec) and key ~= sender and (not lower or key > lower) and (not upper or key <= upper) then
            local theirs = msg.i[key]
            if type(theirs) ~= "number" or theirs < rec.rev then
                if Util.IsMe(key) then own[#own + 1] = key else others[#others + 1] = key end
            end
        end
    end
    local function reply(keys)
        local out = {}
        for _, key in ipairs(keys) do
            local rec, seen = GetRec(key), guildSeen[key]
            -- somebody answered on GUILD since the question: stay quiet
            if rec and not (seen and seen.at >= arrived and seen.v >= rec.rev) then out[#out + 1] = key end
        end
        tsort(out)
        SendSummaries(out, "GUILD")
    end
    if #own > 0 then JitterDelay(REPLY_OWN_MIN, REPLY_OWN_MAX, function() reply(own) end) end
    if #others > 0 then JitterDelay(REPLY_MIN, REPLY_MAX, function() reply(others) end) end

    -- what the sender has newer than me
    local newer, n = {}, 0
    for key, rev in pairs(msg.i) do
        n = n + 1
        if n > 4 * INDEX_PART then break end
        key = WireKey(key)
        if key and IsInt(rev, 1, Now() + FUTURE_SLACK) and not Util.IsMe(key) and InGuild(key)
            and rev > (b[key] and b[key].rev or 0) then
            newer[#newer + 1] = key
        end
    end
    if #newer > 0 and RateLimit("pfw-s:" .. sender, 10) then
        JitterDelay(1, 4, function()
            local ask = {}
            for _, key in ipairs(newer) do
                local rec = GetRec(key)
                if (rec and rec.rev or 0) < msg.i[key] and #ask < INDEX_PART then ask[#ask + 1] = key end
            end
            if #ask > 0 then Send({ t = "PFW", s = ask }, "WHISPER", sender) end
        end)
    end
end

local function OnWant(sender, msg, dist)
    if dist ~= "WHISPER" then return end
    NotePeer(sender)
    local b = Bucket()
    if not b then return end
    if type(msg.s) == "table" then
        local keys, n = {}, 0
        for _, raw in pairs(msg.s) do
            n = n + 1
            if n > INDEX_PART then break end
            local key = WireKey(raw)
            local rec = key and b[key]
            local seen = key and guildSeen[key]
            if rec and Shareable(key, rec) and not (seen and seen.v >= rec.rev and GetTime() - seen.at < 20) then
                keys[#keys + 1] = key
            end
        end
        tsort(keys)
        SendSummaries(keys, "GUILD")
    end
    if type(msg.r) == "table" then
        local n = 0
        for _, pair in pairs(msg.r) do
            n = n + 1
            if n > 2 * WANT_PER_TICK then break end
            local key = type(pair) == "table" and WireKey(pair[1])
            local id = key and pair[2]
            local rec = key and b[key]
            if rec and BY_ID[id] and rec.R[id] and Shareable(key, rec)
                and RateLimit("pfr:" .. sender .. ":" .. key .. ":" .. id, 60) then
                SendRecipes(key, id, "WHISPER", sender)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Roster changes
---------------------------------------------------------------------------

-- Characters that left the guild are forgotten (my own characters stay: they may be on another realm's roster view).
local function Prune()
    local Guild = ns.Guild
    if not (IsInGuild() and Guild and Guild:IsReady()) then return end
    local b = Bucket()
    if not b then return end
    local removed = false
    for key, rec in pairs(b) do
        if not rec.own and not InGuild(key) then
            b[key] = nil
            removed = true
        end
    end
    if removed then Changed() end
end

local function ScheduleIndex()
    if indexSent or not IsInGuild() then return end
    Util.Debounce("prof-index", INDEX_MIN + Jitter() * (INDEX_MAX - INDEX_MIN), function()
        if indexSent then return end
        local Guild = ns.Guild
        if not (Guild and Guild:IsReady() and select(2, Bucket())) then
            ScheduleIndex()
            return
        end
        UpdateOwn()
        SendIndex()
        -- recipes still missing from an earlier session
        local b = Bucket()
        for key in pairs(b or {}) do QueueWants(key) end
    end)
end

---------------------------------------------------------------------------
-- Public API (UI)
---------------------------------------------------------------------------

-- The professions, in display order: { id, name, icon, primary, crafts }.
function Prof:GetProfessions()
    return LIST
end

function Prof:GetProfession(id)
    return BY_ID[id]
end

-- The profession's name on this client.
function Prof:GetName(id)
    local def = BY_ID[id]
    if not def then return nil end
    local name = def.spell and GetSpellInfo and GetSpellInfo(def.spell)
    return (type(name) == "string" and name ~= "") and name or def.name
end

local function Visible(key)
    return Util.IsMe(key) or InGuild(key)
end

-- Professions of a character, primaries first: { { id, rank, max, spec, recipes (known here), total (the owner's
-- count), synced (bool) }, ... }; nil when nothing is known about the character.
function Prof:GetMember(key)
    local rec = type(key) == "string" and GetRec(key)
    if not rec or rec.rev == 0 or not Visible(key) then return nil end
    local out = {}
    for id, e in pairs(rec.p) do
        local set = rec.R[id]
        local known = set and set.e == e.e and set.n or 0
        out[#out + 1] = { id = id, rank = e.r, max = e.m, spec = e.s, recipes = known, total = max(e.n or 0, known),
                          synced = known >= (e.n or 0) }
    end
    tsort(out, function(a, b) return BY_ID[a.id].order < BY_ID[b.id].order end)
    return out
end

-- The character's specs, main first then off spec (nil when nothing is known):
--   { { sp = index into ns.SPECS[class] | nil, tab = 1..3, points = { a, b, c } | nil, bis = true | nil }, ... }
-- My BiS decides when the member picked specs there (bis = true): primary talents can be somebody's off spec. Without
-- it the primary talents are the main spec and the secondary the off spec. points: of the talent set in that tab.
function Prof:GetSpecs(key)
    local rec = type(key) == "string" and GetRec(key)
    if not rec or rec.rev == 0 or not Visible(key) then return nil end
    local sets = {}
    local t = rec.t
    for g = 0, t and (#t - 3) or -1, 3 do
        local a, b, c = t[g + 1], t[g + 2], t[g + 3]
        if a + b + c > 0 then
            sets[#sets + 1] = { tab = (a >= b and a >= c) and 1 or (b >= c and 2 or 3), points = { a, b, c } }
        end
    end
    local Guild = ns.Guild
    local classFile = Guild and Guild:GetClass(key)
    if not classFile and Util.IsMe(key) and UnitClass then classFile = select(2, UnitClass("player")) end
    local specs = ns.SPECS and classFile and ns.SPECS[classFile]
    local function picked(i)
        local spec = specs and i and specs[i]
        if not spec then return nil end
        local out = { sp = i, tab = spec.tab, bis = true }
        for _, set in ipairs(sets) do
            if set.tab == spec.tab then out.points = set.points break end
        end
        return out
    end
    local main = picked(rec.ms) or sets[1]
    if not main then return nil end
    local off = picked(rec.os)
    if off and off.sp == main.sp then off = nil end
    if not off then
        for _, set in ipairs(sets) do
            if set.tab ~= main.tab then off = set break end
        end
    end
    return { main, off }
end

-- The main of the player behind a character: the character itself unless its record names another guild member
-- (who is not somebody's alt in turn).
function Prof:GetMain(key)
    local rec = type(key) == "string" and GetRec(key)
    local main = rec and Visible(key) and rec.a
    if not main or main == key or not Visible(main) then return key end
    local mrec = GetRec(main)
    if mrec and mrec.a and mrec.a ~= main then return key end
    return main
end

-- The other characters of the player behind `key` (alts and main; sorted), without `key` itself.
function Prof:GetOtherCharacters(key)
    local out = {}
    local main = self:GetMain(key)
    for other, rec in pairs(Bucket() or {}) do
        if other ~= key and rec.rev > 0 and Visible(other) and self:GetMain(other) == main then out[#out + 1] = other end
    end
    tsort(out)
    return out
end

-- My account's characters in this guild that DisasterZone knows (they logged in with it), sorted.
function Prof:GetOwnCharacters()
    local out = {}
    for key, rec in pairs(Bucket() or {}) do
        if rec.own and rec.rev > 0 and Visible(key) then out[#out + 1] = key end
    end
    tsort(out)
    return out
end

-- Feedback #5: who is a main decides "Main characters only" prized items, so nobody changes their main while a raid
-- session runs. A council member, an officer or the GM can let one player change it until that raid ends (PMU).
local mainUnlockedFor   -- the raid session (its id) a staff member unlocked my main for

local function RaidSessionId()
    local GR = ns.GroupRules
    local s = GR and GR.GetSession and GR:GetSession()
    return s and (s.id or s.at or true) or nil
end

-- Is my main locked: (locked, why).
function Prof:IsMainLocked()
    local sid = RaidSessionId()
    if not sid or (mainUnlockedFor ~= nil and mainUnlockedFor == sid) then return false end
    return true, "locked while the raid runs"
end

-- May `key` (staff: the GM, an officer or a council member) let a player change their main during a raid?
function Prof:CanUnlockMain(key)
    local Guild = ns.Guild
    if not (Guild and type(key) == "string") then return false end
    return (Guild:IsOfficer(key, true) or Guild:IsCouncil(key, true)) and true or false
end

-- Lets the player at `target` (an online character) change their main until their raid ends. Returns ok, err.
function Prof:UnlockMain(target)
    local me = Util.PlayerKey()
    if ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() then return true end   -- (demo: nothing sent)
    if not (me and self:CanUnlockMain(me)) then return false, "only council members, officers and the GM can" end
    if type(target) ~= "string" or Util.IsMe(target) then return false, "not another player" end
    return Send({ t = "PMU" }, "WHISPER", target), nil
end

local function OnUnlock(sender, msg, dist)
    if dist ~= "WHISPER" or not Prof:CanUnlockMain(sender) then return end
    local sid = RaidSessionId()
    if not sid or mainUnlockedFor == sid then return end
    mainUnlockedFor = sid
    ns:Print("%s lets you change your main character until the raid ends (Guild > Members).", Util.ShortName(sender))
    Changed()
end

-- Makes `mainKey` (one of my characters) the main of all my characters here. An account always has one main and the
-- rest are its alts: there is no "separate characters" any more (feedback #5). Returns ok, err.
function Prof:SetMain(mainKey)
    local b = Bucket()
    if not b then return false, "your professions are not read yet" end
    local locked, why = self:IsMainLocked()
    if locked then return false, why end
    if not (type(mainKey) == "string" and b[mainKey] and b[mainKey].own) then return false, "not one of your characters" end
    if ApplyMain(b, mainKey) then
        Changed()
        lastOwnSend = -1000   -- (a deliberate change: not held back like skill-ups)
        Util.Debounce("prof-own-send", 2, SendOwn)
    end
    return true
end

-- The gear a character wears as last shared: { [sid] = itemID } (empty slots left out), the time it was shared (the
-- record's rev), or nil when they shared none (not logged in with 1.3 or newer since).
function Prof:GetGear(key)
    local rec = GetRec(key)
    if not (rec and rec.g) then return nil end
    local out = {}
    for sid, id in ipairs(rec.g) do
        if id > 0 then out[sid] = id end
    end
    return out, rec.rev
end

function Prof:HasData(key)
    local rec = type(key) == "string" and GetRec(key)
    return (rec and rec.rev > 0 and Visible(key)) and true or false
end

-- Keys of every character with profession data (in my guild; me included).
function Prof:GetMembers()
    local out = {}
    for key, rec in pairs(Bucket() or {}) do
        if rec.rev > 0 and Visible(key) then out[#out + 1] = key end
    end
    tsort(out)
    return out
end

-- { [profId] = number of characters that have it }.
function Prof:GetCounts()
    local out = {}
    for key, rec in pairs(Bucket() or {}) do
        if rec.rev > 0 and Visible(key) then
            for id in pairs(rec.p) do out[id] = (out[id] or 0) + 1 end
        end
    end
    return out
end

-- A recipe's name: its spell's. The client loads spell names on demand, so a name can be missing on the first look
-- (nil then; the client is asked for it and the index is rebuilt when it arrives). A recipe is never left out for it.
local function RecipeName(spell)
    local name = GetSpellInfo and GetSpellInfo(spell)
    if (type(name) ~= "string" or name == "") and C_Spell and C_Spell.GetSpellName then name = C_Spell.GetSpellName(spell) end
    if type(name) == "string" and name ~= "" then return name end
    if not nameRequested[spell] and C_Spell and C_Spell.RequestLoadSpellData then
        nameRequested[spell] = true
        pcall(C_Spell.RequestLoadSpellData, spell)
    end
    return nil
end

local function NamesArrived()
    index = nil
    ns:Fire("PROFESSIONS_UPDATED")
end

local NAME_TRIES = 8

local function BuildIndex()
    local bySpell, byItem, list = {}, {}, {}
    local pending = 0
    for key, rec in pairs(Bucket() or {}) do
        if rec.rev > 0 and Visible(key) then
            for id, set in pairs(rec.R) do
                local e = rec.p[id]
                if e and set.e == e.e then
                    Unpack(set.d, function(spell, item)
                        local r = bySpell[spell]
                        if not r then
                            local name = RecipeName(spell)
                            if not name then
                                pending = pending + 1
                                name = (item > 0 and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(item))
                                    or ("Recipe " .. spell)
                            end
                            r = { spell = spell, item = item, prof = id, name = name, lower = name:lower(), crafters = {} }
                            bySpell[spell] = r
                            list[#list + 1] = r
                        end
                        if r.item == 0 and item > 0 then r.item = item end
                        r.crafters[#r.crafters + 1] = key
                    end)
                end
            end
        end
    end
    for _, r in ipairs(list) do
        if r.item > 0 then
            byItem[r.item] = byItem[r.item] or {}
            local t = byItem[r.item]
            t[#t + 1] = r
        end
    end
    tsort(list, function(a, b)
        if a.lower ~= b.lower then return a.lower < b.lower end
        return a.spell < b.spell
    end)
    index = { bySpell = bySpell, byItem = byItem, list = list, pending = pending }
    if pending > 0 and nameTries < NAME_TRIES then
        nameTries = nameTries + 1
        Util.Debounce("prof-names", 0.4 * nameTries, NamesArrived)
    end
    return index
end

-- Every recipe somebody in the guild knows, sorted by name: { spell, item (0 = none), prof, name, lower,
-- crafters = { key, ... } }. The tables are shared: don't change them.
function Prof:GetRecipes()
    return (index or BuildIndex()).list
end

function Prof:GetRecipe(spell)
    return (index or BuildIndex()).bySpell[spell]
end

-- The recipes that make an item (usually one).
function Prof:GetRecipesForItem(itemID)
    return (index or BuildIndex()).byItem[itemID]
end

-- A character's recipes of one profession, sorted by name (the same shared tables as GetRecipes).
function Prof:GetMemberRecipes(key, id)
    local rec = type(key) == "string" and GetRec(key)
    local set = rec and rec.R[id]
    local e = rec and rec.p[id]
    local out = {}
    if not (set and e and set.e == e.e and Visible(key)) then return out end
    local idx = index or BuildIndex()
    Unpack(set.d, function(spell)
        local r = idx.bySpell[spell]
        if r then out[#out + 1] = r end
    end)
    tsort(out, function(a, b)
        if a.lower ~= b.lower then return a.lower < b.lower end
        return a.spell < b.spell
    end)
    return out
end

function Prof:GetRecipeIcon(r)
    local icon
    if r.item > 0 then
        icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(r.item)) or (GetItemIcon and GetItemIcon(r.item))
    end
    return icon or (GetSpellTexture and GetSpellTexture(r.spell)) or (BY_ID[r.prof] and BY_ID[r.prof].icon)
end

-- A chat link for the recipe, made by the client where it can (a link the client did not make itself may be refused
-- in chat): the item it makes, else the recipe's spell.
function Prof:GetRecipeLink(r)
    local link
    if r.item > 0 and ns.UI and ns.UI.GetItemLink then link = ns.UI:GetItemLink(r.item) end
    if not link and GetSpellLink then link = GetSpellLink(r.spell) end
    if not link and C_Spell and C_Spell.GetSpellLink then link = C_Spell.GetSpellLink(r.spell) end
    return link or ("|cffffd000|Henchant:%d|h[%s]|h|r"):format(r.spell, r.name)
end

-- The group a recipe is listed under: the made item's type ("Consumable", "Armor"), or for an enchant the part
-- before " - " ("Enchant Weapon").
function Prof:GetRecipeGroup(r)
    if r.group then return r.group end
    local group
    if r.item > 0 and C_Item and C_Item.GetItemInfoInstant then
        local _, itemType = C_Item.GetItemInfoInstant(r.item)
        if type(itemType) == "string" and itemType ~= "" then group = itemType end
    end
    if not group then
        group = r.name:match("^(.-) %- ")
    end
    r.group = group or "Other"
    return r.group
end

-- My professions whose recipes were never read (their window was not opened since DisasterZone was installed).
function Prof:GetUnscanned()
    local out = {}
    local rec = OwnRec(false)
    for id, e in pairs(rec and rec.p or {}) do
        if BY_ID[id].crafts and (e.n or 0) == 0 then out[#out + 1] = id end
    end
    tsort(out, function(a, b) return BY_ID[a].order < BY_ID[b].order end)
    return out
end

-- Numbers for the status line / "/dz professions".
function Prof:GetStats()
    local chars, recipes, missing = 0, 0, 0
    for key, rec in pairs(Bucket() or {}) do
        if rec.rev > 0 and Visible(key) then
            chars = chars + 1
            for id in pairs(rec.p) do
                if NeedsRecipes(key, id) then missing = missing + 1 end
            end
        end
    end
    for _ in pairs((index or BuildIndex()).bySpell) do recipes = recipes + 1 end
    return { members = chars, recipes = recipes, missing = missing }
end

-- For tests: the packed form.
Prof._Pack, Prof._Unpack = Pack, Unpack

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function SlashProfessions()
    UpdateOwn()
    local s = Prof:GetStats()
    ns:Print("Professions: %d characters, %d recipes known in the guild%s.", s.members, s.recipes,
        s.missing > 0 and (", " .. s.missing .. " recipe lists still arriving") or "")
    local names = {}
    for _, id in ipairs(Prof:GetUnscanned()) do names[#names + 1] = Prof:GetName(id) end
    if #names > 0 then
        ns:Print("Open your %s window once so the guild can see your recipes.", tconcat(names, " / "))
    end
end

function Prof:OnInit()
    local function scanSkills() Util.Debounce("prof-skills", SCAN_DELAY, UpdateOwn) end
    ns:RegisterEvent("SKILL_LINES_CHANGED", scanSkills)
    ns:RegisterEvent("CHARACTER_POINTS_CHANGED", scanSkills)
    ns:On("MYLIST_CHANGED", scanSkills)   -- (the spec picked in My BiS)
    ns:On("OWNED_UPDATED", scanSkills)    -- (the gear worn: BiS rescans after an equipment change)
    ns:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", scanSkills)
    ns:RegisterEvent("SPELL_DATA_LOAD_RESULT", function(_, spell, ok)
        if ok and nameRequested[spell] and index and index.pending > 0 then
            Util.Debounce("prof-names", 0.3, NamesArrived)
        end
    end)
    ns:RegisterEvent("TRADE_SKILL_SHOW", function() Util.Debounce("prof-trade", 0.5, ScanTradeSkill) end)
    ns:RegisterEvent("TRADE_SKILL_UPDATE", function() Util.Debounce("prof-trade", 0.5, ScanTradeSkill) end)
    ns:RegisterEvent("CRAFT_SHOW", function() Util.Debounce("prof-craft", 0.5, ScanCraft) end)
    ns:RegisterEvent("CRAFT_UPDATE", function() Util.Debounce("prof-craft", 0.5, ScanCraft) end)
    ns:On("GUILD_KEY_READY", function()
        scanSkills()
        ScheduleIndex()
    end)
    ns:On("ROSTER_UPDATED", function(membersChanged)
        index = nil
        if membersChanged then
            Prune()
            ScheduleIndex()
        end
    end)
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("PFB", OnBatch)
        Comm:Register("PFR", OnRecipes)
        Comm:Register("PFI", OnIndex)
        Comm:Register("PFW", OnWant)
        Comm:Register("PMU", OnUnlock)
    end
    ns:RegisterSlash("professions", SlashProfessions, "how many professions and recipes the guild shares")
end

function Prof:OnLogin()
    Util.After(5, UpdateOwn)
    ScheduleIndex()
end

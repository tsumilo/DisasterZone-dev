if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Gems.lua", ...) then return end -- DisasterZone: Core/Gems.lua
-- ns.Gems: gems and enchants on BiS picks. The data (Data/Gems.lua, generated): every TBC item's sockets and socket
-- bonus, every gem (colour, effect, phase, Jewelcrafter only, unique, a meta gem's rule) and enchant (item types, the
-- Enchanting craft or the item that applies it), and per class guide and phase the suggested gems and enchants.
-- The picks live with the list (BiS:GetGemSetup / SetGemSetups, data.ge / data.oge): per item, shared by the phases.
-- Rules the game has: a socket bonus needs every socket filled with a gem of its colour (orange counts as red and
-- yellow, purple red and blue, green yellow and blue, prismatic as all; a meta socket takes only a meta gem), a meta
-- gem is active while the gems worn meet its rule (counted over the phase's main picks), and ring enchants need the
-- wearer's Enchanting (any enchant that names a profession needs it).
-- Gem quality: Suggest can keep to Rare or Uncommon gems (my choice per list, db.gemQuality); the same engine then
-- runs on candidates no better than that, so the strongest gems AT that quality win and the meta still gets its colours.
local addonName, ns = ...

local Gems = ns:NewModule("Gems")

local floor, max = math.floor, math.max
local tsort, tconcat = table.sort, table.concat

local ICON_PATH = "Interface\\Icons\\"
local NUM_SLOTS = 17
local SID_MAINHAND, SID_OFFHAND = 15, 16
local LINK_LEVEL = 70

-- Which socket colours a gem colour counts as.
local COUNTS_AS = {
    R = { R = true }, Y = { Y = true }, B = { B = true },
    O = { R = true, Y = true }, P = { R = true, B = true }, G = { Y = true, B = true },
    X = { R = true, Y = true, B = true },
    M = { M = true },
}
Gems.SOCKET_NAMES = { M = "Meta", R = "Red", Y = "Yellow", B = "Blue" }
Gems.COLORS = {
    M = { 0.78, 0.78, 0.82 }, R = { 0.92, 0.26, 0.22 }, Y = { 0.95, 0.78, 0.18 }, B = { 0.3, 0.55, 0.98 },
    O = { 0.98, 0.55, 0.15 }, P = { 0.68, 0.36, 0.92 }, G = { 0.35, 0.8, 0.3 }, X = { 0.9, 0.9, 0.9 },
}
Gems.EMPTY_SOCKET = {
    M = "Interface\\ItemSocketingFrame\\UI-EmptySocket-Meta", R = "Interface\\ItemSocketingFrame\\UI-EmptySocket-Red",
    Y = "Interface\\ItemSocketingFrame\\UI-EmptySocket-Yellow", B = "Interface\\ItemSocketingFrame\\UI-EmptySocket-Blue",
}

-- Item type numbers of Data/Gems.lua's enchants per equip location.
local ITEM_TYPE = {
    INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_CLOAK = 4, INVTYPE_CHEST = 5, INVTYPE_ROBE = 5,
    INVTYPE_WRIST = 6, INVTYPE_HAND = 7, INVTYPE_WAIST = 8, INVTYPE_LEGS = 9, INVTYPE_FEET = 10, INVTYPE_FINGER = 11,
    INVTYPE_TRINKET = 12, INVTYPE_WEAPON = 13, INVTYPE_2HWEAPON = 13, INVTYPE_WEAPONMAINHAND = 13,
    INVTYPE_WEAPONOFFHAND = 13, INVTYPE_SHIELD = 13, INVTYPE_HOLDABLE = 13, INVTYPE_RANGED = 14,
    INVTYPE_RANGEDRIGHT = 14,
}
local WEAPON_CLASS = 2
local STAFF, BOW, GUN, CROSSBOW = 10, 2, 3, 18

local PIDS = ns.PROFESSION_IDS   -- (the professions with enchants or gems of their own; ids from Constants)
local PROFESSION_IDS = { Enchanting = PIDS.Enchanting, Engineering = PIDS.Engineering,
                         Jewelcrafting = PIDS.Jewelcrafting, Leatherworking = PIDS.Leatherworking,
                         Tailoring = PIDS.Tailoring }

local function Data() return ns.Data or {} end

---------------------------------------------------------------------------
-- Data access
---------------------------------------------------------------------------

local gemCache, enchantCache, socketCache = {}, {}, {}

-- { id, color, quality, phase, text, name, icon, jc, unique, req } of a gem, or nil.
function Gems:Gem(id)
    id = tonumber(id)
    if not id or id == 0 then return nil end
    local g = gemCache[id]
    if g == nil then
        local r = Data().Gems and Data().Gems[id]
        g = false
        if type(r) == "table" then
            g = { id = id, color = r[1], quality = r[2], phase = r[3], text = r[4], name = r[5],
                  icon = r[6] ~= "" and (ICON_PATH .. r[6]) or nil, jc = r.jc, unique = r.u, req = r.req }
        end
        gemCache[id] = g
    end
    return g or nil
end

-- The short name of an enchant ("Major Healing" for "Enchant Gloves - Major Healing").
local function EnchantShort(name)
    return name:match("^Enchant [^-]- %- (.+)$") or name
end

-- { id, types = { [itemType] = true }, name, short, text, icon, craft (spell), item, et, prof } of an enchant, or nil.
function Gems:Enchant(id)
    id = tonumber(id)
    if not id or id == 0 then return nil end
    local e = enchantCache[id]
    if e == nil then
        local r = Data().Enchants and Data().Enchants[id]
        e = false
        if type(r) == "table" then
            local types = { [r[1]] = true }
            for t in tostring(r.x or ""):gmatch("%d+") do types[tonumber(t)] = true end
            e = { id = id, types = types, name = r[2], short = EnchantShort(r[2]), text = r[3],
                  icon = r[4] ~= "" and (ICON_PATH .. r[4]) or nil, craft = r[5] ~= 0 and r[5] or nil,
                  item = r[6] ~= 0 and r[6] or nil, et = r.et, prof = r.prof }
        end
        enchantCache[id] = e
    end
    return e or nil
end

-- The item's sockets { "R", "Y", ... } in order and its socket bonus text (nil when it has none). Empty for an item
-- without sockets.
function Gems:Sockets(itemID)
    itemID = tonumber(itemID)
    if not itemID then return {}, nil end
    local c = socketCache[itemID]
    if c == nil then
        local s = Data().Sockets and Data().Sockets[itemID]
        c = false
        if type(s) == "string" then
            local letters, bonus = s:match("^(%u*)|([^|]*)")
            local list = {}
            for l in (letters or ""):gmatch("%u") do list[#list + 1] = l end
            c = { list = list, bonus = (bonus and bonus ~= "") and bonus or nil }
        end
        socketCache[itemID] = c
    end
    if not c then return {}, nil end
    return c.list, c.bonus
end

function Gems:HasSockets(itemID)
    return #(self:Sockets(itemID)) > 0
end

-- Forgets the cached data (tests swap ns.Data).
local cutIndex   -- [colour .. cut word] = { [quality] = { ids } } (Gems:AtQuality)

function Gems:ClearCache()
    gemCache, enchantCache, socketCache = {}, {}, {}
    cutIndex = nil
end

-- Every gem id (sorted by quality, best first, then name).
function Gems:AllGems()
    local out = {}
    for id in pairs(Data().Gems or {}) do out[#out + 1] = id end
    tsort(out, function(a, b)
        local ga, gb = self:Gem(a), self:Gem(b)
        if ga.quality ~= gb.quality then return ga.quality > gb.quality end
        return ga.name < gb.name
    end)
    return out
end

---------------------------------------------------------------------------
-- Rules
---------------------------------------------------------------------------

-- The gem counts for a socket of that colour (letter).
function Gems:Fits(gemID, socket)
    local g = self:Gem(gemID)
    local as = g and COUNTS_AS[g.color]
    return (as and as[socket]) and true or false
end

-- Every socket holds a gem of its colour.
function Gems:BonusActive(itemID, gems)
    local sockets = self:Sockets(itemID)
    if #sockets == 0 then return false end
    for i, s in ipairs(sockets) do
        local g = gems and gems[i]
        if not g or g == 0 or not self:Fits(g, s) then return false end
    end
    return true
end

-- Adds a gem to colour counts { R, Y, B }.
local function CountGem(counts, g)
    local as = g and COUNTS_AS[g.color]
    if not as or g.color == "M" then return end
    for c in pairs(as) do counts[c] = (counts[c] or 0) + 1 end
end

-- The colour counts { R = n, Y = n, B = n } of the gems on the phase's main picks of a list view.
function Gems:ColorCounts(view, phase)
    local counts = { R = 0, Y = 0, B = 0 }
    local slots = ns.ListPhase and ns.ListPhase(view, phase) or nil
    for _, s in pairs(slots or {}) do
        local main = type(s) == "table" and tonumber(s[1]) or 0
        if main ~= 0 then
            local _, gems = self:GetSetup(view, main)
            for _, id in pairs(gems) do CountGem(counts, self:Gem(id)) end
        end
    end
    return counts
end

local COLOR_WORD = { R = "Red", Y = "Yellow", B = "Blue" }

-- A meta gem's rule against colour counts: active (true / false; true without a rule), and the rule in words
-- ("at least 2 Red, 2 Yellow and 2 Blue gems", "more Blue than Yellow gems"), nil without a rule.
function Gems:MetaState(gemID, counts)
    local g = self:Gem(gemID)
    if not g or not g.req or g.req == "" then return true, nil end
    counts = counts or {}
    local ok, least, more = true, {}, nil
    for rule in g.req:gmatch("[^,]+") do
        local n, c = rule:match("^(%d+)(%u)$")
        if n then
            n = tonumber(n)
            least[#least + 1] = n .. " " .. (COLOR_WORD[c] or c)
            if (counts[c] or 0) < n then ok = false end
        else
            local a, b = rule:match("^(%u)>(%u)$")
            if a then
                more = "more " .. (COLOR_WORD[a] or a) .. " than " .. (COLOR_WORD[b] or b) .. " gems"
                if (counts[a] or 0) <= (counts[b] or 0) then ok = false end
            end
        end
    end
    local words
    if #least > 0 then
        local last = table.remove(least)
        words = "at least " .. (#least > 0 and (tconcat(least, ", ") .. " and ") or "") .. last .. " gems"
    end
    if more then words = words and (words .. ", " .. more) or more end
    return ok, words
end

-- Item info for the enchant rules: equip location, classID, subclassID.
local function EquipInfo(itemID)
    local api = C_Item and C_Item.GetItemInfoInstant
    if not api then return nil end
    local id, _, _, loc, _, classID, subclassID = api(itemID)
    if not id then return nil end
    return loc, tonumber(classID), tonumber(subclassID)
end

-- The professions of a character as a set of names (my own when key is nil or mine).
local function ProfessionSet(key)
    local P = ns.Professions
    local Util = ns.Util
    key = key or (Util and Util.PlayerKey and Util.PlayerKey())
    local set = {}
    local list = P and P.GetMember and key and P:GetMember(key)
    for _, p in ipairs(list or {}) do
        for name, id in pairs(PROFESSION_IDS) do
            if p.id == id then set[name] = true end
        end
    end
    return set
end
Gems.ProfessionSet = function(_, key) return ProfessionSet(key) end

-- The enchant fits the item (its type, two-hand / shield / staff / ranged rules), ignoring professions.
function Gems:EnchantFitsItem(enchantID, itemID)
    local e = self:Enchant(enchantID)
    if not e then return false end
    local loc, classID, subclassID = EquipInfo(itemID)
    local itemType = loc and ITEM_TYPE[loc]
    if not itemType or not e.types[itemType] then return false end
    if itemType == 13 then
        local shield, holdable = loc == "INVTYPE_SHIELD", loc == "INVTYPE_HOLDABLE"
        if holdable then return false end
        if e.et == 2 then return shield end
        if shield then return false end
        if e.et == 1 then return loc == "INVTYPE_2HWEAPON" end
        if e.et == 4 then return classID == WEAPON_CLASS and subclassID == STAFF end
        if e.et == 5 then return loc == "INVTYPE_WEAPONOFFHAND" end
    elseif itemType == 14 then
        return classID == WEAPON_CLASS and (subclassID == BOW or subclassID == GUN or subclassID == CROSSBOW)
    end
    return true
end

-- The enchants for an item, for the wearer with these professions (a set of names; nil = my own): suggested first
-- (`first`, an enchant id), then by name. Rings: only with Enchanting.
function Gems:EnchantsFor(itemID, profs, first)
    profs = profs or ProfessionSet()
    local out = {}
    for id in pairs(Data().Enchants or {}) do
        local e = self:Enchant(id)
        if e and (not e.prof or profs[e.prof]) and self:EnchantFitsItem(id, itemID) then out[#out + 1] = id end
    end
    tsort(out, function(a, b)
        if a == first then return true end
        if b == first then return false end
        local ea, eb = self:Enchant(a), self:Enchant(b)
        if ea.short ~= eb.short then return ea.short < eb.short end
        return a < b
    end)
    return out
end

-- The item can take an enchant (for the wearer with these professions; nil = my own).
function Gems:CanEnchant(itemID, profs)
    profs = profs or ProfessionSet()
    for id in pairs(Data().Enchants or {}) do
        local e = self:Enchant(id)
        if e and (not e.prof or profs[e.prof]) and self:EnchantFitsItem(id, itemID) then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Setups of a list view (data, or ns.ListView(data, "os"))
---------------------------------------------------------------------------

-- enchant (0 = none) and gems { [socket] = id } of an item in a list view (ListData or a ListView; read-only).
function Gems:GetSetup(view, itemID)
    local s = type(view) == "table" and type(view.ge) == "table" and view.ge[tonumber(itemID) or 0] or nil
    local enchant, gems = 0, {}
    if type(s) == "string" then
        local i = 0
        for n in (s .. ":"):gmatch("([^:]*):") do
            if i == 0 then enchant = tonumber(n) or 0 else gems[i] = tonumber(n) or 0 end
            i = i + 1
        end
    end
    return enchant, gems
end

-- The item string with the setup applied (for tooltips): "item:id:enchant:gem1:gem2:gem3:gem4:...".
function Gems:Link(itemID, enchant, gems)
    gems = gems or {}
    local function n(v) v = tonumber(v) or 0; return v ~= 0 and tostring(v) or "" end
    return ("item:%d:%s:%s:%s:%s:%s:::%d"):format(tonumber(itemID) or 0, n(enchant), n(gems[1]), n(gems[2]),
        n(gems[3]), n(gems[4]), LINK_LEVEL)
end

-- The item string of a pick in a list view with its setup, or nil when it has none.
function Gems:LinkFor(view, itemID)
    local enchant, gems = self:GetSetup(view, itemID)
    if enchant == 0 and next(gems) == nil then return nil end
    return self:Link(itemID, enchant, gems)
end

-- What a pick still lacks and has: { sockets = n, filled = n, bonus = bool, enchantable = bool, enchanted = bool }.
function Gems:State(view, itemID, profs)
    local sockets = self:Sockets(itemID)
    local enchant, gems = self:GetSetup(view, itemID)
    local filled = 0
    for i = 1, #sockets do
        if (gems[i] or 0) ~= 0 then filled = filled + 1 end
    end
    return {
        sockets = #sockets, filled = filled, bonus = self:BonusActive(itemID, gems),
        enchantable = self:CanEnchant(itemID, profs), enchanted = enchant ~= 0 and self:Enchant(enchant) ~= nil,
        enchant = enchant, gems = gems,
    }
end

-- The phase's main picks that count (not disabled; the off hand not behind a two-hander): { [sid] = itemID }.
-- isDisabled(sid) optional.
local function CountedPicks(view, phase, isDisabled)
    local slots = ns.ListPhase and ns.ListPhase(view, phase) or nil
    local out = {}
    for sid = 1, NUM_SLOTS do
        local s = slots and slots[sid]
        local main = type(s) == "table" and tonumber(s[1]) or 0
        if main ~= 0 and not (isDisabled and isDisabled(sid)) then out[sid] = main end
    end
    local mh = out[SID_MAINHAND]
    if mh and out[SID_OFFHAND] and ns.ItemDB and ns.ItemDB.GetEquipLoc
        and ns.ItemDB:GetEquipLoc(mh) == "INVTYPE_2HWEAPON" then
        out[SID_OFFHAND] = nil
    end
    return out
end
Gems.CountedPicks = function(_, view, phase, isDisabled) return CountedPicks(view, phase, isDisabled) end

-- How far the phase is gemmed and enchanted: gems placed, sockets, enchants placed, enchantable picks.
function Gems:Progress(view, phase, isDisabled, profs)
    profs = profs or ProfessionSet()
    local placed, sockets, enchanted, enchantable = 0, 0, 0, 0
    for _, itemID in pairs(CountedPicks(view, phase, isDisabled)) do
        local st = self:State(view, itemID, profs)
        placed, sockets = placed + st.filled, sockets + st.sockets
        if st.enchantable then
            enchantable = enchantable + 1
            if st.enchanted then enchanted = enchanted + 1 end
        end
    end
    return placed, sockets, enchanted, enchantable
end

---------------------------------------------------------------------------
-- Suggestions: the WoWSims sims' gems for the spec and phase, ranked by its stat weights
---------------------------------------------------------------------------
-- A socket gets the best (by the spec's weights) of the gems the sims' gear sets use, that fits it; when one gem that
-- doesn't fit is worth more than the fitting ones and the bonus together, the item takes that one in every socket
-- instead ("No bonus"). A unique gem goes in once per set at most, a Jewelcrafter-only gem only for a Jewelcrafter,
-- and a gem only from its phase on. Without the sims' gems (a spec the data lacks): LoonBestInSlot's, then any gem.
-- Enchants: the sims' choice per slot (else the guide's), else the best by the weights that fits the item.

-- The guide of a list view (its class and spec label), or nil.
function Gems:GuideFor(view)
    local Loon = ns.Loon
    if type(view) ~= "table" or not (Loon and Loon.GetGuide) then return nil end
    return Loon:GetGuide(view.cl, view.sp)
end

-- "4:18,5:6" -> { [4] = 18, [5] = 6 }
local function ParseStats(s)
    local out = {}
    for k, v in tostring(s or ""):gmatch("(%d+):([%d.]+)") do out[tonumber(k)] = tonumber(v) end
    return out
end

local statCache = {}
local function StatsOf(kind, id)
    local key = kind .. id
    local s = statCache[key]
    if s == nil then
        local r
        if kind == "g" then r = Data().Gems and Data().Gems[id] elseif kind == "e" then r = Data().Enchants and Data().Enchants[id] end
        if kind == "b" then
            local raw = Data().Sockets and Data().Sockets[id]
            s = ParseStats(type(raw) == "string" and raw:match("^%u*|[^|]*|(.*)$") or "")
        else
            s = ParseStats(type(r) == "table" and r.st or "")
        end
        statCache[key] = s
    end
    return s
end

local function Score(stats, w)
    local n = 0
    for k, v in pairs(stats) do n = n + v * (w[k] or 0) end
    return n
end

-- The guide's suggestions for a phase (0..5; a phase without its own data takes the one before it):
-- { gems = { loon ids }, enchants = { [sid] = id }, meta = id, sim = { ids }, w = { [stat] = weight } }.
function Gems:GuideData(guide, phase)
    local g = guide and Data().GemGuides and Data().GemGuides[guide]
    local p
    for q = tonumber(phase) or 1, 0, -1 do
        p = g and g[q]
        if p then break end
    end
    local out = { gems = {}, enchants = {}, sim = {}, w = ParseStats(p and p.w) }
    if type(p) ~= "table" then return out end
    for id in tostring(p.gems or ""):gmatch("%d+") do
        if self:Gem(tonumber(id)) then out.gems[#out.gems + 1] = tonumber(id) end
    end
    for id in tostring(p.sim or ""):gmatch("%d+") do
        if self:Gem(tonumber(id)) then out.sim[#out.sim + 1] = tonumber(id) end
    end
    for sid, id in tostring(p.enchants or ""):gmatch("(%d+):(%d+)") do
        if self:Enchant(tonumber(id)) then out.enchants[tonumber(sid)] = tonumber(id) end
    end
    out.meta = self:Gem(p.meta) and p.meta or nil
    return out
end

-- (older callers) the guide's gem ids and enchants.
function Gems:GuidePicks(guide, phase)
    local d = self:GuideData(guide, phase)
    return d.gems, d.enchants
end

-- What a gem is worth to the spec (its stats by the weights).
function Gems:GemScore(id, weights)
    return Score(StatsOf("g", tonumber(id) or 0), weights or {})
end

-- A gem may be suggested: from its phase on, a Jewelcrafter-only one for a Jewelcrafter.
local function Allowed(self, g, phase, profs)
    return g and g.phase <= max(1, phase or 1) and (not g.jc or (profs and profs.Jewelcrafting))
end

local qualityCap   -- while set (2 / 3, Gems:WithQuality): no candidate better than that

-- The guide's gems at the quality cap: each one's cut at that quality (or the best below it there is).
local function CappedGuide(self, gd, phase)
    local out = { gems = {}, sim = {}, enchants = gd.enchants, meta = gd.meta, w = gd.w }
    for _, k in ipairs({ "gems", "sim" }) do
        local seen = {}
        for _, id in ipairs(gd[k] or {}) do
            local d = self:AtQuality(id, qualityCap, phase)
            if d and not seen[d] then
                seen[d] = true
                out[k][#out[k] + 1] = d
            end
        end
    end
    return out
end

-- The non-meta gems to suggest from, best first: the sims', else the guide's, else every gem of a usable quality.
-- Under a quality cap: the sims' gems at that quality, and nothing better.
function Gems:Candidates(gd, phase, profs)
    if qualityCap then gd = CappedGuide(self, gd, phase) end
    local out, seen = {}, {}
    local function add(list, uniqueToo)
        for _, id in ipairs(list) do
            local g = self:Gem(id)
            if not seen[id] and g and g.color ~= "M" and Allowed(self, g, phase, profs) and (uniqueToo or not g.unique) then
                seen[id] = true
                out[#out + 1] = id
            end
        end
    end
    add(gd.sim, true)
    if #out == 0 then add(gd.gems, true) end
    -- gems made only of the stats the sims' gems give (a yellow socket for a strength spec gets the strength / crit
    -- topaz even when the sims' sets never needed one; a hit gem the weights love but the sims avoid stays out)
    if #out > 0 then
        local mix, minQ = {}, 9
        for _, id in ipairs(out) do
            for k in pairs(StatsOf("g", id)) do mix[k] = true end
            minQ = math.min(minQ, self:Gem(id).quality)
        end
        local more = {}
        for id, r in pairs(Data().Gems or {}) do
            local st = StatsOf("g", id)
            local inMix = next(st) ~= nil
            for k in pairs(st) do if not mix[k] then inMix = false end end
            if inMix and r[2] >= max(2, minQ) then more[#more + 1] = id end   -- (no cheaper gems than the sims')
        end
        tsort(more)
        add(more, false)
    end
    if #out == 0 or next(gd.w) == nil then
        local all = {}
        for id, r in pairs(Data().Gems or {}) do
            if r[2] >= 2 then all[#all + 1] = id end
        end
        add(all, false)
    end
    if qualityCap then
        local kept = {}
        for _, id in ipairs(out) do
            if self:Gem(id).quality <= qualityCap then kept[#kept + 1] = id end
        end
        out = kept
    end
    local w = gd.w
    tsort(out, function(a, b)
        local sa, sb = self:GemScore(a, w), self:GemScore(b, w)
        if sa ~= sb then return sa > sb end
        return a < b
    end)
    return out
end

-- Best meta gem: the sims', else the guide's first, else none.
local function MetaFor(self, gd, phase, profs)
    for _, id in ipairs({ gd.meta, unpack(gd.gems) }) do
        local g = self:Gem(id)
        if g and g.color == "M" and Allowed(self, g, phase, profs) then return id end
    end
    return nil
end

-- The gems of an item: { [socket] = id }, and whether that set takes the bonus: the combination worth the most to
-- the spec (gems + the bonus when it is on), every combination of the best few candidates per socket tried, a unique
-- gem at most once. used: unique gems already in the set ({ [id] = true }; updated with the ones placed).
local PER_SOCKET = 6
function Gems:BestGems(itemID, gd, phase, profs, used)
    used = used or {}
    local sockets = self:Sockets(itemID)
    local cands = self:Candidates(gd, phase, profs)
    local w = gd.w
    local bonusScore = Score(StatsOf("b", tonumber(itemID) or 0), w)
    -- each socket's options: the best fitting candidates and the best ones overall
    local options = {}
    for i, s in ipairs(sockets) do
        local list = {}
        if s == "M" then
            list[1] = MetaFor(self, gd, phase, profs) or 0
        else
            local fit, any = 0, 0
            for _, id in ipairs(cands) do
                local f = self:Fits(id, s)
                if f and fit < PER_SOCKET then
                    fit = fit + 1
                    list[#list + 1] = id
                elseif not f and any < 3 then
                    any = any + 1
                    list[#list + 1] = id
                end
            end
            if #list == 0 then list[1] = 0 end
        end
        options[i] = list
    end
    local best, bestScore = nil, -1
    local cur, taken = {}, {}
    local function walk(i, total)
        if i > #sockets then
            local score = total
            if self:BonusActive(itemID, cur) then score = score + bonusScore end
            if score > bestScore + 1e-9 then
                bestScore = score
                best = {}
                for k = 1, #cur do best[k] = cur[k] end
            end
            return
        end
        for _, id in ipairs(options[i]) do
            local g = self:Gem(id)
            local unique = g and g.unique
            if not (unique and (used[id] or taken[id])) then
                if unique then taken[id] = true end
                cur[i] = id
                walk(i + 1, total + ((g and sockets[i] ~= "M") and self:GemScore(id, w) or 0))
                if unique then taken[id] = nil end
            end
        end
    end
    walk(1, 0)
    best = best or {}
    for i = 1, #sockets do best[i] = best[i] or 0 end
    for _, id in ipairs(best) do
        local g = self:Gem(id)
        if g and g.unique then used[id] = true end
    end
    return best, self:BonusActive(itemID, best)
end

-- For the editor: the choices for one socket, best first: { { id, best = bool, fits = bool } }. The best is what
-- BestGems puts there; the rest are the candidates that fit (a meta socket: the meta gems), then the best one that
-- doesn't ("No bonus").
function Gems:SocketChoices(itemID, index, gd, phase, profs, used)
    local sockets = self:Sockets(itemID)
    local s = sockets[index]
    local out = {}
    if not s then return out end
    local best = (self:BestGems(itemID, gd, phase, profs, used or {}))[index]
    local seen = {}
    local function add(id, fits)
        if id and id ~= 0 and not seen[id] then
            seen[id] = true
            out[#out + 1] = { id = id, fits = fits, best = (id == best) or nil }
        end
    end
    add(best, self:Fits(best, s))
    if s == "M" then
        add(MetaFor(self, gd, phase, profs), true)
        for _, id in ipairs(gd.gems) do
            if self:Gem(id).color == "M" then add(id, true) end
        end
        return out
    end
    local cands = self:Candidates(gd, phase, profs)
    local firstMiss
    for _, id in ipairs(cands) do
        if self:Fits(id, s) then add(id, true) elseif not firstMiss then firstMiss = id end
    end
    add(firstMiss, false)
    return out
end

-- The enchant for an item in a slot: the sims' / guide's for the slot (or the other hand's), else the best by the
-- weights that fits; 0 when none fits.
function Gems:BestEnchant(itemID, sid, gd, profs)
    profs = profs or ProfessionSet()
    local function ok(id)
        local e = self:Enchant(id)
        return e and self:EnchantFitsItem(id, itemID) and (not e.prof or profs[e.prof])
    end
    local id = gd.enchants[sid]
    if id and ok(id) then return id end
    if sid == SID_OFFHAND or sid == SID_MAINHAND then
        local other = gd.enchants[sid == SID_OFFHAND and SID_MAINHAND or SID_OFFHAND]
        if other and ok(other) then return other end
    end
    local best, bestScore = 0, 0
    if next(gd.w) ~= nil then
        for eid in pairs(Data().Enchants or {}) do
            if ok(eid) then
                local sc = Score(StatsOf("e", eid), gd.w)
                if sc > bestScore then best, bestScore = eid, sc end
            end
        end
    end
    return best
end

-- The unique gems already placed on a phase's picks (except on `exceptItem`): { [id] = true }.
function Gems:UsedUniques(view, phase, exceptItem)
    local used = {}
    for _, itemID in pairs(CountedPicks(view, phase)) do
        if itemID ~= exceptItem then
            local _, gems = self:GetSetup(view, itemID)
            for _, id in pairs(gems) do
                local g = self:Gem(id)
                if g and g.unique then used[id] = true end
            end
        end
    end
    return used
end

-- The suggested setup of an item in a slot: enchant (0 = none fits) and gems { [socket] = id }. used: unique gems
-- the rest of the set already has (updated).
function Gems:Suggest(itemID, sid, guide, phase, profs, used)
    profs = profs or ProfessionSet()
    local gd = self:GuideData(guide, phase)
    local gems = self:BestGems(itemID, gd, phase, profs, used or {})
    return self:BestEnchant(itemID, sid, gd, profs), gems
end

-- How far colour counts fall short of a meta gem's rule (0 = active): the missing gems summed over its rules.
local function MetaShort(self, metaID, counts)
    local g = self:Gem(metaID)
    if not (g and g.req) then return 0 end
    local short = 0
    for rule in g.req:gmatch("[^,]+") do
        local n, c = rule:match("^(%d+)(%u)$")
        if n then
            short = short + max(0, tonumber(n) - (counts[c] or 0))
        else
            local a, b = rule:match("^(%u)>(%u)$")
            if a then short = short + max(0, (counts[b] or 0) - (counts[a] or 0) + 1) end
        end
    end
    return short
end

-- An item's gems worth to the spec: the gems (not the meta) and the socket bonus when it is on.
local function ItemScore(self, itemID, gems, w)
    local sockets = self:Sockets(itemID)
    local n = 0
    for i, s in ipairs(sockets) do
        if s ~= "M" and (gems[i] or 0) ~= 0 then n = n + self:GemScore(gems[i], w) end
    end
    if self:BonusActive(itemID, gems) then n = n + Score(StatsOf("b", itemID), w) end
    return n
end

-- Makes the set's meta gem active: while the phase's gems miss its rule, the cheapest change of one free socket
-- (the least worth lost, socket bonus included, per missing gem it makes up) is made; none when the rule can't be
-- met. setups = { [itemID] = { gems } }
-- (all counted picks), free = { [itemID] = { [socket] = true } } (the sockets being filled). The meta: the one in
-- the set, else the spec's (it counts even when the head is disabled or has no meta socket yet).
function Gems:MeetMetaRule(setups, free, gd, phase, profs)
    local w = gd.w
    local metaID
    for itemID, s in pairs(setups) do
        for _, id in pairs(s.gems) do
            local g = self:Gem(id)
            if g and g.color == "M" then metaID = id end
        end
    end
    metaID = metaID or gd.meta
    if not metaID then return end
    local cands = self:Candidates(gd, phase, profs)
    local function counts()
        local c = { R = 0, Y = 0, B = 0 }
        for _, s in pairs(setups) do
            for _, id in pairs(s.gems) do CountGem(c, self:Gem(id)) end
        end
        return c
    end
    local function uniqueTaken(id)
        for _, s in pairs(setups) do
            for _, x in pairs(s.gems) do if x == id then return true end end
        end
        return false
    end
    -- (half way is worth nothing: when the rule can't be met, every swap is undone)
    local saved = {}
    for itemID, s in pairs(setups) do
        saved[itemID] = {}
        for i, id in pairs(s.gems) do saved[itemID][i] = id end
    end
    local function undo()
        for itemID, s in pairs(setups) do
            for i in pairs(s.gems) do s.gems[i] = saved[itemID][i] end
        end
        return false
    end
    for _ = 1, 24 do
        local c = counts()
        local short = MetaShort(self, metaID, c)
        if short == 0 then return true end
        local best
        for itemID, s in pairs(setups) do
            local sockets = self:Sockets(itemID)
            local before = ItemScore(self, itemID, s.gems, w)
            for i in pairs(free[itemID] or {}) do
                if sockets[i] ~= "M" then
                    local old = s.gems[i] or 0
                    local oldG = self:Gem(old)
                    for _, id in ipairs(cands) do
                        local g = self:Gem(id)
                        if id ~= old and not (g.unique and uniqueTaken(id)) then
                            s.gems[i] = id
                            local nc = { R = c.R, Y = c.Y, B = c.B }
                            local as = oldG and COUNTS_AS[oldG.color]
                            if as and oldG.color ~= "M" then for k in pairs(as) do nc[k] = nc[k] - 1 end end
                            CountGem(nc, g)
                            local gain = short - MetaShort(self, metaID, nc)
                            if gain > 0 then
                                local cost = (before - ItemScore(self, itemID, s.gems, w)) / gain
                                if not best or cost < best.cost - 1e-9 then
                                    best = { cost = cost, itemID = itemID, i = i, id = id }
                                end
                            end
                            s.gems[i] = old
                        end
                    end
                end
            end
        end
        if not best then return undo() end
        setups[best.itemID].gems[best.i] = best.id
    end
    if MetaShort(self, metaID, counts()) == 0 then return true end
    return undo()
end

-- Fills the gems and enchants of a phase's picks of my own list from the suggestions: only sockets and enchants that
-- are still empty (overwrite: every pick's whole setup), with gems of the list's quality (quality: another, 2..4).
-- Returns the number of items changed, false while locked, or nil when the list has no guide.
local FillPhaseNow
function Gems:FillPhase(phase, list, overwrite, quality)
    return self:WithQuality(quality or self:GetQuality(list), FillPhaseNow, self, phase, list, overwrite)
end

function FillPhaseNow(self, phase, list, overwrite)
    local BiS = ns.BiS
    if not BiS then return nil end
    local setups = self:FillSetups(BiS:GetListView(list), phase,
        function(sid) return BiS:IsSlotDisabled(phase, sid, list) end, overwrite)
    if not setups then return nil end
    return BiS:SetGemSetups(setups, list)
end

-- The setups FillPhase stores, for any list view (the BiS list's, the gear I wear: ns.WornGems): { [itemID] =
-- { enchant, gems } } of the phase's counted picks, or nil when the view has no guide. Runs at the quality in force
-- (Gems:WithQuality).
function Gems:FillSetups(view, phase, isDisabled, overwrite)
    local guide = self:GuideFor(view)
    if not guide then return nil end
    local profs = ProfessionSet()
    local picks = CountedPicks(view, phase, isDisabled)
    -- uniques: what is kept counts first
    local used = {}
    if not overwrite then used = self:UsedUniques(view, phase) end
    local setups, free = {}, {}
    for sid = 1, NUM_SLOTS do
        local itemID = picks[sid]
        if itemID and not setups[itemID] then
            local enchant, gems = self:GetSetup(view, itemID)
            local new = { enchant = enchant, gems = {} }
            local n = #self:Sockets(itemID)
            for i = 1, n do new.gems[i] = (not overwrite) and gems[i] or 0 end
            local sEnchant, sGems = self:Suggest(itemID, sid, guide, phase, profs, used)
            if overwrite or enchant == 0 then new.enchant = sEnchant ~= 0 and sEnchant or (overwrite and 0 or enchant) end
            free[itemID] = {}
            for i = 1, n do
                if (new.gems[i] or 0) == 0 then
                    new.gems[i] = sGems[i] or 0
                    free[itemID][i] = true
                end
            end
            setups[itemID] = new
        end
    end
    -- then the set as a whole: enough gems of each colour for the meta gem
    self:MeetMetaRule(setups, free, self:GuideData(guide, phase), phase, profs)
    return setups
end

---------------------------------------------------------------------------
-- Gem quality: Epic, Rare or Uncommon (feedback #4)
---------------------------------------------------------------------------

Gems.QUALITY_WORDS = { [2] = "Uncommon", [3] = "Rare", [4] = "Epic" }

local function CutWord(name) return name and name:match("^(%S+)") end

-- The same cut ("Teardrop", "Bold") in the gem's colour at quality q, else the best quality below q that has it:
-- a plain one (not unique, not Jewelcrafter only) that is out in the phase. The gem itself when it is no better
-- than q, or a meta gem (they come in one quality); nil when the cut has no version that cheap.
function Gems:AtQuality(id, q, phase)
    local g = self:Gem(id)
    q = tonumber(q) or 4
    if not g or g.color == "M" or g.quality <= q then return g and g.id or nil end
    if not cutIndex then
        cutIndex = {}
        for gid in pairs(Data().Gems or {}) do
            local x = self:Gem(gid)
            if x and x.color ~= "M" and not x.unique and not x.jc then
                local key = x.color .. (CutWord(x.name) or "")
                local byQ = cutIndex[key] or {}
                cutIndex[key] = byQ
                byQ[x.quality] = byQ[x.quality] or {}
                local list = byQ[x.quality]
                list[#list + 1] = gid
            end
        end
        for _, byQ in pairs(cutIndex) do
            for _, list in pairs(byQ) do tsort(list) end
        end
    end
    local byQ = cutIndex[g.color .. (CutWord(g.name) or "")]
    if not byQ then return nil end
    for k = q, 2, -1 do
        for _, gid in ipairs(byQ[k] or {}) do
            if self:Gem(gid).phase <= max(1, phase or 1) then return gid end
        end
    end
    return nil
end

-- Runs fn(...) with the suggestions kept to quality q at most (2 Uncommon, 3 Rare; 4 / nil = no limit).
function Gems:WithQuality(q, fn, ...)
    q = tonumber(q)
    if not q or q >= 4 then return fn(...) end
    local was = qualityCap
    qualityCap = q
    local function pack(...) return { n = select("#", ...), ... } end
    local res = pack(pcall(fn, ...))
    qualityCap = was
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2, res.n)
end

-- Some gem of quality q (no meta) is out in the phase.
function Gems:QualityOut(q, phase)
    for id in pairs(Data().Gems or {}) do
        local g = self:Gem(id)
        if g.quality == q and g.color ~= "M" and g.phase <= max(1, phase or 1) then return true end
    end
    return false
end

local function QualitySlot(list)
    local key = ns.loggedIn and ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey()
    local db = ns.db
    if not (key and db) then return nil, nil end
    if type(db.gemQuality) ~= "table" then db.gemQuality = {} end
    return db.gemQuality, key .. (list == "os" and ":os" or "")
end

-- The quality Suggest's gems keep to for my list (4 Epic = no limit, 3 Rare, 2 Uncommon).
function Gems:GetQuality(list)
    local t, key = QualitySlot(list)
    local q = t and tonumber(t[key])
    return (q == 2 or q == 3) and q or 4
end

function Gems:SetQuality(q, list)
    local t, key = QualitySlot(list)
    if not t then return end
    q = tonumber(q)
    t[key] = (q == 2 or q == 3) and q or nil
end

---------------------------------------------------------------------------
-- Sources (what the shopping list and the editor say)
---------------------------------------------------------------------------

-- The enchant number item links carry for a number another site uses: an enchant id itself, the Enchanting craft's
-- spell, or the item that applies it (a glyph, an inscription, a spellthread, an armor kit). nil when unknown.
local bySpell, byItem
function Gems:EnchantFromAny(n)
    n = tonumber(n)
    if not n or n <= 0 then return nil end
    local data = Data().Enchants or {}
    if data[n] then return n end
    if not bySpell then
        bySpell, byItem = {}, {}
        for id, r in pairs(data) do
            if r[5] ~= 0 then bySpell[r[5]] = id end
            if r[6] ~= 0 then byItem[r[6]] = id end
        end
    end
    return bySpell[n] or byItem[n]
end

-- What to make / buy for an enchant: the Atlas craft (-spell) or the item that applies it; nil when neither.
function Gems:EnchantShopID(enchantID)
    local e = self:Enchant(enchantID)
    if not e then return nil end
    if e.craft then return -e.craft end
    return e.item
end

-- What the phase still takes, for the shopping list: { [id] = count } of crafts the shopping list can hold - the
-- crafted picks I don't have yet, and the chosen gems (Jewelcrafting) and enchants (-spell of an Enchanting craft, a
-- crafted spellthread / kit), leaving out what the item I wear already has (the same gem in that socket, the same
-- enchant). Second result: how many chosen gems / enchants no craft makes (drops, reputation glyphs).
function Gems:ShoppingNeeds(phase, list)
    local BiS = ns.BiS
    if not BiS then return {}, 0 end
    return self:ShoppingNeedsOf(BiS:GetListView(list), phase,
        function(sid) return BiS:IsSlotDisabled(phase, sid, list) end)
end

-- ShoppingNeeds for any list view; isDisabled(sid) optional; noItems: only the gems and enchants (the gear I wear:
-- ns.WornGems).
function Gems:ShoppingNeedsOf(view, phase, isDisabled, noItems)
    local BiS, Shop, Exp = ns.BiS, ns.Shop, ns.BiSExport
    local out, other = {}, 0
    if not (BiS and Shop) then return out, 0 end
    local worn = Exp and Exp.EquippedSpecs and Exp:EquippedSpecs() or {}
    local wornById = {}
    for _, s in pairs(worn) do if s and s.id then wornById[s.id] = s end end
    local function need(id)
        if id and Shop:CanAdd(id) then
            out[id] = (out[id] or 0) + 1
        else
            other = other + 1
        end
    end
    for _, itemID in pairs(CountedPicks(view, phase, isDisabled)) do
        if not noItems and Shop:CanAdd(itemID) and not (BiS.IsObtained and BiS:IsObtained(itemID)) then
            out[itemID] = (out[itemID] or 0) + 1
        end
        local enchant, gems = self:GetSetup(view, itemID)
        local w = wornById[itemID]
        for i, g in pairs(gems) do
            if g ~= 0 and not (w and w.gems and w.gems[i] == g) then need(g) end
        end
        if enchant ~= 0 and not (w and w.enchant == enchant) then need(self:EnchantShopID(enchant)) end
    end
    return out, other
end

-- Puts ShoppingNeeds on my shopping list. Returns how many were added (crafts x count) and how many no craft makes.
function Gems:AddToShoppingList(phase, list)
    local needs, other = self:ShoppingNeeds(phase, list)
    local n = 0
    for id, count in pairs(needs) do
        if ns.Shop:Add(id, count) then n = n + count end
    end
    return n, other
end

-- Short words for where a gem or enchant comes from ("Jewelcrafting", "Enchanting", "Glyph", ...).
function Gems:SourceWords(kind, id)
    if kind == "gem" then
        local g = self:Gem(id)
        if not g then return nil end
        local Atlas = ns.Atlas
        if Atlas and Atlas.GetCraft and Atlas:GetCraft(id) then return "Jewelcrafting" end
        if g.color == "M" then return "Meta gem" end
        return nil
    end
    local e = self:Enchant(id)
    if not e then return nil end
    if e.craft then return "Enchanting" end
    if e.prof then return e.prof .. " only" end
    return nil
end

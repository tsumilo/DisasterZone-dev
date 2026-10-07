if DisasterZoneBoot and DisasterZoneBoot.Run("Core/ShoppingList.lua", ...) then return end -- DisasterZone: Core/ShoppingList.lua
-- ns.Shop: the shopping list in the Atlas (UI/AtlasShop.lua). Per character and never synced (the bag and bank counts
-- are the character's own): crafts with how many to make and how far their materials are broken down
-- (Atlas:GetMaterials). Grouped by who can make them: my own characters first, then the guild member who can make the
-- most of what is left (reachable now before not), then what nobody in the guild knows, then crafts that bind when
-- picked up and none of my characters can make. The materials add up with what my bags and bank hold; with
-- Auctionator installed, what the missing ones cost.
-- An entry: { id = an item a craft makes, or -spellID of a craft that makes none (an enchant), n = how many, d = how
-- many steps its materials are broken down, x = true: its materials are left out of the list's / false: a bind on
-- pickup craft's are counted anyway (nil: the default, counted unless bind on pickup) }. Saved in db.shopping[charKey] (created on the first add).
local addonName, ns = ...

local Shop = ns:NewModule("Shop")

local Util = ns.Util
local type, ipairs, pairs, tonumber, select = type, ipairs, pairs, tonumber, select
local floor, min, max, ceil = math.floor, math.min, math.max, math.ceil
local tconcat, tsort = table.concat, table.sort

local MAX_AMOUNT = 999
local MAX_ENTRIES = 100
local CHAT_MAX = 255
local CALLER = "DisasterZone"   -- the Auctionator API's caller id
local BIND_ON_PICKUP = 1        -- GetItemInfo's bindType

Shop.MAX_AMOUNT = MAX_AMOUNT

local function Atlas() return ns.Atlas end
local function P() return ns.Professions end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

-- My saved list; nil until something is added (reading never creates saved tables).
local function List(create)
    local db = ns.db
    local me = Util and Util.PlayerKey and Util.PlayerKey()
    if type(db) ~= "table" or not me then return nil end
    if type(db.shopping) ~= "table" then
        if not create then return nil end
        db.shopping = {}
    end
    local list = db.shopping[me]
    if type(list) ~= "table" then
        if not create then return nil end
        list = {}
        db.shopping[me] = list
    end
    return list
end

local function Valid(e)
    return type(e) == "table" and type(e.id) == "number" and e.id ~= 0 and e.id == floor(e.id)
end

local function Amount(v)
    return max(1, min(MAX_AMOUNT, floor(tonumber(v) or 1)))
end

local function Depth(v)
    return max(0, min(9, floor(tonumber(v) or 0)))
end

local function Changed()
    ns:Fire("SHOP_UPDATED")
end

-- The id a craft is listed under: the item it makes, else -spellID (a recipe / pattern gives what it teaches).
local function ListId(id)
    local craft = Atlas() and Atlas():GetCraft(id)
    if not craft then return nil end
    if id < 0 then return id end
    return craft.item > 0 and craft.item or -craft.spell
end

-- My list, oldest first: { { id, n, d }, ... } (copies).
function Shop:GetEntries()
    local out = {}
    for _, e in ipairs(List() or {}) do
        if Valid(e) then
            local x = e.x   -- (only true / false mean something; "and e.x or nil" would turn false into nil)
            if type(x) ~= "boolean" then x = nil end
            out[#out + 1] = { id = e.id, n = Amount(e.n), d = Depth(e.d), x = x }
        end
    end
    return out
end

function Shop:Count()
    return #self:GetEntries()
end

-- How many of id are on my list (nil when it isn't).
function Shop:GetAmount(id)
    id = tonumber(id)
    for _, e in ipairs(List() or {}) do
        if Valid(e) and e.id == id then return Amount(e.n) end
    end
    return nil
end

local function Find(id)
    local list = List()
    for i, e in ipairs(list or {}) do
        if Valid(e) and e.id == id then return e, i, list end
    end
    return nil
end

-- Can id go on the list (a craft makes it)?
function Shop:CanAdd(id)
    id = tonumber(id)
    return id ~= nil and id ~= 0 and ListId(id) ~= nil
end

-- Puts a craft on my list, or n more of it (default 1); depth: how far its materials are broken down (nil keeps what
-- the entry had). Returns true, or false and why.
function Shop:Add(id, n, depth)
    id = tonumber(id)
    id = id and id ~= 0 and ListId(id)
    if not id then return false, "nothing makes that" end
    local e = Find(id)
    if e then
        e.n = min(MAX_AMOUNT, Amount(e.n) + Amount(n))
        if depth ~= nil then e.d = Depth(depth) end
        Changed()
        return true
    end
    local list = List(true)
    if not list then return false, "your character isn't loaded yet" end
    if #list >= MAX_ENTRIES then return false, "the list is full" end
    list[#list + 1] = { id = id, n = Amount(n), d = Depth(depth) }
    Changed()
    return true
end

-- Sets how many to make; 0 or less takes it off the list.
function Shop:SetAmount(id, n)
    local e = Find(tonumber(id))
    if not e then return false end
    if (tonumber(n) or 0) <= 0 then return self:Remove(id) end
    e.n = Amount(n)
    Changed()
    return true
end

-- Sets how many steps an entry's materials are broken down.
function Shop:SetDepth(id, depth)
    local e = Find(tonumber(id))
    if not e then return false end
    e.d = Depth(depth)
    Changed()
    return true
end

-- Do an entry's materials count (bop: it is in the bind on pickup group)? By default all but bind on pickup crafts.
function Shop:IsCounted(e, bop)
    if e.x ~= nil then return not e.x end
    return not bop
end

-- Counts an entry's materials or leaves them out (only what differs from the default is saved).
function Shop:SetCounted(id, on, bop)
    local e = Find(tonumber(id))
    if not e then return false end
    on = on and true or false
    if on == (not bop) then e.x = nil else e.x = not on end
    Changed()
    return true
end

function Shop:Remove(id)
    local e, i, list = Find(tonumber(id))
    if not e then return false end
    table.remove(list, i)
    Changed()
    return true
end

function Shop:Clear()
    local list = List()
    if not list or #list == 0 then return false end
    for i = #list, 1, -1 do list[i] = nil end
    Changed()
    return true
end

-- How many steps an entry's materials can be broken down at most (0: they can't).
function Shop:GetMaxDepth(id)
    local A = Atlas()
    if not A then return 0 end
    local _, level = A:GetMaterials(id, 1, 99)
    return level or 0
end

---------------------------------------------------------------------------
-- Who makes what
---------------------------------------------------------------------------

-- The guild members who know a craft making id: a set { [key] = true }.
local function CraftersOf(id)
    local out = {}
    local Prof = P()
    if not Prof then return out end
    if id < 0 then
        local r = Prof:GetRecipe(-id)
        for _, k in ipairs(r and r.crafters or {}) do out[k] = true end
    else
        for _, r in ipairs(Prof:GetRecipesForItem(id) or {}) do
            for _, k in ipairs(r.crafters or {}) do out[k] = true end
        end
    end
    return out
end

-- The profession of the craft that makes id (nil when nobody in the guild knows it).
local function ProfOf(id)
    local Prof = P()
    local r = Prof and (id < 0 and Prof:GetRecipe(-id) or (Prof:GetRecipesForItem(id) or {})[1])
    return r and r.prof
end

local function BindsOnPickup(id)
    if id < 0 or not (C_Item and C_Item.GetItemInfo) then return false end
    return select(14, C_Item.GetItemInfo(id)) == BIND_ON_PICKUP
end

-- The character to whisper for a member now: the member, or another character of the same player who is online.
local function Reachable(key)
    local G = ns.Guild
    if not (G and G.IsOnline) then return nil end
    if G:IsOnline(key) then return key end
    for _, other in ipairs(P() and P():GetOtherCharacters(key) or {}) do
        if G:IsOnline(other) then return other end
    end
    return nil
end

local function Profs(entries)
    local out, seen = {}, {}
    for _, e in ipairs(entries) do
        local p = ProfOf(e.id)
        if p and not seen[p] then
            seen[p] = true
            out[#out + 1] = p
        end
    end
    return out
end

-- Does the item bind when picked up (nobody else can make it for me)? False while the client doesn't know yet.
function Shop:IsBindOnPickup(id)
    return BindsOnPickup(tonumber(id) or 0)
end

-- The profession of the craft that makes id, as the guild knows it (nil when nobody in the guild does).
function Shop:GetProfession(id)
    return ProfOf(tonumber(id) or 0)
end

-- The guild members who know the craft of id, sorted reachable first then by name (my own characters left out).
function Shop:GetCrafters(id)
    local own = {}
    for _, k in ipairs(P() and P():GetOwnCharacters() or {}) do own[k] = true end
    local out = {}
    for k in pairs(CraftersOf(tonumber(id) or 0)) do
        if not own[k] and not Util.IsMe(k) then out[#out + 1] = { key = k, reach = Reachable(k) } end
    end
    tsort(out, function(a, b)
        if (a.reach ~= nil) ~= (b.reach ~= nil) then return a.reach ~= nil end
        return a.key < b.key
    end)
    return out
end

-- Can one of my own characters make id?
function Shop:CanMake(id)
    local set = CraftersOf(tonumber(id) or 0)
    if Util.IsMe and set[Util.PlayerKey()] then return true end
    for _, k in ipairs(P() and P():GetOwnCharacters() or {}) do
        if set[k] then return true end
    end
    return false
end

-- My list by who makes it, in the order shown: { { kind = "you" | "member" | "nobody" | "bop", key = (member),
-- reach = the character to whisper now (member; nil when offline), entries = { entry, ... }, profs = { profession
-- id, ... } }, ... }. The member who can make the most of what is left comes next (reachable before not, then by
-- name); a craft that binds when picked up goes to "bop" unless I can make it myself.
function Shop:GetGroups(entries)
    entries = entries or self:GetEntries()
    local own = {}
    for _, k in ipairs(P() and P():GetOwnCharacters() or {}) do own[k] = true end
    local me = Util.PlayerKey()
    if me then own[me] = true end
    local you, bop, rest, others = {}, {}, {}, {}
    for _, e in ipairs(entries) do
        local set = CraftersOf(e.id)
        local mine = false
        for k in pairs(set) do
            if own[k] then mine = true end
        end
        if mine then
            you[#you + 1] = e
        elseif BindsOnPickup(e.id) then
            bop[#bop + 1] = e
        else
            local o = {}
            for k in pairs(set) do o[k] = true end
            others[e] = o
            rest[#rest + 1] = e
        end
    end
    local groups = {}
    if #you > 0 then groups[#groups + 1] = { kind = "you", key = me, entries = you, profs = Profs(you) } end
    local reach = {}
    local function reachOf(k)
        if reach[k] == nil then reach[k] = Reachable(k) or false end
        return reach[k] or nil
    end
    local function better(k, n, best, bn)
        if n ~= bn then return n > bn end
        local a, b = reachOf(k) ~= nil, reachOf(best) ~= nil
        if a ~= b then return a end
        return k < best
    end
    while #rest > 0 do
        local count = {}
        for _, e in ipairs(rest) do
            for k in pairs(others[e]) do count[k] = (count[k] or 0) + 1 end
        end
        local best
        for k, n in pairs(count) do
            if not best or better(k, n, best, count[best]) then best = k end
        end
        if not best then break end
        local g = { kind = "member", key = best, reach = reachOf(best), entries = {} }
        local left = {}
        for _, e in ipairs(rest) do
            if others[e][best] then g.entries[#g.entries + 1] = e else left[#left + 1] = e end
        end
        g.profs = Profs(g.entries)
        groups[#groups + 1] = g
        rest = left
    end
    if #rest > 0 then groups[#groups + 1] = { kind = "nobody", entries = rest, profs = {} } end
    if #bop > 0 then groups[#groups + 1] = { kind = "bop", entries = bop, profs = Profs(bop) } end
    return groups
end

-- "Tailoring 375" for a member's professions among profs (the skill they have), joined.
function Shop:SkillText(key, profs)
    local Prof = P()
    local member = Prof and key and Prof:GetMember(key)
    local parts = {}
    for _, id in ipairs(profs or {}) do
        local name = Prof and Prof:GetName(id)
        local rank
        for _, p in ipairs(member or {}) do
            if p.id == id then rank = p.rank end
        end
        if name then parts[#parts + 1] = rank and (name .. " " .. rank) or name end
    end
    return tconcat(parts, " · ")
end

---------------------------------------------------------------------------
-- Materials
---------------------------------------------------------------------------

local function HaveCount(id)
    local count = GetItemCount or (C_Item and C_Item.GetItemCount)
    return tonumber(count and count(id, true)) or 0   -- bags and bank
end

-- The materials of entries (each at its amount and breakdown), added up: { { id, need, have, name }, ... }, the
-- missing ones first, then the ones my bags and bank hold enough of; each part by name.
function Shop:GetMaterials(entries)
    local A = Atlas()
    local need, order = {}, {}
    for _, e in ipairs(entries or self:GetEntries()) do
        for _, m in ipairs(A and A:GetMaterials(e.id, e.n, e.d) or {}) do
            if not need[m.id] then
                need[m.id] = 0
                order[#order + 1] = m.id
            end
            need[m.id] = need[m.id] + m.count
        end
    end
    local rows = {}
    for _, id in ipairs(order) do
        rows[#rows + 1] = { id = id, need = need[id], have = HaveCount(id), name = (A and A:GetName(id)) or "" }
    end
    tsort(rows, function(a, b)
        local da, db = a.have >= a.need, b.have >= b.need
        if da ~= db then return db end
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    return rows
end

-- What the missing materials cost at the auction house by Auctionator's last scan: copper, and how many missing
-- materials it has no price for. nil when Auctionator isn't there.
function Shop:GetCost(rows)
    local api = _G.Auctionator and _G.Auctionator.API and _G.Auctionator.API.v1
    local get = api and api.GetAuctionPriceByItemID
    if type(get) ~= "function" then return nil end
    local total, unpriced = 0, 0
    for _, r in ipairs(rows or {}) do
        local missing = r.need - r.have
        if missing > 0 then
            local ok, price = pcall(get, CALLER, r.id)
            price = ok and tonumber(price) or nil
            if price and price > 0 then total = total + missing * price else unpriced = unpriced + 1 end
        end
    end
    return total, unpriced
end

-- The entries of my list whose materials count (Shop:IsCounted): of all groups, or of the given ones.
function Shop:GetMaterialEntries(groups)
    local out = {}
    for _, g in ipairs(groups or self:GetGroups()) do
        for _, e in ipairs(g.entries) do
            if self:IsCounted(e, g.kind == "bop") then out[#out + 1] = e end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Whisper
---------------------------------------------------------------------------

local function Link(id)
    if id > 0 then
        local link = ns.UI and ns.UI.GetItemLink and ns.UI:GetItemLink(id)
        return link or (Atlas() and Atlas():GetName(id))
    end
    local link = (GetSpellLink and GetSpellLink(-id)) or (C_Spell and C_Spell.GetSpellLink and C_Spell.GetSpellLink(-id))
    return link or (Atlas() and Atlas():GetName(id))
end

local function JoinAnd(parts)
    if #parts <= 1 then return parts[1] or "" end
    return tconcat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
end

-- The whisper asking a group's crafter for its crafts: "Could you make [A], 2x [B] and [C] for me? I'll bring the
-- materials." ("I have the materials." once my bags and bank hold them all). As many links as the line has room for,
-- the rest as "N more".
function Shop:WhisperText(group)
    local parts = {}
    for _, e in ipairs(group and group.entries or {}) do
        local l = Link(e.id)
        if l then parts[#parts + 1] = (e.n > 1 and (e.n .. "x ") or "") .. l end
    end
    if #parts == 0 then return nil end
    local done = true
    for _, r in ipairs(self:GetMaterials(group.entries)) do
        if r.have < r.need then done = false end
    end
    local tail = " for me? " .. (done and "I have the materials." or "I'll bring the materials.")
    local shown = #parts
    while true do
        local list = {}
        for i = 1, shown do list[i] = parts[i] end
        if shown < #parts then list[#list + 1] = (#parts - shown) .. " more" end
        local text = "Could you make " .. JoinAnd(list) .. tail
        if #text <= CHAT_MAX - 30 or shown <= 1 then return text end
        shown = shown - 1
    end
end

-- Opens a whisper to a group's crafter (the character online now) with WhisperText typed in (not sent).
function Shop:Whisper(group)
    local to = group and (group.reach or group.key)
    local text = self:WhisperText(group)
    if not (to and text) then return false end
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if not open then return false end
    local name = (Ambiguate and Ambiguate(to, "none")) or Util.ShortName(to) or to
    open("/w " .. name .. " " .. text)
    return true
end

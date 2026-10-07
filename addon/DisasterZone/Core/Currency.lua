if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Currency.lua", ...) then return end -- DisasterZone: Core/Currency.lua
-- ns.Currency: what an item costs at its vendor and what I hold to pay for it (the Atlas tab's costs and its currency
-- bar). A cost is a string "key:amount,key:amount": key "c<currencyID>" = a currency (c1901 Honor Points, c1900 Arena
-- Points: C_CurrencyInfo), "g" = money in copper, a number = an item that pays (29434 Badge of Justice, marks, tokens).
-- Where a cost comes from, the first found:
--   1. what a vendor asked me: every vendor I open is read (MERCHANT_SHOW) and its prices kept in db.prices, account
--      wide and never synced; PvP prices change with the arena seasons, so the vendor is the only sure source;
--   2. AtlasLoot's own vendor scans, when it is installed (AtlasLoot.dbGlobal.VendorPrice);
--   3. the shipped table (ns.Data.AtlasCosts: the author's realm scans, AtlasLoot's price tables);
--   4. an arena / honor piece of ARMOR nobody priced yet: the price every priced piece of that season and slot has
--      (vendors list only my class's pieces, and a season's armor costs the same for every class). Weapons never: a
--      wand and a crossbow share a slot and not a price.
local addonName, ns = ...

local Currency = ns:NewModule("Currency")

local type, ipairs, pairs, tonumber, tostring = type, ipairs, pairs, tonumber, tostring
local floor = math.floor
local tconcat = table.concat

local HONOR, ARENA, BADGE, MONEY = "c1901", "c1900", "29434", "g"
Currency.HONOR, Currency.ARENA, Currency.BADGE, Currency.MONEY = HONOR, ARENA, BADGE, MONEY
-- always on the currency bar, in this order
Currency.PINNED = { HONOR, ARENA, BADGE }

local HONOR_TEXTURES = { [136998] = true, [137000] = true }   -- Alliance / Horde (Blizzard's HONOR_POINT_TEXTURES)
local HONOR_COORDS = { 0, 40 / 64, 0, 40 / 64 }                -- the honor icons fill only that much of their file
local ARENA_TEXTURE = "Interface\\PVPFrame\\PVP-ArenaPoints-Icon"
local GOLD_TEXTURE = "Interface\\MoneyFrame\\UI-GoldIcon"
-- names before the client has the item cached (English: the game's own names replace them once it has)
local FALLBACK_NAMES = {
    [HONOR] = "Honor Points", [ARENA] = "Arena Points", [MONEY] = "Gold", [BADGE] = "Badge of Justice",
    ["20560"] = "Alterac Valley Mark of Honor", ["20558"] = "Warsong Gulch Mark of Honor",
    ["20559"] = "Arathi Basin Mark of Honor", ["29024"] = "Eye of the Storm Mark of Honor",
    ["26044"] = "Halaa Research Token", ["26045"] = "Halaa Battle Token", ["24581"] = "Mark of Thrallmar",
    ["24579"] = "Mark of Honor Hold", ["28558"] = "Spirit Shard", ["29735"] = "Holy Dust", ["29736"] = "Arcane Rune",
    ["24245"] = "Glowcap", ["32572"] = "Apexis Crystal", ["32569"] = "Apexis Shard", ["37829"] = "Brewfest Prize Token",
    ["34664"] = "Sunmote", ["23247"] = "Burning Blossom", ["21100"] = "Coin of Ancestry", ["22484"] = "Necrotic Rune",
}
local CLASS_ARMOR = 4                                          -- Enum.ItemClass.Armor
-- the Atlas sources whose armor costs the same for every class (a season, the honor and PvP reputation gear); the
-- PvP and Sets categories share these keys (a season's set pieces and its other pieces)
local SEASON_SOURCES = { ArenaS1 = true, ArenaS2 = true, ArenaS3 = true, ArenaS4 = true, Honor = true, RepPvP = true }
local SEASON_CATS = { pvp = true, sets = true }

-- AtlasLoot's price keys -> cost keys (its VendorPrice.lua PRICE_INFO_LIST; the same map as gen_atlas.py COST_KEYS)
local ATLASLOOT_KEYS = {
    money = MONEY, honor = HONOR, honorA = HONOR, honorH = HONOR, arena = ARENA,
    BoJ = BADGE, pvpAlterac = "20560", pvpWarsong = "20558", pvpArathi = "20559", pvpEye = "29024",
    HalaaRT = "26044", HalaaBT = "26045", MarkOfThrallmar = "24581", MarkOfHonorHold = "24579", SpiritShard = "28558",
    holydust = "29735", arcanerune = "29736", glowcap = "24245", ApexisC = "32572", ApexisS = "32569",
    Brewfest = "37829", sunmote = "34664", burningblossom = "23247", ancestrycoin = "21100", NecroticRune = "22484",
}

local parsed = {}      -- [cost string] = parts (shared: callers never modify them)
local alCache = {}     -- [itemID] = cost string converted from AtlasLoot's scan, or false
local season           -- [source key] = { [equipLoc] = cost string, or false when its priced pieces disagree }

local function Data() return ns.Data or {} end

---------------------------------------------------------------------------
-- Cost strings
---------------------------------------------------------------------------

-- "c1901:22950,29024:10" -> { { key = "c1901", n = 22950 }, { key = "29024", n = 10 } } (nil when malformed).
function Currency:Parse(s)
    if type(s) ~= "string" or s == "" then return nil end
    local p = parsed[s]
    if p ~= nil then return p or nil end
    p = {}
    for part in s:gmatch("[^,]+") do
        local key, n = part:match("^(%w+):(%d+)$")
        n = tonumber(n)
        if not key or not n or n <= 0 or not (key == MONEY or key:match("^c%d+$") or key:match("^%d+$")) then
            p = false
            break
        end
        p[#p + 1] = { key = key, n = n }
    end
    if p and #p == 0 then p = false end
    parsed[s] = p
    return p or nil
end

local function ValidCost(s)
    return Currency:Parse(s) ~= nil
end

-- AtlasLoot's "honor:12695:pvpAlterac:5" -> "c1901:12695,20560:5" (nil when a key is unknown).
function Currency:FromAtlasLoot(s)
    if type(s) ~= "string" then return nil end
    local out, words = {}, {}
    for w in s:gmatch("[^:]+") do words[#words + 1] = w end
    if #words == 0 or #words % 2 == 1 then return nil end
    for i = 1, #words, 2 do
        local key, n = ATLASLOOT_KEYS[words[i]], tonumber(words[i + 1])
        if not key or not n or n <= 0 then return nil end
        out[#out + 1] = key .. ":" .. floor(n)
    end
    return tconcat(out, ",")
end

---------------------------------------------------------------------------
-- Where a cost comes from
---------------------------------------------------------------------------

-- What a vendor asked me for an item: cost string, time seen (or nil).
local function Learned(id)
    local t = ns.db and ns.db.prices
    local v = type(t) == "table" and t[id]
    if type(v) ~= "string" then return nil end
    local cost, at = v:match("^([^|]+)|?(%d*)$")
    if not ValidCost(cost) then return nil end
    return cost, tonumber(at)
end

local function FromAtlasLoot(id)
    local v = alCache[id]
    if v ~= nil then return v or nil end
    local AL = _G.AtlasLoot
    local t = type(AL) == "table" and type(AL.dbGlobal) == "table" and AL.dbGlobal.VendorPrice
    local raw = type(t) == "table" and t[id]
    v = raw and Currency:FromAtlasLoot(raw)
    if v and not ValidCost(v) then v = nil end
    alCache[id] = v or false
    return v
end

local function Shipped(id)
    local t = Data().AtlasCosts
    local v = type(t) == "table" and t[id]
    return ValidCost(v) and v or nil
end

-- A cost from the first three sources: cost string, source ("vendor" | "atlasloot" | "shipped").
local function Direct(id)
    local v = Learned(id)
    if v then return v, "vendor" end
    v = FromAtlasLoot(id)
    if v then return v, "atlasloot" end
    v = Shipped(id)
    if v then return v, "shipped" end
    return nil
end

local function ArmorSlot(id)
    if not (C_Item and C_Item.GetItemInfoInstant) then return nil end
    local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(id)
    if classID ~= CLASS_ARMOR or type(equipLoc) ~= "string" or equipLoc == "" then return nil end
    if equipLoc == "INVTYPE_ROBE" then equipLoc = "INVTYPE_CHEST" end
    return equipLoc
end

-- [source key][equipLoc] = the one price its priced armor pieces share (false: they disagree).
local function SeasonIndex()
    if season then return season end
    season = {}
    local A = ns.Atlas
    for _, cat in ipairs((A and A.GetCategories and A:GetCategories()) or {}) do
        if SEASON_CATS[cat.key] then
            for _, src in ipairs(cat.sources or {}) do
                if SEASON_SOURCES[src.key] then
                    local slots = season[src.key] or {}
                    season[src.key] = slots
                    for _, page in ipairs(src.pages or {}) do
                        for _, id in ipairs(page.items or {}) do
                            local cost = type(id) == "number" and id > 0 and Direct(id)
                            local slot = cost and ArmorSlot(id)
                            if slot then
                                local had = slots[slot]
                                if had == nil then
                                    slots[slot] = cost
                                elseif had ~= cost then
                                    slots[slot] = false
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return season
end

local function FromSeason(id)
    local A = ns.Atlas
    local locs = A and A.GetLocations and A:GetLocations(id)
    if not locs then return nil end
    local slot = ArmorSlot(id)
    if not slot then return nil end
    local idx = SeasonIndex()
    for _, loc in ipairs(locs) do
        if loc.cat and SEASON_CATS[loc.cat.key] and loc.src and SEASON_SOURCES[loc.src.key] and not loc.via then
            local v = idx[loc.src.key] and idx[loc.src.key][slot]
            if v then return v end
        end
    end
    return nil
end

-- What an item costs: parts ({ { key, n }, ... }, shared: don't modify), source ("vendor" | "atlasloot" | "shipped" |
-- "season"), the time a vendor asked it (source "vendor"). nil when nobody knows.
function Currency:GetCost(id)
    id = tonumber(id)
    if not id or id <= 0 then return nil end
    local cost, from = Direct(id)
    local at
    if from == "vendor" then
        local _, t = Learned(id)
        at = t
    end
    if not cost then
        cost = FromSeason(id)
        from = cost and "season" or nil
    end
    local parts = cost and self:Parse(cost)
    if not parts then return nil end
    return parts, from, at
end

-- Forget the derived caches (prices learned, AtlasLoot loaded late, the Atlas tree rebuilt for the other faction).
function Currency:Invalidate()
    season = nil
    alCache = {}
end

---------------------------------------------------------------------------
-- What I hold
---------------------------------------------------------------------------

local function CurrencyID(key)
    return tonumber(type(key) == "string" and key:match("^c(%d+)$"))
end

local function ItemID(key)
    return tonumber(type(key) == "string" and key:match("^(%d+)$"))
end

local function CurrencyInfo(cid)
    if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
        local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, cid)
        if ok and type(info) == "table" then return info end
    end
    return nil
end

-- How much of a currency I have: total (bags + bank for an item), in my bags (what a vendor takes).
function Currency:Have(key)
    if key == MONEY then
        local m = GetMoney and GetMoney() or 0
        return m, m
    end
    local cid = CurrencyID(key)
    if cid then
        local info = CurrencyInfo(cid)
        local n = info and tonumber(info.quantity)
        if not n and cid == 1901 and GetHonorCurrency then n = tonumber(GetHonorCurrency()) end
        if not n and cid == 1900 and GetArenaCurrency then n = tonumber(GetArenaCurrency()) end
        return n or 0, n or 0
    end
    local item = ItemID(key)
    if item then
        local count = (C_Item and C_Item.GetItemCount) or GetItemCount
        if not count then return 0, 0 end
        local total = tonumber(count(item, true)) or 0
        local bags = tonumber(count(item)) or 0
        return total, bags
    end
    return 0, 0
end

-- The most I can hold of a currency (Honor 75000, Arena Points 5000), or nil.
function Currency:Max(key)
    local cid = CurrencyID(key)
    local info = cid and CurrencyInfo(cid)
    local m = info and tonumber(info.maxQuantity)
    return (m and m > 0) and m or nil
end

-- Each part of a cost against what I hold: { { key, n, have, short }, ... } (short = how many I lack, 0 = enough),
-- and true when every part is enough.
function Currency:Check(parts)
    local out, all = {}, true
    for i, p in ipairs(parts or {}) do
        local have = self:Have(p.key)
        local short = p.n > have and (p.n - have) or 0
        if short > 0 then all = false end
        out[i] = { key = p.key, n = p.n, have = have, short = short }
    end
    return out, all
end

---------------------------------------------------------------------------
-- Names, icons, text
---------------------------------------------------------------------------

function Currency:Name(key)
    local cid = CurrencyID(key)
    if cid then
        local info = CurrencyInfo(cid)
        if info and type(info.name) == "string" and info.name ~= "" then return info.name end
        return FALLBACK_NAMES[key] or ("Currency " .. cid)
    end
    if key == MONEY then return FALLBACK_NAMES[MONEY] end
    local item = ItemID(key)
    if item then
        local name = C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(item)
        if type(name) == "string" and name ~= "" then return name end
        local A = ns.Atlas
        return FALLBACK_NAMES[key] or (A and A.GetShippedName and A:GetShippedName(item)) or ("Item " .. item)
    end
    return tostring(key)
end

-- An icon: texture (file id or path), and its tex coords (l, r, t, b) when it doesn't fill its file.
function Currency:Icon(key)
    if key == MONEY then return GOLD_TEXTURE end
    local cid = CurrencyID(key)
    if cid then
        local info = CurrencyInfo(cid)
        local tex = info and info.iconFileID
        if (not tex or tex == 0) and cid == 1901 then
            tex = (UnitFactionGroup and UnitFactionGroup("player") == "Horde") and 137000 or 136998
        elseif (not tex or tex == 0) and cid == 1900 then
            tex = ARENA_TEXTURE
        end
        if HONOR_TEXTURES[tex] then return tex, HONOR_COORDS[1], HONOR_COORDS[2], HONOR_COORDS[3], HONOR_COORDS[4] end
        return tex or "Interface\\Icons\\INV_Misc_QuestionMark"
    end
    local item = ItemID(key)
    local tex = item and ((C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(item))
        or (GetItemIcon and GetItemIcon(item)))
    return tex or "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- The icon as a text escape ("|T...|t") of size px.
function Currency:IconMarkup(key, size)
    size = size or 12
    local tex, l, r, t, b = self:Icon(key)
    if l then
        return ("|T%s:%d:%d:0:0:64:64:%d:%d:%d:%d|t"):format(tostring(tex), size, size, floor(l * 64), floor(r * 64),
            floor(t * 64), floor(b * 64))
    end
    -- item icons: trim their border like the game's small icons
    if ItemID(key) then return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(tostring(tex), size, size) end
    return ("|T%s:%d:%d|t"):format(tostring(tex), size, size)
end

-- 22950 -> "22,950" (the client's own grouping when it has one).
function Currency:Number(n)
    n = floor(tonumber(n) or 0)
    if BreakUpLargeNumbers then
        local ok, s = pcall(BreakUpLargeNumbers, n)
        if ok and type(s) == "string" and s ~= "" then return s end
    end
    local s = tostring(n)
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- An amount of a currency as text: "1,875" (money: "12g 50s" with coin icons).
function Currency:AmountText(key, n, size)
    if key == MONEY then
        local get = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
        if get then
            local ok, s = pcall(get, n, size)
            if ok and type(s) == "string" then return s end
        end
        local g, s = floor(n / 10000), floor(n / 100) % 100
        return (g > 0 and (g .. "g") or "") .. ((s > 0 or g == 0) and ((g > 0 and " " or "") .. s .. "s") or "")
    end
    return self:Number(n)
end

local RED, WHITE = "|cffff5a4f", "|cffe8e8e8"

-- A cost as one line: "1,875 [icon]  10 [icon]", each amount red when I hold less (uncolored = plain text).
function Currency:CostText(parts, size, colored)
    size = size or 12
    local checks = colored ~= false and self:Check(parts) or nil
    local out = {}
    for i, p in ipairs(parts or {}) do
        local amount = self:AmountText(p.key, p.n, size)
        local icon = p.key == MONEY and "" or (" " .. self:IconMarkup(p.key, size))
        local color = checks and (checks[i].short > 0 and RED or WHITE) or ""
        out[#out + 1] = color .. amount .. (color ~= "" and "|r" or "") .. icon
    end
    return tconcat(out, "  ")
end

---------------------------------------------------------------------------
-- Learning from vendors
---------------------------------------------------------------------------

-- The cost key of a vendor's cost item (GetMerchantItemCostItem): an item, a currency link, else Honor / Arena
-- Points by their icon or name.
local function CostKeyOf(texture, link, name)
    if type(link) == "string" then
        local item = link:match("item:(%d+)")
        if item then return item end
        local cur = link:match("currency:(%d+)")
        if cur then return "c" .. cur end
    end
    if HONOR_TEXTURES[texture] then return HONOR end
    for _, key in ipairs({ HONOR, ARENA }) do
        if texture and texture == Currency:Icon(key) then return key end
        if type(name) == "string" and name ~= "" and name == Currency:Name(key) then return key end
    end
    return nil
end

local function Listed(id)
    local names = Data().AtlasNames
    return type(names) == "table" and names[id] ~= nil
end

-- Keeps what a vendor asked for an item; true when it differs from what I knew.
local function Learn(id, cost)
    local db = ns.db
    if type(db) ~= "table" then return false end
    if type(db.prices) ~= "table" then db.prices = {} end
    local old = Learned(id)
    db.prices[id] = cost .. "|" .. (time and time() or 0)
    return old ~= cost
end

-- Reads the open vendor: every item paid with something else than money, and the money price of items the Atlas
-- lists (not every vendor's food and reagents). Items whose cost the client hasn't loaded yet wait for the next
-- MERCHANT_UPDATE. Returns how many prices changed.
function Currency:ScanMerchant()
    if not (GetMerchantNumItems and GetMerchantItemID and GetMerchantItemInfo) then return 0 end
    local changed = 0
    for i = 1, GetMerchantNumItems() or 0 do
        local id = GetMerchantItemID(i)
        local _, _, price, stack = GetMerchantItemInfo(i)
        if id and (tonumber(stack) or 1) <= 1 then
            local parts, ok = {}, true
            if tonumber(price) and price > 0 then parts[#parts + 1] = MONEY .. ":" .. floor(price) end
            local count = (GetMerchantItemCostInfo and GetMerchantItemCostInfo(i)) or 0
            for c = 1, count do
                local tex, value, link, name = GetMerchantItemCostItem(i, c)
                local key = CostKeyOf(tex, link, name)
                value = tonumber(value)
                if not key or not value or value <= 0 then
                    ok = false
                    break
                end
                parts[#parts + 1] = key .. ":" .. floor(value)
            end
            if ok and #parts > 0 and (count > 0 or Listed(id)) and Learn(id, tconcat(parts, ",")) then
                changed = changed + 1
            end
        end
    end
    if changed > 0 then
        self:Invalidate()
        ns:Fire("PRICES_UPDATED")
    end
    return changed
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function Debounce(key, sec, fn)
    if ns.Util and ns.Util.Debounce then ns.Util.Debounce(key, sec, fn) elseif C_Timer then C_Timer.After(sec, fn) else fn() end
end

local function ScanSoon()
    Debounce("currency-merchant", 0.3, function() Currency:ScanMerchant() end)
end

-- What I hold changed: the bar and the red / white amounts.
local function HoldingsChanged()
    Debounce("currency-held", 0.2, function() ns:Fire("CURRENCY_CHANGED") end)
end

function Currency:OnInit()
    ns:RegisterEvent("MERCHANT_SHOW", ScanSoon)
    ns:RegisterEvent("MERCHANT_UPDATE", ScanSoon)
    ns:RegisterEvent("CURRENCY_DISPLAY_UPDATE", HoldingsChanged)
    ns:RegisterEvent("PLAYER_MONEY", HoldingsChanged)
    ns:RegisterEvent("BAG_UPDATE_DELAYED", HoldingsChanged)
    ns:RegisterEvent("HONOR_CURRENCY_UPDATE", HoldingsChanged)
end

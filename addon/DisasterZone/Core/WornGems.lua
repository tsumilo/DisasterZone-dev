if DisasterZoneBoot and DisasterZoneBoot.Run("Core/WornGems.lua", ...) then return end -- DisasterZone Core/WornGems.lua
-- ns.WornGems: gems and enchants for the gear I wear (My BiS's Equipped view). What an item has comes from its link;
-- what I mean to put in (the gem editor, Suggest) is my plan, kept per character and item: db.wornGems[charKey] =
-- { [itemID] = "enchant:g1:g2:g3:g4" }, never synced. A plan holds only what differs from the item (0 = keep what it
-- has), so a gem I socket drops out of it by itself and the plan of an item I take off waits for when I wear it again.
-- Worn:View(list) is a list view of the worn items whose setups are the plan over what the items have: the doll,
-- ns.Gems (State, Progress, ColorCounts, FillSetups, ShoppingNeedsOf) and the gem editor read it like a BiS list.
-- Still to apply: the planned gems and enchants the items don't have yet (Worn:Pending).
local addonName, ns = ...

local Worn = {}
ns.WornGems = Worn

local NUM_SLOTS = 17
local MAX_PLANS = 60   -- plans of items I neither wear nor carry are dropped past this many

local function G() return ns.Gems end

local function Encode(enchant, gems)
    gems = gems or {}
    return ("%d:%d:%d:%d:%d"):format(tonumber(enchant) or 0, tonumber(gems[1]) or 0, tonumber(gems[2]) or 0,
        tonumber(gems[3]) or 0, tonumber(gems[4]) or 0)
end

-- My plans ({ [itemID] = setup string }), created when `create`; nil before login or without one.
local function Plans(create)
    local db = ns.db
    local key = ns.loggedIn and ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey()
    if not (db and key) then return nil end
    if type(db.wornGems) ~= "table" then
        if not create then return nil end
        db.wornGems = {}
    end
    local t = db.wornGems[key]
    if type(t) ~= "table" then
        if not create then return nil end
        t = {}
        db.wornGems[key] = t
    end
    return t
end

-- What I wear: { [sid] = { id, enchant, gems = { [socket] = gem id } } } (read from the item links).
function Worn:Equipped()
    local out = {}
    local Exp = ns.BiSExport
    for sid, s in pairs(Exp and Exp.EquippedSpecs and Exp:EquippedSpecs() or {}) do
        if type(s) == "table" and tonumber(s.id) then
            local gems = {}
            for i, g in pairs(s.gems or {}) do
                if (tonumber(g) or 0) ~= 0 then gems[i] = tonumber(g) end
            end
            out[sid] = { id = tonumber(s.id), enchant = tonumber(s.enchant) or 0, gems = gems }
        end
    end
    return out
end

-- The worn entry of an item (the first slot that holds it), or nil.
function Worn:EntryOf(itemID, eq)
    itemID = tonumber(itemID)
    for sid = 1, NUM_SLOTS do
        local e = (eq or self:Equipped())[sid]
        if e and e.id == itemID then return e, sid end
    end
    return nil
end

-- My plan for an item: enchant and gems { [socket] = id } (0 = keep what the item has).
function Worn:GetPlan(itemID)
    return G():GetSetup({ ge = Plans(false) or {} }, itemID)
end

-- What the item will have: the plan over what it has. enchant, gems { [socket] = id } (every socket).
function Worn:Merged(entry)
    local pEnchant, pGems = self:GetPlan(entry.id)
    local n = #G():Sockets(entry.id)
    for i in pairs(entry.gems) do if i > n then n = i end end
    local gems = {}
    for i = 1, n do
        local p = tonumber(pGems[i]) or 0
        gems[i] = p ~= 0 and p or (entry.gems[i] or 0)
    end
    return pEnchant ~= 0 and pEnchant or entry.enchant, gems
end

-- The list view of what I wear: class, the list's spec (its guide is Suggest's), the worn items as every phase's
-- picks and their setups (asIs: what the items have, without my plan). list: "os" = the off-spec list's spec.
function Worn:View(list, asIs, eq)
    local BiS = ns.BiS
    local data = BiS and BiS.GetData and BiS:GetData() or {}
    local picks, ge = {}, {}
    for sid, e in pairs(eq or self:Equipped()) do
        picks[sid] = { e.id }
        if asIs then
            ge[e.id] = Encode(e.enchant, e.gems)
        else
            ge[e.id] = Encode(self:Merged(e))
        end
    end
    local ph = {}
    for p = 1, ns.MAX_PHASE or 5 do ph[p] = picks end
    local cl = data.cl
    if type(cl) ~= "string" or cl == "" then
        local _, classFile = UnitClass("player")
        cl = classFile
    end
    return { v = data.v, cl = cl, sp = BiS and BiS.GetSpec and BiS:GetSpec(list) or "", ph = ph, pr = picks, ge = ge,
             worn = true }
end

-- Drops plans of items I neither wear nor carry once there are more than MAX_PLANS.
local function Trim(t, eq)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n <= MAX_PLANS then return end
    local worn = {}
    for _, e in pairs(eq) do worn[e.id] = true end
    for id in pairs(t) do
        if not worn[id] and not ((GetItemCount and GetItemCount(id, true) or 0) > 0) then t[id] = nil end
    end
end

-- Stores my plan for a worn item from a whole setup (the gem editor's, Suggest's): what equals the item is left out,
-- nothing left = no plan. quiet: no WORN_GEMS_CHANGED (the caller fires it once). Returns true when it changed.
function Worn:SetSetup(itemID, enchant, gems, quiet, eq)
    itemID = tonumber(itemID)
    if not itemID then return false end
    eq = eq or self:Equipped()
    local entry = self:EntryOf(itemID, eq)
    local e = tonumber(enchant) or 0
    if entry and e == entry.enchant then e = 0 end
    local g, any = {}, e ~= 0
    for i = 1, 4 do
        local v = tonumber(gems and gems[i]) or 0
        if entry and v == (entry.gems[i] or 0) then v = 0 end
        g[i] = v
        if v ~= 0 then any = true end
    end
    local t = Plans(true)
    if not t then return false end
    local new = any and Encode(e, g) or nil
    if t[itemID] == new then return false end
    t[itemID] = new
    Trim(t, eq)
    if not quiet then ns:Fire("WORN_GEMS_CHANGED") end
    return true
end

-- Forgets my plan for an item (back to what it has).
function Worn:ClearPlan(itemID)
    local t = Plans(false)
    itemID = tonumber(itemID)
    if not (t and itemID and t[itemID]) then return false end
    t[itemID] = nil
    ns:Fire("WORN_GEMS_CHANGED")
    return true
end

-- Forgets the plans of everything I wear.
function Worn:ClearAll()
    local t = Plans(false)
    if not t then return 0 end
    local n = 0
    for _, e in pairs(self:Equipped()) do
        if t[e.id] then
            t[e.id] = nil
            n = n + 1
        end
    end
    if n > 0 then ns:Fire("WORN_GEMS_CHANGED") end
    return n
end

-- What a worn item still needs applied (Worn:PendingFor): { gems = { [socket] = planned id }, n = gem count, enchant = id | nil }
-- or nil when nothing.
local function PendingOf(self, e)
    local pEnchant, pGems = self:GetPlan(e.id)
    local p = { gems = {}, n = 0 }
    for i, v in pairs(pGems) do
        if v ~= 0 and v ~= (e.gems[i] or 0) then
            p.gems[i] = v
            p.n = p.n + 1
        end
    end
    if pEnchant ~= 0 and pEnchant ~= e.enchant then p.enchant = pEnchant end
    if p.n == 0 and not p.enchant then return nil end
    return p
end

function Worn:PendingFor(entry)
    return entry and PendingOf(self, entry) or nil
end

-- What is still to apply on the gear I wear: { { sid, itemID, gems = { [socket] = id }, n, enchant = id | nil } } in
-- slot order (the items with something to apply).
function Worn:Pending(eq)
    local out = {}
    if not Plans(false) then return out end
    eq = eq or self:Equipped()
    for sid = 1, NUM_SLOTS do
        local e = eq[sid]
        local p = e and PendingOf(self, e)
        if p then
            p.sid, p.itemID = sid, e.id
            out[#out + 1] = p
        end
    end
    return out
end

-- Suggest for the gear I wear: the spec guide's gems and enchants (at the list's gem quality, for the phase) in every
-- empty socket and missing enchant; overwrite: the best for every socket and enchant, the ones the items have
-- included (where that is what an item has, nothing is left to apply). Returns how many items' plans changed, nil
-- without a guide for the list's spec.
function Worn:Fill(list, phase, overwrite)
    local Gm = G()
    local eq = self:Equipped()
    local view = self:View(list, false, eq)
    local setups = Gm:WithQuality(Gm:GetQuality(list), Gm.FillSetups, Gm, view, phase, nil, overwrite)
    if not setups then return nil end
    local n = 0
    for itemID, s in pairs(setups) do
        if self:SetSetup(itemID, s.enchant, s.gems, true, eq) then n = n + 1 end
    end
    if n > 0 then ns:Fire("WORN_GEMS_CHANGED") end
    return n
end

-- What the plan still takes, for the shopping list (Gems:ShoppingNeedsOf: only the gems and enchants the items don't
-- have yet). needs { [id] = count }, how many no craft makes.
function Worn:ShoppingNeeds(list, phase)
    return G():ShoppingNeedsOf(self:View(list), phase, nil, true)
end

-- Puts ShoppingNeeds on my shopping list: how many were added (crafts x count), how many no craft makes.
function Worn:AddToShoppingList(list, phase)
    local needs, other = self:ShoppingNeeds(list, phase)
    local n = 0
    for id, count in pairs(needs) do
        if ns.Shop:Add(id, count) then n = n + count end
    end
    return n, other
end

-- The gem editor's host (UI/GemEditor.lua) for a worn item: the setup it shows is the plan over the item, a change
-- is stored as my plan; Clear goes back to what the item has.
function Worn:GemHost(itemID, list)
    return {
        kind = "worn",
        clearText = "Reset",
        -- "Equipped  ·  2 to apply" / "Equipped  ·  as worn"
        sub = function()
            local e = self:EntryOf(itemID)
            local p = e and PendingOf(self, e)
            local n = p and (p.n + (p.enchant and 1 or 0)) or 0
            return "Equipped  ·  " .. (n > 0 and (n .. " to apply") or "as worn")
        end,
        view = function() return self:View(list) end,
        get = function()
            local e = self:EntryOf(itemID)
            if not e then return 0, {} end
            return self:Merged(e)
        end,
        set = function(enchant, gems)
            if enchant == nil and gems == nil then
                self:ClearPlan(itemID)
            else
                self:SetSetup(itemID, enchant, gems)
            end
        end,
    }
end

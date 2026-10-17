if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Wardrobe.lua", ...) then return end -- DisasterZone Core/Wardrobe.lua
-- ns.Wardrobe: outfits (Gear > Wardrobe, UI/Wardrobe.lua). TBC has no equipment manager, so this is one: an outfit
-- is a name, an icon and an item per inventory slot, kept per character and never synced:
--   db.wardrobe[charKey] = { outfits = { { id, name, icon, art, slots = { [invSlot] = { id, key } | false },
--     rules = { spec = "Retribution", boss = { kind = "boss" | "zone", name }, pole = true, mount = true } } },
--     bank = { { id, key } ... } (what the bank held when it was last open), bar = true (the quick-swap bar), n }
-- A slot left out is "keep current" (Wear never touches it); false = the slot is emptied. key = the link's
-- "id:enchant:gem1:gem2:gem3:gem4:suffix", so two copies with other gems or enchants are told apart (an item found
-- only by its id still counts).
-- Status per slot (W:Status): worn | swap (from the bags, or the other ring / trinket slot) | bank | missing | keep.
-- Wear swaps everything in one pass (W:Pass, as ItemRack / Outfitter do): only the slots that differ, every move in
-- the same frame; what can't move yet gets a few short retries, then a plain report. In combat the weapons, off hand
-- and ranged / relic swap at once and the armour waits for PLAYER_REGEN_ENABLED; never while casting (a moment
-- later) or dead. With the bank open, missing pieces come out of it into free bag slots first. Wear automatically (rules, all off for a new outfit): a spec switch, a boss
-- targeted or a zone entered (back after the kill / on leaving), a fishing pole put on (back when it comes off),
-- mounted (back on landing). Demo mode (/dz demo on) shows made-up outfits for any class; Wear there only pretends.
local addonName, ns = ...

local W = ns:NewModule("Wardrobe")

local floor, max = math.floor, math.max
local pairs, ipairs, type, tonumber, tostring = pairs, ipairs, type, tonumber, tostring
local tinsert, tremove, tconcat = table.insert, table.remove, table.concat

W.MAX = 7                  -- outfits per character (the list shows them all, the bar card under them)

-- The doll's slots (inventory slot ids) in its order: left column, then right; shirt and tabard are left out.
W.SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }
W.SLOT_NAME = { [1] = "Head", [2] = "Neck", [3] = "Shoulder", [15] = "Back", [5] = "Chest", [9] = "Wrist",
    [10] = "Hands", [6] = "Waist", [7] = "Legs", [8] = "Feet", [11] = "Finger", [12] = "Finger", [13] = "Trinket",
    [14] = "Trinket", [16] = "Main hand", [17] = "Off hand", [18] = "Relic" }
-- the item types each slot takes
local FITS = {
    [1] = { INVTYPE_HEAD = true }, [2] = { INVTYPE_NECK = true }, [3] = { INVTYPE_SHOULDER = true },
    [15] = { INVTYPE_CLOAK = true }, [5] = { INVTYPE_CHEST = true, INVTYPE_ROBE = true },
    [9] = { INVTYPE_WRIST = true },
    [10] = { INVTYPE_HAND = true }, [6] = { INVTYPE_WAIST = true }, [7] = { INVTYPE_LEGS = true },
    [8] = { INVTYPE_FEET = true }, [11] = { INVTYPE_FINGER = true }, [12] = { INVTYPE_FINGER = true },
    [13] = { INVTYPE_TRINKET = true }, [14] = { INVTYPE_TRINKET = true },
    [16] = { INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true, INVTYPE_WEAPONMAINHAND = true },
    [17] = { INVTYPE_WEAPON = true, INVTYPE_WEAPONOFFHAND = true, INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true },
    [18] = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true, INVTYPE_RELIC = true },
}
W.FITS = FITS
local ARTS = { "Karazhan", "GruulsLair", "SerpentshrineCavern", "nagrand", "TempestKeep", "MagtheridonsLair" }
-- fishing poles (their item subclass where the client tells it; these ids where it doesn't)
local POLES = { [6256] = true, [6365] = true, [6366] = true, [6367] = true, [12225] = true, [19022] = true,
    [19970] = true, [25978] = true }

local job   -- the swap running now: { o, why, passes, failed = { [inv] = why }, moved = {}, pulled, next } (Wearing)
-- (the demo guild, or the Demo page's outfit bar part: made-up outfits, Core/DemoParts.lua)
local function Demo()
    local D = ns.Demo
    if not D then return false end
    return (D.IsEnabled and D:IsEnabled()) or (D.IsOn and D:IsOn("outfits")) or false
end
W.IsDemo = Demo

local function Say(text) ns:Print("%s", text) end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------
local function Store(create)
    local db = ns.db
    local key = ns.loggedIn and ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey()
    if not (db and key) then return nil end
    if type(db.wardrobe) ~= "table" then
        if not create then return nil end
        db.wardrobe = {}
    end
    local t = db.wardrobe[key]
    if type(t) ~= "table" then
        if not create then return nil end
        t = { outfits = {}, n = 0 }
        db.wardrobe[key] = t
    end
    if type(t.outfits) ~= "table" then t.outfits = {} end
    return t
end
W.Store = Store

---------------------------------------------------------------------------
-- Items: keys, links, slots
---------------------------------------------------------------------------
-- "id:enchant:g1:g2:g3:g4:suffix" of a link or item string (nil for none).
function W.KeyOf(link)
    if type(link) ~= "string" then return nil end
    local id, rest = link:match("item:(%d+):?([%-%d:]*)")
    if not id then return nil end
    local f = { id }
    for v in (rest or ""):gmatch("([^:]*):?") do
        if #f >= 7 then break end
        f[#f + 1] = tonumber(v) or 0
    end
    for i = #f + 1, 7 do f[i] = 0 end
    return tconcat(f, ":", 1, 7)
end
local KeyOf = W.KeyOf

local function EquipLoc(id)
    local loc = ns.ItemDB and ns.ItemDB.GetEquipLoc and ns.ItemDB:GetEquipLoc(id)
    if not loc and GetItemInfo then loc = select(9, GetItemInfo(id)) end
    return loc
end
W.EquipLoc = EquipLoc

function W.IsTwoHand(id) return id and EquipLoc(id) == "INVTYPE_2HWEAPON" or false end

function W.IsPole(id)
    id = tonumber(id)
    if not id then return false end
    if POLES[id] then return true end
    local sub = GetItemInfo and select(7, GetItemInfo(id))
    return type(sub) == "string" and sub:find("Fishing Pole") ~= nil
end

function W.Fits(id, inv)
    local loc = EquipLoc(id)
    return loc ~= nil and FITS[inv] ~= nil and FITS[inv][loc] == true
end

-- (C_Container where the client has it, the old globals otherwise)
local function CC(name) return (C_Container and C_Container[name]) or _G[name] end
local function NumSlots(bag) local f = CC("GetContainerNumSlots"); return f and f(bag) or 0 end
local function SlotLink(bag, slot) local f = CC("GetContainerItemLink"); return f and f(bag, slot) end
local function SlotID(bag, slot)
    local f = CC("GetContainerItemID")
    if f then return f(bag, slot) end
    local link = SlotLink(bag, slot)
    return link and tonumber(link:match("item:(%d+)"))
end
local function NumBags() return tonumber(NUM_BAG_SLOTS) or 4 end
local function BankBags()
    local out, first = { -1 }, NumBags() + 1
    for b = first, first + (tonumber(NUM_BANKBAGSLOTS) or 7) - 1 do out[#out + 1] = b end
    return out
end

---------------------------------------------------------------------------
-- Scanning: what I wear, carry and keep in the bank
---------------------------------------------------------------------------
W.bankOpen = false

-- A bag slot's item is locked (picked up, or a move the server has not answered yet). C_Container returns a table;
-- the old GetContainerItemInfo returns the lock as its third value.
local function BagLocked(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if type(info) == "table" then return info.isLocked and true or false end
    end
    if GetContainerItemInfo then
        local _, _, locked = GetContainerItemInfo(bag, slot)
        return locked and true or false
    end
    return false
end

local function Entry(id, link, where, bag, slot)
    local e = { id = id, key = KeyOf(link) or (tostring(id) .. ":0:0:0:0:0:0"), link = link, where = where, bag = bag,
        slot = slot }
    if bag then e.locked = BagLocked(bag, slot) or nil end
    return e
end

-- { worn = { [inv] = entry }, bags = { entry ... }, bank = { entry ... }, bankLive = bank open }
function W:Scan()
    local s = { worn = {}, bags = {}, bank = {}, bankLive = self.bankOpen }
    for _, inv in ipairs(W.SLOTS) do
        local id = GetInventoryItemID and (GetInventoryItemID("player", inv))
        id = tonumber(id)
        if id then s.worn[inv] = Entry(id, GetInventoryItemLink("player", inv), "worn", nil, nil) end
        if s.worn[inv] then s.worn[inv].inv = inv end
    end
    for bag = 0, NumBags() do
        for slot = 1, NumSlots(bag) do
            local id = SlotID(bag, slot)
            if id then s.bags[#s.bags + 1] = Entry(id, SlotLink(bag, slot), "bags", bag, slot) end
        end
    end
    if self.bankOpen then
        for _, bag in ipairs(BankBags()) do
            for slot = 1, NumSlots(bag) do
                local id = SlotID(bag, slot)
                if id then s.bank[#s.bank + 1] = Entry(id, SlotLink(bag, slot), "bank", bag, slot) end
            end
        end
    else
        local st = Store(false)
        for _, e in ipairs(st and st.bank or {}) do
            s.bank[#s.bank + 1] = { id = e.id, key = e.key, where = "bank" }
        end
    end
    return s
end

-- Keeps what the bank holds (equippable things only) for when it is closed.
function W:CacheBank()
    if not self.bankOpen then return end
    local st = Store(true)
    if not st then return end
    local list = {}
    for _, bag in ipairs(BankBags()) do
        for slot = 1, NumSlots(bag) do
            local id = SlotID(bag, slot)
            if id and EquipLoc(id) then list[#list + 1] = { id = id, key = KeyOf(SlotLink(bag, slot)) } end
        end
    end
    st.bank = list
end

---------------------------------------------------------------------------
-- Resolving an outfit against what I have
---------------------------------------------------------------------------
-- How well an entry is the wanted item: 2 the same copy, 1 the same item, 0 not it.
local function Match(e, want)
    if not (e and want) or e.id ~= want.id then return 0 end
    if want.key and e.key == want.key then return 2 end
    return want.key and 1 or 2
end

local function LocKey(e)
    if e.inv then return "i" .. e.inv end
    return e.where .. ":" .. tostring(e.bag) .. ":" .. tostring(e.slot) .. ":" .. e.key
end

-- slots = { [inv] = { st, id, want, src (entry to take it from) } } for an outfit; counts = { worn, swap, bank,
-- missing, keep }.
function W:Resolve(o, scan)
    scan = scan or self:Scan()
    local out, counts = {}, { worn = 0, swap = 0, bank = 0, missing = 0, keep = 0 }
    local taken = {}
    local slots = o.slots or {}
    -- a two-hander in the main hand: nothing in the off hand
    local mh = slots[16]
    local twoHand = type(mh) == "table" and W.IsTwoHand(mh.id)
    local function wantOf(inv)
        local w = slots[inv]
        if inv == 17 and twoHand and w ~= nil then return false end
        return w
    end
    -- first the slots that already wear their item (the exact copy; or the item when no exact copy is anywhere)
    for _, inv in ipairs(W.SLOTS) do
        local want, worn = wantOf(inv), scan.worn[inv]
        if want == nil then
            out[inv] = { st = "keep", id = worn and worn.id, key = worn and worn.key }
            counts.keep = counts.keep + 1
        elseif want == false then
            if not worn then out[inv] = { st = "worn" } end
        elseif Match(worn, want) == 2 then
            out[inv] = { st = "worn", id = want.id, want = want }
            taken[LocKey(worn)] = true
        end
    end
    local function find(want, best, inv)
        local pools = { scan.worn, scan.bags, scan.bank }
        for _, need in ipairs(best and { 2 } or { 2, 1 }) do
            for p, pool in ipairs(pools) do
                for k, e in pairs(pool) do
                    local ok = p ~= 1 or (k ~= inv and not (out[k] and out[k].st == "worn"))
                    if ok and not taken[LocKey(e)] and Match(e, want) >= need then return e end
                end
            end
        end
    end
    for _, inv in ipairs(W.SLOTS) do
        if not out[inv] then
            local want, worn = wantOf(inv), scan.worn[inv]
            if want == false then
                out[inv] = { st = "swap", empty = true }
            else
                local src = find(want, true, inv)
                if not src and Match(worn, want) == 1 then
                    src = worn                       -- (another copy of it is worn: good enough)
                end
                src = src or find(want, false, inv)
                if src == worn then
                    out[inv] = { st = "worn", id = want.id, want = want }
                elseif not src then
                    out[inv] = { st = "missing", id = want.id, want = want }
                elseif src.where == "bank" then
                    out[inv] = { st = "bank", id = want.id, want = want, src = src }
                else
                    out[inv] = { st = "swap", id = want.id, want = want, src = src }
                end
                if src then taken[LocKey(src)] = true end
            end
        end
        local st = out[inv].st
        if st ~= "keep" then counts[st] = counts[st] + 1 end
    end
    return out, counts
end

-- slots (as W:Resolve) and counts of an outfit; demo outfits carry theirs.
function W:Status(o)
    if o.demoSlots then return o.demoSlots, o.demoCounts end
    return self:Resolve(o)
end

function W:IsWorn(o)
    if o.demo then return o.wearing and true or false end
    if job and job.o == o then return true end          -- (on its way: shown as worn from the click)
    local _, c = self:Status(o)
    return c.swap + c.bank + c.missing == 0
end

---------------------------------------------------------------------------
-- The outfits
---------------------------------------------------------------------------
function W:List()
    if Demo() then return self:DemoList() end
    local st = Store(false)
    return st and st.outfits or {}
end

function W:Get(id)
    for _, o in ipairs(self:List()) do if o.id == id then return o end end
end

-- The first outfit I have on now (nil for none).
function W:Wearing()
    -- the one on its way wins (the last click: the ring follows it at once); then the one worn last, when two
    -- outfits match what I wear
    if job then return job.next and job.next.o or job.o end
    local cur = W.current and self:Get(W.current)
    if cur and self:IsWorn(cur) then return cur end
    for _, o in ipairs(self:List()) do if self:IsWorn(o) then return o end end
end

local function Changed() ns:Fire("WARDROBE_UPDATED") end
W.Changed = Changed

local function UniqueName(base)
    local taken = {}
    for _, o in ipairs(W:List()) do taken[o.name] = true end
    if not taken[base] then return base end
    for i = 2, 99 do
        if not taken[base .. " " .. i] then return base .. " " .. i end
    end
    return base
end
W.UniqueName = UniqueName

function W:CanAdd() return #self:List() < W.MAX end

-- A new outfit: slots = { [inv] = { id, key } | false }. Returns it (nil when the list is full).
function W:Add(name, slots, icon)
    if not self:CanAdd() then return nil end
    local list
    if Demo() then
        list = self:DemoList()
    else
        local st = Store(true)
        if not st then return nil end
        list = st.outfits
        st.n = (tonumber(st.n) or 0) + 1
    end
    local n = #list + 1
    local id = (Demo() and "demo" or "o") .. tostring(Demo() and n or Store(false).n)
    while self:Get(id) do id = id .. "x" end
    if not icon then
        for _, inv in ipairs({ 16, 5, 1, 18 }) do
            local s = slots[inv]
            if type(s) == "table" then
                icon = (ns.ItemDB and ns.ItemDB.GetIcon and ns.ItemDB:GetIcon(s.id))
                    or (GetItemIcon and GetItemIcon(s.id))
                if icon then break end
            end
        end
    end
    local o = { id = id, name = UniqueName(name or "Outfit"), icon = icon or 132608, art = ARTS[(n - 1) % #ARTS + 1],
        slots = slots, rules = {} }
    if Demo() then o.demo = true; o.demoSlots, o.demoCounts = W.DemoResolve(o) end
    list[#list + 1] = o
    Changed()
    return o
end

-- What I wear now as slots (shirt and tabard left out; an empty slot is saved empty).
function W:WornSlots()
    local slots = {}
    for _, inv in ipairs(W.SLOTS) do
        local id = tonumber((GetInventoryItemID("player", inv)))
        if id then slots[inv] = { id = id, key = KeyOf(GetInventoryItemLink("player", inv)) }
        else slots[inv] = false end
    end
    return slots
end

function W:SaveWorn(name)
    if Demo() then
        local s = {}
        for inv, id in pairs(W.DEMO_WORN) do s[inv] = id and { id = id } or false end
        return self:Add(name or "My gear", s, "Interface\\Icons\\INV_Chest_Plate03")
    end
    return self:Add(name or "My gear", self:WornSlots())
end

-- Saves what I wear into an outfit (its keep-current slots stay so).
function W:Overwrite(id)
    local o = self:Get(id)
    if not o or o.demo then return end
    local worn = self:WornSlots()
    for inv in pairs(o.slots) do o.slots[inv] = worn[inv] end
    Changed()
end

-- My BiS list's picks (of a phase) as an outfit, its empty picks kept current.
-- phase: the list's phase (the page passes the one My BiS shows; default 1).
function W:SaveBiS(phase)
    local BiS = ns.BiS
    if not (BiS and BiS.GetPhaseItems) then return nil end
    phase = phase or 1
    local slots, n = {}, 0
    for _, p in ipairs(BiS:GetPhaseItems(phase) or {}) do
        local def = ns.SLOTS and ns.SLOTS[p.sid]
        if p.which == "main" and def and not p.disabled then
            slots[def.invSlot] = { id = p.itemID }
            n = n + 1
        end
    end
    if n == 0 then return nil end
    local spec = BiS.GetSpec and BiS:GetSpec() or ""
    return self:Add((spec ~= "" and spec or "My") .. " BiS", slots)
end

function W:Rename(id, name)
    local o = self:Get(id)
    if not o or type(name) ~= "string" or name == "" then return end
    o.name = name
    Changed()
end

function W:SetIcon(id, icon)
    local o = self:Get(id)
    if not o then return end
    o.icon = icon
    Changed()
end

function W:Delete(id)
    local list = self:List()
    for i, o in ipairs(list) do
        if o.id == id then tremove(list, i); Changed(); return true end
    end
end

-- One slot: item = { id, key } | false (empty) | nil (keep current).
function W:SetSlot(id, inv, item)
    local o = self:Get(id)
    if not o then return end
    o.slots[inv] = item
    if o.demo then o.demoSlots, o.demoCounts = W.DemoResolve(o) end
    Changed()
end

-- A rule: spec = spec label, boss = { kind, name }, pole / mount = true; nil turns it off.
function W:SetRule(id, key, value)
    local o = self:Get(id)
    if not o then return end
    o.rules = o.rules or {}
    if value ~= nil then
        -- (one outfit per rule: the other outfits let go of it)
        for _, x in ipairs(self:List()) do
            if x ~= o and x.rules and x.rules[key] ~= nil then
                local same = key ~= "spec" or x.rules.spec == value
                if same then x.rules[key] = nil end
            end
        end
    end
    o.rules[key] = value
    Changed()
end

function W:RuleCount(o)
    local n = 0
    for _ in pairs(o.rules or {}) do n = n + 1 end
    return n
end

-- In words: "Spec: Retribution · Fishing pole" (short) or what the banner says (long).
function W:RuleText(o, long)
    local r, parts = o.rules or {}, {}
    if r.spec then parts[#parts + 1] = long and ("when you switch to " .. r.spec) or ("Spec: " .. r.spec) end
    if r.boss then
        local b = r.boss
        if long then parts[#parts + 1] = (b.kind == "zone" and "in " or "when you target ") .. b.name
        else
            -- (the boss by its first name: "Hydross", so the list's pill keeps its room)
            parts[#parts + 1] = (b.kind == "zone" and "Zone: " or "Boss: ") .. (b.name:match("^(.-),? the ") or b.name)
        end
    end
    if r.pole then parts[#parts + 1] = long and "when you equip a fishing pole" or "Fishing pole" end
    if r.mount then parts[#parts + 1] = long and "while you ride" or "Mounted" end
    if #parts == 0 then return long and nil or "Worn by hand" end
    return tconcat(parts, long and " or " or "  ·  ")
end

-- Every item that fits a slot, from what I wear, carry and keep in the bank (one row per copy).
function W:Candidates(inv)
    local s, out, seen = self:Scan(), {}, {}
    local function add(e, where)
        if not W.Fits(e.id, inv) then return end
        local k = where .. e.key
        if seen[k] then return end
        seen[k] = true
        out[#out + 1] = { id = e.id, key = e.key, where = where }
    end
    if s.worn[inv] then add(s.worn[inv], "worn") end
    for _, e in ipairs(s.bags) do add(e, "bags") end
    for _, e in ipairs(s.bank) do add(e, "bank") end
    return out
end

---------------------------------------------------------------------------
-- Wearing: one pass swaps everything (as ItemRack / Outfitter do)
---------------------------------------------------------------------------
-- A pass plans every slot against a model of where each item is (cont: place -> entry) and issues all the moves in
-- the same frame: an item moved is "locked" for the rest of the pass (the client locks it too until the server
-- answers), so each item is used once, no bag slot is filled twice, and what comes off lands in the bag slot the new
-- piece left (or a free slot booked for it). Only what could not be done now (a locked item, a piece just taken
-- out of the bank) waits for a short retry pass, RETRIES at most; then it is reported. In combat the weapons, off
-- hand and ranged / relic swap at once (the game allows it) and the rest waits for the fight to end.
-- (job: the swap running now, declared at the top of the file)
W.queued = nil         -- an outfit (or its armour) waiting for the fight to end
local RETRY, RETRIES, SETTLE, WAITS = 0.1, 6, 0.3, 40
local IN_COMBAT = { [16] = true, [17] = true, [18] = true }   -- slots the game lets you change in a fight
W.IN_COMBAT = IN_COMBAT

local function Pickup(loc)
    if loc.inv then PickupInventoryItem(loc.inv)
    else CC("PickupContainerItem")(loc.bag, loc.slot) end
end

-- Moves an item (src) onto dst: both { inv } or { bag, slot }. Onto a worn slot or a full bag slot the two swap.
-- false = the game refused it (nothing picked up, or the item stayed on the cursor): the pass's model stays as it was.
function W.Move(src, dst)
    if CursorHasItem and CursorHasItem() then ClearCursor() end
    Pickup(src)
    if CursorHasItem and not CursorHasItem() then return false end
    Pickup(dst)
    if CursorHasItem and CursorHasItem() then
        ClearCursor()
        return false
    end
    return true
end

local function PlaceKey(l) return l.inv and ("i" .. l.inv) or ("b" .. l.bag .. ":" .. l.slot) end
local function IsBankBag(bag) return bag == -1 or bag > NumBags() end

-- A free slot in my bags (plain bags only) that no move of this pass fills (`cont` the pass's model).
function W:FreeBagSlot(cont, booked)
    for bag = 0, NumBags() do
        local free, family = 0, 0
        local f = CC("GetContainerNumFreeSlots")
        if f then free, family = f(bag) end
        if (tonumber(free) or 0) > 0 and (tonumber(family) or 0) == 0 then
            for slot = 1, NumSlots(bag) do
                local k = "b" .. bag .. ":" .. slot
                local empty = cont and (cont[k] == nil) or (not cont and not SlotID(bag, slot))
                if empty and not (booked and booked[k]) then return { bag = bag, slot = slot } end
            end
        end
    end
end

-- Why a swap can't start now (nil = it can).
local function Blocked()
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return "dead" end
    if (UnitCastingInfo and UnitCastingInfo("player")) or (UnitChannelInfo and UnitChannelInfo("player")) then
        return "casting"
    end
    if InCombatLockdown and InCombatLockdown() then return "combat" end
end

function W:IsBusy() return job ~= nil or W.queued ~= nil end

-- Every place the game shows locked now: { ["i16"] = true, ["b0:3"] = true, ... }.
function W:LockedPlaces()
    local out = {}
    for _, inv in ipairs(W.SLOTS) do
        if IsInventoryItemLocked and IsInventoryItemLocked(inv) then out["i" .. inv] = true end
    end
    local bags = {}
    for bag = 0, NumBags() do bags[#bags + 1] = bag end
    if self.bankOpen then for _, bag in ipairs(BankBags()) do bags[#bags + 1] = bag end end
    for _, bag in ipairs(bags) do
        for slot = 1, NumSlots(bag) do
            if SlotID(bag, slot) and BagLocked(bag, slot) then out["b" .. bag .. ":" .. slot] = true end
        end
    end
    return out
end

-- Something the game has not finished moving: a worn or bag item locked, or an item on the cursor. A pass only starts
-- when nothing is, so what the client shows is what the server has (an empty bag slot being filled shows no lock).
-- stale = places already locked when the swap began (an item the game left greyed out): those never hold it up.
function W:AnyLocked(stale)
    if CursorHasItem and CursorHasItem() then return true end
    for k in pairs(self:LockedPlaces()) do
        if not (stale and stale[k]) then return true end
    end
    return false
end

-- Wears an outfit (an id or an outfit table: a rule's way back). why = "rule" keeps it quiet unless something is
-- left out. Returns "done" | "retry" (some moves wait for a short retry) | "queued" (all after the fight) |
-- "demo" | "dead" | nil (no such outfit).
function W:Wear(o, why)
    if type(o) ~= "table" then o = self:Get(o) end
    if not o then return nil end
    if o.demo or Demo() then
        for _, x in ipairs(self:DemoList()) do x.wearing = (x == o) end
        local _, c = self:Status(o)
        Say(("Demo: %s would swap %d slots. Nothing was equipped."):format(o.name, c.swap + c.bank))
        Changed()
        return "demo"
    end
    local b = Blocked()
    if b == "dead" then
        Say("You can't change gear while dead.")
        return "dead"
    elseif b == "casting" then
        W.queued = { o = o, why = why }
        ns.Util.After(0.5, function() W:RunQueued() end)
        return "queued"
    end
    W.queued = nil
    if job then
        -- a swap is still running: this one goes next (the last click wins), never on top of it
        job.next = { o = o, why = why }
        return "busy"
    end
    job = { o = o, why = why, passes = 0, waits = 0, failed = {}, moved = {}, pulled = 0, combat = b == "combat",
        stale = self:LockedPlaces() }
    return self:Pass()
end

function W:RunQueued()
    local q = W.queued
    if not q or job then return end
    local b = Blocked()
    if b == "casting" then ns.Util.After(0.5, function() W:RunQueued() end) end
    if b then return end
    W.queued = nil
    self:Wear(q.o, q.why)
end

-- One pass: every move that can be made now, in this frame.
function W:Pass()
    local j = job
    if not j then return end
    -- the game is still moving something (an earlier pass, the player's own drag): wait, never move on top of it
    if self:AnyLocked(j.stale) then
        j.waits = j.waits + 1
        if j.waits <= WAITS then
            ns.Util.After(RETRY, function() if job == j then W:Pass() end end)
            return "retry"
        end
        j.stuckLocks = true
        return self:Finish(self:Resolve(j.o))
    end
    j.waits = 0
    j.passes = j.passes + 1
    local combat = InCombatLockdown and InCombatLockdown() or false
    local scan = self:Scan()
    local res = self:Resolve(j.o, scan)
    -- the model: what is where, and what is locked (by the client, or moved in this pass)
    local cont, locked, booked = {}, {}, {}
    for inv, e in pairs(scan.worn) do
        e.place = { inv = inv }
        cont["i" .. inv] = e
        if IsInventoryItemLocked and IsInventoryItemLocked(inv) then locked["i" .. inv] = true end
    end
    for _, list in ipairs({ scan.bags, scan.bankLive and scan.bank or {} }) do
        for _, e in ipairs(list) do
            if e.bag then
                e.place = { bag = e.bag, slot = e.slot }
                cont[PlaceKey(e.place)] = e
                if e.locked then locked[PlaceKey(e.place)] = true end
            end
        end
    end
    local function where(e)
        for k, x in pairs(cont) do if x == e then return k end end
    end
    local function place(k)
        local inv = k:match("^i(%d+)$")
        if inv then return { inv = tonumber(inv) } end
        local bag, slot = k:match("^b(%-?%d+):(%d+)$")
        return { bag = tonumber(bag), slot = tonumber(slot) }
    end
    local waiting, later = false, false
    local function move(a, b)
        if W.Move(place(a), place(b)) == false then
            waiting = true                                           -- (refused: the next pass looks again)
            return false
        end
        cont[a], cont[b] = cont[b], cont[a]
        locked[a], locked[b] = true, true
        return true
    end
    local order = { 16, 17 }
    for _, inv in ipairs(W.SLOTS) do if inv ~= 16 and inv ~= 17 then order[#order + 1] = inv end end
    for _, inv in ipairs(order) do
        local r = res[inv]
        local t = "i" .. inv
        local act = r.st == "swap" or (r.st == "bank" and scan.bankLive)
        if act and not j.failed[inv] then
            if combat and not IN_COMBAT[inv] then
                later = true                                         -- (armour and jewellery: after the fight)
            elseif r.empty then
                if cont[t] then
                    local free = self:FreeBagSlot(cont, booked)
                    if not free then j.failed[inv] = "bags"
                    elseif locked[t] then waiting = true
                    else
                        local fk = PlaceKey(free)
                        booked[fk] = true
                        move(t, fk)
                    end
                end
            elseif cont[t] and r.want and Match(cont[t], r.want) == 2 then
                -- (already there: an earlier move of this pass put it in, e.g. two rings trading places)
            else
                local from = r.src and where(r.src)
                if not from then
                    waiting = true                                   -- (moved since the scan: next pass finds it)
                elseif locked[from] or locked[t] then
                    waiting = true
                elseif from:sub(1, 1) == "b" and IsBankBag(place(from).bag) then
                    -- out of the bank into my bags first; it goes on in the next pass
                    local free = self:FreeBagSlot(cont, booked)
                    if not free then j.failed[inv] = "bags"
                    else
                        local fk = PlaceKey(free)
                        booked[fk] = true
                        move(from, fk)
                        j.pulled = j.pulled + 1
                        waiting = true
                    end
                elseif inv == 16 and W.IsTwoHand(r.want.id) and cont.i17 then
                    -- a two-hander coming in: this pass only takes the off hand off (to a free bag slot); the
                    -- two-hander goes on in the next one. Both at once makes the game unequip the off hand a second
                    -- time on its own ("Internal bag error", items left locked).
                    local free = (not locked.i17) and self:FreeBagSlot(cont, booked)
                    if locked.i17 then waiting = true
                    elseif not free then j.failed[16] = "bags"
                    else
                        local fk = PlaceKey(free)
                        booked[fk] = true
                        move("i17", fk)
                        waiting = true
                    end
                elseif inv == 17 and scan.worn[16] and W.IsTwoHand(scan.worn[16].id) then
                    waiting = true                     -- (the game still has the two-hander on: after it is off)
                else
                    if move(from, t) then j.moved[inv] = true end
                end
            end
        end
    end
    j.later = later
    if waiting or next(locked) then
        -- the client applies the moves a moment later: look again once it has (then retry what is left)
        j.settle = 0
        ns.Util.After(SETTLE, function() if job == j then W:Settle() end end)
        Changed()
        return "retry"
    end
    return self:Finish(self:Resolve(j.o))
end

-- After a pass: wait for the client's locks to clear, then check; a slot that still differs gets another pass.
function W:Settle()
    local j = job
    if not j then return end
    j.settle = j.settle + 1
    -- (bag items too: a retry must not pick a bag slot the server is still filling)
    if self:AnyLocked(j.stale) and j.settle < WAITS then
        ns.Util.After(RETRY, function() if job == j then W:Settle() end end)
        return
    end
    local res = self:Resolve(j.o)
    local left = false
    for _, inv in ipairs(W.SLOTS) do
        local r = res[inv]
        if not j.failed[inv] and (r.st == "swap" or (r.st == "bank" and self.bankOpen))
            and not (j.later and not IN_COMBAT[inv]) then left = true end
    end
    if left and j.passes < RETRIES then return self:Pass() end
    return self:Finish(res)
end

local function NameOf(id)
    local n = id and ((ns.ItemDB and ns.ItemDB.GetName and ns.ItemDB:GetName(id)) or (GetItemInfo and GetItemInfo(id)))
    return n or ("item " .. tostring(id))
end

-- Ends the swap and says how it went: what swapped, what waits for the fight, what is missing or in the bank.
function W:Finish(res)
    local j = job
    job = nil
    if not j then return end
    local swapped, notes, failed = 0, {}, {}
    for _ in pairs(j.moved) do swapped = swapped + 1 end
    local missing, bank, bags = {}, {}, {}
    for _, inv in ipairs(W.SLOTS) do
        local r = res[inv]
        local name = W.SLOT_NAME[inv]
        if r.st == "missing" then missing[#missing + 1] = name
        elseif r.st == "bank" then bank[#bank + 1] = name
        elseif r.st == "swap" and not (j.later and not IN_COMBAT[inv]) then
            if j.failed[inv] == "bags" then bags[#bags + 1] = name else failed[#failed + 1] = name end
        end
    end
    if #bags > 0 then notes[#notes + 1] = tconcat(bags, ", ") .. " not swapped (bags full)" end
    if #failed > 0 then notes[#notes + 1] = tconcat(failed, ", ") .. " not swapped" end
    if #missing > 0 then notes[#notes + 1] = tconcat(missing, ", ") .. " missing" end
    if #bank > 0 then notes[#notes + 1] = tconcat(bank, ", ") .. " in the bank" end
    if j.later then
        W.queued = { o = j.o, why = j.why }
        notes[#notes + 1] = "armor goes on after combat"
    end
    if j.stuckLocks then notes[#notes + 1] = "the game still has items locked (log out and back in clears it)" end
    -- (a swap that worked says nothing: the bar's ring and the page show it)
    if #notes > 0 then Say(j.o.name .. ": " .. tconcat(notes, "; ") .. ".") end
    self.lastResult = { swapped = swapped, missing = #missing, bank = #bank, bagsFull = #bags > 0, later = j.later,
        stuck = #failed }
    W.current = j.o.id
    Changed()
    -- clicked another outfit while this one was going on: that one now
    if j.next then
        local n = j.next
        ns.Util.After(0, function() W:Wear(n.o, n.why) end)
    end
    return j.later and "queued" or "done"
end

function W:Running() return job end

-- The outfit after the one I wear (the "Next outfit" key).
function W:WearNext()
    local list = self:List()
    if #list == 0 then return end
    local cur = self:Wearing()
    local at = 0
    for i, o in ipairs(list) do if o == cur then at = i end end
    return self:Wear(list[at % #list + 1].id)
end

---------------------------------------------------------------------------
-- Wear automatically
---------------------------------------------------------------------------
-- What a rule took off, to put back when it ends: active[rule] = { o (the outfit it wore), back (an outfit) }.
W.active = {}
local lastSpec, lastWorn

-- The slots an outfit changes, as worn before it (from `worn`, a W:WornSlots(); default now).
local function BackOf(o, worn)
    worn = worn or W:WornSlots()
    local slots = {}
    for inv, v in pairs(o.slots or {}) do
        if v ~= nil then slots[inv] = worn[inv] end
    end
    return { id = "back", name = "What you wore before", slots = slots, rules = {} }
end

local function RuleOutfit(key, test)
    for _, o in ipairs(W:List()) do
        local v = o.rules and o.rules[key]
        if v ~= nil and (not test or test(v)) then return o end
    end
end

local function Begin(key, o, worn)
    if W.active[key] then return end
    W.active[key] = { o = o, back = BackOf(o, worn) }
    W:Wear(o, "rule")
end

local function Finish(key, keep)
    local a = W.active[key]
    if not a then return end
    W.active[key] = nil
    for inv in pairs(keep or {}) do a.back.slots[inv] = nil end
    W:Wear(a.back, "rule")
end
W.EndRule = Finish

function W:CheckSpec(quiet)
    local spec = ns.BiS and ns.BiS.DetectSpec and ns.BiS:DetectSpec() or ""
    if spec == "" then return end
    local was = lastSpec
    lastSpec = spec
    if quiet or was == nil or was == spec or Demo() then return end
    local o = RuleOutfit("spec", function(v) return v == spec end)
    if o then self:Wear(o, "rule") end
end

function W:CheckTarget()
    if Demo() then return end
    local name = UnitName and UnitName("target")
    if not name or (UnitIsDead and UnitIsDead("target")) then return end
    local o = RuleOutfit("boss", function(v) return v.kind ~= "zone" and v.name == name end)
    if o then Begin("boss", o) end
end

function W:CheckZone()
    if Demo() then return end
    local zone = GetRealZoneText and GetRealZoneText() or ""
    local o = RuleOutfit("boss", function(v) return v.kind == "zone" and v.name == zone end)
    if o then Begin("zone", o)
    elseif W.active.zone then Finish("zone") end
    -- (leaving the boss's place ends its rule too)
    local a = W.active.boss
    if a and a.zone and a.zone ~= zone then Finish("boss") end
    if W.active.boss and not W.active.boss.zone then W.active.boss.zone = zone end
end

function W:OnEncounterEnd(success)
    if success == 1 or success == true then Finish("boss") end
end

-- After a fight: the targeted boss is dead -> back.
function W:CheckBossDead()
    local a = W.active.boss
    if not a then return end
    local b = a.o.rules and a.o.rules.boss
    if b and UnitName and UnitName("target") == b.name and UnitIsDead and UnitIsDead("target") then Finish("boss") end
end

function W:CheckPole()
    if Demo() or job then return end
    local mh = tonumber((GetInventoryItemID("player", 16)))
    if mh and W.IsPole(mh) then
        local o = RuleOutfit("pole")
        if o and not W.active.pole then Begin("pole", o, lastWorn) end
    else
        -- (the pole came off: back, the weapon they put on stays)
        if W.active.pole then Finish("pole", mh and { [16] = true, [17] = true } or nil) end
        lastWorn = W:WornSlots()
    end
end

-- What I wear without a pole in hand (the pole rule's way back), kept while no swap runs.
function W:NoteWorn()
    if job then return end
    local mh = tonumber((GetInventoryItemID("player", 16)))
    if not (mh and W.IsPole(mh)) then lastWorn = W:WornSlots() end
end

function W:CheckMount()
    if Demo() then return end
    local m = IsMounted and IsMounted() or false
    if m then
        local o = RuleOutfit("mount")
        if o then Begin("mount", o) end
    elseif W.active.mount then
        Finish("mount")
    end
end

---------------------------------------------------------------------------
-- Demo outfits (the mockup's: a Ret paladin's four outfits; made up, shown for any class)
---------------------------------------------------------------------------
local I = "Interface\\Icons\\"
W.DEMO_WORN = { [1] = 29073, [2] = 28745, [3] = 29075, [15] = 24259, [5] = 29071, [9] = 28795, [10] = 30644,
    [6] = 28779, [7] = 30538, [8] = 28608, [11] = 28757, [12] = 30834, [13] = 29383, [14] = 28830, [16] = 28429,
    [17] = false, [18] = 27484 }

-- (a demo outfit's slots as W:Resolve gives them, from its made-up bank / missing marks)
function W.DemoResolve(o)
    local out, c = {}, { worn = 0, swap = 0, bank = 0, missing = 0, keep = 0 }
    for _, inv in ipairs(W.SLOTS) do
        local want = o.slots[inv]
        local cur = W.DEMO_WORN[inv]
        local r
        if want == nil then r = { st = "keep", id = cur or nil }
        elseif want == false then r = { st = cur and "swap" or "worn", empty = true }
        elseif o.demoBank and o.demoBank[inv] then r = { st = "bank", id = want.id }
        elseif o.demoMissing and o.demoMissing[inv] then r = { st = "missing", id = want.id }
        elseif want.id == cur then r = { st = "worn", id = want.id }
        else r = { st = "swap", id = want.id } end
        out[inv] = r
        c[r.st] = c[r.st] + 1
    end
    return out, c
end

local function DemoOutfit(t, items)
    t.demo = true
    t.slots = {}
    for _, inv in ipairs(W.SLOTS) do
        local v = items[inv]
        if v == nil then v = W.DEMO_WORN[inv] end
        if v == "keep" then t.slots[inv] = nil
        elseif v == false then t.slots[inv] = false
        else t.slots[inv] = { id = v } end
    end
    t.demoSlots, t.demoCounts = W.DemoResolve(t)
    return t
end

local demoList
function W:DemoList()
    if demoList then return demoList end
    demoList = {
        DemoOutfit({ id = "ret", name = "Raid \226\128\148 Retribution", icon = I .. "Spell_Holy_AuraOfLight",
            art = "Karazhan", wearing = true, rules = { spec = "Retribution" } }, {}),
        DemoOutfit({ id = "prot", name = "Tank \226\128\148 Protection", icon = I .. "Spell_Holy_DevotionAura",
            art = "GruulsLair", rules = { spec = "Protection" }, demoBank = { [16] = true } },
            { [1] = 29068, [3] = 29070, [15] = 28660, [5] = 29066, [9] = 29252, [10] = 29067, [6] = 30034,
              [7] = 29069, [8] = 33523, [12] = 29279, [13] = 28528, [14] = "keep", [16] = 28749, [17] = 28825,
              [18] = 29388 }),
        DemoOutfit({ id = "hydross", name = "Hydross \226\128\148 Nature res", icon = I .. "Spell_Nature_ResistNature",
            art = "SerpentshrineCavern", rules = { boss = { kind = "boss", name = "Hydross the Unstable" } },
            demoMissing = { [5] = true } },
            { [1] = 29508, [5] = 31364, [7] = 31367, [13] = "keep", [14] = "keep" }),
        DemoOutfit({ id = "fish", name = "Fishing", icon = I .. "Trade_Fishing", art = "nagrand",
            rules = { pole = true } },
            { [2] = "keep", [3] = "keep", [15] = "keep", [5] = "keep", [9] = "keep", [10] = "keep", [6] = "keep",
              [7] = "keep", [8] = "keep", [11] = "keep", [12] = "keep", [13] = "keep", [14] = "keep", [18] = "keep",
              [1] = 33820, [16] = 19970, [17] = false }),
    }
    return demoList
end

-- The quick-swap bar's switch (per character; demo: the Demo page's outfit bar part).
function W:BarOn()
    if Demo() then return ns.Demo:IsOn("outfits") end
    local st = Store(false)
    return st and st.bar and true or false
end

function W:SetBar(on)
    if Demo() then ns.Demo:SetOn("outfits", on)
    else
        local st = Store(true)
        if not st then return end
        st.bar = on and true or nil
    end
    Changed()
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function W:OnLogin()
    local U = ns.Util
    local function refresh() U.Debounce("wardrobe-refresh", 0.2, Changed) end
    ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function(_, inv)
        refresh()
        if inv == 16 then U.Debounce("wardrobe-pole", 0.3, function() W:CheckPole() end) end
        U.Debounce("wardrobe-worn", 0.6, function() W:NoteWorn() end)
    end)
    ns:RegisterEvent("BAG_UPDATE_DELAYED", function()
        if W.bankOpen then W:CacheBank() end
        refresh()
    end)
    ns:RegisterEvent("BANKFRAME_OPENED", function() W.bankOpen = true; W:CacheBank(); refresh() end)
    ns:RegisterEvent("PLAYERBANKSLOTS_CHANGED", function()
        U.Debounce("wardrobe-bank", 0.2, function() W:CacheBank(); Changed() end)
    end)
    ns:RegisterEvent("BANKFRAME_CLOSED", function() W.bankOpen = false; refresh() end)  -- (kept as last seen)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        W:CheckBossDead()
        ns.Util.After(0.2, function() W:RunQueued() end)
    end)
    ns:RegisterEvent("PLAYER_ALIVE", function() W:RunQueued() end)
    ns:RegisterEvent("PLAYER_UNGHOST", function() W:RunQueued() end)
    local function spec() U.Debounce("wardrobe-spec", 1, function() W:CheckSpec() end) end
    ns:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", spec)   -- (skipped where the client has no dual spec)
    ns:RegisterEvent("PLAYER_TALENT_UPDATE", spec)
    ns:RegisterEvent("CHARACTER_POINTS_CHANGED", spec)
    ns:RegisterEvent("PLAYER_TARGET_CHANGED", function() W:CheckTarget() end)
    ns:RegisterEvent("ENCOUNTER_END", function(_, _, _, _, _, success) W:OnEncounterEnd(success) end)
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", function() W:CheckZone() end)
    local function mount() U.Debounce("wardrobe-mount", 0.4, function() W:CheckMount() end) end
    ns:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED", mount)
    ns:RegisterEvent("UNIT_AURA", function(_, unit) if unit == "player" then mount() end end)
    ns:On("DEMO_TOGGLED", Changed)
    ns:On("DEMO_PARTS_CHANGED", function(key) if key == "outfits" or key == "stop" then Changed() end end)
    ns.Util.After(3, function()
        W:CheckSpec(true)
        lastWorn = W:WornSlots()
    end)
end

-- (the key binding: Bindings.xml)
function DisasterZone_WardrobeNext() W:WearNext() end
BINDING_HEADER_DISASTERZONE = BINDING_HEADER_DISASTERZONE or "DisasterZone"
BINDING_NAME_DISASTERZONE_WARDROBENEXT = "Wear the next outfit"

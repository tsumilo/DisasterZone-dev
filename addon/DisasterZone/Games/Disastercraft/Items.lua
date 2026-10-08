if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/Items.lua", ...) then return end -- DisasterZone Games/Disastercraft/Items.lua
-- Craft.Items: the backpack and bags, the equipment (WoW's 19 inventory slots), using items, vendors.
-- Bags: char.bags[0] = the backpack (16 slots); bags[1..4] = the bags in the bag slots ({ item = id, size = n });
-- each holds [slot] = { id = item, n = count }. Equipment: char.equip[slot] = item id.
local addonName, ns = ...

local Craft = ns.Craft
local D = Craft.D
local Items = {}
Craft.Items = Items

local floor, max, min = math.floor, math.max, math.min

-- WoW's inventory slots
Items.SLOTS = { HEAD = 1, NECK = 2, SHOULDER = 3, SHIRT = 4, CHEST = 5, WAIST = 6, LEGS = 7, FEET = 8, WRIST = 9,
                HANDS = 10, FINGER1 = 11, FINGER2 = 12, TRINKET1 = 13, TRINKET2 = 14, BACK = 15, MAINHAND = 16,
                OFFHAND = 17, RANGED = 18, TABARD = 19 }
Items.SLOT_NAMES = { "Head", "Neck", "Shoulder", "Shirt", "Chest", "Waist", "Legs", "Feet", "Wrist", "Hands",
                     "Finger", "Finger", "Trinket", "Trinket", "Back", "Main Hand", "Off Hand", "Ranged", "Tabard" }
-- the empty-slot pictures of the character window
Items.SLOT_ART = { "Head", "Neck", "Shoulder", "Shirt", "Chest", "Waist", "Legs", "Feet", "Wrists", "Hands",
                   "Finger", "Finger", "Trinket", "Trinket", "Chest", "MainHand", "SecondaryHand", "Ranged",
                   "Tabard" }

-- InventoryType -> slots it may go in
local INV_SLOTS = {
    [1] = { 1 }, [2] = { 2 }, [3] = { 3 }, [4] = { 4 }, [5] = { 5 }, [20] = { 5 }, [6] = { 6 }, [7] = { 7 },
    [8] = { 8 }, [9] = { 9 }, [10] = { 10 }, [11] = { 11, 12 }, [12] = { 13, 14 }, [16] = { 15 },
    [13] = { 16 }, [17] = { 16 }, [21] = { 16 }, [22] = { 17 }, [14] = { 17 }, [23] = { 17 },
    [15] = { 18 }, [26] = { 18 }, [25] = { 18 }, [28] = { 18 }, [19] = { 19 },
}
Items.INV_SLOTS = INV_SLOTS
Items.INV_NAMES = { [1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt", [5] = "Chest", [6] = "Waist",
    [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands", [11] = "Finger", [12] = "Trinket", [13] = "One-Hand",
    [14] = "Off Hand", [15] = "Ranged", [16] = "Back", [17] = "Two-Hand", [18] = "Bag", [19] = "Tabard",
    [20] = "Chest", [21] = "Main Hand", [22] = "Off Hand", [23] = "Held In Off-hand", [25] = "Thrown",
    [26] = "Ranged", [28] = "Relic" }

-- what each class may wear and wield from the start (playercreateinfo skills; weapon masters come later)
-- armour subclasses (class 4): 0 misc, 1 cloth, 2 leather, 3 mail, 4 plate, 6 shield
-- weapon subclasses (class 2): 0 axe, 1 2h axe, 2 bow, 3 gun, 4 mace, 5 2h mace, 6 polearm, 7 sword, 8 2h sword,
-- 10 staff, 13 fist, 14 misc, 15 dagger, 16 thrown, 18 crossbow, 19 wand, 20 fishing pole
Items.PROFICIENT = {
    [1] = { armor = { [0] = true, [1] = true, [2] = true, [3] = true, [6] = true },
            weapon = { [0] = true, [4] = true, [7] = true, [13] = true, [14] = true, [16] = true, [20] = true } },
    [5] = { armor = { [0] = true, [1] = true }, weapon = { [4] = true, [14] = true, [19] = true, [20] = true } },
    [8] = { armor = { [0] = true, [1] = true }, weapon = { [10] = true, [14] = true, [19] = true, [20] = true } },
}
Items.WEAPON_NAMES = { [0] = "Axe", [1] = "Axe", [2] = "Bow", [3] = "Gun", [4] = "Mace", [5] = "Mace",
    [6] = "Polearm", [7] = "Sword", [8] = "Sword", [10] = "Staff", [13] = "Fist Weapon", [14] = "Miscellaneous",
    [15] = "Dagger", [16] = "Thrown", [18] = "Crossbow", [19] = "Wand", [20] = "Fishing Pole" }
Items.ARMOR_NAMES = { [0] = "Miscellaneous", [1] = "Cloth", [2] = "Leather", [3] = "Mail", [4] = "Plate",
                      [6] = "Shield" }
Items.QUALITY_COLORS = { [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00", [3] = "0070dd", [4] = "a335ee", [5] = "ff8000" }
Items.QUALITY_RGB = { [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 },
                      [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 } }
-- stat_type -> unit field
Items.STAT_FIELD = { [1] = "hpBonus", [2] = "manaBonus", [3] = "agi", [4] = "str", [5] = "int", [6] = "spi",
                     [7] = "sta", [12] = "defense", [13] = "dodgeR", [14] = "parryR", [15] = "blockR",
                     [16] = "hitR", [18] = "hitR", [19] = "critR", [20] = "critR", [21] = "spellCritR",
                     [31] = "hitR", [32] = "critR", [36] = "hasteR", [38] = "ap", [45] = "sp" }

function Items.Info(id) return D.items[id] end

function Items.Link(id, count)
    local it = D.items[id]
    if not it then return "[Item " .. tostring(id) .. "]" end
    local s = "|cff" .. (Items.QUALITY_COLORS[it.q] or "ffffff") .. "[" .. it.n .. "]|r"
    if count and count > 1 then s = s .. "x" .. count end
    return s
end

function Items.Icon(id)
    local it = D.items[id]
    if it and it.icon then return it.icon end
    if C_Item and C_Item.GetItemIconByID then
        local ok, icon = pcall(C_Item.GetItemIconByID, id)
        if ok and icon then return icon end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

---------------------------------------------------------------------------
-- Equipping
---------------------------------------------------------------------------

function Items.CanEquip(it, c)
    c = c or Craft.char
    if not it or not it.inv or not INV_SLOTS[it.inv] then return false, "You can't equip that." end
    if it.req and it.req > (c.level or 1) then
        return false, string.format("You must reach level %d to use that item.", it.req)
    end
    if it.cls and Craft.CLASS_MASK[c.class] and bit and bit.band(it.cls, Craft.CLASS_MASK[c.class]) == 0 then
        return false, "Your class can't use that item."
    end
    local prof = Items.PROFICIENT[c.class]
    if prof then
        if it.c == 4 and not prof.armor[it.s or 0] then return false, "You do not have the required proficiency for that item." end
        if it.c == 2 and not prof.weapon[it.s or 0] then return false, "You do not have the required proficiency for that item." end
    end
    return true
end

-- the slot an item would go in (a free one of two rings / trinkets first)
function Items.SlotFor(it, c)
    c = c or Craft.char
    local slots = it and it.inv and INV_SLOTS[it.inv]
    if not slots then return nil end
    if not Items.CanEquip(it, c) then return nil end
    for _, s in ipairs(slots) do
        if not c.equip[s] then return s end
    end
    return slots[1]
end

local function TwoHanded(id)
    local it = id and D.items[id]
    return it and it.inv == 17
end

---------------------------------------------------------------------------
-- Bags
---------------------------------------------------------------------------

local function Bag(c, b) return c.bags[b] end

-- every bag that exists: 0 (backpack), then the equipped bags
function Items.BagList(c)
    c = c or Craft.char
    local out = { 0 }
    for b = 1, 4 do if c.bags[b] and c.bags[b].item then out[#out + 1] = b end end
    return out
end

function Items.BagSize(b, c)
    c = c or Craft.char
    local bag = c.bags[b]
    return bag and bag.size or 0
end

function Items.Get(b, s, c)
    c = c or Craft.char
    local bag = c.bags[b]
    return bag and bag[s]
end

function Items.Count(id, c)
    c = c or Craft.char
    local n = 0
    for _, b in ipairs(Items.BagList(c)) do
        local bag = c.bags[b]
        for s = 1, bag.size do
            local x = bag[s]
            if x and x.id == id then n = n + x.n end
        end
    end
    return n
end

function Items.FreeSlots(c)
    c = c or Craft.char
    local n = 0
    for _, b in ipairs(Items.BagList(c)) do
        local bag = c.bags[b]
        for s = 1, bag.size do if not bag[s] then n = n + 1 end end
    end
    return n
end

-- puts count of id in the bags (stacks first); returns how many did not fit
function Items.Add(id, count, why, c)
    c = c or Craft.char
    local it = D.items[id]
    if not it or not c then return count end
    count = count or 1
    local left = count
    local stack = it.stack or 1
    if it.unique and it.unique > 0 and Items.Count(id, c) + Items.EquippedCount(id, c) >= it.unique then
        Craft:Error("You can't carry any more of those items.")
        return count
    end
    local bags = Items.BagList(c)
    if stack > 1 then
        for _, b in ipairs(bags) do
            local bag = c.bags[b]
            for s = 1, bag.size do
                local x = bag[s]
                if x and x.id == id and x.n < stack and left > 0 then
                    local put = min(stack - x.n, left)
                    x.n = x.n + put
                    left = left - put
                end
            end
        end
    end
    for _, b in ipairs(bags) do
        local bag = c.bags[b]
        for s = 1, bag.size do
            if left <= 0 then break end
            if not bag[s] then
                local put = min(stack, left)
                bag[s] = { id = id, n = put }
                left = left - put
            end
        end
    end
    local got = count - left
    if got > 0 then
        if why ~= "silent" and c == Craft.char then
            local verb = (why == "buy" and "You receive item: ") or (why == "create" and "You create: ")
                         or (why == "quest" and "You receive item: ") or "You receive loot: "
            Craft:Msg(verb .. Items.Link(id) .. (got > 1 and ("x" .. got) or "") .. ".", "loot")
        end
        Craft:Emit("item", id, got)
    end
    if left > 0 and why ~= "silent" then Craft:Error("Inventory is full.") end
    return left
end

function Items.EquippedCount(id, c)
    c = c or Craft.char
    local n = 0
    for _, x in pairs(c.equip) do if x == id then n = n + 1 end end
    return n
end

-- takes count of id out of the bags (from the last slots first); returns how many were taken
function Items.Remove(id, count, c)
    c = c or Craft.char
    local left = count or 1
    local bags = Items.BagList(c)
    for i = #bags, 1, -1 do
        local bag = c.bags[bags[i]]
        for s = bag.size, 1, -1 do
            local x = bag[s]
            if x and x.id == id and left > 0 then
                local take = min(x.n, left)
                x.n = x.n - take
                left = left - take
                if x.n <= 0 then bag[s] = nil end
            end
        end
    end
    if left < (count or 1) then Craft:Emit("item", id, -((count or 1) - left)) end
    return (count or 1) - left
end

function Items.Destroy(b, s)
    local c = Craft.char
    local x = Items.Get(b, s)
    if not x then return end
    c.bags[b][s] = nil
    Craft:Emit("item", x.id, -x.n)
end

-- moves / merges / swaps two bag slots (count = a split, nil = all)
function Items.Move(b1, s1, b2, s2, count)
    local c = Craft.char
    local A, B = c.bags[b1], c.bags[b2]
    if not A or not B or s2 > B.size then return false end
    local x, y = A[s1], B[s2]
    if not x then return false end
    if b1 == b2 and s1 == s2 then return false end
    -- a bag can't go into itself
    if b2 > 0 and c.bags[b2].bagFrom and false then return false end
    count = count and min(count, x.n) or x.n
    if y and y.id == x.id then
        local stack = (D.items[x.id] and D.items[x.id].stack) or 1
        local put = min(stack - y.n, count)
        if put <= 0 then                                   -- (a full stack: swap)
            A[s1], B[s2] = y, x
        else
            y.n = y.n + put
            x.n = x.n - put
            if x.n <= 0 then A[s1] = nil end
        end
    elseif y then
        if count < x.n then return false end               -- (a split onto another item: nothing)
        A[s1], B[s2] = y, x
    else
        if count < x.n then
            B[s2] = { id = x.id, n = count }
            x.n = x.n - count
        else
            A[s1], B[s2] = nil, x
        end
    end
    Craft:Emit("item")
    return true
end

---------------------------------------------------------------------------
-- Equipment
---------------------------------------------------------------------------

local function FirstFree(c)
    for _, b in ipairs(Items.BagList(c)) do
        local bag = c.bags[b]
        for s = 1, bag.size do if not bag[s] then return b, s end end
    end
end
Items.FirstFree = FirstFree

-- equips the item in bag slot (b, s) (into `slot` when given): the old one takes its place
function Items.EquipFromBag(b, s, slot)
    local c = Craft.char
    local x = Items.Get(b, s)
    if not x then return false end
    local it = D.items[x.id]
    if it and it.c == 1 and it.slots then                 -- a bag: into the first empty bag slot
        return Items.EquipBag(b, s)
    end
    local ok, why = Items.CanEquip(it, c)
    if not ok then Craft:Error(why) return false end
    if Craft.player and Craft.player.casting then Craft:Error("You are busy.") return false end
    if Craft.player and Craft.player.inCombat and not (it.inv == 13 or it.inv == 17 or it.inv == 21 or it.inv == 22
            or it.inv == 14 or it.inv == 23 or it.inv == 15 or it.inv == 26 or it.inv == 25) then
        Craft:Error("You can't do that while in combat.")      -- (only weapons swap in combat, like WoW)
        return false
    end
    slot = slot or Items.SlotFor(it, c)
    local allowed = false
    for _, sl in ipairs(INV_SLOTS[it.inv]) do if sl == slot then allowed = true end end
    if not allowed then Craft:Error("That item doesn't go in that slot.") return false end
    -- a two-hander takes the off hand off too; an off-hand item takes a two-hander off
    local alsoOff = it.inv == 17 and c.equip[17]
    local alsoMain = slot == 17 and TwoHanded(c.equip[16]) and c.equip[16]
    if (alsoOff or alsoMain) and Items.FreeSlots(c) < 1 and x.n == 1 then
        -- the item leaving the bag frees one slot, the old one takes it: needs one more
        if c.equip[slot] then Craft:Error("Inventory is full.") return false end
    end
    local old = c.equip[slot]
    c.bags[b][s] = nil
    if x.n > 1 then c.bags[b][s] = { id = x.id, n = x.n - 1 } end
    c.equip[slot] = x.id
    if old then
        if c.bags[b][s] then Items.Add(old, 1, "silent") else c.bags[b][s] = { id = old, n = 1 } end
    end
    if alsoOff then c.equip[17] = nil Items.Add(alsoOff, 1, "silent") end
    if alsoMain then c.equip[16] = nil Items.Add(alsoMain, 1, "silent") end
    Items.AfterGearChange()
    return true
end

-- takes the item in equipment slot `slot` off: into (b, s) when given, else the first free bag slot
function Items.Unequip(slot, b, s)
    local c = Craft.char
    local id = c.equip[slot]
    if not id then return false end
    if Craft.player and Craft.player.casting then Craft:Error("You are busy.") return false end
    if not b then b, s = FirstFree(c) end
    if not b then Craft:Error("Inventory is full.") return false end
    local there = c.bags[b][s]
    if there then
        -- a swap: the bag item must fit this slot
        local it = D.items[there.id]
        local fits = false
        for _, sl in ipairs(it and it.inv and INV_SLOTS[it.inv] or {}) do if sl == slot then fits = true end end
        if not fits or not Items.CanEquip(it, c) then
            b, s = FirstFree(c)
            if not b then Craft:Error("Inventory is full.") return false end
        else
            return Items.EquipFromBag(b, s, slot)
        end
    end
    c.equip[slot] = nil
    c.bags[b][s] = { id = id, n = 1 }
    Items.AfterGearChange()
    return true
end

-- a bag item into a free bag slot (1..4)
function Items.EquipBag(b, s, bagSlot)
    local c = Craft.char
    local x = Items.Get(b, s)
    local it = x and D.items[x.id]
    if not it or not it.slots then return false end
    if b > 0 and false then return false end
    if not bagSlot then
        for i = 1, 4 do if not (c.bags[i] and c.bags[i].item) then bagSlot = i break end end
    end
    if not bagSlot then Craft:Error("You have no free bag slot.") return false end
    if c.bags[bagSlot] and c.bags[bagSlot].item then Craft:Error("That bag slot is taken.") return false end
    if b == bagSlot then return false end
    c.bags[b][s] = nil
    c.bags[bagSlot] = { item = x.id, size = it.slots }
    Craft:Emit("item")
    return true
end

-- an empty bag out of its slot, into the bags
function Items.UnequipBag(bagSlot)
    local c = Craft.char
    local bag = c.bags[bagSlot]
    if not bag or not bag.item then return false end
    for s = 1, bag.size do
        if bag[s] then Craft:Error("You can only take off an empty bag.") return false end
    end
    local id = bag.item
    c.bags[bagSlot] = nil
    if Items.Add(id, 1, "silent") > 0 then
        c.bags[bagSlot] = bag
        return false
    end
    Craft:Emit("item")
    return true
end

function Items.AfterGearChange()
    local p = Craft.player
    if p then Craft.Combat.Recalc(p) end
    Craft:Emit("equip")
    Craft:Emit("item")
end

-- the summed stats of the gear on: { str, agi, ..., armor, dmg = { min, max, school }, spd = s, ranged = {...} }
function Items.GearStats(c)
    c = c or Craft.char
    local t = { str = 0, agi = 0, sta = 0, int = 0, spi = 0, armor = 0, block = 0, hpBonus = 0, manaBonus = 0,
                ap = 0, sp = 0, hitR = 0, critR = 0, spellCritR = 0, defense = 0, dodgeR = 0, parryR = 0, blockR = 0,
                res = { 0, 0, 0, 0, 0, 0 } }
    for slot, id in pairs(c.equip) do
        local it = D.items[id]
        if it then
            t.armor = t.armor + (it.armor or 0)
            if slot == 17 and it.block then t.block = t.block + it.block end
            local st = it.stats
            if st then
                for i = 1, #st, 2 do
                    local f = Items.STAT_FIELD[st[i]]
                    if f then t[f] = (t[f] or 0) + st[i + 1] end
                end
            end
            if it.res then for i = 1, 6 do t.res[i] = t.res[i] + it.res[i] end end
            if slot == 16 and it.dmg then t.mh = { it.dmg[1], it.dmg[2], it.dmg[3], (it.spd or 2000) / 1000, it.s } end
            if slot == 17 and it.dmg then t.oh = { it.dmg[1], it.dmg[2], it.dmg[3], (it.spd or 2000) / 1000, it.s } end
            if slot == 18 and it.dmg then t.ranged = { it.dmg[1], it.dmg[2], it.dmg[3], (it.spd or 2000) / 1000, it.s } end
        end
    end
    return t
end

---------------------------------------------------------------------------
-- Using items: gear goes on, food / drink / potions cast their spell, a bag goes in a bag slot
---------------------------------------------------------------------------

function Items.Use(b, s)
    local c = Craft.char
    local x = Items.Get(b, s)
    if not x then return false end
    local it = D.items[x.id]
    if not it then return false end
    if Craft.player and Craft.player.dead then Craft:Error("You are dead.") return false end
    if it.slots and it.c == 1 then return Items.EquipBag(b, s) end
    if it.inv and INV_SLOTS[it.inv] then return Items.EquipFromBag(b, s) end
    if it.quest and Craft.Quests then return Craft.Quests.OfferFromItem(x.id) end
    for _, sp in ipairs(it.spells or {}) do
        if sp[2] == 0 then                                -- "Use:"
            if it.req and it.req > c.level then
                Craft:Error(string.format("You must reach level %d to use that item.", it.req))
                return false
            end
            return Craft.Combat.CastSpell(Craft.player, sp[1], nil, { item = x.id, b = b, s = s, itemCd = sp })
        end
    end
    Craft:Error("You can't use that item.")
    return false
end

-- after an item's spell went off: charges of -1 = the item is used up (food, potions)
function Items.Consume(opts)
    local sp = opts and opts.itemCd
    if not sp then return end
    if (sp[3] or 0) < 0 or (sp[3] or 0) > 0 then Items.Remove(opts.item, 1) end
end

-- the action bar's item buttons use the first stack of that item in the bags
function Items.UseById(id)
    local c = Craft.char
    for _, b in ipairs(Items.BagList(c)) do
        local bag = c.bags[b]
        for s = 1, bag.size do
            if bag[s] and bag[s].id == id then return Items.Use(b, s) end
        end
    end
    Craft:Error("You don't have that item.")
    return false
end

---------------------------------------------------------------------------
-- Vendors: buy (in the vendor's stack size), sell (the item's sell price), buy back the last twelve sold
---------------------------------------------------------------------------

Items.buyback = {}

function Items.BuyPrice(id)
    local it = D.items[id]
    return it and it.buy or 0
end

function Items.Buy(id, stacks)
    local it = D.items[id]
    if not it then return false end
    stacks = max(1, stacks or 1)
    local per = it.bc or 1
    local price = (it.buy or 0) * stacks
    if Craft:Money() < price then Craft:Error("You don't have enough money.") return false end
    local want = per * stacks
    -- make sure it fits before taking the money
    local room = 0
    local stack = it.stack or 1
    local c = Craft.char
    for _, b in ipairs(Items.BagList(c)) do
        local bag = c.bags[b]
        for s = 1, bag.size do
            local x = bag[s]
            if not x then room = room + stack
            elseif x.id == id then room = room + max(0, stack - x.n) end
        end
    end
    if room < want then Craft:Error("Inventory is full.") return false end
    Craft:AddMoney(-price, "silent")
    Items.Add(id, want, "buy")
    return true
end

function Items.Sell(b, s)
    local x = Items.Get(b, s)
    if not x then return false end
    local it = D.items[x.id]
    if not it or not it.sell or it.sell <= 0 then Craft:Error("The merchant doesn't want that item.") return false end
    local c = Craft.char
    c.bags[b][s] = nil
    Craft:AddMoney(it.sell * x.n, "silent")
    table.insert(Items.buyback, 1, { id = x.id, n = x.n, price = it.sell * x.n })
    while #Items.buyback > 12 do table.remove(Items.buyback) end
    Craft:Emit("item", x.id, -x.n)
    Craft:Emit("sold", x.id, x.n)
    return true
end

function Items.BuyBack(i)
    local e = Items.buyback[i]
    if not e then return false end
    if Craft:Money() < e.price then Craft:Error("You don't have enough money.") return false end
    if Items.FreeSlots() < 1 then Craft:Error("Inventory is full.") return false end
    table.remove(Items.buyback, i)
    Craft:AddMoney(-e.price, "silent")
    Items.Add(e.id, e.n, "silent")
    return true
end

-- sell every grey item at once (the vendor window's shortcut)
function Items.SellJunk()
    local c = Craft.char
    local total = 0
    for _, b in ipairs(Items.BagList(c)) do
        local bag = c.bags[b]
        for s = 1, bag.size do
            local x = bag[s]
            local it = x and D.items[x.id]
            if it and it.q == 0 and (it.sell or 0) > 0 then
                total = total + it.sell * x.n
                Items.Sell(b, s)
            end
        end
    end
    return total
end

Craft:On("login", function(c)
    Items.buyback = {}
end)

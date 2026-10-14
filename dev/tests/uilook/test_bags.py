#!/usr/bin/env python
"""Bags (UI/LookBags.lua, Settings > UI > Bags): the bags, the key ring and the bank in the part's look, in three
layouts (One bag the default, Shelves, Bag by bag). The slots are the game's item buttons in holders carrying the
bag's id; B and the bag slots open ours; the bank opens ours instead of the game's; search, tags, junk.

Run: luaenv\\Scripts\\python.exe tests\\uilook\\test_bags.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

from _common import case, run_all, solo  # noqa: E402

# a Ret paladin's bags: backpack 16, bag 1 of 16; potions, a trinket, cloth, a grey; two keys on the ring
ITEMS = """
    local D = __MOCK.define_item
    D(28830, 'Dragonspine Trophy', 4, 'INVTYPE_TRINKET', 4, 0, 'Interface\\\\Icons\\\\INV_Misc_Bone_10')
    D(22838, 'Haste Potion', 1, 'INVTYPE_NON_EQUIP_IGNORE', 0, 1, 'Interface\\\\Icons\\\\INV_Potion_108')
    D(21877, 'Netherweave Cloth', 1, 'INVTYPE_NON_EQUIP_IGNORE', 7, 5, 'Interface\\\\Icons\\\\INV_Fabric_Netherweave')
    D(3300, "Rabbit's Foot", 0, 'INVTYPE_NON_EQUIP_IGNORE', 15, 0, 'Interface\\\\Icons\\\\INV_Misc_Foot_Kodo')
    D(23436, 'Living Ruby', 3, 'INVTYPE_NON_EQUIP_IGNORE', 3, 0, 'Interface\\\\Icons\\\\INV_Jewelcrafting_LivingRuby_02')
    D(24490, 'The Master\\'s Key', 1, 'INVTYPE_NON_EQUIP_IGNORE', 13, 0, 'Interface\\\\Icons\\\\INV_Misc_Key_07')
    __MOCK.bags[1] = { size = 16, slots = {} }
    __MOCK.set_bags({ { 0, 1, 28830, 1 }, { 0, 2, 22838, 10 }, { 0, 3, 21877, 20 }, { 0, 5, 3300, 2 },
                      { 1, 1, 23436, 1 }, { -2, 1, 24490, 1 } })
    __MOCK.bags[-2] = __MOCK.bags[-2] or { slots = {} }; __MOCK.bags[-2].size = 32
"""


def bagged(look="flat", layout=None):
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.look', ...)", look)
    if layout:
        c.eval("ns.DB:SetSetting('ui.bags.layout', ...)", layout)
    c.relog()
    w.tick(2)
    c.eval("__MOCK.real_geometry = true")
    c.eval(ITEMS)
    w.tick(0.2)
    return w, c


SHOWN = """
    local f = ns.LookBags.windows[...]
    local out = {}
    if not f then return out end
    for bag, list in pairs(f.buttons) do
        for slot, b in pairs(list) do if b:IsShown() then out[#out + 1] = bag .. ':' .. slot end end
    end
    table.sort(out)
    return out
"""


# ------------------------------------------------------------------------------------------------------------------
@case
def b_opens_our_bags_with_the_games_item_buttons():
    w, c = bagged("flat")
    assert c.eval("return ns.LookBags.active") is True
    # (the game's ToggleAllBags, stood in for: the Dock's B key binding calls it)
    c.eval("function ToggleAllBags() end; ns.LookBags:HookGame()")
    c.eval("ToggleAllBags()")
    assert c.eval("return DisasterZoneBags:IsShown()") is True
    # one bag is the default: every slot of the backpack (16) and bag 1 (16)
    shown = c.eval_py(SHOWN, "bags")
    assert len(shown) == 32 and "0:1" in shown and "1:16" in shown, shown
    # the slots are the game's: the holder carries the bag, the button the slot
    assert c.eval("local b = DisasterZoneBagSlot3_1; return b:GetParent():GetID() .. ':' .. b:GetID()") == "0:1"
    assert c.eval("return DisasterZoneBagSlot4_1:GetParent():GetID()") == 1
    # the game's own bag windows stay closed
    assert c.eval("return ContainerFrame1 == nil or not ContainerFrame1:IsShown()") is True
    # B again closes it
    c.eval("ToggleAllBags()")
    w.tick(0.1)
    c.eval("ToggleAllBags()")
    assert c.eval("return DisasterZoneBags:IsShown()") is False
    w.assert_no_errors()


@case
def shelves_sort_by_kind_and_junk_sells_at_a_vendor():
    w, c = bagged("sigil", "shelves")
    c.eval("ns.LookBags:Open('bags')")
    heads = c.eval_py("local out = {}; for _, h in ipairs(DisasterZoneBags.heads) do if h:IsShown() then out[#out + 1] = h.key end end; return out")
    assert heads[:5] == ["gear", "cons", "trade", "gems", "junk"] and heads[-1] == "free", heads
    # the items stay in their slots: only the buttons moved
    assert c.eval("return DisasterZoneBagSlot3_5:GetParent():GetID() .. ':' .. DisasterZoneBagSlot3_5:GetID()") == "0:5"
    # a folded shelf hides its slots
    c.eval("ns.DB:SetSetting('ui.bags.fold.cons', true); ns.LookBags:Refresh('bags')")
    assert c.eval("return DisasterZoneBagSlot3_2:IsShown()") is False
    # at a vendor: Sell junk sells the grey
    c.eval("""
        MerchantFrame = MerchantFrame or CreateFrame('Frame', 'MerchantFrame', UIParent); MerchantFrame:Show()
        local sold = {}
        C_Container.UseContainerItem = function(bag, slot) sold[#sold + 1] = bag .. ':' .. slot end
        _G.__sold = sold
        ns.LookBags:Refresh('bags')""")
    assert c.eval("return DisasterZoneBags.junk:IsShown()") is True
    c.eval("ns.LookBags:SellJunk()")
    assert c.eval_py("return __sold") == ["0:5"]
    w.assert_no_errors()


@case
def bag_by_bag_and_the_key_ring():
    w, c = bagged("gilded", "bags")
    c.eval("ns.LookBags:Open('bags')")
    heads = c.eval_py("local out = {}; for _, h in ipairs(DisasterZoneBags.heads) do if h:IsShown() then out[#out + 1] = h.key end end; return out")
    assert heads == ["bag0", "bag1"], heads
    # the key ring folds in (the key ring button / ToggleKeyRing)
    c.eval("ns.LookBags:ShowKeys(true)")
    heads = c.eval_py("local out = {}; for _, h in ipairs(DisasterZoneBags.heads) do if h:IsShown() then out[#out + 1] = h.key end end; return out")
    assert heads == ["bag0", "bag1", "bag-2"], heads
    assert c.eval("return DisasterZoneBagSlot1_1:GetParent():GetID()") == -2
    w.assert_no_errors()


@case
def the_bank_opens_ours_and_closing_it_leaves_the_bank():
    w, c = bagged("halo")
    c.eval("__MOCK.bags[5] = { size = 14, slots = {} }")
    c.eval("__MOCK.set_bags({ { -1, 1, 21877, 20 }, { -1, 2, 23436, 1 }, { 5, 1, 22838, 5 } }, true)")
    w.tick(0.2)
    assert c.eval("return DisasterZoneBank:IsShown() and DisasterZoneBags:IsShown()") is True
    # the bank's own slots use the bank's template, its bags the container one
    assert c.eval("return DisasterZoneBagSlot2_1:GetParent():GetID()") == -1
    shown = c.eval_py(SHOWN, "bank")
    assert len(shown) == 28 + 14, len(shown)
    # closing our bank window closes the bank (the game's window never opened)
    c.eval("_G.__closed = false; CloseBankFrame = function() _G.__closed = true end; DisasterZoneBank:Hide()")
    assert c.eval("return __closed") is True
    w.assert_no_errors()


@case
def buying_a_bank_slot_and_the_bag_slots_take_bags():
    w, c = bagged("flat")
    c.eval("""
        GetNumBankSlots = function() return 1, false end
        GetBankSlotCost = function(n) return 10000 * (n + 1) end
        BankFrame = BankFrame or CreateFrame('Frame', 'BankFrame')
        BankFrame.nextSlotCost = nil
        _G.__popup = nil
        StaticPopup_Show = function(which)
            -- (the game's dialog shows BankFrame.nextSlotCost: nil threw in MoneyFrame_Update)
            _G.__popup = which; _G.__cost = BankFrame.nextSlotCost
        end
        __MOCK.bags[5] = { size = 14, slots = {} }
    """)
    c.eval("__MOCK.set_bags({ { -1, 1, 21877, 20 } }, true)")
    w.tick(0.2)
    f = "ns.LookBags.windows.bank"
    assert c.eval(f"return {f}.buy:IsShown()") is True
    c.eval(f"{f}.buy:Click()")
    assert c.eval("return __popup") == "CONFIRM_BUY_BANK_SLOT"
    assert c.eval("return __cost") == 20000
    # the footer's bag slots: bought ones take a bag on click / drop, the rest are locked
    c.eval("""
        _G.__put, _G.__pick = {}, {}
        PutItemInBag = function(inv) table.insert(__put, inv) end
        PickupBagFromSlot = function(inv) table.insert(__pick, inv) end
    """)
    icons = f"{f}.bagIcons"
    assert c.eval(f"return {icons}[1].locked") is False
    assert c.eval(f"return {icons}[2].locked") is True
    c.eval(f"{icons}[1]:Click(); {icons}[2]:Click()")
    assert c.eval("return #__pick") == 1
    c.eval("CursorHasItem = function() return true end")
    c.eval(f"{icons}[1]:GetScript('OnReceiveDrag')({icons}[1])")
    assert c.eval("return #__put") == 1
    # the player's bags: dragging one off picks it up
    c.eval("CursorHasItem = function() return false end")
    c.eval("local ic = ns.LookBags.windows.bags.bagIcons[2]; ic:GetScript('OnDragStart')(ic)")
    assert c.eval("return #__pick") == 2
    w.assert_no_errors()


@case
def search_dims_what_does_not_match_and_marks_junk():
    w, c = bagged("flat")
    c.eval("ns.LookBags:Open('bags')")
    c.eval("ns.LookBags:Search('potion')")
    assert c.eval("return DisasterZoneBagSlot3_2:GetAlpha()") == 1
    assert c.eval("return DisasterZoneBagSlot3_1:GetAlpha() < 0.5") is True
    c.eval("ns.LookBags:Search('')")
    # the junk dot on the grey
    assert c.eval("return DisasterZoneBagSlot3_5.dzJunk:IsShown()") is True
    w.assert_no_errors()


@case
def a_refresh_never_hides_a_slot_that_stays():
    # (hiding the button under a held item dropped the drag: a refresh only moves the buttons that keep a slot)
    w, c = bagged("sigil", "shelves")
    c.eval("ns.LookBags:Open('bags')")
    c.eval("_G.__hid = 0; DisasterZoneBagSlot3_1:HookScript('OnHide', function() _G.__hid = _G.__hid + 1 end)")
    c.eval("__MOCK.fire('ITEM_LOCK_CHANGED', 0, 1); ns.LookBags:Refresh('bags'); ns.LookBags:Refresh('bags')")
    assert c.eval("return __hid") == 0
    w.assert_no_errors()


@case
def every_look_paints_a_grid():
    for look in ("flat", "halo", "sigil", "slate", "gilded"):
        for layout in ("one", "shelves", "bags"):
            w, c = bagged(look, layout)
            c.eval("ns.LookBags:Open('bags')")
            assert c.eval("return math.floor(DisasterZoneBagSlot3_1:GetWidth() + 0.5)") == c.eval("return ns.LookBags:Size()")
            w.assert_no_errors()


@case
def sort_merges_stacks_and_orders_by_kind_quality_name():
    w, c = bagged("flat")
    # (the game's pick up / put down, stood in for: a second pickup swaps, or merges the same item up to its stack)
    c.eval("""
        C_Container.SortBags = nil
        local held
        C_Container.PickupContainerItem = function(bag, slot)
            local b = __MOCK.bags[bag]; b.slots = b.slots or {}
            local here = b.slots[slot]
            if not held then
                if here then held = { bag = bag, slot = slot, item = here }; b.slots[slot] = nil end
                return
            end
            local it = held.item; held = nil
            if here and here.id == it.id then
                local room = 20 - here.count
                local n = math.min(room, it.count)
                here.count = here.count + n
                if it.count > n then it.count = it.count - n; __MOCK.bags[bag].slots[slot] = here; 
                    local hb = __MOCK.bags[bag]; for s2 = 1, 16 do if not __MOCK.bags[0].slots[s2] then __MOCK.bags[0].slots[s2] = it; break end end end
            else
                b.slots[slot] = it
                if here then
                    for s2 = 1, 16 do if not __MOCK.bags[0].slots[s2] then __MOCK.bags[0].slots[s2] = here; break end end
                end
            end
        end
        CursorHasItem = function() return held ~= nil end
        __MOCK.define_item(21877, 'Netherweave Cloth', 1, 'INVTYPE_NON_EQUIP_IGNORE', 7, 5, 'x', 1, 1, 0, 20)
        __MOCK.set_bags({ { 0, 1, 3300, 2 }, { 0, 2, 21877, 7 }, { 0, 3, 22838, 10 }, { 0, 4, 21877, 5 },
                          { 0, 6, 28830, 1 }, { 1, 1, 23436, 1 } })""")
    assert c.eval("return ns.LookBags:Sort('bags')") is True
    w.tick(5)
    order = c.eval_py("local out = {}; for slot = 1, 6 do local s = __MOCK.bags[0].slots[slot]; out[slot] = s and (s.id .. 'x' .. s.count) or '-' end; return out")
    # gear (the trophy), consumables (potion), trade goods (cloth, one stack of 12), gems (ruby), junk last
    assert order == ["28830x1", "22838x10", "21877x12", "23436x1", "3300x2", "-"], order
    assert c.eval("return ns.LookBags.sorting == nil") is True
    w.assert_no_errors()


# The server, stood in for: a pickup + drop swaps the two slots (or merges the same item up to its stack size, the rest
# staying behind), both slots stay locked until the server answers 0.1 s later (ITEM_LOCK_CHANGED), and a move onto
# a locked slot is refused (the item goes back).
SERVER = """
    C_Container.SortBags = nil
    local held
    local locks = {}
    local function key(bag, slot) return bag .. ':' .. slot end
    local orig = C_Container.GetContainerItemInfo
    C_Container.GetContainerItemInfo = function(bag, slot)
        local t = orig(bag, slot)
        if t then t.isLocked = locks[key(bag, slot)] and true or false end
        return t
    end
    local function lock(bag, slot)
        locks[key(bag, slot)] = true
        C_Timer.After(0.1, function() locks[key(bag, slot)] = nil; __MOCK.fire('ITEM_LOCK_CHANGED', bag, slot) end)
    end
    local function stackOf(id) local r = __MOCK.ITEMS[id]; return r and r.stack or 1 end
    ClearCursor = function() held = nil end
    C_Container.PickupContainerItem = function(bag, slot)
        local b = __MOCK.bags[bag]
        if not held then
            if locks[key(bag, slot)] or not b.slots[slot] then return end
            held = { bag = bag, slot = slot }
            -- (the real client locks the picked-up slot and fires the event right away, mid-move)
            locks[key(bag, slot)] = true
            __MOCK.fire('ITEM_LOCK_CHANGED', bag, slot)
            locks[key(bag, slot)] = nil
            return
        end
        local from = held; held = nil
        if from.bag == bag and from.slot == slot then return end
        if locks[key(bag, slot)] then held = from; return end
        -- (the server refuses some moves: the item stays on the cursor, as the game does)
        if _G.__refuse and math.random() < _G.__refuse then held = from; _G.__refused = (_G.__refused or 0) + 1; return end
        _G.__moves = (_G.__moves or 0) + 1
        local fb = __MOCK.bags[from.bag]
        local it, here = fb.slots[from.slot], b.slots[slot]
        if here and here.id == it.id and here.count < stackOf(it.id) then
            local n = math.min(stackOf(it.id) - here.count, it.count)
            here.count = here.count + n
            it.count = it.count - n
            if it.count <= 0 then fb.slots[from.slot] = nil end
        else
            b.slots[slot], fb.slots[from.slot] = it, here
        end
        lock(bag, slot); lock(from.bag, from.slot)
    end
    CursorHasItem = function() return held ~= nil end
"""


@case
def sort_works_with_a_real_server_and_takes_few_round_trips():
    sort_run(0)


@case
def sort_still_finishes_right_when_the_server_refuses_moves():
    sort_run(0.25)


def sort_run(refuse):
    w, c = bagged("flat")
    c.eval(SERVER)
    c.eval("_G.__refuse = ...", refuse)
    # a full, shuffled inventory: 4 bags of 16 + the backpack, many kinds, split stacks of the same items
    c.eval("""
        for b = 1, 4 do __MOCK.bags[b] = { size = 16, slots = {} } end
        local D = __MOCK.define_item
        local kinds = { { 0, 1, 20 }, { 2, 4, 1 }, { 4, 3, 1 }, { 7, 1, 20 }, { 3, 3, 20 }, { 15, 0, 1 }, { 12, 1, 1 } }
        local content, n = {}, 0
        math.randomseed(7)
        for id = 90001, 90040 do
            local k = kinds[(id % #kinds) + 1]
            D(id, 'Item ' .. id, k[2], 'INVTYPE_NON_EQUIP_IGNORE', k[1], 0, 'x', 1, 1, 0, k[3])
        end
        local bags = { 0, 1, 2, 3, 4 }
        local free = {}
        for _, b in ipairs(bags) do for s = 1, 16 do free[#free + 1] = { b, s } end end
        for i = #free, 2, -1 do local j = math.random(i); free[i], free[j] = free[j], free[i] end
        local at = 1
        for id = 90001, 90040 do
            local stack = __MOCK.ITEMS[id].stack
            local pieces = stack > 1 and math.random(1, 3) or 1
            for _ = 1, pieces do
                local p = free[at]; at = at + 1
                content[#content + 1] = { p[1], p[2], id, stack > 1 and math.random(1, 9) or 1 }
            end
        end
        _G.__used = at - 1
        __MOCK.set_bags(content)
    """)
    before = c.eval_py("""
        local t = {}
        for b = 0, 4 do for s, x in pairs(__MOCK.bags[b].slots) do t[x.id] = (t[x.id] or 0) + x.count end end
        return t""")
    c.eval("ns.LookBags:Open('bags')")
    assert c.eval("return ns.LookBags:Sort('bags')") is True
    # (the sort tile shows it is working, and stops when done)
    assert c.eval("return DisasterZoneBags.sort.spin:IsShown()") is True
    # (drawn on the tile's face, the top frame: not under its ground)
    assert c.eval("local b = DisasterZoneBags.sort; return b.spin:GetParent() == ns.LookBars.tiles[b].f") is True
    for _ in range(80):
        w.tick(0.1)
        if c.eval("return ns.LookBags.sorting == nil"):
            break
    assert c.eval("return ns.LookBags.sorting == nil") is True, "the sort never finished"
    w.tick(0.5)      # (the loading glyph fades back out)
    assert c.eval("return DisasterZoneBags.sort.spin:IsShown()") is False
    # nothing lost, every item one stack (no stack is over 20 here), in order, the free slots last
    after = c.eval_py("""
        local t, order, gap = {}, {}, false
        for _, b in ipairs({ 0, 1, 2, 3, 4 }) do for s = 1, 16 do
            local x = __MOCK.bags[b].slots[s]
            if x then
                t[x.id] = (t[x.id] or 0) + x.count
                order[#order + 1] = x.id
                if gap then return { bad = 'an item after a free slot' } end
            else gap = true end
        end end
        return { t = t, order = order }""")
    assert "bad" not in after, after
    assert after["t"] == before, (after["t"], before)
    # at most one partial stack per item, and every slot in the sort's order
    check = c.eval_py("""
        local list = {}
        for _, b in ipairs({ 0, 1, 2, 3, 4 }) do for s = 1, 16 do
            local info = C_Container.GetContainerItemInfo(b, s)
            if info then list[#list + 1] = info end
        end end
        local partial = {}
        for _, info in ipairs(list) do
            if info.stackCount < __MOCK.ITEMS[info.itemID].stack then
                if partial[info.itemID] then return 'two partial stacks of ' .. info.itemID end
                partial[info.itemID] = true
            end
        end
        for i = 2, #list do
            if ns.LookBags.Before(list[i], list[i - 1]) then return 'out of order at ' .. i end
        end
        return 'ok'""")
    assert check == "ok", check
    took = c.eval("return ns.LookBags.lastTime")
    moves = c.eval("return __moves")
    print("sort took %.2f s for %d moves (%s refused)" % (took, moves, c.eval("return __refused")))
    # (each move waits 0.1 s for the server; one at a time this would take moves x 0.1 s)
    if not refuse:
        assert took is not None and took <= moves * 0.1 / 4, (took, moves)
    w.assert_no_errors()


@case
def blizzard_bags_stay_the_games():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    assert c.eval("return ns.LookBags.active == nil or ns.LookBags.active == false") is True
    c.eval("function ToggleAllBags() end; ns.LookBags:HookGame()")
    c.eval("ToggleAllBags()")
    assert c.eval("return DisasterZoneBags == nil or not DisasterZoneBags:IsShown()") is True
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

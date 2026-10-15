"""The Atlas shopping list (Core/ShoppingList.lua, UI/AtlasShop.lua, the hooks in UI/Atlas.lua).

Covers: adding a craft from an Atlas row (the bag button, the right-click menu; the amount and breakdown set with Shift
carry over), the bag mark on rows, amounts / breakdown / removing / clearing, one list per character that reading never
creates; grouping by who makes it (my own crafts first, then the member who can make the most of what is left,
nobody, bind on pickup); the list view (Made by column, a crafter's title with Whisper, materials with what the bags
hold, missing first, the progress count, the hover stepper and bin, the breakdown menu), the whisper text, the
Auctionator cost line, the empty state and search taking over while typing.

Run: luaenv\\Scripts\\python.exe tests\\atlas\\test_shopping_list.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "members"))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from mb_common import guild, set_skills, open_tradeskill, ALCHEMY, TAILORING, K  # noqa: E402
from _common import case, run_all, install_helpers, strip_codes, tt_lines, menu_texts  # noqa: E402

BAG = 21841            # Netherweave Bag (Gina's Tailoring): 4 Bolt of Netherweave, 1 Rune Thread
FORT, MIGHTY = 22851, 22853   # Flasks of Fortification / Mighty Restoration (Alfa and Gina)
SUPER_MANA = 22832     # Super Mana Potion (Alfa only)
IMBUED_BAG = 21843     # Imbued Netherweave Bag: nobody in this guild knows it
HOOD = 24266           # Spellstrike Hood (Gina): binds when picked up
SYNC = 200

LUA = r"""
function T_shop_groups()
  local g = ns.AtlasShopUI:GetLists()
  local o = {}
  for i, d in ipairs(g:GetData()) do o[i] = { d.id, (tostring(d.label):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")), d.count or 0 } end
  return o
end
function T_shop_rows()
  local _, l = ns.AtlasShopUI:GetLists()
  local o = {}
  for i, d in ipairs(l:GetData()) do
    if d.type == "item" then o[i] = { "item", d.e.id, d.e.n, d.e.d, d.g.kind }
    elseif d.type == "mat" then o[i] = { "mat", d.m.id, d.m.need, d.m.have }
    elseif d.type == "sect" then o[i] = { "sect", d.done, d.total }
    else o[i] = { d.type, d.copper or 0 } end
  end
  return o
end
function T_shop_row(kind, id)
  local _, l = ns.AtlasShopUI:GetLists()
  for _, r in ipairs(l.box:GetFrames()) do
    local d = rawget(r, "__cdlData")
    if d and d.type == kind and ((d.e and d.e.id == id) or (d.m and d.m.id == id)) and r:IsShown() then return r end
  end
end
function T_atlas_itemrow(id)
  local _, _, list = ns.AtlasUI:GetLists()
  for _, r in ipairs(list.box:GetFrames()) do
    local d = rawget(r, "__cdlData")
    if d and d.type == "item" and d.id == id and r:IsShown() then return r end
  end
end
"""


def world():
    w, c = guild([("Gina", "PALADIN"), ("Alfa", "MAGE"), ("Bert", "ROGUE")])
    g, a, b = c["Gina"], c["Alfa"], c["Bert"]
    for i in (BAG, FORT, MIGHTY, SUPER_MANA, IMBUED_BAG, 22831):
        w.define_item(i, "Item %d" % i, 2, bind=2)
    w.define_item(HOOD, "Spellstrike Hood", 4, "INVTYPE_HEAD", 4, 1, bind=1)
    set_skills(a, [("Alchemy", 375, 375)])
    set_skills(g, [("Alchemy", 320, 375), ("Tailoring", 375, 375)])
    w.tick(5)
    open_tradeskill(a, "Alchemy", ALCHEMY)
    open_tradeskill(g, "Alchemy", ALCHEMY[:2])
    w.tick(2)
    open_tradeskill(g, "Tailoring", TAILORING)
    w.tick(SYNC)
    for x in (g, a, b):
        install_helpers(x)
        x.eval(LUA)
    return w, g, a, b


def entries(c):
    return [(e["id"], e["n"], e["d"]) for e in (c.eval_py("return ns.Shop:GetEntries()") or [])]


def groups(c):
    return [tuple(g) for g in (c.eval_py("local o = {} for i, g in ipairs(ns.Shop:GetGroups()) do "
                                         "local ids = {} for j, e in ipairs(g.entries) do ids[j] = e.id end "
                                         "o[i] = { g.kind, g.key or '', ids } end return o") or [])]


def rows(c):
    return [list(r) for r in (c.eval_py("return T_shop_rows()") or [])]


def fill(c, ids):
    for i in ids:
        assert c.eval("return (ns.Shop:Add(...))", i), i


# ------------------------------------------------------------------------------------------------------------------
@case
def adding_from_an_atlas_row_with_the_shift_amount_and_breakdown():
    w, g, a, b = world()
    b.eval("ns.MainFrame:Open('atlas')")
    w.tick(0.3)
    db_before = b.eval_py("return ns.db.shopping[ns.Util.PlayerKey()]")
    assert db_before is None, "reading the list must not create it"
    b.eval("ns.AtlasUI:GoTo(ns.Atlas:GetLocations(...)[1])", BAG)
    w.tick(0.2)
    row = b.eval("return T_atlas_itemrow(...)", BAG)
    b.hover(row)
    assert b.eval("local r = ...; return r.shop:IsShown()", row), "the bag shows on a craft's row"
    b.hover(b.eval("local r = ...; return r.shop", row))
    tip = [strip_codes(l) for l, _ in tt_lines(b)]
    assert tip[0] == "Add to shopping list" and "Gina can make it for you." in tip, tip
    b.click(b.eval("local r = ...; return r.shop", row))
    assert entries(b) == [(BAG, 1, 0)], entries(b)
    # the row's mark, and the left column's count
    w.tick(0.3)
    row = b.eval("return T_atlas_itemrow(...)", BAG)
    assert "1" in strip_codes(b.eval("local r = ...; return r:StatusText()", row) or ""), "bag mark"
    # Shift: 3 and a step down, then the bag adds that
    b.hover(row)
    b.set_modifiers(shift=True)
    b.eval("local r = ...; r:GetScript('OnMouseWheel')(r, 1); r:GetScript('OnMouseWheel')(r, 1)", row)
    b.click(row)
    b.click(b.eval("local r = ...; return r.shop", row))
    assert entries(b) == [(BAG, 4, 1)], entries(b)
    b.set_modifiers(shift=False)
    # the right-click menu has it too (a spell craft as well); a raid drop is no craft
    b.eval("ns.AtlasUI:OpenMenu({ type = 'item', id = ... })", -27984)
    texts = [strip_codes(e[2]) for e in menu_texts(b.last_menu())]
    assert "Add to shopping list" in texts, texts
    b.eval("ns.AtlasUI:OpenMenu({ type = 'item', id = ... })", 28505)
    assert "Add to shopping list" not in [strip_codes(e[2]) for e in menu_texts(b.last_menu())]
    assert not b.eval("return (ns.Shop:Add(28505))"), "a raid drop is no craft"
    w.assert_no_errors()


@case
def amounts_breakdown_remove_and_clear_per_character():
    w, g, a, b = world()
    fill(b, [BAG, FORT])
    b.eval("ns.Shop:SetAmount(...)", BAG, 3)
    b.eval("ns.Shop:SetDepth(...)", BAG, 1)
    assert entries(b) == [(BAG, 3, 1), (FORT, 1, 0)]
    b.eval("ns.Shop:SetAmount(...)", FORT, 0)
    assert entries(b) == [(BAG, 3, 1)]
    # bolts break down into cloth; Rune Thread is bought
    assert b.eval("return ns.Shop:GetMaxDepth(...)", BAG) == 1
    assert b.eval("return ns.Shop:GetMaxDepth(...)", SUPER_MANA) == 0
    assert entries(g) == [], "another character's list is its own"
    b.eval("ns.Shop:Clear()")
    assert entries(b) == []
    w.assert_no_errors()


@case
def grouped_by_who_can_make_the_most():
    w, g, a, b = world()
    fill(b, [BAG, FORT, MIGHTY, SUPER_MANA, IMBUED_BAG, HOOD])
    got = groups(b)
    # Alfa and Gina can both make three; both online, Alfa sorts first and takes the flasks
    assert got[0] == ("member", K("Alfa"), [FORT, MIGHTY, SUPER_MANA]), got
    assert got[1] == ("member", K("Gina"), [BAG]), got
    assert got[2] == ("nobody", "", [IMBUED_BAG]), got
    assert got[3] == ("bop", "", [HOOD]), got
    # Gina makes the hood herself: hers, first
    fill(g, [HOOD, SUPER_MANA])
    got = groups(g)
    assert got[0] == ("you", K("Gina"), [HOOD]) and got[1] == ("member", K("Alfa"), [SUPER_MANA]), got
    # offline crafters lose a tie
    g.eval("ns.Shop:Clear()")
    w.assert_no_errors()


@case
def the_list_view_crafter_whisper_materials_and_hover():
    w, g, a, b = world()
    fill(b, [BAG, FORT, MIGHTY, SUPER_MANA, IMBUED_BAG, HOOD])
    b.set_bags({(0, 1): (22794, 5)})   # Fel Lotus: enough for the flasks
    b.eval("ns.MainFrame:Open('atlas'); ns.AtlasUI:OpenShop()")
    w.tick(0.3)
    gr = [tuple(x) for x in b.eval_py("return T_shop_groups()")]
    assert gr == [("all", "Everyone", 0), (K("Alfa"), "Alfa", 3), (K("Gina"), "Gina", 1),
                  ("nobody", "Nobody in the guild", 1), ("bop", "Can't be made for you", 1)], gr
    r = rows(b)
    items = [x[1] for x in r if x[0] == "item"]
    assert items == [FORT, MIGHTY, SUPER_MANA, BAG, IMBUED_BAG, HOOD], items
    sect = next(x for x in r if x[0] == "sect")
    mats = [x for x in r if x[0] == "mat"]
    assert sect[2] == len(mats) and sect[1] >= 1, (sect, mats)
    # missing first, the done ones (the Fel Lotus) last
    done = [m for m in mats if m[3] >= m[2]]
    assert done and mats[-len(done):] == done and any(m[1] == 22794 for m in done), mats
    # the hood (bind on pickup, nobody can make it for me) adds no materials: no Primal Nether
    assert not any(m[1] == 23572 for m in mats), mats
    # Alfa: the title, Whisper, only Alfa's crafts and their materials
    b.eval("ns.AtlasShopUI:Select(...)", K("Alfa"))
    w.tick(0.1)
    title = strip_codes(b.eval("return ns.AtlasShopUI:GetTitle().title:GetText()"))
    sub = b.eval("return ns.AtlasShopUI:GetTitle().sub:GetText()")
    assert title == "Alfa" and "Alchemy 375" in sub and "online" in sub, (title, sub)
    assert b.eval("return ns.AtlasShopUI:GetTitle().whisper:IsShown()")
    assert [x[1] for x in rows(b) if x[0] == "item"] == [FORT, MIGHTY, SUPER_MANA]
    b.click(b.eval("return ns.AtlasShopUI:GetTitle().whisper"))
    chat = b.eval("return __MOCK.opened_chat")
    assert chat.startswith("/w Alfa Could you make ") and chat.endswith("for me? I'll bring the materials."), chat
    # hover a craft: the stepper and the bin
    b.eval("ns.AtlasShopUI:Select('all')")
    w.tick(0.1)
    row = b.eval("return T_shop_row('item', ...)", BAG)
    b.hover(row)
    assert b.eval("local r = ...; return r.plusBtn:IsShown() and r.bin:IsShown() and not r.amt:IsShown()", row)
    assert not b.eval("local r = ...; return r.minusBtn:IsShown()", row), "no minus at 1"
    b.click(b.eval("local r = ...; return r.plusBtn", row))
    assert (BAG, 2, 0) in entries(b)
    # the breakdown link: Bolt of Netherweave becomes cloth
    assert b.eval("local r = ...; return r.step:IsShown()", row)
    b.eval("ns.Shop:SetDepth(...)", BAG, 1)
    w.tick(0.3)
    assert any(x[0] == "mat" and x[1] == 21877 for x in rows(b)), rows(b)
    b.click(b.eval("local r = T_shop_row('item', ...); return r.bin", BAG))
    assert BAG not in [e[0] for e in entries(b)]
    w.assert_no_errors()


@case
def auction_house_cost_with_auctionator():
    w, g, a, b = world()
    fill(b, [FORT])
    b.eval("ns.MainFrame:Open('atlas'); ns.AtlasUI:OpenShop()")
    w.tick(0.3)
    assert not any(x[0] == "cost" for x in rows(b)), "no Auctionator, no cost line"
    b.eval("""Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function(caller, id)
      if caller ~= "DisasterZone" then error("caller") end
      return id == 22794 and 250000 or nil end } } }""")
    b.eval("ns.Shop:SetAmount(...)", FORT, 2)
    w.tick(0.3)
    cost = [x for x in rows(b) if x[0] == "cost"]
    assert cost and cost[0][1] == 2 * 250000, cost
    assert b.eval_py("return { ns.Shop:GetCost(ns.Shop:GetMaterials()) }")[1] >= 1, "unpriced counted"
    w.assert_no_errors()


@case
def members_recipe_rows_have_the_bag_too():
    w, g, a, b = world()
    b.slash("/dz members")
    w.tick(1)
    b.eval("ns.MembersUI:SetMode('recipes')")
    b.eval("""T_row = nil
      ns.MembersUI:GetPanel().recipes.box:ForEachFrame(function(row)
        local d = row.__cdlData
        if d and d.r.spell == 26746 then T_row = row end
      end)""")
    row = b.eval("return T_row")
    assert not b.eval("return T_row.shop:IsShown()")
    b.hover(row)
    assert b.eval("return T_row.shop:IsShown() and not T_row.count:IsShown()"), "the bag replaces the count on hover"
    b.hover(b.eval("return T_row.shop"))
    tip = [strip_codes(l) for l, _ in tt_lines(b)]
    assert tip[0] == "Add to shopping list" and "Gina can make it for you." in tip, tip
    b.click(b.eval("return T_row.shop"))
    assert entries(b) == [(BAG, 1, 0)], entries(b)
    assert "On your list: 1" in [strip_codes(l) for l, _ in tt_lines(b)]
    w.assert_no_errors()


@case
def empty_list_and_search_take_turns():
    w, g, a, b = world()
    b.eval("ns.MainFrame:Open('atlas'); ns.AtlasUI:OpenShop()")
    w.tick(0.3)
    assert b.eval_py("return T_shop_groups()") in ([], None) or b.eval_py("return T_shop_groups()") == {}
    assert "Nothing here yet" in b.eval("local _, l = ns.AtlasShopUI:GetLists(); return l.emptyText:GetText()")
    assert b.eval("return ns.AtlasShopUI:IsShown()")
    b.eval("ns.AtlasUI:SetSearch('flask')")
    assert not b.eval("return ns.AtlasShopUI:IsShown()"), "a search shows its results"
    b.eval("ns.AtlasUI:SetSearch('')")
    assert b.eval("return ns.AtlasShopUI:IsShown()"), "back to the list"
    # another place on the left leaves the list
    b.eval("ns.AtlasUI:Select('crafting', 'Tailoring')")
    assert not b.eval("return ns.AtlasShopUI:IsShown()")
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

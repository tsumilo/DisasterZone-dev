#!/usr/bin/env python
"""My BiS > Consumables (Data/Consumables.lua, Core/Kit.lua, UI/KitView.lua), on the real addon.

Covers: the Consumables button shows the kit in the page's body (the doll hidden) and takes turns with Sim mode; a
phase click goes back to the gear; the Retribution kit lists best and budget picks with what the bags hold (a night's
worth); a blunt main hand swaps the sharpening stone for the weightstone; Add prog kit puts what the bags lack of the
crafted picks on the shopping list (scrolls and runes stay off: no craft makes them); the kit sim gives every slot a
DPS number and adds the whole kits up, each run with its own consumables; a healer has no Sim button and says why;
every spec has a kit whose items are all known; no Lua errors on the way.

Run: luaenv\\Scripts\\python.exe tests\\kit\\test_consumables.py   [-k substring]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "sync"))

from common import Runner, Client, new_world, up, settle, assert_no_lua_errors  # noqa: E402

r = Runner("consumables (My BiS)")

# WoWSims' P1 Retribution preset, by inventory slot
P1 = {1: 29073, 2: 28745, 3: 29075, 15: 24259, 5: 29071, 9: 28795, 10: 30644, 6: 28779, 7: 30257, 8: 28608,
      11: 28757, 12: 30834, 13: 29383, 14: 28830, 16: 28429, 18: 27484}
FLASK, HASTE, DOG, SUPER_MANA, CLEFTHOOF, STONE, WEIGHTSTONE = 22854, 22838, 27655, 22832, 27658, 23529, 28421
TORCH_OF_THE_DAMNED = 28657   # a two-handed mace


def solo(spec="Retribution", cls="PALADIN"):
    w = new_world()
    c = Client(w, "Raider", class_file=cls, race="BloodElf" if cls == "PALADIN" else "Human", guild_rank=3)
    up(c)
    settle(w, 5)
    assert c.eval("return ns.BiS:SetSpec(...)", spec) is True
    if cls == "PALADIN":
        c.equip(P1)
    c.set_bags({(0, 1): (FLASK, 2), (0, 2): (HASTE, 5), (0, 3): (DOG, 6), (0, 4): (SUPER_MANA, 2)})
    c.eval("ns.Kit.ITERATIONS = 10")
    c.eval('ns.MainFrame:Open("mybis")')
    settle(w, 1)
    return w, c


def snap(c):
    return c.eval_py("return ns.KitView:Snapshot()")


def open_kit(w, c):
    c.eval("ns.MainFrame:Open('consumables')")
    settle(w, 0.3)


def run_kit(w, c, limit=800):
    c.eval("ns.KitView:Run()")
    for _ in range(limit):
        if not c.eval("return ns.Kit:IsRunning()"):
            return
        w.tick(0.05, 0.05)
    raise AssertionError("kit sim never finished")


def row(s, title):
    for x in s["rows"]:
        if x["title"].startswith(title):
            return x
    raise AssertionError("no row %r in %r" % (title, [x["title"] for x in s["rows"]]))


def bar(c):
    return c.eval_py("local p = ns.MyBiS:GetPanel() local ph = 0 for _, b in ipairs(p.phaseButtons or {}) do "
                     "if b:IsShown() then ph = ph + 1 end end return { view = ns.MyBiS:GetView(), "
                     "page = ns.MainFrame:GetSelectedTab(), title = p.pageTitle:IsShown() and "
                     "p.pageTitle.text:GetText() or false, more = p.moreBtn:IsShown(), phases = ph }")


@r.case
def gear_pages_share_one_panel_each_with_its_own_bar():
    w, c = solo()
    # My BiS: the phases, More, no title
    b = bar(c)
    assert b == {"view": "list", "page": "mybis", "title": False, "more": True, "phases": b["phases"]}, b
    assert b["phases"] >= 5, b
    # Consumables: its own page, the kit, its title instead of the phases, no More
    open_kit(w, c)
    assert c.eval("return ns.KitView:IsActive()") is True
    assert snap(c)["shown"] is True
    assert bar(c) == {"view": "kit", "page": "consumables", "title": "Consumables", "more": False, "phases": 0}
    # Gear sim: the kit goes, Sim mode comes, More (the Working set) is back
    c.eval("ns.MainFrame:Open('gearsim')")
    settle(w, 0.3)
    assert c.eval("return ns.SimPanel:IsActive()") is True
    assert c.eval("return ns.KitView:IsActive()") is False
    assert snap(c)["shown"] is False
    assert bar(c) == {"view": "sim", "page": "gearsim", "title": "Gear sim", "more": True, "phases": 0}
    # the old switches open the pages: KitView:SetActive(true) -> Consumables, SimPanel:SetActive(false) -> My BiS
    c.eval("ns.KitView:SetActive(true)")
    settle(w, 0.3)
    assert bar(c)["page"] == "consumables"
    assert c.eval("return ns.SimPanel:IsActive()") is False
    c.eval("ns.SimPanel:SetActive(true)  ns.SimPanel:SetActive(false)")
    settle(w, 0.3)
    assert bar(c)["page"] == "mybis" and bar(c)["view"] == "list", bar(c)
    assert c.eval("return ns.SimPanel:IsActive() or ns.KitView:IsActive()") is False
    # one panel for the three pages, shown (the background build of the others doesn't hide it)
    assert c.eval("return ns.MainFrame:GetPanel('gearsim') == ns.MainFrame:GetPanel('mybis') and "
                  "ns.MainFrame:GetPanel('consumables') == ns.MainFrame:GetPanel('mybis')") is True
    settle(w, 3)
    assert c.eval("return ns.MyBiS:GetPanel():IsShown()") is True
    # another page and back: the mode follows the page
    c.eval("ns.MainFrame:Open('atlas')")
    settle(w, 0.3)
    assert c.eval("return ns.MyBiS:GetPanel():IsShown()") is False
    c.eval("ns.MainFrame:Open('consumables')")
    settle(w, 0.3)
    assert bar(c)["view"] == "kit" and c.eval("return ns.MyBiS:GetPanel():IsShown()") is True
    assert_no_lua_errors(w)


@r.case
def ret_kit_rows_and_bags():
    w, c = solo()
    open_kit(w, c)
    s = snap(c)
    titles = [x["title"] for x in s["rows"]]
    assert len(titles) == 6, titles
    flask = row(s, "FLASK")
    assert flask["best"] == "Flask of Relentless Assault", flask
    assert flask["budget"] == "Strength + Wisdom", flask
    assert flask["bestReady"] is True, flask              # 2 flasks = a night's worth: a check
    assert flask["bestCanList"] is False, flask
    assert flask["budgetLine"] == "Elixirs", flask
    assert row(s, "FOOD")["bestReady"] is False and row(s, "FOOD")["bestCanList"] is True, s
    pot = row(s, "POTION")
    assert pot["best"] == "Haste Potion" and pot["budget"] == "Super Mana Potion", pot
    food = row(s, "FOOD")
    assert food["best"] == "Roasted Clefthoof" and food["budget"] == "Ravager Dog", food
    assert food["bestLine"] == "+20 Strength, +20 Spirit", food
    assert row(s, "SCROLLS")["budget"] == "Same", s
    assert row(s, "EXTRA")["budget"] == "Skip it", s
    assert row(s, "WEAPON")["best"] == "Adamantite Sharpening Stone", s
    assert s["bar"]["bags"] == "2 of 6 in your bags", s["bar"]
    assert s["bar"]["sim"] is True, s["bar"]
    assert_no_lua_errors(w)


@r.case
def blunt_main_hand_takes_the_weightstone():
    w, c = solo()
    c.equip({16: TORCH_OF_THE_DAMNED})
    open_kit(w, c)
    s = snap(c)
    assert row(s, "WEAPON")["best"] == "Adamantite Weightstone", row(s, "WEAPON")
    assert row(s, "WEAPON")["budget"] == "Fel Weightstone", row(s, "WEAPON")
    assert_no_lua_errors(w)


@r.case
def add_prog_kit_fills_the_shopping_list():
    w, c = solo()
    open_kit(w, c)
    can = c.eval_py("return { ns.Shop:CanAdd(%d), ns.Shop:CanAdd(%d), ns.Shop:CanAdd(27503), ns.Shop:CanAdd(12662) }"
                    % (CLEFTHOOF, STONE))
    assert can[0] is True and can[1] is True, can     # Cooking, Blacksmithing
    assert can[2] is False and can[3] is False, can   # a scroll and a rune: no craft
    c.eval("ns.KitView:AddKit('best')")
    settle(w, 0.3)
    entries = {e["id"]: e["n"] for e in c.eval_py("return ns.Shop:GetEntries()")}
    assert entries.get(CLEFTHOOF) == 6, entries
    assert entries.get(STONE) == 6, entries
    assert FLASK not in entries and HASTE not in entries, entries      # the bags hold a night's worth
    assert 27503 not in entries and 12662 not in entries, entries
    # nothing left to add: the button says so; adding again changes nothing
    s = snap(c)
    assert s["bar"]["addProg"] == "Add prog kit", s["bar"]
    c.eval("ns.KitView:AddKit('best')")
    entries2 = {e["id"]: e["n"] for e in c.eval_py("return ns.Shop:GetEntries()")}
    assert entries2 == entries, (entries, entries2)
    # the farm kit: Super Mana Potions (2 of 5 in the bags) -> 3 more
    c.eval("ns.KitView:AddKit('budget')")
    entries3 = {e["id"]: e["n"] for e in c.eval_py("return ns.Shop:GetEntries()")}
    assert entries3.get(SUPER_MANA) == 3, entries3
    assert_no_lua_errors(w)


@r.case
def left_out_slots_stay_off_the_list_per_kit():
    w, c = solo()
    open_kit(w, c)
    assert snap(c)["bar"]["pips"] == 6
    # leave the prog kit's food and weapon out: not counted, not bought; the farm kit keeps its own
    c.eval("ns.Kit:SetOff('best', 'food', true); ns.Kit:SetOff('best', 'weapon', true)")
    settle(w, 0.3)
    s = snap(c)
    food = row(s, "FOOD")
    assert food["bestOff"] is True and food["budgetOff"] is False, food
    assert food["bestLine"] == "Left out", food
    assert s["bar"]["pips"] == 4, s["bar"]
    assert s["bar"]["bags"] == "2 of 4 in your bags", s["bar"]
    c.eval("ns.KitView:AddKit('best')")
    entries = {e["id"]: e["n"] for e in c.eval_py("return ns.Shop:GetEntries()")}
    assert CLEFTHOOF not in entries and STONE not in entries, entries
    # the farm kit: leave the potion out
    c.eval("ns.Kit:SetOff('budget', 'potion', true)")
    c.eval("ns.KitView:AddKit('budget')")
    entries = {e["id"]: e["n"] for e in c.eval_py("return ns.Shop:GetEntries()")}
    assert SUPER_MANA not in entries, entries
    # saved per spec, and putting it back brings it back
    assert c.eval("return ns.Kit:IsOff('best', 'food', 'PALADIN:Holy')") is False
    c.eval("ns.Kit:SetOff('best', 'food', false)")
    settle(w, 0.3)
    assert row(snap(c), "FOOD")["bestOff"] is False
    assert_no_lua_errors(w)


@r.case
def own_picks_through_the_item_picker():
    w, c = solo()
    open_kit(w, c)
    # a click on the prog kit's food opens the picker with consumables only (no gear sections)
    c.eval("""local v = ns.KitView
      for _, r in ipairs({ ns.KitView:Snapshot() }) do end
      ns.KitView:OpenPicker('best', 'food', ns.MyBiS:GetPanel())""")
    settle(w, 0.3)
    assert c.eval("return ns.KitView:IsPickerOpen()") is True
    ids = c.eval_py("return ns.Picker:VisibleItems()")
    assert 27658 in ids and 33872 in ids, ids           # the guide's food and another one from WoWSims' data
    assert 22854 not in ids, ids                         # no flask in the food slot
    assert all(c.eval("return ns.Kit:SlotOf(...)", i) == "food" for i in ids), ids
    # pick Spicy Hot Talbuk: the card shows it, marked as my own; the farm kit keeps the guide's
    c.eval("ns.Picker:PickItem(33872)")
    settle(w, 0.3)
    assert c.eval("return ns.KitView:IsPickerOpen()") is False
    s = snap(c)
    food = row(s, "FOOD")
    assert food["best"] == "Spicy Hot Talbuk" and food["bestCustom"] is True, food
    assert food["budget"] == "Ravager Dog" and food["budgetCustom"] is False, food
    # an elixir pair for the prog kit's flask: battle then guardian, the picker stays open in between
    c.eval("ns.KitView:OpenPicker('best', 'flask', ns.MyBiS:GetPanel())")
    c.eval("ns.Picker:PickItem(22831)")
    assert c.eval("return ns.KitView:IsPickerOpen()") is True
    c.eval("ns.Picker:PickItem(32062)")
    assert c.eval_py("return ns.Kit:GetPick('best', 'flask')") == [22831, 32062]
    c.eval("ns.Picker:PickItem(22866)")   # a flask replaces both elixirs
    assert c.eval_py("return ns.Kit:GetPick('best', 'flask')") == [22866]
    # a wrong item stays out; Default goes back to the guide's pick
    c.eval("ns.KitView:OpenPicker('best', 'food', ns.MyBiS:GetPanel())")
    c.eval("ns.Picker:PickItem(22854)")
    assert c.eval_py("return ns.Kit:GetPick('best', 'food')") == [33872]
    c.eval("ns.Picker:Close()  ns.Kit:SetPick('best', 'food', nil)")
    settle(w, 0.3)
    assert row(snap(c), "FOOD")["best"] == "Roasted Clefthoof"
    # a farm pick for a slot the guide skips, and the shopping list uses own picks
    c.eval("ns.Kit:SetPick('budget', 'extra', { 12662 })")
    settle(w, 0.3)
    assert row(snap(c), "EXTRA")["budget"] == "Demonic Rune", row(snap(c), "EXTRA")
    c.eval("ns.Kit:SetPick('best', 'food', { 27664 })  ns.KitView:AddKit('best')")
    entries = {e["id"]: e["n"] for e in c.eval_py("return ns.Shop:GetEntries()")}
    assert entries.get(27664) == 6 and CLEFTHOOF not in entries, entries
    # per spec: Holy keeps the guide's
    assert c.eval("return ns.Kit:GetPick('best', 'food', 'PALADIN:Holy') == nil") is True
    assert_no_lua_errors(w)


@r.case
def kit_sim_numbers_every_slot():
    w, c = solo()
    open_kit(w, c)
    run_kit(w, c)
    res = c.eval_py("""
      local r = ns.Kit:Results()
      if not r then return nil end
      return { prog = r.prog, farm = r.farm, best = r.best, budget = r.budget }""")
    assert res, "no results"
    assert res["prog"] > 0, res
    assert res["best"]["flask"] > 0, res
    assert res["best"]["potion"] > 0, res
    assert "food" in res["best"] and "food" in res["budget"], res
    s = snap(c)
    assert s["bar"]["sim"] is False and s["bar"]["progShown"] is True, s["bar"]
    assert s["bar"]["prog"].endswith("DPS"), s["bar"]
    assert row(s, "FLASK")["bestLine"].endswith("DPS"), row(s, "FLASK")
    # each run had its own consumables: the kit's runs are all different scenarios
    keys = c.eval("local n = 0 for k in pairs(ns.SimRunner.cache) do n = n + 1 end return n")
    assert keys >= 10, keys
    # gear changes make the numbers old
    c.equip({13: 28034})
    settle(w, 0.3)
    assert c.eval("return ns.Kit:Results() == nil") is True
    assert_no_lua_errors(w)


@r.case
def healer_has_no_sim_and_says_why():
    w, c = solo(spec="Holy")
    open_kit(w, c)
    s = snap(c)
    assert s["bar"]["sim"] is False and s["bar"]["progShown"] is False, s["bar"]
    assert row(s, "FLASK")["best"] == "Healing Power + Mageblood", s
    assert row(s, "POTION")["best"] == "Super Mana Potion", s
    assert c.eval("return ns.Kit:CanSim()") is False
    assert_no_lua_errors(w)


@r.case
def every_spec_has_a_kit_of_known_items():
    w, c = solo()
    missing = c.eval_py("""
      local out = {}
      local D = ns.Data.Consumables
      for cls, specs in pairs(ns.SPECS) do
        for _, s in ipairs(specs) do
          local key = cls .. ":" .. s.label
          local kit = D.KITS[key]
          if not kit then out[#out + 1] = "no kit " .. key
          else
            for slot, k in pairs(kit) do
              for _, list in ipairs({ k.best, type(k.budget) == "table" and k.budget or {} }) do
                for _, id in ipairs(list) do
                  if not D.ITEMS[id] then out[#out + 1] = key .. " " .. slot .. " " .. id end
                end
              end
            end
          end
        end
      end
      -- what the sim data knows by id (flasks, elixirs, food, potions)
      for id, it in pairs(D.ITEMS) do
        local kind = it[4]
        if (kind == "flask" or kind == "battle" or kind == "guardian" or kind == "food" or kind == "potion")
          and not ns.Data.SimConsumables[id] then out[#out + 1] = "not in sim data " .. id end
      end
      return out""")
    assert missing == [] or missing == {}, missing


if __name__ == "__main__":
    r.run()

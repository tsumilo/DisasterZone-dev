"""Craft materials in tooltips (UI/Tooltip.lua AddMaterials / CraftRow, Core/Atlas.lua GetCraft, Data/Atlas.lua
AtlasCrafts): Shift held over a crafted item shows what its craft needs, with how many I have (bags and bank); over a
craft in the Atlas tab or the Members tab the mouse wheel (Shift held) sets how many to make, and the wheel scrolls
the list as before without Shift.

Run: luaenv\\Scripts\\python.exe tests\\atlas\\test_craft_materials.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import case, run_all, solo, no_errors, install_helpers, strip_codes, tt_lines  # noqa: E402

BAG = 21843          # Imbued Netherweave Bag (Tailoring 26749): 4 Bolt of Imbued Netherweave, 2 Netherweb Spider
BAG_SPELL = 26749    # Silk, 1 Greater Planar Essence
BOLT, SILK, ESSENCE = 21842, 21881, 22446
MONGOOSE = 27984     # Enchant Weapon - Mongoose (makes no item)
MONGOOSE_FORMULA = 22559
SHELLS = 23772       # Fel Iron Shells: one craft makes 200
SHARD = 22449        # Large Prismatic Shard: two crafts make it

LUA = r"""
function T_atlas_itemrow(id)
  local _, _, list = ns.AtlasUI:GetLists()
  for _, r in ipairs(list.box:GetFrames()) do
    local d = rawget(r, "__cdlData")
    if d and d.type == "item" and d.id == id and r:IsShown() then return r end
  end
end
function T_wheel(frame, delta) frame:GetScript("OnMouseWheel")(frame, delta) end
"""


def setup(**kw):
    w, c = solo("Alice", class_file="PALADIN", guild_rank=3, tick=4, council=[], **kw)
    install_helpers(c)
    c.eval(LUA)
    return w, c


def lines(c):
    return [(strip_codes(l).strip(), strip_codes(r or "").strip()) for l, r in tt_lines(c)]


def lefts(c):
    return [l for l, _ in lines(c)]


def right_of(c, text):
    return next((r for l, r in lines(c) if l.endswith(text)), None)


def atlas_row(w, c, item_id):
    c.eval("ns.MainFrame:Open('atlas')")
    w.tick(0.3)
    c.eval("ns.AtlasUI:GoTo(ns.Atlas:GetLocations(...)[1])", item_id)
    w.tick(0.2)
    row = c.eval("return T_atlas_itemrow(...)", item_id)
    assert row, "no row for %d" % item_id
    return row


# ------------------------------------------------------------------------------------------------------------------
@case
def every_craft_has_its_reagents_named():
    w, c = setup()
    craft = c.eval_py("return ns.Atlas:GetCraft(...)", BAG)
    assert craft["spell"] == BAG_SPELL and craft["item"] == BAG and craft["made"] == 1, craft
    assert [(r["id"], r["count"]) for r in craft["reagents"]] == [(BOLT, 4), (SILK, 2), (ESSENCE, 1)], craft
    # an enchant by its spell, a formula by what it teaches, a craft that makes 200, an item two crafts make
    assert c.eval_py("return ns.Atlas:GetCraft(...)", -MONGOOSE)["item"] == 0
    assert c.eval_py("return ns.Atlas:GetCraft(...)", MONGOOSE_FORMULA)["spell"] == MONGOOSE
    assert c.eval_py("return ns.Atlas:GetCraft(...)", SHELLS)["made"] == 200
    assert c.eval_py("return ns.Atlas:GetCraft(...)", SHARD)["spell"] == 28022
    assert c.eval("return ns.Atlas:GetCraft(28505)") is None        # a raid drop
    bad = c.eval_py("""local bad, n = {}, 0
      for spell in pairs(ns.Data.AtlasCrafts) do
        n = n + 1
        local cr = ns.Atlas:GetCraft(-spell)
        if not cr or #cr.reagents == 0 or cr.made < 1 then bad[#bad + 1] = spell
        else
          for _, r in ipairs(cr.reagents) do
            if r.count < 1 or not ns.Atlas:GetShippedName(r.id) then bad[#bad + 1] = spell break end
          end
        end
      end
      return { n, bad }""")
    assert bad[0] > 2000 and not bad[1], bad[1][:10] if bad[1] else bad
    no_errors(w)


@case
def shift_shows_the_materials_on_any_item_tooltip():
    w, c = setup()
    plain = [l for l, _ in c.show_tooltip_item(BAG)]
    assert not any("Materials" in l for l in plain), plain
    c.set_bags({(0, 1): (BOLT, 6), (0, 2): (SILK, 1)})
    c.set_modifiers(shift=True)
    # pressing Shift over a shown tooltip adds the block once
    ls = lefts(c)
    assert ls.count("Materials") == 1, ls
    assert right_of(c, "Bolt of Imbued Netherweave") == "6/4", lines(c)
    assert right_of(c, "Netherweb Spider Silk") == "1/2", lines(c)
    assert right_of(c, "Greater Planar Essence") == "0/1", lines(c)
    c.set_modifiers(shift=False)
    c.set_modifiers(shift=True)
    assert lefts(c).count("Materials") == 1, lefts(c)
    # Shift already held when the tooltip opens; no hint lines outside the addon's lists
    ls = [strip_codes(l) for l, _ in c.show_tooltip_item(BAG)]
    assert "Materials" in ls and not any("Mouse wheel" in l or "Hold Shift" in l for l in ls), ls
    # an item no craft makes: nothing
    assert not any("Materials" in strip_codes(l) for l, _ in c.show_tooltip_item(28505))
    # the comparison tooltips Shift opens next to an item stay as they are; a chat link gets the block
    c.eval("ShoppingTooltip1:SetOwner(UIParent, 'ANCHOR_NONE'); ShoppingTooltip1:SetItemByID(...)", BAG)
    assert not any("Materials" in l for l, _ in tt_lines(c, "ShoppingTooltip1")), tt_lines(c, "ShoppingTooltip1")
    c.eval("ItemRefTooltip:SetOwner(UIParent, 'ANCHOR_NONE'); ItemRefTooltip:SetItemByID(...)", BAG)
    assert [l for l, _ in tt_lines(c, "ItemRefTooltip")].count("Materials") == 1
    # the item hook firing twice for one tooltip adds the block once
    c.eval("ns.Tooltip:HookTooltip(ItemRefTooltip); for _, f in ipairs({ ItemRefTooltip:GetScript('OnTooltipSetItem') }) do f(ItemRefTooltip) end")
    assert [l for l, _ in tt_lines(c, "ItemRefTooltip")].count("Materials") == 1
    no_errors(w)


@case
def an_atlas_craft_row_takes_the_amount_from_the_mouse_wheel():
    w, c = setup()
    row = atlas_row(w, c, BAG)
    wheel = "local r = ...; return r:IsMouseWheelEnabled()"
    c.hover(row)
    ls = lefts(c)
    assert ls[-1] == "Hold Shift: materials" and "Materials" not in ls, ls
    assert not c.eval(wheel, row), "without Shift the wheel belongs to the list"
    c.set_modifiers(shift=True)
    ls = lefts(c)
    assert "Materials" in ls and ls[-2] == "Mouse wheel: change the amount", ls
    assert c.eval(wheel, row)
    assert ls.index("Skill 340") < ls.index("Materials"), ls       # under the row's own lines
    assert right_of(c, "Bolt of Imbued Netherweave") == "0/4"
    c.eval("T_wheel(...)", row, 1)
    c.eval("T_wheel(...)", row, 1)
    assert "Materials ×3" in lefts(c), lefts(c)
    assert right_of(c, "Bolt of Imbued Netherweave") == "0/12" and right_of(c, "Netherweb Spider Silk") == "0/6"
    assert c.eval("return (ns.Tooltip:GetMaterialsAmount())") == 3
    for _ in range(5):
        c.eval("T_wheel(...)", row, -1)
    assert "Materials" in lefts(c) and c.eval("return (ns.Tooltip:GetMaterialsAmount())") == 1
    c.eval("T_wheel(...)", row, 1)
    # releasing Shift hides the block; the amount stays for this craft
    c.set_modifiers(shift=False)
    assert "Materials" not in " ".join(lefts(c)) and lefts(c)[-1] == "Hold Shift: materials", lefts(c)
    c.set_modifiers(shift=True)
    assert "Materials ×2" in lefts(c), lefts(c)
    # without Shift the row gives the wheel back; a turn that still reaches it goes to the list (the nearest
    # parent with a wheel script); leaving the row gives it back too
    c.set_modifiers(shift=False)
    assert not c.eval(wheel, row)
    c.set_modifiers(shift=True)
    c.leave(row)
    assert not c.eval(wheel, row)
    c.hover(row)
    c.set_modifiers(shift=False)
    c.eval("""local row = ...; T_fw = nil
      row:GetParent():SetScript("OnMouseWheel", function(_, d) T_fw = d end)""", row)
    c.eval("T_wheel(...)", row, -1)
    assert c.eval("return T_fw") == -1 and c.eval("return (ns.Tooltip:GetMaterialsAmount())") == 2
    # another craft starts at 1
    c.leave(row)
    other = atlas_row(w, c, 21841)       # Netherweave Bag
    c.set_modifiers(shift=True)
    c.hover(other)
    assert "Materials" in lefts(c) and c.eval("return (ns.Tooltip:GetMaterialsAmount())") == 1, lefts(c)
    no_errors(w)


def mats_lines(c):
    """[(left, right)] of the materials block: the header first."""
    ls = lines(c)
    i = next(k for k, (l, _) in enumerate(ls) if l.startswith("Materials"))
    out = [ls[i]]
    for l, r in ls[i + 1:]:
        if not r or "/" not in r:
            break
        out.append((l, r))
    return out


def materials(c, item_id, crafts, depth):
    """Atlas:GetMaterials as [[(id, count), ...], depth reached, one more step possible]."""
    got = c.eval_py("""local list, level, deeper = ns.Atlas:GetMaterials(...)
      local o = {} for k, e in ipairs(list) do o[k] = { e.id, e.count } end return { o, level, deeper }""",
                    item_id, crafts, depth)
    return [[tuple(x) for x in got[0]], got[1], got[2]]


@case
def breaking_materials_down_follows_crafts_but_not_transmutes():
    w, c = setup()
    assert materials(c, BAG, 1, 0) == [[(BOLT, 4), (SILK, 2), (ESSENCE, 1)], 0, True]
    # a step: the imbued bolts become 3 Bolt of Netherweave + 2 Arcane Dust each, in their place
    got = materials(c, BAG, 2, 1)
    assert got == [[(21840, 24), (22445, 16), (SILK, 4), (ESSENCE, 2)], 1, True], got
    # two steps: the bolts become cloth; Arcane Dust stays (disenchanted, not made from an Arcane Crystal); the end
    got = materials(c, BAG, 2, 5)
    assert got == [[(21877, 144), (22445, 16), (SILK, 4), (ESSENCE, 2)], 2, False], got
    # Primal Might: the primals are only transmuted from each other, so nothing breaks down
    got = materials(c, 23571, 1, 3)
    assert len(got[0]) == 5 and got[1:] == [0, False], got
    no_errors(w)


@case
def the_cooldown_cloths_are_items_that_break_down():
    # AtlasLoot's table has { nil, ... } for Shadowcloth / Spellcloth / Primal Mooncloth and fills the created item in
    # with "fix" lines after it: they are item rows (their own icons) with materials, and they break down
    w, c = setup()
    spellcloth, shadowcloth, mooncloth = 24271, 24272, 21845
    for item, spell in ((spellcloth, 31373), (shadowcloth, 36686), (mooncloth, 26751)):
        craft = c.eval_py("return ns.Atlas:GetCraft(...)", item)
        assert craft and craft["spell"] == spell and craft["item"] == item, (item, craft)
        assert c.eval("return ns.Atlas:GetLocations(...) ~= nil", item), item
        assert c.eval("return ns.Atlas:GetLocations(...) == nil", -spell), spell
    # Spellfire Bag: 6 Spellcloth, 4 Greater Planar Essence, 4 Netherweb Spider Silk; Spellcloth is an Imbued bolt,
    # a Primal Mana and a Primal Fire
    got = materials(c, 21858, 1, 1)
    assert got == [[(BOLT, 6), (22457, 6), (21884, 6), (ESSENCE, 4), (SILK, 4)], 1, True], got
    assert materials(c, 21858, 1, 9)[0][0] == (21877, 108)    # down to Netherweave Cloth
    # a transmute listed as its spell (its page lists Primal Earth already) is not called an enchant
    row = atlas_row(w, c, -28568)
    assert strip_codes(c.eval("local r = ...; return r.sub:GetText()", row)) != "Enchant"
    assert strip_codes(c.eval("local r = ...; return r.sub:GetText()", atlas_row(w, c, -MONGOOSE))) == "Enchant"
    no_errors(w)


@case
def shift_click_breaks_down_right_click_goes_back_and_releasing_shift_starts_over():
    w, c = setup()
    row = atlas_row(w, c, BAG)
    c.hover(row)
    c.set_modifiers(shift=True)
    assert lefts(c)[-2:] == ["Mouse wheel: change the amount", "Click: break down"], lefts(c)[-3:]
    c.click(row)
    m = mats_lines(c)
    assert m[0][0] == "Materials · broken down once", m
    assert [l for l, _ in m[1:]] == ["Bolt of Netherweave", "Arcane Dust", "Netherweb Spider Silk",
                                     "Greater Planar Essence"], m
    assert dict(m[1:])["Bolt of Netherweave"] == "0/12" and dict(m[1:])["Arcane Dust"] == "0/8", m
    assert lefts(c)[-1] == "Click: break down · Right-click: back up", lefts(c)[-3:]
    # the amount keeps the step
    c.eval("T_wheel(...)", row, 1)
    m = mats_lines(c)
    assert m[0][0] == "Materials ×2 · broken down once" and dict(m[1:])["Bolt of Netherweave"] == "0/24", m
    c.click(row)
    m = mats_lines(c)
    assert m[0][0] == "Materials ×2 · broken down twice" and dict(m[1:])["Netherweave Cloth"] == "0/144", m
    assert lefts(c)[-1] == "Right-click: back up", lefts(c)[-3:]
    # nothing left to break down: a click changes nothing (and links nothing)
    c.click(row)
    assert mats_lines(c)[0][0] == "Materials ×2 · broken down twice"
    assert c.eval("return (ns.Tooltip:GetMaterialsAmount())") == 2
    c.click(row, "RightButton")
    assert mats_lines(c)[0][0] == "Materials ×2 · broken down once"
    c.click(row, "RightButton")
    c.click(row, "RightButton")   # at the top: stays, and no item menu while the materials show
    assert mats_lines(c)[0][0] == "Materials ×2" and not c.eval("return __MOCK.last_menu ~= nil"), mats_lines(c)[0]
    # releasing Shift starts over (the amount stays)
    c.click(row)
    c.set_modifiers(shift=False)
    assert lefts(c)[-1] == "Hold Shift: materials"
    c.set_modifiers(shift=True)
    assert mats_lines(c)[0][0] == "Materials ×2", mats_lines(c)[0]
    # without Shift a right-click opens the item menu as before
    c.set_modifiers(shift=False)
    c.click(row, "RightButton")
    assert c.eval("return __MOCK.last_menu ~= nil")
    no_errors(w)


@case
def enchants_and_crafts_that_make_several():
    w, c = setup()
    c.set_modifiers(shift=True)
    row = atlas_row(w, c, -MONGOOSE)
    c.hover(row)
    assert right_of(c, "Large Prismatic Shard") == "0/10" and right_of(c, "Arcane Dust") == "0/40", lines(c)
    c.leave(row)
    row = atlas_row(w, c, SHELLS)
    c.hover(row)
    head = next((l, r) for l, r in lines(c) if l.startswith("Materials"))
    assert head == ("Materials", "makes 200"), head
    c.eval("T_wheel(...)", row, 1)
    head = next((l, r) for l, r in lines(c) if l.startswith("Materials"))
    assert head == ("Materials ×2", "makes 400") and right_of(c, "Fel Iron Bar") == "0/4", lines(c)
    no_errors(w)


if __name__ == "__main__":
    run_all()

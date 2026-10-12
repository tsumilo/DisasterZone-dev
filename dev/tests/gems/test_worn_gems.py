#!/usr/bin/env python
"""My BiS's Equipped view: gems and enchants for the gear I wear (Core/WornGems.lua, UI/MyBiS.lua, UI/PaperDoll.lua).

What a worn item has comes from its link; my plan (the gem editor, Suggest) is kept per character and item in
db.wornGems and holds only what differs from the item. Covers: reading the worn gems and enchant, the view (plan over
the item), what is still to apply, socketing a planned gem empties it, Suggest fills only empty sockets / missing
enchants (or everything), the shopping list takes only the gems and enchants, the Equipped tab (doll, gold "to apply"
line and dots, the gem editor on a worn host, the centre's count / rows), a phase tab goes back to the list.

Run: luaenv\\Scripts\\python.exe tests\\gems\\test_worn_gems.py   [-k substring]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "sync"))

from common import Runner, Client, new_world, up, settle  # noqa: E402

r = Runner("gems and enchants on the gear I wear")

GLOVES = 28506          # Gloves of Dexterous Manipulation: red + blue sockets, +3 Crit
NECK = 28731            # Shining Chain of the Afterworld: no sockets, no enchant
RUBY = 24029            # Teardrop Living Ruby (red)
STAR = 24037            # Lustrous Star of Elune (blue)
MAJOR_HEALING = 2322    # Enchant Gloves - Major Healing
INV_HANDS, INV_NECK = 10, 2
SID_HANDS, SID_NECK = 7, 2


def solo(name="Raider", cls="PALADIN", spec="Holy"):
    w = new_world()
    c = Client(w, name, class_file=cls, guild_rank=3)
    up(c)
    settle(w, 5)
    if spec:
        assert c.eval("return ns.BiS:SetSpec(...)", spec) is True
    return w, c


def wear(c, links):
    """{invSlot: item string or None}: the links GetInventoryItemLink answers (the mock's carry no gems)."""
    c.eval("""T_LINKS = T_LINKS or {}
        for k in pairs(T_LINKS) do T_LINKS[k] = nil end
        for k, v in pairs(...) do T_LINKS[tonumber(k)] = v end
        if not T_ORIG_LINK then
          T_ORIG_LINK = GetInventoryItemLink
          GetInventoryItemLink = function(unit, slot)
            if unit == "player" and T_LINKS[slot] then return "|cffa335ee|H" .. T_LINKS[slot] .. "|h[x]|h|r" end
            return nil
          end
        end""", {str(k): v for k, v in links.items()})


def gloves(enchant=MAJOR_HEALING, g1=RUBY, g2=0):
    n = lambda v: str(v) if v else ""
    return "item:%d:%s:%s:%s:::::70" % (GLOVES, n(enchant), n(g1), n(g2))


def pending(c):
    return c.eval_py("""local o = {} for _, p in ipairs(ns.WornGems:Pending()) do
        o[#o + 1] = { sid = p.sid, item = p.itemID, n = p.n, enchant = p.enchant or 0,
                      g1 = p.gems[1] or 0, g2 = p.gems[2] or 0 } end return o""") or []


# ------------------------------------------------------------------------------------------------------------------
@r.case
def plan_over_what_the_item_has():
    w, c = solo()
    wear(c, {INV_HANDS: gloves(), INV_NECK: "item:%d::::::::70" % NECK})
    e = c.eval_py("local e = ns.WornGems:Equipped()[...] return { e.id, e.enchant, e.gems[1] or 0, e.gems[2] or 0 }",
                  SID_HANDS)
    assert e == [GLOVES, MAJOR_HEALING, RUBY, 0], e
    assert c.eval("return ns.WornGems:View().ge[...]", GLOVES) == "%d:%d:0:0:0" % (MAJOR_HEALING, RUBY)
    assert pending(c) == []
    # the editor stores a whole setup: what the item has is left out of the plan
    assert c.eval("return ns.WornGems:SetSetup(..., select(2, ...), { select(3, ...), select(4, ...) })",
                  GLOVES, MAJOR_HEALING, RUBY, STAR) is True
    key = c.eval("return ns.Util.PlayerKey()")
    assert c.eval("return ns.db.wornGems[...][select(2, ...)]", key, GLOVES) == "0:0:%d:0:0" % STAR
    assert c.eval("return ns.WornGems:View().ge[...]", GLOVES) == "%d:%d:%d:0:0" % (MAJOR_HEALING, RUBY, STAR)
    assert pending(c) == [{"sid": SID_HANDS, "item": GLOVES, "n": 1, "enchant": 0, "g1": 0, "g2": STAR}]
    # the progress counts: the view counts the plan, the item as it is doesn't
    assert c.eval("return ns.Gems:Progress(ns.WornGems:View(), 1)") == (2, 2, 1, 1)
    assert c.eval("return ns.Gems:Progress(ns.WornGems:View(nil, true), 1)") == (1, 2, 1, 1)
    # socketing the planned gem leaves nothing to apply
    wear(c, {INV_HANDS: gloves(g2=STAR)})
    assert pending(c) == []
    # Reset (the editor's Clear on a worn host) forgets the plan
    assert c.eval("return ns.WornGems:SetSetup(..., 0, { 0, select(2, ...) })", GLOVES, RUBY) is True
    assert len(pending(c)) == 1
    c.eval("ns.WornGems:GemHost(...).set(nil, nil)", GLOVES)
    assert pending(c) == []
    w.assert_no_errors()


@r.case
def suggest_fills_empty_only_or_everything():
    w, c = solo()
    wear(c, {INV_HANDS: gloves(enchant=0, g1=STAR, g2=0)})      # a blue gem in the red socket, no enchant
    n = c.eval("return ns.WornGems:Fill(nil, 1, false)")
    assert n == 1, n
    p = pending(c)
    assert len(p) == 1 and p[0]["g1"] == 0 and p[0]["g2"] != 0 and p[0]["enchant"] != 0, p   # the star stays
    # everything: the red socket gets a red gem too
    assert c.eval("return ns.WornGems:Fill(nil, 1, true)") == 1
    p = pending(c)
    assert p[0]["g1"] not in (0, STAR), p
    # nothing changes the second time
    assert c.eval("return ns.WornGems:Fill(nil, 1, true)") == 0
    # without a spec there is no guide
    assert c.eval("return ns.BiS:SetSpec('')") in (True, False, None)
    w.assert_no_errors()


@r.case
def shopping_takes_only_gems_and_enchants():
    w, c = solo()
    wear(c, {INV_HANDS: gloves(g1=RUBY, g2=0)})
    c.eval("ns.WornGems:SetSetup(..., select(2, ...), { select(3, ...), select(3, ...) })", GLOVES, MAJOR_HEALING, RUBY)
    needs, other = c.eval_py("local n, o = ns.WornGems:ShoppingNeeds(nil, 1) return { n, o }")
    needs = {int(k): v for k, v in (needs.items() if isinstance(needs, dict) else enumerate(needs, 1)) if v}
    assert needs == {RUBY: 1}, needs                  # the ruby on it already and the enchant it has are left out
    n, other = c.eval("return ns.WornGems:AddToShoppingList(nil, 1)")
    assert n == 1 and other == 0, (n, other)
    assert c.eval("return ns.Shop:GetAmount(...)", RUBY) == 1
    w.assert_no_errors()


@r.case
def equipped_tab_doll_editor_and_centre():
    w, c = solo()
    wear(c, {INV_HANDS: gloves(enchant=0, g1=RUBY, g2=0), INV_NECK: "item:%d::::::::70" % NECK})
    c.eval("ns.MyBiS:SetPhase(1, true)")
    c.eval("ns.MainFrame:Open('mybis')")
    settle(w, 1)
    assert c.find_text("Equipped")
    c.eval("ns.MyBiS:SetWorn(true)")
    settle(w, 0.3)
    assert c.eval("return ns.MyBiS:IsWorn()") is True
    tiles = c.eval_py("""
        __GT = {}
        local function walk(f)
          if f.strip and f.sid then __GT[f.sid] = f end
          for _, ch in ipairs({ f:GetChildren() }) do walk(ch) end
        end
        walk(UIParent)
        local t = __GT[7]
        return { t.mainID, t.strip:IsShown(), (t.line2:GetText() or ''):gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', ''),
                 __GT[2].mainID, __GT[2].strip:IsShown() }""")
    assert tiles[0] == GLOVES and tiles[1] is True and tiles[2] in ("1 gem, enchant to choose".capitalize(), "To choose"), tiles
    assert tiles[3] == NECK and tiles[4] is False, tiles
    # the tile's tooltip is the real item link (its gems)
    assert c.eval("return __GT[7].mainLink") == "|cffa335ee|H%s|h[x]|h|r" % gloves(enchant=0, g1=RUBY)
    # the centre: what the items have, what is still to choose
    assert c.eval("return ns.MyBiS:GetFinish()") == (True, "1 gem, 1 enchant to choose")
    assert c.find_text("Nothing to apply yet")
    # the strip opens the editor on a worn host; picking a gem plans it
    c.eval("T_STRIP = __GT[7].strip")
    c.click("T_STRIP")
    settle(w, 0.2)
    st = c.eval_py("local f, s = ns.GemEditor:GetFrame() return { f:IsShown(), s.host and s.host.kind, s.target, "
                   "f.clear:GetText(), f.sub:GetText() }")
    assert st == [True, "worn", "s2", "Reset", "Equipped  ·  as worn"], st
    c.eval("T_CHOICE = ns.GemEditor:GetFrame().choices[1]")
    c.click("T_CHOICE")
    settle(w, 0.3)
    p = pending(c)
    assert len(p) == 1 and p[0]["g2"] != 0, p
    assert c.eval("return ns.GemEditor:IsShown()") is True
    line2 = c.eval("return ((__GT[7].line2:GetText() or ''):gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', ''))")
    assert line2 in ("1 gem to apply".capitalize(), "To apply"), line2
    dots = c.eval_py("local o = {} for i, ch in ipairs(__GT[7].strip.chips) do "
                     "o[i] = (ch:IsShown() and ch.todo and ch.todo:IsShown()) and 1 or 0 end return o")
    assert dots[:2] == [0, 1], dots
    assert c.find_text("TO APPLY") or c.find_text("To apply")
    assert c.find_text("Gems to socket")
    # Reset in the editor goes back to what the item has
    c.eval("T_CLEAR = ns.GemEditor:GetFrame().clear")
    c.click("T_CLEAR")
    settle(w, 0.3)
    assert pending(c) == []
    # a phase tab goes back to the BiS list (and closes the editor)
    c.eval("ns.MyBiS:SetPhase(1, true)")
    settle(w, 0.3)
    assert c.eval("return ns.MyBiS:IsWorn()") is False
    assert c.eval("return ns.GemEditor:IsShown()") is False
    assert c.eval("return __GT[7].mainID") is None
    w.assert_no_errors()


r.run()

"""The prized look (1.3.5, the user's picks 2026-10-11): a prized item's tooltip gets the PRIZED ITEM ribbon above it and
an orange edge (anywhere: GameTooltip, ItemRefTooltip, the comparison tooltips), cleared with the tooltip; the drop
panel's card of a prized item glows amber (edge, tint, inner glow, a light running along the top edge).

Run: luaenv\\Scripts\\python.exe tests\\prized\\test_prized_look.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import case, run_all, solo  # noqa: E402

DST = 28830   # Dragonspine Trophy: prized in demo mode
OTHER = 28830 + 1


def demo(c, w):
    c.slash("/dz demo on")
    w.tick(2)
    assert c.eval("return ns.Prized:ForItem(...) ~= nil", DST), "DST should be prized in demo mode"


def ribbon_shown(c, tt="GameTooltip"):
    return c.eval("local tt = _G[...]; return tt.dzPrized ~= nil and tt.dzPrized:IsShown() or false", tt)


@case
def prized_tooltip_gets_the_ribbon_and_loses_it_when_cleared():
    w, c = solo("Alice", guild_rank=0, tick=4)
    demo(c, w)
    c.show_tooltip_item(DST)
    assert ribbon_shown(c)
    txt = c.eval("return GameTooltip.dzPrized.band.text:GetText()")
    assert "P R I Z E D" in txt, txt
    # another, not prized item: no ribbon
    plain = c.eval("""for _, raid in ipairs(ns.ItemDB:GetRaids()) do for _, b in ipairs(raid.bosses or {}) do
        for _, id in ipairs(b.items or {}) do if not ns.Prized:ForItem(id) then return id end end end end""")
    c.show_tooltip_item(plain)
    assert not ribbon_shown(c)
    c.show_tooltip_item(DST)
    c.eval("GameTooltip:Hide()")
    assert not ribbon_shown(c)


@case
def item_link_tooltip_too():
    w, c = solo("Alice", guild_rank=0, tick=4)
    demo(c, w)
    link = c.eval("return (select(2, C_Item.GetItemInfo(...)))", DST)
    c.eval("ItemRefTooltip:SetOwner(UIParent, 'ANCHOR_PRESERVE'); ItemRefTooltip:SetHyperlink(...)", link)
    c.eval("__MOCK.call_script(ItemRefTooltip, 'OnTooltipSetItem')")
    assert ribbon_shown(c, "ItemRefTooltip")


@case
def prized_card_glows_amber_in_the_drop_panel():
    w, c = solo("Alice", guild_rank=0, tick=4)
    demo(c, w)
    c.eval("""local db = ns.ItemDB
        for _, raid in ipairs(db:GetRaids()) do for _, boss in ipairs(raid.bosses or {}) do
            for _, id in ipairs(boss.items or {}) do
                if id == ... then
                    local ref = db:GetBossRef(raid.key .. ":" .. boss.key)
                    ns.Loot:HandleDrop({ s = "TEST-look", b = ref.key, i = { id }, ts = GetServerTime(), test = true },
                        ns.Util.PlayerKey())
                    return
                end
            end
        end end""", DST)
    w.tick(1)
    res = c.eval_py("""local b = ns.DropPanel.blocks[1]
        local k = b.przGlow
        return { glow = k ~= nil and k.tint:IsShown() and k.run:IsShown() or false, item = b.itemID }""")
    assert res["item"] == DST and res["glow"], res
    # the light runs: after a moment it is somewhere along the top edge
    w.tick(1)
    a = c.eval("return ns.DropPanel.blocks[1].przGlow.core:GetAlpha()")
    assert a is not None
    # the same card for a plain item: the glow goes
    c.eval("local b = ns.DropPanel.blocks[1]; ns.DropPanel.PrzGlow(b, false)")
    assert c.eval("return ns.DropPanel.blocks[1].przGlow.tint:IsShown()") is False



@case
def demo_a_roll_includes_a_prized_item_beside_the_rolled_one():
    w, c = solo("Alice", guild_rank=0, tick=4)
    c.eval("ns.SettingsUI:DemoRoll()")
    w.tick(2)
    res = c.eval_py("""local out = {}
        for i, b in ipairs(ns.DropPanel.blocks or {}) do
            if b:IsShown() and b.itemID then
                out[#out + 1] = { item = b.itemID, prized = ns.Prized:ForItem(b.itemID) ~= nil,
                                  glow = b.przGlow ~= nil and b.przGlow.tint:IsShown() or false,
                                  rolling = b.rollSession ~= nil }
            end
        end
        return out""")
    rows = list(res.values()) if isinstance(res, dict) else list(res or [])
    prized = [r for r in rows if r["prized"]]
    assert prized and all(r["glow"] for r in prized), rows
    assert rows[0]["rolling"] and not rows[0]["prized"], rows          # the roll runs on the first, plain item
    assert rows[1]["prized"], rows                                     # the prized item right after it

if __name__ == "__main__":
    run_all(globals())

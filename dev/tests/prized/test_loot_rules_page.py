#!/usr/bin/env python
"""Raids > Loot rules (1.3.5, UI/LootRulesUI.lua): the guild's loot rules and the prized items, read-only, for every
member. Covers: a raider (no council) opens it from the Raids menu; the steps follow the guild's rules (the floor, a
split vote, lists first or the roll, longest use and the driest); Where you stand reads my own BiS list; the prized
items gallery and an item opened, and back.

Run: luaenv\\Scripts\\python.exe tests\\prized\\test_loot_rules_page.py [-k substring]   (from dev)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "loot-roll"))
sys.path.insert(0, HERE)

from lr_common import *  # noqa: F401,F403,E402
from test_prized import guild_world, add, DST  # noqa: E402

R = Runner("Raids > Loot rules page (1.3.5)")

STEPS = r"""
local p = DisasterZoneLootRulesPanel
local out = {}
for i, s in ipairs(p.decided.path.steps) do
  if s:IsShown() then
    local chips = {}
    for j = 1, s.pills:Active() do chips[j] = s.pills.items[j].fs:GetText() end
    out[#out + 1] = { title = s.title:GetText(), text = s.text:GetText(), chips = chips }
  end
end
return out
"""


def steps(c):
    res = c.eval_py(STEPS) or []
    rows = [res[k] for k in sorted(res)] if isinstance(res, dict) else list(res)
    out = []
    for r in rows:
        if isinstance(r, dict) and "title" not in r:
            r = {"title": r.get(1), "text": r.get(2), "chips": r.get(3)}
        out.append(r)
    return out


@R.case
def a_raider_reads_the_rules_as_steps():
    w, c = guild_world()
    carol = c["Carol"]
    assert carol.eval("return ns.Guild:AmICouncil() == false")
    carol.eval("ns.MainFrame:Open('lootrules')")
    w.tick(1)
    assert carol.eval("return DisasterZoneLootRulesPanel ~= nil and DisasterZoneLootRulesPanel:IsVisible()")
    st = steps(carol)
    assert [s["title"] for s in st] == ["Who can be suggested", "The council's votes come first",
                                        "No votes yet? Your list sets your group", "Then, inside a group"], st
    assert "The highest roll wins." in st[3]["text"], st[3]
    # the GM changes the rules: the floor, the council picks a tie, longest use to P4 and the driest
    c["Alice"].eval("ns.Guild:SetLootRules({ f = 60, s = 'p', l = 'l', w = 'd', y = 'n', o = 4 })")
    w.tick(6)
    st = steps(carol)
    chips = [x for s in st for x in (s["chips"].values() if isinstance(s["chips"], dict) else s["chips"])]
    assert "60%+ attendance" in chips, chips
    assert "A tie: the council picks" in chips, chips
    assert "Longest use, to P4" in chips and "Driest first" in chips, chips
    assert "longest (to P4)" in st[3]["text"] and "most raids since" in st[3]["text"], st[3]
    # the roll only, before votes
    c["Alice"].eval("ns.Guild:SetLootRules({ f = 0, s = 'r', l = 'r', w = 'r', y = 'n', o = 0 })")
    w.tick(6)
    st = steps(carol)
    assert st[2]["title"] == "No votes yet? The roll decides" and st[3]["title"] == "The roll", st
    w.assert_no_errors()


@R.case
def where_you_stand_counts_my_own_list():
    w, c = guild_world()
    carol = c["Carol"]
    carol.eval("ns.BiS:SetSlot(1, 1, 'main', 29011); ns.BiS:SetSlot(1, 11, 'main', 28757); ns.BiS:Commit()")
    carol.eval("ns.MainFrame:Open('lootrules')")
    w.tick(1)
    big = carol.eval("return DisasterZoneLootRulesPanel.decided.you.bis.big:GetText()")
    assert big.startswith("2"), big
    note = carol.eval("return DisasterZoneLootRulesPanel.decided.you.bis.note:GetText()")
    assert note.startswith("Empty: ") and "Head" not in note, note
    w.assert_no_errors()


@R.case
def a_two_hander_leaves_the_off_hand_out():
    w, c = guild_world()
    carol = c["Carol"]
    assert carol.eval("return ns.ItemDB:GetEquipLoc(28773)") == "INVTYPE_2HWEAPON"
    carol.eval("ns.BiS:SetSlot(1, 1, 'main', 29011); ns.BiS:SetSlot(1, 15, 'main', 28773); ns.BiS:Commit()")
    carol.eval("ns.MainFrame:Open('lootrules')")
    w.tick(1)
    big = carol.eval("return DisasterZoneLootRulesPanel.decided.you.bis.big:GetText()")
    note = carol.eval("return DisasterZoneLootRulesPanel.decided.you.bis.note:GetText()")
    assert "Off Hand" not in note, note
    total = carol.eval("local n = 0; for _ in ipairs(ns.SLOTS) do n = n + 1 end; return n")
    assert big.startswith("2") and ("/ %d " % (total - 1)) in big, big
    w.assert_no_errors()


@R.case
def the_gallery_and_an_item():
    w, c = guild_world()
    add(c["Alice"], [DST], {"rank": {"m": "r", "i": 2}, "vote": {"s": "all"}})
    w.tick(3)
    carol = c["Carol"]
    carol.eval("ns.MainFrame:Open('lootrules'); ns.LootRulesUI:SetView('prized')")
    w.tick(1)
    p = "DisasterZoneLootRulesPanel"
    assert carol.eval("return %s.gallery:IsShown() and %s.gallery.cards[1]:IsShown()" % (p, p))
    # Carol (rank 3) breaks the rank rule: her card says so
    pill = carol.eval("return %s.gallery.cards[1].pill.fs:GetText()" % p)
    assert pill == "Not yet", pill
    carol.eval("%s.gallery.cards[1]:Click()" % p)
    w.tick(0.5)
    assert carol.eval("return ns.LootRulesUI:GetItem()") == str(DST)
    assert carol.eval("return %s.item:IsShown() and %s.item.rules.rows[1]:IsShown()" % (p, p))
    carol.eval("%s.item.banner.back:Click()" % p)
    w.tick(0.5)
    assert carol.eval("return ns.LootRulesUI:GetItem() == nil and %s.gallery:IsShown()" % p)
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

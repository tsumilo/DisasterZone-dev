#!/usr/bin/env python
"""Loot-roll area: guests (players outside the guild in the raid) in open rolls.

A pug types /roll like everyone else: the roll counts on every client, the pug can be suggested and awarded, the
award lands in the loot log, and the pug's name carries a "(guest)" mark wherever the roll and its result are shown.
A guild member without the addon is not marked.

Run: luaenv\\Scripts\\python.exe tests\\loot-roll\\test_guest_rolls.py   [-k substring]
"""
from lr_common import *  # noqa: F401,F403

R = Runner("loot-roll / guest rolls")


def setup():
    r = Raid()
    r["Alice"].open_loot([(MINDBLADE, 4)])
    r.w.tick(2)
    return r


def guest_tag(c, name):
    return strip_codes(c.eval("return ns.UI:GuestTag(...)", key(name)))


@R.case
def a_pug_rolls_wins_and_is_marked_as_guest():
    r = setup()
    w = r.w
    alice, bob = r["Alice"], r["Bob"]
    alice.eval("ns.DropPanel:StartRoll(...)", MINDBLADE, 1)
    w.tick(1)
    sid = active_session(alice)["id"]
    w.player_roll("Yuri", 97)                  # the pug, without the addon
    w.player_roll("Zed", 40)                   # a guild member without the addon
    w.tick(31)
    for n in ("Alice", "Bob", "Carol"):
        res = results(r[n], sid)
        by = {x["key"]: x for x in res}
        assert by[key("Yuri")]["roll"] == 97 and by[key("Yuri")]["inRaid"], (n, res)
        assert res[0]["key"] == key("Yuri") and res[0]["suggested"], (n, res)     # nobody has it on a list: the roll decides
    # marked as a guest, on every client; guild members are not
    for n in ("Alice", "Bob", "Carol"):
        assert guest_tag(r[n], "Yuri") == " (guest)", n
        assert guest_tag(r[n], "Zed") == "" and guest_tag(r[n], "Bob") == "" and guest_tag(r[n], n) == "", n
    assert "Award to Yuri" in panel_blocks(bob)[0]["buttons"], panel_blocks(bob)[0]
    # the pug's roll row says "guest" where a spec would be (no "(guest)" after the narrow name column)
    marks = [o for o in bob.find_text("guest", True, True)
             if strip_codes(bob.eval("local o = ...; return o:GetText()", o) or "") == "guest"]
    rows = [strip_codes(bob.eval("""local o = ...; local t = {}
        for _, rg in ipairs({ o:GetParent():GetRegions() }) do
          if rg.GetText and rg:GetText() then t[#t + 1] = rg:GetText() end
        end
        return table.concat(t, " | ")""", o) or "") for o in marks]
    assert len(rows) == 1 and "Yuri" in rows[0], rows                       # the roll row of the pug, and only that one
    # the award goes through like any other, and is in the loot log
    alice.close_loot()
    alice.eval("ns.Roll:Award(...)", sid, key("Yuri"))
    w.tick(0.2)
    alice.accept_popup("DISASTERZONE_CONFIRM_AWARD")
    w.tick(3)
    for n in ("Alice", "Bob", "Carol"):
        s = session_info(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Yuri"), (n, s)
    assert "Yuri (guest)" in strip_codes(panel_blocks(bob)[0]["awarded"]), panel_blocks(bob)[0]
    led = [e for e in ledger_visible(alice) if e["i"] == MINDBLADE]
    assert len(led) == 1 and led[0]["w"] == key("Yuri"), led
    assert [e["w"] for e in ledger_visible(bob) if e["i"] == MINDBLADE] == [key("Yuri")]
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

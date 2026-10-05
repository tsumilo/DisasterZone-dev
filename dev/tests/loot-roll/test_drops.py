#!/usr/bin/env python
"""Loot-roll area, part 1: raid drops (SPEC §10.4, §12.8, Addendum §18).

DROP broadcast / receive / dedupe, council drop panel wanters, personal toast + chat line, loot-frame badges and
glow, tier tokens, Sunmote upgrades, duplicate items, group-loot START_LOOT_ROLL, and robustness (no loot source
GUID, junk loot links, uncached item data).

Run: luaenv\\Scripts\\python.exe tests\\loot-roll\\test_drops.py   [-k substring]
"""
from lr_common import *  # noqa: F401,F403

R = Runner("loot-roll / drops")

PRINCE_BOSS = "Karazhan:Prince"


def loot_prince(r, who="Alice", items=None, guid=PRINCE_GUID):
    items = items if items is not None else [(RUBY_DRAPE, 4), (THOUSAND_MARKS, 4), (HELM_CHAMPION, 4),
                                             (MINDBLADE, 4), (22829, 1)]   # 22829 = grey/white junk below threshold
    r[who].open_loot(items, source_guid=guid)


def own_bis_lines(c):
    return [strip_codes(l) for l in printed_lines(c) if "is on your BiS list" in l]


def loot_buttons(c):
    return c.eval_py(r"""
        local out = {}
        for i = 1, 4 do
          local b = _G['LootButton' .. i]
          out[i] = { shown = b:IsShown() and true or false, slot = b.slot,
                     badge = (b.cdlBadge and b.cdlBadge:IsShown()) and b.cdlBadge.text:GetText() or false,
                     glow = b.cdlGlow and true or false }
        end
        return out""")


# ------------------------------------------------------------------------------------------------------------------
@R.case
def drop_reaches_everyone_once_with_panels_toasts_badges():
    r = Raid()
    w = r.w
    log0 = len(w.addon_log)
    loot_prince(r)
    w.tick(2)

    D = msgs_of_type(w, "D", log0)
    assert len(D) == 1, "expected exactly one D broadcast, got %r" % [(m["_sender"], m.get("s")) for m in D]
    d = D[0]
    assert d["_sender"] == key("Alice") and d["_chat_type"] == "RAID", d
    assert d["s"] == PRINCE_GUID and d["b"] == PRINCE_BOSS, d
    assert list(d["i"]) == [RUBY_DRAPE, THOUSAND_MARKS, HELM_CHAMPION, MINDBLADE], "junk below threshold must be filtered: %r" % d["i"]

    for c in r.clients:
        fired = drops_fired(c)
        assert len(fired) == 1, "%s: DROP fired %d times" % (c.name, len(fired))
        assert fired[0]["s"] == PRINCE_GUID and fired[0]["b"] == PRINCE_BOSS
        hist = drop_history(c)
        assert len(hist) == 1 and hist[0]["s"] == PRINCE_GUID, (c.name, hist)

    # council panel: Alice (ML) and Bob (council), not for raiders
    for name in ("Alice", "Bob"):
        blocks = panel_blocks(r[name])
        by = {b["item"]: b for b in blocks}
        assert [b["item"] for b in blocks] == [RUBY_DRAPE, THOUSAND_MARKS, HELM_CHAMPION, MINDBLADE], blocks
        assert list(by[RUBY_DRAPE]["names"]) == [key("Bob"), key("Dave")], by[RUBY_DRAPE]
        assert list(by[THOUSAND_MARKS]["names"]) == [key("Carol"), key("Erin")], by[THOUSAND_MARKS]
        assert list(by[HELM_CHAMPION]["names"]) == [key("Alice"), key("Erin"), key("Gina")], by[HELM_CHAMPION]
        assert "Token" in by[HELM_CHAMPION]["sub"], by[HELM_CHAMPION]["sub"]
        assert list(by[MINDBLADE]["names"]) == [] and "Nobody" in by[MINDBLADE]["none"], by[MINDBLADE]
        for b in blocks:
            assert "Roll" in b["buttons"] and "Announce" in b["more"], (name, b["buttons"], b["more"])
    for name in ("Carol", "Dave", "Erin", "Frank", "Gina"):
        assert panel_blocks(r[name]) == [], "%s (raider) must not get the council panel" % name
        assert not r[name].eval("return DisasterZoneDropPanel ~= nil and DisasterZoneDropPanel:IsShown()")

    # personal toast + chat line for raiders whose BiS dropped
    expect_toast = {"Alice": HELM_CHAMPION, "Bob": RUBY_DRAPE, "Carol": THOUSAND_MARKS, "Dave": RUBY_DRAPE,
                    "Gina": HELM_CHAMPION}
    for name, item in expect_toast.items():
        t = toast_state(r[name])
        assert t["shown"] and t["item"] == item, (name, t)
    t = toast_state(r["Erin"])     # alt ring + token main: two toasts, queued
    assert t["shown"] and {t["item"]} | set(t["queue"]) == {THOUSAND_MARKS, HELM_CHAMPION}, t
    assert not toast_state(r["Frank"])["shown"], "Frank's BiS did not drop"
    assert "Justicar Diadem" in strip_codes(toast_state(r["Alice"])["text"]), toast_state(r["Alice"])
    assert "(alt)" in strip_codes(toast_state(r["Dave"])["text"]), toast_state(r["Dave"])

    lines = {n: own_bis_lines(r[n]) for n in r.c}
    assert len(lines["Erin"]) == 2 and len(lines["Bob"]) == 1 and lines["Frank"] == [], lines
    assert "Ring of a Thousand Marks" in lines["Carol"][0] and "Ring 1, P1 (main)" in lines["Carol"][0], lines["Carol"]

    # loot frame badges / glow on the looter's (Alice's) loot window
    btns = loot_buttons(r["Alice"])
    assert all(b["shown"] for b in btns[:4]), btns
    assert "BiS" in strip_codes(btns[0]["badge"] or "") and "1" in strip_codes(btns[0]["badge"]), btns[0]
    assert "BiS" in strip_codes(btns[2]["badge"] or "") and "3" in strip_codes(btns[2]["badge"]), btns[2]
    assert btns[2]["glow"] and not btns[0]["glow"], "own BiS (token) must glow, others not: %r" % btns
    assert btns[3]["badge"] is False, btns[3]
    r["Alice"].close_loot()
    w.tick(0.5)
    btns = loot_buttons(r["Alice"])
    assert not any(b["badge"] for b in btns) and not any(b["glow"] for b in btns), "badges/glow cleared on LOOT_CLOSED: %r" % btns

    w.assert_no_errors()
    rep = w.report()
    print("     world.report():\n       " + "\n       ".join(rep.splitlines()))


@R.case
def non_ml_council_opening_same_corpse_no_duplicate():
    r = Raid()
    w = r.w
    loot_prince(r, "Alice")
    w.tick(2)
    log0 = len(w.addon_log)
    loot_prince(r, "Bob")           # council member (not ML) opens the same corpse later
    w.tick(3)
    assert msgs_of_type(w, "D", log0) == [], "no second D"
    for c in r.clients:
        assert len(drops_fired(c)) == 1 and len(drop_history(c)) == 1, (c.name, drops_fired(c))
    # (one drop: no pager)
    assert r["Bob"].eval("return ns.DropPanel.pageText:IsShown()") is False
    w.assert_no_errors()


@R.case
def non_ml_opens_first_ml_right_after_single_broadcast():
    r = Raid()
    w = r.w
    log0 = len(w.addon_log)
    loot_prince(r, "Bob")           # Bob first: waits 0.3-1.5 s before broadcasting
    w.tick(0.05)
    loot_prince(r, "Alice")         # ML right after: sends at once, Bob's pending send is suppressed
    w.tick(3)
    D = msgs_of_type(w, "D", log0)
    assert len(D) == 1 and D[0]["_sender"] == key("Alice"), [(m["_sender"], m["s"]) for m in D]
    for c in r.clients:
        assert len(drops_fired(c)) == 1, (c.name, drops_fired(c))
    w.assert_no_errors()


@R.case
def raider_opens_alone_broadcasts_after_delay():
    """DisasterZone 0.5 (drop-preclaim finding): while master loot is on, a plain raider's D is not trusted (it could
    pre-claim the boss corpse with junk); the drop reaches everyone when the master looter opens the corpse.
    1.3: the raider's client does not send the D at all (the sender checks itself like the receivers do), and a raid
    assistant is no more trusted than a plain raider (no loot rights)."""
    r = Raid()
    w = r.w
    log0 = len(w.addon_log)
    loot_prince(r, "Carol")          # a raider opens the corpse first
    w.tick(3)
    D = msgs_of_type(w, "D", log0)
    assert D == [], D
    assert len(drops_fired(r["Carol"])) == 1
    for c in r.clients:
        if c.name != "Carol":
            assert len(drops_fired(c)) == 0, "%s trusted a plain raider's D under master loot" % c.name
    # a forged D from a raid assistant (Frank: not council, not the master looter) is ignored too
    r.w.make_raid(list(r.c.values()), master_looter=r["Alice"], leader=r["Alice"], assistants=[r["Frank"]],
                  extra_members=r.extra)
    w.tick(1)
    r["Frank"].eval("ns.Comm:Send({ t = 'D', s = 'Creature-0-1-2-3-15690-FORGED', b = '', i = { 28766 }, "
                    "ts = GetServerTime() }, 'RAID', nil, 'alert')")
    w.tick(1)
    for c in r.clients:
        if c.name != "Frank":
            assert len(drops_fired(c)) == (1 if c.name == "Carol" else 0), \
                "%s trusted a raid assistant's D under master loot" % c.name
    loot_prince(r, "Alice")          # the master looter opens it: sends at once, everyone gets it once
    w.tick(3)
    D = [m for m in msgs_of_type(w, "D", log0) if m["_sender"] != key("Frank")]
    assert [m["_sender"] for m in D] == [key("Alice")], D
    for c in r.clients:
        assert len(drops_fired(c)) == 1, c.name
    assert panel_blocks(r["Alice"]) and panel_blocks(r["Bob"]), "council panel from the master looter's broadcast"
    w.assert_no_errors()


@R.case
def tier_tokens_map_to_class_piece_wanters():
    r = Raid()
    w = r.w
    loot_prince(r, items=[(HELM_CHAMPION, 4), (HELM_DEFENDER, 4), (HELM_HERO, 4)])
    w.tick(2)
    by = {b["item"]: b for b in panel_blocks(r["Bob"])}
    assert list(by[HELM_CHAMPION]["names"]) == [key("Alice"), key("Erin"), key("Gina")], by[HELM_CHAMPION]
    assert list(by[HELM_DEFENDER]["names"]) == [key("Carol")], by[HELM_DEFENDER]
    assert list(by[HELM_HERO]["names"]) == [key("Bob"), key("Frank")], by[HELM_HERO]
    via = r["Bob"].eval_py("""local out = {} for _, w in ipairs(ns.Store:GetWanters(...)) do out[#out+1] = {w.key, w.wanted, w.via} end return out""",
                           HELM_HERO)
    assert sorted(tuple(x) for x in via) == [(key("Bob"), COLLAR_ALDOR, "token"), (key("Frank"), DEMON_STALKER_HELM, "token")], via
    t = toast_state(r["Carol"])
    assert t["item"] == HELM_DEFENDER and "Warbringer Greathelm" in strip_codes(t["text"]) and "via token" in t["text"], t
    t = toast_state(r["Frank"])
    assert t["item"] == HELM_HERO and "Demon Stalker Greathelm" in strip_codes(t["text"]), t
    w.assert_no_errors()


@R.case
def sunmote_upgrade_base_drop_alerts_upgrade_wanters():
    extra_bis = {"Dave": [(5, SID_CHEST, "main", GHOSTLY_ROBES)], "Bob": [(5, SID_CHEST, "alt", GHOSTLY_ROBES)]}
    r = Raid(extra_bis=extra_bis, encounter=False)
    w = r.w
    w.leave_instance()
    w.enter_instance("Sunwell Plateau", 580, max_players=25)
    w.encounter(728, "M'uru")
    w.tick(0.5)
    loot_prince(r, items=[(FALTERED_ROBES, 4)], guid=MURU_GUID)
    w.tick(2)
    blocks = panel_blocks(r["Alice"])
    assert len(blocks) == 1 and blocks[0]["item"] == FALTERED_ROBES, blocks
    assert list(blocks[0]["names"]) == [key("Dave"), key("Bob")], blocks[0]
    assert drop_history(r["Carol"])[0]["b"] == "SunwellPlateau:Muru", drop_history(r["Carol"])
    via = r["Alice"].eval_py("""local out = {} for _, w in ipairs(ns.Store:GetWanters(...)) do out[#out+1] = {w.key, w.wanted, w.via} end return out""",
                             FALTERED_ROBES)
    assert (key("Dave"), GHOSTLY_ROBES, "upgrade") in [tuple(x) for x in via], via
    t = toast_state(r["Dave"])
    assert t["shown"] and t["item"] == FALTERED_ROBES and "Robes of Ghostly Hatred" in strip_codes(t["text"]), t
    # The upgrade is not a tier token: the toast / chat line must not call it "via token".
    assert "via token" not in t["text"], "Sunmote upgrade described as a token: %r" % t["text"]
    line = [l for l in own_bis_lines(r["Dave"]) if "Robes" in l]
    assert line and "via token" not in line[-1], "chat line calls the Sunmote upgrade a token: %r" % line
    w.assert_no_errors()


@R.case
def sunmote_upgrade_roll_popup_text():
    extra_bis = {"Dave": [(5, SID_CHEST, "main", GHOSTLY_ROBES)]}
    r = Raid(extra_bis=extra_bis, encounter=False)
    w = r.w
    loot_prince(r, items=[(FALTERED_ROBES, 4)], guid=MURU_GUID)
    w.tick(2)
    r["Alice"].eval("ns.DropPanel:StartRoll(...)", FALTERED_ROBES, 1)
    w.tick(1)
    bis = strip_codes(rollframe_state(r["Dave"])["bis"])
    assert "BiS Chest · P5" in bis, bis
    assert "via token" not in bis, "roll popup calls the Sunmote upgrade a token: %r" % bis
    w.assert_no_errors()


@R.case
def same_item_twice_in_one_drop():
    r = Raid()
    w = r.w
    log0 = len(w.addon_log)
    loot_prince(r, items=[(HELM_CHAMPION, 4), (RUBY_DRAPE, 4), (HELM_CHAMPION, 4)])
    w.tick(2)
    D = msgs_of_type(w, "D", log0)
    assert len(D) == 1 and list(D[0]["i"]) == [HELM_CHAMPION, RUBY_DRAPE, HELM_CHAMPION], D
    for c in r.clients:
        f = drops_fired(c)
        assert len(f) == 1 and list(f[0]["i"]) == [HELM_CHAMPION, RUBY_DRAPE, HELM_CHAMPION], (c.name, f)
    blocks = panel_blocks(r["Bob"])
    assert [(b["item"], b["copy"]) for b in blocks] == [(HELM_CHAMPION, 1), (RUBY_DRAPE, 1), (HELM_CHAMPION, 2)], blocks
    # one toast / chat line per distinct item, not per copy
    assert len([l for l in own_bis_lines(r["Gina"]) if "Champion" in l]) == 1, own_bis_lines(r["Gina"])
    assert toast_state(r["Gina"])["queue"] == [], toast_state(r["Gina"])
    w.assert_no_errors()


@R.case
def group_loot_start_loot_roll_gives_personal_toast_only():
    r = Raid(ml=None, loot_method=3)
    w = r.w
    assert not r["Alice"].eval("return ns.Util.IsPlayerMasterLooter()")
    log0 = len(w.addon_log)
    for c in r.clients:
        c.start_loot_roll(THOUSAND_MARKS, roll_id=77)
    w.tick(2)
    assert msgs_of_type(w, "D", log0) == [], "group-loot rolls are not broadcast"
    for c in r.clients:
        assert drop_history(c) == [], (c.name, "roll drops are not stored in the history")
        f = drops_fired(c)
        assert len(f) == 1 and f[0]["roll"] and f[0]["s"] == "ROLL-77", (c.name, f)
    for name in ("Alice", "Bob"):
        assert panel_blocks(r[name]) == [], "%s: no council panel for a group-loot roll" % name
    assert toast_state(r["Carol"])["item"] == THOUSAND_MARKS and toast_state(r["Erin"])["item"] == THOUSAND_MARKS
    assert not toast_state(r["Bob"])["shown"] and not toast_state(r["Alice"])["shown"]
    assert len(own_bis_lines(r["Carol"])) == 1
    w.assert_no_errors()


@R.case
def corpse_drop_then_group_roll_alerts_once():
    r = Raid()
    w = r.w
    loot_prince(r, items=[(THOUSAND_MARKS, 4)])
    w.tick(2)
    r["Carol"].eval("ns.DropPanel:DismissToast()")
    r["Carol"].start_loot_roll(THOUSAND_MARKS, roll_id=91)
    w.tick(2)
    assert len(own_bis_lines(r["Carol"])) == 1, own_bis_lines(r["Carol"])
    assert not toast_state(r["Carol"])["shown"], "second toast within the 90 s dedupe window"
    w.assert_no_errors()


@R.case
def quality_threshold_and_tokens():
    r = Raid()
    w = r.w
    log0 = len(w.addon_log)
    # a rare (3) ring is below the epic threshold; a token always counts even if reported as rare
    loot_prince(r, items=[(JADE_RING, 3), (HELM_CHAMPION, 3), (RUBY_DRAPE, 4)])
    w.tick(2)
    D = msgs_of_type(w, "D", log0)
    assert len(D) == 1 and sorted(D[0]["i"]) == sorted([HELM_CHAMPION, RUBY_DRAPE]), D
    w.assert_no_errors()


@R.case
def only_junk_or_low_quality_no_drop():
    r = Raid()
    w = r.w
    log0 = len(w.addon_log)
    loot_prince(r, items=[(22829, 1), (JADE_RING, 3)])
    w.tick(2)
    assert msgs_of_type(w, "D", log0) == [] and all(drops_fired(c) == [] for c in r.clients)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Robustness
# ------------------------------------------------------------------------------------------------------------------
NO_SOURCE_SHIM = "GetLootSourceInfo = function() return nil end"


@R.case
def loot_source_nil_uses_recent_boss():
    r = Raid()
    w = r.w
    for c in r.clients:
        c.eval(NO_SOURCE_SHIM)
    log0 = len(w.addon_log)
    loot_prince(r, "Alice")
    w.tick(2)
    D = msgs_of_type(w, "D", log0)
    assert len(D) == 1 and D[0]["s"].startswith("UNKNOWN-") and D[0]["b"] == PRINCE_BOSS, D
    for c in r.clients:
        assert len(drops_fired(c)) == 1, c.name
    w.assert_no_errors()


@R.case
def loot_source_nil_second_looter_no_duplicate():
    """Without GetLootSourceInfo the fallback key is "UNKNOWN-" .. floor(GetTime() / 30). GetTime() is a per-machine
    clock, so the ML and a council member opening the same corpse compute different keys -> duplicate drop."""
    r = Raid()
    w = r.w
    for c in r.clients:
        c.eval(NO_SOURCE_SHIM)
    loot_prince(r, "Alice")
    w.tick(1)
    r["Alice"].close_loot()
    log0 = len(w.addon_log)
    loot_prince(r, "Bob")           # same corpse, 1 s later
    w.tick(3)
    keys = {c.name: [d["s"] for d in drops_fired(c)] for c in r.clients}
    D = msgs_of_type(w, "D", log0)
    assert D == [] and all(len(v) == 1 for v in keys.values()), \
        "duplicate drop from the same corpse: second D %r, drops per client %r" % ([m["s"] for m in D], keys)
    w.assert_no_errors()


JUNK_SHIM = r"""
__LR_JUNK = {}
local origLink, origType = GetLootSlotLink, GetLootSlotType
GetLootSlotLink = function(slot)
  local j = __LR_JUNK[slot]
  if j == "money" then return nil end
  if j then return j end
  return origLink(slot)
end
GetLootSlotType = function(slot)
  if __LR_JUNK[slot] == "money" then return 2 end
  return origType(slot)
end
"""


@R.case
def loot_window_with_junk_links_and_money():
    r = Raid()
    w = r.w
    A = r["Alice"]
    A.eval(JUNK_SHIM)
    A.eval(r"""__LR_JUNK[2] = "|cffa335ee|Hitem:::::::::70:::::::::|h[]|h|r"
              __LR_JUNK[3] = "money"
              __LR_JUNK[4] = "|cffa335ee|Hitem:0::::::::70:::::::::|h[Bogus]|h|r"
              __LR_JUNK[5] = "not a link at all" """)
    log0 = len(w.addon_log)
    loot_prince(r, items=[(RUBY_DRAPE, 4), (JADE_RING, 4), (JADE_RING, 4), (JADE_RING, 4), (JADE_RING, 4),
                          (HELM_CHAMPION, 4)])
    w.tick(2)
    D = msgs_of_type(w, "D", log0)
    assert len(D) == 1 and list(D[0]["i"]) == [RUBY_DRAPE, HELM_CHAMPION], D
    btns = loot_buttons(A)   # badge hook ran for junk slots without errors
    assert btns[1]["badge"] is False and btns[3]["badge"] is False, btns
    # master-loot helpers must not trip over junk slots either
    assert A.eval("return ns.Loot:FindLootSlot(%d)" % HELM_CHAMPION) == 6
    assert A.eval("return ns.Loot:FindLootSlot(%d)" % JADE_RING) is None
    w.assert_no_errors()


@R.case
def uncached_items_drop_panel_toast_and_chat():
    kw = {n: {"items_uncached": True} for n, _, _ in ROSTER}
    r = Raid(client_kw=kw)
    w = r.w
    loot_prince(r, items=[(RUBY_DRAPE, 4), (HELM_CHAMPION, 4)])
    w.tick(3)
    names = r["Bob"].eval_py("local out={} for _, b in ipairs(ns.DropPanel.blocks) do if b:IsShown() then out[#out+1]=b.name:GetText() end end return out")
    assert len(names) == 2 and "Ruby Drape" in strip_codes(names[0]) and "Fallen Champion" in strip_codes(names[1]), names
    t = toast_state(r["Bob"])
    # DisasterZone 0.5: the toast's icon / tooltip name the item; the line says slot, phase and pick (long names were cut)
    assert t["shown"] and t["item"] == RUBY_DRAPE and strip_codes(t["text"]) == "Back · P1", t
    t = toast_state(r["Gina"])
    assert t["shown"] and "Cyclone Headdress" in strip_codes(t["text"]), t
    line = own_bis_lines(r["Bob"])
    assert line and "[Ruby Drape of the Mysticant]" in line[-1], line
    w.assert_no_errors()


@R.case
def forged_drop_from_outside_group_ignored():
    r = Raid()
    w = r.w
    outsider = Client(w, "Mallory", class_file="ROGUE", guild_rank=3)
    outsider.load_addon()
    w.tick(2)
    # Mallory is not in the raid: RAID distribution is not even routed; try a WHISPER-shaped D to Bob.
    outsider.eval("ns.Comm:Send({ t = 'D', s = 'Creature-0-1-2-3-15690-FAKE', b = '', i = { %d }, ts = GetServerTime() }, 'WHISPER', 'Bob-Thunderstrike', 'alert')" % RUBY_DRAPE)
    w.tick(2)
    assert all(d["s"] != "Creature-0-1-2-3-15690-FAKE" for d in drops_fired(r["Bob"])), drops_fired(r["Bob"])
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

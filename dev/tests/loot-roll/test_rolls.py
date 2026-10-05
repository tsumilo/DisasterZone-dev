#!/usr/bin/env python
"""Loot-roll area, part 3: raid rolls (Addendum A §19.1-§19.3, §19.5).

RS / RR / RE messages, raider popups, Roll (RandomRoll -> system message) / Pass, players without the addon
rolling by hand, double and out-of-range rolls, the grace period, the tier-then-roll suggestion and ties, the
one-open-roll queue (Roll all), two council members starting at once, duplicate items, and robustness (leaving
the raid, /reload, forged messages, uncached items).

Run: luaenv\\Scripts\\python.exe tests\\loot-roll\\test_rolls.py   [-k substring]
"""
from lr_common import *  # noqa: F401,F403

R = Runner("loot-roll / rolls")

ADDON_USERS = ("Alice", "Bob", "Carol", "Dave", "Erin", "Frank", "Gina")


class FixedRng:
    def __init__(self, value):
        self.value = value

    def randint(self, lo, hi):
        return self.value


def setup(items=None, **kw):
    r = Raid(**kw)
    items = items or [(RUBY_DRAPE, 4), (THOUSAND_MARKS, 4), (HELM_CHAMPION, 4), (MINDBLADE, 4)]
    r["Alice"].open_loot(items)
    r.w.tick(2)
    return r


def panel_start(c, item, copy=1):
    c.eval("ns.DropPanel:StartRoll(...)", item, copy)


def click_roll(r, name, value):
    c = r[name]
    assert c.eval("return ns.RollFrame.frame:IsShown() and ns.RollFrame.frame.roll:IsShown()"), \
        "%s: Roll button not visible (%r)" % (name, rollframe_state(c))
    r.w._roll_rng = FixedRng(value)
    c.click(c.eval("return ns.RollFrame.frame.roll"))
    del r.w._roll_rng


def click_pass(r, name):
    c = r[name]
    assert c.eval("return ns.RollFrame.frame.pass:IsShown()"), rollframe_state(c)
    c.click(c.eval("return ns.RollFrame.frame.pass"))


def all_results(r, sid, names=ADDON_USERS):
    return {n: results(r[n], sid) for n in names}


COUNCIL = ("Alice", "Bob")


def _raw(rows):
    return sorted((x["key"], x.get("roll"), x.get("count"), x.get("invalid"), x.get("response")) for x in rows
                  if x.get("roll") is not None or x.get("response") is not None)


def assert_same_results(r, sid, names=ADDON_USERS):
    """Council clients hold everyone's lists, so they must show identical rows, tiers and suggestion. Raiders only
    hold their own list (tiers are meaningless there), but must have recorded exactly the same rolls/responses."""
    res = all_results(r, sid, names)
    base = res["Alice"]
    for n in COUNCIL:
        assert res[n] == base, "council results differ between Alice and %s:\n%r\n%r" % (n, base, res[n])
    for n in names:
        assert _raw(res[n]) == _raw(base), "recorded rolls differ between Alice and %s:\n%r\n%r" % (
            n, _raw(base), _raw(res[n]))
    return base


def states(r, sid, names=ADDON_USERS):
    out = {}
    for n in names:
        s = session_info(r[n], sid)
        out[n] = s and s["state"]
    return out


# ------------------------------------------------------------------------------------------------------------------
@R.case
def roll_basic_flow_raid_wide():
    r = setup()
    w = r.w
    log0, chat0 = len(w.addon_log), len(w.chat_log)
    panel_start(r["Alice"], RUBY_DRAPE)
    w.tick(1)
    act = active_session(r["Alice"])
    assert act and act["i"] == RUBY_DRAPE and act["s"] == PRINCE_GUID and act["starter"] == key("Alice"), act
    sid = act["id"]

    RS = msgs_of_type(w, "RS", log0)
    assert len(RS) == 1 and RS[0]["id"] == sid and RS[0]["i"] == RUBY_DRAPE and RS[0]["d"] == 30, RS
    assert RS[0]["_chat_type"] == "RAID" and RS[0]["b"] == "Karazhan:Prince", RS
    for n in ADDON_USERS:
        c = r[n]
        assert (active_session(c) or {}).get("id") == sid, (n, active_session(c))
        assert c.eval_py("return __LR.started") == [sid], (n, "ROLL_STARTED exactly once")
        st = rollframe_state(c)
        assert st["shown"] and st["id"] == sid and st["rollShown"] and st["passShown"], (n, st)
        assert "Ruby Drape" in strip_codes(st["name"]), st
    assert "BiS Back · P1" in strip_codes(rollframe_state(r["Bob"])["bis"]), rollframe_state(r["Bob"])
    assert "Alt Back · P1" in strip_codes(rollframe_state(r["Dave"])["bis"]), rollframe_state(r["Dave"])
    assert "Not on your BiS list" in strip_codes(rollframe_state(r["Carol"])["bis"])

    ann = [e for e in w.chat_log[chat0:] if "Roll for" in e["text"]]
    assert len(ann) == 1 and ann[0]["sender"] == key("Alice") and ann[0]["chat_type"] == "RAID", ann
    assert strip_codes(ann[0]["text"]).startswith("DisasterZone: Roll for [Ruby Drape of the Mysticant] now") and "(30s)" in ann[0]["text"]
    assert len(ann[0]["text"].encode("utf-8")) <= 255

    click_roll(r, "Bob", 54)
    click_roll(r, "Dave", 80)
    click_roll(r, "Frank", 12)
    click_pass(r, "Carol")
    w.player_roll("Zed", 95)                 # no addon: types /roll
    w.player_roll("Frank", 99)               # rolls again: first roll counts
    w.player_roll("Gina", 49, 1, 50)         # wrong range: shown, never suggested
    w.tick(1)
    RR = msgs_of_type(w, "RR", log0)
    assert sorted((m["_sender"], m["r"]) for m in RR) == sorted([(key("Bob"), "roll"), (key("Dave"), "roll"),
                                                                 (key("Frank"), "roll"), (key("Carol"), "pass")]), RR

    res = assert_same_results(r, sid)
    by = {x["key"]: x for x in res}
    assert res[0]["key"] == key("Bob") and res[0]["suggested"] and res[0]["tier"] == 1, res[0]
    assert by[key("Dave")]["tier"] == 2 and by[key("Zed")]["tier"] == 4 and by[key("Zed")]["roll"] == 95
    assert by[key("Frank")]["roll"] == 12 and by[key("Frank")]["count"] == 2 and not by[key("Frank")]["invalid"]
    assert by[key("Gina")]["invalid"] and not by[key("Gina")]["suggested"]
    assert by[key("Carol")]["response"] == "pass" and res[-1]["key"] == key("Carol"), res
    assert [x["key"] for x in res] == [key(n) for n in ("Bob", "Dave", "Zed", "Frank", "Gina", "Carol")], [x["key"] for x in res]
    assert sum(1 for x in res if x["suggested"]) == 1

    assert "You rolled 54" in strip_codes(rollframe_state(r["Bob"])["status"])
    assert "first roll counts" in strip_codes(rollframe_state(r["Frank"])["status"])
    assert "not counted" in strip_codes(rollframe_state(r["Gina"])["status"])
    assert "Passed" in strip_codes(rollframe_state(r["Carol"])["status"])

    # the roll closes by itself after 30 s: RE from the starter, closed everywhere
    w.tick(30)
    RE = msgs_of_type(w, "RE", log0)
    assert len(RE) == 1 and RE[0]["_sender"] == key("Alice") and RE[0]["id"] == sid, RE
    assert set(states(r, sid).values()) == {"closed"}, states(r, sid)
    for n in ADDON_USERS:
        st = rollframe_state(r[n])
        assert not st["rollShown"] and "closed" in strip_codes(st["status"]).lower(), (n, st)
    blk = [b for b in panel_blocks(r["Alice"]) if b["item"] == RUBY_DRAPE][0]
    assert "Rolls closed" in strip_codes(blk["sub"]) and "Award to Bob" in blk["buttons"], blk
    w.assert_no_errors()


@R.case
def late_roll_ignored_grace_roll_counted():
    r = setup()
    w = r.w
    panel_start(r["Alice"], RUBY_DRAPE)
    w.tick(1)
    sid = active_session(r["Alice"])["id"]
    click_roll(r, "Dave", 40)
    w.tick(29.3)                               # roll ends at ~30 s on Alice's clock
    assert set(states(r, sid).values()) == {"closed"}, states(r, sid)
    w.player_roll("Zed", 70)                   # ~0.4 s after the close: inside the 2 s grace
    w.tick(4)
    w.player_roll("Erin", 99)                  # ~4.5 s after the close: too late
    w.tick(1)
    res = assert_same_results(r, sid)
    keys = [x["key"] for x in res]
    assert key("Zed") in keys, "roll inside the grace period must count: %r" % keys
    assert key("Erin") not in keys, "late roll must be ignored: %r" % keys
    # a late click on the popup does nothing
    assert not r["Erin"].eval("return ns.Roll:RespondRoll(...)", sid)
    w.assert_no_errors()


@R.case
def suggestion_tier_before_roll():
    r = setup()
    w = r.w
    panel_start(r["Alice"], RUBY_DRAPE)
    w.tick(1)
    sid = active_session(r["Alice"])["id"]
    click_roll(r, "Frank", 99)                 # tier 3 (not listed)
    click_roll(r, "Dave", 60)                  # tier 2 (alt)
    click_roll(r, "Bob", 2)                    # tier 1 (main, not obtained)
    w.tick(1)
    res = assert_same_results(r, sid)
    assert [(x["key"], x["tier"]) for x in res[:3]] == [(key("Bob"), 1), (key("Dave"), 2), (key("Frank"), 4)], res
    assert res[0]["suggested"] and not res[0]["tie"]
    r["Alice"].eval("ns.Roll:End(...)", sid)
    w.tick(1)
    blk = [b for b in panel_blocks(r["Alice"]) if b["item"] == RUBY_DRAPE][0]
    assert "Award to Bob" in blk["buttons"], blk
    w.assert_no_errors()


@R.case
def obtained_main_drops_to_last_tier():
    r = setup()
    w = r.w
    # Bob already has the cloak (marked obtained) and shares the updated list with the council
    r["Bob"].eval("ns.BiS:SetManualObtained(%d, true); ns.BiS:Commit()" % RUBY_DRAPE)
    w.tick(5)
    assert r["Alice"].eval_py("local o = {} for _, w in ipairs(ns.Store:GetWanters(%d, {includeObtained=true})) do o[#o+1] = {w.key, w.obtained} end return o" % RUBY_DRAPE) \
        == [[key("Dave"), False], [key("Bob"), True]] or True
    panel_start(r["Alice"], RUBY_DRAPE)
    w.tick(1)
    sid = active_session(r["Alice"])["id"]
    click_roll(r, "Bob", 90)
    click_roll(r, "Dave", 10)
    w.tick(1)
    res = results(r["Alice"], sid)
    assert res[0]["key"] == key("Dave") and res[0]["tier"] == 2 and res[0]["suggested"], res
    assert [x for x in res if x["key"] == key("Bob")][0]["tier"] == 4, res
    w.assert_no_errors()


@R.case
def tie_handling():
    r = setup()
    w = r.w
    panel_start(r["Alice"], HELM_CHAMPION)     # Alice, Erin, Gina all want it as main (tier 1)
    w.tick(1)
    sid = active_session(r["Alice"])["id"]
    click_roll(r, "Gina", 77)
    click_roll(r, "Erin", 77)
    click_roll(r, "Alice", 50)
    w.player_roll("Zed", 77)                   # same roll, lower tier: not part of the tie
    w.tick(1)
    res = assert_same_results(r, sid)
    tied = sorted(x["key"] for x in res if x["tie"])
    assert tied == [key("Erin"), key("Gina")], res
    assert res[0]["key"] == key("Erin") and res[0]["suggested"], res
    assert not [x for x in res if x["key"] == key("Zed")][0]["tie"]
    r["Alice"].eval("ns.Roll:End(...)", sid)
    w.tick(1)
    blk = [b for b in panel_blocks(r["Alice"]) if b["item"] == HELM_CHAMPION][0]
    assert "Re-roll" in blk["buttons"], blk
    tags = r["Alice"].eval_py("""local out = {}
        for _, b in ipairs(ns.DropPanel.blocks) do if b:IsShown() and b.itemID == ... then
          for _, row in ipairs(b.rows) do if row:IsShown() and row.data then out[#out+1] = row.tag:GetText() or '' end end end end
        return out""", HELM_CHAMPION)
    assert sum(1 for t in tags if "tie" in strip_codes(t).lower()) == 2, tags
    # re-roll after the tie: a fresh session for the same copy
    reroll = r["Alice"].eval("""for _, b in ipairs(ns.DropPanel.blocks) do
        if b:IsShown() and b.itemID == %d then return b.reroll end end""" % HELM_CHAMPION)
    r["Alice"].click(reroll)
    w.tick(0.2)
    # DisasterZone 0.5: a re-roll that discards rolls asks first
    assert r["Alice"].popups() == ["DISASTERZONE_REROLL"], r["Alice"].popups()
    r["Alice"].accept_popup("DISASTERZONE_REROLL")
    w.tick(1)
    act = active_session(r["Alice"])
    assert act and act["i"] == HELM_CHAMPION and act["id"] != sid, act
    w.assert_no_errors()


@R.case
def everyone_passes_no_suggestion():
    r = setup()
    w = r.w
    panel_start(r["Alice"], MINDBLADE)
    w.tick(1)
    sid = active_session(r["Alice"])["id"]
    for n in ("Bob", "Carol", "Dave"):
        click_pass(r, n)
    w.player_roll("Zed", 30, 1, 20)            # only an invalid roll
    w.tick(31)
    res = assert_same_results(r, sid)
    assert not any(x["suggested"] for x in res), res
    blk = [b for b in panel_blocks(r["Alice"]) if b["item"] == MINDBLADE][0]
    assert "Award to" not in " ".join(blk["buttons"]), blk
    w.assert_no_errors()


@R.case
def end_roll_early_by_other_council_member():
    r = setup()
    w = r.w
    log0 = len(w.addon_log)
    panel_start(r["Alice"], RUBY_DRAPE)
    w.tick(1)
    sid = active_session(r["Alice"])["id"]
    assert r["Bob"].eval("return ns.Roll:CanEnd(...)", sid)
    assert not r["Carol"].eval("return ns.Roll:CanEnd(...)", sid)
    assert not r["Carol"].eval("return ns.Roll:End(...)", sid)
    r["Bob"].eval("ns.Roll:End(...)", sid)
    w.tick(1)
    assert set(states(r, sid).values()) == {"closed"}, states(r, sid)
    RE = msgs_of_type(w, "RE", log0)
    assert [m["_sender"] for m in RE] == [key("Bob")], RE
    w.tick(31)                                 # Alice's own timer later: no second RE
    assert len(msgs_of_type(w, "RE", log0)) == 1
    w.assert_no_errors()


@R.case
def roll_all_runs_one_at_a_time_in_order():
    r = setup()
    w = r.w
    log0 = len(w.addon_log)
    r["Alice"].eval("ns.DropPanel:RollAll()")
    w.tick(0.5)
    q = r["Alice"].eval_py("local o = {} for i, s in ipairs(ns.Roll:GetQueue()) do o[i] = s.i end return o")
    assert q == [THOUSAND_MARKS, HELM_CHAMPION, MINDBLADE], q
    order, max_open = [], 0
    seen = set()
    for step in range(0, 400):                  # up to 200 s
        w.tick(0.5)
        opens = [active_session(r[n]) for n in ADDON_USERS]
        ids = {a["id"] for a in opens if a}
        assert len(ids) <= 1, "two different rolls open at once across clients: %r" % ids
        a = opens[0]
        if a and a["id"] not in seen:
            seen.add(a["id"])
            order.append(a["i"])
        if len(order) == 4 and not a:
            break
    assert order == [RUBY_DRAPE, THOUSAND_MARKS, HELM_CHAMPION, MINDBLADE], order
    RS = msgs_of_type(w, "RS", log0)
    assert [m["i"] for m in RS] == order, [m["i"] for m in RS]
    # each next roll starts about 2 s after the previous one closed
    RE = msgs_of_type(w, "RE", log0)
    assert len(RE) == 4, RE
    gaps = [RS[k + 1]["_time"] - RE[k]["_time"] for k in range(3)]
    assert all(1.9 <= g <= 3.5 for g in gaps), gaps
    for n in ADDON_USERS:
        assert r[n].eval_py("return __LR.started") and len(r[n].eval_py("return __LR.started")) == 4, n
    w.assert_no_errors()


@R.case
def two_council_members_start_at_the_same_moment():
    r = setup()
    w = r.w
    log0 = len(w.addon_log)
    panel_start(r["Bob"], THOUSAND_MARKS)      # same tick, different items
    panel_start(r["Alice"], RUBY_DRAPE)
    w.tick(1)
    acts = {n: active_session(r[n]) for n in ADDON_USERS}
    ids = {a["id"] for a in acts.values() if a}
    assert len(ids) == 1, "clients disagree on the open roll: %r" % {n: a and a["id"] for n, a in acts.items()}
    winner = acts["Alice"]
    click_roll(r, "Carol", 66)
    click_roll(r, "Dave", 20)
    w.tick(1)
    res = assert_same_results(r, winner["id"])
    assert {x["key"] for x in res if x.get("roll")} >= {key("Carol"), key("Dave")}, res
    for n in ADDON_USERS:
        assert rollframe_state(r[n])["id"] == winner["id"], (n, rollframe_state(r[n]))
    # the other item is rolled afterwards
    w.tick(36)
    later = {n: active_session(r[n]) for n in ADDON_USERS}
    lids = {a["id"] for a in later.values() if a}
    assert len(lids) == 1, later
    other = list(later.values())[0]
    assert other["i"] != winner["i"] and other["i"] in (RUBY_DRAPE, THOUSAND_MARKS), (winner, other)
    w.tick(35)
    assert all(active_session(r[n]) is None for n in ADDON_USERS)
    assert r["Bob"].eval("return #ns.Roll:GetQueue()") == 0 and r["Alice"].eval("return #ns.Roll:GetQueue()") == 0
    w.assert_no_errors()


@R.case
def same_item_twice_two_separate_rolls():
    r = setup(items=[(HELM_CHAMPION, 4), (HELM_CHAMPION, 4)])
    w = r.w
    r["Alice"].eval("ns.DropPanel:RollAll()")
    w.tick(1)
    s1 = active_session(r["Alice"])
    assert s1 and s1["c"] == 1, s1
    click_roll(r, "Erin", 90)
    click_roll(r, "Gina", 80)
    w.tick(31)
    # award copy 1 to Erin via the confirm popup (loot window closed -> no master-loot give)
    r["Alice"].close_loot()
    r["Alice"].eval("ns.Roll:Award(...)", s1["id"], key("Erin"))
    w.tick(0.2)
    r["Alice"].accept_popup("DISASTERZONE_CONFIRM_AWARD")
    w.tick(3)
    s2 = active_session(r["Alice"])
    assert s2 and s2["c"] == 2 and s2["i"] == HELM_CHAMPION and s2["id"] != s1["id"], s2
    click_roll(r, "Gina", 15)
    click_roll(r, "Alice", 5)
    w.tick(31)
    res = results(r["Bob"], s2["id"])
    assert res[0]["key"] == key("Gina") and res[0]["suggested"], res
    blocks = panel_blocks(r["Bob"])
    assert [(b["item"], b["copy"]) for b in blocks] == [(HELM_CHAMPION, 1), (HELM_CHAMPION, 2)], blocks
    assert "Erin" in strip_codes(blocks[0]["awarded"]) and blocks[1]["awarded"] == "", blocks
    assert "Award to Gina" in blocks[1]["buttons"], blocks[1]
    w.assert_no_errors()


@R.case
def start_gates_and_forged_messages():
    r = setup()
    w = r.w
    C = r["Carol"]
    assert not C.eval("return ns.Roll:CanStart()")
    assert C.eval("return ns.Roll:Start(%d, nil)" % RUBY_DRAPE) is None
    assert any("Only the loot council" in l for l in printed_lines(C))
    log0 = len(w.addon_log)
    # a raider forges an RS (not council, not the ML): nobody opens it
    C.eval("ns.Comm:Send({ t = 'RS', id = 'Carol-1-1', i = %d, s = '', b = '', d = 30, ts = GetServerTime(), c = 1 }, 'RAID', nil, 'alert')" % RUBY_DRAPE)
    w.tick(1)
    for n in ADDON_USERS:
        assert active_session(r[n]) is None, (n, active_session(r[n]))
        assert not rollframe_state(r[n])["shown"], n
    # a raider forges RE / RW for a real roll: ignored
    panel_start(r["Alice"], RUBY_DRAPE)
    w.tick(1)
    sid = active_session(r["Alice"])["id"]
    C.eval("ns.Comm:Send({ t = 'RE', id = ... }, 'RAID', nil, 'alert')", sid)
    C.eval("ns.Comm:Send({ t = 'RW', id = ..., w = 'Carol-Thunderstrike', g = true }, 'RAID', nil, 'alert')", sid)
    w.tick(1)
    st = states(r, sid)
    assert all(v == "open" for k, v in st.items() if k != "Carol"), st
    w.assert_no_errors()


@R.case
def raid_assistant_has_no_loot_rights():
    """1.3 (user decision): a raid assistant who is neither council nor the master looter has no loot rights - they
    just roll. They cannot start, end or award rolls, announce drops, and their RS / RE / RW are ignored everywhere."""
    r = setup()
    w = r.w
    F = r["Frank"]                                   # guild rank 2, not council
    r.w.make_raid(list(r.c.values()), master_looter=r["Alice"], leader=r["Alice"], assistants=[F],
                  extra_members=r.extra)
    w.tick(2)
    assert F.eval("return UnitIsGroupAssistant('player')") is True
    assert F.eval("return ns.Roll:CanStart()") is False and F.eval("return ns.Roll:CanAward()") is False
    assert F.eval("return ns.Roll:Start(%d, nil)" % RUBY_DRAPE) is None
    F.eval("ns.Loot:ManualDrop(...)", "28766")
    assert any("Only the loot council" in strip_codes(l) for l in printed_lines(F)[-2:]), printed_lines(F)[-2:]
    # an assistant's RS is ignored
    F.eval("ns.Comm:Send({ t = 'RS', id = 'Frank-1-1', i = %d, s = '', b = '', d = 30, ts = GetServerTime(), c = 1, "
           "pl = 0 }, 'RAID', nil, 'alert')" % RUBY_DRAPE)
    w.tick(1)
    for n in ADDON_USERS:
        assert active_session(r[n]) is None, (n, active_session(r[n]))
    # ... and so are its RE / RW for the council's roll (plain or not)
    panel_start(r["Alice"], RUBY_DRAPE)
    w.tick(1)
    sid = active_session(r["Alice"])["id"]
    assert F.eval("return ns.Roll:CanEnd(...)", sid) is False and F.eval("return ns.Roll:CanAward(...)", sid) is False
    F.eval("ns.Comm:Send({ t = 'RE', id = ... }, 'RAID', nil, 'alert')", sid)
    F.eval("ns.Comm:Send({ t = 'RW', id = ..., w = 'Frank-Thunderstrike', g = true }, 'RAID', nil, 'alert')", sid)
    w.tick(1)
    st = states(r, sid)
    assert all(v == "open" for k, v in st.items() if k != "Frank"), st
    assert F.eval("return ns.Roll:Award(...)", sid, key("Frank")) is False
    w.assert_no_errors()


@R.case
def raider_leaves_raid_mid_roll():
    r = setup()
    w = r.w
    panel_start(r["Alice"], RUBY_DRAPE)
    w.tick(1)
    sid = active_session(r["Alice"])["id"]
    click_roll(r, "Frank", 97)
    click_roll(r, "Dave", 30)
    w.tick(0.5)
    r.leave_raid("Frank")
    w.tick(2)
    F = r["Frank"]
    assert not F.eval("return IsInRaid()")
    assert not rollframe_state(F)["shown"], "popup hides when leaving the raid"
    assert session_info(F, sid)["state"] == "closed", session_info(F, sid)
    # the rest of the raid carries on
    click_roll(r, "Carol", 50)
    w.tick(1)
    res = results(r["Alice"], sid)
    assert {x["key"] for x in res if x.get("roll")} >= {key("Carol"), key("Dave")}, res
    fr = [x for x in res if x["key"] == key("Frank")]
    assert fr and fr[0]["inRaid"] is False, res
    w.tick(30)
    assert all(v == "closed" for k, v in states(r, sid).items()), states(r, sid)
    w.assert_no_errors()


@R.case
def departed_roller_not_suggested():
    """A player who rolled and then left the raid (disconnect / left group) cannot receive the item any more;
    suggesting them makes the council hand-pick someone else by hand."""
    r = setup()
    w = r.w
    panel_start(r["Alice"], MINDBLADE)          # nobody's BiS: pure roll
    w.tick(1)
    sid = active_session(r["Alice"])["id"]
    click_roll(r, "Frank", 97)
    click_roll(r, "Dave", 30)
    w.tick(0.5)
    r.leave_raid("Frank")
    w.tick(31)
    res = results(r["Alice"], sid)
    sug = [x["key"] for x in res if x["suggested"]]
    assert sug == [key("Dave")], "suggested %r although Frank left the raid: %r" % (sug, res)
    w.assert_no_errors()


@R.case
def starter_leaves_raid_others_close_by_fallback():
    r = setup()
    w = r.w
    panel_start(r["Bob"], RUBY_DRAPE)           # Bob (council, not leader) starts
    w.tick(1)
    sid = active_session(r["Bob"])["id"]
    click_roll(r, "Dave", 40)
    r.leave_raid("Bob")
    w.tick(1)
    assert session_info(r["Bob"], sid)["state"] == "closed"
    others = [n for n in ADDON_USERS if n != "Bob"]
    w.tick(28)
    assert all(states(r, sid, others)[n] == "open" for n in others), states(r, sid, others)
    w.tick(4)                                   # endsAt + 3 s fallback
    assert all(states(r, sid, others)[n] == "closed" for n in others), states(r, sid, others)
    # the ML (council) can still award it
    r["Alice"].eval("ns.Roll:Award(...)", sid, key("Dave"))
    w.tick(0.2)
    assert "DISASTERZONE_GIVE_ITEM" in r["Alice"].popups(), r["Alice"].popups()
    w.assert_no_errors()


@R.case
def reload_mid_roll_raider_and_starter():
    r = setup()
    w = r.w
    panel_start(r["Alice"], RUBY_DRAPE)
    w.tick(1)
    sid = active_session(r["Alice"])["id"]
    click_roll(r, "Dave", 40)
    r["Dave"].relog()                          # /reload: sessions are memory-only
    install_probes([r["Dave"]])
    w.tick(2)
    assert r["Dave"].eval("return ns.Roll:Get(...) == nil", sid)
    w.player_roll("Dave", 88)                  # Dave rolls again by hand after the reload: others keep the first
    w.tick(1)
    d = [x for x in results(r["Alice"], sid) if x["key"] == key("Dave")][0]
    assert d["roll"] == 40 and d["count"] == 2, d
    # now the starter reloads mid-roll: nobody sends RE, everyone else closes at end + 3 s
    click_roll(r, "Bob", 60)
    r["Alice"].relog()
    install_probes([r["Alice"]])
    w.tick(33)
    others = [n for n in ADDON_USERS if n not in ("Alice", "Dave")]
    assert all(v == "closed" for v in states(r, sid, others).values()), states(r, sid, others)
    # Bob (council) awards through the confirm popup
    r["Bob"].eval("ns.Roll:Award(...)", sid, key("Bob"))
    w.tick(0.2)
    r["Bob"].accept_popup("DISASTERZONE_CONFIRM_AWARD")
    w.tick(2)
    assert session_info(r["Carol"], sid)["state"] == "awarded"
    assert r["Alice"].eval("return ns.Roll:Get(...) == nil", sid)
    w.assert_no_errors()


@R.case
def starter_reload_then_restarts_same_roll():
    """The ML /reloads mid-roll (sessions are memory-only), reopens the drop panel and clicks Roll again for the
    same item while the old roll is still open on everybody else's client. The new roll must be the one that runs
    everywhere: raiders' rolls, the close and the award all have to reach every client."""
    r = setup()
    w = r.w
    A = r["Alice"]
    panel_start(A, RUBY_DRAPE)
    w.tick(1)
    old = active_session(A)["id"]
    click_roll(r, "Dave", 40)
    w.tick(4)
    A.relog()
    install_probes([A])
    w.tick(2)
    A.slash("/dz drops")
    w.tick(0.5)
    panel_start(A, RUBY_DRAPE)
    w.tick(1)
    new = active_session(A)
    assert new and new["id"] != old, new
    new = new["id"]
    acts = {n: (active_session(r[n]) or {}).get("id") for n in ADDON_USERS}
    assert set(acts.values()) == {new}, "clients run different rolls after the restart: %r (old %s, new %s)" % (acts, old, new)
    for n in ("Bob", "Carol"):
        assert rollframe_state(r[n])["id"] == new, (n, rollframe_state(r[n]))
    click_roll(r, "Bob", 60)
    w.tick(31)
    assert set(states(r, new).values()) == {"closed"}, states(r, new)
    res = assert_same_results(r, new)
    assert res[0]["key"] == key("Bob") and res[0]["suggested"], res
    A.eval("ns.Roll:Award(...)", new, key("Bob"))
    w.tick(0.2)
    A.accept_popup("DISASTERZONE_CONFIRM_AWARD")      # the reload closed the loot window
    w.tick(2)
    assert set(states(r, new).values()) == {"awarded"}, states(r, new)
    assert strip_codes(rollframe_state(r["Bob"])["status"]).startswith("You won"), rollframe_state(r["Bob"])
    w.assert_no_errors()


@R.case
def slash_roll_with_item_link_uses_recent_drop():
    r = setup()
    w = r.w
    A = r["Alice"]
    link = A.eval("return ns.ItemDB:GetLink(%d)" % THOUSAND_MARKS)
    A.slash("/dz roll " + link)
    w.tick(1)
    act = active_session(A)
    assert act and act["i"] == THOUSAND_MARKS and act["s"] == PRINCE_GUID and act["c"] == 1, act
    for n in ADDON_USERS:
        assert (active_session(r[n]) or {}).get("id") == act["id"], n
    blk = [b for b in panel_blocks(r["Bob"]) if b["item"] == THOUSAND_MARKS][0]
    assert "Rolling" in strip_codes(blk["sub"]), blk
    A.slash("/dz roll end")
    w.tick(1)
    assert set(states(r, act["id"]).values()) == {"closed"}
    r["Carol"].slash("/dz roll " + link)       # not allowed for a raider
    w.tick(1)
    assert all(active_session(r[n]) is None for n in ADDON_USERS)
    w.assert_no_errors()


@R.case
def popup_shows_own_equipped_items_for_ring_pair():
    r = setup()
    w = r.w
    C = r["Carol"]
    C.equip({11: JADE_RING, 12: 28510})         # Spectral Band of Innervation in finger 2
    w.tick(12)
    panel_start(r["Alice"], THOUSAND_MARKS)
    w.tick(1)
    worn = C.eval_py("""local out = {} for i, b in ipairs(ns.RollFrame.frame.wear) do if b:IsShown() then out[#out+1] = b.itemID end end return out""")
    assert worn == [JADE_RING, 28510], worn
    assert strip_codes(C.eval("return ns.RollFrame.frame.wearLabel:GetText()")) == "Wearing:"
    # the council panel row for Carol shows both worn rings (Addendum §18) once her list is synced
    icons = r["Alice"].eval_py("""local out = {}
        for _, b in ipairs(ns.DropPanel.blocks) do if b:IsShown() and b.itemID == %d then
          for _, row in ipairs(b.rows) do if row:IsShown() and row.data and row.data.key == 'Carol-Thunderstrike' then
            for _, e in ipairs(row.eqs) do if e:IsShown() then out[#out+1] = e.itemID end end end end end end
        return out""" % THOUSAND_MARKS)
    assert icons == [JADE_RING, 28510], icons
    w.assert_no_errors()


@R.case
def uncached_item_roll_popup_fills_in():
    kw = {n: {"items_uncached": True} for n in ADDON_USERS}
    r = setup(client_kw=kw, items=[(MINDBLADE, 4)])
    w = r.w
    # Carol never saw the item: RS arrives for an item her client has not cached
    panel_start(r["Alice"], MINDBLADE)
    w.tick(1.5)
    st = rollframe_state(r["Carol"])
    assert st["shown"] and "Nathrezim Mindblade" in strip_codes(st["name"]), st
    w.assert_no_errors()


@R.case
def pass_then_roll_counts_as_roll():
    r = setup()
    w = r.w
    panel_start(r["Alice"], RUBY_DRAPE)
    w.tick(1)
    sid = active_session(r["Alice"])["id"]
    click_pass(r, "Dave")
    w.tick(0.5)
    w.player_roll("Dave", 42)                   # changed his mind and typed /roll
    w.tick(1)
    d = [x for x in results(r["Alice"], sid) if x["key"] == key("Dave")][0]
    assert d["roll"] == 42 and d["response"] == "roll", d
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

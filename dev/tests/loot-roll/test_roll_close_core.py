#!/usr/bin/env python
"""Loot-roll area, Addendum C (core): a roll is resolved once its item is handed out or awarded.

Roll:OnItemLooted (every client, from CHAT_MSG_LOOT), Roll:MarkAwardedExternally (the drop panel's plain
"Award..." path), duplicate copies, loot message before / after RW, exactly one ledger entry per award.

Run: luaenv\\Scripts\\python.exe tests\\loot-roll\\test_roll_close_core.py   [-k substring]
"""
from lr_common import *  # noqa: F401,F403
from test_rolls import setup, click_roll, ADDON_USERS, states  # noqa: F401

R = Runner("loot-roll / roll close (Addendum C core)")


def rolled_session(r, item=RUBY_DRAPE, rolls=(("Bob", 54), ("Dave", 80), ("Frank", 12)), close=True, starter="Alice",
                   copy=1):
    r[starter].eval("ns.DropPanel:StartRoll(...)", item, copy)
    r.w.tick(1)
    sid = active_session(r[starter])["id"]
    for name, v in rolls:
        click_roll(r, name, v)
    r.w.tick(1)
    if close:
        r[starter].eval("ns.Roll:End(...)", sid)
        r.w.tick(1)
    return sid


def ses(c, sid):
    return c.eval_py(r"""
        local s = ns.Roll:Get(...)
        if not s then return nil end
        return { state = s.state, winner = s.winner, given = s.given, via = s.via or false, looted = s.looted or false }""",
                     sid)


def visible_for(c, item):
    return [e for e in ledger_visible(c) if e["i"] == item]


# ------------------------------------------------------------------------------------------------------------------
@R.case
def a_blizzard_hand_out_closes_every_popup():
    """(a) The roll is closed; the ML hands the item out with Blizzard's master-loot menu (no DisasterZone click)."""
    r = setup()
    w = r.w
    sid = rolled_session(r)
    log0 = len(w.addon_log)
    w.broadcast_loot_received(r["Dave"], RUBY_DRAPE)
    w.tick(0.5)
    for n in ADDON_USERS:
        s = ses(r[n], sid)
        assert s == {"state": "awarded", "winner": key("Dave"), "given": True, "via": "loot", "looted": True}, (n, s)
    assert msgs_of_type(w, "RW", log0) == [] and msgs_of_type(w, "RE", log0) == [], "no network traffic needed"
    res = results(r["Alice"], sid)
    assert res[0]["key"] == key("Bob") and res[0]["suggested"], "results frozen as they were: %r" % res
    for n in ("Carol", "Erin"):
        st = strip_codes(rollframe_state(r[n])["status"])
        assert st.startswith("Won by Dave"), (n, st)       # the UI may add "(looted)"
    st = strip_codes(rollframe_state(r["Dave"])["status"])
    assert st.startswith("You won it!"), st
    w.tick(12)
    for n in ADDON_USERS:
        assert not rollframe_state(r[n])["shown"], (n, rollframe_state(r[n]))
    # the council's loot-line auto entry is the only log entry
    for n in ("Alice", "Bob"):
        vis = visible_for(r[n], RUBY_DRAPE)
        assert [(e["w"], e["s"]) for e in vis] == [(key("Dave"), "a")], (n, vis)
    w.assert_no_errors()


@R.case
def b_plain_award_goes_through_the_roll():
    """(b) Plain "Award..." while a roll session exists: RW, popups resolve, exactly one ledger entry."""
    r = setup()
    w = r.w
    B = r["Bob"]
    sid = rolled_session(r)
    log0, chat0 = len(w.addon_log), len(w.chat_log)
    assert B.eval("return ns.Roll:MarkAwardedExternally(...)", sid, key("Dave")) is True
    assert B.popups() == [], "no give / confirm popup: the panel already confirmed"
    w.tick(2)
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["_sender"] == key("Bob") and RW[0]["w"] == key("Dave") and RW[0]["g"] is False, RW
    for n in ADDON_USERS:
        s = ses(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Dave") and s["via"] is False, (n, s)
    for n in ("Alice", "Bob"):
        vis = visible_for(r[n], RUBY_DRAPE)
        assert [(e["w"], e["s"], e["n"]) for e in vis] == [(key("Dave"), "m", "roll 80")], (n, vis)
    lines = [e for e in w.chat_log[chat0:] if "->" in e["text"]]
    assert len(lines) == 1 and strip_codes(lines[0]["text"]) == "DisasterZone: [Ruby Drape of the Mysticant] -> Dave (rolled 80, Alt)", lines
    # the same award again is a no-op (true, nothing new); another winner is refused (caller records itself)
    assert B.eval("return ns.Roll:MarkAwardedExternally(...)", sid, key("Dave")) is True
    ok, why = B.eval("return ns.Roll:MarkAwardedExternally(...)", sid, key("Carol"))
    assert ok is False and why == "awarded", (ok, why)
    w.tick(1)
    assert len(msgs_of_type(w, "RW", log0)) == 1
    # the ML hands it out later: the loot message is matched to this award, still one visible entry
    r["Alice"].eval("GiveMasterLoot(1, 4)")          # candidate 4 = Dave
    w.tick(2)
    assert ses(r["Carol"], sid)["looted"] is True
    for n in ("Alice", "Bob"):
        assert len(visible_for(r[n], RUBY_DRAPE)) == 1, visible_for(r[n], RUBY_DRAPE)
    # a raider cannot use it
    assert r["Carol"].eval("return ns.Roll:MarkAwardedExternally(...)", sid, key("Carol")) == (False, "denied")
    w.assert_no_errors()


@R.case
def b2_plain_award_while_open_and_queued():
    r = setup()
    w = r.w
    A = r["Alice"]
    sid = rolled_session(r, close=False)
    log0 = len(w.addon_log)
    assert A.eval("return ns.Roll:MarkAwardedExternally(...)", sid, key("Bob")) is True
    w.tick(1)
    assert [m["id"] for m in msgs_of_type(w, "RE", log0)] == [sid]
    assert set(states(r, sid).values()) == {"awarded"}, states(r, sid)
    # a queued roll is not started for an item that is awarded directly
    A.eval("ns.DropPanel:StartRoll(...)", MINDBLADE, 1)
    A.eval("ns.DropPanel:StartRoll(...)", THOUSAND_MARKS, 1)
    w.tick(0.5)
    q = A.eval_py("local out = {} for i, s in ipairs(ns.Roll:GetQueue()) do out[i] = { s.id, s.i } end return out")
    assert q and q[-1][1] == THOUSAND_MARKS, q
    ok, why = A.eval("return ns.Roll:MarkAwardedExternally(...)", q[-1][0], key("Carol"))
    assert ok is False and why == "queued", (ok, why)
    assert A.eval("return ns.Roll:Get(...).state", q[-1][0]) == "cancelled"
    w.assert_no_errors()


@R.case
def c_two_copies_two_loot_messages_in_order():
    r = setup(items=[(RUBY_DRAPE, 4), (RUBY_DRAPE, 4)])
    w = r.w
    A = r["Alice"]
    s1 = rolled_session(r, copy=1, rolls=(("Bob", 60),))
    w.tick(3)
    s2 = rolled_session(r, copy=2, rolls=(("Dave", 70),))
    assert s1 != s2
    w.broadcast_loot_received(r["Bob"], RUBY_DRAPE)
    w.tick(0.5)
    for n in ADDON_USERS:
        assert ses(r[n], s1)["winner"] == key("Bob") and ses(r[n], s2)["state"] == "closed", n
    w.broadcast_loot_received(r["Dave"], RUBY_DRAPE)
    w.tick(0.5)
    for n in ADDON_USERS:
        a, b = ses(r[n], s1), ses(r[n], s2)
        assert (a["state"], a["winner"], b["state"], b["winner"]) == ("awarded", key("Bob"), "awarded", key("Dave")), (n, a, b)
    # a third copy's loot line finds nothing left
    assert A.eval("return ns.Roll:OnItemLooted(...) == nil", RUBY_DRAPE, key("Carol"))
    w.assert_no_errors()


@R.case
def d_loot_message_without_session_changes_nothing():
    r = setup()
    w = r.w
    sid = rolled_session(r)
    before = {n: ses(r[n], sid) for n in ADDON_USERS}
    w.broadcast_loot_received(r["Carol"], MINDBLADE)     # dropped too, never rolled
    w.tick(0.5)
    assert {n: ses(r[n], sid) for n in ADDON_USERS} == before
    w.broadcast_loot_received(r["Carol"], 990002)       # unknown item
    w.tick(0.5)
    assert {n: ses(r[n], sid) for n in ADDON_USERS} == before
    w.assert_no_errors()


@R.case
def e_explicit_award_after_the_loot_line_upgrades_it():
    """Loot line first (via "loot"), then the council records the award: RW, given, one ledger entry."""
    r = setup()
    w = r.w
    A = r["Alice"]
    sid = rolled_session(r)
    A.eval("GiveMasterLoot(1, 2)")                     # Blizzard menu: Bob
    w.tick(2)
    assert ses(r["Carol"], sid)["via"] == "loot"
    log0 = len(w.addon_log)
    assert A.eval("return ns.Roll:MarkAwardedExternally(...)", sid, key("Bob")) is True
    w.tick(2)
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["g"] is True, RW
    for n in ADDON_USERS:
        s = ses(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Bob") and s["via"] is False and s["looted"] is True, (n, s)
    for n in ("Alice", "Bob"):
        vis = visible_for(r[n], RUBY_DRAPE)
        assert [(e["w"], e["s"]) for e in vis] == [(key("Bob"), "m")], (n, vis)
    w.assert_no_errors()


@R.case
def f_loot_line_matched_to_the_wrong_copy_is_given_back():
    """Two closed copies. The ML hands one to Bob (loot line marks copy 1), but the council records copy 2 for
    Bob: copy 1 goes back to "closed" everywhere and the next hand-out resolves it."""
    r = setup(items=[(RUBY_DRAPE, 4), (RUBY_DRAPE, 4)])
    w = r.w
    A = r["Alice"]
    s1 = rolled_session(r, copy=1, rolls=(("Dave", 60),))
    w.tick(3)
    s2 = rolled_session(r, copy=2, rolls=(("Bob", 70),))
    w.broadcast_loot_received(r["Bob"], RUBY_DRAPE)
    w.tick(0.5)
    assert ses(r["Carol"], s1)["winner"] == key("Bob")
    assert A.eval("return ns.Roll:MarkAwardedExternally(...)", s2, key("Bob")) is True
    w.tick(2)
    for n in ADDON_USERS:
        a, b = ses(r[n], s1), ses(r[n], s2)
        assert a["state"] == "closed" and a.get("winner") is None, (n, a)
        assert b["state"] == "awarded" and b["winner"] == key("Bob") and b["looted"] is True, (n, b)
    w.broadcast_loot_received(r["Dave"], RUBY_DRAPE)
    w.tick(0.5)
    for n in ADDON_USERS:
        assert ses(r[n], s1)["winner"] == key("Dave"), n
    w.assert_no_errors()


@R.case
def f2_award_of_a_looted_copy_never_gives_the_other_copy():
    """Copy 1 was handed out with the Blizzard menu; the second copy is still in the loot window. Confirming the
    award of copy 1 must not offer (or do) a master-loot hand-out of the other copy."""
    r = setup(items=[(RUBY_DRAPE, 4), (RUBY_DRAPE, 4)])
    w = r.w
    A = r["Alice"]
    s1 = rolled_session(r, copy=1, rolls=(("Bob", 60),))
    A.eval("GiveMasterLoot(1, 2)")                     # Blizzard menu: Bob gets one of the two
    w.tick(2)
    assert ses(A, s1)["via"] == "loot" and A.eval("return ns.Loot:FindLootSlot(...) ~= nil", RUBY_DRAPE)
    A.eval("ns.Roll:Award(...)", s1, key("Bob"))
    w.tick(0.2)
    assert A.popups() == ["DISASTERZONE_CONFIRM_AWARD"], A.popups()
    A.accept_popup("DISASTERZONE_CONFIRM_AWARD")
    w.tick(2)
    s = ses(A, s1)
    assert s["state"] == "awarded" and s["given"] is True and s["via"] is False, s
    assert A.eval("return ns.Loot:FindLootSlot(...) ~= nil", RUBY_DRAPE), "the other copy stays in the loot window"
    assert len([e for e in ledger_visible(A) if e["i"] == RUBY_DRAPE]) == 1
    w.assert_no_errors()


@R.case
def g_open_roll_resolved_by_loot_line_and_queue_moves_on():
    r = setup()
    w = r.w
    A = r["Alice"]
    sid = rolled_session(r, close=False)
    A.eval("ns.DropPanel:StartRoll(...)", MINDBLADE, 1)
    w.tick(0.5)
    assert len(A.eval_py("return ns.Roll:GetQueue()") or []) == 1
    w.broadcast_loot_received(r["Bob"], RUBY_DRAPE)
    w.tick(0.5)
    for n in ADDON_USERS:
        assert ses(r[n], sid)["state"] == "awarded", n
    w.tick(5)
    act = active_session(A)
    assert act and act["i"] == MINDBLADE, act
    w.assert_no_errors()


@R.case
def h_old_sessions_are_not_matched():
    r = setup()
    w = r.w
    sid = rolled_session(r)
    w.tick(16 * 60)
    w.broadcast_loot_received(r["Bob"], RUBY_DRAPE)
    w.tick(0.5)
    assert ses(r["Carol"], sid)["state"] == "closed"
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

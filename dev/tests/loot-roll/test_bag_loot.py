#!/usr/bin/env python
"""Loot-roll area, part 5: bag loot under Free for All (Lady Vashj, Kael'thas).

Under Free for All in a raid that runs loot distribution, a boss item someone picks up is held for the council:
no automatic log entry, no roll resolved by the loot line. The council awards as usual; the holder's trade window
is filled with what the trade partner was awarded, and a completed trade marks the award handed out on every client.

Run: luaenv\\Scripts\\python.exe tests\\loot-roll\\test_bag_loot.py   [-k substring]
"""
from lr_common import *  # noqa: F401,F403
from test_rolls import click_roll, ADDON_USERS  # noqa: F401
from test_award import rolled_session, bag_items

R = Runner("loot-roll / bag loot (Free for All)")

FFA = 0


def setup_ffa(items=None, **kw):
    r = Raid(ml=None, loot_method=FFA, **kw)
    items = items or [(RUBY_DRAPE, 4), (THOUSAND_MARKS, 4), (HELM_CHAMPION, 4)]
    r["Alice"].open_loot(items)
    r.w.tick(2)
    return r


def pick_up(r, name, item):
    """name takes the item from the corpse: the loot line on every client, the item in their bags."""
    r.w.broadcast_loot_received(r[name], item, give_item=True)
    r.w.tick(3)


def held(c):
    return [(h["i"], h["k"]) for h in (c.eval_py("return ns.db.heldLoot") or [])]


def award(r, awarder, sid, winner):
    c = r[awarder]
    c.eval("ns.DropPanel:AwardRoll(...)", sid, key(winner))
    r.w.tick(0.2)
    assert c.popups() == ["DISASTERZONE_CONFIRM_AWARD"], c.popups()
    c.accept_popup("DISASTERZONE_CONFIRM_AWARD")
    r.w.tick(2)


@R.case
def ffa_pickup_is_held_not_an_award():
    r = setup_ffa()
    w = r.w
    assert r["Alice"].eval("return ns.Loot:IsBagLoot()") is True
    pick_up(r, "Alice", RUBY_DRAPE)
    for n in ADDON_USERS:
        assert held(r[n]) == [(RUBY_DRAPE, key("Alice"))], (n, held(r[n]))
        assert ledger_raw(r[n]) == [], "%s: a Free for All pick-up is no award: %r" % (n, ledger_raw(r[n]))
    assert any("You hold" in strip_codes(l) for l in printed_lines(r["Alice"])), printed_lines(r["Alice"])[-3:]
    assert any("picked up" in strip_codes(l) and "Alice" in l for l in printed_lines(r["Bob"])), printed_lines(r["Bob"])[-3:]
    w.assert_no_errors()


@R.case
def ffa_pickup_does_not_resolve_a_roll():
    r = setup_ffa()
    sid = rolled_session(r, close=False)
    pick_up(r, "Alice", RUBY_DRAPE)
    for n in ADDON_USERS:
        s = session_info(r[n], sid)
        assert s["state"] == "open" and s.get("winner") is None, (n, s)
    r.w.assert_no_errors()


@R.case
def master_loot_pickup_is_still_an_award():
    r = Raid()
    r["Alice"].open_loot([(RUBY_DRAPE, 4)])
    r.w.tick(2)
    assert r["Alice"].eval("return ns.Loot:IsBagLoot()") is False
    pick_up(r, "Carol", RUBY_DRAPE)
    assert held(r["Alice"]) == []
    assert [(e["w"], e["s"]) for e in ledger_visible(r["Alice"])] == [(key("Carol"), "a")]
    r.w.assert_no_errors()


@R.case
def award_then_trade_hands_it_out():
    r = setup_ffa()
    w = r.w
    A, D = r["Alice"], r["Dave"]
    pick_up(r, "Alice", RUBY_DRAPE)
    sid = rolled_session(r)
    log0 = len(w.addon_log)
    award(r, "Bob", sid, "Dave")
    for n in ADDON_USERS:
        s = session_info(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Dave") and not s["given"], (n, s)
    assert any("open a trade with Dave" in strip_codes(l) for l in printed_lines(A)), printed_lines(A)[-4:]
    assert A.eval_py("return ns.Roll:GetOwed(...)", key("Dave")) == [RUBY_DRAPE]

    A.open_trade("Dave")
    w.tick(1)
    assert A.eval("return GetTradePlayerItemLink(1) ~= nil") is True, "the awarded item is put into the trade window"
    assert A.eval("return GetTradePlayerItemLink(2)") is None
    assert A.complete_trade() == [RUBY_DRAPE]
    D.receive_item_message(RUBY_DRAPE)
    w.tick(3)
    assert RUBY_DRAPE not in bag_items(A)
    for n in ADDON_USERS:
        s = session_info(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Dave") and s["given"] is True, (n, s)
    RW = msgs_of_type(w, "RW", log0)
    assert [(m["_sender"], m["w"], m["g"]) for m in RW] == [(key("Bob"), key("Dave"), False),
                                                           (key("Alice"), key("Dave"), True)], RW
    assert held(A) == [], held(A)
    for n in ("Alice", "Bob"):
        vis = ledger_visible(r[n])
        assert [(e["w"], e["i"], e["s"]) for e in vis] == [(key("Dave"), RUBY_DRAPE, "m")], (n, vis)
    w.assert_no_errors()


@R.case
def trade_with_someone_else_puts_nothing_in():
    r = setup_ffa()
    A = r["Alice"]
    pick_up(r, "Alice", RUBY_DRAPE)
    sid = rolled_session(r)
    award(r, "Bob", sid, "Dave")
    A.open_trade("Carol")
    r.w.tick(1)
    assert A.eval("return GetTradePlayerItemLink(1)") is None
    A.cancel_trade()
    r.w.tick(1)
    assert session_info(A, sid)["given"] is False
    r.w.assert_no_errors()


@R.case
def award_to_the_holder_is_handed_out_at_once():
    r = setup_ffa()
    pick_up(r, "Alice", RUBY_DRAPE)
    sid = rolled_session(r, rolls=(("Alice", 90), ("Dave", 10)))
    award(r, "Bob", sid, "Alice")
    for n in ADDON_USERS:
        s = session_info(r[n], sid)
        assert s["winner"] == key("Alice") and s["given"] is True, (n, s)
    r.w.assert_no_errors()


@R.case
def switched_back_to_master_loot_after_the_pull():
    """The method of the pull counts: Free for All at the pull, master loot again when the boss dies."""
    r = Raid(ml=None, loot_method=FFA, encounter=False)
    w = r.w
    for c in r.clients:
        c._fire("ENCOUNTER_START", PRINCE_ENCOUNTER, "Prince Malchezaar", 3, 10)
    w.set_master_looter(r["Alice"])
    w.tick(1)
    for c in r.clients:
        c._fire("ENCOUNTER_END", PRINCE_ENCOUNTER, "Prince Malchezaar", 3, 10, 1)
    w.tick(1)
    assert r["Bob"].eval("return ns.Loot:IsBagLoot()") is True
    pick_up(r, "Alice", THOUSAND_MARKS)
    assert held(r["Bob"]) == [(THOUSAND_MARKS, key("Alice"))]
    assert ledger_raw(r["Bob"]) == []
    w.assert_no_errors()


@R.case
def held_items_survive_a_reload():
    r = setup_ffa()
    A = r["Alice"]
    pick_up(r, "Alice", RUBY_DRAPE)
    A.relog()
    r.w.tick(3)
    assert held(A) == [(RUBY_DRAPE, key("Alice"))], held(A)
    assert A.eval_py("return ns.Loot:GetHolder(...)", RUBY_DRAPE) == key("Alice")
    r.w.assert_no_errors()


@R.case
def plain_raider_holder_trade_is_handed_out_everywhere():
    """1.3: any looter may hold bag loot. A plain raider who traded the item to the council's winner tells the raid
    (the award's RW again with g): every client shows it handed out and forgets the holder. From the holder only that
    flag counts (it cannot pick a winner), and a later award of the same item to the former holder is not "handed
    out" at once."""
    r = setup_ffa()
    w = r.w
    C, D = r["Carol"], r["Dave"]
    pick_up(r, "Carol", RUBY_DRAPE)
    sid = rolled_session(r)
    award(r, "Bob", sid, "Dave")
    # neither somebody who does not hold it nor the holder naming another winner changes anything
    r["Erin"].eval("ns.Comm:Send({ t = 'RW', id = ..., w = select(2, ...), g = true }, 'RAID', nil, 'alert')",
                   sid, key("Dave"))
    C.eval("ns.Comm:Send({ t = 'RW', id = ..., w = select(2, ...), g = true }, 'RAID', nil, 'alert')", sid, key("Carol"))
    w.tick(1)
    for n in ADDON_USERS:
        s = session_info(r[n], sid)
        assert s["winner"] == key("Dave") and not s["given"], (n, s)
        assert held(r[n]) == [(RUBY_DRAPE, key("Carol"))], (n, held(r[n]))
    log0 = len(w.addon_log)
    C.open_trade("Dave")
    w.tick(1)
    assert C.complete_trade() == [RUBY_DRAPE]
    D.receive_item_message(RUBY_DRAPE)
    w.tick(3)
    RW = msgs_of_type(w, "RW", log0)
    assert [(m["_sender"], m["w"], m["g"]) for m in RW] == [(key("Carol"), key("Dave"), True)], RW
    for n in ADDON_USERS:
        s = session_info(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Dave") and s["given"] is True, (n, s)
        assert held(r[n]) == [], (n, held(r[n]))
    # the same item awarded to Carol later (another copy): not taken as already handed out
    r["Alice"].eval("ns.Roll:Start(...)", RUBY_DRAPE)
    w.tick(1)
    sid2 = active_session(r["Alice"])["id"]
    click_roll(r, "Carol", 70)
    w.tick(1)
    r["Alice"].eval("ns.Roll:End(...)", sid2)
    w.tick(1)
    award(r, "Bob", sid2, "Carol")
    for n in ADDON_USERS:
        s = session_info(r[n], sid2)
        assert s["winner"] == key("Carol") and not s["given"], (n, s)
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

#!/usr/bin/env python
"""Loot-roll area, part 2: CHAT_MSG_LOOT -> automatic award-log entries (SPEC §10.4, §11).

Each council client records the loot message it sees; entries sync between council members (A messages) and the
visible log de-duplicates identical awards across clients and hides the auto entry after a manual award.

Run: luaenv\\Scripts\\python.exe tests\\loot-roll\\test_ledger_auto.py   [-k substring]
"""
from lr_common import *  # noqa: F401,F403

R = Runner("loot-roll / ledger auto-record")

COUNCIL = ("Alice", "Bob")
RAIDERS = ("Carol", "Dave", "Erin", "Frank", "Gina")


def visible(r, name, item=None):
    return [e for e in ledger_visible(r[name]) if item is None or e["i"] == item]


@R.case
def loot_message_recorded_once_on_every_council_client():
    r = Raid()
    w = r.w
    log0 = len(w.addon_log)
    texts = w.broadcast_loot_received(r["Carol"], THOUSAND_MARKS)
    assert texts[key("Carol")].startswith("You receive loot:"), texts
    w.tick(3)
    ids = set()
    for n in COUNCIL:
        vis = visible(r, n)
        assert len(vis) == 1, (n, vis)
        e = vis[0]
        assert e["w"] == key("Carol") and e["i"] == THOUSAND_MARKS and e["s"] == "a" and e["b"] == "Karazhan:Prince", e
        ids.add(e["id"])
        raw = ledger_raw(r[n])
        assert len(raw) == 1, "identical auto entries (same second) merge by id: %r" % raw
    assert len(ids) == 1, "both council clients show the same entry: %r" % ids
    for n in RAIDERS:
        assert ledger_raw(r[n]) == [], "%s is not council: must not record" % n
    A = msgs_of_type(w, "A", log0)
    assert A and all(m["_chat_type"] == "WHISPER" for m in A), A
    assert all(m["e"]["id"] in ids for m in A), A
    w.assert_no_errors()


@R.case
def loot_message_seen_at_different_seconds_dedupes():
    r = Raid()
    w = r.w
    w.broadcast_loot_received(r["Erin"], HELM_CHAMPION, clients=[r["Alice"]])
    w.tick(1.6)   # Bob's client sees the same line in the next server second
    w.broadcast_loot_received(r["Erin"], HELM_CHAMPION, clients=[c for c in r.clients if c.name != "Alice"])
    w.tick(3)
    shown = {}
    for n in COUNCIL:
        raw = ledger_raw(r[n])
        # CDLoot 0.5: a council member's broadcast is cancelled when an earlier entry of the same line arrives
        # first, so a client may hold one or both raw entries (the digest sync evens them out later).
        assert 1 <= len(raw) <= 2, "the auto entries of one loot line (%s): %r" % (n, raw)
        vis = visible(r, n)
        assert len(vis) == 1, "but only one is visible (%s): %r" % (n, vis)
        shown[n] = vis[0]["id"]
    assert shown["Alice"] == shown["Bob"], "the same entry must win on every client: %r" % shown
    w.assert_no_errors()


@R.case
def manual_award_then_loot_message_one_visible_entry():
    r = Raid()
    w = r.w
    r["Alice"].open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    r["Alice"].eval("ns.DropPanel:Award(%d, 'Bob-Thunderstrike', 'Karazhan:Prince')" % RUBY_DRAPE)
    w.tick(1)
    r["Alice"].eval("GiveMasterLoot(1, ...)", 2)        # candidate 2 = Bob -> loot message 0.2 s later
    w.tick(3)
    for n in COUNCIL:
        raw = ledger_raw(r[n])
        assert sorted(e["s"] for e in raw) == ["a", "m"], (n, raw)
        vis = visible(r, n)
        assert len(vis) == 1 and vis[0]["s"] == "m" and vis[0]["w"] == key("Bob"), (n, vis)
    assert r["Bob"].eval("return ns.Ledger:HasAward('Bob-Thunderstrike', %d)" % RUBY_DRAPE)
    assert r["Alice"].eval("return ns.Ledger:CountSince('Bob-Thunderstrike', 0)") == 1
    w.assert_no_errors()


@R.case
def loot_message_then_late_manual_award_one_visible_entry():
    r = Raid()
    w = r.w
    w.broadcast_loot_received(r["Dave"], RUBY_DRAPE)
    w.tick(30)
    r["Bob"].eval("ns.Ledger:Award(%d, 'Dave-Thunderstrike', 'Karazhan:Prince', 'by hand')" % RUBY_DRAPE)
    w.tick(3)
    for n in COUNCIL:
        vis = visible(r, n)
        assert len(vis) == 1 and vis[0]["s"] == "m" and vis[0]["n"] == "by hand", (n, vis)
    w.assert_no_errors()


@R.case
def own_loot_self_message_and_extra_member_winner():
    r = Raid()
    w = r.w
    w.broadcast_loot_received(r["Alice"], HELM_CHAMPION)          # "You receive loot" on Alice's client
    w.broadcast_loot_received("Zed", HELM_DEFENDER)                # guildie without the addon
    w.tick(3)
    for n in COUNCIL:
        got = sorted((e["w"], e["i"]) for e in visible(r, n))
        assert got == sorted([(key("Alice"), HELM_CHAMPION), (key("Zed"), HELM_DEFENDER)]), (n, got)
    w.assert_no_errors()


@R.case
def two_copies_to_two_players_both_visible():
    r = Raid()
    w = r.w
    w.broadcast_loot_received(r["Erin"], HELM_CHAMPION)
    w.broadcast_loot_received(r["Gina"], HELM_CHAMPION)
    w.tick(3)
    for n in COUNCIL:
        got = sorted(e["w"] for e in visible(r, n, HELM_CHAMPION))
        assert got == [key("Erin"), key("Gina")], (n, got)
    w.assert_no_errors()


@R.case
def ignored_outside_raid_instance_and_for_non_raid_loot():
    r = Raid()
    w = r.w
    w.broadcast_loot_received(r["Carol"], 22829)                  # not raid loot
    w.broadcast_loot_received(r["Carol"], JADE_RING, count=1)
    w.define_item(990001, "Some Rare Ring", quality=3, equip_loc="INVTYPE_FINGER", class_id=4, subclass_id=0)
    w.broadcast_loot_received(r["Carol"], 990001)                 # below epic threshold, no raid source
    w.tick(2)
    for n in COUNCIL:
        got = [(e["w"], e["i"]) for e in visible(r, n)]
        assert got == [(key("Carol"), JADE_RING)], (n, got)
    w.leave_instance()
    w.tick(1)
    w.broadcast_loot_received(r["Dave"], RUBY_DRAPE)               # e.g. a trade/loot in Shattrath
    w.tick(2)
    for n in COUNCIL:
        assert all(e["i"] != RUBY_DRAPE for e in visible(r, n)), "outside a raid instance nothing is recorded"
    w.assert_no_errors()


@R.case
def multiple_count_loot_message_parsed():
    r = Raid()
    w = r.w
    w.broadcast_loot_received(r["Frank"], HELM_HERO, count=2)      # "... receives loot: [X]x2."
    w.tick(3)
    for n in COUNCIL:
        got = [(e["w"], e["i"]) for e in visible(r, n)]
        assert got == [(key("Frank"), HELM_HERO)], (n, got)
    w.assert_no_errors()


@R.case
def council_member_joining_later_catches_up_via_digest():
    r = Raid()
    w = r.w
    r["Bob"].logout()
    w.tick(1)
    w.broadcast_loot_received(r["Carol"], THOUSAND_MARKS)
    w.tick(2)
    assert len(visible(r, "Alice")) == 1
    r["Bob"].login()
    install_probes([r["Bob"]])
    w.tick(2)
    r.form_raid([c for c in r.clients])
    w.tick(40)
    r["Bob"].slash("/cdl sync")
    w.tick(20)
    vis = visible(r, "Bob")
    assert [(e["w"], e["i"]) for e in vis] == [(key("Carol"), THOUSAND_MARKS)], vis
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

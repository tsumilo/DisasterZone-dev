#!/usr/bin/env python
"""(g) Award ledger sync between council members (SPEC §11: A / LW / LG, digests, void, de-dupe view).

Run:  luaenv\\Scripts\\python.exe tests\\sync\\test_ledger_sync.py   [-k substring]
"""
import itertools
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (quick_double_reload, Runner, Client, new_world, up, settle, key, logical_messages, traffic, fmt_traffic,  # noqa: E402
                    ledger_ids, ledger_raw, ledger_view, seed_guild_council, is_council)

r = Runner("ledger sync")
RK, R2K, C1K, C2K = key("Raider"), key("Raiderb"), key("Councila"), key("Councilb")
ITEM_A, ITEM_B, ITEM_C = 28477, 28453, 28506        # Karazhan (Attumen) loot


def setup(c2_online=False):
    w = new_world()
    R = Client(w, "Raider", class_file="PALADIN", guild_rank=3)
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1)
    C2 = Client(w, "Councilb", class_file="MAGE", guild_rank=1, online=c2_online)
    w.add_offline_member("Raiderb", "WARRIOR", 3)
    for c in (R, C1, C2):
        if c.online:
            up(c)
    settle(w, 30)
    return w, R, C1, C2


def view_signature(c, keys=(RK, R2K)):
    sig = c.eval_py("""
      local keys, items = ...
      local out = { view = {}, has = {}, count = {} }
      for _, e in ipairs(ns.Ledger:GetEntries({ includeVoid = true })) do
        out.view[#out.view + 1] = e.id .. (e.vd and "|void" or "")
      end
      for _, k in ipairs(keys) do
        out.count[k] = ns.Ledger:CountSince(k, 0)
        for _, i in ipairs(items) do out.has[k .. ":" .. i] = ns.Ledger:HasAward(k, i) and true or false end
      end
      return out""", list(keys), [ITEM_A, ITEM_B, ITEM_C])
    return sig


def full_entries(c):
    raw = ledger_raw(c)
    return {k: tuple(sorted((kk, vv) for kk, vv in v.items() if kk != "by")) for k, v in raw.items()}


def ledger_traffic(w, mark):
    return [m for m in logical_messages(w, mark) if m["t"] in ("A", "LW", "LG")]


@r.case
def g_awards_recorded_while_c2_offline_reach_c2():
    w, R, C1, C2 = setup()
    w.make_raid([R, C1], master_looter=C1, leader=C1)     # the raid leader is council for the raid (E §29)
    w.enter_instance("Karazhan", 532)
    w.encounter(652, "Attumen the Huntsman")
    e1 = C1.eval_py("return ns.Ledger:Award(...)", ITEM_A, RK, "", "council pick")
    e2 = C1.eval_py("return ns.Ledger:Award(...)", ITEM_B, R2K, "", None)
    assert e1 and e2
    w.broadcast_loot_received(R, ITEM_C)             # CHAT_MSG_LOOT -> auto entry on C1 (council, raid instance)
    settle(w, 2)
    ids = ledger_ids(C1)
    assert len(ids) == 3 and any(i.startswith("a") for i in ids), ids
    assert ledger_ids(R) == [], "a raider recorded ledger entries"

    mark = len(w.addon_log)
    C2.login()
    settle(w, 45)
    assert ledger_ids(C2) == ids, "C2 missing entries: %s vs %s" % (ledger_ids(C2), ids)
    assert full_entries(C2) == full_entries(C1)
    assert view_signature(C2) == view_signature(C1)
    lt = ledger_traffic(w, mark)
    kinds = sorted(m["t"] for m in lt)
    assert kinds.count("LW") <= 2 and kinds.count("LG") <= 2, "digest sync too chatty: %s" % kinds
    r.note("(g) C2 digest catch-up: %s" % kinds)
    w.assert_no_errors()


@r.case
def g_void_propagates_online_and_offline():
    w, R, C1, C2 = setup(c2_online=True)
    e1 = C1.eval_py("return ns.Ledger:Award(...)", ITEM_A, RK, "", "")
    e2 = C1.eval_py("return ns.Ledger:Award(...)", ITEM_B, RK, "", "")
    settle(w, 5)
    assert ledger_ids(C2) == ledger_ids(C1) and len(ledger_ids(C2)) == 2

    # online: void travels as an A message
    assert C1.eval("return ns.Ledger:Void(...)", e1["id"], True)
    settle(w, 3)
    assert ledger_raw(C2)[e1["id"]].get("vd") is True
    assert ledger_raw(C2)[e1["id"]]["vts"] == ledger_raw(C1)[e1["id"]]["vts"]
    assert view_signature(C2) == view_signature(C1)
    assert not C2.eval("return ns.Ledger:HasAward(...)", RK, ITEM_A)

    # offline: C2 misses a restore and a new void; digest sync must repair both
    C2.logout()
    settle(w, 5)
    assert C1.eval("return ns.Ledger:Void(...)", e1["id"], False)     # restore
    assert C1.eval("return ns.Ledger:Void(...)", e2["id"], True)
    settle(w, 2)
    C2.login()
    settle(w, 45)
    assert full_entries(C2) == full_entries(C1), (full_entries(C2), full_entries(C1))
    assert view_signature(C2) == view_signature(C1)
    assert C2.eval("return ns.Ledger:HasAward(...)", RK, ITEM_A)
    assert not C2.eval("return ns.Ledger:HasAward(...)", RK, ITEM_B)
    w.assert_no_errors()


@r.case
def g_conflicting_void_edits_converge():
    """Both council members change the void state of the same entry while apart: the later vts wins
    everywhere, whatever side connects first."""
    w, R, C1, C2 = setup(c2_online=True)
    e = C1.eval_py("return ns.Ledger:Award(...)", ITEM_A, RK, "", "")
    settle(w, 5)
    C2.logout()
    settle(w, 3)
    C1.eval("ns.Ledger:Void(...)", e["id"], True)    # C1 voids at T1
    C1.logout()
    settle(w, 5)
    C2.login()
    settle(w, 30)
    C2.eval("ns.Ledger:Void(...)", e["id"], True)    # C2 voids independently at T2 > T1
    settle(w, 5)
    C1.login()
    settle(w, 45)
    a, b = ledger_raw(C1)[e["id"]], ledger_raw(C2)[e["id"]]
    assert a.get("vd") is True and b.get("vd") is True and a.get("vts") == b.get("vts"), (a, b)
    C1.logout()
    settle(w, 3)
    C2.eval("ns.Ledger:Void(...)", e["id"], False)   # C2 restores while C1 is away
    settle(w, 5)
    C1.login()
    settle(w, 45)
    a, b = ledger_raw(C1)[e["id"]], ledger_raw(C2)[e["id"]]
    assert not a.get("vd") and not b.get("vd"), (a, b)
    assert view_signature(C1) == view_signature(C2)
    w.assert_no_errors()


@r.case
def g_two_council_award_same_item_view_identical():
    w, R, C1, C2 = setup(c2_online=True)
    C1.eval("ns.Ledger:Award(...)", ITEM_A, RK, "", "C1 click")
    w.tick(1.3)
    C2.eval("ns.Ledger:Award(...)", ITEM_A, RK, "", "C2 click")
    settle(w, 5)
    assert len(ledger_ids(C1)) == 2 and ledger_ids(C1) == ledger_ids(C2)
    v1, v2 = ledger_view(C1, False), ledger_view(C2, False)
    assert v1 == v2 and len(v1) == 1, "double click shows %s on C1, %s on C2" % (v1, v2)
    assert C1.eval("return ns.Ledger:CountSince(...)", RK, 0) == 1 == C2.eval("return ns.Ledger:CountSince(...)", RK, 0)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# De-dupe view independent of merge order
# ------------------------------------------------------------------------------------------------------------------
T = 1789900000


def crafted_entries():
    X, Y = ITEM_A, ITEM_B
    E = []

    def add(kind, ts, item=X, w=RK, by=C1K, vd=None, vts=None, suffix=""):
        short = w.split("-")[0] if kind == "a" else by.split("-")[0]
        e = {"id": "%s%d%s%d%s" % (kind, ts, short, item, suffix), "i": item, "w": w, "b": "", "ts": ts, "by": by,
             "s": kind}
        if vd:
            e["vd"] = True
        if vts:
            e["vts"] = vts
        E.append(e)

    add("a", T)                       # hidden: 250s before the kept manual m1 (10-minute rule)
    add("a", T + 60, by=C2K)          # hidden: same-kind within 120s
    add("a", T + 110)                 # hidden
    add("a", T + 200)                 # hidden: 50s before manual m1 (10-minute rule)
    add("m", T + 250)                 # kept (m1)
    add("m", T + 300, by=C2K)         # hidden: second manual within 120s
    add("m", T + 250, by=C2K)         # same ts as m1, different id -> order by id decides
    add("a", T + 250 + 3 * 3600)      # hidden: < 6h after m1
    add("a", T + 250 + 7 * 3600)      # kept
    add("a", T + 250 + 7 * 3600 + 30) # hidden
    add("m", T + 20000, item=Y, vd=True, vts=T + 20100)   # voided manual: does not hide the auto below
    add("a", T + 20060, item=Y)       # kept
    add("a", T + 30000, item=Y, w=R2K)
    add("m", T + 30010, item=Y, w=R2K, by=C2K)            # hides the auto 10s before it
    return E


@r.case
def g_dedupe_view_independent_of_merge_order():
    w = new_world()
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1)
    C2 = Client(w, "Councilb", class_file="MAGE", guild_rank=1)
    up(C1)
    up(C2)
    w.tick(2)
    entries = crafted_entries()
    rng = random.Random(7)
    orders = [list(range(len(entries))), list(reversed(range(len(entries))))]
    for _ in range(6):
        o = list(range(len(entries)))
        rng.shuffle(o)
        orders.append(o)
    sigs = []
    for order in orders:
        for c in (C1, C2):
            c.eval("for id in pairs(ns.db.ledger) do ns.db.ledger[id] = nil end")
        for i in order:
            C1.eval("ns.Ledger:Merge(...)", entries[i], C2K)
        for i in reversed(order):
            C2.eval("ns.Ledger:Merge(...)", entries[i], C1K)
        s1, s2 = view_signature(C1), view_signature(C2)
        assert s1 == s2, "views differ for merge order %s:\nC1 %s\nC2 %s" % (order, s1, s2)
        sigs.append(s1)
    assert all(s == sigs[0] for s in sigs), "view depends on merge order"
    visible = [v for v in sigs[0]["view"] if not v.endswith("|void")]
    r.note("(g) crafted ledger: %d entries -> %d visible: %s" % (len(entries), len(visible), visible))
    expected = {"m%dCouncila%d" % (T + 250, ITEM_A), "a%dRaider%d" % (T + 250 + 7 * 3600, ITEM_A),
                "a%dRaider%d" % (T + 20060, ITEM_B), "m%dCouncilb%d" % (T + 30010, ITEM_B)}
    assert set(visible) == expected, "visible %s, expected %s" % (sorted(visible), sorted(expected))
    # a voided manual must not hide the auto that follows it
    assert any(v.startswith("a%d" % (T + 20060)) for v in visible), visible
    w.assert_no_errors()


@r.case
def g_disjoint_ledgers_merge_to_identical_views():
    """C1 and C2 recorded different awards while never online together; after one login both hold the union
    and show the same de-duplicated view (network path: H/M digests -> LW -> LG)."""
    w, R, C1, C2 = setup()
    def shift(e):
        e = dict(e, ts=e["ts"] + 86400 * 2, id=e["id"].replace(str(e["ts"]), str(e["ts"] + 86400 * 2)))
        if "vts" in e:
            e["vts"] += 86400 * 2
        return e
    shifted = [shift(e) for e in crafted_entries()]
    for e in shifted[0::2]:
        C1.eval("ns.Ledger:Merge(...)", e, C1K)
    odd = shifted[1::2]
    C1.logout()
    settle(w, 3)
    C2.login()
    settle(w, 5)
    for e in odd:
        C2.eval("ns.Ledger:Merge(...)", e, C2K)
    settle(w, 5)
    mark = len(w.addon_log)
    C1.login()
    settle(w, 60)
    assert ledger_ids(C1) == ledger_ids(C2), (len(ledger_ids(C1)), len(ledger_ids(C2)))
    assert view_signature(C1) == view_signature(C2)
    first = [m["t"] for m in ledger_traffic(w, mark)]
    # no ping-pong: a fresh HELLO/MANIFEST round after convergence must not trigger ledger requests
    mark2 = len(w.addon_log)
    C2.eval("ns.Sync:SendHello()")
    settle(w, 30)
    again = [m["t"] for m in ledger_traffic(w, mark2)]
    r.note("(g) disjoint merge traffic: %s; after convergence: %s" % (first, again))
    assert not again, "ledger traffic after convergence: %s" % again
    w.assert_no_errors()


@r.case
def g_bulk_history_sync_batches():
    """120 awards over 40 days on C1; a fresh council member gets all of them in bounded traffic."""
    w, R, C1, C2 = setup()
    now = 1790000000
    n = 0
    for d in range(40):
        for k in range(3):
            ts = now - d * 86400 - k * 7000 - 100
            e = {"id": "m%dCouncila%d" % (ts, 28000 + k), "i": 28000 + k, "w": RK if k % 2 else R2K, "b": "",
                 "ts": ts, "by": C1K, "s": "m"}
            C1.eval("ns.Ledger:Merge(...)", e, C1K)
            n += 1
    settle(w, 2)
    assert len(ledger_ids(C1)) == n
    mark = len(w.addon_log)
    C2.login()
    settle(w, 90)
    assert len(ledger_ids(C2)) == n, "C2 got %d of %d entries" % (len(ledger_ids(C2)), n)
    assert view_signature(C1) == view_signature(C2)
    lt = ledger_traffic(w, mark)
    sent = {}
    for m in lt:
        if m["t"] == "LG":
            for e in m["msg"].get("e", []):
                sent[e["id"]] = sent.get(e["id"], 0) + 1
    dups = {k: v for k, v in sent.items() if v > 1}
    kinds = [m["t"] for m in lt]
    parts = sum(m["parts"] for m in lt)
    r.note("(g) bulk: %d entries in %d LW + %d LG logical messages (%d wire parts); duplicates %d"
           % (n, kinds.count("LW"), kinds.count("LG"), parts, len(dups)))
    assert not dups, "entries sent more than once: %d (e.g. %s)" % (len(dups), list(dups.items())[:3])
    w.assert_no_errors()


@r.case
def g_quick_double_reload_council_awards_still_reach_peer():
    """C2 /reloads twice within ~20s. C1 rate-limits its S/M replies to C2's HELLO (20s per sender), so C2's
    new session never marks C1 as an online council peer and SendToCouncil() skips it: awards C2 records in that
    session must still reach C1."""
    w, R, C1, C2 = setup(c2_online=True)
    C2.relog()
    gap = quick_double_reload(w, C2)
    settle(w, 20)
    r.note("double reload: HELLOs %.1fs apart" % gap)
    peers = C2.eval_py("return ns.Sync:GetOnlineCouncilPeers()") or []
    e = C2.eval_py("return ns.Ledger:Award(...)", ITEM_A, RK, "", "after double reload")
    settle(w, 10)
    assert e["id"] in ledger_ids(C1), ("award recorded by C2 after a quick double /reload did not reach online "
                                       "council member C1 (C2's council peers: %s)" % peers)
    w.assert_no_errors()


@r.case
def g_alt_in_other_guild_does_not_leak_ledger():
    """DisasterZoneDB is account-wide. An officer of guild A logs an alt that is council (GM) in guild B: guild A's
    award ledger must not be offered to guild B's council through HELLO/MANIFEST digests (and vice versa)."""
    w = new_world()
    MAIN = Client(w, "Mainofficer", class_file="PRIEST", guild_rank=1)
    RA = Client(w, "Raidera", class_file="PALADIN", guild_rank=3)
    ALT = Client(w, "Altgm", class_file="MAGE", guild="Other Guild", guild_rank=0, online=False)
    BC = Client(w, "Bofficer", class_file="WARRIOR", guild="Other Guild", guild_rank=1)
    seed_guild_council(w, ["Bofficer"], guild="Other Guild", by="Altgm")   # guild B: GM Altgm picked Bofficer
    for c in (MAIN, RA, BC):
        up(c)
    settle(w, 30)
    e = MAIN.eval_py("return ns.Ledger:Award(...)", ITEM_A, RA.full_name, "", "guild A award")
    settle(w, 3)
    MAIN.logout()
    settle(w, 2)
    w.saved[ALT.full_name] = dict(w.saved[MAIN.full_name])   # shim: account-wide SavedVariables
    ALT.login()
    settle(w, 60)
    # the digest exchange really runs between the two council members of guild B (not a vacuous pass)
    assert is_council(ALT) and is_council(ALT, BC.full_name) and is_council(BC, ALT.full_name), "guild B council"
    leaked =[i for i in ledger_ids(BC) if i == e["id"]]
    b_entries = ledger_raw(BC)
    assert not leaked, ("guild A's award %s (winner %s, not in guild B) was synced to guild B's council via the "
                        "alt's account-wide ledger: %s" % (e["id"], RA.full_name, list(b_entries)))
    w.assert_no_errors()


@r.case
def g_both_council_record_same_loot_line():
    """Both council members in the raid see the same 'X receives loot' line (at the same second, and one second
    apart): the ledger ends up identical and shows ONE award on both."""
    w, R, C1, C2 = setup(c2_online=True)
    w.make_raid([R, C1, C2], master_looter=C1, leader=C1)   # the raider leading would be council (E §29)
    w.enter_instance("Karazhan", 532)
    w.encounter(652, "Attumen the Huntsman")
    w.broadcast_loot_received(R, ITEM_A)                         # same second on both
    settle(w, 3)
    w.broadcast_loot_received(R, ITEM_B, clients=[C1, R])        # C2 sees it ~1s later
    w.tick(1.0)
    w.broadcast_loot_received(R, ITEM_B, clients=[C2])
    settle(w, 5)
    # DisasterZone 0.5: the auto entries are broadcast after a random delay and a later one never cancels an earlier one,
    # so both clients show the same (earliest) entry right away; the raw sets match after the next digest sync.
    v1, v2 = ledger_view(C1, False), ledger_view(C2, False)
    assert v1 == v2, (v1, v2)
    C2.slash("/dz sync")
    settle(w, 30)
    assert ledger_ids(C1) == ledger_ids(C2), (ledger_ids(C1), ledger_ids(C2))
    assert len(v1) == 2, "expected one visible award per item, got %s (raw %s)" % (v1, ledger_ids(C1))
    assert C1.eval("return ns.Ledger:CountSince(...)", RK, 0) == 2
    w.assert_no_errors()


if __name__ == "__main__":
    r.run()

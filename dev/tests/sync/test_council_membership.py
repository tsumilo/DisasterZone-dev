#!/usr/bin/env python
"""(e) Council membership changes while everyone is online (Addendum E §29/§31: the Guild Master picks the guild
council list, CG on GUILD; SPEC §10.3 gates). The GM ("Guildboss", rank 0) is online and council implicitly.

Run:  luaenv\\Scripts\\python.exe tests\\sync\\test_council_membership.py   [-k substring]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (Runner, Client, new_world, up, settle, key, edit, own, cached, cached_rev, online_council_peers,  # noqa: E402
                    is_council, traffic, fmt_traffic, logical_messages, ledger_ids, gm_pick)

r = Runner("council membership")
RK, R2K, C1K, C2K, GMK = key("Raider"), key("Raiderb"), key("Councila"), key("Councilb"), key("Guildboss")


def setup():
    """The GM is online and picks Councila + Councilb (CG on GUILD) once everyone is up."""
    w = new_world(council=None)
    R = Client(w, "Raider", class_file="PALADIN", guild_rank=3)
    R2 = Client(w, "Raiderb", class_file="WARRIOR", guild_rank=3)
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1)
    C2 = Client(w, "Councilb", class_file="MAGE", guild_rank=1)
    GM = Client(w, "Guildboss", class_file="PALADIN", guild_rank=0)
    w.add_offline_member("Oldguy", "ROGUE", 3)
    for c in (R, R2, C1, C2, GM):
        up(c)
    settle(w, 3)
    gm_pick(w, GM, ["Councila", "Councilb"])
    settle(w, 27)
    for c in (R, R2, C1, C2):
        assert is_council(c, C1K) and is_council(c, C2K) and is_council(c, GMK), c
        assert not is_council(c, RK) and not is_council(c, R2K), c
    return w, R, R2, C1, C2, GM


def send_as(c, msg, dist, target=None, cls="ctrl"):
    return c.eval("local m, d, t, cl = ... return ns.Comm:Send(m, d, t, cl)", msg, dist, target, cls)


def state_of(c):
    return c.eval_py("""
      local lists = {}
      for k, v in pairs(ns.db.lists) do lists[k] = { v.rev, v.hash } end
      local led = {}
      for id, e in pairs(ns.db.ledger) do led[id] = tostring(e.vd) .. ":" .. tostring(e.vts) end
      local rec = ns.BiS:GetRecord()
      return { lists = lists, ledger = led, rev = rec.rev, hsr = rec.highestSeenRev, hash = rec.hash }""")


@r.case
def e_promoted_member_gets_all_data():
    w, R, R2, C1, C2, GM = setup()
    edit(R, 0, commit=True)
    edit(C1, 0, commit=True)
    C1.eval("ns.Ledger:Award(...)", 28586, RK, "", "")
    settle(w, 60)                                    # well past everyone's login HELLO rate limit (30s)
    assert not is_council(R2)
    assert cached(R2, RK) is None
    mark = len(w.addon_log)
    gm_pick(w, GM, ["Councila", "Councilb", "Raiderb"], tick=0)
    settle(w, 1)
    assert is_council(R2), "the GM's pick did not make Raiderb council"
    assert is_council(R, R2K) and is_council(C1, R2K), "other clients do not see Raiderb as council"
    settle(w, 40)
    assert cached_rev(R2, RK) == own(R)["rev"] == 1, "promoted member lacks the raider's list"
    assert cached_rev(R2, C1K) == own(C1)["rev"] == 1, "promoted member lacks the council member's list"
    assert ledger_ids(R2) == ledger_ids(C1) and len(ledger_ids(R2)) == 1, (ledger_ids(R2), ledger_ids(C1))
    assert R2K in online_council_peers(R), online_council_peers(R)
    # the next edit is pushed to the new council member as well
    edit(R, 1, commit=True)
    settle(w, 5)
    assert cached_rev(R2, RK) == 2
    r.note("(e) promotion traffic: " + fmt_traffic(traffic(w, mark)))
    w.assert_no_errors()


@r.case
def e_promoted_right_after_login_hello():
    """Promotion within 30s of the member's automatic login HELLO: SendHello is rate limited (30s) and the
    promotion HELLO is dropped silently. The member must still get the data within a reasonable time."""
    w = new_world(council=None)
    R = Client(w, "Raider", class_file="PALADIN", guild_rank=3)
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1)
    GM = Client(w, "Guildboss", class_file="PALADIN", guild_rank=0)
    R2 = Client(w, "Raiderb", class_file="WARRIOR", guild_rank=3, online=False)
    for c in (R, C1, GM):
        up(c)
    settle(w, 3)
    gm_pick(w, GM, ["Councila"])
    settle(w, 27)
    edit(R, 0, commit=True)
    settle(w, 10)
    R2.login()
    hello_at = None
    for _ in range(400):                             # wait for R2's automatic login HELLO
        w.tick(0.1)
        hs = [m for m in logical_messages(w) if m["t"] == "H" and m["sender"] == R2K]
        if hs:
            hello_at = hs[0]["time"]
            break
    assert hello_at is not None, "R2 never sent its login HELLO"
    w.tick(2)
    gm_pick(w, GM, ["Councila", "Raiderb"], tick=0)
    try:
        took = w.run_until(lambda: cached_rev(R2, RK) == 1, timeout=120, step=0.5)
    except TimeoutError:
        took = None
    hs = [m for m in logical_messages(w) if m["t"] == "H" and m["sender"] == R2K]
    r.note("(e) promotion 2s after the login HELLO: data after %s s; HELLOs from R2 at %s"
           % (took, [m["time"] for m in hs]))
    assert took is not None and took <= 60, \
        "promoted council member got no lists for %s s (its promotion HELLO was rate limited)" % (
            "120+" if took is None else "%.0f" % took)
    w.assert_no_errors()


@r.case
def e_removed_member_stops_getting_pushes_and_is_ignored():
    w, R, R2, C1, C2, GM = setup()
    edit(R, 0, commit=True)
    C1.eval("ns.Ledger:Award(...)", 28586, RK, "", "")
    settle(w, 20)
    assert cached_rev(C2, RK) == 1 and len(ledger_ids(C2)) == 1
    gm_pick(w, GM, ["Councila"], tick=0)          # the GM removes Councilb from the list
    settle(w, 2)
    assert not is_council(C2), "C2 still thinks it is council"
    assert not is_council(R, C2K) and not is_council(C1, C2K)
    assert C2K not in online_council_peers(R), online_council_peers(R)
    assert C2.eval_py("return ns.Store:GetAllKeys()") == [C2K], "non-council still sees other lists"

    # 1) no pushes / awards to C2 any more
    mark = len(w.addon_log)
    edit(R, 1, commit=True)
    C1.eval("ns.Ledger:Award(...)", 28587, RK, "", "")
    settle(w, 20)
    to_c2 = [m for m in logical_messages(w, mark) if (m["target"] or "").split("-")[0] == "Councilb"]
    assert not [m for m in to_c2 if m["t"] in ("L", "R", "A", "LG", "M")], \
        "removed council member still receives: %s" % [(m["sender"], m["t"]) for m in to_c2]
    assert cached_rev(C2, RK) == 1, "removed member's cache still updated"

    # 2) what C2 sends is rejected everywhere
    before = {c.full_name: state_of(c) for c in (R, R2, C1, GM)}
    rec = R.eval_py("local r = ns.BiS:GetRecord() return { r = r.rev, ts = r.ts, h = r.hash, d = r.data }")
    forged = dict(rec)
    forged["r"] = 50
    forged["o"] = RK
    send_as(C2, {"t": "R", "e": [forged]}, "WHISPER", C1K, "data")           # relay to council
    send_as(C2, {"t": "R", "e": [forged]}, "WHISPER", RK, "data")            # relay of R's own list to R
    send_as(C2, {"t": "S", "r": 77}, "WHISPER", RK)                           # "I have rev 77 of your list"
    send_as(C2, {"t": "M", "m": {RK: 60, R2K: 5}, "ld": {}}, "WHISPER", C1K)  # manifest
    send_as(C2, {"t": "W", "n": [RK, R2K]}, "WHISPER", C1K)                   # want others' lists
    send_as(C2, {"t": "W", "n": [RK]}, "WHISPER", RK)                         # want R's own list from R
    award = {"id": "m1790000100Councilb28588", "i": 28588, "w": RK, "b": "", "ts": 1790000100, "by": C2K, "s": "m"}
    send_as(C2, {"t": "A", "e": award}, "WHISPER", C1K)
    send_as(C2, {"t": "LG", "e": [award]}, "WHISPER", C1K, "data")
    send_as(C2, {"t": "LW", "d": [20717, 20716]}, "WHISPER", C1K)
    # it also cannot put itself back on the list: a relayed CG naming it (by = the GM, newer rev) is dropped
    send_as(C2, {"t": "CG", "rev": C1.eval("return ns.Guild:GetGuildCouncilRev()") + 5,
                 "m": [C1K, C2K], "ph": 1, "by": GMK}, "GUILD")
    mark = len(w.addon_log)
    settle(w, 20)
    after = {c.full_name: state_of(c) for c in (R, R2, C1, GM)}
    for k in before:
        assert before[k] == after[k], "state of %s changed after messages from the removed member:\n%s\n%s" % (
            k, before[k], after[k])
    for c in (R, R2, C1, GM):
        assert not is_council(c, C2K), "%s: the removed member's relayed CG was accepted" % c.full_name
    replies = [m for m in logical_messages(w, mark) if (m["target"] or "").split("-")[0] == "Councilb"]
    assert not replies, "someone answered the removed member: %s" % [(m["sender"], m["t"]) for m in replies]
    assert R.popups() == [], R.popups()
    w.assert_no_errors()


@r.case
def e_removed_then_picked_again_while_online():
    """Guild ranks no longer matter (only the GM is council by rank): a demotion keeps the list membership, an
    officer who is not on the list is not council. Removing a member from the list stops the traffic to it;
    picking it again makes it catch up."""
    w, R, R2, C1, C2, GM = setup()
    edit(R, 0, commit=True)
    settle(w, 10)
    assert cached_rev(C2, RK) == 1
    C2.guild_rank = 3                                # officer -> raider: still on the GM's list
    R2.guild_rank = 1                                # raider -> officer: not on the list
    w._sync(roster_changed=True)
    settle(w, 2)
    assert is_council(C2) and is_council(R, C2K), "a rank change must not remove a listed council member"
    assert not is_council(R2) and not is_council(C1, R2K), "an officer is council only when picked"
    gm_pick(w, GM, ["Councila"], tick=0)          # removed from the list
    settle(w, 2)
    assert not is_council(C2) and not is_council(R, C2K)
    mark = len(w.addon_log)
    edit(R, 1, commit=True)
    settle(w, 10)
    to_c2 = [m for m in logical_messages(w, mark) if (m["target"] or "").split("-")[0] == "Councilb"]
    assert not to_c2, [(m["sender"], m["t"]) for m in to_c2]
    assert cached_rev(C1, RK) == 2
    # picked again: gets the new rev
    gm_pick(w, GM, ["Councila", "Councilb"], tick=0)
    settle(w, 40)
    assert is_council(C2)
    assert cached_rev(C2, RK) == 2, "re-picked member did not catch up"
    w.assert_no_errors()


if __name__ == "__main__":
    r.run()

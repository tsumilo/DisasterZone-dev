#!/usr/bin/env python
"""CDLoot guild sync flows on the REAL addon (SPEC §10.3): scenarios (a), (b), (c), (c2), (d) and (j).

Run:  luaenv\\Scripts\\python.exe tests\\sync\\test_sync_flows.py   [-k substring]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (login_with_slow_roster, quick_double_reload, Runner, Client, new_world, up, settle, key, edit, own, cached, cached_rev, online_council_peers,  # noqa: E402
                    status_text, traffic, fmt_traffic, logical_messages, wipe_saved, restore_saved, printed, candidates,
                    seed_guild_council)

r = Runner("sync flows")
RK, C1K, C2K = key("Raider"), key("Councila"), key("Councilb")


def trio(c2_online=False, c1_online=True, r_online=True, extra_offline=True):
    w = new_world()
    R = Client(w, "Raider", class_file="PALADIN", guild_rank=3, online=r_online)
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1, online=c1_online)
    C2 = Client(w, "Councilb", class_file="MAGE", guild_rank=0, online=c2_online)
    if extra_offline:
        w.add_offline_member("Oldguy", "ROGUE", 3)
        w.add_offline_member("Altoholic", "HUNTER", 4)
        w.add_offline_member("Officerx", "WARLOCK", 1)   # offline council member
    for c in (R, C1, C2):
        if c.online:
            up(c)
    return w, R, C1, C2


def assert_same_list(council, owner, owner_key, rev=None):
    o = own(owner)
    c = cached(council, owner_key)
    assert c is not None, "%s has no copy of %s (owner at rev %s)" % (council.full_name, owner_key, o["rev"])
    assert c["hash"] == o["hash"] == c["live"] == o["live"], "hash differs: council %s owner %s" % (c, o)
    assert c["rev"] == o["rev"], "rev differs: council %s owner %s" % (c, o)
    if rev is not None:
        assert o["rev"] == rev, "owner rev %s, expected %s" % (o["rev"], rev)
    return c


# ------------------------------------------------------------------------------------------------------------------
# (a) R edits while C1 is online: C1 gets it; C2 logs in later and catches up.
# ------------------------------------------------------------------------------------------------------------------
@r.case
def a_edit_reaches_online_council_and_late_council_catches_up():
    w, R, C1, C2 = trio()
    settle(w, 30)
    assert online_council_peers(R) == [C1K], online_council_peers(R)
    assert "no council member online" not in status_text(R)

    mark = len(w.addon_log)
    edit(R, 0)
    settle(w, 12)                                    # 8s commit debounce + push
    assert_same_list(C1, R, RK, rev=1)
    t = traffic(w, mark)
    assert t["by_type"] == {"L": 1}, "one edit should cost exactly one L push: " + fmt_traffic(t)
    assert "Shared with council" in status_text(R), status_text(R)

    edit(R, 1)
    edit(R, 2, sid=5)                                # two edits inside one debounce window -> one rev
    settle(w, 12)
    assert_same_list(C1, R, RK, rev=2)

    mark = len(w.addon_log)
    C2.login()
    settle(w, 45)
    c2 = assert_same_list(C2, R, RK, rev=2)
    assert RK in (C2.eval_py("return ns.Store:GetAllKeys()") or []), "C2 council view does not list the raider"
    t = traffic(w, mark)
    # C2's login needs: its HELLO, S from C1, S from... (R is not council), M from C1, and R's list once.
    assert t["by_type"].get("L", 0) + t["by_type"].get("R", 0) >= 1, fmt_traffic(t)
    assert t["by_type"].get("W", 0) <= 1, "WANT storm on C2 login: " + fmt_traffic(t)
    assert t["by_type"].get("L", 0) <= 1, "R pushed its list more than once to C2: " + fmt_traffic(t)
    r.note("(a) C2 catch-up traffic: %s; C2 copy via %s" % (fmt_traffic(t), c2["via"]))
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# (b) R edits with no council online; C1 logs in while R is offline; R comes back; C2 logs in (relay from C1).
# ------------------------------------------------------------------------------------------------------------------
@r.case
def b_offline_council_then_relay_via_c1():
    w, R, C1, C2 = trio(c1_online=False, c2_online=False)
    settle(w, 30)
    edit(R, 0)
    settle(w, 12)
    o = own(R)
    assert o["rev"] == 1, o
    assert "no council member online" in status_text(R), status_text(R)
    assert not [m for m in logical_messages(w) if m["t"] == "L"], "a list was sent although no council was online"
    R.logout()
    settle(w, 2)

    C1.login()
    settle(w, 30)
    assert cached(C1, RK) is None

    R.login()
    settle(w, 40)
    assert_same_list(C1, R, RK, rev=1)
    assert cached(C1, RK)["via"] == "direct"
    assert "Shared with council" in status_text(R), status_text(R)
    R.logout()
    settle(w, 2)

    mark = len(w.addon_log)
    C2.login()
    settle(w, 40)
    c = cached(C2, RK)
    assert c is not None, "C2 did not get the raider's list relayed from C1"
    assert c["rev"] == 1 and c["hash"] == o["hash"] == c["live"], c
    assert c["via"] == C1K, "expected relay via C1, got via=%s" % c["via"]
    t = traffic(w, mark)
    assert t["by_type"].get("W", 0) == 1 and t["by_type"].get("R", 0) == 1, fmt_traffic(t)
    r.note("(b) relay traffic: " + fmt_traffic(t))
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# (c) R reinstalls (SavedVariables wiped) while the council holds rev N -> automatic restore, identical hash,
#     next edit is N+1 everywhere.
# ------------------------------------------------------------------------------------------------------------------
@r.case
def c_reinstall_restores_automatically():
    w, R, C1, C2 = trio(c2_online=True)
    settle(w, 30)
    # R wears a few things so the synced data includes eq/ob (they are re-derived after the restore)
    head = candidates(R, 1, 3)
    R.equip({1: head[0]})
    for i in range(3):
        edit(R, i, commit=True)
        settle(w, 3)
    settle(w, 12)
    o = own(R)
    assert o["rev"] >= 3, o
    n = o["rev"]
    assert_same_list(C1, R, RK, rev=n)
    assert_same_list(C2, R, RK, rev=n)
    council_hash = cached(C1, RK)["hash"]

    R.logout()
    wipe_saved(w, R)
    settle(w, 2)
    R.login()
    R.equip({1: head[0]})                            # same gear as before the reinstall
    settle(w, 45)
    o2 = own(R)
    assert o2["rev"] == n, "restore did not happen: own %s, council rev %d" % (o2, n)
    assert o2["hash"] == council_hash == o2["live"], "restored list differs: %s vs %s" % (o2, council_hash)
    assert R.popups() == [], "reinstall should restore silently, popups: %s" % R.popups()
    assert any("Restored your BiS list" in p for p in printed(R)), printed(R)[-5:]

    edit(R, 3, sid=5)
    settle(w, 15)
    assert_same_list(C1, R, RK, rev=n + 1)
    assert_same_list(C2, R, RK, rev=n + 1)
    w.assert_no_errors()


@r.case
def c_reinstall_restores_from_newest_council_copy():
    """Two council members hold different revs (C2 missed the last push): the reinstalled client must restore
    the NEWEST copy (Sync collects offers for 3s)."""
    w, R, C1, C2 = trio(c2_online=True)
    settle(w, 30)
    edit(R, 0, commit=True)
    settle(w, 5)
    C2.logout()
    settle(w, 2)
    edit(R, 1, commit=True)
    settle(w, 5)
    edit(R, 2, sid=5, commit=True)
    settle(w, 5)
    assert cached(C1, RK)["rev"] == 3
    R.logout()
    C2.login()
    settle(w, 30)
    assert cached(C2, RK)["rev"] in (1, 3)           # C2 may already have caught up from C1 (relay); both OK
    wipe_saved(w, R)
    R.login()
    settle(w, 45)
    o = own(R)
    assert o["rev"] == 3 and o["hash"] == cached(C1, RK)["hash"], (o, cached(C1, RK))
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# (c2) R has local data OLDER than the council's copy -> popup; "Restore" and "Keep mine".
# ------------------------------------------------------------------------------------------------------------------
def c2_setup():
    w, R, C1, C2 = trio(c2_online=True)
    settle(w, 30)
    edit(R, 0, commit=True)
    settle(w, 5)
    old_sv = R.saved_variables()                     # SavedVariables as they were at rev 1 (other PC)
    old = own(R)
    edit(R, 1, commit=True)
    settle(w, 5)
    edit(R, 2, sid=5, commit=True)
    settle(w, 10)
    new = own(R)
    assert new["rev"] == 3 and cached(C1, RK)["rev"] == 3 and cached(C2, RK)["rev"] == 3
    R.logout()
    restore_saved(w, R, old_sv)
    settle(w, 2)
    R.login()
    settle(w, 35)
    assert own(R)["rev"] == 1, own(R)
    return w, R, C1, C2, old, new


@r.case
def c2_older_local_copy_popup_restore():
    w, R, C1, C2, old, new = c2_setup()
    pops = R.popups()
    assert pops == ["CDLOOT_RESTORE"], "expected the restore popup once, got %s" % pops
    R.accept_popup("CDLOOT_RESTORE")
    settle(w, 10)
    o = own(R)
    assert o["rev"] == 3 and o["hash"] == new["hash"], "restore failed: %s (wanted %s)" % (o, new)
    assert_same_list(C1, R, RK, rev=3)
    assert_same_list(C2, R, RK, rev=3)
    settle(w, 40)
    assert R.popups() == [], "popup came back: %s" % R.popups()
    assert own(R)["rev"] == 3, "a restore must not create a new rev: %s" % own(R)
    w.assert_no_errors()


@r.case
def c2_older_local_copy_popup_keep_mine():
    w, R, C1, C2, old, new = c2_setup()
    assert R.popups() == ["CDLOOT_RESTORE"], R.popups()
    R.cancel_popup("CDLOOT_RESTORE")
    settle(w, 10)
    o = own(R)
    assert o["rev"] == 4, "keep mine must supersede the council's rev 3 with rev 4: %s" % o
    assert o["hash"] == old["hash"], "keep mine changed the local data: %s vs %s" % (o, old)
    assert_same_list(C1, R, RK, rev=4)
    assert_same_list(C2, R, RK, rev=4)
    settle(w, 40)
    assert R.popups() == [], R.popups()
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# (d) login race: 6 clients log in within 1 second.
# ------------------------------------------------------------------------------------------------------------------
@r.case
def d_login_race_six_clients_within_one_second():
    w = new_world()
    names = ["Raidera", "Raiderb", "Raiderc", "Raiderd"]
    classes = ["PALADIN", "WARRIOR", "DRUID", "HUNTER"]
    raiders = [Client(w, n, class_file=cl, guild_rank=3) for n, cl in zip(names, classes)]
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1)
    C2 = Client(w, "Councilb", class_file="MAGE", guild_rank=1, online=False)
    w.add_offline_member("Oldguy", "ROGUE", 3)
    for c in raiders + [C1]:
        up(c)
    settle(w, 30)
    for i, c in enumerate(raiders):
        edit(c, i % 3, commit=True)
    settle(w, 15)
    for c in raiders:
        assert cached_rev(C1, c.full_name) == 1
    C1.logout()
    settle(w, 2)
    # Raiderc edits while no council is online: only its own SavedVariables have rev 2
    edit(raiders[2], 1, sid=5, commit=True)
    settle(w, 5)
    for c in raiders:
        c.logout()
    settle(w, 5)

    mark = len(w.addon_log)
    everyone = raiders + [C1, C2]
    for i, c in enumerate(everyone):                 # 6 logins within 1 second
        c.login()
        w.tick(0.15, 0.05)
    t0 = w.now

    def converged():
        for coun in (C1, C2):
            for c in raiders:
                o = own(c)
                cc = cached(coun, c.full_name)
                if not cc or cc["rev"] != o["rev"] or cc["hash"] != o["hash"]:
                    return False
        return True

    try:
        took = w.run_until(converged, timeout=90, step=0.25)
    except TimeoutError:
        took = None
    t = traffic(w, mark)
    assert took is not None, "no convergence within 90s: " + fmt_traffic(t)
    settle(w, 30)
    t = traffic(w, mark)
    r.note("(d) 6-client login race: converged after %.1f s; whole wave: %s" % (took, fmt_traffic(t)))
    # duplicate pushes of the same rev to the same council member?
    pushes = {}
    for m in t["msgs"]:
        if m["t"] == "L":
            k = (m["sender"], m["target"], m["msg"].get("r"))
            pushes[k] = pushes.get(k, 0) + 1
    dup = {k: v for k, v in pushes.items() if v > 1}
    assert not dup, "same rev pushed twice to the same council member: %s" % dup
    wants = [m for m in t["msgs"] if m["t"] == "W"]
    assert len(wants) <= 4, "too many WANTs for 6 clients: %d (%s)" % (len(wants), fmt_traffic(t))
    assert own(raiders[2])["rev"] == 2
    w.assert_no_errors()


@r.case
def d_login_race_with_late_guild_roster():
    """Clients whose guild roster arrives late (15 s) must hold early addon messages and still converge."""
    w = new_world()
    R = Client(w, "Raider", guild_rank=3)
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1)
    up(R); up(C1)
    settle(w, 30)
    edit(R, 0, commit=True)
    settle(w, 10)
    R.logout(); C1.logout()
    C2 = Client(w, "Councilb", class_file="MAGE", guild_rank=1, online=False)
    settle(w, 3)
    R.login()
    w.tick(0.3)
    login_with_slow_roster(w, C1, 15)                # shim: only C1/C2 get a slow roster
    w.tick(0.3)
    login_with_slow_roster(w, C2, 15)
    w.tick(10)
    assert not C1.eval("return ns.Guild:IsReady()"), "slow-roster shim not effective"
    settle(w, 70)
    assert_same_list(C1, R, RK, rev=1)
    assert_same_list(C2, R, RK, rev=1)
    for c in (R, C1, C2):
        held = c.eval("return ns.Comm:GetHeldCount()")
        assert held == 0, "%s still holds %s messages" % (c.full_name, held)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# (j) relog persistence and pruning of members who left the guild
# ------------------------------------------------------------------------------------------------------------------
@r.case
def j_relog_keeps_lists_ledger_peers():
    w, R, C1, C2 = trio(c2_online=True)
    settle(w, 30)
    edit(R, 0, commit=True)
    settle(w, 10)
    C1.eval("ns.Ledger:Award(...)", 28586, RK, "", "test award")
    settle(w, 5)
    before_c1 = cached(C1, RK)
    before_led = sorted(C1.eval_py("local t = {} for id in pairs(ns.db.ledger) do t[#t+1] = id end return t"))
    assert len(before_led) == 1
    before_peers = C1.eval_py("return ns.db.peers")
    assert RK in before_peers and C2K in before_peers, before_peers

    C1.relog()
    R.relog()
    w.tick(0.2)
    after_c1 = cached(C1, RK)
    assert after_c1 == before_c1, "cached list changed over /reload: %s vs %s" % (before_c1, after_c1)
    after_led = sorted(C1.eval_py("local t = {} for id in pairs(ns.db.ledger) do t[#t+1] = id end return t"))
    assert after_led == before_led, (before_led, after_led)
    peers = C1.eval_py("return ns.db.peers")
    assert RK in peers and C2K in peers and peers[RK].get("v"), peers
    assert own(R)["rev"] == 1
    vers = C1.eval_py("local out = {} for _, e in ipairs(ns.Sync:GetVersions()) do out[#out+1] = e.key end return out")
    assert RK in vers, vers
    settle(w, 40)
    assert cached(C1, RK) == before_c1
    w.assert_no_errors()


@r.case
def j_shared_status_survives_reload():
    """R's 'Shared with council' marker is persisted in ns.db.peers[me] (sharedRev/sharedTs) and restored by
    Sync:OnLogin, so right after a /reload the status must still say 'Shared with council'."""
    w, R, C1, C2 = trio()
    settle(w, 30)
    edit(R, 0, commit=True)
    settle(w, 10)
    assert "Shared with council" in status_text(R)
    me_peer = R.eval_py("return ns.db.peers[ns.Util.PlayerKey()]")
    assert me_peer and me_peer.get("sharedRev") == 1, me_peer
    R.relog()
    w.tick(1.0)                                      # before any HELLO/STATE traffic of the new session
    me_peer2 = R.eval_py("return ns.db.peers[ns.Util.PlayerKey()]")
    st = status_text(R)
    assert me_peer2 and me_peer2.get("sharedRev") == 1, \
        "own shared marker was dropped at login (ns.db.peers[me] = %s), status now %r" % (me_peer2, st)
    assert "Shared with council" in st, st
    w.assert_no_errors()


@r.case
def j_prune_members_who_left_the_guild():
    w = new_world()
    R = Client(w, "Raider", guild_rank=3)
    L = Client(w, "Leaver", class_file="ROGUE", guild_rank=3)
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1)
    for c in (R, L, C1):
        up(c)
    settle(w, 30)
    edit(R, 0, commit=True)
    edit(L, 0, commit=True)
    settle(w, 10)
    LK = L.full_name
    assert cached_rev(C1, LK) == 1 and cached_rev(C1, RK) == 1
    L.logout()
    L.guild = None                                   # /gquit: gone from the roster
    w._sync(roster_changed=True)
    settle(w, 3)
    keys = C1.eval_py("return ns.Store:GetAllKeys()") or []
    assert LK not in keys, "former member still in the council view: %s" % keys
    man = C1.eval_py("return ns.Store:GetManifest()") or {}
    assert LK not in man, "former member still advertised in the manifest: %s" % man
    rec = C1.eval_py("return ns.db.lists[...]", LK)
    assert rec and rec.get("missingSince"), "record should be kept (with missingSince) for 30 days: %s" % rec

    C1.relog()                                       # missingSince must survive a reload
    w.tick(2)
    rec2 = C1.eval_py("return ns.db.lists[...]", LK)
    assert rec2 and rec2.get("missingSince") == rec.get("missingSince"), (rec, rec2)

    # Pruning runs on ROSTER_UPDATED, i.e. when the roster actually changes (login of C1 / someone logging on).
    w.server_time0 += 29 * 86400                     # shim: jump the shared server clock
    C1.relog()
    settle(w, 2)
    assert C1.eval_py("return ns.db.lists[...]", LK) is not None, "pruned before 30 days"
    w.server_time0 += 2 * 86400
    R.logout()                                       # any real roster change triggers the prune
    settle(w, 2)
    assert C1.eval_py("return ns.db.lists[...]", LK) is None, "not pruned after 31 days"
    assert cached_rev(C1, RK) == 1, "a current member was pruned"
    w.assert_no_errors()


@r.case
def j_old_peers_forgotten_after_90_days():
    w, R, C1, C2 = trio()
    settle(w, 30)
    assert RK in (C1.eval_py("return ns.db.peers") or {})
    R.logout()
    settle(w, 2)
    C1.logout()
    w.server_time0 += 91 * 86400
    C1.login()
    w.tick(1)
    peers = C1.eval_py("return ns.db.peers") or {}
    assert RK not in peers, "peer not seen for 91 days is still stored: %s" % peers
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# more edge cases: quick double /reload, crash (no SavedVariables write), cross-realm member
# ------------------------------------------------------------------------------------------------------------------
def wait_for_hello(w, who_key, after):
    for _ in range(600):
        w.tick(0.1)
        hs = [m for m in logical_messages(w) if m["t"] == "H" and m["sender"] == who_key and m["time"] > after]
        if hs:
            return hs[0]["time"]
    raise AssertionError("no HELLO from %s" % who_key)


@r.case
def j_quick_double_reload_raider_still_shares():
    """R /reloads, and /reloads again a few seconds after its new HELLO went out. The council rate-limits its
    STATE reply per sender (20s), so the second session never learns that C1 is online; edits made in that
    session must still reach the council."""
    w, R, C1, C2 = trio()
    settle(w, 30)
    assert online_council_peers(R) == [C1K]
    R.relog()                                        # first /reload ...
    gap = quick_double_reload(w, R)                  # ... and a second one right after its HELLO
    settle(w, 20)
    r.note("double reload: HELLOs %.1fs apart" % gap)
    peers = online_council_peers(R)
    edit(R, 0, commit=True)
    settle(w, 15)
    st = status_text(R)
    c = cached(C1, RK)
    assert c is not None and c["rev"] == own(R)["rev"],         ("edit after a quick double /reload never reached the online council (R's council peers %s, status %r)"
         % (peers, st))
    w.assert_no_errors()


@r.case
def j_council_crash_recovers_unsaved_cache():
    """C1 receives R's rev 2 and then crashes (SavedVariables not written). After logging back in, C1 must get
    rev 2 again while R is online."""
    w, R, C1, C2 = trio()
    settle(w, 30)
    edit(R, 0, commit=True)
    settle(w, 5)
    C1.relog()                                       # clean save at rev 1
    settle(w, 40)
    edit(R, 1, commit=True)
    settle(w, 40)
    assert cached_rev(C1, RK) == 2
    C1._shutdown(save=False)                         # shim: client crash, no SavedVariables write
    C1.online = False
    w._sync(roster_changed=True)
    settle(w, 5)
    C1.login()
    w.tick(1)
    assert cached_rev(C1, RK) == 1, "crash shim did not lose the unsaved rev"
    settle(w, 45)
    assert_same_list(C1, R, RK, rev=2)
    w.assert_no_errors()


@r.case
def j_cross_realm_member_sync_and_restore():
    w = new_world()
    X = Client(w, "Crossy", realm="Other Realm", class_file="SHAMAN", guild_rank=3)
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1)
    C2 = Client(w, "Councilb", class_file="MAGE", guild_rank=1, online=False)
    up(X); up(C1)
    settle(w, 30)
    XK = X.full_name
    assert XK == "Crossy-OtherRealm", XK
    assert X.eval("return ns.Util.PlayerKey()") == XK
    edit(X, 0, commit=True)
    settle(w, 10)
    assert_same_list(C1, X, XK, rev=1)
    X.logout()
    C2.login()
    settle(w, 40)
    assert cached(C2, XK) and cached(C2, XK)["via"] == C1K, cached(C2, XK)
    wipe_saved(w, X)
    X.login()
    settle(w, 45)
    assert own(X)["rev"] == 1 and own(X)["hash"] == cached(C1, XK)["hash"], (own(X), cached(C1, XK))
    w.assert_no_errors()


@r.case
def a_edit_then_logout_before_commit_debounce():
    """R edits and logs out 2s later (before the 8s commit debounce): PLAYER_LOGOUT commits, and the change
    reaches the council at R's next login."""
    w, R, C1, C2 = trio()
    settle(w, 30)
    edit(R, 0)
    w.tick(2)
    R.logout()
    settle(w, 5)
    assert cached(C1, RK) is None
    R.login()
    settle(w, 45)
    assert_same_list(C1, R, RK, rev=1)
    w.assert_no_errors()


@r.case
def c3_same_rev_divergence_is_repaired():
    """Two machines: PC A pushes rev 2 (data X) to C1 while C2 is away; PC B still has rev 1 and, with only C2
    online, makes a different edit -> also rev 2 (data Y). Manifests and STATE carry revs only, so C1 (rev 2 X)
    and C2 (rev 2 Y) never notice they differ."""
    w, R, C1, C2 = trio(c2_online=True)
    settle(w, 30)
    edit(R, 0, commit=True)
    settle(w, 10)
    pc_b = R.saved_variables()                       # PC B's SavedVariables: rev 1
    C2.logout()
    settle(w, 2)
    edit(R, 1, commit=True)                          # PC A: rev 2 = X, only C1 gets it
    settle(w, 10)
    x = own(R)
    assert cached(C1, RK)["hash"] == x["hash"]
    R.logout(); C1.logout()
    settle(w, 2)
    restore_saved(w, R, pc_b)                        # now playing on PC B
    C2.login()
    R.login()
    settle(w, 40)
    assert own(R)["rev"] == 1 and R.popups() == []
    edit(R, 2, sid=5, commit=True)                   # PC B: rev 2 = Y
    settle(w, 10)
    y = own(R)
    assert y["rev"] == 2 and y["hash"] != x["hash"]
    assert cached(C2, RK)["hash"] == y["hash"]
    C1.login()
    settle(w, 60)
    c1, c2 = cached(C1, RK), cached(C2, RK)
    w.assert_no_errors()
    assert c1["hash"] == c2["hash"] == y["hash"],         ("council copies of the same rev %d differ and are never repaired: C1 %s (PC A data), C2 %s, owner %s"
         % (y["rev"], c1["hash"], c2["hash"], y["hash"]))


@r.case
def j_guildless_then_guild_change_while_online():
    """A guildless character stays silent; a character that leaves guild A and joins guild B while online
    shares with guild B's council only (no pushes to its old council)."""
    w = new_world()
    # guild B: its GM (offline) picked Bofficer, guild phase 2 (Addendum E §29/§32)
    w.add_offline_member("Bgm", "PALADIN", 0, guild="Other Guild")
    seed_guild_council(w, ["Bofficer"], phase=2, guild="Other Guild", by="Bgm")
    solo = Client(w, "Lonely", class_file="HUNTER", guild=None)
    R = Client(w, "Raider", class_file="PALADIN", guild_rank=3)
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1)
    BC = Client(w, "Bofficer", class_file="WARRIOR", guild="Other Guild", guild_rank=1)
    for c in (solo, R, C1, BC):
        up(c)
    settle(w, 30)
    edit(solo, 0, commit=True)
    solo.slash("/cdl sync")
    edit(R, 0, commit=True)
    settle(w, 10)
    assert not [e for e in w.addon_log if e["sender"] == solo.full_name], "a guildless client sent addon messages"
    assert "Not in a guild" in status_text(solo)
    assert cached_rev(C1, RK) == 1

    R.guild = None                                  # /gquit
    w._sync(roster_changed=True)
    R.fire("PLAYER_GUILD_UPDATE", "player")
    settle(w, 5)
    R.guild, R.guild_rank = "Other Guild", 3        # /ginvite by guild B
    w._sync(roster_changed=True)
    R.fire("PLAYER_GUILD_UPDATE", "player")
    settle(w, 40)
    assert R.eval("return ns.Guild:GetGuildName()") == "Other Guild"
    assert R.eval("return ns.Guild:GetGuildPhase()") == 2, "guild B's council list (phase 2) did not reach the new member"
    assert R.eval("return ns.Guild:IsCouncil(...)", key("Bofficer")) is True
    mark = len(w.addon_log)
    edit(R, 1, commit=True)
    settle(w, 15)
    assert cached_rev(BC, RK) == own(R)["rev"] == 2, "guild B's council did not get the list (%s)" % cached(BC, RK)
    to_old = [m for m in logical_messages(w, mark) if (m["target"] or "").split("-")[0] == "Councila"]
    assert not to_old, "list still sent to the old guild's council: %s" % [(m["sender"], m["t"]) for m in to_old]
    assert cached_rev(C1, RK) == 1
    w.assert_no_errors()


if __name__ == "__main__":
    r.run()

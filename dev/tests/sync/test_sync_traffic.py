#!/usr/bin/env python
"""(h) 40-member guild, server throttle ON: addon messages / bytes per login wave, time to convergence,
pathological traffic (message storms, repeated WANTs, ping-pong). Also runs world.report() at the end.

Run:  luaenv\\Scripts\\python.exe tests\\sync\\test_sync_traffic.py   [-k substring]
"""
import os
import random
import string
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (login_with_slow_roster, Runner, Client, new_world, up, settle, key, edit, own, cached, traffic, fmt_traffic,  # noqa: E402
                    logical_messages, throttled)

r = Runner("40-member guild traffic")
CLASSES = ["PALADIN", "WARRIOR", "DRUID", "HUNTER", "ROGUE", "PRIEST", "MAGE", "WARLOCK", "SHAMAN"]


def names(n):
    out = []
    for a in string.ascii_lowercase:
        for b in string.ascii_lowercase:
            out.append("Rdr" + a + b)
            if len(out) == n:
                return out
    return out


def build(n_raiders=36, n_council=4):
    w = new_world()
    council = [Client(w, "Council" + "abcd"[i], class_file=CLASSES[(i + 5) % 9], guild_rank=0 if i == 0 else 1,
                      online=False) for i in range(n_council)]
    raiders = [Client(w, nm, class_file=CLASSES[i % 9], guild_rank=3, online=False)
               for i, nm in enumerate(names(n_raiders))]
    return w, council, raiders


def login_wave(w, clients, spread=1.0, order_seed=1):
    order = list(clients)
    random.Random(order_seed).shuffle(order)
    gap = spread / max(1, len(order))
    for c in order:
        c.login()
        w.tick(gap, gap)


def run_until_quiet(w, quiet=30.0, timeout=900.0, step=0.25):
    """Tick until no CDLoot addon message was sent for `quiet` seconds. Returns the time of the last message."""
    start = w.now
    while w.now - start < timeout:
        w.tick(step, step)
        last = max((e["time"] for e in w.addon_log if e["prefix"].startswith("CDL")), default=0)
        if w.now - max(last, start) >= quiet:
            return last
    raise TimeoutError("traffic did not settle within %ss" % timeout)


def converged(council, raiders):
    missing = []
    for c in council:
        for rd in raiders:
            o = own(rd)
            if o["rev"] == 0:
                continue
            cc = cached(c, rd.full_name)
            if not cc or cc["rev"] != o["rev"] or cc["hash"] != o["hash"]:
                missing.append((c.name, rd.name, o["rev"], cc and cc["rev"]))
    return missing


def pathologies(msgs):
    """Repeated identical WANTs, same rev pushed twice to the same council member, relays of already-held revs."""
    out = []
    wants = Counter()
    for m in msgs:
        if m["t"] == "W":
            for n in (m["msg"].get("n") or []):
                wants[(m["sender"], m["target"], n)] += 1
    rep = {k: v for k, v in wants.items() if v > 1}
    if rep:
        out.append("repeated WANT for the same list: %d (e.g. %s)" % (len(rep), list(rep.items())[:3]))
    pushes = Counter()
    for m in msgs:
        if m["t"] == "L":
            pushes[(m["sender"], m["target"], m["msg"].get("r"))] += 1
    dup = {k: v for k, v in pushes.items() if v > 1}
    if dup:
        out.append("same rev pushed twice: %d (e.g. %s)" % (len(dup), list(dup.items())[:3]))
    got = Counter()
    for m in msgs:
        if m["t"] == "L":
            got[(m["target"].split("-")[0], m["sender"].split("-")[0], m["msg"].get("r"))] += 1
        elif m["t"] == "R":
            for e in (m["msg"].get("e") or []):
                got[(m["target"].split("-")[0], str(e.get("o")).split("-")[0], e.get("r"))] += 1
    # By design a returning council member can get a changed list twice: the owner's direct push (after the
    # HELLO) races the relay pulled from another council member's MANIFEST. Three or more copies = pathology.
    thrice = {k: v for k, v in got.items() if v > 2}
    if thrice:
        out.append("a council member received the same list rev 3+ times: %d cases (e.g. %s)"
                   % (len(thrice), list(thrice.items())[:3]))
    return out


def double_deliveries(msgs):
    got = Counter()
    for m in msgs:
        if m["t"] == "L":
            got[(m["target"].split("-")[0], m["sender"].split("-")[0], m["msg"].get("r"))] += 1
        elif m["t"] == "R":
            for e in (m["msg"].get("e") or []):
                got[(m["target"].split("-")[0], str(e.get("o")).split("-")[0], e.get("r"))] += 1
    return sum(1 for v in got.values() if v == 2), len(got)


def per_sender(msgs):
    c = Counter()
    for m in msgs:
        c[m["sender"].split("-")[0]] += m["parts"]
    return c


@r.case
def h_forty_member_guild_login_waves():
    w, council, raiders = build()
    everyone = council + raiders
    report = []

    # Wave 1: first evening with the addon, nobody has a list yet; 40 logins over 10 s
    mark = len(w.addon_log)
    login_wave(w, everyone, spread=10.0)
    last = run_until_quiet(w)
    t1 = traffic(w, mark)
    report.append("wave 1 (fresh, 40 logins/10s): %s; quiet after %.0fs" % (fmt_traffic(t1), last - w.addon_log[mark]["time"]))

    # Everyone builds a list: edits spread over 60 s
    mark = len(w.addon_log)
    rng = random.Random(3)
    pending = sorted((rng.uniform(0, 60), i) for i in range(len(raiders)))
    t0 = w.now
    for at, i in pending:
        if w.now - t0 < at:
            w.tick(at - (w.now - t0), 0.25)
        edit(raiders[i], i % 3, commit=True)
    edit_done = w.now
    try:
        took = w.run_until(lambda: not converged(council, raiders), timeout=600, step=1.0)
    except TimeoutError:
        took = None
    run_until_quiet(w)
    te = traffic(w, mark)
    miss = converged(council, raiders)
    report.append("edit phase (36 first commits over 60s): %s; all 4 council converged %s s after the last edit"
                  % (fmt_traffic(te), "NEVER" if took is None else "%.0f" % took))
    assert not miss, "not converged after the edit phase: %s" % miss[:5]
    p_edit = pathologies(te["msgs"])

    # Wave 2: next evening, everything already in sync; all 40 log in within 1 s
    for c in everyone:
        c.logout()
    settle(w, 5)
    mark = len(w.addon_log)
    wave_start = w.now
    login_wave(w, everyone, spread=1.0, order_seed=2)
    last = run_until_quiet(w)
    t2 = traffic(w, mark)
    thr = sum(throttled(c) for c in everyone)
    ps = per_sender(t2["msgs"])
    report.append("wave 2 (in sync, 40 logins/1s): %s; last message %.0fs after the wave; server-throttled "
                  "sends (requeued by CTL): %d; busiest sender %s" % (fmt_traffic(t2), last - wave_start, thr,
                                                                       ps.most_common(2)))
    p2 = pathologies(t2["msgs"])
    assert not converged(council, raiders)
    unneeded = {k: v for k, v in t2["by_type"].items() if k in ("L", "W", "R", "LW", "LG")}

    # Wave 3: two council members were away while 12 raiders changed their lists
    for c in council[2:]:
        c.logout()
    settle(w, 3)
    for i in range(12):
        edit(raiders[i], 2 + (i % 2), sid=5, commit=True)
    settle(w, 20)
    mark = len(w.addon_log)
    login_wave(w, council[2:], spread=0.5)
    start3 = w.now
    try:
        took3 = w.run_until(lambda: not converged(council, raiders), timeout=600, step=1.0)
    except TimeoutError:
        took3 = None
    run_until_quiet(w)
    t3 = traffic(w, mark)
    report.append("wave 3 (2 council catch up on 12 changed lists): %s; converged after %s s"
                  % (fmt_traffic(t3), "NEVER" if took3 is None else "%.0f" % took3))
    p3 = pathologies(t3["msgs"])
    dd, total = double_deliveries(t3["msgs"])
    report.append("wave 3: %d of %d list transfers arrived twice (owner push + council relay race)" % (dd, total))

    for line in report:
        r.note("(h) " + line)
    for label, p in (("edit phase", p_edit), ("wave 2", p2), ("wave 3", p3)):
        for line in p:
            r.note("(h) PATHOLOGY %s: %s" % (label, line))
    big = max((m["bytes"] for m in t1["msgs"] + te["msgs"] + t2["msgs"] + t3["msgs"]), default=0)
    r.note("(h) largest logical message: %d bytes on the wire" % big)
    print(w.report())
    w.assert_no_errors()
    assert took3 is not None and took3 <= 90, "wave 3 did not converge within 90s: %s" % converged(council, raiders)[:5]
    assert took is not None and took <= 60, "edit phase did not converge within 60s of the last edit"
    assert not unneeded, "in-sync login wave still moved lists/ledger: %s" % unneeded
    assert t2["by_type"].get("H", 0) == 40, t2["by_type"]
    assert not p2 and not p3 and not p_edit, "pathological traffic: %s" % (p_edit + p2 + p3)


@r.case
def h_slow_roster_council_member_in_login_wave():
    """One council member's guild roster arrives 25 s after login while 39 others log in with it: every HELLO it
    receives meanwhile is held (Comm hold buffer, 40 messages). It must still answer everyone and pull every list."""
    w, council, raiders = build()
    everyone = council + raiders
    login_wave(w, everyone, spread=10.0)
    run_until_quiet(w)
    for i, rd in enumerate(raiders):
        edit(rd, i % 3, commit=True)
    run_until_quiet(w)
    assert not converged(council, raiders)
    for c in everyone:
        c.logout()
    settle(w, 5)
    slow = council[3]
    wipe = slow.full_name
    w.saved.pop(wipe, None)                           # slow member also lost its cache (fresh install)
    mark = len(w.addon_log)
    order = [slow] + [c for c in everyone if c is not slow]
    login_with_slow_roster(w, slow, 25)
    peak = 0
    for c in order[1:]:
        c.login()
        w.tick(0.025, 0.025)
    t0 = w.now
    while w.now - t0 < 30:
        w.tick(0.5, 0.5)
        peak = max(peak, slow.eval("return ns.Comm:GetHeldCount()") or 0)
    try:
        took = w.run_until(lambda: not converged([slow], raiders), timeout=300, step=1.0)
    except TimeoutError:
        took = None
    run_until_quiet(w)
    seen = slow.eval_py("local n = 0 for k, p in pairs(ns.db.peers) do n = n + 1 end return n")
    s_from_slow = [m for m in logical_messages(w, mark) if m["t"] == "S" and m["sender"] == slow.full_name]
    r.note("(h) slow-roster council member: held peak %d, lists complete after %s s, peers known %s, S replies sent %d"
           % (peak, took, seen, len(s_from_slow)))
    w.assert_no_errors()
    assert took is not None, "slow-roster council member never got all lists: %s" % converged([slow], raiders)[:5]
    assert len(s_from_slow) >= 39, "slow-roster council member answered only %d of 39 HELLOs" % len(s_from_slow)


if __name__ == "__main__":
    r.run()

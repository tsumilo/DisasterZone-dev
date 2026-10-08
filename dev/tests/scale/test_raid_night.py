"""A raid night at guild size: what the subsystems besides list sync cost with 60 members online.

  professions      60 members scan two professions each, a relog wave in sync, one fresh install catching up
  stale wave       an officer changes a strategy and a raid while 55 members are offline; they log in within a minute
  patch            an in-game update published to 60 members (run with: -k patch)

Every case prints its numbers (messages, bytes, server-throttled sends, time to convergence) and asserts only the
outcome: everyone ends up with the data and no Lua error. Size with DZ_SCALE_N (default 60).

Run: luaenv\\Scripts\\python.exe tests\\scale\\test_raid_night.py [-k name]
"""
import os
import random
import sys
import time
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
for sub in ("sync", "members", "strategy", "raidplan", "games", "patch", "boot-ui"):
    sys.path.insert(0, os.path.join(TESTS, sub))

import common as sync_common  # noqa: E402
from _common import case, run_all, World, Client, gm_pick  # noqa: E402
from mb_common import set_skills, open_tradeskill, K  # noqa: E402
from st_common import save_council  # noqa: E402
from rp_common import create, set_raid_leaders, now, DAY  # noqa: E402

N = int(os.environ.get("DZ_SCALE_N", "60"))
CLASSES = ["PALADIN", "WARRIOR", "DRUID", "HUNTER", "ROGUE", "PRIEST", "MAGE", "WARLOCK", "SHAMAN"]
PROFS = ["Alchemy", "Tailoring", "Blacksmithing", "Leatherworking", "Engineering", "Jewelcrafting"]
ALL_PREFIXES = ("CDLc", "CDLd", "CDLa", "CDLg", "CDLm", "CDLl")
sync_common.CDL_PREFIXES = ALL_PREFIXES   # decode every DisasterZone prefix, not only the council ones


def names(n):
    return ["Rdr" + chr(97 + i // 26) + chr(97 + i % 26) for i in range(n)]


def guild(n=N, council=3):
    """GM + `council` guild council members (also raid leaders) + raiders, all offline. Returns w, gm, officers, all."""
    w = World()
    gm = Client(w, "Gina", guild_rank=0, class_file="PALADIN", online=False)
    officers = [Client(w, "Officer" + "abcdefgh"[i], guild_rank=1, class_file=CLASSES[i + 1], online=False)
                for i in range(council)]
    raiders = [Client(w, nm, guild_rank=3, class_file=CLASSES[i % 9], online=False)
               for i, nm in enumerate(names(n - 1 - council))]
    return w, gm, officers, [gm] + officers + raiders


def login_wave(w, clients, spread, seed=1):
    order = list(clients)
    random.Random(seed).shuffle(order)
    gap = spread / max(1, len(order))
    for c in order:
        c.login()
        w.tick(gap, min(gap, 0.25))


def quiet(w, prefixes=ALL_PREFIXES, idle=30.0, timeout=1800.0, step=0.25):
    """Tick until none of `prefixes` was sent for `idle` seconds. Returns the time of the last such message."""
    start = w.now
    n0 = len(w.addon_log)
    last = start
    while w.now - start < timeout:
        w.tick(step, step)
        for e in w.addon_log[n0:]:
            if e["prefix"] in prefixes:
                last = max(last, e["time"])
        n0 = len(w.addon_log)
        if w.now - last >= idle:
            return last
    raise TimeoutError("traffic did not settle within %ss" % timeout)


def throttles(clients):
    return sum(sync_common.throttled(c) for c in clients if c.online)


def stats(w, mark, prefixes=ALL_PREFIXES):
    """Wire messages / bytes per prefix and logical message counts per type since `mark`."""
    wire = [e for e in w.addon_log[mark:] if e["prefix"] in prefixes]
    per = Counter()
    size = Counter()
    for e in wire:
        per[e["prefix"]] += 1
        size[e["prefix"]] += len(e["text"])
    msgs = [m for m in sync_common.logical_messages(w, mark) if m["prefix"] in prefixes]
    types, parts, tbytes = Counter(), Counter(), Counter()
    for m in msgs:
        k = "%s/%s" % (m["t"], m["chat_type"][:1])
        types[k] += 1
        parts[k] += m["parts"]
        tbytes[k] += m["bytes"]
    senders = Counter()
    for e in wire:
        senders[e["sender"].split("-")[0]] += 1
    # every GUILD message is decoded by every other online member: the receive-side work of the guild
    fanout = sum(len(e.get("recipients") or ()) for e in wire)
    return {"wire": len(wire), "bytes": sum(size.values()), "per": dict(per), "size": dict(size), "types": types,
            "parts": parts, "tbytes": tbytes, "senders": senders, "fanout": fanout, "msgs": msgs}


def fmt(s):
    types = ", ".join("%s=%d (%dp, %.1f KB)" % (k, v, s["parts"][k], s["tbytes"][k] / 1024.0)
                      for k, v in sorted(s["types"].items(), key=lambda kv: -s["tbytes"][kv[0]]))
    return "%d wire msgs / %.1f KB, %d deliveries [%s]; busiest senders %s" % (
        s["wire"], s["bytes"] / 1024.0, s["fanout"], types, s["senders"].most_common(3))


def note(text):
    print("    " + text)


def stopwatch():
    t0 = time.time()
    return lambda: time.time() - t0


# ----------------------------------------------------------------------------------------------------------------
# Professions
# ----------------------------------------------------------------------------------------------------------------
def recipes_of(i, prof, n):
    base = 40000 + 3000 * PROFS.index(prof)
    rng = random.Random(i * 31 + PROFS.index(prof))
    picks = sorted(rng.sample(range(900), n))
    return [("Recipe %d" % p, base + 3 * p, 20000 + base % 7000 + p if p % 4 else None) for p in picks]


def profs_of(i):
    return [PROFS[i % 6], PROFS[(i // 6 + i + 1) % 6]] if PROFS[i % 6] != PROFS[(i // 6 + i + 1) % 6] \
        else [PROFS[i % 6], PROFS[(i + 3) % 6]]


def skills_of(i):
    return [(p, 375, 375) for p in profs_of(i)]


PROF_STATE = """
local s = ns.Professions:GetStats()
return { members = s.members, missing = s.missing, recipes = s.recipes }
"""


def prof_done(clients, members):
    for c in clients:
        s = c.eval_py(PROF_STATE)
        if s["members"] < members or s["missing"] > 0:
            return False
    return True


def prof_worst(clients):
    out = [c.eval_py(PROF_STATE) for c in clients]
    return min(s["members"] for s in out), max(s["missing"] for s in out)


@case
def professions_at_guild_size():
    w, gm, officers, everyone = guild()
    wall = stopwatch()
    login_wave(w, everyone, spread=10.0)
    for i, c in enumerate(everyone):
        set_skills(c, skills_of(i))
    quiet(w)
    # the first evening: everyone opens both profession windows at some point within two minutes
    mark, thr0, start = len(w.addon_log), throttles(everyone), w.now
    rng = random.Random(7)
    todo = sorted((rng.uniform(0, 120), i, k) for i in range(len(everyone)) for k in (0, 1))
    for at, i, k in todo:
        if w.now - start < at:
            w.tick(at - (w.now - start), 0.5)
        prof = profs_of(i)[k]
        open_tradeskill(everyone[i], prof, recipes_of(i, prof, 120 + (i * 37) % 160))
    scanned = w.now
    try:
        took = w.run_until(lambda: prof_done(everyone, len(everyone)), timeout=3600, step=5.0)
    except TimeoutError:
        took = None
    quiet(w, ("CDLm",))
    s = stats(w, mark, ("CDLm",))
    note("first scan (%d members x 2 professions over 120 s): %s" % (len(everyone), fmt(s)))
    note("  everyone has every recipe list %s s after the last scan; server-throttled sends %d; worst client "
         "(members known, lists missing) = %s; %.0f s wall" % (
             "NEVER" if took is None else "%.0f" % (w.now - scanned if took is None else took), throttles(everyone) - thr0,
             prof_worst(everyone), wall()))
    assert took is not None, "recipes did not converge: %s" % (prof_worst(everyone),)

    # next evening: everything in sync, all log in within 5 s
    for c in everyone:
        c.logout()
    w.tick(5)
    mark, start = len(w.addon_log), w.now
    login_wave(w, everyone, spread=5.0, seed=2)
    for i, c in enumerate(everyone):
        set_skills(c, skills_of(i))
    w.tick(90, 0.5)             # the index goes out a while after login
    last = quiet(w, ("CDLm",))
    s = stats(w, mark, ("CDLm",))
    note("relog wave in sync (%d logins / 5 s): %s; last message %.0f s after; throttled %d" % (
        len(everyone), fmt(s), last - start, throttles(everyone)))
    assert prof_done(everyone, len(everyone))

    # a fresh install among 59 who have everything
    new = everyone[-1]
    new.logout()
    w.saved.pop(new.full_name, None)
    w.tick(3)
    mark, start, thr0 = len(w.addon_log), w.now, throttles(everyone[:-1])
    new.login()
    set_skills(new, skills_of(len(everyone) - 1))
    try:
        took_s = w.run_until(lambda: new.eval_py(PROF_STATE)["members"] >= len(everyone) - 1, timeout=600, step=1.0)
    except TimeoutError:
        took_s = None
    try:
        took_r = w.run_until(lambda: prof_done([new], len(everyone) - 1), timeout=3600, step=5.0)
    except TimeoutError:
        took_r = None
    quiet(w, ("CDLm",))
    s = stats(w, mark, ("CDLm",))
    summaries = sum(len((m["msg"] or {}).get("l") or ()) for m in s["msgs"] if m["t"] == "PFB")
    note("fresh install joins %d members: %s" % (len(everyone) - 1, fmt(s)))
    note("  summaries after %s s, every recipe list after %s more s; %d summaries sent for %d members (%.1fx); "
         "throttled %d" % (took_s, took_r, summaries, len(everyone) - 1, summaries / float(len(everyone) - 1),
                           throttles(everyone[:-1]) - thr0))
    w.assert_no_errors()
    assert took_s is not None and took_r is not None, new.eval_py(PROF_STATE)


# ----------------------------------------------------------------------------------------------------------------
# A strategy and a raid changed while most of the guild was offline
# ----------------------------------------------------------------------------------------------------------------
HASHES = "return { s = ns.Strategy:GetDigestHash(), p = ns.RaidPlan:GetDigestHash() }"


def same_plans(clients):
    seen = set()
    for c in clients:
        h = c.eval_py(HASHES)
        seen.add((h["s"], h["p"]))
    return len(seen) == 1


@case
def stale_strategy_login_wave():
    w, gm, officers, everyone = guild()
    wall = stopwatch()
    login_wave(w, everyone, spread=10.0)
    quiet(w)
    gm_pick(w, gm, [o.name for o in officers])
    # right after a login wave the GM's control prefix is busy answering HELLOs: the list waits behind them
    t0 = w.now
    set_raid_leaders(w, gm, [o.name for o in officers], tick=0)
    w.run_until(lambda: all(o.eval("return ns.Guild:IsRaidPlanner(ns.Util.PlayerKey())") for o in officers), timeout=300,
                step=0.5)
    note("raid leaders list reached the officers %.1f s after the GM saved it (quiet guild)" % (w.now - t0))
    bob = officers[0]
    # a realistic base: 12 strategies and 6 planned raids everybody already has
    sids = [save_council(bob if i % 2 else officers[1], "Plan %d" % i) for i in range(12)]
    for i in range(6):
        create(bob, i="kara" if i % 2 else "gruul", t=now(bob) + (i + 1) * DAY)
    w.run_until(lambda: same_plans(everyone), timeout=600, step=2.0)
    quiet(w)
    online = [gm] + officers + everyone[len(officers) + 1:len(officers) + 3]
    away = [c for c in everyone if c not in online]
    for c in away:
        c.logout()
    w.tick(5)
    # the officer edits one strategy, adds one, and plans one more raid
    res = bob.eval_py("local s = ns.Strategy:GetStrategy(...); s.n = 'Changed'; local ok, e = ns.Strategy:SaveStrategy(s);"
                      " return { ok = ok, e = e }", sids[1])
    assert res["ok"] is True, res
    save_council(bob, "Brand new")
    create(bob, i="kara", t=now(bob) + 9 * DAY)
    w.run_until(lambda: same_plans(online), timeout=120, step=1.0)
    quiet(w)

    mark, start = len(w.addon_log), w.now
    login_wave(w, away, spread=60.0, seed=3)
    logged_in = w.now
    try:
        took = w.run_until(lambda: same_plans(everyone), timeout=1800, step=0.25)   # a coarse step lets timers
        # of a whole step fire before anything is delivered, which hides the "somebody answered" suppression
    except TimeoutError:
        took = None
    last = quiet(w)
    s = stats(w, mark)
    digests = {t: s["types"].get(t + "/G", 0) for t in ("SBD", "RPD")}
    note("%d stale members log in over 60 s (%d up to date online): %s" % (len(away), len(online), fmt(s)))
    lead = set(c.full_name for c in [gm] + officers)
    who = Counter()
    for m in s["msgs"]:
        if m["t"] in ("SBD", "SBG", "RPD", "RPG"):
            who[(m["t"], "council" if m["sender"] in lead else "member")] += m["parts"]
    note("  parts by sender kind: %s" % sorted(who.items()))
    note("  everyone has the new strategy and raid %s s after the last login; last message %.0f s after it; digests "
         "broadcast: %s for %d stale logins; throttled %d; %.0f s wall" % (
             "NEVER" if took is None else "%.0f" % took, last - logged_in, digests, len(away), throttles(everyone), wall()))
    w.assert_no_errors()
    assert took is not None, "plans did not converge"


# ----------------------------------------------------------------------------------------------------------------
# In-game update
# ----------------------------------------------------------------------------------------------------------------
@case
def patch_to_sixty_members():
    from _patchkit import patchlib, simple_pair, make, member, with_outbox, big_mods, text_of, is_ready, PREFIXES
    base_dir, record, new_dir = simple_pair(new_mods=big_mods(30000))
    bundle = make(record, new_dir)
    n_expected = sum(-(-len(i["z"]) // patchlib.CHUNK) for i in bundle["items"]) + -(-len(bundle["z0"]) // patchlib.CHUNK)
    w = World(addon_dir=base_dir)
    wall = stopwatch()
    online = []
    for i in range(N - 1):
        c = member(w, "Raider%02d" % i, base_dir, class_file=CLASSES[i % len(CLASSES)])
        c.load_addon()
        online.append(c)
    w.tick(60)
    with_outbox(new_dir, bundle)
    p = Client(w, "Pub", addon_dir=new_dir, guild_rank=0)
    p.load_addon()
    w.tick(2)
    start, mark = w.now, len(w.addon_log)
    p.slash("/dz publish")
    try:
        w.run_until(lambda: all(is_ready(c) for c in online), timeout=1800, step=1.0)
        took = w.now - start
    except TimeoutError:
        took = None
    w.tick(30)
    msgs = [e for e in w.addon_log[mark:] if e["prefix"] in PREFIXES]
    chunks = [e for e in msgs if text_of(e).startswith("C:")]
    wants = [e for e in msgs if text_of(e).startswith("W:")]
    announces = [e for e in msgs if text_of(e).startswith("A:")]
    refused = [e for e in msgs if e.get("error")]
    note("update of %d chunks to %d members: %d chunk, %d request, %d announce messages (%.1f KB); refused by the server "
         "%d; everyone ready after %s s; %.0f s wall" % (
             n_expected, len(online), len(chunks), len(wants), len(announces),
             sum(len(e["text"]) for e in msgs) / 1024.0, len(refused), "NEVER" if took is None else "%.0f" % took, wall()))
    w.assert_no_errors()
    assert took is not None, "%d of %d not ready" % (sum(1 for c in online if not is_ready(c)), len(online))


if __name__ == "__main__":
    run_all()

"""In-game updates, part 4: a guild-sized transfer.

25 members online when an update is published, 8 more logging in while it travels and after. Checks that everybody
ends up with the update, how long it takes, and that the traffic stays near the minimum: the chunks are sent about
once (not once per member), requests and announcements stay few, and the server never exceeds the per-prefix
allowance (nothing refused).

Run: luaenv\\Scripts\\python.exe tests\\patch\\test_patch_scale.py [-k name]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _patchkit import (case, run_all, World, Client, patchlib, simple_pair, make, member, with_outbox,  # noqa: E402
                       boot_state, patch_status, staged, big_mods, patch_msgs, text_of, is_ready, PREFIXES)

CLASSES = ["WARRIOR", "MAGE", "PRIEST", "ROGUE", "HUNTER", "SHAMAN", "DRUID", "WARLOCK", "PALADIN"]


@case
def guild_sized_transfer():
    base_dir, record, new_dir = simple_pair(new_mods=big_mods(30000))
    bundle = make(record, new_dir)
    n_expected = sum(-(-len(i["z"]) // patchlib.CHUNK) for i in bundle["items"]) + -(-len(bundle["z0"]) // patchlib.CHUNK)
    w = World(addon_dir=base_dir)
    online = []
    for i in range(25):
        c = member(w, "Raider%02d" % i, base_dir, class_file=CLASSES[i % len(CLASSES)])
        c.load_addon()
        online.append(c)
    w.tick(40)                                                    # login traffic settles
    quiet = len(patch_msgs(w))
    assert quiet == 25, quiet                                     # one announcement each, no answers (nobody holds anything)
    with_outbox(new_dir, bundle)
    p = Client(w, "Pub", addon_dir=new_dir, guild_rank=0)
    p.load_addon()
    w.tick(2)
    start = w.now
    mark = len(w.addon_log)
    p.slash("/cdl publish")
    late = []
    for i in range(4):                                            # four log in while the stream is running
        w.tick(12)
        c = member(w, "Late%d" % i, base_dir)
        c.load_addon()
        late.append(c)
    w.run_until(lambda: all(is_ready(c) for c in online + late), timeout=900)
    took = w.now - start
    p.logout()                                                    # the publisher leaves; four more arrive later
    w.tick(30)
    later = []
    for i in range(4):
        c = member(w, "Later%d" % i, base_dir)
        c.load_addon()
        later.append(c)
        w.tick(20)
    w.run_until(lambda: all(is_ready(c) for c in later), timeout=900)

    msgs = [e for e in w.addon_log[mark:] if e["prefix"] in PREFIXES]
    chunks = [e for e in msgs if text_of(e).startswith("C:")]
    wants = [e for e in msgs if text_of(e).startswith("W:")]
    announces = [e for e in msgs if text_of(e).startswith("A:")]
    refused = [e for e in msgs if e.get("error")]
    members = len(online) + len(late) + len(later)
    print("    %d chunks in the update; sent %d chunk, %d request and %d announce messages for %d members; "
          "the first %d members had it %.0f s after publishing" % (
              n_expected, len(chunks), len(wants), len(announces), members, len(online) + len(late), took))
    assert not refused, refused[:3]
    assert n_expected > 100
    # everybody online is served by one stream; latecomers cost at most what they missed, and the four who came
    # after the publisher left are served by members: far below "once per member" (33 x n_expected)
    assert len(chunks) <= n_expected * 6, (len(chunks), n_expected)
    assert len(wants) <= members * 8, len(wants)
    assert len(announces) <= members * 4, len(announces)
    assert took < n_expected / 2.5 + 120, took                    # ~3 chunks a second plus settling
    # the council channel was not starved: every chunk went out at BULK through ChatThrottleLib (no direct sends)
    for c in (online[0], late[0], later[-1]):
        c.relog()
    w.tick(3)
    for c in (online[0], late[0], later[-1]):
        assert boot_state(c)["state"] == "applied" and c.eval("return #ns.Util.PATCH_BLOB") > 100
    w.assert_no_errors()


@case
def everybody_already_up_to_date_is_quiet():
    base_dir, record, new_dir = simple_pair()
    bundle = make(record, new_dir)
    w = World(addon_dir=base_dir)
    for i in range(20):
        c = member(w, "Raider%02d" % i, base_dir, sv=staged(bundle))
        c.load_addon()
    w.tick(120)
    msgs = patch_msgs(w)
    assert len(msgs) == 20 and all(text_of(e).startswith("A:1:") for e in msgs), len(msgs)   # one line each at login
    w.tick(1800)
    assert len(patch_msgs(w)) <= 40                               # the half-hourly repeat, nothing else
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

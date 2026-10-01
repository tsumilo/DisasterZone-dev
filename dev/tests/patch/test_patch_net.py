"""In-game updates, part 2: publishing and the guild transfer (Core/Patch.lua, UI/PatchUI.lua).

Covers: publish -> every online member downloads, verifies and stores the update, reload applies it; late logins
served by any holder (publisher offline); one stream for many downloaders and a single server; lost, duplicated
and reordered messages; a member logging out mid-download and resuming; a newer update overtaking a download;
replays of an older signed update; a revoke; hostile members (garbage chunks, forged manifests, fake announcements,
request floods); another build / another key / kill switch; serving pauses in combat and encounters; the popup.

Run: luaenv\\Scripts\\python.exe tests\\patch\\test_patch_net.py [-k name]
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _patchkit import (case, run_all, World, Client, patchlib, release, key, source_copy, release_of, make,  # noqa: E402
                       staged, simple_pair, boot_state, patch_status, member, read, write, append, replace,
                       with_outbox, set_version, guard, toc_add, PREFIXES, text_of, patch_msgs, is_ready,
                       wait_ready, big_mods)

def publisher(w, new_dir, bundle, name="Pub", **kw):
    """The development copy of the publisher, with the update in its outbox."""
    with_outbox(new_dir, bundle)
    p = Client(w, name, addon_dir=new_dir, guild_rank=0, **kw)
    p.load_addon()
    return p


def setup(n_members=2, mark="v2", version="9.9.9", new_mods=None, base_mods=None, seq=1, **wkw):
    base_dir, record, new_dir = simple_pair(mark=mark, version=version, new_mods=new_mods, base_mods=base_mods)
    bundle = make(record, new_dir, seq=seq)
    w = World(addon_dir=base_dir, **wkw)
    members = []
    for i in range(n_members):
        m = member(w, "Member%s" % "ABCDEFGHIJ"[i], base_dir)
        m.load_addon()
        members.append(m)
    w.tick(1)
    return w, base_dir, record, new_dir, bundle, members


# ---------------------------------------------------------------------------------------------------------------
# The normal path
# ---------------------------------------------------------------------------------------------------------------

def raw_send(c, prefix, text):
    c.eval("C_ChatInfo.RegisterAddonMessagePrefix(...) ", prefix)
    return c.eval("return C_ChatInfo.SendAddonMessage(...)", prefix, text, "GUILD")


@case
def publish_download_apply():
    w, base_dir, record, new_dir, bundle, (a, b) = setup(2)
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")
    w.tick(1)
    assert any("published update 9.9.9 (#1)" in l for l in p.chat_frame), p.chat_frame[-4:]
    assert boot_state(p)["applied"] is None                       # the publisher's own copy runs from disk
    wait_ready(w, [a, b])
    for c in (a, b):
        st = patch_status(c)
        assert st["held"] == 1 and st.get("downloading") is None
        assert c.eval("return ns.Util.PATCH_MARK") is None        # nothing changes before the reload
        assert c.eval("return DisasterZonePatchDB.active.version") == "9.9.9"
        assert c.eval("return DisasterZonePatchDB.partial") is None
        assert any("update 9.9.9 is downloaded" in l for l in c.chat_frame), c.chat_frame[-4:]
        assert "DISASTERZONE_PATCH_READY" in c.popups(), c.popups()
        c.accept_popup("DISASTERZONE_PATCH_READY")
        assert c.eval("return __MOCK.reload_requested") is True
        c.relog()
    w.tick(3)
    for c in (a, b):
        s = boot_state(c)
        assert s["state"] == "applied" and s["version"] == "9.9.9" and c.eval("return ns.Util.PATCH_MARK") == "v2"
        assert patch_status(c).get("ready") is None
        assert "DISASTERZONE_PATCH_READY" not in c.popups()
    # one server at a time: the chunks were sent once (plus nothing after everybody had them)
    chunks = patch_msgs(w, "C")
    n_expected = sum(-(-len(i["z"]) // patchlib.CHUNK) for i in bundle["items"]) + -(-len(bundle["z0"]) // patchlib.CHUNK)
    assert n_expected <= len(chunks) <= n_expected + 2, (len(chunks), n_expected)
    assert all(len(text_of(e)) <= 255 for e in patch_msgs(w))
    assert all(e["chat_type"] == "GUILD" for e in patch_msgs(w))
    w.assert_no_errors()


@case
def late_login_is_served_by_a_member():
    w, base_dir, record, new_dir, bundle, (a,) = setup(1)
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")
    wait_ready(w, [a])
    p.logout()                                                    # the publisher leaves
    w.tick(5)
    late = member(w, "Late", base_dir)
    late.load_addon()
    wait_ready(w, [late], timeout=120)
    assert all(e["sender"].startswith("MemberA") for e in patch_msgs(w, "C")[-3:])
    late.relog()
    w.tick(3)
    assert boot_state(late)["state"] == "applied"
    # ... and a member who applied it still serves it
    a.relog()
    w.tick(3)
    late.logout()
    later = member(w, "Later", base_dir)
    later.load_addon()
    wait_ready(w, [later], timeout=120)
    w.assert_no_errors()


@case
def many_downloaders_one_stream():
    w, base_dir, record, new_dir, bundle, members = setup(6, new_mods=big_mods(40000))
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")
    wait_ready(w, members, timeout=400)
    n_expected = sum(-(-len(i["z"]) // patchlib.CHUNK) for i in bundle["items"]) + -(-len(bundle["z0"]) // patchlib.CHUNK)
    chunks = patch_msgs(w, "C")
    assert n_expected > 150
    assert len(chunks) <= n_expected * 1.15, (len(chunks), n_expected)      # not once per downloader
    assert {e["sender"].split("-")[0] for e in chunks} == {"Pub"}           # members did not pile in
    # the server kept inside the per-prefix allowance: nothing was refused
    assert not [e for e in patch_msgs(w) if e.get("error")], [e.get("error") for e in patch_msgs(w) if e.get("error")][:3]
    for m in members:
        assert m.eval("return DisasterZonePatchDB.active.files['Core/Dungeon.lua'] ~= nil") is True
    w.assert_no_errors()


@case
def lossy_duplicated_reordered_channel():
    rng = random.Random(11)
    w, base_dir, record, new_dir, bundle, members = setup(3, new_mods=big_mods(20000))

    def fault(entry, recipient):
        if entry["prefix"] not in PREFIXES:
            return None
        if rng.random() < 0.15:
            return False                                           # lost for this recipient
        return None
    w.addon_fault = fault
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")
    wait_ready(w, members, timeout=900)
    lost = sum(len(e.get("lost", [])) for e in patch_msgs(w))
    assert lost > 20, lost
    for m in members:
        m.relog()
    w.tick(3)
    for m in members:
        assert boot_state(m)["state"] == "applied" and m.eval("return #ns.Util.PATCH_BLOB") > 100
    w.assert_no_errors()


@case
def logout_mid_download_resumes():
    w, base_dir, record, new_dir, bundle, (a,) = setup(1, new_mods=big_mods(30000))
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")
    # wait until the small second file is complete but the big one is not
    w.run_until(lambda: (patch_status(a).get("downloading") or {}).get("known")
                and a.eval("local p = DisasterZonePatchDB.partial return p and p.src and (p.src[1] or p.src[2]) and true or false"),
                timeout=200)
    assert not is_ready(a)
    stored = a.eval_py("local p = DisasterZonePatchDB.partial return { seq = p.seq, n = (p.src[1] and 1 or 0) + (p.src[2] and 1 or 0) }")
    assert stored == {"seq": 1, "n": 1}, stored
    before = len(patch_msgs(w, "W", sender="MemberA"))
    a.relog(reload=False)                                         # logout + login
    w.tick(1)
    st = patch_status(a)
    assert st.get("downloading") and st["downloading"]["seq"] == 1, st
    wait_ready(w, [a], timeout=300)
    # the manifest and the finished file were not fetched again (the rest may simply arrive with the stream
    # that is still running)
    wants = [text_of(e) for e in patch_msgs(w, "W", sender="MemberA")][before:]
    assert not any(t.startswith("W:1:0:") or t == "W:1:all" for t in wants), wants
    a.relog()
    w.tick(3)
    assert boot_state(a)["state"] == "applied" and a.eval("return ns.PATCH_SECOND_FILE") is True
    w.assert_no_errors()


@case
def newer_update_overtakes_a_download():
    base_dir, record, new_dir = simple_pair(mark="v2", version="9.9.8", new_mods=big_mods(30000))
    b1 = make(record, new_dir, seq=1)
    newer = source_copy("newer", lambda root: append(root, "Core/Util.lua", '\nUtil.PATCH_MARK = "v3"\n'), version="9.9.9")
    b2 = make(record, newer, seq=2)
    w = World(addon_dir=base_dir)
    a = member(w, "MemberA", base_dir)
    a.load_addon()
    p = publisher(w, new_dir, b1)
    w.tick(2)
    p.slash("/dz publish")
    w.run_until(lambda: (patch_status(a).get("downloading") or {}).get("known"), timeout=120)
    # the publisher builds #2 and publishes it while #1 is still travelling
    with_outbox(new_dir, b2)
    p.relog()
    w.tick(1)
    p.slash("/dz publish")
    wait_ready(w, [a], seq=2, timeout=300)
    assert a.eval("return DisasterZonePatchDB.active.version") == "9.9.9" and a.eval("return DisasterZonePatchDB.seq") == 2
    a.relog()
    w.tick(3)
    assert boot_state(a)["version"] == "9.9.9" and a.eval("return ns.Util.PATCH_MARK") == "v3"
    w.assert_no_errors()


@case
def update_on_top_of_a_running_update():
    base_dir, record, new_dir = simple_pair(mark="v2", version="9.9.8")
    b1 = make(record, new_dir, seq=1)
    newer = source_copy("newer", lambda root: append(root, "Core/Dungeon.lua", "\nns.THIRD = 3\n"), version="9.9.9")
    b2 = make(record, newer, seq=2)                               # cumulative, but without the Util change
    w = World(addon_dir=base_dir)
    a = member(w, "MemberA", base_dir, sv=staged(b1))
    a.load_addon()
    w.tick(2)
    assert boot_state(a)["version"] == "9.9.8" and a.eval("return ns.Util.PATCH_MARK") == "v2"
    p = publisher(w, newer, b2)
    w.tick(2)
    p.slash("/dz publish")
    wait_ready(w, [a], seq=2)
    assert boot_state(a)["version"] == "9.9.8"                    # still running #1 until the reload
    a.relog()
    w.tick(3)
    s = boot_state(a)
    assert s["version"] == "9.9.9" and a.eval("return ns.THIRD") == 3
    assert a.eval("return ns.Util.PATCH_MARK") is None            # #2 replaced #1 entirely
    w.assert_no_errors()


@case
def revoke_goes_back_to_the_installed_version():
    base_dir, record, new_dir = simple_pair()
    b1 = make(record, new_dir, seq=1)
    b2 = make(record, new_dir, seq=2, revoke=True)
    assert b2["items"] == [] and b2["version"] == record["version"]
    w = World(addon_dir=base_dir)
    a = member(w, "MemberA", base_dir, sv=staged(b1))
    a.load_addon()
    w.tick(2)
    assert boot_state(a)["state"] == "applied"
    p = publisher(w, new_dir, b2)
    w.tick(2)
    p.slash("/dz publish")
    wait_ready(w, [a], seq=2)
    a.relog()
    w.tick(3)
    s = boot_state(a)
    assert s["state"] == "applied" and s["applied"]["files"] == 0 and s["version"] == record["version"], s
    assert a.eval("return ns.Util.PATCH_MARK") is None
    # the old update cannot come back: a member still announcing #1 is ignored, and told about #2
    old = member(w, "Old", base_dir, sv=staged(b1))
    old.load_addon()
    wait_ready(w, [old], seq=2, timeout=120)
    assert a.eval("return DisasterZonePatchDB.active.seq") == 2
    w.assert_no_errors()


@case
def manifest_length_a_multiple_of_the_chunk_size():
    """The manifest ends with its first short chunk; when its length divides evenly, that chunk is empty."""
    base_dir, record, new_dir = simple_pair()
    src = read(new_dir, "Core/Util.lua").encode("utf-8")
    bundle = None
    for k1 in range(1, 90):
        for k2 in (1, 2, 3):
            entries = [{"kind": "F", "path": "Core/Util.lua", "src": src},
                       {"kind": "D", "path": "Core/Gone%s.lua" % ("x" * k1)},
                       {"kind": "D", "path": "Core/Away%s.lua" % ("y" * k2)}]
            b = patchlib.build_bundle(1, "9.9.9", record["build"], 1, entries, key())
            if len(b["z0"]) % patchlib.CHUNK == 0:
                bundle = b
                break
        if bundle:
            break
    assert bundle, "no manifest length hit a multiple of the chunk size"
    n0 = len(bundle["z0"]) // patchlib.CHUNK + 1
    w = World(addon_dir=base_dir)
    a = member(w, "MemberA", base_dir)
    a.load_addon()
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")
    wait_ready(w, [a], timeout=300)
    manifest_chunks = [text_of(e) for e in patch_msgs(w, "C") if text_of(e).startswith("C:1:0:")]
    assert "C:1:0:%d:" % n0 in manifest_chunks, manifest_chunks[-2:]          # the empty end marker
    assert len(manifest_chunks) == n0
    assert any(text_of(e) == "A:1:%s:%d" % (record["build"], n0) for e in patch_msgs(w, "A"))
    a.relog()
    w.tick(3)
    assert boot_state(a)["state"] == "applied" and a.eval("return ns.Util.PATCH_MARK") == "v2"
    # the member serves it the same way
    p.logout()
    late = member(w, "Late", base_dir)
    late.load_addon()
    wait_ready(w, [late], timeout=300)
    w.assert_no_errors()


@case
def a_false_end_of_the_manifest_is_survived():
    """Somebody injects an early "last chunk" (and a chunk beyond the real end) into the manifest stream."""
    w, base_dir, record, new_dir, bundle, (a, evil) = setup(2)
    evil.eval("ns.Patch.OnPatchComm = function() end")
    for prefix in PREFIXES:
        evil.eval("C_ChatInfo.RegisterAddonMessagePrefix(...)", prefix)
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")
    w.run_until(lambda: len(patch_msgs(w, "C", sender="Pub")) >= 3, timeout=60)
    raw_send(evil, "CDLp2", "C:1:0:2:abc")                        # "the manifest ends at chunk 2" (below a held chunk)
    raw_send(evil, "CDLp3", "C:1:0:200:" + "a" * patchlib.CHUNK)  # far beyond the end
    wait_ready(w, [a], timeout=400)
    a.relog()
    w.tick(3)
    assert boot_state(a)["state"] == "applied"
    w.assert_no_errors()


@case
def joining_mid_stream_keeps_what_it_overhears():
    w, base_dir, record, new_dir, bundle, (a,) = setup(1, new_mods=big_mods(40000))
    n_files = sum(-(-len(i["z"]) // patchlib.CHUNK) for i in bundle["items"])
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")
    w.run_until(lambda: len([e for e in patch_msgs(w, "C") if not text_of(e).startswith("C:1:0:")]) > n_files // 3,
                timeout=200)
    late = member(w, "Late", base_dir)
    late.load_addon()
    joined = w.now
    mark = len(w.addon_log)
    wait_ready(w, [a, late], timeout=400)
    took = w.now - joined
    late_msgs = [text_of(e) for e in w.addon_log[mark:] if e["prefix"] in PREFIXES and e["sender"].startswith("Late")]
    # it asked right away (overhearing the stream), got the manifest while the files kept streaming ...
    assert late_msgs[0].startswith("A:0:"), late_msgs
    assert "W:1:0:*" in late_msgs, late_msgs
    assert "W:1:all" not in late_msgs, late_msgs               # ... and never needed everything again
    asked = [t for t in late_msgs if t.startswith("W:1:") and not t.startswith("W:1:0:")]
    assert asked, late_msgs                                     # only the part that went by before it joined
    resent = len([e for e in w.addon_log[mark:] if e["prefix"] in PREFIXES and text_of(e).startswith("C:1:")
                  and not text_of(e).startswith("C:1:0:")])
    remaining_at_join = n_files - n_files // 3
    assert resent <= remaining_at_join + n_files // 3 + 25, (resent, n_files)
    late.relog()
    w.tick(3)
    assert boot_state(late)["state"] == "applied"
    w.assert_no_errors()


@case
def early_chunks_are_bounded_and_checked():
    """File chunks heard before the manifest are kept only within the limits and still pass every check."""
    w, base_dir, record, new_dir, bundle, (a, evil) = setup(2)
    evil.eval("ns.Patch.OnPatchComm = function() end")
    for prefix in PREFIXES:
        evil.eval("C_ChatInfo.RegisterAddonMessagePrefix(...)", prefix)
    raw_send(evil, "CDLp1", "A:1:%s:15" % record["build"])       # announces the real number, serves nonsense
    w.tick(1)
    assert patch_status(a)["downloading"]["seq"] == 1
    junk = "b" * patchlib.CHUNK
    for i, (item, idx) in enumerate([(1, 1), (1, 2), (1, 1), (999, 1), (1, 99999), (0, 99), (2, 0), (1, 3)]):
        raw_send(evil, PREFIXES[1 + i % 3], "C:1:%d:%d:%s" % (item, idx, junk))
    raw_send(evil, "CDLp2", "C:1:1:4:" + "b" * (patchlib.CHUNK + 1))   # longer than a chunk
    raw_send(evil, "CDLp2", "C:1:1:5:not valid!")
    w.tick(1)
    kept = a.eval_py("local n = 0 for item, chunks in pairs(ns.Patch._dl().early) do for idx in pairs(chunks) do n = n + 1 end end return n")
    assert kept == 3, kept                                        # (1,1) (1,2) (1,3): duplicates and out-of-range dropped
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")
    wait_ready(w, [a], timeout=400)                               # the junk failed its hash; the real data replaced it
    a.relog()
    w.tick(3)
    assert boot_state(a)["state"] == "applied" and a.eval("return ns.Util.PATCH_MARK") == "v2"
    w.assert_no_errors()


@case
def the_servers_own_announcements_get_through_during_a_stream():
    """Chunks never use the control prefix, so the server can answer a newcomer while it is streaming."""
    w, base_dir, record, new_dir, bundle, (a,) = setup(1, new_mods=big_mods(40000))
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")
    w.run_until(lambda: len(patch_msgs(w, "C")) > 80, timeout=200)
    assert all(e["prefix"] != "CDLp1" for e in patch_msgs(w, "C"))
    assert all(e["prefix"] == "CDLp1" for e in patch_msgs(w, "A") + patch_msgs(w, "W"))
    late = member(w, "Late", base_dir)
    late.load_addon()
    t0 = w.now
    w.run_until(lambda: (patch_status(late).get("downloading") or {}).get("known"), timeout=60)
    assert w.now - t0 < 25, w.now - t0                            # nudge + answer + manifest, with the stream running
    # steady rate of the stream: about 2.7 chunks a second through ChatThrottleLib, not 1
    chunks = patch_msgs(w, "C")
    span = chunks[-1]["time"] - chunks[40]["time"]
    assert (len(chunks) - 40) / span > 2.0, ((len(chunks) - 40) / span)
    assert not [e for e in patch_msgs(w) if e.get("error")]
    w.assert_no_errors()


# ---------------------------------------------------------------------------------------------------------------
# Hostile or broken peers
# ---------------------------------------------------------------------------------------------------------------

@case
def replay_of_an_older_signed_update_is_ignored():
    base_dir, record, new_dir = simple_pair(mark="v2", version="9.9.8")
    b1 = make(record, new_dir, seq=1)
    newer = source_copy("newer", lambda root: append(root, "Core/Util.lua", '\nUtil.PATCH_MARK = "v3"\n'), version="9.9.9")
    b2 = make(record, newer, seq=2)
    w = World(addon_dir=base_dir)
    a = member(w, "MemberA", base_dir, sv=staged(b2))
    a.load_addon()
    # a member whose stored #2 was lost (kill switch history, damaged file ...) but who has seen #2
    fresh = member(w, "Fresh", base_dir, sv="{ seq = 2 }")
    fresh.load_addon()
    evil = member(w, "Evil", base_dir, sv=staged(b1))            # genuinely holds the old, correctly signed #1
    evil.load_addon()
    a.logout()
    w.tick(60)
    assert patch_status(fresh).get("downloading") is None and patch_status(fresh).get("held") is None
    assert fresh.eval("return DisasterZonePatchDB.active") is None
    # when a holder of #2 is around, everybody ends on #2
    a.login()
    wait_ready(w, [fresh, evil], seq=2, timeout=200)
    w.assert_no_errors()


@case
def garbage_chunks_from_a_member_are_survived():
    w, base_dir, record, new_dir, bundle, (a, evil) = setup(2, new_mods=big_mods(8000))
    n0 = -(-len(bundle["z0"]) // patchlib.CHUNK)
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    # Evil races the real server with well-formed chunks full of nonsense, for the manifest and for file 1
    evil.eval("ns.Patch.OnPatchComm = function() end")           # (it does not take part itself)
    junk = "a" * patchlib.CHUNK
    for prefix in PREFIXES:
        evil.eval("C_ChatInfo.RegisterAddonMessagePrefix(...)", prefix)
    p.slash("/dz publish")
    w.tick(1.2)
    for idx in range(1, min(n0, 9) + 1):
        raw_send(evil, PREFIXES[1 + idx % 3], "C:1:0:%d:%s" % (idx, junk if idx < n0 else "abc"))
    wait_ready(w, [a], timeout=400)
    assert a.eval("return DisasterZonePatchDB.active.seq") == 1
    a.relog()
    w.tick(3)
    assert boot_state(a)["state"] == "applied" and a.eval("return ns.Util.PATCH_MARK") == "v2"
    w.assert_no_errors()


@case
def forged_manifest_is_rejected():
    """Somebody without the key serves a complete, well-formed update for a higher sequence number."""
    w, base_dir, record, new_dir, bundle, (a,) = setup(1)
    evil_dir = source_copy("evil", lambda root: append(root, "Core/Util.lua", '\nUtil.PATCH_MARK = "pwned"\n'), version="9.9.9")
    for forged in (make(record, evil_dir, seq=5, signing_key=key("other")),):
        with_outbox(evil_dir, forged)
    # the forger's own client accepts its own key (it runs modified code) and serves the forgery
    write(evil_dir, "Core/PatchKey.lua", release.patch_key_lua(key("other")))
    evil = Client(w, "Evil", addon_dir=evil_dir)
    evil.load_addon()
    w.tick(2)
    evil.slash("/dz publish")
    w.tick(120)
    assert any("published update" in l for l in evil.chat_frame)
    assert len(patch_msgs(w, "C", sender="Evil")) > 0             # it was offered and downloaded ...
    st = patch_status(a)
    assert st.get("ready") is None and st.get("held") is None, st  # ... and refused
    assert a.eval("return DisasterZonePatchDB.active") is None and a.eval("return DisasterZonePatchDB.partial") is None
    assert a.eval("return DisasterZonePatchDB.seq") is None              # the replay floor did not move either
    # the genuine update still gets through afterwards
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")
    wait_ready(w, [a], seq=1, timeout=300)
    a.relog()
    w.tick(3)
    assert a.eval("return ns.Util.PATCH_MARK") == "v2"
    w.assert_no_errors()


@case
def tampered_file_with_a_genuine_manifest_is_rejected():
    """The manifest is real, but a holder's stored file text was altered: the hash check stops it."""
    w, base_dir, record, new_dir, bundle, (a,) = setup(1)
    sv = staged(bundle)
    evil_z = patchlib.encode_for_print(patchlib.deflate_raw(b'DisasterZonePwned = true\n'))
    assert sv.count(bundle["items"][0]["z"]) == 1
    evil = member(w, "Evil", base_dir, sv=sv.replace(bundle["items"][0]["z"], evil_z))
    evil.load_addon()
    w.tick(200)
    st = patch_status(a)
    assert st.get("ready") is None, st
    assert a.eval("return DisasterZonePwned") is None
    assert a.eval("local p = DisasterZonePatchDB.partial return p and p.src and p.src[1]") is None
    # the downloader named the holder in its next request; the holder checked its copy and stopped serving it
    assert any("!Evil-" in text_of(e) for e in patch_msgs(w, "W", sender="MemberA")), \
        [text_of(e) for e in patch_msgs(w, "W", sender="MemberA")]
    assert patch_status(evil).get("held") is None
    assert evil.eval("return DisasterZonePatchDB.active.z") is None
    quiet_from = len(patch_msgs(w, "C", sender="Evil"))
    # an honest holder arrives: the download completes from it, and the damaged holder stays silent
    good = member(w, "Good", base_dir, sv=staged(bundle))
    good.load_addon()
    wait_ready(w, [a], timeout=400)
    assert a.eval("return DisasterZonePatchDB.active.files['Core/Util.lua']:find('PATCH_MARK') ~= nil") is True
    assert len(patch_msgs(w, "C", sender="Evil")) == quiet_from
    # after a relog the damaged holder fetches a fresh copy and serves again
    evil.relog(reload=False)
    w.run_until(lambda: patch_status(evil).get("held") == 1, timeout=300)
    assert evil.eval("return #DisasterZonePatchDB.active.z") == 1
    w.assert_no_errors()


@case
def fake_announcements_do_not_block_real_updates():
    w, base_dir, record, new_dir, bundle, (a, evil) = setup(2)
    evil.eval("ns.Patch.OnPatchComm = function() end")
    for prefix in PREFIXES:
        evil.eval("C_ChatInfo.RegisterAddonMessagePrefix(...)", prefix)
    raw_send(evil, "CDLp1", "A:900:%s:3" % record["build"])       # nobody holds #900
    w.tick(2)
    assert patch_status(a)["downloading"]["seq"] == 900
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")                                       # #1 is announced while #900 is being looked for
    wait_ready(w, [a], seq=1, timeout=400)
    # malformed and out-of-range announcements are ignored outright
    for bad in ("A:2:%s:99999" % record["build"], "A:-1:x:1", "A:2", "A:x:y:z", "A:70000:%s:1" % record["build"],
                "A:2:%s:1:extra" % record["build"], "A:" + "9" * 40 + ":" + record["build"] + ":1"):
        raw_send(evil, "CDLp1", bad)
    w.tick(3)
    assert patch_status(a).get("downloading") is None
    # a well-formed lie about a newer update is looked for, given up, and changes nothing
    raw_send(evil, "CDLp1", "A:2:%s:7" % record["build"])
    w.tick(2)
    assert patch_status(a)["downloading"]["seq"] == 2
    w.tick(200)
    st = patch_status(a)
    assert st.get("downloading") is None and st["held"] == 1 and st["ready"]["seq"] == 1, st
    assert a.eval("return DisasterZonePatchDB.seq") == 1
    w.assert_no_errors()


@case
def request_flood_is_rate_limited():
    w, base_dir, record, new_dir, bundle, (holder, evil) = setup(2, new_mods=big_mods(20000))
    holder.logout()
    holder.set_saved_variable("DisasterZonePatchDB", staged(bundle))
    holder.login()
    w.tick(30)
    evil.eval("ns.Patch.OnPatchComm = function() end")
    for prefix in PREFIXES:
        evil.eval("C_ChatInfo.RegisterAddonMessagePrefix(...)", prefix)
    start = len(patch_msgs(w, "C"))
    n_all = sum(-(-len(i["z"]) // patchlib.CHUNK) for i in bundle["items"])
    for round_ in range(12):
        for i in range(8):
            raw_send(evil, PREFIXES[1 + i % 3], "W:1:all")
            raw_send(evil, PREFIXES[1 + i % 3], "W:1:1:*")
        w.tick(8)
    w.tick(120)
    sent = len(patch_msgs(w, "C")) - start
    # without the limit a re-request per finished stream would be served every time; with it the holder
    # serves the full set at most a few times over the two minutes
    assert sent <= n_all * 12, (sent, n_all)
    # garbage requests do no harm
    for bad in ("W:1:99:*", "W:1:1:5-2", "W:1:1:999999-9999999", "W:1:1:1-", "W:x:all", "W:1", "W:1:1:" + "1," * 100,
                "W:7:all", "C:1:1:1:", "C:1:0:0:abc", "C:1:500:1:abc", "C::::", "Z:1", ""):
        raw_send(evil, "CDLp1", bad)
    w.tick(5)
    w.assert_no_errors()


@case
def other_build_other_key_and_kill_switch_do_not_download():
    base_dir, record, new_dir = simple_pair()
    bundle = make(record, new_dir)
    other_src = source_copy("other", lambda root: append(root, "Core/Dungeon.lua", "\n-- another release\n"))
    other_dir, other_record = release_of(other_src)
    wrongkey_src = source_copy("wrongkey", lambda root: write(root, "Core/PatchKey.lua", release.patch_key_lua(key("other"))))
    wrongkey_dir, _ = release_of(wrongkey_src, build=record["build"])
    w = World(addon_dir=base_dir)
    normal = member(w, "Normal", base_dir)
    other = member(w, "Other", other_dir)                         # installed a different release
    wrong = member(w, "Wrong", wrongkey_dir)                      # same build id, but trusts another key
    off = member(w, "Off", base_dir, sv="{ off = true }")
    nosv = member(w, "NoSv", base_dir, sv="{ probe = true }", sv_before_files=False)   # client ignores the directive
    for c in (normal, other, wrong, off, nosv):
        c.load_addon()
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")
    wait_ready(w, [normal])
    w.tick(120)
    for c in (other, wrong, off, nosv):
        st = patch_status(c)
        assert st.get("ready") is None and st.get("held") is None, (c.name, st)
        assert c.eval("return DisasterZonePatchDB.active") is None, c.name
    assert patch_msgs(w, sender="Off") == []                      # switched off = silent
    assert patch_msgs(w, "W", sender="Other") == []               # never asked: the announce named another build
    assert patch_msgs(w, "W", sender="NoSv") == []
    assert len(patch_msgs(w, "W", sender="Wrong")) > 0            # asked, got it, refused it
    w.assert_no_errors()


@case
def no_guild_no_traffic():
    base_dir, record, new_dir = simple_pair()
    bundle = make(record, new_dir)
    w = World(addon_dir=base_dir)
    solo = member(w, "Solo", base_dir, guild=None, sv=staged(bundle))
    solo.load_addon()
    w.tick(60)
    assert boot_state(solo)["state"] == "applied"                 # a stored update still applies
    assert patch_msgs(w) == []
    w.assert_no_errors()


# ---------------------------------------------------------------------------------------------------------------
# Serving rules
# ---------------------------------------------------------------------------------------------------------------

@case
def serving_stops_in_combat_and_another_holder_takes_over():
    w, base_dir, record, new_dir, bundle, (a,) = setup(1, new_mods=big_mods(30000))
    h1 = member(w, "HolderA", base_dir, sv=staged(bundle))
    h2 = member(w, "HolderB", base_dir, sv=staged(bundle))
    h1.load_addon()
    h2.load_addon()
    w.run_until(lambda: len(patch_msgs(w, "C")) > 60, timeout=120)
    first = patch_msgs(w, "C")[-1]["sender"].split("-")[0]
    server, standby = (h1, h2) if first == "HolderA" else (h2, h1)
    # one holder serves the file stream (the manifest before it may have come from the other one)
    assert {e["sender"].split("-")[0] for e in patch_msgs(w, "C")[-25:]} == {first}
    server.set_combat(True)                                       # the server pulls a boss
    w.tick(1)
    mark = len(patch_msgs(w, "C"))
    wait_ready(w, [a], timeout=400)
    later = {e["sender"].split("-")[0] for e in patch_msgs(w, "C")[mark + 5:]}
    assert later == {standby.name}, later
    w.assert_no_errors()


@case
def encounter_pauses_serving_and_delays_the_popup():
    w, base_dir, record, new_dir, bundle, (a,) = setup(1)
    holder = member(w, "Holder", base_dir)
    holder.load_addon()
    w.tick(1)
    w.make_raid([a, holder])
    holder.fire("ENCOUNTER_START", 652, "Gruul", 4, 25)
    a.fire("ENCOUNTER_START", 652, "Gruul", 4, 25)
    a.set_combat(True)
    p = publisher(w, new_dir, bundle)
    w.tick(2)
    p.slash("/dz publish")
    w.tick(90)
    # in combat the heavy verification waits: the chunks are kept, nothing is stored, ready or popped up
    assert a.eval("return DisasterZonePatchDB.partial") is None and not is_ready(a)
    assert (patch_status(a).get("downloading") or {}).get("seq") == 1
    assert "DISASTERZONE_PATCH_READY" not in a.popups()
    a.set_combat(False)
    a.fire("PLAYER_REGEN_ENABLED")
    wait_ready(w, [a], timeout=200)
    w.tick(10)
    assert "DISASTERZONE_PATCH_READY" not in a.popups()                 # the encounter is still going
    a.fire("ENCOUNTER_END", 652, "Gruul", 4, 25, 1)
    w.tick(5)
    assert "DISASTERZONE_PATCH_READY" in a.popups()
    a.cancel_popup("DISASTERZONE_PATCH_READY")                          # "Later"
    w.tick(30)
    assert "DISASTERZONE_PATCH_READY" not in a.popups()                 # once per session
    a.relog()
    w.tick(3)
    assert boot_state(a)["state"] == "applied"                    # applied by the reload anyway
    w.assert_no_errors()


@case
def forced_yields_do_not_change_the_result():
    w, base_dir, record, new_dir, bundle, (a,) = setup(1, new_mods=big_mods(6000))
    a.eval("ns.Patch.forceYield = true")
    p = publisher(w, new_dir, bundle)
    p.eval("ns.Patch.forceYield = true")
    w.tick(2)
    p.slash("/dz publish")
    w.run_until(lambda: any("published update" in l for l in p.chat_frame), timeout=120)
    wait_ready(w, [a], timeout=600)
    a.relog()
    w.tick(3)
    assert boot_state(a)["state"] == "applied"
    w.assert_no_errors()


@case
def publish_refusals():
    base_dir, record, new_dir = simple_pair()
    bundle = make(record, new_dir, seq=2)
    w = World(addon_dir=base_dir)
    # nothing in the outbox
    m = member(w, "MemberA", base_dir)
    m.load_addon()
    w.tick(1)
    m.slash("/dz publish")
    assert any("nothing to publish" in l for l in m.chat_frame[-2:])
    # a damaged outbox
    broken = dict(bundle)
    broken["items"] = [dict(bundle["items"][0], z=bundle["items"][0]["z"][:-4] + "aaaa")]
    p = publisher(w, new_dir, broken)
    w.tick(1)
    p.slash("/dz publish")
    w.tick(3)
    assert any("damaged" in l for l in p.chat_frame[-3:]), p.chat_frame[-3:]
    assert p.eval("return DisasterZonePatchDB.active") is None
    # the good one; publishing it twice only announces again
    with_outbox(new_dir, bundle)
    p.relog()
    w.tick(1)
    p.slash("/dz publish")
    w.tick(3)
    assert any("published update 9.9.9 (#2)" in l for l in p.chat_frame[-3:]), p.chat_frame[-3:]
    p.slash("/dz publish")
    w.tick(3)
    assert any("already published" in l for l in p.chat_frame[-3:]), p.chat_frame[-3:]
    # an outbox older than what is out
    with_outbox(new_dir, make(record, new_dir, seq=1))
    p.relog()
    w.tick(1)
    p.slash("/dz publish")
    w.tick(3)
    assert any("already out" in l for l in p.chat_frame[-3:]), p.chat_frame[-3:]
    assert p.eval("return DisasterZonePatchDB.active.seq") == 2
    p.slash("/dz update")
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

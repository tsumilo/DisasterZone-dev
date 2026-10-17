"""In-game updates, part 3: the publisher's tool (dev/tools/release.py, patchlib.py).

Covers: what may and may not travel as an update (TOC header, libraries, the boot files, TOC order, art with and
without a raised art pack, unguarded files, docs); the build id; source normalisation; the outbox file; the
sequence counter and the signing key running out; and the real command line end to end in a sandbox: keygen ->
full release zip -> a member installs the zip -> patch -> /dz publish -> the member runs the new version.

Run: luaenv\\Scripts\\python.exe tests\\patch\\test_release_tool.py [-k name]
"""
import json
import os
import shutil
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _patchkit import (case, run_all, World, Client, patchlib, release, key, source_copy, release_of, make,  # noqa: E402
                       staged, simple_pair, boot_state, patch_status, member, read, write, append, replace,
                       with_outbox, set_version, guard, toc_add, toc_remove, TMP, _unique)


def refused(record, new_dir, *needles):
    try:
        make(record, new_dir)
    except release.ReleaseError as e:
        for n in needles:
            assert n in str(e), (n, str(e))
        return str(e)
    raise AssertionError("release.py accepted it; expected a refusal mentioning %r" % (needles,))


def full_base(mods=None):
    """A release record that includes non-Lua files (art), as a real release does."""
    src = source_copy("fullsrc", mods)
    dst = _unique("fullrel")
    record = release.stage_tree(src, dst)
    return src, dst, record


def with_art(root):
    write(root, "Art/map.blp", "BLP2 fake art 1")
    write(root, "README.md", "docs")


@case
def what_cannot_travel_is_refused():
    base_dir, record, new_dir = simple_pair()
    cases = [
        (lambda r: replace(r, "DisasterZone.toc", "## Interface: 20506", "## Interface: 20507"), ("full release", "interface")),
        (lambda r: replace(r, "DisasterZone.toc", "## SavedVariables: DisasterZoneDB, DisasterZonePatchDB", "## SavedVariables: DisasterZoneDB, DisasterZonePatchDB, DisasterZoneNew"), ("savedvariables",)),
        (lambda r: append(r, "Libs/LibStub/LibStub.lua", "\n-- changed\n"), ("Libs/LibStub/LibStub.lua changed",)),
        (lambda r: append(r, "Core/Boot.lua", "\n-- changed\n"), ("Core/Boot.lua changed",)),
        (lambda r: append(r, "Core/BootEnd.lua", "\n-- changed\n"), ("Core/BootEnd.lua changed",)),
        (lambda r: (toc_remove(r, "Core/Dungeon.lua"), toc_add(r, "Core/Dungeon.lua", "Core/Constants.lua")), ("order",)),
        (lambda r: (write(r, "Libs/New/New.lua", "-- lib\n"), toc_add(r, "Libs/New/New.lua", "Libs/LibStub/LibStub.lua")), ("cannot be patched",)),
        (lambda r: toc_remove(r, "Libs/LibCustomGlow-1.0/LibCustomGlow-1.0.lua"), ("no longer lists",)),
        (lambda r: write(r, "Core/Dungeon.lua", read(r, "Core/Dungeon.lua").split("then return end ", 1)[1]), ("guard",)),
        (lambda r: replace(r, "Core/Dungeon.lua", '"Core/Dungeon.lua"', '"Core/Other.lua"'), ("guard",)),
        (lambda r: os.remove(os.path.join(r, "Core", "Dungeon.lua")), ("missing",)),
    ]
    for mods, needles in cases:
        tree = source_copy("refuse", mods, version="9.9.9")
        refused(record, tree, *needles)
    # nothing changed at all
    same = source_copy("same")
    refused(record, same, "nothing changed")
    # a version bump alone is not a change either (the TOC is not part of an update)
    refused(record, source_copy("same", version="9.9.9"), "nothing changed")
    # tool-managed files never count: a different outbox / build info in the source tree
    tree = source_copy("managed", lambda r: (write(r, "Core/Outbox.lua", "DisasterZoneOutbox = {}\n"),
                                              append(r, "Core/Util.lua", "\n-- x\n")), version="9.9.9")
    assert [i["path"] for i in make(record, tree)["items"]] == ["Core/Util.lua"]


@case
def art_needs_a_raised_art_pack():
    src, base_dir, record = full_base(with_art)
    assert "Art/map.blp" in record["files"] and record["assetPack"] == 1 and not record["luaOnly"]

    def changed(more=None):
        def mods(r):
            with_art(r)
            write(r, "Art/map.blp", "BLP2 fake art 2")
            write(r, "Art/new.tga", "TGA")
            write(r, "README.md", "docs changed")           # docs never matter
            append(r, "Core/Util.lua", "\nUtil.X = 1\n")
            if more:
                more(r)
        return source_copy("art", mods, version="9.9.9")
    msg = refused(record, changed(), "art changed", "assetPack", "HasAssets(2)")
    assert "Art/map.blp" in msg and "README" not in msg
    # raised, but no code checks for the new art: allowed, with a reminder
    bundle, notes = release.make_patch(record, changed(lambda r: replace(r, "Core/BuildInfo.lua", "assetPack = 1", "assetPack = 2")), key(), 1)
    assert bundle["pack"] == 2 and "pack=2\n" in bundle["manifest"]
    assert any("2 art file(s) changed" in n for n in notes) and any("HasAssets(2)" in n for n in notes), notes
    # raised and gated: no reminder
    bundle, notes = release.make_patch(record, changed(lambda r: (
        replace(r, "Core/BuildInfo.lua", "assetPack = 1", "assetPack = 2"),
        append(r, "Core/Util.lua", "\nUtil.NEW_MAP = ns:HasAssets(2)\n"))), key(), 2)
    assert not any("HasAssets" in n for n in notes), notes
    # only docs changed: nothing to send
    refused(record, source_copy("docs", lambda r: (with_art(r), write(r, "README.md", "other docs"))), "nothing changed")


@case
def build_id_identifies_the_release():
    src = source_copy("idsrc")
    a_dir, a = release_of(src)
    b_dir, b = release_of(src)
    assert a["build"] == b["build"] and len(a["build"]) == 16
    assert 'id = "%s"' % a["build"] in read(a_dir, "Core/BuildInfo.lua")
    assert read(a_dir, "Core/Outbox.lua") == patchlib.OUTBOX_STUB
    # the publisher's outbox and build info do not change the id; any other file does
    write(src, "Core/Outbox.lua", "DisasterZoneOutbox = { seq = 1 }\n")
    assert release_of(src)[1]["build"] == a["build"]
    for rel in ("Core/Util.lua", "Libs/LibStub/LibStub.lua", "DisasterZone.toc", "Core/Boot.lua"):
        other = source_copy("idsrc2", lambda r: append(r, rel, "\n"))
        assert release_of(other)[1]["build"] != a["build"], rel
    renamed = source_copy("idsrc3", lambda r: write(r, "Extra.lua", "-- extra\n"))
    assert release_of(renamed)[1]["build"] != a["build"]


@case
def source_is_normalised_for_travel():
    def mods(r):
        text = read(r, "Core/Dungeon.lua").replace("\r\n", "\n")
        write(r, "Core/Dungeon.lua", (text + "\nns.CRLF_MARK = [[a\nb]]\n").replace("\n", "\r\n"))
    base_dir, record, new_dir = simple_pair(new_mods=mods)
    bundle = make(record, new_dir)
    item = [i for i in bundle["items"] if i["path"] == "Core/Dungeon.lua"][0]
    disk = read(new_dir, "Core/Dungeon.lua")
    assert "\r\n" in disk and b"\r" not in item["src"]
    assert item["src"].count(b"\n") == disk.count("\n")                 # same line numbers in error messages
    assert patchlib.inflate_raw(patchlib.decode_for_print(item["z"])) == item["src"]
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir, sv=staged(bundle))
    c.load_addon()
    w.tick(2)
    assert boot_state(c)["state"] == "applied" and c.eval("return ns.CRLF_MARK") == "a\nb"
    w.assert_no_errors()
    for bad in (b"a\rb", b"a\0b", b"a\xff\xfeb"):
        try:
            patchlib.normalize_source(bad)
            raise AssertionError(bad)
        except ValueError:
            pass
    assert patchlib.normalize_source(b"\xef\xbb\xbflocal x\r\n") == b"local x\n"


@case
def outbox_file_round_trips():
    base_dir, record, new_dir = simple_pair(new_mods=lambda r: append(
        r, "Core/Dungeon.lua", '\nns.TRICKY = "]] ]=] \\\\ \\" \\n" .. [==[ ]] ]=] ]==]\n'))
    bundle = make(record, new_dir)
    lua = patchlib.outbox_lua(bundle)
    w = World(addon_dir=base_dir)
    c = member(w, "Alice", base_dir)
    c.load_addon()
    got = c.eval_py("local f = assert(loadstring(...)) f() return { seq = DisasterZoneOutbox.seq, z0 = DisasterZoneOutbox.z0, z = DisasterZoneOutbox.z }", lua)
    assert got["seq"] == 1 and got["z0"] == bundle["z0"]
    assert got["z"] == [i["z"] for i in bundle["items"] if i["kind"] != "D"]
    for s in ("plain", "]]", "a]=]b]]c", "ends with ]", "x]==", ""):
        assert c.eval("return " + patchlib.lua_long_string(s)) == s, s
    w.assert_no_errors()


@case
def staged_fixture_equals_a_real_download():
    """The tests seed DisasterZonePatchDB with patchlib.staged_sv(); it must be what the addon itself stores."""
    def new_mods(r):
        write(r, "Core/TestNew.lua", guard("Core/TestNew.lua") + "-- test\n")
        toc_add(r, "Core/TestNew.lua", "Core/Constants.lua")
        toc_remove(r, "DisasterZone_Azeromon/Sound.lua")
    base_dir, record, new_dir = simple_pair(new_mods=new_mods)
    bundle = make(record, new_dir)
    w = World(addon_dir=base_dir)
    a = member(w, "MemberA", base_dir)
    a.load_addon()
    b = member(w, "MemberB", base_dir, sv=staged(bundle))
    b.load_addon()                                                # (the deleted module makes no difference here)
    with_outbox(new_dir, bundle)
    p = Client(w, "Pub", addon_dir=new_dir)
    p.load_addon()
    w.tick(2)
    p.slash("/dz publish")
    w.run_until(lambda: (patch_status(a).get("ready") or {}).get("seq") == 1, timeout=300)
    real = a.eval_py("return DisasterZonePatchDB.active")
    fixture = b.eval_py("return DisasterZonePatchDB.active")
    published = p.eval_py("return DisasterZonePatchDB.active")
    assert real == fixture, [k for k in real if real[k] != fixture.get(k)]
    assert real == published
    assert a.eval("return DisasterZonePatchDB.seq") == 1


# ---------------------------------------------------------------------------------------------------------------
# The command line, end to end
# ---------------------------------------------------------------------------------------------------------------

class Sandbox:
    """Points release.py at a private copy of the source tree, key folder, release log and dist folder."""

    def __init__(self):
        self.root = _unique("sandbox")
        self.addon = source_copy("sandbox_addon")
        os.remove(os.path.join(self.addon, "Core", "PatchKey.lua"))
        write(self.addon, "Art/map.blp", "BLP2 art")
        self.saved = (release.ADDON_DIR, release.KEY_PATH, release.RELEASES, release.DIST)
        release.ADDON_DIR = self.addon
        release.KEY_PATH = os.path.join(self.root, "keys", "patch_key.json")
        release.RELEASES = os.path.join(self.root, "releases")
        release.DIST = os.path.join(self.root, "dist")

    def close(self):
        release.ADDON_DIR, release.KEY_PATH, release.RELEASES, release.DIST = self.saved

    def run(self, *argv, fails=None):
        try:
            release.main(list(argv))
        except SystemExit as e:
            assert fails, "release.py %s exited with %s" % (" ".join(argv), e.code)
            return
        assert not fails, "release.py %s should have failed" % " ".join(argv)

    def install(self, version):
        """What a member does: unzip the release into the AddOns folder."""
        dst = _unique("installed")
        with zipfile.ZipFile(os.path.join(release.DIST, "DisasterZone-%s.zip" % version)) as zf:
            names = zf.namelist()
            assert all(n.startswith("DisasterZone/") for n in names), names[:3]
            zf.extractall(dst)
        return os.path.join(dst, "DisasterZone")


@case
def command_line_end_to_end():
    sb = Sandbox()
    try:
        sb.run("patch", fails=True)                               # no key yet
        sb.run("full", fails=True)                                # no public key in the tree
        sb.run("keygen", "--height", "2")                         # 3 updates (sequence 1..3)
        sb.run("keygen", "--height", "2", fails=True)             # would orphan every installed copy
        assert "seed" in read(sb.addon, "Core/PatchKey.lua")
        sb.run("patch", fails=True)                               # no base release yet
        set_version(sb.addon, "1.0.0")
        sb.run("full")
        sb.run("full", fails=True)                                # same version again
        record = json.load(open(os.path.join(release.RELEASES, "1.0.0.json"), encoding="utf-8"))
        assert "Art/map.blp" in record["files"] and not record["luaOnly"]
        installed = sb.install("1.0.0")
        assert 'id = "%s"' % record["build"] in read(installed, "Core/BuildInfo.lua")
        assert read(installed, "Core/Outbox.lua") == patchlib.OUTBOX_STUB
        assert read(installed, "Art/map.blp") == "BLP2 art"
        assert read(sb.addon, "Core/BuildInfo.lua").count('id = "dev"') == 1       # the source tree stays "dev"

        w = World(addon_dir=installed)
        m = member(w, "Member", installed)
        m.load_addon()
        w.tick(2)
        assert boot_state(m)["build"] == record["build"] and boot_state(m)["version"] == "1.0.0"

        sb.run("patch", fails=True)                               # nothing changed
        append(sb.addon, "Core/Util.lua", '\nUtil.PATCH_MARK = "cli"\n')
        sb.run("patch", fails=True)                               # version not bumped
        set_version(sb.addon, "1.0.1")
        sb.run("patch")
        assert "DisasterZoneOutbox" in read(sb.addon, "Core/Outbox.lua")
        log = json.load(open(os.path.join(release.RELEASES, "patches.json"), encoding="utf-8"))
        assert [(p["seq"], p["version"], p["base"]) for p in log] == [(1, "1.0.1", "1.0.0")]
        assert patchlib.load_key(release.KEY_PATH)["next"] == 2
        sb.run("status")

        p = Client(w, "Pub", addon_dir=sb.addon)
        p.load_addon()
        w.tick(2)
        p.slash("/dz publish")
        w.run_until(lambda: (patch_status(m).get("ready") or {}).get("seq") == 1, timeout=300)
        m.relog()
        w.tick(3)
        s = boot_state(m)
        assert s["state"] == "applied" and s["version"] == "1.0.1" and s["disk"] == "1.0.0", s
        assert m.eval("return ns.Util.PATCH_MARK") == "cli"

        # the next update is cumulative and gets the next sequence number
        append(sb.addon, "Core/Dungeon.lua", "\nns.SECOND = true\n")
        set_version(sb.addon, "1.0.2")
        sb.run("patch")
        p.relog()
        w.tick(2)
        p.slash("/dz publish")
        w.run_until(lambda: (patch_status(m).get("ready") or {}).get("seq") == 2, timeout=300)
        m.relog()
        w.tick(3)
        assert boot_state(m)["version"] == "1.0.2" and m.eval("return ns.SECOND") is True
        assert m.eval("return ns.Util.PATCH_MARK") == "cli"

        # a revoke uses a sequence number too; then the key is used up (this copy keeps its changes here)
        sb.run("patch", "--revoke", "--keep-source")
        assert "ns.SECOND = true" in read(sb.addon, "Core/Dungeon.lua")
        log = json.load(open(os.path.join(release.RELEASES, "patches.json"), encoding="utf-8"))
        assert [p["seq"] for p in log] == [1, 2, 3] and log[-1]["revoke"] and log[-1]["version"] == "1.0.0"
        p.relog()
        w.tick(2)
        p.slash("/dz publish")
        w.run_until(lambda: (patch_status(m).get("ready") or {}).get("seq") == 3, timeout=300)
        m.relog()
        w.tick(3)
        assert boot_state(m)["version"] == "1.0.0" and m.eval("return ns.SECOND") is None
        set_version(sb.addon, "1.0.3")
        sb.run("patch", fails=True)                               # 2^2 - 1 signatures are spent
        assert patchlib.load_key(release.KEY_PATH)["next"] == 4

        # a new full release empties the outbox and becomes the base; the member who installs it drops the old update
        sb.run("full")
        assert read(sb.addon, "Core/Outbox.lua") == patchlib.OUTBOX_STUB
        new_install = sb.install("1.0.3")
        m.addon_dir = new_install                                 # same character, replaced folder
        m.relog(reload=False)
        w.tick(3)
        s = boot_state(m)
        assert s["state"] == "base" and s["version"] == "1.0.3" and m.eval("return ns.SECOND") is True, s
        assert m.eval("return DisasterZonePatchDB.active") is None and m.eval("return DisasterZonePatchDB.seq") == 3
        w.assert_no_errors()
    finally:
        sb.close()


@case
def revoke_puts_the_publishers_copy_back_too():
    """Taking an update back must not leave the publisher's own copy behind with the change still in it."""
    sb = Sandbox()
    try:
        sb.run("keygen", "--height", "4")
        set_version(sb.addon, "1.0.0")
        write(sb.addon, "README.md", "# DisasterZone 1.0.0\n")
        sb.run("full")
        base = json.load(open(os.path.join(release.RELEASES, "1.0.0.json"), encoding="utf-8"))
        log_path = os.path.join(release.RELEASES, "patches.json")
        pristine = {rel: read(sb.addon, rel) for rel in ("Core/Util.lua", "Core/Dungeon.lua", "DisasterZone.toc", "README.md")}
        assert release.sync_report(base, [], sb.addon)[0] is True

        # an update with a changed, a new and a deleted file, a version bump and a docs change
        append(sb.addon, "Core/Util.lua", '\nUtil.PATCH_MARK = "x"\n')
        write(sb.addon, "Core/TestNew.lua", guard("Core/TestNew.lua") + "-- test\nDisasterZoneTestNew = true\n")
        toc_add(sb.addon, "Core/TestNew.lua", "Core/Constants.lua")
        toc_remove(sb.addon, "DisasterZone_Azeromon/Sound.lua")
        gone = read(sb.addon, "DisasterZone_Azeromon/Sound.lua")
        os.remove(os.path.join(sb.addon, "Games", "Azeromon", "Sound.lua"))
        set_version(sb.addon, "1.0.1")
        write(sb.addon, "README.md", "# DisasterZone 1.0.1\n")
        # art changed without a new art pack: an update would be refused, and the sync check says why
        write(sb.addon, "Art/map.blp", "BLP2 art, edited")
        ok, lines = release.sync_report(base, [], sb.addon)
        assert ok is False and "art changed" in lines[0], lines
        write(sb.addon, "Art/map.blp", "BLP2 art")
        ok, lines = release.sync_report(base, [], sb.addon)
        assert ok is False and any(l.strip() == "Core/Util.lua" for l in lines) and \
            any(l.strip() == "DisasterZone_Azeromon/Sound.lua" for l in lines), lines
        sb.run("patch")
        log = json.load(open(log_path, encoding="utf-8"))
        assert set(log[-1]["sha"]) == {"Core/Util.lua", "Core/TestNew.lua"}
        assert release.sync_report(base, log, sb.addon)[0] is True          # what I have is what members get

        w = World(addon_dir=sb.install("1.0.0"))
        m = member(w, "Member", w.addon_dir)
        m.load_addon()
        p = Client(w, "Pub", addon_dir=sb.addon)
        p.load_addon()
        w.tick(2)
        p.slash("/dz publish")
        w.run_until(lambda: (patch_status(m).get("ready") or {}).get("seq") == 1, timeout=300)
        m.relog()
        w.tick(3)
        assert boot_state(m)["version"] == "1.0.1" and m.eval("return DisasterZoneTestNew") is True
        assert p.eval("return ns.Util.PATCH_MARK") == "x"                    # the publisher sees it too (from disk)

        # work in progress after the update: the copy is ahead of the members
        append(sb.addon, "Core/Dungeon.lua", "\nns.WIP = true\n")
        ok, lines = release.sync_report(base, log, sb.addon)
        assert ok is False and any(l.strip() == "Core/Dungeon.lua" for l in lines) and \
            not any(l.strip() == "Core/Util.lua" for l in lines), lines

        sb.run("patch", "--revoke")
        log = json.load(open(log_path, encoding="utf-8"))
        assert log[-1]["revoke"] is True and log[-1]["files"] == [] and log[-1]["version"] == "1.0.0"
        # every file is back to the release, the new file is gone, the deleted one is back
        for rel, text in pristine.items():
            assert read(sb.addon, rel) == text, rel
        assert not os.path.exists(os.path.join(sb.addon, "Core", "TestNew.lua"))
        assert read(sb.addon, "DisasterZone_Azeromon/Sound.lua") == gone
        assert release.source_differences(base, sb.addon) == []
        assert release.sync_report(base, log, sb.addon)[0] is True
        # what was there is kept
        undone = os.path.join(release.RELEASES, "undone")
        saved = os.path.join(undone, os.listdir(undone)[0])
        assert 'PATCH_MARK = "x"' in read(saved, "Core/Util.lua") and "ns.WIP = true" in read(saved, "Core/Dungeon.lua")
        assert "DisasterZoneTestNew" in read(saved, "Core/TestNew.lua") and "1.0.1" in read(saved, "DisasterZone.toc")
        assert not os.path.exists(os.path.join(saved, "Games", "Azeromon", "Sound.lua"))

        p.relog()
        w.tick(2)
        assert p.eval("return ns.Util.PATCH_MARK") is None and p.eval("return ns.version") == "1.0.0"
        p.slash("/dz publish")
        w.run_until(lambda: (patch_status(m).get("ready") or {}).get("seq") == 2, timeout=300)
        m.relog()
        w.tick(3)
        assert boot_state(m)["version"] == "1.0.0" and m.eval("return DisasterZoneTestNew") is None
        assert m.eval("return ns.Util.PATCH_MARK") is None
        w.assert_no_errors()

        # nothing to take back twice, and nothing to send
        sb.run("patch", fails=True)
        # undoing by hand works as well: the copy equals the release while members run an update with files
        append(sb.addon, "Core/Util.lua", '\nUtil.PATCH_MARK = "y"\n')
        set_version(sb.addon, "1.0.2")
        sb.run("patch")
        write(sb.addon, "Core/Util.lua", pristine["Core/Util.lua"])
        write(sb.addon, "DisasterZone.toc", pristine["DisasterZone.toc"])
        sb.run("patch")                                                       # builds the take-back by itself
        log = json.load(open(log_path, encoding="utf-8"))
        assert [(e["seq"], e["revoke"], e["version"]) for e in log] == \
            [(1, False, "1.0.1"), (2, True, "1.0.0"), (3, False, "1.0.2"), (4, True, "1.0.0")]
        sb.run("status")
    finally:
        sb.close()


@case
def selftest_runs_the_whole_addon_from_the_store_on_the_development_copy():
    sb = Sandbox()
    try:
        sb.run("selftest", fails=True)                            # no key
        sb.run("keygen", "--height", "3")
        set_version(sb.addon, "1.0.0")
        sb.run("selftest")
        # the addon no longer fits one update (1.4: 13.6 MB): parts that each fit, together every patchable file
        parts = release.selftest_parts(sb.addon)
        assert sorted(f for p in parts for f in p) == sorted(release.patchable_files(sb.addon)), parts
        n_files = len(parts[0])
        tag = "1.0.0-selftest" + ("-1of%d" % len(parts) if len(parts) > 1 else "")
        base_dir, record = release_of(sb.addon)
        w = World(addon_dir=sb.addon)
        bystander = member(w, "Member", base_dir)                 # a member on a real release
        bystander.load_addon()
        dev = Client(w, "Dev", addon_dir=sb.addon, guild_rank=0)
        dev.load_addon()
        w.tick(2)
        dev.slash("/dz publish")
        w.run_until(lambda: any("published update " + tag in l for l in dev.chat_frame), timeout=300)
        assert boot_state(dev)["applied"] is None
        dev.slash("/dzpatch try")
        dev.relog()
        w.tick(3)
        s = boot_state(dev)
        assert s["state"] == "applied" and s["applied"]["files"] == n_files and s["version"] == tag, s
        assert s["init"] and s["loggedIn"] and s["errors"] == 0
        lines = dev.eval_py("return DisasterZoneBoot.StatusLines()")
        assert any("running an in-game update: " + tag in l for l in lines), lines
        dev.relog()
        w.tick(3)
        assert boot_state(dev)["state"] == "base" and boot_state(dev)["version"] == "1.0.0"
        w.tick(120)
        st = patch_status(bystander)                              # nobody else picks it up
        assert st.get("ready") is None and st.get("downloading") is None and st.get("held") is None, st
        w.assert_no_errors()
        # a real update afterwards gets the next number and replaces the outbox
        sb.run("full")
        append(sb.addon, "Core/Util.lua", "\n-- change\n")
        set_version(sb.addon, "1.0.1")
        sb.run("patch")
        log = json.load(open(os.path.join(release.RELEASES, "patches.json"), encoding="utf-8"))
        assert [(p["seq"], p["base"]) for p in log] == [(1, "selftest"), (2, "1.0.0")]
    finally:
        sb.close()


@case
def a_lost_counter_cannot_reuse_a_signature():
    """The key file's counter went back (restored from a backup): the release log still pushes the number up."""
    sb = Sandbox()
    try:
        sb.run("keygen", "--height", "3")
        set_version(sb.addon, "1.0.0")
        sb.run("full")
        append(sb.addon, "Core/Util.lua", "\n-- a\n")
        set_version(sb.addon, "1.0.1")
        sb.run("patch")
        k = patchlib.load_key(release.KEY_PATH)
        k["next"] = 1
        patchlib.save_key(release.KEY_PATH, k)
        append(sb.addon, "Core/Util.lua", "\n-- b\n")
        set_version(sb.addon, "1.0.2")
        sb.run("patch")
        log = json.load(open(os.path.join(release.RELEASES, "patches.json"), encoding="utf-8"))
        assert [p["seq"] for p in log] == [1, 2]
        # and the other way round: the log was lost, the key file remembers
        os.remove(os.path.join(release.RELEASES, "patches.json"))
        append(sb.addon, "Core/Util.lua", "\n-- c\n")
        set_version(sb.addon, "1.0.3")
        sb.run("patch")
        log = json.load(open(os.path.join(release.RELEASES, "patches.json"), encoding="utf-8"))
        assert [p["seq"] for p in log] == [3]
    finally:
        sb.close()


if __name__ == "__main__":
    run_all()

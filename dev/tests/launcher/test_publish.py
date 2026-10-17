"""Desktop launcher, part 1: what release.py publishes for it (tools/launchlib.py, release.py launcher-keygen/publish).

Covers: Ed25519 against the RFC 8032 vectors; a published tree checks out (signature, every object, the changelog
notes, the packs read from each folder's TOC); a second release writes only the objects that changed; tampering
(manifest, object, other key) is caught; publish refuses a zip that is not the release's, a missing key, and taking a
channel back without --force; the pack rules (TOC lines, folder names, the zip's read-me).
Never touches the real keys, releases or dist folders: every path release.py writes is pointed into a temp folder.

Run: luaenv\\Scripts\\python.exe tests\\launcher\\test_publish.py [-k name]
"""
import contextlib
import gzip
import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(DEV, "tests", "boot-ui"))
sys.path.insert(0, os.path.join(DEV, "tools"))

from _common import case, run_all  # noqa: E402
import launchlib  # noqa: E402
import release  # noqa: E402

TMP = tempfile.mkdtemp(prefix="dzlaunch_")

# A game pack's TOC as release.py writes it (CRLF, like the 3D rooms' TOC).
CHESS_TOC = ("## Interface: 20506\r\n## Title: |cffff8000Disaster|rZone \u00b7 Karazhan Chess\r\n"
             "## Notes: Play Medivh's echo, or a guildmate.\r\n## Dependencies: DisasterZone\r\n"
             "## X-DZ-Pack: chess\r\n## X-DZ-Kind: game\r\n## X-DZ-Build: 0123abcd\r\n\r\nLoad.lua\r\nChess.lua\r\n"
             "Done.lua\r\n")

# release.py hands publish the folders it finds next to the addon (the packs branch); until it does, publish here
# reads every folder the test's zip holds.
_read_zip_tree = launchlib.read_zip_tree


def _every_folder(zip_path, folders):
    with zipfile.ZipFile(zip_path) as zf:
        tops = {n.partition("/")[0] for n in zf.namelist() if "/" in n}
    return _read_zip_tree(zip_path, list(folders) + sorted(tops - set(folders)))


launchlib.read_zip_tree = _every_folder

CHANGELOG = """local addonName, ns = ...
ns.CHANGELOG = {
    { version = "%s", date = "1 May", title = "Title %s", sections = {
        { heading = "Raids", kind = "new", area = "raids", lead = "Lead.", lines = {
            "Plain line.", { "Officer line.", ["for"] = "officers" } } } } },
    { version = "0.9", date = "1 April", title = "Old", sections = {} },
}
"""


def sandbox(name):
    """Point every path release.py writes into a fresh folder; returns that folder."""
    root = os.path.join(TMP, name)
    os.makedirs(root)
    release.RELEASES = os.path.join(root, "releases")
    release.DIST = os.path.join(root, "dist")
    release.LAUNCHER_KEY_PATH = os.path.join(root, "keys", "launcher_key.json")
    release.LAUNCHER_DIR = os.path.join(root, "launcher")
    release.LAUNCHER_PUBKEY = os.path.join(root, "launcher", "release_key.json")
    release.PUBLISH_CONF = os.path.join(release.RELEASES, "publish.json")
    release.PUBLISHED_LOG = os.path.join(release.RELEASES, "published.json")
    os.makedirs(release.RELEASES)
    os.makedirs(release.DIST)
    return root


def fake_release(version, build, files=None, rooms=None, zip_build=None, games=None):
    """A release record + dist zip as 'release.py full' leaves them (only what publish reads). games: {folder:
    {path: text}}, by default one game pack (Chess)."""
    files = dict(files or {})
    files.setdefault("Core/BuildInfo.lua", 'DisasterZoneBuild = {\n    id = "%s",\n    assetPack = 3,\n}\n'
                     % (zip_build or build))
    files.setdefault("Data/Changelog.lua", CHANGELOG % (version, version))
    files.setdefault("DisasterZone.toc", "## Title: |cffff8000Disaster|rZone\n## Version: %s\n" % version)
    # (the 3D rooms' TOC without the pack lines: an older Rooms TOC still reads as the rooms Extra)
    rooms = rooms if rooms is not None else {"DisasterZone_Rooms.toc": "## LoadOnDemand: 1\n", "Rooms/A.lua": "-- a\n"}
    games = games if games is not None else {
        "DisasterZone_Chess": {"DisasterZone_Chess.toc": CHESS_TOC, "Chess.lua": "-- chess\n"}}
    with zipfile.ZipFile(os.path.join(release.DIST, "DisasterZone-%s.zip" % version), "w") as zf:
        zf.writestr("Read me.txt", "Replace the folders, don't paste over them.\n")
        for rel, text in files.items():
            zf.writestr("DisasterZone/" + rel, text)
        for rel, text in rooms.items():
            zf.writestr("DisasterZone_Rooms/" + rel, text)
        for folder, tree in games.items():
            for rel, text in tree.items():
                zf.writestr(folder + "/" + rel, text)
    with open(os.path.join(release.RELEASES, "%s.json" % version), "w") as fh:
        json.dump({"version": version, "build": build, "assetPack": 3, "files": {}, "commit": "c0ffee"}, fh)
    with open(os.path.join(release.RELEASES, "base.json"), "w") as fh:
        json.dump({"version": version}, fh)


def run(*argv):
    """release.main(argv) with output captured: (exit code, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    code = 0
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            release.main(list(argv))
        except SystemExit as e:
            code = e.code or 0
    return code, out.getvalue(), err.getvalue()


def ok(*argv):
    code, out, err = run(*argv)
    assert code == 0, (argv, out, err)
    return out


def refused(*argv, needle):
    code, out, err = run(*argv)
    assert code != 0, ("accepted", argv, out)
    assert needle in err, (needle, err)


def pub_key():
    return json.load(open(release.LAUNCHER_PUBKEY))["public"]


def manifest(out, channel="stable"):
    return json.load(open(os.path.join(out, "channels", channel + ".json")))


@case
def ed25519_matches_the_rfc_vectors():
    seed = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
    pub = launchlib.public_key(seed)
    assert pub.hex() == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    sig = launchlib.sign(seed, b"")
    assert sig.hex() == ("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701c"
                         "f9b46bd25bf5f0595bbe24655141438e7a100b")
    assert launchlib.verify(pub, b"", sig)
    assert not launchlib.verify(pub, b"x", sig)
    seed = bytes.fromhex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
    sig = launchlib.sign(seed, b"\x72")
    assert sig.hex() == ("92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0"
                         "f11d8c387b2eaeb4302aeeb00d291612bb0c00")
    bad = bytearray(sig)
    bad[63] ^= 0x10
    assert not launchlib.verify(launchlib.public_key(seed), b"\x72", bytes(bad))


@case
def keygen_writes_the_private_key_and_the_launchers_public_key():
    sandbox("keygen")
    ok("launcher-keygen")
    key = launchlib.load_key(release.LAUNCHER_KEY_PATH)
    pub = json.load(open(release.LAUNCHER_PUBKEY))
    assert pub == {"id": key["id"], "public": key["public"]}, pub
    assert "seed" not in pub
    refused("launcher-keygen", needle="exists")
    ok("launcher-keygen", "--force")
    assert json.load(open(release.LAUNCHER_PUBKEY))["id"] != key["id"]


@case
def a_published_tree_checks_out():
    root = sandbox("tree")
    ok("launcher-keygen")
    fake_release("1.0.0", "b1", {"Core/A.lua": "-- a\n" * 50, "Media/x.tga": b"\x00\x01" * 100})
    out = os.path.join(root, "pub")
    text = ok("publish", "--out", out)
    assert "seq 1" in text, text
    m = manifest(out)
    assert (m["format"], m["channel"], m["seq"], m["version"], m["build"], m["assetPack"]) == (
        2, "stable", 1, "1.0.0", "b1", 3), m
    assert sorted(m["folders"]) == ["DisasterZone", "DisasterZone_Chess", "DisasterZone_Rooms"]
    assert "Read me.txt" not in json.dumps(m["folders"])
    assert m["packs"] == [
        {"id": "core", "folder": "DisasterZone", "kind": "core", "title": "DisasterZone", "tagline": "",
         "required": True, "defaultOn": True},
        {"id": "rooms", "folder": "DisasterZone_Rooms", "kind": "extra", "title": "3D rooms", "tagline": "",
         "required": False, "defaultOn": True},
        {"id": "chess", "folder": "DisasterZone_Chess", "kind": "game", "title": "Karazhan Chess",
         "tagline": "Play Medivh's echo, or a guildmate.", "required": False, "defaultOn": False},
    ], m["packs"]
    a = m["folders"]["DisasterZone"]["Core/A.lua"]
    assert a["size"] == 250 and a["sha256"] == hashlib.sha256(b"-- a\n" * 50).hexdigest(), a
    assert "Rooms/A.lua" in m["folders"]["DisasterZone_Rooms"]
    blob = open(os.path.join(out, *launchlib.object_path(a["sha256"]).split("/")), "rb").read()
    assert len(blob) == a["gz"] and gzip.decompress(blob) == b"-- a\n" * 50
    assert launchlib.verify_tree(out, "stable", pub_key()) == []
    notes = m["notes"]["changelog"]
    assert [e["version"] for e in notes] == ["1.0.0", "0.9"], notes
    assert notes[0]["sections"][0]["lines"] == ["Plain line.", {"text": "Officer line.", "for": "officers"}], notes
    assert m["zip"]["name"] == "DisasterZone-1.0.0.zip" and "url" not in m["zip"]       # (no repo: a local tree)


@case
def a_second_release_writes_only_what_changed():
    root = sandbox("delta")
    ok("launcher-keygen")
    out = os.path.join(root, "pub")
    big = "-- big file\n" * 2000
    fake_release("1.0.0", "b1", {"Core/A.lua": "-- one\n", "Core/Big.lua": big})
    ok("publish", "--out", out)
    fake_release("1.0.1", "b2", {"Core/A.lua": "-- two\n", "Core/Big.lua": big})
    text = ok("publish", "--out", out)
    # A.lua, BuildInfo (new build id), Changelog and the TOC (new version) changed; Big.lua and the rooms did not
    assert "seq 2" in text and "4 new object(s)" in text, text
    m = manifest(out)
    assert m["version"] == "1.0.1" and m["seq"] == 2
    assert launchlib.verify_tree(out, "stable", pub_key()) == []


@case
def channels_are_separate_files():
    root = sandbox("channels")
    ok("launcher-keygen")
    out = os.path.join(root, "pub")
    fake_release("1.0.0", "b1")
    ok("publish", "--out", out)
    fake_release("1.1.0", "b2")
    ok("publish", "--out", out, "--channel", "beta")
    assert manifest(out)["version"] == "1.0.0"
    assert manifest(out, "beta")["version"] == "1.1.0" and manifest(out, "beta")["channel"] == "beta"
    assert manifest(out, "beta")["seq"] > manifest(out)["seq"]


@case
def tampering_is_caught():
    root = sandbox("tamper")
    ok("launcher-keygen")
    out = os.path.join(root, "pub")
    fake_release("1.0.0", "b1", {"Core/A.lua": "-- a\n"})
    ok("publish", "--out", out)
    pub = pub_key()
    path = os.path.join(out, "channels", "stable.json")
    data = open(path, "rb").read()
    sig = open(path + ".sig", "rb").read()
    assert launchlib.check_signature(pub, data, sig)
    assert not launchlib.check_signature(pub, data.replace(b'"1.0.0"', b'"1.0.1"'), sig)
    other = launchlib.keygen()
    assert not launchlib.check_signature(other["public"], data, sig)
    forged = launchlib.signature_bytes(other, data)
    assert not launchlib.check_signature(pub, data, forged)
    # a swapped object
    sha = manifest(out)["folders"]["DisasterZone"]["Core/A.lua"]["sha256"]
    obj = os.path.join(out, *launchlib.object_path(sha).split("/"))
    with open(obj, "wb") as fh:
        fh.write(launchlib.gz(b"-- evil\n"))
    assert any("Core/A.lua" in p for p in launchlib.verify_tree(out, "stable", pub))


@case
def publish_refuses_what_it_should():
    root = sandbox("refuse")
    out = os.path.join(root, "pub")
    fake_release("1.0.0", "b1")
    refused("publish", "--out", out, needle="launcher-keygen")
    ok("launcher-keygen")
    fake_release("1.0.0", "b1", zip_build="other")
    refused("publish", "--out", out, needle="does not carry build b1")
    refused("publish", "--out", out, "--version", "2.0.0", needle="missing")
    fake_release("1.0.0", "b1")
    refused("publish", needle="--repo")                                  # (no repository remembered yet)
    # taking a channel back: an earlier publish to the repository is recorded in the log
    with open(release.PUBLISHED_LOG, "w") as fh:
        json.dump([{"seq": 4, "channel": "stable", "version": "1.2.0", "build": "x", "time": ""}], fh)
    refused("publish", "--out", out, needle="takes everybody back")
    text = ok("publish", "--out", out, "--force")
    assert "seq 5" in text, text


@case
def full_with_publish_hands_the_new_release_to_publish():
    sandbox("fullpub")
    seen = []
    real = release.cmd_publish
    release.cmd_publish = lambda a: seen.append((a.version, a.channel, a.out, a.force))
    try:
        release.publish_after_full("1.4.0", "beta")
    finally:
        release.cmd_publish = real
    assert seen == [("1.4.0", "beta", None, False)], seen
    # the command line: --publish and --channel reach cmd_full (which is not run here)
    got = []
    real_full = release.cmd_full
    release.cmd_full = got.append
    try:
        release.main(["full", "--publish", "--channel", "beta"])
        release.main(["full"])
    finally:
        release.cmd_full = real_full
    assert (got[0].publish, got[0].channel) == (True, "beta"), got[0]
    assert (got[1].publish, got[1].channel) == (False, "stable"), got[1]


@case
def packs_come_from_the_tocs():
    toc = lambda *lines: ("\r\n".join(lines) + "\r\n").encode()
    core = {"DisasterZone.toc": toc("## Title: |cffff8000Disaster|rZone", "## Notes: Loot council.")}
    tree = {"DisasterZone": core,
            "DisasterZone_Rooms": {"DisasterZone_Rooms.toc": toc("## Title: |cffff8000Disaster|rZone 3D rooms",
                                                                  "## X-DZ-Pack: rooms", "## X-DZ-Kind: extra")},
            "DisasterZone_Azeromon": {"DisasterZone_Azeromon.toc": toc(
                "## Title: |cffff8000Disaster|rZone \u00b7 Azeromon", "## Notes: Tame and battle.",
                "##  x-dz-pack : azeromon", "## X-DZ-Kind: game")}}
    packs = launchlib.pack_list(tree)
    assert [(p["id"], p["kind"], p["title"], p["defaultOn"]) for p in packs] == [
        ("core", "core", "DisasterZone", True), ("rooms", "extra", "3D rooms", True),
        ("azeromon", "game", "Azeromon", False)], packs
    assert packs[0]["tagline"] == "Loot council." and packs[0]["required"]

    def refuses(extra, needle):
        bad = dict(tree, **extra)
        try:
            launchlib.pack_list(bad)
        except ValueError as e:
            assert needle in str(e), (needle, str(e))
            return
        raise AssertionError("accepted: %s" % sorted(extra))
    refuses({"DisasterZone_Chess": {"DisasterZone_Chess.toc": toc("## X-DZ-Kind: game")}}, "X-DZ-Pack")
    refuses({"DisasterZone_Chess": {"DisasterZone_Chess.toc": toc("## X-DZ-Pack: chess", "## X-DZ-Kind: core")}},
            "X-DZ-Kind")
    refuses({"DisasterZone_Chess": {"DisasterZone_Chess.toc": toc("## X-DZ-Pack: Ch ess", "## X-DZ-Kind: game")}},
            "bad pack id")
    refuses({"DisasterZone_Chess": {"DisasterZone_Chess.toc": toc("## X-DZ-Pack: azeromon", "## X-DZ-Kind: game")}},
            "two folders")
    refuses({"DisasterZone_Chess": {"Chess.lua": b"-- no toc"}}, "has no DisasterZone_Chess.toc")
    refuses({"DisasterZone-Chess": {"DisasterZone-Chess.toc": toc("## X-DZ-Pack: chess")}}, "release folder")
    refuses({"DisasterZone_Bridge": {"DisasterZone_Bridge.toc": toc("## X-DZ-Pack: bridge")}}, "release folder")
    try:
        launchlib.pack_list({"DisasterZone_Rooms": tree["DisasterZone_Rooms"]})
        raise AssertionError("a release without the core")
    except ValueError as e:
        assert "needs the DisasterZone folder" in str(e), e


@case
def the_zip_may_hold_only_its_folders_and_the_read_me():
    root = sandbox("zipshape")
    path = os.path.join(root, "x.zip")
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("Read me.txt", "hi")
        zf.writestr("DisasterZone/DisasterZone.toc", "## Title: x\n")
        zf.writestr("DisasterZone_Chess/Chess.lua", "-- c\n")
    tree = _read_zip_tree(path, ["DisasterZone", "DisasterZone_Chess", "DisasterZone_Rooms"])
    assert sorted(tree) == ["DisasterZone", "DisasterZone_Chess"], tree      # (an empty folder is left out)
    try:
        _read_zip_tree(path, ["DisasterZone"])
        raise AssertionError("a folder nobody listed was accepted")
    except ValueError as e:
        assert "unexpected entry DisasterZone_Chess/Chess.lua" in str(e), e
    with zipfile.ZipFile(path, "a") as zf:
        zf.writestr("notes.txt", "stray")
    try:
        _read_zip_tree(path, ["DisasterZone", "DisasterZone_Chess"])
        raise AssertionError("a stray root file was accepted")
    except ValueError as e:
        assert "unexpected entry notes.txt" in str(e), e


@case
def verify_tree_checks_the_packs_match_the_folders():
    root = sandbox("packcheck")
    ok("launcher-keygen")
    out = os.path.join(root, "pub")
    fake_release("1.0.0", "b1")
    ok("publish", "--out", out)
    key = launchlib.load_key(release.LAUNCHER_KEY_PATH)
    m = manifest(out)
    m["packs"] = [p for p in m["packs"] if p["id"] != "chess"]
    launchlib.write_tree(out, m, {}, key)
    assert any("don't match the folders" in p for p in launchlib.verify_tree(out, "stable", key["public"]))


@case
def objects_are_deterministic():
    assert launchlib.gz(b"same bytes" * 10) == launchlib.gz(b"same bytes" * 10)


if __name__ == "__main__":
    try:
        run_all()
    finally:
        shutil.rmtree(TMP, ignore_errors=True)

"""Desktop launcher, part 1: what release.py publishes for it (tools/launchlib.py, release.py launcher-keygen/publish).

Covers: Ed25519 against the RFC 8032 vectors; a published tree checks out (signature, every object, the changelog
notes); a second release writes only the objects that changed; tampering (manifest, object, other key) is caught;
publish refuses a zip that is not the release's, a missing key, and taking a channel back without --force.
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


def fake_release(version, build, files=None, rooms=None, zip_build=None):
    """A release record + dist zip as 'release.py full' leaves them (only what publish reads)."""
    files = dict(files or {})
    files.setdefault("Core/BuildInfo.lua", 'DisasterZoneBuild = {\n    id = "%s",\n    assetPack = 3,\n}\n'
                     % (zip_build or build))
    files.setdefault("Data/Changelog.lua", CHANGELOG % (version, version))
    files.setdefault("DisasterZone.toc", "## Version: %s\n" % version)
    rooms = rooms if rooms is not None else {"DisasterZone_Rooms.toc": "## LoadOnDemand: 1\n", "Rooms/A.lua": "-- a\n"}
    with zipfile.ZipFile(os.path.join(release.DIST, "DisasterZone-%s.zip" % version), "w") as zf:
        for rel, text in files.items():
            zf.writestr("DisasterZone/" + rel, text)
        for rel, text in rooms.items():
            zf.writestr("DisasterZone_Rooms/" + rel, text)
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
        1, "stable", 1, "1.0.0", "b1", 3), m
    assert sorted(m["folders"]) == ["DisasterZone", "DisasterZone_Rooms"]
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
def objects_are_deterministic():
    assert launchlib.gz(b"same bytes" * 10) == launchlib.gz(b"same bytes" * 10)


if __name__ == "__main__":
    try:
        run_all()
    finally:
        shutil.rmtree(TMP, ignore_errors=True)

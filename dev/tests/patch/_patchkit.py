"""Shared helpers for the in-game update ("hot patch") suites.

The suites never touch the real addon folder: they work on copies of its .toc + .lua files in a temp folder.
  source_copy(name, mods)   a copy of the source tree (build id "dev"), optionally edited: the "new version"
  release_of(src, name)     a packaged release of such a copy (own build id): what a member has installed
  make(base_record, new)    the signed in-game update that turns that release into the new version
A small test key (16 signatures) replaces the real public key in every copy.
"""
import atexit
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
DEV = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(DEV, "tools"))
# these suites build their own trees: the overrides of tools/patched_run.py do not apply to them
os.environ.pop("DISASTERZONE_ADDON_DIR", None)
os.environ.pop("DISASTERZONE_PATCH_SV", None)

from _common import case, run_all  # noqa: E402,F401
from harness import World, Client, LuaErrorsFound, LuaEvalError  # noqa: E402,F401
import patchlib  # noqa: E402
import release  # noqa: E402

SOURCE = release.ADDON_DIR
TMP = tempfile.mkdtemp(prefix="cdlpatch_")
atexit.register(lambda: shutil.rmtree(TMP, ignore_errors=True))

_KEYS = {}
_PRISTINE = None
_COUNTER = [0]


def key(name="main"):
    """A deterministic test signing key (16 signatures); other names give unrelated keys."""
    if name not in _KEYS:
        secret = (name.encode("ascii") * 32)[:32]
        seed = (name.encode("ascii")[::-1] * 16)[:16]
        _KEYS[name] = patchlib.keygen(4, secret=secret, seed=seed)
    return _KEYS[name]


def _unique(name):
    _COUNTER[0] += 1
    return os.path.join(TMP, "%s_%d" % (name, _COUNTER[0]))


def _pristine():
    global _PRISTINE
    if _PRISTINE is None:
        dst = os.path.join(TMP, "_pristine")
        for rel in release.all_files(SOURCE):
            if not rel.endswith((".lua", ".toc")) or release.is_room_data(rel):     # (the 3D rooms: ~12 MB a copy)
                continue
            target = os.path.join(dst, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copyfile(os.path.join(SOURCE, rel), target)
        write(dst, "Core/Outbox.lua", patchlib.OUTBOX_STUB)
        write(dst, "Core/PatchKey.lua", release.patch_key_lua(key()))
        write(dst, "Core/BuildInfo.lua", 'DisasterZoneBuild = {\n    id = "dev",\n    assetPack = 1,\n}\n')
        _PRISTINE = dst
        _PRISTINE_STAT.update(_stat_tree(dst))
    elif _stat_tree(_PRISTINE) != _PRISTINE_STAT:
        # some case wrote INTO a file of a hard-linked copy (see source_copy): every later copy would carry it
        changed = sorted(k for k, v in _stat_tree(_PRISTINE).items() if _PRISTINE_STAT.get(k) != v)
        raise AssertionError("_patchkit: the pristine tree changed through a hard link: %s" % ", ".join(changed[:5]))
    return _PRISTINE


_PRISTINE_STAT = {}


def _stat_tree(root):
    out = {}
    for d, _, files in os.walk(root):
        for f in files:
            st = os.stat(os.path.join(d, f))
            out[os.path.join(d, f)] = (st.st_size, st.st_mtime_ns)
    return out


def read(root, rel):
    return release.read(os.path.join(root, rel)).decode("utf-8")      # (kept by file identity: copies are links)


def write(root, rel, text):
    """Replaces the file (never writes into it: copies are hard links to the pristine tree, see source_copy)."""
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    release._put(path, text.encode("utf-8"))


def append(root, rel, text):
    write(root, rel, read(root, rel) + text)


def replace(root, rel, old, new, count=1):
    src = read(root, rel)
    assert src.count(old) == count, "%s: %r found %d time(s)" % (rel, old, src.count(old))
    write(root, rel, src.replace(old, new))


def set_version(root, version):
    import re
    src = read(root, "DisasterZone.toc")
    write(root, "DisasterZone.toc", re.sub(r"## Version: [^\r\n]*", "## Version: " + version, src, count=1))


def toc_add(root, rel, after):
    """List a file in the TOC right after `after` (paths with forward slashes)."""
    src = read(root, "DisasterZone.toc")
    eol = "\r\n" if "\r\n" in src else "\n"
    line = after.replace("/", "\\")
    assert src.count(line + eol) == 1, after
    write(root, "DisasterZone.toc", src.replace(line + eol, line + eol + rel.replace("/", "\\") + eol))


def toc_remove(root, rel):
    src = read(root, "DisasterZone.toc")
    eol = "\r\n" if "\r\n" in src else "\n"
    line = rel.replace("/", "\\") + eol
    assert src.count(line) == 1, rel
    write(root, "DisasterZone.toc", src.replace(line, ""))


def guard(rel):
    return 'if DisasterZoneBoot and DisasterZoneBoot.Run("%s", ...) then return end ' % rel


def source_copy(name="src", mods=None, version=None):
    """A copy of the source tree; mods(root) edits it. The files are hard links to the pristine tree: a fresh copy
    of ~400 files cost seconds in virus scans on first read, every case. So nothing may write into a file of a copy:
    write() and release.py replace files instead."""
    dst = _unique(name)
    shutil.copytree(_pristine(), dst, copy_function=os.link)
    if version:
        set_version(dst, version)
    if mods:
        mods(dst)
    return dst


def release_of(src, name="rel", build=None):
    """Package `src` as a release (what a member installs). Returns (folder, release record)."""
    dst = _unique(name)
    record = release.stage_tree(src, dst, lua_only=True, build=build, link=True)
    return dst, record


def make(base_record, new_dir, seq=1, revoke=False, signing_key=None):
    bundle, notes = release.make_patch(base_record, new_dir, signing_key or key(), seq, revoke=revoke)
    return bundle


def with_outbox(new_dir, bundle):
    """Write the publisher's outbox into the (development) tree it was built from."""
    write(new_dir, "Core/Outbox.lua", patchlib.outbox_lua(bundle))
    return new_dir


def staged(bundle, extra=None):
    return patchlib.staged_sv(bundle, extra)


def simple_pair(mark="v2", version="9.9.9", base_mods=None, new_mods=None):
    """The usual fixture: a base release, and a new version whose Core/Util.lua sets ns.Util.PATCH_MARK = mark.
    Returns (base_dir, base_record, new_dir)."""
    src = source_copy("basesrc", base_mods)
    base_dir, record = release_of(src)

    def mods(root):
        if base_mods:
            base_mods(root)
        append(root, "Core/Util.lua", '\nUtil.PATCH_MARK = "%s"\n' % mark)
        if new_mods:
            new_mods(root)
    new_dir = source_copy("newsrc", mods, version=version)
    return base_dir, record, new_dir


def boot_state(c):
    out = dict.fromkeys(("state", "detail", "applied", "safe", "sv", "build", "errors", "version", "disk", "init",
                         "loggedIn"))
    out.update(_boot_state(c))
    return out


def _boot_state(c):
    return c.eval_py("""local B = DisasterZoneBoot
      return { state = B.state, detail = B.detail, applied = B.applied, safe = B.safeMode, sv = B.svFirst,
               build = B.buildId, errors = B.startupErrors, version = ns.version, disk = ns.diskVersion,
               init = ns.initialized, loggedIn = ns.loggedIn }""")


def patch_status(c):
    return c.eval_py("return ns.Patch:GetStatus()")


def member(w, name, addon_dir, sv=None, **kw):
    c = Client(w, name, addon_dir=addon_dir, **kw)
    if sv is not None:
        c.set_saved_variable("DisasterZonePatchDB", sv)
    return c


# ---------------------------------------------------------------------------------------------------------------
# Transfer helpers (net and scale suites)
# ---------------------------------------------------------------------------------------------------------------

import random  # noqa: E402

PREFIXES = ("CDLp1", "CDLp2", "CDLp3", "CDLp4")


def text_of(entry):
    t = entry["text"]
    return t.decode("latin-1") if isinstance(t, bytes) else t


def patch_msgs(w, kind=None, sender=None):
    out = []
    for e in w.addon_log:
        if e["prefix"] in PREFIXES:
            t = text_of(e)
            if (kind is None or t.startswith(kind + ":")) and (sender is None or e["sender"].startswith(sender)):
                out.append(e)
    return out


def is_ready(c, seq=1):
    r = patch_status(c).get("ready")
    return bool(r) and r["seq"] == seq


def wait_ready(w, clients, seq=1, timeout=180):
    w.run_until(lambda: all(is_ready(c, seq) for c in clients), timeout=timeout)
    w.tick(1)                                                     # (the "ready" notice is debounced)
    for c in clients:
        assert is_ready(c, seq), (c.name, patch_status(c))


def big_mods(n_bytes=60000, seed=5):
    """Makes the update large enough to need a few hundred chunks (text that compresses badly)."""
    rng = random.Random(seed)
    words = ["".join(rng.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(12)) for _ in range(n_bytes // 16)]

    def mods(root):
        lines = ['\nUtil.PATCH_BLOB = {']
        for i in range(0, len(words), 6):
            lines.append("  " + ", ".join('"%s"' % x for x in words[i:i + 6]) + ",")
        lines.append("}\n")
        append(root, "Core/Util.lua", "\n".join(lines))
        append(root, "Core/Dungeon.lua", "\nns.PATCH_SECOND_FILE = true\n")
    return mods

"""Runs the test suites with the WHOLE addon delivered as an in-game update.

    luaenv\\Scripts\\python.exe tools\\patched_run.py [substring filters...]

It builds a "shadow" release in a temp folder in which every patchable file on disk is only its guard line plus
`error("the disk copy ran")`, builds an update that carries the current source of all those files, stores it the
way a finished download does (CDLootPatchDB) and points the harness at the shadow release (CDLOOT_ADDON_DIR /
CDLOOT_PATCH_SV, see tools/harness.py). Then tf_e/run_all.py runs as usual, output in tf_e/patched/.

Every suite must give the same result as a normal run: that proves the addon behaves the same when its code comes
from the update path (loadstring of stored text, the boot loader's ordering) as when it comes from disk.
The tests/patch suites ignore the two variables (they build their own trees).
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import patchlib  # noqa: E402
import release  # noqa: E402


def build(tmp):
    src = os.path.join(tmp, "src")
    for rel in release.all_files(release.ADDON_DIR):
        if rel.endswith((".lua", ".toc")):
            target = os.path.join(src, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copyfile(os.path.join(release.ADDON_DIR, rel), target)
    files = release.patchable_files(src)
    for rel in files:
        if rel == "Core/PatchKey.lua":
            continue
        with open(os.path.join(src, rel), "wb") as fh:
            fh.write(release.guard_for(rel) + b"\nerror('the disk copy of " + rel.encode("ascii") + b" ran')\n")
    base_dir = os.path.join(tmp, "CDLoot")
    record = release.stage_tree(src, base_dir, lua_only=True)
    key = patchlib.keygen(2)
    bundle, notes = release.make_patch(record, release.ADDON_DIR, key, 1)
    assert len(bundle["items"]) == len(files) - 1, (len(bundle["items"]), len(files))
    sv = os.path.join(tmp, "CDLootPatchDB.lua")
    with open(sv, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(patchlib.staged_sv(bundle))
    return base_dir, sv, bundle


def main():
    tmp = tempfile.mkdtemp(prefix="cdlshadow_")
    try:
        base_dir, sv, bundle = build(tmp)
        print("shadow release in %s: %d files travel as an update (%d KB of source)" % (
            base_dir, len(bundle["items"]), bundle["total"] // 1024))
        env = dict(os.environ, CDLOOT_ADDON_DIR=base_dir, CDLOOT_PATCH_SV=sv)
        py = os.path.join(DEV, "luaenv", "Scripts", "python.exe")
        rc = subprocess.call([py, os.path.join(DEV, "tf_e", "run_all.py"), "patched"] + sys.argv[1:], cwd=DEV, env=env)
        sys.exit(rc)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()

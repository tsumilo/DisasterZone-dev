"""DisasterZone release tool: full releases (a zip to download) and in-game updates (patches sent over the guild channel).

Run from C:\\Users\\emilo\\CDLoot-dev\\dev with luaenv\\Scripts\\python.exe:

  tools\\release.py keygen             once: creates the signing key (dev\\keys\\patch_key.json, never committed)
                                      and writes its public half to the addon (Core\\PatchKey.lua)
  tools\\release.py guards add|remove|check
                                      the line-1 guard every patchable file needs (see Core\\Boot.lua)
  tools\\release.py full               package the addon folder as dist\\DisasterZone-<version>.zip and make that
                                      release the base for in-game updates
  tools\\release.py full --publish [--channel beta]
                                      the same, then publish it for the desktop launcher in one go
  tools\\release.py patch              build + sign an in-game update with everything that changed since the
                                      base release and write it to Core\\Outbox.lua; then in game: /reload,
                                      /dz publish
  tools\\release.py patch --revoke     take the update back: everybody goes back to the base release, and so does
                                      this copy (the changed files are put back from the release zip; the versions
                                      you had are kept in dev\\releases\\undone\\). --keep-source leaves this
                                      copy alone, for when you want to fix the change and send it again.
  tools\\release.py status             base release, last update, what changed since the base
  tools\\release.py selftest [--part N] an update that carries every patchable file, addressed to no real build, to
                                      try the whole mechanism in the real client on the development copy. In game:
                                      /reload, /dz publish, /dzpatch try, /reload, /dzpatch (must say "running
                                      an in-game update"), /reload to go back. Members ignore it. The addon no
                                      longer fits one update (4 MB / 1.5 MB encoded): it comes in parts, run each.
  tools\\release.py launcher-keygen    once: the desktop launcher's signing key (dev\\keys\\launcher_key.json, never
                                      committed); its public half goes to launcher\\release_key.json
  tools\\release.py publish [--channel stable|beta] [--version V] [--repo owner/name]
                                      put a full release (default: the base) where the desktop launcher finds it:
                                      the public releases repository (commit, push, GitHub release with the zip).
                                      --out DIR writes the same tree to a folder instead (no git). See launchlib.py.
  tools\\release.py launcher-push      copy launcher\\ into the releases repository and push tag launcher-v<version>:
                                      GitHub Actions builds the Windows / macOS / Linux installers

What an in-game update can carry: changed, new and deleted Lua files that the TOC lists (except Libs\\ and the boot
files). What it cannot: art, the TOC header, libraries, Core\\Boot.lua, the 3D room data (the load-on-demand addon
DisasterZone_Rooms next to the addon folder: the zip carries both folders, and the build id covers both). `patch` refuses those and says a full
release is needed; for art it accepts the change when Core\\BuildInfo.lua's assetPack was raised (the code that
needs the new art must check ns:HasAssets(n)).
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
REPO = os.path.dirname(DEV)
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import patchlib  # noqa: E402
import launchlib  # noqa: E402

ADDON_NAME = "DisasterZone"
ADDON_DIR = os.path.join(REPO, "addon", ADDON_NAME)
# The 3D room data: an addon of its own, loaded on demand (Render3D/Rooms.lua R3.LoadData), shipped in the same zip.
ROOMS_NAME = "DisasterZone_Rooms"
KEY_PATH = os.path.join(DEV, "keys", "patch_key.json")
RELEASES = os.path.join(DEV, "releases")
DIST = os.path.join(REPO, "dist")

PROTECTED = ("Core/Boot.lua", "Core/BuildInfo.lua", "Core/BootEnd.lua", "Core/Outbox.lua", "Core/DevPlan.lua")
TOOL_MANAGED = ("Core/BuildInfo.lua", "Core/Outbox.lua", "Core/DevPlan.lua")   # rewritten per release: not part of the build id
# The developer's release plan (dev/tools/feedback.py plan writes it on the developer's machine): a release ships it empty.
DEVPLAN_STUB = ("-- DisasterZone: the developer's release plan from the dev kit (dev/tools/feedback.py plan writes it; the\n"
                "-- developer's client takes it in at /reload, Core/FeedbackPlan.lua). Never shipped: a release keeps this empty.\n")
DOC_EXT = (".md", ".txt")
# The loose-model probe (dev/generators/gen_probe.py): test files for one in-game session on the development copy.
# Never part of a release or an update, so the tree walk below does not see them at all.
DEV_ONLY = ("Media/Probe/",)
GUARD_RE = re.compile(rb'^if DisasterZoneBoot and DisasterZoneBoot\.Run\("([^"]+)", \.\.\.\) then return end ?')


class ReleaseError(Exception):
    pass


# ---------------------------------------------------------------------------------------------------------------
# Addon tree helpers
# ---------------------------------------------------------------------------------------------------------------

def read(path):
    with open(path, "rb") as fh:
        return fh.read()


def parse_toc(addon_dir, name=ADDON_NAME):
    """(headers {lowercase key: value}, [file paths with forward slashes, in load order], raw text)."""
    raw = read(os.path.join(addon_dir, name + ".toc")).decode("utf-8-sig")
    headers, files = {}, []
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("##"):
            k, _, v = line[2:].partition(":")
            headers[k.strip().lower()] = v.strip()
        elif line and not line.startswith("#"):
            files.append(line.replace("\\", "/"))
    return headers, files, raw


def is_room_data(path):
    """The strategy board's generated 3D rooms as releases before 1.3.4 listed them in the addon's own TOC
    (Render3D/Rooms/<Raid>_<Boss>.lua): megabytes of packed text, too much for an in-game update. They are the addon
    DisasterZone_Rooms now (rooms_dir()); a new or changed room ships with a full release."""
    return path.startswith("Render3D/Rooms/") and "_" in path.rsplit("/", 1)[-1]


def rooms_dir(addon_dir=None):
    """The DisasterZone_Rooms folder next to an addon folder, or None when there is none."""
    d = os.path.join(os.path.dirname(os.path.normpath(addon_dir or ADDON_DIR)), ROOMS_NAME)
    return d if os.path.isfile(os.path.join(d, ROOMS_NAME + ".toc")) else None


def rooms_hashes(addon_dir=None):
    """{path in DisasterZone_Rooms: sha256} of the room data next to an addon folder ({} without one)."""
    d = rooms_dir(addon_dir)
    return file_hashes(d) if d else {}


def is_patchable(path):
    return path.endswith(".lua") and not path.startswith("Libs/") and path not in PROTECTED and not is_room_data(path)


def patchable_files(addon_dir):
    return [f for f in parse_toc(addon_dir)[1] if is_patchable(f)]


def all_files(addon_dir):
    out = []
    for root, dirs, files in os.walk(addon_dir):
        # (.claude: a Claude Code session's files, when one ran in the addon folder)
        dirs[:] = [d for d in dirs if d not in (".git", ".claude", "__pycache__")]
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), addon_dir).replace("\\", "/")
            if not rel.startswith(DEV_ONLY):
                out.append(rel)
    return sorted(out)


def file_hashes(addon_dir, lua_only=False):
    out = {}
    for rel in all_files(addon_dir):
        if lua_only and not rel.endswith((".lua", ".toc")):
            continue
        out[rel] = hashlib.sha256(read(os.path.join(addon_dir, rel))).hexdigest()
    return out


def build_id(hashes, rooms=None):
    """The build of a release: its files' hashes (rooms: DisasterZone_Rooms' too, so a release whose room data
    changed is another build)."""
    h = hashlib.sha256()
    for rel in sorted(hashes):
        if rel in TOOL_MANAGED:
            continue
        h.update(rel.encode("utf-8") + b"\0" + hashes[rel].encode("ascii") + b"\n")
    for rel in sorted(rooms or {}):
        h.update((ROOMS_NAME + "/" + rel).encode("utf-8") + b"\0" + rooms[rel].encode("ascii") + b"\n")
    return h.hexdigest()[:16]


def asset_pack(addon_dir):
    src = read(os.path.join(addon_dir, "Core", "BuildInfo.lua")).decode("utf-8")
    m = re.search(r"assetPack\s*=\s*(\d+)", src)
    if not m:
        raise ReleaseError("Core/BuildInfo.lua has no assetPack")
    return int(m.group(1))


def build_info_lua(bid, pack):
    return ("-- DisasterZone: what is installed on disk (written by dev/tools/release.py for this release).\n"
            "-- See the source tree's Core/BuildInfo.lua for what the fields mean. Never part of an in-game update.\n"
            "DisasterZoneBuild = {\n    id = \"%s\",\n    assetPack = %d,\n}\n" % (bid, pack))


def patch_key_lua(key):
    return ('if DisasterZoneBoot and DisasterZoneBoot.Run("Core/PatchKey.lua", ...) then return end '
            "-- DisasterZone: public key in-game updates are verified with (written by dev/tools/release.py keygen).\n"
            "-- The private half lives only on the publisher's machine. Core/Patch.lua explains the scheme.\n"
            "local addonName, ns = ...\n\n"
            "ns.PatchKey = {\n    seed = \"%s\",\n    root = \"%s\",\n    h = %d,\n}\n"
            % (key["seed"], key["root"], key["height"]))


# ---------------------------------------------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------------------------------------------

def guard_for(path):
    return b'if DisasterZoneBoot and DisasterZoneBoot.Run("' + path.encode("ascii") + b'", ...) then return end '


def guard_state(addon_dir, rel):
    """'ok' | 'missing' | 'wrong' for one patchable file."""
    data = read(os.path.join(addon_dir, rel))
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    m = GUARD_RE.match(data)
    if not m:
        return "missing"
    return "ok" if m.group(1).decode("ascii", "replace") == rel else "wrong"


def guards(addon_dir, action):
    changed, problems = [], []
    for rel in patchable_files(addon_dir):
        path = os.path.join(addon_dir, rel)
        if not os.path.exists(path):
            problems.append("%s: listed in the TOC but missing" % rel)
            continue
        data = read(path)
        bom = b""
        if data.startswith(b"\xef\xbb\xbf"):
            bom, data = data[:3], data[3:]
        m = GUARD_RE.match(data)
        if action == "check":
            if not m:
                problems.append("%s: no guard on line 1" % rel)
            elif m.group(1).decode("ascii", "replace") != rel:
                problems.append("%s: guard names %s" % (rel, m.group(1).decode("ascii", "replace")))
        elif action == "add":
            if m and m.group(1).decode("ascii", "replace") == rel:
                continue
            body = data[m.end():] if m else data
            _put(path, bom + guard_for(rel) + body)
            changed.append(rel)
        elif action == "remove":
            if m:
                _put(path, bom + data[m.end():])
                changed.append(rel)
        else:
            raise ReleaseError("guards: add, remove or check")
    return changed, problems


def _put(path, data):
    """Writes a file by replacing it (atomic). Never writes into the existing file: the test suites hard-link their
    copies of the addon tree (tests/patch/_patchkit.py), and an in-place write would change every linked copy."""
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)


# ---------------------------------------------------------------------------------------------------------------
# Full release
# ---------------------------------------------------------------------------------------------------------------

def stage_tree(src, dst, lua_only=False, build=None, key=None, link=False, rooms=False):
    """Copy the addon folder `src` to `dst` as a release: BuildInfo gets the build id, the outbox is emptied.
    lua_only=True copies only what the game executes (.toc, .lua): enough for the offline harness.
    link=True hard-links the files instead of copying them (tests: a new copy costs a virus scan on first read).
    rooms=True also copies the DisasterZone_Rooms folder next to `src` (when there is one) next to `dst`; its files
    go into the build id and the record ("rooms").
    Returns the release record (without the zip)."""
    if os.path.exists(dst):
        raise ReleaseError("%s already exists" % dst)
    for rel in all_files(src):
        if lua_only and not rel.endswith((".lua", ".toc")):
            continue
        target = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        (os.link if link else shutil.copyfile)(os.path.join(src, rel), target)
    pack = asset_pack(src)
    _put(os.path.join(dst, "Core", "Outbox.lua"), patchlib.OUTBOX_STUB.encode("utf-8"))
    _put(os.path.join(dst, "Core", "DevPlan.lua"), DEVPLAN_STUB.encode("utf-8"))
    if key is not None:
        _put(os.path.join(dst, "Core", "PatchKey.lua"), patch_key_lua(key).encode("utf-8"))
    room_hashes = {}
    rsrc = rooms_dir(src) if rooms else None
    if rsrc:
        rdst = os.path.join(os.path.dirname(os.path.normpath(dst)), ROOMS_NAME)
        if os.path.exists(rdst):
            raise ReleaseError("%s already exists" % rdst)
        for rel in all_files(rsrc):
            if lua_only and not rel.endswith((".lua", ".toc")):
                continue
            target = os.path.join(rdst, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            (os.link if link else shutil.copyfile)(os.path.join(rsrc, rel), target)
        room_hashes = file_hashes(rdst)
    hashes = file_hashes(dst)
    bid = build or build_id(hashes, room_hashes)
    _put(os.path.join(dst, "Core", "BuildInfo.lua"), build_info_lua(bid, pack).encode("utf-8"))
    headers, files, raw = parse_toc(dst)
    record = {"version": headers.get("version", "0"), "build": bid, "assetPack": pack, "files": hashes,
              "toc": raw, "luaOnly": bool(lua_only)}
    if rsrc:
        record["rooms"] = room_hashes
    return record


def check_tree(addon_dir):
    """Problems that would make a release unusable for in-game updates."""
    problems = []
    headers, files, _ = parse_toc(addon_dir)
    if headers.get("loadsavedvariablesfirst") not in ("1", "true"):
        problems.append("the TOC lacks '## LoadSavedVariablesFirst: 1'")
    if "DisasterZonePatchDB" not in [s.strip() for s in headers.get("savedvariables", "").split(",")]:
        problems.append("the TOC does not save DisasterZonePatchDB")
    lua = [f for f in files if f.endswith(".lua")]
    if lua[:2] != ["Core/BuildInfo.lua", "Core/Boot.lua"]:
        problems.append("Core/BuildInfo.lua and Core/Boot.lua must be the first two files in the TOC")
    if lua[-2:] != ["Core/Outbox.lua", "Core/BootEnd.lua"]:
        problems.append("Core/Outbox.lua and Core/BootEnd.lua must be the last two files in the TOC")
    problems += guards(addon_dir, "check")[1]
    rdir = rooms_dir(addon_dir)
    if rdir:
        rheaders = parse_toc(rdir, ROOMS_NAME)[0]
        if rheaders.get("version") != headers.get("version"):
            problems.append("%s.toc says version %s, %s.toc %s: give both the same" % (
                ROOMS_NAME, rheaders.get("version"), ADDON_NAME, headers.get("version")))
        if rheaders.get("loadondemand") not in ("1", "true"):
            problems.append("%s.toc lacks '## LoadOnDemand: 1'" % ROOMS_NAME)
    return problems


def git_commit():
    try:
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO, capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def warn_release_suites():
    """The release-only test suites (tf_e/run_all.py RELEASE_ONLY) are left out of normal test runs: say so when
    they have not passed on the current sources. A warning only, never a stop."""
    try:
        import testmap
        problems = testmap.release_check()
    except Exception as e:  # noqa: BLE001 - a missing test record must never block a release
        problems = ["could not check the release-only test suites: %s" % e]
    if problems:
        print("WARNING: release-only tests are not green on these sources (run tf_e\\run_all.py --all):")
        for p in problems:
            print("  " + p)


def cmd_full(args):
    warn_release_suites()
    problems = check_tree(ADDON_DIR)
    if problems:
        raise ReleaseError("not ready for a release:\n  " + "\n  ".join(problems))
    if guard_state(ADDON_DIR, "Core/PatchKey.lua") != "ok":
        raise ReleaseError("Core/PatchKey.lua is missing: run 'release.py keygen' first")
    version = parse_toc(ADDON_DIR)[0].get("version", "0")
    os.makedirs(DIST, exist_ok=True)
    os.makedirs(RELEASES, exist_ok=True)
    zip_path = os.path.join(DIST, "%s-%s.zip" % (ADDON_NAME, version))
    record_path = os.path.join(RELEASES, "%s.json" % version)
    if (os.path.exists(zip_path) or os.path.exists(record_path)) and not args.force:
        raise ReleaseError("release %s already exists (bump '## Version' in the TOC, or --force)" % version)
    tmp = os.path.join(DIST, "_stage")
    if os.path.isdir(tmp):
        shutil.rmtree(tmp)
    stage = os.path.join(tmp, ADDON_NAME)
    record = stage_tree(ADDON_DIR, stage, rooms=True)
    record["commit"] = git_commit()
    record["time"] = time.strftime("%Y-%m-%d %H:%M:%S")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for name in (ADDON_NAME, ROOMS_NAME):                # (both folders go into Interface\AddOns)
            folder = os.path.join(tmp, name)
            if os.path.isdir(folder):
                for rel in all_files(folder):
                    zf.write(os.path.join(folder, rel), name + "/" + rel)
    shutil.rmtree(tmp)
    with open(record_path, "w", encoding="utf-8") as fh:
        json.dump(record, fh, indent=1)
    with open(os.path.join(RELEASES, "base.json"), "w", encoding="utf-8") as fh:
        json.dump({"version": version}, fh)
    # a new base makes the outbox of the previous one meaningless
    _put(os.path.join(ADDON_DIR, "Core", "Outbox.lua"), patchlib.OUTBOX_STUB.encode("utf-8"))
    print("release %s: build %s, art pack %d, %d files + %d in %s" % (
        version, record["build"], record["assetPack"], len(record["files"]), len(record.get("rooms", {})), ROOMS_NAME))
    print("  %s (%.1f MB)" % (zip_path, os.path.getsize(zip_path) / 1048576.0))
    print("  this is now the base for in-game updates. Members install the zip once; after that 'release.py patch'.")
    if getattr(args, "publish", False):
        publish_after_full(version, args.channel)


def publish_after_full(version, channel):
    """'full --publish': the release just built goes straight to the launchers (same as 'publish --version V')."""
    print("publishing %s to %s for the launcher..." % (version, channel))
    cmd_publish(argparse.Namespace(version=version, channel=channel, repo=None, clone=None, out=None, force=False))


# ---------------------------------------------------------------------------------------------------------------
# Patch
# ---------------------------------------------------------------------------------------------------------------

def toc_from_text(raw):
    headers, files = {}, []
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("##"):
            k, _, v = line[2:].partition(":")
            headers[k.strip().lower()] = v.strip()
        elif line and not line.startswith("#"):
            files.append(line.replace("\\", "/"))
    return headers, files


def diff_against_base(base, addon_dir):
    """Compare the addon folder with a release record. Returns (entries, version, pack, notes) where entries is
    the ordered patch file list; raises ReleaseError when the change cannot travel as an in-game update."""
    base_headers, base_files = toc_from_text(base["toc"])
    headers, files, _ = parse_toc(addon_dir)
    errors, notes = [], []

    for k in sorted(set(base_headers) | set(headers)):
        if k != "version" and base_headers.get(k) != headers.get(k):
            errors.append("TOC header '%s' changed (%r -> %r)" % (k, base_headers.get(k), headers.get(k)))

    base_set, now_set = set(base_files), set(files)
    for f in base_files:
        if not is_patchable(f) and f not in now_set:
            errors.append("the TOC no longer lists %s" % f)
    for f in files:
        if not is_patchable(f) and f not in base_set:
            errors.append("the TOC lists a new file that cannot be patched: %s" % f)
    if [f for f in base_files if f in now_set] != [f for f in files if f in base_set]:
        errors.append("the TOC order of existing files changed")

    lua_only = base.get("luaOnly")
    if "rooms" in base:                                  # (the room data next to the addon: only a full release)
        now_rooms = rooms_hashes(addon_dir)
        if lua_only:
            now_rooms = {k: v for k, v in now_rooms.items() if k.endswith((".lua", ".toc"))}
        moved = sorted(k for k in set(base["rooms"]) | set(now_rooms) if base["rooms"].get(k) != now_rooms.get(k))
        if moved:
            errors.append("the 3D room data changed (%s/%s%s): ship a full release" % (
                ROOMS_NAME, ", ".join(moved[:3]), ", ..." if len(moved) > 3 else ""))
    now_hashes = file_hashes(addon_dir, lua_only=lua_only)
    base_hashes = base["files"]
    pack = asset_pack(addon_dir)
    art_changed = []
    for rel in sorted(set(base_hashes) | set(now_hashes)):
        if rel in TOOL_MANAGED or rel.endswith(".toc") or base_hashes.get(rel) == now_hashes.get(rel):
            continue
        if rel.endswith(".lua"):
            if rel.startswith("Libs/") or rel in PROTECTED:
                errors.append("%s changed" % rel)
            elif is_room_data(rel):
                if rel in now_set and rel in base_set:
                    errors.append("%s changed (a 3D room: ship a full release)" % rel)
            elif rel not in now_set and rel not in base_set:
                notes.append("ignored (not in the TOC): %s" % rel)
        elif rel.endswith(DOC_EXT):
            pass
        else:
            art_changed.append(rel)
    if art_changed:
        if pack <= base["assetPack"]:
            errors.append("art changed (%s%s) but assetPack in Core/BuildInfo.lua is still %d: raise it and gate the "
                          "code that needs the new art with ns:HasAssets(%d)" % (
                              ", ".join(art_changed[:4]), ", ..." if len(art_changed) > 4 else "",
                              pack, base["assetPack"] + 1))
        else:
            notes.append("%d art file(s) changed: members see that content after they download the full release "
                         "(art pack %d)" % (len(art_changed), pack))
    elif pack != base["assetPack"]:
        notes.append("assetPack is %d (base %d) although no art changed" % (pack, base["assetPack"]))

    entries = []
    base_patchable = [f for f in base_files if is_patchable(f)]
    for i, f in enumerate(files):
        if not is_patchable(f):
            continue
        path = os.path.join(addon_dir, f)
        if not os.path.exists(path):
            errors.append("%s is listed in the TOC but missing" % f)
            continue
        if f in base_set:
            if base_hashes.get(f) != now_hashes.get(f):
                entries.append({"kind": "F", "path": f, "src": read(path)})
        else:
            before = ""
            for later in files[i + 1:]:
                if later in base_set and is_patchable(later):
                    before = later
                    break
            entries.append({"kind": "N", "path": f, "src": read(path), "before": before})
    for f in base_patchable:
        if f not in now_set:
            entries.append({"kind": "D", "path": f})

    for e in entries:
        if e["kind"] != "D":
            state = guard_state(addon_dir, e["path"])
            if state != "ok":
                errors.append("%s: guard on line 1 is %s (run 'release.py guards add')" % (e["path"], state))
    if art_changed and pack > base["assetPack"]:
        needle = ("HasAssets(%d)" % pack).encode("ascii")
        if not any(e["kind"] != "D" and needle in e["src"] for e in entries):
            notes.append("no changed file calls ns:HasAssets(%d): make sure the code that needs the new art checks it"
                         % pack)
    if errors:
        raise ReleaseError("this change needs a full release:\n  " + "\n  ".join(errors))
    return entries, headers.get("version", "0"), pack, notes


def syntax_errors(entries):
    try:
        import lupa.lua51 as lua51
    except ImportError:
        try:
            sys.path.insert(0, os.path.join(DEV, "luaenv", "Lib", "site-packages"))
            import lupa.lua51 as lua51
        except ImportError:
            return ["(lupa is not installed: syntax was not checked)"]
    rt = lua51.LuaRuntime(encoding=None)
    loadstring = rt.globals()[b"loadstring"]
    out = []
    for e in entries:
        if e["kind"] == "D":
            continue
        res = loadstring(patchlib.normalize_source(e["src"]), ("@" + e["path"]).encode("utf-8"))
        if isinstance(res, tuple) and res[0] is None:
            out.append(res[1].decode("utf-8", "replace"))
    return out


def load_base():
    pointer = os.path.join(RELEASES, "base.json")
    if not os.path.exists(pointer):
        raise ReleaseError("there is no base release yet: run 'release.py full' first")
    version = json.load(open(pointer, encoding="utf-8"))["version"]
    return json.load(open(os.path.join(RELEASES, "%s.json" % version), encoding="utf-8"))


def patch_log():
    path = os.path.join(RELEASES, "patches.json")
    if os.path.exists(path):
        return json.load(open(path, encoding="utf-8"))
    return []


def source_differences(base, addon_dir):
    """Where the source tree differs from the base release, among what an update or a version bump touches: the
    TOC, the patchable Lua files of either TOC, the docs. Returns [(path, 'changed' | 'new' | 'deleted')]."""
    base_files = set(toc_from_text(base["toc"])[1])
    now_files = set(parse_toc(addon_dir)[1])
    candidates = {f for f in base_files | now_files if is_patchable(f)}
    candidates.add(ADDON_NAME + ".toc")
    candidates |= {f for f in base["files"] if f.endswith(DOC_EXT)}
    out = []
    for rel in sorted(candidates):
        path = os.path.join(addon_dir, rel)
        have = hashlib.sha256(read(path)).hexdigest() if os.path.exists(path) else None
        want = base["files"].get(rel)
        if have != want:
            out.append((rel, "new" if want is None else ("deleted" if have is None else "changed")))
    return out


def restore_to_base(base, addon_dir, zip_path, backup_dir):
    """Put every file listed by source_differences() back to its content in the base release (from the release
    zip). The current versions are copied to backup_dir first. Returns the list of differences that were undone."""
    diffs = source_differences(base, addon_dir)
    if not diffs:
        return []
    if not os.path.exists(zip_path):
        raise ReleaseError("%s is missing, so this copy cannot be put back to release %s automatically. "
                           "Use --keep-source and undo the change by hand." % (zip_path, base["version"]))
    with zipfile.ZipFile(zip_path) as zf:
        for rel, state in diffs:
            path = os.path.join(addon_dir, rel)
            if os.path.exists(path):
                saved = os.path.join(backup_dir, rel)
                os.makedirs(os.path.dirname(saved), exist_ok=True)
                shutil.copyfile(path, saved)
            if state == "new":
                os.remove(path)
            else:
                data = zf.read(ADDON_NAME + "/" + rel)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                _put(path, data)
    left = source_differences(base, addon_dir)
    if left:
        raise ReleaseError("could not put these back to release %s: %s (your versions are in %s)" % (
            base["version"], ", ".join(rel for rel, _ in left), backup_dir))
    return diffs


def last_update_for(log, base):
    """The newest update made for this base release (self-tests are addressed elsewhere), or None."""
    for entry in reversed(log):
        if entry.get("build") == base["build"]:
            return entry
    return None


def published_hashes(base, last):
    """{path: sha256 of the travelling text | None when deleted} of what members run for the files the last update
    touched; files it did not touch run from the base release."""
    return dict(last.get("sha") or {}) if last else {}


def sync_report(base, log, addon_dir):
    """How this copy compares with what members run (base release + the newest update for it).
    Returns (in_sync, [lines])."""
    last = last_update_for(log, base)
    try:
        entries, version, pack, notes = diff_against_base(base, addon_dir)
    except ReleaseError as e:
        return False, [str(e)]
    mine = {}
    for e in entries:
        mine[e["path"]] = None if e["kind"] == "D" else hashlib.sha256(patchlib.normalize_source(e["src"])).hexdigest()
    theirs = {}
    if last:
        for kind, path in last.get("files", []):
            theirs[path] = None if kind == "D" else (last.get("sha") or {}).get(path, "?")
    differing = sorted(path for path in set(mine) | set(theirs) if mine.get(path, "base") != theirs.get(path, "base"))
    running = "release %s" % base["version"]
    if last and last.get("files"):
        running = "%s (update #%d)" % (last["version"], last["seq"])
    elif last:
        running = "release %s (update #%d took the earlier ones back)" % (base["version"], last["seq"])
    if not differing:
        return True, ["this copy matches what members run: %s" % running]
    lines = ["this copy differs from what members run (%s) in %d file(s):" % (running, len(differing))]
    lines += ["  " + path for path in differing]
    lines.append("'release.py patch' sends your version to everybody; 'release.py patch --revoke' takes everybody, "
                 "and this copy, back to release %s." % base["version"])
    return False, lines


def make_patch(base, addon_dir, key, seq, revoke=False):
    """Build the signed bundle for `addon_dir` against release record `base`. Returns (bundle, notes)."""
    if revoke:
        entries, version, pack, notes = [], base["version"], base["assetPack"], []
    else:
        entries, version, pack, notes = diff_against_base(base, addon_dir)
        bad = [s for s in syntax_errors(entries)]
        real = [s for s in bad if not s.startswith("(")]
        if real:
            raise ReleaseError("syntax errors:\n  " + "\n  ".join(real))
        notes += bad
        if not entries:
            raise ReleaseError("nothing changed since release %s" % base["version"])
    bundle = patchlib.build_bundle(seq, version, base["build"], pack, entries, key)
    return bundle, notes


def cmd_patch(args):
    warn_release_suites()
    if not os.path.exists(KEY_PATH):
        raise ReleaseError("no signing key: run 'release.py keygen' first")
    key = patchlib.load_key(KEY_PATH)
    base = load_base()
    log = patch_log()
    seq = max([key.get("next", 1)] + [p["seq"] + 1 for p in log])
    if seq >= (1 << key["height"]):
        raise ReleaseError("the signing key is used up (%d updates): make a new key and a full release" % seq)

    revoke = bool(args.revoke)
    keep = bool(getattr(args, "keep_source", False))
    undone, kept, backup = [], [], None
    if revoke:
        # Taking an update back must not leave this copy behind with the change still in it (it would show here,
        # and travel again with the next update): put the files back as well, unless asked not to.
        diffs = source_differences(base, ADDON_DIR)
        if diffs and keep:
            kept = diffs
        elif diffs:
            backup = os.path.join(RELEASES, "undone", "%s_%s" % (
                time.strftime("%Y%m%d-%H%M%S"), parse_toc(ADDON_DIR)[0].get("version", "0")))
            zip_path = os.path.join(DIST, "%s-%s.zip" % (ADDON_NAME, base["version"]))
            undone = restore_to_base(base, ADDON_DIR, zip_path, backup)
    elif not diff_against_base(base, ADDON_DIR)[0]:
        # nothing differs from the release: if members still run an update with files, send them back to it
        last = last_update_for(log, base)
        if last and last.get("files"):
            revoke = True
            print("this copy equals release %s, but members run update #%d (%s): building the update that takes "
                  "them back." % (base["version"], last["seq"], last["version"]))

    bundle, notes = make_patch(base, ADDON_DIR, key, seq, revoke=revoke)
    if not revoke and patchlib_version_le(bundle["version"], base["version"]):
        raise ReleaseError("'## Version' in the TOC is %s, not above the base release %s: bump it first"
                           % (bundle["version"], base["version"]))
    # the sequence number is spent before the signature leaves this function: a leaf signs one manifest only
    key["next"] = seq + 1
    patchlib.save_key(KEY_PATH, key)
    log.append({"seq": seq, "version": bundle["version"], "base": base["version"], "build": base["build"],
                "pack": bundle["pack"], "files": [(it["kind"], it["path"]) for it in bundle["items"]],
                "sha": {it["path"]: hashlib.sha256(it["src"]).hexdigest() for it in bundle["items"] if it["kind"] != "D"},
                "time": time.strftime("%Y-%m-%d %H:%M:%S"), "commit": git_commit(), "revoke": revoke})
    os.makedirs(RELEASES, exist_ok=True)
    with open(os.path.join(RELEASES, "patches.json"), "w", encoding="utf-8") as fh:
        json.dump(log, fh, indent=1)
    _put(os.path.join(ADDON_DIR, "Core", "Outbox.lua"), patchlib.outbox_lua(bundle).encode("utf-8"))
    wire = bundle["ztotal"] + len(bundle["z0"])
    print("update #%d: %s on top of %s (build %s)" % (seq, bundle["version"], base["version"], base["build"]))
    for it in bundle["items"]:
        print("  %s %s" % ({"F": "changed", "N": "new    ", "D": "deleted"}[it["kind"]], it["path"]))
    if revoke:
        print("  no files: everybody goes back to release %s" % base["version"])
    print("  %d KB of source, %d KB to send (about %s for everybody who is online)" % (
        bundle["total"] // 1024, wire // 1024 + 1, human_time(wire / 600.0)))
    for n in notes:
        print("  note: " + n)
    if undone:
        print("  this copy was put back to release %s too (%d file(s)):" % (base["version"], len(undone)))
        for rel, state in undone:
            print("    %s %s" % ({"changed": "restored", "new": "removed ", "deleted": "restored"}[state], rel))
        print("  the versions you had are in %s" % backup)
    elif kept:
        print("  WARNING: this copy keeps changes that members will no longer have (--keep-source):")
        for rel, state in kept:
            print("    %s %s" % (state, rel))
        print("  you still see them in game, and the next 'release.py patch' sends them out again.")
    print("  written to Core\\Outbox.lua. In game: /reload, then /dz publish")


SELFTEST_BUILD = "selftest"


def selftest_parts(addon_dir):
    """The patchable files of `addon_dir` as the fewest runs (in order) that each fit one update's caps (patchlib's
    and Core/Patch.lua's: 4 MB of source, 1.5 MB encoded): the whole addon outgrew one update in 1.4 (13.6 MB)."""
    parts, cur, total, ztotal, mlen = [], [], 0, 0, 0
    room = 0.95                                       # (the manifest and the signature take their share too)
    for rel in patchable_files(addon_dir):
        src = patchlib.normalize_source(read(os.path.join(addon_dir, rel)))
        z = len(patchlib.encode_for_print(patchlib.deflate_raw(src)))
        line = len(rel) + 96
        if cur and (total + len(src) > patchlib.MAX_TOTAL_LEN * room or ztotal + z > patchlib.MAX_TOTAL_ZLEN * room
                    or mlen + line > patchlib.MAX_MANIFEST_LEN * room or len(cur) + 1 > patchlib.MAX_FILES):
            parts.append(cur)
            cur, total, ztotal, mlen = [], 0, 0, 0
        cur.append(rel)
        total, ztotal, mlen = total + len(src), ztotal + z, mlen + line
    if cur:
        parts.append(cur)
    return parts


def make_selftest(addon_dir, key, seq, part=1):
    """An update with the patchable files of `addon_dir` in self-test part `part` (selftest_parts), addressed to a
    build id nobody has installed. -> (bundle, number of parts)"""
    parts = selftest_parts(addon_dir)
    if not 1 <= part <= len(parts):
        raise ReleaseError("there are %d self-test part(s)" % len(parts))
    entries = []
    for rel in parts[part - 1]:
        state = guard_state(addon_dir, rel)
        if state != "ok":
            raise ReleaseError("%s: guard on line 1 is %s (run 'release.py guards add')" % (rel, state))
        entries.append({"kind": "F", "path": rel, "src": read(os.path.join(addon_dir, rel))})
    bad = [x for x in syntax_errors(entries) if not x.startswith("(")]
    if bad:
        raise ReleaseError("syntax errors:\n  " + "\n  ".join(bad))
    version = parse_toc(addon_dir)[0].get("version", "0") + "-selftest"
    if len(parts) > 1:
        version += "-%dof%d" % (part, len(parts))
    return patchlib.build_bundle(seq, version, SELFTEST_BUILD, asset_pack(addon_dir), entries, key), len(parts)


def cmd_selftest(args):
    if not os.path.exists(KEY_PATH):
        raise ReleaseError("no signing key: run 'release.py keygen' first")
    key = patchlib.load_key(KEY_PATH)
    log = patch_log()
    seq = max([key.get("next", 1)] + [p["seq"] + 1 for p in log])
    if seq >= (1 << key["height"]):
        raise ReleaseError("the signing key is used up")
    part = getattr(args, "part", None) or 1
    bundle, nparts = make_selftest(ADDON_DIR, key, seq, part)
    key["next"] = seq + 1
    patchlib.save_key(KEY_PATH, key)
    log.append({"seq": seq, "version": bundle["version"], "base": SELFTEST_BUILD, "build": SELFTEST_BUILD,
                "pack": bundle["pack"], "files": [(it["kind"], it["path"]) for it in bundle["items"]],
                "time": time.strftime("%Y-%m-%d %H:%M:%S"), "commit": git_commit(), "revoke": False, "selftest": True})
    os.makedirs(RELEASES, exist_ok=True)
    with open(os.path.join(RELEASES, "patches.json"), "w", encoding="utf-8") as fh:
        json.dump(log, fh, indent=1)
    _put(os.path.join(ADDON_DIR, "Core", "Outbox.lua"), patchlib.outbox_lua(bundle).encode("utf-8"))
    print("self-test update #%d, part %d of %d: %d files, %d KB of source, %d KB encoded" % (
        seq, part, nparts, len(bundle["items"]), bundle["total"] // 1024,
        (bundle["ztotal"] + len(bundle["z0"])) // 1024))
    print("  in game, on this development copy:")
    print("    /reload            loads the outbox")
    print("    /dz publish       checks the signature and every file, stores it (members ignore it)")
    print("    /dzpatch try      run the stored update once")
    print("    /reload            then /dzpatch must say: running an in-game update: %s" % bundle["version"])
    print("    /reload            back to the files on disk")
    if part < nparts:
        print("  then the next part: release.py selftest --part %d" % (part + 1))
    print("  afterwards 'release.py patch' (or 'full') replaces the outbox.")


def patchlib_version_le(a, b):
    def parts(v):
        return [int(x) if x.isdigit() else 0 for x in re.split(r"[.\-]", v)]
    pa, pb = parts(a), parts(b)
    n = max(len(pa), len(pb))
    pa += [0] * (n - len(pa))
    pb += [0] * (n - len(pb))
    return pa <= pb


def human_time(seconds):
    if seconds < 90:
        return "%d seconds" % max(1, round(seconds))
    return "%d minutes" % round(seconds / 60.0)


def cmd_status(args):
    key = patchlib.load_key(KEY_PATH) if os.path.exists(KEY_PATH) else None
    print("signing key: %s" % ("%d of %d updates used" % (key.get("next", 1) - 1, (1 << key["height"]) - 1) if key else "none (release.py keygen)"))
    try:
        base = load_base()
    except ReleaseError as e:
        print(str(e))
        return
    print("base release: %s (build %s, art pack %d)" % (base["version"], base["build"], base["assetPack"]))
    log = patch_log()
    if log:
        p = log[-1]
        print("last update: #%d = %s on %s (%s)" % (p["seq"], p["version"], p["base"], p["time"]))
    try:
        entries, version, pack, notes = diff_against_base(base, ADDON_DIR)
        print("changed since the base: %d file(s); TOC version %s" % (len(entries), version))
        for e in entries:
            print("  %s %s" % (e["kind"], e["path"]))
        for n in notes:
            print("  note: " + n)
    except ReleaseError as e:
        print(str(e))
        return
    in_sync, lines = sync_report(base, log, ADDON_DIR)
    for line in lines:
        print(("" if in_sync else "NOT IN SYNC: ") + line if line is lines[0] else line)


def cmd_keygen(args):
    if os.path.exists(KEY_PATH) and not args.force:
        raise ReleaseError("%s exists. A new key needs a full release before any update can be sent; "
                           "use --force if that is what you want." % KEY_PATH)
    os.makedirs(os.path.dirname(KEY_PATH), exist_ok=True)
    print("generating %d one-time keys..." % (1 << args.height))
    key = patchlib.keygen(args.height)
    patchlib.save_key(KEY_PATH, key)
    _put(os.path.join(ADDON_DIR, "Core", "PatchKey.lua"), patch_key_lua(key).encode("utf-8"))
    print("private key: %s  (back this file up; never share or commit it)" % KEY_PATH)
    print("public key written to Core\\PatchKey.lua")


def cmd_guards(args):
    changed, problems = guards(ADDON_DIR, args.action)
    for rel in changed:
        print("  %s" % rel)
    for p in problems:
        print("  " + p)
    print("guards %s: %d file(s) changed, %d problem(s)" % (args.action, len(changed), len(problems)))
    if problems:
        sys.exit(1)


# ---------------------------------------------------------------------------------------------------------------
# Desktop launcher: publish a full release (see launchlib.py)
# ---------------------------------------------------------------------------------------------------------------

LAUNCHER_KEY_PATH = os.path.join(DEV, "keys", "launcher_key.json")
LAUNCHER_DIR = os.path.join(REPO, "launcher")
LAUNCHER_PUBKEY = os.path.join(LAUNCHER_DIR, "release_key.json")     # built into the launcher
PUBLISH_CONF = os.path.join(RELEASES, "publish.json")                # {"repo": "owner/name", "clone": path}
PUBLISHED_LOG = os.path.join(RELEASES, "published.json")
DEFAULT_CLONE = os.path.join(os.path.dirname(REPO), "DisasterZone-releases")
CHANGELOG_ENTRIES = 5


def cmd_launcher_keygen(args):
    if os.path.exists(LAUNCHER_KEY_PATH) and not args.force:
        raise ReleaseError("%s exists. A new key means every launcher must be rebuilt and reinstalled before it "
                           "accepts a release again; use --force if that is what you want." % LAUNCHER_KEY_PATH)
    os.makedirs(os.path.dirname(LAUNCHER_KEY_PATH), exist_ok=True)
    key = launchlib.keygen()
    launchlib.save_key(LAUNCHER_KEY_PATH, key)
    os.makedirs(LAUNCHER_DIR, exist_ok=True)
    _put(LAUNCHER_PUBKEY, (json.dumps({"id": key["id"], "public": key["public"]}, indent=1) + "\n").encode("ascii"))
    print("private key: %s  (back this file up; never share or commit it)" % LAUNCHER_KEY_PATH)
    print("public key %s written to %s (built into the launcher)" % (key["id"], LAUNCHER_PUBKEY))


def _load_json(path, default):
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    return default


def _lua_list(t):
    return [t[i] for i in range(1, len(t) + 1)] if t is not None else []


def changelog_notes(addon_files, count=CHANGELOG_ENTRIES):
    """The newest `count` entries of Data/Changelog.lua as plain data for the launcher's changelog view:
    [{version, date, title, sections: [{heading, kind, area, lead, lines: [text | {text, for}]}]}]."""
    src = addon_files.get("Data/Changelog.lua")
    if not src:
        return []
    try:
        import lupa.lua51 as lua51
    except ImportError:
        sys.path.insert(0, os.path.join(DEV, "luaenv", "Lib", "site-packages"))
        import lupa.lua51 as lua51
    rt = lua51.LuaRuntime(encoding="utf-8")
    fn = rt.globals().loadstring(patchlib.normalize_source(src).decode("utf-8"), "@Data/Changelog.lua")
    if not callable(fn):
        raise ReleaseError("Data/Changelog.lua does not compile")
    ns = rt.table()
    fn(ADDON_NAME, ns)
    out = []
    for e in _lua_list(ns.CHANGELOG)[:count]:
        sections = []
        for s in _lua_list(e.sections):
            lines = []
            for line in _lua_list(s.lines):
                if isinstance(line, str):
                    lines.append(line)
                else:
                    lines.append({"text": line[1], "for": line["for"] or ""})
            sections.append({"heading": s.heading or "", "kind": s.kind or "", "area": s.area or "",
                             "lead": s.lead or "", "lines": lines})
        out.append({"version": e.version or "", "date": e.date or "", "title": e.title or "", "sections": sections})
    return out


def gh_exe():
    exe = shutil.which("gh")
    if exe:
        return exe
    for path in (r"C:\Program Files\GitHub CLI\gh.exe", "/opt/homebrew/bin/gh", "/usr/local/bin/gh"):
        if os.path.exists(path):
            return path
    raise ReleaseError("the GitHub CLI (gh) is not installed")


def _run(cmd, cwd=None, check=True):
    res = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and res.returncode != 0:
        raise ReleaseError("%s failed:\n  %s" % (" ".join(cmd[:3]), (res.stderr or res.stdout).strip()))
    return res


def cmd_publish(args):
    """Put a full release (dist zip + record) where the launcher finds it: the releases repository (git commit +
    push + a GitHub release carrying the zip), or with --out any folder (no git; for tests and a local try)."""
    if not os.path.exists(LAUNCHER_KEY_PATH):
        raise ReleaseError("no launcher key: run 'release.py launcher-keygen' first")
    key = launchlib.load_key(LAUNCHER_KEY_PATH)
    version = args.version or load_base()["version"]
    record_path = os.path.join(RELEASES, "%s.json" % version)
    zip_path = os.path.join(DIST, "%s-%s.zip" % (ADDON_NAME, version))
    for path in (record_path, zip_path):
        if not os.path.exists(path):
            raise ReleaseError("%s is missing: publish works on a release made with 'release.py full'" % path)
    record = _load_json(record_path, {})
    tree = launchlib.read_zip_tree(zip_path, (ADDON_NAME, ROOMS_NAME))
    stamped = tree.get(ADDON_NAME, {}).get("Core/BuildInfo.lua", b"")
    if ('id = "%s"' % record["build"]).encode("ascii") not in stamped:
        raise ReleaseError("%s does not carry build %s: it is not the zip of that release" % (zip_path, record["build"]))

    conf = _load_json(PUBLISH_CONF, {})
    repo = args.repo or conf.get("repo")
    local = args.out is not None
    if not local and not repo:
        raise ReleaseError("which GitHub repository? pass --repo owner/name once (it is remembered)")
    log = _load_json(PUBLISHED_LOG, [])
    seq = max([0] + [p["seq"] for p in log]) + 1
    on_channel = [p for p in log if p["channel"] == args.channel and not p.get("local")]
    if on_channel and not args.force and patchlib_version_le(version, on_channel[-1]["version"]):
        raise ReleaseError("%s already has %s; publishing %s takes everybody back to it (--force if you mean that)"
                           % (args.channel, on_channel[-1]["version"], version))

    zip_name = os.path.basename(zip_path)
    zip_info = {"name": zip_name, "size": os.path.getsize(zip_path),
                "sha256": hashlib.sha256(read(zip_path)).hexdigest()}
    if repo:
        zip_info["url"] = "https://github.com/%s/releases/download/release-%s/%s" % (repo, version, zip_name)
    notes = {"changelog": changelog_notes(tree[ADDON_NAME])}
    manifest, objects = launchlib.build_manifest(tree, args.channel, seq, record, zip_info=zip_info, notes=notes,
                                                 published=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))

    out = args.out if local else (args.clone or conf.get("clone") or DEFAULT_CLONE)
    if not local and not os.path.isdir(os.path.join(out, ".git")):
        if os.path.exists(out):
            raise ReleaseError("%s exists but is not a clone of %s" % (out, repo))
        print("cloning %s into %s" % (repo, out))
        _run([gh_exe(), "repo", "clone", repo, out])
    written, size = launchlib.write_tree(out, manifest, objects, key)
    problems = launchlib.verify_tree(out, args.channel, key["public"])
    if problems:
        raise ReleaseError("the published tree does not check out:\n  " + "\n  ".join(problems[:10]))
    total = sum(len(v) for v in objects.values())
    print("%s %s -> %s (seq %d, build %s): %d files, %d new object(s), %.1f MB new of %.1f MB" % (
        "wrote" if local else "publishing", version, args.channel, seq, record["build"],
        sum(len(f) for f in manifest["folders"].values()), written, size / 1048576.0, total / 1048576.0))

    if not local:
        _run(["git", "add", "-A"], cwd=out)
        if _run(["git", "diff", "--cached", "--quiet"], cwd=out, check=False).returncode != 0:
            _run(["git", "commit", "-m", "DisasterZone %s (%s, seq %d)" % (version, args.channel, seq)], cwd=out)
        _run(["git", "push"], cwd=out)
        tag = "release-%s" % version
        if _run([gh_exe(), "release", "view", tag, "--repo", repo], check=False).returncode != 0:
            title = (notes["changelog"][0]["title"] if notes["changelog"] and
                     notes["changelog"][0]["version"] == version else "")
            cmd = [gh_exe(), "release", "create", tag, zip_path, "--repo", repo,
                   "--title", "DisasterZone %s" % version, "--notes", title or "DisasterZone %s" % version]
            if args.channel == "beta":
                cmd.append("--prerelease")
            # the repository's "latest release" stays the launcher (the README's download buttons point there)
            cmd.append("--latest=false")
            _run(cmd)
            print("  GitHub release %s created with %s" % (tag, zip_name))
        print("  pushed to %s: launchers on %s see it within a few minutes" % (repo, args.channel))
        conf.update({"repo": repo, "clone": out})
        os.makedirs(RELEASES, exist_ok=True)
        with open(PUBLISH_CONF, "w", encoding="utf-8") as fh:
            json.dump(conf, fh, indent=1)
    log.append({"seq": seq, "channel": args.channel, "version": version, "build": record["build"],
                "time": time.strftime("%Y-%m-%d %H:%M:%S"), "local": local or None})
    os.makedirs(RELEASES, exist_ok=True)
    with open(PUBLISHED_LOG, "w", encoding="utf-8") as fh:
        json.dump(log, fh, indent=1)


# (server: the guild bot, launcher/server, is not part of the launcher; it is deployed on its own)
LAUNCHER_SKIP = ("node_modules", "target", "gen", "server")


def launcher_version():
    """The launcher's version; tauri.conf.json, Cargo.toml and package.json must agree."""
    conf = _load_json(os.path.join(LAUNCHER_DIR, "src-tauri", "tauri.conf.json"), {})
    pkg = _load_json(os.path.join(LAUNCHER_DIR, "package.json"), {})
    cargo = read(os.path.join(LAUNCHER_DIR, "src-tauri", "Cargo.toml")).decode("utf-8")
    m = re.search(r'^version\s*=\s*"([^"]+)"', cargo, re.M)
    versions = {conf.get("version"), pkg.get("version"), m and m.group(1)}
    if len(versions) != 1:
        raise ReleaseError("launcher versions disagree (tauri.conf.json, package.json, Cargo.toml): %s"
                           % ", ".join(sorted(str(v) for v in versions)))
    return versions.pop()


def cmd_launcher_push(args):
    """Copy the launcher source + its CI workflow into the releases repository and push the tag launcher-v<version>:
    GitHub Actions builds the installers for Windows, macOS and Linux and publishes them (launcher/ci/launcher.yml)."""
    conf = _load_json(PUBLISH_CONF, {})
    repo, clone = args.repo or conf.get("repo"), args.clone or conf.get("clone") or DEFAULT_CLONE
    if not repo:
        raise ReleaseError("which GitHub repository? pass --repo owner/name once (it is remembered)")
    source = read(os.path.join(LAUNCHER_DIR, "source.txt")).decode("utf-8").strip()
    if "/%s/" % repo not in source:
        raise ReleaseError("launcher/source.txt (%s) does not point at %s" % (source, repo))
    version = launcher_version()
    tag = "launcher-v%s" % version
    if not os.path.isdir(os.path.join(clone, ".git")):
        _run([gh_exe(), "repo", "clone", repo, clone])
    if _run(["git", "rev-parse", "-q", "--verify", "refs/tags/" + tag], cwd=clone, check=False).returncode == 0:
        raise ReleaseError("%s was already pushed: raise the launcher version (tauri.conf.json, package.json, "
                           "Cargo.toml) first" % tag)
    dst = os.path.join(clone, "launcher")
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    for root, dirs, files in os.walk(LAUNCHER_DIR):
        dirs[:] = [d for d in dirs if d not in LAUNCHER_SKIP]
        for f in files:
            src = os.path.join(root, f)
            target = os.path.join(dst, os.path.relpath(src, LAUNCHER_DIR))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copyfile(src, target)
    wf = os.path.join(clone, ".github", "workflows", "launcher.yml")
    os.makedirs(os.path.dirname(wf), exist_ok=True)
    shutil.copyfile(os.path.join(LAUNCHER_DIR, "ci", "launcher.yml"), wf)
    _run(["git", "add", "-A"], cwd=clone)
    if _run(["git", "diff", "--cached", "--quiet"], cwd=clone, check=False).returncode != 0:
        _run(["git", "commit", "-m", "Launcher %s" % version], cwd=clone)
    _run(["git", "tag", tag], cwd=clone)
    _run(["git", "push"], cwd=clone)
    _run(["git", "push", "origin", tag], cwd=clone)
    print("launcher %s pushed to %s (tag %s): GitHub Actions now builds the installers" % (version, repo, tag))
    print("  watch: https://github.com/%s/actions" % repo)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("keygen"); p.add_argument("--height", type=int, default=10); p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_keygen)
    p = sub.add_parser("guards"); p.add_argument("action", choices=["add", "remove", "check"]); p.set_defaults(fn=cmd_guards)
    p = sub.add_parser("full"); p.add_argument("--force", action="store_true")
    p.add_argument("--publish", action="store_true", help="then publish it for the launcher (see publish)")
    p.add_argument("--channel", choices=launchlib.CHANNELS, default="stable", help="with --publish")
    p.set_defaults(fn=cmd_full)
    p = sub.add_parser("patch"); p.add_argument("--revoke", action="store_true")
    p.add_argument("--keep-source", action="store_true"); p.set_defaults(fn=cmd_patch)
    p = sub.add_parser("status"); p.set_defaults(fn=cmd_status)
    p = sub.add_parser("selftest"); p.set_defaults(fn=cmd_selftest)
    p.add_argument("--part", type=int, default=1, help="which part (the addon no longer fits one update)")
    p = sub.add_parser("launcher-keygen"); p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_launcher_keygen)
    p = sub.add_parser("publish"); p.add_argument("--channel", choices=launchlib.CHANNELS, default="stable")
    p.add_argument("--version"); p.add_argument("--repo"); p.add_argument("--clone"); p.add_argument("--out")
    p.add_argument("--force", action="store_true"); p.set_defaults(fn=cmd_publish)
    p = sub.add_parser("launcher-push"); p.add_argument("--repo"); p.add_argument("--clone")
    p.set_defaults(fn=cmd_launcher_push)
    args = ap.parse_args(argv)
    try:
        args.fn(args)
    except ReleaseError as e:
        print("release.py: " + str(e), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

"""Self-test of tools/move.py on a throwaway git repo: the real TOC with a stub for every file it lists, plus a few
dev/ files that name addon paths. Checks the moves, TOC order, guards, path literals, moves.json, idempotence, the
dry run and the refusals.
Run: luaenv\\Scripts\\python.exe tools\\test_move.py   (~5 s)
move.py: keep paths   (this file's made-up mappings must not be rewritten by a real move)
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import move  # noqa: E402
import release  # noqa: E402

REAL_ADDON = os.environ.get("DISASTERZONE_ADDON_DIR") or release.ADDON_DIR
MAPPING = [
    {"from": "UI/RaidPlanUI.lua", "to": "UI/Raids/RaidPlanUI.lua"},
    {"from": "Core/RaidPlan.lua", "to": "Logic/Raids/RaidPlan.lua", "after": "Core/Util.lua"},
    {"from": "Core/Atlas.lua", "to": "Logic/Items/Atlas.lua"},
]
TEST_PY = b'''import os
A = "UI/RaidPlanUI.lua"
B = 'Core\\\\RaidPlan.lua'
C = r"Core\\Atlas.lua"
D = os.path.join(ADDON, "Core", "RaidPlan.lua")
E = "@Interface/AddOns/DisasterZone/UI/RaidPlanUI.lua"
F = "UI/RaidPlanUI.lua.bak"
'''
BASELINE = b'{\n "files": {\n  "UI/RaidPlanUI.lua": {"colour": 3},\n  "Core/Util.lua": {"helper": 1}\n }\n}\n'
DOC = b"The plan board is `UI/RaidPlanUI.lua`; its model lives in Core/RaidPlan.lua.\n"


def git(repo, *args):
    return subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True, check=True).stdout


def make_repo(tmp):
    repo = os.path.join(tmp, "repo")
    addon = os.path.join(repo, "addon", "DisasterZone")
    os.makedirs(addon)
    shutil.copy2(os.path.join(REAL_ADDON, "DisasterZone.toc"), addon)
    _, files, _ = release.parse_toc(addon)
    for rel in files:
        p = os.path.join(addon, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        body = b"local addonName, ns = ...\nlocal x = 1\n"
        if rel == "Core/Util.lua":
            body += b'local SKIP = { ["Core/Atlas.lua"] = true }\n'   # addon code naming a moved path
        guard = b""
        if release.is_patchable(rel):
            guard = release.guard_for(rel) + b"-- DisasterZone: " + rel.encode() + b"\n"
        with open(p, "wb") as fh:
            fh.write(guard + body)
    dev = os.path.join(repo, "dev")
    for rel, data in (("tests/x/test_a.py", TEST_PY), ("tools/uniformity_baseline.json", BASELINE),
                      ("docs/notes.md", DOC),
                      ("tests/x/test_keep.py", b'# move.py: keep paths\nA = "UI/RaidPlanUI.lua"\n'),
                      ("docs/arch/MOVES.json", json.dumps(MAPPING).encode())):
        p = os.path.join(dev, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as fh:
            fh.write(data)
    git(repo, "init", "-q")
    git(repo, "-c", "core.autocrlf=false", "add", "-A")
    git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base")
    return repo, addon, dev


def snapshot(root):
    out = {}
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d != ".git"]
        for f in fns:
            p = os.path.join(dp, f)
            with open(p, "rb") as fh:
                out[os.path.relpath(p, root)] = hashlib.sha1(fh.read()).hexdigest()
    return out


def run(repo, mapping, dry=False):
    path = os.path.join(repo, "dev", "docs", "arch", "MOVES.json")
    with open(path, "w") as fh:
        json.dump(mapping, fh)
    logs = []
    m = move.Mover(path, root=repo, dry=dry, log=logs.append).run()
    return m, logs


def main():
    failed = []

    def check(name, ok, info=""):
        print("%s %s%s" % ("PASS" if ok else "FAIL", name, (": %s" % (info,)) if not ok and info != "" else ""))
        if not ok:
            failed.append(name)

    tmp = tempfile.mkdtemp(prefix="dz_move_")
    try:
        repo, addon, dev = make_repo(tmp)
        toc_before = release.parse_toc(addon)
        before = snapshot(repo)

        # dry run: says everything, changes nothing
        m, logs = run(repo, MAPPING, dry=True)
        snap = snapshot(repo)
        snap.pop(os.path.join("dev", "docs", "arch", "MOVES.json"))
        b2 = dict(before)
        b2.pop(os.path.join("dev", "docs", "arch", "MOVES.json"))
        check("dry run changes nothing", snap == b2)
        check("dry run lists the moves", sum(1 for k, _ in m.changes if k == "move") == 3, m.changes)

        # the real run
        m, logs = run(repo, MAPPING)
        for e in MAPPING:
            check("moved %s" % e["from"], os.path.isfile(os.path.join(addon, e["to"]))
                  and not os.path.exists(os.path.join(addon, e["from"])))
        st = git(repo, "status", "--porcelain")
        check("moves are git renames", sum(1 for l in st.splitlines() if l.startswith("R")) == 3, st)
        headers, files, raw = release.parse_toc(addon)
        want = [f for f in toc_before[1]]
        want = [{"UI/RaidPlanUI.lua": "UI/Raids/RaidPlanUI.lua", "Core/Atlas.lua": "Logic/Items/Atlas.lua"}.get(f, f)
                for f in want if f != "Core/RaidPlan.lua"]
        want.insert(want.index("Core/Util.lua") + 1, "Logic/Raids/RaidPlan.lua")
        check("TOC: order kept, 'after' placement, headers kept", files == want and headers == toc_before[0],
              [x for x in zip(files, want) if x[0] != x[1]][:3])
        check("TOC: backslash style kept", "UI\\Raids\\RaidPlanUI.lua" in raw and "Logic\\Raids\\RaidPlan.lua" in raw)
        check("TOC: boot files first and last", files[:2] == ["Core/BuildInfo.lua", "Core/Boot.lua"]
              and files[-2:] == ["Core/Outbox.lua", "Core/BootEnd.lua"])
        with open(os.path.join(addon, "UI", "Raids", "RaidPlanUI.lua"), "rb") as fh:
            first = fh.readline()
        check("guard names the new path (and its comment)", first == release.guard_for("UI/Raids/RaidPlanUI.lua")
              + b"-- DisasterZone: UI/Raids/RaidPlanUI.lua\n", first)
        check("guards check passes", not release.guards(addon, "check")[1], release.guards(addon, "check")[1])
        with open(os.path.join(dev, "tests", "x", "test_a.py"), "rb") as fh:
            t = fh.read()
        check("literals rewritten, both slash styles",
              b'A = "UI/Raids/RaidPlanUI.lua"' in t and b"B = 'Logic\\\\Raids\\\\RaidPlan.lua'" in t
              and b'C = r"Logic\\Items\\Atlas.lua"' in t, t)
        check("longer strings and joined pieces left alone",
              b'"@Interface/AddOns/DisasterZone/UI/RaidPlanUI.lua"' in t and b'"UI/RaidPlanUI.lua.bak"' in t
              and b'"Core", "RaidPlan.lua"' in t)
        warns = "\n".join(m.warnings)
        check("...and listed to check by hand", "test_a.py:5" in warns and "test_a.py:6" in warns, warns)
        check("addon code naming a moved path is listed", "Core/Util.lua:" in warns and "addon code" in warns, warns)
        with open(os.path.join(dev, "tools", "uniformity_baseline.json"), "rb") as fh:
            check("JSON keys rewritten", b'"UI/Raids/RaidPlanUI.lua"' in fh.read())
        with open(os.path.join(dev, "docs", "notes.md"), "rb") as fh:
            d = fh.read()
        check("Markdown `code` rewritten, prose listed", b"`UI/Raids/RaidPlanUI.lua`" in d
              and b"in Core/RaidPlan.lua." in d and "notes.md:1" in warns, d)
        with open(os.path.join(dev, "tests", "x", "test_keep.py"), "rb") as fh:
            check("files marked 'move.py: keep paths' untouched", b'"UI/RaidPlanUI.lua"' in fh.read())
        with open(os.path.join(dev, "docs", "arch", "MOVES.json"), "rb") as fh:
            check("the mapping file itself untouched", json.loads(fh.read()) == MAPPING)
        with open(os.path.join(dev, ".testmap", "moves.json")) as fh:
            mv = json.load(fh)
        check("moves.json written", mv == {e["from"]: e["to"] for e in MAPPING}, mv)

        # idempotent: again on the moved tree changes nothing
        after = snapshot(repo)
        m2, _ = run(repo, MAPPING)
        check("second run changes nothing", snapshot(repo) == after
              and not [c for c in m2.changes if c[0] in ("move", "toc", "guard", "literal")], m2.changes)

        # a later move chains in moves.json
        run(repo, [{"from": "UI/Raids/RaidPlanUI.lua", "to": "UI/Raids/Board.lua"}])
        with open(os.path.join(dev, ".testmap", "moves.json")) as fh:
            mv = json.load(fh)
        check("moves.json chains a later move", mv.get("UI/RaidPlanUI.lua") == "UI/Raids/Board.lua", mv)

        # refusals: nothing changes
        snap = snapshot(repo)
        for name, mapping in (
                ("a boot file", [{"from": "Core/Boot.lua", "to": "Core/X/Boot.lua"}]),
                ("the outbox", [{"from": "Core/Outbox.lua", "to": "Sync/Outbox.lua"}]),
                ("Libs/", [{"from": "Libs/LibStub/LibStub.lua", "to": "Core/LibStub.lua"}]),
                ("onto Libs/", [{"from": "Core/Util.lua", "to": "Libs/Util.lua"}]),
                ("DisasterZone_Rooms", [{"from": "../DisasterZone_Rooms/Load.lua", "to": "Core/Load.lua"}]),
                ("room data", [{"from": "Core/Util.lua", "to": "Render3D/Rooms/BT_Bloodboil.lua"}]),
                ("a target that exists", [{"from": "Core/Util.lua", "to": "Core/Init.lua"}]),
                ("a missing file", [{"from": "Core/Nope.lua", "to": "Core/Nope2.lua"}]),
                ("a duplicate", [{"from": "Core/Util.lua", "to": "A/Util.lua"}, {"from": "Core/Util.lua",
                                                                                   "to": "B/Util.lua"}]),
                ("after the last files", [{"from": "Core/Util.lua", "to": "A/Util.lua", "after": "Core/Outbox.lua"}]),
                ("one bad entry refuses all", [{"from": "Core/Init.lua", "to": "A/Init.lua"},
                                               {"from": "Core/Boot.lua", "to": "A/Boot.lua"}])):
            try:
                run(repo, mapping)
                ok = False
            except move.MoveError:
                ok = True
            s2 = snapshot(repo)
            s2.pop(os.path.join("dev", "docs", "arch", "MOVES.json"), None)
            s1 = dict(snap)
            s1.pop(os.path.join("dev", "docs", "arch", "MOVES.json"), None)
            check("refuses %s" % name, ok and s1 == s2)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("-- test_move: %d failed" % len(failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

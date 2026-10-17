"""Desktop launcher: Hold the Line's weekly challenge on the launcher's game page (launcher/ui/js/games.js htlWeek,
htlWeekLeft, htlChallenge) is the one the game runs (DisasterZone_HoldTheLine/Social.lua S:Week, S:WeekLeft,
S:Challenge): the same week, time left, challenge and seed, in Europe and elsewhere, around the reset days and over
the end of summer time. The game's own code runs (lupa), the launcher's runs in node; both in this PC's time zone.

Run: luaenv\\Scripts\\python.exe tests\\launcher\\test_weekly.py [-k name]
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(os.path.dirname(HERE))
ROOT = os.path.dirname(DEV)
sys.path.insert(0, os.path.join(DEV, "tests", "boot-ui"))
sys.path.insert(0, os.path.join(DEV, "tools"))

from _common import case, run_all  # noqa: E402
import release  # noqa: E402

SOCIAL = os.path.join(ROOT, "addon", "DisasterZone_HoldTheLine", "Social.lua")
GAMES_JS = os.path.join(ROOT, "launcher", "ui", "js", "games.js")


def names():
    folder = os.path.join(ROOT, "addon", release.HTL_FOLDER)
    files = {f: open(os.path.join(folder, f), "rb").read() for f in ("Data.lua", "Naxx.lua")}
    return release.htl_weekly_names({release.HTL_FOLDER: files})


def moments():
    """Times to compare: every 7 hours over five weeks from 18 Oct 2026 (summer time ends 25 Oct in Europe), and the
    minutes around local midnight of each day there."""
    start = int(time.mktime((2026, 10, 18, 0, 0, 0, 0, 0, -1)))
    out = list(range(start, start + 35 * 86400, 7 * 3600))
    for d in range(14):
        mid = int(time.mktime((2026, 10, 18 + d, 0, 0, 0, 0, 0, -1)))
        out += [mid - 1, mid, mid + 1, mid + 3599]
    return out


def lua_side(ts, region, challenge_names):
    """S:Week / S:WeekLeft / S:Challenge from the game's own Social.lua, for each time in `ts`."""
    import lupa.lua51 as lua51
    src = open(SOCIAL, encoding="utf-8").read()
    m = re.search(r"^local function RealmNow\(\).*?^function S:Challenge\(week\).*?^end\n", src, re.S | re.M)
    assert m, "Social.lua changed: RealmNow .. S:Challenge not found"
    rt = lua51.LuaRuntime(encoding="utf-8")
    rt.execute("date, time, max, floor = os.date, os.time, math.max, math.floor\nT, REGION = 0, 1\n"
               "function Now() return T end\nfunction GetCurrentRegion() return REGION end\nns, S, D = {}, {}, { CHALLENGES = {} }\n")
    g = rt.globals()
    for i, n in enumerate(challenge_names, 1):
        g.D.CHALLENGES[i] = rt.table_from({"name": n})
    rt.execute(m.group(0))
    g.REGION = 3 if region == "EU" else 1
    out = []
    for t in ts:
        g.T = t
        week = g.S.Week(g.S)
        left = g.S.WeekLeft(g.S)
        res = rt.eval("function() local c, seed = S:Challenge(); return c.name, seed end")()
        out.append([week, int(left), res[0], int(res[1])])
    return out


def js_side(ts, region, challenge_names):
    node = shutil.which("node")
    assert node, "node is needed for this test"
    script = (
        "const fs = require('fs'), vm = require('vm');"
        "const ctx = {}; vm.createContext(ctx);"
        "vm.runInContext(fs.readFileSync(process.argv[1], 'utf8') + ';this.f = { htlWeek, htlWeekLeft, htlChallenge };', ctx);"
        "const a = JSON.parse(process.argv[2]);"
        "console.log(JSON.stringify(a.ts.map((t) => { const w = ctx.f.htlWeek(t, a.region);"
        " const c = ctx.f.htlChallenge(w, a.names); return [w, ctx.f.htlWeekLeft(t, a.region), c.name, c.seed]; })));"
    )
    arg = json.dumps({"ts": ts, "region": region, "names": challenge_names})
    res = subprocess.run([node, "-e", script, GAMES_JS, arg], capture_output=True, text=True, encoding="utf-8")
    assert res.returncode == 0, res.stderr
    return json.loads(res.stdout)


def compare(region):
    ts = moments()
    n = names()
    lua, js = lua_side(ts, region, n), js_side(ts, region, n)
    for t, a, b in zip(ts, lua, js):
        assert a == b, "%s at %s (%s): game %s, launcher %s" % (region, t, time.strftime("%Y-%m-%d %H:%M", time.localtime(t)), a, b)
    return lua


@case
def europe_resets_on_wednesday_like_the_game():
    out = compare("EU")
    # (a week of 2026-10-21, a Wednesday)
    assert any(w == "2026-10-21" for w, *_ in out), sorted({w for w, *_ in out})


@case
def elsewhere_resets_on_tuesday_like_the_game():
    out = compare("US")
    assert any(w == "2026-10-20" for w, *_ in out), sorted({w for w, *_ in out})


@case
def the_built_in_list_matches_the_game():
    """games.js's HTL_WEEKLY (used when a release's notes carry no list) is the game's list."""
    js = open(GAMES_JS, encoding="utf-8").read()
    m = re.search(r"const HTL_WEEKLY = (\[.*?\]);", js)
    assert m and json.loads(m.group(1)) == names(), (m and m.group(1), names())


if __name__ == "__main__":
    run_all()

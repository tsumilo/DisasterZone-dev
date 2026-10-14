"""The Binding of Illidan's balance runs: the test bot (tests/games/_boi_bot.py) plays the bosses and whole runs in
the mock and prints what it measured.

  bosses  each boss many times (classes x seeds) with the items a player would have by then (1 on floor 1, then two
          more a floor): the fight's length (s) and the hits it would have cost (halves of a healthstone; god mode
          counts them without dying), and the share of fights the bot would have died in with that class's health
          (start health, plus a healthstone a floor from drops).
  runs    whole runs without god mode: how deep the bot gets, what kills it, how long a run lasts.

The bot is no expert (it dodges what it sees coming and keeps its distance), so read the numbers as a floor of what
a player can do: a fight the bot finishes is fine, one it cannot is too hard, the length is an upper bound.
Run (from dev): luaenv\\Scripts\\python.exe tools\\boi_balance.py [bosses|runs|all] [-n seeds] [--json out.json]
"""
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(DEV, "tests", "boot-ui"))
sys.path.insert(0, os.path.join(DEV, "tests", "games"))
from _common import solo  # noqa: E402
from _boi_bot import BOT_LUA  # noqa: E402

CLASSES = ["WARRIOR", "HUNTER", "MAGE", "PRIEST", "WARLOCK"]

LUA = r"""
T_BAL = {}
local E, D = ns.BoI, ns.BoIData
local PASSIVE = {}
for k, it in pairs(D.ITEMS) do if not it.active then PASSIVE[#PASSIVE + 1] = k end end
table.sort(PASSIVE)

-- the items a player would have when they reach floor f's boss
local function Kit(run, f, seed)
  local g = E.NewRng(seed * 13 + f)
  local want = 1 + (f - 1) * 2
  local tries = 0
  while #run.items < want and tries < 50 do
    tries = tries + 1
    local k = E.Pick(g, PASSIVE)
    if not run.has[k] then E.GiveItem(run, k, true) end
  end
end

function T_BAL.Boss(class, f, seed, cap)
  local run = E.New({ class = class, seed = seed })
  Kit(run, f, seed)
  run.god = true
  local boss = T_BOI.Fight(run, f)
  local frames = 0
  while frames < cap * 60 do
    frames = frames + 1
    E.Step(run, T_BOI.Input(run))
    if not run.bossF or run.room.cleared then break end
  end
  local hp = D.CLASSES[class].hp * 2 + (D.CLASSES[class].soul or 0) + (f - 1) * 2
  return { s = frames / 60, taken = run.taken or 0, by = run.takenBy or {}, done = run.room.cleared and true or false, hp = hp,
           phase = boss and boss.phase or 0, left = boss and math.floor(math.max(0, boss.hp) / boss.max * 100) or 0 }
end

function T_BAL.Run(class, seed, cap)
  local run = E.New({ class = class, seed = seed })
  local frames = 0
  while frames < cap * 60 and run.mode ~= 'dead' and run.mode ~= 'won' do
    frames = frames + 1
    E.Step(run, T_BOI.Input(run))
  end
  return { floor = run.floorN, mode = run.mode, killer = run.killer, s = run.time / 60, items = #run.items }
end
"""


def boot():
    w, c = solo("Alice", class_file="MAGE")
    c.eval(BOT_LUA)
    c.eval(LUA)
    return w, c


def bosses(c, n):
    out = {}
    for f in range(1, 6):
        rows = []
        for cls in CLASSES:
            for s in range(n):
                rows.append(c.eval_py("return T_BAL.Boss(...)", cls, f, 1000 + s * 37, 240))
        done = [r for r in rows if r["done"]]
        secs = [r["s"] for r in done]
        died = [r for r in rows if r["taken"] >= r["hp"]]
        out[f] = {
            "fights": len(rows), "finished": len(done),
            "median_s": round(statistics.median(secs), 1) if secs else None,
            "p90_s": round(sorted(secs)[int(len(secs) * 0.9) - 1], 1) if secs else None,
            "median_taken": statistics.median([r["taken"] for r in rows]),
            "would_die": round(len(died) / len(rows), 2),
            "by_class": {cls: round(statistics.median([r["s"] for r in rows[i * n:(i + 1) * n]]), 1) for i, cls in enumerate(CLASSES)},
            "stuck_left": [r["left"] for r in rows if not r["done"]][:10],
        }
        srcs = {}
        for r in rows:
            for k, v in (r.get("by") or {}).items():
                srcs[k] = srcs.get(k, 0) + v
        out[f]["sources"] = sorted(((k, round(v / len(rows), 1)) for k, v in srcs.items()), key=lambda kv: -kv[1])[:6]
        b = out[f]
        print("floor %d: %d/%d finished, median %ss (p90 %ss), hits taken median %s halves, would die %d%%, by class %s, unfinished at %s%%"
              % (f, b["finished"], b["fights"], b["median_s"], b["p90_s"], b["median_taken"], b["would_die"] * 100,
                 b["by_class"], b["stuck_left"]), flush=True)
        print("   hits per fight by source: %s" % b["sources"], flush=True)
    return out


def runs(c, n):
    rows = []
    for cls in CLASSES:
        for s in range(n):
            rows.append(dict(c.eval_py("return T_BAL.Run(...)", cls, 5000 + s * 101, 1800), cls=cls))
    floors = {f: sum(1 for r in rows if r["floor"] == f and r["mode"] == "dead") for f in range(1, 6)}
    wins = sum(1 for r in rows if r["mode"] == "won")
    killers = {}
    for r in rows:
        if r["mode"] == "dead":
            killers[r["killer"]] = killers.get(r["killer"], 0) + 1
    top = sorted(killers.items(), key=lambda kv: -kv[1])[:10]
    print("runs: %d, won %d; died on floor %s; killers %s; median run %ss"
          % (len(rows), wins, floors, top, round(statistics.median([r["s"] for r in rows]), 1)), flush=True)
    return {"rows": rows, "floors": floors, "wins": wins, "killers": top}


def main():
    what = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "all"
    n = int(sys.argv[sys.argv.index("-n") + 1]) if "-n" in sys.argv else 4
    w, c = boot()
    res = {}
    if what in ("bosses", "all"):
        res["bosses"] = bosses(c, n)
    if what in ("runs", "all"):
        res["runs"] = runs(c, n)
    if "--json" in sys.argv:
        json.dump(res, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()

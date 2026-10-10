"""Item sweep: swap each item into a base scenario, run WoWSims and the Lua sim, flag significant differences.

Usage:
  python item_sweep.py base_scenario.json --items 28830,29383 | --wowsims-ret-items | --wowsims-items rogue/TestRogue
       [--lua-iterations 1000]
       [--ws-iterations 20000] [--jobs 4] [--out sweep.json]

Uses the dev kit's lupa env for the Lua side (run with dev/luaenv/Scripts/python.exe).
"""
import argparse
import json
import math
import multiprocessing as mp
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import wowsims_ref  # noqa: E402

WOWSIMS = wowsims_ref.WOWSIMS
# proto ItemType -> EquipmentSpec slot index (0-based)
SLOT_BY_TYPE = {1: 0, 2: 1, 3: 2, 4: 3, 5: 4, 6: 5, 7: 6, 8: 7, 9: 8, 10: 9, 11: 10, 12: 12, 13: 14, 14: 16}


def ret_items():
    return test_items("paladin/retribution/TestRetribution")


def test_items(rel):
    """The items a WoWSims class test sweeps (sim/<rel>.results AllItems-...)."""
    res = open(os.path.join(WOWSIMS, "sim", *(rel + ".results").split("/")), encoding="utf-8").read()
    return sorted(set(int(m) for m in re.findall(r'AllItems-[^"]*?-(\d+)"', res)))


def item_db():
    db = json.load(open(os.path.join(WOWSIMS, "assets", "database", "db.json"), encoding="utf-8"))
    return {i["id"]: i for i in db["items"]}


def scenario_for(base, item):
    slot = SLOT_BY_TYPE.get(item.get("type"))
    if slot is None:
        return None
    sc = json.loads(json.dumps(base))
    gear = sc["gear"]
    while len(gear) < 17:
        gear.append({})
    if item.get("type") == 13:
        # a dual wielder's base sims one-handers (an off-hand-only one in the off hand), a 2H base only 2H weapons
        dw = bool((gear[15] or {}).get("id"))
        hand = item.get("handType")
        if dw:
            if hand == 4:
                return None
            slot = 15 if hand == 3 else 14
        elif hand != 4:
            return None
    gear[slot] = {"id": item["id"]}
    sc["sweepItem"] = item["id"]
    return sc


def run_lua_job(args):
    sc, n = args
    import run_lua
    try:
        r = run_lua.run(sc, n)
        return sc["sweepItem"], r["dps"], r["stderr"], None
    except Exception as e:  # noqa: BLE001
        return sc["sweepItem"], None, None, str(e).splitlines()[0][:200]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("--items")
    ap.add_argument("--wowsims-ret-items", action="store_true")
    ap.add_argument("--wowsims-items", help="class test whose items to sweep, e.g. rogue/TestRogue")
    ap.add_argument("--lua-iterations", type=int, default=1000)
    ap.add_argument("--ws-iterations", type=int, default=20000)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--out", default=os.path.join(HERE, "logs", "sweep.json"))
    a = ap.parse_args()
    base = json.load(open(a.base, encoding="utf-8"))
    items = item_db()
    if a.wowsims_items:
        ids = test_items(a.wowsims_items)
    else:
        ids = ret_items() if a.wowsims_ret_items else [int(x) for x in a.items.split(",")]
    scs = []
    for i in ids:
        if i not in items:
            continue
        sc = scenario_for(base, items[i])
        if sc:
            scs.append(sc)
    print("%d scenarios" % len(scs), flush=True)
    ws = {}
    for sc in scs:
        try:
            r = wowsims_ref.run(sc, a.ws_iterations)
            ws[sc["sweepItem"]] = (r["dps"], r["dpsStdev"] / math.sqrt(r["iterations"]))
        except Exception as e:  # noqa: BLE001
            ws[sc["sweepItem"]] = (None, str(e)[:200])
    print("wowsims done", flush=True)
    with mp.Pool(a.jobs) as pool:
        lua = pool.map(run_lua_job, [(sc, a.lua_iterations) for sc in scs])
    out = []
    for iid, dps, se, err in lua:
        w, wse = ws.get(iid, (None, None))
        row = {"id": iid, "name": items[iid]["name"], "ws": w, "lua": dps, "err": err}
        if w is not None and dps is not None:
            row["diffPct"] = (dps - w) / w * 100
            row["z"] = (dps - w) / math.sqrt(se ** 2 + wse ** 2)
        out.append(row)
    out.sort(key=lambda r: -abs(r.get("z") or 99))
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    json.dump(out, open(a.out, "w"), indent=1)
    for r in out:
        if r.get("err") or r["ws"] is None:
            print("  ERR  %-6d %-40s %s" % (r["id"], r["name"][:40], r.get("err") or "wowsims failed"))
        elif abs(r["z"]) > 3:
            print("  BAD  %-6d %-40s ws %8.1f lua %8.1f  %+6.2f%%  z %+5.1f" % (r["id"], r["name"][:40], r["ws"], r["lua"], r["diffPct"], r["z"]))
    ok = sum(1 for r in out if r.get("z") is not None and abs(r["z"]) <= 3)
    print("%d ok, %d flagged" % (ok, len(out) - ok))


if __name__ == "__main__":
    main()

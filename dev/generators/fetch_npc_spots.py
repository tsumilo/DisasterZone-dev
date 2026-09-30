"""Where every creature of the TBC raids stands (for the starter strategies, gen_starter_strategies.py).

wowhead.com (retail) lists each zone's creatures and, per creature, its spawn points on Blizzard's floor maps (the
same maps as dev/art/blizzard_maps): g_mapperData = {"<zone>": [{coords}]} or {"<zone>": {"<floor>": {coords}}}.
Summoned adds have none. Cached in data/npc_spots.json ({npc id: {name, zone, spots: {floor: [[x, y], ...]}}}, x/y
in percent of the map), so a re-run only fetches what is missing.

Run: luaenv\\Scripts\\python.exe generators\\fetch_npc_spots.py
"""
import json
import os
import re
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "data", "npc_spots.json")
ZONES = [3457, 3923, 3836, 3607, 3845, 3606, 3959, 3805, 4075]


def get(url):
    # curl, not urllib: wowhead refuses Python's TLS client
    for attempt in range(4):
        r = subprocess.run(["curl", "-sL", "-A", "Mozilla/5.0", url], capture_output=True)
        html = r.stdout.decode("utf-8", "replace")
        time.sleep(1.5)
        if "g_mapperData" in html or "id: 'npcs'" in html:
            return html
        time.sleep(10 * (attempt + 1))
    raise SystemExit("wowhead refused %s (rate limit?); re-run later, the cache keeps what was fetched" % url)


def zone_npcs(zone):
    html = get("https://www.wowhead.com/zone=%d" % zone)
    m = re.search(r"id: *'npcs'.*?data: *(\[.*?\])\s*\}\);", html, re.S)
    if not m:
        return {}
    return {str(n["id"]): n["name"] for n in json.loads(m.group(1))}


def spots(npc, zone):
    html = get("https://www.wowhead.com/npc=%s" % npc)
    m = re.search(r"g_mapperData = (.*?);\s*$", html, re.M)
    data = json.loads(m.group(1)) if m else []
    out = {}
    z = data.get(str(zone)) if isinstance(data, dict) else None
    if isinstance(z, list):
        out["0"] = [c for e in z for c in e.get("coords", [])]
    elif isinstance(z, dict):
        for floor, e in z.items():
            out[floor] = e.get("coords", [])
    return out


def main():
    cache = json.load(open(CACHE, encoding="utf-8")) if os.path.exists(CACHE) else {}
    for zone in ZONES:
        npcs = zone_npcs(zone)
        todo = [i for i in npcs if i not in cache]
        print("zone %d: %d creatures, %d to fetch" % (zone, len(npcs), len(todo)), flush=True)
        for i in todo:
            cache[i] = {"name": npcs[i], "zone": zone, "spots": spots(i, zone)}
            json.dump(cache, open(CACHE, "w", encoding="utf-8"), indent=0, sort_keys=True)
    print("creatures: %d" % len(cache))


if __name__ == "__main__":
    main()

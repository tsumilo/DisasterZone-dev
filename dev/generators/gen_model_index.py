"""The models the strategy boards may place by ID: Data/ModelIndex.lua.

A creature can be named by its NPC ID (what Wowhead shows) or its display ID; a game object by its entry. The board
stores creatures as "boss:<display>" and objects as "obj:<entry>" (Core/Strategy.lua), so it needs:
  npc    NPC ID -> display ID (the first model) and the NPC's own scale (AzerothCore creature_template_model)
  obj    object entry -> display ID and size (AzerothCore gameobject_template)
  odisp  object display -> model file ID and its box (GameObjectDisplayInfo, build 2.5.6.69795)
  cscale creature display -> CreatureModelScale when it is not 1 (CreatureDisplayInfo; the client's actors ignore it)
  cdisp  the creature display IDs this client has, as runs (start, count)

Only model files this client has are listed, each read from the installed client and checked to be an M2 (MD21 / MD20):
SetModelByFileID with any other file ID crashes the client (WoWUIBugs #67), so the addon never passes it a number that
is not in odisp. AzerothCore is a 3.3.5 server: its Wrath-only creatures and objects drop out here (no display in 2.5.6).

Each table is a list of fixed-width records in base 36, sorted by key and cut into pieces of PIECE records; the addon
finds a key by binary search over the pieces and then inside one (Core/StrategyObjects.lua), with no unpacking.

Run: luaenv\\Scripts\\python.exe generators\\gen_model_index.py
"""
import csv
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_rooms as R  # noqa: E402
import casc_local  # noqa: E402

OUT = os.path.join(R.ADDON, "Data", "ModelIndex.lua")
ACORE = "https://raw.githubusercontent.com/azerothcore/azerothcore-wotlk/master/data/sql/base/db_world/"
WAGO = "https://wago.tools/db2/%s/csv?build=2.5.6.69795"
PIECE = 32
DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
BOX_BIAS = 23328                 # a box value (model units) as round(v * 100) + this, 3 digits: -233.28 .. 233.27


def b36(n, width):
    if n < 0 or n >= 36 ** width:
        raise ValueError("%d does not fit %d base-36 digits" % (n, width))
    s = ""
    for _ in range(width):
        s = DIGITS[n % 36] + s
        n //= 36
    return s


def sql_rows(path):
    """The value tuples of a mysqldump file's INSERT statements, each a list of str / int / float / None."""
    text = open(path, encoding="utf-8", errors="replace").read()
    rows = []
    i = 0
    n = len(text)
    while True:
        i = text.find("INSERT INTO", i)
        if i < 0:
            break
        i = text.find("VALUES", i) + 6
        while i < n:
            while text[i] in " \r\n\t,":
                i += 1
            if text[i] != "(":
                break
            i += 1
            row, cur, quoted = [], [], False
            while True:
                ch = text[i]
                if quoted:
                    if ch == "\\":
                        cur.append(text[i + 1])
                        i += 2
                        continue
                    if ch == "'":
                        if text[i + 1] == "'":
                            cur.append("'")
                            i += 2
                            continue
                        quoted = False
                        i += 1
                        continue
                    cur.append(ch)
                    i += 1
                    continue
                if ch == "'":
                    quoted = True
                    cur.append("\0")             # (marks a string value)
                    i += 1
                    continue
                if ch in ",)":
                    v = "".join(cur).strip()
                    if v.startswith("\0"):
                        row.append(v[1:])
                    elif v == "NULL":
                        row.append(None)
                    else:
                        try:
                            row.append(int(v))
                        except ValueError:
                            row.append(float(v))
                    cur = []
                    i += 1
                    if ch == ")":
                        break
                    continue
                cur.append(ch)
                i += 1
            rows.append(row)
    return rows


def m2_files(fids):
    """The file IDs of fids that the installed client has as M2 models (cached in dev/art/rooms/m2_check.json)."""
    path = os.path.join(R.CACHE, "m2_check.json")
    seen = json.load(open(path)) if os.path.exists(path) else {}
    build = casc_local.build_name()
    if seen.get("build") != build:
        seen = {"build": build}
    todo = [f for f in fids if str(f) not in seen]
    for k, f in enumerate(todo):
        try:
            head = casc_local.read_fid(f)[:4]
            seen[str(f)] = head in (b"MD21", b"MD20")
        except (KeyError, ValueError):
            seen[str(f)] = False
        if k % 200 == 199:
            print("  checked %d / %d model files" % (k + 1, len(todo)), flush=True)
    tmp = path + ".tmp"
    json.dump(seen, open(tmp, "w"), indent=0, sort_keys=True)
    os.replace(tmp, path)
    return {f for f in fids if seen.get(str(f))}


def pieces(records):
    return ["".join(records[i:i + PIECE]) for i in range(0, len(records), PIECE)]


def main():
    cdi = list(csv.DictReader(open(R._get(WAGO % "CreatureDisplayInfo", os.path.join(R.CACHE, "CreatureDisplayInfo.csv")),
                                   encoding="utf-8")))
    godi = list(csv.DictReader(open(R._get(WAGO % "GameObjectDisplayInfo",
                                           os.path.join(R.CACHE, "GameObjectDisplayInfo.csv")), encoding="utf-8")))
    ctm = sql_rows(R._get(ACORE + "creature_template_model.sql", os.path.join(R.CACHE, "creature_template_model.sql")))
    got = sql_rows(R._get(ACORE + "gameobject_template.sql", os.path.join(R.CACHE, "gameobject_template.sql")))
    R._get(ACORE + "gameobject.sql", os.path.join(R.CACHE, "gameobject.sql"))   # (the starters' object spawns)

    displays = {int(r["ID"]) for r in cdi}
    cscale = {int(r["ID"]): float(r["CreatureModelScale"] or 1) for r in cdi}

    # object displays with a model this client has
    ok = m2_files(sorted({int(r["FileDataID"]) for r in godi if int(r["FileDataID"] or 0) > 0}))
    odisp = {}
    for r in godi:
        fid = int(r["FileDataID"] or 0)
        if fid in ok:
            odisp[int(r["ID"])] = (fid, [float(r["GeoBox_%d" % k]) for k in range(6)])

    npc = {}
    for cid, idx, disp, scale, *_ in ctm:
        if disp in displays and (cid not in npc or idx < npc[cid][2]):
            npc[cid] = (disp, scale or 1.0, idx)
    obj = {}
    for row in got:
        entry, _, disp, size = row[0], row[1], row[2], row[7]
        if disp in odisp:
            obj[entry] = (disp, size or 1.0)

    def pct(v):
        return max(1, min(36 ** 3 - 1, int(round(v * 100))))

    rec_npc = [b36(k, 4) + b36(d, 4) + b36(pct(s), 3) for k, (d, s, _) in sorted(npc.items())]
    rec_obj = [b36(k, 4) + b36(d, 4) + b36(pct(s), 3) for k, (d, s) in sorted(obj.items())]
    rec_odisp = [b36(k, 4) + b36(f, 5) + "".join(b36(max(0, min(36 ** 3 - 1, int(round(v * 100)) + BOX_BIAS)), 3)
                                                 for v in box)
                 for k, (f, box) in sorted(odisp.items())]
    rec_cscale = [b36(k, 4) + b36(pct(s), 3) for k, s in sorted(cscale.items()) if abs(s - 1) > 0.005]
    runs, ids = [], sorted(displays)
    for d in ids:
        if runs and runs[-1][0] + runs[-1][1] == d and runs[-1][1] < 36 ** 3 - 1:
            runs[-1][1] += 1
        else:
            runs.append([d, 1])
    rec_cdisp = [b36(s, 4) + b36(c, 3) for s, c in runs]

    def table(name, width, key, records, note):
        out = ["  -- %s" % note, "  %s = { w = %d, k = %d," % (name, width, key)]
        out += ['    "%s",' % p for p in pieces(records)]
        out.append("  },")
        return out

    lines = [
        "-- DisasterZone: the models the strategy boards may place by ID (Core/StrategyObjects.lua reads it): NPC and object",
        "-- IDs to their models, the object models' files and boxes, the creature models' sizes. Fixed-width base-36",
        "-- records sorted by key, %d to a piece; a box value is round(v * 100) + %d (model units)." % (PIECE, BOX_BIAS),
        "-- Sources: AzerothCore creature_template_model / gameobject_template; wago.tools CreatureDisplayInfo and",
        "-- GameObjectDisplayInfo (build 2.5.6.69795); every model file checked in the installed client (an M2).",
        "-- AUTO-GENERATED by gen_model_index.py; do not edit by hand.",
        "local _, ns = ...",
        "ns.Data = ns.Data or {}",
        "ns.Data.ModelIndex = {",
    ]
    lines += table("npc", 11, 4, rec_npc, "NPC ID (4) -> display ID (4), the NPC's scale in percent (3)")
    lines += table("obj", 11, 4, rec_obj, "object entry (4) -> display ID (4), size in percent (3)")
    lines += table("odisp", 27, 4, rec_odisp, "object display (4) -> model file ID (5), box x0 y0 z0 x1 y1 z1 (3 each)")
    lines += table("cscale", 7, 4, rec_cscale, "creature display (4) -> CreatureModelScale in percent (3), when not 100")
    lines += table("cdisp", 7, 4, rec_cdisp, "creature display IDs of this client: runs of start (4), count (3)")
    lines.append("}")
    src = "\n".join(lines) + "\n"
    tmp = OUT + ".tmp"
    open(tmp, "w", encoding="utf-8", newline="\n").write(src)
    os.replace(tmp, OUT)
    print("ModelIndex: %d NPCs, %d objects, %d object models, %d creature scales, %d display runs; %d KB" % (
        len(rec_npc), len(rec_obj), len(rec_odisp), len(rec_cscale), len(rec_cdisp), len(src) // 1024))


if __name__ == "__main__":
    main()

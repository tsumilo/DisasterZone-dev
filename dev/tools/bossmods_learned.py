r"""What the boss mods learned from the guild's pulls, read from the game's SavedVariables, against the data files.

The addon keeps every pull it recorded or received in DisasterZoneBossLearnDB (format: dev/docs/bossmods/LEARNING.md).
This reads that table (lupa, Lua 5.1), works the windows out again with the addon's own rules (it runs
addon/DisasterZone/Core/BossLearnMath.lua itself, so the numbers are the game's), and prints per raid and boss:
the data's number against what was learned, how many pulls and samples, applied or flagged (far from DBM, varies,
fixed), alerts that never fired with the casts of the same name the boss used instead, unknown casts and yells, and
the developer's review decisions (what to bake into Data/BossMods/*.lua).

Usage (from dev):
    luaenv\Scripts\python.exe tools\bossmods_learned.py [SavedVariables.lua ...] [--json] [--boss KEY] [--raid RAID]
                                                       [--all] [--no-names]
    no path: C:\World of Warcraft\_anniversary_\WTF\Account\*\SavedVariables\DisasterZone*.lua (every file that has
    DisasterZoneBossLearnDB). --all also lists bosses without pulls. --no-names skips the 2.5.6 spell name table
    (art/rooms/db2/SpellName.csv, read only when it is already there: never downloaded).
Exit code 0, or 2 when no file has the table.
"""
import argparse
import csv
import glob
import json
import os
import re
import sys

from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
ADDON = os.environ.get("DISASTERZONE_ADDON_DIR") or os.path.join(DEV, "..", "addon", "DisasterZone")
DEFAULT_GLOB = r"C:\World of Warcraft\_anniversary_\WTF\Account\*\SavedVariables\DisasterZone*.lua"
SPELL_CSV = os.path.join(DEV, "art", "rooms", "db2", "SpellName.csv")
DASH = "\u2013"


def raid_names():
    """{raid key: name}, {boss key: name} from Data/Items.lua (plain text: no Lua run)."""
    raids, bosses, raid = {}, {}, None
    path = os.path.join(ADDON, "Data", "Items.lua")
    for line in open(path, encoding="utf-8"):
        m = re.match(r'^  \{ key = "(\w+)", name = "([^"]+)"', line)
        if m:
            raid = m.group(1)
            raids[raid] = m.group(2)
            continue
        m = re.match(r'^    \{ key = "(\w+)", name = "([^"]+)"', line)
        if m and raid:
            bosses["%s:%s" % (raid, m.group(1))] = m.group(2)
    bosses["HyjalSummit:Waves"] = "Trash waves"
    return raids, bosses


def spell_names(enabled):
    if not enabled or not os.path.isfile(SPELL_CSV):
        return {}
    out = {}
    with open(SPELL_CSV, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            try:
                out[int(r["ID"])] = r["Name_lang"]
            except (KeyError, ValueError):
                pass
    return out


class Lua:
    """One Lua 5.1 state with the addon's learning rules and boss data, and the saved table of one file."""

    def __init__(self):
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        self.ns = self.lua.table()
        self._run = self.lua.eval("function(src, name, ns) local f, e = loadstring(src, '@' .. name); "
                                  "if not f then error(e) end; return f('DisasterZone', ns) end")
        self.load(os.path.join("Core", "BossLearnMath.lua"))
        data = os.path.join(ADDON, "Data", "BossMods")
        for f in sorted(os.listdir(data)):
            if f.endswith(".lua"):
                self.load(os.path.join("Data", "BossMods", f))
        self.M = self.ns["BossLearnMath"]
        self.mods = self.ns["Data"]["BossMods"]

    def load(self, rel):
        src = open(os.path.join(ADDON, rel), encoding="utf-8").read()
        self._run(src, rel.replace("\\", "/"), self.ns)

    def saved(self, path):
        """The DisasterZoneBossLearnDB table of a SavedVariables file (nil -> None)."""
        src = open(path, encoding="utf-8", errors="replace").read()
        if "DisasterZoneBossLearnDB" not in src:
            return None
        g = self.lua.globals()
        g.DisasterZoneBossLearnDB = None
        f = self.lua.eval("function(src) local f, e = loadstring(src, '@saved'); if not f then error(e) end; f() end")
        f(src)
        return g.DisasterZoneBossLearnDB


def py(v):
    """A Lua value as Python (tables with 1..n keys as lists)."""
    if lua51.lua_type(v) == "table":
        keys = list(v.keys())
        if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [py(v[k]) for k in sorted(keys)]
        return {k: py(v[k]) for k in keys}
    if lua51.lua_type(v) == "function":
        return None
    return v


def num(x):
    if x is None:
        return "?"
    return str(int(x)) if float(x) == int(x) else "%.1f" % x


def rng(lo, hi=None):
    if lo is None:
        return "-"
    if hi is None or hi == lo:
        return num(lo) + " s"
    return "%s%s%s s" % (num(lo), DASH, num(hi))


def window(v):
    if isinstance(v, (int, float)):
        return [v, v]
    if isinstance(v, list) and v:
        return [v[0], v[1] if len(v) > 1 else v[0]]
    return None


def report_boss(L, db, key, names, boss_names):
    """Everything about one boss as a dict (the JSON shape)."""
    M = L.M
    d = L.mods[key]
    pulls = db["pulls"][key] if db["pulls"] and db["pulls"][key] else L.lua.table()
    ds = M.Signature(d)
    learned, used = M.LearnBoss(d, pulls, ds)
    out = {"boss": key, "name": boss_names.get(key, key.split(":")[1]), "signature": ds, "pulls": len(py(pulls) or []),
           "usable": used, "stale": 0, "alerts": {}, "never_fired": {}, "unknown": [], "yells": [], "decisions": {},
           "suggest": []}
    for rec in py(pulls) or []:
        if rec.get("ds") != ds:
            out["stale"] += 1
    alerts = py(d["alerts"]) or []
    saved = py(db["learned"][key]) if db["learned"] and db["learned"][key] else None
    for i, a in enumerate(alerts):
        k = a.get("key")
        res = M.Learnable(d["alerts"][i + 1])
        ok, why = res if isinstance(res, tuple) else (res, None)
        e = py(learned[k]) if learned[k] else None
        entry = {"kind": a.get("kind"), "spell": a.get("spell"), "spell_name": names.get(a.get("spell")),
                 "learnable": bool(ok), "why": None if ok else why, "fields": {}}
        for f in ("start", "cd"):
            if a.get(f) is None:
                continue
            fit = (e or {}).get(f) or {}
            in_game = ((saved or {}).get("alerts") or {}).get(k, {}).get(f) if saved else None
            entry["fields"][f] = {
                "data": window(a.get(f)), "state": fit.get("state") if ok else "not learned",
                "applied": bool(fit.get("applied")), "lo": fit.get("lo"), "hi": fit.get("hi"),
                "measured": [fit.get("mlo"), fit.get("mhi")] if fit.get("mlo") is not None else None,
                "pulls": fit.get("p", 0), "samples": fit.get("n", 0), "dropped": fit.get("dropped", 0),
                "clamped": bool(fit.get("clamped")),
                "in_game": None if not in_game else {"state": in_game.get("state"), "lo": in_game.get("lo"),
                                                       "hi": in_game.get("hi")},
            }
        if entry["fields"] or not ok:
            out["alerts"][k] = entry
    never = py(M.NeverFired(pulls, ds, 2)) or {}
    unk = py(M.Unknown(pulls, ds)) or []
    for u in unk:
        u["name"] = u.get("name") or names.get(u.get("id"))
    for k, n in sorted(never.items()):
        a = next((x for x in alerts if x.get("key") == k), {})
        ids = []
        on = a.get("on")
        for t in ([on] if isinstance(on, str) else (on or [])):
            word, rest = (t.split(" ", 1) + [""])[:2]
            if word in ("CAST", "SUCCESS", "AURA", "AURAGONE", "SUMMON", "HIT", "HEAL"):
                ids += [int(x) for x in re.findall(r"\d+", rest)]
        own = {(names.get(i) or "").lower() for i in ids + ([a["spell"]] if a.get("spell") else [])} - {""}
        cands = [u for u in unk if u.get("name") and u["name"].lower() in own and u["id"] not in ids]
        out["never_fired"][k] = {"pulls": n, "ids": ids, "names": sorted(own), "candidates": cands or unk[:3]}
    out["unknown"] = unk
    out["yells"] = py(M.Yells(pulls, ds)) or []
    rv = db["review"]
    if rv:
        dec = py(rv["decisions"][key]) if rv["decisions"] and rv["decisions"][key] else {}
        out["decisions"] = dec or {}
        sug = py(rv["suggest"][key]) if rv["suggest"] and rv["suggest"][key] else []
        out["suggest"] = sug or []
    return out


def print_boss(b):
    print("  %s (%s) · %d pulls stored, %d usable%s" % (
        b["name"], b["boss"], b["pulls"], b["usable"],
        (" · %d recorded against older data (ignored)" % b["stale"]) if b["stale"] else ""))
    for k, a in b["alerts"].items():
        label = "%-11s %-22s" % (k, (a.get("spell_name") or (a.get("spell") and "spell %s" % a["spell"]) or "")[:22])
        if not a["learnable"]:
            print("    %s not learned: %s" % (label, a["why"]))
            continue
        for f, x in a["fields"].items():
            data = rng(*x["data"]) if x["data"] else "-"
            st = x["state"] or "no samples"
            if st == "ok":
                what = "learned %s%s  APPLIED" % (rng(x["lo"], x["hi"]), " (clamped)" if x["clamped"] else "")
            elif st in ("far", "varies"):
                what = "%s: measured %s  NOT applied" % ("far from the data" if st == "far" else "varies",
                                                         rng(*x["measured"]))
            elif st == "fixed":
                what = "fixed" + ((", measured %s" % rng(*x["measured"])) if x["measured"] else "")
            else:
                what = "learning %d of 3" % min(x["pulls"], 2)
            print("    %s %-5s data %-10s %s  (%d pulls, %d samples%s)" % (
                label, f, data, what, x["pulls"], x["samples"],
                (", %d outliers dropped" % x["dropped"]) if x["dropped"] else ""))
            ig = x.get("in_game")
            if ig and (ig.get("state") != x["state"] or ig.get("lo") != x["lo"] or ig.get("hi") != x["hi"]):
                print("      (in game it was %s %s)" % (ig.get("state"), rng(ig.get("lo"), ig.get("hi"))))
    for k, n in b["never_fired"].items():
        c = ", ".join("%s %s (%d pulls)" % (u["id"], u.get("name") or "?", u["pulls"]) for u in n["candidates"])
        print("    NEVER FIRED %s (ids %s%s) in %d pulls; candidates: %s" % (
            k, ", ".join(str(i) for i in n["ids"]) or "-", (": " + ", ".join(n["names"])) if n["names"] else "",
            n["pulls"], c or "none"))
    if b["unknown"]:
        print("    unknown casts: " + ", ".join("%s %s (%d pulls, %dx)" % (u["id"], u.get("name") or "?", u["pulls"],
                                                                         u["n"]) for u in b["unknown"][:8]))
    for y in b["yells"][:6]:
        print("    unknown line (%d pulls): \"%s\"" % (y["pulls"], y["text"]))
    for k, d in sorted(b["decisions"].items()):
        if d.get("use"):
            print("    DECISION %s: use %s instead of %s (%s)" % (k, d["use"], d.get("from"), d.get("name") or ""))
        else:
            print("    DECISION %s: ignore (%s)" % (k, d.get("what") or ""))
    for s in b["suggest"]:
        print("    open suggestion: %s" % json.dumps(s, ensure_ascii=False))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--boss")
    ap.add_argument("--raid")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--no-names", action="store_true")
    a = ap.parse_args(argv)
    paths = a.paths or sorted(glob.glob(DEFAULT_GLOB))
    raids, boss_names = raid_names()
    names = spell_names(not a.no_names)
    L = Lua()
    result, found = {}, 0
    for path in paths:
        if not os.path.isfile(path):
            continue
        db = L.saved(path)
        if db is None:
            continue
        found += 1
        # (names the game saw, for ids the spell table doesn't have here)
        for key in (py(db["pulls"]) or {}):
            for rec in py(db["pulls"][key]) or []:
                for u in rec.get("u") or []:
                    if u.get("name") and u.get("id") not in names:
                        names[u["id"]] = u["name"]
        bosses = {}
        keys = sorted(set(py(db["pulls"]) or {}) | (set(L.mods.keys()) if a.all else set()))
        for key in keys:
            if L.mods[key] is None:
                continue
            if a.boss and key != a.boss:
                continue
            if a.raid and key.split(":")[0] != a.raid:
                continue
            bosses[key] = report_boss(L, db, key, names, boss_names)
        result[path] = {"format": db["v"], "bosses": bosses, "log": py(db["log"]) or []}
    if not found:
        print("no DisasterZoneBossLearnDB in: " + (", ".join(paths) or DEFAULT_GLOB))
        return 2
    if a.json:
        print(json.dumps(result, indent=1, ensure_ascii=False, sort_keys=True))
        return 0
    for path, r in result.items():
        n = sum(b["pulls"] for b in r["bosses"].values())
        print("%s  (format %s, %d pulls)" % (path, r["format"], n))
        by_raid = {}
        for key, b in r["bosses"].items():
            by_raid.setdefault(key.split(":")[0], []).append(b)
        for raid in sorted(by_raid):
            print()
            print(raids.get(raid, raid))
            for b in by_raid[raid]:
                print_boss(b)
        if r["log"]:
            print()
            print("saved log:")
            for line in r["log"]:
                print("  " + line)
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass
    sys.exit(main())

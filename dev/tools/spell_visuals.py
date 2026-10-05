"""A spell's visual effect models, for Data/EncounterObjects.lua (what a state shows: a beam's target effect, an aura).

For each spell ID: SpellXSpellVisual -> SpellVisual -> SpellVisualEvent (when it plays, on whom) -> SpellVisualKitEffect
type 2 -> SpellVisualKitModelAttach (attachment point) -> SpellVisualEffectName.ModelFileDataID
and its M2 header bounds (model units: for an effect's fxSize). Also the spell's icon file. Tables from wago.tools (build 2.5.6.69795), cached in dev/art/rooms/db2/.

Event TargetType: 1 the caster, 2 the target. StartEvent / EndEvent (SpellVisualEvent, wowdev naming): 3 cast,
6 impact, 7 aura start, 8 aura end, 11 channel start, 12 channel end, 13 one-shot end.
AttachmentID as the Raid Trainer uses them: 34 chest, 20 head, 21 spell hand, 19 base.

Run: luaenv\\Scripts\\python.exe tools\\spell_visuals.py <spell id> [...]
"""
import csv
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(DEV, "generators"))
import gen_rooms as R  # noqa: E402
import casc_local  # noqa: E402

CACHE = os.path.join(DEV, "art", "rooms", "db2")
WAGO = "https://wago.tools/db2/%s/csv?build=2.5.6.69795"
_T = {}


def table(name):
    if name not in _T:
        os.makedirs(CACHE, exist_ok=True)
        path = R._get(WAGO % name, os.path.join(CACHE, name + ".csv"))
        _T[name] = list(csv.DictReader(open(path, encoding="utf-8")))
    return _T[name]


def index(name, field):
    key = (name, field)
    if key not in _T:
        out = {}
        for r in table(name):
            out.setdefault(int(r[field] or 0), []).append(r)
        _T[key] = out
    return _T[key]


def m2_bounds(fid):
    try:
        d = casc_local.read_fid(fid)
    except (KeyError, ValueError):
        return None
    if d[:4] == b"MD21":
        d = d[8:]
    return [round(v, 3) for v in struct.unpack_from("<6f", d, 0xA0)]


def visuals(spell):
    out = {"spell": spell, "kits": []}
    misc = index("SpellMisc", "SpellID").get(spell, [])
    if misc:
        out["icon"] = int(misc[0].get("SpellIconFileDataID") or 0)
    for x in index("SpellXSpellVisual", "SpellID").get(spell, []):
        vis = int(x["SpellVisualID"])
        for ev in index("SpellVisualEvent", "SpellVisualID").get(vis, []):
            kit = int(ev["SpellVisualKitID"])
            for eff in index("SpellVisualKitEffect", "ParentSpellVisualKitID").get(kit, []):
                if eff["EffectType"] != "2":
                    continue
                for att in index("SpellVisualKitModelAttach", "ID").get(int(eff["Effect"]), []):
                    for en in index("SpellVisualEffectName", "ID").get(int(att["SpellVisualEffectNameID"]), []):
                        fid = int(en.get("ModelFileDataID") or 0)
                        out["kits"].append({"visual": vis, "kit": kit, "start": int(ev["StartEvent"]),
                                            "end": int(ev["EndEvent"]), "target": int(ev["TargetType"]),
                                            "attach": int(att["AttachmentID"]), "file": fid,
                                            "scale": float(en.get("Scale") or 1), "bounds": m2_bounds(fid)})
    return out


if __name__ == "__main__":
    for a in sys.argv[1:]:
        v = visuals(int(a))
        print("spell %s icon %s" % (v["spell"], v.get("icon")))
        for k in v["kits"]:
            print("  visual %(visual)d kit %(kit)d events %(start)d-%(end)d on %(target)d attach %(attach)d "
                  "file %(file)d scale %(scale)s bounds %(bounds)s" % k)

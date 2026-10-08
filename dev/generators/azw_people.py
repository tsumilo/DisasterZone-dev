"""Azeromon world: map sprites for people and creatures from their own WoW models (azw_render), so the characters
match the ground, the scenery and each other.

People (a creature display with ExtendedDisplayInfoID - a dressed character model): the race / sex model, its
baked NPC skin (CreatureDisplayInfoExtra.BakeMaterialResourcesID -> TextureFileData: the client's own picture of
that NPC's body, face and clothes), its hair style (CharHairGeosets) and beard (CharacterFacialHairStyles), the
pieces its equipment adds (NPCModelItemSlotDisplayInfo -> ItemDisplayInfo geoset groups: gloves, boots, sleeves,
robe, tabard, cape) and its hair drawn in the hair colour.
Creatures: the model with the display's texture variations.

frames(display_id) -> {"down"|"left"|"right"|"up": 16x16 RGBA uint8} or None. Seen from the south and a little
above (ELEV), people ~15 px tall."""
import csv
import math
import os

import numpy as np

import azw_render as RD
import casc_local as C

HERE = os.path.dirname(os.path.abspath(__file__))
DB2 = os.path.join(HERE, "..", "art", "tbcdb", "db2")
ELEV = 26
SIZE = 32
FACING = {"up": 0.0, "down": math.pi, "left": math.pi / 2, "right": -math.pi / 2}

_T = {}


def table(name, key="ID"):
    k = (name, key)
    if k not in _T:
        with open(os.path.join(DB2, name + ".csv"), encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        if key is None:
            _T[k] = rows
        else:
            _T[k] = {int(r[key]): r for r in rows}
    return _T[k]


def _multi(name, key):
    k = (name, key, "multi")
    if k not in _T:
        out = {}
        for r in table(name, None):
            out.setdefault(int(r[key]), []).append(r)
        _T[k] = out
    return _T[k]


HAIR = [(46, 32, 22), (24, 22, 22), (104, 66, 34), (150, 104, 56), (204, 170, 96), (150, 62, 30), (128, 126, 122),
        (220, 210, 178), (86, 48, 28), (62, 40, 28)]

# NPCModelItemSlotDisplayInfo.ItemSlot -> how its ItemDisplayInfo geoset groups become submeshes
SLOT_GEOSETS = {
    2: [(0, 800)], 3: [(0, 800), (2, 1300)],          # shirt, chest: sleeves, robe skirt
    5: [(1, 900), (2, 1300)],                         # legs: kneepads, kilt
    6: [(0, 500)], 8: [(0, 400)], 9: [(0, 1200)], 10: [(0, 1500)],
}


def _baked(material_id):
    for r in _multi("TextureFileData", "MaterialResourcesID").get(material_id, []):
        return int(r["FileDataID"])
    return 0


def character_mesh(display_id):
    cdi = table("CreatureDisplayInfo")
    d = cdi.get(display_id)
    if not d:
        return None
    extra = int(d["ExtendedDisplayInfoID"] or 0)
    model = table("CreatureModelData").get(int(d["ModelID"]))
    if not model:
        return None
    fid = int(model["FileDataID"])
    if not extra:
        var = tuple(int(d["TextureVariationFileDataID_%d" % i]) for i in range(3))
        mesh = RD.m2_mesh(fid, var)
        if mesh:
            mesh = dict(mesh, scale=float(d["CreatureModelScale"] or 1))
            mesh["verts"] = mesh["verts"] * mesh["scale"]
        return mesh
    x = table("CreatureDisplayInfoExtra").get(extra)
    if not x:
        return None
    race, sex = int(x["DisplayRaceID"]), int(x["DisplaySexID"])
    want = {0}
    # hair
    for r in table("CharHairGeosets", None):
        if int(r["RaceID"]) == race and int(r["SexID"]) == sex and int(r["VariationID"]) == int(x["HairStyleID"]) \
                and int(r["GeosetType"]) == 0:
            want.add(int(r["GeosetID"]))
            break
    else:
        want.add(1)
    # beard / whiskers
    fh = [r for r in table("CharacterFacialHairStyles", None)
          if int(r["RaceID"]) == race and int(r["SexID"]) == sex and int(r["VariationID"]) == int(x["FacialHairID"])]
    g = [int(fh[0]["Geoset_%d" % i]) for i in range(3)] if fh else [1, 1, 1]
    want |= {100 + max(1, g[0]), 300 + max(1, g[1]), 200 + max(1, g[2])}
    groups = {4: 401, 5: 501, 7: 702, 13: 1301}
    for r in _multi("NPCModelItemSlotDisplayInfo", "NpcModelID").get(extra, []):
        item = table("ItemDisplayInfo").get(int(r["ItemDisplayInfoID"]))
        if not item:
            continue
        for gi, base in SLOT_GEOSETS.get(int(r["ItemSlot"]), []):
            v = int(item["GeosetGroup_%d" % gi] or 0)
            if v:
                groups[base // 100] = base + 1 + v
    want |= set(groups.values())
    baked = _baked(int(x["BakeMaterialResourcesID"]))
    hair = HAIR[int(x["HairColorID"]) % len(HAIR)]
    mesh = RD.m2_mesh(fid, geoset_ok=lambda sid: sid in want)
    if not mesh:
        return None
    tris, colors = [], {}
    for t in mesh["tris"]:
        tf = t[3]
        if isinstance(tf, tuple):          # ("type", n): 1 body -> the baked skin, 6 hair -> its colour
            kind = tf[1]
            if kind == 1:
                tf = baked
            elif kind == 6:
                tf = -6
                colors[-6] = tuple(c / 255 for c in hair)
            else:
                continue
        tris.append((t[0], t[1], t[2], tf))
    return dict(mesh, tris=tris, colors=colors, scale=1.0)


def fit(img, origin, size=SIZE):
    """A rendered sprite into a size x size cell, standing on its bottom row, centred on its origin."""
    img, origin = RD.trim(img, origin)
    h, w = img.shape[:2]
    out = np.zeros((size, size, 4), np.uint8)
    x0 = int(round(size / 2 - origin[0]))
    y0 = size - h
    for yy in range(h):
        ty = y0 + yy
        if 0 <= ty < size:
            for xx in range(w):
                tx = x0 + xx
                if 0 <= tx < size and img[yy, xx, 3]:
                    out[ty, tx] = img[yy, xx]
    return out


# one scale for every body: a human (~2 yd) fills the cell's height, a rabbit is a rabbit; only what would not
# fit (a bear, a big boar) is shrunk to the cell
PPY_BODY = 15.0


def frames(display_id, height_px=30):
    mesh = character_mesh(display_id)
    if not mesh or not mesh["tris"]:
        return None
    vs = mesh["verts"][np.unique(np.array([t[:3] for t in mesh["tris"]]))]
    height = max(0.3, float(vs[:, 2].max() - min(0.0, vs[:, 2].min())))
    length = float(max(vs[:, 0].max() - vs[:, 0].min(), vs[:, 1].max() - vs[:, 1].min()))
    ppy = min(PPY_BODY, height_px / height, (SIZE - 2) / max(length, 0.3))
    # the walk: two strides from the model's own Walk sequence (a quarter and three quarters through it, the legs
    # opposite), the standing pose between them; no Walk: the standing pose three times (the sheet bobs it)
    poses = [mesh, mesh, mesh]
    walked = False
    try:
        data = C.read_fid(mesh["fid"])
        seq, dur = RD.find_sequence(data, 4)
        if seq is not None and dur:
            poses = []
            for t in (dur // 4, None, 3 * dur // 4):
                if t is None:
                    poses.append(mesh)
                else:
                    poses.append(dict(mesh, verts=RD.posed_vertices(data, seq, t) * mesh.get("scale", 1.0)))
            walked = True
    except Exception:
        poses = [mesh, mesh, mesh]
    out = {"walked": walked}
    for face, yaw in FACING.items():
        imgs = []
        for pm in poses:
            img, origin = RD.render(pm, yaw, ELEV, ppy, oversample=4, ambient=0.72, diffuse=0.42)
            if img is None:
                return None
            imgs.append(fit(img, origin))
        out[face] = imgs
    return out


def player_display(race, sex):
    """A display for the player's own race and sex: a class trainer of that race (dressed like an adventurer)."""
    import tbcdb
    db = tbcdb.load()
    cdi = table("CreatureDisplayInfo")
    cdie = table("CreatureDisplayInfoExtra")
    for t in db.rows("creature_template"):
        if not (t["SubName"] or "").endswith("Trainer") or not t["TrainerClass"]:
            continue
        d = cdi.get(t["DisplayId1"])
        if not d or not int(d["ExtendedDisplayInfoID"] or 0):
            continue
        x = cdie.get(int(d["ExtendedDisplayInfoID"]))
        if x and int(x["DisplayRaceID"]) == race and int(x["DisplaySexID"]) == sex and _baked(int(x["BakeMaterialResourcesID"])):
            return t["DisplayId1"]
    return None

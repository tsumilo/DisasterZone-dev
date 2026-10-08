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


# ---------------------------------------------------------------------------------------------------------------
# Action frames (Disastercraft): a second sheet, mobs_act.blp, with the same cells as mobs.blp, holding each body's
# melee wind-up and strike, its spell ready and release, and its corpse, from the model's own sequences
# (AnimationData: 16 AttackUnarmed, 17 Attack1H, 18 Attack2H, 51/52 ReadySpellDirected/Omni, 31 SpellPrecast,
# 53/54 SpellCastDirected/Omni, 32 SpellCast, 6 Dead, 1 Death). A missing sequence keeps the standing pose.
# ---------------------------------------------------------------------------------------------------------------
ACT_COLS = 5                        # wind-up, strike, spell ready, spell release, dead
ATTACK_IDS = (16, 17, 18)
ATTACK_2H_IDS = (18, 17, 16)
READY_IDS = (51, 52, 31)
CAST_IDS = (53, 54, 32)


def _first_seq(data, ids):
    for a in ids:
        s, d = RD.find_sequence(data, a)
        if s is not None:
            return s, d
    return None, 0


def _act_times(data, ids, reach):
    """[(seq, t)] for the five action columns. reach(seq, t) -> how far forward (+x, the way a model faces) the
    pose reaches: the strike is the attack's furthest reach, the wind-up its shortest before that."""
    stand, _ = RD.find_sequence(data, 0)
    out = []
    seq, dur = _first_seq(data, ids)
    if seq is not None and dur:
        ts = [int(dur * k / 12) for k in range(12)]
        rs = [reach(seq, t) for t in ts]
        k = max(range(len(ts)), key=lambda i: rs[i])
        w = min(range(k + 1), key=lambda i: rs[i]) if k > 0 else 0
        if w == k:
            w = max(0, k - 3)
        out += [(seq, ts[w]), (seq, ts[k])]
    else:
        out += [(stand, 0), (stand, 0)]
    seq, dur = _first_seq(data, READY_IDS)
    out.append((seq, dur // 2) if seq is not None else (stand, 0))
    seq, dur = _first_seq(data, CAST_IDS)
    out.append((seq, int(dur * 0.4)) if seq is not None else (stand, 0))
    seq, dur = RD.find_sequence(data, 6)
    if seq is not None:
        out.append((seq, 0))
    else:
        seq, dur = RD.find_sequence(data, 1)
        out.append((seq, max(0, dur - 1)) if seq is not None else (stand, 0))
    return out


def act_frames(display_id, height_px=30):
    """The five action frames x 4 facings for a creature / NPC display (scaled like frames())."""
    mesh = character_mesh(display_id)
    if not mesh or not mesh["tris"]:
        return None
    vs = mesh["verts"][np.unique(np.array([t[:3] for t in mesh["tris"]]))]
    height = max(0.3, float(vs[:, 2].max() - min(0.0, vs[:, 2].min())))
    length = float(max(vs[:, 0].max() - vs[:, 0].min(), vs[:, 1].max() - vs[:, 1].min()))
    ppy = min(PPY_BODY, height_px / height, (SIZE - 2) / max(length, 0.3))
    data = C.read_fid(mesh["fid"])
    sc = mesh.get("scale", 1.0)
    used = np.unique(np.array([t[:3] for t in mesh["tris"]]))

    def pose(seq, t):
        if seq is None:
            return mesh
        return dict(mesh, verts=RD.posed_vertices(data, seq, t) * sc)

    times = _act_times(data, ATTACK_IDS, lambda s, t: float(pose(s, t)["verts"][used][:, 0].max()))
    poses = [pose(s, t) for s, t in times]
    out = {}
    for face, yaw in FACING.items():
        imgs = []
        for pm in poses:
            img, origin = RD.render(pm, yaw, ELEV, ppy, oversample=4, ambient=0.72, diffuse=0.42)
            imgs.append(fit(img, origin) if img is not None else np.zeros((SIZE, SIZE, 4), np.uint8))
        out[face] = imgs
    return out


def outfit_act_frames(race, sex, items, height_px=30):
    """act_frames() for a character in an outfit, weapons in hand (a two-hander swings with Attack2H)."""
    import tbcdb
    got = outfit(race, sex, items)
    if not got:
        return None
    body, weapons, data = got
    it = tbcdb.load().index("item_template", "entry")
    two = any(it.get(e) and it[e]["InventoryType"] == 17 for e in items)
    stand_seq, _ = RD.find_sequence(data, 0)

    def pose(seq, t):
        if seq is None:
            seq, t = stand_seq, 0
        return _dress(body, weapons, data, RD.bone_mats(data, seq, t), RD.posed_vertices(data, seq, t))

    vs = pose(stand_seq, 0)["verts"]
    height = max(0.3, float(vs[:, 2].max() - min(0.0, vs[:, 2].min())))
    ppy = min(PPY_BODY, height_px / height)
    times = _act_times(data, ATTACK_2H_IDS if two else ATTACK_IDS, lambda s, t: float(pose(s, t)["verts"][:, 0].max()))
    poses = [pose(s, t) for s, t in times]
    out = {}
    for face, yaw in FACING.items():
        imgs = []
        for pm in poses:
            img, origin = RD.render(pm, yaw, ELEV, ppy, oversample=4, ambient=0.72, diffuse=0.42)
            imgs.append(fit(img, origin) if img is not None else np.zeros((SIZE, SIZE, 4), np.uint8))
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


# ---------------------------------------------------------------------------------------------------------------
# A player character in an outfit (CharStartOutfit item IDs): the race's model, its bare skin with each item's
# texture pieces painted into their body sections (CharComponentTextureSections, the classic 256 x 256 layout),
# the pieces the items add (sleeves, robe, boots...) and the weapon / shield models on the hand / shield
# attachment points, posed with the body in every frame.
# ---------------------------------------------------------------------------------------------------------------
from PIL import Image  # noqa: E402
import io  # noqa: E402

RACE_FILE = {1: "human", 2: "orc", 3: "dwarf", 4: "nightelf", 5: "scourge", 6: "tauren", 7: "gnome", 8: "troll",
             10: "bloodelf", 11: "draenei"}
# section type -> (x, y, w, h) on the 256 x 256 skin
SECTIONS = {0: (0, 0, 128, 64), 1: (0, 64, 128, 64), 2: (0, 128, 128, 32), 3: (128, 0, 128, 64),
            4: (128, 64, 128, 32), 5: (128, 96, 128, 64), 6: (128, 160, 128, 64), 7: (128, 224, 128, 32),
            9: (0, 160, 128, 32), 10: (0, 192, 128, 64)}
INV_GEOSETS = {4: [(0, 800)], 5: [(0, 800), (2, 1300)], 20: [(0, 800), (2, 1300)],     # shirt, chest, robe
               7: [(1, 900), (2, 1300)], 8: [(0, 500)], 10: [(0, 400)], 19: [(0, 1200)], 16: [(0, 1500)]}
HAND_SLOTS = {13: 1, 17: 1, 21: 1, 15: 1, 26: 1, 14: 0, 22: 2, 23: 2}     # inventory type -> attachment


def _blp(fid):
    """A BLP as RGBA. One stored without alpha (alpha depth 0, header byte 9) is opaque - Pillow hands those out
    with alpha 0, which made pasted clothes vanish."""
    return RD.open_blp(C.read_fid(fid))


def _item_tex(material_id, sex):
    """An item texture piece: of a male / female pair the higher file ID is the male one."""
    rows = sorted(_multi("TextureFileData", "MaterialResourcesID").get(material_id, []), key=lambda r: int(r["FileDataID"]))
    if not rows:
        return 0
    if len(rows) == 1:
        return int(rows[0]["FileDataID"])
    return int(rows[-1 if sex == 0 else 0]["FileDataID"])


def outfit(race, sex, items):
    """-> (body mesh with the composed skin, [(weapon mesh, attachment id)], model data) or None."""
    import tbcdb
    rf = RACE_FILE[race]
    sx = "male" if sex == 0 else "female"
    model_fid = C.fdid_of("character/%s/%s/%s%s.m2" % (rf, sx, rf, sx))
    skin = _blp(C.fdid_of("character/%s/%s/%s%sskin00_00.blp" % (rf, sx, rf, sx))).resize((256, 256))
    for name, sec in (("facelower00_00", 10), ("faceupper00_00", 9), ("nakedpelvisskin00_00", 5),
                      ("nakedtorsoskin00_00", 3)):
        fid = C.fdid_of("character/%s/%s/%s%s%s.blp" % (rf, sx, rf, sx, name))
        if fid:
            x, y, w, h = SECTIONS[sec]
            piece = _blp(fid).resize((w, h))
            skin.alpha_composite(piece, (x, y))
    db = tbcdb.load()
    it = db.index("item_template", "entry")
    idi = table("ItemDisplayInfo")
    mats = _multi("ItemDisplayInfoMaterialRes", "ItemDisplayInfoID")
    want = {0, 101, 201, 301, 401, 501, 702, 1301}
    hair = [r for r in table("CharHairGeosets", None) if int(r["RaceID"]) == race and int(r["SexID"]) == sex
            and int(r["GeosetType"]) == 0 and int(r["GeosetID"]) > 0]
    want.add(int(hair[min(4, len(hair) - 1)]["GeosetID"]) if hair else 1)
    groups = {}
    weapons = []
    # items in the order the client paints them: what lies on top last (pants, boots, shirt, robe)
    order = {4: 1, 7: 2, 8: 3, 5: 4, 20: 5, 19: 6}
    for e in sorted(items, key=lambda e: order.get(it[e]["InventoryType"], 0) if e in it else 0):
        t = it.get(e)
        if not t:
            continue
        inv, d = t["InventoryType"], idi.get(t["displayid"])
        if not d:
            continue
        for r in mats.get(t["displayid"], []):
            sec = int(r["ComponentSection"])
            fid = _item_tex(int(r["MaterialResourcesID"]), sex)
            if sec in SECTIONS and fid:
                x, y, w, h = SECTIONS[sec]
                skin.alpha_composite(_blp(fid).resize((w, h)), (x, y))
        for gi, base in INV_GEOSETS.get(inv, []):
            v = int(d["GeosetGroup_%d" % gi] or 0)
            if v:
                groups[base // 100] = base + 1 + v
        if inv in HAND_SLOTS and int(d["ModelResourcesID_0"] or 0):
            mfd = _multi("ModelFileData", "ModelResourcesID").get(int(d["ModelResourcesID_0"]), [])
            tex = _item_tex(int(d["ModelMaterialResourcesID_0"] or 0), sex)
            if mfd:
                wm = RD.m2_mesh(int(mfd[0]["FileDataID"]))
                if wm:
                    tris = [(a, b, c, tex if isinstance(tf, tuple) else tf) for a, b, c, tf in wm["tris"]]
                    weapons.append((dict(wm, tris=tris), HAND_SLOTS[inv]))
    for g, v in groups.items():
        want.discard(g * 100 + 1)
        want.add(v)
    if 13 in groups and groups[13] > 1301:
        want.discard(1301)
    key = ("skin", race, sex, tuple(sorted(items)))
    RD.register_texture(key, np.asarray(skin, np.float32) / 255.0)
    body = RD.m2_mesh(model_fid, geoset_ok=lambda sid: sid in want)
    hair_fid = C.fdid_of("character/%s/hair00_00.blp" % rf)
    tris = []
    for a, b, c, tf in body["tris"]:
        if isinstance(tf, tuple):
            if tf[1] == 1:
                tf = key
            elif tf[1] == 6:
                tf = hair_fid or 0
            else:
                continue
        tris.append((a, b, c, tf))
    return dict(body, tris=tris, scale=1.0), weapons, C.read_fid(model_fid)


def _dress(body, weapons, data, mats, body_verts):
    """The body with its weapons on their attachment points for these bone matrices."""
    verts, uvs, tris = [body_verts], [body["uvs"]], list(body["tris"])
    n = len(body_verts)
    for wm, att in weapons:
        a = RD.attachment(data, att)
        if not a or a[0] >= len(mats):
            continue
        bone, pos = a
        v = RD.apply_mat(mats[bone], wm["verts"] + np.array(pos, np.float32))
        verts.append(v)
        uvs.append(wm["uvs"])
        tris += [(x + n, y + n, z + n, tf) for x, y, z, tf in wm["tris"]]
        n += len(v)
    return dict(body, verts=np.concatenate(verts), uvs=np.concatenate(uvs), tris=tris)


def outfit_frames(race, sex, items, height_px=30):
    """frames() for a character in an outfit: stride / stand / stride x 4 facings, weapons in hand."""
    got = outfit(race, sex, items)
    if not got:
        return None
    body, weapons, data = got
    stand_seq, _ = RD.find_sequence(data, 0)
    walk_seq, dur = RD.find_sequence(data, 4)
    poses = []
    for seq, t in ((walk_seq, dur // 4), (stand_seq, 0), (walk_seq, 3 * dur // 4)):
        if seq is None:
            seq, t = stand_seq, 0
        mats = RD.bone_mats(data, seq, t)
        poses.append(_dress(body, weapons, data, mats, RD.posed_vertices(data, seq, t)))
    vs = poses[1]["verts"]
    height = max(0.3, float(vs[:, 2].max() - min(0.0, vs[:, 2].min())))
    ppy = min(PPY_BODY, height_px / height)
    out = {"walked": walk_seq is not None}
    for face, yaw in FACING.items():
        imgs = []
        for pm in poses:
            img, origin = RD.render(pm, yaw, ELEV, ppy, oversample=4, ambient=0.72, diffuse=0.42)
            imgs.append(fit(img, origin))
        out[face] = imgs
    return out

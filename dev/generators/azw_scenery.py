"""Azeromon world: every placed doodad (tree, bush, fence, barrel...) and building (WMO) of a region, rendered from
its own model (azw_render) at its real spot and turn, packed into sprite pages (Media/Azeromon/Scenery/<region>_<n>
.blp, palettised with alpha), plus where each one stands.

Scale: 16 px a tile = 3.84 px a yard, the ground's own scale. Small props (under SMALL yards) are drawn PROP_SCALE
times bigger, the way Pokemon draws people and items larger than its houses, so a barrel next to a person reads.
Elevation: seen from the south at ELEV degrees (buildings show their roofs and fronts, trees their crowns).

build(world, gbox) -> { sprites: [...], placements: [...], pages: n }"""
import math
import os
import struct

import numpy as np
from PIL import Image

import adt_tools as A
import azw_classify as K
import azw_raw as R
import azw_render as RD

PXT = 32                     # sprite pixels a tile (the screen shows 48)
OCC_MIN_HEIGHT = 0.35        # a storey cut away: what stands lower than this over its floor lies flat
OCC_COL = 64                 # depth slices: columns this wide
WMO_BANDS = 2                # outdoor buildings: depth bands a tile
PPY = PXT / A.TS             # pixels a yard on the map
ELEV = None                  # oblique (azw_render): footprints line up with the collision tiles
TREE_ELEV = None               # crowns from higher up: their leaf cards smear when seen from the side
SMALL = 3.0
PROP_SCALE = 1.6
YAW_STEPS = 16               # turns are rounded to this many steps (sprites shared between placements)
ORGANIC = ("tree", "deco", "rock", "stump", "log")


def write_blp_palette(img, path):
    """BLP2, uncompressed palettised (256 colours) with an 8-bit alpha plane, no mipmaps - what WoW loads for
    sprites with soft edges. img: RGBA PIL image (power-of-two sides)."""
    w, h = img.size
    rgb = img.convert("RGB")
    alpha = np.asarray(img.getchannel("A"), np.uint8)
    q = rgb.quantize(256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    pal = q.getpalette()[:768] + [0] * (768 - len(q.getpalette()[:768]))
    idx = np.asarray(q, np.uint8)
    header = b"BLP2" + struct.pack("<I", 1) + struct.pack("<BBBB", 1, 8, 0, 0) + struct.pack("<II", w, h)
    off = len(header) + 16 * 4 * 2 + 256 * 4
    data = idx.tobytes() + alpha.tobytes()
    offsets = [off] + [0] * 15
    sizes = [len(data)] + [0] * 15
    palette = b"".join(struct.pack("<BBBB", pal[i * 3 + 2], pal[i * 3 + 1], pal[i * 3], 0) for i in range(256))
    with open(path, "wb") as f:
        f.write(header)
        f.write(struct.pack("<16I", *offsets))
        f.write(struct.pack("<16I", *sizes))
        f.write(palette)
        f.write(data)


def _scaled(mesh, s):
    if s == 1:
        return mesh
    out = dict(mesh)
    out["verts"] = mesh["verts"] * s
    return out


def pack(sprites, page=1024):
    """Shelf packing; sets sprite["page"], ["u"], ["v"]. -> page count"""
    order = sorted(range(len(sprites)), key=lambda i: -sprites[i]["img"].shape[0])
    pages, x, y, shelf = 0, 0, 0, 0
    pages = 1
    for i in order:
        h, w = sprites[i]["img"].shape[:2]
        if w > page or h > page:
            raise ValueError("sprite too big for a page: %dx%d" % (w, h))
        if x + w > page:
            x, y, shelf = 0, y + shelf + 1, 0
        if y + h > page:
            pages += 1
            x, y, shelf = 0, 0, 0
        sprites[i]["page"], sprites[i]["u"], sprites[i]["v"] = pages - 1, x, y
        x += w + 1
        shelf = max(shelf, h)
    return pages


def build(world, gbox, out_base, objects=None, buildings=None):
    """objects: {key: (model FileDataID, scale)} - game objects (herbs, ore, quest crates) drawn from their own
    models; their sprites come back as result["objects"][key] = sprite index. buildings: {uid: azw_building grid}
    - those WMOs' pieces are tagged "bld" (hidden while you are inside) and each storey's cut-away picture is added
    (placements with "bld" and "st")."""
    r = world["r"]
    gx0, gx1, gy0, gy1 = gbox
    sprites, keys, placements = [], {}, []

    def sprite_for(key, make):
        if key in keys:
            return keys[key]
        img, origin = make()
        if img is None:
            keys[key] = None
            return None
        img, origin = RD.trim(img, origin)
        # bigger than a page (a long wall): cut into pieces that share the spot
        idx = []
        h, w = img.shape[:2]
        for y0 in range(0, h, 1000):
            for x0 in range(0, w, 1000):
                piece = img[y0:y0 + 1000, x0:x0 + 1000]
                if not piece[..., 3].any():
                    continue
                sprites.append({"img": piece, "ox": origin[0] - x0, "oy": origin[1] - y0, "key": key})
                idx.append(len(sprites) - 1)
        keys[key] = idx
        return idx

    # doodads
    for fid, p, rot, sc, uid in r["doodads"]:
        gx, gy = p[0] / A.TS, p[2] / A.TS
        if not (gx0 <= gx < gx1 and gy0 <= gy < gy1):
            continue
        name = R.m2_name(fid)
        kind, _tile = K.doodad_kind(name)
        if kind in (None, "skip"):
            continue
        try:
            mesh = RD.m2_mesh(fid)
        except Exception:
            mesh = None
        if not mesh or not mesh["tris"]:
            continue
        ext = mesh["verts"].max(0) - mesh["verts"].min(0)
        boost = PROP_SCALE if max(ext[0], ext[1], ext[2]) * sc < SMALL else 1.0
        step = round(((rot[1] - 180) % 360) / (360 / YAW_STEPS)) % YAW_STEPS
        if kind in ORGANIC:
            # trees, bushes, rocks look alike turned: one picture per model, drawn at each placement's size
            step, s, k = 0, boost, sc
        else:
            s, k = round(sc * boost, 1), 1.0
        key = ("m2", fid, step, s)
        yaw = math.radians(step * 360 / YAW_STEPS)
        el = TREE_ELEV if kind == "tree" else ELEV
        ids = sprite_for(key, lambda: RD.render(_scaled(mesh, s), yaw, el, PPY))
        for i in ids or ():
            placements.append({"s": i, "x": gx, "y": gy, "sort": gy, "kind": kind, "k": round(k, 2)})
    # buildings, walls, bridges (WMOs): cut into depth slices by the ground row under each pixel (WMO_BANDS a
    # tile), so a tree or a body behind one wing and in front of another sorts against the part it is really
    # behind; their flat ground-level parts (steps, porches, decks) lie under everything
    # (a building walked in place, azw_building: each storey also cut away over head height - clip - with its
    # furniture; there everything at or under the storey's floor lies flat, and a cave lies flat wherever its
    # faces look up - its tunnels slope)
    def wmo_pieces(key, mesh, yaw, floor_z, clip=None, cave=False, drop=None):
        if key in keys:
            return keys[key]
        if cave:
            got = RD.render(mesh, yaw, ELEV, PPY, oversample=2, drop_down=True, aux_floor_z=floor_z,
                            aux_floor_tol=1e9, drop_tris=drop)
        else:
            got = RD.render(mesh, yaw, ELEV, PPY, oversample=2, clip_z=clip, aux_floor_z=floor_z)
        if got[0] is None:
            keys[key] = None
            return None
        img, origin, aux = got
        ys, xs = np.nonzero(img[..., 3])
        if len(xs) == 0:
            keys[key] = None
            return None
        cx0, cx1, cy0, cy1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
        img = img[cy0:cy1, cx0:cx1]
        north, isfloor = aux["north"][cy0:cy1, cx0:cx1], aux["floor"][cy0:cy1, cx0:cx1]
        if clip is not None and not cave:
            isfloor = isfloor | (aux["height"][cy0:cy1, cx0:cx1] < OCC_MIN_HEIGHT)
        origin = (origin[0] - cx0, origin[1] - cy0)
        h, wd = img.shape[:2]
        opaque = img[..., 3] > 0
        out = []

        def add(piece, x0, y0, rel):
            sprites.append({"img": piece, "ox": origin[0] - x0, "oy": origin[1] - y0, "key": key})
            out.append((len(sprites) - 1, rel))

        flat = opaque & isfloor
        if flat.any():
            fl = img.copy()
            fl[~flat] = 0
            for y0 in range(0, h, 1000):
                for x0 in range(0, wd, 1000):
                    piece = fl[y0:y0 + 1000, x0:x0 + 1000]
                    if piece[..., 3].any():
                        add(piece, x0, y0, None)
        rest = opaque & ~isfloor
        # (bands counted from the model's origin, north positive: a band's sort is the placement's row minus it)
        band = np.floor(north / A.TS * WMO_BANDS).astype(np.int64)
        for b in np.unique(band[rest]):
            sel = rest & (band == b)
            for x0 in range(0, wd, OCC_COL):
                m = sel[:, x0:x0 + OCC_COL]
                if not m.any():
                    continue
                ys_, xs_ = np.nonzero(m)
                # (a pixel of overlap into the building next to it, so neighbouring slices leave no seam)
                py0, py1 = max(0, ys_.min() - 1), min(h, ys_.max() + 2)
                px0, px1 = max(0, x0 + xs_.min() - 1), min(wd, x0 + xs_.max() + 2)
                mm = sel[py0:py1, px0:px1].copy()
                if px0 < x0:
                    mm[:, :x0 - px0] = False
                if px1 > x0 + OCC_COL:
                    mm[:, x0 + OCC_COL - px0:] = False
                g = mm.copy()
                g[1:, :] |= mm[:-1, :]
                g[:-1, :] |= mm[1:, :]
                g[:, 1:] |= mm[:, :-1]
                g[:, :-1] |= mm[:, 1:]
                g &= opaque[py0:py1, px0:px1]
                piece = img[py0:py1, px0:px1].copy()
                piece[~g] = 0
                rel = (b + 0.5) / WMO_BANDS * A.TS          # yards north of the origin
                while piece.shape[0] > 1000:
                    add(piece[:1000], px0, py0, rel)
                    piece, py0 = piece[1000:], py0 + 1000
                add(piece, px0, py0, rel)
        keys[key] = out
        return out

    for w in r["wmos"]:
        fid, pos, rot = w[0], w[1], w[2]
        gx, gy = pos[0] / A.TS, pos[2] / A.TS
        cave = world.get("wmo_kinds", {}).get(fid) == "cave"
        mesh = RD.wmo_mesh(fid, outdoor_only=cave)       # (a mine: only its entrance is above ground)
        ext_ok = len(mesh["verts"]) > 0
        if not ext_ok:
            continue
        # does it reach the region at all
        bb = w[3]
        if bb[3] / A.TS < gx0 or bb[0] / A.TS > gx1 or bb[5] / A.TS < gy0 or bb[2] / A.TS > gy1:
            continue
        if max(bb[3] - bb[0], bb[5] - bb[2]) > 400:
            continue                     # a whole city (Stormwind): drawn in pieces with its own step
        yaw = math.radians(rot[1] - 180)
        # the ground under its origin, in the model's frame (what counts as its flat ground-level parts)
        lx, ly = int(gx) - r["gx0"], int(gy) - r["gy0"]
        ground = float(r["z"][ly, lx]) if 0 <= lx < r["W"] and 0 <= ly < r["H"] else pos[1]
        key = ("wmo", fid, round(rot[1], 1), round(ground - pos[1], 1))
        bl = (buildings or {}).get(w[7])
        for i, rel in wmo_pieces(key, mesh, yaw, ground - pos[1]) or ():
            pl = {"s": i, "x": gx, "y": gy, "kind": "wmo", "uid": w[7]}
            if bl:
                pl["bld"] = w[7]                         # (hidden while you are inside it)
            if rel is None:
                pl["sort"] = -1e6                        # (flat on the ground: under everyone)
            else:
                pl["sort"] = gy - rel / A.TS
                pl["wall"] = True
            placements.append(pl)
        # a building walked in place: each storey cut away over head height, its furniture in
        if bl:
            full = wmo_with_doodads(fid)
            drop = _over_tunnels(full, w, bl) if bl["cave"] else None
            for k, st in enumerate(bl["storeys"]):
                skey = ("cut", w[7], k)
                for i, rel in wmo_pieces(skey, full, yaw, st["f"], clip=st["clip"], cave=bl["cave"], drop=drop) or ():
                    pl = {"s": i, "x": gx, "y": gy, "kind": "cut", "bld": w[7], "st": k}
                    if rel is None:
                        pl["sort"] = -1e6
                    else:
                        pl["sort"] = gy - rel / A.TS
                        pl["wall"] = True
                    placements.append(pl)
    # game objects: one sprite per model and size, standing on its origin like a doodad
    obj_sprites = {}
    for okey, (ofid, osc) in sorted((objects or {}).items(), key=lambda kv: str(kv[0])):
        try:
            mesh = RD.m2_mesh(ofid)
        except Exception:
            mesh = None
        if not mesh or not mesh["tris"]:
            continue
        ext = mesh["verts"].max(0) - mesh["verts"].min(0)
        boost = PROP_SCALE if max(ext[0], ext[1], ext[2]) * osc < SMALL else 1.0
        s = round(osc * boost, 2)
        ids = sprite_for(("go", ofid, s), lambda: RD.render(_scaled(mesh, s), 0.0, ELEV, PPY))
        if ids:
            obj_sprites[okey] = ids[0]
    pages = pack(sprites)
    os.makedirs(os.path.dirname(out_base), exist_ok=True)
    for pg in range(pages):
        canvas = np.zeros((1024, 1024, 4), np.uint8)
        for sp in sprites:
            if sp["page"] == pg:
                h, w_ = sp["img"].shape[:2]
                canvas[sp["v"]:sp["v"] + h, sp["u"]:sp["u"] + w_] = sp["img"]
        from azw_blp import write_dxt5
        write_dxt5(Image.fromarray(canvas, "RGBA"), "%s_%d.blp" % (out_base, pg))
    return {"sprites": sprites, "placements": placements, "pages": pages, "objects": obj_sprites}


# ---------------------------------------------------------------------------------------------------------------
# A building's whole model with its furniture (its storeys are drawn cut away: see wmo_pieces)
# ---------------------------------------------------------------------------------------------------------------

def _quat_rot(q, v):
    """Rotate vectors v (N, 3) by quaternion q (x, y, z, w)."""
    x, y, z, w = q
    m = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                  [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                  [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]], np.float32)
    return v @ m.T


def _over_tunnels(mesh, w, bl):
    """A mine's tunnels slope, so no one height cuts it away: the triangles (its own and its furniture's) standing
    more than a head over the floor of the tunnel under them - a shed's roof, a beam - go, by the walk grid."""
    import azw_building as BL
    import azw_wmo as WM
    f = WM.transform(w)
    oz = w[1][1]
    low = {}
    for c, lay in bl["cells"].items():
        hs = [l_["h"] for l_ in lay]
        if hs:
            low[c] = min(hs)
    verts = mesh["verts"]
    drop = set()
    for ti, t in enumerate(mesh["tris"]):
        p = [f(verts[i]) for i in t[:3]]
        cx = int(math.floor(sum(q[0] for q in p) / 3 * BL.SUB))
        cy = int(math.floor(sum(q[1] for q in p) / 3 * BL.SUB))
        floor_h = None
        for r in (0, 1, 2):
            near = [low[(cx + dx, cy + dy)] for dx in range(-r, r + 1) for dy in range(-r, r + 1)
                    if (cx + dx, cy + dy) in low]
            if near:
                floor_h = min(near)
                break
        if floor_h is not None and min(q[2] for q in p) - oz > floor_h + BL.HEAD_CLIP:
            drop.add(ti)
    return drop


def wmo_with_doodads(fid):
    """The WMO's mesh plus its default doodad set (furniture, candles, books...) in its own frame."""
    import azw_wmo as WM
    mesh = RD.wmo_mesh(fid)
    o = WM.load(fid)
    verts, uvs, tris = [mesh["verts"]], [mesh["uvs"]], list(mesh["tris"])
    n = len(mesh["verts"])
    fids = o.get("doodad_fids") or []
    sets = o["sets"] or [("", 0, len(o["doodads"]))]
    _nm, start, count = sets[0]
    for d in o["doodads"][start:start + count]:
        dfid = fids[d["name"]] if d["name"] < len(fids) else 0
        if not dfid:
            continue
        name = (R.m2_name(dfid) or "").lower()
        if K.doodad_kind(name)[0] == "skip" and not any(w in name for w in ("candle", "book", "bottle", "jar", "jug",
                                                                            "plate", "bowl", "chair", "bench")):
            continue
        try:
            m = RD.m2_mesh(dfid)
        except Exception:
            m = None
        if not m or not m["tris"]:
            continue
        v = _quat_rot(d["rot"], m["verts"] * d["scale"]) + np.array(d["pos"], np.float32)
        verts.append(v.astype(np.float32))
        uvs.append(m["uvs"])
        tris += [(a + n, b + n, c + n, tf) for a, b, c, tf in m["tris"]]
        n += len(v)
    return {"verts": np.concatenate(verts), "uvs": np.concatenate(uvs), "tris": tris}

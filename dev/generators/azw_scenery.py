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
BANDS = 4                    # interiors: depth bands a grid cell (walls drawn in front of / behind people)
OCC_ROWS = 2                 # ... a wall is cut into bands only with floor this many rows north of it
OCC_MIN_HEIGHT = 0.35        # ... and only where it stands this many yards over the floor
OCC_COL = 64                 # ... in columns this wide
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


def build(world, gbox, out_base):
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
    # buildings, walls, bridges (WMOs)
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
        key = ("wmo", fid, round(rot[1], 1))
        ids = sprite_for(key, lambda: RD.render(mesh, yaw, ELEV, PPY, oversample=2))
        # drawn behind whoever stands south of its northern half: sort by the middle of its footprint
        for i in ids or ():
            placements.append({"s": i, "x": gx, "y": gy, "sort": (bb[2] + bb[5]) / 2 / A.TS, "kind": "wmo",
                               "uid": w[7]})
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
    return {"sprites": sprites, "placements": placements, "pages": pages}


# ---------------------------------------------------------------------------------------------------------------
# Interiors: each floor of a building seen from above with everything over head height taken off
# ---------------------------------------------------------------------------------------------------------------

def _quat_rot(q, v):
    """Rotate vectors v (N, 3) by quaternion q (x, y, z, w)."""
    x, y, z, w = q
    m = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                  [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                  [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]], np.float32)
    return v @ m.T


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


def build_interiors(interiors, out_base, fine):
    """interiors: [{"uid", "levels": [{id, z, x0, y0...}], "w": placement}] -> sprites / placements by map id."""
    PPY_I = PXT / (A.TS / fine)
    sprites, by_map = [], {}
    for it in interiors:
        w = it["w"]
        fid, pos, rot = w[0], w[1], w[2]
        mesh = wmo_with_doodads(fid)
        yaw = math.radians(rot[1] - 180)
        for lvl in it["levels"]:
            floor_z = lvl["z"] - pos[1]                  # this floor's height in the WMO's frame
            clip = floor_z + 3.4                         # head height above this floor
            if it.get("cave"):                           # a mine: the rock overhead is what faces down
                got = RD.render(mesh, yaw, None, PPY_I, oversample=2, drop_down=True, aux_floor_z=floor_z)
            else:
                got = RD.render(mesh, yaw, None, PPY_I, oversample=2, clip_z=clip, aux_floor_z=floor_z)
            if got[0] is None:
                continue
            img, origin, aux = got
            # (trim, keeping the depth data in step)
            ys, xs = np.nonzero(img[..., 3])
            if len(xs) == 0:
                continue
            cx0, cx1, cy0, cy1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
            img = img[cy0:cy1, cx0:cx1]
            north, isfloor = aux["north"][cy0:cy1, cx0:cx1], aux["floor"][cy0:cy1, cx0:cx1]
            height = aux["height"][cy0:cy1, cx0:cx1]
            origin = (origin[0] - cx0, origin[1] - cy0)
            # where the WMO's origin falls on the interior's grid (fine cells from the level's corner)
            ox_t = pos[0] / A.TS * fine - lvl["x0"]
            oy_t = pos[2] / A.TS * fine - lvl["y0"]
            # The floor lies under everyone. What can stand in front of a body - a wall, railing, pillar or
            # piece of furniture taller than a step, with floor just north of it where someone could stand
            # (feet up to OCC_ROWS rows behind it, a cell to either side) - is cut into depth bands by the grid
            # row of the ground under each pixel (BANDS a cell), each drawn in the world's depth order at its own
            # row: a wall in front of you covers you, one behind you does not. The rest (back walls with nothing
            # walkable behind them, rugs, low steps) stays with the floor, which keeps the pages few.
            opaque = img[..., 3] > 0
            h, wd = img.shape[:2]
            gy = oy_t - north * fine / A.TS
            gx = ox_t + ((np.arange(wd) + 0.5 - origin[0]) / PPY_I * fine / A.TS)[None, :].repeat(h, 0)
            walk = np.array([[ch in "frL" for ch in r_] for r_ in lvl["rows"]], bool)
            gh, gw = walk.shape
            padded = np.zeros((gh + OCC_ROWS, gw + 2), bool)
            padded[OCC_ROWS:, 1:-1] = walk
            near = np.zeros((gh, gw), bool)
            for dy in range(OCC_ROWS + 1):
                for dx in (-1, 0, 1):
                    near |= padded[OCC_ROWS - dy:OCC_ROWS - dy + gh, 1 + dx:1 + dx + gw]
            cx, cy = np.floor(gx).astype(np.int64), np.floor(gy).astype(np.int64)
            inside = (cx >= 0) & (cx < gw) & (cy >= 0) & (cy < gh)
            occ_cell = np.zeros((h, wd), bool)
            occ_cell[inside] = near[cy[inside], cx[inside]]
            wall = opaque & ~isfloor & occ_cell & (height > OCC_MIN_HEIGHT)
            # (the floor layer keeps the whole picture: a slice's soft edge then shows the same pixels under it,
            # not the black behind a hole - a dark crack ran along every cut wall's foot)
            floor_img = img
            band = np.floor(gy * BANDS).astype(np.int64)

            def add(piece_img, x0, y0, sort=None):
                sprites.append({"img": piece_img, "ox": origin[0] - x0, "oy": origin[1] - y0})
                p = {"s": len(sprites) - 1, "x": ox_t, "y": oy_t}
                if sort is not None:
                    p["sort"] = sort
                by_map.setdefault(lvl["id"], []).append(p)

            # the floor in 1000-px pieces that overlap by SEAM px (filtering at a piece's edge read the empty
            # page around it: a dark line across the room)
            SEAM = 2
            for y0 in range(0, h, 1000):
                for x0 in range(0, wd, 1000):
                    ya, xa = max(0, y0 - SEAM), max(0, x0 - SEAM)
                    piece = floor_img[ya:y0 + 1000 + SEAM, xa:x0 + 1000 + SEAM]
                    if piece[..., 3].any():
                        add(piece, xa, ya)
            # the walls: each band cut into columns of OCC_COL px and trimmed; a band's pixels grow one pixel into
            # the walls next to it so neighbouring bands leave no crack
            for b in np.unique(band[wall]):
                sel = wall & (band == b)
                for x0 in range(0, wd, OCC_COL):
                    col = sel[:, x0:x0 + OCC_COL]
                    if not col.any():
                        continue
                    ys_, xs_ = np.nonzero(col)
                    py0, py1 = max(0, ys_.min() - 1), min(h, ys_.max() + 2)
                    px0, px1 = max(0, x0 + xs_.min() - 1), min(wd, x0 + xs_.max() + 2)
                    m = sel[py0:py1, px0:px1].copy()
                    if px0 < x0:
                        m[:, :x0 - px0] = False
                    if px1 > x0 + OCC_COL:
                        m[:, x0 + OCC_COL - px0:] = False
                    g = m.copy()
                    g[1:, :] |= m[:-1, :]
                    g[:-1, :] |= m[1:, :]
                    g[:, 1:] |= m[:, :-1]
                    g[:, :-1] |= m[:, 1:]
                    g &= wall[py0:py1, px0:px1]
                    piece = img[py0:py1, px0:px1].copy()
                    piece[~g] = 0
                    while piece.shape[0] > 1000:            # (a very tall column: in page-sized parts)
                        add(piece[:1000], px0, py0, (b + 0.5) / BANDS)
                        piece, py0 = piece[1000:], py0 + 1000
                    add(piece, px0, py0, (b + 0.5) / BANDS)
    pages = pack(sprites) if sprites else 0
    from azw_blp import write_dxt5
    for pg in range(pages):
        canvas = np.zeros((1024, 1024, 4), np.uint8)
        for sp in sprites:
            if sp["page"] == pg:
                h, w_ = sp["img"].shape[:2]
                canvas[sp["v"]:sp["v"] + h, sp["u"]:sp["u"] + w_] = sp["img"]
        write_dxt5(Image.fromarray(canvas, "RGBA"), "%s_%d.blp" % (out_base, pg))
    return {"sprites": sprites, "maps": by_map, "pages": pages}

"""Disastercraft: the hero's pixel sprite dressed in whatever it wears, like a WoW character.

The body is a bare human (male / female) drawn the way azw_people draws people; every item that shows on a
character (shirt, chest, robe, waist, legs, feet, wrists, hands, tabard, back, weapons, shields, off-hand items)
is a layer: the same body wearing only that item, minus the bare body - just the pixels the item changes. The
game stacks the body and the layers of the gear on, in the order the client paints a character (legs under boots,
chest over the shirt, belt over the chest, cape, then shield and weapon).

Every picture is drawn on one fixed canvas (tiny invisible pins at the corners of a box round the body), so the
body and every layer share the pixel grid, and each is placed in the 32 px cell by the bare body's own fit
(azw_people.fit: centred on the origin, feet on the bottom row) - the layers line up with the body exactly.

Frames: the walk (stride, stand, stride: mobs.blp's three columns) and the five action poses (melee wind-up,
strike, spell ready, spell release, dead: mobs_act.blp's columns), each in the four facings. A layer's frames are
cropped to one box (the union of its pixels in all 32 frames, 4-aligned for the DXT blocks) and stored as a block
of 8 x 4 frames: columns walk 0-2 then action 0-4, rows down / left / right / up.

Writes Media/Azeromon/Outfit/outfitN.blp (DXT5, no mips: the sprites are drawn at their size or larger) and
Games/Disastercraft/OutfitData.lua.

Run: luaenv\\Scripts\\python.exe generators\\gen_dc_outfits.py [--jobs N] [--only itemId,...]"""
import math
import multiprocessing as mp
import os
import re
import sys
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

ADDON = os.path.join(HERE, "..", "..", "addon", "DisasterZone")
DATA_LUA = os.path.join(ADDON, "Games", "Disastercraft", "Data.lua")
OUT_LUA = os.path.join(ADDON, "Games", "Disastercraft", "OutfitData.lua")
MEDIA = os.path.join(ADDON, "Media", "Azeromon", "Outfit")
MEDIA_GAME = "Interface\\AddOns\\DisasterZone\\Media\\Azeromon\\Outfit\\"

RACE = 1                                     # human
SIZE = 32
# inventory types that show on a character -> the paint order of their layer (low first)
ORDER = {4: 1, 7: 2, 8: 3, 9: 4, 5: 5, 20: 5, 10: 6, 6: 7, 19: 8, 16: 9, 14: 10, 22: 10, 23: 10,
         13: 11, 21: 11, 17: 11}
PIN = ("dc-pin",)
BOX = (2.6, 2.6, -0.6, 3.6)                  # yd round the model origin: x / y half widths, z low / high
SHEET_W = 1024


def wearable_items():
    """{item id: inventory type} of Disastercraft's items that show on a character."""
    s = open(DATA_LUA, encoding="utf-8").read()
    out = {}
    for m in re.finditer(r"^I\[(\d+)\] = \{[^\n]*?\binv = (\d+)", s, re.M):
        if int(m.group(2)) in ORDER:
            out[int(m.group(1))] = int(m.group(2))
    return out


def _pins(mesh):
    """The mesh with eight specks at the canvas box corners (a transparent texture: never drawn)."""
    verts, uvs, tris = [np.asarray(mesh["verts"], np.float32)], [np.asarray(mesh["uvs"], np.float32)], list(mesh["tris"])
    n = len(verts[0])
    e = 0.01
    pv = []
    for x in (-BOX[0], BOX[0]):
        for y in (-BOX[1], BOX[1]):
            for z in (BOX[2], BOX[3]):
                pv += [(x, y, z), (x + e, y, z), (x, y, z + e)]
    pv = np.array(pv, np.float32)
    for k in range(8):
        tris.append((n + 3 * k, n + 3 * k + 1, n + 3 * k + 2, PIN))
    verts.append(pv)
    uvs.append(np.zeros((len(pv), 2), np.float32))
    return dict(mesh, verts=np.concatenate(verts), uvs=np.concatenate(uvs), tris=tris)


_W = {}


def _setup():
    import azw_people as AP
    import azw_render as RD
    RD.register_texture(PIN, np.zeros((2, 2, 4), np.float32))
    _W["AP"], _W["RD"] = AP, RD


def _poses(sex):
    """[(seq, t)] x 8: the walk's three and the five action poses, from the bare body (so every layer and the body
    take the same poses whatever is worn)."""
    AP, RD = _W["AP"], _W["RD"]
    body, weapons, data = AP.outfit(RACE, sex, [])
    stand, _ = RD.find_sequence(data, 0)
    walk, dur = RD.find_sequence(data, 4)
    out = []
    for seq, t in ((walk, dur // 4), (stand, 0), (walk, 3 * dur // 4)):
        out.append((seq, t) if seq is not None else (stand, 0))

    def reach(seq, t):
        return float(RD.posed_vertices(data, seq, t)[:, 0].max())
    out += AP._act_times(data, AP.ATTACK_IDS, reach)
    return out


def _render(sex, items, poses):
    """{(col, face): (canvas RGBA, origin)} for the body wearing these items."""
    AP, RD = _W["AP"], _W["RD"]
    got = AP.outfit(RACE, sex, items)
    if not got:
        return None
    body, weapons, data = got
    out = {}
    for col, (seq, t) in enumerate(poses):
        mats = RD.bone_mats(data, seq, t)
        pm = _pins(AP._dress(body, weapons, data, mats, RD.posed_vertices(data, seq, t)))
        for face, (fname, yaw) in enumerate((("down", AP.FACING["down"]), ("left", AP.FACING["left"]),
                                             ("right", AP.FACING["right"]), ("up", AP.FACING["up"]))):
            img, origin = RD.render(pm, yaw, AP.ELEV, AP.PPY_BODY, oversample=4, ambient=0.72, diffuse=0.42)
            out[(col, face)] = (img, origin)
    return out


def _place(canvas, origin, mask, bottom):
    """Canvas pixels under mask into a 32 x 32 cell by the bare body's fit."""
    cell = np.zeros((SIZE, SIZE, 4), np.uint8)
    dx = int(round(SIZE / 2 - origin[0]))
    dy = SIZE - bottom
    ys, xs = np.nonzero(mask)
    tx, ty = xs + dx, ys + dy
    ok = (tx >= 0) & (tx < SIZE) & (ty >= 0) & (ty < SIZE)
    cell[ty[ok], tx[ok]] = canvas[ys[ok], xs[ok]]
    return cell


def _body_job(sex):
    _setup()
    poses = _poses(sex)
    bare = _render(sex, [], poses)
    frames, fits = {}, {}
    for k, (img, origin) in bare.items():
        ys = np.nonzero(img[..., 3])[0]
        bottom = int(ys.max()) + 1 if len(ys) else img.shape[0]
        fits[k] = bottom
        frames[k] = _place(img, origin, img[..., 3] > 0, bottom)
    return sex, poses, {k: (v[0][..., 3] > 0, v[0], v[1]) for k, v in bare.items()}, fits, frames


def _init(bodies):
    _setup()
    _W["bodies"] = {sex: (poses, bare, fits) for sex, poses, bare, fits, _ in bodies}


def _item_job(args):
    sex, item = args
    poses, bare, fits = _W["bodies"][sex]
    try:
        drawn = _render(sex, [item], poses)
    except Exception as e:  # noqa: BLE001
        return sex, item, None, str(e)
    if not drawn:
        return sex, item, None, "no outfit"
    frames = {}
    for k, (img, origin) in drawn.items():
        b_alpha, b_img, b_origin = bare[k]
        if img.shape != b_img.shape or tuple(origin) != tuple(b_origin):
            return sex, item, None, "canvas moved %s %s" % (img.shape, b_img.shape)
        a = img[..., 3] > 0
        diff = np.abs(img[..., :3].astype(np.int16) - b_img[..., :3].astype(np.int16)).max(-1) > 3
        mask = a & (~b_alpha | diff)
        frames[k] = _place(img, origin, mask, fits[k])
    return sex, item, frames, None


def _crop(frames):
    """32 frames -> [(frame index, piece RGBA, ox, oy)] each cut to its own pixels (4-aligned for the DXT blocks);
    frame index = column * 4 + facing row. Frames with nothing to show are left out."""
    out = []
    for (col, face), f in frames.items():
        ys, xs = np.nonzero(f[..., 3])
        if len(xs) == 0:
            continue
        x0, x1, y0, y1 = int(xs.min()), int(xs.max()) + 1, int(ys.min()), int(ys.max()) + 1
        w = ((x1 - x0) + 3) // 4 * 4
        h = ((y1 - y0) + 3) // 4 * 4
        ox, oy = min(x0, SIZE - w), min(y0, SIZE - h)
        out.append((col * 4 + face, f[oy:oy + h, ox:ox + w].copy(), ox, oy))
    return out


def _pack(pieces):
    """Shelf-pack pieces {key: RGBA} into SHEET_W-wide sheets (power-of-two heights, at most 2048).
    -> [sheet image], {key: (sheet number, x, y)}"""
    order = sorted(pieces, key=lambda k: (-pieces[k].shape[0], -pieces[k].shape[1], str(k)))
    sheets, where = [], {}
    cur, x, y, shelf = [], 0, 0, 0
    for key in order:
        b = pieces[key]
        h, w = b.shape[:2]
        if x + w > SHEET_W:
            x, y, shelf = 0, y + shelf, 0
        if y + h > 2048:
            sheets.append((cur, y + shelf))
            cur, x, y, shelf = [], 0, 0, 0
        cur.append((key, x, y))
        where[key] = (len(sheets), x, y)
        x += w
        shelf = max(shelf, h)
    sheets.append((cur, y + shelf))
    images = []
    for items, height in sheets:
        hh = 4
        while hh < height:
            hh *= 2
        img = np.zeros((hh, SHEET_W, 4), np.uint8)
        for key, x, y in items:
            b = pieces[key]
            img[y:y + b.shape[0], x:x + b.shape[1]] = b
        images.append(img)
    return images, where


def write_blp(img, path):
    """BLP2 DXT5 without mips (azw_blp's encoder)."""
    import struct
    from azw_blp import _dxt5
    pic = Image.fromarray(img, "RGBA")
    w, h = pic.size
    data = _dxt5(pic)
    header = 4 + 4 + 4 + 8 + 16 * 4 * 2 + 256 * 4
    with open(path, "wb") as f:
        f.write(b"BLP2")
        f.write(struct.pack("<I", 1))
        f.write(struct.pack("<BBBB", 2, 8, 7, 0))          # DXTC, 8-bit alpha, DXT5, no mips
        f.write(struct.pack("<II", w, h))
        f.write(struct.pack("<16I", header, *([0] * 15)))
        f.write(struct.pack("<16I", len(data), *([0] * 15)))
        f.write(b"\0" * 1024)
        f.write(data)


CACHE = os.path.join(HERE, "..", "art", "dc_outfits.pickle")


def main():
    import pickle
    args = sys.argv[1:]
    jobs = max(1, (os.cpu_count() or 4) - 1)
    only, force = None, False
    while args:
        a = args.pop(0)
        if a == "--jobs":
            jobs = int(args.pop(0))
        elif a == "--only":
            only = {int(x) for x in args.pop(0).split(",")}
        elif a == "--force":
            force = True                     # (draw everything again: the renderer or the bodies changed)
    import tbcdb
    it = tbcdb.load().index("item_template", "entry")
    items = wearable_items()
    if only:
        items = {k: v for k, v in items.items() if k in only}
    # one layer per look: items sharing a display share it
    by_display = {}
    for e, inv in sorted(items.items()):
        d = it.get(e) and it[e]["displayid"]
        if d:
            by_display.setdefault((d, inv in (13, 21, 17), inv), e)
    reps = sorted(set(by_display.values()))
    cache = {}
    if not force and os.path.exists(CACHE):
        with open(CACHE, "rb") as f:
            cache = pickle.load(f)
    t0 = time.time()
    with mp.Pool(min(jobs, 2)) as pool:
        bodies = pool.map(_body_job, [0, 1])
    print("bodies %.0fs" % (time.time() - t0))
    drawn = {("body", sex): frames for sex, _, _, _, frames in bodies}
    work = []
    for sex, *_ in bodies:
        for e in reps:
            key = ("item", sex, e, it[e]["displayid"])
            if key in cache:
                drawn[("item", sex, e)] = cache[key]
            else:
                work.append((sex, e))
    failed = []
    if work:
        with mp.Pool(jobs, initializer=_init, initargs=(bodies,)) as pool:
            for n, (sex, e, frames, err) in enumerate(pool.imap_unordered(_item_job, work, chunksize=2)):
                if err:
                    failed.append((e, sex, err))
                    continue
                drawn[("item", sex, e)] = frames
                cache[("item", sex, e, it[e]["displayid"])] = frames
                if n % 50 == 0:
                    print("  %d / %d  %.0fs" % (n, len(work), time.time() - t0))
        with open(CACHE, "wb") as f:
            pickle.dump(cache, f, protocol=4)
    # every frame of every layer cut to its own pixels, all packed together
    pieces, cut = {}, {}
    for key, frames in drawn.items():
        cut[key] = _crop(frames)
        for k, piece, ox, oy in cut[key]:
            pieces[key + (k,)] = piece
    images, where = _pack(pieces)
    os.makedirs(MEDIA, exist_ok=True)
    for f in os.listdir(MEDIA):
        if f.startswith("outfit") and f.endswith(".blp"):
            os.remove(os.path.join(MEDIA, f))
    total = 0
    for i, img in enumerate(images):
        p = os.path.join(MEDIA, "outfit%d.blp" % (i + 1))
        write_blp(img, p)
        total += os.path.getsize(p)

    # a layer: 32 frames x { sheet, x, y, w, h, ox, oy } (sheet 0: nothing in that frame)
    def layer(key):
        cells = [[0, 0, 0, 0, 0, 0, 0] for _ in range(32)]
        for k, piece, ox, oy in cut[key]:
            n, x, y = where[key + (k,)]
            cells[k] = [n + 1, x, y, piece.shape[1], piece.shape[0], ox, oy]
        return "{ " + ",".join(str(v) for c in cells for v in c) + " }"
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/OutfitData.lua", ...) then return end '
        "-- DisasterZone Games/Disastercraft/OutfitData.lua",
        "-- Generated by dev/generators/gen_dc_outfits.py - do not edit. The hero's sprite in its gear: a bare human",
        "-- and one layer per item look (Media/Azeromon/Outfit/outfitN.blp). A layer: 32 frames (frame = column * 4 +",
        "-- facing; columns walk 0-2 then action 0-4, facings down, left, right, up) of 7 numbers each - sheet, x, y,",
        "-- w, h on the sheet, ox, oy where it sits in the sprite's 32 px cell; sheet 0 = nothing in that frame.",
        "local addonName, ns = ...",
        "local O = { sheets = {}, sizes = {}, layers = {}, body = {}, items = { [0] = {}, [1] = {} } }",
        "ns.CraftOutfit = O",
        "local L = O.layers",
        "O.order = { %s }" % ", ".join("[%d] = %d" % (k, v) for k, v in sorted(ORDER.items())),
    ]
    for i, img in enumerate(images):
        lines.append('O.sheets[%d] = "%s"' % (i + 1, (MEDIA_GAME + "outfit%d" % (i + 1)).replace("\\", "\\\\")))
        lines.append("O.sizes[%d] = { %d, %d }" % (i + 1, img.shape[1], img.shape[0]))
    index = {}
    for key in sorted(drawn, key=lambda k: (k[0] != "body",) + tuple(k[1:])):
        if cut[key]:
            index[key] = len(index) + 1
            lines.append("L[%d] = %s" % (index[key], layer(key)))
    for sex in (0, 1):
        lines.append("O.body[%d] = %d" % (sex, index[("body", sex)]))
    for sex in (0, 1):
        for e, inv in sorted(items.items()):
            d = it.get(e) and it[e]["displayid"]
            rep = by_display.get((d, inv in (13, 21, 17), inv))
            if rep and ("item", sex, rep) in index:
                lines.append("O.items[%d][%d] = %d" % (sex, e, index[("item", sex, rep)]))
    data = "\n".join(lines) + "\n"
    with open(OUT_LUA, "wb") as f:
        f.write(data.encode("utf-8"))
    print("%d layers, %d pieces on %d sheet(s), %.1f MB, data %.0f KB; %d failed %s" % (
        len(index), len(pieces), len(images), total / 1e6, len(data) / 1e3, len(failed), failed[:6]))


if __name__ == "__main__":
    main()



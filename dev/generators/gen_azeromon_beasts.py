r"""Azeromon's pixel beasts (2026-10-17): every species' own WoW model rendered and pixelized into battle sprites at
the battle screen's game-pixel scale (the backdrops are 224 x 144 game px, drawn 3x), Pokemon style:

  foe  view: front three-quarter (turned toward the player, screen left)
  ally view: back three-quarter (turned toward the foe, screen right)

Clips: idle (the stand animation's first second, played back and forth), attack, attack2 (a second, different
attack when the model has one), special (cast / roar: special moves and status moves), hit, faint.

Pixelize: render at 4x and box-downsample, hard alpha, levels (WoW textures are dark and flat) + more colour, ONE
16-colour palette per beast for both views, despeckle (texture noise -> clean shapes), selective outline (each edge
pixel takes a dark version of the body colour next to it: at most 16 more colours).

Balanced sizes: a beast's height on screen follows its base stat total (weak = small, strong = big), never the
model's own scale. Each view's cell fits the box of EVERY frame (a tiger's tail, a lunge, a faint), the idle centred.

Each beast's trimmed frames (both views) are packed into one block; the blocks of all beasts are packed into shared
1024 x 1024 pages (at most 256 colours a page), so a battle loads two pages at most. Rendered blocks are kept in
dev/art/casc/beasts/ (git-ignored): re-rendering one beast repacks every page in seconds.

Writes (in the addon):
  DisasterZone_Azeromon/Media/Beasts/p<NN>.blp     the pages: palette BLP2 like the client's own (pal_blp.py; 1-bit alpha, mips)
  DisasterZone_Azeromon/BeastArt.lua         ns.AzeroBeastArt: per beast its page, the page size and every frame's rectangle
                                      and offset from the feet, per view and clip (strings, decoded on first use)
Shiny skins (Data.lua D.shinyDisplay) are rendered too, as <species>_s.

Run from dev: luaenv\Scripts\python.exe generators\gen_azeromon_beasts.py [species ...] [--qc DIR] [--jobs N]
(no species: all of them; with species: only those are re-rendered, then every page is repacked)."""
import argparse
import json
import math
import multiprocessing as mp
import os
import sys
import time

import numpy as np
from PIL import Image, ImageEnhance

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
DEV = os.path.dirname(HERE)
ADDON = os.path.join(os.path.dirname(DEV), "addon", "DisasterZone")
DATA_LUA = os.path.join(ADDON, "..", "DisasterZone_Azeromon", "Data.lua")
OUT_TEX = os.path.join(ADDON, "..", "DisasterZone_Azeromon", "Media", "Beasts")
OUT_LUA = os.path.join(ADDON, "..", "DisasterZone_Azeromon", "BeastArt.lua")
BLOCKS = os.path.join(DEV, "art", "casc", "beasts")                # (git-ignored) every beast's rendered block
PAGE = 1024

OVER = 4                        # render at 4x, box-downsample to game pixels
VIEWS = {   # facing (0 = toward the camera, + = turned to screen right), camera elevation, base cell, size factor
    "foe": (-0.62, 14, 80, 1.0),
    "ally": (math.pi - 0.62, 20, 96, 1.12),
}
SMALL_PX, BIG_PX, BST_LO, BST_HI = 38, 64, 250, 600
AMBIENT, DIFFUSE = 0.5, 0.8
IDLE_MS = 1100
ATTACKS = (16, 17, 18, 19, 20, 21, 22)          # AttackUnarmed, 1H, 2H, 2HL, ... (the first two distinct ones)
# frames a clip (the idle plays back and forth: 4 frames = a 6-step loop)
CLIPS = [("idle", (0,), 4, True), ("attack", None, 5, False), ("attack2", None, 5, False),
         ("special", (54, 53, 55, 52, 51), 5, False), ("hit", (9, 10, 8), 3, False), ("faint", (1,), 5, False)]
COLORS = 16


def load_data():
    from lupa import lua51
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    ns = lua.eval("{}")
    with open(DATA_LUA, encoding="utf-8") as f:
        lua.eval("loadstring")(f.read())("DisasterZone", ns)
    D = ns.AzeroData
    species = {}
    for k, s in D.species.items():
        base = [s.base[i] for i in range(1, 7)]
        species[k] = {"display": s.display, "bst": sum(base), "name": s.name}
    shiny = {k: v for k, v in D.shinyDisplay.items()} if D.shinyDisplay else {}
    return species, shiny


def yaw_for(facing):
    return -math.pi / 2 - (math.pi / 2 - facing)


def measure(img):
    ys, xs = np.nonzero(img[:, :, 3] > 40)
    return (xs.min(), xs.max(), ys.min(), ys.max()) if len(xs) else None


# ---------------------------------------------------------------- model + animations
def _load(display):
    import azw_people as AP
    import azw_render as RD
    import casc_local as C
    mesh = AP.character_mesh(display)
    data = C.read_fid(mesh["fid"])
    sc = mesh.get("scale", 1.0)

    def pose(seq, t):
        if seq is None:
            return mesh
        return dict(mesh, verts=RD.posed_vertices(data, seq, t) * sc)
    return data, pose


def _seq(data, ids, skip=None):
    import azw_render as RD
    for a in ids:
        s, d = RD.find_sequence(data, a)
        if s is not None and d and s != skip:
            return s, d
    return None, 0


def _columns(data):
    """(clip name, sequence, n, loop, [times]) for every clip; attack2 is None when the model has one attack"""
    out = []
    first = None
    for name, ids, n, loop in CLIPS:
        if name == "attack":
            s, d = _seq(data, ATTACKS)
            first = s
        elif name == "attack2":
            s, d = _seq(data, ATTACKS, skip=first)
            if s is None:
                continue
        else:
            s, d = _seq(data, ids)
        if s is None:
            s, d = _seq(data, (0,))
        if loop:     # never t = 0: some models have no key there (an owl came out upside down)
            span = min(d, IDLE_MS)
            times = [int(d * 0.01 + span * i / (n - 1)) for i in range(n)]
        else:
            times = [int(d * (0.03 + 0.94 * i / (n - 1))) for i in range(n)]
        out.append((name, s, n, loop, times))
    return out


# ---------------------------------------------------------------- pixelize
def _downsample(img, ox, oy, cw, ch, base, shift_x):
    """one OVER-scale render -> (ch, cw, 4) RGBA float colour + coverage, the idle centred, feet on `base`"""
    im = Image.fromarray(img)
    canvas = Image.new("RGBA", (cw * OVER, ch * OVER), (0, 0, 0, 0))
    canvas.paste(im, (int(round(cw * OVER / 2 - ox - shift_x * OVER)), int(round(base * OVER - oy))), im)
    a = np.asarray(canvas).astype(np.float32) / 255.0
    rgb, al = a[:, :, :3] * a[:, :, 3:4], a[:, :, 3]
    rgb = rgb.reshape(ch, OVER, cw, OVER, 3).mean(axis=(1, 3))
    al = al.reshape(ch, OVER, cw, OVER).mean(axis=(1, 3))
    with np.errstate(invalid="ignore", divide="ignore"):
        col = np.where(al[..., None] > 0, rgb / np.maximum(al[..., None], 1e-6), 0)
    out = np.zeros((ch, cw, 4), np.uint8)
    out[..., :3] = np.clip(col * 255, 0, 255).astype(np.uint8)
    out[..., 3] = np.where(al > 0.45, 255, 0)
    return out


def _despeckle(code, a):
    """a body pixel matching none of its 4 neighbours, while 3+ of them agree, takes their colour"""
    code = np.where(a, code, -1)
    for _ in range(2):
        pad = np.pad(code, 1, constant_values=-1)
        nb = [pad[:-2, 1:-1], pad[2:, 1:-1], pad[1:-1, :-2], pad[1:-1, 2:]]
        same = sum((n == code).astype(np.int32) for n in nb)
        lone = a & (same == 0)
        if not lone.any():
            break
        for y, x in zip(*np.nonzero(lone)):
            vals = [n[y, x] for n in nb if n[y, x] >= 0]
            if len(vals) >= 3:
                best = max(set(vals), key=vals.count)
                if vals.count(best) >= 3:
                    code[y, x] = best
    return code


def pixelize(frames):
    """frames: list of (h, w, 4) uint8 (any sizes). One palette across all -> list of RGBA uint8 arrays with at most
    16 body colours + 16 outline shades."""
    lum = np.concatenate([(f[..., :3].astype(np.float32) @ np.array([0.3, 0.59, 0.11]))[f[..., 3] > 0] for f in frames])
    lo, hi = (np.percentile(lum, 4), np.percentile(lum, 98)) if len(lum) else (0, 255)

    def punch(arr):     # levels: darkest 4 % to 0.10, brightest 2 % to 0.97, a little gamma, more colour
        x = (arr[..., :3].astype(np.float32) - lo) / max(1.0, hi - lo)
        x = np.clip(0.10 + 0.87 * x, 0, 1) ** 0.92
        return np.asarray(ImageEnhance.Color(Image.fromarray((x * 255).astype(np.uint8))).enhance(1.3))
    punched = [punch(f) for f in frames]
    pix = np.concatenate([p[f[..., 3] > 0] for p, f in zip(punched, frames)])
    if len(pix) == 0:
        return [f.copy() for f in frames]
    pal_img = Image.fromarray(pix.reshape(1, -1, 3).astype(np.uint8)).quantize(colors=COLORS, method=Image.Quantize.MEDIANCUT)
    pal = np.array(pal_img.getpalette()[:COLORS * 3], np.int32).reshape(-1, 3)
    dark = (pal * 0.28 + np.array([12, 9, 18]) * 0.72).astype(np.uint8)          # the outline shade of each colour
    out = []
    for p, f in zip(punched, frames):
        a = f[..., 3] > 0
        idx = np.asarray(Image.fromarray(p).quantize(palette=pal_img, dither=Image.Dither.NONE)).astype(np.int64)
        idx = np.clip(idx, 0, len(pal) - 1)
        idx = _despeckle(idx, a)
        img = np.zeros(f.shape, np.uint8)
        img[a, :3] = pal[np.maximum(idx[a], 0)].astype(np.uint8)
        img[a, 3] = 255
        # selective outline: an empty pixel touching the body takes the dark shade of the most common colour next to it
        pad = np.pad(np.where(a, idx, -1), 1, constant_values=-1)
        nbs = np.stack([pad[:-2, 1:-1], pad[2:, 1:-1], pad[1:-1, :-2], pad[1:-1, 2:]], -1)
        ring = (nbs >= 0).any(-1) & ~a
        for y, x in zip(*np.nonzero(ring)):
            vals = [int(v) for v in nbs[y, x] if v >= 0]
            img[y, x, :3] = dark[max(set(vals), key=vals.count)]
            img[y, x, 3] = 255
        out.append(img)
    return out


# ---------------------------------------------------------------- one beast
def render(job):
    """job = (key, display, bst) -> (key, {view: {cw, ch, base, px, iw, clips: {name: [frames]}}}, [images])"""
    import azw_render as RD
    key, display, bst = job
    t0 = time.time()
    data, pose = _load(display)
    cols = _columns(data)
    poses, spans = [], []
    for name, s, n, loop, times in cols:
        spans.append((name, len(poses), n, loop))
        poses += [pose(s, t) for t in times]
    kbst = max(0.0, min(1.0, (bst - BST_LO) / (BST_HI - BST_LO)))
    idle0, idle_n = spans[0][1], spans[0][2]
    views, raw = {}, []
    for view, (facing, elev, cell, factor) in VIEWS.items():
        yaw = yaw_for(facing)
        boxes = []
        for pm in poses:
            im, (ox, oy) = RD.render(pm, yaw, elev, 40, oversample=1)
            b = measure(im) if im is not None else None
            boxes.append((b[0] - ox, b[1] - ox, b[2] - oy, b[3] - oy) if b else None)

        def union(bs):
            bs = [b for b in bs if b] or [(-1, 1, -2, 0)]
            return (min(b[0] for b in bs), max(b[1] for b in bs), min(b[2] for b in bs), max(b[3] for b in bs))
        IL, IR, IT, IB = union(boxes[idle0:idle0 + idle_n])
        AL, AR, AT, AB = union(boxes)
        h_yd, w_yd = max(0.01, (IB - IT) / 40.0), max(0.01, (IR - IL) / 40.0)
        target = (SMALL_PX + (BIG_PX - SMALL_PX) * kbst) * factor
        ppy = min(target / max(h_yd, 0.75 * w_yd), (cell - 8) / h_yd)
        k = ppy / 40.0
        cx = (IL + IR) / 2.0
        half = max(cx - AL, AR - cx) * k
        cw = max(cell, int(math.ceil(2 * half)) + 6)
        cw += cw % 2
        below = max(0.0, (AB - IB) * k)
        ch = max(cell, int(math.ceil((IB - AT) * k + below)) + 6)
        base = ch - 3 - int(math.ceil(below))
        drop = IB * k
        imgs = []
        for pm in poses:
            img, (ox, oy) = RD.render(pm, yaw, elev, ppy * OVER, oversample=2, ambient=AMBIENT, diffuse=DIFFUSE)
            if img is None:
                imgs.append(np.zeros((ch, cw, 4), np.uint8))
                continue
            imgs.append(_downsample(img, ox, oy + drop * OVER, cw, ch, base, cx * k))
        views[view] = {"cw": cw, "ch": ch, "base": base, "px": round(min(target, ppy * h_yd), 1),
                       "iw": int(round((IR - IL) * k))}
        raw.append((view, imgs))
    # one palette for both views
    flat = [im for _, imgs in raw for im in imgs]
    pix = pixelize(flat)
    out_frames, i = {}, 0
    for view, imgs in raw:
        frames = pix[i:i + len(imgs)]
        i += len(imgs)
        v = views[view]
        clips = {}
        for name, start, n, loop in spans:
            lst = []
            for f in frames[start:start + n]:
                ys, xs = np.nonzero(f[..., 3])
                if len(xs) == 0:
                    lst.append({"img": np.zeros((1, 1, 4), np.uint8), "lx": 0, "bt": 0})
                    continue
                x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
                lst.append({"img": f[y0:y1, x0:x1].copy(),
                            "lx": int(x0 - v["cw"] // 2),          # left edge, game px right of the feet
                            "bt": int(v["base"] - y1)})             # bottom edge, game px above the feet
            clips[name] = {"loop": loop, "frames": lst}
        v["clips"] = clips
        out_frames[view] = v
    print("%-16s bst %3d  foe %2.0f px  %s  %.0fs" % (key, bst, views["foe"]["px"],
          "+attack2" if any(s[0] == "attack2" for s in spans) else "        ", time.time() - t0), flush=True)
    return key, out_frames


# ---------------------------------------------------------------- packing + files
def _shelf(sizes, W):
    """shelf-pack (w, h) sizes into width W (1 px gaps): positions, height used"""
    order = sorted(range(len(sizes)), key=lambda i: -sizes[i][1])
    x = y = shelf = 0
    pos = [None] * len(sizes)
    for i in order:
        w, h = sizes[i]
        if x + w + 1 > W:
            x, y, shelf = 0, y + shelf + 1, 0
        pos[i] = (x, y)
        x += w + 1
        shelf = max(shelf, h)
    return pos, y + shelf + 1


def make_block(beast):
    """all frames of both views -> one tight block (RGBA) at the best of a few widths; frame records get bx, by"""
    items = [fr for view in ("foe", "ally") for clip in beast[view]["clips"].values() for fr in clip["frames"]]
    sizes = [(fr["img"].shape[1], fr["img"].shape[0]) for fr in items]
    widest = max(w for w, _ in sizes) + 1
    best = None
    for W in (192, 256, 320, 384, 448, 512, 640, 768):        # (a block never fills a page: room for the gap)
        if W < widest:
            continue
        pos, H = _shelf(sizes, W)
        if H <= PAGE and (best is None or W * H < best[0]):
            best = (W * H, W, H, pos)
    _, W, H, pos = best
    block = np.zeros((H, W, 4), np.uint8)
    for fr, (x, y) in zip(items, pos):
        im = fr["img"]
        block[y:y + im.shape[0], x:x + im.shape[1]] = im
        fr["bx"], fr["by"] = x, y
    return block


class MaxRects:
    """free-rectangle packer (best short side fit) for one page"""

    def __init__(self, W, H):
        self.free = [(0, 0, W, H)]

    def fit(self, w, h):
        best = None
        for fx, fy, fw, fh in self.free:
            if w <= fw and h <= fh:
                score = (min(fw - w, fh - h), max(fw - w, fh - h))
                if best is None or score < best[0]:
                    best = (score, fx, fy)
        return None if best is None else (best[1], best[2])

    def place(self, x, y, w, h):
        out = []
        for fx, fy, fw, fh in self.free:
            if x >= fx + fw or x + w <= fx or y >= fy + fh or y + h <= fy:
                out.append((fx, fy, fw, fh))
                continue
            if x > fx:
                out.append((fx, fy, x - fx, fh))
            if x + w < fx + fw:
                out.append((x + w, fy, fx + fw - x - w, fh))
            if y > fy:
                out.append((fx, fy, fw, y - fy))
            if y + h < fy + fh:
                out.append((fx, y + h, fw, fy + fh - y - h))
        # drop rectangles inside others
        self.free = [r for i, r in enumerate(out) if not any(
            j != i and r[0] >= o[0] and r[1] >= o[1] and r[0] + r[2] <= o[0] + o[2] and r[1] + r[3] <= o[1] + o[3]
            and (r != o or j < i) for j, o in enumerate(out))]


def colours(img):
    a = img[..., 3] > 0
    rgb = img[..., :3][a]
    return set(((rgb[:, 0].astype(np.int64) << 16) | (rgb[:, 1].astype(np.int64) << 8) | rgb[:, 2]).tolist())


def pack_pages(blocks):
    """blocks: {key: (block RGBA, beast meta)} -> pages [(RGBA, {key: (x, y)})], every block whole on one page"""
    order = sorted(blocks, key=lambda k: -(blocks[k][0].shape[0] * blocks[k][0].shape[1]))
    pages = []          # [packer, image, placements, colour set]
    for key in order:
        img = blocks[key][0]
        h, w = img.shape[:2]
        cols = colours(img)
        spot = None
        for pg in pages:
            if len(pg[3] | cols) > 256:
                continue
            xy = pg[0].fit(w + 1, h + 1)
            if xy:
                spot = (pg, xy)
                break
        if not spot:
            pg = [MaxRects(PAGE, PAGE), np.zeros((PAGE, PAGE, 4), np.uint8), {}, set()]
            pages.append(pg)
            spot = (pg, pg[0].fit(w + 1, h + 1))
            assert spot[1], (key, w, h)
        pg, (x, y) = spot
        pg[0].place(x, y, w + 1, h + 1)
        pg[1][y:y + h, x:x + w] = img
        pg[2][key] = (x, y)
        pg[3] |= cols
    return [(pg[1], pg[2]) for pg in pages]


def encode_view(v, ox, oy):
    """clip=loop:x,y,w,h,lx,bt,...;clip=...  (ox, oy: the block's place on its page)"""
    parts = []
    for name, clip in v["clips"].items():
        nums = []
        for fr in clip["frames"]:
            nums += [fr["bx"] + ox, fr["by"] + oy, fr["w"], fr["h"], fr["lx"], fr["bt"]]
        parts.append("%s=%d:%s" % (name, 1 if clip["loop"] else 0, ",".join(str(int(n)) for n in nums)))
    return ";".join(parts)


def write_lua(index):
    lines = [
        "if DisasterZoneBoot and DisasterZoneBoot.Run(\"DisasterZone_Azeromon/BeastArt.lua\", ...) then return end -- DisasterZone_Azeromon/BeastArt.lua",
        "-- GENERATED by dev/generators/gen_azeromon_beasts.py - do not edit by hand.",
        "-- Azeromon's pixel beasts: per beast its texture (DisasterZone_Azeromon/Media/Beasts/<tex>.blp, w x h), the idle's height `px`",
        "-- and width `iw` in game pixels, and per view (f = foe / front, a = yours / back) its clips as",
        "-- \"clip=loop:x,y,w,h,lx,bt,...;...\": each frame's rectangle in the texture and its offset from the feet",
        "-- (lx = left edge right of the feet, bt = bottom edge above the feet, in game pixels). Decoded on first use",
        "-- by DisasterZone_Azeromon/Sprites.lua.",
        "local addonName, ns = ...",
        "",
        "ns.AzeroBeastArt = {",
        "    asset = %d," % ASSET_PACK,
        "    dir = \"Interface\\\\AddOns\\\\DisasterZone_Azeromon\\\\Media\\\\Beasts\\\\\",",
        "    beasts = {",
    ]
    for key in sorted(index):
        b = index[key]
        lines.append("        [%s] = { tex = %s, w = %d, h = %d, px = %s, iw = %d, apx = %s," % (
            json.dumps(key), json.dumps(b["tex"]), b["w"], b["h"], b["px"], b["iw"], b["apx"]))
        lines.append("            f = %s," % json.dumps(b["f"]))
        lines.append("            a = %s }," % json.dumps(b["a"]))
    lines += ["    },", "}", ""]
    with open(OUT_LUA, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))


ASSET_PACK = 15


def save_block(key, beast):
    block = make_block(beast)
    for view in ("foe", "ally"):
        for clip in beast[view]["clips"].values():
            for fr in clip["frames"]:
                fr["h"], fr["w"] = fr["img"].shape[:2]
                del fr["img"]
    os.makedirs(BLOCKS, exist_ok=True)
    Image.fromarray(block, "RGBA").save(os.path.join(BLOCKS, key + ".png"))
    json.dump(beast, open(os.path.join(BLOCKS, key + ".json"), "w"))
    return block


def main():
    import pal_blp
    ap = argparse.ArgumentParser()
    ap.add_argument("species", nargs="*")
    ap.add_argument("--qc", help="folder for a contact sheet of every beast")
    ap.add_argument("--jobs", type=int, default=10)
    ap.add_argument("--pack-only", action="store_true", help="repack the rendered blocks, render nothing")
    args = ap.parse_args()
    species, shiny = load_data()
    jobs = []
    for k, s in species.items():
        if s["display"]:
            jobs.append((k, s["display"], s["bst"]))
        if k in shiny:
            jobs.append((k + "_s", shiny[k], s["bst"]))
    keys = [j[0] for j in jobs]
    if args.species:
        want = set(args.species) | {k + "_s" for k in args.species}
        jobs = [j for j in jobs if j[0] in want]
    if args.pack_only:
        jobs = []
    t0 = time.time()
    if jobs:
        with mp.Pool(min(args.jobs, len(jobs))) as pool:
            for key, beast in pool.imap_unordered(render, jobs):
                save_block(key, beast)
    missing = [k for k in keys if not os.path.exists(os.path.join(BLOCKS, k + ".json"))]
    assert not missing, "not rendered yet: %s" % ", ".join(missing)
    blocks = {k: (np.asarray(Image.open(os.path.join(BLOCKS, k + ".png")).convert("RGBA")),
                  json.load(open(os.path.join(BLOCKS, k + ".json")))) for k in keys}
    pages = pack_pages(blocks)
    os.makedirs(OUT_TEX, exist_ok=True)
    for fn in os.listdir(OUT_TEX):
        if fn.endswith(".blp"):
            os.remove(os.path.join(OUT_TEX, fn))
    index = {}
    for n, (img, placed) in enumerate(pages, 1):
        tex = "p%02d" % n
        pal_blp.write(Image.fromarray(img, "RGBA"), os.path.join(OUT_TEX, tex + ".blp"), alpha_depth=1)
        for key, (ox, oy) in placed.items():
            beast = blocks[key][1]
            index[key] = {"tex": tex, "w": PAGE, "h": PAGE, "px": beast["foe"]["px"], "iw": beast["foe"]["iw"],
                          "apx": beast["ally"]["px"], "f": encode_view(beast["foe"], ox, oy),
                          "a": encode_view(beast["ally"], ox, oy)}
    write_lua(index)
    size = sum(os.path.getsize(os.path.join(OUT_TEX, f)) for f in os.listdir(OUT_TEX))
    content = sum(b[0].shape[0] * b[0].shape[1] for b in blocks.values())
    print("%d beasts on %d pages (%.0f %% filled), %.1f MB of textures, %.0fs" % (
        len(index), len(pages), 100.0 * content / (len(pages) * PAGE * PAGE), size / 1e6, time.time() - t0))
    if args.qc:
        os.makedirs(args.qc, exist_ok=True)
        qc_sheet(keys, blocks, species, os.path.join(args.qc, "beasts.png"))


def qc_sheet(keys, blocks, species, path):
    """every beast's front + back idle (frame 1) on grass, 2x, weakest first"""
    order = sorted(keys, key=lambda k: (species.get(k[:-2] if k.endswith("_s") else k, {}).get("bst", 0), k))
    cols, cw, ch = 10, 220, 120
    rows = (len(order) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cw, rows * ch), (96, 150, 84, 255))
    for i, key in enumerate(order):
        block, beast = blocks[key]
        x0, y0 = (i % cols) * cw, (i // cols) * ch
        for j, view in enumerate(("foe", "ally")):
            fr = beast[view]["clips"]["idle"]["frames"][0]
            im = Image.fromarray(block[fr["by"]:fr["by"] + fr["h"], fr["bx"]:fr["bx"] + fr["w"]])
            sheet.alpha_composite(im, (x0 + 4 + j * 104 + max(0, (100 - im.width) // 2), max(0, y0 + ch - 6 - im.height)))
    sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST).save(path)


if __name__ == "__main__":
    main()

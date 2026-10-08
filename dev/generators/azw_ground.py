"""Azeromon world: the ground drawn from WoW's own terrain textures, blended exactly as the client blends them.

A WoW ground texture repeats once per Azeromon tile (8 times across an ADT chunk), so a tile's true look is: every
layer's texture shrunk to one tile (PX pixels), weighted per pixel by the chunk's alpha maps, plus the liquid on
top (WoW's lake texture, more opaque the deeper, fading over the shore).

To fit an addon, each tile is described by its (up to) three strongest textures, the blend masks of the second and
third (10x10: the tile's 8x8 alpha pixels plus one from each neighbour, so the drawn blend runs on across tile
edges) and its water cover (3x3 levels: itself and its neighbours). The masks are clustered (k-means) into a few
hundred shapes; every distinct (textures, mask shapes, water shape) is drawn once into the atlas pages
(Media/Azeromon/Ground/<region>_<n>.blp) and each tile keeps the index of its picture.

tile_layers(...) -> dict of per-tile arrays;  build_tiles(layers) -> (tiles, index);  write_pages(...)"""
import io

import numpy as np
from PIL import Image, ImageEnhance

import adt_tools as A
import casc_local as C

PX = 32                    # pixels a tile (the screen shows 48: drawn smooth, not as blocks)
NL = 3                     # textures kept per tile
MW = 10                    # mask window (alpha pixels): the tile's 8 and one each side
_TEX = {}


def tex16(fid):
    """The texture shrunk to one tile (WoW draws it once per tile)."""
    if fid in _TEX:
        return _TEX[fid]
    try:
        im = Image.open(io.BytesIO(C.read_fid(fid))).convert("RGB")
        t = im.resize((PX, PX), Image.LANCZOS)
        t = ImageEnhance.Contrast(t).enhance(1.15)
        t = ImageEnhance.Color(t).enhance(1.08)
        arr = np.asarray(t, np.float32) / 255.0
    except Exception:
        arr = np.full((PX, PX, 3), 0.5, np.float32)
    _TEX[fid] = arr
    return arr


def _water_tex():
    fid = C.fdid_of("xtextures/river/lake_a.1.blp")
    im = Image.open(io.BytesIO(C.read_fid(fid))).convert("RGB")
    a = np.asarray(im.resize((PX, PX), Image.LANCZOS), np.float32) / 255.0
    lum = a.mean(axis=2, keepdims=True)
    tint = np.array([0.26, 0.52, 0.84], np.float32)             # Elwynn's river blue (WoW tints the grey lake texture)
    return np.clip(tint * (0.75 + (lum - lum.mean()) * 1.6), 0, 1)


WATER_ALPHA = {1: 0.62, 2: 0.8, 3: 0.92}


Q = 5                      # levels a blend / water sample is rounded to (0 .. Q-1)


def _sample3(m, ty, tx):
    """The weight map m (alpha pixels, 8 a tile) at the tile's 3x3 points - corners, edge middles, centre - read
    bilinearly at those exact spots, so a neighbouring tile reads the very same values on the edge it shares."""
    H, W = m.shape
    out = np.zeros((3, 3), np.float32)
    for j, fy in enumerate((0.0, 4.0, 8.0)):
        for i, fx in enumerate((0.0, 4.0, 8.0)):
            x, y = tx * 8 + fx - 0.5, ty * 8 + fy - 0.5
            x0, y0 = int(np.floor(x)), int(np.floor(y))
            ax, ay = x - x0, y - y0
            x0c, x1c = min(max(x0, 0), W - 1), min(max(x0 + 1, 0), W - 1)
            y0c, y1c = min(max(y0, 0), H - 1), min(max(y0 + 1, 0), H - 1)
            out[j, i] = (m[y0c, x0c] * (1 - ax) * (1 - ay) + m[y0c, x1c] * ax * (1 - ay)
                         + m[y1c, x0c] * (1 - ax) * ay + m[y1c, x1c] * ax * ay)
    return out


KC = 2                     # textures kept at each tile corner


def tile_layers(mapname, gx0, gx1, gy0, gy1, raw):
    """The ground as blends at tile CORNERS: at every corner of every tile, the KC strongest textures there and
    their shares rounded to Q levels. A tile is drawn by blending its four corners' textures bilinearly, and the
    four tiles that meet at a corner read the very same corner: no seam can appear between tiles.
    -> {"corners": {(cx, cy): ((fid, level), ...)} for cx in [gx0, gx1], cy in [gy0, gy1], "water": (H+1, W+1)}"""
    big = bool(A.wdt_flags(mapname) & 0x84)
    W, H = gx1 - gx0, gy1 - gy0
    corners = {}
    N = 16 * 64
    for X in range(gx0 // 128, gx1 // 128 + 1):
        for Y in range(gy0 // 128, gy1 // 128 + 1):
            t = A.Tile(mapname, X, Y, big)
            if not t.ok:
                continue
            maps = {}
            for (r, c), lay in t.layers.items():
                if not lay:
                    continue
                alphas = [np.ones((64, 64), np.float32) if al is None else np.array(al, np.float32).reshape(64, 64)
                          for _, al in lay]
                rest = np.ones((64, 64), np.float32)
                for i in range(len(lay) - 1, -1, -1):
                    fid = lay[i][0]
                    m = maps.get(fid)
                    if m is None:
                        m = maps[fid] = np.zeros((N, N), np.float32)
                    m[r * 64:(r + 1) * 64, c * 64:(c + 1) * 64] += alphas[i] * rest
                    rest = rest * (1 - alphas[i])
            fids = list(maps)
            if not fids:
                continue
            # each texture's weight at the tile corners of this ADT: the mean of the 2x2 alpha pixels around each
            st = np.stack([np.pad(maps[f], 1, mode="edge") for f in fids])            # (F, N+2, N+2)
            cw = (st[:, 0:N + 1:8, 0:N + 1:8] + st[:, 1:N + 2:8, 0:N + 1:8]
                  + st[:, 0:N + 1:8, 1:N + 2:8] + st[:, 1:N + 2:8, 1:N + 2:8]) / 4      # (F, 129, 129)
            order = np.argsort(-cw, axis=0)
            for cy in range(129):
                gy = Y * 128 + cy
                if not (gy0 <= gy <= gy1):
                    continue
                for cx in range(129):
                    gx = X * 128 + cx
                    if not (gx0 <= gx <= gx1) or (gx, gy) in corners:
                        continue
                    keep = [order[k, cy, cx] for k in range(min(KC, len(fids)))]
                    w = np.array([cw[fi, cy, cx] for fi in keep])
                    w = w / max(w.sum(), 1e-4)
                    lv = np.rint(w * (Q - 1)).astype(int)
                    # (rounding: the levels add up to Q-1, the strongest takes what is missing)
                    lv[0] += (Q - 1) - lv.sum()
                    corners[(gx, gy)] = tuple(sorted((int(fids[fi]), int(l)) for fi, l in zip(keep, lv) if l > 0))
    # water: the cover at each corner from the liquid levels of the four tiles around it
    lev = np.zeros((H + 2, W + 2), np.float32)
    for y in range(H):
        for x in range(W):
            lx, ly = gx0 + x - raw["gx0"], gy0 + y - raw["gy0"]
            if 0 <= lx < raw["W"] and 0 <= ly < raw["H"] and raw["liq"][ly, lx]:
                d = float(raw["depth"][ly, lx])
                lev[y + 1, x + 1] = WATER_ALPHA[1 if d < 0.8 else (2 if d < 2.0 else 3)]
    lev[0, :], lev[-1, :], lev[:, 0], lev[:, -1] = lev[1, :], lev[-2, :], lev[:, 1], lev[:, -2]
    c = (lev[:-1, :-1] + lev[1:, :-1] + lev[:-1, 1:] + lev[1:, 1:]) / 4          # (H+1, W+1)
    water = np.clip(np.rint(c / 0.95 * (Q - 1)), 0, Q - 1).astype(np.uint8)
    return {"corners": corners, "water": water, "box": (gx0, gx1, gy0, gy1)}


_RAMP = np.linspace(0, 1, PX, dtype=np.float32)


def build_tiles(layers):
    """-> (tiles: [PX x PX x 3 float], index (H, W) int): every distinct set of four corners drawn once."""
    corners, water = layers["corners"], layers["water"]
    gx0, gx1, gy0, gy1 = layers["box"]
    H, W = gy1 - gy0, gx1 - gx0
    water_tex = _water_tex()
    fx = _RAMP[None, :, None]
    fy = _RAMP[:, None, None]
    bil = [(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy]           # tl, tr, bl, br
    keys, tiles, index = {}, [], np.zeros((H, W), np.int64)
    empty = ()
    for y in range(H):
        for x in range(W):
            gx, gy = gx0 + x, gy0 + y
            cs = (corners.get((gx, gy), empty), corners.get((gx + 1, gy), empty),
                  corners.get((gx, gy + 1), empty), corners.get((gx + 1, gy + 1), empty))
            wv = (int(water[y, x]), int(water[y, x + 1]), int(water[y + 1, x]), int(water[y + 1, x + 1]))
            key = (cs, wv if any(wv) else None)
            i = keys.get(key)
            if i is None:
                acc = np.zeros((PX, PX, 3), np.float32)
                tot = np.zeros((PX, PX, 1), np.float32)
                weights = {}
                for k, corner in enumerate(cs):
                    for fid, lv in corner:
                        weights[fid] = weights.get(fid, 0) + bil[k] * (lv / (Q - 1))
                for fid, wgt in weights.items():
                    acc += tex16(fid) * wgt
                    tot += wgt
                img = acc / np.maximum(tot, 1e-4) if weights else np.full((PX, PX, 3), 0.3, np.float32)
                if key[1]:
                    wa = sum(bil[k] * (wv[k] / (Q - 1) * 0.95) for k in range(4))
                    img = img * (1 - wa) + water_tex * wa
                i = keys[key] = len(tiles)
                tiles.append(np.clip(img, 0, 1))
            index[y, x] = i
    return tiles, index


ROW = 1024 // PX            # tiles a row on a page


def write_pages(tiles, base_path, write_blp):
    """Tiles into 1024 x 1024 pages (ROW x ROW tiles each) as DXT1 BLPs: base_path + "_<n>.blp". -> page count"""
    per = ROW * ROW
    pages = (len(tiles) + per - 1) // per
    for p in range(pages):
        img = np.zeros((1024, 1024, 3), np.uint8)
        for k in range(per):
            i = p * per + k
            if i >= len(tiles):
                break
            r, c = divmod(k, ROW)
            img[r * PX:(r + 1) * PX, c * PX:(c + 1) * PX] = (tiles[i] * 255).astype(np.uint8)
        write_blp(Image.fromarray(img, "RGB"), "%s_%d.blp" % (base_path, p))
    return pages

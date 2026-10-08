"""Azeromon world, step 1: the real terrain of a block of ADTs as per-tile arrays (see adt_tools for the grid).

raw(X0, X1, Y0, Y1) -> dict of numpy arrays covering gx in [X0*128, (X1+1)*128), gy in [Y0*128, (Y1+1)*128):
    area   uint16  AreaTable ID of the tile's chunk
    tex    int32   the texture (FileDataID) showing most on the tile (blend weights summed over its 8x8 alpha pixels)
    tex2   int32   the runner-up texture, w2 float32 its share (0..1)
    z      float32 terrain height at the tile centre
    slope  float32 steepest slope across the tile, degrees
    liq    uint8   liquid type (LiquidType ID) where the liquid lies above the ground, else 0
    depth  float32 liquid surface minus ground at the tile centre
    hole   bool    a hole in the terrain (a WMO / cave sits there)
plus the doodads and WMOs placed on those ADTs (unique by placement ID), cached in dev/art/azw/raw_<box>.pickle."""
import math
import os
import pickle
import struct

import numpy as np

import adt_tools as A
import casc_local as C

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "art", "azw")
os.makedirs(OUT, exist_ok=True)


def _tile_arrays(t):
    n = 128
    area = np.zeros((n, n), np.uint16)
    tex = np.zeros((n, n), np.int32)
    tex2 = np.zeros((n, n), np.int32)
    w2 = np.zeros((n, n), np.float32)
    z = np.zeros((n, n), np.float32)
    slope = np.zeros((n, n), np.float32)
    liq = np.zeros((n, n), np.uint8)
    depth = np.zeros((n, n), np.float32)
    hole = np.zeros((n, n), bool)
    for (r, c), a in t.area.items():
        area[r * 8:r * 8 + 8, c * 8:c * 8 + 8] = a
        holes = t.holes[(r, c)]
        lay = t.layers.get((r, c), [])
        # per-layer weight per alpha pixel: layer i shows a_i * prod_{j>i} (1 - a_j)
        weights = []
        if lay:
            alphas = [np.ones((64, 64), np.float32) if al is None else np.array(al, np.float32).reshape(64, 64)
                      for _, al in lay]
            rest = np.ones((64, 64), np.float32)
            ws = [None] * len(lay)
            for i in range(len(lay) - 1, -1, -1):
                ws[i] = alphas[i] * rest
                rest = rest * (1 - alphas[i])
            weights = [w.reshape(8, 8, 8, 8).sum(axis=(1, 3)) for w in ws]     # -> per tile (ty, tx)
        for ty in range(8):
            for tx in range(8):
                gy, gx = r * 8 + ty, c * 8 + tx
                hole[gy, gx] = bool((holes >> (ty * 8 + tx)) & 1)
                if weights:
                    vals = sorted(((float(weights[i][ty, tx]), lay[i][0]) for i in range(len(lay))), reverse=True)
                    tot = sum(v for v, _ in vals) or 1
                    tex[gy, gx] = vals[0][1]
                    if len(vals) > 1:
                        tex2[gy, gx] = vals[1][1]
                        w2[gy, gx] = vals[1][0] / tot
                zc = t.height_at((r, c), tx + 0.5, ty + 0.5)
                z[gy, gx] = zc if zc is not None else 0
                if zc is not None:
                    # steepest of the four corner-to-corner drops (the tile is TS wide)
                    zs = [t.height_at((r, c), tx + a, ty + b) for a, b in ((0, 0), (1, 0), (0, 1), (1, 1))]
                    gxd = ((zs[1] - zs[0]) + (zs[3] - zs[2])) / 2
                    gyd = ((zs[2] - zs[0]) + (zs[3] - zs[1])) / 2
                    slope[gy, gx] = math.degrees(math.atan(math.hypot(gxd, gyd) / A.TS))
                cell = t.liquid.get((r, c), {}).get((tx, ty))
                if cell and zc is not None and cell[1] > zc:
                    liq[gy, gx] = cell[0]
                    depth[gy, gx] = cell[1] - zc
    return dict(area=area, tex=tex, tex2=tex2, w2=w2, z=z, slope=slope, liq=liq, depth=depth, hole=hole)


def raw(X0, X1, Y0, Y1, mapname="azeroth", rebuild=False):
    path = os.path.join(OUT, "raw_%s_%d_%d_%d_%d.pickle" % (mapname, X0, X1, Y0, Y1))
    if os.path.exists(path) and not rebuild:
        return pickle.load(open(path, "rb"))
    big = bool(A.wdt_flags(mapname) & 0x84)
    W, H = (X1 - X0 + 1) * 128, (Y1 - Y0 + 1) * 128
    out = dict(area=np.zeros((H, W), np.uint16), tex=np.zeros((H, W), np.int32), tex2=np.zeros((H, W), np.int32),
               w2=np.zeros((H, W), np.float32), z=np.zeros((H, W), np.float32), slope=np.zeros((H, W), np.float32),
               liq=np.zeros((H, W), np.uint8), depth=np.zeros((H, W), np.float32), hole=np.zeros((H, W), bool),
               present=np.zeros((H, W), bool))
    doodads, wmos = {}, {}
    for X in range(X0, X1 + 1):
        for Y in range(Y0, Y1 + 1):
            t = A.Tile(mapname, X, Y, big)
            if not t.ok:
                continue
            arr = _tile_arrays(t)
            sy, sx = (Y - Y0) * 128, (X - X0) * 128
            for k, v in arr.items():
                out[k][sy:sy + 128, sx:sx + 128] = v
            out["present"][sy:sy + 128, sx:sx + 128] = True
            for d in t.doodads:
                doodads[d[4]] = d
            for w in t.wmos:
                wmos[w[7]] = w
    out.update(gx0=X0 * 128, gy0=Y0 * 128, W=W, H=H, doodads=list(doodads.values()), wmos=list(wmos.values()),
               box=(X0, X1, Y0, Y1), mapname=mapname)
    pickle.dump(out, open(path, "wb"), protocol=pickle.HIGHEST_PROTOCOL)
    return out


_M2NAMES = {}


def m2_name(fid):
    """The model's own name from its MD20 header (e.g. 'ElwynnTreeCanopy04'); None if unreadable."""
    if fid in _M2NAMES:
        return _M2NAMES[fid]
    name = None
    try:
        d = C.read_fid(fid)
        off = 0
        if d[:4] == b"MD21":
            off = 8
        if d[off:off + 4] == b"MD20":
            n, o = struct.unpack_from("<2I", d, off + 8)
            name = d[off + o:off + o + n].split(b"\0")[0].decode("ascii", "replace")
    except Exception:
        pass
    _M2NAMES[fid] = name
    return name


def m2_box(fid):
    """(min xyz, max xyz) of the model's bounding box (header 0xA0) and its radius."""
    try:
        d = C.read_fid(fid)
        off = 8 if d[:4] == b"MD21" else 0
        box = struct.unpack_from("<6f", d, off + 0xA0)
        rad = struct.unpack_from("<f", d, off + 0xB8)[0]
        return box[:3], box[3:], rad
    except Exception:
        return None

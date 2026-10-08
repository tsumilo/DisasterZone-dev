"""Blizzard's outdoor terrain tiles (.adt, split into root / _tex0 / _obj0 in the 2.5.x client), read from the installed
client with casc_local. Used by gen_azeromon_world.py.

Grid used everywhere here (Azeromon's world grid): a TILE is one cell of an ADT chunk's 8x8 grid, TS = 533.333/128
yards. gx grows east, gy grows south, both from the map's north-west corner:
    gx = (MAP_HALF - world_y) / TS        gy = (MAP_HALF - world_x) / TS        (world x = north, y = west)
so ADT file <map>_<X>_<Y> covers gx in [X*128, X*128+128), gy in [Y*128, Y*128+128), and chunk (row r, col c) of it
covers 8x8 tiles from (X*128 + c*8, Y*128 + r*8). Placement coordinates (MDDF / MODF) are (gx*TS, z, gy*TS).

Chunk layouts (wowdev.wiki ADT/v18): MCNK header 128 bytes (flags 0, indexX 4, indexY 8, areaId 0x34, holes low-res
uint16 0x3C or high-res uint64 at 0x14 when flags & 0x10000, position 0x68 = world x, y, z); MCVT 145 heights
(rows of 9 outer + 8 inner vertices, relative to position z); MH2O header 256 x (ofs instances, count, ofs attributes);
liquid instance 24 bytes; MCLY 16 bytes (texture index, flags, MCAL offset, effect); MDDF 36 bytes; MODF 64 bytes.
"""
import struct

import casc_local as C

MAP_HALF = 17066.666666
ADT = 533.333333
CHUNK = ADT / 16
TS = ADT / 128           # yd per Azeromon tile (4.1667)


def chunks(d, start=0, end=None):
    pos, end = start, len(d) if end is None else end
    while pos + 8 <= end:
        name = d[pos:pos + 4][::-1].decode("ascii", "replace")
        size = struct.unpack_from("<I", d, pos + 4)[0]
        yield name, pos + 8, size
        pos += 8 + size


def read_file(path):
    fid = C.fdid_of(path)
    if fid is None:
        return None
    try:
        return C.read_fid(fid)
    except (KeyError, ValueError):
        return None


def wdt_flags(mapname):
    d = read_file("world/maps/%s/%s.wdt" % (mapname, mapname))
    for name, off, size in chunks(d):
        if name == "MPHD":
            return struct.unpack_from("<I", d, off)[0]
    return 0


def _alpha(d, off, flags, big, fix):
    """One layer's 64x64 alpha (0..1 floats, row-major) from MCAL."""
    out = [0.0] * 4096
    if flags & 0x200:                                  # compressed (RLE, 8 bit)
        i, p = 0, off
        while i < 4096:
            b = d[p]
            p += 1
            n = b & 0x7F
            if b & 0x80:                               # fill
                v = d[p] / 255.0
                p += 1
                for _ in range(n):
                    if i < 4096:
                        out[i] = v
                        i += 1
            else:
                for _ in range(n):
                    if i < 4096:
                        out[i] = d[p] / 255.0
                        i += 1
                    p += 1
        return out
    if big:
        for i in range(4096):
            out[i] = d[off + i] / 255.0
        return out
    for i in range(2048):                              # 4 bit, low nibble first
        b = d[off + i]
        out[2 * i] = (b & 0x0F) / 15.0
        out[2 * i + 1] = (b >> 4) / 15.0
    if fix:                                            # the 64th row / column repeat the 63rd
        for r in range(64):
            out[r * 64 + 63] = out[r * 64 + 62]
        for c in range(64):
            out[63 * 64 + c] = out[62 * 64 + c]
    return out


class Tile:
    """One ADT: per chunk (r, c): area, holes (64-bit, per 8x8 tile), heights (9x9 outer + 8x8 inner), base z,
    texture weights per tile, liquid per tile; doodads and WMOs placed on it."""

    def __init__(self, mapname, X, Y, big_alpha):
        self.X, self.Y = X, Y
        base = "world/maps/%s/%s_%d_%d" % (mapname, mapname, X, Y)
        root = read_file(base + ".adt")
        self.ok = root is not None
        if not self.ok:
            return
        tex = read_file(base + "_tex0.adt")
        obj = read_file(base + "_obj0.adt")
        self.area = {}
        self.holes = {}
        self.heights = {}
        self.basez = {}
        self.flags = {}
        self.layers = {}      # (r, c) -> [(texture fdid, alpha list or None)]
        self.liquid = {}      # (r, c) -> {(tx, ty): (type, height)}
        self.doodads = []     # (fdid, (px, py, pz), (rx, ry, rz), scale, uid)
        self.wmos = []        # (fdid, pos, rot, extents, flags, doodadSet, scale, uid)
        mcnk_i = 0
        mh2o = None
        for name, off, size in chunks(root):
            if name == "MCNK":
                h = root[off:off + 128]
                flags, ix, iy = struct.unpack_from("<3I", h, 0)
                area = struct.unpack_from("<I", h, 0x34)[0]
                if flags & 0x10000:
                    holes = struct.unpack_from("<Q", h, 0x14)[0]
                else:
                    lo = struct.unpack_from("<H", h, 0x3C)[0]
                    holes = 0
                    for b in range(16):                     # 4x4 low-res: each bit = 2x2 tiles
                        if lo & (1 << b):
                            br, bc = b // 4, b % 4
                            for dr in range(2):
                                for dc in range(2):
                                    rr, cc = br * 2 + dr, bc * 2 + dc
                                    holes |= 1 << (rr * 8 + cc)
                pos = struct.unpack_from("<3f", h, 0x68)
                key = (iy, ix)
                self.flags[key] = flags
                self.area[key] = area
                self.holes[key] = holes
                self.basez[key] = pos[2]
                self.pos = getattr(self, "pos", {})
                self.pos[key] = pos
                for sub, soff, ssize in chunks(root, off + 128, off + size):
                    if sub == "MCVT":
                        self.heights[key] = struct.unpack_from("<145f", root, soff)
                mcnk_i += 1
            elif name == "MH2O":
                mh2o = (off, size)
        if mh2o:
            self._read_mh2o(root, *mh2o)
        if tex:
            mdid = []
            for name, off, size in chunks(tex):
                if name == "MDID":
                    mdid = list(struct.unpack_from("<%dI" % (size // 4), tex, off))
            i = 0
            for name, off, size in chunks(tex):
                if name != "MCNK":
                    continue
                key = (i // 16, i % 16)
                i += 1
                mcly, mcal = [], None
                for sub, soff, ssize in chunks(tex, off, off + size):
                    if sub == "MCLY":
                        for k in range(ssize // 16):
                            mcly.append(struct.unpack_from("<IIIi", tex, soff + k * 16))
                    elif sub == "MCAL":
                        mcal = soff
                fix = not (self.flags.get(key, 0) & 0x8000)
                lay = []
                for k, (ti, lf, ao, eff) in enumerate(mcly):
                    fid = mdid[ti] if ti < len(mdid) else 0
                    if k == 0 or not (lf & 0x100) or mcal is None:
                        lay.append((fid, None))
                    else:
                        lay.append((fid, _alpha(tex, mcal + ao, lf, big_alpha, fix)))
                self.layers[key] = lay
        if obj:
            for name, off, size in chunks(obj):
                if name == "MDDF":
                    for k in range(size // 36):
                        nid, uid, px, py, pz, rx, ry, rz, sc, fl = struct.unpack_from("<2I6f2H", obj, off + k * 36)
                        if fl & 0x40:
                            self.doodads.append((nid, (px, py, pz), (rx, ry, rz), sc / 1024.0, uid))
                elif name == "MODF":
                    for k in range(size // 64):
                        v = struct.unpack_from("<2I3f3f6f4H", obj, off + k * 64)
                        nid, uid = v[0], v[1]
                        fl, dset, nset, sc = v[14], v[15], v[16], v[17]
                        if fl & 0x8:
                            self.wmos.append((nid, v[2:5], v[5:8], v[8:14], fl, dset, (sc / 1024.0) if fl & 0x4 else 1.0, uid))

    def _read_mh2o(self, d, base, size):
        for ci in range(256):
            oi, cnt, oa = struct.unpack_from("<3I", d, base + ci * 12)
            if not cnt or not oi:
                continue
            key = (ci // 16, ci % 16)
            cells = {}
            for li in range(cnt):
                io = base + oi + li * 24
                ltype, lvf, hmin, hmax, xo, yo, w, hh, oex, ovd = struct.unpack_from("<2H2f4B2I", d, io)
                exists = None
                if oex:
                    nbytes = (w * hh + 7) // 8
                    bits = int.from_bytes(d[base + oex:base + oex + nbytes], "little")
                    exists = bits
                heights = None
                if ovd and lvf in (0, 1, 3):
                    nv = (w + 1) * (hh + 1)
                    heights = struct.unpack_from("<%df" % nv, d, base + ovd)
                for ty in range(hh):
                    for tx in range(w):
                        bi = ty * w + tx
                        if exists is not None and not (exists >> bi) & 1:
                            continue
                        if heights:
                            vs = [heights[(ty + a) * (w + 1) + tx + b] for a in (0, 1) for b in (0, 1)]
                            z = sum(vs) / 4
                        else:
                            z = hmax
                        cells[(xo + tx, yo + ty)] = (ltype, z)
            if cells:
                self.liquid[key] = cells

    def height_at(self, key, fx, fy):
        """Terrain z inside chunk key at fractional cell position (fx, fy) in 0..8 (x east, y south)."""
        hts = self.heights.get(key)
        if hts is None:
            return None
        cx, cy = min(int(fx), 7), min(int(fy), 7)
        ux, uy = fx - cx, fy - cy
        def outer(r, c): return hts[r * 17 + c]
        def inner(r, c): return hts[r * 17 + 9 + c]
        a, b = outer(cy, cx), outer(cy, cx + 1)
        c_, d = outer(cy + 1, cx), outer(cy + 1, cx + 1)
        mid = inner(cy, cx)
        # the four triangles meeting at the inner vertex
        if uy <= ux and uy <= 1 - ux:      # north
            z = _tri(a, b, mid, ux, uy, (0, 0), (1, 0))
        elif ux >= uy and ux >= 1 - uy:    # east
            z = _tri(b, d, mid, ux, uy, (1, 0), (1, 1))
        elif uy >= ux and uy >= 1 - ux:    # south
            z = _tri(d, c_, mid, ux, uy, (1, 1), (0, 1))
        else:
            z = _tri(c_, a, mid, ux, uy, (0, 1), (0, 0))
        return self.basez[key] + z


def _tri(h1, h2, hm, ux, uy, p1, p2):
    """Barycentric z in the triangle p1, p2, centre (0.5, 0.5)."""
    x1, y1 = p1
    x2, y2 = p2
    x3, y3 = 0.5, 0.5
    det = (y2 - y3) * (x1 - x3) + (x3 - x2) * (y1 - y3)
    l1 = ((y2 - y3) * (ux - x3) + (x3 - x2) * (uy - y3)) / det
    l2 = ((y3 - y1) * (ux - x3) + (x1 - x3) * (uy - y3)) / det
    l3 = 1 - l1 - l2
    return l1 * h1 + l2 * h2 + l3 * hm

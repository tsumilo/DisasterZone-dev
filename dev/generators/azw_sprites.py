"""Overworld sprites for Azeromon's real creatures, rendered from the game's own models.

For a creature display: the .m2 (CreatureDisplayInfo.ModelID -> CreatureModelData.FileDataID) in its Stand pose
(m2_tools.standing_vertices), its first skin's triangles per submesh with the batch's texture (type 11/12/13 = the
display's TextureVariation 0/1/2, type 0 = the model's own TXID texture), drawn by a small z-buffered rasteriser:
orthographic, looking down at 45 degrees from the south, lit from the north-west, in the four facings the map
uses. The picture is cut to the creature, scaled down to SPRITE px (nearest the creature's real size: big ones
get two tiles), colour-reduced and outlined so it sits with the pixel-art characters.

render(display_id) -> {dir: PIL image} or None"""
import csv
import io
import math
import os
import struct

import numpy as np
from PIL import Image

import casc_local as C
import m2_tools as MT

HERE = os.path.dirname(os.path.abspath(__file__))
DB2 = os.path.join(HERE, "..", "art", "tbcdb", "db2")

_CDI = _CMD = None


def _tables():
    global _CDI, _CMD
    if _CDI is None:
        with open(os.path.join(DB2, "CreatureDisplayInfo.csv"), encoding="utf-8") as f:
            _CDI = {int(r["ID"]): r for r in csv.DictReader(f)}
        with open(os.path.join(DB2, "CreatureModelData.csv"), encoding="utf-8") as f:
            _CMD = {int(r["ID"]): r for r in csv.DictReader(f)}
    return _CDI, _CMD


def _arr(b, off):
    return struct.unpack_from("<2I", b, off)


def _chunks(data):
    out, i = {}, 0
    if data[:4] != b"MD21":
        return out
    while i + 8 <= len(data):
        tag, size = data[i:i + 4].decode("ascii", "replace"), struct.unpack_from("<I", data, i + 4)[0]
        out[tag] = (i + 8, size)
        i += 8 + size
    return out


_TEX = {}


def _texture(fid):
    if fid in _TEX:
        return _TEX[fid]
    try:
        im = Image.open(io.BytesIO(C.read_fid(fid))).convert("RGBA")
        arr = np.asarray(im, dtype=np.float32) / 255.0
    except Exception:
        arr = None
    _TEX[fid] = arr
    return arr


def load_model(display_id):
    cdi, cmd = _tables()
    d = cdi.get(display_id)
    if not d:
        return None
    if int(d["ExtendedDisplayInfoID"] or 0):
        return None              # a dressed character model (Defias, guards): the map's human sprites draw those
    md = cmd.get(int(d["ModelID"]))
    if not md:
        return None
    data = C.read_fid(int(md["FileDataID"]))
    ch = _chunks(data)
    md20 = data[8:] if data[:4] == b"MD21" else data
    verts, box = MT.standing_vertices(data)
    nv, ov = _arr(md20, 0x3C)
    uvs = [struct.unpack_from("<2f", md20, ov + i * 48 + 32) for i in range(nv)]
    # textures
    ntex, otex = _arr(md20, 0x50)
    types = [struct.unpack_from("<I", md20, otex + i * 16)[0] for i in range(ntex)]
    txid = []
    if "TXID" in ch:
        o, s = ch["TXID"]
        txid = list(struct.unpack_from("<%dI" % (s // 4), data, o))
    var = [int(d["TextureVariationFileDataID_%d" % i]) for i in range(3)]
    tex_fids = []
    for i, t in enumerate(types):
        if t == 0:
            tex_fids.append(txid[i] if i < len(txid) else 0)
        elif t in (11, 12, 13):
            tex_fids.append(var[t - 11])
        else:
            tex_fids.append(0)
    nlook, olook = _arr(md20, 0x80)
    tex_lookup = [struct.unpack_from("<H", md20, olook + i * 2)[0] for i in range(nlook)]
    skins = MT.skin_ids(data)
    if not skins:
        return None
    skin = C.read_fid(skins[0])
    nlook_v, olook_v, nidx, oidx = struct.unpack_from("<4I", skin, 4)
    vlook = struct.unpack_from("<%dH" % nlook_v, skin, olook_v)
    idx = struct.unpack_from("<%dH" % nidx, skin, oidx)
    nsub, osub = struct.unpack_from("<2I", skin, 28)
    nbat, obat = struct.unpack_from("<2I", skin, 36)
    subs = []
    for i in range(nsub):
        so = osub + i * 48
        sid, lvl, vstart, vcount, istart, icount = struct.unpack_from("<6H", skin, so)
        istart += lvl << 16
        subs.append((sid, istart, icount))
    sub_tex = {}
    for i in range(nbat):
        bo = obat + i * 24
        sub_i = struct.unpack_from("<H", skin, bo + 4)[0]
        combo = struct.unpack_from("<H", skin, bo + 16)[0]
        if sub_i not in sub_tex and combo < len(tex_lookup):
            ti = tex_lookup[combo]
            if ti < len(tex_fids) and tex_fids[ti]:
                sub_tex[sub_i] = tex_fids[ti]
    tris = []
    for si, (sid, istart, icount) in enumerate(subs):
        # base geosets and the first variant of each group (the rest are alternative pieces)
        if not (sid == 0 or sid % 100 == 1 or sid < 100):
            continue
        tf = sub_tex.get(si)
        if not tf:
            continue
        for k in range(istart, istart + icount - 2, 3):
            tris.append((vlook[idx[k]], vlook[idx[k + 1]], vlook[idx[k + 2]], tf))
    return {"verts": np.array(verts, dtype=np.float32), "uvs": np.array(uvs, dtype=np.float32), "tris": tris,
            "scale": float(d["CreatureModelScale"] or 1)}


FACING_YAW = {"down": -math.pi / 2, "up": math.pi / 2, "left": math.pi, "right": 0.0}
PITCH = math.radians(24)          # how far the camera looks down (Pokemon-like: mostly from the side)


def _project(verts, yaw):
    """Model (x forward, y left, z up) turned by yaw, seen from the south and above: -> screen x (right), y (down),
    depth (bigger = nearer)."""
    c, s = math.cos(yaw), math.sin(yaw)
    x = verts[:, 0] * c - verts[:, 1] * s
    y = verts[:, 0] * s + verts[:, 1] * c
    z = verts[:, 2]
    # world: x east? we treat model x after yaw as east (right), y as north. Facing "down" = south = -y.
    east, north = y * -1.0, x
    east, north = x, y
    sx = east
    cp, sp = math.cos(PITCH), math.sin(PITCH)
    sy = -(z * cp + north * sp)
    depth = -north * cp + z * sp
    return sx, sy, depth


def _raster(m, yaw, res):
    verts, uvs = m["verts"], m["uvs"]
    sx, sy, dep = _project(verts, yaw)
    x0, x1, y0, y1 = sx.min(), sx.max(), sy.min(), sy.max()
    span = max(x1 - x0, y1 - y0) or 1
    k = (res - 4) / span
    px = (sx - x0) * k + 2 + ((res - 4) - (x1 - x0) * k) / 2
    py = (sy - y0) * k + 2 + ((res - 4) - (y1 - y0) * k)          # standing on the bottom
    img = np.zeros((res, res, 4), np.float32)
    zbuf = np.full((res, res), -1e9, np.float32)
    # light from the north-west, above
    L = np.array([-0.5, 0.5, 0.7])
    L /= np.linalg.norm(L)
    for a, b, cc, tf in m["tris"]:
        tex = _texture(tf)
        xa, ya, xb, yb, xc, yc = px[a], py[a], px[b], py[b], px[cc], py[cc]
        minx, maxx = int(max(0, math.floor(min(xa, xb, xc)))), int(min(res - 1, math.ceil(max(xa, xb, xc))))
        miny, maxy = int(max(0, math.floor(min(ya, yb, yc)))), int(min(res - 1, math.ceil(max(ya, yb, yc))))
        if maxx < minx or maxy < miny:
            continue
        det = (yb - yc) * (xa - xc) + (xc - xb) * (ya - yc)
        if abs(det) < 1e-9:
            continue
        # face normal (model space after yaw) for a simple light
        va, vb, vc = verts[a], verts[b], verts[cc]
        n = np.cross(vb - va, vc - va)
        ln = np.linalg.norm(n) or 1
        cy_, sy_ = math.cos(yaw), math.sin(yaw)
        nx, ny = n[0] * cy_ - n[1] * sy_, n[0] * sy_ + n[1] * cy_
        light = abs(np.dot(np.array([nx, ny, n[2]]) / ln, L))
        shade = 0.78 + 0.32 * light
        gx, gy = np.meshgrid(np.arange(minx, maxx + 1) + 0.5, np.arange(miny, maxy + 1) + 0.5)
        l0 = ((yb - yc) * (gx - xc) + (xc - xb) * (gy - yc)) / det
        l1 = ((yc - ya) * (gx - xc) + (xa - xc) * (gy - yc)) / det
        l2 = 1 - l0 - l1
        inside = (l0 >= -0.01) & (l1 >= -0.01) & (l2 >= -0.01)
        if not inside.any():
            continue
        z = l0 * dep[a] + l1 * dep[b] + l2 * dep[cc]
        zb = zbuf[miny:maxy + 1, minx:maxx + 1]
        win = inside & (z > zb)
        if not win.any():
            continue
        if tex is not None:
            u = l0 * uvs[a, 0] + l1 * uvs[b, 0] + l2 * uvs[cc, 0]
            v = l0 * uvs[a, 1] + l1 * uvs[b, 1] + l2 * uvs[cc, 1]
            th, tw = tex.shape[:2]
            tx = (np.mod(u, 1.0) * tw).astype(int).clip(0, tw - 1)
            ty = (np.mod(v, 1.0) * th).astype(int).clip(0, th - 1)
            col = tex[ty, tx]
            alpha_ok = col[..., 3] > 0.3
            win = win & alpha_ok
            rgb = col[..., :3] * shade
        else:
            rgb = np.full(z.shape + (3,), 0.5) * shade
        sub = img[miny:maxy + 1, minx:maxx + 1]
        sub[win, :3] = np.clip(rgb[win], 0, 1)
        sub[win, 3] = 1
        zb[win] = z[win]
    return img


def _pixelate(img, size):
    """Big render -> size x size sprite: box-filter colours where covered, then a dark outline."""
    res = img.shape[0]
    f = res // size
    a = img[..., 3].reshape(size, f, size, f)
    rgb = img[..., :3].reshape(size, f, size, f, 3)
    cov = a.mean(axis=(1, 3))
    wsum = a.sum(axis=(1, 3))[..., None]
    col = (rgb * a[..., None]).sum(axis=(1, 3)) / np.maximum(wsum, 1e-6)
    out = np.zeros((size, size, 4), np.uint8)
    on = cov >= 0.35
    out[on, :3] = (np.clip(col[on] * 1.08, 0, 1) * 255).astype(np.uint8)
    out[on, 3] = 255
    # outline: transparent pixels next to the sprite become dark
    edge = np.zeros_like(on)
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        edge |= np.roll(np.roll(on, dy, 0), dx, 1)
    edge &= ~on
    out[edge] = (34, 26, 22, 255)
    im = Image.fromarray(out, "RGBA")
    # fewer colours (keeps the outline)
    q = im.convert("RGB").quantize(10, method=Image.Quantize.MEDIANCUT).convert("RGB")
    q.putalpha(im.getchannel("A"))
    return q


def render(display_id, size=16, res=128):
    m = load_model(display_id)
    if not m or not m["tris"]:
        return None
    out = {}
    for face, yaw in FACING_YAW.items():
        out[face] = _pixelate(_raster(m, yaw, res), size)
    return out

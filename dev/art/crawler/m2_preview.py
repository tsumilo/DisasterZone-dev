"""Blizzard models (.m2) for the Portal previews (hub_paint.py): a model file or a creature display as triangles in its
Stand pose with their textures, rasterized z-buffered into a picture through the preview's camera.

Read from the installed client (casc_local):
  .m2 (MD21 chunks: MD20 data, SFID skins, TXID texture file IDs): vertices (48 bytes: position 0, uv 32), textures at
  0x50 (16 bytes: type uint32 - 0 a file, 11..13 the creature's skins), materials at 0x70 (flags, blend uint16),
  texture lookup at 0x80; the Stand pose from m2_tools.standing_vertices.
  .skin: vertex lookup 4, indices 12, sections 28 (48 bytes: vertexStart 4, vertexCount 6, indexStart 8 + level 2 *
  65536, indexCount 10), batches 36 (24 bytes: section index 4, material 10, texture count 14, texture combo 16).
  creature displays: tbcdb/db2 CreatureDisplayInfo.csv (ModelID, CreatureModelScale, CreatureModelAlpha,
  TextureVariationFileDataID_0..2) -> CreatureModelData.csv (FileDataID).
Blend modes: 0 opaque, 1 alpha key (texel alpha < 0.5 dropped), 2+ blended (drawn at half strength, no depth write).
Particles, ribbons and animation beyond the first Stand frame are not drawn.
"""
import csv, io, math, os, struct, sys
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(DEV, "generators"))
import casc_local as CASC  # noqa: E402
import m2_tools as M2  # noqa: E402

DB2 = os.path.join(DEV, "art", "tbcdb", "db2")
_MODELS, _TEX, _CDI, _CMD = {}, {}, None, None


def _arr(b, off):
    return struct.unpack_from("<2I", b, off)


def _chunks(data):
    out, i = {}, 0
    while i + 8 <= len(data):
        tag, size = data[i:i + 4], struct.unpack_from("<I", data, i + 4)[0]
        out[tag] = (i + 8, size)
        i += 8 + size
    return out


def texture(fid):
    if fid not in _TEX:
        try:
            _TEX[fid] = np.asarray(Image.open(io.BytesIO(CASC.read_fid(int(fid)))).convert("RGBA"), np.float32) / 255
        except Exception:
            _TEX[fid] = None
    return _TEX[fid]


def display(display_id):
    """-> (model file ID, scale, alpha 0..1, skin texture IDs [3])."""
    global _CDI, _CMD
    if _CDI is None:
        _CDI = {r["ID"]: r for r in csv.DictReader(open(os.path.join(DB2, "CreatureDisplayInfo.csv"), encoding="utf-8"))}
        _CMD = {r["ID"]: r for r in csv.DictReader(open(os.path.join(DB2, "CreatureModelData.csv"), encoding="utf-8"))}
    r = _CDI[str(display_id)]
    md = _CMD[r["ModelID"]]
    skins = [int(r["TextureVariationFileDataID_%d" % k] or 0) for k in range(3)]
    return int(md["FileDataID"]), float(r["CreatureModelScale"] or 1), int(r["CreatureModelAlpha"] or 255) / 255, skins


def model(fid, skins=(0, 0, 0)):
    """-> dict(V (n, 3), UV (n, 2), N (n, 3) normals, parts [(tri index array (k, 3), texture RGBA array or None,
    blend, texture file ID)])."""
    key = (fid, tuple(skins))
    if key in _MODELS:
        return _MODELS[key]
    data = CASC.read_fid(int(fid))
    ch = _chunks(data) if data[:4] == b"MD21" else {}
    md = data[8:] if data[:4] == b"MD21" else data
    vs, _box = M2.standing_vertices(data)
    V = np.array(vs, np.float64).reshape(-1, 3)
    nv, ov = _arr(md, 0x3C)
    if nv == 0:                                         # (a model of particles only: nothing to draw here)
        _MODELS[key] = dict(V=V, UV=np.zeros((0, 2)), N=np.zeros((0, 3)), parts=[])
        return _MODELS[key]
    UV = np.array([struct.unpack_from("<2f", md, ov + k * 48 + 32) for k in range(nv)], np.float64)
    NRM = np.array([struct.unpack_from("<3f", md, ov + k * 48 + 20) for k in range(nv)], np.float64)
    ntex, otex = _arr(md, 0x50)
    ttypes = [struct.unpack_from("<I", md, otex + k * 16)[0] for k in range(ntex)]
    txid = []
    if b"TXID" in ch:
        o, s = ch[b"TXID"]
        txid = list(struct.unpack_from("<%dI" % (s // 4), data, o))
    nmat, omat = _arr(md, 0x70)
    mats = [struct.unpack_from("<2H", md, omat + k * 4) for k in range(nmat)]
    nlook, olook = _arr(md, 0x80)
    tlook = list(struct.unpack_from("<%dH" % nlook, md, olook)) if nlook else []
    sids = M2.skin_ids(data)
    skin = CASC.read_fid(sids[0])
    nvl, ovl, nidx, oidx = struct.unpack_from("<4I", skin, 4)
    look = np.array(struct.unpack_from("<%dH" % nvl, skin, ovl), np.int64)
    idx = np.array(struct.unpack_from("<%dH" % nidx, skin, oidx), np.int64)
    nsec, osec = _arr(skin, 28)
    nbat, obat = _arr(skin, 36)
    secs = []
    for k in range(nsec):
        level = struct.unpack_from("<H", skin, osec + k * 48 + 2)[0]
        istart, icount = struct.unpack_from("<2H", skin, osec + k * 48 + 8)
        secs.append((istart + level * 65536, icount))
    parts = []
    seen = set()
    for k in range(nbat):
        b = osec  # (unused)
        sec, = struct.unpack_from("<H", skin, obat + k * 24 + 4)
        mat, = struct.unpack_from("<H", skin, obat + k * 24 + 10)
        combo, = struct.unpack_from("<H", skin, obat + k * 24 + 16)
        if (sec, combo) in seen or sec >= len(secs):
            continue
        seen.add((sec, combo))
        istart, icount = secs[sec]
        tri = look[idx[istart:istart + icount]].reshape(-1, 3)
        ti = tlook[combo] if combo < len(tlook) else 0
        tt = ttypes[ti] if ti < len(ttypes) else 0
        tfid = txid[ti] if tt == 0 and ti < len(txid) else (skins[tt - 11] if 11 <= tt <= 13 else 0)
        blend = mats[mat][1] if mat < len(mats) else 0
        parts.append((tri, texture(tfid) if tfid else None, blend, tfid))
    out = dict(V=V, UV=UV, N=NRM, parts=parts)
    _MODELS[key] = out
    return out


def draw(img, zb, cam, mdl, pos, yaw, scale, view_h, alpha=1.0, light=1.0):
    """Rasterizes a model into img (H, W, 3) with the depth buffer zb (H, W): model space turned by yaw about z,
    times scale, moved to pos (scene coordinates); cam: render_check.Camera (project -> view units, y up)."""
    c, s = math.cos(yaw), math.sin(yaw)
    V = mdl["V"] * scale
    P = np.stack([V[:, 0] * c - V[:, 1] * s + pos[0], V[:, 0] * s + V[:, 1] * c + pos[1], V[:, 2] + pos[2]], 1)
    sx, sy, d = cam.project(P.T) if False else _proj(cam, P)
    H, W = zb.shape
    UV = mdl["UV"]
    for part in mdl["parts"]:
        tri, tex, blend = part[0], part[1], part[2]
        for a, b, cc in tri:
            if d[a] < 0.3 or d[b] < 0.3 or d[cc] < 0.3:
                continue
            xs = np.array([sx[a], sx[b], sx[cc]])
            ys = np.array([view_h - sy[a], view_h - sy[b], view_h - sy[cc]])
            x0, x1 = max(0, int(xs.min())), min(W - 1, int(xs.max()) + 1)
            y0, y1 = max(0, int(ys.min())), min(H - 1, int(ys.max()) + 1)
            if x0 > x1 or y0 > y1:
                continue
            den = (ys[1] - ys[2]) * (xs[0] - xs[2]) + (xs[2] - xs[1]) * (ys[0] - ys[2])
            if abs(den) < 1e-9:
                continue
            gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
            l0 = ((ys[1] - ys[2]) * (gx - xs[2]) + (xs[2] - xs[1]) * (gy - ys[2])) / den
            l1 = ((ys[2] - ys[0]) * (gx - xs[2]) + (xs[0] - xs[2]) * (gy - ys[2])) / den
            l2 = 1 - l0 - l1
            inside = (l0 >= 0) & (l1 >= 0) & (l2 >= 0)
            if not inside.any():
                continue
            w0, w1, w2 = l0 / d[a], l1 / d[b], l2 / d[cc]
            ws = w0 + w1 + w2
            depth = 1 / ws
            sub = zb[y0:y1 + 1, x0:x1 + 1]
            ok = inside & (depth < sub)
            if not ok.any():
                continue
            u = (w0 * UV[a, 0] + w1 * UV[b, 0] + w2 * UV[cc, 0]) / ws
            v = (w0 * UV[a, 1] + w1 * UV[b, 1] + w2 * UV[cc, 1]) / ws
            if tex is not None:
                th, tw = tex.shape[:2]
                col = tex[(np.floor(v * th).astype(int) % th), (np.floor(u * tw).astype(int) % tw)]
            else:
                col = np.full(u.shape + (4,), 0.6, np.float32)
            if blend == 1:
                ok = ok & (col[..., 3] >= 0.5)
            reg = img[y0:y1 + 1, x0:x1 + 1]
            rgb = col[..., :3] * light
            if blend >= 2:
                k = 0.5 * alpha
                reg[ok] = reg[ok] * (1 - k) + rgb[ok] * k
                continue
            if alpha < 0.99:
                reg[ok] = reg[ok] * (1 - alpha) + rgb[ok] * alpha
            else:
                reg[ok] = rgb[ok]
            sub[ok] = depth[ok]


def _proj(cam, P):
    D = P - cam.C
    r, u, d = D @ cam.R, D @ cam.U, D @ cam.F
    with np.errstate(divide="ignore", invalid="ignore"):
        return cam.cx + cam.f * r / d, cam.cy + cam.f * u / d, d

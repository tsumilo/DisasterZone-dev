"""Azeromon world: a small software renderer for WoW models (M2 doodads / creatures, WMO buildings) -> pixel sprites.

mesh = { "verts": (N, 3) float32 yards (x forward/north, y left/west, z up, in the model's own frame),
         "uvs": (N, 2), "tris": [(a, b, c, texture FileDataID or 0)], "colors": optional per-tri RGB }
render(mesh, yaw, elev, px_per_yd, oversample) -> (RGBA uint8 image, origin (x, y) in its pixels)

Orthographic, the model turned by `yaw` (radians, WoW facing: 0 = the model's front points north on the map),
seen from the south at `elev` degrees above the horizon (90 = straight down: lines up with the top-down ground;
lower = more from the side). Lit from the north-west and above. Drawn `oversample` times larger, then box-filtered
down: a pixel shows where at least ~40% of it is covered. The origin is where the model's (0, 0, 0) lands - the
spot it stands on - so the game can put it on its tile."""
import io
import math
import struct

import numpy as np
from PIL import Image

import casc_local as C

_TEX = {}


def register_texture(key, arr):
    """A texture made here (a character's composed skin) under a key a triangle can name."""
    _TEX[key] = arr


def open_blp(data):
    """A BLP2 as RGBA. Palettised ones (compression 1) keep their alpha in a plane after the indices (8, 4 or 1
    bits a pixel; 0 = opaque) - Pillow takes it from the palette instead and gets 0, so they are read here."""
    if data[:4] == b"BLP2" and data[8] == 1:
        depth = data[9]
        w, h = struct.unpack_from("<II", data, 12)
        off = struct.unpack_from("<I", data, 20)[0]
        pal = np.frombuffer(data, np.uint8, 1024, 148).reshape(256, 4)[:, [2, 1, 0]]       # BGRA -> RGB
        idx = np.frombuffer(data, np.uint8, w * h, off)
        rgb = pal[idx].reshape(h, w, 3)
        a0 = off + w * h
        if depth == 8:
            alpha = np.frombuffer(data, np.uint8, w * h, a0).reshape(h, w)
        elif depth == 4:
            b = np.frombuffer(data, np.uint8, (w * h + 1) // 2, a0)
            alpha = (np.stack([b & 15, b >> 4], 1).reshape(-1)[:w * h] * 17).astype(np.uint8).reshape(h, w)
        elif depth == 1:
            b = np.frombuffer(data, np.uint8, (w * h + 7) // 8, a0)
            alpha = (np.unpackbits(b, bitorder="little")[:w * h] * 255).astype(np.uint8).reshape(h, w)
        else:
            alpha = np.full((h, w), 255, np.uint8)
        return Image.fromarray(np.dstack([rgb, alpha]).astype(np.uint8), "RGBA")
    im = Image.open(io.BytesIO(data)).convert("RGBA")
    if data[:4] == b"BLP2" and data[9] == 0:
        im.putalpha(255)                 # (stored without alpha: opaque)
    return im


def texture(fid):
    if not fid:
        return None
    if fid in _TEX:
        return _TEX[fid]
    try:
        im = open_blp(C.read_fid(fid))
        arr = np.asarray(im, dtype=np.float32) / 255.0
    except Exception:
        arr = None
    _TEX[fid] = arr
    return arr


LIGHT = np.array([-0.45, 0.55, 0.70], np.float64)       # (east, north, up): from the north-west, above
LIGHT /= np.linalg.norm(LIGHT)


DOWN_FACING = -0.35        # drop_down: faces whose normal points this far down are ceilings
OBLIQUE = 0.6              # elev = None: oblique view - the ground plan as on the map, heights drawn upwards at this


def _transform(verts, yaw, elev):
    """Model frame -> map (east, north, up) -> screen (x right, y down, depth toward the viewer). elev None: the
    oblique view classic top-down games use (the ground lines up with the tile grid exactly, tall things lean
    up the screen); a number: a true camera that many degrees above the horizon."""
    c, s = math.cos(yaw), math.sin(yaw)
    fx, fy, z = verts[:, 0], verts[:, 1], verts[:, 2]
    # model x (forward) points north when yaw = 0; model y (left) points west
    north = fx * c - fy * s
    west = fx * s + fy * c
    east = -west
    if elev is None:
        # along a view ray north + OBLIQUE * z is constant and the higher point is the nearer one
        return np.stack([east, north, z], 1), east, -(north + OBLIQUE * z), z
    ce, se = math.cos(math.radians(elev)), math.sin(math.radians(elev))
    sx = east
    sy = -(north * se + z * ce)
    depth = z * se - north * ce
    return np.stack([east, north, z], 1), sx, sy, depth


def render(mesh, yaw, elev, px_per_yd, oversample=4, alpha_test=0.35, ambient=0.62, diffuse=0.48, clip_z=None,
           drop_down=False, aux_floor_z=None, aux_floor_tol=0.9, drop_tris=None):
    """-> (RGBA uint8 image, origin pixel). aux_floor_z (a model-frame height, oblique view only): also returns a
    third value {"north": per-pixel map north (yd) of the surface seen, "floor": per-pixel bool - an upward face
    within a step of that height, "height": yd above that height}, for cutting a picture into depth slices."""
    verts = np.asarray(mesh["verts"], np.float64)
    uvs = np.asarray(mesh["uvs"], np.float64)
    if len(verts) == 0 or not mesh["tris"]:
        return None, (0, 0)
    world, sx, sy, dep = _transform(verts, yaw, elev)
    k = px_per_yd * oversample
    tri_idx = np.array([t[:3] for t in mesh["tris"]], np.int64)
    used = np.unique(tri_idx)
    x0, x1 = sx[used].min(), sx[used].max()
    y0, y1 = sy[used].min(), sy[used].max()
    x0, y0 = min(x0, 0.0), min(y0, 0.0)            # (keep the origin inside the picture)
    x1, y1 = max(x1, 0.0), max(y1, 0.0)
    pad = 2 * oversample
    W = int(math.ceil((x1 - x0) * k)) + 2 * pad
    H = int(math.ceil((y1 - y0) * k)) + 2 * pad
    W += (-W) % oversample
    H += (-H) % oversample
    if W * H > 6000 * 6000:
        raise ValueError("model too big to render")
    px = (sx - x0) * k + pad
    py = (sy - y0) * k + pad
    img = np.zeros((H, W, 4), np.float32)
    zbuf = np.full((H, W), -1e18, np.float64)
    want_aux = aux_floor_z is not None
    if want_aux:
        nbuf = np.zeros((H, W), np.float64)
        hbuf = np.zeros((H, W), np.float64)
        fbuf = np.zeros((H, W), bool)
    for ti, t in enumerate(mesh["tris"]):
        if drop_tris is not None and ti in drop_tris:
            continue                     # (cut away by the caller: a mine's roof over its tunnel)
        a, b, cc, tf = t[0], t[1], t[2], t[3]
        if clip_z is not None and min(verts[a, 2], verts[b, 2], verts[cc, 2]) > clip_z:
            continue                     # (an interior: ceilings and the floors above taken off)
        tex = texture(tf)
        xa, ya, xb, yb, xc, yc = px[a], py[a], px[b], py[b], px[cc], py[cc]
        minx, maxx = int(max(0, math.floor(min(xa, xb, xc)))), int(min(W - 1, math.ceil(max(xa, xb, xc))))
        miny, maxy = int(max(0, math.floor(min(ya, yb, yc)))), int(min(H - 1, math.ceil(max(ya, yb, yc))))
        if maxx < minx or maxy < miny:
            continue
        det = (yb - yc) * (xa - xc) + (xc - xb) * (ya - yc)
        if abs(det) < 1e-12:
            continue
        n = np.cross(world[b] - world[a], world[cc] - world[a])
        ln = np.linalg.norm(n)
        if ln < 1e-12:
            continue
        n = n / ln
        if drop_down and n[2] < DOWN_FACING:
            continue                     # (a cave's ceiling: it faces down, into the tunnel)
        if n[2] < 0:
            n = -n                      # (two-sided: leaves, cloth)
        shade = ambient + diffuse * max(0.0, float(np.dot(n, LIGHT)))
        gx, gy = np.meshgrid(np.arange(minx, maxx + 1) + 0.5, np.arange(miny, maxy + 1) + 0.5)
        l0 = ((yb - yc) * (gx - xc) + (xc - xb) * (gy - yc)) / det
        l1 = ((yc - ya) * (gx - xc) + (xa - xc) * (gy - yc)) / det
        l2 = 1 - l0 - l1
        inside = (l0 >= -1e-6) & (l1 >= -1e-6) & (l2 >= -1e-6)
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
            tx = (np.mod(u, 1.0) * tw).astype(np.int64).clip(0, tw - 1)
            ty = (np.mod(v, 1.0) * th).astype(np.int64).clip(0, th - 1)
            col = tex[ty, tx]
            win = win & (col[..., 3] > alpha_test) if len(t) < 5 or not t[4] else win
            rgb = col[..., :3] * shade
        else:
            base = np.array(mesh.get("colors", {}).get(tf, (0.5, 0.5, 0.5)))
            rgb = np.broadcast_to(base * shade, z.shape + (3,))
        if not win.any():
            continue
        sub = img[miny:maxy + 1, minx:maxx + 1]
        sub[win, :3] = np.clip(rgb[win], 0, 1)
        sub[win, 3] = 1
        zb[win] = z[win]
        if want_aux:
            nb = nbuf[miny:maxy + 1, minx:maxx + 1]
            nb[win] = (l0 * world[a, 1] + l1 * world[b, 1] + l2 * world[cc, 1])[win]
            up = float(np.dot(np.cross(world[b] - world[a], world[cc] - world[a]) / ln, (0, 0, 1)))
            zw = l0 * world[a, 2] + l1 * world[b, 2] + l2 * world[cc, 2]
            fbuf[miny:maxy + 1, minx:maxx + 1][win] = (abs(up) >= 0.75) & (np.abs(zw - aux_floor_z) < aux_floor_tol)[win]
            hbuf[miny:maxy + 1, minx:maxx + 1][win] = (zw - aux_floor_z)[win]
    # down to pixel size
    h, w = H // oversample, W // oversample
    a = img[..., 3].reshape(h, oversample, w, oversample)
    rgb = img[..., :3].reshape(h, oversample, w, oversample, 3)
    cov = a.mean(axis=(1, 3))
    wsum = a.sum(axis=(1, 3))[..., None]
    col = (rgb * a[..., None]).sum(axis=(1, 3)) / np.maximum(wsum, 1e-6)
    out = np.zeros((h, w, 4), np.uint8)
    on = cov >= 0.4
    out[on, :3] = (np.clip(col[on], 0, 1) * 255).astype(np.uint8)
    out[on, 3] = 255
    ox = (0 - x0) * px_per_yd + pad / oversample
    oy = (0 - y0) * px_per_yd + pad / oversample
    if want_aux:
        # per output pixel: the mean north of its covered samples; a floor when most of them are floor
        cnt = np.maximum(wsum[..., 0], 1e-6)
        north = (nbuf.reshape(h, oversample, w, oversample) * a).sum(axis=(1, 3)) / cnt
        floor = (fbuf.reshape(h, oversample, w, oversample) * a).sum(axis=(1, 3)) * 2 > cnt
        height = (hbuf.reshape(h, oversample, w, oversample) * a).sum(axis=(1, 3)) / cnt
        return out, (ox, oy), {"north": north, "floor": floor, "height": height}
    return out, (ox, oy)


def outline(img, color=(30, 24, 20, 255)):
    """A one-pixel dark outline around a sprite (the pixel-art characters have one)."""
    on = img[..., 3] > 0
    edge = np.zeros_like(on)
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        edge |= np.roll(np.roll(on, dy, 0), dx, 1)
    edge &= ~on
    out = img.copy()
    out[edge] = color
    return out


def trim(img, origin):
    """Crop to the opaque pixels; -> (img, origin)."""
    ys, xs = np.nonzero(img[..., 3])
    if len(xs) == 0:
        return img[:1, :1], origin
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    return img[y0:y1, x0:x1], (origin[0] - x0, origin[1] - y0)


# ---------------------------------------------------------------------------------------------------------------
# Mesh loaders
# ---------------------------------------------------------------------------------------------------------------
import struct  # noqa: E402

import m2_tools as MT  # noqa: E402


def _arr(b, off):
    return struct.unpack_from("<2I", b, off)


def _m2_chunks(data):
    out, i = {}, 0
    if data[:4] != b"MD21":
        return out
    while i + 8 <= len(data):
        tag, size = data[i:i + 4].decode("ascii", "replace"), struct.unpack_from("<I", data, i + 4)[0]
        out[tag] = (i + 8, size)
        i += 8 + size
    return out


_M2 = {}


def m2_mesh(fid, variations=(0, 0, 0), geoset_ok=None):
    """An .m2's Stand pose with its textures. variations: the creature display's TextureVariation file IDs (texture
    types 11 / 12 / 13). geoset_ok(id) -> bool picks submeshes (default: base and first variants)."""
    key = (fid, tuple(variations)) if geoset_ok is None else None     # (a picked set of pieces: not cached)
    if key is not None and key in _M2:
        return _M2[key]
    data = C.read_fid(fid)
    ch = _m2_chunks(data)
    md = data[8:] if data[:4] == b"MD21" else data
    verts, box = MT.standing_vertices(data)
    nv, ov = _arr(md, 0x3C)
    uvs = [struct.unpack_from("<2f", md, ov + i * 48 + 32) for i in range(nv)]
    ntex, otex = _arr(md, 0x50)
    types = [struct.unpack_from("<I", md, otex + i * 16)[0] for i in range(ntex)]
    txid = []
    if "TXID" in ch:
        o, s = ch["TXID"]
        txid = list(struct.unpack_from("<%dI" % (s // 4), data, o))
    tex_fids = []
    for i, t in enumerate(types):
        if t == 0:
            tex_fids.append(txid[i] if i < len(txid) else 0)
        elif t in (11, 12, 13):
            tex_fids.append(variations[t - 11])
        else:
            tex_fids.append(("type", t))
    nlook, olook = _arr(md, 0x80)
    tex_lookup = [struct.unpack_from("<H", md, olook + i * 2)[0] for i in range(nlook)]
    nmat, omat = _arr(md, 0x70)
    mats = [struct.unpack_from("<2H", md, omat + i * 4) for i in range(nmat)]       # (flags, blend mode)
    skins = MT.skin_ids(data)
    if not skins:
        if key is not None:
            _M2[key] = None
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
        subs.append((sid, istart + (lvl << 16), icount))
    tris = []
    seen = set()
    for i in range(nbat):
        bo = obat + i * 24
        sub_i, = struct.unpack_from("<H", skin, bo + 4)
        mat_i, = struct.unpack_from("<H", skin, bo + 10)
        combo, = struct.unpack_from("<H", skin, bo + 16)
        if sub_i in seen or sub_i >= len(subs):
            continue
        sid, istart, icount = subs[sub_i]
        ok = geoset_ok(sid) if geoset_ok else (sid == 0 or sid % 100 == 1 or sid < 100)
        if not ok:
            continue
        blend = mats[mat_i][1] if mat_i < len(mats) else 0
        if blend >= 3:                   # additive glows, light shafts: not drawn on a sprite
            continue
        seen.add(sub_i)
        tf = 0
        if combo < len(tex_lookup):
            ti = tex_lookup[combo]
            tf = tex_fids[ti] if ti < len(tex_fids) else 0
        for k in range(istart, istart + icount - 2, 3):
            tris.append((vlook[idx[k]], vlook[idx[k + 1]], vlook[idx[k + 2]], tf))
    mesh = {"verts": np.array(verts, np.float32), "uvs": np.array(uvs, np.float32), "tris": tris, "box": box,
            "fid": fid}
    if key is not None:
        _M2[key] = mesh
    return mesh


def wmo_mesh(fid, outdoor_only=False):
    """Every visible triangle of a WMO (all groups, or only its outdoor ones) with its material's texture."""
    import azw_wmo as WM
    import wmo_tools as WT
    o = WM.load(fid)
    data = C.read_fid(fid)
    mat_tex = []
    for name, off, size in WT.chunks(data):
        if name == "MOMT":
            for i in range(size // 64):
                mat_tex.append(struct.unpack_from("<I", data, off + i * 64 + 12)[0])
    verts, uvs, tris = [], [], []
    for g in o["groups"]:
        if not g["verts"] or (outdoor_only and g["flags"] & 0x2000):
            continue
        base = len(verts)
        verts.extend(g["verts"])
        gu = g.get("uvs") or [(0.0, 0.0)] * len(g["verts"])
        uvs.extend(gu[:len(g["verts"])] + [(0.0, 0.0)] * (len(g["verts"]) - len(gu)))
        for t, (fl, mat) in zip(g["tris"], g["mopy"] or [(0, 0)] * len(g["tris"])):
            if mat == 255:               # collision only
                continue
            tf = mat_tex[mat] if mat < len(mat_tex) else 0
            tris.append((base + t[0], base + t[1], base + t[2], tf))
    return {"verts": np.array(verts, np.float32), "uvs": np.array(uvs, np.float32), "tris": tris}


# ---------------------------------------------------------------------------------------------------------------
# Animation: a model's vertices at time t of one of its sequences (Walk = 4, Run = 5, Stand = 0)
# ---------------------------------------------------------------------------------------------------------------

def _anim_file(data, md, seq_index):
    """The bytes a sequence's track offsets point into: the .m2 itself (flag 0x20) or its .anim file (AFID)."""
    nseq, oseq = _arr(md, 0x1C)
    sid, var = struct.unpack_from("<2H", md, oseq + seq_index * 64)
    flags = struct.unpack_from("<I", md, oseq + seq_index * 64 + 12)[0]
    if flags & 0x20:
        return md
    ch = _m2_chunks(data)
    if "AFID" not in ch:
        return None
    o, s = ch["AFID"]
    for k in range(s // 8):
        a, sub, fid = struct.unpack_from("<2HI", data, o + k * 8)
        if a == sid and sub == var and fid:
            try:
                d = C.read_fid(fid)
            except Exception:
                return None
            if d[:4] == b"AFM2":                      # chunked .anim: the raw data is that chunk
                n = struct.unpack_from("<I", d, 4)[0]
                return d[8:8 + n]
            return d
    return None


def find_sequence(data, anim_id):
    md = data[8:] if data[:4] == b"MD21" else data
    nseq, oseq = _arr(md, 0x1C)
    for i in range(nseq):
        if struct.unpack_from("<H", md, oseq + i * 64)[0] == anim_id:
            return i, struct.unpack_from("<I", md, oseq + i * 64 + 4)[0]    # (index, duration ms)
    return None, 0


def _sample(md, src, track_off, seq, t, kind):
    """A track's value at time t (ms) of sequence seq, linear between keys; None if it has none."""
    n_ts, o_ts = _arr(md, track_off + 4)
    n_vals, o_vals = _arr(md, track_off + 12)
    if seq >= n_ts or seq >= n_vals or src is None:
        return None
    cnt_t, off_t = _arr(md, o_ts + seq * 8)
    cnt_v, off_v = _arr(md, o_vals + seq * 8)
    if cnt_v == 0 or off_v + cnt_v * (8 if kind == "q" else 12) > len(src):
        return None
    times = struct.unpack_from("<%dI" % cnt_t, src, off_t) if cnt_t and off_t + 4 * cnt_t <= len(src) else (0,)

    def val(i):
        i = max(0, min(cnt_v - 1, i))
        if kind == "q":
            return MT._quat(struct.unpack_from("<4h", src, off_v + i * 8))
        return struct.unpack_from("<3f", src, off_v + i * 12)
    if cnt_v == 1 or len(times) < 2:
        return val(0)
    k = 0
    while k + 1 < len(times) and times[k + 1] <= t:
        k += 1
    if k + 1 >= len(times):
        return val(k)
    t0, t1 = times[k], times[k + 1]
    f = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
    a, b = val(k), val(k + 1)
    if kind == "q":
        if sum(x * y for x, y in zip(a, b)) < 0:
            b = [-x for x in b]
    return [x + (y - x) * f for x, y in zip(a, b)]


def bone_mats(data, seq, t):
    """Every bone's 3x4 matrix at time t of sequence index seq (seq None: the rest pose)."""
    md = data[8:] if data[:4] == b"MD21" else data
    src = _anim_file(data, md, seq) if seq is not None else None
    nbone, obone = _arr(md, 0x2C)
    mats = []
    for i in range(nbone):
        bo = obone + i * 88
        parent = struct.unpack_from("<h", md, bo + 8)[0]
        if seq is None:
            tr, q, sc = (0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 1.0), (1.0, 1.0, 1.0)
        else:
            tr = _sample(md, src, bo + 16, seq, t, "v") or (0.0, 0.0, 0.0)
            q = _sample(md, src, bo + 36, seq, t, "q") or (0.0, 0.0, 0.0, 1.0)
            sc = _sample(md, src, bo + 56, seq, t, "v") or (1.0, 1.0, 1.0)
        pivot = struct.unpack_from("<3f", md, bo + 76)
        m = MT._trs(tr, q, sc, pivot)
        if 0 <= parent < len(mats):
            m = MT._mul(mats[parent], m)
        mats.append(m)
    return mats


def attachment(data, att_id):
    """(bone, position) of the model's attachment point att_id (1 right hand, 2 left hand, 0 shield), or None.
    M2Attachment is 40 bytes at the header's 0xF0 array: id, bone, (pad), position."""
    md = data[8:] if data[:4] == b"MD21" else data
    n, o = _arr(md, 0xF0)
    for i in range(n):
        aid, bone = struct.unpack_from("<IH", md, o + i * 40)
        if aid == att_id:
            return bone, struct.unpack_from("<3f", md, o + i * 40 + 8)
    return None


def apply_mat(m, v):
    """3x4 matrix m on points v (N, 3)."""
    M = np.array(m, np.float64).reshape(3, 4)
    return (v @ M[:, :3].T + M[:, 3]).astype(np.float32)


def posed_vertices(data, seq, t):
    """Vertices at time t of sequence index seq (bones without data there keep their rest pose)."""
    md = data[8:] if data[:4] == b"MD21" else data
    nv, ov = _arr(md, 0x3C)
    mats = bone_mats(data, seq, t)
    nbone = len(mats)
    mats = list(mats)
    out = np.zeros((nv, 3), np.float32)
    for i in range(nv):
        vo = ov + i * 48
        x, y, z = struct.unpack_from("<3f", md, vo)
        ws = struct.unpack_from("<4B", md, vo + 12)
        bs = struct.unpack_from("<4B", md, vo + 16)
        tw = sum(ws)
        if not mats or tw == 0:
            out[i] = (x, y, z)
            continue
        px = py = pz = 0.0
        for w, bi in zip(ws, bs):
            if w == 0 or bi >= len(mats):
                continue
            m, f = mats[bi], w / tw
            px += f * (m[0] * x + m[1] * y + m[2] * z + m[3])
            py += f * (m[4] * x + m[5] * y + m[6] * z + m[7])
            pz += f * (m[8] * x + m[9] * y + m[10] * z + m[11])
        out[i] = (px, py, pz)
    return out

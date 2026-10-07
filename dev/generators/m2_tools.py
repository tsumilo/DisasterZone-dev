"""Blizzard's creature models (.m2, chunked MD21) as the client shows them standing: the vertices of the Stand
animation's first frame (skinned by the bones' tracks at time 0), for the strategy board's occlusion (gen_rooms.py
display_parts).

Layout (MD20 header, version 264+; offsets from the MD20 start): sequences at 0x1C, bones at 0x2C, vertices at 0x3C,
the model's box at 0xA0. M2Sequence is 64 bytes (id uint16 at 0, flags uint32 at 12: 0x20 = its data is in the .m2;
else in an external .anim file, not read here); M2CompBone is 88 bytes (parent int16 at 8; translation, rotation,
scale M2Tracks of 20 bytes at 16, 36, 56; pivot at 76); M2Track = interpolation uint16, global sequence int16,
timestamps M2Array<M2Array<uint32>>, values M2Array<M2Array<T>> (one inner array per sequence; rotation as 4 int16,
x / 32767 after shifting negatives by +32768 and positives by -32767). M2Vertex is 48 bytes: position, 4 bone weights
(uint8), 4 bone indices (uint8, into the bone lookup at 0x78... the vertex's indices are bone indices directly in
version 264+ skins? no: they index the bones array), normal, 2 texture coordinates.
"""
import math
import struct


def _arr(b, off):
    return struct.unpack_from("<2I", b, off)


def _quat(raw):
    out = []
    for s in raw:
        out.append((s + 32768 if s < 0 else s - 32767) / 32767.0)
    return out


def _mul(a, b):
    """3x4 affine matrices as 12 floats (row-major 3x4)."""
    return [
        a[0] * b[0] + a[1] * b[4] + a[2] * b[8], a[0] * b[1] + a[1] * b[5] + a[2] * b[9],
        a[0] * b[2] + a[1] * b[6] + a[2] * b[10], a[0] * b[3] + a[1] * b[7] + a[2] * b[11] + a[3],
        a[4] * b[0] + a[5] * b[4] + a[6] * b[8], a[4] * b[1] + a[5] * b[5] + a[6] * b[9],
        a[4] * b[2] + a[5] * b[6] + a[6] * b[10], a[4] * b[3] + a[5] * b[7] + a[6] * b[11] + a[7],
        a[8] * b[0] + a[9] * b[4] + a[10] * b[8], a[8] * b[1] + a[9] * b[5] + a[10] * b[9],
        a[8] * b[2] + a[9] * b[6] + a[10] * b[10], a[8] * b[3] + a[9] * b[7] + a[10] * b[11] + a[11],
    ]


def _trs(t, q, s, pivot):
    """T(pivot) T(t) R(q) S(s) T(-pivot)."""
    x, y, z, w = q
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    r = [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
         2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
         2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]
    px, py, pz = pivot
    m = [r[0] * s[0], r[1] * s[1], r[2] * s[2], 0, r[3] * s[0], r[4] * s[1], r[5] * s[2], 0,
         r[6] * s[0], r[7] * s[1], r[8] * s[2], 0]
    # translation: pivot + t - M * pivot
    m[3] = px + t[0] - (m[0] * px + m[1] * py + m[2] * pz)
    m[7] = py + t[1] - (m[4] * px + m[5] * py + m[6] * pz)
    m[11] = pz + t[2] - (m[8] * px + m[9] * py + m[10] * pz)
    return m


def standing_vertices(data):
    """-> ([(x, y, z)] the vertices in the Stand animation's first frame, header box (6 floats)), from an .m2 file's
    bytes. Bones whose Stand data is not in the file (an external .anim) keep their rest pose."""
    md = data[8:] if data[:4] == b"MD21" else data
    if md[:4] != b"MD20":
        raise ValueError("not an M2 file")
    box = struct.unpack_from("<6f", md, 0xA0)
    nseq, oseq = _arr(md, 0x1C)
    nbone, obone = _arr(md, 0x2C)
    nv, ov = _arr(md, 0x3C)
    stand, flags = 0, 0x20
    for i in range(nseq):
        sid = struct.unpack_from("<H", md, oseq + i * 64)[0]
        if sid == 0:
            stand, flags = i, struct.unpack_from("<I", md, oseq + i * 64 + 12)[0]
            break
    inline = bool(flags & 0x20)

    def first(track_off, kind):
        n_ts, o_ts = _arr(md, track_off + 4)
        n_vals, o_vals = _arr(md, track_off + 12)
        if not inline or stand >= n_vals:
            return None
        cnt, off = _arr(md, o_vals + stand * 8)
        if cnt == 0 or off == 0 or off >= len(md):
            return None
        if kind == "q":
            return _quat(struct.unpack_from("<4h", md, off))
        return struct.unpack_from("<3f", md, off)

    mats = []
    for i in range(nbone):
        bo = obone + i * 88
        parent = struct.unpack_from("<h", md, bo + 8)[0]
        t = first(bo + 16, "v") or (0.0, 0.0, 0.0)
        q = first(bo + 36, "q") or (0.0, 0.0, 0.0, 1.0)
        s = first(bo + 56, "v") or (1.0, 1.0, 1.0)
        pivot = struct.unpack_from("<3f", md, bo + 76)
        m = _trs(t, q, s, pivot)
        if 0 <= parent < len(mats):
            m = _mul(mats[parent], m)
        mats.append(m)
    out = []
    for i in range(nv):
        vo = ov + i * 48
        x, y, z = struct.unpack_from("<3f", md, vo)
        ws = struct.unpack_from("<4B", md, vo + 12)
        bs = struct.unpack_from("<4B", md, vo + 16)
        tw = sum(ws)
        if not mats or tw == 0:
            out.append((x, y, z))
            continue
        px = py = pz = 0.0
        for w, bi in zip(ws, bs):
            if w == 0 or bi >= len(mats):
                continue
            m, f = mats[bi], w / tw
            px += f * (m[0] * x + m[1] * y + m[2] * z + m[3])
            py += f * (m[4] * x + m[5] * y + m[6] * z + m[7])
            pz += f * (m[8] * x + m[9] * y + m[10] * z + m[11])
        out.append((px, py, pz))
    return out, box


def skin_ids(data):
    """The skin files' IDs of a chunked (MD21) .m2 (its SFID chunk; the first is the full-detail skin), else []."""
    out, i = [], 0
    if data[:4] != b"MD21":
        return out
    while i + 8 <= len(data):
        tag, size = data[i:i + 4], struct.unpack_from("<I", data, i + 4)[0]
        if tag == b"SFID":
            out = list(struct.unpack_from("<%dI" % (size // 4), data, i + 8))
            break
        i += 8 + size
    return out


def skin_triangles(skin):
    """A .skin file's triangles as vertex numbers of the .m2 (its index list mapped through its vertex lookup)."""
    if skin[:4] != b"SKIN":
        raise ValueError("not a skin file")
    nlook, olook, nidx, oidx = struct.unpack_from("<4I", skin, 4)
    look = struct.unpack_from("<%dH" % nlook, skin, olook)
    idx = struct.unpack_from("<%dH" % nidx, skin, oidx)
    return [(look[idx[k]], look[idx[k + 1]], look[idx[k + 2]]) for k in range(0, nidx - 2, 3)]


def standing_mesh(data, skin):
    """-> (vertices in the Stand animation's first frame (standing_vertices), triangles (vertex numbers), header
    box) from an .m2's bytes and its first skin's."""
    vs, box = standing_vertices(data)
    return vs, skin_triangles(skin), box

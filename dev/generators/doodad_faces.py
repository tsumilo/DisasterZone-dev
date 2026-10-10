"""The doodads a WMO places (its M2 props: tables, barrels, banners...) as room faces, for rooms the follow camera
looks down into (the Portal hub): baked into the room they cost nothing per frame and the room renderer sorts them
with the walls, where ModelScene actors would need a model, an occluder and a draw each.

faces(mapdir, box, zlo, zhi, budget) -> [(texture key (file ID, blend), [(x, y, z, u, v, light)] * 3, flags)] in
world coordinates, the format gen_rooms.wmo_faces gives. Each doodad: model space (m2_preview.model, the Stand pose)
-> turned by its quaternion and scaled -> plus its position in the WMO -> the placement's to_world. Kept: doodads
whose middle is in the box and the height band, biggest first (the box's half diagonal times scale) until `budget`
faces; their opaque and alpha-keyed parts (M2 blend 0, 1; blend 2 drawn as a key), never glows / additive (3+) nor
untextured parts. Light: 0.55 + 0.45 * the normal's share towards a light from above, south-west.
"""
import math, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "art", "crawler"))
import gen_rooms as R  # noqa: E402
import azw_wmo as AW  # noqa: E402
import m2_preview as MP  # noqa: E402

DOODAD = 0                       # the flags of a doodad's face (no collision, not ground, not liquid)
LIGHT = (0.35, 0.45, 0.82)       # towards the light


def _quat(q, v):
    qx, qy, qz, qw = q
    x, y, z = v
    ix = qw * x + qy * z - qz * y
    iy = qw * y + qz * x - qx * z
    iz = qw * z + qx * y - qy * x
    iw = -qx * x - qy * y - qz * z
    return (ix * qw - iw * qx - iy * qz + iz * qy, iy * qw - iw * qy - iz * qx + ix * qz,
            iz * qw - iw * qz - ix * qy + iy * qx)


def model_name(fid):
    """The model's own name (its MD20 header's), e.g. "BeerKeg01"."""
    d = MP.CASC.read_fid(int(fid))
    o = 8 if d[:4] == b"MD21" else 0
    n, no = struct.unpack_from("<2I", d, o + 8)
    return d[o + no:o + no + n].rstrip(b"\0").decode("latin1")


def placed(mapdir, box, zlo, zhi):
    """-> [(size, file ID, placement, doodad, model)] for the doodads whose position is in the box and band."""
    out = []
    pls, _ = R.placements(mapdir, box)
    for pl in pls:
        rt = AW.load(pl.file)
        fids = rt.get("doodad_fids") or []
        for dd in rt["doodads"]:
            fid = fids[dd["name"]] if dd["name"] < len(fids) else 0
            if not fid:
                continue
            wx, wy, wz = pl.to_world(*dd["pos"])
            if not (box[0] <= wx <= box[2] and box[1] <= wy <= box[3] and zlo <= wz <= zhi):
                continue
            try:
                m = MP.model(fid)
            except Exception:
                continue
            if not m["parts"] or len(m["V"]) == 0:
                continue
            ext = m["V"].max(0) - m["V"].min(0)
            out.append((float(math.hypot(*ext)) * dd["scale"], fid, pl, dd, m))
    out.sort(key=lambda t: -t[0])
    return out


def faces(mapdir, box, zlo, zhi, budget, min_size=0.0, keep=None):
    """keep: {model name: how many at most} (the nearest the box's middle first), ordered by priority; None: all,
    biggest first."""
    out, used, kept = [], 0, 0
    cands = placed(mapdir, box, zlo, zhi)
    if keep is not None:
        cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
        named = []
        for c in cands:
            nm = model_name(c[1])
            if nm in keep:
                wx, wy, _ = c[2].to_world(*c[3]["pos"])
                named.append((list(keep).index(nm), math.hypot(wx - cx, wy - cy), nm, c))
        named.sort(key=lambda t: (t[0], t[1]))
        count, cands = {}, []
        for _, _, nm, c in named:
            count[nm] = count.get(nm, 0) + 1
            if count[nm] <= keep[nm]:
                cands.append(c)
    for size, fid, pl, dd, m in cands:
        if size < min_size:
            continue
        mine = []
        for part in m["parts"]:
            tri, _tex, blend, tfid = part
            if not tfid or blend > 2:
                continue
            for a, b, c in tri:
                pts = []
                for i in (a, b, c):
                    v = m["V"][i]
                    lv = _quat(dd["rot"], (v[0] * dd["scale"], v[1] * dd["scale"], v[2] * dd["scale"]))
                    wx, wy, wz = pl.to_world(dd["pos"][0] + lv[0], dd["pos"][1] + lv[1], dd["pos"][2] + lv[2])
                    n = m["N"][i]
                    ln = _quat(dd["rot"], (n[0], n[1], n[2]))
                    # the normal in world axes: to_world of a direction = to_world(p + n) - to_world(p)
                    p0 = pl.to_world(*dd["pos"])
                    p1 = pl.to_world(dd["pos"][0] + ln[0], dd["pos"][1] + ln[1], dd["pos"][2] + ln[2])
                    nx, ny, nz = p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]
                    nl = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
                    lam = max(0.0, (nx * LIGHT[0] + ny * LIGHT[1] + nz * LIGHT[2]) / nl)
                    pts.append((wx, wy, wz, float(m["UV"][i][0]), float(m["UV"][i][1]), 0.55 + 0.45 * lam))
                mine.append(((tfid, min(blend, 1)), pts, DOODAD))
        if used + len(mine) > budget:
            continue
        out += mine
        used += len(mine)
        kept += 1
    print("doodads: %d kept, %d faces (budget %d)" % (kept, used, budget))
    return out


def drop_posts(faces, zcut, foot=3.5, below=3.0):
    """The faces without the posts the room's ceiling cut slices: an object (faces joined by shared corners, as
    gen_rooms.drop_clutter finds them) at most `foot` yd across on the ground that rises from `below` yd under the cut
    to over it. Cut, a post is an open box seen from above (the follow camera); gone, the room is clear as a Diablo
    building with its columns hidden."""
    def vk(q):
        return (round(q[0], 2), round(q[1], 2), round(q[2], 2))
    parent = list(range(len(faces)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    owner = {}
    for k, (_, pts, _) in enumerate(faces):
        for q in pts:
            j = owner.setdefault(vk(q), k)
            if j != k:
                a, b = find(j), find(k)
                if a != b:
                    parent[a] = b
    lo, hi = {}, {}
    for k, (_, pts, _) in enumerate(faces):
        r = find(k)
        for q in pts:
            l, h = lo.get(r), hi.get(r)
            lo[r] = tuple(min(l[i], q[i]) for i in range(3)) if l else tuple(q[:3])
            hi[r] = tuple(max(h[i], q[i]) for i in range(3)) if h else tuple(q[:3])
    gone = {r for r in lo if hi[r][0] - lo[r][0] <= foot and hi[r][1] - lo[r][1] <= foot
            and lo[r][2] <= zcut - below and hi[r][2] >= zcut + 0.5}
    out = [f for k, f in enumerate(faces) if find(k) not in gone]
    print("posts: %d dropped (%d faces)" % (len(gone), len(faces) - len(out)))
    return out


def caps(faces, zcut, max_area=80.0, eps=0.02):
    """Lids for what the room's ceiling cut leaves open: the edges at the cut's height that only one face uses,
    chained into closed loops; each loop up to `max_area` sq yd (a column, a wall's top) gets a flat lid at the cut,
    ear-clipped, in the texture of a face on its rim. Seen from above a cut column is then a solid stump and a cut wall
    has a top, not an open box. faces: [(texture key, [(x, y, z, u, v, light)] * 3, flags)] in world coordinates."""
    def k(q):
        return (round(q[0] / eps), round(q[1] / eps))
    edges, at = {}, {}
    for fi, (key, pts, fl) in enumerate(faces):
        for a, b in ((0, 1), (1, 2), (2, 0)):
            p, q = pts[a], pts[b]
            if abs(p[2] - zcut) < 0.05 and abs(q[2] - zcut) < 0.05:
                kp, kq = k(p), k(q)
                if kp == kq:
                    continue
                e = (kp, kq) if kp < kq else (kq, kp)
                edges.setdefault(e, []).append(fi)
                at[kp], at[kq] = p, q
    nxt = {}
    for (a, b), fs in edges.items():
        if len(fs) == 1:
            nxt.setdefault(a, []).append((b, fs[0]))
            nxt.setdefault(b, []).append((a, fs[0]))
    out, used = [], set()
    for start in list(nxt):
        if start in used or len(nxt[start]) != 2:
            continue
        loop, prev, cur, owner = [start], None, start, nxt[start][0][1]
        ok = False
        while True:
            used.add(cur)
            cand = [n for n, _ in nxt.get(cur, []) if n != prev]
            if len(nxt.get(cur, [])) != 2 or not cand:
                break
            prev, cur = cur, cand[0]
            if cur == start:
                ok = True
                break
            if cur in used:
                break
            loop.append(cur)
        if not ok or len(loop) < 3:
            continue
        P = [at[v] for v in loop]
        area = 0.0
        for i in range(len(P)):
            x1, y1 = P[i][0], P[i][1]
            x2, y2 = P[(i + 1) % len(P)][0], P[(i + 1) % len(P)][1]
            area += x1 * y2 - x2 * y1
        if abs(area) / 2 > max_area or abs(area) / 2 < 0.05:
            continue
        if area < 0:
            P = P[::-1]
        key = faces[owner][0]
        idx = list(range(len(P)))
        guard = 0
        while len(idx) > 3 and guard < 10000:                     # ear clipping (counter-clockwise, seen from above)
            guard += 1
            clipped = False
            for j in range(len(idx)):
                a, b, c = P[idx[j - 1]], P[idx[j]], P[idx[(j + 1) % len(idx)]]
                cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
                if cross <= 1e-9:
                    continue
                inside = False
                for m in idx:
                    q = P[m]
                    if q is a or q is b or q is c:
                        continue
                    d1 = (b[0] - a[0]) * (q[1] - a[1]) - (b[1] - a[1]) * (q[0] - a[0])
                    d2 = (c[0] - b[0]) * (q[1] - b[1]) - (c[1] - b[1]) * (q[0] - b[0])
                    d3 = (a[0] - c[0]) * (q[1] - c[1]) - (a[1] - c[1]) * (q[0] - c[0])
                    if d1 > 0 and d2 > 0 and d3 > 0:
                        inside = True
                        break
                if inside:
                    continue
                out.append((key, [(q[0], q[1], zcut, q[0] * 0.25, q[1] * 0.25, 0.5) for q in (a, b, c)], DOODAD))
                idx.pop(j)
                clipped = True
                break
            if not clipped:
                break
        if len(idx) == 3:
            a, b, c = (P[m] for m in idx)
            out.append((key, [(q[0], q[1], zcut, q[0] * 0.25, q[1] * 0.25, 0.5) for q in (a, b, c)], DOODAD))
    print("caps: %d faces" % len(out))
    return out

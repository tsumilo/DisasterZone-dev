"""The Portal's hub: the Dark Portal's front as a flat backdrop (Media/Portal/Facade_Low.blp, Facade_High.blp).

The whole Dark Portal (WMO 115769, 46k faces) is far over the room renderer's budget (~7000), so the hub draws its
front as a picture standing in the gate's plane, like a stage backdrop: the camera only ever looks east at it
(Games/Portal/Hub.lua, camera.yaw = 0), so what stands near that plane (towers, lintel, statues, skull) lines up as
you walk; the floor you walk on is live room geometry (gen_dungeon_proto.py hub: the platform west of the gate).

Rendered orthographically from the west (looking east, the Portal's front faces Hellfire Peninsula) with the
client's own textures, z-buffered, alpha-keyed textures see-through, everything else transparent (the mouth too:
the nether sky and the Portal's live swirl model show through it). Only the gate itself: faces from 20 yd in
front of the plane (the statues) to the back, from the platform up.

Picture: world x (north) X0..X1 across, height Z0..Z1 up (world yd), split in two textures at ZS so the part at eye
level gets the most pixels: Low = Z0..ZS (1024 x 1024), High = ZS..Z1 (1024 x 512). Writes the extents for the Lua
side in the json beside the shots.
Run: luaenv\\Scripts\\python.exe generators\\gen_portal_facade.py
"""
import io, json, os, sys
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import casc_local as C  # noqa: E402
import gen_rooms as R  # noqa: E402
import azw_blp  # noqa: E402

GATE_WY = 946.8                      # the gate's plane: world y (west) of the Portal's swirl doodad
FRONT = 20.0                         # faces up to this far in front of (west of) the plane are drawn
X0, X1 = -385.0, -105.0              # world x (north) across the picture (the chain to the far statue)
Z0, ZS, Z1 = 82.0, 222.0, 362.0      # world height: the platform, the split, the skull's top
OUT = os.path.join(HERE, "..", "..", "addon", "DisasterZone", "Media", "Portal")
SHOTS = os.path.join(HERE, "..", "art", "crawler", "shots")
_TEX = {}


def tex(fid):
    if fid not in _TEX:
        try:
            _TEX[fid] = np.asarray(Image.open(io.BytesIO(C.read_fid(int(fid)))).convert("RGBA"), np.float32) / 255
        except Exception:
            _TEX[fid] = np.full((4, 4, 4), 0.5, np.float32)
    return _TEX[fid]


def render(faces, z0, z1, w, h):
    """Orthographic, looking east: picture x = north (X0 left .. X1 right? no: looking east, north is LEFT), y = up."""
    img = np.zeros((h, w, 4), np.float32)
    zb = np.full((h, w), np.inf)
    sx = w / (X1 - X0)
    sz = h / (z1 - z0)
    for (fid, blend), pts, fl in faces:
        P = np.array([q[:3] for q in pts])
        if (P[:, 1] < GATE_WY - FRONT).all() and False:
            continue
        # looking east from the west: screen right = south (smaller world x), so picture x = (X1 - wx) * sx
        xs = (X1 - P[:, 0]) * sx
        ys = (z1 - P[:, 2]) * sz
        depth = -P[:, 1]                       # nearer the camera (west) = larger world y = smaller depth
        x0, x1 = max(0, int(xs.min())), min(w - 1, int(xs.max()) + 1)
        y0, y1 = max(0, int(ys.min())), min(h - 1, int(ys.max()) + 1)
        if x0 > x1 or y0 > y1:
            continue
        den = (ys[1] - ys[2]) * (xs[0] - xs[2]) + (xs[2] - xs[1]) * (ys[0] - ys[2])
        if abs(den) < 1e-9:
            continue
        X, Y = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        l0 = ((ys[1] - ys[2]) * (X - xs[2]) + (xs[2] - xs[1]) * (Y - ys[2])) / den
        l1 = ((ys[2] - ys[0]) * (X - xs[2]) + (xs[0] - xs[2]) * (Y - ys[2])) / den
        l2 = 1 - l0 - l1
        inside = (l0 >= 0) & (l1 >= 0) & (l2 >= 0)
        if not inside.any():
            continue
        d = l0 * depth[0] + l1 * depth[1] + l2 * depth[2]
        sub = zb[y0:y1 + 1, x0:x1 + 1]
        ok = inside & (d < sub)
        if not ok.any():
            continue
        u = l0 * pts[0][3] + l1 * pts[1][3] + l2 * pts[2][3]
        v = l0 * pts[0][4] + l1 * pts[1][4] + l2 * pts[2][4]
        T = tex(fid)
        th, tw = T.shape[:2]
        col = T[np.floor(v * th).astype(int) % th, np.floor(u * tw).astype(int) % tw]
        if blend:
            ok &= col[..., 3] > 0.5
        light = l0 * pts[0][5] + l1 * pts[1][5] + l2 * pts[2][5]
        rgb = col[..., :3] * np.clip(light, 0.3, 1.4)[..., None]
        sub[ok] = d[ok]
        reg = img[y0:y1 + 1, x0:x1 + 1]
        reg[ok, :3] = rgb[ok]
        reg[ok, 3] = 1
    return img


def fill_mouth(rgba):
    """The gate's mouth painted with the swirl's own textures (Hellfire_DarkPortal_FX, model 192920: nebula 197067,
    stars 192923, the green flame band 192922): the open area in the middle of the picture (the transparent part
    joined to its centre, not the sky round the outside) gets the nebula, the stars added over it, and the flames
    glowing in from its edges. The live model is not drawn: it is a 160 yd volume no backdrop could hide."""
    from collections import deque
    h, w = rgba.shape[:2]
    clear = rgba[..., 3] < 0.5
    seen = np.zeros_like(clear)
    sy, sx = int(h * 0.55), w // 2
    if not clear[sy, sx]:
        return rgba
    q = deque([(sy, sx)])
    seen[sy, sx] = True
    edge_touch = False
    while q:
        y, x = q.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and clear[ny, nx] and not seen[ny, nx]:
                if ny == 0 or nx == 0 or nx == w - 1:
                    edge_touch = True
                seen[ny, nx] = True
                q.append((ny, nx))
    ys, xs = np.nonzero(seen)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    mh, mw = y1 - y0, x1 - x0

    def img(fid, size):
        return np.asarray(Image.open(io.BytesIO(C.read_fid(fid))).convert("RGBA").resize(size, Image.BICUBIC),
                          np.float32) / 255
    neb = img(197067, (mw, mh))[..., :3]
    stars = img(192923, (mw, mh))[..., :3]
    flame = img(192922, (mw, max(8, mh // 3)))[..., :3]
    col = neb * 0.9 + stars * 0.8
    # distance to the mouth's edge (in pixels, a few chamfer passes): green flames strongest there
    m = seen[y0:y1, x0:x1]
    d = np.where(m, 1e9, 0.0)
    for _ in range(2):
        for y in range(mh):
            for x in range(1, mw):
                d[y, x] = min(d[y, x], d[y, x - 1] + 1)
            for x in range(mw - 2, -1, -1):
                d[y, x] = min(d[y, x], d[y, x + 1] + 1)
        for x in range(mw):
            for y in range(1, mh):
                d[y, x] = min(d[y, x], d[y - 1, x] + 1)
            for y in range(mh - 2, -1, -1):
                d[y, x] = min(d[y, x], d[y + 1, x] + 1)
    rim = np.clip(1 - d / (0.12 * min(mw, mh)), 0, 1)[..., None]
    band = np.tile(flame, (int(np.ceil(mh / flame.shape[0])) + 1, 1, 1))[:mh]
    green = np.clip(band * 1.8 + np.array([0.15, 0.55, 0.05]) * 0.6, 0, 1)
    col = col * (1 - rim * 0.85) + green * rim
    out = rgba.copy()
    sub = out[y0:y1, x0:x1]
    sub[m, :3] = np.clip(col[m], 0, 1)
    sub[m, 3] = 1
    print("mouth filled: %d x %d px%s" % (mw, mh, " (it reached the picture's edge!)" if edge_touch else ""))
    return out


def main():
    pls, _ = R.placements("Expansion01", (-330.0, 870.0, -180.0, 1010.0))
    faces = R.wmo_faces(pls[0], (-1e9, -1e9, 1e9, 1e9), -1e9, 1e9, [])
    keep = [f for f in faces
            if all(q[1] <= GATE_WY + FRONT for q in f[1])             # from 20 yd west of the plane to the back
            and max(q[2] for q in f[1]) >= Z0 + 0.5                    # from the platform up (not the floor)
            and all(X0 - 5 <= q[0] <= X1 + 5 for q in f[1])]
    print("faces drawn: %d of %d" % (len(keep), len(faces)))
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SHOTS, exist_ok=True)
    for name, z0, z1, w, h in (("Facade_Low", Z0, ZS, 1024, 1024), ("Facade_High", ZS, Z1, 1024, 512)):
        img = render(keep, z0, z1, w, h)
        if name == "Facade_Low":
            img = fill_mouth(img)
        rgba = (np.clip(img, 0, 1) * 255).astype(np.uint8)
        Image.fromarray(rgba, "RGBA").save(os.path.join(SHOTS, name + ".png"))
        azw_blp.write_dxt5(Image.fromarray(rgba, "RGBA"), os.path.join(OUT, name + ".blp"))
        print(name, os.path.getsize(os.path.join(OUT, name + ".blp")), "bytes")
    meta = dict(gate_wy=GATE_WY, x0=X0, x1=X1, z0=Z0, zs=ZS, z1=Z1)
    json.dump(meta, open(os.path.join(SHOTS, "facade.json"), "w"), indent=1)
    print(meta)


if __name__ == "__main__":
    main()

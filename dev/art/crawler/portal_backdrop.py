"""The Portal's hub: a pre-rendered backdrop test. The WHOLE Dark Portal WMO (file 115769, all 46k faces, uncut)
rendered offline with the client's own textures from a fixed camera east of the gate, looking west, the way the
hub would show it (a painted backdrop behind the live 3D platform the characters walk on).
Run: python portal_backdrop.py [dist] [height] [pitch] -> shots/portal_backdrop.png"""
import io, math, os, sys
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.join(HERE, "..", "..")
sys.path.insert(0, os.path.join(DEV, "generators"))
import casc_local as C  # noqa: E402
import gen_rooms as R  # noqa: E402

W, H, FOV = 1280, 900, 0.9
_TEX = {}


def tex(fid):
    if fid not in _TEX:
        try:
            _TEX[fid] = np.asarray(Image.open(io.BytesIO(C.read_fid(int(fid)))).convert("RGBA"), np.float32) / 255
        except Exception:
            _TEX[fid] = np.full((4, 4, 4), 0.5, np.float32)
    return _TEX[fid]


def main():
    dist = float(sys.argv[1]) if len(sys.argv) > 1 else 150
    height = float(sys.argv[2]) if len(sys.argv) > 2 else 45
    pitch = float(sys.argv[3]) if len(sys.argv) > 3 else 0.12
    pls, _ = R.placements("Expansion01", (-330.0, 870.0, -180.0, 1010.0))
    faces = R.wmo_faces(pls[0], (-1e9, -1e9, 1e9, 1e9), -1e9, 1e9, [])
    # world (x north, y west, z up) -> view space: east = -wy, north = wx
    gx, gy, gz = -946.8, -245.7, 84.35 + 60          # the gate's middle, 60 yd up
    yaw = math.pi if dist > 0 else 0.0               # dist > 0: from the east looking west; < 0: from the west
    fx, fy, fz = math.cos(yaw) * math.cos(pitch), math.sin(yaw) * math.cos(pitch), -math.sin(pitch)
    cx, cy, cz = gx + dist, gy, 84.35 + height           # (gx + dist: east of the gate for dist > 0)
    rx, ry, rz = math.sin(yaw), -math.cos(yaw), 0.0
    ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
    f = (H / 2) / math.tan(FOV / 2)
    # the sky behind: Outland's orange and violet (the nether skybox is drawn live in game)
    t = np.linspace(0, 1, H)[:, None, None]
    img = (np.array([0.55, 0.25, 0.12]) * (1 - t) + np.array([0.28, 0.08, 0.30]) * t) * np.ones((H, W, 3))
    zb = np.full((H, W), np.inf)
    for (fid, blend), pts, fl in faces:
        P = np.array([(-q[1], q[0], q[2]) for q in pts])
        dx, dy, dz = P[:, 0] - cx, P[:, 1] - cy, P[:, 2] - cz
        d = dx * fx + dy * fy + dz * fz
        if (d < 1).any():
            continue
        xs = W / 2 + f * (dx * rx + dy * ry + dz * rz) / d
        ys = H / 2 - f * (dx * ux + dy * uy + dz * uz) / d
        x0, x1 = max(0, int(xs.min())), min(W - 1, int(xs.max()) + 1)
        y0, y1 = max(0, int(ys.min())), min(H - 1, int(ys.max()) + 1)
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
        w0, w1, w2 = l0 / d[0], l1 / d[1], l2 / d[2]
        ws = w0 + w1 + w2
        depth = 1 / ws
        sub = zb[y0:y1 + 1, x0:x1 + 1]
        ok = inside & (depth < sub)
        if not ok.any():
            continue
        u = (w0 * pts[0][3] + w1 * pts[1][3] + w2 * pts[2][3]) / ws
        v = (w0 * pts[0][4] + w1 * pts[1][4] + w2 * pts[2][4]) / ws
        T = tex(fid)
        th, tw = T.shape[:2]
        col = T[np.floor(v * th).astype(int) % th, np.floor(u * tw).astype(int) % tw]
        if blend:                                    # alpha-keyed (chains, spikes): see-through where clear
            ok &= col[..., 3] > 0.5
        light = (w0 * pts[0][5] + w1 * pts[1][5] + w2 * pts[2][5]) / ws
        rgb = col[..., :3] * np.clip(light, 0.25, 1.4)[..., None]
        sub[ok] = depth[ok]
        reg = img[y0:y1 + 1, x0:x1 + 1]
        reg[ok] = rgb[ok]
    os.makedirs(os.path.join(HERE, "shots"), exist_ok=True)
    out = os.path.join(HERE, "shots", "portal_backdrop.png")
    Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(out)
    print(out)


if __name__ == "__main__":
    main()

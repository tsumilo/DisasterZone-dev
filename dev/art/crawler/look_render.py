"""Portal crawler prototype: the look. Renders the Ramparts entrance room with the game's REAL textures (read from the
installed client) through the prototype's fixed camera (north, pitch 0.95 rad, 26 yd, fov 1.1), z-buffered, plus the
party and the pack as markers at their positions after a few seconds of the fight (from the addon's own sim in the
mock). The mock has no 3D models, so units are drawn as rings with names; in game they are the real models.
Run: python look_render.py -> shots/look_entrance.png, shots/look_fight.png"""
import io, math, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.join(HERE, "..", "..")
sys.path.insert(0, os.path.join(DEV, "tools"))
sys.path.insert(0, os.path.join(DEV, "generators"))
os.environ["DISASTERZONE_ROOMS"] = "1"
import casc_local as C  # noqa: E402
import render_check as RC  # noqa: E402
from harness import World, Client  # noqa: E402

W, H, FOV = 1280, 800, 1.1
PITCH, DIST = 0.95, 26.0
YAW = math.pi / 2                # the way the fixed camera looks (0 east, pi / 2 north)
_TEX = {}


def tex(fid):
    if fid not in _TEX:
        try:
            im = Image.open(io.BytesIO(C.read_fid(int(fid)))).convert("RGB")
            _TEX[fid] = np.asarray(im, np.float32) / 255
        except Exception:
            _TEX[fid] = np.full((4, 4, 3), 0.5, np.float32)
    return _TEX[fid]


def render(mesh, target, units, path, title, quads=()):
    tx, ty, tz = target
    fx, fy, fz = math.cos(YAW) * math.cos(PITCH), math.sin(YAW) * math.cos(PITCH), -math.sin(PITCH)
    cx, cy, cz = tx - fx * DIST, ty - fy * DIST, tz - fz * DIST
    rx, ry, rz = math.sin(YAW), -math.cos(YAW), 0.0             # right of where it looks
    ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx   # up = right x forward
    f = (H / 2) / math.tan(FOV / 2)

    def proj(P):
        dx, dy, dz = P[:, 0] - cx, P[:, 1] - cy, P[:, 2] - cz
        d = dx * fx + dy * fy + dz * fz
        sx = W / 2 + f * (dx * rx + dy * ry + dz * rz) / np.maximum(d, 1e-3)
        sy = H / 2 - f * (dx * ux + dy * uy + dz * uz) / np.maximum(d, 1e-3)
        return sx, sy, d

    V = mesh.V
    sx, sy, d = proj(V[:, :3])
    img = np.zeros((H, W, 3), np.float32) + np.array([0.04, 0.03, 0.05])
    zb = np.full((H, W), np.inf, np.float32)
    T = np.asarray(mesh.tri)
    texid = np.asarray(mesh.T4)[:, 3] if hasattr(mesh, "T4") else None
    for i, (a, b, c) in enumerate(T):
        if d[a] < 0.5 or d[b] < 0.5 or d[c] < 0.5:
            continue
        xs, ys = np.array([sx[a], sx[b], sx[c]]), np.array([sy[a], sy[b], sy[c]])
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
        # perspective-correct depth and texture coordinates
        w0, w1, w2 = l0 / d[a], l1 / d[b], l2 / d[c]
        ws = w0 + w1 + w2
        depth = 1 / ws
        sub = zb[y0:y1 + 1, x0:x1 + 1]
        ok = inside & (depth < sub)
        if not ok.any():
            continue
        u = (w0 * V[a, 3] + w1 * V[b, 3] + w2 * V[c, 3]) / ws
        v = (w0 * V[a, 4] + w1 * V[b, 4] + w2 * V[c, 4]) / ws
        t = tex(mesh.textures[mesh.texof[i] - 1]) if mesh.texof[i] >= 1 else None
        if t is None:
            col = np.full(u.shape + (3,), 0.5, np.float32)
        else:
            th, tw = t.shape[:2]
            col = t[(np.floor(v * th).astype(int) % th), (np.floor(u * tw).astype(int) % tw)]
        light = (w0 * V[a, 5] + w1 * V[b, 5] + w2 * V[c, 5]) / ws if V.shape[1] > 5 else 1
        if np.ndim(light):
            light = np.clip(light, 0.2, 1.5)[..., None]
        col = col * light
        sub[ok] = depth[ok]
        reg = img[y0:y1 + 1, x0:x1 + 1]
        reg[ok] = col[ok]
    # textured quads standing in the world (the hub's pre-rendered facade): (UL, LL, UR, LR points, RGBA image),
    # cut 24 x 24 so the picture keeps its perspective; transparent texels let what is behind show
    for (ul, ll, ur, lr), pic in quads:
        ph, pw = pic.shape[:2]
        G = 24
        for i in range(G):
            for j in range(G):
                u0, u1, v0, v1 = i / G, (i + 1) / G, j / G, (j + 1) / G
                def at(u, v):
                    top = [ul[k] + (ur[k] - ul[k]) * u for k in range(3)]
                    bot = [ll[k] + (lr[k] - ll[k]) * u for k in range(3)]
                    return [top[k] + (bot[k] - top[k]) * v for k in range(3)]
                P = np.array([at(u0, v0), at(u0, v1), at(u1, v0), at(u1, v1)])
                ps, pys, pd = proj(P)
                if (pd < 0.5).any():
                    continue
                x0, x1 = max(0, int(ps.min())), min(W - 1, int(ps.max()) + 1)
                y0, y1 = max(0, int(pys.min())), min(H - 1, int(pys.max()) + 1)
                if x0 > x1 or y0 > y1:
                    continue
                gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
                # bilinear inverse is overkill: map by the cell's bounding box (cells are small)
                uu = u0 + (gx - ps.min()) / max(1e-6, ps.max() - ps.min()) * (u1 - u0)
                vv = v0 + (gy - pys.min()) / max(1e-6, pys.max() - pys.min()) * (v1 - v0)
                depth = float(pd.mean())
                col = pic[np.clip((vv * ph).astype(int), 0, ph - 1), np.clip((uu * pw).astype(int), 0, pw - 1)]
                sub = zb[y0:y1 + 1, x0:x1 + 1]
                ok = (col[..., 3] > 0.5) & (depth < sub)
                sub[ok] = depth
                img[y0:y1 + 1, x0:x1 + 1][ok] = col[..., :3][ok]
    out = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
    dr = ImageDraw.Draw(out)
    try:
        font = ImageFont.truetype(os.path.join(DEV, "art", "casc", "lfg_mockup", "art", "frizqt.ttf"), 18)
    except Exception:
        font = None
    for name, x, y, z, col in units:
        px, py, pd = proj(np.array([[x, y, z]]))
        px, py = float(px[0]), float(py[0])
        r = max(6, 900 / float(pd[0]))
        dr.ellipse((px - r, py - r * 0.5, px + r, py + r * 0.5), outline=col, width=3)
        hx, hy, _ = proj(np.array([[x, y, z + 2.4]]))
        dr.line((px, py, float(hx[0]), float(hy[0])), fill=col, width=3)
        dr.text((float(hx[0]) - 40, float(hy[0]) - 22), name, fill=col, font=font)
    dr.text((16, 12), title, fill=(255, 214, 110), font=font)
    out.save(path)


def main():
    w = World()
    c = Client(w, "Alice", class_file="PALADIN", guild_rank=3)
    c.load_addon()
    w.tick(2)
    c.slash("/dz play trainer")
    w.tick(0.3)
    c.eval(open(RC.LUA_HELPER, encoding="utf-8").read())
    text = c.eval("return __RC.mesh('ramparts')")
    mesh = RC.Mesh.from_text(text)
    tris = np.array(text.split("|")[1].split(), int).reshape(-1, 4)
    mesh.texof = tris[:, 3]
    c.eval("ns.TrainerUI._Select('ramparts','p0')")
    c.eval("ns.TrainerUI._Start(3)")

    def units():
        rows = c.eval_py("local o = {} for _, u in ipairs(ns.TrainerUI._Sim().units) do if not u.dead then "
                         "o[#o+1] = { u.name, u.kind, u.x, u.y, u.gz or 0 } end end return o")
        colors = {"player": (90, 230, 90), "party": (90, 170, 255), "mob": (255, 80, 60)}
        return [(r[0], r[2], r[3], r[4], colors.get(r[1], (255, 255, 255))) for r in rows]

    def height(x, y):
        return c.eval("local h = ns.TrainerUI._Sim().enc.arena.height; return h and h(%f, %f) or 0" % (x, y)) or 0

    p = c.eval_py("local p = ns.TrainerUI._Sim().player; return { p.x, p.y }")
    os.makedirs(os.path.join(HERE, "shots"), exist_ok=True)
    render(mesh, (p[0], p[1], height(p[0], p[1]) + 2.2), units(), os.path.join(HERE, "shots", "look_entrance.png"),
           "Hellfire Ramparts: the entrance (fixed camera, real textures; units as markers)")
    c.eval("ns.TrainerUI._Sim():SetMove(-0.55, 1)")
    for _ in range(60):
        c.eval("ns.TrainerUI._Tick(0.05)")
    c.eval("local s = ns.TrainerUI._Sim(); s:SetMove(0, 0)")
    for _ in range(30):
        c.eval("ns.TrainerUI._Tick(0.05)")
    p = c.eval_py("local p = ns.TrainerUI._Sim().player; return { p.x, p.y }")
    render(mesh, (p[0], p[1], height(p[0], p[1]) + 2.2), units(), os.path.join(HERE, "shots", "look_fight.png"),
           "Hellfire Ramparts: the first pack (fixed camera, real textures; units as markers)")


if __name__ == "__main__":
    main()

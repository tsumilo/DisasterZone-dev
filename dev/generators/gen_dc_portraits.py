"""Disastercraft: the hero's round portrait (unit frames, character sheet, micro button), drawn from the same bare
human the pixel sprite is made of (azw_people.outfit: the race's model, its skin, face and hair) - so the face in the
frames is the hero's, never your own WoW character's, and never an untextured model.

A small renderer of its own (azw_render draws flat-shaded facets, fine for 32 px sprites, not for a face): smooth
shading from the model's averaged vertex normals, bilinear texture sampling, 4x supersampling; the camera looks at
the head a little from the side, like the client's portrait camera; cut to a circle over a dark ground the way
SetPortraitTexture hands portraits out.

Writes Media/Azeromon/Outfit/portrait0.blp (male) and portrait1.blp (female), 128 x 128 DXT5 with mips.

Run: luaenv\\Scripts\\python.exe generators\\gen_dc_portraits.py [--png out_dir]"""
import math
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import azw_people as AP  # noqa: E402
import azw_render as RD  # noqa: E402

MEDIA = os.path.join(HERE, "..", "..", "addon", "DisasterZone", "Media", "Azeromon", "Outfit")
SIZE = 128
SS = 4                                   # supersampling
YAW = math.pi - 0.35                     # (facing the camera, turned a little to its right)
ELEV = 6
LIGHT = np.array([-0.55, -0.45, 0.70])   # (east, north, up): from the camera's left, in front, above
LIGHT = LIGHT / np.linalg.norm(LIGHT)


def _bilinear(tex, u, v):
    th, tw = tex.shape[:2]
    x = np.mod(u, 1.0) * tw - 0.5
    y = np.mod(v, 1.0) * th - 0.5
    x0 = np.floor(x).astype(np.int64)
    y0 = np.floor(y).astype(np.int64)
    fx, fy = (x - x0)[..., None], (y - y0)[..., None]
    x0c, x1c = np.mod(x0, tw), np.mod(x0 + 1, tw)
    y0c, y1c = np.mod(y0, th), np.mod(y0 + 1, th)
    a = tex[y0c, x0c] * (1 - fx) + tex[y0c, x1c] * fx
    b = tex[y1c, x0c] * (1 - fx) + tex[y1c, x1c] * fx
    return a * (1 - fy) + b * fy


def _vertex_normals(world, tris):
    """Averaged normals, shared by vertices at the same place (the model's seams do not show)."""
    key = np.round(world, 4)
    _, inv = np.unique(key, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    acc = np.zeros((inv.max() + 1, 3))
    for a, b, c, _ in tris:
        n = np.cross(world[b] - world[a], world[c] - world[a])
        for i in (a, b, c):
            acc[inv[i]] += n
    n = acc[inv]
    return n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-9)


def render_head(sex):
    body, weapons, data = AP.outfit(1, sex, [])
    stand, _ = RD.find_sequence(data, 0)
    pm = AP._dress(body, weapons, data, RD.bone_mats(data, stand, 0), RD.posed_vertices(data, stand, 0))
    verts = np.asarray(pm["verts"], np.float64)
    uvs = np.asarray(pm["uvs"], np.float64)
    tris = pm["tris"]
    world, sx, sy, dep = RD._transform(verts, YAW, ELEV)
    used = np.unique(np.array([t[:3] for t in tris]))
    top = sy[used].min()
    height = sy[used].max() - top
    # the frame: the head and a little of the shoulders
    span = height * 0.185
    cx = float(np.median(sx[used][sy[used] < top + height * 0.12]))
    x0, y0 = cx - span / 2, top - span * 0.10
    k = SIZE * SS / span
    px, py = (sx - x0) * k, (sy - y0) * k
    W = H = SIZE * SS
    img = np.zeros((H, W, 4))
    zbuf = np.full((H, W), -1e18)
    normals = _vertex_normals(world, tris)
    for a, b, c, tf in tris:
        tex = RD.texture(tf)
        xa, ya, xb, yb, xc, yc = px[a], py[a], px[b], py[b], px[c], py[c]
        minx, maxx = int(max(0, math.floor(min(xa, xb, xc)))), int(min(W - 1, math.ceil(max(xa, xb, xc))))
        miny, maxy = int(max(0, math.floor(min(ya, yb, yc)))), int(min(H - 1, math.ceil(max(ya, yb, yc))))
        if maxx < minx or maxy < miny:
            continue
        det = (yb - yc) * (xa - xc) + (xc - xb) * (ya - yc)
        if abs(det) < 1e-12:
            continue
        gx, gy = np.meshgrid(np.arange(minx, maxx + 1) + 0.5, np.arange(miny, maxy + 1) + 0.5)
        l0 = ((yb - yc) * (gx - xc) + (xc - xb) * (gy - yc)) / det
        l1 = ((yc - ya) * (gx - xc) + (xa - xc) * (gy - yc)) / det
        l2 = 1 - l0 - l1
        inside = (l0 >= -1e-6) & (l1 >= -1e-6) & (l2 >= -1e-6)
        if not inside.any():
            continue
        z = l0 * dep[a] + l1 * dep[b] + l2 * dep[c]
        zb = zbuf[miny:maxy + 1, minx:maxx + 1]
        win = inside & (z > zb)
        if not win.any() or tex is None:
            continue
        u = l0 * uvs[a, 0] + l1 * uvs[b, 0] + l2 * uvs[c, 0]
        v = l0 * uvs[a, 1] + l1 * uvs[b, 1] + l2 * uvs[c, 1]
        col = _bilinear(tex, u, v)
        win = win & (col[..., 3] > 0.35)
        if not win.any():
            continue
        n = (l0[..., None] * normals[a] + l1[..., None] * normals[b] + l2[..., None] * normals[c])
        n = n / np.maximum(np.linalg.norm(n, axis=-1, keepdims=True), 1e-9)
        lam = np.abs(n @ LIGHT)                       # (two-sided, like the client's hair and cloth)
        shade = 0.42 + 0.78 * lam
        rgb = np.clip(col[..., :3] * shade[..., None], 0, 1)
        sub = img[miny:maxy + 1, minx:maxx + 1]
        sub[win, :3] = rgb[win]
        sub[win, 3] = 1
        zb[win] = z[win]
    # down to size, over the portrait's dark ground, cut round
    rgb = img[..., :3].reshape(SIZE, SS, SIZE, SS, 3)
    a = img[..., 3].reshape(SIZE, SS, SIZE, SS)
    cov = a.mean(axis=(1, 3))
    col = (rgb * a[..., None]).sum(axis=(1, 3)) / np.maximum(a.sum(axis=(1, 3))[..., None], 1e-9)
    yy, xx = np.mgrid[0:SIZE, 0:SIZE] + 0.5
    r = np.hypot(xx - SIZE / 2, yy - SIZE / 2) / (SIZE / 2)
    ground = np.stack([0.10 - 0.06 * r, 0.09 - 0.06 * r, 0.08 - 0.05 * r], -1).clip(0, 1)
    out = col * cov[..., None] + ground * (1 - cov[..., None])
    alpha = np.clip((1.0 - r) * SIZE / 2, 0, 1)        # (a soft one-pixel edge)
    pic = np.dstack([out, alpha])
    return Image.fromarray((pic * 255).round().astype(np.uint8), "RGBA")


def main():
    from azw_blp import write_dxt5
    png = None
    if "--png" in sys.argv:
        png = sys.argv[sys.argv.index("--png") + 1]
    os.makedirs(MEDIA, exist_ok=True)
    for sex in (0, 1):
        pic = render_head(sex)
        write_dxt5(pic, os.path.join(MEDIA, "portrait%d.blp" % sex))
        if png:
            pic.save(os.path.join(png, "portrait%d.png" % sex))
    print("wrote portrait0.blp, portrait1.blp")


if __name__ == "__main__":
    main()

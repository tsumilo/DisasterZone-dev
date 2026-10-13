"""Textures for the Gilded look (UI/Look.lua Look:Gilt; units, cast, bars, minimap, meters):
  Media/Gilt/trim_h.tga   a worked gold moulding, tiles left to right (REPEAT): bevel, a groove punched with studs
  Media/Gilt/trim_v.tga   the same, top to bottom
  Media/Gilt/corner.tga   a filigree corner for the top left (mirrored by tex coords): a scroll, a spear, a garnet stud
  Media/Gilt/bezel.tga    a square bevelled gold frame with rivets (buttons, icons, portraits); centre clear
  Media/Gilt/grain.tga    a faint damask lattice, white on clear, tiles (REPEAT); tinted gold at a low alpha
Everything gold is drawn in colour from a height field lit from the top left, never tinted.
Run (from dev): luaenv\\Scripts\\python.exe generators\\gen_gilt_media.py"""
import math
from pathlib import Path

import numpy as np
from PIL import Image

ADDON = Path(__file__).resolve().parents[2] / "addon" / "DisasterZone"
OUT = ADDON / "Media" / "Gilt"

STOPS = [(0.0, (34, 22, 5)), (0.3, (94, 67, 14)), (0.6, (200, 150, 48)), (0.85, (240, 205, 110)),
         (1.0, (255, 245, 200))]
LIGHT = np.array([-0.55, -0.6, 0.58])
LIGHT = LIGHT / np.linalg.norm(LIGHT)


def gold(v):
    v = np.clip(v, 0, 1)
    out = np.zeros(v.shape + (3,))
    for (a, ca), (b, cb) in zip(STOPS, STOPS[1:]):
        m = (v >= a) & (v <= b)
        t = ((v - a) / (b - a))[m][:, None]
        out[m] = np.array(ca) * (1 - t) + np.array(cb) * t
    return out


def shade(h, scale=1.0, base=0.5, spec=0.3, wrap=False):
    """Colour of a height field lit from the top left (y grows downward)."""
    if wrap:
        gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) / 2
        gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) / 2
    else:
        gy, gx = np.gradient(h)
    n = np.dstack([-gx * scale, -gy * scale, np.ones_like(h)])
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    d = n @ LIGHT
    r = 2 * d[..., None] * n - LIGHT              # reflection; the eye looks straight down
    s = np.clip(r[..., 2], 0, 1) ** 24
    return gold(base + 1.1 * (d - LIGHT[2]) + 0.04 * (h - h.mean()) + spec * s)


def smooth_noise(w, h, cells, seed):
    """Tileable value noise (cells divides w and h)."""
    rng = np.random.default_rng(seed)
    g = rng.random((cells, cells))
    ys, xs = np.mgrid[0:h, 0:w]
    fx, fy = xs / w * cells, ys / h * cells
    x0, y0 = np.floor(fx).astype(int), np.floor(fy).astype(int)
    tx, ty = fx - x0, fy - y0
    tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
    x1, y1 = (x0 + 1) % cells, (y0 + 1) % cells
    x0, y0 = x0 % cells, y0 % cells
    a = g[y0, x0] * (1 - tx) + g[y0, x1] * tx
    b = g[y1, x0] * (1 - tx) + g[y1, x1] * tx
    return a * (1 - ty) + b * ty


def save(rgb, alpha, size, name):
    big = np.dstack([np.clip(rgb, 0, 255), np.clip(alpha, 0, 1) * 255]).astype(np.uint8)
    im = Image.fromarray(big, "RGBA").resize(size, Image.LANCZOS)
    OUT.mkdir(parents=True, exist_ok=True)
    im.save(OUT / name)
    print("wrote", OUT / name)
    return im


def trim():
    W, H, k = 64, 16, 8
    w, h = W * k, H * k
    ys, xs = np.mgrid[0:h, 0:w]
    v = (ys + 0.5) / h
    u = (xs + 0.5) / w
    # the moulding's profile across: a rounded bead on top, a groove, a flatter fillet under it
    bead = np.clip(np.sin(np.clip((v - 0.04) / 0.42, 0, 1) * math.pi), 0, 1) * 1.0
    fillet = np.clip(np.sin(np.clip((v - 0.58) / 0.38, 0, 1) * math.pi), 0, 1) * 0.6
    hf = np.maximum(bead, fillet)
    # studs punched in the groove: a small dome every 16 px of the 64
    for cx in (8, 24, 40, 56):
        d = np.hypot((xs + 0.5) / k - cx, (ys + 0.5) / k - H * 0.52)
        hf = np.maximum(hf, np.clip(1 - (d / 2.2) ** 2, 0, 1) * 0.9)
        # a ring round each stud
        hf -= np.clip(1 - np.abs(d - 3.1) / 0.6, 0, 1) * 0.25
    # cross-hatched engraving on the fillet, hammered metal everywhere
    eng = (np.abs(np.sin((xs / k) * math.pi / 2 + (ys / k) * math.pi / 2)) < 0.18) & (v > 0.62) & (v < 0.92)
    hf -= eng * 0.12
    hf += (smooth_noise(w, h, 16, 3) - 0.5) * 0.12
    rgb = shade(hf * 14, scale=1.0, wrap=False)
    # a slow sheen along the length (tiles: one period per 64 px)
    rgb *= (0.92 + 0.12 * np.cos(u * 2 * math.pi))[..., None]
    alpha = np.ones_like(hf)
    alpha[(v < 0.02) | (v > 0.98)] = 0.85
    im = save(rgb, alpha, (W, H), "trim_h.tga")
    im.transpose(Image.Transpose.TRANSPOSE).save(OUT / "trim_v.tga")
    print("wrote", OUT / "trim_v.tga")


def corner():
    S, k = 32, 8
    n = S * k
    ys, xs = np.mgrid[0:n, 0:n]
    x, y = (xs + 0.5) / k, (ys + 0.5) / k
    hf = np.zeros((n, n))
    alpha = np.zeros((n, n))

    def add(mask_h, a):
        nonlocal hf, alpha
        hf = np.maximum(hf, mask_h)
        alpha = np.maximum(alpha, a)

    # the two arms along the edges (5 px thick), ending in spear tips
    for a, b in ((x, y), (y, x)):
        L = 27.0
        width = np.where(a < L - 6, 5.0, np.clip((L - a) / 6, 0, 1) * 5.0)
        inside = (b < width) & (a < L)
        prof = np.sin(np.clip(b / np.maximum(width, 0.01), 0, 1) * math.pi)
        add(np.where(inside, prof, 0), inside.astype(float))
    # the scroll: a ring curling in from the corner
    d = np.hypot(x - 12.5, y - 12.5)
    ring = np.clip(1 - np.abs(d - 5.2) / 1.6, 0, 1)
    add(np.sin(ring * math.pi / 2) * 0.9, (ring > 0).astype(float))
    # small leaf dots along the arms' inner side
    for cx, cy in ((19, 8.2), (8.2, 19)):
        dd = np.hypot(x - cx, y - cy)
        dot = np.clip(1 - (dd / 1.8) ** 2, 0, 1)
        add(dot * 0.8, (dot > 0).astype(float))
    # the stud: a raised diamond on the corner
    dia = np.clip(1 - (np.abs(x - 6) + np.abs(y - 6)) / 6.0, 0, 1)
    add(dia * 1.3, (dia > 0).astype(float))
    hf += (smooth_noise(n, n, 8, 7) - 0.5) * 0.05
    rgb = shade(hf * 10)
    # a garnet set in the diamond
    gem = np.clip(1 - (np.abs(x - 6) + np.abs(y - 6)) / 2.6, 0, 1)
    gh = np.sqrt(gem)
    gem_rgb = np.dstack([110 + 145 * gh, 12 + 30 * gh, 18 + 30 * gh])
    hl = np.clip(1 - np.hypot(x - 5.2, y - 5.2) / 0.9, 0, 1)
    gem_rgb += hl[..., None] * np.array([120, 160, 150])
    m = (gem > 0)[..., None]
    rgb = np.where(m, gem_rgb, rgb)
    # a dark outline round the whole ornament so it reads on any ground
    a8 = Image.fromarray((alpha * 255).astype(np.uint8))
    from PIL import ImageFilter
    grown = np.asarray(a8.filter(ImageFilter.MaxFilter(2 * k + 1))) / 255.0
    rgb = np.where((alpha > 0)[..., None], rgb, np.array([12, 8, 2]))
    alpha = np.maximum(alpha, grown * 0.85)
    save(rgb, alpha, (S, S), "corner.tga")


def bezel():
    S, k = 64, 6
    n = S * k
    ys, xs = np.mgrid[0:n, 0:n]
    x, y = (xs + 0.5) / k, (ys + 0.5) / k
    d = np.minimum(np.minimum(x, y), np.minimum(S - x, S - y))   # distance to the outer edge
    W = 6.5
    band = d < W
    hf = np.where(band, np.sin(np.clip(d / W, 0, 1) * math.pi) ** 0.7, 0)
    # a fine groove along the middle of the band
    hf -= np.clip(1 - np.abs(d - W * 0.55) / 0.5, 0, 1) * 0.35 * band
    # rivets in the corners
    for cx in (3.4, S - 3.4):
        for cy in (3.4, S - 3.4):
            r = np.hypot(x - cx, y - cy)
            hf = np.maximum(hf, np.clip(1 - (r / 2.6) ** 2, 0, 1) ** 0.5 * 1.25)
    hf += (smooth_noise(n, n, 16, 11) - 0.5) * 0.08
    rgb = shade(hf * 10)
    alpha = band.astype(float)
    # the outer and inner hairlines in near black
    edge = (d < 0.9) | ((d > W - 0.9) & band)
    rgb = np.where(edge[..., None], np.array([18, 12, 3]), rgb)
    save(rgb, alpha, (S, S), "bezel.tga")


def grain():
    S, k = 64, 4
    n = S * k
    ys, xs = np.mgrid[0:n, 0:n]
    x, y = (xs + 0.5) / n * 2 * math.pi, (ys + 0.5) / n * 2 * math.pi
    # a diamond lattice with a quatrefoil in each cell (tiles: whole periods over the texture)
    lat = np.minimum(np.abs(np.sin(2 * (x + y) / 2)), np.abs(np.sin(2 * (x - y) / 2)))
    lines = np.clip(1 - lat / 0.07, 0, 1)
    fx, fy = np.sin(4 * x), np.sin(4 * y)
    foil = np.clip(1 - np.abs(np.hypot(np.cos(2 * x), np.cos(2 * y)) - 0.35) / 0.12, 0, 1)
    a = np.maximum(lines * 0.9, foil * 0.55)
    a *= 0.75 + 0.5 * smooth_noise(n, n, 8, 5)
    a = np.clip(a + (smooth_noise(n, n, 32, 9) - 0.5) * 0.25, 0, 1)
    rgb = np.full((n, n, 3), 255.0)
    save(rgb, a, (S, S), "grain.tga")


def main():
    trim()
    corner()
    bezel()
    grain()


if __name__ == "__main__":
    main()

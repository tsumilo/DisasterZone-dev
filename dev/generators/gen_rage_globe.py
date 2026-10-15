"""Textures for the warrior swing timer's rage globe (UI/RingFace.lua BuildExtra; art pack 14):
  Media/Warrior/fluid.tga        tileable liquid: soft swirls in grey (0.74..1), tinted by vertex colour and
                                 drifted by texture coordinates, so the rage reads as a body of liquid, not a flat fill
  Media/Warrior/glass_shade.tga  the sphere's shading, drawn over the liquid (BLEND): black, transparent in the middle,
                                 darker toward the rim and the lower right (lit from the top left)
  Media/Warrior/glass_spec.tga   the glass's light (ADD): a crisp specular arc round the upper left, a small hot spot,
                                 and a faint warm bounce along the lower right rim
  Media/Warrior/tank_shade.tga / tank_spec.tga   the same for Sigil's square tank (edges instead of a sphere)
Run (from dev): luaenv\\Scripts\\python.exe generators\\gen_rage_globe.py"""
from pathlib import Path

import numpy as np
from PIL import Image

ADDON = Path(__file__).resolve().parents[2] / "addon" / "DisasterZone"
OUT = ADDON / "Media" / "Warrior"
N = 128          # globe textures
SS = 4           # supersampling


def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def grid(n):
    # x right, y up, -1..1 over the texture (pixel centres)
    c = (np.arange(n) + 0.5) / n * 2 - 1
    x, y = np.meshgrid(c, -c)
    return x, y


def save(rgb, alpha, name):
    """rgb: (n, n, 3) 0..1, alpha (n, n) 0..1 at SS times the size: box-downsampled, written as 32-bit TGA."""
    n = alpha.shape[0] // SS
    a = alpha.reshape(n, SS, n, SS).mean(axis=(1, 3))
    c = (rgb * alpha[..., None]).reshape(n, SS, n, SS, 3).sum(axis=(1, 3))
    w = alpha.reshape(n, SS, n, SS).sum(axis=(1, 3))[..., None]
    c = np.where(w > 0, c / np.maximum(w, 1e-6), 0)    # (colour where the pixel is covered, un-premultiplied)
    img = np.dstack([np.clip(c, 0, 1) * 255, np.clip(a, 0, 1)[..., None] * 255]).round().astype(np.uint8)
    OUT.mkdir(parents=True, exist_ok=True)
    Image.fromarray(img, "RGBA").save(OUT / name)
    print("wrote", OUT / name)


def fluid():
    """Tileable (0.74..1.06 clipped): sums of sines with whole-number frequencies, the x axis warped by y (wisps), stretched sideways."""
    n = 128 * SS
    u = (np.arange(n) + 0.5) / n
    x, y = np.meshgrid(u, u)
    two = 2 * np.pi
    warp = 0.06 * np.sin(two * (2 * y + 1 * x) + 0.7) + 0.04 * np.sin(two * (3 * y - 2 * x) + 2.1)
    xw, yw = x + warp, y + 0.5 * warp
    v = (0.50 * np.sin(two * (1 * xw + 3 * yw) + 0.3)
         + 0.32 * np.sin(two * (2 * xw - 5 * yw) + 1.9)
         + 0.20 * np.sin(two * (3 * xw + 7 * yw) + 4.0)
         + 0.12 * np.sin(two * (5 * xw - 11 * yw) + 2.6)
         + 0.08 * np.sin(two * (7 * xw + 13 * yw) + 5.1))
    v = (v - v.min()) / (v.max() - v.min())
    # thin bright filaments where the field crosses its middle, the rest calm
    fil = np.exp(-((v - 0.55) / 0.05) ** 2) * 0.10
    g = 0.74 + 0.22 * v + fil
    g = np.clip(g, 0, 1)
    rgb = np.dstack([g, g, g])
    save(rgb, np.ones_like(g), "fluid.tga")


def glass_shade():
    x, y = grid(N * SS)
    r = np.hypot(x, y)
    inside = smooth(1.0, 0.985, r)                       # (anti-aliased edge; the mask cuts it too)
    rim = smooth(0.55, 1.0, r) ** 1.7 * 0.82              # darker toward the rim: a sphere, not a disc
    away = np.clip((x - y) / 1.414, 0, 1)                 # away from the light (top left)
    a = np.clip(rim + 0.28 * away * smooth(0.2, 1.0, r), 0, 0.92) * inside
    save(np.zeros(x.shape + (3,)), a, "glass_shade.tga")


def glass_spec():
    x, y = grid(N * SS)
    r = np.hypot(x, y)
    inside = smooth(1.0, 0.985, r)
    ang = np.arctan2(y, x)
    # the arc: a crescent between the rim and a circle pushed toward the lower right, brightest at 125 degrees
    off = np.hypot(x - 0.10, y + 0.12)
    cres = smooth(0.83, 0.89, off) * (1 - smooth(0.93, 0.975, r))
    along = np.exp(-((ang - np.radians(125)) / np.radians(38)) ** 2)
    arc = cres * along * 0.6
    # a small hot spot under the arc
    spot = np.exp(-(((x + 0.40) / 0.11) ** 2 + ((y - 0.46) / 0.075) ** 2)) * 0.85
    # a broad, very soft sheen over the upper half (the glass catching the room)
    sheen = np.exp(-(((x + 0.18) / 0.55) ** 2 + ((y - 0.42) / 0.30) ** 2)) * 0.10
    white = np.clip(arc + spot + sheen, 0, 1)
    # the warm bounce: light through the liquid, back along the lower right rim
    warm = smooth(0.80, 0.94, r) * (1 - smooth(0.95, 0.99, r)) * np.exp(-((ang + np.radians(60)) / np.radians(45)) ** 2) * 0.35
    a = np.clip(white + warm, 0, 1) * inside
    tot = np.maximum(white + warm, 1e-6)
    rgb = (np.dstack([np.ones_like(x)] * 3) * white[..., None]
           + np.dstack([np.ones_like(x), 0.62 * np.ones_like(x), 0.42 * np.ones_like(x)]) * warm[..., None]) / tot[..., None]
    save(rgb, a, "glass_spec.tga")


def tank_shade():
    x, y = grid(N * SS)
    d = 1 - np.maximum(np.abs(x), np.abs(y))              # 0 at the edge, 1 in the middle
    edge = (1 - smooth(0.0, 0.35, d)) ** 1.6 * 0.78
    away = np.clip((x - y) / 1.414, 0, 1)
    a = np.clip(edge + 0.22 * away, 0, 0.9)
    save(np.zeros(x.shape + (3,)), a, "tank_shade.tga")


def tank_spec():
    x, y = grid(N * SS)
    d = 1 - np.maximum(np.abs(x), np.abs(y))
    # a thin lit inner edge along the top and the left, and one soft diagonal streak across the upper left
    lip = smooth(0.02, 0.04, d) * (1 - smooth(0.05, 0.08, d))
    lit = lip * np.clip((-x + y) / 1.414 + 0.3, 0, 1) * 0.6
    t = (x + y) / 1.414                                   # across the diagonal
    streak = np.exp(-((t - 0.38) / 0.10) ** 2) * np.exp(-(((x - y) / 1.414 + 0.45) / 0.45) ** 2) * 0.22
    white = np.clip(lit + streak, 0, 1)
    save(np.ones(x.shape + (3,)), white, "tank_spec.tga")


if __name__ == "__main__":
    fluid()
    glass_shade()
    glass_spec()
    tank_shade()
    tank_spec()

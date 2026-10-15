"""Textures for the warrior swing timer's rage globe (UI/RingFace.lua BuildExtra; art pack 14):
  Media/Warrior/fluid.tga        tileable liquid: soft swirls in grey (0.74..1), tinted by vertex colour and
                                 drifted by texture coordinates, so the rage reads as a body of liquid, not a flat fill
  Media/Warrior/glass_shade.tga  the sphere's shading, drawn over the liquid (BLEND): black, transparent in the middle,
                                 darker toward the rim and the lower right (lit from the top left)
  Media/Warrior/glass_spec.tga   the glass's light (ADD): a crisp specular arc round the upper left, a small hot spot,
                                 and a faint warm bounce along the lower right rim
  Media/Warrior/tank_shade.tga / tank_spec.tga   the same for Sigil's square tank (edges instead of a sphere)
  Media/Warrior/notch.tga        the Heroic Strike marker on the rim: a small bevelled gold pointer (pointing right)
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


def notch():
    """The Heroic Strike marker: a small gold pointer, pointing right (the left one; the right one is the same
    texture mirrored). A bevelled wedge with a rounded back, lit from the top left, a dark outline and a soft shadow.
    Drawn in colour; the HUD dims it while rage is under the line."""
    n = 64 * SS
    c = (np.arange(n) + 0.5) / n
    x, y = np.meshgrid(c, 1 - c)                            # x right, y up, 0..1
    # the wedge: a rounded back (a half disc) at the left, two straight sides meeting at the tip on the right
    tip, back, half = 0.88, 0.30, 0.26
    cy = 0.5
    dy = np.abs(y - cy)
    # signed distance (negative inside), in texture units
    side = (dy - half * np.clip((tip - x) / (tip - back), 0, 1))       # the sides, narrowing to the tip
    body = np.where(x >= back, np.maximum(side, x - tip), np.hypot(x - back, y - cy) - half)
    d = body
    aa = 1.0 / n * 1.5
    inside = smooth(aa, -aa, d)
    outline = smooth(aa, -aa, d - 0.055) * (1 - inside)
    shadow = np.exp(-np.maximum(np.hypot(x - 0.03, y + 0.04) * 0 + (d + 0.0), 0) / 0.05) * 0  # (unused)
    # soft shadow: the shape blurred, offset down right
    sx, sy = x - 0.035, y + 0.045
    sdy = np.abs(sy - cy)
    sside = (sdy - half * np.clip((tip - sx) / (tip - back), 0, 1))
    sbody = np.where(sx >= back, np.maximum(sside, sx - tip), np.hypot(sx - back, sy - cy) - half)
    shadow = smooth(0.09, -0.02, sbody) * 0.55
    # the gold: a bevel (lighter toward the upper edge and the back, darker toward the lower edge), a bright ridge
    # along the middle line toward the tip
    up = (y - cy) / half                                    # -1 bottom .. 1 top
    edge = np.clip(-d / 0.07, 0, 1)                         # 0 at the edge .. 1 deep inside
    # two facets meeting on a ridge: the upper one catches the light, the lower one in shade
    facet = np.where(y >= cy, 0.92 - 0.18 * up, 0.42 + 0.10 * up)
    ridge = np.exp(-((y - cy) / 0.018) ** 2) * 0.35
    lip = (1 - edge) * np.where(y >= cy, 0.25, -0.15)       # a lit upper rim, a darker lower one
    v = np.clip(facet + ridge + lip, 0, 1.2)
    dark, mid, light = np.array([0.37, 0.26, 0.06]), np.array([0.85, 0.62, 0.19]), np.array([1.0, 0.94, 0.70])
    t = v[..., None]
    gold = np.where(t < 0.6, dark + (mid - dark) * (t / 0.6), mid + (light - mid) * np.clip((t - 0.6) / 0.6, 0, 1))
    black = np.zeros_like(gold)
    a_shadow = shadow * (1 - inside) * (1 - outline)
    a = np.clip(inside + outline * 0.95 + a_shadow, 0, 1)
    rgb = (gold * inside[..., None] + black * (outline * 0.95 + a_shadow)[..., None]) / np.maximum(a, 1e-6)[..., None]
    save(rgb, a, "notch.tga")


if __name__ == "__main__":
    fluid()
    glass_shade()
    glass_spec()
    tank_shade()
    tank_spec()
    notch()

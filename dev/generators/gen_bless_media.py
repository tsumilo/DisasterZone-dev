"""Textures for the class tool bars (UI/BarFace.lua; the Blessings and Totem bars):
  Media/Blessings/ring.tga    a white anti-aliased ring (the time ring: the cooldown swipe and its track)
  Media/Blessings/bezel.tga   the Gilded theme's worked gold bezel (art pack 7): a bevelled gold ring, lit from the
                              top left, with a soft sheen running round it; drawn in colour, never tinted
Run (from dev): luaenv\\Scripts\\python.exe generators\\gen_bless_media.py"""
import math
from pathlib import Path

from PIL import Image

ADDON = Path(__file__).resolve().parents[2] / "addon" / "DisasterZone"
OUT = ADDON / "Media" / "Blessings"
SIZE, SS = 64, 8                 # texture size, supersampling per axis
OUTER, WIDTH = 31.0, 4.2         # ring outer radius and stroke, in texture pixels
B_OUTER, B_WIDTH = 31.5, 6.6     # bezel: 4 px of a 38 px cell


def ring():
    big = SIZE * SS
    im = Image.new("L", (big, big), 0)
    px = im.load()
    c = big / 2
    ro, ri = OUTER * SS, (OUTER - WIDTH) * SS
    for y in range(big):
        for x in range(big):
            d = math.hypot(x + 0.5 - c, y + 0.5 - c)
            if ri <= d <= ro:
                px[x, y] = 255
    alpha = im.resize((SIZE, SIZE), Image.LANCZOS)
    out = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


DARK, MID, LIGHT = (94, 67, 14), (200, 150, 48), (255, 241, 186)


def gold(v):
    v = max(0.0, min(1.0, v))
    a, b, t = (DARK, MID, v / 0.55) if v < 0.55 else (MID, LIGHT, (v - 0.55) / 0.45)
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def bezel():
    n = SIZE * 4                 # colour wants less supersampling than coverage
    im = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    px = im.load()
    c = n / 2
    k = n / SIZE
    ro, ri = B_OUTER * k, (B_OUTER - B_WIDTH) * k
    light = math.radians(135)    # from the top left (y grows downward)
    for y in range(n):
        for x in range(n):
            dx, dy = x + 0.5 - c, c - (y + 0.5)
            d = math.hypot(dx, dy)
            if not (ri <= d <= ro):
                continue
            t = (d - ri) / (ro - ri)                 # 0 inner edge .. 1 outer edge
            a = math.atan2(dy, dx)
            facing = math.cos(a - light)             # +1 toward the light
            bevel = (t - 0.5) * 2                    # the outer half leans out, the inner half in
            shade = 0.5 + 0.42 * facing * bevel
            sheen = 0.5 + 0.5 * math.cos(3 * a + 1.1)
            v = 0.22 + 0.5 * shade + 0.28 * sheen
            if t < 0.14 or t > 0.86:                 # a dark line on both edges
                v *= 0.45
            px[x, y] = gold(v) + (255,)
    return im.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    ring().save(OUT / "ring.tga")
    print("wrote", OUT / "ring.tga")
    bezel().save(OUT / "bezel.tga")
    print("wrote", OUT / "bezel.tga")


if __name__ == "__main__":
    main()

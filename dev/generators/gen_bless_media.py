"""Textures for the paladin blessings bar (UI/BlessingsBar.lua):
  Media/Blessings/ring.tga   a white anti-aliased ring (the class circles' time ring: the cooldown swipe and its track)
Run (from dev): luaenv\\Scripts\\python.exe generators\\gen_bless_media.py"""
import math
from pathlib import Path

from PIL import Image

ADDON = Path(__file__).resolve().parents[2] / "addon" / "DisasterZone"
OUT = ADDON / "Media" / "Blessings"
SIZE, SS = 64, 8                 # texture size, supersampling per axis
OUTER, WIDTH = 31.0, 4.2         # ring outer radius and stroke, in texture pixels


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


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    ring().save(OUT / "ring.tga")
    print("wrote", OUT / "ring.tga")


if __name__ == "__main__":
    main()

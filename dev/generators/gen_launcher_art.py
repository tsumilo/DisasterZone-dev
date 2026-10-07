"""Draws the DisasterZone seal into addon/DisasterZone/Media/Launcher/ (art pack 4).

seal.tga    - 128x128: the full seal (purple disc, gold rim, dotted inner ring, "DZ" in gold serif) on transparent.
              The addon's icon in the AddOns list (.toc IconTexture) and on shared chat links (UI/Share.lua).
seal_mm.tga - 64x64: the same seal without its gold rim, filling the square edge to edge, for the minimap button
              (LibDBIcon draws its own round border over it).
"""
import math
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "addon", "DisasterZone", "Media", "Launcher")
OS = 4  # oversampling

PURPLE_IN = (58, 40, 84)
PURPLE_OUT = (30, 21, 46)
GOLD = (214, 176, 92)
GOLD_LIGHT = (246, 228, 170)
FONT = "C:/Windows/Fonts/georgiab.ttf"


def disc(d, c, r, inner, outer):
    # a radial fade from inner (centre) to outer (edge), drawn as concentric circles
    steps = int(r)
    for i in range(steps, 0, -1):
        t = i / steps
        col = tuple(int(inner[k] + (outer[k] - inner[k]) * t ** 1.6) for k in range(3))
        d.ellipse([c - i, c - i, c + i, c + i], fill=col + (255,))


def draw(size, rim):
    S = size * OS
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = S / 2
    r = S / 2 - (S * 0.03 if rim else 0)
    if rim:
        d.ellipse([c - r, c - r, c + r, c + r], fill=GOLD + (255,))
        r -= S * 0.06
    disc(d, c, r, PURPLE_IN, PURPLE_OUT)
    # the dotted inner ring
    ri = r * 0.78
    n = 36
    dot = S * 0.012
    for i in range(n):
        a = 2 * math.pi * i / n
        x, y = c + ri * math.cos(a), c + ri * math.sin(a)
        d.ellipse([x - dot, y - dot, x + dot, y + dot], fill=GOLD + (220,))
    # "DZ", centred on its ink box
    font = ImageFont.truetype(FONT, int(S * (0.40 if rim else 0.46)))
    l, t, rr, b = d.textbbox((0, 0), "DZ", font=font)
    x, y = c - (l + rr) / 2, c - (t + b) / 2
    d.text((x + S * 0.012, y + S * 0.018), "DZ", font=font, fill=(10, 6, 16, 200))  # soft drop under the letters
    d.text((x, y), "DZ", font=font, fill=GOLD_LIGHT + (255,))
    return im.resize((size, size), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    draw(128, True).save(os.path.join(OUT, "seal.tga"))
    draw(64, False).save(os.path.join(OUT, "seal_mm.tga"))
    draw(256, True).save(os.path.join(HERE, "..", "art", "launcher_seal_preview.png"))
    print("wrote", OUT)


if __name__ == "__main__":
    main()

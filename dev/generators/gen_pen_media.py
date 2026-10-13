"""Smooth shapes for the pen (UI/CombatTextPen.lua: the boss mods and combat text looks), drawn 4x and scaled down so
their edges are anti-aliased, white on clear (tinted in the game):
  Media/Pen/disc.tga          a filled disc (256)
  Media/Pen/ring1.tga ..      rings whose stroke is 1.5% / 3% / 5% / 8% / 12% of the texture (ring1 512 px, the
  ring4.tga                   others 256): the pen picks the one nearest the stroke it needs; the ring's outer edge is
                              1 px inside the texture
  Media/Pen/ringglow.tga      a soft blurred ring at 36% of the size from the centre (glow under a ring; drawn additive: its colour is its alpha)
  Media/Pen/ringsoft.tga      the same, white, the blur in its alpha (a sweep's glow: blended normally)
  Media/Pen/pill.tga          a capsule 256 x 64 (3-sliced: the ends are the 32 px at each side, the middle stretches)
  Media/Pen/pillline.tga      its outline, 3 px
Run (from dev): luaenv\\Scripts\\python.exe generators\\gen_pen_media.py"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ADDON = Path(__file__).resolve().parents[2] / "addon" / "DisasterZone"
OUT = ADDON / "Media" / "Pen"
SS = 4
RINGS = [("ring1", 512, 0.015), ("ring2", 256, 0.03), ("ring3", 256, 0.05), ("ring4", 256, 0.08), ("ring5", 256, 0.12)]


def white(alpha):
    im = Image.new("RGBA", alpha.size, (255, 255, 255, 0))
    im.putalpha(alpha)
    return im


def disc(size):
    big = Image.new("L", (size * SS, size * SS), 0)
    d = ImageDraw.Draw(big)
    m = SS
    d.ellipse((m, m, size * SS - 1 - m, size * SS - 1 - m), fill=255)
    return big.resize((size, size), Image.LANCZOS)


def ring(size, stroke):
    big = Image.new("L", (size * SS, size * SS), 0)
    d = ImageDraw.Draw(big)
    m = SS
    w = max(SS, int(round(stroke * size * SS)))
    d.ellipse((m, m, size * SS - 1 - m, size * SS - 1 - m), fill=255)
    d.ellipse((m + w, m + w, size * SS - 1 - m - w, size * SS - 1 - m - w), fill=0)
    return big.resize((size, size), Image.LANCZOS)


def glow_ring(size, at, stroke):
    """A ring whose middle is `at` x the size from the centre: room round it for a blur to fade out."""
    big = Image.new("L", (size * SS, size * SS), 0)
    d = ImageDraw.Draw(big)
    c, r, w = size * SS / 2, at * size * SS, stroke * size * SS / 2
    d.ellipse((c - r - w, c - r - w, c + r + w, c + r + w), fill=255)
    d.ellipse((c - r + w, c - r + w, c + r - w, c + r - w), fill=0)
    return big.resize((size, size), Image.LANCZOS)


def pill(w, h, line=0):
    big = Image.new("L", (w * SS, h * SS), 0)
    d = ImageDraw.Draw(big)
    m = SS
    d.rounded_rectangle((m, m, w * SS - 1 - m, h * SS - 1 - m), radius=(h * SS - 2 * m) // 2, fill=255)
    if line:
        k = line * SS
        d.rounded_rectangle((m + k, m + k, w * SS - 1 - m - k, h * SS - 1 - m - k), radius=(h * SS - 2 * m) // 2 - k, fill=0)
    return big.resize((w, h), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    white(disc(256)).save(OUT / "disc.tga")
    for name, size, stroke in RINGS:
        white(ring(size, stroke)).save(OUT / (name + ".tga"))
    g = glow_ring(256, 0.36, 0.05).filter(ImageFilter.GaussianBlur(9))
    # (the blur spreads it thin: lift it so its middle is near full)
    g = g.point(lambda v: min(255, int(v * 2.2)))
    # (drawn additive: its colour is its alpha, so a transparent pixel adds nothing whatever the blend)
    Image.merge("RGBA", (g, g, g, g)).save(OUT / "ringglow.tga")
    # (the same glow, white with the blur in its alpha: for the game's sweep, which blends normally)
    white(g).save(OUT / "ringsoft.tga")
    white(pill(256, 64)).save(OUT / "pill.tga")
    white(pill(256, 64, line=3)).save(OUT / "pillline.tga")
    for f in sorted(OUT.glob("*.tga")):
        print("wrote", f, Image.open(f).size)


main()

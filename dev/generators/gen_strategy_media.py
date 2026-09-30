"""Draws the strategy board's shape textures (Addendum K) into addon/CDLoot/Media/Strategy/.

disc.tga  - a white filled circle with a soft edge (zones, tinted by vertex colour)
ring.tga  - a white circle outline (zone borders)
arrow.tga - a white arrowhead pointing up (arrow ends, rotated in game)
The shapes are 128x128 32-bit TGA (power of two, straight alpha), drawn 4x oversampled for smooth edges.
tools.tga - the board's toolbar icons: a 256x256 grid of 4x4 cells of 64px, white on transparent (tinted in game),
            in the order of TOOL_ICONS below (UI/StrategyBoard.lua picks them by index).
"""
import math
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "addon", "CDLoot", "Media", "Strategy")
SIZE, OS = 128, 4


def shape(draw_fn):
    big = Image.new("L", (SIZE * OS, SIZE * OS), 0)
    draw_fn(ImageDraw.Draw(big), SIZE * OS)
    alpha = big.resize((SIZE, SIZE), Image.LANCZOS)
    img = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
    img.putalpha(alpha)
    return img


def disc(d, n):
    m = n * 0.02
    d.ellipse([m, m, n - m, n - m], fill=255)


def ring(d, n):
    m = n * 0.02
    w = n * 0.06
    d.ellipse([m, m, n - m, n - m], fill=255)
    d.ellipse([m + w, m + w, n - m - w, n - m - w], fill=0)


def arrow(d, n):
    d.polygon([(n * 0.5, n * 0.06), (n * 0.92, n * 0.94), (n * 0.5, n * 0.74), (n * 0.08, n * 0.94)], fill=255)


# --- toolbar icons, drawn in a 64-unit box scaled by k ---
def _w(k, v):
    return max(1, int(round(v * k)))


def _pts(k, pts):
    return [(x * k, y * k) for x, y in pts]


def ic_select(d, k):
    d.polygon(_pts(k, [(18, 6), (18, 52), (29, 42), (37, 58), (45, 54), (37, 39), (51, 39)]), fill=255)


def ic_pan(d, k):
    c = 32
    d.line(_pts(k, [(c, 12), (c, 52)]), fill=255, width=_w(k, 5))
    d.line(_pts(k, [(12, c), (52, c)]), fill=255, width=_w(k, 5))
    for x, y, ang in ((c, 5, 0), (c, 59, 180), (5, c, 270), (59, c, 90)):
        a = math.radians(ang)
        tri = [(0, 0), (-9, 11), (9, 11)]
        d.polygon(_pts(k, [(x + px * math.cos(a) - py * math.sin(a), y + px * math.sin(a) + py * math.cos(a))
                           for px, py in tri]), fill=255)


def ic_circle(d, k):
    d.ellipse(_pts(k, [(10, 10), (54, 54)]), outline=255, width=_w(k, 5))


def ic_rect(d, k):
    d.rectangle(_pts(k, [(9, 14), (55, 50)]), outline=255, width=_w(k, 5))


def ic_arrow(d, k):
    d.line(_pts(k, [(12, 52), (42, 22)]), fill=255, width=_w(k, 5))
    d.polygon(_pts(k, [(54, 10), (28, 16), (48, 36)]), fill=255)


def ic_line(d, k):
    d.line(_pts(k, [(12, 52), (52, 12)]), fill=255, width=_w(k, 5))
    for x, y in ((12, 52), (52, 12)):
        d.ellipse(_pts(k, [(x - 6, y - 6), (x + 6, y + 6)]), fill=255)


def ic_icon(d, k):
    # a map pin
    d.ellipse(_pts(k, [(15, 5), (49, 39)]), fill=255)
    d.polygon(_pts(k, [(17, 28), (47, 28), (32, 59)]), fill=255)
    d.ellipse(_pts(k, [(25, 15), (39, 29)]), fill=0)


def _glyph(d, k, ch, size):
    f = ImageFont.truetype("arialbd.ttf", int(size * k))
    l, t, r, b = d.textbbox((0, 0), ch, font=f)
    d.text(((64 * k - (r - l)) / 2 - l, (64 * k - (b - t)) / 2 - t), ch, font=f, fill=255)


def ic_text(d, k):
    _glyph(d, k, "T", 48)


def ic_undo(d, k):
    d.arc(_pts(k, [(14, 16), (54, 56)]), 190, 90, fill=255, width=_w(k, 5))
    d.polygon(_pts(k, [(4, 34), (26, 34), (15, 18)]), fill=255)


def ic_redo(d, k):
    d.arc(_pts(k, [(10, 16), (50, 56)]), 90, 350, fill=255, width=_w(k, 5))
    d.polygon(_pts(k, [(60, 34), (38, 34), (49, 18)]), fill=255)


def ic_help(d, k):
    d.ellipse(_pts(k, [(5, 5), (59, 59)]), outline=255, width=_w(k, 4))
    _glyph(d, k, "?", 36)


def ic_trash(d, k):
    d.rectangle(_pts(k, [(11, 13), (53, 19)]), fill=255)
    d.rectangle(_pts(k, [(25, 7), (39, 13)]), fill=255)
    d.polygon(_pts(k, [(15, 22), (49, 22), (46, 58), (18, 58)]), fill=255)
    for x in (25, 32, 39):
        d.line(_pts(k, [(x, 28), (x, 52)]), fill=0, width=_w(k, 3))


def ic_gear(d, k):
    c = 32
    for i in range(8):
        a = math.radians(i * 45)
        pts = []
        for da, r in ((-13, 18), (-9, 29), (9, 29), (13, 18)):
            aa = a + math.radians(da)
            pts.append((c + r * math.cos(aa), c + r * math.sin(aa)))
        d.polygon(_pts(k, pts), fill=255)
    d.ellipse(_pts(k, [(12, 12), (52, 52)]), fill=255)
    d.ellipse(_pts(k, [(23, 23), (41, 41)]), fill=0)


def ic_chevron(d, k):
    d.line(_pts(k, [(14, 24), (32, 42), (50, 24)]), fill=255, width=_w(k, 7), joint="curve")


TOOL_ICONS = [ic_select, ic_pan, ic_circle, ic_rect, ic_arrow, ic_line, ic_icon, ic_text,
              ic_undo, ic_redo, ic_help, ic_trash, ic_gear, ic_chevron]


def tool_atlas():
    cell = 64
    big = Image.new("L", (cell * 4 * OS, cell * 4 * OS), 0)
    for i, fn in enumerate(TOOL_ICONS):
        sub = Image.new("L", (cell * OS, cell * OS), 0)
        fn(ImageDraw.Draw(sub), OS)
        big.paste(sub, ((i % 4) * cell * OS, (i // 4) * cell * OS))
    alpha = big.resize((cell * 4, cell * 4), Image.LANCZOS)
    img = Image.new("RGBA", alpha.size, (255, 255, 255, 0))
    img.putalpha(alpha)
    return img


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in (("disc", disc), ("ring", ring), ("arrow", arrow)):
        shape(fn).save(os.path.join(OUT, name + ".tga"))
        print("wrote", name)
    tool_atlas().save(os.path.join(OUT, "tools.tga"))
    print("wrote tools")

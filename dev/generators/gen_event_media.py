"""Draws the event builder's piece shapes and the badge ring into addon/DisasterZone/Media/Events/ (art pack 4).

pieces.tga - a 256x256 atlas of white shapes on transparent, tinted in game (SetVertexColor): every shape comes as a
             fill and as an edge (its 1px outline, drawn over the fill in the category's edge colour). Cells (x, y, w, h
             in px of the 256 texture, PIECE_CELLS below; UI/EventPieces.lua reads the same numbers):
             dome      the cap on top of a "when" piece (Scratch's hat), 96 x 16 at 1x
             tab       the puzzle tab under a piece (and the notch over one, drawn dark), 24 x 8
             hexL/hexR the pointed ends of a yes/no piece or hole, 12 x 24
             rndL/rndR the round ends of a value piece or blank, 12 x 24
             The shapes are drawn 4x oversampled at 2x their game size (the textures are drawn at half their pixels).
ring.tga   - the badge frame: a 128x128 ring with a metallic sweep baked into its brightness (white = lit), tinted per
             frame (gold, silver, bronze, fel, arcane, blood), and its inner shadow.
"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "addon", "DisasterZone", "Media", "Events")
OS = 4          # oversampling
K = 2           # texture px per game px

# The game sizes (px at scale 1) and where each shape's fill and edge sit in the atlas (texture px = 2x game px).
# UI/EventPieces.lua (SHAPE) reads the same numbers.
SHAPES = [  # name, game w, game h, fill x, fill y, edge x, edge y
    ("dome", 80, 12, 0, 0, 0, 24),
    ("tab", 20, 6, 0, 48, 48, 48),
    ("hexL", 10, 21, 0, 64, 24, 64),
    ("hexR", 10, 21, 48, 64, 72, 64),
    ("rndL", 10, 19, 96, 64, 120, 64),
    ("rndR", 10, 19, 144, 64, 168, 64),
]


def dome(d, w, h, edge, lw):
    # a flat-bottomed half ellipse; the edge is its arc and its two short sides
    box = [0, 0, w - 1, 2 * h]
    if edge:
        d.arc(box, 180, 360, fill=255, width=lw)
        d.line([(0, h), (0, h * 2)], fill=255, width=lw)
        d.line([(w - 1, h), (w - 1, h * 2)], fill=255, width=lw)
    else:
        d.pieslice(box, 180, 360, fill=255)


def tab(d, w, h, edge, lw):
    # a short bar with round bottom corners (radius = h)
    r = h
    if edge:
        d.line([(lw / 2, 0), (lw / 2, h - r)], fill=255, width=lw)
        d.line([(w - 1 - lw / 2, 0), (w - 1 - lw / 2, h - r)], fill=255, width=lw)
        d.arc([0, h - 2 * r, 2 * r, h], 90, 180, fill=255, width=lw)
        d.arc([w - 1 - 2 * r, h - 2 * r, w - 1, h], 0, 90, fill=255, width=lw)
        d.line([(r, h - lw / 2), (w - 1 - r, h - lw / 2)], fill=255, width=lw)
    else:
        d.rounded_rectangle([0, -r, w - 1, h - 1], radius=r, fill=255)


def hexL(d, w, h, edge, lw):
    pts = [(w, 0), (0, h / 2), (w, h)]
    if edge:
        d.line(pts, fill=255, width=lw, joint="curve")
    else:
        d.polygon(pts + [(w + 2, h), (w + 2, 0)], fill=255)


def hexR(d, w, h, edge, lw):
    pts = [(-1, 0), (w - 1, h / 2), (-1, h)]
    if edge:
        d.line(pts, fill=255, width=lw, joint="curve")
    else:
        d.polygon(pts, fill=255)


def rndL(d, w, h, edge, lw):
    box = [0, 0, 2 * w, h - 1]
    if edge:
        d.arc(box, 90, 270, fill=255, width=lw)
    else:
        d.pieslice(box, 90, 270, fill=255)


def rndR(d, w, h, edge, lw):
    box = [-w - 1, 0, w - 1, h - 1]
    if edge:
        d.arc(box, 270, 90, fill=255, width=lw)
    else:
        d.pieslice(box, 270, 450, fill=255)


DRAW = {"dome": dome, "tab": tab, "hexL": hexL, "hexR": hexR, "rndL": rndL, "rndR": rndR}


def pieces():
    big = Image.new("L", (256 * OS, 256 * OS), 0)
    for name, gw, gh, fx, fy, ex, ey in SHAPES:
        for edge in (False, True):
            w, h = gw * K * OS, gh * K * OS
            sub = Image.new("L", (w, h), 0)
            DRAW[name](ImageDraw.Draw(sub), w, h, edge, K * OS)   # a 1 game px line
            big.paste(sub, ((ex if edge else fx) * OS, (ey if edge else fy) * OS))
    alpha = big.resize((256, 256), Image.LANCZOS)
    img = Image.new("RGBA", (256, 256), (255, 255, 255, 0))
    img.putalpha(alpha)
    return img


def ring():
    """The badge frame: a ring whose brightness sweeps like polished metal (two highlights, two shadows)."""
    n = 128 * OS
    c = n / 2
    ro, ri = n * 0.49, n * 0.40
    mask = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(mask)
    d.ellipse([c - ro, c - ro, c + ro, c + ro], fill=255)
    d.ellipse([c - ri, c - ri, c + ri, c + ri], fill=0)
    lum = Image.new("L", (n, n), 0)
    px = lum.load()
    step = OS
    for y in range(0, n, step):
        for x in range(0, n, step):
            a = math.atan2(y - c, x - c)
            r = math.hypot(x - c, y - c)
            sweep = 0.5 + 0.5 * math.cos(2 * (a + 2.2))            # two bright and two dark arcs
            bevel = 1 - abs((r - (ri + ro) / 2) / ((ro - ri) / 2))  # brighter in the middle of the band
            v = 0.42 + 0.48 * sweep + 0.18 * bevel
            v = max(0, min(1, v))
            for yy in range(y, min(y + step, n)):
                for xx in range(x, min(x + step, n)):
                    px[xx, yy] = int(v * 255)
    lum = lum.filter(ImageFilter.GaussianBlur(OS))
    # a dark hairline inside and outside the band, so the ring reads on any icon
    edge = Image.new("L", (n, n), 0)
    e = ImageDraw.Draw(edge)
    e.ellipse([c - ro, c - ro, c + ro, c + ro], outline=255, width=OS * 2)
    e.ellipse([c - ri - OS, c - ri - OS, c + ri + OS, c + ri + OS], outline=255, width=OS * 2)
    lum.paste(0, mask=edge)
    alpha = mask.resize((128, 128), Image.LANCZOS)
    rgb = lum.resize((128, 128), Image.LANCZOS)
    img = Image.merge("RGBA", (rgb, rgb, rgb, alpha))
    return img


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    pieces().save(os.path.join(OUT, "pieces.tga"))
    print("wrote pieces")
    ring().save(os.path.join(OUT, "ring.tga"))
    print("wrote ring")

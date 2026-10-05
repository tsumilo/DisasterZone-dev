"""The ranged role icon (Media/Roles/ranged.tga): the game's LFG damage icon (UI-LFG-ICON-ROLES, the sword on a red disc
in a gold ring) with the sword painted out and a bow with an arrow drawn in its place, in the sword's steel. The game
has no ranged role icon; melee keeps the sword. Source: the client's texture, cached by tools/ui_look.py as
dev/art/casc/tex/interface_lfgframe_ui_lfg_icon_roles.png (256x256, 67 px cells; damage = column 2, row 2).
Writes a 64x64 32-bit TGA (straight alpha)."""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "art", "casc", "tex", "interface_lfgframe_ui_lfg_icon_roles.png")
OUT = os.path.join(HERE, "..", "..", "addon", "DisasterZone", "Media", "Roles")
CELL = 67
OS = 8


def disc_profile(cell, cx, cy, r_in):
    """The red disc's colour by radius, from the quadrants the sword leaves free (upper left, lower right)."""
    prof = []
    for r in range(int(r_in) + 2):
        acc, n = [0, 0, 0, 0], 0
        for deg in list(range(105, 170, 5)) + list(range(285, 350, 5)):
            a = math.radians(deg)
            x, y = cx + r * math.cos(a), cy - r * math.sin(a)
            if 0 <= x < cell.width and 0 <= y < cell.height:
                p = cell.getpixel((int(round(x)), int(round(y))))
                acc = [acc[i] + p[i] for i in range(4)]
                n += 1
        prof.append(tuple(int(v / max(n, 1)) for v in acc))
    return prof


def steel(size, draw_fn):
    """A glyph in the sword's steel: grey-blue lit toward the top right, a dark edge."""
    big = size * OS
    mask = Image.new("L", (big, big), 0)
    draw_fn(ImageDraw.Draw(mask), OS)
    edge = mask.filter(ImageFilter.MaxFilter(OS + 1 if OS % 2 == 0 else OS))
    shade = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    px = shade.load()
    mk, ed = mask.load(), edge.load()
    for y in range(big):
        for x in range(big):
            if mk[x, y] > 0:
                t = (x + (big - y)) / (2 * big)
                v = int(108 + 104 * t)
                px[x, y] = (v, v + 6, min(255, v + 22), mk[x, y])
            elif ed[x, y] > 0:
                px[x, y] = (20, 6, 6, int(ed[x, y] * 0.9))
    return shade.resize((size, size), Image.LANCZOS)


def bow(d, k):
    # in the 67 px cell's units (scaled by k): the string on the falling diagonal, the limbs bulging to the upper
    # right, an arrow along the sword's diagonal (fletching lower left, head upper right)
    def P(x, y):
        return (x * k, y * k)
    pts = []
    for i in range(49):
        t = i / 48
        x = (1 - t) ** 2 * 21 + 2 * (1 - t) * t * 47 + t * t * 45
        y = (1 - t) ** 2 * 21 + 2 * (1 - t) * t * 19 + t * t * 45
        pts.append(P(x, y))
    d.line(pts, fill=255, width=int(4.2 * k), joint="curve")               # the limbs
    for x, y in ((21, 21), (45, 45)):                                       # their tips
        d.ellipse([P(x - 2.1, y - 2.1), P(x + 2.1, y + 2.1)], fill=255)
    d.line([P(21, 21), P(45, 45)], fill=255, width=int(1.3 * k))          # the string
    d.line([P(22, 44), P(43, 23)], fill=255, width=int(2.6 * k))          # the shaft
    d.polygon([P(49, 17), P(39, 22), P(44, 27)], fill=255)                 # the head
    d.polygon([P(24, 42), P(17, 43), P(21, 39)], fill=255)                 # fletching
    d.polygon([P(24, 42), P(23, 49), P(27, 45)], fill=255)


def main():
    sheet = Image.open(SRC).convert("RGBA")
    cell = sheet.crop((CELL, CELL, 2 * CELL, 2 * CELL))
    # the disc's centre and inner radius (inside the gold ring)
    cx, cy, r_in = CELL / 2 - 0.5, CELL / 2 - 0.5, 22
    prof = disc_profile(cell, cx, cy, r_in)
    out = cell.copy()
    px = out.load()
    for y in range(CELL):
        for x in range(CELL):
            r = math.hypot(x - cx, y - cy)
            if r <= r_in:
                px[x, y] = prof[min(int(r), len(prof) - 1)]
    glyph = steel(CELL, bow)
    out.alpha_composite(glyph)
    out = out.resize((64, 64), Image.LANCZOS)
    os.makedirs(OUT, exist_ok=True)
    out.save(os.path.join(OUT, "ranged.tga"))
    print("wrote ranged.tga")


if __name__ == "__main__":
    main()

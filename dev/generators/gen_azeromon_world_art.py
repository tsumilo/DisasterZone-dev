"""Tiles for Azeromon's real map (World/World.lua), appended to the atlas by gen_azeromon_art.py.

Ground edges are the accepted Red Voxel dirt path's own hand-drawn grass rim: every new ground class (road, cobbles,
vineyard rows, rocky ground, cliffs, sand, water) is that same 13-piece set with the path's bricks replaced by the
class's fill and its dark rim recoloured, so all edges share one style. Props are drawn here in the same flat,
outlined manner as the rest of gen_azeromon_art.py. Tree crowns (bigger than a tile) go to their own texture,
Media/Azeromon/crowns.tga."""
import colorsys
import os
import random

from PIL import Image, ImageDraw

PIECES = (("tl", 8, 1), ("t", 9, 1), ("tr", 10, 1), ("l", 8, 2), ("c", 9, 2), ("r", 10, 2),
          ("bl", 8, 3), ("b", 9, 3), ("br", 10, 3), ("inw", 11, 0), ("ine", 12, 0), ("isw", 11, 1), ("ise", 12, 1))


def _hsv(p):
    r, g, b = p[:3]
    return colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)


def _is_grass(p):
    h, s, v = _hsv(p)
    return 0.17 <= h <= 0.45 and s > 0.18


def tile(fn, seed=1):
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    fn(ImageDraw.Draw(img), img, random.Random(seed))
    return img


def fill_from(base, spots):
    """A 16x16 fill: base colour plus (colour, count, size) speckles (tileable: wraps)."""
    def fn(d, img, rnd):
        d.rectangle((0, 0, 15, 15), fill=base)
        px = img.load()
        for col, n, sz in spots:
            for _ in range(n):
                x, y = rnd.randrange(16), rnd.randrange(16)
                for dx in range(sz):
                    for dy in range(sz):
                        px[(x + dx) % 16, (y + dy) % 16] = col
    return fn


def road_fill(d, img, rnd):
    fill_from((212, 196, 150, 255), [((196, 178, 132, 255), 26, 2), ((168, 150, 110, 255), 10, 1),
                                     ((232, 222, 186, 255), 10, 1), ((150, 134, 100, 255), 4, 2)])(d, img, rnd)


def cobble_fill(d, img, rnd):
    mortar, stone, hi, lo = (112, 106, 98, 255), (172, 168, 160, 255), (198, 194, 186, 255), (142, 138, 130, 255)
    d.rectangle((0, 0, 15, 15), fill=mortar)
    rows = [(0, 5), (5, 10), (10, 16)]
    for i, (y0, y1) in enumerate(rows):
        x = -2 if i % 2 else 0
        while x < 16:
            w = rnd.choice((5, 6, 7))
            d.rectangle((x + 1, y0 + 1, x + w - 1, y1 - 1), fill=stone)
            d.line((x + 1, y0 + 1, x + w - 2, y0 + 1), fill=hi)
            d.line((x + 1, y1 - 1, x + w - 1, y1 - 1), fill=lo)
            x += w


def crops_fill(d, img, rnd):
    soil, soil_d = (126, 88, 54, 255), (100, 68, 40, 255)
    leaf, leaf_d, grape, stake = (82, 150, 56, 255), (52, 108, 40, 255), (110, 60, 130, 255), (92, 62, 34, 255)
    d.rectangle((0, 0, 15, 15), fill=soil)
    for y in (3, 11):
        d.line((0, y + 3, 15, y + 3), fill=soil_d)
        d.line((0, y, 15, y), fill=stake)
        for x in range(0, 16, 3):
            d.rectangle((x, y - 2, x + 2, y), fill=leaf)
            d.point((x + 1, y - 2), fill=leaf_d)
            d.point((x, y), fill=leaf_d)
        d.point(((y * 3) % 16, y + 1), fill=grape)
        d.point(((y * 3 + 7) % 16, y + 1), fill=grape)


def rocky_fill(d, img, rnd):
    fill_from((152, 142, 124, 255), [((128, 118, 102, 255), 14, 2), ((176, 168, 150, 255), 12, 1),
                                     ((108, 98, 84, 255), 8, 1)])(d, img, rnd)


def cliff_fill(d, img, rnd):
    base, dark, hi = (114, 106, 98, 255), (80, 74, 68, 255), (142, 134, 124, 255)
    d.rectangle((0, 0, 15, 15), fill=base)
    for x in range(0, 16, 4):
        o = rnd.randrange(3)
        d.line((x + o, 0, x + o + rnd.choice((-1, 0, 1)), 15), fill=dark)
        d.line((x + o + 1, 0, x + o + 1, 6), fill=hi)
    for _ in range(6):
        x, y = rnd.randrange(16), rnd.randrange(16)
        d.point((x, y), fill=hi)


def sand_fill(d, img, rnd):
    fill_from((224, 206, 152, 255), [((204, 184, 128, 255), 18, 1), ((240, 228, 186, 255), 8, 1)])(d, img, rnd)


def shaded(img, f):
    out = img.copy()
    px = out.load()
    for y in range(16):
        for x in range(16):
            r, g, b, a = px[x, y]
            px[x, y] = (min(255, int(r * f[0])), min(255, int(g * f[1])), min(255, int(b * f[2])), a)
    return out


def autotile_set(R, prefix, fill, rim, grass=None):
    """The 13 path pieces with the bricks replaced by `fill` and the dark rim by `rim`."""
    out = []
    for n, c, r in PIECES:
        src = R.crop((c * 16, r * 16, c * 16 + 16, r * 16 + 16))
        img = src.copy()
        sp, fp = src.load(), fill.load()
        px = img.load()
        gp = grass.load() if grass else None
        for y in range(16):
            for x in range(16):
                p = sp[x, y]
                if p[3] == 0:
                    continue
                if _is_grass(p):
                    if gp:
                        px[x, y] = gp[x, y] if not _is_grass(gp[x, y]) else _regrass(p, gp[x, y])
                    continue
                v = _hsv(p)[2]
                px[x, y] = rim if v < 0.45 else fp[x, y]
        out.append((prefix + n, img, 1, 1))
    return out


def _regrass(p, g):
    return g


def recolor_green(img, h_target, s_mul, v_mul):
    out = img.copy()
    px = out.load()
    for y in range(out.size[1]):
        for x in range(out.size[0]):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if 0.17 <= h <= 0.45 and s > 0.18:
                nr, ng, nb = colorsys.hsv_to_rgb(h_target, min(1, s * s_mul), min(1, v * v_mul))
                px[x, y] = (int(nr * 255), int(ng * 255), int(nb * 255), a)
    return out


# --- building blocks (the abbey's slate roof, stone fronts) ---------------------------------------------------
SLATE, SLATE_D, SLATE_H, OUTLINE = (108, 118, 140, 255), (78, 86, 104, 255), (140, 150, 170, 255), (44, 40, 52, 255)


def roof_piece(name):
    def fn(d, img, rnd):
        d.rectangle((0, 0, 15, 15), fill=SLATE)
        for y in range(1, 16, 4):                       # shingle rows
            d.line((0, y + 2, 15, y + 2), fill=SLATE_D)
            off = 0 if (y // 4) % 2 else 2
            for x in range(off, 16, 4):
                d.line((x, y, x, y + 2), fill=SLATE_D)
            d.line((0, y, 15, y), fill=SLATE_H)
        top = name in ("tl", "t", "tr")
        left = name in ("tl", "l", "bl")
        right = name in ("tr", "r", "br")
        if top:
            d.rectangle((0, 0, 15, 1), fill=OUTLINE)
            d.line((0, 2, 15, 2), fill=SLATE_H)
        if left:
            d.rectangle((0, 0, 1, 15), fill=OUTLINE)
        if right:
            d.rectangle((14, 0, 15, 15), fill=OUTLINE)
        if name == "inw":
            d.rectangle((0, 0, 1, 1), fill=OUTLINE)
        if name == "ine":
            d.rectangle((14, 0, 15, 1), fill=OUTLINE)
        if name == "isw":
            d.rectangle((0, 14, 1, 15), fill=OUTLINE)
        if name == "ise":
            d.rectangle((14, 14, 15, 15), fill=OUTLINE)
    return fn


STONE, STONE_D, STONE_H = (196, 186, 164, 255), (150, 140, 120, 255), (220, 212, 192, 255)


def front(window=False, door=False):
    def fn(d, img, rnd):
        d.rectangle((0, 0, 15, 15), fill=STONE)
        d.rectangle((0, 0, 15, 2), fill=(70, 64, 70, 255))          # the roof's shadow
        for y in (6, 10, 14):
            d.line((0, y, 15, y), fill=STONE_D)
        for i, y in enumerate((3, 7, 11)):
            for x in range(2 if i % 2 else 0, 16, 5):
                d.line((x, y, x, y + 2), fill=STONE_D)
        d.line((0, 15, 15, 15), fill=(96, 88, 76, 255))
        if window:
            d.rectangle((4, 4, 11, 11), fill=(60, 50, 44, 255))
            d.rectangle((5, 5, 10, 10), fill=(120, 170, 220, 255))
            d.line((7, 5, 7, 10), fill=(60, 50, 44, 255))
            d.line((5, 7, 10, 7), fill=(60, 50, 44, 255))
            d.point((5, 5), fill=(200, 230, 250, 255))
        if door:
            d.rectangle((3, 3, 12, 15), fill=(60, 44, 30, 255))
            d.rectangle((4, 4, 11, 15), fill=(132, 86, 46, 255))
            for x in (6, 9):
                d.line((x, 4, x, 15), fill=(100, 64, 34, 255))
            d.point((10, 10), fill=(230, 200, 90, 255))
            d.arc((3, 1, 12, 8), 180, 360, fill=(60, 44, 30, 255))
    return fn


def stonewall(d, img, rnd):
    cobble_fill(d, img, rnd)
    d.rectangle((0, 0, 15, 15), outline=(70, 66, 62, 255))
    d.line((1, 1, 14, 1), fill=(210, 206, 198, 255))


def bridge(d, img, rnd):
    wood, dark, hi = (156, 106, 60, 255), (100, 64, 34, 255), (184, 134, 84, 255)
    d.rectangle((0, 0, 15, 15), fill=wood)
    for x in range(0, 16, 4):
        d.line((x, 0, x, 15), fill=dark)
        d.line((x + 1, 0, x + 1, 15), fill=hi)
    for y in (3, 12):
        d.point((2, y), fill=dark)
        d.point((10, y), fill=dark)


# --- props ------------------------------------------------------------------------------------------------------
INK = (40, 30, 26, 255)


def trunk(d, img, rnd):
    bark, bark_d, bark_h = (112, 72, 40, 255), (78, 48, 26, 255), (140, 96, 56, 255)
    d.ellipse((2, 11, 13, 15), fill=(40, 70, 28, 140))                   # shade on the grass
    d.polygon([(5, 15), (6, 3), (10, 3), (11, 15)], fill=bark, outline=INK)
    d.line((7, 4, 7, 14), fill=bark_d)
    d.line((9, 4, 9, 13), fill=bark_h)
    d.polygon([(3, 15), (6, 12), (6, 15)], fill=bark, outline=INK)        # roots
    d.polygon([(13, 15), (10, 12), (10, 15)], fill=bark, outline=INK)


def stump(d, img, rnd):
    d.ellipse((2, 9, 14, 15), fill=(112, 72, 40, 255), outline=INK)
    d.ellipse((3, 7, 13, 12), fill=(196, 160, 110, 255), outline=INK)
    d.ellipse((6, 8, 10, 11), outline=(150, 112, 70, 255))


def log(d, img, rnd):
    d.rectangle((1, 7, 13, 13), fill=(112, 72, 40, 255), outline=INK)
    d.line((2, 9, 12, 9), fill=(80, 50, 28, 255))
    d.ellipse((11, 6, 15, 14), fill=(196, 160, 110, 255), outline=INK)


def bush(d, img, rnd):
    g, gd, gh = (84, 156, 56, 255), (54, 112, 40, 255), (130, 196, 80, 255)
    d.ellipse((1, 4, 15, 15), fill=gd, outline=INK)
    d.ellipse((2, 4, 12, 12), fill=g)
    for x, y in ((4, 6), (8, 5), (6, 9), (10, 8)):
        d.point((x, y), fill=gh)
        d.point((x + 1, y), fill=gh)


def vines(d, img, rnd):
    d.line((3, 2, 3, 15), fill=(92, 62, 34, 255))
    d.line((12, 2, 12, 15), fill=(92, 62, 34, 255))
    d.line((2, 4, 13, 4), fill=(92, 62, 34, 255))
    d.ellipse((1, 3, 14, 12), fill=(70, 140, 50, 255), outline=INK)
    for x, y in ((4, 9), (9, 8), (7, 11)):
        d.rectangle((x, y, x + 1, y + 2), fill=(110, 56, 128, 255))


def cabbage(d, img, rnd):
    d.ellipse((4, 7, 12, 14), fill=(120, 180, 90, 255), outline=INK)
    d.arc((5, 8, 11, 13), 200, 340, fill=(80, 140, 60, 255))


def sack(d, img, rnd):
    d.polygon([(4, 15), (3, 9), (6, 5), (10, 5), (13, 9), (12, 15)], fill=(196, 168, 112, 255), outline=INK)
    d.line((6, 6, 10, 6), fill=(140, 110, 70, 255))
    d.line((7, 9, 8, 13), fill=(170, 140, 90, 255))


def lumber(d, img, rnd):
    for y, c in ((12, (150, 104, 60, 255)), (9, (168, 120, 72, 255)), (6, (150, 104, 60, 255))):
        d.rectangle((1, y, 14, y + 2), fill=c, outline=INK)


def cart(d, img, rnd):
    d.rectangle((2, 5, 13, 10), fill=(150, 100, 56, 255), outline=INK)
    d.line((3, 7, 12, 7), fill=(110, 70, 38, 255))
    d.ellipse((2, 9, 7, 14), fill=(90, 60, 34, 255), outline=INK)
    d.ellipse((9, 9, 14, 14), fill=(90, 60, 34, 255), outline=INK)


def well(d, img, rnd):
    d.ellipse((2, 8, 14, 15), fill=(160, 156, 148, 255), outline=INK)
    d.ellipse((4, 9, 12, 13), fill=(40, 60, 90, 255))
    d.line((3, 2, 3, 11), fill=(100, 64, 34, 255))
    d.line((13, 2, 13, 11), fill=(100, 64, 34, 255))
    d.polygon([(1, 3), (8, 0), (15, 3)], fill=(150, 60, 50, 255), outline=INK)


def dummy(d, img, rnd):
    d.line((8, 6, 8, 15), fill=(100, 64, 34, 255), width=2)
    d.rectangle((4, 7, 12, 9), fill=(100, 64, 34, 255))
    d.ellipse((5, 1, 11, 7), fill=(210, 180, 120, 255), outline=INK)
    d.rectangle((6, 8, 10, 13), fill=(200, 170, 110, 255), outline=INK)


def rack(d, img, rnd):
    d.rectangle((2, 6, 13, 7), fill=(110, 70, 38, 255))
    d.rectangle((2, 12, 13, 13), fill=(110, 70, 38, 255))
    for x in (4, 8, 11):
        d.line((x, 2, x, 14), fill=(180, 190, 200, 255))
        d.point((x, 2), fill=(230, 235, 240, 255))


def scarecrow(d, img, rnd):
    d.line((8, 4, 8, 15), fill=(100, 64, 34, 255), width=2)
    d.line((2, 7, 14, 7), fill=(100, 64, 34, 255), width=2)
    d.ellipse((5, 1, 11, 7), fill=(220, 190, 110, 255), outline=INK)
    d.polygon([(4, 2), (8, -1), (12, 2)], fill=(120, 80, 40, 255))
    d.rectangle((6, 8, 10, 12), fill=(150, 60, 50, 255), outline=INK)


def tent(d, img, rnd):
    d.polygon([(1, 14), (8, 2), (15, 14)], fill=(200, 180, 140, 255), outline=INK)
    d.polygon([(6, 14), (8, 8), (10, 14)], fill=(70, 50, 36, 255))


def shed(d, img, rnd):
    d.rectangle((1, 6, 14, 15), fill=(150, 104, 60, 255), outline=INK)
    d.polygon([(0, 7), (8, 1), (15, 7)], fill=(120, 60, 50, 255), outline=INK)
    d.rectangle((6, 9, 9, 15), fill=(80, 54, 32, 255))


def statue(d, img, rnd):
    d.rectangle((3, 11, 12, 15), fill=(150, 146, 140, 255), outline=INK)
    d.ellipse((5, 1, 10, 6), fill=(196, 192, 186, 255), outline=INK)
    d.rectangle((5, 6, 10, 11), fill=(180, 176, 170, 255), outline=INK)


def banner(d, img, rnd):
    d.line((3, 0, 3, 15), fill=(100, 64, 34, 255))
    d.rectangle((4, 1, 12, 10), fill=(40, 70, 160, 255), outline=INK)
    d.polygon([(4, 10), (8, 13), (12, 10)], fill=(40, 70, 160, 255))
    d.rectangle((7, 4, 9, 6), fill=(230, 200, 90, 255))


def awning(d, img, rnd):
    for x in range(0, 16, 4):
        d.rectangle((x, 0, x + 1, 9), fill=(170, 50, 50, 255))
        d.rectangle((x + 2, 0, x + 3, 9), fill=(230, 220, 200, 255))
    d.line((0, 10, 15, 10), fill=INK)


def campfire(d, img, rnd):
    d.ellipse((2, 9, 14, 15), fill=(110, 104, 96, 255), outline=INK)
    d.line((4, 13, 12, 9), fill=(100, 64, 34, 255), width=2)
    d.line((4, 9, 12, 13), fill=(100, 64, 34, 255), width=2)
    d.polygon([(5, 11), (8, 2), (11, 11)], fill=(240, 140, 40, 255))
    d.polygon([(7, 11), (8, 5), (9, 11)], fill=(255, 230, 120, 255))


def tools(d, img, rnd):
    d.line((3, 2, 12, 14), fill=(110, 70, 38, 255), width=2)
    d.polygon([(10, 12), (15, 11), (13, 15)], fill=(170, 176, 184, 255), outline=INK)


def crown_sprite(size, seed):
    """A tree crown `size` px across (Elwynn's broad oaks / pines seen from above), on transparency."""
    rnd = random.Random(seed)
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = size / 2
    dark, mid, light, hi = (46, 96, 36, 255), (70, 132, 46, 255), (96, 164, 58, 255), (140, 200, 84, 255)
    # outline + body: overlapping leaf clusters on a disc
    clusters = []
    n = max(5, int(size / 6))
    for i in range(n):
        a = 2 * 3.14159 * i / n + rnd.random() * 0.4
        rr = r * (0.55 + rnd.random() * 0.15)
        import math
        cx, cy = r + math.cos(a) * rr * 0.6, r + math.sin(a) * rr * 0.6
        cr = r * (0.36 + rnd.random() * 0.08)
        clusters.append((cx, cy, cr))
    clusters.append((r, r, r * 0.55))
    for cx, cy, cr in clusters:
        d.ellipse((cx - cr - 1, cy - cr - 1, cx + cr + 1, cy + cr + 1), fill=(24, 44, 18, 255))
    for cx, cy, cr in clusters:
        d.ellipse((cx - cr, cy - cr, cx + cr, cy + cr), fill=dark)
    for cx, cy, cr in clusters:                     # lit from the north-west
        d.ellipse((cx - cr * 0.9 - cr * 0.15, cy - cr * 0.9 - cr * 0.15, cx + cr * 0.6, cy + cr * 0.6), fill=mid)
    for cx, cy, cr in clusters:
        d.ellipse((cx - cr * 0.7 - cr * 0.25, cy - cr * 0.7 - cr * 0.25, cx + cr * 0.1, cy + cr * 0.1), fill=light)
    px = img.load()
    for _ in range(size * size // 40):
        x, y = rnd.randrange(size), rnd.randrange(size)
        if px[x, y][3] and px[x, y] == light:
            px[x, y] = hi
    return img


CROWN_SIZES = (32, 48, 64, 80, 96, 112, 128)


def build_crowns(out_dir):
    """crowns.tga: one crown per size in CROWN_SIZES, left to right in a 512 x 128 strip... laid out on a
    1024 x 128 sheet (power-of-two), each in a 128 x 128 cell, centred."""
    sheet = Image.new("RGBA", (1024, 128), (0, 0, 0, 0))
    for i, s in enumerate(CROWN_SIZES):
        c = crown_sprite(s, 100 + s)
        sheet.paste(c, (i * 128 + (128 - s) // 2, (128 - s) // 2), c)
    sheet.save(os.path.join(out_dir, "crowns.tga"))
    print("wrote crowns.tga", sheet.size)


def railing(d, img, rnd):
    bridge(d, img, rnd)
    d.rectangle((0, 5, 15, 9), fill=(120, 78, 42, 255), outline=INK)
    for x in (2, 13):
        d.rectangle((x - 1, 3, x + 1, 11), fill=(92, 58, 30, 255), outline=INK)


def sfloor(d, img, rnd):
    base, joint, hi = (176, 172, 164, 255), (138, 134, 126, 255), (200, 196, 188, 255)
    d.rectangle((0, 0, 15, 15), fill=base)
    d.line((0, 7, 15, 7), fill=joint)
    d.line((0, 15, 15, 15), fill=joint)
    d.line((7, 0, 7, 7), fill=joint)
    d.line((15, 8, 15, 15), fill=joint)
    d.line((0, 0, 6, 0), fill=hi)
    d.line((8, 8, 14, 8), fill=hi)


def swall(d, img, rnd):
    base, dark, hi = (128, 122, 116, 255), (88, 84, 80, 255), (160, 154, 146, 255)
    d.rectangle((0, 0, 15, 15), fill=base)
    for y in (4, 9, 14):
        d.line((0, y, 15, y), fill=dark)
    for i, y in enumerate((0, 5, 10)):
        for x in range(3 if i % 2 else 0, 16, 7):
            d.line((x, y, x, y + 3), fill=dark)
    d.line((0, 0, 15, 0), fill=hi)


def world_art(R, T):
    """[(name, img, w, h)] for the atlas."""
    out = []
    grass = R.crop((8 * 16, 0, 9 * 16, 16))
    fills = {
        "road_": (tile(road_fill, 2), (150, 132, 96, 255)),
        "cobble_": (tile(cobble_fill, 3), (92, 86, 80, 255)),
        "crops_": (tile(crops_fill, 4), (92, 62, 34, 255)),
        "rocky_": (tile(rocky_fill, 5), (96, 88, 76, 255)),
        "cliff_": (tile(cliff_fill, 6), (58, 52, 48, 255)),
        "sand_": (tile(sand_fill, 7), (176, 156, 104, 255)),
    }
    for prefix, (fill, rim) in fills.items():
        out += autotile_set(R, prefix, fill, rim)
    water = T.crop((5 * 16, 2 * 16, 6 * 16, 3 * 16)).convert("RGBA")
    out += autotile_set(R, "water_", water, (226, 236, 240, 255))
    out.append(("shallow_c", shaded(water, (1.25, 1.18, 1.05)), 1, 1))
    out.append(("egrass_d1", recolor_green(R.crop((8 * 16, 0, 9 * 16, 16)), 0.31, 1.05, 0.74), 1, 1))
    out.append(("egrass_d2", recolor_green(R.crop((9 * 16, 0, 10 * 16, 16)), 0.31, 1.05, 0.74), 1, 1))
    for n in ("tl", "t", "tr", "l", "c", "r", "bl", "b", "br", "inw", "ine", "isw", "ise"):
        out.append(("roof_" + n, tile(roof_piece(n)), 1, 1))
    out.append(("bwall", tile(front()), 1, 1))
    out.append(("bwindow", tile(front(window=True)), 1, 1))
    out.append(("door", tile(front(door=True)), 1, 1))
    out.append(("stonewall", tile(stonewall, 8), 1, 1))
    out.append(("bridge", tile(bridge), 1, 1))
    out.append(("railing", tile(railing), 1, 1))
    out.append(("sfloor", tile(sfloor), 1, 1))
    out.append(("swall", tile(swall), 1, 1))
    for name, fn in (("trunk", trunk), ("stump", stump), ("log", log), ("bush", bush), ("vines", vines),
                     ("cabbage", cabbage), ("sack", sack), ("lumber", lumber), ("cart", cart), ("well", well),
                     ("dummy", dummy), ("rack", rack), ("n_scarecrow", scarecrow), ("n_tent", tent),
                     ("shed", shed), ("statue", statue), ("banner", banner), ("awning", awning),
                     ("campfire", campfire), ("tools", tools)):
        out.append((name, tile(fn), 1, 1))
    return out

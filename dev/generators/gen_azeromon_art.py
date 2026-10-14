"""Builds the Azeromon overworld art (32-bit TGA, power-of-two sizes) into addon/DisasterZone/Media/Azeromon/
and the tile index addon/DisasterZone/Games/Azeromon/Atlas.lua.

Sources (dev/art/src, downloaded from OpenGameArt; credits in NOTICE.md):
  basictiles.png, characters.png, things.png  "Tiny 16: Basic" by Lanea Zimmerman (Sharm), CC-BY 3.0/4.0, OGA-BY 3.0
  redvoxel_tilemap.png                          "Pokemon-inspired 16x16 tiles" by Red_Voxel, CC-BY-SA 3.0

Outputs:
  atlas.tga   256x256, 16x16 slots of 16px tiles; slot i sits at column i % 16, row i // 16
  chars.tga   characters.png padded to 256x128 (walk frames: 3 columns per character, rows down/left/right/up)
  platform.tga 128x32 battle platform (procedural)

Run: luaenv\\Scripts\\python.exe generators\\gen_azeromon_art.py   (needs Pillow)
"""
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
SRC = os.path.join(DEV, "art", "src")
ADDON = os.path.join(os.path.dirname(DEV), "addon", "DisasterZone")
OUT = os.path.join(ADDON, "Media", "Azeromon")
ATLAS_LUA = os.path.join(ADDON, "Games", "Azeromon", "Atlas.lua")


def load(name):
    return Image.open(os.path.join(SRC, name)).convert("RGBA")


T = load("basictiles.png")
R = load("redvoxel_tilemap.png")
TH = load("things.png")
CH = load("characters.png")

# name -> (sheet, col, row). Multi-tile stamps are expanded to name_x_y.
TILES = [
    ("grass1", R, 8, 0), ("grass2", R, 9, 0),
    ("path_tl", R, 8, 1), ("path_t", R, 9, 1), ("path_tr", R, 10, 1),
    ("path_l", R, 8, 2), ("path_c", R, 9, 2), ("path_r", R, 10, 2),
    ("path_bl", R, 8, 3), ("path_b", R, 9, 3), ("path_br", R, 10, 3),
    ("path_inw", R, 11, 0), ("path_ine", R, 12, 0), ("path_isw", R, 11, 1), ("path_ise", R, 12, 1),
    ("tall_tl", R, 0, 6), ("tall_t", R, 1, 6), ("tall_tr", R, 2, 6),
    ("tall_l", R, 0, 7), ("tall_c", R, 1, 7), ("tall_r", R, 2, 7),
    ("tall_bl", R, 0, 8), ("tall_b", R, 1, 8), ("tall_br", R, 2, 8),
    ("tree", T, 4, 9), ("pine", T, 6, 3), ("oak", T, 6, 4), ("twintrees", T, 5, 9),
    ("water1", T, 5, 1), ("water2", T, 5, 2),
    ("sign", T, 3, 8), ("flowers", T, 4, 1), ("rock", T, 2, 7),
    ("floor", T, 0, 2), ("floor2", T, 1, 1), ("rug", T, 1, 2), ("wall", T, 4, 0), ("wall2", T, 0, 0),
    ("bed", T, 5, 6), ("table", T, 6, 6), ("dresser", T, 7, 6), ("pot", T, 3, 3),
    ("chest", T, 4, 4), ("chest_open", T, 3, 4), ("void", T, 6, 2), ("stairs", T, 0, 7),
    ("idoor", T, 0, 6), ("counter", T, 7, 4),
    ("fire1", TH, 9, 4), ("fire2", TH, 10, 4), ("fire3", TH, 11, 4),
    ("torch1", TH, 0, 4), ("torch2", TH, 1, 4), ("torch3", TH, 2, 4),
]
STAMPS = [
    ("house", R, 0, 0, 5, 6),
    ("bigtree", R, 5, 3, 3, 3),
    ("mailbox", R, 8, 4, 1, 2),
]


def tga(img, name):
    os.makedirs(OUT, exist_ok=True)
    img.save(os.path.join(OUT, name + ".tga"))
    print("wrote", name + ".tga", img.size)


ATLAS_H = 512          # 16 columns x 32 rows of 16px tiles (power of two)


def build_atlas():
    atlas = Image.new("RGBA", (256, ATLAS_H), (0, 0, 0, 0))
    index = {}

    def add(name, sheet, c, r):
        i = len(index)
        if i >= 16 * (ATLAS_H // 16):
            raise SystemExit("atlas full")
        atlas.paste(sheet.crop((c * 16, r * 16, c * 16 + 16, r * 16 + 16)), ((i % 16) * 16, (i // 16) * 16))
        index[name] = i

    for name, sheet, c, r in TILES:
        add(name, sheet, c, r)
    for name, sheet, c0, r0, w, h in STAMPS:
        for y in range(h):
            for x in range(w):
                add("%s_%d_%d" % (name, x, y), sheet, c0 + x, r0 + y)
    # Westfall + Forest's Edge (appended so earlier slots never move)
    for name, img, w, h in westfall_art() + mine_art() + town_art() + duskwood_art() + jungle_art() + hideout_art() + hall_art():
        if w == 1 and h == 1:
            add(name, img, 0, 0)
        else:
            for y in range(h):
                for x in range(w):
                    add("%s_%d_%d" % (name, x, y), img, x, y)
    # the world-art pass (appended, so earlier slots never move): forest-floor shade under the map's outer
    # trees, and the soft shadow drawn under people
    for g in ("grass1", "wgrass1", "dgrass1", "jgrass1"):
        add(g + "_shade", shade_tile(atlas, index[g]), 0, 0)
    add("shadow", shadow_tile(), 0, 0)
    redraw_props(atlas, index)
    clean_stamp_margins(atlas, index)
    soften_tree_rings(atlas, index)
    # the forest beyond a map's edge: the shaded floor with darker trees tucked in, repeating seamlessly (the same
    # pattern the ground baker draws between neighbouring trees inside the map)
    for g, tree in (("grass1", "tree"), ("wgrass1", "wtree"), ("dgrass1", "dtree"), ("jgrass1", "jtree")):
        add(g + "_forest", forest_tile(atlas, index[g + "_shade"], index[tree]), 0, 0)
    tga(atlas, "atlas")
    return index


# ---------------------------------------------------------------------------------------------------------------
# World art pass (2026-10-14): hand-shaded props replace the old procedural ones in their own slots, and stamps lose
# the grass they were painted on, so they sit on the baked ground (gen_azeromon_ground.py) without a square of
# other grass around them.
# ---------------------------------------------------------------------------------------------------------------
import azeromon_props  # noqa: E402
import azeromon_interiors  # noqa: E402

SHADE = 0.74            # forest floor under the trees (the ground baker uses the same)
GRASS_TILES = ("grass1", "grass2", "wgrass1", "wgrass2", "dgrass1", "dgrass2", "jgrass1", "jgrass2")
CLEAN_STAMPS = ("house", "farmhouse", "stonehouse", "ruinhouse", "darkhouse", "bbhouse", "bigtree", "wbigtree",
                "dbigtree", "jbigtree", "mailbox", "scarecrow", "windmill")


def _cell_box(i):
    return ((i % 16) * 16, (i // 16) * 16, (i % 16) * 16 + 16, (i // 16) * 16 + 16)


def _put_cell(atlas, i, img):
    box = _cell_box(i)
    atlas.paste(Image.new("RGBA", (16, 16), (0, 0, 0, 0)), box[:2])
    atlas.paste(img, box[:2])


def shade_tile(atlas, i):
    src = atlas.crop(_cell_box(i))
    r, g, b, a = src.split()
    dark = lambda ch: ch.point(lambda v: int(v * SHADE))
    return Image.merge("RGBA", (dark(r), dark(g), dark(b), a))


def shadow_tile():
    """a soft oval: a darker middle, lighter ends"""
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    for y, x0, x1, core in ((13, 5, 10, (6, 9)), (14, 3, 12, (5, 10)), (15, 5, 10, (6, 9))):
        for x in range(x0, x1 + 1):
            img.putpixel((x, y), (8, 18, 24, 92 if core[0] <= x <= core[1] else 48))
    return img


RING = (117, 113, 97)
RING_TREES = ("tree", "pine", "oak", "twintrees", "wtree")


def soften_tree_rings(atlas, index):
    """Tiny 16's trees stand on an opaque grey dirt ring: make it a see-through shadow on whatever ground is below"""
    for name in RING_TREES:
        box = _cell_box(index[name])
        cell = atlas.crop(box)
        px = cell.load()
        for y in range(8, 16):
            for x in range(16):
                r, g, b, a = px[x, y]
                if a and abs(r - RING[0]) + abs(g - RING[1]) + abs(b - RING[2]) < 6:
                    px[x, y] = (10, 24, 14, 96)
        atlas.paste(Image.new("RGBA", (16, 16), (0, 0, 0, 0)), box[:2])
        atlas.paste(cell, box[:2])


def forest_tile(atlas, shade_i, tree_i):
    out = atlas.crop(_cell_box(shade_i)).copy()
    r, g, b, a = atlas.crop(_cell_box(tree_i)).split()
    dim = lambda ch, k: ch.point(lambda v: int(v * k))
    back = Image.merge("RGBA", (dim(r, 0.62), dim(g, 0.7), dim(b, 0.74), a))
    big = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    for dx, dy in ((8, -3), (0, 8)):                     # right neighbour's gap, the gap below
        for ox in (-16, 0, 16):                          # every wrapped copy, so the tile repeats seamlessly
            for oy in (-16, 0, 16):
                big.alpha_composite(back, (24 + dx + ox, 24 + dy + oy))
    out.alpha_composite(big.crop((24, 24, 40, 40)))
    return out


def redraw_props(atlas, index):
    furniture = {name: fn().image() for name, fn in azeromon_interiors.FURNITURE.items()}
    for name, img in list(azeromon_props.images().items()) + list(furniture.items()):
        if name.rpartition("_")[0] in ("ruinwall", "cavewall", "arenawall"):
            continue                                   # walls are baked into the ground, by their neighbours
        w, h = img.size[0] // 16, img.size[1] // 16
        if w == 1 and h == 1:
            _put_cell(atlas, index[name], img)
        else:
            for y in range(h):
                for x in range(w):
                    _put_cell(atlas, index["%s_%d_%d" % (name, x, y)], img.crop((x * 16, y * 16, x * 16 + 16, y * 16 + 16)))


def clean_stamp_margins(atlas, index):
    pal = set()
    for g in GRASS_TILES:
        cell = atlas.crop(_cell_box(index[g])).load()
        for y in range(16):
            for x in range(16):
                pal.add(cell[x, y][:3])
    pal = list(pal)

    def grassy(c):
        if c[3] < 10:
            return True
        for p in pal:
            if abs(p[0] - c[0]) + abs(p[1] - c[1]) + abs(p[2] - c[2]) < 14:
                return True
        return False

    for kind in CLEAN_STAMPS:
        w = 0
        while "%s_%d_0" % (kind, w) in index:
            w += 1
        h = 0
        while "%s_0_%d" % (kind, h) in index:
            h += 1
        if not w or not h:
            continue
        comp = Image.new("RGBA", (w * 16, h * 16))
        for y in range(h):
            for x in range(w):
                comp.paste(atlas.crop(_cell_box(index["%s_%d_%d" % (kind, x, y)])), (x * 16, y * 16))
        W, H = comp.size
        px = comp.load()
        seen = set()
        stack = [(x, 0) for x in range(W)] + [(x, H - 1) for x in range(W)] + [(0, y) for y in range(H)] + [(W - 1, y) for y in range(H)]
        while stack:
            x, y = stack.pop()
            if (x, y) in seen or not (0 <= x < W and 0 <= y < H) or not grassy(px[x, y]):
                continue
            seen.add((x, y))
            px[x, y] = (0, 0, 0, 0)
            stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
        for y in range(h):
            for x in range(w):
                _put_cell(atlas, index["%s_%d_%d" % (kind, x, y)], comp.crop((x * 16, y * 16, x * 16 + 16, y * 16 + 16)))


# ---------------------------------------------------------------------------------------------------------------
# Westfall: the Elwynn tiles recoloured to dry gold, plus a few hand-drawn props (fences, hay, pumpkins, a
# scarecrow, a windmill, gnoll tents). Greens are detected by hue; light greens become grass/wheat colours,
# dark greens (roofs, leaves) get their own colour.
# ---------------------------------------------------------------------------------------------------------------
import colorsys  # noqa: E402


def recolor(img, light, dark=None, light_min_v=0.62, sat_mul=1.0, dark_rows=None):
    """Maps green pixels: light ones (value >= light_min_v) toward `light`, darker ones toward `dark`.
    Colours are target (h, s, v-scale) triples; the pixel keeps its own brightness pattern."""
    out = img.copy()
    px = out.load()
    for yy in range(out.size[1]):
        for xx in range(out.size[0]):
            r, g, b, a = px[xx, yy]
            if a == 0:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if not (0.17 <= h <= 0.45 and s > 0.18):
                continue
            if dark_rows is not None:            # region split: rows above dark_rows are roof, below is ground
                tgt = dark if yy < dark_rows else light
            else:
                tgt = light if (v >= light_min_v or dark is None) else dark
            th, ts, tv = tgt
            nr, ng, nb = colorsys.hsv_to_rgb(th, min(1, s * ts * sat_mul), min(1, v * tv))
            px[xx, yy] = (int(nr * 255), int(ng * 255), int(nb * 255), a)
    return out


def crop(sheet, c, r, w=1, h=1):
    return sheet.crop((c * 16, r * 16, (c + w) * 16, (r + h) * 16))


GOLD = (0.115, 0.62, 0.98)        # dry Westfall grass
WHEAT = (0.115, 0.95, 1.30)       # ripe wheat
ROOF_RED = (0.015, 1.1, 0.95)     # farmhouse roof
ROOF_SLATE = (0.61, 0.35, 0.95)   # Sentinel Hill slate roofs
OLIVE = (0.14, 0.55, 0.70)        # dry leaves


def draw(w, h, fn):
    img = Image.new("RGBA", (w * 16, h * 16), (0, 0, 0, 0))
    fn(ImageDraw.Draw(img), img)
    return img


def fence(d, img):
    wood, dark = (150, 100, 55, 255), (92, 58, 30, 255)
    for y in (5, 10):
        d.rectangle((0, y, 15, y + 1), fill=wood)
        d.line((0, y + 2, 15, y + 2), fill=dark)
    for x in (2, 12):
        d.rectangle((x, 3, x + 1, 14), fill=wood)
        d.line((x + 2, 3, x + 2, 14), fill=dark)
        d.point((x, 3), fill=dark)


def hay(d, img):
    d.ellipse((1, 4, 14, 15), fill=(160, 120, 40, 255))
    d.ellipse((2, 3, 13, 13), fill=(222, 184, 80, 255))
    d.ellipse((4, 4, 10, 8), fill=(246, 214, 120, 255))
    for x in (4, 7, 10):
        d.line((x, 9, x + 1, 12), fill=(176, 136, 50, 255))


def pumpkin(d, img):
    d.ellipse((2, 6, 14, 15), fill=(168, 72, 20, 255))
    d.ellipse((3, 6, 13, 14), fill=(232, 120, 36, 255))
    d.line((8, 7, 8, 14), fill=(190, 88, 24, 255))
    d.line((5, 8, 5, 13), fill=(200, 96, 28, 255))
    d.line((11, 8, 11, 13), fill=(200, 96, 28, 255))
    d.rectangle((7, 3, 8, 6), fill=(70, 110, 40, 255))
    d.point((9, 4), fill=(90, 140, 50, 255))


def scarecrow(d, img):
    wood = (120, 80, 40, 255)
    d.rectangle((7, 6, 8, 31), fill=wood)                 # post
    d.rectangle((1, 13, 14, 14), fill=wood)               # arms
    d.rectangle((4, 12, 11, 22), fill=(170, 60, 50, 255)) # shirt
    d.line((4, 17, 11, 17), fill=(130, 40, 36, 255))
    for x in (1, 14):
        d.line((x, 14, x, 17), fill=(222, 184, 80, 255))  # straw hands
    d.ellipse((4, 4, 11, 11), fill=(214, 186, 130, 255))  # sack head
    d.point((6, 7), fill=(40, 30, 20, 255))
    d.point((9, 7), fill=(40, 30, 20, 255))
    d.line((6, 9, 9, 9), fill=(90, 60, 40, 255))
    d.rectangle((2, 3, 13, 4), fill=(150, 110, 50, 255))  # hat brim
    d.rectangle((5, 0, 10, 3), fill=(176, 136, 60, 255))  # hat top


def windmill(d, img):
    # stone tower (2 wide x 3 tall tiles = 32 x 48), dark door, four sails
    stone, shade, line = (196, 184, 160, 255), (150, 138, 118, 255), (110, 100, 86, 255)
    d.polygon([(8, 47), (24, 47), (21, 16), (11, 16)], fill=stone)
    d.polygon([(16, 47), (24, 47), (21, 16), (16, 16)], fill=shade)
    for y in range(20, 46, 6):
        d.line((10, y, 23, y), fill=line)
    d.rectangle((13, 38, 18, 47), fill=(80, 56, 36, 255))
    d.polygon([(9, 17), (23, 17), (16, 9)], fill=(150, 70, 50, 255))   # cap
    hub = (16.0, 12.0)
    sail, frame = (238, 230, 206, 255), (112, 84, 56, 255)
    for ux, uy in ((0.707, 0.707), (-0.707, 0.707), (0.707, -0.707), (-0.707, -0.707)):
        px_, py_ = -uy, ux                                     # perpendicular
        def at(t, w):
            return (hub[0] + ux * t + px_ * w, hub[1] + uy * t + py_ * w)
        d.polygon([at(3, 0), at(14, 0), at(14, 4), at(3, 4)], fill=sail)
        d.line([at(0, 0), at(15, 0)], fill=frame, width=1)
        d.line([at(8, 0), at(8, 4)], fill=frame)
    d.ellipse((14, 11, 18, 15), fill=(90, 60, 40, 255))


def tent(d, img):
    hide, dark, pole = (150, 110, 70, 255), (104, 72, 44, 255), (70, 48, 30, 255)
    d.polygon([(1, 31), (30, 31), (16, 3)], fill=hide)
    d.polygon([(16, 31), (30, 31), (16, 3)], fill=dark)
    d.polygon([(12, 31), (20, 31), (16, 17)], fill=(40, 26, 18, 255))    # opening
    d.line((16, 0, 16, 5), fill=pole)
    d.line((14, 1, 13, 0), fill=pole)
    for y in (12, 20):
        d.line((10 - (y - 12) // 3, y, 22 + (y - 12) // 3, y), fill=(176, 136, 90, 255))


def westfall_art():
    out = []
    gold = lambda im: recolor(im, GOLD)                              # noqa: E731
    out.append(("wgrass1", gold(crop(R, 8, 0)), 1, 1))
    out.append(("wgrass2", gold(crop(R, 9, 0)), 1, 1))
    for n, c, r in (("tl", 8, 1), ("t", 9, 1), ("tr", 10, 1), ("l", 8, 2), ("c", 9, 2), ("r", 10, 2),
                    ("bl", 8, 3), ("b", 9, 3), ("br", 10, 3), ("inw", 11, 0), ("ine", 12, 0), ("isw", 11, 1),
                    ("ise", 12, 1)):
        out.append(("wpath_" + n, gold(crop(R, c, r)), 1, 1))
    for n, c, r in (("tl", 0, 6), ("t", 1, 6), ("tr", 2, 6), ("l", 0, 7), ("c", 1, 7), ("r", 2, 7),
                    ("bl", 0, 8), ("b", 1, 8), ("br", 2, 8)):
        out.append(("wtall_" + n, recolor(crop(R, c, r), WHEAT, (0.10, 0.9, 0.9), light_min_v=0.0), 1, 1))
    out.append(("farmhouse", recolor(crop(R, 0, 0, 5, 6), GOLD, ROOF_RED, dark_rows=78), 5, 6))
    out.append(("stonehouse", recolor(crop(R, 0, 0, 5, 6), GOLD, ROOF_SLATE, dark_rows=78), 5, 6))
    out.append(("wbigtree", recolor(crop(R, 5, 3, 3, 3), GOLD, OLIVE, light_min_v=0.80), 3, 3))
    out.append(("wtree", recolor(crop(T, 4, 9), OLIVE, OLIVE), 1, 1))
    out.append(("sand", crop(T, 2, 1), 1, 1))
    out.append(("fence", draw(1, 1, fence), 1, 1))
    out.append(("hay", draw(1, 1, hay), 1, 1))
    out.append(("pumpkin", draw(1, 1, pumpkin), 1, 1))
    out.append(("scarecrow", draw(1, 2, scarecrow), 1, 2))
    out.append(("windmill", draw(2, 3, windmill), 2, 3))
    out.append(("tent", draw(2, 2, tent), 2, 2))
    return out



# ---------------------------------------------------------------------------------------------------------------
# The Deadmines: cave floor and rock, timber supports, mine rails, crates, powder barrels, cannons, ship planks,
# dark cove water, the mine entrance, a mast and Moonbrook's burned houses. Drawn here (deterministic noise) or
# recoloured from the sets above. Appended after the Westfall art so earlier atlas slots never move.
# ---------------------------------------------------------------------------------------------------------------
import random as _random  # noqa: E402


def _speckle(d, rnd, base, lo, hi, n):
    for _ in range(n):
        x, y = rnd.randrange(16), rnd.randrange(16)
        d.point((x, y), fill=rnd.choice((lo, hi)))


def mfloor(seed):
    def fn(d, img):
        rnd = _random.Random(seed)
        d.rectangle((0, 0, 15, 15), fill=(74, 58, 44, 255))
        _speckle(d, rnd, None, (60, 46, 34, 255), (92, 74, 56, 255), 40)
        if seed % 2:
            d.ellipse((9, 9, 12, 11), fill=(98, 92, 88, 255))
            d.point((10, 9), fill=(130, 124, 118, 255))
    return fn


def mwall(d, img):
    rnd = _random.Random(7)
    d.rectangle((0, 0, 15, 15), fill=(50, 44, 44, 255))
    for (x0, y0, x1, y1) in ((0, 0, 7, 6), (8, 0, 15, 5), (0, 7, 5, 15), (6, 7, 15, 15)):
        d.rectangle((x0, y0, x1, y1), fill=(62, 56, 54, 255))
        d.line((x0, y0, x1, y0), fill=(84, 78, 74, 255))
        d.line((x0, y1, x1, y1), fill=(36, 32, 32, 255))
    _speckle(d, rnd, None, (44, 40, 40, 255), (74, 68, 66, 255), 18)


def msupport(d, img):
    mwall(d, img)
    wood, dark = (122, 82, 44, 255), (78, 50, 26, 255)
    for x in (1, 12):
        d.rectangle((x, 3, x + 2, 15), fill=wood)
        d.line((x + 2, 3, x + 2, 15), fill=dark)
    d.rectangle((0, 1, 15, 4), fill=wood)
    d.line((0, 4, 15, 4), fill=dark)
    d.point((2, 2), fill=(170, 170, 170, 255))
    d.point((13, 2), fill=(170, 170, 170, 255))


def rail(horizontal, vertical):
    def fn(d, img):
        wood, steel = (98, 66, 38, 255), (160, 160, 168, 255)
        if horizontal:
            for x in range(1, 16, 4):
                d.rectangle((x, 3, x + 1, 12), fill=wood)
            d.line((0, 5, 15, 5), fill=steel)
            d.line((0, 10, 15, 10), fill=steel)
        if vertical:
            for y in range(1, 16, 4):
                d.rectangle((3, y, 12, y + 1), fill=wood)
            d.line((5, 0, 5, 15), fill=steel)
            d.line((10, 0, 10, 15), fill=steel)
    return fn


def crate(d, img):
    d.rectangle((1, 2, 14, 15), fill=(96, 62, 32, 255))
    d.rectangle((2, 3, 13, 14), fill=(150, 104, 58, 255))
    for y in (6, 10):
        d.line((2, y, 13, y), fill=(110, 72, 38, 255))
    d.line((2, 3, 13, 14), fill=(110, 72, 38, 255))
    d.line((2, 14, 13, 3), fill=(110, 72, 38, 255))


def barrel(d, img):
    d.ellipse((2, 2, 13, 15), fill=(92, 58, 30, 255))
    d.ellipse((3, 2, 12, 14), fill=(140, 92, 48, 255))
    for y in (5, 11):
        d.line((3, y, 12, y), fill=(70, 70, 76, 255))
    d.ellipse((5, 1, 10, 4), fill=(60, 40, 22, 255))
    d.rectangle((6, 7, 9, 9), fill=(210, 60, 40, 255))    # red powder mark


def cannon(d, img):
    d.rectangle((2, 10, 13, 14), fill=(110, 72, 38, 255))
    d.ellipse((2, 12, 6, 15), fill=(60, 40, 24, 255))
    d.ellipse((9, 12, 13, 15), fill=(60, 40, 24, 255))
    d.rectangle((1, 5, 14, 9), fill=(58, 58, 64, 255))
    d.line((1, 5, 14, 5), fill=(96, 96, 104, 255))
    d.rectangle((0, 4, 2, 10), fill=(40, 40, 44, 255))


def deck(d, img):
    d.rectangle((0, 0, 15, 15), fill=(112, 74, 42, 255))
    for y in (3, 7, 11, 15):
        d.line((0, y, 15, y), fill=(76, 48, 26, 255))
    for x, y in ((3, 1), (11, 5), (6, 9), (13, 13)):
        d.point((x, y), fill=(150, 150, 150, 255))


def mine_entrance(d, img):
    # 3 x 2 tiles: rock face with a timbered opening in the middle bottom
    for tx in range(3):
        for ty in range(2):
            sub = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
            mwall(ImageDraw.Draw(sub), sub)
            img.paste(sub, (tx * 16, ty * 16))
    wood, dark = (122, 82, 44, 255), (78, 50, 26, 255)
    d.rectangle((14, 8, 33, 31), fill=(10, 8, 8, 255))           # the dark opening
    d.rectangle((12, 6, 15, 31), fill=wood)
    d.rectangle((32, 6, 35, 31), fill=wood)
    d.rectangle((10, 4, 37, 8), fill=wood)
    d.line((10, 8, 37, 8), fill=dark)
    d.line((15, 6, 15, 31), fill=dark)
    d.line((35, 6, 35, 31), fill=dark)
    d.rectangle((20, 0, 27, 3), fill=(90, 60, 34, 255))           # sign board
    d.line((20, 1, 27, 1), fill=(200, 60, 40, 255))


def mast(d, img):
    wood, dark = (118, 78, 42, 255), (74, 48, 24, 255)
    d.rectangle((6, 0, 9, 47), fill=wood)
    d.line((9, 0, 9, 47), fill=dark)
    d.rectangle((0, 8, 15, 10), fill=wood)
    d.line((0, 10, 15, 10), fill=dark)
    for x in (1, 14):
        d.line((x, 10, 7, 40), fill=(170, 150, 110, 255))          # rigging
    d.rectangle((5, 0, 10, 2), fill=(200, 40, 40, 255))           # a red pennant


def mine_art():
    out = []
    out.append(("mfloor1", draw(1, 1, mfloor(2)), 1, 1))
    out.append(("mfloor2", draw(1, 1, mfloor(3)), 1, 1))
    out.append(("mwall", draw(1, 1, mwall), 1, 1))
    out.append(("msupport", draw(1, 1, msupport), 1, 1))
    out.append(("rail_h", draw(1, 1, rail(True, False)), 1, 1))
    out.append(("rail_v", draw(1, 1, rail(False, True)), 1, 1))
    out.append(("rail_x", draw(1, 1, rail(True, True)), 1, 1))
    out.append(("crate", draw(1, 1, crate), 1, 1))
    out.append(("barrel", draw(1, 1, barrel), 1, 1))
    out.append(("cannon", draw(1, 1, cannon), 1, 1))
    out.append(("deck", draw(1, 1, deck), 1, 1))
    dark = lambda im: recolor(im, (0.50, 0.55, 0.55), (0.50, 0.55, 0.55))        # noqa: E731
    for name, c, r in (("dwater1", 5, 1), ("dwater2", 5, 2)):
        im = crop(T, c, r).copy()
        px = im.load()
        for yy in range(16):
            for xx in range(16):
                rr, gg, bb, aa = px[xx, yy]
                px[xx, yy] = (int(rr * 0.45), int(gg * 0.62), int(bb * 0.62), aa)
        out.append((name, im, 1, 1))
    out.append(("mineentrance", draw(3, 2, mine_entrance), 3, 2))
    out.append(("mast", draw(1, 3, mast), 1, 3))
    ruin = recolor(crop(R, 0, 0, 5, 6), GOLD, (0.07, 0.25, 0.35), dark_rows=78)
    px = ruin.load()
    for yy in range(ruin.size[1]):
        for xx in range(ruin.size[0]):
            rr, gg, bb, aa = px[xx, yy]
            if aa and yy >= 70:                                            # soot on the walls
                px[xx, yy] = (int(rr * 0.62), int(gg * 0.58), int(bb * 0.55), aa)
    out.append(("ruinhouse", ruin, 5, 6))
    return out


# Goldshire's bounty board: a little roofed notice board with WANTED posters pinned to it.
def wanted_board(d, img):
    post, wood, dark = (98, 64, 34, 255), (150, 102, 56, 255), (72, 46, 24, 255)
    paper, ink, red = (236, 222, 180, 255), (128, 96, 62, 255), (178, 40, 32, 255)
    d.rectangle((2, 9, 3, 15), fill=post)               # legs
    d.rectangle((12, 9, 13, 15), fill=post)
    d.line((4, 9, 4, 15), fill=dark)
    d.line((14, 9, 14, 15), fill=dark)
    d.rectangle((0, 1, 15, 2), fill=dark)               # the little roof
    d.line((1, 0, 14, 0), fill=post)
    d.rectangle((1, 3, 14, 11), fill=dark)              # the board
    d.rectangle((2, 4, 13, 10), fill=wood)
    for x0, y0, x1, y1 in ((3, 5, 6, 9), (8, 4, 12, 8)):   # two posters
        d.rectangle((x0, y0, x1, y1), fill=paper)
        d.line((x0 + 1, y0 + 2, x1 - 1, y0 + 2), fill=ink)
        d.line((x0 + 1, y0 + 3, x1 - 1, y0 + 3), fill=ink)
    d.line((9, 5, 11, 5), fill=red)                     # "WANTED"
    d.point((4, 5), fill=red)
    d.point((10, 9), fill=paper)                        # a torn corner below


# Professions: herbs and ore veins to gather, a forge, an anvil and an alchemy table. Each node has a little
# white glint so it reads as "something to pick up".
LEAF, LEAF_D = (70, 150, 60, 255), (40, 100, 40, 255)


def _glint(d, x, y):
    d.point((x, y), fill=(255, 255, 255, 255))
    d.point((x - 1, y), fill=(255, 255, 230, 160))
    d.point((x + 1, y), fill=(255, 255, 230, 160))
    d.point((x, y - 1), fill=(255, 255, 230, 160))
    d.point((x, y + 1), fill=(255, 255, 230, 160))


def _tuft(d, leaf, dark):
    for x0, lean in ((4, -1), (7, 0), (10, 1)):          # three leaves fanning out of the ground
        d.line((x0 + 2, 15, x0 + 2 + lean * 2, 9), fill=dark)
        d.line((x0 + 1, 15, x0 + 1 + lean * 2, 10), fill=leaf)
    d.line((4, 15, 12, 15), fill=dark)


def herb_peacebloom(d, img):
    _tuft(d, LEAF, LEAF_D)
    for cx, cy in ((6, 7), (10, 6)):
        for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            d.point((cx + dx, cy + dy), fill=(250, 250, 245, 255))
        d.point((cx, cy), fill=(240, 200, 40, 255))
    _glint(d, 13, 3)


def herb_silverleaf(d, img):
    silver, silver_l, dark = (175, 195, 188, 255), (220, 232, 228, 255), (95, 118, 112, 255)
    for box in ((1, 7, 8, 12), (7, 6, 14, 11), (4, 2, 11, 9)):     # three broad leaves in a rosette
        d.ellipse(box, fill=dark)
        d.ellipse((box[0] + 1, box[1], box[2] - 1, box[3] - 1), fill=silver)
    d.line((4, 10, 7, 9), fill=silver_l)
    d.line((8, 8, 11, 8), fill=silver_l)
    d.line((7, 4, 8, 7), fill=silver_l)
    d.line((7, 11, 8, 15), fill=dark)
    _glint(d, 13, 3)


def herb_earthroot(d, img):
    soil, root, root_d = (110, 80, 50, 255), (170, 120, 70, 255), (120, 80, 45, 255)
    d.ellipse((2, 11, 13, 15), fill=soil)
    d.line((5, 12, 9, 7), fill=root_d, width=2)
    d.line((6, 12, 10, 8), fill=root)
    d.point((10, 7), fill=root)
    d.line((9, 7, 12, 4), fill=LEAF)
    d.line((8, 7, 7, 4), fill=LEAF_D)
    _glint(d, 13, 9)


def herb_mageroyal(d, img):
    _tuft(d, (60, 120, 70, 255), (35, 80, 45, 255))
    for cx, cy in ((5, 7), (8, 5), (11, 7)):
        d.rectangle((cx - 1, cy - 1, cx, cy), fill=(150, 80, 200, 255))
        d.point((cx, cy - 1), fill=(200, 150, 240, 255))
    _glint(d, 13, 3)


def herb_briarthorn(d, img):
    vine, vine_d = (110, 120, 50, 255), (60, 68, 28, 255)
    d.arc((1, 5, 11, 16), 180, 360, fill=vine_d, width=2)
    d.arc((5, 2, 15, 15), 190, 360, fill=vine, width=2)
    d.arc((3, 8, 14, 17), 180, 340, fill=vine, width=2)
    for x, y in ((2, 9), (7, 3), (13, 5), (9, 9), (4, 12)):
        d.point((x, y), fill=(235, 230, 190, 255))        # thorns
    for x, y in ((5, 7), (11, 9), (8, 12), (13, 12)):
        d.rectangle((x, y, x + 1, y + 1), fill=(200, 35, 40, 255))   # berries
    _glint(d, 13, 2)


def _vein(d, speck, speck_d):
    rock, rock_d, rock_l = (120, 118, 112, 255), (78, 76, 72, 255), (160, 158, 150, 255)
    d.ellipse((1, 5, 14, 15), fill=rock_d)
    d.ellipse((2, 5, 13, 13), fill=rock)
    d.line((4, 6, 9, 6), fill=rock_l)
    for x, y in ((4, 9), (8, 8), (11, 10), (6, 12), (10, 12)):
        d.rectangle((x, y, x + 1, y), fill=speck)
        d.point((x, y + 1), fill=speck_d)


def vein_copper(d, img):
    _vein(d, (215, 120, 50, 255), (150, 75, 30, 255))
    _glint(d, 12, 4)


def vein_tin(d, img):
    _vein(d, (205, 215, 225, 255), (140, 150, 165, 255))
    _glint(d, 12, 4)


def forge(d, img):
    brick, brick_d, mortar = (140, 70, 50, 255), (95, 45, 35, 255), (70, 60, 55, 255)
    d.rectangle((1, 3, 14, 15), fill=mortar)
    for y in range(4, 15, 3):
        off = 0 if (y // 3) % 2 else 2
        for x in range(1 + off, 14, 4):
            d.rectangle((x, y, min(14, x + 2), y + 1), fill=brick)
    d.rectangle((5, 0, 10, 3), fill=brick_d)             # chimney
    d.rectangle((4, 8, 11, 14), fill=(40, 25, 20, 255))  # the mouth
    d.rectangle((5, 10, 10, 14), fill=(240, 120, 30, 255))
    d.rectangle((6, 11, 9, 14), fill=(255, 210, 80, 255))


def anvil(d, img):
    iron, iron_d, iron_l = (70, 72, 80, 255), (40, 40, 46, 255), (120, 122, 130, 255)
    d.rectangle((5, 12, 10, 15), fill=(110, 75, 40, 255))  # the stump
    d.rectangle((4, 15, 11, 15), fill=(80, 55, 30, 255))
    d.rectangle((6, 9, 9, 11), fill=iron_d)                # waist
    d.rectangle((2, 5, 13, 8), fill=iron)                  # face
    d.polygon([(0, 5), (2, 5), (2, 7)], fill=iron)         # horn
    d.line((2, 5, 13, 5), fill=iron_l)
    d.line((3, 8, 13, 8), fill=iron_d)


def alchemy_table(d, img):
    wood, wood_d = (150, 100, 55, 255), (95, 60, 30, 255)
    d.rectangle((1, 9, 14, 11), fill=wood)
    d.line((1, 11, 14, 11), fill=wood_d)
    d.rectangle((2, 12, 3, 15), fill=wood_d)
    d.rectangle((12, 12, 13, 15), fill=wood_d)
    for x, col in ((3, (80, 200, 90, 255)), (7, (220, 60, 60, 255)), (11, (90, 120, 230, 255))):
        d.rectangle((x, 5, x + 2, 8), fill=col)            # three flasks
        d.rectangle((x + 1, 3, x + 1, 4), fill=(200, 200, 210, 255))
        d.point((x, 5), fill=(255, 255, 255, 200))


def sand(seed):
    def fn(d, img):
        rnd = _random.Random(seed)
        d.rectangle((0, 0, 15, 15), fill=(214, 184, 128, 255))
        for _ in range(22):
            x, y = rnd.randrange(16), rnd.randrange(16)
            d.point((x, y), fill=rnd.choice([(196, 164, 110, 255), (228, 202, 150, 255), (184, 150, 98, 255)]))
    return fn


def arena_wall(d, img):
    stone, dark, light = (138, 124, 104, 255), (86, 76, 64, 255), (176, 162, 138, 255)
    d.rectangle((0, 0, 15, 15), fill=dark)
    for y, off in ((1, 0), (6, 4), (11, 0)):                 # three courses of blocks
        for x in range(-8 + off, 16, 8):
            if x + 7 < 0:
                continue
            d.rectangle((max(0, x + 1), y, min(15, x + 7), y + 3), fill=stone)
            d.line((max(0, x + 1), y, min(15, x + 7), y), fill=light)
    d.rectangle((0, 15, 15, 15), fill=(60, 52, 44, 255))


def town_art():
    return [("wantedboard", draw(1, 1, wanted_board), 1, 1),
            ("node_peacebloom", draw(1, 1, herb_peacebloom), 1, 1),
            ("node_silverleaf", draw(1, 1, herb_silverleaf), 1, 1),
            ("node_earthroot", draw(1, 1, herb_earthroot), 1, 1),
            ("node_mageroyal", draw(1, 1, herb_mageroyal), 1, 1),
            ("node_briarthorn", draw(1, 1, herb_briarthorn), 1, 1),
            ("node_copper", draw(1, 1, vein_copper), 1, 1),
            ("node_tin", draw(1, 1, vein_tin), 1, 1),
            ("forge", draw(1, 1, forge), 1, 1),
            ("anvil", draw(1, 1, anvil), 1, 1),
            ("alchemy", draw(1, 1, alchemy_table), 1, 1),
            ("sand1", draw(1, 1, sand(5)), 1, 1),
            ("sand2", draw(1, 1, sand(9)), 1, 1),
            ("arenawall", draw(1, 1, arena_wall), 1, 1)]


# ---------------------------------------------------------------------------------------------------------------
# Duskwood: the Elwynn tiles in the zone's endless dusk (dark blue-green grass, black pines, a cold tint over
# everything), plus gravestones, iron fences, Darkshire's lamps, bare dead trees and dark-roofed houses.
# ---------------------------------------------------------------------------------------------------------------
DUSK = (0.36, 0.50, 0.66)          # dark grass
DUSK_TALL = (0.40, 0.60, 0.74)     # tall grass, a shade darker than the ground
DUSK_LEAF = (0.45, 0.45, 0.42)     # black-green pine needles
ROOF_DUSK = (0.75, 0.30, 0.55)     # Darkshire's dark purple slate


def shade(img, r=0.70, g=0.74, b=0.92):
    """Everything a little darker and colder (Duskwood's gloom)."""
    out = img.copy()
    px = out.load()
    for yy in range(out.size[1]):
        for xx in range(out.size[0]):
            rr, gg, bb, aa = px[xx, yy]
            if aa:
                px[xx, yy] = (int(rr * r), int(gg * g), int(bb * b), aa)
    return out


def dusk_path(im):
    """A path tile: its grass edge exactly like the ground tiles (no halo), its dirt darkened to wet earth."""
    grass = shade(recolor(im, DUSK, DUSK_LEAF))
    px, src = grass.load(), im.load()
    for yy in range(im.size[1]):
        for xx in range(im.size[0]):
            r, g, b, a = src[xx, yy]
            if not a:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if not (0.17 <= h <= 0.45 and s > 0.18):          # not grass: the dirt
                px[xx, yy] = (int(r * 0.50), int(g * 0.48), int(b * 0.56), a)
    return grass


def gravestone(d, img):
    stone, dark, light = (128, 130, 138, 255), (70, 72, 82, 255), (170, 172, 180, 255)
    d.rectangle((4, 4, 11, 14), fill=stone)
    d.rectangle((5, 2, 10, 3), fill=stone)
    d.point((4, 3), fill=stone)
    d.point((11, 3), fill=stone)
    d.line((4, 4, 4, 14), fill=light)
    d.line((11, 3, 11, 14), fill=dark)
    d.line((4, 14, 11, 14), fill=dark)
    d.line((7, 6, 8, 6), fill=dark)                      # a cross cut in the stone
    d.line((7, 5, 7, 10), fill=dark)
    d.line((6, 7, 9, 7), fill=dark)
    d.point((5, 12), fill=(78, 104, 70, 255))            # moss
    d.point((9, 13), fill=(78, 104, 70, 255))
    d.line((3, 15, 12, 15), fill=(30, 36, 34, 160))      # its shadow


def iron_fence(d, img):
    iron, hi = (34, 34, 42, 255), (84, 84, 98, 255)
    d.rectangle((0, 6, 15, 6), fill=iron)
    d.rectangle((0, 12, 15, 12), fill=iron)
    for x in (1, 5, 9, 13):
        d.line((x, 3, x, 15), fill=iron)
        d.point((x, 2), fill=hi)                         # spear tips
        d.point((x + 1, 4), fill=hi)


def lamppost(d, img):
    post, hi = (38, 36, 44, 255), (90, 88, 100, 255)
    d.rectangle((7, 6, 8, 15), fill=post)
    d.line((7, 6, 7, 15), fill=hi)
    d.rectangle((5, 14, 10, 15), fill=post)
    d.rectangle((5, 1, 10, 5), fill=post)                # the lantern
    d.rectangle((6, 2, 9, 4), fill=(255, 214, 120, 255))
    d.point((7, 3), fill=(255, 246, 200, 255))
    d.line((4, 1, 11, 1), fill=hi)


def dead_tree(d, img):
    bark, dark = (92, 80, 72, 255), (54, 46, 42, 255)
    d.rectangle((7, 7, 8, 15), fill=bark)
    d.line((8, 7, 8, 15), fill=dark)
    d.line((5, 15, 10, 15), fill=dark)
    for (x0, y0, x1, y1) in ((7, 8, 3, 4), (8, 7, 12, 3), (7, 10, 2, 8), (8, 9, 13, 7), (7, 6, 6, 1),
                             (3, 4, 2, 2), (12, 3, 14, 2), (6, 1, 8, 0)):
        d.line((x0, y0, x1, y1), fill=bark)
    d.point((3, 5), fill=dark)
    d.point((12, 4), fill=dark)


def duskwood_art():
    out = []
    dusk = lambda im: shade(recolor(im, DUSK, DUSK_LEAF))                        # noqa: E731
    out.append(("dgrass1", dusk(crop(R, 8, 0)), 1, 1))
    out.append(("dgrass2", dusk(crop(R, 9, 0)), 1, 1))
    for n, c, r in (("tl", 8, 1), ("t", 9, 1), ("tr", 10, 1), ("l", 8, 2), ("c", 9, 2), ("r", 10, 2),
                    ("bl", 8, 3), ("b", 9, 3), ("br", 10, 3), ("inw", 11, 0), ("ine", 12, 0), ("isw", 11, 1),
                    ("ise", 12, 1)):
        out.append(("dpath_" + n, dusk_path(crop(R, c, r)), 1, 1))
    for n, c, r in (("tl", 0, 6), ("t", 1, 6), ("tr", 2, 6), ("l", 0, 7), ("c", 1, 7), ("r", 2, 7),
                    ("bl", 0, 8), ("b", 1, 8), ("br", 2, 8)):
        out.append(("dtall_" + n, shade(recolor(crop(R, c, r), DUSK_TALL, DUSK_LEAF, light_min_v=0.0)), 1, 1))
    out.append(("dtree", shade(recolor(crop(T, 6, 3), DUSK_LEAF, DUSK_LEAF)), 1, 1))       # the pine
    out.append(("dbigtree", shade(recolor(crop(R, 5, 3, 3, 3), DUSK, DUSK_LEAF, light_min_v=0.80)), 3, 3))
    out.append(("darkhouse", shade(recolor(crop(R, 0, 0, 5, 6), DUSK, ROOF_DUSK, dark_rows=78), 0.56, 0.56, 0.68), 5, 6))
    out.append(("gravestone", draw(1, 1, gravestone), 1, 1))
    out.append(("ironfence", draw(1, 1, iron_fence), 1, 1))
    out.append(("lamppost", draw(1, 1, lamppost), 1, 1))
    out.append(("deadtree", draw(1, 1, dead_tree), 1, 1))
    return out


# ---------------------------------------------------------------------------------------------------------------
# Stranglethorn Vale: the Elwynn tiles in deep tropical green (wet red earth for the paths), palms, a jungle
# canopy tree, troll huts and ruin stones for the Bloodscalp and Skullsplitter camps, Booty Bay's wooden
# houses on stilts, and a troll totem.
# ---------------------------------------------------------------------------------------------------------------
JUNGLE = (0.30, 1.15, 0.92)        # deep jungle green
JUNGLE_TALL = (0.28, 1.25, 0.98)   # tall grass, lusher still
JUNGLE_LEAF = (0.33, 1.10, 0.62)   # canopy leaves
ROOF_BB = (0.07, 0.90, 0.72)       # Booty Bay: weathered brown planks


def jungle_path(im):
    """A path tile with the jungle's grass edge and wet red earth for the dirt."""
    grass = recolor(im, JUNGLE, JUNGLE_LEAF)
    px, src = grass.load(), im.load()
    for yy in range(im.size[1]):
        for xx in range(im.size[0]):
            r, g, b, a = src[xx, yy]
            if not a:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if not (0.17 <= h <= 0.45 and s > 0.18):          # not grass: the dirt, reddened
                px[xx, yy] = (min(255, int(r * 0.92)), int(g * 0.66), int(b * 0.52), a)
    return grass


def palm(d, img):
    trunk, dark = (128, 92, 52, 255), (84, 58, 30, 255)
    leaf, leaf2 = (58, 140, 62, 255), (36, 104, 44, 255)
    d.line((8, 6, 7, 15), fill=trunk)
    d.line((9, 6, 8, 15), fill=dark)
    for y in (8, 11, 14):
        d.point((7, y), fill=dark)
    # fronds fanning out from the crown
    for (x1, y1, x2, y2) in ((8, 5, 2, 2), (8, 5, 1, 7), (8, 5, 14, 2), (8, 5, 15, 7), (8, 5, 5, 9), (8, 5, 11, 9),
                             (8, 5, 8, 0)):
        d.line((x1, y1, x2, y2), fill=leaf)
    for (x1, y1, x2, y2) in ((7, 4, 3, 3), (9, 4, 13, 3), (6, 6, 2, 8), (10, 6, 14, 8)):
        d.line((x1, y1, x2, y2), fill=leaf2)
    d.point((8, 5), fill=leaf2)
    d.point((7, 6), fill=(190, 140, 60, 255))       # coconuts
    d.point((9, 6), fill=(190, 140, 60, 255))
    d.line((5, 15, 11, 15), fill=(30, 50, 34, 140))  # shadow


def hut(d, img):
    """A troll hut, 3 x 3 tiles (48 x 48): thatched roof, wattle walls, a dark doorway at the bottom middle."""
    thatch, thatch_d, thatch_l = (176, 138, 66, 255), (128, 96, 40, 255), (206, 170, 92, 255)
    wall, wall_d, door = (120, 84, 52, 255), (80, 54, 30, 255), (34, 22, 16, 255)
    d.polygon([(24, 2), (46, 24), (2, 24)], fill=thatch)
    d.polygon([(24, 2), (46, 24), (24, 24)], fill=thatch_d)
    for y in range(8, 24, 4):
        d.line((24 - (y - 2), y, 24 + (y - 2), y), fill=thatch_l)
    d.rectangle((6, 24, 41, 45), fill=wall)
    d.rectangle((24, 24, 41, 45), fill=wall_d)
    for x in range(8, 40, 6):
        d.line((x, 25, x, 45), fill=(96, 66, 40, 255))
    d.rectangle((19, 32, 28, 45), fill=door)
    d.rectangle((6, 45, 41, 46), fill=(60, 40, 24, 255))
    d.line((2, 47, 45, 47), fill=(30, 50, 34, 140))
    # a skull over the door
    d.ellipse((21, 27, 26, 31), fill=(226, 220, 200, 255))
    d.point((22, 29), fill=door)
    d.point((25, 29), fill=door)


def ruin_wall(d, img):
    stone, dark, light, moss = (118, 126, 112, 255), (70, 78, 66, 255), (156, 164, 148, 255), (72, 118, 60, 255)
    d.rectangle((0, 0, 15, 15), fill=stone)
    for y in (3, 8, 13):
        d.line((0, y, 15, y), fill=dark)
    for (x, y0, y1) in ((5, 0, 3), (11, 0, 3), (2, 4, 8), (9, 4, 8), (6, 9, 13), (13, 9, 13)):
        d.line((x, y0, x, y1), fill=dark)
    d.line((0, 0, 15, 0), fill=light)
    d.line((0, 0, 0, 15), fill=light)
    d.rectangle((7, 5, 8, 7), fill=(150, 60, 50, 255))     # a troll glyph in old red paint
    d.point((7, 4), fill=(150, 60, 50, 255))
    d.point((8, 4), fill=(150, 60, 50, 255))
    d.point((1, 14), fill=moss)
    d.point((2, 14), fill=moss)
    d.point((14, 11), fill=moss)
    d.point((12, 2), fill=moss)


def totem(d, img):
    """A troll totem, 1 x 2 tiles."""
    wood, dark, paint, teeth = (140, 96, 48, 255), (88, 58, 28, 255), (196, 60, 48, 255), (236, 230, 210, 255)
    d.rectangle((5, 2, 10, 31), fill=wood)
    d.line((10, 2, 10, 31), fill=dark)
    d.rectangle((4, 4, 11, 12), fill=wood)              # the top face
    d.rectangle((5, 6, 6, 7), fill=paint)
    d.rectangle((9, 6, 10, 7), fill=paint)
    d.rectangle((5, 10, 10, 10), fill=dark)
    for x in (5, 7, 9):
        d.point((x, 11), fill=teeth)
    d.rectangle((4, 16, 11, 24), fill=wood)             # the lower face
    d.rectangle((5, 18, 6, 19), fill=(60, 120, 200, 255))
    d.rectangle((9, 18, 10, 19), fill=(60, 120, 200, 255))
    d.line((5, 22, 10, 22), fill=paint)
    d.line((2, 3, 13, 3), fill=paint)                   # feathers / a crossbar
    d.line((3, 31, 12, 31), fill=(30, 50, 34, 140))


def jungle_art():
    out = []
    jungle = lambda im: recolor(im, JUNGLE, JUNGLE_LEAF)                               # noqa: E731
    out.append(("jgrass1", jungle(crop(R, 8, 0)), 1, 1))
    out.append(("jgrass2", jungle(crop(R, 9, 0)), 1, 1))
    for n, c, r in (("tl", 8, 1), ("t", 9, 1), ("tr", 10, 1), ("l", 8, 2), ("c", 9, 2), ("r", 10, 2),
                    ("bl", 8, 3), ("b", 9, 3), ("br", 10, 3), ("inw", 11, 0), ("ine", 12, 0), ("isw", 11, 1),
                    ("ise", 12, 1)):
        out.append(("jpath_" + n, jungle_path(crop(R, c, r)), 1, 1))
    for n, c, r in (("tl", 0, 6), ("t", 1, 6), ("tr", 2, 6), ("l", 0, 7), ("c", 1, 7), ("r", 2, 7),
                    ("bl", 0, 8), ("b", 1, 8), ("br", 2, 8)):
        out.append(("jtall_" + n, recolor(crop(R, c, r), JUNGLE_TALL, JUNGLE_LEAF, light_min_v=0.0), 1, 1))
    out.append(("jtree", draw(1, 1, palm), 1, 1))
    out.append(("jbigtree", recolor(crop(R, 5, 3, 3, 3), JUNGLE, JUNGLE_LEAF, light_min_v=0.80), 3, 3))
    out.append(("bbhouse", recolor(crop(R, 0, 0, 5, 6), JUNGLE, ROOF_BB, dark_rows=78), 5, 6))
    out.append(("hut", draw(3, 3, hut), 3, 3))
    out.append(("ruinwall", draw(1, 1, ruin_wall), 1, 1))
    out.append(("totem", draw(1, 2, totem), 1, 2))
    return out


# ---------------------------------------------------------------------------------------------------------------
# The Guild Hall: a stone plinth with a golden trophy, an empty draped one, and the guild Bestiary board.
# ---------------------------------------------------------------------------------------------------------------
def _plinth_base(d):
    stone, dark, light = (150, 150, 158, 255), (92, 92, 104, 255), (198, 198, 206, 255)
    d.rectangle((3, 9, 12, 15), fill=stone)
    d.rectangle((2, 8, 13, 9), fill=light)
    d.line((3, 15, 12, 15), fill=dark)
    d.line((12, 10, 12, 15), fill=dark)
    d.line((2, 15, 13, 15), fill=dark)


def plinth_trophy(d, img):
    _plinth_base(d)
    gold, bright, shade = (228, 186, 66, 255), (250, 222, 120, 255), (176, 132, 40, 255)
    d.rectangle((6, 2, 9, 6), fill=gold)          # the cup
    d.rectangle((5, 1, 10, 2), fill=bright)
    d.point((6, 3), fill=bright)
    d.line((9, 3, 9, 6), fill=shade)
    d.point((4, 2), fill=gold)                    # handles
    d.point((11, 2), fill=gold)
    d.point((4, 3), fill=shade)
    d.point((11, 3), fill=shade)
    d.rectangle((7, 6, 8, 7), fill=shade)         # the stem
    d.rectangle((5, 7, 10, 8), fill=gold)         # the foot


def plinth_empty(d, img):
    _plinth_base(d)
    cloth, fold = (108, 40, 52, 255), (140, 60, 74, 255)
    d.polygon([(4, 3), (11, 3), (12, 9), (3, 9)], fill=cloth)
    d.line((4, 3, 11, 3), fill=fold)
    d.line((7, 4, 7, 8), fill=fold)


def trophy_board(d, img):
    wood, dark, paper = (140, 96, 48, 255), (88, 58, 28, 255), (236, 226, 196, 255)
    d.rectangle((1, 1, 14, 13), fill=wood)
    d.rectangle((1, 13, 14, 14), fill=dark)
    d.rectangle((3, 3, 12, 11), fill=paper)
    for (x, y) in ((4, 4), (7, 4), (10, 4), (4, 7), (7, 7), (10, 7)):
        d.rectangle((x, y, x + 1, y + 1), fill=(60, 50, 40, 255))    # beast silhouettes
    d.line((4, 10, 11, 10), fill=(120, 100, 80, 255))



# ---------------------------------------------------------------------------------------------------------------
# The Guild Hall: flagstone floors, a red carpet with gold trim (autotiled like a path), brick walls, banners,
# stained-glass windows, the guild crest, pillars, chandeliers, hearths, a throne and the plinths.
# ---------------------------------------------------------------------------------------------------------------
STONE, STONE_D, STONE_L = (128, 124, 134, 255), (98, 94, 106, 255), (152, 148, 160, 255)
CARPET, CARPET_D, TRIM = (150, 34, 40, 255), (118, 24, 30, 255), (222, 178, 70, 255)


def hall_floor(seed):
    def fn(d, img):
        import random
        rnd = random.Random(seed)
        d.rectangle((0, 0, 15, 15), fill=STONE)
        for (x0, y0, x1, y1) in ((0, 0, 7, 7), (8, 0, 15, 7), (0, 8, 7, 15), (8, 8, 15, 15)):
            d.line((x0, y1, x1, y1), fill=STONE_D)
            d.line((x1, y0, x1, y1), fill=STONE_D)
            d.line((x0, y0, x1, y0), fill=STONE_L)
            d.line((x0, y0, x0, y1), fill=STONE_L)
        for _ in range(4):
            d.point((rnd.randint(1, 14), rnd.randint(1, 14)), fill=STONE_D)
    return fn


def carpet(piece):
    """A carpet tile: red, a gold trim along the edges the piece has, the inner corners trimmed on the diagonal."""
    def fn(d, img):
        d.rectangle((0, 0, 15, 15), fill=CARPET)
        for y in range(0, 16, 4):
            for x in range(0, 16, 4):
                if (x + y) % 8 == 0:
                    d.point((x + 2, y + 2), fill=CARPET_D)
        edges = {
            "tl": "tl", "t": "t", "tr": "tr", "l": "l", "c": "", "r": "r", "bl": "bl", "b": "b", "br": "br",
            "inw": "", "ine": "", "isw": "", "ise": "",
        }[piece]
        if "t" in edges:
            d.rectangle((0, 0, 15, 1), fill=TRIM)
        if "b" in edges:
            d.rectangle((0, 14, 15, 15), fill=TRIM)
        if "l" in edges:
            d.rectangle((0, 0, 1, 15), fill=TRIM)
        if "r" in edges:
            d.rectangle((14, 0, 15, 15), fill=TRIM)
        if piece == "inw":
            d.rectangle((0, 0, 1, 1), fill=TRIM)
        if piece == "ine":
            d.rectangle((14, 0, 15, 1), fill=TRIM)
        if piece == "isw":
            d.rectangle((0, 14, 1, 15), fill=TRIM)
        if piece == "ise":
            d.rectangle((14, 14, 15, 15), fill=TRIM)
    return fn


def hall_wall(d, img):
    brick, mortar, light = (96, 78, 72, 255), (60, 46, 44, 255), (122, 102, 94, 255)
    d.rectangle((0, 0, 15, 15), fill=brick)
    for y in (3, 7, 11, 15):
        d.line((0, y, 15, y), fill=mortar)
    for y0, off in ((0, 5), (4, 1), (8, 5), (12, 1)):
        for x in range(off, 16, 8):
            d.line((x, y0, x, y0 + 2), fill=mortar)
    for y in (0, 4, 8, 12):
        d.line((0, y, 15, y), fill=light)


def banner(color, dark, emblem):
    """A hanging banner, 1 x 2 tiles: a pole, the cloth with a gold trim and emblem, a pointed hem."""
    def fn(d, img):
        pole = (120, 92, 50, 255)
        d.rectangle((2, 1, 13, 2), fill=pole)
        d.point((1, 1), fill=TRIM)
        d.point((14, 1), fill=TRIM)
        d.polygon([(3, 3), (12, 3), (12, 24), (8, 29), (3, 24)], fill=color)
        d.line((3, 3, 3, 24), fill=dark)
        d.line((3, 24, 8, 29), fill=dark)
        d.line((12, 3, 12, 24), fill=dark)
        d.line((12, 24, 8, 29), fill=dark)
        d.line((4, 5, 11, 5), fill=TRIM)
        d.line((4, 21, 11, 21), fill=TRIM)
        if emblem == "lion":
            d.ellipse((5, 9, 10, 15), fill=TRIM)          # a golden head
            d.point((6, 11), fill=dark)
            d.point((9, 11), fill=dark)
            d.line((6, 14, 9, 14), fill=dark)
            d.polygon([(4, 8), (6, 9), (5, 11)], fill=TRIM)
            d.polygon([(11, 8), (9, 9), (10, 11)], fill=TRIM)
        else:
            d.polygon([(8, 8), (11, 12), (8, 16), (5, 12)], fill=TRIM)      # a golden diamond
            d.point((8, 12), fill=color)
    return fn


def window(d, img):
    frame, glass, glass2, glass3 = (50, 40, 40, 255), (70, 90, 170, 255), (120, 60, 150, 255), (200, 170, 80, 255)
    d.rectangle((2, 1, 13, 30), fill=frame)
    d.pieslice((2, 1, 13, 12), 180, 360, fill=frame)
    d.rectangle((4, 7, 11, 28), fill=glass)
    d.pieslice((4, 3, 11, 11), 180, 360, fill=glass)
    for (x0, y0, x1, y1) in ((4, 12, 7, 17), (8, 18, 11, 23), (4, 24, 7, 28)):
        d.rectangle((x0, y0, x1, y1), fill=glass2)
    d.rectangle((6, 8, 9, 11), fill=glass3)
    d.line((8, 3, 8, 28), fill=frame)
    for y in (12, 18, 24):
        d.line((4, y, 11, y), fill=frame)
    d.point((5, 5), fill=(230, 235, 255, 255))               # a gleam


def crest(d, img):
    """The guild crest on the wall, 2 x 2 tiles: a gold shield with a red lion on a dark hanging."""
    d.rectangle((2, 0, 29, 31), fill=(60, 26, 30, 255))
    d.rectangle((0, 0, 31, 2), fill=(120, 92, 50, 255))
    d.polygon([(6, 5), (25, 5), (25, 18), (16, 28), (7, 18)], fill=TRIM)
    d.polygon([(8, 7), (23, 7), (23, 17), (16, 25), (9, 17)], fill=(198, 150, 50, 255))
    d.ellipse((11, 9, 20, 18), fill=CARPET)                  # the lion
    d.point((13, 12), fill=TRIM)
    d.point((18, 12), fill=TRIM)
    d.line((13, 16, 18, 16), fill=CARPET_D)
    d.polygon([(10, 8), (13, 9), (11, 12)], fill=CARPET)
    d.polygon([(21, 8), (18, 9), (20, 12)], fill=CARPET)
    d.line((12, 19, 19, 22), fill=CARPET)                    # a sword under it
    d.line((19, 19, 12, 22), fill=CARPET)


def pillar(d, img):
    col, dark, light = (170, 166, 176, 255), (110, 106, 118, 255), (210, 206, 216, 255)
    d.rectangle((3, 0, 12, 2), fill=col)                     # the capital
    d.rectangle((5, 3, 10, 28), fill=col)
    d.line((5, 3, 5, 28), fill=light)
    d.line((10, 3, 10, 28), fill=dark)
    d.line((8, 4, 8, 27), fill=dark)
    d.rectangle((3, 29, 12, 31), fill=col)                   # the base
    d.line((3, 31, 12, 31), fill=dark)


def chandelier(d, img):
    iron, flame, glow = (60, 56, 60, 255), (255, 200, 80, 255), (255, 240, 170, 255)
    d.line((8, 0, 8, 5), fill=iron)
    d.ellipse((2, 6, 13, 10), outline=iron)
    for x in (3, 8, 12):
        d.rectangle((x, 3, x, 6), fill=(230, 226, 200, 255))
        d.point((x, 2), fill=flame)
        d.point((x, 1), fill=glow)


def fireplace(d, img):
    """A hearth, 2 x 2 tiles: a stone surround, the fire, a mantel with a candle."""
    d.rectangle((0, 4, 31, 31), fill=STONE)
    d.rectangle((0, 4, 31, 6), fill=STONE_L)                 # the mantel
    d.rectangle((6, 9, 25, 30), fill=(24, 18, 20, 255))      # the opening
    d.line((6, 9, 25, 9), fill=STONE_D)
    for x in (7, 23):
        d.line((x, 9, x, 30), fill=STONE_D)
    d.polygon([(10, 29), (14, 17), (16, 24), (19, 15), (22, 29)], fill=(220, 90, 30, 255))
    d.polygon([(13, 29), (15, 22), (17, 26), (19, 21), (20, 29)], fill=(250, 180, 60, 255))
    d.rectangle((9, 28, 23, 30), fill=(90, 60, 40, 255))     # logs
    d.rectangle((14, 0, 15, 3), fill=(230, 226, 200, 255))   # a candle on the mantel
    d.point((14, 0), fill=(255, 200, 80, 255))


def throne(d, img):
    """A throne, 2 x 1 tiles (32 x 16): red cushions, gold frame."""
    d.rectangle((6, 0, 25, 15), fill=TRIM)
    d.rectangle((8, 1, 23, 9), fill=CARPET)
    d.rectangle((8, 10, 23, 12), fill=CARPET_D)
    d.rectangle((3, 4, 5, 14), fill=TRIM)
    d.rectangle((26, 4, 28, 14), fill=TRIM)
    d.point((7, 0), fill=(255, 240, 170, 255))
    d.point((24, 0), fill=(255, 240, 170, 255))


def hall_art():
    out = [("hallfloor1", draw(1, 1, hall_floor(3)), 1, 1), ("hallfloor2", draw(1, 1, hall_floor(11)), 1, 1)]
    for piece in ("tl", "t", "tr", "l", "c", "r", "bl", "b", "br", "inw", "ine", "isw", "ise"):
        out.append(("carpet_" + piece, draw(1, 1, carpet(piece)), 1, 1))
    out.append(("hallwall", draw(1, 1, hall_wall), 1, 1))
    out.append(("banner", draw(1, 2, banner(CARPET, CARPET_D, "lion")), 1, 2))
    out.append(("bannerblue", draw(1, 2, banner((40, 60, 140, 255), (26, 40, 100, 255), "diamond")), 1, 2))
    out.append(("window", draw(1, 2, window), 1, 2))
    out.append(("crest", draw(2, 2, crest), 2, 2))
    out.append(("pillar", draw(1, 2, pillar), 1, 2))
    out.append(("chandelier", draw(1, 1, chandelier), 1, 1))
    out.append(("fireplace", draw(2, 2, fireplace), 2, 2))
    out.append(("throne", draw(2, 1, throne), 2, 1))
    return out


def hideout_art():
    return [("plinth", draw(1, 1, plinth_trophy), 1, 1),
            ("plinthempty", draw(1, 1, plinth_empty), 1, 1),
            ("trophyboard", draw(1, 1, trophy_board), 1, 1)]

def build_chars():
    img = Image.new("RGBA", (256, 128), (0, 0, 0, 0))
    img.paste(CH, (0, 0))
    tga(img, "chars")


def build_platform():
    k = 4
    img = Image.new("RGBA", (128 * k, 32 * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((0, 0, 128 * k - 1, 32 * k - 1), fill=(84, 150, 60, 255))
    d.ellipse((6 * k, 3 * k, 122 * k, 26 * k), fill=(144, 214, 84, 255))
    d.ellipse((14 * k, 6 * k, 114 * k, 20 * k), fill=(160, 226, 96, 255))
    tga(img.resize((128, 32), Image.NEAREST), "platform")
    # Westfall: dry golden ground
    img = Image.new("RGBA", (128 * k, 32 * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((0, 0, 128 * k - 1, 32 * k - 1), fill=(150, 118, 60, 255))
    d.ellipse((6 * k, 3 * k, 122 * k, 26 * k), fill=(214, 182, 104, 255))
    d.ellipse((14 * k, 6 * k, 114 * k, 20 * k), fill=(228, 198, 122, 255))
    tga(img.resize((128, 32), Image.NEAREST), "platform_w")
    # the Deadmines: worn stone
    img = Image.new("RGBA", (128 * k, 32 * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((0, 0, 128 * k - 1, 32 * k - 1), fill=(58, 52, 50, 255))
    d.ellipse((6 * k, 3 * k, 122 * k, 26 * k), fill=(96, 88, 84, 255))
    d.ellipse((14 * k, 6 * k, 114 * k, 20 * k), fill=(110, 102, 96, 255))
    tga(img.resize((128, 32), Image.NEAREST), "platform_m")
    # Duskwood: dark mossy ground
    img = Image.new("RGBA", (128 * k, 32 * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((0, 0, 128 * k - 1, 32 * k - 1), fill=(34, 48, 44, 255))
    d.ellipse((6 * k, 3 * k, 122 * k, 26 * k), fill=(58, 80, 70, 255))
    d.ellipse((14 * k, 6 * k, 114 * k, 20 * k), fill=(66, 90, 78, 255))
    tga(img.resize((128, 32), Image.NEAREST), "platform_d")
    # Stranglethorn: lush jungle floor
    img = Image.new("RGBA", (128 * k, 32 * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((0, 0, 128 * k - 1, 32 * k - 1), fill=(46, 96, 44, 255))
    d.ellipse((6 * k, 3 * k, 122 * k, 26 * k), fill=(84, 150, 60, 255))
    d.ellipse((14 * k, 6 * k, 114 * k, 20 * k), fill=(104, 172, 70, 255))
    tga(img.resize((128, 32), Image.NEAREST), "platform_j")


def write_lua(index):
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Atlas.lua", ...) then return end '
        "-- DisasterZone Games/Azeromon/Atlas.lua  (GENERATED by dev/generators/gen_azeromon_art.py - do not edit)",
        "-- Tile name -> slot in Media/Azeromon/atlas.tga (256 x %d, 16 columns of 16px tiles)." % ATLAS_H,
        "local addonName, ns = ...",
        "ns.AzeroAtlasHeight = %d" % ATLAS_H,
        "ns.AzeroAtlas = {",
    ]
    for name, i in sorted(index.items(), key=lambda kv: kv[1]):
        lines.append("    %s = %d," % (name, i))
    lines.append("}")
    os.makedirs(os.path.dirname(ATLAS_LUA), exist_ok=True)
    with open(ATLAS_LUA, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote Atlas.lua", len(index), "tiles")


if __name__ == "__main__":
    idx = build_atlas()
    build_chars()
    build_platform()
    write_lua(idx)

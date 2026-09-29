"""Builds the Azeromon overworld art (32-bit TGA, power-of-two sizes) into addon/CDLoot/Media/Azeromon/
and the tile index addon/CDLoot/Games/Azeromon/Atlas.lua.

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
ADDON = os.path.join(os.path.dirname(DEV), "addon", "CDLoot")
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


def build_atlas():
    atlas = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    index = {}

    def add(name, sheet, c, r):
        i = len(index)
        if i >= 256:
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
    for name, img, w, h in westfall_art():
        if w == 1 and h == 1:
            add(name, img, 0, 0)
        else:
            for y in range(h):
                for x in range(w):
                    add("%s_%d_%d" % (name, x, y), img, x, y)
    tga(atlas, "atlas")
    return index


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


def write_lua(index):
    lines = [
        "-- CDLoot Games/Azeromon/Atlas.lua  (GENERATED by dev/generators/gen_azeromon_art.py - do not edit)",
        "-- Tile name -> slot in Media/Azeromon/atlas.tga (256x256, 16 columns of 16px tiles).",
        "local addonName, ns = ...",
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

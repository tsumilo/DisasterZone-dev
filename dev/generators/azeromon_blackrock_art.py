"""Blackrock's tiles (Azeromon 0.25: Redridge, the Burning Steppes, the Searing Gorge, Blackrock Mountain), made from
the shipped atlas by recolouring: the same shapes in the zone's own palette (the approved mockup's tiles.py,
dev/art/casc/zone_mockup/blackrock). Shared by gen_azeromon_art.py (the atlas tiles) and gen_azeromon_ground.py (the
baker's joined wall pieces in canyon and basalt colours).

  redridge   rgrass1/2, rtall_*, rpath_*, rtree       (autumn: gold-olive ground, red and orange leaves)
  steppes    sgrass1/2, stall_*, spath_*, stree       (ash, dead grass, a scorched road, charred trees)
  gorge      ggrass1/2, gtall_*, gpath_*, gwall       (orange canyon, rust scrub, a dust road)
  blackrock  bfloor1/2, bpath_*, bwall                (basalt cave floor and walls)
  rrhouse_x_y  Lakeshire's red-roofed house (5 x 6 stamp, the house with its roof turned red)
  node_<res> iron gold mithril truesilver darkiron fadeleaf kingsblood firebloom sungrass (gather nodes)
"""
import numpy as np
from PIL import Image

SUFFIX = ["tl", "t", "tr", "l", "c", "r", "bl", "b", "br"]
PATHSUF = SUFFIX + ["inw", "ine", "isw", "ise"]


def hsv(c):
    return np.array(Image.fromarray(np.clip(c, 0, 255).astype(np.uint8), "RGB").convert("HSV"), dtype=np.float64)


def rgb(h):
    return np.array(Image.fromarray(np.clip(h, 0, 255).astype(np.uint8), "HSV").convert("RGB"), dtype=np.float64)


def recolor(tile, fn):
    """tile: (h, w, 4) float -> the same, its colour channels through fn(rgb, hsv) -> rgb"""
    t = np.array(tile, dtype=np.float64).copy()
    c = t[..., :3]
    t[..., :3] = np.clip(fn(c, hsv(c)), 0, 255)
    return t


def autumn(c, h):
    """greens to the Redridge fall: dark -> deep red, mid -> orange, light -> gold; non-greens kept"""
    hue = h[..., 0] * 360 / 255
    green = (hue > 40) & (hue < 190) & (h[..., 1] > 40)
    v = h[..., 2] / 255
    out = h.copy()
    tgt = np.where(v < 0.42, 6, np.where(v < 0.62, 20, 34))
    out[..., 0] = np.where(green, tgt * 255 / 360, h[..., 0])
    out[..., 1] = np.where(green, np.minimum(255, h[..., 1] * 1.12 + 20), h[..., 1])
    out[..., 2] = np.where(green, np.minimum(255, h[..., 2] * 1.04 + 6), h[..., 2])
    return rgb(out)


def wheat_gold(c, h):
    """Redridge's open ground: the Elwynn green turned to a warm dry olive-gold"""
    hue = h[..., 0] * 360 / 255
    green = (hue > 40) & (hue < 190)
    out = h.copy()
    out[..., 0] = np.where(green, (44 + (h[..., 2] / 255) * 8) * 255 / 360, h[..., 0])
    out[..., 1] = np.where(green, h[..., 1] * 0.8, h[..., 1])
    out[..., 2] = np.where(green, h[..., 2] * 0.78, h[..., 2])
    return rgb(out)


def ash(c, h):
    g = c.mean(-1, keepdims=True)
    return (g * 0.62 + c * 0.1) * np.array([1.06, 0.97, 0.92]) + np.array([6, 2, 0])


def charred(c, h):
    g = c.mean(-1, keepdims=True)
    return g * np.array([0.42, 0.36, 0.34])


def canyon(c, h):
    v = c.mean(-1, keepdims=True) / 255
    lo, hi = np.array([118, 52, 30]), np.array([232, 140, 74])
    return lo + (hi - lo) * np.clip((v - 0.25) * 1.6, 0, 1)


def rust(c, h):
    v = c.mean(-1, keepdims=True) / 255
    lo, hi = np.array([92, 44, 26]), np.array([200, 120, 56])
    return lo + (hi - lo) * np.clip((v - 0.2) * 1.5, 0, 1)


def basalt(c, h):
    v = c.mean(-1, keepdims=True) / 255
    lo, hi = np.array([22, 16, 16]), np.array([112, 86, 78])
    return lo + (hi - lo) * np.clip(v * 1.35 - 0.05, 0, 1)


def emberfloor(c, h):
    v = c.mean(-1, keepdims=True) / 255
    lo, hi = np.array([34, 24, 22]), np.array([128, 92, 78])
    return lo + (hi - lo) * np.clip(v * 1.4 - 0.1, 0, 1)


def scorched_path(c, h):
    v = c.mean(-1, keepdims=True) / 255
    lo, hi = np.array([46, 30, 26]), np.array([150, 104, 80])
    return lo + (hi - lo) * np.clip(v * 1.3 - 0.1, 0, 1)


def green_to(deg, sat=1.0, val=1.0):
    """only the greens (a roof, leaves) to another hue"""
    def f(c, h):
        hue = h[..., 0] * 360 / 255
        green = (hue > 60) & (hue < 170) & (h[..., 1] > 40)
        out = h.copy()
        out[..., 0] = np.where(green, deg * 255 / 360, h[..., 0])
        out[..., 1] = np.where(green, np.minimum(255, h[..., 1] * sat), h[..., 1])
        out[..., 2] = np.where(green, np.minimum(255, h[..., 2] * val), h[..., 2])
        return rgb(out)
    return f


def autumn_soft(c, h):
    a = autumn(c, h)
    g = a.mean(-1, keepdims=True)
    return (a * 0.72 + g * 0.28) * 0.9


def ashgrass(c, h):
    g = c.mean(-1, keepdims=True)
    return g * np.array([0.66, 0.6, 0.54]) + np.array([8, 4, 0])


def tint(mul, add=(0, 0, 0)):
    return lambda c, h: c * np.array(mul) + np.array(add)


def hue_to(deg, sat=1.0, val=1.0):
    def f(c, h):
        out = h.copy()
        colourful = h[..., 1] > 50
        out[..., 0] = np.where(colourful, deg * 255 / 360, h[..., 0])
        out[..., 1] = np.where(colourful, np.minimum(255, h[..., 1] * sat), h[..., 1])
        out[..., 2] = np.minimum(255, h[..., 2] * val)
        return rgb(out)
    return f


# (new tile, source tile, recolour), in the order they are appended to the atlas
def recipes():
    out = [("rgrass1", "grass1", wheat_gold), ("rgrass2", "grass2", wheat_gold)]
    out += [("rtall_" + s, "tall_" + s, autumn_soft) for s in SUFFIX]
    out += [("rpath_" + s, "path_" + s, tint((1.04, 0.96, 0.9))) for s in PATHSUF]
    out += [("rtree", "tree", autumn)]
    out += [("sgrass1", "wgrass1", ash), ("sgrass2", "wgrass2", ash)]
    out += [("stall_" + s, "wtall_" + s, ashgrass) for s in SUFFIX]
    out += [("spath_" + s, "wpath_" + s, scorched_path) for s in PATHSUF]
    out += [("stree", "deadtree", charred)]
    out += [("ggrass1", "sand1", canyon), ("ggrass2", "sand2", canyon)]
    out += [("gtall_" + s, "wtall_" + s, rust) for s in SUFFIX]
    out += [("gpath_" + s, "wpath_" + s, tint((0.96, 0.78, 0.62))) for s in PATHSUF]
    out += [("bfloor1", "mfloor1", emberfloor), ("bfloor2", "mfloor2", emberfloor)]
    out += [("bpath_" + s, "dpath_" + s, scorched_path) for s in PATHSUF]
    out += [("bwall", "mwall", basalt), ("gwall", "mwall", canyon)]
    out += [("rrhouse_%d_%d" % (dx, dy), "house_%d_%d" % (dx, dy), green_to(6, 0.95, 0.82))
            for dy in range(6) for dx in range(5)]
    out += [("node_iron", "node_copper", tint((0.62, 0.62, 0.66))),
            ("node_gold", "node_copper", hue_to(48, 1.2, 1.1)),
            ("node_mithril", "node_copper", hue_to(200, 0.6, 1.05)),
            ("node_truesilver", "node_tin", tint((1.1, 1.1, 1.16), (16, 16, 20))),
            ("node_darkiron", "node_copper", hue_to(356, 1.3, 0.6)),
            ("node_fadeleaf", "node_briarthorn", hue_to(110, 0.5, 1.15)),
            ("node_kingsblood", "node_briarthorn", hue_to(350, 1.2, 0.95)),
            ("node_firebloom", "node_briarthorn", hue_to(22, 1.4, 1.1)),
            ("node_sungrass", "node_briarthorn", hue_to(52, 1.2, 1.15))]
    return out


def tiles(get):
    """get(name) -> (16, 16, 4) tile of the finished atlas. -> [(name, (16, 16, 4) uint8)]"""
    out = []
    for name, src, fn in recipes():
        out.append((name, np.clip(np.round(recolor(get(src), fn)), 0, 255).astype(np.uint8)))
    return out


def walls(prop_images):
    """the baker's joined wall pieces: {kind: {mask: (h, w, 4) float}} for the shipped ruin / cave / arena walls plus
    the cave wall in canyon (gorgewall) and basalt (basaltwall) colours"""
    out = {}
    for name, img in prop_images.items():
        kind, _, m_ = name.rpartition("_")
        if kind in ("ruinwall", "cavewall", "arenawall"):
            a = np.array(img, dtype=np.float64)
            out.setdefault(kind, {})[int(m_)] = a
            if kind == "cavewall":
                out.setdefault("gorgewall", {})[int(m_)] = recolor(a, canyon)
                out.setdefault("basaltwall", {})[int(m_)] = recolor(a, basalt)
    return out

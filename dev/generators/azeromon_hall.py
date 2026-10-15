"""Azeromon's Guild Hall, the grand version (mockup first: dev/art/casc/azeromon_hall).

One 36 x 34 hall at 16 px a tile: a tall north wall with stained glass and a rose window over the throne dais, a
marble nave with a gold-edged carpet and a mosaic rotunda, colossal pillars, eight raid wings off the nave (four a
side, each with its own floor, wall dressing, light and trophy) and Sunwell's plinths on the dais beside the
throne. The lower hall holds the champions' statues, the hearths, the feast tables and the Bestiary lectern.

paint(sealed) -> picture (H, W, 3) floats: everything at floor level (floors, walls, wall dressing, pedestals,
contact shadows). Things that stand up (pillars, statues, braziers, the throne, trophies) are sprites the renderer
sorts with the player by their foot (SPRITES / instances()). sealed=True paints every wing shut (dust, shrouds,
scaffolding, a rope across the mouth): the renderer takes a wing's rectangle from that picture while the guild
has not killed anything there.
Light comes from the top left; ramps run dark -> light."""
import math

import numpy as np

from azeromon_props import Spr, H, WOOD, DWOOD, STONE, FIRE, PAPER, RED, TEAL, BONE, IRON, LEAF, MOSS, ROCK
from azeromon_interiors import _img, _blit, GOLD, BLUE, CLOTH, hearth

TW, TH = 36, 34
W, HT = TW * 16, TH * 16

WALL = [(26, 28, 40), (46, 50, 66), (70, 74, 92), (96, 100, 118), (124, 128, 146), (156, 160, 176)]
MARB = [(70, 66, 74), (116, 110, 116), (150, 144, 146), (176, 170, 168), (202, 196, 190), (228, 224, 216)]
GOLD5 = GOLD + [(255, 246, 196)]
VEL = [(54, 12, 18), (96, 22, 30), (140, 34, 40), (180, 52, 52), (214, 88, 78)]
PURP = [(30, 20, 44), (58, 38, 86), (92, 62, 132), (138, 104, 184), (190, 164, 228)]
FEL = [(14, 36, 10), (34, 90, 20), (70, 170, 40), (140, 240, 80), (210, 255, 160)]
SEA = [(10, 34, 52), (18, 64, 92), (30, 104, 136), (60, 150, 176), (120, 204, 220), (200, 240, 246)]
SUNC = [(120, 84, 40), (196, 150, 70), (240, 204, 110), (255, 236, 170), (255, 252, 230)]
JUNG = [(40, 24, 14), (72, 44, 24), (108, 70, 38), (146, 100, 56), (184, 138, 82)]
BASALT = [(18, 16, 20), (32, 28, 34), (48, 42, 50), (66, 60, 68), (88, 80, 88)]


def C(c):
    return np.array(c[:3], dtype=np.float64)


# ------------------------------------------------------------------------------------------- the plan

# raid wings: side, block top row Y (wall top Y, wall face Y+1, plinths Y+2 / Y+4, walk Y+3)
WINGS = [
    {"key": "Karazhan", "side": "l", "Y": 7, "theme": "kara", "short": "Karazhan", "n": 11},
    {"key": "GruulsLair", "side": "l", "Y": 12, "theme": "gruul", "short": "Gruul's Lair", "n": 2},
    {"key": "MagtheridonsLair", "side": "l", "Y": 17, "theme": "mag", "short": "Magtheridon's Lair", "n": 1},
    {"key": "SerpentshrineCavern", "side": "l", "Y": 22, "theme": "ssc", "short": "Serpentshrine", "n": 6},
    {"key": "TempestKeep", "side": "r", "Y": 7, "theme": "tk", "short": "Tempest Keep", "n": 4},
    {"key": "HyjalSummit", "side": "r", "Y": 12, "theme": "hyjal", "short": "Mount Hyjal", "n": 5},
    {"key": "BlackTemple", "side": "r", "Y": 17, "theme": "bt", "short": "Black Temple", "n": 9},
    {"key": "ZulAman", "side": "r", "Y": 22, "theme": "za", "short": "Zul'Aman", "n": 6},
]
SUNWELL = {"key": "SunwellPlateau", "theme": "sw", "short": "Sunwell Plateau"}

# light colours, wall trims and floor of each theme
THEME = {
    "kara": {"light": (190, 150, 255), "trim": PURP, "banner": PURP},
    "gruul": {"light": (255, 168, 96), "trim": ROCK, "banner": RED},
    "mag": {"light": (130, 255, 90), "trim": FEL, "banner": FEL},
    "ssc": {"light": (110, 220, 255), "trim": SEA, "banner": SEA},
    "tk": {"light": (255, 150, 220), "trim": GOLD5, "banner": VEL},
    "hyjal": {"light": (170, 255, 200), "trim": LEAF, "banner": LEAF},
    "bt": {"light": (110, 255, 80), "trim": FEL, "banner": BASALT},
    "za": {"light": (255, 150, 70), "trim": JUNG, "banner": RED},
    "sw": {"light": (255, 228, 150), "trim": SUNC, "banner": SUNC},
}


def wing_cols(side):
    """the wing's tile columns x0..x1 (interior incl. the mouth column) and its mouth column"""
    return (1, 12, 12) if side == "l" else (23, 34, 23)


def mx(side, x):
    """a left-wing column mirrored for the right side"""
    return x if side == "l" else TW - 1 - x


def plinth_slots(n):
    """plinth positions (dx from the wall, row offset 2 or 4) for n bosses: back row first, staggered"""
    back = [1, 3, 5, 7, 9, 11]
    front = [2, 4, 6, 8, 10]
    if n == 1:
        return [(6, 3)]
    if n == 2:
        return [(4, 3), (8, 3)]
    if n <= 4:
        xs = {3: [3, 6, 9], 4: [2, 5, 8, 11]}[n]
        return [(x, 3) for x in xs]
    nb = (n + 1) // 2
    nf = n - nb
    bx = {3: [3, 6, 9], 4: [2, 5, 8, 11], 5: [1, 3, 6, 9, 11], 6: back}[nb]
    fx = {2: [4, 8], 3: [3, 6, 9], 4: [2, 5, 8, 10], 5: front}[nf]
    return [(x, 2) for x in bx] + [(x, 4) for x in fx]


# ------------------------------------------------------------------------------------------- noise

def vnoise(w, h, cell, seed):
    gw, gh = w // cell + 3, h // cell + 3
    g = np.array([[H(x, y, seed) for x in range(gw)] for y in range(gh)])
    ys, xs = np.mgrid[0:h, 0:w]
    fx, fy = xs / cell, ys / cell
    x0, y0 = fx.astype(int), fy.astype(int)
    tx, ty = fx - x0, fy - y0
    tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
    a = g[y0, x0] * (1 - tx) + g[y0, x0 + 1] * tx
    b = g[y0 + 1, x0] * (1 - tx) + g[y0 + 1, x0 + 1] * tx
    return a * (1 - ty) + b * ty


def hashmap(w, h, seed):
    ys, xs = np.mgrid[0:h, 0:w]
    v = (xs * 374761393 + ys * 668265263 + seed * 1442695041) & 0xFFFFFFFF
    v = ((v ^ (v >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((v ^ (v >> 16)) & 0xFFFF) / 65536.0


# ------------------------------------------------------------------------------------------- floors

def floor_marble(w, h, seed=1, slab=32):
    """polished slabs with thin grout, a bevel, wandering veins and a few speckles"""
    ys, xs = np.mgrid[0:h, 0:w]
    sx, sy = xs // slab, ys // slab
    lx, ly = xs % slab, ys % slab
    pick = hashmap(int(sx.max()) + 1, int(sy.max()) + 1, seed)[sy, sx]
    img = np.zeros((h, w, 3))
    for i, (lo, hi) in enumerate(((0, 0.45), (0.45, 0.85), (0.85, 1.01))):
        m = (pick >= lo) & (pick < hi)
        img[m] = C(MARB[3 + (i == 1) - (i == 2)])
    n = vnoise(w, h, 20, seed + 3)
    v = np.abs(np.sin(xs * 0.11 + ys * 0.07 + n * 9 + sx * 1.7))
    img[v < 0.05] *= 0.9
    img[(v < 0.11) & (v >= 0.05)] *= 0.96
    sp = hashmap(w, h, seed + 9)
    img[sp < 0.012] *= 0.88
    img[sp > 0.994] = img[sp > 0.994] * 0.7 + 255 * 0.3
    img[(lx == 1) | (ly == 1)] = img[(lx == 1) | (ly == 1)] * 1.06 + 6
    img[(lx == slab - 1) | (ly == slab - 1)] *= 0.86
    img[(lx == 0) | (ly == 0)] = C(MARB[1])
    return img


def floor_checker(w, h, a, b, seed=2):
    """Karazhan: a chessboard of dark and pale marble, 16 px squares, veined"""
    ys, xs = np.mgrid[0:h, 0:w]
    q = ((xs // 16) + (ys // 16)) % 2
    img = np.where(q[..., None] == 0, C(a), C(b))
    n = vnoise(w, h, 14, seed)
    v = np.abs(np.sin(xs * 0.17 - ys * 0.09 + n * 8))
    img = np.where((v < 0.07)[..., None], img * np.where(q[..., None] == 0, 1.35, 0.88), img)
    lx, ly = xs % 16, ys % 16
    img[(lx == 0) | (ly == 0)] *= 0.8
    img[((lx == 1) | (ly == 1)) & (q == 1)] += 10
    return img


def floor_flag(w, h, ramp, seed=3, cracks=None):
    """rough irregular flagstones (Gruul, Magtheridon, Black Temple): a jittered cell pattern with dark joints;
    `cracks` (an RGB) glows in the joints"""
    ys, xs = np.mgrid[0:h, 0:w]
    cell = 14
    best = np.full((h, w), 1e9)
    second = np.full((h, w), 1e9)
    for gy in range(-1, h // cell + 2):
        for gx in range(-1, w // cell + 2):
            px = (gx + 0.15 + 0.7 * H(gx, gy, seed)) * cell
            py = (gy + 0.15 + 0.7 * H(gx, gy, seed + 1)) * cell
            d = (xs - px) ** 2 + (ys - py) ** 2
            upd = d < best
            second = np.where(upd, best, np.minimum(second, d))
            best = np.where(upd, d, best)
    edge = np.sqrt(second) - np.sqrt(best)
    tone = vnoise(w, h, 9, seed + 2)
    img = C(ramp[2]) + (C(ramp[3]) - C(ramp[2])) * tone[..., None]
    img = np.where((edge < 1.6)[..., None], C(ramp[0]), img)
    img = np.where(((edge >= 1.6) & (edge < 2.6))[..., None], img * 0.82, img)
    sp = hashmap(w, h, seed + 5)
    img = np.where((sp < 0.03)[..., None], img * 0.85, img)
    if cracks is not None:
        img = np.where((edge < 1.0)[..., None], C(cracks), img)
    return img


def floor_tiles_sea(w, h, seed=4):
    """Serpentshrine: glazed teal tiles with a wave motif and wet glints"""
    ys, xs = np.mgrid[0:h, 0:w]
    lx, ly = xs % 16, ys % 16
    img = np.zeros((h, w, 3))
    img[:] = C(SEA[2])
    wave = (np.abs(ly - 8 - 3 * np.sin((xs) * 0.39)) < 1.0)
    img[wave] = C(SEA[3])
    img[(lx == 0) | (ly == 0)] = C(SEA[0])
    img[(lx == 1) | (ly == 1)] = C(SEA[3])
    t = vnoise(w, h, 18, seed)
    img[t > 0.72] = img[t > 0.72] * 0.75 + C(SEA[4]) * 0.25
    sp = hashmap(w, h, seed + 1)
    img[sp > 0.993] = C(SEA[5])
    return img


def floor_glyph(w, h, seed=5):
    """Tempest Keep: polished violet stone with gold naaru geometry: diamonds on a 32 px lattice"""
    ys, xs = np.mgrid[0:h, 0:w]
    img = np.zeros((h, w, 3))
    t = vnoise(w, h, 24, seed)
    img[:] = C((58, 34, 78))
    img += (t[..., None] - 0.5) * 24
    lx, ly = (xs + 16) % 32, (ys + 8) % 32
    d = np.abs(lx - 16) + np.abs(ly - 16)
    img[(d == 13) | (d == 14)] = C(GOLD[2])
    img[d == 12] = C(GOLD[1])
    img[d <= 2] = C(GOLD5[4])
    img[(d == 6)] = C((110, 72, 140))
    img[(xs % 32 == 0) | (ys % 32 == 8)] *= 0.75
    return img


def floor_hyjal(w, h, seed=6):
    """Mount Hyjal: old stone half-swallowed by moss and grass, roots crossing it"""
    base = floor_flag(w, h, ROCK, seed=seed)
    n = vnoise(w, h, 12, seed + 4)
    g = hashmap(w, h, seed + 5)
    grass = C(MOSS[1]) + (C(MOSS[2]) - C(MOSS[1])) * g[..., None]
    grass = np.where((g > 0.86)[..., None], C(MOSS[3]), grass)
    img = np.where((n > 0.5)[..., None], grass, base)
    img = np.where(((n > 0.46) & (n <= 0.5))[..., None], base * 0.7 + C(MOSS[0]) * 0.3, img)
    ys, xs = np.mgrid[0:h, 0:w]
    for k in range(3):
        y0 = h * (0.25 + 0.3 * k)
        root = np.abs(ys - y0 - 6 * np.sin(xs * 0.05 + k * 2) - 3 * np.sin(xs * 0.17 + k)) < (2.2 - 0.004 * xs)
        img = np.where(root[..., None], C((96, 70, 48)), img)
        img = np.where((root & (np.abs(ys - y0 - 6 * np.sin(xs * 0.05 + k * 2) - 3 * np.sin(xs * 0.17 + k) + 1) < 0.7))[..., None],
                       C((140, 108, 74)), img)
    return img


def floor_planks_jungle(w, h, seed=7):
    """Zul'Aman: dark hardwood planks running sideways, a woven mat down the middle"""
    ys, xs = np.mgrid[0:h, 0:w]
    row = ys // 5
    off = (hashmap(1, int(row.max()) + 1, seed)[row, 0] * 40).astype(int)
    seg = (xs + off) // 36
    tone = hashmap(64, int(row.max()) + 1, seed + 1)[row, seg % 64]
    img = C(JUNG[2]) + (C(JUNG[3]) - C(JUNG[2])) * tone[..., None]
    img[ys % 5 == 4] = C(JUNG[0])
    img[(xs + off) % 36 == 0] = C(JUNG[1])
    img[ys % 5 == 0] *= 1.08
    g = hashmap(w, h, seed + 2)
    img[g < 0.08] *= 0.88
    mat = (ys >= h // 2 - 9) & (ys < h // 2 + 9) & (xs > 10) & (xs < w - 10)
    weave = ((xs // 3 + ys // 3) % 2 == 0)
    img[mat & weave] = C((176, 138, 74))
    img[mat & ~weave] = C((140, 104, 52))
    img[mat & ((ys == h // 2 - 9) | (ys == h // 2 + 8))] = C((96, 40, 30))
    return img


def floor_sun(w, h, seed=8):
    """Sunwell (the dais): white-gold marble with a gold inlay border"""
    img = floor_marble(w, h, seed, slab=16)
    img = img * 0.6 + C(SUNC[4]) * 0.4
    return img


FLOORS = {
    "kara": lambda w, h: floor_checker(w, h, (34, 26, 48), (196, 186, 206)),
    "gruul": lambda w, h: floor_flag(w, h, [(40, 32, 28), (70, 58, 50), (104, 90, 76), (134, 118, 98)], seed=11),
    "mag": lambda w, h: floor_flag(w, h, BASALT, seed=12, cracks=(96, 220, 60)),
    "ssc": floor_tiles_sea,
    "tk": floor_glyph,
    "hyjal": floor_hyjal,
    "bt": lambda w, h: floor_flag(w, h, [(20, 26, 22), (36, 44, 38), (56, 66, 56), (74, 86, 72)], seed=14),
    "za": floor_planks_jungle,
}


# ------------------------------------------------------------------------------------------- walls

def ashlar(w, h, ramp, seed=0, bh=8, bw=16):
    """dressed stone blocks in staggered courses, each its own tone, lit top edge, dark joint"""
    ys, xs = np.mgrid[0:h, 0:w]
    course = ys // bh
    off = (course % 2) * (bw // 2)
    blk = (xs + off) // bw
    tone = hashmap(128, int(course.max()) + 1, seed)[course, blk % 128]
    img = C(ramp[2]) + (C(ramp[3]) - C(ramp[2])) * tone[..., None]
    n = hashmap(w, h, seed + 3)
    img[n < 0.08] *= 0.9
    img[ys % bh == 0] = img[ys % bh == 0] * 1.08 + 6
    img[ys % bh == bh - 1] = C(ramp[0])
    img[(xs + off) % bw == 0] = C(ramp[1])
    return img


def stained_glass(w, h, scheme, night=False, seed=0):
    """a tall pointed window with leaded panes: a border band, a diamond lattice, a figure-ish centre lozenge"""
    s = Spr(w, h)
    cx = (w - 1) / 2
    cols = {"blue": [(40, 70, 170), (70, 120, 220), (130, 180, 250)],
            "red": [(150, 30, 40), (210, 60, 60), (250, 130, 110)],
            "gold": [(190, 130, 30), (240, 190, 70), (255, 236, 150)],
            "purple": [(90, 40, 150), (140, 80, 210), (200, 150, 250)]}
    main = cols[scheme]
    alt = cols["gold"] if scheme != "gold" else cols["blue"]
    arch = w * 0.75
    for y in range(h):
        for x in range(w):
            if y < arch:
                # pointed arch: two circles meeting at the top
                r = w * 0.95
                inside = ((x - (w - 1 - r + 0.5)) ** 2 + (y - arch) ** 2 <= r * r) and ((x - (r - 0.5)) ** 2 + (y - arch) ** 2 <= r * r)
                if not inside:
                    continue
            edge = x in (0, w - 1) or y == h - 1
            if edge:
                s.put(x, y, (24, 22, 30))
                continue
            lead = ((x + y) % 5 == 0) or ((x - y) % 5 == 0)
            if lead:
                s.put(x, y, (30, 28, 36))
                continue
            border = x in (1, 2, w - 2, w - 3)
            d = abs(x - cx) / (w / 2) + abs(y - h * 0.5) / (h * 0.32)
            pal = alt if (border or d < 0.55) else main
            k = 2 if (y < h * 0.3 or H(x, y, seed) > 0.8) else 1 if H(x, y, seed + 1) > 0.35 else 0
            c = pal[k]
            if night:
                c = (int(c[0] * 0.28 + 10), int(c[1] * 0.3 + 12), int(c[2] * 0.42 + 26))
            s.put(x, y, c)
    s.rect(1, h - 2, w - 2, h - 1, WALL[4])                             # the sill
    s.rect(1, h - 1, w - 2, h - 1, WALL[2])
    return s


def rose_window(r, night=False):
    s = Spr(2 * r + 3, 2 * r + 3)
    c = r + 1
    for y in range(s.h):
        for x in range(s.w):
            dx, dy = x - c, y - c
            d = math.hypot(dx, dy)
            if d > r + 1:
                continue
            if d > r - 0.3:
                s.put(x, y, WALL[4] if dy < 0 else WALL[2])
                continue
            a = math.atan2(dy, dx)
            petal = math.cos(a * 8)
            if d < r * 0.22:
                col = (255, 230, 140)
            elif abs(d - r * 0.62) < 0.8 or (d > r * 0.25 and abs(math.sin(a * 8)) < 0.12):
                col = (34, 30, 40)                                       # lead
            elif d < r * 0.62:
                col = (220, 60, 70) if petal > 0 else (250, 170, 70)
            else:
                col = (60, 100, 210) if petal > 0.2 else (130, 80, 200)
            if night:
                col = (int(col[0] * 0.28 + 10), int(col[1] * 0.3 + 12), int(col[2] * 0.42 + 26))
            s.put(x, y, col)
    return s


def lion_glyph():
    return [(5, 6), (6, 6), (7, 6), (8, 6), (4, 7), (5, 7), (6, 7), (7, 7), (8, 7), (9, 7), (5, 8), (6, 8), (7, 8),
            (8, 8), (6, 9), (7, 9), (5, 10), (8, 10), (5, 11), (8, 11), (4, 12), (9, 12), (6, 5), (7, 5)]


def great_banner(w, h, ramp, trim, glyph="lion"):
    """a long hanging banner with a gold pole, trim and a swallow-tail; the guild lion big in the middle"""
    s = Spr(w, h)
    s.rect(0, 0, w - 1, 1, GOLD[2]); s.rect(0, 1, w - 1, 1, GOLD[1])
    s.put(0, 0, GOLD5[4]); s.put(w - 1, 0, GOLD[1])
    body = h - 6
    for y in range(2, body):
        for x in range(1, w - 1):
            k = 3 if x < 3 else 1 if x > w - 4 else 2
            if (x + y * 3) % 11 == 0:
                k = max(0, k - 1)
            s.put(x, y, ramp[k])
    for y in range(body, h):
        for x in range(1, w - 1):
            t = (y - body) / max(1, h - body)
            if abs(x - (w - 1) / 2) >= t * (w / 2 - 1):
                s.put(x, y, ramp[1])
    s.rect(1, 3, w - 2, 3, trim[2]); s.rect(1, body - 3, w - 2, body - 3, trim[2])
    s.rect(1, 2, 1, body - 1, trim[1]); s.rect(w - 2, 2, w - 2, body - 1, trim[1])
    if glyph == "lion":
        sc = max(1, (w - 4) // 12)
        ox = (w - 12 * sc) // 2 + sc
        oy = (body - 14 * sc) // 2 + 1
        for gx, gy in lion_glyph():
            for a in range(sc):
                for b in range(sc):
                    s.put(ox + gx * sc + a, oy + gy * sc + b, GOLD[2] if gx > 6 else GOLD[3])
    s.outline(0.4)
    return s


# ------------------------------------------------------------------------------------------- standing sprites

def pillar(h=64, ramp=MARB):
    """a colossal column 22 px wide on a 16 px tile: stepped base, fluted shaft lit from the left, gilded capital"""
    w = 22
    s = Spr(w, h)
    s.rect(0, h - 7, w - 1, h - 1, ramp[2]); s.rect(0, h - 7, w - 1, h - 7, ramp[4]); s.rect(0, h - 1, w - 1, h - 1, ramp[0])
    s.rect(w - 2, h - 6, w - 1, h - 2, ramp[1])
    s.rect(2, h - 10, w - 3, h - 8, ramp[3]); s.rect(2, h - 10, w - 3, h - 10, ramp[4])
    for y in range(10, h - 10):
        for x in range(3, w - 3):
            t = (x - 3) / (w - 7)
            k = 5 if t < 0.12 else 4 if t < 0.3 else 3 if t < 0.55 else 2 if t < 0.8 else 1
            if (x - 3) % 4 == 3:
                k = max(0, k - 1)
            s.put(x, y, ramp[k])
    s.rect(1, 6, w - 2, 9, GOLD[2]); s.rect(1, 6, w - 2, 6, GOLD5[4]); s.rect(1, 9, w - 2, 9, GOLD[1])
    for x in range(2, w - 2, 3):
        s.put(x, 8, GOLD[0])
    s.rect(0, 2, w - 1, 5, ramp[3]); s.rect(0, 2, w - 1, 2, ramp[5]); s.rect(0, 5, w - 1, 5, ramp[1])
    s.rect(2, 0, w - 3, 1, ramp[4])
    s.outline(0.42)
    return s


def brazier(ramp=IRON, bowl=GOLD):
    """a tall standing brazier: tripod, bowl; the flame is drawn live"""
    s = Spr(16, 26)
    s.line(4, 25, 7, 13, ramp[2]); s.line(11, 25, 8, 13, ramp[1]); s.line(8, 25, 8, 13, ramp[2])
    s.rect(6, 12, 9, 13, ramp[3])
    s.poly([(1, 7), (14.9, 7), (12, 12), (4, 12)], lambda x, y: bowl[2] if x < 8 else bowl[1])
    s.rect(1, 7, 14, 7, bowl[3]); s.rect(2, 6, 13, 6, (40, 20, 14))
    s.put(3, 8, GOLD5[4])
    s.outline(0.4)
    return s


def throne():
    s = Spr(32, 46)
    # tall back with a crest
    s.poly([(4, 14), (8, 3), (16, 0), (24, 3), (28, 14)], lambda x, y: GOLD[2] if x < 16 else GOLD[1])
    s.fill(7, 6, 24, 30, lambda x, y: VEL[2] if x < 16 else VEL[1])
    s.rect(7, 6, 24, 6, VEL[3])
    for gx, gy in lion_glyph():
        s.put(10 + gx, 6 + gy, GOLD[3] if gx < 7 else GOLD[2])
    s.rect(4, 14, 6, 34, GOLD[2]); s.rect(25, 14, 27, 34, GOLD[1])           # side posts
    s.put(5, 13, GOLD5[4]); s.put(26, 13, GOLD[3])
    # arms and seat
    s.rect(2, 26, 9, 30, GOLD[2]); s.rect(2, 26, 9, 26, GOLD5[4])
    s.rect(22, 26, 29, 30, GOLD[1]); s.rect(22, 26, 29, 26, GOLD[3])
    s.rect(9, 28, 22, 34, VEL[3]); s.rect(9, 28, 22, 28, VEL[4]); s.rect(9, 34, 22, 34, VEL[1])
    s.rect(6, 35, 25, 39, GOLD[1]); s.rect(6, 35, 25, 35, GOLD[2])
    s.rect(8, 40, 10, 45, GOLD[1]); s.rect(21, 40, 23, 45, GOLD[0])
    s.rect(7, 44, 24, 45, GOLD[0])
    for x in (12, 16, 19):
        s.put(x, 37, (120, 200, 255)); s.put(x + 1, 37, (60, 120, 220))      # gems
    s.put(16, 1, (255, 80, 80)); s.put(16, 2, (180, 30, 40))
    s.outline(0.4)
    return s


def pedestal(ramp=MARB, band=GOLD):
    """a trophy pedestal (baked at floor level, its top 4 px into the tile above's floor): a cushion slab, a fluted
    drum with a gold band and the plaque, a stepped foot"""
    s = Spr(16, 20)
    s.rect(1, 16, 14, 19, ramp[2]); s.rect(1, 16, 14, 16, ramp[4]); s.rect(1, 19, 14, 19, ramp[0])
    for y in range(6, 16):
        for x in range(3, 13):
            k = 5 if x == 3 else 4 if x < 6 else 3 if x < 9 else 2 if x < 11 else 1
            if x in (5, 8, 11):
                k = max(0, k - 1)
            s.put(x, y, ramp[min(k, len(ramp) - 1)])
    s.rect(3, 11, 12, 12, band[2]); s.rect(3, 12, 12, 12, band[1])
    s.rect(6, 13, 9, 14, band[1]); s.rect(6, 13, 9, 13, band[3])
    s.rect(0, 1, 15, 5, ramp[3]); s.rect(0, 1, 15, 1, ramp[min(5, len(ramp) - 1)]); s.rect(0, 5, 15, 5, ramp[1])
    s.rect(1, 2, 14, 3, ramp[4])
    s.rect(1, 0, 14, 0, ramp[3])
    s.outline(0.42)
    return s


def shroud():
    """a pedestal under a dust sheet (sealed wings)"""
    s = Spr(16, 16)
    s.poly([(2, 2), (13, 2), (15, 15), (0.5, 15)], lambda x, y: (150, 144, 132) if x < 7 else (118, 112, 104) if x < 12 else (94, 90, 84))
    for x in range(1, 15, 3):
        s.put(x, 14, (80, 76, 70)); s.put(x + 1, 15, (100, 96, 90))
    s.rect(3, 2, 12, 2, (180, 174, 160))
    s.line(6, 4, 5, 14, (108, 104, 96)); s.line(10, 4, 11, 14, (90, 86, 80))
    s.outline(0.45)
    return s


def statue_base():
    s = Spr(20, 12)
    s.ellipse(10, 6, 9.5, 5.5, lambda x, y: MARB[2] if y > 6 else MARB[4])
    s.ellipse(10, 5, 8, 3.6, lambda x, y: MARB[3])
    s.rect(4, 8, 15, 9, GOLD[2])
    s.outline(0.42)
    return s


def lectern():
    s = Spr(16, 22)
    s.rect(6, 10, 9, 20, WOOD[2]); s.rect(6, 10, 6, 20, WOOD[3]); s.rect(3, 20, 12, 21, WOOD[1])
    s.poly([(0.5, 6), (15.5, 6), (13, 11), (3, 11)], lambda x, y: WOOD[3])
    s.rect(1, 2, 7, 8, PAPER[3]); s.rect(8, 2, 14, 8, PAPER[2]); s.rect(7, 2, 8, 8, PAPER[1])
    for y in (4, 6):
        s.rect(2, y, 6, y, PAPER[1]); s.rect(9, y, 13, y, PAPER[0])
    s.put(12, 3, RED[2]); s.line(13, 0, 15, 4, (240, 240, 230))
    s.outline(0.42)
    return s


def feast_table(n):
    """a long table n tiles wide with a runner, plates, goblets and candles"""
    w = n * 16
    s = Spr(w, 22)
    s.rect(0, 4, w - 1, 13, WOOD[3]); s.rect(0, 4, w - 1, 4, WOOD[4]); s.rect(0, 13, w - 1, 13, WOOD[1])
    s.rect(0, 14, w - 1, 15, WOOD[1])
    s.rect(4, 7, w - 5, 10, VEL[2]); s.rect(4, 7, w - 5, 7, VEL[3]); s.rect(4, 10, w - 5, 10, VEL[1])
    for x in range(8, w - 6, 12):
        s.ellipse(x, 5.5, 2.2, 1.2, lambda a, b: BONE[3])
        s.ellipse(x + 3, 12, 2.2, 1.2, lambda a, b: BONE[2])
        s.put(x + 6, 8, GOLD[3]); s.put(x + 6, 9, GOLD[1])
    for x in range(14, w - 8, 32):
        s.rect(x, 1, x + 1, 7, (246, 240, 220)); s.put(x, 0, FIRE[3])
    for x in (2, w - 4):
        s.rect(x, 16, x + 1, 21, WOOD[1])
    s.outline(0.42)
    return s


# trophies (one look per raid; the plaque names the boss)
def trophy(theme):
    s = Spr(16, 18)
    if theme == "kara":                                     # a gold chess king
        s.rect(5, 14, 10, 15, GOLD[1]); s.rect(4, 16, 11, 17, GOLD[1]); s.rect(4, 16, 11, 16, GOLD[2])
        s.poly([(5, 14), (10.9, 14), (9.5, 6), (6.5, 6)], lambda x, y: GOLD[3] if x < 8 else GOLD[2])
        s.ellipse(8, 5, 3, 2, lambda x, y: GOLD[3])
        s.rect(7, 0, 8, 4, GOLD5[4]); s.rect(6, 1, 9, 2, GOLD5[4])
    elif theme == "gruul":                                  # a gronn's tooth on a stand
        s.rect(4, 15, 11, 17, IRON[2])
        s.poly([(5, 15), (11, 15), (9, 2), (8, 0)], lambda x, y: BONE[3] if x < 8 else BONE[1])
        s.line(7, 4, 6, 13, BONE[2])
    elif theme == "mag":                                    # the pit lord's horned skull
        s.ellipse(8, 10, 4.5, 4, lambda x, y: BONE[2] if x < 8 else BONE[1])
        s.put(6, 10, (120, 255, 80)); s.put(10, 10, (120, 255, 80))
        s.line(4, 8, 1, 2, BONE[3]); s.line(12, 8, 15, 2, BONE[1]); s.put(1, 1, (70, 20, 20)); s.put(15, 1, (70, 20, 20))
        s.rect(5, 15, 11, 17, BASALT[3])
    elif theme == "ssc":                                    # Vashj's trident
        s.line(8, 17, 8, 4, GOLD[2]); s.line(9, 17, 9, 5, GOLD[1])
        for x in (4, 8, 12):
            s.line(x, 6, x, 1, SEA[4])
        s.rect(4, 6, 12, 7, GOLD[3])
        s.rect(5, 16, 12, 17, SEA[1])
    elif theme == "tk":                                     # a verdant sphere in a gold claw
        s.ellipse(8, 7, 4, 4, lambda x, y: (120, 255, 140) if x + y < 14 else (40, 160, 80))
        s.put(6, 5, (240, 255, 240))
        s.line(3, 7, 5, 13, GOLD[2]); s.line(13, 7, 11, 13, GOLD[1]); s.rect(5, 13, 11, 14, GOLD[2])
        s.rect(4, 15, 12, 17, GOLD[1])
    elif theme == "hyjal":                                  # a horn bound in gold
        for i in range(12):
            t = i / 11
            x = 3 + 10 * t
            y = 14 - 9 * t + 3 * math.sin(t * math.pi)
            s.ellipse(x, y, 2.4 - t * 1.4, 2.4 - t * 1.4, lambda a, b: BONE[2] if b < y else BONE[1])
        s.rect(5, 10, 6, 15, GOLD[2]); s.rect(3, 15, 12, 17, WOOD[2])
    elif theme == "bt":                                     # a warglaive
        s.line(2, 15, 14, 3, (190, 240, 160)); s.line(3, 15, 15, 3, (90, 200, 70))
        s.line(2, 3, 14, 15, (190, 240, 160)); s.line(3, 3, 15, 15, (90, 200, 70))
        s.rect(6, 7, 10, 11, IRON[1]); s.rect(7, 8, 9, 10, (110, 255, 80))
    elif theme == "za":                                     # a gold troll mask
        s.ellipse(8, 8, 5.5, 7, lambda x, y: GOLD[3] if x < 8 else GOLD[2])
        s.rect(5, 6, 6, 7, (30, 10, 10)); s.rect(10, 6, 11, 7, (30, 10, 10))
        s.rect(6, 12, 10, 13, (60, 20, 10)); s.put(5, 13, BONE[3]); s.put(11, 13, BONE[3])
        s.line(2, 2, 4, 5, (220, 60, 50)); s.line(14, 2, 12, 5, (220, 60, 50))
    else:                                                   # the Sunwell's light in a golden cup
        s.poly([(3, 6), (13, 6), (10, 12), (6, 12)], lambda x, y: GOLD[3] if x < 8 else GOLD[2])
        s.rect(7, 12, 8, 15, GOLD[1]); s.rect(4, 15, 11, 17, GOLD[2])
        s.ellipse(8, 4, 3, 3, lambda x, y: SUNC[4])
        s.put(8, 0, SUNC[3]); s.put(8, 1, SUNC[4])
    s.outline(0.4)
    return s


# ------------------------------------------------------------------------------------------- wing dressing

def wing_face(img, theme, x0, y0, w, sealed, seed):
    """the wall face of a wing's back wall (22 px tall at y0..y0+21) dressed for its raid"""
    tr = THEME[theme]["trim"]
    face = ashlar(w, 22, WALL, seed=seed, bh=7, bw=14)
    if theme == "gruul":
        face = floor_flag(w, 22, ROCK, seed=seed + 1) * 0.9
    elif theme == "mag":
        face = ashlar(w, 22, BASALT, seed=seed)
    elif theme == "ssc":
        face = ashlar(w, 22, [SEA[0], SEA[1], SEA[1], SEA[2]], seed=seed)
    elif theme == "hyjal":
        ys, xs = np.mgrid[0:22, 0:w]
        bark = np.abs(np.sin(xs * 0.6 + 2 * np.sin(ys * 0.3))) < 0.35
        face = np.where(bark[..., None], C((70, 52, 36)), C((104, 78, 52)))
        face = face * (0.85 + 0.3 * vnoise(w, 22, 5, seed)[..., None])
    elif theme == "za":
        ys, xs = np.mgrid[0:22, 0:w]
        face = np.where(((xs % 6) == 0)[..., None], C(JUNG[1]), C(JUNG[3]))
        face = np.where(((xs % 6) == 1)[..., None], C(JUNG[4]), face)
        face = np.where(((ys == 5) | (ys == 15))[..., None], C((150, 120, 70)), face)
    elif theme == "bt":
        face = ashlar(w, 22, [(14, 20, 16), (28, 36, 30), (44, 54, 46), (60, 72, 60)], seed=seed)
    elif theme == "tk":
        face = ashlar(w, 22, [(30, 18, 44), (56, 34, 76), (80, 50, 104), (104, 70, 128)], seed=seed, bh=11, bw=22)
    elif theme == "kara":
        face = ashlar(w, 22, [(22, 16, 30), (44, 32, 58), (64, 48, 82), (84, 66, 104)], seed=seed)
    img[y0:y0 + 22, x0:x0 + w] = face
    # the cornice (the wall top above the face) in the theme's trim
    img[y0 - 10:y0, x0:x0 + w] = C(WALL[1])
    img[y0 - 10, x0:x0 + w] = C(WALL[3])
    img[y0 - 3:y0 - 1, x0:x0 + w] = C(tr[2])
    img[y0 - 1, x0:x0 + w] = C(tr[0])
    img[y0 + 21, x0:x0 + w] = C(WALL[0])
    decor = []
    if theme == "kara":
        for i, x in enumerate(range(6, w - 14, 30)):
            decor.append((bookshelf(seed + i), x, 1))
    elif theme == "gruul":
        decor += [(chains(20), 10, 0), (crossed_clubs(), w // 2 - 12, 1), (chains(20), w - 30, 0)]
    elif theme == "mag":
        for x in range(8, w - 10, 28):
            decor.append((chains(21), x, 0))
            decor.append((fel_rune(), x + 12, 6))
    elif theme == "ssc":
        decor += [(coral(seed), 4, 6), (coral(seed + 1), w - 20, 6)]
    elif theme == "tk":
        for x in range(10, w - 20, 40):
            decor.append((nether_window(seed + x), x, 1))
    elif theme == "hyjal":
        for x in range(4, w - 12, 22):
            decor.append((vines(seed + x), x, 0))
    elif theme == "bt":
        for x in range(14, w - 16, 44):
            decor.append((illidari_banner(), x, 0))
    elif theme == "za":
        for i, x in enumerate(range(10, w - 16, 34)):
            decor.append((troll_mask(i), x, 3))
    for spr, x, y in decor:
        _blit(img, _img(spr), x0 + x, y0 + y)
    if sealed:
        sub = img[y0:y0 + 22, x0:x0 + w]
        img[y0:y0 + 22, x0:x0 + w] = sub * 0.5 + np.array([40, 38, 44]) * 0.3
        for x in range(8, w - 24, 46):
            _blit(img, _img(scaffold()), x0 + x, y0 - 6)
        _blit(img, _img(cobweb()), x0, y0)


def bookshelf(seed):
    s = Spr(24, 20)
    s.rect(0, 0, 23, 19, DWOOD[2]); s.rect(0, 0, 23, 0, DWOOD[4]); s.rect(1, 1, 22, 18, DWOOD[0])
    cols = [PURP, RED, TEAL, GOLD, BLUE, CLOTH]
    for sh, yb in enumerate((8, 17)):
        x = 1
        while x < 22:
            c = cols[int(H(x, sh, seed) * len(cols))]
            bw = 1 + int(H(x, sh + 4, seed) * 2)
            th = 5 + int(H(x, sh + 8, seed) * 3)
            s.rect(x, yb - th + 1, min(22, x + bw - 1), yb, c[2]); s.put(x, yb - th + 1, c[3])
            x += bw + (1 if H(x, sh + 2, seed) < 0.2 else 0)
        s.rect(1, yb + 1, 22, yb + 1, DWOOD[3])
    s.outline(0.4)
    return s


def chains(h):
    s = Spr(6, h)
    for y in range(0, h - 2, 3):
        if (y // 3) % 2:
            s.rect(2, y, 3, y + 2, IRON[3]); s.put(3, y + 1, IRON[1])
        else:
            s.rect(1, y + 1, 4, y + 1, IRON[2]); s.put(1, y + 1, IRON[3])
    s.rect(0, h - 3, 5, h - 1, IRON[2]); s.rect(0, h - 3, 5, h - 3, IRON[3])
    return s


def crossed_clubs():
    s = Spr(24, 20)
    s.line(2, 18, 20, 2, WOOD[2]); s.line(3, 18, 21, 2, WOOD[1])
    s.line(2, 2, 20, 18, WOOD[3]); s.line(3, 2, 21, 18, WOOD[2])
    s.ellipse(20, 3, 3, 3, lambda x, y: WOOD[3]); s.ellipse(3, 3, 3, 3, lambda x, y: WOOD[2])
    for x, y in ((19, 1), (22, 4), (2, 1), (4, 5)):
        s.put(x, y, IRON[4])
    s.outline(0.4)
    return s


def fel_rune():
    s = Spr(10, 10)
    for x, y in ((4, 0), (5, 0), (2, 2), (7, 2), (1, 4), (8, 4), (4, 4), (5, 4), (2, 6), (7, 6), (4, 8), (5, 8), (4, 2), (5, 6)):
        s.put(x, y, FEL[3])
    return s


def coral(seed):
    s = Spr(16, 16)
    for b in range(4):
        x = 3 + b * 3
        for y in range(15, 4 + int(H(b, 1, seed) * 5), -1):
            s.put(x + int(math.sin(y * 0.8 + b) * 1.2), y, [(230, 110, 120), (250, 150, 120), (190, 80, 140)][b % 3])
    s.outline(0.45)
    return s


def nether_window(seed):
    s = Spr(20, 20)
    for y in range(20):
        for x in range(20):
            if y < 8 and (x - 9.5) ** 2 + (y - 8) ** 2 > 9.5 ** 2:
                continue
            c = (14, 6, 30)
            n = math.sin(x * 0.5 + y * 0.3 + seed) + math.sin(y * 0.4 - x * 0.2)
            if n > 1.1:
                c = (90, 40, 140)
            elif n > 0.6:
                c = (50, 20, 90)
            if H(x, y, seed) > 0.96:
                c = (250, 240, 255)
            s.put(x, y, c)
    for y in range(20):
        s.put(0, y, GOLD[2]); s.put(19, y, GOLD[1])
    s.rect(0, 18, 19, 19, GOLD[2])
    s.outline(0.4)
    return s


def vines(seed):
    s = Spr(12, 20)
    for y in range(20):
        x = 5 + 2 * math.sin(y * 0.5 + seed)
        s.put(x, y, LEAF[1])
        if H(y, 2, seed) > 0.55:
            s.put(x + (1 if y % 2 else -1), y, LEAF[3])
            if H(y, 3, seed) > 0.7:
                s.put(x + (2 if y % 2 else -2), y, (200, 255, 210))
    return s


def illidari_banner():
    s = Spr(14, 21)
    s.rect(0, 0, 13, 1, IRON[3])
    s.fill(1, 2, 12, 16, lambda x, y: (24, 40, 22) if x > 8 else (36, 60, 30))
    s.poly([(1, 16.5), (12.9, 16.5), (12.9, 20.5), (7, 17.5), (1, 20.5)], lambda x, y: (24, 40, 22))
    s.ellipse(7, 9, 3.5, 2, lambda x, y: FEL[3]); s.rect(6, 8, 7, 10, (10, 14, 10))
    s.rect(1, 3, 12, 3, FEL[2])
    s.outline(0.4)
    return s


def troll_mask(i):
    s = Spr(16, 18)
    col = [(176, 92, 52), (90, 140, 120), (180, 60, 50)][i % 3]
    s.ellipse(8, 9, 6, 8, lambda x, y: col if x < 9 else tuple(int(v * 0.75) for v in col))
    s.rect(4, 6, 6, 8, (20, 10, 6)); s.rect(10, 6, 12, 8, (20, 10, 6))
    s.rect(5, 13, 11, 14, (40, 14, 10)); s.put(4, 14, BONE[3]); s.put(12, 14, BONE[3])
    s.line(1, 0, 4, 4, (230, 210, 120)); s.line(15, 0, 12, 4, (230, 210, 120))
    s.outline(0.4)
    return s


def scaffold():
    s = Spr(24, 30)
    for x in (2, 20):
        s.rect(x, 0, x + 1, 29, WOOD[2]); s.rect(x, 0, x, 29, WOOD[3])
    for y in (6, 18):
        s.rect(0, y, 23, y + 1, WOOD[3]); s.rect(0, y + 1, 23, y + 1, WOOD[1])
    s.line(3, 7, 20, 18, WOOD[1])
    s.outline(0.45)
    return s


def cobweb():
    s = Spr(10, 10)
    for i in range(10):
        s.put(i, 0, (200, 200, 200)); s.put(0, i, (200, 200, 200))
        s.put(i, 9 - i if i < 7 else 2, (170, 170, 170))
    for k in (3, 6):
        for i in range(k + 1):
            s.put(i, k - i, (150, 150, 150))
    return s


def rubble(seed):
    s = Spr(16, 10)
    for i in range(7):
        x = 2 + H(i, 1, seed) * 11
        y = 4 + H(i, 2, seed) * 4
        r = 1.2 + H(i, 3, seed) * 1.8
        s.ellipse(x, y, r, r * 0.8, lambda a, b: STONE[3] if b < y else STONE[1])
    s.outline(0.45)
    return s


def stanchion():
    s = Spr(6, 16)
    s.rect(2, 3, 3, 14, GOLD[2]); s.rect(2, 3, 2, 14, GOLD[3])
    s.ellipse(2.5, 2, 2, 2, lambda x, y: GOLD5[4] if x < 3 else GOLD[2])
    s.rect(0, 14, 5, 15, GOLD[1])
    return s


def manticron():
    s = Spr(10, 10)
    s.rect(1, 3, 8, 9, BASALT[2]); s.rect(1, 3, 8, 3, BASALT[4]); s.rect(8, 4, 8, 9, BASALT[1])
    s.rect(3, 5, 6, 7, FEL[3]); s.put(4, 6, FEL[4])
    s.outline(0.4)
    return s


def gronn_skull():
    s = Spr(34, 26)
    s.ellipse(17, 12, 15, 11, lambda x, y: BONE[2] if x < 17 else BONE[1])
    s.ellipse(11, 11, 4, 3.5, lambda x, y: (26, 20, 16)); s.ellipse(23, 11, 4, 3.5, lambda x, y: (26, 20, 16))
    s.rect(10, 19, 24, 24, BONE[1]); s.rect(10, 19, 24, 19, BONE[2])
    for x in range(11, 24, 3):
        s.rect(x, 20, x + 1, 23, BONE[3])
    s.line(16, 2, 20, 9, BONE[0])
    s.outline(0.42)
    return s


def crystal(col):
    s = Spr(10, 18)
    s.poly([(5, 0), (9, 6), (7, 17), (3, 17), (1, 6)], lambda x, y: tuple(min(255, int(v * (1.25 if x < 5 else 0.8))) for v in col))
    s.line(5, 1, 5, 16, tuple(min(255, v + 70) for v in col))
    s.outline(0.4)
    return s


def wisp_tree_root():
    s = Spr(40, 20)
    for i in range(40):
        y = 14 - 10 * math.sin(i / 39 * math.pi)
        s.rect(i, int(y), i, int(y) + 3, (96, 70, 48))
        s.put(i, int(y), (140, 108, 74))
    s.outline(0.4)
    return s


def fel_brazier():
    return brazier(ramp=[(20, 30, 20), (36, 50, 36), (60, 80, 60), (90, 110, 86)], bowl=[(20, 40, 18), (40, 80, 30), (70, 130, 50), (120, 190, 90)])


def totem_pole():
    s = Spr(12, 34)
    for i, col in enumerate([(176, 92, 52), (90, 140, 120), (180, 60, 50), (176, 92, 52)]):
        y0 = i * 8
        s.rect(1, y0, 10, y0 + 7, col); s.rect(1, y0, 1, y0 + 7, tuple(min(255, v + 40) for v in col))
        s.rect(3, y0 + 2, 4, y0 + 3, (20, 10, 6)); s.rect(7, y0 + 2, 8, y0 + 3, (20, 10, 6)); s.rect(4, y0 + 5, 7, y0 + 5, BONE[3])
    s.rect(4, 32, 7, 33, JUNG[1])
    s.outline(0.4)
    return s


def wing_banner(theme):
    ramp = THEME[theme]["banner"]
    tr = THEME[theme]["trim"]
    s = great_banner(12, 24, list(ramp) + [ramp[-1]] * 2, tr if len(tr) >= 3 else GOLD, glyph=None)
    sig = {"kara": [(5, 8), (6, 8), (5, 9), (6, 9), (4, 10), (7, 10), (5, 7), (6, 7)],
           "gruul": [(3, 9), (4, 8), (5, 9), (6, 8), (7, 9), (8, 8), (5, 11), (6, 11)],
           "mag": [(5, 7), (6, 7), (4, 9), (7, 9), (5, 11), (6, 11), (3, 6), (8, 6)],
           "ssc": [(5, 7), (5, 8), (5, 9), (5, 10), (3, 7), (7, 7), (3, 8), (7, 8)],
           "tk": [(5, 7), (6, 7), (4, 8), (7, 8), (4, 9), (7, 9), (5, 10), (6, 10)],
           "hyjal": [(5, 6), (4, 7), (6, 7), (3, 8), (7, 8), (5, 8), (5, 9), (5, 10)],
           "bt": [(4, 8), (5, 8), (6, 8), (7, 8), (5, 7), (6, 9), (3, 8), (8, 8)],
           "za": [(4, 7), (7, 7), (4, 8), (7, 8), (5, 10), (6, 10), (3, 6), (8, 6)],
           "sw": [(5, 7), (6, 7), (5, 8), (6, 8), (4, 6), (7, 6), (4, 9), (7, 9)]}[theme]
    for x, y in sig:
        s.put(x, y + 1, GOLD5[4])
    return s


# ------------------------------------------------------------------------------------------- the painter

def carpet(img, x0, y0, w, h):
    """royal carpet: gold border with a dash pattern, deep red field with a diamond lattice, worn down the middle"""
    ys, xs = np.mgrid[0:h, 0:w]
    f = np.zeros((h, w, 3))
    f[:] = C(VEL[2])
    lat = ((xs + ys) % 12 == 0) | ((xs - ys) % 12 == 0)
    f[lat] = C(VEL[1])
    dot = ((xs + ys) % 12 == 6) & ((xs - ys) % 12 == 6)
    f[dot] = C(GOLD[2])
    wear = np.exp(-((xs - w / 2) / (w * 0.22)) ** 2) * (0.5 + 0.5 * vnoise(w, h, 6, 31))
    f = f * (1 - 0.12 * wear[..., None]) + C(VEL[4]) * 0.12 * wear[..., None]
    b = (xs < 5) | (xs >= w - 5)
    f[b] = C(GOLD[2])
    f[b & ((ys % 6) < 2)] = C(GOLD[3])
    f[(xs == 0) | (xs == w - 1)] = C(GOLD[0])
    f[(xs == 5) | (xs == w - 6)] = C(VEL[0])
    img[y0:y0 + h, x0:x0 + w] = f


def mosaic(img, cx, cy, R):
    """the rotunda: rings of tesserae, an eight-point gold star on lapis, the guild lion in a red roundel"""
    H_, W_ = img.shape[:2]
    for y in range(int(cy - R) - 1, int(cy + R) + 2):
        for x in range(int(cx - R) - 1, int(cx + R) + 2):
            if not (0 <= x < W_ and 0 <= y < H_):
                continue
            dx, dy = x + 0.5 - cx, y + 0.5 - cy
            d = math.hypot(dx, dy)
            if d > R:
                continue
            a = math.atan2(dy, dx)
            tx, ty = x // 2, y // 2
            jit = (H(tx, ty, 77) - 0.5) * 18
            if d > R - 2:
                c = GOLD[1]
            elif d > R - 7:
                c = GOLD[2] if (tx + ty) % 2 else GOLD[3]
            elif d > R - 9:
                c = (30, 30, 50)
            elif d > R - 22:
                k = (int((a + math.pi) / (2 * math.pi) * 48)) % 2
                c = (36, 58, 120) if k else (52, 82, 156)
                if abs(d - (R - 15.5)) < 1:
                    c = GOLD[2]
            else:
                ray = abs(math.cos(a * 4))
                long_ = 1 - (0.35 if (int(round(a / (math.pi / 4))) % 2) else 0)
                star = d < (R - 22) * (0.25 + 0.75 * ray ** 6 * long_)
                c = GOLD[3] if star and (dx < 0) == (dy < 0) else GOLD[2] if star else (26, 40, 92)
                if d < 15:
                    c = VEL[2] if d < 13.5 else GOLD5[4]
            col = np.array(c, dtype=np.float64) + jit
            if x % 2 == 0 and y % 2 == 0:
                col *= 0.86                                     # the grout between tesserae
            img[y, x] = col
    sc = 2
    for gx, gy in lion_glyph():
        for a_ in range(sc):
            for b_ in range(sc):
                img[int(cy) - 15 + gy * sc + b_, int(cx) - 13 + gx * sc + a_] = C(GOLD[3] if gx < 7 else GOLD[2])


def contact(img, x, y, rx, ry=2.6, k=0.62):
    H_, W_ = img.shape[:2]
    for yy in range(int(y - ry) - 1, int(y + ry) + 2):
        for xx in range(int(x - rx) - 1, int(x + rx) + 2):
            if 0 <= xx < W_ and 0 <= yy < H_:
                d = ((xx + 0.5 - x) / rx) ** 2 + ((yy + 0.5 - y) / ry) ** 2
                if d <= 1:
                    f = k if d < 0.45 else (1 + k) / 2
                    img[yy, xx] = img[yy, xx] * f


def long_shadow(img, x0, y0, w, length, k=0.8):
    """a pillar's shadow thrown down-right across the floor (light from the top left)"""
    for i in range(length):
        for xx in range(w):
            x = int(x0 + xx + i * 0.55)
            y = y0 + i
            if 0 <= x < img.shape[1] and 0 <= y < img.shape[0]:
                f = k + (1 - k) * (i / length)
                img[y, x] *= f


def reflection(img, spr, x, y, alpha=0.16, depth=14):
    """polished marble shows a faint upside-down copy of what stands on it"""
    a = _img(spr)
    h = a.shape[0]
    for i in range(min(depth, h)):
        row = a[h - 1 - i]
        yy = y + i
        if not (0 <= yy < img.shape[0]):
            continue
        fade = alpha * (1 - i / depth)
        for xx in range(a.shape[1]):
            if row[xx, 3] > 0 and 0 <= x + xx < img.shape[1]:
                img[yy, x + xx] = img[yy, x + xx] * (1 - fade) + row[xx, :3] * fade


def paint(sealed=False, night=False):
    """the hall as one picture plus the plan the renderer needs"""
    img = np.zeros((HT, W, 3))
    img[:] = (10, 9, 14)
    plan = {"sprites": [], "lights": [], "fires": [], "fx": [], "plinths": [], "solid": [[0] * TW for _ in range(TH)],
            "wings": [], "water": [], "shafts": [], "npcs": [], "objects": []}
    solid = plan["solid"]

    def block(x0, y0, x1, y1):
        for yy in range(y0, y1 + 1):
            for xx in range(x0, x1 + 1):
                solid[yy][xx] = 1

    def sprite(name, spr, px, py, foot, wing=None):
        plan["sprites"].append({"name": name, "spr": spr, "x": px, "y": py, "foot": foot, "wing": wing})

    def light(px, py, r, col, wing=None, flick=1, kind="glow"):
        plan["lights"].append({"x": px, "y": py, "r": r, "c": list(col), "wing": wing, "f": flick, "k": kind})

    # --- main floor: the whole interior in marble
    img[80:32 * 16, 16:W - 16] = floor_marble(W - 32, 32 * 16 - 80, seed=1)
    # gold inlay strips framing the nave
    for x in (13 * 16 + 1, 23 * 16 - 3):
        img[8 * 16:32 * 16, x:x + 2] = C(GOLD[2])
        img[8 * 16:32 * 16, x + 2] = C(MARB[1])

    # --- north wall (rows 0-4): cornice, ashlar, pilasters, stained glass, rose window, the great banner
    img[0:10, :] = C(WALL[1]); img[9, :] = C(WALL[3]); img[0, :] = C(WALL[0])
    img[10:72, 16:W - 16] = ashlar(W - 32, 62, WALL, seed=21)
    img[68:72, 16:W - 16] = C(WALL[1])
    img[72:80, 16:W - 16] = C(WALL[2]); img[72, 16:W - 16] = C(GOLD[2]); img[79, 16:W - 16] = C(WALL[0])
    for px in list(range(40, 230, 64)) + list(range(W - 40 - 12, W - 230, -64)):
        img[10:72, px:px + 12] = ashlar(12, 62, [WALL[1], WALL[2], WALL[3], WALL[4]], seed=px, bh=10, bw=12)
        img[10:72, px] *= 1.15
        img[10:72, px + 11] *= 0.7
        img[10:16, px - 1:px + 13] = C(GOLD[1]); img[10, px - 1:px + 13] = C(GOLD[3])
    windows = [(66, "blue"), (130, "red"), (194, "purple"), (W - 66 - 20, "blue"), (W - 130 - 20, "red"), (W - 194 - 20, "purple")]
    for wx, scheme in windows:
        _blit(img, _img(stained_glass(20, 52, scheme, night, seed=wx)), wx, 14)
        plan["shafts"].append({"x": wx + 1, "y": 66, "w": 18, "c": {"blue": [150, 180, 255], "red": [255, 160, 140],
                                                                     "purple": [210, 170, 255]}[scheme]})
    rr = 20
    _blit(img, _img(rose_window(rr, night)), W // 2 - rr - 1, 4)
    plan["shafts"].append({"x": W // 2 - 14, "y": 46, "w": 28, "c": [255, 220, 170]})
    _blit(img, _img(great_banner(36, 40, VEL, GOLD)), W // 2 - 18, 40)
    for bx in (W // 2 - 64, W // 2 + 64 - 16):
        _blit(img, _img(great_banner(16, 34, [(20, 30, 70), (30, 46, 100), (44, 66, 136), (70, 100, 170)], GOLD)), bx, 30)
    block(0, 0, TW - 1, 4)

    # --- outer side walls and the south wall (seen from above)
    for x0 in (0, W - 16):
        img[0:HT - 16, x0:x0 + 16] = C(WALL[1])
        edge = x0 + 15 if x0 == 0 else x0
        img[10:HT - 16, edge] = C(WALL[3])
        for y in range(16, HT - 16, 48):
            img[y:y + 4, x0:x0 + 16] = C(WALL[2])
    block(0, 0, 0, TH - 1); block(TW - 1, 0, TW - 1, TH - 1)
    img[32 * 16:HT, :] = C(WALL[1]); img[32 * 16, :] = C(WALL[3]); img[32 * 16 + 3:32 * 16 + 5, 16:W - 16] = C(GOLD[1])
    img[33 * 16:HT, :] = (10, 9, 14)
    block(0, 32, TW - 1, 33)
    # the grand stair up to the inn (2 tiles wide), its rails
    sx0 = 16 * 16
    for i in range(4):
        y = 32 * 16 + i * 8
        img[y:y + 8, sx0:sx0 + 64] = C(MARB[3 - (i % 2)])
        img[y, sx0:sx0 + 64] = C(MARB[5]); img[y + 7, sx0:sx0 + 64] = C(MARB[1])
        img[y:y + 8, sx0:sx0 + 64] *= 1 - i * 0.12
    img[32 * 16:HT, sx0 - 3:sx0] = C(GOLD[1]); img[32 * 16:HT, sx0 + 64:sx0 + 67] = C(GOLD[1])
    for xx in (17, 18):
        solid[32][xx] = 0
    plan["exit"] = {"x": 17, "y": 32}

    # --- the dais (x 12..23, rows 5..7): raised white-gold marble, three steps at its front
    dx0, dx1 = 12 * 16, 24 * 16
    img[80:7 * 16, dx0:dx1] = floor_sun(dx1 - dx0, 32, seed=8)
    img[80:7 * 16, dx0:dx0 + 2] = C(GOLD[2]); img[80:7 * 16, dx1 - 2:dx1] = C(GOLD[1])
    for i in range(3):
        y = 7 * 16 + i * 5
        x_a, x_b = dx0 - i * 4, dx1 + i * 4
        img[y:y + 5, x_a:x_b] = C(MARB[4 - i])
        img[y, x_a:x_b] = C(MARB[5]); img[y + 4, x_a:x_b] = C(MARB[1])
        img[y + 1, x_a:x_b] = C(GOLD[2]) if i == 0 else img[y + 1, x_a:x_b]
    carpet(img, 16 * 16, 80, 64, 32)
    sprite("throne", throne(), W // 2 - 16, 6 * 16 + 16 - 46, foot=6 * 16 + 15)
    block(17, 5, 18, 6)
    for bx in (15, 20):
        sprite("brazier", brazier(), bx * 16, 6 * 16 + 16 - 26, foot=6 * 16 + 14)
        plan["fires"].append({"x": bx * 16 + 2, "y": 6 * 16 + 16 - 26 + 1, "w": 12, "h": 9, "kind": "gold"})
        light(bx * 16 + 8, 6 * 16 - 4, 64, (255, 200, 130))
        block(bx, 6, bx, 6)
    sw_slots = [12, 13, 14, 21, 22, 23]
    swr = {"key": SUNWELL["key"], "theme": "sw", "short": SUNWELL["short"], "rect": [12 * 16, 80, 12 * 16, 48]}
    plan["wings"].append(swr)
    for i, sx in enumerate(sw_slots[:6]):
        px, py = sx * 16, 6 * 16
        contact(img, px + 8, py + 15.5, 7)
        if sealed:
            _blit(img, _img(shroud()), px, py)
        else:
            _blit(img, _img(pedestal(ramp=[SUNC[0], SUNC[1], SUNC[2], SUNC[3], SUNC[4], SUNC[4]], band=VEL)), px, py - 4)
        plan["plinths"].append({"wing": "SunwellPlateau", "i": i, "x": sx, "y": 6, "theme": "sw"})
        block(sx, 6, sx, 6)
    if not sealed:
        light(W // 2, 80, 92, (255, 228, 150), wing="SunwellPlateau", flick=0, kind="holy")
    plan["fx"].append({"type": "sun", "rect": [12 * 16, 64, 12 * 16, 48], "wing": "SunwellPlateau"})
    # sunwell banners at the dais corners
    for bx in (dx0 + 2, dx1 - 14):
        _blit(img, _img(wing_banner("sw")), bx, 42)

    # --- upper gallery corners (rows 5..6 outside the dais): hearths on the north wall, armour stands
    hearth_spr = hearth()
    for hx in (3 * 16, W - 5 * 16):
        _blit(img, _img(hearth_spr), hx, 5 * 16 - 26 + 16)
        plan["fires"].append({"x": hx + 7, "y": 5 * 16 - 26 + 16 + 17, "w": 19, "h": 13, "kind": "hearth"})
        light(hx + 16, 5 * 16 + 14, 76, (255, 190, 120))
        block(hx // 16, 5, hx // 16 + 1, 5)
    for gx in (7, 9, 26, 28):
        sprite("brazier", brazier(), gx * 16, 5 * 16 + 16 - 26, foot=5 * 16 + 14)
        plan["fires"].append({"x": gx * 16 + 2, "y": 5 * 16 + 16 - 26 + 1, "w": 12, "h": 9, "kind": "gold"})
        light(gx * 16 + 8, 5 * 16 - 2, 46, (255, 196, 120))
        block(gx, 5, gx, 5)

    # --- the nave: carpet and the rotunda mosaic (the eight colossal pillars were taken out 2026-10-15: they stood in
    # the way and made the layout hard to read)
    carpet(img, 16 * 16, 8 * 16 + 4, 64, 31 * 16 - 8 * 16 - 4)
    rcx, rcy, R = 18 * 16, 19 * 16 + 8, 76
    mosaic(img, rcx, rcy, R)
    plan["chandelier"] = {"x": rcx, "y": rcy}
    light(rcx, rcy, 120, (255, 214, 150), flick=1, kind="chandelier")
    # the chandelier's shadow ring on the floor by day
    plan["fx"].append({"type": "dust", "rect": [13 * 16, 5 * 16, 10 * 16, 16 * 16], "wing": None})

    # --- the wings
    for wi, wg in enumerate(WINGS):
        side, Y, theme = wg["side"], wg["Y"], wg["theme"]
        x0t, x1t, mouth = wing_cols(side)
        px0 = x0t * 16
        wpx = (x1t - x0t + 1) * 16
        face_x0 = px0 if side == "l" else px0 + 16
        face_w = wpx - 16
        # floor
        fl = FLOORS[theme](wpx, 48)
        if sealed:
            dust = hashmap(wpx, 48, 50 + wi)
            fl = fl * 0.42 + np.array([46, 44, 50]) * 0.58 * 0.8
            fl[dust > 0.97] = fl[dust > 0.97] * 0.6 + 70
        img[(Y + 2) * 16:(Y + 5) * 16, px0:px0 + wpx] = fl
        # ambient occlusion at the back wall
        for k_, f_ in ((0, 0.6), (1, 0.72), (2, 0.84), (3, 0.92)):
            img[(Y + 2) * 16 + k_, px0:px0 + wpx] *= f_
        # back wall: cornice on row Y, face on rows Y..Y+1 (22 px)
        wing_face(img, theme, face_x0, Y * 16 + 10, face_w, sealed, seed=wi * 13 + 5)
        block(min(x0t, x1t), Y, max(x0t, x1t), Y + 1)
        # the mouth: a pillar-end with the raid's banner; light at the mouth
        mpx = mouth * 16
        img[Y * 16:(Y + 2) * 16, mpx:mpx + 16] = ashlar(16, 32, WALL, seed=wi + 70, bh=8, bw=8)
        img[Y * 16:(Y + 2) * 16, mpx + (15 if side == "l" else 0)] = C(WALL[0])
        img[Y * 16, mpx:mpx + 16] = C(WALL[4])
        _blit(img, _img(wing_banner(theme) if not sealed else furled_banner()), mpx + 2, Y * 16 + 6)
        rect = [px0, Y * 16, wpx, 80]
        plan["wings"].append({"key": wg["key"], "theme": theme, "short": wg["short"], "rect": rect, "side": side,
                              "Y": Y, "mouth": mouth})
        tl = THEME[theme]["light"]
        # side theme features + lights
        cx = px0 + wpx // 2
        if not sealed:
            light(cx - 50, (Y + 3) * 16, 58, tl, wing=wg["key"], flick=1)
            light(cx + 50, (Y + 3) * 16, 58, tl, wing=wg["key"], flick=1)
        def T(dx):
            return mx(side, dx) * 16
        if theme == "kara":
            plan["fx"].append({"type": "arcane", "rect": rect, "wing": wg["key"]})
            for k_ in range(5):
                plan["fx"].append({"type": "candle", "x": px0 + 18 + k_ * 38, "y": (Y + 2) * 16 + 4 + (k_ % 2) * 16,
                                   "wing": wg["key"]})
        elif theme == "gruul":
            if not sealed:
                sprite("skull", gronn_skull(), px0 + 6, (Y + 2) * 16 + 2, foot=(Y + 3) * 16 + 11, wing=wg["key"])
                block(1, Y + 2, 2, Y + 3)
            plan["fx"].append({"type": "dust", "rect": rect, "wing": wg["key"]})
        elif theme == "mag":
            cxp = px0 + 6 * 16 + 8
            for k_ in range(5):
                a = -math.pi / 2 + k_ * 2 * math.pi / 5
                mxp, myp = cxp + math.cos(a) * 40, (Y + 3) * 16 + 8 + math.sin(a) * 16
                contact(img, mxp, myp + 5, 5)
                _blit(img, _img(manticron()), int(mxp - 5), int(myp - 5))
                if not sealed:
                    light(mxp, myp, 22, (110, 255, 80), wing=wg["key"], flick=1)
            plan["fx"].append({"type": "fel", "rect": rect, "wing": wg["key"]})
        elif theme == "ssc":
            wx0 = face_x0 + 26
            wwid = face_w - 52
            # a sheet of water running down the back wall into a basin along the back
            img[Y * 16 + 12:Y * 16 + 31, wx0:wx0 + wwid] = C(SEA[2])
            plan["water"].append({"x": wx0, "y": Y * 16 + 12, "w": wwid, "h": 19, "fall": 1, "wing": wg["key"]})
            img[(Y + 2) * 16:(Y + 2) * 16 + 6, wx0 - 4:wx0 + wwid + 4] = C(SEA[1])
            img[(Y + 2) * 16 + 6, wx0 - 4:wx0 + wwid + 4] = C(SEA[4])
            plan["water"].append({"x": wx0 - 4, "y": (Y + 2) * 16, "w": wwid + 8, "h": 6, "fall": 0, "wing": wg["key"]})
            plan["fx"].append({"type": "bubbles", "rect": rect, "wing": wg["key"]})
        elif theme == "tk":
            for k_, row in enumerate((Y + 2, Y + 4)):
                sprite("crystal", crystal((220, 120, 255) if k_ else (255, 190, 90)), T(1) + 3, row * 16 - 2,
                       foot=row * 16 + 15, wing=wg["key"])
                block(mx(side, 1), row, mx(side, 1), row)
                if not sealed:
                    light(T(1) + 8, row * 16 + 6, 34, (255, 150, 230), wing=wg["key"], flick=0)
            plan["fx"].append({"type": "stars", "rect": rect, "wing": wg["key"]})
        elif theme == "hyjal":
            _blit(img, _img(wisp_tree_root()), px0 + 8, (Y + 2) * 16 + 24)
            _blit(img, _img(wisp_tree_root()), px0 + wpx - 50, (Y + 2) * 16 + 4)
            plan["fx"].append({"type": "wisps", "rect": rect, "wing": wg["key"]})
        elif theme == "bt":
            for dx_ in (1, 11):
                bxp, row = T(dx_), Y + 4
                sprite("felbrazier", fel_brazier(), bxp, row * 16 + 16 - 26, foot=row * 16 + 14, wing=wg["key"])
                plan["fires"].append({"x": bxp + 2, "y": row * 16 + 16 - 26 + 1, "w": 12, "h": 9, "kind": "fel",
                                      "wing": wg["key"]})
                block(mx(side, dx_), row, mx(side, dx_), row)
                if not sealed:
                    light(bxp + 8, row * 16 - 4, 44, (110, 255, 80), wing=wg["key"])
            plan["fx"].append({"type": "fel", "rect": rect, "wing": wg["key"]})
        elif theme == "za":
            for dx_, row in ((1, Y + 2), (1, Y + 4)):
                txp = T(dx_) + 2
                sprite("totem", totem_pole(), txp, row * 16 + 16 - 34, foot=row * 16 + 15, wing=wg["key"])
                plan["fires"].append({"x": txp + 2, "y": row * 16 + 16 - 40, "w": 8, "h": 7, "kind": "torch",
                                      "wing": wg["key"]})
                block(mx(side, dx_), row, mx(side, dx_), row)
                if not sealed:
                    light(txp + 6, row * 16 - 18, 40, (255, 150, 70), wing=wg["key"])
            plan["fx"].append({"type": "embers", "rect": rect, "wing": wg["key"]})
        # plinths
        slots = plinth_slots(wg["n"])
        for i, (dx, dy) in enumerate(slots):
            tx = mx(side, dx) if side == "l" else mx(side, dx)
            ty = Y + dy
            ppx, ppy = tx * 16, ty * 16
            contact(img, ppx + 8, ppy + 15.5, 7)
            if sealed:
                _blit(img, _img(shroud()), ppx, ppy)
            else:
                _blit(img, _img(pedestal()), ppx, ppy - 4)
            plan["plinths"].append({"wing": wg["key"], "i": i, "x": tx, "y": ty, "theme": theme})
            block(tx, ty, tx, ty)
        if sealed:
            # rope across the mouth, rubble
            for k_ in range(3):
                _blit(img, _img(stanchion()), mouth * 16 + 5, (Y + 2 + k_) * 16)
            for k_ in range(3):
                yy = (Y + 2 + k_) * 16 + 6
                img[yy:yy + 14, mouth * 16 + 7:mouth * 16 + 9] = C(VEL[2])
            for k_ in range(2):
                _blit(img, _img(rubble(wi * 3 + k_)), px0 + 20 + k_ * 120, (Y + 3) * 16 + 4)
            plan["objects"].append({"kind": "rope", "wing": wg["key"], "x": mouth, "y0": Y + 2, "y1": Y + 4})
            light(mouth * 16 + 8, (Y + 3) * 16, 46, (150, 160, 190), wing=wg["key"], flick=0, kind="spot")
    # balustrade between the last wings and the lower hall (row 27, x 1..11 and 24..34)
    for xs_, xe_ in ((1, 11), (24, 34)):
        y = 27 * 16
        img[y + 2:y + 6, xs_ * 16:(xe_ + 1) * 16] = C(MARB[4]); img[y + 2, xs_ * 16:(xe_ + 1) * 16] = C(MARB[5])
        img[y + 6:y + 7, xs_ * 16:(xe_ + 1) * 16] = C(MARB[1])
        for x in range(xs_ * 16 + 2, (xe_ + 1) * 16 - 2, 5):
            img[y + 7:y + 14, x:x + 3] = C(MARB[3]); img[y + 7:y + 14, x] = C(MARB[4]); img[y + 7:y + 14, x + 2] = C(MARB[1])
        img[y + 14:y + 16, xs_ * 16:(xe_ + 1) * 16] = C(MARB[2])
        contact(img, (xs_ + xe_ + 1) * 8, y + 17, (xe_ - xs_ + 1) * 8, 2, 0.8)
        block(xs_, 27, xe_, 27)
    for x in (12, 23):
        block(x, 27, x, 27)
        img[27 * 16:28 * 16, x * 16:(x + 1) * 16] = ashlar(16, 16, MARB, seed=x)

    # --- the lower hall (rows 28..31): champions, feast tables, the Bestiary lectern, the steward
    for i, sx in enumerate((3, 6, 9, 26, 29)):
        px, py = sx * 16, 29 * 16
        contact(img, px + 8, py + 14, 10)
        _blit(img, _img(statue_base()), px - 2, py + 4)
        plan["npcs"].append({"id": "statue%d" % (i + 1), "x": sx, "y": 29, "statue": True, "sprite": "hero",
                             "face": "down"})
        block(sx, 29, sx, 29)
        light(px + 8, py - 8, 26, (255, 236, 200), flick=0, kind="spot")
    for tx0 in (2, 25):
        rug_ = np.zeros((30, 8 * 16 + 8, 3))
        carpet(rug_, 0, 0, 8 * 16 + 8, 30)
        rug_[0:2] = C(GOLD[1]); rug_[-2:] = C(GOLD[1])
        img[30 * 16 + 6:30 * 16 + 36, tx0 * 16 - 2:tx0 * 16 + 8 * 16 + 6] = rug_
        tbl = feast_table(8)
        contact(img, tx0 * 16 + 64, 31 * 16 + 14, 66, 3, 0.7)
        sprite("table", tbl, tx0 * 16 + 2, 31 * 16 - 6, foot=31 * 16 + 14)
        block(tx0, 31, tx0 + 7, 31)
        for k_ in range(14 + 2, 8 * 16 - 8, 32):
            light(tx0 * 16 + 2 + k_, 31 * 16 - 6, 24, (255, 210, 150), flick=1, kind="candle")
    sprite("lectern", lectern(), 32 * 16, 29 * 16 + 16 - 22, foot=29 * 16 + 15)
    plan["objects"].append({"kind": "bestiary", "x": 32, "y": 29})
    block(32, 29, 32, 29)
    plan["npcs"].append({"id": "steward", "x": 20, "y": 30, "sprite": "bald", "face": "left", "tint": [0.9, 0.85, 0.7]})
    block(20, 30, 20, 30)
    return img, plan


def furled_banner():
    s = Spr(12, 24)
    s.rect(0, 0, 11, 1, GOLD[1])
    s.rect(3, 2, 8, 9, (80, 70, 64)); s.rect(3, 2, 4, 9, (110, 100, 92)); s.rect(3, 6, 8, 6, (60, 52, 48))
    s.outline(0.45)
    return s


ORANGE = [(120, 50, 14), (184, 86, 24), (228, 126, 40), (246, 168, 76)]


# ------------------------------------------------------------------------------------------- for the game

NIGHT_AMB = (34, 36, 66)


def light_map(plan, scale=2):
    """the night darkness (multiplied over the hall): a cold ambient, moonlight falling from the north windows and
    through each window in a beam, and soft coloured pools round every light. RGB uint8 at 1/scale."""
    w, h = W // scale, HT // scale
    ys, xs = np.mgrid[0:h, 0:w]
    px, py = xs * scale + scale / 2, ys * scale + scale / 2
    img = np.zeros((h, w, 3))
    img[:] = NIGHT_AMB
    wash = np.clip(1 - (py - 60) / 270, 0, 1) * ((py >= 60) & (px >= 16) & (px < W - 16))
    img += wash[..., None] * np.array([40, 52, 96])
    for sh in plan["shafts"]:
        L = 150 if sh["w"] > 20 else 175
        t = (py - sh["y"]) / L
        x0 = sh["x"] + (py - sh["y"]) * 0.42
        inside = (t >= 0) & (t <= 1) & (px >= x0) & (px <= x0 + sh["w"])
        img += (inside * (1 - t) * 0.55)[..., None] * np.array([80, 92, 150])
    for L in plan["lights"]:
        r = L["r"] * (1.15 if L["k"] == "chandelier" else 1.25)
        k = 0.8 if L["k"] == "holy" else 0.7 if L["k"] == "spot" else 0.62 if L["y"] < 112 else 0.85
        d = np.sqrt((px - L["x"]) ** 2 + ((py - L["y"]) / 0.8) ** 2) / r
        f = np.interp(d, [0, 0.35, 0.7, 1], [1, 0.62, 0.2, 0]) * k
        img += f[..., None] * np.array(L["c"], dtype=np.float64)
    return np.clip(np.round(img), 0, 255).astype(np.uint8)


def sun_overlay(plan):
    """the sun through the stained glass and the rose window, added over everything by day: a coloured beam from each
    window and the patch where it lands. RGB uint8, full size."""
    ys, xs = np.mgrid[0:HT, 0:W]
    out = np.zeros((HT, W, 3))
    for sh in plan["shafts"]:
        L = 150 if sh["w"] > 20 else 175
        t = (ys - sh["y"]) / L
        x0 = sh["x"] + (ys - sh["y"]) * 0.42
        inside = (t >= 0) & (t <= 1) & (xs >= x0) & (xs <= x0 + sh["w"])
        a = np.where(t < 0.75, 0.2 - 0.09 * t / 0.75, 0.11 * (1 - (t - 0.75) / 0.25)) * inside
        edge = inside & ((xs - x0 < 1.5) | (x0 + sh["w"] - xs < 1.5)) & ((xs + ys) % 2 == 1)
        a = np.where(edge, 0, a)
        cx, cy = sh["x"] + sh["w"] / 2 + L * 0.42 * 0.82, sh["y"] + L * 0.82
        d = np.sqrt(((xs - cx) / (sh["w"] * 1.1)) ** 2 + ((ys - cy) / (sh["w"] * 0.55)) ** 2)
        a = a + np.clip(1 - d, 0, 1) * 0.18
        out = np.maximum(out, a[..., None] * np.array(sh["c"], dtype=np.float64))
    return np.clip(np.round(out), 0, 255).astype(np.uint8)


FIRE_PAL = {"gold": FIRE, "hearth": FIRE, "torch": FIRE,
            "fel": [(14, 42, 10), (34, 122, 20), (70, 184, 40), (140, 240, 80), (224, 255, 192)]}
FIRE_SIZE = {"gold": (12, 9), "hearth": (19, 13), "torch": (8, 7), "fel": (12, 9)}
FIRE_FRAMES_N = 8


def fire_frames(kind):
    """FIRE_FRAMES_N frames of pixel flames (RGBA) for a brazier bowl, a hearth's mouth or a torch head"""
    w, h = FIRE_SIZE[kind]
    pal = FIRE_PAL[kind]
    frames = []
    for f in range(FIRE_FRAMES_N):
        fr = np.zeros((h + 3, w, 4))
        for c in range(w):
            edge = 1 - abs(c + 0.5 - w / 2) / (w / 2)
            hc = max(1, int(round(h * (0.35 + 0.65 * edge) * (0.65 + 0.45 * H(c, f, 41)))))
            for r in range(hc):
                k = r / hc
                i = 0 if k > 0.85 else 1 if k > 0.62 else 2 if k > 0.35 else (4 if edge > 0.5 else 3)
                fr[h + 2 - r, c, :3] = pal[i]
                fr[h + 2 - r, c, 3] = 255
        if H(f, 7, 43) > 0.4:                                   # a spark above
            sx = int(w / 2 + (H(f, 3, 44) - 0.5) * w * 0.6)
            fr[int(H(f, 5, 45) * 3), sx, :3] = pal[3]
            fr[int(H(f, 5, 45) * 3), sx, 3] = 255
        frames.append(fr)
    return frames


WATER_FRAMES_N = 12


def water_frames(wv):
    """moving water over a baked sheet (fall: streaks running down; else: a ripple along the basin), RGBA frames"""
    w, h = wv["w"], wv["h"]
    frames = []
    for f in range(WATER_FRAMES_N):
        fr = np.zeros((h, w, 4))
        t = f / WATER_FRAMES_N
        for x in range(w):
            if wv["fall"]:
                y = int((t * h * (1 + int(H(x, 1, 51) * 2)) + H(x, 2, 52) * h) % h)
                fr[y:y + 2, x, :3] = SEA[4] if x % 3 == 0 else SEA[3]
                fr[y:y + 2, x, 3] = 255
                if H(x, f, 53) > 0.93:
                    fr[(y + 7) % h, x] = (*SEA[5], 255)
                if x % 2 == 0 and H(x, f, 54) > 0.6:
                    fr[h - 1, x] = (200, 240, 246, 180)
            else:
                y = int((math.sin(x * 0.4 + t * 2 * math.pi) + 1) * (h - 1) / 2)
                if (x + f) % 3 == 0:
                    fr[y, x] = (*SEA[4], 255)
        frames.append(fr)
    return frames


def chandelier_sprite():
    """the rotunda's chandelier, hung over everything: chains up out of view, a gold ring of candles, crystal drops.
    Returns (Spr, ring centre x, y within it)"""
    s = Spr(70, 100)
    cx, cy = 35, 86
    for dx in (-20, -7, 7, 20):
        for y in range(cy - 80, cy - 2, 3):
            s.put(cx + dx * (1 - (cy - y) / 100), y, (138, 106, 38))
            s.put(cx + dx * (1 - (cy - y) / 100), y + 1, (110, 84, 32))
    for i in range(240):
        a = i / 240 * 2 * math.pi
        x, y = cx + math.cos(a) * 30, cy + math.sin(a) * 8
        s.put(x, y, GOLD[2] if math.sin(a) > 0 else GOLD[3])
        s.put(x, y + 1, GOLD[0])
        s.put(cx + math.cos(a) * 16, cy + math.sin(a) * 4.5, GOLD[1])
    s.rect(cx - 1, cy - 12, cx + 1, cy + 3, GOLD[2]); s.rect(cx - 1, cy - 12, cx - 1, cy + 3, GOLD5[4])
    s.ellipse(cx, cy + 5, 3, 3, lambda x, y: GOLD[2])
    for i in range(16):
        a = i / 16 * 2 * math.pi + 0.2
        if math.sin(a) < -0.2:
            continue
        x, y = cx + math.cos(a) * 30, cy + math.sin(a) * 8
        for k in range(1, 4):
            s.put(x, y + k, (200, 230, 255) if k < 3 else (150, 190, 240))
    for i in range(12):
        a = i / 12 * 2 * math.pi
        x, y = int(round(cx + math.cos(a) * 30)), int(round(cy + math.sin(a) * 8))
        s.rect(x, y - 5, x + 1, y - 1, (246, 240, 220)); s.rect(x + 1, y - 4, x + 1, y - 1, (200, 190, 170))
        s.put(x, y - 7, FIRE[4]); s.put(x, y - 6, FIRE[3]); s.put(x + 1, y - 6, FIRE[2])
    return s, cx, cy


def rows(plan):
    """the hall's collision as Maps.lua rows: X solid, . open (Hideout.lua keeps a copy; the test compares them)"""
    npc = {(n["x"], n["y"]) for n in plan["npcs"]}           # (people stand on open tiles: they block by themselves)
    return ["".join("X" if v and (x, y) not in npc else "." for x, v in enumerate(r)) for y, r in enumerate(plan["solid"])]


if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ["rows"]:
        _, pl = paint()
        for r in rows(pl):
            print('    "%s",' % r)

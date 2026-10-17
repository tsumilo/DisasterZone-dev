"""Hand-shaded props for Azeromon's overworld: used by gen_azeromon_art.py (atlas), gen_azeromon_ground.py (ruin
walls, baked into the ground) and the look mockup (dev/art/casc/azeromon_looks).
Light comes from the top left; every material has a 4-5 step ramp; silhouettes get a dark selective outline.
Run: python props.py <out dir>  ->  props.png + props.json (name -> [x, y, w, h])"""
import json, os, sys, math
from PIL import Image

# ramps, dark -> light
WOOD = [(46, 28, 22), (84, 52, 34), (124, 78, 46), (166, 112, 64), (204, 152, 96)]
DWOOD = [(34, 22, 20), (60, 40, 32), (90, 62, 44), (122, 88, 60), (152, 116, 80)]
STONE = [(42, 42, 52), (72, 74, 86), (106, 108, 120), (142, 144, 154), (180, 182, 190)]
RUIN = [(44, 48, 40), (78, 84, 68), (114, 118, 96), (152, 152, 124), (190, 186, 152)]
MOSS = [(36, 70, 36), (60, 108, 46), (96, 146, 60), (138, 182, 80)]
THATCH = [(70, 46, 24), (116, 82, 40), (164, 124, 60), (204, 166, 92), (232, 204, 136)]
CANVAS = [(66, 48, 40), (110, 84, 64), (154, 122, 92), (194, 164, 126), (226, 204, 166)]
IRON = [(26, 26, 32), (52, 54, 64), (86, 90, 102), (130, 136, 148), (186, 192, 202)]
FIRE = [(112, 28, 18), (196, 66, 28), (240, 136, 46), (255, 210, 104), (255, 246, 200)]
PAPER = [(122, 106, 80), (176, 158, 120), (220, 204, 164), (244, 234, 204)]
LEAF = [(22, 56, 34), (34, 90, 44), (58, 132, 54), (98, 172, 70), (150, 204, 94)]
PINE = [(14, 22, 30), (24, 38, 46), (36, 56, 60), (54, 80, 76), (80, 108, 96)]
BARK = [(40, 34, 32), (66, 56, 50), (98, 86, 74), (132, 118, 100)]
RED = [(92, 22, 24), (150, 40, 36), (204, 70, 52), (236, 120, 86)]
TEAL = [(18, 58, 64), (30, 100, 104), (56, 150, 148), (110, 196, 186)]
BONE = [(120, 112, 96), (180, 172, 150), (226, 220, 200), (250, 246, 232)]
GLASS = [(70, 64, 40), (196, 170, 90), (250, 226, 140), (255, 250, 214)]


class Spr:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.p = [[None] * w for _ in range(h)]

    def put(self, x, y, c):
        x, y = int(round(x)), int(round(y))
        if 0 <= x < self.w and 0 <= y < self.h and c is not None:
            self.p[y][x] = tuple(c)

    def get(self, x, y):
        return self.p[y][x] if 0 <= x < self.w and 0 <= y < self.h else None

    def rect(self, x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.put(x, y, c)

    def fill(self, x0, y0, x1, y1, fn):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.put(x, y, fn(x, y))

    def poly(self, pts, fn):
        ys = [p[1] for p in pts]
        for y in range(int(min(ys)), int(max(ys)) + 1):
            xs = []
            n = len(pts)
            for i in range(n):
                (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % n]
                if (y0 <= y + 0.5 < y1) or (y1 <= y + 0.5 < y0):
                    xs.append(x0 + (y + 0.5 - y0) * (x1 - x0) / (y1 - y0))
            xs.sort()
            for a, b in zip(xs[::2], xs[1::2]):
                for x in range(int(math.ceil(a - 0.5)), int(math.floor(b - 0.5)) + 1):
                    self.put(x, y, fn(x, y))

    def ellipse(self, cx, cy, rx, ry, fn):
        for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
            for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
                if ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1:
                    self.put(x, y, fn(x, y))

    def line(self, x0, y0, x1, y1, c):
        n = int(max(abs(x1 - x0), abs(y1 - y0))) + 1
        for i in range(n):
            t = i / max(1, n - 1)
            self.put(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, c)

    def outline(self, k=0.42, skip_bottom=False):
        """selective outline: each empty pixel touching the sprite takes a dark version of its neighbour"""
        add = []
        for y in range(self.h):
            for x in range(self.w):
                if self.p[y][x] is not None:
                    continue
                for dx, dy in ((0, 1), (1, 0), (-1, 0), (0, -1)):
                    c = self.get(x + dx, y + dy)
                    if c is not None and not (skip_bottom and dy == -1 and y == self.h - 1):
                        add.append((x, y, tuple(int(v * k) for v in c[:3])))
                        break
        for x, y, c in add:
            self.p[y][x] = c

    def image(self):
        im = Image.new("RGBA", (self.w, self.h), (0, 0, 0, 0))
        for y in range(self.h):
            for x in range(self.w):
                c = self.p[y][x]
                if c is not None:
                    im.putpixel((x, y), c if len(c) == 4 else c + (255,))
        return im


def H(x, y, s=0):
    h = (x * 374761393 + y * 668265263 + s * 1442695041) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return (h ^ (h >> 16)) / 4294967296


# ---------------------------------------------------------------------------- small props (16 x 16)

def sign():
    s = Spr(16, 16)
    s.rect(7, 9, 8, 15, WOOD[2]); s.rect(8, 9, 8, 15, WOOD[1]); s.put(7, 10, WOOD[3])          # post
    s.rect(2, 3, 13, 9, WOOD[3])                                                                 # board
    s.rect(2, 3, 13, 3, WOOD[4]); s.rect(2, 9, 13, 9, WOOD[1]); s.rect(13, 4, 13, 9, WOOD[2])
    s.rect(2, 6, 13, 6, WOOD[2])                                                                 # plank seam
    for x in range(3, 13):                                                                       # grain
        if H(x, 4) < 0.25: s.put(x, 4, WOOD[2])
        if H(x, 7) < 0.25: s.put(x, 7, WOOD[4])
    for x, y in ((3, 4), (12, 4), (3, 8), (12, 8)): s.put(x, y, IRON[3])                         # nails
    for x in (5, 6, 8, 10): s.put(x, 5, DWOOD[1])                                                # carved letters
    for x in (4, 6, 7, 9, 11): s.put(x, 8, DWOOD[1])
    s.put(6, 15, WOOD[1]); s.put(9, 15, WOOD[1])
    s.outline()
    return s


def wantedboard():
    s = Spr(16, 16)
    for x in (2, 13):                                                                            # posts
        s.rect(x, 4, x, 15, WOOD[2]); s.put(x, 4, WOOD[3])
    s.poly([(0.5, 4), (8, 0.5), (15.5, 4)], lambda x, y: THATCH[3] if y < 2 else THATCH[2])    # little roof
    s.rect(1, 4, 14, 4, DWOOD[1])
    s.rect(3, 5, 12, 12, DWOOD[2]); s.rect(3, 5, 12, 5, DWOOD[3]); s.rect(3, 12, 12, 12, DWOOD[1])
    s.rect(4, 6, 7, 10, PAPER[2]); s.rect(4, 6, 7, 6, PAPER[3]); s.rect(7, 7, 7, 10, PAPER[1])   # notice 1
    s.put(5, 7, DWOOD[1]); s.put(6, 7, DWOOD[1]); s.put(5, 8, RED[2]); s.put(6, 8, RED[2])         # a face
    s.rect(5, 9, 6, 9, DWOOD[2])
    s.rect(9, 6, 11, 9, PAPER[3]); s.rect(11, 7, 11, 9, PAPER[1])                                 # notice 2
    s.put(10, 7, DWOOD[2]); s.put(9, 8, DWOOD[2]); s.put(10, 8, DWOOD[2])
    s.put(10, 10, RED[2]); s.put(10, 11, RED[1])                                                  # wax seal
    s.put(4, 6, RED[3])                                                                           # pin
    s.outline()
    return s


def forge():
    s = Spr(16, 16)
    s.rect(9, 0, 12, 4, STONE[1]); s.rect(9, 0, 10, 4, STONE[2]); s.rect(9, 0, 12, 0, STONE[3])   # chimney
    def body(x, y):
        r = STONE[3] if x < 5 else STONE[2] if x < 11 else STONE[1]
        if y == 4: r = STONE[4] if x < 10 else STONE[3]
        if (y - 4) % 3 == 0 and y > 4: r = STONE[1]                                           # courses
        elif (x + (y // 3) * 3) % 6 == 0: r = STONE[1]                                         # joints
        return r
    s.poly([(1, 15.5), (1, 6), (3, 4), (13, 4), (15, 6), (15, 15.5)], body)
    s.ellipse(8, 11.5, 4.2, 4.6, lambda x, y: (28, 14, 12))                                     # the mouth
    for y in range(9, 16):
        for x in range(4, 13):
            if s.get(x, y) == (28, 14, 12):
                d = abs(x - 8) + max(0, 13 - y) * 0.8
                s.put(x, y, FIRE[4] if d < 1.2 else FIRE[3] if d < 2.6 else FIRE[2] if d < 4 else FIRE[1])
    for x in range(4, 13): s.put(x, 15, (54, 30, 24) if H(x, 15) < 0.5 else (90, 44, 26))           # coals
    s.rect(4, 7, 12, 7, STONE[4]); s.put(3, 8, STONE[3]); s.put(13, 8, STONE[1])                  # arch lip
    s.outline()
    return s


def anvil():
    s = Spr(16, 16)
    s.rect(5, 11, 11, 15, WOOD[2]); s.rect(5, 11, 6, 15, WOOD[3]); s.rect(10, 11, 11, 15, WOOD[1])   # stump
    s.rect(5, 11, 11, 11, THATCH[3]); s.put(8, 11, THATCH[2]); s.put(7, 11, THATCH[4])
    s.rect(6, 8, 10, 10, IRON[1]); s.rect(6, 8, 7, 10, IRON[2])                                      # waist
    s.poly([(1, 5), (4, 4), (14, 4), (14, 7), (11, 8), (5, 8), (3, 6)], lambda x, y: IRON[3] if y <= 5 else IRON[2])
    s.rect(4, 4, 14, 4, IRON[4]); s.put(2, 5, IRON[3]); s.put(1, 5, IRON[2])                         # face + horn
    s.rect(12, 5, 14, 7, IRON[1])
    s.put(9, 3, FIRE[3]); s.put(10, 2, FIRE[4])                                                       # a spark
    s.outline()
    return s


def alchemy():
    s = Spr(16, 16)
    s.rect(1, 9, 14, 10, WOOD[3]); s.rect(1, 9, 14, 9, WOOD[4]); s.rect(1, 10, 14, 10, WOOD[2])     # top
    s.rect(2, 11, 3, 15, WOOD[2]); s.rect(12, 11, 13, 15, WOOD[1]); s.rect(4, 11, 11, 11, WOOD[1])  # legs
    s.rect(1, 9, 5, 10, (150, 50, 70)); s.put(1, 9, (190, 80, 96))                                   # cloth
    def bottle(x, top, col):
        s.rect(x, top + 2, x + 2, 8, col[1]); s.put(x, top + 3, col[3]); s.put(x, top + 4, col[2])
        s.rect(x + 1, top, x + 1, top + 1, GLASS[1]); s.put(x + 1, top - 1, WOOD[1])
    bottle(2, 3, TEAL); bottle(10, 4, RED)
    s.ellipse(7.5, 6.6, 2.4, 2.4, lambda x, y: (120, 200, 90) if y > 5 else (90, 160, 70))          # round flask
    s.put(6, 5, (200, 250, 170)); s.rect(7, 2, 7, 4, GLASS[1])
    s.put(8, 1, (220, 250, 200)); s.put(6, 0, (200, 240, 180))                                       # bubbles
    s.outline()
    return s


def lamppost():
    s = Spr(16, 16)
    s.rect(7, 7, 8, 14, IRON[2]); s.rect(8, 7, 8, 14, IRON[1])                                      # pole
    s.rect(5, 14, 10, 15, IRON[1]); s.rect(5, 14, 10, 14, IRON[2])                                  # foot
    s.rect(5, 1, 10, 1, IRON[3]); s.put(7, 0, IRON[2]); s.put(8, 0, IRON[2])                        # cap
    s.rect(5, 2, 10, 5, GLASS[2]); s.rect(6, 3, 9, 4, GLASS[3]); s.put(7, 3, GLASS[3])              # glass
    for x in (5, 10): s.rect(x, 2, x, 5, IRON[2])
    s.rect(5, 6, 10, 6, IRON[2])
    s.put(4, 6, IRON[1]); s.put(11, 6, IRON[1])
    s.outline()
    return s


# ---------------------------------------------------------------------------- trees: the themes' 'T' tile (16 x 16).
# Forests pack them edge to edge and the ground baker tucks a darker copy between neighbours and casts each one's
# silhouette, so crowns fill the tile's width, trunks stay short and no tree carries its own shadow.

LIGHT = (-0.48, -0.66, 0.58)            # top left, a little toward us


def _lit(dx, dy):
    """brightness of a dome's surface at (dx, dy) in -1..1: about -0.8 (lower right) .. 1 (upper left)"""
    nz = math.sqrt(max(0.0, 1 - min(1.0, dx * dx + dy * dy)))
    return dx * LIGHT[0] + dy * LIGHT[1] + nz * LIGHT[2]


def _pick(ramp, v):
    return ramp[max(0, min(len(ramp) - 1, int(v * len(ramp))))]


def _clump(s, cx, cy, rx, ry, ramp, seed, bias=0.0):
    """one ball of leaves, lit on its own from the top left: a lobed edge, leaf clusters, specks of light"""
    for y in range(int(cy - ry) - 2, int(cy + ry) + 2):
        for x in range(int(cx - rx) - 2, int(cx + rx) + 2):
            dx, dy = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
            ang = math.atan2(dy, dx)
            edge = 1 + 0.13 * math.sin(ang * 5 + seed * 2.3) + 0.16 * (H(x, y, seed) - 0.5)
            if dx * dx + dy * dy > edge * edge:
                continue
            v = (_lit(dx / edge, dy / edge) + 0.8) / 1.8 + bias
            v += (H(x // 2 + (y // 2) % 2, y // 2, seed + 7) - 0.5) * 0.2
            s.put(x, y, _pick(ramp, v))


def _speck(s, ramp, pts):
    """leaf tips catching the light: a lit pixel with a darker one under it"""
    for x, y in pts:
        if s.get(x, y) is not None and s.get(x, y + 1) is not None:
            s.put(x, y, ramp[-1]); s.put(x, y + 1, ramp[-3])


def _trunk(s, x0, top, ramp, roots=True):
    """a two pixel trunk lit on the left, flaring into roots at the bottom row"""
    for y in range(top, 16):
        s.put(x0, y, ramp[2]); s.put(x0 + 1, y, ramp[1])
    s.put(x0, top, ramp[3])
    if roots:
        s.put(x0 - 1, 15, ramp[2]); s.put(x0 + 2, 15, ramp[0]); s.put(x0 - 1, 14, ramp[1])


WLEAF = [(34, 34, 16), (56, 54, 22), (84, 78, 30), (114, 104, 40), (146, 134, 56), (180, 168, 90)]      # Westfall
AUTUMN = [(48, 12, 16), (82, 18, 20), (122, 28, 26), (160, 44, 30), (192, 72, 38), (220, 112, 58)]      # Redridge
AMBER = [(66, 22, 12), (104, 38, 16), (142, 62, 22), (176, 92, 30), (204, 128, 48), (228, 170, 92)]
WBARK = [(38, 28, 22), (64, 46, 34), (94, 70, 50), (126, 98, 72)]


def oak(ramp, second=None, bark=WBARK, bias=0.0):
    """a round broadleaf tree: back clumps darker, front ones brighter; `second` mixes in a few clumps of another
    ramp (Redridge's amber among the red)"""
    s = Spr(16, 16)
    _trunk(s, 7, 10, bark)
    clumps = [(8, 6.2, 6.8, 5.4, -0.16, 0), (4.0, 7.8, 3.7, 3.3, -0.08, 0), (12.0, 7.8, 3.7, 3.3, -0.14, 0),
              (8, 3.4, 4.4, 3.4, 0.04, 0), (4.6, 4.6, 3.1, 2.9, 0.04, 1), (11.4, 4.6, 3.1, 2.9, -0.04, 0),
              (6.0, 9.6, 3.2, 2.5, -0.02, 1), (10.4, 9.8, 3.0, 2.4, -0.1, 0)]
    for i, (cx, cy, rx, ry, b, alt) in enumerate(clumps):
        _clump(s, cx, cy, rx, ry, second if (second and alt) else ramp, 11 + i * 3, b + bias)
    _speck(s, ramp, ((3, 5), (6, 2), (9, 1), (5, 8), (2, 9), (8, 5), (12, 3), (7, 10)))
    for x, y in ((12, 9), (13, 6), (10, 11), (14, 8)):                                         # the shaded side
        if s.get(x, y) is not None: s.put(x, y, ramp[0])
    s.outline(0.42)
    return s


def _shape(rows, ramp, base=2, marks=None):
    """a hand-drawn silhouette ('#' filled) lit from the top left on its own: open space to the left or above a
    pixel brightens it, to the right or below darkens it; other characters are colours from `marks` (None = empty)"""
    s = Spr(len(rows[0]), len(rows))
    marks = marks or {}
    full = lambda x, y: (0 <= y < len(rows) and 0 <= x < len(rows[0]) and rows[y][x] != "."
                         and marks.get(rows[y][x], 1) is not None)
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch == ".":
                continue
            if ch in marks:
                s.put(x, y, marks[ch])
                continue
            v = base + (1.2 if not full(x - 1, y) else 0) + (0.8 if not full(x, y - 1) else 0) \
                - (1.2 if not full(x + 1, y) else 0) - (0.5 if not full(x, y + 1) else 0)
            s.put(x, y, ramp[max(0, min(len(ramp) - 1, int(round(v))))])
    return s


DFIR = [(10, 18, 26), (16, 30, 38), (24, 44, 52), (34, 62, 66), (50, 84, 80), (74, 112, 98), (112, 150, 128)]
DBARK = [(30, 28, 30), (54, 50, 50), (84, 78, 72), (118, 110, 100), (154, 146, 132)]


def fir():
    """Duskwood's dark fir: four tiers of boughs, each one a skirt that widens down to a hem of needle tips hanging
    lower at the ends; the tier above shades the top of the one below; moonlight catches the lower left edges"""
    s = Spr(16, 16)
    _trunk(s, 7, 12, DBARK)
    tiers = [(7.0, 14.0, 8.0), (4.5, 11.0, 6.6), (2.0, 8.0, 5.0), (-0.6, 4.6, 3.2)]          # top, hem, half width

    def hem(t, x):
        dx = (x + 0.5 - 8) / t[2]
        return t[1] + 1.1 * dx * dx

    def inside(t, x, y):
        top, bot, hw = t
        f = (y + 0.5 - top) / (bot - top)
        if f < 0 or abs(x + 0.5 - 8) > hw * min(1.0, f):
            return False
        return y + 0.5 <= hem(t, x) - (1 if x % 2 else 0)

    for ti, t in enumerate(tiers):                                                          # lowest first
        above = tiers[ti + 1] if ti + 1 < len(tiers) else None
        for y in range(16):
            for x in range(16):
                if not inside(t, x, y):
                    continue
                v = 0.7 - 0.42 * (x + 0.5 - 8) / t[2]
                shaded = above and y + 0.5 <= hem(above, x) + 1.6
                if shaded:                                                                  # under the tier above
                    v -= 0.34
                if not inside(t, x, y + 1):                                                 # the hem's underside
                    v -= 0.16
                if (y + int(abs(x - 7.5) * 0.7)) % 3 == 0:                                  # needle chevrons
                    v -= 0.08
                s.put(x, y, _pick(DFIR, v))
        for y in range(16):                                                                 # moonlit edge
            if above and y + 0.5 <= hem(above, 4) + 1.6:
                continue
            for x in range(8):
                if inside(t, x, y):
                    s.put(x, y, DFIR[6] if inside(t, x, y + 1) else DFIR[5])
                    break
    s.put(7, 0, DFIR[6]); s.put(8, 0, DFIR[4])
    s.outline(0.5)
    return s


DEADTREE = ["..#..........#..",
            "..#......#...#..",
            "...#.....#..#...",
            ".#.#.....#..#...",
            "..###.....##....",
            "...m##....##.m..",
            "...n.##..##..n..",
            "......####......",
            "......###.......",
            "......###.......",
            "......r##.......",
            ".....#h##.......",
            ".....#h##.......",
            ".....#####......",
            "....#######.....",
            "..###.###.###..."]
CHARRED = ["................",
           "......#.........",
           "..#...#....#....",
           "..#..##...#.....",
           "...#.#...##.....",
           "...###..##......",
           "....##.##.......",
           ".....####.......",
           "......###.......",
           "......###.......",
           "......###.......",
           ".....####.......",
           ".....####.......",
           ".....#####......",
           "....######......",
           "...##.###.##...."]
CHAR = [(14, 10, 10), (30, 22, 20), (46, 36, 32), (70, 60, 54), (104, 94, 86)]


def deadtree(ramp=DBARK, embers=False, moss=True, shape=DEADTREE):
    """a gnarled dead tree: two crooked limbs forking into twigs over a broken middle stub, a hollow in the trunk,
    roots gripping the ground; Duskwood's has grey moss hanging, the Burning Steppes' is charred with embers"""
    marks = {"h": ramp[0], "r": ramp[4], "m": (90, 102, 86) if moss else None, "n": (62, 72, 60) if moss else None}
    s = _shape(shape, ramp, marks=marks)
    for x, y in ((7, 9), (7, 13), (8, 14)):                                                 # bark grooves
        s.put(x, y, ramp[1])
    if embers:                                                                              # a glowing crack
        for x, y, c in ((7, 10, 0), (7, 11, 1), (7, 12, 2), (6, 13, 3), (7, 13, 1)):
            s.put(x, y, FIRE[c])
        for x, y in ((2, 2), (6, 1), (5, 6), (6, 8)):                                       # ash on the lit edges
            if s.get(x, y): s.put(x, y, (118, 110, 102))
    s.outline(0.5)
    return s


def charredtree():
    return deadtree(CHAR, embers=True, moss=False, shape=CHARRED)


PALM = [(14, 46, 30), (24, 78, 40), (40, 114, 50), (70, 152, 60), (118, 190, 80), (170, 220, 120)]
PBARK = [(54, 36, 24), (92, 64, 40), (134, 98, 60), (174, 138, 88)]


def _bez(p0, p1, p2, n):
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]) for t in (i / (n - 1) for i in range(n))]


def palm():
    """a palm: a ringed trunk curving up into a crown of arching fronds (a lit rib, leaflets hanging under it, the
    fronds behind darker), coconuts under the crown"""
    s = Spr(16, 16)
    for y in range(6, 16):                                                                  # the trunk
        t = (15 - y) / 9
        x = int(round(5.6 + 2.6 * t * t))
        ring = (y % 2 == 0)
        s.put(x, y, PBARK[2] if ring else PBARK[3]); s.put(x + 1, y, PBARK[0] if ring else PBARK[1])
        if y > 13: s.put(x - 1, y, PBARK[1])
    s.put(5, 15, PBARK[0]); s.put(7, 15, PBARK[0])
    c = (8.5, 5.0)

    def frond(ctrl, tip, base, wide=False):
        pts = _bez(c, ctrl, tip, 16)
        for i, (x, y) in enumerate(pts):
            t = i / (len(pts) - 1)
            v = base + 0.08 - 0.2 * t
            if t > 0.12:
                s.put(x, y + 1, _pick(PALM, v - 0.2))                                       # leaflets
                if wide and 0.25 < t < 0.75: s.put(x, y + 2, _pick(PALM, v - 0.38))
        for x, y in pts:
            s.put(x, y, _pick(PALM, base + 0.12))                                           # the rib

    frond((6.5, 0.5), (3.5, 1.0), 0.28); frond((10.5, 0.5), (13.5, 1.2), 0.22)            # behind
    frond((3.0, 2.0), (0.2, 8.0), 0.66, True); frond((14.0, 2.0), (15.8, 8.5), 0.5, True)  # the sides
    frond((5.5, 4.0), (3.0, 10.5), 0.6); frond((11.5, 4.0), (13.0, 11.0), 0.46)           # in front
    frond((7.5, 0.0), (5.5, 0.2), 0.7); frond((9.5, 0.0), (11.5, 0.4), 0.56)              # on top
    for x, y, col in ((8, 6, (134, 92, 44)), (9, 6, (104, 70, 34)), (8, 7, (90, 60, 30))):  # coconuts
        s.put(x, y, col)
    s.put(8, 5, PALM[4])
    s.outline(0.42)
    return s


# ---------------------------------------------------------------------------- stamps

def tent():
    """a conical camp tent: poles crossing above the smoke hole, canvas panels sewn from the top (lit on the left,
    one patched with hide), a laced band, the door flap tied back on a dark inside with a bedroll, guy ropes"""
    s = Spr(32, 32)
    ax, ay = 15.5, 4.5                                                                      # the apex

    def hem(x):
        lx = (x + 0.5 - 15.5) / 13.5
        return 27.0 + 2.0 * (1 - lx * lx)

    def half(y):
        return 13.8 * min(1.0, max(0.0, (y + 0.5 - ay) / (27.0 - ay))) ** 0.85

    for x, y0, x1, y1 in ((12, 0, 15, 5), (19, 0, 16, 5), (16, 0, 15.5, 4)):                 # poles
        s.line(x, y0, x1, y1, WOOD[2])
        s.put(x, y0, WOOD[3])
    panel = lambda x, y: int(math.floor((x + 0.5 - ax) / max(half(y), 1) * 2.5 + 10))
    for y in range(int(ay), 32):
        for x in range(32):
            if y + 0.5 > hem(x) or abs(x + 0.5 - ax) > half(y) + 0.2:
                continue
            t = (y + 0.5 - ay) / (hem(x) - ay)
            lx = (x + 0.5 - ax) / max(half(y), 1)
            v = 0.6 - 0.5 * lx - 0.06 * t
            if half(y) > 3 and panel(x, y) != panel(x + 1, y):                              # panel seams
                v -= 0.18
            if 0.6 < t < 0.68:                                                              # the laced band
                v -= 0.24 if (x % 3) else 0.04
            if y + 1.3 > hem(x):                                                            # the hem
                v -= 0.18
            c = _pick(CANVAS, v)
            if -0.62 < lx < -0.3 and 0.28 < t < 0.46:                                       # a patch of hide
                c = _pick(THATCH, v - 0.1)
            s.put(x, y, c)
    for y in range(12, 30):                                                                 # the door: a dark inside
        d0, d1 = 14.5 - (y - 12) * 0.26, 15.5 + (y - 12) * 0.3
        for x in range(32):
            if d0 <= x + 0.5 <= d1 + 1 and y + 1 < hem(x):
                s.put(x, y, (22, 15, 13) if y < 22 else (34, 24, 20))
    for x, y, c in ((15, 26, (120, 74, 48)), (16, 26, (120, 74, 48)), (17, 26, (96, 58, 40)),   # the bedroll
                    (15, 27, (84, 52, 36)), (16, 27, (96, 58, 40))):
        s.put(x, y, c)
    for y in range(13, 29):                                                                 # the flap, tied back
        x1 = 14.5 - (y - 12) * 0.26
        w_ = 1 + int((y - 13) * 0.22)
        for k in range(w_):
            s.put(x1 - 1 - k, y, CANVAS[4] if k == 0 else CANVAS[3])
    s.put(11, 21, (150, 54, 42)); s.put(10, 21, (110, 40, 32))                              # its tie
    s.put(15, 4, WOOD[1]); s.put(16, 4, WOOD[1])                                            # the smoke hole
    s.outline(0.42)
    for (x0, y0), (x1, y1) in (((4, 17), (0, 30)), ((27, 16), (31, 29))):                   # guy ropes and stakes
        n = int(max(abs(x1 - x0), abs(y1 - y0))) + 1
        for i in range(n):
            x, y = x0 + (x1 - x0) * i / (n - 1), y0 + (y1 - y0) * i / (n - 1)
            if s.get(int(round(x)), int(round(y))) is None:
                s.put(x, y, (150, 128, 92) if i % 2 else (126, 106, 76))
    for x in (0, 31):
        s.put(x, 30, WOOD[3]); s.put(x, 31, WOOD[1])
    return s


def hut():
    s = Spr(48, 48)
    # wall: round, so its bottom edge bows toward us; timber posts with mud between, darker to the right
    def wall(x, y):
        lx = (x - 24) / 18.5
        c = WOOD[3] if lx < -0.55 else WOOD[2] if lx < 0.3 else WOOD[1]
        if x % 4 == 0: c = DWOOD[1] if lx > -0.55 else WOOD[2]
        if y < 25: c = DWOOD[1]                                   # under the eaves
        return c
    for x in range(6, 43):
        lx = (x - 24) / 18.5
        bottom = 43 + int(round(3.5 * (1 - lx * lx)))
        for y in range(22, bottom + 1):
            s.put(x, y, wall(x, y))
        s.put(x, bottom + 1, DWOOD[0])
    # door (the walkable tile is dx 1, dy 2: x 16..31, y 32..47)
    s.ellipse(24, 40, 6.5, 9.5, lambda x, y: (26, 18, 16))
    for y in range(31, 48):
        for x in range(17, 32):
            if s.get(x, y) == (26, 18, 16) and y > 46: s.put(x, y, (40, 30, 24))
    s.fill(17, 30, 31, 31, lambda x, y: WOOD[4] if x < 24 else WOOD[3])                             # lintel
    s.put(16, 31, WOOD[2]); s.put(32, 31, WOOD[1])
    for x0, d in ((15, -1), (33, 1)):                                                                # tusks by the door
        for k in range(6):
            s.put(x0 + d * (k // 2), 46 - k * 2, BONE[2] if k < 4 else BONE[3])
            s.put(x0 + d * (k // 2), 45 - k * 2, BONE[1] if k < 4 else BONE[2])
    # skull over the door
    s.rect(22, 25, 26, 28, BONE[2]); s.rect(22, 25, 26, 25, BONE[3]); s.put(23, 26, (30, 20, 20)); s.put(25, 26, (30, 20, 20))
    s.rect(23, 28, 25, 29, BONE[1]); s.put(24, 29, BONE[2])
    # roof: a cone of layered thatch with a ragged fringe
    def roof(x, y):
        lx = (x - 24) / 22
        band = (y - 2) // 4
        c = THATCH[4] if lx < -0.5 else THATCH[3] if lx < 0 else THATCH[2] if lx < 0.55 else THATCH[1]
        if (y - 2) % 4 == 3: c = THATCH[max(0, THATCH.index(c) - 1)]
        if H(x, band) < 0.12: c = THATCH[max(0, THATCH.index(c) - 1)]
        return c
    s.poly([(24, 1), (47, 22), (1, 22)], roof)
    for x in range(1, 47):                                                                            # fringe
        n = 1 + int(H(x, 99) * 3)
        for k in range(n): s.put(x, 22 + k, THATCH[1] if x > 26 else THATCH[2])
    s.rect(23, 0, 25, 2, WOOD[1]); s.put(23, 0, WOOD[2])                                             # top knot
    s.put(22, 1, RED[2]); s.put(26, 1, TEAL[2])                                                        # feathers
    s.outline(0.42)
    return s


def totem():
    s = Spr(16, 32)
    def pole(x, y):
        return WOOD[3] if x < 7 else WOOD[2] if x < 10 else WOOD[1]
    s.fill(4, 6, 11, 31, pole)
    for y in (13, 22, 28): s.rect(4, y, 11, y, DWOOD[1])                                             # carved rings
    s.rect(4, 14, 11, 15, RED[2]); s.rect(4, 26, 11, 27, TEAL[2]); s.rect(9, 14, 11, 15, RED[1]); s.rect(9, 26, 11, 27, TEAL[1])
    # the face
    s.rect(5, 8, 6, 9, BONE[3]); s.rect(9, 8, 10, 9, BONE[3]); s.put(6, 9, (20, 14, 14)); s.put(9, 9, (20, 14, 14))
    s.rect(7, 10, 8, 11, WOOD[1]); s.rect(5, 12, 10, 12, (30, 18, 16))
    s.put(4, 11, BONE[3]); s.put(3, 10, BONE[3]); s.put(11, 11, BONE[2]); s.put(12, 10, BONE[2])      # tusks
    s.rect(5, 17, 10, 20, WOOD[2]); s.put(6, 18, (20, 14, 14)); s.put(9, 18, (20, 14, 14)); s.rect(6, 20, 9, 20, DWOOD[1])
    # headdress
    s.rect(3, 4, 12, 6, WOOD[2]); s.rect(3, 4, 12, 4, WOOD[3])
    for i, (x, c) in enumerate(((3, RED), (6, TEAL), (9, RED), (12, TEAL))):
        s.rect(x, 0 + (i % 2), x, 3, c[2]); s.put(x, 0 + (i % 2), c[3])
    s.outline(0.42)
    return s


def ruinwall(mask, RUIN=RUIN, moss=True, glyph=True, timber=False):
    """mask bits: 1 = wall to the north, 2 = east, 4 = south, 8 = west. Low troll wall in 3/4 view."""
    s = Spr(16, 16)
    n, e, so, w = mask & 1, mask & 2, mask & 4, mask & 8
    face = 0 if so else 6                     # front face height when nothing continues south
    top_end = 15 - face
    x0 = 0 if w else 1
    x1 = 15 if e else 14
    y0 = 0 if n else 2
    def top(x, y):
        bx, by = (x + (3 if (y // 5) % 2 else 0)) // 6, y // 5
        c = RUIN[3]
        if H(bx, by, 3) < 0.35: c = RUIN[2]
        if (x + (3 if (y // 5) % 2 else 0)) % 6 == 0 or y % 5 == 4: c = RUIN[1]
        if (not n and y == y0) or (not w and x == x0): c = RUIN[4]
        if H(x, y, 9) < 0.06: c = RUIN[4]
        return c
    s.fill(x0, y0, x1, top_end, top)
    if face:
        def front(x, y):
            yy = y - top_end - 1
            c = RUIN[2] if yy < 2 else RUIN[1]
            if (x + (4 if yy >= 3 else 0)) % 8 == 0 or yy == 2: c = RUIN[0]
            if x == x0 and not w: c = RUIN[2]
            return c
        s.fill(x0, top_end + 1, x1, 15, front)
        if glyph and H(mask, 5, 7) < 0.5:                                                                     # a carved glyph
            gx = 6
            for dx, dy in ((0, 0), (1, 1), (2, 0), (1, 2)): s.put(gx + dx, top_end + 2 + dy, TEAL[1])
    # moss on top and dripping over the face
    for x in (range(x0, x1 + 1) if moss else ()):
        hm = H(x, mask, 11)
        if hm < 0.45:
            ys = y0 + int(H(x, 3, mask) * 3)
            s.put(x, ys, MOSS[2 if hm < 0.25 else 1]); s.put(x, ys + 1, MOSS[1])
        if face and hm < 0.2:
            for k in range(1 + int(H(x, 4) * 3)): s.put(x, top_end + 1 + k, MOSS[1] if k else MOSS[2])
    # broken crumbs
    if not n and H(mask, 1, 2) < 0.6:
        s.put(x0 + 4, y0, None) if False else None
    if timber and face and mask & 10 and (mask & 2):
        s.rect(x1 - 2, top_end + 1, x1, 15, WOOD[2]); s.rect(x1 - 2, top_end + 1, x1 - 2, 15, WOOD[3])
    s.outline(0.42)
    # outline must not cut where the wall continues
    for y in range(16):
        for x in range(16):
            c = s.p[y][x]
            if c is None: continue
    return s


# ---------------------------------------------------------------------------- herb and ore nodes (16 x 16, shown
# while they can be picked; each carries its own see-through ground shadow since it is not baked)

def _node_shadow(s, cx, rx):
    for y, k in ((13, 0.7), (14, 1), (15, 0.6)):
        for x in range(int(cx - rx * k), int(cx + rx * k) + 1):
            if s.get(x, y) is None:
                core = abs(x - cx) < rx * k - 1.5
                s.p[y][x] = (10, 24, 14, 90 if core else 48)


def _leaf(s, x0, y0, dx, dy, n, ramp):
    for k in range(n):
        x, y = x0 + dx * k, y0 + dy * k
        s.put(x, y, ramp[3] if k < n - 1 else ramp[4])
        s.put(x + (1 if dx <= 0 else -1) * (k % 2), y + 1, ramp[2])


def herb_peacebloom():
    s = Spr(16, 16)
    for x0, y0, dx, dy, n in ((7, 12, -1, -1, 4), (8, 12, 1, -1, 4), (7, 12, -1, 0, 4), (9, 12, 1, 0, 4)):
        _leaf(s, x0, y0, dx, dy, n, LEAF)
    for cx, cy in ((4, 6), (8, 3), (12, 6), (8, 8)):
        s.rect(cx, cy - 1, cx, cy + 1, (244, 244, 236)); s.rect(cx - 1, cy, cx + 1, cy, (244, 244, 236))
        s.put(cx - 1, cy - 1, (214, 214, 206)); s.put(cx + 1, cy + 1, (196, 196, 190)); s.put(cx, cy, (250, 210, 80))
    s.line(8, 9, 8, 12, LEAF[1]); s.line(4, 7, 6, 11, LEAF[1]); s.line(12, 7, 10, 11, LEAF[1])
    s.outline(0.42)
    _node_shadow(s, 8, 6)
    return s


def herb_silverleaf():
    s = Spr(16, 16)
    SIL = [(40, 70, 64), (70, 110, 100), (120, 160, 150), (184, 210, 204), (232, 244, 240)]
    for x0, dx, n in ((8, 0, 9), (7, -1, 7), (9, 1, 7), (6, -2, 5), (10, 2, 5)):
        for k in range(n):
            x, y = x0 + dx * k * 0.45, 12 - k
            s.put(x, y, SIL[3] if k > n - 3 else SIL[2])
            s.put(x + (1 if dx >= 0 else -1), y, SIL[1])
    for x, y in ((8, 3), (5, 6), (11, 6), (8, 7)):
        s.put(x, y, SIL[4])
    s.outline(0.42)
    _node_shadow(s, 8, 6)
    return s


def herb_earthroot():
    s = Spr(16, 16)
    DIRT = [(60, 40, 28), (96, 66, 44), (132, 94, 62), (164, 122, 82)]
    s.ellipse(8, 12, 6.5, 2.6, lambda x, y: DIRT[2] if y < 12 else DIRT[1])                          # the mound
    for x in (4, 7, 11):
        s.put(x, 11, DIRT[3])
    ROOT = [(70, 42, 30), (120, 74, 46), (164, 108, 68), (200, 146, 96)]
    for i, (x, y) in enumerate(((5, 11), (6, 10), (6, 9), (7, 8), (8, 7), (8, 6), (9, 5), (10, 5), (11, 4))):
        s.put(x, y, ROOT[2]); s.put(x + 1, y, ROOT[1]); s.put(x, y - 1, ROOT[3] if i % 2 else ROOT[2])
    s.put(12, 3, ROOT[2]); s.put(4, 12, ROOT[1]); s.put(10, 11, ROOT[1]); s.put(11, 11, ROOT[2])         # tip, rootlets
    for x, y, c in ((9, 3, LEAF[3]), (10, 2, LEAF[4]), (8, 3, LEAF[2]), (12, 2, LEAF[3]), (13, 1, LEAF[4])):
        s.put(x, y, c)
    s.outline(0.42)
    _node_shadow(s, 8, 7)
    return s


def herb_mageroyal():
    s = Spr(16, 16)
    PUR = [(70, 30, 80), (120, 52, 134), (170, 86, 180), (214, 140, 222), (246, 200, 250)]
    for x0, y0, dx, dy, n in ((7, 12, -1, -1, 3), (9, 12, 1, -1, 3), (6, 13, -1, 0, 3), (10, 13, 1, 0, 3)):
        _leaf(s, x0, y0, dx, dy, n, LEAF)
    for x, top in ((5, 4), (8, 2), (11, 4)):                                                           # three stalks
        s.line(x, top + 4, x, 12, LEAF[1])
        for k in range(4):
            s.put(x, top + k, PUR[3] if k % 2 == 0 else PUR[2])
            s.put(x - 1, top + k + 1, PUR[2] if k % 2 else PUR[1])
            s.put(x + 1, top + k + 1, PUR[1])
        s.put(x, top - 1, PUR[4])
    s.outline(0.42)
    _node_shadow(s, 8, 6)
    return s


def _blade(s, p0, ctrl, tip, ramp, wide=2, fade=False):
    """a curved leaf or stem from p0 to tip: a lit upper edge over a darker underside while it is wide, a light tip;
    `fade` lets the last pixels go see-through (Fadeleaf)"""
    pts = _bez(p0, ctrl, tip, 14)
    for i, (x, y) in enumerate(pts):
        t = i / (len(pts) - 1)
        if wide > 1 and t < 0.6:
            s.put(x, y + 1, ramp[1])
        c = ramp[2] if t < 0.45 else ramp[3] if t < 0.85 else ramp[4]
        if fade and t > 0.7:
            c = c + (int(255 * (1.15 - t)),)
        s.put(x, y, c)


def _rosette(s, x, y, ramp):
    """a five pixel flower: lit upper left petal, dark lower right, a pale heart"""
    s.put(x, y - 1, ramp[3]); s.put(x - 1, y, ramp[3]); s.put(x + 1, y, ramp[1]); s.put(x, y + 1, ramp[1])
    s.put(x, y, ramp[-1])


def herb_briarthorn():
    """Briarthorn: three arching thorny canes from one root, small serrated leaves, pink flowers at the tips"""
    s = Spr(16, 16)
    VINE = [(44, 24, 22), (80, 42, 34), (118, 66, 48), (156, 98, 68), (190, 136, 100)]
    PINK = [(110, 26, 54), (176, 56, 92), (226, 106, 136), (250, 176, 196), (255, 236, 200)]
    for x0, y0, dx, dy, n in ((7, 12, -1, -1, 3), (9, 12, 1, -1, 3), (6, 13, -1, 0, 3), (10, 13, 1, 0, 3)):
        _leaf(s, x0, y0, dx, dy, n, LEAF)
    canes = (((7, 13), (2, 10), (3, 4)), ((8, 13), (7, 6), (10, 2)), ((9, 13), (14, 10), (13, 5)))
    for p0, c, tip in canes:
        pts = _bez(p0, c, tip, 14)
        for i, (x, y) in enumerate(pts):
            s.put(x, y, VINE[3] if i < 9 else VINE[2])
            if i % 4 == 2:                                                                  # thorns
                s.put(x - 1, y - 1, VINE[4]); s.put(x + 1, y, VINE[0])
    for x, y in ((4, 9), (12, 9), (8, 7)):                                                  # leaves on the canes
        s.put(x, y, LEAF[3]); s.put(x + 1, y, LEAF[2]); s.put(x, y + 1, LEAF[1])
    for x, y in ((3, 4), (10, 2), (13, 5)):
        _rosette(s, x, y, PINK)
    s.outline(0.42)
    _node_shadow(s, 8, 6)
    return s


FADE = [(36, 64, 58), (66, 104, 92), (108, 150, 132), (160, 196, 178), (212, 234, 222)]


def herb_fadeleaf():
    """Fadeleaf: a rosette of long pale leaves whose tips fade away, small white buds in the middle"""
    s = Spr(16, 16)
    base = (8, 13)
    for ctrl, tip in (((5, 12), (1, 9)), ((5, 9), (3, 4)), ((7, 6), (7, 1)), ((10, 7), (12, 2)), ((12, 10), (15, 7)),
                      ((10, 12), (13, 12))):
        _blade(s, base, ctrl, tip, FADE, fade=True)
    s.put(1, 10, FADE[1] + (120,)); s.put(14, 13, FADE[1] + (120,))
    for x, y in ((7, 9), (9, 8), (8, 10)):                                                  # buds
        s.put(x, y, (238, 244, 236)); s.put(x + 1, y + 1, FADE[2])
    s.outline(0.42)
    _node_shadow(s, 8, 6)
    return s


KB = [(66, 10, 24), (118, 18, 38), (172, 32, 54), (216, 70, 82), (246, 150, 146)]


def herb_kingsblood():
    """Kingsblood: broad dark leaves at the foot, a tall stalk hung with crimson bells, a bud on top"""
    s = Spr(16, 16)
    for ctrl, tip in (((5, 13), (2, 11)), ((5, 11), (4, 8)), ((11, 11), (12, 8)), ((11, 13), (14, 11))):
        _blade(s, (8, 13), ctrl, tip, LEAF)
    for y in range(3, 14):                                                                  # the stalk
        s.put(8, y, LEAF[2] if y > 6 else LEAF[3])
    for bx, by, side in ((6, 4, -1), (9, 6, 1), (6, 8, -1), (9, 10, 1)):                    # the bells
        s.rect(bx, by, bx + 1, by + 1, KB[2])
        s.put(bx, by, KB[3]); s.put(bx + 1, by + 1, KB[1])
        s.put(bx + (2 if side > 0 else -1), by + 1, KB[1])
        s.put(bx + (0 if side > 0 else 1), by + 2, KB[0])
    s.put(8, 2, KB[3]); s.put(8, 1, KB[4]); s.put(9, 2, KB[1])                             # the bud
    s.outline(0.42)
    _node_shadow(s, 8, 6)
    return s


ASHLEAF = [(30, 40, 30), (50, 64, 44), (78, 94, 62), (110, 126, 84), (144, 158, 110)]


def herb_firebloom():
    """Firebloom: ash-green leaves under three flame-shaped flowers, red at the cup, yellow-white at the tip"""
    s = Spr(16, 16)
    for ctrl, tip in (((5, 13), (1, 12)), ((6, 11), (3, 9)), ((10, 11), (13, 9)), ((11, 13), (15, 12))):
        _blade(s, (8, 13), ctrl, tip, ASHLEAF)
    for (fx, fy), stem in (((4, 8), (5, 10)), ((8, 6), (8, 9)), ((12, 8), (11, 10))):
        _blade(s, (8, 13), stem, (fx, fy + 2), ASHLEAF, wide=1)
        for dx, dy, k in ((1, -5, 4), (0, -4, 4), (0, -3, 3), (-1, -2, 2), (0, -2, 3), (1, -2, 2), (-1, -1, 2),
                          (0, -1, 3), (1, -1, 1), (-1, 0, 1), (0, 0, 2), (1, 0, 0), (0, 1, 0)):
            s.put(fx + dx, fy + dy, FIRE[k])
    s.outline(0.42)
    _node_shadow(s, 8, 6)
    return s


SUNG = [(76, 66, 18), (124, 110, 28), (176, 158, 42), (218, 200, 68), (246, 236, 140)]


def herb_sungrass():
    """Sungrass: a fan of tall golden blades with a sunburst flower held above them"""
    s = Spr(16, 16)
    for ctrl, tip in (((4, 12), (1, 7)), ((5, 9), (4, 3)), ((11, 9), (12, 3)), ((12, 12), (15, 7)),
                      ((6, 12), (2, 11)), ((10, 12), (14, 11))):
        _blade(s, (8, 13), ctrl, tip, SUNG)
    _blade(s, (8, 13), (8, 9), (8, 5), LEAF, wide=1)                                        # the flower's stem
    for dx, dy in ((0, -2), (0, 2), (-2, 0), (2, 0), (-1, -1), (1, -1), (-1, 1), (1, 1)):    # rays
        s.put(8 + dx, 3 + dy, SUNG[4] if dx <= 0 and dy <= 0 else SUNG[3])
    s.put(8, 3, (236, 140, 40)); s.put(7, 3, (250, 186, 70)); s.put(8, 2, (250, 186, 70))  # the heart
    s.outline(0.42)
    _node_shadow(s, 8, 6)
    return s


# the boulder and the small rock at its foot, face by face: T top (in the light), L upper left, F front, R right
# (turned away), D the underside; lower case = a pit in that face
ORE_ROCK = ["................",
            "................",
            "....TTTT........",
            "...TTTtTTT......",
            "..LTTTTTTTTR....",
            "..LLTTTTTTFRR...",
            ".LLlLTTTFFFRR...",
            ".LLLLLFFFfFFRR..",
            "LLLLLFFFFFFFRR..",
            "LlLLFFFFFFFRRr..",
            "LLLFFfFFFFFRRTTT",
            ".LLFFFFFFFRRLTtR",
            ".LLFFFFFFRRDLLFR",
            "..DDFFFFRRDDLFFR",
            "................",
            "................"]
FACE = {"T": 4, "L": 3, "F": 2, "R": 1, "D": 0}


def _facet_rock(ramp):
    """the ore rock painted from ORE_ROCK; returns the sprite and each pixel's light (0..1) for the seams"""
    s = Spr(16, 16)
    lit = {}
    for y, row in enumerate(ORE_ROCK):
        for x, ch in enumerate(row):
            if ch == ".":
                continue
            k = FACE[ch.upper()] - (1 if ch.islower() else 0)
            s.put(x, y, ramp[max(0, k)])
            lit[(x, y)] = FACE[ch.upper()] / 4.0
    for y, row in enumerate(ORE_ROCK):                                                     # lit ridge on the top
        for x, ch in enumerate(row):
            if ch == "T" and y > 0 and ORE_ROCK[y - 1][x] == ".":
                s.put(x, y, ramp[-1] if len(ramp) > 5 else ramp[4])
    return s, lit


def _vein(s, lit, pts, ore):
    """a seam of ore along pts, its colour following the face it crosses"""
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        n = int(max(abs(x1 - x0), abs(y1 - y0))) + 1
        for i in range(n):
            t = i / max(1, n - 1)
            x, y = int(round(x0 + (x1 - x0) * t)), int(round(y0 + (y1 - y0) * t))
            if (x, y) in lit:
                s.put(x, y, _pick(ore[:-1], lit[(x, y)]))


def _nugget(s, lit, x, y, ore, glint=False):
    """a lump of ore standing out of the rock: lit corner, dark corner, maybe a glint"""
    if (x, y) not in lit:
        return
    s.put(x, y, ore[-2]); s.put(x + 1, y, ore[-3]); s.put(x, y + 1, ore[-3]); s.put(x + 1, y + 1, ore[0])
    s.put(x, y - 1, ore[-1] if glint else ore[-2])


def _crystal(s, x, base, h, ramp):
    """a crystal point growing out of the rock: lit left face, darker right face, a bright tip"""
    for y in range(base - h + 1, base + 1):
        s.put(x, y, ramp[-2]); s.put(x + 1, y, ramp[1])
    s.put(x, base - h, ramp[-1]); s.put(x + 1, base - h + 1, ramp[2])


def _ore_node(ore, rock=STONE, seams=True, crystals=None, glow=False):
    """a gatherable vein: a faceted boulder with a smaller rock and a pebble at its foot, seams of ore crossing the
    faces and lumps standing out; crystal ores grow points out of the top; Dark Iron's seams glow"""
    s, lit = _facet_rock(rock)
    if seams:
        _vein(s, lit, [(1, 10), (3, 8), (5, 7), (7, 6), (9, 6), (10, 5)], ore)
        _vein(s, lit, [(4, 12), (6, 11), (8, 10), (10, 9), (12, 8)], ore)
    for i, (x, y) in enumerate(((5, 4), (8, 8), (2, 6), (13, 10))):
        _nugget(s, lit, x, y, ore, glint=(i == 1))
    for x, base, h in crystals or ():
        _crystal(s, x, base, h, ore)
    if glow:                                                                                # the seams' heat
        for (x, y), v in lit.items():
            c = s.get(x, y)
            if c in ore[1:-1] and H(x, y, 21) < 0.3:
                s.put(x, y, ore[-1])
    s.outline(0.42)
    _node_shadow(s, 8, 7.6)
    return s


COPPER = [(92, 40, 20), (156, 76, 34), (210, 122, 60), (240, 172, 112), (252, 226, 190)]
TIN = [(64, 82, 102), (112, 136, 160), (166, 192, 214), (212, 230, 244), (248, 252, 255)]
IRONORE = [(64, 30, 22), (112, 54, 34), (160, 86, 52), (198, 128, 88), (232, 186, 150)]
GOLDORE = [(108, 68, 14), (176, 124, 26), (230, 182, 52), (252, 222, 108), (255, 250, 210)]
MITHRIL = [(46, 80, 104), (82, 132, 162), (130, 186, 212), (186, 228, 244), (244, 254, 255)]
TRUESILVER = [(84, 82, 108), (136, 134, 166), (190, 188, 216), (230, 230, 248), (255, 255, 255)]
DARKIRON = [(86, 14, 10), (164, 34, 18), (226, 82, 30), (252, 156, 56), (255, 226, 150)]
BASALT = [(16, 12, 14), (30, 24, 26), (48, 38, 40), (70, 56, 56), (96, 80, 76)]
WARM = [(40, 34, 32), (66, 58, 54), (96, 86, 78), (128, 118, 106), (162, 152, 136)]


def vein_copper():
    s = _ore_node(COPPER)
    for x, y in ((5, 8), (10, 10), (13, 11)):                                               # verdigris
        if s.get(x, y): s.put(x, y, (70, 150, 120))
    return s


def vein_tin():
    return _ore_node(TIN)


def vein_iron():
    return _ore_node(IRONORE, rock=WARM)


def vein_gold():
    return _ore_node(GOLDORE)


def vein_mithril():
    return _ore_node(MITHRIL, crystals=((4, 5, 3), (7, 3, 3), (10, 4, 2)))


def vein_truesilver():
    return _ore_node(TRUESILVER, crystals=((5, 4, 3), (9, 3, 2)))


def vein_darkiron():
    return _ore_node(DARKIRON, rock=BASALT, glow=True)


BLUE = [(26, 40, 74), (44, 66, 116), (70, 100, 160), (120, 150, 204)]
GOLD = [(110, 74, 20), (176, 128, 36), (224, 182, 64), (250, 228, 130)]

# ---------------------------------------------------------------------------- the rest of the world's props

ROCK = [(36, 32, 30), (62, 56, 52), (92, 84, 76), (124, 114, 102), (156, 146, 130)]
SAND = [(110, 82, 52), (156, 120, 80), (196, 160, 110), (226, 196, 146), (244, 222, 178)]
STRAW = [(110, 80, 30), (164, 124, 44), (206, 168, 70), (232, 204, 110), (248, 232, 160)]
ORANGE = [(120, 50, 14), (184, 86, 24), (228, 126, 40), (246, 168, 76)]


def gravestone():
    s = Spr(16, 16)
    def stone(x, y):
        c = STONE[3] if x < 7 else STONE[2]
        if y < 5 and x < 9: c = STONE[4]
        if H(x, y, 4) < 0.08: c = STONE[1]
        return c
    s.poly([(4, 15), (4, 5), (6, 2), (10, 2), (12, 5), (12, 15)], stone)
    s.rect(7, 5, 8, 11, STONE[1]); s.rect(5, 7, 10, 8, STONE[1])                                     # the cross
    s.put(7, 5, STONE[0]); s.put(8, 6, STONE[0])
    for x, y in ((4, 13), (5, 14), (11, 12), (11, 13), (6, 2)):                                      # moss
        s.put(x, y, (70, 96, 60))
    s.rect(3, 15, 13, 15, (70, 60, 50))                                                               # the mound
    s.outline(0.42)
    return s


def ironfence():
    """repeats sideways: bars with spear tips between two rails"""
    s = Spr(16, 16)
    for y in (5, 12):
        s.rect(0, y, 15, y, IRON[2]); s.rect(0, y + 1, 15, y + 1, IRON[1])
    for x in (1, 5, 9, 13):
        s.rect(x, 3, x, 15, IRON[2]); s.put(x + 1, 4, IRON[1])
        s.put(x, 1, IRON[3]); s.put(x - 1, 2, IRON[2]); s.put(x + 1, 2, IRON[2]); s.put(x, 2, IRON[3])
    s.outline(0.5)
    return s


def fence():
    """repeats sideways: posts and two rails, lit from the top left"""
    s = Spr(16, 16)
    for y in (6, 11):
        s.rect(0, y, 15, y + 1, WOOD[3]); s.rect(0, y, 15, y, WOOD[4]); s.rect(0, y + 2, 15, y + 2, WOOD[1])
    for x in (2, 13):
        s.rect(x, 3, x + 1, 15, WOOD[2]); s.rect(x, 3, x, 15, WOOD[3]); s.put(x, 3, WOOD[4]); s.put(x + 1, 3, WOOD[3])
    s.outline(0.42)
    return s


def crate():
    s = Spr(16, 16)
    s.rect(2, 3, 13, 15, WOOD[3]); s.rect(2, 3, 13, 3, WOOD[4]); s.rect(13, 4, 13, 15, WOOD[2])
    for y in (7, 11):
        s.rect(3, y, 12, y, WOOD[2])
    s.line(3, 4, 12, 14, WOOD[1]); s.line(4, 4, 12, 13, WOOD[2])
    s.rect(2, 3, 2, 15, WOOD[2]); s.rect(2, 15, 13, 15, WOOD[1])
    for x, y in ((3, 4), (12, 4), (3, 14), (12, 14)):
        s.put(x, y, IRON[3])
    s.outline(0.42)
    return s


def barrel():
    """the Defias' powder keg: bulging staves round a lit left side, two iron hoops, the lid with its bung and a
    lit fuse"""
    s = Spr(16, 16)
    for y in range(5, 16):
        hw = 4.6 + 1.1 * math.sin(math.pi * (y - 5) / 10)
        for x in range(16):
            lx = (x + 0.5 - 8) / hw
            if abs(lx) > 1:
                continue
            v = 0.66 - 0.42 * lx - 0.3 * lx * lx
            if (math.asin(max(-0.99, min(0.99, lx))) / (math.pi / 2) * 3 + 3.5) % 1 < 0.22:
                v -= 0.2                                                                    # stave seams
            s.put(x, y, _pick(WOOD, v))
    for y in (7, 13):                                                                       # hoops
        for x in range(16):
            if s.get(x, y) is not None:
                lx = (x + 0.5 - 8) / 5.6
                s.put(x, y, IRON[3] if lx < -0.4 else IRON[2] if lx < 0.4 else IRON[1])
                if s.get(x, y - 1) is not None and lx < 0.2: s.put(x, y - 1, _pick(WOOD, 0.2))
    s.ellipse(8, 4.6, 4.9, 1.9, lambda x, y: WOOD[4] if y < 4 else WOOD[3])                # the lid
    for x in range(4, 12):
        s.put(x, 5, WOOD[2])
    s.put(4, 4, WOOD[2]); s.put(11, 4, WOOD[1])
    s.put(10, 4, (40, 28, 22)); s.put(10, 3, (70, 56, 40)); s.put(11, 2, (70, 56, 40))      # bung + fuse
    s.put(12, 1, FIRE[3]); s.put(12, 0, FIRE[4]); s.put(13, 1, FIRE[2])
    s.outline(0.42)
    return s


def hay():
    s = Spr(16, 16)
    def straw(x, y):
        c = STRAW[3] if (x + y * 2) % 5 else STRAW[2]
        if y < 7: c = STRAW[4] if (x + y) % 4 else STRAW[3]
        if x > 11: c = STRAW[1] if (x + y) % 3 else STRAW[2]
        return c
    s.poly([(1, 15.5), (1, 6), (3, 4), (13, 4), (15, 6), (15, 15.5)], straw)
    s.rect(1, 9, 15, 9, (130, 80, 40)); s.rect(1, 13, 15, 13, (130, 80, 40))                           # twine
    s.put(4, 3, STRAW[3]); s.put(9, 2, STRAW[4]); s.put(12, 3, STRAW[3])
    s.outline(0.42)
    return s


def pumpkin():
    s = Spr(16, 16)
    def rind(x, y):
        lx = (x - 8) / 6
        c = ORANGE[3] if lx < -0.4 else ORANGE[2] if lx < 0.35 else ORANGE[1]
        if x in (5, 8, 11): c = ORANGE[1] if lx < 0.35 else ORANGE[0]
        return c
    s.ellipse(8, 10.5, 6.5, 4.8, rind)
    s.put(5, 7, ORANGE[3]); s.put(6, 7, ORANGE[3])
    s.rect(8, 4, 8, 6, (90, 70, 30)); s.put(9, 4, (110, 86, 40))
    s.put(10, 5, LEAF[2]); s.put(11, 5, LEAF[3]); s.put(11, 4, LEAF[2])
    s.outline(0.42)
    return s


def cannon():
    s = Spr(16, 16)
    s.rect(2, 10, 13, 12, WOOD[2]); s.rect(2, 10, 13, 10, WOOD[3])                                    # carriage
    s.ellipse(5, 13, 2.6, 2.6, lambda x, y: WOOD[1]); s.put(5, 13, IRON[3])                              # wheels
    s.ellipse(11, 13, 2.6, 2.6, lambda x, y: WOOD[1]); s.put(11, 13, IRON[3])
    for i, x in enumerate(range(1, 14)):                                                                  # the barrel
        y0 = 6 - (1 if x > 10 else 0)
        s.rect(x, y0, x, y0 + 3, IRON[3] if x < 5 else IRON[2])
        s.put(x, y0, IRON[4] if x < 8 else IRON[3])
    s.ellipse(14, 6.5, 1.2, 2, lambda x, y: IRON[0])
    s.rect(1, 6, 1, 9, IRON[1])
    s.outline(0.42)
    return s


def scarecrow():
    s = Spr(16, 32)
    s.rect(7, 12, 8, 31, WOOD[2]); s.rect(7, 12, 7, 31, WOOD[3])                                       # pole
    s.rect(1, 14, 14, 15, WOOD[2]); s.rect(1, 14, 14, 14, WOOD[3])                                     # crossbar
    for x in range(2, 14):                                                                            # the shirt
        for y in range(13, 22):
            if abs(x - 7.5) < 4 or y < 17:
                plaid = RED[2] if (x // 2 + y // 2) % 2 else RED[1]
                if x % 4 == 0 or y % 4 == 0: plaid = (60, 40, 50)
                s.put(x, y, plaid)
    for x in (1, 14):
        s.put(x, 16, STRAW[3]); s.put(x, 17, STRAW[2])                                                 # straw hands
    s.ellipse(7.5, 9, 3.4, 3.6, lambda x, y: CANVAS[3] if x < 8 else CANVAS[2])                       # sack head
    s.put(6, 8, (30, 20, 20)); s.put(9, 8, (30, 20, 20))
    for x in range(5, 11):
        if x % 2: s.put(x, 11, (60, 40, 30))                                                           # stitched mouth
    s.rect(2, 5, 13, 6, STRAW[2]); s.rect(5, 1, 10, 5, STRAW[3]); s.rect(5, 1, 10, 1, STRAW[4])        # the hat
    s.rect(5, 4, 10, 4, RED[1])
    for x in (6, 9):
        s.put(x, 22, STRAW[3]); s.put(x, 23, STRAW[2])
    s.outline(0.42)
    return s


def windmill():
    """a stone mill: the tapered tower, a thatched cap, four lattice sails (a spar, a frame of bars round the
    canvas) turning about a wooden hub"""
    s = Spr(32, 48)
    def tower(x, y):
        lx = (x - 16) / 9
        c = STONE[3] if lx < -0.3 else STONE[2] if lx < 0.4 else STONE[1]
        if y % 5 == 4 or (x + (y // 5) * 3) % 7 == 0: c = STONE[1] if lx < 0.4 else STONE[0]
        return c
    s.poly([(7, 47.5), (10, 18), (22, 18), (25, 47.5)], tower)
    s.rect(14, 38, 18, 47, WOOD[1]); s.rect(15, 39, 17, 47, (40, 26, 20)); s.put(15, 39, WOOD[2])  # door
    s.rect(15, 27, 17, 30, (30, 34, 50)); s.put(15, 27, BLUE[2]); s.rect(14, 31, 18, 31, STONE[4])  # window
    def cap(x, y):
        lx = (x - 16) / 8.5
        c = THATCH[4] if lx < -0.45 else THATCH[3] if lx < 0.05 else THATCH[2] if lx < 0.5 else THATCH[1]
        if (y - 11) % 3 == 2: c = THATCH[max(0, THATCH.index(c) - 1)]
        return c
    s.ellipse(16, 18.5, 8.6, 6.2, cap)
    for x in range(8, 25):
        s.put(x, 20 + (1 if H(x, 2) < 0.5 else 0), THATCH[1] if x > 17 else THATCH[2])        # ragged eave
    for y in range(12, 22):
        for x in range(32):
            if y >= 19 and s.get(x, y) in THATCH: pass
    hx, hy = 16, 17
    for k in range(4):
        a = 0.35 + k * math.pi / 2
        ux, uy = math.cos(a), math.sin(a)
        px, py = -uy, ux
        for y in range(48):
            for x in range(32):
                dx, dy = x + 0.5 - hx, y + 0.5 - hy
                u, w = dx * ux + dy * uy, dx * px + dy * py
                if 0 <= u <= 15.5 and abs(w) < 0.75:
                    s.put(x, y, WOOD[1])                                                    # the spar
                elif 3.5 <= u <= 15.5 and 0.75 <= w <= 4.6:
                    frame = (u % 3.0) < 0.9 or w > 3.8 or u > 14.6
                    lit = (ux + uy) < 0
                    s.put(x, y, (WOOD[3] if lit else WOOD[2]) if frame else (CANVAS[4] if lit else CANVAS[3]))
    s.ellipse(hx, hy, 2.0, 2.0, lambda x, y: WOOD[2] if x < hx else WOOD[1])
    s.put(hx - 1, hy - 1, IRON[3]); s.put(hx, hy, IRON[2])
    s.outline(0.42)
    return s


def mineentrance(rock=ROCK, moss=True):
    """a mine cut into a rocky hill: the hill rises from the ground at both sides to a crown over the door (no square
    edges), its boulders each lit on their own inside the hill's own light and parted by dark cracks, moss on the
    ledges, a timber frame under an overhang, rails running into the dark, a lantern (the walkable door tile is the
    middle of the bottom row; the ground baker lays scree and worn earth round its foot). Blackrock's is basalt."""
    s = Spr(48, 32)
    seeds = [(4, 27), (9, 19), (13, 9), (21, 3), (30, 3), (37, 9), (41, 18), (44, 27), (10, 28), (38, 28),
             (25, 8), (16, 3), (34, 14)]

    def top(x):
        cx = abs(x + 0.5 - 24) / 24
        return 0.6 + 21.0 * cx ** 1.7 - 1.3 * math.sin(x * 0.61) * (0.4 + cx)

    def bottom(x):
        cx = abs(x + 0.5 - 24)
        return 31.5 - max(0.0, cx - 19) * 0.9

    lit = {}
    for y in range(32):
        for x in range(48):
            if not (top(x) <= y + 0.5 <= bottom(x)):
                continue
            d = sorted((math.hypot(x + 0.5 - sx, (y + 0.5 - sy) * 1.25), i) for i, (sx, sy) in enumerate(seeds))
            (d0, i0), (d1, _) = d[0], d[1]
            sx, sy = seeds[i0]
            r = max(4.0, d1)
            v = (_lit((x + 0.5 - sx) / (r * 1.1), (y + 0.5 - sy) / (r * 1.1)) + 0.8) / 1.8
            hill = (_lit((x + 0.5 - 24) / 26, (y + 0.5 - 22) / 24) + 0.8) / 1.8           # the hill's own light
            v = 0.55 * v + 0.45 * hill - 0.04
            if d1 - d0 < 1.1: v = 0.02                                                      # the cracks
            elif d1 - d0 < 2.0: v -= 0.16
            if H(x // 2, y // 2, i0) < 0.1: v -= 0.08
            if y + 0.5 > bottom(x) - 2: v -= 0.12                                           # the foot, in shade
            lit[(x, y)] = v
            s.put(x, y, _pick(rock, v))
    for x in range(48):                                                                     # moss on the ledges
        for y in range(32):
            if (x, y) in lit:
                if moss and H(x, 7) < 0.55:
                    s.put(x, y, MOSS[2] if H(x, 8) < 0.5 else MOSS[1])
                    if H(x, 9) < 0.35: s.put(x, y + 1, MOSS[1])
                break
    for y in range(13, 32):                                                                 # the dark inside
        for x in range(18, 30):
            depth = min(x - 18, 29 - x, y - 13)
            s.put(x, y, (10, 8, 8) if depth > 2 else (20, 15, 13) if depth > 0 else (32, 24, 20))
    for y in range(21, 32):                                                                 # rails into the dark
        t = (y - 21) / 10
        l, r_ = int(round(21.5 - 2.5 * t)), int(round(26.5 + 2.5 * t))
        c = IRON[1] if y < 25 else IRON[2]
        s.put(l, y, c); s.put(r_, y, c)
        if y % 3 == 1:
            for x in range(l + 1, r_):
                s.put(x, y, WOOD[1] if y > 25 else DWOOD[1])
    for x0 in (15, 30):                                                                     # posts
        s.rect(x0, 12, x0 + 2, 31, WOOD[2]); s.rect(x0, 12, x0, 31, WOOD[3]); s.rect(x0 + 2, 12, x0 + 2, 31, WOOD[1])
        for y in (16, 22, 27):
            s.put(x0 + 1, y, WOOD[1])
    s.rect(13, 9, 34, 12, WOOD[3]); s.rect(13, 9, 34, 9, WOOD[4]); s.rect(13, 12, 34, 12, WOOD[1])  # the lintel
    for x in (13, 34):
        s.rect(x, 10, x, 11, THATCH[3])                                                     # end grain
    for x in range(14, 34):                                                                 # the overhang's shadow
        if s.get(x, 8) is not None: s.put(x, 8, rock[0])
    for k in range(4):                                                                      # braces
        s.put(18 + k, 13 + k, WOOD[2]); s.put(29 - k, 13 + k, WOOD[2])
    s.put(27, 13, IRON[2]); s.rect(26, 14, 28, 16, IRON[1]); s.put(27, 15, FIRE[3])         # the lantern
    s.put(27, 14, FIRE[2]); s.put(26, 15, FIRE[1])
    s.outline(0.42, skip_bottom=True)
    return s


def mast():
    """a ship's mast: shrouds with ratlines behind, the pole with iron bands, two yards with their sails furled and
    lashed, a crow's nest and a black flag"""
    s = Spr(16, 48)
    ROPE, ROPED = (126, 104, 72), (86, 70, 50)
    shrouds = [(5.5, 12, 0.5, 47), (10.5, 12, 15.5, 47)]
    for x0, y0, x1, y1 in shrouds:
        s.line(x0, y0, x1, y1, ROPE)
    for y in range(18, 47, 4):                                                              # ratlines
        t = (y - 12) / 35
        s.line(5.5 + (0.5 - 5.5) * t, y, 6, y, ROPED); s.line(9, y, 10.5 + 5 * t, y, ROPED)
    for y in range(1, 48):                                                                  # the pole
        s.put(7, y, WOOD[3]); s.put(8, y, WOOD[1])
    for y in (22, 38):
        s.put(7, y, IRON[3]); s.put(8, y, IRON[1])
    for yy, x0, x1 in ((16, 1, 14), (31, 2, 13)):                                           # yards + furled sails
        s.rect(x0, yy, x1, yy, WOOD[3]); s.put(x1, yy, WOOD[1])
        for x in range(x0, x1 + 1):
            if x in (7, 8):
                continue
            sag = 1 if 2 < x - x0 < x1 - x0 - 2 and (x % 5) else 0
            s.put(x, yy + 1, CANVAS[4] if x < 8 else CANVAS[3])
            s.put(x, yy + 2, CANVAS[2] if x < 8 else CANVAS[1])
            if sag: s.put(x, yy + 3, CANVAS[1])
            if (x - x0) % 4 == 1:
                s.put(x, yy + 1, ROPED); s.put(x, yy + 2, ROPED)                            # lashings
    s.rect(5, 9, 10, 12, WOOD[2]); s.rect(5, 9, 10, 9, WOOD[4])                             # crow's nest
    s.rect(5, 10, 5, 12, WOOD[3]); s.rect(10, 10, 10, 12, WOOD[1])
    for x in (7, 9): s.put(x, 11, WOOD[1])
    for x, y in ((9, 1), (10, 1), (11, 1), (12, 2), (9, 2), (10, 2), (11, 2), (12, 3), (13, 3), (9, 3), (10, 3),
                 (11, 3), (12, 4)):
        s.put(x, y, (34, 32, 38))                                                           # the black flag
    s.put(10, 2, (220, 214, 200)); s.put(11, 3, (150, 146, 138))
    s.put(7, 0, WOOD[4]); s.put(8, 0, WOOD[2])
    s.outline(0.42)
    return s


def _plinth_base(s):
    s.rect(3, 9, 12, 15, STONE[2]); s.rect(3, 9, 12, 9, STONE[4]); s.rect(12, 10, 12, 15, STONE[1])
    s.rect(2, 14, 13, 15, STONE[1]); s.rect(2, 14, 13, 14, STONE[3])


def plinth():
    s = Spr(16, 16)
    _plinth_base(s)
    s.rect(6, 6, 9, 8, GOLD[2]); s.rect(5, 2, 10, 5, GOLD[2]); s.rect(5, 2, 10, 2, GOLD[3])             # the cup
    s.put(4, 3, GOLD[1]); s.put(11, 3, GOLD[1]); s.put(6, 3, GOLD[3]); s.rect(7, 8, 8, 8, GOLD[1])
    s.outline(0.42)
    return s


def plinthempty():
    s = Spr(16, 16)
    _plinth_base(s)
    s.rect(5, 8, 10, 8, STONE[0])
    s.outline(0.42)
    return s


def trophyboard():
    s = Spr(16, 16)
    s.rect(1, 2, 14, 13, DWOOD[2]); s.rect(1, 2, 14, 2, DWOOD[3]); s.rect(2, 3, 13, 12, PAPER[2])
    for y in (5, 7, 9, 11):
        s.rect(4, y, 11 - (y % 3), y, DWOOD[1]); s.put(3, y, GOLD[2])
    s.rect(3, 14, 4, 15, DWOOD[1]); s.rect(11, 14, 12, 15, DWOOD[1])
    s.outline(0.42)
    return s


# atlas name -> sprite; multi-tile ones are stamps (cut into name_x_y cells by the atlas build)
PROPS = {"sign": sign, "wantedboard": wantedboard, "forge": forge, "anvil": anvil, "alchemy": alchemy,
         "lamppost": lamppost, "deadtree": deadtree, "jtree": palm, "dtree": fir,
         "wtree": lambda: oak(WLEAF), "rtree": lambda: oak(AUTUMN, AMBER, bias=-0.1), "stree": charredtree,
         "tent": tent, "hut": hut, "totem": totem,
         "node_peacebloom": herb_peacebloom, "node_silverleaf": herb_silverleaf, "node_earthroot": herb_earthroot,
         "node_mageroyal": herb_mageroyal, "node_briarthorn": herb_briarthorn, "node_copper": vein_copper,
         "node_tin": vein_tin, "node_iron": vein_iron, "node_gold": vein_gold, "node_mithril": vein_mithril,
         "node_truesilver": vein_truesilver, "node_darkiron": vein_darkiron,
         "node_fadeleaf": herb_fadeleaf, "node_kingsblood": herb_kingsblood, "node_firebloom": herb_firebloom,
         "node_sungrass": herb_sungrass,
         "gravestone": gravestone, "ironfence": ironfence, "fence": fence, "crate": crate, "barrel": barrel,
         "hay": hay, "pumpkin": pumpkin, "cannon": cannon, "scarecrow": scarecrow, "windmill": windmill,
         "mineentrance": mineentrance, "bmineentrance": lambda: mineentrance(BASALT, moss=False), "mast": mast, "plinth": plinth, "plinthempty": plinthempty,
         "trophyboard": trophyboard}


def sprites():
    """name -> Spr: the props plus the 16 ruin wall pieces (ruinwall_<mask>, mask bits N=1 E=2 S=4 W=8)"""
    out = {name: fn() for name, fn in PROPS.items()}
    for m in range(16):
        out["ruinwall_%d" % m] = ruinwall(m)
        out["cavewall_%d" % m] = ruinwall(m, RUIN=ROCK, moss=False, glyph=False, timber=True)
        out["arenawall_%d" % m] = ruinwall(m, RUIN=SAND, moss=False, glyph=False)
    return out


def images():
    return {name: s.image() for name, s in sprites().items()}


def build(out):
    sprites_ = sprites()
    W = 256
    x = y = rowh = 0
    meta = {}
    places = []
    for name, s in sprites_.items():
        if x + s.w > W:
            x, y, rowh = 0, y + rowh, 0
        places.append((name, s, x, y))
        meta[name] = [x, y, s.w, s.h]
        x += s.w
        rowh = max(rowh, s.h)
    sheet = Image.new("RGBA", (W, y + rowh), (0, 0, 0, 0))
    for name, s, px, py in places:
        sheet.alpha_composite(s.image(), (px, py))
    sheet.save(os.path.join(out, "props.png"))
    json.dump(meta, open(os.path.join(out, "props.json"), "w"))
    return sheet, meta


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    sheet, meta = build(out)
    sheet.resize((sheet.width * 4, sheet.height * 4), Image.NEAREST).save(os.path.join(out, "props_preview.png"))
    print(len(meta), sheet.size)

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


def deadtree():
    s = Spr(16, 16)
    def limb(x0, y0, x1, y1, c):
        s.line(x0, y0, x1, y1, c)
    s.rect(7, 9, 9, 15, BARK[2]); s.rect(7, 9, 7, 15, BARK[3]); s.rect(9, 10, 9, 15, BARK[1])
    s.put(6, 15, BARK[1]); s.put(10, 15, BARK[1]); s.put(5, 15, BARK[0])
    limb(8, 10, 3, 4, BARK[2]); limb(8, 9, 12, 3, BARK[2]); limb(8, 9, 8, 1, BARK[3])
    limb(4, 5, 1, 4, BARK[1]); limb(11, 4, 14, 4, BARK[1]); limb(8, 3, 6, 0, BARK[2])
    limb(5, 6, 5, 3, BARK[3]); limb(12, 3, 13, 1, BARK[2])
    s.put(8, 12, BARK[0])                                                                            # a knot
    s.outline(0.5)
    return s


def palm():
    s = Spr(16, 16)
    for i, y in enumerate(range(6, 16)):                                                             # bent trunk
        x = 8 + int(round(math.sin(i * 0.28) * 1.4))
        c = WOOD[3] if i % 2 == 0 else WOOD[2]
        s.put(x - 1, y, c); s.put(x, y, WOOD[1] if i % 2 else WOOD[2])
    fr = [(-7, 2), (-6, -2), (-2, -5), (3, -5), (7, -2), (7, 3)]
    for dx, dy in fr:                                                                                 # fronds
        n = 7
        for k in range(1, n + 1):
            t = k / n
            x = 8 + dx * t
            y = 5 + dy * t + 2.2 * t * t
            s.put(x, y, LEAF[3] if k < 4 else LEAF[2])
            if k > 1: s.put(x, y + 1, LEAF[1])
            if k in (2, 4, 6) and abs(dx) > 3: s.put(x, y - 1, LEAF[4])
    s.ellipse(8, 5, 2.2, 1.6, lambda x, y: LEAF[3])
    s.put(7, 6, (120, 80, 40)); s.put(9, 6, (96, 64, 32)); s.put(8, 7, (120, 80, 40))               # coconuts
    s.outline(0.4)
    return s


def pine():
    s = Spr(16, 16)
    s.rect(7, 13, 8, 15, BARK[1]); s.put(7, 13, BARK[2])
    tiers = [(1, 4.5, 2.5), (5, 6.0, 4.2), (9, 7.4, 6.0)]
    for top, half, depth in tiers:
        bot = top + depth
        def f(x, y, top=top, bot=bot):
            lx = (x - 8) / 7
            if y >= bot - 0.8: return PINE[1]
            return PINE[4] if lx < -0.45 and y < bot - 1 else PINE[3] if lx < 0 else PINE[2]
        s.poly([(8, top - 0.5), (8 + half, bot), (8 - half, bot)], f)
    for x, y in ((5, 8), (4, 12), (10, 11), (7, 4)):
        s.put(x, y, PINE[4])
    s.outline(0.5)
    return s


# ---------------------------------------------------------------------------- stamps

def tent():
    s = Spr(32, 32)
    # the side roof (seen in 3/4: the right slope runs back)
    s.poly([(15, 3), (30, 26), (30, 29.5), (20, 29.5)], lambda x, y: CANVAS[1] if (x + y) % 7 else CANVAS[0])
    def front(x, y):
        c = CANVAS[3] if x < 12 else CANVAS[2]
        if (x - 3) % 5 == 0 and x < 15: c = CANVAS[2] if x < 12 else CANVAS[1]                  # seams
        return c
    s.poly([(15, 3), (24, 29.5), (2, 29.5)], front)
    s.line(15, 3, 3, 29, CANVAS[4])                                                                  # lit edge
    # the opening, with the flap folded back
    s.poly([(14, 12), (19, 29.5), (11, 29.5)], lambda x, y: (34, 24, 22) if y > 16 else (52, 38, 32))
    s.poly([(14, 12), (11, 29.5), (8, 29.5), (12, 18)], lambda x, y: CANVAS[4] if x < 11 else CANVAS[3])
    s.line(14, 12, 9, 29, CANVAS[2])
    s.put(15, 26, (90, 70, 50)); s.put(16, 27, (70, 54, 40)); s.put(14, 28, (90, 70, 50))          # bedroll inside
    # pole, flag, ropes and pegs
    s.rect(15, 0, 15, 3, WOOD[1]); s.put(16, 0, RED[2]); s.put(17, 0, RED[2]); s.put(16, 1, RED[1])
    s.line(3, 28, 0, 31, WOOD[2]); s.line(26, 26, 31, 30, WOOD[2])
    s.put(0, 31, WOOD[1]); s.put(31, 31, WOOD[1])
    s.outline(0.42)
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


def ruinwall(mask):
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
        if H(mask, 5, 7) < 0.5:                                                                     # a carved glyph
            gx = 6
            for dx, dy in ((0, 0), (1, 1), (2, 0), (1, 2)): s.put(gx + dx, top_end + 2 + dy, TEAL[1])
    # moss on top and dripping over the face
    for x in range(x0, x1 + 1):
        hm = H(x, mask, 11)
        if hm < 0.45:
            ys = y0 + int(H(x, 3, mask) * 3)
            s.put(x, ys, MOSS[2 if hm < 0.25 else 1]); s.put(x, ys + 1, MOSS[1])
        if face and hm < 0.2:
            for k in range(1 + int(H(x, 4) * 3)): s.put(x, top_end + 1 + k, MOSS[1] if k else MOSS[2])
    # broken crumbs
    if not n and H(mask, 1, 2) < 0.6:
        s.put(x0 + 4, y0, None) if False else None
    s.outline(0.42)
    # outline must not cut where the wall continues
    for y in range(16):
        for x in range(16):
            c = s.p[y][x]
            if c is None: continue
    return s


# atlas name -> sprite; multi-tile ones are stamps (cut into name_x_y cells by the atlas build)
PROPS = {"sign": sign, "wantedboard": wantedboard, "forge": forge, "anvil": anvil, "alchemy": alchemy,
         "lamppost": lamppost, "deadtree": deadtree, "jtree": palm, "dtree": pine,
         "tent": tent, "hut": hut, "totem": totem}


def sprites():
    """name -> Spr: the props plus the 16 ruin wall pieces (ruinwall_<mask>, mask bits N=1 E=2 S=4 W=8)"""
    out = {name: fn() for name, fn in PROPS.items()}
    for m in range(16):
        out["ruinwall_%d" % m] = ruinwall(m)
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

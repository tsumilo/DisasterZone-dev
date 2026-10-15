"""Goldshire's new buildings for the atlas (Azeromon 0.27, the bigger Goldshire), cut from the finished house stamps'
own pixels (house / farmhouse / stonehouse / bbhouse: DawnBringer 32, the 4-px plank rhythm, brick gables, timber
beam, log-end posts) and put back together in new shapes, so they match the existing houses exactly. Approved in the
"alive" mockup (dev/art/casc/azeromon_alive, 2026-10-15).

  inn      9 x 8  the Lion's Pride: two red gables meeting in a valley, a second storey of guest rooms with flower
                  boxes, a double door (doors dx 4 and 5 on the bottom row), lanterns and the lion sign
  smithy   5 x 6  slate roof, an open front with the forge glowing inside and tools on the back wall (no door)
  cottage  5 x 6  thatched roof, flower box under the window (door dx 3, dy 5 like a house)
  stable   5 x 6  brown roof, barn doors with cross braces (no door)
  well     2 x 3  stone curb, timber posts, a small shingled roof, crank and bucket (DawnBringer 16, hand-placed)

Used by gen_azeromon_art.py: tiles(cell) -> [(name_x_y, 16 x 16 RGBA Image)] where cell(name) returns an atlas tile
as a (16, 16, 4) array (taken after the stamps' grass margins are cleaned). SIZE / DOORS / CHIMNEYS / FORGE describe
each kind for the game (Game.lua STAMP_SIZE, the baker's lights, UI.lua's chimney smoke)."""
import numpy as np
from PIL import Image

K = (34, 32, 52)                          # the stamps' outline

SIZE = {"inn": (9, 8), "smithy": (5, 6), "cottage": (5, 6), "stable": (5, 6), "well": (2, 3)}
DOORS = {"inn": [(4, 7), (5, 7)], "cottage": [(3, 5)]}
CHIMNEYS = {"inn": [(16, 27), (80, 27)], "smithy": [(16, 13)], "cottage": [(16, 13)], "stable": [(16, 13)]}
FORGE = {"smithy": (24, 87)}              # the forge's glow inside the smithy (px in the stamp)


def unit(cell, kind):
    """a finished 5 x 6 house stamp as a (96, 80, 4) uint8 array, without the grass shadow at the walls' foot"""
    a = np.zeros((96, 80, 4), dtype=np.uint8)
    for y in range(6):
        for x in range(5):
            a[y * 16:y * 16 + 16, x * 16:x * 16 + 16] = np.clip(np.asarray(cell("%s_%d_%d" % (kind, x, y))), 0, 255)
    low = a[73:]
    r, g, b = low[..., 0].astype(int), low[..., 1].astype(int), low[..., 2].astype(int)
    low[(g > r + 20) & (g > b + 10)] = 0                 # any grass green (each stamp's shadow green differs)
    return a


def paste(dst, src, x, y):
    """alpha paste (src's clear pixels leave dst alone)"""
    h, w = src.shape[:2]
    H, W = dst.shape[:2]
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W, x + w), min(H, y + h)
    s = src[y0 - y:y1 - y, x0 - x:x1 - x]
    m = s[..., 3:4] > 0
    dst[y0:y1, x0:x1] = np.where(m, s, dst[y0:y1, x0:x1])


def recolor_roof(u, ramp_light, ramp_dark):
    """the green roof's two planes to new ramps (rows above the eave only: the corners below keep their colour)"""
    out = u.copy()
    roof = out[:73]
    pairs = {(153, 229, 80): ramp_light[1], (106, 190, 48): ramp_light[0], (75, 105, 47): ramp_dark[1], (50, 60, 57): ramp_dark[0]}
    for src, dst in pairs.items():
        m = np.all(roof[..., :3] == src, axis=-1)
        roof[m, :3] = dst
    return out


ROOF = slice(0, 73)          # roof planes, chimney and the brick gable
BEAM = slice(73, 79)         # the timber beam
FLOOR = slice(79, 95)        # the ground floor: log-end posts, brick wall, window, door


def wall_strip(u, w):
    src = u[FLOOR, 41:45]                 # 4 px = one brick rhythm
    return np.concatenate([src] * (-(-w // 4)), axis=1)[:, :w]


def beam_strip(u, w):
    return np.repeat(u[BEAM, 40:41], w, axis=1)


def window(u):
    return u[79:93, 20:41].copy()        # the two-pane window with its frame (21 x 14)


def door(u):
    return u[79:94, 47:65].copy()        # the plank door (18 x 15)


def posts(u):
    return u[73:95, 0:14].copy(), u[73:95, 66:80].copy()      # left / right log ends with the beam's ends


def flowerbox(w):
    b = np.zeros((4, w, 4), dtype=np.uint8)
    b[1:4, :, :3] = (102, 57, 49); b[1:4, :, 3] = 255
    b[1, :, :3] = (143, 86, 59)
    b[3, :, :3] = K
    rng = [(217, 87, 99), (251, 242, 54), (215, 123, 186), (255, 255, 255)]
    for x in range(1, w - 1):
        b[0, x, :3] = rng[(x // 2) % len(rng)] if x % 2 == 1 else (106, 190, 48)
        b[0, x, 3] = 255
    return b


def hanging_sign():
    """the Lion's Pride sign: an iron bracket and a red board with a gold lion (14 x 15)"""
    s = np.zeros((15, 14, 4), dtype=np.uint8)

    def p(x, y, c):
        s[y, x, :3] = c; s[y, x, 3] = 255
    for x in range(0, 13):
        p(x, 0, (89, 86, 82))
    p(13, 0, K); p(3, 1, (89, 86, 82)); p(10, 1, (89, 86, 82))
    for y in range(2, 14):
        for x in range(1, 13):
            p(x, y, K if x in (1, 12) or y in (2, 13) else ((172, 50, 50) if x < 6 else (140, 38, 42)))
    for j, r in enumerate(["..YY....", ".YYYY.Y.", "..YYYYY.", "..YYYY..", ".Y.YY.Y.", "Y..Y..Y."]):
        for i, ch in enumerate(r):
            if ch == "Y":
                p(3 + i, 5 + j, (251, 242, 54))
    return s


def lantern():
    s = np.zeros((7, 5, 4), dtype=np.uint8)
    cols = {"K": K, "Y": (251, 242, 54), "h": (255, 255, 255)}
    for j, r in enumerate([".KKK.", "KYYYK", "KhYhK", "KYYYK", ".KKK.", "..K..", "....."]):
        for i, ch in enumerate(r):
            if ch in cols:
                s[j, i, :3] = cols[ch]; s[j, i, 3] = 255
    return s


def floor(u, w, items):
    """a storey w px wide: log ends at both ends, beam and brick only between them, items [(x, array, y)] on it"""
    left, right = posts(u)
    f = np.zeros((22, w, 4), dtype=np.uint8)
    f[0:6, 14:w - 14] = beam_strip(u, w - 28)
    f[6:22, 14:w - 14] = wall_strip(u, w - 28)
    paste(f, left, 0, 0)
    paste(f, right, w - right.shape[1], 0)
    for x, arr, y in items:
        paste(f, arr, x, y)
    return f


# ------------------------------------------------------------------ the buildings

def inn(cell):
    red, u = unit(cell, "farmhouse"), unit(cell, "house")
    W, H = 144, 128
    img = np.zeros((H, W, 4), dtype=np.uint8)
    roof_y = H - 95 - 20                       # the roof sits on two storeys
    # two gables side by side, split at the valley (x = 72) so neither covers the other, a dark seam where they meet
    VAL = 72
    left = red[ROOF].copy(); left[:, VAL:] = 0
    right = red[ROOF].copy(); right[:, :VAL - 64] = 0
    paste(img, left, 0, roof_y)
    paste(img, right, 64, roof_y)
    for y in range(roof_y, roof_y + 73):
        if img[y, VAL - 1, 3] and img[y, VAL, 3]:
            img[y, VAL, :3] = K
    up = floor(u, W, [])                       # guest rooms upstairs
    for x in (12, 36, 87, 111):
        paste(up, window(u), x, 4)
        paste(up, flowerbox(21), x, 16)
    paste(img, up[0:20], 0, roof_y + 73)
    d = door(u)
    dd = np.concatenate([d, d[:, ::-1]], axis=1)
    gf = floor(u, W, [(18, window(u), 6), (105, window(u), 6), (54, dd, 6), (48, lantern(), 8), (93, lantern(), 8)])
    paste(img, gf, 0, roof_y + 93)
    paste(img, hanging_sign(), 65, roof_y + 76)
    return img


def smithy(cell):
    u = unit(cell, "stonehouse")
    img = np.zeros((96, 80, 4), dtype=np.uint8)
    paste(img, u[0:79], 0, 0)
    inside = floor(u, 80, [])
    for y in range(6, 22):
        for x in range(14, 66):
            inside[y, x, :3] = (45, 32, 36) if y > 8 else (34, 24, 30); inside[y, x, 3] = 255
    for y in range(9, 21):                     # back wall bricks, in shadow
        for x in range(14, 66):
            if (y % 4 == 0) or ((x + (y // 4) * 2) % 6 == 0):
                inside[y, x, :3] = (58, 42, 44)
    for y in range(12, 21):                    # the forge's mouth
        for x in range(18, 30):
            d = abs(x - 23.5) + (20 - y) * 0.6
            if d < 7:
                inside[y, x, :3] = (255, 246, 200) if d < 2 else (251, 242, 54) if d < 3.5 else (223, 113, 38) if d < 5 else (172, 50, 50)
    for x, h in ((40, 6), (46, 5), (52, 7), (58, 4)):          # tongs and hammers on hooks
        inside[10:10 + h, x, :3] = (155, 173, 183)
        inside[10 + h, x - 1:x + 2, :3] = (105, 106, 106)
    for x in (13, 39, 66):                     # posts
        inside[6:22, x:x + 2, :3] = (102, 57, 49); inside[6:22, x, :3] = (143, 86, 59); inside[6:22, x + 2, :3] = K
    paste(img, inside, 0, 73)
    return img


def cottage(cell):
    straw_l = [(196, 152, 72), (232, 196, 108)]
    straw_d = [(132, 96, 44), (164, 124, 58)]
    img = recolor_roof(unit(cell, "house"), straw_l, straw_d)
    rng = np.random.default_rng(4)             # thatch: straw strokes break up the plank lines
    for y in range(0, 73):
        for x in range(0, 80):
            c = tuple(int(v) for v in img[y, x, :3])
            if c in (straw_l[0], straw_l[1], straw_d[0], straw_d[1]) and rng.random() < 0.22:
                ramp = straw_l if c in straw_l else straw_d
                img[y, x, :3] = ramp[0] if rng.random() < 0.5 else ramp[1]
    paste(img, flowerbox(21), 20, 91)
    return img


def stable(cell):
    u = unit(cell, "bbhouse")
    img = np.zeros((96, 80, 4), dtype=np.uint8)
    paste(img, u[0:79], 0, 0)
    f = floor(u, 80, [])
    planks = [(102, 57, 49), (143, 86, 59)]
    for y in range(7, 22):
        for x in range(16, 64):
            f[y, x, :3] = planks[1] if (x // 4) % 2 == 0 else planks[0]
    for k in range(15):
        for x0 in (16, 40):
            f[7 + k, x0 + int(k * 23 / 14), :3] = (69, 40, 60); f[7 + k, x0 + 23 - int(k * 23 / 14), :3] = (69, 40, 60)
    f[7:22, 16, :3] = K; f[7:22, 63, :3] = K; f[7:22, 39:41, :3] = K; f[7, 16:64, :3] = K
    paste(img, f, 0, 73)
    return img


# ------------------------------------------------------------------ the well (DawnBringer 16, placed pixel by pixel)
DB = {"K": (20, 12, 28), "P": (68, 36, 52), "N": (48, 52, 109), "G": (78, 74, 78), "B": (133, 76, 48),
      "R": (208, 70, 72), "U": (89, 125, 206), "O": (210, 125, 44), "S": (133, 149, 161), "Y": (218, 212, 94),
      "D": (40, 26, 44), "s": (176, 186, 196), "m": (96, 100, 112), "r": (160, 50, 56), "p": (96, 32, 44)}


def well_rows():
    W, H = 32, 40
    g = [["."] * W for _ in range(H)]

    def put(x, y, c):
        if 0 <= x < W and 0 <= y < H:
            g[y][x] = c
    cx, cy, rx, ry = 15.5, 30.0, 12.5, 6.0
    for y in range(H):                         # the curb: stones round dark water
        for x in range(W):
            if ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1:
                if ((x - cx) / (rx - 3.2)) ** 2 + ((y - cy + 1.2) / (ry - 2.4)) ** 2 <= 1:
                    put(x, y, "N" if y < cy - 1 else "U" if (x + y) % 5 == 0 else "N")
                else:
                    put(x, y, "s" if (x < cx - 3 or y < cy - 3) else "m")
    for x in range(4, 28):                     # the curb's front face, in courses
        top = None
        for y in range(H):
            if g[y][x] in "sm" and y > cy:
                top = y
        if top is None:
            continue
        for y in range(top + 1, min(H - 1, top + 5)):
            put(x, y, "m" if (x // 4 + y // 2) % 2 else "s")
            if (y - top) == 2 or (x % 4 == 0 and (y - top) in (1, 3)):
                put(x, y, "G")
    for x, y in ((8, 26), (13, 25), (19, 25), (24, 27), (6, 30), (25, 31), (11, 35), (20, 35)):
        put(x, y, "G")
    for x in (5, 26):                          # posts
        for y in range(9, 31):
            put(x, y, "B"); put(x + 1, y, "P" if x > 15 else "O")
    for x in range(5, 28):                     # crossbar, crank, rope, bucket
        put(x, 13, "B"); put(x, 14, "P")
    put(28, 13, "S"); put(29, 13, "S"); put(29, 14, "S"); put(29, 15, "K")
    for y in range(15, 22):
        put(15, y, "Y" if y % 2 else "O")
    for y in range(22, 26):
        for x in range(13, 18):
            put(x, y, "B" if x < 17 else "P")
    for x in range(13, 18):
        put(x, 22, "S")
    for y in range(2, 10):                     # the roof: shingle rows, staggered, lit from the left
        a, b = 15 - (y - 2) * 2 - 2, 16 + (y - 2) * 2 + 2
        for x in range(max(0, a), min(W, b + 1)):
            lit = x < 16
            c = "R" if lit else "r"
            if y % 2 == 0 or (x + (y // 2) * 2) % 4 == 0:
                c = "P" if lit else "p"
            put(x, y, c)
    for x in range(W):
        if g[9][x] in "RPrp":
            put(x, 10, "D")
    put(15, 1, "R"); put(16, 1, "P"); put(15, 0, "Y")
    add = []
    for y in range(H):                         # black outline round the shape
        for x in range(W):
            if g[y][x] != ".":
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                xx, yy = x + dx, y + dy
                if 0 <= xx < W and 0 <= yy < H and g[yy][xx] != ".":
                    add.append((x, y)); break
    for x, y in add:
        g[y][x] = "K"
    return g


def well(cell):
    img = np.zeros((48, 32, 4), dtype=np.uint8)            # 2 x 3 tiles, the well standing on the bottom edge
    for y, row in enumerate(well_rows()):
        for x, ch in enumerate(row):
            if ch != ".":
                img[8 + y, x, :3] = DB[ch]; img[8 + y, x, 3] = 255
    return img


BUILD = {"inn": inn, "smithy": smithy, "cottage": cottage, "stable": stable, "well": well}


def images(cell):
    """kind -> the whole stamp (H, W, 4) uint8"""
    return {k: fn(cell) for k, fn in BUILD.items()}


def tiles(cell):
    """[(name_x_y, 16 x 16 RGBA Image)] for every new stamp, row by row"""
    out = []
    for kind, img in images(cell).items():
        w, h = SIZE[kind]
        assert img.shape[:2] == (h * 16, w * 16), (kind, img.shape)
        for y in range(h):
            for x in range(w):
                out.append(("%s_%d_%d" % (kind, x, y), Image.fromarray(img[y * 16:y * 16 + 16, x * 16:x * 16 + 16], "RGBA")))
    return out

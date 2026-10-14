"""Azeromon interiors (the world art pass, indoors): hand-shaded furniture for the atlas, wall dressing, and the room
painter - plank floors, timbered back walls with wainscot, wall thickness round the room, a doormat at the door,
light from the windows by day and from hearth, candles and sconces at night.

Used by the look mockup first (dev/art/casc/azeromon_looks); the ground baker takes it over once the look is agreed.
Rooms use the map rows: W wall (the top two rows are the back wall), f floor, r the doormat, b bed, d dresser,
t table, p pot, c counter, C chest, L stairs."""
import math

import numpy as np

from azeromon_props import (Spr, H, WOOD, DWOOD, STONE, FIRE, PAPER, RED, TEAL, BONE, GLASS, IRON, LEAF, CANVAS)

PLANK = [(78, 48, 32), (132, 86, 52), (146, 96, 58), (158, 104, 62), (170, 114, 68), (190, 134, 82)]
PLASTER = [(150, 134, 108), (196, 180, 148), (214, 200, 166), (228, 216, 184)]
CLOTH = [(60, 40, 70), (96, 60, 110), (132, 86, 148), (170, 120, 182)]
QUILT = [(70, 24, 28), (128, 40, 40), (176, 66, 56), (214, 112, 88)]
BLUE = [(26, 40, 74), (44, 66, 116), (70, 100, 160), (120, 150, 204)]
GOLD = [(110, 74, 20), (176, 128, 36), (224, 182, 64), (250, 228, 130)]


# ------------------------------------------------------------------------------------------- furniture (atlas)

def counter():
    """a stretch of wooden bar: repeats sideways into one long counter"""
    s = Spr(16, 16)
    s.rect(0, 4, 15, 6, WOOD[4]); s.rect(0, 4, 15, 4, (226, 178, 118)); s.rect(0, 7, 15, 7, WOOD[1])   # top
    s.rect(0, 8, 15, 15, WOOD[2])
    for x in (0, 8):
        s.rect(x + 1, 9, x + 6, 14, WOOD[3]); s.rect(x + 1, 9, x + 6, 9, WOOD[4]); s.rect(x + 6, 10, x + 6, 14, WOOD[1])
    s.rect(0, 15, 15, 15, WOOD[0])
    s.put(3, 5, (240, 230, 210)); s.put(4, 5, (200, 190, 170)); s.put(12, 5, GOLD[2])                  # a cup, a coin
    return s


def bed():
    s = Spr(16, 16)
    s.rect(1, 0, 14, 3, WOOD[3]); s.rect(1, 0, 14, 0, WOOD[4]); s.rect(1, 3, 14, 3, WOOD[1])           # headboard
    s.rect(2, 3, 13, 6, (240, 236, 226)); s.rect(2, 6, 13, 6, (200, 196, 190)); s.put(3, 4, (255, 255, 250))  # pillow
    for y in range(7, 15):
        for x in range(1, 15):
            q = ((x // 4) + (y // 4)) % 2
            c = QUILT[2] if q else BLUE[2]
            if y == 7: c = QUILT[3] if q else BLUE[3]
            if x == 14 or y == 14: c = QUILT[1] if q else BLUE[1]
            s.put(x, y, c)
    s.rect(1, 15, 14, 15, WOOD[1])
    s.outline()
    return s


def table():
    s = Spr(16, 16)
    s.rect(1, 4, 14, 10, WOOD[3]); s.rect(1, 4, 14, 4, WOOD[4]); s.rect(1, 10, 14, 10, WOOD[1])       # top
    s.rect(5, 4, 10, 10, (226, 218, 196)); s.rect(5, 10, 10, 10, (180, 170, 150))                      # runner
    s.rect(2, 11, 3, 15, WOOD[2]); s.rect(12, 11, 13, 15, WOOD[1])                                      # legs
    s.rect(7, 2, 8, 6, (246, 240, 220)); s.put(7, 1, FIRE[3]); s.put(7, 0, FIRE[4]); s.put(8, 6, (200, 190, 170))  # candle
    s.outline()
    return s


def dresser():
    s = Spr(16, 16)
    s.rect(1, 2, 14, 15, WOOD[2]); s.rect(1, 2, 14, 2, WOOD[4]); s.rect(14, 3, 14, 15, WOOD[1])
    for y in (4, 8, 12):
        s.rect(2, y, 13, y + 2, WOOD[3]); s.rect(2, y + 2, 13, y + 2, WOOD[1])
        s.put(5, y + 1, GOLD[2]); s.put(10, y + 1, GOLD[2])
    s.rect(3, 0, 5, 1, BLUE[2]); s.put(4, 0, BLUE[3])                                                   # a jug on top
    s.outline()
    return s


def pot():
    s = Spr(16, 16)
    s.ellipse(8, 11.5, 5.5, 4.5, lambda x, y: (176, 96, 56) if x < 8 else (140, 72, 44))
    s.rect(5, 6, 10, 7, (196, 114, 66)); s.rect(5, 6, 10, 6, (220, 140, 86))
    for x, y, c in ((6, 4, LEAF[3]), (7, 3, LEAF[2]), (8, 2, LEAF[3]), (9, 3, LEAF[2]), (10, 4, LEAF[3]),
                    (5, 3, LEAF[2]), (11, 3, LEAF[2]), (8, 4, LEAF[1]), (7, 5, LEAF[1]), (9, 5, LEAF[1]), (8, 1, LEAF[4])):
        s.put(x, y, c)
    s.outline()
    return s


def stairs():
    """steps going down into the floor: a dark opening, lit treads that fade into the dark"""
    s = Spr(16, 16)
    s.rect(0, 0, 15, 15, (24, 16, 14))
    for i, y in enumerate((1, 5, 9, 13)):
        k = 1 - i * 0.22
        tread = tuple(int(v * k) for v in WOOD[3])
        riser = tuple(int(v * k) for v in WOOD[1])
        s.rect(1 + i, y, 14 - i, y + 1, tread)
        s.rect(1 + i, y + 2, 14 - i, y + 3, riser)
    s.rect(0, 0, 0, 15, DWOOD[2]); s.rect(15, 0, 15, 15, DWOOD[2]); s.rect(0, 0, 15, 0, DWOOD[3])
    return s


FURNITURE = {"counter": counter, "bed": bed, "table": table, "dresser": dresser, "pot": pot, "stairs": stairs}


# ------------------------------------------------------------------------------------------- wall dressing (baked)

def window():
    s = Spr(14, 14)
    s.rect(0, 0, 13, 13, WOOD[1]); s.rect(1, 1, 12, 11, BLUE[3])
    for y in range(1, 12):                                       # sky light, brighter at the top
        for x in range(1, 13):
            s.put(x, y, (190, 220, 240) if y < 5 else (160, 200, 232) if y < 9 else (136, 180, 220))
    s.rect(6, 1, 7, 11, WOOD[2]); s.rect(1, 6, 12, 6, WOOD[2])
    s.put(2, 2, (240, 250, 255)); s.put(3, 2, (240, 250, 255)); s.put(2, 3, (240, 250, 255))
    s.rect(0, 12, 13, 13, WOOD[3]); s.rect(0, 12, 13, 12, WOOD[4])     # sill
    return s


def window_night(s):
    out = Spr(s.w, s.h)
    for y in range(s.h):
        for x in range(s.w):
            c = s.get(x, y)
            if c is not None and c[2] > 150 and c[2] > c[0] + 30:
                c = (34, 44, 82) if y < 6 else (26, 34, 64)
            out.p[y][x] = c
    return out


def hearth():
    s = Spr(32, 32)
    def stone(x, y):
        c = STONE[2] if (x // 5 + y // 4) % 2 else STONE[3]
        if y % 4 == 3 or (x + (y // 4) * 3) % 5 == 4: c = STONE[1]
        return c
    s.fill(2, 4, 29, 31, stone)
    s.rect(0, 2, 31, 4, WOOD[3]); s.rect(0, 2, 31, 2, WOOD[4]); s.rect(0, 5, 31, 5, WOOD[1])           # mantel
    s.ellipse(16, 25, 9, 9, lambda x, y: (22, 12, 10))
    for y in range(17, 32):
        for x in range(7, 26):
            if s.get(x, y) == (22, 12, 10):
                d = abs(x - 16) * 0.9 + max(0, 29 - y) * 0.7
                s.put(x, y, FIRE[4] if d < 2 else FIRE[3] if d < 4 else FIRE[2] if d < 6.5 else FIRE[1] if d < 9 else (22, 12, 10))
    s.rect(8, 30, 24, 31, (60, 36, 26)); s.rect(10, 29, 22, 29, (90, 50, 30))                         # logs
    s.rect(6, 0, 7, 1, (246, 240, 220)); s.put(6, -1, FIRE[3])                                          # candles on the mantel
    s.rect(24, 0, 25, 1, (246, 240, 220))
    s.put(14, 1, BLUE[2]); s.put(15, 1, BLUE[2]); s.put(16, 1, BLUE[3]); s.put(18, 1, GOLD[2])
    s.outline(0.45)
    return s


def shelf():
    s = Spr(16, 14)
    for y0 in (5, 12):
        s.rect(0, y0, 15, y0 + 1, WOOD[3]); s.rect(0, y0 + 1, 15, y0 + 1, WOOD[1])
    cols = [RED, TEAL, GOLD, BLUE, LEAF, RED, CLOTH]
    for i, x in enumerate((1, 4, 6, 9, 12)):
        c = cols[i % len(cols)]
        s.rect(x, 1, x + 1, 4, c[2]); s.put(x, 1, c[3]); s.put(x + 1, 4, c[1]); s.put(x, 0, (90, 70, 50))
    for i, x in enumerate((1, 3, 5, 8, 10, 13)):                     # books
        c = cols[(i + 2) % len(cols)]
        s.rect(x, 8 - (i % 2), x + 1, 11, c[2]); s.rect(x + 1, 8 - (i % 2), x + 1, 11, c[1])
    s.outline(0.45)
    return s


def banner_lion():
    s = Spr(14, 22)
    s.rect(0, 0, 13, 1, WOOD[2])
    s.fill(1, 2, 12, 17, lambda x, y: RED[2] if x < 9 else RED[1])
    s.poly([(1, 17.5), (12.9, 17.5), (12.9, 21.5), (7, 18.5), (1, 21.5)], lambda x, y: RED[1])
    for x, y in ((5, 6), (6, 6), (7, 6), (8, 6), (4, 7), (5, 7), (6, 7), (7, 7), (8, 7), (9, 7), (5, 8), (6, 8), (7, 8),
                 (8, 8), (6, 9), (7, 9), (5, 10), (8, 10), (5, 11), (8, 11), (4, 12), (9, 12)):
        s.put(x, y, GOLD[2])                                         # the lion (a rampant shape)
    s.put(6, 5, GOLD[3]); s.put(7, 5, GOLD[3])
    s.rect(1, 3, 12, 3, GOLD[1]); s.rect(1, 15, 12, 15, GOLD[1])
    s.outline(0.45)
    return s


def stag_head():
    s = Spr(18, 14)
    s.rect(6, 9, 11, 13, WOOD[3]); s.rect(6, 9, 11, 9, WOOD[4])                                       # plaque
    s.ellipse(9, 8, 3.2, 3.6, lambda x, y: (140, 96, 60) if x < 9 else (112, 74, 46))
    s.rect(8, 10, 9, 11, (96, 64, 40)); s.put(8, 7, (20, 14, 12)); s.put(10, 7, (20, 14, 12))
    for d in (-1, 1):                                                # antlers
        cx = 9 + d * 2
        for k in range(5):
            s.put(cx + d * k, 4 - k // 2, BONE[2])
        s.put(cx + d * 2, 1, BONE[2]); s.put(cx + d * 4, 0, BONE[3]); s.put(cx + d * 1, 1, BONE[1])
    s.outline(0.45)
    return s


def bows():
    s = Spr(16, 16)
    for d in (-1, 1):
        for k in range(14):
            t = k / 13
            x = 8 + d * (6 - 12 * t)
            y = 1 + 13 * t
            s.put(x + d * math.sin(t * math.pi) * 2, y, WOOD[3])
        s.line(8 + d * 6, 1, 8 - d * 6, 14, (220, 214, 196))
    s.put(7, 7, IRON[3]); s.put(8, 7, IRON[3]); s.put(7, 8, IRON[2]); s.put(8, 8, IRON[2])
    s.outline(0.45)
    return s


def pelt():
    s = Spr(16, 14)
    s.poly([(2, 1), (14, 1), (15, 6), (13, 13), (8, 11), (3, 13), (1, 6)],
           lambda x, y: (150, 116, 80) if (x + y) % 5 else (126, 96, 66))
    s.ellipse(8, 6, 3, 3, lambda x, y: (176, 140, 100))
    s.outline(0.45)
    return s


def painting():
    s = Spr(16, 12)
    s.rect(0, 0, 15, 11, GOLD[1]); s.rect(0, 0, 15, 0, GOLD[2]); s.rect(1, 1, 14, 10, (120, 170, 210))
    s.poly([(1, 10.5), (6, 4), (10, 8), (12, 6), (14.9, 10.5)], lambda x, y: (70, 120, 70) if y > 7 else (110, 150, 90))
    s.put(11, 2, (250, 240, 180)); s.put(12, 2, (250, 240, 180))
    s.outline(0.45)
    return s


def sconce():
    s = Spr(6, 10)
    s.rect(1, 6, 4, 9, IRON[2]); s.rect(1, 6, 4, 6, IRON[3])
    s.rect(2, 3, 3, 5, (246, 240, 220)); s.put(2, 2, FIRE[3]); s.put(2, 1, FIRE[4]); s.put(3, 2, FIRE[2])
    s.outline(0.45)
    return s


def rug(w, h, base, edge):
    s = Spr(w, h)
    for y in range(h):
        for x in range(w):
            c = base[2]
            if x in (1, w - 2) or y in (1, h - 2): c = edge[2]
            elif x in (2, w - 3) or y in (2, h - 3): c = base[1]
            elif (x + y) % 6 == 0 and 3 < x < w - 4 and 3 < y < h - 4: c = edge[3]
            if x == 0 or x == w - 1: c = base[1] if y % 2 else (226, 214, 180)                        # tassels
            s.put(x, y, c)
    return s


def doormat():
    s = Spr(14, 9)
    s.fill(0, 0, 13, 8, lambda x, y: (150, 108, 58) if (x + y) % 3 else (120, 84, 44))
    s.rect(0, 0, 13, 0, (176, 132, 76)); s.rect(0, 8, 13, 8, (100, 68, 36))
    return s


DECOR = {"window": window, "hearth": hearth, "shelf": shelf, "banner": banner_lion, "stag": stag_head,
         "bows": bows, "pelt": pelt, "painting": painting, "sconce": sconce}

# per room: wall dressing at pixel positions inside the room (x from the room's left, y from its top), rugs on the
# floor, and lights (hearth, candles, sconces: x, y, radius, flickers)
DRESSING = {
    "home": {"wall": [("window", 18, 6), ("hearth", 64, 0), ("painting", 112, 7), ("window", 134, 6)],
             "rugs": [(40, 58, 52, 30, CLOTH, GOLD)],
             "lights": [(80, 26, 46, 1), (56, 66, 22, 1)], "shafts": [(18, 6, 14), (134, 6, 14)]},
    "lab": {"wall": [("window", 6, 6), ("bows", 40, 6), ("stag", 71, 4), ("pelt", 102, 6), ("window", 140, 6)],
            "rugs": [(36, 52, 88, 38, QUILT, GOLD)],
            "lights": [(30, 14, 30, 1), (130, 14, 30, 1)], "sconces": [(28, 10), (128, 10)],
            "shafts": [(6, 6, 14), (140, 6, 14)]},
    "post": {"wall": [("shelf", 4, 12), ("banner", 34, 6), ("shelf", 108, 12), ("banner", 126, 6),
                      ("window", 140, 6)],
             "rugs": [(64, 64, 32, 48, QUILT, GOLD)],
             "lights": [(62, 14, 30, 1), (98, 14, 30, 1)], "sconces": [(60, 10), (96, 10)],
             "shafts": [(140, 6, 14)]},
}


DRESSING["hall"] = {"wall": [("window", 6, 6), ("painting", 40, 7), ("shelf", 72, 12), ("painting", 104, 7),
                             ("window", 140, 6)],
                    "rugs": [(36, 52, 88, 38, BLUE, GOLD)],
                    "lights": [(30, 14, 30, 1), (130, 14, 30, 1)], "sconces": [(28, 10), (128, 10)],
                    "shafts": [(6, 6, 14), (140, 6, 14)]}
# rooms that share a dressing (every interior is the same 10 x 8 room)
DRESSING_OF = {"saldean": "home", "mistmantle": "home", "bootybayinn": "post", "darkshireinn": "post",
               "sentinelinn": "post", "bbhall": "hall"}


def dressing(map_id):
    return DRESSING.get(map_id) or DRESSING.get(DRESSING_OF.get(map_id, "hall"))


# ------------------------------------------------------------------------------------------- the room painter

def _img(s):
    a = np.zeros((s.h, s.w, 4))
    for y in range(s.h):
        for x in range(s.w):
            c = s.p[y][x]
            if c is not None:
                a[y, x, :3] = c[:3]
                a[y, x, 3] = c[3] if len(c) == 4 else 255
    return a


def _blit(dst, src, x, y):
    H_, W_ = dst.shape[:2]
    h, w = src.shape[:2]
    x0, y0, x1, y1 = max(0, x), max(0, y), min(W_, x + w), min(H_, y + h)
    if x0 >= x1 or y0 >= y1:
        return
    s = src[y0 - y:y1 - y, x0 - x:x1 - x]
    a = s[..., 3:4] / 255.0
    dst[y0:y1, x0:x1] = dst[y0:y1, x0:x1] * (1 - a) + s[..., :3] * a


def floor(W, H_, seed=0):
    """horizontal planks 4 px tall, staggered, each its own tone, with grain, knots and a lit top edge"""
    img = np.zeros((H_, W, 3))
    for y in range(H_):
        row = y // 4
        off = int(H(row, 7, seed) * 40)
        for x in range(W):
            xx = x + off
            seg = xx // 40 if row % 2 else (xx + 20) // 40
            start = seg * 40 - (0 if row % 2 else 20)
            tone = PLANK[2 + int(H(seg, row, seed + 1) * 3)]
            c = np.array(tone, dtype=np.float64)
            if y % 4 == 3:
                c = np.array(PLANK[0], dtype=np.float64)                      # the seam between rows
            elif xx - start == 0:
                c = np.array(PLANK[1], dtype=np.float64)                      # a plank's end
            else:
                if y % 4 == 0:
                    c = c * 1.07 + 4                                          # lit top edge
                if H(xx // 3, y, seed + 2) < 0.12:
                    c = c * 0.86                                              # grain
                if H(seg * 7 + row, 3, seed + 4) < 0.25 and abs(xx - start - 18) < 2 and y % 4 == 1:
                    c = np.array(PLANK[1], dtype=np.float64)                  # a knot
            img[y, x] = c
    return img


def back_wall(W, top, height=32, seed=0):
    """the back wall, `height` px: ceiling beam, timbered plaster, chair rail, wainscot, skirting"""
    img = np.zeros((height, W, 3))
    for y in range(height):
        for x in range(W):
            if y < 3:
                c = DWOOD[1] if y < 2 else DWOOD[3]
            elif y < 18:
                c = PLASTER[2]
                n = H(x // 2, y // 2, seed)
                if n < 0.18: c = PLASTER[1]
                elif n > 0.9: c = PLASTER[3]
                if x % 48 in (0, 1, 2, 3):                                    # timber posts
                    c = WOOD[2] if x % 48 else WOOD[3]
                    if x % 48 == 3: c = WOOD[1]
                if y == 17: c = PLASTER[0]
            elif y < 20:
                c = WOOD[4] if y == 18 else WOOD[1]
            elif y < 30:
                c = WOOD[2] if (x // 6) % 2 else (116, 72, 42)
                if x % 6 == 5: c = WOOD[1]
                if y == 20: c = WOOD[3]
            else:
                c = DWOOD[1]
            img[y, x] = c
    return img


def contact(img, t, x0, y0, joined=False):
    """a soft oval of shadow under a sprite's foot (its lowest row), spilling past its tile; `joined` (a counter's
    stretch) shades the whole width so neighbouring pieces read as one"""
    H_, W = img.shape[:2]
    a = t[..., 3] > 0
    rows_ = np.where(a.any(1))[0]
    if not len(rows_):
        return
    by = rows_[-1]
    cols = np.where(a[by])[0]
    cx = x0 + (cols[0] + cols[-1]) / 2 + 0.5
    cy = y0 + by + 1
    rx = (cols[-1] - cols[0]) / 2 + (8 if joined else 3.5)
    for yy in range(int(cy) - 3, int(cy) + 3):
        for xx in range(int(cx - rx) - 1, int(cx + rx) + 2):
            if not (0 <= xx < W and 0 <= yy < H_):
                continue
            d = (((xx + 0.5 - cx) / rx) ** 2 if not joined else 0) + ((yy + 0.5 - cy) / 2.6) ** 2
            if d <= 1:
                k = 0.6 if d < 0.45 else 0.78
                img[yy, xx] = img[yy, xx] * k + np.array([20, 12, 10]) * (1 - k) * 0.5


def sun_overlay(W, H_, shafts, floor_span):
    """the sun through the windows as light to add over everything (furniture and people too): a faint beam from the
    window's foot, then a bright patch where it lands (down and a little right), dithered edges. RGB, added."""
    out = np.zeros((H_, W, 3))
    fy0, fy1, rx0, rx1 = floor_span
    sun = np.array([255, 238, 196], dtype=np.float64)
    for x, y, sw in shafts:
        top = y + 13
        land = fy0 + 10
        for yy in range(top, min(fy1 - 2, land + 26)):
            d = yy - top
            xa = x + 1 + d * 0.3
            k = 0.07 if yy < land else 0.2
            if yy >= land + 22:
                k = 0.2 * (land + 26 - yy) / 5
            for xx in range(int(xa) - 1, int(xa + sw + 2)):
                if not (rx0 + 1 <= xx < rx1 - 1):
                    continue
                edge = xx < xa or xx > xa + sw
                if edge and (xx + yy) % 2:
                    continue
                out[yy, xx] = np.maximum(out[yy, xx], sun * k * (0.5 if edge else 1))
    return np.clip(np.round(out), 0, 255).astype(np.uint8)


FIRE_FRAMES = 8


def hearth_fire():
    """the hearth's flames as FIRE_FRAMES frames (RGBA, the size of its fire mouth) and where they sit in the hearth
    sprite: tongues rise and fall per column, the core flickers"""
    base = hearth()
    mouth = [(x, y) for y in range(17, 30) for x in range(7, 26)
             if ((x + 0.5 - 16) / 9) ** 2 + ((y + 0.5 - 25) / 9) ** 2 <= 1]
    x0, y0 = 7, 16
    frames = []
    for f in range(FIRE_FRAMES):
        fr = np.zeros((14, 19, 4))
        ph = 2 * math.pi * f / FIRE_FRAMES
        for x, y in mouth:
            lift = 2.2 * math.sin(ph + x * 1.3) + 1.4 * math.sin(2 * ph - x * 0.7) + (H(x, f, 21) - 0.5) * 1.6
            d = abs(x - 16) * 0.9 + max(0, 29 - y) * 0.7 - lift * 0.55
            c = FIRE[4] if d < 2 else FIRE[3] if d < 4 else FIRE[2] if d < 6.5 else FIRE[1] if d < 9 else (22, 12, 10)
            fr[y - y0, x - x0, :3] = c
            fr[y - y0, x - x0, 3] = 255
        for x in range(10, 23):                                     # the logs stay put
            if (x, 29) in mouth:
                fr[29 - y0, x - x0] = (90, 50, 30, 255)
        frames.append(fr)
    return frames, (x0, y0)


def bake_room(m, atlas, furn, period="day"):
    """the room as a picture with 16 px of wall thickness all round. m: compiled map (w, h, rows, over...)
    Returns (picture RGB float (H, W, 3), lights [(x, y, r, flick)], shafts [(x, y, w)] in picture pixels)."""
    w, h, rows = m["w"], m["h"], m["rows"]
    M = 16
    W, Ht = w * 16 + 2 * M, h * 16 + 2 * M
    img = np.zeros((Ht, W, 3))
    img[:] = (16, 12, 14)
    room_x0, room_y0 = M, M
    # back wall: rows with W at the top
    wall_rows = 0
    while wall_rows < h and rows[wall_rows].strip("W") == "":
        wall_rows += 1
    floor_y0 = room_y0 + wall_rows * 16
    floor_h = (h - wall_rows - 1) * 16
    img[floor_y0:floor_y0 + floor_h, room_x0:room_x0 + w * 16] = floor(w * 16, floor_h, seed=len(m["id"]))
    img[room_y0:floor_y0, room_x0:room_x0 + w * 16] = back_wall(w * 16, 0, wall_rows * 16, seed=3)
    dr = dressing(m["id"])
    # rugs on the floor
    for x, y, rw, rh, base, edge in dr.get("rugs", []):
        _blit(img, _img(rug(rw, rh, base, edge)), room_x0 + x, room_y0 + y)
    # the doormat and the front wall (its top, seen from above), with the door gap
    fy = room_y0 + (h - 1) * 16
    for x in range(w):
        ch = rows[h - 1][x]
        px = room_x0 + x * 16
        if ch == "r":
            img[fy:fy + 16, px:px + 16] = floor(16, 16, seed=9)
            _blit(img, _img(doormat()), px + 1, fy + 2)
            img[fy:fy + 16, px - 2:px] = WOOD[1]
            img[fy:fy + 16, px + 16:px + 18] = WOOD[1]
        else:
            img[fy:fy + 6, px:px + 16] = DWOOD[2]
            img[fy, px:px + 16] = DWOOD[3]
            img[fy + 6:fy + 16, px:px + 16] = (16, 12, 14)
    # side walls: a thickness of dark wood beside the room, lit along its inner edge
    for side, x0 in (("l", room_x0 - 6), ("r", room_x0 + w * 16)):
        img[room_y0:fy + 6, x0:x0 + 6] = DWOOD[2]
        img[room_y0:fy + 6, (x0 + 5) if side == "l" else x0] = DWOOD[3]
    img[room_y0 - 6:room_y0, room_x0 - 6:room_x0 + w * 16 + 6] = DWOOD[2]
    img[room_y0 - 1, room_x0 - 6:room_x0 + w * 16 + 6] = DWOOD[3]
    # ambient occlusion: the floor darkens toward the walls
    for k, f in ((0, 0.62), (1, 0.72), (2, 0.82), (3, 0.9)):
        img[floor_y0 + k, room_x0:room_x0 + w * 16] *= f
        img[floor_y0:fy, room_x0 + k] *= f
        img[floor_y0:fy, room_x0 + w * 16 - 1 - k] *= f
        img[fy - 1 - k, room_x0:room_x0 + w * 16] *= (f + 1) / 2
    # wall dressing
    win = _img(window())
    win_n = _img(window_night(window()))
    for kind, x, y in dr.get("wall", []):
        spr = (win_n if period != "day" else win) if kind == "window" else _img(DECOR[kind]())
        _blit(img, spr, room_x0 + x, room_y0 + y)
    for x, y in dr.get("sconces", []):
        _blit(img, _img(sconce()), room_x0 + x, room_y0 + y)
    # furniture stands in a soft pool of shadow under its foot (the game draws the furniture itself on top)
    for y in range(h):
        for x in range(w):
            o = m["over"][y * w + x]
            if o in furn or o in ("chest", "stairs", "sign"):
                t = furn[o] if o in furn else atlas.tile(o)
                if t is not None:
                    contact(img, t, room_x0 + x * 16, room_y0 + y * 16, joined=(o == "counter"))
    lights = [(room_x0 + x, room_y0 + y, r, f) for x, y, r, f in dr.get("lights", [])]
    shafts = [(room_x0 + x, room_y0 + y, sw) for x, y, sw in dr.get("shafts", [])]
    m["_fires"] = [(room_x0 + x, room_y0 + y) for kind, x, y in dr.get("wall", []) if kind == "hearth"]
    return img, lights, shafts, (floor_y0, fy, room_x0, room_x0 + w * 16)


def light_room(img, lights, shafts, floor_span, period):
    """day: sun through the windows (a bright patch on the floor and a faint shaft); evening: the room darkens to
    warm pools round the hearth, candles and sconces"""
    out = img.copy()
    H_, W = out.shape[:2]
    ys, xs = np.mgrid[0:H_, 0:W]
    fy0, fy1, rx0, rx1 = floor_span
    if period == "day":
        sun = np.array([255, 238, 196], dtype=np.float64)
        for x, y, sw in shafts:
            # a faint beam from the window's foot, then a bright patch where it lands on the planks (down and right:
            # the light comes from the top left); dithered edges
            top = y + 13
            land = fy0 + 10
            for yy in range(top, min(fy1 - 2, land + 26)):
                d = yy - top
                xa = x + 1 + d * 0.3
                k = 0.10 if yy < land else 0.30
                if yy >= land + 22:
                    k = 0.30 * (land + 26 - yy) / 5
                for xx in range(int(xa) - 1, int(xa + sw + 2)):
                    if not (rx0 + 1 <= xx < rx1 - 1):
                        continue
                    edge = xx < xa or xx > xa + sw
                    if edge and (xx + yy) % 2:
                        continue
                    kk = k * (0.5 if edge else 1)
                    out[yy, xx] = out[yy, xx] + (sun - out[yy, xx]) * kk
        return np.clip(out, 0, 255)
    dark = np.array((112, 96, 120) if period == "night" else (170, 140, 140), dtype=np.float64)
    warm = np.array((255, 222, 168), dtype=np.float64)
    lm = np.zeros((H_, W, 3))
    lm[:] = dark
    for k, f in ((1, 0.25), (0.8, 0.5), (0.6, 0.75), (0.4, 1)):
        for x, y, r, flick in lights:
            inside = (xs - x) ** 2 + (ys - y) ** 2 <= (r * k * 1.6) ** 2
            lm[inside] = dark + (warm - dark) * f
    return np.clip(out * lm / 255, 0, 255)

"""Aftermath art for the atlas (Azeromon 0.32, Aftermath.lua), approved in the "alive" and "Azeroth Remembers" mockups
(dev/art/casc/azeromon_alive: pixels.py STANDARD / bonfire / FLAME, newart.py crop()):

  field_soil            1 x 1  a ploughed field: furrows of turned earth (Westfall's north field, days 3 to 4)
  field_crop_a / _b     1 x 1  the first shoots in rows (days 5 to 6)
  standard              1 x 2  the People's Militia's blue standard on a pole, stone foot
  bonfire               2 x 2  a ring of stones round a log stack (the harvest feast)
  flame_0 .. flame_3    1 x 1  its flames, four frames drawn over the logs
  standard_red          1 x 2  the guild's red standard (Goldshire, a week after a raid kill: Marks.lua)
  pennant               1 x 1  a guild pennant, hung from a lamp post's arm (7 x 12 at the tile's top left)
  pet_murkling          1 x 1  Gurgles, Billy's Murkling: a murloc head out of the water, mouth open (People.lua)

Used by gen_azeromon_art.py: tiles() -> [(name, 16 x 16 RGBA Image)], appended so earlier slots never move."""
import numpy as np
from PIL import Image

from azeromon_props import Spr, H, IRON, RED

SOIL = [(46, 30, 20), (74, 50, 32), (102, 72, 46), (130, 96, 62)]
WHEAT = [(96, 70, 26), (150, 116, 40), (198, 162, 60), (230, 204, 104)]
GREEN = [(20, 56, 30), (34, 96, 46), (60, 140, 62), (110, 184, 86)]
GOLD = [(96, 62, 14), (164, 116, 30), (220, 172, 52), (250, 218, 110), (255, 246, 196)]

# the people sheet's DawnBringer 16 (pixels.py), with the few in-between tones the mockup used
DB = {"K": (20, 12, 28), "B": (133, 76, 48), "Y": (218, 212, 94), "M": (117, 113, 97), "s": (176, 186, 196),
      "m": (96, 100, 112), "O": (210, 125, 44), "o": (240, 160, 70), "w": (255, 250, 220), "R": (208, 70, 72),
      "A": (89, 125, 206), "a": (48, 52, 109)}

STANDARD = [
    "......KYK.......", "......KYK.......", ".....KBKBK......", "..KKKKKBKKKKKK..", "..KBBBBBBBBBBK..",
    "..KKKKKBKKKKKK..", "...KAAAAAAAAK...", "...KAaAAAAAaK...", "...KAAAYYAAAK...", "...KAAYYYYAAK...",
    "...KAAYAYYAAK...", "...KAAAYYYAAK...", "...KAAYAAYAAK...", "...KAAAAAAAaK...", "...KAaAAAAAAK...",
    "...KAAAAAAAAK...", "...KAAAKKAAAK...", "...KAAKBKKAAK...", "...KAK.KBK.AK...", "...KK..KBK..K...",
    ".......KBK......", ".......KBK......", ".......KBK......", ".......KBK......", ".......KBK......",
    ".......KBK......", ".......KBK......", ".....KKKBKKK....", "....KsssmmmmK...", "...KsssssmmmmK..",
    "...KKKKKKKKKKK..", "....MMMMMMMMMM..",
]
BONFIRE = [
    "................................", "................................", "................................",
    "................................", "................................", "................................",
    "................................", "................................", "................................",
    "................................", "................................", "................................",
    "...............KK...............", "..............KBBK..............", ".............KBBBK..............",
    "......KK....KBBKBBK....KK.......", ".....KBBK..KBBK.KBBK..KBBK......", ".....KBBBKKBBK...KBBKKBBBK......",
    "......KBBBBBK.....KBBBBBK.......", ".......KBBBBK.....KBBBBK........", "......KKOKBBBKKKKKBBBKOKK.......",
    "....KKOOOOKBBBBBBBBBKOOOOKK.....", "...KssKOOOOKKKKKKKKKOOOOKssK....", "..KsssmKKOOOOOOOOOOOOOKKsssmK...",
    "..KssmmKmKKKKKKKKKKKKKmKssmmK...", "...KKKKsssmK.KssmK.KsssmKKKK....", "......KssmmK.KsmmK.KssmmK.......",
    ".......KKKK...KKK...KKKK........", "......MMMMMMMMMMMMMMMMMMMM......", "................................",
    "................................", "................................",
]
FLAMES = [
    ["..........Y.....", ".........YY..Y..", "....Y...YoY..YY.", "...YY..YooY.YoY.", "...YoY.YowY.YoY.",
     "..YooYYowwYYooY.", "..YowoYowwoYoY..", "..RYowoowwwooYR.", ".RYoowwwwwwwoYR.", ".ROowwwwwwwwwoOR",
     ".ROowwwwwwwwwoOR", "..ROowwwwwwwoOR.", "...RROoooooORR..", ".....RRRRRRR...."],
    [".......Y........", "......YY.....Y..", "..Y..YoY....YY..", "..YY.YoY...YoY..", "..YoYYowY..YoY..",
     "..YowYowwYYooY..", "...YowoowwYowY..", "..RYowwowwwooYR.", ".RYoowwwwwwwoYR.", ".ROowwwwwwwwwoOR",
     ".ROowwwwwwwwwoOR", "..ROowwwwwwwoOR.", "...RROoooooORR..", ".....RRRRRRR...."],
    [".............Y..", "....Y.......YY..", "...YY...Y..YoY..", "...YoY.YY..YoY..", "..YoY..YoYYowY..",
     "..YowYYowYoowY..", "..YowoowwYowY...", "..RYowwowwooYR..", ".RYoowwwwwwwoYR.", ".ROowwwwwwwwwoOR",
     ".ROowwwwwwwwwoOR", "..ROowwwwwwwoOR.", "...RROoooooORR..", ".....RRRRRRR...."],
    [".........Y......", "..Y.....YY......", "..YY...YoY...Y..", "..YoY..YoY..YY..", "...YoYYowY.YoY..",
     "..YowYoowwYowY..", "..YowoowwwowY...", "..RYowwowwwooYR.", ".RYoowwwwwwwoYR.", ".ROowwwwwwwwwoOR",
     ".ROowwwwwwwwwoOR", "..ROowwwwwwwoOR.", "...RROoooooORR..", ".....RRRRRRR...."],
]


def grid(rows, w, h, top=0, pal=None):
    img = np.zeros((h, w, 4), dtype=np.uint8)
    pal = dict(DB, **(pal or {}))
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch != ".":
                img[top + y, x] = pal[ch] + (255,)
    return img


def pennant():
    """a guild pennant: red with a gilt lion and a swallowtail, on an iron bar"""
    s = Spr(7, 12)
    s.rect(0, 0, 6, 0, IRON[2])
    s.poly([(0.5, 1), (6.5, 1), (6.5, 11.5), (3.5, 8.5), (0.5, 11.5)], lambda x, y: RED[3] if x < 2 else RED[2] if x < 5 else RED[1])
    for x, y in ((3, 3), (2, 4), (3, 4), (4, 4), (3, 5), (2, 6), (4, 6)):
        s.put(x, y, GOLD[3])
    s.rect(1, 1, 5, 1, GOLD[2])
    s.outline(0.45)
    img = np.zeros((16, 16, 4), dtype=np.uint8)
    img[0:12, 0:7] = np.array(s.image())
    return img


def soil(seed, plants):
    s = Spr(16, 16)
    for y in range(16):
        for x in range(16):
            row = y % 8
            if row < 2:
                s.put(x, y, SOIL[1] if row == 0 else SOIL[2])
            else:
                s.put(x, y, SOIL[2] if H(x, y, seed) < 0.6 else SOIL[3])
    if plants:
        for y0 in (2, 10):                                                   # two rows of young wheat
            for x in range(0, 16, 2):
                hgt = 3 + int(H(x, y0, seed + 1) * 3)
                for k in range(hgt):
                    c = WHEAT[3] if k == hgt - 1 else GREEN[2] if k > 1 else GREEN[1]
                    s.put(x + (k % 2 if k > 1 else 0), y0 + 5 - k, c)
                if H(x, y0, seed + 2) < 0.5:
                    s.put(x + 1, y0 + 2, WHEAT[2])
    return np.array(s.image())


def cut(img, name, w, h):
    out = []
    for y in range(h):
        for x in range(w):
            out.append(("%s_%d_%d" % (name, x, y), Image.fromarray(img[y * 16:y * 16 + 16, x * 16:x * 16 + 16], "RGBA")))
    return out


def murkling():
    s = Spr(16, 16)
    GR = [(30, 70, 50), (50, 112, 76), (84, 154, 98), (130, 196, 124)]
    s.ellipse(8, 9, 5.6, 4.6, lambda x, y: GR[3] if x < 6 and y < 8 else GR[2] if x < 10 else GR[1])
    for k, x in enumerate(range(4, 13, 2)):                                  # head fin
        s.rect(x, 3 - (k % 2), x, 5, (200, 90, 70) if k % 2 else (230, 130, 90))
    s.ellipse(5.5, 8, 1.6, 1.6, lambda x, y: (250, 250, 230)); s.put(5, 8, (20, 20, 20))
    s.ellipse(10.5, 8, 1.6, 1.6, lambda x, y: (250, 250, 230)); s.put(11, 8, (20, 20, 20))
    s.rect(6, 11, 10, 12, (90, 20, 30)); s.put(7, 11, (240, 240, 230)); s.put(9, 11, (240, 240, 230))
    s.outline(0.45)
    img = np.array(s.image())
    img[13:, :] = 0                                                         # the chin under the water
    for x in range(2, 15, 3):
        img[13, x] = (220, 240, 250, 220)                                   # a ripple round it
    return img


def tiles():
    out = [("field_soil", Image.fromarray(soil(5, False), "RGBA")),
           ("field_crop_a", Image.fromarray(soil(3, True), "RGBA")),
           ("field_crop_b", Image.fromarray(soil(9, True), "RGBA"))]
    out += cut(grid(STANDARD, 16, 32), "standard", 1, 2)
    out += cut(grid(BONFIRE, 32, 32), "bonfire", 2, 2)
    for i, f in enumerate(FLAMES):
        out.append(("flame_%d" % i, Image.fromarray(grid(f, 16, 16, top=2), "RGBA")))
    # the guild's chronicle (0.33, Marks.lua)
    out += cut(grid(STANDARD, 16, 32, pal={"A": (208, 70, 72), "a": (160, 44, 52)}), "standard_red", 1, 2)
    out.append(("pennant", Image.fromarray(pennant(), "RGBA")))
    out.append(("pet_murkling", Image.fromarray(murkling(), "RGBA")))     # (0.34, People.lua)
    return out

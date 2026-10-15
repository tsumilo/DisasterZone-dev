"""The guild's things in Goldshire for the atlas (Azeromon 0.30), approved in the "alive" mockup
(dev/art/casc/azeromon_alive, 2026-10-15: newart.py statue(), pixels.py "marker"):

  statue0..2  2 x 4  the weekly guild goal's statue (Bounties.lua): 0 scaffolding round a rough block, 1 the plinth
                     with a block being carved, 2 a knight of the guild on the plinth. 32 x 56 art standing on the
                     bottom of a 32 x 64 cell; UI.lua draws it live (its stage changes during the week) with the
                     base (the bottom 2 x 2) solid
  marker      1 x 1  a last-seen marker: a small rune stone where a guildmate last stood (12 x 14 on a 16 x 16 tile)

Used by gen_azeromon_art.py: tiles() -> [(name, 16 x 16 RGBA Image)], appended so earlier slots never move."""
import numpy as np
from PIL import Image

from azeromon_props import Spr, WOOD, STONE, CANVAS, IRON, RED, MOSS

GOLD = [(96, 62, 14), (164, 116, 30), (220, 172, 52), (250, 218, 110), (255, 246, 196)]
BLUE = [(16, 36, 84), (30, 66, 140), (56, 108, 196), (110, 160, 232)]

SIZE = {"statue0": (2, 4), "statue1": (2, 4), "statue2": (2, 4)}


def statue(stage):
    s = Spr(32, 56)
    base_top = 40
    if stage == 0:
        # scaffolding round a rough block, stones waiting, a ladder
        s.rect(9, 30, 22, 53, STONE[2]); s.rect(9, 30, 22, 30, STONE[3]); s.rect(19, 31, 22, 53, STONE[1])
        for y in range(33, 54, 4): s.rect(9, y, 22, y, STONE[1])
        for x in (5, 26):
            s.rect(x, 20, x, 54, WOOD[2]); s.put(x, 20, WOOD[3])
        for y in (24, 36, 48):
            s.rect(4, y, 27, y, WOOD[3]); s.rect(4, y + 1, 27, y + 1, WOOD[1])
        s.line(5, 20, 26, 48, WOOD[1]); s.line(26, 20, 5, 48, WOOD[1])
        for y in range(38, 55, 3): s.rect(28, y, 30, y, WOOD[2])
        s.rect(28, 36, 28, 55, WOOD[1]); s.rect(31, 36, 31, 55, WOOD[1])
        for x, y in ((1, 52), (2, 50)):
            s.rect(x, y, x + 3, y + 2, STONE[3]); s.put(x + 3, y + 2, STONE[1])
        s.rect(13, 22, 18, 23, CANVAS[3]); s.rect(13, 24, 18, 25, CANVAS[2])                       # a canvas tarp
    else:
        # plinth: three stepped courses of dressed stone with a crest panel
        def stone(x, y, x0, x1):
            lx = (x - x0) / max(1, x1 - x0)
            return STONE[4 if lx < 0.18 else 3 if lx < 0.6 else 2]
        for (x0, x1, y0, y1) in ((2, 29, 50, 55), (4, 27, 45, 49), (6, 25, base_top, 44)):
            s.fill(x0, y0, x1, y1, lambda x, y, x0=x0, x1=x1: stone(x, y, x0, x1))
            s.rect(x0, y0, x1, y0, STONE[4]); s.rect(x0, y1, x1, y1, STONE[1])
        for x in range(3, 29, 6): s.rect(x, 51, x, 54, STONE[1])
        s.rect(11, 41, 20, 43, (40, 34, 30))                                                       # the plaque
        s.rect(12, 41, 19, 42, GOLD[2]); s.rect(12, 41, 19, 41, GOLD[3])
        for x in (13, 15, 17): s.put(x, 42, GOLD[1])
        for x, y in ((3, 55), (8, 49), (24, 54), (27, 49)): s.put(x, y, MOSS[2])                  # moss
        if stage == 1:
            s.rect(9, 22, 22, 39, STONE[2]); s.rect(9, 22, 22, 22, STONE[3]); s.rect(19, 23, 22, 39, STONE[1])   # rough block
            s.poly([(9, 22), (13, 17), (17, 17), (22, 22)], lambda x, y: STONE[3])                 # chiselled top
            for y in range(25, 39, 5): s.rect(9, y, 18, y, STONE[1])
            s.rect(24, 34, 27, 39, WOOD[2]); s.line(24, 34, 30, 27, IRON[3]); s.put(30, 27, IRON[4])   # mallet, chisel
        else:
            # a knight of the guild: helm and plume, a cape, a kite shield with a gilt lion, the sword planted
            L = [(66, 66, 78), (106, 106, 120), (150, 150, 162), (194, 194, 204), (230, 230, 238)]
            sh = lambda x, x0, x1: L[4] if (x - x0) / max(1, x1 - x0) < 0.2 else L[3] if (x - x0) / max(1, x1 - x0) < 0.55 else L[2]
            s.poly([(10, 19), (22, 19), (24, 39.5), (8, 39.5)], lambda x, y: L[1] if x < 20 else L[0])       # cape
            s.rect(12, 31, 14, 39, L[3]); s.rect(17, 31, 19, 39, L[2]); s.rect(19, 31, 19, 39, L[1])          # legs
            s.rect(11, 38, 14, 39, L[2]); s.rect(17, 38, 20, 39, L[1])                                        # sabatons
            s.poly([(11, 19), (21, 19), (21.5, 32), (10.5, 32)], lambda x, y: sh(x, 10, 22))                 # tabard
            s.rect(11, 25, 21, 25, L[1]); s.put(16, 25, GOLD[3])                                              # belt
            s.ellipse(11, 19.5, 2.6, 1.8, lambda x, y: L[4]); s.ellipse(21, 19.5, 2.6, 1.8, lambda x, y: L[2])   # pauldrons
            s.rect(13, 10, 19, 17, L[3]); s.rect(13, 10, 15, 17, L[4]); s.rect(18, 10, 19, 17, L[2])         # helm
            s.rect(14, 13, 19, 13, L[0]); s.put(16, 15, L[1]); s.rect(13, 17, 19, 18, L[2])                   # visor, gorget
            for k in range(6):
                s.put(15 + k * 0.5, 9 - k, RED[2] if k < 4 else RED[3]); s.put(16 + k * 0.5, 9 - k, RED[1])  # plume
            s.rect(15, 26, 16, 39, L[4]); s.rect(16, 26, 16, 39, L[2])                                        # blade
            s.rect(12, 25, 19, 25, GOLD[2]); s.rect(12, 25, 15, 25, GOLD[3])                                  # crossguard
            s.rect(15, 21, 16, 24, L[1]); s.rect(14, 22, 17, 23, L[3])                                        # hands
            s.poly([(4, 21), (10, 21), (10, 29), (7, 34), (4, 29)], lambda x, y: L[3] if x < 7 else L[2])    # shield
            s.poly([(5, 22), (9, 22), (9, 28.5), (7, 32), (5, 28.5)], lambda x, y: BLUE[2] if x < 7 else BLUE[1])
            for x, y in ((6, 24), (7, 24), (7, 25), (6, 26), (7, 26), (8, 26), (6, 27), (8, 28), (7, 23)): s.put(x, y, GOLD[3])
    s.outline(0.42)
    return s


# the last-seen marker, hand-placed in the people sheet's DawnBringer 16 (pixels.py)
MARKER_PAL = {"K": (20, 12, 28), "L": (109, 170, 44), "E": (52, 101, 36), "M": (117, 113, 97),
              "s": (176, 186, 196), "m": (96, 100, 112), "A": (109, 194, 202)}
MARKER = [
    "....KKKK....",
    "...KsssmK...",
    "..KssAsmmK..",
    "..KsAAAsmK..",
    "..KssAsmmK..",
    "..KsAsAmmK..",
    "..KssssmmK..",
    "..KsssmmmK..",
    "..KssmmmmK..",
    ".KKsmmmmmKK.",
    "KLKKKKKKKKLK",
    ".KLLELLLELK.",
    "..MMMMMMMM..",
    "............",
]


def marker():
    img = np.zeros((16, 16, 4), dtype=np.uint8)
    for y, row in enumerate(MARKER):
        for x, ch in enumerate(row):
            if ch != ".":
                img[y + 1, x + 2] = MARKER_PAL[ch] + (255,)    # centred, its foot on the tile's lower part
    return img


def tiles():
    out = []
    for stage in range(3):
        art = np.array(statue(stage).image())                  # 56 x 32
        cell = np.zeros((64, 32, 4), dtype=np.uint8)
        cell[8:64] = art
        for y in range(4):
            for x in range(2):
                out.append(("statue%d_%d_%d" % (stage, x, y), Image.fromarray(cell[y * 16:y * 16 + 16, x * 16:x * 16 + 16], "RGBA")))
    out.append(("marker", Image.fromarray(marker(), "RGBA")))
    return out

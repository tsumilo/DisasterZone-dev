"""Azeromon title screen art: the AZEROMON logo and a soft shade strip, in the world's pixel style.

The logo is drawn at game-pixel size (the game shows it at 3x with nearest filtering, like the world): pixel-font
letters on a gentle arc, a gold fill with a lit top edge and a shaded bottom edge, a dark rim, a thick blue outline
with a 3D drop under it, and a red ribbon underneath for the tagline (the tagline itself is a game font string so it
stays crisp). The shade strip is a white alpha ramp the game tints and stretches for the dark bands at the top and
bottom of the screen.

    python gen_azeromon_title.py            (writes Media/Azeromon/title_logo.tga + title_shade.tga)

UI.lua reads LOGO_W / LOGO_H / RIBBON (printed at the end) from TITLE_ART at the top of its title section."""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "addon", "DisasterZone"))
MEDIA = os.path.join(ROOT, "Media", "Azeromon")
FONT = os.path.join(MEDIA, "fonts", "PixelOperator-Bold.ttf")

TEXT = "AZEROMON"
SIZE = 32                    # a multiple of the font's 16 px grid: clean doubled pixels
ARC = 4                      # how far the middle letters rise
GAP = -1                     # letters tucked together: their outlines merge into one shape
PAD = 4                      # room for the outlines and the drop
DROP = 3                     # the 3D drop under the outline
RIBBON_W, RIBBON_H = 112, 16

GOLD = [(255, 248, 190), (255, 226, 96), (255, 196, 52), (240, 150, 30), (214, 112, 22)]
LIT, SHADE = (255, 252, 226), (168, 78, 14)
RIM = (58, 30, 12)
BLUE, BLUE_HI, DEEP = (36, 66, 138), (64, 104, 182), (16, 24, 58)
RED, RED_HI, RED_LO, RED_TAIL, RED_EDGE = (184, 42, 38), (222, 82, 64), (132, 26, 28), (112, 20, 26), (60, 12, 16)


def dilate(m, r=1):
    out = m.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            if dx * dx + dy * dy > r * r + r:
                continue
            out |= np.roll(np.roll(m, dy, 0), dx, 1)
    return out


def letters():
    """The letter mask on a gentle arc, trimmed to its pixels."""
    font = ImageFont.truetype(FONT, SIZE)
    glyphs = []
    for ch in TEXT:
        l, t, r, b = font.getbbox(ch)
        im = Image.new("L", (r - l + 2, SIZE + 8), 0)
        ImageDraw.Draw(im).text((-l + 1, 2), ch, font=font, fill=255)
        glyphs.append(np.array(im) > 127)
    n = len(glyphs)
    w = sum(g.shape[1] for g in glyphs) + GAP * (n - 1)
    h = SIZE + 8 + ARC
    m = np.zeros((h, w), bool)
    x = 0
    for i, g in enumerate(glyphs):
        rise = round(ARC * math.sin(math.pi * i / (n - 1)))
        y = ARC - rise
        m[y:y + g.shape[0], x:x + g.shape[1]] |= g
        x += g.shape[1] + GAP
    ys, xs = np.nonzero(m)
    return m[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def logo():
    core = letters()
    ch, cw = core.shape
    W, H = cw + PAD * 2, ch + PAD * 2 + DROP + 2 + RIBBON_H
    m = np.zeros((H, W), bool)
    m[PAD:PAD + ch, PAD:PAD + cw] = core
    rgba = np.zeros((H, W, 4), np.uint8)

    def put(mask, c, a=255):
        rgba[mask] = (*c, a)

    rim = dilate(m, 1)
    outer = dilate(rim, 1) | dilate(m, 2)
    drop = np.zeros_like(outer)
    for k in range(1, DROP + 1):
        drop |= np.roll(outer, k, 0)
    put(drop & ~outer, DEEP)
    put(outer & ~rim, BLUE)
    hi = outer & ~rim & ~np.roll(outer, 1, 0)                 # the outline's own lit top edge
    put(hi, BLUE_HI)
    put(rim & ~m, RIM)
    # the gold: banded top to bottom over the letters' height (each letter keeps the same bands: the arc moves them)
    ys = np.arange(H)[:, None].repeat(W, 1)
    top = np.full(W, H)
    bot = np.zeros(W, int)
    for x in range(W):
        col = np.nonzero(m[:, x])[0]
        if len(col):
            top[x], bot[x] = col.min(), col.max()
    span = np.maximum(bot - top, 1)
    f = np.clip((ys - top[None, :]) / span[None, :], 0, 0.999)
    band = (f * len(GOLD)).astype(int)
    for i, c in enumerate(GOLD):
        put(m & (band == i), c)
    put(m & ~np.roll(m, 1, 0), LIT)                            # lit top edges
    put(m & ~np.roll(m, -1, 0) & (band >= 2), SHADE)           # shaded bottom edges
    # a glint: two bright pixels on the first letter's shoulder
    ys0, xs0 = np.nonzero(m[:, :PAD + 12])
    if len(ys0):
        y0 = ys0.min() + 2
        x0 = xs0[ys0 == ys0.min()].min() + 1
        for dx, dy in ((0, 0), (1, 0), (0, 1)):
            if m[y0 + dy, x0 + dx]:
                rgba[y0 + dy, x0 + dx] = (255, 255, 255, 255)

    # the ribbon: a red band with folded tails, centred under the word
    ry = PAD + ch + DROP + 2
    rx = (W - RIBBON_W) // 2
    rb = np.zeros((H, W), bool)
    rb[ry:ry + RIBBON_H - 3, rx:rx + RIBBON_W] = True
    # the tails hang a little lower, behind the band's ends, cut with a swallow-tail notch
    tail, th = 12, RIBBON_H - 3
    tails = np.zeros_like(rb)
    for y in range(th):
        cut = max(0, 3 - abs(y - th // 2))
        yy = ry + 3 + y
        tails[yy, rx - tail + cut:rx + 4] = True
        tails[yy, rx + RIBBON_W - 4:rx + RIBBON_W + tail - cut] = True
    put(dilate(tails, 1) & ~tails, RED_EDGE)
    put(tails, RED_TAIL)
    put(tails & ~np.roll(tails, 1, 0), RED_LO)
    put(dilate(rb, 1) & ~rb, RED_EDGE)
    put(rb, RED)
    put(rb & ~np.roll(rb, 1, 0), RED_HI)
    put(rb & ~np.roll(rb, -1, 0), RED_LO)
    for x in (rx - 1, rx + RIBBON_W):                          # the fold where the band meets its tails
        rgba[ry + 3:ry + RIBBON_H - 2, x] = (*RED_EDGE, 255)

    # padded to a power of two (the game reads the used part by texcoords)
    PW = 1 << (W - 1).bit_length()
    PH = 1 << (H - 1).bit_length()
    out = np.zeros((PH, PW, 4), np.uint8)
    out[:H, :W] = rgba
    Image.fromarray(out, "RGBA").save(os.path.join(MEDIA, "title_logo.tga"))
    return W, H, PW, PH, (rx, ry, RIBBON_W, RIBBON_H)


def shade():
    a = (np.linspace(1, 0, 64) ** 1.6 * 255).astype(np.uint8)
    out = np.zeros((64, 4, 4), np.uint8)
    out[..., :3] = 255
    out[..., 3] = a[:, None]
    Image.fromarray(out, "RGBA").save(os.path.join(MEDIA, "title_shade.tga"))


if __name__ == "__main__":
    W, H, PW, PH, rib = logo()
    shade()
    print("LOGO_W = %d, LOGO_H = %d, TEX_W = %d, TEX_H = %d, RIBBON = { %d, %d, %d, %d }" % ((W, H, PW, PH) + rib))

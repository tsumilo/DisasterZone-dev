"""The Games hub's game logos (set A, picked 2026-10-15 from the poster logo mockup): Council Bingo, Raid Trainer,
Karazhan Chess and The Binding of Illidan. Drawn with the client's own fonts (Morpheus, Skurri, Friz) and baked light,
outline, shadow and glow, the way gen_azeromon_title.py draws Azeromon's. Each is drawn at 2x on a LOGO_W x LOGO_H
box (a poster title's place) with room round it for the glow, then placed at the top left of a 512 x 256 texture.

    python gen_game_logos.py            (writes Media/Games/logo_<id>.tga)

Games/HubUI.lua's LOGOS table holds the numbers this prints (the ink box inside each texture, in texture pixels):
paste them there when a logo changes. Art: raise assetPack in Core/BuildInfo.lua (logos came with art pack 14)."""
import math
import sys
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).parent
ART = HERE.parent / "art" / "fonts"
SRC = HERE.parent / "art" / "logos"
ADDON = HERE.parent.parent / "addon" / "DisasterZone"
MORPH, SKURRI, FRIZ = ART / "morpheus.ttf", ART / "skurri.ttf", ART / "frizqt.ttf"
K = 2                                   # drawn at 2x
LOGO_W, LOGO_H = 268, 72                # the box on a front poster (1x)
OX, OY = 34, 28                         # room for glows and shadows round the box (trimmed away at the end)
W, H = (LOGO_W + 2 * OX) * K, (LOGO_H + 2 * OY) * K


class D:
    """ImageDraw on mask m with the logo's origin (OX, OY) added to every coordinate (given in drawn px)."""
    def __init__(self, m):
        self.d = ImageDraw.Draw(m)

    @staticmethod
    def _shift(xy):
        if isinstance(xy, (list, tuple)) and xy and isinstance(xy[0], (list, tuple)):
            return [(x + OX * K, y + OY * K) for x, y in xy]
        return tuple(v + (OX if i % 2 == 0 else OY) * K for i, v in enumerate(xy))

    def __getattr__(self, name):
        fn = getattr(self.d, name)
        return lambda xy, *a, **kw: fn(self._shift(xy), *a, **kw)


def font(path, px):
    return ImageFont.truetype(str(path), int(px * K))


def mask_text(text, f, track=0.0, size=(W, H), at=(0, 0)):
    """An L mask of text, with tracking (extra px between letters, 1x), drawn at `at` (1x, top-left of the ink)."""
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    x, y = (at[0] + OX) * K, (at[1] + OY) * K
    for ch in text:
        d.text((x, y), ch, font=f, fill=255)
        x += d.textlength(ch, font=f) + track * K
    return m


def text_w(text, f, track=0.0):
    d = ImageDraw.Draw(Image.new("L", (1, 1)))
    return (sum(d.textlength(ch, font=f) for ch in text) + track * K * (len(text) - 1)) / K


def ink_box(m):
    return m.getbbox() or (0, 0, 1, 1)


def vgrad(size, stops, box=None):
    """A vertical gradient (RGBA) over size; stops [(t, (r,g,b))] t in 0..1 across box's top..bottom (default all)."""
    w, h = size
    y0, y1 = (box[1], box[3]) if box else (0, h)
    col = Image.new("RGBA", (1, h))
    for y in range(h):
        t = min(1, max(0, (y - y0) / max(1, y1 - y0)))
        for i in range(len(stops) - 1):
            if stops[i][0] <= t <= stops[i + 1][0]:
                a, b = stops[i], stops[i + 1]
                u = (t - a[0]) / max(1e-6, b[0] - a[0])
                c = tuple(int(a[1][k] + (b[1][k] - a[1][k]) * u) for k in range(3))
                break
        else:
            c = stops[-1][1]
        col.putpixel((0, y), c + (255,))
    return col.resize((w, h))


def grow(m, px):
    if px <= 0:
        return m
    n = int(px * K) * 2 + 1
    return m.filter(ImageFilter.MaxFilter(n if n % 2 else n + 1))


def colored(m, rgb, a=1.0):
    im = Image.new("RGBA", m.size, rgb + (0,))
    im.putalpha(m.point(lambda v: int(v * a)))
    return im


def bevel(m, strength=0.55, blur=1.6, light=(-1, -1)):
    """Light and shade from a blurred mask's slope (light from the top left): returns (hi, lo) L masks inside m."""
    b = m.filter(ImageFilter.GaussianBlur(blur * K))
    sh = ImageChops.offset(b, int(light[0] * K), int(light[1] * K))
    hi = ImageChops.subtract(b, sh)            # facing the light
    lo = ImageChops.subtract(sh, b)            # facing away
    f = lambda im: ImageChops.multiply(im.point(lambda v: min(255, int(v * 4 * strength))), m)
    return f(hi), f(lo)


def layer(base, *layers):
    for l in layers:
        base.alpha_composite(l)
    return base


def styled(m, fill, outline=None, outline_px=1.2, shadow=0.75, shadow_dy=2.0, glow=None, glow_px=7, glow_a=0.6,
           bev=0.55, inner=None):
    """A logo layer from mask m: glow, drop shadow, outline, gradient/texture fill, bevel, inner rim."""
    out = Image.new("RGBA", m.size, (0, 0, 0, 0))
    edge = grow(m, outline_px) if outline else m
    if glow:
        g = grow(m, 1.5).filter(ImageFilter.GaussianBlur(glow_px * K))
        out.alpha_composite(colored(g, glow, glow_a))
    if shadow:
        s = ImageChops.offset(edge, 0, int(shadow_dy * K)).filter(ImageFilter.GaussianBlur(2.2 * K))
        out.alpha_composite(colored(s, (0, 0, 0), shadow))
    if outline:
        out.alpha_composite(colored(edge, outline))
    f = fill.copy()
    f.putalpha(ImageChops.multiply(f.getchannel("A"), m))
    out.alpha_composite(f)
    if bev:
        hi, lo = bevel(m, bev)
        out.alpha_composite(colored(hi, (255, 255, 240), 0.9))
        out.alpha_composite(colored(lo, (0, 0, 0), 0.7))
    if inner:
        rim = ImageChops.subtract(m, m.filter(ImageFilter.MinFilter(3)))
        out.alpha_composite(colored(rim, inner, 0.55))
    return out


def ls_tex(fid, size, l=0.3, t=0.35, s=0.25):
    """A patch of a loading screen as a fill texture."""
    src = Image.open(SRC / fid).convert("RGB")
    S = src.size[0]
    return src.crop((int(l * S), int(t * S), int((l + s) * S), int((t + s * size[1] / size[0]) * S))).resize(size, Image.LANCZOS).convert("RGBA")


def raid_icon(i, px):
    im = Image.open(SRC / "raidicons.png").convert("RGBA")
    c, r = i % 4, i // 4
    return im.crop((c * 64, r * 64, c * 64 + 64, r * 64 + 64)).resize((int(px * K), int(px * K)), Image.LANCZOS)


GOLD = [(0, (255, 246, 196)), (0.42, (255, 210, 70)), (0.58, (214, 150, 20)), (1, (255, 214, 110))]
STEEL_TEAL = [(0, (232, 252, 255)), (0.45, (140, 226, 236)), (0.6, (60, 160, 176)), (1, (170, 236, 244))]
FEL = [(0, (236, 255, 170)), (0.45, (166, 240, 74)), (1, (52, 120, 12))]
SILVER = [(0, (255, 255, 255)), (0.5, (196, 188, 220)), (0.62, (120, 104, 160)), (1, (214, 204, 236))]
IVORY = [(0, (255, 250, 236)), (0.55, (226, 214, 190)), (1, (160, 142, 116))]


def baseline_place(m_list, total_h=H):
    return m_list

# ------------------------------------------------------------------------------------------------- the logos
def bingo_A():
    """Gilded: COUNCIL small over BINGO in beveled gold, the O a raid marker (the dauber)."""
    out = Image.new("RGBA", (W, H))
    small = font(FRIZ, 11)
    big = font(MORPH, 44)
    sm = mask_text("COUNCIL", small, track=4.2, at=(3, 2))
    out.alpha_composite(styled(sm, vgrad((W, H), GOLD, ink_box(sm)), outline=(40, 26, 4), outline_px=0.8, bev=0, shadow=0.6))
    bm = mask_text("BING", big, track=1, at=(0, 12))
    bb = ink_box(bm)
    out.alpha_composite(styled(bm, vgrad((W, H), GOLD, bb), outline=(46, 28, 2), outline_px=1.4, glow=(255, 190, 40), glow_a=0.28))
    # the O: a gold ring holding the star marker
    cx, cy, r = bb[2] / K - OX + 22, (bb[1] + bb[3]) / 2 / K - OY + 1, 17
    ring = Image.new("L", (W, H))
    d = D(ring)
    d.ellipse(((cx - r) * K, (cy - r) * K, (cx + r) * K, (cy + r) * K), fill=255)
    d.ellipse(((cx - r + 4.2) * K, (cy - r + 4.2) * K, (cx + r - 4.2) * K, (cy + r - 4.2) * K), fill=0)
    out.alpha_composite(styled(ring, vgrad((W, H), GOLD, ink_box(ring)), outline=(46, 28, 2), outline_px=1.4))
    ic = raid_icon(0, 21)
    out.alpha_composite(ic, (int((cx - 10.5 + OX) * K), int((cy - 10.5 + OY) * K)))
    return out


def bingo_B():
    """Card: B I N G O on five gold-edged squares (the card's own cells), COUNCIL tracked above."""
    out = Image.new("RGBA", (W, H))
    small = font(FRIZ, 10.5)
    sm = mask_text("COUNCIL", small, track=6.5, at=(2, 1))
    out.alpha_composite(styled(sm, vgrad((W, H), [(0, (255, 232, 160)), (1, (220, 170, 60))], ink_box(sm)), bev=0, shadow=0.6))
    cell, gap, y = 40, 5, 22
    let = font(MORPH, 34)
    for i, ch in enumerate("BINGO"):
        x = i * (cell + gap)
        box = Image.new("L", (W, H))
        D(box).rectangle((x * K, y * K, (x + cell) * K - 1, (y + cell) * K - 1), fill=255)
        tile = vgrad((W, H), [(0, (58, 46, 18)), (1, (24, 19, 8))], ink_box(box))
        out.alpha_composite(styled(box, tile, outline=None, bev=0.25, shadow=0.7, shadow_dy=2.5))
        rim = ImageChops.subtract(box, box.filter(ImageFilter.MinFilter(int(1.4 * K) * 2 + 1)))
        out.alpha_composite(colored(rim, (255, 209, 0), 0.85 if ch != "N" else 1))
        if ch == "N":           # the free centre: the marker, lit
            out.alpha_composite(colored(box.filter(ImageFilter.GaussianBlur(6 * K)), (255, 200, 40), 0.35))
        lw = text_w(ch, let)
        lm = mask_text(ch, let, at=(x + (cell - lw) / 2, y - 1))
        out.alpha_composite(styled(lm, vgrad((W, H), GOLD, (0, y * K, 0, (y + cell) * K)), outline=(40, 24, 0), outline_px=1, shadow=0.5))
    return out


def trainer_A():
    """Sigil: a target ring with crosshair, then RAID / TRAINER in steel teal Friz, tracked."""
    out = Image.new("RGBA", (W, H))
    cx, cy, r = 30, 38, 26
    ring = Image.new("L", (W, H))
    d = D(ring)
    for rr, wd in ((r, 3.2), (r - 9, 2)):
        d.ellipse(((cx - rr) * K, (cy - rr) * K, (cx + rr) * K, (cy + rr) * K), outline=255, width=int(wd * K))
    for a in range(4):
        ang = a * math.pi / 2 + math.pi / 4
        x0, y0 = cx + math.cos(ang) * (r - 15), cy + math.sin(ang) * (r - 15)
        x1, y1 = cx + math.cos(ang) * (r + 6), cy + math.sin(ang) * (r + 6)
        d.line((x0 * K, y0 * K, x1 * K, y1 * K), fill=255, width=int(2.4 * K))
    d.ellipse(((cx - 4) * K, (cy - 4) * K, (cx + 4) * K, (cy + 4) * K), fill=255)
    out.alpha_composite(styled(ring, vgrad((W, H), STEEL_TEAL, ink_box(ring)), outline=(4, 22, 26), outline_px=1.1,
                               glow=(79, 211, 224), glow_a=0.45, glow_px=6))
    f1, f2 = font(FRIZ, 14), font(MORPH, 36)
    m1 = mask_text("RAID", f1, track=9, at=(70, 7))
    out.alpha_composite(styled(m1, vgrad((W, H), STEEL_TEAL, ink_box(m1)), outline=(4, 22, 26), outline_px=0.9, bev=0.3))
    m2 = mask_text("TRAINER", f2, track=1.5, at=(68, 24))
    out.alpha_composite(styled(m2, vgrad((W, H), STEEL_TEAL, ink_box(m2)), outline=(2, 18, 22), outline_px=1.4,
                               glow=(79, 211, 224), glow_a=0.25))
    return out


def trainer_B():
    """Arena: Raid Trainer in Morpheus, white-to-teal, over an ellipse floor ring (the boss room seen from above)."""
    out = Image.new("RGBA", (W, H))
    fl = Image.new("L", (W, H))
    d = D(fl)
    d.ellipse((4 * K, 46 * K, 250 * K, 70 * K), outline=255, width=int(1.6 * K))
    d.ellipse((40 * K, 52 * K, 214 * K, 66 * K), outline=150, width=int(1 * K))
    out.alpha_composite(colored(fl.filter(ImageFilter.GaussianBlur(0.5 * K)), (79, 211, 224), 0.75))
    out.alpha_composite(colored(fl.filter(ImageFilter.GaussianBlur(5 * K)), (79, 211, 224), 0.5))
    for i, (x, y, c) in enumerate(((30, 58, (199, 156, 110)), (80, 66, (105, 204, 240)), (170, 64, (245, 140, 186)),
                                   (224, 56, (171, 212, 115)), (127, 59, (255, 90, 74)))):
        dm = Image.new("L", (W, H))
        rr = 4.5 if i == 4 else 3
        D(dm).ellipse(((x - rr) * K, (y - rr) * K, (x + rr) * K, (y + rr) * K), fill=255)
        out.alpha_composite(styled(dm, vgrad((W, H), [(0, c), (1, c)]), outline=(0, 0, 0), outline_px=0.8, bev=0, shadow=0.5))
    f = font(MORPH, 38)
    m = mask_text("RAID TRAINER", f, track=1.5, at=(8, 2))
    out.alpha_composite(styled(m, vgrad((W, H), [(0, (255, 255, 255)), (0.55, (190, 244, 250)), (1, (79, 211, 224))], ink_box(m)),
                               outline=(2, 20, 24), outline_px=1.4, glow=(79, 211, 224), glow_a=0.35))
    return out


def chess_A():
    """Carved: Karazhan in tracked silver small caps over CHESS cut from the tower's own stone, purple rim light."""
    out = Image.new("RGBA", (W, H))
    f1, f2 = font(FRIZ, 11), font(FRIZ, 42)
    m1 = mask_text("KARAZHAN", f1, track=5.5, at=(3, 2))
    out.alpha_composite(styled(m1, vgrad((W, H), SILVER, ink_box(m1)), outline=(20, 12, 34), outline_px=0.8, bev=0, shadow=0.6))
    m2 = mask_text("CHESS", f2, track=3, at=(0, 15))
    stone = ls_tex("karazhan_loadscreen.png", (W, H), l=0.62, t=0.4, s=0.18)
    tint = vgrad((W, H), [(0, (236, 228, 255)), (1, (120, 100, 170))], ink_box(m2))
    stone = ImageChops.multiply(stone, tint)
    stone = Image.blend(stone, tint, 0.35)
    out.alpha_composite(styled(m2, stone, outline=(18, 10, 30), outline_px=1.5, glow=(189, 148, 255), glow_a=0.35, bev=0.8,
                               inner=(230, 210, 255)))
    # the king: a crowned piece after the word
    bb = ink_box(m2)
    x0 = bb[2] / K - OX + 12
    k = Image.new("L", (W, H))
    d = D(k)
    P = lambda pts: [((x0 + x) * K, (12 + y) * K) for x, y in pts]
    d.polygon(P([(4, 46), (26, 46), (24, 41), (21, 39), (19, 24), (23, 21), (23, 18), (7, 18), (7, 21), (11, 24), (9, 39), (6, 41)]), fill=255)
    d.polygon(P([(7, 17), (23, 17), (25, 9), (20, 12), (15, 5), (10, 12), (5, 9)]), fill=255)
    d.rectangle(((x0 + 13.6) * K, (12 + 0) * K, (x0 + 16.4) * K, (12 + 6) * K), fill=255)
    d.rectangle(((x0 + 12) * K, (12 + 1.6) * K, (x0 + 18) * K, (12 + 3.8) * K), fill=255)
    out.alpha_composite(styled(k, vgrad((W, H), SILVER, ink_box(k)), outline=(18, 10, 30), outline_px=1.4, glow=(189, 148, 255),
                               glow_a=0.45, bev=0.7))
    return out


def chess_B():
    """Board: Karazhan Chess in ivory Morpheus over a band of black and white squares in perspective."""
    out = Image.new("RGBA", (W, H))
    band = Image.new("RGBA", (W, H))
    d = D(band)
    n, y0, y1 = 12, 50, 70
    for row in range(2):
        for i in range(n):
            ya, yb = y0 + row * 10, y0 + (row + 1) * 10
            def X(x, y):
                s = 0.78 + 0.22 * (y - y0) / (y1 - y0)
                return (134 + (x - 134) * s) * K
            xa, xb = 10 + i * 20, 10 + (i + 1) * 20
            c = (225, 216, 196, 235) if (i + row) % 2 == 0 else (40, 30, 52, 235)
            d.polygon([(X(xa, ya), ya * K), (X(xb, ya), ya * K), (X(xb, yb), yb * K), (X(xa, yb), yb * K)], fill=c)
    fade = Image.new("L", (W, H))
    fd = ImageDraw.Draw(fade)
    for x in range(W):
        t = min(x / (40 * K), (W - x) / (40 * K), 1)
        fd.line((x, 0, x, H), fill=int(255 * t))
    band.putalpha(ImageChops.multiply(band.getchannel("A"), fade))
    out.alpha_composite(band)
    f = font(FRIZ, 25)
    m = mask_text("KARAZHAN CHESS", f, track=2.2, at=(6, 12))
    out.alpha_composite(styled(m, vgrad((W, H), IVORY, ink_box(m)), outline=(20, 12, 30), outline_px=1.5, glow=(189, 148, 255),
                               glow_a=0.4, bev=0.6))
    return out


def illidan_A():
    """Fel scrawl: THE BINDING OF in small Friz, ILLIDAN in Skurri, fel green with drips and a fel glow."""
    out = Image.new("RGBA", (W, H))
    f1, f2 = font(FRIZ, 10.5), font(SKURRI, 50)
    m1 = mask_text("THE BINDING OF", f1, track=3.6, at=(3, 1))
    out.alpha_composite(styled(m1, vgrad((W, H), [(0, (220, 236, 200)), (1, (150, 190, 120))], ink_box(m1)), bev=0, shadow=0.7))
    m2 = mask_text("ILLIDAN", f2, track=1, at=(0, 9))
    bb = ink_box(m2)
    # drips: a few runs down from the letters' feet
    d = ImageDraw.Draw(m2)
    for x, ln in ((22, 9), (61, 5), (104, 12), (151, 6), (199, 8)):
        xx = bb[0] / K + x
        y = bb[3] / K - 2
        d.rounded_rectangle((xx * K, y * K, (xx + 3) * K, (y + ln) * K), radius=int(1.5 * K), fill=255)
        d.ellipse(((xx - 0.6) * K, (y + ln - 2) * K, (xx + 3.6) * K, (y + ln + 2.4) * K), fill=255)
    out.alpha_composite(styled(m2, vgrad((W, H), FEL, ink_box(m2)), outline=(10, 22, 2), outline_px=1.5, glow=(140, 255, 40),
                               glow_a=0.55, glow_px=8, bev=0.5))
    return out


def illidan_B():
    """Chained: THE BINDING OF on a chain that runs behind, ILLIDAN in dark iron with fel light in its cuts."""
    out = Image.new("RGBA", (W, H))
    ch = Image.new("L", (W, H))
    d = D(ch)
    y, n = 13, 17
    for i in range(n):
        x = 4 + i * 15
        if i % 2 == 0:
            d.rounded_rectangle((x * K, (y - 5) * K, (x + 18) * K, (y + 5) * K), radius=int(5 * K), outline=255, width=int(2.4 * K))
        else:
            d.rounded_rectangle((x * K, (y - 1.4) * K, (x + 18) * K, (y + 1.4) * K), radius=int(1.4 * K), fill=255)
    out.alpha_composite(styled(ch, vgrad((W, H), [(0, (150, 150, 146)), (1, (54, 54, 58))], ink_box(ch)), outline=(0, 0, 0),
                               outline_px=0.8, bev=0.7, shadow=0.7))
    f1, f2 = font(FRIZ, 10.5), font(FRIZ, 40)
    m1 = mask_text("THE BINDING OF", f1, track=3.6, at=(64, 6))
    plate = grow(m1, 4).filter(ImageFilter.GaussianBlur(2 * K))
    out.alpha_composite(colored(plate, (12, 14, 10), 0.95))
    out.alpha_composite(styled(m1, vgrad((W, H), [(0, (226, 236, 210)), (1, (160, 180, 140))], ink_box(m1)), bev=0, shadow=0))
    m2 = mask_text("ILLIDAN", f2, track=3, at=(2, 24))
    iron = vgrad((W, H), [(0, (200, 204, 192)), (0.5, (112, 118, 104)), (1, (60, 64, 54))], ink_box(m2))
    out.alpha_composite(styled(m2, iron, outline=(4, 10, 0), outline_px=1.5, glow=(140, 255, 40), glow_a=0.55, glow_px=9, bev=0.8,
                               inner=(190, 255, 120)))
    return out


def azeromon():
    """Azeromon's own title_logo.tga (the generator's pixel letters + ribbon), 2x NEAREST like the game draws it."""
    im = Image.open(ADDON / "Media" / "Azeromon" / "title_logo.tga").convert("RGBA")
    big = im.resize((im.size[0] * 2, im.size[1] * 2), Image.NEAREST)
    out = Image.new("RGBA", (W, H))
    out.alpha_composite(big, (OX * K, (OY + 4) * K))
    return out


LOGOS = {"bingo": (bingo_A, bingo_B), "trainer": (trainer_A, trainer_B), "chess": (chess_A, chess_B),
         "illidan": (illidan_A, illidan_B), "azeromon": (azeromon, azeromon)}
SHIP = {"bingo": bingo_A, "trainer": trainer_A, "chess": chess_A, "illidan": illidan_A}
TEX_W, TEX_H = 512, 256


def trim(im):
    """Crop to the ink (keeping the glow), so the poster can sit it on the title's baseline."""
    bb = im.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    return im.crop(bb) if bb else im


def ink(im):
    """The solid letters' box (alpha > 150): what lines up with text."""
    return im.getchannel("A").point(lambda v: 255 if v > 150 else 0).getbbox()


def build():
    out = ADDON / "Media" / "Games"
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    for gid, fn in SHIP.items():
        im = trim(fn())
        assert im.size[0] <= TEX_W and im.size[1] <= TEX_H, (gid, im.size)
        tex = Image.new("RGBA", (TEX_W, TEX_H))
        tex.alpha_composite(im, (0, 0))
        tex.save(out / f"logo_{gid}.tga")
        l, t, r, b = ink(im)
        rows.append(f"    {gid} = {{ w = {im.size[0]}, h = {im.size[1]}, l = {l}, t = {t}, r = {r}, b = {b} }},")
    print("-- paste into Games/HubUI.lua LOGOS (texture px; the art spans w x h from the top left of 512 x 256)")
    print("\n".join(rows))


if __name__ == "__main__":
    build()

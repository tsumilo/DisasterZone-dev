"""Textures for the gear sim page's sigil (UI/SimStage.lua), the look of mockup B (dev/art/casc/simflow_mockup):
  Media/Sim/disc.tga       the dial's face: a dark disc, lit a little above the centre, a gold edge and a faint inner ring
  Media/Sim/dashring.tga   the slow outer ring: white dashes (14 4 2 4) round a circle, turned by the page
  Media/Sim/glasses.tga    the Nerd stats button's glasses (white, tinted gold)
  Media/Sim/pill.tga       a white rounded pill (the settings chip: fill and edge, as three slices)
  Media/Sim/pilledge.tga   its 1 px outline
  Media/Sim/iconring.tga   the spec icon's edge at 52 px: 1 px black, then 1 px of the dial's gold (#5a4a1c)
Run (from dev): luaenv\\Scripts\\python.exe generators\\gen_sim_media.py"""
import math
from pathlib import Path

from PIL import Image, ImageDraw

ADDON = Path(__file__).resolve().parents[2] / "addon" / "DisasterZone"
OUT = ADDON / "Media" / "Sim"
SS = 4  # supersampling per axis


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(len(a)))


def disc(size=256):
    """The sigil's face at 168 px: the mock's radial gradient (centre 50% 40%, radius 70%: #25221a -> #141413 at 75% ->
    #0e0e10), a #5a4a1c edge (1.2 px) and a #2a2620 ring 5 px inside it (1 px)."""
    big = size * SS
    c = big / 2
    R = c - 1.5 * SS
    disp = 168.0 / size          # display px per texture px
    edge_w = 1.2 / disp * SS     # in big px
    inner_r, inner_w = R * (79.0 / 84.0), 1.0 / disp * SS
    stops = [(0.0, hexrgb("25221a")), (0.75, hexrgb("141413")), (1.0, hexrgb("0e0e10"))]
    gx, gy, gr = c, c - 0.2 * R * 0.5, 0.7 * 2 * R * 0.72
    im = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    px = im.load()
    edge_c, inner_c = hexrgb("5a4a1c"), hexrgb("2a2620")
    for y in range(big):
        for x in range(big):
            d = math.hypot(x + 0.5 - c, y + 0.5 - c)
            if d > R:
                continue
            t = min(1.0, math.hypot(x + 0.5 - gx, y + 0.5 - gy) / gr)
            col = stops[-1][1]
            for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
                if t <= t1:
                    col = lerp(c0, c1, (t - t0) / (t1 - t0))
                    break
            if abs(d - inner_r) <= inner_w / 2:
                col = lerp(col, inner_c, 0.9)
            if d >= R - edge_w:
                col = edge_c
            px[x, y] = tuple(int(round(v)) for v in col) + (255,)
    return im.resize((size, size), Image.LANCZOS)


def dashring(size=512, display=222.0, radius=110.0):
    """White dashes round a circle of `radius` display px in a `display` px texture: 14 on, 4 off, 2 on, 4 off."""
    big = size * SS
    c = big / 2
    scale = big / display
    r = radius * scale
    w = 1.0 * scale
    circ = 2 * math.pi * radius
    reps = round(circ / 24.0)
    unit = circ / reps / 24.0           # stretch the pattern to close the circle
    pattern = [(0, 14), (18, 20)]       # on-intervals in a 24-long unit
    im = Image.new("L", (big, big), 0)
    px = im.load()
    for y in range(big):
        for x in range(big):
            d = math.hypot(x + 0.5 - c, y + 0.5 - c)
            if abs(d - r) > w / 2:
                continue
            a = (math.atan2(y + 0.5 - c, x + 0.5 - c) + math.pi) / (2 * math.pi) * circ
            u = (a / unit) % 24.0
            if any(lo <= u < hi for lo, hi in pattern):
                px[x, y] = 255
    alpha = im.resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


def glasses(w=64, h=32):
    """Two round lenses and a bridge (the mock's 22 x 11 icon, 1.6 px strokes)."""
    big = Image.new("L", (w * SS, h * SS), 0)
    d = ImageDraw.Draw(big)
    s = w * SS / 22.0
    lw = int(round(1.6 * s))
    for cx in (4.5, 17.5):
        r = 4.5
        d.ellipse([(cx - r) * s + lw / 2, (5.5 - r) * s + lw / 2, (cx + r) * s - lw / 2, (5.5 + r) * s - lw / 2],
                  outline=255, width=lw)
    d.rectangle([8.5 * s, 4.5 * s, 13.5 * s, 4.5 * s + lw], fill=255)
    big = big.crop((0, 0, w * SS, int(11 * s)))
    alpha = big.resize((w, int(11 * s / SS)), Image.LANCZOS)
    out = Image.new("RGBA", alpha.size, (255, 255, 255, 0))
    out.putalpha(alpha)
    canvas = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    canvas.paste(out, (0, (h - out.size[1]) // 2))
    return canvas


def pill(w=64, h=32, edge=False):
    """A rounded pill (radius = half the height), filled or as a 1 px outline at the chip's 24 px height."""
    big = Image.new("L", (w * SS, h * SS), 0)
    d = ImageDraw.Draw(big)
    r = h * SS / 2
    lw = max(1, int(round(SS * h / 24.0)))
    box = [lw / 2, lw / 2, w * SS - lw / 2 - 1, h * SS - lw / 2 - 1]
    if edge:
        d.rounded_rectangle(box, radius=r - lw / 2, outline=255, width=lw)
    else:
        d.rounded_rectangle(box, radius=r - lw / 2, fill=255)
    alpha = big.resize((w, h), Image.LANCZOS)
    out = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


def iconring(size=128, display=52.0):
    big = size * SS
    c = big / 2
    k = big / display
    im = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    px = im.load()
    gold = hexrgb("5a4a1c")
    for y in range(big):
        for x in range(big):
            d = math.hypot(x + 0.5 - c, y + 0.5 - c) / k
            if 24.0 <= d < 25.0:
                px[x, y] = (0, 0, 0, 255)
            elif 25.0 <= d < 26.2:
                px[x, y] = gold + (255,)
    return im.resize((size, size), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    disc().save(OUT / "disc.tga")
    dashring().save(OUT / "dashring.tga")
    glasses().save(OUT / "glasses.tga")
    pill().save(OUT / "pill.tga")
    pill(edge=True).save(OUT / "pilledge.tga")
    iconring().save(OUT / "iconring.tga")
    print("wrote", OUT)


if __name__ == "__main__":
    main()

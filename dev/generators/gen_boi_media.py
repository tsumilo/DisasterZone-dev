"""Textures for The Binding of Illidan's doors (Games/Illidan/UI.lua), made from the Black Temple's own art:
  Media/Illidan/door.tga     256 x 256: the gilded door frame (126730) with its middle cut out as an opening down to
                             its foot (the room's side), the cut's edge shaded so the frame reads as a deep moulding
  Media/Illidan/bars.tga     128 x 128: a portcullis - five iron bars (the temple's spiked iron, 128035) with two
                             cross bands and spiked feet, clear between the bars
  Media/Illidan/passage.tga  64 x 64: the dark beyond a doorway - black at the top (the far end) fading out to the
                             bottom (the room's side), darker at the sides
The textures come from dev/art/casc/tex (decoded from the installed client: ui_look / the room tools put them there).
Pictures read top = the door's outer end (into the wall), bottom = the room's side, as UI.lua turns them per side.
Run (from dev): luaenv\\Scripts\\python.exe generators\\gen_boi_media.py"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageEnhance

DEV = Path(__file__).resolve().parents[1]
ADDON = DEV.parent / "addon" / "DisasterZone"
OUT = ADDON / "Media" / "Illidan"
TEX = DEV / "art" / "casc" / "tex"

# the opening, in the frame picture's 0..1: the inner panel's edge, straight down through the foot
OPENING = [(0.225, 0.20), (0.775, 0.20), (0.735, 0.80), (0.735, 1.01), (0.265, 1.01), (0.265, 0.80)]
# the frame's outline: its top under the gem, the sides slanting in, the foot flaring out
SILHOUETTE = [(0.07, 0.045), (0.36, 0.045), (0.40, 0.0), (0.60, 0.0), (0.64, 0.045), (0.93, 0.045), (0.95, 0.10), (0.91, 0.80),
              (0.985, 0.86), (0.985, 1.0), (0.015, 1.0), (0.015, 0.86), (0.09, 0.80), (0.05, 0.10)]


def door():
    src = Image.open(TEX / "fid_126730.png").convert("RGBA").resize((256, 256), Image.LANCZOS)
    S = 256
    poly = [(x * S, y * S) for x, y in OPENING]
    cut = Image.new("L", (S, S), 0)
    ImageDraw.Draw(cut).polygon(poly, fill=255)
    # the moulding's inner face: darker towards the cut (a soft band 10 px wide round it)
    band = cut.filter(ImageFilter.MaxFilter(29)).filter(ImageFilter.GaussianBlur(5))
    dark = ImageEnhance.Brightness(src).enhance(0.22)
    out = Image.composite(dark, src, band)
    # the frame's own silhouette (the picture's square ground cut away), and a soft shadow round it on the wall
    shape = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shape).polygon([(x * S, y * S) for x, y in SILHOUETTE], fill=255)
    shape = shape.filter(ImageFilter.GaussianBlur(0.8))
    solid = Image.composite(shape, Image.new("L", (S, S), 0), Image.eval(cut, lambda v: 255 - v))
    shadow = shape.filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(5)).point(lambda v: int(v * 0.55))
    frame = out.copy()
    frame.putalpha(solid)
    base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    base.putalpha(Image.composite(Image.new("L", (S, S), 0), shadow, cut.filter(ImageFilter.GaussianBlur(0.8))))
    base.alpha_composite(frame)
    base.save(OUT / "door.tga")


def bars():
    S = 128
    iron = Image.open(TEX / "fid_128035.png").convert("RGBA")
    W0 = iron.size[0]
    strip = iron.crop((int(W0 * 0.03), 0, int(W0 * 0.2), iron.size[1])).resize((12, S), Image.LANCZOS)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # each bar lit from the left, dark on the right: a round bar, not a flat strip
    shade = Image.new("L", (12, S))
    for x in range(12):
        v = int(255 * (1.25 - abs(x - 4.5) / 8))
        for y in range(S):
            shade.putpixel((x, y), max(60, min(255, v)))
    bar = Image.composite(strip, ImageEnhance.Brightness(strip).enhance(0.45), shade)
    bar = ImageEnhance.Brightness(bar).enhance(1.15)
    # the spiked foot
    mask = Image.new("L", (12, S), 255)
    d = ImageDraw.Draw(mask)
    d.polygon([(0, S - 16), (0, S), (5.5, S)], fill=0)
    d.polygon([(12, S - 16), (12, S), (6.5, S)], fill=0)
    bar.putalpha(mask)
    for cx in (13, 38, 64, 90, 115):
        out.alpha_composite(bar, (cx - 6, 0))
    # two cross bands, riveted
    band = iron.crop((0, int(iron.size[1] * 0.4), W0, int(iron.size[1] * 0.47))).resize((S, 8), Image.LANCZOS)
    band = ImageEnhance.Brightness(band).enhance(0.9)
    for y in (26, 70):
        out.alpha_composite(band, (0, y))
        d2 = ImageDraw.Draw(out)
        for cx in (13, 38, 64, 90, 115):
            d2.ellipse((cx - 2, y + 2, cx + 2, y + 6), fill=(150, 140, 122, 255))
    out.save(OUT / "bars.tga")


def passage():
    S = 64
    out = Image.new("RGBA", (S, S))
    for y in range(S):
        far = 1 - y / (S - 1)                 # 1 at the far end (top), 0 at the room's side
        for x in range(S):
            side = abs(x - (S - 1) / 2) / ((S - 1) / 2)
            a = min(1, 0.25 + 0.85 * far ** 0.8 + 0.35 * side ** 3)
            out.putpixel((x, y), (6, 4, 3, int(255 * a)))
    out.save(OUT / "passage.tga")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    door()
    bars()
    passage()
    print("wrote", ", ".join(p.name for p in sorted(OUT.glob("*.tga"))))


if __name__ == "__main__":
    main()

"""Draws the README art for both GitHub repositories, in the addon's look (the launcher's Banner header: dark
purple-slate with a gold glow, the DZ seal, Georgia title, gold rule; SLEEK gold buttons; seal-dot dividers).

  luaenv\\Scripts\\python.exe tools\\readme_art.py dev        -> .github/readme/ in this repository
  luaenv\\Scripts\\python.exe tools\\readme_art.py releases   -> assets/ in the releases clone (DisasterZone-releases)

Windows fonts (Georgia Bold, Segoe UI); the seal is launcher/src-tauri/icons/source.png.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SEAL = os.path.join(REPO, "launcher", "src-tauri", "icons", "source.png")
RELEASES_CLONE = os.path.join(os.path.dirname(REPO), "DisasterZone-releases")
FONTS = "C:/Windows/Fonts/"
GEO, SEGB, SEG = FONTS + "georgiab.ttf", FONTS + "seguisb.ttf", FONTS + "segoeui.ttf"
GOLD, GOLD_HI, CREAM = (201, 163, 38), (255, 214, 82), (244, 232, 196)


def glow(size, cx, cy, rx, ry, col, alpha):
    g = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(g)
    for i in range(40, 0, -1):
        t = i / 40
        d.ellipse([cx - rx * t, cy - ry * t, cx + rx * t, cy + ry * t], fill=col + (int(alpha * (1 - t) ** 1.6),))
    return g.filter(ImageFilter.GaussianBlur(30))


def header_bg(w, h):
    im = Image.new("RGBA", (w, h))
    top, bot = (32, 27, 40), (18, 17, 22)
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
    im = Image.alpha_composite(im, glow((w, h), w * 0.18, 0, w * 0.55, h * 1.3, GOLD, 70))
    im = Image.alpha_composite(im, glow((w, h), w * 0.85, h * 1.2, w * 0.45, h * 1.4, (90, 60, 150), 90))
    grain = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    g = ImageDraw.Draw(grain)
    for x in range(-h, w, 14):
        g.line([(x, h), (x + h, 0)], fill=(255, 255, 255, 5), width=4)
    return Image.alpha_composite(im, grain)


def shadow_text(im, xy, txt, font, fill):
    sh = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).text((xy[0] + 4, xy[1] + 4), txt, font=font, fill=(0, 0, 0, 170))
    im.alpha_composite(sh.filter(ImageFilter.GaussianBlur(5)))
    ImageDraw.Draw(im).text(xy, txt, font=font, fill=fill)


def spaced(d, xy, txt, font, fill, track):
    x, y = xy
    for ch in txt:
        d.text((x, y), ch, font=font, fill=fill)
        x += d.textlength(ch, font=font) + track


def banner(path, kicker, subtitle, chip=None):
    w, h = 1600, 420
    im = header_bg(w, h)
    s = 230
    seal = Image.open(SEAL).convert("RGBA").resize((s, s), Image.LANCZOS)
    cx, cy = 150 + s // 2, h // 2 - 6
    im.alpha_composite(glow((w, h), cx, cy, 230, 230, (255, 209, 90), 95))
    sh = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    sh.paste((0, 0, 0, 150), (cx - s // 2 + 6, cy - s // 2 + 10), seal)
    im.alpha_composite(sh.filter(ImageFilter.GaussianBlur(10)))
    im.alpha_composite(seal, (cx - s // 2, cy - s // 2))
    d = ImageDraw.Draw(im)
    x0 = cx + s // 2 + 56
    spaced(d, (x0, 118), kicker, ImageFont.truetype(SEGB, 24), GOLD, 3.2)
    title_font = ImageFont.truetype(GEO, 104)
    shadow_text(im, (x0 - 4, 150), "DisasterZone", title_font, CREAM)
    d = ImageDraw.Draw(im)
    if chip:  # a small outlined tag after the title (e.g. DEV KIT)
        tx = x0 - 4 + d.textlength("DisasterZone", font=title_font) + 28
        f = ImageFont.truetype(SEGB, 26)
        tw = d.textlength(chip, font=f) + 4 * len(chip)
        tag = Image.new("RGBA", im.size, (0, 0, 0, 0))     # (own layer: a translucent fill drawn straight on
        td = ImageDraw.Draw(tag)                             # the banner would replace its pixels)
        td.rounded_rectangle([tx, 196, tx + tw + 36, 244], radius=6, outline=GOLD + (220,), width=2,
                             fill=(255, 209, 0, 22))
        im.alpha_composite(tag)
        d = ImageDraw.Draw(im)
        spaced(d, (tx + 18, 203), chip, f, GOLD_HI, 4)
    d.text((x0, 284), subtitle, font=ImageFont.truetype(SEG, 30), fill=(200, 196, 186))
    d.rectangle([0, h - 4, w, h], fill=GOLD)
    im.convert("RGB").save(path, optimize=True)


def divider(path):
    w, h = 1600, 36
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = w // 2
    for x in range(c - 560, c + 561):
        t = 1 - abs(x - c) / 560
        d.point((x, h // 2), fill=GOLD + (int(255 * t ** 1.3),))
        d.point((x, h // 2 + 1), fill=GOLD + (int(120 * t ** 1.3),))
    for k, (dx, r) in enumerate([(0, 9), (-34, 4), (34, 4), (-60, 3), (60, 3)]):
        x, y = c + dx, h // 2
        if k == 0:
            d.polygon([(x, y - r - 3), (x + r + 3, y), (x, y + r + 3), (x - r - 3, y)], fill=(20, 20, 23, 255))
            d.polygon([(x, y - r), (x + r, y), (x, y + r), (x - r, y)], fill=GOLD_HI + (255,))
        else:
            d.ellipse([x - r, y - r, x + r, y + r], fill=(232, 190, 100, 255))
    im.save(path, optimize=True)


def button(path, label, sub, primary, w=360):
    k = 2
    bw, bh = w * k, 64 * k
    b = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
    if primary:
        top, bot, edge, txt = (133, 96, 18), (77, 52, 8), (204, 158, 43), (255, 238, 196)
    else:
        top, bot, edge, txt = (34, 34, 40), (20, 20, 24), (84, 84, 96), (236, 232, 222)
    grad = Image.new("RGBA", (bw, bh))
    gd = ImageDraw.Draw(grad)
    for y in range(bh):
        t = y / bh
        gd.line([(0, y), (bw, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
    mask = Image.new("L", (bw, bh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, bw - 1, bh - 1], radius=8 * k, fill=255)
    b.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(b)
    d.rounded_rectangle([0, 0, bw - 1, bh - 1], radius=8 * k, outline=edge + (230,), width=2 * k)
    d.line([(10 * k, 3 * k), (bw - 10 * k, 3 * k)], fill=(255, 230, 150, 60) if primary else (255, 255, 255, 22),
           width=k)
    f, fs = ImageFont.truetype(SEGB, 24 * k), ImageFont.truetype(SEG, 15 * k)
    d.text(((bw - d.textlength(label, font=f)) / 2, 9 * k), label, font=f, fill=txt)
    d.text(((bw - d.textlength(sub, font=fs)) / 2, 39 * k), sub, font=fs,
           fill=(235, 205, 140) if primary else (160, 158, 152))
    b.save(path, optimize=True)


def main(which):
    if which == "dev":
        out = os.path.join(REPO, ".github", "readme")
        os.makedirs(out, exist_ok=True)
        banner(os.path.join(out, "banner.png"), "<CASUAL DISASTER>  ·  TBC ANNIVERSARY",
               "Addon source  ·  WoW-mock tests  ·  Releases  ·  Launcher", chip="DEV KIT")
        divider(os.path.join(out, "divider.png"))
    elif which == "releases":
        out = os.path.join(RELEASES_CLONE, "assets")
        os.makedirs(out, exist_ok=True)
        banner(os.path.join(out, "banner.png"), "<CASUAL DISASTER>  ·  TBC ANNIVERSARY",
               "BiS lists  ·  Loot Council  ·  Raids  ·  Strategy boards")
        divider(os.path.join(out, "divider.png"))
        button(os.path.join(out, "btn-windows.png"), "Windows", "Download the setup.exe", True)
        button(os.path.join(out, "btn-macos.png"), "macOS", "Download the .dmg", True)
        button(os.path.join(out, "btn-linux.png"), "Linux", "AppImage or .deb", True)
        button(os.path.join(out, "btn-zip.png"), "Install by hand", "The addon zip, no launcher", False, w=420)
    else:
        raise SystemExit("readme_art.py dev | releases")
    print("written to " + out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "")

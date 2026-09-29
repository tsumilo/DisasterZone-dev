"""Generates the Murloc Defense board textures (32-bit TGA, power-of-two sizes) into
addon/CDLoot/Media/Murloc/. Procedural (noise + shading), so no third-party art is shipped.

Run: luaenv\\Scripts\\python.exe generators\\gen_murloc_textures.py   (needs Pillow + numpy)
"""
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "addon", "CDLoot", "Media", "Murloc")
RNG = np.random.default_rng(1337)


def tile_noise(w, h, scale, octaves=4):
    """Tileable value noise in [0, 1] (sum of wrapped, upsampled random grids)."""
    out = np.zeros((h, w))
    amp, total = 1.0, 0.0
    for o in range(octaves):
        gw, gh = max(2, int(w / scale * 2 ** o)), max(2, int(h / scale * 2 ** o))
        img = Image.fromarray((RNG.random((gh, gw)) * 255).astype(np.uint8))
        big = Image.new("L", (gw * 3, gh * 3))
        for i in range(3):
            for j in range(3):
                big.paste(img, (i * gw, j * gh))
        big = big.resize((w * 3, h * 3), Image.BICUBIC).crop((w, h, 2 * w, 2 * h))
        out += np.asarray(big, dtype=float) / 255 * amp
        total += amp
        amp *= 0.5
    return out / total


def rgba(arr):
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")


def colorize(n, lo, hi, alpha=255):
    lo, hi = np.array(lo, float), np.array(hi, float)
    rgb = lo + (hi - lo) * n[..., None]
    return np.concatenate([rgb, np.full(n.shape + (1,), alpha, float)], axis=2)


def save(img, name):
    os.makedirs(OUT, exist_ok=True)
    img.save(os.path.join(OUT, name + ".tga"))
    print("wrote", name, img.size)


def ground(name, lo, hi, speck, scale=24):
    n = tile_noise(256, 128, scale)
    fine = tile_noise(256, 128, 4, 2)
    n = np.clip(n * 0.75 + fine * 0.35 - 0.05, 0, 1)
    arr = colorize(n, lo, hi)
    arr[RNG.random(n.shape) > 0.985, :3] = speck
    save(rgba(arr), name)


def surf():
    w, h = 128, 128
    n = tile_noise(w, h, 16)
    waves = 0.5 + 0.5 * np.sin((np.linspace(0, 1, w)[None, :] * 4 + n * 1.5) * 2 * np.pi)
    arr = colorize(np.clip(n * 0.6 + waves * 0.4, 0, 1), (20, 60, 110), (60, 140, 190))
    foam = (waves > 0.93) | (n > 0.78)
    arr[foam, :3] = arr[foam, :3] * 0.3 + np.array([230, 240, 245]) * 0.7
    save(rgba(arr), "surf")
    fw, fh = 32, 128
    x = np.linspace(0, 1, fw)[None, :]
    n2 = tile_noise(fw, fh, 8)
    arr = np.zeros((fh, fw, 4))
    arr[..., :3] = 235
    arr[..., 3] = np.clip((x - 0.2 - n2 * 0.4) * 3, 0, 1) * 255 * (0.6 + 0.4 * n2)
    save(rgba(arr), "shore")


def slot():
    s = 64
    img = rgba(colorize(tile_noise(s, s, 8), (70, 64, 56), (120, 112, 98), 150))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, s - 1, 1], fill=(170, 160, 140, 190))
    d.rectangle([0, 0, 1, s - 1], fill=(160, 150, 130, 170))
    d.rectangle([0, s - 3, s - 1, s - 1], fill=(20, 18, 14, 200))
    d.rectangle([s - 3, 0, s - 1, s - 1], fill=(25, 22, 18, 190))
    save(img, "slot")


def blob(name, fn, blur=1):
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    fn(ImageDraw.Draw(img))
    if blur:
        img = img.filter(ImageFilter.GaussianBlur(blur))
    save(img, name)


def rocks(d):
    for _ in range(7):
        cx, cy, r = int(RNG.integers(10, 54)), int(RNG.integers(18, 54)), int(RNG.integers(7, 15))
        sh = int(RNG.integers(80, 130))
        d.ellipse([cx - r, cy - r * 0.8, cx + r, cy + r * 0.8], fill=(sh, sh - 6, sh - 14, 255))
        d.ellipse([cx - r * 0.6, cy - r * 0.7, cx + r * 0.2, cy - r * 0.1], fill=(sh + 50, sh + 45, sh + 35, 200))


def shallows(d):
    d.ellipse([4, 14, 60, 58], fill=(60, 130, 180, 170))
    for i in range(4):
        y = 22 + i * 9
        d.arc([10, y - 4, 54, y + 4], 200, 340, fill=(200, 230, 245, 200), width=1)


def current(d):
    d.rectangle([0, 18, 63, 50], fill=(30, 120, 150, 150))
    for x in (8, 26, 44):
        d.polygon([(x + 12, 26), (x, 34), (x + 12, 42)], fill=(210, 245, 250, 220))


def bonfire(d):
    d.ellipse([10, 40, 54, 58], fill=(60, 40, 25, 230))
    d.ellipse([16, 14, 48, 50], fill=(255, 120, 20, 200))
    d.ellipse([22, 22, 42, 48], fill=(255, 210, 60, 230))
    d.ellipse([28, 32, 36, 46], fill=(255, 255, 200, 255))


def shrine(d):
    d.ellipse([6, 30, 58, 58], outline=(255, 230, 120, 230), width=3)
    d.ellipse([16, 36, 48, 52], outline=(255, 245, 190, 200), width=2)
    d.polygon([(32, 6), (37, 30), (32, 40), (27, 30)], fill=(255, 240, 170, 230))


def glowcap(d):
    d.rectangle([29, 32, 35, 56], fill=(200, 200, 210, 240))
    d.ellipse([14, 16, 50, 40], fill=(90, 200, 230, 230))
    d.ellipse([20, 20, 30, 28], fill=(210, 250, 255, 220))


def bog(d):
    d.ellipse([4, 16, 60, 58], fill=(55, 70, 35, 190))
    for cx, cy in ((20, 30), (40, 40), (30, 48)):
        d.ellipse([cx - 4, cy - 4, cx + 4, cy + 4], outline=(140, 160, 90, 220), width=1)


def shadow(d):
    d.ellipse([4, 20, 60, 44], fill=(0, 0, 0, 170))


def lanefade():
    w, h = 16, 128
    y = np.linspace(-1, 1, h)[:, None]
    arr = np.zeros((h, w, 4))
    arr[..., 3] = np.repeat((np.abs(y) ** 3) * 150, w, axis=1)
    save(rgba(arr), "lanefade")


if __name__ == "__main__":
    ground("sand", (150, 125, 80), (220, 195, 140), (120, 100, 70))
    ground("jungle", (35, 70, 25), (95, 140, 55), (140, 110, 60), scale=18)
    ground("marsh", (35, 45, 55), (80, 90, 120), (120, 200, 220), scale=20)
    surf()
    slot()
    for name, fn in (("rocks", rocks), ("shallows", shallows), ("current", current), ("shrine", shrine),
                     ("glowcap", glowcap), ("bog", bog)):
        blob(name, fn)
    blob("bonfire", bonfire, blur=2)
    blob("shadow", shadow, blur=4)
    lanefade()

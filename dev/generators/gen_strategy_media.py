"""Draws the strategy board's shape textures (Addendum K) into addon/CDLoot/Media/Strategy/.

disc.tga  - a white filled circle with a soft edge (zones, tinted by vertex colour)
ring.tga  - a white circle outline (zone borders)
arrow.tga - a white arrowhead pointing up (arrow ends, rotated in game)
All are 128x128 32-bit TGA (power of two, straight alpha), drawn 4x oversampled for smooth edges.
"""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "addon", "CDLoot", "Media", "Strategy")
SIZE, OS = 128, 4


def shape(draw_fn):
    big = Image.new("L", (SIZE * OS, SIZE * OS), 0)
    draw_fn(ImageDraw.Draw(big), SIZE * OS)
    alpha = big.resize((SIZE, SIZE), Image.LANCZOS)
    img = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
    img.putalpha(alpha)
    return img


def disc(d, n):
    m = n * 0.02
    d.ellipse([m, m, n - m, n - m], fill=255)


def ring(d, n):
    m = n * 0.02
    w = n * 0.06
    d.ellipse([m, m, n - m, n - m], fill=255)
    d.ellipse([m + w, m + w, n - m - w, n - m - w], fill=0)


def arrow(d, n):
    d.polygon([(n * 0.5, n * 0.06), (n * 0.92, n * 0.94), (n * 0.5, n * 0.74), (n * 0.08, n * 0.94)], fill=255)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in (("disc", disc), ("ring", ring), ("arrow", arrow)):
        shape(fn).save(os.path.join(OUT, name + ".tga"))
        print("wrote", name)

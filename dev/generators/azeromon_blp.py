"""Palette BLP2 (256 colours, 8-bit alpha when needed) for Azeromon's baked art: lossless for pixel art with at most
256 colours (nearly every baked picture), a quarter of a 32-bit TGA's size (a third of a 24-bit one). Pictures with
more colours are reduced to their best 256 (the battle backdrops' haze); `write` says how many colours it kept.

Layout (BLP2, encoding 1): "BLP2", type 1, encoding 1, alpha depth (0 or 8), alpha type, has mips; width, height;
16 mip offsets, 16 mip sizes; a 256-entry BGRA palette; then per mip the colour indices (w * h bytes) followed by the
alpha bytes (w * h when the depth is 8). Mips are made by nearest-neighbour halving, so every mip pixel is a palette
colour. `read` decodes what `write` wrote (tests and preview tools)."""
import struct

import numpy as np
from PIL import Image


def _palette(rgb):
    """(H, W, 3) uint8 -> (indices (H, W) uint8, palette (n, 3)), exact when n <= 256"""
    flat = rgb.reshape(-1, 3)
    key = (flat[:, 0].astype(np.uint32) << 16) | (flat[:, 1].astype(np.uint32) << 8) | flat[:, 2]
    uniq, inv = np.unique(key, return_inverse=True)
    if len(uniq) <= 256:
        pal = np.stack([(uniq >> 16) & 255, (uniq >> 8) & 255, uniq & 255], 1).astype(np.uint8)
        return inv.reshape(rgb.shape[:2]).astype(np.uint8), pal, True
    q = Image.fromarray(rgb, "RGB").quantize(256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    pal = np.array(q.getpalette()[:768], dtype=np.uint8).reshape(-1, 3)
    return np.array(q, dtype=np.uint8), pal, False


def write(img, path):
    """img: PIL image (RGB or RGBA). Returns (colours, exact)."""
    rgba = np.array(img.convert("RGBA"))
    has_alpha = bool((rgba[..., 3] < 255).any()) or img.mode == "RGBA"
    idx, pal, exact = _palette(rgba[..., :3].copy())
    alpha = rgba[..., 3]
    h, w = idx.shape
    mips = []
    ci, ca = idx, alpha
    while True:
        mips.append(ci.tobytes() + (ca.tobytes() if has_alpha else b""))
        if ci.shape[0] == 1 and ci.shape[1] == 1:
            break
        ci = ci[::2, ::2] if ci.shape[0] > 1 and ci.shape[1] > 1 else (ci[:, ::2] if ci.shape[0] == 1 else ci[::2, :])
        ca = ca[::2, ::2] if ca.shape[0] > 1 and ca.shape[1] > 1 else (ca[:, ::2] if ca.shape[0] == 1 else ca[::2, :])
        if len(mips) == 16:
            break
    header = 4 + 4 + 4 + 8 + 16 * 4 * 2 + 256 * 4
    offsets, sizes, pos = [], [], header
    for m in mips:
        offsets.append(pos)
        sizes.append(len(m))
        pos += len(m)
    offsets += [0] * (16 - len(offsets))
    sizes += [0] * (16 - len(sizes))
    palette = bytearray(1024)
    for i, (r, g, b) in enumerate(pal):
        palette[i * 4:i * 4 + 4] = bytes((int(b), int(g), int(r), 255))
    with open(path, "wb") as f:
        f.write(b"BLP2")
        f.write(struct.pack("<I", 1))
        f.write(struct.pack("<BBBB", 1, 8 if has_alpha else 0, 8 if has_alpha else 0, 1))
        f.write(struct.pack("<II", w, h))
        f.write(struct.pack("<16I", *offsets))
        f.write(struct.pack("<16I", *sizes))
        f.write(bytes(palette))
        for m in mips:
            f.write(m)
    return len(pal), exact


def read(path):
    """the top mip of a palette BLP written by `write` -> PIL RGBA image"""
    data = open(path, "rb").read()
    assert data[:4] == b"BLP2", path
    enc, adepth = data[8], data[9]
    assert enc == 1, (path, enc)
    w, h = struct.unpack_from("<II", data, 12)
    off = struct.unpack_from("<16I", data, 20)[0]
    pal = np.frombuffer(data, dtype=np.uint8, count=1024, offset=148).reshape(256, 4)
    idx = np.frombuffer(data, dtype=np.uint8, count=w * h, offset=off).reshape(h, w)
    out = np.zeros((h, w, 4), dtype=np.uint8)
    out[..., 0], out[..., 1], out[..., 2] = pal[idx, 2], pal[idx, 1], pal[idx, 0]
    if adepth == 8:
        out[..., 3] = np.frombuffer(data, dtype=np.uint8, count=w * h, offset=off + w * h).reshape(h, w)
    else:
        out[..., 3] = 255
    return Image.fromarray(out, "RGBA")


def size(path):
    data = open(path, "rb").read(20)
    return struct.unpack_from("<II", data, 12)

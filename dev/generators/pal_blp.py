"""Palette BLP2 the way this client's own palette textures are made (2026-10-17, Azeromon's pixel beasts).

azeromon_blp.py (2026-10-14) wrote palette BLPs that the client drew as its missing-texture square. Scanning 3,600
of the client's own BLP2 files: 940 are palette textures and nearly all of them carry a FULL mip chain (down to 1x1)
with alpha type 8 and palette entries whose alpha byte is 0; azeromon_blp wrote no mips and alpha 255. This writer
copies the client's layout exactly (checked against FileDataIDs 122690 = 1-bit alpha, 118606 = 8-bit alpha):

  "BLP2", type 1, encoding 1 (palette), alpha depth 1 or 8, alpha type 8, has mips 1;
  width, height (powers of two); 16 mip offsets, 16 mip sizes; 256 x BGRA palette (A = 0);
  per mip: w*h colour indices, then the alpha plane (1 bit a pixel, low bit first, or 1 byte a pixel).

Mips are made by nearest-neighbour halving, so every mip pixel is a palette colour (the game draws the beasts
magnified with nearest filtering, so mips are never shown). Lossless for pictures with up to 256 colours."""
import struct

import numpy as np
from PIL import Image


def palettize(rgba, max_colours=256):
    """(H, W, 4) uint8 with hard alpha -> (indices (H, W) uint8, palette (n, 3) uint8). Transparent pixels use
    index 0's colour slot only through their alpha; colours come from opaque pixels."""
    rgb = rgba[..., :3].reshape(-1, 3)
    op = rgba[..., 3].reshape(-1) > 127
    key = (rgb[:, 0].astype(np.uint32) << 16) | (rgb[:, 1].astype(np.uint32) << 8) | rgb[:, 2]
    key = np.where(op, key, 0)
    uniq, inv = np.unique(key, return_inverse=True)
    if len(uniq) > max_colours:
        raise ValueError("%d colours (max %d): quantize first" % (len(uniq), max_colours))
    pal = np.stack([(uniq >> 16) & 255, (uniq >> 8) & 255, uniq & 255], 1).astype(np.uint8)
    return inv.reshape(rgba.shape[:2]).astype(np.uint8), pal


def _alpha_plane(a, depth):
    if depth == 8:
        return np.where(a, 255, 0).astype(np.uint8).tobytes()
    bits = a.reshape(-1).astype(np.uint8)
    pad = (-len(bits)) % 8
    if pad:
        bits = np.concatenate([bits, np.zeros(pad, np.uint8)])
    return np.packbits(bits.reshape(-1, 8), axis=1, bitorder="little").reshape(-1).tobytes()


def write(img, path, alpha_depth=1):
    """img: RGBA (hard alpha), sides powers of two, at most 256 colours. Returns the number of colours."""
    rgba = np.asarray(img.convert("RGBA"), np.uint8)
    h, w = rgba.shape[:2]
    assert w & (w - 1) == 0 and h & (h - 1) == 0, (w, h)
    idx, pal = palettize(rgba)
    alpha = rgba[..., 3] > 127
    levels = []
    ci, ca = idx, alpha
    while True:
        levels.append(ci.tobytes() + _alpha_plane(ca, alpha_depth))
        if ci.shape[0] == 1 and ci.shape[1] == 1:
            break
        ys = slice(None, None, 2) if ci.shape[0] > 1 else slice(None)
        xs = slice(None, None, 2) if ci.shape[1] > 1 else slice(None)
        ci, ca = ci[ys, xs], ca[ys, xs]
    header = 148 + 1024
    offsets, sizes, pos = [], [], header
    for m in levels:
        offsets.append(pos)
        sizes.append(len(m))
        pos += len(m)
    offsets += [0] * (16 - len(offsets))
    sizes += [0] * (16 - len(sizes))
    palette = bytearray(1024)
    for i, (r, g, b) in enumerate(pal):
        palette[i * 4:i * 4 + 4] = bytes((int(b), int(g), int(r), 0))
    with open(path, "wb") as f:
        f.write(b"BLP2")
        f.write(struct.pack("<I", 1))
        f.write(struct.pack("<BBBB", 1, alpha_depth, 8, 1))
        f.write(struct.pack("<II", w, h))
        f.write(struct.pack("<16I", *offsets[:16]))
        f.write(struct.pack("<16I", *sizes[:16]))
        f.write(bytes(palette))
        for m in levels:
            f.write(m)
    return len(pal)


def read(path):
    """mip 0 of a palette BLP2 (1- or 8-bit alpha) -> RGBA. Decodes independently of write (tests, previews)."""
    d = open(path, "rb").read()
    assert d[:4] == b"BLP2" and d[8] == 1, path
    depth = d[9]
    w, h = struct.unpack_from("<II", d, 12)
    off = struct.unpack_from("<16I", d, 20)[0]
    pal = np.frombuffer(d, np.uint8, 1024, 148).reshape(256, 4)[:, [2, 1, 0]]
    idx = np.frombuffer(d, np.uint8, w * h, off).reshape(h, w)
    if depth == 8:
        a = np.frombuffer(d, np.uint8, w * h, off + w * h).reshape(h, w)
    elif depth == 1:
        raw = np.frombuffer(d, np.uint8, (w * h + 7) // 8, off + w * h)
        a = np.unpackbits(raw, bitorder="little")[:w * h].reshape(h, w) * 255
    else:
        a = np.full((h, w), 255, np.uint8)
    out = np.zeros((h, w, 4), np.uint8)
    out[..., :3] = pal[idx]
    out[..., 3] = a
    return Image.fromarray(out, "RGBA")

"""BLP2 writers for the Azeromon world's textures: DXT1 (opaque: the ground) and DXT5 (with alpha: scenery and
character sprites), full mip chains. The colour blocks use gen_raid_maps' DXT1 encoder (principal axis endpoints);
DXT5 adds an interpolated 8-step alpha block per 4x4 block, and transparent pixels do not pull the colour ends."""
import struct

import numpy as np
from PIL import Image

from gen_raid_maps import dxt1, from565, to565


def _blocks(a, ch):
    h, w = a.shape[:2]
    return a.reshape(h // 4, 4, w // 4, 4, ch).transpose(0, 2, 1, 3, 4).reshape(-1, 16, ch)


def _alpha_blocks(alpha):
    """alpha (h, w) uint8 -> DXT5 alpha blocks bytes (n x 8)."""
    b = _blocks(alpha[..., None].astype(np.int32), 1)[..., 0]           # n, 16
    a0, a1 = b.max(1), b.min(1)
    same = a0 == a1
    a0 = np.where(same & (a0 < 255), a0 + 1, a0)
    a1 = np.where(same & (a0 >= 255), a1 - 1, a1).clip(0, 255)
    pal = np.stack([a0, a1] + [((7 - k) * a0 + k * a1) // 7 for k in range(1, 7)], 1)   # n, 8 (a0 > a1 mode)
    idx = np.abs(b[:, :, None] - pal[:, None, :]).argmin(-1).astype(np.uint64)            # n, 16
    bits = np.zeros(b.shape[0], np.uint64)
    for k in range(16):
        bits |= idx[:, k] << np.uint64(3 * k)
    out = np.zeros((b.shape[0], 8), np.uint8)
    out[:, 0] = a0
    out[:, 1] = a1
    for k in range(6):
        out[:, 2 + k] = ((bits >> np.uint64(8 * k)) & np.uint64(255)).astype(np.uint8)
    return out


def _dxt5(img):
    rgba = np.asarray(img.convert("RGBA"), np.uint8).copy()
    h, w = rgba.shape[:2]
    # transparent pixels take the mean of the opaque ones in their block (so they do not bend the colour line)
    blk = _blocks(rgba.astype(np.float64), 4)
    op = blk[..., 3:4] > 8
    mean = (blk[..., :3] * op).sum(1, keepdims=True) / np.maximum(op.sum(1, keepdims=True), 1)
    blk[..., :3] = np.where(op, blk[..., :3], mean)
    rgb = blk[..., :3].reshape(h // 4, w // 4, 4, 4, 3).transpose(0, 2, 1, 3, 4).reshape(h, w, 3)
    col = np.frombuffer(dxt1(Image.fromarray(rgb.astype(np.uint8), "RGB")), np.uint8).reshape(-1, 8)
    alp = _alpha_blocks(rgba[..., 3])
    return np.concatenate([alp, col], 1).tobytes()


def _write(img, path, alpha):
    w, h = img.size
    mips, cur = [], img
    while True:
        mips.append(_dxt5(cur) if alpha else dxt1(cur))
        if cur.size[0] <= 4 or cur.size[1] <= 4:
            break
        cur = cur.resize((max(4, cur.size[0] // 2), max(4, cur.size[1] // 2)), Image.LANCZOS)
    header = 4 + 4 + 4 + 8 + 16 * 4 * 2 + 256 * 4
    offsets, sizes, pos = [], [], header
    for m in mips[:16]:
        offsets.append(pos)
        sizes.append(len(m))
        pos += len(m)
    offsets += [0] * (16 - len(offsets))
    sizes += [0] * (16 - len(sizes))
    with open(path, "wb") as f:
        f.write(b"BLP2")
        f.write(struct.pack("<I", 1))
        if alpha:
            f.write(struct.pack("<BBBB", 2, 8, 7, 1))       # DXTC, 8-bit alpha, DXT5, mips
        else:
            f.write(struct.pack("<BBBB", 2, 0, 0, 1))       # DXTC, no alpha, DXT1, mips
        f.write(struct.pack("<II", w, h))
        f.write(struct.pack("<16I", *offsets))
        f.write(struct.pack("<16I", *sizes))
        f.write(b"\0" * 1024)
        for m in mips[:16]:
            f.write(m)


def write_dxt1(img, path):
    _write(img.convert("RGB"), path, False)


def write_dxt5(img, path):
    _write(img.convert("RGBA"), path, True)

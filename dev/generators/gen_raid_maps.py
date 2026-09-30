"""Raid floor maps for the strategy boards (Addendum K).

The Anniversary client has no raid map art of its own, so CDLoot ships Blizzard's floor maps (as hosted by wowhead,
downloaded once into dev/art/blizzard_maps/<zone>-<floor>.jpg, 1009 x 673). This script turns each one into two
power-of-two DXT1 BLP2 textures with mipmaps (WoW's own compressed format):
    <name>_a.blp  1024 x 512  (rows 0-511 of the map scaled to 1024 x 683)
    <name>_b.blp  1024 x 256  (rows 512-682, the rest padded)
into addon/CDLoot/Media/Maps/, and writes the list the map picker reads (Data/RaidMaps.lua).
Run: luaenv\\Scripts\\python.exe generators\\gen_raid_maps.py   (needs numpy + Pillow)
"""
import io
import os
import struct

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "art", "blizzard_maps")
ADDON = os.path.join(HERE, "..", "..", "addon", "CDLoot")
OUT = os.path.join(ADDON, "Media", "Maps")
DATA = os.path.join(ADDON, "Data", "RaidMaps.lua")

W, H = 1024, 683

# (source file, texture name, raid key, label, bosses that start on it)
MAPS = [
    ("3457-1", "Kara01", "Karazhan", "Karazhan - Servants' Quarters", ["Attumen", "Rokad", "Shadikith", "Hyakiss"]),
    ("3457-2", "Kara02", "Karazhan", "Karazhan - Upper Livery Stables", []),
    ("3457-3", "Kara03", "Karazhan", "Karazhan - Banquet Hall", ["Moroes"]),
    ("3457-4", "Kara04", "Karazhan", "Karazhan - Guest Chambers", ["Maiden", "OperaOz", "OperaWolf", "OperaRomulo"]),
    ("3457-5", "Kara05", "Karazhan", "Karazhan - Opera Hall Balcony", []),
    ("3457-6", "Kara06", "Karazhan", "Karazhan - Master's Terrace", ["Nightbane"]),
    ("3457-7", "Kara07", "Karazhan", "Karazhan - Lower Broken Stair", []),
    ("3457-8", "Kara08", "Karazhan", "Karazhan - Upper Broken Stair", []),
    ("3457-9", "Kara09", "Karazhan", "Karazhan - The Menagerie", ["Curator"]),
    ("3457-10", "Kara10", "Karazhan", "Karazhan - Guardian's Library", ["Illhoof"]),
    ("3457-11", "Kara11", "Karazhan", "Karazhan - Library Floor", ["Aran"]),
    ("3457-12", "Kara12", "Karazhan", "Karazhan - Upper Library", []),
    ("3457-13", "Kara13", "Karazhan", "Karazhan - The Repository", ["Netherspite"]),
    ("3457-14", "Kara14", "Karazhan", "Karazhan - Gamesman's Hall", ["Chess"]),
    ("3457-15", "Kara15", "Karazhan", "Karazhan - Celestial Watch", []),
    ("3457-16", "Kara16", "Karazhan", "Karazhan - Medivh's Chambers", []),
    ("3457-17", "Kara17", "Karazhan", "Karazhan - Netherspace", ["Prince"]),
    ("3923-1", "Gruul", "GruulsLair", "Gruul's Lair", ["Maulgar", "Gruul"]),
    ("3836-1", "Magtheridon", "MagtheridonsLair", "Magtheridon's Lair", ["Magtheridon"]),
    ("3607-1", "Serpentshrine", "SerpentshrineCavern", "Serpentshrine Cavern",
     ["Hydross", "Lurker", "Leotheras", "Karathress", "Morogrim", "Vashj"]),
    ("3845-1", "TheEye", "TempestKeep", "Tempest Keep - The Eye", ["Alar", "VoidReaver", "Solarian", "Kaelthas"]),
    ("3606", "Hyjal", "HyjalSummit", "Hyjal Summit",
     ["Winterchill", "Anetheron", "Kazrogal", "Azgalor", "Archimonde"]),
    ("3959", "BT00", "BlackTemple", "Black Temple - Illidari Training Grounds", ["Supremus"]),
    ("3959-1", "BT01", "BlackTemple", "Black Temple - Karabor Sewers", ["Najentus"]),
    ("3959-2", "BT02", "BlackTemple", "Black Temple - Sanctuary of Shadows", ["ShadeOfAkama"]),
    ("3959-3", "BT03", "BlackTemple", "Black Temple - Halls of Anguish", ["Reliquary"]),
    ("3959-4", "BT04", "BlackTemple", "Black Temple - Gorefiend's Vigil", ["Teron", "Bloodboil"]),
    ("3959-5", "BT05", "BlackTemple", "Black Temple - Den of Mortal Delights", ["Shahraz"]),
    ("3959-6", "BT06", "BlackTemple", "Black Temple - Chamber of Command", ["Council"]),
    ("3959-7", "BT07", "BlackTemple", "Black Temple - Temple Summit", ["Illidan"]),
    ("3805", "ZulAman", "ZulAman", "Zul'Aman", ["Akilzon", "Nalorakk", "Janalai", "Halazzi", "Malacrass", "Zuljin"]),
    ("4075-1", "Sunwell", "SunwellPlateau", "Sunwell Plateau",
     ["Kalecgos", "Brutallus", "Felmyst", "EredarTwins", "Muru", "Kiljaeden"]),
]


# ---------------------------------------------------------------------------------------------------------------
# DXT1 (BC1) encoder: principal axis endpoints per 4x4 block, 4-colour mode
# ---------------------------------------------------------------------------------------------------------------

def to565(c):
    c = np.clip(np.rint(c), 0, 255).astype(np.int32)
    return ((c[..., 0] >> 3) << 11) | ((c[..., 1] >> 2) << 5) | (c[..., 2] >> 3)


def from565(v):
    r = ((v >> 11) & 31) * 255 / 31
    g = ((v >> 5) & 63) * 255 / 63
    b = (v & 31) * 255 / 31
    return np.stack([r, g, b], -1)


def dxt1(img):
    a = np.asarray(img.convert("RGB"), dtype=np.float64)
    h, w, _ = a.shape
    ph, pw = max(4, (h + 3) // 4 * 4), max(4, (w + 3) // 4 * 4)
    if (ph, pw) != (h, w):
        pad = np.zeros((ph, pw, 3))
        pad[:h, :w] = a
        pad[h:, :w] = a[h - 1:h, :, :] if h else 0
        pad[:, w:] = pad[:, w - 1:w]
        a = pad
    by, bx = ph // 4, pw // 4
    blocks = a.reshape(by, 4, bx, 4, 3).transpose(0, 2, 1, 3, 4).reshape(-1, 16, 3)
    mean = blocks.mean(1, keepdims=True)
    d = blocks - mean
    cov = np.einsum("nki,nkj->nij", d, d)
    axis = np.ones((blocks.shape[0], 3)) / np.sqrt(3)
    for _ in range(6):
        axis = np.einsum("nij,nj->ni", cov, axis)
        norm = np.linalg.norm(axis, axis=1, keepdims=True)
        axis = np.where(norm > 1e-9, axis / np.maximum(norm, 1e-9), 1 / np.sqrt(3))
    proj = np.einsum("nki,ni->nk", d, axis)
    lo, hi = proj.min(1), proj.max(1)
    inset = (hi - lo) / 16
    c0 = mean[:, 0] + axis * (hi - inset)[:, None]
    c1 = mean[:, 0] + axis * (lo + inset)[:, None]
    e0, e1 = to565(c0), to565(c1)
    swap = e0 < e1
    e0, e1 = np.where(swap, e1, e0), np.where(swap, e0, e1)
    p0, p1 = from565(e0), from565(e1)
    pal = np.stack([p0, p1, (2 * p0 + p1) / 3, (p0 + 2 * p1) / 3], 1)          # n, 4, 3
    dist = ((blocks[:, :, None, :] - pal[:, None, :, :]) ** 2).sum(-1)       # n, 16, 4
    idx = dist.argmin(-1)
    idx = np.where((e0 == e1)[:, None], 0, idx)
    bits = np.zeros(blocks.shape[0], dtype=np.uint64)
    for k in range(16):
        bits |= idx[:, k].astype(np.uint64) << np.uint64(2 * k)
    out = np.zeros((blocks.shape[0], 8), dtype=np.uint8)
    out[:, 0] = e0 & 255
    out[:, 1] = e0 >> 8
    out[:, 2] = e1 & 255
    out[:, 3] = e1 >> 8
    for k in range(4):
        out[:, 4 + k] = ((bits >> np.uint64(8 * k)) & np.uint64(255)).astype(np.uint8)
    return out.tobytes()


def write_blp(img, path):
    """BLP2, DXT1, no alpha, full mip chain."""
    w, h = img.size
    mips = []
    cur = img
    while True:
        mips.append(dxt1(cur))
        if cur.size == (1, 1):
            break
        cur = cur.resize((max(1, cur.size[0] // 2), max(1, cur.size[1] // 2)), Image.LANCZOS)
    header_size = 4 + 4 + 4 + 4 + 4 + 16 * 4 + 16 * 4 + 256 * 4
    offsets, sizes = [], []
    pos = header_size
    for m in mips[:16]:
        offsets.append(pos)
        sizes.append(len(m))
        pos += len(m)
    offsets += [0] * (16 - len(offsets))
    sizes += [0] * (16 - len(sizes))
    with open(path, "wb") as f:
        f.write(b"BLP2")
        f.write(struct.pack("<I", 1))                    # type: DirectX compression family
        f.write(struct.pack("<BBBB", 2, 0, 0, 1))        # compression DXTC, alpha depth 0, alpha type DXT1, has mips
        f.write(struct.pack("<II", w, h))
        f.write(struct.pack("<16I", *offsets))
        f.write(struct.pack("<16I", *sizes))
        f.write(b"\0" * 1024)                            # palette (unused)
        for m in mips[:16]:
            f.write(m)


def main():
    os.makedirs(OUT, exist_ok=True)
    lines = [
        "-- CDLoot: the raid floor maps of the strategy boards (Media/Maps/<file>_a / _b.blp: the top 1024 x 512 and",
        "-- the bottom 1024 x 256 of each map scaled to 1024 x 683). Blizzard's map art as hosted by wowhead; see NOTICE.md.",
        "-- AUTO-GENERATED by gen_raid_maps.py; do not edit by hand.",
        "local _, ns = ...",
        "ns.Data = ns.Data or {}",
        "ns.Data.RaidMaps = {",
    ]
    total = 0
    for i, (src, name, raid, label, bosses) in enumerate(MAPS):
        img = Image.open(os.path.join(SRC, src + ".jpg")).convert("RGB").resize((W, H), Image.LANCZOS)
        top = img.crop((0, 0, 1024, 512))
        bottom = Image.new("RGB", (1024, 256))
        bottom.paste(img.crop((0, 512, 1024, H)), (0, 0))
        for part, im in (("a", top), ("b", bottom)):
            p = os.path.join(OUT, "%s_%s.blp" % (name, part))
            write_blp(im, p)
            total += os.path.getsize(p)
        lines.append('  { id = %d, file = "%s", raid = "%s", name = "%s", bosses = { %s } },' % (
            900101 + i, name, raid, label.replace('"', '\\"'), ", ".join('"%s"' % b for b in bosses)))
    lines.append("}")
    open(DATA, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print("maps: %d, %.1f MB" % (len(MAPS), total / 1e6))
    # self-check: Pillow reads DXT1 BLP2
    chk = Image.open(os.path.join(OUT, "BT06_a.blp"))
    chk.load()
    chk.convert("RGB").save(os.path.join(HERE, "..", "art", "maps_probe", "check_BT06_a.png"))
    print("check:", chk.size, chk.mode)


if __name__ == "__main__":
    main()

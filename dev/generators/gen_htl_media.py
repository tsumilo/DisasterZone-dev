"""Hold the Line (Games/HoldTheLine): its media, from the mockup's own art (dev/art/casc/survivors_mockup), so the
game draws exactly what the mockup drew.

  Media/HoldTheLine/Units/<unit>_<n>.blp  the units' frames (game models rendered in 8 facings: walk, death, attack,
                                          gen_sprites.py), scaled to the game's size (1 texel = 1 world unit),
                                          trimmed and packed into power-of-two DXT5 pages (<= 2048)
  Media/HoldTheLine/Props_<n>.blp         the Plaguelands doodads, the same way
  Media/HoldTheLine/FX/<name>.tga         the spell textures taken from the client's spell models (catalog/), with
                                          their backgrounds crushed to black / their edge alpha to zero, plus the
                                          round frost and lava discs
  Media/HoldTheLine/ground.blp            the Eastern Plaguelands ground (1024, tiles), DXT1
  Media/HoldTheLine/fog.blp               the plague fog (512, tiles), DXT5
  Media/HoldTheLine/UI/<name>.tga         the painted rune crystals and ice spikes (padded to powers of two)
  Games/HoldTheLine/Art.lua               where every frame / prop / texture sits, and the client UI crops

Run from dev: luaenv\\Scripts\\python.exe generators\\gen_htl_media.py [units] [props] [fx] [ui] [ground] (default all)"""
import json
import math
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import azw_blp  # noqa: E402

DEV = HERE.parent
ADDON = DEV.parent / "addon" / "DisasterZone"
MOCK = DEV / "art" / "casc" / "survivors_mockup"
ART = MOCK / "art"
SITE = MOCK / "site" / "art"
OUT = ADDON / "Media" / "HoldTheLine"
LUA = ADDON / "Games" / "HoldTheLine" / "Art.lua"
GAME = "Interface\\\\AddOns\\\\DisasterZone\\\\Media\\\\HoldTheLine\\\\"
S = 0.6            # render px -> world units (the mockup's S)
PAGE = 2048
NAXX = MOCK / "naxx" / "site"      # the Naxxramas mockup's art (pack_naxx.py): its cleaned spell textures
# Naxxramas's models come in at their own render sizes: each is scaled so its body (the south-facing first walk
# frame) is this many world units tall (a hero is ~47, a ghoul ~60, the Lich ~113)
BODY = {
    "n_spider": 26, "n_creeper": 40, "n_spinner": 44, "n_venom": 50, "n_cryptguard": 72, "n_worshipper": 47, "n_follower": 47,
    "n_infghoul": 50, "n_grub": 40, "n_frenzbat": 38, "n_plaguebeast": 78, "n_gargoyle": 46,
    "n_understudy": 48, "n_trainee": 46, "n_rider": 56, "n_bony": 74, "n_smith": 48, "n_necroknight": 50, "n_shade": 64,
    "n_golem": 82, "n_belcher": 62, "n_monstrosity": 62, "n_scientist": 50, "n_slime": 34, "n_chow": 48,
    "n_soldier": 46, "n_guardian": 96,
    "n_anub": 100, "n_faerlina": 56, "n_maexxna": 92, "n_noth": 58, "n_heigan": 60, "n_loatheb": 112, "n_razuvious": 60,
    "n_gothik": 60, "n_korthazz": 92, "n_blaumeux": 92, "n_mograine": 92, "n_zeliek": 92, "n_patchwerk": 124, "n_grobbulus": 112,
    "n_gluth": 112, "n_stalagg": 100, "n_thaddius": 140, "n_sapphiron": 150, "n_kelthuzad": 112,
}
NAXX_FX = ["web", "webspin", "bone", "dust", "cloud", "smoke_dark", "swarm_cloud", "insect_a", "insect_b", "green_glow", "green_drops",
           "slime", "poison_sheet", "poison_ring", "shadow_glyph2", "shadow_ring", "shadow_ring2", "purple_star", "red_star", "curse_skull",
           "tele_star", "tele_ring", "ice_burst", "ice_blue", "frost_cloud2", "snow2", "lightning_h", "lightning_b", "lightning_hit",
           "meteor_fire", "meteor_rock", "bomb", "flames", "beam", "portal_ring", "void_orb", "dnd", "spikes", "rf_ring", "cone",
           "green_ring", "blizz", "ice_tex", "frost_ring", "seep", "starx"]


def body_px(sheet, W, H):
    a = np.asarray(sheet.crop((0, 2 * H, W, 3 * H)))[:, :, 3]
    ys = np.nonzero(a.max(axis=1) > 40)[0]
    return (ys.max() - ys.min() + 1) if len(ys) else H


def pow2(n):
    p = 4
    while p < n:
        p *= 2
    return p


def write_dxt5_flat(img, path):
    """BLP2 DXT5 without mips (sprites are drawn at about their own size; as gen_dc_outfits)."""
    import struct
    from azw_blp import _dxt5
    pic = img.convert("RGBA")
    w, h = pic.size
    data = _dxt5(pic)
    header = 4 + 4 + 4 + 8 + 16 * 4 * 2 + 256 * 4
    with open(path, "wb") as f:
        f.write(b"BLP2")
        f.write(struct.pack("<I", 1))
        f.write(struct.pack("<BBBB", 2, 8, 7, 0))
        f.write(struct.pack("<II", w, h))
        f.write(struct.pack("<16I", header, *([0] * 15)))
        f.write(struct.pack("<16I", len(data), *([0] * 15)))
        f.write(bytes(1024))
        f.write(data)


def write_tga(img, path):
    """Uncompressed 32-bit TGA (what the client reads; Illidan's media are the same)."""
    img.convert("RGBA").save(path)


class Packer:
    """Shelf packing into power-of-two pages; pieces start on 4 px boundaries (DXT blocks never mix two pieces)."""
    def __init__(self, maxw=PAGE):
        self.maxw = maxw
        self.pages = []

    def best_width(self, order):
        best = None
        for width in (256, 512, 1024, 2048):
            if max(im.width for _, im in order) + 4 > width:
                continue
            x = y = shelf = 0
            pages = 1
            for _, im in order:
                w, h = (im.width + 7) // 4 * 4, (im.height + 7) // 4 * 4
                if x + w > width:
                    x, y, shelf = 0, y + shelf, 0
                if y + h > self.maxw:
                    pages, x, y, shelf = pages + 1, 0, 0, 0
                x += w
                shelf = max(shelf, h)
            cost = (pages - 1) * width * self.maxw + width * pow2(y + shelf)
            if best is None or cost < best[0]:
                best = (cost, width)
        return best[1]

    def pack(self, pieces):
        """pieces: [(key, image)] -> {key: (page, x, y)}; tallest first."""
        order = sorted(pieces, key=lambda kv: -kv[1].height)
        area = sum(((im.width + 7) // 4 * 4) * ((im.height + 7) // 4 * 4) for _, im in pieces)
        width = self.best_width(order)
        out, page, x, y, shelf = {}, None, 0, 0, 0

        def new_page():
            p = {"w": width, "items": []}
            self.pages.append(p)
            return p
        page = new_page()
        for key, im in order:
            w, h = (im.width + 7) // 4 * 4, (im.height + 7) // 4 * 4
            if x + w > width:
                x, y, shelf = 0, y + shelf, 0
            if y + h > self.maxw:
                page, x, y, shelf = new_page(), 0, 0, 0
            page["items"].append((key, im, x + 2, y + 2))
            out[key] = (len(self.pages) - 1, x + 2, y + 2)
            x += w
            shelf = max(shelf, h)
            page["h"] = max(page.get("h", 0), y + shelf)
        return out

    def images(self):
        for p in self.pages:
            img = Image.new("RGBA", (p["w"], pow2(p["h"])), (0, 0, 0, 0))
            for _, im, x, y in p["items"]:
                img.paste(im, (x, y))
            yield img


def lua_num(v):
    return str(int(v)) if float(v).is_integer() else ("%.3f" % v).rstrip("0").rstrip(".")


# ---------------------------------------------------------------------------------------------------------------
def units():
    meta = json.load(open(ART / "units.json"))
    (OUT / "Units").mkdir(parents=True, exist_ok=True)
    rows = []
    for key, m in sorted(meta.items()):
        sheet = Image.open(ART / "units" / (key + ".png")).convert("RGBA")
        W, H = m["w"], m["h"]
        cols = sheet.width // W
        k = BODY[key] / body_px(sheet, W, H) if key in BODY else S
        big = m["atk"] > 0
        pieces, frames = [], []
        for d in range(8):
            for c in range(cols):
                if big and m["walk"] <= c < m["walk"] + m["death"] and d != 2:
                    frames.append(("alias", 2 * cols + c))
                    continue
                cell = sheet.crop((c * W, d * H, (c + 1) * W, (d + 1) * H))
                cw, chh = max(1, round(W * k)), max(1, round(H * k))
                cell = cell.resize((cw, chh), Image.LANCZOS)
                bb = cell.split()[3].point(lambda v: 255 if v > 6 else 0).getbbox() or (0, 0, 1, 1)
                piece = cell.crop(bb)
                pieces.append((d * cols + c, piece))
                frames.append(("own", d * cols + c, piece.width, piece.height, bb[0] - m["ox"] * k, bb[1] - m["oy"] * k))
        pk = Packer()
        at = pk.pack(pieces)
        names = []
        for i, img in enumerate(pk.images()):
            name = "%s_%d" % (key, i + 1)
            write_dxt5_flat(img, OUT / "Units" / (name + ".blp"))
            names.append((name, img.width, img.height))
        flat = []
        for fr in frames:
            if fr[0] == "alias":
                flat.append(None)
                continue
            _, ki, w, h, dx, dy = fr
            p, x, y = at[ki]
            flat.append((p + 1, x, y, w, h, dx, dy))
        for i, fr in enumerate(frames):
            if fr[0] == "alias":
                flat[i] = flat[fr[1]]
        pages = ", ".join('{ "%sUnits\\\\%s", %d, %d }' % (GAME, n, w, h) for n, w, h in names)
        fl = ", ".join("%d,%d,%d,%d,%d,%s,%s" % (f[0], f[1], f[2], f[3], f[4], lua_num(round(f[5], 1)), lua_num(round(f[6], 1))) for f in flat)
        rows.append('A.UNITS.%s = { cols = %d, walk = %d, death = %d, atk = %d, moveDur = %d, pages = { %s },\n    f = { %s } }'
                    % (key, cols, m["walk"], m["death"], m["atk"], m.get("moveDur") or 1000, pages, fl))
        print(key, len(names), "pages", [n[1:] for n in names])
    return rows


def props():
    meta = json.load(open(ART / "props.json"))
    pieces = []
    for k in sorted(meta):
        im = Image.open(ART / "props" / (k + ".png")).convert("RGBA")
        im = im.resize((max(1, round(im.width * S)), max(1, round(im.height * S))), Image.LANCZOS)
        pieces.append((k, im))
    pk = Packer()
    at = pk.pack(pieces)
    names = []
    for i, img in enumerate(pk.images()):
        name = "Props_%d" % (i + 1)
        write_dxt5_flat(img, OUT / (name + ".blp"))
        names.append((name, img.width, img.height))
    rows = ['A.PROP_PAGES = { %s }' % ", ".join('{ "%s%s", %d, %d }' % (GAME, n, w, h) for n, w, h in names)]
    for k, im in pieces:
        p, x, y = at[k]
        m = meta[k]
        rows.append('A.PROPS.%s = { %d, %d, %d, %d, %d, %s, %s }' % (k, p + 1, x, y, im.width, im.height, lua_num(round(m["ox"] * S, 1)), lua_num(round(m["oy"] * S, 1))))
    print("props", len(names), "pages")
    return rows


def disc(src, power=1.0):
    """A square client tile made round: tiled twice inward, faded out from the middle (as the mockup's prepare())."""
    im = Image.open(src).convert("RGBA").resize((256, 256), Image.LANCZOS)
    inner = im.resize((128, 128), Image.LANCZOS)
    im.alpha_composite(inner, (64, 64))
    a = np.asarray(im).astype(np.float32)
    yy, xx = np.mgrid[0:256, 0:256]
    r = np.sqrt((xx - 127.5) ** 2 + (yy - 127.5) ** 2) / 128
    g = np.interp(r, [0, 0.45, 0.8, 1.0], [1, 0.7, 0.25, 0])
    a[..., 3] *= g
    return Image.fromarray(a.clip(0, 255).astype(np.uint8), "RGBA")


def slash_arc(n=256, span=150.0, inner=0.58):
    """A weapon's swing: a crescent pointing east (+x) across span degrees, brightest at its outer edge and its middle,
    thinning to nothing at both ends (white: the game tints it)."""
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32)
    cx = cy = (n - 1) / 2
    dx, dy = (xx - cx) / (n / 2), (yy - cy) / (n / 2)
    r = np.sqrt(dx * dx + dy * dy)
    ang = np.degrees(np.arctan2(dy, dx))
    h = span / 2
    along = np.clip(1 - np.abs(ang) / h, 0, 1)                     # 1 in the middle of the swing, 0 at its ends
    width = inner + (1 - inner) * (1 - along ** 0.6)                  # the blade's band: widest mid-swing
    band = np.clip((r - width) / np.maximum(1e-3, 0.97 - width), 0, 1)
    edge = np.where(r <= 0.97, band ** 1.6, np.clip(1 - (r - 0.97) / 0.03, 0, 1))
    a = np.clip(edge * along ** 0.8, 0, 1)
    img = np.zeros((n, n, 4), np.uint8)
    img[..., 0] = img[..., 1] = img[..., 2] = 255
    img[..., 3] = (a * 255).astype(np.uint8)
    return Image.fromarray(img, "RGBA")


def exo_shaft(w=64, h=256, seed=7):
    """Exorcism's column of light: a soft halo round a narrow white-hot core, feathered at the sides, faint
    falling streaks, fading out toward the sky and softly at the foot (drawn tinted, additive)."""
    rng = np.random.default_rng(seed)
    x = (np.arange(w) + 0.5) / w * 2 - 1                          # -1..1 across
    y = (np.arange(h) + 0.5) / h                                  # 0 at the top .. 1 at the foot
    X, Y = np.meshgrid(x, y)
    halo = np.exp(-(X / 0.42) ** 2) * 0.55
    core = np.exp(-(X / 0.11) ** 2)
    streak = np.zeros(w)
    for _ in range(9):                                            # a few soft vertical streaks in the halo
        c, sw, a = rng.uniform(-0.6, 0.6), rng.uniform(0.04, 0.1), rng.uniform(0.15, 0.4)
        streak += a * np.exp(-((x - c) / sw) ** 2)
    streaks = np.exp(-(X / 0.5) ** 2) * streak[None, :] * (0.6 + 0.4 * np.sin(Y * 9 + X * 3) ** 2)
    along = np.clip(Y / 0.75, 0, 1) ** 1.6                        # sky: nothing; strongest low down
    foot = np.clip((1 - Y) / 0.06, 0, 1) ** 0.7
    edge = np.clip((1 - np.abs(X)) / 0.12, 0, 1)                  # never a hard side
    a = np.clip((halo + core + streaks) * along * foot * edge, 0, 1)
    img = np.zeros((h, w, 4), np.uint8)
    img[..., 0] = img[..., 1] = img[..., 2] = 255
    img[..., 3] = (a * 255).astype(np.uint8)
    return Image.fromarray(img, "RGBA")


def exo_sigil(n=256, spokes=12):
    """Exorcism's sigil burned into the ground: a glow, two rings, a ring of short rune dashes and spokes."""
    c = (np.arange(n) + 0.5) / n * 2 - 1
    X, Y = np.meshgrid(c, c)
    r = np.hypot(X, Y)
    ang = np.arctan2(Y, X)
    ring = lambda rad, wid: np.exp(-((r - rad) / wid) ** 2)
    a = 0.5 * np.exp(-(r / 0.42) ** 2)
    a += ring(0.9, 0.022) + 0.8 * ring(0.62, 0.016)
    seg = (np.cos(ang * 24) > 0.35) * ring(0.76, 0.03) * 0.85    # a band of dashes between the rings
    a += seg
    sp = np.exp(-((np.sin(ang * spokes / 2)) * r / 0.018) ** 2) * (r > 0.2) * (r < 0.6) * 0.55
    a += sp
    a *= np.clip((1 - r) / 0.04, 0, 1)
    a = np.clip(a, 0, 1)
    img = np.zeros((n, n, 4), np.uint8)
    img[..., 0] = img[..., 1] = img[..., 2] = 255
    img[..., 3] = (a * 255).astype(np.uint8)
    return Image.fromarray(img, "RGBA")


def fx():
    d = OUT / "FX"
    d.mkdir(parents=True, exist_ok=True)
    rows = []
    for f in sorted(os.listdir(SITE / "fx")):
        k = f[:-4]
        im = Image.open(SITE / "fx" / f).convert("RGBA")       # (already crushed by build_htl.py)
        if im.width != pow2(im.width) or im.height != pow2(im.height):
            pad = Image.new("RGBA", (pow2(im.width), pow2(im.height)), (0, 0, 0, 0))
            pad.paste(im, (0, 0))
            rows.append('A.FX_CROP.%s = { %s, %s }' % (k, lua_num(im.width / pad.width), lua_num(im.height / pad.height)))
            im = pad
        write_tga(im, d / (k + ".tga"))
    have = set(os.listdir(d))
    for k in NAXX_FX:               # the necropolis's (only those the Plaguelands set lacks)
        if k + ".tga" in have and k not in ("lava",):
            continue
        im = Image.open(NAXX / "fx" / (k + ".png")).convert("RGBA")
        if im.width != pow2(im.width) or im.height != pow2(im.height):
            pad = Image.new("RGBA", (pow2(im.width), pow2(im.height)), (0, 0, 0, 0))
            pad.paste(im, (0, 0))
            rows.append('A.FX_CROP.%s = { %s, %s }' % (k, lua_num(im.width / pad.width), lua_num(im.height / pad.height)))
            im = pad
        write_tga(im, d / (k + ".tga"))
    write_tga(disc(SITE / "fx" / "frost_tex.png"), d / "frost_disc.tga")
    write_tga(disc(SITE / "fx" / "lava.png"), d / "lava_disc.tga")
    write_tga(slash_arc(), d / "slash_arc.tga")
    write_tga(exo_shaft(), d / "exo_shaft.tga")
    write_tga(exo_sigil(), d / "exo_sigil.tga")
    print("fx", len(os.listdir(d)))
    return rows


def ui():
    d = OUT / "UI"
    d.mkdir(parents=True, exist_ok=True)
    rows = []
    for k in ("gem_green", "gem_blue", "gem_violet", "ice_spike_0", "ice_spike_1", "ice_spike_2"):
        im = Image.open(ART / "ui" / (k + ".png")).convert("RGBA")
        pad = Image.new("RGBA", (pow2(im.width), pow2(im.height)), (0, 0, 0, 0))
        pad.paste(im, (0, 0))
        write_tga(pad, d / (k + ".tga"))
        rows.append('A.UI_SIZE.%s = { %d, %d, %s, %s }' % (k, im.width, im.height, lua_num(im.width / pad.width), lua_num(im.height / pad.height)))
    # what the mockup drew on canvases at load (game.js prepare()): the contact shadow, the glow disc, the
    # darkness round the hero's light (alpha = how dark: 0 in the middle, the light's falloff out to its edge)
    yy, xx = np.mgrid[0:32, 0:64]
    r = np.sqrt(((xx - 31.5) / 32) ** 2 + ((yy - 15.5) / 16) ** 2)
    a_ = np.interp(r, [0, 0.6, 1], [0.62, 0.32, 0])
    write_tga(Image.fromarray(np.dstack([np.zeros((32, 64, 3)), a_ * 255]).astype(np.uint8), "RGBA"), d / "shadow.tga")
    yy, xx = np.mgrid[0:128, 0:128]
    r = np.sqrt((xx - 63.5) ** 2 + (yy - 63.5) ** 2) / 64
    a_ = np.interp(r, [0, 0.35, 1], [0.9, 0.35, 0])
    write_tga(Image.fromarray(np.dstack([np.full((128, 128, 3), 255), a_ * 255]).astype(np.uint8), "RGBA"), d / "glow.tga")
    yy, xx = np.mgrid[0:256, 0:256]
    r = np.sqrt((xx - 127.5) ** 2 + (yy - 127.5) ** 2) / 128
    light = np.interp(r, [0, 0.45, 1], [1, 0.65, 0]) * 0.95
    write_tga(Image.fromarray(np.dstack([np.full((256, 256, 3), 255), (1 - light) * 255]).astype(np.uint8), "RGBA"), d / "dark_hole.tga")
    # the client's own UI textures, cropped by texcoords (gen_art.py UI_CROPS boxes, trimmed to their alpha)
    crops = {"lvl_rule": ("levelup", (0, 0, 410, 22)), "lvl_glow": ("levelup", (285, 112, 512, 245)),
             "toast_leg": ("toast", (290, 0, 575, 80)), "bd_orange": ("toast", (826, 0, 888, 62)), "bd_blue": ("toast", (887, 0, 948, 62)),
             "bd_purple": ("toast", (946, 0, 1010, 62)), "bd_gold": ("toast", (746, 144, 812, 208)), "bd_green": ("toast", (180, 186, 246, 250))}
    files = {"levelup": "Interface\\\\LevelUp\\\\LevelUpTex", "toast": "Interface\\\\LootFrame\\\\LootToast"}
    for k, (src, box) in crops.items():
        im = Image.open(ART / "ui" / (src + ".png")).convert("RGBA")
        bb = im.crop(box).split()[3].point(lambda v: 255 if v > 6 else 0).getbbox()
        l, t, r, b = box[0] + bb[0], box[1] + bb[1], box[0] + bb[2], box[1] + bb[3]
        rows.append('A.CLIENT.%s = { "%s", %s, %s, %s, %s, %d, %d }' % (k, files[src], lua_num(round(l / im.width, 5)), lua_num(round(r / im.width, 5)),
                                                                     lua_num(round(t / im.height, 5)), lua_num(round(b / im.height, 5)), r - l, b - t))
    print("ui", len(rows))
    return rows


def sounds():
    """The client's own sounds, played by FileDataID (no files shipped): the mockup's list (gen_art.py SOUNDS)."""
    import casc_local as C
    sys.path.insert(0, str(MOCK))
    import gen_art
    rows = []
    for k, path in sorted(gen_art.SOUNDS.items()):
        f = C.fdid_of(path)
        if f:
            rows.append('A.SOUND.%s = %d   -- %s' % (k, f, path))
    print("sounds", len(rows))
    return rows


def ground():
    g = Image.open(ART / "ground.webp").convert("RGB")
    azw_blp.write_dxt1(g, OUT / "ground.blp")
    f = Image.open(ART / "fog.webp").convert("RGBA")
    azw_blp.write_dxt5(f, OUT / "fog.blp")
    print("ground + fog")
    return []


def main():
    what = sys.argv[1:] or ["units", "props", "fx", "ui", "ground", "sounds"]
    OUT.mkdir(parents=True, exist_ok=True)
    LUA.parent.mkdir(parents=True, exist_ok=True)
    # keep the parts not rebuilt this time (Art.lua is written whole)
    old = LUA.read_text(encoding="utf-8") if LUA.exists() else ""
    parts = {}
    for sec in ("units", "props", "fx", "ui", "ground", "sounds"):
        a, b = "-- [%s]\n" % sec, "-- [/%s]\n" % sec
        if a in old:
            parts[sec] = old[old.index(a) + len(a):old.index(b)]
    for sec in what:
        rows = globals()[sec]()
        parts[sec] = "".join(r + "\n" for r in rows)
    body = ['if DisasterZoneBoot and DisasterZoneBoot.Run("Games/HoldTheLine/Art.lua", ...) then return end -- DisasterZone Games/HoldTheLine/Art.lua',
            "-- ns.HTLArt: where Hold the Line's pictures sit. Generated by dev/generators/gen_htl_media.py - do not edit.",
            "-- UNITS[k].f: 7 numbers a frame (index = dir * cols + col, dir 0 = east, clockwise): page, x, y, w, h (texels =",
            "-- world units), dx, dy (the frame's top left from the feet). PROPS[k]: page, x, y, w, h, ox, oy (the foot in the picture).",
            "local _, ns = ...", "local A = { UNITS = {}, PROPS = {}, FX_CROP = {}, UI_SIZE = {}, CLIENT = {}, SOUND = {} }", "ns.HTLArt = A"]
    for sec in ("units", "props", "fx", "ui", "ground", "sounds"):
        body.append("-- [%s]\n%s-- [/%s]" % (sec, parts.get(sec, ""), sec))
    LUA.write_bytes(("\n".join(body) + "\n").encode("utf-8"))
    print("wrote", LUA)


if __name__ == "__main__":
    main()

"""Bakes the Guild Hall (azeromon_hall.py) for the game; gen_azeromon_ground.py calls bake() and lists the result
as the hall's Ground.lua entry. Writes into Media/Azeromon/Ground (prefix hideout_):
  hideout_<cx>_<cy>.tga, hideout_e_<cx>_<cy>.tga   the hall by day / by night (dark glass), 256 px chunks
  hideout_n_<cx>_<cy>.tga                         the night darkness (multiplied), at 1/2 size
  hideout_s.tga                                   the sun through the stained glass (added by day), cropped
  hideout_seal<i>.tga, hideout_seal<i>e.tga       wing i shut (dust sheets, scaffolding, a rope), day / night
  hideout_dim<i>.tga                              wing i's night light while shut, as a ratio of the open one
  hideout_props.tga                               things that stand up (sorted with the player), trophies, the chandelier
  hideout_f_<kind>.tga                            flame strips (braziers, hearths, torches, fel)
  hideout_w<i>.tga                                Serpentshrine's water: frames of streaks over the baked sheet
and Games/Azeromon/HallArt.lua (ns.AzeroHallArt): where all of that goes. Hideout.lua keeps the hall's rows (the
test compares them with azeromon_hall.rows()).
Run through gen_azeromon_ground.py (it re-bakes everything), or alone: python gen_azeromon_hall.py"""
import hashlib
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import azeromon_hall as ah  # noqa: E402
import azeromon_interiors  # noqa: E402
import azeromon_props  # noqa: E402
from azeromon_interiors import _img  # noqa: E402

ADDON = os.path.join(os.path.dirname(os.path.dirname(HERE)), "addon", "DisasterZone")
OUT_DIR = os.path.join(ADDON, "Media", "Azeromon", "Ground")
HALL_LUA = os.path.join(ADDON, "Games", "Azeromon", "HallArt.lua")
VERSION = 1
LIGHT_SCALE = 2
CHUNK = 256
MAP = "hideout"


def digest():
    h = hashlib.sha1()
    for p in (__file__, ah.__file__, azeromon_interiors.__file__, azeromon_props.__file__):
        h.update(open(p, "rb").read().replace(b"\r\n", b"\n"))
    h.update(str(VERSION).encode())
    return h.hexdigest()[:16]


def pot(n):
    p = 1
    while p < n:
        p *= 2
    return p


def u8(a):
    return np.clip(np.round(a), 0, 255).astype(np.uint8)


def save(arr, name):
    mode = "RGBA" if arr.shape[2] == 4 else "RGB"
    Image.fromarray(u8(arr), mode).save(os.path.join(OUT_DIR, name))
    return name


def padded(part, channels=3):
    """a picture in the corner of a power-of-two texture, its edge carried into the padding"""
    uh, uw = part.shape[:2]
    tex = np.zeros((pot(uh), pot(uw), channels))
    tex[:uh, :uw] = part
    if channels == 3:
        tex[uh:, :uw] = part[-1:, :, :]
        tex[:, uw:] = tex[:, uw - 1:uw]
    return tex


def chunks(img, prefix):
    out = []
    H_, W_ = img.shape[:2]
    for cy in range(0, H_, CHUNK):
        for cx in range(0, W_, CHUNK):
            part = img[cy:cy + CHUNK, cx:cx + CHUNK]
            tex = padded(part)
            save(tex, "%s_%s%d_%d.tga" % (MAP, prefix, cx // CHUNK, cy // CHUNK))
            out.append((cx, cy, part.shape[1], part.shape[0], tex.shape[1], tex.shape[0]))
    return out


def pack(images):
    """shelf-pack RGBA arrays into one sheet: (sheet, [(x, y)])"""
    width = 512
    x = y = row_h = 0
    pos = []
    for a in images:
        h, w = a.shape[:2]
        if x + w > width:
            x, y, row_h = 0, y + row_h + 1, 0
        pos.append((x, y))
        x += w + 1
        row_h = max(row_h, h)
    sheet = np.zeros((pot(y + row_h + 1), width, 4))
    for a, (x, y) in zip(images, pos):
        sheet[y:y + a.shape[0], x:x + a.shape[1]] = a
    return sheet, pos


def lua(v, ind=""):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, np.integer)):
        return "%d" % v
    if isinstance(v, (float, np.floating)):
        return ("%.3f" % v).rstrip("0").rstrip(".")
    if isinstance(v, str):
        return '"%s"' % v.replace("\\", "\\\\").replace('"', '\\"')
    if isinstance(v, dict):
        return "{ " + ", ".join("%s = %s" % (k, lua(x)) for k, x in v.items()) + " }"
    return "{ " + ", ".join(lua(x) for x in v) + " }"


def bake():
    os.makedirs(OUT_DIR, exist_ok=True)
    day, plan = ah.paint(sealed=False, night=False)
    night, _ = ah.paint(sealed=False, night=True)
    s_day, splan = ah.paint(sealed=True, night=False)
    s_night, _ = ah.paint(sealed=True, night=True)
    cs = chunks(day, "")
    chunks(night, "e_")
    # the night darkness, open and with every wing shut (the shut one only fills the wings' dim ratios)
    lm = ah.light_map(plan, LIGHT_SCALE)
    lm_s = ah.light_map(splan, LIGHT_SCALE)
    lc = []
    for cy in range(0, lm.shape[0], CHUNK):
        for cx in range(0, lm.shape[1], CHUNK):
            part = lm[cy:cy + CHUNK, cx:cx + CHUNK]
            tex = padded(part)
            save(tex, "%s_n_%d_%d.tga" % (MAP, cx // CHUNK, cy // CHUNK))
            lc.append((cx, cy, part.shape[1], part.shape[0], tex.shape[1], tex.shape[0]))
    # the sun through the glass, cropped to where it falls
    sun = ah.sun_overlay(plan)
    ys, xs = np.nonzero(sun.max(2) > 0)
    x0, y0, x1, y1 = int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1
    part = sun[y0:y1, x0:x1]
    tex = np.zeros((pot(part.shape[0]), pot(part.shape[1]), 3))
    tex[:part.shape[0], :part.shape[1]] = part
    save(tex, "%s_s.tga" % MAP)
    sunlight = (part.shape[1], part.shape[0], tex.shape[1], tex.shape[0], x0, y0)
    # the wings: index order as plan["wings"] (Sunwell first)
    wkeys = [w["key"] for w in plan["wings"]]
    widx = lambda k: (wkeys.index(k) + 1) if k else 0
    wings = []
    for i, w in enumerate(plan["wings"]):
        x, y, ww, hh = w["rect"]
        for suffix, pic in (("", s_day), ("e", s_night)):
            t_ = padded(pic[y:y + hh, x:x + ww])
            save(t_, "%s_seal%d%s.tga" % (MAP, i + 1, suffix))
        a, b = lm[y // LIGHT_SCALE:(y + hh) // LIGHT_SCALE, x // LIGHT_SCALE:(x + ww) // LIGHT_SCALE].astype(np.float64), \
            lm_s[y // LIGHT_SCALE:(y + hh) // LIGHT_SCALE, x // LIGHT_SCALE:(x + ww) // LIGHT_SCALE].astype(np.float64)
        ratio = np.clip(255 * b / np.maximum(a, 1), 0, 255)
        dt = padded(ratio)
        save(dt, "%s_dim%d.tga" % (MAP, i + 1))
        e = {"key": w["key"], "name": w["short"], "rect": [x, y, ww, hh], "tex": [t_.shape[1], t_.shape[0]],
             "dim": [ratio.shape[1], ratio.shape[0], dt.shape[1], dt.shape[0]]}
        if w.get("mouth") is not None:
            e["mouth"] = w["mouth"]
            e["y0"] = w["Y"]
        wings.append(e)
    # standing things + trophies + the chandelier in one sheet
    imgs, keys, props = [], {}, []
    for s in plan["sprites"]:
        a = _img(s["spr"])
        k = (s["name"], a.shape, a.tobytes())
        if k not in keys:
            keys[k] = len(imgs)
            imgs.append(a)
        props.append((keys[k], s["x"], s["y"], s["foot"], widx(s["wing"])))
    t0 = len(imgs)
    for th in ah.THEME:
        imgs.append(_img(ah.trophy(th)))
    ch, ccx, ccy = ah.chandelier_sprite()
    imgs.append(_img(ch))
    sheet, pos = pack(imgs)
    save(sheet, "%s_props.tga" % MAP)
    rect = lambda i: [pos[i][0], pos[i][1], imgs[i].shape[1], imgs[i].shape[0]]
    trophies = [[th] + rect(t0 + j) for j, th in enumerate(ah.THEME)]     # (a list: theme keys read as raid keys)
    top = rect(len(imgs) - 1) + [plan["chandelier"]["x"] - ccx, plan["chandelier"]["y"] - 46 - ccy]
    # flame strips
    strips = {}
    for kind in ah.FIRE_SIZE:
        frames = ah.fire_frames(kind)
        fh, fw = frames[0].shape[:2]
        strip = np.zeros((pot(fh), pot(fw * len(frames)), 4))
        for i, fr in enumerate(frames):
            strip[:fh, i * fw:(i + 1) * fw] = fr
        save(strip, "%s_f_%s.tga" % (MAP, kind))
        strips[kind] = [fw, fh, strip.shape[1], strip.shape[0], len(frames)]
    fires = [[f["x"], f["y"] - 3, f["kind"], widx(f.get("wing"))] for f in plan["fires"]]
    water = []
    for i, wv in enumerate(plan["water"]):
        frames = ah.water_frames(wv)
        cols = max(1, min(len(frames), 1024 // wv["w"]))
        rows_ = -(-len(frames) // cols)
        strip = np.zeros((pot(wv["h"] * rows_), pot(wv["w"] * cols), 4))
        for k, fr in enumerate(frames):
            c, r = k % cols, k // cols
            strip[r * wv["h"]:(r + 1) * wv["h"], c * wv["w"]:(c + 1) * wv["w"]] = fr
        save(strip, "%s_w%d.tga" % (MAP, i + 1))
        water.append([wv["x"], wv["y"], wv["w"], wv["h"], cols, rows_, strip.shape[1], strip.shape[0], len(frames),
                      widx(wv["wing"])])
    glows = [[L["x"], L["y"], L["r"]] + [round(c / 255, 3) for c in L["c"]] + [L["f"], widx(L["wing"])]
             for L in plan["lights"] if L["k"] not in ("spot", "sconce")]
    motes = [[e["type"]] + list(e["rect"]) + [widx(e["wing"])] for e in plan["fx"] if e["type"] != "candle"]
    candles = [[e["x"], e["y"], widx(e["wing"])] for e in plan["fx"] if e["type"] == "candle"]
    plinths = [[p["wing"], p["i"] + 1, p["x"], p["y"], p["theme"]] for p in plan["plinths"]]
    v = digest()
    lines = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/HallArt.lua", ...) then return end '
        "-- DisasterZone Games/Azeromon/HallArt.lua  (GENERATED by dev/generators/gen_azeromon_hall.py - do not edit)",
        "-- The Guild Hall's baked art beyond its ground (Ground.lua: hideout). Map pixels (16 a tile); files in",
        "-- Media/Azeromon/Ground. Wing numbers index `wings` (0: always there). A wing is shut until the guild has",
        "-- killed one of its raid's bosses: the game lays its seal picture over the hall and dims its night light.",
        "--   props     { sheet x, y, w, h, x, y, foot y, wing }  hideout_props.tga: drawn behind or in front of the player",
        "--   top       { sheet x, y, w, h, x, y }  the chandelier, over everything",
        "--   trophies  { theme, sheet x, y, w, h }; plinths { raid key, boss number, x, y, theme } (tile x, y)",
        "--   wings     { key, name, rect, tex = { tw, th } (hideout_seal<i>[e]), dim = { w, h, tw, th } (hideout_dim<i>,",
        "--             1/%d size, multiplied at night), mouth / y0 (the wing's opening column, its top row) }" % LIGHT_SCALE,
        "--   fires     { x, y, kind, wing }; strips kind = { w, h, tw, th, frames } (hideout_f_<kind>.tga)",
        "--   water     { x, y, w, h, cols, rows, tw, th, frames, wing } (hideout_w<i>.tga)",
        "--   glows     { x, y, radius, r, g, b, flickers, wing }  added at night over the darkness",
        "--   motes     { kind, x, y, w, h, wing }; candles { x, y, wing } (Karazhan's floating candles)",
        "local addonName, ns = ...",
        "ns.AzeroHallArt = {",
        '    v = "%s", sheet = { %d, %d }, lightScale = %d,' % (v, sheet.shape[1], sheet.shape[0], LIGHT_SCALE),
        "    props = { %s }," % ", ".join(lua([rect(i)[0], rect(i)[1], rect(i)[2], rect(i)[3], x, y, f, w])
                                         for i, x, y, f, w in props),
        "    top = %s," % lua(top),
        "    trophies = { %s }," % ", ".join(lua(t) for t in trophies),
        "    plinths = { %s }," % ", ".join(lua(p) for p in plinths),
        "    wings = {",
    ]
    for w in wings:
        lines.append("        %s," % lua(w))
    lines += [
        "    },",
        "    fires = { %s }," % ", ".join(lua(f) for f in fires),
        "    strips = %s," % lua(strips),
        "    water = { %s }," % ", ".join(lua(w) for w in water),
        "    glows = { %s }," % ", ".join(lua(g) for g in glows),
        "    motes = { %s }," % ", ".join(lua(m) for m in motes),
        "    candles = { %s }," % ", ".join(lua(c) for c in candles),
        "}",
    ]
    with open(HALL_LUA, "w", newline="\n", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    files = {n for n in os.listdir(OUT_DIR) if n.startswith(MAP + "_")}
    entry = {"v": v, "chunks": cs, "water": [], "meadows": [], "lights": [], "lightChunks": lc,
             "shafts": [(sh["x"], sh["y"] - 14, sh["w"]) for sh in plan["shafts"]], "indoor": True, "mx": 0, "my": 0,
             "sunlight": [sunlight], "anims": [], "lightScale": LIGHT_SCALE, "hall": True}
    return entry, files


if __name__ == "__main__":
    e, files = bake()
    print("baked hideout:", len(e["chunks"]), "chunks,", len(files), "files")

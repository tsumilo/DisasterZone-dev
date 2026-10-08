"""Azeromon's overworld from the real Eastern Kingdoms (see dev/docs/azeromon_world/PLAN.md).

    luaenv\\Scripts\\python.exe generators\\gen_azeromon_world.py preview [region]   # PNG of the classified map
    luaenv\\Scripts\\python.exe generators\\gen_azeromon_world.py lua                # write the addon's World data

Pipeline: azw_raw (terrain per tile) -> ground classes (azw_classify) -> WMOs (azw_struct) -> doodads -> layers:
    G  ground class char per tile (azw_classify.CLASSES)
    O  overlay char per tile (OVER below): trunks, rocks, fences, props, building roofs / walls / doors, bridges
    S  hill shade 0..9 per tile (light from the north-west, from the terrain normal)
and entity lists (trees with crown sizes, doors, NPCs, mobs...)."""
import io
import re
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import adt_tools as A          # noqa: E402
import azw_classify as K       # noqa: E402
import azw_raw as R            # noqa: E402
import azw_struct as ST        # noqa: E402
import azw_wmo as WM           # noqa: E402

DEV = os.path.dirname(HERE)
SCRATCH = os.path.join(DEV, "art", "azw")

# The block of ADTs the current zones live in (Stormwind, Elwynn incl. Northshire).
BOX = (29, 36, 46, 50)

# area IDs (AreaTable) per region we build
REGIONS = {
    "northshire": {9, 24, 59, 34, 23},
}

# overlay chars -> (tile kind, solid)
OVER = {
    "T": ("trunk", True), "s": ("stump", True), "l": ("log", True), "o": ("rock", True),
    "b": ("bush", False), "u": ("pumpkin", False), "c": ("cabbage", False), "v": ("vines", False),
    "f": ("fence", True), "g": ("gravestone", True), "L": ("lamppost", True), "i": ("torch", True),
    "n": ("sign", True), "h": ("hay", True), "B": ("barrel", True), "C": ("crate", True), "k": ("sack", True),
    "m": ("lumber", True), "a": ("cart", True), "W": ("well", True), "N": ("anvil", True), "d": ("dummy", True),
    "r": ("rack", True), "y": ("scarecrow", True), "A": ("tent", True), "H": ("shed", True), "U": ("statue", True),
    "F": ("banner", True), "w": ("awning", False), "p": ("campfire", True), "t": ("tools", True),
    # structures (WMOs)
    "#": ("wall", True), "R": ("roof", True), "D": ("door", False), "=": ("deck", False),
}
TILE_TO_OVER = {v[0]: k for k, v in OVER.items()}

# WMO kinds where the automatic rules need help: "cave" = only its entrance matters outdoors
WMO_KINDS = {
    110750: "cave",          # Echo Ridge Mine
}


def nearest_class_fallback(colours):
    """Unknown texture -> the class with the nearest preview colour of the texture's average colour."""
    cache = {}

    def fb(tex):
        if tex in cache:
            return cache[tex]
        col = colours(tex)
        best, bd = ".", 1e9
        for ch, (_n, walk, c) in K.CLASSES.items():
            if ch in "Xw~":
                continue
            d = sum((a - b) ** 2 for a, b in zip(col, c))
            if d < bd:
                best, bd = ch, d
        cache[tex] = (best, "#" if best in "^#" else "^")
        print("unknown texture %d avg %s -> %s" % (tex, col, best))
        return cache[tex]
    return fb


_TEXCOL = {}


def tex_colour(tex):
    if tex not in _TEXCOL:
        from PIL import Image
        import casc_local as C
        try:
            im = Image.open(io.BytesIO(C.read_fid(tex))).convert("RGB").resize((1, 1), Image.BOX)
            _TEXCOL[tex] = im.getpixel((0, 0))
        except Exception:
            _TEXCOL[tex] = (255, 0, 255)
    return _TEXCOL[tex]


def build(box=BOX):
    r = R.raw(*box)
    H, W = r["H"], r["W"]
    fb = nearest_class_fallback(tex_colour)
    G = np.full((H, W), "X", dtype="<U1")
    for y in range(H):
        for x in range(W):
            if not r["present"][y, x]:
                continue
            if r["liq"][y, x]:
                G[y, x] = "w" if r["depth"][y, x] > K.DEEP_WATER else "~"
                continue
            G[y, x] = K.ground_class(int(r["tex"][y, x]), float(r["slope"][y, x]), fb)
    O = np.full((H, W), " ", dtype="<U1")
    trees = []
    # surface height a person stands on (terrain, or the water surface)
    stand = r["z"] + np.where(r["liq"] > 0, r["depth"], 0)
    # --- WMOs ---
    doors = []
    buildings = []
    for info in ST.apply(None, r["wmos"], WMO_KINDS):
        gx0, gy0 = r["gx0"], r["gy0"]
        cave = info["kind"] == "cave"
        for (tx, ty), c in info["cells"].items():
            x, y = tx - gx0, ty - gy0
            if not (0 <= x < W and 0 <= y < H):
                continue
            g = float(stand[y, x])
            if cave and c["top"] < g - 1:
                continue                         # under the ground
            floors = [z for z in c["floors"] if g - 1.5 <= z <= g + 6]
            st = max(floors) if floors else g          # (a bridge deck, not the beams under it)
            blocked = any(z0 < st + 1.8 and z1 > st + 0.4 for z0, z1 in c["walls"])
            roof = info["indoor"] and not cave and c["indoor_top"] > st + 3
            if roof or (blocked and info["indoor"] and not cave):
                O[y, x] = "R"                    # (a building's walls belong to its block on the map)
            elif blocked:
                O[y, x] = "#"
            elif floors and G[y, x] in ("w", "~", "#", "^"):
                O[y, x] = "="                    # a bridge deck / stairs over water or rock
        if cave:
            # a mine's mouth: the portal between its outdoor entrance and the tunnels, on the nearest walkable
            # ground at that height; the way out is the walkable neighbour farthest from the tunnels
            cx_ = sum(t[0] for t in info["cells"]) / max(1, len(info["cells"]))
            cy_ = sum(t[1] for t in info["cells"]) / max(1, len(info["cells"]))
            for (dx, dy, dz, grp, pi) in info["doors"]:
                best = None
                for yy in range(int(dy) - 4, int(dy) + 5):
                    for xx in range(int(dx) - 4, int(dx) + 5):
                        lx, ly = xx - gx0, yy - gy0
                        if not (0 <= lx < W and 0 <= ly < H) or G[ly, lx] in "#wX" or O[ly, lx] != " ":
                            continue
                        if abs(float(stand[ly, lx]) - dz) > 6:
                            continue
                        d2 = (xx + 0.5 - dx) ** 2 + (yy + 0.5 - dy) ** 2
                        if best is None or d2 < best[0]:
                            best = (d2, xx, yy)
                if not best:
                    continue
                _, xx, yy = best
                outs = [(xx + ax, yy + ay) for ax, ay in ((0, 1), (0, -1), (1, 0), (-1, 0))
                        if 0 <= xx + ax - gx0 < W and 0 <= yy + ay - gy0 < H
                        and G[yy + ay - gy0, xx + ax - gx0] not in "#wX" and O[yy + ay - gy0, xx + ax - gx0] == " "]
                if not outs:
                    continue
                out_t = max(outs, key=lambda t: (t[0] - cx_) ** 2 + (t[1] - cy_) ** 2)
                O[yy - gy0, xx - gx0] = "D"
                doors.append({"x": xx, "y": yy, "out": out_t, "z": dz, "wmo": info["w"][0], "uid": info["w"][7],
                              "portal": pi, "px": dx, "py": dy})
            buildings.append({"w": info["w"], "cells": set(info["cells"]), "cave": True})
            continue
        # doors: from the portal, walk away from the building's middle to the edge of its roof
        roofs = [(tx, ty) for (tx, ty), c in info["cells"].items()
                 if 0 <= tx - gx0 < W and 0 <= ty - gy0 < H and O[ty - gy0, tx - gx0] == "R"]
        if not roofs:
            continue
        mx = sum(t[0] for t in roofs) / len(roofs) + 0.5
        my = sum(t[1] for t in roofs) / len(roofs) + 0.5
        for (dx, dy, dz, grp, pi) in info["doors"]:
            vx, vy = dx - mx, dy - my
            ln = math.hypot(vx, vy) or 1
            vx, vy = vx / ln, vy / ln
            px_, py_ = dx, dy
            last = None
            for _ in range(200):
                x, y = int(px_) - gx0, int(py_) - gy0
                if not (0 <= x < W and 0 <= y < H):
                    break
                if O[y, x] != "R":
                    if last:
                        break
                else:
                    last = (x, y)
                px_ += vx * 0.25
                py_ += vy * 0.25
            if not last:
                continue
            ox, oy = int(px_) - gx0, int(py_) - gy0
            if 0 <= ox < W and 0 <= oy < H and abs(dz - float(stand[oy, ox])) > 12:
                continue                         # an upper-floor door (a balcony): not reachable from the ground
            x, y = last
            O[y, x] = "D"
            doors.append({"x": x + gx0, "y": y + gy0, "out": (int(px_), int(py_)), "z": dz, "wmo": info["w"][0],
                          "uid": info["w"][7], "portal": pi, "px": dx, "py": dy})
        if info["indoor"] and not cave:
            buildings.append({"w": info["w"], "cells": set(info["cells"])})
    # --- doodads ---
    unknown = {}
    for fid, p, rot, sc, uid in r["doodads"]:
        name = R.m2_name(fid)
        kind, tile = K.doodad_kind(name)
        if kind is None:
            unknown[name] = unknown.get(name, 0) + 1
            continue
        if kind == "skip":
            continue
        gx, gy = p[0] / A.TS, p[2] / A.TS
        x, y = int(gx) - r["gx0"], int(gy) - r["gy0"]
        if not (0 <= x < W and 0 <= y < H):
            continue
        box = R.m2_box(fid)
        if kind == "tree":
            # crown radius in tiles from the model's box (x / y half extents x scale)
            rad = 1.5
            if box:
                (x0_, y0_, _), (x1_, y1_, _), _ = box
                rad = max(x1_ - x0_, y1_ - y0_) * sc / 2 / A.TS
            trees.append((int(gx), int(gy), round(min(max(rad, 0.5), 3.5), 1)))
            if O[y, x] == " ":
                O[y, x] = "T"
            continue
        if kind == "deco":
            if O[y, x] == " " and G[y, x] not in "w#":
                O[y, x] = TILE_TO_OVER[tile]
            continue
        if kind == "fence":
            # a line along the model's long axis
            length = 1.0
            if box:
                (x0_, y0_, _), (x1_, y1_, _), _ = box
                length = max(x1_ - x0_, y1_ - y0_) * sc
                along_x = (x1_ - x0_) >= (y1_ - y0_)
            else:
                along_x = True
            f = WM.transform_of(p, rot, 1.0)
            half = length / 2
            ax = (half, 0, 0) if along_x else (0, half, 0)
            a, b = f(ax), f((-ax[0], -ax[1], 0))
            steps = max(1, int(math.ceil(math.hypot(b[0] - a[0], b[1] - a[1]) * 2)))
            for k in range(steps + 1):
                tx = a[0] + (b[0] - a[0]) * k / steps
                ty = a[1] + (b[1] - a[1]) * k / steps
                xx, yy = int(tx) - r["gx0"], int(ty) - r["gy0"]
                if 0 <= xx < W and 0 <= yy < H and O[yy, xx] in (" ", "b"):
                    O[yy, xx] = "f"
            continue
        # props / rocks / stumps / logs: the tile under the model (big ones cover their box)
        ch = TILE_TO_OVER.get(tile, "C")
        if O[y, x] in (" ", "b"):
            O[y, x] = ch
    # --- hill shade (light from the north-west) ---
    z = r["z"]
    dzdx = np.zeros_like(z)
    dzdy = np.zeros_like(z)
    dzdx[:, 1:-1] = (z[:, 2:] - z[:, :-2]) / (2 * A.TS)
    dzdy[1:-1, :] = (z[2:, :] - z[:-2, :]) / (2 * A.TS)
    nx, ny, nzv = -dzdx, -dzdy, np.ones_like(z)
    ln = np.sqrt(nx * nx + ny * ny + nzv * nzv)
    lx, ly, lz = -0.5, -0.5, 0.707
    lam = (nx * lx + ny * ly + nzv * lz) / ln
    S = np.clip(np.round((lam - 0.35) / 0.65 * 9), 0, 9).astype(int)
    smooth(G)
    connect_decks(O, G)
    return {"r": r, "G": G, "O": O, "S": S, "trees": trees, "doors": doors, "unknown": unknown,
            "buildings": buildings}


# Classes that only colour the ground (walkability stays the same whatever they become): the blend of WoW's
# texture layers leaves specks of them that would read as noise, so they are cleaned to shapes at least 2 tiles wide.
COSMETIC = ".,*=:+%^s"
THIN_OK = ".,*"          # grass kinds may stay 1 tile wide (they are the background)


def smooth(G):
    H, W = G.shape
    for _ in range(2):
        # 1) a cosmetic tile with no same-class 4-neighbour takes the most common cosmetic neighbour class
        out = G.copy()
        for y in range(1, H - 1):
            for x in range(1, W - 1):
                c = G[y, x]
                if c not in COSMETIC:
                    continue
                n4 = (G[y - 1, x], G[y + 1, x], G[y, x - 1], G[y, x + 1])
                if c in n4:
                    continue
                cnt = {}
                for yy in (y - 1, y, y + 1):
                    for xx in (x - 1, x, x + 1):
                        k = G[yy, xx]
                        if (yy, xx) != (y, x) and k in COSMETIC:
                            cnt[k] = cnt.get(k, 0) + 1
                if cnt:
                    out[y, x] = max(cnt.items(), key=lambda kv: kv[1])[0]
        G[:, :] = out
    # 2) thin features (roads, dirt, crops...) must belong to a full 2x2 block of their class, else they melt into
    # the most common grass class around them (the autotiles need two tiles to draw an edge on each side)
    for c in COSMETIC:
        if c in THIN_OK:
            continue
        m = G == c
        ok = np.zeros_like(m)
        blk = m[:-1, :-1] & m[1:, :-1] & m[:-1, 1:] & m[1:, 1:]
        ok[:-1, :-1] |= blk
        ok[1:, :-1] |= blk
        ok[:-1, 1:] |= blk
        ok[1:, 1:] |= blk
        for y, x in zip(*np.nonzero(m & ~ok)):
            cnt = {}
            for yy in range(max(0, y - 1), min(H, y + 2)):
                for xx in range(max(0, x - 1), min(W, x + 2)):
                    k = G[yy, xx]
                    if k in THIN_OK:
                        cnt[k] = cnt.get(k, 0) + 1
            G[y, x] = max(cnt.items(), key=lambda kv: kv[1])[0] if cnt else "."


def connect_decks(O, G):
    """Bridge decks that only touch diagonally get an orthogonal step between them (the player walks in 4
    directions): the blocked tile of the two candidates that is not water is opened, else the first."""
    changed = True
    while changed:
        changed = False
        ys, xs = np.nonzero(O == "=")
        deck = set(zip(ys.tolist(), xs.tolist()))
        for y, x in list(deck):
            for dy, dx in ((1, 1), (1, -1)):
                yy, xx = y + dy, x + dx
                if (yy, xx) not in deck:
                    continue
                a, b = (y, xx), (yy, x)
                if a in deck or b in deck:
                    continue
                pick = a if G[a] not in "w~" else b
                O[pick] = "="
                deck.add(pick)
                changed = True


def region_bbox(world, region, pad=6):
    r = world["r"]
    m = np.isin(r["area"], list(REGIONS[region]))
    ys, xs = np.nonzero(m)
    return xs.min() - pad, xs.max() + pad, ys.min() - pad, ys.max() + pad, m


def preview(world, region, path, px=8):
    from PIL import Image, ImageDraw
    r = world["r"]
    x0, x1, y0, y1, m = region_bbox(world, region)
    im = Image.new("RGB", ((x1 - x0) * px, (y1 - y0) * px))
    d = ImageDraw.Draw(im)
    G, O, S = world["G"], world["O"], world["S"]
    OC = {"T": (40, 70, 20), "#": (60, 60, 70), "R": (90, 90, 140), "D": (255, 220, 0), "=": (170, 120, 70),
          "f": (130, 90, 40), "b": (50, 110, 40), "o": (110, 110, 110)}
    for y in range(y0, y1):
        for x in range(x0, x1):
            c = K.CLASSES[G[y, x]][2]
            sh = 0.65 + 0.07 * S[y, x]
            c = tuple(min(255, int(v * sh)) for v in c)
            if not m[y, x]:
                c = tuple(v // 2 for v in c)
            X, Y = (x - x0) * px, (y - y0) * px
            d.rectangle([X, Y, X + px - 1, Y + px - 1], fill=c)
            o = O[y, x]
            if o != " ":
                oc = OC.get(o, (230, 230, 230))
                if o in "R#=":
                    d.rectangle([X, Y, X + px - 1, Y + px - 1], fill=oc)
                else:
                    d.rectangle([X + 2, Y + 2, X + px - 3, Y + px - 3], fill=oc)
    for (tx, ty, rad) in world["trees"]:
        X, Y = (tx - r["gx0"] - x0 + 0.5) * px, (ty - r["gy0"] - y0 + 0.5) * px
        rr = rad * px
        d.ellipse([X - rr, Y - rr, X + rr, Y + rr], outline=(20, 60, 10))
    im.save(path)
    print("preview", path, im.size)


# ----------------------------------------------------------------------------------------------------------------
# Lua output
# ----------------------------------------------------------------------------------------------------------------
ADDON = os.path.join(os.path.dirname(DEV), "addon", "DisasterZone")
WORLD_DIR = os.path.join(ADDON, "Games", "Azeromon", "World")
BLOCK = 32
RUNS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_-"     # run length 1..64


def rle(s):
    """'aaab' -> 'a2b0' (symbol, run char): pairs, read two characters at a time."""
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        j = i
        while j < n and s[j] == c and j - i < 64:
            j += 1
        out.append(c + RUNS[j - i - 1])
        i = j
    return "".join(out)


def lua_str(v):
    return '"%s"' % str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def lua_val(v, indent=""):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, np.integer)):
        return str(int(v))
    if isinstance(v, (float, np.floating)):
        f = float(v)
        return str(int(f)) if f == int(f) else ("%.2f" % f).rstrip("0")
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, (list, tuple)):
        return "{ " + ", ".join(lua_val(x) for x in v) + " }"
    if isinstance(v, dict):
        parts = []
        for k, x in v.items():
            if x is None:
                continue
            key = k if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", str(k)) else "[%s]" % lua_val(k)
            parts.append("%s = %s" % (key, lua_val(x)))
        return "{ " + ", ".join(parts) + " }"
    raise TypeError(type(v))


def area_names(ids):
    import csv
    out = {}
    with open(os.path.join(DEV, "art", "tbcdb", "db2", "AreaTable.csv"), encoding="utf-8") as f:
        for row in csv.DictReader(f):
            i = int(row["ID"])
            if i in ids:
                out[i] = {"name": row["AreaName_lang"], "zone": int(row["ParentAreaID"]) or i}
    return out


def header(path):
    rel = os.path.relpath(path, ADDON).replace("\\", "/")
    return ('if DisasterZoneBoot and DisasterZoneBoot.Run("%s", ...) then return end -- DisasterZone %s  '
            '(GENERATED by dev/generators/gen_azeromon_world.py - do not edit)\n' % (rel, rel))


GROUND_RUNS = RUNS


def b64(n, width=3):
    out = ""
    for _ in range(width):
        out = RUNS[n % 64] + out
        n //= 64
    return out


def rle3(codes):
    """[3-char code] -> 'codeR...' (code + run char), read four characters at a time."""
    out, i, n = [], 0, len(codes)
    while i < n:
        j = i
        while j < n and codes[j] == codes[i] and j - i < 64:
            j += 1
        out.append(codes[i] + RUNS[j - i - 1])
        i = j
    return "".join(out)


def emit_ground(world, region, bx0, bx1, by0, by1):
    """WoW's own ground for the region's blocks (azw_ground): Media/Azeromon/Ground/<region>_<n>.blp pages and the
    per-tile slots. -> (per block key: rle string, page count)"""
    import azw_ground as GR
    from azw_blp import write_dxt1 as write_blp
    gx0, gx1, gy0, gy1 = bx0 * BLOCK, (bx1 + 1) * BLOCK, by0 * BLOCK, (by1 + 1) * BLOCK
    tiles, index = GR.build_tiles(GR.tile_layers("azeroth", gx0, gx1, gy0, gy1, world["r"]))
    gdir = os.path.join(MEDIA, "Ground")
    os.makedirs(gdir, exist_ok=True)
    pages = GR.write_pages(tiles, os.path.join(gdir, region), write_blp)
    print("ground %s: %d tiles, %d page(s)" % (region, len(tiles), pages))
    out = {}
    for by in range(by0, by1 + 1):
        for bx in range(bx0, bx1 + 1):
            ys, xs = by * BLOCK - gy0, bx * BLOCK - gx0
            codes = [b64(int(index[ys + j, xs + i])) for j in range(BLOCK) for i in range(BLOCK)]   # (< 262144)
            out[by * 256 + bx] = rle3(codes)
    return out, pages


def emit(world, region, entities, interiors=()):
    """Writes World/<Region>.lua: the region's blocks, area names, trees, doors and spawns."""
    import azw_entities as E
    r = world["r"]
    x0, x1, y0, y1, m = region_bbox(world, region)
    gx0, gy0 = r["gx0"], r["gy0"]
    bx0, bx1 = (x0 + gx0) // BLOCK, (x1 + gx0) // BLOCK
    by0, by1 = (y0 + gy0) // BLOCK, (y1 + gy0) // BLOCK
    G, O, S = world["G"], world["O"], world["S"]
    ground, pages = emit_ground(world, region, bx0, bx1, by0, by1)
    import azw_scenery as SCN
    scen = SCN.build(dict(world, wmo_kinds=WMO_KINDS),
                     (bx0 * BLOCK, (bx1 + 1) * BLOCK, by0 * BLOCK, (by1 + 1) * BLOCK),
                     os.path.join(MEDIA, "Scenery", region))
    print("scenery %s: %d sprites, %d placements, %d page(s)" % (region, len(scen["sprites"]),
                                                                 len(scen["placements"]), scen["pages"]))
    lines = []
    areas = set()
    for by in range(by0, by1 + 1):
        for bx in range(bx0, bx1 + 1):
            ys, xs = by * BLOCK - gy0, bx * BLOCK - gx0
            g = "".join("".join(G[ys + j, xs:xs + BLOCK]) for j in range(BLOCK))
            o = "".join("".join(O[ys + j, xs:xs + BLOCK]) for j in range(BLOCK))
            s = "".join("".join(str(v) for v in S[ys + j, xs:xs + BLOCK]) for j in range(BLOCK))
            ar = [int(r["area"][ys + cy * 8, xs + cx * 8]) for cy in range(4) for cx in range(4)]
            areas.update(ar)
            lines.append("B[%d] = { [=[%s]=], [=[%s]=], [=[%s]=], { %s }, [=[%s]=], R }" %
                         (by * 256 + bx, rle(g), rle(o), rle(s), ", ".join(map(str, ar)), ground[by * 256 + bx]))
    bgx0, bgx1, bgy0, bgy1 = bx0 * BLOCK, (bx1 + 1) * BLOCK, by0 * BLOCK, (by1 + 1) * BLOCK
    trees = [t for t in world["trees"] if bgx0 <= t[0] < bgx1 and bgy0 <= t[1] < bgy1]
    doors = [d for d in world["doors"] if bgx0 <= d["x"] < bgx1 and bgy0 <= d["y"] < bgy1]
    name = region.capitalize()
    path = os.path.join(WORLD_DIR, "%s.lua" % name)
    os.makedirs(WORLD_DIR, exist_ok=True)
    with open(path, "wb") as f:
        out = [header(path),
               "-- %s: blocks %d..%d x %d..%d (32x32 tiles: ground, overlay, shade, area per 8x8 chunk)\n"
               % (name, bx0, bx1, by0, by1),
               "local addonName, ns = ...\nlocal W = ns.AzeroWorldData\nlocal B = W.blocks\n",
               "-- the ground: WoW's own terrain textures as blended in the client (Media/Azeromon/Ground/%s_<n>.blp)\n"
               "local R = W.AddGround(%s, %d, %d)\n" % (region, lua_str(region), pages, __import__("azw_ground").ROW)]
        out.append("\n".join(lines) + "\n")
        for aid, a in sorted(area_names(areas).items()):
            out.append("W.areas[%d] = %s\n" % (aid, lua_val(a)))
        # every tree, bush, fence, prop and building, drawn from its own model (azw_scenery): the sprites
        # (page, u, v, w, h, origin x, y) and where each stands (sprite, x, y, sort y in map pixels, size x 100)
        sp = []
        for s_ in scen["sprites"]:
            h_, w_ = s_["img"].shape[:2]
            sp += [s_["page"], s_["u"], s_["v"], w_, h_, int(round(s_["ox"])), int(round(s_["oy"]))]
        out.append("local SP = W.AddSprites(%s, %d, %d, { %s })\n" % (lua_str(region), scen["pages"], SCN.PXT,
                                                                       ", ".join(map(str, sp))))
        pl = []
        for p_ in scen["placements"]:
            kk = int(round(p_.get("k", 1) * 100))
            pl += [p_["s"], int(round(p_["x"] * 16)), int(round(p_["y"] * 16)), int(round(p_["sort"] * 16)),
                   -kk if p_.get("kind") == "tree" else kk]           # (negative: a tree, its crown may fade)
        out.append("W.AddScenery(SP, { %s })\n" % ", ".join(map(str, pl)))
        for d in doors:
            out.append("W.AddDoor(%s)\n" % lua_val({"x": d["x"], "y": d["y"], "ox": d["out"][0], "oy": d["out"][1],
                                                     "wmo": d["wmo"], "uid": d["uid"]}))
        for it in interiors:
            for l in it["levels"]:
                out.append("W.AddInterior(%s, %s)\n" % (lua_str(l["id"]), lua_val({
                    "name": l["name"], "level": l["level"], "rows": l["rows"],
                    "stairs": [{"x": w_["x"], "y": w_["y"], "map": "i%d_%d" % (it["uid"], w_["to"]),
                                "tx": w_["tx"], "ty": w_["ty"]} for w_ in l["warps"]]})))
            for d in it["doors"]:
                if "inside" in d and False:
                    pass
                if "inside" in d:
                    out.append("W.LinkDoor(%d, %d, %s, %d, %d)\n" % (d["x"], d["y"], lua_str("i%d_0" % it["uid"]),
                                                                     d["inside"][0], d["inside"][1]))
        # the floors drawn from the building's own model (azw_scenery.build_interiors)
        if interiors:
            import azw_interior as AI
            ia = SCN.build_interiors(interiors, os.path.join(MEDIA, "Scenery", region + "_in"), AI.FINE)
            sp = []
            for s_ in ia["sprites"]:
                h_, w_ = s_["img"].shape[:2]
                sp += [s_["page"], s_["u"], s_["v"], w_, h_, int(round(s_["ox"])), int(round(s_["oy"]))]
            out.append("local IA = W.AddSprites(%s, %d, %d, { %s })\n" % (lua_str(region + "_in"), ia["pages"], SCN.PXT,
                                                                          ", ".join(map(str, sp))))
            for mid, pls in sorted(ia["maps"].items()):
                flat = []
                for p_ in pls:
                    flat += [p_["s"], int(round(p_["x"] * 16)), int(round(p_["y"] * 16))]
                out.append("W.AddInteriorArt(%s, IA, { %s })\n" % (lua_str(mid), ", ".join(map(str, flat))))
            print("interiors %s: %d pieces, %d page(s)" % (region, len(ia["sprites"]), ia["pages"]))
        for e in entities:
            if e.get("map") or (bgx0 <= e["x"] < bgx1 and bgy0 <= e["y"] < bgy1):
                out.append("W.Add(%s)\n" % lua_val(e))
        f.write("".join(out).encode("utf-8"))
    print("wrote", path, os.path.getsize(path), "bytes")
    return (bgx0, bgx1, bgy0, bgy1)


NPC_FLAGS = [(0x2, "quest"), (0x20, "classtrainer"), (0x40, "proftrainer"), (0x80, "vendor"), (0x1000, "repair"),
             (0x2000, "flight"), (0x10000, "inn"), (0x20000, "bank"), (0x400000, "stable"), (0x200000, "auction")]


def gossip_text(db, menu):
    """The NPC's greeting (its gossip menu's first text), or None."""
    if not menu:
        return None
    rows = db.multi("gossip_menu", "entry").get(menu) or []
    texts = db.index("npc_text", "ID")
    for r in rows:
        t = texts.get(r["text_id"])
        if t:
            s = t.get("text0_0") or t.get("text0_1")
            if s:
                return s.replace("$B", "\n").replace("$b", "\n").strip()
    return None


def entities_for(world, gbox):
    """Creatures and objects of the area as Lua-ready dicts, plus the creature entries fought there."""
    import azw_entities as E
    import tbcdb
    db = tbcdb.load()
    ct = db.index("creature_template", "Entry")
    models = db.index("creature_model_info", "modelid")
    r = world["r"]
    gx0, gx1, gy0, gy1 = gbox
    out, fought = [], set()
    creatures = E.creatures(gx0, gx1, gy0, gy1)
    # buildings with a door get an inside (azw_interior): the creatures standing in their footprint go there
    import azw_interior as AI
    interiors, placed = [], {}
    anames = None
    for b in world.get("buildings", []):
        uid = b["w"][7]
        bdoors = [d for d in world["doors"] if d["uid"] == uid and gx0 <= d["x"] < gx1 and gy0 <= d["y"] < gy1]
        if not bdoors:
            continue
        ins = []
        for c in creatures:
            x, y = int(c["x"]), int(c["y"])
            lx, ly = x - r["gx0"], y - r["gy0"]
            if (x, y) not in b["cells"] or not (0 <= lx < r["W"] and 0 <= ly < r["H"]):
                continue
            if b.get("cave"):
                ground = float(r["z"][ly, lx])
                if c["z"] < ground - 3:                  # under the hill: in the tunnels
                    ins.append(c)
            elif world["O"][ly, lx] in "RD":
                ins.append(c)
        d0 = bdoors[0]
        aid = int(r["area"][d0["y"] - r["gy0"], d0["x"] - r["gx0"]])
        if anames is None:
            anames = {}
        if aid not in anames:
            anames.update(area_names({aid}))
        name = anames.get(aid, {}).get("name", "Inside")
        levels = AI.build(b["w"], bdoors, ins, name, single=b.get("cave", False))
        for l in levels:
            l["id"] = "i%d_%d" % (uid, l["level"])
            for (c, ix, iy) in l["npcs"]:
                placed[c["guid"]] = (l["id"], ix, iy)
        if levels:
            interiors.append({"uid": uid, "levels": levels, "doors": bdoors, "w": b["w"], "cave": b.get("cave", False)})
    for c in creatures:
        x, y = int(c["x"]), int(c["y"])
        base = {"g": c["guid"], "x": x, "y": y, "f": E.facing(c["face"])}
        if c["guid"] in placed:
            mid, ix, iy = placed[c["guid"]]
            base.update(map=mid, x=ix, y=iy)
            c = dict(c, move=0, path=[])
        if c["move"] == 1 and c["wander"]:
            base["w"] = max(1, int(round(c["wander"] / A.TS)))
        if c["path"]:
            base["p"] = [v for (px, py, wt) in c["path"] for v in (int(px), int(py), int(wt // 1000))]
        if c["reaction"] == "friendly":
            t = ct[c["entry"]]
            roles = [name for bit, name in NPC_FLAGS if c["npcflags"] & bit]
            mi = models.get(c["display"][0]) if c["display"] else None
            e = dict(base, k="npc", e=c["entry"], n=c["name"], t=c["sub"] or None, roles=roles or None,
                     d=c["display"][0] if c["display"] else None,
                     sex=(mi["gender"] if mi else 0), lvl=c["lvl"][1], say=gossip_text(db, t["GossipMenuId"]),
                     cls=t["TrainerClass"] or None)
            out.append(e)
        elif c["type"] in (8, 12):
            # critters (rabbits, squirrels, deer, the Crazy Cat Lady's cats): they wander, nobody fights them
            e = dict(base, k="critter", e=c["entry"], d=c["display"][0] if c["display"] else None)
            out.append(e)
        else:
            fought.add(c["entry"])
            e = dict(base, k="mob", e=c["entry"], lv=list(c["lvl"]), h=(c["reaction"] == "hostile") or None,
                     r=int(c["respawn"] or 300))
            if c["pool"]:
                e["pool"] = c["pool"]
            out.append(e)
    for o in E.objects(gx0, gx1, gy0, gy1):
        kind = None
        n = o["name"] or ""
        if o["type"] == 3 and re.search(r"Vein|Deposit", n):
            kind = "ore"
        elif o["type"] == 3 and n in ("Peacebloom", "Silverleaf", "Earthroot", "Mageroyal", "Briarthorn",
                                      "Bruiseweed", "Stranglekelp", "Swiftthistle", "Kingsblood", "Liferoot",
                                      "Wild Steelbloom", "Grave Moss", "Fadeleaf", "Goldthorn", "Khadgar's Whisker"):
            kind = "herb"
        elif o["type"] == 3 and re.search(r"Chest|Crate|Box", n) and not db.multi("gameobject_questrelation", "id").get(o["entry"]):
            kind = "chest" if "Chest" in n else "quest"
        elif o["type"] == 3:
            kind = "quest"
        elif o["type"] == 19:
            kind = "mail"
        elif o["type"] in (2, 9):        # questgiver objects / readable texts
            kind = "read"
        if not kind:
            continue
        out.append({"k": "obj", "g": o["guid"], "e": o["entry"], "n": n, "kind": kind, "x": int(o["x"]),
                    "y": int(o["y"])})
    return out, fought, interiors


MEDIA = os.path.join(ADDON, "Media", "Azeromon")
MOB_COLS = 5                 # creatures per row of the sheet (3 frame columns each, 4 facing rows)


# the player's own race / sex (ChrRaces IDs of TBC) get a body each
PLAYER_RACES = {1: "Human", 2: "Orc", 3: "Dwarf", 4: "NightElf", 5: "Scourge", 6: "Tauren", 7: "Gnome", 8: "Troll",
                10: "BloodElf", 11: "Draenei"}


def emit_sprite_sheet(displays):
    """Media/Azeromon/mobs.tga: one map sprite per display, from its own model (azw_people), 3 walk frames x 4
    facings each, 5 to a row. displays: [display id]. -> ({display: index}, sheet height)"""
    from PIL import Image
    import azw_people as PP
    out, frames = {}, []
    for d in displays:
        if d in out or not d:
            continue
        try:
            if isinstance(d, tuple) and d[0] == "outfit":       # ("outfit", race, sex, items): a dressed player
                f = PP.outfit_frames(d[1], d[2], list(d[3]))
            else:
                f = PP.frames(d)
        except Exception as e:            # a model the renderer cannot read: that one keeps the old sprites
            print("no sprite for display", d, e)
            f = None
        if f:
            out[d] = len(frames)
            frames.append(f)
    cell = PP.SIZE
    rows = (len(frames) + MOB_COLS - 1) // MOB_COLS
    h = 64
    while h < rows * 4 * cell:
        h *= 2
    sheet = Image.new("RGBA", (512, h), (0, 0, 0, 0))
    for i, f in enumerate(frames):
        cx, cy = (i % MOB_COLS) * 3, (i // MOB_COLS) * 4
        for fr, face in enumerate(("down", "left", "right", "up")):
            for k in range(3):                             # stride, stand, stride (no Walk sequence: a bob)
                img = Image.fromarray(f[face][k], "RGBA")
                bob = 0 if f.get("walked") or k == 1 else 2
                sheet.paste(img, ((cx + k) * cell, (cy + fr) * cell - bob), img)
    from azw_blp import write_dxt5
    write_dxt5(sheet, os.path.join(MEDIA, "mobs.blp"))
    print("wrote mobs.blp", sheet.size, len(frames), "sprites")
    return out, h


# the player classes' looks (Disastercraft): a human in the class's starting outfit (CharStartOutfit, race 1;
# hearthstone, food and water left out), 0 = male, 1 = female
CLASS_OUTFITS = {"WARRIOR": (38, 39, 40, 25, 2362), "MAGE": (56, 1395, 55, 35), "PRIEST": (6098, 52, 53, 51, 36)}


def emit_species(species, sheet, sheet_h, players):
    path = os.path.join(WORLD_DIR, "Species.lua")
    order = sorted(species.values(), key=lambda s: (s["lvl"][0], s["entry"]))
    sprites = {s["entry"]: sheet[s["display"]] for s in order if s.get("display") in sheet}
    with open(path, "wb") as f:
        out = [header(path),
               "-- Battle species of the real creatures (azw_species.py): real names and models, element from type /\n"
               "-- family, stats from an archetype grown with the creature's level, catch = 0 never tamed.\n",
               "local addonName, ns = ...\nns.AzeroData = ns.AzeroData or {}\nlocal D = ns.AzeroData\nlocal S = {}\nD.worldSpecies = S\n"]
        for i, s in enumerate(order):
            d = {"name": s["name"], "type": s["type"], "num": i + 1, "display": s["display"], "catch": s["catch"],
                 "exp": s["exp"], "base": s["base"], "entry": s["entry"], "lvl": list(s["lvl"]),
                 "learn": [list(x) for x in s["learn"]]}
            if s["catch"] == 0:
                d["untameable"] = True
            if s["rank"]:
                d["rank"] = s["rank"]
            if s.get("evolve"):
                d["evolve"] = {"into": s["evolve"][0], "level": s["evolve"][1]}
            if s["entry"] in sprites:
                d["spr"] = sprites[s["entry"]]
            out.append("S.%s = %s\n" % (s["key"], lua_val(d)))
        out.append("S._byEntry = { %s }\n" % ", ".join("[%d] = %s" % (s["entry"], lua_str(s["key"])) for s in order))
        out.append("D.MOB_SHEET_H = %d          -- Media/Azeromon/mobs.blp: 512 x this, 5 a row, 32 px frames\n" % sheet_h)
        out.append("-- the player's own body by race and sex (UnitRace file name, UnitSex 2 / 3)\n")
        out.append("D.PLAYER_SPR = { %s }\n" % ", ".join('["%s%d"] = %d' % (k[0], k[1], v) for k, v in sorted(players.items())))
        cls = {}
        for c, items in CLASS_OUTFITS.items():
            for sex in (0, 1):
                key = ("outfit", 1, sex, items)
                if key in sheet:
                    cls["%s%d" % (c, sex)] = sheet[key]
        out.append("-- the classes' starting outfits (a human: 0 male, 1 female), drawn from the models with their items\n")
        out.append("D.CLASS_SPR = { %s }\n" % ", ".join("%s = %d" % (k, v) for k, v in sorted(cls.items())))
        f.write("".join(out).encode("utf-8"))
    print("wrote", path, os.path.getsize(path), "bytes")


def emit_quests(npcs, objects):
    import azw_quests as QZ
    path = os.path.join(WORLD_DIR, "Quests.lua")
    qs = QZ.quests_for(npcs, objects)
    with open(path, "wb") as f:
        out = [header(path),
               "-- The real quests of the built zones (azw_quests.py, cMaNGOS TBC). Texts keep WoW's $N / $C / $R / $G\n"
               "-- placeholders; World/Quests are run by WorldGame.lua.\n",
               "local addonName, ns = ...\nlocal Q = {}\nns.AzeroWorldData.quests = Q\n"]
        for q in qs:
            out.append("Q[%d] = %s\n" % (q["id"], lua_val(q)))
        f.write("".join(out).encode("utf-8"))
    print("wrote", path, os.path.getsize(path), "bytes,", len(qs), "quests")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "preview"
    world = build()
    if cmd == "lua":
        import azw_species as SP
        import azw_people as PP
        fought_all, npc_entries, obj_entries = set(), set(), set()
        regions = []
        for region in sys.argv[2:] or ["northshire"]:
            x0, x1, y0, y1, m = region_bbox(world, region)
            r = world["r"]
            gb = ((x0 + r["gx0"]) // BLOCK * BLOCK, ((x1 + r["gx0"]) // BLOCK + 1) * BLOCK,
                  (y0 + r["gy0"]) // BLOCK * BLOCK, ((y1 + r["gy0"]) // BLOCK + 1) * BLOCK)
            ents, fought, interiors = entities_for(world, gb)
            fought_all |= fought
            npc_entries |= {e["e"] for e in ents if e["k"] == "npc"}
            obj_entries |= {e["e"] for e in ents if e["k"] == "obj"}
            regions.append((region, ents, interiors))
        species = SP.species_for(fought_all)
        players = {}
        for race, file in PLAYER_RACES.items():
            for sex in (0, 1):
                players[(file, sex + 2)] = PP.player_display(race, sex)
        displays = [s["display"] for s in species.values()]
        displays += [e["d"] for _, ents, _ in regions for e in ents if e["k"] in ("npc", "critter") and e.get("d")]
        displays += [d for d in players.values() if d]
        displays += [("outfit", 1, sex, items) for items in CLASS_OUTFITS.values() for sex in (0, 1)]
        sheet, sheet_h = emit_sprite_sheet(displays)
        for region, ents, interiors in regions:
            for e in ents:
                if e["k"] in ("npc", "critter") and e.get("d") in sheet:
                    e["spr"] = sheet[e["d"]]
                e.pop("d", None)
            emit(world, region, ents, interiors)
        emit_species(species, sheet, sheet_h, {k: sheet[d] for k, d in players.items() if d in sheet})
        emit_quests(npc_entries, obj_entries)
        sys.exit(0)
    if world["unknown"]:
        print("unclassified doodads:", sorted(world["unknown"].items(), key=lambda kv: -kv[1])[:60])
    if cmd == "preview":
        region = sys.argv[2] if len(sys.argv) > 2 else "northshire"
        out = sys.argv[3] if len(sys.argv) > 3 else os.path.join(SCRATCH, "preview_%s.png" % region)
        preview(world, region, out)

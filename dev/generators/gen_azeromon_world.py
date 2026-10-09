"""Azeromon's overworld from the real Eastern Kingdoms (see dev/docs/azeromon_world/PLAN.md).

    luaenv\\Scripts\\python.exe generators\\gen_azeromon_world.py preview [region]   # PNG of the classified map
    luaenv\\Scripts\\python.exe generators\\gen_azeromon_world.py lua                # write the addon's World data

Pipeline: azw_raw (terrain per tile) -> ground classes (azw_classify) -> WMOs (azw_struct) -> doodads -> layers:
    G  ground class char per tile (azw_classify.CLASSES)
    O  overlay char per tile (OVER below): trunks, rocks, fences, props, building roofs / walls, bridges
    S  hill shade 0..9 per tile (light from the north-west, from the terrain normal)
and entity lists (trees with crown sizes, NPCs, mobs...). Buildings with rooms are walked in place: azw_building."""
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
    # the rest of Elwynn Forest (AreaTable children of 12) - build it after Northshire: "lua northshire elwynn"
    "elwynn": {12, 18, 53, 54, 56, 57, 60, 61, 62, 63, 64, 80, 86, 87, 88, 89, 91, 92, 120, 797, 798},
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
    111538: "cave",          # Jasperlode Mine
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
        # a building with rooms (indoor groups) is walked in place: azw_building makes its walk grid when its
        # region is written (building_grids)
        bb = info["w"][3]
        if info["indoor"] and max(bb[3] - bb[0], bb[5] - bb[2]) <= 400:
            buildings.append({"w": info["w"], "kind": info["kind"]})
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
    return {"r": r, "G": G, "O": O, "S": S, "trees": trees, "unknown": unknown, "buildings": buildings}


def building_grids(world, gbox, taken=frozenset()):
    """{uid: azw_building grid} of the buildings whose origin lies in the grid box (tiles gx0, gx1, gy0, gy1) and
    not in an earlier region's blocks (cached on the world)."""
    import azw_building as BL
    cache = world.setdefault("grids", {})
    gx0, gx1, gy0, gy1 = gbox
    out = {}
    for b in world["buildings"]:
        w = b["w"]
        x, y = w[1][0] / A.TS, w[1][2] / A.TS
        if not (gx0 <= x < gx1 and gy0 <= y < gy1) or block_of(int(x), int(y)) in taken:
            continue
        if w[7] not in cache:
            cache[w[7]] = BL.grid(world["r"], w, b["kind"])
            if cache[w[7]]:
                print(BL.report(cache[w[7]]))
        if cache[w[7]]:
            out[w[7]] = cache[w[7]]
    return out


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


def emit_collision(world, bx0, bx1, by0, by1):
    """The fine collision layer (azw_collide) of the blocks: per block key an rle3 string of 16-bit masks per tile
    (bit sy * 4 + sx: a solid ~1 yd cell)."""
    import azw_collide as CO
    # (buildings walked in place keep their walls in their own walk grids: azw_building)
    cells = CO.build(dict(world, wmo_kinds=WMO_KINDS, walked_in={b["w"][7] for b in world["buildings"]}),
                     (bx0 * BLOCK, (bx1 + 1) * BLOCK, by0 * BLOCK, (by1 + 1) * BLOCK))
    out = {}
    for by in range(by0, by1 + 1):
        for bx in range(bx0, bx1 + 1):
            out[by * 256 + bx] = rle3([b64(m) for m in CO.masks(cells, bx, by, BLOCK)])
    return out


def patch_collision(world, region, taken=frozenset()):
    """Writes the collision layer into an already generated World/<Region>.lua (the 7th field of each block line)
    without rebuilding its art."""
    x0, x1, y0, y1, m = region_bbox(world, region)
    r = world["r"]
    bx0, bx1 = (x0 + r["gx0"]) // BLOCK, (x1 + r["gx0"]) // BLOCK
    by0, by1 = (y0 + r["gy0"]) // BLOCK, (y1 + r["gy0"]) // BLOCK
    coll = emit_collision(world, bx0, bx1, by0, by1)
    path = os.path.join(WORLD_DIR, "%s.lua" % region.capitalize())
    with open(path, "rb") as f:
        text = f.read().decode("utf-8")
    n = 0

    def sub(mo):
        nonlocal n
        key = int(mo.group(1))
        if key in taken or key not in coll:
            return mo.group(0)
        n += 1
        return "%s, R, [=[%s]=] }" % (mo.group(2), coll[key])
    text = re.sub(r"^(?=B\[(\d+)\] = \{)(.*?), R(?:, \[=\[[^\]]*\]=\])? \}$", sub, text, flags=re.M)
    with open(path, "wb") as f:
        f.write(text.encode("utf-8"))
    print("collision: %d blocks of %s" % (n, path))


def object_models(entities):
    """{gameobject entry: (model FileDataID, size)} for the region's objects (GameObjectDisplayInfo)."""
    import tbcdb
    import gen_disastercraft as GD
    tmpl = tbcdb.load().index("gameobject_template", "entry")
    disp = {int(r["ID"]): int(r["FileDataID"] or 0) for r in GD.table("GameObjectDisplayInfo")}
    out = {}
    for e in entities:
        if e.get("k") != "obj" or e["e"] in out:
            continue
        t = tmpl.get(e["e"])
        fid = t and disp.get(int(t["displayId"] or 0))
        if fid:
            out[e["e"]] = (fid, float(t["size"] or 1))
    return out


def emit(world, region, entities, taken=frozenset()):
    """Writes World/<Region>.lua: the region's blocks, area names, trees, buildings and spawns (but none of the
    blocks in taken: an earlier region's)."""
    import azw_entities as E
    r = world["r"]
    x0, x1, y0, y1, m = region_bbox(world, region)
    gx0, gy0 = r["gx0"], r["gy0"]
    bx0, bx1 = (x0 + gx0) // BLOCK, (x1 + gx0) // BLOCK
    by0, by1 = (y0 + gy0) // BLOCK, (y1 + gy0) // BLOCK
    G, O, S = world["G"], world["O"], world["S"]
    ground, pages = emit_ground(world, region, bx0, bx1, by0, by1)
    coll = emit_collision(world, bx0, bx1, by0, by1)
    import azw_scenery as SCN
    import azw_building as BL
    gbox = (bx0 * BLOCK, (bx1 + 1) * BLOCK, by0 * BLOCK, (by1 + 1) * BLOCK)
    grids = building_grids(world, gbox, taken)
    scen = SCN.build(dict(world, wmo_kinds=WMO_KINDS), gbox, os.path.join(MEDIA, "Scenery", region),
                     objects=object_models(entities), buildings=grids)
    # (an earlier region's blocks are its own: their scenery is not drawn twice)
    scen["placements"] = [p_ for p_ in scen["placements"] if block_of(p_["x"], p_["y"]) not in taken]
    for e in entities:
        if e.get("k") == "obj" and e["e"] in scen["objects"]:
            e["s"], e["sr"] = scen["objects"][e["e"]], region   # (its model's sprite in this region's scenery pages)
    print("scenery %s: %d sprites, %d placements, %d page(s)" % (region, len(scen["sprites"]),
                                                                 len(scen["placements"]), scen["pages"]))
    lines = []
    areas = set()
    for by in range(by0, by1 + 1):
        for bx in range(bx0, bx1 + 1):
            if by * 256 + bx in taken:
                continue
            ys, xs = by * BLOCK - gy0, bx * BLOCK - gx0
            if ys < 0 or xs < 0 or ys + BLOCK > G.shape[0] or xs + BLOCK > G.shape[1]:
                continue                        # (past the edge of the terrain read in: BOX)
            g = "".join("".join(G[ys + j, xs:xs + BLOCK]) for j in range(BLOCK))
            o = "".join("".join(O[ys + j, xs:xs + BLOCK]) for j in range(BLOCK))
            s = "".join("".join(str(v) for v in S[ys + j, xs:xs + BLOCK]) for j in range(BLOCK))
            ar = [int(r["area"][ys + cy * 8, xs + cx * 8]) for cy in range(4) for cx in range(4)]
            areas.update(ar)
            lines.append("B[%d] = { [=[%s]=], [=[%s]=], [=[%s]=], { %s }, [=[%s]=], R, [=[%s]=] }" %
                         (by * 256 + bx, rle(g), rle(o), rle(s), ", ".join(map(str, ar)), ground[by * 256 + bx],
                          coll[by * 256 + bx]))
    bgx0, bgx1, bgy0, bgy1 = bx0 * BLOCK, (bx1 + 1) * BLOCK, by0 * BLOCK, (by1 + 1) * BLOCK
    trees = [t for t in world["trees"] if bgx0 <= t[0] < bgx1 and bgy0 <= t[1] < bgy1
             and block_of(t[0], t[1]) not in taken]
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
        # (a building walked in place: its outside pieces carry its id - hidden while you are in it - and each
        # storey's cut-away picture is its own list, see W.AddBuilding)
        pl, walls, by_bld, cuts = [], [], {}, {}
        for p_ in scen["placements"]:
            if "st" in p_:
                c_ = cuts.setdefault((p_["bld"], p_["st"]), ([], []))
                if p_.get("wall"):
                    c_[1].extend([p_["s"], int(round(p_["x"] * 16)), int(round(p_["y"] * 16)),
                                  int(round(p_["sort"] * 16))])
                else:
                    c_[0].extend([p_["s"], int(round(p_["x"] * 16)), int(round(p_["y"] * 16))])
                continue
            if p_.get("bld"):
                tl, tw = by_bld.setdefault(p_["bld"], ([], []))
            else:
                tl, tw = pl, walls
            if p_.get("wall"):                  # a building's depth slice (see azw_scenery: wmo_pieces)
                tw += [p_["s"], int(round(p_["x"] * 16)), int(round(p_["y"] * 16)), int(round(p_["sort"] * 16))]
                continue
            kk = int(round(p_.get("k", 1) * 100))
            tl += [p_["s"], int(round(p_["x"] * 16)), int(round(p_["y"] * 16)), int(round(p_["sort"] * 16)),
                   -kk if p_.get("kind") == "tree" else kk]           # (negative: a tree, its crown may fade)
        out.append("W.AddScenery(SP, { %s })\n" % ", ".join(map(str, pl)))
        out.append("W.objSprites = W.objSprites or {} W.objSprites[%s] = SP\n" % lua_str(region))
        if walls:
            out.append("W.AddSceneryWalls(SP, { %s })\n" % ", ".join(map(str, walls)))
        # buildings walked in place (azw_building): the walk grid, the storeys, the pictures
        for uid, g in sorted(grids.items()):
            out.append("W.AddBuilding(%s)\n" % lua_val({
                "id": uid, "x0": g["cx0"], "y0": g["cy0"], "w": g["w"], "h": g["h"], "cave": g["cave"] or None,
                "storeys": [{"f": round(st["f"], 2), "top": round(min(st["top"], 9999), 2)} for st in g["storeys"]],
                "rows": BL.encode_rows(g)}))
            tl, tw = by_bld.get(uid, ([], []))
            if tl:
                out.append("W.AddScenery(SP, { %s }, %d)\n" % (", ".join(map(str, tl)), uid))
            if tw:
                out.append("W.AddSceneryWalls(SP, { %s }, %d)\n" % (", ".join(map(str, tw)), uid))
            for k in range(len(g["storeys"])):
                fl, wl = cuts.get((uid, k), ([], []))
                out.append("W.AddBuildingArt(%d, %d, SP, { %s }, { %s })\n" % (uid, k + 1, ", ".join(map(str, fl)),
                                                                                ", ".join(map(str, wl))))
        for e in entities:
            if bgx0 <= e["x"] < bgx1 and bgy0 <= e["y"] < bgy1:
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


def block_of(x, y):
    """The key of the 32x32 block holding world tile (x, y)."""
    return int(y) // BLOCK * 256 + int(x) // BLOCK


def entities_for(world, gbox, taken=frozenset()):
    """Creatures and objects of the area as Lua-ready dicts, plus the creature entries fought there. taken: block
    keys an earlier region already wrote (their spawns, buildings and objects are that region's)."""
    import azw_entities as E
    import tbcdb
    db = tbcdb.load()
    ct = db.index("creature_template", "Entry")
    models = db.index("creature_model_info", "modelid")
    r = world["r"]
    gx0, gx1, gy0, gy1 = gbox
    out, fought = [], set()
    creatures = E.creatures(gx0, gx1, gy0, gy1)
    # in a building walked in place (azw_building) a spawn stands on the layer nearest its height (ht, yd over the
    # building's origin) at its exact spot (xf, yf)
    import azw_building as BL
    grids = building_grids(world, gbox, taken)

    def place(base, fx, fy, z):
        for g in grids.values():
            if not (g["cx0"] <= fx * BL.SUB < g["cx0"] + g["w"] and g["cy0"] <= fy * BL.SUB < g["cy0"] + g["h"]):
                continue
            got = BL.layer_for(g, fx, fy, z - g["oz"], reach=1e9)
            if got:
                base.update(ht=round(got[2]["h"], 2), xf=round(fx, 2), yf=round(fy, 2))
            return
    for c in creatures:
        x, y = int(c["x"]), int(c["y"])
        if block_of(x, y) in taken:
            continue
        base = {"g": c["guid"], "x": x, "y": y, "f": E.facing(c["face"])}
        place(base, c["x"], c["y"], c["z"])
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
        if not kind or block_of(o["x"], o["y"]) in taken:
            continue
        ob = {"k": "obj", "g": o["guid"], "e": o["entry"], "n": n, "kind": kind, "x": int(o["x"]), "y": int(o["y"])}
        if "z" in o:
            place(ob, o["x"], o["y"], o["z"])
        out.append(ob)
    return out, fought


MEDIA = os.path.join(ADDON, "Media", "Azeromon")
MOB_COLS = 5                 # creatures per row of the sheet (3 frame columns each, 8 facing rows)
MOB_FACES = 8                # down, left, right, up, then the diagonals (azw_people.FACES)
MOB_SHEET_H = 4096           # each sheet's height: 16 rows of bodies (the client's textures stop at 4096)
MOB_PER_SHEET = MOB_COLS * MOB_SHEET_H // (MOB_FACES * 32)
HANDS = {}                   # sprite index -> its hand points (azw_people._act_render), for Species.lua D.HANDS
BOXES = {}                   # sprite index -> its standing, facing-you picture's opaque box in the cell (portraits)


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
    # sheets of MOB_PER_SHEET bodies, 2048 high (the client's textures stop at 4096; a region like Elwynn has
    # hundreds of bodies): sprite i lives on sheet i // MOB_PER_SHEET - mobs.blp, mobs_1.blp, ...
    h = MOB_SHEET_H
    nsheets = max(1, (len(frames) + MOB_PER_SHEET - 1) // MOB_PER_SHEET)
    from azw_blp import write_dxt5

    def sheet_name(base, k):
        return "%s.blp" % base if k == 0 else "%s_%d.blp" % (base, k)

    def cell_of(i, cols):
        j = i % MOB_PER_SHEET
        return (j % MOB_COLS) * cols, (j // MOB_COLS) * MOB_FACES

    sheets = [Image.new("RGBA", (512, h), (0, 0, 0, 0)) for _ in range(nsheets)]
    for i, f in enumerate(frames):
        import numpy as np
        ys, xs = np.nonzero(f["down"][1][..., 3])
        if len(xs):
            BOXES[i] = (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)
        cx, cy = cell_of(i, 3)
        sheet = sheets[i // MOB_PER_SHEET]
        for fr, face in enumerate(PP.FACES):
            for k in range(3):                             # stride, stand, stride (no Walk sequence: a bob)
                img = Image.fromarray(f[face][k], "RGBA")
                bob = 0 if f.get("walked") or k == 1 else 2
                sheet.paste(img, ((cx + k) * cell, (cy + fr) * cell - bob), img)
    for k, sheet in enumerate(sheets):
        write_dxt5(sheet, os.path.join(MEDIA, sheet_name("mobs", k)))
    print("wrote mobs sheets", nsheets, "x", (512, h), len(frames), "sprites")
    # Disastercraft's action frames: the same sprite order and rows, 5 columns each (azw_people.ACT_COLS: wind-up,
    # strike, spell ready, spell release, dead), 1024 wide
    acts = [Image.new("RGBA", (1024, h), (0, 0, 0, 0)) for _ in range(nsheets)]
    order = sorted(out.items(), key=lambda kv: kv[1])
    for d, i in order:
        try:
            if isinstance(d, tuple) and d[0] == "outfit":
                f = PP.outfit_act_frames(d[1], d[2], list(d[3]))
            else:
                f = PP.act_frames(d)
        except Exception as e:
            print("no action frames for display", d, e)
            f = None
        if not f:                   # (no model to pose: the standing frame, so the body never vanishes mid-swing)
            w = frames[i]
            f = {face: [w[face][1]] * PP.ACT_COLS for face in PP.FACES}
        if f.get("hands"):
            HANDS[i] = f["hands"]
        cx, cy = cell_of(i, PP.ACT_COLS)
        act = acts[i // MOB_PER_SHEET]
        for fr, face in enumerate(PP.FACES):
            for k in range(PP.ACT_COLS):
                img = Image.fromarray(f[face][k], "RGBA")
                act.paste(img, ((cx + k) * cell, (cy + fr) * cell), img)
    for k, act in enumerate(acts):
        write_dxt5(act, os.path.join(MEDIA, sheet_name("mobs_act", k)))
    # (sheets a smaller build no longer needs)
    for base in ("mobs", "mobs_act"):
        k = nsheets
        while os.path.exists(os.path.join(MEDIA, sheet_name(base, k))):
            os.remove(os.path.join(MEDIA, sheet_name(base, k)))
            k += 1
    print("wrote mobs_act sheets", nsheets)
    return out, h


def hands_lua():
    """D.HANDS[sprite] = { 48 numbers }: per facing (8, sheet order) x pose (stand, ready, release) x hand (left,
    right): (x2 * 100 + y2), x2 / y2 the hand's cell position in half pixels (0..99), negative when the hand is
    behind the body, 0 when the model has no such hand."""
    rows = []
    import azw_people as PP
    for spr in sorted(HANDS):
        h = HANDS[spr]
        vals = []
        for face in PP.FACES:
            for pose in h.get(face, [[None, None]] * 3):
                for pt in pose:
                    if not pt:
                        vals.append(0)
                        continue
                    x2 = max(0, min(99, int(round(pt[0] * 2))))
                    y2 = max(1, min(99, int(round(pt[1] * 2))))
                    v = x2 * 100 + y2
                    vals.append(-v if pt[2] else v)
        rows.append("[%d] = { %s }" % (spr, ", ".join(str(v) for v in vals)))
    return ("-- each body's spell hands per facing and pose (Disastercraft's cast glows; see gen_azeromon_world.hands_lua)\n"
            "D.HANDS = {\n    " + ",\n    ".join(rows) + ",\n}\n")


def emit_seehole():
    """Media/Azeromon/seehole.blp: Disastercraft's see-through mask (UIWorld SeeHoles) - white, with a feathered
    ellipse in the middle where a wall in front of a body shows faintly (28 %)."""
    import numpy as np
    from PIL import Image
    from azw_blp import write_dxt5
    n = 128
    y, x = np.mgrid[0:n, 0:n] + 0.5
    d = np.sqrt(((x - n / 2) / (n / 2)) ** 2 + ((y - n / 2) / (n / 2)) ** 2)
    t = np.clip((d - 0.45) / (0.97 - 0.45), 0, 1)
    t = t * t * (3 - 2 * t)
    img = np.zeros((n, n, 4), np.uint8)
    img[..., :3] = 255
    img[..., 3] = ((0.28 + 0.72 * t) * 255).astype(np.uint8)
    write_dxt5(Image.fromarray(img, "RGBA"), os.path.join(MEDIA, "seehole.blp"))


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
        out.append("D.MOB_FACES = %d             -- facing rows a body (down, left, right, up, downleft, downright, upleft, upright)\n"
                   % MOB_FACES)
        out.append(hands_lua())
        out.append("-- each body's standing, facing-you picture: its opaque box in the 32 px cell (x0, y0, x1, y1; portraits)\n")
        out.append("D.BOX = { %s }\n" % ", ".join("[%d] = { %d, %d, %d, %d }" % ((k,) + BOXES[k]) for k in sorted(BOXES)))
        out.append("D.MOB_PER_SHEET = %d        -- bodies a sheet: sprite i is on mobs_<i // this>.blp (0: mobs.blp)\n"
                   % MOB_PER_SHEET)
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
    if cmd == "collision":
        # only the fine collision layer, into the region files already written (regions in the "lua" order)
        taken = set()
        for region in sys.argv[2:] or ["northshire"]:
            patch_collision(world, region, frozenset(taken))
            x0, x1, y0, y1, m = region_bbox(world, region)
            r = world["r"]
            taken |= {by * 256 + bx for by in range((y0 + r["gy0"]) // BLOCK, (y1 + r["gy0"]) // BLOCK + 1)
                      for bx in range((x0 + r["gx0"]) // BLOCK, (x1 + r["gx0"]) // BLOCK + 1)}
        sys.exit(0)
    if cmd == "lua":
        import azw_species as SP
        import azw_people as PP
        fought_all, npc_entries, obj_entries = set(), set(), set()
        regions = []
        taken = set()                       # blocks written by the regions before (in the order given)
        for region in sys.argv[2:] or ["northshire"]:
            x0, x1, y0, y1, m = region_bbox(world, region)
            r = world["r"]
            gb = ((x0 + r["gx0"]) // BLOCK * BLOCK, ((x1 + r["gx0"]) // BLOCK + 1) * BLOCK,
                  (y0 + r["gy0"]) // BLOCK * BLOCK, ((y1 + r["gy0"]) // BLOCK + 1) * BLOCK)
            before = frozenset(taken)
            ents, fought = entities_for(world, gb, before)
            taken |= {by * 256 + bx for by in range(gb[2] // BLOCK, gb[3] // BLOCK)
                      for bx in range(gb[0] // BLOCK, gb[1] // BLOCK)}
            fought_all |= fought
            npc_entries |= {e["e"] for e in ents if e["k"] == "npc"}
            obj_entries |= {e["e"] for e in ents if e["k"] == "obj"}
            regions.append((region, ents, before))
        species = SP.species_for(fought_all)
        players = {}
        for race, file in PLAYER_RACES.items():
            for sex in (0, 1):
                players[(file, sex + 2)] = PP.player_display(race, sex)
        # (the heroes first: their bodies stay on mobs.blp, which the character screen and the Games poster read)
        displays = [("outfit", 1, sex, items) for items in CLASS_OUTFITS.values() for sex in (0, 1)]
        displays += [d for d in players.values() if d]
        displays += [s["display"] for s in species.values()]
        displays += [e["d"] for _, ents, _ in regions for e in ents if e["k"] in ("npc", "critter") and e.get("d")]
        sheet, sheet_h = emit_sprite_sheet(displays)
        emit_seehole()
        for region, ents, before in regions:
            for e in ents:
                if e["k"] in ("npc", "critter") and e.get("d") in sheet:
                    e["spr"] = sheet[e["d"]]
                e.pop("d", None)
            emit(world, region, ents, before)
        emit_species(species, sheet, sheet_h, {k: sheet[d] for k, d in players.items() if d in sheet})
        emit_quests(npc_entries, obj_entries)
        sys.exit(0)
    if world["unknown"]:
        print("unclassified doodads:", sorted(world["unknown"].items(), key=lambda kv: -kv[1])[:60])
    if cmd == "preview":
        region = sys.argv[2] if len(sys.argv) > 2 else "northshire"
        out = sys.argv[3] if len(sys.argv) > 3 else os.path.join(SCRATCH, "preview_%s.png" % region)
        preview(world, region, out)

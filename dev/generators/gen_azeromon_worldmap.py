"""Azeromon's world map (START > MAP): bake the painted map from the world map's own data (ns.AzeroWorld: places,
roads, zones, gryphon routes), the overworld ground's noise and water colours (gen_azeromon_ground) and the props'
palettes (azeromon_props). One picture, 2 screen units a pixel (336 x 216 -> the 672 x 432 panel).

Writes, in Media/Azeromon/WorldMap (not Ground: gen_azeromon_ground clears files it doesn't know there):
    worldmap.tga        the map by day (512 x 256, the picture top left)
    worldmap_fog1.tga   the mist over each place's surroundings (and Redridge's peaks), packed; _fog2 = the same
                        mist with other noise (the game crossfades the two so it drifts)
    worldmap_lap.tga    the waves lapping the shore: LAP_FRAMES frames of the whole picture, 3 a row
    worldmap_dusk.tga   Duskwood's shape (white, alpha), the mask its mist is drawn through
    worldmap_sprites.tga gryphon frames, clouds and their shadows
and Games/Azeromon/WorldArt.lua (ns.AzeroWorldArt: where all that is, place stamps, lights, smoke, glints, routes).
test_azeromon_worldmap checks WorldArt.lua's hash against the places / roads / zones: re-run this after editing them.

    luaenv\\Scripts\\python.exe generators\\gen_azeromon_worldmap.py
"""
import os, sys, json, math, hashlib
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(DEV, "tests", "boot-ui"))
import gen_azeromon_ground as GG          # noqa: E402
import azeromon_props as P               # noqa: E402

ADDON = os.path.join(os.path.dirname(DEV), "addon", "DisasterZone")
OUT_DIR = os.path.join(ADDON, "Media", "Azeromon", "WorldMap")
ART_LUA = os.path.join(ADDON, "Games", "Azeromon", "WorldArt.lua")
VERSION = 1                               # bump when the look changes without an input change
W, H = 336, 216                           # the map picture; the panel shows it at 2 units a pixel (672 x 432)
TW, TH = 512, 256
GRID, OX, OY = 20, 6, 78                  # grid unit -> pixels: x' = OX + (x + 0.5) * GRID, y' = OY + (y - 0.4) * GRID
                                          # (20: Blackrock, 0.25, fits north of Duskwood under the key bar; the old world was 30)
LAP_FRAMES = 6
FOG_SOFT = 4                              # the mist's edge: this many pixels either side of a place's border

LOAD = """local W = ns.AzeroWorld
  local places, roads, flights, zones = {}, {}, {}, {}
  for _, p in ipairs(W.PLACES) do places[#places + 1] = { id = p.id, zone = p.zone, kind = p.kind, x = p.x, y = p.y } end
  for _, r in ipairs(W.Roads()) do roads[#roads + 1] = { r[1].id, r[2].id } end
  for _, f in ipairs(W.FLIGHTS) do
    local via = {}
    for i, v in ipairs(f.via or {}) do via[i] = { v[1], v[2] } end
    flights[#flights + 1] = { from = f.from, to = f.to, via = via }
  end
  for _, z in ipairs(W.ZONES) do zones[#zones + 1] = { id = z.id } end
  return { places = places, roads = roads, flights = flights, zones = zones }"""


def world_data(c=None):
    """the world map's places, roads, routes and zones, as the game has them"""
    if c is None:
        from _common import solo
        _, c = solo("Alice", tick=2)
    return c.eval_py(LOAD)


def _norm(v):
    if isinstance(v, dict):
        return {k: _norm(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [_norm(x) for x in v]
    if isinstance(v, float) and v == int(v):
        return int(v)
    return v


def inputs_hash(data):
    """what the art depends on: the places, roads, routes, this code, the props and ground code, the atlas"""
    h = hashlib.sha1()
    for p in (__file__, P.__file__, GG.__file__):
        h.update(open(p, "rb").read().replace(b"\r\n", b"\n"))
    h.update(open(os.path.join(GG.MEDIA, "atlas.tga"), "rb").read())
    h.update(json.dumps(_norm(data), sort_keys=True).encode())
    h.update(str(VERSION).encode())
    return h.hexdigest()[:16]


def gx(x):
    return OX + (x + 0.5) * GRID


def gy(y):
    return OY + (y - 0.4) * GRID


def place_px(p):
    return int(round(gx(p["x"]))), int(round(gy(p["y"])))


def bake(DATA):
    PLACES = DATA["places"]
    BY_ID = {p["id"]: p for p in PLACES}
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float64)
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float64)
    fbm = GG.fbm
    BAYER = GG.BAYER
    bay = BAYER[(ys.astype(int) % 4), (xs.astype(int) % 4)]

    # ------------------------------------------------------------------------------------------- land
    # zones as rounded boxes (pixels), the edges warped by noise; the land is their smooth union. Peaks north of
    # Westfall and Duskwood run off the top (the continent carries on north; always misty); Blackrock (0.25) climbs
    # north of Darkshire: Redridge, then the mountain with the Burning Steppes east of it and the Searing Gorge on top.
    ZONE_IDS = ["sea", "westfall", "elwynn", "duskwood", "stv", "north", "redridge", "steppes", "blackrock", "gorge"]
    SHAPES = [  # zone, x0, y0, x1, y1 (grid), corner radius (px)
        ("westfall", -0.42, 0.3, 2.5, 2.52, 10),
        ("elwynn", 0.52, 2.4, 2.48, 4.5, 12),
        ("duskwood", 2.4, 0.38, 5.5, 1.62, 8),
        ("stv", 3.92, 1.6, 6.5, 5.92, 12),
        ("stv", 3.92, 5.5, 5.5, 6.82, 10),
        ("north", -0.42, -3.4, 4.5, 0.42, 8),
        ("redridge", 4.5, -1.05, 8.85, 0.42, 8),
        ("steppes", 7.65, -2.05, 8.9, -1.0, 8),
        ("blackrock", 4.5, -3.4, 7.67, -1.0, 8),
        ("gorge", 6.2, -3.4, 8.0, -2.0, 8),
    ]
    warpx = (fbm(xs / 26, ys / 26, 11) - 0.5) * 16
    warpy = (fbm(xs / 26, ys / 26, 12) - 0.5) * 16
    wx, wy = xs + warpx, ys + warpy


    def rbox(x0, y0, x1, y1, r):
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        hx, hy = (x1 - x0) / 2, (y1 - y0) / 2
        qx, qy = np.abs(wx - cx) - hx + r, np.abs(wy - cy) - hy + r
        return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


    def disc(cx, cy, rx, ry, warp=1.0):
        return (np.hypot((xs + warpx * warp * 0.5 - cx) / rx, (ys + warpy * warp * 0.5 - cy) / ry) - 1) * min(rx, ry)


    dists = []
    for z, x0, y0, x1, y1, r in SHAPES:
        dists.append((z, rbox(gx(x0), gy(y0), gx(x1), gy(y1), r)))
    # Jaguero Isle, off the bay
    jx, jy = place_px(BY_ID["jaguero"])
    dists.append(("stv", disc(jx + 2, jy, 10, 8)))


    def smin(a, b, k=6.0):
        h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
        return b * (1 - h) + a * h - k * h * (1 - h)


    land_d = dists[0][1]
    for _, d in dists[1:-1]:
        land_d = smin(land_d, d)
    land_d = np.minimum(land_d, dists[-1][1])
    # Booty Bay's cove and the channel round Jaguero
    bx, by = place_px(BY_ID["bootybay"])
    land_d = np.maximum(land_d, -disc(bx + 9, by + 3, 7, 6, 0.4))
    land_d = np.maximum(land_d, -disc(jx - 9, jy + 1, 3.5, 12, 0.3))
    land = land_d < 0
    # lakes: Crystal Lake by Goldshire, Lake Nazferiti in the north of the vale, a Duskwood pond
    lakes = (disc(gx(1.32), gy(3.62), 7, 4.5, 0.5) < 0) | (disc(gx(5.62), gy(2.62), 7, 5, 0.5) < 0) | \
            (disc(gx(3.52), gy(1.32), 4, 2.6, 0.4) < 0) | (disc(gx(6.65), gy(0.24), 7, 3.4, 0.4) < 0)   # + Lake Everstill
    land &= ~lakes
    # lava (0.25): a lake in the Steppes, the mountain's lava sea, the Searing Gorge's Cauldron (land, painted later)
    lava = ((disc(gx(8.62), gy(-1.88), 4, 2.4, 0.4) < 0) | (disc(gx(6.5), gy(-1.62), 5, 2.8, 0.4) < 0) |
            (disc(gx(7.62), gy(-2.62), 5, 2.6, 0.4) < 0)) & land

    zone = np.zeros((H, W), dtype=np.int32)
    best = np.full((H, W), 1e9)
    for z, d in dists:
        zi = ZONE_IDS.index(z)
        dn = d + (fbm(xs / 9, ys / 9, 31 + zi) - 0.5) * 6         # ragged borders between zones
        sel = dn < best
        best[sel], zone[sel] = dn[sel], zi
    zone[~land] = 0

    # distance from land (sea side) and from the sea (land side), 4-neighbour chamfer
    def chamfer(mask):
        d = np.where(mask, 0, 999).astype(np.int32)
        for _ in range(2):
            for y in range(H):
                for x in range(W):
                    if d[y, x]:
                        v = d[y, x]
                        if x: v = min(v, d[y, x - 1] + 1)
                        if y: v = min(v, d[y - 1, x] + 1)
                        d[y, x] = v
            for y in range(H - 1, -1, -1):
                for x in range(W - 1, -1, -1):
                    if d[y, x]:
                        v = d[y, x]
                        if x < W - 1: v = min(v, d[y, x + 1] + 1)
                        if y < H - 1: v = min(v, d[y + 1, x] + 1)
                        d[y, x] = v
        return d


    try:
        from scipy.ndimage import distance_transform_edt as edt
        sea_d = np.where(land, 0, edt(~land)).astype(np.float64)
        land_in = np.where(land, edt(land), 0).astype(np.float64)
    except ImportError:
        sea_d = chamfer(land).astype(np.float64)
        land_in = chamfer(~land).astype(np.float64)

    # ------------------------------------------------------------------------------------------- palettes
    atlas = GG.Atlas()


    def ramp(base, n=5, lo=0.55, hi=1.22, warm=(10, 8, -6), cool=(-10, -2, 16)):
        """a pixel-art ramp round a colour: shadows cooler, lights warmer"""
        base = np.asarray(base, dtype=np.float64)
        out = []
        for i in range(n):
            t = i / (n - 1)
            k = lo + (hi - lo) * t
            shift = np.array(cool) * (1 - t) + np.array(warm) * t
            out.append(np.clip(base * k + shift * (abs(t - 0.5) * 2), 0, 255))
        return np.array(out)


    GROUND = {
        1: ramp(atlas.avg("wgrass1") * 0.55 + np.array((150, 150, 64)) * 0.45, lo=0.6, hi=1.18),
        2: ramp(atlas.avg("grass1"), lo=0.5, hi=1.18),
        3: ramp(atlas.avg("dgrass1"), lo=0.55, hi=1.28),
        4: ramp(atlas.avg("jgrass1"), lo=0.5, hi=1.2),
        5: ramp(np.array((150, 92, 66)), lo=0.62, hi=1.3),
        6: ramp(atlas.avg("rgrass1"), lo=0.55, hi=1.2),
        7: ramp(atlas.avg("sgrass1"), lo=0.6, hi=1.25),
        8: ramp(atlas.avg("bfloor1") * 1.3, lo=0.6, hi=1.3),
        9: ramp(atlas.avg("ggrass1"), lo=0.62, hi=1.18),
    }
    PATH = {1: atlas.avg("wpath_c"), 2: atlas.avg("path_c"), 3: atlas.avg("dpath_c"), 4: atlas.avg("jpath_c"), 5: atlas.avg("path_c"),
            6: atlas.avg("rpath_c"), 7: atlas.avg("spath_c") * 1.2, 8: atlas.avg("bpath_c") * 1.3, 9: atlas.avg("gpath_c")}
    SAND = np.array([(206, 176, 120), (226, 200, 146), (240, 222, 172)], dtype=np.float64)
    WATER = GG.THEMES["elwynn"]["water"]
    DEEP2 = np.array(WATER["deep"]) * 0.86

    # ------------------------------------------------------------------------------------------- the ground
    img = np.zeros((H, W, 3))
    height = fbm(xs / 22, ys / 22, 5)
    light = (np.roll(np.roll(height, 1, 0), 1, 1) - np.roll(np.roll(height, -1, 0), -1, 1)) * 9
    tex = fbm(xs / 5, ys / 5, 8) - 0.5

    # forest density per zone (also where trees go)
    forest = np.zeros((H, W))
    fn = fbm(xs / 16, ys / 16, 21)
    forest[zone == 2] = np.clip((fn[zone == 2] - 0.36) * 4, 0, 1)
    forest[zone == 3] = np.clip((fn[zone == 3] - 0.30) * 4, 0, 1)
    forest[zone == 4] = np.clip((fn[zone == 4] - 0.22) * 3, 0, 1)
    forest[zone == 5] = 0
    forest[zone == 6] = np.clip((fn[zone == 6] - 0.34) * 4, 0, 1)            # Redridge's autumn woods
    forest[zone == 7] = np.clip((fn[zone == 7] - 0.5) * 2, 0, 1)             # charred stumps on the ash

    # clearings round places and along roads come later (they need the roads); the ground first
    v = 2.2 + light * 1.1 + tex * 1.2 - forest * 1.0
    for zi, rp in GROUND.items():
        m = zone == zi
        idx = np.clip(np.floor(v + bay - 0.5), 0, len(rp) - 1).astype(int)
        img[m] = rp[idx[m]]


    # ------------------------------------------------------------------------------------------- Westfall's fields
    rng = np.random.default_rng(7)
    seeds = []
    for sy in range(-6, H, 13):
        for sx in range(-6, W, 15):
            seeds.append((sx + rng.uniform(0, 12), sy + rng.uniform(0, 10)))
    seeds = np.array(seeds)
    wm = zone == 1
    pts = np.stack([xs[wm], ys[wm]], 1)
    dd = ((pts[:, None, :] - seeds[None, :, :]) ** 2).sum(2)
    order = np.argsort(dd, 1)
    near, second = order[:, 0], order[:, 1]
    d1 = np.sqrt(dd[np.arange(len(pts)), near])
    d2 = np.sqrt(dd[np.arange(len(pts)), second])
    cellkind = rng.choice([0, 1, 2, 3, 3], size=len(seeds))          # 0 wheat, 1 ploughed, 2 green crop, 3 wild grass
    celldir = rng.integers(0, 3, size=len(seeds))
    FIELD = [np.array([(214, 172, 74), (238, 204, 108)]), np.array([(132, 92, 58), (160, 116, 72)]),
             np.array([(122, 150, 64), (150, 178, 80)])]
    HEDGE = np.array((96, 104, 50))
    px_, py_ = pts[:, 0].astype(int), pts[:, 1].astype(int)
    for i in range(len(pts)):
        k = cellkind[near[i]]
        x, y = px_[i], py_[i]
        if d2[i] - d1[i] < 1.4:
            if k != 3 or cellkind[second[i]] != 3:
                img[y, x] = HEDGE if (x + y) % 3 else HEDGE * 0.8
            continue
        if k == 3 or land_in[y, x] < 3:
            continue
        dirn = celldir[near[i]]
        s = (y if dirn == 0 else (x + y) if dirn == 1 else (x - y)) % 3
        img[y, x] = FIELD[k][1 if s == 0 else 0]

    # ------------------------------------------------------------------------------------------- roads
    def bez(a, c, b, n):
        t = np.linspace(0, 1, n)[:, None]
        return (1 - t) ** 2 * a + 2 * (1 - t) * t * c + t ** 2 * b


    road = np.zeros((H, W), dtype=bool)
    boat = np.zeros((H, W), dtype=bool)
    road_paths = []
    for ri, (ai, bi) in enumerate(DATA["roads"]):
        a, b = BY_ID[ai], BY_ID[bi]
        A, B = np.array(place_px(a), float), np.array(place_px(b), float)
        if abs(A[0] - B[0]) > 2 and abs(A[1] - B[1]) > 2:
            C = np.array([B[0], A[1]]) * 0.7 + (A + B) / 2 * 0.3           # the old L, rounded
        else:
            C = (A + B) / 2
        n = int(np.hypot(*(B - A)) * 3) + 8
        pts_ = bez(A, C, B, n)
        seed = (ri * 13 + 5) % 97
        t = np.linspace(0, 1, n)
        wig = np.sin(t * math.pi) * (fbm(t * 5, np.full_like(t, seed), 41) - 0.5) * 7
        dvec = np.gradient(pts_, axis=0)
        nrm = np.stack([-dvec[:, 1], dvec[:, 0]], 1) / (np.linalg.norm(dvec, axis=1)[:, None] + 1e-9)
        pts_ = pts_ + nrm * wig[:, None]
        path = []
        for x, y in pts_:
            xi, yi = int(round(x)), int(round(y))
            path.append((xi, yi))
            for ox, oy in ((0, 0), (1, 0), (0, 1), (1, 1)):
                X, Y = xi + ox, yi + oy
                if 0 <= X < W and 0 <= Y < H:
                    if land[Y, X] or lakes[Y, X] and ox == 0:
                        road[Y, X] = True
                    else:
                        if ox == 0 and oy == 0:
                            boat[Y, X] = True
        road_paths.append({"a": ai, "b": bi, "pts": path[::2]})

    # clearings: no forest near places or roads
    place_xy = np.array([place_px(p) for p in PLACES], float)
    pd = np.min(np.hypot(xs[..., None] - place_xy[:, 0], ys[..., None] - place_xy[:, 1]), axis=2)
    road_near = road.copy()
    for _ in range(3):
        road_near = road_near | np.roll(road_near, 1, 0) | np.roll(road_near, -1, 0) | np.roll(road_near, 1, 1) | np.roll(road_near, -1, 1)
    forest[pd < 11] = 0
    forest[road_near] = 0

    # road edge (darkened ground), then the road itself (lighter centre)
    edge = (np.roll(road, 1, 0) | np.roll(road, -1, 0) | np.roll(road, 1, 1) | np.roll(road, -1, 1)) & ~road & land
    img[edge] *= 0.78
    for zi, c in PATH.items():
        m = road & (zone == zi) & land
        c = np.asarray(c)
        img[m] = c * np.where(((xs + ys * 2) % 5 == 0)[m], 0.9, 1.04)[:, None]
    bridge = road & lakes
    img[bridge] = np.array(P.WOOD[3])

    # ------------------------------------------------------------------------------------------- the sea and shore
    sea = ~land
    deep = np.array(WATER["deep"], float)
    mid = np.array(WATER["mid"], float)
    lightw = np.array(WATER["light"], float)
    foam = np.array(WATER["foam"], float)
    sn = fbm(xs / 30, ys / 18, 51)
    k = np.clip((sea_d - 2) / 9, 0, 1)                       # 0 at the shore, 1 out at sea
    q = k + (bay - 0.5) * 0.25
    water = np.where((q < 0.25)[..., None], lightw, np.where((q < 0.6)[..., None], mid, deep))
    far = (sea_d > 14) & (sn > 0.6)
    water[far & ((xs.astype(int) + ys.astype(int) * 2) % 4 == 0)] = DEEP2           # soft darker deeps, one in four
    wave = (sea_d > 6) & (hash01 := GG.hash_(xs.astype(int) // 5, ys.astype(int) // 4, 77)) .__gt__(0.9)
    wave &= ((xs.astype(int) % 5) < 3) & ((ys.astype(int) % 4) == 0)
    water[wave] = mid * 0.4 + lightw * 0.6
    img[sea] = water[sea]
    img[lakes] = np.where((land_in[lakes] if False else np.ones(lakes.sum(), bool))[:, None], mid, mid)
    lk_edge = lakes & ((np.roll(~lakes, 1, 0)) | np.roll(~lakes, -1, 0) | np.roll(~lakes, 1, 1) | np.roll(~lakes, -1, 1))
    img[lk_edge] = lightw
    img[road & lakes] = np.array(P.WOOD[3])
    # a raised coast: a cliff face under land that has sea below it, then the foam
    cliff1 = sea & np.roll(land, 1, 0)
    cliff2 = sea & np.roll(land, 2, 0) & ~cliff1
    CLIFF = {1: ((150, 120, 76), (112, 86, 56)), 2: ((116, 100, 72), (84, 70, 52)), 3: ((70, 62, 70), (50, 44, 54)),
             4: ((112, 92, 60), (82, 66, 44)), 5: ((92, 84, 76), (62, 56, 52)), 6: ((150, 96, 60), (110, 66, 42)),
             7: ((70, 60, 58), (46, 40, 40)), 8: ((60, 46, 44), (40, 30, 30)), 9: ((170, 92, 52), (124, 62, 36))}
    zabove1, zabove2 = np.roll(zone, 1, 0), np.roll(zone, 2, 0)
    for zi, (c1, c2) in CLIFF.items():
        img[cliff1 & (zabove1 == zi)] = c1
        img[cliff2 & (zabove2 == zi)] = c2
    shore = sea & (sea_d <= 1.0) & ~cliff1 & ~cliff2
    img[shore] = foam
    shore2 = sea & (sea_d > 1.0) & (sea_d <= 2.0) & ~cliff1 & ~cliff2 & ((xs + ys) % 2 == 0)
    img[shore2] = foam * 0.9 + lightw * 0.1
    # beaches: sand on low coasts (not under cliffs facing south)
    beach = land & (land_in <= 2.2) & (zone != 3) & (zone != 5) & (zone < 6)
    bi_ = np.clip((land_in + bay * 1.2 - 0.6).astype(int), 0, 2)
    img[beach & ~road] = SAND[2 - bi_[beach & ~road]]

    # lava: dark crust at the rim, glowing orange inside, bright cracks
    if lava.any():
        lv_in = np.zeros((H, W))
        cur = lava.copy()
        for k_ in range(1, 4):                       # pixels inside the lava's rim (erosion steps)
            lv_in[cur] = k_
            cur = cur & np.roll(cur, 1, 0) & np.roll(cur, -1, 0) & np.roll(cur, 1, 1) & np.roll(cur, -1, 1)
        lv_in[cur] = 4
        lc = np.where((lv_in <= 1)[..., None], np.array((70, 18, 8)), np.where((lv_in <= 2)[..., None],
                      np.array((196, 58, 18)), np.array((244, 112, 30))))
        crack = (lv_in > 2) & (fbm(xs / 4, ys / 4, 97) > 0.62)
        lc[crack] = (255, 196, 90)
        img[lava] = lc[lava]

    # ------------------------------------------------------------------------------------------- stamps
    def pal(*ramp_):
        return [np.array(c, float) for c in ramp_]


    STAMPS = {}


    def stamp(name, rows, colours):
        STAMPS[name] = (rows, colours)


    LEAF_E = [(36, 82, 40), (52, 118, 48), (82, 156, 60), (128, 190, 82), (180, 222, 120)]
    stamp("oak", ["..aab..",
                  ".abbcb.",
                  "abcdcbb",
                  "abccbba",
                  ".abbaa.",
                  "..aaa..",
                  "...t..."], {"a": LEAF_E[0], "b": LEAF_E[1], "c": LEAF_E[2], "d": LEAF_E[3], "t": P.BARK[1]})
    stamp("oak2", [".aab.",
                   "abcbb",
                   "abdca",
                   ".aba.",
                   "..t.."], {"a": LEAF_E[0], "b": LEAF_E[1], "c": LEAF_E[2], "d": LEAF_E[3], "t": P.BARK[1]})
    LEAF_W = [(92, 70, 30), (140, 104, 40), (186, 140, 56), (222, 180, 84)]
    stamp("wtree", [".aab.",
                    "abccb",
                    "abdcb",
                    ".aba.",
                    "..t.."], {"a": LEAF_W[0], "b": LEAF_W[1], "c": LEAF_W[2], "d": LEAF_W[3], "t": P.BARK[1]})
    PINE_D = P.PINE
    stamp("pine", ["..b..",
                   ".bc..",
                   ".bca.",
                   "bcdba",
                   ".bca.",
                   "bccba",
                   "aabaa",
                   "..t.."], {"a": PINE_D[0], "b": PINE_D[1], "c": PINE_D[2], "d": PINE_D[3], "t": P.BARK[0]})
    JL = [(16, 60, 36), (26, 92, 46), (44, 126, 56), (74, 162, 66), (122, 198, 90)]
    stamp("jungle", ["..abba...",
                     ".abccbb..",
                     "abcddcbba",
                     "abccecbba",
                     ".abccbbaa",
                     "..aabaa..",
                     "....t...."], {"a": JL[0], "b": JL[1], "c": JL[2], "d": JL[3], "e": JL[4], "t": P.BARK[1]})
    stamp("palm", ["b.c.b",
                   ".bcb.",
                   "cbdbc",
                   "..t..",
                   "..t..",
                   ".t..."], {"b": JL[2], "c": JL[3], "d": (150, 110, 60), "t": (150, 116, 70)})
    R5 = P.ROCK
    stamp("mount", ["......e......",
                    ".....edc.....",
                    "....eddcb....",
                    "...eddccbb...",
                    "..edddcbbba..",
                    ".eddcccbbbaa.",
                    "edddccbbbaaaa"], {"a": (52, 46, 46), "b": (82, 70, 66), "c": (118, 98, 86), "d": (158, 132, 112),
                                       "e": (198, 172, 146)})
    stamp("mount2", ["...e....",
                     "..edc...",
                     ".eddcb..",
                     "eddcbbaa"], {"a": (52, 46, 46), "b": (82, 70, 66), "c": (118, 98, 86), "d": (158, 132, 112),
                                   "e": (198, 172, 146)})
    ROOF_R = {"a": (92, 22, 24), "R": (204, 70, 52), "b": (150, 40, 36), "w": (238, 226, 200), "W": (196, 180, 152),
              "D": (104, 64, 40), "B": (120, 170, 220), "k": (46, 28, 22)}
    stamp("house", ["...a...",
                    "..aRa..",
                    ".aRRba.",
                    "aRRRbba",
                    ".wwwWW.",
                    ".wDwBW.",
                    ".wDwWW."], ROOF_R)
    stamp("inn", ["...aaaa...",
                  "..aRRRba..",
                  ".aRRRRbba.",
                  "aRRRRRbbba",
                  ".wBwwwBWW.",
                  ".wwwDDwWW.",
                  ".wBwDDwBW."], ROOF_R)
    ROOF_D = dict(ROOF_R, a=(28, 24, 40), R=(82, 72, 116), b=(56, 48, 82), w=(150, 130, 116), W=(112, 96, 88), D=(60, 40, 30))
    stamp("dhouse", ["...a...",
                     "..aRa..",
                     ".aRRba.",
                     "aRRRbba",
                     ".wwwWW.",
                     ".wDwBW.",
                     ".wDwWW."], ROOF_D)
    ROOF_F = dict(ROOF_R, a=(70, 46, 24), R=(204, 166, 92), b=(164, 124, 60))
    stamp("farm", ["...a...",
                   "..aRa..",
                   ".aRRba.",
                   "aRRRbba",
                   ".wwwWW.",
                   ".wDwBW.",
                   ".wDwWW."], ROOF_F)
    stamp("tower", [".a.a.",
                    ".aaa.",
                    "acccb",
                    ".cdb.",
                    ".cBb.",
                    ".ccb.",
                    ".cdb.",
                    ".cDb."], {"a": (72, 74, 86), "c": (180, 182, 190), "b": (106, 108, 120), "d": (142, 144, 154),
                               "B": (120, 170, 220), "D": (60, 40, 30)})
    stamp("flag", ["rr", "r.", "k.", "k."], {"r": (60, 100, 190), "k": (46, 28, 22)})
    stamp("ruin", ["a...a..",
                   "ab.aba.",
                   "ab.ab.a",
                   "abaab.b",
                   "kkkkkkk"], {"a": (90, 84, 76), "b": (58, 52, 48), "k": (40, 34, 30)})
    stamp("lamp", ["y", "k", "k"], {"y": (255, 220, 120), "k": (40, 36, 44)})
    stamp("grave", ["w", "W"], {"w": (214, 210, 200), "W": (120, 116, 108)})
    stamp("cave", ["..abbba..",
                   ".abcccbb.",
                   "abccdccba",
                   "abckkkcba",
                   "abkkkkkba",
                   "aakkkkkaa"], {"a": (52, 46, 46), "b": (92, 84, 76), "c": (130, 118, 104), "d": (166, 152, 132),
                                  "k": (16, 12, 14)})
    stamp("arena", ["...aaaaa...",
                    ".aabbbbbaa.",
                    "abbsssssbba",
                    "absssssssba",
                    "abbsssssbba",
                    ".aabbbbbaa.",
                    "...aaaaa..."], {"a": (92, 84, 76), "b": (166, 152, 132), "s": (226, 196, 146)})
    stamp("tent", ["..a..",
                   ".abb.",
                   "abkbb",
                   "abkbb"], {"a": (226, 204, 166), "b": (154, 122, 92), "k": (46, 28, 22)})
    stamp("gtent", ["..a..",
                    ".abb.",
                    "abkbb",
                    "abkbb"], {"a": (176, 120, 70), "b": (120, 74, 40), "k": (36, 20, 14)})
    stamp("hut", ["..aaa..",
                  ".aRRRa.",
                  "aRRRRba",
                  ".wwDww.",
                  ".k.k.k."], {"a": (110, 80, 30), "R": (206, 168, 70), "b": (164, 124, 44), "w": (124, 78, 46),
                               "D": (46, 28, 22), "k": (84, 52, 34)})
    stamp("pyramid", ["...aa...",
                      "..abba..",
                      ".abbbba.",
                      "abbmbbba",
                      "aabbbbaa"], {"a": (78, 84, 68), "b": (152, 152, 124), "m": (60, 108, 46)})
    stamp("windmill", ["b...b",
                       ".b.b.",
                       "..k..",
                       ".b.b.",
                       "baaab",
                       ".aca.",
                       ".aDa."], {"b": (226, 204, 166), "k": (46, 28, 22), "a": (164, 124, 60), "c": (204, 166, 92),
                                  "D": (70, 46, 24)})
    stamp("manor", ["..a...a..",
                    ".aRa.aRa.",
                    "aRRRaRRRa",
                    ".wBwwwBw.",
                    ".wwwDwww.",
                    ".wBwDwBw."], dict(ROOF_D))
    stamp("ship", [".....k....",
                   "..wwwkww..",
                   "...wwkw...",
                   "aabbbbbbaa",
                   ".abbbbbba."], {"k": (60, 40, 30), "w": (230, 226, 210), "a": (84, 52, 34), "b": (124, 78, 46)})
    stamp("burnt", ["..a..",
                    ".aba.",
                    "a.k.a",
                    ".kkk."], {"a": (46, 40, 38), "b": (90, 60, 40), "k": (30, 24, 22)})
    stamp("sign", ["aaa", ".k."], {"a": (166, 112, 64), "k": (84, 52, 34)})
    LEAF_A = [(110, 34, 22), (168, 64, 30), (214, 110, 40), (240, 168, 70)]          # Redridge's autumn
    stamp("aoak", ["..aab..",
                   ".abbcb.",
                   "abcdcbb",
                   "abccbba",
                   ".abbaa.",
                   "..aaa..",
                   "...t..."], {"a": LEAF_A[0], "b": LEAF_A[1], "c": LEAF_A[2], "d": LEAF_A[3], "t": P.BARK[1]})
    stamp("aoak2", [".aab.",
                    "abcbb",
                    "abdca",
                    ".aba.",
                    "..t.."], {"a": LEAF_A[0], "b": LEAF_A[1], "c": LEAF_A[2], "d": LEAF_A[3], "t": P.BARK[1]})
    stamp("stump", ["k.k", ".k.", ".k.", "kkk"], {"k": (40, 32, 30)})                  # the Steppes' charred trees
    stamp("keep", ["a.a.a.a",
                   "abbbbbb",
                   "abcbbcb",
                   "abbbbbb",
                   "abbkkbb",
                   "aakkkka"], {"a": (60, 52, 50), "b": (120, 108, 98), "c": (255, 170, 70), "k": (30, 24, 22)})
    stamp("dock", ["aaaaaa", "k.k.k."], {"a": (166, 112, 64), "k": (84, 52, 34)})

    shadow = np.zeros((H, W))
    items = []          # (y_base, x, y, name) drawn sorted by the base line


    def put(name, cx, by_):
        """queue stamp `name` with its bottom-centre at (cx, by_)"""
        rows = STAMPS[name][0]
        items.append((by_, name, int(cx - len(rows[0]) // 2), int(by_ - len(rows) + 1)))


    lights, smoke, windows = [], [], []
    boxes = {}


    def draw_items():
        for _, name, x0, y0 in sorted(items):
            rows, cols = STAMPS[name]
            # silhouette shadow, +1 +1
            for j, row in enumerate(rows):
                for i, ch in enumerate(row):
                    if ch != ".":
                        X, Y = x0 + i + 1, y0 + j + 1
                        if 0 <= X < W and 0 <= Y < H and land[Y, X]:
                            shadow[Y, X] = 1
            for j, row in enumerate(rows):
                for i, ch in enumerate(row):
                    if ch != ".":
                        X, Y = x0 + i, y0 + j
                        if 0 <= X < W and 0 <= Y < H:
                            img[Y, X] = np.asarray(cols[ch], float)
                            shadow[Y, X] = 0
                            if ch == "B":
                                windows.append((X, Y))


    # ------------------------------------------------------------------------------------------- forests
    rng = np.random.default_rng(3)
    TREE = {2: ("oak", "oak2"), 3: ("pine", "pine"), 4: ("jungle", "jungle"), 1: ("wtree", "wtree"), 6: ("aoak", "aoak2"),
            7: ("stump", "stump")}
    STEP = {2: 4, 3: 3, 4: 5, 1: 9, 6: 4, 7: 7}
    for zi in (1, 2, 3, 4, 6, 7):
        st = STEP[zi]
        for ty in range(-2, H + 4, st):
            for tx in range(-2, W + 4, st):
                x = int(tx + rng.uniform(0, st)) + (st // 2 if (ty // st) % 2 else 0)
                y = int(ty + rng.uniform(0, st))
                if not (0 <= x < W and 0 <= y < H) or zone[y, x] != zi or land_in[y, x] < 3 or lava[y, x]:
                    continue
                f = forest[y, x] if zi != 1 else (0.6 if fbm(x / 9, y / 9, 61) > 0.62 and pd[y, x] > 9 and not road_near[y, x] else 0)
                if f <= 0 or rng.random() > f * (1.0 if zi != 1 else 0.7):
                    continue
                nm = TREE[zi][rng.integers(0, 2)]
                put(nm, x, y)
    # palms along the jungle's beaches
    for _ in range(260):
        x, y = int(rng.uniform(0, W)), int(rng.uniform(0, H))
        if zone[y, x] == 4 and land[y, x] and 1.5 <= land_in[y, x] <= 4 and pd[y, x] > 6 and not road_near[y, x]:
            put("palm", x, y)
    # mountains along the north rim and in Redridge's corner
    for x in range(-4, W + 8, 9):
        y = int(4 + rng.uniform(0, 4))
        if 0 <= x < W and land[min(y, H - 1), min(max(x, 0), W - 1)]:
            put("mount" if rng.random() < 0.6 else "mount2", x + rng.uniform(-2, 2), y)
    for _ in range(80):
        x, y = int(rng.uniform(0, W)), int(rng.uniform(0, H))
        if zone[y, x] == 5 and land_in[y, x] > 3:
            put("mount" if rng.random() < 0.5 else "mount2", x, y)
    # Blackrock Mountain's peaks and the Gorge's canyon walls, clear of the places, roads and lava
    for _ in range(160):
        x, y = int(rng.uniform(0, W)), int(rng.uniform(0, H))
        if zone[y, x] in (8, 9) and land_in[y, x] > 2 and pd[y, x] > 8 and not road_near[y, x] and not lava[y, x]:
            put("mount2" if zone[y, x] == 9 or rng.random() < 0.5 else "mount", x, y)

    # ------------------------------------------------------------------------------------------- places
    def town(cx, cy, specs):
        for nm, dx, dy in specs:
            put(nm, cx + dx, cy + dy)


    for p in PLACES:
        cx, cy = place_px(p)
        i, k = p["id"], p["kind"]
        if i == "goldshire":
            town(cx, cy, [("house", -6, -2), ("inn", 2, -1), ("house", -3, 5), ("house", 6, 5)])
            smoke += [(cx + 4, cy - 8), (cx - 6, cy - 8)]
            lights += [(cx, cy, "warm", 14)]
        elif i == "sentinel":
            town(cx, cy, [("tower", 0, 0), ("farm", -6, 4), ("farm", 6, 4)])
            put("flag", cx + 1, cy - 8)
            smoke += [(cx - 6, cy - 2)]
            lights += [(cx, cy, "warm", 12)]
        elif i == "darkshire":
            town(cx, cy, [("dhouse", -6, -1), ("dhouse", 3, -2), ("dhouse", -1, 5), ("lamp", -9, 5), ("lamp", 7, 4),
                          ("lamp", 3, 7)])
            smoke += [(cx + 3, cy - 8)]
            lights += [(cx - 9, cy + 3, "lamp", 7), (cx + 7, cy + 2, "lamp", 7), (cx + 3, cy + 5, "lamp", 7), (cx, cy, "warm", 12)]
        elif i == "bootybay":
            town(cx, cy, [("hut", -4, -1), ("hut", 4, 2), ("hut", -2, 6), ("dock", 9, 6)])
            smoke += [(cx - 4, cy - 6)]
            lights += [(cx, cy, "warm", 13), (cx + 9, cy + 5, "lamp", 6)]
        elif i == "moonbrook":
            town(cx, cy, [("burnt", -4, 0), ("burnt", 4, 2), ("ruin", 0, 5)])
            smoke += [(cx - 4, cy - 3), (cx + 4, cy - 1), (cx, cy + 1)]
            lights += [(cx - 4, cy - 1, "ember", 6), (cx + 4, cy + 1, "ember", 6)]
        elif i == "ravenhill":
            town(cx, cy, [("dhouse", -4, 0), ("grave", 3, 3), ("grave", 5, 2), ("grave", 7, 3), ("grave", 4, 5), ("grave", 6, 5)])
        elif i == "duskwood":
            town(cx, cy, [("manor", 0, 2)])
            lights += [(cx, cy, "lamp", 6)]
        elif i == "westfall":
            town(cx, cy, [("farm", -4, 1), ("windmill", 5, 1)])
            smoke += [(cx - 4, cy - 5)]
        elif i == "forestedge":
            town(cx, cy, [("gtent", -3, 1), ("gtent", 3, 2), ("gtent", 0, -2)])
            lights += [(cx, cy + 1, "ember", 7)]
            smoke += [(cx, cy)]
        elif i == "elwynn":
            town(cx, cy, [("sign", 0, 2)])
        elif i == "rebelcamp":
            town(cx, cy, [("tent", -4, 1), ("tent", 3, 0), ("tent", 0, 4)])
            lights += [(cx, cy + 2, "ember", 7)]
            smoke += [(cx, cy + 1)]
        elif i == "stvnorth":
            town(cx, cy, [("tent", -3, 1), ("tent", 3, 1), ("sign", 0, 4)])
            lights += [(cx, cy + 2, "ember", 6)]
        elif i == "zulmamwe":
            town(cx, cy, [("pyramid", 0, 2)])
        elif i == "arena":
            town(cx, cy, [("arena", 0, 3)])
            lights += [(cx - 5, cy, "ember", 6), (cx + 5, cy, "ember", 6), (cx, cy, "warm", 10)]
        elif i == "stvsouth":
            town(cx, cy, [("sign", 0, 2)])
        elif i == "wildshore":
            town(cx, cy, [("pyramid", -4, 2), ("ship", 9, 6)])
        elif i == "jaguero":
            town(cx, cy, [("palm", -3, 2), ("palm", 3, 1), ("palm", 0, -2)])
        elif i == "threecorners":
            town(cx, cy, [("gtent", -3, 1), ("gtent", 3, 2)])
            lights += [(cx, cy + 1, "ember", 6)]
            smoke += [(cx, cy)]
        elif i == "lakeshire":
            town(cx, cy, [("house", -5, -1), ("inn", 3, -1), ("house", -2, 5)])
            smoke += [(cx + 3, cy - 8), (cx - 5, cy - 8)]
            lights += [(cx, cy, "warm", 13)]
        elif i == "everstill":
            town(cx, cy, [("windmill", 3, 0), ("gtent", -4, 2)])
            lights += [(cx - 4, cy + 1, "ember", 5)]
        elif i == "stonewatch":
            town(cx, cy, [("keep", 0, 2)])
            lights += [(cx, cy, "ember", 7)]
        elif i == "steppes":
            town(cx, cy, [("tent", -3, 2), ("tent", 3, 2), ("flag", 0, -1)])
            lights += [(cx, cy + 1, "ember", 6)]
            smoke += [(cx, cy)]
        elif i == "gorge":
            town(cx, cy, [("hut", -3, 1), ("tent", 4, 2)])
            lights += [(cx, cy, "warm", 9)]
            smoke += [(cx - 3, cy - 3)]
        elif k == "dungeon":
            put("cave", cx, cy + 3)
            lights += [(cx, cy + 1, "ember", 5)]
        rows = None
        boxes[i] = [cx - 9, cy - 9, cx + 9, cy + 9]

    draw_items()
    img[(shadow > 0)] *= 0.72
    for y_, x_ in zip(*np.nonzero(lava & (GG.hash_(xs.astype(int), ys.astype(int), 5) > 0.985))):
        lights.append((int(x_), int(y_), "ember", 5))

    # ------------------------------------------------------------------------------------------- the compass
    cx0, cy0 = 20, 186
    for y in range(cy0 - 8, cy0 + 9):
        for x in range(cx0 - 8, cx0 + 9):
            r = math.hypot(x - cx0, y - cy0)
            if r <= 8.4:
                img[y, x] = (42, 46, 54) if r > 7.2 else (214, 200, 160)
            elif r <= 9.6 and y > cy0 and x > cx0 - 6:
                img[y, x] *= 0.75                                     # its shadow on the sea
    for i in range(1, 7):
        w_ = max(0, 2 - i // 3)
        for o in range(-w_, w_ + 1):
            img[cy0 - i, cx0 + o] = (204, 66, 56)                    # north, red
            img[cy0 + i, cx0 + o] = (246, 242, 226)
            img[cy0 + o, cx0 - i] = (246, 242, 226)
            img[cy0 + o, cx0 + i] = (246, 242, 226)
    img[cy0, cx0] = (42, 46, 54)

    # ------------------------------------------------------------------------------------------- fog regions
    # every pixel near a place belongs to it (organic edges); the north-east peaks are the next region (always misty)
    FOG_R = 30
    nx = (fbm(xs / 12, ys / 12, 71) - 0.5) * 14
    dpl = np.hypot(xs[..., None] + nx[..., None] - place_xy[:, 0], ys[..., None] + nx[..., None] * 0.7 - place_xy[:, 1])
    reg = np.argmin(dpl, axis=2) + 1
    reg[np.min(dpl, axis=2) > FOG_R] = 0
    reg[zone == 5] = 255
    reg[(zone == 0) & (sea_d > 7 + (fbm(xs / 8, ys / 8, 73) - 0.5) * 6) & (reg != 255)] = 0

    still = 0.35 * GG.hash_(xs.astype(int), ys.astype(int), 9) + 0.65 * fbm(xs / 6, ys / 6, 83)
    return dict(img=img, reg=reg, sea_d=sea_d, lakes=lakes, lava=lava, zone=zone, still=still, lights=lights, smoke=smoke,
                windows=windows, boxes=boxes, PLACES=PLACES, BY_ID=BY_ID)


# ------------------------------------------------------------------------------------------- the moving parts
def fog_pictures(b):
    """per region: its mist (two noise variants) with a soft stepped edge either side of its border"""
    reg, still = b["reg"], b["still"]
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float64)
    bay = GG.BAYER[(ys.astype(int) % 4), (xs.astype(int) % 4)]
    out = {}
    ids = [(i + 1, p["id"]) for i, p in enumerate(b["PLACES"])] + [(255, "peaks")]
    for r, pid in ids:
        inside = reg == r
        if not inside.any():
            continue
        d_out = edt(~inside)
        d_in = edt(inside)
        a = np.where(inside, 0.5 + 0.5 * np.clip(d_in / FOG_SOFT, 0, 1), 0.5 * (1 - np.clip(d_out / FOG_SOFT, 0, 1)))
        a = np.floor(a * 4 + bay * 0.999) / 4                      # four steps, dithered: pixel-art edges
        a[d_out > FOG_SOFT] = 0
        yy, xx = np.nonzero(a > 0)
        x0, x1, y0, y1 = xx.min(), xx.max() + 1, yy.min(), yy.max() + 1
        pics = []
        for k, (sx, sy) in enumerate(((0, 0), (37, 19))):
            nv = 0.7 * GG.fbm((xs + sx) / 16, (ys + sy) / 16, 91 + k) + 0.3 * GG.fbm((xs - sx) / 7, (ys + sy) / 7, 95 + k)
            lv = np.floor((nv - 0.3) * 6 + bay)
            col = np.where((lv <= 0)[..., None], np.array([150, 160, 186]), np.where((lv == 1)[..., None],
                           np.array([188, 196, 218]), np.array([224, 229, 242])))
            alpha = np.where(lv <= 0, 196, np.where(lv == 1, 214, 232)) * a
            pic = np.zeros((H, W, 4), dtype=np.uint8)
            pic[..., :3] = col
            pic[..., 3] = np.clip(np.round(alpha), 0, 255)
            pics.append(pic[y0:y1, x0:x1])
        out[pid] = (int(x0), int(y0), pics)
    return out


def edt(mask, cap=8):
    """distance from each pixel to the nearest False pixel of `mask` (euclidean, capped at cap + 1)"""
    pad = np.pad(~mask, cap, constant_values=False)
    d = np.where(mask, cap + 1.0, 0.0)
    for dy in range(-cap, cap + 1):
        for dx in range(-cap, cap + 1):
            r = math.hypot(dx, dy)
            if 0 < r <= cap:
                hit = pad[cap + dy:cap + dy + mask.shape[0], cap + dx:cap + dx + mask.shape[1]]
                d = np.where(mask & hit, np.minimum(d, r), d)
    return d


def pack(sizes, width):
    """shelf packing: [(w, h)] -> [(x, y)], total height"""
    order = sorted(range(len(sizes)), key=lambda i: -sizes[i][1])
    pos, x, y, row = [None] * len(sizes), 0, 0, 0
    for i in order:
        w, h = sizes[i]
        if x + w > width:
            x, y, row = 0, y + row, 0
        pos[i] = (x, y)
        x, row = x + w + 1, max(row, h + 1)
    return pos, y + row


def lap_frames(b):
    """the waves lapping the shore: a crest running in to the coast, LAP_FRAMES frames"""
    sea_d, still, lakes = b["sea_d"], b["still"], b["lakes"]
    coast = (sea_d >= 2) & (sea_d <= 4) & ~lakes
    frames = []
    for f in range(LAP_FRAMES):
        t = f / LAP_FRAMES * 2 * math.pi
        on = coast & (np.sin(t - sea_d * 1.35 + still * 5) > 0.82)
        pic = np.zeros((H, W, 4), dtype=np.uint8)
        pic[on] = (226, 244, 246, 190)
        frames.append(pic)
    return frames


def sprite(rows, cols):
    pic = np.zeros((len(rows), len(rows[0]), 4), dtype=np.uint8)
    for y, r in enumerate(rows):
        for x, ch in enumerate(r):
            if ch != ".":
                pic[y, x] = cols[ch]
    return pic


def cloud(seed, w, h):
    pic, sh = np.zeros((h, w, 4), dtype=np.uint8), np.zeros((h, w, 4), dtype=np.uint8)
    hs = lambda i, k: float(GG.hash_(i, k, seed))
    blobs = [(w * (0.2 + 0.6 * hs(i, 1)), h * (0.45 + 0.25 * hs(i, 2)), h * (0.28 + 0.22 * hs(i, 3))) for i in range(5)]
    for y in range(h):
        for x in range(w):
            v = max(1 - math.hypot((x - bx) / 1.4, y - by) / br for bx, by, br in blobs)
            if v > 0:
                lit = 1 if y < h * 0.55 else (0.92 if v > 0.35 else 0.84)
                pic[y, x] = (int(250 * lit), int(250 * lit), min(255, int(255 * lit)), 235)
                sh[y, x] = (8, 18, 32, 46)
    return pic, sh


def sprites():
    """gryphon frames + shadow, three clouds and their shadows -> (sheet 128 x 64, {name: (x, y, w, h)})"""
    GRY = {"b": (196, 150, 80, 255), "h": (244, 240, 226, 255), "t": (120, 84, 50, 255), "k": (0, 0, 0, 72)}
    parts = {
        "gryA": sprite(["b.....b", "bb...bb", ".bbhbb.", "..bhb..", "...t..."], GRY),
        "gryB": sprite([".......", "..bhb..", "bbbhbbb", "b..t..b", "......."], GRY),
        "gryS": sprite(["kkkkk"], GRY),
    }
    for i, (w, h) in enumerate(((34, 12), (26, 10), (40, 13))):
        parts["cloud%d" % (i + 1)], parts["cshadow%d" % (i + 1)] = cloud(i + 1, w, h)
    sheet = np.zeros((64, 128, 4), dtype=np.uint8)
    at, x, y = {}, 0, 0
    for name in ("gryA", "gryB", "gryS"):
        p = parts[name]
        sheet[y:y + p.shape[0], x:x + p.shape[1]] = p
        at[name] = (x, y, p.shape[1], p.shape[0])
        x += p.shape[1] + 1
    for i in range(3):
        for col, name in ((0, "cloud%d" % (i + 1)), (48, "cshadow%d" % (i + 1))):
            p = parts[name]
            yy = 8 + i * 15
            sheet[yy:yy + p.shape[0], col:col + p.shape[1]] = p
            at[name] = (col, yy, p.shape[1], p.shape[0])
    return sheet, at


def save(arr, name):
    arr = np.ascontiguousarray(arr)
    Image.fromarray(arr, "RGBA" if arr.shape[2] == 4 else "RGB").save(os.path.join(OUT_DIR, name))


def main():
    data = world_data()
    b = bake(data)
    os.makedirs(OUT_DIR, exist_ok=True)
    tex = np.zeros((TH, TW, 3), dtype=np.uint8)
    tex[:H, :W] = np.clip(np.round(b["img"]), 0, 255).astype(np.uint8)
    tex[H:, :W] = tex[H - 1:H, :W]
    tex[:, W:] = tex[:, W - 1:W]
    save(tex, "worldmap.tga")
    # mist per region, packed into two sheets of the same layout
    fogs = fog_pictures(b)
    names = sorted(fogs)
    sizes = [(fogs[n][2][0].shape[1], fogs[n][2][0].shape[0]) for n in names]
    pos, used = pack(sizes, 512)
    fh = GG.pot(used)
    fog_rows = []
    for k in range(2):
        sheet = np.zeros((fh, 512, 4), dtype=np.uint8)
        for n, (px, py) in zip(names, pos):
            pic = fogs[n][2][k]
            sheet[py:py + pic.shape[0], px:px + pic.shape[1]] = pic
        save(sheet, "worldmap_fog%d.tga" % (k + 1))
    for n, (px, py), (w, h) in zip(names, pos, sizes):
        fog_rows.append((n, fogs[n][0], fogs[n][1], w, h, px, py))
    # the lapping waves
    frames = lap_frames(b)
    cols = 3
    rows = (LAP_FRAMES + cols - 1) // cols
    lw, lh = GG.pot(cols * W), GG.pot(rows * H)
    lap = np.zeros((lh, lw, 4), dtype=np.uint8)
    for i, fr in enumerate(frames):
        lap[(i // cols) * H:(i // cols + 1) * H, (i % cols) * W:(i % cols + 1) * W] = fr
    save(lap, "worldmap_lap.tga")
    # Duskwood's mask
    dm = np.zeros((TH, TW, 4), dtype=np.uint8)
    dm[:H, :W][b["zone"] == 3] = (255, 255, 255, 255)
    save(dm, "worldmap_dusk.tga")
    sheet, at = sprites()
    save(sheet, "worldmap_sprites.tga")
    # glints: open sea well off the coast, and the lakes
    ys, xs = np.mgrid[0:H, 0:W]
    hs = GG.hash_(xs, ys, 2)
    gl = [(int(x), int(y)) for y, x in zip(*np.nonzero(((b["sea_d"] > 9) & (hs > 0.993)) | (b["lakes"] & (hs > 0.9))))]
    write_lua(data, b, fog_rows, fh, at, gl, (lw, lh, cols))
    keep = {"worldmap.tga", "worldmap_fog1.tga", "worldmap_fog2.tga", "worldmap_lap.tga", "worldmap_dusk.tga",
            "worldmap_sprites.tga"}
    for f in os.listdir(OUT_DIR):
        if f not in keep:
            os.remove(os.path.join(OUT_DIR, f))
    print("baked the world map:", len(fog_rows), "mist regions, sheet 512 x", fh, ",", len(gl), "glints")


def write_lua(data, b, fog_rows, fh, at, glints, lap):
    row = lambda c: "{ " + ", ".join(("%d" % v) if isinstance(v, (int, np.integer)) else ('"%s"' % v) for v in c) + " }"
    BY = b["BY_ID"]
    L = [
        'if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/WorldArt.lua", ...) then return end '
        "-- DisasterZone Games/Azeromon/WorldArt.lua  (GENERATED by dev/generators/gen_azeromon_worldmap.py - do not edit)",
        "-- The painted world map (WorldMap.lua draws it). Pixels of the picture (%d x %d); the panel shows a pixel as" % (W, H),
        "-- 2 x 2 units. Files in Media/Azeromon/WorldMap:",
        "--   worldmap        the map by day (%d x %d of %d x %d)" % (W, H, TW, TH),
        "--   worldmap_fog1/2 mist per place: fog[id] = { x, y, w, h, sx, sy } (where it goes; where it is in the sheet)",
        "--   worldmap_lap    lap = { frames, cols, tw, th }: the waves on the shore, frames of the whole picture",
        "--   worldmap_dusk   Duskwood's shape (its mist's mask), same size as worldmap",
        "--   worldmap_sprites sprites[name] = { x, y, w, h } (gryphon frames, clouds and their shadows)",
        "--   places[id] = { x, y } (centre of its stamp); lights { x, y, kind, radius }; windows / smoke / glints { x, y }",
        "local addonName, ns = ...",
        "ns.AzeroWorldArt = {",
        '    v = "%s", w = %d, h = %d, tw = %d, th = %d, fogH = %d,' % (inputs_hash(data), W, H, TW, TH, fh),
        "    lap = { frames = %d, cols = %d, tw = %d, th = %d }," % (LAP_FRAMES, lap[2], lap[0], lap[1]),
        "    places = { %s }," % ", ".join("%s = { %d, %d }" % ((p["id"],) + place_px(p)) for p in b["PLACES"]),
        "    fog = {",
    ]
    for n, x, y, w, h, sx, sy in fog_rows:
        L.append("        %s = { %d, %d, %d, %d, %d, %d }," % (n, x, y, w, h, sx, sy))
    L.append("    },")
    L.append("    sprites = { %s }," % ", ".join("%s = %s" % (k, row(v)) for k, v in sorted(at.items())))
    L.append("    lights = { %s }," % ", ".join(row((int(x), int(y), k, int(r))) for x, y, k, r in b["lights"]))
    L.append("    windows = { %s }," % ", ".join(row((int(x), int(y))) for x, y in b["windows"]))
    L.append("    smoke = { %s }," % ", ".join(row((int(x), int(y))) for x, y in b["smoke"]))
    L.append("    glints = { %s }," % ", ".join(row(g) for g in glints))
    L.append("    flights = {")
    for f in data["flights"]:
        pts = [place_px(BY[f["from"]])] + [(gx(v[0]), gy(v[1])) for v in f["via"]] + [place_px(BY[f["to"]])]
        L.append('        { from = "%s", to = "%s", pts = { %s } },' % (f["from"], f["to"], ", ".join(
            row((int(round(x)), int(round(y)))) for x, y in pts)))
    L.append("    },")
    L.append("}")
    with open(ART_LUA, "w", newline="\n", encoding="utf-8") as fo:
        fo.write("\n".join(L) + "\n")


if __name__ == "__main__":
    main()

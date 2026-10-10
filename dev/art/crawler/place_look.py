"""A candidate Portal place, looked at before any Lua is written: the room through gen_rooms' pipeline (Blizzard's
geometry cut to a box) plus every doodad the cave / building WMOs place in it (their M2 models, turned and scaled as
the WMO places them) and NPCs at their database spawns, z-buffered with real textures through a follow camera.

Run (from dev):  luaenv\\Scripts\\python.exe art\\crawler\\place_look.py <name> [x y pitch dist yaw] ...
  name: a key of PLACES; each (x y pitch dist yaw) is one picture: room coordinates of the look-at point, the
  camera's pitch (rad, down), distance (yd) and the way it looks (rad, 0 east, pi/2 north). -> shots/place_<name>_<k>.png
"""
import math, os, sys, pickle
import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(DEV, "generators"))
sys.path.insert(0, os.path.join(DEV, "tools"))
import gen_rooms as R  # noqa: E402
import azw_wmo as AW  # noqa: E402
import m2_preview as MP  # noqa: E402

PLACES = {
    # the Keepers of Time's camp in the Caverns of Time (south of the hall, the vendors)
    "cotcamp": dict(mapid=1, mapdir="Kalimdor", box=(-8600.0, -4700.0, -8440.0, -4540.0),
                    spot=(-8527.0, -4606.0, -212.0), up=20.0, down=12.0),
    "tavern": dict(mapid=530, mapdir="Expansion01", box=(-1808.0, 5113.0, -1708.0, 5213.0),
                   spot=(-1758.0, 5163.0, -37.1), up=8.0, down=6.0),
    "honorhold": dict(mapid=530, mapdir="Expansion01", box=(-798.0, 2631.0, -698.0, 2731.0),
                      spot=(-748.2, 2681.5, 100.35), up=14.0, down=10.0),
    "thrallmar": dict(mapid=530, mapdir="Expansion01", box=(106.0, 2623.0, 206.0, 2723.0),
                      spot=(156.3, 2673.5, 85.7), up=14.0, down=10.0),
    "area52": dict(mapid=530, mapdir="Expansion01", box=(2993.0, 3631.0, 3093.0, 3731.0),
                   spot=(3043.3, 3681.3, 143.4), up=14.0, down=10.0),
    "stormspire": dict(mapid=530, mapdir="Expansion01", box=(4100.0, 2966.0, 4200.0, 3066.0),
                       spot=(4150.2, 3015.9, 339.2), up=14.0, down=10.0),
    "cothall": dict(mapid=1, mapdir="Kalimdor", box=(-8620.0, -4460.0, -8380.0, -4160.0),
                    spot=(-8509.0, -4356.0, -208.0), up=30.0, down=15.0),
}
W, H = 1280, 720


class Cam:
    def __init__(self, target, pitch, dist, yaw, fov=1.1):
        self.F = np.array([math.cos(yaw) * math.cos(pitch), math.sin(yaw) * math.cos(pitch), -math.sin(pitch)])
        self.C = np.asarray(target, float) - self.F * dist
        self.R = np.array([math.sin(yaw), -math.cos(yaw), 0.0])
        self.U = np.cross(self.R, self.F)
        self.f = (W / 2) / math.tan(fov / 2)
        self.cx, self.cy = W / 2, H / 2


def quat_rot(q, v):
    qx, qy, qz, qw = q
    x, y, z = v
    ix = qw * x + qy * z - qz * y
    iy = qw * y + qz * x - qx * z
    iz = qw * z + qx * y - qy * x
    iw = -qx * x - qy * y - qz * z
    return (ix * qw - iw * qx - iy * qz + iz * qy, iy * qw - iw * qy - iz * qx + ix * qz,
            iz * qw - iw * qz - ix * qy + iy * qx)


def build(name):
    cfg = PLACES[name]
    BOX, SPOT = cfg["box"], cfg["spot"]
    p = dict(ref="Look:" + name, key="Look_" + name, raid="Look", mapid=cfg["mapid"], mapdir=cfg["mapdir"],
             mapfile=None, rect=(BOX[0], BOX[1], 0, BOX[2], BOX[3], 0), page={}, box=BOX, portrait=SPOT[:2],
             spot=SPOT, how="look", name=name, ref_z=None)
    R.UP[p["ref"]], R.DOWN[p["ref"]] = cfg["up"], cfg["down"]
    r = R.build(p)
    x0, y0, x1, y1 = r["roombox"]
    zb = SPOT[2]

    def to_room(wx, wy, wz):
        return (y1 - wy, wx - x0, wz - zb)
    # the room as a model: parts grouped by texture
    V = np.array([v[:3] for v in r["verts"]], float)
    UV = np.array([v[3:5] for v in r["verts"]], float)
    parts = {}
    for a, b, c, t in r["tris"]:
        parts.setdefault(t, []).append((a, b, c))
    room = dict(V=V, UV=UV, parts=[(np.array(tr), MP.texture(r["textures"][t - 1]), 0) for t, tr in parts.items()])
    # the doodads the WMOs place inside the box (model space -> WMO local -> world -> room)
    dood = []
    pls, _ = R.placements(cfg["mapdir"], BOX)
    for pl in pls:
        rt = AW.load(pl.file)
        fids = rt.get("doodad_fids") or []
        for dd in rt["doodads"]:
            fid = fids[dd["name"]] if dd["name"] < len(fids) else 0
            if not fid:
                continue
            wx, wy, wz = pl.to_world(*dd["pos"])
            if not (BOX[0] <= wx <= BOX[2] and BOX[1] <= wy <= BOX[3]) or abs(wz - zb) > cfg["up"] + 20:
                continue
            try:
                m = MP.model(fid)
            except Exception:
                continue
            if not m["parts"]:
                continue
            Vw = []
            for v in m["V"]:
                lv = quat_rot(dd["rot"], (v[0] * dd["scale"], v[1] * dd["scale"], v[2] * dd["scale"]))
                Vw.append(to_room(*pl.to_world(dd["pos"][0] + lv[0], dd["pos"][1] + lv[1], dd["pos"][2] + lv[2])))
            dood.append(dict(V=np.array(Vw), UV=m["UV"], parts=m["parts"]))
    # NPCs at their spawns
    t = pickle.load(open(os.path.join(DEV, "art", "tbcdb", "tables.pickle"), "rb"))
    cols = t["creature"]["cols"]
    ct = {row[0]: row for row in t["creature_template"]["rows"]}
    ctc = t["creature_template"]["cols"]
    npcs = []
    for row in t["creature"]["rows"]:
        q = dict(zip(cols, row))
        if q["map"] != cfg["mapid"] or not (BOX[0] <= q["position_x"] <= BOX[2] and BOX[1] <= q["position_y"] <= BOX[3]):
            continue
        if abs(q["position_z"] - zb) > 25:
            continue
        e = dict(zip(ctc, ct[q["id"]]))
        if "Specimen" in (e["Name"] or "") or "Trigger" in (e["Name"] or ""):
            continue
        npcs.append((e["Name"], e["DisplayId1"], to_room(q["position_x"], q["position_y"], q["position_z"]),
                     q["orientation"] + math.pi / 2))
    print("%s: room %d tris, %d doodads, %d npcs, roombox %s" % (name, len(r["tris"]), len(dood), len(npcs), r["roombox"]))
    return room, dood, npcs, r


def shot(room, dood, npcs, look, path, title):
    x, y, pitch, dist, yaw = look
    # (look at the floor there: the room's height under the point, roughly)
    V = room["V"]
    near = np.hypot(V[:, 0] - x, V[:, 1] - y) < 6
    z = float(np.median(V[near, 2])) if near.any() else 0.0
    cam = Cam((x, y, z + 1.5), pitch, dist, yaw)
    img = np.zeros((H, W, 3), np.float32) + np.array([0.04, 0.03, 0.05], np.float32)
    zb = np.full((H, W), np.inf, np.float32)
    MP.draw(img, zb, cam, room, np.zeros(3), 0.0, 1.0, H)
    for d in dood:
        MP.draw(img, zb, cam, d, np.zeros(3), 0.0, 1.0, H)
    labels = []
    for name, disp, (nx, ny, nz), facing in npcs:
        try:
            fid, sc, alpha, skins = MP.display(disp)
            MP.draw(img, zb, cam, MP.model(fid, skins), np.array([nx, ny, nz]), facing, sc, H, alpha=alpha)
            sx, sy, d = MP._proj(cam, np.array([[nx, ny, nz + 2.5 * sc]]))
            if d[0] > 0:
                labels.append((float(sx[0]), H - float(sy[0]), name))
        except Exception as e:  # noqa: BLE001
            print("npc", name, e)
    out = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
    dr = ImageDraw.Draw(out)
    for lx, ly, name in labels:
        dr.text((lx - 3 * len(name), ly - 12), name, fill=(255, 220, 120))
    dr.text((10, 8), title, fill=(255, 214, 110))
    out.save(path)
    print("->", path)


def main():
    name = sys.argv[1]
    nums = [float(v) for v in sys.argv[2:]]
    room, dood, npcs, r = build(name)
    looks = [nums[i:i + 5] for i in range(0, len(nums), 5)] or [[r["w"] / 2, r["h"] / 2, 0.9, 40, math.pi / 2]]
    for k, lk in enumerate(looks):
        shot(room, dood, npcs, lk, os.path.join(HERE, "shots", "place_%s_%d.png" % (name, k)),
             "%s  at %.0f,%.0f  pitch %.2f  dist %.0f" % (name, lk[0], lk[1], lk[2], lk[3]))


if __name__ == "__main__":
    main()

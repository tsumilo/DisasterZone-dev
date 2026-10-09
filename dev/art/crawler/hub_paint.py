"""The Portal hub as the addon's own Lua draws it: boots DisasterZone in the harness, opens the Portal (the hub),
puts the player somewhere, ticks the real Games/Portal/UI.lua and paints every texture it placed (room pieces with a
flat shade per texture file, the facade with its real picture, colour textures in their colour) in WoW's draw order,
plus the actors as billboards. Also prints where key points land on screen.

Run (from dev):  luaenv\\Scripts\\python.exe art\\crawler\\hub_paint.py [x y] [out.png]
"""
import math, os, sys
import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(DEV, "tools"))
import harness  # noqa: E402
harness.LOAD_ROOMS = True
from harness import World, Client  # noqa: E402
import render_check as RC  # noqa: E402

SIZE = (1200, 620)
SHOTS = os.path.join(HERE, "shots")

TEXMAP = """
local M = __MOCK local OBJ = M.OBJ local out = {}
local function walk(f)
  local st = OBJ[f]
  for _, ch in ipairs(st.children) do
    local cs = OBJ[ch]
    if cs and cs.parent == f then
      if cs.is_frame then walk(ch)
      elseif cs.kind == "Texture" and type(cs.texture) == "string" and cs.texture ~= "Color" then
        out[#out + 1] = cs.seq .. "=" .. cs.texture
      end
    end
  end
end
walk((ns.PortalUI._View()))
return table.concat(out, "\\n")
"""


def boot():
    w = World()
    c = Client(w, "Alice", class_file="PALADIN", guild_rank=3, guild="Casual Disaster")
    c.load_addon()
    w.tick(2.0)
    c.slash("/dz play portal")
    w.tick(0.3)
    if not c.eval("return ns.PortalUI._View() ~= nil"):
        c.eval("ns.MainFrame:Open('games')")
        w.tick(0.3)
        c.eval("ns.GamesUI:Select('portal')")
    w.tick(0.5)
    with open(RC.LUA_HELPER, encoding="utf-8") as fh:
        c.eval(fh.read())
    c.eval("ns.TrainerUI = ns.PortalUI")          # (the capture helper reads the panel through ns.TrainerUI)
    c.eval("local v = ns.PortalUI._View() v:SetSize(%d, %d)" % SIZE)
    for _ in range(5):
        c.eval("ns.PortalUI._Tick(0.05)")
    return w, c


def set_camera(c, spec):
    """spec: 'pitch,dist,lift,fov' -> the hub's camera, then a fresh start (the lens is set at the start)."""
    pitch, dist, lift, fov = (float(v) for v in spec.split(","))
    c.eval("local e = ns.Trainer:GetEncounter('hub') e.camera.pitch, e.camera.dist, e.camera.lift, e.camera.fov"
           " = %f, %f, %f, %f ns.PortalUI._Start(1)" % (pitch, dist, lift, fov))
    for _ in range(5):
        c.eval("ns.PortalUI._Tick(0.05)")


def pose(c, x, y, ticks=60):
    c.eval("local s = ns.PortalUI._Sim() s.player.x, s.player.y = %f, %f" % (x, y))
    for _ in range(ticks):
        c.eval("ns.PortalUI._Tick(0.05)")
        c.eval("local s = ns.PortalUI._Sim() s.player.x, s.player.y = %f, %f" % (x, y))


def paint(c, out_png):
    view_w, view_h = SIZE
    cap = RC.Capture(c.eval("return __RC.capture_trainer()"), view_w, view_h)
    paths = dict(l.split("=", 1) for l in c.eval(TEXMAP).split("\n") if "=" in l)
    pics = {}
    img = np.zeros((view_h, view_w, 3), np.float32)
    img[:] = (0.24, 0.10, 0.22)                       # the scene's own background where nothing is drawn (purple)
    R = cap.regions
    entries = []
    for i, row in enumerate(R):
        if row[35] <= 0.001 or int(row[0]) != 1:
            continue
        f = cap.frames.get(int(row[2]))
        if f is None or not f["visible"]:
            continue
        entries.append(((f["strata"], f["level"], f["seq"], int(row[3]), int(row[4]), int(row[1])), "tex", i))
    if cap.scene_frame is not None:
        f = cap.frames[cap.scene_frame]
        entries.append(((f["strata"], f["level"], f["seq"], 2, 0, 1 << 40), "scene", -1))
    entries.sort(key=lambda e: e[0])
    yy, xx = np.mgrid[0:view_h, 0:view_w]
    px, py = xx + 0.5, (view_h - yy - 0.5)            # view units, y up
    counts = {"room": 0, "facade": 0, "other": 0}
    for _, kind, i in entries:
        if kind == "scene":
            for a in cap.actors:
                if a["kind"] != 1:
                    continue
                P = np.array(a["pos"])
                sx, sy, d = cap.cam.project(P)
                sx2, sy2, _ = cap.cam.project(P + np.array([0, 0, a["height"]]))
                if not (d > 0):
                    continue
                hw = max(2, abs(sy2 - sy) * 0.22)
                m = (px >= sx - hw) & (px <= sx + hw) & (py >= sy) & (py <= sy2)
                img[m] = (0.2, 0.9, 0.3) if a["unit"] == 1 else (0.3, 0.6, 1.0)
            continue
        row = R[i]
        if np.isnan(row[18:22]).any():
            continue
        (ul, ll, ur, lr), (tul, tll, tur, tlr) = RC.region_quad(row)
        seq = str(int(row[1]))
        path = paths.get(seq, "")
        fid = int(row[5])
        if "Facade" in path:
            what = "facade"
            if path not in pics:
                name = os.path.basename(path.replace("\\", "/")) + ".png"
                pics[path] = np.asarray(Image.open(os.path.join(SHOTS, name)).convert("RGBA"), np.float32) / 255
            pic = pics[path]
        elif fid > 0:
            what, pic = "room", None
        else:
            what, pic = "other", None
        if what == "other":
            continue                                   # (plates, hud: not the scene)
        counts[what] += 1
        for (A, B, C), (ta, tb, tc) in (((ul, ll, ur), (tul, tll, tur)), ((ll, lr, ur), (tll, tlr, tur))):
            x0, x1 = int(max(0, math.floor(min(A[0], B[0], C[0])))), int(min(view_w, math.ceil(max(A[0], B[0], C[0]))))
            y0, y1 = int(max(0, math.floor(min(A[1], B[1], C[1])))), int(min(view_h, math.ceil(max(A[1], B[1], C[1]))))
            if x1 <= x0 or y1 <= y0:
                continue
            sx, sy = px[view_h - y1:view_h - y0, x0:x1], py[view_h - y1:view_h - y0, x0:x1]
            det = (B[1] - C[1]) * (A[0] - C[0]) + (C[0] - B[0]) * (A[1] - C[1])
            if abs(det) < 1e-9:
                continue
            l1 = ((B[1] - C[1]) * (sx - C[0]) + (C[0] - B[0]) * (sy - C[1])) / det
            l2 = ((C[1] - A[1]) * (sx - C[0]) + (A[0] - C[0]) * (sy - C[1])) / det
            l3 = 1 - l1 - l2
            m = (l1 >= 0) & (l2 >= 0) & (l3 >= 0)
            if not m.any():
                continue
            sub = img[view_h - y1:view_h - y0, x0:x1]
            if pic is not None:
                u = l1 * ta[0] + l2 * tb[0] + l3 * tc[0]
                v = l1 * ta[1] + l2 * tb[1] + l3 * tc[1]
                H, W = pic.shape[:2]
                iu = np.clip((u * W).astype(int), 0, W - 1)
                iv = np.clip((v * H).astype(int), 0, H - 1)
                col = pic[iv, iu]
                a = col[..., 3:4] * m[..., None]
                sub[:] = sub * (1 - a) + col[..., :3] * a
            else:
                h = (fid * 2654435761) % 1000 / 1000.0
                shade = np.array([0.45 + 0.25 * h, 0.40 + 0.2 * h, 0.38 + 0.15 * (1 - h)])
                shade = shade * (0.6 + 0.4 * row[6])       # vertex colour (the light)
                sub[m] = shade
    out = (np.clip(img, 0, 1) * 255).astype(np.uint8)
    im = Image.fromarray(out)
    dr = ImageDraw.Draw(im)
    # marks: where the gate's foot and the platform's far edge should land (the mock's own camera)
    def mark(P, colr, label):
        x, y, d = cap.cam.project(np.array([P[0], cap.mirror * P[1], P[2]]))
        if d > 0:
            dr.ellipse((x - 4, view_h - y - 4, x + 4, view_h - y + 4), outline=colr)
            dr.text((x + 6, view_h - y - 6), label, fill=colr)
            return x, y
    pts = {}
    for yy_ in (60, 75, 90):
        pts["gate foot y%d" % yy_] = mark((131.2, yy_, -2.35), (255, 80, 80), "gate foot")
        pts["platform edge y%d" % yy_] = mark((130, yy_, 0), (255, 255, 0), "edge")
    p = cap.player
    if p:
        z = float(c.eval("local s = ns.PortalUI._Sim() return s:FeetZ(s.player)"))
        mark((p[0], p[1], z), (80, 255, 80), "you")
    im.save(out_png)
    print("drawn:", counts, "->", out_png)
    for k, v in pts.items():
        print("  %-20s %s" % (k, None if v is None else "(%.0f, %.0f)" % v))
    return cap


def main():
    args = sys.argv[1:]
    x, y = (float(args[0]), float(args[1])) if len(args) >= 2 else (120.0, 74.3)
    out = args[2] if len(args) >= 3 else os.path.join(SHOTS, "hub_paint.png")
    w, c = boot()
    if len(args) >= 4:
        set_camera(c, args[3])
    pose(c, x, y)
    paint(c, out)


if __name__ == "__main__":
    main()

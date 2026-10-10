"""A Portal place as the addon's own Lua draws it: boots DisasterZone in the harness, opens the Portal (the hub, or
another place with --enc), puts the player somewhere, ticks the real Games/Portal/UI.lua and paints every texture it
placed in WoW's draw order - room pieces with the client's real textures (read with casc_local) and their light,
other picture textures (a facade) from their PNG in shots/ - then the ModelScene's actors as outlined boxes with their
names (the mock has no models; the box is the unit's body, a model file's its client box when known). Use it to judge
a place before it goes to the game: what lines up, what covers what, what the camera shows.

Run (from dev):
  luaenv\\Scripts\\python.exe art\\crawler\\hub_paint.py [x y] [out.png] [--enc hub] [--cam pitch,dist[,yawOff]]
"""
import io, math, os, sys
import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(DEV, "tools"))
sys.path.insert(0, os.path.join(DEV, "generators"))
import harness  # noqa: E402
harness.LOAD_ROOMS = True
from harness import World, Client  # noqa: E402
import render_check as RC  # noqa: E402
import casc_local as CASC  # noqa: E402
import m2_preview as MP  # noqa: E402

PLAYER_DISPLAY = 22931          # (the mock has no player model: drawn as the tank's human)

SIZE = (1200, 680)
SHOTS = os.path.join(HERE, "shots")
# model files the mock cannot measure: their client box (half width, bottom, top over the origin; m2 header 0xA0)
MODEL_BOX = {190850: (31.7, 4.8, 164.4)}       # COT_HourGlass_redo

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

UNITS = """
local s = ns.PortalUI._Sim() local out = {}
for _, u in ipairs(s.units) do
  local d = u.display and s.enc.displays and s.enc.displays[u.display]
  out[#out + 1] = string.format("%d|%s|%s|%s|%.3f|%.3f|%.3f|%s|%.4f|%.4f", u.id, u.name or "?", u.kind or "?",
    tostring(u.fdid or ""), u.x, u.y, s:FeetZ(u), tostring(u.display or ""), u.facing or 0,
    u.scale or (d and d.scale) or 1)
end
return table.concat(out, "\\n")
"""

_TEX = {}


def tex(fid):
    if fid not in _TEX:
        try:
            im = Image.open(io.BytesIO(CASC.read_fid(int(fid)))).convert("RGB")
            _TEX[fid] = np.asarray(im, np.float32) / 255
        except Exception:
            _TEX[fid] = None
    return _TEX[fid]


def boot(enc=None):
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
    if enc:
        c.eval("ns.PortalUI._Select('%s') ns.PortalUI._Start(1)" % enc)
    for _ in range(5):
        c.eval("ns.PortalUI._Tick(0.05)")
    return w, c


def set_camera(c, spec):
    """spec: 'pitch,dist[,yawOff]' -> the place's camera (a fresh start), then the turn."""
    v = [float(x) for x in spec.split(",")]
    c.eval("local s = ns.PortalUI._Sim() local e = s.enc e.camera.pitch, e.camera.dist = %f, %f ns.PortalUI._Start(1)"
           % (v[0], v[1]))
    if len(v) > 2:
        c.eval("ns.PortalUI._Camera().yawOff = %f" % v[2])
    for _ in range(5):
        c.eval("ns.PortalUI._Tick(0.05)")


def pose(c, x, y, ticks=40):
    for _ in range(ticks):
        c.eval("local s = ns.PortalUI._Sim() s.player.x, s.player.y = %f, %f" % (x, y))
        c.eval("ns.PortalUI._Tick(0.05)")


OWNER = {"arr": None, "id": None}


def _fill(img, view_h, px, py, A, B, C, ta, tb, tc, sample):
    view_w = img.shape[1]
    x0, x1 = int(max(0, math.floor(min(A[0], B[0], C[0])))), int(min(view_w, math.ceil(max(A[0], B[0], C[0]))))
    y0, y1 = int(max(0, math.floor(min(A[1], B[1], C[1])))), int(min(view_h, math.ceil(max(A[1], B[1], C[1]))))
    if x1 <= x0 or y1 <= y0:
        return
    sx, sy = px[view_h - y1:view_h - y0, x0:x1], py[view_h - y1:view_h - y0, x0:x1]
    det = (B[1] - C[1]) * (A[0] - C[0]) + (C[0] - B[0]) * (A[1] - C[1])
    if abs(det) < 1e-9:
        return
    l1 = ((B[1] - C[1]) * (sx - C[0]) + (C[0] - B[0]) * (sy - C[1])) / det
    l2 = ((C[1] - A[1]) * (sx - C[0]) + (A[0] - C[0]) * (sy - C[1])) / det
    l3 = 1 - l1 - l2
    m = (l1 >= -1e-4) & (l2 >= -1e-4) & (l3 >= -1e-4)
    if not m.any():
        return
    u = l1 * ta[0] + l2 * tb[0] + l3 * tc[0]
    v = l1 * ta[1] + l2 * tb[1] + l3 * tc[1]
    col, alpha = sample(u, v)
    sub = img[view_h - y1:view_h - y0, x0:x1]
    a = (alpha if alpha is not None else 1.0) * m
    a = a[..., None] if np.ndim(a) == 2 else a
    sub[:] = sub * (1 - a) + col * a
    if OWNER["arr"] is not None:
        OWNER["arr"][view_h - y1:view_h - y0, x0:x1][m] = OWNER["id"]


def paint(c, out_png, title=""):
    view_w, view_h = SIZE
    cap = RC.Capture(c.eval("return __RC.capture_trainer()"), view_w, view_h)
    paths = dict(l.split("=", 1) for l in c.eval(TEXMAP).split("\n") if "=" in l)
    units = {}
    for line in c.eval(UNITS).split("\n"):
        i, name, kind, fdid, x, y, z, disp, facing, scale = line.split("|")
        units[int(i)] = dict(name=name, kind=kind, fdid=int(fdid) if fdid else None, x=float(x), y=float(y), z=float(z),
                             display=int(disp) if disp else None, facing=float(facing), scale=float(scale))
    pics = {}
    img = np.zeros((view_h, view_w, 3), np.float32)
    img[:] = (0.05, 0.04, 0.06)                       # the scene's own background where nothing is drawn
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
    counts = {"room": 0, "picture": 0}
    OWNER["arr"] = np.full((view_h, view_w), -1, np.int64)
    boxes = []
    for _, kind, i in entries:
        if kind == "scene":
            # the models, z-buffered among themselves (the client's ModelScene); the room drawn later (the copies)
            # goes over them as in game. A model the preview cannot read is a faint box.
            zb = np.full((view_h, view_w), np.inf, np.float32)
            for a in cap.actors:
                u = units.get(a["unit"])
                if not u:
                    continue
                try:
                    if u["fdid"]:
                        mdl, alpha = MP.model(u["fdid"]), 1.0
                    else:
                        fid, _sc, alpha, skins = MP.display(u["display"] or PLAYER_DISPLAY)
                        mdl = MP.model(fid, skins)
                    MP.draw(img, zb, cap.cam, mdl, np.array(a["pos"]), cap.mirror * u["facing"], u["scale"], view_h,
                            alpha=alpha)
                    u["drawn"] = True
                except Exception as e:  # noqa: BLE001
                    print("model of %s not drawn: %s" % (u["name"], e))
            for a in cap.actors:
                u = units.get(a["unit"])
                if not u:
                    continue
                P = np.array(a["pos"])
                if u["fdid"] in MODEL_BOX:
                    hw, z0, z1 = MODEL_BOX[u["fdid"]]
                else:
                    hw, z0, z1 = max(0.5, a["width"] / 2), 0.0, a["height"]
                corners = []
                for dz in (z0, z1):
                    for side in (-1, 1):
                        # a billboard across the view: offset along the camera's right vector
                        Q = P + cap.cam.R * side * hw + np.array([0, 0, dz])
                        sx, sy, d = cap.cam.project(Q)
                        if d > 0.1:
                            corners.append((sx, sy))
                if len(corners) == 4:
                    xs, ys = [q[0] for q in corners], [q[1] for q in corners]
                    boxes.append((min(xs), min(ys), max(xs), max(ys), u))
                    if u.get("drawn"):
                        continue
                    m = (px >= min(xs)) & (px <= max(xs)) & (py >= min(ys)) & (py <= max(ys))
                    colr = np.array((0.25, 0.85, 0.3) if a["unit"] == 1 else
                                    (0.95, 0.75, 0.3) if u["kind"] == "npc" else
                                    (0.4, 0.6, 1.0) if u["kind"] == "party" else (0.7, 0.5, 0.9))
                    img[m] = img[m] * 0.55 + colr * 0.45
            continue
        row = R[i]
        if np.isnan(row[18:22]).any():
            continue
        (ul, ll, ur, lr), (tul, tll, tur, tlr) = RC.region_quad(row)
        path = paths.get(str(int(row[1])), "")
        fid = int(row[5])
        if fid > 0 and not path:
            t = tex(fid)
            if t is None:
                continue
            light = np.array(row[6:9])

            def sample(u, v, t=t, light=light):
                th, tw = t.shape[:2]
                return t[(np.floor(v * th).astype(int) % th), (np.floor(u * tw).astype(int) % tw)] * light, None
            counts["room"] += 1
        elif path and os.path.exists(os.path.join(SHOTS, os.path.basename(path.replace("\\", "/")) + ".png")):
            if path not in pics:
                name = os.path.basename(path.replace("\\", "/")) + ".png"
                pics[path] = np.asarray(Image.open(os.path.join(SHOTS, name)).convert("RGBA"), np.float32) / 255
            pic = pics[path]

            def sample(u, v, pic=pic):
                H, W = pic.shape[:2]
                col = pic[np.clip((v * H).astype(int), 0, H - 1), np.clip((u * W).astype(int), 0, W - 1)]
                return col[..., :3], col[..., 3]
            counts["picture"] += 1
        else:
            continue                                   # (plates, hud, colour textures: not the scene)
        OWNER["id"] = i
        _fill(img, view_h, px, py, ul, ll, ur, tul, tll, tur, sample)
        _fill(img, view_h, px, py, ll, lr, ur, tll, tlr, tur, sample)
    for probe in filter(None, os.environ.get("HUB_PROBE", "").split(";")):
        qx, qy = (int(v) for v in probe.split(","))
        i = int(OWNER["arr"][qy, qx])
        if i >= 0:
            row = R[i]
            f = cap.frames.get(int(row[2]))
            print("probe %s: texture %d, frame level %d, layer %d, light %.2f" % (probe, int(row[5]), f["level"], int(row[3]), row[6]))
        else:
            print("probe %s: no texture (a model or nothing)" % probe)
    out = (np.clip(img, 0, 1) * 255).astype(np.uint8)
    im = Image.fromarray(out)
    dr = ImageDraw.Draw(im)
    for x0, y0, x1, y1, u in boxes:
        colr = (90, 255, 110) if u["kind"] == "player" else (255, 210, 110)
        if not u.get("drawn"):
            dr.rectangle((x0, view_h - y1, x1, view_h - y0), outline=colr)
        if u["kind"] != "prop":
            dr.text(((x0 + x1) / 2 - 3 * len(u["name"]), view_h - y1 - 14), u["name"], fill=colr)
    if os.environ.get("HUB_GRID"):
        step = float(os.environ["HUB_GRID"])
        for gx in np.arange(0, 400, step):
            for gy in np.arange(0, 400, step):
                gz = float(c.eval("local s = ns.PortalUI._Sim() local a = s.enc.arena return (a.height and a.height(%f, %f)) or 0" % (gx, gy)))
                sx, sy, d = cap.cam.project(np.array([gx, cap.mirror * gy, gz]))
                if d > 0 and 0 <= sx < view_w and 0 <= sy < view_h:
                    dr.point((sx, view_h - sy), fill=(255, 255, 255))
                    if gx % (2 * step) == 0 and gy % (2 * step) == 0:
                        dr.text((sx + 2, view_h - sy), "%d,%d" % (gx, gy), fill=(200, 255, 255))
    if title:
        dr.text((8, 6), title, fill=(255, 214, 110))
    im.save(out_png)
    print("drawn:", counts, "->", out_png)
    return cap


def main():
    args = sys.argv[1:]
    enc, cam = None, None
    if "--enc" in args:
        k = args.index("--enc")
        enc = args[k + 1]
        del args[k:k + 2]
    if "--cam" in args:
        k = args.index("--cam")
        cam = args[k + 1]
        del args[k:k + 2]
    x, y = (float(args[0]), float(args[1])) if len(args) >= 2 else (None, None)
    out = args[2] if len(args) >= 3 else os.path.join(SHOTS, "hub_paint.png")
    w, c = boot(enc)
    if cam:
        set_camera(c, cam)
    if x is not None:
        pose(c, x, y)
    else:
        pose(c, *[float(v) for v in c.eval_py("local p = ns.PortalUI._Sim().player return {p.x, p.y}")])
    paint(c, out, "%s at %s" % (enc or "hub", "%.0f, %.0f" % (x, y) if x is not None else "start"))


if __name__ == "__main__":
    main()

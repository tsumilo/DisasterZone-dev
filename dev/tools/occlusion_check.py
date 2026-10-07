#!/usr/bin/env python
"""Occlusion check: how often each 3D depth mode of the strategy board hides or shows a boss pixel wrongly, per room.

The modes (UI/StrategyMap3D.lua V:SyncStandins):
  box      occluder boxes and the copies: room pieces drawn again over the models (Render3D/Room.lua, spec 5.13)
  standins stand-ins (Render3D/Standins.lua) write the room's depth under it; no copies
  gaps     stand-ins, and the copies for the room triangles no stand-in covers (Render3D/Standins/Gaps.lua)

For every encounter it opens the board in the harness (wowmock, as tests/strategy/test_standins.py does), orbits the
camera round the boss and, in each mode, runs the board's own Draw and records what it left: the room camera
(Room.CameraTable), the copy textures over the scene (Room.CopyFrames, their rectangles and vertex offsets as the
client would place them) and the stand-ins it shows (their 12 numbers). Then, offline:
  TRUTH    a z-buffer of the room's opaque faces as the renderer draws them (gen_standins.drawn: by each face's BSP
           node), and of every creature on the page: its .m2 in the Stand animation's first frame with its first
           skin's triangles (m2_tools.standing_mesh), placed as the board places it - origin on its spot, turned by
           its facing, times its scale (the baked part boxes are cut from these same vertices).
  PAINTER  box: a boss pixel shows unless a copy texture covers it; standins / gaps: it shows where it is nearer
           than the shown stand-ins' depth (gen_standins.render_standins) and no copy covers it.
A boss pixel is wrong when the painter shows it and the truth does not (shown wrongly: through a wall) or the other
way round (hidden wrongly: cut by something behind it). Pixels where a see-through room face (alpha-keyed or blended:
fences, foliage) lies in front of the boss are left out: their truth depends on the texture's holes.

Limits: the boss stands in its first Stand frame (an animation moves it); a model's alternative geosets (helmets,
weapons) are all drawn; copies are taken as opaque (an alpha-keyed copy has holes in game).

Run: luaenv\\Scripts\\python.exe tools\\occlusion_check.py [Raid:Boss ...] [--poses N] [--px W] [--jobs N]
         [--json FILE] [--write]   (all 55 encounters by default; --jobs runs them in parallel processes)

--write: each room's best mode (fewest wrong pixels; a tie keeps the box mode) into Render3D/Standins/Modes.lua
(ns.RoomDepthModes[room key]): the board's "auto" setting uses it. Rooms not measured keep their old line.
"""
import argparse
import csv
import json
import math
import os
import re
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(DEV, "tests", "strategy"))
sys.path.insert(0, os.path.join(DEV, "generators"))

MODES = ("box", "standins", "gaps")
NEAR = 0.5

CAP = r"""
local OC = {}
__OC = OC
local M = __MOCK
local function vis(f)
  while f do
    local st = M.OBJ[f]
    if not (st and st.shown) then return false end
    f = st.parent
  end
  return true
end
function OC.models()
  local v, out = T3.v(), {}
  for _, e in ipairs(T3.elems()) do
    local g = e.t == 'i' and v:Geo(e)
    if g and g.display then
      out[#out + 1] = { g.display, g.x, g.y, g.z, g.curFace or 0, g.scale or 1 }
    end
  end
  return out
end
-- the client's box of a model (the mock has none): what the board reads from a loaded model
function OC.bb(display, x0, y0, z0, x1, y1, z1)
  for _, a in pairs(T3.v().actors) do
    if a.display == display then
      a.loadedOnce = true
      a.bb = { r = math.max(math.abs(x0), math.abs(x1), math.abs(y0), math.abs(y1)), z0 = math.min(0, z0), z1 = z1,
               x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
    end
  end
end
function OC.mode(m)
  local cfg = ns.StrategyMap3D.standins
  cfg.on, cfg.gaps, cfg.debug = m ~= 'box', m == 'gaps', false
end
function OC.pose(tx, ty, h, p, d)
  local o = T3.v().orb
  o.x, o.y, o.heading, o.pitch, o.dist = tx, ty, h, p, d
end
function OC.capture()
  local v = T3.v()
  v:Draw()
  v:Draw()
  local R, C = v.R, v.R.CameraTable()
  local scene = v.view.scene
  local out = { cam = { C.ex, C.ey, C.ez, C.Fx, C.Fy, C.Fz, C.Rx, C.Ry, C.Ux, C.Uy, C.Uz, C.cx, C.cy, C.exx, C.exy,
                        C.eyx, C.eyy, C.W, C.H }, copies = {}, si = {}, measured = v.measured and true or false }
  local memo, c = {}, out.copies
  for _, f in ipairs(R.CopyFrames()) do
    if vis(f) then
      for _, ch in ipairs(M.OBJ[f].children) do
        local cs = M.OBJ[ch]
        if cs and cs.parent == f and cs.shown and cs.kind == 'Texture' and (cs.alpha or 1) > 0 then
          local l, b, w, h = M.region_rect(ch, scene, memo)
          if l then
            local vo = cs.voff or {}
            local function o(i, k) return vo[i] and vo[i][k] or 0 end
            local n = #c
            c[n + 1], c[n + 2] = l + o(1, 1), b + h + o(1, 2)
            c[n + 3], c[n + 4] = l + o(2, 1), b + o(2, 2)
            c[n + 5], c[n + 6] = l + w + o(3, 1), b + h + o(3, 2)
            c[n + 7], c[n + 8] = l + w + o(4, 1), b + o(4, 2)
          end
        end
      end
    end
  end
  local si = v.standins
  if si then
    local d, st, s = si.set.d, si.set.stride, out.si
    for i in pairs(si.at) do
      local o = (i - 1) * st
      for k = 1, 12 do s[#s + 1] = d[o + k] end
    end
  end
  return out
end
"""


# ---------------------------------------------------------------------------------------------------------------
# the board's camera as gen_standins' rasterizer wants it
# ---------------------------------------------------------------------------------------------------------------
class BoardCam:
    """Room.CameraTable() as a camera for gen_standins.raster / render_standins: screen = c + M (r, u) / d (UI units,
    y up), pixels k per UI unit, y down. to_cam gives (M (r, u), d): raster then puts a point at cx + F r' / d,
    cy - F u' / d with F = k."""

    def __init__(self, t, px):
        ex, ey, ez, Fx, Fy, Fz, Rx, Ry, Ux, Uy, Uz, cx, cy, exx, exy, eyx, eyy, W, H = t
        self.C = np.array([ex, ey, ez])
        self.f = np.array([Fx, Fy, Fz])
        self.r = np.array([Rx, Ry, 0.0])
        self.u = np.array([Ux, Uy, Uz])
        self.M = np.array([[exx, eyx], [exy, eyy]])
        self.k = px / W
        self.W, self.H = int(round(W * self.k)), int(round(H * self.k))
        self.Hui = H
        self.F = self.k
        self.cx, self.cy = cx * self.k, (H - cy) * self.k
        self.near = NEAR
        self.guard = 0.0

    def to_cam(self, P):
        D = np.asarray(P, float) - self.C
        r, u, d = D @ self.r, D @ self.u, D @ self.f
        return np.stack([self.M[0, 0] * r + self.M[0, 1] * u, self.M[1, 0] * r + self.M[1, 1] * u, d], axis=-1)

    def screen_tris(self, xy):
        """UI-unit triangles (n, 3, 2), y up -> camera-space triangles at depth 1 that raster puts on those pixels."""
        xy = np.asarray(xy, float)
        px = xy[..., 0] * self.k
        py = (self.Hui - xy[..., 1]) * self.k
        return np.stack([(px - self.cx) / self.F, -(py - self.cy) / self.F, np.ones(px.shape)], axis=-1)


def zbuf(G, cam, tris):
    z, _ = G.raster(cam, cam.to_cam(tris.reshape(-1, 3)).reshape(-1, 3, 3), np.zeros(len(tris), np.int64))
    return z


# ---------------------------------------------------------------------------------------------------------------
# creature meshes
# ---------------------------------------------------------------------------------------------------------------
_MESH = {}


def creature_mesh(display):
    """display id -> (vertices (n, 3) model units, triangles (m, 3)), the standing pose."""
    if display in _MESH:
        return _MESH[display]
    import gen_rooms as R
    import m2_tools
    cache = os.path.join(R.CACHE, "meshes")
    os.makedirs(cache, exist_ok=True)
    path = os.path.join(cache, "%d.npz" % display)
    if os.path.exists(path):
        z = np.load(path)
        _MESH[display] = (z["v"], z["t"])
        return _MESH[display]
    cdi = {int(r["ID"]): r for r in csv.DictReader(open(os.path.join(R.CACHE, "CreatureDisplayInfo.csv"),
                                                        encoding="utf-8"))}
    cmd = {int(r["ID"]): r for r in csv.DictReader(open(os.path.join(R.CACHE, "CreatureModelData.csv"),
                                                        encoding="utf-8"))}
    model = cmd[int(cdi[display]["ModelID"])]
    data = open(R.casc(int(model["FileDataID"])), "rb").read()
    skins = m2_tools.skin_ids(data)
    vs, tris, _ = m2_tools.standing_mesh(data, open(R.casc(skins[0]), "rb").read())
    v, t = np.array(vs, float), np.array(tris, np.int64)
    np.savez(path, v=v, t=t)
    _MESH[display] = (v, t)
    return _MESH[display]


def placed(display, x, y, z, face, s):
    v, t = creature_mesh(display)
    c, sn = math.cos(face), math.sin(face)
    P = np.stack([x + s * (c * v[:, 0] - sn * v[:, 1]), y + s * (sn * v[:, 0] + c * v[:, 1]), z + s * v[:, 2]], 1)
    return P[t]


# ---------------------------------------------------------------------------------------------------------------
# one encounter
# ---------------------------------------------------------------------------------------------------------------
def pose_list(n):
    """n orbit poses round the boss: headings x pitches x distances (the board's whole range, low to high)."""
    pitches, dists = (0.2, 0.5, 0.9), (12.0, 25.0, 45.0)
    nh = max(1, n // (len(pitches) * len(dists)))
    return [(2 * math.pi * i / nh + 0.3, p, d) for i in range(nh) for p in pitches for d in dists]


def check(enc, poses=72, px=480, log=print):
    import gen_standins as G
    import test_standins as TS
    t0 = time.time()
    w, bob = TS.board(enc)
    bob.eval(CAP)
    key = bob.eval("return T3.v().room.key")
    room = G.load_room(key)
    models = bob.eval_py("return __OC.models()") or []
    # (a model with no triangles - an effect, a sheet with no standing vertices - hides nothing and is not scored)
    models = [m for m in models if len(creature_mesh(int(m[0]))[0]) and len(creature_mesh(int(m[0]))[1])]
    if not models:
        return dict(enc=enc, key=key, error="no creature on the page")
    for m in models:
        v, _ = creature_mesh(int(m[0]))
        lo, hi = v.min(0), v.max(0)
        bob.eval("__OC.bb(...)", int(m[0]), *[float(x) for x in (lo[0], lo[1], lo[2], hi[0], hi[1], hi[2])])
    boss = models[0]
    opaque = room.opaque
    see = (room.blend != "D") & (room.area > 1e-9) & (room.QO != 0)
    btris = np.concatenate([placed(int(m[0]), m[1], m[2], m[3], m[4], m[5]) for m in models])
    tot = {m: dict(px=0, wrong=0, hidden=0, shown=0) for m in MODES}
    per_pose = []
    excluded = 0
    for (h, p, d) in pose_list(poses):
        bob.eval("__OC.pose(...)", float(boss[1]), float(boss[2]), h, p, d)
        caps = {}
        for m in MODES:
            bob.eval("__OC.mode(...)", m)
            caps[m] = bob.eval_py("return __OC.capture()")
        cam = BoardCam(caps["box"]["cam"], px)
        dr = G.drawn(room, cam.C)
        Zr = zbuf(G, cam, room.V[room.T[dr & opaque]])
        Za = zbuf(G, cam, room.V[room.T[dr & see]]) if (dr & see).any() else np.full(Zr.shape, np.inf)
        Zb = zbuf(G, cam, btris)
        boss_px = np.isfinite(Zb)
        unsure = boss_px & (Za < np.minimum(Zb, Zr))
        score = boss_px & ~unsure
        excluded += int(unsure.sum())
        truth = Zb < Zr
        row = dict(h=round(h, 3), p=p, d=d, px=int(score.sum()))
        for m in MODES:
            cp = caps[m]
            if BoardCam(cp["cam"], px).C.tolist() != cam.C.tolist():
                raise RuntimeError("%s: the camera moved between modes" % enc)
            q = np.asarray(cp["copies"], float).reshape(-1, 4, 2)
            copy = np.zeros(Zr.shape, bool)
            if len(q):
                tri = np.concatenate([q[:, [0, 1, 2]], q[:, [1, 3, 2]]])
                zc, _ = G.raster(cam, cam.screen_tris(tri), np.zeros(len(tri), np.int64))
                copy = np.isfinite(zc)
            shown = ~copy
            if m != "box" and cp["si"]:
                arr = G.record_arrays(np.asarray(cp["si"], float).reshape(-1, 12))
                Zs, _ = G.render_standins(cam, arr, show=np.ones(len(arr[0]), bool))
                shown &= Zb < Zs
            wrong = score & (shown != truth)
            hid = score & truth & ~shown
            sh = score & ~truth & shown
            t = tot[m]
            t["px"] += int(score.sum())
            t["wrong"] += int(wrong.sum())
            t["hidden"] += int(hid.sum())
            t["shown"] += int(sh.sum())
            row[m] = int(wrong.sum())
        per_pose.append(row)
    res = dict(enc=enc, key=key, models=[int(m[0]) for m in models], poses=len(per_pose), px=px,
               excluded=excluded, seconds=round(time.time() - t0, 1))
    for m in MODES:
        t = tot[m]
        res[m] = dict(t, pct=round(100.0 * t["wrong"] / max(1, t["px"]), 3))
    res["best"] = min(MODES, key=lambda m: (res[m]["wrong"], MODES.index(m)))
    res["worst_poses"] = sorted(per_pose, key=lambda r: -max(r[m] for m in MODES))[:5]
    log("%-36s box %6.2f%%  standins %6.2f%%  gaps %6.2f%%  -> %s  (%d poses, %.0f s)" % (
        enc, res["box"]["pct"], res["standins"]["pct"], res["gaps"]["pct"], res["best"], len(per_pose),
        res["seconds"]))
    return res


def encounters():
    import gen_standins as G
    src = open(os.path.join(G.ADDON, "Render3D", "Rooms", "Index.lua"), encoding="utf-8").read()
    return sorted(set(re.findall(r'\["(\w+:\w+)"\] = \{ floor', src)))


def write_modes(results):
    import gen_standins as G
    path = os.path.join(G.OUT_DIR, "Modes.lua")
    lines = {}
    if os.path.exists(path):
        for m in re.finditer(r'^D\["([^"]+)"\] = .*$', open(path, encoding="utf-8").read(), re.M):
            lines[m.group(1)] = m.group(0)
    for r in results.values():
        if "error" in r or "best" not in r:
            continue
        lines[r["key"]] = 'D["%s"] = "%s"   -- wrong boss pixels: box %.2f%%, standins %.2f%%, gaps %.2f%%' % (
            r["key"], r["best"], r["box"]["pct"], r["standins"]["pct"], r["gaps"]["pct"])
    head = ['if DisasterZoneBoot and DisasterZoneBoot.Run("Render3D/Standins/Modes.lua", ...) then return end '
            '-- DisasterZone Render3D/Standins/Modes.lua',
            '-- Generated by dev/tools/occlusion_check.py --write: per room the 3D depth mode that hid or showed the '
            'fewest boss',
            '-- pixels wrongly, measured against an exact z-buffer from orbit poses round the boss '
            '(UI/StrategyMap3D.lua M3.DepthMode).',
            'local _, ns = ...', 'ns.RoomDepthModes = ns.RoomDepthModes or {}', 'local D = ns.RoomDepthModes']
    src = "\n".join(head + [lines[k] for k in sorted(lines)]) + "\n"
    with open(path, "wb") as fh:
        fh.write(src.encode("utf-8"))
    print("wrote", path)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("encs", nargs="*")
    ap.add_argument("--poses", type=int, default=72)
    ap.add_argument("--px", type=int, default=480)
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("--json")
    ap.add_argument("--write", action="store_true")
    a = ap.parse_args(argv)
    encs = a.encs or encounters()
    out = {}
    if a.jobs > 1 and len(encs) > 1:
        import tempfile
        tmp = tempfile.mkdtemp(prefix="occ_")
        procs, queue = [], list(encs)
        while queue or procs:
            while queue and len(procs) < a.jobs:
                e = queue.pop(0)
                j = os.path.join(tmp, e.replace(":", "_") + ".json")
                procs.append((e, j, subprocess.Popen([sys.executable, __file__, e, "--poses", str(a.poses),
                                                      "--px", str(a.px), "--json", j])))
            for item in list(procs):
                if item[2].poll() is not None:
                    procs.remove(item)
                    try:
                        out.update(json.load(open(item[1])))
                    except (OSError, ValueError):
                        out[item[0]] = dict(enc=item[0], error="exit %s" % item[2].returncode)
            time.sleep(1)
    else:
        for e in encs:
            try:
                out[e] = check(e, poses=a.poses, px=a.px)
            except Exception as ex:                      # (one room failing does not stop the rest)
                import traceback
                traceback.print_exc()
                out[e] = dict(enc=e, error=str(ex))
    if a.json:
        with open(a.json, "w") as fh:
            json.dump(out, fh, indent=1)
    if a.write:
        write_modes(out)
    if len(out) > 1:
        print()
        for e in sorted(out):
            r = out[e]
            if "error" in r:
                print("%-36s ERROR %s" % (e, r["error"]))
            else:
                print("%-36s box %6.2f%%  standins %6.2f%%  gaps %6.2f%%  -> %s" % (
                    e, r["box"]["pct"], r["standins"]["pct"], r["gaps"]["pct"], r["best"]))
    return out


if __name__ == "__main__":
    main()

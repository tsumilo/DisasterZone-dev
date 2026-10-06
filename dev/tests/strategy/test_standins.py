"""The stand-in depth mode of the strategy board's 3D view (Render3D/Standins.lua, /dz 3d standins), on the real addon.

Covers: version 3 data (packed text) unpacked to exactly the numbers version 2 holds, and only when a room's stand-ins
are first used - at login every room's data is loaded and none unpacked, the last two rooms used stay unpacked, rooms
that are one room share one unpacked set -, broken packing (a piece changed, another size or count, a piece that is not
text, a later version) unreadable; a room's data read flat whether it comes as one table of numbers or as strings and
tables of them (a broken
number makes it unreadable, a non-finite value, a normal that is not a unit vector or an unknown model file leaves that
stand-in out); each stand-in's radius and reach along its normal (a cube turned about z reaches further along a slanted
normal); which stand-ins a redraw shows: their surface facing the camera (the camera farther out along the normal than
the stand-in reaches and than the near plane's farthest corner: a surface 0.3 or 0.6 yd before the camera shows
nothing behind it), in front of
the near plane and on the screen (a ball off the view's middle bounded exactly), and over a model's rectangle, nearer
than its farthest corner and with some of the model's box behind its surface's plane - the floor under a model's feet
only when the model sinks into it (or every one in view with 'all'), the biggest on the screen first up to the budget;
a model through the near plane covers the whole view; the regions (runs of one surface) never change what is chosen,
checked against the rules one stand-in at a time on the shipped Magtheridon data from random cameras. On the board:
the mode is off by default and then makes nothing (no scene, the copies on); 'on' makes the stand-in scene under the
floor frame (a level of its own) with its opaque backdrop over it in the floor frame,
on the same camera, lens and clips as the creature scene, turns the room's copies off and shows exactly the stand-ins
between the camera and the boss (model file 167145, paused, placed as the creatures are: mirrored y, position divided
by the scale, yaw and roll turned with the mirror, pitch kept); a redraw with nothing changed or a camera move that
keeps the selection places nothing again, a smaller budget hides the smallest and a bigger one places only those
that come back; 'off' hides it all and the box mode is what it was; a room without stand-ins (or unreadable ones)
keeps the box mode and says so once per turn-on; Kil'jaeden stands in the backdrop scene in the box mode, leaves it
for the creature scene in the mode and goes back without it, each actor back in its own scene's pool; Magtheridon's
Lair turns on with its shipped stand-ins, all usable, and the board's selection matches the rules from a round of
cameras; actors without SetPaused freeze with SetAnimation(0, 0, 0, 0); debug raises the scene
over the room with see-through cubes (all: every one in view), the client's depth-clearing flag is on for the stand-in
scene alone (never a creature scene), off in debug and with 'flag off'; walking,
your character stays in the second scene and the stand-ins between the camera and you are shown; no Lua errors.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_standins.py [-k name]
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import st_common  # noqa: E402,F401  (sets the suites' paths)
from _common import case, run_all, no_errors, World, Client  # noqa: E402
from rp_common import gm_pick, set_raid_leaders  # noqa: E402
import harness  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "generators"))
import gen_standins as G  # noqa: E402  (the data files' writer: packed text for version 3 cases)

harness.LOAD_ROOMS = True                      # (the board's rooms)

STANDINS = "Render3D/Standins.lua"
MAG_DATA = "Render3D/Standins/MagtheridonsLair_Magtheridon.lua"
# Until the coordinator adds the TOC lines, the suite loads the stand-ins where they will sit: after the probe, the
# shipped room data right after them.
_parse_toc = harness.parse_toc


def _toc_with_standins(addon_dir, addon_name=harness.ADDON_NAME):
    headers, files = _parse_toc(addon_dir, addon_name)
    if STANDINS not in files:
        for anchor in ("Render3D/Probe.lua", "Render3D/Rooms.lua", "Render3D/View.lua"):
            if anchor in files:
                i = files.index(anchor) + 1
                files = files[:i] + [STANDINS] + files[i:]
                break
    if MAG_DATA not in files and STANDINS in files:
        i = files.index(STANDINS) + 1
        files = files[:i] + [MAG_DATA] + files[i:]
    return headers, files


harness.parse_toc = _toc_with_standins

TERON = "BlackTemple:Teron"
KJ = "SunwellPlateau:Kiljaeden"
MAG = "MagtheridonsLair:Magtheridon"
CUBE = 167145

# The selection's rules one stand-in at a time, with no regions (S.Select must choose exactly these: its regions
# only skip work). Loaded with the helpers and the pure-selection setup.
BRUTE = r"""
function __BRUTE(set, cam, proj, models, nm, all)
  local d, st, R, E = set.d, set.stride, set.R, set.E
  local huge, out = math.huge, {}
  -- the near clip's guard: out to the near plane's farthest corner
  local tx, ty = cam.w / (2 * cam.k), cam.h / (2 * cam.k)
  local guard = cam.near * math.sqrt(1 + tx * tx + ty * ty)
  for i = 1, set.n do
    local r = R[i]
    if r then
      local o = (i - 1) * st
      local px, py, pz = d[o + 2], d[o + 3], d[o + 4]
      local nx, ny, nz = d[o + 9], d[o + 10], d[o + 11]
      local vx, vy, vz = cam.x - px, cam.y - py, cam.z - pz
      local dep = -(vx * cam.fx + vy * cam.fy + vz * cam.fz)
      if vx * nx + vy * ny + vz * nz > E[i] + guard and dep + r > cam.near then
        local nearest, x0, y0, x1, y1 = dep - r
        if dep - r <= cam.near then
          nearest, x0, y0, x1, y1 = cam.near, -huge, -huge, huge, huge
        else
          local sx, sy = proj(px, py, pz)
          if sx then
            local rp = cam.k * r * math.sqrt(vx * vx + vy * vy + vz * vz) / (dep * (dep - r))
            x0, y0, x1, y1 = sx - rp, sy - rp, sx + rp, sy + rp
          end
        end
        if x0 and x1 >= 0 and x0 <= cam.w and y1 >= 0 and y0 <= cam.h then
          local hit = all
          local pe = nx * px + ny * py + nz * pz + E[i]
          for m = 1, nm do
            local M = models[m]
            local lo = nx * M.bx + ny * M.by - M.br * (math.abs(nx) + math.abs(ny)) + math.min(nz * M.bz0, nz * M.bz1)
            if nearest < M.far and x1 >= M.x0 and x0 <= M.x1 and y1 >= M.y0 and y0 <= M.y1 and lo <= pe then
              hit = true
            end
          end
          if hit then out[#out + 1] = i end
        end
      end
    end
  end
  return out
end
function __SAME(a, n, b)
  local s = {}
  for j = 1, n do s[a[j]] = true end
  if n ~= #b then return false end
  for _, i in ipairs(b) do if not s[i] then return false end end
  return true
end
"""

# The mock's actors have no SetPaused / SetPitch / SetRoll and its scenes no SetAllowOverlappedModels (2.5.6 has them):
# a spy adds them and counts what the stand-ins do (actors of the stand-ins carry sfid once given their model).
SPY = r"""
__SI = { pos = 0, flagCalls = 0, frozen = 0 }
local sc = CreateFrame("ModelScene")
local idx = getmetatable(sc:CreateActor()).__index
if __SI_PAUSE then idx.SetPaused = function(self, v) self.paused = v end else idx.SetPaused = nil end
idx.SetPitch = function(self, v) self.pitch = v end
idx.SetRoll = function(self, v) self.roll = v end
__SI.setpos = __SI.setpos or idx.SetPosition
idx.SetPosition = function(self, x, y, z)
  if self.sfid then __SI.pos = __SI.pos + 1 end
  return __SI.setpos(self, x, y, z)
end
__SI.setanim = __SI.setanim or idx.SetAnimation
idx.SetAnimation = function(self, id, variation, speed, offset)
  if self.sfid and speed == 0 then self.frozen = true __SI.frozen = __SI.frozen + 1 end
  return __SI.setanim(self, id, variation, speed, offset)
end
__SI.flagScenes = {}
__MOCK.Methods.ModelScene.SetAllowOverlappedModels = function(self, v)
  __SI.flagCalls = __SI.flagCalls + 1
  __SI.flag = v
  __SI.flagScenes[self] = v
end
"""

HELPERS = r"""
T3 = {}
function T3.cv() return _G.DisasterZoneStrategyBoard.canvas end
function T3.v() return T3.cv().v3 end
function T3.page() return ns.StrategyBoard:GetState().strat.p[ns.StrategyBoard:GetState().page] end
function T3.elems() return T3.page().e end
function T3.boss()
  local e
  for _, x in ipairs(T3.elems()) do if x.t == 'i' and (x.i or ''):find('^boss:') then e = x end end
  return e
end
-- the eye (room coordinates) and a target: the boss' chest, or your own while walking
function T3.line()
  local v = T3.v()
  local cam, m = v.cam, v.cam.mirror
  local E = { cam.x, m * cam.y, cam.z }
  if v.walk then
    local k = v.walk.k
    return E, { k.x, k.y, k.z + 1.2 }
  end
  local g = v:Geo(T3.boss())
  return E, { g.x, g.y, g.z + (g.h or 2) / 2 }
end
-- one stand-in on the line from the eye (t = 0) to the target (t = 1); o: away (its normal turned from the eye),
-- side (yd sideways, level), scale, prim, yaw, pitch, roll
function T3.put(list, E, T, t, o)
  o = o or {}
  local x, y, z = E[1] + t * (T[1] - E[1]), E[2] + t * (T[2] - E[2]), E[3] + t * (T[3] - E[3])
  local dx, dy, dz = E[1] - T[1], E[2] - T[2], E[3] - T[3]
  local len = math.sqrt(dx * dx + dy * dy + dz * dz)
  dx, dy, dz = dx / len, dy / len, dz / len
  if o.side then
    local fl = math.sqrt(dx * dx + dy * dy)
    x, y = x + o.side * dy / fl, y - o.side * dx / fl
  end
  if o.away then dx, dy, dz = -dx, -dy, -dz end
  local n = #list
  local row = { o.prim or 1, x, y, z, o.yaw or 0, o.pitch or 0, o.roll or 0, o.scale or 0.3, dx, dy, dz, n / 12 + 1 }
  for i = 1, 12 do list[n + i] = row[i] end
  return n / 12 + 1
end
function T3.data(list, key)
  key = key or T3.v().room.key
  ns.RoomStandins = ns.RoomStandins or {}
  -- (stamped with the room build it stands in, as the generator does: other data is refused as stale)
  local fl = ns.RoomFloors and ns.RoomFloors[key]
  ns.RoomStandins[key] = { version = 1, n = #list / 12, stride = 12, data = list, room = { size = fl and fl.size },
    prims = { { fid = 167145, kind = 'cube', half = 0.5 }, { fid = 12345, kind = 'cube', half = 0.5 } } }
end
-- the groups: A between the eye and the target (shown), B far past it, C turned away, D behind the camera, E far to
-- the side, F an unknown model file
function T3.groups(nA)
  local E, T = T3.line()
  local list, g = {}, { A = {}, B = {}, C = {}, D = {}, E = {}, F = {} }
  for j = 1, nA or 10 do
    local t = 0.4 + 0.2 * (j - 1) / math.max(1, (nA or 10) - 1)
    g.A[#g.A + 1] = T3.put(list, E, T, t, { scale = 0.2 + 0.02 * j, yaw = 0.1 * j,
      pitch = j == 1 and 0.2 or nil, roll = j == 1 and 0.3 or nil })
  end
  for j = 1, 4 do g.B[#g.B + 1] = T3.put(list, E, T, 3 + 0.2 * j) end
  for j = 1, 4 do g.C[#g.C + 1] = T3.put(list, E, T, 0.45 + 0.02 * j, { away = true }) end
  for j = 1, 4 do g.D[#g.D + 1] = T3.put(list, E, T, -0.5 - 0.1 * j, { away = true }) end
  for j = 1, 4 do g.E[#g.E + 1] = T3.put(list, E, T, 0.5, { side = 400 + 20 * j }) end
  for j = 1, 3 do g.F[#g.F + 1] = T3.put(list, E, T, 0.5 + 0.01 * j, { prim = 2 }) end
  T3.data(list)
  T3.list, T3.g = list, g
  return g
end
-- the stand-ins shown now: index -> its actor's state
function T3.shown()
  local si = T3.v().standins
  local out = {}
  if not si then return out end
  for i, a in pairs(si.at) do
    out[#out + 1] = i
  end
  table.sort(out)
  return out
end
function T3.inScene(sc, a)
  for _, x in ipairs(__MOCK.OBJ[sc].actors or {}) do if x == a then return true end end
  return false
end
"""


def board(boss=TERON, pause=True):
    """Gina (GM) and Bob (raid leader, who plans); Bob opens a new strategy for `boss` in 3D (no tilt)."""
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE")):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ["Bob"])
    w.tick(2)
    bob = c["Bob"]
    bob.eval("__SI_PAUSE = %s" % ("true" if pause else "false"))
    bob.eval(SPY)
    bob.eval(HELPERS)
    bob.eval(BRUTE)
    bob.eval("ns.StrategyBoard:NewStrategy(...)", boss)
    w.tick(0.2)
    assert bob.eval("return T3.cv():Set3D(true, false)") is True
    tick(w, 1.0)
    return w, bob


def tick(w, secs):
    for _ in range(int(secs / 0.05 + 0.5)):
        w.tick(0.05)


def chat_since(cl, n0, needle):
    return [str(x) for x in cl.chat_frame[n0:] if needle in str(x)]


def box_state(bob):
    """What the box mode shows: the copies and the occluders as the copies saw them."""
    return bob.eval_py("""
        local v = T3.v() local R = v.R local st = R.Stats() local occ = {}
        for _, o in ipairs(R.Occluders()) do
          occ[#occ + 1] = { o.x, o.y, o.z, o.h, o.rb, o.onScreen, o.copies, o.box[1], o.box[2], o.box[3], o.box[4] }
        end
        return { copies = st.copies, copyActors = st.copyActors, nOcc = v.nOcc, occ = occ,
                 copiesOpt = R.opts.copies ~= false }""")


# Pure selection (no board): a camera at the origin looking along +x, a 600 x 400 view, 300 px per yd at depth 1.
SELECT = r"""
local S = ns.Render3D.Standins
local cam = { x = 0, y = 0, z = 0, fx = 1, fy = 0, fz = 0, near = 0.5, w = 600, h = 400, k = 300 }
local function proj(x, y, z)
  if x <= 1e-6 then return nil end
  return 300 - 300 * y / x, 200 + 300 * z / x, x
end
local function row(list, prim, x, y, z, scale, nx, ny, nz, yaw, pitch, roll)
  local r = { prim, x, y, z, yaw or 0, pitch or 0, roll or 0, scale, nx, ny, nz, #list / 12 + 1 }
  for i = 1, 12 do list[#list + 1] = r[i] end
end
local prims = { { fid = 167145, kind = 'cube', half = 0.5 }, { fid = 999, kind = 'cube', half = 0.5 } }
T_SEL = { S = S, cam = cam, proj = proj, row = row, prims = prims }
-- one model: a box round (20, 0, 0) 2 yd wide and high
T_SEL.occ = { { x = 20, y = 0, z = -1, h = 2, top = 2, rb = 1, w = 0 } }
-- a pinhole camera at (x, y, z) looking along yaw / pitch (radians, pitch up), the view w x h, k px per yd at depth 1
function T_SEL.look(x, y, z, yaw, pitch, w, h, k)
  local fx, fy, fz = math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)
  local rx, ry = math.sin(yaw), -math.cos(yaw)
  local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
  local c = { x = x, y = y, z = z, fx = fx, fy = fy, fz = fz, near = 0.5, w = w, h = h, k = k }
  local function proj(px, py, pz)
    local vx, vy, vz = px - x, py - y, pz - z
    local dd = vx * fx + vy * fy + vz * fz
    if dd <= 1e-6 then return nil end
    return w / 2 + k * (vx * rx + vy * ry) / dd, h / 2 + k * (vx * ux + vy * uy + vz * uz) / dd, dd
  end
  return c, proj
end
""" + BRUTE


@case
def a_redraw_shows_only_the_stand_ins_that_face_the_camera_lie_in_view_and_in_front_of_a_model():
    w = World()
    c = Client(w, "Bob", guild_rank=1, class_file="MAGE")
    c.load_addon()
    w.tick(1)
    c.eval(SELECT)
    r = c.eval_py(r"""
        local T = T_SEL local S, row = T.S, T.row
        local L = {}
        row(L, 1, 10, 0, 0, 0.4, -1, 0, 0)          -- 1 between the eye and the model, facing: shown
        row(L, 1, 10, 0, 0, 0.4, 1, 0, 0)           -- 2 its surface turned away
        row(L, 1, 30, 0, 0, 0.4, -1, 0, 0)          -- 3 past the model's farthest corner
        row(L, 1, 10, 5, 0, 0.4, -1, 0, 0)          -- 4 in view, beside the model's rectangle
        row(L, 1, -5, 0, 0, 0.4, 1, 0, 0)           -- 5 facing, but behind the camera
        row(L, 1, 10, 100, 0, 0.4, -1, 0, 0)        -- 6 facing, off the screen
        row(L, 1, 1.32, 0, 0, 1, -1, 0, 0)          -- 7 through the near plane: anywhere on the screen (its surface
                                                    --   0.82 yd out, past the guard: 0.78 yd in this 3:2 view)
        row(L, 1, 0.3, 0, 0, 1, -1, 0, 0)           -- 8 the camera inside its slab: behind its surface
        row(L, 2, 10, 0, 0, 0.4, -1, 0, 0)          -- 9 an unknown model file
        row(L, 1, 10, 0, 0, 0, -1, 0, 0)            -- 10 no size
        row(L, 1, 10, -100, 0, 1, -1, 0, 0, math.pi / 4)  -- 11 turned 45 degrees about z (off the screen)
        row(L, 1, 10, 0, -4, 4, 0, 0, 1)            -- 12 a floor under the model (top 1 yd under its feet)
        row(L, 1, 0.8, 0, 0, 1, -1, 0, 0)           -- 13 its surface 0.3 yd before the camera: in the near clip
        row(L, 1, 10, 0, 0, 0.4, -1, 0, 0.5)        -- 14 a normal that is not a unit vector
        local set = S.Prepare({ version = 1, prims = T.prims, n = 14, stride = 12, data = L })
        local rects = {}
        local nm = S.ModelRects(T.occ, 1, T.cam, T.proj, rects)
        local out, st = {}, {}
        local n = S.Select(set, T.cam, T.proj, rects, nm, 800, out, false, st)
        local all, sta = {}, {}
        local na = S.Select(set, T.cam, T.proj, rects, nm, 800, all, true, sta)
        -- the model reaching 0.5 yd under its record's feet (a part the board starts on the floor): the floor
        -- under it now hides that much of it
        local sunk = { { x = 20, y = 0, z = -1, h = 2, top = 2, rb = 1, w = 0, sink = 1.5 } }
        local r2 = {}
        local nm2 = S.ModelRects(sunk, 1, T.cam, T.proj, r2)
        local o2 = {}
        local n2 = S.Select(set, T.cam, T.proj, r2, nm2, 800, o2, false)
        return { n = n, out = out, st = st, na = na, all = all, sta = sta, usable = set.usable, unsafe = set.unsafe,
                 R1 = set.R[1], E1 = set.E[1], E8 = set.E[8], E11 = set.E[11], R9 = set.R[9], R10 = set.R[10],
                 R14 = set.R[14], nm = nm, rect = rects[1], n2 = n2, o2 = o2, sunkBox = r2[1],
                 brute = __BRUTE(set, T.cam, T.proj, rects, nm, false), bruteAll = __BRUTE(set, T.cam, T.proj, rects, nm, true) }
    """)
    assert r["nm"] == 1 and 270 < r["rect"]["x0"] < 290 and 310 < r["rect"]["x1"] < 330, r["rect"]
    assert abs(r["rect"]["far"] - 21) < 1e-6, r["rect"]
    assert (r["rect"]["bx"], r["rect"]["by"], r["rect"]["br"], r["rect"]["bz0"], r["rect"]["bz1"]) == (20, 0, 1, -1, 1)
    assert r["usable"] == 11 and r["unsafe"] == 1, r                # (9: unknown file, 10: no size, 14: normal)
    assert r["R9"] is False and r["R10"] is False and r["R14"] is False, r
    assert abs(r["R1"] - 0.2 * math.sqrt(3)) < 1e-9 and abs(r["E1"] - 0.2) < 1e-9, r
    assert abs(r["E8"] - 0.5) < 1e-9, r
    assert abs(r["E11"] - 0.5 * math.sqrt(2)) < 1e-9, r             # (a cube turned 45 degrees reaches its corner)
    # only 1 (in front of the model) and 7 (through the near plane) are shown: not the floor under the model's
    # feet (12: the model wholly in front of its plane) nor 13 (the near clip takes its surface away); 'all' adds
    # 3, 4 and 12 (in view)
    assert r["n"] == 2 and sorted(r["out"]) == [1, 7], r
    # (each row is a region of its own: only 1 and 7 are looked at one by one, the rest go as regions)
    assert r["st"] == {"regions": 2, "examined": 2, "facing": 2, "inView": 2, "relevant": 2}, r["st"]
    assert r["na"] == 5 and sorted(r["all"]) == [1, 3, 4, 7, 12], r
    assert sorted(r["brute"]) == [1, 7] and sorted(r["bruteAll"]) == [1, 3, 4, 7, 12], r
    # sunk 1.5 yd: its box reaches past the floor's top (1 yd under its feet): 12 too
    assert r["sunkBox"]["bz0"] == -2.5 and r["n2"] == 3 and sorted(r["o2"]) == [1, 7, 12], r
    no_errors(w)


@case
def the_near_clip_guard_shows_nothing_behind_a_surface_nearer_than_the_near_clip():
    """A wall of stand-ins (surface at x = d, normal towards the camera) between the camera and a model: with the
    camera 0.3 yd before the surface the client clips the surface away, so none may show; 0.6 yd before it - past
    the near clip, but nearer than the near plane's corners (0.78 yd in this 3:2 view) - the view's corners may
    clip it, so none either; from 1.2 yd they do."""
    w = World()
    c = Client(w, "Bob", guild_rank=1, class_file="MAGE")
    c.load_addon()
    w.tick(1)
    c.eval(SELECT)
    r = c.eval_py(r"""
        local T = T_SEL local S, row = T.S, T.row
        local L = {}
        for y = -3, 3 do
          for z = -2, 2 do row(L, 1, 0.3 + 0.25, y * 0.5, z * 0.5, 0.5, -1, 0, 0) end   -- surface at x = 0.3
        end
        local set = S.Prepare({ version = 1, prims = T.prims, n = #L / 12, stride = 12, data = L })
        local res = {}
        for _, back in ipairs({ 0, 0.1, 0.15, 0.3, 0.9 }) do
          local cam = { x = -back, y = 0, z = 0, fx = 1, fy = 0, fz = 0, near = 0.5, w = 600, h = 400, k = 300 }
          local function proj(x, y, z)
            local dx = x + back
            if dx <= 1e-6 then return nil end
            return 300 - 300 * y / dx, 200 + 300 * z / dx, dx
          end
          local rects, out = {}, {}
          local nm = S.ModelRects(T.occ, 1, cam, proj, rects)
          res[#res + 1] = { S.Select(set, cam, proj, rects, nm, 800, out, false),
                            S.Select(set, cam, proj, rects, nm, 800, {}, true), #__BRUTE(set, cam, proj, rects, nm, false) }
        end
        return { n = set.n, res = res, guard = S.Guard({ near = 0.5, w = 600, h = 400, k = 300 }) }
    """)
    assert abs(r["guard"] - 0.5 * math.sqrt(1 + 1 + (2 / 3) ** 2)) < 1e-12, r
    # 0.3, 0.4, 0.45 and 0.6 yd before the surface: nothing, even with 'all'; 1.2 yd: those over the model
    for k in range(4):
        assert r["res"][k] == [0, 0, 0], (k, r)
    assert r["res"][4][0] > 0 and r["res"][4][0] == r["res"][4][2] and r["res"][4][1] == r["n"], r
    no_errors(w)


QUAD_PRIM = "{ fid = 653518, kind = 'quad', w = 48.9309, h = 32.9853, cx = -4.03583, cy = 0.86901, cz = 18.25718 }"


def _ypr(yaw, pitch, roll):
    """Rz(yaw) Ry(pitch) Rx(roll), Render3D/Probe.lua's AXIS turns (the client's order, roll first): columns = the
    model's axes."""
    cy, sy, cp, sp, cr, sr = (math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch), math.cos(roll),
                              math.sin(roll))
    rz = [[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]]
    ry = [[cp, 0, sp], [0, 1, 0], [-sp, 0, cp]]
    rx = [[1, 0, 0], [0, cr, -sr], [0, sr, cr]]

    def mul(a, b):
        return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
    return mul(mul(rz, ry), rx)


def _app(M, v):
    return [sum(M[i][k] * v[k] for k in range(3)) for i in range(3)]


@case
def quads_are_read_with_their_turn_and_reach_and_only_known_aligned_ones_are_used():
    """Version 2 data: a quad (653518) lies in its plane - its radius the half diagonal, its reach along its normal 0;
    one whose front does not face along its normal (turned 0.6 degrees off, or facing away) is left out, as is a
    quad of a file not on the allow-list (even the verified 1396283, which no data uses) and a kind the runtime does
    not know; a cube turned by pitch and roll reaches exactly as far as its turned axes do; S.Turn is the client's
    yaw-pitch-roll order; data of a later version is unreadable. A quad facing the camera before the model is shown,
    a floor quad under the model's feet is not."""
    w = World()
    c = Client(w, "Bob", guild_rank=1, class_file="MAGE")
    c.load_addon()
    w.tick(1)
    c.eval(SELECT)
    r = c.eval_py(r"""
        local T = T_SEL local S, row = T.S, T.row
        local prims = { { fid = 167145, kind = 'cube', half = 0.5 }, """ + QUAD_PRIM + r""",
                        { fid = 1396283, kind = 'quad', w = 63.83, h = 32.99, cx = -7.05, cy = 1.98, cz = 14.7 },
                        { fid = 653518, kind = 'disc', w = 1, h = 1 } }
        local L = {}
        row(L, 2, 10, 0, 0, 0.04, -1, 0, 0, math.pi, 0, 0)            -- 1 a quad facing the camera, before the model
        row(L, 2, 20, 0, -3, 0.2, 0, 0, 1, 0.3, -math.pi / 2, 0.2)     -- 2 a floor quad under the model (front up)
        row(L, 2, 10, 0, 0, 0.04, -1, 0, 0, math.pi - 0.01, 0, 0)     -- 3 turned 0.6 degrees off its normal
        row(L, 2, 10, 0, 0, 0.04, -1, 0, 0, 0, 0, 0)                  -- 4 facing away from its normal
        row(L, 3, 10, 0, 0, 0.04, -1, 0, 0, math.pi, 0, 0)            -- 5 a quad file not on the allow-list
        row(L, 4, 10, 0, 0, 0.04, -1, 0, 0, math.pi, 0, 0)            -- 6 a kind it does not know
        row(L, 1, 10, 3, 0, 1, -0.6, 0.8, 0, 0.2, 0.3, 0.4)           -- 7 a cube turned by yaw, pitch and roll
        local set = S.Prepare({ version = 2, prims = prims, n = #L / 12, stride = 12, data = L })
        local rects = {}
        local nm = S.ModelRects(T.occ, 1, T.cam, T.proj, rects)
        local out = {}
        local n = S.Select(set, T.cam, T.proj, rects, nm, 800, out, false)
        local turns = {}
        for _, a in ipairs({ { 0.3, 0.2, 0.1 }, { -2.5, 1.1, 2.9 }, { 1.0, -math.pi / 2, 0.4 } }) do
          turns[#turns + 1] = { a, { S.Turn(a[1], a[2], a[3]) } }
        end
        local later = { S.Prepare({ version = 4, prims = prims, n = 1, stride = 12, data = { unpack(L, 1, 12) } }) }
        return { R = set.R, E = set.E, usable = set.usable, unsafe = set.unsafe, n = n, out = out, turns = turns,
                 later = later[2], brute = __BRUTE(set, T.cam, T.proj, rects, nm, false) }
    """)
    hw, hh = 48.9309 / 2 * 0.04, 32.9853 / 2 * 0.04
    assert abs(r["R"][0] - math.hypot(hw, hh)) < 1e-9 and abs(r["E"][0]) < 1e-9, r
    assert abs(r["R"][1] - math.hypot(hw * 5, hh * 5)) < 1e-9 and abs(r["E"][1]) < 1e-9, r
    assert r["R"][2] is False and r["R"][3] is False and r["R"][4] is False and r["R"][5] is False, r
    assert r["usable"] == 3 and r["unsafe"] == 1, r
    # the turned cube: half x the sum over its turned axes of |n . axis|
    M = _ypr(0.2, 0.3, 0.4)
    n = [-0.6, 0.8, 0]
    want = 0.5 * sum(abs(sum(n[i] * M[i][k] for i in range(3))) for k in range(3))
    assert abs(r["E"][6] - want) < 1e-9 and abs(r["R"][6] - 0.5 * math.sqrt(3)) < 1e-9, (r["E"], want)
    for a, cols in r["turns"]:
        M = _ypr(*a)
        got = [[cols[3 * k + i] for k in range(3)] for i in range(3)]      # (S.Turn gives the columns)
        assert max(abs(got[i][j] - M[i][j]) for i in range(3) for j in range(3)) < 1e-12, (a, got, M)
    assert r["later"] == "unreadable", r
    assert r["n"] == 1 and r["out"] == [1] and r["brute"] == [1], r
    no_errors(w)


@case
def a_tilted_quad_is_placed_exactly_on_its_rectangle_under_either_mirror():
    """Ctl:Place of a quad turned by yaw, pitch and roll: the corners the client draws (the actor's position times the
    scale, the model turned by the actor's yaw, pitch and roll in the client's order ABOUT THE MIDDLE OF ITS BOX - probe
    page 8 in game, 2026-10-06: turned about the origin, floor quads floated yards off) are the
    data's rectangle - with the scene's y mirrored, the mirrored rectangle exactly - and its front faces the
    (mirrored) normal, so the one-sided quad shows to the cameras on its surface's side in the scene too."""
    w, bob = board()
    assert bob.slash("/dz 3d standins on")
    tick(w, 0.2)
    yaw, pitch, roll, s = 0.7, -0.4, 0.9, 0.05
    r = bob.eval_py(r"""
        local S = ns.Render3D.Standins
        local yaw, pitch, roll, s = ...
        local xx, xy, xz = S.Turn(yaw, pitch, roll)
        local key = T3.v().room.key
        local fl = ns.RoomFloors[key]
        ns.RoomStandins[key] = { version = 2, n = 1, stride = 12, room = { size = fl.size },
          prims = { { fid = 167145, kind = 'cube', half = 0.5 }, """ + QUAD_PRIM + r""" },
          data = { 2, 12.5, -3.25, 4.75, yaw, pitch, roll, s, xx, xy, xz, 1 } }
        T3.v():Draw()
        local si = T3.v().standins
        local m0, places = si.mirror, {}
        for _, m in ipairs({ 1, -1 }) do
          local a = si:NewActor()
          si.mirror = m
          si:Place(a, 1)
          places[#places + 1] = { m = m, pos = a.pos, scale = a.scale, yaw = a.yaw, pitch = a.pitch or 0,
                                  roll = a.roll or 0, fid = a.fileID }
          a:SetShown(false)
        end
        si.mirror = m0
        return { usable = si.set.usable, places = places }""", yaw, pitch, roll, s)
    assert r["usable"] == 1, r
    c = (-4.03583, 0.86901, 18.25718)
    # (the model's corners as the prim's numbers put them: its middle plus or minus half its size)
    model = [(c[0], c[1] + a * 48.9309 / 2, c[2] + b * 32.9853 / 2) for a in (-1, 1) for b in (-1, 1)]
    R = _ypr(yaw, pitch, roll)
    anchor = (12.5, -3.25, 4.75)
    places = r["places"]
    for got in places:
        m = got["m"]
        assert got["fid"] == 653518 and abs(got["scale"] - s) < 1e-12, got
        Ra = _ypr(got["yaw"], got["pitch"], got["roll"])
        drawn = sorted(tuple(got["pos"][i] * got["scale"] + s * c[i] + v
                             for i, v in enumerate(_app(Ra, [s * (x - cc) for x, cc in zip(q, c)])))
                       for q in model)
        want = sorted(tuple(v * (m if i == 1 else 1) for i, v in
                            enumerate(a + b for a, b in zip(anchor, _app(R, [s * (x - cc) for x, cc in zip(q, c)]))))
                      for q in model)
        assert max(abs(p - q) for d_, w_ in zip(drawn, want) for p, q in zip(d_, w_)) < 1e-9, (m, drawn, want)
        front = _app(Ra, [1, 0, 0])
        n = _app(R, [1, 0, 0])
        assert max(abs(front[i] - n[i] * (m if i == 1 else 1)) for i in range(3)) < 1e-12, (m, front, n)
    # (unmirrored, the turn is the data's own; mirrored, yaw and roll turn the other way and pitch stays)
    assert abs(places[0]["yaw"] - yaw) < 1e-12 and abs(places[1]["yaw"] + yaw) < 1e-12
    assert places[1]["pitch"] == pitch and abs(places[1]["roll"] + roll) < 1e-12, places
    bob.slash("/dz 3d standins off")
    no_errors(w)


@case
def a_ball_off_the_middle_of_the_view_is_bounded_on_the_screen_exactly():
    """Perspective stretches a ball away from the view's middle by |v| / depth: a stand-in 63 degrees off the
    middle reaches 167 px out on the screen, not the 94 px a fixed 1.25 pad gave, and hides the model there."""
    w = World()
    c = Client(w, "Bob", guild_rank=1, class_file="MAGE")
    c.load_addon()
    w.tick(1)
    c.eval(SELECT)
    r = c.eval_py(r"""
        local T = T_SEL local S, row = T.S, T.row
        local L = {}
        local D = math.sqrt(500)
        row(L, 1, 10, -20, 0, 2 / (0.5 * math.sqrt(3)), -10 / D, 20 / D, 0)   -- radius 2 yd, toward the camera
        local set = S.Prepare({ version = 1, prims = T.prims, n = 1, stride = 12, data = L })
        local cam = { x = 0, y = 0, z = 0, fx = 1, fy = 0, fz = 0, near = 0.5, w = 2000, h = 400, k = 300 }
        local function proj(x, y, z)
          if x <= 1e-6 then return nil end
          return 1000 - 300 * y / x, 200 + 300 * z / x, x
        end
        -- a model 25 yd out on the line at tan 2.5 (x 1750 on the screen): the ball's edge is at tan 2.546 (1764)
        local models = { { x0 = 1740, x1 = 1760, y0 = 190, y1 = 210, far = 26, bx = 25, by = -62.5, br = 1, bz0 = -1,
                           bz1 = 1, bh = 1.8 } }
        local out = {}
        return { n = S.Select(set, cam, proj, models, 1, 800, out, false), brute = #__BRUTE(set, cam, proj, models, 1, false) }
    """)
    assert r == {"n": 1, "brute": 1}, r
    no_errors(w)


@case
def regions_never_change_what_is_chosen_on_the_shipped_magtheridon_data():
    """S.Select (whole regions turned away first) against the same rules one stand-in at a time, from random
    cameras round and inside Magtheridon's Lair with random models (some sunk, some through the near plane)."""
    w = World()
    c = Client(w, "Bob", guild_rank=1, class_file="MAGE")
    c.load_addon()
    w.tick(1)
    c.eval(SELECT)
    r = c.eval_py(r"""
        local T = T_SEL local S = T.S
        local set = S.Load('MagtheridonsLair_Magtheridon')
        if not set then return { none = true } end
        local seed = 12345
        local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
        local x0, y0, z0, x1, y1, z1 = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
        for i = 1, set.n do
          local o = (i - 1) * set.stride
          x0, y0, z0 = math.min(x0, set.d[o + 2]), math.min(y0, set.d[o + 3]), math.min(z0, set.d[o + 4])
          x1, y1, z1 = math.max(x1, set.d[o + 2]), math.max(y1, set.d[o + 3]), math.max(z1, set.d[o + 4])
        end
        local bad, total, shown, poses, cut = {}, 0, 0, 120, 0
        for p = 1, poses do
          local cx, cy = x0 + rnd() * (x1 - x0), y0 + rnd() * (y1 - y0)
          local cz = (p % 3 == 0) and (z0 + rnd() * (z1 - z0 + 5)) or (2 + rnd() * 40)
          local cam, proj = T.look(cx, cy, cz, rnd() * 2 * math.pi, -1.4 + rnd() * 1.8, 800 + rnd() * 600, 500, 400 + rnd() * 400)
          local occ = {}
          for m = 1, 1 + math.floor(rnd() * 6) do
            local ox, oy = x0 + rnd() * (x1 - x0), y0 + rnd() * (y1 - y0)
            if m == 1 and p % 4 == 0 then ox, oy = cx + cam.fx * 0.4, cy + cam.fy * 0.4 end   -- through the near plane
            occ[m] = { x = ox, y = oy, z = rnd() * 0.3, h = 1 + rnd() * 12, rb = 0.3 + rnd() * 6, w = 0,
                       sink = (rnd() < 0.3) and rnd() * 1.5 or nil }
          end
          local rects, out, st = {}, {}, {}
          local nm = S.ModelRects(occ, #occ, cam, proj, rects)
          for i = 1, nm do if rects[i].x0 == -math.huge then cut = cut + 1 end end
          for _, all in ipairs({ false, true }) do
            local n = S.Select(set, cam, proj, rects, nm, 100000, out, all, st)
            local b = __BRUTE(set, cam, proj, rects, nm, all)
            if not __SAME(out, n, b) then bad[#bad + 1] = { p = p, all = all, n = n, brute = #b } end
            if not all then total, shown = total + st.examined, shown + n end
          end
        end
        return { bad = bad, n = set.n, usable = set.usable, unsafe = set.unsafe, ng = set.ng, examined = total / poses,
                 shown = shown / poses, cut = cut }
    """)
    assert not r.get("none"), "the shipped Magtheridon stand-ins did not load"
    assert r["usable"] == r["n"] and r["unsafe"] == 0 and r["n"] > 1000, r
    assert r["bad"] == [], r["bad"][:5]
    # (the regions skip work: far fewer looked at one by one than there are; models through the near plane met)
    assert r["examined"] < 0.5 * r["n"] and r["shown"] > 0 and r["cut"] > 0, r
    no_errors(w)


@case
def over_the_budget_the_biggest_on_the_screen_win_and_a_model_through_the_near_plane_covers_the_view():
    w = World()
    c = Client(w, "Bob", guild_rank=1, class_file="MAGE")
    c.load_addon()
    w.tick(1)
    c.eval(SELECT)
    r = c.eval_py(r"""
        local T = T_SEL local S, row = T.S, T.row
        local L = {}
        for j = 1, 50 do row(L, 1, 10, 0, 0, 0.1 * j, -1, 0, 0) end
        local set = S.Prepare({ version = 1, prims = T.prims, n = 50, stride = 12, data = L })
        local rects = {}
        local nm = S.ModelRects(T.occ, 1, T.cam, T.proj, rects)
        local out = {}
        local n = S.Select(set, T.cam, T.proj, rects, nm, 10, out, false)
        local again = {}
        S.Select(set, T.cam, T.proj, rects, nm, 10, again, false)
        local none = {}
        local n0 = S.Select(set, T.cam, T.proj, rects, nm, 0, none, false)
        -- a model whose box reaches behind the camera: the whole view; one wholly behind it: left out
        local occ2 = { { x = 0, y = 0, z = -1, h = 2, rb = 1 }, { x = -20, y = 0, z = 0, h = 2, rb = 1 } }
        local r2 = {}
        local nm2 = S.ModelRects(occ2, 2, T.cam, T.proj, r2)
        return { n = n, out = out, again = again, n0 = n0, none = #none, nm2 = nm2, r2 = r2[1] }
    """)
    assert r["n"] == 10 and sorted(r["out"]) == list(range(41, 51)), r
    assert r["again"] == r["out"], r                                # (the same order every redraw)
    assert r["n0"] == 0 and r["none"] == 0, r
    assert r["nm2"] == 1 and r["r2"]["x0"] < -1e300 and r["r2"]["x1"] > 1e300, r
    no_errors(w)


@case
def the_data_reads_the_same_in_chunks_and_a_broken_number_makes_it_unreadable():
    w = World()
    c = Client(w, "Bob", guild_rank=1, class_file="MAGE")
    c.load_addon()
    w.tick(1)
    c.eval(SELECT)
    r = c.eval_py(r"""
        local S = T_SEL.S
        local prims = T_SEL.prims
        local flat = { 1, 10, 0, 0, 0, 0, 0, 0.4, -1, 0, 0, 7,   1, 12, 1, 0.5, 0.2, 0, 0, 0.5, -1, 0, 0, 8 }
        local a = S.Prepare({ prims = prims, n = 2, stride = 12, data = flat })
        local b = S.Prepare({ prims = prims, n = 2, stride = 12,
          data = { "1 10 0 0 0 0 0 0.4", { -1, 0, 0, 7, 1, 12 }, "1 0.5 0.2\n0 0 0.5 -1 0 0", 8 } })
        local same = a and b and #a.d == #b.d
        for i = 1, a and #a.d or 0 do if a.d[i] ~= b.d[i] then same = false end end
        local bad = { S.Prepare({ prims = prims, data = { "1 10 x 0" } }) }
        local nan = S.Prepare({ prims = prims, data = "1 10 0 0 0 0 0 0.4 -1 0 0 7  1 10 0 0 0 0 0 0.4 -1 0 0 8",
                                n = 2, stride = 12 })
        local inf = S.Prepare({ prims = prims, data = { 1, 10, 0, 0, 0, 0, 0, 1 / 0, -1, 0, 0, 7,
                                                        1, 10, 0, 0, 0, 0, 0, 0.4, -1, 0, 0, 8 } })
        local none = { S.Prepare(nil) }
        local empty = { S.Prepare({ prims = prims, data = { 2, 10, 0, 0, 0, 0, 0, 0.4, -1, 0, 0, 7 } }) }
        return { same = same, plain = a.d == flat, bad = bad[2], inf1 = inf.R[1], inf2 = inf.R[2] ~= false,
                 none = none[2], empty = empty[2], n = b.n, plainN = nan.n }
    """)
    assert r["same"] is True and r["plain"] is True and r["n"] == 2, r   # (a table of numbers is used as it is)
    assert r["bad"] == "unreadable" and r["none"] == "none" and r["empty"] == "empty", r
    assert r["inf1"] is False and r["inf2"] is True and r["plainN"] == 2, r
    no_errors(w)


def _packed(recs, piece=G.PIECE):
    """The version 3 packing of records (as gen_standins.py writes it): the pieces and the text's size."""
    raw = G.pack_text(recs).encode("ascii")
    enc = G.encode_for_print(G.deflate_raw(raw))
    return [enc[i:i + piece] for i in range(0, len(enc), piece)], len(raw)


@case
def version_3_data_unpacks_to_the_numbers_version_2_holds_and_broken_packing_is_unreadable():
    w = World()
    c = Client(w, "Bob", guild_rank=1, class_file="MAGE")
    c.load_addon()
    w.tick(1)
    c.eval(SELECT)
    # (numbers as the files round them; the tilted quad's normal its front, R's first column)
    front = [round(_ypr(-2.35619, -0.5, 1.25)[i][0], 5) for i in range(3)]
    recs = [(1, 10, 0, 0, 0, 0, 0, 0.4, -1, 0, 0, 7), (1, 12.125, -1, 0.5, 0.2, 0, 0, 0.5, -1, 0, 0, 8),
            (2, -3.5, 7.25, 1.001, -2.35619, -0.5, 1.25, 0.018, front[0], front[1], front[2], 9),
            (2, 40.245, 77.382, -0.065, 0, -1.5708, 1.69397, 0.02252, 0, 0, 1, 9)]
    pieces, size = _packed(recs, piece=7)                        # (small pieces: several of them)
    flat = [x for r in recs for x in r]
    r = c.eval_py(r"""
        local S = T_SEL.S
        local pieces, size, flat = ...
        local prims = { { fid = 167145, kind = 'cube', half = 0.5 }, """ + QUAD_PRIM + r""" }
        local function v3(o)
          local rec = { version = 3, prims = prims, n = 4, stride = 12, size = size, packed = pieces }
          for k, v in pairs(o or {}) do rec[k] = v end
          return S.Prepare(rec)
        end
        local a = v3()
        local b = S.Prepare({ version = 2, prims = prims, n = 4, stride = 12, data = flat })
        local same = a ~= nil and b ~= nil and #a.d == #b.d and #a.d == 48
        for i = 1, a and #a.d or 0 do if a.d[i] ~= b.d[i] then same = false end end
        local function why(o) return select(2, v3(o)) end
        local changed = {}
        for i = 1, #pieces do changed[i] = pieces[i] end
        changed[1] = (changed[1]:sub(1, 1) == 'a' and 'b' or 'a') .. changed[1]:sub(2)
        return { same = same, usable = a and a.usable, R3 = a and a.R[3], E1 = a and a.E[1], pieces = #pieces,
                 size = why({ size = size + 1 }), n5 = why({ n = 5 }), n3 = why({ n = 3 }),
                 piece = why({ packed = changed }), notText = why({ packed = { pieces[1], 7 } }),
                 none = why({ packed = 'x' }), stride = why({ stride = 13 }), later = why({ version = 4 }) }
    """, pieces, size, flat)
    assert r["same"] is True and r["pieces"] > 3, r
    # (the tilted quad: its front along its normal, so usable; the cube's reach as version 2's)
    assert r["usable"] == 4 and r["R3"] and abs(r["E1"] - 0.2) < 1e-9, r
    for k in ("size", "n5", "n3", "piece", "notText", "none", "stride", "later"):
        assert r[k] == "unreadable", (k, r)
    no_errors(w)


@case
def every_rooms_data_loads_at_login_and_is_unpacked_only_when_first_used():
    """At login every data file of the TOC has run (each room's table holds its packed text, nothing unpacked); the
    first S.Load of a room unpacks it (LibDeflate once) and prepares it, the next ones reuse it; the last two rooms used
    stay prepared, an older one is let go and unpacked again when it comes back; rooms that are one room share one set;
    every shipped room's set is usable whole and matches what the generator wrote."""
    w = World()
    c = Client(w, "Bob", guild_rank=1, class_file="MAGE")
    c.load_addon()
    w.tick(1)
    c.eval(SELECT)
    keys = sorted(f[:-4] for f in os.listdir(G.OUT_DIR) if f.endswith(".lua") and not f.startswith("."))
    r = c.eval_py(r"""
        local S = T_SEL.S
        local LD = LibStub('LibDeflate')
        local calls = 0
        local orig = LD.DecompressDeflate
        LD.DecompressDeflate = function(self, ...) calls = calls + 1 return orig(self, ...) end
        local keys = ...
        local out = { loaded = {}, prepared = 0, plain = 0, sets = {} }
        for k, rec in pairs(ns.RoomStandins or {}) do
          out.loaded[#out.loaded + 1] = k
          if S.Prepared(k) then out.prepared = out.prepared + 1 end
          if rec.data ~= nil then out.plain = out.plain + 1 end
        end
        table.sort(out.loaded)
        -- every shipped room through S.Load: one unpack each (rooms that are one room: one between them; S.Load
        -- keeps two, so a room shares the set of the one loaded just before it)
        local recs = {}
        for _, k in ipairs(out.loaded) do
          local c0 = calls
          local set, why = S.Load(k)
          local rec = ns.RoomStandins[k]
          out.sets[k] = { n = set and set.n, usable = set and set.usable, unsafe = set and set.unsafe,
                          why = (not set) and why or nil, unpacks = calls - c0, shared = recs[rec] }
          recs[rec] = recs[rec] or k
        end
        -- made-up rooms A, B, C (D: the same room as A): the last two used stay prepared, an older one is let go
        local pieces, size = select(2, ...)
        local prims = { { fid = 167145, kind = 'cube', half = 0.5 } }
        for i, k in ipairs({ 'T_A', 'T_B', 'T_C' }) do
          ns.RoomFloors[k] = { size = 1000 + i }
          ns.RoomStandins[k] = { version = 3, prims = prims, n = 1, stride = 12, size = size, packed = pieces,
                                 room = { size = 1000 + i } }
        end
        ns.RoomFloors.T_D = { size = 1001 }
        ns.RoomStandins.T_D = ns.RoomStandins.T_A
        local steps = {}
        local function load(k)
          local c0 = calls
          local set = S.Load(k)
          steps[#steps + 1] = { k, calls - c0, S.Prepared('T_A'), S.Prepared('T_B'), S.Prepared('T_C') }
          return set
        end
        local a = load('T_A') load('T_A') local d = load('T_D') load('T_B') load('T_C') load('T_A')
        out.steps, out.sharedSet = steps, a == d
        LD.DecompressDeflate = orig
        return out
    """, keys, *_packed([(1, 10, 0, 0, 0, 0, 0, 0.4, -1, 0, 0, 7)]))
    loaded = r["loaded"]
    # every data file ran (each sets its own key and those of its SAME_ROOM), none unpacked, none a plain table
    want = sorted(set(keys) | {k for f in keys for k in G.SAME_ROOM.get(f, ())})
    assert loaded == want, (loaded, want)
    assert r["prepared"] == 0 and r["plain"] == 0, r
    for k in loaded:
        s = r["sets"][k]
        f = G.read_file(os.path.join(G.OUT_DIR, G.data_key(k) + ".lua"))
        assert s.get("why") is None, (k, s)
        assert s["n"] == len(f["recs"]) and s["usable"] == s["n"] and s["unsafe"] == 0, (k, s)
        if G.data_key(k) == k:
            assert s["unpacks"] == 1 and not s.get("shared"), (k, s)
        else:
            assert s["unpacks"] == 0 and s["shared"] == G.data_key(k), (k, s)
    # [key, unpacks, A, B, C prepared]: A unpacked once, again and as D (the same room) not; B, C: A let go, then back
    assert r["steps"] == [["T_A", 1, True, False, False], ["T_A", 0, True, False, False],
                          ["T_D", 0, True, False, False], ["T_B", 1, True, True, False],
                          ["T_C", 1, False, True, True], ["T_A", 1, True, False, True]], r["steps"]
    assert r["sharedSet"] is True
    no_errors(w)


@case
def on_the_board_the_mode_turns_on_and_off_and_the_box_mode_stays_as_it_was():
    w, bob = board()
    # off by default: nothing of it is made, the copies are on
    assert bob.eval("return T3.v().view.sceneS") is None
    assert bob.eval("return T3.v().standins") is None
    before = box_state(bob)
    assert before["copiesOpt"] is True and before["nOcc"] > 0, before
    g = bob.eval_py("return T3.groups(10)")
    # (the far group lies past every model: else it would rightly be shown)
    far = bob.eval_py("""
        local v, E, T = T3.v(), T3.line()
        local cam = { x = E[1], y = E[2], z = E[3], fx = v.cam.fx, fy = v.cam.mirror * v.cam.fy, fz = v.cam.fz,
                      near = 0.5 }
        local rects = {}
        local nm = ns.Render3D.Standins.ModelRects(v.occ, v.nOcc, cam, v.R.Project, rects)
        local far = 0 for i = 1, nm do far = math.max(far, rects[i].far) end
        local dx, dy, dz = T[1] - E[1], T[2] - E[2], T[3] - E[3]
        return { far = far, B = 3 * math.sqrt(dx * dx + dy * dy + dz * dz) }""")
    assert far["B"] > far["far"] + 5, far
    assert bob.slash("/dz 3d standins on")
    tick(w, 0.2)
    st = bob.eval_py("return T3.v().standins:Stats()")
    assert st["key"] == "BlackTemple_Teron" and st["total"] == 29 and st["usable"] == 26 and st["unsafe"] == 3, st
    assert bob.eval_py("return T3.shown()") == sorted(g["A"]), (bob.eval_py("return T3.shown()"), g)
    assert st["shown"] == 10 and st["actors"] == 10 and st["placed"] == 10, st
    # the scene at the bottom of the view, its opaque backdrop over it at the bottom of the floor frame, the room's
    # copies off; same camera, lens and clips as the creature scene
    lay = bob.eval_py("""
        local v = T3.v() local view = v.view local s, s0, bg = view.sceneS, view.scene, view.standinBg
        local O = __MOCK.OBJ
        local a, b = O[s], O[s0]
        local layer, sub = bg:GetDrawLayer()
        return { level = s:GetFrameLevel() - v.frame:GetFrameLevel(), shown = s:IsShown(), bgShown = bg:IsShown(),
                 bgParent = bg:GetParent() == view.floorFrame, layer = layer, sub = sub,
                 floor = view.floorFrame:GetFrameLevel() - v.frame:GetFrameLevel(),
                 room0 = v.R.Frames()[1] and v.R.Frames()[1]:GetFrameLevel() - v.frame:GetFrameLevel(),
                 cam = a.camPos[1] == b.camPos[1] and a.camPos[2] == b.camPos[2] and a.camPos[3] == b.camPos[3]
                   and a.camYPR[1] == b.camYPR[1] and a.camYPR[2] == b.camYPR[2],
                 lens = a.fov == b.fov and a.near == b.near and a.far == b.far,
                 copies = v.R.Stats().copies, copyActors = v.R.Stats().copyActors, opt = v.R.opts.copies }""")
    # (the board gives it a level of its own, under the floor frame: never level with it)
    assert lay["level"] == 1 and lay["shown"] is True and lay["floor"] == 2 and lay["room0"] >= 4, lay
    assert lay["bgShown"] is True and lay["bgParent"] is True and lay["layer"] == "BACKGROUND" and lay["sub"] == -8, lay
    assert lay["cam"] is True and lay["lens"] is True, lay
    assert lay["copies"] == 0 and lay["copyActors"] == 0 and lay["opt"] is False, lay
    # each actor placed as the creatures are: the cube, paused, mirrored y, position divided by the scale
    bad = bob.eval_py("""
        local v = T3.v() local si = v.standins local m = v.cam.mirror local L = T3.list local out = {}
        for i, a in pairs(si.at) do
          local o = (i - 1) * 12 local s = L[o + 8]
          local function near(p, q) return math.abs(p - q) < 1e-9 end
          if not (a.fileID == 167145 and a.paused == true and a.shown == true and a.scale == s
                  and near(a.pos[1], L[o + 2] / s) and near(a.pos[2], m * L[o + 3] / s) and near(a.pos[3], L[o + 4] / s)
                  and near(a.yaw, m * L[o + 5]) and near(a.pitch or 0, L[o + 6]) and near(a.roll or 0, m * L[o + 7])
                  and T3.inScene(v.view.sceneS, a) and a.alpha == 1) then
            out[#out + 1] = i
          end
        end
        return { bad = out, m = m, p1 = si.at[1] and si.at[1].pitch, r1 = si.at[1] and si.at[1].roll }""")
    assert bad["bad"] == [] and abs(bad["p1"] - 0.2) < 1e-9 and abs(bad["r1"] - bad["m"] * 0.3) < 1e-9, bad
    # nothing changed: nothing placed again; a camera move that keeps the selection: the same
    pos0 = bob.eval("return __SI.pos")
    bob.eval("T3.v():Draw()")
    st2 = bob.eval_py("return T3.v().standins:Stats()")
    assert st2["skipped"] >= 1 and st2["placed"] == 10 and bob.eval("return __SI.pos") == pos0, st2
    bob.eval("local o = T3.v().orb T3.h0 = o.heading o.heading = o.heading + 0.002 T3.v():Draw()")
    st3 = bob.eval_py("return T3.v().standins:Stats()")
    assert st3["placed"] == 10 and st3["shown"] == 10 and bob.eval("return __SI.pos") == pos0, st3
    bob.eval("local o = T3.v().orb o.heading = T3.h0 T3.v():Draw()")
    # a smaller budget hides the smallest (the biggest on the screen stay where they are); back up, only those
    # that come back are placed
    assert bob.slash("/dz 3d standins budget 4")
    kept = bob.eval_py("return T3.shown()")
    assert len(kept) == 4 and bob.eval("return __SI.pos") == pos0, kept
    hidden = bob.eval("local n = 0 for _, a in ipairs(T3.v().standins.pool) do if a.shown then n = n + 1 end end return n")
    assert hidden == 4, hidden
    assert bob.slash("/dz 3d standins budget 800")
    assert bob.eval_py("return T3.shown()") == sorted(g["A"])
    assert bob.eval("return __SI.pos") == pos0 + 6
    # off: all of it hidden, and the box mode shows what it showed
    assert bob.slash("/dz 3d standins off")
    tick(w, 0.2)
    off = bob.eval_py("""
        local v = T3.v() local view = v.view local n = 0
        for _, a in ipairs(view.standinCtl.pool) do if a.shown then n = n + 1 end end
        return { scene = view.sceneS:IsShown(), bg = view.standinBg:IsShown(), shown = n, si = v.standins == nil }""")
    assert off == {"scene": False, "bg": False, "shown": 0, "si": True}, off
    after = box_state(bob)
    assert after == before, (before, after)
    # and on again: the same stand-ins, on the actors they had
    assert bob.slash("/dz 3d standins on")
    assert bob.eval_py("return T3.shown()") == sorted(g["A"])
    assert bob.eval("return #T3.v().standins.pool") == 10
    bob.slash("/dz 3d standins off")
    no_errors(w)


@case
def stand_ins_made_for_another_build_of_the_room_are_refused_as_stale():
    # a room file made again (another payload size) may have moved a surface: its old stand-ins are not used
    w = World()
    c = Client(w, "Bob", guild_rank=1, class_file="MAGE")
    c.load_addon()
    w.tick(1)
    c.eval(SELECT)
    r = c.eval_py(r"""
        local S = T_SEL.S
        local key = 'MagtheridonsLair_Magtheridon'
        local rec = ns.RoomStandins[key]
        local ok1 = S.Load(key) ~= nil
        local size = rec.room.size
        rec.room.size = size + 1
        local set2, why2 = S.Load(key)
        rec.room = nil
        local set3, why3 = S.Load(key)
        rec.room = { size = size }
        return { ok1 = ok1, why2 = why2, why3 = why3, set2 = set2 ~= nil, set3 = set3 ~= nil, ok4 = S.Load(key) ~= nil }
    """)
    assert r == {"ok1": True, "why2": "stale", "why3": "stale", "set2": False, "set3": False, "ok4": True}, r
    no_errors(w)


@case
def a_room_without_stand_ins_keeps_the_box_mode_and_says_so_once():
    w, bob = board()
    before = box_state(bob)
    bob.eval("if ns.RoomStandins then ns.RoomStandins.BlackTemple_Teron = nil end")
    n0 = len(bob.chat_frame)
    assert bob.slash("/dz 3d standins on")
    for _ in range(3):
        bob.eval("T3.v():Draw()")
    said = chat_since(bob, n0, "No 3D stand-ins")
    assert len(said) == 1 and "BlackTemple_Teron" in said[0] and "none" in said[0], said
    assert bob.eval("return T3.v().standins") is None
    assert box_state(bob) == before
    assert bob.eval("return T3.v().view.sceneS:IsShown()") is False
    # off and on again: said again; unreadable data says why
    bob.slash("/dz 3d standins off")
    bob.eval("T3.data({ 1, 2, 3 }) ns.RoomStandins.BlackTemple_Teron.data = { '1 2 x' }")
    n1 = len(bob.chat_frame)
    bob.slash("/dz 3d standins on")
    bob.eval("T3.v():Draw()")
    said = chat_since(bob, n1, "No 3D stand-ins")
    assert len(said) == 1 and "unreadable" in said[0], said
    assert box_state(bob) == before
    # data arriving while on (a hot patch) is picked up at the next redraw
    bob.eval("T3.groups(6)")
    bob.eval("T3.v():Draw()")
    assert bob.eval("return T3.v().standins ~= nil") is True
    assert len(bob.eval_py("return T3.shown()")) == 6
    bob.slash("/dz 3d standins off")
    no_errors(w)


@case
def kiljaeden_leaves_the_backdrop_for_the_creature_scene_with_stand_ins():
    # (a client without actor SetPaused: the stand-ins freeze as Blizzard does, SetAnimation(0, 0, 0, 0))
    w, bob = board(KJ, pause=False)
    bob.eval("function T3.kj() for e, a in pairs(T3.v().actors) do if a.display == 23200 then return a, e end end end")
    # box mode: in the backdrop scene under the whole room, with no occluder (V:Actor once handed him the creature
    # scene's actor, drawn over all of the room)
    box = bob.eval_py("local a, e = T3.kj() local v = T3.v() local n = 0 "
                      "for i = 1, v.nOcc do local o = v.occ[i] if o.id == e or o.group == e then n = n + 1 end end "
                      "return { back = a.back, inBack = v.view.scene0 and T3.inScene(v.view.scene0, a) or false, "
                      "inMain = T3.inScene(v.view.scene, a), occ = n, pool = v.backPool ~= nil }")
    assert box == {"back": True, "inBack": True, "inMain": False, "occ": 0, "pool": True}, box
    bob.eval("T3.groups(5)")
    assert bob.slash("/dz 3d standins on")
    tick(w, 0.5)
    r = bob.eval_py("local a, e = T3.kj() local v = T3.v() local n = 0 "
                    "for i = 1, v.nOcc do local o = v.occ[i] if o.id == e or o.group == e then n = n + 1 end end "
                    "return { back = a.back, inMain = T3.inScene(v.view.scene, a), shown = a.shown, occ = n }")
    assert r["back"] is False and r["inMain"] is True and r["shown"] is True and r["occ"] >= 1, r
    fr = bob.eval_py("local si = T3.v().standins local n, f = 0, 0 for _, a in pairs(si.at) do n = n + 1 "
                     "if a.frozen and a.paused == nil then f = f + 1 end end return { n = n, f = f }")
    assert fr["n"] == 5 and fr["f"] == 5, fr
    assert bob.slash("/dz 3d standins off")
    tick(w, 0.3)
    r = bob.eval_py("local a, e = T3.kj() local v = T3.v() local n = 0 "
                    "for i = 1, v.nOcc do local o = v.occ[i] if o.id == e or o.group == e then n = n + 1 end end "
                    "return { back = a.back, occ = n, inBack = T3.inScene(v.view.scene0, a), "
                    "inMain = T3.inScene(v.view.scene, a), shown = a.shown }")
    assert r == {"back": True, "occ": 0, "inBack": True, "inMain": False, "shown": True}, r
    # the creature-scene actor he had in the mode went back to its own pool, not the backdrop's
    pools = bob.eval_py("local v = T3.v() local m, b = 0, 0 "
                        "for _, a in ipairs(v.actorPool) do if T3.inScene(v.view.scene, a) then m = m + 1 end end "
                        "for _, a in ipairs(v.backPool) do if T3.inScene(v.view.scene0, a) then b = b + 1 end end "
                        "return { m = m, nm = #v.actorPool, b = b, nb = #v.backPool }")
    assert pools["m"] == pools["nm"] and pools["b"] == pools["nb"] and pools["nm"] >= 1, pools
    no_errors(w)


@case
def magtheridons_lair_turns_on_with_its_shipped_stand_ins_and_shows_those_in_front_of_him():
    """The generated data file (Render3D/Standins/MagtheridonsLair_Magtheridon.lua) through the runtime: every
    stand-in usable, the mode on with no complaint, stand-ins shown over the boss, and from a round of cameras the
    board's own selection is exactly the rules' (regions only skip work; his feet's sink in the parts' records)."""
    w, bob = board(MAG)
    prep = bob.eval_py("""
        local set = ns.Render3D.Standins.Load('MagtheridonsLair_Magtheridon')
        local rec = ns.RoomStandins and ns.RoomStandins.MagtheridonsLair_Magtheridon
        return { ok = set ~= nil, n = set and set.n, usable = set and set.usable, unsafe = set and set.unsafe,
                 ng = set and set.ng, recN = rec and rec.n, key = T3.v().room.key }""")
    assert prep["ok"] and prep["key"] == "MagtheridonsLair_Magtheridon", prep
    assert prep["n"] == prep["recN"] and prep["n"] > 1000 and prep["usable"] == prep["n"] and prep["unsafe"] == 0, prep
    n0 = len(bob.chat_frame)
    assert bob.slash("/dz 3d standins on")
    tick(w, 0.3)
    assert chat_since(bob, n0, "No 3D stand-ins") == []
    st = bob.eval_py("return T3.v().standins:Stats()")
    assert st["key"] == "MagtheridonsLair_Magtheridon" and st["shown"] > 0 and st["shown"] == st["relevant"], st
    assert st["examined"] < st["total"] / 2, st                       # (whole regions turned away)
    r = bob.eval_py("""
        local v = T3.v() local si = v.standins local S = ns.Render3D.Standins local o = v.orb
        local h0, p0, d0 = o.heading, o.pitch, o.dist
        local bad, shown, sunk = {}, 0, 0
        for i = 1, v.nOcc do if (v.occ[i].sink or 0) > 0 then sunk = sunk + 1 end end
        for p = 0, 11 do
          o.heading, o.pitch, o.dist = h0 + p * 0.55, 0.25 + (p % 4) * 0.3, 15 + (p % 3) * 20
          v:Draw()
          local cam, rects = si.cam, {}
          local nm = S.ModelRects(v.occ, v.nOcc, cam, v.R.Project, rects)
          local b = __BRUTE(si.set, cam, v.R.Project, rects, nm, false)
          local cnt = 0
          for _ in pairs(si.at) do cnt = cnt + 1 end
          local sel = {}
          for i in pairs(si.at) do sel[#sel + 1] = i end
          if not __SAME(sel, cnt, b) then bad[#bad + 1] = { p = p, shown = cnt, brute = #b } end
          shown = shown + cnt
        end
        o.heading, o.pitch, o.dist = h0, p0, d0
        v:Draw()
        return { bad = bad, shown = shown, sunk = sunk }""")
    assert r["bad"] == [] and r["shown"] > 0 and r["sunk"] > 0, r
    bob.slash("/dz 3d standins off")
    no_errors(w)


@case
def debug_shows_the_cubes_over_the_room_and_the_flag_is_on_in_the_depth_layer_only():
    w, bob = board()
    g = bob.eval_py("return T3.groups(10)")
    assert bob.slash("/dz 3d standins on")
    # on by default on the stand-in scene (its draw clears the screen's depth first), never on the creature scenes
    assert bob.eval_py("return { __SI.flagCalls, __SI.flag }") == [1, True]
    scenes = bob.eval_py("""
        local view = T3.v().view
        return { main = __SI.flagScenes[view.scene] or false, two = view.scene2 and __SI.flagScenes[view.scene2] or false,
                 si = __SI.flagScenes[view.sceneS] or false }""")
    assert scenes == {"main": False, "two": False, "si": True}, scenes
    # debug draws the scene over the creatures: the flag off there (a clear would wipe their depth)
    assert bob.slash("/dz 3d standins debug")
    assert bob.eval_py("return { __SI.flagCalls, __SI.flag }") == [2, False]
    d = bob.eval_py("""
        local v = T3.v() local s = v.view.sceneS local n, a5 = 0, 0
        for _, a in pairs(v.standins.at) do n = n + 1 if a.alpha == 0.5 then a5 = a5 + 1 end end
        return { level = s:GetFrameLevel() - v.frame:GetFrameLevel(), n = n, a5 = a5 }""")
    lv = bob.eval_py("local lv = T3.v().view.lv return { plates = lv.plates, scene = lv.scene }")
    assert d["level"] == lv["plates"] - 1 and d["level"] > lv["scene"] and d["n"] == 10 and d["a5"] == 10, d
    # all: every one facing the camera and in view (A and the far B), still never the unknown model file
    assert bob.slash("/dz 3d standins debug all")
    assert bob.eval_py("return T3.shown()") == sorted(g["A"] + g["B"])
    assert bob.slash("/dz 3d standins debug off")
    d = bob.eval_py("""
        local v = T3.v() local n = 0
        for _, a in pairs(v.standins.at) do if a.alpha == 1 then n = n + 1 end end
        return { level = v.view.sceneS:GetFrameLevel() - v.frame:GetFrameLevel(), n = n, all = #T3.shown() }""")
    assert d == {"level": 1, "n": 10, "all": 10}, d
    # back in the depth layer: on again; 'flag off' is the opt-out for testing, 'flag on' undoes it
    assert bob.eval_py("return { __SI.flagCalls, __SI.flag }") == [3, True]
    assert bob.slash("/dz 3d standins flag off")
    assert bob.eval_py("return { __SI.flagCalls, __SI.flag }") == [4, False]
    assert bob.slash("/dz 3d standins flag on")
    assert bob.eval_py("return { __SI.flagCalls, __SI.flag }") == [5, True]
    n0 = len(bob.chat_frame)
    bob.slash("/dz 3d standins")
    said = [str(x) for x in bob.chat_frame[n0:]]
    assert any("3D stand-ins: on" in s for s in said) and any("BlackTemple_Teron: 29 stand-ins" in s for s in said), said
    n0 = len(bob.chat_frame)
    bob.slash("/dz 3d standins sideways")
    assert any("/dz 3d standins on | off" in str(x) for x in bob.chat_frame[n0:])
    bob.slash("/dz 3d standins off")
    no_errors(w)


@case
def walking_you_stay_in_the_second_scene_and_the_stand_ins_before_you_are_shown():
    w, bob = board()
    bob.eval("T3.v():StartWalk()")
    tick(w, 0.5)
    g = bob.eval_py("return T3.groups(6)")
    assert bob.slash("/dz 3d standins on")
    tick(w, 0.2)
    r = bob.eval_py("""
        local v = T3.v() local a = v.walk.actor
        local mine = false
        for i = 1, v.nOcc do if v.occ[i].id == v.walk then mine = true end end
        return { scene2 = T3.inScene(v.view.scene2, a), copies = v.R.Stats().copies, mine = mine }""")
    assert r == {"scene2": True, "copies": 0, "mine": True}, r
    # (the far group lies behind you and may rightly be in front of a model further on)
    shown = set(bob.eval_py("return T3.shown()"))
    assert set(g["A"]) <= shown and not shown & set(g["C"] + g["D"] + g["E"] + g["F"]), (shown, g)
    bob.eval("T3.v():StopWalk()")
    bob.slash("/dz 3d standins off")
    no_errors(w)


if __name__ == "__main__":
    run_all()

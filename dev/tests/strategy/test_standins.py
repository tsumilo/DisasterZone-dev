"""The stand-in depth mode of the strategy board's 3D view (Render3D/Standins.lua, /dz 3d standins), on the real addon.

Covers: a room's data read flat whether it comes as one table of numbers or as strings and tables of them (a broken
number makes it unreadable, a non-finite value or an unknown model file leaves that stand-in out); each stand-in's
radius and reach along its normal (a cube turned about z reaches further along a slanted normal); which stand-ins a
redraw shows: their surface facing the camera (the camera farther out along the normal than the stand-in reaches, so
not inside its slab), in front of the near plane and on the screen, and over a model's rectangle and nearer than its
farthest corner (or every one in view with 'all'), the biggest on the screen first up to the budget; a model through
the near plane covers the whole view. On the board: the mode is off by default and then makes nothing (no scene, the
copies on); 'on' makes the stand-in scene at the bottom of the view with its opaque backdrop over it in the floor frame,
on the same camera, lens and clips as the creature scene, turns the room's copies off and shows exactly the stand-ins
between the camera and the boss (model file 167145, paused, placed as the creatures are: mirrored y, position divided
by the scale, yaw and roll turned with the mirror, pitch kept); a redraw with nothing changed or a camera move that
keeps the selection places nothing again, a smaller budget hides the smallest and a bigger one places only those
that come back; 'off' hides it all and the box mode is what it was; a room without stand-ins (or unreadable ones)
keeps the box mode and says so once per turn-on; Kil'jaeden leaves the backdrop scene for the creature scene in the
mode and goes back without it; actors without SetPaused freeze with SetAnimation(0, 0, 0, 0); debug raises the scene
over the room with see-through cubes (all: every one in view), the client's flag is called only when asked; walking,
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

harness.LOAD_ROOMS = True                      # (the board's rooms)

STANDINS = "Render3D/Standins.lua"
# Until the coordinator adds the TOC line, the suite loads the stand-ins where they will sit: after the probe.
_parse_toc = harness.parse_toc


def _toc_with_standins(addon_dir, addon_name=harness.ADDON_NAME):
    headers, files = _parse_toc(addon_dir, addon_name)
    if STANDINS not in files:
        for anchor in ("Render3D/Probe.lua", "Render3D/Rooms.lua", "Render3D/View.lua"):
            if anchor in files:
                i = files.index(anchor) + 1
                files = files[:i] + [STANDINS] + files[i:]
                break
    return headers, files


harness.parse_toc = _toc_with_standins

TERON = "BlackTemple:Teron"
KJ = "SunwellPlateau:Kiljaeden"
CUBE = 167145

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
__MOCK.Methods.ModelScene.SetAllowOverlappedModels = function(self, v)
  __SI.flagCalls = __SI.flagCalls + 1
  __SI.flag = v
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
  ns.RoomStandins = ns.RoomStandins or {}
  ns.RoomStandins[key or T3.v().room.key] = { version = 1, n = #list / 12, stride = 12, data = list,
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
"""


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
        row(L, 1, 0.6, 0, 0, 1, -1, 0, 0)           -- 7 through the near plane: anywhere on the screen
        row(L, 1, 0.3, 0, 0, 1, -1, 0, 0)           -- 8 the camera inside its slab: behind its surface
        row(L, 2, 10, 0, 0, 0.4, -1, 0, 0)          -- 9 an unknown model file
        row(L, 1, 10, 0, 0, 0, -1, 0, 0)            -- 10 no size
        row(L, 1, 10, -100, 0, 1, -1, 0, 0, math.pi / 4)  -- 11 turned 45 degrees about z (off the screen)
        local set = S.Prepare({ version = 1, prims = T.prims, n = 11, stride = 12, data = L })
        local rects = {}
        local nm = S.ModelRects(T.occ, 1, T.cam, T.proj, rects)
        local out, st = {}, {}
        local n = S.Select(set, T.cam, T.proj, rects, nm, 800, out, false, st)
        local all = {}
        local na = S.Select(set, T.cam, T.proj, rects, nm, 800, all, true)
        return { n = n, out = out, st = st, na = na, all = all, usable = set.usable, unsafe = set.unsafe,
                 R1 = set.R[1], E1 = set.E[1], E8 = set.E[8], E11 = set.E[11], R9 = set.R[9], R10 = set.R[10],
                 nm = nm, rect = rects[1] }
    """)
    assert r["nm"] == 1 and 270 < r["rect"]["x0"] < 290 and 310 < r["rect"]["x1"] < 330, r["rect"]
    assert abs(r["rect"]["far"] - 21) < 1e-6, r["rect"]
    assert r["usable"] == 9 and r["unsafe"] == 1, r                 # (9: unknown file, 10: no size)
    assert r["R9"] is False and r["R10"] is False, r
    assert abs(r["R1"] - 0.2 * math.sqrt(3)) < 1e-9 and abs(r["E1"] - 0.2) < 1e-9, r
    assert abs(r["E8"] - 0.5) < 1e-9, r
    assert abs(r["E11"] - 0.5 * math.sqrt(2)) < 1e-9, r             # (a cube turned 45 degrees reaches its corner)
    # only 1 (in front of the model) and 7 (through the near plane) are shown; 'all' adds 3 and 4 (in view)
    assert r["n"] == 2 and sorted(r["out"]) == [1, 7], r
    assert r["st"]["facing"] == 7 and r["st"]["inView"] == 4 and r["st"]["relevant"] == 2, r["st"]
    assert r["na"] == 4 and sorted(r["all"]) == [1, 3, 4, 7], r
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
    assert lay["level"] == 0 and lay["shown"] is True and lay["floor"] == 1 and lay["room0"] >= 3, lay
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
    # (box mode: marked for the backdrop; which scene its actor comes from is the box mode's own business)
    assert bob.eval("local a = T3.kj() return a.back") is True
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
                    "return { back = a.back, occ = n }")
    assert r == {"back": True, "occ": 0}, r
    no_errors(w)


@case
def debug_shows_the_cubes_over_the_room_and_the_flag_is_only_set_when_asked():
    w, bob = board()
    g = bob.eval_py("return T3.groups(10)")
    assert bob.slash("/dz 3d standins on")
    assert bob.eval("return __SI.flagCalls") == 0                       # (the client's default, untouched)
    assert bob.slash("/dz 3d standins debug")
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
    assert d == {"level": 0, "n": 10, "all": 10}, d
    assert bob.slash("/dz 3d standins flag on")
    assert bob.eval_py("return { __SI.flagCalls, __SI.flag }") == [1, True]
    assert bob.slash("/dz 3d standins flag off")
    assert bob.eval_py("return { __SI.flagCalls, __SI.flag }") == [2, False]
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

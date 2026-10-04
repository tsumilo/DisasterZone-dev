"""The strategy board's 3D view (UI/StrategyMap3D.lua on the shared Render3D/ module), on the real addon.

Covers: the rooms and their map fits (a board point and a room point are one spot: the starters' bosses land where
the server spawns them, on the room's own floor); every starter's room unpacking (only the last two used stay
unpacked); walking in the room as your own character (keys, mouse, steps, walls, a jump, the camera); the 2D / 3D
switch (only for a boss with a room, greyed on a page
drawn on another map, hidden without the 3D files, which only a client restart loads); the map tilting up into the
room and back; the room drawn by the board's own renderer (not the trainer's); the boss portrait as its model with
its name over it; drawing a zone on the floor with the circle tool, moving a drawing on the floor, picking what is
under the mouse (plates, the floor of a zone), undo of 3D edits; the camera (right-drag turns and tilts, a right click
without a drag opens the menu, the wheel zooms, middle-drag moves, Q / E turn 45 degrees, Home shows the room);
"View from here" (an arrow from its start along it, a marker facing the boss) and "My spot"; the small map in the
corner (a click looks there); a page on another map drops back to 2D and the room comes back on a page that has it.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_3d.py [-k name]
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import world, save_council  # noqa: E402
from _common import case, run_all, no_errors, menu_texts, strip_codes, World, Client  # noqa: E402
import harness  # noqa: E402

harness.LOAD_ROOMS = True                      # (the mock leaves the board's rooms out unless asked)

TERON = "BlackTemple:Teron"
VASHJ = "SerpentshrineCavern:Vashj"
W = "_G.DisasterZoneStrategyBoard"
# The tests' room points are in a frame of their own round the boss, the Raid Trainer's old rooms' (Teron's hall:
# Teron stands at 29.9, 85.2 in his alcove, the hall 6.2 yd over it, its entrance near y = 5; Vashj in the middle at
# 105, 105), moved onto the generated room by its boss spot (T3.ox, T3.oy).
LURKER = "SerpentshrineCavern:Lurker"
BASE = {TERON: (29.9, 85.2), VASHJ: (105.0, 105.0), LURKER: (0.0, 0.0)}

HELPERS = r"""
T3 = { down = {} }
function T3.cv() return _G.DisasterZoneStrategyBoard.canvas end
function T3.v() return T3.cv().v3 end
function T3.page() return ns.StrategyBoard:GetState().strat.p[ns.StrategyBoard:GetState().page] end
function T3.elems() return T3.page().e end
T3.ox, T3.oy = 0, 0
-- the floor height and the screen point of a test point (the view's own measured camera)
function T3.ground(x, y) return T3.v():Ground(x + T3.ox, y + T3.oy) end
function T3.screen(x, y, up)
  local v = T3.v()
  x, y = x + T3.ox, y + T3.oy
  return v.R.Project(x, y, v:Ground(x, y) + (up or 0))
end
-- a test point on the board, and a board point (or a drawing) as a test point
function T3.toBoard(x, y) return ns.Render3D.RoomToBoard(T3.v().room, T3.page(), x + T3.ox, y + T3.oy) end
-- the mouse at a screen point of the scene (the mock puts every frame at 0, 0)
function T3.cursor(sx, sy)
  local es = T3.v().view.scene:GetEffectiveScale() or 1
  _G.GetCursorPosition = function() return sx * es, sy * es end
end
function T3.at(x, y, up) local sx, sy = T3.screen(x, y, up) T3.cursor(sx, sy) return sx, sy end
_G.IsMouseButtonDown = function(b) return T3.down[b or "LeftButton"] == true end
function T3.press(b) T3.down[b] = true T3.cv():OnMouseDown(b) end
function T3.release(b) T3.down[b] = nil T3.cv():OnMouseUp(b) end
function T3.room(e)
  local x, y = ns.Render3D.BoardToRoom(T3.v().room, T3.page(), e.x, e.y)
  return { x - T3.ox, y - T3.oy }
end
function T3.state() return T3.v():_State() end
-- the camera, its point as a test point
function T3.orb()
  local o = T3.state().orb
  o.x, o.y = o.x - T3.ox, o.y - T3.oy
  return o
end
"""


def boot(boss=TERON):
    w, c = world()
    bob = c["Bob"]
    bob.eval(HELPERS)
    bob.eval("local s = ns.Render3D.RoomForBoss(...).spot T3.ox, T3.oy = s.x - %r, s.y - %r" % BASE[boss], boss)
    bob.eval("ns.StrategyBoard:NewStrategy(...)", boss)
    w.tick(0.2)
    return w, c, bob


def go3d(w, bob, animate=False):
    assert bob.eval("return T3.cv():Set3D(true, %s)" % ("true" if animate else "false")) is True
    w.tick(0.1)


def tick(w, secs):
    for _ in range(int(secs / 0.05 + 0.5)):
        w.tick(0.05)


# ------------------------------------------------------------------------------------------------------------------
@case
def the_rooms_put_the_starters_bosses_where_the_server_spawns_them():
    w, c, bob = boot()
    assert bob.eval_py("return ns.Render3D.RoomForBoss(...).key", TERON) == "BlackTemple_Teron"
    assert bob.eval_py("return ns.Render3D.RoomForBoss(...).key", VASHJ) == "SerpentshrineCavern_Vashj"
    assert bob.eval_py("return ns.Render3D.RoomForBoss('BlackTemple:Nobody')") is None
    # board -> room -> board is exact
    rt = bob.eval_py("local r = ns.Render3D.RoomForBoss(...) local p = { vx = 390, vy = 220, vz = 280 } "
                     "local x, y = ns.Render3D.BoardToRoom(r, p, 123, 456) "
                     "local bx, by = ns.Render3D.RoomToBoard(r, p, x, y) return { bx, by }", TERON)
    assert abs(rt[0] - 123) < 1e-6 and abs(rt[1] - 456) < 1e-6, rt
    go3d(w, bob)
    # Teron's portrait on the starter lands within 5 yd of his spawn, on the alcove's floor (the room's 0)
    e = bob.eval_py("for _, e in ipairs(T3.elems()) do if e.t == 'i' then return e end end")
    xy = bob.eval_py("return T3.room(...)", e)
    assert math.hypot(xy[0] - 29.9, xy[1] - 85.2) < 5, xy
    z = bob.eval_py("return T3.ground(...)", xy[0], xy[1])
    assert abs(z) < 0.6, z
    z = bob.eval_py("return T3.ground(30, 15)")
    assert abs(z - 6.23) < 0.6, z                      # (the hall's entrance is 6.2 yd over the alcove)
    no_errors(w)
    # Vashj's starter: within 3 yd of her spot in the middle of her room
    w2, c2, bob2 = boot(VASHJ)
    go3d(w2, bob2)
    e = bob2.eval_py("for _, e in ipairs(T3.elems()) do if e.t == 'i' then return e end end")
    xy = bob2.eval_py("return T3.room(...)", e)
    assert math.hypot(xy[0] - 105, xy[1] - 105) < 3, xy
    no_errors(w2)


@case
def every_starter_boss_has_a_room_that_unpacks():
    w, c = world()
    bob = c["Bob"]
    res = bob.eval_py("""
        local R3, out, n = ns.Render3D, { missing = {}, bad = {} }, 0
        local refs = {}
        for ref in pairs(R3.ROOM_INDEX) do refs[#refs + 1] = ref end
        table.sort(refs)
        for _, ref in ipairs(refs) do
          local room = R3.RoomForBoss(ref)
          if not (room and R3.HasFloor(room)) then
            out.missing[#out.missing + 1] = ref
          else
            local f = R3.Floor(room)
            local m = f and f.mesh
            if not (m and #f.rows > 0 and #m.verts % 6 == 0 and #m.tris % 4 == 0 and #m.textures == #m.blend
                    and #m.nodes > 0 and R3.Height(room)(room.spot.x, room.spot.y)) then
              out.bad[#out.bad + 1] = ref
            end
            n = n + 1
          end
        end
        local kept = 0
        for _, f in pairs(ns.RoomFloors) do if f.version == 3 and f.mesh then kept = kept + 1 end end
        out.n, out.kept = n, kept
        return out
    """)
    assert res["n"] >= 50 and not res["missing"] and not res["bad"], res
    assert res["kept"] == 2, res                                         # (the rest keep only their packed text)
    # a room put away unpacks again when it is used
    assert bob.eval_py("local r = ns.Render3D.RoomForBoss(...) return ns.RoomFloors[r.floor].mesh == nil", TERON) is True
    assert bob.eval_py("local r = ns.Render3D.RoomForBoss(...) return ns.Render3D.Floor(r).mesh ~= nil", TERON) is True
    no_errors(w)


@case
def the_switch_is_there_for_a_boss_with_a_room():
    w, c = world()
    bob = c["Bob"]
    bob.eval(HELPERS)
    sid = save_council(bob)
    w.tick(1)
    # (every starter boss has a room: one without, as a custom boss would be)
    bob.eval("local f = ns.Render3D.RoomForBoss "
             "ns.Render3D.RoomForBoss = function(r) if r == 'BlackTemple:Council' then return nil end return f(r) end")
    bob.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", sid)
    w.tick(0.2)
    assert bob.eval("return %s.mode3d:IsShown()" % W) is False
    bob.eval("ns.StrategyBoard:NewStrategy(...)", TERON)
    w.tick(0.2)
    assert bob.eval("return %s.mode3d:IsShown() and %s.mode3d:IsEnabled()" % (W, W)) is True
    assert bob.eval("return %s.mode2d.kind" % W) == "chosen"
    # a page on another map: greyed out, saying which map the room is on
    bob.eval("T3.page().m = 0 ns.StrategyBoard:Refresh()")
    assert bob.eval("return %s.mode3d:IsShown()" % W) is True
    assert bob.eval("return %s.mode3d:IsEnabled()" % W) is False
    assert "Teron Gorefiend's room" in bob.eval("return %s.mode3d.tip" % W)
    no_errors(w)


@case
def the_map_tilts_up_into_the_room_and_back_down():
    w, c, bob = boot()
    bob.eval("ns.StrategyBoard:Set3D(true)")
    w.tick(0.05)
    st = bob.eval_py("return T3.state()")
    assert st["on"] is True and st["animating"] is True and st["room"] == "BlackTemple_Teron", st
    assert st["orb"]["pitch"] > 1.3, st["orb"]                          # starts as the map seen from above
    assert bob.eval("return T3.cv().art:IsShown()") is False
    assert bob.eval("return %s.mode3d.kind" % W) == "chosen"
    tick(w, 0.8)
    st = bob.eval_py("return T3.state()")
    assert st["animating"] is False and abs(st["orb"]["pitch"] - 0.9) < 0.01, st["orb"]
    assert st["measured"] is True and st["textures"] > 200, st         # the room is drawn
    assert st["models"] == 1 and st["plates"] >= 1, st                  # Teron as his model, his name over him
    assert st["inset"] is True and st["compass"] is True
    # the board's renderer is its own, not the trainer's
    assert bob.eval_py("return T3.v().R ~= ns.TrainerRoom and ns.TrainerRoom ~= nil") is True
    # back down to the map
    bob.eval("ns.StrategyBoard:Set3D(false)")
    tick(w, 0.8)
    assert bob.eval("return T3.cv():Is3D()") is False
    assert bob.eval("return T3.cv().art:IsShown() and T3.cv().layer:IsShown()") is True
    assert bob.eval("return %s.mode2d.kind" % W) == "chosen"
    no_errors(w)


@case
def a_zone_drawn_on_the_floor_lands_where_the_mouse_was():
    w, c, bob = boot()
    go3d(w, bob)
    tick(w, 0.3)
    n0 = bob.eval("return #T3.elems()")
    bob.eval("T3.cv():SetTool('circle')")
    bob.eval("T3.at(30, 20) T3.press('LeftButton')")
    bob.eval("T3.at(36, 20) T3.cv():OnDragUpdate()")
    bob.eval("T3.release('LeftButton')")
    w.tick(0.1)
    es = bob.eval_py("return T3.elems()")
    assert len(es) == n0 + 1 and es[-1]["t"] == "z" and es[-1]["s"] == "c", es[-1]
    xy = bob.eval_py("return T3.room(T3.elems()[#T3.elems()])")
    assert math.hypot(xy[0] - 30, xy[1] - 20) < 1.0, xy
    r = bob.eval_py("local e = T3.elems()[#T3.elems()] local sx = ns.Render3D.BoardScale(T3.v().room, T3.page()) "
                    "return e.w / 2 * sx")
    assert abs(r - 6) < 1.0, r                                          # the radius in yards, as dragged
    assert bob.eval("return T3.cv():SelectionCount()") == 1
    assert bob.eval("return T3.cv().tool") == "select"
    st = bob.eval_py("return T3.state()")
    assert st["handles"] == 1, st                                       # the zone's size corner
    # undo takes it back, as on the map
    bob.set_modifiers(False, True, False)
    bob.eval("_G.DisasterZoneStrategyBoard:GetScript('OnKeyDown')(_G.DisasterZoneStrategyBoard, 'Z')")
    bob.set_modifiers(False, False, False)
    w.tick(0.1)
    assert bob.eval("return #T3.elems()") == n0
    no_errors(w)


@case
def a_drawing_is_picked_under_the_mouse_and_moved_on_the_floor():
    w, c, bob = boot()
    bob.eval("table.insert(T3.page().e, { t = 'x', x = 0, y = 0, l = 'Stack here', z = 2, c = 9 })")
    go3d(w, bob)
    # put the text at room (25, 30)
    bob.eval("local e = T3.elems()[#T3.elems()] local bx, by = T3.toBoard(25, 30) "
             "e.x, e.y = math.floor(bx + 0.5), math.floor(by + 0.5) T3.cv():Render()")
    tick(w, 0.2)
    bob.eval("T3.at(25, 30, 0.6)")                                     # over its plate
    assert bob.eval_py("local e = T3.cv():HitTest() return e and e.l") == "Stack here"
    # drag it to room (35, 12): the floor point under the mouse
    bob.eval("T3.press('LeftButton')")
    bob.eval("T3.at(35, 12, 0.6) T3.cv():OnDragUpdate()")
    bob.eval("T3.release('LeftButton')")
    w.tick(0.1)
    xy = bob.eval_py("return T3.room(T3.elems()[#T3.elems()])")
    assert math.hypot(xy[0] - 35, xy[1] - 12) < 1.5, xy
    # a zone is picked by the floor under the mouse
    bob.eval("local bx, by = T3.toBoard(15, 40) "
             "table.insert(T3.page().e, 1, { t = 'z', s = 'r', x = math.floor(bx), y = math.floor(by), w = 30, h = 30, c = 2 }) "
             "T3.cv():Render()")
    tick(w, 0.2)
    bob.eval("T3.at(15, 40)")
    assert bob.eval_py("local e = T3.cv():HitTest() return e and e.t") == "z"
    no_errors(w)


@case
def the_camera_turns_tilts_zooms_and_moves():
    w, c, bob = boot()
    go3d(w, bob)
    tick(w, 0.2)
    o0 = bob.eval_py("return T3.state().orb")
    # right-drag: turn and tilt; no menu after a drag
    bob.eval("T3.cursor(300, 200) T3.press('RightButton')")
    bob.eval("T3.cursor(380, 240)")
    w.tick(0.05)
    o1 = bob.eval_py("return T3.state().orb")
    assert abs(o1["heading"] - (o0["heading"] - 80 * 0.008)) < 1e-6, (o0, o1)
    assert abs(o1["pitch"] - max(0.12, o0["pitch"] - 40 * 0.006)) < 1e-6, (o0, o1)
    bob.eval("T3.release('RightButton')")
    menu = bob.last_menu()
    # a right click without a drag opens the menu (on the floor: add here / look here)
    bob.eval("T3.at(40, 15) T3.press('RightButton') T3.release('RightButton')")
    texts = [strip_codes(t[2]) for t in menu_texts(bob.last_menu()) if t[2]]
    assert "Look here" in texts and "View from here" in texts, texts
    # the wheel zooms
    d0 = bob.eval_py("return T3.state().orb.dist")
    bob.eval("T3.cv():OnWheel(1)")
    assert bob.eval_py("return T3.state().orb.dist") < d0
    # Q turns 45 degrees (eased)
    h0 = bob.eval_py("return T3.state().orb.heading")
    bob.eval("_G.DisasterZoneStrategyBoard:GetScript('OnKeyDown')(_G.DisasterZoneStrategyBoard, 'Q')")
    tick(w, 0.5)
    assert abs(bob.eval_py("return T3.state().orb.heading") - (h0 + math.pi / 4)) < 1e-6
    # middle-drag moves the point looked at
    p0 = bob.eval_py("return T3.state().orb")
    bob.eval("T3.cursor(350, 233) T3.press('MiddleButton')")
    bob.eval("T3.cursor(300, 233)")
    w.tick(0.05)
    bob.eval("T3.release('MiddleButton')")
    p1 = bob.eval_py("return T3.state().orb")
    assert math.hypot(p1["x"] - p0["x"], p1["y"] - p0["y"]) > 1, (p0, p1)
    # Home: the whole room again
    bob.eval("_G.DisasterZoneStrategyBoard:GetScript('OnKeyDown')(_G.DisasterZoneStrategyBoard, 'HOME')")
    tick(w, 0.5)
    o = bob.eval_py("return T3.state().orb")
    v = bob.eval_py("return T3.v().room.view")
    assert abs(o["x"] - v["x"]) < 1e-6 and abs(o["y"] - v["y"]) < 1e-6 and abs(o["dist"] - v["dist"]) < 1e-6, (o, v)
    no_errors(w)


@case
def view_from_here_and_my_spot():
    w, c, bob = boot()
    # a tank block and the tank's marker in the hall, an arrow from the entrance into the room
    bob.eval("local p = T3.page() p.k = { { id = 'tk', n = 'Tanks', r = 1, c = { { t = 'p', n = 'Tank' } } } } "
             "ns.StrategyBoard:MarkDirty(true)")
    go3d(w, bob)
    bob.eval("local p = T3.page() "
             "local sx, sy = T3.toBoard(30, 60) "
             "local ax, ay = T3.toBoard(30, 5) local bx, by = T3.toBoard(30, 40) "
             "table.insert(p.e, { t = 's', x = math.floor(sx + 0.5), y = math.floor(sy + 0.5), r = 'tk.1.1' }) "
             "table.insert(p.e, { t = 'a', x = math.floor(ax + 0.5), y = math.floor(ay + 0.5), x2 = math.floor(bx + 0.5), "
             "y2 = math.floor(by + 0.5), h = true, c = 4 }) T3.cv():Render()")
    tick(w, 0.2)
    # the marker: at eye height on its spot, facing Teron (north, down the steps)
    bob.eval("T3.cv():ViewFrom3D(T3.elems()[#T3.elems() - 1])")
    tick(w, 0.5)
    o = bob.eval_py("return T3.orb()")
    teron = bob.eval_py("for _, e in ipairs(T3.elems()) do if e.t == 'i' then return T3.room(e) end end")
    assert abs(o["dist"] - 0.3) < 1e-6 and math.hypot(o["x"] - 30, o["y"] - 60) < 1, o
    want = math.atan2(teron[1] - o["y"], teron[0] - o["x"])
    assert abs((o["heading"] - want + math.pi) % (2 * math.pi) - math.pi) < 0.05, (o, want)
    # the arrow: from its start, looking along it (north)
    bob.eval("T3.cv():ViewFrom3D(T3.elems()[#T3.elems()])")
    tick(w, 0.5)
    o = bob.eval_py("return T3.orb()")
    assert math.hypot(o["x"] - 30, o["y"] - 5) < 1 and abs(o["heading"] - math.pi / 2) < 0.05, o
    # My spot: shown when one of my slots has a marker on the page; it stands there
    assert bob.eval_py("return T3.state().mySpots") == 0
    bob.eval("T3.cv().opts.mySlots = function() return { ['tk.1.1'] = true } end T3.cv():Render()")
    w.tick(0.1)
    assert bob.eval("return T3.v().eyeBtn:IsShown()") is True
    bob.eval("T3.v().eyeBtn:Click()")
    tick(w, 0.5)
    o = bob.eval_py("return T3.orb()")
    assert math.hypot(o["x"] - 30, o["y"] - 60) < 1 and o["dist"] < 0.5, o
    # the element menu offers it too
    bob.eval("T3.cv():ElementMenu(T3.elems()[#T3.elems() - 1])")
    texts = [strip_codes(t[2]) for t in menu_texts(bob.last_menu()) if t[2]]
    assert "View from here" in texts, texts
    no_errors(w)


@case
def the_small_map_shows_the_page_and_a_click_there_looks_there():
    w, c, bob = boot()
    go3d(w, bob)
    tick(w, 0.2)
    inset = bob.eval_py("local i = T3.v().inset return { shown = i.frame:IsShown(), page = i.page == T3.page() }")
    assert inset == {"shown": True, "page": True}, inset
    # a click on the small map at the board point of room (40, 30)
    bob.eval("local i = T3.v().inset local bx, by = T3.toBoard(40, 30) "
             "i.Cursor = function() return bx, by end i.frame:GetScript('OnMouseDown')(i.frame, 'LeftButton') "
             "i.frame:GetScript('OnMouseUp')(i.frame, 'LeftButton')")
    tick(w, 0.5)
    o = bob.eval_py("return T3.orb()")
    assert math.hypot(o["x"] - 40, o["y"] - 30) < 0.5, o
    # the map button hides it
    bob.eval("T3.v().mapBtn:Click()")
    assert bob.eval("return T3.v().inset.frame:IsShown()") is False
    no_errors(w)


@case
def a_page_on_another_map_shows_in_2d_and_the_room_comes_back():
    w, c, bob = boot()
    go3d(w, bob)
    bob.eval("ns.StrategyBoard:AddPage()")
    w.tick(0.2)
    # the new page starts with the same map: still 3D; on a blank map it drops to the map
    assert bob.eval("return T3.cv():Is3D()") is True
    bob.eval("T3.page().m = 0 ns.StrategyBoard:Refresh()")
    w.tick(0.1)
    assert bob.eval("return T3.cv():Is3D()") is False and bob.eval("return T3.cv().art:IsShown()") is True
    bob.eval("local st = ns.StrategyBoard:GetState() st.page = 1 ns.StrategyBoard:Refresh()")
    w.tick(0.1)
    assert bob.eval("return T3.cv():Is3D()") is True
    no_errors(w)


@case
def a_new_strategy_opened_in_3d_shows_its_own_boss_room():
    w, c, bob = boot()
    go3d(w, bob)
    assert bob.eval_py("return T3.state().room") == "BlackTemple_Teron"
    bob.eval("ns.StrategyBoard:NewStrategy(...)", VASHJ)
    w.tick(0.2)
    assert bob.eval("return T3.cv():Is3D()") is True
    assert bob.eval_py("return T3.state().room") == "SerpentshrineCavern_Vashj"
    no_errors(w)


@case
def a_drawing_moved_in_the_room_looks_through_what_stands_high_over_its_floor():
    w, c, bob = boot()
    bob.eval("table.insert(T3.page().e, { t = 'x', x = 0, y = 0, l = 'Stack here', z = 2, c = 9 })")
    go3d(w, bob)
    bob.eval("local e = T3.elems()[#T3.elems()] local bx, by = T3.toBoard(30, 20) "
             "e.x, e.y = math.floor(bx + 0.5), math.floor(by + 0.5) T3.cv():Render()")
    tick(w, 0.2)
    # a 12 yd pillar between: on its own the floor search stops on its top; moving, the floor behind it counts
    bob.eval("local H = T3.v().H T3.v().H = function(x, y) "
             "if math.abs(x - (40 + T3.ox)) < 3 and math.abs(y - (15 + T3.oy)) < 2 then return 18 end return H(x, y) end "
             "T3.v():HeightRange() T3.v().hiZ = 18.5")
    bob.eval("T3.at(30, 20, 0.6) T3.press('LeftButton')")
    bob.eval("T3.at(40, 20) T3.cv():OnDragUpdate()")
    bob.eval("T3.release('LeftButton')")
    w.tick(0.1)
    xy = bob.eval_py("return T3.room(T3.elems()[#T3.elems()])")
    assert math.hypot(xy[0] - 40, xy[1] - 20) < 1.5, xy
    no_errors(w)


def walk_key(bob, key, down):
    bob.eval("local f = T3.v().keys f:GetScript('%s')(f, '%s')" % ("OnKeyDown" if down else "OnKeyUp", key))


WALKER = ("local k = T3.v().walk.k return { x = k.x - T3.ox, y = k.y - T3.oy, z = k.z, f = k.facing, "
          "falling = k.falling or false, swimming = k.swimming }")


@case
def walking_in_the_room_runs_down_the_steps_stops_at_walls_and_jumps():
    w, c, bob = boot()
    go3d(w, bob)
    tick(w, 0.3)
    # dropped in where the camera looks (the hall's entrance), facing Teron (north)
    bob.eval("local o = T3.v().orb o.x, o.y = 30 + T3.ox, 20 + T3.oy")
    bob.eval("T3.v().walkBtn:Click()")
    w.tick(0.05)
    k = bob.eval_py(WALKER)
    assert math.hypot(k["x"] - 30, k["y"] - 20) < 0.01 and abs(k["z"] - 6.2) < 0.6, k
    assert abs(k["f"] - math.pi / 2) < 0.05, k
    assert bob.eval_py("return T3.v().walkBtn.active") is True
    # W: 7 yd a second, the camera behind you
    walk_key(bob, "W", True)
    tick(w, 1.0)
    k = bob.eval_py(WALKER)
    assert abs(k["y"] - 27) < 0.3 and abs(k["x"] - 30) < 0.2, k
    assert bob.eval_py("return T3.v().walk.actor.anim") == 5                     # (running)
    walk_key(bob, "W", False)
    w.tick(0.05)
    assert bob.eval_py("return T3.v().walk.actor.anim") == 0                     # (standing once stopped)
    walk_key(bob, "W", True)
    o = bob.eval_py("return T3.orb()")
    assert math.hypot(o["x"] - k["x"], o["y"] - k["y"]) < 0.01 and abs(o["heading"] - k["f"]) < 1e-6, o
    # on north: down the ramp into the alcove (Teron's floor, the room's 0), and the alcove's back wall stops you
    tick(w, 11.05)
    walk_key(bob, "W", False)
    k = bob.eval_py(WALKER)
    assert abs(k["z"]) < 0.3 and 88 < k["y"] < 95 and not k["falling"], k
    y = k["y"]
    walk_key(bob, "W", True)
    tick(w, 1.0)
    walk_key(bob, "W", False)
    assert abs(bob.eval_py(WALKER)["y"] - y) < 0.05
    # Space: up about 1.6 yd and down again
    walk_key(bob, "SPACE", True)
    walk_key(bob, "SPACE", False)
    top = 0
    for _ in range(20):
        w.tick(0.05)
        top = max(top, bob.eval_py("return T3.v().walk.k.z"))
    assert 1.3 < top < 1.8, top
    assert abs(bob.eval_py(WALKER)["z"]) < 0.05
    # only the walking keys stay with the view, the rest go on to the game
    assert bob.eval("local f = T3.v().keys return f:GetPropagateKeyboardInput()") is False
    walk_key(bob, "M", True)
    assert bob.eval("local f = T3.v().keys return f:GetPropagateKeyboardInput()") is True
    # Escape: the free camera again, over where you were
    walk_key(bob, "ESCAPE", True)
    assert bob.eval_py("return T3.v():IsWalking()") is False
    o = bob.eval_py("return T3.orb()")
    assert math.hypot(o["x"] - 29.9, o["y"] - y) < 0.5 and o["dist"] >= 12, o
    no_errors(w)


@case
def walking_starts_on_my_spot_and_the_mouse_turns_and_swings_the_camera():
    w, c, bob = boot()
    bob.eval("local p = T3.page() p.k = { { id = 'tk', n = 'Tanks', r = 1, c = { { t = 'p', n = 'Tank' } } } } "
             "ns.StrategyBoard:MarkDirty(true)")
    go3d(w, bob)
    bob.eval("local p = T3.page() local sx, sy = T3.toBoard(30, 60) "
             "table.insert(p.e, { t = 's', x = math.floor(sx + 0.5), y = math.floor(sy + 0.5), r = 'tk.1.1' }) "
             "T3.cv().opts.mySlots = function() return { ['tk.1.1'] = true } end T3.cv():Render()")
    tick(w, 0.2)
    bob.eval("T3.v():StartWalk()")
    k = bob.eval_py(WALKER)
    assert math.hypot(k["x"] - 30, k["y"] - 60) < 1, k
    # right-drag turns you; left-drag swings the camera round you without turning you
    f0 = k["f"]
    bob.eval("T3.cursor(300, 200) T3.press('RightButton')")
    bob.eval("T3.cursor(350, 200)")
    w.tick(0.05)
    bob.eval("T3.release('RightButton')")
    f1 = bob.eval_py(WALKER)["f"]
    assert abs(f1 - (f0 - 50 * 0.008)) < 1e-6, (f0, f1)
    bob.eval("T3.cursor(300, 200) T3.press('LeftButton')")
    bob.eval("T3.cursor(250, 200)")
    w.tick(0.05)
    bob.eval("T3.release('LeftButton')")
    assert abs(bob.eval_py(WALKER)["f"] - f1) < 1e-6
    assert abs(bob.eval_py("return T3.v().walk.yawOff") - 50 * 0.008) < 1e-6
    # running brings the camera back behind you
    walk_key(bob, "W", True)
    tick(w, 1.5)
    walk_key(bob, "W", False)
    assert abs(bob.eval_py("return T3.v().walk.yawOff")) < 0.02
    # the wheel zooms the walking camera; nothing is drawn while walking
    d0 = bob.eval_py("return T3.v().walk.dist")
    bob.eval("T3.cv():OnWheel(1)")
    assert bob.eval_py("return T3.v().walk.dist") < d0
    n0 = bob.eval("return #T3.elems()")
    bob.eval("T3.cv():SetTool('circle') T3.cursor(300, 150) T3.press('LeftButton')")
    bob.eval("T3.cursor(330, 150) T3.cv():OnDragUpdate() T3.release('LeftButton')")
    assert bob.eval("return #T3.elems()") == n0
    # leaving the room (back to the map) stops walking
    bob.eval("ns.StrategyBoard:Set3D(false)")
    tick(w, 0.8)
    assert bob.eval_py("return T3.v():IsWalking()") is False
    no_errors(w)


@case
def dragging_the_walk_button_into_the_room_drops_you_where_it_is_let_go():
    w, c, bob = boot()
    go3d(w, bob)
    tick(w, 0.3)
    btn = "T3.v().walkBtn"
    bob.eval("%s:GetScript('OnDragStart')(%s)" % (btn, btn))
    assert bob.eval("return T3.v().peg:IsShown()") is True
    # let go over the room at (40, 30): you stand there (the mock's mouse is over nothing unless told)
    bob.eval("T3.v().frame.IsMouseOver = function() return true end T3.at(40, 30)")
    bob.eval("%s:GetScript('OnDragStop')(%s)" % (btn, btn))
    assert bob.eval("return T3.v().peg:IsShown()") is False
    k = bob.eval_py(WALKER)
    assert math.hypot(k["x"] - 40, k["y"] - 30) < 1, k
    # dragged again, onto the small map: that board point
    bob.eval("%s:GetScript('OnDragStart')(%s)" % (btn, btn))
    bob.eval("T3.v().frame.IsMouseOver = function() return false end "
             "local i = T3.v().inset i.frame.IsMouseOver = function() return true end "
             "local bx, by = T3.toBoard(20, 50) i.Cursor = function() return bx, by end")
    bob.eval("%s:GetScript('OnDragStop')(%s)" % (btn, btn))
    k = bob.eval_py(WALKER)
    assert math.hypot(k["x"] - 20, k["y"] - 50) < 1, k
    # let go over nothing: still where you were
    bob.eval("%s:GetScript('OnDragStart')(%s)" % (btn, btn))
    bob.eval("T3.v().inset.frame.IsMouseOver = function() return false end")
    bob.eval("%s:GetScript('OnDragStop')(%s)" % (btn, btn))
    k = bob.eval_py(WALKER)
    assert math.hypot(k["x"] - 20, k["y"] - 50) < 1, k
    # you stand in the view's second scene, over the bosses' copies
    w.tick(0.05)
    assert bob.eval_py("return T3.v().view.scene2 ~= nil and T3.v().occ[T3.v().nOcc].layer") == 2
    no_errors(w)


@case
def a_big_model_is_hidden_part_by_part_and_you_swim_in_its_pool():
    w, c, bob = boot(LURKER)
    go3d(w, bob)
    tick(w, 1.0)
    # the Lurker as he stands (30 yd across, his tail 40 yd down in the water): one occluder per part of him
    parts = bob.eval_py("local e for _, x in ipairs(T3.elems()) do if x.t == 'i' then e = x end end "
                        "local d = T3.v():Geo(e).display return #ns.Render3D.DISPLAY_PARTS[d] / 6")
    assert parts == 6, parts
    bob.eval("local o = T3.v().orb o.x, o.y, o.dist, o.heading, o.pitch = T3.ox, T3.oy - 3, 30, math.pi / 2, 0.55 "
             "T3.v():Draw()")
    tick(w, 0.2)
    assert bob.eval_py("return T3.v().nOcc") == 6
    st = bob.eval_py("return T3.v().R.Stats()")
    assert st["copyActors"] >= 4 and st["copyDropped"] == 0 and st["copies"] > 0, st
    # dropped in on him: in the pool, swimming at its surface
    bob.eval("local o = T3.v().orb o.x, o.y = T3.ox + 20, T3.oy + 30")
    bob.eval("T3.v():StartWalk()")
    k = bob.eval_py(WALKER)
    assert k["swimming"] is True and abs(k["z"]) < 0.5, k
    assert bob.eval_py("return T3.v().walk.actor.anim") == 41                    # (swimming in place)
    walk_key(bob, "W", True)
    tick(w, 1.0)
    walk_key(bob, "W", False)
    k2 = bob.eval_py(WALKER)
    assert 3.5 < math.hypot(k2["x"] - k["x"], k2["y"] - k["y"]) < 5.5, (k, k2)     # (4.7 yd a second)
    no_errors(w)


@case
def reading_a_board_the_camera_moves_with_a_left_drag():
    w, c, bob = boot()
    go3d(w, bob)
    bob.eval("local st = ns.StrategyBoard:GetState() st.mode = 'view' ns.StrategyBoard:Refresh()")
    tick(w, 0.2)
    assert bob.eval("return T3.cv():Editable()") is False
    assert "Drag to move the view" in bob.eval_py("return T3.state().hint")
    p0 = bob.eval_py("return T3.state().orb")
    bob.eval("T3.cursor(350, 233) T3.press('LeftButton')")
    bob.eval("T3.cursor(350, 290)")
    w.tick(0.05)
    bob.eval("T3.release('LeftButton')")
    p1 = bob.eval_py("return T3.state().orb")
    assert math.hypot(p1["x"] - p0["x"], p1["y"] - p0["y"]) > 1, (p0, p1)
    n0 = bob.eval("return #T3.elems()")
    assert n0 == bob.eval("return #T3.elems()")                      # nothing was drawn
    no_errors(w)


@case
def without_the_3d_files_there_is_no_switch_and_a_restart_is_asked_for_once():
    w = World()
    names = (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"))
    c = {}
    for name, rank, cls in names:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    bob = c["Bob"]
    toc = bob.toc
    bob.toc = lambda: (toc()[0], [f for f in toc()[1] if "Render3D\\" not in f.replace("/", "\\")
                                  and not f.replace("/", "\\").endswith("StrategyMap3D.lua")])
    for x in c.values():
        x.load_addon()
    w.tick(3)
    from rp_common import gm_pick, set_raid_leaders  # noqa: E402
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ["Bob"])
    w.tick(2)
    n0 = len(bob.chat_frame)
    bob.eval("ns.StrategyBoard:NewStrategy(...)", TERON)
    w.tick(0.2)
    assert bob.eval("return %s.mode3d:IsShown()" % W) is False
    said = [str(line) for line in bob.chat_frame[n0:] if "3D view" in str(line)]
    assert len(said) == 1 and "restart" in said[0].lower(), bob.chat_frame[n0:]
    bob.eval("ns.StrategyBoard:Refresh()")
    assert len([1 for line in bob.chat_frame[n0:] if "3D view" in str(line)]) == 1
    no_errors(w)


if __name__ == "__main__":
    run_all()

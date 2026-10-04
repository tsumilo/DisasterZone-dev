"""The strategy board's 3D view (UI/StrategyMap3D.lua on the shared Render3D/ module), on the real addon.

Covers: the rooms and their map fits (a board point and a room point are one spot: the starters' bosses land where
the server spawns them, on the room's own floor); the 2D / 3D switch (only for a boss with a room, greyed on a page
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

TERON = "BlackTemple:Teron"
VASHJ = "SerpentshrineCavern:Vashj"
W = "_G.DisasterZoneStrategyBoard"

HELPERS = r"""
T3 = { down = {} }
function T3.cv() return _G.DisasterZoneStrategyBoard.canvas end
function T3.v() return T3.cv().v3 end
function T3.page() return ns.StrategyBoard:GetState().strat.p[ns.StrategyBoard:GetState().page] end
function T3.elems() return T3.page().e end
-- the floor height and the screen point of a room point (the view's own measured camera)
function T3.ground(x, y) return T3.v():Ground(x, y) end
function T3.screen(x, y, up)
  local v = T3.v()
  return v.R.Project(x, y, v:Ground(x, y) + (up or 0))
end
-- the mouse at a screen point of the scene (the mock puts every frame at 0, 0)
function T3.cursor(sx, sy)
  local es = T3.v().view.scene:GetEffectiveScale() or 1
  _G.GetCursorPosition = function() return sx * es, sy * es end
end
function T3.at(x, y, up) local sx, sy = T3.screen(x, y, up) T3.cursor(sx, sy) return sx, sy end
_G.IsMouseButtonDown = function(b) return T3.down[b or "LeftButton"] == true end
function T3.press(b) T3.down[b] = true T3.cv():OnMouseDown(b) end
function T3.release(b) T3.down[b] = nil T3.cv():OnMouseUp(b) end
-- a drawing's spot in the room
function T3.room(e) local v = T3.v() return { ns.Render3D.BoardToRoom(v.room, T3.page(), e.x, e.y) } end
function T3.state() return T3.v():_State() end
"""


def boot(boss=TERON):
    w, c = world()
    bob = c["Bob"]
    bob.eval(HELPERS)
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
    assert bob.eval_py("return ns.Render3D.RoomForBoss(...).key", TERON) == "teron"
    assert bob.eval_py("return ns.Render3D.RoomForBoss(...).key", VASHJ) == "vashj"
    assert bob.eval_py("return ns.Render3D.RoomForBoss('BlackTemple:Council')") is None
    # board -> room -> board is exact
    rt = bob.eval_py("local r = ns.Render3D.RoomForBoss(...) local p = { vx = 390, vy = 220, vz = 280 } "
                     "local x, y = ns.Render3D.BoardToRoom(r, p, 123, 456) "
                     "local bx, by = ns.Render3D.RoomToBoard(r, p, x, y) return { bx, by }", TERON)
    assert abs(rt[0] - 123) < 1e-6 and abs(rt[1] - 456) < 1e-6, rt
    go3d(w, bob)
    # Teron's portrait on the starter lands within 5 yd of his spawn (room 29.9, 85.2), on the alcove's floor
    e = bob.eval_py("for _, e in ipairs(T3.elems()) do if e.t == 'i' then return e end end")
    xy = bob.eval_py("return T3.room(...)", e)
    assert math.hypot(xy[0] - 29.9, xy[1] - 85.2) < 5, xy
    z = bob.eval_py("return T3.ground(...)", xy[0], xy[1])
    assert abs(z + 6.23) < 0.6, z                      # (the alcove is 6.2 yd under the hall)
    no_errors(w)
    # Vashj's starter: within 3 yd of her spot in the middle of her room (105, 105)
    w2, c2, bob2 = boot(VASHJ)
    go3d(w2, bob2)
    e = bob2.eval_py("for _, e in ipairs(T3.elems()) do if e.t == 'i' then return e end end")
    xy = bob2.eval_py("return T3.room(...)", e)
    assert math.hypot(xy[0] - 105, xy[1] - 105) < 3, xy
    no_errors(w2)


@case
def the_switch_is_there_for_a_boss_with_a_room():
    w, c = world()
    bob = c["Bob"]
    bob.eval(HELPERS)
    sid = save_council(bob)
    w.tick(1)
    bob.eval("ns.StrategyBoard:OpenStrategy(..., 'edit')", sid)
    w.tick(0.2)
    assert bob.eval("return %s.mode3d:IsShown()" % W) is False          # Illidari Council: no room yet
    bob.eval("ns.StrategyBoard:NewStrategy(...)", TERON)
    w.tick(0.2)
    assert bob.eval("return %s.mode3d:IsShown() and %s.mode3d:IsEnabled()" % (W, W)) is True
    assert bob.eval("return %s.mode2d.kind" % W) == "chosen"
    # a page on another map: greyed out, saying which map the room is on
    bob.eval("T3.page().m = 0 ns.StrategyBoard:Refresh()")
    assert bob.eval("return %s.mode3d:IsShown()" % W) is True
    assert bob.eval("return %s.mode3d:IsEnabled()" % W) is False
    assert "Gorefiend's Vigil" in bob.eval("return %s.mode3d.tip" % W)
    no_errors(w)


@case
def the_map_tilts_up_into_the_room_and_back_down():
    w, c, bob = boot()
    bob.eval("ns.StrategyBoard:Set3D(true)")
    w.tick(0.05)
    st = bob.eval_py("return T3.state()")
    assert st["on"] is True and st["animating"] is True and st["room"] == "teron", st
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
    bob.eval("local e = T3.elems()[#T3.elems()] local bx, by = ns.Render3D.RoomToBoard(T3.v().room, T3.page(), 25, 30) "
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
    bob.eval("local bx, by = ns.Render3D.RoomToBoard(T3.v().room, T3.page(), 15, 40) "
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
    assert abs(o["x"] - 30) < 1e-6 and abs(o["y"] - 50) < 1e-6 and abs(o["dist"] - 78) < 1e-6, o
    no_errors(w)


@case
def view_from_here_and_my_spot():
    w, c, bob = boot()
    # a tank block and the tank's marker in the hall, an arrow from the entrance into the room
    bob.eval("local p = T3.page() p.k = { { id = 'tk', n = 'Tanks', r = 1, c = { { t = 'p', n = 'Tank' } } } } "
             "ns.StrategyBoard:MarkDirty(true)")
    go3d(w, bob)
    bob.eval("local r, p = T3.v().room, T3.page() "
             "local sx, sy = ns.Render3D.RoomToBoard(r, p, 30, 60) "
             "local ax, ay = ns.Render3D.RoomToBoard(r, p, 30, 5) local bx, by = ns.Render3D.RoomToBoard(r, p, 30, 40) "
             "table.insert(p.e, { t = 's', x = math.floor(sx + 0.5), y = math.floor(sy + 0.5), r = 'tk.1.1' }) "
             "table.insert(p.e, { t = 'a', x = math.floor(ax + 0.5), y = math.floor(ay + 0.5), x2 = math.floor(bx + 0.5), "
             "y2 = math.floor(by + 0.5), h = true, c = 4 }) T3.cv():Render()")
    tick(w, 0.2)
    # the marker: at eye height on its spot, facing Teron (north, down the steps)
    bob.eval("T3.cv():ViewFrom3D(T3.elems()[#T3.elems() - 1])")
    tick(w, 0.5)
    o = bob.eval_py("return T3.state().orb")
    teron = bob.eval_py("for _, e in ipairs(T3.elems()) do if e.t == 'i' then return T3.room(e) end end")
    assert abs(o["dist"] - 0.3) < 1e-6 and math.hypot(o["x"] - 30, o["y"] - 60) < 1, o
    want = math.atan2(teron[1] - o["y"], teron[0] - o["x"])
    assert abs((o["heading"] - want + math.pi) % (2 * math.pi) - math.pi) < 0.05, (o, want)
    # the arrow: from its start, looking along it (north)
    bob.eval("T3.cv():ViewFrom3D(T3.elems()[#T3.elems()])")
    tick(w, 0.5)
    o = bob.eval_py("return T3.state().orb")
    assert math.hypot(o["x"] - 30, o["y"] - 5) < 1 and abs(o["heading"] - math.pi / 2) < 0.05, o
    # My spot: shown when one of my slots has a marker on the page; it stands there
    assert bob.eval_py("return T3.state().mySpots") == 0
    bob.eval("T3.cv().opts.mySlots = function() return { ['tk.1.1'] = true } end T3.cv():Render()")
    w.tick(0.1)
    assert bob.eval("return T3.v().eyeBtn:IsShown()") is True
    bob.eval("T3.v().eyeBtn:Click()")
    tick(w, 0.5)
    o = bob.eval_py("return T3.state().orb")
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
    bob.eval("local i = T3.v().inset local bx, by = ns.Render3D.RoomToBoard(T3.v().room, T3.page(), 40, 30) "
             "i.Cursor = function() return bx, by end i.frame:GetScript('OnMouseDown')(i.frame, 'LeftButton') "
             "i.frame:GetScript('OnMouseUp')(i.frame, 'LeftButton')")
    tick(w, 0.5)
    o = bob.eval_py("return T3.state().orb")
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

"""The Portal: its hub, the World's End Tavern (2026-10-10).

Covers: the game opens in the tavern (its room, the follow camera looking south from the door, the regulars, the
stations: the portal, the Portal level pedestal, the Wanted board, the stash, the practice dummy); F at a station
opens its card and the prompt says what F would use; the pedestal sets the Portal level without starting the hub
again (you stay where you stand, the level is kept per character); walking away closes a card and Escape closes it
before it pauses; the board lists your best runs per level; your abilities on the dummy (it never falls) and its
damage a second on the job card; stepping into the portal asks the party (the AI members answer, F answers for you)
and everyone ready takes you into Hellfire Ramparts at the pedestal's level; Cancel steps you back out; the camera
turns with the right mouse button up to 60 degrees either way and the keys follow the screen.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_portal.py [-k name]
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors  # noqa: E402

import harness  # noqa: E402
harness.LOAD_ROOMS = True


def boot():
    w, c = solo("Alice", tick=2)
    c.slash("/dz play portal")
    w.tick(0.3)
    if not c.eval("return ns.PortalUI._View() ~= nil"):
        c.eval("ns.MainFrame:Open('games')")
        w.tick(0.3)
        c.eval("ns.GamesUI:Select('portal')")
    w.tick(0.5)
    tick(c, 3)
    return w, c


def tick(c, n=1, dt=0.05):
    c.eval("for _ = 1, %d do ns.PortalUI._Tick(%f) end" % (n, dt))


def put(c, x, y):
    c.eval("local p = ns.PortalUI._Sim().player p.x, p.y = %f, %f" % (x, y))


def S(c, expr):
    return c.eval_py("local s = ns.PortalUI._Sim() " + expr)


def unit(c, name):
    return S(c, "for _, u in ipairs(s.units) do if u.name == %r then return { x = u.x, y = u.y, kind = u.kind } end end"
             % name)


@case
def the_game_opens_in_the_tavern_with_its_stations_and_regulars():
    w, c = boot()
    assert S(c, "return s.enc.id") == "hub"
    assert S(c, "return s.enc.name") == "The World's End Tavern"
    assert S(c, "return s.enc.arena.mesh ~= nil"), "the tavern's room is loaded"
    cam = S(c, "return s.enc.camera")
    assert abs(cam["yaw"] + math.pi / 2) < 1e-6 and abs(cam["turn"] - math.pi / 3) < 1e-6, cam
    for name in ("Portal", "Portal level", "Wanted board", "Stash", "Practice Dummy", "Shaarubo", "Kylene",
                 "Haris Pilton", "Tank", "Healer"):
        assert unit(c, name), name
    st = c.eval_py("return ns.PortalUI._State()")
    assert st["is3D"] and st["state"] == "run", st
    no_errors(w)


@case
def f_at_the_pedestal_opens_the_level_card_and_sets_the_level_where_you_stand():
    w, c = boot()
    ped = unit(c, "Portal level")
    put(c, ped["x"] - 2, ped["y"] + 1)
    tick(c)
    assert c.eval_py("return ns.PortalUI._Prompt()") == "|cffffd100F|r  Set Portal level"
    first = S(c, "return tostring(s)")
    c.eval("ns.PortalUI._Key('F')")
    tick(c)
    card = c.eval_py("return ns.PortalUI._Card()")
    assert card and card["title"] == "Portal level", card
    assert [b["text"] for b in card["buttons"]] == ["> Portal level 0", "Portal level 5", "Portal level 10"], card
    assert card["buttons"][0]["enabled"] is False and card["buttons"][1]["enabled"] is True, card
    assert c.eval_py("return ns.PortalUI._Prompt()") is False            # (no prompt over an open card)
    pos = S(c, "return { s.player.x, s.player.y }")
    c.eval("ns.PortalUI._CardClick(2)")
    tick(c)
    assert S(c, "return s.diff.id") == "p5"
    assert S(c, "return tostring(s)") == first, "the hub goes on: not started again"
    assert S(c, "return { s.player.x, s.player.y }") == pos
    assert c.eval_py("return ns.Games:GetData('portal').diff.hub") == "p5"
    card = c.eval_py("return ns.PortalUI._Card()")
    assert card["buttons"][1]["text"] == "> Portal level 5" and card["buttons"][1]["enabled"] is False, card
    no_errors(w)


@case
def walking_away_closes_a_card_and_escape_closes_it_before_pausing():
    w, c = boot()
    board = unit(c, "Wanted board")
    put(c, board["x"] + 1.5, board["y"] + 1.5)
    tick(c)
    c.eval("ns.PortalUI._Key('F')")
    tick(c)
    card = c.eval_py("return ns.PortalUI._Card()")
    assert card and card["title"] == "Wanted: your best runs", card
    assert "Portal level 0:" in card["body"] and "no clear yet" in card["body"], card
    put(c, board["x"] + 12, board["y"] + 12)
    tick(c, 2)
    assert c.eval_py("return ns.PortalUI._Card()") is False
    # Escape: the card first, then the pause
    stash = unit(c, "Stash")
    put(c, stash["x"] + 1.5, stash["y"])
    tick(c)
    c.eval("ns.PortalUI._Key('F')")
    tick(c)
    assert c.eval_py("return ns.PortalUI._Card()")["title"] == "Stash"
    c.eval("ns.PortalUI._Esc()")
    tick(c)
    assert c.eval_py("return ns.PortalUI._Card()") is False
    assert c.eval_py("return ns.PortalUI._State()")["paused"] is False
    c.eval("ns.PortalUI._Esc()")
    tick(c)
    assert c.eval_py("return ns.PortalUI._State()")["paused"] is True
    no_errors(w)


@case
def your_abilities_on_the_practice_dummy_and_its_damage_a_second():
    w, c = boot()
    d = unit(c, "Practice Dummy")
    put(c, d["x"], d["y"] + 2.5)
    c.eval("local s = ns.PortalUI._Sim() for _, u in ipairs(s.units) do if u.dummy then s:SetTarget(u) end end")
    tick(c)
    c.eval("ns.PortalUI._Key('1')")
    tick(c, 40)
    c.eval("ns.PortalUI._Key('2')")
    tick(c, 20)
    hp = S(c, "for _, u in ipairs(s.units) do if u.dummy then return { u.hp, u.hpMax, u.dead or false } end end")
    assert hp[0] == hp[1] and hp[2] is False, hp                            # it never falls
    status = S(c, "return s.status and s.status[1] or false")
    assert status and status.startswith("Practice Dummy: ") and "damage a second" in status, status
    total = S(c, "return s.meter.total")
    assert total >= 650 + 380, total                                       # Heroic Strike + Cleave at least
    no_errors(w)


@case
def the_portal_asks_the_party_and_everyone_ready_goes_into_the_dungeon_at_the_level():
    w, c = boot()
    ped = unit(c, "Portal level")
    put(c, ped["x"] - 2, ped["y"] + 1)
    tick(c)
    c.eval("ns.PortalUI._Key('F')")
    tick(c)
    c.eval("ns.PortalUI._CardClick(3)")                                     # Portal level 10
    tick(c)
    portal = unit(c, "Portal")
    put(c, portal["x"], portal["y"])
    tick(c)
    card = c.eval_py("return ns.PortalUI._Card()")
    assert card and card["title"] == "Ready check", card
    assert "Portal level 10" in card["body"] and "Waiting|r   You" in card["body"], card
    tick(c, 50)                                                            # the AI members answer
    card = c.eval_py("return ns.PortalUI._Card()")
    assert "Ready|r   Tank" in card["body"] and "Ready|r   Healer" in card["body"], card
    assert S(c, "return s.enc.id") == "hub", "not before you are ready"
    c.eval("ns.PortalUI._Key('F')")                                       # F answers for you
    tick(c, 2)
    assert S(c, "return s.enc.id") == "ramparts"
    assert S(c, "return s.diff.id") == "p10"
    no_errors(w)


@case
def cancel_steps_you_back_out_of_the_portal():
    w, c = boot()
    portal = unit(c, "Portal")
    put(c, portal["x"], portal["y"])
    tick(c)
    assert c.eval_py("return ns.PortalUI._Card()")["title"] == "Ready check"
    c.eval("ns.PortalUI._CardClick(2)")
    tick(c)
    assert c.eval_py("return ns.PortalUI._Card()") is False
    p = S(c, "return { s.player.x, s.player.y }")
    assert math.hypot(p[0] - portal["x"], p[1] - portal["y"]) > 2.5, p
    tick(c, 60)
    assert S(c, "return s.enc.id") == "hub"
    no_errors(w)


@case
def the_camera_turns_with_the_mouse_up_to_60_degrees_and_the_keys_follow_the_screen():
    w, c = boot()
    c.eval("__CX = 960 GetCursorPosition = function() return __CX, 540 end")
    c.eval("ns.PortalUI._Mouse(true, false)")
    tick(c)                                                                # (the drag's first frame: where it starts)
    c.eval("ns.PortalUI._Camera().yawOff = 0")
    c.eval("__CX = 960 - 100")                                            # 100 px left: turned by 0.6
    tick(c)
    off = c.eval_py("return ns.PortalUI._Camera().yawOff")
    assert abs(off - 0.6) < 1e-6, off
    c.eval("__CX = 960 - 600")                                            # far left: no more than 60 degrees
    tick(c)
    assert abs(c.eval_py("return ns.PortalUI._Camera().yawOff") - math.pi / 3) < 1e-6
    c.eval("__CX = 960 + 2000")                                           # far right: the other way, as far
    tick(c)
    assert abs(c.eval_py("return ns.PortalUI._Camera().yawOff") + math.pi / 3) < 1e-6
    c.eval("ns.PortalUI._Mouse(false, false)")
    # W runs up the screen: with the camera turned, along the turned view
    c.eval("ns.PortalUI._Camera().yawOff = 0.5")
    put(c, 33, 47)
    c.eval("ns.PortalUI._Key('W', true)")
    tick(c, 10)
    c.eval("ns.PortalUI._Key('W', false)")
    p = S(c, "return { s.player.x, s.player.y }")
    ang = math.atan2(p[1] - 47, p[0] - 33)
    assert abs(ang - (-math.pi / 2 + 0.5)) < 0.15, (p, ang)
    no_errors(w)


if __name__ == "__main__":
    run_all(sys.argv)

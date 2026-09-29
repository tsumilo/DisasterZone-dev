"""Azeromon: list menus fit the screen.

Covers: every long list (Bestiary, Achievements, Guild Bestiary, Bag) stays inside the screen and above the
description box, scrolls to keep the cursor in view (keys and mouse wheel) with the up/down markers, reaches the last
item, keeps icon sizes when a pooled frame is reused, and the Bestiary list does not overlap its info panel.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_menus.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def game(seed=7):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    c.eval("ns.Azero:NewGame()")
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('owlet', 3, ns.Azero.rng), 'caught')")
    c.slash("/cdl play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")                    # title: CONTINUE
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    return w, c


def key(w, c, *keys):
    for k in keys:
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.05)


def layout(c):
    return c.eval_py("return ns.AzeroUI._MenuLayout()")


def check_fits(L, name):
    """The menu is inside the screen and above the description box; every visible row is inside the menu."""
    top = -L["y"]
    bottom = top + L["h"]
    limit = L["SH"] - L["desc"]
    assert L["x"] >= 0 and L["x"] + L["w"] <= L["SW"], (name, L)
    assert bottom <= limit, (name, "menu bottom %d past %d" % (bottom, limit), L)
    for r in L["rows"]:
        assert -r["y"] + r["h"] <= L["h"] - 10, (name, "row past the menu", r, L)
        assert r["x"] + r["w"] <= L["w"] - 10, (name, "row past the right edge", r, L)
    shown = [r["idx"] for r in L["rows"]]
    assert L["cursor"] in shown, (name, "cursor scrolled out of view", L)
    assert shown == list(range(L["first"], L["first"] + len(shown))), (name, shown)


def scroll_through(w, c, name):
    """Walk to the last item: the list scrolls, the markers follow, every step fits."""
    L = layout(c)
    n = L["n"]
    assert L["per"] < n, (name, "expected a list that needs scrolling", L)
    assert L["up"] is False and L["down"] is True, (name, L)
    check_fits(L, name)
    for _ in range(n - 1):
        key(w, c, "down")
        check_fits(layout(c), name)
    L = layout(c)
    assert L["cursor"] == n and L["rows"][-1]["idx"] == n, (name, L)
    assert L["up"] is True and L["down"] is False, (name, L)
    # the mouse wheel scrolls back up
    for _ in range(n):
        c.eval("ns.AzeroUI._Wheel(1)")
    L = layout(c)
    assert L["cursor"] == 1 and L["first"] == 1 and L["up"] is False, (name, L)


@case
def bestiary_scrolls_and_leaves_room_for_its_panel():
    w, c = game()
    key(w, c, "START", "A")                                  # BESTIARY
    L = layout(c)
    assert L["x"] + L["w"] <= L["SW"] - 8 - L["log"], ("the list overlaps the info panel", L)
    scroll_through(w, c, "bestiary")
    no_errors(w)


@case
def achievements_scroll_above_the_description_box():
    w, c = game()
    key(w, c, "START", "down", "down", "down", "A")          # ACHIEVEMENTS
    assert layout(c)["desc"] > 0
    scroll_through(w, c, "achievements")
    no_errors(w)


@case
def guild_bestiary_scrolls_above_the_description_box():
    w, c = game()
    key(w, c, "START", "down", "down", "down", "down", "A")  # GUILD
    n = c.eval("return ns.AzeroUI._MenuLayout().n")
    opened = False
    for _ in range(n):                                        # try each Guild entry until the Guild Bestiary opens
        key(w, c, "A")
        t = c.eval_py("local l = ns.AzeroUI._Levels() return l[#l].title")
        if t == "GUILD BESTIARY":
            opened = True
            break
        key(w, c, "B", "down")
    assert opened
    scroll_through(w, c, "guild bestiary")
    no_errors(w)


@case
def a_full_bag_scrolls_and_icons_keep_their_size():
    w, c = game()
    c.eval("""local G = ns.Azero
      for id, def in pairs(ns.AzeroData.items) do G.save.bag[id] = 3 end""")
    key(w, c, "START", "down", "down", "A")                  # BAG
    L = layout(c)
    if L["per"] < L["n"]:
        scroll_through(w, c, "bag")
    else:
        check_fits(L, "bag")
    icons = {r["icon"] for r in layout(c)["rows"] if r["icon"]}
    assert icons == {30}, icons                               # rowH 36 - 6
    key(w, c, "B", "B")
    # the Bestiary reuses the pooled frame: its rows have no icons, the bag's again 30 when reopened
    key(w, c, "START", "A")
    assert all(r["icon"] == 0 for r in layout(c)["rows"])
    key(w, c, "B", "START", "down", "down", "A")
    assert {r["icon"] for r in layout(c)["rows"] if r["icon"]} == {30}
    no_errors(w)


@case
def short_menus_do_not_scroll():
    w, c = game()
    key(w, c, "START")
    L = layout(c)
    assert L["per"] == L["n"] and L["up"] is False and L["down"] is False, L
    check_fits(L, "start")
    no_errors(w)


@case
def the_game_fills_the_space_it_is_given():
    w, c = game()
    r = c.eval_py("""local UI = ns.AzeroUI
      return { wide = UI._Fit(1356, 1205), tall = UI._Fit(600, 1400), small = UI._Fit(264, 216), huge = UI._Fit(2112, 1728) }""")
    assert abs(r["wide"] - 1356 / 528) < 1e-6, r          # limited by the width: never stretched
    assert abs(r["tall"] - 600 / 528) < 1e-6, r
    assert abs(r["small"] - 0.5) < 1e-6 and abs(r["huge"] - 4) < 1e-6, r
    no_errors(w)


if __name__ == "__main__":
    run_all()

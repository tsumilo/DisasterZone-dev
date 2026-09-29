"""Azeromon: learning the controls.

Covers: the key strip (the keys for walking, menus and text; it fades after the situation changes and comes back
when the player idles; a key drops out once learned; under the game when there's room, else over its top edge);
the one-time tips (walk, menu, back, run), shown once each and never during menus; the CONTROLS page from the
start menu and the title screen (and bringing the hints back); a right-click going back.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_keys.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def game(seed=7, tips=False):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    c.eval("ns.Azero:NewGame()")
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('owlet', 3, ns.Azero.rng), 'caught')")
    c.eval("ns.Azero:Data().keys = {} ns.Azero:Data().tips = {}")
    c.slash("/cdl play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")                    # title: CONTINUE
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    c.eval("ns.AzeroUI.tipsOff = %s" % ("false" if tips else "true"))
    c.eval("ns.AzeroUI._Focus(true)")
    w.tick(0.1)
    return w, c


def key(w, c, *keys):
    for k in keys:
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.05)


def dismiss(w, c):
    """Space until the message is gone (the first press finishes the text, the next closes it)."""
    for _ in range(6):
        if not c.eval_py("return ns.AzeroUI._State()")["msg"]:
            return
        key(w, c, "A")
        w.tick(0.1)


def strip(c):
    return c.eval_py("return ns.AzeroUI._KeyStrip()")


def title(c):
    lv = c.eval_py("return ns.AzeroUI._Levels()") or []
    return lv[-1]["title"] if lv else None


@case
def the_key_strip_shows_what_matters_then_fades_and_learns():
    w, c = game()
    s = strip(c)
    assert s and s["keys"] == ["Arrows Walk", "Space Talk", "Enter Menu", "X Run (hold)"], s
    key(w, c, "START")
    assert strip(c)["keys"] == ["Space Select", "X Back"]
    w.tick(7.5)                                               # 6 s shown, 1 s fading
    assert strip(c) is None
    w.tick(5)                                                 # 12 s without a key: a reminder
    assert strip(c)["keys"] == ["Space Select", "X Back"]
    c.eval("ns.Azero:Data().keys.select = 5")                 # used Space five times in menus: learned
    key(w, c, "B", "START")
    assert strip(c)["keys"] == ["X Back"]
    c.eval("ns.Azero:Data().keys.back = 5")
    w.tick(0.1)
    assert strip(c) is None                                   # nothing left to teach here
    no_errors(w)


@case
def the_strip_sits_under_the_game_when_there_is_room():
    w, c = game()
    c.eval("ns.AzeroUI._Fit(1356, 1205)")                     # taller than the game: a bar below it
    assert c.eval("return ns.AzeroUI._Outside()") is True
    c.eval("ns.AzeroUI._Fit(1356, 1109)")                     # no room: over the top edge
    assert c.eval("return ns.AzeroUI._Outside()") is False
    no_errors(w)


@case
def one_time_tips_at_the_right_moments():
    w, c = game(tips=True)
    w.tick(0.2)
    st = c.eval_py("return ns.AzeroUI._State()")
    assert st["msg"] and st["text"].startswith("walk with the arrow keys"), st      # under a "Tip" name tab
    dismiss(w, c)
    w.tick(0.2)
    c.eval("ns.Azero:SetFlag('starter', 'murkling')")         # after the starter: the menu
    w.tick(0.2)
    st = c.eval_py("return ns.AzeroUI._State()")
    assert st["msg"] and st["text"].startswith("press Enter"), st
    dismiss(w, c)
    w.tick(0.2)
    key(w, c, "START")                                        # the first menu: how to go back, then the menu
    st = c.eval_py("return ns.AzeroUI._State()")
    assert st["msg"] and "goes back" in st["text"] and st["stack"] == 0, st
    dismiss(w, c)
    assert c.eval_py("return ns.AzeroUI._State()")["stack"] == 1
    key(w, c, "B")
    c.eval("ns.Azero.save.steps = 60")                        # walked a while: running
    w.tick(0.2)
    st = c.eval_py("return ns.AzeroUI._State()")
    assert st["msg"] and st["text"] == "hold X while you walk to run.", st
    dismiss(w, c)
    w.tick(0.5)
    key(w, c, "START")                                        # each tip only once
    st = c.eval_py("return ns.AzeroUI._State()")
    assert not st["msg"] and st["stack"] == 1, st
    no_errors(w)


@case
def the_controls_page_from_the_menu_and_the_title():
    w, c = game()
    key(w, c, "START", "down", "down", "down", "down", "down", "down", "down", "down", "down", "A")
    assert title(c) == "CONTROLS", title(c)
    items = c.eval_py("return ns.AzeroUI._MenuItems()")
    assert "Back, cancel" in items and items[-1] == "Show the key hints again", items
    c.eval("ns.Azero:Data().keys = { select = 9, back = 9 }")
    for _ in range(len(items) - 1):
        key(w, c, "down")
    key(w, c, "A")
    assert c.eval_py("return ns.AzeroUI._MenuItems()")[-1] == "Key hints will show again"
    assert c.eval("return next(ns.Azero:Data().keys) == nil")
    key(w, c, "B", "B")
    no_errors(w)
    # the title screen has it too
    w2, c2 = solo("Bob", tick=2)
    c2.eval(BOT)
    c2.slash("/cdl play azeromon")
    w2.tick(0.3)
    items = c2.eval_py("return ns.AzeroUI._MenuItems()")
    assert items[-1] == "CONTROLS", items
    for _ in range(len(items) - 1):
        key(w2, c2, "down")
    key(w2, c2, "A")
    assert title(c2) == "CONTROLS"
    no_errors(w2)


@case
def the_class_perk_in_the_menu_and_a_tip_per_class():
    w, c = game()
    c.eval("ns.Azero:Data().tips.walk = true ns.Azero.classOverride = 'HUNTER' ns.AzeroUI.tipsOff = false")
    w.tick(0.2)
    st = c.eval_py("return ns.AzeroUI._State()")
    assert st["msg"] and "Hunter, Tame Beast: Hunters tame beasts 25% more easily." in " ".join(st["text"].split()), st
    dismiss(w, c)
    c.eval("ns.Azero:Data().tips.back = true")
    key(w, c, "START")
    w.tick(0.1)
    assert c.eval("return ns.AzeroUI._PerkLine()") == "Hunter: Tame Beast"
    key(w, c, "B")
    c.eval("ns.Azero.classOverride = 'MAGE'")                   # an alt of another class learns its own
    w.tick(0.2)
    st = c.eval_py("return ns.AzeroUI._State()")
    assert st["msg"] and "Mage, Arcane Intellect" in " ".join(st["text"].split()), st
    dismiss(w, c)
    c.eval("ns.Azero.classOverride = 'HUNTER'")                  # but only once per class
    w.tick(0.3)
    assert not c.eval_py("return ns.AzeroUI._State()")["msg"]
    no_errors(w)


@case
def the_type_chart_from_the_menu():
    w, c = game()
    key(w, c, "START", "down", "down", "down", "down", "down", "down", "down", "down", "A")
    assert c.eval("return ns.AzeroUI._TypeChart()") is True
    key(w, c, "B")
    assert c.eval("return ns.AzeroUI._TypeChart()") is False
    assert c.eval_py("return ns.AzeroUI._State()")["stack"] == 1          # back in the start menu
    no_errors(w)


@case
def whats_new_on_the_title_screen():
    w, c = solo("Carol", tick=2)
    c.eval(BOT)
    c.slash("/cdl play azeromon")
    w.tick(0.3)
    items = c.eval_py("return ns.AzeroUI._MenuItems()")
    assert "WHAT'S NEW" in items and c.eval("return ns.AzeroUI._ChangelogUnseen()") is True, items
    for _ in range(items.index("WHAT'S NEW")):
        key(w, c, "down")
    key(w, c, "A")
    page = c.eval_py("return ns.AzeroUI._Changelog()")
    n = c.eval("return #ns.AzeroChangelog")
    first = c.eval("return ns.AzeroChangelog[1].version")
    assert page["page"] == "1 / %d" % n and page["head"].startswith("v" + first), page
    assert page["body"].startswith("-  "), page
    key(w, c, "right")
    assert c.eval_py("return ns.AzeroUI._Changelog()")["page"] == "2 / %d" % n
    key(w, c, "left", "left")                                    # can't go past the newest
    assert c.eval_py("return ns.AzeroUI._Changelog()")["page"] == "1 / %d" % n
    key(w, c, "B")
    assert c.eval("return ns.AzeroUI._Changelog()") is None
    assert c.eval("return ns.AzeroUI._ChangelogUnseen()") is False      # read: no more "new"
    no_errors(w)


@case
def changelog_entries_are_well_formed():
    w, c = solo("Dave", tick=2)
    bad = c.eval_py("""local bad = {}
      for i, r in ipairs(ns.AzeroChangelog) do
        if type(r.version) ~= 'string' or type(r.date) ~= 'string' or type(r.lines) ~= 'table' or #r.lines == 0 then
          bad[#bad + 1] = 'entry ' .. i
        end
        for _, line in ipairs(r.lines or {}) do
          if #line > 64 then bad[#bad + 1] = 'too long: ' .. line end
        end
        if #(r.lines or {}) > 11 then bad[#bad + 1] = 'more than a page (11 lines): ' .. tostring(r.version) end
      end
      return bad""")
    assert bad == [], bad
    no_errors(w)


@case
def a_right_click_goes_back():
    w, c = game()
    key(w, c, "START")
    assert c.eval_py("return ns.AzeroUI._State()")["stack"] == 1
    c.eval("ns.AzeroUI._RightClick('row')")
    assert c.eval_py("return ns.AzeroUI._State()")["stack"] == 0
    key(w, c, "START")
    c.eval("ns.AzeroUI._RightClick('box')")
    assert c.eval_py("return ns.AzeroUI._State()")["stack"] == 0
    no_errors(w)


if __name__ == "__main__":
    run_all()

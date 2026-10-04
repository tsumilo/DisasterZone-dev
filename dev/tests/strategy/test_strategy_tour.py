"""The strategy board's tutorial (UI/Tour.lua, Data/Tours/Strategy.lua): a guided tour on a practice board that is
never a draft, never saved and never shared. Every step must point at a control that exists, the steps the member
does themselves must notice the real action, and the finished chapters are remembered.

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_strategy_tour.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import world, strategies  # noqa: E402
from _common import case, run_all  # noqa: E402

BOSS = "GruulsLair:Maulgar"
W = "_G.DisasterZoneStrategyBoard"
B = "ns.StrategyBoard"
ST = B + ":GetState()"
T = "ns.Tour"
P = "ns.RaidsUI:GetPanel()"

HELPERS = """
function T_pg() local s = ns.StrategyBoard:GetState(); return s.strat.p[s.page] end
function T_canvas() return _G.DisasterZoneStrategyBoard.canvas end
function T_changed() T_canvas():Changed() end
function T_add_rotation()
    local k = ns.StrategyBlocksUI.TEMPLATES[2].make()
    k.id = ns.Strategy:NewPartId(ns.StrategyBoard:GetState().strat, "k")
    table.insert(T_pg().k, k)
    T_changed()
    return k.id
end
function T_empty_slot()
    local s = ns.StrategyBoard:GetState()
    for _, sl in ipairs(ns.Strategy:GetSlots(s.strat)) do
        if not s.assign[sl.ref] then return sl.ref end
    end
end
function T_names()
    local s, n, mine = ns.StrategyBoard:GetState(), 0, 0
    for _, key in pairs(s.assign) do
        n = n + 1
        if key == ns.Util.PlayerKey() then mine = mine + 1 end
    end
    return { n = n, mine = mine, slots = #ns.Strategy:GetSlots(s.strat) }
end
"""

CHAPTERS = ["basics", "drawing", "jobs", "helpers", "assign", "read", "library"]


def setup():
    w, c = world()
    bob = c["Bob"]
    bob.eval(HELPERS)
    return w, c, bob


def state(cl):
    return cl.eval_py("return %s:GetState()" % T)


def tick(w, cl, seconds=0.0):
    """One look of the tour at the board (its OnUpdate), after `seconds` of game time."""
    if seconds:
        w.tick(seconds)
    cl.eval("%s:Tick()" % T)


def did(w, cl):
    """The step notices what was just done, says so, and the tour goes on."""
    before = state(cl)
    tick(w, cl)
    s = state(cl)
    assert s and s["done"] is True, (before, s)
    tick(w, cl, 1.0)
    return state(cl)


def ndrafts(cl):
    return cl.eval("local n = 0; for _ in pairs(ns.db.strategyDraft[ns.Util.PlayerKey()] or {}) do n = n + 1 end; "
                   "return n")


def start(w, cl, chapter=None):
    assert cl.eval("return %s:Start('strategy', ...)" % T, chapter) is True
    w.tick(0.2)


# ------------------------------------------------------------------------------------------------------------------
@case
def the_tour_runs_on_a_practice_board_that_is_never_saved():
    w, c, bob = setup()
    start(w, bob)
    s = state(bob)
    assert (s["id"], s["chapter"], s["si"]) == ("strategy", "basics", 1), s
    st = bob.eval_py("local s = %s; return { mode = s.mode, sandbox = s.sandbox, b = s.strat.b, id = s.strat.id, "
                     "n = #s.strat.p[1].e }" % ST)
    assert st == {"mode": "edit", "sandbox": True, "b": BOSS, "n": 5}, st
    assert bob.eval("return %s:IsShown()" % B) is True
    # changes never become a draft
    bob.eval("T_canvas():Place({ t = 'i', x = 500, y = 300, i = 'rt1', z = 32 })")
    w.tick(0.2)
    assert bob.eval("return %s.dirty" % ST) is True
    assert ndrafts(bob) == 0
    assert bob.eval("return %s:HasDraft()" % B) is False
    # Save saves nothing and says why
    n0 = len(bob.chat_frame)
    bob.click(bob.eval("return %s.saveBtn" % W))
    w.tick(1)
    assert any("practice board" in p for p in bob.chat_frame[n0:]), bob.chat_frame[n0:]
    assert not strategies(bob, BOSS)
    assert bob.eval("return %s.sandbox" % ST) is True
    # nothing of it went to the guild
    rita = c["Rita"]
    assert not strategies(rita, BOSS)
    bob.relog()
    w.tick(1)
    assert bob.eval("return %s:HasDraft()" % B) is False
    assert state(bob) is None
    w.assert_no_errors()


@case
def unsaved_work_on_the_board_stays_a_draft_when_the_tour_starts():
    w, c, bob = setup()
    bob.eval(B + ":NewStrategy(...)", "BlackTemple:Council", "Mine")
    w.tick(0.2)
    assert ndrafts(bob) == 1
    start(w, bob)
    assert bob.eval("return %s.sandbox" % ST) is True
    assert ndrafts(bob) == 1
    # going back to the draft leaves the practice board behind and ends the tour
    assert bob.eval("return %s:OpenDraft()" % B) is True
    w.tick(0.2)
    tick(w, bob)
    assert state(bob) is None
    st = bob.eval_py("local s = %s; return { n = s.strat.n, sandbox = s.sandbox }" % ST)
    assert st == {"n": "Mine"}, st
    w.assert_no_errors()


@case
def closing_the_board_ends_the_tour():
    w, c, bob = setup()
    start(w, bob)
    bob.eval(B + ":Close()")
    tick(w, bob)
    assert state(bob) is None
    assert bob.eval("return _G.DisasterZoneTour:IsShown()") is False
    # Cancel closes the practice board too
    start(w, bob)
    bob.click(bob.eval("return %s.cancelBtn" % W))
    w.tick(0.2)
    assert bob.eval("return %s:IsShown()" % B) is False
    tick(w, bob)
    assert state(bob) is None
    w.assert_no_errors()


@case
def every_step_points_at_a_control_on_the_screen():
    w, c, bob = setup()
    start(w, bob)
    seen = []
    modes = {}
    for _ in range(120):
        s = state(bob)
        if s is None:
            break
        seen.append((s["chapter"], s["si"]))
        modes.setdefault(s["chapter"], bob.eval("return %s:IsShown() and %s.mode" % (B, ST)))
        if s["anchored"]:
            assert s["lit"] is True, "nothing to point at: %r" % (s,)
        # the texts are there
        txt = bob.eval_py("local b = _G.DisasterZoneTourBox; return { t = b.title:GetText(), x = b.text:GetText() }")
        assert txt["t"] and txt["x"], (s, txt)
        if s["chapter"] == "jobs" and s["si"] == 1:
            # the later steps point into a block: add the first suggested one
            bob.eval("%s.blocks.cards[1].onPick()" % W)
            w.tick(0.2)
        if s["chapter"] == "helpers" and s["si"] == 2:
            bob.eval("T_add_rotation()")        # the steps after it point at the rotation
            w.tick(0.2)
        bob.click(bob.eval("return _G.DisasterZoneTourBox.next"))
        w.tick(0.1)
    assert state(bob) is None
    n = bob.eval_py("local out = {}; for i, ch in ipairs(%s:Get('strategy').chapters) do out[i] = #ch.steps end; "
                    "return out" % T)
    # one page only (the step that adds one was skipped): the step about the page tabs is left out
    assert ("read", 5) not in seen
    assert len(seen) == sum(n) - 1, (len(seen), n)
    done = bob.eval_py("return %s:Progress('strategy').done" % T)
    assert done == {k: True for k in CHAPTERS}, done
    assert [c for c, _ in seen if c] and sorted(set(c for c, _ in seen), key=CHAPTERS.index) == CHAPTERS
    # each chapter had the board the way it needs it; the last one runs on the library
    assert modes == {"basics": "edit", "drawing": "edit", "jobs": "edit", "helpers": "edit", "assign": "fill",
                     "read": "view", "library": False}, modes
    assert any("Tutorial finished" in p for p in bob.chat_frame), bob.chat_frame[-3:]
    assert ndrafts(bob) == 0
    assert not strategies(bob, BOSS)
    w.assert_no_errors()


@case
def the_steps_notice_the_real_actions():
    w, c, bob = setup()
    start(w, bob)
    nxt = lambda: (bob.click(bob.eval("return _G.DisasterZoneTourBox.next")), w.tick(0.1))  # noqa: E731
    for _ in range(3):
        nxt()                                   # welcome, the map, the jobs
    s = state(bob)
    assert (s["si"], s["interactive"], s["done"]) == (4, True, False), s
    # nothing done yet: the tour waits
    tick(w, bob, 2.0)
    assert state(bob)["si"] == 4
    assert bob.eval("return _G.DisasterZoneTourBox.next:GetText()") == "Skip step"
    bob.eval("T_pg().vz = T_pg().vz + 40; T_changed()")                         # zoom
    assert did(w, bob)["si"] == 5
    bob.click(bob.eval("return %s.tools.btns[2]" % W))                          # the hand tool
    assert did(w, bob)["si"] == 6
    bob.eval("T_pg().vx = T_pg().vx + 25; T_changed()")                         # pan
    assert did(w, bob)["si"] == 7
    nxt()                                                                       # the map menu
    bob.click(bob.eval("return %s.addPage" % W))
    assert did(w, bob)["si"] == 9
    assert bob.eval("return %s.page" % ST) == 2
    bob.click(bob.eval("return %s.tabs[1]" % W))
    s = did(w, bob)
    assert (s["chapter"], s["si"]) == ("drawing", 1), s
    assert bob.eval_py("return %s:Progress('strategy').done" % T) == {"basics": True}

    # drawing
    bob.click(bob.eval("return %s.tools.btns[3]" % W))                          # the circle tool
    assert did(w, bob)["si"] == 2
    bob.eval("T_canvas():Place({ t = 'z', s = 'c', x = 300, y = 480, w = 100, h = 100, c = 1 })")
    assert did(w, bob)["si"] == 3
    bob.click(bob.eval("return %s.tools.swatches[4]" % W))                      # a colour
    assert did(w, bob)["si"] == 4
    assert bob.eval("return T_canvas():GetSelected().c") == 4
    bob.eval("local e = T_canvas():GetSelected(); e.x = e.x + 30; T_changed()")  # moved
    assert did(w, bob)["si"] == 5
    bob.eval("T_canvas():GetSelected().l = 'Melee'; T_changed()")               # labelled
    assert did(w, bob)["si"] == 6
    bob.eval("T_canvas():Place({ t = 'i', x = 700, y = 500, i = 'rt1', z = 32 })")
    assert did(w, bob)["si"] == 7
    bob.eval("T_canvas():SelectAll()")                                          # several selected
    assert did(w, bob)["si"] == 8
    n = bob.eval("return #T_pg().e")
    bob.click(bob.eval("return %s.tools.undoBtn" % W))                          # undo
    assert bob.eval("return #T_pg().e") == n - 1
    assert did(w, bob)["si"] == 9
    nxt()
    s = state(bob)
    assert (s["chapter"], s["si"]) == ("jobs", 1), s

    # jobs
    bob.click(bob.eval("return %s.blocks.cards[1]" % W))                        # a suggested block
    assert did(w, bob)["si"] == 2
    nxt()
    bob.eval("T_pg().k[1].c[1].f = 'tank'; T_changed()")                        # who fits the slot
    assert did(w, bob)["si"] == 4
    nxt()
    s = state(bob)
    assert s["si"] == 5 and s["lit"] is True, s
    n = bob.eval("return #T_pg().e")
    bob.eval("local c = T_canvas(); for _, e in ipairs(T_pg().e) do if e.t == 'z' then "
             "c:LinkList({ e }, T_pg().k[1].id .. '.1.1') end end")            # the zone linked to a slot
    assert did(w, bob)["si"] == 6
    assert bob.eval("return #T_pg().e") == n        # there was something to link: nothing was added
    for _ in range(5):
        nxt()
    s = state(bob)
    assert (s["chapter"], s["si"]) == ("helpers", 1), s
    assert bob.eval_py("return %s:Progress('strategy').done" % T) == {"basics": True, "drawing": True, "jobs": True}

    # in-fight helpers
    nxt()
    rot = bob.eval("return T_add_rotation()")                                   # a rotation block
    assert did(w, bob)["si"] == 3
    bob.eval("for _, k in ipairs(T_pg().k) do if k.id == ... then k.tr = 'rot' end end; T_changed()", rot)
    assert did(w, bob)["si"] == 4
    for _ in range(4):
        nxt()

    # assigning the demo raid: the same board, now with players
    s = state(bob)
    assert (s["chapter"], s["si"]) == ("assign", 1), s
    st = bob.eval_py("local s = %s; return { mode = s.mode, sandbox = s.sandbox, occ = s.occ }" % ST)
    assert st == {"mode": "fill", "sandbox": True, "occ": "sandbox"}, st
    chips = bob.eval_py("local out = {}; for _, c in ipairs(%s.pool.chips) do if c:IsShown() then "
                        "out[#out + 1] = c.key end end; return out" % W)
    me = bob.eval("return ns.Util.PlayerKey()")
    assert len(chips) == 10 and me in chips, chips
    nxt()
    nxt()
    other = [k for k in chips if k != me][0]
    bob.eval("%s:Assign(T_empty_slot(), ...)" % B, other)                       # a player in a slot
    assert did(w, bob)["si"] == 4
    before = bob.eval_py("return T_names()")
    bob.click(bob.eval("return %s.pool.suggestBtn" % W))                        # Suggest fill
    assert bob.eval_py("return T_names()")["n"] > before["n"]
    assert did(w, bob)["si"] == 5
    nxt()
    nxt()
    s = state(bob)
    assert (s["si"], s["title"]) == (7, "A job for you"), s
    bob.eval("%s:Assign(T_empty_slot(), ...)" % B, me)
    assert did(w, bob)["si"] == 8
    nxt()

    # reading it: my job is on the board, every slot has a name
    s = state(bob)
    assert (s["chapter"], s["si"]) == ("read", 1), s
    assert bob.eval("return %s.mode" % ST) == "view"
    names = bob.eval_py("return T_names()")
    assert names["n"] == names["slots"] and names["mine"] >= 1, names
    jobs = bob.eval("return %s.view.mine:GetText()" % W)
    assert "Your jobs" in jobs and "none on this board" not in jobs, jobs
    for _ in range(4):
        nxt()
    assert state(bob)["title"] == "Phases"       # two pages (the basics added one): the tabs are shown
    for _ in range(3):
        nxt()

    # the library
    s = state(bob)
    assert (s["chapter"], s["si"], s["lit"]) == ("library", 1, True), s
    assert bob.eval("return %s:IsShown()" % B) is False
    assert bob.eval("return ns.StrategiesUI:GetLibrary():IsVisible()") is True
    # Back goes to the practice board as it was left
    bob.click(bob.eval("return _G.DisasterZoneTourBox.back"))
    w.tick(0.1)
    s = state(bob)
    assert (s["chapter"], s["si"]) == ("read", s["steps"]), s
    assert bob.eval("return %s:IsShown() and %s.mode" % (B, ST)) == "view"
    assert bob.eval_py("return T_names()") == names
    nxt()
    for _ in range(5):
        nxt()
    assert state(bob) is None
    assert bob.eval_py("return %s:Progress('strategy').done" % T) == {k: True for k in CHAPTERS}
    assert ndrafts(bob) == 0
    assert not strategies(bob, BOSS)
    w.assert_no_errors()


@case
def a_later_chapter_started_on_its_own_brings_its_board():
    w, c, bob = setup()
    # reading: the jobs are there, every slot has a name and one is mine
    start(w, bob, "read")
    st = bob.eval_py("local s = %s; return { mode = s.mode, sandbox = s.sandbox, blocks = #s.strat.p[1].k }" % ST)
    assert st == {"mode": "view", "sandbox": True, "blocks": 5}, st
    names = bob.eval_py("return T_names()")
    assert names["n"] == names["slots"] == 5 and names["mine"] >= 1, names
    # the practice board's own buttons stay on the practice board
    bob.click(bob.eval("return %s.editBtn" % W))
    w.tick(0.2)
    st = bob.eval_py("local s = %s; return { mode = s.mode, sandbox = s.sandbox }" % ST)
    assert st == {"mode": "edit", "sandbox": True}, st
    assert ndrafts(bob) == 0
    bob.eval("%s:Stop()" % T)

    # assigning: the same board, in the assigning mode; Cancel closes it without a trace
    start(w, bob, "assign")
    assert bob.eval("return %s.mode" % ST) == "fill"
    assert bob.eval("return %s.stratDD:IsShown()" % W) is False
    bob.click(bob.eval("return %s.pool.suggestBtn" % W))
    n0 = len(bob.chat_frame)
    bob.click(bob.eval("return %s.saveBtn" % W))
    assert any("practice board" in p for p in bob.chat_frame[n0:]), bob.chat_frame[n0:]
    bob.click(bob.eval("return %s.cancelBtn" % W))
    w.tick(0.2)
    assert bob.eval("return %s:IsShown()" % B) is False
    tick(w, bob)
    assert state(bob) is None
    assert ndrafts(bob) == 0

    # the library chapter needs no board
    start(w, bob, "library")
    s = state(bob)
    assert (s["chapter"], s["si"], s["lit"]) == ("library", 1, True), s
    assert bob.eval("return %s:IsShown()" % B) is False
    # leaving the Strategies view ends it
    bob.eval("ns.RaidsUI:SetView('upcoming')")
    w.tick(0.2)
    tick(w, bob)
    assert state(bob) is None
    w.assert_no_errors()


@case
def the_link_step_brings_its_own_zone_when_everything_is_linked():
    w, c, bob = setup()
    start(w, bob, "jobs")
    s = state(bob)
    assert (s["chapter"], s["si"]) == ("jobs", 1), s
    # every creature linked: all five suggested blocks
    for _ in range(5):
        bob.eval("local p = %s.blocks; for _, sg in ipairs(p:Suggestions(T_pg())) do sg.apply() break end" % W)
        w.tick(0.1)
    assert bob.eval("return #T_pg().k") == 5
    n = bob.eval("return #T_pg().e")
    for _ in range(4):
        bob.click(bob.eval("return _G.DisasterZoneTourBox.next"))
        w.tick(0.1)
    assert state(bob)["si"] == 5
    assert bob.eval("return #T_pg().e") == n + 1
    assert bob.eval_py("local e = T_pg().e[#T_pg().e]; return { t = e.t, l = e.l, ln = e.ln }") == {"t": "z", "l": "Melee"}
    w.assert_no_errors()


@case
def back_and_the_chapter_menu():
    w, c, bob = setup()
    start(w, bob, 2)
    s = state(bob)
    assert (s["chapter"], s["si"]) == ("drawing", 1), s
    # Back from a chapter's first step: the last step of the one before
    bob.click(bob.eval("return _G.DisasterZoneTourBox.back"))
    s = state(bob)
    assert (s["chapter"], s["si"]) == ("basics", s["steps"]), s
    bob.eval("%s:Stop()" % T)
    assert state(bob) is None
    # with nothing finished, it starts at the first chapter; later at the first one not finished
    start(w, bob)
    assert state(bob)["chapter"] == "basics"
    bob.eval("%s:Progress('strategy').done.basics = true; %s:Stop()" % (T, T))
    start(w, bob)
    assert state(bob)["chapter"] == "drawing"
    # the progress survives a reload
    bob.relog()
    w.tick(1)
    assert bob.eval_py("return %s:Progress('strategy')" % T) == {"seen": True, "done": {"basics": True}}
    w.assert_no_errors()


@case
def the_library_offers_the_tour_once():
    w, c, bob = setup()
    w.tick(0.5)
    bob.slash("/dz raids")
    w.tick(0.5)
    bob.eval("ns.RaidsUI:SetView('strategies')")
    w.tick(0.5)
    assert state(bob) == {"offer": "strategy"}, state(bob)
    assert bob.eval("return _G.DisasterZoneTourBox.next:GetText()") == "Start"
    # Not now: never offered again, the button stays
    bob.click(bob.eval("return _G.DisasterZoneTourBox.back"))
    assert state(bob) is None
    bob.eval("ns.StrategiesUI:RefreshLibrary()")
    assert state(bob) is None
    bob.relog()
    w.tick(1)
    bob.slash("/dz raids")
    w.tick(0.5)
    bob.eval("ns.RaidsUI:SetView('strategies')")
    w.tick(0.5)
    assert state(bob) is None
    assert bob.eval("return %s.strategies.detail.tourBtn:IsShown()" % P) is True

    # Start on the offer starts the tour
    rita = c["Rita"]
    rita.slash("/dz raids")
    w.tick(0.5)
    rita.eval("ns.RaidsUI:SetView('strategies')")
    w.tick(0.5)
    assert state(rita) == {"offer": "strategy"}, state(rita)
    rita.click(rita.eval("return _G.DisasterZoneTourBox.next"))
    w.tick(0.2)
    s = state(rita)
    assert (s["id"], s["chapter"], s["si"]) == ("strategy", "basics", 1), s
    assert rita.eval("return %s.sandbox" % ST) is True
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

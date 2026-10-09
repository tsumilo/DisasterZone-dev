import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "raidplan"))
import test_raidplan_comp_ui as T
from rp_common import K

def run(src_expr, over_box, over_chip, label):
    w, c = T.world()
    bob = c["Bob"]
    tid = T.save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, comp=T.preset(bob, "std25"),
                      groups={"Lee": 1, "Rita": 1, "Sam": 2})
    w.tick(1)
    T.open_teams(w, bob, tid, "groups")
    G = T.GRID
    src = bob.eval(src_expr)
    print(label, "src", src is not None)
    bob.eval("_G.IsMouseButtonDown = function() return true end")
    try:
        bob.eval("local s = ...; local f = s:GetScript('OnDragStart'); f(s)", src)
    except Exception as e:
        print("  BeginDrag error", e)
    w.tick(0.2)
    print("  ghost shown", bob.eval("local g = ns.RaidGroupsUI.__plateGhost; return g and g:IsShown()"),
          "size", bob.eval("local g = ns.RaidGroupsUI.__plateGhost; return g and g:GetWidth()"), bob.eval("local g = ns.RaidGroupsUI.__plateGhost; return g and g:GetHeight()"))
    if over_box:
        bob.eval("local g = %s; g.boxes[%d].IsMouseOver = function() return true end; g.boxes[%d].chips[%d].IsMouseOver = function() return true end" % (G, over_box, over_box, over_chip))
    w.tick(0.2)
    bob.eval("_G.IsMouseButtonDown = function() return false end")
    try:
        bob.eval("local s = ...; local f = s:GetScript('OnDragStop'); if f then f(s) end", src)
    except Exception as e:
        print("  DragStop error", e)
    w.tick(0.3)
    print("  dragging", bob.eval("return %s.dragging" % G))
    print("  groups", bob.eval_py("return ns.RaidPlanUI:GetDraft().grp"))
    errs = bob.eval_py("return nil")
    try:
        w.assert_no_errors()
        print("  no lua errors")
    except Exception as e:
        print("  ERR", str(e)[:1500])

run("return %s.pool.chips[1]" % T.GRID, 3, 2, "pool->g3s2")
run("return %s.pool.chips[1].roleBtn" % T.GRID, 3, 2, "pool roleBtn->g3s2")
run("return %s.boxes[1].chips[1]" % T.GRID, 1, 2, "g1s1->g1s2 (swap)")
run("return %s.boxes[1].chips[1].roleBtn" % T.GRID, 2, 1, "g1 roleBtn->g2s1")

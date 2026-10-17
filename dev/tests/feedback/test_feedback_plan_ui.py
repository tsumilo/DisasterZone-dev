"""The Plan tab and its pieces (UI/FeedbackPlan.lua): the board, Sort, the roadmap, the release check, the release and
own-item sheets, Plan it in the Inbox; read-only for officers, hidden from raiders; demo mode; Coming next on the pill.

Run: luaenv\\Scripts\\python.exe tests\\feedback\\test_feedback_plan_ui.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import case, run_all, strip_codes  # noqa: E402
import test_feedback_plan as tp  # noqa: E402

standard, setup_plan, P, F = tp.standard, tp.setup_plan, tp.P, tp.F

PUI = "ns.FeedbackPlanUI"


def open_plan(cl, w, view="board"):
    cl.eval("ns.FeedbackUI:Open('plan')")
    w.tick(0.3)
    cl.eval("%s:SetView(...)" % PUI, view)
    w.tick(0.3)


def board_titles(cl):
    return cl.eval_py("""local out = {}
      local f = ns.FeedbackPlanUI:GetFrame()
      for _, kid in ipairs({ f.board:GetChildren() }) do
        if kid:IsShown() and kid.title then out[#out + 1] = kid.title:GetText() end
      end
      return out""") or []


@case
def the_developer_sees_every_view_and_sheet():
    w, c = standard()
    a, b = setup_plan(w, c)
    t = c["Tsumil"]
    open_plan(t, w, "board")
    assert t.eval("return ns.FeedbackUI:GetState().tab") == "plan"
    assert board_titles(t) == ["To sort", "1.9.1", "1.9.2", "Later"], board_titles(t)
    for view in ("sort", "road", "board"):
        open_plan(t, w, view)
    t.eval("%s:OpenCheck('1.9.1')" % PUI)
    w.tick(0.3)
    assert t.eval("return %s.checkSheet:IsShown()" % PUI) is True
    draft = t.eval("return %s.checkSheet.draft.eb:GetText()" % PUI)
    assert "fb = {" in draft and "Boss mods" in draft, draft
    t.eval("%s.checkSheet:Close()" % PUI)
    t.eval("%s:OpenRelease('1.9.1')" % PUI)
    w.tick(0.2)
    assert t.eval("return %s.relSheet.th:GetText()" % PUI) == "Quality of life"
    t.eval("%s.relSheet:Close(); %s:OpenOwnItem()" % (PUI, PUI))
    w.tick(0.2)
    t.eval("local s = %s.ownSheet; s.title:SetText('Polish the board'); s.ok:Click()" % PUI)
    w.tick(0.3)
    assert t.eval("return %s:Entry('D-2').tt" % P) == "Polish the board"
    # the card menu builds for a guild item and a dev item
    for key in (a, "D-1"):
        t.eval("local c = %s.CardOf(..., %s:Entry(...)); ns.UI:ContextMenu(UIParent, function(root) "
               "%s:CardMenu(root, c) end); ns.UI:CloseMenus()" % (P, P, PUI), key)
    w.assert_no_errors()


@case
def plan_it_in_the_inbox_sizes_and_places_an_item():
    w, c = standard()
    setup_plan(w, c)
    new = c["Alfa"].eval("return (ns.Feedback:Submit('change', 'Thinner swing timer bar for 10-man raids.'))")
    w.tick(10, step=0.25)
    t = c["Tsumil"]
    t.eval("ns.FeedbackUI:Open('inbox', ...)", new)
    w.tick(0.3)
    t.eval("ns.FeedbackUI:GetPanel().detail.plan:Click()")
    w.tick(0.2)
    assert t.eval("return %s.planIt:IsShown()" % PUI) is True
    tell = strip_codes(t.eval("return %s.planIt.tell:GetText()" % PUI))
    assert "Planned for 1.9.1" in tell, tell
    t.eval("local p = %s.planIt; p.size:Select('S', true); p.note:SetText('easy'); p.ok:Click()" % PUI)
    w.tick(0.3)
    e = t.eval_py("return %s:Entry(...)" % P, new)
    assert e["rl"] == "1.9.1" and e["sz"] == "S" and e["nt"] == "easy", e
    assert t.eval("return %s:Get(...).state" % F, new) == "planned"
    w.tick(10, step=0.25)
    # the author's pill says which release
    pill = c["Alfa"].eval("return (ns.FeedbackUI.Pill(%s:Get(...)))" % F, new)
    assert pill == "Planned for 1.9.1", pill
    w.assert_no_errors()


@case
def officers_see_it_read_only_and_raiders_not_at_all():
    w, c = standard()
    a, _ = setup_plan(w, c)
    c["Bert"].eval("ns.Feedback:Submit('idea', 'An unplaced idea for the Sort view.')")
    w.tick(10, step=0.25)
    o = c["Olaf"]
    open_plan(o, w, "board")
    assert o.eval("return ns.FeedbackUI:GetState().tab") == "plan"
    assert "1.9.1" in board_titles(o)
    assert o.eval("return %s.ownBtn:IsShown()" % PUI) is False
    open_plan(o, w, "sort")
    assert o.eval("return %s:GetFrame().sort.save:IsEnabled()" % PUI) is False
    # Plan it stays the plain status for an officer (no popover)
    r = c["Bert"]
    open_plan(r, w, "board")
    assert r.eval("return ns.FeedbackUI:GetState().tab") == "all"
    w.assert_no_errors()


@case
def demo_mode_shows_a_full_plan():
    w, c = standard()
    alfa = c["Alfa"]
    alfa.slash("/dz demo on")
    w.tick(1)
    for view in ("board", "sort", "road"):
        open_plan(alfa, w, view)
    titles = board_titles(alfa)
    assert titles[0] == "To sort" and titles[-1] == "Later" and len(titles) == 4, titles
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())

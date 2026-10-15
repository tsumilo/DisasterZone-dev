"""Feedback screens (UI/Feedback.lua, UI/FeedbackSheet.lua, the changelog's credits): the page, demo mode, the form,
Point at it (a mode that never blocks DisasterZone), the editable About, the staff buttons in the Inbox only, the
pop-ups.

Run: luaenv\\Scripts\\python.exe tests\\feedback\\test_feedback_ui.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import case, run_all, strip_codes  # noqa: E402
from test_feedback import standard, settle, submit, item, K, F  # noqa: E402

SHEET = "ns.FeedbackSheet"


def open_page(cl, w, tab=None):
    cl.eval("ns.FeedbackUI:Open(...)", tab)
    w.tick(0.3)


def rows(cl):
    return cl.eval_py("""local out = {}
      for _, d in ipairs(ns.FeedbackUI:GetPanel().list:GetData()) do
        out[#out + 1] = d.header and ('# ' .. d.header) or d.item.text
      end
      return out""") or []


@case
def demo_mode_fills_the_page_and_saves_and_sends_nothing():
    w, c = standard()
    settle(w)
    g = c["Gina"]
    start = len(w.addon_log)
    g.slash("/dz demo on")
    w.tick(1)
    open_page(g, w)
    r = rows(g)
    assert r[0] == "# Open" and "# Done lately" in r and len(r) >= 10, r
    assert g.eval("return ns.FeedbackUI:GetState().sel ~= nil")
    # I am staff in demo mode, and one item is mine with an officer's answer: news on Yours
    assert g.eval("return ns.Feedback:AmIStaff()") is True
    assert g.eval("return ns.FeedbackUI:NewsCount()") == 1
    # acting in demo mode: in memory only, nothing on the wire, nothing saved
    gid = g.eval("for _, v in ipairs(ns.Feedback:List()) do if v.text:find('Sunwell') then return v.id end end")
    g.eval("%s:Vote(..., true)" % F, gid)
    id_ = submit(g, "idea", "A demo idea that must never leave this client.")
    assert "#" in id_, id_
    w.tick(5)
    assert [e for e in w.addon_log[start:] if e["prefix"] == "CDLb" and e["sender"] == K("Gina")] == []
    assert g.eval_py("local s = ns.db.feedback; local n = 0 for _, b in pairs(s or {}) do for _ in pairs(b.r or {}) do "
                     "n = n + 1 end end return n") == 0
    assert g.eval("return ns.Feedback:Get(...).no ~= nil", id_), "demo: Tsumil has it after a moment"
    # the demo's officer answer is news in the bell too (kept in memory by the notification center)
    g.eval("ns.Notify:Refresh('feedbackAnswer')")
    w.tick(0.2)
    assert g.eval("for _, it in ipairs(ns.Notify:List()) do if it.kind == 'feedbackAnswer' then return it.title end end")         == "Caelith answered your feedback"
    # off again: the real (empty) feedback, the demo's gone
    g.slash("/dz demo off")
    w.tick(1)
    assert rows(g) == []
    w.assert_no_errors()


@case
def real_feedback_keeps_arriving_while_demo_mode_is_on():
    w, c = standard()
    settle(w)
    c["Tsumil"].slash("/dz demo on")
    w.tick(1)
    id_ = submit(c["Alfa"], "bug", "Something real while Tsumil looks at the demo.")
    w.tick(5)
    assert c["Tsumil"].eval_py("return ns.Feedback:Get(...)", id_) is None, "the demo store is what Tsumil sees"
    c["Tsumil"].slash("/dz demo off")
    w.tick(3)
    assert item(c["Tsumil"], id_)["no"] == 1, "it arrived and was numbered all the same"
    assert item(c["Alfa"], id_)["no"] == 1
    w.assert_no_errors()


@case
def a_tile_opens_the_form_with_that_kind_and_send_shows_the_tracker():
    w, c = standard()
    settle(w)
    a = c["Alfa"]
    open_page(a, w)
    a.eval("ns.FeedbackUI:GetPanel().banner.tiles.idea:Click()")
    w.tick(0.2)
    assert a.eval("return %s:IsOpen()" % SHEET) is True
    assert a.eval_py("return %s:GetDraft().kind" % SHEET) == "idea"
    a.eval("%s:GetFrame().edit:SetText('Let me pin pages to the minimap.')" % SHEET)
    a.eval("%s:Send()" % SHEET)
    w.tick(0.2)
    f = "%s:GetFrame()" % SHEET
    assert a.eval("return %s.done:IsShown()" % f) is True
    assert a.eval("return %s.done.steps.nodes[2].label:GetText()" % f) == "Received"
    a.eval("%s.done.see:Click()" % f)
    w.tick(0.3)
    assert a.eval("return ns.MainFrame:GetSelectedTab()") == "feedback"
    assert a.eval("return ns.FeedbackUI:GetState().tab") == "mine"
    w.assert_no_errors()


@case
def point_at_it_lets_you_navigate_and_a_right_click_picks():
    w, c = standard()
    settle(w)
    a = c["Alfa"]
    open_page(a, w)
    a.eval("%s:Open({ kind = 'bug' })" % SHEET)
    a.eval("%s:StartPointing()" % SHEET)
    w.tick(0.2)
    # the form steps aside, nothing covers DisasterZone: navigation works as usual
    assert a.eval("return %s:IsOpen()" % SHEET) is False
    assert a.eval("return %s:IsPointing()" % SHEET) is True
    assert a.eval("return _G.DisasterZoneFeedbackPointer:IsMouseEnabled()") is False
    assert a.eval("return _G.DisasterZoneFeedbackPointerBar:IsShown()") is True
    a.eval("ns.MainFrame:Open('changelog')")
    w.tick(0.2)
    assert a.eval("return ns.MainFrame:GetSelectedTab()") == "changelog"
    # the right-click on a frame of the page picks it: the form comes back with About filled
    a.eval("%s.StopPointing(ns.ChangelogUI and ns.MainFrame:GetPanel('changelog').list)" % SHEET)
    w.tick(0.2)
    assert a.eval("return %s:IsOpen()" % SHEET) is True
    about = a.eval_py("return %s:GetDraft().about" % SHEET)
    assert about and about.startswith("Changelog"), about
    assert a.eval("return %s:GetFrame().about:GetText()" % SHEET) == about
    # Cancel keeps what was there
    a.eval("%s:StartPointing()" % SHEET)
    a.eval("_G.DisasterZoneFeedbackPointerBar.cancel:Click()")
    w.tick(0.1)
    assert a.eval_py("return %s:GetDraft().about" % SHEET) == about
    assert a.eval("return %s:IsOpen()" % SHEET) is True
    w.assert_no_errors()


@case
def about_can_be_typed():
    w, c = standard()
    settle(w)
    a = c["Alfa"]
    a.eval("%s:Open({ kind = 'change', about = 'Raids' })" % SHEET)
    a.eval("""local eb = %s:GetFrame().about
      eb:SetText('Raids › Sign-ups')
      local fn = eb:GetScript('OnTextChanged'); fn(eb, true)""" % SHEET)
    assert a.eval_py("return %s:GetDraft().about" % SHEET) == "Raids › Sign-ups"
    a.eval("%s:GetFrame().edit:SetText('Show alts in one row.')" % SHEET)
    a.eval("%s:Send()" % SHEET)
    w.tick(3)
    got = c["Tsumil"].eval_py("for _, v in ipairs(ns.Feedback:List()) do if v.text:find('alts') then return v.about end end")
    assert got == "Raids › Sign-ups", got
    w.assert_no_errors()


@case
def staff_buttons_only_in_the_inbox_and_the_author_answers_everywhere():
    w, c = standard()
    settle(w)
    id_ = submit(c["Alfa"], "idea", "Show token needs on boss tiles.")
    w.tick(3)
    o = c["Olaf"]
    open_page(o, w, "inbox")
    o.eval("ns.FeedbackUI:Select(...)", id_)
    d = "ns.FeedbackUI:GetPanel().detail"
    assert o.eval("return %s.plan:IsShown() and %s.reply:IsShown()" % (d, d)) is True
    open_page(o, w, "all")
    o.eval("ns.FeedbackUI:Select(...)", id_)
    assert o.eval("return %s.plan:IsShown()" % d) is False
    assert o.eval("return %s.reply:IsShown()" % d) is False
    assert o.eval("return %s.status:IsShown()" % d) is True
    a = c["Alfa"]
    open_page(a, w, "all")
    a.eval("ns.FeedbackUI:Select(...)", id_)
    assert a.eval("return %s.reply:IsShown() and not %s.status:IsShown()" % (d, d)) is True
    # a raider's own Inbox tab never shows
    assert a.eval("return ns.FeedbackUI:GetPanel().tabs.inbox:IsShown()") is False
    w.assert_no_errors()


@case
def news_goes_through_the_notification_center():
    w, c = standard()
    settle(w)
    a = c["Alfa"]
    # a Lua error: a feedbackError item with Tell Tsumil
    a.eval("ns.Feedback.NoteError('Interface/AddOns/DisasterZone/UI/X.lua:1: boom', '')")
    w.tick(0.5)
    errs = a.eval_py("local o = {} for _, it in ipairs(ns.Notify:List()) do if it.kind == 'feedbackError' then "
                     "o[#o + 1] = it.title end end return o")
    assert errs == ["DisasterZone hit an error"], errs
    a.eval("local it; for _, x in ipairs(ns.Notify:List()) do if x.kind == 'feedbackError' then it = x end end "
           "ns.Notify:RunAction(it.id, 1)")
    w.tick(0.2)
    assert a.eval_py("return %s:GetDraft().kind" % SHEET) == "bug"
    a.eval("%s:GetFrame():Hide()" % SHEET)
    # an officer answers Alfa's item: news until Alfa looks at it on the page
    id_ = submit(a, "idea", "Sort the loot log by item level.")
    w.tick(3)
    c["Olaf"].eval("%s:SetState(..., 'exists', { reply = 'Click the Item column.' })" % F, id_)
    w.tick(3)
    a.eval("ns.Notify:Refresh('feedbackAnswer')")
    w.tick(0.2)
    ans = a.eval_py("local o = {} for _, it in ipairs(ns.Notify:List()) do if it.kind == 'feedbackAnswer' then "
                    "o[#o + 1] = { it.key, it.title } end end return o")
    assert ans == [[id_, "Olaf answered your feedback"]], ans
    a.eval("ns.FeedbackUI:Open('mine', ...)", id_)
    w.tick(0.3)
    a.eval("ns.Notify:Refresh('feedbackAnswer')")
    w.tick(0.2)
    assert a.eval("for _, it in ipairs(ns.Notify:List()) do if it.kind == 'feedbackAnswer' then return true end end "
                  "return false") is False
    w.assert_no_errors()


@case
def the_changelog_names_who_asked_and_marks_mine():
    w, c = standard()
    settle(w)
    a = c["Alfa"]
    # (the installed version's own credits are taken off first: the footer then counts only this one)
    a.eval("""local e
      for _, x in ipairs(ns.CHANGELOG) do if x.version == ns.version then e = x end end
      for _, s in ipairs(e.sections) do
        for i, l in ipairs(s.lines) do
          if type(l) == 'table' and (l.fb or l.by) then s.lines[i] = l[1] end
        end
      end
      table.insert(e.sections[1].lines, 1, { 'The roll popup waits until you leave combat.', fb = { 12 },
        by = { 'Alfa', 'Bert' }, mt = 3, k = 'bug' })
      ns.ChangelogUI.ResetIndex()""")
    a.eval("ns.ChangelogUI:Open(ns.version)")
    w.tick(0.3)
    # the credited line's section opened (sections are folded to one line)
    a.eval("""local st = ns.ChangelogUI:GetState()
      for _, s in ipairs(ns.ChangelogUI.Norm().by[ns.version].sections) do st.open[s.id] = true; st.card = s.id end
      st.card = ns.ChangelogUI.Norm().by[ns.version].sections[1].id
      ns.ChangelogUI:Render()""")
    w.tick(0.1)
    texts = [strip_codes(t) for t in a.eval_py("""local out = {}
      local function walk(f)
        for _, r in ipairs({ f:GetRegions() }) do
          if r.GetText and r:IsVisible() and r:GetText() then out[#out + 1] = r:GetText() end
        end
        for _, ch in ipairs({ f:GetChildren() }) do if ch:IsVisible() then walk(ch) end end
      end
      walk(ns.MainFrame:GetPanel('changelog'))
      return out""")]
    line = next(t for t in texts if t.startswith("The roll popup waits"))
    assert line == "The roll popup waits until you leave combat.", line     # the credit is its own text
    assert any(t.strip() == "Alfa, Bert +3   you asked for this" for t in texts), texts
    # the footer says which changes are theirs, not the whole release
    assert "Thanks to Alfa and Bert for the bug report behind one of these changes." in texts, texts
    w.assert_no_errors()


@case
def the_thanks_line_counts_the_credited_changes():
    w, c = standard()
    a = c["Alfa"]
    def thanks(lines):
        return a.eval("return ns.ChangelogUI.ThanksLine({ sections = { { lines = { " + lines + " } } } })")
    assert thanks("'plain'") is None
    assert thanks("'plain', { 'x', by = { 'Släy' }, k = 'idea' }") == \
        "Thanks to Släy for the idea behind one of these changes."
    assert thanks("{ 'x', by = { 'Bert' }, k = 'idea' }, { 'y', by = { 'Alfa' }, k = 'change' }") == \
        "Thanks to Alfa and Bert for the ideas behind 2 of these changes."
    assert thanks("{ 'x', by = { 'Bert' }, k = 'bug' }, { 'y', by = { 'Bert' }, k = 'idea' }, 'z'") == \
        "Thanks to Bert for the bug reports and ideas behind 2 of these changes."
    w.assert_no_errors()


@case
def the_nav_share_links_the_feedback_page_and_the_picked_item():
    w, c = standard()
    settle(w)
    a, b = c["Alfa"], c["Bert"]
    id_ = submit(a, "bug", "The share icon on the member card can't be clicked.")
    settle(w)
    cur = lambda cl: cl.eval("return ns.Share:CurrentRef()")  # noqa: E731
    open_page(b, w)
    b.eval("ns.FeedbackUI:Select(nil)")
    assert cur(b) == "feedback"
    b.eval("ns.FeedbackUI:Select(...)", id_)
    assert cur(b) == "fb:" + id_
    assert b.eval("return ns.Share:Describe(...).label", "fb:" + id_).startswith("Bug: The share icon")
    tok = b.eval("return ns.Share:Text(...)", "fb:" + id_)
    assert tok and tok.endswith("#fb:" + id_ + "]"), tok
    assert b.eval_py("return #ns.Share:Parse(...)", tok) == 1
    # a click on the link opens the page on that item; the tooltip says what it is
    a.eval("ns.MainFrame:Open('home')")
    assert a.eval_py("return (ns.Share:Open(...))", "fb:" + id_) is True
    assert a.eval("return ns.MainFrame:GetSelectedTab()") == "feedback"
    assert a.eval("return ns.FeedbackUI:GetState().sel") == id_
    tip = a.eval_py("""GameTooltip:SetOwner(UIParent, 'ANCHOR_NONE'); ns.Share:FillTooltip(GameTooltip, ...)
      local out = {}
      for i = 1, GameTooltip:NumLines() do out[#out + 1] = _G['GameTooltipTextLeft' .. i]:GetText() end
      GameTooltip:Hide(); return table.concat(out, ' | ')""", "fb:" + id_)
    assert "Something broke" in tip and "can't be clicked" in tip, tip
    # the other new pages are shareable too
    for page in ("feedback", "polls", "atlas", "map", "mylog", "notify"):
        assert b.eval("return ns.Share:Text(...)", page), page
    w.assert_no_errors()


@case
def the_box_shows_its_count_and_placeholder_over_its_fill():
    # (1.4 regression: the box became a card with its own fill, a child frame drawn over its parent's text)
    w, c = standard()
    settle(w)
    a = c["Alfa"]
    open_page(a, w)
    a.eval("ns.FeedbackUI:GetPanel().banner.tiles.idea:Click()")
    w.tick(0.2)
    f = "%s:GetFrame()" % SHEET
    over = a.eval_py("""local f = %s
      local function above(fs)
        local p = fs:GetParent()
        return p == f.boxEdge or (p:GetFrameLevel() > f.boxEdge:GetFrameLevel())
      end
      return { above(f.hint), above(f.count) }""" % f)
    assert over == [True, True], over
    assert a.eval("return %s.hint:IsShown()" % f) is True
    a.eval("%s.edit:SetText('Let me pin pages to the minimap.')" % f)
    assert a.eval("return %s.count:GetText()" % f) == "32 / 400"
    assert a.eval("return %s.hint:IsShown()" % f) is False
    w.assert_no_errors()


@case
def feedback_pop_ups_waiting_behind_a_full_stack_are_all_shown():
    # (1.4 regression: a second pop-up replaced the first one while it waited in the shared queue)
    w, c = standard()
    settle(w)
    a = c["Alfa"]
    a.eval("for i = 1, ns.UI.TOAST.MAX do ns.UI:Toast({ key = 'fill' .. i, title = 'Other ' .. i, duration = 0 }) end")
    a.eval("%s:Toast({ title = 'First', text = 'one', button = 'OK' })" % SHEET)
    a.eval("%s:Toast({ title = 'Second', text = 'two', button = 'OK' })" % SHEET)
    w.tick(0.2)
    assert a.eval("return %s:GetToast() ~= nil and ns.UI:GetToast('dz-feedback') ~= nil" % SHEET) is False
    a.eval("for i = 1, ns.UI.TOAST.MAX do ns.UI:HideToast('fill' .. i) end")
    w.tick(1)
    seen = []
    for _ in range(4):
        t = a.eval_py("local t = ns.UI:GetToast('dz-feedback'); return t and t.title:GetText() or false")
        if t and t not in seen:
            seen.append(t)
            a.eval("ns.UI:HideToast('dz-feedback', 'close')")
        w.tick(1)
    assert seen == ["First", "Second"], seen
    w.assert_no_errors()


@case
def a_bug_takes_a_pasted_error_and_the_item_opens_it_from_its_header():
    w, c = standard()
    settle(w)
    a = c["Alfa"]
    f = "%s:GetFrame()" % SHEET
    a.eval("%s:Open({ kind = 'idea' })" % SHEET)
    w.tick(0.2)
    assert a.eval("return %s.paste:IsShown()" % f) is False, "only a bug pastes an error"
    a.eval("%s:Open({ kind = 'bug' })" % SHEET)
    w.tick(0.2)
    assert a.eval("return %s.paste:IsShown()" % f) is True
    a.eval("%s.paste:Click()" % f)
    w.tick(0.2)
    ew = "%s:GetErrorWindow()" % SHEET
    assert a.eval("return %s:IsShown() and %s.mode" % (ew, ew)) == "edit"
    a.eval("%s.eb:SetText(...)" % ew, "1x DisasterZone/UI/Members.lua:233: boom\nline two\nline three")
    a.eval("%s.ok:Click()" % ew)
    w.tick(0.2)
    assert a.eval("return %s:IsShown()" % ew) is False
    assert a.eval("return %s.paste:GetText()" % f) == "Edit error"
    chips = a.eval_py("local o = {} for _, ch in ipairs(%s.withChips) do if ch:IsShown() then "
                      "o[#o + 1] = ch.fs:GetText() or '' end end return o" % f)
    assert any("Pasted error, 3 lines" in (t or "") for t in chips), chips
    a.eval("%s.edit:SetText('Members tab broke.')" % f)
    a.eval("%s:Send()" % SHEET)
    w.tick(3)
    assert a.eval_py("return %s:GetDraft().paste" % SHEET) is None, "sent: the paste is cleared"
    # the developer opens the item: an error icon left of the Status menu, it opens the error to read
    t = c["Tsumil"]
    id_ = K("Alfa") + "#1"
    open_page(t, w, "all")
    t.eval("ns.FeedbackUI:Select(...)", id_)
    w.tick(0.2)
    d = "ns.FeedbackUI:GetPanel().detail"
    assert t.eval("return %s.errTool:IsShown()" % d) is True
    # (row from the right: the error icon hangs off the Status button's left edge)
    assert t.eval("local _, rel, rp = %s.errTool:GetPoint(1); return rel == %s.status and rp" % (d, d)) == "LEFT"
    t.eval("%s.errTool:Click()" % d)
    w.tick(0.2)
    assert t.eval("return %s:IsShown() and %s.mode" % (ew, ew)) == "view"
    assert t.eval("return %s.eb:GetText()" % ew) == "1x DisasterZone/UI/Members.lua:233: boom\nline two\nline three"
    # read only: typing puts it back
    t.eval("local eb = %s.eb; eb:SetText('x'); eb:GetScript('OnTextChanged')(eb, true)" % ew)
    assert t.eval("return %s.eb:GetText()" % ew).startswith("1x DisasterZone")
    # an item without an error has no icon
    other = submit(c["Bert"], "idea", "No error here.")
    w.tick(3)
    t.eval("ns.FeedbackUI:Select(...)", other)
    w.tick(0.2)
    assert t.eval("return %s.errTool:IsShown()" % d) is False
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

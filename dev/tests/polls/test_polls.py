"""Guild polls (Core/Polls.lua): asking, answering, sync between clients, who sees what.

Covers: the GM posts, the asked answer, results on everyone; members who aren't asked never see it (but keep it);
only the GM / officers / guild council ask (a forged poll is dropped); a member who was offline catches up from
whoever is online, also when the asker is gone; answers can't change when the poll says so, and none come after the
close; a Pick days poll counts can / if needed / can't and finds the best day; a nudge reaches only who hasn't
answered; a team target asks the team's roster; the asker adds people (never removes); removal by the asker or GM.
Run: luaenv\\Scripts\\python.exe tests\\polls\\test_polls.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

HELLO = 50
CLASSES = ["PALADIN", "MAGE", "ROGUE", "WARRIOR", "PRIEST", "DRUID", "HUNTER", "SHAMAN", "WARLOCK"]
NAMES = ["Gina", "Brakka", "Cora", "Dan", "Elowen"]


def guild(names=NAMES, tick=HELLO, ranks=None):
    w = World()
    cs = []
    for i, n in enumerate(names):
        rank = (ranks or {}).get(n, 0 if i == 0 else 3)
        cs.append(Client(w, n, guild_rank=rank, class_file=CLASSES[i % len(CLASSES)]))
    for c in cs:
        c.load_addon()
    w.tick(tick)
    return w, cs


def k(c):
    return c.eval("return ns.Util.PlayerKey()")


def post(c, q, kind, answers, targets, **opts):
    """c posts a poll: its id (or the error)."""
    code = """
        local q, kind, answers, targets, cl, rv, ch, mx = ...
        local id, why = ns.Polls:Create({ q = q, k = kind, o = answers, a = targets, cl = GetServerTime() + cl,
                                          rv = rv, ch = ch, mx = mx })
        return id or ("ERR " .. tostring(why))"""
    return c.eval(code, q, kind, answers, targets, opts.get("cl", 3600), opts.get("rv", "vote"),
                  opts.get("ch", True), opts.get("mx", 0))


def visible(c):
    return c.eval_py("local out = {} for _, p in ipairs(ns.Polls:GetPolls()) do out[#out + 1] = p.id end return out") or []


def stored(c, pid):
    return c.eval("local r = ns.db.polls and ns.db.polls[ns.Guild:GetGuildKey()]; return r and r.P[...] ~= nil or false",
                  pid)


def results(c, pid):
    return c.eval_py("""
        local p = ns.Polls:GetPoll(...)
        if not p then return nil end
        local r = ns.Polls:Results(p)
        local w = {}
        for i, key in ipairs(r.waiting) do w[i] = key:gsub("%-.*", "") end
        return { counts = r.counts, maybe = r.maybe, no = r.no, answered = r.answered, total = r.total, waiting = w,
                 best = r.best or 0 }""", pid)


def vote(c, pid, choice):
    return c.eval_py("return { ns.Polls:Vote(...) }", pid, choice)


@case
def gm_posts_the_asked_answer_and_everyone_sees_results():
    w, (g, b, c, d, e) = guild()
    pid = post(g, "Which night for SSC?", "one", ["Wednesday", "Thursday", "Sunday"],
               [["p", k(b)], ["p", k(c)], ["p", k(e)]])
    assert pid.startswith("p"), pid
    w.tick(5)
    assert visible(b) == [pid] and visible(c) == [pid], (visible(b), visible(c))
    assert visible(d) == [], visible(d)                # not asked: hidden ...
    assert stored(d, pid), "Dan's client keeps it for the others"   # ... but kept to relay
    assert visible(g) == [pid]                         # the asker sees it
    assert vote(b, pid, [2]) == [True], vote(b, pid, [2])
    assert vote(c, pid, [2])[0] is True
    assert vote(d, pid, [1])[0] is False               # Dan isn't asked
    w.tick(5)
    for cl in (g, b, e):
        r = results(cl, pid)
        assert r["counts"] == [0, 2, 0] and r["answered"] == 2 and r["total"] == 3, r
        assert r["waiting"] == ["Elowen"], r
    # the waiting count for Elowen, none for Brakka
    assert e.eval("return ns.Polls:WaitingCount()") == 1
    assert b.eval("return ns.Polls:WaitingCount()") == 0
    w.assert_no_errors()


@case
def only_gm_officers_and_council_ask_and_a_forged_poll_is_dropped():
    w, (g, b, c, d, e) = guild(ranks={"Brakka": 1})   # Brakka is an officer
    err = post(c, "Members can't ask", "yn", None, [["g"]])
    assert err.startswith("ERR"), err
    assert c.eval("return ns.Polls:AmIAsker()") is False
    assert b.eval("return ns.Polls:AmIAsker()") is True
    pid = post(b, "Officer asks", "yn", None, [["g"]])
    assert pid.startswith("p"), pid
    # Cora sends a poll by hand: nobody takes it
    c.eval("""
        local now = GetServerTime()
        ns.Comm:Send({ t = "PLU", k = "P", r = { id = "pforged", by = ns.Util.PlayerKey(), rev = now, at = now,
            q = "Forged", k = "yn", o = { "Yes", "No" }, cl = now + 600, rv = "live", a = { { "g" } },
            m = { ns.Util.PlayerKey() } } }, "GUILD", nil, "data")""")
    w.tick(5)
    for cl in (g, d, e):
        assert not stored(cl, "pforged"), cl.name
        assert stored(cl, pid), cl.name
    w.assert_no_errors()


@case
def everyone_poll_asks_each_member_once():
    w, cs = guild()
    g = cs[0]
    pid = post(g, "Everyone?", "yn", None, [["g"]])
    w.tick(5)
    r = results(g, pid)
    assert r["total"] == 5, r
    for cl in cs:
        assert visible(cl) == [pid], cl.name
    w.assert_no_errors()


@case
def an_offline_member_catches_up_even_when_the_asker_is_gone():
    w, (g, b, c, d, e) = guild()
    c.logout()
    w.tick(2)
    pid = post(g, "While you were away", "one", ["A", "B"], [["p", "Cora-" + w.realm], ["p", k(b)]])
    w.tick(5)
    assert vote(b, pid, [1])[0] is True
    w.tick(3)
    g.logout()                      # the asker leaves; Brakka / Dan / Elowen still hold it
    w.tick(2)
    c.login()
    w.tick(HELLO)
    assert visible(c) == [pid], visible(c)
    assert vote(c, pid, [2])[0] is True
    w.tick(5)
    r = results(b, pid)
    assert r["counts"] == [1, 1], r
    g.login()
    w.tick(HELLO)
    r = results(g, pid)
    assert r["counts"] == [1, 1] and r["waiting"] == [], r
    w.assert_no_errors()


@case
def answers_change_only_when_allowed_and_never_after_the_close():
    w, (g, b, c, d, e) = guild()
    fixed = post(g, "Fixed answers", "one", ["A", "B"], [["p", k(b)], ["p", k(c)]], ch=False)
    free = post(g, "Free answers", "one", ["A", "B"], [["p", k(b)]], ch=True)
    w.tick(5)
    assert vote(b, fixed, [1])[0] is True
    assert vote(b, fixed, [2])[0] is False             # can't change
    assert vote(b, free, [1])[0] is True
    assert vote(b, free, [2])[0] is True               # may change
    w.tick(5)
    assert results(g, free)["counts"] == [0, 1]
    assert results(g, fixed)["counts"] == [1, 0]
    # Gina closes the fixed one: Cora can't answer any more, and nobody takes an answer sent by hand
    assert g.eval("return ns.Polls:Close(...)", fixed) is True
    w.tick(5)
    assert c.eval("return ns.Polls:IsOpen(ns.Polls:GetPoll(...))", fixed) is False
    assert vote(c, fixed, [1])[0] is False
    c.eval("""
        local id = ...
        local me = ns.Util.PlayerKey()
        ns.Comm:Send({ t = "PLU", k = "V", r = { id = id .. "/" .. me, by = me, rev = GetServerTime(), c = { 1 } } },
            "GUILD", nil, "data")""", fixed)
    w.tick(5)
    assert results(g, fixed)["answered"] == 1
    w.assert_no_errors()


@case
def pick_days_counts_and_finds_the_best_day():
    w, (g, b, c, d, e) = guild()
    days = ["2026-10-13 20:00", "2026-10-15 20:00", "2026-10-16", "2026-10-18 19:30"]
    pid = post(g, "Which nights?", "days", days, [["g"]], rv="live")
    assert pid.startswith("p"), pid
    w.tick(5)
    assert vote(b, pid, [1, 0, 1, 2])[0] is True
    assert vote(c, pid, [1, 1, 1, 0])[0] is True
    assert vote(d, pid, [0, 1, 1, 2])[0] is True
    assert vote(e, pid, [1, 0, 2, 1])[0] is True
    assert vote(g, pid, [1, 2])[0] is False            # one state per day
    w.tick(5)
    r = results(g, pid)
    assert r["counts"] == [3, 2, 3, 1], r
    assert r["maybe"] == [0, 0, 1, 2] and r["no"] == [1, 2, 0, 1], r
    assert r["best"] == 3, r                           # Fri 16 ties Mon 13 on "can", wins on "if needed"
    label = g.eval_py("return { ns.Polls:DayLabel('2026-10-13 20:00') }")
    assert label[1] == "20:00", label
    w.assert_no_errors()


@case
def a_nudge_reaches_only_who_has_not_answered():
    w, (g, b, c, d, e) = guild()
    for cl in (b, c, d):
        cl.eval("_G.__nudged = 0; ns:On('POLL_NUDGED', function() _G.__nudged = _G.__nudged + 1 end)")
    pid = post(g, "Nudge me", "yn", None, [["p", k(b)], ["p", k(c)]])
    w.tick(5)
    assert vote(b, pid, [1])[0] is True
    w.tick(3)
    assert g.eval("return ns.Polls:Nudge(...)", pid) == 1
    w.tick(3)
    assert c.eval("return _G.__nudged") == 1
    assert b.eval("return _G.__nudged") == 0           # answered
    assert d.eval("return _G.__nudged") == 0           # not asked
    assert b.eval("return ns.Polls:Nudge(...)", pid) is None   # only the asker nudges
    w.assert_no_errors()


@case
def a_team_target_asks_its_roster():
    w, (g, b, c, d, e) = guild()
    tid = g.eval_py("""
        local ok, id = ns.RaidPlan:SaveTeam(nil, "Main team", { ... })
        return ok and id or nil""", k(b), k(d))
    assert tid, tid
    w.tick(5)
    pid = post(g, "Team only", "yn", None, [["t", tid, False, "Main team"]])
    assert pid.startswith("p"), pid
    w.tick(5)
    assert visible(b) == [pid] and visible(d) == [pid]
    assert visible(c) == [] and visible(e) == []
    assert results(g, pid)["total"] == 2
    w.assert_no_errors()


@case
def the_asker_adds_people_and_removes_the_poll():
    w, (g, b, c, d, e) = guild(ranks={"Brakka": 1})
    pid = post(g, "Add more", "yn", None, [["p", k(b)]])
    w.tick(5)
    assert visible(c) == []
    assert g.eval("return ns.Polls:Edit(..., { add = { { 'p', select(2, ...) } } })", pid, k(c)) is True
    w.tick(5)
    assert visible(c) == [pid], visible(c)
    assert results(b, pid)["total"] == 2
    # Brakka (an officer, not the asker, not the GM) can't remove it; Gina can
    assert b.eval("return ns.Polls:Delete(...)", pid) is False
    assert g.eval("return ns.Polls:Delete(...)", pid) is True
    w.tick(5)
    for cl in (b, c, d):
        assert visible(cl) == [], cl.name
    w.assert_no_errors()


@case
def the_sheet_posts_and_the_banner_answers_yes_or_no():
    w, (g, b, c, d, e) = guild()
    ok = g.eval_py("""
        ns.MainFrame:Open("polls")
        ns.PollsUI:OpenNew()
        ns.PollsUI:SetDraft({ q = "Start earlier?", k = "yn", a = { { "g" } } })
        local sheet = ns.PollsUI:GetPanel().sheet
        sheet.post:Click()
        local st = ns.PollsUI:GetState()
        return { view = st.view, poll = st.poll, err = st.sheetErr }""")
    assert ok["view"] == "poll" and ok["poll"], ok
    w.tick(5)
    # Brakka's list leads with it in the banner: Yes on its answer bar
    out = b.eval_py("""
        ns.MainFrame:Open("polls")
        ns.PollsUI:ShowList("open")
        local v = ns.PollsUI:GetPanel().list
        local shown = v.hero:IsShown() and v.hero.pid
        local yes = v.hero.seg.buttons[1]
        local text = yes.fs:GetText()
        yes:Click()
        return { shown = shown, text = text, waiting = ns.Polls:WaitingCount() }""")
    assert out["shown"] == ok["poll"] and out["text"] == "Yes" and out["waiting"] == 0, out
    w.tick(5)
    assert results(g, ok["poll"])["counts"] == [1, 0]
    # on the poll's page the answer bar shows the pick and No changes it
    c.eval("ns.MainFrame:Open('polls'); ns.PollsUI:OpenPoll(...); ns.PollsUI:GetPanel().poll.ban.seg.buttons[2]:Click()",
           ok["poll"])
    w.tick(5)
    assert results(g, ok["poll"])["counts"] == [1, 1]
    # an empty sheet says what's missing and posts nothing
    err = g.eval_py("""
        ns.PollsUI:OpenNew()
        ns.PollsUI:SetDraft({ q = "", k = "one" })
        ns.PollsUI:GetPanel().sheet.post:Click()
        return ns.PollsUI:GetState().sheetErr""")
    assert err == "Write the question first.", err
    w.assert_no_errors()


@case
def the_notification_center_counts_and_pops_up_polls_not_the_page():
    w, (g, b, c, d, e) = guild()
    pid = post(g, "Pop-up?", "yn", None, [["p", k(b)], ["p", k(c)]])
    w.tick(5)
    # the page's own pop-up stays off: the notification center has the poll
    assert b.eval("local t = ns.PollsUI:GetToast(); return t and t:IsShown() or false") is False
    assert b.eval("return ns.Notify:Count({ page = 'polls' })") == 1
    assert d.eval("return ns.Notify:Count({ page = 'polls' })") == 0      # not asked
    assert vote(b, pid, [1])[0] is True
    w.tick(2)
    assert b.eval("return ns.Notify:Count({ page = 'polls' })") == 0
    w.assert_no_errors()


def post_many(c, qs, targets, **opts):
    """c posts a poll of several questions: its first question's id (or the error)."""
    code = """
        local qs, targets, cl, rv, ch = ...
        local id, why = ns.Polls:Create({ qs = qs, a = targets, cl = GetServerTime() + cl, rv = rv, ch = ch })
        return id or ("ERR " .. tostring(why))"""
    return c.eval(code, qs, targets, opts.get("cl", 3600), opts.get("rv", "live"), opts.get("ch", True))


def questions(c, pid):
    return c.eval_py("""
        local p = ns.Polls:GetPoll(...)
        if not p then return {} end
        local out = {}
        for i, q in ipairs(ns.Polls:Questions(p)) do out[i] = q and q.id or "" end
        return out""", pid)


@case
def a_poll_of_several_questions_goes_out_as_one_and_is_answered_question_by_question():
    """(1.4.1, feedback #7) Several questions in one poll: linked records (base-iofn), one row / one waiting count,
    answered one question at a time; close, nudge and remove act on the whole poll; a 1.4.0 client keeps the
    records unchanged (the link is in the ids)."""
    w, (g, b, c, d, e) = guild()
    days = g.eval_py("local t = GetServerTime(); return { date('%Y-%m-%d', t + 2 * 86400), "
                     "date('%Y-%m-%d', t + 3 * 86400) }")
    pid = post_many(g, [{"q": "A second raid night?", "k": "yn"},
                        {"q": "Which nights?", "k": "days", "o": days},
                        {"q": "What start time?", "k": "one", "o": ["19:00", "20:00"]}],
                    [["p", k(b)], ["p", k(c)]], cl=2 * 86400)
    assert pid.endswith("-1of3"), pid
    w.tick(5)
    qs = questions(b, pid)
    assert len(qs) == 3 and all(qs) and qs[1].endswith("-2of3"), qs
    # one poll on the lists and in the counts
    assert visible(b) == [pid], visible(b)
    assert b.eval("return ns.Polls:WaitingCount()") == 1
    assert b.eval("return ns.Notify:Count({ page = 'polls' })") == 1
    # every question is a plain poll with the same people and closing time
    for q in qs:
        r = results(g, q)
        assert r["total"] == 2, (q, r)
    # Brakka answers the first two: still waiting (one question left)
    assert vote(b, qs[0], [1])[0] is True
    assert vote(b, qs[1], [1, 2])[0] is True
    w.tick(3)
    assert b.eval("return ns.Polls:WaitingCount()") == 1
    assert b.eval_py("return { ns.Polls:AnsweredAllCount(ns.Polls:GetPoll(...)) }", pid)[:2] == [0, 2]
    assert vote(b, qs[2], [2])[0] is True
    w.tick(3)
    assert b.eval("return ns.Polls:WaitingCount()") == 0
    assert g.eval_py("return { ns.Polls:AnsweredAllCount(ns.Polls:GetPoll(...)) }", pid)[:2] == [1, 2]
    assert results(g, qs[2])["counts"] == [0, 1]
    # a nudge reaches Cora (nothing answered), not Brakka
    for cl in (b, c):
        cl.eval("_G.__nudged = nil; ns:On('POLL_NUDGED', function(id) _G.__nudged = id end)")
    assert g.eval("return (ns.Polls:Nudge(...))", qs[2]) == 1
    w.tick(3)
    assert c.eval("return _G.__nudged") == pid and b.eval("return _G.__nudged") is None
    # the page opens on the first question Cora hasn't answered; answering moves on to the next
    vote(c, qs[0], [2])
    w.tick(2)
    page = c.eval_py("""
        ns.MainFrame:Open('polls'); ns.PollsUI:OpenPoll(...)
        local s = ns.PollsUI:GetState()
        local first = s.poll
        ns.PollsUI:SetDays({ 1, 1 })
        ns.PollsUI:GetPanel().poll.grid.save:Click()
        local tabs = ns.PollsUI:GetPanel().poll.layout.tabs
        return { first = first, next = ns.PollsUI:GetState().poll, tabs = tabs:IsShown() }""", pid)
    assert page == {"first": qs[1], "next": qs[2], "tabs": True}, page
    # closing closes every question
    assert g.eval("return ns.Polls:Close(...)", pid) is True
    w.tick(3)
    for q in qs:
        assert b.eval("return ns.Polls:IsOpen(ns.Polls:GetPoll(...))", q) is False, q
    # removing removes every question
    assert g.eval("return ns.Polls:Delete(...)", pid) is True
    w.tick(3)
    assert visible(b) == [] and visible(g) == [], (visible(b), visible(g))
    w.assert_no_errors()


@case
def the_sheet_posts_several_questions_and_says_which_one_is_missing_something():
    w, (g, b, c, d, e) = guild()
    out = g.eval_py("""
        ns.MainFrame:Open('polls'); ns.PollsUI:OpenNew()
        ns.PollsUI:SetDraft({ q = "Second night?", k = "yn", a = { { "g" } } })
        ns.PollsUI:AddQuestion()
        local s = ns.PollsUI:GetState()
        local d = s.draft
        local second = d.cur
        d.q, d.k = "Start time?", "one"
        d.o = { "19:00", "" }
        ns.PollsUI:PostDraft()
        local err = s.sheetErr
        d.o[2] = "20:00"
        ns.PollsUI:SelectQuestion(1)
        local back = d.q
        ns.PollsUI:PostDraft()
        local p = ns.Polls:GetPoll(s.poll)
        local qs = {}
        for i, q in ipairs(ns.Polls:Questions(p)) do qs[i] = q and (q.k .. ":" .. q.q) or "" end
        return { second = second, err = err, back = back, qs = qs, view = s.view }""")
    assert out["second"] == 2 and out["back"] == "Second night?", out
    assert out["err"] == "Question 2: give at least two answers.", out
    assert out["qs"] == ["yn:Second night?", "one:Start time?"] and out["view"] == "poll", out
    w.assert_no_errors()


@case
def a_question_tab_closes_with_its_x_and_many_tabs_share_the_strip():
    w, (g, b, c, d, e) = guild()
    out = g.eval_py("""
        ns.MainFrame:Open('polls'); ns.PollsUI:OpenNew()
        ns.PollsUI:SetDraft({ q = "One?", k = "yn", a = { { "g" } } })
        local one = ns.PollsUI:GetPanel().sheet.layout.tabs:GetTab(1)
        local xAlone = one.x and one.x:IsShown() or false
        for i = 2, 5 do
            ns.PollsUI:AddQuestion()
            ns.PollsUI:GetState().draft.q = "Q" .. i .. "?"
        end
        local tabs = ns.PollsUI:GetPanel().sheet.layout.tabs
        local total, adds = 0, tabs:GetTab("add") and tabs:GetTab("add"):IsShown() or false
        for i = 1, 5 do total = total + tabs:GetTab(i):GetWidth() end
        -- close question 2 while question 5 is open: question 5 (now 4) stays open
        tabs:GetTab(2).x:Click()
        local s = ns.PollsUI:GetState()
        local words = {}
        for i, e in ipairs(s.draft.qs) do words[i] = i == s.draft.cur and s.draft.q or e.q end
        return { xAlone = xAlone, adds = adds, total = total, strip = tabs.fitWidth, cur = s.draft.cur,
                 words = words, n = #s.draft.qs }""")
    assert out["xAlone"] is False and out["adds"] is False, out      # one question: no x; five: no "+ Question"
    assert out["total"] <= out["strip"], out                          # the five tabs fit the strip
    assert out["n"] == 4 and out["cur"] == 4, out
    assert out["words"] == ["One?", "Q3?", "Q4?", "Q5?"], out
    w.assert_no_errors()

if __name__ == "__main__":
    run_all()

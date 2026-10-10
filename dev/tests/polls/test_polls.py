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
def the_sheet_posts_and_the_row_answers_yes_or_no():
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
    # Brakka answers from the list row: Yes is the second button from the right
    out = b.eval_py("""
        ns.MainFrame:Open("polls")
        ns.PollsUI:ShowList("open")
        local v = ns.PollsUI:GetPanel().list
        local row = v.rows[1]
        local yes = row.b2
        local text = yes:GetText()
        yes:Click()
        return { text = text, waiting = ns.Polls:WaitingCount() }""")
    assert out["text"] == "Yes" and out["waiting"] == 0, out
    w.tick(5)
    assert results(g, ok["poll"])["counts"] == [1, 0]
    # an empty sheet says what's missing and posts nothing
    err = g.eval_py("""
        ns.PollsUI:OpenNew()
        ns.PollsUI:SetDraft({ q = "", k = "one" })
        ns.PollsUI:GetPanel().sheet.post:Click()
        return ns.PollsUI:GetState().sheetErr""")
    assert err == "Write the question first.", err
    w.assert_no_errors()


@case
def the_pop_up_answers_and_waits_for_combat_and_the_notification_center():
    w, (g, b, c, d, e) = guild()
    pid = post(g, "Pop-up?", "yn", None, [["p", k(b)], ["p", k(c)], ["p", k(d)]])
    w.tick(5)
    shown = b.eval_py("local t = ns.PollsUI:GetToast(); return { t and t:IsShown() or false, t and t.pid or '' }")
    assert shown == [True, pid], shown
    b.eval("ns.PollsUI:GetToast().a:Click()")         # Yes
    w.tick(1)
    assert results(b, pid)["counts"][0] == 1
    # in combat it waits; afterwards it shows
    c.eval("InCombatLockdown = function() return true end; ns.PollsUI:HideToast()")
    pid2 = post(g, "In combat?", "yn", None, [["p", k(c)]])
    w.tick(5)
    assert c.eval("local t = ns.PollsUI:GetToast(); return t and t:IsShown() and t.pid == ... or false", pid2) is False
    c.eval("InCombatLockdown = function() return false end")
    c.fire("PLAYER_REGEN_ENABLED")
    w.tick(3)
    assert c.eval("local t = ns.PollsUI:GetToast(); return t and t:IsShown() and t.pid == ... or false", pid2) is True
    # with a notification center the polls page leaves the pop-ups to it
    d.eval("ns.Notify = ns.Notify or { stub = true }; local t = ns.PollsUI:GetToast(); if t then t:Hide() end")
    pid3 = post(g, "Notify?", "yn", None, [["p", k(d)]])
    w.tick(5)
    assert d.eval("local t = ns.PollsUI:GetToast(); return t and t:IsShown() and t.pid == ... or false", pid3) is False
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

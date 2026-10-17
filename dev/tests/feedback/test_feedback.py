"""Feedback to the developer (Core/Feedback.lua): members send bugs, ideas, changes and love; it travels through the
guild until it reaches Tsumil, who numbers it ("Tsumil has it"); everyone sees it and may say "me too"; staff (the
developer, the Guild Master, officers) answer and set a status; the changelog's fb numbers make it "Fixed in".

Run: luaenv\\Scripts\\python.exe tests\\feedback\\test_feedback.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import World, Client, case, run_all  # noqa: E402

REALM = "Thunderstrike"
F = "ns.Feedback"


def K(name):
    return "%s-%s" % (name, REALM)


def world(names, tick=3.0):
    """names: [(name, class, rank)] -> world, {name: client}; everyone loaded and logged in."""
    w = World()
    c = {}
    for name, cls, rank in names:
        c[name] = Client(w, name, class_file=cls, guild_rank=rank)
    for x in c.values():
        x.load_addon()
    w.tick(tick)
    return w, c


def standard():
    """Gina the GM, Olaf an officer, Tsumil the developer (a plain member), Alfa and Bert raiders."""
    return world([("Gina", "PALADIN", 0), ("Olaf", "WARRIOR", 1), ("Tsumil", "PALADIN", 3),
                  ("Alfa", "MAGE", 3), ("Bert", "ROGUE", 3)])


def submit(cl, kind, text, **opts):
    return cl.eval("local kind, text, opts = ...; local id, err = %s:Submit(kind, text, opts); return id or err" % F,
                   kind, text, opts)


def item(cl, id_):
    return cl.eval_py("local v = %s:Get(...); if not v then return nil end; return { id = v.id, no = v.no or false, "
                      "state = v.state or false, votes = v.voteCount, kind = v.kind, text = v.text, "
                      "replies = #v.replies, shipped = v.shipped or false, stage = %s:Stage(v), "
                      "author = v.author }" % (F, F), id_)


def fb_msgs(w, start=0):
    return [e for e in w.addon_log[start:] if e["prefix"] == "CDLb"]


def settle(w, seconds=40):
    w.tick(seconds, step=0.25)


@case
def a_member_s_bug_reaches_the_developer_who_numbers_it():
    w, c = standard()
    settle(w)
    id_ = submit(c["Alfa"], "bug", "The roll popup closed by itself when I entered combat.", about="Roll popup")
    assert id_ == K("Alfa") + "#1", id_
    w.tick(5, step=0.25)
    seen = item(c["Tsumil"], id_)
    assert seen and seen["no"] == 1 and seen["stage"] == 2, seen
    # the number comes back to everyone: "Tsumil has it"
    for name in ("Alfa", "Bert", "Gina"):
        v = item(c[name], id_)
        assert v and v["no"] == 1 and v["stage"] == 2, (name, v)
    w.assert_no_errors()


@case
def feedback_written_while_the_developer_is_offline_arrives_at_the_next_login():
    w, c = standard()
    settle(w)
    c["Tsumil"].logout()
    w.tick(5)
    id_ = submit(c["Alfa"], "idea", "Show who still needs a token on the boss tile.")
    w.tick(5)
    c["Alfa"].logout()          # the author is gone too: Bert carries it
    w.tick(5)
    assert item(c["Bert"], id_), "Bert holds it"
    c["Tsumil"].login()
    settle(w, 60)
    v = item(c["Tsumil"], id_)
    assert v and v["no"] == 1, v
    # Bert hears the number from Tsumil
    assert item(c["Bert"], id_)["no"] == 1
    w.assert_no_errors()


@case
def feedback_written_alone_spreads_when_the_guild_comes_online():
    w, c = standard()
    settle(w)
    for name in ("Gina", "Olaf", "Tsumil", "Bert"):
        c[name].logout()
    w.tick(5)
    id_ = submit(c["Alfa"], "change", "The swing timer bar is too tall.")
    w.tick(5)
    c["Bert"].login()            # Bert asks Alfa at login: Alfa tells the guild what Bert lacked
    settle(w, 60)
    assert item(c["Bert"], id_), "Bert got it at login"
    c["Alfa"].logout()
    c["Tsumil"].login()
    settle(w, 60)
    assert item(c["Tsumil"], id_)["no"] == 1
    w.assert_no_errors()


@case
def me_too_counts_once_per_member_and_not_for_the_author():
    w, c = standard()
    settle(w)
    id_ = submit(c["Alfa"], "idea", "Show who still needs a token on the boss tile.")
    w.tick(3)
    for name in ("Bert", "Gina", "Bert"):
        assert c[name].eval("return (%s:Vote(..., true))" % F, id_) is True
    assert c["Alfa"].eval("return select(2, %s:Vote(..., true))" % F, id_) == "it's your own"
    w.tick(3)
    assert item(c["Tsumil"], id_)["votes"] == 2
    c["Bert"].eval("%s:Vote(..., false)" % F, id_)
    w.tick(3)
    assert item(c["Tsumil"], id_)["votes"] == 1
    # "Yours" lists what I asked for and what I said me too to
    mine = c["Gina"].eval_py("local o = {} for _, v in ipairs(%s:List({ mine = true })) do o[#o + 1] = v.id end "
                             "return o" % F)
    assert mine == [id_], mine
    w.assert_no_errors()


@case
def staff_answer_and_set_a_status_members_can_not():
    w, c = standard()
    settle(w)
    id_ = submit(c["Alfa"], "idea", "Let me sort the loot log by item level.")
    w.tick(3)
    # a raider can't set a status
    ok = c["Bert"].eval("return select(2, %s:SetState(..., 'exists'))" % F, id_)
    assert ok == "only the officers and the developer set a status", ok
    # the officer answers: it already exists
    assert c["Olaf"].eval("return (%s:SetState(..., 'exists', { reply = 'Click the Item column header.' }))" % F,
                          id_) is True
    w.tick(3)
    v = item(c["Alfa"], id_)
    assert v["state"] == "exists" and v["replies"] == 1, v
    # the author answers back; a bystander can't
    assert c["Alfa"].eval("return (%s:Reply(..., 'Oh, thanks!'))" % F, id_)
    assert c["Bert"].eval("return select(2, %s:Reply(..., 'me neither'))" % F, id_) == \
        "only the author and the officers answer here"
    w.tick(3)
    assert item(c["Tsumil"], id_)["replies"] == 2
    w.assert_no_errors()


@case
def a_status_passed_on_by_a_raider_is_refused():
    w, c = standard()
    settle(w)
    id_ = submit(c["Alfa"], "bug", "Something is broken.")
    w.tick(3)
    # Bert makes up a "planned" by the developer and sends it on as if he passed it on
    c["Bert"].eval("""
      local id = ...
      local rec = { k = "s", i = id, a = "Tsumil-Thunderstrike", s = "planned", rv = GetServerTime() }
      ns.Comm:Send({ t = "FBN", r = { [id .. "!"] = rec } }, "GUILD", nil, "fb")""", id_)
    w.tick(3)
    assert item(c["Alfa"], id_)["state"] is False, item(c["Alfa"], id_)
    # the developer's own status is taken, and an officer may pass it on
    c["Tsumil"].eval("%s:SetState(..., 'planned')" % F, id_)
    w.tick(3)
    assert item(c["Alfa"], id_)["state"] == "planned"
    assert item(c["Alfa"], id_)["stage"] == 3
    w.assert_no_errors()


@case
def withdrawn_items_leave_every_list():
    w, c = standard()
    settle(w)
    id_ = submit(c["Alfa"], "idea", "A thing I changed my mind about.")
    w.tick(3)
    assert item(c["Bert"], id_)
    assert c["Bert"].eval("return select(2, %s:Withdraw(...))" % F, id_) == "not your item"
    assert c["Alfa"].eval("return (%s:Withdraw(...))" % F, id_) is True
    w.tick(3)
    assert item(c["Bert"], id_) is None
    assert item(c["Tsumil"], id_) is None
    w.assert_no_errors()


@case
def the_changelog_number_makes_it_fixed_in_and_credits_the_author():
    w, c = standard()
    settle(w)
    id_ = submit(c["Alfa"], "bug", "The roll popup closed by itself in combat.")
    w.tick(5)
    no = item(c["Tsumil"], id_)["no"]
    for cl in c.values():
        cl.eval("""local no = ...
          local e
          for _, x in ipairs(ns.CHANGELOG) do if x.version == ns.version then e = x end end
          table.insert(e.sections[1].lines, { "The roll popup waits until you leave combat.",
            fb = { no }, by = { "Alfa" }, k = "bug" })
          ns:Fire("CONFIG_UPDATED")""", no)
    v = item(c["Bert"], id_)
    assert v["shipped"] == c["Bert"].eval("return ns.version"), v
    assert v["stage"] == 4
    # Alfa is told, Bert isn't
    assert len(c["Alfa"].eval_py("return %s:UntoldShipped()" % F)) == 1
    assert c["Bert"].eval_py("return %s:UntoldShipped()" % F) == []
    # a me too counts as asking for it
    c["Bert"].eval("%s:Vote(..., true)" % F, id_)
    w.tick(3)
    assert len(c["Bert"].eval_py("return %s:UntoldShipped()" % F)) == 1
    w.assert_no_errors()


@case
def similar_items_are_suggested_while_typing():
    w, c = standard()
    settle(w)
    submit(c["Alfa"], "bug", "The roll popup closes when I enter combat.")
    submit(c["Alfa"], "idea", "Add a dark theme to the calendar.")
    w.tick(3)
    sim = c["Bert"].eval_py("local o = {} for _, v in ipairs(%s:Similar(...)) do o[#o + 1] = v.text end return o" % F,
                            "Roll popup hides itself in combat")
    assert sim == ["The roll popup closes when I enter combat."], sim
    assert c["Bert"].eval_py("return #%s:Similar(...)" % F, "Hello there") == 0
    w.assert_no_errors()


@case
def lua_errors_in_disasterzone_are_kept_for_a_bug():
    w, c = standard()
    a = c["Alfa"]
    a.eval("""ns.Feedback.NoteError("Interface/AddOns/DisasterZone/UI/RollFrame.lua:120: attempt to index nil",
                "Interface/AddOns/DisasterZone/UI/RollFrame.lua:120: in function <...>")""")
    a.eval("""ns.Feedback.NoteError("Interface/AddOns/OtherAddon/x.lua:1: boom", "")""")
    errs = a.eval_py("return ns.Feedback:GetErrors()")
    assert len(errs) == 1 and "RollFrame" in errs[0]["m"], errs
    id_ = a.eval("local e = ns.Feedback:RecentError(); return (ns.Feedback:Submit('bug', 'It broke', { err = e }))")
    w.tick(3)
    got = c["Tsumil"].eval_py("return ns.Feedback:Get(...).err", id_)
    assert got and "RollFrame" in got["m"] and "in function" in got["s"], got


PASTE = ("|cffff00001x|r DisasterZone/UI/Members.lua:233: attempt to compare nil with number\n"
         "[string \"@Interface/AddOns/DisasterZone/UI/Members.lua\"]:233: in function 'SortRows'\n"
         "\nLocals:\n\tname = \"Brakka\"\n")


@case
def a_pasted_error_travels_whole_and_plain():
    w, c = standard()
    settle(w)
    long_tail = "\n".join("(*temporary) = %d" % i for i in range(120))   # past the 900-char stack cap
    id_ = submit(c["Alfa"], "bug", "Members tab broke when sorting.", paste=PASTE + long_tail)
    assert "#" in id_, id_
    w.tick(5, step=0.25)
    got = c["Tsumil"].eval_py("return ns.Feedback:Get(...).err", id_)
    assert got, "the item and its error reach the developer"
    assert got["m"] == "1x DisasterZone/UI/Members.lua:233: attempt to compare nil with number", got["m"]
    assert "|c" not in got["p"] and "|r" not in got["p"], "colour codes are taken out"
    assert "    name = " in got["p"], "tabs become spaces"
    assert len(got["p"]) > 900 and "(*temporary) = 119" in got["p"], len(got["p"])
    assert c["Tsumil"].eval("return ns.Feedback:ErrorText(ns.Feedback:Get(...))", id_) == got["p"]
    # past the cap it is cut, not refused; an idea never carries one
    big = submit(c["Bert"], "bug", "Huge error.", paste="x" * 5000)
    idea = submit(c["Bert"], "idea", "An idea.", paste=PASTE)
    w.tick(5, step=0.25)
    assert len(c["Tsumil"].eval_py("return ns.Feedback:Get(...).err.p", big)) == 3000
    assert c["Tsumil"].eval("return ns.Feedback:Get(...).err == nil", idea) is True
    w.assert_no_errors()


@case
def a_record_with_a_paste_too_long_is_refused():
    w, c = standard()
    settle(w)
    for n, size in ((7, 3001), (8, 3000)):
        c["Alfa"].eval("""local a, n, size = ...
          local now = GetServerTime()
          local rec = { k = "i", a = a, n = n, kd = "bug", x = "x", t = now, rv = now,
                        e = { m = "boom", p = string.rep("y", size) } }
          ns.Comm:Send({ t = "FBN", r = { [a .. "#" .. n] = rec } }, "GUILD", nil, "fb")""", K("Alfa"), n, size)
    w.tick(3)
    assert item(c["Tsumil"], K("Alfa") + "#7") is None
    assert item(c["Tsumil"], K("Alfa") + "#8") is not None
    w.assert_no_errors()


# --- Lua errors that report themselves -------------------------------------------------------------------------

ERR = "Interface/AddOns/DisasterZone/UI/RollFrame.lua:120: attempt to index field 'session' (a nil value)"
STACK = "[string \"@Interface/AddOns/DisasterZone/UI/RollFrame.lua\"]:120: in function 'Refresh'"
REPORT_WAIT = 45        # AUTO_DELAY + AUTO_SPREAD and a bit


def note(cl, msg=ERR, locals_=None):
    cl.eval("local m, s, l = ...; ns.Feedback.NoteError(m, s, nil, l)", msg, STACK, locals_)


def bugs(cl):
    return cl.eval_py("local o = {} for _, v in ipairs(%s:List({ kind = 'bug' })) do o[#o + 1] = { id = v.id, "
                      "auto = v.auto, text = v.text, about = v.about or false, votes = v.voteCount, "
                      "author = v.author } end return o" % F)


def last_error(cl):
    return cl.eval_py("local e = %s:GetErrors(); e = e[#e]; return e and { f = e.f or false, how = e.how or false, "
                      "x = e.x or false } or false" % F)


def popup(cl):
    """The notification center's error item: { text, how } or None."""
    return cl.eval_py("local e = %s:GetErrors(); e = e[#e]; local it = e and ns.Notify:Get('feedbackError\\1' .. e.m) "
                      "return it and { text = it.text, how = it.data and it.data.how or false } or nil" % F)


@case
def a_lua_error_reports_itself_with_what_was_going_on():
    w, c = standard()
    settle(w)
    a = c["Alfa"]
    a.eval("ns:Trail('page raids'); ns:Trail('/dz raid'); ns:Trail('/dz raid')")
    note(a, locals_="self = <table> {\n}\n")
    assert popup(a) is None, "no Report it pop-up: the report goes by itself"
    w.tick(REPORT_WAIT, step=0.5)
    mine = bugs(a)
    assert len(mine) == 1 and mine[0]["auto"], mine
    assert mine[0]["text"].startswith("Lua error: attempt to index field 'session' (a nil value)"), mine[0]["text"]
    assert mine[0]["about"] == "UI/RollFrame.lua:120", mine[0]["about"]
    got = c["Tsumil"].eval_py("local v = %s:Get(...); return { no = v.no or false, auto = v.auto, err = v.err }" % F,
                              mine[0]["id"])
    assert got["no"] and got["auto"], got
    assert got["err"]["m"] == ERR, got["err"]["m"]
    p = got["err"]["p"]
    for part in ("1x " + ERR, "in function 'Refresh'", "What was going on:", "In combat: no", "/dz raid (x2)",
                 "Locals:", "self = <table>", "Other addons"):
        assert part in p, (part, p)
    # the player is told, with their report to add to; a bug written by hand doesn't take the error again
    assert popup(a) == {"text": "It went to the developer by itself, with what was going on. Add what you were doing?",
                        "how": "filed"}, popup(a)
    assert a.eval("return %s:RecentError() == nil" % F) is True
    # it happens again: no second report
    note(a)
    w.tick(REPORT_WAIT, step=0.5)
    assert len(bugs(c["Tsumil"])) == 1
    w.assert_no_errors()


@case
def the_same_error_from_another_member_is_a_me_too():
    w, c = standard()
    settle(w)
    note(c["Alfa"])
    w.tick(REPORT_WAIT, step=0.5)
    note(c["Bert"], "1x DisasterZone/UI/RollFrame.lua:120: attempt to index field 'session' (a nil value)")
    w.tick(REPORT_WAIT, step=0.5)
    seen = bugs(c["Tsumil"])
    assert len(seen) == 1 and seen[0]["author"] == K("Alfa") and seen[0]["votes"] == 1, seen
    assert last_error(c["Bert"])["how"] == "joined"
    assert popup(c["Bert"])["how"] == "joined", popup(c["Bert"])
    w.assert_no_errors()


@case
def the_developer_s_errors_and_a_switched_off_report_stay_out():
    w, c = standard()
    settle(w)
    note(c["Tsumil"])                           # (BugSack shows them to the developer)
    c["Bert"].eval("ns.DB:SetSetting('feedbackAuto', false)")
    note(c["Bert"])
    w.tick(REPORT_WAIT, step=0.5)
    assert bugs(c["Gina"]) == [], bugs(c["Gina"])
    # Bert is offered the form at once, the error goes with it
    assert popup(c["Bert"]) == {"text": "Report what you were doing? The error goes with it.", "how": False}
    assert c["Bert"].eval("return %s:RecentError().m" % F) == ERR
    w.assert_no_errors()


@case
def three_reports_a_session_at_most():
    w, c = standard()
    settle(w)
    for i in range(4):
        note(c["Alfa"], "Interface/AddOns/DisasterZone/UI/X%d.lua:%d: boom" % (i, i + 1))
    w.tick(REPORT_WAIT, step=0.5)
    assert len(bugs(c["Tsumil"])) == 3
    # the fourth is left for the form
    assert last_error(c["Alfa"]) == {"f": False, "how": False, "x": "enough"}, last_error(c["Alfa"])
    assert popup(c["Alfa"])["how"] is False
    w.assert_no_errors()


@case
def an_error_fixed_in_a_newer_release_is_not_reported_again():
    w, c = standard()
    settle(w)
    note(c["Alfa"])
    w.tick(REPORT_WAIT, step=0.5)
    no = c["Tsumil"].eval_py("return %s:List({ kind = 'bug' })[1].no" % F)
    c["Bert"].eval("""table.insert(ns.CHANGELOG, 1, { version = "99.0.0", sections = { { lines = {
        { "The roll popup no longer errors.", fb = { ... }, k = "bug" } } } } })
      ns:Fire("CONFIG_UPDATED")""", no)
    note(c["Bert"])
    w.tick(REPORT_WAIT, step=0.5)
    assert last_error(c["Bert"])["how"] == "fixed"
    assert popup(c["Bert"])["text"] == "It's fixed in 99.0.0: update DisasterZone to get it.", popup(c["Bert"])
    assert bugs(c["Tsumil"])[0]["votes"] == 0
    w.assert_no_errors()


@case
def an_error_before_a_reload_is_reported_after_it_an_old_version_s_is_not():
    w, c = standard()
    settle(w)
    a = c["Alfa"]
    note(a)
    note(a, "Interface/AddOns/DisasterZone/UI/Old.lua:1: from an older release")
    a.eval("ns.db.feedbackErrors[2].v = '0.0.1'")
    w.tick(2)
    a.logout()                                  # (before its report went out)
    w.tick(5)
    a.login()
    w.tick(40 + REPORT_WAIT, step=0.5)          # (the login look, then the report)
    seen = bugs(c["Tsumil"])
    assert [b["about"] for b in seen] == ["UI/RollFrame.lua:120"], seen
    w.assert_no_errors()


@case
def an_error_reports_itself_in_demo_mode_without_sending_it():
    w, c = standard()
    settle(w)
    t = c["Tsumil"]
    t.eval("ns.Demo:SetEnabled(true)")
    note(t)
    w.tick(REPORT_WAIT, step=0.5)
    demo = bugs(t)
    assert any(b["auto"] and b["author"] == K("Tsumil") for b in demo), demo
    t.eval("ns.Demo:SetEnabled(false)")
    assert bugs(t) == [] and bugs(c["Gina"]) == [], "demo reports stay in the demo list"
    w.assert_no_errors()


# --- DisasterZone's errors never reach the screen (Core/Init.lua, "Errors") ------------------------------------

DZ_STACK = "[string \"@Interface/AddOns/DisasterZone/UI/Y.lua\"]:5: in function <...>"
OWNS = [
    ("Interface/AddOns/DisasterZone/UI/X.lua:1: boom", "", True),
    ("Interface\\AddOns\\DisasterZone_Rooms\\Rooms.lua:3: boom", "", True),
    ("DisasterZone/UI/X.lua:9: boom", "", True),
    # another addon's error, even with our code further down
    ("Interface/AddOns/OtherAddon/x.lua:1: boom", DZ_STACK, False),
    # the game's code: the first addon down the stack decides
    ("Interface/FrameXML/UIParent.lua:100: bad argument",
     "[string \"@Interface/FrameXML/UIParent.lua\"]:100: in function 'X'\n[C]: ?\n" + DZ_STACK, True),
    ("Interface/SharedXML/Util.lua:7: bad",
     "[string \"@Interface/SharedXML/Util.lua\"]:7: in function 'Y'\n"
     "[string \"@Interface/AddOns/OtherAddon/z.lua\"]:2: in function <...>\n" + DZ_STACK, False),
    ("[ADDON_ACTION_BLOCKED] AddOn 'DisasterZone' tried to call the protected function 'CastSpellByName()'.", None, True),
    ("[ADDON_ACTION_FORBIDDEN] AddOn 'OtherAddon' tried to call the protected function 'X'.", None, False),
    # a /run line that only says our name
    ('[string "error(\\"DisasterZone test\\")"]:1: DisasterZone test', '[string "error(\\"DisasterZone t..."]:1: in main chunk',
     False),
]


def shown_where(cl):
    """Where each recorded error went: 'caught by DisasterZone' (the harness's tap: kept off the screen) or the
    game's handler ('geterrorhandler()': on screen)."""
    return cl.eval_py("local o = {} for _, e in ipairs(__MOCK.errors) do o[#o + 1] = e.where end return o")


def noted(cl):
    return [e["m"] for e in cl.eval_py("return %s:GetErrors()" % F)]


@case
def an_error_is_ours_by_where_it_happened():
    w, c = standard()
    a = c["Alfa"]
    for msg, stack, ours in OWNS:
        assert a.eval("return ns.OwnsError(...)", msg, stack) is ours, (msg, ours)
    w.assert_no_errors()


@case
def our_errors_never_reach_the_screen_other_addons_errors_do():
    w, c = standard()
    settle(w)
    a = c["Alfa"]
    assert a.eval("return ns:ErrorMode()") == "handler"
    a.eval("geterrorhandler()('Interface/AddOns/DisasterZone/UI/X.lua:1: boom')")
    # an error inside one of our message handlers (our protected calls catch it themselves)
    a.eval("ns:On('POLL_ANSWERED', ns.Feedback.Report); ns:Fire('POLL_ANSWERED')")
    a.eval("geterrorhandler()('Interface/AddOns/OtherAddon/x.lua:1: theirs')")
    assert shown_where(a) == ["caught by DisasterZone", "caught by DisasterZone", "geterrorhandler()"], shown_where(a)
    got = noted(a)
    assert len(got) == 2 and "UI/X.lua:1: boom" in got[0] and "Core/Feedback.lua" in got[1], got
    w.clear_errors()


@case
def the_developer_still_sees_theirs_unless_in_demo_mode():
    w, c = standard()
    settle(w)
    t = c["Tsumil"]
    t.eval("geterrorhandler()('Interface/AddOns/DisasterZone/UI/X.lua:1: boom')")
    assert "geterrorhandler()" in shown_where(t) and noted(t) == [], shown_where(t)
    t.eval("ns.Demo:SetEnabled(true)")
    w.clear_errors()
    t.eval("geterrorhandler()('Interface/AddOns/DisasterZone/UI/X.lua:2: bang')")
    assert shown_where(t) == ["caught by DisasterZone"] and len(noted(t)) == 1, (shown_where(t), noted(t))
    t.eval("ns.Demo:SetEnabled(false)")
    w.clear_errors()


@case
def errortest_raises_one_of_ours_in_demo_mode_only():
    w, c = standard()
    settle(w)
    a = c["Alfa"]
    assert a.slash("/dz errortest")
    w.tick(1)
    assert w.errors() == []
    a.eval("ns.Demo:SetEnabled(true)")
    a.slash("/dz errortest")
    w.tick(1)
    errs = a.eval_py("local o = {} for _, e in ipairs(__MOCK.errors) do o[#o + 1] = e.msg end return o")
    assert len(errs) == 1 and "errortest" in errs[0] and a.eval("return ns.OwnsError(...)", errs[0]) is True, errs
    a.eval("ns.Demo:SetEnabled(false)")
    w.clear_errors()


# BugGrabber keeps the game's error handler (seterrorhandler does nothing after it), lists errors and tells
# EventRegistry; BugSack counts what it would show. The registry is the game's: [type][event][owner] = fn.
BUGSACK_WORLD = r"""
local reg = { callbackTables = { {}, {} } }
function reg:GetCallbackTables() return self.callbackTables end
function reg:RegisterCallback(event, func, owner)
  owner = owner or {}
  local t = self.callbackTables[2]
  t[event] = t[event] or {}
  t[event][owner] = func
  return owner
end
function reg:UnregisterCallback(event, owner) local t = self.callbackTables[2][event]; if t then t[owner] = nil end end
function reg:TriggerEvent(event, ...)
  for _, byType in ipairs(self.callbackTables) do
    local list = byType[event]
    if list then for owner, fn in pairs(list) do fn(owner, ...) end end
  end
end
EventRegistry = reg
local db = {}
BugGrabber = { GetDB = function() return db end }
seterrorhandler(function(msg)
  local e = { message = tostring(msg), stack = debugstack(3), counter = 1 }
  db[#db + 1] = e
  reg:TriggerEvent("BugGrabber.BugGrabbed", tostring(e))
  return msg
end)
seterrorhandler = function() end
SACK = { shown = 0 }
reg:RegisterCallback("BugGrabber.BugGrabbed", function(_, id) SACK.shown = SACK.shown + 1 end, {})
"""


@case
def with_bugsack_ours_leave_its_list_and_alert_theirs_stay():
    w = World()
    c = {}
    for name, cls, rank in (("Gina", "PALADIN", 0), ("Tsumil", "PALADIN", 3), ("Alfa", "MAGE", 3)):
        c[name] = Client(w, name, class_file=cls, guild_rank=rank)
    a = c["Alfa"]
    a.eval(BUGSACK_WORLD)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    assert a.eval("return ns:ErrorMode()") == "buggrabber"
    a.eval("geterrorhandler()('Interface/AddOns/DisasterZone/UI/X.lua:1: boom')")
    assert a.eval_py("return { SACK.shown, #BugGrabber:GetDB() }") == [0, 0]
    assert len(noted(a)) == 1
    a.eval("geterrorhandler()('Interface/AddOns/OtherAddon/x.lua:1: theirs')")
    assert a.eval_py("return { SACK.shown, #BugGrabber:GetDB() }") == [1, 1]
    # a display that registers after DisasterZone loaded says so, and skips ours too
    a.eval("EventRegistry:RegisterCallback('BugGrabber.BugGrabbed', function() SACK.late = (SACK.late or 0) + 1 end, {}) "
           "EventRegistry:TriggerEvent('BugGrabber.DisplayRegistered')")
    a.eval("geterrorhandler()('Interface/AddOns/DisasterZone/UI/Y.lua:2: bang')")
    assert a.eval_py("return { SACK.shown, SACK.late or 0, #BugGrabber:GetDB() }") == [1, 0, 1]
    assert len(noted(a)) == 2
    w.clear_errors()


if __name__ == "__main__":
    run_all()

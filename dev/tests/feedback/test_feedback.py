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


if __name__ == "__main__":
    run_all()

"""The Events tab (UI/EventsTab.lua) on the real addon: Upcoming, an event's page, results, Library, Season, Review
and the sheets other modules open (host it, send it for review, the badge designer).

Covers: the tab shows in a guild (and in demo mode), not without one; every view and sheet renders in demo mode
without errors (the live cup on the banner with Watch and my next match, the planned cup's page with Join, last
week's results with the podium, the library's cards and their hover actions, the standings, the review of my own
event); Join / Leave on an event's page reach another client and the host gets Start; the schedule sheet puts an
event on the calendar (and moves it); the review view ranks an event for a reviewer, a member has no Review tab and
Send back asks for a reason; the badge designer hands its badge to onSave (new and edited), Escape closes it.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_events_tab.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

HELLO = 50
CLASSES = ["PALADIN", "MAGE", "ROGUE", "WARRIOR", "PRIEST", "DRUID", "HUNTER", "SHAMAN", "WARLOCK"]


def guild(names, tick=HELLO):
    w = World()
    cs = []
    for i, n in enumerate(names):
        cs.append(Client(w, n, guild_rank=0 if i == 0 else 3, class_file=CLASSES[i % len(CLASSES)]))
    for c in cs:
        c.load_addon()
    w.tick(tick)
    return w, cs


def K(name):
    return name + "-Thunderstrike"


def schedule_starter(host, at_offset=3600):
    """The host saves the starter event and puts it on the calendar: (defId, occId)."""
    return host.eval_py("""
        local d = ns.Events:NewDef(true)
        assert(ns.Events:SaveDef(d), "save")
        local occ = ns.Events:Schedule(d.id, GetServerTime() + ...)
        return { d.id, occ }""", at_offset)


def banner(c, field="btn"):
    """A button of the event page's banner: its text when shown, else None."""
    return c.eval_py("local v = ns.EventsUI:GetViewFrame('event'); local b = v and v.ban[...]; "
                     "return b and b:IsShown() and b:GetText() or nil", field)


@case
def the_tab_shows_in_a_guild_and_not_without_one():
    w = World()
    g = Client(w, "Gina", guild_rank=0, class_file="PALADIN")
    lone = Client(w, "Lone", guild=None, class_file="MAGE")
    g.load_addon()
    lone.load_addon()
    w.tick(3)
    g.eval("ns.MainFrame:Open('events')")
    w.tick(0.3)
    assert g.eval_py("return ns.MainFrame:GetSelectedTab()") == "events"
    assert g.eval_py("return ns.EventsUI:GetPanel():IsVisible()") is True
    # the views' tabs; no event waits for a review: the Review tab is there (the GM reviews) without a count
    tabs = g.eval_py("local p = ns.EventsUI:GetPanel(); local out = {}; for k, t in pairs(p.tabs) do "
                     "out[k] = t:IsShown() end; return out")
    assert tabs == {"upcoming": True, "library": True, "season": True, "review": True}, tabs
    assert g.eval_py("return ns.EventsUI:GetPanel().tabs.review.cnt:IsShown()") is False
    # nothing on the calendar: the banner says so and its one button goes to the Library
    hero = g.eval_py("local h = ns.EventsUI:GetViewFrame('upcoming').hero; return { h.title:GetText(), h.btn:GetText() }")
    assert hero == ["Nothing on the calendar", "Library"], hero
    g.eval("ns.EventsUI:GetViewFrame('upcoming').hero.btn:Click()")
    assert g.eval_py("return ns.EventsUI:GetView()") == "library"
    # outside a guild there is no Events tab (demo mode shows it)
    lone.eval("ns.MainFrame:Open('events')")
    w.tick(0.3)
    assert lone.eval_py("return ns.MainFrame:GetSelectedTab()") != "events"
    lone.slash("/dz demo on")
    w.tick(1)
    lone.eval("ns.MainFrame:Open('events')")
    w.tick(0.3)
    assert lone.eval_py("return ns.MainFrame:GetSelectedTab()") == "events"
    w.assert_no_errors()


@case
def every_view_and_sheet_renders_in_demo_mode():
    w = World()
    g = Client(w, "Gina", guild_rank=0, class_file="PALADIN")
    g.load_addon()
    w.tick(3)
    g.slash("/dz demo on")
    w.tick(1)
    assert g.eval_py("return ns.EventsUI:Open('upcoming')") is True
    w.tick(0.3)
    # the banner: the live cup, its round, my next match, Watch
    hero = g.eval_py("""
        local h = ns.EventsUI:GetViewFrame('upcoming').hero
        return { title = h.title:GetText(), kick = h.kick:GetText(), btn = h.btn:GetText(), live = h.live:IsShown(),
                 chip = h.chip:IsShown() and h.chip.fs:GetText() or nil }""")
    assert hero["title"] == "Friday duel cup" and hero["btn"] == "Watch" and hero["live"] is True, hero
    assert hero["kick"].startswith("ROUND 2 OF"), hero
    assert hero["chip"] and "up next" in hero["chip"], hero
    # the week's rows and the season card (me in the top five's last place when further down)
    rows = g.eval_py("local v = ns.EventsUI:GetViewFrame('upcoming'); local out = {}; for _, r in ipairs(v.rows) do "
                     "if r:IsShown() then out[#out + 1] = r.l1:GetText() end end; return out")
    assert "2v2 arena cup" in rows and "Ring of Blood night" in rows and "Friday duel cup" in rows, rows
    me = g.eval_py("local s = ns.EventsUI:GetViewFrame('upcoming').card; local out; for _, r in ipairs(s.rows) do "
                   "if r:IsShown() and r.bg:IsShown() then out = r.n:GetText() end end; return out")
    assert me and "You" in me, me
    # a planned event's page: Join; the live one's: Watch; last week's results: the podium
    assert g.eval_py("return ns.EventsUI:OpenEvent('odemo2')") is True
    w.tick(0.3)
    assert banner(g) == "Join"
    stages = g.eval_py("local v = ns.EventsUI:GetViewFrame('event'); local n = 0; for _, r in ipairs(v.stages) do "
                       "if r:IsShown() then n = n + 1 end end; return n")
    assert stages == 2, stages
    g.eval("ns.EventsUI:OpenEvent('odemo1')")
    w.tick(0.3)
    assert banner(g) == "Watch"
    g.eval("ns.EventsUI:OpenEvent('rdemo1')")
    w.tick(0.3)
    res = g.eval_py("""
        local v = ns.EventsUI:GetViewFrame('event')
        local f = v.res
        local peds = 0
        for _, p in ipairs(f.peds) do if p:IsShown() then peds = peds + 1 end end
        local awards = 0
        for _, a in ipairs(f.awards) do if a:IsShown() then awards = awards + 1 end end
        return { mode = v.mode, peds = peds, awards = awards, l4 = f.l4:IsShown(), mom = f.mom:IsShown() }""")
    assert res == {"mode": "results", "peds": 3, "awards": 3, "l4": True, "mom": True}, res
    # the back link
    g.eval("ns.EventsUI:GetViewFrame('event').ban.back:Click()")
    assert g.eval_py("return ns.EventsUI:GetView()") == "upcoming"
    # the library: four cards; the hovered one shows Host / Copy and hides its smart blocks
    g.eval("ns.EventsUI:Open('library'); ns.EventsUI:SetLibraryHover('edemo1')")
    w.tick(0.3)
    lib = g.eval_py("""
        local v = ns.EventsUI:GetViewFrame('library')
        local names, acts = {}, nil
        for _, c in ipairs(v.cards) do
          if c:IsShown() then
            names[#names + 1] = c.n:GetText()
            if c.def.id == 'edemo1' then acts = { c.acts:IsShown(), c.host:IsShown(), c.edit:IsShown(), c.minis[1]:IsShown() } end
          end
        end
        return { names = names, acts = acts }""")
    assert len(lib["names"]) == 4 and lib["names"][0] == "Friday duel cup", lib
    assert lib["acts"] == [True, True, False, False], lib
    # Mine: only my Hide and seek; a search that matches nothing
    g.eval("ns.EventsUI:GetViewFrame('library').filters.mine:Click()")
    w.tick(0.3)
    mine = g.eval_py("local out = {}; for _, c in ipairs(ns.EventsUI:GetViewFrame('library').cards) do "
                     "if c:IsShown() then out[#out + 1] = c.n:GetText() end end; return out")
    assert mine == ["Hide and seek in Shattrath"], mine
    g.eval("ns.EventsUI:GetState().lib = 'guild'; ns.EventsUI:GetState().q = 'zzz'; ns.EventsUI:Refresh()")
    assert g.eval_py("return ns.EventsUI:GetViewFrame('library').empty:IsShown()") is True
    g.eval("ns.EventsUI:GetState().q = ''")
    # the season: the standings, me highlighted
    g.eval("ns.EventsUI:Open('season')")
    w.tick(0.3)
    sea = g.eval_py("""
        local v = ns.EventsUI:GetViewFrame('season')
        local n, mine = 0, nil
        for _, r in ipairs(v.rows) do
          if r:IsShown() then n = n + 1; if r.bg:IsShown() then mine = r.rk:GetText() end end
        end
        return { n = n, mine = mine, rk = v.you.rk:GetText() }""")
    assert sea["n"] >= 10 and sea["mine"] is not None and str(sea["mine"]) == str(sea["rk"]), sea
    # the review: my Hide and seek waits; the two ranked ones are decided
    g.eval("ns.EventsUI:Open('review')")
    w.tick(0.3)
    rv = g.eval_py("""
        local v = ns.EventsUI:GetViewFrame('review')
        local n = 0
        for _, r in ipairs(v.qrows) do if r:IsShown() then n = n + 1 end end
        return { n = n, pick = ns.EventsUI:GetState().review, rank = v.head.rank:IsShown(),
                 count = ns.EventsUI:GetPanel().tabs.review.cnt.fs:GetText() }""")
    assert rv == {"n": 3, "pick": "edemo3", "rank": True, "count": "1"}, rv
    # the sheets
    for lua, key in (("ns.EventsUI:OpenSchedule('edemo1')", "schedule"), ("ns.EventsUI:OpenSubmit('edemo3')", "submit"),
                     ("ns.EventsUI:OpenBadgeDesigner(ns.Events:GetDef('edemo1'), 'champ', function() end)", "badge"),
                     ("ns.EventsUI:OpenSeasonSheet()", "season"), ("ns.EventsUI:ConfirmCancel('odemo2')", "confirm")):
        g.eval("ns.EventsUI:CloseSheets(); " + lua)
        w.tick(0.2)
        assert g.eval_py("local f = ns.EventsUI:GetSheet(...); return f and f:IsShown() and f.dim:IsShown()", key), key
    g.eval("ns.EventsUI:CloseSheets()")
    w.assert_no_errors()


@case
def join_and_leave_on_an_event_page_reach_another_client():
    w, cs = guild(["Gina", "Bert"])
    gina, bert = cs
    _, occ = schedule_starter(gina, 3600)
    w.tick(5)
    assert bert.eval_py("return ns.EventsUI:OpenEvent(...)", occ) is True
    w.tick(0.3)
    assert banner(bert) == "Join"
    assert banner(bert, "btn2") is None
    bert.eval("ns.EventsUI:GetViewFrame('event').ban.btn:Click()")
    w.tick(3)
    assert gina.eval_py("return ns.Events:GetSignups(...)", occ) == [K("Gina"), K("Bert")]
    assert banner(bert) == "Leave"
    # his own face in the entrants' grid (seeded: nobody has a rank yet, sign-up order)
    ents = bert.eval_py("local out = {}; for _, e in ipairs(ns.EventsUI:GetViewFrame('event').ents) do "
                        "if e:IsShown() and e.face.key then out[#out + 1] = e.face.key end end; return out")
    assert ents == [K("Gina"), K("Bert")], ents
    bert.eval("ns.EventsUI:GetViewFrame('event').ban.btn:Click()")
    w.tick(3)
    assert gina.eval_py("return ns.Events:GetSignups(...)", occ) == [K("Gina")]
    assert banner(bert) == "Join"
    # the host: Start, and Leave beside it (she is in it)
    gina.eval("ns.EventsUI:OpenEvent(...)", occ)
    w.tick(0.3)
    assert banner(gina) == "Start" and banner(gina, "btn2") == "Leave"
    w.assert_no_errors()


@case
def the_schedule_sheet_puts_an_event_on_the_calendar():
    w, cs = guild(["Gina", "Bert"])
    gina, bert = cs
    def_id = gina.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); return d.id")
    w.tick(3)
    gina.eval("ns.EventsUI:Open('library')")
    w.tick(0.3)
    assert gina.eval_py("return ns.EventsUI:OpenSchedule(...)", def_id) is True
    assert gina.eval_py("return ns.EventsUI:GetSheet('schedule').ok:GetText()") == "Put it on the calendar"
    gina.eval("ns.EventsUI:SetSchedule({ day = 1, mins = 20 * 60, where = 'Ring of Trials', note = 'bring a flask' })")
    occ = gina.eval_py("return ns.EventsUI:SubmitSchedule()")
    assert isinstance(occ, str), occ
    expect = gina.eval_py("local t = date('*t', GetServerTime()); return time({ year = t.year, month = t.month, "
                          "day = t.day + 1, hour = 20, min = 0, sec = 0 })")
    w.tick(3)
    o = bert.eval_py("local o = ns.Events:GetOcc(...); return o and { at = o.at, where = o.where, note = o.note, "
                     "h = o.h } or nil", occ)
    assert o == {"at": expect, "where": "Ring of Trials", "note": "bring a flask", "h": K("Gina")}, o
    # the sheet closed and the host's tab shows the new event's page
    assert gina.eval_py("return ns.EventsUI:GetSheet('schedule'):IsShown()") is False
    assert gina.eval_py("return ns.EventsUI:GetView()") == "event"
    assert gina.eval_py("return ns.EventsUI:GetState().occ") == occ
    # the host moves it an hour later (More > Edit opens the same sheet)
    gina.eval("ns.EventsUI:OpenSchedule(...)", def_id, occ)
    assert gina.eval_py("return ns.EventsUI:GetSheet('schedule').ok:GetText()") == "Save"
    assert gina.eval_py("return ns.EventsUI:GetSheet('schedule').where:GetText()") == "Ring of Trials"
    gina.eval("ns.EventsUI:SetSchedule({ mins = 21 * 60 })")
    assert gina.eval_py("return ns.EventsUI:SubmitSchedule()") == occ
    w.tick(3)
    assert bert.eval_py("return ns.Events:GetOcc(...).at", occ) == expect + 3600
    # someone else's calendar event can't be moved
    bert.eval("ns.MainFrame:Open('events')")
    w.tick(0.3)
    bert.eval("ns.EventsUI:OpenSchedule(...)", def_id, occ)
    assert bert.eval_py("return ns.EventsUI:SubmitSchedule()") is False
    assert bert.eval_py("return ns.EventsUI:GetSheet('schedule').err:GetText()") == "Only its host can move it."
    w.assert_no_errors()


@case
def the_review_view_ranks_an_event_for_a_reviewer():
    w, cs = guild(["Gina", "Bert"])
    gina, bert = cs
    def_id = bert.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); return d.id")
    w.tick(3)
    # Bert sends it in from the sheet, with a note
    bert.eval("ns.MainFrame:Open('events')")
    w.tick(0.3)
    assert bert.eval_py("return ns.EventsUI:OpenSubmit(...)", def_id) is True
    checks = bert.eval_py("local out = {}; for _, r in ipairs(ns.EventsUI:GetSheet('submit').rows) do "
                          "out[#out + 1] = r.fs:GetText() end; return out")
    assert checks[1:] == ["Every blank is filled", "Guild chat stays under the limit", "Points stay under the season cap"], checks
    bert.eval("ns.EventsUI:GetSheet('submit').note:SetText('the final is best of 5 now')")
    assert bert.eval_py("return ns.EventsUI:SubmitReview()") is True
    w.tick(3)
    # a member has no Review tab
    assert bert.eval_py("return ns.EventsUI:GetPanel().tabs.review:IsShown()") is False
    # the GM's Review: it waits, with its note; Mark ranked
    assert gina.eval_py("return ns.Events:ReviewState(ns.Events:GetDef(...))", def_id) == "review"
    gina.eval("ns.EventsUI:Open('review')")
    w.tick(0.3)
    rv = gina.eval_py("local v = ns.EventsUI:GetViewFrame('review'); return { pick = ns.EventsUI:GetState().review, "
                      "note = v.note.fs:GetText(), count = ns.EventsUI:GetPanel().tabs.review.cnt.fs:GetText() }")
    assert rv == {"pick": def_id, "note": "the final is best of 5 now", "count": "1"}, rv
    gina.eval("ns.EventsUI:GetViewFrame('review').head.rank:Click()")
    w.tick(3)
    for c in cs:
        assert c.eval_py("return ns.Events:ReviewState(ns.Events:GetDef(...))", def_id) == "ranked", c.name
    # a second one: Send back asks for a reason first
    def2 = bert.eval("local d = ns.Events:NewDef(true); d.name = 'Duel cup II'; ns.Events:SaveDef(d); "
                     "ns.Events:SubmitForReview(d.id, 'please'); return d.id")
    w.tick(3)
    gina.eval("ns.EventsUI:SelectReview(...)", def2)
    w.tick(0.3)
    gina.eval("ns.EventsUI:GetViewFrame('review').head.back:Click()")
    w.tick(1)
    assert gina.eval_py("return ns.Events:ReviewState(ns.Events:GetDef(...))", def2) == "review"
    assert "say why first" in gina.eval_py("return ns.EventsUI:GetViewFrame('review').rsect.r:GetText()")
    gina.eval("local v = ns.EventsUI:GetViewFrame('review'); v.reply:SetText('two cups on one night is too much'); "
              "v.head.back:Click()")
    w.tick(3)
    assert bert.eval_py("return ns.Events:ReviewState(ns.Events:GetDef(...))", def2) == "back"
    assert bert.eval_py("return ns.Events:GetReview(...).note", def2) == "two cups on one night is too much"
    w.assert_no_errors()


@case
def the_badge_designer_hands_its_badge_to_onsave():
    w = World()
    g = Client(w, "Gina", guild_rank=0, class_file="PALADIN")
    g.load_addon()
    w.tick(3)
    g.eval("T_DEF = ns.Events:NewDef(true); T_SAVED = nil; "
           "T_CB = function(id, bd) T_SAVED = { id = id, n = bd.n, i = bd.i, f = bd.f, ti = bd.ti } end")
    # a new badge: a free id, the name, icon, frame and title picked
    assert g.eval_py("return ns.EventsUI:OpenBadgeDesigner(T_DEF, nil, T_CB)") is True
    assert g.eval_py("return ns.EventsUI:GetSheet('badge').title:GetText()") == "New badge"
    # an empty name is refused
    assert g.eval_py("return (ns.EventsUI:SaveBadge())") is False
    assert g.eval_py("return ns.EventsUI:GetSheet('badge'):IsShown()") is True
    # the icon search keeps what matches
    g.eval("ns.EventsUI:SetBadge({ q = 'mount' })")
    icons = g.eval_py("local n = 0; for _, c in ipairs(ns.EventsUI:GetSheet('badge').cells) do "
                      "if c:IsShown() then n = n + 1 end end; return n")
    assert icons == 6, icons
    g.eval("ns.EventsUI:SetBadge({ n = 'Giant slayer II', i = 'Interface\\\\Icons\\\\INV_Misc_Head_Dragon_01', "
           "f = 'blood', tiOn = true, ti = 'the Slayer' })")
    assert g.eval_py("return ns.EventsUI:GetSheet('badge').pv.tt.l1:GetText()").endswith("the Slayer|r")
    g.eval("ns.EventsUI:SaveBadge()")
    saved = g.eval_py("return T_SAVED")
    assert saved == {"id": "b1", "n": "Giant slayer II", "i": "Interface\\Icons\\INV_Misc_Head_Dragon_01",
                     "f": "blood", "ti": "the Slayer"}, saved
    assert g.eval_py("return ns.EventsUI:GetSheet('badge'):IsShown()") is False
    # an edit keeps its id; the title switched off drops the title
    g.eval("T_SAVED = nil; ns.EventsUI:OpenBadgeDesigner(T_DEF, 'champ', T_CB)")
    assert g.eval_py("return ns.EventsUI:GetSheet('badge').name:GetText()") == "Duel champion"
    g.eval("ns.EventsUI:SetBadge({ f = 'silver', tiOn = false })")
    g.eval("ns.EventsUI:SaveBadge()")
    saved = g.eval_py("return T_SAVED")
    assert saved["id"] == "champ" and saved["f"] == "silver" and saved.get("ti") is None, saved
    # Escape closes it (nothing saved)
    g.eval("T_SAVED = nil; ns.EventsUI:OpenBadgeDesigner(T_DEF, 'second', T_CB)")
    g.eval("local f = ns.EventsUI:GetSheet('badge'); f:GetScript('OnKeyDown')(f, 'ESCAPE')")
    assert g.eval_py("return ns.EventsUI:GetSheet('badge'):IsShown()") is False
    assert g.eval_py("return T_SAVED") is None
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

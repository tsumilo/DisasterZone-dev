"""Edge cases of the Events tab (UI/EventsTab.lua), each one a bug found and fixed on 2026-10-06, and the removal of
calendar events, results, library events and review rows by the GM / officers / guild council.

Covers: long names fit every view (smaller, else two lines; the audit's real text metrics find nothing cut or drawn
over); a cancelled event's page shows nothing open (no "Open now", no open seats, the reason at the bottom right, not
in the meta line); Join is refused once the sign-up closed or filled, also from a button drawn before; the schedule
sheet explains what changed while it stood open (cancelled, removed, started, a time that passed, broken pieces) and
keeps a far-off date; a ranked event isn't sent in again; a reply typed for one event doesn't follow to the next;
level points read "tied with"; the badge designer refuses a name twice and keeps no escape codes; the season sheet
counts its days right and needs today in it; refreshes keep coming in an update storm; stray scroll bars and texts
go with their lists; a cancel confirmed after the start is refused; Remove for the GM (rows, menus, cards, review
rows) moves the view on cleanly and members never see it.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_edge_tab.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all, menu_labels, menu_pick, printed_since  # noqa: E402

HELLO = 50
CLASSES = ["PALADIN", "MAGE", "ROGUE", "WARRIOR", "PRIEST", "DRUID", "HUNTER", "SHAMAN", "WARLOCK"]
LONG = "Thunderstrike Grand Midsummer Duel Party"   # 40 letters: the most an event's name keeps
SRCS = ("UI/EventsTab.lua", "UI/EventWidgets.lua")


def guild(names, tick=HELLO, metrics=False):
    pre = {}
    if metrics:
        import ui_audit as A
        pre = {"preload_lua": A.PRELOAD + A.metrics_preload()}
    w = World()
    cs = [Client(w, n, guild_rank=0 if i == 0 else 3, class_file=CLASSES[i % len(CLASSES)], **pre)
          for i, n in enumerate(names)]
    for c in cs:
        c.load_addon()
    w.tick(tick)
    return w, cs


def K(name):
    return name + "-Thunderstrike"


def findings(c):
    """The UI audit's cut / overlapping / outside texts of the Events tab's own regions on c's screen now."""
    import ui_audit as A
    regs, ui = A.capture(c)
    found, _ = A.audit(regs, ui)
    return [(f["kind"], f["src"], f["text"][:60]) for f in A.group(found)
            if any(s in (f["src"] or "") for s in SRCS)]


def starter(c, at_offset=3 * 86400, lua="", where=None):
    """c saves the starter event (lua: changes to `d` first) and hosts it: (defId, occId)."""
    return c.eval_py("""
        local off, where = ...
        local d = ns.Events:NewDef(true)
        """ + lua + """
        assert(ns.Events:SaveDef(d), "save")
        return { d.id, ns.Events:Schedule(d.id, GetServerTime() + off, { where = where }) }""", at_offset, where)


def page(c, field):
    return c.eval_py("local v = ns.EventsUI:GetViewFrame('event'); local b = v and v.ban[...]; "
                     "return b and b:IsShown() and b:GetText() or nil", field)


def shown_rows(c, view, list_name, field):
    return c.eval_py("local out = {}; for _, r in ipairs(ns.EventsUI:GetViewFrame(...)[select(2, ...)]) do "
                     "if r:IsShown() then out[#out + 1] = r end end; local f = select(3, ...); local t = {}; "
                     "for i, r in ipairs(out) do t[i] = r[f]:GetText() end; return t", view, list_name, field)


def fill_store(c, occ, key):
    """A sign-up of `key` straight into c's store (another member's, arrived before c's tab refreshed)."""
    c.eval("local occ, key = ...; local st = ns.db.events[ns.Guild:GetGuildKey()]; "
           "st.J[occ .. '/' .. key] = { id = occ .. '/' .. key, by = key, o = occ, on = true, at = 1, rev = 1 }", occ, key)


@case
def long_names_fit_every_view():
    w, (g,) = guild(["Gina"], tick=3, metrics=True)
    long_lua = """d.name = '%s'
        for _, bd in pairs(d.badges) do bd.n = 'Giant slayer of the Ring of Blood' end
        for i, s in ipairs(d.stages) do s.name = 'Stage with a long name ' .. i end""" % LONG
    def_id, occ = starter(g, 3 * 86400, long_lua, "The Ring of Trials, far side of Nagrand, by tree")
    starter(g, 4 * 86400, long_lua + "; d.id = nil")
    g.eval("ns.Events:SubmitForReview(..., string.rep('the final is best of 5 now ', 7))", def_id)
    w.tick(1)
    views = {
        "upcoming": "ns.EventsUI:Open('upcoming')",
        "page": "ns.EventsUI:OpenEvent(...)",
        "library": "ns.EventsUI:Open('library'); ns.EventsUI:SetLibraryHover(select(2, ...))",
        "review": "ns.EventsUI:Open('review')",
    }
    for name, lua in views.items():
        g.eval(lua, occ, def_id)
        w.tick(0.3)
        assert findings(g) == [], (name, findings(g))
    # called off with a long reason: the reason at the bottom right, on two lines
    g.eval("ns.Events:CancelOcc(..., string.rep('Not enough players this week, sorry all ', 3))", occ)
    w.tick(1)
    g.eval("ns.EventsUI:OpenEvent(...)", occ)
    w.tick(0.3)
    assert findings(g) == [], ("cancelled", findings(g))
    # demo mode's results, rows and season with long names (and long player names in the last four)
    g.slash("/dz demo on")
    w.tick(1)
    g.eval("""local name = ...
        for _, d in ipairs(ns.Events:GetDefs()) do d.name = name end
        for _, o in ipairs(ns.Events:GetOccurrences()) do o.def.name = name; o.ranked = true end
        for _, r in ipairs(ns.Events:GetResults()) do
          r.name = name
          for _, b in ipairs(r.badges or {}) do b.n = 'Giant slayer of the Ring of Bloo'; b.p = 'Shadowmelder-Thunderstrike' end
        end
        local st = ns.Events:GetSeason()
        ns.Events.GetSeason = function() return { n = 'The Great Midsummer Brawl Season', from = st.from, to = st.to } end""",
           LONG)
    for name, lua in (("demo upcoming", "ns.EventsUI:Open('upcoming')"), ("demo season", "ns.EventsUI:Open('season')"),
                      ("demo results", "ns.EventsUI:OpenEvent('rdemo1')"), ("demo live", "ns.EventsUI:OpenEvent('odemo1')")):
        g.eval(lua)
        w.tick(0.3)
        if name == "demo results":
            g.eval("""local r = ns.Events:GetResult('rdemo1')
                for _, m in ipairs(r.last4) do
                  if m.a ~= r.champ then m.a = 'Shadowmelder-Thunderstrike' end
                  if m.b ~= r.champ then m.b = 'Wwwwwwwwwwww-Thunderstrike' end
                end
                ns.EventsUI:Refresh()""")
        assert findings(g) == [], (name, findings(g))
    # the badge designer's preview: the tooltip as wide as its longest line (up to the panel), longer lines wrap
    g.eval("ns.Events.GetSeason = nil; ns.MainFrame:Close(); T_DEF = ns.Events:NewDef(true); T_DEF.name = ...", LONG)
    g.eval("ns.EventsUI:OpenBadgeDesigner(T_DEF, nil, function() end)")
    g.eval("ns.EventsUI:SetBadge({ n = 'Giant slayer of the Ring of Bloo', tiOn = true, ti = 'the Unbeaten Champion of' })")
    tt = g.eval_py("""local tt = ns.EventsUI:GetSheet('badge').pv.tt
        local out = { w = tt:GetWidth() }
        for i, fs in ipairs({ tt.l1, tt.l2, tt.l3, tt.l4 }) do
          out[i] = { fs:GetUnboundedStringWidth(), fs:GetWidth(), fs:GetNumLines() }
        end
        return out""")
    assert tt["w"] <= 216, tt
    for i in (1, 2, 3, 4):
        nat, width, lines = tt[i]
        assert nat <= width + 0.5 or lines >= 2, (i, tt)
        assert width <= tt["w"] - 20, (i, tt)
    w.assert_no_errors()


@case
def a_cancelled_event_page_shows_nothing_open():
    w, (g, b) = guild(["Gina", "Bert"])
    _, occ = starter(g)
    w.tick(5)
    g.eval("ns.Events:CancelOcc(..., 'Not enough players')", occ)
    w.tick(5)
    b.eval("ns.EventsUI:OpenEvent(...)", occ)
    w.tick(0.3)
    st = b.eval_py("""local v = ns.EventsUI:GetViewFrame('event')
        local whens, glow, open = {}, false, 0
        for _, r in ipairs(v.stages) do if r:IsShown() then whens[#whens + 1] = r.when:GetText(); glow = glow or r.glow:IsShown() end end
        for _, e in ipairs(v.ents) do if e:IsShown() and not e.face.key then open = open + 1 end end
        return { whens = whens, glow = glow, open = open, meta = v.ban.meta:GetText(),
                 why = v.ban.why:IsShown() and v.ban.why:GetText() or nil, btn = v.ban.btn:IsShown() }""")
    assert not any("Open" in x for x in st["whens"]) and st["glow"] is False, st
    assert st["open"] == 0 and st["btn"] is False, st
    assert "Not enough players" not in st["meta"] and st["why"] == "Not enough players", st
    w.assert_no_errors()


@case
def join_is_refused_once_the_signup_closed_or_filled():
    w, (g, b) = guild(["Gina", "Bert"])
    # its sign-up closes 15 min before the start: 10 min to go, so it closed
    _, occ = starter(g, 600, "for _, bl in pairs(d.blocks) do if bl.kind == 'signup' then bl.set.closes = 'early' end end")
    w.tick(5)
    b.eval("ns.EventsUI:OpenEvent(...)", occ)
    w.tick(0.3)
    assert page(b, "btn") is None and page(b, "note") == "Sign-up closed", (page(b, "btn"), page(b, "note"))
    b.eval("ns.EventsUI:Open('upcoming')")
    w.tick(0.3)
    hero = b.eval_py("local h = ns.EventsUI:GetViewFrame('upcoming').hero; return { h.btn:IsShown(), h.note:GetText() }")
    assert hero == [False, "Sign-up closed"], hero
    # two spots: a Join drawn before the second one filled it is refused on click
    _, occ2 = starter(g, 5 * 3600, "for _, bl in pairs(d.blocks) do if bl.kind == 'signup' then bl.set.spots = 2 end end")
    w.tick(5)
    b.eval("ns.EventsUI:OpenEvent(...)", occ2)
    w.tick(0.3)
    assert page(b, "btn") == "Join"
    fill_store(b, occ2, K("Zed"))
    fill_store(b, occ2, K("Yan"))
    n0 = len(b.chat_frame)
    b.eval("ns.EventsUI:GetViewFrame('event').ban.btn:Click()")
    w.tick(3)
    assert b.eval_py("return ns.Events:IsSignedUp(...)", occ2) is False
    assert any("is full" in x for x in printed_since(b, n0)), printed_since(b, n0)
    w.tick(1)
    assert page(b, "btn") is None and page(b, "note") == "Full: 2 of 2"
    w.assert_no_errors()


@case
def the_schedule_sheet_explains_what_changed_while_it_was_open():
    w, (g, b) = guild(["Gina", "Bert"])
    def_id, occ = starter(g, 3 * 86400)
    w.tick(5)
    g.eval("ns.EventsUI:Open('upcoming')")
    err = "return ns.EventsUI:GetSheet('schedule').err:GetText()"
    # called off meanwhile: not moved
    g.eval("ns.EventsUI:OpenSchedule(...); ns.Events:CancelOcc(select(2, ...), 'x')", def_id, occ)
    g.eval("ns.EventsUI:SetSchedule({ mins = 21 * 60 })")
    assert g.eval_py("return ns.EventsUI:SubmitSchedule()") is False and g.eval_py(err) == "It was cancelled."
    # removed meanwhile
    occ2 = g.eval("return ns.Events:Schedule(..., GetServerTime() + 2 * 86400, {})", def_id)
    g.eval("ns.EventsUI:OpenSchedule(...); ns.Events:DeleteOcc(select(2, ...))", def_id, occ2)
    assert g.eval_py("return ns.EventsUI:SubmitSchedule()") is False and g.eval_py(err) == "It's gone from the calendar."
    # started meanwhile (its run is live)
    occ3 = g.eval("return ns.Events:Schedule(..., GetServerTime() + 2 * 86400, {})", def_id)
    g.eval("ns.EventsUI:OpenSchedule(...); local id = select(2, ...); local L = ns.EventLive; local orig = L.IsLive; "
           "L.IsLive = function(self, x) if x == id then return true end return orig(self, x) end", def_id, occ3)
    assert g.eval_py("return ns.EventsUI:SubmitSchedule()") is False
    assert g.eval_py(err) == "It's running: it can't move now."
    # a time that passed while it stood open: moved to the first one left, said, saved on the next click
    g.eval("ns.EventsUI:CloseSheets(); ns.EventsUI:OpenSchedule(...); ns.EventsUI:SetSchedule({ day = 0, mins = 0 })", def_id)
    shown = g.eval_py("return ns.EventsUI:GetSheet('schedule').time.text:GetText()")
    w.tick(16 * 60)
    assert g.eval_py("return ns.EventsUI:SubmitSchedule()") is False
    later = g.eval_py("return ns.EventsUI:GetSheet('schedule').time.text:GetText()")
    assert later != shown and g.eval_py(err) == "That time has passed: moved to %s." % later, (shown, later)
    occ4 = g.eval_py("return ns.EventsUI:SubmitSchedule()")
    assert g.eval_py("return date('%H:%M', ns.Events:GetOcc(...).at)", occ4) == later
    # an event with pieces to fix can't be hosted (it couldn't start)
    broken = g.eval("local d = ns.Events:NewDef(true); d.scripts[3].top.n.a[1] = nil; ns.Events:SaveDef(d); return d.id")
    g.eval("ns.EventsUI:OpenSchedule(...)", broken)
    assert g.eval_py("return ns.EventsUI:SubmitSchedule()") is False
    assert "need fixing" in g.eval_py(err)
    # a calendar event further out than the sheet's days keeps its day when only its note changes
    far = g.eval("return ns.Events:Schedule(..., GetServerTime() + 20 * 86400, {})", def_id)
    at = g.eval_py("return ns.Events:GetOcc(...).at", far)
    g.eval("ns.EventsUI:OpenSchedule(...); ns.EventsUI:SetSchedule({ note = 'bring a flask' })", def_id, far)
    assert g.eval_py("return ns.EventsUI:SubmitSchedule()") == far
    moved = g.eval_py("return ns.Events:GetOcc(...).at", far)
    assert abs(moved - at) < 15 * 60, (moved - at)
    w.assert_no_errors()


@case
def a_ranked_event_is_not_sent_in_again():
    w, (g, b) = guild(["Gina", "Bert"])
    d = b.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); ns.Events:SubmitForReview(d.id, 'x'); return d.id")
    w.tick(10)
    g.eval("ns.Events:Review(..., true)", d)
    w.tick(5)
    b.eval("ns.MainFrame:Open('events'); ns.EventsUI:OpenSubmit(...)", d)
    assert b.eval_py("return ns.EventsUI:SubmitReview()") is False
    assert b.eval_py("return ns.EventsUI:GetSheet('submit').err:GetText()") == "It's ranked already."
    w.tick(3)
    assert g.eval_py("return ns.Events:ReviewState(ns.Events:GetDef(...))", d) == "ranked"
    w.assert_no_errors()


@case
def a_reply_stays_with_its_event():
    w, (g, b) = guild(["Gina", "Bert"])
    ids = b.eval_py("""local out = {}
        for i = 1, 2 do local d = ns.Events:NewDef(true); d.name = 'Cup ' .. i; ns.Events:SaveDef(d)
          ns.Events:SubmitForReview(d.id, 'n' .. i); out[i] = d.id end
        return out""")
    w.tick(20)
    g.eval("ns.EventsUI:Open('review'); ns.EventsUI:SelectReview(...)", ids[0])
    w.tick(0.3)
    g.eval("ns.EventsUI:GetViewFrame('review').reply:SetText('too many points')")
    g.eval("ns.EventsUI:SelectReview(...)", ids[1])
    assert g.eval_py("return ns.EventsUI:GetState().review") == ids[1]
    assert g.eval_py("return ns.EventsUI:GetViewFrame('review').reply:GetText()") == ""
    # Send back right away asks for a reason (none was typed for this one)
    g.eval("ns.EventsUI:GetViewFrame('review').head.back:Click()")
    w.tick(3)
    assert b.eval_py("return ns.Events:ReviewState(ns.Events:GetDef(...))", ids[1]) == "review"
    w.assert_no_errors()


@case
def level_points_read_tied_with():
    w, (g,) = guild(["Gina"], tick=3)
    g.slash("/dz demo on")
    w.tick(1)
    # Gina level with the one above her
    g.eval("""local rows = ns.Events:Standings()
        local me = ns.Util.PlayerKey()
        local i
        for j, r in ipairs(rows) do if r.key == me then i = j end end
        local diff = rows[i - 1].pts - rows[i].pts
        for _, r in ipairs(ns.Events:GetResults()) do
          if r.points[me] then r.points[me] = r.points[me] + diff; break end
        end""")
    g.eval("ns.EventsUI:Open('season')")
    w.tick(0.3)
    words = g.eval_py("return ns.EventsUI:GetViewFrame('season').you.pt2:GetText()")
    assert "tied with" in words and "0 behind" not in words and "0 ahead" not in words, words
    g.eval("ns.EventsUI:Open('upcoming')")
    w.tick(0.3)
    card = g.eval_py("return ns.EventsUI:GetViewFrame('upcoming').card.pt2:GetText()")
    assert not card.startswith("0 "), card
    w.assert_no_errors()


@case
def the_badge_designer_refuses_a_name_twice_and_keeps_no_codes():
    w, (g,) = guild(["Gina"], tick=3)
    g.eval("T_DEF = ns.Events:NewDef(true); T_SAVED = nil; T_CB = function(id, bd) T_SAVED = { id = id, n = bd.n, ti = bd.ti } end")
    g.eval("ns.EventsUI:OpenBadgeDesigner(T_DEF, nil, T_CB)")
    g.eval("ns.EventsUI:SetBadge({ n = '  duel CHAMPION ' })")
    assert g.eval_py("return (ns.EventsUI:SaveBadge())") is False
    assert g.eval_py("return ns.EventsUI:GetSheet('badge').err:GetText()") == "Another badge of this event has that name."
    # its own name, edited, is fine
    g.eval("ns.EventsUI:OpenBadgeDesigner(T_DEF, 'champ', T_CB)")
    assert g.eval_py("return (ns.EventsUI:SaveBadge())") == "champ"
    # escape codes and line breaks are what the guild would drop: dropped here too (the preview shows the same)
    g.eval("T_SAVED = nil; ns.EventsUI:OpenBadgeDesigner(T_DEF, nil, T_CB)")
    g.eval("ns.EventsUI:SetBadge({ n = 'Red |cffff0000giant|r', tiOn = true, ti = 'the |cff00ff00Green' })")
    assert g.eval_py("return ns.EventsUI:GetSheet('badge').pv.n:GetText()") == "Red cffff0000giantr"
    g.eval("ns.EventsUI:SaveBadge()")
    assert g.eval_py("return T_SAVED") == {"id": "b1", "n": "Red cffff0000giantr", "ti": "the cff00ff00Green"}
    # the hint stays off typed text in every field of the sheets
    for key, lua, fld in (("badge", "ns.EventsUI:OpenBadgeDesigner(T_DEF, nil, T_CB)", "name"),
                          ("badge", None, "title2"),
                          ("schedule", "ns.EventsUI:OpenSchedule(T_ID)", "where"), ("schedule", None, "note"),
                          ("submit", "ns.EventsUI:OpenSubmit(T_ID)", "note"),
                          ("season", "ns.EventsUI:OpenSeasonSheet()", "name")):
        if lua:
            g.eval("if not T_ID then local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); T_ID = d.id end; "
                   "ns.EventsUI:CloseSheets(); " + lua)
        eb = g.eval("return ns.EventsUI:GetSheet(...)[select(2, ...)]", key, fld)
        g.eval("(...):SetText('')", eb)
        assert g.eval_py("return (...).cdlHint:IsShown()", eb) is True, (key, fld)
        g.type_text(eb, "x")
        assert g.eval_py("return (...).cdlHint:IsShown()", eb) is False, (key, fld)
    w.assert_no_errors()


@case
def the_season_sheet_counts_its_days_and_needs_today():
    w, (g, b) = guild(["Gina", "Bert"], tick=3)
    g.eval("ns.MainFrame:Open('events'); ns.EventsUI:Open('season'); ns.EventsUI:OpenSeasonSheet()")
    days = g.eval_py("""local s = ns.Events:GetSeason()
        local a, z = date('*t', s.from), date('*t', s.to)
        local n = 0
        local t = time({ year = a.year, month = a.month, day = a.day, hour = 12 })
        while date('%Y%m%d', t) <= date('%Y%m%d', s.to) do n = n + 1; t = t + 86400 end
        return n""")
    assert g.eval_py("return ns.EventsUI:GetSheet('season').info:GetText()") == "%d days" % days
    # a day on is a day on: each step shows the next date
    seen = []
    for _ in range(40):
        g.eval("ns.EventsUI:GetSheet('season').to.next:Click()")
        seen.append(g.eval_py("return ns.EventsUI:GetSheet('season').to.text:GetText()"))
    assert len(set(seen)) == 40, seen
    # a season that doesn't take in today wouldn't show: refused
    g.eval("local f = ns.EventsUI:GetSheet('season'); f.name:SetText('Season 2'); "
           "f.s.from = GetServerTime() + 5 * 86400; f.s.to = GetServerTime() + 60 * 86400")
    g.eval("ns.EventsUI:GetSheet('season').ok:Click()")
    assert g.eval_py("return ns.EventsUI:GetSheet('season'):IsShown()") is True
    assert g.eval_py("return ns.EventsUI:GetSheet('season').err:GetText()") == "Pick days that take in today."
    w.assert_no_errors()


@case
def refreshes_keep_coming_in_an_update_storm():
    w, (g,) = guild(["Gina"], tick=3)
    g.eval("ns.EventsUI:Open('upcoming')")
    w.tick(0.5)
    g.eval("T_N = 0; local orig = ns.EventsUI.Refresh; ns.EventsUI.Refresh = function(...) T_N = T_N + 1; return orig(...) end")
    for _ in range(40):
        g.eval("ns:Fire('EVENTS_UPDATED')")
        w.tick(0.1)
    n = g.eval_py("return T_N")
    assert 3 <= n <= 6, n
    w.assert_no_errors()


@case
def stray_scroll_bars_and_texts_go_with_their_lists():
    w, (g, b) = guild(["Gina", "Bert"])
    # a long event page's scroll bar (the page's, not its scroll frame's) stays out of its results page
    _, occ = starter(g, 3 * 86400, "for _, bl in pairs(d.blocks) do if bl.kind == 'signup' then bl.set.spots = 40 end end")
    w.tick(5)
    g.eval("ns.EventsUI:OpenEvent(...)", occ)
    w.tick(0.3)
    bar = "return ns.EventsUI:GetViewFrame('event').scroll.ScrollBar:IsShown()"
    g.eval("ns.EventsUI:GetViewFrame('event').scroll.ScrollBar:Show()")
    g.slash("/dz demo on")
    w.tick(1)
    g.eval("ns.EventsUI:OpenEvent('rdemo1')")
    w.tick(0.3)
    assert g.eval_py("return ns.EventsUI:GetViewFrame('event').mode") == "results"
    assert g.eval_py(bar) is False
    g.slash("/dz demo off")
    w.tick(1)
    # the review: an event with nothing changed, then none to show: "Nothing changed" goes too
    d = b.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); ns.Events:SubmitForReview(d.id, 'x'); return d.id")
    w.tick(10)
    g.eval("ns.Events:Review(..., true)", d)
    b.eval("local d = ns.EventBlocks.Copy(ns.Events:GetDef(...)); ns.Events:SaveDef(d); ns.Events:SubmitForReview(d.id, 'y')", d)
    w.tick(10)
    g.eval("ns.EventsUI:Open('review'); ns.EventsUI:SelectReview(...)", d)
    w.tick(0.3)
    nochange = "local v = ns.EventsUI:GetViewFrame('review'); return v.nochange and v.nochange:IsShown() or false"
    assert g.eval_py(nochange) is True
    g.eval("ns.EventsUI:GetViewFrame('review').dscroll.ScrollBar:Show()")
    g.eval("ns.Events:DeleteDef(...)", d)
    w.tick(1)
    assert g.eval_py("return ns.EventsUI:GetViewFrame('review').empty:IsShown()") is True
    assert g.eval_py(nochange) is False
    assert g.eval_py("return ns.EventsUI:GetViewFrame('review').dscroll.ScrollBar:IsShown()") is False
    w.assert_no_errors()


@case
def a_cancel_confirmed_after_the_start_is_refused():
    w, (g, b) = guild(["Gina", "Bert"])
    _, occ = starter(g, 60)
    w.tick(5)
    g.eval("ns.EventsUI:Open('upcoming'); ns.EventsUI:ConfirmCancel(...)", occ)
    g.eval("local id = ...; local L = ns.EventLive; local orig = L.IsLive; "
           "L.IsLive = function(self, x) if x == id then return true end return orig(self, x) end", occ)
    n0 = len(g.chat_frame)
    g.eval("ns.EventsUI:GetSheet('confirm').ok:Click()")
    w.tick(3)
    assert b.eval_py("return ns.Events:GetOcc(...).cancel", occ) is None
    assert any("can't be cancelled now" in x for x in printed_since(g, n0)), printed_since(g, n0)
    w.assert_no_errors()


@case
def the_gm_removes_calendar_events_results_library_and_review_rows():
    w, (g, b) = guild(["Gina", "Bert"])
    def_id, occ = b.eval_py("""local d = ns.Events:NewDef(true); ns.Events:SaveDef(d)
        return { d.id, ns.Events:Schedule(d.id, GetServerTime() + 3 * 86400, {}) }""")
    occ2 = b.eval("return ns.Events:Schedule(..., GetServerTime() + 4 * 86400, {})", def_id)
    w.tick(10)
    # a row's bin (on hover) asks, then takes Bert's event off the calendar for everyone
    g.eval("ns.EventsUI:Open('upcoming')")
    w.tick(0.3)
    row = g.eval("for _, r in ipairs(ns.EventsUI:GetViewFrame('upcoming').rows) do "
                 "if r:IsShown() and r.occId == ... then return r end end", occ2)
    assert g.eval_py("return (...).del:IsShown()", row) is False
    g.hover(row)
    assert g.eval_py("return (...).del:IsShown()", row) is True
    assert g.eval_py("return (...).del.tipText", row) == "Takes it off the calendar for everyone."
    g.eval("(...).del:Click()", row)
    assert g.eval_py("local f = ns.EventsUI:GetSheet('confirm'); return f:IsShown() and f.ok:GetText()") == "Remove"
    g.eval("ns.EventsUI:GetSheet('confirm').ok:Click()")
    w.tick(5)
    assert b.eval_py("return ns.Events:GetOcc(...)", occ2) is None
    # the page's More: Remove next to Cancel; the page goes back to the list once it's gone
    g.eval("ns.EventsUI:OpenEvent(...); ns.EventsUI:GetViewFrame('event').ban.more:Click()", occ)
    labels = menu_labels(g)
    assert "Cancel" in labels and "Remove" in labels, labels
    menu_pick(g, "Remove")
    g.eval("ns.EventsUI:GetSheet('confirm').ok:Click()")
    w.tick(1)
    assert g.eval_py("return ns.EventsUI:GetView()") == "upcoming"
    w.tick(5)
    assert b.eval_py("return ns.Events:GetOcc(...)", occ) is None
    # the library card's Remove (Bert's event)
    g.eval("ns.EventsUI:Open('library'); ns.EventsUI:SetLibraryHover(...)", def_id)
    w.tick(0.3)
    card = g.eval("for _, c in ipairs(ns.EventsUI:GetViewFrame('library').cards) do "
                  "if c:IsShown() and c.def.id == ... then return c end end", def_id)
    assert g.eval_py("return (...).del:IsShown()", card) is True
    g.eval("(...).del:Click(); ns.EventsUI:GetSheet('confirm').ok:Click()", card)
    w.tick(5)
    assert b.eval_py("return ns.Events:GetDef(...)", def_id) is None
    # the review rows: Waiting (off the list undecided, the next one picked), Decided (cleared, still ranked)
    ids = b.eval_py("""local out = {}
        for i = 1, 3 do local d = ns.Events:NewDef(true); d.name = 'Cup ' .. i; ns.Events:SaveDef(d)
          ns.Events:SubmitForReview(d.id, 'n' .. i); out[i] = d.id end
        return out""")
    w.tick(25)
    g.eval("ns.Events:Review(..., true)", ids[2])
    w.tick(1)
    g.eval("ns.EventsUI:Open('review'); ns.EventsUI:SelectReview(...)", ids[0])
    w.tick(0.3)
    qrow = "for _, r in ipairs(ns.EventsUI:GetViewFrame('review').qrows) do if r:IsShown() and r.id == ... then return r end end"
    r0 = g.eval(qrow, ids[0])
    g.hover(r0)
    assert g.eval_py("return (...).del:IsShown()", r0) is True
    g.eval("(...).del:Click(); ns.EventsUI:GetSheet('confirm').ok:Click()", r0)
    w.tick(1)
    assert g.eval_py("return ns.Events:ReviewState(ns.Events:GetDef(...))", ids[0]) == "draft"
    assert g.eval_py("return ns.EventsUI:GetState().review") == ids[1]
    r2 = g.eval(qrow, ids[2])
    g.hover(r2)
    g.eval("(...).del:Click()", r2)
    w.tick(1)
    assert g.eval_py(qrow, ids[2]) is None
    assert g.eval_py("return ns.Events:ReviewState(ns.Events:GetDef(...))", ids[2]) == "ranked"
    w.tick(5)
    assert b.eval_py("return ns.Events:ReviewState(ns.Events:GetDef(...))", ids[0]) == "draft"
    w.assert_no_errors()


@case
def the_gm_removes_results_and_their_calendar_entry():
    w, (g,) = guild(["Gina"], tick=3)
    g.slash("/dz demo on")
    w.tick(1)
    g.eval("ns.EventsUI:Open('upcoming')")
    w.tick(0.3)
    row = g.eval("for _, r in ipairs(ns.EventsUI:GetViewFrame('upcoming').rows) do "
                 "if r:IsShown() and r.occId == 'rdemo2' then return r end end")
    g.hover(row)
    assert g.eval_py("return (...).del:IsShown()", row) is True
    g.eval("(...).del:Click(); ns.EventsUI:GetSheet('confirm').ok:Click()", row)
    w.tick(1)
    assert g.eval_py("return ns.Events:GetResult('rdemo2')") is None
    # the results page's More: Remove, and the page goes back
    g.eval("ns.EventsUI:OpenEvent('rdemo1'); ns.EventsUI:GetViewFrame('event').ban.more:Click()")
    menu_pick(g, "Remove")
    g.eval("ns.EventsUI:GetSheet('confirm').ok:Click()")
    w.tick(1)
    assert g.eval_py("return ns.Events:GetResult('rdemo1')") is None
    assert g.eval_py("return ns.EventsUI:GetView()") == "upcoming"
    w.assert_no_errors()


@case
def members_never_see_remove_on_others_events():
    w, (g, b) = guild(["Gina", "Bert"])
    gd, gocc = starter(g, 3 * 86400)
    bd, bocc = b.eval_py("""local d = ns.Events:NewDef(true); d.name = 'Bert cup'; ns.Events:SaveDef(d)
        return { d.id, ns.Events:Schedule(d.id, GetServerTime() + 4 * 86400, {}) }""")
    w.tick(10)
    b.eval("ns.EventsUI:Open('upcoming')")
    w.tick(0.3)
    rows = b.eval_py("local out = {}; for _, r in ipairs(ns.EventsUI:GetViewFrame('upcoming').rows) do "
                     "if r:IsShown() then out[r.occId] = r.remove ~= nil end end; local h = ns.EventsUI:GetViewFrame('upcoming').hero; "
                     "out.hero = h.occId; return out")
    # Gina's event is the banner (soonest); Bert's own is a row he may remove
    assert rows.get(bocc) is True and rows.get(gocc) in (None, False), rows
    b.eval("ns.EventsUI:OpenEvent(...); ns.EventsUI:GetViewFrame('event').ban.more:Click()", gocc)
    assert "Remove" not in menu_labels(b) and "Cancel" not in menu_labels(b), menu_labels(b)
    b.eval("ns.EventsUI:OpenEvent(...); ns.EventsUI:GetViewFrame('event').ban.more:Click()", bocc)
    assert "Remove" in menu_labels(b), menu_labels(b)
    b.eval("ns.EventsUI:Open('library')")
    w.tick(0.3)
    cards = b.eval_py("local out = {}; for _, c in ipairs(ns.EventsUI:GetViewFrame('library').cards) do "
                      "if c:IsShown() then ns.EventsUI:SetLibraryHover(c.def.id); out[c.def.id] = c.del:IsShown() end end; "
                      "return out")
    assert cards == {gd: False, bd: True}, cards
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

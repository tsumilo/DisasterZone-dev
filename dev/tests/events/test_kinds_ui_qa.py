"""Events part 2, the final UI QA pass (docs/EVENTS_KINDS.md, mockup shots 00-25): one case for each UI bug the pass
fixed in the builder (UI/EventBuilder.lua, UI/EventPieces.lua), the board / tracker / prompts (UI/EventBoard.lua,
UI/EventTracker.lua, UI/EventWidgets.lua) and the Events tab (UI/EventsTab.lua): very long names everywhere they show,
many definitions (8 tags, 8 scores, 80 list items, 24 places), an ask with 40 candidates, prompts and banners arriving
together, definitions renamed or deleted while views are open, boards with 1, 2 and 40 players, read-only editors and
small screens.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_kinds_ui_qa.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all, strip_codes  # noqa: E402,F401

CLASSES = ["PALADIN", "MAGE", "ROGUE", "WARRIOR", "PRIEST", "DRUID", "HUNTER", "SHAMAN", "WARLOCK"]


def one(name="Gina", rank=0, cls="ROGUE"):
    """One client in a guild of its own, the addon loaded."""
    w = World()
    c = Client(w, name, guild_rank=rank, class_file=cls)
    c.load_addon()
    w.tick(3)
    return w, c


def plain(s):
    return strip_codes(s) if isinstance(s, str) else s


def saved_example(c, key):
    """An example saved in my library: its def id."""
    return c.eval("local d = ns.Events:NewDef(false); for k, v in pairs(ns.EventBlocks:Example(...)) do d[k] = v end; "
                  "assert(ns.Events:SaveDef(d)); return d.id", key)


def meet_of(c, did):
    """The def's meeting place: pid, map, x, y."""
    return c.eval_py("local d = ns.Events:GetDef(...); local p = d.places[d.meet]; return { d.meet, p.map, p.x, p.y, p.n }",
                     did)


TRACKER = r"""
local f = ns.EventTracker:GetFrames().tracker
if not (f and f:IsShown()) then return { shown = false } end
return { shown = true, name = f.name:GetText(), stage = f.stage:GetText(), clock = f.clock:GetText(),
  arrow = f.arr:IsShown() and f.arr.name:GetText() or false, yd = f.arr:IsShown() and f.arr.yd:GetText() or false,
  l3 = f.l3:GetText() }
"""


def tracker(c):
    c.eval("ns.EventTracker:Refresh()")
    return c.eval_py(TRACKER)


# ---------------------------------------------------------------------------------------------------------------
# Where to go (EVENTS_KINDS.md "Where to go"): the meeting place on the tracker, every map, the event page, the
# schedule sheet
# ---------------------------------------------------------------------------------------------------------------

@case
def a_signed_up_player_is_pointed_to_the_meeting_place_from_30_minutes_before():
    w, c = one()
    did = saved_example(c, "redlight")
    pid, m, x, y, name = meet_of(c, did)
    assert name == "Start line", name
    w.set_position("Gina", m, x + 0.03, y + 0.02, subzone="Nagrand")
    # an hour and a half away: nothing yet
    occ = c.eval("return ns.Events:Schedule(..., GetServerTime() + 90 * 60)", did)
    w.tick(1)
    t0 = tracker(c)
    assert t0["shown"] is False, t0
    # twelve minutes before: when it starts, and the way to the start line with how far
    c.eval("local o = ns.Events:GetOcc(...); ns.Events:EditOcc(o.id, GetServerTime() + 12 * 60, nil, nil)", occ)
    w.tick(1)
    t = tracker(c)
    assert t["shown"] and t["name"] == "Red light, green light", t
    assert t["stage"] == "Starts in 12 min", t
    assert t["arrow"] == "Meet at Start line", t
    assert t["yd"].endswith(" yd") and int(t["yd"].split()[0]) > 30, t
    assert t["clock"] and ":" in t["clock"], t
    # nowhere the game says (another continent, an instance): the zone's name instead of yards
    w.set_position("Gina", None)
    t = tracker(c)
    assert t["arrow"] == "Meet at Start line" and t["yd"] == "Nagrand", t
    # standing in it: "you're there"
    w.set_position("Gina", m, x, y, subzone="Nagrand")
    t = tracker(c)
    assert t["yd"] == "you're there", t
    # (its host goes there too, signed up or not)
    c.eval("ns.Events:SignUp(..., false)", occ)
    w.tick(1)
    assert tracker(c)["arrow"] == "Meet at Start line"
    w.assert_no_errors()


@case
def an_entrant_is_pointed_to_the_meeting_place_while_the_sign_up_runs():
    w = World()
    host = Client(w, "Gina", guild_rank=0, class_file="ROGUE")
    me = Client(w, "Victhar", guild_rank=3, class_file="WARRIOR")
    for x in (host, me):
        x.load_addon()
    w.tick(50)
    # red light without its own pointing in the sign-up stage: only the meeting place says where to go
    occ = host.eval(r"""
        local d = ns.Events:NewDef(false)
        for k, v in pairs(ns.EventBlocks:Example('redlight')) do d[k] = v end
        local keep = {}
        for _, s in ipairs(d.scripts) do
          local points = false
          ns.EventBlocks:Walk(s.top, function(p) if p.k == 'pc.point' then points = true end end)
          if not (s.st == 's1' and points) then keep[#keep + 1] = s end
        end
        d.scripts = keep
        assert(#ns.EventBlocks:Problems(d) == 0, 'problems')
        assert(ns.Events:SaveDef(d))
        return ns.Events:Schedule(d.id, GetServerTime() + 60)""")
    w.run_until(lambda: me.eval("return ns.Events:GetOcc(...) ~= nil", occ), timeout=90, step=0.5)
    # not in it: nothing to go to; signed up: a minute before, the way there
    assert tracker(me)["shown"] is False
    assert me.eval("return (ns.Events:SignUp(..., true))", occ)
    w.tick(3)
    t = tracker(me)
    assert t["shown"] and t["stage"] in ("Starts in 1 min", "Starts any minute") and t["arrow"] == "Meet at Start line", t
    ok = host.eval_py("return { ns.EventLive:Start(...) }", occ)
    assert ok[0] is True, ok
    w.tick(5)
    assert me.eval("return ns.EventLive:IsLive(...)", occ)
    t = tracker(me)
    assert t["shown"] and t["arrow"] == "Meet at Start line", t
    assert not (t["l3"] or "").startswith("Meet at "), t     # (the arrow says it: no second "Meet at" line)
    w.assert_no_errors()


@case
def every_map_shows_its_zone_my_arrow_and_a_place_card_that_shows_the_way():
    w, c = one()
    from _common import install_helpers, tt_lines
    install_helpers(c)
    did = saved_example(c, "redlight")
    pid, m, x, y, name = meet_of(c, did)
    w.set_position("Gina", m, x + 0.01, y + 0.01, subzone="Nagrand")
    occ = c.eval("return ns.Events:Schedule(..., GetServerTime() + 3 * 3600)", did)
    w.tick(1)
    # the event page's map ("Where"), then the board's (the practice sign-up)
    c.eval("__MOCK.real_geometry = true; ns.EventsUI:OpenEvent(...)", occ)
    w.tick(0.5)
    page = c.eval_py("""local v = ns.EventsUI:GetViewFrame('event'); local m = v.wmap
        return { sect = v.wsect:IsShown() and v.wsect.t:GetText(), right = v.wsect.r:GetText(),
          zone = m.zone:IsShown() and m.zone.fs:GetText(), me = m.me:IsShown() }""")
    assert page["sect"] == "Where" and page["right"] == "meet at Start line", page
    assert page["zone"] == "Nagrand" and page["me"], page
    # a place's card: its zone and coordinates, how far from me, and a click shows the way (the tracker's arrow)
    c.eval("""local m = ns.EventsUI:GetViewFrame('event').wmap
        for _, r in ipairs(m.rings) do if r:IsShown() and r.hit and r.hit.info.place.n == 'Start line' then
          r.hit:GetScript('OnEnter')(r.hit) end end""")
    lines = [plain(a) for a, _ in tt_lines(c)]
    assert lines[0] == "Start line", lines
    assert any(l.startswith("Nagrand · ") and "," in l for l in lines), lines
    assert any(l.endswith("yd from you") for l in lines) and "Click: show the way" in lines, lines
    c.eval("""local m = ns.EventsUI:GetViewFrame('event').wmap
        for _, r in ipairs(m.rings) do if r:IsShown() and r.hit and r.hit.info.place.n == 'Start line' then
          r.hit:Click() end end""")
    assert c.eval("return (ns.EventLive:MyPoint(...))", occ) == pid
    # (three hours before: the tracker shows it only because I asked the way; my own point, not "Meet at")
    t = tracker(c)
    assert t["shown"] and t["arrow"] == "Start line", t
    c.eval("ns.EventLive:PointMe(..., nil)", occ)
    c.eval("ns.MainFrame:Close(); ns.EventLive:StartPractice(ns.Events:GetDef(...), 6); ns.EventBoard:Open('practice')", did)
    w.tick(0.5)
    board = c.eval_py("""local m = ns.EventBoard:GetWindow().kv.map
        local n = 0
        for _, r in ipairs(m.rings) do if r:IsShown() and r.hit and r.hit:IsShown() then n = n + 1 end end
        return { zone = m.zone:IsShown() and m.zone.fs:GetText(), me = m.me:IsShown(), cards = n }""")
    assert board["zone"] == "Nagrand" and board["me"] and board["cards"] >= 2, board
    c.eval("ns.EventLive:StopPractice(); __MOCK.real_geometry = nil")
    w.assert_no_errors()


@case
def the_event_page_says_where_to_meet_and_shows_the_way():
    w, c = one()
    did = saved_example(c, "redlight")
    pid, m, x, y, name = meet_of(c, did)
    occ = c.eval("return ns.Events:Schedule(..., GetServerTime() + 3 * 3600, { where = 'by the big tree' })", did)
    w.tick(1)
    c.eval("ns.EventsUI:OpenEvent(...)", occ)
    w.tick(0.5)
    ban = c.eval_py("local b = ns.EventsUI:GetViewFrame('event').ban; return { plain = b.meta:GetText(), "
                    "btn3 = b.btn3:IsShown() and b.btn3:GetText(), kind = b.btn3.kind }")
    meta = plain(ban["plain"])
    xy = "%d, %d" % (int(x * 100), int(y * 100))
    assert ("Meet at Start line · Nagrand " + xy) in meta and "big tree" not in meta, meta
    assert ban["btn3"] == "Show the way", ban
    c.eval("ns.EventsUI:GetViewFrame('event').ban.btn3:Click()")
    assert c.eval("return (ns.EventLive:MyPoint(...))", occ) == pid
    # an event without places keeps the host's own words and has no way to show
    did2 = saved_example(c, "duel")
    occ2 = c.eval("return ns.Events:Schedule(..., GetServerTime() + 3 * 3600, { where = 'Ring of Trials' })", did2)
    w.tick(1)
    c.eval("ns.EventsUI:OpenEvent(...)", occ2)
    w.tick(0.5)
    ban = c.eval_py("local b = ns.EventsUI:GetViewFrame('event').ban; local v = ns.EventsUI:GetViewFrame('event'); "
                    "return { b.meta:GetText(), b.btn3:IsShown(), v.wsect:IsShown() }")
    assert "Ring of Trials" in plain(ban[0]) and "Meet at" not in plain(ban[0]) and not ban[1] and not ban[2], ban
    w.assert_no_errors()


@case
def the_schedule_sheet_picks_where_to_meet_among_the_events_places():
    w, c = one()
    did = saved_example(c, "redlight")
    pid, m, x, y, name = meet_of(c, did)
    finish = c.eval("local d = ns.Events:GetDef(...); for id, p in pairs(d.places) do if p.n == 'Finish line' then "
                    "return id end end", did)
    assert finish and finish != pid
    c.eval("ns.EventsUI:Open('library'); ns.EventsUI:OpenSchedule(...)", did)
    sheet = c.eval_py("local f = ns.EventsUI:GetSheet('schedule'); return { f.meet:IsShown() and f.meet:GetText(), "
                      "f.where:IsShown(), f.whereLabel:GetText() }")
    assert plain(sheet[0]).startswith("Start line · Nagrand ") and sheet[1] is False and sheet[2] == "Meet at", sheet
    c.eval("ns.EventsUI:SetSchedule({ meet = ... })", finish)
    occ = c.eval("return ns.EventsUI:SubmitSchedule()")
    assert occ and c.eval("return ns.Events:MeetOf(ns.Events:GetOcc(...))", occ) == finish
    # moved back to the event's own meeting place: the calendar event keeps no choice of its own
    c.eval("ns.EventsUI:OpenSchedule(nil, ...)", occ)
    assert c.eval("return ns.EventsUI:GetSheet('schedule').s.meet") == finish
    c.eval("ns.EventsUI:SetSchedule({ meet = ... })", pid)
    assert c.eval("return ns.EventsUI:SubmitSchedule()") == occ
    assert c.eval("return ns.Events:GetOcc(...).meet", occ) is None
    assert c.eval("return ns.Events:MeetOf(ns.Events:GetOcc(...))", occ) == pid
    # an event without places: the free "Where" text
    did2 = saved_example(c, "duel")
    c.eval("ns.EventsUI:OpenSchedule(...)", did2)
    sheet = c.eval_py("local f = ns.EventsUI:GetSheet('schedule'); return { f.meet:IsShown(), f.where:IsShown(), "
                      "f.whereLabel:GetText() }")
    assert sheet == [False, True, "Where"], sheet
    w.assert_no_errors()


@case
def the_place_card_in_the_builder_says_where_the_place_is_and_how_far():
    w, c = one()
    did = saved_example(c, "redlight")
    pid, m, x, y, name = meet_of(c, did)
    w.set_position("Gina", m, x + 0.01, y, subzone="Nagrand")
    c.eval("__MOCK.real_geometry = true; ns.EventBuilder:Open(ns.Events:GetDef(...), { stage = 's1' })", did)
    w.tick(0.3)
    c.eval("""local S, ui = ns.EventBuilder:GetState()
        for s, f in pairs(ui.scripts) do for _, bl in ipairs(f.blanks) do
          if bl.t == 'place' and not T_DONE then T_DONE = true; bl.frame:GetScript('OnEnter')(bl.frame) end end end""")
    card = c.eval_py("""local S, ui = ns.EventBuilder:GetState(); local c = ui.pcard
        return { c:IsShown(), c.m:GetText(), c.view.zone and c.view.zone:IsShown() and c.view.zone.fs:GetText() }""")
    assert card[0] and card[1].startswith("At %.1f, %.1f, " % (int(x * 1000) / 10, int(y * 1000) / 10)), card
    assert " yd from you. " in card[1] and card[2] == "Nagrand", card
    c.eval("__MOCK.real_geometry = nil")
    w.assert_no_errors()


# ---------------------------------------------------------------------------------------------------------------
# The builder (UI/EventBuilder.lua, UI/EventPieces.lua)
# ---------------------------------------------------------------------------------------------------------------

@case
def clean_up_shows_all_it_tidied():
    w, c = measured()
    c.eval("__MOCK.real_geometry = true")
    open_example(c, "hide", "s3")
    c.eval("ns.EventBuilder:ZoomTo(1, nil, nil, true); ns.EventBuilder:CleanUp()")
    w.tick(0.5)
    got = c.eval_py("local S = ns.EventBuilder:GetState(); return { S.view.z, S.view.x, S.view.y, ns.EventBuilder:FitsAt(S.view.z) }")
    assert got[1] == 0 and got[2] == 0 and got[3] is True and got[0] < 1, got
    c.eval("__MOCK.real_geometry = nil")
    w.assert_no_errors()

# The game gives a click to the top mouse-enabled frame (by level) whose rectangle holds the cursor. For each blank on
# the canvas: the frame that would take a click at its middle (a blank, or a value piece dropped in it, which opens
# the same picker), walking every shown mouse-enabled frame of the builder's window in screen units.
HIT_TEST = r"""
local S, ui = ns.EventBuilder:GetState()
local win = ns.EventBuilder:GetWindow()
local frames, order = {}, 0
local function walk(f)
  if not f:IsShown() then return end
  order = order + 1
  if f.IsMouseEnabled and f:IsMouseEnabled() then
    local l, b, w, h = f:GetRect()
    if l and w and w > 0 and h > 0 then
      local s = f:GetEffectiveScale()
      frames[#frames + 1] = { f = f, l = l * s, b = b * s, r = (l + w) * s, t = (b + h) * s, lvl = f:GetFrameLevel(), o = order }
    end
  end
  for _, k in ipairs({ f:GetChildren() }) do walk(k) end
end
walk(win)
local function top(x, y)
  local best
  for _, e in ipairs(frames) do
    if x >= e.l and x <= e.r and y >= e.b and y <= e.t then
      if not best or e.lvl > best.lvl then best = e end
    end
  end
  return best
end
local function under(f, anc)
  while f do if f == anc then return true end; f = f:GetParent() end
  return false
end
local bad, n = {}, 0
local cl, cb, cr, ct = ui.cv:GetLeft(), ui.cv:GetBottom(), ui.cv:GetRight(), ui.cv:GetTop()
local cs = ui.cv:GetEffectiveScale()
for s, sf in pairs(ui.scripts) do
  for _, bl in ipairs(sf.blanks or {}) do
    local f = bl.frame
    local l, b, w, h = f:GetRect()
    local es = f:GetEffectiveScale()
    local x, y = (l + w / 2) * es, (b + h / 2) * es
    -- (only what the canvas shows: a blank scrolled out of it can't be clicked)
    if x > cl * cs + 2 and x < cr * cs - 2 and y > cb * cs + 2 and y < ct * cs - 2 then
      n = n + 1
      local e = top(x, y)
      if not (e and under(e.f, f)) then
        local who = e and (e.f.piece and e.f.piece.k or (e.f:GetParent() and e.f:GetParent().piece and ('part of ' .. e.f:GetParent().piece.k)) or tostring(e.f:GetName())) or 'nothing'
        bad[#bad + 1] = s.id .. ' ' .. bl.piece.k .. '#' .. bl.slot .. ' -> ' .. who .. ' (' .. tostring(e and e.lvl) .. ' vs ' .. f:GetFrameLevel() .. ')'
      end
    end
  end
end
return { n = n, bad = bad }
"""


@case
def every_blank_on_the_canvas_takes_its_own_click():
    w, c = measured()
    c.eval("__MOCK.real_geometry = true")
    total = 0
    for key in EXAMPLES:
        open_example(c, key)
        stages = c.eval_py("local S = ns.EventBuilder:GetState(); local out = {}; for _, st in ipairs(S.def.stages) do "
                           "out[#out + 1] = st.id end; out[#out + 1] = '*'; return out")
        for sid in stages:
            for z in (None, 0.67, 1.25):
                c.eval("ns.EventBuilder:SelectStage(...)", sid)
                if z:
                    c.eval("ns.EventBuilder:ZoomTo(..., nil, nil, true)", z)
                got = c.eval_py(HIT_TEST)
                total += got["n"]
                assert not got["bad"], (key, sid, z, got["bad"][:4])
    assert total > 300, total
    c.eval("__MOCK.real_geometry = nil")
    w.assert_no_errors()


@case
def a_text_blank_in_the_room_right_of_another_scripts_if_takes_its_click():
    w, c = measured()
    c.eval("__MOCK.real_geometry = true")
    open_example(c, "duel", "s3")
    # a long script whose "if" has a wide header and a short inside (its rectangle holds empty room right of the
    # inside), and a two-piece script whose text blank sits in that room
    c.eval("""local S = ns.EventBuilder:GetState()
        local B = ns.EventBlocks
        local N = B.Build.N
        local d = S.def
        d.scripts[#d.scripts + 1] = { id = 'tqx', st = 's3', x = 20, y = 150, top = B:Stack(N('ev.start'),
          N('lo.if', N('lo.gt', N('pl.howmany', N('pl.all')), 4), N('sg.next')), N('tm.wait', 5), N('tm.wait', 5),
          N('tm.wait', 5), N('tm.wait', 5)) }
        d.scripts[#d.scripts + 1] = { id = 'tq1', st = 's3', x = 150, y = 180, top = B:Stack(N('ev.start'),
          N('ch.show', N('pl.tagged', 'entrants'))) }
        ns.EventBuilder:Refresh()""")
    where = c.eval_py("""local S, ui = ns.EventBuilder:GetState()
        local out = {}
        for s, f in pairs(ui.scripts) do
          if s.id == 'tq1' then for _, bl in ipairs(f.blanks) do if bl.piece.k == 'ch.show' and bl.slot == 2 then
            local x, y = ns.EventPieces:Abs(bl.frame); out = { s.x + x, s.y + y } end end end
        end
        return out""")
    assert 175 < where[0] and where[0] + 36 < 326 and 220 < where[1] < 248, where      # (inside the "if"'s rectangle, off its parts)
    got = c.eval_py(HIT_TEST)
    assert got["n"] >= 3 and not got["bad"], got
    # and a click there opens the typed picker
    c.eval("""local S, ui = ns.EventBuilder:GetState()
        for s, f in pairs(ui.scripts) do
          if s.id == 'tq1' then for _, bl in ipairs(f.blanks) do if bl.piece.k == 'ch.show' and bl.slot == 2 then bl.frame:Click() end end end
        end""")
    assert c.eval("local S, ui = ns.EventBuilder:GetState(); return ui.picker:IsShown() and ui.picker.field:IsShown()")
    c.eval("__MOCK.real_geometry = nil")
    w.assert_no_errors()

@case
def a_categorys_pieces_about_its_definitions_come_right_under_them():
    w, c = one()
    open_example(c, "hide", "s3", "pl")
    order = c.eval_py("""local S, ui = ns.EventBuilder:GetState(); local out = {}
        for _, it in ipairs(ui.pal.items) do if it:IsShown() and it.piece and not it.defId then out[#out + 1] = it.piece.k end end
        return out""")
    # Players: its "when" pieces, then the tag pieces, then the host and the rest (the mockup's order)
    assert order[:4] == ["pl.touch", "pl.radar", "pl.gettag", "pl.notag"], order
    assert order.index("pl.has") < order.index("pl.host") and order.index("pl.tag") < order.index("pl.host"), order
    c.eval("local S = ns.EventBuilder:GetState(); S.cat = 'pt'; ns.EventBuilder:RenderPalette()")
    order = c.eval_py("""local S, ui = ns.EventBuilder:GetState(); local out = {}
        for _, it in ipairs(ui.pal.items) do if it:IsShown() and it.piece and not it.defId then out[#out + 1] = it.piece.k end end
        return out""")
    assert order[0] == "pt.add" and order[-1] == "pt.badge", order
    w.assert_no_errors()


@case
def a_new_event_shows_its_examples_in_a_box_and_nothing_that_has_nothing_to_say():
    w, c = measured()
    c.eval("__MOCK.real_geometry = true; ns.EventBuilder:Open(nil, { stage = 's1' })")
    got = c.eval_py("""local S, ui = ns.EventBuilder:GetState()
        local sf = ui.start
        local _, _, _, bx, by = sf.box:GetPoint(1)
        local bw, bh = sf.box:GetSize()
        local cw, ch = ui.cv:GetWidth(), ui.cv:GetHeight()
        return { shown = sf:IsShown(), box = { bx, -by, bw, bh }, cw = cw, ch = ch,
          status = ui.status:IsShown(), overview = ui.overview:IsShown() }""")
    x, y, bw, bh = got["box"]
    # (clear of the overview and the zoom bar in the bottom-right corner: 10 + 24 + 6 + 82 up)
    assert got["shown"] and x >= 0 and y >= 0 and x + bw <= got["cw"] and y + bh <= got["ch"] - 10 - 24 - 6 - 82, got
    assert got["status"] is False and got["overview"] is False, got
    # one picked: the status and the overview are back
    c.eval("ns.EventBuilder:UseExample('fish')")
    got = c.eval_py("local S, ui = ns.EventBuilder:GetState(); return { ui.status:IsShown(), ui.overview:IsShown(), "
                    "ui.status.fs:GetText() }")
    assert got == [True, True, "Ready to practice"], got
    c.eval("__MOCK.real_geometry = nil")
    w.assert_no_errors()

@case
def long_choices_in_the_ask_editor_take_two_lines_inside_their_box():
    w, c = measured()
    open_example(c, "tmog", "s4", "as")
    c.eval("""local S = ns.EventBuilder:GetState()
        ns.EventBlocks:NewDefinition(S.def, 'asks', { n = 'Theme', q = 'Which theme next week?', kind = 'choice',
          choices = { 'Pirates of the Barrens and Booty Bay', 'The Undead of Stratholme and Scholomance', 'Night elves',
            'Holiday outfits from every festival x', 'Tier four sets', 'Anything goes this time' }, votes = 1 })
        ns.EventBuilder:Refresh()
        ns.EventBuilder.Defs:Open('asks', 'ak4')""")
    got = c.eval_py("""local S, ui = ns.EventBuilder:GetState()
        local box = ui.dpop.forms.asks.choices
        local out = {}
        for i, ch in ipairs(box.chips) do
          if ch:IsShown() then
            local fs = ch.fs
            local need = fs:CanWordWrap() and fs:GetWidth() or (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth())
            out[#out + 1] = { w = ch:GetWidth(), need = need, tall = ch:GetHeight() > 20, wraps = fs:CanWordWrap() }
          end
        end
        local last = 0
        for _, ch in ipairs(box.chips) do if ch:IsShown() then
          local _, _, _, _, y = ch:GetPoint(1)
          last = math.max(last, -y + ch:GetHeight())
        end end
        return { chips = out, boxW = box:GetWidth(), h = box.h, last = last, add = box.add:IsShown() }""")
    for ch in got["chips"]:
        assert ch["w"] <= got["boxW"] + 0.5 and 8 + ch["need"] + 6 + 9 + 7 <= ch["w"] + 1, (ch, got["boxW"])
    assert any(ch["tall"] and ch["wraps"] for ch in got["chips"]), got
    # six of six: no "Add" box and no empty row under the last chip
    assert got["add"] is False and got["h"] == got["last"], got
    w.assert_no_errors()


@case
def the_map_sheets_place_names_stay_inside_the_map_and_off_each_other():
    w, c = measured()
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
    import ui_audit_states as ST
    c.eval(ST.EVB_MAPART)
    open_example(c, "hide", "s3", "pc")
    c.eval("""local S = ns.EventBuilder:GetState()
        S.def.places = {}
        for i = 1, 24 do
          S.def.places['pc' .. i] = { n = ('Place number %d of the hu'):format(i), map = 1951, x = 0.2 + 0.6 * ((i * 37) % 100) / 100,
            y = 0.2 + 0.6 * ((i * 61) % 100) / 100, r = 30 + (i % 4) * 40, z = 'Nagrand' }
        end
        S.def.meet = 'pc1'
        ns.EventBuilder:Refresh()
        ns.EventBuilder.MapSheet:Open({ pid = 'pc3' })""")
    got = c.eval_py("""local S, ui = ns.EventBuilder:GetState()
        local v = ui.msheet.view
        local out = {}
        for i = 1, v.nf do
          local fs = v.fonts[i]
          if fs:IsShown() and fs:GetText() ~= 'You' then
            local _, _, _, x, y = fs:GetPoint(1)
            local tw = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
            out[#out + 1] = { x - tw / 2, -y - 6, tw, 12, fs:GetText() }
          end
        end
        return { labels = out, W = v.W, H = v.H }""")
    labels = got["labels"]
    assert len(labels) > 3, got
    for l in labels:
        assert l[0] >= 0 and l[0] + l[2] <= got["W"] + 0.5, (l, got["W"])
    for i in range(len(labels)):
        for j in range(i + 1, len(labels)):
            a, b = labels[i], labels[j]
            assert apart(a, b), (a, b)
    w.assert_no_errors()


@case
def a_piece_frame_reused_from_the_pool_keeps_nothing_of_its_last_piece():
    w, c = one()
    got = c.eval_py("""local B, EP = ns.EventBlocks, ns.EventPieces
        local N = B.Build.N
        local f = CreateFrame('Frame', nil, UIParent)
        f:SetSize(600, 400)
        -- a C piece, put back, then a value drawn: the value has no C piece's header any more
        local d1 = EP:DrawScript(f, B:Stack(N('ev.start'), N('lo.if', N('lo.set', N('var', 'Clue')))), { def = B:Starter(), static = true })
        local cFrames = {}
        for p, pf in pairs(d1.at) do if pf.headW then cFrames[#cFrames + 1] = pf end end
        EP:Release(d1)
        local stale = 0
        for i = 1, 20 do
          local d2 = EP:Draw(f, N('ctx', 'player'), { static = true })
          for p, pf in pairs(d2.at) do if pf.headW then stale = stale + 1 end end
          EP:Release(d2)
        end
        return { #cFrames, stale }""")
    assert got[0] >= 1 and got[1] == 0, got
    w.assert_no_errors()

def measured(name="Gina"):
    """A client whose texts measure as the game's font does (the audit's metrics): widths and line breaks real."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
    import ui_audit as A
    w = World()
    c = Client(w, name, guild_rank=0, class_file="ROGUE", preload_lua=A.PRELOAD + A.metrics_preload())
    c.load_addon()
    w.tick(3)
    return w, c


def open_example(c, key, stage="s1", cat=None):
    did = saved_example(c, key)
    c.eval("ns.EventBuilder:Open(ns.Events:GetDef(...), { stage = select(2, ...) }); local S = ns.EventBuilder:GetState(); "
           "if select(3, ...) then S.cat = select(3, ...); ns.EventBuilder:RenderPalette() end", did, stage, cat)
    return did


@case
def the_status_pill_says_ready_to_practice_then_ready_to_host():
    w, c = one()
    open_example(c, "hide")
    status = "local S, ui = ns.EventBuilder:GetState(); ns.EventBuilder:RenderStatus(); return ui.status.fs:GetText()"
    assert c.eval(status) == "Ready to practice"
    # practised to its end exactly as it is: ready to host
    c.eval("ns.EventBuilder:NotePracticed(ns.EventBuilder:GetState().def)")
    assert c.eval(status) == "Ready to host"
    # changed since: practise it again first
    c.eval("local S = ns.EventBuilder:GetState(); S.def.stages[1].name = 'Gather'")
    assert c.eval(status) == "Ready to practice"
    w.assert_no_errors()


@case
def the_palettes_pieces_show_plain_wells_and_the_canvas_marks_an_empty_blank():
    w, c = one()
    open_example(c, "hide", "s3", "pl")
    # "players with tag [tag]" in the palette: a dark well with white words (the mockups), not the warning look
    pal = c.eval_py("""local S, ui = ns.EventBuilder:GetState()
        for _, it in ipairs(ui.pal.items) do
          if it:IsShown() and it.piece and it.piece.k == 'pl.tagged' then
            local bl = it.draw.blanks[1]
            for _, fs in pairs(bl.frame.fonts or {}) do if fs:IsShown() then return { fs:GetText(), fs:GetTextColor() } end end
          end
        end""")
    assert pal[0] == "tag" and pal[1:4] == [1, 1, 1], pal
    # an empty text blank says "text", no quotes around nothing (Messages' "show players text")
    c.eval("local S = ns.EventBuilder:GetState(); S.cat = 'ch'; ns.EventBuilder:RenderPalette()")
    quotes = c.eval_py("""local S, ui = ns.EventBuilder:GetState(); local out = {}
        for _, it in ipairs(ui.pal.items) do
          if it:IsShown() and it.piece and it.piece.k == 'ch.show' then
            for _, bl in ipairs(it.draw.blanks) do
              for _, fs in pairs(bl.frame.fonts or {}) do if fs:IsShown() then out[#out + 1] = fs:GetText() end end
            end
          end
        end
        return out""")
    assert "text" in quotes and "“" not in quotes and "”" not in quotes, quotes
    # on the canvas an empty blank needs filling: the warning look
    canvas = c.eval_py("""local S, ui = ns.EventBuilder:GetState()
        local s
        for _, x in ipairs(S.def.scripts) do if x.st == 's3' and not s then s = x end end
        local p = s.top.n
        p.a[1] = nil
        ns.EventBuilder:Refresh()
        for _, bl in ipairs(ui.scripts[s].blanks) do
          if bl.piece == p and bl.slot == 1 then
            for _, fs in pairs(bl.frame.fonts or {}) do if fs:IsShown() then return { fs:GetTextColor() } end end
          end
        end""")
    assert canvas and abs(canvas[1] - 0.83) < 0.01, canvas
    w.assert_no_errors()


@case
def a_built_in_tags_line_fits_one_line_and_the_category_dots_are_its_colours():
    w, c = measured()
    open_example(c, "hide", "s3", "pl")
    row = c.eval_py("""local S, ui = ns.EventBuilder:GetState(); local it = ui.pal.rowOf['tags:entrants']
        return { it.sb:GetText(), it.sb:GetStringHeight() }""")
    assert row[0] == "every entrant · built in" and row[1] <= 14, row
    # the circles: a gradient of the category's colours, not tinted flat (the mockups' dots are the pieces' colours)
    dots = c.eval_py("local S, ui = ns.EventBuilder:GetState(); local out = {}; for _, b in ipairs(ui.pal.cats) do "
                     "out[#out + 1] = { b.dot:GetVertexColor() } end; return out")
    assert all(d[:3] == [1, 1, 1] for d in dots), dots
    w.assert_no_errors()


EXAMPLES = ["duel", "hide", "infect", "race", "fish", "tmog", "quiz", "redlight"]
# (stages too busy for 100%: the builder opens them a step or two out; all the others show whole at 100%)
ZOOMED = {("hide", "s3"): 0.9, ("race", "s2"): 0.8, ("fish", "s3"): 0.8, ("quiz", "s3"): 0.9, ("redlight", "s2"): 0.67}


@case
def every_examples_stage_opens_tidy_and_whole():
    w, c = measured()
    c.eval("__MOCK.real_geometry = true")
    for key in EXAMPLES:
        open_example(c, key)
        stages = c.eval_py("local S = ns.EventBuilder:GetState(); local out = {}; for _, st in ipairs(S.def.stages) do "
                           "out[#out + 1] = st.id end; out[#out + 1] = '*'; return out")
        for sid in stages:
            got = c.eval_py("""ns.EventBuilder:SelectStage(...)
                local S, ui = ns.EventBuilder:GetState()
                local boxes = {}
                for s, f in pairs(ui.scripts) do boxes[#boxes + 1] = { s.id, s.x, s.y, f.w, f.h } end
                for bid, card in pairs(ui.cards) do
                  if card:IsShown() then local b = S.def.blocks[bid]; boxes[#boxes + 1] = { bid, b.x, b.y, 318, card:GetHeight() } end
                end
                return { z = S.view.z, fits = ns.EventBuilder:FitsAt(S.view.z), boxes = boxes }""", sid)
            want = ZOOMED.get((key, sid), 1)
            assert got["z"] == want and got["fits"], (key, sid, got["z"], want)
            boxes = got["boxes"] or []
            for i in range(len(boxes)):
                for j in range(i + 1, len(boxes)):
                    a, b = boxes[i], boxes[j]
                    apart = a[1] + a[3] <= b[1] or b[1] + b[3] <= a[1] or a[2] + a[4] <= b[2] or b[2] + b[4] <= a[2]
                    assert apart, (key, sid, a, b)
    c.eval("__MOCK.real_geometry = nil")
    w.assert_no_errors()


@case
def a_stage_too_big_for_100_opens_zoomed_out_once_and_keeps_the_zoom_picked():
    w, c = measured()
    c.eval("__MOCK.real_geometry = true")
    open_example(c, "fish", "s2")
    assert c.eval("return ns.EventBuilder:GetState().view.z") == 1
    # a script dragged far right: seen again in a new builder, the stage shows all of it, zoomed out
    c.eval("""local S = ns.EventBuilder:GetState()
        for _, s in ipairs(S.def.scripts) do if s.id == 'f3' then s.x = 640 end end
        ns.Events:SaveDef(S.def)
        local d = ns.Events:GetDef(S.def.id)
        ns.EventBuilder:Close()
        ns.EventBuilder:Open(d, { stage = 's2' })""")
    z = c.eval("return ns.EventBuilder:GetState().view.z")
    assert z < 1 and c.eval("return ns.EventBuilder:FitsAt(...)", z), z
    # 100% picked, another stage and back: it stays where I put it
    c.eval("ns.EventBuilder:ZoomTo(1, nil, nil, true); ns.EventBuilder:SelectStage('s1'); ns.EventBuilder:SelectStage('s2')")
    assert c.eval("return ns.EventBuilder:GetState().view.z") == 1
    c.eval("__MOCK.real_geometry = nil")
    w.assert_no_errors()


# ---------------------------------------------------------------------------------------------------------------
# The board, tracker and prompts (UI/EventBoard.lua, UI/EventTracker.lua, UI/EventWidgets.lua)
# ---------------------------------------------------------------------------------------------------------------

@case
def the_boards_prizes_never_say_most_twice():
    w, c = board_client()
    c.eval("""local d = ns.EventBlocks:Example('hide')
        for id, s in pairs(d.scores) do if s.n == 'Finds' then s.n = 'Most finds' end end
        QA.Big(d, 8, true)""")
    hows = c.eval_py("""local rail = ns.EventBoard:GetWindow().kv.rail
        local out = {}
        for _, r in ipairs(rail.prizes) do if r:IsShown() then out[#out + 1] = r.how:GetText() end end
        return out""")
    assert "Most finds" in hows and "longest Hidden" in hows, hows
    w.assert_no_errors()

@case
def an_ask_of_40_candidates_pages_them_by_nine_on_a_card_that_fits():
    w, c = board_client()
    c.eval("UIParent:SetSize(1365, 768)")
    c.eval("""local B, L = ns.EventBlocks, ns.EventLive
        local d = B:Example('tmog')
        d.asks = { ak1 = { n = 'Best outfit', q = 'Who wore it best?', kind = 'player', from = 'entrants', votes = 3,
          self = false, time = 90, secret = true } }
        local run = QA.Big(d, 40, true)
        ns.EventBoard:Close()
        local me = ns.Util.PlayerKey()
        run.st.entrants[#run.st.entrants + 1] = me
        local now = L:PracticeNow()
        run.st.qa = { ak1 = { open = true, who = { [me] = true }, q = 'Who wore it best?', at = now, ends = now + 90, ans = {} } }
        run.st.seq = run.st.seq + 1
        ns.EventTracker:Refresh()""")
    w.tick(0.5)
    got = c.eval_py("""local f = ns.EventTracker:GetFrames().asks[1]
        local n = 0
        for _, t in ipairs(f.tiles or {}) do if t:IsShown() then n = n + 1 end end
        local l, b, w, h = f:GetRect()
        return { tiles = n, page = f.pageFs:IsShown() and f.pageFs:GetText(), b = b, top = b + h, sh = UIParent:GetHeight() }""")
    assert got["tiles"] == 9 and got["page"] == "1 of 5", got
    assert got["b"] >= 0 and got["top"] <= got["sh"], got
    w.assert_no_errors()

@case
def definitions_renamed_or_deleted_under_a_running_event_leave_the_board_and_tracker_whole():
    w, c = board_client()
    for key in ("hide", "race", "fish", "tmog"):
        for what in ("rename", "delete"):
            c.eval("""local key, what = ...
                local run = QA.Big(ns.EventBlocks:Example(key), 10, true)
                local st, me = run.st, ns.Util.PlayerKey()
                st.entrants[#st.entrants + 1] = me
                QA.Spread(st, run.def)
                if run.def.places and run.def.places.pc1 then st.point = { [me] = 'pc1' } end
                st.buttons = { Hint = { [me] = true } }
                ns.EventTracker:Refresh()
                local rd = run.def
                for _, k in ipairs({ 'tags', 'scores', 'places', 'lists', 'asks' }) do
                  if what == 'delete' then rd[k] = {} else
                    for id, x in pairs(rd[k] or {}) do x.n = 'Renamed ' .. id .. ' with a long name' end
                  end
                end
                rd.meet = nil
                st.seq = st.seq + 1
                ns.EventBoard:Refresh()
                ns.EventTracker:Refresh()""", key, what)
            w.tick(0.6)
            assert c.eval("return ns.EventBoard:GetWindow():IsShown()"), (key, what)
            if what == "rename":
                tags = c.eval_py("local out = {}; for _, ch in ipairs(ns.EventTracker:GetFrames().tracker.chips or {}) do "
                                 "if ch:IsShown() then out[#out + 1] = ch.fs:GetText() end end; return out")
                assert all(t.startswith("Renamed ") for t in (tags or [])), (key, tags)
            c.eval("ns.EventLive:StopPractice(); ns.EventBoard:Close()")
    w.assert_no_errors()

# A practice run of an example with any number of players, made by hand (the board only reads the state), paused.
QA_LUA = r"""
QA = {}
local B, L, E = ns.EventBlocks, ns.EventLive, ns.EventEngine
function QA.Big(d, n, close, robin)
  if robin then for _, b in pairs(d.blocks) do if b.kind == 'bracket' then b.set = b.set or {}; b.set.fmt = 'robin' end end end
  for _, b in pairs(d.blocks) do if b.kind == 'signup' then b.set = b.set or {}; b.set.spots = 64 end end
  L:StartPractice(d, 2)
  local _, p = L:GetPractice()
  local keys = {}
  for i = 1, n do keys[i] = 'Dummy' .. i .. '-Practice' end
  local run = E:New(d, { id = 'practice', host = ns.Util.PlayerKey(), signups = keys, out = {}, practice = true,
    now = function() return L:PracticeNow() end, nameOf = L.DisplayName })
  p.run = run
  run:Start()
  if close then
    for bid, b in pairs(run.st.blocks) do if b.kind == 'signup' and b.open then run:CloseSignup(bid) end end
  end
  run:Tick()
  L:SetPracticePaused(true)
  ns.EventBoard:Open('practice')
  ns.EventBoard:Refresh()
  return run
end
-- n tags / scores with long names (24 letters, the limit) on an example
QA.LONG = { 'Hidden in the long grass', 'Seekers of the far hills', 'Found behind the old mil', 'Out of the race for good',
  'Wardens of the green hil', 'Watchers of the dark woo', 'Keepers of the high towe', 'Runners of the long rive' }
QA.SCORES = { 'Most mushrooms gathered!', 'Longest time spent hidde', 'Fewest steps on the rout', 'Points from the judges 1',
  'Fish caught in Terokkar!', 'Gold gained in the marke', 'Ogres killed near Halaa!', 'Hints given to the seeker' }
QA.COLORS = { 'green', 'red', 'purple', 'blue', 'orange', 'yellow', 'teal', 'pink' }
function QA.Tags(d, n) d.tags = {}; for i = 1, n do d.tags['tg' .. i] = { n = QA.LONG[i], c = QA.COLORS[i], shown = 'all' } end end
function QA.Scores(d, n)
  d.scores = {}
  for i = 1, n do d.scores['sc' .. i] = { n = QA.SCORES[i], high = true, fmt = 'num', board = true } end
end
function QA.Spread(st, d)
  local tids = {}
  for id in pairs(d.tags or {}) do tids[#tids + 1] = id end
  table.sort(tids, function(a, b) return tonumber(a:match('%d+')) < tonumber(b:match('%d+')) end)
  st.tags = {}
  for _, id in ipairs(tids) do st.tags[id] = {} end
  for i, k in ipairs(st.entrants) do if #tids > 0 then st.tags[tids[((i - 1) % #tids) + 1]][k] = true end end
  st.scores = {}
  for id in pairs(d.scores or {}) do
    st.scores[id] = {}
    for i, k in ipairs(st.entrants) do st.scores[id][k] = (i * 7919) % 97 end
  end
  st.seq = (st.seq or 0) + 1
  ns.EventBoard:Refresh()
end
-- the shown frames of a list, in order
function QA.Shown(list) local out = {}; for _, f in ipairs(list or {}) do if f:IsShown() then out[#out + 1] = f end end; return out end
function QA.Rect(r) local l, b, w, h = r:GetRect(); return { l, b, w, h } end
"""


def board_client():
    w, c = measured()
    c.eval(QA_LUA)
    c.eval("__MOCK.real_geometry = true")
    return w, c


def apart(a, b):
    return a[0] + a[2] <= b[0] + 0.5 or b[0] + b[2] <= a[0] + 0.5 or a[1] + a[3] <= b[1] + 0.5 or b[1] + b[3] <= a[1] + 0.5


@case
def a_race_of_40_ends_its_table_in_how_many_more():
    w, c = board_client()
    c.eval("QA.Big(ns.EventBlocks:Example('race'), 40, false)")
    got = c.eval_py("""local kv = ns.EventBoard:GetWindow().kv
        local rows = QA.Shown(kv.raceRows)
        local last = rows[#rows]
        local l, b = kv:GetRect()
        return { n = #rows, last = last.name:GetText(), bottom = select(2, last:GetRect()), win = select(2, ns.EventBoard:GetWindow():GetRect()) }""")
    more = int(got["last"].lstrip("+").split()[0])
    assert got["last"].endswith(" more") and (got["n"] - 1) + more == 40, got
    assert got["bottom"] >= got["win"], got           # (inside the window)
    w.assert_no_errors()


@case
def standings_and_sign_up_lists_of_40_say_how_many_more():
    w, c = board_client()
    c.eval("QA.Big(ns.EventBlocks:Example('duel'), 40, true, true)")
    rows = c.eval_py("""local br = ns.EventBoard:GetWindow().br
        local out = {}
        for _, r in ipairs(QA.Shown(br.rows)) do out[#out + 1] = r.name:GetText() end
        return out""")
    assert rows[-1].endswith(" more"), rows[-3:]
    shown = len(rows) - 1
    assert shown + int(rows[-1].lstrip("+").split()[0]) == 40, rows[-3:]
    w.assert_no_errors()


@case
def a_bracket_of_40_starts_at_the_first_round_whose_cards_fit():
    w, c = board_client()
    c.eval("QA.Big(ns.EventBlocks:Example('duel'), 40, true)")
    got = c.eval_py("""local br = ns.EventBoard:GetWindow().br
        local heads = {}
        for _, fs in ipairs(QA.Shown(br.heads)) do heads[#heads + 1] = fs:GetText() end
        local _, bb = br:GetRect()
        local low = 1e9
        for _, cd in ipairs(QA.Shown(br.cards)) do low = math.min(low, (select(2, cd:GetRect()))) end
        return { heads = heads, low = low, bottom = bb }""")
    assert got["heads"][0] != "ROUND 1" and "FINAL" in got["heads"], got["heads"]
    assert got["low"] >= got["bottom"] - 1, got
    w.assert_no_errors()


@case
def score_tabs_that_dont_fit_go_in_a_more_tab():
    w, c = board_client()
    c.eval("local d = ns.EventBlocks:Example('fish'); QA.Scores(d, 8); local run = QA.Big(d, 12, true); QA.Spread(run.st, d)")
    got = c.eval_py("""local kv = ns.EventBoard:GetWindow().kv
        local out, right, moreTab = {}, 0, nil
        for _, t in ipairs(QA.Shown(kv.tabs)) do
          local l, b, w = t:GetRect()
          out[#out + 1] = t.rest and ('more:' .. #t.rest) or t.sid
          right = math.max(right, l + w)
          if t.rest then moreTab = t end
        end
        local l, b, w = kv.lbHead:GetRect()
        return { tabs = out, right = right, edge = l + w }""")
    tabs = got["tabs"]
    assert tabs[-1].startswith("more:") and len(tabs) - 1 + int(tabs[-1][5:]) == 8, tabs
    assert got["right"] <= got["edge"] + 1, got
    w.assert_no_errors()


@case
def more_than_four_tags_fold_into_an_other_tags_column():
    w, c = board_client()
    c.eval("local d = ns.EventBlocks:Example('hide'); QA.Tags(d, 8); QA.Scores(d, 2); local run = QA.Big(d, 40, true); "
           "QA.Spread(run.st, d)")
    got = c.eval_py("""local kv = ns.EventBoard:GetWindow().kv
        local cols = QA.Shown(kv.cols)
        local last = cols[#cols]
        -- (a row: the dot 6..16, the name from 24, the count at the right, 6 in)
        local rows = {}
        for _, r in ipairs(QA.Shown(last.rows)) do
          rows[#rows + 1] = { 24 + r.name:GetWidth() + 8 + ns.UI:TextWidth(r.val) + 6 <= last:GetWidth() + 0.5, r.name:GetText(), r.name:GetWidth(), last:GetWidth() }
        end
        -- (a header: the title from 18, the score's name at the right)
        local heads = {}
        for _, c in ipairs(cols) do
          local rw = (c.right:GetText() or '') ~= '' and (ns.UI:TextWidth(c.right) + 8) or 0
          local tw = c.title:CanWordWrap() and c.title:GetWidth() or ns.UI:TextWidth(c.title)
          heads[#heads + 1] = { 18 + tw + rw <= c:GetWidth() + 1, c.title:GetText(), ns.UI:TextWidth(c.title), rw, c:GetWidth() }
        end
        return { n = #cols, title = last.title:GetText(), rows = rows, heads = heads }""")
    assert got["n"] == 4 and got["title"] == "Other tags" and len(got["rows"]) == 5, got
    assert all(r[0] for r in got["rows"]), got["rows"]
    assert all(h[0] for h in got["heads"]), got["heads"]
    w.assert_no_errors()


@case
def a_route_that_comes_back_to_its_places_marks_each_place_once():
    w, c = board_client()
    c.eval("""local d = ns.EventBlocks:Example('race')
        local items = {}
        local ids = {}
        for _, pid in ipairs(d.lists.ls1.items) do ids[#ids + 1] = pid end
        for i = 1, 40 do items[i] = ids[((i - 1) % #ids) + 1] end
        d.lists.ls1.items = items
        QA.Big(d, 6, true)""")
    got = c.eval_py("""local kv = ns.EventBoard:GetWindow().kv
        local seen, n = {}, 0
        for _, cp in ipairs(QA.Shown(kv.route.cps)) do n = n + 1; seen[cp.name or '?'] = (seen[cp.name or '?'] or 0) + 1 end
        local dup = 0
        for _, k in pairs(seen) do if k > 1 then dup = dup + 1 end end
        return { n = n, dup = dup }""")
    assert got["n"] > 0 and got["dup"] == 0, got
    w.assert_no_errors()


@case
def place_names_on_a_crowded_map_never_lie_on_each_other():
    w, c = board_client()
    w.set_position("Gina", 1951, 0.5, 0.5, subzone="Nagrand")
    c.eval("""local d = ns.EventBlocks:Example('hide')
        d.places = {}
        for i = 1, 24 do
          d.places['pc' .. i] = { n = ('Place number %d of the hu'):format(i), map = 1951, x = 0.4 + 0.2 * ((i * 37) % 100) / 100,
            y = 0.4 + 0.2 * ((i * 61) % 100) / 100, r = 30, z = 'Nagrand' }
        end
        d.meet = 'pc1'
        QA.Big(d, 6, true)""")
    labels = c.eval_py("""local m = ns.EventBoard:GetWindow().kv.map
        local out = {}
        for _, r in ipairs(m.rings) do
          if r:IsShown() and r.label:IsShown() then
            local tw = ns.UI:TextWidth(r.label)
            out[#out + 1] = { r.px - tw / 2, r.py + r.r + 10 - 6, tw, 12 }
          end
        end
        -- (my own arrow's "You", on whichever side it shows)
        local me = m.me
        if me and me:IsShown() and me.fs:IsShown() then
          local _, _, _, mx, my = me:GetPoint(1)
          local p1, _, _, ox = me.fs:GetPoint(1)
          local tw = ns.UI:TextWidth(me.fs)
          local x1 = (p1 == 'LEFT') and (mx + 15) or (mx - 15 - tw)
          out[#out + 1] = { x1, -my - 6, tw, 12 }
        end
        return out""")
    assert len(labels) >= 1
    for i in range(len(labels)):
        for j in range(i + 1, len(labels)):
            assert apart(labels[i], labels[j]), (labels[i], labels[j])
    w.assert_no_errors()


ASK_LUA = r"""
local B, L = ns.EventBlocks, ns.EventLive
local d = B:Example('tmog')
local me = ns.Util.PlayerKey()
d.asks = { ak1 = { n = 'The theme of next week!!', q = 'Which theme should the next contest have?', kind = 'choice', from = 'entrants',
  votes = 1, time = 90, choices = { 'Pirates of the Barrens and Booty Bay ships', 'The Undead of Stratholme and Scholomance',
  'Night elves', 'Holiday outfits from every festival' } } }
L:StartPractice(d, 6)
local run = L:GetPractice()
local st = run.st
L:SetPracticePaused(true)
local now = L:PracticeNow()
st.entrants[#st.entrants + 1] = me
st.qa = { ak1 = { open = true, who = { [me] = true }, q = d.asks.ak1.q, at = now, ends = now + 90, ans = {} } }
st.seq = st.seq + 1
ns.EventTracker:Refresh()
"""


@case
def long_choices_take_a_row_each_and_never_spill():
    w, c = board_client()
    c.eval(ASK_LUA)
    got = c.eval_py("""local f = ns.EventTracker:GetFrames().asks[1]
        local out = {}
        for _, b in ipairs(QA.Shown(f.opts)) do
          local fs = b:GetFontString()
          local need = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
          out[#out + 1] = { b:GetWidth(), need, fs:CanWordWrap() and fs:GetWidth() or false, QA.Rect(b) }
        end
        return { opts = out, w = f:GetWidth() }""")
    opts = got["opts"]
    assert len(opts) == 4, got
    lefts = {round(o[3][0]) for o in opts}
    assert len(lefts) == 1, opts                           # (one column: a row each)
    for bw, need, wrapw, rect in opts:
        assert need <= bw - 10 or (wrapw and wrapw <= bw - 12), (bw, need, wrapw)
    w.assert_no_errors()


@case
def banners_grow_down_and_the_cards_in_the_middle_start_below_them():
    w, c = board_client()
    c.eval(ASK_LUA)
    c.eval("UIParent:SetSize(1365, 768)")
    c.eval("for i = 1, 3 do ns.EventTracker:Show('practice', 'A very long banner text number ' .. i .. ': hide in the "
           "play area now, the seekers come in three minutes and they will find you') end")
    got = c.eval_py("""local fr = ns.EventTracker:GetFrames()
        local bs = {}
        for _, b in ipairs(fr.banners) do if b:IsShown() then
          local l, bot, w, h = b:GetRect()
          -- (its words from 31 down: the kicker 15 down, 12 high, 4 under it; 10 under the words at least)
          bs[#bs + 1] = { bot = bot, fits = h >= 31 + b.t:GetStringHeight() + 10 } end end
        local a = fr.asks[1]
        local _, ab, _, ah = a:GetRect()
        return { banners = bs, askTop = ab + ah }""")
    assert len(got["banners"]) == 2, got
    for b in got["banners"]:
        assert b["fits"], b                                # (its words inside it)
        assert got["askTop"] <= b["bot"], got              # (the card below it)
    w.assert_no_errors()


@case
def a_long_event_name_takes_two_lines_on_the_tracker_and_keeps_the_clock_clear():
    w, c = board_client()
    c.eval("local d = ns.EventBlocks:Example('hide'); d.name = 'The great hide and seek of Nagrand'; QA.Big(d, 6, true); "
           "ns.EventBoard:Close(); ns.EventLive:GetPractice().st.point = { [ns.Util.PlayerKey()] = 'pc1' }; "
           "ns.EventTracker:Refresh()")
    got = c.eval_py("""local f = ns.EventTracker:GetFrames().tracker
        if not (f and f:IsShown()) then return false end
        f.clock:SetText('14:20')
        -- (the name from 23, the clock at the right: 44 kept for it)
        return { name = f.name:GetWidth(), wraps = f.name:CanWordWrap(), clock = ns.UI:TextWidth(f.clock), head = f.head:GetHeight() }""")
    assert got and got["head"] == 32 and got["wraps"] and 23 + got["name"] + 8 + got["clock"] <= 232, got
    w.assert_no_errors()


@case
def the_numbers_font_is_the_games_arial_narrow():
    w, c = one()
    assert c.eval("return ns.EventUI.NARROW_FONT") == "Fonts\\ARIALN.TTF"
    w.assert_no_errors()


@case
def a_tag_the_event_no_longer_has_takes_nobody_out_of_the_race():
    w, c = board_client()
    c.eval("QA.Big(ns.EventBlocks:Example('race'), 6, true)")
    out_tag = c.eval("local d = ns.EventLive:GetPractice().def; for id, t in pairs(d.tags) do if t.n == 'Out' then "
                     "return id end end")
    assert out_tag
    c.eval("""local run = ns.EventLive:GetPractice()
        local st = run.st
        st.tags = st.tags or {}
        st.tags[...] = { [st.entrants[1]] = true }
        st.seq = st.seq + 1
        ns.EventBoard:Refresh()""", out_tag)
    before = c.eval("local r = ns.EventBoard:Racers(ns.EventLive:GetPractice().def, ns.EventLive:GetPractice().st); "
                    "for _, e in ipairs(r) do if e.out then return true end end; return false")
    assert before is True
    c.eval("local run = ns.EventLive:GetPractice(); run.def.tags[...] = nil; ns.EventBoard:Refresh()", out_tag)
    after = c.eval("local r = ns.EventBoard:Racers(ns.EventLive:GetPractice().def, ns.EventLive:GetPractice().st); "
                   "for _, e in ipairs(r) do if e.out then return true end end; return false")
    assert after is False
    w.assert_no_errors()


@case
def the_tracker_shows_the_clock_of_the_event_it_shows_now():
    w, c = one()
    c.slash("/dz demo on")
    w.tick(1)
    c.eval("ns.EventBoard:OpenDemo('kdemo-hide'); ns.EventBoard:Close(); ns.EventTracker:Refresh()")
    w.tick(0.3)
    hide = c.eval("return ns.EventTracker:GetFrames().tracker.clock:GetText()")
    c.eval("ns.EventBoard:OpenDemo('kdemo-fish'); ns.EventBoard:Close(); ns.EventTracker:Refresh()")
    w.tick(0.3)
    fish = c.eval_py("local f = ns.EventTracker:GetFrames().tracker; local occ = ns.EventTracker:GetOcc(); "
                     "local st = ns.EventBoard:StateOf(occ); local t = ns.EventBoard.H.ShownTimers(occ, st)[1]; "
                     "return { f.clock:GetText(), t and ns.EventBoard.H.Clock(t.left) or '' }")
    assert hide and fish[0] == fish[1], (hide, fish)
    w.assert_no_errors()


@case
def a_long_sign_up_list_shrinks_the_map_above_it():
    w, c = board_client()
    c.eval("QA.Big(ns.EventBlocks:Example('redlight'), 40, false)")
    got = c.eval_py("""local win = ns.EventBoard:GetWindow()
        local m = win.kv.map
        local rows = QA.Shown(win.br.rows)
        local low = 1e9
        for _, r in ipairs(rows) do low = math.min(low, (select(2, r:GetRect()))) end
        local _, wb = win:GetRect()
        return { mh = m:GetHeight(), n = #rows, low = low, wb = wb }""")
    assert got["mh"] < 250 and got["low"] >= got["wb"], got
    w.assert_no_errors()


# ---------------------------------------------------------------------------------------------------------------
# The Events tab (UI/EventsTab.lua)
# ---------------------------------------------------------------------------------------------------------------

@case
def a_score_named_most_something_leads_without_a_second_most():
    w, c = one()
    import re
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_kinds_tab.py"), encoding="utf-8").read()
    c.eval(re.search(r'PLAY = r"""(.*?)"""', src, re.S).group(1))
    # the fishing derby with two scores on the board and no badges: the awards are each score's leader
    c.eval("""local B = ns.EventBlocks
        local orig = B.Example
        B.Example = function(self, k)
          local d = orig(self, k)
          if k == 'fish' then
            d.scores = { sc1 = { n = 'Most mushrooms', high = true, fmt = 'num', board = true },
                         sc2 = { n = 'Hidden', high = true, fmt = 'time', board = true } }
            d.badges = {}
            for _, s in ipairs(d.scripts) do
              ns.EventBlocks:Walk(s.top, function(p) if p.k == 'pt.badge' then p.a[1] = nil end end)
            end
          end
          return d
        end
        T_K8 = {}
        for i = 1, 8 do T_K8[i] = 'P' .. i .. '-Thunderstrike' end
        T_OCC = T_PLAY('fish', T_K8)
        B.Example = orig""")
    c.eval("ns.MainFrame:Open('events'); ns.EventsUI:OpenEvent(T_OCC)")
    w.tick(0.5)
    texts = c.eval_py(SHOWN_TEXTS, "ost") + c.eval_py(SHOWN_TEXTS, "Hidden")
    titles = [plain(t) for t in texts]
    assert not any("most Most" in t or "Most Most" in t for t in titles), titles
    assert any(t.startswith("Most mushrooms") for t in titles) and any(t.startswith("Longest Hidden") for t in titles), titles
    w.assert_no_errors()

SHOWN_TEXTS = r"""
local out, needle = {}, ...
local function walk(f)
  if not f:IsShown() then return end
  for _, r in ipairs({ f:GetRegions() }) do
    local t = r.GetText and r:IsShown() and r:GetText() or nil
    if type(t) == 'string' and t:find(needle, 1, true) then
      out[#out + 1] = r:GetText()
    end
  end
  for _, k in ipairs({ f:GetChildren() }) do walk(k) end
end
walk(ns.EventsUI:GetPanel())
return out
"""


@case
def each_event_names_who_takes_part_in_its_own_word():
    w, c = one()
    for key, word in (("race", "racers"), ("fish", "anglers"), ("hide", "players")):
        did = saved_example(c, key)
        occ = c.eval("return ns.Events:Schedule(..., GetServerTime() + 2 * 3600)", did)
        w.tick(1)
        c.eval("ns.EventsUI:OpenEvent(...)", occ)
        w.tick(0.5)
        meter = c.eval_py(SHOWN_TEXTS, " of ")
        assert any(plain(t).endswith(" " + word) for t in meter), (key, meter)
        c.eval("ns.Events:DeleteOcc(...)", occ)
    w.assert_no_errors()


@case
def the_results_moments_name_players_in_their_colours():
    w, c = one()
    c.slash("/dz demo on")
    w.tick(1)
    c.eval("ns.EventsUI:OpenEvent('rdemo1')")
    w.tick(0.5)
    got = c.eval_py("""local v = ns.EventsUI:GetViewFrame('event')
        local out = {}
        for _, m in ipairs(v.res.moments or {}) do if m:IsShown() then out[#out + 1] = m.fs:GetText() end end
        return out""")
    assert got and any("|c" in t for t in got), got
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

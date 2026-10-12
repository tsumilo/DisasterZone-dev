"""Events part 2 on screen (UI/EventBoard.lua, UI/EventTracker.lua, UI/EventWidgets.lua; mockup shots 20-24): the
live board's views drawn from what an event has, the banner and the tracker's feed, the ask prompts, the tracker's
tags / scores / buttons / arrow / minimap ring, demo mode's boards and the practice runs.

Covers: a live hide and seek across clients (tag columns in the event's order, the board's scores next to the names,
the places map with its ring, the shown timer, "You: Hiders"); a race (progress, finish times, gaps, my splits, the
route's map); a fishing derby (the leaderboard with the last catch, medals, prizes 1st / 2nd / 3rd, "You're 1st");
"show" as a banner and "tell" in the tracker's feed (newest first, older grey); each ask kind answered through its
prompt reaching the host's run, and its result once it closes; buttons pressed from the tracker; the arrow's turn for
a facing and a position, the place's ring on the minimap; prompts that never overlap; nothing sent in demo mode; the
practice board of every example inside the window.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_kinds_board.py [-k name]   (from dev)"""
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all, strip_codes  # noqa: E402

HELLO = 50
CLASSES = ["PALADIN", "MAGE", "ROGUE", "WARRIOR", "PRIEST", "DRUID", "HUNTER", "SHAMAN", "WARLOCK"]
NAGRAND = 1951
YDY = 1.0 / 3683.33     # one yard north-south on the mock's Nagrand map


def K(n):
    return n + "-Thunderstrike"


def plain(s):
    return strip_codes(s) if isinstance(s, str) else s


def guild(names, tick=HELLO):
    w = World()
    cs = []
    for i, n in enumerate(names):
        cs.append(Client(w, n, guild_rank=0 if i == 0 else 3, class_file=CLASSES[i % len(CLASSES)]))
    for c in cs:
        c.load_addon()
    w.tick(tick)
    return w, cs


BUILD = r"""
local B = ns.EventBlocks
local N, C, J, If, T, V = B.Build.N, B.Build.C, B.Build.J, B.Build.If, B.Build.T, B.Build.V
local function S(id, top) d.scripts[#d.scripts + 1] = { id = id, st = '*', x = 0, y = 0, top = top } end
"""

SHORT_TIMERS = r"""
local function shorten(sec, name)
  for _, s in ipairs(d.scripts) do
    B:Walk(s.top, function(p) if p.k == 'tm.start' and (not name or p.a[2] == name) then p.a[1] = sec end end)
  end
end
"""


def arrive(w, players, occ):
    w.run_until(lambda: all(c.eval("return ns.Events:GetOcc(...) ~= nil", occ) for c in players), timeout=90, step=0.5)


def schedule(w, host, players, lua, start=True):
    """The host saves a def (`lua` fills `d`), schedules it, the players sign up, it starts. Returns occId."""
    occ = host.eval(lua + """
        local probs = ns.EventBlocks:Problems(d)
        assert(#probs == 0, 'problems: ' .. tostring(probs[1] and probs[1].text))
        assert(ns.Events:SaveDef(d), 'save')
        return ns.Events:Schedule(d.id, GetServerTime() + 30)""")
    assert occ, "schedule"
    w.tick(3)
    arrive(w, players, occ)
    for c in players:
        assert c.eval("return (ns.Events:SignUp(..., true))", occ), c.name
    w.tick(3)
    if start:
        ok = host.eval_py("return { ns.EventLive:Start(...) }", occ)
        assert ok[0] is True, ok
        w.tick(3)
    return occ


def example(w, host, players, key, setup="", start=True):
    return schedule(w, host, players, "local d = ns.EventBlocks:Example(%r)\nd.id, d.by = nil, nil\n" % key + BUILD
                    + SHORT_TIMERS + setup, start)


def event(w, host, players, body, start=True):
    """A blank def (no Sign-up: the entrants are who signed up) with `body` filling it."""
    return schedule(w, host, players, "local d = ns.Events:NewDef(false)\nd.name = 'Test event'\n" + BUILD + body, start)


def run(host, occ, code, *args):
    """Lua on the host's own run (`run`, `st`): the facts its entrants' games would send."""
    return host.eval_py("local occ = ...\nlocal run = ns.EventLive:_State()[occ].run\nlocal st = run.st\n" + code, occ, *args)


BOARD = r"""
local f = ns.EventBoard:GetWindow()
local o = { shown = f and f:IsShown() or false }
if not o.shown then return o end
local kv = f.kv
local function vis(x) return x and x:IsShown() and x:IsVisible() end
local st0, def0 = ns.EventBoard:StateOf(ns.EventBoard:GetOcc())
o.layout = ns.EventBoard:Views(def0, st0).layout
o.chip = f.hdr.chip:IsShown() and f.hdr.chip.fs:GetText() or false
o.cols = {}
for _, c in ipairs(kv and kv.cols or {}) do
  if vis(c) then
    local col = { title = c.title:GetText(), right = c.right:GetText(), rightShown = vis(c.right), rows = {} }
    for _, r in ipairs(c.rows) do
      if r:IsShown() then col.rows[#col.rows + 1] = { r.name:IsShown() and r.name:GetText() or r.more:GetText(), r.val:GetText() } end
    end
    o.cols[#o.cols + 1] = col
  end
end
o.map = kv and vis(kv.map) or false
o.secret = kv and vis(kv.secret) or false
o.rings = {}
for _, r in ipairs(kv and kv.map.rings or {}) do if r:IsShown() then o.rings[#o.rings + 1] = r.label:GetText() end end
o.lb = {}
for _, r in ipairs(kv and kv.lbRows or {}) do
  if vis(r) then
    o.lb[#o.lb + 1] = { r.name:GetText(), r.score:GetText(), r.last:GetText(), r.ago:GetText(),
                        r.medal:IsShown() and r.medal.fs:GetText() or r.rank:GetText() }
  end
end
o.race = {}
for _, r in ipairs(kv and kv.raceRows or {}) do
  if vis(r) then o.race[#o.race + 1] = { r.rank:GetText(), r.name:GetText(), r.time:GetText(), r.gap:GetText(), r.outfs:GetText() } end
end
o.splits = {}
if kv and vis(kv.splits) then
  for _, cell in ipairs(kv.splits.cells) do
    if cell.a:IsShown() then o.splits[#o.splits + 1] = { cell.a:GetText(), cell.b:GetText(), cell.c:GetText() } end
  end
end
o.cps, o.dashes = 0, 0
for _, c in ipairs(kv and kv.route.cps or {}) do if c:IsShown() then o.cps = o.cps + 1 end end
for _, l in ipairs(kv and kv.route.lines or {}) do if l:IsShown() then o.dashes = o.dashes + 1 end end
o.times, o.prizes, o.heads = {}, {}, {}
for _, t in ipairs(kv and kv.rail.times or {}) do
  if vis(t) then o.times[#o.times + 1] = { t.big:GetText(), t.of:GetText(), t.l:GetText(), t.r:GetText() } end
end
for _, p in ipairs(kv and kv.rail.prizes or {}) do if vis(p) then o.prizes[#o.prizes + 1] = { p.name:GetText(), p.how:GetText() } end end
for _, fs in ipairs(kv and kv.rail.texts or {}) do if fs:IsShown() then o.heads[#o.heads + 1] = fs:GetText() end end
-- every shown part of the views inside the board (nothing spills out of the window)
o.spill = {}
local M = __MOCK
local rl, rb, rw, rh = M.region_rect(f.root)
local function check(x, what)
  if not vis(x) then return end
  local l, b, w, h = M.region_rect(x)
  if l and (l < rl - 0.5 or b < rb - 0.5 or l + w > rl + rw + 0.5 or b + h > rb + rh + 0.5) then
    o.spill[#o.spill + 1] = { what, l - rl, b - rb, w, h }
  end
end
if kv then
  check(kv.map, 'map'); check(kv.rail, 'rail'); check(kv.splits, 'splits'); check(kv.lbHead, 'lbhead')
  for i, c in ipairs(kv.cols) do check(c, 'col' .. i) end
  for i, r in ipairs(kv.lbRows) do check(r, 'lb' .. i) end
  for i, r in ipairs(kv.raceRows) do check(r, 'race' .. i) end
  for i, t in ipairs(kv.rail.times) do check(t, 'time' .. i) end
  for i, p in ipairs(kv.rail.prizes) do check(p, 'prize' .. i) end
  for i, m in ipairs(kv.rail.moms) do check(m, 'moment' .. i) end
end
return o"""


def board(c):
    return c.eval_py(BOARD)


TRACKER = r"""
local fr = ns.EventTracker:GetFrames()
local t = fr.tracker
local o = { shown = t and t:IsShown() or false, asks = {}, results = {}, banners = {} }
if o.shown then
  o.name, o.clock, o.stage = t.name:GetText(), t.clock:GetText(), t.stage:IsShown() and t.stage:GetText() or false
  o.chips, o.scores, o.btns, o.feed = {}, {}, {}, {}
  for _, c in ipairs(t.chips) do if c:IsShown() then o.chips[#o.chips + 1] = c.fs:GetText() end end
  for _, s in ipairs(t.scores) do if s:IsShown() then o.scores[#o.scores + 1] = s.big:GetText() .. ' ' .. s.sub:GetText() end end
  for _, b in ipairs(t.btns) do if b:IsShown() then o.btns[#o.btns + 1] = b:GetText() end end
  for _, r in ipairs(t.feed) do
    if r:IsShown() then local cr = r.fs:GetTextColor(); o.feed[#o.feed + 1] = { r.fs:GetText(), cr } end
  end
  o.arrow = t.arr:IsShown() and { t.arr.name:GetText(), t.arr.yd:GetText(), t.arr.arrow:IsShown() and t.arr.arrow:GetRotation() or false } or false
  o.segs = t.segs:IsShown()
end
for _, f in ipairs(fr.asks) do o.asks[#o.asks + 1] = { kind = f.kind, kick = f.kick:GetText(), q = f.q:GetText() } end
for _, f in ipairs(fr.results) do
  local rows = {}
  for _, r in ipairs(f.rows) do if r:IsShown() then rows[#rows + 1] = { r.name:GetText(), r.n:GetText() } end end
  o.results[#o.results + 1] = { kick = f.kick:GetText(), head = f.head:GetText(), sub = f.sub:GetText(), rows = rows,
    mine = f.mine:IsShown() and f.mine.fs:GetText() or false }
end
for _, b in ipairs(fr.banners) do if b:IsShown() then o.banners[#o.banners + 1] = { b.kick:GetText(), b.t:GetText() } end end
return o"""


def tracker(c):
    return c.eval_py(TRACKER)


# ------------------------------------------------------------------------------------------------------------------
# The board's views
# ------------------------------------------------------------------------------------------------------------------
@case
def a_live_hide_and_seek_board_has_tag_columns_the_map_and_time_left():
    w, cs = guild(["Gina", "Bert", "Cora", "Dain", "Wade"])
    by = {c.name: c for c in cs}
    g = by["Gina"]
    occ = example(w, g, cs[1:4], "hide", "shorten(20, 'Hide')")
    tags = g.eval_py("local st = ns.EventLive:GetState(...); return { st.tags.tg1, st.tags.tg2 }", occ)
    hiders = sorted(k.split("-")[0] for k in tags[0])
    seeker = list(tags[1])[0].split("-")[0]
    wade = by["Wade"]
    wade.eval("ns.EventBoard:Open(...)", occ)
    w.tick(3)
    b = board(wade)
    assert b["shown"] and b["layout"] == "columns", b
    # a column a tag, in the order the event made them
    assert [plain(c["title"]) for c in b["cols"]] == ["Hiders", "Seekers", "Found"], b["cols"]
    assert sorted(plain(r[0]) for r in b["cols"][0]["rows"]) == hiders, (b["cols"][0], hiders)
    assert [plain(r[0]) for r in b["cols"][1]["rows"]] == [seeker], b["cols"][1]
    # the places on the map (its ring, its name), never where anyone is
    assert b["map"] and b["secret"] and b["rings"] == ["Play area"], b
    # the Hide timer the event shows: time left, when it ends, what comes then
    assert b["times"] and b["times"][0][1] == "of 20 s" and b["times"][0][2].startswith("Hide ends ") \
        and b["times"][0][3] == "then Seek", b["times"]
    assert not b["spill"], b["spill"]
    # a hider's own board: "You: Hiders"
    h = by[hiders[0]]
    h.eval("ns.EventBoard:Open(...)", occ)
    w.tick(1)
    assert board(h)["chip"] == "You: Hiders", board(h)["chip"]
    # seeking: a find moves a hider to Found with the time they stayed hidden, the seeker's Finds next to the name
    w.tick(22)
    assert g.eval("return ns.EventLive:GetState(...).stage", occ) == "s3"
    found = hiders[0]
    run(g, occ, "run:Touch(select(2, ...), select(3, ...), 'click')", K(seeker), K(found))
    w.tick(4)
    b = board(wade)
    cols = {plain(c["title"]): c for c in b["cols"]}
    assert plain(cols["Seekers"]["right"]) == "Finds" and cols["Seekers"]["rows"][0][1] == "1", cols["Seekers"]
    # (the score's name is drawn at the header's right, not only set)
    assert cols["Seekers"]["rightShown"] and cols["Found"]["rightShown"], cols
    assert plain(cols["Found"]["right"]) == "Hidden" and [plain(r[0]) for r in cols["Found"]["rows"]] == [found], cols
    # the prizes and how they're won
    assert sorted(p[1] for p in b["prizes"]) == ["longest Hidden", "most Finds"], b["prizes"]
    w.assert_no_errors()


@case
def a_broken_state_from_the_host_draws_without_errors():
    w, cs = guild(["Gina", "Bert", "Cora", "Wade"])
    by = {c.name: c for c in cs}
    g, wade = by["Gina"], by["Wade"]
    occ = example(w, g, [by["Bert"], by["Cora"]], "hide", "shorten(20, 'Hide')")
    w.tick(2)
    # Wade's copy of the state, every part 2 field of the wrong shape (an old or odd client's state)
    wade.eval("""local occ = ...
        local _, seen = ns.EventLive:_State()
        local st = seen[occ].st
        st.tags = { tg1 = 5, tg2 = { [1] = 'x' } }
        st.scores = { sc1 = 'many', sc2 = { ['Bert-Thunderstrike'] = 'x', ['Cora-Thunderstrike'] = 3, ['Gina-Thunderstrike'] = 0 / 0 } }
        st.qa = { ak1 = 3, ak2 = { open = true, who = 'all', ans = 7 } }
        st.shown, st.lt, st.last, st.point = 'yes', { ls1 = 4 }, { x = 1 }, { ['Wade-Thunderstrike'] = 9 }
        st.moments = { 1, 'a', { text = 'fine' } }
        st.timers = { 'x', { n = 'Hide' } }
        st.seq = st.seq + 1""", occ)
    wade.eval("ns.EventBoard:Open(...); ns.EventBoard:Refresh(); ns.EventTracker:Refresh()", occ)
    w.tick(1)
    assert board(wade)["shown"]
    w.assert_no_errors()


@case
def a_race_board_shows_progress_finish_times_gaps_my_splits_and_the_route():
    w, cs = guild(["Gina", "Bert", "Cora", "Dain"])
    by = {c.name: c for c in cs}
    g, bert = by["Gina"], by["Bert"]
    occ = example(w, g, cs[1:], "race")
    g.eval("ns.EventLive:CloseSignup(...)", occ)
    w.tick(25)
    assert g.eval("return ns.EventLive:GetState(...).stage", occ) == "s2"
    items = g.eval_py("return ns.EventLive:GetDef(...).lists.ls1.items", occ)
    # Dain rides the whole route, Bert three places, Cora two (each a few seconds after the one before)
    for j in range(len(items)):
        for n, upto, gap in (("Dain", 8, 1), ("Bert", 3, 1), ("Cora", 2, 1)):
            if j < upto:
                run(g, occ, "run:Place(select(2, ...), select(3, ...), true); run:Place(select(2, ...), select(3, ...), false)",
                    K(n), items[j])
                w.tick(gap)
        w.tick(2)
    w.tick(4)
    bert.eval("ns.EventBoard:Open(...)", occ)
    w.tick(3)
    b = board(bert)
    assert b["layout"] == "race", b
    order = [plain(r[1]) for r in b["race"]]
    assert order == ["Dain", "You", "Cora", "Gina"], b["race"]       # (the host is signed up too: not started)
    dain, me, cora, gina = b["race"]
    assert gina[0] == "–" and gina[2] == "", gina
    assert dain[2] and ":" in dain[2] and dain[3] == "", dain        # a finish time, no gap: the leader
    assert me[3].startswith("+") and cora[3].startswith("+"), b["race"]
    assert b["chip"] == "You're 2nd", b["chip"]
    # my splits: my three places with their times and the gaps to the leader's, then the next one
    sp = b["splits"]
    assert [x[0] for x in sp[:4]] == ["1", "2", "3", "4"] and sp[3][1] == "next", sp
    assert all(":" in x[1] for x in sp[:3]) and all(x[2] == "+1s" for x in sp[:3]), sp
    # the route: the start's flag and a number for each place (the loop's finish is the flag), a dashed line
    assert b["cps"] == len(items) and b["dashes"] > 20, (b["cps"], b["dashes"])
    assert not b["spill"], b["spill"]
    # the tracker: "Race · Route 4 of 8" and its progress
    t = tracker(bert)
    assert t["shown"] and plain(t["stage"]) == "Race · Route 4 of 8" and t["segs"], t
    w.assert_no_errors()


@case
def a_fishing_derby_board_is_a_leaderboard_with_the_last_catch_and_its_prizes():
    w, cs = guild(["Gina", "Bert", "Cora", "Dain"])
    by = {c.name: c for c in cs}
    g, bert = by["Gina"], by["Bert"]
    occ = example(w, g, cs[1:], "fish", "shorten(600)")
    catches = {"Bert": [(27422, "Barbed Gill Trout")] * 3, "Cora": [(27425, "Spotted Feltail")] * 2,
               "Dain": [(27388, "Mr. Pinchy")]}
    for n, items in catches.items():
        for item, name in items:
            run(g, occ, "run:Happen(select(2, ...), 'fish', { item = select(3, ...), name = select(4, ...), count = 1 })",
                K(n), item, name)
            w.tick(1)
    w.tick(4)
    bert.eval("ns.EventBoard:Open(...)", occ)
    w.tick(3)
    b = board(bert)
    assert b["layout"] == "scores", b
    names = [plain(r[0]) for r in b["lb"]]
    assert names[:3] == ["You", "Cora", "Dain"], b["lb"]
    assert [r[1] for r in b["lb"][:3]] == ["3", "2", "1"], b["lb"]
    assert [r[2] for r in b["lb"][:3]] == ["Barbed Gill Trout", "Spotted Feltail", "Mr. Pinchy"], b["lb"]
    assert all(r[3].endswith("ago") for r in b["lb"][:3]), b["lb"]
    assert [r[4] for r in b["lb"][:3]] == ["1", "2", "3"], b["lb"]      # the medals
    assert b["chip"] == "You're 1st", b["chip"]
    assert [p[1] for p in b["prizes"]] == ["1st", "2nd", "3rd"], b["prizes"]
    assert b["times"] and b["times"][0][2].startswith("Derby ends") and b["times"][0][3] == "then Prizes", b["times"]
    assert not b["spill"], b["spill"]
    t = tracker(bert)
    assert t["scores"] == ["3 Fish · 1st"], t
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Delivery: show, tell
# ------------------------------------------------------------------------------------------------------------------
@case
def show_puts_a_banner_on_screen_and_tell_lines_go_in_the_feed_newest_first():
    w, cs = guild(["Gina", "Bert", "Cora"])
    g, b, c = cs
    occ = event(w, g, [b, c], """
        S('m1', B:Stack(N('ev.start'), N('ch.show', N('pl.all'), J('Welcome to the event!')),
            N('ch.tell', N('pl.all'), J('First line')), N('tm.wait', 3), N('ch.tell', N('pl.all'), J('Second line'))))""")
    w.tick(1)
    t = tracker(b)
    assert [plain(x[1]) for x in t["banners"]] == ["Welcome to the event!"] and plain(t["banners"][0][0]) == "TEST EVENT", t
    w.tick(8)
    t = tracker(b)
    assert [plain(x[0]) for x in t["feed"]] == ["Second line", "First line"], t["feed"]
    assert t["feed"][0][1] > 0.9 and t["feed"][1][1] < 0.8, t["feed"]   # (the older one grey)
    # the banner goes by itself
    w.tick(12)
    assert tracker(b)["banners"] == [], tracker(b)["banners"]
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Asks: each kind answered through its prompt
# ------------------------------------------------------------------------------------------------------------------
ASKS = """
    d.asks = {
      ak1 = { n = 'Best outfit', q = 'Who wore it best?', kind = 'player', from = 'entrants', votes = 2, self = false, time = 90 },
      ak2 = { n = 'Answer', q = 'Which zone is Halaa in?', kind = 'text', from = 'entrants', votes = 1, time = 90 },
      ak3 = { n = 'Score', q = 'Score it 1 to 10', kind = 'number', from = 'entrants', votes = 1, time = 90, secret = true },
      ak4 = { n = 'Teams', q = 'Same teams for round 2?', kind = 'yesno', from = 'entrants', votes = 1, time = 90 },
      ak5 = { n = 'Colour', q = 'Which colour?', kind = 'choice', choices = { 'Red', 'Blue' }, from = 'entrants', votes = 1, time = 90 },
    }
    for i = 1, 5 do S('a' .. i, B:Stack(N('ev.start'), N('as.ask', N('pl.all'), 'ak' .. i))) end"""


def prompt(c, kind):
    return "local f; for _, x in ipairs(ns.EventTracker:GetFrames().asks) do if x.kind == '%s' then f = x end end\n" % kind


@case
def each_ask_kind_answered_through_its_prompt_reaches_the_run():
    w, cs = guild(["Gina", "Bert", "Cora", "Dain"])
    g, b = cs[0], cs[1]
    occ = event(w, g, cs[1:], ASKS)
    w.tick(2)
    t = tracker(b)
    kinds = [a["kind"] for a in t["asks"]]
    assert len(kinds) == 3 and kinds == ["player", "text", "number"], t["asks"]
    assert plain(t["asks"][0]["kick"]) == "BEST OUTFIT · PICK 2" and t["asks"][0]["q"] == "Who wore it best?", t["asks"]
    # pick: myself is "that's you" (no vote), two picks, Send votes
    out = b.eval_py(prompt(b, "player") + """
        local keys, mine = {}, nil
        for _, t in ipairs(f.tiles) do if t:IsShown() then
          keys[#keys + 1] = t.key
          if t.you:IsShown() then mine = t.key end
        end end
        for _, t in ipairs(f.tiles) do
          if t:IsShown() and (t.key == 'Cora-Thunderstrike' or t.key == 'Dain-Thunderstrike') then t:Click() end
        end
        f.send:Click()
        return { keys = keys, mine = mine }""")
    assert out["mine"] == K("Bert") and sorted(out["keys"]) == sorted(K(n) for n in ("Gina", "Bert", "Cora", "Dain")), out
    # typed: Answer with nothing typed says so, then the answer goes
    b.eval(prompt(b, "text") + "f.send:Click()")
    assert plain(b.eval(prompt(b, "text") + "return f.foot:GetText()")) == "Type an answer first"
    b.eval(prompt(b, "text") + "f.eb:SetText('Nagrand'); f.send:Click()")
    # 1 to 10: a number, Send 8
    b.eval(prompt(b, "number") + "f.nums[8]:Click()")
    assert b.eval(prompt(b, "number") + "return f.send:GetText()") == "Send 8"
    b.eval(prompt(b, "number") + "f.send:Click()")
    w.tick(1)
    # the last two come up: yes / no, a choice
    kinds = [a["kind"] for a in tracker(b)["asks"]]
    assert kinds == ["yesno", "choice"], kinds
    b.eval(prompt(b, "yesno") + "f.opts[1]:Click()")
    b.eval(prompt(b, "choice") + "for _, o in ipairs(f.opts) do if o:IsShown() and o.value == 'Blue' then o:Click() end end")
    w.tick(4)
    ans = g.eval_py("""local st = ns.EventLive:GetState(...)
        local out = {}
        for aid, q in pairs(st.qa) do out[aid] = q.ans['Bert-Thunderstrike'] end
        return out""", occ)
    picks = ans["ak1"].values() if isinstance(ans["ak1"], dict) else ans["ak1"]
    assert sorted(x for x in picks if isinstance(x, str)) == [K("Cora"), K("Dain")], ans
    assert ans["ak2"] == "Nagrand" and ans["ak3"] == 8 and ans["ak4"] is True and ans["ak5"] == "Blue", ans
    assert tracker(b)["asks"] == []
    # the others answer: each ask closes, its result on Bert's screen
    for c in [g] + cs[2:]:
        for aid, v in (("ak1", [K("Bert")]), ("ak2", "Nagrand"), ("ak3", 6), ("ak4", True), ("ak5", "Red")):
            assert c.eval("return ns.EventLive:AnswerAsk2(...)", occ, aid, v), (c.name, aid)
    w.tick(5)
    res = tracker(b)["results"]
    assert len(res) == 2, res          # (two at a time; the rest come as these go)
    seen = {}
    for _ in range(6):
        for r in tracker(b)["results"]:
            seen[plain(r["kick"])] = r
        w.tick(16)
    assert sorted(seen) == ["ANSWER · CLOSED", "BEST OUTFIT · CLOSED", "COLOUR · CLOSED", "SCORE · CLOSED",
                            "TEAMS · CLOSED"], sorted(seen)
    first = seen["BEST OUTFIT · CLOSED"]
    assert plain(first["head"]) == "You wore it best" and plain(first["mine"]) == "You picked Cora and Dain", first
    assert plain(seen["TEAMS · CLOSED"]["mine"]) == "You said yes", seen["TEAMS · CLOSED"]
    assert plain(seen["SCORE · CLOSED"]["head"]) == "Average 6.5" and plain(seen["SCORE · CLOSED"]["mine"]) == "You gave 8"
    assert plain(seen["COLOUR · CLOSED"]["head"]) == "Red got the most votes", seen["COLOUR · CLOSED"]
    assert plain(seen["ANSWER · CLOSED"]["head"]) == "Most said Nagrand", seen["ANSWER · CLOSED"]
    w.assert_no_errors()


@case
def prompts_stack_without_overlapping_and_stay_on_screen():
    w, cs = guild(["Gina", "Bert", "Cora", "Dain"])
    g, b = cs[0], cs[1]
    event(w, g, cs[1:], ASKS)
    w.tick(2)
    rects = b.eval_py("""
        local out = {}
        for _, f in ipairs(ns.EventTracker:GetFrames().asks) do out[#out + 1] = { __MOCK.region_rect(f) } end
        local W, H = UIParent:GetWidth(), UIParent:GetHeight()
        return { out, W, H }""")
    boxes, W, H = rects
    assert len(boxes) == 3, boxes
    for i, a in enumerate(boxes):
        assert a[0] >= 0 and a[1] >= 0 and a[0] + a[2] <= W and a[1] + a[3] <= H, (a, W, H)
        for bx in boxes[i + 1:]:
            apart = a[0] + a[2] <= bx[0] or bx[0] + bx[2] <= a[0] or a[1] + a[3] <= bx[1] or bx[1] + bx[3] <= a[1]
            assert apart, (a, bx)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# The tracker: buttons, the arrow, the minimap's ring
# ------------------------------------------------------------------------------------------------------------------
@case
def buttons_pressed_from_the_tracker_reach_the_run():
    w, cs = guild(["Gina", "Bert", "Cora"])
    g, b, c = cs
    occ = event(w, g, [b, c], """
        d.tags = { tg1 = { n = 'Hiders', c = 'green', shown = 'all' } }
        d.scores = { sc1 = { n = 'Finds', high = true, fmt = 'num', board = true } }
        S('b1', B:Stack(N('ev.start'), N('pl.tag', N('pl.all'), 'tg1'), N('as.give', N('pl.all'), 'Ready'),
            N('pt.add', 2, 'sc1', N('pl.all'))))
        S('b2', B:Stack(N('as.press', 'Ready'), N('ch.moment', J(C('player'), ' is ready')),
            N('as.take', 'Ready', C('player'))))""")
    w.tick(3)
    t = tracker(b)
    assert t["chips"] == ["Hiders"] and t["btns"] == ["Ready"] and t["scores"] == ["2 Finds · 1st"], t
    b.eval("for _, x in ipairs(ns.EventTracker:GetFrames().tracker.btns) do if x:IsShown() then x:Click() end end")
    w.tick(4)
    ms = g.eval_py("local out = {}; for _, m in ipairs(ns.EventLive:GetState(...).moments) do out[#out + 1] = m.text end; "
                   "return out", occ)
    assert "Bert is ready" in ms, ms
    assert tracker(b)["btns"] == [], tracker(b)
    w.assert_no_errors()


@case
def the_arrow_turns_with_my_facing_and_the_place_rings_my_minimap():
    w, cs = guild(["Gina", "Bert", "Cora"])
    g, b, c = cs
    w.set_position(b, NAGRAND, 0.5, 0.5)
    occ = event(w, g, [b, c], """
        d.places = { pc1 = { n = 'Tower', map = 1951, x = 0.5, y = 0.5 - 100 / 3683.33, r = 10 } }
        S('p1', B:Stack(N('ev.start'), N('pc.point', N('pl.all'), 'pc1')))""")
    w.tick(3)
    t = tracker(b)
    name, yd, rot = t["arrow"]
    assert plain(name) == "Tower" and yd == "100 yd" and min(rot, 2 * math.pi - rot) < 0.02, t["arrow"]
    # facing west, the tower (north) is to my right: three quarters of a turn counterclockwise
    b.eval("__MOCK.facing = math.pi / 2")
    w.tick(0.5)
    rot = tracker(b)["arrow"][2]
    assert abs(rot - 3 * math.pi / 2) < 0.02, rot
    # its ring on the minimap: straight up (north) from the middle, 100 yards at the minimap's scale
    ring = b.eval_py("""local r = ns.EventTracker:GetFrames().minimap
        if not (r and r:IsShown() and r.circle:IsShown()) then return false end
        local _, _, _, x, y = r.circle:GetPoint(1)
        return { x, y, r.circle.r }""")
    assert ring and abs(ring[0]) < 0.5 and abs(ring[1] - 100 * 70 / 233.33) < 1, ring
    # the rotating minimap turns it with me: facing west, north is to the right
    b.eval("SetCVar('rotateMinimap', '1')")
    w.tick(0.5)
    ring = b.eval_py("local r = ns.EventTracker:GetFrames().minimap; local _, _, _, x, y = r.circle:GetPoint(1); return { x, y }")
    assert ring[0] > 29 and abs(ring[1]) < 1, ring
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Demo mode, practice
# ------------------------------------------------------------------------------------------------------------------
@case
def demo_mode_shows_the_new_boards_and_sends_nothing():
    w = World()
    c = Client(w, "Gina", guild_rank=0)
    c.load_addon()
    w.tick(3)
    c.slash("/dz demo on")
    w.tick(1)
    n0, a0 = len(w.chat_log), len(w.addon_log)
    for key, layout in (("kdemo-hide", "columns"), ("kdemo-race", "race"), ("kdemo-fish", "scores")):
        assert c.eval("return ns.EventBoard:OpenDemo(...)", key), key
        w.tick(1)
        b = board(c)
        assert b["shown"] and b["layout"] == layout and not b["spill"], (key, b)
        assert b["chip"], (key, b["chip"])
        c.eval("ns.EventBoard:Close(); ns.EventTracker:Refresh()")
        t = tracker(c)
        assert t["shown"] and t["stage"], (key, t)
        # (a demo button presses nothing)
        c.eval("ns.EventTracker:Press(..., 'Hint')", key)
    c.eval("ns.EventBoard:OpenDemo('kdemo-fish')")
    w.tick(10)
    # (the events' prefixes: states, facts, the host's messages)
    sent = [e for e in w.addon_log[a0:] if e["prefix"] in ("CDLe", "CDLf")]
    assert sent == [] and len(w.chat_log) == n0, (sent, w.chat_log[n0:])
    w.assert_no_errors()


@case
def a_practice_run_asks_its_host_through_the_prompt_and_the_board_shows_who_won_a_prize():
    w = World()
    c = Client(w, "Gina", guild_rank=0)
    c.load_addon()
    w.tick(3)
    # the transmog contest: the host (me) picks the judges on the catwalk card (I may pick myself here)
    c.eval("ns.EventLive:StartPractice(ns.EventBlocks:Example('tmog'), 6); ns.EventBoard:Open('practice')")
    w.tick(2)
    t = tracker(c)
    assert [a["kind"] for a in t["asks"]] == ["player"] and plain(t["asks"][0]["kick"]) == "PICK JUDGES · PICK 3", t["asks"]
    c.eval(prompt(c, "player") + """
        for _, t in ipairs(f.tiles) do
          if t:IsShown() and (t.key == 'Dummy1-Practice' or t.key == 'Dummy2-Practice') then t:Click() end
        end
        f.send:Click()""")
    w.tick(1)
    judges = c.eval_py("return ns.EventLive:GetPractice().st.tags.tg1")
    assert sorted(judges) == ["Dummy1-Practice", "Dummy2-Practice"], judges
    # the board: a leaderboard of Votes, the judges' tag on their rows
    assert board(c)["layout"] == "scores", board(c)
    # a prize given shows who has it
    c.eval("""local run = ns.EventLive:GetPractice()
        table.insert(run.st.awards, { p = 'Dummy3-Practice', b = 'gold' })
        ns.EventBoard:Refresh()""")
    prizes = {plain(p[0]): plain(p[1]) for p in board(c)["prizes"]}
    assert prizes.get("Best dressed") == "Dummy 3", prizes
    c.eval("ns.EventLive:StopPractice(); ns.EventBoard:Close()")
    w.assert_no_errors()


@case
def the_practice_board_of_every_example_fits_the_window():
    w = World()
    c = Client(w, "Gina", guild_rank=0)
    c.load_addon()
    w.tick(3)
    want = {"duel": "bracket", "hide": "columns", "infect": "columns", "race": "race", "fish": "scores",
            "tmog": "scores", "quiz": "scores", "redlight": "players"}
    for key, layout in want.items():
        c.eval("ns.EventLive:StartPractice(ns.EventBlocks:Example(...), 12); ns.EventBoard:Open('practice')", key)
        w.tick(1)
        for _ in range(4):
            c.eval("ns.EventLive:PracticeSkip()")
            w.tick(2)
            b = board(c)
            assert b["shown"] and not b["spill"], (key, b["spill"])
        assert board(c)["layout"] in (layout, "players"), (key, board(c)["layout"])
        c.eval("ns.EventLive:StopPractice(); ns.EventBoard:Close()")
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

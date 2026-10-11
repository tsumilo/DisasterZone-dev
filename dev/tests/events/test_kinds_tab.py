"""Events part 2 on the Events tab (UI/EventsTab.lua; dev/docs/EVENTS_KINDS.md): the new building blocks as players see
them before, during and after an event.

Covers: every example's page in plain words (its stages' chips from EventBlocks:DescribeStage: tags in their colours,
what wins, a place's ring and "open world only", asks, a Hint button, a walked list, Matches "won by"; its Always row;
rewards from badges, scores and season points; its kind chips on the banner); every example played to its end by the
engine and its results (the podium from Matches or from the first score on the board, each score's table in its look,
the tags at the end, the moments; awards from badges or, without them, by score); the library's kind chips (fitted to
the card, the least telling go first) and the Examples menu opening the builder on an example of my own; the review
of a changed event (its definitions in plain rows, what it gives with its scores and season points); a live derby's
banner (my place, the time its timer has left); demo mode's derby, trivia night and hide and seek.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_kinds_tab.py [-k name]   (from dev)"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

HELLO = 50
CLASSES = ["PALADIN", "MAGE", "ROGUE", "WARRIOR", "PRIEST", "DRUID", "HUNTER", "SHAMAN", "WARLOCK"]
EXAMPLES = ["duel", "hide", "infect", "race", "fish", "tmog", "quiz", "redlight"]


def K(n):
    return n + "-Thunderstrike"


def guild(names, tick=HELLO):
    w = World()
    cs = []
    for i, n in enumerate(names):
        cs.append(Client(w, n, guild_rank=0 if i == 0 else 3, class_file=CLASSES[i % len(CLASSES)]))
    for c in cs:
        c.load_addon()
    w.tick(tick)
    return w, cs


def one():
    w = World()
    g = Client(w, "Gina", guild_rank=0, class_file="PALADIN")
    g.load_addon()
    w.tick(3)
    g.eval(PLAY)
    g.eval("ns.MainFrame:Open('events')")
    w.tick(0.3)
    return w, g


# T_PLAY(key, keys, ranked) -> occId: the example saved to the library (ranked: reviewed first), put on the calendar
# three hours ago and played to its end by the engine with the players `keys` (I host it, not in it); its result
# saved. Duels: the first named wins every match; hide and seek: the seeker finds all but two; the others: every score
# on the board given in the players' order (the last one never scores) and a moment, then its last stage (prizes).
PLAY = r"""
function T_PLAY(key, keys, ranked)
  local B, E, Ev = ns.EventBlocks, ns.EventEngine, ns.Events
  local me = ns.Util.PlayerKey()
  local d = Ev:CopyDef(B:Example(key))
  assert(Ev:SaveDef(d), "save " .. key)
  if ranked then
    assert(Ev:SubmitForReview(d.id, "please"), "submit")
    assert(Ev:Review(d.id, true), "review")
  end
  local at = GetServerTime() - 3 * 3600
  local occ = Ev:Schedule(d.id, at, { noJoin = true, where = "Nagrand" })
  assert(occ, "schedule " .. key)
  local o = Ev:GetOcc(occ)
  local clock, nop = at, function() end
  local run = E:New(o.def, { id = occ, host = me, signups = keys, now = function() return clock end,
    out = { show = nop, tell = nop, guild = nop, sound = nop, plates = nop, log = nop } })
  run:Start()
  local function adv(s) for i = 1, s do clock = clock + 1; run:Tick() end end
  adv(2)
  if run.st.blocks.b1 and run.st.blocks.b1.open then run:CloseSignup("b1"); run:Pump() end
  adv(2)
  local bk = run:MainBracket()
  if bk then
    local guard = 0
    while run.st.phase == "live" and guard < 400 do
      guard = guard + 1
      local any = false
      for _, mid in ipairs(bk.rounds[bk.r] or {}) do
        local m = bk.m[mid]
        if m.st == "play" then any = true; run:Duel(m.a, m.b, true) end
      end
      if not any then adv(5) end
    end
  elseif key == "hide" then
    adv(181)
    local seeker, hiders = run:Tagged("tg2")[1], run:Tagged("tg1")
    T_SEEKER = seeker
    for i = 1, #hiders - 2 do adv(60 + i * 41); run:Touch(seeker, hiders[i], "click") end
    adv(1300)
  else
    local ents = run.st.entrants
    for _, sc in ipairs(B:Defs(o.def, "scores", true)) do
      for i, k in ipairs(ents) do
        if i < #ents then run:SetScore(sc.id, k, sc.fmt == "time" and (240 + i * 37) or ((#ents - i + 1) * 2)) end
      end
    end
    run:Moment(run:Name(ents[1]) .. " took the lead early")
    adv(30)
    run:GoStage(o.def.stages[#o.def.stages].id)
    adv(5)
  end
  if run.st.phase == "live" then run:End() end
  assert(Ev:SaveResult(occ, run, { me }), "result " .. key)
  return occ
end
T_KEYS = {}
for i = 1, 8 do T_KEYS[i] = "P" .. i .. "-Thunderstrike" end
"""

# The event page as it shows: its stages (name, when, words, chips with their look), the rewards' cells, the
# rewards' right words, the banner's kind chips.
READ_PAGE = r"""
local v = ns.EventsUI:GetViewFrame('event')
local out = { mode = v.mode, stages = {}, rewards = {}, kinds = {}, right = v.rsect.r:IsShown() and v.rsect.r:GetText() or nil }
for _, r in ipairs(v.stages) do
  if r:IsShown() then
    local chips = {}
    for _, c in ipairs(r.rules) do
      if c:IsShown() then
        local look = "glyph"
        if c.box:IsShown() then look = "box"
        elseif c.dot:IsShown() then look = tostring(c.dot:GetTexture() or ""):find("ring") and "ring" or "dot" end
        chips[#chips + 1] = { c.fs:GetText(), look }
      end
    end
    out.stages[#out.stages + 1] = { name = r.t1:GetText(), when = r.when:GetText(), inf = r.inf and r.inf:IsShown() or false,
      text = r.t2:IsShown() and r.t2:GetText() or "", chips = chips }
  end
end
for _, c in ipairs(v.rewards) do
  if c:IsShown() then out.rewards[#out.rewards + 1] = { c.place:GetText(), c.n:GetText(), c.s:IsShown() and c.s:GetText() or "" } end
end
for _, m in ipairs(v.ban.kinds or {}) do if m:IsShown() then out.kinds[#out.kinds + 1] = m.fs:GetText() end end
return out"""

# The results page as it shows: pedestals (place, name, line), awards (l1, l2, pts), score tables (title, right,
# rows), tag rows (name, count, faces), moments, the last four.
READ_RESULTS = r"""
local v = ns.EventsUI:GetViewFrame('event')
local f = v.res
local out = { mode = v.mode, peds = {}, awards = {}, tables = {}, tags = {}, moments = {}, l4 = f.l4:IsShown(),
  awRight = f.awSect.r:IsShown() and f.awSect.r:GetText() or nil, kinds = {} }
local placeOf = { 2, 1, 3 }
for i, p in ipairs(f.peds) do
  if p:IsShown() and f.stand:IsShown() then out.peds[#out.peds + 1] = { placeOf[i], p.face.key, p.sb:GetText() } end
end
table.sort(out.peds, function(a, b) return a[1] < b[1] end)
for _, a in ipairs(f.awards) do
  if a:IsShown() then out.awards[#out.awards + 1] = { a.l1:GetText(), a.l2:GetText(), a.pts:GetText() } end
end
for _, t in ipairs(f.tables) do
  if t:IsShown() then
    local rows = {}
    for _, r in ipairs(t.rows) do
      if r:IsShown() then rows[#rows + 1] = { tonumber(r.rk:GetText()), r.face.key, r.v:GetText() } end
    end
    out.tables[#out.tables + 1] = { t.sect.t:GetText(), t.sect.r:GetText(), rows }
  end
end
if f.tags:IsShown() then
  for _, r in ipairs(f.tagRows) do
    if r:IsShown() then
      local n = 0
      for _, x in ipairs(r.faces) do if x:IsShown() then n = n + 1 end end
      out.tags[#out.tags + 1] = { r.n:GetText(), r.c:GetText(), n }
    end
  end
end
if f.mom:IsShown() then
  for _, m in ipairs(f.moments) do if m:IsShown() then out.moments[#out.moments + 1] = m.fs:GetText() end end
end
for _, m in ipairs(v.ban.kinds or {}) do if m:IsShown() then out.kinds[#out.kinds + 1] = m.fs:GetText() end end
return out"""


def chips_of(page, stage):
    for s in page["stages"]:
        if s["name"] == stage:
            return [tuple(x) for x in s["chips"]]
    raise AssertionError("no stage %s in %r" % (stage, [s["name"] for s in page["stages"]]))


@case
def every_example_reads_in_plain_words_on_its_page():
    w, g = one()
    pages = {}
    for key in EXAMPLES:
        occ = g.eval_py("""local B, Ev = ns.EventBlocks, ns.Events
            local d = Ev:CopyDef(B:Example(...)); assert(Ev:SaveDef(d))
            return Ev:Schedule(d.id, GetServerTime() + 86400 + 3600, { where = 'Nagrand' })""", key)
        assert g.eval_py("return ns.EventsUI:OpenEvent(...)", occ) is True, key
        w.tick(0.3)
        pages[key] = g.eval_py(READ_PAGE)
        assert pages[key]["mode"] == "event", key
        # (nothing on any chip is cut: they're as wide as their words)
        assert all(x[0] for s in pages[key]["stages"] for x in s["chips"]), (key, pages[key])
    # the duel cup: Matches won by a duel, its Always row (the guild post, points a match won), 1st / 2nd / 3rd
    p = pages["duel"]
    assert [s["name"] for s in p["stages"]] == ["Sign-up", "Bracket", "Finals", "Prizes", "Always"], p["stages"]
    assert p["stages"][-1]["inf"] is True and p["stages"][-1]["when"] == "the whole event", p["stages"][-1]
    bracket = chips_of(p, "Bracket")
    assert ("best of 3", "glyph") in bracket and ("won by a duel", "glyph") in bracket, bracket
    assert ("seeded by season rank", "glyph") in bracket and ("5 min no-show", "glyph") in bracket, bracket
    assert [r[0] for r in p["rewards"]] == ["1ST", "2ND", "3RD", "BIGGEST UPSET"], p["rewards"]
    assert p["rewards"][0][2] == "+50, title" and p["right"] == "if it were ranked", p
    assert p["kinds"] == ["Sign-up", "Matches"], p["kinds"]
    # hide and seek: the tags in their colours, the play area's ring and "open world only", the Hint button
    p = pages["hide"]
    hide, seek = chips_of(p, "Hide"), chips_of(p, "Seek")
    assert hide == [("Hiders", "dot"), ("Seekers", "dot"), ("Play area", "ring"), ("open world only", "glyph"),
                    ("3 min", "glyph")], hide
    assert seek == [("Found", "dot"), ("most Finds wins", "glyph"), ("longest Hidden wins", "glyph"),
                    ("a Hint button", "box"), ("20 min", "glyph")], seek
    assert chips_of(p, "Always") == [("Play area", "ring"), ("open world only", "glyph")], chips_of(p, "Always")
    assert [r[0] for r in p["rewards"]] == ["MOST FINDS", "LONGEST HIDDEN"], p["rewards"]
    assert p["rewards"][0][1] == "Sharp eyes" and p["rewards"][1][1] == "Last one found", p["rewards"]
    assert p["kinds"] == ["Sign-up", "Tags", "Scores", "Places"], p["kinds"]
    # infection: two tags, two scores deciding its two badges
    p = pages["infect"]
    assert chips_of(p, "Run")[:2] == [("Hiders", "dot"), ("Infected", "dot")], chips_of(p, "Run")
    assert [r[0] for r in p["rewards"]] == ["MOST INFECTIONS", "LONGEST SURVIVED"], p["rewards"]
    # the mount race: the meeting place, the walked Route of places, the Time score (lower wins)
    p = pages["race"]
    assert ("Garadar", "ring") in chips_of(p, "Sign-up") and ("open world only", "glyph") in chips_of(p, "Sign-up"), p
    race = chips_of(p, "Race")
    i = race.index(("Route: 8 places", "glyph"))
    assert race[i + 1] == ("open world only", "glyph"), race
    assert ("fastest Time wins", "glyph") in race and ("stay mounted", "glyph") in race, race
    assert ("Racing", "dot") in race and ("Out", "dot") in race, race
    assert [r[0] for r in p["rewards"]] == ["1ST", "2ND", "3RD"], p["rewards"]
    # the fishing derby: what counts, what wins, its timer; its prizes
    p = pages["fish"]
    assert chips_of(p, "Fishing") == [("every fish counts", "glyph"), ("most Fish wins", "glyph"), ("30 min", "glyph")], p
    assert [r[0] for r in p["rewards"]] == ["1ST", "2ND", "3RD"] and p["rewards"][0][1] == "Angler of the night", p
    assert p["kinds"] == ["Sign-up", "Scores"], p["kinds"]
    # the transmog contest: a tag of judges, votes and scores 1 to 10 (asks)
    p = pages["tmog"]
    assert chips_of(p, "Judges") == [("Judges", "dot"), ("a vote", "glyph")], chips_of(p, "Judges")
    assert chips_of(p, "Catwalk") == [("scores 1 to 10", "glyph")], chips_of(p, "Catwalk")
    assert "Asks" in p["kinds"], p["kinds"]
    # trivia night: typed answers to a list of ten questions
    p = pages["quiz"]
    assert chips_of(p, "Quiz") == [("most Right wins", "glyph"), ("typed answers", "glyph"), ("Questions: 10", "glyph")], p
    # red light, green light: the start and finish lines, what you mustn't do
    p = pages["redlight"]
    play = chips_of(p, "Play")
    assert play[0] == ("don't move", "glyph") and ("Finish line", "ring") in play, play
    assert [x[0] for x in play if x[1] == "dot"] == ["Playing", "Out", "Made it"], play
    # a ranked derby says the season points no badge goes with
    occ = g.eval_py("""local B, Ev = ns.EventBlocks, ns.Events
        local d = Ev:CopyDef(B:Example('fish')); assert(Ev:SaveDef(d)); Ev:SubmitForReview(d.id, 'x'); Ev:Review(d.id, true)
        return Ev:Schedule(d.id, GetServerTime() + 7200)""")
    g.eval("ns.EventsUI:OpenEvent(...)", occ)
    w.tick(0.3)
    assert g.eval_py(READ_PAGE)["right"] == "plus 5 for playing"
    w.assert_no_errors()


@case
def every_example_played_to_its_end_shows_its_results():
    w, g = one()
    res = {}
    for key in EXAMPLES:
        ranked = key in ("duel", "race", "fish")
        occ = g.eval_py("return T_PLAY(..., T_KEYS, select(2, ...))", key, ranked)
        assert g.eval_py("return ns.EventsUI:OpenEvent(...)", occ) is True, key
        w.tick(0.3)
        res[key] = g.eval_py(READ_RESULTS)
        assert res[key]["mode"] == "results", key
    P = [K("P%d" % i) for i in range(1, 9)]
    # the duel cup (ranked): its podium from Matches, the last four, the badges and the points a match won
    r = res["duel"]
    assert len(r["peds"]) == 3 and [x[1] for x in r["peds"][:2]] == [P[0], P[1]], r["peds"]
    assert r["l4"] is True and r["tables"] == [] and r["tags"] == [], r
    assert [a[0].split("|")[0] for a in r["awards"]][0].startswith("Duel champion"), r["awards"]
    assert r["awards"][0][2] == "+50" and r["awRight"] == "plus 5 for playing, 5 a match won", r
    assert r["kinds"] == ["Sign-up", "Matches"], r["kinds"]
    # the fishing derby (ranked): the podium from its Fish table, the table in order, the badges with the catches
    r = res["fish"]
    assert [x[1] for x in r["peds"]] == P[0:3] and r["peds"][0][2] == "16 Fish", r["peds"]
    assert len(r["tables"]) == 1 and r["tables"][0][0] == "Fish" and r["tables"][0][1] == "most wins", r["tables"]
    rows = r["tables"][0][2]
    assert [x[1] for x in rows] == P[0:7] and [x[2] for x in rows] == ["16", "14", "12", "10", "8", "6", "4"], rows
    assert r["awards"][0][0].startswith("Angler of the night") and r["awards"][0][2] == "+30", r["awards"]
    assert r["awards"][1][1] == "14 Fish" and r["awRight"] == "plus 5 for playing", r
    assert r["moments"] == ["P1 took the lead early"] and not r["l4"], r
    # the mount race (ranked): a Time table, lower first, in m:ss
    r = res["race"]
    rows = r["tables"][0][2]
    assert r["tables"][0][0] == "Time" and r["tables"][0][1] == "fastest wins", r["tables"]
    assert [x[2] for x in rows] == ["4:37", "5:14", "5:51", "6:28", "7:05", "7:42", "8:19"], rows
    assert r["peds"][0][1] == P[0] and r["peds"][0][2] == "Time 4:37", r["peds"]
    assert any(t[0] == "Racing" for t in r["tags"]), r["tags"]
    # hide and seek (not ranked): one seeker on the podium, two tables, the tags at the end, the finds as moments
    r = res["hide"]
    seeker = g.eval_py("return T_SEEKER")
    assert len(r["peds"]) == 1 and r["peds"][0][:2] == [1, seeker] and r["peds"][0][2] == "5 Finds", r["peds"]
    assert [t[0] for t in r["tables"]] == ["Finds", "Hidden"], r["tables"]
    hidden = r["tables"][1][2]
    assert len(hidden) == 7 and hidden[0][0] == 1 and hidden[1][0] == 1, hidden
    assert all(re.match(r"^\d+:\d\d$", x[2]) for x in hidden), hidden
    tags = {t[0]: t for t in r["tags"]}
    assert tags["Found"][1] == "5 of 8" and tags["Hiders"][1] == "2 of 8", tags
    assert tags["Seekers"][1] == "1 of 8" and tags["Found"][2] == 5, tags
    assert len(r["moments"]) == 5 and all(" found " in m for m in r["moments"]), r["moments"]

    # (no badges: who leads each score)
    assert r["awards"][0][0].startswith("Most Finds") and r["awards"][1][0].startswith("Longest Hidden"), r["awards"]
    assert r["awRight"] == "not ranked", r
    # the others (not ranked): their tables, a podium of three from the first one
    for key, title in (("infect", "Infections"), ("tmog", "Votes"), ("quiz", "Right"), ("redlight", "Finish")):
        r = res[key]
        assert r["tables"] and r["tables"][0][0] == title, (key, r["tables"])
        assert len(r["peds"]) == 3 and r["peds"][0][1] == P[0], (key, r["peds"])
        assert len(r["tables"][0][2]) == 7, (key, r["tables"])
    assert res["redlight"]["tables"][0][2][0][2] == "4:37", res["redlight"]["tables"]
    w.assert_no_errors()


@case
def library_cards_show_their_kinds_and_examples_open_the_builder():
    w, g = one()
    g.eval("""for _, e in ipairs(ns.EventBlocks:Examples()) do
        local d = ns.Events:CopyDef(e.def); d.name = e.name; assert(ns.Events:SaveDef(d)) end""")
    g.eval("ns.EventsUI:Open('library')")
    w.tick(0.3)
    cards = g.eval_py("""
        local v = ns.EventsUI:GetViewFrame('library')
        local out = {}
        for _, c in ipairs(v.cards) do
          if c:IsShown() then
            local shown, x = {}, 0
            for _, m in ipairs(c.minis) do if m:IsShown() then shown[#shown + 1] = m.fs:GetText(); x = x + m:GetWidth() + 4 end end
            local all = {}
            for _, k in ipairs(ns.EventBlocks:Kinds(c.def, true)) do all[#all + 1] = ns.EventBlocks:KindLabel(k) end
            out[c.n:GetText()] = { shown = shown, all = all, room = c:GetWidth() - 20, used = x - 4 }
          end
        end
        return out""")
    assert len(cards) == 8, cards
    for name, c in cards.items():
        # in their order, as many as fit; what goes first: Scores, Lists, then Sign-up
        it = iter(c["all"])
        assert all(x in it for x in c["shown"]), (name, c)
        assert c["used"] <= c["room"], (name, c)
        dropped = [x for x in c["all"] if x not in c["shown"]]
        order = ["Scores", "Lists", "Sign-up", "Places", "Tags", "Asks", "Matches"]
        kept = [x for x in c["all"] if x in c["shown"]]
        assert all(order.index(d) <= min(order.index(k) for k in kept) for d in dropped), (name, c)
        for k in ("Matches", "Asks", "Tags"):
            if k in c["all"]:
                assert k in c["shown"], (name, c)
    assert cards["Friday duel cup"]["shown"] == ["Sign-up", "Matches"], cards["Friday duel cup"]
    assert cards["Fishing derby"]["shown"] == ["Sign-up", "Scores"], cards["Fishing derby"]
    # hovered, a card's chips make way for its actions
    did = g.eval_py("local v = ns.EventsUI:GetViewFrame('library'); return v.cards[1].def.id")
    g.eval("ns.EventsUI:SetLibraryHover(...)", did)
    assert g.eval_py("local c = ns.EventsUI:GetViewFrame('library').cards[1]; return { c.acts:IsShown(), "
                     "c.minis[1]:IsShown() }") == [True, False]
    g.eval("ns.EventsUI:SetLibraryHover(nil)")
    # Examples, beside New event: its menu lists the eight with their icons; one opens the builder as my own event
    v = "ns.EventsUI:GetViewFrame('library')"
    assert g.eval_py("local b = %s.examples; return { b:IsShown(), b:GetText() }" % v) == [True, "Examples"]
    g.eval("%s.examples:Click()" % v)
    w.tick(0.2)
    menu = g.eval_py("""local m = ns.UI:GetOpenMenu()
        if not m then return nil end
        local out = {}
        for _, d in ipairs(m.root.children) do out[#out + 1] = { d.kind, d.text } end
        return out""")
    assert menu and menu[0] == ["title", "Start from an example"], menu
    names = [x[1].split("  ", 1)[1] for x in menu[1:]]
    assert names == ["Friday duel cup", "Hide and seek in Nagrand", "Infection", "Mount race", "Fishing derby",
                     "Transmog contest", "Trivia night", "Red light, green light"], names
    assert all(x[1].startswith("|TInterface\\Icons\\") for x in menu[1:]), menu
    tip = g.eval_py("""local m = ns.UI:GetOpenMenu(); local d = m.root.children[5]
        local lines = {}
        local tt = { AddLine = function(_, t) lines[#lines + 1] = t end }
        d.tooltip(tt); return lines""")
    assert tip[0] == "Mount race" and tip[1].startswith("A Route of places, a Time score and the arrow."), tip
    g.eval("ns.UI:GetOpenMenu().root.children[5]:cdlPick()")
    w.tick(0.3)
    b = g.eval_py("""local S = ns.EventBuilder:GetState()
        return { shown = ns.EventBuilder:IsShown(), name = S.def.name, ro = S.readOnly, mine = S.def.by == ns.Util.PlayerKey(),
                 saved = ns.Events:GetDef(S.def.id) ~= nil, route = S.def.lists and S.def.lists.ls1 and #S.def.lists.ls1.items }""")
    assert b == {"shown": True, "name": "Mount race", "ro": False, "mine": True, "saved": False, "route": 8}, b
    assert g.eval_py("return ns.UI:GetOpenMenu() == nil") is True
    # Upcoming has it too (the Library's own beside its New event)
    g.eval("ns.EventBuilder:Close(); ns.EventsUI:Open('upcoming')")
    w.tick(0.3)
    assert g.eval_py("local p = ns.EventsUI:GetPanel(); return { p.exBtn:IsShown(), p.newBtn:IsShown() }") == [True, True]
    g.eval("ns.EventsUI:Open('library')")
    w.tick(0.3)
    assert g.eval_py("return ns.EventsUI:GetPanel().exBtn:IsShown()") is False
    w.assert_no_errors()


@case
def the_review_shows_definition_changes_and_what_it_gives():
    w, (gina, bert) = guild(["Gina", "Bert"])
    did = bert.eval("""local d = ns.Events:CopyDef(ns.EventBlocks:Example('hide')); assert(ns.Events:SaveDef(d))
        ns.Events:SubmitForReview(d.id, 'first'); return d.id""")
    w.tick(10)
    assert gina.eval_py("return ns.Events:Review(..., true)", did) is True
    w.tick(10)
    # Bert changes its definitions (and one timer) and sends it in again
    bert.eval("""local d = ns.EventBlocks.Copy(ns.Events:GetDef(...))
        d.tags.tg3.n, d.tags.tg3.c = 'Caught', 'grey'
        d.tags.tg4 = { n = 'Ghosts', c = 'teal', shown = 'self' }
        d.places.pc1.r = 400
        d.scores.sc3 = { n = 'Hints', high = true, fmt = 'num', board = true }
        for _, s in ipairs(d.scripts) do
          ns.EventBlocks:Walk(s.top, function(p) if p.k == 'tm.start' and p.a[2] == 'Seek' then p.a[1] = 900 end end)
        end
        assert(ns.Events:SaveDef(d)); assert(ns.Events:SubmitForReview(d.id, 'second'))""", did)
    w.tick(10)
    gina.eval("ns.MainFrame:Open('events'); ns.EventsUI:Open('review'); ns.EventsUI:SelectReview(...)", did)
    w.tick(0.3)
    rv = gina.eval_py("""local v = ns.EventsUI:GetViewFrame('review')
        local rows, gives = {}, {}
        for _, r in ipairs(v.diffs) do
          if r:IsShown() then rows[#rows + 1] = { r.stage:GetText(), r.fs:IsShown() and r.fs:GetText() or '(piece)', r.dot:IsShown() } end
        end
        for _, g in ipairs(v.gives) do
          if g:IsShown() then gives[#gives + 1] = { g.n:GetText(), g.l2:IsShown() and g.l2:GetText() or '', g.r:GetText() } end
        end
        return { label = v.csect.t:GetText(), rows = rows, gives = gives }""")
    assert rv["label"] == "What changed since it was ranked", rv
    rows = [tuple(x) for x in rv["rows"]]
    assert ("Tags", "Tag: Caught (was Found), colour grey (was purple)", True) in rows, rows
    assert ("Tags", "New tag: Ghosts, only the players who have it see it", True) in rows, rows
    assert ("Places", "Place: Play area, 400 yd (was 600 yd)", False) in rows, rows
    assert ("Scores", "New score: Hints, higher wins, a number, on the board", False) in rows, rows
    assert ("Seek", "(piece)", False) in rows, rows
    # (the definitions' rows first: they say what the pieces mean)
    assert rows[-1][1] == "(piece)", rows
    gives = [tuple(x) for x in rv["gives"]]
    assert gives[:2] == [("Sharp eyes", "most Finds", "+20 · title"), ("Last one found", "longest Hidden", "+20 · title")], gives
    assert ("Hints", "most wins, on the board", "") in gives, gives
    assert gives[-1] == ("Season points", "5 for playing", ""), gives
    w.assert_no_errors()


@case
def a_live_derby_banner_says_my_place_and_its_time_left():
    w, (gina, bert) = guild(["Gina", "Bert"])
    occ = gina.eval("""local d = ns.Events:CopyDef(ns.EventBlocks:Example('fish')); assert(ns.Events:SaveDef(d))
        return ns.Events:Schedule(d.id, GetServerTime() + 30)""")
    w.run_until(lambda: bert.eval("return ns.Events:GetOcc(...) ~= nil", occ), timeout=60, step=0.5)
    assert bert.eval("return (ns.Events:SignUp(..., true))", occ)
    w.tick(3)
    assert gina.eval_py("return { ns.EventLive:Start(...) }", occ)[0] is True
    w.tick(3)
    for it in (27422, 27425):
        bert.eval("__MOCK.fish_loot({ { %d, 1 } })" % it)
        w.tick(2)
    w.tick(5)
    bert.eval("ns.MainFrame:Open('events'); ns.EventsUI:Open('upcoming')")
    w.tick(0.5)
    hero = bert.eval_py("""local h = ns.EventsUI:GetViewFrame('upcoming').hero
        local kinds = {}
        for _, m in ipairs(h.kinds or {}) do if m:IsShown() then kinds[#kinds + 1] = m.fs:GetText() end end
        return { title = h.title:GetText(), live = h.live:IsShown(), kick = h.kick:GetText(), btn = h.btn:GetText(),
                 chip = h.chip:IsShown() and h.chip.fs:GetText() or nil, face = h.chip.cls:IsShown() and h.chip.key,
                 prog = h.prog:IsShown(), kinds = kinds }""")
    assert hero["title"] == "Fishing derby" and hero["live"] is True and hero["btn"] == "Watch", hero
    assert re.match(r"^FISHING · (30|29) MIN LEFT$", hero["kick"]), hero
    assert hero["chip"] == "You're 1st" and hero["face"] == K("Bert") and hero["prog"] is True, hero
    assert hero["kinds"] == ["Sign-up", "Scores"], hero
    # its page: the stage now, with its time left; each player's fish next to their name (no seeds: no Matches)
    bert.eval("ns.EventsUI:OpenEvent(...)", occ)
    w.tick(0.5)
    page = bert.eval_py(READ_PAGE)
    fishing = [s for s in page["stages"] if s["name"] == "Fishing"][0]
    assert re.match(r"^now · (30|29) min left$", fishing["when"]), fishing
    ents = bert.eval_py("local out = {}; for _, e in ipairs(ns.EventsUI:GetViewFrame('event').ents) do "
                        "if e:IsShown() and e.face.key then out[e.face.key] = e.sd:IsShown() and e.sd:GetText() or '' end end; "
                        "return out")
    assert ents == {K("Gina"): "", K("Bert"): "2"}, ents
    # the host has no fish: no chip
    gina.eval("ns.MainFrame:Open('events'); ns.EventsUI:Open('upcoming')")
    w.tick(0.5)
    assert gina.eval_py("return ns.EventsUI:GetViewFrame('upcoming').hero.chip:IsShown()") is False
    w.assert_no_errors()


@case
def demo_mode_shows_the_derby_the_trivia_night_and_hide_and_seek():
    w = World()
    g = Client(w, "Gina", guild_rank=0, class_file="PALADIN")
    g.load_addon()
    w.tick(3)
    g.slash("/dz demo on")
    w.tick(1)
    g.eval("ns.EventsUI:Open('upcoming')")
    w.tick(0.3)
    rows = g.eval_py("local out = {}; for _, r in ipairs(ns.EventsUI:GetViewFrame('upcoming').rows) do "
                     "if r:IsShown() then out[r.occId] = r.l2:GetText() end end; return out")
    assert rows["odemo4"].startswith("Scores") and rows["odemo5"].startswith("Asks"), rows
    assert rows["odemo2"].startswith("Matches"), rows
    # (last derby: won by the first of its Fish table, my place in it)
    assert rows["rdemo3"].startswith("Won by ") and "you placed " in rows["rdemo3"], rows

    # the derby's page and last derby's results: its Fish table, the podium from it
    g.eval("ns.EventsUI:OpenEvent('odemo4')")
    w.tick(0.3)
    page = g.eval_py(READ_PAGE)
    assert ("most Fish wins", "glyph") in chips_of(page, "Fishing"), page
    g.eval("ns.EventsUI:OpenEvent('rdemo3')")
    w.tick(0.3)
    r = g.eval_py(READ_RESULTS)
    fish = r["tables"][0]
    nums = [int(x[2]) for x in fish[2]]
    assert fish[0] == "Fish" and nums == sorted(nums, reverse=True) and len(nums) >= 9, fish
    assert [x[1] for x in r["peds"]] == [x[1] for x in fish[2][:3]], (r["peds"], fish)
    assert r["awards"][0][0].startswith("Angler of the night") and r["awards"][0][2] == "+30", r["awards"]
    assert r["awards"][1][1].endswith(" Fish") and not r["l4"], r
    # (the derby isn't dressed as a duel cup: no last four, no numbers)
    assert g.eval_py("return ns.EventsUI:GetViewFrame('event').res.num:IsShown()") is False
    # my hide and seek in the library: its tags among its chips
    g.eval("ns.EventsUI:Open('library')")
    w.tick(0.3)
    chips = g.eval_py("""for _, c in ipairs(ns.EventsUI:GetViewFrame('library').cards) do
        if c:IsShown() and c.def.id == 'edemo3' then
          local out = {}
          for _, m in ipairs(c.minis) do if m:IsShown() then out[#out + 1] = m.fs:GetText() end end
          return out
        end end""")
    assert "Tags" in chips and "Places" in chips, chips
    # and its review: it gives two badges decided by two scores, and season points for playing
    g.eval("ns.EventsUI:Open('review'); ns.EventsUI:SelectReview('edemo3')")
    w.tick(0.3)
    gives = g.eval_py("local out = {}; for _, x in ipairs(ns.EventsUI:GetViewFrame('review').gives) do "
                      "if x:IsShown() then out[#out + 1] = x.n:GetText() end end; return out")
    assert gives == ["Sharp eyes", "Last one found", "Season points"], gives
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

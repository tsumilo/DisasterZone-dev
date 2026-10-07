"""Events part 2: the edges of the general blocks, found by playing the examples (2026-10-07 QA pass), run straight on
ns.EventEngine with a fake clock (like test_kinds_engine.py) or across a few clients where the network matters.

Covers: a restored run's waiting scripts (waits, asks, inside if / repeat / for each / for each item, nested; a script
that changed; part 1's question who won); asks (time-outs, nobody answers, ties, votes for oneself, answers after the
close, the host's own answers as a non-entrant, more picks than allowed); buttons pressed many times; touches of
non-entrants and of the host; places at an edge and across a zone border; lists (the end, empty); scores (ties, the
lead on equal values, negative, caps, a player who left); tags (an odd split, a tag gone); text with escape codes and
very long text; a library rename while the event runs on its copy; positions in an instance; duel reports of two
clocks apart; demo mode and practice; sign-ups at the limit.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_kinds_edge.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

HELLO = 50
CLASSES = ["PALADIN", "MAGE", "ROGUE", "WARRIOR", "PRIEST", "DRUID", "HUNTER", "SHAMAN", "WARLOCK"]
NAGRAND = 1951
YD = 1.0 / 5525.0
YDY = 1.0 / 3683.33

# K.mk(def, n, opts): a live run of n players P1..Pn hosted by Host (not an entrant), a fake clock K.clock, a world of
# 1000 x 1000 yards maps; what the addon would do in K.shown, K.told, K.posts, K.sounds, K.plates; its log K.logs.
HELPERS = r"""
K = {}
local E, B = ns.EventEngine, ns.EventBlocks
N, C, V, J, If, IfElse, Each, ForItems, T = B.Build.N, B.Build.C, B.Build.V, B.Build.J, B.Build.If, B.Build.IfElse,
  B.Build.Each, B.Build.ForItems, B.Build.T
S = function(...) return B:Stack(...) end
HOST = "Host-Thunderstrike"
function K.short(k) return type(k) == "string" and (k:gsub("%-.*", "")) or tostring(k) end
function K.keys(list) local o = {} for i, k in ipairs(list or {}) do o[i] = K.short(k) end return table.concat(o, ",") end
function K.P(i) return "P" .. i .. "-Thunderstrike" end
function K.opts()
  return { now = function() return K.clock end, out = K.out, nameOf = K.short,
    worldPos = function(map, x, y) return 1, x * 1000, y * 1000 end }
end
function K.mk(def, n, opts)
  opts = opts or {}
  local names = {}
  for i = 1, n do names[i] = K.P(i) end
  K.clock = K.clock or 1000
  K.shown, K.told, K.posts, K.sounds, K.plates, K.logs = {}, {}, {}, {}, {}, {}
  K.out = {
    show = function(keys, text) K.shown[#K.shown + 1] = { to = K.keys(keys), text = text } end,
    tell = function(keys, text) for _, k in ipairs(keys) do K.told[#K.told + 1] = { k = K.short(k), text = text } end end,
    guild = function(text) K.posts[#K.posts + 1] = text end,
    sound = function(keys, s) K.sounds[#K.sounds + 1] = K.keys(keys) .. ":" .. s end,
    plates = function(keys, off) K.plates[#K.plates + 1] = K.keys(keys) .. ":" .. tostring(off) end,
    log = function(kind, text) K.logs[#K.logs + 1] = kind .. ": " .. tostring(text) end,
  }
  local o = K.opts()
  o.id, o.host, o.signups = opts.id or "k", HOST, opts.signups or names
  K.run = E:New(def, o)
  K.names = names
  if not opts.noStart then K.run:Start() end
  return K.run, names
end
-- the run as a /reload or a takeover brings it back (full: the host's own disk; else the state that went out)
function K.restore(full)
  local snap = K.run:Snapshot(full)
  snap = B.Copy(snap)
  K.run = E:Restore(K.run.def, snap, K.opts())
  return K.run
end
function K.adv(sec) for i = 1, sec do K.clock = K.clock + 1; K.run:Tick() end end
function K.untilit(fn, max) for i = 1, max or 600 do if fn() then return true end K.adv(1) end return fn() and true or false end
function K.errors()
  local out = {}
  for _, l in ipairs(K.logs) do if l:find("^error") then out[#out + 1] = l end end
  return out
end
function K.tags(tid) return K.keys(K.run:Tagged(tid)) end
function K.scores(sid)
  local o = {}
  for _, r in ipairs(K.run:Ranked(sid)) do o[#o + 1] = K.short(r.key) .. "=" .. r.n end
  return table.concat(o, " ")
end
function K.told_to(who) local o = {} for _, t in ipairs(K.told) do if t.k == who then o[#o + 1] = t.text end end return o end
function K.texts(list) local o = {} for _, x in ipairs(list) do o[#o + 1] = x.text end return o end
function K.moments() local o = {} for _, m in ipairs(K.run.st.moments) do o[#o + 1] = m.text end return o end
function K.awards()
  local o = {}
  for _, a in ipairs(K.run.st.awards) do o[#o + 1] = K.short(a.p) .. ":" .. a.b end
  table.sort(o)
  return o
end
function K.bare(...)
  local d = B:Blank("t")
  d.scripts = {}
  for i, top in ipairs({ ... }) do d.scripts[i] = { id = "x" .. i, st = "*", top = top } end
  return d
end
"""


def one():
    w = World()
    c = Client(w, "Gina", guild_rank=0)
    c.load_addon()
    w.tick(2)
    c.eval(HELPERS)
    return w, c


def K(n):
    return n + "-Thunderstrike"


def guild(names, tick=HELLO, **kw):
    w = World(**kw)
    cs = []
    for i, n in enumerate(names):
        cs.append(Client(w, n, guild_rank=0 if i == 0 else 3, class_file=CLASSES[i % len(CLASSES)]))
    for c in cs:
        c.load_addon()
    w.tick(tick)
    return w, {c.name: c for c in cs}, cs


# ------------------------------------------------------------------------------------------------------------------
# A restored run goes on where its scripts were
# ------------------------------------------------------------------------------------------------------------------
@case
def a_restored_run_goes_on_inside_loops_and_ifs_where_it_waited():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local d = K.bare(
          S(N("ev.start"),
            N("ch.moment", "begin"),
            If(N("lo.gt", 2, 1),
              N("lo.rep", 2),
              Each(N("pl.all"),
                N("ch.moment", J("each ", C("each"))),
                ForItems("ls1",
                  N("tm.wait", 10),
                  N("ch.moment", J(C("each"), " ", C("item")))))),
            N("ch.moment", "end")))
        d.lists = { ls1 = { n = "L", kind = "text", items = { "a", "b" } } }
        -- (repeat 2 times around for each: its inside is set below)
        local rep = d.scripts[1].top.n.n.c1
        rep.c1 = rep.n
        rep.n = nil
        local run = K.mk(d, 2)
        K.adv(25)   -- P1: a, b done; P2 waiting before a
        local before = K.moments()
        -- the host reloads (its own disk): the script goes on from the wait it was in
        K.restore(true)
        K.adv(200)
        return { before = before, after = K.moments(), err = K.errors(), threads = (function() local n = 0
          for _ in pairs(K.run.threads) do n = n + 1 end return n end)(), phase = K.run.st.phase }""")
    want = ["begin", "each P1", "P1 a", "P1 b", "each P2", "P2 a", "P2 b",
            "each P1", "P1 a", "P1 b", "each P2", "P2 a", "P2 b", "end"]
    assert out["before"] == want[:5], out["before"]
    # nothing before the wait runs again, everything after it runs once
    assert out["after"] == want, out["after"]
    assert out["err"] == [] and out["threads"] == 0, out
    w.assert_no_errors()


@case
def a_takeover_goes_on_from_the_state_that_went_out_and_secret_answers_stay_unknown():
    w, c = one()
    out = c.eval_py("""
        local d = K.bare(S(N("ev.start"), N("as.ask", N("pl.all"), "ak1"),
            N("ch.moment", J("top: ", N("as.top", "ak1"), ", P1 said ", N("as.answer", K.P(1), "ak1")))),
          S(N("as.on", "ak1"), N("ch.moment", J(C("player"), " answered"))))
        d.asks = { ak1 = { n = "Pick", q = "Who?", kind = "player", from = "entrants", votes = 1, self = false, time = 60,
                           secret = true } }
        local run = K.mk(d, 3)
        local P1, P2, P3 = K.P(1), K.P(2), K.P(3)
        run:AskAnswer("ak1", P1, P2)
        -- the state as it went out: P1's answer only "answered"
        K.restore(false)
        local r = { open = K.run.st.qa.ak1.open, lost = K.run.st.qa.ak1.lost and K.run.st.qa.ak1.lost[P1] or false,
          again = K.run:AskAnswer("ak1", P1, P3) }
        K.run:AskAnswer("ak1", P2, P3)
        K.run:AskAnswer("ak1", P3, P1)
        r.moments = K.moments()
        r.err = K.errors()
        -- (the closed ask's result as a watcher reads it: P1's lost answer isn't counted)
        local tally = ns.EventEngine:Reader(K.run.def, K.run:Snapshot()):Tally("ak1")
        r.tally = {}
        for _, t in ipairs(tally) do r.tally[#r.tally + 1] = K.short(t.v) .. "=" .. t.n end
        return r""")
    assert out["open"] is True and out["lost"] is True and out["again"] is False, out
    # the script that asked goes on once everyone answered; P1's answer counts for nobody (P3 got 1, P1 got 1: a tie,
    # P3 picked first)
    assert out["moments"] == ["P1 answered", "P2 answered", "P3 answered", "top: P3, P1 said "], out["moments"]
    assert out["tally"] == ["P3=1", "P1=1"] and out["err"] == [], out
    w.assert_no_errors()


@case
def a_script_that_changed_or_a_question_who_won_doesnt_come_back():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local d = K.bare(S(N("ev.start"), N("tm.wait", 30), N("ch.moment", "after")),
                         S(N("ev.start"), N("tm.wait", 30), N("ch.moment", "second")))
        local run = K.mk(d, 2)
        K.adv(5)
        local snap = B.Copy(run:Snapshot(true))
        -- the def changed meanwhile: the first script's wait is a moment now (a run's def never changes, but a state
        -- may come from anywhere)
        local d2 = B.Copy(d)
        d2.scripts[1].top.n = N("ch.moment", "changed")
        K.run = ns.EventEngine:Restore(d2, snap, K.opts())
        K.adv(40)
        local r = { moments = K.moments(), err = K.errors() }
        -- part 1's question who won: dropped with its script (the host decides the match)
        local cup = B:Example("duel")
        cup.blocks.b2.set.seed = "order"
        local run2 = K.mk(cup, 4)
        local bk = run2:MainBracket()
        local m = bk.m[bk.rounds[1][1]]
        run2:Duel(m.a, m.b, false)
        r.asked = next(run2.st.asks) ~= nil
        local waits = run2:Snapshot(true).waits
        r.waits = #waits
        local run3 = ns.EventEngine:Restore(run2.def, run2:Snapshot(true), K.opts())
        r.asks3 = next(run3.st.asks) ~= nil
        r.threads3 = 0
        for _ in pairs(run3.threads) do r.threads3 = r.threads3 + 1 end
        return r""")
    assert out["moments"] == ["second"], out["moments"]
    assert any("couldn't go on" in e or "can't go on" in e for e in out["err"]), out["err"]
    assert out["asked"] is True and out["waits"] == 0 and out["asks3"] is False and out["threads3"] == 0, out
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Asks
# ------------------------------------------------------------------------------------------------------------------
@case
def asks_time_out_nobody_answers_ties_and_late_answers():
    w, c = one()
    out = c.eval_py("""
        local d = K.bare(
          S(N("ev.start"), N("as.ask", N("pl.all"), "ak1"),
            IfElse(N("lo.set", N("as.top", "ak1")), N("ch.moment", J("top ", N("as.top", "ak1"))), N("ch.moment", "nobody")),
            N("as.ask", N("pl.all"), "ak1"), N("ch.moment", J("top ", N("as.top", "ak1"), " ", N("as.count", K.P(1), "ak1")))),
          S(N("as.closed", "ak1"), N("ch.moment", "closed")))
        d.asks = { ak1 = { n = "Best", q = "Who?", kind = "player", from = "entrants", votes = 2, self = false, time = 20 } }
        local run = K.mk(d, 3)
        local P1, P2, P3 = K.P(1), K.P(2), K.P(3)
        -- nobody answers: it closes at its time
        K.adv(21)
        local r = { first = K.moments() }
        -- votes for oneself refused; a tie: the one picked first
        r.self = run:AskAnswer("ak1", P1, { P1 })
        run:AskAnswer("ak1", P1, { P2 })
        run:AskAnswer("ak1", P2, { P1 })
        K.adv(21)
        -- after the close: refused
        r.late = run:AskAnswer("ak1", P3, { P1 })
        r.moments = K.moments()
        r.err = K.errors()
        return r""")
    assert out["first"] == ["closed", "nobody"], out["first"]
    assert out["self"] is False and out["late"] is False, out
    assert out["moments"] == ["closed", "nobody", "closed", "top P2 1"], out["moments"]
    assert out["err"] == [], out
    w.assert_no_errors()


@case
def the_derby_knows_mr_pinchy_by_his_item_whatever_the_client_calls_him():
    w, c = one()
    out = c.eval_py("""
        local run = K.mk(ns.EventBlocks:Example("fish"), 2)
        run:Happen(K.P(1), "fish", { item = 27388, name = "Herr Zwickel" })
        run:Happen(K.P(2), "fish", { item = 27422, name = "Mr. Pinchy" })
        return K.moments()""")
    assert out == ["P1 fished up Mr. Pinchy"], out
    w.assert_no_errors()


@case
def an_ask_doesnt_wait_for_who_went_offline():
    w, c = one()
    out = c.eval_py("""
        local d = K.bare(S(N("ev.start"), N("as.ask", N("pl.all"), "ak1"), N("ch.moment", "next")))
        d.asks = { ak1 = { n = "Q", q = "Ready?", kind = "yesno", time = 120 } }
        local run = K.mk(d, 3)
        local P1, P2, P3 = K.P(1), K.P(2), K.P(3)
        run:AskAnswer("ak1", P1, true)
        run:AskAnswer("ak1", P2, false)
        local r = { before = run.st.qa.ak1.open }
        -- P3's game goes away: the ask has all it waits for
        run:SetOnline(P3, false)
        r.after = run.st.qa.ak1.open
        r.moments = K.moments()
        -- (one who is offline when the others answer doesn't hold it up either)
        local run2 = K.mk(d, 3)
        run2:SetOnline(P3, false)
        run2:AskAnswer("ak1", P1, true)
        r.second = { run2.st.qa.ak1.open }
        run2:AskAnswer("ak1", P2, true)
        r.second[2] = run2.st.qa.ak1.open
        return r""")
    assert out["before"] is True and out["after"] is False and out["moments"] == ["next"], out
    assert out["second"] == [True, False], out
    w.assert_no_errors()


@case
def the_host_answers_its_asks_and_presses_its_buttons_without_being_an_entrant():
    w, by, cs = guild(["Gina", "Bert", "Cora", "Dain"])
    g, b, co, d = cs
    occ = g.eval("""
        local B = ns.EventBlocks
        local d = ns.EventBlocks:Example('tmog')
        d.id, d.by = nil, nil
        d.asks.ak1.time = 30
        assert(ns.Events:SaveDef(d))
        return ns.Events:Schedule(d.id, GetServerTime() + 30, { noJoin = true })""")
    w.tick(3)
    w.run_until(lambda: all(c.eval("return ns.Events:GetOcc(...) ~= nil", occ) for c in cs[1:]), timeout=60, step=0.5)
    for c in (b, co, d):
        assert c.eval("return (ns.Events:SignUp(..., true))", occ)
    w.tick(3)
    assert g.eval_py("return { ns.EventLive:Start(...) }", occ)[0] is True
    w.tick(3)
    assert K("Gina") not in g.eval_py("return ns.EventLive:GetState(...).entrants", occ)
    # the host (not an entrant) is asked who judges: her prompt shows it, and her answer counts
    asks = g.eval_py("local o = {} for _, a in ipairs(ns.EventLive:MyAsks(...)) do o[#o + 1] = a.id end return o", occ)
    assert asks == ["ak1"], asks
    assert g.eval("return ns.EventLive:AnswerAsk2(...)", occ, "ak1", [K("Bert")]) is True
    w.tick(3)
    assert sorted(g.eval_py("return ns.EventLive:GetState(...).tags.tg1", occ)) == [K("Bert")]
    w.assert_no_errors()


@case
def more_picks_than_an_ask_takes_are_refused():
    w, by, cs = guild(["Gina", "Bert", "Cora", "Dain", "Eve"])
    g = cs[0]
    occ = g.eval("""
        local B = ns.EventBlocks
        local N, C = B.Build.N, B.Build.C
        local d = ns.Events:NewDef(false)
        d.asks = { ak1 = { n = 'Best', q = 'Who?', kind = 'player', from = 'entrants', votes = 3, self = false, time = 60 } }
        d.scripts = { { id = 'a', st = '*', x = 0, y = 0, top = B:Stack(N('ev.start'), N('as.ask', N('pl.all'), 'ak1')) } }
        assert(ns.Events:SaveDef(d))
        return ns.Events:Schedule(d.id, GetServerTime() + 30)""")
    w.tick(3)
    w.run_until(lambda: all(c.eval("return ns.Events:GetOcc(...) ~= nil", occ) for c in cs[1:]), timeout=60, step=0.5)
    for c in cs[1:]:
        assert c.eval("return (ns.Events:SignUp(..., true))", occ)
    w.tick(3)
    assert g.eval_py("return { ns.EventLive:Start(...) }", occ)[0] is True
    w.tick(4)
    b = by["Bert"]
    four = [K("Cora"), K("Dain"), K("Eve"), K("Gina")]
    assert b.eval("return ns.EventLive:AnswerAsk2(...)", occ, "ak1", four) is False
    assert b.eval("return ns.EventLive:AnswerAsk2(...)", occ, "ak1", four[:3]) is True
    w.tick(3)
    assert len(g.eval_py("return ns.EventLive:GetState(...).qa.ak1.ans['Bert-Thunderstrike']", occ)) == 4  # (3 + list)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Buttons, touches, places, lists
# ------------------------------------------------------------------------------------------------------------------
@case
def a_button_pressed_many_times_runs_once_while_it_is_taken():
    w, c = one()
    out = c.eval_py("""
        local d = K.bare(
          S(N("ev.start"), N("as.give", N("pl.all"), "Go")),
          S(N("as.press", "Go"), N("as.take", "Go", C("player")), N("ch.moment", J(C("player"), " went")), N("tm.wait", 10),
            N("as.give", C("player"), "Go")),
          S(N("ev.start"), N("as.give", N("pl.all"), "Ping")),
          S(N("as.press", "Ping"), N("pt.add", 1, "sc1", C("player"))))
        d.scores = { sc1 = { n = "Pings", high = true, fmt = "num", board = true, cap = 5 } }
        local run = K.mk(d, 2)
        local P1 = K.P(1)
        local r = { go = {} }
        for i = 1, 5 do r.go[i] = run:Press(P1, "Go") end
        for i = 1, 9 do run:Press(P1, "Ping") end
        K.adv(11)
        r.back = run:Press(P1, "Go")
        r.moments = K.moments()
        r.pings = run:GetScore("sc1", P1)
        return r""")
    assert out["go"] == [True, False, False, False, False] and out["back"] is True, out
    assert out["moments"] == ["P1 went", "P1 went"], out["moments"]
    # (a score with a cap stays within it)
    assert out["pings"] == 5, out
    w.assert_no_errors()


@case
def touches_of_non_entrants_dont_count_and_the_host_may_be_touched():
    w, c = one()
    out = c.eval_py("""
        local d = K.bare(S(N("pl.touch", nil, nil, "click"), N("ch.moment", J(C("toucher"), " got ", C("touched")))))
        local run = K.mk(d, 2)
        local P1, P2 = K.P(1), K.P(2)
        return { out = run:Touch(P1, "Out-Thunderstrike", "click"), by = run:Touch("Out-Thunderstrike", P1, "click"),
          host = run:Touch(P1, HOST, "click"), self = run:Touch(P1, P1, "click"), hostBy = run:Touch(HOST, P1, "click"),
          moments = K.moments() }""")
    assert out["out"] is False and out["by"] is False and out["self"] is False, out
    # the host may be found (whom), but isn't one who touches unless an entrant
    assert out["host"] is True and out["hostBy"] is False and out["moments"] == ["P1 got Host"], out
    w.assert_no_errors()


@case
def pointing_someone_where_they_are_already_shows_no_arrow():
    w, c = one()
    out = c.eval_py("""
        local d = K.bare(S(N("as.press", "Go"), N("pc.point", N("pl.all"), "pc1")),
                         S(N("as.press", "Away"), N("pc.point", N("pl.all"), "pc2")),
                         S(N("ev.start"), N("as.give", N("pl.all"), "Go"), N("as.give", N("pl.all"), "Away")))
        d.places = { pc1 = { n = "Here", map = 1, x = 0.5, y = 0.5, r = 30 }, pc2 = { n = "There", map = 1, x = 0.9, y = 0.9, r = 30 } }
        local run = K.mk(d, 2)
        local P1, P2 = K.P(1), K.P(2)
        run:Place(P1, "pc1", true)
        run:Press(P1, "Go")
        local r = { here = run.st.point[P1] or false, other = run.st.point[P2] or false }
        run:Press(P1, "Away")
        r.away = run.st.point[P1] or false
        return r""")
    assert out == {"here": False, "other": "pc1", "away": "pc2"}, out
    w.assert_no_errors()


@case
def lists_at_their_end_and_empty_ones():
    w, c = one()
    out = c.eval_py("""
        local d = K.bare(
          S(N("ev.start"), N("lo.lnext", N("pl.all"), "ls1"), N("lo.lnext", N("pl.all"), "ls1"), N("lo.lnext", N("pl.all"), "ls1"),
            N("ch.moment", J("at ", N("lo.lpos", K.P(1), "ls1"), " item ", N("lo.lmine", K.P(1), "ls1"))),
            ForItems("ls2", N("ch.moment", "never")),
            N("pc.point", N("pl.all"), N("lo.lmine", K.P(1), "ls2")),
            N("ch.moment", J("empty: ", N("lo.lcount", "ls2"), " ", N("lo.litem", 3, "ls1")))),
          S(N("lo.lend", "ls1"), N("ch.moment", J(C("player"), " at the end"))))
        d.lists = { ls1 = { n = "Two", kind = "text", items = { "a", "b" } }, ls2 = { n = "None", kind = "text", items = {} } }
        local run = K.mk(d, 1)
        return { moments = K.moments(), point = run.st.point[K.P(1)] or false, err = K.errors() }""")
    # the end is reached once (a third "move on" changes nothing; its hat runs once the script that got there
    # is done), "item 3" of two is nothing
    assert out["moments"] == ["at 3 item ", "empty: 0 ", "P1 at the end"], out["moments"]
    assert out["point"] is False and out["err"] == [], out
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Scores and tags
# ------------------------------------------------------------------------------------------------------------------
@case
def scores_tie_keep_the_lead_go_negative_and_leave_with_their_player():
    w, c = one()
    out = c.eval_py("""
        local d = K.bare(
          S(N("pt.lead", "sc1"), N("ch.moment", J(C("player"), " leads"))),
          S(N("pt.reach", "sc1", 3), N("ch.moment", J(C("player"), " reached 3"))))
        d.scores = { sc1 = { n = "Pts", high = true, fmt = "num", board = true },
                     sc2 = { n = "Low", high = false, fmt = "num", board = false, cap = 10 } }
        local run = K.mk(d, 3)
        local P1, P2, P3 = K.P(1), K.P(2), K.P(3)
        run:SetScore("sc1", P1, 2, true)
        run:SetScore("sc1", P2, 2, true)     -- (equal: P1 keeps the lead)
        run:SetScore("sc1", P2, 1, true)     -- P2 leads
        run:SetScore("sc1", P3, -4, true)    -- negative
        run:SetScore("sc2", P1, -50, false)  -- held to the cap
        run:Pump()
        local r = { places = { run:PlaceBy("sc1", P1), run:PlaceBy("sc1", P2), run:PlaceBy("sc1", P3) }, low = run:GetScore("sc2", P1),
          scores = K.scores("sc1") }
        -- P2 leaves: no score any more (nor a prize), the lead goes back to P1; scores for them are refused
        run:Leave(P2)
        run:Pump()
        run:SetScore("sc1", P2, 9, true)
        r.after = K.scores("sc1")
        r.moments = K.moments()
        return r""")
    assert out["places"] == [2, 1, 3] and out["low"] == -10 and out["scores"] == "P2=3 P1=2 P3=-4", out
    assert out["after"] == "P1=2 P3=-4", out["after"]
    # (one change: "reaches" before "the lead changes")
    assert out["moments"] == ["P1 leads", "P2 reached 3", "P2 leads", "P1 leads"], out["moments"]
    w.assert_no_errors()


@case
def an_odd_split_and_a_tag_that_is_gone():
    w, c = one()
    out = c.eval_py("""
        local B = ns.EventBlocks
        local d = K.bare(S(N("ev.start"), N("pl.split", N("pl.all"), "tg1", "tg2"), N("pl.tag", N("pl.all"), "tg9")))
        d.tags = { tg1 = { n = "Red" }, tg2 = { n = "Blue" } }
        local probs = B:Problems(d)
        local run = K.mk(d, 5)
        return { red = #run:Tagged("tg1"), blue = #run:Tagged("tg2"), gone = #run:Tagged("tg9"), prob = probs[1] and probs[1].text,
          err = K.errors() }""")
    # five: the first tag gets the odd one; a tag that's gone stops hosting (a problem) and tags nobody in a run
    assert out["red"] == 3 and out["blue"] == 2 and out["gone"] == 0, out
    assert out["prob"] == "That tag is gone." and out["err"] == [], out
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Text
# ------------------------------------------------------------------------------------------------------------------
@case
def text_with_escape_codes_and_very_long_text_is_cleaned_and_cut():
    w, by, cs = guild(["Gina", "Bert"])
    g, b = cs
    long = "é" * 400   # (two bytes a letter: cut between letters)
    occ = g.eval("""
        local B = ns.EventBlocks
        local N, C, J = B.Build.N, B.Build.C, B.Build.J
        local d = ns.Events:NewDef(false)
        local long = ...
        d.scripts = { { id = 'a', st = '*', x = 0, y = 0, top = B:Stack(N('ev.start'),
          N('ch.show', N('pl.all'), J('|cffff0000Red|r |Hitem:1|h[x]|h ', long)), N('ch.tell', N('pl.all'), long),
          N('ch.moment', long), N('ch.guild', long)) } }
        assert(ns.Events:SaveDef(d))
        return ns.Events:Schedule(d.id, GetServerTime() + 30)""", long)
    w.tick(3)
    w.run_until(lambda: b.eval("return ns.Events:GetOcc(...) ~= nil", occ), timeout=60, step=0.5)
    b.eval("""T_got = {}
        for _, m in ipairs({ 'EVENT_SHOW', 'EVENT_TELL' }) do ns:On(m, function(o, text) T_got[#T_got + 1] = { m, text } end) end""")
    assert b.eval("return (ns.Events:SignUp(..., true))", occ)
    w.tick(3)
    n0 = len(w.chat_log)
    assert g.eval_py("return { ns.EventLive:Start(...) }", occ)[0] is True
    w.tick(15)
    gotb = b.eval_py("return T_got")
    show = [x[1] for x in gotb if x[0] == "EVENT_SHOW"][0]
    tell = [x[1] for x in gotb if x[0] == "EVENT_TELL"][0]
    assert "|" not in show and show.startswith("cffff0000Redr Hitem:1h[x]h "), show
    for t, n in ((show, 200), (tell, 200)):
        assert len(t.encode("utf-8")) <= n and t.encode("utf-8").decode("utf-8"), (len(t.encode("utf-8")), n)
    post = [e["text"] for e in w.chat_log[n0:] if e["chat_type"] == "GUILD"]
    assert len(post) == 1 and len(post[0].encode("utf-8")) <= 250, post
    mom = g.eval_py("return ns.EventLive:GetState(...).moments[1].text", occ)
    assert len(mom.encode("utf-8")) <= 200, len(mom.encode("utf-8"))
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# The library's event renamed while its calendar copy runs
# ------------------------------------------------------------------------------------------------------------------
@case
def a_library_rename_doesnt_touch_the_running_copy():
    w, by, cs = guild(["Gina", "Bert", "Cora", "Dain"])
    g = cs[0]
    did = g.eval("""
        local d = ns.EventBlocks:Example('hide')
        d.id, d.by = nil, nil
        assert(ns.Events:SaveDef(d))
        return d.id""")
    occ = g.eval("return ns.Events:Schedule(..., GetServerTime() + 30)", did)
    w.tick(3)
    w.run_until(lambda: all(c.eval("return ns.Events:GetOcc(...) ~= nil", occ) for c in cs[1:]), timeout=60, step=0.5)
    for c in cs[1:]:
        assert c.eval("return (ns.Events:SignUp(..., true))", occ)
    w.tick(3)
    assert g.eval_py("return { ns.EventLive:Start(...) }", occ)[0] is True
    w.tick(3)
    # the owner renames the tags and the play area in the library meanwhile
    g.eval("""local d = ns.EventBlocks.Copy(ns.Events:GetDef(...))
        d.tags.tg1.n = 'Sneaks'; d.places.pc1.n = 'Somewhere else'; d.tags.tg3 = nil
        assert(ns.Events:SaveDef(d))""", did)
    w.tick(10)
    # the run and every client's tracker go on with the calendar event's copy
    assert g.eval_py("return ns.EventLive:GetDef(...).tags.tg1.n", occ) == "Hiders"
    for c in cs[1:]:
        tags = c.eval_py("local o = {} for _, t in ipairs(ns.EventLive:MyTags(...)) do o[#o + 1] = t.n end return o", occ)
        assert tags in (["Hiders"], ["Seekers"]), (c.name, tags)
        assert c.eval_py("return ns.EventLive:GetDef(...).places.pc1.n", occ) == "Play area"
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Places across a zone border, and a place that is a whole zone
# ------------------------------------------------------------------------------------------------------------------
@case
def places_across_a_zone_border_and_a_place_that_is_a_zone():
    w, by, cs = guild(["Gina", "Bert"])
    g, b = cs
    # a spot in Nagrand where the map overlaps Terokkar's (world y 6000, x -3000), and the zone of Nagrand itself
    nx, ny = (10150.0 - 6000) / 5525.0, (-1483.33 + 3000) / 3683.33
    tx, ty = (7083.33 - 6000) / 5400.0, (-1608.33 + 3000) / 3600.0
    w.set_position(b, 1955, 0.5, 0.5)   # (in Shattrath to begin with)
    occ = g.eval("""
        local B = ns.EventBlocks
        local N, C, J = B.Build.N, B.Build.C, B.Build.J
        local nx, ny = ...
        local d = ns.Events:NewDef(false)
        d.places = { pc1 = { n = 'Border', map = 1951, x = nx, y = ny, r = 30 }, pc2 = { n = 'Nagrand', z = 'Nagrand' } }
        d.scripts = { { id = 'a', st = '*', x = 0, y = 0, top = B:Stack(N('pc.enter'), N('ch.moment', J(C('player'), ' in ', C('place')))) },
                      { id = 'b', st = '*', x = 0, y = 0, top = B:Stack(N('pc.leave'), N('ch.moment', J(C('player'), ' out of ', C('place')))) } }
        assert(ns.Events:SaveDef(d))
        return ns.Events:Schedule(d.id, GetServerTime() + 30)""", nx, ny)
    w.tick(3)
    w.run_until(lambda: b.eval("return ns.Events:GetOcc(...) ~= nil", occ), timeout=60, step=0.5)
    assert b.eval("return (ns.Events:SignUp(..., true))", occ)
    w.tick(3)
    assert g.eval_py("return { ns.EventLive:Start(...) }", occ)[0] is True
    w.tick(3)

    def moments():
        return [m["text"] for m in (g.eval_py("return ns.EventLive:GetState(...).moments", occ) or [])]
    # on Terokkar's map, 10 yards from the spot: in it (world yards, whatever map the game puts him on); not in Nagrand
    w.set_position(b, 1952, tx + 10 / 5400.0, ty)
    w.tick(3)
    assert moments() == ["Bert in Border"], moments()
    # on Nagrand's map: in the zone too
    w.set_position(b, 1951, nx + 10 / 5525.0, ny)
    w.tick(3)
    assert moments() == ["Bert in Border", "Bert in Nagrand"], moments()
    # into Terokkar proper: out of both
    w.set_position(b, 1952, 0.5, 0.5)
    w.tick(3)
    assert sorted(moments()[2:]) == ["Bert out of Border", "Bert out of Nagrand"], moments()
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Where to go: the place an event meets at (def.meet, o.meet), MyMeet, PointMe
# ------------------------------------------------------------------------------------------------------------------
@case
def where_to_meet_for_a_planned_event_and_the_way_there():
    import math
    w, by, cs = guild(["Gina", "Bert", "Cora"])
    g, b, co = cs
    for c in cs:
        w.set_position(c, NAGRAND, 0.415, 0.47, subzone="Halaa")
    # every example with places says where to meet; the others don't
    meets = g.eval_py("local o = {} for _, e in ipairs(ns.EventBlocks:Examples()) do o[e.key] = e.def.meet or false end return o")
    assert meets == {"duel": False, "hide": "pc1", "infect": "pc1", "race": "pc1", "fish": False, "tmog": False,
                     "quiz": False, "redlight": "pc1"}, meets
    sched = """local key, meet = ...
        local d = ns.EventBlocks:Example(key)
        d.id, d.by = nil, nil
        assert(ns.Events:SaveDef(d))
        return ns.Events:Schedule(d.id, GetServerTime() + 3600, { meet = meet })"""
    occ = g.eval(sched, "redlight", None)
    occ2 = g.eval(sched, "redlight", "pc2")
    occ3 = g.eval(sched, "redlight", "nowhere")
    occ4 = g.eval(sched, "fish", None)
    w.tick(3)
    w.run_until(lambda: all(b.eval("return ns.Events:GetOcc(...) ~= nil", o) for o in (occ, occ2, occ3, occ4)), timeout=90,
                step=0.5)
    meet = "local o = ns.Events:GetOcc(...); return ns.Events:MeetOf(o) or false"
    # the calendar event's own choice, else the event's (a place it doesn't have: the event's); none without places
    assert [b.eval(meet, o) for o in (occ, occ2, occ3, occ4)] == ["pc1", "pc2", "pc1", False]
    # Bert, signed up or not, planned: where to meet, how far, which way (the start line: 55 yards west, 110 north)
    pid, yards, bearing = b.eval_py("return { ns.EventLive:MyMeet(...) }", occ)
    want = math.hypot(55.25, 110.5)
    assert pid == "pc1" and abs(yards - want) < 2 and abs(bearing - math.atan2(55.25, 110.5)) < 0.02, (pid, yards, bearing)
    assert b.eval_py("return { ns.EventLive:MyMeet(...) }", occ4) == []
    # nothing points him there yet; he asks to be shown the way (his own: nothing goes out)
    assert b.eval_py("return { ns.EventLive:MyPoint(...) }", occ) == []
    a0 = len(w.addon_log)
    assert b.eval("return ns.EventLive:PointMe(..., 'pc1')", occ) is True
    assert b.eval("return ns.EventLive:PointMe(..., 'pc9')", occ) is False
    p = b.eval_py("return { ns.EventLive:MyPoint(...) }", occ)
    assert p[0] == "pc1" and abs(p[1] - want) < 2, p
    w.tick(2)
    assert not [e for e in w.addon_log[a0:] if e["sender"] == K("Bert")], w.addon_log[a0:]
    # in an instance: the place, no yards or way
    w.enter_instance("Mana-Tombs", 557, "party", 5, clients=[b])
    assert b.eval_py("return { ns.EventLive:MyPoint(...) }", occ) == ["pc1"]
    assert b.eval_py("return { ns.EventLive:MyMeet(...) }", occ) == ["pc1"]
    w.leave_instance(clients=[b])
    # there: the way is done
    w.set_position(b, NAGRAND, 0.405, 0.44 + 10 * YDY, subzone="Halaa")
    assert b.eval_py("return { ns.EventLive:MyPoint(...) }", occ) == []
    # stop: nil
    assert b.eval("return ns.EventLive:PointMe(..., 'pc2')", occ) is True
    assert b.eval("return ns.EventLive:PointMe(..., nil)", occ) is True
    assert b.eval_py("return { ns.EventLive:MyPoint(...) }", occ) == []
    # the host moves where to meet on the calendar event; false: the event's own again
    # (a calendar event with its event's copy takes a few parts a second to reach the others)
    assert g.eval("return ns.Events:EditOcc(..., ns.Events:GetOcc(...).at, nil, nil, 'pc2')", occ, occ) is True
    assert g.eval(meet, occ) == "pc2"
    w.run_until(lambda: b.eval(meet, occ) == "pc2", timeout=90, step=1)
    assert g.eval("return ns.Events:EditOcc(..., ns.Events:GetOcc(...).at, nil, nil, false)", occ, occ) is True
    w.run_until(lambda: b.eval(meet, occ) == "pc1", timeout=90, step=1)
    # (nil: as it was)
    assert g.eval("return ns.Events:EditOcc(..., ns.Events:GetOcc(...).at, 'Halaa', nil)", occ, occ) is True
    assert g.eval(meet, occ) == "pc1"
    # a def whose meeting place is gone loses it (CleanDef); taking the place out of the builder's def too
    out = g.eval_py("""local B, Ev = ns.EventBlocks, ns.Events
        local d = B:Example('redlight'); d.id, d.by = 'emeet1', 'Gina-Thunderstrike'
        d.meet = 'pc7'
        local c1 = Ev:CleanDef(d)
        d.meet = 'pc2'
        local c2 = Ev:CleanDef(d)
        B:RemoveDefinition(d, 'places', 'pc2')
        return { c1.meet or false, c2.meet or false, d.meet or false }""")
    assert out == [False, "pc2", False], out
    w.assert_no_errors()


@case
def the_hosts_point_replaces_mine_and_practice_knows_where_to_meet():
    w, by, cs = guild(["Gina", "Bert", "Cora"])
    g, b, co = cs
    for c in cs:
        w.set_position(c, NAGRAND, 0.415, 0.47, subzone="Halaa")
    occ = g.eval("""local d = ns.EventBlocks:Example('redlight')
        d.id, d.by = nil, nil
        assert(ns.Events:SaveDef(d))
        return ns.Events:Schedule(d.id, GetServerTime() + 30)""")
    w.tick(3)
    w.run_until(lambda: all(c.eval("return ns.Events:GetOcc(...) ~= nil", occ) for c in (b, co)), timeout=90, step=0.5)
    for c in (b, co):
        assert c.eval("return (ns.Events:SignUp(..., true))", occ)
    w.tick(3)
    # Bert asks the way to the finish line; the host's run points everyone to the start: that's his arrow now
    assert b.eval("return ns.EventLive:PointMe(..., 'pc2')", occ)
    assert b.eval_py("return { ns.EventLive:MyPoint(...) }", occ)[0] == "pc2"
    assert g.eval_py("return { ns.EventLive:Start(...) }", occ)[0] is True
    w.tick(4)
    assert b.eval_py("return { ns.EventLive:MyPoint(...) }", occ)[0] == "pc1"
    # at the start line the host's arrow goes, and his own doesn't come back
    w.set_position(b, NAGRAND, 0.405, 0.44, subzone="Halaa")
    w.tick(5)
    assert b.eval_py("return { ns.EventLive:MyPoint(...) }", occ) == []
    # practice: where its event meets
    assert g.eval_py("""local run = ns.EventLive:StartPractice(ns.EventBlocks:Example('race'), 3)
        local pid = ns.EventLive:MyMeet('practice')
        ns.EventLive:StopPractice()
        return pid""") == "pc1"
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

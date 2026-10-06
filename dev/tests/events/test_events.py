"""Events (Core/EventBlocks.lua, EventEngine.lua, Events.lua, EventLive.lua): the pieces, the engine, the guild's
library / calendar / results / season and live runs between clients.

Covers: the starter event has no problems and reads in plain words; single elimination seeds and byes; round robin;
a whole live duel cup between five clients from real duel messages (whispers, guild lines, the board on a watcher,
results and season points on everyone); the loser's word counts alone; a winner's alone waits and then asks both;
a dispute goes to the host; the host goes offline and an entrant takes over; review: ranked for one revision only,
an edit takes it back, only reviewers decide; someone else's event can't be edited; practice runs with dummies.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_events.py [-k name]   (from dev)"""
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


def duel(w, cs, winner, loser):
    """Both duelists' clients see the system message."""
    by = {c.name: c for c in cs}
    text = "%s has defeated %s in a duel" % (winner, loser)
    for n in (winner, loser):
        by[n].fire("CHAT_MSG_SYSTEM", text)
    w.tick(1)


def host_state(c, occ):
    return c.eval_py("local st = ns.EventLive:GetState(...); return st and { phase = st.phase, stage = st.stage, "
                     "seq = st.seq, host = st.host, n = #st.entrants } or nil", occ)


def playing(c, occ):
    """The matches being played on the host: [(a, b, id)]."""
    return c.eval_py("""
        local st = ns.EventLive:GetState(...)
        local bk = ns.EventEngine:BracketOf(ns.EventLive:GetDef(...), st)
        local out = {}
        if bk then
          for _, mid in ipairs(bk.rounds[bk.r] or {}) do
            local m = bk.m[mid]
            if m.st == "play" then out[#out + 1] = { (m.a:gsub("%-.*", "")), (m.b:gsub("%-.*", "")), m.id } end
          end
        end
        return out""", occ) or []


def schedule_starter(host, at_offset=60):
    """The host saves the starter event and puts it on the calendar: (defId, occId)."""
    return host.eval_py("""
        local d = ns.Events:NewDef(true)
        assert(ns.Events:SaveDef(d), "save")
        local occ = ns.Events:Schedule(d.id, GetServerTime() + ...)
        return { d.id, occ }""", at_offset)


@case
def starter_has_no_problems_and_reads_in_plain_words():
    w = World()
    c = Client(w, "Gina", guild_rank=0)
    c.load_addon()
    w.tick(2)
    out = c.eval_py("""
        local B = ns.EventBlocks
        local d = B:Starter()
        local words = {}
        for _, s in ipairs(B:Describe(d)) do words[#words + 1] = s.name .. ": " .. s.text end
        return { n = #B:Problems(d), words = words, kinds = B:Kinds(d) }""")
    assert out["n"] == 0, out
    assert out["kinds"] == ["signup", "bracket"], out
    assert any("Single elimination, best of 3" in x for x in out["words"]), out["words"]
    assert any("16 spots" in x for x in out["words"]), out["words"]
    # an emptied blank is a problem
    n = c.eval("""
        local B = ns.EventBlocks
        local d = B:Starter()
        d.scripts[1].top.n.a[1] = nil   -- the whisper's player
        return #B:Problems(d)""")
    assert n == 1, n
    w.assert_no_errors()


@case
def single_elimination_seeds_and_byes():
    w = World()
    c = Client(w, "Gina", guild_rank=0)
    c.load_addon()
    w.tick(2)
    out = c.eval_py("""
        local B, E = ns.EventBlocks, ns.EventEngine
        local d = B:Starter()
        d.blocks.b2.set.seed = "order"
        local names = {}
        for i = 1, 6 do names[i] = "P" .. i .. "-Thunderstrike" end
        local run = E:New(d, { id = "x", host = names[1], signups = names, now = function() return 100 end })
        run:Start()
        local bk = run:MainBracket()
        local r1 = {}
        for _, mid in ipairs(bk.rounds[1]) do
          local m = bk.m[mid]
          r1[#r1 + 1] = { m.a and m.a:sub(1, 2) or "-", m.b and m.b:sub(1, 2) or "-", m.st }
        end
        return { order = E.SeedOrder(8), r1 = r1, last = bk.last, stage = run.st.stage }""")
    assert out["order"] == [1, 8, 4, 5, 2, 7, 3, 6], out
    # 6 players: seeds 1 and 2 have byes
    assert out["r1"][0] == ["P1", "-", "bye"], out
    assert out["r1"][2] == ["P2", "-", "bye"], out
    assert out["last"] == 3 and out["stage"] == "s2", out
    w.assert_no_errors()


@case
def round_robin_everyone_plays_everyone():
    w = World()
    c = Client(w, "Gina", guild_rank=0)
    c.load_addon()
    w.tick(2)
    out = c.eval_py("""
        local B, E = ns.EventBlocks, ns.EventEngine
        local d = B:Starter()
        d.blocks.b2.set.fmt = "robin"
        d.blocks.b2.set.bo = 1
        d.blocks.b2.set.atonce = 8
        local names = {}
        for i = 1, 4 do names[i] = "P" .. i .. "-Thunderstrike" end
        local clock = 100
        local run = E:New(d, { id = "x", host = names[1], signups = names, now = function() return clock end })
        run:Start()
        for guard = 1, 50 do
          if run.st.phase ~= "live" then break end
          local bk = run:MainBracket()
          for _, mid in ipairs(bk.rounds[bk.r] or {}) do
            local m = bk.m[mid]
            if m.st == "play" then
              local w, l = m.a, m.b
              if w > l then w, l = l, w end   -- the lower name wins
              run:Duel(w, l, true)
            end
          end
          clock = clock + 5
          run:Tick()
        end
        local bk = run:MainBracket()
        local pairs_ = 0
        for _ in pairs(bk.m) do pairs_ = pairs_ + 1 end
        return { matches = pairs_, champ = bk.champ, second = bk.second, phase = run.st.phase }""")
    assert out["matches"] == 6, out
    assert out["champ"] == "P1-Thunderstrike" and out["second"] == "P2-Thunderstrike", out
    assert out["phase"] == "done", out
    w.assert_no_errors()


@case
def a_live_duel_cup_between_five_clients():
    names = ["Gina", "Bert", "Cora", "Dain", "Elsa", "Watcher"]
    w, cs = guild(names)
    host = cs[0]
    def_id, occ = schedule_starter(host, 30)
    w.tick(5)
    # everyone has the event and its calendar entry; four more sign up (the watcher doesn't)
    for c in cs[1:]:
        assert c.eval("return ns.Events:GetDef(...) ~= nil", def_id), c.name
        assert c.eval("return ns.Events:GetOcc(...) ~= nil", occ), c.name
    for c in cs[1:5]:
        assert c.eval("return ns.Events:SignUp(...)", occ, True)
    w.tick(5)
    assert host.eval_py("return ns.Events:GetSignups(...)", occ) == [
        "Gina-Thunderstrike", "Bert-Thunderstrike", "Cora-Thunderstrike", "Dain-Thunderstrike", "Elsa-Thunderstrike"]
    ok = host.eval_py("return { ns.EventLive:Start(...) }", occ)
    assert ok[0] is True, ok
    w.tick(5)
    st = host_state(cs[-1], occ)
    assert st and st["phase"] == "live" and st["stage"] == "s2" and st["n"] == 5, st
    # the matches tell their players
    whispers = [e for e in w.chat_log if e["chat_type"] == "WHISPER"]
    assert any("You're up vs" in e["text"] for e in whispers), whispers
    # play it out: the lower name wins every duel
    for guard in range(60):
        st = host_state(host, occ)
        if st["phase"] != "live":
            break
        ms = playing(host, occ)
        if not ms:
            w.tick(5)
            continue
        a, b, _ = ms[0]
        win, lose = (a, b) if a < b else (b, a)
        duel(w, cs, win, lose)
        w.tick(2)
    st = host_state(host, occ)
    assert st["phase"] == "done", st
    w.tick(10)
    guild_lines = [e["text"] for e in w.chat_log if e["chat_type"] == "GUILD"]
    assert any("beats" in t for t in guild_lines), guild_lines
    assert any(t.startswith("GG! Bert wins") for t in guild_lines), guild_lines
    # the result reached everyone (the watcher too); it was not ranked: no points, no badges
    for c in cs:
        r = c.eval_py("local r = ns.Events:GetResult(...); return r and { r.champ, r.second, r.n, r.ranked or false } or nil", occ)
        # seeds Gina 1, Bert 2, Cora 3, Dain 4, Elsa 5: Bert beats Cora in a semi, Dain beats Gina; Bert wins the final
        assert r == ["Bert-Thunderstrike", "Dain-Thunderstrike", 5, False], (c.name, r)
    assert host.eval("return #ns.Events:Standings()") == 0
    w.assert_no_errors()


@case
def ranked_events_give_season_points_and_badges():
    names = ["Gina", "Bert", "Cora", "Dain"]
    w, cs = guild(names)
    host = cs[0]
    def_id = host.eval("local d = ns.Events:NewDef(true); d.blocks.b2.set.bo = 1; d.blocks.b2.set.fbo = 1; "
                       "ns.Events:SaveDef(d); return d.id")
    w.tick(3)
    # Gina sends it in for review; she is the GM, so she may rank it too
    assert host.eval("return ns.Events:SubmitForReview(..., 'please')", def_id)
    w.tick(3)
    assert cs[1].eval("return ns.Events:ReviewState(ns.Events:GetDef(...))", def_id) == "review"
    # a member can't rank it (their K record is refused everywhere)
    cs[1].eval("ns.Events:Review(..., true)", def_id)
    w.tick(3)
    assert host.eval("return ns.Events:ReviewState(ns.Events:GetDef(...))", def_id) == "review"
    assert host.eval("return ns.Events:Review(..., true)", def_id)
    w.tick(3)
    for c in cs:
        assert c.eval("return ns.Events:ReviewState(ns.Events:GetDef(...))", def_id) == "ranked", c.name
    occ = host.eval("return ns.Events:Schedule(..., GetServerTime() + 10)", def_id)
    w.tick(3)
    for c in cs[1:]:
        c.eval("ns.Events:SignUp(..., true)", occ)
    w.tick(3)
    host.eval("ns.EventLive:Start(...)", occ)
    w.tick(3)
    for guard in range(40):
        if host_state(host, occ)["phase"] != "live":
            break
        ms = playing(host, occ)
        if not ms:
            w.tick(5)
            continue
        a, b, _ = ms[0]
        win, lose = (a, b) if a < b else (b, a)
        duel(w, cs, win, lose)
    w.tick(10)
    rows = cs[3].eval_py("local out = {}; for _, r in ipairs(ns.Events:Standings()) do "
                         "out[#out + 1] = { (r.key:gsub('%-.*', '')), r.pts, #r.badges, r.wins } end; return out")
    # Bert wins (50 + 5 a match won x2 + 5 for playing), Dain second (30 + 5 + 5), Cora third (20 + 5 bronze + 5)
    assert rows[0][0] == "Bert" and rows[0][1] == 65 and rows[0][2] == 1 and rows[0][3] == 2, rows
    assert rows[1][0] == "Dain" and rows[1][1] == 40, rows
    assert rows[2][0] == "Cora" and rows[2][1] == 30, rows
    assert cs[3].eval("return ns.Events:GetTitle('Bert-Thunderstrike')") == "the Duelist"
    # an edit makes a new revision: not ranked any more
    host.eval("local d = ns.EventBlocks.Copy(ns.Events:GetDef(...)); d.name = 'Friday duel cup II'; ns.Events:SaveDef(d)", def_id)
    w.tick(3)
    assert cs[2].eval("return ns.Events:ReviewState(ns.Events:GetDef(...))", def_id) == "changed"
    w.assert_no_errors()


@case
def the_losers_word_counts_alone_and_a_winners_waits():
    names = ["Gina", "Bert", "Cora", "Dain"]
    w, cs = guild(names)
    host = cs[0]
    _, occ = schedule_starter(host, 10)
    w.tick(3)
    for c in cs[1:]:
        c.eval("ns.Events:SignUp(..., true)", occ)
    w.tick(3)
    host.eval("ns.EventLive:Start(...)", occ)
    w.tick(3)
    ms = playing(host, occ)
    a, b, mid = ms[0]
    by = {c.name: c for c in cs}
    # only the loser's client sees it: counts at once
    by[b].fire("CHAT_MSG_SYSTEM", "%s has defeated %s in a duel" % (a, b))
    w.tick(2)
    wins = host.eval_py("""
        local st = ns.EventLive:GetState(...)
        local bk = ns.EventEngine:BracketOf(ns.EventLive:GetDef(...), st)
        local m = bk.m[select(2, ...)]
        return { m.wa, m.wb }""", occ, mid)
    assert wins == [1, 0], wins
    # only the winner's client (the next game, a while later): nothing for 10 s, then both players are asked who won
    w.tick(20)
    by[a].fire("CHAT_MSG_SYSTEM", "%s has defeated %s in a duel" % (a, b))
    w.tick(4)
    assert host.eval("local st = ns.EventLive:GetState(...); return next(st.asks) == nil", occ)
    w.tick(10)
    ask = by[a].eval_py("local a = ns.EventLive:MyAsk(...); return a and { a.id, a.q } or nil", occ)
    assert ask and ask[1] == "Who won game 2?", ask
    # they agree: the game counts (and the match, best of 3: 2-0)
    for n in (a, b):
        by[n].eval("ns.EventLive:AnswerAsk(...)", occ, ask[0], "%s-Thunderstrike" % a)
    w.tick(3)
    st = host.eval_py("""
        local st = ns.EventLive:GetState(...)
        local bk = ns.EventEngine:BracketOf(ns.EventLive:GetDef(...), st)
        local m = bk.m[select(2, ...)]
        return { m.wa, m.wb, m.st }""", occ, mid)
    assert st == [2, 0, "done"], st
    w.assert_no_errors()


@case
def a_dispute_goes_to_the_host():
    names = ["Gina", "Bert", "Cora", "Dain"]
    w, cs = guild(names)
    host = cs[0]
    _, occ = schedule_starter(host, 10)
    w.tick(3)
    for c in cs[1:]:
        c.eval("ns.Events:SignUp(..., true)", occ)
    w.tick(3)
    host.eval("ns.EventLive:Start(...)", occ)
    w.tick(3)
    a, b, mid = [m for m in playing(host, occ) if "Gina" not in m[:2]][0]
    by = {c.name: c for c in cs}
    by[a].fire("CHAT_MSG_SYSTEM", "%s has defeated %s in a duel" % (a, b))
    w.tick(12)
    ask = by[a].eval_py("local a = ns.EventLive:MyAsk(...); return a and a.id", occ)
    by[a].eval("ns.EventLive:AnswerAsk(...)", occ, ask, "%s-Thunderstrike" % a)
    by[b].eval("ns.EventLive:AnswerAsk(...)", occ, ask, "%s-Thunderstrike" % b)
    w.tick(3)
    hask = host.eval_py("local a = ns.EventLive:MyAsk(...); return a and { a.id, a.claims ~= nil } or nil", occ)
    assert hask and hask[1] is True, hask
    host.eval("ns.EventLive:HostAnswer(...)", occ, hask[0], "%s-Thunderstrike" % b)
    w.tick(3)
    wins = host.eval_py("""
        local st = ns.EventLive:GetState(...)
        local bk = ns.EventEngine:BracketOf(ns.EventLive:GetDef(...), st)
        local m = bk.m[select(2, ...)]
        return { m.a:gsub('%-.*', ''), m.wa, m.wb }""", occ, mid)
    assert (wins[1], wins[2]) == ((0, 1) if wins[0] == a else (1, 0)), wins
    w.assert_no_errors()


@case
def an_entrant_takes_over_when_the_host_is_gone():
    names = ["Gina", "Bert", "Cora", "Dain", "Elsa"]
    w, cs = guild(names)
    host = cs[0]
    _, occ = schedule_starter(host, 10)
    w.tick(3)
    for c in cs[1:]:
        c.eval("ns.Events:SignUp(..., true)", occ)
    w.tick(3)
    host.eval("ns.EventLive:Start(...)", occ)
    w.tick(3)
    seq = host_state(cs[1], occ)["seq"]
    host.logout()
    w.tick(80)
    # Bert (first in name order among those online) hosts it now, and everyone knows
    assert cs[1].eval("return ns.EventLive:IsHostOf(...)", occ)
    for c in cs[2:]:
        st = host_state(c, occ)
        assert st["host"] == "Bert-Thunderstrike" and st["seq"] > seq, (c.name, st)
    # it goes on: a duel between two others counts on Bert's run
    ms = [m for m in playing(cs[1], occ) if "Gina" not in m[:2] and "Bert" not in m[:2]]
    if ms:
        a, b, mid = ms[0]
        duel(w, cs[1:], a, b)
        w.tick(2)
        wins = cs[1].eval_py("""
            local st = ns.EventLive:GetState(...)
            local bk = ns.EventEngine:BracketOf(ns.EventLive:GetDef(...), st)
            local m = bk.m[select(2, ...)]
            return m.wa + m.wb""", occ, mid)
        assert wins == 1, wins
    w.assert_no_errors()


@case
def someone_elses_event_cant_be_edited_and_moderators_delete():
    names = ["Gina", "Bert", "Cora"]
    w, cs = guild(names)
    bert = cs[1]
    def_id = bert.eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); return d.id")
    w.tick(3)
    # Cora's save of Bert's event is refused (she copies it instead)
    assert cs[2].eval("local d = ns.EventBlocks.Copy(ns.Events:GetDef(...)); d.name = 'mine'; return ns.Events:SaveDef(d)",
                      def_id) is False
    cid = cs[2].eval("local d = ns.Events:CopyDef(...); ns.Events:SaveDef(d); return d.id", def_id)
    w.tick(3)
    assert cs[0].eval("return ns.Events:GetDef(...).by", cid) == "Cora-Thunderstrike"
    assert cs[0].eval("return ns.Events:GetDef(...).from", cid) == def_id
    # the GM deletes Bert's
    assert cs[0].eval("return ns.Events:DeleteDef(...)", def_id)
    w.tick(3)
    assert bert.eval("return ns.Events:GetDef(...) == nil", def_id)
    w.assert_no_errors()


@case
def a_late_member_gets_the_library_from_the_guild():
    names = ["Gina", "Bert"]
    w, cs = guild(names)
    def_id = cs[0].eval("local d = ns.Events:NewDef(true); ns.Events:SaveDef(d); return d.id")
    w.tick(3)
    late = Client(w, "Late", guild_rank=3)
    late.load_addon()
    w.tick(HELLO + 20)
    assert late.eval("return ns.Events:GetDef(...) ~= nil", def_id)
    w.assert_no_errors()


@case
def practice_runs_with_dummies_and_sends_nothing():
    w = World()
    c = Client(w, "Gina", guild_rank=0)
    c.load_addon()
    w.tick(3)
    before = len(w.chat_log)
    out = c.eval_py("""
        local L = ns.EventLive
        local d = ns.EventBlocks:Starter()
        d.blocks.b2.set.bo = 1
        d.blocks.b2.set.fbo = 1
        local run = L:StartPractice(d, 8)
        for guard = 1, 40 do
          if run.st.phase ~= "live" then break end
          local bk = run:MainBracket()
          for _, mid in ipairs(bk and bk.rounds[bk.r] or {}) do
            local m = bk.m[mid]
            if m.st == "play" then L:PracticeDuel(m.a, m.b) end
          end
          L:PracticeSkip()
        end
        local bk = run:MainBracket()
        return { phase = run.st.phase, champ = bk.champ, name = L.DisplayName(bk.champ) }""")
    assert out["phase"] == "done" and out["name"] == "Dummy 1", out
    assert len(w.chat_log) == before
    w.assert_no_errors()


@case
def duel_messages_parse_both_ways():
    w = World()
    c = Client(w, "Gina", guild_rank=0)
    c.load_addon()
    w.tick(2)
    out = c.eval_py("""
        local L = ns.EventLive
        local a, b = L:ParseDuel("Bert has defeated Gina in a duel")
        local c, d = L:ParseDuel("Gina has fled from Bert in a duel")
        local pat, order = L._Pattern("%2$s has fled from %1$s in a duel")
        return { a, b, c, d, pat, order }""")
    assert out[:4] == ["Bert-Thunderstrike", "Gina-Thunderstrike", "Bert-Thunderstrike", "Gina-Thunderstrike"], out
    assert out[5] == [2, 1], out
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

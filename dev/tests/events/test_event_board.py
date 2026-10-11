"""The live board, the host's controls and what an event puts on a player's screen (UI/EventBoard.lua,
UI/EventTracker.lua; mockup shots 7-10).

Covers: the board on a watcher and on the host (the host bar), its cards show the bracket's players and scores; a
dispute card on the host whose buttons decide the game; the tracker under the minimap for an entrant, gone when the
event ends; the match card when my match starts, Ready marks me ready on the host (then the wait for the opponent);
the "who won" prompt answers; a game counted shows the toast; the host's More menu (change a result, end the event);
raid warnings and countdowns; demo mode, the practice run, round robin and a 32-player bracket render without
errors and inside the board.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_event_board.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all, menu_pick, menu_labels, strip_codes  # noqa: E402

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


def K(n):
    return n + "-Thunderstrike"


def duel(w, by, winner, loser, only=None):
    """The duelists' clients see the system message (only: just that one's)."""
    text = "%s has defeated %s in a duel" % (winner, loser)
    for n in ([only] if only else (winner, loser)):
        by[n].fire("CHAT_MSG_SYSTEM", text)
    w.tick(1)


def start_cup(names=("Gina", "Bert", "Cora", "Dain", "Wade"), players=("Bert", "Cora", "Dain"), tick=HELLO):
    """Gina hosts the starter cup (she is signed up as its host); `players` sign up; Wade only watches."""
    w, cs = guild(list(names), tick)
    by = {c.name: c for c in cs}
    host = by["Gina"]
    occ = host.eval_py("""
        local d = ns.Events:NewDef(true)
        assert(ns.Events:SaveDef(d), "save")
        return ns.Events:Schedule(d.id, GetServerTime() + 30)""")
    w.tick(5)
    for n in players:
        assert by[n].eval("return ns.Events:SignUp(...)", occ, True)
    w.tick(5)
    ok = host.eval_py("return { ns.EventLive:Start(...) }", occ)
    assert ok[0] is True, ok
    w.tick(5)
    return w, cs, by, host, occ


def playing(c, occ):
    return c.eval_py("""
        local st = ns.EventLive:GetState(...)
        local bk = ns.EventEngine:BracketOf(ns.EventLive:GetDef(...), st)
        local out = {}
        for _, mid in ipairs(bk and bk.rounds[bk.r] or {}) do
          local m = bk.m[mid]
          if m.st == "play" then out[#out + 1] = { (m.a:gsub("%-.*", "")), (m.b:gsub("%-.*", "")), m.id } end
        end
        return out""", occ) or []


def match(c, occ, mid):
    return c.eval_py("""
        local st = ns.EventLive:GetState(...)
        local bk = ns.EventEngine:BracketOf(ns.EventLive:GetDef(...), st)
        local m = bk.m[select(2, ...)]
        return { a = (m.a or '-'):gsub('%-.*', ''), b = (m.b or '-'):gsub('%-.*', ''), wa = m.wa, wb = m.wb, st = m.st }""",
                     occ, mid)


BOARD = """
    local f = ns.EventBoard:GetWindow()
    local o = { shown = f and f:IsShown() or false, cards = {}, host = f and f.hostbar:IsShown() or false }
    if not o.shown then return o end
    for _, cd in ipairs(f.br.cards) do
      if cd:IsShown() then
        local r1, r2 = cd.rows[1], cd.rows[2]
        o.cards[#o.cards + 1] = { r1.name:GetText() or '', r1.score:GetText() or '', r2.name:GetText() or '',
                                  r2.score:GetText() or '', cd.m and cd.m.st or '' }
      end
    end
    o.title = f.hdr.title:GetText()
    o.pill = f.hdr.pill.fs:GetText()
    o.chip = f.hdr.chip:IsShown() and f.hdr.chip.fs:GetText() or false
    o.now = 0
    for _, n in ipairs(f.rail.nows) do if n:IsShown() then o.now = o.now + 1 end end
    o.dispute = f.dispute:IsShown()
    o.hostsub = f.hostbar.sub:GetText()
    -- every shown card inside the bracket area (the layout never spills)
    local bw, bh = f.br:GetWidth(), f.br:GetHeight()
    o.spill = {}
    for _, cd in ipairs(f.br.cards) do
      if cd:IsShown() then
        local _, _, _, x, y = cd:GetPoint(1)
        if x < 0 or -y < 0 or x + cd:GetWidth() > bw + 0.5 or -y + cd:GetHeight() > bh + 0.5 then
          o.spill[#o.spill + 1] = { x, y, cd:GetWidth(), cd:GetHeight() }
        end
      end
    end
    return o"""


def board(c):
    return c.eval_py(BOARD)


TRACKER = """
    local fr = ns.EventTracker:GetFrames()
    local t = fr.tracker
    local o = { shown = t and t:IsShown() or false }
    if o.shown then
      o.name = t.name:GetText()
      o.l1, o.l2, o.l3 = t.l1:GetText(), t.l2:GetText(), t.l3:GetText()
      o.ready = t.ready:IsShown()
      o.pips = t.pips:IsShown() and t.pipText:GetText() or false
    end
    o.card = fr.card and fr.card:IsShown() or false
    o.cardText = fr.card and fr.card.text:GetText() or nil
    o.ask = fr.ask and fr.ask:IsShown() or false
    o.wait = fr.wait and fr.wait:IsShown() or false
    o.toast = fr.toast and fr.toast:IsShown() and fr.toast.t:GetText() or false
    o.toastLine = fr.toast and fr.toast:IsShown() and fr.toast.l:GetText() or false
    return o"""


def tracker(c):
    return c.eval_py(TRACKER)


def plain(s):
    return strip_codes(s) if isinstance(s, str) else s


@case
def the_board_on_a_watcher_and_on_the_host():
    w, cs, by, host, occ = start_cup()
    wade = by["Wade"]
    wade.eval("ns.EventBoard:Open(...)", occ)
    w.tick(3)
    b = board(wade)
    assert b["shown"] and b["title"] == "Friday duel cup" and b["pill"] == "Live", b
    assert not b["host"], "a watcher has no host bar"
    names = {plain(x) for card in b["cards"] for x in (card[0], card[2])}
    # four players, two semifinals and the final (+ the 3rd place match)
    for n in ("Gina", "Bert", "Cora", "Dain"):
        assert n in names, (n, names)
    assert b["now"] == 2, b
    assert not b["spill"], b["spill"]
    # the watcher counts as watching on the host
    w.tick(35)
    assert host.eval("return ns.EventLive:GetState(...).watch", occ) >= 1
    # a duel: its score on both boards
    host.eval("ns.EventBoard:Open(...)", occ)
    ms = playing(host, occ)
    a, bb, mid = [m for m in ms if "Gina" not in m[:2]][0]
    duel(w, by, a, bb)
    w.tick(3)
    hb = board(host)
    assert hb["host"] and "2 matches playing" in plain(hb["hostsub"]), hb
    row = [cd for cd in hb["cards"] if plain(cd[0]) in (a, bb) and cd[4] == "play"][0]
    scores = {plain(row[0]): row[1], plain(row[2]): row[3]}
    assert scores[a] == "1" and scores[bb] == "0", (scores, row)
    wb = board(wade)
    row = [cd for cd in wb["cards"] if plain(cd[0]) in (a, bb) and cd[4] == "play"][0]
    assert {plain(row[0]): row[1], plain(row[2]): row[3]}[a] == "1", row
    # the host's own match card: "You" on the host's board
    assert any(plain(cd[0]) == "You" or plain(cd[2]) == "You" for cd in hb["cards"]), hb["cards"]
    # closing the board stops watching
    wade.eval("ns.EventBoard:Close()")
    assert wade.eval("return ns.EventLive.watching == nil")
    w.assert_no_errors()


@case
def a_dispute_on_the_host_is_settled_from_the_board():
    w, cs, by, host, occ = start_cup()
    host.eval("ns.EventBoard:Open(...)", occ)
    a, b, mid = [m for m in playing(host, occ) if "Gina" not in m[:2]][0]
    # only the winner's client sees it: both are asked, they disagree, it goes to the host
    duel(w, by, a, b, only=a)
    w.tick(12)
    ask = by[a].eval_py("local a = ns.EventLive:MyAsk(...); return a and a.id", occ)
    assert ask, "the players are asked"
    by[a].eval("ns.EventLive:AnswerAsk(...)", occ, ask, K(a))
    by[b].eval("ns.EventLive:AnswerAsk(...)", occ, ask, K(b))
    w.tick(3)
    hb = board(host)
    assert hb["dispute"], hb
    assert "1 dispute" in plain(hb["hostsub"]), hb["hostsub"]
    d = host.eval_py("""
        local d = ns.EventBoard:GetWindow().dispute
        local o = { h1 = d.h1:GetText(), p = d.p:GetText(), says = {}, btns = {} }
        for i = 1, 2 do o.says[i] = d.cl[i].name:GetText() .. ' ' .. d.cl[i].says:GetText() end
        for i = 1, 3 do o.btns[i] = d.btns[i]:GetText() end
        return o""")
    assert d["h1"] == "Game 1 is disputed", d
    assert all("claims the win" in s for s in d["says"]), d["says"]
    assert [plain(x) for x in d["btns"]][2] == "Replay", d["btns"]
    # the tracker tells the host too
    t = tracker(host)
    assert t["shown"], t
    # "<b> won" decides the game for b
    host.eval("""
        local d = ns.EventBoard:GetWindow().dispute
        for i = 1, 2 do if d.btns[i].answer == select(1, ...) then d.btns[i]:Click() end end""", K(b))
    w.tick(3)
    m = match(host, occ, mid)
    assert (m["wa"], m["wb"]) == ((0, 1) if m["a"] == a else (1, 0)), m
    assert not board(host)["dispute"]
    w.assert_no_errors()


@case
def the_tracker_shows_for_an_entrant_and_goes_when_the_event_ends():
    w, cs, by, host, occ = start_cup()
    w.tick(2)
    bert = by["Bert"]
    t = tracker(bert)
    assert t["shown"], t
    assert t["name"] == "Friday duel cup", t
    assert "you vs" in plain(t["l1"]), t
    assert plain(t["pips"]).endswith("first to 2"), t
    # the watcher has none
    assert not tracker(by["Wade"])["shown"]
    # the host ends it (More > End the event, confirmed): everyone's tracker goes
    host.eval("ns.EventBoard:Open(...)", occ)
    host.eval("local hb = ns.EventBoard:GetWindow().hostbar; hb.more:Click()")
    labels = menu_labels(host)
    for lab in ("Change a result", "Add a player", "Remove a player", "Go to a stage", "Hand over hosting", "End the event"):
        assert lab in labels, (lab, labels)
    menu_pick(host, "End the event")
    assert host.eval("return ns.EventBoard:GetWindow().confirm:IsShown()")
    host.eval("ns.EventBoard:GetWindow().confirm.ok:Click()")   # (the confirm is a UI:CreateSheet: its OK)
    w.tick(5)
    assert host.eval("return ns.EventLive:GetState(...).phase", occ) == "done"
    for n in ("Bert", "Cora", "Gina"):
        assert not tracker(by[n])["shown"], n
    assert board(host)["pill"] == "Ended"
    w.assert_no_errors()


@case
def the_match_card_comes_up_and_ready_reaches_the_host():
    w, cs, by, host, occ = start_cup()
    w.tick(2)
    a, b, mid = [m for m in playing(host, occ) if "Gina" not in m[:2]][0]
    pa = by[a]
    t = tracker(pa)
    assert t["card"], t
    assert "Best of 3. Find %s" % b in plain(t["cardText"]), t["cardText"]
    assert t["ready"], "the tracker has Ready too"
    # Ready on the card: the host has me ready; the card goes, the wait for the opponent comes
    pa.eval("ns.EventTracker:GetFrames().card.go:Click()")
    w.tick(4)
    assert host.eval("return ns.EventLive:GetState(...).ready[select(2, ...)] == true", occ, K(a))
    t = tracker(pa)
    assert not t["card"] and t["wait"] and not t["ready"], t
    # the opponent says "Need a minute": the card goes, it doesn't come back with the next change
    pb = by[b]
    assert tracker(pb)["card"]
    pb.eval("ns.EventTracker:GetFrames().card.later:Click()")
    pb.eval("ns.EventTracker:Refresh()")
    assert not tracker(pb)["card"]
    # a duel: both are ready (the wait goes), the game counts: the toast
    duel(w, by, a, b)
    w.tick(3)
    t = tracker(pa)
    assert not t["wait"], t
    assert plain(t["toast"]) == "Game 1 · you won", t
    assert plain(t["toastLine"]) == "1-0 · one more win takes the match", t
    tb = tracker(pb)
    assert plain(tb["toast"]) == "Game 1 · you lost", tb
    w.assert_no_errors()


@case
def the_who_won_prompt_answers():
    w, cs, by, host, occ = start_cup()
    a, b, mid = [m for m in playing(host, occ) if "Gina" not in m[:2]][0]
    duel(w, by, a, b, only=a)
    w.tick(12)
    for n in (a, b):
        t = tracker(by[n])
        assert t["ask"], (n, t)
    q = by[a].eval_py("local f = ns.EventTracker:GetFrames().ask; return { f.t:GetText(), f.b[1]:GetText(), f.b[2]:GetText() }")
    assert q[0] == "Who won game 1?" and plain(q[1]) == "I won" and plain(q[2]) == b + " won", q
    # both say a won: the game counts for a (the toast says they agreed)
    by[a].eval("ns.EventTracker:GetFrames().ask.b[1]:Click()")
    by[b].eval("ns.EventTracker:GetFrames().ask.b[2]:Click()")
    w.tick(4)
    m = match(host, occ, mid)
    assert (m["wa"] if m["a"] == a else m["wb"]) == 1, m
    t = tracker(by[a])
    assert not t["ask"], t
    assert plain(t["toast"]) == "Game 1 · you won", t
    w.assert_no_errors()


@case
def the_hosts_more_menu_changes_a_result():
    w, cs, by, host, occ = start_cup()
    host.eval("ns.EventBoard:Open(...)", occ)
    a, b, mid = [m for m in playing(host, occ) if "Gina" not in m[:2]][0]
    host.eval("ns.EventBoard:GetWindow().hostbar.more:Click()")
    menu_pick(host, "%s won" % b)
    w.tick(3)
    m = match(host, occ, mid)
    assert m["st"] == "done", m
    # the next round's card has the winner
    names = [plain(x) for cd in board(host)["cards"] for x in (cd[0], cd[2])]
    assert names.count(b) >= 2, names
    # pause from the bar
    host.eval("ns.EventBoard:GetWindow().hostbar.pause:Click()")
    assert host.eval("return ns.EventLive:IsPaused(...)", occ)
    assert board(host)["pill"] == "Paused"
    host.eval("ns.EventBoard:GetWindow().hostbar.pause:Click()")
    assert not host.eval("return ns.EventLive:IsPaused(...)", occ)
    w.assert_no_errors()


@case
def raid_warnings_and_countdowns_on_screen():
    w, cs, by, host, occ = start_cup()
    bert = by["Bert"]
    bert.eval("ns:Fire('EVENT_ANNOUNCE', ..., 'Final: Bert vs Cora')", occ)
    bert.eval("ns:Fire('EVENT_COUNTDOWN', ..., 5)", occ)
    out = bert.eval_py("""
        local fr = ns.EventTracker:GetFrames()
        return { cd = fr.countdown and fr.countdown:IsShown() or false, notices = __MOCK.raid_notices }""")
    assert out["cd"], out
    assert "Final: Bert vs Cora" in list(out["notices"] or []), out
    w.tick(3)
    assert bert.eval("return ns.EventTracker:GetFrames().countdown.t:GetText()") in ("3", "2")
    w.tick(5)
    assert not bert.eval("return ns.EventTracker:GetFrames().countdown:IsShown()")
    w.assert_no_errors()


@case
def demo_mode_and_the_practice_run_render():
    w = World()
    c = Client(w, "Gina", guild_rank=0)
    c.load_addon()
    w.tick(2)
    c.slash("/dz demo on")
    w.tick(1)
    c.eval("ns.EventBoard:Open('odemo1')")
    w.tick(1)
    b = board(c)
    assert b["shown"] and len(b["cards"]) == 16 and b["now"] == 2, b
    assert b["chip"] == "You're up next" and not b["host"], b
    assert not b["spill"], b["spill"]
    # the tracker in demo mode: my quarterfinal, up next
    c.eval("ns.EventTracker:Refresh()")
    t = tracker(c)
    assert t["shown"] and plain(t["l1"]).startswith("Quarterfinal: you vs"), t
    assert plain(t["l2"]).startswith("Up after"), t
    c.eval("ns.EventBoard:Close()")
    c.slash("/dz demo off")
    w.tick(1)
    # a practice run with 8 dummies on the board: a dispute to me (the host) is answered on the board
    c.eval("""
        local d = ns.EventBlocks:Starter()
        ns.EventLive:StartPractice(d, 8)
        ns.EventBoard:Open('practice')""")
    w.tick(1)
    b = board(c)
    assert b["shown"] and b["pill"] == "Practice" and len(b["cards"]) >= 7, b
    assert not b["host"], b
    out = c.eval_py("""
        local run = ns.EventLive:GetPractice()
        local bk = run:MainBracket()
        local m
        for _, mid in ipairs(bk.rounds[bk.r]) do if bk.m[mid].st == 'play' then m = bk.m[mid] break end end
        ns.EventLive:PracticeDuel(m.a, m.b, false)
        return { m.id, m.a, m.b }""")
    for _ in range(30):
        w.tick(1)
        if c.eval("return ns.EventBoard:GetWindow().dispute:IsShown()"):
            break
    if c.eval("return ns.EventBoard:GetWindow().dispute:IsShown()"):
        c.eval("ns.EventBoard:GetWindow().dispute.btns[1]:Click()")
        w.tick(2)
    c.eval("ns.EventLive:StopPractice(); ns.EventBoard:Close()")
    w.assert_no_errors()


@case
def round_robin_and_a_32_player_bracket_fit_the_board():
    w = World()
    c = Client(w, "Gina", guild_rank=0)
    c.load_addon()
    w.tick(2)
    for fmt, count in (("robin", 6), ("single", 32), ("single", 3), ("single", 2), ("single", 12)):
        c.eval("""
            local fmt, n = ...
            local d = ns.EventBlocks:Starter()
            d.blocks.b2.set.fmt = fmt
            d.blocks.b2.set.atonce = 8
            d.blocks.b1.set.spots = 32
            ns.EventLive:StartPractice(d, n)
            ns.EventBoard:Open('practice')
            ns.EventBoard:Refresh()""", fmt, count)
        b = board(c)
        assert b["shown"], (fmt, count, b)
        assert not b["spill"], (fmt, count, b["spill"])
        if fmt == "robin":
            rows = c.eval("local n = 0; for _, r in ipairs(ns.EventBoard:GetWindow().br.rows) do "
                          "if r:IsShown() then n = n + 1 end end; return n")
            assert rows == 6, rows
        elif count == 32:
            assert len(b["cards"]) == 32, len(b["cards"])
        c.eval("ns.EventLive:StopPractice()")
    c.eval("ns.EventBoard:Close()")
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

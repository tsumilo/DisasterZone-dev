"""Azeromon multiplayer edge cases (regressions for the 2026-10-10 review of PvP / Trade / Watch / Net).

Covers: a trade can't duplicate a beast across a /reload or a disconnect (the other side reloads before the commit,
the host reloads after sending it, the ack is lost, a commit while the other side is busy waits until it's free,
a commit sent to the host is ignored); a late yes to a challenge or a trade starts nothing (the asker says it
stopped waiting, a stray yes is turned away, an unanswered prompt expires); a slow turn can't give both players
the win (my own clock runs even after the opponent acted; a timeout is told to the slow side); leaving a match
(a /reload or closing the game) is a loss the opponent hears at once; different game data refuses the battle and
a broken team on the challenger's side calls it off for both; spectators survive a long turn without world presence,
ghosts free their slot, and a lost relay names the player; presence waits for a busy queue and the turn action
goes out before spectator relays; the shared random numbers no longer collapse into one short cycle.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_fix_net.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, no_errors, World, Client  # noqa: E402
from _azero_bot import BOT  # noqa: E402

# An unattended player (as in test_azeromon_pvp, plus spectators): reads text, answers Yes / No with T_PVP.answer,
# plays battles with the best move unless idle, records every result. Trades wait for the test.
PLAYER_BOT = r"""
local G, D, M = ns.Azero, ns.AzeroData, ns.AzeroMon
T_PVP = { answer = 1, results = {}, sent = {} }
function T_PVP.tick()
  local p = G.pending
  if not p then return end
  if p.kind == "text" then T_AZ.log[#T_AZ.log + 1] = p.text G:Advance()
  elseif p.kind == "choice" then if T_PVP.answer then G:Advance(T_PVP.answer) end
  elseif p.kind == "battle" then
    local b = p.battle
    local e = b:Pop()
    while e do
      if e.t == "text" then T_AZ.log[#T_AZ.log + 1] = e.text end
      e = b:Pop()
    end
    if b.need == "action" and not T_PVP.idle then
      if not b:Act({ kind = "move", idx = T_AZ.bestMove(b) }) then b:Act({ kind = "move", idx = 1 }) end
    elseif b.need == "done" then
      T_PVP.results[#T_PVP.results + 1] = b.result
      G:Advance(b.result)
    end
  elseif p.kind == "wait" or p.kind == "evolve" then G:Update(0.5) end
end
-- every message I send (t, op, turn / n) in order; T_PVP.drop[type or type.op] = n drops the next n of them
T_PVP.drop = {}
local send = ns.Comm.Send
ns.Comm.Send = function(self, msg, ...)
  if type(msg) == "table" then
    local key = msg.op and (msg.t .. "." .. msg.op) or msg.t
    T_PVP.sent[#T_PVP.sent + 1] = { t = msg.t, op = msg.op, turn = msg.turn, n = msg.n }
    local d = T_PVP.drop[key] or T_PVP.drop[msg.t]
    if d and d > 0 then
      if T_PVP.drop[key] then T_PVP.drop[key] = d - 1 else T_PVP.drop[msg.t] = d - 1 end
      return true
    end
  end
  return send(self, msg, ...)
end
function T_PVP.party()
  local out = {}
  for i, m in ipairs(ns.Azero.save.party) do out[i] = m.sp end
  return out
end
"""

POSITIONS = {"Alice": (8, 9, "right"), "Bob": (9, 9, "left"), "Carol": (8, 10, "up")}


def open_game(c, w, new=True):
    c.eval(BOT)
    c.eval(PLAYER_BOT)
    c.slash("/dz play azeromon")
    w.tick(0.3)
    for _ in range(40):                             # through the title (and the intro of a new game), no further
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.3)
        if c.eval("return ns.Azero.started") and not c.eval("return ns.Azero.pending ~= nil or ns.Azero.co ~= nil"):
            break
    c.eval("ns.AzeroUI._Detach()")
    if new:
        x, y, face = POSITIONS[c.name]
        c.eval("ns.Azero:EnterMap('town', %d, %d, %r, true)" % (x, y, face))


def setup(names=("Alice", "Bob"), teams=None):
    teams = teams or {"Alice": ("murkling", 12), "Bob": ("emberwhelp", 12), "Carol": ("lashling", 12)}
    w = World()
    cs = [Client(w, n, guild_rank=3) for n in names]
    for c in cs:
        c.load_addon()
    w.tick(3)
    for c in cs:
        open_game(c, w)
        sp, lvl = teams[c.name]
        c.eval("local G, M = ns.Azero, ns.AzeroMon; G.save.party = { M.New(%r, %d, G.rng) }; G.save.party[1].hp = 3"
               % (sp, lvl))
    run(w, cs, seconds=2)
    return (w,) + tuple(cs)


def run(w, clients, seconds=1, step=0.3, bots=None):
    for _ in range(max(1, int(round(seconds / step)))):
        for c in clients:
            if c.runtime is None:
                continue
            if bots is None or c in bots:
                c.eval("T_PVP.tick()")
            c.eval("ns.AzeroNet:Update(0.3); ns.AzeroPvP:Update(); ns.AzeroWatch:Update(); ns.AzeroTrade:Update()")
        w.tick(step)


def log(c):
    return "\n".join(c.eval_py("return T_AZ.log") or [])


def printed(c):
    return "\n".join(str(x) for x in (c.eval_py("return _G.T_PRINTED") or []))


def watch_prints(c):
    c.eval("""T_PRINTED = {}
      local p = ns.Print
      ns.Print = function(self, fmt, ...) T_PRINTED[#T_PRINTED + 1] = string.format(fmt, ...) return p(self, fmt, ...) end""")


def records(c):
    return c.eval_py("return ns.Games:GetData('azeromon').pvp") or {}


def sent(c, t=None):
    out = c.eval_py("return T_PVP.sent") or []
    return [m for m in out if t is None or m.get("t") == t]


def everyone(*cs):
    """Every beast on both sides (party + stable), as species names."""
    out = []
    for c in cs:
        out += c.eval_py("""local o = {} local s = ns.Games:GetData('azeromon').save
          for _, m in ipairs(s.party) do o[#o + 1] = m.sp end
          for _, m in ipairs(s.box) do o[#o + 1] = m.sp end return o""") or []
    return sorted(out)


# --- trades ---------------------------------------------------------------------------------------------------------

def open_trade(w, a, b):
    a.eval("ns.Azero:PressA()")
    a.eval("ns.Azero:Advance(2)")                  # Trade
    run(w, (a, b), seconds=1.5, bots=(b,))         # Bob: Yes, then the go
    for c in (a, b):
        assert c.eval("return ns.Azero.pending and ns.Azero.pending.kind") == "trade", \
            c.eval("return ns.Azero.pending and ns.Azero.pending.kind")
    assert a.eval("return ns.AzeroTrade.session.host") is True      # Alice's key sorts first
    a.eval("ns.AzeroTrade:Offer(1)")
    b.eval("ns.AzeroTrade:Offer(1)")
    run(w, (a, b), seconds=0.6, bots=())


def reopen(c, w):
    """After a relog: the game opened again from the title (CONTINUE)."""
    open_game(c, w, new=False)
    c.eval("ns.AzeroTrade:Update()")


@case
def a_trade_cannot_duplicate_when_the_other_side_reloads_first():
    w, a, b = setup()
    open_trade(w, a, b)
    a.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=0.6, bots=())
    b.eval("ns.AzeroTrade:Confirm()")
    b.relog()                                       # Bob's confirm is on its way; his session is gone
    run(w, (a,), seconds=2, bots=())
    reopen(b, w)
    run(w, (a, b), seconds=3)
    assert a.eval_py("return T_PVP.party()") == ["murkling"], a.eval_py("return T_PVP.party()")
    assert b.eval_py("return T_PVP.party()") == ["emberwhelp"], b.eval_py("return T_PVP.party()")
    assert everyone(a, b) == ["emberwhelp", "murkling"]
    assert a.eval("return ns.AzeroTrade:Unfinished() == nil")
    assert "Nothing changed hands." in log(a), log(a)
    no_errors(w)


@case
def a_trade_cannot_duplicate_when_the_host_reloads_after_its_commit():
    w, a, b = setup()
    open_trade(w, a, b)
    b.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=0.6, bots=())
    a.eval("ns.AzeroTrade:Confirm()")               # escrow + commit ...
    assert a.eval("return ns.AzeroTrade.session.committing") is True
    assert a.eval_py("return T_PVP.party()") == []  # Alice's beast is in escrow, not in her save
    a.relog()                                       # ... and Alice reloads before Bob's answer lands
    run(w, (b,), seconds=2)
    assert b.eval_py("return T_PVP.party()") == ["murkling"]
    reopen(a, w)
    watch_prints(a)
    run(w, (a, b), seconds=3)
    assert a.eval_py("return T_PVP.party()") == ["emberwhelp"], a.eval_py("return T_PVP.party()")
    assert everyone(a, b) == ["emberwhelp", "murkling"], everyone(a, b)
    assert a.eval("return ns.AzeroTrade:Unfinished() == nil")
    assert a.eval("return ns.Azero.save.party[1].ot") == "Bob"
    # another reload changes nothing (both swaps are checkpointed, the log answers a repeated commit)
    a.relog()
    b.relog()
    reopen(a, w)
    reopen(b, w)
    b.eval("ns.Comm:Send({ t = 'AZT', op = 'commit', id = '1', h = 1 }, 'WHISPER', 'Alice-Thunderstrike', 'game')")
    run(w, (a, b), seconds=3)
    assert everyone(a, b) == ["emberwhelp", "murkling"], everyone(a, b)
    assert a.eval_py("return T_PVP.party()") == ["emberwhelp"]
    no_errors(w)


@case
def a_lost_ack_is_answered_again_from_the_log():
    w, a, b = setup()
    open_trade(w, a, b)
    b.eval("T_PVP.drop['AZT.ack'] = 1")             # Bob's first answer never arrives
    a.eval("ns.AzeroTrade:Confirm()")
    b.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=1)
    assert b.eval_py("return T_PVP.party()") == ["murkling"]
    assert a.eval("return ns.AzeroTrade.session and ns.AzeroTrade.session.committing") is True
    run(w, (a, b), seconds=5)                       # Alice repeats the commit; Bob answers from his log
    assert a.eval_py("return T_PVP.party()") == ["emberwhelp"], a.eval_py("return T_PVP.party()")
    assert b.eval_py("return T_PVP.party()") == ["murkling"]   # swapped once only
    assert len([m for m in sent(b, "AZT") if m["op"] == "ack"]) >= 2
    assert "Bob sent over Emberwhelp!" in log(a), log(a)
    no_errors(w)


@case
def no_answer_closes_the_screen_and_the_trade_completes_later():
    w, a, b = setup()
    open_trade(w, a, b)
    b.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=0.6, bots=())
    b.logout()                                      # Bob disconnects before Alice's commit
    a.eval("ns.AzeroTrade:Confirm()")
    run(w, (a,), seconds=35)
    assert "No answer from Bob yet." in log(a), log(a)
    assert a.eval("return ns.AzeroTrade.session == nil and ns.AzeroTrade:Unfinished() ~= nil")
    # no new trade while one is unfinished
    assert a.eval_py("return T_PVP.party()") == []
    b.login()
    w.tick(3)
    reopen(b, w)
    watch_prints(a)
    run(w, (a, b), seconds=35)                      # Bob doesn't know the trade any more: it's refused
    assert a.eval_py("return T_PVP.party()") == ["murkling"], a.eval_py("return T_PVP.party()")
    assert b.eval_py("return T_PVP.party()") == ["emberwhelp"]
    assert "didn't go through" in printed(a), printed(a)
    assert a.eval("return ns.AzeroTrade:Unfinished() == nil")
    no_errors(w)


@case
def a_commit_while_busy_waits_until_the_game_is_free():
    w, a, b = setup()
    open_trade(w, a, b)
    a.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=0.6, bots=())
    watch_prints(b)
    b.eval("ns.AzeroTrade:Confirm() ns.AzeroTrade:Cancel()")     # accepts and leaves at once
    run(w, (a, b), seconds=0.3, bots=())
    # Bob reads "The trade was cancelled." (a script: busy) - the commit must wait
    run(w, (a, b), seconds=3, bots=(a,))
    assert b.eval_py("return T_PVP.party()") == ["emberwhelp"]
    assert b.eval("return ns.AzeroTrade.last ~= nil and ns.AzeroTrade.last.deferred ~= nil")
    assert a.eval_py("return T_PVP.party()") == []                 # Alice's side waits in escrow
    run(w, (a, b), seconds=4)                                       # Bob is free again
    assert b.eval_py("return T_PVP.party()") == ["murkling"], b.eval_py("return T_PVP.party()")
    assert a.eval_py("return T_PVP.party()") == ["emberwhelp"], a.eval_py("return T_PVP.party()")
    assert "went through after all" in printed(b), printed(b)
    no_errors(w)


@case
def a_commit_sent_to_the_host_is_ignored():
    w, a, b = setup()
    open_trade(w, a, b)
    a.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=0.6, bots=())
    sid = a.eval("return ns.AzeroTrade.session.id")
    h = a.eval("return ns.AzeroTrade.session.myOk")
    b.eval("ns.Comm:Send({ t = 'AZT', op = 'commit', id = %r, h = %d }, 'WHISPER', 'Alice-Thunderstrike', 'game')"
           % (sid, h))
    run(w, (a, b), seconds=1, bots=())
    assert a.eval_py("return T_PVP.party()") == ["murkling"]
    assert a.eval("return ns.AzeroTrade.session.state") == "open"
    # a commit for a trade Bob never had: refused, and Bob's save is untouched
    a.eval("ns.Comm:Send({ t = 'AZT', op = 'commit', id = 'nope', h = 5 }, 'WHISPER', 'Bob-Thunderstrike', 'game')")
    run(w, (a, b), seconds=1, bots=())
    assert b.eval_py("return T_PVP.party()") == ["emberwhelp"]
    no_errors(w)


@case
def a_late_yes_to_a_trade_opens_nothing():
    w, a, b = setup()
    b.eval("T_PVP.answer = nil")                    # Bob leaves the prompt open
    a.eval("ns.Azero:PressA()")
    a.eval("ns.Azero:Advance(2)")
    run(w, (a, b), seconds=33, bots=(a,))          # Alice stops waiting (and says so)
    assert "Bob didn't answer." in log(a)
    b.eval("ns.Azero:Advance(1)")                   # Yes, too late
    run(w, (a, b), seconds=3)
    assert "Alice called off the trade." in log(b), log(b)
    assert a.eval("return ns.AzeroTrade.session == nil") and b.eval("return ns.AzeroTrade.session == nil")
    no_errors(w)


# --- player battles -------------------------------------------------------------------------------------------------

def challenge(a):
    a.eval("ns.Azero:PressA()")
    assert "Challenge Bob" in (a.eval("return ns.Azero.pending and ns.Azero.pending.text") or "")
    a.eval("ns.Azero:Advance(1)")


def until_match(w, cs):
    for _ in range(40):
        run(w, cs, seconds=0.3)
        if all(c.eval("return ns.AzeroPvP:InMatch()") for c in cs[:2]):
            return
    raise AssertionError("no match")


@case
def a_late_yes_to_a_challenge_starts_nothing():
    w, a, b = setup()
    b.eval("T_PVP.answer = nil")
    challenge(a)
    run(w, (a, b), seconds=33)                      # Alice gives up: Bob's prompt is told
    assert "Bob didn't answer." in log(a)
    b.eval("ns.Azero:Advance(1)")
    run(w, (a, b), seconds=3)
    assert "Alice withdrew the challenge." in log(b), log(b)
    assert not b.eval("return ns.AzeroPvP:InMatch()") and not a.eval("return ns.AzeroPvP:InMatch()")
    # the withdrawal is lost: Bob's prompt expires by itself, and a yes after that is turned away
    a.eval("T_PVP.drop.AZF = 1")
    challenge(a)
    run(w, (a, b), seconds=33)
    b.eval("ns.Azero:Advance(1)")
    run(w, (a, b), seconds=3)
    assert "The challenge from Alice expired." in log(b), log(b)
    # a stray yes (no prompt state left on Bob's side): Alice turns it away, Bob backs out of the start
    a.eval("T_PVP.drop.AZF = 0")
    b.eval("ns.AzeroPvP.starting = { id = 'x1', from = 'Alice-Thunderstrike', at = GetTime() }")
    b.eval("ns.Azero:Run(function(g) local r = g:Wait({ kind = 'netwait', text = 'Starting' }) T_PVP.start = r end)")
    b.eval("ns.Comm:Send({ t = 'AZA', id = 'x1', ok = true }, 'WHISPER', 'Alice-Thunderstrike', 'game')")
    run(w, (a, b), seconds=1, bots=())
    assert b.eval("return T_PVP.start") == "withdrawn"
    run(w, (a, b), seconds=100)
    assert not records(a) and not records(b), (records(a), records(b))
    no_errors(w)


@case
def my_turn_clock_runs_even_after_the_opponent_acted():
    w, a, b = setup()
    a.eval("T_PVP.idle = true")                     # Bob acts, Alice never does
    challenge(a)
    until_match(w, (a, b))
    run(w, (a, b), seconds=70)
    assert a.eval_py("return T_PVP.results") == ["lose"], a.eval_py("return T_PVP.results")
    assert b.eval_py("return T_PVP.results") == ["win"], b.eval_py("return T_PVP.results")
    assert "You forfeited the match." in log(a) and "Alice forfeited the match!" in log(b)
    no_errors(w)


@case
def a_slow_turn_gives_only_one_side_the_win():
    w, a, b = setup()
    challenge(a)
    until_match(w, (a, b))
    # Bob takes 58 s: Alice (already acted) must not call a timeout first
    b.eval("T_PVP.idle = true")
    run(w, (a, b), seconds=58)
    b.eval("T_PVP.idle = false")
    run(w, (a, b), seconds=200)
    ra, rb = a.eval_py("return T_PVP.results"), b.eval_py("return T_PVP.results")
    assert len(ra) == 1 and len(rb) == 1 and {ra[0], rb[0]} in ({"win", "lose"}, {"draw"}), (ra, rb)
    assert "forfeited" not in log(a) + log(b)
    # Bob's action is lost on the way: Alice calls the timeout after the grace and tells Bob, who takes the loss
    a.eval("T_PVP.results = {}")
    b.eval("T_PVP.results = {}")
    challenge(a)
    until_match(w, (a, b))
    b.eval("T_PVP.drop.AZM = 1")
    run(w, (a, b), seconds=90)
    ra, rb = a.eval_py("return T_PVP.results"), b.eval_py("return T_PVP.results")
    assert ra == ["win"] and rb == ["lose"], (ra, rb)
    assert "You ran out of time." in log(b), log(b)
    ka, kb = records(a)["Bob-Thunderstrike"], records(b)["Alice-Thunderstrike"]
    assert (ka["w"], ka["l"], ka["d"]) == (kb["l"], kb["w"], kb["d"]), (ka, kb)
    no_errors(w)


@case
def a_reload_mid_match_is_a_loss_the_opponent_hears_at_once():
    w, a, b = setup()
    challenge(a)
    until_match(w, (a, b))
    b.eval("T_PVP.idle = true")
    run(w, (a, b), seconds=2)
    assert b.eval("return ns.Games:GetData('azeromon').pvpOpen ~= nil")
    b.relog()                                       # the match is gone with the old session
    run(w, (a,), seconds=3)
    assert a.eval_py("return T_PVP.results") == ["win"], a.eval_py("return T_PVP.results")
    assert "Bob left the match. You win!" in log(a), log(a)
    assert records(a)["Bob-Thunderstrike"]["w"] == 1
    rb = records(b)["Alice-Thunderstrike"]
    assert (rb["w"], rb["l"]) == (0, 1), rb
    assert b.eval("return ns.Games:GetData('azeromon').pvpOpen == nil")
    # closing the game window mid-match: a loss counted right away, the opponent wins at once
    reopen(b, w)
    b.eval("ns.Azero:EnterMap('town', 9, 9, 'left', true)")
    a.eval("T_PVP.results = {}")
    run(w, (a, b), seconds=2)
    challenge(a)
    until_match(w, (a, b))
    b.eval("ns.AzeroNet:SetActive(false)")
    assert records(b)["Alice-Thunderstrike"]["l"] == 2
    run(w, (a,), seconds=2)
    assert a.eval_py("return T_PVP.results") == ["win"]
    assert records(a)["Bob-Thunderstrike"]["w"] == 2
    no_errors(w)


@case
def different_game_data_refuses_the_battle():
    w, a, b = setup()
    b.eval("ns.AzeroData.moves.tackle.power = 99")  # Bob's Data.lua differs
    challenge(a)
    run(w, (a, b), seconds=3)
    assert "Bob has a different game version." in log(a), log(a)
    assert not a.eval("return ns.AzeroPvP:InMatch()") and not b.eval("return ns.AzeroPvP:InMatch()")
    assert a.eval("return ns.AzeroPvP.Fingerprint()") != b.eval("return ns.AzeroPvP.Fingerprint()")
    no_errors(w)


@case
def a_team_the_challenger_cannot_read_calls_it_off_for_both():
    w, a, b = setup()
    b.eval("ns.AzeroPvP.PackTeam = function() return { { sp = 'nothing', lvl = 5 } } end")
    challenge(a)
    run(w, (a, b), seconds=3)
    assert "Something went wrong with the other team." in log(a), log(a)
    assert "Alice withdrew the challenge." in log(b), log(b)
    assert not b.eval("return ns.AzeroPvP:InMatch()")
    run(w, (a, b), seconds=90)
    assert not records(a) and not records(b)
    no_errors(w)


# --- spectators and the shared queue -------------------------------------------------------------------------------

def watch(c):
    c.eval("ns.Azero:PressA()")
    text = c.eval("return ns.Azero.pending and ns.Azero.pending.text") or ""
    assert "Alice is battling Bob" in text, text
    c.eval("ns.Azero:Advance(1)")


@case
def spectators_survive_long_turns_and_ghosts_free_their_slot():
    w, a, b, c = setup(("Alice", "Bob", "Carol"))
    for cl in (a, b):
        cl.eval("ns.AzeroPvP.TURN_TIMEOUT = 400")   # a long match
    challenge(a)
    until_match(w, (a, b, c))
    b.eval("T_PVP.idle = true")
    run(w, (a, b, c), seconds=2)
    watch(c)
    run(w, (a, b, c), seconds=1)
    assert c.eval("return ns.AzeroWatch:Watching()")
    # Alice's presence stops (WoW combat): the keepalive still carries the watch through a long turn
    a.eval("InCombatLockdown = function() return true end")
    run(w, (a, b, c), seconds=130)
    assert c.eval("return ns.AzeroWatch:Watching()"), log(c)
    assert a.eval("return ns.AzeroPvP:WatcherCount()") == 1
    # Carol reloads: her slot is freed once she's been quiet for a while
    c.relog()
    run(w, (a, b), seconds=65)
    assert a.eval("return ns.AzeroPvP:WatcherCount()") == 0
    # the relay itself goes quiet: the spectator names the player she asked
    reopen(c, w)
    c.eval("ns.Azero:EnterMap('town', 8, 10, 'up', true)")
    a.eval("InCombatLockdown = function() return false end")
    run(w, (a, b, c), seconds=2)
    watch(c)
    run(w, (a, b, c), seconds=1)
    assert c.eval("return ns.AzeroWatch:Watching()")
    a.eval("T_PVP.drop.AZV = 1000")
    run(w, (a, b, c), seconds=120)
    assert "Lost touch with Alice, so the battle can't be followed any more." in log(c), log(c)
    no_errors(w)


@case
def presence_waits_for_the_queue_and_turns_go_before_relays():
    w, a, b, c = setup(("Alice", "Bob", "Carol"))
    n = len(sent(a, "AZP"))
    a.eval("T_BACKLOG = ns.Comm.Backlog; ns.Comm.Backlog = function() return 5000 end")
    a.eval("ns.Azero.save.face = 'up'")             # a change that would be sent at once
    run(w, (a,), seconds=12)
    assert len(sent(a, "AZP")) == n, sent(a, "AZP")[n:]
    a.eval("ns.Comm.Backlog = T_BACKLOG")
    run(w, (a,), seconds=1.5)
    assert len(sent(a, "AZP")) > n
    a.eval("ns.Azero.save.face = 'right'")
    run(w, (a, b, c), seconds=1.5)
    challenge(a)
    until_match(w, (a, b, c))
    b.eval("T_PVP.idle = true")
    run(w, (a, b, c), seconds=2)
    watch(c)
    run(w, (a, b, c), seconds=1)
    b.eval("T_PVP.idle = false")
    n0 = len(sent(a))
    run(w, (a, b, c), seconds=200)
    seq = sent(a)[n0:]
    pos_move = {m["turn"]: i for i, m in enumerate(seq) if m["t"] == "AZM"}
    relays = [(i, m["n"]) for i, m in enumerate(seq) if m["t"] == "AZV" and m["op"] == "turn"]
    assert relays and pos_move, (relays, pos_move)
    for i, nturn in relays:                         # turn n reaches Carol after my action for turn n + 1
        if nturn + 1 in pos_move:
            assert pos_move[nturn + 1] < i, (nturn, seq)
    # during the match presence slows down (a status change still goes out at once)
    p = [m for m in seq if m["t"] == "AZP"]
    assert len(p) <= 200 / 5 + 3, len(p)
    no_errors(w)


@case
def the_shared_random_numbers_do_not_fall_into_a_short_cycle():
    w = World()
    c = Client(w, "Alice", guild_rank=3)
    c.load_addon()
    r = c.eval_py(r"""local P = ns.AzeroPvP
      local out = {}
      -- many draws, distinct seeds: the old generator lost precision and repeated after ~10k draws
      local rng = P.NewRng(123456789)
      local seen, n = {}, 0
      for _ = 1, 30000 do
        local v = rng(1, 1000000000)
        if not seen[v] then seen[v] = true n = n + 1 end
      end
      out.distinct = n
      -- every value in range, both ends reachable
      local lo, hi, bad = false, false, false
      local r2 = P.NewRng(7)
      for _ = 1, 20000 do
        local v = r2(1, 6)
        if v == 1 then lo = true elseif v == 6 then hi = true elseif v < 1 or v > 6 or v % 1 ~= 0 then bad = true end
      end
      out.lo, out.hi, out.bad = lo, hi, bad
      -- the same seed gives the same numbers; neighbouring seeds don't
      local x, y, z = P.NewRng(42), P.NewRng(42), P.NewRng(43)
      local same, diff = true, false
      for _ = 1, 50 do
        local a1, b1, c1 = x(1, 1000), y(1, 1000), z(1, 1000)
        if a1 ~= b1 then same = false end
        if a1 ~= c1 then diff = true end
      end
      out.same, out.diff = same, diff
      -- odd seeds are fine
      out.odd = P.NewRng(0)(1, 10) ~= nil and P.NewRng(-5)(1, 10) ~= nil and P.NewRng('x')(1, 10) ~= nil
        and P.NewRng(1 / 0)(1, 10) ~= nil
      return out""")
    assert r["distinct"] > 29000, r
    assert r["lo"] and r["hi"] and not r["bad"], r
    assert r["same"] and r["diff"] and r["odd"], r
    no_errors(w)


if __name__ == "__main__":
    run_all()

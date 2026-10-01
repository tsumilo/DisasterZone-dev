"""Azeromon multiplayer: watching guildmates battle, and the "battling..." bubble over busy players.

Covers: presence carries what a player is busy with (a player battle names the opponent), the bubble over busy
guildmates and "Space: Watch the battle"; a spectator who joins mid-match catches up and then sees exactly what
the challenger sees, turn by turn, to the same result (with gear on a beast: both players and the spectator build
the teams the same way); the players' own match and records are untouched; stopping (B) tells the player and the
match goes on; a player who leaves ends the watch; late / full / finished answers; pressing A on a guildmate busy
with something else; a whole watch through the real UI with keys only.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_watch.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, no_errors, World, Client  # noqa: E402
from _azero_bot import BOT  # noqa: E402

# The players (same as test_azeromon_pvp) plus a spectator bot.
BOTS = r"""
local G, D, M = ns.Azero, ns.AzeroData, ns.AzeroMon
T_PVP = { answer = 1, policy = nil, trace = {}, results = {} }
function T_PVP.tick()
  local p = G.pending
  if not p then return end
  if p.kind == "text" then T_AZ.log[#T_AZ.log + 1] = p.text G:Advance()
  elseif p.kind == "choice" then G:Advance(T_PVP.answer)
  elseif p.kind == "battle" then
    local b = p.battle
    local e = b:Pop()
    while e do
      if e.t == "text" then T_AZ.log[#T_AZ.log + 1] = e.text end
      e = b:Pop()
    end
    if b.need == "watch" then
      T_PVP.trace[b.turn] = { turn = b.turn, ally = b.ally.mon.hp, foe = b.foe.mon.hp,
                              allySp = b.ally.mon.sp, foeSp = b.foe.mon.sp }
    elseif b.need == "action" and not T_PVP.idle then
      local act = T_PVP.policy and T_PVP.policy(b) or { kind = "move", idx = T_AZ.bestMove(b) }
      T_PVP.trace[#T_PVP.trace + 1] = { turn = b.turn, ally = b.ally.mon.hp, foe = b.foe.mon.hp,
                                        allySp = b.ally.mon.sp, foeSp = b.foe.mon.sp }
      if not b:Act(act) then b:Act({ kind = "move", idx = T_AZ.bestMove(b) }) end
    elseif b.need == "done" then
      T_PVP.final = { turn = b.turn, ally = b.ally.mon.hp, foe = b.foe.mon.hp }
      T_PVP.results[#T_PVP.results + 1] = b.result
      G:Advance(b.result)
    end
  elseif p.kind == "wait" or p.kind == "evolve" then G:Update(0.5) end
end
"""

TEAM = ("local G, M, D = ns.Azero, ns.AzeroMon, ns.AzeroData; G.save.party = { M.New(%r, 12, G.rng), "
        "M.New('wolfpup', 11, G.rng), M.New('lashling', 11, G.rng) }; G.save.party[1].hp = 3")

GEAR = """local D = ns.AzeroData
for id, d in pairs(D.items) do
  if d.use == 'gear' then ns.Azero.save.party[1].gear = { [d.slot] = id } return id end
end"""


def start(c, w, x, y, face):
    c.eval(BOT)
    c.eval(BOTS)
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    for _ in range(40):
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        if not c.eval("return ns.Azero.pending ~= nil"):
            break
    c.eval("ns.Azero:EnterMap('town', %d, %d, %r, true)" % (x, y, face))


def setup(detach=True):
    """Alice (8,9) faces Bob (9,9); Carol stands below Alice (8,10), facing her."""
    w = World()
    a, b, c = (Client(w, n, guild_rank=3) for n in ("Alice", "Bob", "Carol"))
    for cl in (a, b, c):
        cl.load_addon()
    w.tick(3)
    for cl, x, y, face, sp in ((a, 8, 9, "right", "murkling"), (b, 9, 9, "left", "emberwhelp"),
                               (c, 8, 10, "up", "lashling")):
        start(cl, w, x, y, face)
        if detach:
            cl.eval("ns.AzeroUI._Detach()")
        cl.eval(TEAM % sp)
    run(w, (a, b, c), seconds=2)
    return w, a, b, c


def run(w, clients, seconds=1, step=0.3):
    for _ in range(int(seconds / step)):
        for cl in clients:
            cl.eval("T_PVP.tick()")
            cl.eval("ns.AzeroNet:Update(0.3); ns.AzeroPvP:Update(); ns.AzeroWatch:Update()")
        w.tick(step)


def challenge(a, w, clients):
    a.eval("ns.Azero:PressA()")
    assert "Challenge Bob" in (a.eval("return ns.Azero.pending and ns.Azero.pending.text") or "")
    a.eval("ns.Azero:Advance(1)")
    for _ in range(40):
        run(w, clients, seconds=0.3)
        if a.eval("return ns.AzeroPvP:InMatch()"):
            return
    raise AssertionError("no match")


def peer(cl, name):
    return cl.eval_py("""for _, p in ipairs(ns.AzeroNet:PeersOn('town')) do
        if p.name == %r then return { status = p.status, vs = p.vs } end end""" % name)


def log(cl):
    return "\n".join(cl.eval_py("return T_AZ.log") or [])


def watch(c):
    """Carol presses A on Alice and says yes."""
    c.eval("ns.Azero:PressA()")
    text = c.eval("return ns.Azero.pending and ns.Azero.pending.text") or ""
    assert "Alice is battling Bob" in text, text
    c.eval("ns.Azero:Advance(1)")


@case
def presence_says_who_is_busy_with_what():
    w, a, b, c = setup()
    assert peer(c, "Alice") == {} or peer(c, "Alice").get("status") is None
    assert c.eval("return (ns.Azero:InteractHint())") is None
    challenge(a, w, (a, b, c))
    b.eval("T_PVP.idle = true")                 # keep the match going
    run(w, (a, b, c), seconds=2)
    assert peer(c, "Alice") == {"status": "pvp", "vs": "Bob-Thunderstrike"}, peer(c, "Alice")
    assert peer(c, "Bob") == {"status": "pvp", "vs": "Alice-Thunderstrike"}, peer(c, "Bob")
    assert c.eval("return (ns.Azero:InteractHint())") == "Watch the battle"
    b.eval("T_PVP.idle = false")
    run(w, (a, b, c), seconds=120)
    assert a.eval_py("return T_PVP.results") and not a.eval("return ns.AzeroPvP:InMatch()")
    run(w, (a, b, c), seconds=2)
    assert peer(c, "Alice").get("status") is None, peer(c, "Alice")
    # an ordinary battle and a trade say so too; A on such a guildmate explains instead of challenging
    a.eval("ns.Azero.battle = {}")
    run(w, (a, c), seconds=1.5)
    assert peer(c, "Alice").get("status") == "battle"
    c.eval("ns.Azero:PressA()")
    assert c.eval("return ns.Azero.pending.text") == "Alice is in a battle right now."
    c.eval("ns.Azero:Advance()")
    a.eval("ns.Azero.battle = nil; ns.AzeroTrade.session = {}")
    run(w, (a,), seconds=1.5)
    assert peer(c, "Alice").get("status") == "trade"
    a.eval("ns.AzeroTrade.session = nil")
    no_errors(w)


@case
def a_spectator_who_joins_mid_match_sees_what_the_challenger_sees():
    w, a, b, c = setup()
    gear = a.eval(GEAR)                          # gear changes stats: every copy of the match must include it
    assert gear
    challenge(a, w, (a, b, c))
    run(w, (a, b), seconds=2)                    # a turn or more before Carol arrives
    b.eval("T_PVP.idle = true")
    run(w, (a, b), seconds=1)
    joined = a.eval("return ns.AzeroPvP:Match().battle.turn")
    assert joined >= 1, joined
    run(w, (a, b, c), seconds=1)
    watch(c)
    run(w, (a, b, c), seconds=1)
    assert c.eval("return ns.AzeroWatch:Watching()")
    assert "You're watching Alice and Bob battle!" in log(c), log(c)
    assert a.eval("return ns.AzeroPvP:WatcherCount()") == 1
    b.eval("T_PVP.idle = false")
    run(w, (a, b, c), seconds=240)
    ra, rb, rc = (cl.eval_py("return T_PVP.results") for cl in (a, b, c))
    assert len(ra) == 1 and len(rc) == 1 and rc == ra, (ra, rb, rc)
    # every turn Carol saw matches Alice's screen (Carol watches from the challenger's side)
    ta = {t["turn"]: t for t in a.eval_py("return T_PVP.trace")}
    tc = c.eval_py("return T_PVP.trace")
    tc = tc.values() if isinstance(tc, dict) else tc
    assert tc
    for t in tc:
        assert t["turn"] >= joined
        if t["turn"] in ta:
            assert t == ta[t["turn"]], (t, ta[t["turn"]])
    assert a.eval_py("return T_PVP.final") == c.eval_py("return T_PVP.final")
    # Alice's and Bob's views mirror each other too (the gear no longer splits them)
    tb = {t["turn"]: t for t in b.eval_py("return T_PVP.trace")}
    for turn, t in ta.items():
        if turn in tb:
            assert (t["ally"], t["foe"]) == (tb[turn]["foe"], tb[turn]["ally"]), (t, tb[turn])
    # watching leaves no trace: no record, the spectator's party untouched
    assert not (c.eval_py("return ns.Games:GetData('azeromon').pvp") or {})
    assert c.eval("return ns.Azero.save.party[1].hp") == 3
    assert not c.eval("return ns.AzeroWatch:Watching()") and c.eval("return ns.Azero:IsFree()")
    no_errors(w)


@case
def stopping_tells_the_player_and_the_match_goes_on():
    w, a, b, c = setup()
    challenge(a, w, (a, b, c))
    b.eval("T_PVP.idle = true")
    run(w, (a, b, c), seconds=2)
    watch(c)
    run(w, (a, b, c), seconds=1)
    assert a.eval("return ns.AzeroPvP:WatcherCount()") == 1
    c.eval("ns.AzeroWatch:Stop()")
    run(w, (a, b, c), seconds=1)
    assert "You stopped watching." in log(c)
    assert not c.eval("return ns.AzeroWatch:Watching()")
    assert a.eval("return ns.AzeroPvP:WatcherCount()") == 0
    b.eval("T_PVP.idle = false")
    run(w, (a, b, c), seconds=200)
    assert len(a.eval_py("return T_PVP.results")) == 1 and len(b.eval_py("return T_PVP.results")) == 1
    assert c.eval_py("return T_PVP.results") == ["left"]          # the spectator's own copy just stopped
    no_errors(w)


@case
def the_watch_ends_when_the_player_leaves():
    w, a, b, c = setup()
    challenge(a, w, (a, b, c))
    b.eval("T_PVP.idle = true")
    run(w, (a, b, c), seconds=2)
    watch(c)
    run(w, (a, b, c), seconds=1)
    assert c.eval("return ns.AzeroWatch:Watching()")
    a.eval("ns.AzeroNet:SetActive(false)")      # Alice closes the game: she says goodbye (AZL)
    run(w, (c,), seconds=1)
    assert "Alice left, so the battle can't be followed any more." in log(c), log(c)
    assert not c.eval("return ns.AzeroWatch:Watching()")
    no_errors(w)


@case
def finished_full_and_unanswered_requests():
    w, a, b, c = setup()
    # the match ended between the bubble and the question
    c.eval("ns.Azero:Run(function(g) ns.AzeroWatch:Watch(g, ns.AzeroNet:Peer('Alice-Thunderstrike')) end)")
    run(w, (a, c), seconds=1)
    assert "That battle is already over." in log(c), log(c)
    # too many spectators already
    challenge(a, w, (a, b, c))
    b.eval("T_PVP.idle = true")
    a.eval("ns.AzeroPvP.MAX_WATCHERS = 0")
    run(w, (a, b, c), seconds=2)
    watch(c)
    run(w, (a, b, c), seconds=1)
    assert "Too many guildmates are watching" in log(c), log(c)
    # no answer at all
    a.eval("ns.Comm:Register('AZW', function() end)")
    watch(c)
    run(w, (a, b, c), seconds=17)
    assert "Alice didn't answer." in log(c), log(c)
    assert not c.eval("return ns.AzeroWatch:Watching()")
    no_errors(w)


@case
def watching_through_the_real_ui_with_keys_only():
    """Carol sees the bubble, presses Space on Alice, watches, and leaves with B; then watches another to the end."""
    w, a, b, c = setup(detach=False)
    for cl in (a, b):
        cl.eval("ns.AzeroUI._Detach()")
    challenge(a, w, (a, b))
    b.eval("T_PVP.idle = true")
    for _ in range(8):
        run(w, (a, b), seconds=0.3)
        c.eval("ns.AzeroWatch:Update()")
    bubbles = c.eval_py("return ns.AzeroUI._PeerBubbles()")
    assert bubbles.get("Alice", "").startswith("battling") and bubbles.get("Bob", "").startswith("battling"), bubbles
    c.eval("ns.AzeroUI._HandleKey('A')")        # "Alice is battling Bob. Watch the battle?"
    w.tick(0.5)
    c.eval("ns.AzeroUI._HandleKey('A')")        # Yes
    for _ in range(20):
        run(w, (a, b), seconds=0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
    assert c.eval("return ns.AzeroWatch:Watching()"), c.eval_py("return ns.AzeroUI._State()")
    # Carol now shows as watching to the others
    run(w, (a, b), seconds=1.5)
    assert peer(a, "Carol").get("status") == "watch"
    c.eval("ns.AzeroUI._HandleKey('B')")        # "Stop watching?"
    c.eval("ns.AzeroUI._HandleKey('A')")        # Stop watching
    for _ in range(20):                         # "You stopped watching." (still facing Alice: no more Space after)
        run(w, (a, b), seconds=0.3)
        if not c.eval("return ns.AzeroWatch:Watching()") and c.eval("return ns.Azero:IsFree()"):
            break
        c.eval("ns.AzeroUI._HandleKey('A')")
    assert not c.eval("return ns.AzeroWatch:Watching()")
    assert c.eval("return ns.Azero:IsFree()"), c.eval_py("return ns.AzeroUI._State()")
    assert a.eval("return ns.AzeroPvP:WatcherCount()") == 0
    # again, this time to the end
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.5)
    c.eval("ns.AzeroUI._HandleKey('A')")
    for _ in range(10):
        run(w, (a, b), seconds=0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
    assert c.eval("return ns.AzeroWatch:Watching()")
    b.eval("T_PVP.idle = false")
    for _ in range(800):
        run(w, (a, b), seconds=0.3)
        if a.eval_py("return T_PVP.results") and not c.eval("return ns.AzeroWatch:Watching()"):
            break
        c.eval("ns.AzeroUI._HandleKey('A')")
    assert a.eval_py("return T_PVP.results")
    assert not c.eval("return ns.AzeroWatch:Watching()"), c.eval_py("return ns.AzeroUI._State()")
    for _ in range(10):
        if c.eval("return ns.Azero:IsFree()"):
            break
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
    assert c.eval("return ns.Azero:IsFree()"), c.eval_py("return ns.AzeroUI._State()")
    assert not c.eval_py("return ns.Games:GetData('azeromon').pvp")
    no_errors(w)


if __name__ == "__main__":
    run_all()

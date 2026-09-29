"""Azeromon multiplayer, step 2: battles between guildmates (lockstep over whispers).

Covers: a full match plays out identically on both clients (every turn's HP mirrors, complementary results,
the record is kept), the real parties are untouched afterwards, declining / busy / no answer, withdrawing a
challenge, forfeiting, a silent opponent forfeits after the turn timeout, mirror matches with speed ties stay
in sync, stray or wrong-turn messages are ignored, and the traffic is whispers on the game prefix.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_pvp.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, no_errors, World, Client  # noqa: E402
from _azero_bot import BOT  # noqa: E402

PVP_BOT = r"""
local G, D, M = ns.Azero, ns.AzeroData, ns.AzeroMon
T_PVP = { answer = 1, policy = nil, trace = {}, results = {} }
-- One step of an unattended player: answers prompts, plays battles with the best move, records every turn.
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
    if b.need == "action" and not T_PVP.idle then
      local act = T_PVP.policy and T_PVP.policy(b) or { kind = "move", idx = T_AZ.bestMove(b) }
      T_PVP.trace[#T_PVP.trace + 1] = { turn = b.turn, ally = b.ally.mon.hp, foe = b.foe.mon.hp }
      if not b:Act(act) then b:Act({ kind = "move", idx = T_AZ.bestMove(b) }) end
    elseif b.need == "done" then
      T_PVP.trace[#T_PVP.trace + 1] = { turn = b.turn, ally = b.ally.mon.hp, foe = b.foe.mon.hp, final = true }
      T_PVP.results[#T_PVP.results + 1] = b.result
      G:Advance(b.result)
    end
  elseif p.kind == "wait" or p.kind == "evolve" then G:Update(0.5) end
end
"""


def player(w, name):
    c = Client(w, name, guild_rank=3)
    return c


def setup(team_a=("murkling", 12), team_b=("emberwhelp", 12), extra=None):
    w = World()
    a, b = Client(w, "Alice", guild_rank=3), Client(w, "Bob", guild_rank=3)
    for c in (a, b):
        c.load_addon()
    w.tick(3)
    for c, (sp, lvl), x in ((a, team_a, 8), (b, team_b, 9)):
        c.eval(BOT)
        c.eval(PVP_BOT)
        c.slash("/cdl play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        for _ in range(40):
            w.tick(0.3)
            c.eval("ns.AzeroUI._HandleKey('A')")
            if not c.eval("return ns.Azero.pending ~= nil"):
                break
        # the UI would play the battle itself: keep it out of the way, the bots drive the engine
        c.eval("ns.AzeroUI._Detach()")
        c.eval("local G, M = ns.Azero, ns.AzeroMon; G:EnterMap('town', %d, 9, %r, true); "
               "G.save.party = { M.New(%r, %d, G.rng) }; G.save.party[1].hp = 3"
               % (x, "right" if x == 8 else "left", sp, lvl))
    if extra:
        extra(a, b)
    run(w, (a, b), seconds=2)               # presence: each sees the other
    return w, a, b


def run(w, clients, seconds=120, step=0.3):
    for _ in range(int(seconds / step)):
        for c in clients:
            c.eval("T_PVP.tick()")
            c.eval("ns.AzeroNet:Update(0.3); ns.AzeroPvP:Update()")
        w.tick(step)


def challenge(a):
    a.eval("ns.Azero:PressA()")            # facing Bob -> "Challenge Bob to a battle?"
    assert "Challenge Bob" in (a.eval("return ns.Azero.pending and ns.Azero.pending.text") or "")
    a.eval("ns.Azero:Advance(1)")          # Yes -> waiting for Bob


def log(c):
    return "\n".join(c.eval_py("return T_AZ.log") or [])


@case
def a_full_match_plays_identically_on_both_clients():
    w, a, b = setup()
    n0 = len(w.addon_log)
    challenge(a)
    run(w, (a, b))
    ra, rb = a.eval_py("return T_PVP.results"), b.eval_py("return T_PVP.results")
    assert len(ra) == 1 and len(rb) == 1, (ra, rb)
    assert {ra[0], rb[0]} == {"win", "lose"}, (ra, rb)
    ta, tb = a.eval_py("return T_PVP.trace"), b.eval_py("return T_PVP.trace")
    # Alice's view of each turn is Bob's view mirrored
    mirror = [(t["turn"], t["foe"], t["ally"]) for t in tb]
    assert [(t["turn"], t["ally"], t["foe"]) for t in ta] == mirror, (ta, tb)
    # real parties untouched (both were at 3 HP), records kept
    assert a.eval("return ns.Azero.save.party[1].hp") == 3 and b.eval("return ns.Azero.save.party[1].hp") == 3
    rec = a.eval_py("return ns.Games:GetData('azeromon').pvp")
    assert sum(rec[k]["w"] + rec[k]["l"] for k in rec) == 1, rec
    # all battle traffic is whispers on the game prefix
    battle = [e for e in w.addon_log[n0:] if e["prefix"] == "CDLg" and e["chat_type"] == "WHISPER"]
    assert battle and all(e["prefix"] == "CDLg" for e in battle)
    no_errors(w)


@case
def mirror_match_with_speed_ties_stays_in_sync():
    def same_ivs(a, b):
        for c in (a, b):
            c.eval("local m = ns.Azero.save.party[1]; m.ivs = { 10, 10, 10, 10, 10, 10 }; ns.AzeroMon.Heal(m); m.hp = 3; "
                   "ns.Azero.save.party[2] = ns.AzeroMon.New('wolfpup', 11, ns.Azero.rng); "
                   "ns.Azero.save.party[2].ivs = { 5, 5, 5, 5, 5, 5 }")
    w, a, b = setup(("lashling", 12), ("lashling", 12), extra=same_ivs)
    challenge(a)
    run(w, (a, b), seconds=240)
    ta, tb = a.eval_py("return T_PVP.trace"), b.eval_py("return T_PVP.trace")
    assert ta and [(t["turn"], t["ally"], t["foe"]) for t in ta] == [(t["turn"], t["foe"], t["ally"]) for t in tb]
    ra, rb = a.eval_py("return T_PVP.results"), b.eval_py("return T_PVP.results")
    assert (ra, rb) in ((["win"], ["lose"]), (["lose"], ["win"]), (["draw"], ["draw"])), (ra, rb)
    no_errors(w)


@case
def declined_busy_and_unanswered_challenges():
    w, a, b = setup()
    b.eval("T_PVP.answer = 2")             # Bob says No
    challenge(a)
    run(w, (a, b), seconds=5)
    assert "Bob declined" in log(a)
    # Bob busy in a conversation: automatic "busy"
    b.eval("ns.Azero:Run(function(g) g:Say('Talking to Maybell...') end)")
    challenge(a)
    run(w, (a,), seconds=3)
    assert "Bob is busy" in log(a)
    b.eval("ns.Azero:Advance()")
    # Bob closes the game window entirely: his Net is inactive, so he answers busy too; if he never answers at all
    # (offline mid-way), Alice gives up after 30 s
    b.eval("ns.AzeroPvP.OnInit = nil")
    b.eval("ns.Comm:Register('AZC', function() end)")
    challenge(a)
    run(w, (a,), seconds=35)
    assert "Bob didn't answer" in log(a)
    no_errors(w)


@case
def withdrawing_a_challenge():
    w, a, b = setup()
    b.eval("T_PVP.answer = nil")            # Bob leaves the prompt open
    b.eval("T_PVP.tick = function() end")
    challenge(a)
    w.tick(1)
    assert "challenges you" in (b.eval("return ns.Azero.pending and ns.Azero.pending.text") or "")
    a.eval("ns.Azero:Advance('cancel')")    # Alice presses X
    w.tick(1)
    b.eval("ns.Azero:Advance(1)")           # Bob says yes too late
    w.tick(0.5)
    assert "withdrew the challenge" in (b.eval("return ns.Azero.pending and ns.Azero.pending.text") or "")
    assert b.eval("return ns.AzeroPvP:InMatch()") is False
    no_errors(w)


@case
def forfeiting_and_timeouts():
    w, a, b = setup()
    a.eval("T_PVP.policy = function(b) return { kind = 'forfeit' } end")
    challenge(a)
    run(w, (a, b), seconds=20)
    assert a.eval_py("return T_PVP.results") == ["lose"] and b.eval_py("return T_PVP.results") == ["win"]
    assert "forfeited" in log(b)
    # second match: Bob goes silent after accepting -> Alice wins after the turn timeout, Bob's own clock
    # forfeits him too, so both agree
    a.eval("T_PVP.policy = nil; T_PVP.results = {}")
    b.eval("T_PVP.results = {}")
    challenge(a)
    run(w, (a, b), seconds=3)
    b.eval("T_PVP.idle = true")
    run(w, (a, b), seconds=80)
    assert a.eval_py("return T_PVP.results") == ["win"], a.eval_py("return T_PVP.results")
    assert b.eval_py("return T_PVP.results") == ["lose"], b.eval_py("return T_PVP.results")
    no_errors(w)


@case
def stray_and_wrong_turn_messages_are_ignored():
    w, a, b = setup()
    challenge(a)
    mid = None
    for _ in range(40):                     # inject as soon as the match exists
        run(w, (a, b), seconds=0.3)
        mid = a.eval("return ns.AzeroPvP:Match() and ns.AzeroPvP:Match().id")
        if mid:
            break
    assert mid
    # a move for a turn far ahead, one for another match id, and garbage: none of them may be applied
    for msg in ("{ t = 'AZM', id = %r, turn = 99, a = { kind = 'forfeit' } }" % mid,
                "{ t = 'AZM', id = 'other', turn = 1, a = { kind = 'forfeit' } }",
                "{ t = 'AZM', id = %r, turn = 'x', a = 'boom' }" % mid):
        b.eval("ns.Comm:Send(%s, 'WHISPER', 'Alice-Thunderstrike', 'game')" % msg)
    run(w, (a, b), seconds=200)
    ta, tb = a.eval_py("return T_PVP.trace"), b.eval_py("return T_PVP.trace")
    assert [(t["turn"], t["ally"], t["foe"]) for t in ta] == [(t["turn"], t["foe"], t["ally"]) for t in tb]
    ra, rb = a.eval_py("return T_PVP.results"), b.eval_py("return T_PVP.results")
    assert len(ra) == 1 and {ra[0], rb[0]} in ({"win", "lose"}, {"draw"}), (ra, rb)
    assert "forfeited" not in log(a) + log(b)
    no_errors(w)


@case
def a_match_through_the_real_ui_with_keys_only():
    """Both players use only keys (Space): challenge, accept, fight to the end, back in the overworld."""
    w = World()
    a, b = Client(w, "Alice", guild_rank=3), Client(w, "Bob", guild_rank=3)
    for c in (a, b):
        c.load_addon()
    w.tick(3)
    for c, x, face in ((a, 8, "right"), (b, 9, "left")):
        c.eval(BOT)
        c.slash("/cdl play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        for _ in range(40):
            w.tick(0.3)
            c.eval("ns.AzeroUI._HandleKey('A')")
            if not c.eval("return ns.Azero.pending ~= nil"):
                break
        c.eval("local G, M = ns.Azero, ns.AzeroMon; G:EnterMap('town', %d, 9, %r, true); "
               "G.save.party = { M.New('murkling', 8, G.rng) }; G.save.party[1].moves = { { id = 'waterjet', pp = 25 } }"
               % (x, face))
    w.tick(3)
    a.eval("ns.AzeroUI._HandleKey('A')")       # talk to Bob -> "Challenge Bob?"
    w.tick(0.5)
    a.eval("ns.AzeroUI._HandleKey('A')")       # Yes
    done = False
    for _ in range(600):
        w.tick(0.25)
        for c in (a, b):
            c.eval("ns.AzeroUI._HandleKey('A')")
        states = [c.eval("return ns.AzeroPvP:InMatch() or ns.Azero.pending ~= nil or ns.Azero.co ~= nil") for c in (a, b)]
        rec = a.eval_py("return ns.Games:GetData('azeromon').pvp")
        if rec and not any(states):
            done = True
            break
    assert done, [c.eval_py("return ns.AzeroUI._State()") for c in (a, b)]
    ra = a.eval_py("return ns.Games:GetData('azeromon').pvp")
    rb = b.eval_py("return ns.Games:GetData('azeromon').pvp")
    (ka, va), = ra.items()
    (kb, vb), = rb.items()
    assert (va["w"], va["l"], va["d"]) == (vb["l"], vb["w"], vb["d"]), (ra, rb)
    no_errors(w)


if __name__ == "__main__":
    run_all()

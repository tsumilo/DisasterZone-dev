"""Azeromon: UI edge cases that used to freeze or confuse the game.

Covers: a Message on screen when a guildmate's challenge arrives (the prompt waits for it, nothing is left waiting on
a message nobody sees) and any text replacing a message; a challenge accepted over the start menu or the bag closes
them; a click on a bag row while a message is up does nothing; a PvP turn that runs out while the battle menus are
open closes them and the match still ends; a click on the battle text box never picks a menu entry; Esc pauses the
game (no script timers, no battle playback) but a match between players keeps going and the overlay says so; the
"What will X do?" prompt comes back after a message; the capture net is not grey in the next battle.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_fix_ui.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors, World, Client  # noqa: E402
from _azero_bot import BOT  # noqa: E402

# Alice (the challenger) is an unattended player driven by this bot; Bob keeps the real UI.
PVP_BOT = r"""
local G = ns.Azero
T_PVP = { answer = 1 }
function T_PVP.tick()
  local p = G.pending
  if not p then return end
  if p.kind == "text" then G:Advance()
  elseif p.kind == "choice" then G:Advance(T_PVP.answer)
  elseif p.kind == "battle" then
    local b = p.battle
    while b:Pop() do end
    if b.need == "action" then
      if not b:Act({ kind = "move", idx = T_AZ.bestMove(b) }) then b:Act({ kind = "move", idx = 1 }) end
    elseif b.need == "done" then
      G:Advance(b.result)
    end
  elseif p.kind == "wait" or p.kind == "evolve" then G:Update(0.5) end
end
"""


def state(c):
    return c.eval_py("return ns.AzeroUI._State()")


def items(c):
    return c.eval_py("return ns.AzeroUI._MenuItems()") or []


def key(w, c, *keys):
    for k in keys:
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.05)


def dismiss(w, c):
    """Space until the message is gone (the first press finishes the text, the next closes it)."""
    for _ in range(6):
        if not state(c)["msg"]:
            return
        key(w, c, "A")
        w.tick(0.1)
    raise AssertionError("the message did not close: %r" % state(c))


# ---------------------------------------------------------------- single player

def game(seed=4):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    c.eval("ns.Azero:NewGame()")
    c.eval("local M = ns.AzeroMon ns.Azero.save.party = { M.New('murkling', 30, ns.Azero.rng) }")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")                    # title: CONTINUE
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    return w, c


def to_action(w, c):
    for _ in range(80):                                     # play the intro until the action menu is up
        w.tick(0.2)
        if c.eval("return ns.Azero.battle and ns.Azero.battle.need") == "action" and state(c)["stack"] >= 1:
            return
        c.eval("ns.AzeroUI._HandleKey('A')")
    raise AssertionError("no action menu: %r" % state(c))


def battle(foe="rustgolem"):
    w, c = game()
    c.eval("ns.Azero.save.bag = { net = 5, illusiondust = 1 }")
    c.eval("ns.Azero:Run(function(g) g:WildBattle(%r, 10) end)" % foe)
    to_action(w, c)
    return w, c


def open_bag_on_dust(w, c):
    """FIGHT/BAG/PARTY/RUN -> BAG, then Illusion Dust (a charm): "Now is not the time to use that!"."""
    key(w, c, "up", "left", "right", "A")                   # (the cursor to FIGHT, then) BAG
    assert items(c) == ["Taming Rod", "Illusion Dust"], items(c)
    key(w, c, "down", "A")
    t = c.eval_py("return ns.AzeroUI._TextOnTop()")
    assert state(c)["msg"] and t.get("text") == "Now is not the time to use that!", t


@case
def a_text_replacing_a_message_leaves_nothing_waiting():
    w, c = game()
    c.eval("ns.AzeroUI.Kit.Message('First.')")
    assert state(c)["msg"]
    c.eval("ns.AzeroUI.Kit.SetText('Something else.')")
    assert not state(c)["msg"], state(c)                    # the message gave way: keys work again
    c.eval("ns.AzeroUI.Kit.Message('Second.')")
    c.eval("ns.AzeroUI.Kit.ClearText()")
    s = state(c)
    assert not s["msg"] and s.get("text") is None, s
    # a second message waits for the first, then both `after`s run in order
    c.eval("T_FIX = {} local K = ns.AzeroUI.Kit "
           "K.Message('One.', function() T_FIX[#T_FIX + 1] = 1 end) "
           "K.Message('Two.', function() T_FIX[#T_FIX + 1] = 2 end)")
    assert c.eval_py("return ns.AzeroUI._TextOnTop()").get("text") == "One."
    for _ in range(4):                                      # (dismiss() would close both)
        if c.eval_py("return ns.AzeroUI._TextOnTop()").get("text") != "One.":
            break
        key(w, c, "A")
        w.tick(0.1)
    assert c.eval_py("return ns.AzeroUI._TextOnTop()").get("text") == "Two." and state(c)["msg"]
    dismiss(w, c)
    assert c.eval_py("return T_FIX") == [1, 2]
    key(w, c, "START")                                      # the overworld answers keys again
    assert state(c)["stack"] == 1
    no_errors(w)


@case
def clicking_a_bag_row_under_a_message_does_nothing():
    w, c = battle()
    open_bag_on_dust(w, c)
    # left-click the Taming Rod row while the message is up
    c.eval("""local K = ns.AzeroUI.Kit
      local m = K.stack[#K.stack]
      for _, row in ipairs(m.frame.rows) do
        if row:IsShown() and m.items[row.idx].item == 'net' then row:GetScript('OnClick')(row, 'LeftButton') end
      end""")
    w.tick(0.1)
    s = state(c)
    assert s["msg"] and s.get("text") == "Now is not the time to use that!", s
    assert c.eval("return ns.Azero.save.bag.net") == 5                       # nothing thrown
    assert c.eval("return ns.Azero.battle.need") == "action"
    dismiss(w, c)
    assert items(c) == ["Taming Rod", "Illusion Dust"], items(c)             # the bag is still open, usable
    key(w, c, "up", "A")                                                     # throw the rod by key
    for _ in range(80):
        if c.eval("return ns.Azero.save.bag.net") == 4 and state(c)["stack"] >= 1:
            break
        w.tick(0.2)
        c.eval("ns.AzeroUI._HandleKey('A')")
    assert c.eval("return ns.Azero.save.bag.net") == 4
    no_errors(w)


@case
def clicking_the_battle_text_box_never_picks_from_the_menu():
    w, c = battle()
    key(w, c, "down", "right")                              # the cursor on RUN
    c.eval("local tb = ns.AzeroUI.Kit.R.textbox tb:GetScript('OnMouseDown')(tb, 'LeftButton')")
    w.tick(0.5)
    assert c.eval("return ns.Azero.battle ~= nil and ns.Azero.battle.need") == "action"
    assert state(c)["battle"] and items(c) == ["FIGHT", "BAG", "PARTY", "RUN"], (state(c), items(c))
    # with a message up, the click answers it
    open_bag_on_dust(w, c)
    for _ in range(3):
        c.eval("local tb = ns.AzeroUI.Kit.R.textbox tb:GetScript('OnMouseDown')(tb, 'LeftButton')")
        w.tick(0.1)
    assert not state(c)["msg"] and items(c) == ["Taming Rod", "Illusion Dust"], (state(c), items(c))
    no_errors(w)


@case
def the_prompt_comes_back_after_a_message():
    w, c = battle()
    prompt = state(c).get("text")
    assert prompt.startswith("What will"), prompt
    open_bag_on_dust(w, c)
    dismiss(w, c)
    key(w, c, "B")                                          # close the bag: FIGHT / BAG / PARTY / RUN on top
    w.tick(0.1)
    assert state(c).get("text") == prompt, state(c)
    # the same after a message straight from the action menu (no PP left: the move list, then back)
    c.eval("for _, mv in ipairs(ns.Azero.battle.ally.mon.moves) do mv.pp = 0 end")
    key(w, c, "left", "A")                                  # FIGHT: "has no moves left!" then it struggles
    assert state(c)["msg"]
    dismiss(w, c)
    to_action(w, c)
    assert (state(c).get("text") or "").startswith("What will"), state(c)
    no_errors(w)


@case
def the_net_is_not_grey_in_the_next_battle():
    w, c = game()
    c.eval("ns.AzeroUI.Kit.R.net:SetVertexColor(0.6, 0.6, 0.6)")     # how a catch leaves it
    c.eval("ns.Azero:Run(function(g) g:WildBattle('rustgolem', 10) end)")
    w.tick(0.1)
    col = c.eval_py("return ns.AzeroUI._NetColor()")
    assert state(c)["battle"] and col[:3] == [1, 1, 1], col
    no_errors(w)


@case
def esc_pauses_the_game():
    w, c = game()
    root = "local r = ns.AzeroUI._Root() "
    c.eval(root + "r:GetScript('OnKeyDown')(r, 'ESCAPE')")
    assert state(c)["paused"] and c.eval("return ns.AzeroUI._PauseNote()") == ""
    c.eval("ns.Azero:Run(function(g) g:Sleep(0.5) g:Say('Done waiting.') end)")
    w.tick(3)
    assert c.eval("return ns.Azero.pending.kind") == "wait"                  # script timers wait
    c.eval("ns.AzeroUI._Focus(true)")                                        # the click to play
    assert not state(c)["paused"]
    w.tick(1)
    assert c.eval("return ns.Azero.pending.kind") == "text"
    key(w, c, "A", "A")
    w.tick(0.2)
    # a wild battle does not play while paused
    c.eval("ns.Azero:Run(function(g) g:WildBattle('rustgolem', 10) end)")
    w.tick(0.1)
    c.eval(root + "r:GetScript('OnKeyDown')(r, 'ESCAPE')")
    n = c.eval("return #ns.Azero.battle.events")
    t = state(c).get("text")
    assert n > 0, n
    w.tick(4)
    assert c.eval("return #ns.Azero.battle.events") == n and state(c).get("text") == t and state(c)["stack"] == 0
    c.eval("ns.AzeroUI._Focus(true)")
    to_action(w, c)
    no_errors(w)


# ---------------------------------------------------------------- two players (Bob has the UI)

def setup_pvp():
    w = World()
    a, b = Client(w, "Alice", guild_rank=3), Client(w, "Bob", guild_rank=3)
    for c in (a, b):
        c.load_addon()
    w.tick(3)
    for c, x in ((a, 8), (b, 9)):
        c.eval(BOT)
        c.eval(PVP_BOT)
        c.slash("/dz play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        for _ in range(40):
            w.tick(0.3)
            c.eval("ns.AzeroUI._HandleKey('A')")
            if not c.eval("return ns.Azero.pending ~= nil"):
                break
        if c is a:
            c.eval("ns.AzeroUI._Detach()")
        c.eval("local G, M = ns.Azero, ns.AzeroMon; G:EnterMap('town', %d, 9, %r, true); "
               "G.save.party = { M.New(%r, 12, G.rng) }; G.save.bag = { potion = 2 }"
               % (x, "right" if x == 8 else "left", "murkling" if x == 8 else "emberwhelp"))
    run(w, a, seconds=2)
    return w, a, b


def run(w, a, seconds=1.5, step=0.3):
    """Alice's bot and network each step; Bob's UI runs itself (OnUpdate)."""
    for _ in range(int(seconds / step)):
        a.eval("T_PVP.tick()")
        a.eval("ns.AzeroNet:Update(0.3); ns.AzeroPvP:Update()")
        w.tick(step)


def challenge(w, a):
    a.eval("ns.Azero:PressA()")                             # facing Bob: Battle or Trade
    assert "Challenge Bob" in (a.eval("return ns.Azero.pending and ns.Azero.pending.text") or "")
    a.eval("ns.Azero:Advance(1)")                           # Battle -> waiting for Bob


def bob_to_action(w, a, b):
    for _ in range(120):
        run(w, a, seconds=0.3)
        if b.eval("return ns.Azero.battle and ns.Azero.battle.need") == "action" and state(b)["stack"] >= 1:
            return
        if not state(b)["stack"]:
            b.eval("ns.AzeroUI._HandleKey('A')")
    raise AssertionError("Bob never got to choose: %r" % state(b))


def finish(w, a, b):
    """Bob reads everything to the end of the match."""
    for _ in range(200):
        run(w, a, seconds=0.3)
        if not state(b)["battle"] and b.eval("return ns.Azero.pending == nil"):
            return
        b.eval("ns.AzeroUI._HandleKey('A')")
    raise AssertionError("the match never ended for Bob: %r" % state(b))


@case
def a_challenge_waits_for_the_message_and_closes_the_start_menu():
    w, a, b = setup_pvp()
    key(w, b, "START")
    assert state(b)["stack"] == 1
    b.eval("ns.AzeroUI.Kit.Message('Hello there.')")
    challenge(w, a)
    run(w, a, seconds=1.5)
    assert b.eval("return ns.Azero.pending and ns.Azero.pending.kind") == "choice"
    s = state(b)
    assert s["msg"] and s.get("text") == "Hello there." and s["stack"] == 1, s   # the message stays up, keys work on it
    dismiss(w, b)
    w.tick(0.1)
    s = state(b)
    assert s["stack"] == 1 and items(b) == ["Yes", "No"], (s, items(b))     # the start menu went, the prompt is on top
    assert (s.get("text") or "").startswith("Alice challenges you"), s
    assert not b.eval("return ns.AzeroUI.Kit.R.money:IsShown()")
    key(w, b, "A")                                          # Yes
    bob_to_action(w, a, b)
    assert items(b) == ["FIGHT", "BAG", "PARTY", "RUN"], items(b)
    finish(w, a, b)
    no_errors(w)


@case
def accepting_over_the_bag_starts_a_clean_battle():
    w, a, b = setup_pvp()
    key(w, b, "START", "down", "down", "A")                 # BAG
    assert state(b)["stack"] == 2
    challenge(w, a)
    run(w, a, seconds=1.5)
    assert state(b)["stack"] == 1 and items(b) == ["Yes", "No"], (state(b), items(b))
    key(w, b, "A")
    run(w, a, seconds=0.6)
    assert state(b)["battle"] and state(b)["stack"] == 0, state(b)          # nothing from the overworld left
    bob_to_action(w, a, b)
    assert state(b)["stack"] == 1 and items(b) == ["FIGHT", "BAG", "PARTY", "RUN"], (state(b), items(b))
    finish(w, a, b)
    no_errors(w)


@case
def a_turn_that_runs_out_closes_the_battle_menus():
    w, a, b = setup_pvp()
    challenge(w, a)
    run(w, a, seconds=1.5)
    key(w, b, "A")                                          # Yes
    bob_to_action(w, a, b)
    key(w, b, "A")                                          # FIGHT: the move list is open
    assert state(b)["stack"] == 2
    b.eval("ns.AzeroPvP.TURN_TIMEOUT = -1 ns.AzeroPvP:Update() ns.AzeroPvP.TURN_TIMEOUT = 60")   # ran out: forfeit
    assert b.eval("return ns.Azero.battle.need") != "action"
    c_key = "ns.AzeroUI._HandleKey('A')"                    # a move picked right then is refused
    b.eval(c_key)
    s = state(b)
    assert not s["msg"] and s["stack"] == 0, s
    w.tick(0.1)
    finish(w, a, b)
    assert b.eval_py("return ns.Games:GetData('azeromon').pvp")              # the result was recorded
    no_errors(w)


@case
def a_turn_that_runs_out_mid_playback_never_freezes():
    w, a, b = setup_pvp()
    challenge(w, a)
    run(w, a, seconds=1.5)
    key(w, b, "A")
    bob_to_action(w, a, b)
    key(w, b, "right", "A")                                 # BAG: items can't be used against players (a message)
    assert state(b)["msg"]
    b.eval("ns.AzeroPvP.TURN_TIMEOUT = -1")
    w.tick(0.1)                                             # the forfeit happens under the message
    b.eval("ns.AzeroPvP.TURN_TIMEOUT = 60")
    assert b.eval("return ns.Azero.battle.need") != "action"
    assert state(b)["stack"] == 0, state(b)                 # the battle menus closed by themselves
    finish(w, a, b)
    no_errors(w)


@case
def a_paused_match_keeps_going_and_says_so():
    w, a, b = setup_pvp()
    challenge(w, a)
    run(w, a, seconds=1.5)
    key(w, b, "A")
    bob_to_action(w, a, b)
    b.eval("local r = ns.AzeroUI._Root() r:GetScript('OnKeyDown')(r, 'ESCAPE')")
    assert state(b)["paused"]
    assert b.eval("return ns.AzeroUI._PauseNote()") == "Your turn timer keeps running."
    b.eval("ns.AzeroPvP.TURN_TIMEOUT = -1")
    run(w, a, seconds=0.3)
    b.eval("ns.AzeroPvP.TURN_TIMEOUT = 60")
    assert b.eval("return ns.Azero.battle and ns.Azero.battle.need") != "action"   # the clock ran while paused
    assert state(b)["stack"] == 0
    for _ in range(40):                                     # the playback goes on while paused too
        run(w, a, seconds=0.3)
        if not state(b)["battle"]:
            break
    assert not state(b)["battle"], state(b)
    b.eval("ns.AzeroUI._Focus(true)")
    finish(w, a, b)
    no_errors(w)


if __name__ == "__main__":
    run_all()

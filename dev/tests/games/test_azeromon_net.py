"""Azeromon multiplayer, step 1: seeing guildmates in the world.

Covers: two guild clients with the game open see each other on the same map and replay each other's steps,
presence traffic goes over GUILD on the separate game prefix (CDLg) at most about once a second, nothing is sent
with the game closed or in combat, closing the game tells the others (AZL), a malformed or wrong-version update
is ignored, peers on another map are not drawn, and pressing A on a peer does not error.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_net.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, no_errors, World, Client  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def open_game(c, w, x, y, map_id="town"):
    """Opens the Games tab on Azeromon, starts a new game and places the player."""
    c.eval(BOT)
    c.eval("T_AZ.seed(5)")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")        # NEW GAME
    for _ in range(40):
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        if not c.eval("return ns.Azero.pending ~= nil"):
            break
    c.eval("ns.Azero:EnterMap(%r, %d, %d, 'down', true)" % (map_id, x, y))


def two_players():
    w = World()
    a = Client(w, "Alice", guild_rank=3)
    b = Client(w, "Bob", guild_rank=3)
    for c in (a, b):
        c.load_addon()
    w.tick(3)
    open_game(a, w, 8, 9)
    open_game(b, w, 12, 12)
    w.tick(2)
    return w, a, b


def peer(c, name, map_id="town"):
    return c.eval_py("""for _, p in ipairs(ns.AzeroNet:PeersOn(%r)) do
        if p.name == %r then return { x = p.x, y = p.y, face = p.face, q = #p.queue } end end""" % (map_id, name))


def game_msgs(w, since=0, sender=None):
    return [e for e in w.addon_log[since:] if e["prefix"] == "CDLg" and (sender is None or e["sender"].startswith(sender))]


@case
def guildmates_see_each_other_and_replay_steps():
    w, a, b = two_players()
    assert peer(b, "Alice") == {"x": 8, "y": 9, "face": "down", "q": 0}, peer(b, "Alice")
    # the sender's class travels with it (class-coloured names); regression: "UnitClass and UnitClass()" lost it
    assert b.eval("for _, p in ipairs(ns.AzeroNet:PeersOn('town')) do if p.name == 'Alice' then return p.class end end")         == "PALADIN"
    assert peer(a, "Bob")["x"] == 12
    # Alice walks right three tiles and down one
    for d in ("right", "right", "right", "down"):
        a.eval("T_AZ.step(%r)" % d)
    w.tick(3)
    assert a.eval_py("return { ns.Azero.save.x, ns.Azero.save.y }") == [11, 10]
    assert peer(b, "Alice") == {"x": 11, "y": 10, "face": "down", "q": 0}, peer(b, "Alice")
    no_errors(w)


@case
def presence_uses_the_game_prefix_over_guild_and_is_rate_limited():
    w, a, b = two_players()
    n0 = len(w.addon_log)
    # walk back and forth for 10 seconds (one step every 0.25 s)
    for i in range(40):
        a.eval("T_AZ.step(%r)" % ("right" if (i // 4) % 2 == 0 else "left"))
        w.tick(0.05)
    msgs = game_msgs(w, n0, "Alice")
    assert msgs, "Alice sent nothing"
    assert all(e["chat_type"] == "GUILD" for e in msgs), msgs[:2]
    assert len(msgs) <= 14, len(msgs)
    # standing still: only a heartbeat every 10 s
    n1 = len(w.addon_log)
    w.tick(21)
    assert 1 <= len(game_msgs(w, n1, "Alice")) <= 3
    no_errors(w)


@case
def closing_the_game_or_combat_stops_presence():
    w, a, b = two_players()
    assert peer(b, "Alice")
    a.set_combat(True)
    w.tick(0.5)
    n0 = len(w.addon_log)
    a.eval("T_AZ.step('right')")    # the game releases the keyboard in combat, but a step must not be sent
    w.tick(5)
    assert game_msgs(w, n0, "Alice") == []
    a.set_combat(False)
    w.tick(2)
    # close the DisasterZone window: Alice says goodbye and disappears for Bob
    a.slash("/dz")
    w.tick(1)
    assert a.eval("return ns.AzeroNet:IsActive()") is False
    assert peer(b, "Alice") is None
    n1 = len(w.addon_log)
    w.tick(15)
    assert game_msgs(w, n1, "Alice") == []
    no_errors(w)


@case
def bad_updates_are_ignored_and_peers_time_out():
    w, a, b = two_players()
    b.eval("ns.AzeroNet._Reset()")
    for bad in ("{ t = 'AZP', v = 1, m = 'nowhere', x = 1, y = 1, f = 'up', p = '' }",
                "{ t = 'AZP', v = 1, m = 'town', x = 999, y = 1, f = 'up', p = '' }",
                "{ t = 'AZP', v = 1, m = 'town', x = 3, y = 3, f = 'sideways', p = '' }",
                "{ t = 'AZP', v = 1, m = 'town', x = 3, y = 3, f = 'up', p = 'UUXX' }",
                "{ t = 'AZP', v = 99, m = 'town', x = 3, y = 3, f = 'up', p = '' }"):
        a.eval("ns.Comm:Send(%s, 'GUILD', nil, 'game')" % bad)
    w.tick(0.5)
    assert b.eval("return ns.AzeroNet:Count()") == 0
    # a peer that goes silent (crash / disconnect) disappears
    a.eval("ns.AzeroNet:SetActive(false)")
    a.eval("ns.AzeroNet.SetActive = function() end")     # keep Alice silent
    b.eval("ns.AzeroNet._Reset()")
    a.eval("ns.Comm:Send({ t = 'AZP', v = 1, m = 'town', x = 3, y = 3, f = 'up', p = '' }, 'GUILD', nil, 'game')")
    w.tick(1)
    assert peer(b, "Alice") is not None
    w.tick(30)
    assert peer(b, "Alice") is None
    no_errors(w)


@case
def peers_on_other_maps_are_not_drawn_and_talking_to_one_works():
    w, a, b = two_players()
    # Bob stands right of Alice, facing her
    b.eval("ns.Azero:EnterMap('town', 9, 9, 'left', true)")
    w.tick(2)
    assert peer(b, "Alice")["x"] == 8
    b.eval("ns.Azero:PressA()")
    assert "Challenge Alice" in (b.eval("return ns.Azero.pending and ns.Azero.pending.text") or "")
    b.eval("ns.Azero:Advance(2)")          # No
    # Alice goes into her house: Bob no longer sees her in town
    a.eval("ns.Azero:EnterMap('home', 4, 6, 'up')")
    w.tick(2)
    assert peer(b, "Alice") is None and peer(b, "Alice", "home") is not None
    no_errors(w)


@case
def the_hub_shows_how_many_are_playing_now():
    w, a, b = two_players()
    status = lambda c: c.eval("return ns.Games:Get('azeromon').status()")
    assert "2 playing now" in status(a) and "2 playing now" in status(b), (status(a), status(b))
    # Bob closes the game (the panel's loop stops, he says goodbye): Alice counts herself only
    b.eval("ns.AzeroUI._Detach() ns.AzeroNet:SetActive(false)")
    w.tick(2)
    assert "1 playing now" in status(a), status(a)
    # Bob is back; Alice closes hers: she still sees Bob, heard just now
    b.eval("ns.AzeroNet:SetActive(true) ns.AzeroNet:Update(0.1)")
    w.tick(2)
    a.eval("ns.AzeroUI._Detach() ns.AzeroNet:SetActive(false)")
    w.tick(1)
    assert "1 playing now" in status(a), status(a)
    # Bob goes quiet without a goodbye (a disconnect): he drops out after the timeout, Alice's game closed or not
    w.tick(30)
    assert "No one playing right now" in status(a), status(a)
    no_errors(w)


if __name__ == "__main__":
    run_all()

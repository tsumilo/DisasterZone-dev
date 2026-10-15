"""Azeromon guild chat (Chat.lua, 0.29).

Covers: Enter opens the chat line in the world (Tab still opens the menu; Enter in a menu is still START); a line
shows as a bubble over the speaker on both screens and in both logs, and over GUILD on CDLg as AZK; a guildmate
on another map gets it in the log with [Place] and no bubble; emotes play on the character for the other client
and /sit lasts until walking; escape codes are stripped and long lines cut; sending too fast and floods are held
back; "Guild chat" off hides others' lines; "Chat bubbles" off keeps the log; Esc closes the line without sending.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_chat.py [-k name]
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
    """Opens the Games tab on Azeromon, starts a new game and places the player (as test_azeromon_net.py)."""
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


def two_players(b_map="town", b_xy=(10, 10)):
    w = World()
    a = Client(w, "Alice", guild_rank=3)
    b = Client(w, "Bob", guild_rank=3)
    for c in (a, b):
        c.load_addon()
    w.tick(3)
    open_game(a, w, 8, 10)
    open_game(b, w, b_xy[0], b_xy[1], b_map)
    for c in (a, b):
        c.eval("ns.AzeroUI.tipsOff = true ns.AzeroChat._Reset()")
    w.tick(2)
    return w, a, b


def say(w, c, text):
    """Enter, type, Enter."""
    c.eval("ns.AzeroUI._HandleKey('CHAT')")
    assert c.eval("return ns.AzeroUI._ChatBox():IsShown()") is True
    c.eval("local eb = ns.AzeroUI._ChatBox().eb eb:SetText(%r) eb:GetScript('OnEnterPressed')(eb)" % text)
    w.tick(0.6)


def log(c):
    c.eval("ns.AzeroUI._DrawChat()")
    return c.eval_py("return ns.AzeroUI._ChatLog()") or []


@case
def a_line_shows_as_a_bubble_and_in_both_logs():
    w, a, b = two_players()
    n0 = len(w.addon_log)
    say(w, a, "anyone up for the Deadmines?")
    assert a.eval("return ns.AzeroUI._ChatBox():IsShown()") is False
    msgs = [e for e in w.addon_log[n0:] if e["prefix"] == "CDLg" and e["sender"].startswith("Alice")]
    assert msgs and all(e["chat_type"] == "GUILD" for e in msgs), msgs
    assert a.eval("return ns.AzeroUI._Bubble('me')") == "anyone up for the Deadmines?"
    assert b.eval("return ns.AzeroUI._Bubble('Alice')") == "anyone up for the Deadmines?"
    la, lb = log(a), log(b)
    assert any("Alice" in l and "Deadmines" in l for l in la), la
    assert any("Alice" in l and "Deadmines" in l and "[" not in l for l in lb), lb
    no_errors(w)


@case
def another_map_gets_the_line_with_the_place_and_no_bubble():
    w, a, b = two_players(b_map="route1", b_xy=(10, 10))
    say(w, a, "hello from town")
    lb = log(b)
    assert any("[Goldshire]" in l and "hello from town" in l for l in lb), lb
    assert b.eval("return next(ns.AzeroChat._Said())") is None
    no_errors(w)


@case
def enter_chats_in_the_world_and_tab_opens_the_menu():
    w, a, b = two_players()
    a.eval("ns.AzeroUI._HandleKey('START')")
    w.tick(0.3)
    assert a.eval("return #ns.AzeroUI._Levels() > 0") is True
    assert a.eval("return ns.AzeroUI._ChatBox():IsShown()") is False
    a.eval("ns.AzeroUI._HandleKey('CHAT')")                 # in a menu Enter is still START: no chat line
    assert a.eval("return ns.AzeroUI._ChatBox():IsShown()") is False
    a.eval("ns.AzeroUI._HandleKey('B') ns.AzeroUI._HandleKey('B')")
    w.tick(0.3)
    a.eval("ns.AzeroUI._HandleKey('CHAT')")
    assert a.eval("return ns.AzeroUI._ChatBox():IsShown()") is True
    a.eval("local eb = ns.AzeroUI._ChatBox().eb eb:SetText('never mind') eb:GetScript('OnEscapePressed')(eb)")
    w.tick(0.6)
    assert a.eval("return ns.AzeroUI._ChatBox():IsShown()") is False
    assert not any("never mind" in l for l in log(b))
    no_errors(w)


@case
def emotes_play_for_the_other_client_and_sit_lasts_until_walking():
    w, a, b = two_players()
    say(w, a, "/wave")
    assert b.eval("return (ns.AzeroChat:Emote(ns.AzeroUI._PeerKey('Alice')))") == "wave"
    assert b.eval("return ns.AzeroUI._Bubble('Alice')") == "*waves*"
    w.tick(1.5)
    say(w, a, "/sit")
    w.tick(5)
    assert b.eval("return (ns.AzeroChat:Emote(ns.AzeroUI._PeerKey('Alice')))") == "sit"
    assert a.eval("return (ns.AzeroChat:Emote('me'))") == "sit"
    a.eval("T_AZ.step('right')")
    w.tick(3)
    assert a.eval("return (ns.AzeroChat:Emote('me'))") is None
    assert b.eval("return (ns.AzeroChat:Emote(ns.AzeroUI._PeerKey('Alice')))") is None
    say(w, a, "/flex")                                     # not an emote: the list, sent to nobody
    assert any("/wave" in l for l in log(a)), log(a)
    no_errors(w)


@case
def text_is_cleaned_and_cut():
    w, a, b = two_players()
    r = a.eval_py("""local C = ns.AzeroChat
      return { C.Clean('|cffff0000red|r |TInterface\\\\Icons\\\\X:0|t hi'), #C.Clean(string.rep('a', 300)),
               C.Clean('   '), C.Clean('a\\nb') }""")
    assert r[0] == "/cffff0000red/r /TInterface\\Icons\\X:0/t hi", r
    assert r[1] == 120 and r[2] is None and r[3] == "a b", r
    # someone else's escape codes never reach the log as codes
    b.eval("ns.AzeroChat._OnChat('Mallet-Realm', { v = 1, m = 'town', x = '|Hitem:1|h[Free]|h' })")
    lb = log(b)
    assert any("/Hitem:1/h[Free]/h" in l for l in lb), lb
    no_errors(w)


@case
def too_fast_and_floods_are_held_back():
    w, a, b = two_players()
    r = a.eval_py("return { ns.AzeroChat:Say('one') } ")
    r2 = a.eval_py("return { ns.AzeroChat:Say('two') } ")
    assert r == [True] and r2 == [False, "fast"], (r, r2)
    shown = b.eval("""ns.AzeroChat._Reset()
      for i = 1, 9 do ns.AzeroChat._OnChat('Spam-Realm', { v = 1, m = 'town', x = 'spam ' .. i }) end
      return #ns.AzeroChat:Log()""")
    assert shown == 5, shown
    no_errors(w)


@case
def chat_off_hides_lines_and_bubbles_off_keeps_the_log():
    w, a, b = two_players()
    b.eval("ns.Azero:Data().chatBubbles = false")
    say(w, a, "first")
    assert b.eval("return ns.AzeroUI._Bubble('Alice')") is None
    assert any("first" in l for l in log(b))
    b.eval("ns.Azero:Data().chatBubbles = nil ns.Azero:Data().chat = false")
    w.tick(1.5)
    say(w, a, "second")
    assert not any("second" in l for l in log(b))
    b.eval("ns.AzeroUI._HandleKey('CHAT')")
    assert b.eval("return ns.AzeroUI._ChatBox():IsShown()") is False
    no_errors(w)


if __name__ == "__main__":
    run_all()

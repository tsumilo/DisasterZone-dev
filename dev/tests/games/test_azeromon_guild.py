"""Azeromon step 3: the guild Bestiary and leaderboard.

Covers: summaries reach guildmates over GUILD on the game prefix, throttled (one per 10 s however much happens) and
refreshed; opening the guild pages asks the guild, and players who have played answer from saved data even with the
game closed (never-players stay silent); rankings per category with shared ranks; the Guild Bestiary (who tamed
what); malformed or wrong-version summaries are ignored or clamped; "first to complete the Bestiary" with its
achievements; the board survives a relog; and the GUILD pages in the start menu.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_guild.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, no_errors, World, Client  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def open_game(c, w):
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")        # NEW GAME / CONTINUE
    for _ in range(40):
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        if not c.eval("return ns.Azero.pending ~= nil"):
            break


def guild(names=("Alice", "Bob", "Carol", "Dave")):
    w = World()
    cs = {n: Client(w, n, guild_rank=3) for n in names}
    for c in cs.values():
        c.load_addon()
    w.tick(3)
    for c in cs.values():
        c.eval(BOT)
        c.eval("T_AZ.seed(3)")
    return w, cs


def tame(c, *species):
    for sp in species:
        c.eval("ns.Azero:AddMon(ns.AzeroMon.New(%r, 5, ns.Azero.rng), 'caught')" % sp)


def entry(c, name):
    return c.eval_py("for k, e in pairs(ns.AzeroGuild:Entries()) do if e.name == %r then "
                     "local t = {} for id in pairs(e.caught or {}) do t[#t+1] = id end table.sort(t) "
                     "return { n = e.n, b = e.b, ap = e.ap, caught = t, me = e.me } end end" % name)


def azs(w, since, sender):
    return [e for e in w.addon_log[since:] if e["prefix"] == "CDLg" and e["sender"].startswith(sender)
            and e["chat_type"] == "GUILD"]


@case
def summaries_reach_guildmates_throttled():
    w, cs = guild(("Alice", "Bob"))
    a, b = cs["Alice"], cs["Bob"]
    open_game(a, w)
    open_game(b, w)
    w.tick(1)
    tame(a, "owlet", "wolfpup")
    w.tick(11)
    e = entry(b, "Alice")
    assert e and e["n"] == 2 and e["caught"] == ["owlet", "wolfpup"], e
    # a burst of activity: still at most one summary per 10 s
    a.eval("""T_AZS = 0
      local real = ns.Comm.Send
      ns.Comm.Send = function(self, msg, ...)
        if type(msg) == 'table' and msg.t == 'AZS' then T_AZS = T_AZS + 1 end
        return real(self, msg, ...)
      end""")
    for sp in ("kobling", "webling", "tuskling", "coyote", "fleshripper"):
        tame(a, sp)
        w.tick(1)
    w.tick(10)                                             # 15 s in all
    assert entry(b, "Alice")["n"] == 7
    assert 1 <= a.eval("return T_AZS") <= 2, a.eval("return T_AZS")
    no_errors(w)


@case
def queries_are_answered_from_saved_data_even_with_the_game_closed():
    w, cs = guild()
    a, b, carol = cs["Alice"], cs["Bob"], cs["Carol"]
    # Carol played earlier: a save exists, but her game window is closed now
    carol.eval("ns.Azero:NewGame()")
    tame(carol, "owlet", "kobling", "coyote")
    carol.eval("ns.AzeroNet:SetActive(false)")
    open_game(b, w)
    w.tick(1)
    n0 = len(w.addon_log)
    assert b.eval("return ns.AzeroGuild:Query()") is True
    assert b.eval("return ns.AzeroGuild:Query()") is False   # at most every 30 s
    w.tick(5)
    assert entry(b, "Carol")["n"] == 3
    assert entry(b, "Dave") is None                            # never played: stays silent
    assert not [x for x in w.addon_log[n0:] if x["sender"].startswith("Dave") and x["prefix"] == "CDLg"]
    no_errors(w)


@case
def rankings_and_the_guild_bestiary():
    w, cs = guild(("Alice", "Bob", "Carol"))
    a, b, carol = cs["Alice"], cs["Bob"], cs["Carol"]
    for c in (a, carol):
        c.eval("ns.Azero:NewGame()")
    tame(a, "owlet", "kobling", "coyote")
    tame(carol, "owlet", "kobling", "coyote")
    open_game(b, w)
    tame(b, "owlet")
    b.eval("ns.AzeroGuild:Query()")
    w.tick(5)
    rows = b.eval_py("local t = {} for _, r in ipairs(ns.AzeroGuild:Ranking('tamed')) do "
                     "t[#t+1] = { r.rank, r.entry.name, r.text } end return t")
    assert rows == [[1, "Alice", "3 tamed"], [1, "Carol", "3 tamed"], [3, "Bob", "1 tamed"]], rows
    beast = b.eval_py("for _, r in ipairs(ns.AzeroGuild:GuildBestiary()) do if r.id == 'owlet' then return r.names end end")
    assert beast == ["Alice", "Bob (you)", "Carol"], beast
    coyote = b.eval_py("for _, r in ipairs(ns.AzeroGuild:GuildBestiary()) do if r.id == 'coyote' then return r.count end end")
    assert coyote == 2
    no_errors(w)


@case
def bad_summaries_are_ignored_or_clamped():
    w, cs = guild(("Alice", "Bob"))
    a, b = cs["Alice"], cs["Bob"]
    b.eval("ns.Azero:NewGame()")
    for msg in ("{ t = 'AZS', v = 99, n = 5 }",
                "{ t = 'AZS', v = 1, c = { 1, 2, 999, 'x', 2 }, b = 1e9, w = -5, ap = 'lots', done = -1 }"):
        a.eval("ns.Comm:Send(%s, 'GUILD', nil, 'game')" % msg)
        w.tick(0.5)
    e = b.eval_py("for k, e in pairs(ns.Azero:Data().guild or {}) do if e.name == 'Alice' then return e end end")
    assert e["n"] == 2 and e["b"] == 0 and e["w"] == 0 and e["ap"] == 0 and e.get("done") is None, e
    no_errors(w)


@case
def first_to_complete_the_bestiary():
    w, cs = guild(("Alice", "Bob"))
    a, b = cs["Alice"], cs["Bob"]
    ids = a.eval_py("return ns.AzeroGuild.CompletableIds()")
    open_game(a, w)
    open_game(b, w)
    tame(a, *ids)
    w.tick(11)
    got_a = a.eval_py("local t = {} for id in pairs(ns.AzeroAch.Earned()) do t[#t+1] = id end return t")
    assert "bestiary" in got_a and "guildfirst" in got_a, got_a
    tame(b, *ids)
    got_b = b.eval_py("local t = {} for id in pairs(ns.AzeroAch.Earned()) do t[#t+1] = id end return t")
    assert "bestiary" in got_b and "guildfirst" not in got_b, got_b     # Alice was first, and Bob knows it
    first = b.eval_py("local f = ns.AzeroGuild:FirstComplete() return f and f.name")
    assert first == "Alice"
    # rares are not needed for the Bestiary
    assert not [i for i in ids if b.eval("return ns.AzeroData.species[%r].rare" % i)]
    no_errors(w)


@case
def the_board_survives_a_relog_and_opens_from_the_start_menu():
    w, cs = guild(("Alice", "Bob"))
    a, b = cs["Alice"], cs["Bob"]
    a.eval("ns.Azero:NewGame()")
    tame(a, "owlet", "kobling")
    open_game(b, w)
    b.eval("ns.AzeroGuild:Query()")
    w.tick(5)
    assert entry(b, "Alice")["n"] == 2
    b.relog()
    w.tick(3)
    b.eval(BOT)
    assert entry(b, "Alice")["n"] == 2                          # kept in SavedVariables
    open_game(b, w)
    b.eval("T_AZ.settle()")
    b.eval("ns.AzeroUI._HandleKey('START')")
    w.tick(0.1)
    for k in ("down", "down", "down", "down", "down", "A", "A"):  # ... GUILD, then "Most beasts tamed"
        b.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.05)
    titles = [l["title"] for l in b.eval_py("return ns.AzeroUI._Levels()")]
    assert "GUILD" in titles and "MOST BEASTS TAMED" in titles, titles
    no_errors(w)


if __name__ == "__main__":
    run_all()

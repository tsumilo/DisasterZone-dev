"""Azeromon: people remember you (People.lua, 0.34).

Covers: Billy's words follow your badges (rod at 1, Gurgles at 3) and at 6 he challenges you to a friendly battle
(his team just under yours, Gurgles first; win: he's beaten for good, lose: no blackout, healed); Bard Willem plays
the Lion's Pride in the evening and sings a ballad built from your save (first beast, badges in order, first shiny,
best catch); people greet you by name once a day for what they've noticed (Brog your usual buy, Lee Brown your best
fish, Maybell your badges); Gurgles draws by Billy's bobber.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_people.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

T0 = 1790000000
BADGES = ["hogger", "vancleef", "nightwatch", "nesingwary", "blackwater", "stonewatch", "darkiron"]


def game(badges=0, hour=12):
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame() ns.Azero.started = true ns.Azero.clockHour = %r ns.AzeroPeople.clock = %d" % (hour, T0))
    c.eval("ns.Azero.save.party = { ns.AzeroMon.New('murkling', 30, ns.Azero.rng) } ns.Azero.save.party[1].evoStop = 999")
    for b in BADGES[:badges]:
        c.eval("ns.Azero:SetFlag('badge_%s')" % b)
    return w, c


def texts(c, limit=12):
    out = []
    for _ in range(limit):
        p = c.eval_py("local p = ns.Azero.pending return p and { p.kind, p.text }")
        if not p or p[0] != "text":
            break
        out.append(p[1])
        c.eval("ns.Azero:Advance()")
    return out


def talk(c, nid):
    """talks to an NPC of the current map the way PressA does (greeting, gossip, script)"""
    c.eval("""for _, n in ipairs(ns.Azero.npcs) do if n.id == %r then
        ns.Azero.save.x, ns.Azero.save.y, ns.Azero.save.face = n.x, n.y + 1, 'up'
        if ns.Azero.map.solid[ns.Azero.map.key(n.x, n.y + 1)] then ns.Azero.save.x, ns.Azero.save.y, ns.Azero.save.face = n.x - 1, n.y, 'right' end
        ns.Azero:PressA() end end""" % nid)
    return texts(c)


@case
def billy_grows_with_your_badges():
    for n, bit in ((0, "dragon whelp"), (1, "Ma got me a rod"), (3, "This is Gurgles"), (5, "This is Gurgles")):
        w, c = game(badges=n)
        assert c.eval("return ns.AzeroPeople.BillyStage()") == (0 if n == 0 else 1 if n < 3 else 2)
        c.eval("ns.Azero:Run(function(g) ns.AzeroPeople.BillyTalk(g) end)")
        assert any(bit in t for t in texts(c)), (n, bit)
        no_errors(w)


@case
def at_six_badges_billy_battles_you_and_win_or_lose_is_friendly():
    w, c = game(badges=6)
    c.eval("ns.Azero:Run(function(g) ns.AzeroPeople.BillyTalk(g) end)")
    texts(c)
    assert c.eval("return ns.Azero.pending.kind") == "choice"
    c.eval("ns.Azero:Advance(1)")
    texts(c)
    p = c.eval_py("""local b = ns.Azero.pending.battle local o = {}
      for _, f in ipairs(b.foes) do o[#o + 1] = { f.sp, f.lvl, f.nick or false } end return o""")
    assert p == [["murkling", 29, "Gurgles"], ["owlet", 28, False], ["tuskling", 27, False]], p
    c.eval("ns.Azero:Advance('win')")
    t = texts(c)
    assert c.eval("return ns.Azero:Flag('beat_billy')") is True and any("Next time" in x for x in t), t
    c.eval("ns.Azero:Run(function(g) ns.AzeroPeople.BillyTalk(g) end)")
    assert any("One day I'll beat you" in x for x in texts(c))
    # losing to him: no blackout, healed, he cheers
    w2, c2 = game(badges=6)
    c2.eval("ns.Azero.save.map = 'town' ns.Azero:Run(function(g) ns.AzeroPeople.BillyTalk(g) end)")
    texts(c2)
    c2.eval("ns.Azero:Advance(1)")
    texts(c2)
    c2.eval("ns.Azero.save.party[1].hp = 0 ns.Azero:Advance('lose')")
    t = texts(c2)
    assert any("WE WON" in x for x in t), t
    assert c2.eval("return ns.Azero.save.party[1].hp > 0") is True
    assert c2.eval("return ns.Azero:Flag('beat_billy')") is None
    no_errors(w)
    no_errors(w2)


@case
def the_ballad_is_built_from_your_save():
    w, c = game()
    c.eval("ns.Azero.save.flags.starter = 'murkling' ns.Azero:SetFlag('badge_nightwatch') ns.Azero:SetFlag('badge_hogger')")
    c.eval("ns.Azero.save.party[1].shiny = true ns.Azero.save.fishBest = 'redgill'")
    lines = c.eval_py("local o = {} for _, cp in ipairs(ns.AzeroPeople.Ballad()) do o[#o + 1] = cp[1] .. ' / ' .. cp[2] end return o")
    assert lines[0] == "Hear the tale of {PLAYER}, who left the Maclures' door, / a Murkling at their heel and courage to the core.", lines
    assert lines[1].startswith("They felled Hogger") and lines[2].startswith("In Darkshire"), lines
    assert lines[3] == ("A shiny Murkling, silver-bright, came to them in the reeds, / "
                        "and the Raw Redgill that they landed still hangs where Farley feeds."), lines
    assert len(lines) == 4, lines
    no_errors(w)


@case
def bard_willem_plays_the_evening_and_sings_your_song():
    w, c = game(hour=12)
    c.eval("ns.Azero:EnterMap('post', 7, 7, 'up', true)")
    assert c.eval_py("for _, n in ipairs(ns.Azero.npcs) do if n.id == 'bard' then return n.hidden == true end end") is True
    c.eval("ns.Azero.clockHour = 20 ns.Azero:EnterMap('post', 7, 7, 'up', true)")
    b = c.eval_py("for _, n in ipairs(ns.Azero.npcs) do if n.id == 'bard' then return { n.x, n.y, n.act or false, n.hidden == true } end end")
    assert b == [12, 4, "lute", False], b
    t = talk(c, "bard")
    assert any("Hear the tale of Alice" in x for x in t) and any("more verses" in x for x in t), t
    no_errors(w)


@case
def people_greet_you_by_name_once_a_day():
    w, c = game(badges=2)
    c.eval("ns.Azero:EnterMap('post', 5, 3, 'up', true) ns.Azero.save.money = 99999")
    c.eval("ns.Azero:Buy('potion', 3) ns.Azero:Buy('potion', 3) ns.Azero:Buy('net', 1)")
    for _ in range(2):
        t = talk(c, "clerk")
        assert not any("Back again" in x for x in t), t
        c.eval("ns.Azero.pending = nil ns.Azero.co = nil")
    t = talk(c, "clerk")
    assert t and t[0] == "Brog Hamfist: Back again, Alice? 3 Minor Healing Potions, as usual?", t
    c.eval("ns.Azero.pending = nil ns.Azero.co = nil")
    t = talk(c, "clerk")
    assert not any("Back again" in x for x in t), t                         # once a day
    c.eval("ns.Azero.pending = nil ns.Azero.co = nil ns.AzeroPeople.clock = %d" % (T0 + 86400))
    assert any("Back again" in x for x in talk(c, "clerk"))
    # Lee Brown and your best fish; Maybell and your badges
    c.eval("ns.Azero.pending = nil ns.Azero.co = nil ns.AzeroPeople.NoteFish('smallfish') ns.AzeroPeople.NoteFish('catfish') ns.AzeroPeople.NoteFish('mudsnapper')")
    assert c.eval("return ns.Azero.save.fishBest") == "catfish"
    c.eval("ns.Azero:EnterMap('town', 20, 18, 'down', true)")
    t = talk(c, "farmer")
    assert t and t[0] == "Maybell Maclure: Billy hasn't stopped talking about you, Alice.", t
    no_errors(w)


@case
def gurgles_swims_by_billys_bobber():
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(7) ns.Azero:NewGame()")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle() ns.AzeroUI.tipsOff = true ns.Azero.clockHour = 15")
    c.eval("ns.Azero:EnterMap('town', 26, 13, 'right', true)")
    w.tick(0.3)
    assert c.eval("return ns.AzeroUI._Gurgles()") is False
    for b in BADGES[:3]:
        c.eval("ns.Azero:SetFlag('badge_%s')" % b)
    for _ in range(4):
        w.tick(0.1)
    assert c.eval("return ns.AzeroUI._Gurgles()") is True
    no_errors(w)


if __name__ == "__main__":
    run_all()

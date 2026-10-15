"""Azeromon: who's where (Routine.lua R.Town / G:WhosWhere, UI.lua KH.OpenWhos), asked of an innkeeper.

Covers: a town's page lists everyone keeping a day there with what they're doing and where (a room, out of
town, out in town) and a day bar that covers all 24 hours; every town with an innkeeper has people (Sentinel Hill
too), the arena none; Sentinel Hill's day (Hewen, Danuvin, the footman, Mara); the innkeeper's "Anyone seen...?"
opens the page, up/down picks, Space has the innkeeper say where they are, X goes back; "Yes, please" still rests.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_whos.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def town_list(c, town, hour):
    return c.eval_py("""local out = {}
      for _, e in ipairs(ns.AzeroRoutine.Town(%r, %r)) do
        local cover = 0
        for _, b in ipairs(e.bar) do cover = cover + (b[2] - b[1]) end
        out[#out + 1] = { e.name, e.label, e.where, math.floor(cover + 0.5) }
      end
      return out""" % (town, hour * 60)) or []


@case
def a_towns_page_lists_its_people_where_they_are_and_their_day():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame()")
    rows = town_list(c, "town", 19.7)
    names = [r[0] for r in rows]
    assert names[:4] == ["Marshal Dughan", "Maybell Maclure", "Alchemist Mallory", "Smith Argus"], names
    assert len(rows) == 10, names
    by = {r[0]: r for r in rows}
    assert by["Smith Argus"][1:3] == ["Supper at the inn", "Lion's Pride Inn"], by["Smith Argus"]
    assert by["Marshal Dughan"][1:3] == ["Watching the north road", "Out in Goldshire"], by["Marshal Dughan"]
    assert all(r[3] == 1440 for r in rows), rows                    # every bar covers the whole day
    noon = {r[0]: r for r in town_list(c, "town", 12)}
    assert noon["Wenna"][2] == "Out of town", noon["Wenna"]
    no_errors(w)


@case
def every_town_with_an_innkeeper_has_people_and_the_arena_none():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame()")
    for town in ("town", "sentinel", "darkshire", "bootybay", "lakeshire"):
        assert len(town_list(c, town, 12)) >= 2, town
    assert town_list(c, "arena", 12) == []
    dark = {r[0]: r for r in town_list(c, "darkshire", 23)}
    assert dark["Lord Ello Ebonlocke"][2] == "At home in the town hall", dark
    no_errors(w)


@case
def sentinel_hill_keeps_its_day():
    w, c = solo("Alice", tick=2)
    def people(hour):
        c.eval("ns.Azero:NewGame() ns.Azero.clockHour = %r ns.Azero:EnterMap('sentinel', 10, 11, 'down', true)" % hour)
        return c.eval_py("""local out = {}
          for _, n in ipairs(ns.Azero.npcs) do out[n.id] = { n.x, n.y, n.hidden == true } end return out""")
    p = people(12)
    assert p["hewen"] == [8, 8, False] and p["danuvin"] == [4, 12, False], p
    assert p["refugee"][2] and not p["footman"][2] and p["footman"][1] in (9, 10), p
    p = people(23)
    assert p["hewen"][2] and p["footman"][2] and not p["refugee"][2] is False, p
    assert not p["danuvin"][2] and p["danuvin"][1] in (9, 10), p          # on his lantern round
    c.eval("ns.Azero.clockHour = 23 ns.Azero:EnterMap('sentinelinn', 4, 6, 'up', true)")
    inn = c.eval_py("local out = {} for _, n in ipairs(ns.Azero.npcs) do if n.visitor then out[#out + 1] = n.id end end table.sort(out) return out")
    assert inn == ["footman", "hewen", "refugee"], inn
    no_errors(w)


def ui_game(c, w):
    c.eval(BOT)
    c.eval("T_AZ.seed(7) ns.Azero:NewGame()")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle() ns.AzeroUI.tipsOff = true ns.Azero.clockHour = 19.7")
    c.eval("ns.Azero.save.party = { ns.AzeroMon.New('murkling', 12, ns.Azero.rng) }")


def talk_to_farley(c, w):
    c.eval("ns.Azero:EnterMap('post', 2, 3, 'up', true)")
    w.tick(0.2)
    c.eval("ns.AzeroUI._HandleKey('A')")
    for _ in range(10):
        w.tick(0.2)
        p = c.eval_py("local p = ns.Azero.pending return p and { p.kind, p.text }")
        if p and p[0] == "choice":
            return p
        c.eval("ns.AzeroUI._HandleKey('A')")
    return None


@case
def the_innkeeper_tells_you_who_is_where():
    w, c = solo("Alice", tick=2)
    ui_game(c, w)
    p = talk_to_farley(c, w)
    assert p and "warm meal" in p[1], p
    c.eval("ns.AzeroUI._HandleKey('down') ns.AzeroUI._HandleKey('A')")       # "Anyone seen...?"
    w.tick(0.3)
    page = c.eval_py("return ns.AzeroUI._Whos()")
    assert page and page["title"] == "WHO'S WHERE  -  GOLDSHIRE" and len(page["rows"]) == 10, page
    assert page["rows"][3] == ["Smith Argus", "Supper at the inn", "Lion's Pride Inn"], page["rows"][3]
    for _ in range(3):
        c.eval("ns.AzeroUI._HandleKey('down')")
    assert c.eval_py("return ns.AzeroUI._Whos()")["sel"] == 4
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    p = c.eval_py("local p = ns.Azero.pending return p and { p.kind, p.text }")
    assert p and p[0] == "text" and p[1].startswith("Innkeeper Farley: Smith Argus? Right over there."), p
    assert c.eval_py("return ns.AzeroUI._Whos()") is None
    no_errors(w)


@case
def back_closes_the_page_and_yes_still_rests():
    w, c = solo("Alice", tick=2)
    ui_game(c, w)
    talk_to_farley(c, w)
    c.eval("ns.AzeroUI._HandleKey('down') ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('B')")
    w.tick(0.3)
    assert c.eval_py("return ns.AzeroUI._Whos()") is None
    for _ in range(5):
        if not c.eval("return ns.Azero.pending ~= nil"):
            break
        c.eval("ns.Azero:Advance()")
    c.eval("for _, m in ipairs(ns.Azero.save.party) do m.hp = 1 end")
    talk_to_farley(c, w)
    c.eval("ns.AzeroUI._HandleKey('A')")                         # "Yes, please"
    w.tick(0.3)
    hp = c.eval_py("local M = ns.AzeroMon local o = {} for _, m in ipairs(ns.Azero.save.party) do o[#o + 1] = m.hp == M.MaxHP(m) end return o")
    assert hp and all(hp), hp
    no_errors(w)


if __name__ == "__main__":
    run_all()

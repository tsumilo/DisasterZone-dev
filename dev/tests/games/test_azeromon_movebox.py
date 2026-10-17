"""Azeromon 0.40: the move box (UI.lua OpenFightMenu, Scr.MoveLine / FitMoveRow / RestMark / FightDeco).

Covers: what a move does is one line under the moves (the coach's pick says why, behind a COACH tag) and every
move's line fits that line in the game's own font; the box on the right keeps four rows, its corner the hourglass and
the rest after use, or "Ready in N" while it rests; a resting move shows an hourglass and one pip per turn of rest
(filled: the turns left) in its row's one right-hand slot; the turn it is ready again its row glints; nothing of the
move list's own layer is left over a menu that reuses its frame.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_movebox.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

ADDON = os.environ.get("DISASTERZONE_ADDON_DIR") or os.path.join(TESTS, "..", "..", "addon", "DisasterZone")
FONT = os.path.join(ADDON, "..", "DisasterZone_Azeromon", "Media", "fonts", "PixelifySans-Medium.ttf")
LINE_W = 472 - 40                    # the line's room: the move list's width less its margins
SLACK = 1.06                         # the game draws Pixelify a little wider than PIL measures it


def key(w, c, *keys):
    for k in keys:
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.05)


def to_action(w, c):
    for _ in range(80):
        w.tick(0.2)
        if c.eval("return ns.Azero.battle and ns.Azero.battle.need") == "action" and \
                c.eval_py("return ns.AzeroUI._State()")["stack"] >= 1:
            return
        c.eval("ns.AzeroUI._HandleKey('A')")
    raise AssertionError("no action menu")


def battle(moves, coach=False):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(4)")
    c.eval("ns.Azero:NewGame()")
    c.eval("ns.Azero:Data().coach = %s" % ("true" if coach else "false"))
    c.eval("local M = ns.AzeroMon local m = M.New('murkling', 30, ns.Azero.rng) m.moves = {} "
           "for i, id in ipairs({ %s }) do m.moves[i] = { id = id, pp = ns.AzeroData.moves[id].pp } end "
           "ns.Azero.save.party = { m }" % ", ".join('"%s"' % x for x in moves))
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    c.eval("ns.Azero:Run(function(g) g:WildBattle('rustgolem', 10) end)")
    to_action(w, c)
    return w, c


@case
def every_moves_line_fits_under_the_moves():
    from PIL import ImageFont
    w, c = solo("Alice", tick=2)
    lines = c.eval_py(r"""
      local D, out = ns.AzeroData, {}
      local kitOf = {}
      for _, kit in pairs(D.TYPE_KIT) do for _, id in ipairs(kit) do kitOf[id] = kit end end
      for id, md in pairs(D.moves) do
        if md.role then
          out[#out + 1] = { id, ns.AzeroUI._MoveLine(id, kitOf[id] or D.TYPE_KIT[md.type] or {}) }
        end
      end
      table.sort(out, function(a, b) return a[1] < b[1] end)
      return out""")
    big = ImageFont.truetype(FONT, 15)               # size 12: the line's own
    small = ImageFont.truetype(FONT, 14)             # size 11: a long one steps down to it
    assert len(lines) > 60, len(lines)
    too_long = [(i, t, round(small.getlength(t) * SLACK)) for i, t in lines if small.getlength(t) * SLACK > LINE_W]
    assert too_long == [], too_long
    stepped = [i for i, t in lines if big.getlength(t) * SLACK > LINE_W]
    assert len(stepped) <= len(lines) // 10, stepped                  # almost all at the line's own size
    empty = [i for i, t in lines if not t]
    assert empty == [], empty
    want = {
        "kfrostshock": "Leaves CHILL (2 turns): Ice Lance hits x2.3.",
        "kicelance": "x2.3 while the foe is Chilled.",
        "krend": "Leaves BLEED (3 turns): Ferocious Bite hits x1.8.",
        "kferobite": "x1.8 while the foe is Bleeding; uses it up.",
        "kchargeup": "Gets CHARGED (3 turns): Rocket Punch hits x1.8.",
        "kpyroblast": "Lands next turn. Guard or interrupt can stop it.",
        "kfireward": "Goes first. Soaks 75% of hits for 2 turns.",
        "kcounterspell": "Goes first and breaks the foe's cast.",
        "kregrowth": "Heals 20% of its HP, then REGROWTH for 3 turns.",
        "kwaterbolt": "No rest: use it any turn.",
    }
    got = dict(lines)
    assert {k: got.get(k) for k in want} == want, {k: got.get(k) for k in want}
    no_errors(w)


@case
def a_resting_move_shows_its_hourglass_and_pips():
    w, c = battle(["kwaterbolt", "kfrostshock", "kicelance", "kshellshield"])
    c.eval("local b = ns.Azero.battle b.ally.cd[2] = 2")             # Frost Shock: 2 of its 3 turns left
    key(w, c, "A")                                                   # FIGHT
    rows = c.eval_py("return ns.AzeroUI._MoveRows()")
    assert rows[1]["mark"] == {"total": 3, "left": 2, "glass": True}, rows
    assert rows[0]["mark"] is False and rows[2]["mark"] is False and rows[1].get("right") is None, rows
    assert all(r["size"] == 16 for r in rows), rows
    key(w, c, "right")                                               # onto Frost Shock: the box's corner says so
    assert c.eval_py("return ns.AzeroUI._MoveRest()") == {"glass": False, "text": "Ready in 2"}
    key(w, c, "left")                                                # Water Bolt: no rest, no hourglass
    assert c.eval_py("return ns.AzeroUI._MoveRest()") == {"glass": False, "text": ""}
    key(w, c, "down", "right")                                       # Shell Shield: rests 3 after use
    assert c.eval_py("return ns.AzeroUI._MoveRest()") == {"glass": True, "text": "3"}
    assert c.eval("return ns.AzeroUI._MoveNote()") == "Goes first. Soaks 75% of hits for 2 turns."
    no_errors(w)


@case
def a_move_ready_again_glints_once():
    w, c = battle(["kwaterbolt", "kfrostshock", "kicelance", "kshellshield"])
    c.eval("ns.Azero.battle.ally.cd[2] = 1")
    key(w, c, "A")                                                   # FIGHT: Frost Shock rests one more turn
    assert c.eval_py("return ns.AzeroUI._MoveRows()")[1]["glint"] is False
    c.eval("ns.Azero.battle.foe.mon.hp = 999")
    key(w, c, "A")                                                   # Water Bolt (the cursor is on it)
    to_action(w, c)                                                  # the turn plays out
    assert c.eval("return ns.Azero.battle.ally.cd[2]") == 0
    key(w, c, "A")                                                   # FIGHT again: it is ready, its row glints
    rows = c.eval_py("return ns.AzeroUI._MoveRows()")
    assert rows[1]["glint"] is True and rows[1]["mark"] is False, rows
    w.tick(1.0)
    assert c.eval_py("return ns.AzeroUI._MoveRows()")[1]["glint"] is False             # (once)
    no_errors(w)


@case
def the_coachs_pick_says_why_on_the_line():
    w, c = battle(["kwaterbolt", "kfrostshock", "kicelance", "kshellshield"], coach=True)
    key(w, c, "A")
    assert c.eval("return ns.AzeroUI._MoveNote()") == "Coach: Set up the combo for Ice Lance."
    key(w, c, "left")                                                # Water Bolt: its own line
    assert c.eval("return ns.AzeroUI._MoveNote()") == "No rest: use it any turn."
    no_errors(w)


@case
def the_move_lists_layer_leaves_with_it():
    w, c = battle(["kwaterbolt", "kfrostshock", "kicelance", "kshellshield"])
    c.eval("ns.Azero.battle.ally.cd[2] = 2")
    key(w, c, "A")                                                   # FIGHT
    assert c.eval("return ns.AzeroUI.Kit.R.fightDeco:IsShown()") is True
    key(w, c, "B")                                                   # back: the layer is gone with the list
    assert c.eval("return ns.AzeroUI.Kit.R.fightDeco:IsShown()") is False
    key(w, c, "right", "A")                                          # BAG (the pooled frame again): nothing over it
    assert c.eval("return ns.AzeroUI.Kit.R.fightDeco:IsShown()") is False
    assert c.eval("return ns.AzeroUI._MoveNote()") is None
    no_errors(w)


if __name__ == "__main__":
    run_all()

"""Azeromon: move details when learning, and the pet trainer (move relearner).

Covers: which moves a beast can be reminded of (its type's kit and its earlier form's, up to its level, not the ones
it knows); lessons are free since 0.36 (the fourth slot: big cast, guard or interrupt) and need a forget slot; the
whole conversation with Gorvin Wildhammer in the Lion's Pride Inn through the UI (party pick, move list, forget menu
with both moves compared, nothing paid, even with an empty purse); the battle's "forget which move?" menu showing the
new move beside the highlighted one; and the move text (power, accuracy, PP, cooldown, what a kit move does).

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_relearn.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def layout(c):
    return c.eval_py("return ns.AzeroUI._MenuLayout()")


def check_fits(L, name):
    """Inside the screen and above the box at the bottom; the rows inside the menu; the cursor in view."""
    bottom = -L["y"] + L["h"]
    assert L["x"] >= 0 and L["x"] + L["w"] <= L["SW"], (name, L)
    assert bottom <= L["SH"] - L["desc"], (name, "menu bottom %d past %d" % (bottom, L["SH"] - L["desc"]), L)
    for r in L["rows"]:
        assert -r["y"] + r["h"] <= L["h"] - 10 and r["x"] + r["w"] <= L["w"] - 10, (name, r, L)
    assert L["cursor"] in [r["idx"] for r in L["rows"]], (name, L)


def game(seed=7, ui=False):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    c.eval("ns.Azero:NewGame()")
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('owlet', 3, ns.Azero.rng), 'caught')")
    if ui:
        c.slash("/dz play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")                # title: CONTINUE
        w.tick(0.3)
        c.eval("T_AZ.settle()")
    return w, c


def key(w, c, *keys):
    for k in keys:
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.05)


def top_title(c):
    levels = c.eval_py("return ns.AzeroUI._Levels()") or []
    return levels[-1]["title"] if levels else None


def press_until(w, c, title, limit=60):
    """Presses A (reading text) until the menu titled `title` is on top."""
    for _ in range(limit):
        if top_title(c) == title:
            return True
        key(w, c, "A")
        w.tick(0.2)
    return top_title(c) == title


def drake(c, lvl=25, moves=("kscorch", "kimmolate", "kincinerate", "kfireward")):
    c.eval("""local M = ns.AzeroMon
      local mon = M.New('flamescale', %d, ns.Azero.rng)
      mon.moves = {}
      for _, id in ipairs({ %s }) do mon.moves[#mon.moves + 1] = { id = id, pp = ns.AzeroData.moves[id].pp } end
      ns.Azero.save.party = { mon }""" % (lvl, ", ".join("'%s'" % m for m in moves)))


def talk_to_gorvin(w, c):
    c.eval("ns.Azero:EnterMap('post', 12, 7, 'left', true)")
    w.tick(0.2)
    key(w, c, "A")
    # read his lines up to the Yes / No
    for _ in range(20):
        if c.eval("return ns.Azero.pending and ns.Azero.pending.kind") == "choice":
            break
        key(w, c, "A")
        w.tick(0.2)
    return c.eval("return ns.Azero.pending.text") or ""


@case
def relearnable_moves_come_from_its_kit_and_its_earlier_form_up_to_its_level():
    w, c = game()
    drake(c)
    got = c.eval_py("return ns.Azero:RelearnableMoves(ns.Azero.save.party[1])")
    # the fourth slot's other two (19, 25) and its signatures: the Whelp's Flame Breath (16), its own Flame Buffet (24)
    assert got == ["sf_flamebreath", "kcounterspell", "sf_flamebuffet", "kpyroblast"], got
    # below the level a move comes at, it isn't offered
    drake(c, lvl=18, moves=("kincinerate",))
    got = c.eval_py("return ns.Azero:RelearnableMoves(ns.Azero.save.party[1])")
    assert got == ["kscorch", "kimmolate", "kfireward", "sf_flamebreath"], got
    # every evolved species offers its earlier form's moves too
    bad = c.eval_py("""local D, G, M = ns.AzeroData, ns.Azero, ns.AzeroMon
      local bad = {}
      for id, sp in pairs(D.species) do
        if sp.evolve then
          local mon = M.New(sp.evolve.into, D.MAX_LEVEL, G.rng)
          mon.moves = {}
          local offered = {}
          for _, m in ipairs(G:RelearnableMoves(mon)) do offered[m] = true end
          for _, e in ipairs(sp.learn) do
            if not offered[e[2]] then bad[#bad + 1] = sp.evolve.into .. " misses " .. e[2] end
          end
        end
      end
      return bad""")
    assert bad == [], bad
    no_errors(w)


@case
def a_lesson_is_free_and_needs_a_slot_once_it_knows_four_moves():
    w, c = game()
    drake(c)
    r = c.eval_py("""local G = ns.Azero
      G.save.money = 1200
      local out = {}
      out.noSlot = { G:Relearn(1, 'kcounterspell', nil) }
      out.notItsMove = { G:Relearn(1, 'ktidalwave', 1) }
      out.ok = { G:Relearn(1, 'kpyroblast', 4) }
      out.slot4 = G.save.party[1].moves[4].id
      out.pp4 = G.save.party[1].moves[4].pp
      out.money = G.save.money
      G.save.money = 0
      out.broke = { G:Relearn(1, 'kfireward', 4) }
      out.moneyBroke = G.save.money
      return out""")
    assert r["noSlot"][0] is False and r["notItsMove"][0] is False, r
    assert r["ok"][0] is True and "forgot Fire Ward" in r["ok"][1] and "learned Pyroblast" in r["ok"][1], r
    assert r["slot4"] == "kpyroblast" and r["pp4"] == 10 and r["money"] == 1200, r
    assert r["broke"][0] is True and r["moneyBroke"] == 0, r                   # free: an empty purse is fine
    # with room, no slot is needed
    drake(c, moves=("kincinerate",))
    r = c.eval_py("ns.Azero.save.money = 500 local ok = ns.Azero:Relearn(1, 'kscorch') "
                  "return { ok = ok, n = #ns.Azero.save.party[1].moves, money = ns.Azero.save.money }")
    assert r == {"ok": True, "n": 2, "money": 500}, r
    no_errors(w)


@case
def the_pet_trainer_teaches_through_the_menus():
    w, c = game(ui=True)
    drake(c)
    c.eval("ns.Azero.save.money = 2000")
    assert "Gorvin Wildhammer" in talk_to_gorvin(w, c)
    key(w, c, "A")                                           # Yes (after the text is shown)
    assert press_until(w, c, "TEACH WHICH BEAST?")
    key(w, c, "A")
    assert top_title(c) == "REMEMBER WHICH MOVE?"
    L = layout(c)
    check_fits(L, "remember")
    cards = c.eval_py("return ns.AzeroUI._MoveCards()")
    assert cards[0]["label"] == "REMEMBER" and cards[0]["name"] == "Flame Breath", cards        # a signature filler
    assert cards[0]["stats"].startswith("Power 45") and "burn" in cards[0]["effect"], cards
    assert cards[1]["label"] == "LESSON" and cards[1]["name"] == "Free", cards
    key(w, c, "down")                                        # Counterspell
    cards = c.eval_py("return ns.AzeroUI._MoveCards()")
    assert cards[0]["name"] == "Counterspell" and cards[0]["stats"] == "Power 30   Acc 100%   PP 15   CD 4", cards
    assert cards[0]["effect"] == "First. Breaks a cast", cards
    key(w, c, "down", "down")                                # (Flame Buffet) Pyroblast
    cards = c.eval_py("return ns.AzeroUI._MoveCards()")
    assert cards[0]["name"] == "Pyroblast" and cards[0]["effect"] == "Lands next turn", cards
    key(w, c, "A")
    assert top_title(c) == "FORGET WHICH MOVE?"
    check_fits(layout(c), "forget")
    cards = c.eval_py("return ns.AzeroUI._MoveCards()")
    assert cards[0]["label"] == "NEW MOVE" and cards[0]["name"] == "Pyroblast", cards
    assert cards[1]["label"] == "FORGET" and cards[1]["name"] == "Scorch", cards
    key(w, c, "down")                                         # Immolate
    assert c.eval_py("return ns.AzeroUI._MoveCards()")[1]["effect"] == "Leaves IMMOLATE for 3 turns"
    key(w, c, "down", "down")                                 # Fire Ward
    cards = c.eval_py("return ns.AzeroUI._MoveCards()")
    assert cards[1]["name"] == "Fire Ward" and cards[1]["effect"] == "Soaks 75% for 2 turns", cards
    key(w, c, "down")                                         # Don't learn
    assert c.eval_py("return ns.AzeroUI._MoveCards()")[1]["label"] == "KEEP"
    key(w, c, "B")                                            # back to the list
    assert top_title(c) == "REMEMBER WHICH MOVE?"
    key(w, c, "A")                                            # Pyroblast again
    key(w, c, "down", "down", "down", "A")                    # forget Fire Ward
    for _ in range(20):
        if not c.eval("return ns.Azero.pending ~= nil") and c.eval("return ns.AzeroUI._State().stack") == 0:
            break
        key(w, c, "A")
        w.tick(0.2)
    r = c.eval_py("""local mon = ns.Azero.save.party[1]
      local ids = {}
      for i, m in ipairs(mon.moves) do ids[i] = m.id end
      return { moves = ids, money = ns.Azero.save.money, cards = ns.AzeroUI._MoveCards() }""")
    assert r["moves"] == ["kscorch", "kimmolate", "kincinerate", "kpyroblast"], r
    assert r["money"] == 2000 and r.get("cards") is None, r              # nothing paid
    no_errors(w)


@case
def the_pet_trainer_teaches_an_empty_purse_too():
    w, c = game(ui=True)
    drake(c)
    c.eval("ns.Azero.save.money = 0")
    assert "for free" in talk_to_gorvin(w, c)
    key(w, c, "A")                                           # Yes
    assert press_until(w, c, "TEACH WHICH BEAST?")
    assert c.eval("return ns.Azero.save.money") == 0
    no_errors(w)


@case
def the_battle_forget_menu_compares_the_new_move():
    w, c = game(ui=True)
    c.eval("""local G, M = ns.Azero, ns.AzeroMon
      local mon = M.New('flamescale', 18, G.rng)
      mon.exp = M.ExpForLevel(19) - 1
      G.save.party = { mon }
      G:Run(function(g)
        local foe = M.New('wolfpup', 2, g.rng)
        foe.hp = 1
        g:RunBattle({ foe }, nil)
      end)""")
    assert c.eval("return #ns.Azero.save.party[1].moves") == 4
    assert press_until(w, c, "FORGET WHICH MOVE?", limit=120)
    check_fits(layout(c), "battle forget")
    cards = c.eval_py("return ns.AzeroUI._MoveCards()")
    assert cards[0]["label"] == "NEW MOVE" and cards[0]["name"] == "Counterspell", cards
    assert cards[0]["effect"] == "First. Breaks a cast", cards
    assert cards[1]["label"] == "FORGET" and cards[1]["name"] == "Scorch", cards
    key(w, c, "down", "down", "down", "down")                 # Don't learn
    key(w, c, "A")
    for _ in range(80):
        if c.eval("return ns.Azero.battle == nil and ns.Azero.pending == nil"):
            break
        key(w, c, "A")
        w.tick(0.2)
    r = c.eval_py("""local mon = ns.Azero.save.party[1]
      local knows = false
      for _, m in ipairs(mon.moves) do if m.id == 'kcounterspell' then knows = true end end
      return { sp = mon.sp, lvl = mon.lvl, knows = knows }""")
    assert r == {"sp": "flamescale", "lvl": 19, "knows": False}, r
    no_errors(w)


if __name__ == "__main__":
    run_all()

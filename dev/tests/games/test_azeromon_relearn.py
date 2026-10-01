"""Azeromon: move details when learning, and the pet trainer (move relearner).

Covers: which moves a beast can be reminded of (its own list and its earlier form's, up to its level, not the ones it
knows); the fee and the forget slot; the whole conversation with Gorvin Wildhammer in the Lion's Pride Inn through the
UI (party pick, move list, forget menu with both moves compared, the fee paid); the battle's "forget which move?" menu
showing the new move beside the highlighted one; and the move text (power, accuracy, PP, effects).

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
        c.slash("/cdl play azeromon")
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


def drake(c, lvl=25, moves=("flamebuffet", "wingbuffet", "flamebreath", "leer")):
    c.eval("""local M = ns.AzeroMon
      local mon = M.New('flamescale', %d, ns.Azero.rng)
      mon.moves = {}
      for _, id in ipairs({ %s }) do mon.moves[#mon.moves + 1] = { id = id, pp = ns.AzeroData.moves[id].pp } end
      ns.Azero.save.party = { mon }""" % (lvl, ", ".join("'%s'" % m for m in moves)))


@case
def relearnable_moves_come_from_its_list_and_its_earlier_form_up_to_its_level():
    w, c = game()
    drake(c)
    got = c.eval_py("return ns.Azero:RelearnableMoves(ns.Azero.save.party[1])")
    assert got == ["scratch", "growl", "ember"], got
    # below the level a move comes at, it isn't offered
    drake(c, lvl=18, moves=("flamebreath",))
    got = c.eval_py("return ns.Azero:RelearnableMoves(ns.Azero.save.party[1])")
    assert got == ["scratch", "growl", "ember", "leer"], got
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
def a_lesson_costs_the_fee_and_needs_a_slot_once_it_knows_four_moves():
    w, c = game()
    drake(c)
    r = c.eval_py("""local G = ns.Azero
      G.save.money = 1200
      local out = {}
      out.noSlot = { G:Relearn(1, 'scratch', nil) }
      out.notItsMove = { G:Relearn(1, 'tidal', 1) }
      out.moneyAfterRefusals = G.save.money
      out.ok = { G:Relearn(1, 'scratch', 2) }
      out.slot2 = G.save.party[1].moves[2].id
      out.pp2 = G.save.party[1].moves[2].pp
      out.money = G.save.money
      G.save.money = 100
      out.poor = { G:Relearn(1, 'growl', 1) }
      return out""")
    assert r["noSlot"][0] is False and r["notItsMove"][0] is False, r
    assert r["moneyAfterRefusals"] == 1200, r
    assert r["ok"][0] is True and "forgot Wing Buffet" in r["ok"][1] and "learned Claw" in r["ok"][1], r
    assert r["slot2"] == "scratch" and r["pp2"] == 35 and r["money"] == 700, r
    assert r["poor"] == [False, "You don't have enough money."], r
    # with room, no slot is needed
    drake(c, moves=("flamebreath",))
    r = c.eval_py("ns.Azero.save.money = 500 local ok = ns.Azero:Relearn(1, 'ember') "
                  "return { ok = ok, n = #ns.Azero.save.party[1].moves, money = ns.Azero.save.money }")
    assert r == {"ok": True, "n": 2, "money": 0}, r
    no_errors(w)


@case
def the_pet_trainer_teaches_through_the_menus():
    w, c = game(ui=True)
    drake(c)
    c.eval("ns.Azero.save.money = 2000 ns.Azero:EnterMap('post', 2, 5, 'left', true)")
    w.tick(0.2)
    key(w, c, "A")                                           # talk to Gorvin
    # read his lines up to the Yes / No
    for _ in range(20):
        if c.eval("return ns.Azero.pending and ns.Azero.pending.kind") == "choice":
            break
        key(w, c, "A")
        w.tick(0.2)
    assert "Gorvin Wildhammer" in (c.eval("return ns.Azero.pending.text") or "")
    key(w, c, "A")                                           # Yes (after the text is shown)
    assert press_until(w, c, "TEACH WHICH BEAST?")
    key(w, c, "A")
    assert top_title(c) == "REMEMBER WHICH MOVE?"
    L = layout(c)
    check_fits(L, "remember")
    cards = c.eval_py("return ns.AzeroUI._MoveCards()")
    assert cards[0]["label"] == "REMEMBER" and cards[0]["name"] == "Claw", cards
    assert cards[0]["stats"] == "Power 40   Acc 100%   PP 35", cards
    assert cards[1]["label"] == "LESSON" and cards[1]["name"] == "5s", cards
    key(w, c, "down")                                        # Demoralizing Roar
    cards = c.eval_py("return ns.AzeroUI._MoveCards()")
    assert cards[0]["name"] == "Demoralizing Roar" and cards[0]["effect"] == "Lowers the foe's Attack", cards
    key(w, c, "A")
    assert top_title(c) == "FORGET WHICH MOVE?"
    check_fits(layout(c), "forget")
    cards = c.eval_py("return ns.AzeroUI._MoveCards()")
    assert cards[0]["label"] == "NEW MOVE" and cards[0]["name"] == "Demoralizing Roar", cards
    assert cards[1]["label"] == "FORGET" and cards[1]["name"] == "Flame Buffet", cards
    assert cards[1]["effect"] == "May burn the foe (20%)", cards
    key(w, c, "down", "down", "down")                         # Leer (Sunder Armor)
    assert c.eval_py("return ns.AzeroUI._MoveCards()")[1]["name"] == "Sunder Armor"
    key(w, c, "down")                                         # Don't learn
    assert c.eval_py("return ns.AzeroUI._MoveCards()")[1]["label"] == "KEEP"
    key(w, c, "B")                                            # back to the list
    assert top_title(c) == "REMEMBER WHICH MOVE?"
    key(w, c, "A")                                            # Demoralizing Roar again
    key(w, c, "down", "down", "down", "A")                    # forget Sunder Armor
    for _ in range(20):
        if not c.eval("return ns.Azero.pending ~= nil") and c.eval("return ns.AzeroUI._State().stack") == 0:
            break
        key(w, c, "A")
        w.tick(0.2)
    r = c.eval_py("""local mon = ns.Azero.save.party[1]
      local ids = {}
      for i, m in ipairs(mon.moves) do ids[i] = m.id end
      return { moves = ids, money = ns.Azero.save.money, cards = ns.AzeroUI._MoveCards() }""")
    assert r["moves"] == ["flamebuffet", "wingbuffet", "flamebreath", "growl"], r
    assert r["money"] == 1500 and r.get("cards") is None, r
    no_errors(w)


@case
def the_pet_trainer_turns_away_a_player_who_cannot_pay():
    w, c = game(ui=True)
    drake(c)
    c.eval("ns.Azero.save.money = 100 ns.Azero:EnterMap('post', 2, 5, 'left', true)")
    w.tick(0.2)
    key(w, c, "A")
    for _ in range(20):
        if c.eval("return ns.Azero.pending and ns.Azero.pending.kind") == "choice":
            break
        key(w, c, "A")
        w.tick(0.2)
    key(w, c, "A")                                           # Yes
    w.tick(0.2)
    text = c.eval("return ns.Azero.pending and ns.Azero.pending.text") or ""
    assert "short on coin" in text, text
    assert c.eval("return ns.Azero.save.money") == 100
    no_errors(w)


@case
def the_battle_forget_menu_compares_the_new_move():
    w, c = game(ui=True)
    c.eval("""local G, M = ns.Azero, ns.AzeroMon
      local mon = M.New('emberwhelp', 15, G.rng)
      mon.exp = M.ExpForLevel(16) - 1
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
    assert cards[0]["label"] == "NEW MOVE" and cards[0]["name"] == "Flame Breath", cards
    assert cards[0]["effect"] == "May burn the foe (10%)", cards
    assert cards[1]["label"] == "FORGET" and cards[1]["name"] == "Claw", cards
    key(w, c, "down", "down", "down", "down")                 # Don't learn
    key(w, c, "A")
    for _ in range(80):
        if c.eval("return ns.Azero.battle == nil and ns.Azero.pending == nil"):
            break
        key(w, c, "A")
        w.tick(0.2)
    r = c.eval_py("""local mon = ns.Azero.save.party[1]
      local knows = false
      for _, m in ipairs(mon.moves) do if m.id == 'flamebreath' then knows = true end end
      return { sp = mon.sp, knows = knows }""")
    assert r == {"sp": "flamescale", "knows": False}, r
    no_errors(w)


if __name__ == "__main__":
    run_all()

"""Azeromon 0.39: the taming moment (Games/Azeromon/Taming.lua, B:TameOdds, the battle's "tamed" event).

Covers: the odds a rod shows are the exact chance of B:Catch's four checks (asleep and better rods raise them, a
trainer's beast is never tamed); the wild battle's prompt names your best rod and its odds, and the battle bag shows
each rod's; a tame plays lure -> sigil -> orb -> pips -> TAMED! stamp, then the tamed card (the beast idling, its
level and type, NEW IN BESTIARY the first time, where it went) until A, then the battle is over; a beast that breaks
free cracks the orb after as many pips as checks held, and bursts back out, back to full size; a known species tamed
with a full party goes to the Stable Master; a shiny's card wears its star.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_taming.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def state(c):
    return c.eval_py("return ns.AzeroUI._State()")


def items(c):
    return c.eval_py("return ns.AzeroUI._MenuItems()") or []


def key(w, c, *keys):
    for k in keys:
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.05)


def game(party=None):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(4)")
    c.eval("ns.Azero:NewGame()")
    c.eval("local M = ns.AzeroMon ns.Azero.save.party = { M.New('murkling', 30, ns.Azero.rng) }")
    if party:
        c.eval(party)
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")                    # title: CONTINUE
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    return w, c


def to_action(w, c):
    for _ in range(80):
        w.tick(0.2)
        if c.eval("return ns.Azero.battle and ns.Azero.battle.need") == "action" and state(c)["stack"] >= 1:
            return
        c.eval("ns.AzeroUI._HandleKey('A')")
    raise AssertionError("no action menu: %r" % state(c))


def wild(w, c, foe="owlet", lvl=8, bag="{ net = 5, truesilverrod = 2 }", shiny=False):
    c.eval("ns.Azero.save.bag = %s" % bag)
    c.eval("ns.Azero:Run(function(g) local M = ns.AzeroMon local m = M.New(%r, %d, g.rng) m.shiny = %s "
           "g:RunBattle({ m }, nil) end)" % (foe, lvl, "true" if shiny else "false"))
    to_action(w, c)


def throw(w, c, rod):
    """BAG, then the rod named `rod` (the cursor starts on the first row)."""
    key(w, c, "up", "left", "right", "A")                   # (the cursor to FIGHT, then) BAG
    names = items(c)
    assert rod in names, names
    key(w, c, *(["down"] * names.index(rod)))
    key(w, c, "A")


def watch(w, c, seconds=12):
    """Ticks through the playback, collecting what the moment showed; stops at the next prompt or the card."""
    seen = {"lure": False, "sigil": False, "beams": False, "orb": False, "pips": 0, "stamp": False, "cracked": False,
            "sparks": 0}
    t = 0
    while t < seconds:
        w.tick(0.05)
        t += 0.05
        s = c.eval_py("return ns.AzeroTaming.State()") or {}
        for k in ("lure", "sigil", "beams", "orb", "stamp", "cracked"):
            seen[k] = seen[k] or bool(s.get(k))
        seen["pips"] = max(seen["pips"], s.get("pips") or 0)
        seen["sparks"] = max(seen["sparks"], s.get("sparks") or 0)
        if c.eval_py("return ns.AzeroTaming.CardState()"):
            break
        st = state(c)
        if st["msg"] or (st.get("text") and not st["waitText"]):
            c.eval("ns.AzeroUI._HandleKey('A')")            # read the battle's lines along
        if c.eval("return ns.Azero.battle and ns.Azero.battle.need") == "action" and st["stack"] >= 1 and t > 1:
            break
    return seen


@case
def the_odds_are_the_chance_of_the_four_checks():
    w, c = game()
    r = c.eval_py(r"""
      local B, M, D = ns.AzeroBattle, ns.AzeroMon, ns.AzeroData
      local foe = M.New('kobling', 10, ns.Azero.rng)
      local b = B.New({ party = { M.New('murkling', 10, ns.Azero.rng) }, foes = { foe }, wild = true, rng = math.random })
      while b:Pop() do end
      local a, bb = b:CatchValues(1)
      local out = { odds = b:TameOdds('net'), want = (bb / 65536) ^ 4, a = a }
      out.better = b:TameOdds('truesilverrod')
      foe.hp = 1
      out.low = b:TameOdds('net')
      foe.status = 'slp'
      out.asleep = b:TameOdds('net')
      out.potion = b:TameOdds('potion')
      -- the same checks, rolled: the share of tames over many throws comes close
      foe.hp, foe.status = M.MaxHP(foe), nil
      local p, tamed = b:TameOdds('net'), 0
      local _, bar = b:CatchValues(1)
      for _ = 1, 4000 do
        local k = 0
        while k < 4 and math.random(0, 65535) < bar do k = k + 1 end
        if k == 4 then tamed = tamed + 1 end
      end
      out.share, out.p = tamed / 4000, p
      local t = B.New({ party = { M.New('murkling', 10, ns.Azero.rng) }, foes = { M.New('kobling', 10, ns.Azero.rng) },
                        wild = false, trainer = { name = 'Hogger', class = 'boss', id = 'hogger' }, rng = math.random })
      out.trainer = t:TameOdds('net')
      return out""")
    assert abs(r["odds"] - r["want"]) < 1e-9 and 0 < r["odds"] < 1, r
    assert r["better"] > r["odds"] and r["low"] > r["odds"] and r["asleep"] > r["low"], r
    assert r["potion"] == 0 and r["trainer"] == 0, r
    assert abs(r["share"] - r["p"]) < 0.05, r
    pct = c.eval_py("local T = ns.AzeroTaming return { T.Percent(0.344), T.Percent(0.004), T.Percent(0), T.Percent(1) }")
    assert pct == ["34%", "<1%", "0%", "100%"], pct
    no_errors(w)


@case
def the_prompt_and_the_bag_show_the_odds():
    w, c = game()
    wild(w, c, foe="kobling")
    want = c.eval("local b = ns.Azero.battle return ns.AzeroTaming.Percent(b:TameOdds('truesilverrod'))")
    text = state(c).get("text") or ""
    assert text.split("\n")[-1] == "Truesilver Taming Rod: %s to tame" % want, text
    key(w, c, "up", "left", "right", "A")                   # BAG
    rows = c.eval_py("local K = ns.AzeroUI.Kit local m = K.stack[#K.stack] local o = {} "
                     "for i, it in ipairs(m.items) do o[i] = { it.text, it.right } end return o")
    net = c.eval("local b = ns.Azero.battle return ns.AzeroTaming.Percent(b:TameOdds('net'))")
    assert ["Taming Rod", "%s   x5" % net] in rows and ["Truesilver Taming Rod", "%s   x2" % want] in rows, rows
    no_errors(w)


@case
def a_trainers_beast_shows_no_odds():
    w, c = game()
    c.eval("ns.Azero.save.bag = { net = 5 }")
    c.eval("ns.Azero:Run(function(g) local M = ns.AzeroMon g:RunBattle({ M.New('kobling', 8, g.rng) }, 'hogger') end)")
    to_action(w, c)
    text = state(c).get("text") or ""
    assert "to tame" not in text and text.startswith("What will"), text
    no_errors(w)


@case
def a_tame_plays_the_moment_and_shows_the_card():
    w, c = game()
    wild(w, c, foe="owlet", lvl=8)
    c.eval("ns.Azero.battle.foe.mon.hp = 1")                # a Truesilver rod on a worn-out Owlet always holds
    assert c.eval("return ns.Azero.battle:TameOdds('truesilverrod')") == 1
    throw(w, c, "Truesilver Taming Rod")
    seen = watch(w, c)
    assert seen["lure"] and seen["sigil"] and seen["beams"] and seen["orb"] and seen["stamp"], seen
    assert seen["pips"] == 3 and not seen["cracked"] and seen["sparks"] >= 10, seen
    card = c.eval_py("return ns.AzeroTaming.CardState()")
    assert card and card["name"] == "Owlet" and card["lvl"] == "Lv8" and card["type"] == "AIR", card
    assert card["new"] == "NEW IN BESTIARY" and card["where"] == "Joined your party" and not card["star"], card
    assert card["sprite"] and card["sprite"]["shown"] and card["sprite"]["view"] == "f", card
    for _ in range(20):                                     # the line under it: then A
        if (state(c).get("text") or "") == "Owlet was added to your Bestiary!" and state(c)["msg"]:
            break
        w.tick(0.1)
    assert state(c)["msg"] and state(c).get("text") == "Owlet was added to your Bestiary!", state(c)
    assert state(c)["battle"]                                # (still over the battle until A)
    for _ in range(4):
        key(w, c, "A")
        w.tick(0.1)
        if not state(c)["battle"]:
            break
    assert not state(c)["battle"] and c.eval_py("return ns.AzeroTaming.CardState()") is None
    r = c.eval_py("local s = ns.Azero.save return { caught = s.caught.owlet == true, n = #s.party, sp = s.party[2].sp }")
    assert r == {"caught": True, "n": 2, "sp": "owlet"}, r
    no_errors(w)


@case
def a_beast_that_breaks_free_cracks_the_orb():
    w, c = game()
    wild(w, c, foe="kobling", lvl=8)
    # two checks hold, the third fails (the battle's dice: 0 twice for the checks, then the highest)
    c.eval("""local b = ns.Azero.battle local n, old = 0, b.rng
      b.rng = function(a, z) if a == 0 and z == 65535 then n = n + 1 return n <= 2 and 0 or 65535 end return old(a, z) end""")
    throw(w, c, "Taming Rod")
    seen = watch(w, c)
    assert seen["orb"] and seen["cracked"] and seen["pips"] == 2 and not seen["stamp"], seen
    assert c.eval_py("return ns.AzeroTaming.CardState()") is None
    to_action(w, c)                                         # the battle goes on
    r = c.eval_py("local m = ns.AzeroUI.Kit.R.foeModel return { a = m:GetAlpha(), spr = m.spr:State() }")
    assert r["a"] == 1 and r["spr"]["shrink"] == 1 and r["spr"]["flash"] == 0 and r["spr"]["shown"], r
    st = c.eval_py("return ns.AzeroTaming.State()")
    assert not (st["sigil"] or st["orb"] or st["stamp"] or st["beams"]) and st.get("pips") is None, st
    assert c.eval("return ns.Azero.save.caught.kobling") is None
    no_errors(w)


@case
def a_known_beast_with_a_full_party_goes_to_the_stable():
    w, c = game("""local M, s = ns.AzeroMon, ns.Azero.save
      for i = 2, 6 do s.party[i] = M.New('wolfpup', 5, ns.Azero.rng) end
      s.caught.owlet = true""")
    wild(w, c, foe="owlet", lvl=6)
    c.eval("ns.Azero.battle.foe.mon.hp = 1")
    throw(w, c, "Truesilver Taming Rod")
    watch(w, c)
    card = c.eval_py("return ns.AzeroTaming.CardState()")
    assert card and card.get("new") is None and card["where"] == "Sent to the Stable Master", card
    for _ in range(20):
        if (state(c).get("text") or "") == "Take good care of Owlet!":
            break
        w.tick(0.1)
    assert state(c).get("text") == "Take good care of Owlet!", state(c)
    no_errors(w)


@case
def a_shiny_wears_its_star_on_the_card():
    w, c = game()
    wild(w, c, foe="owlet", lvl=8, shiny=True)
    c.eval("ns.Azero.battle.foe.mon.hp = 1")
    throw(w, c, "Truesilver Taming Rod")
    watch(w, c)
    card = c.eval_py("return ns.AzeroTaming.CardState()")
    assert card and card["star"], card
    assert c.eval("return ns.Azero.save.party[2].shiny") is True
    no_errors(w)


@case
def the_tamed_event_says_what_the_card_needs():
    w, c = game()
    r = c.eval_py(r"""
      local B, M = ns.AzeroBattle, ns.AzeroMon
      local foe = M.New('owlet', 7, ns.Azero.rng)
      foe.hp, foe.shiny = 1, true
      local b = B.New({ party = { M.New('murkling', 10, ns.Azero.rng) }, foes = { foe }, wild = true, rng = math.random,
                        bag = { truesilverrod = 1 }, isNew = function(sp) return sp == 'owlet' end,
                        onCaught = function() return 'box' end })
      while b:Pop() do end
      b:Act({ kind = "item", item = "truesilverrod" })
      local throw, tamed
      while true do
        local e = b:Pop()
        if not e then break end
        if e.t == "throw" then throw = e end
        if e.t == "tamed" then tamed = e end
      end
      return { caught = throw.caught, shiny = throw.shiny, sp = tamed.sp, lvl = tamed.lvl, fresh = tamed.fresh,
               where = tamed.where, tshiny = tamed.shiny, result = b.result }""")
    assert r == {"caught": True, "shiny": True, "sp": "owlet", "lvl": 7, "fresh": True, "where": "box", "tshiny": True,
                 "result": "caught"}, r
    no_errors(w)


if __name__ == "__main__":
    run_all()

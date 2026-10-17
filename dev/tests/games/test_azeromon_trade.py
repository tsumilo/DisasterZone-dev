"""Azeromon: trading with a guildmate.

Covers: A on a guildmate offers Battle or Trade; the trade request, Yes / No, busy players; offers both ways (a new
offer clears acceptances), both acceptances swap the two beasts in place on both clients (original trainer kept,
Bestiary updated, achievements, "tame" as traded); a cancel changes nothing; a Tunneler evolves when traded; a
traded beast earns boosted exp (and a beast back with its original trainer doesn't); bad offers are refused; the
host's commit is honoured by a player who left right after accepting; the trade screen driven through the UI.
Items: offered alongside a beast or alone (a gift), both ways; bounded by the bag and the stack cap; a changed item
offer clears acceptances; items gone from the bag stop the trade; your last beast can't go for nothing; bad item
lists are cleaned; the item picker and the cards through the UI.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_trade.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, no_errors, World, Client  # noqa: E402
from _azero_bot import BOT  # noqa: E402

TRADE_BOT = r"""
local G = ns.Azero
T_TR = { answer = 1 }
-- an unattended player: reads text, answers Yes / No prompts with T_TR.answer; trades wait for the test
function T_TR.tick()
  local p = G.pending
  if not p then return end
  if p.kind == "text" then T_AZ.log[#T_AZ.log + 1] = p.text G:Advance()
  elseif p.kind == "choice" then G:Advance(T_TR.answer)
  elseif p.kind == "wait" or p.kind == "evolve" then G:Update(0.5) end
end
function T_TR.party()
  local out = {}
  for i, m in ipairs(G.save.party) do out[i] = { sp = m.sp, lvl = m.lvl, ot = m.ot, shiny = m.shiny, traded = m.traded } end
  return out
end
"""


def setup(team_a=(("murkling", 12),), team_b=(("emberwhelp", 12),), ui_a=False):
    w = World()
    a, b = Client(w, "Alice", guild_rank=3), Client(w, "Bob", guild_rank=3)
    for c in (a, b):
        c.load_addon()
    w.tick(3)
    for c, team, x in ((a, team_a, 8), (b, team_b, 9)):
        c.eval(BOT)
        c.eval(TRADE_BOT)
        c.slash("/dz play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        for _ in range(40):
            w.tick(0.3)
            c.eval("ns.AzeroUI._HandleKey('A')")
            if not c.eval("return ns.Azero.pending ~= nil"):
                break
        if not (ui_a and c is a):
            c.eval("ns.AzeroUI._Detach()")
        mons = ", ".join("M.New(%r, %d, G.rng)" % t for t in team)
        c.eval("local G, M = ns.Azero, ns.AzeroMon; G:EnterMap('town', %d, 9, %r, true); G.save.party = { %s }"
               % (x, "right" if x == 8 else "left", mons))
    run(w, (a, b), seconds=2)
    return w, a, b


def run(w, clients, seconds=3, step=0.3, bots=None):
    for _ in range(int(seconds / step)):
        for c in clients:
            if bots is None or c in bots:
                c.eval("T_TR.tick()")
            c.eval("ns.AzeroNet:Update(0.3); ns.AzeroTrade:Update()")
        w.tick(step)


def open_trade(w, a, b):
    a.eval("ns.Azero:PressA()")                   # facing Bob
    text = a.eval("return ns.Azero.pending and ns.Azero.pending.text") or ""
    assert "Challenge Bob" in text and "trade" in text, text
    a.eval("ns.Azero:Advance(2)")                 # Trade -> waiting for Bob
    assert a.eval("return ns.Azero.pending.kind") == "netwait"
    run(w, (a, b), seconds=1.5, bots=(b,))        # Bob: Yes
    for c in (a, b):
        assert c.eval("return ns.Azero.pending and ns.Azero.pending.kind") == "trade", c.eval("return ns.Azero.pending and ns.Azero.pending.kind")


def log(c):
    return "\n".join(c.eval_py("return T_AZ.log") or [])


@case
def a_trade_swaps_the_two_beasts_on_both_sides():
    w, a, b = setup(team_a=(("murkling", 12), ("owlet", 5)), team_b=(("emberwhelp", 14),))
    a.eval("ns.Azero.save.party[1].shiny = true")
    open_trade(w, a, b)
    a.eval("ns.AzeroTrade:Offer(1)")
    b.eval("ns.AzeroTrade:Offer(1)")
    run(w, (a, b), seconds=0.6, bots=())
    assert a.eval("return ns.AzeroTrade.session.theirs.sp") == "emberwhelp"
    assert b.eval("return ns.AzeroTrade.session.theirs.sp") == "murkling"
    a.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=0.6, bots=())
    assert a.eval("return ns.AzeroTrade.session and ns.AzeroTrade.session.state") == "open"   # Bob hasn't accepted
    b.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=3)
    pa, pb = a.eval_py("return T_TR.party()"), b.eval_py("return T_TR.party()")
    assert pa[0]["sp"] == "emberwhelp" and pa[0]["ot"] == "Bob" and pa[0]["traded"] is True, pa
    assert pa[1]["sp"] == "owlet", pa                                   # the rest of the party stays
    assert pb[0]["sp"] == "murkling" and pb[0]["ot"] == "Alice" and pb[0]["shiny"] is True, pb
    assert a.eval("return ns.Azero.save.caught.emberwhelp") and b.eval("return ns.Azero.save.shinyCaught.murkling")
    assert "Bob sent over Emberwhelp!" in log(a) and "Alice sent over Murkling!" in log(b)
    for c in (a, b):
        assert c.eval("return ns.AzeroAch.Earned().trade1 ~= nil")
        assert c.eval("return ns.AzeroTrade.session == nil and ns.Azero.pending == nil")
    assert a.eval("return ns.AzeroAch.Stat('caught')") == 0            # a traded beast isn't a tame
    no_errors(w)


@case
def a_new_offer_clears_the_acceptances():
    w, a, b = setup(team_b=(("emberwhelp", 14), ("coyote", 10)))
    open_trade(w, a, b)
    a.eval("ns.AzeroTrade:Offer(1)")
    b.eval("ns.AzeroTrade:Offer(1)")
    run(w, (a, b), seconds=0.6, bots=())
    a.eval("ns.AzeroTrade:Confirm()")
    b.eval("ns.AzeroTrade:Offer(2)")                                  # Bob switches to the coyote
    run(w, (a, b), seconds=0.6, bots=())
    assert a.eval("return ns.AzeroTrade.session.myOk == nil")         # Alice must accept again
    b.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=0.6, bots=())
    assert a.eval("return ns.Azero.save.party[1].sp") == "murkling"   # nothing yet
    a.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=3)
    assert a.eval("return ns.Azero.save.party[1].sp") == "coyote"
    assert [m["sp"] for m in b.eval_py("return T_TR.party()")] == ["emberwhelp", "murkling"]
    no_errors(w)


@case
def a_cancel_changes_nothing():
    w, a, b = setup()
    open_trade(w, a, b)
    a.eval("ns.AzeroTrade:Offer(1)")
    b.eval("ns.AzeroTrade:Offer(1)")
    run(w, (a, b), seconds=0.6, bots=())
    a.eval("ns.AzeroTrade:Confirm()")
    b.eval("ns.AzeroTrade:Cancel()")
    run(w, (a, b), seconds=3)
    assert a.eval("return ns.Azero.save.party[1].sp") == "murkling"
    assert b.eval("return ns.Azero.save.party[1].sp") == "emberwhelp"
    assert "Bob left the trade." in log(a) and "The trade was cancelled." in log(b)
    no_errors(w)


@case
def a_tunneler_evolves_when_traded():
    w, a, b = setup(team_a=(("tunneler", 18),))
    open_trade(w, a, b)
    a.eval("ns.AzeroTrade:Offer(1)")
    b.eval("ns.AzeroTrade:Offer(1)")
    run(w, (a, b), seconds=0.6, bots=())
    a.eval("ns.AzeroTrade:Confirm()")
    b.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=10)                  # (the evolution animation plays)
    assert b.eval("return ns.Azero.save.party[1].sp") == "geomancer"
    assert b.eval("return ns.Azero.save.caught.geomancer") is True
    assert "What? Kobold Tunneler is evolving!" in log(b) and "evolved into Kobold Geomancer" in log(b)
    # it never evolves by level
    assert b.eval("local M = ns.AzeroMon return M.EvolutionTarget(M.New('tunneler', 60, ns.Azero.rng)) == nil")
    no_errors(w)


@case
def a_busy_player_is_not_bothered():
    w, a, b = setup()
    b.eval("ns.Azero:Run(function(g) g:Say('Busy reading.') end)")
    a.eval("ns.Azero:PressA()")
    a.eval("ns.Azero:Advance(2)")
    run(w, (a, b), seconds=1.5, bots=(a,))
    assert "Bob is busy right now." in log(a)
    assert b.eval("return ns.AzeroTrade.session == nil")
    no_errors(w)


@case
def bad_offers_are_refused():
    w, a, b = setup()
    open_trade(w, a, b)
    sid = b.eval("return ns.AzeroTrade.session.id")
    for wire in ("{ sp = 'hogger', lvl = 20 }", "{ sp = 'nothing', lvl = 5 }", "'garbage'"):
        b.eval("ns.Comm:Send({ t = 'AZT', op = 'offer', id = %r, mon = %s }, 'WHISPER', 'Alice-Thunderstrike', 'game')"
               % (sid, wire))
        run(w, (a, b), seconds=0.6, bots=())
        assert a.eval("return ns.AzeroTrade.session.theirs == nil"), wire
    # a beast "from the future": exp beyond its level is trimmed, bad moves dropped
    mon = a.eval_py("""local w = { sp = 'owlet', lvl = 10, exp = 1e9, ivs = { 99, -5 }, moves = { { id = 'nope', pp = 5 }, { id = 'kdive', pp = 99 } } }
      local m = ns.AzeroTrade.Unpack(w)
      return { exp = m.exp, cap = ns.AzeroMon.ExpForLevel(11), iv1 = m.ivs[1], iv2 = m.ivs[2], n = #m.moves, pp = m.moves[1].pp }""")
    assert mon["exp"] < mon["cap"] and mon["iv1"] == 31 and mon["iv2"] == 0 and mon["n"] == 1 and mon["pp"] == 35, mon
    no_errors(w)


@case
def the_hosts_commit_is_honoured_after_a_late_cancel():
    # Alice is the host (her key sorts first): she accepts, then Bob accepts and leaves in the same instant
    w, a, b = setup()
    assert a.eval("return ns.AzeroTrade.session == nil")
    open_trade(w, a, b)
    assert a.eval("return ns.AzeroTrade.session.host") is True
    a.eval("ns.AzeroTrade:Offer(1)")
    b.eval("ns.AzeroTrade:Offer(1)")
    run(w, (a, b), seconds=0.6, bots=())
    a.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=0.6, bots=())
    b.eval("ns.AzeroTrade:Confirm() ns.AzeroTrade:Cancel()")
    run(w, (a, b), seconds=3)
    assert a.eval("return ns.Azero.save.party[1].sp") == "emberwhelp"
    assert b.eval("return ns.Azero.save.party[1].sp") == "murkling"      # swapped after all: nothing lost
    no_errors(w)


@case
def traded_beasts_earn_boosted_exp():
    w, a, b = setup()
    r = a.eval_py(r"""local G, M = ns.Azero, ns.AzeroMon
      local mine = M.New('murkling', 10, G.rng)
      local traded = M.New('coyote', 10, G.rng); traded.traded = true
      G.save.party = { traded, mine }
      local b = ns.AzeroBattle.New({ party = G.save.party, foes = { M.New('wolfpup', 2, G.rng) }, wild = true, rng = G.rng })
      local e0 = traded.exp
      b.foe.participants = { [1] = true }
      b:AwardExp()
      local texts = {}
      local e = b:Pop()
      while e do if e.t == 'text' then texts[#texts + 1] = e.text end e = b:Pop() end
      return { texts = texts, gain = traded.exp - e0 }""")
    boosted = [t for t in r["texts"] if "boosted" in t]
    assert boosted, r
    # back with its original trainer: no longer "traded"
    back = a.eval_py("""local T = ns.AzeroTrade
      local w = T.Pack(ns.AzeroMon.New('owlet', 5, ns.Azero.rng))
      w.ot = ns.Azero:PlayerName()
      local m = T.Unpack(w)
      return { ot = m.ot, traded = m.traded == nil }""")
    assert back["traded"] is True, back
    no_errors(w)


@case
def the_trade_screen_through_the_ui():
    w, a, b = setup(ui_a=True)
    a.eval("ns.AzeroUI._HandleKey('A')")                  # talk to Bob
    w.tick(0.3)
    a.eval("ns.AzeroUI._HandleKey('down')")               # Trade
    a.eval("ns.AzeroUI._HandleKey('A')")
    run(w, (a, b), seconds=1.5, bots=(b,))
    w.tick(0.3)
    t = a.eval_py("return ns.AzeroUI._Trade()")
    assert t and t["status"].startswith("Offer a beast or items.") and t["cards"][1]["label"] == "BOB OFFERS", t
    a.eval("ns.AzeroUI._HandleKey('A')")                  # Offer a beast
    w.tick(0.1)
    assert a.eval_py("return ns.AzeroUI._Levels()")[-1]["title"].startswith("OFFER WHICH BEAST?")
    a.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.1)
    t = a.eval_py("return ns.AzeroUI._Trade()")
    assert t["cards"][0]["name"] == "Murkling" and t["cards"][0]["info"].startswith("Lv12"), t
    assert "Nothing from Bob yet." in t["status"], t
    b.eval("ns.AzeroTrade:Offer(1)")
    run(w, (a, b), seconds=0.6, bots=())
    t = a.eval_py("return ns.AzeroUI._Trade()")
    assert t["cards"][1]["name"] == "Emberwhelp" and t["status"] == "Both offers are on the table. Trade?", t
    a.eval("ns.AzeroUI._HandleKey('down')")
    a.eval("ns.AzeroUI._HandleKey('down')")
    a.eval("ns.AzeroUI._HandleKey('A')")                  # Trade
    w.tick(0.1)
    assert "Waiting for Bob to accept" in a.eval_py("return ns.AzeroUI._Trade()")["status"]
    b.eval("ns.AzeroTrade:Confirm()")
    for _ in range(30):
        run(w, (a, b), seconds=0.3, bots=(b,))
        if a.eval("return ns.Azero.pending == nil"):
            break
        a.eval("ns.AzeroUI._HandleKey('A')")
    assert a.eval("return ns.AzeroUI._Trade()") is None
    assert a.eval("return ns.Azero.save.party[1].sp") == "emberwhelp"
    no_errors(w)


def bags(c):
    return c.eval_py("local o = {} for k, v in pairs(ns.Azero.save.bag) do o[k] = v end return o")


@case
def items_travel_with_a_beast_both_ways():
    w, a, b = setup(team_a=(("murkling", 12), ("owlet", 5)), team_b=(("emberwhelp", 14),))
    a.eval("ns.Azero.save.bag = { copperbar = 5, peacebloom = 2 }")
    b.eval("ns.Azero.save.bag = { lionsstrength = 1 }")
    open_trade(w, a, b)
    a.eval("ns.AzeroTrade:Offer(1)")
    assert a.eval("return ns.AzeroTrade:OfferItem('copperbar', 3)") == 3
    assert a.eval("return ns.AzeroTrade:OfferItem('copperbar', 9)") == 5            # only what's in the bag
    assert a.eval("return ns.AzeroTrade:OfferItem('copperbar', -1)") == 4
    b.eval("ns.AzeroTrade:Offer(1) ns.AzeroTrade:OfferItem('lionsstrength', 1)")
    run(w, (a, b), seconds=0.6, bots=())
    assert b.eval_py("return ns.AzeroTrade.session.theirItems") == {"copperbar": 4}
    a.eval("ns.AzeroTrade:Confirm()")
    b.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=3)
    assert bags(a) == {"copperbar": 1, "peacebloom": 2, "lionsstrength": 1}, bags(a)
    assert bags(b) == {"copperbar": 4}, bags(b)
    assert a.eval("return ns.Azero.save.party[1].sp") == "emberwhelp"
    assert "You gave Bob: Copper Bar x4." in log(a) and "Bob gave you Elixir of Lion's Strength." in log(a), log(a)
    assert "Alice gave you Copper Bar x4." in log(b), log(b)
    no_errors(w)


@case
def items_alone_are_a_gift():
    w, a, b = setup(team_a=(("murkling", 12),), team_b=(("emberwhelp", 14),))
    a.eval("ns.Azero.save.bag = { tinbar = 2 }")
    b.eval("ns.Azero.save.bag = {}")
    open_trade(w, a, b)
    assert a.eval_py("return { ns.AzeroTrade:Confirm() }") == [False, "empty"]
    a.eval("ns.AzeroTrade:OfferItem('tinbar', 2)")
    run(w, (a, b), seconds=0.6, bots=())
    a.eval("ns.AzeroTrade:Confirm()")
    b.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=3)
    assert bags(a) == {} and bags(b) == {"tinbar": 2}, (bags(a), bags(b))
    for c in (a, b):                                                                   # the beasts stay
        assert len(c.eval_py("return T_TR.party()")) == 1
    no_errors(w)


@case
def a_beast_for_items_goes_to_the_party_or_the_stable():
    w, a, b = setup(team_a=(("murkling", 12), ("owlet", 5)),
                    team_b=tuple(("coyote", 5) for _ in range(6)))
    b.eval("ns.Azero.save.bag = { copperbar = 10 }")
    open_trade(w, a, b)
    a.eval("ns.AzeroTrade:Offer(2)")
    b.eval("ns.AzeroTrade:OfferItem('copperbar', 10)")
    run(w, (a, b), seconds=0.6, bots=())
    a.eval("ns.AzeroTrade:Confirm()")
    b.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=3)
    assert [m["sp"] for m in a.eval_py("return T_TR.party()")] == ["murkling"]
    assert bags(a).get("copperbar") == 10, bags(a)
    assert len(b.eval_py("return T_TR.party()")) == 6
    assert b.eval("return ns.Azero.save.box[#ns.Azero.save.box].sp") == "owlet"
    no_errors(w)


@case
def item_offers_are_checked():
    w, a, b = setup(team_b=(("emberwhelp", 12), ("coyote", 8)))
    a.eval("ns.Azero.save.bag = { copperbar = 5, tinbar = 1, peacebloom = 1, silverleaf = 1, earthroot = 1, "
           "mageroyal = 1, briarthorn = 1 }")
    open_trade(w, a, b)
    # the last beast can't go for nothing
    a.eval("ns.AzeroTrade:Offer(1)")
    assert a.eval_py("return { ns.AzeroTrade:Confirm() }") == [False, "last"]
    a.eval("ns.AzeroTrade:Offer(1)")                                                   # again: taken back
    assert a.eval("return ns.AzeroTrade.session.mine == nil")
    # at most MAX_STACKS kinds
    for it in ("copperbar", "tinbar", "peacebloom", "silverleaf", "earthroot", "mageroyal"):
        a.eval("ns.AzeroTrade:OfferItem(%r, 1)" % it)
    assert a.eval("return ns.AzeroTrade:OfferItem('briarthorn', 1)") == 0
    # a changed item offer clears acceptances
    b.eval("ns.AzeroTrade:Offer(1)")
    run(w, (a, b), seconds=0.6, bots=())
    b.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=0.6, bots=())
    assert a.eval("return ns.AzeroTrade.session.theirOk ~= nil")
    a.eval("ns.AzeroTrade:OfferItem('copperbar', 1)")
    run(w, (a, b), seconds=0.6, bots=())
    assert b.eval("return ns.AzeroTrade.session.myOk == nil")
    # items gone from the bag by the time it commits: nothing changes
    a.eval("ns.Azero.save.bag.copperbar = 1")
    a.eval("ns.AzeroTrade:Confirm()")
    b.eval("ns.AzeroTrade:Confirm()")
    run(w, (a, b), seconds=3)
    assert a.eval("return ns.Azero.save.party[1].sp") == "murkling"
    assert b.eval("return ns.Azero.save.bag.copperbar") is None
    # bad lists from the wire are cleaned
    clean = a.eval_py("""return ns.AzeroTrade.CleanItems({ copperbar = 500, nope = 3, tinbar = -2, peacebloom = 1.7,
      [5] = 1, silverleaf = 'x' })""")
    assert clean == {"copperbar": 99, "peacebloom": 1}, clean
    no_errors(w)


@case
def offering_items_through_the_ui():
    w, a, b = setup(ui_a=True)
    a.eval("ns.Azero.save.bag = { copperbar = 3 }")
    a.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    a.eval("ns.AzeroUI._HandleKey('down')")
    a.eval("ns.AzeroUI._HandleKey('A')")
    run(w, (a, b), seconds=1.5, bots=(b,))
    w.tick(0.3)
    a.eval("ns.AzeroUI._HandleKey('down')")               # Offer items
    a.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.1)
    lv = a.eval_py("return ns.AzeroUI._Levels()")[-1]
    assert lv["title"] == "OFFER ITEMS", lv
    assert a.eval_py("return ns.AzeroUI._MenuItems()") == ["Take back all items", "Copper Bar"]
    a.eval("ns.AzeroUI._HandleKey('down')")
    for _ in range(2):
        a.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.1)
    t = a.eval_py("return ns.AzeroUI._Trade()")
    assert t["cards"][0]["name"] == "Items" and t["cards"][0]["moves"] == "Copper Bar x2", t
    a.eval("ns.AzeroUI._HandleKey('B')")                  # back to the trade menu, then add a beast
    a.eval("ns.AzeroUI._HandleKey('up')")
    a.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.1)
    a.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.1)
    t = a.eval_py("return ns.AzeroUI._Trade()")
    assert t["cards"][0]["name"] == "Murkling" and t["cards"][0]["items"] == "+ Copper Bar x2", t
    b.eval("ns.AzeroTrade:Offer(1)")
    run(w, (a, b), seconds=0.6, bots=())
    for k in ("down", "down", "A"):
        a.eval("ns.AzeroUI._HandleKey(%r)" % k)
    b.eval("ns.AzeroTrade:Confirm()")
    for _ in range(30):
        run(w, (a, b), seconds=0.3, bots=(b,))
        if a.eval("return ns.Azero.pending == nil"):
            break
        a.eval("ns.AzeroUI._HandleKey('A')")
    assert bags(a) == {"copperbar": 1} and bags(b).get("copperbar") == 2, (bags(a), bags(b))
    no_errors(w)


if __name__ == "__main__":
    run_all()

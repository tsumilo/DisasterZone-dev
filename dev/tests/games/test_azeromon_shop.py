"""Azeromon: selling to shops.

Covers: what a shop pays (an item's own sell value, else half its price, nothing for free goods); selling takes the
items and pays the coins (the "sell" event), refuses what you don't have; the shop screen titled by its keeper with a
Sell entry; the SELL list (only what they buy, count and price each, names clear of the prices), a quantity picker, the coins arriving and the
list refreshed.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_shop.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def game(ui=False):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(4)")
    c.eval("ns.Azero:NewGame()")
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('murkling', 12, ns.Azero.rng), 'caught')")
    if ui:
        c.slash("/dz play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.3)
        c.eval("T_AZ.settle()")
    return w, c


def key(w, c, *keys):
    for k in keys:
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.05)


def title(c):
    lv = c.eval_py("return ns.AzeroUI._Levels()") or []
    return lv[-1]["title"] if lv else None


def pick(w, c, text):
    """Moves the top menu's cursor to the entry `text` and selects it."""
    items = c.eval_py("return ns.AzeroUI._MenuItems()")
    assert text in items, items
    key(w, c, *(["down"] * items.index(text)), "A")


@case
def what_a_shop_pays():
    w, c = game()
    r = c.eval_py("""local G = ns.Azero
      return { bar = G:SellPrice('copperbar'), potion = G:SellPrice('potion'), dust = G:SellPrice('illusiondust'),
               price = ns.AzeroData.items.potion.price, nope = G:SellPrice('nothing') }""")
    assert r["bar"] == 30 and r["dust"] == 250 and r["nope"] == 0, r
    assert r["potion"] == r["price"] // 2, r
    no_errors(w)


@case
def selling_takes_the_goods_and_pays():
    w, c = game()
    c.eval("""local G = ns.Azero
      G.save.bag = { copperbar = 5 } G.save.money = 100
      T_SOLD = {} G:On('sell', function(g, e) T_SOLD[#T_SOLD + 1] = e.money end)""")
    r = c.eval_py("return { ns.Azero:Sell('copperbar', 3) }")
    assert r == [True, "Sold Copper Bar x3 for 90c."], r
    assert c.eval("return ns.Azero.save.money") == 190 and c.eval("return ns.Azero.save.bag.copperbar") == 2
    assert c.eval_py("return T_SOLD") == [90]
    assert c.eval_py("return { ns.Azero:Sell('copperbar', 3) }") == [False, "You don't have that many."]
    assert c.eval_py("return { ns.Azero:Sell('copperbar', 2) }")[0] is True
    assert c.eval("return ns.Azero.save.bag.copperbar") is None                   # the stack is gone
    no_errors(w)


@case
def selling_through_the_shop_screen():
    w, c = game(ui=True)
    c.eval("ns.Azero.save.bag = { copperbar = 4, peacebloom = 1 } ns.Azero.save.money = 0")
    c.eval("ns.Azero:EnterMap('post', 7, 3, 'up', true)")
    key(w, c, "A")                                             # Brog Hamfist
    for _ in range(10):
        if title(c) == "BROG HAMFIST":
            break
        key(w, c, "A")
    assert title(c) == "BROG HAMFIST", title(c)
    pick(w, c, "Sell")
    assert title(c) == "SELL"
    assert c.eval_py("return ns.AzeroUI._MenuItems()") == ["Peacebloom", "Copper Bar"]
    assert "Sells for 12c each." in c.eval("return ns.AzeroUI._DescText()")
    for row in c.eval_py("return ns.AzeroUI._MenuLayout()")["rows"]:     # long names stop short of the prices
        assert row["textEnd"] <= row["rightStart"] - 4, row
    pick(w, c, "Copper Bar")
    assert title(c) == "HOW MANY?"
    assert c.eval_py("return ns.AzeroUI._MenuItems()") == ["x4   1s 20c"]
    key(w, c, "left")
    assert c.eval_py("return ns.AzeroUI._MenuItems()") == ["x3   90c"]
    key(w, c, "A")
    assert c.eval("return ns.Azero.save.money") == 90 and c.eval("return ns.Azero.save.bag.copperbar") == 1
    key(w, c, "A")                                             # "Sold Copper Bar x3 for 90c."
    assert title(c) == "SELL"
    items = c.eval_py("return ns.AzeroUI._MenuLayout()")
    assert items["n"] == 2, items                              # refreshed: one Copper Bar left
    no_errors(w)


if __name__ == "__main__":
    run_all()

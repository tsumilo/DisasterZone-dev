"""Shared helpers of the strategy board suites (Addendum K)."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "raidplan"))
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(TESTS, "loot-roll"))

from rp_common import world, K, DAY, REALM, now, create, signup, team  # noqa: E402,F401

GUILD_KEY = "Casual Disaster-Thunderstrike"

# Illidari Council, roughly as the guild's sheet has it: a tank block (player + boss target), a hunter-only misdirect
# block with an order column, an open zone block and a text-only notes block; a second page reuses the tank slots.
COUNCIL = """
return {
  b = 'BlackTemple:Council', n = '25 farm',
  p = {
    { id = 'p1', n = 'P1', m = 0, vx = 500, vy = 500, vz = 100,
      e = {
        { t = 'z', s = 'c', x = 300, y = 250, w = 120, h = 120, c = 1, l = 'Move out Flamestrike' },
        { t = 'z', s = 'r', x = 500, y = 400, w = 200, h = 150, c = 3, l = 'Zone 1', ln = 'zn.1' },
        { t = 'a', x = 100, y = 100, x2 = 200, y2 = 150, c = 2, h = true },
        { t = 'i', x = 700, y = 300, i = 'rt8', z = 24 },
        { t = 'x', x = 800, y = 500, l = 'Major Nature Protection Potion', z = 2 },
        { t = 's', x = 450, y = 200, r = 'tk.1.1' },
      },
      k = {
        { id = 'tk', n = 'Tanks', r = 2, c = { { t = 'p', n = 'Player', f = 'tank' }, { t = 'g', n = 'Boss' } },
          d = { [1] = { [2] = { i = 'rt8', l = 'Gathios' } }, [2] = { [2] = { i = 'rt7', l = 'Veras' } } } },
        { id = 'md', n = 'Misdirects', r = 2, c = { { t = 'o' }, { t = 'p', n = 'Hunter', f = 'HUNTER' },
          { t = 'g', n = 'Tank', } },
          d = { [1] = { [3] = { s = 'tk.1.1' } }, [2] = { [3] = { s = 'tk.2.1' } } } },
        { id = 'zn', n = 'Zones', r = 3, c = { { t = 'p', n = 'Zone 1' }, { t = 'p', n = 'Zone 2' } } },
        { id = 'nt', n = 'Notes', r = 1, c = { { t = 'x' } }, d = { [1] = { [1] = 'BoP mage tank' } } },
      } },
    { id = 'p2', n = 'P2', m = 0, no = 'Dampen magic pre-pull', e = { { t = 's', x = 100, y = 100, r = 'tk.2.1' } }, k = {} },
  },
}
"""


def save_council(cl, name=None):
    res = cl.eval_py("local d = (loadstring(...))(); if select(2, ...) then d.n = select(2, ...) end;"
                     " local ok, r = ns.Strategy:SaveStrategy(d); return { ok = ok, r = r }", COUNCIL, name)
    assert res["ok"] is True, res
    return res["r"]


def strategies(cl, boss=None):
    return cl.eval_py("return ns.Strategy:GetStrategies(...)", boss)


def fill(cl, occ, boss, sid, a):
    res = cl.eval_py("local o, b, s, a = ...; local ok, e = ns.Strategy:SaveFill(o, b, s, a); return { ok = ok, e = e }",
                     occ, boss, sid, a)
    return res


def get_fill(cl, occ, boss):
    return cl.eval_py("return ns.Strategy:GetFill(...)", occ, boss)

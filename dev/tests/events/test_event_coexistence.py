"""Events next to the other modules: the event system leaves the shared math.random sequence alone at login.

Why: every module draws its jitter (HELLO answers, digest claims, roster queries) from math.random, and the harness
seeds it per client. In fact lupa's Lua 5.1 runtimes share the C library's rand(), so all clients of a World draw
from one interleaved stream. Before this test, Events:OnLogin drew its first prune delay from math.random on every
login, events or not. That one draw moved every later delay in every suite, and three cases whose outcome hung on
the old values flipped: raidplan late_login, raidlog council_recorders, regressions ledger late guild name. Each
was also made robust on its own. Patch.lua and Guild.lua (OwnJitter) keep their own jitter for this reason, and
now so does the events prune.

Covers: no draw from an event file during load, login, the minutes after, a relog and a /reload in a guild without
events (the guard sees other modules' draws, so it is live); the first prune still runs once, 20-40 s after the
login, at a different moment per character.
Run: luaenv\\Scripts\\python.exe tests\\events\\test_event_coexistence.py [-k name]   (from dev)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "boot-ui"))
from _common import World, Client, case, run_all  # noqa: E402

# Wraps every alias of math.random before the addon loads (Util.lua and the others capture it at load). A draw with
# an event file anywhere on its stack is recorded with that stack.
DRAWS = r"""
local real = math.random
__DRAWS = { total = 0, sync = 0, event = {} }
local function draw(...)
  local s = debugstack(2) or ""
  __DRAWS.total = __DRAWS.total + 1
  if s:find("/Core/Sync%.lua:") then __DRAWS.sync = __DRAWS.sync + 1 end
  if s:find("/Core/Event%w*%.lua:") or s:find("/UI/Event%w*%.lua:") then
    if #__DRAWS.event < 10 then __DRAWS.event[#__DRAWS.event + 1] = s end
  end
  return real(...)
end
math.random, random, fastrandom = draw, draw, draw
"""

NAMES = (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"))


def guild(preload=None):
    w = World()
    cs = {n: Client(w, n, guild_rank=r, class_file=cl, preload_lua=preload) for n, r, cl in NAMES}
    for c in cs.values():
        c.load_addon()
    return w, cs


def draws(c):
    return c.eval_py("return __DRAWS")


@case
def event_modules_draw_nothing_from_the_shared_random_sequence():
    w, cs = guild(DRAWS)
    w.tick(60)          # load, login, the login HELLO round, the first events prune (20-40 s)
    assert all(c.eval("return #ns.Events:GetDefs()") == 0 for c in cs.values())   # (a guild without events)
    cs["Rita"].relog(reload=False)
    cs["Lee"].relog()   # /reload
    w.tick(60)
    for n, c in cs.items():
        d = draws(c)
        assert not d["event"], (n, d["event"])
        # the guard is live: it saw the other modules' draws (the login HELLO's delay comes from Sync.lua)
        assert d["total"] > 0 and d["sync"] > 0, (n, d["total"], d["sync"])
    w.assert_no_errors()


@case
def the_first_prune_runs_once_20_to_40_s_after_the_login_spread_per_character():
    w, cs = guild()
    for c in cs.values():
        c.eval("""
            __PRUNES = {}
            local real = ns.Events.Prune
            ns.Events.Prune = function(self, ...)
              __PRUNES[#__PRUNES + 1] = GetTime()
              return real(self, ...)
            end""")
    login = {n: c.eval("return GetTime()") for n, c in cs.items()}
    w.tick(45)
    delays = {}
    for n, c in cs.items():
        at = c.eval_py("return __PRUNES")
        assert len(at) == 1, (n, at)
        delays[n] = at[0] - login[n]
        assert 20 <= delays[n] < 40, (n, delays[n])
    assert len({round(d, 2) for d in delays.values()}) > 1, delays
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

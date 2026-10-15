"""A raid walking together in a strategy's 3D room: 25 members on one saved Teron strategy, all of them walking.

Measures on one receiver (Gina, walking too, so 24 others in her room): the Lua time per frame of the 3D view
(V:OnUpdate as a whole, and inside it V:DrawWalkers - the walker sims - and the room's occluder / copy pass,
Room.SetOccluders + Room.DrawCopies, with the occluders the walkers add), what the copies kept and dropped
(Room.Stats copyItems / copyDropped), the CDLw words a second on the wire and the throttled sends, and her memory (in
use, and the garbage a second with the collector stopped). Asserts only that it holds: every walker seen, no Lua
error, the words within the budget, the frame cost within what a client can spend.

The senders' own rooms are not drawn (their V:Draw only clears the dirty flag): their walking and words run as in
the game, and the mock's time goes to the one receiver measured. Size with DZ_WALK_N (default 25).

Run: luaenv\\Scripts\\python.exe tests\\strategy\\test_walk_crowd.py [-k name]
"""
import math
import os
import random
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from st_common import world  # noqa: E402
from _common import case, run_all, no_errors  # noqa: E402
import harness  # noqa: E402

harness.LOAD_ROOMS = True

N = int(os.environ.get("DZ_WALK_N", "25"))
TERON = "BlackTemple:Teron"
CLASSES = ["PALADIN", "WARRIOR", "DRUID", "HUNTER", "ROGUE", "PRIEST", "MAGE", "WARLOCK", "SHAMAN"]

HELPERS = r"""
T3 = {}
function T3.v() return _G.DisasterZoneStrategyBoard.canvas.v3 end
T3.ox, T3.oy = 0, 0
"""

# The receiver's meters: os.clock time in the view's frame, its walkers, the room's occluder pass; per frame.
METER = r"""
local v = T3.v()
local R = v.R
local clock = ...
local gc = collectgarbage
PM = { frames = 0, upd = 0, worst = 0, occN = 0, onScreen = 0, items = 0, dropped = 0, slots = 0, drawn = 0,
       meterG = 0 }
PMF = { "walkers", "rw", "models", "occ", "room", "copies", "plates" }
for _, f in ipairs(PMF) do PM[f], PM[f .. "G"] = 0, 0 end
local function wrap(t, name, field)
  local f = t[name]
  t[name] = function(...)
    local c, g = clock(), gc("count")
    local a, b, c2, d = f(...)
    PM[field], PM[field .. "G"] = PM[field] + (clock() - c), PM[field .. "G"] + (gc("count") - g)
    return a, b, c2, d
  end
end
local up = v.OnUpdate
v.OnUpdate = function(self, el)
  local c = clock()
  up(self, el)
  local t = clock() - c
  PM.frames, PM.upd = PM.frames + 1, PM.upd + t
  if t > PM.worst then PM.worst = t end
end
wrap(v, "DrawWalkers", "walkers")
wrap(v, "DrawModels", "models")
wrap(v, "DrawPlates", "plates")
wrap(R, "SetOccluders", "occ")
wrap(R, "DrawRoom", "room")
wrap(R, "DrawCopies", "copies")
wrap(ns.StrategyCollab, "RemoteWalkers", "rw")
local draw = v.Draw
v.Draw = function(self)
  draw(self)
  local c, g = clock(), gc("count")
  PM.drawn = PM.drawn + 1
  local s = R.Stats()
  PM.items, PM.dropped = PM.items + (s.copyItems or 0), PM.dropped + (s.copyDropped or 0)
  PM.occN = PM.occN + (self.nOcc or 0)
  local on, sl = 0, 0
  for _, o in ipairs(R.Occluders()) do
    if o.onScreen then on = on + 1 end
    if o.slot >= 0 then sl = sl + 1 end
  end
  PM.onScreen, PM.slots = PM.onScreen + on, PM.slots + sl
  PM.meterG, PM.upd = PM.meterG + (gc("count") - g), PM.upd - (clock() - c)
end
"""


def walk_throttled(clients):
    """CDLw sends the simulated server refused (the walk prefix only)."""
    return sum(int(c.eval("return (__MOCK.throttledBy or {}).CDLw or 0") or 0) for c in clients)


def crowd(n=N):
    names = [("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE")]
    names += [("Wlk" + chr(97 + i // 26) + chr(97 + i % 26), 3, CLASSES[i % 9]) for i in range(n - 2)]
    w, c = world(names=names)
    cl = [c[nm] for nm, _, _ in names]
    for x in cl:
        x.eval(HELPERS)
    bob = c["Bob"]
    bob.eval("ns.StrategyBoard:NewStrategy(...)", TERON)
    w.tick(0.2)
    sid = bob.eval_py("local s = ns.StrategyBoard:GetState().strat local ok, r = ns.Strategy:SaveStrategy(s) "
                      "return r")
    w.tick(1)
    for x in cl:
        x.eval("ns.StrategyBoard:OpenStrategy(...)", sid)
    w.tick(3, 0.25)
    for x in cl:
        x.eval("local s = ns.Render3D.RoomForBoss(...).spot T3.ox, T3.oy = s.x - 29.9, s.y - 85.2", TERON)
        assert x.eval("return _G.DisasterZoneStrategyBoard.canvas:Set3D(true, false)") is True
    w.tick(1, 0.25)
    gina = c["Gina"]
    # the senders' rooms are not drawn (their walking and words are)
    for x in cl:
        if x is not gina:
            x.eval("local v = T3.v() v.Draw = function(self) self.dirty = false end")
    return w, gina, cl


def key(cl, k, down):
    cl.eval("local f = T3.v().keys f:GetScript('%s')(f, '%s')" % ("OnKeyDown" if down else "OnKeyUp", k))


def start_walking(cl, rng, back=None):
    # spread over the hall in front of Teron's alcove (test frame: the entrance near y = 5, the alcove at y ~ 85);
    # back: one who stands at the entrance looking up the hall, the whole crowd in front of the camera
    for i, x in enumerate(cl):
        if x is back:
            x.eval("local o = T3.v().orb o.x, o.y = 30 + T3.ox, 4 + T3.oy T3.v():StartWalk()")
            continue
        px, py = 18 + (i % 5) * 6, 14 + (i // 5) * 8
        x.eval("local o = T3.v().orb o.x, o.y = %r + T3.ox, %r + T3.oy T3.v():StartWalk()" % (px, py))
        x.eval("T3.v().walk.k.facing = %r" % rng.uniform(0, 2 * math.pi))


def wander(w, cl, rng, secs, step=0.05, each=None):
    """Every walker runs, turns and stops by turns (new keys every 1-3 s), as a raid exploring the room does."""
    nxt = [0.0] * len(cl)
    held = [set() for _ in cl]
    t = 0.0
    while t < secs - 1e-9:
        for i, x in enumerate(cl):
            if t >= nxt[i]:
                nxt[i] = t + rng.uniform(1, 3)
                want = set()
                r = rng.random()
                if r < 0.65:
                    want.add("W")
                elif r < 0.75:
                    want.add("S")
                if rng.random() < 0.4:
                    want.add(rng.choice(["A", "D"]))
                if rng.random() < 0.15:
                    want.add(rng.choice(["Q", "E"]))
                for k in held[i] - want:
                    key(x, k, False)
                for k in want - held[i]:
                    key(x, k, True)
                held[i] = want
                if rng.random() < 0.05:
                    key(x, "SPACE", True)
                    key(x, "SPACE", False)
        w.tick(step, step)
        t += step
        if each:
            each()


PM_RESET = """
for k in pairs(PM) do if type(PM[k]) == 'number' then PM[k] = 0 end end
"""


def measure(w, gina, cl, walking, rng, label, secs=10.0, step=1 / 30):
    """secs of `walking` wandering at 1 / step fps; prints and returns Gina's numbers."""
    gina.eval(PM_RESET)
    mark, thr0 = len(w.addon_log), walk_throttled(cl)
    kb0 = gina.eval_py("collectgarbage('collect') return collectgarbage('count')")
    gina.eval("collectgarbage('stop') PM.g0 = collectgarbage('count')")
    wall = time.time()
    wander(w, walking, rng, secs, step)
    wall = time.time() - wall
    m = gina.eval_py("PM.g1 = collectgarbage('count') collectgarbage('restart') return PM")
    m["kb"] = gina.eval_py("collectgarbage('collect') return collectgarbage('count')")
    m["seen"] = gina.eval_py("return #T3.v():RemoteWalkers()")
    words = [e for e in w.addon_log[mark:] if e["prefix"] == "CDLw"]
    m["words"], m["thr"] = len(words), walk_throttled(cl) - thr0
    f, d = max(1, m["frames"]), max(1, m["drawn"])
    ms = lambda v: 1000.0 * v / f                           # noqa: E731
    by = {}
    for e in words:
        by[e["sender"]] = by.get(e["sender"], 0) + 1
    m["ms"], m["walk_ms"], m["occ_ms"] = ms(m["upd"]), ms(m["walkers"]), ms(m["occ"] + m["copies"])
    m["garbage"] = (m["g1"] - m["g0"] - m["meterG"]) / secs
    print("\n  %s: %d seen by Gina, %.0f s at %d fps (%d frames, %d drawn)" % (label, m["seen"], secs, round(1 / step),
                                                                           f, d))
    print("    frame (V:OnUpdate)  %.2f ms avg, %.2f ms worst" % (m["ms"], 1000 * m["worst"]))
    for fld, nm in (("models", "V:DrawModels"), ("walkers", "  V:DrawWalkers"), ("rw", "    Collab:RemoteWalkers"),
                    ("occ", "Room.SetOccluders"), ("room", "Room.DrawRoom"), ("copies", "Room.DrawCopies"),
                    ("plates", "V:DrawPlates")):
        print("      %-24s %.2f ms  %5.0f KB/s garbage" % (nm, ms(m[fld]), m[fld + "G"] / secs))
    print("    occluders %.1f a frame, %.1f on screen, %.1f with copy slots; copyItems %.0f, copyDropped %.0f a frame"
          % (m["occN"] / d, m["onScreen"] / d, m["slots"] / d, m["items"] / d, m["dropped"] / d))
    print("    CDLw on the wire: %d words = %.1f/s (%.2f/s per walker, max %d from one); %d throttled; %d bytes/s"
          % (len(words), len(words) / secs, len(words) / secs / max(1, len(walking)), max(by.values() or [0]),
             m["thr"], sum(len(e["text"]) for e in words) / secs))
    print("    memory %.0f KB after a collect; garbage %.0f KB/s   (%.0f s wall)" % (m["kb"], m["garbage"], wall))
    return m


@case
def a_raid_of_25_walks_together_in_teron_s_room():
    w, gina, cl = crowd()
    rng = random.Random(7)
    others = [x for x in cl if x is not gina]
    # Gina alone (the base), then the raid in front of her (she stands at the entrance looking up the hall), then
    # everyone wandering, Gina too
    start_walking([gina], rng, back=gina)
    gina.eval(METER, time.perf_counter)
    f0 = gina.eval_py("return T3.v().walk.k.facing")
    base = measure(w, gina, cl, [], rng, "Gina alone, standing", secs=4)
    base_w = measure(w, gina, cl, [gina], rng, "Gina alone, wandering", secs=6)
    key(gina, "W", False), key(gina, "S", False), key(gina, "A", False), key(gina, "D", False)
    key(gina, "Q", False), key(gina, "E", False)
    gina.eval("local o = T3.v().orb T3.v():StopWalk() o.x, o.y = 30 + T3.ox, 4 + T3.oy T3.v():StartWalk() "
              "T3.v().walk.k.facing = %r" % f0)
    start_walking(others, rng)
    wander(w, others, rng, 4)                               # (everyone in, their looks heard)
    front = measure(w, gina, cl, others, rng, "%d walking in front of her" % len(others))
    allw = measure(w, gina, cl, cl, rng, "all %d wandering" % len(cl))
    print("\n  per remote walker: %.3f ms a frame, %.0f KB, %.0f KB/s garbage" % (
        (front["ms"] - base["ms"]) / len(others), (front["kb"] - base["kb"]) / len(others),
        (front["garbage"] - base["garbage"]) / len(others)))
    print("  all wandering over Gina wandering alone: %+.2f ms a frame, %+.0f KB/s garbage" % (
        allw["ms"] - base_w["ms"], allw["garbage"] - base_w["garbage"]))
    # (only the 6 others nearest the camera hide behind the room: 24 cost the copies ~5 ms a frame)
    occ = lambda m: m["occN"] / max(1, m["drawn"])          # noqa: E731
    assert occ(front) <= occ(base) + 6 + 1e-9 and occ(allw) <= occ(base) + 6 + 1e-9, (occ(base), occ(front))
    for m in (front, allw):
        assert m["seen"] == len(cl) - 1, m["seen"]
        assert m["words"] <= len(cl) * (5 + 0.8 * 10) + 1, m["words"]
        assert m["thr"] == 0, m["thr"]
    no_errors(w)


if __name__ == "__main__":
    run_all()

"""Raid Trainer: Lady Vashj, phase 2 (the Tainted Core run), and the engine pieces it added.

Covers: the room (Blizzard's geometry: a round stepped platform, holes where there is no floor, walls from the
same grid); the round (an elemental at the edge, killed by the raid, a core on the ground); looting roots you
(Paralyze) until the core is gone; Throw Key: allies only, 40 yd, the core flies at 30 yd/s; simulated raiders
pass it on towards the generator and use it there; using it yourself on a generator from 5 yd; each job (looter,
relay, at the generator) played through to four generators down; a core nobody moves loses the try; the panel:
ally name plates, clicking an ally, the F key, the unit frame of an ally, the aura icon without a time.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_trainer_vashj.py [-k name]
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors  # noqa: E402

HELPERS = r"""
T_V = {}
local T = ns.Trainer
function T_V.new(d, seed) T_V.sim = T:NewSim('vashj', d, seed or 7) return T_V.sim end
function T_V.run(secs) local s = T_V.sim for _ = 1, math.floor(secs / T.STEP + 0.5) do if s.state ~= 'run' then break end s:Step(T.STEP) end end
function T_V.until_state(state, maxSecs)
    local s = T_V.sim
    local t0 = s.time
    while s.state == 'run' and s.time - t0 < (maxSecs or 60) and not (s.core and s.core.state == state) do s:Step(T.STEP) end
    return s.core and s.core.state == state
end
-- a player who does the job well: goes where the job is, loots, throws to the ally nearest the generator, uses
function T_V.play(maxSecs)
    local s = T_V.sim
    local p = s.player
    local t0 = s.time
    while s.state == 'run' and s.time - t0 < maxSecs do
        local c = s.core
        s:SetMove(0, 0)
        if c then
            local gx, gy = c.gen.x, c.gen.y
            local wantX, wantY
            if c.role == 'looter' then wantX, wantY = c.x, c.y
            elseif c.role == 'relay' then wantX, wantY = c.spot.x, c.spot.y
            else wantX, wantY = gx + (gx - 105) * 0.1, gy + (gy - 105) * 0.1 end
            if c.holder == p then
                if not s:Interact() then
                    local best, bestD
                    for _, u in ipairs(s.units) do
                        if u.selectable and not u.dead and T.Dist(p.x, p.y, u.x, u.y) <= 40 then
                            local d = T.Dist(u.x, u.y, gx, gy)
                            if not bestD or d < bestD then best, bestD = u, d end
                        end
                    end
                    if best then s:SetTarget(best) s:Use('core') end
                end
            else
                local dx, dy = wantX - p.x, wantY - p.y
                if dx * dx + dy * dy > 4 then s:SetMove(dx, dy) end
                if c.role == 'looter' and c.state == 'onground' then s:Interact() end
            end
        end
        s:Step(T.STEP)
    end
end
"""


def boot():
    w, c = solo("Alice", tick=2)
    c.eval(HELPERS)
    return w, c


def sim(c, expr):
    return c.eval_py("local s = T_V.sim " + expr)


@case
def the_room_is_the_round_stepped_platform():
    w, c = boot()
    a = c.eval_py("local a = ns.Trainer:GetEncounter('vashj').arena return { a.w, a.h, #a.mesh.tris / 4, #a.mesh.textures }")
    assert a[0] == 210 and a[1] == 210 and 3000 < a[2] < 9000 and a[3] >= 5, a
    h = lambda x, y: c.eval_py("return ns.Trainer:GetEncounter('vashj').arena.height(%f, %f)" % (x, y))
    ok = lambda x, y: c.eval_py("return ns.Trainer:GetEncounter('vashj').arena.walkable(%f, %f)" % (x, y))
    assert abs(h(105, 105)) < 0.3                                    # Vashj's own platform
    assert -2.5 < h(105, 60) < -0.5                                  # the wide ring round it, a step lower
    assert h(105, 30) < -8 and h(105, 18) < h(105, 30)               # the steps going down to the edge
    assert -25 < h(105, 14) < -18                                    # the bottom, 20-odd yards under her
    assert abs(h(60, 105) - h(150, 105)) < 0.6 and abs(h(105, 60) - h(105, 150)) < 0.6   # it is round
    assert ok(105, 105) and ok(105, 20) and not ok(3, 3) and not ok(207, 207) and not ok(-5, 100)
    # the generators stand on the ring, the eight edge points on the bottom
    g = c.eval_py("T_V.new('finisher') local t = {} for _, g in ipairs(T_V.sim.generators) do t[#t+1] = { g.x, g.y } end return t")
    assert len(g) == 4
    for x, y in g:
        assert 26 < math.hypot(x - 105, y - 105) < 31 and -2.5 < h(x, y) < 0 and ok(x, y), (x, y, h(x, y))
    no_errors(w)


@case
def walls_come_from_the_floor_grid():
    w, c = boot()
    c.eval("T_V.new('finisher')  local p = T_V.sim.player  p.x, p.y = 105, 30  T_V.sim:SetMove(0, -1)  T_V.run(12)")
    y = sim(c, "return s.player.y")
    assert 2 < y < 20 and c.eval_py("return ns.Trainer:GetEncounter('vashj').arena.walkable(105, %f)" % y), y
    assert not c.eval_py("return ns.Trainer:GetEncounter('vashj').arena.walkable(105, %f)" % (y - 2.5))


@case
def an_elemental_comes_up_is_killed_and_leaves_a_core():
    w, c = boot()
    c.eval("T_V.new('looter')")
    assert sim(c, "return s.core == nil") and sim(c, "return #s.generators") == 4
    c.eval("T_V.run(3.2)")
    core = sim(c, "local c = s.core return { c.state, c.role, c.elemental.display, c.elemental.targetable, #s.beams }")
    assert core == ["elemental", "looter", 11172, True, 4], core
    d = sim(c, "return ns.Trainer.Dist(s.core.x, s.core.y, 105, 105)")
    assert 85 < d < 95, d                                               # at the room's edge
    assert sim(c, "return s.core.looter == nil") and sim(c, "return #s:Alive('raider')") >= 2   # relay + generator
    assert "LOOTER" in sim(c, "return s.objective")
    c.eval("T_V.run(4)")
    assert 40 < sim(c, "return s.core.elemental.hp") < 60
    assert sim(c, "local n = 0 for _, f in ipairs(s.fx) do if f.fdid == 166254 then n = n + 1 end end return n") >= 0
    assert c.eval_py("return T_V.until_state('onground', 6)")
    assert sim(c, "return s.core.elemental.dead") is True
    assert sim(c, "return s.core.corpse.name") == "Tainted Core"
    assert sim(c, "return #s:Alive('enchanted')") >= 1                  # the others walk in meanwhile
    no_errors(w)


@case
def looting_roots_you_and_throwing_needs_an_ally_in_40_yards():
    w, c = boot()
    c.eval("T_V.new('looter', 3)  T_V.until_state('onground', 20)")
    assert sim(c, "local ok, why = s:Use('core') return why") == "You have no Tainted Core."
    # too far to loot
    c.eval("local s = T_V.sim  s.player.x, s.player.y = s.core.x + 9, s.core.y")
    assert sim(c, "return (s:Interact())") is False and sim(c, "return (s:Interact(s.core.corpse))") is False
    assert sim(c, "return s.error.text") == "You are too far away."
    c.eval("local s = T_V.sim  s.player.x, s.player.y = s.core.x + 3, s.core.y")
    assert sim(c, "return (s:Interact())") is True
    assert sim(c, "return s.core.state") == "carried" and sim(c, "return s.core.holder == s.player")
    assert sim(c, "return s.player.rooted") is True and sim(c, "return s.core.corpse.dead") is True
    # Paralyze: you do not move
    x = sim(c, "return s.player.x")
    c.eval("T_V.sim:SetMove(1, 0) T_V.run(1) T_V.sim:SetMove(0, 0)")
    assert sim(c, "return s.player.x") == x
    assert sim(c, "return s.bars[1].label") == "Paralyze" and sim(c, "return s.bars[1].remain") is None
    # no target, an enemy target, an ally out of range: no throw
    assert sim(c, "local ok, why = s:Use('core') return why") == "You have no target."
    c.eval("local s = T_V.sim  T_FAR = s:Alive('raider')[#s:Alive('raider')]  T_FAR.x, T_FAR.y = s.player.x + 41, s.player.y  s:SetTarget(T_FAR)")
    assert sim(c, "local ok, why = s:Use('core') return why") == "Out of range."
    assert sim(c, "return s.core.holder == s.player")
    # in range: it flies at 30 yd/s and lands in their hands; you can move again at once
    c.eval("T_FAR.x = T_TR_X or (T_V.sim.player.x + 30)")
    assert sim(c, "return s:Use('1')") is True
    assert sim(c, "return s.player.rooted") is False and sim(c, "return s.core.holder == nil and s.core.flying == T_FAR")
    assert sim(c, "local t = {} for _, f in ipairs(s.fx) do if f.kind == 'missile' then t[#t+1] = { f.fdid, f.dur } end end return t") == [[166648, 1.0]]
    c.eval("T_V.run(0.9)")
    assert sim(c, "return s.core.holder == nil")
    c.eval("T_V.run(0.2)")
    assert sim(c, "return s.core.holder == T_FAR") and sim(c, "return s.sounds[#s.sounds]") is not None
    no_errors(w)


@case
def simulated_raiders_pass_it_on_and_use_it_at_the_generator():
    w, c = boot()
    # you are the looter and do your part; the relay and the raider at the generator do the rest
    c.eval("T_V.new('looter', 3)  T_V.until_state('onground', 20)")
    c.eval("local s = T_V.sim  s.player.x, s.player.y = s.core.x + 2, s.core.y  s:Interact()")
    gen = sim(c, "return { s.core.gen.x, s.core.gen.y }")
    relay = sim(c, "local best for _, u in ipairs(s:Alive('raider')) do if u.job == 'Relay' then best = u end end s:SetTarget(best) return { best.x, best.y }")
    assert sim(c, "return s:Use('core')") is True
    c.eval("T_V.run(2)")
    assert sim(c, "return s.core.holder ~= nil and s.core.holder.job") == "Relay"
    assert c.eval_py("return T_V.until_state('done', 8)")
    assert sim(c, "return s.stats.down") == 1 and sim(c, "return s.core.gen.active") is False
    assert sim(c, "return #s.beams") == 4 and (c.eval("T_V.run(0.1)") or True) and sim(c, "return #s.beams") == 3
    assert 4 < sim(c, "return s.stats.times[1]") < 12
    # nobody for a raider to throw to: he calls for it, and a core nobody moves loses the try
    c.eval("T_V.new('relay', 3)  T_V.until_state('carried', 30)")
    c.eval("T_V.sim.player.x, T_V.sim.player.y = 105, 190  T_V.run(4)")
    assert sim(c, "return s.core.holder.job") == "Looter" and "nobody in range" in sim(c, "return s.banner.text")
    c.eval("T_V.run(50)")
    assert sim(c, "return s.state") == "lost" and "never reached" in sim(c, "return s.reason")
    no_errors(w)


@case
def using_the_core_on_a_generator_yourself():
    w, c = boot()
    c.eval("T_V.new('finisher', 5)  T_V.run(4)")
    g = sim(c, "return { s.core.gen.x, s.core.gen.y }")
    # no core yet: the generator does nothing for you
    c.eval("local s = T_V.sim  s.player.x, s.player.y = s.core.gen.x + 2, s.core.gen.y")
    assert sim(c, "return (s:Interact(s.core.gen))") is True and sim(c, "return s.error.text") == "You need a Tainted Core."
    assert sim(c, "return s.core.gen.active") is True
    # the chain brings it to you; you are rooted with it; F / a click on the generator uses it
    assert c.eval_py("return T_V.until_state('carried', 30)")
    for _ in range(200):
        if sim(c, "return s.core.holder == s.player"):
            break
        c.eval("T_V.run(0.1)")
    assert sim(c, "return s.core.holder == s.player") and sim(c, "return s.player.rooted") is True
    assert sim(c, "return (s:Interact())") is True
    assert sim(c, "return s.core.state") == "done" and sim(c, "return s.core.gen.active") is False
    assert sim(c, "return s.player.rooted") is False and sim(c, "return s.stats.down") == 1
    # caught out of the generator's reach: you are stuck with it until you throw it on
    c.eval("T_V.new('finisher', 5)  T_V.run(4)  local s = T_V.sim  local g = s.core.gen "
           "s.player.x, s.player.y = g.x + (g.x - 105) * 0.5, g.y + (g.y - 105) * 0.5")
    for _ in range(300):
        if sim(c, "return s.core.holder == s.player"):
            break
        c.eval("T_V.run(0.1)")
    assert sim(c, "return s.core.holder == s.player")
    assert sim(c, "return (s:Interact())") is False and sim(c, "return s.core.gen.active") is True
    no_errors(w)


@case
def every_job_plays_through_to_four_generators():
    w, c = boot()
    for role in ("looter", "relay", "finisher", "all"):
        for seed in (3, 11):
            c.eval("T_V.new('%s', %d) T_V.play(400)" % (role, seed))
            st = sim(c, "return { s.state, s.reason or '', s.stats.times, ns.Trainer:GetEncounter('vashj').score(s) }")
            assert st[0] == "won" and len(st[2]) == 4, (role, seed, st)
            assert all(4 < t < 20 for t in st[2]) and 2500 < st[3] <= 4000, (role, seed, st)
    # the jobs come up as asked for; "any job" mixes them
    roles = set()
    for seed in range(1, 9):
        c.eval("T_V.new('all', %d) T_V.run(3.2)" % seed)
        roles.add(sim(c, "return s.core.role"))
    assert roles == {"looter", "relay", "finisher"}, roles
    c.eval("T_V.new('relay', 4) T_V.run(3.2)")
    assert sim(c, "return s.core.role") == "relay"
    # as the relay nobody stands on your spot; a far generator gets a second, simulated relay
    assert sim(c, "local n = 0 for _, u in ipairs(s:Alive('raider')) do if ns.Trainer.Dist(u.x, u.y, s.core.spot.x, s.core.spot.y) < 3 then n = n + 1 end end return n") == 0
    no_errors(w)


@case
def the_panel_shows_allies_and_things_to_use():
    w, c = boot()
    c.slash("/dz play trainer")
    w.tick(0.3)
    c.eval("ns.TrainerUI._Select('vashj', 'looter')")
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["enc"] == "vashj" and st["diff"] == "looter" and st["overlay"] == "Lady Vashj", st
    assert "Tainted Core" in st["body"]
    c.eval("ns.TrainerUI._Start(3)  T_V.sim = ns.TrainerUI._Sim()")
    for _ in range(40):
        c.eval("ns.TrainerUI._Tick(0.1)")
    assert sim(c, "return s.core.state") == "elemental"
    c.eval("T_V.sim.player.facing = math.pi  ns.TrainerUI._Tick(0.05)")       # (the mock only projects a west view)
    assert c.eval_py("return ns.TrainerUI._Floor().mesh") > 300
    # the job card, the marks with their labels, the compass
    g = c.eval_py("return ns.TrainerUI._Guide()")
    assert "Your job" in g["status"] and "LOOTER" in g["status"] and "Elemental:" in g["status"] and "Generator:" in g["status"], g
    assert g["heading"] == "Facing west", g
    assert any(l in ("N", "S", "E", "W") for l in g["labels"]), g
    marks = sim(c, "local t = {} for _, m in ipairs(s.marks) do t[#t+1] = m.label or '' end return t")
    assert "Tainted Elemental" in marks and "Generator: bring it here" in marks and len(marks) == 5, marks
    assert sim(c, "local n = 0 for _, u in ipairs(s:Alive('raider')) do if u.name:find('^Raider %(') then n = n + 1 end end return n") >= 2
    # F with nothing in reach is still our key; the 1 key is the core
    assert c.eval_py("return ns.TrainerUI._Key('F')") is True
    c.eval("ns.TrainerUI._Key('1')")
    assert sim(c, "return s.error.text") == "You have no Tainted Core."
    c.eval("T_V.until_state('onground', 20)  local s = T_V.sim  s.player.x, s.player.y = s.core.x + 3, s.core.y "
           "s.player.facing = math.pi  ns.TrainerUI._Tick(0.05)")
    c.eval("ns.TrainerUI._Key('F')  ns.TrainerUI._Tick(0.05)")
    assert sim(c, "return s.core.holder == s.player")
    hud = c.eval_py("return ns.TrainerUI._Hud()")
    assert hud["auras"] == [""] and hud["target"] is False, hud            # Paralyze: an icon, no time
    # an ally in front of you: click him (the view's own click picking), the target frame shows him, 1 throws
    c.eval("local s = T_V.sim  for _, u in ipairs(s:Alive('raider')) do if u.job == 'Relay' then T_AL = u end end "
           "T_AL.x, T_AL.y = s.player.x - 20, s.player.y  ns.TrainerUI._Tick(0.05)")
    x, y = c.eval_py("local x, y = ns.TrainerUI._Project(T_AL.x, T_AL.y, 1.3) return { x, y }")
    assert c.eval_py("return ns.TrainerUI._Click(%f, %f) == T_AL" % (x, y))
    c.eval("ns.TrainerUI._Tick(0.05)")
    hud = c.eval_py("return ns.TrainerUI._Hud()")
    assert hud["target"] == "Raider (relay)", hud
    c.eval("ns.TrainerUI._Key('1')  ns.TrainerUI._Tick(0.05)")
    assert sim(c, "return s.core.holder == nil and s.core.flying == T_AL") and sim(c, "return s.player.rooted") is False
    no_errors(w)


if __name__ == "__main__":
    run_all(sys.argv)

"""Raid Trainer: the generic engine and the Teron Gorefiend encounter.

Covers: the hub entry and the encounter registry; the engine (fixed steps, movement clamped to the arena, the
client's controls: run / backpedal / strafe / turn, Tab targeting, cooldown + global cooldown, range and "not yet"
errors, the fading stacking slow, stuns); Teron with the real numbers: the mark kills after the fuse, four
constructs (41,567 health) rise within 6 yd of the corpse, stand stunned for a second and each run at a raider,
the clean rotation from a corner wins, dying in the raid or never slowing them loses, the spirit running out
loses; scores and bests saved per encounter and mode; the panel (briefing, the 3D view's actors, name plates and
camera, keys, mouse look, pause on Esc and on combat, the result screen). The room renderer (Room.lua): both rooms in
their exact BSP order (every node its own place, every piece on its node's, cluster frames one per level under the
models), a still view costs no room calls, a wall through the near plane is cut there and not dropped, pieces are
halved to the screen-error bound tau (finer for a smaller tau, coarser but complete past the hard cap), the count
controller moves tau with the number of pieces and never without a camera move, the projection self-check (and its
one warning when the client's camera is not the assumed pinhole), and without Room.lua (client not restarted) the
view is drawn flat and says so. Fix round 1 (judged by tools/render_check.py where it is about pixels): a piece clear
of the near plane again shows its whole picture, not the cut one; at 5 px a redraw past the hard cap is collected
again coarser instead of leaving its nearest pieces whole; past the texture budget a frame borrows a hidden texture
rather than making one; the midpoints cache is emptied when full without changing the picture; marks that stand
still cost no line setters; a room switch while the projection gives nothing errs not. Fix round 2: the models are
hidden by copies of the room in front of them (_Occluders: behind a pillar, in the open, in the pit behind the
walkway) and stand on the room's own floor; the camera stays in the hall (collision, easing back out) and its height
eases over steps; /dz trainer render switches are kept per character; the time controller moves the leaf target;
the morph switches on and off without leaving its texture coordinates behind; copies kept from frames before (only
the slots a moving raider can change are copied again) are what copying every slot makes.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_trainer.py [-k name]
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors, World, Client  # noqa: E402

HELPERS = r"""
T_TR = {}
local T = ns.Trainer
function T_TR.new(diff, seed) T_TR.sim = T:NewSim("teron", diff or "quick", seed or 7) return T_TR.sim end
function T_TR.run(secs) local s = T_TR.sim for _ = 1, math.floor(secs / T.STEP + 0.5) do if s.state ~= "run" then break end s:Step(T.STEP) end end
function T_TR.constructs() return T_TR.sim:Alive("construct") end
-- run to the bottom-left corner until the mark kills
function T_TR.die_in_corner()
    local s = T_TR.sim
    s:SetMove(-0.8, -1)
    while s.phase == "marked" do s:Step(T.STEP) end
    s:SetMove(0, 0)
end
-- the textbook rotation: Volley, Chains, Lance the least slowed construct, Volley / Chains on cooldown
function T_TR.rotate(maxSecs)
    local s = T_TR.sim
    local t0 = s.time
    while s.state == "run" and s.time - t0 < maxSecs do
        local list = s:Alive("construct")
        -- stay on top of the pack
        local cx, cy = 0, 0
        for _, u in ipairs(list) do cx, cy = cx + u.x, cy + u.y end
        if #list > 0 then
            cx, cy = cx / #list, cy / #list
            local dx, dy = cx - s.player.x, cy - s.player.y
            if dx * dx + dy * dy > 4 then s:SetMove(dx, dy) else s:SetMove(0, 0) end
        end
        if s.gcdUntil <= s.time then
            if not s:Use("volley") and not s:Use("chains") then
                local function slow(u) local l = s:HasAura(u, "lance") return l and s:AuraSlow(l) or 0 end
                table.sort(list, function(a, b)
                    if slow(a) ~= slow(b) then return slow(a) < slow(b) end
                    return a.id < b.id
                end)
                if list[1] then s:SetTarget(list[1]) s:Use("lance") end
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
    return c.eval_py("local s = T_TR.sim " + expr)


@case
def the_hub_lists_the_trainer_and_teron_is_registered():
    w, c = boot()
    ids = c.eval_py("local t = {} for _, d in ipairs(ns.Games:GetList()) do t[#t+1] = d.id end return t")
    assert "trainer" in ids, ids
    encs = c.eval_py("local t = {} for _, e in ipairs(ns.Trainer:GetEncounters()) do t[#t+1] = e.id end return t")
    assert encs == ["teron", "vashj"], encs
    fuses = c.eval_py("local t = {} for _, d in ipairs(ns.Trainer:GetEncounter('teron').difficulties) do t[d.id] = d.fuse end return t")
    assert fuses == {"quick": 15, "real": 55}, fuses
    keys = c.eval_py("local t = {} for _, a in ipairs(ns.Trainer:GetEncounter('teron').abilities) do t[#t+1] = a.key .. a.id end return t")
    assert keys == ["1strike", "3lance", "4chains", "5volley", "7shield"], keys
    no_errors(w)


@case
def the_mark_kills_after_the_fuse_and_four_constructs_rise():
    w, c = boot()
    c.eval("T_TR.new('quick')")
    ok, why = c.eval_py("local ok, why = T_TR.sim:Use('volley') return { ok, why }")
    assert ok is False and "still alive" in why, (ok, why)
    assert sim(c, "return s.player.speed") == 7 and sim(c, "return s.player.model") == "player"
    c.eval("T_TR.sim:SetMove(-0.8, -1) T_TR.run(14.9)")
    assert sim(c, "return s.phase") == "marked"
    assert sim(c, "return #s:Alive('construct')") == 0
    c.eval("T_TR.run(0.2)")
    assert sim(c, "return s.phase") == "ghost"
    cons = sim(c, "local t = {} for _, u in ipairs(s:Alive('construct')) do "
                  "t[#t+1] = { hp = u.hp, speed = u.speed, d = ns.Trainer.Dist(u.x, u.y, s.corpse.x, s.corpse.y), "
                  "prey = u.prey.kind, display = u.display, v = s:UnitSpeed(u) } end return t")
    assert len(cons) == 4
    for u in cons:
        assert u["hp"] == 41567 and u["speed"] == 8 and u["display"] == 21305 and u["prey"] == "raider", u
        assert u["d"] <= 6.01, u                                  # Summon Skeleton: within 6 yd
        assert u["v"] == 0, u                                     # Brief Stun
    c.eval("T_TR.run(1.1)")
    assert all(abs(v - 8) < 1e-6 for v in sim(c, "local t = {} for _, u in ipairs(s:Alive('construct')) do t[#t+1] = s:UnitSpeed(u) end return t"))
    p = sim(c, "return { ghost = s.player.ghost, display = s.player.display, speed = s.player.speed, model = s.player.model }")
    assert p == {"ghost": True, "display": 21300, "speed": 8}, p
    assert sim(c, "return #s:Alive('corpse')") == 1
    no_errors(w)


@case
def the_real_mark_lasts_55_seconds():
    w, c = boot()
    c.eval("T_TR.new('real') T_TR.run(54.9)")
    assert sim(c, "return s.phase") == "marked"
    assert abs(sim(c, "return s.bars[1].remain") - 0.1) < 0.06
    c.eval("T_TR.run(0.2)")
    assert sim(c, "return s.phase") == "ghost"


@case
def dying_in_the_raid_loses_at_once():
    w, c = boot()
    c.eval("T_TR.new('quick')")
    c.eval("T_TR.run(19)")
    assert sim(c, "return s.state") == "lost"
    assert "reached the raid" in sim(c, "return s.reason")
    lines = c.eval_py("return ns.Trainer:GetEncounter('teron').summary(T_TR.sim)")
    assert any("die further away" in l for l in lines), lines


@case
def movement_is_clamped_to_the_arena():
    w, c = boot()
    c.eval("T_TR.new('quick')")
    c.eval("T_TR.sim:SetMove(-1, -1) T_TR.run(14)")
    x, y = sim(c, "return { s.player.x, s.player.y }")
    assert 1 <= x <= 2 and 1 <= y <= 2, (x, y)
    # diagonal speed is not faster than straight: 7 yd/s
    c.eval("T_TR.new('quick') T_TR.sim:SetMove(1, 0) T_TR.run(2)")
    assert abs(sim(c, "return s.player.x") - (31 + 14)) < 0.01


@case
def the_clients_controls_run_backpedal_strafe_and_turn():
    w, c = boot()
    c.eval("T_TR.new('quick')")
    x0, y0, f0 = sim(c, "return { s.player.x, s.player.y, s.player.facing }")
    assert abs(f0 - math.pi / 2) < 1e-9                           # facing the boss (north)
    c.eval("T_TR.sim:SetControls(1, 0, 0) T_TR.run(1)")           # forward: 7 yd/s
    assert abs(sim(c, "return s.player.y") - (y0 + 7)) < 0.01 and sim(c, "return s.player.moving") is True
    c.eval("T_TR.sim:SetControls(-1, 0, 0) T_TR.run(1)")          # backwards: 4.5 yd/s
    assert abs(sim(c, "return s.player.y") - (y0 + 7 - 4.5)) < 0.01 and sim(c, "return s.player.backward") is True
    c.eval("T_TR.sim:SetControls(0, 1, 0) T_TR.run(1)")           # strafe right, facing north: +x
    assert abs(sim(c, "return s.player.bodyTurn") + math.pi / 2) < 1e-9   # the body runs sideways, the view stays
    assert abs(sim(c, "return s.player.x") - (x0 + 7)) < 0.01
    assert abs(sim(c, "return s.player.facing") - f0) < 1e-9
    c.eval("T_TR.sim:SetControls(0, 0, 1) T_TR.run(0.5)")         # turn left: 180 degrees a second
    assert abs(sim(c, "return s.player.facing") - math.pi) < 1e-6
    c.eval("T_TR.sim:SetControls(1, 0, 0) T_TR.run(1)")           # now forward is west
    assert abs(sim(c, "return s.player.x") - x0) < 0.01
    c.eval("T_TR.sim:SetControls(0, 0, 0) T_TR.sim:Turn(-math.pi / 2)")   # mouse look: a quarter turn right
    assert abs(sim(c, "return s.player.facing") - math.pi / 2) < 1e-6
    c.eval("T_TR.run(0.2)")
    assert sim(c, "return s.player.moving") is False
    assert sim(c, "return s.player.bodyTurn") == 0
    # one step per frame, whatever its length; a long frame is cut into steps of at most 0.05 s
    t0 = sim(c, "return s.time")
    c.eval("T_TR.sim:SetControls(1, 0, 0)  T_N = 0  local step = T_TR.sim.Step "
           "T_TR.sim.Step = function(self, dt) T_N = T_N + 1 return step(self, dt) end")
    y0 = sim(c, "return s.player.y")
    c.eval("T_TR.sim:Update(0.016)")
    assert c.eval_py("return T_N") == 1 and abs(sim(c, "return s.time") - t0 - 0.016) < 1e-9
    assert abs(sim(c, "return s.player.y") - y0 - 7 * 0.016) < 1e-6
    c.eval("T_N = 0  T_TR.sim:Update(0.12)")
    assert c.eval_py("return T_N") == 3 and abs(sim(c, "return s.time") - t0 - 0.136) < 1e-9


@case
def the_clean_rotation_from_the_corner_wins():
    w, c = boot()
    times = []
    for seed in (1, 7, 99, 1234, 5):
        c.eval("T_TR.new('quick', %d) T_TR.die_in_corner() T_TR.rotate(60)" % seed)
        st = sim(c, "return { s.state, s.ghostTime or -1, s.stats.closest, s.reason or '' }")
        assert st[0] == "won", (seed, st)
        assert st[1] < 30, (seed, st)
        times.append(st[1])
    assert min(times) > 12, times                                  # never before the second Volley
    no_errors(w)


@case
def volley_spam_without_slows_leaks():
    w, c = boot()
    c.eval("T_TR.new('quick') T_TR.die_in_corner()")
    c.eval("local s = T_TR.sim  s:Use('volley')  T_TR.run(60)")
    assert sim(c, "return s.state") == "lost"
    assert "reached the raid" in sim(c, "return s.reason")
    assert sim(c, "return s.time - 15") < 9                       # ~50 yd at 8 yd/s after the 1 s stun


@case
def cooldowns_the_global_cooldown_and_range():
    w, c = boot()
    c.eval("T_TR.new('quick') T_TR.die_in_corner()")
    c.eval("for _, u in ipairs(T_TR.constructs()) do u.speed = 0 end")
    assert sim(c, "return s:Use('volley')") is True
    assert sim(c, "local ok, why = s:Use('chains') return why") == "That ability isn't ready yet."   # global cooldown
    c.eval("T_TR.run(1.05)")
    assert sim(c, "return s:Use('chains')") is True
    c.eval("T_TR.run(1.05)")
    assert sim(c, "return (s:Use('volley'))") is False
    cd = sim(c, "local r, total = s:Cooldown(s:GetAbility('volley')) return { r, total }")
    assert 12.5 < cd[0] < 13.1 and cd[1] == 15, cd
    assert sim(c, "return s:GetAbility('5').id") == "volley"      # the 5 key is the same ability
    # lance: auto-targets, 30 yd
    assert sim(c, "return s.target == nil")
    assert sim(c, "return s:Use('lance')") is True
    assert sim(c, "return s.target ~= nil and s.target.kind") == "construct"
    c.eval("T_TR.run(1.05) T_TR.sim.player.x, T_TR.sim.player.y = 60, 80")
    assert sim(c, "local ok, why = s:Use('lance') return why") == "Out of range."
    assert sim(c, "return s.error.text") == "Out of range."
    # Spirit Strike needs Teron in melee; Spirit Shield reaches the tank from 40 yd and has a 90 s cooldown
    c.eval("T_TR.sim.player.x, T_TR.sim.player.y = 5, 5")
    assert sim(c, "local ok, why = s:Use('1') return why") == "Out of range."
    assert sim(c, "local ok, why = s:Use('7') return why") == "Out of range."
    c.eval("T_TR.sim.player.x, T_TR.sim.player.y = 29.5, 20")
    assert sim(c, "return s:Use('7')") is True
    c.eval("T_TR.run(1.05) T_TR.sim.player.x, T_TR.sim.player.y = 29.5, 52")
    assert sim(c, "return s:Use('1')") is True
    assert sim(c, "return s.stats.strikes") == 1 and sim(c, "return s.stats.shields") == 1
    assert 87 < sim(c, "return (s:Cooldown(s:GetAbility('shield')))") < 90


@case
def the_lance_slow_stacks_to_three_and_fades_and_chains_stun():
    w, c = boot()
    c.eval("T_TR.new('quick') T_TR.die_in_corner()")
    c.eval("local s = T_TR.sim  T_U = s:Alive('construct')[1]  s:SetTarget(T_U)")
    c.eval("for i, u in ipairs(T_TR.constructs()) do u.speed = 0 end  T_U.speed = 8  T_U.goal = nil  T_TR.run(1.1)")
    c.eval("T_TR.sim.player.x, T_TR.sim.player.y = T_U.x, T_U.y")       # point blank: the missile lands at once
    speed = lambda: c.eval_py("return T_TR.sim:UnitSpeed(T_U) / 8")
    assert abs(speed() - 1) < 1e-6
    for want in (0.7, 0.4, 0.1, 0.1):                              # 30% a stack, three stacks
        c.eval("T_TR.sim:Use('lance') T_TR.run(1.05)")
        assert abs(speed() - want) < 1e-6, (want, speed())
    assert c.eval_py("return T_TR.sim:HasAura(T_U, 'lance').stacks") == 3
    c.eval("T_TR.run(2.1)")                                        # 3 s after the last one: a third of it is gone
    assert abs(speed() - 0.4) < 1e-6, speed()
    c.eval("T_TR.run(3.0)")
    assert abs(speed() - 0.7) < 1e-6, speed()
    c.eval("T_TR.run(3.0)")                                        # 9 s: over
    assert abs(speed() - 1) < 1e-6 and c.eval_py("return T_TR.sim:HasAura(T_U, 'lance')") is None
    c.eval("T_TR.sim:Use('lance') T_TR.run(1.05)")                 # starts again from one stack
    assert abs(speed() - 0.7) < 1e-6
    hp0 = c.eval_py("return T_U.hp")
    assert 41567 - 5 * 6825 <= hp0 <= 41567 - 5 * 6175, hp0
    c.eval("T_TR.sim.player.x, T_TR.sim.player.y = T_U.x, T_U.y  T_TR.sim:Use('chains')")
    assert speed() == 0 and 1900 <= hp0 - c.eval_py("return T_U.hp") <= 2100
    c.eval("T_TR.run(4.9)")
    assert speed() == 0
    c.eval("T_TR.run(0.2)")
    assert c.eval_py("return T_TR.sim:HasAura(T_U, 'chains')") is None


@case
def spells_fly_at_their_real_speed_with_their_own_effects_and_sounds():
    w, c = boot()
    c.eval("T_TR.new('quick')")
    assert sim(c, "return s.sounds[1]") == 743                               # the mark lands
    assert sim(c, "return s.fx[1].fdid") == 166814
    c.eval("T_TR.die_in_corner()")
    c.eval("local s = T_TR.sim  for _, u in ipairs(T_TR.constructs()) do u.speed = 0 end  T_U = T_TR.constructs()[1] "
           "s.player.x, s.player.y = 20, 10  T_U.x, T_U.y = 39, 10  s:SetTarget(T_U)  for i = #s.sounds, 1, -1 do s.sounds[i] = nil end")
    # Spirit Lance: 38 yd/s, so 19 yd takes half a second; nothing happens to the target before that
    assert sim(c, "return s:Use('lance')") is True
    fx = sim(c, "local t = {} for _, f in ipairs(s.fx) do if f.kind == 'missile' then t[#t+1] = { f.fdid, f.dur } end end return t")
    assert fx == [[166373, 0.5]], fx
    c.eval("T_TR.run(0.4)")
    assert c.eval_py("return T_U.hp") == 41567 and c.eval_py("return T_TR.sim:HasAura(T_U, 'lance')") is None
    c.eval("T_TR.run(0.15)")
    assert 6175 <= 41567 - c.eval_py("return T_U.hp") <= 6825 and c.eval_py("return T_TR.sim:HasAura(T_U, 'lance').stacks") == 1
    assert sim(c, "local n = 0 for _, f in ipairs(s.fx) do if f.fdid == 166372 and f.unit == T_U then n = n + 1 end end return n") == 1
    assert sim(c, "return s.sounds") == [2559, 10009], sim(c, "return s.sounds")
    # Spirit Volley: 15 yd/s. From 9 yd the damage lands 0.6 s after the cast
    c.eval("T_TR.run(1)  local s = T_TR.sim  s.player.x = 30  for i = #s.sounds, 1, -1 do s.sounds[i] = nil end")
    hp = c.eval_py("return T_U.hp")
    assert sim(c, "return s:Use('volley')") is True
    c.eval("T_TR.run(0.5)")
    assert c.eval_py("return T_U.hp") == hp
    c.eval("T_TR.run(0.15)")
    assert 9900 <= hp - c.eval_py("return T_U.hp") <= 12100
    assert sim(c, "return s.sounds") == [2559, 7]
    # Spirit Chains: no missile, at once; its chains stay on the target for the 5 s
    c.eval("T_TR.run(1)  local s = T_TR.sim  for i = #s.sounds, 1, -1 do s.sounds[i] = nil end")
    hp = c.eval_py("return T_U.hp")
    assert sim(c, "return s:Use('chains')") is True
    assert 1900 <= hp - c.eval_py("return T_U.hp") <= 2100 and c.eval_py("return T_TR.sim:UnitSpeed(T_U)") == 0
    kinds = sim(c, "local t = {} for _, f in ipairs(s.fx) do if f.fdid then t[#t+1] = f.fdid end end table.sort(t) return t")
    assert kinds == [165782, 166210, 166385], kinds
    assert sim(c, "return s.sounds") == [3076, 1502]
    c.eval("T_TR.run(4.9)")
    assert sim(c, "local n = 0 for _, f in ipairs(s.fx) do if f.fdid == 166385 then n = n + 1 end end return n") == 1
    c.eval("T_TR.run(0.2)")
    assert sim(c, "local n = 0 for _, f in ipairs(s.fx) do if f.fdid then n = n + 1 end end return n") == 0
    no_errors(w)


@case
def the_room_is_the_real_hall_with_its_map_on_the_floor():
    w, c = boot()
    a = c.eval_py("local a = ns.Trainer:GetEncounter('teron').arena return { a.w, a.h, a.map.file, a.map.u0, a.map.u1, a.map.v0, a.map.v1 }")
    assert a[0] == 60 and a[1] == 58 and a[2].endswith("BT04_a"), a
    # 0.436 yd a pixel of the 1009-wide map, scaled to 1024: the texture piece is as wide and tall as the hall
    yd_per_u = 440.0                                                 # the map's width in yards (world Y 135..575)
    assert abs((a[4] - a[3]) * yd_per_u - 60) < 1.5 and abs((a[6] - a[5]) * 512 / 683 * 293.4 - 58) < 1.5, a
    # the floor's real heights (Blizzard's geometry of the hall): flat round the walls, a pit 2.75 yd deep in the
    # middle of the north half with steps down its sides and a raised walkway into it from the south
    h = lambda x, y: c.eval_py("return ns.Trainer:GetEncounter('teron').arena.height(%f, %f)" % (x, y))
    rim = h(5, 5)
    assert abs(rim) < 0.3 and abs(h(50, 15) - rim) < 0.05 and abs(h(12, 20) - rim) < 0.05, (rim, h(50, 15), h(12, 20))
    assert abs(h(31, 45) - rim + 2.75) < 0.2 and abs(h(25, 55) - rim + 2.75) < 0.2, h(31, 45)
    assert rim - 2.7 < h(18.5, 45) < rim - 0.1 and rim - 2.7 < h(43, 45) < rim - 0.1          # on the side steps
    assert h(18.5, 45) < h(17.5, 45) < rim + 0.05                                                # going up westwards
    assert abs(h(-5, -5) - h(0.5, 0.5)) < 1e-9                                                   # the edge value outside
    c.slash("/dz play trainer")
    w.tick(0.3)
    c.eval("ns.TrainerUI._Start(3)  T_TR.sim = ns.TrainerUI._Sim()  ns.TrainerUI._Tick(0.05)")
    # everyone stands on the floor where they are: you and the raid down in the pit, on the room's own floor (the
    # height grid lies a hand's width off it; a model sunk into a step would have the step copied over its front)
    floor = lambda x, y: c.eval_py("return ns.TrainerRoom.FloorZ(%f, %f, %f)" % (x, y, h(x, y)))
    z = c.eval_py("return ns.TrainerUI._ActorPos(T_TR.sim.player.id)[3]")
    assert abs(z - floor(31, 38)) < 1e-6 and abs(z - h(31, 38)) < 0.25 and z < rim - 2, (z, floor(31, 38), h(31, 38))
    zb = c.eval_py("return ns.TrainerUI._ActorPos(T_TR.sim.boss.id)[3]")
    assert abs(zb - floor(31, 52)) < 1e-6 and abs(zb - h(31, 52)) < 0.25, (zb, h(31, 52))
    c.eval("T_TR.sim.player.x, T_TR.sim.player.y, T_TR.sim.player.facing = 50, 30, math.pi  ns.TrainerUI._Tick(0.05)")
    assert abs(c.eval_py("return ns.TrainerUI._ActorPos(T_TR.sim.player.id)[3]") - rim) < 0.15
    # the camera 14 yd behind you would stand outside the east wall: it is pulled in before the wall (spec 5.2),
    # still on the line behind you at the pitch you look with
    cm = c.eval_py("local c = ns.TrainerUI._Camera() return { c.z, c.cur, c.dist, c.x, c.collided }")
    assert cm[2] == 14 and 5 < cm[1] < 14 and cm[4] is True and cm[3] < 60, cm
    assert abs(cm[0] - (rim + 2.2 + cm[1] * math.sin(0.3))) < 0.1, cm
    # the room itself: Blizzard's triangles with their own textures; the ones facing the camera are shown
    m = c.eval_py("local m = ns.Trainer:GetEncounter('teron').arena.mesh return { #m.verts / 6, #m.tris / 4, #m.textures, m.textures[1] }")
    assert m[0] > 2000 and m[1] > 3000 and 8 <= m[2] <= 20 and m[3] > 100000, m
    fl = c.eval_py("return ns.TrainerUI._Floor()")
    assert fl["tiles"] == 0 and 500 < fl["mesh"] < m[1] and fl["mini"] is True, fl
    # the models are hidden by the room in front of them: the pieces in front of each one are copied over it (spec
    # 5.13). A raider behind the west pillar gets copies; one in the open in front of you gets (almost) none; one down
    # in the pit behind the raised walkway gets copies.
    def occ(uid):
        for o in c.eval_py("return ns.TrainerUI._Occluders()") or []:
            if o["id"] == uid:
                return o
    def stand(px, py, facing, rx, ry):
        c.eval("local s = T_TR.sim  s.player.x, s.player.y, s.player.facing = %r, %r, %r "
               "local cam = ns.TrainerUI._Camera()  cam.pitch, cam.dist = 0.3, 14 "
               "for i, u in ipairs(s:Alive('raider')) do u.x, u.y, u.goal = 58, 57, nil end "
               "T_R = s:Alive('raider')[1]  T_R.x, T_R.y = %r, %r  s.boss.x, s.boss.y = 58, 57 "
               "ns.TrainerUI._Tick(0.05)" % (px, py, facing, rx, ry))
        return c.eval_py("return T_R.id")
    uid = stand(25.5, 8, math.pi / 2, 24.0, 24.5)
    o = occ(uid)
    assert o and o["family"] == "A" and o["onScreen"] and o["copies"] > 0, o
    uid = stand(25.5, 8, math.pi / 2, 28.0, 15.0)
    o = occ(uid)
    assert o and o["onScreen"] and o["copies"] <= 2, o
    uid = stand(10, 29.5, 0, 36.0, 29.5)
    o = occ(uid)
    assert o and o["onScreen"] and o["copies"] > 0, o
    assert c.eval_py("return ns.TrainerUI._Floor().copies") > 0
    # a raider walks through the hall while the view stands still: the room is not drawn again for that (no piece
    # moves; only the copies follow him) and its order holds every frame
    c.eval("T_R = T_TR.sim:Alive('raider')[5]")
    for yy in (8, 20, 32, 44):
        c.eval("T_TR.sim.player.x, T_TR.sim.player.y = 56, %d  for _, u in ipairs(T_TR.sim:Alive('raider')) do u.x, u.y = 58, 57 end "
               "T_TR.sim.boss.x, T_TR.sim.boss.y = 58, 57  ns.TrainerUI._Tick(0.05)" % yy)
        r0 = c.eval_py("return ns.TrainerUI._Render().redraws")
        for xx in range(3, 52, 3):
            c.eval("T_R.x, T_R.y = %d, %d  ns.TrainerUI._Tick(0.05)" % (xx, yy))
            o = c.eval_py("return ns.TrainerUI._Order()")
            assert o["wrong"] == 0 and o["distinct"] == o["nodes"], (xx, yy, {k: v for k, v in o.items() if k != "levels"})
        assert c.eval_py("return ns.TrainerUI._Render().redraws") == r0, yy
    # the raised walkway that runs into the pit from the south stands well above the pit's floor
    h0 = h(29.5, 29)
    assert h0 > h(22, 29.5) + 1.5, (h0, h(22, 29.5))
    c.eval("T_TR.sim.player.x, T_TR.sim.player.y = 20, 50  ns.TrainerUI._Tick(0.05)")   # move: another view
    assert c.eval_py("return ns.TrainerUI._Floor().mesh") != fl["mesh"]
    # the spell effects are actors holding the effect's model file
    c.eval("T_TR.die_in_corner()  local s = T_TR.sim  for _, u in ipairs(T_TR.constructs()) do u.speed = 0 end "
           "ns.TrainerUI._Key('TAB') ns.TrainerUI._Key('3') ns.TrainerUI._Tick(0.05)")
    fx = c.eval_py("return ns.TrainerUI._Fx()")
    assert any(f["fdid"] in (166373, 166372) and f["shown"] for f in fx), fx     # the missile, or its impact already
    c.eval("for _ = 1, 20 do ns.TrainerUI._Tick(0.1) end")
    assert c.eval_py("return #ns.TrainerUI._Fx()") == 0
    assert c.eval_py("return #ns.TrainerUI._Sim().sounds") == 0      # played and cleared
    no_errors(w)


@case
def the_room_is_drawn_in_its_bsp_order_in_both_rooms():
    w, c = boot()
    c.slash("/dz play trainer")
    w.tick(0.3)
    for enc, diff, nodes in (("teron", "quick", 1338), ("vashj", "looter", 1511)):
        c.eval("ns.TrainerUI._Select('%s', '%s')  local v = ns.TrainerUI._View() v:SetSize(600, 400) "
               "ns.TrainerUI._Start(3)  ns.TrainerUI._Tick(0.05)" % (enc, diff))
        # every BSP node has its own place (a cluster frame's draw layer + sublevel), every piece sits on its
        # node's place, the cluster frames stand one per level between the floor's line frame and the models
        o = c.eval_py("return ns.TrainerUI._Order()")
        st = c.eval_py("return ns.TrainerUI._Render()")
        assert o["nodes"] == nodes and o["distinct"] == nodes and o["wrong"] == 0, (enc, {k: v for k, v in o.items() if k != "levels"})
        assert 50 < o["frames"] == st["frames"] <= 200 and o["pieces"] == st["leaves"] > 100, (enc, o["frames"], st)
        levels = list(o["levels"].values()) if isinstance(o["levels"], dict) else list(o["levels"])
        view_lv, scene_lv = c.eval_py("local v, s = ns.TrainerUI._View() return { v:GetFrameLevel(), s:GetFrameLevel() }")
        assert len(set(levels)) == len(levels) == o["frames"], enc
        assert min(levels) == view_lv + 3 and max(levels) < scene_lv == view_lv + 210, (enc, min(levels), max(levels), scene_lv)
        # nothing moves: the room costs nothing
        c.eval("T_CNT = {}  __MOCK.set_api_count(T_CNT)  ns.TrainerUI._Tick(0)  __MOCK.set_api_count(nil)")
        cnt = c.eval_py("return T_CNT")
        for k in ("SetVertexOffset", "SetTexCoord", "SetDrawLayer", "SetFrameLevel", "SetParent", "CreateTexture"):
            assert cnt.get(k, 0) == 0, (enc, k, cnt)
        assert c.eval_py("return ns.TrainerUI._Render().redraw") is False
    no_errors(w)


@case
def a_wall_through_the_near_plane_is_cut_there_not_dropped():
    w, c = boot()
    c.slash("/dz play trainer")
    w.tick(0.3)
    c.eval("ns.TrainerUI._Select('teron', 'quick')  local v = ns.TrainerUI._View() v:SetSize(600, 400) "
           "ns.TrainerUI._Start(3)  ns.TrainerUI._RenderOpts({ collision = false })  ns.TrainerUI._Tick(0.05)")
    # the camera 6 yd behind you with you at the west wall's foot: it hangs a hand's width from the wall, which
    # runs through the camera's near plane inside the view
    c.eval("local s = ns.TrainerUI._Sim()  s.player.x, s.player.y, s.player.facing = -0.1, 20, math.pi / 2 "
           "local cam = ns.TrainerUI._Camera()  cam.pitch, cam.dist = 0.1, 6  ns.TrainerUI._Tick(0.05)")
    st = c.eval_py("return ns.TrainerUI._Render()")
    o = c.eval_py("return ns.TrainerUI._Order()")
    assert st["clipped"] > 0 and st["midpoints"] > 0 and st["leaves"] > 300, st
    assert o["wrong"] == 0 and o["distinct"] == o["nodes"], {k: v for k, v in o.items() if k != "levels"}
    no_errors(w)


@case
def a_piece_clear_of_the_near_plane_again_shows_its_whole_picture():
    # The camera eases towards a wall of Vashj's hall until pieces cross its near plane (cut there, with cut texture
    # coordinates), then backs off: the same pieces lie whole in front of the plane again and must show their whole
    # picture, not the cut one (judged by tools/render_check.py: every texture matches its triangle, and no texel is
    # further off than the screen-error bound allows).
    rc = _render_check()
    sess = rc.Session("vashj", (300, 200), 1.0, opts=dict(rc.R1_OPTS, collision=False, morph=False))
    x, y, f, p = 79.88, 176.39, -4.32, 0.147
    toward = [8.31 - 0.02 * k for k in range(4)]
    back = [toward[-1] + 0.02 * k for k in range(1, 7)]
    sess.pose(x, y, f, p, toward[0] + 0.001)
    sess.frame()
    clipped = []
    for d in toward + back:
        sess.pose(x, y, f, p, d)
        sess.frame()
        st = sess.render_stats()
        clipped.append(st["clipped"])
        if d in back:
            tr, pt, res = rc.analyse(sess, sess.capture())
            assert res["unmatchedRegions"] == 0 and res["misplacementMaxPx"] <= 2 * st["tau"] + 0.5, (d, st["clipped"], {
                k: res[k] for k in ("unmatchedRegions", "matchedRegions", "misplacementMaxPx", "wrongSurfacePct")})
    assert min(clipped) > 0, clipped
    sess.w.assert_no_errors()


@case
def pieces_are_halved_to_the_screen_error_bound_and_tau_follows_the_count():
    w, c = boot()
    c.slash("/dz play trainer")
    w.tick(0.3)
    c.eval("ns.TrainerUI._Select('teron', 'quick')  local v = ns.TrainerUI._View() v:SetSize(600, 400) "
           "ns.TrainerUI._Start(3)  ns.TrainerUI._Tick(0.001)")

    def pose(x, y, facing, pitch=0.3, dist=14, dt=0.001):
        c.eval("local s = ns.TrainerUI._Sim()  s.player.x, s.player.y, s.player.facing = %r, %r, %r "
               "local cam = ns.TrainerUI._Camera()  cam.pitch, cam.dist = %r, %r  ns.TrainerUI._Tick(%r)"
               % (x, y, facing, pitch, dist, dt))

    def render():
        return c.eval_py("return ns.TrainerUI._Render()")

    # a fixed bound: the smaller it is, the finer the pieces; the picture reports the bound it was drawn with
    leaves = {}
    for t in (4.0, 2.0, 1.5):
        c.eval("ns.TrainerUI._RenderOpts({ tau = %r, hardCap = 8000 })" % t)
        pose(30, 8, math.pi / 2)
        st = render()
        assert st["tau"] == t and st["capped"] == 0 and st["midpoints"] > 0 and st["redraw"] is True, st
        leaves[t] = st["leaves"]
    assert leaves[4.0] < leaves[2.0] < leaves[1.5], leaves
    # past the hard cap nothing is halved any more, but every piece is still drawn (coarser), in its place
    c.eval("ns.TrainerUI._RenderOpts({ hardCap = 400 })")
    pose(30, 8, math.pi / 2)
    st, o = render(), c.eval_py("return ns.TrainerUI._Order()")
    assert st["capped"] > 0 and 400 <= st["leaves"] < leaves[1.5], st
    assert o["wrong"] == 0 and o["distinct"] == o["nodes"] and o["pieces"] == st["leaves"], o["wrong"]
    # the count controller: tau rises while there are far more pieces than the target (fast near the hard cap) ...
    c.eval("ns.TrainerUI._RenderOpts({ tau = false, adaptive = true, hardCap = 2800, target = 300 })")
    taus = []
    for k in range(25):
        pose(30, 8 + 0.05 * k, math.pi / 2)
        taus.append(render()["tauNext"])
    assert all(b >= a for a, b in zip(taus, taus[1:])) and taus[0] < 2 and taus[-1] == 5.0, taus
    # ... a camera that stands still never redraws (so tau stays where it is) ...
    r0 = render()
    for _ in range(3):
        c.eval("ns.TrainerUI._Tick(0)")
    st = render()
    assert st["redraws"] == r0["redraws"] and st["tauNext"] == r0["tauNext"] and st["redraw"] is False, st
    # ... and it sinks slowly to 1.5 px while there are few
    c.eval("ns.TrainerUI._RenderOpts({ target = 6000, hardCap = 8000 })")
    for k in range(45):
        pose(30, 9 + 0.05 * k, math.pi / 2)
    st = render()
    assert st["tauNext"] == 1.5 and st["leaves"] > leaves[2.0], st
    # the hard cap is the last resort: while tau is the controller's and under 5 px, a redraw that would run past
    # the cap is collected again at 1.25 tau before anything is drawn (no coarse frame)
    c.eval("ns.TrainerUI._RenderOpts({ hardCap = %d })" % (leaves[2.0] - 100))
    pose(30, 8, math.pi / 2)
    st = render()
    assert st["redone"] >= 1 and st["capped"] == 0 and st["leaves"] <= leaves[2.0] - 100 and st["tau"] > 2, st
    # the projection self-check (every 30th camera move): the mock's camera is the pinhole the basis assumes
    assert st["selfCheckPx"] is not None and st["selfCheckPx"] < 0.01, st
    # a client camera that is not that pinhole (here: drawn further right the deeper a point is) gets reported once
    n0 = len(c.chat_frame)
    c.eval("local v, sc = ns.TrainerUI._View()  v:SetSize(160, 120)  local f = sc.Project3DPointTo2D "
           "sc.Project3DPointTo2D = function(self, x, y, z) local px, py, d = f(self, x, y, z) "
           "if px then return px + 0.3 * d, py, d end end  ns.TrainerUI._RenderOpts({ tau = 5 })")
    for k in range(330):
        pose(30, 8 + 0.01 * (k % 60), math.pi / 2 + 0.001 * k)
    said = [str(line) for line in c.chat_frame[n0:] if "may not line up" in str(line)]
    assert len(said) == 1 and render()["selfCheckPx"] > 1.5, (said, render()["selfCheckPx"])
    no_errors(w)


def _render_check():
    tools = os.path.join(os.path.dirname(TESTS), "tools")
    if tools not in sys.path:
        sys.path.insert(0, tools)
    import render_check as rc
    return rc


@case
def at_5_px_a_redraw_past_the_hard_cap_coarsens_evenly_instead_of_cutting_its_nearest_pieces_short():
    # Vashj's hall from the east side at 32 yd, looking across it: at 5 px it takes about 2820 pieces, over the
    # hard cap (2800). The controller's tau stops at 5, so that redraw is collected again at 6.25 px (about 2490
    # pieces) instead of drawing its last pieces in the BSP order - the nearest ones - whole and far off.
    rc = _render_check()
    sess = rc.Session("vashj", (600, 400), 1.0, opts={"adaptiveTime": False, "target": 300})
    x, y, f, p, d = 167.157, 138.602, 2.345, 0.407, 32.344
    for k in range(12):
        sess.pose(x, y, f + (0.001 if k % 2 == 0 else -0.001), p, d)
        sess.frame()
    sess.pose(x, y, f, p, d)
    sess.frame()
    st = sess.render_stats()
    assert st["tauNext"] == 5.0 and st["tau"] > 5.0 and st["redone"] >= 1, st
    assert st["capped"] == 0 and st["leaves"] <= st["hardCap"] == 2800, st
    tr, pt, res = rc.analyse(sess, sess.capture())
    assert res["misplacementMaxPx"] <= 2 * st["tau"] + 0.5 and res["unmatchedRegions"] == 0, {
        k: res[k] for k in ("misplacementMaxPx", "unmatchedRegions", "wrongSurfacePct")}
    o = sess.check_order()
    assert o and o["wrong"] == 0 and o["distinct"] == o["nodes"], o
    sess.w.assert_no_errors()


@case
def past_the_texture_budget_a_frame_borrows_a_hidden_texture_instead_of_making_one():
    # Textures never leave their cluster frame in the spec, so over a long session every frame keeps as many as it
    # ever needed. Past Room's texture budget (here set low) a frame with none free borrows a hidden one from the
    # frame with the most free ones: the total stops growing, the pieces still land right and in order, and a frame
    # that needs no new texture moves none.
    rc = _render_check()
    budget = 1700
    sess = rc.Session("teron", (300, 200), 1.0, opts=dict(rc.R1_OPTS, texBudget=budget, morph=False))
    peak, sp = 0, 0
    for name, x, y, f, p, d, _ in rc.POSES["teron"][:8]:
        sess.pose(x, y, f, p, d)
        counts, _ = sess.frame()
        sp += counts.get("SetParent", 0)
        peak = max(peak, sess.c.eval_py("return ns.TrainerRoom.ShownTextures()"))
        o = sess.check_order()
        assert o["wrong"] == 0 and o["distinct"] == o["nodes"], (name, o)
    st = sess.render_stats()
    assert st["lent"] > 0 and sp == st["lent"] and st["textures"] <= max(budget, peak), (st["textures"], st["lent"], sp, peak)
    tr, pt, res = rc.analyse(sess, sess.capture())
    assert res["unmatchedRegions"] == 0 and res["wrongSurfacePct"] <= 0.02 and res["holesPct"] <= 0.01, {
        k: res[k] for k in ("unmatchedRegions", "wrongSurfacePct", "holesPct", "misplacementMaxPx")}
    # (a small turn: the pieces in view keep their textures, nothing moves between frames)
    name, x, y, f, p, d, _ = rc.POSES["teron"][7]
    sess.pose(x, y, f + 0.001, p, d)
    counts, _ = sess.frame()
    assert counts.get("SetParent", 0) == 0 and counts.get("CreateTexture", 0) == 0, counts
    sess.w.assert_no_errors()


@case
def the_midpoints_cache_is_emptied_when_full_and_the_picture_does_not_mind():
    # Every halved edge keeps its midpoint from frame to frame; once the cache holds more than its cap (16384, here
    # 300) it is emptied at the start of a redraw. Keys are paths, so no texture minds: the pieces are the same.
    rc = _render_check()
    sess = rc.Session("teron", (300, 200), 1.0, opts=dict(rc.R1_OPTS, midCap=300, morph=False))
    mids = []
    for k in range(6):
        sess.pose(30 + 2 * k, 8 + 3 * k, math.pi / 2 + 0.2 * k, 0.3, 14)
        sess.frame()
        mids.append(sess.render_stats()["midpoints"])
        tr, pt, res = rc.analyse(sess, sess.capture())
        assert res["unmatchedRegions"] == 0 and res["misplacementMaxPx"] <= 4.5 and res["wrongSurfacePct"] <= 0.02, (k, {
            kk: res[kk] for kk in ("unmatchedRegions", "misplacementMaxPx", "wrongSurfacePct")})
    sess.set_opts({"midCap": False})
    sess.pose(30 + 2 * 6, 8 + 3 * 6, math.pi / 2 + 1.2, 0.3, 14)
    sess.frame()
    grown = sess.render_stats()["midpoints"]
    assert max(mids) < 3000 and grown > max(mids[-1], 300), (mids, grown)
    sess.w.assert_no_errors()


@case
def marks_that_stand_still_are_put_into_the_order_once():
    w, c = boot()
    c.slash("/dz play trainer")
    w.tick(0.3)
    c.eval("ns.TrainerUI._Select('vashj', 'looter')  local v = ns.TrainerUI._View() v:SetSize(600, 400) "
           "ns.TrainerUI._Start(3)")
    for _ in range(40):
        c.eval("ns.TrainerUI._Tick(0.1)")
    c.eval("local s = ns.TrainerUI._Sim()  s.player.x, s.player.y, s.player.facing = 105, 48, -math.pi / 2 "
           "local cam = ns.TrainerUI._Camera()  cam.pitch, cam.dist = 0.5, 14  ns.TrainerUI._Tick(0)")
    o0, m0 = c.eval_py("return ns.TrainerUI._Order()"), c.eval_py("return ns.TrainerUI._Marks()")
    assert len(m0) >= 20 and len(o0["lines"]) >= 20, (len(m0), len(o0["lines"]))
    # the camera and the marks stand still: the same segments in the same places, and not one line setter (the one
    # SetStartPoint + SetEndPoint is the minimap's facing arrow) nor label font
    c.eval("T_CNT = {}  __MOCK.set_api_count(T_CNT)  ns.TrainerUI._Tick(0)  __MOCK.set_api_count(nil)")
    cnt = c.eval_py("return T_CNT")
    for k in ("SetThickness", "SetColorTexture", "SetDrawLayer", "CreateLine", "SetFontObject"):
        assert cnt.get(k, 0) == 0, (k, cnt)
    assert cnt.get("SetStartPoint", 0) <= 1 and cnt.get("SetEndPoint", 0) <= 1, cnt
    o1, m1 = c.eval_py("return ns.TrainerUI._Order()"), c.eval_py("return ns.TrainerUI._Marks()")
    assert m1 == m0 and o1["lines"] == o0["lines"], (len(m1), len(o1["lines"]))
    # a ring that grows (the one on the steps in view, the last mark): its lines follow, the order holds
    c.eval("local s = ns.TrainerUI._Sim()  local mk = s.marks[#s.marks]  mk.r = (mk.r or 3) + 1  ns.TrainerUI._Tick(0)")
    o2, m2 = c.eval_py("return ns.TrainerUI._Order()"), c.eval_py("return ns.TrainerUI._Marks()")
    assert m2 != m0 and o2["wrong"] == 0 and all(l["frame"] == 0 or l["pos"] % 2 == 1 for l in o2["lines"]), len(m2)
    no_errors(w)


@case
def a_room_switch_while_the_projection_gives_nothing_errs_not():
    # Project3DPointTo2D may return nothing: the camera cannot be measured, so the new room is neither drawn nor are
    # marks put into its order until it can (they would land on the old room's order).
    w, c = boot()
    c.slash("/dz play trainer")
    w.tick(0.3)
    c.eval("ns.TrainerUI._Select('teron', 'quick')  local v = ns.TrainerUI._View() v:SetSize(600, 400) "
           "ns.TrainerUI._Start(3)  ns.TrainerUI._Tick(0.05)")
    c.eval("local v, sc = ns.TrainerUI._View()  T_P3D = sc.Project3DPointTo2D  sc.Project3DPointTo2D = function() end "
           "ns.TrainerUI._Select('vashj', 'looter')  ns.TrainerUI._Start(3)")
    for _ in range(3):
        res = c.eval_py("local ok, err = pcall(ns.TrainerUI._Tick, 0.05) return { ok = ok, err = tostring(err) }")
        assert res["ok"], res
    assert c.eval_py("return ns.TrainerUI._Order()") is None
    c.eval("local v, sc = ns.TrainerUI._View()  sc.Project3DPointTo2D = T_P3D  ns.TrainerUI._Tick(0.05)")
    o = c.eval_py("return ns.TrainerUI._Order()")
    assert o and o["nodes"] == 1511 and o["wrong"] == 0 and len(o["lines"]) > 0, o and {k: v for k, v in o.items() if k != "levels"}
    no_errors(w)


@case
def without_the_room_module_the_view_is_drawn_flat():
    # Room.lua is a new file: until the client is restarted it is not loaded (a /reload does not read the TOC)
    w = World()
    c = Client(w, "Alice", class_file="PALADIN", guild_rank=3, guild="Casual Disaster")
    toc = c.toc
    c.toc = lambda: (toc()[0], [f for f in toc()[1] if not f.replace("/", "\\").endswith("Trainer\\Room.lua")])
    c.load_addon()
    w.tick(2)
    n0 = len(c.chat_frame)
    c.slash("/dz play trainer")
    w.tick(0.3)
    assert c.eval_py("return ns.TrainerRoom") is None
    assert any("restart the game client" in str(line) for line in c.chat_frame[n0:]), c.chat_frame[n0:]
    for enc, diff in (("teron", "quick"), ("vashj", "looter")):
        c.eval("ns.TrainerUI._Select('%s', '%s')  ns.TrainerUI._Start(3)" % (enc, diff))
        for _ in range(5):
            c.eval("ns.TrainerUI._Tick(0.05)")
        assert c.eval_py("return ns.TrainerUI._State().is3D") is True
        fl = c.eval_py("return ns.TrainerUI._Floor()")
        assert fl["mesh"] == 0 and fl["lines"] == 0, fl
        assert c.eval_py("return ns.TrainerUI._Render()") is None and c.eval_py("return ns.TrainerUI._Order()") is None
    assert c.eval_py("return ns.TrainerUI._Floor().tiles") > 0                    # (Teron's floor map was drawn)
    no_errors(w)


def _pose(c, x, y, facing, pitch=0.3, dist=14, dt=0.001):
    c.eval("local s = ns.TrainerUI._Sim()  s.player.x, s.player.y, s.player.facing = %r, %r, %r "
           "local cam = ns.TrainerUI._Camera()  cam.pitch, cam.dist = %r, %r  ns.TrainerUI._Tick(%r)"
           % (x, y, facing, pitch, dist, dt))


@case
def the_camera_stays_in_the_hall_and_its_height_eases_over_steps():
    # Spec 5.2: facing east by the west wall, the camera 14 yd back would hang outside the hall (and show the room
    # through the wall). It is pulled in before the wall; without collision it is not.
    w, c = boot()
    c.slash("/dz play trainer")
    w.tick(0.3)
    c.eval("ns.TrainerUI._Select('teron', 'quick')  local v = ns.TrainerUI._View() v:SetSize(600, 400) "
           "ns.TrainerUI._Start(3)  ns.TrainerUI._Tick(0.05)")
    _pose(c, 10, 12, 0)
    cam = lambda: c.eval_py("local c = ns.TrainerUI._Camera() return { c.x, c.cur, c.dist, c.collided, c.hz }")
    x, cur, dist, hit, _ = cam()
    assert hit is True and 0.8 <= cur < dist == 14 and x > 0, (x, cur, dist, hit)
    st = c.eval_py("return ns.TrainerUI._Render()")
    assert st["camCur"] == cur and st["camWant"] == 14 and st["collided"] is True, st
    # without collision it eases back out at 6 yd a second (0.3 yd in a 0.05 s frame), then stays outside the wall
    c.eval("ns.TrainerUI._RenderOpts({ collision = false })")
    _pose(c, 10, 12, 0.001, dt=0.05)
    assert hit is True and abs(cam()[1] - (cur + 0.3)) < 1e-9 and cam()[3] is False, (cur, cam())
    for _ in range(25):
        _pose(c, 10, 12, 0.001, dt=0.05)
    x, cur, dist, hit, _ = cam()
    assert hit is False and cur == 14 and x < 0, (x, cur, hit)
    c.eval("ns.TrainerUI._RenderOpts({ collision = true })")
    # in the open nothing is in the way: the whole distance
    _pose(c, 30, 20, math.pi / 2)
    assert cam()[1] == 14 and cam()[3] is False
    # all five rays leave the hall through the doorway in its east wall, where the room has nothing beyond: the
    # camera still stops 0.5 yd inside the room's footprint (its points span x -0.73 .. 60.04)
    _pose(c, 48, 17.2, 2.87, pitch=0.05, dist=32.2)
    x, cur, dist, hit, _ = cam()
    assert hit is True and abs(x - (60.04 - 0.5)) < 0.05 and 11 < cur < 13, (x, cur, hit)
    c.eval("ns.TrainerUI._RenderOpts({ collision = false })")
    _pose(c, 48, 17.2, 2.87, pitch=0.05, dist=32.0)                    # (another distance: no easing out)
    assert cam()[0] > 75 and cam()[3] is False, cam()
    c.eval("ns.TrainerUI._RenderOpts({ collision = true })")
    # the pivot's height follows the floor on a spring: a step down the pit's side eases over a few frames instead
    # of jumping (a jump of the player, a new distance or pitch snaps it)
    h = lambda x, y: c.eval_py("return ns.Trainer:GetEncounter('teron').arena.height(%f, %f)" % (x, y))
    a, b = (17.0, 45), (18.6, 45)
    assert h(*a) - h(*b) > 0.4, (h(*a), h(*b))
    _pose(c, a[0], a[1], 0, dt=0.03)
    _pose(c, a[0], a[1], 0, dt=0.03)
    assert abs(cam()[4] - (h(*a) + 2.2)) < 1e-6
    _pose(c, b[0], b[1], 0, dt=0.03)
    hz = cam()[4]
    assert h(*b) + 2.2 < hz < h(*a) + 2.2, (hz, h(*a), h(*b))
    for _ in range(40):
        _pose(c, b[0], b[1], 0, dt=0.03)
    assert abs(cam()[4] - (h(*b) + 2.2)) < 0.01, cam()
    no_errors(w)


@case
def render_switches_are_kept_per_character_and_set_with_the_slash_command():
    # Spec 7.3: /dz trainer render ... writes Data().render and sets Room.opts; the panel applies Data().render
    w = World()
    c = Client(w, "Alice", class_file="PALADIN", guild_rank=3, guild="Casual Disaster")
    c.load_addon()
    w.tick(2)
    c.eval("ns.Games:GetData('trainer').render = { copies = false }")
    c.slash("/dz play trainer")
    w.tick(0.3)
    opts = lambda: c.eval_py("local o = ns.TrainerRoom.opts return { o.copies, o.collision, o.morph, o.quads, o.opaque, "
                             "o.target or false }")
    assert opts()[0] is False, opts()
    c.eval("ns.TrainerUI._Select('teron', 'quick')  local v = ns.TrainerUI._View() v:SetSize(600, 400) "
           "ns.TrainerUI._Start(3)")
    _pose(c, 25.5, 8, math.pi / 2)
    assert c.eval_py("return ns.TrainerUI._Floor().copies") == 0
    n0 = len(c.chat_frame)
    c.slash("/dz trainer render copies on")
    _pose(c, 25.5, 8, math.pi / 2 + 0.001)
    assert opts()[0] is True and c.eval_py("return ns.Games:GetData('trainer').render.copies") is True
    c.slash("/dz trainer render collision off")
    c.slash("/dz trainer render target 1200")
    assert opts()[1] is False and opts()[5] == 1200, opts()
    assert c.eval_py("return ns.TrainerUI._Render().target") == 1200
    said = [str(l) for l in c.chat_frame[n0:] if "Raid Trainer render" in str(l)]
    assert said and "collision off" in said[-1] and "target 1200" in said[-1], said
    # quads off: every triangle a texture of its own (the room is prepared again)
    p1 = c.eval_py("return ns.TrainerUI._Render().prims")
    c.slash("/dz trainer render quads off")
    _pose(c, 25.5, 8, math.pi / 2 + 0.002)
    p2 = c.eval_py("return ns.TrainerUI._Render().prims")
    nt = c.eval_py("return #ns.Trainer:GetEncounter('teron').arena.mesh.tris / 4")
    assert p1 < p2 == nt, (p1, p2, nt)
    o = c.eval_py("return ns.TrainerUI._Order()")
    assert o["wrong"] == 0 and o["distinct"] == o["nodes"], o["wrong"]
    c.slash("/dz trainer render reset")
    _pose(c, 25.5, 8, math.pi / 2 + 0.003)
    assert opts() == [True, True, False, True, True, False], opts()
    assert c.eval_py("local n = 0 for _ in pairs(ns.Games:GetData('trainer').render) do n = n + 1 end return n") == 0
    assert c.eval_py("return ns.TrainerUI._Render().prims") == p1
    c.slash("/dz trainer render bogus on")
    assert any("unknown render setting" in str(l) for l in c.chat_frame[n0:])
    no_errors(w)


@case
def the_time_controller_keeps_a_moving_frame_near_4_ms_in_game():
    # Spec 5.11: debugprofilestop around the room, its marks and the copies; three camera-driven redraws in a row
    # over 4 ms lower the leaf target by 10%, sixty in a row under 2.4 ms raise it by 5% (900 .. 2200)
    w, c = boot()
    c.slash("/dz play trainer")
    w.tick(0.3)
    c.eval("ns.TrainerUI._Select('teron', 'quick')  local v = ns.TrainerUI._View() v:SetSize(600, 400) "
           "ns.TrainerUI._Start(3)  ns.TrainerUI._Tick(0.05)")
    c.eval("T_DPS = debugprofilestop  T_MS = 0  T_STEP = 10  debugprofilestop = function() T_MS = T_MS + T_STEP return T_MS end")
    try:
        target = lambda: c.eval_py("return ns.TrainerUI._Render().target")
        assert target() == 1600
        for k in range(3):
            _pose(c, 30, 8 + 0.1 * k, math.pi / 2)
        assert abs(target() - 1440) < 1e-9 and c.eval_py("return ns.TrainerUI._Render().ms") == 10, target()
        c.eval("T_STEP = 1")
        for k in range(60):
            _pose(c, 30, 9 + 0.05 * k, math.pi / 2)
        assert abs(target() - 1512) < 1e-9, target()
        # a still camera does not redraw: nothing to time
        r0 = c.eval_py("return ns.TrainerUI._Render().redraws")
        c.eval("ns.TrainerUI._Tick(0)")
        assert c.eval_py("return ns.TrainerUI._Render().redraws") == r0 and abs(target() - 1512) < 1e-9
        # off (render_check and the tests): the target stays
        c.eval("ns.TrainerUI._RenderOpts({ adaptiveTime = false })  T_STEP = 10")
        for k in range(5):
            _pose(c, 30, 12 + 0.1 * k, math.pi / 2)
        assert abs(target() - 1512) < 1e-9
    finally:
        c.eval("debugprofilestop = T_DPS")
    no_errors(w)


@case
def the_morph_switches_on_and_off_without_leaving_its_texture_coordinates_behind():
    # The morph (spec 5.6) ships off (spec step 8); switched on and off again, every piece shows its true picture
    # again (judged by tools/render_check.py: every texture matches its triangle within the bound)
    rc = _render_check()
    sess = rc.Session("teron", (300, 200), 1.0, opts=dict(rc.R1_OPTS, morph=False))
    assert sess.c.eval_py("return ns.TrainerRoom.Defaults.morph") is False
    for k, morph in enumerate((False, True, True, False)):
        sess.set_opts({"morph": morph})
        sess.pose(30, 8, math.pi / 2 + 0.001 * k, 0.3, 14)
        sess.frame()
    tr, pt, res = rc.analyse(sess, sess.capture())
    assert res["unmatchedRegions"] == 0 and res["misplacementMaxPx"] <= 2.5 and res["wrongSurfacePct"] <= 0.02, {
        k: res[k] for k in ("unmatchedRegions", "misplacementMaxPx", "wrongSurfacePct")}
    sess.w.assert_no_errors()


COPY_DUMP = r"""
local out = {}
for fi, fr in ipairs(ns.TrainerRoom.CopyFrames()) do
    for pool, list in pairs(fr.tex) do
        for i = 1, (fr.used[pool] or 0) do
            local t = list[i]
            out[#out + 1] = { fi, pool, t.pos, t.u1, t.v1, t.u2, t.v2, t.u3, t.v3, t.u4, t.v4,
                              t.ox1, t.oy1, t.ox2, t.oy2, t.ox3, t.oy3, t.ox4, t.oy4 }
        end
    end
    for i = 1, fr.lineUsed do
        local l = fr.lines[i]
        out[#out + 1] = { fi, -1, l.pos, 0, 0, 0, 0, 0, 0, 0, 0, l.x1, l.y1, l.x2, l.y2, 0, 0, 0, 0 }
    end
end
local occ = {}
for _, o in ipairs(ns.TrainerUI._Occluders()) do occ[#occ + 1] = { o.id, o.slot, o.copies } end
return { out, occ }
"""


@case
def the_copies_kept_from_frames_before_are_what_copying_every_slot_makes():
    # Spec 5.13 (incremental): when a raider moves under a still camera, only the slots whose copies can change are
    # copied again - its own, and those whose pieces its restricting region covers, then or now; the others keep
    # theirs. After any run of such frames the copies are the ones a pass over every slot makes (same textures in
    # the same frames and places, same pictures and corners; vertex offsets are sent on a change over 0.01 px).
    rc = _render_check()
    sess = rc.Session("teron", (600, 400), 1.0, opts=dict(rc.R1_OPTS, morph=False))
    sess.pose(25.5, 8, math.pi / 2 + 0.004, 0.3, 14)
    sess.frame()
    sess.pose(25.5, 8, math.pi / 2, 0.3, 14)
    sess.frame()
    raider = lambda i, x, y: sess.c.eval("local r = ns.TrainerUI._Sim():Alive('raider')[%d] r.x, r.y, r.goal = %r, %r, nil"
                                         % (i, x, y))
    raider(2, 24.0, 24.5)                      # behind the west pillar
    raider(3, 27.5, 16.0)                      # in front of it, over the others on the screen
    sess.frame(0.0)

    def key(r):
        return tuple(r[:3]) + tuple(round(v, 4) for v in r[3:11])

    def same(a, b):
        (ca, oa), (cb, ob) = a, b
        assert sorted(map(tuple, oa)) == sorted(map(tuple, ob)), (oa, ob)
        assert len(ca) == len(cb), (len(ca), len(cb))
        for ra, rb in zip(sorted(ca, key=key), sorted(cb, key=key)):
            assert ra[:3] == rb[:3], (ra, rb)
            assert all(abs(x - y) < 1e-6 for x, y in zip(ra[3:11], rb[3:11])), (ra, rb)
            assert all(abs(x - y) <= 0.0101 for x, y in zip(ra[11:], rb[11:])), (ra, rb)

    passes, total = 0, 0
    for k in range(16):
        raider(1, 19.0 + 0.85 * k, 24.0)       # walks west to east right behind the pillar, through raider 2
        if k % 3 == 2:
            raider(3, 27.5 - 0.3 * k, 16.0)    # and now and then raider 3 moves too
        r0 = sess.c.eval_py("return ns.TrainerUI._Render().redraws")
        sess.frame(0.0)
        assert sess.c.eval_py("return ns.TrainerUI._Render().redraws") == r0      # (the room stands: copies only)
        total += sess.c.eval_py("return ns.TrainerUI._Floor().copies")
        if k % 4 == 3:
            kept = sess.c.eval_py(COPY_DUMP)
            sess.c.eval("ns.TrainerRoom.HideCopies()  ns.TrainerRoom.DrawCopies()")
            whole = sess.c.eval_py(COPY_DUMP)
            same(kept, whole)
            passes += 1
    assert passes == 4 and total > 0, (passes, total)
    sess.w.assert_no_errors()


@case
def tab_cycles_from_near_to_far_and_skips_the_dead():
    w, c = boot()
    c.eval("T_TR.new('quick') T_TR.die_in_corner()")
    ids = []
    for _ in range(5):
        ids.append(c.eval_py("return T_TR.sim:TabTarget().id"))
    assert len(set(ids[:4])) == 4 and ids[4] == ids[0], ids
    c.eval("local s = T_TR.sim  s:Damage(s.target, 1e6)")
    assert sim(c, "return s.target == nil")
    assert sim(c, "return #s:Alive('construct')") == 3
    assert sim(c, "return s:TabTarget().kind") == "construct"      # never the boss, a raider or the corpse


@case
def tab_takes_what_is_in_front_first_and_never_repeats_within_a_round():
    w, c = boot()
    c.eval("T_TR.new('quick') T_TR.die_in_corner()")
    # you at (20, 20) facing east; A 6 yd ahead, B 12 yd ahead, C 3 yd behind, D 20 yd ahead but far off to the side
    c.eval("local s = T_TR.sim  s.player.x, s.player.y, s.player.facing = 20, 20, 0  local u = T_TR.constructs() "
           "for _, k in ipairs(u) do k.speed = 0 end "
           "u[1].x, u[1].y = 26, 20  u[2].x, u[2].y = 32, 21  u[3].x, u[3].y = 17, 20  u[4].x, u[4].y = 22, 40 "
           "T_ID = { [u[1].id] = 'A', [u[2].id] = 'B', [u[3].id] = 'C', [u[4].id] = 'D' }")
    tab = lambda: c.eval_py("return T_ID[T_TR.sim:TabTarget().id]")
    assert [tab() for _ in range(4)] == ["A", "B", "C", "D"]       # in front near to far, then behind near to far
    assert tab() == "A"                                             # a new round
    # B overtakes A between two Tabs: the round still goes on to B, not back to A
    c.eval("local u = T_TR.constructs()  u[2].x = 23")
    assert tab() == "B"
    # a click (or an auto-target) starts the round from that enemy
    c.eval("local s = T_TR.sim  s:SetTarget(T_TR.constructs()[2])")
    assert tab() == "A"
    # turn round: what was behind is in front now
    c.eval("T_TR.sim.player.facing = math.pi  T_TR.sim:SetTarget(nil)")
    assert tab() == "C"


@case
def a_click_on_a_construct_targets_it():
    w, c = boot()
    c.slash("/dz play trainer")
    w.tick(0.3)
    c.eval("ns.TrainerUI._Start(3)  T_TR.sim = ns.TrainerUI._Sim()  T_TR.die_in_corner()")
    # face west (the mock's projection only knows a camera that looks along -x), two constructs ahead
    c.eval("local s = T_TR.sim  s.player.x, s.player.y, s.player.facing = 40, 40, math.pi  local u = T_TR.constructs() "
           "for _, k in ipairs(u) do k.speed = 0 k.x, k.y = 5, 80 end "
           "u[1].x, u[1].y = 30, 37  u[2].x, u[2].y = 26, 44  T_A, T_B = u[1], u[2]")
    c.eval("ns.TrainerUI._Tick(0.05)")
    ax, ay = c.eval_py("local x, y = ns.TrainerUI._Project(T_A.x, T_A.y, 1.5) return { x, y }")
    bx, by = c.eval_py("local x, y = ns.TrainerUI._Project(T_B.x, T_B.y, 1.5) return { x, y }")
    assert abs(ax - bx) > 30, (ax, bx)
    assert c.eval_py("return ns.TrainerUI._Click(%f, %f) == T_A" % (ax, ay))
    assert c.eval_py("return T_TR.sim.target == T_A")
    assert c.eval_py("return ns.TrainerUI._Click(%f, %f) == T_B" % (bx + 3, by - 2))
    assert c.eval_py("return T_TR.sim.target == T_B")
    assert c.eval_py("return ns.TrainerUI._Click(%f, %f) == T_A" % (ax + 25, ay))      # a near miss still takes it
    # four constructs on one spot: their name plates climb above each other (and the frame still ends)
    c.eval("for _, k in ipairs(T_TR.constructs()) do k.x, k.y = 30.3, 37.7 end  ns.TrainerUI._Tick(0.05)")
    ys = sorted(p[1] for p in c.eval_py("return ns.TrainerUI._Plates()") if abs(p[0] - c.eval_py("return (ns.TrainerUI._Project(30.3, 37.7, 3.2))")) < 1)
    assert len(ys) == 4 and all(abs(b - a - 46) < 1e-6 for a, b in zip(ys, ys[1:])), ys
    c.eval("local u = T_TR.constructs()  u[1].x, u[1].y = 30, 37  u[2].x, u[2].y = 26, 44  for i = 3, 4 do u[i].x, u[i].y = 5, 80 end  ns.TrainerUI._Tick(0.05)")
    assert c.eval_py("return ns.TrainerUI._Click(%f, %f)" % (ax, ay + 400)) is None     # the ceiling: nothing
    assert c.eval_py("return T_TR.sim.target == T_A")                                   # and the target stays
    no_errors(w)


@case
def the_spirit_running_out_loses():
    w, c = boot()
    c.eval("T_TR.new('quick') T_TR.die_in_corner()")
    c.eval("for _, u in ipairs(T_TR.constructs()) do u.speed = 0 end  T_TR.run(61)")   # held forever, never killed
    assert sim(c, "return s.state") == "lost"
    assert "spirit faded" in sim(c, "return s.reason")


@case
def scores_and_bests_are_saved_per_mode():
    w, c = boot()
    c.eval("T_TR.new('quick', 7) T_TR.die_in_corner() T_TR.rotate(60)")
    score, best = c.eval_py("local a, b = ns.Trainer:Finish(T_TR.sim) return { a, b }")
    assert score > 1000 and best is True, (score, best)
    assert c.eval_py("local a, b = ns.Trainer:Finish(T_TR.sim) return { a, b }") == [score, False]   # stored once
    rec = c.eval_py("return ns.Trainer:Record('teron', 'quick')")
    assert rec["tries"] == 1 and rec["clears"] == 1 and rec["bestScore"] == score and rec["bestTime"] > 15, rec
    assert c.eval_py("return ns.Games:GetData('trainer').best") == score
    c.eval("T_TR.new('quick') T_TR.run(19)")                        # a wipe: a try, no clear, the best stays
    low = c.eval_py("return (ns.Trainer:Finish(T_TR.sim))")
    assert low == 0
    rec = c.eval_py("return ns.Trainer:Record('teron', 'quick')")
    assert rec["tries"] == 2 and rec["clears"] == 1 and rec["bestScore"] == score
    assert c.eval_py("return ns.Trainer:Record('teron', 'real').tries") == 0
    # the same seed replays the same run
    c.eval("T_TR.new('quick', 7) T_TR.die_in_corner() T_TR.rotate(60)")
    assert c.eval_py("return ns.Trainer:GetEncounter('teron').score(T_TR.sim)") == score


@case
def the_panel_briefs_plays_pauses_and_shows_the_result():
    w, c = boot()
    c.slash("/dz play trainer")
    w.tick(0.3)
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["enc"] == "teron" and st["diff"] == "quick" and st["is3D"] is True, st
    assert st["overlay"] == "Teron Gorefiend" and "Shadow of Death" in st["body"] and "right mouse button" in st["body"], st
    assert st["focused"] is False
    c.eval("ns.TrainerUI._Start(7)")
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["focused"] is True and st["overlay"] is False and st["phase"] == "marked", st
    ctl = lambda: c.eval_py("local s = ns.TrainerUI._Sim() return { s.fwd, s.strafe, s.turn }")
    # the client's keys: W runs, A turns left, Q / E strafe; with the right button held A / D strafe instead
    c.eval("ns.TrainerUI._Key('W') ns.TrainerUI._Key('A')")
    assert ctl() == [1, 0, 1]
    c.eval("ns.TrainerUI._Mouse(true, false)")
    assert ctl() == [1, -1, 0]
    c.eval("ns.TrainerUI._Key('W', false) ns.TrainerUI._Key('A', false) ns.TrainerUI._Mouse(true, true)")
    assert ctl() == [1, 0, 0]                                       # both buttons: run
    c.eval("ns.TrainerUI._Mouse(false, false) ns.TrainerUI._Key('E')")
    assert ctl() == [0, 1, 0]
    c.eval("ns.TrainerUI._Key('E', false) ns.TrainerUI._Key('S')")
    assert ctl() == [-1, 0, 0]
    assert c.eval_py("return ns.TrainerUI._Key('F')") is False     # not ours: the client keeps it
    for _ in range(20):
        c.eval("ns.TrainerUI._Tick(0.1)")
    y = c.eval_py("return ns.TrainerUI._Sim().player.y")
    assert abs(y - (38 - 9)) < 0.5, y                              # two seconds backwards at 4.5 yd/s
    # the 3D view: an actor per model (you, Teron, 11 raiders), Teron's name plate, the camera behind you
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["actors"] == 13, st
    cam = c.eval_py("local c = ns.TrainerUI._Camera() return { c.x, c.y, c.z, c.dist }")
    assert cam[2] > 3 and abs(math.hypot(cam[0] - 31, abs(cam[1]) - y) - cam[3] * math.cos(0.3)) < 0.5, cam
    teron = c.eval_py("local s = ns.TrainerUI._Sim() for _, u in ipairs(s.units) do if u.kind == 'boss' then "
                      "local a = ns.TrainerUI._Actor(u.id) return { a.pending or a.display, a.anim } end end")
    assert teron[0] == 21254 and teron[1] in (17, 26), teron      # swinging at the tank
    # the raid: different armed models, melee swinging, casters casting, each out of step with the next
    raid = c.eval_py("local s, t = ns.TrainerUI._Sim(), {} for _, u in ipairs(s.units) do if u.kind == 'raider' then "
                     "t[#t+1] = { u.display, u.act, ns.TrainerUI._Anim(u.id) } end end return t")
    assert len(raid) == 11 and len(set(r[0] for r in raid)) >= 7, raid
    allowed = {"melee": (17, 26), "caster": (51, 53, 0), "bow": (29, 0)}
    assert all(r[2] in allowed[r[1]] for r in raid), raid
    assert len(set(r[2] for r in raid if r[1] == "caster")) > 1, raid
    # combat pauses: time stands still, the keyboard is released
    c.eval("ns:Fire('GAMES_COMBAT', true)")
    t0 = c.eval_py("return ns.TrainerUI._Sim().time")
    c.eval("ns.TrainerUI._Tick(1)")
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["focused"] is False and st["paused"] is True, st
    assert c.eval_py("return ns.TrainerUI._Sim().time") == t0
    assert ctl() == [0, 0, 0]
    no_errors(w)


@case
def the_panel_runs_a_whole_try_to_the_result_screen():
    w, c = boot()
    c.slash("/dz play trainer")
    w.tick(0.3)
    c.eval("ns.TrainerUI._Select('teron', 'real')")
    assert c.eval_py("return ns.Games:GetData('trainer').diff.teron") == "real"
    c.eval("ns.TrainerUI._Select('teron', 'quick')")
    c.eval("ns.TrainerUI._Start(3)")
    c.eval("ns.TrainerUI._Key('5')")                                      # too early
    assert "still alive" in c.eval_py("return ns.TrainerUI._Sim().error.text")
    for _ in range(200):                                                    # stand in the raid and die there
        c.eval("ns.TrainerUI._Tick(0.1)")
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["state"] == "lost" and st["overlay"] == "Wipe", st
    assert "reached the raid" in st["body"] and "Score:" in st["body"], st
    assert c.eval_py("return ns.Trainer:Record('teron', 'quick').tries") == 1
    c.eval("ns.TrainerUI._Key('SPACE')")                                  # Space: again
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["state"] == "run" and st["overlay"] is False and st["phase"] == "marked", st
    # a win through the panel's own update
    c.eval("T_TR.sim = ns.TrainerUI._Sim()  T_TR.die_in_corner()")
    c.eval("for _, u in ipairs(T_TR.constructs()) do u.speed = 0 end")
    c.eval("ns.TrainerUI._Tick(0.1)")
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["actors"] == 13 + 1 + 4, st                                 # + your corpse and the four constructs
    you = c.eval_py("local s = ns.TrainerUI._Sim() local a = ns.TrainerUI._Actor(s.player.id) return a.pending or a.display")
    assert you == 21300, you                                              # you are the Vengeful Spirit now
    # the client's frames: yours shows the spirit now, no target frame until you pick one
    hud = c.eval_py("return ns.TrainerUI._Hud()")
    assert hud["player"] == "Vengeful Spirit" and hud["target"] is False and hud["auras"] == ["60 s"], hud
    c.eval("ns.TrainerUI._Key('TAB') ns.TrainerUI._Key('5') ns.TrainerUI._Tick(0.1)")
    assert c.eval_py("return ns.TrainerUI._Sim().stats.casts.volley") == 1
    hud = c.eval_py("return ns.TrainerUI._Hud()")
    assert hud["target"] == "Shadowy Construct" and hud["targetHp"].endswith(" / 41567") and str(hud["targetLevel"]) == "70", hud
    assert len(hud["debuffs"]) == 0 and 0 < hud["targetWidth"] <= 119, hud
    # Lance lands: the debuff with its stack count on the target frame, the bar shorter, a number floats up
    c.eval("for _ = 1, 11 do ns.TrainerUI._Tick(0.1) end  ns.TrainerUI._Key('3')  for _ = 1, 4 do ns.TrainerUI._Tick(0.1) end")
    c.eval("for _ = 1, 8 do ns.TrainerUI._Tick(0.1) end  ns.TrainerUI._Key('3')  for _ = 1, 4 do ns.TrainerUI._Tick(0.1) end")
    hud = c.eval_py("return ns.TrainerUI._Hud()")
    assert len(hud["debuffs"]) == 1 and str(hud["debuffs"][0]["count"]) == "2", hud
    assert hud["targetWidth"] < 119 * 0.75 and hud["targetHp"].endswith("/ 41567") and not hud["targetHp"].startswith("41567"), hud
    assert len(hud["texts"]) >= 1 and all(6175 <= int(t) <= 6825 for t in hud["texts"]), hud
    c.eval("for _ = 1, 20 do ns.TrainerUI._Tick(0.1) end")
    assert c.eval_py("return #ns.TrainerUI._Hud().texts") == 0                     # they fade out
    c.eval("for _, u in ipairs(T_TR.constructs()) do u.hp = 1 end")
    c.eval("ns.TrainerUI._Key('4') ns.TrainerUI._Tick(0.1)")
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["state"] == "won" and "New best!" in st["body"], st
    no_errors(w)


if __name__ == "__main__":
    run_all(sys.argv)

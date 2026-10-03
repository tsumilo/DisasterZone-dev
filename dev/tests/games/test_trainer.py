"""Raid Trainer: the generic engine and the Teron Gorefiend encounter.

Covers: the hub entry and the encounter registry; the engine (fixed steps, movement clamped to the arena, the
client's controls: run / backpedal / strafe / turn, Tab targeting, cooldown + global cooldown, range and "not yet"
errors, the fading stacking slow, stuns); Teron with the real numbers: the mark kills after the fuse, four
constructs (41,567 health) rise within 6 yd of the corpse, stand stunned for a second and each run at a raider,
the clean rotation from a corner wins, dying in the raid or never slowing them loses, the spirit running out
loses; scores and bests saved per encounter and mode; the panel (briefing, the 3D view's actors, name plates and
camera, keys, mouse look, pause on Esc and on combat, the result screen).

Run: luaenv\\Scripts\\python.exe tests\\games\\test_trainer.py [-k name]
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors  # noqa: E402

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
    assert encs == ["teron"], encs
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
    assert hp0 == 41567 - 5 * 6175, hp0
    c.eval("T_TR.sim.player.x, T_TR.sim.player.y = T_U.x, T_U.y  T_TR.sim:Use('chains')")
    assert speed() == 0 and c.eval_py("return T_U.hp") == hp0 - 1900
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
    assert c.eval_py("return T_U.hp") == 41567 - 6175 and c.eval_py("return T_TR.sim:HasAura(T_U, 'lance').stacks") == 1
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
    assert c.eval_py("return T_U.hp") == hp - 1900 and c.eval_py("return T_TR.sim:UnitSpeed(T_U)") == 0
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
    # everyone stands on the floor where they are: you and the raid down in the pit
    z = c.eval_py("return ns.TrainerUI._ActorPos(T_TR.sim.player.id)[3]")
    assert abs(z - h(31, 38)) < 1e-6 and z < rim - 2, z
    assert abs(c.eval_py("return ns.TrainerUI._ActorPos(T_TR.sim.boss.id)[3]") - h(31, 52)) < 1e-6
    c.eval("T_TR.sim.player.x, T_TR.sim.player.y, T_TR.sim.player.facing = 50, 30, math.pi  ns.TrainerUI._Tick(0.05)")
    assert abs(c.eval_py("return ns.TrainerUI._ActorPos(T_TR.sim.player.id)[3]") - rim) < 0.05
    assert abs(c.eval_py("return ns.TrainerUI._Camera().z") - (rim + 2.2 + 14 * math.sin(0.3))) < 0.1
    fl = c.eval_py("return ns.TrainerUI._Floor()")
    assert fl["tiles"] == 400 and 60 < fl["shown"] <= 400 and fl["mini"] is True, fl
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
    c.eval("ns.TrainerUI._Key('TAB') ns.TrainerUI._Key('5') ns.TrainerUI._Tick(0.1)")
    assert c.eval_py("return ns.TrainerUI._Sim().stats.casts.volley") == 1
    c.eval("for _, u in ipairs(T_TR.constructs()) do u.hp = 1 end")
    c.eval("for _ = 1, 11 do ns.TrainerUI._Tick(0.1) end  ns.TrainerUI._Key('4') ns.TrainerUI._Tick(0.1)")
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["state"] == "won" and "New best!" in st["body"], st
    no_errors(w)


if __name__ == "__main__":
    run_all(sys.argv)

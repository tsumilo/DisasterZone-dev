"""Raid Trainer: the generic engine and the Teron Gorefiend encounter.

Covers: the hub entry and the encounter registry; the engine (fixed steps, movement clamped to the arena, Tab
targeting, cooldown + global cooldown, range and "not yet" errors, slow stacks and stuns); Teron: the mark kills
after the fuse, four constructs rise from the corpse, the clean rotation from a corner wins, dying in the raid or
never slowing them loses, the spirit running out loses; scores and bests saved per encounter and difficulty; the
panel (briefing, keys, pause on Esc and on combat, the result screen).

Run: luaenv\\Scripts\\python.exe tests\\games\\test_trainer.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors  # noqa: E402

HELPERS = r"""
T_TR = {}
local T = ns.Trainer
function T_TR.new(diff, seed) T_TR.sim = T:NewSim("teron", diff or "normal", seed or 7) return T_TR.sim end
function T_TR.run(secs) local s = T_TR.sim for _ = 1, math.floor(secs / T.STEP + 0.5) do if s.state ~= "run" then break end s:Step(T.STEP) end end
function T_TR.constructs() return T_TR.sim:Alive("construct") end
-- run to the bottom-left corner until the mark kills
function T_TR.die_in_corner()
    local s = T_TR.sim
    s:SetMove(-0.52, -1)
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
            if dx * dx + dy * dy > 9 then s:SetMove(dx, dy) else s:SetMove(0, 0) end
        end
        if s.gcdUntil <= s.time then
            if not s:Use("volley") and not s:Use("chains") then
                local function stacks(u) local l = s:HasAura(u, "lance") return l and l.stacks or 0 end
                table.sort(list, function(a, b)
                    if stacks(a) ~= stacks(b) then return stacks(a) < stacks(b) end
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
    assert c.eval_py("return #ns.Trainer:GetEncounter('teron').difficulties") == 3
    no_errors(w)


@case
def the_mark_kills_after_the_fuse_and_four_constructs_rise():
    w, c = boot()
    c.eval("T_TR.new('normal')")
    ok, why = c.eval_py("local ok, why = T_TR.sim:Use('volley') return { ok, why }")
    assert ok is False and "still alive" in why, (ok, why)
    c.eval("T_TR.run(11.9)")
    assert sim(c, "return s.phase") == "marked"
    assert sim(c, "return #s:Alive('construct')") == 0
    c.eval("T_TR.run(0.2)")
    assert sim(c, "return s.phase") == "ghost"
    assert sim(c, "return #s:Alive('construct')") == 4
    assert sim(c, "return s.player.ghost") is True
    assert sim(c, "return s.corpse ~= nil")
    no_errors(w)


@case
def dying_in_the_raid_loses_at_once():
    w, c = boot()
    c.eval("T_TR.new('normal')")
    c.eval("T_TR.run(14)")
    assert sim(c, "return s.state") == "lost"
    assert "reached the raid" in sim(c, "return s.reason")
    lines = c.eval_py("return ns.Trainer:GetEncounter('teron').summary(T_TR.sim)")
    assert any("die further away" in l for l in lines), lines


@case
def movement_is_clamped_to_the_arena():
    w, c = boot()
    c.eval("T_TR.new('learner')")
    c.eval("T_TR.sim:SetMove(-1, -1) T_TR.run(14)")
    x, y = sim(c, "return { s.player.x, s.player.y }")
    assert 1 <= x <= 2 and 1 <= y <= 60, (x, y)
    # diagonal speed is not faster than straight: 7 yd/s
    c.eval("T_TR.new('learner') T_TR.sim:SetMove(1, 0) T_TR.run(2)")
    assert abs(sim(c, "return s.player.x") - (35 + 14)) < 0.01


@case
def the_clean_rotation_from_the_corner_wins_on_every_difficulty():
    w, c = boot()
    for diff in ("learner", "normal", "hard"):
        for seed in (1, 7, 99):
            c.eval("T_TR.new('%s', %d) T_TR.die_in_corner() T_TR.rotate(60)" % (diff, seed))
            st = sim(c, "return { s.state, s.ghostTime or -1, s.stats.closest, s.reason or '' }")
            assert st[0] == "won", (diff, seed, st)
            assert st[1] < 30, (diff, seed, st)
    no_errors(w)


@case
def volley_spam_without_slows_leaks():
    w, c = boot()
    c.eval("T_TR.new('normal') T_TR.die_in_corner()")
    c.eval("local s = T_TR.sim  s:Use('volley')  T_TR.run(60)")
    assert sim(c, "return s.state") == "lost"
    assert "reached the raid" in sim(c, "return s.reason")


@case
def cooldowns_the_global_cooldown_and_range():
    w, c = boot()
    c.eval("T_TR.new('normal') T_TR.die_in_corner()")
    assert sim(c, "return s:Use('volley')") is True
    assert sim(c, "local ok, why = s:Use('chains') return why") == "That ability isn't ready yet."   # global cooldown
    c.eval("T_TR.run(1.05)")
    assert sim(c, "return s:Use('chains')") is True
    c.eval("T_TR.run(1.05)")
    assert sim(c, "return (s:Use('volley'))") is False
    cd = sim(c, "local r, total = s:Cooldown(s:GetAbility('volley')) return { r, total }")
    assert 12.5 < cd[0] < 13.1 and cd[1] == 15, cd
    # the 5 key is the same ability
    assert sim(c, "return s:GetAbility('5').id") == "volley"
    # lance: auto-targets, 30 yd
    assert sim(c, "return s.target == nil")
    assert sim(c, "return s:Use('lance')") is True
    assert sim(c, "return s.target ~= nil and s.target.kind") == "construct"
    c.eval("T_TR.run(1.05) T_TR.sim.player.x, T_TR.sim.player.y = 60, 80")
    assert sim(c, "local ok, why = s:Use('lance') return why") == "Out of range."
    assert sim(c, "return s.error.text") == "Out of range."


@case
def lance_slows_stack_to_three_and_chains_hold():
    w, c = boot()
    c.eval("T_TR.new('normal') T_TR.die_in_corner()")
    c.eval("local s = T_TR.sim  T_U = s:Alive('construct')[1]  s:SetTarget(T_U)")
    c.eval("for i, u in ipairs(T_TR.constructs()) do if i > 1 then u.speed = 0 end end")
    assert abs(c.eval_py("return T_TR.sim:UnitSpeed(T_U)") - 7) < 1e-6
    for want in (0.7, 0.4, 0.1, 0.1):
        c.eval("T_TR.sim:Use('lance') T_TR.run(1.05)")
        got = c.eval_py("return T_TR.sim:UnitSpeed(T_U) / 7")
        assert abs(got - want) < 1e-6, (want, got)
    assert c.eval_py("return T_TR.sim:HasAura(T_U, 'lance').stacks") == 3
    c.eval("T_TR.sim.player.x, T_TR.sim.player.y = T_U.x, T_U.y  T_TR.sim:Use('chains')")
    assert c.eval_py("return T_TR.sim:UnitSpeed(T_U)") == 0
    hp = c.eval_py("return T_U.hp")
    assert hp == 40000 - 4 * 6175 - 1900, hp
    c.eval("T_TR.run(5.1)")
    assert c.eval_py("return T_TR.sim:HasAura(T_U, 'chains')") is None
    c.eval("T_TR.run(9)")
    assert abs(c.eval_py("return T_TR.sim:UnitSpeed(T_U)") - 7) < 1e-6 or c.eval_py("return T_TR.sim.state") != "run"


@case
def tab_cycles_from_near_to_far_and_skips_the_dead():
    w, c = boot()
    c.eval("T_TR.new('normal') T_TR.die_in_corner()")
    ids = []
    for _ in range(5):
        ids.append(c.eval_py("return T_TR.sim:TabTarget().id"))
    assert len(set(ids[:4])) == 4 and ids[4] == ids[0], ids
    c.eval("local s = T_TR.sim  s:Damage(s.target, 1e6)")
    assert sim(c, "return s.target == nil")
    assert sim(c, "return #s:Alive('construct')") == 3
    assert sim(c, "return s:TabTarget().dead") is None


@case
def the_spirit_running_out_loses():
    w, c = boot()
    c.eval("T_TR.new('normal') T_TR.die_in_corner()")
    # hold them forever, never kill
    c.eval("for _, u in ipairs(T_TR.constructs()) do u.speed = 0 end  T_TR.run(61)")
    assert sim(c, "return s.state") == "lost"
    assert "spirit faded" in sim(c, "return s.reason")


@case
def scores_and_bests_are_saved_per_difficulty():
    w, c = boot()
    c.eval("T_TR.new('normal', 7) T_TR.die_in_corner() T_TR.rotate(60)")
    score, best = c.eval_py("local a, b = ns.Trainer:Finish(T_TR.sim) return { a, b }")
    assert score > 1000 and best is True, (score, best)
    assert c.eval_py("local a, b = ns.Trainer:Finish(T_TR.sim) return { a, b }") == [score, False]   # stored once
    rec = c.eval_py("return ns.Trainer:Record('teron', 'normal')")
    assert rec["tries"] == 1 and rec["clears"] == 1 and rec["bestScore"] == score and rec["bestTime"] > 12, rec
    assert c.eval_py("return ns.Games:GetData('trainer').best") == score
    c.eval("T_TR.new('normal') T_TR.run(14)")                       # a wipe: a try, no clear, the best stays
    low = c.eval_py("return (ns.Trainer:Finish(T_TR.sim))")
    assert low == 0
    rec = c.eval_py("return ns.Trainer:Record('teron', 'normal')")
    assert rec["tries"] == 2 and rec["clears"] == 1 and rec["bestScore"] == score
    assert c.eval_py("return ns.Trainer:Record('teron', 'hard').tries") == 0
    # the same seed replays the same run
    c.eval("T_TR.new('normal', 7) T_TR.die_in_corner() T_TR.rotate(60)")
    assert c.eval_py("return ns.Trainer:GetEncounter('teron').score(T_TR.sim)") == score


@case
def the_panel_briefs_plays_pauses_and_shows_the_result():
    w, c = boot()
    c.slash("/dz play trainer")
    w.tick(0.3)
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["enc"] == "teron" and st["diff"] == "normal", st
    assert st["overlay"] == "Teron Gorefiend" and "Shadow of Death" in st["body"], st
    assert st["focused"] is False
    c.eval("ns.TrainerUI._Start(7)")
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["focused"] is True and st["overlay"] is False and st["phase"] == "marked", st
    # keys: hold S + A to run to the corner, release stops
    c.eval("ns.TrainerUI._Key('S') ns.TrainerUI._Key('A')")
    assert c.eval_py("local s = ns.TrainerUI._Sim() return { s.moveX, s.moveY }") == [-1, -1]
    c.eval("ns.TrainerUI._Key('A', false)")
    assert c.eval_py("local s = ns.TrainerUI._Sim() return { s.moveX, s.moveY }") == [0, -1]
    assert c.eval_py("return ns.TrainerUI._Key('F')") is False             # not ours: the client keeps it
    for _ in range(20):
        c.eval("ns.TrainerUI._Tick(0.1)")
    y = c.eval_py("return ns.TrainerUI._Sim().player.y")
    assert y < 55 - 13, y
    # combat pauses: time stands still, the keyboard is released
    c.eval("ns:Fire('GAMES_COMBAT', true)")
    t0 = c.eval_py("return ns.TrainerUI._Sim().time")
    c.eval("ns.TrainerUI._Tick(1)")
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["focused"] is False and st["paused"] is True, st
    assert c.eval_py("return ns.TrainerUI._Sim().time") == t0
    assert c.eval_py("local s = ns.TrainerUI._Sim() return { s.moveX, s.moveY }") == [0, 0]
    no_errors(w)


@case
def the_panel_runs_a_whole_try_to_the_result_screen():
    w, c = boot()
    c.slash("/dz play trainer")
    w.tick(0.3)
    c.eval("ns.TrainerUI._Select('teron', 'learner')")
    assert c.eval_py("return ns.Games:GetData('trainer').diff.teron") == "learner"
    c.eval("ns.TrainerUI._Start(3)")
    c.eval("ns.TrainerUI._Key('5')")                                      # too early
    assert "still alive" in c.eval_py("return ns.TrainerUI._Sim().error.text")
    for _ in range(170):                                                    # stand in the raid and die there
        c.eval("ns.TrainerUI._Tick(0.1)")
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["state"] == "lost" and st["overlay"] == "Wipe", st
    assert "reached the raid" in st["body"] and "Score:" in st["body"], st
    assert c.eval_py("return ns.Trainer:Record('teron', 'learner').tries") == 1
    c.eval("ns.TrainerUI._Key('SPACE')")                                  # Space: again
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["state"] == "run" and st["overlay"] is False and st["phase"] == "marked", st
    # a win through the panel's own update
    c.eval("T_TR.sim = ns.TrainerUI._Sim()  T_TR.die_in_corner()")
    c.eval("ns.TrainerUI._Key('5') ns.TrainerUI._Tick(0.1)")
    assert c.eval_py("return ns.TrainerUI._Sim().stats.casts.volley") == 1
    c.eval("for _, u in ipairs(T_TR.constructs()) do u.hp = 1 u.speed = 0 end")
    c.eval("for _ = 1, 11 do ns.TrainerUI._Tick(0.1) end  ns.TrainerUI._Key('4') ns.TrainerUI._Tick(0.1)")
    st = c.eval_py("return ns.TrainerUI._State()")
    assert st["state"] == "won" and "New best!" in st["body"], st
    no_errors(w)


if __name__ == "__main__":
    run_all(sys.argv)

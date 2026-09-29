"""Murloc Defense (co-op lane tower defense) on the real addon.

Covers: the simulation is deterministic (same seed + actions = same hash), waves / gold / leaks / game over,
builds validated (own lane, gold, empty slot), heroes from spec + gear (healer heals, gear scales power,
clamped wire values), a solo game end to end, a 3-player networked game staying in lockstep (no desyncs,
everyone sees every build), a forged action from a non-host ignored, a corrupted client recovering through a
snapshot, combat pausing the host, and the lobby flow.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_murloc.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors, World, Client  # noqa: E402

REALM = "Thunderstrike"


def K(name):
    return "%s-%s" % (name, REALM)


def party(names=("Lee", "Rita", "Sam"), leader="Lee"):
    w = World()
    c = {}
    for n in names:
        c[n] = Client(w, n, guild_rank=3)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    w.make_party(list(c.values()), leader=c[leader])
    w.tick(3)
    return w, c


def lobby_game(w, c, host="Lee", joiners=("Rita", "Sam")):
    c[host].eval("ns.Murloc:Host()")
    w.tick(1)
    for n in joiners:
        c[n].eval("ns.Murloc:Join()")
    w.tick(1)
    c[host].eval("ns.Murloc:Start()")
    w.tick(1)


def sim_tick(cl):
    return cl.eval("local g = ns.Murloc:GetGame(); return g and g.S.tick or -1")


# -- simulation ----------------------------------------------------------------------------------------------------

SIM_RUN = """
local seed, ticks = ...
local S = ns.MurlocSim.New(seed, 3, { {role='healer', class='PRIEST', power=130}, {role='tank', class='WARRIOR', power=90},
                                      {role='caster', class='MAGE', power=150} })
ns.MurlocSim.Queue(S, { tick = 5, p = 1, k = 'b', a = 1, b = 3, c = 2, seq = 1 })
ns.MurlocSim.Queue(S, { tick = 5, p = 2, k = 'b', a = 2, b = 2, c = 1, seq = 2 })
ns.MurlocSim.Queue(S, { tick = 6, p = 3, k = 'b', a = 3, b = 4, c = 0, seq = 3 })
ns.MurlocSim.Queue(S, { tick = 7, p = 1, k = 'b', a = 1, b = 1, c = 0, seq = 4 })
ns.MurlocSim.Queue(S, { tick = 400, p = 2, k = 'l', seq = 5 })
for i = 1, ticks do ns.MurlocSim.Step(S) end
return ns.MurlocSim.Hash(S), S.wave, S.lives, S.kills
"""


@case
def simulation_is_deterministic():
    w, c = solo("Alice", tick=2)
    a = c.eval(SIM_RUN, 12345, 3000)
    b = c.eval(SIM_RUN, 12345, 3000)
    d = c.eval(SIM_RUN, 54321, 3000)
    assert a == b, (a, b)
    assert a[0] != d[0]
    assert a[1] >= 3, "several waves in 5 minutes"
    no_errors(w)


@case
def undefended_lanes_leak_until_game_over():
    w, c = solo("Alice", tick=2)
    over, lives, wave = c.eval("local S = ns.MurlocSim.New(7, 1); for i = 1, 20000 do ns.MurlocSim.Step(S); "
                               "if S.over then break end end; return S.over, S.lives, S.wave")
    assert over is True and lives == 0 and wave >= 1
    no_errors(w)


@case
def builds_are_validated():
    w, c = solo("Alice", tick=2)
    r = c.eval_py("""
        local Sim = ns.MurlocSim
        local S = Sim.New(1, 2)
        local out = {}
        out.ownLane = Sim.CanBuild(S, 1, 1, 1, 2)
        out.otherLane = Sim.CanBuild(S, 1, 2, 1, 2)
        out.badSlot = Sim.CanBuild(S, 1, 1, 9, 2)
        out.tooPoor = Sim.CanBuild(S, 1, 1, 1, 3) and Sim.CanBuild(S, 1, 1, 2, 3)
        Sim.Queue(S, { tick = 0, p = 1, k = 'b', a = 1, b = 1, c = 3, seq = 1 })
        Sim.Queue(S, { tick = 0, p = 1, k = 'b', a = 1, b = 2, c = 3, seq = 2 })   -- 150 - 100 = 50 left: refused
        Sim.Queue(S, { tick = 0, p = 1, k = 'b', a = 2, b = 1, c = 1, seq = 3 })   -- someone else's lane
        Sim.Step(S)
        out.built = S.towers[1][1] and S.towers[1][1].kind or 0
        out.second = S.towers[1][2] and true or false
        out.foreign = S.towers[2][1] and true or false
        out.gold = S.gold[1]
        out.late = Sim.Queue(S, { tick = 0, p = 1, k = 'l' })
        return out""")
    assert r["ownLane"] and not r["otherLane"] and not r["badSlot"]
    assert r["built"] == 3 and not r["second"] and not r["foreign"]
    assert r["gold"] == 150 - 100 + 1          # + the tick-0 trickle
    assert r["late"] is False
    no_errors(w)


@case
def heroes_follow_spec_and_gear():
    w, c = solo("Alice", class_file="PRIEST", tick=2)
    c.eval("ns.BiS:SetSpec('Holy')")
    h = c.eval_py("return ns.Murloc:GetMyHero()")
    assert h["role"] == "healer" and h["class"] == "PRIEST"
    r = c.eval_py("""
        local D = ns.MurlocData
        return { lo = D.PowerFromItemLevel(40), t4 = D.PowerFromItemLevel(115), hi = D.PowerFromItemLevel(400),
                 weak = D.HeroStats({role='healer', class='PRIEST', power=80}).heal,
                 strong = D.HeroStats({role='healer', class='PRIEST', power=180}).heal }""")
    assert r["lo"] == 60 and r["t4"] == 130 and r["hi"] == 200
    assert r["strong"] > r["weak"]
    # a forged hero from the wire is clamped
    p = c.eval("local S = ns.MurlocSim.New(1, 1, { { role = 'god', class = 'X', power = 99999 } }); "
               "return S.heroes[1].power, S.heroes[1].role")
    assert p == (200, "melee")
    no_errors(w)


@case
def healer_hero_heals_wounded_defenders():
    w, c = solo("Alice", tick=2)
    hp = c.eval("""
        local Sim = ns.MurlocSim
        local S = Sim.New(1, 1, { { role = 'healer', class = 'PALADIN', power = 100 } })
        Sim.Queue(S, { tick = 0, p = 1, k = 'b', a = 1, b = 3, c = 1, seq = 1 })
        Sim.Queue(S, { tick = 0, p = 1, k = 'b', a = 1, b = 1, c = 0, seq = 2 })
        Sim.Step(S)
        S.towers[1][3].hp = 100
        for i = 1, 30 do Sim.Step(S) end
        return S.towers[1][3].hp""")
    assert hp > 100, hp
    no_errors(w)


# -- in-game ---------------------------------------------------------------------------------------------------------

@case
def solo_game_runs_and_records_a_score():
    w, c = solo("Alice", tick=2)
    c.slash("/cdl play murloc")
    w.tick(0.5)
    c.eval("ns.Murloc:PlaySolo()")
    w.tick(1)
    assert c.eval("return ns.Murloc:IsPlaying()")
    c.eval("ns.Murloc:Act('b', 1, 2, 2)")
    w.tick(2)
    assert c.eval("return ns.Murloc:GetGame().S.towers[1][2].kind") == 2
    # no more defence: let the murlocs through
    c.eval("ns.Murloc:GetGame().S.towers[1][2] = false")
    w.run_until(lambda: not c.eval("return ns.Murloc:IsPlaying()"), timeout=600, step=0.5)
    assert c.eval("return ns.Games:GetData('murloc').best") >= 1
    assert c.sent_addon == [] or all("MD" not in str(m) for m in c.sent_addon), "solo games stay private"
    no_errors(w)


@case
def three_players_stay_in_lockstep():
    w, c = party()
    lobby_game(w, c)
    for n in ("Lee", "Rita", "Sam"):
        assert c[n].eval("return ns.Murloc:IsPlaying()"), n
    assert c["Rita"].eval("return ns.Murloc:GetGame().me") == 2
    c["Lee"].eval("ns.Murloc:Act('b', 1, 1, 1)")
    c["Rita"].eval("ns.Murloc:Act('b', 2, 3, 2)")
    c["Sam"].eval("ns.Murloc:Act('b', 3, 2, 0)")
    c["Sam"].eval("ns.Murloc:Act('g', 1)")
    w.tick(60, step=0.1)
    c["Rita"].eval("ns.Murloc:Act('l')")
    w.tick(60, step=0.1)
    for n in ("Lee", "Rita", "Sam"):
        g = c[n].eval_py("local g = ns.Murloc:GetGame(); return { d = g.desyncs or 0, "
                         "a = g.S.towers[1][1] and g.S.towers[1][1].kind, b = g.S.towers[2][3] and g.S.towers[2][3].kind, "
                         "h = g.S.heroUp[3], t = g.S.tick, w = g.S.wave }")
        assert g["d"] == 0, (n, g)
        assert g["b"] == 2 and g["h"] is True, (n, g)   # Rita's Rifleman and Sam's hero, seen by all
        assert g["w"] >= 2, (n, g)
    lag = sim_tick(c["Lee"]) - sim_tick(c["Sam"])
    assert 0 <= lag <= 20, lag
    no_errors(w)


@case
def forged_action_from_a_non_host_is_ignored():
    w, c = party()
    lobby_game(w, c)
    c["Sam"].eval("local g = ns.Murloc:GetGame(); ns.Comm:Send({ t = 'MDa', g = g.id, "
                  "x = { tick = g.S.tick + 30, p = 1, k = 'b', a = 1, b = 5, c = 3, seq = 99 } }, 'PARTY')")
    w.tick(6, step=0.1)
    assert c["Rita"].eval("return ns.Murloc:GetGame().S.towers[1][5]") is False
    no_errors(w)


@case
def corrupted_client_resyncs_from_a_snapshot():
    w, c = party()
    lobby_game(w, c)
    w.tick(5, step=0.1)
    c["Sam"].eval("local S = ns.Murloc:GetGame().S; S.gold[1] = S.gold[1] + 500")
    w.tick(6, step=0.1)
    assert c["Sam"].eval("return ns.Murloc:GetGame().desyncs") >= 1
    w.tick(6, step=0.1)
    gold_host = c["Lee"].eval("local g = ns.Murloc:GetGame(); return g.S.gold[1] - g.S.tick / 10")
    gold_sam = c["Sam"].eval("local g = ns.Murloc:GetGame(); return g.S.gold[1] - g.S.tick / 10")
    assert abs(gold_host - gold_sam) < 5, (gold_host, gold_sam)
    d0 = c["Sam"].eval("return ns.Murloc:GetGame().desyncs")
    w.tick(10, step=0.1)
    assert c["Sam"].eval("return ns.Murloc:GetGame().desyncs") == d0, "back in lockstep"
    no_errors(w)


@case
def combat_pauses_the_game():
    w, c = party()
    lobby_game(w, c)
    w.tick(3, step=0.1)
    c["Rita"].fire("PLAYER_REGEN_DISABLED")
    w.tick(1, step=0.1)
    t0 = sim_tick(c["Lee"])
    w.tick(8, step=0.1)
    assert sim_tick(c["Lee"]) == t0, "host paused while Rita fights"
    assert c["Sam"].eval("return ns.Murloc:IsPlaying()"), "keepalive: nobody timed out"
    c["Rita"].fire("PLAYER_REGEN_ENABLED")
    w.tick(3, step=0.1)
    assert sim_tick(c["Lee"]) > t0
    no_errors(w)


@case
def lobby_join_leave_and_host_quit():
    w, c = party()
    c["Lee"].eval("ns.Murloc:Host()")
    w.tick(1)
    c["Rita"].eval("ns.Murloc:Join()")
    c["Sam"].eval("ns.Murloc:Join()")
    w.tick(1)
    assert len(c["Sam"].eval_py("return ns.Murloc:GetLobby().players")) == 3
    c["Sam"].eval("ns.Murloc:LeaveLobby()")
    w.tick(1)
    assert c["Rita"].eval_py("return ns.Murloc:GetLobby().players") == [K("Lee"), K("Rita")]
    c["Lee"].eval("ns.Murloc:LeaveLobby()")
    w.tick(1)
    assert c["Rita"].eval("return ns.Murloc:GetLobby()") is None
    no_errors(w)


if __name__ == "__main__":
    run_all()

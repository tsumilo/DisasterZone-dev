"""Delve (co-op turn-based dungeon RPG) on the real addon.

Covers: determinism, bot-played full runs for every composition (solo per role, duo, 3 and 5 players), heroic
scaling, round mechanics (intents, taunt redirecting an attack, interrupts cancelling telegraphed casts, crowd
control / bosses slowed, hp-threshold triggers, heals / hots, round cooldowns, one potion per fight, party stuns),
clamped wire heroes, rewards + achievements, a 3-player networked run under the mock's server message throttle
(commits in step, no desyncs, steady progress), the planning timeout, a forged commit ignored, snapshot resync,
the combat pause, the lobby, and the battlefield UI running a whole solo run.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_rpg.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors, World, Client  # noqa: E402

REALM = "Thunderstrike"
BOT = open(os.path.join(HERE, "rpg_bot.lua"), encoding="utf-8").read()   # choose(S, p) + run(seed, heroes, heroic)


def P(role, cls, power=130):
    return {"role": role, "class": cls, "power": power, "name": cls.title()}


PARTY3 = [P("tank", "WARRIOR"), P("healer", "PRIEST"), P("caster", "MAGE")]


def K(name):
    return "%s-%s" % (name, REALM)


def run(c, seed, heroes, heroic=False):
    return c.eval_py(BOT + " return run(...)", seed, heroes, heroic)


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


def start(w, c, host="Lee", joiners=("Rita", "Sam")):
    c[host].eval("ns.RPG:Host()")
    w.tick(1)
    for n in joiners:
        c[n].eval("ns.RPG:Join()")
    w.tick(1)
    c[host].eval("ns.RPG:Start()")
    w.tick(1)


# The bot playing through the real RPG API (what a player clicks).
PLAY = BOT + """
local g = ns.RPG:GetGame(); if not g or g.ended then return end
local S, me = g.S, g.me; local h = S.party[me]
if h.talentOffer then ns.RPG:Act('t', 1) end
if S.phase == 'loot' and not h.lootTaken and not ns.RPG:GetChoice() then ns.RPG:Act('l', 1) end
if S.phase == 'path' and h.vote == 0 and not ns.RPG:GetChoice() then ns.RPG:Act('v', 1) end
if S.phase == 'combat' and not ns.RPG:GetChoice() and Sim.Waiting(S, me) then
    local c = choose(S, me)
    if c then ns.RPG:Cast(c.a, c.b) end
end
"""


# -- simulation ------------------------------------------------------------------------------------------------------

@case
def simulation_is_deterministic():
    w, c = solo("Alice", tick=2)
    a = run(c, 4242, PARTY3)
    assert a == run(c, 4242, PARTY3)
    assert a["hash"] != run(c, 999, PARTY3)["hash"]
    no_errors(w)


@case
def every_composition_can_clear_the_deadmines():
    w, c = solo("Alice", tick=2)
    comps = {
        "party3": PARTY3,
        "party5": PARTY3 + [P("melee", "ROGUE"), P("ranged", "HUNTER")],
        "duo": [P("tank", "PALADIN"), P("healer", "SHAMAN")],
        "solo_tank": [P("tank", "WARRIOR")], "solo_healer": [P("healer", "PALADIN")],
        "solo_melee": [P("melee", "ROGUE")], "solo_caster": [P("caster", "WARLOCK")],
        "solo_ranged": [P("ranged", "HUNTER")],
    }
    for name, heroes in comps.items():
        wins = sum(1 for s in range(1, 6) if run(c, s, heroes)["won"])
        assert wins >= 3, (name, wins)
    no_errors(w)


@case
def heroic_scales_enemies_up():
    w, c = solo("Alice", tick=2)
    hp = [c.eval("local heroes, heroic = ...; return ns.RPGSim.New(3, heroes, { heroic = heroic }).enemies[1].max",
                 PARTY3, h) for h in (False, True)]
    assert abs(hp[1] - hp[0] * 1.4) <= 2, hp
    no_errors(w)


MECH = """
local Sim, D = ns.RPGSim, ns.RPGData
local S = Sim.New(7, { {role='tank', class='WARRIOR', power=100}, {role='healer', class='PRIEST', power=100},
                       {role='caster', class='MAGE', power=100} })
local out = {}
local function only(id)
    S.enemies = {}
    local def = D.enemies[D.enemyIndex[id]]
    local e = { uid = 99, kind = D.enemyIndex[id], hp = 5000, max = 5000, abCd = {}, threat = { 0, 0, 0 }, ccRounds = 0,
                slowRounds = 0, tauntP = 0, tauntRounds = 0, enraged = false, triggered = {}, dead = false, intent = false }
    for i in ipairs(def.abilities or {}) do e.abCd[i] = 99; e.triggered[i] = false end
    S.enemies[1] = e
    return e
end
local function round(ch) Sim.ResolveRound(S, ch or {}) end
-- taunt: the miner means to hit the mage; the tank taunts and takes it instead
local e = only('miner')
e.threat = { 1, 0, 500 }
e.intent = { k = 'attack', target = 3 }
local mage0, tank0 = S.party[3].hp, S.party[1].hp
round({ { a = 3, b = 1 }, { a = 1, b = 1 }, { a = 1, b = 1 } })
out.taunt = S.party[3].hp == mage0 and S.party[1].hp < tank0 and e.tauntP == 1
-- interrupts: the evoker casts Fireball at the priest; Counterspell stops it
e = only('evoker')
e.intent = { k = 'cast', ab = 1, target = 2, interruptible = true }
local priest0 = S.party[2].hp
S.party[3].cds[3] = 0
round({ nil, nil, { a = 3, b = 1 } })
out.interrupted = S.interrupts == 1 and S.party[2].hp == priest0
-- round cooldowns: counterspell (cd 3) is not usable next round
out.cooldown = not Sim.CanUse(S, 3, 3, 1)
-- crowd control: trash is controlled; the boss is slowed
e = only('cutpurse')
S.party[3].cds[4] = 0
round({ nil, nil, { a = 4, b = 1 } })
out.cc = e.ccRounds > 0 and e.intent.k == 'cc'
e = only('vancleef')
S.party[3].cds[4] = 0
round({ nil, nil, { a = 4, b = 1 } })
out.bossSlowed = e.ccRounds == 0 and e.slowRounds > 0
-- triggers: VanCleef calls Blackguards at 50% and frenzies at 25%
e.hp = 1000
round({})
out.summoned = #S.enemies >= 2
e.hp = 400
round({})
out.enraged = e.enraged
-- healing, heal over time
e = only('miner')
S.party[3].hp = 50
round({ nil, { a = 2, b = 3 } })
out.healed = S.party[3].hp > 50
S.party[3].hp = 50
round({ nil, { a = 3, b = 3 } })
local h1 = S.party[3].hp
round({})
out.hot = S.party[3].hp > h1 or S.party[3].hp == S.party[3].max
-- one potion per fight
S.party[1].hp = 100
round({ { a = 5 } })
out.potion = S.party[1].hp > 100 and S.party[1].cds[5] > 0 and not Sim.CanUse(S, 1, 5, 1)
-- a party stun skips the next round's actions
e = only('smite')
e.intent = { k = 'cast', ab = 1, target = 0 }
round({})
out.stunned = S.party[1].stunRounds > 0 and not Sim.CanUse(S, 1, 1, 1)
return out
"""


@case
def round_mechanics():
    w, c = solo("Alice", tick=2)
    r = c.eval_py(MECH)
    for k in ("taunt", "interrupted", "cooldown", "cc", "bossSlowed", "summoned", "enraged", "healed", "hot",
              "potion", "stunned"):
        assert r.get(k) is True, (k, r)
    no_errors(w)


@case
def forged_heroes_are_clamped():
    w, c = solo("Alice", tick=2)
    r = c.eval_py("local S = ns.RPGSim.New(1, { { role = 'god', class = 'X', power = 99999, name = string.rep('a', 90) } }); "
                  "local h = S.party[1]; return { role = h.role, class = h.class, power = h.power, name = #h.name }")
    assert r == {"role": "melee", "class": "WARRIOR", "power": 200, "name": 24}, r
    no_errors(w)


# -- in-game ---------------------------------------------------------------------------------------------------------

@case
def solo_run_through_the_ui():
    w, c = solo("Alice", class_file="PRIEST", tick=2)
    c.eval("ns.BiS:SetSpec('Holy')")
    assert c.eval("return ns.RPG:GetMyHero().role") == "healer"
    c.slash("/cdl play rpg")
    w.tick(0.5)
    c.eval("ns.RPG:PlaySolo()")
    w.tick(0.5)
    assert c.eval("return ns.RPG:GetGame().S.phase") == "combat"
    for _ in range(900):
        if not c.eval("return ns.RPG:IsPlaying()"):
            break
        c.eval(PLAY)
        w.tick(0.3, step=0.1)
    assert not c.eval("return ns.RPG:IsPlaying()"), "the run should finish"
    assert c.eval("return ns.RPG:GetRep()") > 0
    no_errors(w)


@case
def rewards_and_heroic_unlock():
    w, c = solo("Alice", tick=2)
    c.eval("ns.RPG:PlaySolo()")
    w.tick(0.5)
    c.eval("local g = ns.RPG:GetGame(); local S = g.S; S.depth = 8; S.won = true; "
           "S.bossKills = { ns.RPGData.enemyIndex.vancleef, ns.RPGData.enemyIndex.rhahkzor }; S.flawlessBoss = true; "
           "S.interrupts = 12; S.over = true; S.phase = 'won'")
    c.eval("ns.RPG:Quit()")
    assert c.eval("return ns.RPG:GetRep()") == 8 * 25 + 150
    for a in ("first", "rhahk", "vancleef", "solo", "nodeath", "interrupt"):
        assert c.eval("return ns.RPG:HasAchievement(...)", a), a
    assert not c.eval("return ns.RPG:CanHeroic()")
    c.eval("ns.Games:GetData('rpg').rep = 1200")
    assert c.eval("return ns.RPG:CanHeroic()")
    c.eval("ns.RPG:SetHeroic(true)")
    assert c.eval("return ns.RPG:GetHeroic()")
    no_errors(w)


@case
def three_players_in_step_under_the_server_throttle():
    w, c = party()
    assert w.addon_throttle, "the mock must simulate the server's addon message limit"
    start(w, c)
    for n in ("Lee", "Rita", "Sam"):
        assert c[n].eval("return ns.RPG:IsPlaying()"), n
    for _ in range(300):
        for n in ("Lee", "Rita", "Sam"):
            c[n].eval(PLAY)
        w.tick(0.5, step=0.1)
        if not c["Lee"].eval("return ns.RPG:IsPlaying()"):
            break
    states = {n: c[n].eval_py("local g = ns.RPG:GetGame(); return { d = g.desyncs or 0, depth = g.S.depth, "
                              "commits = g.S.commits, hash = ns.RPGSim.Hash(g.S) }") for n in c}
    for n, s in states.items():
        assert s["d"] == 0, (n, s)
    assert states["Lee"]["depth"] >= 4, states
    assert states["Lee"]["hash"] == states["Rita"]["hash"] == states["Sam"]["hash"], states
    no_errors(w)


@case
def planning_timeout_uses_the_default_move():
    w, c = party()
    start(w, c)
    for n in ("Lee", "Rita"):             # Sam stays silent
        c[n].eval(PLAY)
    w.tick(2, step=0.1)
    assert c["Lee"].eval("return ns.RPG:GetGame().S.round") == 1, "still waiting for Sam"
    w.tick(20, step=0.2)
    assert c["Lee"].eval("return ns.RPG:GetGame().S.round") >= 2
    assert c["Sam"].eval("return ns.RPG:GetGame().S.round") == c["Lee"].eval("return ns.RPG:GetGame().S.round")
    no_errors(w)


@case
def forged_commit_from_a_non_host_is_ignored():
    w, c = party()
    start(w, c)
    c["Sam"].eval("local g = ns.RPG:GetGame(); ns.Comm:Send({ t = 'DVk', g = g.id, n = g.S.commits, "
                  "h = ns.RPGSim.Hash(g.S), round = true, acts = {} }, 'PARTY')")
    w.tick(2, step=0.1)
    assert c["Rita"].eval("return ns.RPG:GetGame().S.round") == 1
    no_errors(w)


@case
def corrupted_client_resyncs():
    w, c = party()
    start(w, c)
    c["Sam"].eval("ns.RPG:GetGame().S.party[1].hp = 1")
    for _ in range(6):
        for n in ("Lee", "Rita", "Sam"):
            c[n].eval(PLAY)
        w.tick(3, step=0.1)
    assert c["Sam"].eval("return ns.RPG:GetGame().desyncs") >= 1
    h = [c[n].eval("return ns.RPGSim.Hash(ns.RPG:GetGame().S)") for n in ("Lee", "Sam")]
    assert h[0] == h[1], h
    no_errors(w)


@case
def real_combat_holds_the_timer():
    w, c = party()
    start(w, c)
    c["Rita"].fire("PLAYER_REGEN_DISABLED")
    w.tick(30, step=0.2)
    assert c["Lee"].eval("return ns.RPG:GetGame().S.round") == 1, "nobody is rushed while Rita is in combat"
    c["Rita"].fire("PLAYER_REGEN_ENABLED")
    w.tick(8, step=0.2)
    assert c["Lee"].eval("return ns.RPG:GetGame().S.round") == 2
    no_errors(w)


@case
def lobby_flow():
    w, c = party()
    c["Lee"].eval("ns.RPG:Host()")
    w.tick(1)
    c["Rita"].eval("ns.RPG:Join()")
    c["Sam"].eval("ns.RPG:Join()")
    w.tick(1)
    assert len(c["Sam"].eval_py("return ns.RPG:GetLobby().players")) == 3
    c["Sam"].eval("ns.RPG:LeaveLobby()")
    w.tick(1)
    assert c["Rita"].eval_py("return ns.RPG:GetLobby().players") == [K("Lee"), K("Rita")]
    c["Lee"].eval("ns.RPG:LeaveLobby()")
    w.tick(1)
    assert c["Rita"].eval("return ns.RPG:GetLobby()") is None
    no_errors(w)


if __name__ == "__main__":
    run_all()

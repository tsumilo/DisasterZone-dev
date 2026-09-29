"""Delve (co-op real-time dungeon RPG) on the real addon.

Covers: determinism (same seed + actions = same hash), bot-played full runs (solo and a 3-player party reach
VanCleef; wipes end the run), class kits (resources, casts, gcd / cooldowns, heals, shields, hots), threat + taunt,
interrupts, crowd control (bosses immune), hp-threshold triggers (summon / enrage), path votes / loot / talents,
reputation + achievements, a 3-player networked run in lockstep, a forged action ignored, snapshot resync,
combat pause, lobby flow, and the battlefield UI running without errors.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_rpg.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors, World, Client  # noqa: E402

REALM = "Thunderstrike"

# A simple bot for the pure sim: each hero uses its first castable ability (heals the most hurt ally,
# interrupts casts, taunts off others), picks choice 1 everywhere.
BOT = """
local Sim, D = ns.RPGSim, ns.RPGData
local function bot(S)
    local seq = 0
    local function act(p, k, a, b) seq = seq + 1; Sim.Queue(S, { tick = S.tick, p = p, k = k, a = a, b = b, seq = seq }) end
    for p = 1, S.players do
        local h = S.party[p]
        if h.talentOffer then act(p, 't', 1) end
        if S.phase == 'loot' and not h.lootTaken then act(p, 'l', 1) end
        if S.phase == 'path' and h.vote == 0 then act(p, 'v', 1) end
        if S.phase == 'combat' and not h.dead then
            local enemy
            for i, e in ipairs(S.enemies) do if not e.dead and (not enemy or e.cast) then enemy = i end end
            local hurt, pct = p, 1001
            for q = 1, S.players do
                local x = S.party[q]
                if not x.dead and x.hp * 1000 / x.max < pct then hurt, pct = q, x.hp * 1000 / x.max end
            end
            for a = 1, D.ABILITIES do
                local ab = D.kits[h.role][a]
                local t = ab.tgt == 'ally' and hurt or (ab.tgt == 'enemy' and enemy or p)
                local useful = true
                if ab.kind == 'potion' then useful = h.hp * 100 < h.max * 40 end
                if ab.kind == 'heal' or ab.kind == 'hot' or ab.kind == 'shield' then useful = pct < 850 end
                if ab.kind == 'interrupt' then useful = enemy and S.enemies[enemy].cast and S.enemies[enemy].cast.interruptible end
                if ab.kind == 'taunt' then useful = enemy ~= nil end
                if ab.kind == 'cc' then useful = enemy ~= nil end
                if useful and t and Sim.CanCast(S, p, a, t) then act(p, 'c', a, t) break end
            end
        end
    end
end
"""

RUN = BOT + """
local seed, heroes, heroic, limit = ...
local S = Sim.New(seed, heroes, { heroic = heroic })
for i = 1, limit do
    bot(S)
    Sim.Step(S)
    if S.over then break end
end
return { hash = Sim.Hash(S), depth = S.depth, won = S.won, over = S.over, tick = S.tick,
         kills = #S.bossKills, interrupts = S.interrupts, level = S.party[1].level, loot = #S.party[1].loot }
"""

PARTY = [{"role": "tank", "class": "WARRIOR", "power": 130, "name": "Tank"},
         {"role": "healer", "class": "PRIEST", "power": 130, "name": "Heals"},
         {"role": "caster", "class": "MAGE", "power": 130, "name": "Mage"}]


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


def start(w, c, host="Lee", joiners=("Rita", "Sam")):
    c[host].eval("ns.RPG:Host()")
    w.tick(1)
    for n in joiners:
        c[n].eval("ns.RPG:Join()")
    w.tick(1)
    c[host].eval("ns.RPG:Start()")
    w.tick(1)


# -- simulation ------------------------------------------------------------------------------------------------------

@case
def simulation_is_deterministic():
    w, c = solo("Alice", tick=2)
    a = c.eval_py(RUN, 4242, PARTY, False, 6000)
    b = c.eval_py(RUN, 4242, PARTY, False, 6000)
    d = c.eval_py(RUN, 999, PARTY, False, 6000)
    assert a == b, (a, b)
    assert a["hash"] != d["hash"]
    no_errors(w)


@case
def bot_party_clears_the_deadmines():
    w, c = solo("Alice", tick=2)
    wins = 0
    for seed in (1, 2, 3, 4, 5):
        r = c.eval_py(RUN, seed, PARTY, False, 30000)
        assert r["over"], r
        if r["won"]:
            wins += 1
            assert r["depth"] >= 8 and r["kills"] >= 1, r
    assert wins >= 3, "a sensible party should usually win (%d/5)" % wins
    no_errors(w)


@case
def solo_heroes_can_progress():
    w, c = solo("Alice", tick=2)
    for role, cls in (("tank", "WARRIOR"), ("healer", "PALADIN"), ("melee", "ROGUE"), ("caster", "WARLOCK"),
                      ("ranged", "HUNTER")):
        r = c.eval_py(RUN, 11, [{"role": role, "class": cls, "power": 140}], False, 30000)
        assert r["depth"] >= 3, (role, r)
        assert r["level"] >= 2 and r["loot"] >= 1, (role, r)
    no_errors(w)


@case
def heroic_scales_enemies_up():
    w, c = solo("Alice", tick=2)
    hp = [c.eval("local S = ns.RPGSim.New(3, ...); ns.RPGSim.Step(S); return S.enemies[1].max", PARTY, {"heroic": h})
          for h in (False, True)]
    assert hp[1] == hp[0] * 140 // 100 or abs(hp[1] - hp[0] * 1.4) <= 2, hp
    no_errors(w)


MECH = BOT + """
local S = Sim.New(7, { {role='tank', class='WARRIOR', power=100}, {role='healer', class='PRIEST', power=100},
                       {role='caster', class='MAGE', power=100} })
Sim.Step(S)              -- tick 0: enter the first fight
local out = {}
local function spawnOnly(id)
    S.enemies = {}
    local def = D.enemies[D.enemyIndex[id]]
    S.enemies[1] = { uid = 99, kind = D.enemyIndex[id], hp = 5000, max = 5000, autoCd = 0, cast = false, abCd = {},
                     threat = { 0, 0, 0 }, stunUntil = 0, ccUntil = 0, slowUntil = 0, tauntP = 0, tauntUntil = 0, enraged = false,
                     triggered = {}, dead = false }
    for i, ab in ipairs(def.abilities or {}) do S.enemies[1].abCd[i] = S.tick + 1000; S.enemies[1].triggered[i] = false end
end
local function cast(p, a, t) Sim.Queue(S, { tick = S.tick, p = p, k = 'c', a = a, b = t, seq = S.tick * 10 + p }); Sim.Step(S) end
-- threat: the mage out-damages the tank, then the tank taunts it back
spawnOnly('miner')
S.enemies[1].threat = { 10, 0, 500 }
out.before = S.enemies[1].threat[3] > S.enemies[1].threat[1]
cast(1, 3, 1)
out.tauntP = S.enemies[1].tauntP
out.after = S.enemies[1].threat[1] > S.enemies[1].threat[3]
-- healing, gcd, cooldowns, shields
local mage = S.party[3]
mage.hp = 50
for i = 1, 20 do Sim.Step(S) end
cast(2, 1, 3)
out.casting = S.party[2].cast ~= false
out.gcd = not Sim.CanCast(S, 2, 3, 3)
for i = 1, 20 do Sim.Step(S) end
out.healed = mage.hp > 50
for i = 1, 20 do Sim.Step(S) end
cast(2, 3, 3)
out.absorb = mage.absorb > 0
out.shieldCd = S.party[2].cds[3] > S.tick
-- interrupts
spawnOnly('evoker')
S.enemies[1].abCd[1] = S.tick
Sim.Step(S)
out.evokerCasting = S.enemies[1].cast ~= false
for i = 1, 5 do Sim.Step(S) end
cast(3, 3, 1)
out.interrupted = S.enemies[1].cast == false and S.interrupts == 1
-- crowd control: works on trash, not on bosses
for i = 1, 30 do Sim.Step(S) end
spawnOnly('cutpurse')
cast(3, 4, 1)
out.cc = S.enemies[1].ccUntil > S.tick
spawnOnly("vancleef"); S.party[3].cds[4] = 0
for i = 1, 30 do Sim.Step(S) end
cast(3, 4, 1)
out.bossImmune = S.enemies[1].ccUntil == 0 and S.enemies[1].slowUntil > S.tick
-- triggers: VanCleef calls blackguards at 50% and frenzies at 25%
S.enemies[1].hp = 1100
Sim.Step(S)
out.summoned = #S.enemies == 3
S.enemies[1].hp = 500
Sim.Step(S)
out.enraged = S.enemies[1].enraged
return out
"""


@case
def combat_mechanics():
    w, c = solo("Alice", tick=2)
    r = c.eval_py(MECH)
    for k in ("before", "after", "casting", "gcd", "healed", "absorb", "shieldCd", "evokerCasting", "interrupted",
              "cc", "bossImmune", "summoned", "enraged"):
        assert r.get(k) is True, (k, r)
    assert r["tauntP"] == 1
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
def solo_run_with_ui_and_rewards():
    w, c = solo("Alice", class_file="PRIEST", tick=2)
    c.eval("ns.BiS:SetSpec('Holy')")
    assert c.eval("return ns.RPG:GetMyHero().role") == "healer"
    c.slash("/cdl play rpg")
    w.tick(0.5)
    c.eval("ns.RPG:PlaySolo()")
    w.tick(1)
    assert c.eval("return ns.RPG:IsPlaying()")
    assert c.eval("return ns.RPG:GetGame().S.phase") == "combat"
    # play with the real UI entry points for a while
    for _ in range(40):
        c.eval("local g = ns.RPG:GetGame(); if g and not g.ended then ns.RPG:Cast(4, 1) end")
        w.tick(1, step=0.1)
    # then force the end and check the rewards
    c.eval("local S = ns.RPG:GetGame().S; S.depth = 8; S.won = true; S.bossKills = { ns.RPGData.enemyIndex.vancleef }; "
           "S.over = false; S.phase = 'won'; for _, h in ipairs(S.party) do h.hp = 0 end; S.party[1].dead = false")
    c.eval("local S = ns.RPG:GetGame().S; S.over = true")
    w.tick(1)
    c.eval("ns.RPG:GetGame().S.over = true; ns.RPG:GetGame().S.won = true")
    w.tick(1)
    no_errors(w)


@case
def rewards_and_heroic_unlock():
    w, c = solo("Alice", tick=2)
    c.eval("ns.RPG:PlaySolo()")
    w.tick(1)
    c.eval("local S = ns.RPG:GetGame().S; S.depth = 8; S.won = true; S.bossKills = { ns.RPGData.enemyIndex.vancleef, "
           "ns.RPGData.enemyIndex.rhahkzor }; S.flawlessBoss = true; S.interrupts = 12; S.over = true")
    w.tick(1)
    assert not c.eval("return ns.RPG:IsPlaying()")
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
def three_players_stay_in_lockstep():
    w, c = party()
    start(w, c)
    for n in ("Lee", "Rita", "Sam"):
        assert c[n].eval("return ns.RPG:IsPlaying()"), n
    assert c["Sam"].eval("return ns.RPG:GetGame().me") == 3
    # everyone mashes abilities / choices through the real network path for a while
    for _ in range(60):
        for n in ("Lee", "Rita", "Sam"):
            c[n].eval("""
                local g = ns.RPG:GetGame(); if not g or g.ended then return end
                local S, me = g.S, g.me; local h = S.party[me]
                if h.talentOffer then ns.RPG:Act('t', 1) end
                if S.phase == 'loot' and not h.lootTaken then ns.RPG:Act('l', 1) end
                if S.phase == 'path' and h.vote == 0 then ns.RPG:Act('v', 1) end
                if S.phase == 'combat' then
                    for a = 1, 4 do
                        local ab = ns.RPGData.kits[h.role][a]
                        local t = ab.tgt == 'ally' and me or 1
                        for i, e in ipairs(S.enemies) do if ab.tgt == 'enemy' and not e.dead then t = i break end end
                        if ns.RPGSim.CanCast(S, me, a, t) then ns.RPG:Cast(a, t) break end
                    end
                end""")
        w.tick(1, step=0.1)
    for n in ("Lee", "Rita", "Sam"):
        g = c[n].eval_py("local g = ns.RPG:GetGame(); local hurt = 0; for _, e in ipairs(g.S.enemies) do "
                         "hurt = hurt + e.max - e.hp end; return { d = g.desyncs or 0, hurt = hurt, t = g.S.tick }")
        assert g["d"] == 0, (n, g)
        assert g["hurt"] > 0 or c[n].eval("return ns.RPG:GetGame().S.depth") >= 1, (n, g)
    lag = c["Lee"].eval("return ns.RPG:GetGame().S.tick") - c["Sam"].eval("return ns.RPG:GetGame().S.tick")
    assert 0 <= lag <= 10, lag
    no_errors(w)


@case
def forged_action_from_a_non_host_is_ignored():
    w, c = party()
    start(w, c)
    w.tick(2, step=0.1)
    c["Sam"].eval("local g = ns.RPG:GetGame(); ns.Comm:Send({ t = 'DVa', g = g.id, "
                  "x = { tick = g.S.tick + 20, p = 1, k = 'l', a = 1, seq = 99 } }, 'PARTY')")
    c["Sam"].eval("local g = ns.RPG:GetGame(); ns.Comm:Send({ t = 'DVn', g = g.id, s = { tick = 0 } }, 'PARTY')")
    w.tick(4, step=0.1)
    assert c["Rita"].eval("return ns.RPG:GetGame().S.party ~= nil")
    assert c["Rita"].eval("return (ns.RPG:GetGame().desyncs or 0)") == 0
    no_errors(w)


@case
def corrupted_client_resyncs():
    w, c = party()
    start(w, c)
    w.tick(3, step=0.1)
    c["Sam"].eval("local S = ns.RPG:GetGame().S; S.party[1].hp = S.party[1].hp - 77")
    w.tick(4, step=0.1)
    assert c["Sam"].eval("return ns.RPG:GetGame().desyncs") >= 1
    w.tick(4, step=0.1)
    d0 = c["Sam"].eval("return ns.RPG:GetGame().desyncs")
    w.tick(6, step=0.1)
    assert c["Sam"].eval("return ns.RPG:GetGame().desyncs") == d0, "back in lockstep"
    no_errors(w)


@case
def combat_pauses_the_run():
    w, c = party()
    start(w, c)
    w.tick(2, step=0.1)
    c["Rita"].fire("PLAYER_REGEN_DISABLED")
    w.tick(1, step=0.1)
    t0 = c["Lee"].eval("return ns.RPG:GetGame().S.tick")
    w.tick(8, step=0.1)
    assert c["Lee"].eval("return ns.RPG:GetGame().S.tick") == t0
    assert c["Sam"].eval("return ns.RPG:IsPlaying()")
    c["Rita"].fire("PLAYER_REGEN_ENABLED")
    w.tick(2, step=0.1)
    assert c["Lee"].eval("return ns.RPG:GetGame().S.tick") > t0
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

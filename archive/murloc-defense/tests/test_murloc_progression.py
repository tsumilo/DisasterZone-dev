"""Murloc Defense progression + mechanics on the real addon.

Covers: spell ranks (upgrade / sell), reputation-gated defenders, terrain (rocks block building; the same layout
on every client), goblin mines exploding once, the Windfury totem hasting neighbours, hero levels / talent
offers / picks, the party boon vote (majority, tie -> first), the new murlocs (oracle heals, netter stuns, runner
leaps, tidecaller summons), reputation + achievements at game end, map unlocks, snapshots without the fx list
and within the member wire cap, and the board UI running through a whole game without errors.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_murloc_progression.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors, World, Client  # noqa: E402

PRELUDE = """
local Sim, D = ns.MurlocSim, ns.MurlocData
local function clear(S) for p = 1, S.players do for c = 1, D.SLOTS do S.terrain[p][c] = false end end end
local function act(S, a) a.tick = S.tick; a.seq = (a.seq or 0) + S.tick; Sim.Queue(S, a); Sim.Step(S) end
"""


def run(c, body, *args):
    return c.eval_py(PRELUDE + body, *args)


@case
def upgrade_and_sell():
    w, c = solo("Alice", tick=2)
    r = run(c, """
        local S = Sim.New(1, 1); clear(S); S.gold[1] = 1000
        act(S, { p = 1, k = 'b', a = 1, b = 2, c = 2 })
        local t = S.towers[1][2]
        local dmg1, spent1 = t.dmg, t.spent
        act(S, { p = 1, k = 'u', a = 1, b = 2 })
        act(S, { p = 1, k = 'u', a = 1, b = 2 })
        local dmg3, rank = t.dmg, t.rank
        local capped = Sim.CanUpgrade(S, 1, 1, 2)
        local before = S.gold[1]
        act(S, { p = 1, k = 's', a = 1, b = 2 })
        return { dmg1 = dmg1, dmg3 = dmg3, rank = rank, capped = capped, refund = S.gold[1] - before,
                 spent = t.spent, gone = S.towers[1][2] == false }""")
    assert r["rank"] == 3 and r["dmg3"] == r["dmg1"] * 2 and r["capped"] is False
    assert r["spent"] == 75 + 75 + 150
    assert r["gone"] and abs(r["refund"] - r["spent"] // 2) <= 1
    no_errors(w)


@case
def reputation_gates_defenders():
    w, c = solo("Alice", tick=2)
    r = run(c, """
        local S = Sim.New(1, 2, { { tier = 0 }, { tier = 3 } }); clear(S); S.gold[1], S.gold[2] = 999, 999
        return { neutralMine = Sim.CanBuild(S, 1, 1, 1, D.defenderIndex.mine),
                 reveredTotem = Sim.CanBuild(S, 2, 2, 1, D.defenderIndex.totem),
                 forged = Sim.New(1, 1, { { tier = 99 } }).heroes[1].tier }""")
    assert r["neutralMine"] is False and r["reveredTotem"] is True and r["forged"] == 4
    no_errors(w)


@case
def terrain_is_seeded_and_rocks_block():
    w, c = solo("Alice", tick=2)
    r = run(c, """
        local A, B = Sim.New(77, 3, nil, 2), Sim.New(77, 3, nil, 2)
        local same, rock = true, nil
        for p = 1, 3 do for col = 1, D.SLOTS do
            if A.terrain[p][col] ~= B.terrain[p][col] then same = false end
            if A.terrain[p][col] == 'rocks' then rock = { p, col } end
        end end
        local first = A.terrain[1][1]
        local blocked = rock and Sim.CanBuild(A, rock[1], rock[1], rock[2], 1)
        return { same = same, first = first, blocked = blocked, hasRock = rock ~= nil }""")
    assert r["same"] and r["first"] is False
    if r["hasRock"]:
        assert r["blocked"] is False
    no_errors(w)


@case
def mine_explodes_once_and_totem_hastes():
    w, c = solo("Alice", tick=2)
    r = run(c, """
        local S = Sim.New(1, 1, { { tier = 4 } }); clear(S); S.gold[1] = 9999
        act(S, { p = 1, k = 'b', a = 1, b = 5, c = D.defenderIndex.mine })
        act(S, { p = 1, k = 'b', a = 1, b = 2, c = D.defenderIndex.rifleman })
        act(S, { p = 1, k = 'b', a = 1, b = 3, c = D.defenderIndex.totem })
        S.mobs = { { id = 900, kind = 1, lane = 1, x = Sim.SlotX(5) + 100, px = 0, hp = 50, max = 50, slow = 0, cd = 0,
                     hcd = 0, hopped = false, leapt = false, netted = false },
                   { id = 901, kind = 1, lane = 1, x = Sim.SlotX(5) + 600, px = 0, hp = 50, max = 50, slow = 0, cd = 0,
                     hcd = 0, hopped = false, leapt = false, netted = false } }
        S.phase = 'wave'; S.spawns = {}
        Sim.Step(S)
        local mineGone = S.towers[1][5] == false
        local alive = #S.mobs
        local rifle = S.towers[1][2]
        rifle.cd = 0
        S.mobs = { { id = 902, kind = 2, lane = 1, x = 5000, px = 5000, hp = 9999, max = 9999, slow = 0, cd = 0,
                     hcd = 0, hopped = false, leapt = false, netted = false } }
        Sim.Step(S)
        return { mineGone = mineGone, alive = alive, cd = rifle.cd, rate = rifle.rate }""")
    assert r["mineGone"] and r["alive"] == 0, r
    assert r["cd"] < r["rate"], r
    no_errors(w)


@case
def heroes_level_and_pick_talents():
    w, c = solo("Alice", tick=2)
    r = run(c, """
        local S = Sim.New(5, 1, { { role = 'caster', class = 'MAGE', power = 100 } }); clear(S)
        act(S, { p = 1, k = 'b', a = 1, b = 1, c = 0 })
        local dmg0 = S.towers[1][1].dmg
        for i = 1, D.XpForLevel(1) do
            S.mobs[#S.mobs + 1] = { id = 1000 + i, kind = 1, lane = 1, x = 9000, px = 9000, hp = 0, max = 1, slow = 0,
                                    cd = 0, hcd = 0, hopped = false, leapt = false, netted = false }
        end
        S.phase = 'wave'; S.spawns = {}
        Sim.Step(S)
        local level, offer = S.heroLevel[1], S.talentOffer[1] and #S.talentOffer[1] or 0
        local pickIdx = S.talentOffer[1][1]
        act(S, { p = 1, k = 't', a = 1 })
        return { level = level, offer = offer, picked = S.talentPicks[1][pickIdx], after = S.talentOffer[1],
                 dmg0 = dmg0, dmg1 = S.towers[1][1].dmg }""")
    assert r["level"] == 2 and r["offer"] == 3 and r["picked"] == 1 and r["after"] is False, r
    assert r["dmg1"] >= r["dmg0"], r
    no_errors(w)


@case
def boon_vote_majority_and_tie():
    w, c = solo("Alice", tick=2)
    r = run(c, """
        local S = Sim.New(9, 3); clear(S)
        S.phase = 'wave'; S.spawns = {}; S.mobs = {}
        Sim.Step(S)                                    -- wave over -> offer
        local offer = { S.boonOffer[1], S.boonOffer[2], S.boonOffer[3] }
        act(S, { p = 1, k = 'v', a = 2 }); act(S, { p = 2, k = 'v', a = 2 }); act(S, { p = 3, k = 'v', a = 3 })
        S.phaseEnd = S.tick
        Sim.Step(S)
        local won = S.boonsTaken[1]
        -- nobody votes: the first offer wins
        S.phase = 'wave'; S.spawns = {}; S.mobs = {}
        Sim.Step(S)
        local first = S.boonOffer[1]
        S.phaseEnd = S.tick
        Sim.Step(S)
        return { expect = offer[2], won = won, first = first, won2 = S.boonsTaken[2] }""")
    assert r["won"] == r["expect"] and r["won2"] == r["first"], r
    no_errors(w)


@case
def new_murlocs_do_their_thing():
    w, c = solo("Alice", tick=2)
    r = run(c, """
        local function mob(id, kind, x, hp)
            return { id = id, kind = D.murlocIndex[kind], lane = 1, x = x, px = x, hp = hp or 100, max = 200, slow = 0,
                     cd = 0, hcd = 0, hopped = false, leapt = false, netted = false }
        end
        local S = Sim.New(3, 1); clear(S); S.gold[1] = 999; S.phase = 'wave'; S.spawns = {}
        act(S, { p = 1, k = 'b', a = 1, b = 4, c = 1 })
        local foot = S.towers[1][4]
        foot.dmg = 0
        S.mobs = { mob(1, 'oracle', 9000, 200), mob(2, 'forager', 9200, 50),
                   mob(3, 'netter', foot.x + 300, 200), mob(4, 'coastrunner', foot.x + 300, 200) }
        S.mobs[2].max = 200
        for i = 1, 3 do Sim.Step(S) end
        local healed = S.mobs[2] and S.mobs[2].hp > 50
        local netted = foot.stun > 0
        local runner
        for _, m in ipairs(S.mobs) do if m.id == 4 then runner = m end end
        local T = Sim.New(4, 1); clear(T); T.phase = 'wave'; T.spawns = {}; T.tick = 70
        T.mobs = { mob(10, 'tidecaller', 9000, 999) }
        Sim.Step(T)
        return { healed = healed, netted = netted, leapt = runner and runner.x < foot.x, summoned = #T.mobs }""")
    assert r["healed"] and r["netted"] and r["leapt"], r
    assert r["summoned"] == 2, r
    no_errors(w)


@case
def game_end_awards_reputation_and_achievements():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Murloc:PlaySolo()")
    w.tick(1)
    c.eval("local S = ns.Murloc:GetGame().S; S.wave = 10; S.kills = 400; S.bossKills = { ns.MurlocData.murlocIndex.king }; "
           "S.maxGold = 1200; S.lives = 0; S.over = false")
    w.tick(1)
    assert not c.eval("return ns.Murloc:IsPlaying()")
    rep = c.eval("return ns.Murloc:GetRep()")
    assert rep == 10 * 12 + 200, rep
    for a in ("wave5", "wave10", "king", "rich"):
        assert c.eval("return ns.Murloc:HasAchievement(...)", a), a
    assert not c.eval("return ns.Murloc:HasAchievement('wave20')")
    # Friendly unlocks Stranglethorn
    c.eval("ns.Games:GetData('murloc').rep = 0")
    assert not c.eval("return ns.Murloc:MapUnlocked(2)")
    c.eval("ns.Games:GetData('murloc').rep = 300")
    assert c.eval("return ns.Murloc:MapUnlocked(2)") and not c.eval("return ns.Murloc:MapUnlocked(3)")
    c.eval("ns.Murloc:SetMap(3)")
    assert c.eval("return ns.Murloc:GetMap()") == 1, "locked map refused"
    c.eval("ns.Murloc:SetMap(2)")
    assert c.eval("return ns.Murloc:GetMap()") == 2
    assert c.eval("return ns.Murloc:GetMyHero().tier") == 1
    no_errors(w)


@case
def snapshot_fits_the_member_wire_cap():
    w, c = solo("Alice", tick=2)
    size = c.eval("""
        local Sim, D = ns.MurlocSim, ns.MurlocData
        local S = Sim.New(3, 5, { {tier=4}, {tier=4}, {tier=4}, {tier=4}, {tier=4} }, 3)
        for p = 1, 5 do S.gold[p] = 99999 end
        for p = 1, 5 do for col = 1, D.SLOTS do
            Sim.Queue(S, { tick = 0, p = p, k = 'b', a = p, b = col, c = (col % 3) + 1, seq = p * 10 + col })
        end end
        local LS, LD = LibStub('LibSerialize'), LibStub('LibDeflate')
        local worst = 0
        for i = 1, 2500 do
            Sim.Step(S)
            if i % 250 == 0 then
                local fx = S.fx; S.fx = {}
                local enc = LD:EncodeForWoWAddonChannel(LD:CompressDeflate(LS:Serialize({ t = 'MDn', g = 'x', s = S })))
                S.fx = fx
                if #enc > worst then worst = #enc end
            end
        end
        return worst""")
    assert size < 4000, size
    no_errors(w)


@case
def board_ui_runs_a_whole_game():
    w, c = solo("Alice", tick=2)
    c.slash("/cdl play murloc")
    w.tick(0.5)
    c.eval("ns.Murloc:PlaySolo()")
    w.tick(1)
    c.eval("local g = ns.Murloc:GetGame(); g.S.gold[1] = 5000")
    for col, kind in ((1, 0), (2, 1), (3, 2), (4, 3)):
        c.eval("ns.Murloc:Act('b', 1, ...)", col, kind)
    w.tick(2)
    c.eval("ns.Murloc:Act('u', 1, 2)")
    c.eval("ns.Murloc:Act('l')")
    w.tick(90, step=0.1)
    c.eval("local S = ns.Murloc:GetGame().S; S.lives = 0")
    w.tick(1)
    assert not c.eval("return ns.Murloc:IsPlaying()")
    c.eval("ns.Murloc:Quit()")
    w.tick(0.5)
    no_errors(w)


if __name__ == "__main__":
    run_all()

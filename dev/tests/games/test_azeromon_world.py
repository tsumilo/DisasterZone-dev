"""Azeromon step 2: day and night, class perks, raid-kill rares.

Covers: realm-time periods and the sky tint (outdoors only, none by day), time-of-day encounter weights (night
creatures and night rares), the warlock's doubled Shadow beasts, every class perk in real battles (hunter taming
odds, mage exp, warrior Battle Shout in trainer battles only, rogue prize money, druid heal, paladin cleanse,
priest blackout, shaman walking speed) and never in battles between players, class lines from NPCs, and raid
rares: a real ENCOUNTER_END in a raid sets the creature loose for 24 hours in its area (with the rare banner,
alert sound and achievements), nothing happens outside a raid or on a wipe, and it expires.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_world.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def game(seed=7, cls="PALADIN"):
    w, c = solo("Alice", tick=2, class_file=cls)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    c.eval("ns.Azero:NewGame()")
    return w, c


def strong(c, sp="murkling", lvl=30):
    c.eval("local M = ns.AzeroMon; local m = M.New(%r, %d, ns.Azero.rng); m.moves = M.DefaultMoves(%r, %d); "
           "ns.Azero.save.party = { m }" % (sp, lvl, sp, lvl))


def log(c):
    return "\n".join(c.eval_py("return T_AZ.log") or [])


# -- day and night ----------------------------------------------------------------------------------------------------

@case
def periods_follow_the_realm_clock_and_tint_outdoors_only():
    w, c = game()
    expect = {0: "night", 4.9: "night", 5.5: "dawn", 7: "day", 12: "day", 18.5: "dusk", 21: "night", 23.9: "night"}
    for h, p in expect.items():
        assert c.eval("ns.Azero.clockHour = %s; return ns.Azero:Period()" % h) == p, (h, p)
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")                  # CONTINUE
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    c.eval("ns.Azero:EnterMap('route1', 11, 20, 'up', true)")
    alpha = lambda: c.eval("return ns.AzeroUI._SkyAlpha()")
    c.eval("ns.Azero.clockHour = 23")
    w.tick(0.1)
    assert alpha() > 0.4
    c.eval("ns.Azero.clockHour = 12")
    w.tick(0.1)
    assert alpha() == 0
    c.eval("ns.Azero.clockHour = 19.5")
    w.tick(0.1)
    assert 0.1 < alpha() < 0.3                              # amber dusk, in between
    c.eval("ns.Azero.clockHour = 23; ns.Azero:EnterMap('home', 4, 6, 'up', true)")
    w.tick(0.1)
    assert alpha() == 0                                    # indoors: no sky
    no_errors(w)


@case
def night_brings_different_beasts_and_night_rares():
    w, c = game()
    counts = c.eval_py(r"""
      local G = ns.Azero
      local m = G.Compile('route1')
      local out = {}
      for _, h in ipairs({ 12, 23 }) do
        G.clockHour = h
        local n = {}
        for i = 1, 4000 do
          local sp = G:RollEncounter(G:EncounterList(m, false))
          n[sp] = (n[sp] or 0) + 1
        end
        out[tostring(h)] = n
      end
      return out""")
    day, night = counts["12"], counts["23"]
    assert day.get("motherfang", 0) == 0, day                   # night rare: never by day
    assert night.get("motherfang", 0) > 20, night               # ~2% of night encounters
    assert night["owlet"] > 3 * day.get("owlet", 1), (day, night)
    assert night["webling"] > 2 * day["webling"], (day, night)
    no_errors(w)


@case
def warlocks_draw_shadow_beasts():
    w, c = game()
    r = c.eval_py("""local G = ns.Azero
      G.clockHour = 12
      local e = { sp = 'webling', weight = 10 }
      local rare = { sp = 'motherfang', weight = 2, rare = true }
      G.classOverride = 'HUNTER'
      local a, ar = G:EncounterWeight(e), G:EncounterWeight(rare)
      G.classOverride = 'WARLOCK'
      return { a, G:EncounterWeight(e), ar, G:EncounterWeight(rare) }""")
    assert r == [10, 20, 2, 2], r
    no_errors(w)


# -- class perks ------------------------------------------------------------------------------------------------------

def start_battle(c, lua):
    c.eval("ns.Azero:Run(function(g) %s end)" % lua)
    return c.eval_py("local b = ns.Azero.pending and ns.Azero.pending.battle "
                     "return b and { catch = b.catchMult, exp = b.expMult, atk = b.ally.stages.atk } or nil")


@case
def hunters_tame_better_and_mages_learn_faster_in_battles_but_not_against_players():
    w, c = game(cls="HUNTER")
    strong(c)
    b = start_battle(c, "g:WildBattle('owlet', 3)")
    assert b["catch"] == 1.25 and b["exp"] == 1, b
    c.eval("ns.Azero.pending = nil ns.Azero.co = nil ns.Azero.battle = nil")
    c.eval("ns.Azero.classOverride = 'MAGE'")
    b = start_battle(c, "g:WildBattle('owlet', 3)")
    assert b["catch"] == 1 and b["exp"] == 1.1, b
    # a battle between players never gets perks (both clients must compute it identically)
    pv = c.eval_py("""ns.Azero.classOverride = 'WARRIOR'
      local M = ns.AzeroMon
      local b = ns.AzeroBattle.New({ party = { M.New('murkling', 10, ns.Azero.rng) }, foes = { M.New('owlet', 10, ns.Azero.rng) },
        rng = ns.Azero.rng, pvp = { host = true, name = 'Bob' }, startAtk = 1 })
      return { catch = b.catchMult, exp = b.expMult, atk = b.ally.stages.atk }""")
    assert pv == {"catch": 1, "exp": 1, "atk": 0}, pv
    no_errors(w)


@case
def warriors_shout_in_trainer_battles_only():
    w, c = game(cls="WARRIOR")
    strong(c)
    b = start_battle(c, "g:Battle('hunter1')")
    assert b["atk"] == 1, b
    texts = c.eval_py("local t = {} for _, e in ipairs(ns.Azero.pending.battle.events) do "
                      "if e.t == 'text' then t[#t + 1] = e.text end end return t")
    assert any("Battle Shout!" in t for t in texts), texts
    c.eval("ns.Azero.pending = nil ns.Azero.co = nil ns.Azero.battle = nil")
    b = start_battle(c, "g:WildBattle('owlet', 3)")
    assert b["atk"] == 0, b
    no_errors(w)


@case
def rogues_druids_paladins_priests_and_shamans():
    w, c = game(cls="ROGUE")
    strong(c)
    money = lambda: c.eval("return ns.Azero.save.money")
    m0 = money()
    c.eval("ns.Azero:Run(function(g) g:Battle('hunter1') end)")
    c.eval("T_AZ.settle()")
    prize = 20 * 4                                         # prize 20 x the last beast's level (4)
    assert money() - m0 == int(prize * 1.2), (money() - m0, prize)
    # druid: +10% max HP after a win
    c.eval("ns.Azero.classOverride = 'DRUID'; local m = ns.Azero.save.party[1]; m.hp = 20; m.status = nil")
    c.eval("ns.Azero:Run(function(g) g:WildBattle('owlet', 2) end)")
    c.eval("T_AZ.settle()")
    r = c.eval_py("local m = ns.Azero.save.party[1] return { hp = m.hp, max = ns.AzeroMon.MaxHP(m) }")
    assert r["hp"] >= 20 + r["max"] // 10 - 1, r
    # paladin: poison cleansed after a battle
    c.eval("ns.Azero.classOverride = 'PALADIN'; ns.Azero.save.party[1].status = 'psn'")
    c.eval("ns.Azero:Run(function(g) g:WildBattle('owlet', 2) end)")
    c.eval("T_AZ.settle()")
    assert c.eval("return ns.Azero.save.party[1].status") is None
    # priest: no money lost on a blackout
    c.eval("ns.Azero.classOverride = 'PRIEST'; ns.Azero.save.money = 1000")
    c.eval("ns.Azero:Run(function(g) g:Blackout() end)")
    c.eval("T_AZ.settle()")
    assert money() == 1000
    c.eval("ns.Azero.classOverride = 'HUNTER'; ns.Azero.save.money = 1000")
    c.eval("ns.Azero:Run(function(g) g:Blackout() end)")
    c.eval("T_AZ.settle()")
    assert money() == 500
    # shaman: faster on foot
    durs = c.eval_py("""local G = ns.Azero
      G:EnterMap('route1', 11, 20, 'up', true)
      local out = {}
      for _, cls in ipairs({ 'HUNTER', 'SHAMAN' }) do
        G.classOverride = cls
        G:StartStep('up', false)
        out[cls] = G.moving.dur
        G.moving = nil
      end
      return out""")
    assert abs(durs["SHAMAN"] - durs["HUNTER"] * 0.8) < 1e-9, durs
    no_errors(w)


@case
def perks_say_so_when_they_change_something():
    w, c = game(cls="ROGUE")
    strong(c)
    c.eval("T_AZ.log = {}")
    m0 = c.eval("return ns.Azero.save.money")
    c.eval("ns.Azero:Run(function(g) g:Battle('hunter1') end)")
    c.eval("T_AZ.settle()")
    assert "You got 96c for winning! (Pick Pocket)" in log(c), log(c)       # 20 x level 4, +20%
    assert c.eval("return ns.Azero.save.money") - m0 == 96                   # what it says is what you get
    c.eval("ns.Azero.classOverride = 'MAGE' T_AZ.log = {}")
    c.eval("ns.Azero:Run(function(g) g:WildBattle('owlet', 2) end)")
    c.eval("T_AZ.settle()")
    assert "Exp. Points! (Arcane Intellect)" in log(c), log(c)
    c.eval("ns.Azero.classOverride = 'DRUID' T_AZ.log = {} ns.Azero.save.party[1].hp = 20")
    c.eval("ns.Azero:Run(function(g) g:WildBattle('owlet', 2) end)")
    c.eval("T_AZ.settle()")
    assert "Rejuvenation: your beasts recovered a little." in log(c), log(c)
    c.eval("ns.Azero.classOverride = 'PALADIN' T_AZ.log = {} ns.Azero.save.party[1].status = 'psn' "
           "ns.Azero.save.bag = {}")                          # (no Anti-Venom for the bot to drink)
    c.eval("ns.Azero:Run(function(g) g:WildBattle('owlet', 2) end)")
    c.eval("T_AZ.settle()")
    assert "Cleanse: Tidehunter is cured." in log(c), log(c)      # (the Murkling evolved after the first battle)
    c.eval("ns.Azero.classOverride = 'PRIEST' T_AZ.log = {}")
    c.eval("ns.Azero:Run(function(g) g:Blackout() end)")
    c.eval("T_AZ.settle()")
    assert "Spirit of Redemption: Alice kept every coin" in log(c), log(c)
    # a perk that changed nothing says nothing
    c.eval("ns.Azero.classOverride = 'DRUID' T_AZ.log = {} local m = ns.Azero.save.party[1] m.hp = ns.AzeroMon.MaxHP(m)")
    c.eval("ns.Azero:Run(function(g) g:WildBattle('owlet', 2) end)")
    c.eval("T_AZ.settle()")
    assert "Rejuvenation" not in log(c), log(c)
    no_errors(w)


@case
def npcs_greet_some_classes():
    w, c = game(cls="HUNTER")
    c.eval("ns.Azero:EnterMap('lab', 4, 4, 'up', true)")
    c.eval("ns.Azero:PressA()")                            # Huntmaster Aldric, before choosing a starter
    c.eval("T_AZ.settle()")
    assert "A hunter!" in log(c)
    c.eval("T_AZ.log = {} ns.Azero.classOverride = 'ROGUE'")
    c.eval("ns.Azero:PressA()")
    c.eval("T_AZ.settle()")
    assert "Huntmaster Aldric: Ah," in log(c) and "A hunter!" not in log(c)
    no_errors(w)


# -- raid rares -------------------------------------------------------------------------------------------------------

def in_raid(c, on=True):
    if on:
        c.eval("IsInRaid = function() return true end IsInInstance = function() return true, 'raid' end")
    else:
        c.eval("IsInRaid = function() return false end IsInInstance = function() return false, 'none' end")


@case
def a_raid_kill_sets_a_rare_loose_for_a_day():
    w, c = game()
    n0 = len(c.chat_frame)
    in_raid(c)
    c.fire("ENCOUNTER_END", 650, "Gruul the Dragonkiller", 4, 25, 0)      # a wipe: nothing
    assert c.eval_py("return ns.Azero:RaidRareStore()") in ({}, [], None)
    c.fire("ENCOUNTER_END", 650, "Gruul the Dragonkiller", 4, 25, 1)      # the kill
    store = c.eval_py("return ns.Azero:RaidRareStore()")
    left = store["gronnling"] - c.eval("return time()")
    assert 24 * 3600 - 5 <= left <= 24 * 3600, left
    assert any("Gronnling" in str(l) and "Westfall" in str(l) for l in c.chat_frame[n0:]), c.chat_frame[n0:]
    assert "raidscout" in c.eval_py("local t = {} for id in pairs(ns.AzeroAch.Earned()) do t[#t+1] = id end return t")
    # it roams Westfall's tall grass (not the shore, not Elwynn), and the banner says so
    r = c.eval_py("""local G = ns.Azero
      local function has(map, coast)
        for _, e in ipairs(G:EncounterList(G.Compile(map), coast)) do if e.sp == 'gronnling' then return true end end
        return false
      end
      G:EnterMap('westfall', 11, 30, 'up')
      return { wf = has('westfall', false), coast = has('westfall', true), elwynn = has('route1', false),
               banner = G.banner and G.banner.text }""")
    assert r["wf"] and not r["coast"] and not r["elwynn"], r
    assert "a rare roams here" in r["banner"], r
    # a kill outside a raid (a dungeon, say) does nothing; an expired rare is gone
    in_raid(c, False)
    c.fire("ENCOUNTER_END", 652, "Attumen the Huntsman", 3, 10, 1)
    assert "midnight" not in c.eval_py("return ns.Azero:RaidRareStore()")
    c.eval("ns.Azero:RaidRareStore().gronnling = time() - 1")
    assert c.eval("return #ns.Azero:ActiveRaidRares('westfall')") == 0
    no_errors(w)


@case
def meeting_and_taming_a_rare():
    w, c = game()
    strong(c, lvl=50)                                      # rares hit hard and nets rarely hold them (~9%)
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    s0 = len(c.eval_py("return __MOCK.sounds") or [])
    c.eval("ns.Azero.save.bag.greatnet = 60")
    c.eval("ns.Azero:Run(function(g) g:WildBattle('gronnling', 16, true) end)")
    w.tick(0.2)
    sounds = c.eval_py("return __MOCK.sounds")[s0:]
    assert 8959 in sounds, sounds                             # the rare-spawn alert
    texts = c.eval_py("local t = {} for _, e in ipairs(ns.Azero.battle.events) do "
                      "if e.t == 'text' then t[#t + 1] = e.text end end return t")
    assert any("A rare Gronnling appeared!" in t for t in texts), texts
    # throw nets until it is tamed (the UI would; the engine is enough here)
    c.eval("""local b = ns.Azero.battle
      b.foe.mon.hp = 1
      for i = 1, 60 do
        if b.need == 'action' then b.foe.mon.hp = 1 b:Act({ kind = 'item', item = 'greatnet' }) end
      end""")
    assert c.eval("return ns.Azero.battle.result") == "caught"
    got = c.eval_py("local t = {} for id in pairs(ns.AzeroAch.Earned()) do t[#t+1] = id end return t")
    assert "rare1" in got and "raidrare" in got, got
    no_errors(w)


if __name__ == "__main__":
    run_all()

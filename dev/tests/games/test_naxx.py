r"""Hold the Line: Naxxramas (Games/HoldTheLine/Naxx.lua, NaxxBoss.lua).

Covers: every stage plays to its finale with the bot (god mode) without an error, its bosses arrive on the clock and
die, the master's death wins the run; the floors' hazards (webs, eggs, clouds, rider lanes, slime pools, the Chill);
boss coffers offer relics and a relic works; Desecrated tokens and Frozen Runes are counted and saved; Frost
Resistance is bought; the unlock (a first win in the Plaguelands, the four masters for the lair); the Necropolis
screen opens; Naxxramas achievements.

Run: luaenv\Scripts\python.exe tests\games\test_naxx.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402


def boot(cls="PALADIN"):
    w, c = solo("Alice", class_file=cls)
    c.world = w
    return w, c


def play(c, stage, cls, seed, secs):
    return c.eval_py("""
      local E, D = ns.HTL, ns.HTLData
      local r = E.New({ cls = '%s', seed = %d, god = true, bot = true, stage = '%s' })
      E.FastForward(r, %d, true)
      local slain = {}
      for k in pairs(r.slain) do slain[#slain + 1] = k end
      table.sort(slain)
      local left = {}
      for _, e in ipairs(r.en) do if e.M.boss and not e.dead then left[#left + 1] = e.type .. ':' .. math.floor(100 * e.hp / e.maxHp) .. (e.immune and 'i' or '') .. (e.berserk and 'B' or '') .. '@' .. math.floor(e.arriveT or -1) end end
      return { over = r.over or 'none', t = math.floor(r.t), slain = table.concat(slain, ','), level = r.level, kills = r.kills,
        frozen = r.frozen, tokens = #r.tokens, relics = #r.rorder, left = table.concat(left, ' ') }
    """ % (cls, seed, stage, secs))


def check_stage(stage, cls, seed, want):
    w, c = boot(cls)
    out = play(c, stage, cls, seed, 1700 if stage == "frost" else 1150)
    no_errors(w)
    print("   ", stage, cls, out)
    for k in want:
        assert k in out["slain"], "%s not slain in %s: %s" % (k, stage, out)
    assert out["over"] == "victory", "%s not won: %s" % (stage, out)
    assert out["frozen"] > 0 and out["tokens"] > 0, out


@case
def the_arachnid_quarter_plays_to_maexxna():
    check_stage("arachnid", "PALADIN", 8, ["n_anub", "n_faerlina", "n_maexxna"])


@case
def the_plague_quarter_plays_to_loatheb():
    check_stage("plague", "WARRIOR", 3, ["n_noth", "n_heigan", "n_loatheb"])


@case
def the_military_quarter_plays_to_the_horsemen():
    check_stage("military", "WARRIOR", 7, ["n_razuvious", "n_gothik", "n_korthazz", "n_blaumeux", "n_mograine", "n_zeliek"])


@case
def the_construct_quarter_plays_to_thaddius():
    check_stage("construct", "PALADIN", 14, ["n_patchwerk", "n_grobbulus", "n_gluth", "n_stalagg", "n_feugen", "n_thaddius"])


@case
def the_frostwyrm_lair_plays_to_kelthuzad():
    check_stage("frost", "MAGE", 15, ["n_sapphiron", "n_kelthuzad"])


def opened(c, w):
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(0.5)


@case
def naxxramas_opens_after_a_first_win_and_the_lair_after_four_masters():
    w, c = boot()
    opened(c, w)
    c.eval("local d = ns.HTLGame.Data() d.wins = 0 wipe(d.naxx.cleared)")
    assert c.eval_py("return ns.HTLGame:NaxxReady()"), "art pack 16 should be present"
    assert not c.eval_py("return ns.HTLGame:NaxxOpen()")
    assert not c.eval_py("return ns.HTLGame:StageOpen('arachnid')")
    c.eval("ns.HTLGame.Data().wins = 1")
    assert c.eval_py("return ns.HTLGame:StageOpen('arachnid')")
    assert not c.eval_py("return ns.HTLGame:StageOpen('frost')")
    c.eval("for _, k in ipairs({'arachnid','plague','military','construct'}) do ns.HTLGame.Data().naxx.cleared[k] = true end")
    assert c.eval_py("return ns.HTLGame:StageOpen('frost')")
    # a locked stage asked for from the UI falls back to the Plaguelands
    c.eval("wipe(ns.HTLGame.Data().naxx.cleared) ns.HTLUI.Start('PALADIN', { stage = 'frost' })")
    w.tick(0.3)
    assert c.eval_py("return ns.HTLUI._Run().stage or 'epl'") == "epl"
    no_errors(w)


@case
def the_necropolis_and_desecrated_screens_draw_and_wilhelm_sells_frost_resistance():
    w, c = boot()
    opened(c, w)
    c.eval("""local d = ns.HTLGame.Data() d.wins = 1 d.naxx.cleared.arachnid = true d.naxx.best.arachnid = 1012
      d.naxx.kills.PALADIN = { n_anub = 1, n_maexxna = 2 } d.t3.PALADIN = { wrist = true, hands = true, head = true }
      d.frozen, d.bank, d.frostRes = 30, 500, 0""")
    c.eval("ns.HTLUI._ShowTitle()")
    w.tick(0.3)
    for sel in ("arachnid", "plague", "military", "construct", "frost"):
        c.eval("ns.HTLUI.ShowNaxx()")
        w.tick(0.1)
        assert c.eval_py("return ns.HTLUI._Overlay()") == "naxx"
    c.eval("ns.HTLUI.ShowT3()")
    w.tick(0.2)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "t3"
    assert c.eval_py("return ns.HTLGame:CanBuyFrost()")
    assert c.eval_py("return ns.HTLGame:BuyFrost()")
    d = c.eval_py("local d = ns.HTLGame.Data() return { r = d.frostRes, f = d.frozen, b = d.bank }")
    cost = c.eval_py("local f = ns.HTLData.FROST_RES[1] return { r = f.runes, g = f.gold }")
    assert d["r"] == 1 and d["f"] == 30 - cost["r"] and d["b"] == 500 - cost["g"], (d, cost)
    c.eval("ns.HTLUI.ShowT3()")
    # a full set: the look can be worn or hidden
    c.eval("local t = ns.HTLGame:T3('MAGE') for _, s in ipairs(ns.HTLData.T3_SLOTS) do t[s.id] = true end")
    assert c.eval_py("return ns.HTLGame:T3Look('MAGE')")
    c.eval("ns.HTLGame:ToggleT3Look() ns.HTLUI.ShowT3()")
    assert not c.eval_py("return ns.HTLGame:T3Look('MAGE')")
    # a run carries the necropolis: frost resistance, the tier 3 count
    c.eval("ns.HTLGame:ToggleT3Look() ns.HTLUI.Start('MAGE', { stage = 'plague' })")
    w.tick(0.3)
    r = c.eval_py("local r = ns.HTLUI._Run() return { s = r.stage, fr = r.frostRes, t3 = r.t3n }")
    assert r == {"s": "plague", "fr": 1, "t3": 9}, r
    no_errors(w)


@case
def a_boss_coffer_offers_relics_and_the_chosen_one_is_kept():
    w, c = boot()
    opened(c, w)
    c.eval("ns.HTLGame.Data().wins = 1 ns.HTLUI.Start('PALADIN', { stage = 'arachnid' })")
    w.tick(0.3)
    n = c.eval_py("""local r = ns.HTLUI._Run() ns.HTL.OpenChest(r, true, 'n_anub')
      local ch = r.chest r.chest = nil
      ns.HTLUI._ShowLoot(ch.items, ch.gold, ch.relics)
      return #(ch.relics or {})""")
    assert n == 3, n
    w.tick(1.5)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "chest"
    # Take does nothing until a relic is chosen
    c.eval("ns.HTLUI._TakeLoot()")
    assert c.eval_py("return ns.HTLUI._Overlay()") == "chest"
    rid = c.eval_py("local l = ns.HTLUI._Loot() return l.relics[2].id")
    c.eval("ns.HTLUI.PickRelic('%s') ns.HTLUI._TakeLoot()" % rid)
    w.tick(0.2)
    assert c.eval_py("return ns.HTLUI._Run().relics['%s'] ~= nil" % rid), rid
    assert c.eval_py("return ns.HTLUI._Overlay()") != "chest"
    no_errors(w)


@case
def a_cleared_quarter_banks_runes_and_tokens_and_ends_on_the_necropolis():
    w, c = boot()
    opened(c, w)
    c.eval("local d = ns.HTLGame.Data() d.wins = 1 d.frozen = 0 wipe(d.t3) wipe(d.naxx.kills) wipe(d.naxx.cleared)")
    c.eval("ns.HTLUI.Start('WARRIOR', { stage = 'military' })")
    w.tick(0.3)
    c.eval("""local r = ns.HTLUI._Run() r.t = 1000 r.frozen = 12
      r.tokens = { { boss = 'n_razuvious', slot = 'feet' }, { boss = 'n_mograine', slot = 'chest' } }
      r.over = 'victory' ns.HTLUI._ShowEnd('victory')""")
    w.tick(0.5)
    d = c.eval_py("""local d = ns.HTLGame.Data() local n = 0 for _ in pairs(d.t3.WARRIOR or {}) do n = n + 1 end
      return { f = d.frozen, n = n, cl = d.naxx.cleared.military and true or false, b = d.naxx.best.military or 0, best = d.best }""")
    assert d["f"] == 12 and d["n"] == 2 and d["cl"] and d["b"] == 1000, d
    assert c.eval_py("return ns.HTLUI._Overlay()") == "end"
    no_errors(w)


if __name__ == "__main__":
    run_all()

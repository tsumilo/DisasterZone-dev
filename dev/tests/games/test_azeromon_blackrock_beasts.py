"""Azeromon: Blackrock's beasts, battles and crafting (badges 6 and 7).

Covers: species #131-166 (types, moves, evolutions, rares, the legendary), the new evolutions on old lines
(Venom Web Spider -> Glassweb Spider, Black Ravager Mastiff -> Core Hound, Harvest Watcher + Dark Iron Bar -> Heavy
War Golem as a branch beside Crowd Pummeler) and the lookups that find a form's earlier forms; the 12 new moves in
battle (burns, Conflagrate, Steam Jet, Magma Shackles, Panic and Free Action, War Stomp, Molten Armor) and gear with
a resistance, regeneration or a stun; Magmadar as a once-per-save legendary; the new trainers, badges, raid rares and
Nefarius's cache; the shops' shelves; skill tiers to 175, the Black Forge, recipes and beast drops.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_blackrock_beasts.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

NEW = ["blackwhelp", "broodling", "blackwyrmkin", "ragetalon", "mongrel", "rrbrute", "rralpha", "rrmystic", "condor",
       "chatter", "spitter", "rager", "torcher", "firegut", "fgbrute", "fgmage", "scaldingdrake", "firetail",
       "burningimp", "volchan", "glassweb", "lavaspider", "greaterlava", "blazing", "inferno", "magma", "obsidian",
       "temperedgolem", "heavygolem", "faultygolem", "firewalker", "fireguard", "flameimp", "lavasurger", "corehound",
       "magmadar"]
MOVES = ["lavaburst", "firenova", "conflagrate", "moltenarmor", "bellowingroar", "shadowflame", "warstomp", "slagtoss",
         "magmashackles", "steamjet", "burningweb", "panic"]
TRAINERS = ["rrpoacher", "yowler", "bwgrunt", "bwshadow", "gath", "nef1", "nef2", "dimaster", "senator", "warden",
            "thaurissan"]

# A battle rng for the mechanics cases: never a crit (rng(1, 16) = 16), every hit lands and every chance succeeds
# (the low end), damage rolls 85%.
SURE_RNG = "function(a, b) if b == 16 then return 16 end return a end"


def game(seed=11):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    c.eval("ns.Azero:NewGame() ns.Azero.clockHour = 12 ns.AzeroCraft.clock = 1790000000")
    c.eval("""local M = ns.AzeroMon
      local a = M.New('emberancient', 100, ns.Azero.rng) a.moves = M.DefaultMoves('emberancient', 100)
      local b = M.New('tidelord', 100, ns.Azero.rng) b.moves = M.DefaultMoves('tidelord', 100)
      ns.Azero.save.party = { a, b }
      ns.Azero.save.money = 100000""")
    return w, c


def log(c):
    return "\n".join(c.eval_py("return T_AZ.log") or [])


@case
def the_new_species_are_sound():
    w, c = game()
    r = c.eval_py("""local D = ns.AzeroData
      local bad, nums = {}, {}
      for id, s in pairs(D.species) do
        if nums[s.num] then bad[#bad + 1] = 'num twice ' .. s.num end
        nums[s.num] = id
        if not D.types[s.type] then bad[#bad + 1] = 'type ' .. id end
        if type(s.base) ~= 'table' or #s.base ~= 6 then bad[#bad + 1] = 'base ' .. id end
        local last = 0
        for _, e in ipairs(s.learn) do
          if not D.moves[e[2]] then bad[#bad + 1] = 'move ' .. id .. ' ' .. tostring(e[2]) end
          if e[1] < last then bad[#bad + 1] = 'order ' .. id end
          last = e[1]
        end
        if s.evolve and not D.species[s.evolve.into] then bad[#bad + 1] = 'evolve ' .. id end
        if s.evolveItem and not (D.species[s.evolveItem.into] and D.items[s.evolveItem.item]) then bad[#bad + 1] = 'item evo ' .. id end
        if not (s.catch >= 3 and s.catch <= 255) then bad[#bad + 1] = 'catch ' .. id end
      end
      local n = 0
      for _ in pairs(D.species) do n = n + 1 end
      local order = {}
      for num = 131, 166 do order[#order + 1] = nums[num] or false end
      local rares, legend, tops = {}, {}, {}
      for num = 131, 166 do
        local s = D.species[nums[num]]
        if s.rare then rares[#rares + 1] = s.id end
        if s.legendary then legend[#legend + 1] = s.id end
        if not s.evolve and not s.rare and not s.legendary then
          tops[#tops + 1] = { s.id, s.learn[#s.learn][1] }
        end
      end
      return { bad = bad, n = n, maxnum = #D.dexOrder, order = order, rares = rares, legend = legend, tops = tops,
               moves = (function() local t = {} for id in pairs(D.moves) do t[id] = true end return t end)() }""")
    assert r["bad"] == [], r["bad"]
    assert r["order"] == NEW and r["n"] == 166 and r["maxnum"] == 166, r["order"]
    assert sorted(r["rares"]) == ["chatter", "faultygolem", "lavasurger", "volchan"], r["rares"]
    assert r["legend"] == ["magmadar"], r["legend"]
    for m in MOVES:
        assert m in r["moves"], m
    # final forms keep learning into the 70s and 80s
    low = [t for t in r["tops"] if t[1] < 70]
    assert low == [], low
    no_errors(w)


@case
def old_lines_grow_new_forms_and_earlier_forms_are_found():
    w, c = game()
    r = c.eval_py("""local D, M = ns.AzeroData, ns.AzeroMon
      local function ids(t) local o = {} for k in pairs(t) do o[#o + 1] = k end table.sort(o) return o end
      local legal = M.LegalMoves('heavygolem', 60)
      return { venom = D.species.venomweb.evolve, mastiff = D.species.mastiff.evolve,
               watcher = D.species.watcher.evolve, item = D.species.watcher.evolveItem,
               prevHeavy = M.PrevForms('heavygolem'), prevHound = M.PrevForms('corehound'),
               lineage = M.Lineage('greaterlava'),
               knowsWatcher = legal.overdrive == true, knowsTempered = legal.gears == true and legal.steamjet == true,
               notLater = legal.sawstorm == nil }""")
    assert r["venom"] == {"level": 46, "into": "glassweb"}, r
    assert r["mastiff"] == {"level": 58, "into": "corehound"}, r
    assert r["watcher"] == {"level": 60, "into": "pummeler"} and r["item"] == {"item": "darkironbar", "into": "heavygolem"}, r
    assert r["prevHeavy"] == ["temperedgolem", "watcher"] and r["prevHound"] == ["mastiff"], r
    assert r["lineage"] == ["greaterlava", "lavaspider", "glassweb", "venomweb", "pygmyweb"], r
    assert r["knowsWatcher"] and r["knowsTempered"] and r["notLater"], r
    # the pet trainer remembers both lines' moves for a Heavy War Golem
    r = c.eval_py("""local G, M = ns.Azero, ns.AzeroMon
      local m = M.New('heavygolem', 60, G.rng)
      m.moves = { { id = 'tackle', pp = 35 } }
      G.save.party[1] = m
      local t = {} for _, id in ipairs(G:RelearnableMoves(m)) do t[id] = true end
      return { scythe = t.scythe == true, steamjet = t.steamjet == true, rocket = t.rocketpunch == true }""")
    assert r == {"scythe": True, "steamjet": True, "rocket": True}, r
    # level evolutions after a battle
    r = c.eval_py("""local G, M = ns.Azero, ns.AzeroMon
      local a = M.New('venomweb', 46, G.rng) local b = M.New('mastiff', 58, G.rng)
      G.save.party = { a, b }
      G:Run(function(g) g:Evolutions() end)
      T_AZ.settle()
      return { a.sp, b.sp }""")
    assert r == ["glassweb", "corehound"], r
    no_errors(w)


@case
def a_dark_iron_bar_turns_a_harvest_watcher_into_a_heavy_war_golem():
    w, c = game()
    r = c.eval_py("""local G, M = ns.Azero, ns.AzeroMon
      local wt = M.New('watcher', 50, G.rng)
      local other = M.New('reaper', 30, G.rng)
      G.save.party = { wt, other }
      G.save.bag.darkironbar = 2
      G:Run(function(g) g:UseEvolveItem(2, 'darkironbar') end) T_AZ.settle()
      local wrong = { other.sp, G.save.bag.darkironbar }
      G:Run(function(g) g:UseEvolveItem(1, 'darkironbar') end) T_AZ.settle()
      return { wrong = wrong, sp = wt.sp, bar = G.save.bag.darkironbar, stop = wt.evoStop or false,
               caught = G.save.caught.heavygolem == true }""")
    assert r == {"wrong": ["reaper", 2], "sp": "heavygolem", "bar": 1, "stop": False, "caught": True}, r
    assert "It won't have any effect." in log(c) and "evolved into Heavy War Golem" in log(c), log(c)
    # stopped with X: the bar stays and the level evolution is not held back
    r = c.eval_py("""local G, M = ns.Azero, ns.AzeroMon
      local wt = M.New('watcher', 60, G.rng)
      G.save.party = { wt }
      G.save.bag.darkironbar = 1
      G:Run(function(g) g:UseEvolveItem(1, 'darkironbar') end)
      for _ = 1, 50 do
        local p = G.pending
        if p and p.kind == 'evolve' then G:Advance('cancel') break end
        if p and p.kind == 'text' then G:Advance() else G:Update(0.05) end
      end
      T_AZ.settle()
      local after = { wt.sp, G.save.bag.darkironbar, wt.evoStop or false }
      G:Run(function(g) g:Evolutions() end) T_AZ.settle()
      return { after = after, level = wt.sp }""")
    assert r == {"after": ["watcher", 1, False], "level": "pummeler"}, r
    no_errors(w)


@case
def magmadar_is_met_once_and_comes_back_until_tamed():
    w, c = game()
    c.eval("""local G, M = ns.Azero, ns.AzeroMon
      local d = M.New('scaldingdrake', 100, G.rng) d.moves = M.DefaultMoves('scaldingdrake', 100)
      G.save.party = { d }""")
    # run: it stays
    r = c.eval_py("""local G = ns.Azero
      local res
      G:Run(function(g) res = g:LegendaryBattle('magmadar', 62) end)
      T_AZ.settle(function() return { kind = 'run' } end)
      return { res = res, flag = G:Flag('caught_magmadar') or false }""")
    assert r == {"res": "run", "flag": False}, r
    assert "The legendary Magmadar blocks the way!" in log(c), log(c)
    # tamed: flag, achievement, and gone for good
    r = c.eval_py("""local G, D = ns.Azero, ns.AzeroData
      G.save.bag.truesilverrod = 50
      local rate = D.species.magmadar.catch
      D.species.magmadar.catch = 255
      local res, again
      G:Run(function(g) res = g:LegendaryBattle('magmadar', 62) end)
      T_AZ.settle(function() return { kind = 'item', item = 'truesilverrod' } end)
      D.species.magmadar.catch = rate
      G:Run(function(g) again = g:LegendaryBattle('magmadar', 62) end)
      T_AZ.settle()
      local had = false
      for _, m in ipairs(G.save.party) do if m.sp == 'magmadar' then had = m.lvl end end
      return { res = res, again = again, flag = G:Flag('caught_magmadar') == true, had = had,
               ach = ns.AzeroAch.Earned().magmadar ~= nil }""")
    assert r == {"res": "caught", "again": "gone", "flag": True, "had": 62, "ach": True}, r
    # never in the Bestiary goal or the arena
    r = c.eval_py("""local ids = ns.AzeroGuild.CompletableIds()
      for _, id in ipairs(ids) do if id == 'magmadar' then return false end end
      return true""")
    assert r is True
    no_errors(w)


@case
def the_new_trainers_badges_and_rares():
    w, c = game()
    r = c.eval_py("""local D = ns.AzeroData
      local bad = {}
      for _, id in ipairs({ %s }) do
        local t = D.trainers[id]
        if not t then bad[#bad + 1] = 'missing ' .. id
        else
          if not (t.name and t.intro and t.lose and t.class and t.prize) then bad[#bad + 1] = 'fields ' .. id end
          for _, e in ipairs(t.team) do
            if not D.species[e[1]] then bad[#bad + 1] = id .. ' ' .. tostring(e[1]) end
            if e[2] < 48 or e[2] > 60 then bad[#bad + 1] = id .. ' level ' .. e[2] end
          end
        end
      end
      local rr = {}
      for _, r in ipairs(D.raidRares) do rr[#rr + 1] = r.boss .. ':' .. r.sp .. ':' .. r.map .. ':' .. r.level end
      return { bad = bad, gath = D.trainers.gath.badge, thaur = D.trainers.thaurissan.badge,
               b6 = D.badges.stonewatch, b7 = D.badges.darkiron, rr = rr,
               titles = { ns.Azero.NpcTitle({ trainer = 'senator' }), ns.Azero.NpcTitle({ trainer = 'rrpoacher' }) } }"""
                  % ", ".join("'%s'" % t for t in TRAINERS))
    assert r["bad"] == [], r["bad"]
    assert r["gath"] == "stonewatch" and r["thaur"] == "darkiron", r
    assert r["b6"]["name"] == "Stonewatch Seal" and r["b6"]["order"] == 6, r
    assert r["b7"]["name"] == "Dark Iron Signet" and r["b7"]["order"] == 7, r
    assert "Magtheridon:corehound:steppes:55" in r["rr"] and "Alar:lavasurger:gorge:56" in r["rr"], r["rr"]
    assert "Magtheridon:pitling:forestedge:16" in r["rr"], r["rr"]
    assert r["titles"] == ["Shadowforge City", "Redridge Gnoll"], r["titles"]
    # Gath waits for his guards, then gives the seal
    r = c.eval_py("""local G = ns.Azero
      local before = G:TrainerLocked('gath')
      G:SetFlag('beat_bwgrunt') G:SetFlag('beat_bwshadow')
      local npc = { def = { trainer = 'gath' }, face = 'down', x = 1, y = 1 }
      G:Run(function(g) g:TrainerEncounter(npc, false) end)
      T_AZ.settle()
      return { before = before, after = G:TrainerLocked('gath') or false, badge = G:Flag('badge_stonewatch') == true,
               hidden = npc.hidden == true, count = G:BadgeCount() }""")
    assert r["before"].startswith("Gath'Ilzogg: You crawl past my guards?"), r
    assert r["after"] is False and r["badge"] and r["hidden"] and r["count"] == 1, r
    assert "Alice received Stonewatch Seal!" in log(c), log(c)[-800:]
    # Nefarius twice: the cache comes with the second win, once
    r = c.eval_py("""local G = ns.Azero
      G.save.bag.blackdragonscale = nil
      for _, id in ipairs({ 'nef1', 'nef2' }) do
        local npc = { def = { trainer = id }, face = 'down', x = 1, y = 1 }
        G:Run(function(g) g:TrainerEncounter(npc, false) end)
        T_AZ.settle()
      end
      local got = G.save.bag.blackdragonscale
      G:TrainerCache(ns.AzeroData.trainers.nef2)
      return { got, G.save.bag.blackdragonscale }""")
    assert r == [5, 5], r
    no_errors(w)


@case
def shops_have_their_own_shelves():
    w, c = game()
    r = c.eval_py("""local D, G = ns.AzeroData, ns.Azero
      local bad = {}
      for id, list in pairs(D.shopStocks) do
        for _, item in ipairs(list) do
          if not D.items[item] or (D.items[item].price or 0) <= 0 then bad[#bad + 1] = id .. ' ' .. item end
        end
      end
      local seen
      G:Run(function(g) g:Shop('Lamar Veisilli', 'lakeshire') end)
      seen = G.pending and { G.pending.kind, G.pending.keeper, G.pending.stock }
      G:Advance()
      return { bad = bad, plain = D.ShopStock(nil) == D.shopStock, lake = D.ShopStock('lakeshire'),
               thor = D.ShopStock('thorium'), seen = seen, rod = D.items.truesilverrod.ball,
               heal = D.items.greatpotion.heal }""")
    assert r["bad"] == [] and r["plain"], r
    assert "greatpotion" in r["lake"] and "truesilverrod" not in r["lake"], r
    assert "truesilverrod" in r["thor"] and "fireprotection" in r["thor"], r
    assert r["seen"] == ["shop", "Lamar Veisilli", "lakeshire"] and r["rod"] == 2 and r["heal"] == 100, r
    no_errors(w)


@case
def skill_tiers_climb_to_175():
    w, c = game()
    c.eval("ns.Azero.save.prof = { mining = 100, alchemy = 80 } ns.Azero.save.money = 5000")
    r = c.eval_py("""local C, D = ns.AzeroCraft, ns.AzeroData
      C.rng = function(a, b) return a end
      return { max = D.SKILL_MAX, cap = C.Cap('mining'), up = C:SkillUp('mining', 100) or false }""")
    assert r == {"max": 175, "cap": 100, "up": False}, r
    c.eval("T_AZ.log = {} T_AZ.choice = 1")
    c.eval("ns.Azero:Run(function(g) g:ProfessionTrainer('journeyman') end)")
    opts = c.eval_py("return ns.Azero.pending and ns.Azero.pending.kind == 'text' and (ns.Azero:Advance() or true) and ns.Azero.pending.options")
    assert opts == ["Journeyman Alchemy (5s)", "Journeyman Mining (5s)"], opts
    c.eval("ns.Azero:Advance(2)")
    c.eval("T_AZ.settle()")
    r = c.eval_py("""local C = ns.AzeroCraft
      return { cap = C.Cap('mining'), alch = C.Cap('alchemy'), money = ns.Azero.save.money,
               up = C:SkillUp('mining', 100) or false }""")
    assert r == {"cap": 150, "alch": 100, "money": 4500, "up": 101}, r
    assert "You are now a Journeyman in Mining! Your skill can rise to 150." in log(c), log(c)
    # Expert needs 125
    c.eval("T_AZ.log = {}")
    c.eval("ns.Azero:Run(function(g) g:ProfessionTrainer('expert') end) T_AZ.settle()")
    assert "Expert needs" in log(c) and "Mining 125" in log(c), log(c)
    c.eval("ns.Azero.save.prof.mining = 140 T_AZ.log = {} T_AZ.choice = 1")
    c.eval("ns.Azero:Run(function(g) g:ProfessionTrainer('expert') end) T_AZ.settle()")
    r = c.eval_py("return { ns.AzeroCraft.Cap('mining'), ns.Azero.save.money }")
    assert r == [175, 3000], (r, log(c))
    # forgetting the trade forgets its tier
    c.eval("ns.AzeroCraft:Unlearn('mining') ns.Azero.save.prof.mining = 1")
    assert c.eval("return ns.AzeroCraft.Cap('mining')") == 100
    # a trainer with nothing to offer and room for a trade teaches one from scratch
    c.eval("ns.Azero.save.prof = {} ns.Azero.save.profTier = nil T_AZ.log = {} T_AZ.choice = 1")
    c.eval("ns.Azero:Run(function(g) g:ProfessionTrainer('journeyman') end) T_AZ.settle()")
    assert c.eval("return ns.AzeroCraft.Skill('herbalism')") == 1, log(c)
    no_errors(w)


@case
def dark_iron_needs_the_black_forge():
    w, c = game()
    r = c.eval_py("""local G, C, D = ns.Azero, ns.AzeroCraft, ns.AzeroData
      G.save.prof = { mining = 175, blacksmithing = 175 }
      G.save.bag.darkironore = 16 G.save.bag.ironore = 2
      local function recipe(id) for _, r in ipairs(D.recipes) do if r.id == id then return r end end end
      local function at(station)
        G.map = { id = 't', def = { objects = { { x = 5, y = 5, station = station } } } }
        G.save.x, G.save.y = 5, 6
      end
      at('forge')
      local plain = { C:Check(recipe('smeltdarkiron')) }
      local okIron = C:Check(recipe('smeltiron'))
      at('blackforge')
      local black = { C:Craft(recipe('smeltdarkiron')) }
      local ironHere = C:Check(recipe('smeltiron'))
      local _, msg = C:Craft(recipe('fierychaingirdle'))
      at('anvil')
      local _, anvilMsg = C:Craft(recipe('fierychaingirdle'))
      local stations = {}
      for _, r in ipairs(D.recipes) do
        if not D.items[r.makes] then stations[#stations + 1] = 'makes ' .. r.id end
        for m in pairs(r.mats) do if not D.items[m] then stations[#stations + 1] = 'mat ' .. r.id .. ' ' .. m end end
        if r.station and not D.recipeStations[r.station] then stations[#stations + 1] = 'station ' .. r.id end
      end
      for id, res in pairs(D.resources) do
        if not D.items[res.item or id] then stations[#stations + 1] = 'res ' .. id end
      end
      return { plain = plain, okIron = okIron, black = black[1], bar = G.save.bag.darkironbar,
               ironHere = ironHere, msg = msg, anvilMsg = anvilMsg, bad = stations }""")
    assert r["plain"] == [False, "station"] and r["okIron"] is True, r
    assert r["black"] is True and r["bar"] == 1 and r["ironHere"] is True, r
    assert r["msg"] == "You don't have the materials.", r
    assert r["anvilMsg"] == "You need to be at the Black Forge in Blackrock Mountain.", r
    assert r["bad"] == [], r["bad"]
    no_errors(w)


@case
def wild_beasts_drop_materials_and_trainers_do_not():
    w, c = game()
    r = c.eval_py("""local G, C, M = ns.Azero, ns.AzeroCraft, ns.AzeroMon
      local real = G.rng
      G.rng = function(a, b) if a == 1 and b == 100 then return 1 end return real(a, b) end
      local got = {}
      G:Run(function(g) got = C:BeastDrops(g, { M.New('inferno', 60, real) }) end)
      T_AZ.settle()
      local none = {}
      G:Run(function(g) none = C:BeastDrops(g, { M.New('wolfpup', 3, real) }) end)
      T_AZ.settle()
      -- a trainer battle never calls it; a won wild battle does
      local calls = 0
      local orig = C.BeastDrops
      C.BeastDrops = function(self, g, foes) calls = calls + 1 return {} end
      G.rng = real
      G:Run(function(g) local f = M.New('wolfpup', 2, g.rng) g:RunBattle({ f }, nil) end) T_AZ.settle()
      local wild = calls
      G:Run(function(g) g:RunBattle({ M.New('wolfpup', 2, g.rng) }, 'rrpoacher') end) T_AZ.settle()
      C.BeastDrops = orig
      return { got = got, none = #none, wild = wild, trainer = calls - wild,
               fire = G.save.bag.elementalfire, heart = G.save.bag.heartoffire }""")
    assert r["got"] == ["elementalfire", "heartoffire"] and r["none"] == 0, r
    assert r["fire"] == 1 and r["heart"] == 1 and r["wild"] == 1 and r["trainer"] == 0, r
    assert "The Inferno Elemental dropped Heart of Fire!" in log(c), log(c)
    no_errors(w)


def battle(c, ally, foe, extra=""):
    """A battle between two Lv 60 beasts (moves set by the caller) on SURE_RNG; returns nothing (B in T_B)."""
    c.eval("""local M, B = ns.AzeroMon, ns.AzeroBattle
      local a = M.New('%s', 60, function() return 15 end)
      local f = M.New('%s', 60, function() return 15 end)
      local p2 = M.New('rager', 60, function() return 15 end)
      %s
      T_B = B.New({ party = { a, p2 }, foes = { f }, wild = true, rng = %s })
      while T_B:Pop() do end""" % (ally, foe, extra, SURE_RNG))


def texts(c):
    return c.eval_py("local t = {} local e = T_B:Pop() while e do if e.t == 'text' then t[#t + 1] = e.text end e = T_B:Pop() end return t") or []


@case
def burns_conflagrate_and_steam_jet():
    w, c = game()
    # FIRE types shrug off a burn; Shadow Flame burns them anyway
    battle(c, "rrmystic", "blazing")
    r = c.eval_py("""local D = ns.AzeroData
      T_B:UseMove('ally', D.moves.ember) local plain = T_B.foe.mon.status or false
      T_B:UseMove('ally', D.moves.shadowflame) return { plain, T_B.foe.mon.status or false }""")
    assert r == [False, "brn"], r
    # Conflagrate hits a burned foe harder and ends the burn; Lava Burst hits a burned foe harder
    battle(c, "inferno", "magma")
    r = c.eval_py("""local D = ns.AzeroData
      local function dmg(mv) local d = T_B:Damage('ally', 'foe', D.moves[mv], false) return d end
      local c1, l1 = dmg('conflagrate'), dmg('lavaburst')
      T_B.foe.mon.status = 'brn'
      local c2, l2 = dmg('conflagrate'), dmg('lavaburst')
      T_B:UseMove('ally', D.moves.conflagrate)
      return { c2 > c1 * 2, l2 > l1 * 1.4, T_B.foe.mon.status or false }""")
    assert r == [True, True, False], r
    # Steam Jet: neutral on WATER; Grinding Gears: resisted
    battle(c, "temperedgolem", "tidelord")
    r = c.eval_py("""local D = ns.AzeroData
      local _, e1 = T_B:Damage('ally', 'foe', D.moves.steamjet, false)
      local _, e2 = T_B:Damage('ally', 'foe', D.moves.gears, false)
      return { e1, e2 }""")
    assert r == [1, 0.5], r
    no_errors(w)


@case
def shackles_panic_stomp_and_molten_armor():
    w, c = game()
    # Magma Shackles: no switching, no running, until the shackler leaves
    battle(c, "scaldingdrake", "obsidian")
    r = c.eval_py("""local D = ns.AzeroData
      T_B:UseMove('foe', D.moves.magmashackles)
      local trapped = T_B:Trapped('ally')
      local spe = T_B.ally.stages.spe
      T_B:Act({ kind = 'switch', idx = 2 })
      local still = T_B.allyIdx
      T_B:Act({ kind = 'run' })
      return { trapped = trapped, spe = spe, idx = still, need = T_B.need,
               pvp = T_B:ValidPvP('ally', { kind = 'switch', idx = 2 }).kind }""")
    assert r == {"trapped": True, "spe": -1, "idx": 1, "need": "action", "pvp": "move"}, r
    t = texts(c)
    assert any("is trapped and can't be recalled!" in x for x in t) and any("can't get away!" in x for x in t), t
    # Panic: the next move is lost, once per beast; Free Action blocks it
    battle(c, "scaldingdrake", "magmadar")
    r = c.eval_py("""local D = ns.AzeroData
      T_B:UseMove('foe', D.moves.panic)
      local hp = T_B.foe.mon.hp
      T_B:UseMove('ally', D.moves.ember)
      local skipped = T_B.foe.mon.hp == hp
      T_B:UseMove('foe', D.moves.panic)
      local again = T_B.ally.panic or false
      return { skipped = skipped, again = again }""")
    assert r == {"skipped": True, "again": False}, r
    t = texts(c)
    assert any("is panicking and can't move!" in x for x in t) and "But it failed!" in t, t
    battle(c, "scaldingdrake", "magmadar", "a.status = 'par'")
    r = c.eval_py("""local D = ns.AzeroData
      T_B.bag.freeaction = 1
      local ok = T_B:UseItem('freeaction', 1)
      T_B:UseMove('foe', D.moves.panic)
      return { ok = ok, status = T_B.ally.mon.status or false, panic = T_B.ally.panic or false }""")
    assert r == {"ok": True, "status": False, "panic": False}, r
    # War Stomp: a foe that hasn't moved flinches; Molten Armor burns a physical attacker
    battle(c, "fgbrute", "rralpha")
    r = c.eval_py("""local D = ns.AzeroData
      T_B:UseMove('ally', D.moves.warstomp)
      local hp = T_B.ally.mon.hp
      T_B:UseMove('foe', D.moves.maul)
      local flinched = T_B.ally.mon.hp == hp
      T_B:EndTurn()
      T_B:UseMove('foe', D.moves.maul)
      return { flinched = flinched, hit = T_B.ally.mon.hp < hp }""")
    assert r == {"flinched": True, "hit": True}, r
    battle(c, "firewalker", "rralpha")
    r = c.eval_py("""local D = ns.AzeroData
      T_B:UseMove('ally', D.moves.moltenarmor)
      T_B:UseMove('foe', D.moves.maul)
      return { T_B.foe.mon.status or false, T_B.ally.armor }""")
    assert r == ["brn", 4], r
    no_errors(w)


@case
def blackrock_gear_resists_heals_and_stuns():
    w, c = game()
    battle(c, "magma", "inferno")
    r = c.eval_py("""local D, M = ns.AzeroData, ns.AzeroMon
      local plain = T_B:Damage('foe', 'ally', D.moves.fireball, false)
      T_B.ally.mon.gear = { waist = 'fierychaingirdle' }
      local girdled = T_B:Damage('foe', 'ally', D.moves.fireball, false)
      T_B.ally.mon.gear = { waist = 'fierychaingirdle', chest = 'truesilverbreastplate' }
      T_B.ally.mon.hp = 10
      T_B:EndTurn()
      local healed = T_B.ally.mon.hp
      T_B.ally.mon.gear = { claws = 'darkironpulverizer' }
      T_B:UseMove('ally', D.moves.rockthrow)
      return { ratio = girdled / plain, healed = healed - 10 == math.floor(M.MaxHP(T_B.ally.mon) / 16),
               stun = T_B.flinch and T_B.flinch.foe == true }""")
    assert 0.6 < r["ratio"] < 0.8 and r["healed"] and r["stun"], r
    # flasks with a type; the PvP fingerprint sees the new gear fields
    r = c.eval_py("""local M, D = ns.AzeroMon, ns.AzeroData
      local m = M.New('tidelord', 50, function() return 1 end)
      m.flask = { id = 'flaskflowing', n = 10 }
      return { M.TypeMult(m, 'typePower', 'WATER'), M.TypeMult(m, 'typePower', 'FIRE'),
               D.items.fireprotection.resist.FIRE, ns.AzeroPvP and ns.AzeroPvP.Fingerprint() ~= nil }""")
    assert r[:3] == [1.1, 1, 0.7] and r[3] is True, r
    no_errors(w)


if __name__ == "__main__":
    run_all()

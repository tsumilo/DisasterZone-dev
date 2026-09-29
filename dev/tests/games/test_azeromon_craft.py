"""Azeromon: professions.

Covers: learning trades from Alchemist Mallory and Smith Argus (fee, only what you don't know); herb and ore nodes on
the maps (blocking, needing the profession and the skill, yields and extras, growing back after RESPAWN, sometimes as
another herb); the real game's difficulty colours and skill-up chances; smelting at a forge, smithing at an anvil,
brewing anywhere; gear (stat bonuses, swapping, taking off, carried into player battles and trades, bad gear dropped);
flasks (a bonus that counts down over battles, HP clamped when it ends); elixirs and rejuvenation in battle; the
PROFESSIONS page and a forge through the UI.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_craft.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

CLOCK = 1790000000


def game(seed=7, ui=False):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    c.eval("ns.Azero:NewGame()")
    c.eval("ns.AzeroCraft.clock = %d" % CLOCK)
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('murkling', 12, ns.Azero.rng), 'caught')")
    if ui:
        c.slash("/cdl play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.3)
        c.eval("T_AZ.settle()")
    return w, c


def texts_until_choice(c):
    """Reads text prompts (logging them) until a choice or nothing is pending; returns the log."""
    out = []
    for _ in range(20):
        p = c.eval_py("local p = ns.Azero.pending return p and { kind = p.kind, text = p.text }")
        if not p or p["kind"] != "text":
            break
        out.append(p["text"])
        c.eval("ns.Azero:Advance()")
    return out


def key(w, c, *keys):
    for k in keys:
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.05)


def title(c):
    lv = c.eval_py("return ns.AzeroUI._Levels()") or []
    return lv[-1]["title"] if lv else None


@case
def learning_trades_from_the_goldshire_trainers():
    w, c = game()
    c.eval("ns.Azero.save.money = 200 ns.Azero:EnterMap('town', 8, 4, 'up', true) ns.Azero:PressA()")
    said = texts_until_choice(c)
    assert said and said[0].startswith("Alchemist Mallory:"), said
    opts = c.eval_py("return ns.Azero.pending.options")
    assert opts == ["Learn Herbalism", "Learn Alchemy"], opts
    c.eval("ns.Azero:Advance(1)")
    said = texts_until_choice(c)
    assert "You have learned Herbalism!" in said, said
    assert c.eval("return ns.AzeroCraft.Skill('herbalism')") == 1 and c.eval("return ns.Azero.save.money") == 150
    c.eval("ns.Azero:PressA()")
    texts_until_choice(c)
    assert c.eval_py("return ns.Azero.pending.options") == ["Learn Alchemy"]
    c.eval("ns.Azero:Advance(2)")                                  # B: cancel
    texts_until_choice(c)
    # Smith Argus, across the road
    c.eval("ns.Azero:EnterMap('town', 18, 18, 'up', true) ns.Azero:PressA()")
    said = texts_until_choice(c)
    assert said[0].startswith("Smith Argus:") and c.eval_py("return ns.Azero.pending.options") == ["Learn Mining", "Learn Blacksmithing"]
    c.eval("ns.Azero:Advance(1)")
    texts_until_choice(c)
    assert c.eval("return ns.AzeroCraft.Skill('mining')") == 1
    # two trades: a third means forgetting one
    assert c.eval_py("return { ns.AzeroCraft:Learn('alchemy') }") == [False, "You can only know two professions. Forget one first."]
    c.eval("ns.Azero:EnterMap('town', 8, 4, 'up', true) ns.Azero:PressA()")
    said = texts_until_choice(c)
    assert "You already know Herbalism and Mining. A tamer can only keep two trades." in said[-1], said
    assert c.eval_py("return ns.Azero.pending.options") == ["Forget Herbalism", "Forget Mining"]
    c.eval("ns.Azero:Advance(2)")                                     # Forget Mining
    assert "Your skill of 1 will be lost." in c.eval("return ns.Azero.pending.text")
    c.eval("ns.Azero:Advance(1)")                                     # Yes
    said = texts_until_choice(c)
    assert "You have unlearned Mining." in said, said
    assert c.eval_py("return ns.Azero.pending.options") == ["Learn Alchemy"]
    c.eval("ns.Azero:Advance(1)")
    texts_until_choice(c)
    assert c.eval("return ns.AzeroCraft.Skill('alchemy')") == 1 and c.eval("return ns.AzeroCraft.Skill('mining')") is None
    no_errors(w)


@case
def a_hint_shows_what_space_would_do_and_choices_fit():
    w, c = game(ui=True)
    c.eval("ns.Azero:EnterMap('route1', 1, 10, 'up', true)")        # facing a herb
    w.tick(0.2)
    hint = c.eval("return ns.AzeroUI._Hint()")
    assert hint and hint.startswith("Pick ") and hint.endswith("(needs Herbalism)"), hint
    c.eval("ns.Azero.save.prof = { herbalism = 1 }")
    c.eval("ns.Azero:EnterMap('route1', 16, 12, 'up', true)")       # facing the copper vein
    w.tick(0.2)
    assert c.eval("return ns.AzeroUI._Hint()") == "Mine Copper Vein  (needs Mining)"
    c.eval("ns.Azero:EnterMap('route1', 1, 9, 'down', true)")       # standing on the herb, facing away
    w.tick(0.2)
    hint = c.eval("return ns.AzeroUI._Hint()")
    assert hint and hint.startswith("Pick ") and "needs" not in hint, hint
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.2)
    assert c.eval("return ns.Azero.pending and ns.Azero.pending.text or ''").startswith("You picked ")
    for _ in range(5):
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.2)
    c.eval("ns.Azero:EnterMap('town', 19, 18, 'up', true)")         # the forge
    w.tick(0.2)
    assert c.eval("return ns.AzeroUI._Hint()") == "Smelt at the forge"
    # a choice box is as wide as its longest option
    c.eval("ns.Azero:EnterMap('town', 18, 18, 'up', true)")
    w.tick(0.2)
    c.eval("ns.AzeroUI._HandleKey('A')")
    for _ in range(10):
        w.tick(0.2)
        if c.eval("return ns.Azero.pending and ns.Azero.pending.kind") == "choice":
            break
        c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.2)
    L = c.eval_py("return ns.AzeroUI._MenuLayout()")
    need = c.eval("return #'Learn Blacksmithing'")
    assert L["n"] == 2 and L["w"] > 130 and L["x"] + L["w"] <= L["SW"], L
    no_errors(w)


@case
def a_herb_needs_herbalism_then_grows_back():
    w, c = game()
    c.eval("ns.Azero:EnterMap('route1', 1, 10, 'up', true)")
    r = c.eval_py("""local G, C = ns.Azero, ns.AzeroCraft
      local m = G.map
      local node = m.node[m.key(1, 9)]
      local up, res = C:NodeState(m.id, node)
      return { up = up, res = res, blocked = G:Blocked(1, 9) }""")
    assert r["up"] is True and r["res"] in ("peacebloom", "silverleaf", "earthroot") and r["blocked"] is False, r
    assert c.eval("return ns.Azero:Blocked(16, 11)") is True                      # an ore vein blocks
    # ... when walking, too (walking has its own check), and a herb doesn't
    walk = c.eval_py("""local G = ns.Azero
      G:EnterMap('route1', 16, 12, 'up', true)
      local vein = G:TryStep('up')
      G:EnterMap('route1', 1, 10, 'up', true)
      local herb = G:TryStep('up')
      for i = 1, 20 do if G.moving then G:Update(0.05) end end
      return { vein = vein, herb = herb, y = G.save.y }""")
    assert walk == {"vein": "blocked", "herb": "moved", "y": 9}, walk
    c.eval("ns.Azero:EnterMap('route1', 1, 10, 'up', true)")
    c.eval("ns.Azero:PressA()")
    said = texts_until_choice(c)
    assert "It takes Herbalism to gather it: Alchemist Mallory in Goldshire teaches it." in said[0], said
    # learned, but maybe not skilled enough (Earthroot needs 15): give 20 skill
    c.eval("ns.Azero.save.prof = { herbalism = 20 } ns.AzeroCraft.rng = function(a, b) return a end")
    first = r["res"]
    c.eval("ns.Azero:PressA()")
    said = texts_until_choice(c)
    item = first
    assert said[0].startswith("You picked ") and " x1." in said[0], said
    r = c.eval_py("""local G, C = ns.Azero, ns.AzeroCraft
      local m = G.map
      local node = m.node[m.key(1, 9)]
      local up, res = C:NodeState(m.id, node)
      return { up = up, blocked = G:Blocked(1, 9), n = G.save.bag[%r], skill = C.Skill('herbalism') }""" % item)
    assert r["up"] is False and r["blocked"] is False and r["n"] == 1, r
    assert r["skill"] == 21, r                                    # a skill-up (the roll is forced low)
    c.eval("ns.AzeroCraft.clock = %d" % (CLOCK + 600))
    r = c.eval_py("""local m = ns.Azero.map
      local up, res = ns.AzeroCraft:NodeState(m.id, m.node[m.key(1, 9)])
      return { up = up, res = res }""")
    assert r["up"] is True and r["res"] != first, (r, first)      # grown back, as the next herb of the map
    no_errors(w)


@case
def difficulty_colours_and_skill_up_chances():
    w, c = game()
    r = c.eval_py("""local C = ns.AzeroCraft
      local d = {}
      for _, s in ipairs({ 1, 10, 19, 20, 34, 35, 60 }) do d[#d + 1] = C.Difficulty(1, s) end
      ns.Azero.save.prof = { alchemy = 30 }
      local results = {}
      C.rng = function(a, b) return 76 end                      -- just above yellow's 75%
      results[1] = C:SkillUp('alchemy', 15) or false             -- 15 past it: yellow, no
      results[2] = C:SkillUp('alchemy', 30) or false             -- orange: always
      C.rng = function(a, b) return 25 end
      results[3] = C:SkillUp('alchemy', 5) or false              -- 26 past it: green, 25%: yes at 25
      ns.Azero.save.prof.alchemy = 60
      results[4] = C:SkillUp('alchemy', 1) or false              -- grey: never
      ns.Azero.save.prof.alchemy = 100
      results[5] = C:SkillUp('alchemy', 100) or false            -- at the cap
      return { d = d, r = results }""")
    assert r["d"] == ["orange", "orange", "yellow", "yellow", "green", "green", "grey"], r
    assert r["r"] == [False, 31, 32, False, False], r
    no_errors(w)


@case
def smelting_at_a_forge_smithing_at_an_anvil_brewing_anywhere():
    w, c = game()
    r = c.eval_py("""local G, C = ns.Azero, ns.AzeroCraft
      C.rng = function(a, b) return a end
      G.save.prof = { mining = 1, blacksmithing = 1, alchemy = 1 }
      G.save.bag = { copperore = 4, roughstone = 2, peacebloom = 1, silverleaf = 1 }
      local R = {}
      for _, r in ipairs(ns.AzeroData.recipes) do R[r.id] = r end
      G:EnterMap('route1', 10, 10, 'up', true)
      local away = { C:Craft(R.smeltcopper) }
      local brew = { C:Craft(R.minorhealing) }
      G:EnterMap('town', 18, 18, 'up', true)
      local smelt = { C:Craft(R.smeltcopper) }
      local stone = { C:Craft(R.roughsharpening) }
      local belt = { C:Craft(R.copperchainbelt) }                -- needs 10 skill
      return { away = away, brew = brew, smelt = smelt, stone = stone, belt = belt, bag = G.save.bag,
               mining = C.Skill('mining'), bs = C.Skill('blacksmithing') }""")
    assert r["away"] == [False, "You need to be at a forge."], r
    assert r["brew"][0] is True and "Minor Healing Potion" in r["brew"][1] and r["bag"]["potion"] == 1, r
    assert r["smelt"][0] is True and "Your skill in Mining has increased to 2." in r["smelt"][1], r
    assert r["stone"][0] is True and r["bag"]["roughsharpening"] == 1 and r["bag"].get("roughstone") is None, r
    assert r["belt"] == [False, "Requires Blacksmithing (10)."], r
    assert r["bag"]["copperore"] == 3 and r["bag"]["copperbar"] == 1 and r["mining"] == 2 and r["bs"] == 2, r
    no_errors(w)


@case
def gear_boosts_stats_and_goes_where_the_beast_goes():
    w, c = game()
    r = c.eval_py("""local G, M, D = ns.Azero, ns.AzeroMon, ns.AzeroData
      local mon = G.save.party[1]
      local def0, spd0 = M.Stat(mon, 'def'), M.Stat(mon, 'spd')
      G.save.bag = { copperchainvest = 1, roughsharpening = 1 }
      local e1 = { G:Equip(1, 'copperchainvest') }
      local def1, spd1 = M.Stat(mon, 'def'), M.Stat(mon, 'spd')
      local e2 = { G:Equip(1, 'roughsharpening') }                 -- claws: the vest stays on
      G.save.bag.copperchainvest = 1
      local e3 = { G:Equip(1, 'copperchainvest') }                 -- a second vest swaps with the first
      local vestBack = G.save.bag.copperchainvest
      local pvp = ns.AzeroPvP.UnpackTeam(ns.AzeroPvP.PackTeam({ mon }))[1].gear
      local traded = ns.AzeroTrade.Unpack(ns.AzeroTrade.Pack(mon)).gear
      pvp = pvp and (pvp.claws .. '+' .. pvp.chest)
      traded = traded and (traded.claws .. '+' .. traded.chest)
      local off = { G:Unequip(1, 'claws') }
      local bad = M.Sanitize({ sp = 'owlet', lvl = 5, gear = 'potion' }).gear
      local wrongSlot = M.Sanitize({ sp = 'owlet', lvl = 5, gear = { chest = 'roughsharpening' } }).gear
      local old = M.Sanitize({ sp = 'owlet', lvl = 5, gear = 'copperchainbelt' }).gear
      return { def0 = def0, def1 = def1, spd0 = spd0, spd1 = spd1, e1 = e1[2], e2 = e2[2], e3 = e3[2], vestBack = vestBack,
               pvp = pvp, traded = traded, off = off[2], stone = G.save.bag.roughsharpening, bad = bad == nil,
               wrongSlot = wrongSlot == nil, old = old and old.waist or false }""")
    assert r["def1"] == int(r["def0"] * 1.1) or r["def1"] == int(r["def0"] * 1.1 + 1e-9), r
    assert r["spd1"] > r["spd0"], r
    assert r["e1"] == "Murkling is now wearing the Copper Chain Vest.", r
    assert r["e2"] == "Murkling is now wearing the Rough Sharpening Stone.", r
    assert r["e3"] == "Murkling took off the Copper Chain Vest and put on the Copper Chain Vest.", r
    assert r["vestBack"] == 1 and r["pvp"] == "roughsharpening+copperchainvest" and r["traded"] == r["pvp"], r
    assert r["off"] == "You took the Rough Sharpening Stone off Murkling." and r["stone"] == 1 and r["bad"], r
    assert r["wrongSlot"] and r["old"] == "copperchainbelt", r                 # an old single piece finds its slot
    assert c.eval("return ns.AzeroAch.Earned().geared ~= nil")
    no_errors(w)


@case
def a_flask_lasts_ten_battles_then_wears_off():
    w, c = game()
    r = c.eval_py("""local G, M, C = ns.Azero, ns.AzeroMon, ns.AzeroCraft
      local mon = G.save.party[1]
      local hp0 = M.MaxHP(mon)
      G.save.bag = { flasktitans = 1 }
      local ok = G:UseFlask(1, 'flasktitans')
      local hp1 = M.MaxHP(mon)
      mon.hp = hp1
      local said = {}
      local g = { Say = function(_, t) said[#said + 1] = t end }
      for i = 1, 9 do C:AfterBattle(g) end
      local left = mon.flask and mon.flask.n
      C:AfterBattle(g)
      return { ok = ok, hp0 = hp0, hp1 = hp1, left = left, gone = mon.flask == nil, hp = mon.hp, said = said }""")
    assert r["ok"] is True and r["hp1"] == int(r["hp0"] * 1.2) and r["left"] == 1 and r["gone"], r
    assert r["hp"] == r["hp0"] and r["said"] == ["The Flask of the Titans on Murkling wore off."], r
    # flasks never go into player battles
    assert c.eval("local m = ns.Azero.save.party[1] m.flask = { id = 'flasksupreme', n = 3 } "
                  "return ns.AzeroPvP.UnpackTeam(ns.AzeroPvP.PackTeam({ m }))[1].flask == nil")
    no_errors(w)


@case
def elixirs_and_rejuvenation_in_battle():
    w, c = game()
    r = c.eval_py("""local G, M = ns.Azero, ns.AzeroMon
      local mon = G.save.party[1]
      mon.status = 'psn'
      mon.hp = 5
      local bag = { lionsstrength = 1, rejuv = 1 }
      local b = ns.AzeroBattle.New({ party = G.save.party, foes = { M.New('wolfpup', 3, G.rng) }, wild = true,
                                     rng = G.rng, bag = bag })
      while b:Pop() do end
      local st0 = b.ally.stages.atk
      local ok1 = b:UseItem('lionsstrength')
      local ok2 = b:UseItem('rejuv', 1)
      local texts = {}
      local e = b:Pop()
      while e do if e.t == 'text' then texts[#texts + 1] = e.text end e = b:Pop() end
      return { st0 = st0, st1 = b.ally.stages.atk, ok1 = ok1, ok2 = ok2, status = mon.status or false, hp = mon.hp,
               texts = texts, left = bag.lionsstrength }""")
    assert r["ok1"] and r["ok2"] and r["st1"] == r["st0"] + 1 and r["left"] == 0, r
    assert r["status"] is False and r["hp"] == 45 or r["hp"] > 5, r
    assert "Murkling's Attack rose!" in r["texts"] and "Murkling was rejuvenated!" in r["texts"], r
    no_errors(w)


@case
def the_professions_page_and_a_forge_through_the_ui():
    w, c = game(ui=True)
    c.eval("ns.Azero.save.prof = { mining = 12, herbalism = 3 } ns.Azero.save.bag.copperore = 2")
    key(w, c, "START", "down", "down", "down", "down", "down", "down", "A")
    assert title(c) == "PROFESSIONS", title(c)
    L = c.eval_py("return ns.AzeroUI._MenuLayout()")
    assert L["n"] == 4 and -L["y"] + L["h"] <= L["SH"] - L["desc"], L
    key(w, c, "down", "down", "A")                                # Mining
    assert title(c) == "MINING  12 / 100", title(c)
    assert "Copper Ore 2/1" in c.eval("return ns.AzeroUI._DescText()") and "Needs a forge." in c.eval("return ns.AzeroUI._DescText()")
    key(w, c, "B", "B", "B")
    # the forge in Goldshire opens smelting, and crafting works there
    c.eval("ns.Azero:EnterMap('town', 19, 18, 'up', true)")
    w.tick(0.2)
    key(w, c, "A")
    w.tick(0.2)
    assert title(c) == "MINING  12 / 100", title(c)
    key(w, c, "A")                                               # Copper Bar
    assert c.eval("return ns.Azero.save.bag.copperbar") == 1
    assert c.eval("return ns.AzeroUI._DescText()").startswith("You create Copper Bar.")
    key(w, c, "B")
    w.tick(0.2)
    assert c.eval("return ns.Azero.pending == nil")
    no_errors(w)


@case
def every_node_stands_on_open_ground():
    w, c = game()
    bad = c.eval_py("""local G, D = ns.Azero, ns.AzeroData
      local bad = {}
      for id, def in pairs(ns.AzeroMaps) do
        if type(def) == 'table' and def.nodes then
          local m = G.Compile(id)
          for k, node in pairs(m.node) do
            if m.solid[k] or m.warp[k] or m.object[k] or m.chest[k] then bad[#bad + 1] = id .. ' ' .. node.x .. ',' .. node.y end
            for _, r in ipairs(node.list) do if not D.resources[r] then bad[#bad + 1] = 'unknown ' .. r end end
            for _, n in ipairs(def.npcs or {}) do
              if n.x == node.x and n.y == node.y then bad[#bad + 1] = id .. ' npc ' .. n.id end
            end
          end
        end
      end
      for _, r in ipairs(D.recipes) do
        if not D.items[r.makes] then bad[#bad + 1] = 'makes ' .. r.id end
        for item in pairs(r.mats) do if not D.items[item] then bad[#bad + 1] = 'mat ' .. item end end
      end
      return bad""")
    assert bad == [], bad
    no_errors(w)


@case
def the_gear_page_shows_every_slot_and_changes_them():
    w, c = game(ui=True)
    c.eval("ns.Azero.save.bag.copperchainvest = 1 ns.Azero.save.bag.flasktitans = 1")
    key(w, c, "START", "down", "A", "A")                           # PARTY > Murkling
    items = c.eval_py("local m = ns.AzeroUI._MenuItems() return m")
    assert items[:2] == ["Summary", "Gear"], items
    key(w, c, "A")                                                  # Summary: the info page
    st = c.eval_py("return ns.AzeroUI._SummaryState()")
    assert st["page"] == "info" and not st["gearShown"] and "INFO" in st["tabs"], st
    key(w, c, "right")
    st = c.eval_py("return ns.AzeroUI._SummaryState()")
    assert st["page"] == "gear" and st["gearShown"], st
    assert st["labels"] == ["Claws", "Shoulders", "Chest", "Wrists", "Waist", "Flask"], st
    assert st["slots"] == [False] * 6 and st["detail"].startswith("Claws: empty.") and st["totals"] == "No gear or flask yet.", st
    key(w, c, "down", "down")                                       # Chest
    assert c.eval_py("return ns.AzeroUI._SummaryState()")["detail"].startswith("Chest: empty."), st
    key(w, c, "A")
    assert title(c) == "CHEST", title(c)
    key(w, c, "A")                                                  # the vest
    st = c.eval_py("return ns.AzeroUI._SummaryState()")
    assert st["slots"][2] == "copperchainvest" and st["detail"] == "Murkling is now wearing the Copper Chain Vest.", st
    assert st["totals"] == "All together: +10% Def, +10% SpD", st
    key(w, c, "up")                                                 # Shoulders: nothing in the bag for it
    key(w, c, "A")
    st = c.eval_py("return ns.AzeroUI._SummaryState()")
    assert st["detail"] == "You have nothing for the Shoulders slot. Blacksmiths make gear.", st
    key(w, c, "up", "up", "A", "A")                                 # Flask (wraps from Claws), the Flask of the Titans
    st = c.eval_py("return ns.AzeroUI._SummaryState()")
    assert st["slots"][5] == "flasktitans" and "+20% HP" in st["totals"], st
    key(w, c, "down", "down", "down", "A")                          # Chest again: Take off
    assert c.eval_py("return ns.AzeroUI._MenuItems()") == ["Take off", "Cancel"]
    key(w, c, "A")
    st = c.eval_py("return ns.AzeroUI._SummaryState()")
    assert st["slots"][2] is False and c.eval("return ns.Azero.save.bag.copperchainvest") == 1, st
    key(w, c, "B")
    assert c.eval("return ns.AzeroUI._SummaryState()") is None
    no_errors(w)


if __name__ == "__main__":
    run_all()

"""Azeromon (Games hub): the Pokemon-style monster-taming game.

Covers: data integrity (moves, species, trainers, maps, atlas tiles, warps), Gen III mechanics (type chart, STAB,
stat stages, catching, exp and level-up, learning a 5th move, evolution, forced switch, blackout), the save
(sanitised on load), a bot playing the whole preview from a new game to the Ranger Captain, and the UI driven by
keys from the title screen through the intro and a full battle without Lua errors.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402

from _azero_bot import BOT  # noqa: E402


def game(seed=7):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    return w, c


def logtext(c):
    return "\n".join(c.eval_py("return T_AZ.log") or [])


# -- data --------------------------------------------------------------------------------------------------------------

@case
def data_is_consistent():
    w, c = game()
    problems = c.eval_py(r"""
      local D, A, Maps, G = ns.AzeroData, ns.AzeroAtlas, ns.AzeroMaps, ns.Azero
      local out = {}
      local function bad(s) out[#out + 1] = s end
      for id, mv in pairs(D.moves) do if not D.types[mv.type] then bad("move type " .. id) end end
      for id, s in pairs(D.species) do
        if not D.types[s.type] then bad("species type " .. id) end
        if #s.base ~= 6 then bad("base " .. id) end
        if type(s.display) ~= "number" then bad("display " .. id) end
        for _, e in ipairs(s.learn) do if not D.moves[e[2]] then bad("learn " .. id .. " " .. e[2]) end end
        if s.evolve and not D.species[s.evolve.into] then bad("evolve " .. id) end
      end
      for id, t in pairs(D.trainers) do
        if t.team ~= "rival" then for _, e in ipairs(t.team) do if not D.species[e[1]] then bad("trainer " .. id) end end end
      end
      for _, sp in ipairs(D.starters) do if not D.rivalStarter[sp] then bad("rival " .. sp) end end
      for id, def in pairs(Maps) do
        if type(def) == "table" and def.rows then
          local w = #def.rows[1]
          for i, r in ipairs(def.rows) do if #r ~= w then bad(id .. " row " .. i .. " width " .. #r) end end
          local m = G.Compile(id)
          for k, name in pairs(m.base) do if not A[name] then bad(id .. " base tile " .. name) end end
          for k, name in pairs(m.over) do if not A[name] then bad(id .. " over tile " .. name) end end
          for _, wp in ipairs(def.warps or {}) do
            local t = G.Compile(wp.map)
            if not t then bad(id .. " warp to " .. wp.map)
            elseif t.solid[t.key(wp.tx, wp.ty)] then bad(id .. " warp lands on a solid tile") end
            if m.solid[m.key(wp.x, wp.y)] then bad(id .. " warp tile solid " .. wp.x .. "," .. wp.y) end
          end
          for _, n in ipairs(def.npcs or {}) do
            if m.solid[m.key(n.x, n.y)] then bad(id .. " npc on solid " .. n.id) end
            if n.trainer and not D.trainers[n.trainer] then bad(id .. " trainer " .. n.trainer) end
          end
          for dir, e in pairs(def.edges or {}) do if not Maps[e.map] then bad(id .. " edge " .. dir) end end
        end
      end
      local s = Maps.START
      if G.Compile(s.map).solid[G.Compile(s.map).key(s.x, s.y)] then bad("start solid") end
      return out
    """)
    assert problems == [], problems
    no_errors(w)


# -- mechanics --------------------------------------------------------------------------------------------------------

@case
def type_chart_and_stab_scale_damage():
    w, c = game()
    r = c.eval_py(r"""
      local B, M = ns.AzeroBattle, ns.AzeroMon
      local function dmg(atkSp, defSp, move)
        local a, d = M.New(atkSp, 20, function() return 15 end), M.New(defSp, 20, function() return 15 end)
        local b = B.New({ party = { a }, foes = { d }, wild = true, rng = function(x, y) return y or x end })
        return (b:Damage("ally", "foe", ns.AzeroData.moves[move], false))
      end
      return { fireVsNature = dmg("emberwhelp", "lashling", "ember"), fireVsWater = dmg("emberwhelp", "murkling", "ember"),
               neutral = dmg("emberwhelp", "wolfpup", "ember"), nonStab = dmg("murkling", "wolfpup", "tackle"),
               earthVsAir = dmg("kobling", "owlet", "rockthrow") }
    """)
    assert r["fireVsNature"] > r["neutral"] > r["fireVsWater"] > 0, r
    assert r["earthVsAir"] == 0, r
    no_errors(w)


@case
def weakened_creatures_are_easier_to_catch_and_join_the_party():
    w, c = game(seed=11)
    r = c.eval_py(r"""
      local G, M, B = ns.Azero, ns.AzeroMon, ns.AzeroBattle
      G:NewGame()
      local s = G.save
      s.party[1] = M.New("murkling", 30, G.rng)
      s.bag.net = 40
      local wild = M.New("owlet", 3, G.rng)
      wild.hp = 1
      local b = B.New({ party = s.party, foes = { wild }, wild = true, bag = s.bag, rng = G.rng,
                        onCaught = function(mon) return G:AddMon(mon) end })
      local throws = 0
      while b.need ~= "done" and throws < 40 do
        throws = throws + 1
        b:Act({ kind = "item", item = "net" })
      end
      return { result = b.result, party = #s.party, throws = throws, caught = s.caught.owlet == true, nets = s.bag.net }
    """)
    assert r["result"] == "caught" and r["party"] == 2 and r["caught"], r
    assert r["nets"] == 40 - r["throws"], r
    no_errors(w)


@case
def a_trainer_blocks_nets():
    w, c = game()
    r = c.eval_py(r"""
      local G, M, B = ns.Azero, ns.AzeroMon, ns.AzeroBattle
      G:NewGame()
      G.save.party[1] = M.New("murkling", 30, G.rng)
      G.save.bag.net = 1
      local b = B.New({ party = G.save.party, foes = G:TrainerTeam("hunter1"), wild = false,
                        trainer = G:TrainerDef("hunter1"), bag = G.save.bag, rng = G.rng })
      b:Act({ kind = "item", item = "net" })
      local texts = {}
      for _, e in ipairs(b.events) do if e.t == "text" then texts[#texts + 1] = e.text end end
      return { need = b.need, texts = texts }
    """)
    assert r["need"] == "action"
    assert any("swatted the rod away" in t for t in r["texts"]), r
    no_errors(w)


@case
def level_up_offers_a_fifth_move_and_replaces_the_chosen_one():
    w, c = game(seed=3)
    r = c.eval_py(r"""
      local G, M, B, D = ns.Azero, ns.AzeroMon, ns.AzeroBattle, ns.AzeroData
      G:NewGame()
      local mon = M.New("emberwhelp", 15, G.rng)
      mon.exp = M.ExpForLevel(16) - 1
      G.save.party[1] = mon
      local before = {}
      for i, m in ipairs(mon.moves) do before[i] = m.id end
      local wild = M.New("wolfpup", 5, G.rng)
      wild.hp = 1
      local b = B.New({ party = G.save.party, foes = { wild }, wild = true, rng = G.rng })
      T_AZ.learnSlot = 2
      local res = T_AZ.fight(b)
      local after = {}
      for i, m in ipairs(mon.moves) do after[i] = m.id end
      return { res = res, lvl = mon.lvl, before = before, after = after }
    """)
    assert r["res"] == "win" and r["lvl"] == 16, r
    assert r["before"] == ["scratch", "growl", "ember", "leer"], r
    assert r["after"] == ["scratch", "flamebreath", "ember", "leer"], r
    no_errors(w)


@case
def lashling_evolves_after_the_battle():
    w, c = game(seed=5)
    r = c.eval_py(r"""
      local G, M = ns.Azero, ns.AzeroMon
      G:NewGame()
      local mon = M.New("lashling", 13, G.rng)
      mon.exp = M.ExpForLevel(14) - 1
      G.save.party[1] = mon
      G:Run(function(g)
        local foe = M.New("wolfpup", 5, g.rng)
        foe.hp = 1
        g:RunBattle({ foe }, nil)
      end)
      T_AZ.settle()
      return { sp = mon.sp, lvl = mon.lvl, caught = G.save.caught.flaytrap == true }
    """)
    assert r == {"sp": "flaytrap", "lvl": 14, "caught": True}, r
    assert "evolved into Flaytrap" in logtext(c)
    no_errors(w)


@case
def emberwhelp_evolves_into_the_flamescale_drake():
    w, c = game(seed=5)
    r = c.eval_py(r"""
      local G, M, D = ns.Azero, ns.AzeroMon, ns.AzeroData
      G:NewGame()
      local mon = M.New("emberwhelp", 15, G.rng)
      mon.exp = M.ExpForLevel(16) - 1
      G.save.party[1] = mon
      G:Run(function(g)
        local foe = M.New("wolfpup", 5, g.rng)
        foe.hp = 1
        g:RunBattle({ foe }, nil)
      end)
      T_AZ.settle()
      local nums = {}
      for id, sp in pairs(D.species) do nums[sp.num] = (nums[sp.num] or 0) + 1 end
      local dup = false
      for _, n in pairs(nums) do if n > 1 then dup = true end end
      return { sp = mon.sp, lvl = mon.lvl, caught = G.save.caught.flamescale == true,
               last = D.species.flamescale.num == 45 and "flamescale" or "?", dup = dup,
               completable = (function() for _, id in ipairs(ns.AzeroGuild.CompletableIds()) do
                   if id == "flamescale" then return true end end return false end)() }
    """)
    assert r == {"sp": "flamescale", "lvl": 16, "caught": True, "last": "flamescale", "dup": False,
                 "completable": True}, r
    assert "evolved into Flamescale Drake" in logtext(c)
    no_errors(w)


@case
def an_overdue_beast_evolves_after_its_next_battle_unless_it_fainted():
    """Levelled past its evolution without evolving (fainted then, or before the evolution existed): the next battle
    it is standing at the end of evolves it, no level needed."""
    w, c = game(seed=5)
    r = c.eval_py(r"""
      local G, M = ns.Azero, ns.AzeroMon
      G:NewGame()
      local whelp = M.New("emberwhelp", 16, G.rng)
      local owlet = M.New("owlet", 16, G.rng)
      local fainted = M.New("murkling", 17, G.rng)
      fainted.hp = 0
      G.save.party = { whelp, fainted, owlet }
      G:Run(function(g)
        local foe = M.New("wolfpup", 2, g.rng)
        foe.hp = 1
        g:RunBattle({ foe }, nil)
      end)
      T_AZ.settle()
      return { whelp = whelp.sp, lvl = whelp.lvl, fainted = fainted.sp }
    """)
    assert r == {"whelp": "flamescale", "lvl": 16, "fainted": "murkling"}, r
    assert "evolved into Flamescale Drake" in logtext(c)
    no_errors(w)


@case
def fainted_lead_forces_a_switch_and_a_wipe_blacks_out():
    w, c = game(seed=9)
    r = c.eval_py(r"""
      local G, M = ns.Azero, ns.AzeroMon
      G:NewGame()
      G.save.party = { M.New("owlet", 2, G.rng), M.New("webling", 2, G.rng) }
      G.save.money = 1000
      G:EnterMap("route1", 11, 20, "up", true)
      local switches = 0
      G:Run(function(g) g:RunBattle({ M.New("kobling", 40, g.rng) }, "hunter1") end)
      for _ = 1, 3000 do
        local p = G.pending
        if not p then break end
        if p.kind == "battle" then
          local b = p.battle
          while b:Pop() do end
          if b.need == "switch" then switches = switches + 1 b:Act({ kind = "switch", idx = 2 })
          elseif b.need == "action" then b:Act({ kind = "move", idx = 1 })
          elseif b.need == "done" then G:Advance(b.result) end
        elseif p.kind == "text" then T_AZ.log[#T_AZ.log + 1] = p.text G:Advance()
        else G:Update(0.05) end
      end
      local s = G.save
      return { switches = switches, map = s.map, money = s.money, hp1 = s.party[1].hp == M.MaxHP(s.party[1]),
               hp2 = s.party[2].hp == M.MaxHP(s.party[2]) }
    """)
    assert r["switches"] == 1, r
    assert r["map"] == "post" and r["money"] == 500 and r["hp1"] and r["hp2"], r
    assert "dropped 5s" in logtext(c)
    no_errors(w)


@case
def a_broken_save_is_repaired_on_load():
    w, c = game()
    r = c.eval_py(r"""
      local G = ns.Azero
      G:Data().save = { v = 1, map = "nowhere", x = 1, y = 1, money = "lots",
        party = { { sp = "emberwhelp", lvl = 900, hp = -5, moves = { { id = "nope" }, { id = "ember", pp = 99 } } },
                  { sp = "missingno", lvl = 5 } },
        bag = { net = 3, fake = 2, potion = -1 } }
      G:Load()
      local s = G.save
      return { map = s.map, party = #s.party, lvl = s.party[1].lvl, hp = s.party[1].hp, moves = #s.party[1].moves,
               pp = s.party[1].moves[1].pp, net = s.bag.net, fake = s.bag.fake, potion = s.bag.potion, money = s.money,
               max = ns.AzeroMon.MaxHP(s.party[1]) }
    """)
    # (a party where nothing can fight - a save from mid-battle - is rested)
    assert r["map"] == "home" and r["party"] == 1 and r["lvl"] == 100 and r["hp"] == r["max"], r
    assert r["moves"] == 1 and r["pp"] == 25 and r["net"] == 3, r
    assert r.get("fake") is None and r.get("potion") is None and r["money"] == 0, r
    no_errors(w)


# -- story -------------------------------------------------------------------------------------------------------------

@case
def guard_turns_you_back_without_a_starter():
    w, c = game()
    r = c.eval_py(r"""
      local G = ns.Azero
      G:NewGame()
      G:EnterMap("town", 17, 3, "up", true)
      T_AZ.walkTo(17, 1)
      T_AZ.settle()
      return { x = G.save.x, y = G.save.y, map = G.save.map }
    """)
    assert r == {"x": 17, "y": 2, "map": "town"}, r
    assert "Hold it!" in logtext(c)
    no_errors(w)


@case
def bot_plays_the_whole_preview():
    w, c = game(seed=21)
    r = c.eval_py(r"""
      local G, M = ns.Azero, ns.AzeroMon
      local trace = {}
      local function go(x, y, label)
        local ok, why = T_AZ.walkTo(x, y)
        trace[#trace + 1] = label .. "=" .. tostring(ok) .. (why and (":" .. why) or "") .. "@" .. G.save.map .. " " .. G.save.x .. "," .. G.save.y
        return ok
      end
      G:NewGame()
      go(4, 7, "leave home")                 -- the exit mat warps to town (5, 7)
      go(28, 8, "lab door")
      go(4, 5, "starter basket")
      T_AZ.face("up")
      T_AZ.choice = 1
      G:PressA()                             -- Murkling basket
      T_AZ.settle()
      local s = G.save
      local starter = s.party[1] and s.party[1].sp
      -- make the run deterministic: a strong starter
      local mon = s.party[1]
      mon.lvl = 30 mon.exp = M.ExpForLevel(30) mon.moves = M.DefaultMoves(mon.sp, 30) M.Heal(mon)
      go(4, 7, "leave lab")
      go(17, 0, "town exit")
      T_AZ.step("up")                        -- north edge -> Brightbrook Trail
      local routeY = G.save.y
      go(19, 12, "potion chest")             -- stands below the chest at (19, 11)
      T_AZ.face("up") G:PressA() T_AZ.settle()
      go(11, 3, "captain")                   -- Deputy Rainer spots you from (13, 2)
      T_AZ.settle()
      go(10, 2, "road north")
      T_AZ.step("up")                        -- the gate: no badge yet -> pushed back
      T_AZ.settle()
      local gated = { G.save.map, G.save.y }
      go(0, 2, "west exit")
      T_AZ.step("left")                      -- -> Forest's Edge
      local fe = G.save.map
      go(5, 7, "hogger")                     -- the gnolls on the trail spot you on the way
      T_AZ.face("left") G:PressA() T_AZ.settle()
      local badge = s.flags.badge_hogger == true
      M.Heal(mon)                            -- (a player would rest at the inn here)
      go(19, 6, "camp exit")
      T_AZ.step("right")                     -- back to Elwynn
      go(10, 1, "gate again")
      go(10, 0, "road top")
      T_AZ.step("up")                        -- -> Westfall
      local wfY = G.save.y
      M.Heal(mon)                            -- (Salma Saldean's stew)
      go(11, 0, "westfall north")
      T_AZ.step("up")                        -- -> Sentinel Hill
      go(11, 7, "gryan")
      T_AZ.face("up") G:PressA() T_AZ.settle()
      local beaten = {}
      for k, v in pairs(s.flags) do if k:find("^beat_") then beaten[#beaten + 1] = k end end
      table.sort(beaten)
      return { starter = starter, map = s.map, routeY = routeY, nets = s.bag.net, potions = s.bag.potion,
               beaten = beaten, battles = T_AZ.battles, trace = trace, flags = s.flags.rivalDone == true,
               gated = gated, fe = fe, badge = badge, wfY = wfY,
               seen = (function() local n = 0 for _ in pairs(s.seen) do n = n + 1 end return n end)() }
    """)
    assert r["starter"] == "murkling", r
    assert r["flags"] and r["potions"] >= 2, r
    assert r["routeY"] == 32, r
    assert r["gated"] == ["route1", 2], r
    assert r["fe"] == "forestedge" and r["badge"], r
    for t in ("beat_captain", "beat_hogger", "beat_militia1"):
        assert t in r["beaten"], r
    assert r["wfY"] == 33 and r["map"] == "sentinel", r
    assert r["seen"] >= 5, r
    text = logtext(c)
    for needle in ("Rival Vera", "Hogger's Claw", "Deputy Rainer: Hold on!", "Gryan Stoutmantle"):
        assert needle in text, (needle, text[-1500:])
    # the real Hogger encounter awards the badge, and the badge the achievement (event feed end to end)
    got = c.eval_py("local t = {} for id in pairs(ns.AzeroAch.Earned()) do t[#t + 1] = id end return t")
    for ach in ("hogger", "militia"):         # (the bot loses its first battle to Vera: she picks the counter)
        assert ach in got, got
    no_errors(w)


@case
def event_snapshots_follow_the_playback_order():
    """The UI shows each event's snapshot: HP may only change on that side's own hp event."""
    w, c = game(seed=13)
    bad = c.eval_py(r"""
      local G, M, B = ns.Azero, ns.AzeroMon, ns.AzeroBattle
      G:NewGame()
      local party = { M.New("murkling", 12, G.rng), M.New("owlet", 10, G.rng) }
      local b = B.New({ party = party, foes = G:TrainerTeam("captain"), wild = false,
                        trainer = G:TrainerDef("captain"), rng = G.rng })
      local out, last = {}, nil
      for _ = 1, 400 do
        local e = b:Pop()
        while e do
          if last then
            for _, side in ipairs({ "ally", "foe" }) do
              local a, z = last[side], e.snap[side]
              if a and z and a.name == z.name and a.hp ~= z.hp then
                if not (e.t == "hp" and e.side == side and e.from == a.hp and e.to == z.hp) then
                  out[#out + 1] = e.t .. " changed " .. side .. " hp " .. a.hp .. "->" .. z.hp
                end
              end
            end
          end
          last = e.snap
          e = b:Pop()
        end
        if b.need == "done" then break end
        if b.need == "action" then b:Act({ kind = "move", idx = 1 })
        elseif b.need == "switch" then for i, m in ipairs(party) do if m.hp > 0 then b:Act({ kind = "switch", idx = i }) break end end
        elseif b.need == "learn" then b:ResolveLearn(nil) end
      end
      return out
    """)
    assert bad == [], bad
    no_errors(w)


@case
def stacked_menus_draw_above_the_menu_below():
    """Battle > BAG > Healing Salve > party picker: each menu (and its rows) sits above the one under it."""
    w, c = game(seed=4)
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    for _ in range(40):
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        if not c.eval("return ns.Azero.pending ~= nil"):
            break
    c.eval("local G = ns.Azero; G.save.bag.potion = 1; G.save.party[1] = ns.AzeroMon.New('lashling', 5, G.rng); "
           "G.save.party[1].hp = 3; G:Run(function(g) g:WildBattle('owlet', 3) end)")
    for _ in range(60):
        w.tick(0.3)
        if c.eval("return ns.AzeroUI._State().stack") >= 1:
            break
        c.eval("ns.AzeroUI._HandleKey('A')")
    for k in ("right", "A", "A"):          # BAG, Healing Salve -> "use on which?"
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.1)
    levels = c.eval_py("return ns.AzeroUI._Levels()")
    assert len(levels) == 3, levels
    for below, above in zip(levels, levels[1:]):
        assert above["level"] > below["row"] and above["row"] > above["level"], levels
    no_errors(w)


def _ui_battle(c, w, lead="emberwhelp"):
    """UI started, intro done, a wild battle open at the FIGHT / BAG / PARTY / RUN menu."""
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    for _ in range(40):
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        if not c.eval("return ns.Azero.pending ~= nil"):
            break
    c.eval("local G = ns.Azero; G.save.party[1] = ns.AzeroMon.New('%s', 5, G.rng); "
           "G:Run(function(g) g:WildBattle('kobling', 3) end)" % lead)
    for _ in range(60):
        w.tick(0.3)
        if c.eval("return ns.AzeroUI._State().stack") >= 1:
            return
        c.eval("ns.AzeroUI._HandleKey('A')")
    raise AssertionError("no action menu")


@case
def party_summary_in_battle_closes_cleanly():
    """PARTY > creature > Summary > close > close: back at the action menu, and FIGHT still works."""
    w, c = game(seed=4)
    _ui_battle(c, w)
    for k in ("down", "A", "A", "down", "A"):     # PARTY, the lead, sub-menu, Summary
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.1)
    assert c.eval("return ns.AzeroUI._Summary()") is True
    c.eval("ns.AzeroUI._HandleKey('B')")          # close the summary
    w.tick(0.1)
    assert c.eval("return ns.AzeroUI._Summary()") is False
    # the summary frame must never come back as a menu
    c.eval("ns.AzeroUI._HandleKey('A')")          # sub-menu again
    w.tick(0.1)
    assert c.eval("return ns.AzeroUI._Summary()") is False
    c.eval("ns.AzeroUI._HandleKey('B')")          # close sub-menu
    c.eval("ns.AzeroUI._HandleKey('B')")          # close party
    w.tick(0.1)
    assert c.eval("return ns.AzeroUI._State().stack") == 1
    c.eval("ns.AzeroUI._HandleKey('up')")         # FIGHT
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.1)
    assert c.eval("return ns.AzeroUI._State().stack") == 2
    no_errors(w)


# Where the mock "engine" really draws the creature: the mock's true box for the display (the idle envelope from
# the model's ground up), turned by the yaw actually given to the actor, at the actor's scale, projected with the
# mock's own camera conventions. Computed independently of the addon's fitting code.
TRUE_RECT = r"""
local sc = ns.AzeroUI._Scene(...)
local a = sc.actor
local d = a.display
if not d or not a.scale then return nil end
local h, w = 0.5 + (d % 9) * 0.6, 0.4 + (d % 5) * 0.5
local zTop = (d % 3 == 0) and (h + 0.8) or h
local bx0, by0, bz0, bx1, by1, bz1 = -0.6 * w, -0.3 * w, 0, 0.4 * w, 0.7 * w, zTop
-- (a creature whose real box the mock knows - the Lurker's lurkling - has that box instead)
local rx0, ry0, rz0, rx1, ry1, rz1 = a:GetMaxBoundingBox()
if rx0 and math.abs(rx0 - bx0) > 1e-6 then bx0, by0, bz0, bx1, by1, bz1 = rx0, ry0, rz0, rx1, ry1, rz1 end
local sn, cs = math.sin(a.yaw or 0), math.cos(a.yaw or 0)
local es = sc:GetEffectiveScale() or 1
local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
for _, x in ipairs({ bx0, bx1 }) do for _, y in ipairs({ by0, by1 }) do for _, z in ipairs({ bz0, bz1 }) do
  local px, py = sc:Project3DPointTo2D((x * cs - y * sn) * a.scale, (x * sn + y * cs) * a.scale, z * a.scale)
  px, py = px / es, py / es
  x0, x1, y0, y1 = math.min(x0, px), math.max(x1, px), math.min(y0, py), math.max(y1, py)
end end end
local W, H = sc:GetWidth(), sc:GetHeight()
return { h = (y1 - y0) / H, w = (x1 - x0) / W, feet = y0 / H, center = (x0 + x1) / 2 / W, anim = a.anim or 0 }
"""


def _fit_all(no_template=False):
    w, c = game()
    if no_template:
        c.eval("__MOCK_NO_ACTOR_TEMPLATE = true")
    # in the mock, scene +y is screen-LEFT, so creatures only face each other with the facing flipped - the
    # in-game fix (/dz azeromon flip) a player would apply
    c.eval("ns.Azero:Data().flipFacing = true")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    ids = c.eval_py("return ns.AzeroData.dexOrder")
    out = []
    for sp in ids:                                   # all in the same frame, one after another, like battles
        c.eval("ns.AzeroUI._ShowFoe(%r)" % sp)
        w.tick(2.2)                                  # load, then 1.6 s of idle pose sampling, then the fit
        info = c.eval_py("return ns.AzeroUI._FitInfo()")
        truth = c.eval_py(TRUE_RECT, "foe")
        disp = c.eval("return ns.AzeroData.species[%r].display" % sp)
        out.append((sp, disp, info, truth))
    return w, c, out


def _check_fits(results):
    for sp, disp, info, truth in results:
        assert info and info["projected"], (sp, info)
        # what is REALLY drawn (independent of the addon's maths): same share of the frame for every creature,
        # ground on the platform line, centred - including snouts/tails and hovering fliers
        big = max(truth["h"] / 0.78, truth["w"] / 0.86)
        assert abs(big - 1) < 0.02, (sp, truth)
        assert truth["h"] <= 0.79 and truth["w"] <= 0.87, (sp, truth)
        assert abs(truth["feet"] - 0.03) < 0.005, (sp, truth)
        assert abs(truth["center"] - 0.5) < 0.01, (sp, truth)
        # measured THIS creature, not the previous one still loaded in the same frame (mock: w = 0.4 + d%5 * 0.5)
        # (the mock's real boxes, wowmock/objects.lua DISPLAY_BOXES: the Lurker's lurkling)
        x0, x1 = {20216: (-9.68, 5.6), 23200: (-5.96, 15.65)}.get(disp, (-0.6 * (0.4 + (disp % 5) * 0.5),
                                                                 0.4 * (0.4 + (disp % 5) * 0.5)))
        assert abs(info["x0"] - x0) < 1e-6 and abs(info["x1"] - x1) < 1e-6, (sp, disp, info)
        if disp % 3 == 0:
            # hovering idle (mock: 0.2 .. 0.8 above its ground): the whole bob is measured, the rearing animation
            # of the all-animations box is not, and the ground stays in (it lands there when it faints)
            h = 0.5 + (disp % 9) * 0.6
            assert info["z0"] <= 0.21 and info["z1"] < h + 0.81 and info["ground"] == 0, (sp, info)


@case
def every_creature_is_fitted_to_the_same_size_on_its_platform():
    """Battle models are measured after they have really loaded (not the previous creature's lingering box),
    over a full idle bob, turned the way they are drawn, and checked with the engine's own projection - in the
    mock that projection uses a horizontal field of view and a flipped sideways axis, which plain camera maths
    would get wrong. The result is verified against where the mock really draws each creature."""
    w, c, results = _fit_all()
    assert len(results) == c.eval("return #ns.AzeroData.dexOrder")
    _check_fits(results)
    cam = c.eval_py("return ns.AzeroUI._Camera()")
    assert cam["dist"] >= 50 and cam["fov"] < 0.1, cam
    no_errors(w)


@case
def fitting_also_works_without_the_actor_load_event():
    """Without Blizzard's actor template (no load callback) the model file change is the load signal."""
    w, c, results = _fit_all(no_template=True)
    _check_fits(results)
    no_errors(w)


@case
def a_model_that_loads_late_is_still_fitted():
    """Nothing to measure for 10 s: shown unfitted (ground on the platform line) - and fitted properly as soon as
    its load event arrives, instead of staying wrong."""
    w, c = game()
    c.eval("ns.Azero:Data().flipFacing = true")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("__MOCK_SLOW_DISPLAY = ns.AzeroData.species.kobling.display")
    c.eval("ns.AzeroUI._ShowFoe('kobling')")
    w.tick(10.5)
    assert c.eval_py("return ns.AzeroUI._Scene('foe').fitInfo") == {"gaveUp": True}
    w.tick(4)                                        # loads at 12 s, then 1.6 s of sampling
    truth = c.eval_py(TRUE_RECT, "foe")
    assert truth and abs(max(truth["h"] / 0.78, truth["w"] / 0.86) - 1) < 0.02, truth
    assert abs(truth["feet"] - 0.03) < 0.005, truth
    no_errors(w)


@case
def the_next_creature_never_inherits_a_death_pose():
    """A foe faints (death animation), the next battle reuses the same frame: the new creature must be idle
    (and is measured idle), not lying dead."""
    w, c = game(seed=4)
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    for _ in range(40):
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        if not c.eval("return ns.Azero.pending ~= nil"):
            break
    c.eval("local M = ns.AzeroMon; local mon = M.New('murkling', 30, ns.Azero.rng); "
           "mon.moves = { { id = 'waterjet', pp = 25 } }; ns.Azero.save.party[1] = mon")
    fainted = False
    for species in ("wolfpup", "kobling"):
        c.eval("ns.Azero:Run(function(g) g:WildBattle(%r, 2) end)" % species)
        for _ in range(300):
            w.tick(0.25)
            c.eval("ns.AzeroUI._HandleKey('A')")
            if c.eval("return ns.AzeroUI._Scene('foe').actor.anim") == 1:
                fainted = True                       # the death animation really played
            if not c.eval("return ns.Azero.pending ~= nil or ns.AzeroUI._State().battle"):
                break
    assert fainted
    assert c.eval("return ns.AzeroUI._Scene('foe').actor.anim") == 0
    no_errors(w)


@case
def the_title_screen_plays_the_zones_behind_its_logo():
    w, c = game()
    c.slash("/dz play azeromon")
    w.tick(3)
    assert c.eval("return ns.AzeroUI._TitleFilm() ~= nil and ns.AzeroUI._TitleFilm():IsShown()")
    t0 = c.eval("return ns.AzeroUI._TitleFilm().clock")
    w.tick(1)
    assert c.eval("return ns.AzeroUI._TitleFilm().clock") > t0          # the film runs while the title shows
    c.slash("/dz")          # close and reopen the window: the same film, not a second one
    w.tick(0.2)
    film = c.eval("return tostring(ns.AzeroUI._TitleFilm())")
    c.slash("/dz play azeromon")
    w.tick(1)
    assert c.eval("return tostring(ns.AzeroUI._TitleFilm())") == film
    no_errors(w)


@case
def ui_title_intro_walk_and_battle_by_keys():
    w, c = game(seed=4)
    c.slash("/dz play azeromon")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "games"
    assert c.eval("return ns.AzeroUI._State() ~= nil")
    # title: NEW GAME is the only option without a save
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.2)
    assert c.eval("return ns.Azero.started == true")
    # intro text: press A until it is done
    for _ in range(40):
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        if not c.eval("return ns.Azero.pending ~= nil"):
            break
    assert c.eval("return ns.Azero.pending == nil")
    # no atlas texture is shown without tile coordinates (it would draw the whole atlas squashed into one tile)
    stray = c.eval_py(r'''
      local n = 0
      for obj, st in pairs(__MOCK.OBJ) do
        if st.kind == "Texture" and type(st.texture) == "string" and st.texture:find("Azeromon", 1, true) and st.texture:find("atlas", 1, true)
           and not st.texcoord and obj:IsShown() then n = n + 1 end
      end
      return n''')
    assert stray == 0, stray
    # walk right one tile
    c.eval("ns.Azero:SetDir('right')")
    w.tick(0.5)
    c.eval("ns.Azero:SetDir(nil)")
    w.tick(0.3)
    # start menu opens and closes
    c.eval("ns.AzeroUI._HandleKey('START')")
    w.tick(0.1)
    assert c.eval("return ns.AzeroUI._State().stack") == 1
    c.eval("ns.AzeroUI._HandleKey('B')")
    w.tick(0.1)
    assert c.eval("return ns.AzeroUI._State().stack") == 0
    # a wild battle, played only with the A key (FIGHT, first move, text)
    c.eval("local M = ns.AzeroMon; local mon = M.New('murkling', 25, ns.Azero.rng); mon.moves = { { id = 'waterjet', pp = 25 } }; "
           "ns.Azero.save.party[1] = mon; "
           "ns.Azero:Run(function(g) g:WildBattle('wolfpup', 3) end)")
    finished = False
    for _ in range(400):
        w.tick(0.25)
        c.eval("ns.AzeroUI._HandleKey('A')")
        if not c.eval("return ns.Azero.pending ~= nil or ns.AzeroUI._State().battle"):
            finished = True
            break
    assert finished, c.eval_py("return ns.AzeroUI._State()")
    assert c.eval("return ns.Azero.save.seen.wolfpup == true")
    no_errors(w)


if __name__ == "__main__":
    run_all()

r"""Hold the Line (Games/HoldTheLine/): the run, the spells, the overlays, the panel.

Covers: a seeded run is the same twice; the clock's events (the ring, the Abomination at 5:00, the Lich at 10:00, the
Pale Rider at 15:00 ending the run as a win); every spell of both classes casts and hurts (and the Ashbringer purges);
level-ups open the picker with three cards whose previews run, a pick adds the spell / blessing and the icon flies to
the bar; a coffer from an elite opens and its legendary can be taken; a bot plays 15 minutes with god mode to the
end without an error; the panel: title, class pick, keys move, Esc pauses, the spell lab (and leaving it); talents bought with banked
gold, carried into runs, refunded; the dev scenarios (a development copy only) jump to a stage's moment and are never
recorded. The late game: levels come at a pace (XP waits on the bar), a full build turns levels into Paragon, four spell
and four blessing slots, every path and legendary casts and hurts, rank 3 opens the path screen, a new legendary is
revealed by name.

Run: luaenv\Scripts\python.exe tests\games\test_holdtheline.py [-k name]
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


@case
def it_registers_and_the_panel_opens_on_the_title():
    w, c = boot()
    assert c.eval_py("return ns.Games:Get('holdtheline') ~= nil"), "not registered"
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(1.0)
    no_errors(w)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "title"
    assert c.eval_py("return ns.HTLUI._Run().attract")


@case
def a_seeded_run_is_the_same_twice():
    w, c = boot()
    a, b = c.eval_py(r"""
      local E = ns.HTL
      local function go() local r = E.New({ cls = 'MAGE', seed = 4242, god = true, bot = true }) E.FastForward(r, 120, true) return r.kills .. '/' .. r.level .. '/' .. #r.en end
      return go(), go()
    """)
    assert a == b, (a, b)


@case
def the_clock_brings_its_bosses_and_the_pale_rider_ends_the_run():
    w, c = boot()
    out = c.eval_py(r"""
      local E = ns.HTL
      local r = E.New({ cls = 'PALADIN', seed = 77, god = true, bot = true })
      local seen = {}
      for i = 1, 1150 * 30 do
        E.Step(r, 1 / 30, 0, 0)
        r.wantLevelUp = nil r.pending = 0 r.chest = nil
        for _, e in ipairs(r.en) do seen[e.type] = true end
        if r.over then break end
      end
      return seen.abom and 1 or 0, seen.lich and 1 or 0, seen.reaper and 1 or 0, r.t
    """)
    assert out[0] == 1 and out[1] == 1 and out[2] == 1, out
    no_errors(w)


@case
def every_spell_casts_and_hurts():
    w, c = boot()
    bad = c.eval_py(r"""
      local E, D, out = ns.HTL, ns.HTLData, {}
      for _, id in ipairs(D.SPELL_ORDER) do
        local cls = D.SPELLS[id].cls or 'PALADIN'
        local r = E.New({ cls = cls, seed = 9, god = true, lab = true, noStart = true })
        r.labN = 40
        E.AddSpell(r, id) for _ = 1, 4 do E.AddSpell(r, id) end
        for _ = 1, 6 * 30 do E.Step(r, 1 / 30, 0, 0) end
        if r.kills == 0 then out[#out + 1] = id end
      end
      return table.concat(out, ',')
    """)
    assert bad == "", "no kills: " + bad
    no_errors(w)


@case
def the_ashbringer_purges():
    w, c = boot()
    n = c.eval_py(r"""
      local E = ns.HTL
      local r = E.New({ cls = 'PALADIN', seed = 9, god = true, lab = true })
      r.labN = 60
      for _ = 1, 4 do E.AddSpell(r, 'consecration') end
      E.AddPassive(r, 'crusader')
      E.Apply(r, { kind = 'legend', id = 'consecration' })
      local purged = 0
      for _ = 1, 8 * 30 do E.Step(r, 1 / 30, 0, 0) for _, c in ipairs(r.corpses) do if c.purge then purged = purged + 1 end end end
      return purged
    """)
    assert n > 0
    no_errors(w)


@case
def a_level_up_opens_the_picker_and_a_pick_lands_on_the_bar():
    w, c = boot()
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(1.0)
    c.eval("ns.HTLUI.Start('PALADIN')")
    w.tick(0.5)
    c.eval("ns.HTLUI._Run().pending = 1")
    w.tick(1.5)
    no_errors(w)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "level"
    n = c.eval_py("local n = 0 for _, pv in ipairs(ns.HTLUI._Previews()) do if pv.on then n = n + 1 end end return n")
    assert n >= 2, n
    before = c.eval_py("local r = ns.HTLUI._Run() return #r.order + #r.porder")
    c.eval("ns.HTLUI.TakeLevel(1)")
    w.tick(1.5)
    no_errors(w)
    assert c.eval_py("return ns.HTLUI._Overlay()") is None
    after = c.eval_py("local r = ns.HTLUI._Run() local s = 0 for _, id in ipairs(r.order) do s = s + r.spells[id].r end for _, id in ipairs(r.porder) do s = s + r.passives[id] end return s")
    assert after >= 2, after


@case
def a_coffer_with_a_legendary_is_taken():
    w, c = boot()
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(1.0)
    c.eval("ns.HTLUI.Start('PALADIN')")
    w.tick(0.3)
    c.eval(r"""
      local r = ns.HTLUI._Run()
      for _ = 1, 4 do ns.HTL.AddSpell(r, 'consecration') end
      ns.HTL.AddPassive(r, 'crusader')
      ns.HTL.OpenChest(r, true)
    """)
    w.tick(2.0)
    no_errors(w)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "legend"
    c.eval("ns.HTLUI.TakeLegend()")
    w.tick(0.5)
    assert c.eval_py("return ns.HTLUI._Run().ashbringer")


@case
def a_bot_plays_the_whole_run_without_an_error():
    w, c = boot("MAGE")
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(1.0)
    c.eval("ns.HTLUI.Start('MAGE') ns.HTLUI._Run().god = true ns.HTLUI._Run().bot = true")
    over = c.eval_py(r"""
      local r = ns.HTLUI._Run()
      for i = 1, 1200 * 10 do
        r.wantLevelUp = nil r.chest = nil
        ns.HTL.Step(r, 1 / 10, 0, 0)
        if i % 50 == 0 then ns.HTLRender.Draw(ns.HTLUI._View(), r) end
        if r.over then break end
      end
      return r.over
    """)
    no_errors(w)
    assert over == "victory", over


@case
def giving_up_from_the_pause_ends_the_run_and_banks_its_gold():
    w, c = boot()
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(1.0)
    c.eval("ns.HTLGame.Data().bank = 0 ns.HTLUI.Start('PALADIN')")
    w.tick(0.3)
    c.eval("ns.HTLUI._Run().gold = 41 ns.HTLUI._Key('ESCAPE')")
    w.tick(0.2)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "pause"
    c.eval("ns.HTLUI.GiveUp()")
    w.tick(0.3)
    no_errors(w)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "end"
    assert c.eval_py("return ns.HTLUI._Run().over") == "death"
    assert c.eval_py("return ns.HTLGame.Data().bank") == 41


@case
def paused_the_game_gets_every_key_but_esc():
    w, c = boot()
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(1.0)
    c.eval("ns.HTLUI.Start('PALADIN') ns.HTLUI.SetFocus(true)")
    w.tick(0.3)
    c.eval("ns.HTLUI._Key('W')")
    assert not c.eval_py("return ns.HTLUI._Root():GetPropagateKeyboardInput()"), "playing, W is the game's"
    c.eval("ns.HTLUI._Key('W', true) ns.HTLUI._Key('ESCAPE')")
    w.tick(0.2)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "pause"
    c.eval("ns.HTLUI._Key('W')")                   # (held down while paused: WoW moves you, the hero stays)
    assert c.eval_py("return ns.HTLUI._Root():GetPropagateKeyboardInput()"), "paused, W should reach WoW"
    c.eval("ns.HTLUI._Key('ESCAPE')")
    assert not c.eval_py("return ns.HTLUI._Root():GetPropagateKeyboardInput()"), "Esc stays ours: it resumes"
    assert c.eval_py("return ns.HTLUI._Overlay()") is None
    p0 = c.eval_py("local r = ns.HTLUI._Run() return { x = r.p.x, y = r.p.y }")
    w.tick(0.5)
    p1 = c.eval_py("local r = ns.HTLUI._Run() return { x = r.p.x, y = r.p.y }")
    assert p0 == p1, ("a key pressed during the pause walked the hero", p0, p1)
    no_errors(w)


@case
def esc_pauses_and_the_lab_opens():
    w, c = boot()
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(1.0)
    c.eval("ns.HTLUI.Start('MAGE')")
    w.tick(0.3)
    c.eval("ns.HTLUI._Key('ESCAPE')")
    w.tick(0.2)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "pause"
    c.eval("ns.HTLUI.OpenLab('PALADIN')")
    w.tick(2.0)
    no_errors(w)
    assert c.eval_py("return ns.HTLUI._Run().lab")
    assert c.eval_py("return ns.HTLUI.lab:IsShown()"), "the lab's bar is not up"
    # leaving it: back on the title, and the bar goes too (a lab button used to bring it back)
    c.eval("local b = ns.HTLUI.lab.leaveList[1] b:GetScript('OnClick')(b)")
    w.tick(0.5)
    no_errors(w)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "title"
    assert not c.eval_py("return ns.HTLUI.lab:IsShown()"), "the lab's bar stayed up after leaving"




@case
def the_warrior_swings_charges_and_thunderfury_chains():
    w, c = boot("WARRIOR")
    out = c.eval_py(r"""
      local E = ns.HTL
      local r = E.New({ cls = 'WARRIOR', seed = 4, god = true, lab = true })
      r.labN = 60
      for _, id in ipairs({ 'charge', 'thunderclap', 'execute' }) do E.AddSpell(r, id) end
      local dashed, swung = false, false
      for _ = 1, 8 * 30 do
        E.Step(r, 1 / 30, 0, 0)
        if r.p.dash then dashed = true end
        if (r.p.atkT or 0) > 0 then swung = true end
      end
      local kills = r.kills
      r.legend.cleave, r.spells.cleave.r = true, 5
      local storm = false
      for _ = 1, 4 * 30 do E.Step(r, 1 / 30, 0, 0) for _, a in ipairs(r.arcs) do if a.storm then storm = true end end end
      return { dashed = dashed, swung = swung, kills = kills, storm = storm, start = r.order[1] }
    """)
    assert out["start"] == "cleave", out
    assert out["swung"] and out["dashed"], out
    assert out["kills"] > 10, out
    assert out["storm"], "Thunderfury never chained"
    no_errors(w)

@case
def talents_are_bought_with_banked_gold_and_carried_into_runs():
    w, c = boot()
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(0.5)
    c.eval("local d = ns.HTLGame.Data() d.bank = 1000 wipe(d.talents)")
    # a deeper tier is shut until enough points are spent in its tree
    assert c.eval_py("local ok, why = ns.HTLGame:CanBuy('area') return why") == "locked"
    for _ in range(4):
        assert c.eval_py("return ns.HTLGame:Buy('might')")
    assert c.eval_py("return ns.HTLGame.Data().bank") == 1000 - 4 * 40
    assert c.eval_py("return ns.HTLGame:Buy('area')"), "tier 2 should open after 4 points"
    assert c.eval_py("return ns.HTLGame:Buy('might')")
    assert c.eval_py("local ok, why = ns.HTLGame:CanBuy('might') return why") == "max"
    # the talents screen draws them
    c.eval("ns.HTLUI.ShowTalents()")
    w.tick(0.3)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "talents"
    no_errors(w)
    # a run carries a copy: Might of the Dawn 5/5 = +15% damage
    c.eval("ns.HTLUI.Start('PALADIN')")
    w.tick(0.3)
    assert c.eval_py("return ns.HTLUI._Run().tal.might") == 5
    assert abs(c.eval_py("return ns.HTLUI._Run().st.might") - 1.15) < 1e-6
    # its gold is banked when it ends; unlearning refunds every rank
    c.eval("local r = ns.HTLUI._Run() r.gold = 77 ns.HTLUI._ShowEnd('death')")
    bank = c.eval_py("return ns.HTLGame.Data().bank")
    assert bank == 1000 - 5 * 40 - 80 + 77, bank
    c.eval("ns.HTLGame:Reset()")
    assert c.eval_py("return ns.HTLGame.Data().bank") == 1077
    assert c.eval_py("return next(ns.HTLGame.Data().talents) == nil")
    # the title's demo and the lab never use them
    c.eval("local d = ns.HTLGame.Data() d.talents.might = 3 ns.HTLUI._ShowTitle()")
    w.tick(0.3)
    assert c.eval_py("return ns.HTLUI._Run().tal.might") is None
    no_errors(w)



@case
def a_run_earns_achievements_and_reaches_the_guild_board():
    w, c = boot()
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(0.5)
    out = c.eval_py(r"""
      local S, E = ns.HTLSocial, ns.HTL
      local r = E.New({ cls = 'PALADIN', seed = 3 })
      r.t, r.kills, r.level, r.over, r.gold = 905, 1200, 30, 'victory', 140
      r.legend.consecration = true r.slain.abom = true
      ns.HTLGame:Finished(r, true, 900)
      local d = S.Data()
      local me = ns.Util.PlayerKey()
      local e = d.weeks[S:Week()][me]
      -- a guildmate's result arrives on the wire
      S._handlers.HLR('Lidevna-' .. ns.Util.GetPlayerRealm(), { w = S:Week(), e = { b = { MAGE = { t = 861, k = 6980, l = 41 } }, g = 50, r = 3000, p = 40 } })
      local board = S:Board('time', 'week')
      -- someone else claims a first earlier than ours: theirs stands
      S._handlers.HLF('Victhar-' .. ns.Util.GetPlayerRealm(), { id = 'ash', ts = 1 })
      return { line = d.ach.line ~= nil, ash = d.ach.ash ~= nil, k1000 = d.ach.k1000 ~= nil, abom = d.ach.abom ~= nil, pale = d.ach.palefirst ~= nil,
               t = e and e.b.PALADIN.t, n = #board, top = board[1] and board[1].me, second = board[2] and board[2].name,
               first = ns.Util.ShortName(d.firsts.ash.who), toasts = #S.toasts, pts = (S:Points()) }
    """)
    assert out["line"] and out["ash"] and out["k1000"] and out["abom"] and out["pale"], out
    assert out["t"] == 905 and out["n"] == 2 and out["top"] and out["second"] == "Lidevna", out
    assert out["first"] == "Victhar", out
    assert out["toasts"] >= 5 and out["pts"] > 0, out
    # the screens draw it
    for show in ("ShowBoard", "ShowAch", "ShowDawn"):
        c.eval("ns.HTLUI.%s()" % show)
        w.tick(0.2)
    no_errors(w)

@case
def dev_scenarios_jump_to_a_moment_and_are_never_recorded():
    w, c = boot()
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(1.0)
    assert c.eval_py("return ns.HTLUI.IsDev()"), "the test tree is a development copy"
    assert c.eval_py("local l = ns.HTLUI.devTitleList return l ~= nil and l[1]:IsShown()"), "no Dev pill on the title"
    labels = c.eval_py("local t = {} for _, m in ipairs(ns.HTLUI.DevMoments('epl')) do t[#t + 1] = m.label end return t")
    assert "05:00  Unstoppable Abomination" in labels and labels[0] == "00:00  Start", labels
    before = c.eval_py("local d = ns.Games:GetData('holdtheline') return { d.runs, d.kills, d.bank, d.wins }")
    c.eval("ns.HTLUI.ShowDev()")
    assert c.eval_py("return ns.HTLUI._Overlay()") == "dev"
    # 5 s before the Abomination: the clock, the crowd and Auto's level, then she comes on time
    c.eval("ns.HTLUI.dev.level = 'auto' ns.HTLUI.DevStart('MAGE', 'epl', 300)")
    r = c.eval_py("local r = ns.HTLUI._Run() return { t = r.t, en = #r.en, level = r.level, dev = r.dev, bar = ns.HTLUI.devBar:IsShown() }")
    assert r["t"] == 295 and r["en"] > 100 and r["level"] == 18 and r["dev"] and r["bar"], r
    for _ in range(80):
        c.eval("ns.HTLUI._Tick(0.1) local r = ns.HTLUI._Run() r.wantLevelUp, r.pending, r.chest = nil, 0, nil")
    assert c.eval_py("local r = ns.HTLUI._Run() return r.boss and r.boss.type") == "abom"
    # a locked quarter opens for a dev run; dying in it records nothing
    c.eval("ns.HTLUI.DevStart('WARRIOR', 'construct', 600)")
    r = c.eval_py("local r = ns.HTLUI._Run() return { stage = r.stage, t = r.t, open = ns.HTLGame:StageOpen('construct') }")
    assert r["stage"] == "construct" and r["t"] == 595 and not r["open"], r
    c.eval("local r = ns.HTLUI._Run() r.god = false r.p.hp = 0 r.p.dead = true r.p.deadT = 0")
    for _ in range(40):
        c.eval("ns.HTLUI._Tick(0.1)")
    assert c.eval_py("return ns.HTLUI._Overlay()") == "end"
    after = c.eval_py("local d = ns.Games:GetData('holdtheline') return { d.runs, d.kills, d.bank, d.wins }")
    assert after == before, (before, after)
    no_errors(w)


@case
def the_late_game_paces_levels_and_a_full_build_turns_to_paragon():
    w, c = boot("MAGE")
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(1.0)
    r = c.eval_py(r"""
      local E, D = ns.HTL, ns.HTLData
      local r = E.New({ cls = 'MAGE', seed = 4, god = true, bot = true })
      r.level, r.xpNext, r.xp = 30, 200, 5000         -- (a pile of XP at level 30: D.PACE's gap between levels)
      local levels = {}
      for i = 1, 40 * 30 do
        local L = r.level
        E.Step(r, 1 / 30, 0, 0)
        r.wantLevelUp, r.chest = nil, nil
        if r.level > L then levels[#levels + 1] = r.t end
      end
      local gaps = {}
      for k = 2, #levels do gaps[#gaps + 1] = levels[k] - levels[k - 1] end
      local waiting = E.Waiting(r)
      -- a full build: four spells and four blessings at rank 5; waiting levels become Paragon, +1% damage each
      local f = E.New({ cls = 'MAGE', seed = 4, god = true })
      for _, id in ipairs({ 'frostbolt', 'arcane', 'nova', 'blizzard' }) do for _ = 1, 5 do E.AddSpell(f, id) end end
      for _, id in ipairs({ 'might', 'intellect', 'crusader', 'motw' }) do for _ = 1, 5 do E.AddPassive(f, id) end end
      local full = E.BuildFull(f)
      local m0 = f.st.might
      f.pending = 2
      E.Step(f, 1 / 30, 0, 0)
      f.xp = f.xpNext * 3
      ns.HTLRender.DrawHud(ns.HTLUI._View(), f)
      return { n = #levels, gmin = #gaps > 0 and math.min(unpack(gaps)) or -1, gap = E.PaceGap(30), waiting = waiting, full = full, paragon = f.paragon or 0,
        pending = f.pending, k = f.st.might / m0, choices = E.Choices(f, 3)[1].kind }
    """)
    no_errors(w)
    assert r["n"] >= 2 and r["gap"] > 5 and r["gmin"] >= r["gap"] - 0.1, r       # (one level at a time, the gap kept)
    assert r["waiting"] >= 5, r                        # (the rest waits on the bar)
    assert r["full"] and r["paragon"] == 2 and r["pending"] == 0, r
    assert abs(r["k"] - 1.02) < 1e-6 and r["choices"] == "gold", r


@case
def four_spell_and_four_blessing_slots():
    w, c = boot("PALADIN")
    r = c.eval_py(r"""
      local E, D = ns.HTL, ns.HTLData
      local r = E.New({ cls = 'PALADIN', seed = 2, god = true })
      for _, id in ipairs({ 'avenger', 'exorcism', 'grenade' }) do E.AddSpell(r, id) end
      for _, id in ipairs({ 'might', 'fortitude', 'cheetah', 'motw' }) do E.AddPassive(r, id) end
      local newSpell, newBless = 0, 0
      for _ = 1, 300 do
        for _, o in ipairs(E.Choices(r, 3)) do
          if o.kind == 'spell' and not r.spells[o.id] then newSpell = newSpell + 1 end
          if o.kind == 'passive' and not r.passives[o.id] then newBless = newBless + 1 end
        end
      end
      return { spells = #r.order, newSpell = newSpell, newBless = newBless, slots = D.SLOTS.spells .. '/' .. D.SLOTS.blessings }
    """)
    no_errors(w)
    assert r == {"spells": 4, "newSpell": 0, "newBless": 0, "slots": "4/4"}, r


@case
def every_path_and_legendary_casts_and_hurts():
    w, c = boot()
    r = c.eval_py(r"""
      local E, D, bad = ns.HTL, ns.HTLData, {}
      local seen = {}
      for _, id in ipairs(D.SPELL_ORDER) do
        for _, path in ipairs({ 'a', 'b' }) do
          for _, leg in ipairs({ false, true }) do
            local cls = D.SPELLS[id].cls or 'PALADIN'
            local r = E.New({ cls = cls, seed = 9, god = true, lab = true, noStart = true })
            r.labN = 40
            for _ = 1, 5 do E.AddSpell(r, id) end
            r.spells[id].path = path
            if leg then r.legend[id] = true end
            local kid, mini, fel = false, false, 0
            for _ = 1, 6 * 30 do
              E.Step(r, 1 / 30, 0, 0)
              for _, b in ipairs(r.proj) do kid, mini = kid or b.kid == true, mini or b.mini == true end
              local n = 0 for _, a in ipairs(r.areas) do if a.kind == 'felfire' then n = n + 1 end end
              fel = math.max(fel, n)
            end
            if r.kills == 0 then bad[#bad + 1] = id .. path .. (leg and 'L' or '') end
            if leg and id == 'avenger' then seen.absorb = (r.p.absorb or 0) > 0 end
            if leg and id == 'blizzard' then for _, a in ipairs(r.areas) do if a.endless then seen.storm = true end end end
            if leg and id == 'dragonling' then seen.whelps = r.spells.dragonling.wh and #r.spells.dragonling.wh end
            if path == 'a' and not leg and id == 'frostbolt' then seen.split = kid end
            if path == 'a' and not leg and id == 'grenade' then seen.cluster = mini end
            if leg and id == 'charge' then seen.fel = fel end
          end
        end
      end
      seen.bad = table.concat(bad, ',')
      return seen
    """)
    no_errors(w)
    assert r["bad"] == "", "no kills: " + r["bad"]
    assert r.get("absorb") and r.get("storm") and r.get("whelps") == 3, r
    assert r.get("split") and r.get("cluster") and r.get("fel", 0) >= 2, r


@case
def rank_three_is_a_path_chosen_on_its_own_screen():
    w, c = boot()
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(1.0)
    c.eval("ns.HTLUI.Start('PALADIN')")
    w.tick(0.5)
    c.eval("local r = ns.HTLUI._Run() ns.HTL.AddSpell(r, 'consecration') r.pending = 1")
    w.tick(1.5)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "level"
    c.eval("local r = ns.HTLUI._Run() r.lvlOpts[1] = { kind = 'spell', id = 'consecration', r = 3, fork = true }")
    c.eval("ns.HTLUI.TakeLevel(1)")
    w.tick(1.0)
    no_errors(w)
    r = c.eval_py("local r = ns.HTLUI._Run() return { ov = ns.HTLUI._Overlay(), n = #r.lvlOpts, k = r.lvlOpts[1].kind, rank = r.spells.consecration.r }")
    assert r == {"ov": "level", "n": 2, "k": "path", "rank": 2}, r
    c.eval("ns.HTLUI.TakeLevel(3)")                     # (two cards: key 3 does nothing)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "level"
    c.eval("ns.HTLUI.TakeLevel(2)")
    w.tick(1.5)
    no_errors(w)
    r = c.eval_py("local r = ns.HTLUI._Run() local s = r.spells.consecration return { ov = ns.HTLUI._Overlay() or 'none', r = s.r, path = s.path }")
    assert r == {"ov": "none", "r": 3, "path": "b"}, r


@case
def a_new_legendary_is_revealed_by_name_and_taken():
    w, c = boot()
    c.eval("ns.Games:Open('holdtheline')")
    w.tick(1.0)
    c.eval("ns.HTLUI.Start('PALADIN')")
    w.tick(0.3)
    c.eval(r"""
      local r = ns.HTLUI._Run()
      for _ = 1, 5 do ns.HTL.AddSpell(r, 'avenger') end
      ns.HTL.AddPassive(r, 'fortitude')
      ns.HTL.OpenChest(r, true)
    """)
    w.tick(2.0)
    no_errors(w)
    assert c.eval_py("return ns.HTLUI._Overlay()") == "legend"
    c.eval("ns.HTLUI.TakeLegend()")
    w.tick(0.5)
    assert c.eval_py("return ns.HTLUI._Run().legend.avenger == true")
    no_errors(w)


@case
def the_plaguelands_start_with_a_trickle_and_small_encounters_come_between_events():
    w, c = boot("MAGE")
    r = c.eval_py(r"""
      local E, D = ns.HTL, ns.HTLData
      local r = E.New({ cls = 'MAGE', seed = 5, god = true, bot = true })
      r.ff = true
      local msgs, enc, at15, at200, last = {}, {}, nil, nil, nil
      for _, en in pairs(E.ENCOUNTERS) do msgs[en.msg] = true end
      for i = 1, 600 * 30 do
        E.Step(r, 1 / 30, 0, 0)
        r.wantLevelUp, r.chest = nil, nil
        local n = 0 for _, e in ipairs(r.en) do if not e.dead then n = n + 1 end end
        if not at15 and r.t >= 15 then at15 = n end
        if not at200 and r.t >= 200 then at200 = n end
        if r.warn and r.warn.msg ~= last then last = r.warn.msg if msgs[last] then enc[#enc + 1] = math.floor(r.t) end end
      end
      local near = 0      -- (none from 25 s before a clock event to 15 s after it)
      for _, t in ipairs(enc) do for _, ev in ipairs(D.EVENTS) do if t > ev.t - 25 and t < ev.t + 15 then near = near + 1 end end end
      return { at15 = at15, at200 = at200, n = #enc, first = enc[1] or -1, near = near }
    """)
    no_errors(w)
    assert r["at15"] <= 16 and r["at200"] >= 100, r       # (a trickle, then the full crowd by 2:00)
    assert r["n"] >= 4 and 0 < r["first"] <= 70 and r["near"] == 0, r


@case
def every_small_encounter_plays_and_a_caught_courier_spills_its_satchel():
    w, c = boot()
    r = c.eval_py(r"""
      local E = ns.HTL
      local out = {}
      local function fresh(t)
        local r = E.New({ cls = 'PALADIN', seed = 3, god = true })
        r.calm, r.t, r.evI, r.encT = true, t, 99, nil     -- (no crowd, clock events or own encounters)
        E.Use(r)
        return r
      end
      for _, id in ipairs({ 'courier', 'bones', 'rats', 'hounds', 'packleader' }) do
        local r = fresh(200)
        E.ENCOUNTERS[id].run(r)
        for _ = 1, 3 * 30 do E.Step(r, 1 / 30, 0, 0) r.wantLevelUp = nil end
        local n = 0 for _, e in ipairs(r.en) do if not e.dead then n = n + 1 end end
        out[id] = n
      end
      local function gold(r) local g = 0 for _, k in ipairs(r.pick) do if k.kind == 'gold' then g = g + 1 end end return g end
      local r = fresh(100)
      E.ENCOUNTERS.courier.run(r)
      E.Kill(r, r.courier)
      E.Step(r, 1 / 30, 0, 0)
      out.caughtGold, out.caughtGems, out.caughtGone = gold(r), #r.gems, r.courier == nil
      r = fresh(100)
      E.ENCOUNTERS.courier.run(r)
      for _ = 1, 20 * 30 do E.Step(r, 1 / 30, 0, 0) r.wantLevelUp = nil end
      out.fledGold, out.fledGone = gold(r), r.courier == nil
      return out
    """)
    no_errors(w)
    assert r["courier"] == 1 and r["bones"] >= 6 and r["rats"] >= 18 and r["hounds"] >= 4 and r["packleader"] >= 4, r
    assert r["caughtGold"] >= 1 and r["caughtGems"] >= 8 and r["caughtGone"], r
    assert r["fledGold"] == 0 and r["fledGone"], r


if __name__ == "__main__":
    run_all(globals())

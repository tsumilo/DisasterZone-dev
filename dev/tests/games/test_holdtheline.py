r"""Hold the Line (Games/HoldTheLine/): the run, the spells, the overlays, the panel.

Covers: a seeded run is the same twice; the clock's events (the ring, the Abomination at 5:00, the Lich at 10:00, the
Pale Rider at 15:00 ending the run as a win); every spell of both classes casts and hurts (and the Ashbringer purges);
level-ups open the picker with three cards whose previews run, a pick adds the spell / blessing and the icon flies to
the bar; a coffer from an elite opens and its legendary can be taken; a bot plays 15 minutes with god mode to the
end without an error; the panel: title, class pick, keys move, Esc pauses, the spell lab (and leaving it); talents bought with banked
gold, carried into runs, refunded.

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

if __name__ == "__main__":
    run_all(globals())

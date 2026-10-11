#!/usr/bin/env python
"""The paladin buff bar (UI/BlessingsBar.lua) updates in full only when something changed. Seen in game 2026-10-11: it
rebuilt every row once a second (891 KB of garbage a minute). Now a look once a second that makes no tables
(NeedsUpdate) finds what changed, and only then the bar updates in full: a blessing given, refreshed or gone, someone
offline or dead, a class running short, the next class's chip a minute on, the Greater's target out of range, a pet
(an event). Between updates the slate theme's time bars still drain, and in a fight the rows show their class as it
is now while their casts stay as they were (WoW forbids changing them).

Run: luaenv\\Scripts\\python.exe tests\\blessings\\test_blessings_bar_idle.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

from harness import World, Client  # noqa: E402
from _common import case, run_all  # noqa: E402

COMMON = [27142, 27143, 27140, 27141, 1038, 25895, 27144, 27145, 27149, 27150, 19746, 27151, 27152, 27153]

SETUP = """
    local B, Bar = ns.Blessings, ns.BlessingsBar
    local CI = B.CLASS_INDEX
    B:SetAssign('Gina', CI.WARRIOR, 2)      -- Might
    B:SetAssign('Gina', CI.PRIEST, 1)       -- Wisdom
    B:SetAssign('Gina', CI.MAGE, 1)
    __MOCK.unit_auras = {}
    _G.__FULL = 0
    local f = Bar.MyRows
    Bar.MyRows = function(...) _G.__FULL = _G.__FULL + 1 return f(...) end
    -- a Greater on name, `left` seconds to go (nil: none)
    _G.__give = function(name, bi, left)
        if not left then __MOCK.unit_auras[name] = nil return end
        local id = B.D.BLESSINGS[bi].granks[1][1]
        __MOCK.unit_auras[name] = { { 'Greater', id, 900, GetTime() + left } }
    end
    -- the shown row of a class (its frame)
    _G.__row = function(cls)
        for i = 1, 20 do
            local r = _G['DisasterZoneBlessRow' .. i]
            if r and r:IsShown() and r.data and r.data.cls == cls then return r end
        end
    end
    _G.__unit = function(name)
        for _, m in ipairs(B:Roster()) do if m.name == name then return m.unit end end
    end
"""


def world():
    w = World()
    gina = Client(w, "Gina", class_file="PALADIN", guild_rank=2, talents=(41, 20, 0))
    vic = Client(w, "Victhar", class_file="WARRIOR", guild_rank=3)
    for c in w.clients:
        c.load_addon()
    gina.eval("local ids = ...; for _, id in ipairs(ids) do __MOCK.known_spells[id] = true end; ns.Blessings:ScanSelf()",
              COMMON)
    w.make_raid([gina, vic], leader=gina,
                extra_members=[{"name": "Brakka", "class_file": "WARRIOR"}, {"name": "Isolde", "class_file": "PRIEST"},
                               {"name": "Embera", "class_file": "MAGE"}])
    w.tick(10)
    gina.eval(SETUP)
    w.tick(2)
    assert gina.eval("return DisasterZoneBlessBar ~= nil and DisasterZoneBlessBar:IsShown()") is True
    return w, gina


def everyone(gina, left=900):
    gina.eval("local left = ... for _, n in ipairs({ 'Victhar', 'Brakka' }) do __give(n, 2, left) end "
              "for _, n in ipairs({ 'Isolde', 'Embera' }) do __give(n, 1, left) end", left)


def full(gina):
    return gina.eval("return _G.__FULL")


def missing(gina, cls):
    return gina.eval("return #__row(...).data.state.missing", cls)


@case
def nothing_changes_no_full_update_and_no_garbage():
    w, gina = world()
    everyone(gina)
    w.tick(3)
    n0 = full(gina)
    w.tick(20)
    assert full(gina) == n0, (n0, full(gina))
    kb = gina.eval_py("""
        local Bar = ns.BlessingsBar
        local function per(f, n)
            collectgarbage('collect') collectgarbage('stop')
            local a = collectgarbage('count')
            for i = 1, n do f() end
            local b = collectgarbage('count')
            collectgarbage('restart')
            return (b - a) / n
        end
        return { tick = per(function() Bar:Tick() end, 200), update = per(function() Bar:Update() end, 20) }
    """)
    print("KB per second: idle look %.3f, full update %.2f" % (kb["tick"], kb["update"]))
    assert kb["tick"] < 0.05, kb
    assert full(gina) == n0 + 20       # (only the 20 Updates called above)
    w.assert_no_errors()


@case
def a_blessing_given_refreshed_or_gone_shows_within_a_second():
    w, gina = world()
    everyone(gina)
    gina.eval("__give('Brakka', 2, nil)")
    w.tick(2)
    assert missing(gina, "WARRIOR") == 1
    n0 = full(gina)
    gina.eval("__give('Brakka', 2, 1000)")
    w.tick(1.1)
    assert missing(gina, "WARRIOR") == 0 and full(gina) == n0 + 1, (missing(gina, "WARRIOR"), full(gina), n0)
    # recast: the same blessing, a fresh timer (the ring starts again)
    gina.eval("__give('Brakka', 2, 1800)")
    w.tick(1.1)
    assert full(gina) == n0 + 2
    gina.eval("__give('Brakka', 2, nil)")
    w.tick(1.1)
    assert missing(gina, "WARRIOR") == 1 and full(gina) == n0 + 3
    w.assert_no_errors()


@case
def offline_or_dead_shows_within_a_second():
    w, gina = world()
    everyone(gina)
    gina.eval("__give('Isolde', 1, nil); __give('Embera', 1, nil)")
    w.tick(2)
    assert missing(gina, "PRIEST") == 1 and missing(gina, "MAGE") == 1
    w.set_dead("Isolde")
    w.tick(1.1)
    assert missing(gina, "PRIEST") == 0, "the dead count as having it"
    m = w._member("Embera")
    m.online = False
    w._sync()
    w.tick(1.1)
    assert missing(gina, "MAGE") == 0, "so do the offline"
    w.set_dead("Isolde", False)
    w.tick(1.1)
    assert missing(gina, "PRIEST") == 1
    w.assert_no_errors()


@case
def running_short_and_the_chip_follow_the_clock():
    w, gina = world()
    everyone(gina)
    gina.eval("__give('Embera', 1, 303)")          # warn: 5 minutes
    w.tick(1.5)
    assert gina.eval("return __row('MAGE').data.short") is False
    w.tick(3)
    assert gina.eval("return __row('MAGE').data.short") is True
    # the mages are next (nobody missing): the chip says when it runs out, a minute at a time
    assert gina.eval("return __row('MAGE').face.label.text:GetText()") == "4m"
    n0 = full(gina)
    w.tick(30)
    assert gina.eval("return __row('MAGE').face.label.text:GetText()") == "4m"
    w.tick(32)
    assert gina.eval("return __row('MAGE').face.label.text:GetText()") == "3m"
    assert full(gina) - n0 <= 2, full(gina) - n0
    w.assert_no_errors()


@case
def the_greater_goes_to_someone_in_range():
    w, gina = world()
    everyone(gina)
    gina.eval("__give('Victhar', 2, 600); __give('Brakka', 2, 700)")
    gina.eval("_G.__far = {} IsSpellInRange = function(spell, unit) return __far[unit] and 0 or 1 end")
    w.tick(2)
    vu, bu = gina.eval_py("return { __unit('Victhar'), __unit('Brakka') }")
    assert vu and bu, (vu, bu)
    assert gina.eval("return __row('WARRIOR').data.unit") == vu, "the one running lowest"
    assert gina.eval("return __row('WARRIOR'):GetAttribute('unit1')") == vu
    gina.eval("__far[...] = true", vu)
    w.tick(1.1)
    assert gina.eval("return __row('WARRIOR').data.unit") == bu
    assert gina.eval("return __row('WARRIOR'):GetAttribute('unit1')") == bu
    gina.eval("__far[...] = true", bu)
    w.tick(1.1)
    assert gina.eval("return __row('WARRIOR').data.unit") is None, "nobody in range: the row dims"
    gina.eval("IsSpellInRange = nil")
    w.assert_no_errors()


@case
def in_a_fight_the_rows_show_now_and_keep_their_casts():
    w, gina = world()
    everyone(gina)
    w.tick(2)
    cast = gina.eval("local r = __row('WARRIOR') return r:GetAttribute('spell1'), r:GetAttribute('unit1')")
    gina.set_combat(True)
    w.tick(0.5)
    gina.eval("__give('Brakka', 2, nil)")
    w.tick(1.1)
    assert missing(gina, "WARRIOR") == 1, "the missing count shows in a fight"
    assert gina.eval("local r = __row('WARRIOR') return r:GetAttribute('spell1'), r:GetAttribute('unit1')") == cast
    gina.set_combat(False)
    w.tick(1.1)
    assert missing(gina, "WARRIOR") == 1
    w.assert_no_errors()


@case
def a_pet_or_a_name_updates_in_full():
    w, gina = world()
    everyone(gina)
    w.tick(2)
    n0 = full(gina)
    gina.fire("UNIT_PET", "target")              # (not the group's)
    w.tick(1.1)
    assert full(gina) == n0
    gina.fire("UNIT_PET", "raid2")
    w.tick(1.1)
    assert full(gina) == n0 + 1
    gina.fire("UNIT_NAME_UPDATE", "raidpet2")
    w.tick(1.1)
    assert full(gina) == n0 + 2
    w.assert_no_errors()


@case
def the_slate_bars_drain_between_updates():
    w, gina = world()
    everyone(gina, 1000)
    gina.eval("ns.DB:SetSetting('classbar.theme', 'slate')")
    w.tick(2)
    n0 = full(gina)
    w1 = gina.eval("return __row('PRIEST').face.barFill:GetWidth()")
    w.tick(60)
    w2 = gina.eval("return __row('PRIEST').face.barFill:GetWidth()")
    assert w2 < w1, (w1, w2)
    assert full(gina) == n0, "drained without a full update"
    gina.eval("ns.DB:SetSetting('classbar.theme', 'halo')")
    w.assert_no_errors()


@case
def demo_mode_bar_still_runs():
    w, gina = world()
    gina.slash("/dz demo on")
    w.tick(3)
    assert gina.eval("return DisasterZoneBlessBar:IsShown()") is True
    w.tick(5)
    gina.slash("/dz demo off")
    w.tick(2)
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

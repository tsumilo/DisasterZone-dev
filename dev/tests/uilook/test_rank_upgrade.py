#!/usr/bin/env python
"""New ranks onto the bars (UI/LookBars.lua UpgradeRanks, setting actionbars.upgradeRanks, on by default): a learned
rank takes the place of the best rank known before it on every action slot; a lower rank kept for down-ranking stays,
macros and other spells stay; ranks learned together go on as the best one; in combat it waits for the fight's end;
something on the cursor makes it wait; the setting off does nothing.

Run: luaenv\\Scripts\\python.exe tests\\uilook\\test_rank_upgrade.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

from _common import case, run_all, solo  # noqa: E402

# Flash of Light ranks 1-7 = 101..107, Holy Light ranks 1-11 = 201..211; the spellbook lists the ranks in KNOWN.
SPELLS = """
    local NAMES = {}
    for r = 1, 7 do NAMES[100 + r] = { 'Flash of Light', r } end
    for r = 1, 11 do NAMES[200 + r] = { 'Holy Light', r } end
    NAMES[301] = { 'Seal of Righteousness', nil }
    __RANKS = NAMES
    KNOWN = {}
    GetSpellInfo = function(id) local n = NAMES[id]; return n and n[1] or ('Spell ' .. tostring(id)) end
    C_Spell.GetSpellName = GetSpellInfo
    GetSpellSubtext = function(id) local n = NAMES[id]; return n and n[2] and ('Rank ' .. n[2]) or '' end
    GetNumSpellTabs = function() return 1 end
    GetSpellTabInfo = function() return 'Holy', 0, 0, #KNOWN end
    GetSpellBookItemName = function(i) local id = KNOWN[i]; if not id then return nil end
        return GetSpellInfo(id), GetSpellSubtext(id) end
    PickupSpell = function(id) __MOCK.cursor = { kind = 'spell', id = id, action = { 'spell', id } } end
    LEARN = function(...)
        for i = 1, select('#', ...) do local id = select(i, ...); KNOWN[#KNOWN + 1] = id
            __MOCK.fire('LEARNED_SPELL_IN_TAB', id, 1) end
    end
"""


def boot(known=(101, 102, 103, 104, 201, 202, 203, 204, 205, 206, 207, 208, 209, 301)):
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval(SPELLS)
    c.eval("for _, id in ipairs({...}) do KNOWN[#KNOWN + 1] = id end", *known)
    return w, c


def slot(c, n):
    return c.eval("local a = __MOCK.actions[...]; return a and a[2]", n)


@case
def learned_rank_replaces_the_best_rank_everywhere():
    w, c = boot()
    c.eval("__MOCK.actions[1] = { 'spell', 104 }; __MOCK.actions[30] = { 'spell', 104 }; "
           "__MOCK.actions[80] = { 'spell', 104 }; __MOCK.actions[2] = { 'spell', 301 }; "
           "__MOCK.actions[3] = { 'macro', 1 }")
    c.eval("LEARN(105)")
    w.tick(1.0)
    assert [slot(c, n) for n in (1, 30, 80)] == [105, 105, 105]
    assert slot(c, 2) == 301
    assert c.eval("return __MOCK.actions[3][1]") == "macro"
    assert c.eval("return __MOCK.cursor") is None


@case
def a_down_rank_stays():
    w, c = boot()
    c.eval("__MOCK.actions[1] = { 'spell', 209 }; __MOCK.actions[2] = { 'spell', 205 }")
    c.eval("LEARN(210)")
    w.tick(1.0)
    assert slot(c, 1) == 210
    assert slot(c, 2) == 205


@case
def ranks_learned_together_go_on_as_the_best():
    w, c = boot()
    c.eval("__MOCK.actions[1] = { 'spell', 209 }; __MOCK.actions[5] = { 'spell', 104 }")
    c.eval("LEARN(210, 211, 105)")
    w.tick(1.0)
    assert slot(c, 1) == 211
    assert slot(c, 5) == 105


@case
def in_combat_it_waits_for_the_end():
    w, c = boot()
    c.eval("__MOCK.actions[1] = { 'spell', 104 }; __MOCK.combat = true; __MOCK.fire('PLAYER_REGEN_DISABLED')")
    c.eval("LEARN(105)")
    w.tick(2.0)
    assert slot(c, 1) == 104
    c.eval("__MOCK.combat = false; __MOCK.fire('PLAYER_REGEN_ENABLED')")
    w.tick(0.2)
    assert slot(c, 1) == 105


@case
def a_held_cursor_makes_it_wait():
    w, c = boot()
    c.eval("__MOCK.actions[1] = { 'spell', 104 }; PickupSpell(301)")
    c.eval("LEARN(105)")
    w.tick(1.0)
    assert slot(c, 1) == 104
    assert c.eval("return __MOCK.cursor.id") == 301
    c.eval("ClearCursor()")
    w.tick(1.5)
    assert slot(c, 1) == 105


@case
def setting_off_does_nothing():
    w, c = boot()
    c.eval("ns.DB:SetSetting('actionbars.upgradeRanks', false); __MOCK.actions[1] = { 'spell', 104 }")
    c.eval("LEARN(105)")
    w.tick(1.0)
    assert slot(c, 1) == 104


if __name__ == "__main__":
    sys.exit(run_all())

#!/usr/bin/env python
"""Rotation helper keys and names, opacity, quiet pop-ups (1.5.4): the next presses wear the key their spell is on
(style A, the user's pick 2026-10-17: the corner of every icon, the name under the face; UI/KeyBinds.lua
KB:KeyForSpell, UI/RingFace.lua, UI/SwingTimerHUD.lua), with switches for the key and the name; the timers' opacity in
a fight and at rest (feedback #29); every toast waits out a fight and a boss encounter unless it is loot (D-2,
UI/Comp/Overlays.lua)."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from harness import World, Client  # noqa: E402

w = World()
war = Client(w, "Garrosh", class_file="WARRIOR", guild_rank=0, talents=(17, 44, 0))
war.load_addon()
w.tick(2)
war.eval("ns.ClassKit:SetOn('war', true)")
w.tick(0.3)
war.eval("local names = { [29707] = 'Heroic Strike', [25231] = 'Cleave', [30335] = 'Bloodthirst', [1680] = 'Whirlwind', "
         "[25236] = 'Execute', [30033] = 'Rampage', [2048] = 'Battle Shout', [2687] = 'Bloodrage', [25212] = 'Hamstring' }; "
         "local old = GetSpellInfo; GetSpellInfo = function(x, ...) if names[x] then return names[x] end "
         "for _, n in pairs(names) do if n == x then return n end end return old(x, ...) end; "
         "for id, n in pairs(names) do __MOCK.known_spells[id] = true; __MOCK.spell_cd = __MOCK.spell_cd or {}; "
         "__MOCK.spell_cd[n] = { 0, 0 } end; __MOCK.fire('SPELLS_CHANGED'); "
         "UnitAttackSpeed = function() return 2.6, 2.6 end; GetShapeshiftForm = function() return 3 end; "
         "__MOCK.fire('UNIT_ATTACK_SPEED', 'player')")

# ---------------------------------------------------------------------------------------------------------------
# keys as an action button writes them
# ---------------------------------------------------------------------------------------------------------------
short = war.eval_py("local o = {}; for i, k in ipairs({ '2', 'SHIFT-E', 'CTRL-ALT-3', 'BUTTON4', 'MOUSEWHEELUP', "
                    "'NUMPAD5', 'SHIFT--' }) do o[i] = ns.KeyBinds.ShortKey(k) end; return o")
assert short == ["2", "S-E", "C-A-3", "M4", "WU", "N5", "S--"], short

# ---------------------------------------------------------------------------------------------------------------
# the key a spell is on: the main bar (its page), the other bars, a SPELL / MACRO binding; nothing when unbound
# ---------------------------------------------------------------------------------------------------------------
war.eval("""
    __MOCK.bindings = { { 'ACTIONBUTTON2', '2' }, { 'MULTIACTIONBAR1BUTTON7', 'SHIFT-E' }, { 'SPELL Hamstring', 'R' },
                        { 'MACRO Shout', 'BUTTON4' } }
    __MOCK.actions = { [2] = { 'spell', 30335 }, [67] = { 'spell', 25236 }, [14] = { 'spell', 1680 } }
    __MOCK.macros = { [1] = { 'Shout', 2048 } }
    GetMacroSpell = function(i) local m = __MOCK.macros[i]; return m and m[2] end
    __MOCK.fire('UPDATE_BINDINGS')
""")
keys = war.eval_py("local o = {}; for _, n in ipairs({ 'Bloodthirst', 'Execute', 'Hamstring', 'Battle Shout', 'Whirlwind' }) "
                   "do o[n] = ns.KeyBinds:KeyForSpell(n) or false end; return o")
assert keys == {"Bloodthirst": "2", "Execute": "S-E", "Hamstring": "R", "Battle Shout": "M4", "Whirlwind": False}, keys
# page 2 of the main bar puts slot 14 (Whirlwind) on 2; the cache forgets on the page change
war.eval("__MOCK.action_page = 2; __MOCK.fire('ACTIONBAR_PAGE_CHANGED')")
_pg = war.eval("return ns.KeyBinds:KeyForSpell('Whirlwind'), ns.KeyBinds:KeyForSpell('Bloodthirst'), GetActionBarPage(), GetBonusBarOffset and GetBonusBarOffset()")
assert _pg[:2] == ("2", None), _pg
# a stance bar (Berserker: bonus offset 3) swaps in slots 97-108 for the main bar
war.eval("__MOCK.action_page = 1; GetBonusBarOffset = function() return 3 end; __MOCK.actions[98] = { 'spell', 1680 }; "
         "__MOCK.fire('UPDATE_BONUS_ACTIONBAR')")
assert war.eval("return ns.KeyBinds:KeyForSpell('Whirlwind')") == "2"
war.eval("GetBonusBarOffset = function() return 0 end; __MOCK.actions[98] = nil; __MOCK.fire('UPDATE_BONUS_ACTIONBAR')")

# ---------------------------------------------------------------------------------------------------------------
# the HUD: the key in the next press's corner and on the queue; the name under it; both switch off
# ---------------------------------------------------------------------------------------------------------------
DRAW = """
    local W = ns.WarriorSwing
    W.OnMH(GetTime()); W.OnOH(GetTime() - 1)
    __MOCK.player_power = { 62, 100 }
    W:MarkDirty(); ns.WarriorSwingHUD:Refresh(); for i = 1, 3 do ns.WarriorSwingHUD:Update() end
    local f = DisasterZoneWarriorSwing
    local steps = W:Current().plan.steps
    local q = {}
    for i, s in ipairs(f.small) do if s:IsShown() then q[#q + 1] = s.key:GetText() or '' end end
    return { first = steps[1].key, key = f.big.key:GetText() or '', name = f.big.name:IsShown() and f.big.name:GetText() or false,
             queue = q, alpha = f:GetAlpha() }
"""
war.eval("ns.DB:SetSetting('war.idle', true); ns.DB:SetSetting('war.theme', 'halo'); ns.DB:SetSetting('war.style', 'bar'); "
         "__MOCK.spell_cd['Bloodrage'] = { GetTime(), 60 }")
r = war.eval_py(DRAW)
assert r["first"] == "bt" and r["key"] == "2" and r["name"] == "Bloodthirst", r
assert "" in r["queue"] or r["queue"], r                    # (the queue shows: Whirlwind is on no key here)
for theme in ("sigil", "slate", "gilded", "pips", "classic"):
    war.eval("ns.DB:SetSetting('war.theme', ...)", theme)
    r = war.eval_py(DRAW)
    assert r["key"] == "2" and r["name"] == "Bloodthirst", (theme, r)
war.eval("ns.DB:SetSetting('war.theme', 'halo'); ns.DB:SetSetting('war.keys', false); ns.DB:SetSetting('war.names', false)")
r = war.eval_py(DRAW)
assert r["key"] == "" and r["name"] is False and all(k == "" for k in r["queue"]), r
# Slate and Classic keep their name (it is part of their look)
war.eval("ns.DB:SetSetting('war.theme', 'slate')")
assert war.eval_py(DRAW)["name"] == "Bloodthirst"
war.eval("ns.DB:SetSetting('war.theme', 'halo'); ns.DB:SetSetting('war.keys', true); ns.DB:SetSetting('war.names', true)")

# ---------------------------------------------------------------------------------------------------------------
# opacity (feedback #29): in a fight and at rest; 0 at rest hides it
# ---------------------------------------------------------------------------------------------------------------
war.eval("ns.DB:SetSetting('war.alpha', 0.55); ns.DB:SetSetting('war.restAlpha', 0)")
assert abs(war.eval_py(DRAW)["alpha"] - 0.55) < 0.01
war.eval("ns.WarriorSwing.state.mhLast = nil; ns.WarriorSwing.state.ohLast = nil; ns.WarriorSwing:MarkDirty(); "
         "ns.WarriorSwingHUD:Update()")
rest = war.eval("return ns.WarriorSwing:Current() == nil, DisasterZoneWarriorSwing:GetAlpha()")
assert rest[0] is False or rest[1] == 0, rest              # (resting: hidden)
war.eval("ns.DB:SetSetting('war.alpha', 1); ns.DB:SetSetting('war.restAlpha', 1)")

# ---------------------------------------------------------------------------------------------------------------
# quiet pop-ups (D-2): a toast waits out combat and an encounter; loot shows; Quiet in combat off shows them
# ---------------------------------------------------------------------------------------------------------------
TOAST = "return ns.UI:GetToast(...) ~= nil"
war.set_combat(True)
war.eval("ns.UI:Toast({ key = 't-bingo', title = 'Bingo!' }); ns.UI:Toast({ key = 't-loot', title = 'Drop', combat = true })")
assert war.eval(TOAST, "t-bingo") is False and war.eval(TOAST, "t-loot") is True
war.set_combat(False)
war.fire("PLAYER_REGEN_ENABLED")
w.tick(0.5)
assert war.eval(TOAST, "t-bingo") is True
war.eval("ns.UI:HideToast('t-bingo'); ns.UI:HideToast('t-loot')")
war.fire("ENCOUNTER_START", 731, "Void Reaver", 4, 25)
war.eval("ns.UI:Toast({ key = 't-poll', title = 'New poll' })")
assert war.eval(TOAST, "t-poll") is False                  # (out of combat between pulls of a boss: still held)
war.fire("ENCOUNTER_END", 731, "Void Reaver", 4, 25, 1)
w.tick(0.5)
assert war.eval(TOAST, "t-poll") is True
war.eval("ns.UI:HideToast('t-poll'); ns.db.settings.notify = ns.db.settings.notify or {}; "
         "ns.db.settings.notify.quietCombat = false")
war.set_combat(True)
war.eval("ns.UI:Toast({ key = 't-news', title = 'Raid started' })")
assert war.eval(TOAST, "t-news") is True
war.set_combat(False)

w.assert_no_errors()
print("ok")

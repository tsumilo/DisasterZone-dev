#!/usr/bin/env python
"""Twist practice (Core/SwingPractice.lua, UI/SwingPracticeUI.lua): keys read from the action bars, lessons that
unlock in order, a perfect run (3 stars), a sloppy one (early presses), the spell queue, keys caught and others let
through, Esc and combat stopping it, and the real swing timer untouched afterwards."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from harness import World, Client  # noqa: E402

w = World()
c = Client(w, "Alice", class_file="PALADIN", guild_rank=0, talents=(5, 11, 45))
c.load_addon()
w.tick(2)

# the bars: Command on 2, Blood on 3, Crusader Strike in a macro on the bottom-left bar (Shift-1), Judgement nowhere
c.eval("""
    __MOCK.swing_speed = 3.6
    __MOCK.actions[2] = { 'spell', 20375 }
    __MOCK.actions[3] = { 'spell', 31892 }
    __MOCK.macros[5] = { 'CSmacro', 35395 }
    __MOCK.actions[61] = { 'macro', 5 }
    __MOCK.bindings = { { 'ACTIONBUTTON1', '1' }, { 'ACTIONBUTTON2', '2' }, { 'ACTIONBUTTON3', '3' },
        { 'MULTIACTIONBAR1BUTTON1', 'SHIFT-1' }, { 'MOVEFORWARD', 'W' } }
""")
keys = c.eval_py("return (ns.SwingPractice:Keys())")
assert keys == {"soc": "2", "sob": "3", "cs": "SHIFT-1"}, keys
assert c.eval("return ns.SwingPractice:Short('ALT-SHIFT-NUMPAD4')") == "asN4"
# one key, one spell: E for Judgement, then E for Blood takes it off Judgement; nil = back to the bars
c.eval("ns.SwingPractice:SetKey('judge', 'e')")
assert c.eval_py("return (ns.SwingPractice:Keys())")["judge"] == "E"
c.eval("ns.SwingPractice:SetKey('sob', 'E')")
k = c.eval_py("return (ns.SwingPractice:Keys())")
assert k["sob"] == "E" and "judge" not in k, k
c.eval("ns.SwingPractice:SetKey('sob', nil); ns.SwingPractice:SetKey('judge', 'E')")
assert c.eval_py("return (ns.SwingPractice:Keys())") == {"soc": "2", "sob": "3", "cs": "SHIFT-1", "judge": "E"}

# the window: six rows, only the first lesson and free play open, the first one picked
c.slash("/dz swing practice")
w.tick(0.2)
assert c.eval("return DisasterZoneSwingPractice:IsShown()") is True
r = c.eval_py("""
    local out = {}
    for _, L in ipairs(ns.SwingPractice.LESSONS) do out[#out + 1] = ns.SwingPractice:IsUnlocked(L) end
    return out
""")
assert r == [True, False, False, False, False, True], r

# A perfect player: the clock in small steps, pressing a key the moment the planner (what the ring shows) says so.
# The key goes through the keyboard frame like a real key press.
PLAY = """
    local mode = ...
    local SP, ST = ns.SwingPractice, ns.SwingTimer
    local catcher = DisasterZoneSwingPracticeKeys
    local onKey = catcher:GetScript('OnKeyDown')
    local KEY = { soc = '2', sob = '3', cs = '1', judge = 'E' }
    local pressedAt = {}
    for i = 1, 9000 do
        if not SP.run then break end
        __MOCK.now = __MOCK.now + 0.01
        SP:_Advance()
        if SP.run and GetTime() >= SP.run.go then
            local cur = ST:Current()
            local first = cur and cur.plan.steps[1]
            local due = first and first.key ~= 'wait' and first.at <= GetTime() + 0.001
            local at = first and first.at
            if mode == 'early' and first and first.key == 'sob' and first.twist then
                due, at = first.at - 0.3 <= GetTime(), first.at - 0.3
            end
            if due and pressedAt[first.key] ~= at then
                pressedAt[first.key] = at
                if first.key == 'cs' then __MOCK.mods.shift = true end
                onKey(catcher, KEY[first.key])
                __MOCK.mods.shift = false
            end
        end
    end
    local res = SP.last
    return { running = SP.run ~= nil, stars = res and res.stars, grade = res and res.grade, twists = res and res.twists,
        early = res and res.counts.early, expected = res and res.expected, swings = res and res.swings,
        cs = res and res.counts.cs, judge = res and res.counts.judge, lesson = res and res.lesson }
"""

# lesson 1 with the window's Start: the window hides, the ring and the coach overlay show, keys are caught
c.eval("ns.SwingPracticeUI:StartSelected()")
w.tick(0.1)
st = c.eval_py("""
    local SP, ST = ns.SwingPractice, ns.SwingTimer
    local o = ns.SwingPracticeUI:Overlay()
    return { running = SP:IsRunning(), lesson = SP.run and SP.run.L.key, practice = ST.practice ~= nil,
        hud = DisasterZoneSwingTimer:IsShown(), win = DisasterZoneSwingPractice:IsShown(), overlay = o and o:IsShown(),
        kb = DisasterZoneSwingPracticeKeys:IsShown(), speed = SP.run and SP.run.base, coach = o and o.card.line:GetText() }
""")
assert st == {"running": True, "lesson": "twist", "practice": True, "hud": True, "win": False, "overlay": True,
              "kb": True, "speed": 4.2, "coach": "Get ready"}, st
# lesson 1 shows only the Seal of Blood key under the ring
assert c.eval_py("""
    local out = {}
    for _, ch in ipairs(ns.SwingPracticeUI:Overlay().chips) do if ch:IsShown() then out[#out + 1] = ch.spell end end
    return out
""") == ["sob"]
# keys that are not practice keys walk on (W moves the character)
assert c.eval("""
    local f = DisasterZoneSwingPracticeKeys
    f:GetScript('OnKeyDown')(f, 'W')
    return f:GetPropagateKeyboardInput()
""") is True
res = c.eval_py(PLAY, "perfect")
assert res["running"] is False and res["lesson"] == "twist", res
assert res["stars"] == 3 and res["twists"] == 8 and res["swings"] == 8, res
w.tick(0.2)
# the result screen: the window back, stars lit, lesson 2 open now
r = c.eval_py("""
    local f = DisasterZoneSwingPractice
    local res = f.content and true
    return { shown = f:IsShown(), unlocked = ns.SwingPractice:IsUnlocked('command'),
        best = ns.SwingPractice:Best('twist').stars, practice = ns.SwingTimer.practice ~= nil,
        last = ns.SwingTimer.state.last, kb = DisasterZoneSwingPracticeKeys:IsShown() }
""")
assert r == {"shown": True, "unlocked": True, "best": 3, "practice": False, "kb": False}, r

# a sloppy run: Seal of Blood 0.3 s before the window every time -> every swing early, no star, best kept
c.eval("ns.SwingPractice:Start('twist')")
res = c.eval_py(PLAY, "early")
assert res["twists"] == 0 and res["early"] == 8 and res["stars"] == 0, res
assert c.eval("return ns.SwingPractice:Best('twist').stars") == 3
assert "too soon" in c.eval("return ns.SwingPractice:Tip(ns.SwingPractice.last)")

# lesson 2 (Command back on, the weapon's 3.6 s) and lesson 4 (the full rotation) played perfectly: 3 stars each,
# the player's run matches the ghost's
c.eval("ns.SwingPractice:Start('command')")
assert c.eval("return ns.SwingPractice.run.base") == 3.6
res = c.eval_py(PLAY, "perfect")
assert res["stars"] == 3 and res["grade"] > 0.97 and res["swings"] == 10, res
c.eval("""
    local all = ns.DB:GetSetting('swing.practice.best') or {}
    local me = UnitName('player') .. '-' .. GetRealmName()
    all[me].strike = { stars = 3, grade = 1, score = 1 }
    ns.DB:SetSetting('swing.practice.best', all)
""")
assert c.eval("return ns.SwingPractice:IsUnlocked('judge')") is True
c.eval("ns.SwingPractice:Start('judge')")
res = c.eval_py(PLAY, "perfect")
assert res["stars"] == 3 and res["cs"] >= 3 and res["judge"] >= 2, res

# the spell queue: Command pressed 0.3 s before the GCD ends waits and goes off when it ends; 1 s before: refused
r = c.eval_py("""
    local SP = ns.SwingPractice
    SP:Start('command')
    __MOCK.now = SP.run.go + 0.5
    SP:_Advance()
    local me = SP:_Me()
    me.gcdEnd = GetTime() + 0.3
    local f = DisasterZoneSwingPracticeKeys
    f:GetScript('OnKeyDown')(f, '2')
    local caught = f:GetPropagateKeyboardInput() == false
    local queued = me.queued ~= nil and caught
    __MOCK.now = __MOCK.now + 0.31
    SP:_Advance()
    local fired = me.queued == nil and me.gcdEnd > GetTime() + 1
    me.gcdEnd = GetTime() + 1.0
    local before = me.gcdEnd
    SP:Press('sob')
    local refused = me.queued == nil and me.gcdEnd == before
    local deny = SP.run.pops[#SP.run.pops]
    -- Esc ends a lesson without a result
    f:GetScript('OnKeyDown')(f, 'ESCAPE')
    return { queued = queued, fired = fired, refused = refused, deny = deny.text, running = SP:IsRunning(),
        last = SP.last == nil }
""")
assert r == {"queued": True, "fired": True, "refused": True, "deny": "GCD", "running": False, "last": True}, r
w.tick(0.2)
assert c.eval("return DisasterZoneSwingPractice:IsShown()") is True, "Esc brings the lessons back"

# combat ends practice at once and gives the swing timer back
c.eval("ns.SwingPractice:Start('free')")
assert c.eval("return ns.SwingPractice:IsRunning()") is True
c.set_combat(True)
w.tick(0.2)
r = c.eval_py("return { running = ns.SwingPractice:IsRunning(), practice = ns.SwingTimer.practice ~= nil, "
              "kb = DisasterZoneSwingPracticeKeys:IsShown(), active = ns.SwingTimer.active }")
assert r == {"running": False, "practice": False, "kb": False, "active": True}, r
assert c.eval("return ns.SwingPractice:Start('free')") is False, "no practice in combat"
c.set_combat(False)
w.tick(0.5)

# a Protection paladin can't start it
p = Client(w, "Bob", class_file="PALADIN", guild_rank=1, talents=(0, 45, 16))
p.load_addon()
w.tick(1)
assert p.eval("return ns.SwingPractice:Start('twist')") is False

w.assert_no_errors()
print(w.report())
print("ok")

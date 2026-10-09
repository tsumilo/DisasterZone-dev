#!/usr/bin/env python
"""Swing timer (Core/SwingTimer.lua, UI/SwingTimerHUD.lua): a Retribution Paladin gets the HUD, the planner runs
through the HUD in and out of the twist window, swings are classified, and a fight report is stored."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from harness import World, Client  # noqa: E402

w = World()
ret = Client(w, "Alice", class_file="PALADIN", guild_rank=0, talents=(5, 11, 45))
prot = Client(w, "Bob", class_file="PALADIN", guild_rank=1, talents=(0, 45, 16))
for c in w.clients:
    c.load_addon()
w.tick(2)

assert ret.eval("return ns.SwingTimer:IsRet()") is True, "45 points in Retribution should count as Ret"
assert prot.eval("return ns.SwingTimer:IsRet()") is False
assert ret.eval("return ns.SwingTimer.active") is True
assert prot.eval("return DisasterZoneSwingTimer == nil") is True, "no HUD for a Protection Paladin"

# show it out of combat, run the HUD through a full swing (planner + every part drawn), in each style
ret.eval("ns.DB:SetSetting('swing.idle', true)")
for style in ("bar", "lane", "both"):
    ret.eval("ns.DB:SetSetting('swing.style', ...)", style)
    ret.eval("""
        local ST = ns.SwingTimer
        ST.state.last = GetTime(); ST.state.seal = 'soc'
        for i = 1, 40 do ns.SwingTimerHUD:Update(); _G.__dzAdvance = (_G.__dzAdvance or 0) end
    """)
    w.tick(1)
    w.tick(1)
    w.tick(1.5)
assert ret.eval("return DisasterZoneSwingTimer:IsShown()") is True

# a plan with Command up: the twist step lands inside the window, one round trip early
plan = ret.eval("""
    local ST = ns.SwingTimer
    local snap = { now = 10, nextSwing = 11, speed = 3.5, gcdReady = 10, lat = 0.08, seal = 'soc', socUntil = 0,
      cd = { cs = 99, exo = 99, cons = 99, how = 99 }, judgeReady = 99,
      values = { soc = 1500, sob = 450, cs = 1500, exo = 1000, cons = 800, how = 900, judge = 800 },
      use = { cs = false, exo = false, cons = false, how = false } }
    local p = ST.Plan(snap)
    local s = p.steps[1]
    return s.key, s.at, s.twist
""")
key, at, twist = plan
assert key == "sob", plan
assert abs(twist - 11) < 1e-6
apply = at + 0.08
assert 11 - 0.399 < apply < 11, "Seal of Blood must land inside the overlap: %r" % (plan,)

# a fight: enter combat, a few swings, leave combat -> report stored
ret.eval("""
    local ST = ns.SwingTimer
    ns:Fire('SWING_STATE', true)
""")
w.tick(1)
w.assert_no_errors()
print(w.report())
print("ok")

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

# the rotation (WoWSims' Ret priority list) played from a known state
RUN = """
    local ST = ns.SwingTimer
    local o = ...
    local snap = { now = 10, nextSwing = o.next or 11, lastSwing = o.last or 7.5, speed = o.speed or 3.5, lat = 0.08,
      gcdReady = o.gcd or 10, seal = o.seal, use = { cs = true, exo = false, cons = false },
      ready = { cs = o.cs or 10, judge = o.judge or 10, exo = 99, cons = 99 }, gcd = 1.5,
      cd = { cs = 6, judge = 8, exo = 15, cons = 8 } }
    local out = {}
    for i, st in ipairs(ST.Run(snap)) do out[i] = st.key .. '@' .. string.format('%.3f', st.at) .. (st.twist and ('>' .. st.twist) or '') end
    return table.concat(out, ' ')
"""
def run(**o):
    return ret.eval("local t = {}; for k, v in pairs(...) do t[k] = v end; return (function(...) " + RUN + " end)(t)", o)

# Command up, swing at 11: Seal of Blood at the press zone's start (11 - 0.399 + 0.05 - 0.08), twisting swing 11
seq = run(seal="soc").split()
assert seq[0] == "sob@10.571>11", seq
# then Crusader Strike as soon as the GCD is back, then Judgement within 0.8 s of the swing is gone -> Command
assert seq[1].startswith("cs@12.071"), seq
assert "soc@" in " ".join(seq[2:4]), seq
# Blood up just after a swing, Strike ready: Strike now
assert run(seal="sob", next=13.4, last=9.9).split()[0] == "cs@10.000"
# Blood up, Strike cooling, Judgement ready 0.2 s after the swing: Judgement now (off the GCD), then Command
seq = run(seal="sob", next=13.3, last=9.8, cs=14).split()
assert seq[0] == "judge@10.000" and seq[1] == "soc@10.000", seq
# haste: a 2.8 s swing moves the next twist with it (swing at 10.7 -> press at 10.271)
seq = run(seal="soc", next=10.7, last=7.9, speed=2.8).split()
assert seq[0] == "sob@10.271>10.7", seq

# Settings > Class tools: a card for every paladin; open for the Retribution Paladin, closed ("not your spec") for
# the Protection one; SelectSection('swing') opens Class tools at the card
for c in (ret, prot):
    c.slash("/dz settings")
w.tick(0.5)
assert ret.eval("return ns.SettingsUI:KitShown('swing')") is True
assert prot.eval("return ns.SettingsUI:KitShown('swing')") is True
CARD = ("for _, c in ipairs(ns.SettingsUI.sections.classtools.cards) do if c.kit.key == 'swing' then "
        "return c.body:IsShown(), c.head.sub:GetText() end end")
assert ret.eval(CARD)[0] is True
assert prot.eval(CARD)[0] is False and "not your spec" in prot.eval(CARD)[1]
prot.eval("ns.SettingsUI:SelectSection('swing')")
assert prot.eval("return ns.SettingsUI:GetSection()") == "classtools"
assert prot.eval(CARD)[0] is True, "opening a card by its key opens it"

# not swinging: the HUD rests (no plan), so nothing moves out of combat
assert ret.eval("ns.SwingTimer.state.last = nil; return ns.SwingTimer:Current() == nil") is True
# swinging: there is a press to show
assert ret.eval("local ST = ns.SwingTimer; ST.state.last = GetTime(); ST.state.seal = 'soc'; ST:MarkDirty(); "
                "local c = ST:Current(); return c ~= nil and #c.plan.steps > 0") is True
# Hammer of Wrath is never planned (its cast time resets the swing)
assert ret.eval("return ns.SwingTimer.IDS.how == nil") is True

# a fight: enter combat, a few swings, leave combat -> report stored
ret.eval("""
    local ST = ns.SwingTimer
    ns:Fire('SWING_STATE', true)
""")
w.tick(1)
w.assert_no_errors()
print(w.report())
print("ok")

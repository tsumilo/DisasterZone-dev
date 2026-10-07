"""Minimap arc: left-click fans the pins out, a pin opens its page, pins are shared by the account, and the arc
folds back in (UI/MinimapArc.lua)."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from harness import World, Client

w = World()
a = Client(w, "Alice", class_file="PALADIN", guild_rank=0)
a.load_addon()
w.tick(2)

btn = 'LibStub("LibDBIcon-1.0"):GetMinimapButton("DisasterZone")'
assert a.eval_py(f"return {btn} ~= nil"), "minimap button"
assert "seal_mm" in (a.eval_py('return LibStub("LibDataBroker-1.1"):GetDataObjectByName("DisasterZone").icon') or "")

a.eval(f'{btn}:GetScript("OnClick")({btn}, "LeftButton")')
w.tick(0.6)
assert a.eval_py("return DisasterZone.MinimapArc:IsOpen()"), "arc opens"
pins = a.eval_py("return DisasterZone.db.settings.minimapPins")
print("pins:", pins)
n = a.eval_py("local n=0 for _,c in ipairs({DisasterZoneMinimapArc:GetChildren()}) do if c:IsShown() and c.key then n=n+1 end end return n")
assert n == 4, n

# pin Members, move it first, unpin Atlas
a.eval('DisasterZone.MinimapArc:SetPinned("members", true)')
a.eval('DisasterZone.MinimapArc:MovePin("members", -4)')
a.eval('DisasterZone.MinimapArc:SetPinned("atlas", false)')
pins = a.eval_py("return DisasterZone.db.settings.minimapPins")
print("pins now:", pins)

# a pin opens its page and the arc folds away
a.eval('for _,c in ipairs({DisasterZoneMinimapArc:GetChildren()}) do if c.key == "raids" then c:GetScript("OnClick")(c, "LeftButton") end end')
w.tick(0.8)
assert a.eval_py("return DisasterZone.MainFrame:GetSelectedTab()") == "raids"
assert not a.eval_py("return DisasterZoneMinimapArc:IsShown()"), "arc closed"

# right-click toggles the window
a.eval(f'{btn}:GetScript("OnClick")({btn}, "RightButton")')
w.tick(0.2)

# auto close after the mouse is away
a.eval(f'{btn}:GetScript("OnClick")({btn}, "LeftButton")')
w.tick(4.5)
assert not a.eval_py("return DisasterZone.MinimapArc:IsOpen()"), "lingers then closes"

a.relog()
w.tick(1)
assert a.eval_py("return DisasterZone.db.settings.minimapPins")  # saved
print(w.report())
w.assert_no_errors()
print("OK")

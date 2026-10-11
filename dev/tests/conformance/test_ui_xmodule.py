"""Cross-module UI smoke: every tab, council views, drop panel + roll, loot log, tooltips, settings actions,
run in demo mode on a council client and in a real raid for a non-council ML. Only checks for Lua errors and
a few data contracts between Core and UI.

Run from SCRATCH:  luaenv\\Scripts\\python.exe tests\\conformance\\test_ui_xmodule.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))
sys.path.insert(0, os.path.join(HERE, ".."))
from harness import World, Client  # noqa: E402
from cdl_council import seed_guild_council  # noqa: E402

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name + ((" -- " + str(detail)) if detail else ""))


w = World()
seed_guild_council(w, ["Alice"])     # Addendum E: Alice is on the GM's guild council list
alice = Client(w, "Alice", class_file="PALADIN", guild_rank=1)
bob = Client(w, "Bob", class_file="MAGE", guild_rank=3)
for c in w.clients:
    c.load_addon()
w.tick(3)

# --- demo mode, solo council client -----------------------------------------------------------------------
alice.slash("/dz demo on")
w.tick(1)
for tab in ("council", "log", "settings"):
    alice.slash("/dz " + tab)
    w.tick(0.5)
alice.slash("/dz")      # toggle closed
alice.slash("/dz")      # open (mybis)
w.tick(0.5)
alice.eval("ns.CouncilUI:SetView('items')")
w.tick(0.5)
alice.eval("ns.CouncilUI:SetView('member')")
w.tick(0.5)
key = alice.eval("return ns.Demo:GetRaidKeys()[2]")
alice.eval("ns.CouncilUI:ShowMember(...)", key)
w.tick(0.5)
alice.eval("ns.CouncilUI:ShowItem(28822)")
w.tick(0.5)

# tooltips (own + council lines)
lines = alice.show_tooltip_item(28822)
check("council tooltip lines present in demo", any(" want" in (l or "") and "seal_mm:" in (l or "") for l, _ in lines), lines[-4:])

# drop panel + roll in demo
alice.slash("/dz test")
w.tick(1)
check("drop panel shown for the simulated drop", alice.eval("return ns.DropPanel.frame and ns.DropPanel.frame:IsShown()"))
drop_item = alice.eval("return ns.DropPanel.drop and ns.DropPanel.drop.i[1]")
alice.eval("ns.DropPanel:StartRoll(..., 1)", drop_item)
w.tick(33)   # default roll.duration = 30 s
res =alice.eval_py("local s = ns.Roll:GetActive() or ns.Roll:GetForItem(..., ns.DropPanel.drop.s, 1); return s and ns.Roll:GetResults(s.id)", drop_item)
check("demo roll produced result rows", isinstance(res, list) and len(res) > 0, res and len(res))
sid = alice.eval("local s = ns.Roll:GetForItem(..., ns.DropPanel.drop.s, 1); return s and s.id", drop_item)
state = alice.eval("local s = ns.Roll:Get(...); return s and s.state", sid)
check("demo roll closed after its duration", state == "closed", state)
sug = alice.eval("local r = ns.Roll:GetResults(...); return r[1] and r[1].suggested and r[1].key", sid)
if sug:
    alice.eval("ns.DropPanel:AwardRoll(...)", sid, sug)
    alice.accept_popup("DISASTERZONE_CONFIRM_AWARD")
    w.tick(1)
check("demo award recorded in the demo ledger view", alice.eval("return #ns.Ledger:GetEntries({})") >= 1)
check("demo award not in the saved ledger", alice.eval("return next(DisasterZoneDB.ledger) == nil"))

# loot log award dialog
alice.eval("ns.LootLogUI:OpenAwardDialog(28822, ..., '')", key)
w.tick(0.5)
alice.slash("/dz demo off")
w.tick(1)
check("demo ledger discarded on demo off", alice.eval("return #ns.Ledger:GetEntries({})") == 0)

# --- real raid: non-council master looter (Bob) can see / run rolls -------------------------------------
w.make_raid([alice, bob], master_looter=bob)
w.enter_instance("Karazhan", 532)
w.encounter(652, "Attumen the Huntsman")
w.tick(1)
bob.open_loot([(28477, 4), (28453, 4)])
w.tick(2)
check("Bob (ML, not council) can start rolls", bob.eval("return ns.Roll:CanStart()"))
check("Alice (council) got the drop via D", alice.eval("return #ns.Loot:GetHistory() >= 1"))
bob.slash("/dz drops")
w.tick(0.5)
bob.eval("ns.DropPanel:StartRoll(28477, 1)")
w.tick(1)
w.player_roll(alice, 88)
w.tick(35)
bsid = bob.eval("local s = ns.Roll:GetForItem(28477, ns.DropPanel.drop.s, 1); return s and s.id")
check("remote roll session exists on Alice", alice.eval("return ns.Roll:Get(...) ~= nil", bsid))
bob.eval("ns.Roll:Award(...)", bsid, "Alice-Thunderstrike")
w.tick(0.2)
print("Bob popups:", bob.popups())
w.tick(1)

print(w.report())
errs = w.errors()
check("no Lua errors", not errs, errs[:3] if errs else "")
print()
print("%d/%d passed" % (sum(1 for r in results if r[1]), len(results)))

#!/usr/bin/env python
"""Scratch: load CDLoot in the mock, open every tab / menu / popup path, and print the mock's report of
unknown template fields, unknown widget methods and missing globals (hints for the client-API audit)."""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))
from harness import World, Client  # noqa: E402

w = World()
alice = Client(w, "Alice", class_file="PALADIN", guild_rank=0, talents=(41, 20, 0))
bob = Client(w, "Bob", class_file="MAGE", guild_rank=1)
for c in w.clients:
    c.load_addon()
w.tick(2)
w.make_raid([alice, bob], master_looter=alice)
w.enter_instance("Karazhan", 532)
w.encounter(652, "Attumen the Huntsman")
for key in ("mybis", "council", "loot", "settings"):
    alice.slash("/cdl " + {"mybis": "", "council": "council", "loot": "log", "settings": "settings"}[key])
    w.tick(0.5)
alice.open_loot([(28477, 4), (28453, 4)])
w.tick(1)
alice.slash("/cdl test")
w.tick(1)
alice.slash("/cdl drops")
w.tick(1)
alice.show_tooltip_item(28477)
w.tick(0.5)
alice.close_loot()
w.tick(2)
print(w.report()); print(w.report_unknown_fields(lowercase=True))
errs = w.errors()
print("errors:", len(errs))
for e in errs[:10]:
    print(e)

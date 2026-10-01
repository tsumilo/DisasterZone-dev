#!/usr/bin/env python
"""Template scenario: three guild members load the REAL DisasterZone addon, form a master-loot raid, kill a boss,
the ML awards an item, one player /reloads. Copy this file and add assertions for the feature under test.

Run:  luaenv\\Scripts\\python.exe tools\\example_scenario.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import World, Client  # noqa: E402

w = World()                                    # realm Thunderstrike, guild ranks GM/Officer/Raider/Member/Initiate
alice = Client(w, "Alice", class_file="PALADIN", guild_rank=0, talents=(41, 20, 0))
bob = Client(w, "Bob", class_file="MAGE", guild_rank=1)
carol = Client(w, "Carol", class_file="WARRIOR", guild_rank=3)
w.add_offline_member("Dave", "ROGUE", 3, officer_note="alt of Bob")

for c in w.clients:
    c.load_addon()                             # runs DisasterZone.toc, fires ADDON_LOADED/PLAYER_LOGIN/PLAYER_ENTERING_WORLD
w.tick(2)                                      # guild roster arrives after 0.5 s (GUILD_ROSTER_UPDATE)

w.make_raid([alice, bob, carol], master_looter=alice)
w.enter_instance("Karazhan", 532)
w.encounter(652, "Attumen the Huntsman")       # ENCOUNTER_START / ENCOUNTER_END(success) / BOSS_KILL
alice.open_loot([(28477, 4), (28453, 4)])      # ML looting the corpse: LOOT_READY + LOOT_OPENED
w.tick(1)
alice.eval("GiveMasterLoot(1, 2)")             # candidate 2 = Bob -> CHAT_MSG_LOOT on everyone after 0.2 s
w.tick(1)
alice.close_loot()

bob.relog()                                    # /reload: DisasterZoneDB serialized + restored in a fresh runtime
w.tick(15)                                     # let AceComm/ChatThrottleLib traffic settle

print("addon messages:", len(w.addon_log), "chat lines:", len(w.chat_log))
print("Bob's DisasterZoneDB top-level keys:", sorted((bob.eval_py("return DisasterZoneDB") or {}).keys()))
print(w.report())                              # errors, warnings, unknown template fields/methods, missing globals
w.assert_no_errors()                           # raises LuaErrorsFound with every Lua traceback

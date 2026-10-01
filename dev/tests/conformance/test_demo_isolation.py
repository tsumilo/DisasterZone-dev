"""Conformance probes: demo-mode interaction with real raid traffic (Loot D gate, announce lines,
real roll sessions awarded while demo is on). Read-only against the addon.

Run from SCRATCH:  luaenv\\Scripts\\python.exe tests\\conformance\\test_demo_isolation.py
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
    results.append((name, bool(cond), detail))
    print(("PASS " if cond else "FAIL ") + name + ((" -- " + str(detail)) if detail else ""))


def setup():
    w = World()
    seed_guild_council(w, ["Alice"])     # Addendum E: Alice is on the GM's guild council list
    alice = Client(w, "Alice", class_file="PALADIN", guild_rank=1)
    bob = Client(w, "Bob", class_file="MAGE", guild_rank=3)
    carol = Client(w, "Carol", class_file="WARRIOR", guild_rank=3)
    for c in w.clients:
        c.load_addon()
    w.tick(3)
    return w, alice, bob, carol


# ---------------------------------------------------------------------------------------------------------------
# A. A real raid D arrives while demo mode is on
# ---------------------------------------------------------------------------------------------------------------
def scenario_drop_gate(demo):
    w, alice, bob, carol = setup()
    w.make_raid([alice, bob, carol], master_looter=bob)
    w.enter_instance("Karazhan", 532)
    w.tick(1)
    if demo:
        alice.slash("/dz demo on")
    w.tick(1)
    before = alice.eval("return #ns.Loot:GetHistory()")
    bob.open_loot([(28477, 4), (28453, 4)])
    w.tick(3)
    after = alice.eval("return #ns.Loot:GetHistory()")
    d_sent = [e for e in w.addon_log if e["sender"].startswith("Bob") and e["prefix"] == "CDLa"]
    w.assert_no_errors()
    return before, after, len(d_sent)


b0, a0, n0 = scenario_drop_gate(False)
check("control: Alice (demo off) receives Bob's raid D", a0 == b0 + 1 and n0 >= 1, (b0, a0, n0))
b1, a1, n1 = scenario_drop_gate(True)
check("demo on: Alice still receives Bob's real raid D", a1 == b1 + 1, "history %d -> %d, D sent by Bob: %d" % (b1, a1, n1))


# ---------------------------------------------------------------------------------------------------------------
# B. Announce lines while demo mode is on, in a real raid
# ---------------------------------------------------------------------------------------------------------------
w, alice, bob, carol = setup()
w.make_raid([alice, bob, carol], master_looter=alice)
w.tick(1)
alice.slash("/dz demo on")
w.tick(1)
fake = alice.eval_py("return ns.Demo:GetFakeNames()")
# an item some demo raid member has on their list
item = alice.eval("""
    for _, key in ipairs(ns.Demo:GetRaidKeys()) do
        local rec = ns.Store:Get(key)
        local ph = rec and rec.data and rec.data.ph
        for p = 1, 5 do
            if ph and ph[p] then
                for sid, pair in pairs(ph[p]) do
                    if pair[1] and pair[1] > 0 and #ns.Store:GetWanters(pair[1], {raidOnly=true}) > 0 then
                        return pair[1]
                    end
                end
            end
        end
    end
""")
n_chat_before = len(w.chat_log)
alice.eval("ns.DropPanel.lastAnnounce = ns.DropPanel.lastAnnounce or {}; ns.DropPanel:AnnounceItem(...)", item)
w.tick(1)
lines = [c for c in w.chat_log[n_chat_before:] if c["sender"].startswith("Alice")]
leaked = [c for c in lines if any(n in (c["text"] if isinstance(c["text"], str) else c["text"].decode("utf-8", "replace")) for n in fake)]
check("demo on: DropPanel Announce does not post demo names to real raid chat", not leaked,
      [(c["chat_type"], c["text"]) for c in leaked][:2])
w.assert_no_errors()


# ---------------------------------------------------------------------------------------------------------------
# C. A real (non-demo) closed roll awarded after demo mode was switched on
# ---------------------------------------------------------------------------------------------------------------
w, alice, bob, carol = setup()
w.make_raid([alice, bob, carol], master_looter=bob)
w.tick(1)
sid = alice.eval("local s = ns.Roll:Start(28477, nil); return s and s.id")
w.tick(1)
w.player_roll(bob, 77)
w.tick(1)
alice.eval("ns.Roll:End(...)", sid)
w.tick(1)
check("real roll closed on Bob's client", bob.eval("local s = ns.Roll:Get(...); return s and s.state", sid) == "closed")
alice.slash("/dz demo on")
w.tick(1)
state = alice.eval("local s = ns.Roll:Get(...); return s and s.state", sid)
alice.eval("ns.Roll:Award(...)", sid, "Bob-Thunderstrike")
popups = alice.popups() if hasattr(alice, "popups") else None
try:
    alice.accept_popup("DISASTERZONE_CONFIRM_AWARD")
except Exception as exc:  # noqa: BLE001
    print("accept_popup failed:", exc)
w.tick(2)
real_n = alice.eval("local n=0; for _ in pairs(DisasterZoneDB.ledger) do n=n+1 end; return n")
demo_n = alice.eval("return #ns.Ledger:GetEntries({includeVoid=true})")
rw = [e for e in w.addon_log if e["sender"].startswith("Alice") and e["prefix"] == "CDLa" and e["time"] > 0]
bob_state = bob.eval("local s = ns.Roll:Get(...); return s and s.state", sid)
check("real roll awarded in demo mode is written to the REAL ledger", real_n >= 1,
      "real ledger entries=%s, demo-view entries=%s, alice session state before=%s" % (real_n, demo_n, state))
check("real roll awarded in demo mode reaches other raiders (RW)", bob_state == "awarded", "bob sees state=%s" % bob_state)
alice.slash("/dz demo off")
w.tick(1)
real_after = alice.eval("local n=0; for _ in pairs(DisasterZoneDB.ledger) do n=n+1 end; return n")
check("after demo off the award is still in the loot log", real_after >= 1, "real ledger entries=%s" % real_after)
w.assert_no_errors()

print()
print("%d/%d passed" % (sum(1 for r in results if r[1]), len(results)))

import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))
from harness import World, Client
w = World()
alice = Client(w, "Alice", class_file="PALADIN", guild_rank=1)
bob = Client(w, "Bob", class_file="MAGE", guild_rank=3)
for c in w.clients: c.load_addon()
w.tick(3)
w.make_raid([alice, bob], master_looter=alice)
w.tick(1)
alice.slash("/cdl demo on")
w.tick(1)
item = alice.eval("""
  for _, key in ipairs(ns.Demo:GetRaidKeys()) do
    local rec = ns.Store:Get(key)
    local ph = rec and rec.data and rec.data.ph
    for p = 1, 5 do
      if ph and ph[p] then
        for sid, pair in pairs(ph[p]) do
          if pair[1] and pair[1] > 0 and #ns.Store:GetWanters(pair[1], {raidOnly=true}) > 0 then return pair[1] end
        end
      end
    end
  end
""")
print("item", item, alice.eval("return #ns.Store:GetWanters(...)", item))
print("line:", alice.eval("return ns.DropPanel:BuildAnnounceLine(...)", item))
n0 = len(w.chat_log)
alice.eval("ns.DropPanel:AnnounceItem(...)", item)
w.tick(1)
for c in w.chat_log[n0:]:
    print("CHAT", c["sender"], c["chat_type"], c["text"])
# Council items-view announce path
print(alice.printed[-3:] if hasattr(alice, "printed") else "")
w.assert_no_errors()

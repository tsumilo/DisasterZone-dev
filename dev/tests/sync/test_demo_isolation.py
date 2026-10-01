#!/usr/bin/env python
"""(i) Demo isolation (Addendum A §20): nothing demo-related goes over the wire (addon messages or chat) or into
SavedVariables, while real sync keeps working next to demo mode.

Run:  luaenv\\Scripts\\python.exe tests\\sync\\test_demo_isolation.py   [-k substring]
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (Runner, Client, new_world, up, settle, key, edit, own, cached, cached_rev, logical_messages,  # noqa: E402
                    ledger_ids, printed)

r = Runner("demo isolation")
RK, C1K, C2K = key("Raider"), key("Councila"), key("Councilb")
ITEM = 28477


def setup():
    w = new_world()
    R = Client(w, "Raider", class_file="PALADIN", guild_rank=3)
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1)
    C2 = Client(w, "Councilb", class_file="MAGE", guild_rank=1)
    for c in (R, C1, C2):
        up(c)
    settle(w, 30)
    edit(R, 0, commit=True)
    settle(w, 10)
    w.make_raid([C1, R, C2], master_looter=C1, leader=C1)
    w.enter_instance("Karazhan", 532)
    fake = list(C1.eval_py("return ns.Demo:GetFakeNames()") or [])
    assert len(fake) >= 10, fake
    return w, R, C1, C2, fake


def contains_fake(text, fake):
    return [n for n in fake if re.search(r"\b%s\b" % re.escape(n), text)]


def wire_leaks(w, mark, fake):
    leaks = []
    for m in logical_messages(w, mark):
        blob = repr(m["msg"])
        hit = contains_fake(blob, fake)
        if hit:
            leaks.append((m["sender"], m["t"], hit[:3]))
    return leaks


def chat_leaks(w, mark_chat, fake):
    return [(c["sender"], c["chat_type"], c["text"]) for c in w.chat_log[mark_chat:] if contains_fake(c["text"], fake)]


def sv_leaks(c, fake):
    src = c.saved_variables().get("DisasterZoneDB") or ""
    if isinstance(src, bytes):
        src = src.decode("utf-8", "replace")
    return contains_fake(src, fake)


def fake_key_with_list(c):
    """A demo member who has ITEM (or anything) on their list, as the council UI would offer."""
    return c.eval("""
      for _, e in ipairs(ns.Store:GetWanters(...)) do
        if not ns.Util.IsMe(e.key) and ns.Demo:GetRecord(e.key) then return e.key end
      end
      return ns.Demo:GetMembers()[1]""", ITEM)


@r.case
def i_demo_on_council_sends_nothing_demo_related():
    w, R, C1, C2, fake = setup()
    mark, mark_chat = len(w.addon_log), len(w.chat_log)
    C1.slash("/dz demo")
    assert C1.eval("return ns.Demo:IsEnabled()")
    fk = fake_key_with_list(C1)
    assert fk and fk.split("-")[0] in fake, fk
    led_before = ledger_ids(C1)

    # awards in demo mode (to a demo member and to a real one), a roll, a simulated drop
    C1.eval("ns.Ledger:Award(...)", ITEM, fk, "", "demo award")
    C1.eval("ns.Ledger:Award(...)", ITEM, RK, "", "demo award to real")
    C1.eval("ns.Roll:Start(...)", ITEM)
    C1.slash("/dz test")
    settle(w, 40)
    # sync traffic next to demo mode: C2 and R say HELLO, C1 answers (S/M must only carry real data)
    C2.eval("ns.Sync:SendHello()")
    R.eval("ns.Sync:SendHello()")
    C1.eval("ns.Sync:SendHello()")
    settle(w, 30)

    man = C1.eval_py("return ns.Store:GetManifest()") or {}
    assert not contains_fake(repr(man), fake), "manifest carries demo keys: %s" % man
    assert ledger_ids(C1) == led_before, "demo awards reached the real ledger: %s" % ledger_ids(C1)
    assert ledger_ids(C2) == led_before, "demo awards reached another council member: %s" % ledger_ids(C2)
    leaks = wire_leaks(w, mark, fake)
    assert not leaks, "demo data on the wire: %s" % leaks[:5]
    types = sorted({m["t"] for m in logical_messages(w, mark) if m["sender"] == C1K})
    assert not ({"A", "RS", "RW", "RE", "D"} & set(types)), "demo actions sent %s" % types
    cl = chat_leaks(w, mark_chat, fake)
    assert not cl, "demo names in chat: %s" % cl[:3]
    assert not sv_leaks(C1, fake), "demo names in DisasterZoneDB: %s" % sv_leaks(C1, fake)

    C1.slash("/dz demo")                             # off: demo ledger discarded, nothing flushed
    settle(w, 10)
    assert not C1.eval("return ns.Demo:IsEnabled()")
    assert ledger_ids(C1) == led_before
    C1.relog()
    settle(w, 30)
    assert not C1.eval("return ns.Demo:IsEnabled()"), "demo mode survived a reload"
    assert not sv_leaks(C1, fake), sv_leaks(C1, fake)
    assert not wire_leaks(w, mark, fake)
    # real sync still fine
    assert cached_rev(C1, RK) == own(R)["rev"] == 1
    w.assert_no_errors()


@r.case
def i_real_sync_keeps_working_while_demo_on():
    w, R, C1, C2, fake = setup()
    C1.slash("/dz demo")
    R.slash("/dz demo")
    mark = len(w.addon_log)
    edit(R, 1, commit=True)
    settle(w, 10)
    assert cached_rev(C1, RK) == 2 and cached_rev(C2, RK) == 2, (cached_rev(C1, RK), cached_rev(C2, RK))
    assert own(R)["rev"] == 2
    # a real ledger award by C2 reaches C1's REAL ledger although C1 is in demo mode
    e = C2.eval_py("return ns.Ledger:Award(...)", ITEM, RK, "", "real")
    settle(w, 5)
    real = C1.eval_py("local t = {} for id in pairs(ns.db.ledger) do t[#t+1] = id end return t") or []
    assert e["id"] in real, "real award from C2 missing in C1's saved ledger while C1 is in demo mode"
    assert not wire_leaks(w, mark, fake)
    # a raider in demo mode must not start behaving like council
    assert not R.eval("return ns.Guild:AmICouncil(true)")
    assert not [m for m in logical_messages(w, mark) if m["sender"] == RK and m["t"] in ("S", "M", "W", "R", "A")]
    w.assert_no_errors()


@r.case
def i_real_drop_announce_in_demo_mode_does_not_post_fake_names():
    """A council member tries demo mode during a real raid. A REAL boss drop comes in; the drop panel shows
    demo wanters (fine, local). Clicking 'Announce' must not post demo names into raid chat."""
    w, R, C1, C2, fake = setup()
    C1.slash("/dz demo")
    fk, wanted = C1.eval("""
      -- a demo member of the (demo) raid with an unobtained boss item as a main pick
      for _, key in ipairs(ns.Demo:GetRaidKeys()) do
        local rec = not ns.Util.IsMe(key) and ns.Store:Get(key)
        if rec then
          for p, slots in pairs(rec.data.ph) do for sid, pair in pairs(slots) do
            local id = pair[1]
            if id and id > 0 and #ns.ItemDB:GetSources(id) > 0 and not ns.ItemDB:IsToken(id) then
              local ob = false
              for _, o in ipairs(rec.data.ob or {}) do if o == id then ob = true end end
              if not ob then return key, id end
            end
          end end
        end
      end""")
    assert wanted, "no demo raid member wants a boss item?"
    n_wanters = C1.eval("return ns.Store:CountWanters(...)", wanted)
    assert n_wanters >= 1, n_wanters
    mark, mark_chat = len(w.addon_log), len(w.chat_log)
    w.encounter(652, "Attumen the Huntsman")
    C1.open_loot([(wanted, 4)])                       # real loot window (C1 is master looter)
    settle(w, 3)
    shown = C1.eval("return ns.DropPanel and ns.DropPanel.drop and ns.DropPanel.drop.s")
    C1.eval("ns.DropPanel:AnnounceItem(...)", wanted)  # the per-item 'Announce' button
    settle(w, 3)
    C1.close_loot()
    cl = chat_leaks(w, mark_chat, fake)
    r.note("(i) drop panel shown for source %s; chat lines: %s" % (shown, [c["text"] for c in w.chat_log[mark_chat:]]))
    assert not wire_leaks(w, mark, fake)
    w.assert_no_errors()
    assert not cl, "demo names posted to raid chat from a real drop in demo mode: %s" % cl


DEMO_WANTED_LUA = """
  -- a demo member of the (demo) raid with an unobtained boss item as a main pick
  for _, key in ipairs(ns.Demo:GetRaidKeys()) do
    local rec = not ns.Util.IsMe(key) and ns.Store:Get(key)
    if rec then
      for p, slots in pairs(rec.data.ph) do for sid, pair in pairs(slots) do
        local id = pair[1]
        if id and id > 0 and #ns.ItemDB:GetSources(id) > 0 and not ns.ItemDB:IsToken(id) then
          local ob = false
          for _, o in ipairs(rec.data.ob or {}) do if o == id then ob = true end end
          if not ob then return key, id end
        end
      end end
    end
  end"""


@r.case
def i_council_overview_announce_in_demo_mode_does_not_post_fake_names():
    """Council overview (UI/Council.lua) item row -> right-click -> 'Announce to raid' while demo mode is on in a
    real raid: the line is built from demo wanters and posted to RAID chat."""
    w, R, C1, C2, fake = setup()
    C1.slash("/dz demo")
    fk, wanted = C1.eval(DEMO_WANTED_LUA)
    assert wanted, "no demo raid member wants a boss item?"
    mark_chat = len(w.chat_log)
    C1.eval("ns.CouncilUI:ShowItem(...)", wanted)
    w.tick(0.5)
    found = C1.eval("""
      local id = ...
      for f in pairs(__MOCK.OBJ) do
        if type(f) == "table" and rawget(f, "cdlInit") and type(rawget(f, "cdlData")) == "table"
           and rawget(f, "cdlData").itemID == id and __MOCK.is_visible(f) then
          __probeRow = f
          return true
        end
      end
      return false""", wanted)
    assert found, "council items view has no visible row for item %s" % wanted
    C1.eval('__MOCK.click(__probeRow, "RightButton")')
    menu = C1.last_menu()
    assert menu and any(ch.get("text") == "Announce to raid" for ch in menu["children"]), menu
    C1.menu_select("Announce to raid")
    settle(w, 2)
    lines = [c["text"] for c in w.chat_log[mark_chat:]]
    r.note("(i) council overview announce in demo mode posted: %s" % lines)
    cl = chat_leaks(w, mark_chat, fake)
    w.assert_no_errors()
    assert not cl, "demo names posted to raid chat from the council overview in demo mode: %s" % cl


@r.case
def i_legacy_demo_awards_purged_and_not_resynced():
    """DisasterZone 0.1 wrote demo awards into the real ledger. At login they are purged (roster needed), and a 0.1 peer
    that still has them cannot sync them back (A / LG)."""
    w = new_world()
    R = Client(w, "Raider", class_file="PALADIN", guild_rank=3)
    C1 = Client(w, "Councila", class_file="PRIEST", guild_rank=1, online=False)
    C2 = Client(w, "Councilb", class_file="MAGE", guild_rank=1)
    up(R); up(C2)
    fake = list(C2.eval_py("return ns.Demo:GetFakeNames()"))
    f1 = fake[0] + "-Thunderstrike"
    C1.set_saved_variable("DisasterZoneDB", """{ schema = 1, ledger = {
      ["m1789990000Councila28477"] = { id = "m1789990000Councila28477", i = 28477, w = "%s", b = "", ts = 1789990000, by = "Councila-Thunderstrike", s = "m" },
      ["m1789990001Councila28453"] = { id = "m1789990001Councila28453", i = 28453, w = "Raider-Thunderstrike", b = "", ts = 1789990001, by = "Councila-Thunderstrike", s = "m" },
    } }""" % f1)
    C1.login()
    settle(w, 5)
    ids = ledger_ids(C1)
    assert ids == ["m1789990001Councila28453"], "demo award not purged at login: %s" % ids
    assert any("removed 1 demo award" in p for p in printed(C1)), printed(C1)[-5:]
    # a legacy peer pushes a demo award again
    legacy = {"id": "m1789990500Councilb28477", "i": 28477, "w": fake[1] + "-Thunderstrike", "b": "", "ts": 1789990500,
              "by": C2K, "s": "m"}
    C2.eval("local m, d, t, cl = ... return ns.Comm:Send(m, d, t, cl)", {"t": "A", "e": legacy}, "WHISPER", C1K, "ctrl")
    C2.eval("local m, d, t, cl = ... return ns.Comm:Send(m, d, t, cl)", {"t": "LG", "e": [legacy]}, "WHISPER", C1K, "data")
    settle(w, 30)
    assert legacy["id"] not in ledger_ids(C1), "demo award from a legacy peer was merged"
    assert not sv_leaks(C1, fake), sv_leaks(C1, fake)
    w.assert_no_errors()


if __name__ == "__main__":
    r.run()

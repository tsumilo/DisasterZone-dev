#!/usr/bin/env python
"""Dungeon mode end to end (Addendum B §21-§22, the §22.3 scenario list) on the real addon, 5 mocked clients.

- A 5-man party in The Black Morass: the leader turns dungeon mode on (Settings checkbox), every member gets DM.
- Loot from a dungeon boss GUID with a rare item: D on PARTY, the drop panel for council + party leader (boss name
  from normal / heroic creature GUIDs and chest objects), personal toasts.
- A party roll through the drop panel: popups, RandomRoll, suggestion, award -> RW on PARTY, ledger dg = true,
  Loot Log "(dungeon)" tag and filter, "won tonight" ignores it. A non-council party leader runs rolls too.
- Disband / raid conversion clear the mode; a plain member cannot turn it on for the others; with the mode off a
  party drop is not broadcast.
- Quality rules (rare only inside a 5-man with the mode active, epic elsewhere), /dz test inside a dungeon, the
  picker's dungeon scopes (slots x classes, heroic tags), and the council Items tree (5-man items under "Other").

Run: luaenv\\Scripts\\python.exe tests\\dungeon\\test_dungeon.py   [-k substring]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(SCRATCH, "tests", "loot-roll"))
sys.path.insert(0, os.path.join(SCRATCH, "tests", "boot-ui"))

from lr_common import *  # noqa: F401,F403,E402
import _common as bu  # noqa: E402

R = Runner("dungeon mode (Addendum B, end to end)")

BM_NAME, BM_ID = "Black Morass", 269
AEONUS_GUID = "Creature-0-1-2-3-17881-00000A1"          # normal Aeonus
AEONUS_H_GUID = "Creature-0-1-2-3-20737-00000A2"        # heroic Aeonus
TEMPORUS_GUID = "Creature-0-1-2-3-17880-00000A3"
DEJA_H_GUID = "Creature-0-1-2-3-20738-00000A4"          # heroic Chrono Lord Deja
NAZAN_CHEST_GUID = "GameObject-0-1-2-3-185168-00000A5"  # Hellfire Ramparts: Reinforced Fel Iron Chest
IKISS_COFFER_GUID = "GameObject-0-1-2-3-187372-00000A6"  # Sethekk Halls: Talon King's Coffer
TRASH_GUID = "Creature-0-1-2-3-21104-00000A7"           # a Black Morass trash mob (no boss)

COWL = 28206            # Cowl of the Guiltless: Aeonus normal + heroic (leather head, rare)
BREECHES = 30531        # Breeches of the Occultist: Aeonus heroic only (cloth legs)
QUANTUM = 29356         # Quantum Blade: Aeonus heroic only (2H)
SCARAB = 28190          # Scarab of the Infinite Cycle (trinket)
MANA_CROWN = 28193      # Mana-Etched Crown (cloth head)
KILT = 28185            # Khadgar's Kilt of Abjuration (Temporus, cloth legs)
LEGPLATES = 27977       # Legplates of the Bold (Aeonus, plate legs)
BURNOOSE = 27988        # Burnoose of Shifting Ages (Deja, cloak)
GREEN = 25730           # Pattern: Stylin' Jungle Hat (quality 1-2: never tracked)
SID_LEGS = 9

PARTY = [
    ("Alice", "PALADIN", 0),   # GM: council, party leader
    ("Bob", "MAGE", 1),        # officer: council
    ("Carol", "WARRIOR", 3),
    ("Dave", "PRIEST", 3),
    ("Erin", "ROGUE", 3),
]
NAMES = [p[0] for p in PARTY]
PARTY_BIS = {
    "Erin": [(1, SID_HEAD, "main", COWL)],
    "Dave": [(1, SID_LEGS, "main", BREECHES)],
    "Bob": [(1, SID_LEGS, "alt", BREECHES), (1, SID_BACK, "main", RUBY_DRAPE)],
}
ENABLE_LABEL = "Dungeon mode (5-man parties)"


class FixedRng:
    def __init__(self, value):
        self.value = value

    def randint(self, lo, hi):
        return self.value


DG_PROBE = r"""
__DG = __DG or { changed = {} }
if not __DG.hooked then
  __DG.hooked = true
  ns:On("DUNGEON_MODE_CHANGED", function(active) __DG.changed[#__DG.changed + 1] = active and true or false end)
end
"""


class Party:
    """5 loaded clients in one party (leader first), BiS lists synced, inside The Black Morass."""

    def __init__(self, roster=PARTY, bis=PARTY_BIS, leader="Alice", sync=True, instance=True):
        self.w = World()
        self.c = {}
        for name, cls, rank in roster:
            self.c[name] = Client(self.w, name, class_file=cls, guild_rank=rank)
        for cl in self.c.values():
            cl.load_addon()
            bu.install_helpers(cl)
        install_probes(self.c.values())
        for cl in self.c.values():
            cl.eval(DG_PROBE)
        self.w.tick(2)
        setup_council(self.w, self.c, roster)
        self.leader = leader
        self.form(leader)
        for name, entries in (bis or {}).items():
            seed_bis(self.c[name], entries)
        if sync:
            for cl in self.c.values():
                cl.slash("/dz sync")
                self.w.tick(0.3)
            self.w.tick(45)
        if instance:
            self.w.enter_instance(BM_NAME, BM_ID, "party", 5, 2)
            self.w.tick(1)

    def form(self, leader, names=None):
        names = names or list(self.c)
        members = [self.c[leader]] + [self.c[n] for n in names if n != leader]
        self.w.make_party(members, leader=self.c[leader])
        self.w.tick(1)

    def __getitem__(self, name):
        return self.c[name]

    @property
    def clients(self):
        return list(self.c.values())


def active(c):
    return c.eval("return ns.Util.IsDungeonModeActive()")


def channel(c):
    return c.eval("return ns.Util.GetGroupChannel()")


def enabled_by(c):
    return c.eval("return ns.Dungeon.groupEnabledBy")


def changed(c):
    return c.eval_py("return __DG.changed") or []


def sent_by(w, t, sender, start=0):
    return [m for m in msgs_of_type(w, t, start) if m["_sender"] == key(sender)]


def open_settings(c):
    c.eval("function T_settings() return ns.MainFrame:GetPanel('settings') end")
    c.slash("/dz settings")


def settings_status(c):
    if not c.eval("return ns.SettingsUI.dungeonStatus ~= nil"):
        open_settings(c)
    c.eval("ns.SettingsUI:RefreshDungeon()")
    return strip_codes(c.eval("return ns.SettingsUI.dungeonStatus:GetText()"))


def enable_via_settings(p, name="Alice", tick=1.5):
    c = p[name]
    open_settings(c)
    p.w.tick(0.3)
    cb = c.eval("return T_checkbox(T_settings(), ...)", ENABLE_LABEL)
    assert cb is not None, "no dungeon mode checkbox in the Settings panel"
    was = c.eval("local b = ...; return b:GetChecked() and true or false", cb)
    c.click(cb)
    p.w.tick(tick)
    assert c.eval("return ns.DB:GetSetting('dungeon.enabled')") is (not was)
    return cb


def panel_shown(c):
    return bool(c.eval("return ns.DropPanel.frame ~= nil and ns.DropPanel.frame:IsShown()"))


def panel_header(c):
    return (strip_codes(c.eval("return ns.DropPanel.title:GetText()") or ""),
            strip_codes(c.eval("return ns.DropPanel.sub:GetText()") or ""))


def block(c, item, copy=1):
    return c.eval("local id, cp = ...; for _, b in ipairs(ns.DropPanel.blocks) do "
                  "if b:IsShown() and b.itemID == id and (b.copy or 1) == cp then return b end end", item, copy)


def block_info(c, item, copy=1):
    for b in panel_blocks(c):
        if b["item"] == item and (b.get("copy") or 1) == copy:
            return b
    return None


def click_popup_roll(p, name, value):
    c = p[name]
    assert c.eval("return ns.RollFrame.frame:IsShown() and ns.RollFrame.frame.roll:IsShown()"), \
        "%s: Roll button not visible (%r)" % (name, rollframe_state(c))
    p.w._roll_rng = FixedRng(value)
    c.click(c.eval("return ns.RollFrame.frame.roll"))
    del p.w._roll_rng


def click_popup_pass(p, name):
    c = p[name]
    assert c.eval("return ns.RollFrame.frame.pass:IsShown()"), rollframe_state(c)
    c.click(c.eval("return ns.RollFrame.frame.pass"))


def ledger_rows(c):
    return c.eval_py(r"""local out = {}
      for _, e in ipairs(ns.Ledger:GetEntries({ includeVoid = true })) do
        out[#out + 1] = { id = e.id, i = e.i, w = e.w, s = e.s, dg = e.dg or false, b = e.b, n = e.n, vd = e.vd or false }
      end
      return out""") or []


def loot_log_rows(c):
    """[(entry id, boss column text)] of the visible Loot Log rows."""
    c.eval("ns.LootLogUI:Refresh(true)")
    rows = c.eval_py(r"""local o = {}
      for _, r in ipairs(T_rows(T_box(DisasterZoneLootLogPanel))) do
        local e = rawget(r, 'cdlEntry')
        if e and r:IsShown() then o[#o + 1] = { e.id, r.boss:GetText() or '' } end
      end
      return o""") or []
    return [(x[0], strip_codes(x[1])) for x in rows]


def open_loot_log(c):
    c.slash("/dz log")
    if c.eval("return ns.MainFrame:GetSelectedTab() == 'council' and ns.CouncilUI:GetView()") != "log":
        c.eval("ns.MainFrame:Open('loot')")


# ------------------------------------------------------------------------------------------------------------------
# §22.1 activation: the leader enables it, every member gets DM; Settings status lines
# ------------------------------------------------------------------------------------------------------------------
@R.case
def leader_enables_in_settings_every_member_gets_dm():
    p = Party()
    w = p.w
    for n in NAMES:
        assert not active(p[n]) and channel(p[n]) is None, n
    open_settings(p["Carol"])
    w.tick(0.3)
    assert settings_status(p["Carol"]) == "Status: Inactive (not turned on for this party)", settings_status(p["Carol"])
    log0 = len(w.addon_log)
    enable_via_settings(p, "Alice")
    dm = msgs_of_type(w, "DM", log0)
    assert len(dm) == 1 and dm[0]["_sender"] == key("Alice") and dm[0]["on"] is True, dm
    assert dm[0]["_chat_type"] == "PARTY", dm
    for n in NAMES:
        assert active(p[n]) is True and channel(p[n]) == "PARTY", n
        assert changed(p[n]) and changed(p[n])[-1] is True, (n, changed(p[n]))
    for n in NAMES[1:]:
        assert enabled_by(p[n]) == key("Alice"), (n, enabled_by(p[n]))
        lines = [strip_codes(l) for l in printed_lines(p[n])]
        want = "DisasterZone: dungeon mode enabled by Alice (5-man loot sharing & rolls)"
        assert lines.count(want) == 1, (n, lines[-4:])
        # the member's own setting stays off: the switch is the group's
        assert p[n].eval("return ns.DB:GetSetting('dungeon.enabled')") is False, n
    assert settings_status(p["Alice"]) == "Status: Active — enabled by you", settings_status(p["Alice"])
    assert settings_status(p["Carol"]) == "Status: Active — enabled by Alice", settings_status(p["Carol"])
    # the roll / drop traffic of every member now uses PARTY
    assert p["Alice"].eval("return ns.Roll:CanStart()") is True
    assert p["Carol"].eval("return ns.Roll:CanStart()") is False
    # the enabler re-sends at most once per party change (debounced), not on every roster event
    log1 = len(w.addon_log)
    for _ in range(3):
        p["Alice"].fire("GROUP_ROSTER_UPDATE")
        w.tick(0.5)
    w.tick(5)
    assert len(sent_by(w, "DM", "Alice", log1)) <= 1, sent_by(w, "DM", "Alice", log1)
    # unticking it tells the party too
    log2 = len(w.addon_log)
    enable_via_settings(p, "Alice")
    dm = sent_by(w, "DM", "Alice", log2)
    assert [m["on"] for m in dm] == [False], dm
    for n in NAMES:
        assert not active(p[n]) and channel(p[n]) is None, n
    assert settings_status(p["Carol"]) == "Status: Inactive (not turned on for this party)"
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# §22.2 drops: D on PARTY from a dungeon boss GUID, panel for council + leader, personal toasts
# ------------------------------------------------------------------------------------------------------------------
@R.case
def dungeon_boss_loot_is_shared_on_party_with_panel_and_toasts():
    p = Party()
    w = p.w
    enable_via_settings(p, "Alice")
    log0 = len(w.addon_log)
    p["Alice"].open_loot([(COWL, 3), (BREECHES, 3), (GREEN, 2)], source_guid=AEONUS_H_GUID)
    w.tick(3)
    D = msgs_of_type(w, "D", log0)
    assert len(D) == 1 and D[0]["_chat_type"] == "PARTY" and D[0]["_sender"] == key("Alice"), D
    assert D[0]["b"] == "BlackMorass:Aeonus" and D[0]["s"] == AEONUS_H_GUID, D
    assert sorted(D[0]["i"]) == sorted([COWL, BREECHES]), "the rare items only (not the green pattern): %r" % D[0]["i"]
    for n in NAMES:
        hist = drop_history(p[n])
        assert len(hist) == 1 and hist[0]["b"] == "BlackMorass:Aeonus", (n, hist)
    # council (Alice = leader + GM, Bob = officer) get the panel with the boss name; plain members do not
    for n in ("Alice", "Bob"):
        assert panel_shown(p[n]), n
        title, sub = panel_header(p[n])
        assert title == "Aeonus" and sub.startswith("The Black Morass (5-man)"), (n, title, sub)
        items = sorted(b["item"] for b in panel_blocks(p[n]))
        assert items == sorted([COWL, BREECHES]), (n, items)
    blk = block_info(p["Alice"], BREECHES)
    assert blk["names"] == [key("Dave"), key("Bob")], blk          # main before alt
    for n in ("Carol", "Dave", "Erin"):
        assert not panel_shown(p[n]), n
    # personal toasts and chat lines work as in raids
    for n, item in (("Erin", COWL), ("Dave", BREECHES)):
        t = toast_state(p[n])
        assert t["shown"] and t["item"] == item, (n, t)
        assert any("is on your BiS list" in strip_codes(l) for l in printed_lines(p[n])), n
    assert not toast_state(p["Carol"])["shown"]
    # the same corpse looted by a second member is not shared again
    log1 = len(w.addon_log)
    p["Alice"].close_loot()
    p["Bob"].open_loot([(COWL, 3), (BREECHES, 3)], source_guid=AEONUS_H_GUID)
    w.tick(3)
    assert msgs_of_type(w, "D", log1) == []
    assert len(drop_history(p["Carol"])) == 1
    w.assert_no_errors()


@R.case
def drop_panel_names_the_dungeon_boss_from_its_guid():
    p = Party(bis={}, sync=False)
    w = p.w
    A = p["Alice"]
    enable_via_settings(p, "Alice")
    cases = [
        (AEONUS_GUID, [COWL], "Aeonus", "The Black Morass (5-man)", "BlackMorass:Aeonus"),
        (DEJA_H_GUID, [BURNOOSE], "Chrono Lord Deja", "The Black Morass (5-man)", "BlackMorass:Deja"),
        (TEMPORUS_GUID, [KILT], "Temporus", "The Black Morass (5-man)", "BlackMorass:Temporus"),
        (NAZAN_CHEST_GUID, [SCARAB], "Nazan & Vazruden", "Hellfire Ramparts (5-man)", "HellfireRamparts:NazanVazruden"),
        (IKISS_COFFER_GUID, [MANA_CROWN], "Talon King Ikiss", "Sethekk Halls (5-man)", "SethekkHalls:Ikiss"),
    ]
    for guid, items, boss, where, bkey in cases:
        log0 = len(w.addon_log)
        A.open_loot([(i, 3) for i in items], source_guid=guid)
        w.tick(3)
        A.close_loot()
        title, sub = panel_header(A)
        assert title == boss and sub.startswith(where), (guid, title, sub)
        D = msgs_of_type(w, "D", log0)
        assert len(D) == 1 and D[0]["b"] == bkey, (guid, D)
        title, sub = panel_header(p["Bob"])
        assert title == boss and sub.startswith(where), ("Bob", guid, title, sub)
    # DisasterZone 0.5: a creature that is no mapped boss, right after a kill, counts as that kill's loot only when the item
    # is on that boss's loot list (the Scarab is an Aeonus drop); other trash loot is never filed under the last boss
    # (see tests/regressions/test_final_review.py); a raid GUID still names the raid boss
    A.open_loot([(COWL, 3)], source_guid=AEONUS_GUID.replace("00000A1", "00000B1"))
    w.tick(3)
    A.close_loot()
    A.open_loot([(SCARAB, 3)], source_guid=TRASH_GUID)
    w.tick(3)
    A.close_loot()
    assert panel_header(A)[0] == "Aeonus", panel_header(A)
    assert A.eval("return ns.ItemDB:GetBossBySourceGUID(...).boss.name", PRINCE_GUID) == "Prince Malchezaar"
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# §22.2 rolls: a party roll through the drop panel, award -> ledger dg, Loot Log "(dungeon)"
# ------------------------------------------------------------------------------------------------------------------
@R.case
def party_roll_through_the_panel_awards_a_dungeon_ledger_entry():
    p = Party()
    w = p.w
    A = p["Alice"]
    enable_via_settings(p, "Alice")
    A.open_loot([(COWL, 3), (BREECHES, 3)], source_guid=AEONUS_H_GUID)
    w.tick(3)
    log0, chat0 = len(w.addon_log), len(w.chat_log)
    b = block(A, COWL)
    assert b is not None and "Roll" in block_info(A, COWL)["buttons"], block_info(A, COWL)
    A.click(A.eval("local b = ...; return b.rollBtn", b))
    w.tick(1)
    RS = msgs_of_type(w, "RS", log0)
    assert len(RS) == 1 and RS[0]["_chat_type"] == "PARTY" and RS[0]["i"] == COWL and RS[0]["b"] == "BlackMorass:Aeonus", RS
    sid = RS[0]["id"]
    for n in NAMES:
        st = rollframe_state(p[n])
        assert st["shown"] and st["id"] == sid and st["rollShown"] and st["passShown"], (n, st)
    assert "BiS Head · P1" in strip_codes(rollframe_state(p["Erin"])["bis"]), rollframe_state(p["Erin"])
    ann = [e for e in w.chat_log[chat0:] if "Roll for" in e["text"]]
    assert len(ann) == 1 and ann[0]["chat_type"] == "PARTY", ann
    # Erin (BiS) rolls low, Carol (no BiS) high, Dave passes; party members see each other's rolls
    click_popup_roll(p, "Erin", 40)
    click_popup_roll(p, "Carol", 90)
    click_popup_pass(p, "Dave")
    w.tick(1)
    RR = msgs_of_type(w, "RR", log0)
    assert len(RR) == 3 and {m["_chat_type"] for m in RR} == {"PARTY"}, RR
    for n in NAMES:
        s = session_info(p[n], sid)
        assert s["rolls"][key("Erin")]["roll"] == 40 and s["rolls"][key("Carol")]["roll"] == 90, (n, s["rolls"])
        assert s["responses"].get(key("Dave")) == "pass", n
    A.click(A.eval("local b = ...; return b.endRoll", block(A, COWL)))
    w.tick(1)
    assert [m["_chat_type"] for m in msgs_of_type(w, "RE", log0)] == ["PARTY"]
    res = results(A, sid)
    assert res[0]["key"] == key("Erin") and res[0]["suggested"] and res[0]["tier"] == 1, res
    assert results(p["Bob"], sid)[0]["key"] == key("Erin"), "council clients agree on the suggestion"
    w.tick(0.3)
    blk = block_info(A, COWL)
    assert "Award to Erin" in blk["buttons"], blk
    # party loot is group loot: the award is confirmed (no master-loot hand-out)
    A.click(A.eval("local b = ...; return b.awardRoll", block(A, COWL)))
    w.tick(0.2)
    assert A.popups() == ["DISASTERZONE_CONFIRM_AWARD"], A.popups()
    A.accept_popup("DISASTERZONE_CONFIRM_AWARD")
    w.tick(1)
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["_chat_type"] == "PARTY" and RW[0]["w"] == key("Erin"), RW
    for n in ("Bob", "Carol", "Dave"):
        assert strip_codes(rollframe_state(p[n])["status"]) == "Won by Erin", (n, rollframe_state(p[n]))
    assert strip_codes(rollframe_state(p["Erin"])["status"]) == "You won it!", rollframe_state(p["Erin"])
    lines = [e for e in w.chat_log[chat0:] if "->" in e["text"]]
    assert len(lines) == 1 and lines[0]["chat_type"] == "PARTY", lines
    assert strip_codes(lines[0]["text"]) == "DisasterZone: [Cowl of the Guiltless] -> Erin (rolled 40, BiS)", lines[0]
    w.tick(6.5)
    for n in NAMES:
        assert not rollframe_state(p[n])["shown"], (n, rollframe_state(p[n]))
    # the one ledger entry, on both council clients, is dungeon loot
    for n in ("Alice", "Bob"):
        rows = [e for e in ledger_rows(p[n]) if e["i"] == COWL]
        assert len(rows) == 1 and rows[0]["w"] == key("Erin") and rows[0]["dg"] is True, (n, rows)
        assert rows[0]["b"] == "BlackMorass:Aeonus" and rows[0]["s"] == "m", rows
        assert p[n].eval("return ns.Ledger:CountSince(..., 0)", key("Erin")) == 0, "dungeon loot is not 'won tonight'"
        assert p[n].eval("return ns.Ledger:CountSince(..., 0, true)", key("Erin")) == 1
    # Loot Log: grey "(dungeon)" tag, "Show dungeon loot" hides it
    open_loot_log(A)
    w.tick(0.5)
    rows = loot_log_rows(A)
    assert len(rows) == 1 and rows[0][1].endswith("(dungeon)"), rows
    cb = A.eval("return T_checkbox(DisasterZoneLootLogPanel, 'Show dungeon loot')")
    assert cb is not None and A.eval("local b = ...; return b:GetChecked() and true or false", cb) is True
    A.click(cb)
    w.tick(0.3)
    assert loot_log_rows(A) == [], loot_log_rows(A)
    A.click(cb)
    w.tick(0.3)
    assert len(loot_log_rows(A)) == 1
    # the hand-out's loot line later resolves nothing new and keeps one visible entry
    w.broadcast_loot_received(p["Erin"], COWL)
    w.tick(1)
    for n in ("Alice", "Bob"):
        vis = [e for e in ledger_visible(p[n]) if e["i"] == COWL]
        assert len(vis) == 1, (n, vis)
    w.assert_no_errors()


@R.case
def non_council_party_leader_runs_the_panel_and_rolls():
    roster = [("Carol", "WARRIOR", 3), ("Alice", "PALADIN", 0), ("Bob", "MAGE", 1), ("Dave", "PRIEST", 3),
              ("Erin", "ROGUE", 3)]
    p = Party(roster=roster, leader="Carol")
    w = p.w
    C = p["Carol"]
    log0 = len(w.addon_log)
    C.slash("/dz dungeon on")
    w.tick(1.5)
    assert len(sent_by(w, "DM", "Carol", log0)) == 1, "the party leader may tell the party"
    for n in NAMES:
        assert active(p[n]), n
    C.open_loot([(COWL, 3)], source_guid=AEONUS_GUID)
    w.tick(3)
    shown = {n: panel_shown(p[n]) for n in NAMES}
    assert shown == {"Alice": True, "Bob": True, "Carol": True, "Dave": False, "Erin": False}, shown
    assert C.eval("return ns.Roll:CanStart()") is True and p["Dave"].eval("return ns.Roll:CanStart()") is False
    C.click(C.eval("local b = ...; return b.rollBtn", block(C, COWL)))
    w.tick(1)
    sid = active_session(C)["id"]
    click_popup_roll(p, "Erin", 22)
    click_popup_roll(p, "Dave", 77)
    w.tick(1)
    C.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    # Carol holds no lists: the council whispers her the BiS tiers (RT), so her suggestion follows BiS
    rt = [m for m in msgs_of_type(w, "RT", log0) if m["id"] == sid]
    assert rt and rt[0]["_chat_type"] == "WHISPER", rt
    assert results(C, sid)[0]["key"] == key("Erin"), results(C, sid)
    C.eval("ns.Roll:Award(...)", sid, key("Erin"))
    w.tick(0.2)
    C.accept_popup("DISASTERZONE_CONFIRM_AWARD")
    w.tick(1.5)
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["_sender"] == key("Carol") and RW[0]["_chat_type"] == "PARTY", RW
    # Carol cannot write the ledger; the council clients record the RW (one shared entry, dg)
    assert ledger_rows(C) == []
    for n in ("Alice", "Bob"):
        rows = [e for e in ledger_rows(p[n]) if e["i"] == COWL]
        assert len(rows) == 1 and rows[0]["dg"] is True and rows[0]["w"] == key("Erin"), (n, rows)
    assert ledger_rows(p["Alice"])[0]["id"] == ledger_rows(p["Bob"])[0]["id"]
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# §22.1 the switch clears: disband, raid conversion, the enabler leaving; a plain member cannot enable it
# ------------------------------------------------------------------------------------------------------------------
@R.case
def disband_clears_dungeon_mode_and_closes_rolls():
    p = Party()
    w = p.w
    A = p["Alice"]
    enable_via_settings(p, "Alice")
    A.open_loot([(SCARAB, 3)], source_guid=TEMPORUS_GUID)
    w.tick(3)
    A.eval("ns.DropPanel:StartRoll(...)", SCARAB, 1)
    w.tick(1)
    sid = active_session(A)["id"]
    assert rollframe_state(p["Dave"])["shown"]
    w.disband()
    w.tick(1.5)
    for n in NAMES:
        assert not active(p[n]) and channel(p[n]) is None, n
        assert enabled_by(p[n]) is None, n
        assert changed(p[n])[-1] is False, (n, changed(p[n]))
        assert session_info(p[n], sid)["state"] == "closed", n
        assert not rollframe_state(p[n])["shown"], (n, rollframe_state(p[n]))
    for n in ("Bob", "Carol"):
        assert settings_status(p[n]) == "Status: Inactive (not in a 5-man party)", settings_status(p[n])
    # the enabler's own setting stays: a new party with her as leader gets it again
    assert A.eval("return ns.DB:GetSetting('dungeon.enabled')") is True
    log0 = len(w.addon_log)
    p.form("Alice", ["Alice", "Bob", "Carol"])
    w.tick(5)
    assert sent_by(w, "DM", "Alice", log0), "no DM to the new party"
    for n in ("Alice", "Bob", "Carol"):
        assert active(p[n]), n
    for n in ("Dave", "Erin"):
        assert not active(p[n]), n
    # the group becomes a raid: raid rules, the 5-man switch is gone
    w.make_raid([p[n] for n in NAMES], leader=A)
    w.tick(1.5)
    for n in NAMES:
        assert not active(p[n]) and channel(p[n]) == "RAID", n
        assert enabled_by(p[n]) is None, n
    assert settings_status(p["Bob"]) == "Status: Inactive (in a raid: raid rules apply)", settings_status(p["Bob"])
    w.assert_no_errors()


# Addendum D §24 / E §33 parties: the leader Carol is a plain member, Bob (on the GM's guild council list) is the
# only council member -> Bob is the party's loot authority until the leader turns dungeon mode on herself.
BOB_DECIDES = [("Carol", "WARRIOR", 3), ("Alice", "PALADIN", 2), ("Bob", "MAGE", 1), ("Dave", "PRIEST", 3),
               ("Erin", "ROGUE", 3)]
# Nobody on the council list: without a leader who turned dungeon mode on there is no loot authority.
NO_COUNCIL = [("Carol", "WARRIOR", 3), ("Alice", "PALADIN", 2), ("Bob", "MAGE", 2), ("Dave", "PRIEST", 3),
              ("Erin", "ROGUE", 3)]


def authority(c):
    return c.eval("return ns.GroupRules:GetAuthority()")


@R.case
def enabler_leaving_the_party_clears_it():
    p = Party(roster=BOB_DECIDES, leader="Carol", sync=False)
    w = p.w
    w.tick(8)
    assert authority(p["Dave"]) == key("Bob")
    p["Bob"].slash("/dz dungeon on")          # council, not the leader: the party's loot authority
    w.tick(1.5)
    for n in NAMES:
        assert active(p[n]), n
    assert enabled_by(p["Dave"]) == key("Bob")
    p.form("Carol", ["Carol", "Alice", "Dave", "Erin"])     # Bob leaves: no authority is left
    w.tick(1.5)
    for n in ("Alice", "Carol", "Dave", "Erin"):
        assert not active(p[n]) and enabled_by(p[n]) is None, n
        assert p[n].eval("return ns.GroupRules:GetStatus()") == "own", n
    w.assert_no_errors()


@R.case
def enabler_who_passed_the_lead_no_longer_decides():
    """Addendum D §24/§26: a non-council leader decides for the party (as its loot authority) only while she leads
    it with dungeon mode on. Passing the lead on hands the rules to the next eligible authority; without one
    everybody is back on their own settings. The old enabler can neither keep nor turn it on for the others
    afterwards, and forged "off" messages from non-authorities change nothing."""
    p = Party(roster=NO_COUNCIL, leader="Carol", bis={}, sync=False)
    w = p.w
    w.tick(8)
    assert authority(p["Dave"]) is None
    p["Carol"].slash("/dz dungeon on")          # non-council party leader: becomes the loot authority
    w.tick(1.5)
    assert all(active(p[n]) for n in NAMES)
    assert authority(p["Erin"]) == key("Carol")
    p.form("Dave", ["Carol", "Alice", "Bob", "Dave", "Erin"])     # the lead goes to Dave, Carol stays
    w.tick(5)
    for n in ("Alice", "Bob", "Dave", "Erin"):
        assert authority(p[n]) is None, (n, authority(p[n]))
        assert not active(p[n]), "%s: the former leader's rules must not outlive her lead" % n
    assert active(p["Carol"]), "her own setting still applies to her own client"
    # she is no longer the leader nor council: she cannot turn it on for the party again
    log1 = len(w.addon_log)
    p["Carol"].slash("/dz dungeon off")
    p["Carol"].slash("/dz dungeon on")
    w.tick(1.5)
    assert [m for m in sent_by(w, "DM", "Carol", log1) if m["on"]] == []
    assert sent_by(w, "GS", "Carol", log1) == []
    assert active(p["Carol"]) and not active(p["Erin"])
    # the new leader turns it on: he decides now; forged "off" messages from others change nothing
    p["Dave"].slash("/dz dungeon on")
    w.tick(1.5)
    assert active(p["Erin"]) and enabled_by(p["Erin"]) == key("Dave")
    assert authority(p["Erin"]) == key("Dave")
    p["Erin"].eval("ns.Comm:Send({ t = 'DM', on = false }, 'PARTY', nil, 'alert')")
    p["Carol"].eval("ns.Comm:Send({ t = 'DM', on = false }, 'PARTY', nil, 'alert')")
    w.tick(1)
    for n in ("Alice", "Bob", "Carol", "Erin"):
        assert active(p[n]) and enabled_by(p[n]) == key("Dave"), n
    w.assert_no_errors()


@R.case
def plain_member_cannot_enable_it_for_the_party():
    p = Party()
    w = p.w
    w.tick(5)                                          # the GM leader's group rules reached everyone
    C = p["Carol"]                                     # rank 3, not the leader, not council
    log0 = len(w.addon_log)
    open_settings(C)
    w.tick(0.3)
    # Addendum D §27: while the loot authority (Alice) sets the rules, the control is read-only for her
    cb = C.eval("return T_checkbox(T_settings(), ...)", ENABLE_LABEL)
    assert cb is not None
    assert C.eval("local b = ...; return b:IsEnabled()", cb) is False, "the dungeon mode control must be read-only"
    status = strip_codes(C.eval("return ns.SettingsUI.rulesStatus:GetText()"))
    assert status.startswith("Set by Alice for this group"), status
    C.click(cb)                                        # a disabled checkbox does nothing
    w.tick(1)
    assert C.eval("return ns.DB:GetSetting('dungeon.enabled')") is False
    assert sent_by(w, "DM", "Carol", log0) == [], "a plain member must not tell the party"
    for n in NAMES:
        assert not active(p[n]) and enabled_by(p[n]) is None, n
    # a forged DM from her is dropped by the gate (not leader, not council)
    C.eval("ns.Comm:Send({ t = 'DM', on = true }, 'PARTY', nil, 'alert')")
    w.tick(1)
    assert len(sent_by(w, "DM", "Carol", log0)) == 1
    for n in ("Alice", "Bob", "Dave", "Erin"):
        assert not active(p[n]), n
    # in a party without a loot authority her switch works for her own client only: her drops go out on PARTY
    # but nobody else takes them, and she cannot start rolls
    q = Party(roster=NO_COUNCIL, leader="Dave", bis={}, sync=False, instance=True)
    q.w.tick(8)
    Q = q["Carol"]
    qlog = len(q.w.addon_log)
    open_settings(Q)
    q.w.tick(0.3)
    enable_via_settings(q, "Carol")
    assert sent_by(q.w, "DM", "Carol", qlog) == [] and sent_by(q.w, "GS", "Carol", qlog) == []
    assert active(Q) is True
    assert settings_status(Q) == "Status: Active — enabled by you (only for you)", settings_status(Q)
    for n in ("Alice", "Bob", "Dave", "Erin"):
        assert not active(q[n]) and enabled_by(q[n]) is None, n
    Q.open_loot([(COWL, 3)], source_guid=AEONUS_GUID)
    q.w.tick(3)
    D = msgs_of_type(q.w, "D", qlog)
    assert len(D) == 1 and D[0]["_sender"] == key("Carol") and D[0]["_chat_type"] == "PARTY", D
    for n in ("Alice", "Bob", "Dave", "Erin"):
        assert drop_history(q[n]) == [], n
    assert not panel_shown(Q), "Carol is neither council nor the leader"
    assert Q.eval("return ns.Roll:CanStart()") is False
    q.w.assert_no_errors()
    # a forged RS from her is ignored even by clients that have the mode on
    p["Alice"].slash("/dz dungeon on")
    w.tick(1.5)
    C.eval("ns.Comm:Send({ t = 'RS', id = 'Carol-1-1', i = %d, s = '', b = '', d = 30, ts = GetServerTime(), c = 1 }, 'PARTY', nil, 'alert')" % COWL)
    w.tick(1)
    for n in ("Alice", "Bob", "Erin"):
        assert p[n].eval("return ns.Roll:Get('Carol-1-1') == nil"), n
        assert not rollframe_state(p[n])["shown"], n
    w.assert_no_errors()


@R.case
def mode_off_party_drop_is_not_broadcast():
    p = Party()
    w = p.w
    log0 = len(w.addon_log)
    p["Alice"].open_loot([(COWL, 3), (BREECHES, 4)], source_guid=AEONUS_H_GUID)
    w.tick(3)
    assert msgs_of_type(w, "D", log0) == [], "nothing is broadcast without dungeon mode"
    for n in NAMES[1:]:
        assert drop_history(p[n]) == [], n
        assert not panel_shown(p[n]), n
    # local only: the looter's own drop uses the raid threshold (epic), so the rare cowl is not tracked
    hist = drop_history(p["Alice"])
    assert len(hist) == 1 and hist[0]["i"] == [BREECHES], hist
    # Erin opens loot herself: her own toast still works (local personal alert), nobody else hears of it
    p["Alice"].close_loot()
    p["Erin"].open_loot([(COWL, 4)], source_guid=AEONUS_GUID)
    w.tick(3)
    assert msgs_of_type(w, "D", log0) == []
    t = toast_state(p["Erin"])
    assert t["shown"] and t["item"] == COWL, t
    assert all(drop_history(p[n]) == [] for n in ("Bob", "Carol", "Dave"))
    # no rolls in a party without the mode
    assert p["Alice"].eval("return ns.Roll:CanStart()") is False
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Quality rules: rare inside a 5-man with the mode active, epic elsewhere; the Settings quality dropdown
# ------------------------------------------------------------------------------------------------------------------
@R.case
def quality_threshold_rare_in_dungeon_only_when_active_epic_elsewhere():
    p = Party(bis={}, sync=False, instance=False)
    w = p.w
    A = p["Alice"]
    n = [0]

    def loot(items, guid_base=AEONUS_GUID):
        """Alice loots a fresh corpse; returns the item ids broadcast (D) and her own tracked drop."""
        n[0] += 1
        guid = guid_base[:-2] + "%02d" % n[0]
        log0 = len(w.addon_log)
        A.open_loot(items, source_guid=guid)
        w.tick(3)
        A.close_loot()
        D = msgs_of_type(w, "D", log0)
        mine = [d for d in drop_history(A) if d["s"] == guid]
        return (sorted(D[0]["i"]) if D else None), (sorted(mine[0]["i"]) if mine else None)

    RARE, EPIC = (COWL, 3), (RUBY_DRAPE, 4)
    # 1. open world party, mode active: the raid threshold (epic) applies, the drop still goes on PARTY
    A.slash("/dz dungeon on")
    w.tick(1.5)
    assert active(A) and not A.eval("return ns.Util.InPartyInstance()")
    assert loot([RARE, EPIC]) == ([RUBY_DRAPE], [RUBY_DRAPE])
    # 2. inside a 5-man, mode active, dungeon quality Rare (default): the rare item triggers
    w.enter_instance(BM_NAME, BM_ID, "party", 5, 2)
    w.tick(1)
    assert loot([RARE, EPIC, (GREEN, 2)]) == (sorted([COWL, RUBY_DRAPE]), sorted([COWL, RUBY_DRAPE]))
    # 3. dungeon quality Epic (Settings dropdown): only the epic
    open_settings(A)
    w.tick(0.3)
    dd = A.eval("""for _, f in ipairs(T_dropdown_list(T_settings())) do
        local m = T_menu(f)
        if m and m.children[1] and m.children[1].text == 'Rare' then return f end end""")
    assert dd is not None, "no Rare / Epic dropdown in the Settings panel"
    A.dropdown_menu(dd)
    A.menu_select("Epic")
    w.tick(0.3)
    assert A.eval("return ns.DB:GetSetting('dungeon.quality')") == 4
    assert loot([RARE, EPIC]) == ([RUBY_DRAPE], [RUBY_DRAPE])
    A.dropdown_menu(dd)
    A.menu_select("Rare")
    w.tick(0.3)
    assert A.eval("return ns.DB:GetSetting('dungeon.quality')") == 3
    # 4. inside the 5-man with the mode off: nothing is broadcast, the local drop uses epic
    A.slash("/dz dungeon off")
    w.tick(1.5)
    assert not active(A)
    assert loot([RARE, EPIC]) == (None, [RUBY_DRAPE])
    # 5. a raid in a raid instance with the dungeon setting on: raid rules (epic), D on RAID
    A.slash("/dz dungeon on")
    w.make_raid(p.clients, leader=A)
    w.tick(1)
    w.enter_instance("Karazhan", 532)
    w.tick(1)
    log0 = len(w.addon_log)
    assert loot([RARE, EPIC], PRINCE_GUID) == ([RUBY_DRAPE], [RUBY_DRAPE])
    assert {m["_chat_type"] for m in msgs_of_type(w, "D", log0)} == {"RAID"}
    w.assert_no_errors()


@R.case
def council_auto_record_in_a_dungeon_is_dungeon_loot():
    p = Party()
    w = p.w
    enable_via_settings(p, "Alice")
    w.broadcast_loot_received(p["Dave"], BREECHES)          # a rare handed out by group loot
    w.tick(1)
    for n in ("Alice", "Bob"):
        rows = ledger_rows(p[n])
        assert len(rows) == 1 and rows[0]["s"] == "a" and rows[0]["dg"] is True and rows[0]["w"] == key("Dave"), (n, rows)
    assert ledger_rows(p["Carol"]) == [], "only council clients record"
    # without the mode, a 5-man loot line is not recorded (raid instances only)
    enable_via_settings(p, "Alice")
    w.broadcast_loot_received(p["Erin"], COWL)
    w.tick(1)
    assert len(ledger_rows(p["Alice"])) == 1
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# §22.3 /dz test inside a 5-man
# ------------------------------------------------------------------------------------------------------------------
@R.case
def cdl_test_in_a_dungeon_simulates_that_dungeon():
    p = Party(sync=False)
    w = p.w
    A = p["Alice"]
    enable_via_settings(p, "Alice")
    log0 = len(w.addon_log)
    A.slash("/dz test")
    w.tick(1)
    drop = drops_fired(A)[-1]
    assert drop["test"] and drop["b"].startswith("BlackMorass:"), drop
    assert 2 <= len(drop["i"]) <= 3, drop
    heroic = A.eval_py("local r = ns.ItemDB:GetBossRef(...); local o = {} for _, id in ipairs(r.boss.heroicItems) do o[#o + 1] = id end return o", drop["b"])
    assert all(i in heroic for i in drop["i"]), (drop, heroic)
    title, sub = panel_header(A)
    assert title == A.eval("return ns.ItemDB:GetBossRef(...).boss.name", drop["b"]) and "The Black Morass (5-man)" in sub, (title, sub)
    assert "simulated" in sub, sub
    assert msgs_of_type(w, "D", log0) == [], "test drops stay local"
    assert any("Simulated a dungeon drop" in l and "Heroic" in l for l in printed_lines(A))
    assert drop_history(p["Bob"]) == []
    # another dungeon: that dungeon's bosses
    w.enter_instance("Hellfire Ramparts", 543, "party", 5, 2)
    w.tick(1)
    A.slash("/dz test")
    w.tick(1)
    assert drops_fired(A)[-1]["b"].startswith("HellfireRamparts:"), drops_fired(A)[-1]
    # mode off: the raid simulation as before
    enable_via_settings(p, "Alice")
    A.slash("/dz test")
    w.tick(1)
    b = drops_fired(A)[-1]["b"]
    assert A.eval("return ns.ItemDB:GetBossRef(...).dungeon == nil", b), b
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# §21.2 / §21.3 picker dungeon scopes: candidates per slot and class, heroic tags, headers
# ------------------------------------------------------------------------------------------------------------------
CANDS = r"""
  local sid, f = ...
  local out = {}
  for _, r in ipairs(ns.ItemDB:GetCandidates(sid, f)) do
    out[#out + 1] = { r.itemID, r.ref.key, r.ref.dungeon and true or false, r.heroic and true or false }
  end
  return out"""

PICKER_DATA = r"""
local out = {}
for i, d in ipairs(T_data(T_box(DisasterZonePicker))) do
  out[i] = { d.type, d.name or '', d.itemID or 0, (d.ref and d.ref.dungeon) and 1 or 0, d.heroic and 1 or 0 }
end
return out"""

# The Sources checkbox dropdown (Addendum F §35): the picker dropdown that is not the phase dropdown ('-').
SOURCES_DD = "return T_multi_dropdown(DisasterZonePicker)"

PICKER_SUBS = r"""
local out = {}
for _, r in ipairs(T_rows(T_box(DisasterZonePicker))) do
  local d = rawget(r, '__cdlData')
  if d and d.type == 'item' then out[#out + 1] = { d.itemID, d.heroic and 1 or 0, r.sub:GetText() or '' } end
end
return out"""


def cands(c, sid, cls, scope):
    f = {"class": cls, "usableOnly": True, "primaryArmorOnly": True, "maxPhase": 1, "includeTrash": True}
    if scope:
        f["scope"] = scope
    return {r[0]: r for r in (c.eval_py(CANDS, sid, f) or [])}


@R.case
def item_db_dungeon_candidates_by_slot_and_class():
    w = World()
    mage = Client(w, "Mia", class_file="MAGE", guild_rank=3)
    war = Client(w, "Wes", class_file="WARRIOR", guild_rank=3)
    for c in (mage, war):
        c.load_addon()
    w.tick(2)
    # legs: the mage gets the heroic-only cloth breeches (tagged) and the normal kilt; the warrior plate legs
    m = cands(mage, SID_LEGS, "MAGE", "dungeons")
    assert m[BREECHES][1:] == ["BlackMorass:Aeonus", True, True], m.get(BREECHES)
    assert m[KILT][1:] == ["BlackMorass:Temporus", True, False], m.get(KILT)
    assert LEGPLATES not in m, "plate is not a mage's armor"
    wl = cands(war, SID_LEGS, "WARRIOR", "dungeons")
    assert wl[LEGPLATES][1:] == ["BlackMorass:Aeonus", True, False], wl.get(LEGPLATES)
    assert BREECHES not in wl and KILT not in wl, "cloth is filtered for a warrior (primary armor only)"
    # head: cloth crown for the mage, the leather cowl for nobody here
    mh = cands(mage, SID_HEAD, "MAGE", "dungeons")
    assert mh[MANA_CROWN][2] is True and COWL not in mh, sorted(mh)[:10]
    # 2H: the heroic-only Quantum Blade (warrior main hand), not for a mage
    w15 = cands(war, SID_MH, "WARRIOR", "dungeons")
    assert w15[QUANTUM][3] is True, w15.get(QUANTUM)
    assert QUANTUM not in cands(mage, SID_MH, "MAGE", "dungeons")
    # trinket / cloak fit every class
    for c, cls in ((mage, "MAGE"), (war, "WARRIOR")):
        assert SCARAB in cands(c, 13, cls, "dungeons") and BURNOOSE in cands(c, SID_BACK, cls, "dungeons"), cls
    # the default scope is raids only; "all" = raids first, then the 5-man rows not already listed
    for c, cls, sid in ((mage, "MAGE", SID_LEGS), (war, "WARRIOR", SID_MH), (mage, "MAGE", 13)):
        raids = cands(c, sid, cls, None)
        assert raids == cands(c, sid, cls, "raids") and raids and not any(r[2] for r in raids.values()), (cls, sid)
        both = c.eval_py(CANDS, sid, {"class": cls, "usableOnly": True, "primaryArmorOnly": True, "maxPhase": 1, "scope": "all"})
        split = next((i for i, r in enumerate(both) if r[2]), len(both))
        assert all(not r[2] for r in both[:split]) and all(r[2] for r in both[split:]), (cls, sid)
        assert {r[0] for r in both} == set(raids) | set(cands(c, sid, cls, "dungeons")), (cls, sid)
    # Magisters' Terrace (phase 5) only shows once phase 5 is allowed
    mgt = [r for r in (mage.eval_py(CANDS, 13, {"scope": "dungeons", "phase": 5}) or [])]
    assert mgt and all(r[1].startswith("MagistersTerrace:") for r in mgt), mgt[:3]
    assert not any(r[1].startswith("MagistersTerrace:") for r in cands(mage, 13, "MAGE", "dungeons").values())
    w.assert_no_errors()


@R.case
def picker_dungeon_scopes_headers_and_heroic_tag():
    for cls, sids in (("MAGE", (SID_LEGS, SID_HEAD, 13)), ("WARRIOR", (SID_LEGS, SID_MH, SID_BACK))):
        w, c = bu.solo("Alice", class_file=cls, guild_rank=3, tick=3)
        bu.install_helpers(c)
        c.slash("/dz bis")
        w.tick(0.3)
        for sid in sids:
            c.click(c.eval("local s = ...; return T_tile(s).main", sid))
            # Addendum F §35: the scope dropdown became a Sources checkbox dropdown (default Raids + 5-man)
            sdd = c.eval(SOURCES_DD)
            assert sdd is not None, "no Sources dropdown"
            texts = [e[2] for e in bu.menu_texts(c.dropdown_menu(sdd))]
            assert "Raids" in texts and "5-man dungeons" in texts, texts
            assert c.eval_py("return ns.Picker:GetSources()")["dungeons"] is True, "5-man dungeons ticked by default"
            c.menu_select("Raids")                      # untick Raids: 5-man dungeons only
            c.eval("ns.Picker:Rebuild(true)")
            rows = c.eval_py(PICKER_DATA) or []
            items = [x for x in rows if x[0] == "item"]
            heads = [x[1] for x in rows if x[0] == "raid"]
            assert items and all(x[3] == 1 for x in items), (cls, sid, rows[:6])
            assert heads and all(h.endswith(" (5-man)") for h in heads), (cls, sid, heads)
            assert "The Black Morass (5-man)" in heads or sid == SID_HEAD and cls == "WARRIOR", (cls, sid, heads)
            subs = c.eval_py(PICKER_SUBS) or []
            assert subs, (cls, sid)
            for iid, heroic, sub in subs:
                assert ("Heroic" in strip_codes(sub)) == bool(heroic), (cls, sid, iid, heroic, sub)
            if cls == "MAGE" and sid == SID_LEGS:
                tagged = {iid for iid, heroic, sub in subs if "Heroic" in sub}
                assert BREECHES in tagged and KILT not in tagged, tagged
            if cls == "WARRIOR" and sid == SID_MH:
                assert QUANTUM in {iid for iid, heroic, sub in subs if "Heroic" in sub}
            # picking a dungeon item works like any other
            if cls == "MAGE" and sid == SID_LEGS:
                c.eval("ns.Picker:Rebuild(true)")
                row = c.eval("local id = ...; for _, r in ipairs(T_rows(T_box(DisasterZonePicker))) do "
                             "local d = rawget(r, '__cdlData'); if d and d.itemID == id then return r end end", BREECHES)
                assert row is not None
                c.click(row)
                w.tick(0.2)
                assert c.eval("return (ns.BiS:GetSlot(1, ...))", SID_LEGS) == BREECHES
                c.click(c.eval("local s = ...; return T_tile(s).main", sid))
                assert c.eval_py("return ns.Picker:GetSources()")["raids"] is False, "sources kept for the session"
            c.dropdown_menu(sdd)
            c.menu_select("Raids")                      # tick Raids again: raids first, then the 5-man sections
            c.eval("ns.Picker:Rebuild(true)")
            rows = c.eval_py(PICKER_DATA) or []
            heads = [x[1] for x in rows if x[0] == "raid"]
            first5 = next((i for i, h in enumerate(heads) if h.endswith(" (5-man)")), None)
            assert first5 is not None and first5 > 0 and all(h.endswith(" (5-man)") for h in heads[first5:]), heads
            c.dropdown_menu(sdd)
            c.menu_select("5-man dungeons")             # untick 5-man: raids only
            c.eval("ns.Picker:Rebuild(true)")
            rows = c.eval_py(PICKER_DATA) or []
            assert rows and all(x[3] == 0 for x in rows if x[0] == "item"), "raids only lists no 5-man item"
            c.eval("ns.Picker:SetSourceEnabled('dungeons', true)")   # back to the default for the next slot
            c.eval("ns.Picker:Close()")
        w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Council Items tree: 5-man items are counted under "Other / no raid source" (never under hidden dungeon bosses)
# ------------------------------------------------------------------------------------------------------------------
@R.case
def council_items_tree_counts_dungeon_items_under_other():
    p = Party(instance=False)
    w = p.w
    A = p["Alice"]
    A.slash("/dz council")
    A.eval("ns.CouncilUI:SetView('items')")
    w.tick(0.5)
    tree = A.eval_py("local o = {} for i, d in ipairs(T_data(DisasterZoneCouncilPanel.itemsView.tree.box)) do "
                     "o[i] = { d.type, d.name or '', d.count or 0, d.key or '' } end return o") or []
    other = [t for t in tree if t[0] == "other"]
    # Erin's cowl + Dave's and Bob's breeches: 3 claims, all 5-man items
    assert other and other[0][2] == 3, tree
    assert not any(t[3].startswith("BlackMorass:") for t in tree), "a dungeon boss node the tree cannot show"
    prince = [t for t in tree if t[3] == "Karazhan:Prince"]
    assert prince and prince[0][2] >= 1, "Bob's raid cloak is still counted under its raid boss"
    # jumping to a 5-man item opens the Other node with it
    A.eval("ns.CouncilUI:ShowItem(...)", BREECHES)
    w.tick(0.5)
    title = strip_codes(A.eval("return DisasterZoneCouncilPanel.itemsView.title:GetText()"))
    assert title.startswith("Other / no raid source"), title
    ids = A.eval_py("local o = {} for i, d in ipairs(T_data(DisasterZoneCouncilPanel.itemsView.list.box)) do o[i] = d.itemID end return o")
    assert sorted(ids) == sorted([COWL, BREECHES]), ids
    src = strip_codes(A.eval("for _, r in ipairs(T_rows(DisasterZoneCouncilPanel.itemsView.list.box)) do "
                             "local d = rawget(r, 'cdlData'); if d and d.itemID == %d then return r.source:GetText() end end" % BREECHES) or "")
    assert "Aeonus (H)" in src, src
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

#!/usr/bin/env python
"""Dungeon mode, core side (Addendum B §21.2, §22.1-§22.3): 5-man ItemDB data, the DM switch and its gate,
party drops (D on PARTY, 5-man quality threshold), party rolls (RS/RR/RE/RW on PARTY, CanStart gate), ledger dg
entries, /cdl test inside a 5-man, and what must NOT change (party without the mode, raids).

UI parts (RollFrame in a party, drop panel for the party leader, Loot Log tag/filter) are not covered here.

Run: luaenv\\Scripts\\python.exe tests\\dungeon\\test_dungeon_core.py   [-k substring]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "loot-roll"))

from lr_common import *  # noqa: F401,F403,E402

R = Runner("dungeon / core")

BM_ID = 269
AEONUS_GUID = "Creature-0-1-2-3-17881-000AE0"          # normal Aeonus
AEONUS_H_GUID = "Creature-0-1-2-3-20737-000AE1"        # heroic Aeonus
COWL = 28206            # Cowl of the Guiltless: Aeonus normal + heroic list (head)
BREECHES = 30531        # Breeches of the Occultist: Aeonus heroic list only (legs)
QUANTUM = 29356         # Quantum Blade: heroic only (2H)
SCARAB = 28190          # Scarab of the Infinite Cycle (trinket), normal + heroic
GREEN = 25730           # Pattern: Stylin' Jungle Hat (Black Morass trash)
SID_LEGS = 9

PARTY = [
    ("Alice", "PALADIN", 0),   # GM: council, party leader
    ("Bob", "MAGE", 1),        # officer: council
    ("Carol", "WARRIOR", 3),
    ("Dave", "PRIEST", 3),
    ("Erin", "ROGUE", 3),
]
PARTY_BIS = {
    "Erin": [(1, SID_HEAD, "main", COWL)],
    "Dave": [(1, SID_LEGS, "main", BREECHES)],
    "Bob": [(1, SID_LEGS, "alt", BREECHES)],
}
NAMES = [p[0] for p in PARTY]


class FixedRng:
    def __init__(self, value):
        self.value = value

    def randint(self, lo, hi):
        return self.value


class Party:
    def __init__(self, roster=PARTY, bis=PARTY_BIS, leader="Alice", sync=True, instance=True):
        self.w = World()
        self.c = {}
        for name, cls, rank in roster:
            self.c[name] = Client(self.w, name, class_file=cls, guild_rank=rank)
        for cl in self.c.values():
            cl.load_addon()
        install_probes(self.c.values())
        install_dm_probe(self.c.values())
        self.w.tick(2)
        setup_council(self.w, self.c, roster)
        members = [self.c[leader]] + [c for n, c in self.c.items() if n != leader]
        self.w.make_party(members, leader=self.c[leader])
        self.w.tick(1)
        for name, entries in (bis or {}).items():
            seed_bis(self.c[name], entries)
        if sync:
            for cl in self.c.values():
                cl.slash("/cdl sync")
                self.w.tick(0.3)
            self.w.tick(45)
        if instance:
            self.w.enter_instance("The Black Morass", BM_ID, "party", 5, 2)
            self.w.tick(1)

    def __getitem__(self, name):
        return self.c[name]


DM_PROBE = r"""
__DG = __DG or { changed = {} }
if not __DG.hooked then
  __DG.hooked = true
  ns:On("DUNGEON_MODE_CHANGED", function(active) __DG.changed[#__DG.changed + 1] = active and true or false end)
end
"""


def install_dm_probe(clients):
    for c in clients:
        c.eval(DM_PROBE)


def active(c):
    return c.eval("return ns.Util.IsDungeonModeActive()")


def channel(c):
    return c.eval("return ns.Util.GetGroupChannel()")


def enabled_by(c):
    return c.eval("return ns.Dungeon.groupEnabledBy")


def changed(c):
    return c.eval_py("return __DG.changed") or []


def enable(p, name="Alice", tick=1):
    p[name].slash("/cdl dungeon on")
    p.w.tick(tick)


def sent_by(w, t, sender, start=0):
    return [m for m in msgs_of_type(w, t, start) if m["_sender"] == key(sender)]


# ------------------------------------------------------------------------------------------------------------------
# §21.2 ItemDB
# ------------------------------------------------------------------------------------------------------------------
@R.case
def itemdb_dungeon_refs_sources_text_guid():
    w = World()
    c = Client(w, "Alice", guild_rank=0)
    c.load_addon()
    w.tick(2)
    ref = c.eval_py("local r = ns.ItemDB:GetBossRef('BlackMorass:Aeonus'); "
                    "return { r.key, r.dungeon, r.raid.name, r.phase, r.boss.name }")
    assert ref == ["BlackMorass:Aeonus", True, "The Black Morass", 1, "Aeonus"], ref
    mgt = c.eval_py("local r = ns.ItemDB:GetBossRef('MagistersTerrace:Kaelthas'); return { r.phase, r.dungeon }")
    assert mgt == [5, True], mgt
    # raids unchanged: GetBossRefs() is still raids only; the new scopes add the 5-man bosses
    n_raid, n_dg, n_all = c.eval("return #ns.ItemDB:GetBossRefs(), #ns.ItemDB:GetBossRefs('dungeons'), #ns.ItemDB:GetBossRefs('all')")
    assert n_dg > 60 and n_all == n_raid + n_dg, (n_raid, n_dg, n_all)
    assert c.eval("for _, r in ipairs(ns.ItemDB:GetBossRefs()) do if r.dungeon then return false end end return true")
    # sources + heroic flag
    src = c.eval_py("local out = {} for i, s in ipairs(ns.ItemDB:GetSources(...)) do out[i] = { s.ref.key, s.heroic or false } end return out", BREECHES)
    assert src == [["BlackMorass:Aeonus", True]], src
    src = c.eval_py("local out = {} for i, s in ipairs(ns.ItemDB:GetSources(...)) do out[i] = { s.ref.key, s.heroic or false } end return out", COWL)
    assert src == [["BlackMorass:Aeonus", False]], src
    assert c.eval("return #ns.ItemDB:GetSources(..., 'raids')", COWL) == 0
    assert c.eval("return #ns.ItemDB:GetSources(..., 'dungeons')", RUBY_DRAPE) == 0
    assert c.eval("return ns.ItemDB:GetSources(...)[1].ref.key", RUBY_DRAPE) == "Karazhan:Prince"
    txt = [c.eval("return ns.ItemDB:GetSourceText(...)", i) for i in (COWL, BREECHES)]
    assert txt == ["Aeonus · The Black Morass", "Aeonus · The Black Morass (Heroic)"], txt
    short = [c.eval("return ns.ItemDB:GetSourceText(..., true)", i) for i in (COWL, BREECHES)]
    assert short == ["Aeonus", "Aeonus (H)"], short
    assert c.eval("return ns.ItemDB:IsDungeonItem(...)", COWL) and not c.eval("return ns.ItemDB:IsDungeonItem(...)", RUBY_DRAPE)
    # GUID lookup: normal + heroic creature ids, and raid bosses still resolve
    for guid in (AEONUS_GUID, AEONUS_H_GUID):
        assert c.eval("return ns.ItemDB:GetBossBySourceGUID(...).key", guid) == "BlackMorass:Aeonus", guid
    assert c.eval("return ns.ItemDB:GetBossBySourceGUID(...).key", PRINCE_GUID) == "Karazhan:Prince"
    w.assert_no_errors()


@R.case
def itemdb_candidates_scope_heroic_and_phase():
    w = World()
    c = Client(w, "Alice", guild_rank=0)
    c.load_addon()
    w.tick(2)
    q = r"""
      local sid, f = ...
      local out = {}
      for _, r in ipairs(ns.ItemDB:GetCandidates(sid, f)) do
        out[#out + 1] = { r.itemID, r.ref.key, r.ref.dungeon and true or false, r.heroic and true or false, r.ref.phase }
      end
      return out"""
    raids = c.eval_py(q, SID_LEGS, {})
    dung = c.eval_py(q, SID_LEGS, {"scope": "dungeons"})
    both = c.eval_py(q, SID_LEGS, {"scope": "all"})
    assert raids and not any(r[2] for r in raids), "default scope must stay raid-only"
    assert raids == c.eval_py(q, SID_LEGS, {"scope": "raids"})
    assert dung and all(r[2] for r in dung), dung[:3]
    ids = {r[0]: r for r in dung}
    assert ids[BREECHES][3] is True and ids[BREECHES][1] == "BlackMorass:Aeonus", ids.get(BREECHES)
    assert any(not r[3] for r in dung), "normal-list rows carry no heroic flag"
    assert [r for r in both if not r[2]] == raids, "scope all: raids first, unchanged"
    assert len(both) == len(raids) + len([r for r in dung if r[0] not in {x[0] for x in raids}])
    # phase filters apply to dungeons (Magisters' Terrace is phase 5)
    p4 = c.eval_py(q, 5, {"scope": "dungeons", "maxPhase": 4})
    p5 = c.eval_py(q, 5, {"scope": "dungeons", "phase": 5})
    assert p5 and all(r[4] == 5 for r in p5) and not any(r[4] == 5 for r in p4), (p4[:2], p5[:2])
    # a 2H heroic-only weapon lands in the main-hand slot
    mh = c.eval_py(q, SID_MH, {"scope": "dungeons"})
    assert [r for r in mh if r[0] == QUANTUM][0][3] is True
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# §22.1 switch, DM message and its gate
# ------------------------------------------------------------------------------------------------------------------
@R.case
def dm_from_party_leader_reaches_every_member():
    p = Party()
    w = p.w
    for n in NAMES:
        assert not active(p[n]) and channel(p[n]) is None, n
    log0 = len(w.addon_log)
    enable(p, "Alice")
    dm = sent_by(w, "DM", "Alice", log0)
    assert len(dm) == 1 and dm[0]["on"] is True and dm[0]["_chat_type"] == "PARTY", dm
    for n in NAMES:
        assert active(p[n]) and channel(p[n]) == "PARTY", n
        assert changed(p[n])[-1] is True, (n, changed(p[n]))
    for n in NAMES[1:]:
        assert enabled_by(p[n]) == key("Alice"), n
        assert any("dungeon mode enabled by Alice (5-man loot sharing & rolls)" in strip_codes(l)
                   for l in printed_lines(p[n])), printed_lines(p[n])[-3:]
    assert p["Alice"].eval("return ns.db.settings.dungeon.enabled") is True
    # turning it off tells the party too
    log1 = len(w.addon_log)
    p["Alice"].slash("/cdl dungeon off")
    w.tick(1)
    dm = sent_by(w, "DM", "Alice", log1)
    assert len(dm) == 1 and dm[0]["on"] is False, dm
    for n in NAMES:
        assert not active(p[n]) and enabled_by(p[n]) is None, n
        assert changed(p[n])[-1] is False
    w.assert_no_errors()


# A party without a loot authority (Addendum D §24 as amended by E §33): the leader is not council and did not
# turn dungeon mode on, and nobody in it is on the guild council list -> everyone uses their own settings.
PLAIN_PARTY = [("Dave", "PRIEST", 3), ("Carol", "WARRIOR", 3), ("Erin", "ROGUE", 3)]


@R.case
def dm_from_plain_member_is_ignored():
    p = Party()
    w = p.w
    w.tick(5)                                    # the GM leader's group rules (GS) have reached everyone
    log0 = len(w.addon_log)
    p["Carol"].slash("/cdl dungeon on")          # not leader, not council, not the group's loot authority
    w.tick(1)
    assert sent_by(w, "DM", "Carol", log0) == [], "a plain member must not tell the party"
    assert sent_by(w, "GS", "Carol", log0) == [], "a plain member must not send group rules"
    # Addendum D §26: while the group's loot authority (the GM party leader) sets the rules, her own switch is
    # only her saved setting; the mode follows the authority for everyone, her included
    assert p["Carol"].eval("return ns.DB:GetSetting('dungeon.enabled')") is True
    assert not active(p["Carol"]) and channel(p["Carol"]) is None
    assert any("Alice sets the loot rules for this group" in strip_codes(l) for l in printed_lines(p["Carol"])), \
        printed_lines(p["Carol"])[-2:]
    for n in ("Alice", "Bob", "Dave", "Erin"):
        assert not active(p[n]), n
    # a forged DM from her is dropped by the gate
    p["Carol"].eval("ns.Comm:Send({ t = 'DM', on = true }, 'PARTY', nil, 'alert')")
    w.tick(1)
    assert len(sent_by(w, "DM", "Carol", log0)) == 1
    for n in ("Alice", "Bob", "Dave", "Erin"):
        assert not active(p[n]) and enabled_by(p[n]) is None, n
    # junk payloads never error
    p["Alice"].eval("ns.Comm:Send({ t = 'DM', on = 'yes' }, 'PARTY', nil, 'alert')")
    p["Alice"].eval("ns.Comm:Send({ t = 'DM' }, 'PARTY', nil, 'alert')")
    w.tick(1)
    assert not active(p["Bob"])
    w.assert_no_errors()
    # without a loot authority her switch works for her client only, and the party is not told
    q = Party(roster=PLAIN_PARTY, bis={}, leader="Dave", sync=False)
    q.w.tick(8)
    assert q["Carol"].eval("return ns.GroupRules:GetAuthority()") is None
    log1 = len(q.w.addon_log)
    q["Carol"].slash("/cdl dungeon on")
    q.w.tick(1)
    assert sent_by(q.w, "DM", "Carol", log1) == [] and sent_by(q.w, "GS", "Carol", log1) == []
    assert active(q["Carol"]) and channel(q["Carol"]) == "PARTY"
    assert any("Only your client uses it" in l for l in printed_lines(q["Carol"])), printed_lines(q["Carol"])[-2:]
    for n in ("Dave", "Erin"):
        assert not active(q[n]), n
    q["Carol"].eval("ns.Comm:Send({ t = 'DM', on = true }, 'PARTY', nil, 'alert')")   # forged: dropped
    q.w.tick(1)
    for n in ("Dave", "Erin"):
        assert not active(q[n]) and enabled_by(q[n]) is None, n
    q.w.assert_no_errors()


@R.case
def council_member_can_enable_and_non_council_leader_too():
    # Addendum E §33: in a party the authority is the party leader if council (or if they turned dungeon mode on),
    # else a guild-list council member in the party. Here the leader Carol is a plain member and Bob (on the
    # GM's list) is the only council member: Bob decides for the party.
    roster = [("Carol", "WARRIOR", 3), ("Alice", "PALADIN", 2), ("Bob", "MAGE", 1), ("Dave", "PRIEST", 3),
              ("Erin", "ROGUE", 3)]
    p = Party(roster=roster, leader="Carol", sync=False)
    w = p.w
    w.tick(8)
    assert p["Dave"].eval("return ns.GroupRules:GetAuthority()") == key("Bob")
    log0 = len(w.addon_log)
    enable(p, "Bob")                              # council, not the leader
    assert len(sent_by(w, "DM", "Bob", log0)) == 1, "the authority tells CDLoot 0.2 members too (DM)"
    for n in NAMES:
        assert active(p[n]), n
    assert enabled_by(p["Carol"]) == key("Bob")
    for n in ("Alice", "Carol", "Dave", "Erin"):
        assert p[n].eval("return ns.GroupRules:GetActive().from") == key("Bob"), n
    w.assert_no_errors()
    # ... but not in a party whose leader is council (the GM): the leader is the authority, Bob is not
    g = Party(sync=False)
    g.w.tick(5)
    log1 = len(g.w.addon_log)
    enable(g, "Bob")
    assert sent_by(g.w, "DM", "Bob", log1) == [], "a council member who is not the authority must not tell the party"
    for n in NAMES:
        assert not active(g[n]), n
    enable(g, "Alice")
    for n in NAMES:
        assert active(g[n]), n
    g.w.assert_no_errors()
    # a party led by a non-council member: the leader's DM counts, and the leader may start rolls
    q = Party(leader="Carol", sync=False)
    enable(q, "Carol")
    for n in NAMES:
        assert active(q[n]), n
    assert q["Carol"].eval("return ns.Roll:CanStart()") is True
    assert q["Dave"].eval("return ns.Roll:CanStart()") is False
    q.w.assert_no_errors()


@R.case
def newly_joined_member_gets_the_resend():
    p = Party()
    w = p.w
    # Erin leaves, the leader enables, Erin comes back: the enabler re-sends DM (debounced 3s)
    w.make_party([p[n] for n in ("Alice", "Bob", "Carol", "Dave")], leader=p["Alice"])
    w.tick(1)
    enable(p, "Alice")
    assert not active(p["Erin"])
    log0 = len(w.addon_log)
    w.make_party([p[n] for n in NAMES], leader=p["Alice"])
    w.tick(5)
    assert sent_by(w, "DM", "Alice", log0), "no re-send after the party changed"
    assert active(p["Erin"]) and enabled_by(p["Erin"]) == key("Alice")
    w.assert_no_errors()


@R.case
def reload_asks_the_party_again():
    p = Party()
    w = p.w
    enable(p, "Alice")
    p["Dave"].relog()
    w.tick(0.5)
    install_dm_probe([p["Dave"]])
    assert enabled_by(p["Dave"]) is None, "the group switch is session-only"
    w.tick(10)
    assert active(p["Dave"]) and enabled_by(p["Dave"]) == key("Alice"), "Dave did not get dungeon mode back"
    w.assert_no_errors()


@R.case
def disband_and_raid_conversion_clear_the_group_switch():
    p = Party()
    w = p.w
    enable(p, "Alice")
    # the group becomes a raid (same members): the 5-man switch is gone, traffic uses RAID
    w.make_raid([p[n] for n in NAMES], leader=p["Alice"])
    w.tick(1)
    for n in NAMES:
        assert not active(p[n]) and channel(p[n]) == "RAID", n
    assert enabled_by(p["Bob"]) is None
    assert changed(p["Bob"])[-1] is False
    # back to a party: the enabler (setting still on) tells the party again
    w.make_party([p[n] for n in NAMES], leader=p["Alice"])
    w.tick(5)
    assert active(p["Bob"]) and enabled_by(p["Bob"]) == key("Alice")
    w.disband()
    w.tick(1)
    for n in NAMES:
        assert not active(p[n]) and channel(p[n]) is None, n
    assert enabled_by(p["Bob"]) is None and changed(p["Bob"])[-1] is False
    w.assert_no_errors()


@R.case
def slash_quality_and_status():
    p = Party(sync=False)
    c = p["Alice"]
    c.slash("/cdl dungeon epic")
    assert c.eval("return ns.db.settings.dungeon.quality") == 4
    c.slash("/cdl dungeon rare")
    assert c.eval("return ns.db.settings.dungeon.quality") == 3
    n0 = len(c.chat_frame)
    c.slash("/cdl dungeon status")
    assert "off" in strip_codes(printed_lines(c)[-1]), printed_lines(c)[n0:]
    c.slash("/cdl dungeon bogus")
    assert "Usage: /cdl dungeon" in printed_lines(c)[-1]
    p.w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# §22.2 drops
# ------------------------------------------------------------------------------------------------------------------
@R.case
def party_drop_broadcast_on_party_with_rare_threshold():
    p = Party()
    w = p.w
    enable(p, "Alice")
    log0 = len(w.addon_log)
    p["Alice"].open_loot([(COWL, 3), (BREECHES, 3), (GREEN, 2)], source_guid=AEONUS_H_GUID)
    w.tick(3)
    D = msgs_of_type(w, "D", log0)
    assert len(D) == 1 and D[0]["_chat_type"] == "PARTY" and D[0]["b"] == "BlackMorass:Aeonus", D
    assert sorted(D[0]["i"]) == sorted([COWL, BREECHES]), D[0]["i"]
    for n in NAMES:
        hist = drop_history(p[n])
        assert len(hist) == 1 and hist[0]["b"] == "BlackMorass:Aeonus" and sorted(hist[0]["i"]) == sorted([COWL, BREECHES]), (n, hist)
    # Erin's BiS toast works like in a raid
    assert toast_state(p["Erin"])["shown"] and toast_state(p["Erin"])["item"] == COWL, toast_state(p["Erin"])
    # quality setting Epic: rares are no longer tracked
    for n in NAMES:
        p[n].slash("/cdl dungeon epic")
    p["Alice"].close_loot()
    log1 = len(w.addon_log)
    p["Alice"].open_loot([(SCARAB, 3)], source_guid="Creature-0-1-2-3-17880-000AE2")   # Temporus
    w.tick(3)
    assert msgs_of_type(w, "D", log1) == []
    w.assert_no_errors()


@R.case
def party_without_dungeon_mode_keeps_todays_behaviour():
    p = Party()
    w = p.w
    log0 = len(w.addon_log)
    p["Alice"].open_loot([(COWL, 4), (BREECHES, 3)], source_guid=AEONUS_GUID)
    w.tick(3)
    assert msgs_of_type(w, "D", log0) == [], "nothing is broadcast without dungeon mode"
    assert drop_history(p["Bob"]) == []
    hist = drop_history(p["Alice"])
    assert len(hist) == 1 and hist[0]["i"] == [COWL], "epic threshold outside dungeon mode: %r" % hist
    # a PARTY drop from someone else is ignored while the mode is off for me (a party without a loot authority,
    # where Carol's own switch applies to her client only)
    q = Party(roster=PLAIN_PARTY, bis={}, leader="Dave", sync=False)
    q["Carol"].slash("/cdl dungeon on")
    q.w.tick(1)
    qlog = len(q.w.addon_log)
    q["Carol"].open_loot([(SCARAB, 3)], source_guid="Creature-0-1-2-3-17879-000AE3")   # Deja
    q.w.tick(3)
    D = msgs_of_type(q.w, "D", qlog)
    assert len(D) == 1 and D[0]["_sender"] == key("Carol") and D[0]["_chat_type"] == "PARTY", D
    assert drop_history(q["Dave"]) == [] and drop_history(q["Erin"]) == []
    q.w.assert_no_errors()
    assert drop_history(p["Bob"]) == []
    # Roll:CanStart needs the mode in a party (and says so)
    assert p["Alice"].eval("return ns.Roll:CanStart()") is False
    n0 = len(p["Alice"].chat_frame)
    p["Alice"].slash("/cdl roll %d" % COWL)
    assert "need dungeon mode" in printed_lines(p["Alice"])[-1], printed_lines(p["Alice"])[n0:]
    w.assert_no_errors()


@R.case
def raid_is_unaffected_by_the_setting():
    r = Raid(sync=False)
    w = r.w
    r["Bob"].slash("/cdl dungeon on")
    w.tick(1)
    assert not r["Bob"].eval("return ns.Util.IsDungeonModeActive()")
    assert r["Bob"].eval("return ns.Util.GetGroupChannel()") == "RAID"
    log0 = len(w.addon_log)
    r["Alice"].open_loot([(RUBY_DRAPE, 4)])
    w.tick(3)
    D = msgs_of_type(w, "D", log0)
    assert len(D) == 1 and D[0]["_chat_type"] == "RAID", D
    assert msgs_of_type(w, "DM", 0) == [], "no DM in a raid"
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# §22.2 rolls + ledger
# ------------------------------------------------------------------------------------------------------------------
@R.case
def party_roll_award_records_dungeon_entry():
    p = Party()
    w = p.w
    A = p["Alice"]
    enable(p, "Alice")
    A.open_loot([(COWL, 3), (BREECHES, 3)], source_guid=AEONUS_H_GUID)
    w.tick(3)
    assert p["Carol"].eval("return ns.Roll:CanStart()") is False
    assert A.eval("return ns.Roll:CanStart()") is True
    log0, chat0 = len(w.addon_log), len(w.chat_log)
    A.eval("ns.Roll:Start(..., ns.Loot:GetHistory()[1])", COWL)
    w.tick(1)
    RS = msgs_of_type(w, "RS", log0)
    assert len(RS) == 1 and RS[0]["_chat_type"] == "PARTY" and RS[0]["b"] == "BlackMorass:Aeonus", RS
    sid = RS[0]["id"]
    for n in NAMES:
        s = session_info(p[n], sid)
        assert s and s["state"] == "open", (n, s)
    # members respond with the addon (RR on PARTY + RandomRoll) or roll by hand
    w._roll_rng = FixedRng(40)
    p["Erin"].eval("ns.Roll:RespondRoll(...)", sid)
    w._roll_rng = FixedRng(90)
    p["Carol"].eval("ns.Roll:RespondRoll(...)", sid)
    del w._roll_rng
    p["Dave"].eval("ns.Roll:RespondPass(...)", sid)
    w.tick(1)
    RR = msgs_of_type(w, "RR", log0)
    assert len(RR) == 3 and all(m["_chat_type"] == "PARTY" for m in RR), RR
    A.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    assert [m["_chat_type"] for m in msgs_of_type(w, "RE", log0)] == ["PARTY"]
    res = results(A, sid)
    assert res[0]["key"] == key("Erin") and res[0]["suggested"] and res[0]["tier"] == 1, res
    for n in NAMES:
        assert session_info(p[n], sid)["rolls"][key("Carol")]["roll"] == 90, n
    A.eval("ns.Roll:Award(...)", sid, key("Erin"))
    w.tick(0.2)
    assert A.popups() == ["CDLOOT_CONFIRM_AWARD"], A.popups()
    A.accept_popup("CDLOOT_CONFIRM_AWARD")
    w.tick(2)
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["_chat_type"] == "PARTY" and RW[0]["w"] == key("Erin"), RW
    for n in NAMES:
        s = session_info(p[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Erin"), (n, s)
    for n in ("Alice", "Bob"):
        e = p[n].eval_py("local out = {} for _, e in ipairs(ns.Ledger:GetEntries()) do out[#out + 1] = { e.w, e.i, e.s, e.dg, e.b } end return out")
        assert e == [[key("Erin"), COWL, "m", True, "BlackMorass:Aeonus"]], (n, e)
        assert p[n].eval("return ns.Ledger:CountSince(..., 0)", key("Erin")) == 0, "dungeon loot is not 'won tonight'"
        assert p[n].eval("return ns.Ledger:CountSince(..., 0, true)", key("Erin")) == 1
        assert p[n].eval("return #ns.Ledger:GetEntries({ excludeDungeon = true })") == 0
        assert p[n].eval("return #ns.Ledger:GetEntries({ dungeonOnly = true })") == 1
    lines = [e for e in w.chat_log[chat0:] if "->" in e["text"]]
    assert len(lines) == 1 and lines[0]["chat_type"] == "PARTY", lines
    assert strip_codes(lines[0]["text"]) == "CDLoot: [Cowl of the Guiltless] -> Erin (rolled 40, BiS)", lines[0]
    # the loot line later only resolves nothing new; council clients keep one visible entry
    w.broadcast_loot_received(p["Erin"], COWL)
    w.tick(1)
    for n in ("Alice", "Bob"):
        vis = ledger_visible(p[n])
        assert len(vis) == 1, (n, vis)
        raw = p[n].eval_py("local out = {} for _, e in pairs(ns.db.ledger) do out[#out + 1] = { e.s, e.dg } end table.sort(out, function(a, b) return a[1] < b[1] end) return out")
        assert raw == [["a", True], ["m", True]], (n, raw)
    w.assert_no_errors()


@R.case
def party_rs_gate_and_mode_off_closes_rolls():
    p = Party()
    w = p.w
    enable(p, "Alice")
    # a plain member's forged RS is ignored
    p["Carol"].eval("ns.Comm:Send({ t = 'RS', id = 'Carol-1-1', i = %d, s = '', b = '', d = 30, ts = GetServerTime(), c = 1 }, 'PARTY', nil, 'alert')" % COWL)
    w.tick(1)
    assert p["Bob"].eval("return ns.Roll:Get('Carol-1-1') == nil")
    # dungeon mode ends while a party roll is open: closed everywhere
    p["Alice"].eval("ns.Roll:Start(...)", SCARAB)
    w.tick(1)
    sid = active_session(p["Alice"])["id"]
    assert session_info(p["Dave"], sid)["state"] == "open"
    p["Alice"].slash("/cdl dungeon off")
    w.tick(1)
    for n in NAMES:
        assert session_info(p[n], sid)["state"] == "closed", n
    w.assert_no_errors()


@R.case
def ledger_dg_field_validation_and_merge():
    p = Party(sync=False, instance=False)
    B = p["Bob"]
    base = {"id": "mtest1", "i": COWL, "w": key("Erin"), "by": key("Alice"), "ts": 1790000000, "s": "m"}
    assert B.eval("return ns.Ledger:Merge(...)", dict(base, dg="yes"), key("Alice")) is False, "non-boolean dg"
    assert B.eval("return ns.Ledger:Merge(...)", base, key("Alice")) is True
    assert B.eval("return ns.db.ledger.mtest1.dg") is None
    # an older client relayed it without dg; a 0.3 copy adds the flag (never removes it)
    assert B.eval("return ns.Ledger:Merge(...)", dict(base, dg=True), key("Alice")) is True
    assert B.eval("return ns.db.ledger.mtest1.dg") is True
    assert B.eval("return ns.Ledger:Merge(...)", base, key("Alice")) is False
    assert B.eval("return ns.db.ledger.mtest1.dg") is True
    # the digest does not depend on dg
    d1 = B.eval_py("return ns.Ledger:GetDigest()")
    B.eval("ns.db.ledger.mtest1.dg = nil")
    assert B.eval_py("return ns.Ledger:GetDigest()") == d1
    # dg survives a reload (OnLogin cleaning)
    B.eval("ns.db.ledger.mtest1.dg = true")
    B.relog()
    p.w.tick(1)
    assert B.eval("return ns.db.ledger.mtest1.dg") is True
    p.w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# §22.3 /cdl test in a 5-man
# ------------------------------------------------------------------------------------------------------------------
@R.case
def cdl_test_in_a_dungeon_simulates_a_dungeon_boss_drop():
    p = Party(sync=False)
    w = p.w
    enable(p, "Alice")
    log0 = len(w.addon_log)
    A = p["Alice"]
    A.slash("/cdl test")
    w.tick(1)
    drop = drops_fired(A)[-1]
    assert drop["test"] and drop["b"].startswith("BlackMorass:"), drop
    assert 2 <= len(drop["i"]) <= 3, drop
    heroic = A.eval_py("local r = ns.ItemDB:GetBossRef(...); local out = {} for _, id in ipairs(r.boss.heroicItems) do out[#out + 1] = id end return out", drop["b"])
    assert all(i in heroic for i in drop["i"]), (drop, heroic)
    assert msgs_of_type(w, "D", log0) == [], "test drops stay local"
    assert any("Simulated a dungeon drop" in l for l in printed_lines(A))
    # outside dungeon mode /cdl test is the raid simulation as before
    A.slash("/cdl dungeon off")
    w.tick(1)
    A.slash("/cdl test")
    w.tick(1)
    b = drops_fired(A)[-1]["b"]
    assert A.eval("return ns.ItemDB:GetBossRef(...).dungeon == nil", b), b
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

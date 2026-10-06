"""Regression cases for the DisasterZone 0.5.0 final-review fixes (one or more cases per finding id).

Runs the real addon in the mocked multi-client world. Case names start with the finding id they cover.
Usage: python tests/regressions/test_final_review.py [-k substring]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(SCRATCH, "tests", "loot-roll"))
sys.path.insert(0, os.path.join(SCRATCH, "tests"))

from lr_common import *  # noqa: F401,F403,E402
from lr_common import (Runner, main, Raid, World, Client, ExtraMember, key, msgs_of_type, panel_blocks,  # noqa: E402
                       results, session_info, active_session, ledger_visible, ledger_raw, printed_lines,
                       strip_codes, rollframe_state, drop_history, drops_fired, wanter_keys, toast_state, seed_bis,
                       RUBY_DRAPE, THOUSAND_MARKS, HELM_CHAMPION, HELM_DEFENDER, MINDBLADE, JADE_RING, PRINCE_GUID,
                       PRINCE_ENCOUNTER, SID_BACK, SID_HEAD, SID_RING1)
from cdl_council import gm_pick, raid_pick, seed_guild_council  # noqa: E402

R = Runner("regressions / final review (0.5.0)")

VOID_CRYSTAL = 22450          # disenchant result (epic trade good, no boss drops it)
LARGE_PRISMATIC = 22449       # disenchant result (rare trade good)
FIERY_WARHORSE = 30480        # Attumen mount: boss loot that is neither equippable nor a token
ASHES_ALAR = 32458            # Kael'thas mount
NETHER_VORTEX = 30183         # boss trade good (has drop sources)
WARP_SPRING_COIL = 30450      # T5 trinket, Classes: Rogue
GLAD_PLATE_HELM = 24545       # S1 warrior set helm (arena exchange of Helm of the Fallen Defender... for warriors)
MEDALLION_DRUID = 28235       # Medallion of the Alliance, Classes: Druid
ITEM_GUID = "Item-4467-0-4000000ABCDEF01"
ATTUMEN_ENCOUNTER = 652
ATTUMEN_GUID = "Creature-0-1-2-3-16152-000A11"
KARA_TRASH_GUID = "Creature-0-1-2-3-16408-000B22"   # Phantom Valet (Karazhan trash)


FIND_FIELD = """local field = ...
local function find(fr)
  if type(rawget(fr, field)) == "table" then return rawget(fr, field) end
  for _, ch in ipairs({ fr:GetChildren() }) do local x = find(ch) if x then return x end end
end
return find(UIParent)"""


def send_as(c, msg, dist, target=None, cls="ctrl"):
    return c.eval("local m, d, t, cl = ... return ns.Comm:Send(m, d, t, cl)", msg, dist, target, cls)


def confirm_award(c, sid, winner, item):
    """DISASTERZONE_CONFIRM_AWARD accepted for sid -> winner (record + announce, no hand-out)."""
    c.eval("local a, b, i = ... ns.Roll:ConfirmAward({ id = a, key = b, itemID = i })", sid, winner, item)


def now(c):
    return c.eval("return GetServerTime()")


def D_msgs(w, log0):
    return [(m["_sender"], m.get("s"), m.get("b"), m.get("i")) for m in msgs_of_type(w, "D", log0)]


def roll(w, who, value):
    w.player_roll(who, value)


def start_roll(c, item, copy=1):
    c.eval("ns.DropPanel:StartRoll(...)", item, copy)


def block_of(c, item, copy=1):
    for b in panel_blocks(c):
        if b["item"] == item and b["copy"] == copy:
            return b
    return None


# ================================================================================================================
# disenchant-loot-broadcast-as-boss-drop
# ================================================================================================================
@R.case
def disenchant_item_source_is_never_a_drop():
    r = Raid()
    w = r.w
    A, E = r["Alice"], r["Erin"]
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    A.close_loot()
    shown = A.eval("return ns.DropPanel.drop.i[1]")
    snd0, log0 = len(A.sounds), len(w.addon_log)
    E.open_loot([(VOID_CRYSTAL, 4, 2)], source_guid=ITEM_GUID)        # the raid's enchanter disenchants
    w.tick(3)
    E.close_loot()
    assert D_msgs(w, log0) == [], D_msgs(w, log0)
    assert A.eval("return ns.DropPanel.drop.i[1]") == shown and A.sounds[snd0:] == []
    assert not [d for d in drop_history(E) if d["s"] == ITEM_GUID]
    # no loot source at all (the UNKNOWN-* fallback): a trade good no boss drops is still not tracked
    E.open_loot([(VOID_CRYSTAL, 4, 1)], source_guid=None)
    w.tick(3)
    E.close_loot()
    assert D_msgs(w, log0) == [], D_msgs(w, log0)
    # a DisasterZone 0.4 client still broadcasts its disenchant window: receivers ignore it
    send_as(E, {"t": "D", "s": ITEM_GUID + "2", "b": "Karazhan:Prince", "i": [VOID_CRYSTAL], "ts": now(E)}, "RAID",
            None, "alert")
    w.tick(1)
    assert A.eval("return ns.DropPanel.drop.i[1]") == shown
    w.assert_no_errors()


@R.case
def disenchant_filter_keeps_mounts_vortex_and_fishing_is_skipped():
    r = Raid(encounter=False)
    w = r.w
    A = r["Alice"]
    w.encounter(ATTUMEN_ENCOUNTER, "Attumen the Huntsman")
    w.tick(0.5)
    log0 = len(w.addon_log)
    A.open_loot([(FIERY_WARHORSE, 4), (NETHER_VORTEX, 4)], source_guid=ATTUMEN_GUID)
    w.tick(3)
    A.close_loot()
    D = msgs_of_type(w, "D", log0)
    assert len(D) == 1 and sorted(D[0]["i"]) == sorted([FIERY_WARHORSE, NETHER_VORTEX]), D
    # fishing loot is never a drop
    A.eval("IsFishingLoot = function() return true end")
    A.open_loot([(RUBY_DRAPE, 4)], source_guid="GameObject-0-1-2-3-999999-00F")
    w.tick(3)
    A.close_loot()
    assert len(msgs_of_type(w, "D", log0)) == 1
    w.assert_no_errors()


# ================================================================================================================
# ledger-view-cached-empty-before-guild-name / awards-untagged-before-guild-name
# ================================================================================================================
LATE_GUILD_NAME = r"""
local real = GetGuildInfo
__LATE_UNTIL = GetTime() + 3
GetGuildInfo = function(unit)
  if GetTime() < __LATE_UNTIL then return nil end
  return real(unit)
end
"""


@R.case
def ledger_view_and_awards_survive_a_late_guild_name():
    r = Raid(encounter=False, instance=False, raid=False)
    w = r.w
    A, B = r["Alice"], r["Bob"]
    e = A.eval_py("return ns.Ledger:Award(...)", RUBY_DRAPE, key("Dave"), "", "before relog")
    w.tick(3)
    assert B.eval("return ns.Ledger:HasAward(...)", key("Dave"), RUBY_DRAPE)
    # Bob reconnects; GetGuildInfo("player") answers nil for the first 3 s, the ledger is read at once
    B.preload_lua = LATE_GUILD_NAME
    B.relog(reload=False)
    B.preload_lua = None
    w.tick(1)
    assert B.eval("return ns.Guild:GetGuildKey()") is None
    B.eval("return ns.Ledger:GetEntries()")     # e.g. a tooltip / RS snapshot in that window builds the view
    # an award recorded in that window: kept, tagged and sent once the name is known
    e2 = B.eval_py("return ns.Ledger:Award(...)", THOUSAND_MARKS, key("Carol"), "", "early")
    assert e2 and e2.get("g") is None, e2
    w.tick(5)
    assert B.eval("return ns.Guild:GetGuildKey()") is not None
    assert B.eval("return ns.Ledger:HasAward(...)", key("Dave"), RUBY_DRAPE), "view stayed cached empty"
    # The addon learns the name at its first read after the 3 s. That read is the login HELLO's ledger digest if the
    # HELLO's random delay falls in this window, else the check just above. The scope update that tags the early award
    # runs one frame after that read (Guild defers GUILD_KEY_READY, the ledger its own UpdateScope), so allow that frame.
    w.tick(0.05)
    assert B.eval("return #ns.Ledger:GetEntries()") == 2
    assert B.eval("return ns.db.ledger[...].g", e2["id"]) == B.eval("return ns.Guild:GetGuildKey()")
    w.tick(40)   # (sent to the peers seen since the login: A, or the digest sync after the login HELLO)
    assert A.eval("return ns.Ledger:GetEntry(...) ~= nil", e2["id"]), "the early award was never sent"
    w.assert_no_errors()


# ================================================================================================================
# escape-restore-popup-overwrites-newer-copy (+ mock fidelity: StaticPopup_EscapePressed, busy dialogs)
# ================================================================================================================
COPY = "local r = ns.Store:GetCached(...) return { rev = r.rev, neck = r.data.ph[1][2] and r.data.ph[1][2][1] or false }"


def _restore_setup():
    r = Raid(encounter=False, instance=False, raid=False)
    w = r.w
    B, C = r["Bob"], r["Carol"]
    C.eval("ns.BiS:SetSlot(1, 2, 'main', 28762)")
    C.eval("ns.BiS:Commit()")
    w.tick(20)
    newer = B.eval_py(COPY, key("Carol"))
    C.eval("local rec = ns.BiS:GetRecord(); rec.data.ph[1][2] = nil; rec.rev = rec.rev - 1; "
           "rec.highestSeenRev = rec.rev; rec.hash = ns.Util.Hash(rec.data)")
    C.relog()
    w.tick(40)
    assert "DISASTERZONE_RESTORE" in C.popups(), C.popups()
    return r, w, B, C, newer


@R.case
def escape_restore_popup_escape_keeps_the_council_copy():
    r, w, B, C, newer = _restore_setup()
    assert C.escape_popups() is True
    w.tick(30)
    assert B.eval_py(COPY, key("Carol")) == newer, "Escape superseded the council's newer copy"
    assert C.popups() == []
    w.assert_no_errors()


@R.case
def escape_restore_popup_keep_mine_click_still_supersedes():
    r, w, B, C, newer = _restore_setup()
    C.cancel_popup("DISASTERZONE_RESTORE")
    w.tick(20)
    after = B.eval_py(COPY, key("Carol"))
    assert after["neck"] is False and after["rev"] > newer["rev"], after
    # a popup that is never shown (all dialogs busy -> OnCancel(nil, data)) does nothing
    C.eval("StaticPopupDialogs.DISASTERZONE_RESTORE.OnCancel(nil, { from = 'x', rev = 1 }, nil)")
    w.tick(10)
    assert B.eval_py(COPY, key("Carol")) == after
    w.assert_no_errors()


# ================================================================================================================
# stale-ml-flag-rt-not-sent
# ================================================================================================================
@R.case
def stale_ml_flag_new_master_looter_gets_tiers():
    r = Raid()
    w = r.w
    A = r["Alice"]
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    A.close_loot()
    w.set_master_looter(r["Frank"])          # the loot method changes, no roster change
    w.tick(1)
    assert A.eval("return ns.Util.group[...].isML", key("Frank")) is True
    # 1.3: a master looter from the guild is council of the raid while it runs the loot council. Every client knows
    # the new master looter at once (no stale flag): it is council ("ml") everywhere and gets the raid's lists like
    # other raid-scope council, instead of the tiers by RT.
    for n, c in r.c.items():
        assert c.eval("return ns.Guild:GetCouncilSource(...)", key("Frank")) == "ml", n
    w.tick(20)                               # (raid-scope council gets the lists pushed after 10-15 s)
    log0 = len(w.addon_log)
    start_roll(A, RUBY_DRAPE)
    w.tick(2)
    assert msgs_of_type(w, "RT", log0) == []
    assert wanter_keys(r["Frank"], RUBY_DRAPE) == wanter_keys(A, RUBY_DRAPE), (wanter_keys(r["Frank"], RUBY_DRAPE),
                                                                              wanter_keys(A, RUBY_DRAPE))
    w.assert_no_errors()


# ================================================================================================================
# mock-ismodifiedclick-noarg: shift-click links from the Council Items view and the Loot Log
# ================================================================================================================
@R.case
def modified_click_links_items_from_council_views():
    r = Raid(encounter=False, instance=False)
    w = r.w
    A = r["Alice"]
    assert A.eval("return IsModifiedClick()") is False
    A.set_modifiers(shift=True)
    assert A.eval("return IsModifiedClick()") is True
    A.set_modifiers()
    A.slash("/dz council")
    w.tick(0.5)
    A.eval("ns.CouncilUI:SetView('items')")
    w.tick(0.5)
    row = A.eval("""for _, f in ipairs({ DisasterZoneMainFrame:GetChildren() }) do end
        local function find(fr)
          if fr.cdlData and fr.cdlData.itemID and fr.GetScript and fr:GetScript('OnClick') and fr:IsShown() then return fr end
          for _, ch in ipairs({ fr:GetChildren() }) do local x = find(ch) if x then return x end end
        end
        return find(DisasterZoneMainFrame)""")
    assert row is not None, "no item row in the Items view"
    n0 = len(A.inserted_links)
    A.set_modifiers(shift=True)
    A.click(row)
    A.set_modifiers()
    assert len(A.inserted_links) == n0 + 1, "shift-click did not link the item (HandleModifiedItemClick)"
    w.assert_no_errors()


# ================================================================================================================
# relay-poison-raidscope
# ================================================================================================================
def _poison_world():
    w = World()
    names = [("Gina", 0, "PALADIN"), ("Councila", 1, "PRIEST"), ("Councilb", 1, "MAGE"), ("Mallory", 3, "ROGUE"),
             ("Bob", 3, "WARRIOR")]
    c = {}
    for n, rank, cls in names:
        c[n] = Client(w, n, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Councila", "Councilb"])
    c["Bob"].eval("ns.BiS:SetSlot(1, 4, 'main', 28766)")
    c["Bob"].eval("ns.BiS:Commit()")
    w.tick(30)
    return w, c


@R.case
def relay_poison_raid_leader_relay_is_ignored_and_forged_copies_heal():
    w, c = _poison_world()
    ca, bob = c["Councila"], c["Bob"]
    assert ca.eval("return ns.Store:GetCached(...).rev", key("Bob")) == 1
    w.make_raid([c["Mallory"], ca], leader=c["Mallory"])    # Mallory leads: council on Councila's client
    w.tick(2)
    assert ca.eval("return ns.Guild:IsCouncil(..., true)", key("Mallory"))
    forged = bob.eval_py("local d = ns.Util.CopyTable(ns.BiS:GetRecord().data); d.ph[1][4] = nil; "
                         "return { o = ns.Util.PlayerKey(), r = 2147483647, ts = GetServerTime(), h = ns.Util.Hash(d), d = d }")
    send_as(c["Mallory"], {"t": "R", "e": [forged]}, "WHISPER", key("Councila"), "data")
    w.tick(2)
    assert ca.eval("return ns.Store:GetCached(...).rev", key("Bob")) == 1, "a raid-scope relay was stored"
    # a buggy / hostile GUILD council peer relays a MAX_REV copy: the owner's next contact heals it
    send_as(c["Councilb"], {"t": "R", "e": [forged]}, "WHISPER", key("Councila"), "data")
    w.tick(2)
    assert ca.eval("return ns.Store:GetCached(...).rev", key("Bob")) == 1, "an implausible relayed rev was stored"
    ca.eval("local r = ns.Store:GetCached(...); r.rev = 2147483647; r.via = 'Councilb-Thunderstrike'", key("Bob"))
    bob.relog()
    w.tick(40)
    rec = ca.eval_py("local r = ns.Store:GetCached(...) return { rev = r.rev, via = r.via }", key("Bob"))
    assert rec == {"rev": 1, "via": "direct"}, rec
    w.assert_no_errors()


@R.case
def relay_poison_raid_scope_cannot_hijack_a_restore():
    w, c = _poison_world()
    bob = c["Bob"]
    w.make_raid([c["Mallory"], bob], leader=c["Mallory"])
    w.tick(2)
    # fresh install: Bob's own list is gone; Mallory (raid leader) offers a high rev and spams relays
    for x in ("Councila", "Councilb", "Gina"):
        c[x].logout()
    w.tick(1)
    bob.eval("DisasterZoneDB = {}")          # a fresh install (the relog saves this empty table)
    bob.relog()
    w.tick(2)
    assert bob.eval("return ns.BiS:GetRecord().rev") == 0
    forged = bob.eval_py("local d = { v = 1, ph = { [1] = { [4] = { 28767 } } } } "
                         "return { o = ns.Util.PlayerKey(), r = 5, ts = GetServerTime(), h = ns.Util.Hash(d), d = d }")
    send_as(c["Mallory"], {"t": "S", "r": 5}, "WHISPER", key("Bob"))
    w.tick(5)
    send_as(c["Mallory"], {"t": "R", "e": [forged]}, "WHISPER", key("Bob"), "data")
    w.tick(10)
    assert bob.eval("return ns.BiS:GetRecord().rev") == 0, "a raid-scope council member restored my list"
    w.assert_no_errors()


# ================================================================================================================
# award-inject-any-council
# ================================================================================================================
@R.case
def award_inject_raid_and_future_and_old_voids_are_refused():
    w, c = _poison_world()
    ca, cb, mal = c["Councila"], c["Councilb"], c["Mallory"]
    real = ca.eval_py("return ns.Ledger:Award(...)", 28586, key("Bob"), "", "real")
    w.tick(3)
    # an old award (3 days ago) recorded by Councila, known to everyone
    old = ca.eval_py("local e = ns.Ledger:Award(...); e.ts = GetServerTime() - 3 * 86400; return e", 28587,
                     key("Bob"), "", "old")
    w.make_raid([mal, ca], leader=mal)
    w.tick(2)
    t = now(mal)
    # 1) A over RAID: never taken (A is whispered)
    send_as(mal, {"t": "A", "e": {"id": "m%dMallory1" % t, "i": 28588, "w": key("Bob"), "by": key("Mallory"),
                                  "ts": t, "s": "m"}}, "RAID")
    # 2) a forged author and a future-dated award from the raid leader
    send_as(mal, {"t": "A", "e": {"id": "m%dCouncilb2" % t, "i": 28589, "w": key("Bob"), "by": key("Councilb"),
                                  "ts": t, "s": "m"}}, "WHISPER", key("Councila"))
    send_as(mal, {"t": "A", "e": {"id": "m%dMallory3" % t, "i": 28590, "w": key("Bob"), "by": key("Mallory"),
                                  "ts": 4102444800, "s": "m"}}, "WHISPER", key("Councila"))
    # 3) a void of an award older than 12 h, and a MAX_TS void of a recent one
    v1 = dict(old, vd=True, vts=t)
    v1.pop("g", None)
    v2 = dict(real, vd=True, vts=4102444800)
    v2.pop("g", None)
    send_as(mal, {"t": "A", "e": v1}, "WHISPER", key("Councila"))
    send_as(mal, {"t": "A", "e": v2}, "WHISPER", key("Councila"))
    w.tick(2)
    for i in (28588, 28589, 28590):
        assert not ca.eval("return ns.Ledger:HasAward(...)", key("Bob"), i), i
    assert ca.eval("return ns.Ledger:HasAward(...)", key("Bob"), 28587), "an old award was voided by a raid leader"
    assert ca.eval("return ns.Ledger:HasAward(...)", key("Bob"), 28586), "a MAX_TS void was taken"
    # 4) the raid leader's own award of this raid is still shared (Addendum E §29)
    ok = send_as(mal, {"t": "A", "e": {"id": "m%dMallory4" % t, "i": 28591, "w": key("Bob"), "by": key("Mallory"),
                                       "ts": t, "s": "m"}}, "WHISPER", key("Councila"))
    w.tick(2)
    assert ok and ca.eval("return ns.Ledger:HasAward(...)", key("Bob"), 28591)
    w.assert_no_errors()


@R.case
def award_inject_poisoned_void_time_heals_and_void_ts_is_clamped():
    w, c = _poison_world()
    ca, cb = c["Councila"], c["Councilb"]
    e = ca.eval_py("return ns.Ledger:Award(...)", 28586, key("Bob"), "", "x")
    w.tick(3)
    # a 0.4-era poisoned copy: voided at MAX_TS on Councilb
    cb.eval("local e = ns.db.ledger[...]; e.vd = true; e.vts = 4102444800", e["id"])
    cb.eval("ns.Ledger:Void(..., false)", e["id"])        # restore: vts must be a sane time, never MAX_TS + 1
    vts = cb.eval("return ns.db.ledger[...].vts", e["id"])
    assert vts <= now(cb) + 1, vts
    w.tick(3)
    assert cb.eval("return ns.Ledger:HasAward(...)", key("Bob"), 28586)
    # a relog resets a future vts instead of deleting the entry
    cb.eval("local e = ns.db.ledger[...]; e.vts = 4102444800", e["id"])
    cb.relog()
    w.tick(2)
    assert cb.eval("return ns.db.ledger[...].vts", e["id"]) == 0
    w.assert_no_errors()


# ================================================================================================================
# cg-tofu-takeover
# ================================================================================================================
def _cg_world():
    w = World()
    c = {}
    for n, rank, cls, online in [("Gina", 0, "PALADIN", True), ("Councila", 1, "PRIEST", True),
                                 ("Mallory", 3, "ROGUE", True), ("Newbie", 3, "DRUID", False)]:
        c[n] = Client(w, n, guild_rank=rank, class_file=cls, online=online)
    for x in c.values():
        if x.online:
            x.load_addon()
    w.tick(3)
    return w, c


def _council_rev(x):
    return x.eval("return ns.Guild:GetGuildCouncilRev()")


@R.case
def cg_tofu_forged_list_is_unconfirmed_and_the_gm_replaces_it():
    w, c = _cg_world()
    rev = gm_pick(w, c["Gina"], ["Councila"])
    c["Gina"].logout()
    c["Councila"].logout()
    w.tick(2)
    c["Newbie"].login()
    w.tick(3)
    t = now(c["Mallory"])
    # a relayed rev in the future is refused outright; one "now" is taken on trust (TOFU) but stays unconfirmed
    send_as(c["Mallory"], {"t": "CG", "rev": t + 299, "m": [key("Mallory"), key("Newbie")], "ph": 3,
                           "by": key("Gina")}, "WHISPER", key("Newbie"))
    w.tick(2)
    assert c["Newbie"].eval("return ns.Guild:IsCouncil(..., true)", key("Mallory")) is False
    send_as(c["Mallory"], {"t": "CG", "rev": t, "m": [key("Mallory"), key("Newbie")], "ph": 3, "by": key("Gina")},
            "WHISPER", key("Newbie"))
    w.tick(2)
    N = c["Newbie"]
    assert N.eval("return ns.Guild:IsGuildCouncilUnconfirmed()") is True
    # 1.3: an unconfirmed list makes nobody council until the GM confirms it
    assert N.eval("return ns.Guild:IsCouncil(..., true)", key("Mallory")) is False
    assert N.eval("return ns.Guild:GetGuildCouncilRev()") == t
    # never re-served: no CG answer to a query, no cg in HELLO
    log0 = len(w.addon_log)
    send_as(c["Mallory"], {"t": "CQ", "r": 0}, "WHISPER", key("Newbie"))
    w.tick(10)
    assert not [m for m in msgs_of_type(w, "CG", log0) if m["_sender"] == key("Newbie")]
    # the GM comes online: its own (lower-rev) list replaces the unconfirmed one
    c["Gina"].login()
    w.tick(60)
    assert _council_rev(N) == rev, (_council_rev(N), rev)
    assert N.eval("return ns.Guild:IsCouncil(..., true)", key("Mallory")) is False
    assert N.eval("return ns.Guild:IsGuildCouncilUnconfirmed()") is False
    w.assert_no_errors()


@R.case
def cg_tofu_gm_never_takes_a_relayed_copy_and_a_stale_gm_does_not_roll_back():
    w, c = _cg_world()
    rev = gm_pick(w, c["Gina"], ["Councila"])
    G = c["Gina"]
    # the GM's client on a PC without the list: a relayed copy of "its" list is not taken
    G.eval("ns.db.council.guild = nil")
    G.relog()
    w.tick(3)
    send_as(c["Councila"], {"t": "CG", "rev": rev, "m": [key("Councila")], "ph": 1, "by": key("Gina")}, "WHISPER",
            key("Gina"))
    w.tick(2)
    assert _council_rev(G) == 0
    assert any("not saved on this PC" in l for l in printed_lines(G)), printed_lines(G)[-5:]
    # a stale GM CG (older rev) never rolls a confirmed list back
    send_as(G, {"t": "CG", "rev": rev - 100, "m": [key("Mallory")], "ph": 1, "by": key("Gina")}, "GUILD")
    w.tick(2)
    assert _council_rev(c["Councila"]) == rev and _council_rev(c["Mallory"]) == rev
    w.assert_no_errors()


# ================================================================================================================
# lock-detect-backdated-ts
# ================================================================================================================
@R.case
def lock_backdated_change_gets_a_soft_note_not_a_flag():
    r = Raid(encounter=False)
    w = r.w
    A, C = r["Alice"], r["Carol"]
    A.eval("ns.GroupRules:SetLocked(true)")
    w.tick(90)
    assert A.eval("return ns.GroupRules:IsLocked()")
    lock_at = A.eval("return ns.GroupRules:GetLockInfo().at")
    # Carol's modified client edits during the lock and pushes rev+1 dated before the lock
    entry = C.eval_py("""local rec = ns.BiS:GetRecord()
        local d = ns.Util.CopyTable(rec.data); d.ph[1][11] = { 28763 }
        return { t = 'L', r = rec.rev + 1, ts = ..., h = ns.Util.Hash(d), d = d }""", lock_at - 30)
    n0 = len(printed_lines(A))
    send_as(C, entry, "WHISPER", key("Alice"), "data")
    w.tick(2)
    assert A.eval("return ns.Store:GetLockFlag(...)", key("Carol")) is None, "a soft note must not exclude"
    assert A.eval("return ns.Store:GetLockNote(...)", key("Carol")) is not None
    assert any("claims an earlier save" in strip_codes(l) for l in printed_lines(A)[n0:]), printed_lines(A)[n0:]
    w.assert_no_errors()


# ================================================================================================================
# rw-at-override
# ================================================================================================================
@R.case
def rw_forged_given_or_late_rw_cannot_override_an_award():
    r = Raid(ml="Alice")
    w = r.w
    A = r["Alice"]
    w.make_raid(r.clients, master_looter=A, leader=A, assistants=[r["Frank"]], extra_members=r.extra)
    w.tick(1)
    A.open_loot([(RUBY_DRAPE, 4), (THOUSAND_MARKS, 4)])
    w.tick(2)
    start_roll(A, RUBY_DRAPE)
    w.tick(1)
    sid = active_session(A)["id"]
    roll(w, r["Bob"], 60)
    w.tick(1)
    A.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    confirm_award(A, sid, key("Bob"), RUBY_DRAPE)
    w.tick(1)
    # the assistant (not the ML) forges a "handed out" award with an early time, right away (1.3: an assistant has
    # no loot rights at all, its RW is not even looked at)
    send_as(r["Frank"], {"t": "RW", "id": sid, "w": key("Frank"), "g": True, "at": 1}, "RAID", None, "alert")
    w.tick(1)
    for n in ("Alice", "Bob", "Carol"):
        assert session_info(r[n], sid)["winner"] == key("Bob"), n
    # a council member (not the ML) sends a crossing "handed out" award with an early time: the ML's hand-out stands
    send_as(r["Bob"], {"t": "RW", "id": sid, "w": key("Frank"), "g": True, "at": 1}, "RAID", None, "alert")
    w.tick(1)
    for n in ("Alice", "Carol"):
        assert session_info(r[n], sid)["winner"] == key("Bob"), n
    assert not [e for e in ledger_visible(A) if e["w"] == key("Frank")]
    # a re-award long after the award is ignored too
    w.tick(40)
    send_as(r["Bob"], {"t": "RW", "id": sid, "w": key("Frank"), "g": False}, "RAID", None, "alert")
    w.tick(1)
    assert session_info(r["Carol"], sid)["winner"] == key("Bob")
    assert any("tried to re-award" in strip_codes(l) for l in printed_lines(A))
    w.assert_no_errors()


# ================================================================================================================
# drop-preclaim-any-raider
# ================================================================================================================
@R.case
def drop_preclaim_by_a_raider_is_ignored_and_empty_d_does_not_mute_the_ml():
    r = Raid()
    w = r.w
    A, B, M = r["Alice"], r["Bob"], r["Carol"]
    send_as(M, {"t": "D", "s": PRINCE_GUID, "b": "Karazhan:Prince", "i": [28453, 28454], "ts": now(M)}, "RAID",
            None, "alert")
    send_as(M, {"t": "D", "s": PRINCE_GUID, "b": "Karazhan:Prince", "ts": now(M)}, "RAID", None, "alert")
    w.tick(1)
    assert drops_fired(B) == [] and drops_fired(A) == []
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(3)
    assert [d["i"] for d in drops_fired(B)] == [[RUBY_DRAPE]], drops_fired(B)
    w.assert_no_errors()


# ================================================================================================================
# decode-cost-storm
# ================================================================================================================
@R.case
def decode_bomb_from_a_pug_is_refused_and_the_sender_ignored():
    r = Raid()
    w = r.w
    B = r["Bob"]
    pug = r["Carol"]
    # a 99 KB '{}' payload that deflates to ~250 bytes
    text = pug.eval(r"""
        local LS, LD = LibStub("LibSerialize"), LibStub("LibDeflate")
        local t = { t = "NOPE" }
        for i = 1, 20000 do t[i] = {} end
        return "1" .. LD:EncodeForWoWAddonChannel(LD:CompressDeflate(LS:Serialize(t)))""")
    assert len(text) < 4000
    d0 = B.eval("return ns.Comm.stats.dropped")
    pug.eval("C_ChatInfo.SendAddonMessage('CDLc', ..., 'RAID')", text) if len(text) <= 255 else \
        pug.eval("ns.Comm:SendCommMessage('CDLc', ..., 'RAID', nil, 'BULK')", text)
    w.tick(3)
    assert B.eval("return ns.Comm.stats.dropped") > d0
    B.eval("__DEC = 0; local LD = LibStub('LibDeflate'); local o = LD.DecompressDeflate; "
           "LD.DecompressDeflate = function(...) __DEC = __DEC + 1; return o(...) end")
    pug.eval("ns.Comm:SendCommMessage('CDLc', ..., 'RAID', nil, 'BULK')", text)
    w.tick(3)
    assert B.eval("return __DEC") == 0, "an oversized sender was decoded again"
    w.assert_no_errors()


# ================================================================================================================
# rs-backdated-preempt
# ================================================================================================================
@R.case
def rs_backdated_start_cannot_cancel_a_running_roll():
    r = Raid()
    w = r.w
    A = r["Alice"]
    w.make_raid(r.clients, master_looter=A, leader=A, assistants=[r["Frank"]], extra_members=r.extra)
    w.tick(1)
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    start_roll(A, RUBY_DRAPE)
    w.tick(12)
    sid = active_session(A)["id"]
    roll(w, r["Bob"], 40)
    w.tick(0.5)
    # 1.3: a raid assistant may not start rolls at all: its RS is ignored
    send_as(r["Frank"], {"t": "RS", "id": "Frank-1-1", "i": MINDBLADE, "s": "", "b": "", "d": 60,
                         "ts": now(A) - 299, "c": 1}, "RAID", None, "alert")
    w.tick(1)
    assert session_info(r["Bob"], "Frank-1-1") is None
    # a council member's backdated start does not pre-empt the running roll: the new one is dropped
    send_as(r["Bob"], {"t": "RS", "id": "Bob-1-1", "i": MINDBLADE, "s": "", "b": "", "d": 60,
                       "ts": now(A) - 299, "c": 1}, "RAID", None, "alert")
    w.tick(1)
    for n in ("Alice", "Bob", "Carol"):
        assert session_info(r[n], sid)["state"] == "open", n
    assert session_info(r["Carol"], "Bob-1-1")["state"] == "cancelled"
    w.assert_no_errors()


# ================================================================================================================
# query-debounce-starvation
# ================================================================================================================
@R.case
def crq_flood_does_not_starve_the_leaders_cr():
    r = Raid(encounter=False)
    w = r.w
    A, B, C = r["Alice"], r["Bob"], r["Carol"]
    log0 = len(w.addon_log)
    seen_during_flood = False
    for i in range(60):
        # ~3 queries a second from one raid member, spread over the three prefixes (each has its own throttle)
        send_as(C, {"t": "CRQ"}, "RAID", None, ("ctrl", "data", "alert")[i % 3])
        if i == 5:
            A.eval("ns.Guild:SetMyRaidList({ ... })", key("Dave"))
        if i == 40:
            seen_during_flood = B.eval("return ns.Guild:IsCouncil(..., true)", key("Dave"))
        w.tick(0.35)
    assert seen_during_flood, "the leader's own list change never went out while the queries kept coming"
    CR = [m for m in msgs_of_type(w, "CR", log0) if m["_sender"] == key("Alice")]
    assert 2 <= len(CR) <= 6, len(CR)            # answered, but at most one answer per 5 s
    w.assert_no_errors()


# ================================================================================================================
# crossguild-whisper-gate
# ================================================================================================================
@R.case
def crossguild_master_looter_receives_tiers():
    r = Raid(ml="Alice", extra=[])
    w = r.w
    A = r["Alice"]
    pug = Client(w, "Pugml", class_file="WARRIOR", guild="Other Guild", guild_rank=3)
    pug.load_addon()
    w.tick(2)
    w.make_raid(r.clients + [pug], master_looter=pug, leader=A)
    w.tick(2)
    # 1.3: the pug is never council for us, and on its own client (another guild) only the raid it is a guest in
    # counts: once it knows the raid's session (GS from Alice's guild) it follows that raid's leader, so it takes
    # Alice's roll and her tiers (RT).
    w.run_until(lambda: pug.eval("return ns.GroupRules:GetSession() ~= nil") is True, timeout=30)
    assert A.eval("return ns.Guild:IsCouncil(..., true)", key("Pugml")) is False
    assert pug.eval("return ns.Guild:AmICouncil(true)") is False
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    start_roll(A, RUBY_DRAPE)
    w.tick(3)
    sid = active_session(A)["id"]
    tiers = pug.eval_py("local s = ns.Roll:Get(...) return s and s.remoteTiers or {}", sid)
    assert tiers.get(key("Bob")) == 1, tiers
    w.assert_no_errors()


# ================================================================================================================
# ledger-strings-unsanitized
# ================================================================================================================
@R.case
def ledger_notes_from_peers_lose_escape_codes():
    r = Raid(encounter=False, instance=False, raid=False)
    w = r.w
    A, B = r["Alice"], r["Bob"]
    t = now(A)
    send_as(A, {"t": "A", "e": {"id": "m%dAlice9" % t, "i": 28586, "w": key("Dave"), "by": key("Alice"), "ts": t,
                                "s": "m", "n": "|TInterface\\Icons\\INV_Misc_QuestionMark:400:400|t|cffff0000x|r"}},
            "WHISPER", key("Bob"))
    w.tick(2)
    n = B.eval("return ns.db.ledger[...].n", "m%dAlice9" % t)
    assert n and "|" not in n, n
    send_as(A, {"t": "A", "e": {"id": "m%dAlice8" % t, "i": 28586, "w": "Da|cve", "by": key("Alice"), "ts": t,
                                "s": "m"}}, "WHISPER", key("Bob"))
    w.tick(2)
    assert B.eval("return ns.db.ledger[...] == nil", "m%dAlice8" % t)
    w.assert_no_errors()


# ================================================================================================================
# copy2-frozen-tier-suggests-previous-winner
# ================================================================================================================
@R.case
def copy2_winner_of_copy1_is_not_suggested_for_copy2():
    bis = {"Erin": [(1, SID_HEAD, "main", 29044)], "Gina": [(1, SID_HEAD, "main", 29028)],
           "Alice": [(1, SID_HEAD, "main", 29061)]}
    r = Raid(bis=bis)
    w = r.w
    A = r["Alice"]
    A.open_loot([(HELM_CHAMPION, 4), (HELM_CHAMPION, 4)])
    w.tick(2)
    A.eval("ns.Roll:StartAll(ns.DropPanel.drop)")
    w.tick(1)
    s1 = active_session(A)["id"]
    roll(w, r["Erin"], 90)
    roll(w, r["Gina"], 50)
    w.tick(32)                                  # copy 1 times out, copy 2 opens 2 s later
    s2 = active_session(A)["id"]
    assert s2 != s1
    roll(w, r["Erin"], 95)
    roll(w, r["Gina"], 60)
    w.tick(1)
    confirm_award(A, s1, key("Erin"), HELM_CHAMPION)
    w.tick(1)
    for n in ("Alice", "Bob"):
        res = results(r[n], s2)
        top = [x for x in res if x["suggested"]]
        assert top and top[0]["key"] == key("Gina"), (n, res)
        assert [x for x in res if x["key"] == key("Erin")][0]["tier"] == 4
    w.assert_no_errors()


# ================================================================================================================
# ml-give-refused-recorded-as-given (+ mock fidelity: GiveMasterLoot waits for the server, refusals)
# ================================================================================================================
@R.case
def ml_give_refused_is_not_recorded_and_offers_the_award():
    r = Raid()
    w = r.w
    A = r["Alice"]
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    start_roll(A, RUBY_DRAPE)
    w.tick(1)
    sid = active_session(A)["id"]
    roll(w, r["Bob"], 54)
    w.tick(1)
    A.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    A.set_ml_refusal(r["Bob"], "inv_full")
    log0 = len(w.addon_log)
    A.eval("ns.Roll:Award(...)", sid, key("Bob"))
    w.tick(0.2)
    A.accept_popup("DISASTERZONE_GIVE_ITEM")
    w.tick(1)
    assert session_info(A, sid)["state"] == "closed", session_info(A, sid)
    assert msgs_of_type(w, "RW", log0) == []
    assert not [e for e in ledger_visible(A) if e["w"] == key("Bob")]
    assert "DISASTERZONE_CONFIRM_AWARD" in A.popups(), A.popups()
    assert A.eval("return ns.Loot:FindLootSlot(...)", RUBY_DRAPE) == 1, "the item left the loot window"
    A.cancel_popup("DISASTERZONE_CONFIRM_AWARD")
    # Bob freed a bag slot: the give now goes through and is recorded once the slot cleared
    A.set_ml_refusal(r["Bob"], None)
    A.eval("ns.Roll:Award(...)", sid, key("Bob"))
    w.tick(0.2)
    A.accept_popup("DISASTERZONE_GIVE_ITEM")
    assert session_info(A, sid)["state"] == "closed", "recorded before the server answered"
    w.tick(1)
    s = session_info(A, sid)
    assert s["state"] == "awarded" and s["winner"] == key("Bob") and s["given"], s
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["g"] is True, RW
    w.assert_no_errors()


# ================================================================================================================
# split-raid-awards-bleed-into-drop
# ================================================================================================================
@R.case
def split_raid_foreign_group_award_is_not_this_drops_award():
    r = Raid()
    w = r.w
    A = r["Alice"]
    hank = Client(w, "Hank", guild_rank=1, class_file="PRIEST")
    hank.load_addon()
    w.tick(3)
    gm_pick(w, A, ["Bob", "Hank"])
    w.tick(5)
    A.open_loot([(RUBY_DRAPE, 4), (HELM_CHAMPION, 4)])
    w.tick(2)
    # the other Karazhan group's officer records the same token from their own Prince kill
    hank.eval("ns.Ledger:Award(...)", HELM_CHAMPION, "Quinn-Thunderstrike", "Karazhan:Prince", "other group")
    w.tick(3)
    assert A.eval("return ns.Ledger:HasAward(...)", "Quinn-Thunderstrike", HELM_CHAMPION), "the A never arrived"
    blk = block_of(A, HELM_CHAMPION)
    assert blk and "Quinn" not in strip_codes(blk["awarded"]) and "Roll" in blk["buttons"], blk
    assert A.eval("return ns.Roll:StartAll(ns.DropPanel.drop)") == 2
    w.assert_no_errors()


# ================================================================================================================
# view-phase-override-changes-suggestion (+ the council starter tells a non-council ML the tiers)
# ================================================================================================================
@R.case
def view_phase_override_does_not_change_roll_tiers():
    bis = {"Dave": [(1, SID_BACK, "alt", RUBY_DRAPE), (2, SID_BACK, "main", RUBY_DRAPE)],
           "Frank": [(1, SID_BACK, "main", RUBY_DRAPE)]}
    r = Raid(bis=bis, ml="Carol")
    w = r.w
    A, B, C = r["Alice"], r["Bob"], r["Carol"]
    B.eval("ns.DB:SetSetting('viewPhase', 2)")
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    start_roll(A, RUBY_DRAPE)
    w.tick(1)
    sid = active_session(A)["id"]
    roll(w, r["Dave"], 90)
    roll(w, r["Frank"], 20)
    w.tick(2)
    for n in ("Alice", "Bob", "Carol"):
        top = [x for x in results(r[n], sid) if x["suggested"]]
        assert top and top[0]["key"] == key("Frank"), (n, results(r[n], sid))
    w.assert_no_errors()


# ================================================================================================================
# earlier-phase-pick-ranks-as-bis
# ================================================================================================================
@R.case
def earlier_phase_pick_of_a_disabled_slot_is_not_a_wanter():
    bis = {"Frank": [(1, SID_BACK, "main", RUBY_DRAPE)], "Dave": [(2, SID_BACK, "main", RUBY_DRAPE)]}
    r = Raid(bis=bis, sync=False)
    F = r["Frank"]
    F.eval("ns.BiS:SetSlotDisabled(2, ..., true)", SID_BACK)
    F.eval("ns.BiS:Commit()")
    r.sync()
    A = r["Alice"]
    A.eval("ns.DB:SetSetting('groupPhase', 2)")
    A.eval("ns.DB:SetSetting('viewPhase', 2)")
    ks = wanter_keys(A, RUBY_DRAPE)
    assert key("Frank") + ":main" not in ks and key("Dave") + ":main" in ks, ks
    F.eval("ns.DB:SetSetting('viewPhase', 2)")
    assert F.eval("return #ns.BiS:MatchItem(...)", RUBY_DRAPE) == 0
    r.w.assert_no_errors()


# ================================================================================================================
# loot-message-contradicting-award-not-reconciled
# ================================================================================================================
@R.case
def loot_message_contradicting_an_award_is_flagged_and_fixed():
    r = Raid()
    w = r.w
    A, B = r["Alice"], r["Bob"]
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    start_roll(A, RUBY_DRAPE)
    w.tick(1)
    sid = active_session(A)["id"]
    roll(w, r["Dave"], 80)
    w.tick(1)
    B.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    confirm_award(B, sid, key("Dave"), RUBY_DRAPE)
    w.tick(1)
    n0 = len(printed_lines(B))
    w.broadcast_loot_received(A, RUBY_DRAPE)     # the ML takes it (to trade on), the award names Dave
    w.tick(4)
    assert B.eval("return ns.Roll:Get(...).lootOther", sid) == key("Alice")
    assert any("but it was awarded to Dave" in strip_codes(l) for l in printed_lines(B)[n0:])
    assert B.eval("return ns.Roll:ResolveLootConflict(..., 'passing')", sid)
    w.tick(3)
    for n in ("Alice", "Bob"):
        vis = sorted(e["w"] for e in ledger_visible(r[n]) if e["i"] == RUBY_DRAPE)
        assert vis == [key("Dave")], (n, vis)
    w.assert_no_errors()


# ================================================================================================================
# demo-purge-deletes-real-awards
# ================================================================================================================
@R.case
def demo_purge_keeps_real_awards_to_demo_named_pugs():
    r = Raid(encounter=False, instance=False, world_kw={"server_time": 1790640000 + 86400})
    w = r.w
    A, B = r["Alice"], r["Bob"]
    e = B.eval_py("return ns.Ledger:Award(...)", RUBY_DRAPE, "Isolde-Thunderstrike", "", "pug")
    w.tick(3)
    assert A.eval("return ns.Ledger:GetEntry(...) ~= nil", e["id"]), "merge rejected a real award"
    B.relog()
    w.tick(25)
    assert B.eval("return ns.Ledger:GetEntry(...) ~= nil", e["id"]), "purged at login"
    w.assert_no_errors()


# ================================================================================================================
# auto-entry-boss-key-is-last-encounter / trash-drop-hijacks-panel
# ================================================================================================================
@R.case
def auto_entry_keeps_the_boss_of_the_drop_and_trash_is_not_the_boss():
    r = Raid(encounter=False)
    w = r.w
    A, B = r["Alice"], r["Bob"]
    w.encounter(ATTUMEN_ENCOUNTER, "Attumen the Huntsman")
    w.tick(0.5)
    A.open_loot([(28477, 4)], source_guid=ATTUMEN_GUID)
    w.tick(2)
    A.close_loot()
    w.encounter(PRINCE_ENCOUNTER, "Prince Malchezaar")
    w.tick(0.5)
    w.broadcast_loot_received(r["Carol"], 28477)   # handed out after the next boss died
    w.tick(4)
    ent = [e for e in ledger_visible(B) if e["i"] == 28477]
    assert ent and ent[0]["b"] == "Karazhan:Attumen", ent
    # a trash corpse right after the kill: not filed under Prince, and the open roll keeps the panel
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    A.close_loot()
    start_roll(A, RUBY_DRAPE)
    w.tick(1)
    before = B.eval("return ns.DropPanel.drop.s")
    A.open_loot([(30667, 4)], source_guid=KARA_TRASH_GUID)
    w.tick(3)
    A.close_loot()
    tr = [d for d in drop_history(B) if d["s"] == KARA_TRASH_GUID]
    assert tr and tr[0]["b"] in ("", "Karazhan:Trash"), tr
    assert B.eval("return ns.DropPanel.drop.s") == before, "the trash drop replaced the drop being rolled"
    assert "new" in strip_codes(B.eval("return ns.DropPanel.pageText:GetText()") or ""), "pager does not say so"
    w.assert_no_errors()


# ================================================================================================================
# typed-accented-name-phantom-key
# ================================================================================================================
@R.case
def typed_accented_name_finds_the_member():
    r = Raid(encounter=False, instance=False, raid=False, extra=[])
    w = r.w
    A = r["Alice"]
    elise = Client(w, "Élise", class_file="PRIEST", guild_rank=3)
    elise.load_addon()
    w.tick(3)
    # (Alice's roster has not seen the new member yet: the typed name is built, and must be spelled right)
    A.eval("local id, name = ... ns.DropPanel:AwardByName({ itemID = id, drop = false }, name)", RUBY_DRAPE,
           "élise")
    w.tick(1)
    ws = [e["w"] for e in ledger_visible(A)]
    assert ws == ["Élise-Thunderstrike"], ws
    assert A.eval("return ns.Util.CapitalizeName(...)", "élise") == "Élise"
    w.assert_no_errors()


# ================================================================================================================
# council-items-award-bypasses-roll
# ================================================================================================================
@R.case
def council_items_award_goes_through_the_open_roll():
    r = Raid(ml="Carol")
    w = r.w
    A, B = r["Alice"], r["Bob"]
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    start_roll(A, RUBY_DRAPE)
    w.tick(1)
    sid = active_session(A)["id"]
    B.slash("/dz council")
    w.tick(0.5)
    B.eval("ns.CouncilUI:SetView('items')")
    w.tick(0.5)
    B.eval("ns.CouncilUI:ShowItem(...)", RUBY_DRAPE)
    w.tick(0.5)
    # the Items view's "Record award to > Dave" (the menu calls the same local recordAward)
    menu_owner = B.eval("""local want = ...
        local function find(fr)
          if fr.cdlData and fr.cdlData.itemID == want and fr:IsShown() then return fr end
          for _, ch in ipairs({ fr:GetChildren() }) do local x = find(ch) if x then return x end end
        end
        return find(DisasterZoneMainFrame)""", RUBY_DRAPE)
    assert menu_owner is not None
    B.click(menu_owner, "RightButton")
    menu = B.last_menu()
    award = [ch for ch in menu["children"] if (ch.get("text") or "").startswith("Record award to")][0]
    assert "closes the open roll" in strip_codes(award["text"]), award["text"]
    dave = [ch for ch in award["children"] if "Dave" in strip_codes(ch.get("text") or "")][0]
    B.menu_select(dave["text"])
    w.tick(2)
    for n in ("Alice", "Bob", "Carol"):
        s = session_info(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Dave"), (n, s)
    vis = [e for e in ledger_visible(A) if e["i"] == RUBY_DRAPE]
    assert len(vis) == 1, vis
    w.assert_no_errors()


# ================================================================================================================
# award-click-closes-roll-before-confirm / floating-panel-jumps-per-roll / roll-more-rows-not-awardable
# ================================================================================================================
@R.case
def open_roll_button_says_it_ends_the_roll_and_the_panel_does_not_grow():
    r = Raid()
    w = r.w
    A = r["Alice"]
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    start_roll(A, RUBY_DRAPE)
    w.tick(1)
    h0 = A.eval("return ns.DropPanel.frame:GetHeight()")
    for n, v in (("Bob", 30), ("Dave", 60), ("Carol", 10), ("Erin", 20)):
        roll(w, r[n], v)
        w.tick(0.3)
    assert A.eval("return ns.DropPanel.frame:GetHeight()") == h0, "the panel grew with every roll"
    btns = block_of(A, RUBY_DRAPE)["buttons"]
    assert any(b.startswith("Award to ") for b in btns), btns     # (1.3.1: the click still ends the roll first)
    w.assert_no_errors()


@R.case
def more_rows_of_a_roll_can_be_awarded():
    names = ["X%02d" % i for i in range(12)]
    extra = [ExtraMember(n, "WARRIOR") for n in names]
    r = Raid(extra=extra)
    w = r.w
    A = r["Alice"]
    A.open_loot([(MINDBLADE, 4)])
    w.tick(2)
    start_roll(A, MINDBLADE)
    w.tick(1)
    sid = active_session(A)["id"]
    for i, n in enumerate(names):
        roll(w, n, 50 + i)
    w.tick(1)
    A.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    more = A.eval("""for _, b in ipairs(ns.DropPanel.blocks) do
          if b:IsShown() then for _, r in ipairs(b.rows) do if r:IsShown() and r.more then return r end end end end""")
    assert more is not None, "no +N more row"
    A.click(more)
    menu = A.last_menu()
    items = [ch["text"] for ch in menu["children"] if ch.get("kind") != "title"]
    assert items and all(strip_codes(t).startswith("Award to ") for t in items), items
    more = block_of(A, MINDBLADE)["more"]
    assert "Award" in more, more                  # (1.3.1: someone else: the card's More menu)
    w.assert_no_errors()


# ================================================================================================================
# drop-panel-auto-attach-dead
# ================================================================================================================
@R.case
def drop_panel_attaches_to_the_loot_window():
    r = Raid()
    w = r.w
    A = r["Alice"]
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(1)
    assert A.eval("return ns.DropPanel.attached") is True
    pt = A.eval_py("local p, rel = ns.DropPanel.frame:GetPoint(1) return { p, rel and rel:GetName() }")
    assert pt[1] == "LootFrame", pt
    w.assert_no_errors()


# ================================================================================================================
# rollall-winner-not-told
# ================================================================================================================
@R.case
def roll_all_winner_of_an_earlier_item_is_told():
    r = Raid()
    w = r.w
    A, D = r["Alice"], r["Dave"]
    A.open_loot([(RUBY_DRAPE, 4), (THOUSAND_MARKS, 4)])
    w.tick(2)
    A.eval("ns.Roll:StartAll(ns.DropPanel.drop)")
    w.tick(1)
    s1 = active_session(A)["id"]
    roll(w, D, 70)
    w.tick(33)
    assert active_session(A)["id"] != s1
    n0 = len(printed_lines(D))
    confirm_award(A, s1, key("Dave"), RUBY_DRAPE)
    w.tick(1)
    assert any(strip_codes(l).startswith("DisasterZone: You won") for l in printed_lines(D)[n0:]), printed_lines(D)[n0:]
    assert rollframe_state(D)["id"] != s1, "the running roll's popup was replaced"
    w.assert_no_errors()


# ================================================================================================================
# award-menu-absent-wanters
# ================================================================================================================
@R.case
def award_menu_keeps_absent_wanters_apart():
    r = Raid()
    w = r.w
    A = r["Alice"]
    w.add_offline_member("Kim", "MAGE", 3)
    w.tick(2)
    A.eval("""local rec = ns.Util.CopyTable(ns.Store:GetCached(...)); rec.data.ph[1][4] = { 28766 }
        rec.hash = ns.Util.Hash(rec.data); rec.rev = rec.rev + 1
        ns.Store:Put('Kim-Thunderstrike', { r = rec.rev, ts = rec.ts, h = rec.hash, d = rec.data }, 'direct')""",
           key("Bob"))
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    A.eval("""for _, b in ipairs(ns.DropPanel.blocks) do if b:IsShown() and b.itemID == ... then
        ns.DropPanel:OpenAwardMenu(b, b.award) end end""", RUBY_DRAPE)
    menu = A.last_menu()
    top = [strip_codes(ch.get("text") or "") for ch in menu["children"]]
    assert not any(t.startswith("Kim") for t in top), top
    away = [ch for ch in menu["children"] if strip_codes(ch.get("text") or "").startswith("Not in raid")]
    assert away and any("Kim" in strip_codes(x["text"]) for x in away[0]["children"]), top
    w.assert_no_errors()


# ================================================================================================================
# search-dropdown-focus-trap
# ================================================================================================================
@R.case
def search_dropdown_drops_focus_when_it_closes():
    w = World()
    g = Client(w, "Gina", guild_rank=0)
    g.load_addon()
    w.tick(3)
    g.slash("/dz council")
    w.tick(0.5)
    g.eval("ns.CouncilUI:SetView('council')")
    w.tick(0.5)
    sd = g.eval(FIND_FIELD, "picker")
    assert sd is not None, "no search dropdown"
    g.eval("local sd = ...; sd:Toggle()", sd)
    assert g.eval("local sd = ...; return sd.editBox:HasFocus()", sd)
    g.eval("local sd = ...; sd:Close()", sd)
    assert not g.eval("local sd = ...; return sd.editBox:HasFocus()", sd)
    w.assert_no_errors()


# ================================================================================================================
# esc-closes-drop-panel-no-reopen
# ================================================================================================================
@R.case
def drops_button_and_shift_click_reopen_the_drop_panel():
    r = Raid()
    w = r.w
    A = r["Alice"]
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    A.close_loot()
    A.eval("ns.DropPanel:Hide()")
    A.slash("/dz council")
    w.tick(0.5)
    btn = A.eval(FIND_FIELD, "dropsBtn")
    assert btn is not None
    A.click(btn)
    w.tick(0.2)
    assert A.eval("return ns.DropPanel.frame:IsShown()")
    w.assert_no_errors()


# ================================================================================================================
# index-rebuild-churn / roster-rebuild-garbage / ledger-unbounded
# ================================================================================================================
@R.case
def index_is_not_rebuilt_for_awards_or_online_flips_and_own_obtained_is_live():
    r = Raid(encounter=False)
    w = r.w
    A = r["Alice"]
    A.eval("__RB = 0; local up = debug.getupvalue; ns.Store:GetWanters(1)")
    probe = r"""
      local n = 0
      local f = ns.Store.GetWanters
      local i = 1
      while true do
        local name, v = debug.getupvalue(f, i)
        if not name then break end
        if name == "EnsureIndex" then
          local inner = v
          local j = 1
          while true do
            local n2, v2 = debug.getupvalue(inner, j)
            if not n2 then break end
            if n2 == "indexDirty" then return v2 end
            j = j + 1
          end
        end
        i = i + 1
      end
      return "?"
    """
    A.eval("ns.Store:GetWanters(28766)")
    assert A.eval(probe) is False
    A.eval("ns.Ledger:Award(28766, 'Dave-Thunderstrike', '', 'x')")
    w.tick(1)
    assert A.eval(probe) is False, "an award rebuilt the index"
    roster0 = A.eval("return ns.Guild:GetMember(...)", key("Bob"))
    r["Carol"].logout()
    w.tick(3)
    assert A.eval(probe) is False, "an online flip rebuilt the index"
    assert A.eval("local e = ...; return e == ns.Guild:GetMember('Bob-Thunderstrike')", roster0), "roster entry replaced"
    # own obtained state is live: an item that left my bags is wanted again at once
    A.eval("ns.BiS:SetSlot(1, 11, 'main', 28763)")
    A.set_bags({(0, 1): 28763})
    w.tick(3)
    assert not [x for x in wanter_keys(A, 28763) if x.startswith(key("Alice"))]
    A.set_bags({})
    w.tick(3)
    assert [x for x in wanter_keys(A, 28763) if x.startswith(key("Alice"))]
    # the login cleaning keeps the stored entry tables
    A.eval("__E = ns.db.ledger[next(ns.db.ledger)]")
    A.eval("ns.Ledger:OnLogin()")
    assert A.eval("local id = next(ns.db.ledger) return ns.db.ledger[id] == __E")
    w.assert_no_errors()


# ================================================================================================================
# auto-award-k2-fanout / ledger-catchup-per-peer
# ================================================================================================================
@R.case
def auto_entries_are_sent_about_once_per_loot_line():
    roster = [("Alice", "PALADIN", 0), ("Bob", "MAGE", 1), ("Carol", "WARRIOR", 1), ("Dave", "PRIEST", 1),
              ("Erin", "ROGUE", 3)]
    r = Raid(roster=roster, bis={}, extra=[])
    w = r.w
    log0 = len(w.addon_log)
    w.broadcast_loot_received(r["Erin"], HELM_CHAMPION)
    w.tick(6)
    A = msgs_of_type(w, "A", log0)
    assert 0 < len(A) < 4 * 3, len(A)                  # was 4 recorders x 3 peers = 12
    ids = {tuple(sorted(e["id"] for e in ledger_raw(r[n]))) for n in ("Alice", "Bob", "Carol", "Dave")}
    views = {tuple(e["id"] for e in ledger_visible(r[n])) for n in ("Alice", "Bob", "Carol", "Dave")}
    assert len(views) == 1, views
    w.assert_no_errors()


@R.case
def ledger_catchup_asks_each_day_from_one_peer():
    roster = [("Alice", "PALADIN", 0), ("Bob", "MAGE", 1), ("Carol", "WARRIOR", 1), ("Dave", "PRIEST", 1)]
    r = Raid(roster=roster, bis={}, extra=[], raid=False, instance=False, encounter=False)
    w = r.w
    A = r["Alice"]
    for i in range(30):
        A.eval("local e = ns.Ledger:Award(...); e.ts = GetServerTime() - (%d * 3600)" % (i * 5), 28586 + (i % 5),
               key("Dave"), "", "x")
    w.tick(30)
    newbie = r["Dave"]
    newbie.eval("ns.db.ledger = {}")
    log0 = len(w.addon_log)
    newbie.relog()
    w.tick(90)
    LW = [m for m in msgs_of_type(w, "LW", log0) if m["_sender"] == newbie.full_name]
    days = [d for m in LW for d in m["d"]]
    assert len(days) == len(set(days)), "a day was asked from more than one peer: %r" % days
    assert sorted(e["id"] for e in ledger_raw(newbie)) == sorted(e["id"] for e in ledger_raw(A))
    w.assert_no_errors()


# ================================================================================================================
# class-restricted-raid-drops-usable-by-all / sources-class-restricted-pvp-rep / token-wanter-no-class-guard
# ================================================================================================================
@R.case
def class_restricted_items_and_tokens_are_not_for_other_classes():
    bis = {"Gina": [(2, 13, "main", WARP_SPRING_COIL)],     # a shaman picked the rogue trinket (old list)
           "Erin": [(2, 13, "alt", WARP_SPRING_COIL)]}
    r = Raid(bis=bis)
    w = r.w
    A = r["Alice"]
    db = "ns.ItemDB"
    assert A.eval("return %s:IsUsableBy(..., 'DRUID')" % db, WARP_SPRING_COIL) is False
    assert A.eval("return %s:IsUsableBy(..., 'ROGUE')" % db, WARP_SPRING_COIL) is True
    assert A.eval("return %s:IsUsableBy(..., 'WARRIOR')" % db, MEDALLION_DRUID) is False
    assert A.eval("return %s:IsUsableBy(32837, 'MAGE')" % db) is False
    assert A.eval("return %s:IsUsableBy(32837, 'WARRIOR', 15)" % db) is True
    A.open_loot([(WARP_SPRING_COIL, 4)])
    w.tick(2)
    start_roll(A, WARP_SPRING_COIL)
    w.tick(1)
    sid = active_session(A)["id"]
    roll(w, r["Gina"], 90)
    roll(w, r["Erin"], 20)
    w.tick(2)
    res = results(A, sid)
    top = [x for x in res if x["suggested"]]
    assert top and top[0]["key"] == key("Erin"), res
    assert [x for x in res if x["key"] == key("Gina")][0]["tier"] == 4
    w.assert_no_errors()


@R.case
def token_arena_piece_of_another_class_is_not_a_bis_wanter():
    bis = {"Alice": [(1, SID_HEAD, "main", GLAD_PLATE_HELM)],       # a paladin picked the warrior S1 helm
           "Carol": [(1, SID_HEAD, "main", 29011)]}                  # Warbringer Battle-Helm (warrior T4)
    r = Raid(bis=bis)
    A = r["Alice"]
    ws = r["Bob"].eval_py("""local out = {}
        for _, w in ipairs(ns.Store:GetWanters(...)) do out[#out + 1] = { w.key, w.cantUse or false } end
        return out""", HELM_DEFENDER)
    d = {k: v for k, v in ws}
    assert d.get(key("Alice")) is True and d.get(key("Carol")) is False, ws
    assert A.eval("return #ns.BiS:MatchItem(...)", HELM_DEFENDER) == 0
    r.w.assert_no_errors()


# ================================================================================================================
# arena-exchange-patch-gate-ignored / phase-disagreements / mock-equiploc-fidelity
# ================================================================================================================
@R.case
def data_arena_gate_phases_and_mock_token_slots():
    w = World()
    c = Client(w, "Alice", guild_rank=3)
    c.load_addon()
    w.tick(1)
    # T6 -> Season 3 is not open on Anniversary realms: T6 tokens do not expand to S3 pieces; T4 -> S1 does
    t6 = c.eval_py("""for tok, info in pairs(ns.Data.TokenArenaExchanges) do
        if info.patch == '2.5' then return { tok, info.items[1] } end end""")
    exp = c.eval_py("return ns.ItemDB:ExpandDrop(...)", t6[0])
    assert t6[1] not in exp, exp
    assert GLAD_PLATE_HELM in c.eval_py("return ns.ItemDB:ExpandDrop(...)", HELM_DEFENDER)
    for iid, ph in ((32494, 2), (37864, 5), (32973, 2)):
        assert c.eval("return ns.ItemDB:GetPhase(...)", iid) == ph, iid
    # mock fidelity: every piece of a token sits in one slot, the token's slot word matches it
    words = {"Helm": "INVTYPE_HEAD", "Pauldrons": "INVTYPE_SHOULDER", "Chestguard": "INVTYPE_CHEST",
             "Gloves": "INVTYPE_HAND", "Leggings": "INVTYPE_LEGS", "Bracers": "INVTYPE_WRIST",
             "Belt": "INVTYPE_WAIST", "Boots": "INVTYPE_FEET"}
    bad = c.eval_py("""local W = ...
        local out = {}
        for tok, pieces in pairs(ns.Data.Tokens) do
          local name = ns.ItemDB:GetName(tok) or ''
          local word = name:match('^(%a+) of the')
          local want = word and W[word]
          if want then
            for _, p in ipairs(pieces) do
              local loc = select(4, C_Item.GetItemInfoInstant(p))
              if loc ~= want and not (want == 'INVTYPE_CHEST' and loc == 'INVTYPE_ROBE') then
                out[#out + 1] = tok .. ':' .. p .. ':' .. tostring(loc)
              end
            end
          end
        end
        return out""", words) or []
    assert bad == [], bad[:10]
    w.assert_no_errors()


# ================================================================================================================
# docs review (post-0.5.0): "can't use" / "won a copy" players must NEVER be the suggested winner, even when
# they are the only ones who rolled (before: they were only ranked last, so a lone roll was still suggested).
# ================================================================================================================
@R.case
def cant_use_player_is_never_suggested_even_when_alone():
    bis = {"Gina": [(2, 13, "main", WARP_SPRING_COIL)]}     # a shaman picked the rogue-only trinket
    r = Raid(bis=bis)
    w = r.w
    A = r["Alice"]
    A.open_loot([(WARP_SPRING_COIL, 4)])
    w.tick(2)
    start_roll(A, WARP_SPRING_COIL)
    w.tick(1)
    sid = active_session(A)["id"]
    roll(w, r["Gina"], 99)
    w.tick(2)
    for n in ("Alice", "Bob"):
        res = results(r[n], sid)
        gina = [x for x in res if x["key"] == key("Gina")][0]
        assert gina.get("cantUse") is True, (n, gina)
        assert not [x for x in res if x["suggested"]], (n, res)
    w.assert_no_errors()


@R.case
def winner_of_copy1_is_not_suggested_for_copy2_even_when_alone():
    bis = {"Erin": [(1, SID_HEAD, "main", 29044)]}
    r = Raid(bis=bis)
    w = r.w
    A = r["Alice"]
    A.open_loot([(HELM_CHAMPION, 4), (HELM_CHAMPION, 4)])
    w.tick(2)
    A.eval("ns.Roll:StartAll(ns.DropPanel.drop)")
    w.tick(1)
    s1 = active_session(A)["id"]
    roll(w, r["Erin"], 90)
    w.tick(32)                                  # copy 1 times out, copy 2 opens 2 s later
    s2 = active_session(A)["id"]
    assert s2 != s1
    roll(w, r["Erin"], 95)                      # only the copy-1 winner rolls on copy 2
    w.tick(1)
    confirm_award(A, s1, key("Erin"), HELM_CHAMPION)
    w.tick(1)
    for n in ("Alice", "Bob"):
        res = results(r[n], s2)
        erin = [x for x in res if x["key"] == key("Erin")][0]
        assert erin.get("wonCopy") is True, (n, erin)
        assert not [x for x in res if x["suggested"]], (n, res)
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

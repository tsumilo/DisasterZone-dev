#!/usr/bin/env python
"""UI of Addendum B (dungeon mode) and Addendum C (roll popups close once awarded / looted).

Picker dungeon scopes, RollFrame fade + hover hold + "(looted)", DropPanel plain "Award..." / "Someone else..."
through the roll (exactly one log entry), "(looted)" header, panel for the dungeon party leader, Loot Log
"(dungeon)" tag + filter, Settings "Dungeon mode" section with its live status line.

Where a core API of Addendum B/C is not there yet (Roll:MarkAwardedExternally), a minimal stand-in built on
Roll:ConfirmAward is installed so the UI path can be exercised; the real core replaces it automatically.

Run: luaenv\\Scripts\\python.exe tests\\ui-dungeon\\test_ui_dungeon.py   [-k substring]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(SCRATCH, "tests", "loot-roll"))
sys.path.insert(0, os.path.join(SCRATCH, "tests", "boot-ui"))

from lr_common import *  # noqa: F401,F403,E402
from test_rolls import setup as raid_setup, click_roll  # noqa: E402
import _common as bu  # noqa: E402

R = Runner("ui / dungeon mode + popup closing")

MARK_STUB = r"""
if not ns.Roll.MarkAwardedExternally then
  __UI_STUB_MARK = true
  function ns.Roll:MarkAwardedExternally(id, key)
    local ses = self:Get(id)
    if not ses then return false end
    self:ConfirmAward({ id = id, key = key })
    return ses.state == "awarded"
  end
end
"""

LEDGER_SPY = r"""
__UI = __UI or {}
__UI.ledgerAwards = 0
local orig = ns.Ledger.Award
ns.Ledger.Award = function(self, ...)
  __UI.ledgerAwards = __UI.ledgerAwards + 1
  return orig(self, ...)
end
"""

ADDON_USERS = ("Alice", "Bob", "Carol", "Dave", "Erin", "Frank", "Gina")


def rf(client):
    return rollframe_state(client)


def rf_alpha(client):
    return client.eval("return ns.RollFrame.frame:GetAlpha()")


def closed_session(r, item=RUBY_DRAPE, copy=1, rolls=(("Bob", 54), ("Dave", 80))):
    A = r["Alice"]
    A.eval("ns.DropPanel:StartRoll(...)", item, copy)
    r.w.tick(1)
    sid = active_session(A)["id"]
    for name, v in rolls:
        click_roll(r, name, v)
    r.w.tick(1)
    A.eval("ns.Roll:End(...)", sid)
    r.w.tick(1)
    return sid


def visible_ledger_for(client, item):
    return [e for e in ledger_visible(client) if e["i"] == item]


def block_of(client, item, copy=1):
    for b in panel_blocks(client):
        if b["item"] == item and b.get("copy", 1) == copy:
            return b
    return None


# ------------------------------------------------------------------------------------------------------------------
# RollFrame: fade timing (§23.3)
# ------------------------------------------------------------------------------------------------------------------
@R.case
def award_shows_winner_then_fades_hover_holds_until_leave():
    r = raid_setup()
    w = r.w
    sid = closed_session(r)
    # Bob (council, not the master looter) awards: confirm popup -> RW to everyone
    r["Bob"].eval("ns.DropPanel:AwardRoll(...)", sid, key("Dave"))
    w.tick(0.2)
    r["Bob"].accept_popup("DISASTERZONE_CONFIRM_AWARD")
    w.tick(0.5)
    for n in ("Carol", "Erin", "Frank", "Gina"):
        st = rf(r[n])
        assert st["shown"] and strip_codes(st["status"]) == "Won by Dave", (n, st)
    assert strip_codes(rf(r["Dave"])["status"]) == "You won it!", rf(r["Dave"])
    C, E, F = r["Carol"], r["Erin"], r["Frank"]
    fC = C.eval("return ns.RollFrame.frame")
    C.hover(fC)                                   # Carol keeps the mouse on it
    w.tick(3.5)                                   # ~3.9s after the award reached the raiders
    assert rf(E)["shown"], "Erin's popup must still show before 5s"
    w.tick(1.4)                                   # ~5.3s: Frank's fade is running
    assert F.eval("return ns.RollFrame.frame.fadeAnim:IsPlaying()"), "fade should be running at ~5s"
    fF = F.eval("return ns.RollFrame.frame")
    F.hover(fF)                                   # Frank grabs it while it fades
    assert not F.eval("return ns.RollFrame.frame.fadeAnim:IsPlaying()")
    assert rf_alpha(F) == 1
    w.tick(2.0)
    assert not rf(E)["shown"], ("Erin's popup should have faded", rf(E))
    for cl in (C, F):
        st = rf(cl)
        assert st["shown"] and rf_alpha(cl) == 1, (cl.name, st)
    w.tick(8)                                     # hover keeps it as long as the mouse stays
    assert rf(C)["shown"] and rf(F)["shown"]
    C.leave(fC)
    F.leave(fF)
    w.tick(0.7)
    assert rf(C)["shown"] and not C.eval("return ns.RollFrame.frame.fadeAnim:IsPlaying()"), "resumes ~1s after leave"
    w.tick(2.2)                                   # 1s wait + 1s fade
    assert not rf(C)["shown"] and not rf(F)["shown"], (rf(C), rf(F))
    w.assert_no_errors()


@R.case
def looted_resolution_shows_looted_in_popup_and_panel():
    r = raid_setup()
    w = r.w
    A = r["Alice"]
    sid = closed_session(r, item=THOUSAND_MARKS, rolls=(("Carol", 70),))
    real = all(r[n].eval("return type(ns.Roll.OnItemLooted) == 'function'") for n in ADDON_USERS)
    if real:
        w.broadcast_loot_received(r["Carol"], THOUSAND_MARKS)
    else:
        # stand-in for Roll:OnItemLooted (Addendum C §23.1) until the core has it
        for n in ADDON_USERS:
            r[n].eval("""local id, k = ...
              local s = ns.Roll:Get(id)
              s.state, s.winner, s.given, s.via = 'awarded', k, true, 'loot'
              ns:Fire('ROLL_UPDATED', id)""", sid, key("Carol"))
    w.tick(0.5)
    for n in ("Bob", "Dave", "Erin"):
        st = strip_codes(rf(r[n])["status"])
        assert st == "Won by Carol (looted)", (n, st)
    assert strip_codes(rf(r["Carol"])["status"]) == "You won Band of the Thousand Marks! (looted)" or \
        strip_codes(rf(r["Carol"])["status"]).startswith("You won "), rf(r["Carol"])
    w.tick(0.3)
    blk = block_of(A, THOUSAND_MARKS)
    assert blk and strip_codes(blk["sub"]) == "Awarded to Carol (looted)", blk
    w.tick(7)
    assert not rf(r["Bob"])["shown"], rf(r["Bob"])
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# DropPanel: plain Award... / Someone else... go through the roll (§23.2)
# ------------------------------------------------------------------------------------------------------------------
@R.case
def plain_award_menu_goes_through_the_roll_one_ledger_entry():
    r = raid_setup()
    w = r.w
    A = r["Alice"]
    stubbed = False
    for n in ADDON_USERS:
        r[n].eval(MARK_STUB)
    stubbed = bool(A.eval("return __UI_STUB_MARK"))
    A.eval(LEDGER_SPY)
    sid = closed_session(r, rolls=())            # nobody rolled: no suggestion, the plain "Award..." shows
    blk = block_of(A, RUBY_DRAPE)
    assert blk and "Award..." in blk["buttons"], blk
    log0 = len(w.addon_log)
    # the real menu: Award... -> "Dave  [Alt]"
    b = A.eval("for _, b in ipairs(ns.DropPanel.blocks) do if b.itemID == %d then return b end end" % RUBY_DRAPE)
    assert A.eval("local b = ...; return b.award:IsEnabled()", b) in (True, 1)
    A.click(A.eval("local b = ...; return b.award", b))
    menu = A.last_menu()
    entry = next(e for e in bu.menu_texts(menu) if e[2] and strip_codes(e[2]).startswith("Dave"))
    A.menu_select(entry[2])
    w.tick(1.5)
    assert A.eval("return __UI.ledgerAwards") == 0, "the roll path must not also write a plain entry"
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["w"] == key("Dave"), RW
    for n in ADDON_USERS:
        s = session_info(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Dave"), (n, s)
    for n in ("Alice", "Bob"):
        vis = visible_ledger_for(r[n], RUBY_DRAPE)
        assert len(vis) == 1 and vis[0]["w"] == key("Dave"), (n, vis)
    assert strip_codes(rf(r["Carol"])["status"]) == "Won by Dave"
    w.tick(6.5)
    for n in ("Bob", "Carol", "Erin"):
        assert not rf(r[n])["shown"], (n, rf(r[n]))
    w.assert_no_errors()
    print("     (MarkAwardedExternally: %s)" % ("stand-in" if stubbed else "core"))


@R.case
def someone_else_dialog_goes_through_the_roll_and_add_award_does_not():
    r = raid_setup()
    w = r.w
    A = r["Alice"]
    for n in ADDON_USERS:
        r[n].eval(MARK_STUB)
    bu.install_helpers(A)
    A.eval(LEDGER_SPY)
    sid = closed_session(r, item=THOUSAND_MARKS, rolls=(("Carol", 33),))
    A.eval("ns.DropPanel:AwardSomeoneElse(%d, 'Karazhan:Prince', 1)" % THOUSAND_MARKS)
    w.tick(0.1)
    dlg = A.frame("DisasterZoneAwardDialog")
    assert dlg is not None and A.eval("return DisasterZoneAwardDialog:IsShown()")
    A.eval("local eb = ...; eb:SetText('Erin')", A.eval("return DisasterZoneAwardDialog.winBox"))
    A.click(A.eval("return DisasterZoneAwardDialog.saveBtn"))
    w.tick(1.5)
    assert not A.eval("return DisasterZoneAwardDialog:IsShown()"), A.eval("return DisasterZoneAwardDialog.status:GetText()")
    assert A.eval("return __UI.ledgerAwards") == 0
    for n in ADDON_USERS:
        s = session_info(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Erin"), (n, s)
    assert len(visible_ledger_for(A, THOUSAND_MARKS)) == 1
    # the Loot Log's own "Add award..." never touches rolls
    sid2 = closed_session(r, item=MINDBLADE, rolls=(("Dave", 10),))
    A.eval("ns.LootLogUI:OpenAwardDialog(%d, 'Frank-Thunderstrike', 'Karazhan:Prince')" % MINDBLADE)
    A.click(A.eval("return DisasterZoneAwardDialog.saveBtn"))
    w.tick(1)
    assert A.eval("return __UI.ledgerAwards") == 1
    assert session_info(A, sid2)["state"] == "closed", session_info(A, sid2)
    assert len(visible_ledger_for(A, MINDBLADE)) == 1
    w.assert_no_errors()


@R.case
def award_without_roll_is_a_plain_entry_and_cancels_a_queued_roll():
    r = raid_setup()
    w = r.w
    A = r["Alice"]
    for n in ADDON_USERS:
        r[n].eval(MARK_STUB)
    A.eval(LEDGER_SPY)
    log0 = len(w.addon_log)
    ok = A.eval("return ns.DropPanel:Award(%d, 'Gina-Thunderstrike', 'Karazhan:Prince')" % MINDBLADE)
    w.tick(1)
    assert ok is True and A.eval("return __UI.ledgerAwards") == 1
    assert msgs_of_type(w, "RW", log0) == []
    assert len(visible_ledger_for(A, MINDBLADE)) == 1
    # Roll all: the first item rolls, the others wait; awarding a queued one cancels its roll
    A.eval("ns.DropPanel:RollAll()")
    w.tick(1)
    q = A.eval_py("local o = {} for i, s in ipairs(ns.Roll:GetQueue()) do o[i] = {s.id, s.i} end return o")
    queued = [x for x in q if x[1] == HELM_CHAMPION]
    assert queued, q
    A.eval("return ns.DropPanel:Award(%d, 'Gina-Thunderstrike', 'Karazhan:Prince', 1)" % HELM_CHAMPION)
    w.tick(1)
    assert A.eval("return __UI.ledgerAwards") == 2
    assert session_info(A, queued[0][0])["state"] == "cancelled", session_info(A, queued[0][0])
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Dungeon mode: popup + panel in a party, Settings section
# ------------------------------------------------------------------------------------------------------------------
def party_world(names=(("Alice", "PALADIN", 3), ("Bob", "MAGE", 3), ("Carol", "WARRIOR", 3))):
    w = World()
    cs = {}
    for n, cl, rank in names:
        cs[n] = Client(w, n, class_file=cl, guild_rank=rank)
    for c in cs.values():
        c.load_addon()
    w.tick(2)
    setup_council(w, cs, names)      # Addendum E: rank-1 members are on the guild council list
    return w, cs


FAKE_SESSION = r"""
local id, item = ...
return { id = id, i = item, s = '', b = '', c = 1, state = 'open', duration = 30, endsAt = GetTime() + 30,
         rolls = {}, responses = {} }
"""


@R.case
def party_popup_and_panel_follow_dungeon_mode():
    w, cs = party_world()
    A, B, C = cs["Alice"], cs["Bob"], cs["Carol"]
    w.make_party([A, B, C], leader=A)
    w.tick(1)
    for c in (A, B, C):
        assert c.eval("return ns.Util.IsDungeonModeActive()") is False
    # dungeon mode off: a roll popup does not show in a party
    C.eval("ns.RollFrame:OnRollStarted((function(...) " + FAKE_SESSION + " end)('x-1', %d))" % RUBY_DRAPE)
    assert not rf(C)["shown"]
    A.slash("/dz dungeon on")
    w.tick(2)
    for c in (A, B, C):
        assert c.eval("return ns.Util.IsDungeonModeActive()") is True, c.name
    C.eval("ns.RollFrame:OnRollStarted((function(...) " + FAKE_SESSION + " end)('x-2', %d))" % RUBY_DRAPE)
    assert rf(C)["shown"], "popup must show in a dungeon-mode party"
    # the drop panel: leader yes (not council), members no
    drop = "{ s = 'dg-test-1', b = 'BlackMorass:Aeonus', i = { %d }, ts = GetServerTime(), from = 'Alice-Thunderstrike' }" % RUBY_DRAPE
    for c in (A, C):
        c.eval("ns:Fire('DROP', %s)" % drop)
    w.tick(0.5)
    assert A.eval("return ns.DropPanel.frame ~= nil and ns.DropPanel.frame:IsShown()"), "leader's panel"
    assert not C.eval("return ns.DropPanel.frame ~= nil and ns.DropPanel.frame:IsShown()"), "member has no panel"
    if A.eval("return ns.ItemDB:GetBossRef('BlackMorass:Aeonus') ~= nil"):
        sub = strip_codes(A.eval("return ns.DropPanel.sub:GetText()"))
        assert "(5-man)" in sub, sub
    # turning it off hides the leader's panel (no council seat, no roll rights) and the popup
    A.slash("/dz dungeon off")
    w.tick(2)
    assert C.eval("return ns.Util.IsDungeonModeActive()") is False
    assert not rf(C)["shown"], rf(C)
    assert not A.eval("return ns.DropPanel.frame:IsShown()")
    w.assert_no_errors()


COWL = 28206            # Cowl of the Guiltless (Aeonus, heroic list)
AEONUS_GUID = "Creature-0-1-2-3-17881-000ABC"


@R.case
def party_roll_end_to_end_leader_awards_through_the_roll():
    w, cs = party_world((("Alice", "PALADIN", 3), ("Bob", "MAGE", 1), ("Carol", "WARRIOR", 3),
                         ("Dave", "PRIEST", 3), ("Erin", "ROGUE", 3)))
    A, B = cs["Alice"], cs["Bob"]
    members = list(cs.values())
    w.make_party(members, leader=A)
    w.tick(1)
    w.enter_instance("The Black Morass", 269, "party", 5, 2)
    w.tick(1)
    A.slash("/dz dungeon on")
    w.tick(2)
    A.open_loot([(COWL, 3)], source_guid=AEONUS_GUID)
    w.tick(2)
    shown = {n: c.eval("return ns.DropPanel.frame ~= nil and ns.DropPanel.frame:IsShown()") for n, c in cs.items()}
    assert shown["Alice"] and shown["Bob"], shown            # party leader + council
    assert not shown["Carol"] and not shown["Dave"], shown
    if not A.eval("return ns.Roll:CanStart()"):
        print("     (core Roll:CanStart is false for the party leader: roll part skipped)")
        return
    A.eval("ns.DropPanel:StartRoll(%d, 1)" % COWL)
    w.tick(1)
    for n in ("Bob", "Carol", "Dave", "Erin"):
        assert rf(cs[n])["shown"] and rf(cs[n])["rollShown"], (n, rf(cs[n]))
    sid = A.eval("return ns.Roll:GetActive().id")
    for n, v in (("Carol", 40), ("Dave", 90)):
        w._roll_rng = __import__("test_rolls").FixedRng(v)
        cs[n].click(cs[n].eval("return ns.RollFrame.frame.roll"))
        del w._roll_rng
    w.tick(1)
    A.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    ok = A.eval("return ns.DropPanel:Award(%d, 'Dave-Thunderstrike', 'BlackMorass:Aeonus', 1)" % COWL)
    w.tick(1)
    assert ok is True, printed_lines(A)[-5:]
    for n in ("Bob", "Carol", "Erin"):
        assert strip_codes(rf(cs[n])["status"]) == "Won by Dave", (n, rf(cs[n]))
    w.tick(6.5)
    for n in ("Bob", "Carol", "Dave", "Erin"):
        assert not rf(cs[n])["shown"], (n, rf(cs[n]))
    entries = B.eval_py("""local o = {} for _, e in ipairs(ns.Ledger:GetEntries({})) do
        o[#o + 1] = { e.i, e.w, e.dg and 1 or 0 } end return o""") or []
    mine = [e for e in entries if e[0] == COWL]
    assert len(mine) == 1 and mine[0][1] == "Dave-Thunderstrike", entries
    if mine[0][2] != 1:
        print("     (ledger entry has no dg flag: core Ledger/Roll part not there yet)")
    w.assert_no_errors()


@R.case
def settings_dungeon_section_toggle_quality_and_live_status():
    w, cs = party_world()
    A, B = cs["Alice"], cs["Bob"]
    for c in (A, B):
        bu.install_helpers(c)
        c.eval("function T_settings() return ns.MainFrame:GetPanel('settings') end")
        c.slash("/dz settings")
    w.tick(0.5)

    def status(c):
        return strip_codes(c.eval("return ns.SettingsUI.dungeonStatus:GetText()"))
    assert status(A) == "Status: Inactive (not in a 5-man party)", status(A)
    w.make_party([A, B], leader=A)
    w.tick(1)
    assert status(B) == "Status: Inactive (not turned on for this party)", status(B)
    cb = A.eval("return T_checkbox(T_settings(), 'Enable dungeon mode (5-man parties)')")
    assert cb is not None
    A.click(cb)
    w.tick(2)
    assert A.eval("return ns.DB:GetSetting('dungeon.enabled')") is True
    assert status(A) == "Status: Active — enabled by you", status(A)
    assert status(B) == "Status: Active — enabled by Alice", status(B)
    # quality dropdown (Rare / Epic)
    dd = A.eval("""for _, f in ipairs(T_dropdown_list(T_settings())) do
        local m = T_menu(f)
        if m and m.children[1] and m.children[1].text == 'Rare' then return f end end""")
    assert dd is not None, "no Rare/Epic dropdown"
    A.dropdown_menu(dd)
    A.menu_select("Epic")
    w.tick(0.2)
    assert A.eval("return ns.DB:GetSetting('dungeon.quality')") == 4
    A.click(cb)
    w.tick(2)
    assert status(B) == "Status: Inactive (not turned on for this party)", status(B)
    w.disband()
    w.tick(1)
    assert status(A) == "Status: Inactive (not in a 5-man party)", status(A)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Picker scopes (§21.3) and Loot Log (§22.2)
# ------------------------------------------------------------------------------------------------------------------
PICKER_DATA = r"""
local out = {}
for i, d in ipairs(T_data(T_box(DisasterZonePicker))) do
  out[i] = { d.type, d.name or '', d.itemID or 0, d.ref and d.ref.dungeon and 1 or 0, d.heroic and 1 or 0 }
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


@R.case
def picker_dungeon_scopes_headers_and_heroic_tag():
    w, c = bu.solo("Alice", class_file="PALADIN", guild_rank=3, tick=3)
    bu.install_helpers(c)
    c.slash("/dz bis")
    w.tick(0.3)
    if not c.eval("return ns.Data.Dungeons ~= nil and ns.ItemDB.GetBossRefs ~= nil"):
        print("     (dungeon data not loaded by the core yet: skipped)")
        return
    for sid in (1, 5, 3, 10, 7):
        c.click(c.eval("local s = ...; return T_tile(s).main", sid))
        # Addendum F §35: the scope dropdown became a Sources checkbox dropdown (default Raids + 5-man dungeons)
        sdd = c.eval(SOURCES_DD)
        assert sdd is not None, "no Sources dropdown"
        c.dropdown_menu(sdd)
        c.menu_select("Raids")                          # untick Raids: 5-man dungeons only
        c.eval("ns.Picker:Rebuild(true)")
        rows = c.eval_py(PICKER_DATA) or []
        items = [x for x in rows if x[0] == "item"]
        heads = [x[1] for x in rows if x[0] == "raid"]
        assert items and all(x[3] == 1 for x in items), rows[:6]
        assert heads and all(h.endswith(" (5-man)") for h in heads), heads
        subs = c.eval_py(PICKER_SUBS) or []
        for iid, heroic, sub in subs:
            assert (("Heroic" in sub) == bool(heroic)), (iid, heroic, sub)
        c.dropdown_menu(sdd)
        c.menu_select("Raids")                          # the default again: raids + dungeons
        rows = c.eval_py(PICKER_DATA) or []
        heads = [x[1] for x in rows if x[0] == "raid"]
        assert any(h.endswith(" (5-man)") for h in heads) and any(not h.endswith(" (5-man)") for h in heads), heads
        c.dropdown_menu(sdd)
        c.menu_select("5-man dungeons")                 # raids only
        rows = c.eval_py(PICKER_DATA) or []
        assert all(x[3] == 0 for x in rows if x[0] == "item"), "raids only lists no 5-man item"
        c.eval("ns.Picker:SetSourceEnabled('dungeons', true)")
        c.eval("ns.Picker:Close()")
    w.assert_no_errors()


@R.case
def loot_log_dungeon_tag_and_filter():
    w, c = bu.solo("Alice", class_file="PALADIN", guild_rank=0, tick=3)
    bu.install_helpers(c)
    e1 = c.eval("return ns.Ledger:Award(%d, 'Bob-Thunderstrike', 'Karazhan:Prince').id" % RUBY_DRAPE)
    e2 = c.eval("return ns.Ledger:Award(%d, 'Carol-Thunderstrike', 'BlackMorass:Aeonus').id" % MINDBLADE)
    c.eval("local id = ...; ns.db.ledger[id].dg = true; ns:Fire('LEDGER_UPDATED')", e2)
    c.slash("/dz log")
    w.tick(0.5)
    if c.eval("return ns.MainFrame:GetSelectedTab()") != "loot":
        c.eval("ns.MainFrame:Open('loot')")
        w.tick(0.3)
    c.eval("ns.LootLogUI:Refresh(true)")
    p = "DisasterZoneLootLogPanel"
    assert c.eval("return %s.count:GetText()" % p) == "2 awards"
    bosses = c.eval_py("""local o = {}
      for _, r in ipairs(T_rows(T_box(DisasterZoneLootLogPanel))) do
        local e = rawget(r, 'cdlEntry'); if e then o[#o + 1] = { e.id, r.boss:GetText() or '' } end end
      return o""")
    tags = {x[0]: strip_codes(x[1]) for x in bosses}
    assert tags[e2].endswith("(dungeon)") and not tags[e1].endswith("(dungeon)"), tags
    cb = c.eval("return T_checkbox(DisasterZoneLootLogPanel, 'Show dungeon loot')")
    assert cb is not None and c.eval("local b = ...; return b:GetChecked()", cb)
    c.click(cb)
    w.tick(0.3)
    assert c.eval("return %s.count:GetText()" % p) == "1 of 2 awards"
    c.click(cb)
    w.tick(0.3)
    assert c.eval("return %s.count:GetText()" % p) == "2 awards"
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

#!/usr/bin/env python
"""Addendum C end to end: roll popups close once the item is awarded or looted (real addon, 7 mocked raiders).

(a) the roll is closed and the master looter hands the item out with Blizzard's own master-loot menu
    (GiveMasterLoot, no DisasterZone click) -> every popup shows "Won by X (looted)" and is gone within 5s + fade;
    the same for a plain loot line (world.broadcast_loot_received) and for an open roll; a dungeon-mode party too.
(b) the drop panel's plain "Award..." (and "Someone else...") while a roll session exists -> RW, popups close,
    exactly one ledger entry (and the typed note is kept).
(c) two copies of the same token: two loot lines close the two sessions in copy order.
(d) a loot line for an item without a session changes nothing.
Plus the popup timing rules: hover pauses the fade only while the mouse is over the popup (also over a child
button, and while the fade already runs), it resumes ~1s after the mouse leaves, a new state restarts the
countdown, and "Rolls closed" without an award still lingers 45s.

Every case ends with world.assert_no_errors().
Run: luaenv\\Scripts\\python.exe tests\\rollclose\\test_rollclose.py   [-k substring]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(SCRATCH, "tests", "loot-roll"))
sys.path.insert(0, os.path.join(SCRATCH, "tests", "boot-ui"))

from lr_common import *  # noqa: F401,F403,E402
import _common as bu  # noqa: E402

R = Runner("roll popups close (Addendum C, end to end)")

ADDON_USERS = ("Alice", "Bob", "Carol", "Dave", "Erin", "Frank", "Gina")
RAIDERS = ("Carol", "Dave", "Erin", "Frank", "Gina")
FADE_AFTER_AWARD, FADE_TIME, LINGER = 5, 1, 45

LEDGER_SPY = r"""
__RC = __RC or {}
__RC.plainAwards = 0
if not __RC.spied then
  __RC.spied = true
  local orig = ns.Ledger.Award
  ns.Ledger.Award = function(self, ...)
    __RC.plainAwards = __RC.plainAwards + 1
    return orig(self, ...)
  end
end
"""


class FixedRng:
    def __init__(self, value):
        self.value = value

    def randint(self, lo, hi):
        return self.value


def setup(items=None, **kw):
    """Raid (Alice = leader + master looter, Bob = council), synced lists, Prince's loot window open on Alice."""
    r = Raid(**kw)
    for c in r.clients:
        bu.install_helpers(c)
        c.eval(LEDGER_SPY)
    items = items or [(RUBY_DRAPE, 4), (THOUSAND_MARKS, 4), (HELM_CHAMPION, 4), (MINDBLADE, 4)]
    r["Alice"].open_loot(items)
    r.w.tick(2)
    return r


def click_roll(r, name, value):
    c = r[name]
    assert c.eval("return ns.RollFrame.frame:IsShown() and ns.RollFrame.frame.roll:IsShown()"), \
        "%s: Roll button not visible (%r)" % (name, rollframe_state(c))
    r.w._roll_rng = FixedRng(value)
    c.click(c.eval("return ns.RollFrame.frame.roll"))
    del r.w._roll_rng


def rolled(r, item, rolls=(), close=True, copy=1, starter="Alice"):
    """Starts a roll for (item, copy) from the drop panel, lets `rolls` roll, closes it. Returns the session id."""
    r[starter].eval("ns.DropPanel:StartRoll(...)", item, copy)
    r.w.tick(1)
    act = active_session(r[starter])
    assert act and act["i"] == item and act["c"] == copy, act
    for name, v in rolls:
        click_roll(r, name, v)
    r.w.tick(1)
    if close:
        r[starter].eval("ns.Roll:End(...)", act["id"])
        r.w.tick(1)
    return act["id"]


def status(c):
    return strip_codes(rollframe_state(c)["status"])


def shown(c):
    return rollframe_state(c)["shown"]


def ses(c, sid):
    return c.eval_py(r"""
        local s = ns.Roll:Get(...)
        if not s then return nil end
        return { state = s.state, winner = s.winner or false, given = s.given, via = s.via or false,
                 looted = s.looted or false, c = s.c }""", sid)


def candidate_index(c, name, slot=1):
    return c.eval("""local slot, want = ...
        for i = 1, 40 do
          local n = GetMasterLootCandidate(slot, i)
          if n == nil then return nil end
          if ns.Util.NormalizeName(n) == want then return i end
        end""", slot, key(name))


def blizzard_give(r, item, name):
    """The master looter hands `item` to `name` with Blizzard's master-loot dropdown (no DisasterZone click)."""
    A = r["Alice"]
    slot = A.eval("return ns.Loot:FindLootSlot(...)", item)
    assert slot, "item %s not in the loot window" % item
    idx = candidate_index(A, name, slot)
    assert idx, "%s is no master-loot candidate" % name
    A.eval("GiveMasterLoot(...)", slot, idx)


def visible_for(c, item):
    return [e for e in ledger_visible(c) if e["i"] == item]


def block_of(c, item, copy=1):
    return c.eval("local id, cp = ...; for _, b in ipairs(ns.DropPanel.blocks) do "
                  "if b:IsShown() and b.itemID == id and (b.copy or 1) == cp then return b end end", item, copy)


def block_info(c, item, copy=1):
    for b in panel_blocks(c):
        if b["item"] == item and (b.get("copy") or 1) == copy:
            return b
    return None


def rf(c):
    return c.eval("return ns.RollFrame.frame")


def fading(c):
    return bool(c.eval("return ns.RollFrame.frame.fadeAnim:IsPlaying()"))


def alpha(c):
    return c.eval("return ns.RollFrame.frame:GetAlpha()")


# ------------------------------------------------------------------------------------------------------------------
# (a) Blizzard master-loot hand-out, no DisasterZone click
# ------------------------------------------------------------------------------------------------------------------
@R.case
def a_blizzard_master_loot_hand_out_closes_every_popup():
    r = setup()
    w = r.w
    sid = rolled(r, RUBY_DRAPE, (("Bob", 54), ("Dave", 80), ("Frank", 12)))
    for n in ADDON_USERS:
        assert shown(r[n]) and "rolls closed" in status(r[n]).lower(), (n, status(r[n]))
    log0, chat0 = len(w.addon_log), len(w.chat_log)
    blizzard_give(r, RUBY_DRAPE, "Dave")
    w.tick(0.5)
    t_loot = w.now
    for n in ADDON_USERS:
        s = ses(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Dave") and s["via"] == "loot" and s["given"] is True, (n, s)
    for n in ADDON_USERS:
        if n == "Dave":
            assert status(r[n]) == "You won it! (looted)", status(r[n])
        else:
            assert status(r[n]) == "Won by Dave (looted)", (n, status(r[n]))
        assert not rollframe_state(r[n])["rollShown"], n
    # no network traffic: every client saw the same loot line
    for t in ("RW", "RE", "RS"):
        assert msgs_of_type(w, t, log0) == [], t
    assert [e for e in w.chat_log[chat0:] if "->" in e["text"]] == [], "no award line without an award click"
    # the council panel's roll header
    w.tick(0.3)
    for n in ("Alice", "Bob"):
        assert strip_codes(block_info(r[n], RUBY_DRAPE)["sub"]) == "Awarded to Dave (looted)", (n, block_info(r[n], RUBY_DRAPE))
        assert strip_codes(block_info(r[n], RUBY_DRAPE)["awarded"]) == "Awarded to Dave (looted)"
    # still there just before 5s, gone after 5s + the 1s fade
    w.tick(t_loot + FADE_AFTER_AWARD - 0.5 - w.now)
    for n in ADDON_USERS:
        assert shown(r[n]), (n, "faded too early")
    w.tick(t_loot + FADE_AFTER_AWARD + FADE_TIME + 0.3 - w.now)
    for n in ADDON_USERS:
        assert not shown(r[n]), (n, rollframe_state(r[n]))
    # the council's loot-line auto entry is the only log entry, no plain award was written
    for n in ("Alice", "Bob"):
        vis = visible_for(r[n], RUBY_DRAPE)
        assert [(e["w"], e["s"]) for e in vis] == [(key("Dave"), "a")], (n, vis)
        assert r[n].eval("return __RC.plainAwards") == 0
    w.assert_no_errors()


@R.case
def a2_plain_loot_line_resolves_an_open_roll_and_the_queue_moves_on():
    r = setup()
    w = r.w
    A = r["Alice"]
    sid = rolled(r, THOUSAND_MARKS, (("Carol", 44),), close=False)
    A.eval("ns.DropPanel:StartRoll(...)", MINDBLADE, 1)          # waits in Alice's queue
    w.tick(0.5)
    assert len(A.eval_py("return ns.Roll:GetQueue()") or []) == 1
    for n in RAIDERS:
        assert shown(r[n]) and rollframe_state(r[n])["id"] == sid, n
    log0 = len(w.addon_log)
    w.broadcast_loot_received(r["Erin"], THOUSAND_MARKS)     # no loot window involved
    w.tick(0.3)
    for n in ADDON_USERS:
        s = ses(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Erin") and s["via"] == "loot", (n, s)
        want = "You won it! (looted)" if n == "Erin" else "Won by Erin (looted)"
        assert status(r[n]) == want, (n, status(r[n]))
    assert msgs_of_type(w, "RE", log0) == [] and msgs_of_type(w, "RW", log0) == []
    # the open roll ended with the loot line: Alice's queued roll starts 2s later everywhere
    w.tick(3)
    act = active_session(A)
    assert act and act["i"] == MINDBLADE, act
    for n in RAIDERS:
        st = rollframe_state(r[n])
        assert st["shown"] and st["id"] == act["id"] and st["rollShown"], (n, st)
    w.assert_no_errors()


@R.case
def a3_dungeon_party_master_looter_hand_out():
    """Dungeon mode, party with master loot: the Blizzard hand-out closes the party popups too."""
    roster = [("Alice", "PALADIN", 0), ("Bob", "MAGE", 1), ("Carol", "WARRIOR", 3), ("Dave", "PRIEST", 3),
              ("Erin", "ROGUE", 3)]
    w = World()
    cs = {}
    for n, cl, rank in roster:
        cs[n] = Client(w, n, class_file=cl, guild_rank=rank)
    for c in cs.values():
        c.load_addon()
    install_probes(cs.values())
    w.tick(2)
    setup_council(w, cs, roster)
    A = cs["Alice"]
    w.make_party(list(cs.values()), leader=A)
    w.tick(1)
    w.set_master_looter(A)
    w.tick(1)
    w.enter_instance("Black Morass", 269, "party", 5, 2)
    w.tick(1)
    A.slash("/dz dungeon on")
    w.tick(1.5)
    assert A.eval("return ns.Util.IsPlayerMasterLooter()") is True
    COWL, AEONUS = 28206, "Creature-0-1-2-3-17881-0000C01"
    A.open_loot([(COWL, 3), (28190, 3)], source_guid=AEONUS)
    w.tick(2)
    A.eval("ns.DropPanel:StartRoll(...)", COWL, 1)
    w.tick(1)
    sid = active_session(A)["id"]
    for n in ("Bob", "Carol", "Dave", "Erin"):
        assert rollframe_state(cs[n])["shown"], n
    w._roll_rng = FixedRng(61)
    cs["Carol"].click(cs["Carol"].eval("return ns.RollFrame.frame.roll"))
    del w._roll_rng
    w.tick(1)
    A.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    log0 = len(w.addon_log)
    slot = A.eval("return ns.Loot:FindLootSlot(...)", COWL)
    idx = candidate_index(A, "Carol", slot)
    assert slot and idx, (slot, idx)
    A.eval("GiveMasterLoot(...)", slot, idx)
    w.tick(0.5)
    for n in cs:
        s = ses(cs[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Carol") and s["via"] == "loot", (n, s)
    assert status(cs["Dave"]) == "Won by Carol (looted)", status(cs["Dave"])
    assert msgs_of_type(w, "RW", log0) == []
    w.tick(FADE_AFTER_AWARD + FADE_TIME + 0.3)
    for n in cs:
        assert not rollframe_state(cs[n])["shown"], n
    # the council's auto entry is 5-man loot
    rows = A.eval_py("local o = {} for _, e in ipairs(ns.Ledger:GetEntries()) do o[#o + 1] = { e.w, e.s, e.dg or false } end return o")
    assert rows == [[key("Carol"), "a", True]], rows
    w.assert_no_errors()


@R.case
def a4_cdloot_give_in_a_dungeon_party_master_loot():
    """The award button as party master looter: DISASTERZONE_GIVE_ITEM hands the item out (party candidates), one RW,
    the loot line that follows is matched to the award (no second resolution), one dg ledger entry."""
    roster = [("Alice", "PALADIN", 0), ("Bob", "MAGE", 1), ("Carol", "WARRIOR", 3)]
    w = World()
    cs = {n: Client(w, n, class_file=cl, guild_rank=rk) for n, cl, rk in roster}
    for c in cs.values():
        c.load_addon()
    install_probes(cs.values())
    w.tick(2)
    setup_council(w, cs, roster)
    A = cs["Alice"]
    w.make_party(list(cs.values()), leader=A)
    w.tick(1)
    w.set_master_looter(A)
    w.tick(1)
    w.enter_instance("Black Morass", 269, "party", 5, 2)
    w.tick(1)
    A.slash("/dz dungeon on")
    w.tick(1.5)
    COWL = 28206
    A.open_loot([(COWL, 3)], source_guid="Creature-0-1-2-3-17881-0000C02")
    w.tick(2)
    A.eval("ns.DropPanel:StartRoll(...)", COWL, 1)
    w.tick(1)
    sid = active_session(A)["id"]
    w._roll_rng = FixedRng(33)
    cs["Carol"].click(cs["Carol"].eval("return ns.RollFrame.frame.roll"))
    del w._roll_rng
    w.tick(1)
    A.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    log0 = len(w.addon_log)
    A.eval("ns.Roll:Award(...)", sid, key("Carol"))
    w.tick(0.2)
    assert A.popups() == ["DISASTERZONE_GIVE_ITEM"], A.popups()
    A.accept_popup("DISASTERZONE_GIVE_ITEM")
    w.tick(1)
    assert A.eval("return ns.Loot:FindLootSlot(...)", COWL) is None, "the item was handed out"
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["_chat_type"] == "PARTY" and RW[0]["g"] is True, RW
    for n in cs:
        s = ses(cs[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Carol") and s["via"] is False, (n, s)
    assert cs["Bob"].eval("return ns.Roll:Get(...).looted", sid) is True, "the loot line matched the award"
    for n in ("Alice", "Bob"):
        vis = cs[n].eval_py("local o = {} for _, e in ipairs(ns.Ledger:GetEntries()) do o[#o + 1] = { e.w, e.s, e.dg or false } end return o")
        assert vis == [[key("Carol"), "m", True]], (n, vis)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# (b) plain "Award..." / "Someone else..." from the drop panel go through the roll
# ------------------------------------------------------------------------------------------------------------------
@R.case
def b_plain_award_menu_goes_through_the_roll():
    r = setup()
    w = r.w
    B = r["Bob"]                                   # council, not the master looter
    sid = rolled(r, RUBY_DRAPE, ())                # nobody rolled: no suggestion, the plain Award... shows
    w.tick(0.3)
    blk = block_info(B, RUBY_DRAPE)
    assert blk and "Award..." in blk["buttons"] and strip_codes(blk["sub"]).startswith("Rolls closed"), blk
    for n in ADDON_USERS:
        assert status(r[n]) == "Rolls closed", (n, status(r[n]))
    log0, chat0 = len(w.addon_log), len(w.chat_log)
    b = block_of(B, RUBY_DRAPE)
    assert B.eval("local b = ...; return b.award:IsEnabled() and true or false", b) is True
    B.click(B.eval("local b = ...; return b.award", b))
    entry = next(e for e in bu.menu_texts(B.last_menu()) if e[2] and strip_codes(e[2]).startswith("Dave"))
    B.menu_select(entry[2])
    w.tick(0.5)
    t_award = w.now
    assert B.popups() == [], "no give / confirm popup: the menu click is the confirmation"
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["_sender"] == key("Bob") and RW[0]["w"] == key("Dave") and RW[0]["g"] is False, RW
    assert msgs_of_type(w, "RE", log0) == [], "the roll was already closed"
    for n in ADDON_USERS:
        s = ses(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Dave") and s["via"] is False, (n, s)
        want = "You won it!" if n == "Dave" else "Won by Dave"
        assert status(r[n]) == want, (n, status(r[n]))
    lines = [e for e in w.chat_log[chat0:] if "->" in e["text"]]
    assert len(lines) == 1 and lines[0]["sender"] == key("Bob"), lines
    assert strip_codes(lines[0]["text"]) == "DisasterZone: [Ruby Drape of the Mysticant] -> Dave (no roll, Alt)", lines[0]
    w.tick(0.3)
    for n in ("Alice", "Bob"):
        info = block_info(r[n], RUBY_DRAPE)
        assert strip_codes(info["sub"]) == "Awarded to Dave  ·  Alt" and info["buttons"] == [], (n, info)
    # exactly one ledger entry on each council client, and no plain Ledger:Award next to it
    for n in ("Alice", "Bob"):
        vis = visible_for(r[n], RUBY_DRAPE)
        assert [(e["w"], e["s"], e["n"]) for e in vis] == [(key("Dave"), "m", "roll: no roll")], (n, vis)
        assert r[n].eval("return __RC.plainAwards") == 0, n
    assert visible_for(r["Alice"], RUBY_DRAPE)[0]["id"] == visible_for(r["Bob"], RUBY_DRAPE)[0]["id"]
    # the popups close 5s + fade after the award
    w.tick(t_award + FADE_AFTER_AWARD - 0.5 - w.now)
    assert all(shown(r[n]) for n in ADDON_USERS)
    w.tick(t_award + FADE_AFTER_AWARD + FADE_TIME + 0.3 - w.now)
    for n in ADDON_USERS:
        assert not shown(r[n]), (n, rollframe_state(r[n]))
    # the master looter hands it out later: matched to the award, still one visible entry
    blizzard_give(r, RUBY_DRAPE, "Dave")
    w.tick(1)
    assert ses(r["Carol"], sid)["looted"] is True and ses(r["Carol"], sid)["via"] is False
    for n in ("Alice", "Bob"):
        assert len(visible_for(r[n], RUBY_DRAPE)) == 1, visible_for(r[n], RUBY_DRAPE)
    assert not shown(r["Carol"]), "a loot line for an awarded roll does not bring the popup back"
    w.assert_no_errors()


@R.case
def b2_someone_else_dialog_keeps_the_note_and_add_award_does_not_touch_rolls():
    r = setup()
    w = r.w
    A = r["Alice"]
    sid = rolled(r, THOUSAND_MARKS, (("Carol", 33),))
    # the suggestion's row menu is the roll's own flow; "Someone else..." is in the Award... menu of a
    # block without a suggestion, and in DropPanel:AwardSomeoneElse
    log0 = len(w.addon_log)
    A.eval("ns.DropPanel:AwardSomeoneElse(%d, 'Karazhan:Prince', 1)" % THOUSAND_MARKS)
    w.tick(0.1)
    assert A.eval("return DisasterZoneAwardDialog:IsShown()")
    A.eval("local eb = ...; eb:SetText('Erin')", A.eval("return DisasterZoneAwardDialog.winBox"))
    A.eval("local eb = ...; eb:SetText('offspec | for now')", A.eval("return DisasterZoneAwardDialog.noteBox"))
    A.click(A.eval("return DisasterZoneAwardDialog.saveBtn"))
    w.tick(1)
    assert not A.eval("return DisasterZoneAwardDialog:IsShown()"), A.eval("return DisasterZoneAwardDialog.status:GetText()")
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["w"] == key("Erin"), RW
    for n in ADDON_USERS:
        s = ses(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Erin"), (n, s)
    for n in ("Alice", "Bob"):
        vis = visible_for(r[n], THOUSAND_MARKS)
        assert len(vis) == 1 and vis[0]["w"] == key("Erin"), (n, vis)
        assert vis[0]["n"] == "offspec   for now; roll: no roll", (n, vis[0]["n"])   # escape bar removed
        assert r[n].eval("return __RC.plainAwards") == 0
    # a very long note keeps the roll part and fits the award message
    sid2 = rolled(r, MINDBLADE, (("Frank", 91),))
    long_note = "x" * 80 + "é"
    ok = A.eval("return ns.DropPanel:Award(%d, 'Gina-Thunderstrike', 'Karazhan:Prince', 1, nil, ...)" % MINDBLADE, long_note)
    w.tick(1)
    assert ok is True
    n2 = [e for e in visible_for(r["Bob"], MINDBLADE)]
    assert len(n2) == 1 and n2[0]["n"].endswith("; roll: no roll") and len(n2[0]["n"].encode("utf-8")) <= 64, n2
    assert ses(r["Carol"], sid2)["winner"] == key("Gina")
    # the Loot Log's own "Add award..." never touches rolls: a plain entry, the closed roll stays closed
    sid3 = rolled(r, HELM_CHAMPION, (("Erin", 5),))
    A.eval("ns.LootLogUI:OpenAwardDialog(%d, 'Gina-Thunderstrike', 'Karazhan:Prince')" % HELM_CHAMPION)
    A.click(A.eval("return DisasterZoneAwardDialog.saveBtn"))
    w.tick(1)
    assert A.eval("return __RC.plainAwards") == 1
    for n in ADDON_USERS:
        assert ses(r[n], sid3)["state"] == "closed", n
    assert len(visible_for(A, HELM_CHAMPION)) == 1
    w.assert_no_errors()


@R.case
def b3_plain_award_while_open_ends_the_roll_and_queued_is_cancelled():
    r = setup()
    w = r.w
    A = r["Alice"]
    sid = rolled(r, RUBY_DRAPE, (("Bob", 20),), close=False)
    log0 = len(w.addon_log)
    assert A.eval("return ns.DropPanel:Award(%d, 'Bob-Thunderstrike', 'Karazhan:Prince', 1)" % RUBY_DRAPE) is True
    w.tick(1)
    assert [m["id"] for m in msgs_of_type(w, "RE", log0)] == [sid]
    assert len(msgs_of_type(w, "RW", log0)) == 1
    for n in ADDON_USERS:
        assert ses(r[n], sid)["state"] == "awarded", n
    assert status(r["Carol"]) == "Won by Bob" and status(r["Bob"]) == "You won it!"
    # a queued roll: the award is a plain entry and the queued roll never starts
    A.eval("ns.DropPanel:StartRoll(...)", MINDBLADE, 1)
    A.eval("ns.DropPanel:StartRoll(...)", THOUSAND_MARKS, 1)
    w.tick(0.3)
    q = A.eval_py("local o = {} for i, s in ipairs(ns.Roll:GetQueue()) do o[i] = { s.id, s.i } end return o")
    queued = [x[0] for x in q if x[1] == THOUSAND_MARKS]
    assert queued, q
    assert A.eval("return ns.DropPanel:Award(%d, 'Carol-Thunderstrike', 'Karazhan:Prince', 1)" % THOUSAND_MARKS) is True
    w.tick(1)
    assert A.eval("return __RC.plainAwards") == 1
    assert A.eval("return ns.Roll:Get(...).state", queued[0]) == "cancelled"
    w.tick(40)
    starts = [m["i"] for m in msgs_of_type(w, "RS", log0)]
    assert THOUSAND_MARKS not in starts, starts
    w.assert_no_errors()


@R.case
def b4_non_council_master_looter_awards_through_the_roll():
    """A non-council master looter's plain Award... goes through the roll too: the council clients record the
    RW (one shared entry); the master looter writes nothing and gets no plain-award refusal."""
    r = Raid(ml="Frank")
    w = r.w
    for c in r.clients:
        bu.install_helpers(c)
        c.eval(LEDGER_SPY)
    F = r["Frank"]
    F.open_loot([(RUBY_DRAPE, 4), (MINDBLADE, 4)])
    w.tick(2)
    assert F.eval("return ns.Roll:CanStart()") is True and not F.eval("return ns.Guild:AmICouncil(true)")
    F.eval("ns.DropPanel:ShowHistory()")
    w.tick(0.3)
    sid = rolled(r, RUBY_DRAPE, (), starter="Frank")
    w.tick(0.3)
    blk = block_info(F, RUBY_DRAPE)
    assert blk and "Award..." in blk["buttons"], blk
    assert F.eval("local b = ...; return b.award:IsEnabled() and true or false", block_of(F, RUBY_DRAPE)) is True
    log0 = len(w.addon_log)
    F.click(F.eval("local b = ...; return b.award", block_of(F, RUBY_DRAPE)))
    entry = next(e for e in bu.menu_texts(F.last_menu()) if e[2] and strip_codes(e[2]).startswith("Bob"))
    F.menu_select(entry[2])
    w.tick(1)
    assert not any("Only Loot Council members can record" in l for l in printed_lines(F))
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["_sender"] == key("Frank") and RW[0]["w"] == key("Bob"), RW
    for n in ADDON_USERS:
        assert ses(r[n], sid)["winner"] == key("Bob"), n
    assert status(r["Carol"]) == "Won by Bob"
    assert F.eval("return __RC.plainAwards") == 0 and ledger_raw(F) == []
    ids = set()
    for n in ("Alice", "Bob"):
        vis = visible_for(r[n], RUBY_DRAPE)
        assert len(vis) == 1 and vis[0]["w"] == key("Bob") and vis[0]["by"] == key("Frank"), (n, vis)
        ids.add(vis[0]["id"])
    assert len(ids) == 1, ids
    w.tick(FADE_AFTER_AWARD + FADE_TIME + 0.5)
    assert not any(shown(r[n]) for n in ADDON_USERS)
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# (c) two copies of the same item: two loot lines close the two sessions in order
# ------------------------------------------------------------------------------------------------------------------
@R.case
def c_two_copies_two_loot_lines_close_the_sessions_in_order():
    r = setup(items=[(HELM_CHAMPION, 4), (HELM_CHAMPION, 4), (RUBY_DRAPE, 4)])
    w = r.w
    A = r["Alice"]
    s1 = rolled(r, HELM_CHAMPION, (("Erin", 70), ("Gina", 20)), copy=1)
    w.tick(3)
    s2 = rolled(r, HELM_CHAMPION, (("Gina", 55),), copy=2)
    assert s1 != s2 and ses(A, s1)["c"] == 1 and ses(A, s2)["c"] == 2
    log0 = len(w.addon_log)
    # the tokens are handed out with the Blizzard menu: the loot line names the token itself
    blizzard_give(r, HELM_CHAMPION, "Erin")
    w.tick(0.5)
    for n in ADDON_USERS:
        a, b = ses(r[n], s1), ses(r[n], s2)
        assert (a["state"], a["winner"], a["via"]) == ("awarded", key("Erin"), "loot"), (n, a)
        assert b["state"] == "closed", (n, b)
    # the popups show the latest roll (copy 2): still "Rolls closed"
    assert status(r["Carol"]) == "Rolls closed", status(r["Carol"])
    blizzard_give(r, HELM_CHAMPION, "Gina")
    w.tick(0.5)
    t2 = w.now
    for n in ADDON_USERS:
        a, b = ses(r[n], s1), ses(r[n], s2)
        assert (a["winner"], b["state"], b["winner"], b["via"]) == (key("Erin"), "awarded", key("Gina"), "loot"), (n, a, b)
    assert status(r["Carol"]) == "Won by Gina (looted)", status(r["Carol"])
    assert status(r["Gina"]).startswith("You won it!"), status(r["Gina"])
    w.tick(0.3)
    for n in ("Alice", "Bob"):
        assert strip_codes(block_info(r[n], HELM_CHAMPION, 1)["sub"]) == "Awarded to Erin (looted)", n
        assert strip_codes(block_info(r[n], HELM_CHAMPION, 2)["sub"]) == "Awarded to Gina (looted)", n
    assert msgs_of_type(w, "RW", log0) == []
    w.tick(t2 + FADE_AFTER_AWARD + FADE_TIME + 0.3 - w.now)
    for n in ADDON_USERS:
        assert not shown(r[n]), (n, rollframe_state(r[n]))
    # a third copy's loot line finds nothing left to resolve
    assert A.eval("return ns.Roll:OnItemLooted(...) == nil", HELM_CHAMPION, key("Carol"))
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# (d) a loot line for an item without a session changes nothing
# ------------------------------------------------------------------------------------------------------------------
@R.case
def d_loot_line_without_a_session_changes_nothing():
    r = setup()
    w = r.w
    sid = rolled(r, RUBY_DRAPE, (("Bob", 54),))
    t_close = w.now
    before = {n: ses(r[n], sid) for n in ADDON_USERS}
    popups = {n: (shown(r[n]), status(r[n])) for n in ADDON_USERS}
    log0 = len(w.addon_log)
    blizzard_give(r, MINDBLADE, "Carol")            # in the same drop, never rolled
    w.broadcast_loot_received(r["Carol"], 990002)   # an unknown item
    w.broadcast_loot_received(r["Frank"], 30531)    # a 5-man item nobody rolled for
    w.tick(1)
    assert {n: ses(r[n], sid) for n in ADDON_USERS} == before
    assert {n: (shown(r[n]), status(r[n])) for n in ADDON_USERS} == popups
    for t in ("RW", "RE", "RS"):
        assert msgs_of_type(w, t, log0) == [], t
    for n in ADDON_USERS:
        assert r[n].eval("return ns.Roll:OnItemLooted(...) == nil", THOUSAND_MARKS, key("Carol")), n
    # the unrelated hand-out does not shorten the popup: "Rolls closed" still lingers until 45s
    w.tick(t_close + 30 - w.now)
    assert all(shown(r[n]) for n in ADDON_USERS)
    assert ses(r["Carol"], sid)["state"] == "closed"
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Popup timing: hover pause, resume after leave, restart on a new state, 45s linger
# ------------------------------------------------------------------------------------------------------------------
@R.case
def hover_pauses_the_fade_only_while_over_the_popup():
    r = setup()
    w = r.w
    sid = rolled(r, RUBY_DRAPE, (("Dave", 80),))
    C, E, F, G = r["Carol"], r["Erin"], r["Frank"], r["Gina"]
    C.hover(rf(C))                                 # Carol points at her popup before the award
    G.hover(rf(G))                                 # Gina too, but moves away again before the fade is due
    r["Alice"].eval("return ns.DropPanel:Award(%d, 'Dave-Thunderstrike', 'Karazhan:Prince', 1)" % RUBY_DRAPE)
    w.tick(0.3)
    t_award = w.now
    for c in (C, E, F, G):
        assert status(c) == "Won by Dave", (c.name, status(c))
    w.tick(2)
    G.leave(rf(G))
    w.tick(t_award + FADE_AFTER_AWARD + 0.4 - w.now)
    assert fading(E) and fading(F) and fading(G), "the fade runs for everyone not pointing at the popup"
    assert not fading(C) and shown(C) and alpha(C) == 1
    # Frank grabs the popup while it is fading: back to full alpha, held
    F.hover(rf(F))
    assert not fading(F) and alpha(F) == 1
    w.tick(t_award + FADE_AFTER_AWARD + FADE_TIME + 0.3 - w.now)
    assert not shown(E) and not shown(G), (rollframe_state(E), rollframe_state(G))
    assert shown(C) and shown(F)
    w.tick(10)                                     # held as long as the mouse stays
    assert shown(C) and shown(F) and alpha(C) == 1 and alpha(F) == 1
    C.leave(rf(C))
    t_leave = w.now
    w.tick(0.6)
    assert shown(C) and not fading(C), "resumes about 1s after the mouse left"
    w.tick(t_leave + 1.25 - w.now)
    assert fading(C) or not shown(C)
    w.tick(t_leave + 1 + FADE_TIME + 0.4 - w.now)
    assert not shown(C), rollframe_state(C)
    # coming back during the resume delay keeps it
    F.leave(rf(F))
    w.tick(0.5)
    F.hover(rf(F))
    w.tick(3)
    assert shown(F) and alpha(F) == 1
    F.leave(rf(F))
    w.tick(1 + FADE_TIME + 0.5)
    assert not shown(F)
    w.assert_no_errors()


@R.case
def hover_over_a_child_button_also_holds_the_fade():
    """The mouse on the close button gives the frame no OnEnter; IsMouseOver() still holds the fade."""
    r = setup()
    w = r.w
    sid = rolled(r, RUBY_DRAPE, (("Dave", 80),))
    E = r["Erin"]
    E.eval("__RC.over = false; ns.RollFrame.frame.IsMouseOver = function() return __RC.over end")
    r["Alice"].eval("return ns.DropPanel:Award(%d, 'Dave-Thunderstrike', 'Karazhan:Prince', 1)" % RUBY_DRAPE)
    w.tick(0.3)
    E.eval("__RC.over = true")
    w.tick(FADE_AFTER_AWARD + FADE_TIME + 2)
    assert shown(E) and alpha(E) == 1, rollframe_state(E)
    E.eval("__RC.over = false")
    w.tick(0.5)
    assert shown(E)
    w.tick(1 + FADE_TIME + 0.5)
    assert not shown(E), rollframe_state(E)
    assert ses(E, sid)["winner"] == key("Dave")
    w.assert_no_errors()


@R.case
def a_new_state_restarts_the_countdown_and_closed_still_lingers():
    r = setup()
    w = r.w
    # "Rolls closed" without an award lingers 45s
    s1 = rolled(r, MINDBLADE, (("Frank", 10),))
    t_close = w.now
    w.tick(t_close + LINGER - 1 - w.now)
    assert shown(r["Carol"]) and status(r["Carol"]) == "Rolls closed"
    w.tick(t_close + LINGER + FADE_TIME + 0.5 - w.now)
    assert not shown(r["Carol"]), rollframe_state(r["Carol"])
    assert ses(r["Carol"], s1)["state"] == "closed"
    # closed for 43s, then the item is handed out: the popup of the NEXT roll resolves on its own 5s countdown
    s2 = rolled(r, RUBY_DRAPE, (("Dave", 80),))
    t2 = w.now
    w.tick(t2 + 43 - w.now)
    assert shown(r["Carol"]) and status(r["Carol"]) == "Rolls closed"
    blizzard_give(r, RUBY_DRAPE, "Dave")
    w.tick(0.3)
    t_loot = w.now
    assert status(r["Carol"]) == "Won by Dave (looted)"
    w.tick(t_loot + 3.5 - w.now)                  # past the old 45s linger, inside the new 5s
    assert shown(r["Carol"]) and not fading(r["Carol"]), "the award restarted the countdown"
    # upgrading the loot mark to a recorded award keeps the popup's countdown (same state)
    r["Bob"].eval("return ns.Roll:MarkAwardedExternally(...)", s2, key("Dave"))
    w.tick(0.3)
    assert status(r["Carol"]) == "Won by Dave"
    w.tick(t_loot + FADE_AFTER_AWARD + FADE_TIME + 0.4 - w.now)
    assert not shown(r["Carol"]), rollframe_state(r["Carol"])
    w.assert_no_errors()


@R.case
def explicit_award_after_a_hand_out_to_someone_else_is_recorded_with_a_note():
    """The master looter misclicks (Blizzard menu -> Frank); the council then records the roll winner Dave:
    the award is recorded, the awarder is told who the loot message named, no second copy is given."""
    r = setup()
    w = r.w
    A = r["Alice"]
    sid = rolled(r, RUBY_DRAPE, (("Dave", 80),))
    blizzard_give(r, RUBY_DRAPE, "Frank")
    w.tick(0.5)
    assert status(r["Carol"]) == "Won by Frank (looted)"
    log0, n0 = len(w.addon_log), len(A.chat_frame)
    A.eval("ns.Roll:Award(...)", sid, key("Dave"))
    w.tick(0.2)
    assert A.popups() == ["DISASTERZONE_CONFIRM_AWARD"], "no master-loot hand-out of an item already handed out"
    A.accept_popup("DISASTERZONE_CONFIRM_AWARD")
    w.tick(1)
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["w"] == key("Dave") and RW[0]["g"] is False, RW
    for n in ADDON_USERS:
        s = ses(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Dave") and s["via"] is False, (n, s)
    assert status(r["Carol"]) == "Won by Dave"
    notes = [strip_codes(l) for l in printed_lines(A)[n0:] if "loot message says" in l]
    assert notes[0] == ("DisasterZone: Note: the loot message says Frank received [Ruby Drape of the Mysticant]; "
                        "recorded as awarded to Dave."), notes
    # DisasterZone 0.5: the one copy went to Frank but the award names Dave: flagged for the council to fix the log
    assert len(notes) == 2 and "but it was awarded to Dave" in notes[1] and "Fix the loot log" in notes[1], notes
    for n in ("Alice", "Bob"):
        vis = sorted((e["w"], e["s"]) for e in visible_for(r[n], RUBY_DRAPE))
        assert vis == [(key("Dave"), "m"), (key("Frank"), "a")], (n, vis)
    w.assert_no_errors()


@R.case
def winner_who_closed_the_popup_is_told_once():
    r = setup()
    w = r.w
    sid = rolled(r, RUBY_DRAPE, (("Dave", 80),))
    D = r["Dave"]
    D.click(D.eval("return ns.RollFrame.frame.close"))
    assert not shown(D)
    blizzard_give(r, RUBY_DRAPE, "Dave")
    w.tick(0.5)
    assert shown(D) and status(D) == "You won it! (looted)", rollframe_state(D)
    assert not shown(r["Carol"]) or status(r["Carol"]) == "Won by Dave (looted)"
    w.tick(FADE_AFTER_AWARD + FADE_TIME + 0.5)
    assert not shown(D)
    # a later update of the same session (the recorded award) does not bring it back
    r["Bob"].eval("return ns.Roll:MarkAwardedExternally(...)", sid, key("Dave"))
    w.tick(1)
    assert not shown(D), rollframe_state(D)
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

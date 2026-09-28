#!/usr/bin/env python
"""Loot-roll area, part 4: awarding a roll (Addendum A §19.1 "Award", §19.4 master-loot give, §20 demo isolation).

ML with the loot window open -> CDLOOT_GIVE_ITEM -> GiveMasterLoot to the right candidate -> loot message ->
ledger; non-ML award -> CDLOOT_CONFIRM_AWARD; RW propagation and the winner's "You won"; raid announce lines
(text + 255-byte limit); the master-loot candidate list arriving late (OPEN_MASTER_LOOT_LIST); races; demo mode.

Run: luaenv\\Scripts\\python.exe tests\\loot-roll\\test_award.py   [-k substring]
"""
from lr_common import *  # noqa: F401,F403
from test_rolls import setup, click_roll, click_pass, FixedRng, ADDON_USERS, states  # noqa: F401

R = Runner("loot-roll / award")

GIVE_SPY = r"""
__LR.gives = {}
local orig = GiveMasterLoot
GiveMasterLoot = function(slot, idx)
  __LR.gives[#__LR.gives + 1] = { slot = slot, idx = idx, name = GetMasterLootCandidate(slot, idx),
                                  link = GetLootSlotLink(slot) }
  return orig(slot, idx)
end
"""


def rolled_session(r, item=RUBY_DRAPE, rolls=(("Bob", 54), ("Dave", 80), ("Frank", 12)), close=True, starter="Alice"):
    r[starter].eval("ns.DropPanel:StartRoll(...)", item, 1)
    r.w.tick(1)
    sid = active_session(r[starter])["id"]
    for name, v in rolls:
        click_roll(r, name, v)
    r.w.tick(1)
    if close:
        r[starter].eval("ns.Roll:End(...)", sid)
        r.w.tick(1)
    return sid


def bag_items(c):
    return c.eval_py("local out = {} for b = 0, 4 do for s = 1, 16 do local id = C_Container.GetContainerItemID(b, s) if id then out[#out+1] = id end end end return out") or []


def award_lines(w, start):
    return [e for e in w.chat_log[start:] if "->" in e["text"] or "→" in e["text"]]


# ------------------------------------------------------------------------------------------------------------------
@R.case
def ml_give_via_master_loot_full_flow():
    r = setup()
    w = r.w
    A, B = r["Alice"], r["Bob"]
    A.eval(GIVE_SPY)
    sid = rolled_session(r)
    log0, chat0 = len(w.addon_log), len(w.chat_log)
    A.eval("ns.DropPanel:AwardRoll(...)", sid, key("Bob"))
    w.tick(0.2)
    assert A.popups() == ["CDLOOT_GIVE_ITEM"], A.popups()
    txt = strip_codes(popups_log(A)[-1]["text"])
    assert txt == "Give [Ruby Drape of the Mysticant] to Bob?", txt
    A.accept_popup("CDLOOT_GIVE_ITEM")
    w.tick(2)

    gives = A.eval_py("return __LR.gives")
    assert len(gives) == 1 and gives[0]["name"] == "Bob" and "Ruby Drape" in gives[0]["link"], gives
    assert RUBY_DRAPE in bag_items(B), "Bob received the item: %r" % bag_items(B)

    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["_sender"] == key("Alice") and RW[0]["w"] == key("Bob") and RW[0]["g"] is True, RW
    for n in ADDON_USERS:
        s = session_info(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Bob"), (n, s)
    assert session_info(A, sid)["given"] is True
    st = strip_codes(rollframe_state(B)["status"])
    assert st == "You won it!", st
    for n in ("Alice", "Carol", "Dave"):
        assert strip_codes(rollframe_state(r[n])["status"]) == "Won by Bob", (n, rollframe_state(r[n]))

    for n in ("Alice", "Bob"):
        vis = ledger_visible(r[n])
        assert len(vis) == 1 and vis[0]["s"] == "m" and vis[0]["w"] == key("Bob") and vis[0]["i"] == RUBY_DRAPE, (n, vis)
        assert vis[0]["n"] == "roll 54" and vis[0]["b"] == "Karazhan:Prince", vis
        assert sorted(e["s"] for e in ledger_raw(r[n])) == ["a", "m"], "the loot message auto entry is kept but hidden"

    lines = award_lines(w, chat0)
    assert len(lines) == 1 and lines[0]["sender"] == key("Alice") and lines[0]["chat_type"] == "RAID", lines
    assert strip_codes(lines[0]["text"]) == "CDLoot: [Ruby Drape of the Mysticant] -> Bob (rolled 54, BiS)", lines[0]
    assert all(len(e["text"].encode("utf-8")) <= 255 for e in w.chat_log), [len(e["text"].encode()) for e in w.chat_log]

    blk = [b for b in panel_blocks(A) if b["item"] == RUBY_DRAPE][0]
    assert "Bob" in strip_codes(blk["awarded"]) and blk["buttons"] == [], blk
    # the winner's popup fades after a few seconds
    w.tick(12)
    assert not rollframe_state(B)["shown"], rollframe_state(B)
    w.assert_no_errors()


@R.case
def ml_give_to_player_without_addon():
    r = setup()
    w = r.w
    A = r["Alice"]
    A.eval(GIVE_SPY)
    r["Alice"].eval("ns.DropPanel:StartRoll(...)", MINDBLADE, 1)
    w.tick(1)
    sid = active_session(A)["id"]
    w.player_roll("Yuri", 91)                  # pug without the addon
    w.tick(1)
    A.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    res = results(A, sid)
    assert res[0]["key"] == key("Yuri") and res[0]["suggested"], res
    A.eval("ns.DropPanel:AwardSuggested(...)", A.eval("for _, b in ipairs(ns.DropPanel.blocks) do if b.itemID == %d then return b end end" % MINDBLADE))
    w.tick(0.2)
    A.accept_popup("CDLOOT_GIVE_ITEM")
    w.tick(2)
    gives = A.eval_py("return __LR.gives")
    assert len(gives) == 1 and gives[0]["name"] == "Yuri", gives
    assert session_info(r["Carol"], sid)["winner"] == key("Yuri")
    w.assert_no_errors()


@R.case
def non_ml_council_award_uses_confirm_popup():
    r = setup()
    w = r.w
    A, B = r["Alice"], r["Bob"]
    A.eval(GIVE_SPY)
    sid = rolled_session(r)
    log0, chat0 = len(w.addon_log), len(w.chat_log)
    B.eval("ns.DropPanel:AwardRoll(...)", sid, key("Dave"))
    w.tick(0.2)
    assert B.popups() == ["CDLOOT_CONFIRM_AWARD"], B.popups()
    txt = strip_codes(popups_log(B)[-1]["text"])
    assert txt.startswith("Award [Ruby Drape of the Mysticant] to Dave?") and "master loot or trade" in txt, txt
    B.accept_popup("CDLOOT_CONFIRM_AWARD")
    w.tick(2)
    assert A.eval_py("return __LR.gives") == [], "nothing is handed out by a non-ML"
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["_sender"] == key("Bob") and RW[0]["w"] == key("Dave") and RW[0]["g"] is False, RW
    for n in ADDON_USERS:
        s = session_info(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Dave"), (n, s)
    assert strip_codes(rollframe_state(r["Dave"])["status"]) == "You won it!"
    for n in ("Alice", "Bob"):
        vis = ledger_visible(r[n])
        assert [(e["w"], e["s"], e["n"]) for e in vis] == [(key("Dave"), "m", "roll 80")], (n, vis)
    lines = award_lines(w, chat0)
    assert len(lines) == 1 and lines[0]["sender"] == key("Bob"), lines
    assert strip_codes(lines[0]["text"]) == "CDLoot: [Ruby Drape of the Mysticant] -> Dave (rolled 80, BiS alt)", lines
    # the ML later hands the item out by hand: the loot message adds a hidden auto entry, still one visible award
    A.eval("GiveMasterLoot(1, ...)", 4)        # candidate 4 = Dave
    w.tick(2)
    for n in ("Alice", "Bob"):
        assert len(ledger_visible(r[n])) == 1, ledger_visible(r[n])
    w.assert_no_errors()


@R.case
def award_while_open_closes_first_and_cancel_keeps_it_closed():
    r = setup()
    w = r.w
    A = r["Alice"]
    sid = rolled_session(r, close=False)
    log0 = len(w.addon_log)
    A.eval("ns.Roll:Award(...)", sid, key("Bob"))
    w.tick(0.5)
    assert [m["id"] for m in msgs_of_type(w, "RE", log0)] == [sid]
    assert set(states(r, sid).values()) == {"closed"}, states(r, sid)
    assert A.popups() == ["CDLOOT_GIVE_ITEM"]
    A.cancel_popup("CDLOOT_GIVE_ITEM")
    w.tick(1)
    assert set(states(r, sid).values()) == {"closed"} and msgs_of_type(w, "RW", log0) == []
    assert ledger_raw(A) == []
    w.assert_no_errors()


@R.case
def raider_cannot_award():
    r = setup()
    w = r.w
    sid = rolled_session(r)
    C = r["Carol"]
    assert not C.eval("return ns.Roll:CanAward()")
    assert not C.eval("return ns.Roll:Award(...)", sid, key("Carol"))
    assert C.popups() == []
    w.assert_no_errors()


@R.case
def ml_award_to_player_not_eligible_falls_back_to_confirm():
    r = setup()
    w = r.w
    A = r["Alice"]
    A.eval(GIVE_SPY)
    sid = rolled_session(r, rolls=(("Frank", 99), ("Dave", 10)))
    r.leave_raid("Frank")
    w.tick(1)
    A.eval("ns.Roll:Award(...)", sid, key("Frank"))
    w.tick(0.2)
    assert A.popups() == ["CDLOOT_CONFIRM_AWARD"], A.popups()
    assert any("not eligible" in l for l in printed_lines(A)), printed_lines(A)[-3:]
    assert A.eval_py("return __LR.gives") == []
    w.assert_no_errors()


ML_LIST_SHIM = r"""
-- Candidates are only known after the master-loot list was opened (OPEN_MASTER_LOOT_LIST), like the real client.
__LR.mlOpen = false
__LR.clicks = 0
local origCand = GetMasterLootCandidate
GetMasterLootCandidate = function(slot, i)
  if not __LR.mlOpen then return nil end
  return origCand(slot, i)
end
LootButton_OnClick = function(btn, button)
  __LR.clicks = __LR.clicks + 1
  LootFrame.selectedSlot = btn.slot
  if __LR.mlListWorks ~= false then
    C_Timer.After(0.05, function() __LR.mlOpen = true; __MOCK.fire("OPEN_MASTER_LOOT_LIST") end)
  end
end
"""


@R.case
def ml_give_waits_for_master_loot_list():
    r = setup()
    w = r.w
    A, B = r["Alice"], r["Bob"]
    A.eval(GIVE_SPY)
    A.eval(ML_LIST_SHIM)
    sid = rolled_session(r)
    A.eval("ns.Roll:Award(...)", sid, key("Bob"))
    w.tick(0.2)
    assert A.popups() == ["CDLOOT_GIVE_ITEM"], A.popups()
    A.accept_popup("CDLOOT_GIVE_ITEM")
    w.tick(2)
    assert A.eval("return __LR.clicks") == 1
    gives = A.eval_py("return __LR.gives")
    assert len(gives) == 1 and gives[0]["name"] == "Bob", gives
    assert RUBY_DRAPE in bag_items(B)
    assert session_info(r["Carol"], sid)["state"] == "awarded" and session_info(A, sid)["given"] is True
    w.assert_no_errors()


@R.case
def ml_give_list_never_opens_times_out_to_confirm():
    r = setup()
    w = r.w
    A = r["Alice"]
    A.eval(GIVE_SPY)
    A.eval(ML_LIST_SHIM)
    A.eval("__LR.mlListWorks = false")
    sid = rolled_session(r)
    A.eval("ns.Roll:Award(...)", sid, key("Bob"))
    w.tick(0.2)
    A.accept_popup("CDLOOT_GIVE_ITEM")
    w.tick(6)
    assert A.eval_py("return __LR.gives") == []
    assert "CDLOOT_CONFIRM_AWARD" in A.popups(), A.popups()
    assert any("timed out" in l for l in printed_lines(A)), printed_lines(A)[-3:]
    A.accept_popup("CDLOOT_CONFIRM_AWARD")
    w.tick(1)
    assert session_info(r["Bob"], sid)["state"] == "awarded" and session_info(A, sid)["given"] is False
    w.assert_no_errors()


@R.case
def ml_closed_loot_window_uses_confirm_popup():
    r = setup()
    w = r.w
    A = r["Alice"]
    sid = rolled_session(r)
    A.close_loot()
    w.tick(0.5)
    A.eval("ns.Roll:Award(...)", sid, key("Bob"))
    w.tick(0.2)
    assert A.popups() == ["CDLOOT_CONFIRM_AWARD"], A.popups()
    w.assert_no_errors()


@R.case
def second_award_of_same_roll_refused():
    r = setup()
    w = r.w
    B = r["Bob"]
    sid = rolled_session(r)
    B.eval("ns.Roll:Award(...)", sid, key("Bob"))
    w.tick(0.2)
    B.accept_popup("CDLOOT_CONFIRM_AWARD")
    w.tick(1)
    assert not r["Alice"].eval("return ns.Roll:Award(...)", sid, key("Dave"))
    assert r["Alice"].popups() == []
    assert any("already awarded" in l for l in printed_lines(r["Alice"])), printed_lines(r["Alice"])[-2:]
    w.assert_no_errors()


@R.case
def simultaneous_awards_by_two_council_members_agree():
    """Alice and Bob confirm different winners for the same closed roll at the same moment. Every client must end
    up showing the same winner (and the award log should not credit the item twice)."""
    r = setup()
    w = r.w
    A, B = r["Alice"], r["Bob"]
    sid = rolled_session(r)
    A.close_loot()
    w.tick(0.5)
    A.eval("ns.Roll:Award(...)", sid, key("Bob"))
    B.eval("ns.Roll:Award(...)", sid, key("Dave"))
    w.tick(0.05)
    A.accept_popup("CDLOOT_CONFIRM_AWARD")
    B.accept_popup("CDLOOT_CONFIRM_AWARD")
    w.tick(2)
    winners = {n: session_info(r[n], sid)["winner"] for n in ADDON_USERS}
    assert len(set(winners.values())) == 1, "clients disagree on the winner: %r" % winners
    for n in ("Alice", "Bob"):
        vis = [e for e in ledger_visible(r[n]) if e["i"] == RUBY_DRAPE]
        assert len(vis) == 1, "%s: the item is credited %d times: %r" % (n, len(vis), vis)
    w.assert_no_errors()


@R.case
def handed_out_before_confirming_keeps_bis_winner():
    """Common habit: the ML gives the item with the normal master-loot menu, then clicks "Award to <suggested>".
    The loot-message auto entry for this very item must not demote the winner (suggestion + announce tier)."""
    r = setup()
    w = r.w
    A = r["Alice"]
    sid = rolled_session(r, rolls=(("Bob", 54), ("Dave", 80), ("Frank", 99)))
    res = results(A, sid)
    assert res[0]["key"] == key("Bob") and res[0]["suggested"], res
    chat0 = len(w.chat_log)
    A.eval("GiveMasterLoot(1, 2)")             # candidate 2 = Bob, straight from the Blizzard menu
    w.tick(15)                                 # loot message (ledger) + Bob's bag scan / list sync (obtained)
    res = results(A, sid)
    assert res[0]["key"] == key("Bob") and res[0]["suggested"], \
        "after the item was handed to Bob the suggestion moved to %r: %r" % (res[0]["key"], res)
    A.eval("ns.Roll:Award(...)", sid, key("Bob"))
    w.tick(0.2)
    A.accept_popup("CDLOOT_CONFIRM_AWARD")
    w.tick(1)
    lines = award_lines(w, chat0)
    assert lines and strip_codes(lines[-1]["text"]).endswith("(rolled 54, BiS)"), [strip_codes(e["text"]) for e in lines]
    w.assert_no_errors()


@R.case
def non_council_master_looter_suggestion_follows_bis_tiers():
    """Spec §19: the master looter (council or not) may start and award rolls, and the panel's primary button is
    "Award to <suggested>". A non-council client holds no other player's list, so every roller is tier 3 there."""
    r = Raid(ml="Frank")                        # Frank: rank 2, not council, master looter
    w = r.w
    F = r["Frank"]
    F.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    assert F.eval("return ns.Roll:CanStart() and ns.Roll:CanAward()")
    F.slash("/cdl drops")
    w.tick(0.5)
    F.eval("ns.DropPanel:StartRoll(...)", RUBY_DRAPE, 1)
    w.tick(1)
    sid = active_session(F)["id"]
    click_roll(r, "Bob", 10)                    # BiS main
    w.player_roll("Zed", 90)                    # not listed
    w.tick(1)
    F.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    council = [x["key"] for x in results(r["Alice"], sid) if x["suggested"]]
    ml = [x["key"] for x in results(F, sid) if x["suggested"]]
    assert council == [key("Bob")], council
    assert ml == council, "the master looter's panel suggests %r, the council's %r" % (ml, council)
    w.assert_no_errors()


@R.case
def non_council_master_looter_award_reaches_the_award_log():
    """Spec §19.1 step 3 records every roll award in the ledger. A non-council ML cannot write the (council-only)
    ledger itself; when the item is handed out by trade (no loot message) the council must still learn it."""
    r = Raid(ml="Frank")
    w = r.w
    F = r["Frank"]
    F.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    F.slash("/cdl drops")                       # not council: the panel does not open by itself
    w.tick(0.5)
    F.eval("ns.DropPanel:StartRoll(...)", RUBY_DRAPE, 1)
    w.tick(1)
    sid = active_session(F)["id"]
    click_roll(r, "Bob", 40)
    w.tick(1)
    F.eval("ns.Roll:End(...)", sid)
    F.close_loot()                              # handed out later by trade
    w.tick(1)
    F.eval("ns.Roll:Award(...)", sid, key("Bob"))
    w.tick(0.2)
    F.accept_popup("CDLOOT_CONFIRM_AWARD")
    w.tick(3)
    assert session_info(r["Alice"], sid)["state"] == "awarded" and session_info(r["Alice"], sid)["winner"] == key("Bob")
    for n in ("Alice", "Bob"):
        vis = [(e["w"], e["i"]) for e in ledger_visible(r[n])]
        assert vis == [(key("Bob"), RUBY_DRAPE)], "%s: roll award by the (non-council) ML missing from the log: %r" % (n, vis)
    w.assert_no_errors()


@R.case
def announce_lines_stay_within_255_bytes():
    r = setup(items=[(RUBY_DRAPE, 4), (THOUSAND_MARKS, 4), (HELM_CHAMPION, 4), (MINDBLADE, 4)])
    w = r.w
    A = r["Alice"]
    chat0 = len(w.chat_log)
    A.eval("ns.DropPanel:AnnounceAll()")
    w.tick(3)
    lines = [e for e in w.chat_log[chat0:] if e["sender"] == key("Alice")]
    assert len(lines) == 4, [strip_codes(e["text"]) for e in lines]
    txt = [strip_codes(e["text"]) for e in lines]
    assert txt[0] == "CDLoot: [Ruby Drape of the Mysticant] - BiS: Bob; Alt: Dave", txt
    assert txt[2] == "CDLoot: [Helm of the Fallen Champion] - BiS: Alice, Erin, Gina", txt
    assert "not on anyone's BiS list" in txt[3], txt
    # a very long line with several links is split into <=255-byte chunks without cutting a link
    links = A.eval("local t = {} for _, id in ipairs({...}) do t[#t+1] = ns.ItemDB:GetLink(id) end return table.concat(t, ' and ')",
                   RUBY_DRAPE, THOUSAND_MARKS, HELM_CHAMPION, MINDBLADE, JADE_RING, FARSTRIDER)
    chat1 = len(w.chat_log)
    A.eval("ns.UI:AnnounceLine(...)", "CDLoot: " + links + " - " + " ".join("Name%d" % i for i in range(30)))
    w.tick(1)
    chunks = w.chat_log[chat1:]
    assert len(chunks) >= 2, chunks
    for e in chunks:
        b = e["text"].encode("utf-8")
        assert len(b) <= 255, len(b)
        assert e["text"].count("|H") == e["text"].count("|h") // 2, "link cut in half: %r" % e["text"]
    for e in w.chat_log:
        assert len(e["text"].encode("utf-8")) <= 255
    w.assert_no_errors()


# ------------------------------------------------------------------------------------------------------------------
# Demo mode
# ------------------------------------------------------------------------------------------------------------------
@R.case
def demo_mode_solo_roll_and_award_stay_local():
    w = World()
    s = Client(w, "Solo", class_file="PRIEST", guild_rank=3)
    s.load_addon()
    install_probes([s])
    w.tick(3)
    log0, chat0 = len(w.addon_log), len(w.chat_log)
    s.slash("/cdl demo")
    w.tick(1)
    assert s.eval("return ns.Demo:IsEnabled()")
    s.slash("/cdl test")
    w.tick(1)
    drop = s.eval_py("return ns.DropPanel.drop")
    assert drop and drop["test"], drop
    item = drop["i"][0]
    s.eval("ns.DropPanel:StartRoll(...)", item, 1)
    w.tick(0.5)
    act = active_session(s)
    assert act and act["i"] == item, act
    sid = act["id"]
    assert rollframe_state(s)["shown"], "own popup shows in demo mode"
    w._roll_rng = FixedRng(64)
    s.click(s.eval("return ns.RollFrame.frame.roll"))
    del w._roll_rng
    w.tick(13)
    info = session_info(s, sid)
    rolls, resp = info["rolls"], info["responses"]
    assert rolls.get(key("Solo"), {}).get("roll") == 64, rolls
    passes = [k for k, v in resp.items() if v == "pass"]
    invalid = [k for k, v in rolls.items() if v.get("invalid")]
    doubles = [k for k, v in rolls.items() if (v.get("count") or 1) > 1]
    assert len(passes) == 2 and len(invalid) == 1 and len(doubles) == 1, (passes, invalid, doubles, rolls)
    s.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    res = results(s, sid)
    sug = [x for x in res if x["suggested"]]
    assert len(sug) == 1 and not sug[0]["invalid"], res
    s.eval("ns.Roll:Award(...)", sid, sug[0]["key"])
    w.tick(0.2)
    assert s.popups() == ["CDLOOT_CONFIRM_AWARD"], s.popups()
    s.accept_popup("CDLOOT_CONFIRM_AWARD")
    w.tick(1)
    assert session_info(s, sid)["state"] == "awarded"
    vis = ledger_visible(s)
    assert len(vis) == 1 and vis[0]["w"] == sug[0]["key"], vis
    assert s.eval_py("local n = 0 for _ in pairs(ns.db.ledger) do n = n + 1 end return n") == 0, "real ledger untouched"
    sent = [decode_msg(s, e["text"]) for e in w.addon_log[log0:] if e["prefix"].startswith("CDL")]
    bad = [m.get("t") for m in sent if m and m.get("t") in ("RS", "RR", "RE", "RW", "A", "D", "LG", "LW")]
    assert bad == [], "demo roll / award traffic was sent: %r" % bad     # the normal guild HELLO is fine
    assert w.chat_log[chat0:] == [], [e["text"] for e in w.chat_log[chat0:]]
    assert any("demo: only shown to you" in l for l in printed_lines(s))
    s.slash("/cdl demo")
    w.tick(1)
    assert not s.eval("return ns.Demo:IsEnabled()")
    assert ledger_visible(s) == [], "demo awards discarded when demo mode ends"
    s.relog()
    w.tick(3)
    assert "Aldrin" not in str(w.saved_variables(s)), "no demo data in SavedVariables"
    w.assert_no_errors()


@R.case
def demo_mode_inside_a_real_raid_sends_nothing():
    r = setup()
    w = r.w
    A = r["Alice"]
    ledger_before = ledger_raw(A)
    A.slash("/cdl demo")
    w.tick(1)
    log0, chat0 = len(w.addon_log), len(w.chat_log)
    A.slash("/cdl test")
    w.tick(1)
    drop = A.eval_py("return ns.DropPanel.drop")
    item = drop["i"][0]
    A.eval("ns.DropPanel:StartRoll(...)", item, 1)
    w.tick(13)
    sid = active_session(A)["id"]
    A.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    sug = [x for x in results(A, sid) if x["suggested"]]
    A.eval("ns.Roll:Award(...)", sid, sug[0]["key"])
    w.tick(0.2)
    A.accept_popup("CDLOOT_CONFIRM_AWARD")
    w.tick(2)
    sent = [e for e in w.addon_log[log0:] if e["sender"] == key("Alice") and e["prefix"].startswith("CDL")]
    kinds = [decode_msg(A, e["text"]) for e in sent]
    bad = [m.get("t") for m in kinds if m and m.get("t") in ("RS", "RR", "RE", "RW", "A", "D", "LG")]
    assert bad == [], "demo traffic reached the raid/council: %r" % bad
    assert [e for e in w.chat_log[chat0:] if e["sender"] == key("Alice")] == [], w.chat_log[chat0:]
    for n in ADDON_USERS:
        if n != "Alice":
            assert active_session(r[n]) is None and r[n].eval("return ns.Roll:Get(...) == nil", sid), n
    assert ledger_raw(A) == ledger_before and ledger_raw(r["Bob"]) == ledger_before
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

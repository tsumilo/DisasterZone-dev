#!/usr/bin/env python
"""Addendum G: award reasons, council votes on rolls, and the disenchanter / guild bank targets.

Reasons: default from the winner's tier, chosen reasons (RW r), offspec / disenchant / bank not counted as loot won,
disenchant / bank not "awarded", Ledger:SetReason sync and merge rules, digests unchanged for unedited reasons.
Votes: RV on the raid channel, one vote per council member, the vote-based suggestion, ties, forged votes.
Targets: CG / CR carry de / bk, the raid leader's pick overrides the guild's, the drop panel's DE / Bank buttons
(plain record and master-loot give), older messages without the new fields.

Run: luaenv\\Scripts\\python.exe tests\\votes\\test_votes.py   [-k substring]
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "loot-roll"))

from lr_common import *  # noqa: F401,F403,E402
from test_rolls import setup, click_roll, click_pass, ADDON_USERS  # noqa: E402

R = Runner("votes / award reasons / DE-bank (Addendum G)")


def start_roll(r, item=RUBY_DRAPE, starter="Alice"):
    r[starter].eval("ns.DropPanel:StartRoll(...)", item, 1)
    r.w.tick(1)
    return active_session(r[starter])["id"]


def vote(c, sid, name):
    return c.eval("return ns.Roll:Vote(...)", sid, key(name) if name else None)


def rows_by_key(c, sid):
    out = {}
    for row in c.eval_py(r"""
        local out = {}
        for i, r in ipairs(ns.Roll:GetResults(...)) do
          local voters = {}
          for j, v in ipairs(r.voters or {}) do voters[j] = v end
          out[i] = { key = r.key, votes = r.votes, voters = voters, suggested = r.suggested, by = r.suggestedBy,
                     tie = r.tie, tier = r.tier, roll = r.roll, myVote = r.myVote }
        end
        return out""", sid) or []:
        out[row["key"]] = row
    return out


def suggested(c, sid):
    for k, row in rows_by_key(c, sid).items():
        if row["suggested"]:
            return k, row
    return None, None


def ledger_full(c):
    return c.eval_py(r"""
        local out = {}
        for i, e in ipairs(ns.Ledger:GetEntries({ includeVoid = true })) do
          out[i] = { id = e.id, i = e.i, w = e.w, s = e.s, n = e.n, r = e.r, rts = e.rts, vd = e.vd }
        end
        return out""") or []


def award_confirm(r, awarder, sid, name, reason=None):
    c = r[awarder]
    c.eval("ns.DropPanel:AwardRoll(...)", sid, key(name), reason)
    r.w.tick(0.2)
    pops = c.popups()
    assert pops, "no confirmation popup"
    c.accept_popup(pops[0])
    r.w.tick(3)


# ----------------------------------------------------------------------------------------------------------------
# Reasons
# ----------------------------------------------------------------------------------------------------------------
@R.case
def reason_defaults_from_tier_and_travels_in_rw():
    r = setup()
    w = r.w
    sid = start_roll(r)
    click_roll(r, "Bob", 54)
    click_roll(r, "Dave", 80)
    w.tick(1)
    r["Alice"].eval("ns.Roll:End(...)", sid)
    w.tick(1)
    log0, chat0 = len(w.addon_log), len(w.chat_log)
    award_confirm(r, "Bob", sid, "Dave")          # Dave has it as alt
    RW = msgs_of_type(w, "RW", log0)
    assert len(RW) == 1 and RW[0]["r"] == "alt", RW
    for n in ("Alice", "Bob"):
        vis = ledger_full(r[n])
        assert len(vis) == 1 and vis[0]["w"] == key("Dave") and vis[0].get("r") == "alt" and vis[0].get("rts") is None, (n, vis)
    line = [e for e in w.chat_log[chat0:] if "->" in e["text"]]
    assert strip_codes(line[0]["text"]).endswith("-> Dave (rolled 80, Alt)"), line
    blk = [b for b in panel_blocks(r["Alice"]) if b["item"] == RUBY_DRAPE][0]
    assert "Alt" in strip_codes(blk["awarded"]) or "Alt" in strip_codes(blk["sub"]), blk
    w.assert_no_errors()


@R.case
def offspec_award_not_counted_but_awarded():
    r = setup()
    w = r.w
    sid = start_roll(r)
    click_roll(r, "Bob", 54)
    w.tick(1)
    r["Alice"].eval("ns.Roll:End(...)", sid)
    w.tick(1)
    chat0 = len(w.chat_log)
    award_confirm(r, "Bob", sid, "Bob", "os")
    for n in ("Alice", "Bob"):
        vis = ledger_full(r[n])
        assert vis[0]["r"] == "os", (n, vis)
        assert r[n].eval("return ns.Ledger:CountSince(...)", key("Bob"), 0) == 0, n
        assert r[n].eval("return ns.Ledger:HasAward(...)", key("Bob"), RUBY_DRAPE) is True, n
    line = [e for e in w.chat_log[chat0:] if "->" in e["text"]]
    assert strip_codes(line[0]["text"]).endswith("-> Bob (rolled 54, Offspec)"), line
    w.assert_no_errors()


@R.case
def disenchant_and_bank_neither_counted_nor_awarded():
    r = setup()
    A = r["Alice"]
    A.eval("ns.Ledger:Award(...)", RUBY_DRAPE, key("Bob"), "Karazhan:Prince", None, None, "de")
    A.eval("ns.Ledger:Award(...)", JADE_RING, key("Dave"), "Karazhan:Prince", None, None, "bank")
    A.eval("ns.Ledger:Award(...)", THOUSAND_MARKS, key("Carol"), "Karazhan:Prince", None, None, "bis")
    r.w.tick(2)
    for n in ("Alice", "Bob"):
        c = r[n]
        assert c.eval("return ns.Ledger:HasAward(...)", key("Bob"), RUBY_DRAPE) is False, n
        assert c.eval("return ns.Ledger:HasAward(...)", key("Dave"), JADE_RING) is False, n
        assert c.eval("return ns.Ledger:HasAward(...)", key("Carol"), THOUSAND_MARKS) is True, n
        assert c.eval("return ns.Ledger:CountSince(...)", key("Bob"), 0) == 0
        assert c.eval("return ns.Ledger:CountSince(...)", key("Carol"), 0) == 1
    # Bob is still a BiS main wanter of the drape (the disenchant award didn't give it to him)
    assert key("Bob") + ":main" in wanter_keys(A, RUBY_DRAPE)
    r.w.assert_no_errors()


@R.case
def set_reason_syncs_and_newer_change_wins():
    r = setup()
    w = r.w
    A, B = r["Alice"], r["Bob"]
    e = A.eval_py("local e = ns.Ledger:Award(...) return { id = e.id }", RUBY_DRAPE, key("Bob"), "Karazhan:Prince",
                  None, None, "bis")
    w.tick(2)
    eid = e["id"]
    assert B.eval_py("return ns.db.ledger[...].r", eid) == "bis"
    dig_a0 = A.eval_py("return ns.Ledger:GetDigest()")
    assert A.eval("return ns.Ledger:SetReason(...)", eid, "os") is True
    w.tick(2)
    for c in (A, B):
        ent = c.eval_py("local e = ns.db.ledger[...] return { r = e.r, rts = e.rts }", eid)
        assert ent["r"] == "os" and ent["rts"], (c.name, ent)
    assert A.eval_py("return ns.Ledger:GetDigest()") == B.eval_py("return ns.Ledger:GetDigest()")
    assert A.eval_py("return ns.Ledger:GetDigest()") != dig_a0, "a changed reason is part of the digest"
    # an older change (smaller rts) never wins
    rts = A.eval_py("return ns.db.ledger[...].rts", eid)
    old = A.eval_py("local e = ns.db.ledger[...] local c = {} for k, v in pairs(e) do c[k] = v end c.g = nil return c", eid)
    old["r"], old["rts"] = "bis", rts - 5
    assert B.eval("return ns.Ledger:Merge(...)", old, key("Alice")) is False
    assert B.eval_py("return ns.db.ledger[...].r", eid) == "os"
    # equal rts: a missing reason is filled in; two different ones settle on the smaller key
    newer = dict(old)
    newer["r"], newer["rts"] = "bank", rts
    assert B.eval("return ns.Ledger:Merge(...)", newer, key("Alice")) is True
    assert B.eval_py("return ns.db.ledger[...].r", eid) == "bank"   # "bank" < "os"
    w.assert_no_errors()


@R.case
def unedited_reason_digests_like_05():
    r = setup()
    A = r["Alice"]
    A.eval("ns.Ledger:Award(...)", RUBY_DRAPE, key("Bob"), "Karazhan:Prince", None, None, "bis")
    r.w.tick(1)
    d1 = A.eval_py("return ns.Ledger:GetDigest()")
    A.eval("for id, e in pairs(ns.db.ledger) do e.r = nil end ns.Ledger:Merge({ id = 'x', i = 1 }, 'y')")
    d2 = A.eval_py("return ns.Ledger:GetDigest()")
    assert d1 == d2, (d1, d2)
    r.w.assert_no_errors()


@R.case
def unknown_reason_from_newer_version_kept():
    r = setup()
    B = r["Bob"]
    now = B.eval("return GetServerTime()")
    e = {"id": "m%dAlice12345" % now, "i": RUBY_DRAPE, "w": key("Bob"), "by": key("Alice"), "ts": now, "s": "m",
         "b": "", "r": "loan"}
    assert B.eval("return ns.Ledger:Merge(...)", e, key("Alice")) is True
    assert B.eval_py("return ns.db.ledger[...].r", e["id"]) == "loan"
    assert B.eval("return ns.Ledger:CountSince(...)", key("Bob"), 0) == 1   # unknown reasons count
    bad = dict(e, id=e["id"] + "b", r="<|cff>")
    assert B.eval("return ns.Ledger:Merge(...)", bad, key("Alice")) is True
    assert B.eval_py("return ns.db.ledger[...].r", bad["id"]) is None
    r.w.assert_no_errors()


@R.case
def rw_without_reason_from_older_client():
    r = setup()
    w = r.w
    sid = start_roll(r)
    click_roll(r, "Bob", 54)
    w.tick(1)
    r["Alice"].eval("ns.Roll:End(...)", sid)
    w.tick(1)
    # An 0.5 master looter's RW (no r): council clients record it without a reason
    r["Alice"].eval(r"""
        local id = ...
        ns.Comm:Send({ t = "RW", id = id, w = ns.Util.NormalizeName("Bob"), g = false, at = GetServerTime(),
                       n = "roll 54" }, "RAID", nil, "alert")""", sid)
    w.tick(2)
    vis = ledger_full(r["Bob"])
    assert len(vis) == 1 and vis[0].get("r") is None, vis
    w.assert_no_errors()


# ----------------------------------------------------------------------------------------------------------------
# Votes
# ----------------------------------------------------------------------------------------------------------------
@R.case
def votes_override_roll_suggestion_everywhere():
    r = setup()
    w = r.w
    A, B = r["Alice"], r["Bob"]
    sid = start_roll(r)
    click_roll(r, "Bob", 20)
    click_roll(r, "Dave", 90)
    click_roll(r, "Frank", 99)
    w.tick(1)
    k, row = suggested(A, sid)
    assert k == key("Bob") and row["by"] == "roll", (k, row)       # tier 1 beats the higher rolls
    log0 = len(w.addon_log)
    assert vote(A, sid, "Dave") is True
    assert vote(B, sid, "Dave") is True
    w.tick(1)
    RV = msgs_of_type(w, "RV", log0)
    assert len(RV) == 2 and all(m["_chat_type"] == "RAID" and m["k"] == key("Dave") for m in RV), RV
    for n in ADDON_USERS:
        rows = rows_by_key(r[n], sid)
        assert rows[key("Dave")]["votes"] == 2, (n, rows[key("Dave")])
        assert rows[key("Dave")]["voters"] == [key("Alice"), key("Bob")], (n, rows[key("Dave")])
    for n in ("Alice", "Bob"):
        k, row = suggested(r[n], sid)
        assert k == key("Dave") and row["by"] == "votes" and not row["tie"], (n, k, row)
    assert rows_by_key(A, sid)[key("Dave")]["myVote"] is True
    # voting for the same player again takes the vote back
    assert vote(A, sid, "Dave") is True
    w.tick(1)
    assert rows_by_key(B, sid)[key("Dave")]["votes"] == 1
    # moving a vote
    vote(A, sid, "Frank")
    w.tick(1)
    rows = rows_by_key(B, sid)
    assert rows[key("Frank")]["votes"] == 1 and rows[key("Dave")]["votes"] == 1
    # 1-1: tie broken by tier (Dave alt = tier 2, Frank not listed = tier 3)
    k, row = suggested(B, sid)
    assert k == key("Dave") and not row["tie"], (k, row)
    w.assert_no_errors()


@R.case
def vote_tie_same_tier_and_no_rolls():
    r = setup()
    w = r.w
    A, B = r["Alice"], r["Bob"]
    sid = start_roll(r, MINDBLADE)
    w.tick(1)
    vote(A, sid, "Carol")
    vote(B, sid, "Erin")
    w.tick(1)
    rows = rows_by_key(A, sid)
    assert rows[key("Carol")]["tie"] and rows[key("Erin")]["tie"], rows
    assert sum(1 for x in rows.values() if x["suggested"]) == 1
    w.assert_no_errors()


@R.case
def votes_for_passers_and_nonvoters_ignored():
    r = setup()
    w = r.w
    A, C = r["Alice"], r["Carol"]
    sid = start_roll(r)
    click_roll(r, "Bob", 20)
    click_pass(r, "Dave")
    w.tick(1)
    vote(A, sid, "Dave")        # Dave passed: listed with the vote, never suggested for it
    w.tick(1)
    rows = rows_by_key(A, sid)
    assert rows[key("Dave")]["votes"] == 1 and not rows[key("Dave")]["suggested"], rows
    k, row = suggested(A, sid)
    assert k == key("Bob") and row["by"] == "roll", (k, row)
    # a raider (not council) cannot vote, and a forged RV from one is ignored
    assert vote(C, sid, "Frank") is False
    C.eval("ns.Comm:Send({ t = 'RV', id = ..., k = ns.Util.NormalizeName('Frank') }, 'RAID', nil, 'alert')", sid)
    # a vote for someone outside the group is ignored
    r["Bob"].eval("ns.Comm:Send({ t = 'RV', id = ..., k = 'Nobody-Thunderstrike' }, 'RAID', nil, 'alert')", sid)
    w.tick(1)
    rows = rows_by_key(A, sid)
    assert rows.get(key("Frank"), {}).get("votes", 0) == 0, rows.get(key("Frank"))
    assert "Nobody-Thunderstrike" not in rows
    w.assert_no_errors()


@R.case
def voted_award_note_and_announce():
    r = setup()
    w = r.w
    A, B = r["Alice"], r["Bob"]
    sid = start_roll(r)
    click_roll(r, "Frank", 30)
    w.tick(1)
    vote(A, sid, "Frank")
    vote(B, sid, "Frank")
    w.tick(1)
    A.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    chat0 = len(w.chat_log)
    award_confirm(r, "Bob", sid, "Frank")
    line = [e for e in w.chat_log[chat0:] if "->" in e["text"]]
    assert strip_codes(line[0]["text"]).endswith("-> Frank (2 votes, rolled 30, Upgrade)"), line
    vis = ledger_full(A)
    assert vis[0]["n"] == "roll 30; 2 votes" and vis[0]["r"] == "up", vis
    # no votes after the award
    assert A.eval("return ns.Roll:CanVote(...)", sid) is False
    w.assert_no_errors()


@R.case
def raid_council_member_can_vote():
    r = setup()
    w = r.w
    raid_pick(w, r["Alice"], ["Gina"])
    w.tick(2)
    sid = start_roll(r)
    assert r["Gina"].eval("return ns.Roll:CanVote(...)", sid) is True
    vote(r["Gina"], sid, "Erin")
    w.tick(1)
    assert rows_by_key(r["Alice"], sid)[key("Erin")]["votes"] == 1
    w.assert_no_errors()


@R.case
def drop_panel_vote_column_click():
    r = setup()
    w = r.w
    A = r["Alice"]
    sid = start_roll(r)
    click_roll(r, "Bob", 20)
    w.tick(1)
    A.eval("ns.DropPanel:Render()")
    ok = A.eval(r"""
        for _, b in ipairs(ns.DropPanel.blocks) do
          if b:IsShown() and b.itemID == ... then
            for _, row in ipairs(b.rows) do
              if row:IsShown() and row.data and row.data.key == ns.Util.NormalizeName("Bob") then
                if not row.voteBtn:IsShown() then return "hidden" end
                row.voteBtn:Click()
                return true
              end
            end
          end
        end
        return false""", RUBY_DRAPE)
    assert ok is True, ok
    w.tick(1)
    assert rows_by_key(r["Bob"], sid)[key("Bob")]["votes"] == 1
    A.eval("ns.DropPanel:Render()")
    txt = A.eval(r"""
        for _, b in ipairs(ns.DropPanel.blocks) do
          if b:IsShown() and b.itemID == ... then
            for _, row in ipairs(b.rows) do
              if row:IsShown() and row.data and row.data.key == ns.Util.NormalizeName("Bob") then return row.votes:GetText() end
            end
          end
        end""", RUBY_DRAPE)
    assert strip_codes(txt).endswith("1"), txt
    # raiders see no vote button
    assert r["Carol"].eval("return ns.Roll:CanVote(...)", sid) is False
    w.assert_no_errors()


@R.case
def demo_officers_vote():
    w = World()
    c = Client(w, "Solo", class_file="MAGE", guild_rank=0)
    c.load_addon()
    w.tick(2)
    c.slash("/cdl demo on")
    w.tick(1)
    c.slash("/cdl test")
    w.tick(1)
    item = c.eval("local h = ns.Loot:GetHistory() return h[#h].i[1]")
    c.eval("ns.DropPanel:StartRoll(...)", item, 1)
    w.tick(15)
    sid = c.eval("for id, s in pairs(ns.Roll._debugSessions and ns.Roll._debugSessions() or {}) do return id end") \
        or (active_session(c) or {}).get("id")
    assert sid, "demo roll session"
    rows = rows_by_key(c, sid)
    assert sum(x["votes"] for x in rows.values()) >= 1, rows
    k, row = suggested(c, sid)
    assert k and row["by"] == "votes", (k, row)
    # the DE / Bank stand-ins exist in demo mode
    assert c.eval("return (ns.Guild:GetLootTarget('de'))") is not None
    w.assert_no_errors()


# ----------------------------------------------------------------------------------------------------------------
# Disenchanter / guild bank
# ----------------------------------------------------------------------------------------------------------------
def gm_targets(r, de=None, bank=None):
    A = r["Alice"]
    members = A.eval_py("local g = ns.Guild:GetGuildCouncil() local out = {} for k in pairs(g.members) do out[#out+1] = k end return out")
    ok = A.eval("return ns.Guild:SetGuildCouncil(...)", members, None,
                {"de": key(de) if de else False, "bank": key(bank) if bank else False})
    assert ok, "SetGuildCouncil"
    r.w.tick(2)


@R.case
def guild_targets_shared_by_cg():
    r = setup()
    w = r.w
    log0 = len(w.addon_log)
    gm_targets(r, de="Erin", bank="Zed")
    CG = msgs_of_type(w, "CG", log0)
    assert CG and CG[-1]["de"] == key("Erin") and CG[-1]["bk"] == key("Zed"), CG
    for n in ADDON_USERS:
        c = r[n]
        assert c.eval_py("return { ns.Guild:GetLootTarget('de') }") == [key("Erin"), "guild"], n
        assert c.eval_py("return { ns.Guild:GetLootTarget('bank') }") == [key("Zed"), "guild"], n
    # the members / phase stay; a later save without targets keeps them
    A = r["Alice"]
    members = A.eval_py("local g = ns.Guild:GetGuildCouncil() local out = {} for k in pairs(g.members) do out[#out+1] = k end return out")
    A.eval("ns.Guild:SetGuildCouncil(...)", members, 2)
    w.tick(2)
    assert r["Carol"].eval("return (ns.Guild:GetLootTarget('de'))") == key("Erin")
    # clearing
    gm_targets(r, de=None, bank="Zed")
    assert r["Carol"].eval("return (ns.Guild:GetLootTarget('de'))") is None
    # a malformed de drops the CG
    rev = A.eval("return ns.Guild:GetGuildCouncilRev()")
    A.eval(r"""ns.Comm:Send({ t = "CG", rev = ... + 1, m = {}, ph = 1, by = ns.Util.PlayerKey(), de = "a|cffbad" },
                              "GUILD", nil, "ctrl")""", rev)
    w.tick(2)
    assert r["Carol"].eval("return ns.Guild:GetGuildCouncilRev()") == rev
    w.assert_no_errors()


@R.case
def raid_leader_target_overrides_guild():
    r = setup()
    w = r.w
    gm_targets(r, de="Erin", bank="Zed")
    ok = r["Alice"].eval("return ns.Guild:SetMyRaidList(...)", [], {"de": key("Gina")})
    assert ok
    w.tick(2)
    for n in ("Bob", "Carol", "Gina"):
        assert r[n].eval_py("return { ns.Guild:GetLootTarget('de') }") == [key("Gina"), "raid"], n
        assert r[n].eval_py("return { ns.Guild:GetLootTarget('bank') }") == [key("Zed"), "guild"], n
    w.disband()
    w.tick(2)
    assert r["Carol"].eval_py("return { ns.Guild:GetLootTarget('de') }") == [key("Erin"), "guild"]
    w.assert_no_errors()


def block_button(c, item, field):
    return c.eval(r"""
        local item, field = ...
        ns.DropPanel:Render()
        for _, b in ipairs(ns.DropPanel.blocks) do
          if b:IsShown() and b.itemID == item then
            local btn = b[field]
            return btn:IsShown() and (btn:IsEnabled() and "on" or "off") or "hidden"
          end
        end
        return "noblock" """, item, field)


def click_block_button(c, item, field):
    c.eval(r"""
        local item, field = ...
        for _, b in ipairs(ns.DropPanel.blocks) do
          if b:IsShown() and b.itemID == item then b[field]:Click() return end
        end""", item, field)


@R.case
def de_button_records_for_non_ml_council():
    r = setup(ml="Bob")          # Bob is ML; Alice (council, not ML) awards
    w = r.w
    gm_targets(r, de="Erin")
    A = r["Alice"]
    A.eval("ns.DropPanel:ShowHistory()")
    w.tick(0.5)
    assert block_button(A, MINDBLADE, "deBtn") == "on"
    assert block_button(A, MINDBLADE, "bankBtn") == "hidden"     # no bank character set
    click_block_button(A, MINDBLADE, "deBtn")
    w.tick(2)
    for n in ("Alice", "Bob"):
        vis = ledger_full(r[n])
        assert len(vis) == 1 and vis[0]["w"] == key("Erin") and vis[0]["r"] == "de" and vis[0]["i"] == MINDBLADE, (n, vis)
    assert block_button(A, MINDBLADE, "deBtn") == "hidden"       # awarded now
    w.assert_no_errors()


@R.case
def de_button_ml_gives_with_master_loot():
    r = setup()
    w = r.w
    gm_targets(r, bank="Erin")
    A = r["Alice"]                # ML with the loot window open
    A.eval("ns.DropPanel:ShowHistory()")
    w.tick(0.5)
    click_block_button(A, MINDBLADE, "bankBtn")
    w.tick(0.2)
    assert A.popups() == ["CDLOOT_GIVE_TARGET"], A.popups()
    A.accept_popup("CDLOOT_GIVE_TARGET")
    w.tick(3)
    assert MINDBLADE in (r["Erin"].eval_py("local out = {} for b = 0, 4 do for s = 1, 16 do local id = C_Container.GetContainerItemID(b, s) if id then out[#out+1] = id end end end return out") or [])
    vis = ledger_full(r["Bob"])
    assert len(vis) == 1 and vis[0]["w"] == key("Erin") and vis[0]["r"] == "bank", vis
    w.assert_no_errors()


@R.case
def de_button_goes_through_open_roll():
    r = setup()
    w = r.w
    gm_targets(r, de="Erin")
    A = r["Alice"]
    sid = start_roll(r, MINDBLADE)
    w.tick(1)
    A.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    assert block_button(A, MINDBLADE, "deBtn") == "on"            # nobody rolled: no suggestion
    click_block_button(A, MINDBLADE, "deBtn")
    w.tick(0.2)
    assert A.popups() == ["CDLOOT_GIVE_ITEM"], A.popups()
    A.accept_popup("CDLOOT_GIVE_ITEM")
    w.tick(3)
    s = session_info(r["Carol"], sid)
    assert s["state"] == "awarded" and s["winner"] == key("Erin"), s
    vis = ledger_full(r["Bob"])
    assert len(vis) == 1 and vis[0]["r"] == "de", vis
    w.assert_no_errors()


@R.case
def council_ui_saves_targets():
    r = setup()
    w = r.w
    A = r["Alice"]
    A.eval("ns.CouncilUI:ShowCouncil()")
    w.tick(0.5)
    assert A.eval("return ns.CouncilUI:SetCouncilDraftTarget('guild', 'de', ...)", key("Frank")) is True
    assert A.eval("return ns.CouncilUI:GetCouncilDraft('guild').dirty") is True
    assert A.eval("return ns.CouncilUI:SaveCouncil('guild')") is True
    w.tick(2)
    assert r["Dave"].eval("return (ns.Guild:GetLootTarget('de'))") == key("Frank")
    assert A.eval("return ns.CouncilUI:GetCouncilDraft('guild').dirty") is False
    # raid section as raid leader
    assert A.eval("return ns.CouncilUI:SetCouncilDraftTarget('raid', 'bank', ...)", key("Gina")) is True
    assert A.eval("return ns.CouncilUI:SaveCouncil('raid')") is True
    w.tick(2)
    assert r["Dave"].eval_py("return { ns.Guild:GetLootTarget('bank') }") == [key("Gina"), "raid"]
    # non-editors can't
    assert r["Carol"].eval("return ns.CouncilUI:SetCouncilDraftTarget('guild', 'de', ...)", key("Frank")) is False
    w.assert_no_errors()


@R.case
def loot_log_reason_column_and_menu():
    r = setup()
    w = r.w
    A = r["Alice"]
    A.eval("ns.Ledger:Award(...)", RUBY_DRAPE, key("Bob"), "Karazhan:Prince", None, None, "bis")
    w.tick(1)
    A.eval("ns.MainFrame:Open('loot')")
    w.tick(0.5)
    assert A.find_text("Reason"), "Reason header"
    eid = ledger_full(A)[0]["id"]
    A.eval("ns.Ledger:SetReason(...)", eid, "os")
    w.tick(1)
    assert ledger_full(r["Bob"])[0]["r"] == "os"
    # award dialog with a reason
    A.eval("ns.LootLogUI:OpenAwardDialog(...)", JADE_RING, key("Dave"), "Karazhan:Prince", None, {"reason": "alt"})
    w.tick(0.2)
    A.eval("CDLootAwardDialog.saveBtn:Click()")
    w.tick(1)
    e = [x for x in ledger_full(A) if x["i"] == JADE_RING][0]
    assert e["r"] == "alt", e
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

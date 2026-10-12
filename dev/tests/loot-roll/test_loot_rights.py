#!/usr/bin/env python
"""Loot-roll area: who may do what with the loot in a raid (1.3, the user's decisions of 2026-10-04).

- Pugs are never loot council: a master looter outside the guild is not council (it may still start rolls).
- The master looter joins the raid's loot council while the loot council runs (Guild source "ml"): its votes count,
  it gets the lists like the raid's other council; with the loot council off it is not council.
- Rolling plain (loot council off): the master looter starts, ends and awards rolls; its End roll and its award close
  the roll on every client (RE / RW accepted from it), and the council records the award.
- The plain-roll flag comes from the starter (RS pl = 1 / 0): a council member that just reloaded (no raid rules yet)
  does not take a loot council roll for a plain one.
- A master looter outside the council gives an item to the disenchanter / guild bank character: every council client
  records it with its reason (LT), so it does not count as loot won; an LT from anyone else, or naming someone who is
  not the target, is ignored.

Run: luaenv\\Scripts\\python.exe tests\\loot-roll\\test_loot_rights.py   [-k substring]
"""
from lr_common import *  # noqa: F401,F403
from test_rolls import click_roll, ADDON_USERS, states  # noqa: F401

R = Runner("loot-roll / loot rights (1.3)")


def source(c, name):
    return c.eval("return ns.Guild:GetCouncilSource(...)", key(name))


def council_of(c):
    return c.eval_py("return ns.Guild:GetCouncilMembers()") or []


def ses(c, sid):
    return c.eval_py("local s = ns.Roll:Get(...) if not s then return nil end "
                     "return { state = s.state, winner = s.winner, plain = s.plain, given = s.given }", sid)


def ledger_with_reason(c):
    return c.eval_py(r"""
        local out = {}
        for i, e in ipairs(ns.Ledger:GetEntries()) do
          out[i] = { id = e.id, i = e.i, w = e.w, s = e.s, r = e.r, by = e.by }
        end
        return out""") or []


@R.case
def master_looter_is_raid_council_while_the_loot_council_runs():
    r = Raid(ml="Frank")                         # Frank: guild member (rank 2), not on the guild council list
    w = r.w
    A, F = r["Alice"], r["Frank"]
    for n in ADDON_USERS:
        assert source(r[n], "Frank") == "ml", (n, source(r[n], "Frank"))
        assert key("Frank") in council_of(r[n]), n
    assert F.eval("return ns.Guild:AmICouncil(true)") is True
    assert F.eval("return ns.Guild:IsGuildCouncil(ns.Util.PlayerKey())") is False   # council of this raid only
    # Frank got the raid's lists like any raid-scope council member, so his panel ranks the rollers like the council
    F.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    A.eval("ns.DropPanel:StartRoll(...)", RUBY_DRAPE, 1)
    w.tick(1)
    sid = active_session(A)["id"]
    click_roll(r, "Dave", 80)                   # BiS alt
    click_roll(r, "Bob", 10)                    # BiS main
    w.tick(1)
    A.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    sug = lambda c: [x["key"] for x in results(c, sid) if x["suggested"]]   # noqa: E731
    assert sug(F) == sug(A) == [key("Bob")], (sug(F), sug(A))
    # his vote counts everywhere
    assert F.eval("return ns.Roll:CanVote(...)", sid) is True
    assert F.eval("return ns.Roll:Vote(...)", sid, key("Dave")) is True
    w.tick(1)
    votes = lambda c: {x["key"]: x for x in c.eval_py(  # noqa: E731
        "local out = {} for i, x in ipairs(ns.Roll:GetResults(...)) do out[i] = { key = x.key, votes = x.votes, "
        "suggested = x.suggested } end return out", sid)}
    for n in ("Alice", "Bob", "Frank"):
        v = votes(r[n])
        assert v[key("Dave")]["votes"] == 1 and v[key("Dave")]["suggested"], (n, v)
    # the loot council off: the master looter is no longer council anywhere, and his vote stops counting
    set_features(r, loot=False, rolls=True)
    for n in ADDON_USERS:
        assert source(r[n], "Frank") is None, (n, source(r[n], "Frank"))
    for n in ("Alice", "Bob"):
        v = votes(r[n])
        assert v[key("Dave")]["votes"] == 0 and v[key("Bob")]["suggested"], (n, v)
    # back on, and another master looter: council follows the master looter
    set_features(r, loot=True, rolls=True)
    w.set_master_looter(r["Gina"])
    w.tick(1)
    for n in ("Alice", "Bob", "Gina"):
        assert source(r[n], "Gina") == "ml" and source(r[n], "Frank") is None, n
    w.assert_no_errors()


@R.case
def pug_master_looter_is_never_council_but_starts_rolls():
    roster = list(ROSTER) + [("Pete", "WARRIOR", 3)]
    r = Raid(roster=roster, ml="Pete", client_kw={"Pete": {"guild": None}})   # Pete: a pug, master looter
    w = r.w
    A, P = r["Alice"], r["Pete"]
    for n in ADDON_USERS:
        assert source(r[n], "Pete") is None and key("Pete") not in council_of(r[n]), n
    assert P.eval("return ns.Guild:AmICouncil(true)") is False
    # the master looter can always start rolls (the council then decides)
    P.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    assert P.eval("return ns.Roll:CanStart()") is True
    P.eval("ns.DropPanel:StartRoll(...)", RUBY_DRAPE, 1)
    w.tick(1)
    sid = active_session(P)["id"]
    for n in ADDON_USERS:
        assert ses(r[n], sid)["state"] == "open", n
    # it neither votes nor awards: a forged vote and a forged award are ignored
    assert P.eval("return ns.Roll:CanVote(...)", sid) is False and P.eval("return ns.Roll:CanAward(...)", sid) is False
    P.eval("ns.Comm:Send({ t = 'RV', id = ..., k = select(2, ...) }, 'RAID', nil, 'alert')", sid, key("Dave"))
    w.tick(1)
    assert all(x.get("votes", 0) == 0 for x in A.eval_py(
        "local out = {} for i, x in ipairs(ns.Roll:GetResults(...)) do out[i] = { votes = x.votes } end return out",
        sid) or []), "a pug's vote was counted"
    P.eval("ns.Roll:End(...)", sid)                 # (it started the roll: it may end it)
    w.tick(1)
    for n in ADDON_USERS:
        assert ses(r[n], sid)["state"] == "closed", n
    P.eval("ns.Comm:Send({ t = 'RW', id = ..., w = select(2, ...), at = GetServerTime() }, 'RAID', nil, 'alert')",
           sid, key("Pete"))
    w.tick(1)
    for n in ADDON_USERS:
        assert ses(r[n], sid)["state"] == "closed", (n, ses(r[n], sid))
    w.assert_no_errors()


@R.case
def plain_raid_master_looter_ends_and_awards_for_everyone():
    r = Raid(ml="Frank")
    w = r.w
    set_features(r, loot=False, rolls=True)
    A, B, F = r["Alice"], r["Bob"], r["Frank"]
    assert F.eval("return ns.Guild:AmICouncil(true)") is False
    F.open_loot([(RUBY_DRAPE, 4), (MINDBLADE, 4)])
    w.tick(2)
    # the master looter's panel opens by itself (it may start rolls)
    assert any(b["item"] == RUBY_DRAPE for b in panel_blocks(F)), panel_blocks(F)
    # a council member starts the roll; the master looter ends it: closed on every client, not only on his own
    B.eval("ns.DropPanel:StartRoll(...)", RUBY_DRAPE, 1)
    w.tick(1)
    sid = active_session(B)["id"]
    for n in ADDON_USERS:
        assert ses(r[n], sid)["plain"] is True, n
    click_roll(r, "Dave", 80)
    click_roll(r, "Carol", 30)
    w.tick(1)
    assert F.eval("return ns.Roll:CanEnd(...)", sid) is True
    assert F.eval("return ns.Roll:End(...)", sid) is True
    w.tick(1)
    assert all(v == "closed" for v in states(r, sid).values()), states(r, sid)
    # ... and awards the highest roll: the council records it
    F.close_loot()
    w.tick(0.5)
    assert F.eval("return ns.Roll:CanAward(...)", sid) is True
    F.eval("ns.Roll:Award(...)", sid, key("Dave"))
    w.tick(0.2)
    F.accept_popup("DISASTERZONE_CONFIRM_AWARD")
    w.tick(2)
    for n in ADDON_USERS:
        s = ses(r[n], sid)
        assert s["state"] == "awarded" and s["winner"] == key("Dave"), (n, s)
    for n in ("Alice", "Bob"):
        vis = [(e["w"], e["i"], e["by"]) for e in ledger_with_reason(r[n]) if e["i"] == RUBY_DRAPE]
        assert vis == [(key("Dave"), RUBY_DRAPE, key("Frank"))], (n, vis)
    # an award of an open roll ends it for everyone first (RE from the master looter)
    B.eval("ns.DropPanel:StartRoll(...)", MINDBLADE, 1)
    w.tick(1)
    sid2 = active_session(B)["id"]
    click_roll(r, "Erin", 55)
    w.tick(1)
    log0 = len(w.addon_log)
    F.eval("ns.Roll:Award(...)", sid2, key("Erin"))
    w.tick(0.5)
    re = [m for m in msgs_of_type(w, "RE", log0) if m["_sender"] == key("Frank")]
    assert re, "the master looter's award did not end the roll for the raid"
    for n in ADDON_USERS:
        assert ses(r[n], sid2)["state"] == "closed", (n, ses(r[n], sid2))
    F.accept_popup("DISASTERZONE_CONFIRM_AWARD")
    w.tick(2)
    for n in ADDON_USERS:
        assert ses(r[n], sid2)["winner"] == key("Erin"), n
    w.assert_no_errors()


@R.case
def plain_flag_comes_from_the_starter():
    """A council member that reloads does not know the raid's rules for a moment (no loot council in its eyes):
    the starter's pl decides, so a loot council roll stays one there (votes, tiers)."""
    r = Raid()
    w = r.w
    A, B = r["Alice"], r["Bob"]
    A.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    B.relog()
    w.tick(0.6)
    assert B.eval("return ns.Roll:IsPlainRaid()") is True        # (its own guess right after the reload)
    log0 = len(w.addon_log)
    A.eval("ns.DropPanel:StartRoll(...)", RUBY_DRAPE, 1)
    w.tick(1)
    sid = active_session(A)["id"]
    rs = [m for m in msgs_of_type(w, "RS", log0) if m["id"] == sid]
    assert rs and rs[0].get("pl") == 0, rs
    assert ses(B, sid).get("plain") is None, ses(B, sid)
    w.tick(8)
    assert B.eval("return ns.Roll:CanVote(...)", sid) is True
    # a plain roll says so: pl = 1, plain everywhere
    set_features(r, loot=False, rolls=True)
    A.eval("ns.Roll:End(...)", sid)
    w.tick(3)
    log0 = len(w.addon_log)
    A.eval("ns.DropPanel:StartRoll(...)", RUBY_DRAPE, 1)
    w.tick(1)
    sid2 = active_session(A)["id"]
    rs = [m for m in msgs_of_type(w, "RS", log0) if m["id"] == sid2]
    assert rs and rs[0].get("pl") == 1, rs
    for n in ADDON_USERS:
        assert ses(r[n], sid2)["plain"] is True, n
    w.assert_no_errors()


def de_target(r, name):
    A = r["Alice"]
    members = A.eval_py("local g = ns.Guild:GetGuildCouncil() local out = {} for k in pairs(g.members) do "
                        "out[#out+1] = k end return out")
    assert A.eval("return ns.Guild:SetGuildCouncil(...)", members, None, {"de": key(name), "bank": False})
    r.w.tick(2)


@R.case
def non_council_master_looter_de_is_recorded_with_its_reason():
    r = Raid(ml="Carol")
    w = r.w
    set_features(r, loot=False, rolls=True)          # Carol: master looter, not council (the loot council is off)
    de_target(r, "Erin")
    C = r["Carol"]
    assert C.eval("return ns.Guild:AmICouncil(true)") is False
    assert C.eval("return (ns.Guild:GetLootTarget('de'))") == key("Erin")
    C.open_loot([(RUBY_DRAPE, 4)])
    w.tick(2)
    state = C.eval(r"""
        ns.DropPanel:Render()
        for _, b in ipairs(ns.DropPanel.blocks) do
          if b:IsShown() and b.itemID == ... then
            for _, e in ipairs(ns.DropPanel:GetMoreActions(b)) do if e.key == "de" then return e.enabled end end
            return false
          end
        end""", RUBY_DRAPE)
    assert state is True, "no DE button for the master looter"
    log0 = len(w.addon_log)
    C.eval(r"""
        for _, b in ipairs(ns.DropPanel.blocks) do
          if b:IsShown() and b.itemID == ... then ns.DropPanel:RunMoreAction(b, "de") return end
        end""", RUBY_DRAPE)
    w.tick(0.2)
    assert C.popups() == ["DISASTERZONE_CONFIRM_GIVE_TARGET"], C.popups()
    C.accept_popup("DISASTERZONE_CONFIRM_GIVE_TARGET")
    w.tick(3)
    lt = msgs_of_type(w, "LT", log0)
    assert len(lt) == 1 and lt[0]["_sender"] == key("Carol") and lt[0]["r"] == "de", lt
    assert not any("Only Loot Council members can record" in l for l in printed_lines(C))
    ids = set()
    for n in ("Alice", "Bob"):
        vis = [e for e in ledger_with_reason(r[n]) if e["i"] == RUBY_DRAPE]
        assert len(vis) == 1 and vis[0]["w"] == key("Erin") and vis[0]["r"] == "de" and vis[0]["s"] == "m", (n, vis)
        assert vis[0]["by"] == key("Carol"), vis
        ids.add(vis[0]["id"])
        assert r[n].eval("return ns.Ledger:CountSince(..., 0)", key("Erin")) == 0, n   # not loot won
    assert len(ids) == 1, "every council client records the same entry: %r" % ids
    # an LT from somebody else, or naming someone who is not the disenchanter, is ignored
    for sender, who in (("Dave", "Erin"), ("Carol", "Dave")):
        r[sender].eval("ns.Comm:Send({ t = 'LT', i = 28770, w = ..., r = 'de', b = '', at = GetServerTime() }, "
                       "'RAID', nil, 'alert')", key(who))
    w.tick(1)
    for n in ("Alice", "Bob"):
        assert [e for e in ledger_with_reason(r[n]) if e["i"] == MINDBLADE] == [], n
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

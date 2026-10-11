#!/usr/bin/env python
"""Prized items (Core/Prized.lua, Raids > Loot rules, 1.3.5): stricter loot rules for a few very important drops.

Covers: the GM / guild council add and change the rules, every member gets them (also after being offline, from
whoever is online), nobody else can (a forged record is dropped), a change reaches the guild's notifications; in a raid:
the roll rows say who breaks a rule (never suggested), the council decides (no roll suggestion), an award needs the
item's agree count of the council members in the raid, an award against a rule asks why and records it for the whole
guild; the raider's pop-up blocks Roll for a player who breaks a rule; the cooldown rule reads the hand-outs; a voided
loot log award leaves the history.

Run: luaenv\\Scripts\\python.exe tests\\prized\\test_prized.py [-k substring]   (from dev)
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "loot-roll"))

from lr_common import *  # noqa: F401,F403,E402
from test_rolls import setup, click_roll  # noqa: E402

R = Runner("prized items / loot rules (1.3.5)")
HELLO = 50
DST = 28830


def add(c, ids, rules):
    return c.eval("""
        local ids, rules = ...
        local rec = ns.Prized:Add(ids, rules)
        return rec and rec.id or false""", ids, rules)


def rules_of(c, item):
    return c.eval_py("local rec = ns.Prized:ForItem(...) return rec and rec.r or false", item)


def check(c, item, name):
    return c.eval_py("""
        local item, k = ...
        local rec = ns.Prized:ForItem(item)
        if not rec then return false end
        local res = ns.Prized:Check(rec, k)
        return { ok = res.ok == nil and "unknown" or res.ok, fail = res.failKey }""", item, key(name))


def given(c, item):
    return c.eval_py("""
        local out = {}
        for i, g in ipairs(ns.Prized:GetGiven({ item = ... })) do
          out[i] = { to = g.to, ov = g.ov, why = g.why, ag = g.ag, of = g.of }
        end
        return out""", item) or []


def guild_world():
    w = World()
    roster = [("Alice", "PALADIN", 0), ("Bob", "MAGE", 1), ("Carol", "WARRIOR", 3), ("Dave", "PRIEST", 3)]
    c = {}
    for name, cls, rank in roster:
        c[name] = Client(w, name, class_file=cls, guild_rank=rank)
    for cl in c.values():
        cl.load_addon()
    w.tick(2)
    setup_council(w, c, roster)
    w.tick(HELLO)
    return w, c


@R.case
def gm_adds_rules_and_every_member_gets_them():
    w, c = guild_world()
    rid = add(c["Alice"], [DST], {"att": {"m": "r", "p": 75, "w": 6}, "rank": {"m": "r", "i": 2},
                                  "cd": {"m": "r", "w": 4}, "vote": {"s": "all"}})
    assert rid == str(DST), rid
    w.tick(3)
    for n in ("Bob", "Carol", "Dave"):
        r = rules_of(c[n], DST)
        assert r and r["rank"]["i"] == 2 and r["att"]["p"] == 75 and r["vote"]["s"] == "all", (n, r)
    # the rank rule: Carol (rank 3) breaks it, Bob (rank 1) doesn't
    assert check(c["Dave"], DST, "Carol")["fail"] == "rank"
    assert check(c["Dave"], DST, "Bob").get("fail") in (None, "att"), check(c["Dave"], DST, "Bob")
    w.assert_no_errors()


@R.case
def only_gm_and_guild_council_set_rules_and_a_forged_record_is_dropped():
    w, c = guild_world()
    assert add(c["Carol"], [DST], {"main": {"m": "r"}}) is False
    # Carol forges an item record in her own name on the guild channel
    c["Carol"].eval("""
        ns.Comm:Send({ t = "PZU", k = "I", r = { id = "28830", ids = { 28830 }, r = { main = { m = "r" } },
                       by = ns.Util.PlayerKey(), rev = GetServerTime() } }, "GUILD", nil, "data")""")
    w.tick(3)
    for n in ("Alice", "Bob", "Dave"):
        assert rules_of(c[n], DST) is False, n
    # the guild council (Bob) can
    assert add(c["Bob"], [DST], {"main": {"m": "r"}}) == str(DST)
    w.tick(3)
    assert rules_of(c["Dave"], DST)["main"]["m"] == "r"
    w.assert_no_errors()


@R.case
def a_member_offline_catches_up_and_gets_a_notification_of_changes():
    w, c = guild_world()
    add(c["Alice"], [DST], {"rank": {"m": "r", "i": 2}})
    w.tick(3)
    c["Dave"].logout()
    w.tick(2)
    assert c["Alice"].eval("return ns.Prized:Save('28830', { rank = { m = 'r', i = 1 }, main = { m = 'p' } })") is True
    w.tick(3)
    # Carol was online: the rules and a notification of what changed
    assert rules_of(c["Carol"], DST)["rank"]["i"] == 1
    notes = c["Carol"].eval_py("""
        local out = {}
        for i, it in ipairs(ns.Notify:List({ kind = "lootRules" })) do out[i] = it.text end
        return out""") or []
    # (newest first: the change, then the new item itself)
    assert len(notes) == 2 and "rank" in notes[0].lower() and "added mains only" in notes[0].lower(), notes
    assert notes[1] == "Made a prized item", notes
    # Dave comes back: the HELLO digest brings the new rules and the history
    c["Dave"].login()
    w.tick(HELLO + 20)
    r = rules_of(c["Dave"], DST)
    assert r and r["rank"]["i"] == 1 and r["main"]["m"] == "p", r
    hist = c["Dave"].eval_py("""
        local out = {}
        for i, e in ipairs(ns.Prized:GetHistory("28830")) do out[i] = e.kind .. ":" .. (e.rec.t or "") end
        return out""")
    assert len(hist) == 2 and any("Made a prized item" in h for h in hist), hist
    w.assert_no_errors()


@R.case
def the_queue_the_pair_and_the_spec_order():
    w, c = guild_world()
    A = c["Alice"]
    # two cloaks sharing rules: a queue (Carol, then Bob) and the pair rule
    assert add(A, [RUBY_DRAPE, FARSTRIDER], {"queue": {"m": "r", "n": [key("Carol"), key("Bob")]},
                                              "pair": {"m": "r"}}) == str(RUBY_DRAPE)
    w.tick(3)
    assert check(c["Dave"], FARSTRIDER, "Carol")["ok"] is True
    assert check(c["Dave"], FARSTRIDER, "Bob")["fail"] == "queue"
    # Carol gets the first one: the second follows it (Bob still waits)
    assert A.eval("return ns.Prized:RecordGiven(...)", RUBY_DRAPE, key("Carol"), {})
    w.tick(3)
    assert check(c["Dave"], FARSTRIDER, "Carol")["ok"] is True
    assert check(c["Dave"], FARSTRIDER, "Bob")["fail"] in ("queue", "pair")
    # both hers: Bob is next
    assert A.eval("return ns.Prized:RecordGiven(...)", FARSTRIDER, key("Carol"), {})
    w.tick(3)
    assert check(c["Dave"], RUBY_DRAPE, "Bob")["ok"] is True, check(c["Dave"], RUBY_DRAPE, "Bob")
    # a required spec order: only mages and Holy priests
    assert add(A, [DST], {"order": {"m": "r", "g": [["MAGE", "PRIEST:Holy"]]}}) == str(DST)
    w.tick(3)
    assert check(c["Dave"], DST, "Carol")["fail"] == "order"          # a warrior
    assert check(c["Dave"], DST, "Bob")["ok"] is True                 # a mage
    w.assert_no_errors()


# ---------------------------------------------------------------------------------------------------------------
# In a raid (lr_common's raid: Alice GM / ML / raid leader, Bob council; Bob BiS main and Dave alt on the drape)
# ---------------------------------------------------------------------------------------------------------------
def prized_raid(rules):
    r = setup()
    assert add(r["Alice"], [RUBY_DRAPE], rules) == str(RUBY_DRAPE)
    r.w.tick(3)
    return r


def start(r, item=RUBY_DRAPE):
    r["Alice"].eval("ns.DropPanel:StartRoll(...)", item, 1)
    r.w.tick(1)
    return active_session(r["Alice"])["id"]


def rows(c, sid):
    return c.eval_py("""
        local out = {}
        for i, r in ipairs(ns.Roll:GetResults(...)) do
          out[i] = { key = r.key, ok = r.prz and (r.prz.ok == nil and "unknown" or r.prz.ok), fail = r.prz and r.prz.failKey,
                     suggested = r.suggested, votes = r.votes }
        end
        return out""", sid) or []


def vote(c, sid, name):
    return c.eval("return ns.Roll:Vote(...)", sid, key(name))


RANK_VOTE = {"rank": {"m": "r", "i": 2}, "vote": {"s": "all"}}


@R.case
def roll_rows_flag_who_breaks_a_rule_and_the_council_decides():
    r = prized_raid(RANK_VOTE)
    sid = start(r)
    click_roll(r, "Bob", 20)
    # Dave (rank 3) can't get it: no roll window for him (1.3.5, the GM's default), a notice says why
    assert not r["Dave"].eval("return ns.RollFrame.frame ~= nil and ns.RollFrame.frame:IsShown() or false")
    assert r["Dave"].eval("return #ns.Notify:List({ kind = 'lootNotEligible' })") == 1
    # (Carol, rank 3, neither; Bob qualifies: the council decides, so his button says "I want it")
    assert r["Carol"].eval("return #ns.Notify:List({ kind = 'lootNotEligible' })") == 1
    assert r["Bob"].eval("return ns.RollFrame.frame.roll:GetText()") == "I want it"
    r.w.tick(1)
    res = {x["key"]: x for x in rows(r["Alice"], sid)}
    assert res[key("Bob")]["ok"] is not False, res
    # no votes yet: the council decides, so no roll is suggested
    assert not any(x["suggested"] for x in res.values()), res
    vote(r["Alice"], sid, "Bob")
    vote(r["Bob"], sid, "Bob")
    r.w.tick(1)
    top = [x for x in rows(r["Alice"], sid) if x["suggested"]]
    assert len(top) == 1 and top[0]["key"] == key("Bob"), top
    r.w.assert_no_errors()


@R.case
def an_award_needs_every_council_member_here_and_goes_to_the_whole_guild():
    r = prized_raid(RANK_VOTE)
    sid = start(r)
    click_roll(r, "Bob", 20)
    r.w.tick(1)
    r["Alice"].eval("ns.Roll:End(...)", sid)
    r.w.tick(1)
    # one vote of two council members in the raid: refused, nothing recorded
    vote(r["Alice"], sid, "Bob")
    r.w.tick(1)
    r["Alice"].eval("ns.Roll:Award(...)", sid, key("Bob"))
    r.w.tick(0.3)
    assert r["Alice"].popups() == [], r["Alice"].popups()
    assert given(r["Alice"], RUBY_DRAPE) == []
    vote(r["Bob"], sid, "Bob")
    r.w.tick(1)
    r["Alice"].eval("ns.Roll:Award(...)", sid, key("Bob"))
    r.w.tick(0.3)
    pops = r["Alice"].popups()
    assert pops, "no confirmation"
    r["Alice"].accept_popup(pops[0])
    r.w.tick(4)
    for n in ("Alice", "Carol", "Erin"):
        g = given(r[n], RUBY_DRAPE)
        assert len(g) == 1 and g[0]["to"] == key("Bob") and g[0]["ag"] == 2 and g[0]["of"] == 2 and not g[0].get("ov"), (n, g)
    r.w.assert_no_errors()


@R.case
def an_award_against_a_rule_asks_why_and_everyone_sees_it():
    r = prized_raid(RANK_VOTE)
    sid = start(r)
    r.w.tick(1)
    r["Alice"].eval("ns.Roll:End(...)", sid)
    r.w.tick(1)
    vote(r["Alice"], sid, "Dave")
    vote(r["Bob"], sid, "Dave")
    r.w.tick(1)
    res = {x["key"]: x for x in rows(r["Alice"], sid)}
    assert res[key("Dave")]["ok"] is False and res[key("Dave")]["fail"] == "rank", res
    assert not res[key("Dave")]["suggested"], res          # votes never suggest a player who breaks a rule
    r["Alice"].eval("ns.Roll:Award(...)", sid, key("Dave"))
    r.w.tick(0.3)
    assert "DISASTERZONE_PRIZED_OVERRIDE" in r["Alice"].popups(), r["Alice"].popups()
    # no reason: nothing happens (asked again)
    r["Alice"].accept_popup("DISASTERZONE_PRIZED_OVERRIDE", "")
    r.w.tick(0.3)
    assert given(r["Alice"], RUBY_DRAPE) == []
    r["Alice"].accept_popup("DISASTERZONE_PRIZED_OVERRIDE", "Our only healer without a cloak upgrade")
    r.w.tick(0.3)
    pops = [p for p in r["Alice"].popups() if p != "DISASTERZONE_PRIZED_OVERRIDE"]
    assert pops, r["Alice"].popups()
    r["Alice"].accept_popup(pops[0])
    r.w.tick(4)
    for n in ("Alice", "Carol"):
        g = given(r[n], RUBY_DRAPE)
        assert len(g) == 1 and g[0]["to"] == key("Dave") and g[0]["ov"] == ["rank"], (n, g)
        assert g[0]["why"] == "Our only healer without a cloak upgrade", g
    log = r["Alice"].eval_py("local e = ns.Ledger:GetEntries()[1] return e and e.n")
    assert log and log.startswith("override: Our only"), log
    r.w.assert_no_errors()


@R.case
def the_cooldown_rule_reads_the_hand_outs_and_a_void_lifts_it():
    r = prized_raid({"vote": {"s": "half"}})
    sid = start(r)
    click_roll(r, "Bob", 50)
    r.w.tick(1)
    r["Alice"].eval("ns.Roll:End(...)", sid)
    vote(r["Alice"], sid, "Bob")
    vote(r["Bob"], sid, "Bob")
    r.w.tick(1)
    r["Alice"].eval("ns.Roll:Award(...)", sid, key("Bob"))
    r.w.tick(0.3)
    r["Alice"].accept_popup(r["Alice"].popups()[0])
    r.w.tick(3)
    assert add(r["Alice"], [JADE_RING], {"cd": {"m": "r", "w": 4}}) == str(JADE_RING)
    r.w.tick(3)
    for n in ("Alice", "Bob", "Carol"):
        assert check(r[n], JADE_RING, "Bob")["fail"] == "cd", n
        assert check(r[n], JADE_RING, "Carol")["ok"] is True, n
    # the loot log award is voided: the hand-out leaves the history, the cooldown with it
    eid = r["Alice"].eval("return ns.Ledger:GetEntries()[1].id")
    assert r["Alice"].eval("return ns.Ledger:Void(..., true)", eid)
    r.w.tick(3)
    for n in ("Alice", "Carol"):
        assert given(r[n], RUBY_DRAPE) == [], n
        assert check(r[n], JADE_RING, "Bob")["ok"] is True, n
    r.w.assert_no_errors()


@R.case
def awards_outside_a_roll_are_refused_for_prized_items():
    r = prized_raid(RANK_VOTE)
    ok, why = r["Alice"].eval_py("return { ns.DropPanel:Award(...) }", RUBY_DRAPE, key("Bob"), "Karazhan:Prince", 1, False)
    assert ok is False and "roll" in why, (ok, why)
    assert r["Alice"].eval("return #ns.Ledger:GetEntries()") == 0
    # disenchant / guild bank aren't loot for a player: no rules
    ok2 = r["Alice"].eval("return (ns.DropPanel:Award(...))", RUBY_DRAPE, key("Bob"), "Karazhan:Prince", 1, False, None, "de")
    assert ok2 is True
    r.w.assert_no_errors()


if __name__ == "__main__":
    main(R)

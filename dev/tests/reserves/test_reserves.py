"""Loot reserves (1.4.3): the list, its rules, the sync, whispers and how rolls are decided."""
from rv_common import *  # noqa: F403

R = Runner("reserves / list, rules, rolls")


def setup(n=1, held=None, loot=True):
    r = reserve_raid()
    open_reserves(r, n=n, held=held)
    if loot:
        r["Alice"].open_loot([(RUBY_DRAPE, 4), (THOUSAND_MARKS, 4), (HELM_CHAMPION, 4), (MINDBLADE, 4)])
        r.w.tick(2)
    return r


@R.case
def the_session_runs_reserves_and_every_client_knows():
    r = reserve_raid()
    for n in ("Alice", "Bob", "Carol", "Gina"):
        assert r[n].eval("return ns.Reserves:IsLootMethod()"), n
        f = r[n].eval_py("return ns.GroupRules:GetSessionFeatures()")
        assert f["reserve"] and f["loot"] and f["rolls"] and not f["lock"], (n, f)
    # the wire keeps the letters older clients accept (rf without "v") and says reserves apart (rv = 1)
    log0 = len(r.w.addon_log)
    r["Alice"].eval("ns.GroupRules:SetSessionFeatures({ loot = true, rolls = true, reserve = true })")
    r.w.tick(6)
    gs = [m for m in msgs_of_type(r.w, "GS", log0)]
    assert gs and gs[-1]["rf"] == "lr" and gs[-1]["rv"] == 1, gs[-1:]
    set_reserve_features(r, on=False)
    assert not r["Carol"].eval("return ns.Reserves:IsLootMethod()")
    r.w.assert_no_errors()


@R.case
def opening_reaches_the_raid_and_raiders_reserve_through_the_host():
    r = setup(n=2, held=[HELM_CHAMPION])
    for n in ("Bob", "Carol", "Gina"):
        L = r[n].eval_py("local L = ns.Reserves:Get(); return L and { by = L.by, n = L.n, o = L.o, rk = L.rk, h = L.h }")
        assert L and L["by"] == key("Alice") and L["n"] == 2 and L["o"] and L["rk"] == "Karazhan", (n, L)
        assert L["h"] == [HELM_CHAMPION], L
    ok = r["Carol"].eval_py("local ok, c = ns.Reserves:Reserve(...); return { ok, c }", RUBY_DRAPE)
    assert ok == [True, "asked"], ok
    r.w.tick(2)
    for n in ("Alice", "Bob", "Carol"):
        assert reserves_of(r[n], "Carol") == [RUBY_DRAPE], (n, reserves_of(r[n], "Carol"))
        assert r[n].eval_py("return ns.Reserves:SourceOf(...)", key("Carol"), RUBY_DRAPE) == "d"
    # the host's rules: held items, the raid's loot, duplicates, the limit
    for item, code in ((HELM_CHAMPION, "held"), (28477, "ok"), (28477, "dupe"), (19019, "notloot"),
                       (MINDBLADE, "ok"), (RUBY_DRAPE, "full")):
        res = r["Alice"].eval_py("local ok, c = ns.Reserves:AddFor(...); return c", key("Dave"), item, "h")
        assert res == code, (item, res)
    r["Alice"].eval_py("return ns.Reserves:CancelFor(...)", key("Dave"), MINDBLADE)
    r["Alice"].eval_py("return ns.Reserves:AddFor(...)", key("Dave"), RUBY_DRAPE, "h")
    r.w.tick(2)
    assert reservers(r["Gina"], RUBY_DRAPE) == [key("Carol"), key("Dave")]
    assert reserves_of(r["Gina"], "Dave") == [28477, RUBY_DRAPE]
    r.w.assert_no_errors()


@R.case
def whispers_reserve_list_cancel_and_explain():
    r = setup(n=1, held=[HELM_CHAMPION])
    w = r.w
    c0 = len(w.chat_log)
    whisper(r, "Yuri", "!sr [Ruby Drape of the Mysticant]")
    whisper(r, "Zed", "res thousand marks")                  # LootReserve's word, a name, no "!" in a whisper
    whisper(r, "Frank", "!sr 28757")                          # an item id
    w.tick(2)
    assert reserves_of(r["Alice"], "Yuri") == [RUBY_DRAPE], reserves_of(r["Alice"], "Yuri")
    assert reserves_of(r["Alice"], "Zed") == [THOUSAND_MARKS]
    assert reserves_of(r["Alice"], "Frank") == [THOUSAND_MARKS]
    assert r["Alice"].eval_py("return ns.Reserves:SourceOf(...)", key("Yuri"), RUBY_DRAPE) == "w"
    yuri = whispers_to(r, "Yuri", c0)
    assert yuri and yuri[0].startswith("[DZ] Reserved [Ruby Drape") and "Nobody else on it yet" in yuri[0], yuri
    frank = whispers_to(r, "Frank", c0)
    assert "1 other on it" in frank[0], frank
    # more than the limit, a held item, a list, a cancel, the rules
    whisper(r, "Yuri", "!sr Mindblade")
    whisper(r, "Zed", "!sr [Helm of the Fallen Champion]")
    whisper(r, "Yuri", "!sr list")
    whisper(r, "Yuri", "!sr cancel")
    whisper(r, "Yuri", "!sr rules")
    yuri = whispers_to(r, "Yuri", c0)
    assert any("You have no reserves left" in l for l in yuri), yuri
    assert any("held for the guild" in l for l in whispers_to(r, "Zed", c0)), whispers_to(r, "Zed", c0)
    assert any(l.startswith("[DZ] [Ruby Drape") for l in yuri), yuri
    assert any(l.startswith("[DZ] Took back [Ruby Drape") for l in yuri), yuri
    assert any("1 soft reserve each" in l for l in yuri) and any("Held for the guild" in l for l in yuri), yuri
    assert reserves_of(r["Alice"], "Yuri") == []
    # a name that fits several items asks which one
    whisper(r, "Yuri", "!sr ring")
    assert any(l.startswith("[DZ] Which one:") for l in whispers_to(r, "Yuri", c0)), whispers_to(r, "Yuri", c0)
    # not the host: Bob's client stays quiet
    c1 = len(w.chat_log)
    whisper(r, "Yuri", "!sr Mindblade", to="Bob")
    assert not [e for e in w.chat_log[c1:] if e["sender"] == key("Bob")]
    # every answer fits a chat line; the host's chat frame doesn't show the !sr whispers
    assert all(len(e["text"].encode()) <= 255 for e in w.chat_log[c0:])
    w.assert_no_errors()


@R.case
def the_first_pull_closes_reserves():
    r = setup(n=1, loot=False)
    whisper(r, "Yuri", "!sr Mindblade")
    c0 = len(r.w.chat_log)
    r.w.encounter(652, "Attumen the Huntsman")
    r.w.tick(2)
    for n in ("Alice", "Carol"):
        assert r[n].eval("return ns.Reserves:IsOpen()") is False, n
    assert any("Reserves are closed" in t for _, t in raid_lines(r, c0)), raid_lines(r, c0)
    whisper(r, "Yuri", "!sr cancel")
    assert any("Reserves are closed" in l for l in whispers_to(r, "Yuri", c0))
    assert reserves_of(r["Alice"], "Yuri") == [MINDBLADE]
    # the host can still change them
    assert r["Alice"].eval_py("local ok = ns.Reserves:CancelFor(...); return ok", key("Yuri"), MINDBLADE, True)
    r.w.tick(2)
    assert reserves_of(r["Carol"], "Yuri") == []
    r.w.assert_no_errors()


@R.case
def a_reserved_item_rolls_among_its_reservers_only():
    r = setup(n=1)
    w = r.w
    whisper(r, "Yuri", "!sr Ruby Drape")
    r["Bob"].eval("ns.Reserves:Reserve(...)", RUBY_DRAPE)
    w.tick(2)
    assert decide(r["Alice"], RUBY_DRAPE) == {"k": "s", "keys": [key("Bob"), key("Yuri")]}
    c0, log0 = len(w.chat_log), len(w.addon_log)
    s = start_roll(r, RUBY_DRAPE)
    RS = msgs_of_type(w, "RS", log0)
    assert RS and RS[0]["rv"] == "s" and RS[0]["rk"] == [key("Bob"), key("Yuri")] and RS[0]["pl"] == 1, RS
    for n in ("Alice", "Bob", "Carol"):
        assert roll_kind(r[n], s["id"]) == {"k": "s", "keys": [key("Bob"), key("Yuri")]}, n
    ann = [t for _, t in raid_lines(r, c0) if "reserved by" in t]
    assert ann and "Bob, Yuri" in ann[0] and "Only they /roll" in ann[0], raid_lines(r, c0)
    w.player_roll("Yuri", 40)
    w.player_roll("Carol", 99)        # didn't reserve it: listed, never suggested
    w.player_roll("Bob", 70)
    w.tick(1)
    for n in ("Alice", "Bob"):
        res = results_rv(r[n], s["id"])
        top = [x for x in res if x["suggested"]]
        assert top and top[0]["key"] == key("Bob"), (n, res)
        carol = [x for x in res if x["key"] == key("Carol")][0]
        assert carol["unres"] and not carol["suggested"], carol
        assert res[-1]["key"] == key("Carol"), res
    w.assert_no_errors()


@R.case
def one_reserver_gets_it_without_a_roll():
    r = setup(n=1)
    w = r.w
    r["Dave"].eval("ns.Reserves:Reserve(...)", THOUSAND_MARKS)
    w.tick(2)
    c0 = len(w.chat_log)
    s = start_roll(r, THOUSAND_MARKS)
    res = results_rv(r["Alice"], s["id"])
    assert res and res[0]["key"] == key("Dave") and res[0]["suggested"] and res[0]["by"] == "reserve", res
    assert any("goes to Dave: the only reserve" in t for _, t in raid_lines(r, c0)), raid_lines(r, c0)
    w.tick(6)          # the session only names Dave and closes by itself
    blk = [b for b in panel_blocks(r["Alice"]) if b["item"] == THOUSAND_MARKS][0]
    assert "Award to Dave" in blk["buttons"], blk
    w.assert_no_errors()


@R.case
def nobody_reserved_it_up_for_grabs():
    r = setup(n=1)
    w = r.w
    c0, log0 = len(w.chat_log), len(w.addon_log)
    s = start_roll(r, MINDBLADE)
    assert roll_kind(r["Carol"], s["id"])["k"] == "o"
    assert msgs_of_type(w, "RS", log0)[0]["pl"] == 1
    assert any("up for grabs" in t for _, t in raid_lines(r, c0)), raid_lines(r, c0)
    w.player_roll("Yuri", 81)
    w.player_roll("Carol", 30)
    w.tick(1)
    res = results_rv(r["Alice"], s["id"])
    assert res[0]["key"] == key("Yuri") and res[0]["suggested"], res
    w.assert_no_errors()


@R.case
def a_guild_item_is_the_councils_among_guild_members_then_up_for_grabs():
    r = setup(n=1, held=[RUBY_DRAPE])
    w = r.w
    log0 = len(w.addon_log)
    s = start_roll(r, RUBY_DRAPE)
    RS = msgs_of_type(w, "RS", log0)
    assert RS[0]["rv"] == "g" and RS[0]["pl"] == 0, RS
    w.player_roll("Yuri", 100)          # a pug: listed, never suggested, votes for them don't count
    w.player_roll("Carol", 20)
    w.tick(1)
    r["Alice"].eval("ns.Roll:Vote(...)", s["id"], key("Yuri"))
    w.tick(1)
    res = results_rv(r["Alice"], s["id"])
    yuri = [x for x in res if x["key"] == key("Yuri")][0]
    assert yuri["notGuild"] and not yuri["suggested"], res
    assert [x for x in res if x["suggested"]][0]["key"] != key("Yuri"), res
    # nobody from the guild wants it: the council opens it to everyone
    r["Alice"].eval("ns.Roll:End(...)", s["id"])
    w.tick(3)
    log1 = len(w.addon_log)
    r["Alice"].eval("ns.Roll:StartUpForGrabs(...)", RUBY_DRAPE, r["Alice"].eval_py("return ns.Loot:GetHistory()")[-1], 1)
    w.tick(4)
    RS = msgs_of_type(w, "RS", log1)
    assert RS and RS[-1]["rv"] == "o", RS
    w.assert_no_errors()


@R.case
def reserves_survive_the_hosts_reload_and_a_new_leader_takes_them_over():
    r = setup(n=1, loot=False)
    w = r.w
    whisper(r, "Yuri", "!sr Mindblade")
    r["Carol"].eval("ns.Reserves:Reserve(...)", RUBY_DRAPE)
    w.tick(2)
    r["Alice"].relog()
    w.tick(10)
    assert reserves_of(r["Alice"], "Yuri") == [MINDBLADE], reserves_of(r["Alice"], "Yuri")
    # a client that reloads asks and gets the list again
    r["Gina"].relog()
    w.tick(10)
    assert reserves_of(r["Gina"], "Carol") == [RUBY_DRAPE], reserves_of(r["Gina"], "Carol")
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

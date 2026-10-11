"""ADDENDUM I §48-§49: raid sessions (GS rs / rsAt) and the raid log recording, on the real addon.

Covers: the raid leader starting / ending a session (same id everywhere, BiS lock on / off, one record per client,
endedBy), non-authority raiders refused (slash and forged GS), attendance by group membership (a wipe with ghosts
outside still gives boss credit), a long trash clear never ending the session, the session following the group when
the leader leaves (the new authority adopts it and its lock), the disband safety net (autoEnded, stop = last
activity), the missed-pull reminder and backdated start, mid-raid joiners and /reloads (raider and leader) resuming
the same record, offline-at-kill marks, awards carrying rid (and a peer's rid filling a missing one), and pruning.

Run: luaenv\\Scripts\\python.exe tests\\raidlog\\test_raidlog.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(TESTS, "loot-roll"))

from _common import case, run_all, World, Client, printed_since, strip_codes, gm_pick  # noqa: E402
import lr_common as lr  # noqa: E402

REALM = "Thunderstrike"


def K(name):
    return "%s-%s" % (name, REALM)


def world(names=(("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Bob", 1, "MAGE"), ("Rita", 3, "PRIEST"),
                 ("Sam", 3, "ROGUE")), council=("Bob",)):
    """Gina = GM, Bob = guild council, Lee = raid leader, Rita / Sam = raiders."""
    w = World()
    w.auto_session = False      # this suite starts and ends the raid sessions itself
    c = {}
    for name, rank, cls in names:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], list(council))
    return w, c


def raid(w, c, members=("Lee", "Bob", "Rita", "Sam", "Gina"), leader="Lee", tick=8):
    w.make_raid([c[n] for n in members], leader=c[leader])
    w.tick(tick)


def session(cl):
    return cl.eval_py("return ns.GroupRules:GetSession()")


def current(cl):
    return cl.eval("return ns.RaidLog:GetCurrentID()")


def rec(cl, rid):
    return cl.eval_py("return ns.RaidLog:GetRaid(...)", rid)


def said(cl, n0, needle):
    return [strip_codes(l) for l in printed_since(cl, n0) if needle in strip_codes(l)]


def start(w, c, who="Lee", tick=2):
    c[who].slash("/dz raid start")
    w.tick(tick)
    s = session(c[who])
    assert s, "no session after /dz raid start"
    # every raider's client has learned the session (a real pull is never seconds after Start)
    members = [m for m in w.group_members() if isinstance(m, Client) and m.runtime is not None]
    w.run_until(lambda: all(current(x) == s["id"] for x in members), timeout=20)
    return s["id"]


# ------------------------------------------------------------------------------------------------------------------
@case
def leader_starts_and_ends_everyone_records_the_same_session():
    w, c = world()
    lee = c["Lee"]
    raid(w, c)
    mark = len(w.addon_log)
    n0 = {n: len(x.chat_frame) for n, x in c.items()}
    rid = start(w, c)
    assert rid.startswith(K("Lee") + "-"), rid
    gs = [m for m in lr.msgs_of_type(w, "GS", mark) if m["_sender"] == K("Lee")]
    assert gs and gs[-1].get("rs") == rid and isinstance(gs[-1].get("rsAt"), int), gs
    for n, x in c.items():
        assert session(x)["id"] == rid, n
        assert x.eval("return ns.GroupRules:IsLocked()") is True, n
        assert current(x) == rid, n
        r = rec(x, rid)
        assert r["start"] == gs[-1]["rsAt"] and r["by"] == K("Lee"), (n, r)
        assert set(r["att"]) == {K(m) for m in c}, (n, r["att"])
        assert said(x, n0[n], "raid session started"), (n, printed_since(x, n0[n]))
    # starting twice only says so
    n1 = len(lee.chat_frame)
    lee.slash("/dz raid start")
    assert said(lee, n1, "already running")
    w.tick(30)
    lee.slash("/dz raid end")
    w.tick(2)
    for n, x in c.items():
        assert session(x) is None and current(x) is None, n
        assert x.eval("return ns.GroupRules:IsLocked()") is False, n
        r = rec(x, rid)
        assert r["stop"] and r["endedBy"] == K("Lee") and not r.get("autoEnded"), (n, r)
        assert all(a["l"] == r["stop"] or a["l"] <= r["stop"] for a in r["att"].values()), r["att"]
    w.assert_no_errors()


@case
def only_the_authority_can_start_and_forged_sessions_are_ignored():
    w, c = world()
    rita, sam = c["Rita"], c["Sam"]
    raid(w, c)
    n0 = len(rita.chat_frame)
    rita.slash("/dz raid start")
    w.tick(2)
    assert said(rita, n0, "only the raid leader"), printed_since(rita, n0)
    assert all(session(x) is None for x in c.values())
    # a modified client sends its own GS with a session: nobody accepts it
    rita.eval("ns.Comm:Send({ t = 'GS', v = 99, rd = 30, q = 4, dq = 3, rs = 'x-1', rsAt = 1 }, 'RAID', nil, 'alert')")
    w.tick(2)
    assert session(sam) is None and current(sam) is None
    # a malformed rs from the real authority is dropped, the rules still apply
    c["Lee"].eval("ns.Comm:Send({ t = 'GS', v = 99, rd = 30, q = 4, dq = 3, rs = 'bad|id', rsAt = 5 }, 'RAID', nil, 'alert')")
    w.tick(2)
    assert session(sam) is None
    w.assert_no_errors()


@case
def wipe_with_ghosts_outside_still_gets_boss_credit():
    w, c = world()
    raid(w, c)
    w.enter_instance("Karazhan", 532)
    w.tick(2)
    rid = start(w, c)
    # a wipe: Rita and Sam release and stay outside; the rest kill the boss
    w.leave_instance(clients=[c["Rita"], c["Sam"]])
    w.tick(120, step=1)
    inside = [c["Lee"], c["Bob"], c["Gina"]]
    w.encounter(652, "Attumen the Huntsman", clients=inside)
    w.tick(2)
    for x in inside:
        r = rec(x, rid)
        assert r["zone"] == "Karazhan" and r["instID"] == 532, r
        assert len(r["bosses"]) == 1 and r["bosses"][0]["enc"] == 652, r["bosses"]
        assert set(r["bosses"][0]["roster"]) == {K(m) for m in c}, r["bosses"][0]
        assert all(a["k"] == 1 for a in r["att"].values()), r["att"]
        assert all("l" not in a for a in r["att"].values()), r["att"]
    # the same kill seen twice is recorded once
    w.encounter(652, "Attumen the Huntsman", clients=inside)
    w.tick(1)
    assert len(rec(c["Lee"], rid)["bosses"]) == 1
    assert current(c["Rita"]) == rid
    w.assert_no_errors()


@case
def a_long_trash_clear_never_ends_the_session():
    w, c = world()
    raid(w, c)
    w.enter_instance()
    rid = start(w, c)
    w.tick(2.5 * 3600, step=5)
    for n, x in c.items():
        assert current(x) == rid, n
        assert rec(x, rid).get("stop") is None, n
    w.assert_no_errors()


@case
def leader_leaves_the_new_authority_adopts_the_session_and_lock():
    w, c = world()
    lee, bob, rita = c["Lee"], c["Bob"], c["Rita"]
    raid(w, c)
    rid = start(w, c)
    lee.eval("ns.RaidLog.__t = GetServerTime()")
    raid(w, c, members=("Bob", "Rita", "Sam", "Gina"), leader="Bob", tick=12)
    assert bob.eval("return ns.GroupRules:IsAuthority()") is True
    for n in ("Bob", "Rita", "Sam", "Gina"):
        x = c[n]
        assert session(x)["id"] == rid, (n, session(x))
        assert x.eval("return ns.GroupRules:IsLocked()") is True, n
        assert current(x) == rid, n
        assert rec(x, rid)["att"][K("Lee")].get("l"), (n, rec(x, rid)["att"][K("Lee")])
    # Lee left the raid: his own copy ends by the safety net
    r = rec(lee, rid)
    assert r["stop"] and r.get("autoEnded") is True and current(lee) is None, r
    bob.slash("/dz raid end")
    w.tick(2)
    for n in ("Bob", "Rita", "Sam", "Gina"):
        r = rec(c[n], rid)
        assert r["endedBy"] == K("Bob"), (n, r)
        assert c[n].eval("return ns.GroupRules:IsLocked()") is False, n
    w.assert_no_errors()


@case
def disband_without_end_closes_at_the_last_activity():
    w, c = world()
    raid(w, c)
    w.enter_instance()
    rid = start(w, c)
    w.tick(600, step=1)
    w.encounter(652, "Attumen the Huntsman")
    w.tick(1)
    kill_ts = rec(c["Rita"], rid)["bosses"][0]["ts"]
    w.leave_instance()
    w.tick(3600, step=5)     # everyone hearthed; nobody disbanded yet
    assert current(c["Rita"]) == rid
    w.disband()
    w.tick(2)
    for n, x in c.items():
        r = rec(x, rid)
        assert r.get("autoEnded") is True and not r.get("endedBy"), (n, r)
        # the last activity: the last scan with the raid inside (up to one scan interval after the kill)
        assert kill_ts <= r["stop"] <= kill_ts + 61, (n, r["stop"], kill_ts)
        assert current(x) is None and x.eval("return ns.GroupRules:IsLocked()") is False, n
    w.assert_no_errors()


@case
def missed_pull_reminds_the_leader_and_backdates_the_start():
    w, c = world()
    lee, rita = c["Lee"], c["Rita"]
    raid(w, c)
    w.enter_instance()
    entered = w.server_time
    w.tick(300, step=1)
    n0, r0 = len(lee.chat_frame), len(rita.chat_frame)
    w.encounter(652, "Attumen the Huntsman", success=False)
    w.tick(1)
    assert said(lee, n0, "/dz raid start"), printed_since(lee, n0)
    assert not said(rita, r0, "/dz raid start")
    # a second pull soon after doesn't repeat it
    n1 = len(lee.chat_frame)
    w.encounter(652, "Attumen the Huntsman", success=False)
    w.tick(1)
    assert not said(lee, n1, "/dz raid start")
    rid = start(w, c)
    s = session(rita)
    assert abs(s["at"] - entered) <= 2, (s, entered)
    assert rec(rita, rid)["start"] == s["at"]
    w.assert_no_errors()


@case
def midraid_joiner_and_reloads_resume_the_same_record():
    w, c = world()
    lee, rita, sam = c["Lee"], c["Rita"], c["Sam"]
    raid(w, c, members=("Lee", "Bob", "Rita", "Gina"))
    w.enter_instance()
    rid = start(w, c)
    raid(w, c, members=("Lee", "Bob", "Rita", "Gina", "Sam"), tick=10)
    assert current(sam) == rid and rec(sam, rid)["start"] == session(lee)["at"]
    assert K("Sam") in rec(lee, rid)["att"]
    w.encounter(652, "Attumen the Huntsman")
    w.tick(1)
    rita.relog()
    w.tick(10)
    assert current(rita) == rid
    assert len(rec(rita, rid)["bosses"]) == 1 and rec(rita, rid).get("stop") is None
    # the leader reloads: still the authority, the same session and lock go on
    lee.relog()
    w.tick(12)
    assert session(lee)["id"] == rid and session(rita)["id"] == rid
    assert rita.eval("return ns.GroupRules:IsLocked()") is True
    assert rec(lee, rid).get("stop") is None
    # ended while Rita was reloading: she closes her copy when she learns it
    rita.relog(reload=True)
    lee.slash("/dz raid end")
    w.tick(10)
    assert current(rita) is None and rec(rita, rid)["stop"], rec(rita, rid)
    w.assert_no_errors()


@case
def offline_members_at_a_kill_are_marked():
    w, c = world()
    raid(w, c)
    w.enter_instance()
    rid = start(w, c)
    c["Sam"].logout()
    w.tick(2)
    w.encounter(652, "Attumen the Huntsman")
    w.tick(1)
    b = rec(c["Lee"], rid)["bosses"][0]
    assert K("Sam") in b["roster"] and b["off"] == {K("Sam"): True}, b
    w.assert_no_errors()


@case
def awards_carry_the_raid_id():
    w, c = world()
    bob, gina = c["Bob"], c["Gina"]
    raid(w, c)
    before = bob.eval_py("local e = ns.Ledger:Award(28000, ..., '', nil, false); return e.rid", K("Rita"))
    assert before is None
    rid = start(w, c)
    e = bob.eval_py("local e = ns.Ledger:Award(28001, ..., '', nil, false); return { id = e.id, rid = e.rid }", K("Rita"))
    assert e["rid"] == rid, e
    w.tick(10)
    assert gina.eval("return ns.Ledger:GetEntry(...).rid", e["id"]) == rid
    # a peer's copy with rid fills in a missing one (a council member who was not in the raid)
    gina.eval("local x = ns.Ledger:GetEntry(...); x.rid = nil", e["id"])
    gina.eval("ns.Ledger:Merge({ id = ..., i = 28001, w = select(2, ...), b = '', ts = select(3, ...), by = select(4, ...), "
              "s = 'm', rid = select(5, ...) }, 'x')", e["id"], K("Rita"), bob.eval("return ns.Ledger:GetEntry(...).ts", e["id"]),
              K("Bob"), rid)
    assert gina.eval("return ns.Ledger:GetEntry(...).rid", e["id"]) == rid
    w.assert_no_errors()


@case
def prune_drops_old_rosters_and_old_raids():
    w, c = world()
    lee = c["Lee"]
    now = w.server_time
    lee.eval("""local now = ...
        ns.db.raids.old = { id = 'old', start = now - 400 * 86400, stop = now - 400 * 86400 + 3600, bosses = {}, att = {} }
        ns.db.raids.mid = { id = 'mid', start = now - 100 * 86400, stop = now - 100 * 86400 + 3600,
            bosses = { { enc = 1, ts = now - 100 * 86400, roster = { 'A' }, off = { A = true } } }, att = { A = { k = 1 } } }
        ns.db.raids.new = { id = 'new', start = now - 10 * 86400, stop = now - 10 * 86400 + 3600,
            bosses = { { enc = 1, ts = now - 10 * 86400, roster = { 'A' } } }, att = { A = { k = 1 } } }
        ns.db.raids.junk = 5
        ns.RaidLog:Prune(now)""", now)
    raids = lee.eval_py("return ns.db.raids")
    assert set(raids) == {"mid", "new"}, raids
    assert "roster" not in raids["mid"]["bosses"][0] and raids["mid"]["att"]["A"]["k"] == 1
    assert raids["new"]["bosses"][0]["roster"] == ["A"]
    w.assert_no_errors()


# -- UI: session bar and Raids tab (§51) ---------------------------------------------------------------------------
def bar(cl):
    return cl.eval_py("""local f = ns.SessionBar:GetFrame()
        if not f then return { shown = false } end
        -- the zone is the bar's title, the details its grey text, the lock a pill
        local text = (f.title:GetText() or "") .. " " .. (f.text:GetText() or "") .. (f.pill:IsShown() and " BiS locked" or "")
        return { shown = f:IsShown(), text = text, button = f.button:IsShown() and f.button:GetText() or nil,
                 close = f.close:IsShown() }""")


@case
def session_bar_shows_for_everyone_and_the_leader_ends_from_it():
    w, c = world()
    lee, rita = c["Lee"], c["Rita"]
    raid(w, c)
    assert not bar(lee)["shown"], "no bar outside a raid instance without a session"
    w.enter_instance("Karazhan", 532)
    w.tick(2)
    b = bar(lee)
    assert b["shown"] and b["button"] == "Start raid" and b["close"], b
    assert not bar(rita)["shown"], "only the authority sees the idle bar"
    lee.click(lee.eval("return ns.SessionBar:GetFrame().button"))
    w.tick(0.2)
    # 1.2: Start raid asks what the session runs first (tests/raidlog/test_raid_features.py); everything by default
    lee.click(lee.eval("return ns.SessionBar:GetStartWindow().startBtn"))
    w.tick(3)
    rid = session(rita)["id"]
    for n, x in c.items():
        b = bar(x)
        assert b["shown"] and "Karazhan" in b["text"] and "0/11 bosses" in b["text"] and "BiS locked" in b["text"], (n, b)
        assert b.get("button") == ("End raid" if n == "Lee" else None) and not b["close"], (n, b)
    w.encounter(652, "Attumen the Huntsman")
    w.tick(2)
    assert "1/11 bosses" in bar(rita)["text"], bar(rita)
    lee.click(lee.eval("return ns.SessionBar:GetFrame().button"))
    w.tick(0.2)
    assert "DISASTERZONE_RAID_END" in lee.popups()
    assert session(rita)["id"] == rid, "nothing ends before the confirmation"
    lee.accept_popup("DISASTERZONE_RAID_END")
    w.tick(3)
    assert not bar(rita)["shown"] and rec(rita, rid)["endedBy"] == K("Lee")
    # the leader, still inside, sees the idle bar again; dismissing it hides it until the next instance
    assert bar(lee).get("button") == "Start raid"
    lee.click(lee.eval("return ns.SessionBar:GetFrame().close"))
    w.tick(0.2)
    assert not bar(lee)["shown"]
    w.assert_no_errors()


@case
def raids_tab_lists_raids_details_bench_and_players():
    w, c = world()
    lee, bob, rita = c["Lee"], c["Bob"], c["Rita"]
    raid(w, c)
    w.enter_instance("Karazhan", 532)
    w.tick(2)
    rid = start(w, c)
    w.encounter(652, "Attumen the Huntsman")
    w.tick(2)
    bob.eval("ns.Ledger:Award(28000, ..., '', nil, false)", K("Rita"))
    w.tick(2)
    lee.slash("/dz raid end")
    w.tick(3)
    # (Addendum J: raiders have the Raids tab for sign-ups, but not its Raid log view)
    rita.slash("/dz raids")
    w.tick(0.5)
    rita.eval("ns.RaidsUI:SetView('log')")
    assert rita.eval("return ns.RaidsUI:GetView()") == "upcoming", "raiders don't get the raid log"
    assert not rita.eval("return ns.RaidsUI:GetPanel().logBtn:IsShown()")
    bob.slash("/dz raids")
    w.tick(0.5)
    assert bob.eval("return ns.MainFrame:GetSelectedTab()") == "raids"
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().logBtn"))
    w.tick(0.3)
    assert bob.eval("return ns.RaidsUI:GetView()") == "log"
    texts = lambda needle: [strip_codes(t) for t in bob.eval_py(
        "local out = {}; for _, r in ipairs(...) do out[#out + 1] = r:GetText() end; return out",
        bob.find_text(needle, True, True)) or []]
    assert any("Karazhan" in t for t in texts("Karazhan")), "raid row"
    assert texts("1/11 bosses"), "summary with the boss total"
    assert texts("Attendance") and texts("Bosses") and texts("Awards"), "the raid's tabs"
    assert not texts("Attumen the Huntsman"), "the kills are on the Bosses tab"
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().tabBoss"))
    assert texts("Attumen the Huntsman"), "boss timeline"
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().tabAward"))
    assert texts("Rita"), "the award's winner"
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().tabAtt"))
    assert bob.eval("return ns.RaidLog:GetAwards(ns.RaidLog:GetRaid(...))[1].i", rid) == 28000
    # bench: a council member marks Sam (not in the log) as bench -> counts as attending
    bob.eval("ns.RaidLog:SetBench(...)", rid, K("Nora"), True)
    a = rec(bob, rid)["att"][K("Nora")]
    assert a["b"] is True and a["k"] == 0, a
    # players view
    bob.eval("ns.RaidsUI:SetMode('players', 8)")
    w.tick(0.5)
    stats = bob.eval_py("return (ns.RaidLog:GetPlayerStats(8))")
    by = {s["key"]: s for s in stats}
    assert by[K("Rita")]["pct"] == 100 and by[K("Rita")]["items"] == 1 and by[K("Rita")]["kills"] == 1, by[K("Rita")]
    assert by[K("Nora")]["bench"] == 1 and by[K("Nora")]["pct"] == 100
    assert texts("100%"), "attendance column"
    assert bob.eval_py("return { ns.RaidLog:GetAttendance(...) }", K("Rita")) == [100, 1, 1]
    w.assert_no_errors()


# -- Council sync (§50) and attendance in the council views ----------------------------------------------------------
@case
def council_recorders_fill_each_others_gaps_when_the_raid_ends():
    w, c = world(council=("Bob", "Gina"))
    bob, gina, lee = c["Bob"], c["Gina"], c["Lee"]
    raid(w, c)
    w.enter_instance()
    rid = start(w, c)
    # Gina is outside for the first kill (her client never sees it), Bob for the second
    w.encounter(652, "Attumen the Huntsman", clients=[lee, bob, c["Rita"], c["Sam"]])
    w.tick(60, step=1)
    w.encounter(653, "Moroes", clients=[lee, gina, c["Rita"], c["Sam"]])
    w.tick(2)
    # 1.3.4: whoever saw a kill tells the raid (RLK), so the missed kill is filled in right away
    assert [b["enc"] for b in rec(bob, rid)["bosses"]] == [652, 653], rec(bob, rid)["bosses"]
    assert [b["enc"] for b in rec(gina, rid)["bosses"]] == [652, 653], rec(gina, rid)["bosses"]
    mark = len(w.addon_log)
    lee.slash("/dz raid end")
    w.tick(40)
    for x in (bob, gina):
        r = rec(x, rid)
        assert [b["enc"] for b in r["bosses"]] == [652, 653], r["bosses"]
        assert r["endedBy"] == K("Lee"), r
    assert bob.eval_py("return ns.RaidLog:GetDigest()") == gina.eval_py("return ns.RaidLog:GetDigest()")
    assert lr.msgs_of_type(w, "RLD", mark)
    # each recorder gave the other its record. A record often goes out in two AceComm parts (over 255 bytes), and how
    # big it is depends on which recorder offered first (random delays), so the parts are joined before decoding.
    rlg = lr.msgs_of_type(w, "RLG", mark, whole=True)
    # (1.3.4: RLK already filled the kills in, so one exchange can be enough to agree)
    assert rlg and {m["_sender"] for m in rlg} <= {K("Bob"), K("Gina")}, [(m["_sender"], m["_time"]) for m in rlg]
    # raiders never get records: only council members send or receive them
    targets = [e.get("target") for e in w.addon_log[mark:] if e["prefix"] == "CDLd"]
    assert targets and set(targets) <= {"Bob", "Gina"}, targets
    w.assert_no_errors()


@case
def a_council_member_who_missed_the_raid_gets_it_at_login():
    w, c = world(names=(("Gina", 0, "PALADIN"), ("Lee", 3, "WARRIOR"), ("Bob", 1, "MAGE"), ("Rita", 3, "PRIEST"),
                        ("Sam", 3, "ROGUE"), ("Nora", 1, "DRUID")), council=("Bob", "Nora"))
    nora = c["Nora"]
    nora.logout()
    w.tick(2)
    raid(w, c)
    w.enter_instance()
    rid = start(w, c)
    w.encounter(652, "Attumen the Huntsman")
    w.tick(2)
    c["Lee"].slash("/dz raid end")
    w.tick(30)
    nora.login()
    w.tick(60)
    r = rec(nora, rid)
    assert r and r["stop"] and len(r["bosses"]) == 1 and K("Rita") in r["att"], r
    assert nora.eval("return ns.RaidLog:GetRaid(...).g", rid) == c["Bob"].eval("return ns.RaidLog:GetRaid(...).g", rid)
    # a later bench edit spreads with the next sync
    c["Bob"].eval("ns.RaidLog:SetBench(...)", rid, K("Rita"), True)
    w.tick(2)
    c["Bob"].eval("ns.Sync:SendHello(true)")
    w.tick(30)
    assert rec(nora, rid)["att"][K("Rita")].get("b") is True
    w.assert_no_errors()


@case
def forged_or_malformed_records_are_ignored():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    now = w.server_time
    good = {"id": "Lee-Thunderstrike-1", "start": now - 7200, "stop": now - 3600, "bosses": [],
            "att": {K("Rita"): {"j": now - 7200, "l": now - 3600, "k": 0}}}
    # from a raider: dropped
    rita.eval("ns.Comm:Send({ t = 'RLG', r = ... }, 'WHISPER', select(2, ...), 'data')", good, K("Bob"))
    w.tick(3)
    assert bob.eval("return ns.RaidLog:GetRaid('Lee-Thunderstrike-1')") is None
    # malformed shapes from council are rejected by MergeRecord
    for bad in ({"id": "x|y", "start": 1, "stop": 2, "att": {}, "bosses": []},
                {"id": "a", "start": now + 9999, "stop": now + 99999, "att": {}, "bosses": []},
                {"id": "b", "start": 10, "stop": 5, "att": {}, "bosses": []},
                {"id": "c", "start": 1, "stop": 2, "att": 5, "bosses": []}):
        assert bob.eval("return ns.RaidLog:MergeRecord(...)", bad, "x") is False, bad
    assert bob.eval("return ns.RaidLog:MergeRecord(...)", good, "x") is True
    # merging the same record twice changes nothing; a copy with an explicit End wins over the safety net
    assert bob.eval("return ns.RaidLog:MergeRecord(...)", good, "x") is False
    ended = dict(good, stop=now - 3000, endedBy=K("Lee"))
    auto = dict(good, stop=now - 2000, autoEnded=True)
    assert bob.eval("return ns.RaidLog:MergeRecord(...)", auto, "x") is True
    assert bob.eval("return ns.RaidLog:MergeRecord(...)", ended, "x") is True
    r = rec(bob, "Lee-Thunderstrike-1")
    assert r["endedBy"] == K("Lee") and r["stop"] == now - 3000 and not r.get("autoEnded"), r
    w.assert_no_errors()


@case
def gm_and_guild_council_delete_a_logged_raid_for_everyone():
    w, c = world(council=("Bob", "Gina"))
    bob, gina, lee, rita = c["Bob"], c["Gina"], c["Lee"], c["Rita"]
    raid(w, c)
    w.enter_instance("Karazhan", 532)
    rid = start(w, c)
    w.encounter(652, "Attumen the Huntsman")
    w.tick(2)
    # a running raid can't be deleted
    ok = bob.eval_py("return { ns.RaidLog:Delete(...) }", rid)
    assert ok[0] is False and "running" in ok[1], ok
    lee.slash("/dz raid end")
    w.tick(40)
    assert rec(bob, rid) and rec(gina, rid)
    # raiders (and the group's leader) can't
    for x in (rita, lee):
        assert x.eval("return ns.RaidLog:CanDelete()") is False
        assert x.eval("return (ns.RaidLog:Delete(...))", rid) is False
    # the council member deletes it with the bin in the Raid log view, after confirming
    bob.slash("/dz raids")
    w.tick(0.5)
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().logBtn"))
    w.tick(0.3)
    btn = bob.eval("return ns.RaidsUI:GetPanel().deleteLogBtn")
    assert bob.eval("return ns.RaidsUI:GetPanel().deleteLogBtn:IsShown()") is True
    bob.click(btn)
    bob.cancel_popup("DISASTERZONE_CONFIRM")
    w.tick(1)
    assert rec(bob, rid)
    bob.click(btn)
    bob.accept_popup("DISASTERZONE_CONFIRM")
    w.tick(40)
    for x in (bob, gina):
        assert rec(x, rid) is None, "gone"
        assert x.eval("return #ns.RaidLog:GetRaids()") == 0
        assert x.eval("return ns.RaidLog:GetAttendance(...)", K("Rita")) is None
    assert bob.eval_py("return ns.RaidLog:GetDigest()") == gina.eval_py("return ns.RaidLog:GetDigest()")
    assert bob.eval("return ns.RaidsUI:GetPanel().deleteLogBtn:IsShown()") is False
    # a peer's copy of the raid doesn't bring it back
    now = int(w.server_time)
    live = {"id": rid, "start": now - 7200, "stop": now - 3600, "bosses": [],
            "att": {K("Rita"): {"j": now - 7200, "l": now - 3600, "k": 0}}}
    assert gina.eval("return ns.RaidLog:MergeRecord(...)", live, "x") is False
    assert rec(gina, rid) is None
    # 1.3: a deletion counts by who sends it (the GM / guild council), whoever it names: a raid leader or raider can't
    # relay one that names a council member, and one naming somebody who has left the council since still spreads
    other = dict(live, id="Lee-Thunderstrike-77")
    assert gina.eval("return ns.RaidLog:MergeRecord(...)", other, "x") is True
    tomb = {"id": other["id"], "start": other["start"], "stop": other["stop"], "del": True, "delAt": now}
    assert gina.eval("return ns.RaidLog:MergeRecord(...)", dict(tomb, delBy=K("Bob")), K("Lee")) is False
    assert gina.eval("return ns.RaidLog:MergeRecord(...)", dict(tomb, delBy=K("Bob")), K("Rita")) is False
    assert gina.eval("return ns.RaidLog:MergeRecord(...)", tomb, "x") is False
    assert rec(gina, other["id"])
    assert gina.eval("return ns.RaidLog:MergeRecord(...)", dict(tomb, delBy=K("Rita")), K("Bob")) is True
    assert rec(gina, other["id"]) is None
    w.assert_no_errors()


@case
def attendance_shows_in_the_council_views():
    w, c = world()
    bob, lee = c["Bob"], c["Lee"]
    raid(w, c)
    rid = start(w, c)
    lee.slash("/dz raid end")
    w.tick(2)
    raid(w, c, members=("Lee", "Bob", "Gina", "Sam"))
    start(w, c)
    lee.slash("/dz raid end")
    w.tick(2)
    # 1.3.5 (time-based): raids not linked to a planned raid only expect who came, so Rita's second raid (she wasn't
    # in it) doesn't count against her; nobody expected = no attendance
    assert bob.eval_py("return { ns.RaidLog:GetAttendance(...) }", K("Rita")) == [100, 1, 2]
    assert bob.eval("return ns.RaidLog:GetAttendanceText(...)", K("Sam")) == "100% (2 raids)"
    assert bob.eval("return ns.RaidLog:GetAttendance(...)", K("Nobody")) is None
    bob.eval("ns.CouncilUI:ShowMember(...)", K("Rita"))
    w.tick(0.5)
    assert bob.find_text("attendance 100% (1 raid)", True, True), "member header"
    w.assert_no_errors()


@case
def demo_mode_fills_the_raids_tab_without_touching_the_real_log():
    from _common import solo
    w, c = solo(council=None)
    c.eval("ns.db.raids.real = { id = 'real', start = GetServerTime() - 3600, stop = GetServerTime(), bosses = {}, att = {} }")
    saved = c.eval_py("return ns.db.raids")
    c.slash("/dz demo")
    w.tick(1)
    raids = c.eval_py("local out = {}; for i, r in ipairs(ns.RaidLog:GetRaids()) do out[i] = { id = r.id, zone = r.zone, "
                      "n = #r.bosses, att = ns.Util.Count(r.att), aw = #ns.RaidLog:GetAwards(r), auto = r.autoEnded } end; return out")
    assert len(raids) == 10 and all(r["id"].startswith("demo-") for r in raids), raids
    assert {r["zone"] for r in raids} == {"Karazhan", "Gruul's Lair", "Magtheridon's Lair"}, raids
    assert raids[0]["n"] > 0 and all(r["att"] >= 5 and r["aw"] >= r["n"] for r in raids), raids
    assert any(r.get("auto") for r in raids)
    # deterministic, varied attendance, player included
    me = c.eval("return ns.Util.PlayerKey()")
    assert c.eval_py("return { ns.RaidLog:GetAttendance(...) }", me)[0] == 100
    stats = c.eval_py("return (ns.RaidLog:GetPlayerStats(8))")
    pcts = {s["pct"] for s in stats}
    assert len(pcts) >= 3 and any(s["bench"] > 0 for s in stats) and any(s["items"] > 0 for s in stats), stats
    again = c.eval_py("local r = ns.RaidLog:GetRaids()[1]; return { r.start, r.bosses[1].enc, ns.RaidLog:GetAwards(r)[1].i }")
    # the tab paints
    c.slash("/dz raids")
    w.tick(0.5)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "raids"
    c.eval("ns.RaidsUI:SetView('log')")
    w.tick(0.3)
    assert c.find_text("Karazhan", True, True)
    c.eval("ns.RaidsUI:SetMode('players', 8)")
    w.tick(0.3)
    assert c.find_text("100%", True, True)
    # toggling off brings the real log back; nothing demo was saved
    c.slash("/dz demo")
    w.tick(1)
    assert [r["id"] for r in c.eval_py("return ns.RaidLog:GetRaids()")] == ["real"]
    assert c.eval_py("return ns.db.raids") == saved
    c.slash("/dz demo")
    w.tick(1)
    assert c.eval_py("local r = ns.RaidLog:GetRaids()[1]; return { r.start, r.bosses[1].enc, ns.RaidLog:GetAwards(r)[1].i }") == again
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

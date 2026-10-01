"""ADDENDUM J §54-§57: raid planning core (teams, raids, weekly series, sign-ups, sync), on the real addon.

Covers: an organizer's team + raid reaching every online member, invited / unanswered, non-organizers refused and
forged or non-organizer records hidden, sign-ups spreading and the newest winning, the remembered spec, weekly series
(two occurrences ahead, override of one, series-wide time shift, cancel, stop repeating), a member who logs in late
catching up from another member after the organizer went offline (one answer per round), a sign-up made while nobody
else was online spreading at the next login, malformed traffic, the HELLO pd field, group layouts and pruning.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(TESTS, "loot-roll"))

from _common import case, run_all  # noqa: E402
import lr_common as lr  # noqa: E402

from rp_common import REALM, DAY, K, world, now, team, create, raids, raid, signup, signups, call  # noqa: E402


# ------------------------------------------------------------------------------------------------------------------
@case
def organizer_team_and_raid_reach_everyone():
    w, c = world()
    bob = c["Bob"]
    assert bob.eval("return ns.RaidPlan:CanOrganize()") is True
    assert c["Gina"].eval("return ns.RaidPlan:CanOrganize()") is True
    assert c["Rita"].eval("return ns.RaidPlan:CanOrganize()") is False
    mark = len(w.addon_log)
    tid = team(bob, "Kara Team A", ["Lee", "Rita"])
    t0 = now(bob) + 2 * DAY
    occ = create(bob, i="kara", t=t0, tm=[tid], no="Bring pots")
    w.tick(2)
    rpu = lr.msgs_of_type(w, "RPU", mark)
    assert [m["k"] for m in rpu] == ["T", "E"] and all(m["_chat_type"] == "GUILD" for m in rpu), rpu
    for n, x in c.items():
        rs = raids(x)
        assert len(rs) == 1, (n, rs)
        v = rs[0]
        assert v["id"] == occ and v["i"] == "kara" and v["sz"] == 10 and v["t"] == t0 and v["no"] == "Bring pots", (n, v)
        assert v["tm"] == [tid] and not v["weekly"] and not v["cancelled"], (n, v)
        assert x.eval("return ns.RaidPlan:GetRaidName(ns.RaidPlan:GetRaid(...))", occ) == "Karazhan"
        tms = x.eval_py("return ns.RaidPlan:GetTeams()")
        assert len(tms) == 1 and tms[0]["name"] == "Kara Team A" and tms[0]["members"] == [K("Lee"), K("Rita")], (n, tms)
        inv = x.eval_py("return ns.RaidPlan:GetInvited(...)", occ)
        assert set(inv) == {K("Lee"), K("Rita")}, (n, inv)
    assert len(c["Rita"].eval_py("return ns.RaidPlan:GetUnanswered()")) == 1
    assert c["Sam"].eval_py("return ns.RaidPlan:GetUnanswered()") == []
    # an open raid (no team) invites nobody in particular
    occ2 = create(c["Gina"], i="gruul", t=t0 + 3600, ti="Gruul + Mag")
    w.tick(2)
    v = raid(c["Sam"], occ2)
    assert v["sz"] == 25 and v["ti"] == "Gruul + Mag" and v["tm"] == [], v
    assert c["Sam"].eval("return ns.RaidPlan:GetInvited(...)", occ2) is None
    assert c["Sam"].eval("return ns.RaidPlan:GetRaidName(ns.RaidPlan:GetRaid(...))", occ2) == "Gruul + Mag"
    # the team is renamed, then deleted
    team(bob, "Kara A", ["Lee"], tid)
    w.tick(2)
    assert c["Rita"].eval_py("return ns.RaidPlan:GetTeam(...)", tid)["name"] == "Kara A"
    assert call(bob, "DeleteTeam", tid)["ok"] is True
    w.tick(2)
    for n, x in c.items():
        assert x.eval_py("return ns.RaidPlan:GetTeams()") == [], n
        assert x.eval("return ns.RaidPlan:GetInvited(...)", occ) is not None   # names a team: invited set (empty)
    w.assert_no_errors()


@case
def non_organizers_are_refused_and_forged_records_hidden():
    w, c = world()
    rita, sam = c["Rita"], c["Sam"]
    res = rita.eval_py("local ok, e = ns.RaidPlan:CreateRaid({ i = 'kara', t = GetServerTime() + 86400 }); return { ok = ok, e = e }")
    assert res["ok"] is False and "raid leaders" in res["e"], res
    assert call(rita, "SaveTeam", None, "X", [])["ok"] is False
    t = now(rita) + DAY
    # a forged live edit naming an organizer as the editor: dropped (the editor must be the sender)
    rita.eval("local t = ...; ns.Comm:Send({ t = 'RPU', k = 'E', r = { id = 'f1', rev = GetServerTime(), by = 'Bob-Thunderstrike',"
              " t = t, i = 'kara', sz = 10 } }, 'GUILD', nil, 'data')", t)
    # a member's own "raid": stored, but hidden (not an organizer)
    rita.eval("local t = ...; ns.Comm:Send({ t = 'RPU', k = 'E', r = { id = 'f2', rev = GetServerTime(), by = 'Rita-Thunderstrike',"
              " t = t, i = 'kara', sz = 10 } }, 'GUILD', nil, 'data')", t)
    w.tick(2)
    assert sam.eval("return ns.db.raidplan['Casual Disaster-Thunderstrike'].E.f1") is None
    assert sam.eval("return ns.db.raidplan['Casual Disaster-Thunderstrike'].E.f2 ~= nil") is True
    assert raids(sam) == []
    # malformed records: unknown raid, bad size, far future, rev in the future, oversized team
    bad = [
        "{ id = 'b1', rev = GetServerTime(), by = 'Rita-Thunderstrike', t = GetServerTime() + 3600, i = 'naxx', sz = 10 }",
        "{ id = 'b2', rev = GetServerTime(), by = 'Rita-Thunderstrike', t = GetServerTime() + 3600, i = 'kara', sz = 40 }",
        "{ id = 'b3', rev = GetServerTime(), by = 'Rita-Thunderstrike', t = GetServerTime() + 400 * 86400, i = 'kara', sz = 10 }",
        "{ id = 'b4', rev = GetServerTime() + 3600, by = 'Rita-Thunderstrike', t = GetServerTime() + 3600, i = 'kara', sz = 10 }",
        "{ id = 'b 5', rev = GetServerTime(), by = 'Rita-Thunderstrike', t = GetServerTime() + 3600, i = 'kara', sz = 10 }",
    ]
    for r in bad:
        rita.eval("ns.Comm:Send({ t = 'RPU', k = 'E', r = %s }, 'GUILD', nil, 'data')" % r)
    rita.eval("local m = {}; for i = 1, 41 do m[i] = 'P' .. i .. '-Thunderstrike' end;"
              " ns.Comm:Send({ t = 'RPU', k = 'T', r = { id = 't1', rev = GetServerTime(), by = 'Rita-Thunderstrike', n = 'Big', m = m } }, 'GUILD', nil, 'data')")
    w.tick(2)
    stored = sam.eval_py("local r = ns.db.raidplan['Casual Disaster-Thunderstrike']; local out = {}; "
                         "for id in pairs(r.E) do out[#out + 1] = id end; for id in pairs(r.T) do out[#out + 1] = id end; "
                         "table.sort(out); return out")
    assert stored == ["f2"], stored
    # a sign-up is always the sender's own: someone else's name can't be forged
    occ = create(c["Bob"], i="kara", t=t)
    w.tick(2)
    rita.eval("local o = ...; ns.Comm:Send({ t = 'RPS', l = { { o = o, s = { st = 'X', rev = GetServerTime() } } } }, 'GUILD', nil, 'ctrl')", occ)
    w.tick(2)
    assert set(signups(sam, occ)) == {K("Rita")}
    w.assert_no_errors()


@case
def signups_spread_newest_wins_and_spec_is_remembered():
    w, c = world()
    bob, rita, sam, lee = c["Bob"], c["Rita"], c["Sam"], c["Lee"]
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(2)
    assert signup(rita, occ, "A", 3, "late 10 min")["ok"] is True       # Shadow
    assert signup(sam, occ, "T")["ok"] is True
    assert signup(lee, occ, "A", 4)["ok"] is False                       # warriors have 3 specs
    assert signup(lee, occ, "Z")["ok"] is False
    w.tick(2)
    for n, x in c.items():
        s = signups(x, occ)
        assert set(s) == {K("Rita"), K("Sam")}, (n, s)
        assert s[K("Rita")]["st"] == "A" and s[K("Rita")]["sp"] == 3 and s[K("Rita")]["c"] == "PRIEST", (n, s)
        assert s[K("Rita")]["n"] == "late 10 min" and s[K("Sam")]["st"] == "T" and "sp" not in s[K("Sam")], (n, s)
    # changing the answer keeps spec and note; the newest wins everywhere
    w.tick(2)
    assert signup(rita, occ, "X")["ok"] is True
    w.tick(2)
    for n, x in c.items():
        s = signups(x, occ)[K("Rita")]
        assert s["st"] == "X" and s["sp"] == 3 and s["n"] == "late 10 min", (n, s)
    assert rita.eval("return ns.RaidPlan:GetLastSpec()") == 3
    # a new raid defaults to the spec used last; the note can be cleared
    occ2 = create(bob, i="gruul", t=now(bob) + 2 * DAY)
    w.tick(2)
    assert signup(rita, occ2, "B", None, False)["ok"] is True
    assert rita.eval_py("return ns.RaidPlan:GetMySignup(...)", occ2)["sp"] == 3
    # a cancelled or finished raid takes no sign-ups
    assert call(bob, "CancelRaid", occ2)["ok"] is True
    w.tick(2)
    assert raid(sam, occ2)["cancelled"] is True
    assert "cancelled" in signup(sam, occ2, "A")["e"]
    w.assert_no_errors()


@case
def weekly_series_occurrences_overrides_and_stop():
    w, c = world()
    bob, sam = c["Bob"], c["Sam"]
    t0 = now(bob) + DAY
    occ0 = create(bob, i="kara", t=t0, weekly=True, no="weekly")
    assert occ0.endswith("#0"), occ0
    sid = occ0[:-2]
    w.tick(2)
    rs = raids(sam)
    assert [r["id"] for r in rs] == [occ0, sid + "#1"], rs          # two ahead; #2 (15 days out) not yet
    assert rs[1]["t"] - rs[0]["t"] in (7 * DAY - 3600, 7 * DAY, 7 * DAY + 3600) and all(r["weekly"] for r in rs), rs
    # this raid only: a different note on #1
    assert call(bob, "EditRaid", sid + "#1", {"no": "SSC attune run"})["ok"] is True
    # the whole series: one hour later, a new note
    assert call(bob, "EditRaid", occ0, {"t": t0 + 3600, "no": "weekly v2"}, "series")["ok"] is True
    w.tick(2)
    rs = raids(sam)
    assert rs[0]["t"] == t0 + 3600 and rs[0]["no"] == "weekly v2", rs[0]
    assert rs[1]["no"] == "SSC attune run" and rs[1]["override"] is True, rs[1]   # the override keeps its note
    assert rs[1]["t"] - rs[0]["t"] in (7 * DAY - 3600, 7 * DAY, 7 * DAY + 3600), rs
    # sign-ups are per occurrence and survive series edits
    assert signup(sam, sid + "#1", "A", 2)["ok"] is True
    w.tick(2)
    assert call(bob, "EditRaid", occ0, {"i": "gruul", "sz": 25}, "series")["ok"] is True
    w.tick(2)
    assert raid(c["Rita"], sid + "#1")["i"] == "gruul"
    assert set(signups(c["Rita"], sid + "#1")) == {K("Sam")}
    # cancel one, then stop after #0
    assert call(bob, "CancelRaid", sid + "#1")["ok"] is True
    w.tick(2)
    assert [r["cancelled"] for r in raids(sam)] == [False, True]
    assert call(bob, "EditRaid", sid + "#1", {"x": False})["ok"] is True
    w.tick(2)
    assert [r["cancelled"] for r in raids(sam)] == [False, False]
    assert call(bob, "StopRepeating", occ0)["ok"] is True
    w.tick(2)
    assert [r["id"] for r in raids(sam)] == [occ0]
    # deleting the series removes it everywhere
    assert call(bob, "CancelRaid", occ0, "series")["ok"] is True
    w.tick(2)
    assert raids(sam) == [] and raids(c["Gina"]) == []
    w.assert_no_errors()


@case
def late_login_catches_up_from_a_member_after_the_organizer_left():
    names = (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"),
             ("Sam", 3, "ROGUE"), ("Uma", 3, "HUNTER"), ("Vic", 3, "SHAMAN"))
    w, c = world(names)
    bob, uma = c["Bob"], c["Uma"]
    uma.logout()
    c["Gina"].logout()
    w.tick(2)
    tid = team(bob, "Main", ["Uma", "Rita"])
    occ = create(bob, i="ssc", t=now(bob) + 3 * DAY, tm=[tid])
    w.tick(2)
    assert signup(c["Rita"], occ, "A", 2)["ok"] is True
    w.tick(2)
    bob.logout()
    w.tick(2)
    mark = len(w.addon_log)
    uma.login()
    w.tick(40)
    assert [r["id"] for r in raids(uma)] == [occ], raids(uma)
    assert uma.eval_py("return ns.RaidPlan:GetTeam(...)", tid)["members"] == [K("Rita"), K("Uma")]
    assert set(signups(uma, occ)) == {K("Rita")}
    assert len(uma.eval_py("return ns.RaidPlan:GetUnanswered()")) == 1
    rpd = [m for m in lr.msgs_of_type(w, "RPD", mark) if m["to"] == K("Uma")]
    assert len(rpd) == 1, rpd                                  # the others saw the answer and stayed quiet
    h = [m for m in lr.msgs_of_type(w, "H", mark) if m["_sender"] == K("Uma")]
    assert h and isinstance(h[0]["pd"], str), h           # (a live sign-up may have reached Uma already)
    # everyone agrees afterwards
    hashes = {n: x.eval("return ns.RaidPlan:GetDigestHash()") for n, x in c.items() if x.online}
    assert len(set(hashes.values())) == 1, hashes
    w.assert_no_errors()


@case
def a_signup_made_alone_spreads_at_the_next_login():
    w, c = world()
    bob, sam = c["Bob"], c["Sam"]
    occ = create(bob, i="kara", t=now(bob) + 2 * DAY)
    w.tick(2)
    others = [n for n in c if n != "Sam"]
    for n in others:
        c[n].logout()
    w.tick(2)
    assert signup(sam, occ, "A", 1)["ok"] is True     # nobody hears it
    w.tick(2)
    sam.logout()
    for n in others:
        c[n].login()
    w.tick(40)
    assert signups(bob, occ) == {}
    sam.login()
    w.tick(40)
    for n, x in c.items():
        assert set(signups(x, occ)) == {K("Sam")}, n
    w.assert_no_errors()


@case
def group_layout_and_digest_convergence():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    occ = create(bob, i="kara", t=now(bob) + DAY, weekly=True)
    w.tick(2)
    res = call(bob, "SetGroups", occ, {K("Rita"): 1, K("Sam"): 2})
    assert res["ok"] is True, res
    assert call(bob, "SetGroups", occ, {K("Rita"): 9})["ok"] is False
    assert call(rita, "SetGroups", occ, {K("Rita"): 1})["ok"] is False
    w.tick(2)
    v = raid(rita, occ)
    assert v["grp"] == {K("Rita"): 1, K("Sam"): 2}, v
    # the layout override still follows series edits
    assert call(bob, "EditRaid", occ, {"no": "new note"}, "series")["ok"] is True
    w.tick(2)
    v = raid(rita, occ)
    assert v["no"] == "new note" and v["grp"] == {K("Rita"): 1, K("Sam"): 2}, v
    hashes = {x.eval("return ns.RaidPlan:GetDigestHash()") for x in c.values()}
    assert len(hashes) == 1 and "0" not in hashes, hashes
    w.assert_no_errors()


@case
def old_raids_and_tombstones_are_pruned():
    w, c = world()
    bob = c["Bob"]
    t = now(bob)
    occ = create(bob, i="kara", t=t + DAY)
    wk = create(bob, i="gruul", t=t + 2 * DAY, weekly=True)
    tid = team(bob, "Gone", ["Lee"])
    assert call(bob, "DeleteTeam", tid)["ok"] is True
    w.tick(2)
    assert signup(c["Sam"], occ, "A")["ok"] is True
    w.tick(2)
    sam = c["Sam"]
    root = "ns.db.raidplan['Casual Disaster-Thunderstrike']"
    sam.eval("ns.RaidPlan:Prune(GetServerTime() + 10 * 86400)")
    assert sam.eval("return %s.E[...] ~= nil" % root, occ) is True
    sam.eval("ns.RaidPlan:Prune(GetServerTime() + 17 * 86400)")
    assert sam.eval("return %s.E[...]" % root, occ) is None
    assert sam.eval("return %s.U[...]" % root, occ) is None
    assert sam.eval("return %s.T[...] ~= nil" % root, tid) is True      # tombstone still spreading
    assert sam.eval("return %s.S[...] ~= nil" % root, wk[:-2]) is True  # a running series stays
    sam.eval("ns.RaidPlan:Prune(GetServerTime() + 31 * 86400)")
    assert sam.eval("return %s.T[...]" % root, tid) is None
    w.assert_no_errors()


@case
def slash_plan_lists_raids():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    occ = create(bob, i="tk", t=now(bob) + DAY)
    w.tick(2)
    signup(rita, occ, "A", 1)
    n0 = len(rita.chat_frame)
    rita.slash("/dz plan")
    lines = [str(x) for x in rita.chat_frame[n0:]]
    assert any("Tempest Keep (25)" in l and "you: Accepted" in l for l in lines), lines
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

"""Time-based attendance (1.3.5, user decisions 2026-10-11), on the real addon: Core/Attendance.lua + the raid log's
presence pieces (Core/RaidLog.lua).

Covers: who a raid expects (the team raid's own lineup only, never a 10-man player at the 25; a raid without a lineup:
Accept answers), the expected window (the team's raid night), presence pieces recorded live (late join, early leave,
a fill-in replacing them, short and long disconnects), credit and attendance %, reviews (left early, an own reason,
chat lines picked; nothing counts until decided; Excuse / Counts by a reviewer only; a decision from a non-reviewer
dropped at merge), officers reading and syncing the raid log, the raid leader's marks (bench, removed, swap) reaching
every recorder, a player's own reason reaching the leader, away periods, the clash rule (the team raid wins), server
trouble excused, the GM's margins, members asking for their own attendance, and digests compared without the new
fields with a client before 1.3.5.

Run: luaenv\\Scripts\\python.exe tests\\attendance\\test_attendance.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "raidplan"))

from rp_common import World, Client, gm_pick, set_raid_leaders, K  # noqa: E402
from _common import case, run_all, strip_codes  # noqa: E402

MIN = 60
HOUR = 3600
# Gina = GM, Olly = officer (not on any list), Bob = guild council + raid leader, the rest members
NAMES = (("Gina", 0, "PALADIN"), ("Olly", 1, "DRUID"), ("Bob", 2, "MAGE"), ("Tank", 3, "WARRIOR"),
         ("Heal", 3, "PRIEST"), ("Dps", 3, "ROGUE"), ("Kai", 3, "HUNTER"), ("Sam", 3, "WARLOCK"), ("Rita", 3, "SHAMAN"))


def world(names=NAMES, live=True):
    w = World()
    w.auto_session = False
    c = {}
    for name, rank, cls in names:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ["Bob"])
    w.tick(2)
    return w, c


def now(cl):
    return cl.eval("return GetServerTime()")


def lst(v):
    if v is None:
        return []
    return list(v.values()) if isinstance(v, dict) else list(v)


def save_team(cl, name, members, lineups=None, nights=None):
    o = {}
    if lineups is not None:
        o["lineups"] = [{"name": l["name"], "size": l["size"], "groups": {K(n): g for n, g in l["groups"].items()}}
                        for l in lineups]
    if nights is not None:
        o["nights"] = nights
    res = cl.eval_py("local n, m, o = ...; local ok, r = ns.RaidPlan:SaveTeam(nil, n, m, o); return { ok = ok, r = r }",
                     name, [K(m) for m in members], o)
    assert res["ok"] is True, res
    return res["r"]


def create(cl, **f):
    res = cl.eval_py("local f = ...; local ok, r = ns.RaidPlan:CreateRaid(f); return { ok = ok, r = r }", f)
    assert res["ok"] is True, res
    return res["r"]


def signup(cl, occ, st, note=None):
    res = cl.eval_py("local o, st, n = ...; local ok, e = ns.RaidPlan:SignUp(o, st, nil, n); return { ok = ok, e = e }",
                     occ, st, note)
    assert res["ok"] is True, res


def rec(cl, rid):
    return cl.eval_py("return ns.RaidLog:GetRaid(...)", rid)


def start(w, c, leader="Bob", occ=None, tick=3):
    assert c[leader].eval("return ns.GroupRules:SetSession(true, nil, { loot = true, rolls = true })")
    w.tick(tick)
    if occ:
        assert c[leader].eval("return ns.GroupRules:SetSessionPlan(...)", occ)
        w.tick(tick)
    rid = c[leader].eval("return ns.RaidLog:GetCurrentID()")
    assert rid
    return rid


def end(w, c, leader="Bob"):
    assert c[leader].eval("return ns.GroupRules:SetSession(false)")
    w.tick(3)


def wait(w, seconds):
    """Lets time pass in big steps (the raid log scans every minute)."""
    w.tick(seconds, 5)


def result(cl, nightKey, name):
    return cl.eval_py("local n = ns.Attendance:GetNight(...); return n and ns.Attendance:Result(n, select(2, ...))",
                      nightKey, K(name))


def stats(cl, lastN=8):
    rows = cl.eval_py("return (ns.Attendance:GetStats(...))", lastN)
    return {r["key"].split("-")[0]: r for r in lst(rows)}


def sync(w, *cls):
    for x in cls:
        x.eval("ns.Sync:SendHello(true)")
        w.tick(1)
    w.tick(40)


def team_and_raid(w, c, t_offset=60, nights=None):
    """Team T1 (Tank, Heal, Dps in the 25 lineup, Kai + Tank in Kara A) and a Gruul raid for it starting soon."""
    bob = c["Bob"]
    tid = save_team(bob, "T1", ["Tank", "Heal", "Dps", "Kai"], lineups=[
        {"name": "Main", "size": 25, "groups": {"Tank": 1, "Heal": 1, "Dps": 2}},
        {"name": "Kara A", "size": 10, "groups": {"Kai": 1, "Tank": 1}}], nights=nights)
    w.tick(2)
    occ = create(bob, i="gruul", t=now(bob) + t_offset, tm=[tid])
    w.tick(3)
    return tid, occ


# Injected records (the arithmetic without a live raid): pieces in minutes after `base`.
INJECT = """
local base, recs = ...
local g = ns.Guild:GetGuildKey()
for _, r in ipairs(recs) do
    local att = {}
    for name, a in pairs(r.att or {}) do
        local s = {}
        for i, m in ipairs(a.s or {}) do s[i] = base + m * 60 end
        att[name] = { j = s[1], l = s[#s], k = 0, s = #s > 0 and s or nil, b = a.b, c = a.c }
    end
    local ex = {}
    for name, kind in pairs(r.ex or {}) do ex[name] = kind end
    ns.db.raids[r.id] = { id = r.id, g = g, start = base + (r.start or 0) * 60, stop = base + r.stop * 60,
        zone = r.zone or 'Karazhan', att = att, bosses = {}, pl = r.pl, plAt = base, ex = next(ex) and ex or nil,
        exAt = base, ef = base + (r.ef or 0) * 60, et = r.et and (base + r.et * 60) or nil, endedBy = 'x',
        dc = r.dc, rs = r.rs, mk = r.mk }
end
ns:Fire('RAIDLOG_CHANGED')
"""


def inject(cl, base, recs):
    fixed = []
    for r in recs:
        r = dict(r)
        r["att"] = {K(n): a for n, a in r.get("att", {}).items()}
        r["ex"] = {K(n): k for n, k in r.get("ex", {}).items()}
        fixed.append(r)
    cl.eval(INJECT, base, fixed)


# ------------------------------------------------------------------------------------------------------------------
@case
def a_team_raid_expects_its_own_lineup_only():
    w, c = world()
    bob = c["Bob"]
    tid, occ = team_and_raid(w, c)
    # Kai is only in the Kara A (10) lineup: not expected at the 25-man Gruul raid
    w.make_raid([bob, c["Tank"], c["Heal"], c["Dps"]], leader=bob)
    w.tick(4)
    rid = start(w, c, occ=occ)
    for x in (bob, c["Tank"]):
        r = rec(x, rid)
        assert r["pl"] == occ and r.get("ex") == {K("Tank"): "l", K("Heal"): "l", K("Dps"): "l"}, (x.name, r.get("ex"))
    # a raid without a team: whoever answered Accept (not Tentative, not guests)
    occ2 = create(bob, i="kara", t=now(bob) + 3 * HOUR)
    w.tick(2)
    signup(c["Rita"], occ2, "A")
    signup(c["Sam"], occ2, "T")
    w.tick(3)
    ex = bob.eval_py("local r = { pl = ... }; ns.Attendance:Snapshot(r); return r.ex", occ2)
    assert ex == {K("Rita"): "a"}, ex
    # a team raid whose team has no lineup of that size: only Accept answers
    occ3 = create(bob, i="kara", t=now(bob) + 5 * HOUR, tm=[save_team(bob, "T2", ["Sam", "Rita"], lineups=[
        {"name": "Big", "size": 25, "groups": {"Sam": 1, "Rita": 1}}])])
    w.tick(3)
    signup(c["Sam"], occ3, "A")
    w.tick(3)
    ex = bob.eval_py("local r = { pl = ... }; ns.Attendance:Snapshot(r); return r.ex", occ3)
    assert ex == {K("Sam"): "a"}, ex


@case
def late_left_early_and_a_fill_in_live():
    w, c = world()
    bob, tank, heal, dps, sam, olly = c["Bob"], c["Tank"], c["Heal"], c["Dps"], c["Sam"], c["Olly"]
    tid, occ = team_and_raid(w, c, t_offset=60)
    w.make_raid([bob, tank, heal], leader=bob)
    w.tick(4)
    rid = start(w, c, occ=occ)
    wait(w, 40 * MIN)                       # Dps is 40 minutes late
    w.make_raid([bob, tank, heal, dps], leader=bob)
    wait(w, 80 * MIN)
    w.make_raid([bob, tank, dps], leader=bob)   # Heal leaves two hours in
    wait(w, 5 * MIN)
    w.make_raid([bob, tank, dps, sam], leader=bob)  # Sam fills in
    wait(w, 55 * MIN)
    end(w, c)
    t = result(bob, occ, "Tank")
    assert t["credit"] >= 0.99 and t["counts"] and not t["review"], t
    d = result(bob, occ, "Dps")
    assert 36 * MIN <= d["late"] <= 41 * MIN and 0.7 < d["credit"] < 0.85, (d["late"], d["credit"])
    h = result(bob, occ, "Heal")
    assert h["left"] > 55 * MIN and h["review"] and h["pending"] and not h["counts"], h
    res = bob.eval_py("local n = ns.Attendance:GetNight(...); local r = ns.Attendance:NightResults(n); "
                      "return { h = r.helpers, e = r.expected }", occ)
    helpers = {x["key"]: x for x in lst(res["h"])}
    assert K("Sam") in helpers and helpers[K("Sam")]["forKey"] == K("Heal"), helpers
    assert K("Bob") not in [x["key"] for x in lst(res["e"])]          # the leader wasn't expected (not in the lineup)
    rv = bob.eval_py("return ns.Attendance:GetReviews()")
    assert [r["key"] for r in lst(rv["pending"])] == [K("Heal")], rv
    # nothing counts until decided: Heal has no attendance yet; Excuse makes it 100%
    s = stats(bob)
    assert s["Heal"].get("pct") is None and s["Heal"]["pending"] == 1, s["Heal"]
    # a member can't decide
    assert tank.eval_py("local ok, e = ns.Attendance:Decide(...); return { ok = ok, e = e }", occ, K("Heal"), "x")["ok"] is False
    assert bob.eval("return (ns.Attendance:Decide(...))", occ, K("Heal"), "x", "power cut")
    s = stats(bob)
    assert s["Heal"]["pct"] == 100 and s["Heal"]["excused"] == 1, s["Heal"]
    assert s["Sam"]["fills"] == 1 and s["Sam"].get("pct") is None, s["Sam"]
    # the officer (not on any list) gets the raid log and the decision
    sync(w, bob, olly)
    s = stats(olly)
    assert s.get("Heal") and s["Heal"]["pct"] == 100, s.get("Heal")
    assert olly.eval("return ns.Attendance:CanReview()") and olly.eval("return ns.Guild:AmIRaidLogReader()")
    assert not olly.eval("return ns.Guild:AmIRaidLogMember()")        # (not the other raid log rights)


@case
def disconnects_short_ignored_long_counted_and_no_shows():
    w, c = world()
    bob = c["Bob"]
    base = now(bob) - 6 * HOUR
    inject(bob, base, [{"id": "r1", "pl": "occA", "stop": 210, "ex": {"Tank": "l", "Heal": "l", "Dps": "l", "Kai": "l"},
                        "att": {"Tank": {"s": [0, 100, 106, 210]},        # 6 min offline: ignored
                                "Heal": {"s": [0, 100, 125, 210]},        # 25 min: counted
                                "Kai": {"s": [2, 210]}}}])                # (Dps never came)
    t, h, d, k = (result(bob, "occA", n) for n in ("Tank", "Heal", "Dps", "Kai"))
    assert t["credit"] >= 0.99 and t["away"] == 0, t
    assert abs(h["away"] - 25 * MIN) < 60 and 0.85 < h["credit"] < 0.9, h
    assert d["noShow"] and d["credit"] == 0 and d["counts"] and not d["review"], d
    assert k["credit"] >= 0.99 and k["late"] == 0, k                  # (2 min late: inside the on-time margin)
    s = stats(bob)
    assert s["Dps"]["noShows"] == 1 and s["Dps"]["pct"] == 0 and s["Dps"]["codes"][0] == "N", s["Dps"]


@case
def server_trouble_is_excused_for_everyone():
    w, c = world()
    bob = c["Bob"]
    base = now(bob) - 6 * HOUR
    names = ("Tank", "Heal", "Dps", "Kai")
    inject(bob, base, [{"id": "r1", "pl": "occT", "stop": 180, "ex": {n: "l" for n in names},
                        "att": {n: {"s": [0, 60 + i, 90 + i, 180]} for i, n in enumerate(names)}}])
    for n in names:
        r = result(bob, "occT", n)
        assert r["credit"] >= 0.99 and r["away"] == 0, (n, r)


@case
def reviews_reasons_and_picked_chat_lines():
    w, c = world()
    bob, heal, olly, tank = c["Bob"], c["Heal"], c["Olly"], c["Tank"]
    tid, occ = team_and_raid(w, c)
    w.make_raid([bob, tank, heal, c["Dps"]], leader=bob)
    w.tick(4)
    rid = start(w, c, occ=occ)
    wait(w, 30 * MIN)
    heal.eval("SendChatMessage('sorry guys power is flickering', 'RAID')")
    w.tick(2)
    heal.eval("SendChatMessage('power went out :( back sunday', 'WHISPER', nil, 'Bob')")
    w.tick(2)
    lines = lst(bob.eval_py("return ns.Attendance:GetChat(..., GetServerTime() - 600, GetServerTime() + 60)", K("Heal")))
    assert [(l["ch"], l["t"], l["likely"]) for l in lines] == [
        ("Raid", "sorry guys power is flickering", True), ("Whisper", "power went out :( back sunday", True)], lines
    # Heal leaves: the leader hears it (prompt event); Heal's own reason reaches the leader's record
    bob.eval("ATT_LEFT = nil; ns:On('ATTENDANCE_PLAYER_LEFT', function(_, rid, key) ATT_LEFT = key end)")
    w.make_raid([bob, tank, c["Dps"]], leader=bob)
    wait(w, 2 * MIN)
    assert bob.eval("return ATT_LEFT") == K("Heal")
    assert heal.eval("return ns.Attendance:SendReason(..., 'life', 'power went out')", rid)
    w.tick(3)
    assert rec(bob, rid)["rs"][K("Heal")]["c"] == "life", rec(bob, rid).get("rs")
    # the leader keeps both chat lines (two lines at once), every recorder gets them
    assert bob.eval_py("local ok = ns.Attendance:Pick(..., select(2, ...), select(3, ...)); return ok", occ, K("Heal"),
                       [{"t": l["t"], "ch": l["ch"], "at": l["at"]} for l in lines])
    w.tick(3)
    q = rec(tank, rid)["q"][K("Heal")]
    assert [l["t"] for l in lst(q["l"])] == ["sorry guys power is flickering", "power went out :( back sunday"], q
    # the leader's mark: Bob benched Dps for a fight (full credit), every recorder has it
    assert bob.eval("return ns.Attendance:LeaderMark(...)", K("Dps"), "b")
    w.tick(3)
    assert rec(tank, rid)["mk"][K("Dps")]["b"] is True
    wait(w, 30 * MIN)
    end(w, c)
    h = result(bob, occ, "Heal")
    assert h["pending"] and h["reason"]["c"] == "life" and len(lst(h["picked"]["l"])) == 2, h
    d = result(bob, occ, "Dps")
    assert d["bench"] and d["credit"] == 1 and not d["review"], d
    # a decision forged by a member never lands at merge
    sync(w, bob, olly)
    heal.eval("local r = ns.RaidLog:GetRaid(...); r.dc = { [select(2, ...)] = { d = 'x', by = select(2, ...), at = GetServerTime() } }",
              rid, K("Heal"))
    merged = olly.eval_py("local r = ns.RaidLog:GetRaid(...); local copy = {}; for k, v in pairs(r) do copy[k] = v end; "
                          "copy.dc = { [select(2, ...)] = { d = 'x', by = select(2, ...), at = GetServerTime() } }; "
                          "copy.g = nil; ns.RaidLog:MergeRecord(copy, select(2, ...)); return ns.RaidLog:GetRaid(...).dc", rid, K("Heal"))
    assert not merged or K("Heal") not in merged, merged


@case
def away_periods_excuse_every_raid_in_them():
    w, c = world()
    bob, tank = c["Bob"], c["Tank"]
    base = now(bob) - 10 * 86400
    inject(bob, base, [
        {"id": "r1", "pl": "o1", "start": 0, "ef": 0, "stop": 180, "ex": {"Tank": "l", "Heal": "l"}, "att": {"Heal": {"s": [0, 180]}}},
        {"id": "r2", "pl": "o2", "start": 3 * 1440, "ef": 3 * 1440, "stop": 3 * 1440 + 180, "ex": {"Tank": "l", "Heal": "l"},
         "att": {"Heal": {"s": [3 * 1440, 3 * 1440 + 180]}}},
        {"id": "r3", "pl": "o3", "start": 8 * 1440, "ef": 8 * 1440, "stop": 8 * 1440 + 180, "ex": {"Tank": "l", "Heal": "l"},
         "att": {"Heal": {"s": [8 * 1440, 8 * 1440 + 180]}}}])
    assert stats(bob)["Tank"]["pct"] == 0
    res = bob.eval_py("local ok, n = ns.Attendance:ExcusePeriod(...); return { ok = ok, n = n }", K("Tank"),
                      base - 3600, base + 4 * 86400, "holiday")
    assert res["ok"] is True and res["n"] == 2, res
    s = stats(bob)["Tank"]
    assert s["excused"] == 2 and s["noShows"] == 1 and s["pct"] == 67, s
    assert not tank.eval("return (ns.Attendance:ExcusePeriod(...))", K("Tank"), base, base + 86400)
    # the dialog: click the first day, then the last, Excuse
    inject(bob, base - 20 * 86400, [{"id": "r9", "pl": "o9", "stop": 180, "ex": {"Heal": "l"}, "att": {}}])
    bob.eval("ns.AttendanceUI:OpenAwayDialog(...)", K("Heal"))
    bob.eval("local f = DisasterZoneAttendanceAway; local d = date('*t', ...); local day = time({ year = d.year, "
             "month = d.month, day = d.day, hour = 0 }); f.pick(day - 86400); f.pick(day + 86400)", base - 20 * 86400)
    assert "1 logged raid" in strip_codes(bob.eval("return DisasterZoneAttendanceAway.sum:GetText()"))
    bob.click(bob.eval("return DisasterZoneAttendanceAway.ok"))
    w.tick(0.5)
    assert result(bob, "o9", "Heal")["excused"]
    assert not bob.eval("return DisasterZoneAttendanceAway:IsShown()")


@case
def a_raid_without_a_team_never_beats_the_team_raid():
    w, c = world()
    bob = c["Bob"]
    base = now(bob) - 6 * HOUR
    inject(bob, base, [
        {"id": "team", "pl": "oT", "stop": 210, "ex": {"Tank": "l", "Heal": "l"}, "att": {"Tank": {"s": [0, 210]}, "Heal": {"s": [0, 210]}}},
        {"id": "pug", "pl": "oP", "stop": 200, "ex": {"Tank": "a", "Rita": "a"}, "att": {"Rita": {"s": [0, 200]}}}])
    rows = bob.eval_py("local res = ns.Attendance:Results(ns.Attendance:ClosedNights()); local out = {}; "
                       "for _, it in ipairs(res) do out[it.night.key] = it.results[...] end; return out", K("Tank"))
    assert rows["oP"].get("kind") is None and rows["oP"].get("clash"), rows["oP"]
    assert rows["oT"]["counts"] and rows["oT"]["credit"] >= 0.99, rows["oT"]
    assert stats(bob)["Tank"]["pct"] == 100 and stats(bob)["Tank"]["clashes"] == 1
    # skipping the team raid for another guild raid at the same time: excused unless an officer says it counts
    inject(bob, base - 7 * 86400, [
        {"id": "team2", "pl": "oT2", "stop": 210, "ex": {"Heal": "l"}, "att": {}},
        {"id": "kara2", "pl": "oK2", "stop": 200, "ex": {"Rita": "a"}, "att": {"Heal": {"s": [0, 200]}, "Rita": {"s": [0, 200]}}}])
    r = bob.eval_py("local res = ns.Attendance:Results(ns.Attendance:ClosedNights()); for _, it in ipairs(res) do "
                    "if it.night.key == 'oT2' then return it.results[...] end end", K("Heal"))
    assert r["excused"] and r["otherRaid"], r


@case
def the_team_night_sets_the_planned_end():
    w, c = world()
    bob = c["Bob"]
    t0 = now(bob) + 2 * HOUR
    # the team raids at the raid's start time for 3 hours (realm time = my clock here)
    w_min = bob.eval("local t = date('*t', ...); return ((t.wday + 5) % 7) * 1440 + t.hour * 60 + t.min", t0)
    tid = save_team(bob, "T1", ["Tank"], lineups=[{"name": "Main", "size": 25, "groups": {"Tank": 1}}],
                    nights=[{"w": (w_min // 15) * 15, "m": 180}])
    w.tick(2)
    occ = create(bob, i="gruul", t=t0, tm=[tid])
    w.tick(2)
    r = bob.eval_py("local r = { pl = ... }; ns.Attendance:Snapshot(r); return r", occ)
    assert r["ex"] == {K("Tank"): "l"} and r["ef"] == t0, r
    assert abs(r["et"] - (t0 - (t0 % 900 if False else 0) + 180 * 60)) <= 15 * 60, (r["et"] - t0)
    # leaving after the planned end is never early
    base = now(bob) - 8 * HOUR
    inject(bob, base, [{"id": "r1", "pl": "oE", "stop": 240, "et": 180, "ex": {"Tank": "l"}, "att": {"Tank": {"s": [0, 185]}}}])
    t = result(bob, "oE", "Tank")
    assert t["left"] == 0 and t["credit"] >= 0.99 and not t["review"], t


@case
def the_gm_sets_the_margins():
    w, c = world()
    gina, bob, olly = c["Gina"], c["Bob"], c["Olly"]
    assert bob.eval_py("return ns.Guild:GetAttendanceRules()") == {"o": 5, "d": 10}
    assert olly.eval_py("local ok, e = ns.Guild:SetAttendanceRules(1, 1); return { ok = ok, e = e }")["ok"] is False
    assert gina.eval("return (ns.Guild:SetAttendanceRules(10, 20))")
    w.tick(3)
    assert bob.eval_py("return ns.Guild:GetAttendanceRules()") == {"o": 10, "d": 20}
    # (a 15 min disconnect is now ignored)
    base = now(bob) - 6 * HOUR
    inject(bob, base, [{"id": "r1", "pl": "oM", "stop": 180, "ex": {"Tank": "l"}, "att": {"Tank": {"s": [0, 60, 75, 180]}}}])
    assert result(bob, "oM", "Tank")["credit"] >= 0.99
    # the raid leaders list itself is kept
    assert bob.eval_py("return ns.Guild:GetRaidLeaders()") == {1: K("Bob")} or \
        lst(bob.eval_py("return ns.Guild:GetRaidLeaders()")) == [K("Bob")]


@case
def members_get_their_own_attendance_from_a_reader():
    w, c = world()
    bob, dps = c["Bob"], c["Dps"]
    base = now(bob) - 6 * HOUR
    inject(bob, base, [{"id": "r1", "pl": "oX", "stop": 200, "ex": {"Dps": "l", "Tank": "l"},
                        "att": {"Dps": {"s": [20, 200]}, "Tank": {"s": [0, 200]}}}])
    want = stats(bob)["Dps"]["pct"]
    assert want == 90, want
    assert not dps.eval("return ns.Attendance:CanSeeAll()")
    for x in c.values():
        if x.name not in ("Bob", "Dps"):
            x.logout()          # only Bob can answer
    w.tick(2)
    assert dps.eval("return ns.Attendance:RequestMine()")
    w.tick(5)
    mine = dps.eval_py("return ns.Attendance:GetMine()")
    assert mine and mine["p"] == want and lst(mine["h"])[0]["c"] == 90, mine


@case
def digests_compare_without_the_new_fields_with_older_clients():
    w, c = world()
    bob = c["Bob"]
    base = now(bob) - 6 * HOUR
    inject(bob, base, [{"id": "r1", "pl": "oD", "stop": 200, "ex": {"Tank": "l"}, "att": {"Tank": {"s": [0, 200]}}}])
    legacy = bob.eval_py("return ns.RaidLog:GetDigest(true)")
    full = bob.eval_py("return ns.RaidLog:GetDigest()")
    assert full.get("v") == 2 and "v" not in legacy, (full, legacy)
    bob.eval("local r = ns.RaidLog:GetRaid('r1'); r.dc = { [...] = { d = 'x', by = ..., at = GetServerTime() } }", K("Bob"))
    assert bob.eval_py("return ns.RaidLog:GetDigest(true)") == legacy
    assert bob.eval_py("return ns.RaidLog:GetDigest()") != full


@case
def pugs_are_never_expected_and_unlinked_raids_have_no_planned_time():
    """In-game report 2026-10-11: pugs listed as no-shows / left early, and Gruul + Mag nights where the pugs left
    after Mag counted as leaving early on a raid that wasn't linked to a planned raid."""
    w, c = world()
    bob = c["Bob"]
    base = now(bob) - 6 * HOUR
    inject(bob, base, [{"id": "r1", "stop": 200, "att": {"Tank": {"s": [0, 200]}, "Heal": {"s": [0, 60]},
                                                          "Pugone": {"s": [0, 70]}, "Pugtwo": {"s": [0, 200]}}}])
    bob.eval("ns.db.raids.r1.su = { [...] = 'A', [select(2, ...)] = 'A' }; ns.db.raids.r1.pl = 'old'; ns.db.raids.r1.plAt = 1; "
             "ns:Fire('RAIDLOG_CHANGED')", K("Pugthree"), K("Dps"))
    res = bob.eval_py("local n = ns.Attendance:GetNight('old'); local r = ns.Attendance:NightResults(n); "
                      "local function keys(l) local o = {} for _, x in ipairs(l) do o[#o + 1] = x.key end return o end; "
                      "return { e = keys(r.expected), h = keys(r.helpers), g = keys(r.guests) }")
    assert sorted(lst(res["e"])) == sorted([K("Tank"), K("Heal"), K("Dps")]), res
    assert sorted(lst(res["g"])) == sorted([K("Pugone"), K("Pugtwo")]) and not lst(res.get("h")), res
    h = result(bob, "old", "Heal")
    assert h["credit"] == 1 and h["loose"] and not h["review"], h        # left after the first part: still there
    d = result(bob, "old", "Dps")
    assert d["noShow"] and d["credit"] == 0, d                           # answered Accept, never came
    s = stats(bob)
    assert "Pugone" not in s and "Pugthree" not in s and s["Heal"]["pct"] == 100, sorted(s)


@case
def the_raid_log_pages_decide_and_pick_by_clicks():
    w, c = world()
    bob = c["Bob"]
    base = now(bob) - 6 * HOUR
    inject(bob, base, [{"id": "r1", "pl": "oU", "stop": 200, "ex": {"Tank": "l", "Heal": "l"},
                        "att": {"Tank": {"s": [0, 200]}, "Heal": {"s": [0, 120]}}}])
    bob.eval("ns.Attendance:NoteChat(..., 'Raid', 'gtg sorry, kid woke up', select(2, ...))", K("Heal"), base + 119 * 60)
    bob.slash("/dz raids")
    w.tick(0.3)
    bob.eval("ns.RaidsUI:SetMode('reviews')")
    w.tick(0.5)
    P = "ns.RaidsUI:GetPanel()"
    assert bob.eval("return " + P + ".reviewsBtn:IsShown()")
    card = bob.eval("local f; " + P + ".reviews.list.box:ForEachFrame(function(r) if r.cdlR and r.card:IsShown() then f = r end end); return f")
    assert card, "a review card"
    # Pick from chat: the likely line is ticked; Use keeps it
    bob.click(bob.eval("return (...).card.pick", card))
    w.tick(0.3)
    picker = "DisasterZoneAttendancePicker"
    assert bob.eval("return " + picker + ":IsShown()")
    assert bob.eval("return " + picker + ".rows[1].picked") is True
    bob.click(bob.eval("return " + picker + ".use"))
    w.tick(0.5)
    assert lst(result(bob, "oU", "Heal")["picked"]["l"])[0]["t"] == "gtg sorry, kid woke up"
    # Excuse on the card decides it
    card = bob.eval("local f; " + P + ".reviews.list.box:ForEachFrame(function(r) if r.cdlR and r.card:IsShown() then f = r end end); return f")
    bob.click(bob.eval("return (...).card.excuse", card))
    w.tick(0.5)
    r = result(bob, "oU", "Heal")
    assert r["excused"] and r["decision"]["by"] == K("Bob"), r
    # the overview lists them; a click opens the page
    bob.eval("ns.RaidsUI:SetMode('players')")
    w.tick(0.5)
    row = bob.eval("local want, f = ...; " + P + ".overview.list.box:ForEachFrame(function(r) if r.cdlS and r.cdlS.key == want then f = r end end); return f",
                   K("Heal"))
    bob.click(row)
    w.tick(0.5)
    assert bob.eval("return ns.RaidsUI:GetAttendancePlayer()") == K("Heal")
    assert bob.eval("return " + P + ".playerPage.banner.big:GetText()") == "100%"
    w.assert_no_errors()


@case
def reviewers_get_a_notification_members_dont():
    w, c = world()
    bob, tank = c["Bob"], c["Tank"]
    base = now(bob) - 6 * HOUR
    for x in (bob, tank):
        inject(x, base, [{"id": "r1", "pl": "oN", "stop": 200, "ex": {"Tank": "l", "Heal": "l"},
                          "att": {"Tank": {"s": [0, 200]}, "Heal": {"s": [0, 120]}}}])
        x.eval("ns.Notify:Refresh('attReview')")
    w.tick(1)
    items = lst(bob.eval_py("return ns.Notify:List({ kind = 'attReview' })"))
    assert len(items) == 1 and items[0]["n"] == 1 and "Heal" in strip_codes(items[0]["title"]), items
    assert lst(tank.eval_py("return ns.Notify:List({ kind = 'attReview' })")) == []
    bob.eval("ns.Attendance:Decide('oN', ..., 'c')", K("Heal"))
    bob.eval("ns.Notify:Refresh('attReview')")
    w.tick(1)
    assert lst(bob.eval_py("return ns.Notify:List({ kind = 'attReview' })")) == []


@case
def a_main_who_came_on_an_alt_is_there_and_listed_once():
    """In-game report 2026-10-11: Grumpykat answered Accept and came on Saltykim (same player): Grumpykat was a
    no-show and the two had their own rows."""
    w, c = world()
    bob = c["Bob"]
    # Sam is Dps's alt (the Members tab's main / alt link)
    bob.eval("local alt, main = ...; local P = ns.Professions; local old = P.GetMain; "
             "P.GetMain = function(self, k) if k == alt then return main end return old(self, k) end", K("Sam"), K("Dps"))
    base = now(bob) - 6 * HOUR
    inject(bob, base, [{"id": "r1", "stop": 200, "att": {"Tank": {"s": [0, 200]}, "Sam": {"s": [0, 200]}}}])
    bob.eval("ns.db.raids.r1.su = { [...] = 'A' }; ns.db.raids.r1.pl = 'oA'; ns.db.raids.r1.plAt = 1; "
             "ns:Fire('RAIDLOG_CHANGED')", K("Dps"))
    keys = lst(bob.eval_py("local n = ns.Attendance:GetNight('oA'); local o = {}; for _, r in ipairs(ns.Attendance:NightResults(n).expected) do "
                           "o[#o + 1] = r.key end; return o"))
    assert sorted(keys) == sorted([K("Tank"), K("Dps")]), keys
    d = result(bob, "oA", "Dps")
    assert not d["noShow"] and d["credit"] == 1, d
    s = stats(bob)
    assert "Sam" not in s and s["Dps"]["pct"] == 100 and s["Dps"]["noShows"] == 0, sorted(s)
    assert bob.eval("return (ns.RaidLog:GetAttendance(...))", K("Sam")) == 100     # (asked by the alt: the player's)
    # a team raid: the lineup character came on the alt
    inject(bob, base - 86400, [{"id": "r2", "pl": "oB", "stop": 200, "ex": {"Dps": "l", "Tank": "l"},
                                "att": {"Tank": {"s": [0, 200]}, "Sam": {"s": [5, 200]}}}])
    d = result(bob, "oB", "Dps")
    assert d["credit"] >= 0.99 and not d["noShow"], d


@case
def the_guest_book_shows_a_combined_run_as_one_night():
    """In-game report 2026-10-11: a Gruul + Mag run logged as two raids showed as two rows, and the planned raid as
    the guest's Next raid after it had happened."""
    w, c = world()
    bob = c["Bob"]
    occ = create(bob, i="gruul", ix=["mag"], t=now(bob) - 3000, ti="Spark run")
    w.tick(2)
    assert bob.eval_py("local ok, e = ns.RaidPlan:AddGuest(..., 'Pugone', 'SHAMAN'); return { ok = ok, e = e }", occ)["ok"] is True
    w.tick(2)
    base = now(bob) - 3000
    inject(bob, base, [{"id": "g1", "pl": occ, "stop": 60, "zone": "Gruul's Lair", "att": {"Tank": {"s": [0, 60]}}},
                       {"id": "g2", "pl": occ, "start": 70, "ef": 0, "stop": 120, "zone": "Magtheridon's Lair",
                        "att": {"Tank": {"s": [70, 120]}}}])
    bob.eval("for _, id in ipairs({ 'g1', 'g2' }) do ns.db.raids[id].su = { [...] = 'A' } end; ns:Fire('RAIDLOG_CHANGED'); "
             "if ns.GuestBook.Invalidate then ns.GuestBook:Invalidate() end", K("Pugone"))
    e = bob.eval_py("return ns.GuestBook:GetEntry(...)", K("Pugone"))
    zones = lst(e["zones"])
    assert len(zones) == 1 and zones[0]["noShow"] and "Spark run" in zones[0]["zone"], zones
    assert e["noShows"] == 1 and not e.get("next"), e


@case
def the_raid_log_shows_a_combined_run_as_one_card():
    """In-game report 2026-10-11: a Mag + Gruul run linked to one planned raid showed as two cards."""
    w, c = world()
    bob = c["Bob"]
    occ = create(bob, i="gruul", ix=["mag"], t=now(bob) - 3000, ti="Spark run")
    w.tick(2)
    base = now(bob) - 3000
    inject(bob, base, [{"id": "m1", "pl": occ, "stop": 50, "zone": "Magtheridon's Lair", "ex": {"Tank": "l"}, "att": {"Tank": {"s": [0, 50]}}},
                       {"id": "g1", "pl": occ, "start": 60, "ef": 0, "stop": 110, "zone": "Gruul's Lair", "ex": {"Tank": "l"},
                        "att": {"Tank": {"s": [60, 110]}}}])
    bob.slash("/dz raids")
    w.tick(0.3)
    bob.eval("ns.RaidsUI:Select('m1')")
    w.tick(0.5)
    rows = lst(bob.eval_py("local out = {}; for _, d in ipairs(ns.RaidsUI:GetPanel().raidList.data) do "
                           "out[#out + 1] = { id = d.rec.id, zone = d.rec.zone, n = d.rec.ids and #d.rec.ids or 1 } end; return out"))
    mine = [r for r in rows if r["n"] == 2]
    assert len(mine) == 1 and "Spark run" in mine[0]["zone"], rows
    assert bob.eval("return ns.RaidsUI:GetPanel().banner.title:GetText()").startswith("Spark run")
    t = result(bob, occ, "Tank")
    assert t["credit"] >= 0.99 and t["away"] == 0, t                      # (nothing was logged between the two)
    # a longer break between the two logs (nobody recorded) never counts against anyone
    inject(bob, base - 86400, [{"id": "m2", "pl": "oGap", "stop": 50, "ex": {"Tank": "l"}, "att": {"Tank": {"s": [0, 50]}}},
                               {"id": "g2", "pl": "oGap", "start": 95, "ef": 0, "stop": 150, "ex": {"Tank": "l"},
                                "att": {"Tank": {"s": [95, 150]}}}])
    t2 = result(bob, "oGap", "Tank")
    assert t2["credit"] >= 0.99 and t2["away"] == 0, t2
    # the session button stays off the Attendance page (its filters need the row)
    bob.eval("ns.RaidsUI:SetMode('players')")
    w.tick(0.3)
    assert not bob.eval("return ns.RaidsUI:GetPanel().sessionBtn:IsShown()")


if __name__ == "__main__":
    run_all(globals())

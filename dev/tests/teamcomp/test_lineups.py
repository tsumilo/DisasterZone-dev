"""Raids > Teams, lineups and waitlists (1.3.2, user decisions 2026-10-06), on the real addon.

Covers: a team's lineups (one roster, any number of 10- and 25-player lineups with their own groups, specs and target
comp) saved, synced and mirrored for older clients, a team saved before 1.3.2 read as one lineup, bad lineups refused
whole; Unassigned (on the roster, in none of the lineup's groups) and the waitlist never counting for the comp, its
raid buffs or "the team as it is", and both listed first among who could fill a slot; players putting themselves on
a waitlist and taking themselves off, the order (first in line first, kept when the spec changes, the end when they
come back), the GM / council taking anyone off and moving them, forged entries ignored, a late login catching up,
the blacklist; saving the roster taking its new members off the waitlists; raids using a lineup of their size (the
first by default, or the one they name) for their starting groups, open slots, the team's next raid and LF line,
inviting the players in its groups (the roster without such a lineup, or with nobody in its groups), never the
waitlist; an older client's copies and edits (the lineups kept); the Teams page (lineup chips,
a new lineup, rename, the waitlist pool, Join, a waitlisted player dragged into a group and saved).

Run: luaenv\\Scripts\\python.exe tests\\teamcomp\\test_lineups.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "raidplan"))

from rp_common import World, Client, gm_pick, set_raid_leaders, K, DAY, now, create, signup, call  # noqa: E402
from _common import case, run_all, strip_codes  # noqa: E402

# Gina = GM, Bob = guild council + raid leader; the others are members.
NAMES = (("Gina", 0, "PALADIN"), ("Bob", 2, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE"))
STD25 = {"WARRIOR": [0, 1, 1], "PALADIN": [2, 1, 1], "HUNTER": [0, 1, 1], "ROGUE": [0, 2], "PRIEST": [0, 1, 1],
         "SHAMAN": [1, 2, 2], "MAGE": [1, 1], "WARLOCK": [1, 0, 1], "DRUID": [1, 1, 1, 1]}
KARA10 = {"WARRIOR": [0, 0, 1], "PALADIN": [1, 1], "HUNTER": [0, 1], "ROGUE": [0, 1], "PRIEST": [0, 1],
          "SHAMAN": [0, 1], "MAGE": [0, 1], "WARLOCK": [0, 0, 1], "DRUID": [0, 0, 0, 1]}
ROOT = "ns.db.raidplan[ns.Guild:GetGuildKey()]"
P = "ns.RaidsUI:GetPanel()"
TV = P + ".teams"
D = TV + ".detail"


def world(names=NAMES):
    w = World()
    c = {}
    for name, rank, cls in names:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ("Bob",))
    w.tick(2)
    return w, c


def lst(v):
    """A Lua array as Python returns it (a list, or a dict for a sparse / empty table)."""
    if v is None:
        return []
    return list(v.values()) if isinstance(v, dict) else list(v)


def save(cl, name, members, lineups=None, tid=None, **opts):
    """SaveTeam with opts.lineups = [{name, size, specs {name: sp}, groups {name: g}, comp, id}] or the one-lineup
    opts (size, specs, groups, comp, ln)."""
    o = {}
    if lineups is not None:
        out = []
        for l in lineups:
            e = {k: v for k, v in l.items() if k in ("id", "name", "size", "comp")}
            if "specs" in l:
                e["specs"] = {K(n): sp for n, sp in l["specs"].items()}
            if "groups" in l:
                e["groups"] = {K(n): g for n, g in l["groups"].items()}
            out.append(e)
        o["lineups"] = out
    for k in ("size", "comp", "ln"):
        if k in opts:
            o[k] = opts[k]
    if "groups" in opts:
        o["groups"] = {K(n): g for n, g in opts["groups"].items()}
    if "specs" in opts:
        o["specs"] = {K(n): sp for n, sp in opts["specs"].items()}
    return cl.eval_py("local id, n, m, o = ...; local ok, r = ns.RaidPlan:SaveTeam(id, n, m, o); return { ok = ok, r = r }",
                      tid, name, [K(m) for m in members], o)


def team(cl, *args, **opts):
    res = save(cl, *args, **opts)
    assert res["ok"] is True, res
    return res["r"]


def get_team(cl, tid):
    return cl.eval_py("return ns.RaidPlan:GetTeam(...)", tid)


def lineups(cl, tid):
    t = get_team(cl, tid)
    return lst(t["lineups"]) if t else []


def ln_id(cl, tid, i):
    return lineups(cl, tid)[i]["id"]


def rp(cl, fn, *args):
    return cl.eval_py("local fn = ...; return (ns.RaidPlan[fn](ns.RaidPlan, select(2, ...)))", fn, *args)


def ok_err(cl, fn, *args):
    return cl.eval_py("local fn = ...; local ok, e = ns.RaidPlan[fn](ns.RaidPlan, select(2, ...)); "
                      "return { ok = ok and true or false, e = e }", fn, *args)


def waitlist(cl, tid, ln=None):
    return [(e["key"], e.get("sp"), e["n"]) for e in lst(rp(cl, "GetWaitlist", {"id": tid, "ln": ln} if ln else tid))]


def keys(entries):
    return [e["key"] for e in lst(entries)]


def open_teams(w, cl, tid=None):
    cl.slash("/dz raids")
    w.tick(0.5)
    cl.eval("ns.RaidsUI:SetView('teams')")
    if tid:
        cl.eval("ns.RaidPlanUI:SelectTeam(...)", tid)
    elif cl.eval("return ns.RaidPlanUI:IsTeamBoard()"):
        cl.eval("ns.RaidPlanUI:SelectTeam(ns.RaidPlanUI:GetSelectedTeam())")
    w.tick(0.3)


def shown(cl, expr):
    return cl.eval("local f = %s; return f ~= nil and f:IsShown() and f:IsVisible()" % expr) is True


def lineup_chips(cl):
    rows = cl.eval_py("local out = {}; for _, c in ipairs(%s.lcards) do if c:IsShown() then out[#out + 1] = "
                      "{ c.name:GetText(), c.chosen } end end; return out" % D) or []
    return [tuple(r) for r in lst(rows)]


# ------------------------------------------------------------------------------------------------------------------
@case
def lineups_are_saved_synced_and_mirrored():
    w, c = world()
    bob, rita, lee = c["Bob"], c["Rita"], c["Lee"]
    tid = team(bob, "Main", ["Lee", "Rita", "Sam"], [
        {"name": "SSC", "size": 25, "groups": {"Lee": 1, "Rita": 2}, "specs": {"Lee": 3}, "comp": STD25},
        {"name": "Kara A", "size": 10, "groups": {"Lee": 1}, "specs": {"Lee": 2}, "comp": KARA10},
        {"size": 10, "groups": {"Rita": 2, "Gina": 1}}])                     # (Gina isn't on the roster: dropped)
    w.tick(2)
    for n, x in c.items():
        ls = lineups(x, tid)
        assert [(l.get("name"), l["size"]) for l in ls] == [("SSC", 25), ("Kara A", 10), (None, 10)], (n, ls)
        assert len({l["id"] for l in ls}) == 3, ls
        assert ls[1]["specs"] == {K("Lee"): 2} and ls[1]["comp"] == KARA10 and ls[2]["groups"] == {K("Rita"): 2}, ls
        # the first lineup is the team as clients before 1.3.2 know it
        t = get_team(x, tid)
        assert t["size"] == 25 and t["comp"] == STD25 and t["groups"] == {K("Lee"): 1, K("Rita"): 2}, t
        rec = x.eval_py("return %s.T[...]" % ROOT, tid)
        assert rec["sz"] == 25 and rec["cp"] == STD25 and rec["s"] == {K("Lee"): 3}, rec
    t = get_team(rita, tid)
    assert [rp(rita, "LineupName", t, l) for l in lst(t["lineups"])] == ["SSC", "Kara A", "10-man"]
    assert rp(rita, "FindLineup", tid)["name"] == "SSC" and rp(rita, "FindLineup", tid, "nope") is None
    # one lineup's comp alone (SetTeamComp with a lineup), the others kept
    kara = ln_id(bob, tid, 1)
    assert call(bob, "SetTeamComp", tid, {"MAGE": [0, 1]}, kara)["ok"] is True
    w.tick(2)
    ls = lineups(lee, tid)
    assert ls[0]["comp"] == STD25 and ls[1]["comp"] == {"MAGE": [0, 1]} and ls[2].get("comp") is None, ls
    assert rp(lee, "GetTeamComp", tid, kara) == {"MAGE": [0, 1]} and rp(lee, "GetTeamComp", tid) == STD25
    # a team saved before 1.3.2 (no L): one lineup "1" made of its size, groups, specs and comp
    bob.eval("local r = %s; r.T.old1 = { id = 'old1', rev = GetServerTime(), by = ns.Util.PlayerKey(), n = 'Old', "
             "m = { ... }, sz = 10, s = { [select(1, ...)] = 3 }, grp = { [select(1, ...)] = 1 }, "
             "cp = { WARRIOR = { 0, 0, 1 } } }" % ROOT, K("Lee"))
    ls = lineups(bob, "old1")
    assert len(ls) == 1 and ls[0]["id"] == "1" and ls[0]["size"] == 10 and ls[0]["comp"] == {"WARRIOR": [0, 0, 1]}, ls
    assert ls[0]["groups"] == {K("Lee"): 1} and ls[0]["specs"] == {K("Lee"): 3}
    # saving it keeps that lineup (id "1") and adds a 25
    assert team(bob, "Old", ["Lee"], [{"id": "1", "size": 10, "groups": {"Lee": 1}}, {"size": 25}], "old1") == "old1"
    ls = lineups(bob, "old1")
    assert [(l["id"] == "1", l["size"]) for l in ls] == [(True, 10), (False, 25)], ls
    # refused: more than 10 lineups, none, a comp bigger than its lineup, a member's save
    res = save(bob, "Main", ["Lee"], [{"size": 10}] * 11, tid)
    assert res["ok"] is False and "at most 10 lineups" in res["r"], res
    res = save(bob, "Main", ["Lee"], [], tid)
    assert res["ok"] is False and "at least one lineup" in res["r"], res
    res = save(bob, "Main", ["Lee"], [{"name": "Kara A", "size": 10, "comp": STD25}], tid)
    assert res["ok"] is False and "The target comp of Kara A has 25 slots, more than the team's 10." == res["r"], res
    res = save(lee, "Main", ["Lee"], [{"size": 10}], tid)
    assert res["ok"] is False, res
    # a hand-made record with doubled lineup ids is refused whole
    bob.eval("local id, m = ...; ns.Comm:Send({ t = 'RPU', k = 'T', r = { id = id, rev = GetServerTime() + 5, "
             "by = ns.Util.PlayerKey(), n = 'Main', m = m, L = { { id = 'a', sz = 10 }, { id = 'a', sz = 25 } } } }, "
             "'GUILD', nil, 'data')", tid, [K("Lee")])
    w.tick(2)
    assert len(lineups(lee, tid)) == 3
    w.assert_no_errors()


@case
def unassigned_and_the_waitlist_never_count():
    w, c = world()
    bob, gina, rita = c["Bob"], c["Gina"], c["Rita"]
    tid = team(bob, "Kara", ["Lee", "Rita", "Sam"], [
        {"name": "Kara A", "size": 10, "groups": {"Lee": 1}, "specs": {"Lee": 3, "Rita": 2}, "comp": KARA10}])
    w.tick(2)
    ln = ln_id(bob, tid, 0)
    assert call(gina, "JoinWaitlist", tid, ln, 1)["ok"] is True          # Holy
    w.tick(2)
    m = rp(rita, "MatchTeam", {"id": tid, "ln": ln})
    assert m["filled"] == 1 and m["total"] == 10, m                       # Lee alone: in a group
    assert keys(m["unassigned"]) == [K("Rita"), K("Sam")], m["unassigned"]
    assert [(e["key"], e["sp"], e["n"], e["source"]) for e in lst(m["waitlist"])] == [(K("Gina"), 1, 1, "waitlist")]
    assert "Holy Priest" in [o["name"] for o in lst(m["open"])]           # Rita (unassigned) leaves it open
    st = {b["key"]: b["state"] for b in lst(rp(rita, "GetTeamBuffStates", {"id": tid, "ln": ln}))}
    assert st["fortitude"] == "planned" and st["blessings"] == "planned" and st["sunder"] == "have", st
    assert rp(rita, "CompFromTeam", {"id": tid, "ln": ln}) == {"WARRIOR": [0, 0, 1]}
    # who could fill: the unassigned first, then the waitlist (with their place), never twice
    f = rp(rita, "CanFill", {"id": tid, "ln": ln}, "PRIEST", 2)
    assert keys(f["unassigned"]) == [K("Rita")] and lst(f["waitlist"]) == [], f
    f = rp(rita, "CanFill", {"id": tid, "ln": ln}, "PALADIN", 1)
    assert [(e["key"], e["n"]) for e in lst(f["waitlist"])] == [(K("Gina"), 1)] and lst(f["guild"]) == [], f
    # in a group they count: Rita into group 2
    assert team(bob, "Kara", ["Lee", "Rita", "Sam"], [
        {"id": ln, "name": "Kara A", "size": 10, "groups": {"Lee": 1, "Rita": 2}, "specs": {"Lee": 3, "Rita": 2},
         "comp": KARA10}], tid) == tid
    w.tick(2)
    m = rp(rita, "MatchTeam", {"id": tid, "ln": ln})
    assert m["filled"] == 2 and keys(m["unassigned"]) == [K("Sam")], m
    w.assert_no_errors()


@case
def players_put_themselves_on_the_waitlist():
    w, c = world()
    bob, gina, lee, rita, sam = c["Bob"], c["Gina"], c["Lee"], c["Rita"], c["Sam"]
    tid = team(bob, "Main", ["Lee"], [{"name": "SSC", "size": 25}, {"name": "Kara A", "size": 10}])
    w.tick(2)
    ssc, kara = ln_id(bob, tid, 0), ln_id(bob, tid, 1)
    assert call(rita, "JoinWaitlist", tid, ssc, 2)["ok"] is True
    w.tick(1)
    assert call(sam, "JoinWaitlist", tid, None, None)["ok"] is True        # (nil: the first lineup, spec as known)
    w.tick(1)
    assert call(gina, "JoinWaitlist", tid, ssc, 1)["ok"] is True
    w.tick(2)
    for n, x in c.items():
        assert [k for k, _, _ in waitlist(x, tid, ssc)] == [K("Rita"), K("Sam"), K("Gina")], (n, waitlist(x, tid, ssc))
        assert waitlist(x, tid, kara) == []
    # on the roster: no waitlist; joining again changes the spec, keeps the place
    res = call(lee, "JoinWaitlist", tid, ssc, 3)
    assert res["ok"] is False and "roster" in res["e"], res
    assert call(rita, "JoinWaitlist", tid, ssc, 3)["ok"] is True
    w.tick(2)
    assert waitlist(bob, tid, ssc)[0] == (K("Rita"), 3, 1)
    assert call(rita, "JoinWaitlist", tid, ssc, 9)["e"] == "unknown spec"
    # a member takes only themselves off; the council anyone, and moves them
    res = call(sam, "LeaveWaitlist", tid, ssc, K("Rita"))
    assert res["ok"] is False and "guild council" in res["e"], res
    assert call(sam, "MoveWaitlist", tid, ssc, K("Gina"), -1)["ok"] is False
    assert call(bob, "MoveWaitlist", tid, ssc, K("Gina"), -1)["ok"] is True
    w.tick(2)
    assert [k for k, _, _ in waitlist(lee, tid, ssc)] == [K("Rita"), K("Gina"), K("Sam")]
    assert call(bob, "MoveWaitlist", tid, ssc, K("Rita"), -1)["ok"] is False     # first already
    assert call(bob, "LeaveWaitlist", tid, ssc, K("Rita"))["ok"] is True
    w.tick(2)
    assert [k for k, _, _ in waitlist(sam, tid, ssc)] == [K("Gina"), K("Sam")]
    # back again: the end of the line
    assert call(rita, "JoinWaitlist", tid, ssc, 2)["ok"] is True
    w.tick(2)
    assert [(k, n) for k, _, n in waitlist(lee, tid, ssc)] == [(K("Gina"), 1), (K("Sam"), 2), (K("Rita"), 3)]
    # forged: an entry for someone else from a member, or one naming another writer, is ignored
    sam.eval("local tm, ln, k = ...; ns.Comm:Send({ t = 'RTW', l = { { tm = tm, ln = ln, k = k, e = { rev = "
             "GetServerTime() + 1, by = ns.Util.PlayerKey(), at = GetServerTime() } } } }, 'GUILD', nil, 'ctrl')",
             tid, ssc, K("Lee"))
    sam.eval("local tm, ln, k = ...; ns.Comm:Send({ t = 'RTW', l = { { tm = tm, ln = ln, k = k, e = { rev = "
             "GetServerTime() + 1, by = k, x = true } } } }, 'GUILD', nil, 'ctrl')", tid, ssc, K("Gina"))
    w.tick(2)
    assert [k for k, _, _ in waitlist(bob, tid, ssc)] == [K("Gina"), K("Sam"), K("Rita")]
    # a late login catches up (the team's digest item carries its waitlists)
    lee.logout()
    w.tick(2)
    assert call(sam, "LeaveWaitlist", tid, ssc)["ok"] is True
    assert call(gina, "JoinWaitlist", tid, kara, 1)["ok"] is True
    w.tick(2)
    lee.login()
    w.tick(40)
    assert [k for k, _, _ in waitlist(lee, tid, ssc)] == [K("Gina"), K("Rita")]
    assert [k for k, _, _ in waitlist(lee, tid, kara)] == [K("Gina")]
    hashes = {n: x.eval("return ns.RaidPlan:GetDigestHash()") for n, x in c.items()}
    assert len(set(hashes.values())) == 1, hashes
    # the blacklist: hidden, and no joining
    assert gina.eval("local ok = ns.RaidPlan:SetBlacklisted(...); return ok", K("Rita")) is True
    w.tick(2)
    assert [k for k, _, _ in waitlist(bob, tid, ssc)] == [K("Gina")]
    res = call(rita, "JoinWaitlist", tid, kara, 2)
    assert res["ok"] is False and "blacklist" in res["e"], res
    w.assert_no_errors()


@case
def saving_the_roster_takes_its_new_members_off_the_waitlists():
    w, c = world()
    bob, rita, sam = c["Bob"], c["Rita"], c["Sam"]
    tid = team(bob, "Main", ["Lee"], [{"name": "SSC", "size": 25}, {"name": "Kara A", "size": 10}])
    w.tick(2)
    ssc, kara = ln_id(bob, tid, 0), ln_id(bob, tid, 1)
    for ln in (ssc, kara):
        assert call(rita, "JoinWaitlist", tid, ln, 2)["ok"] is True
    assert call(sam, "JoinWaitlist", tid, kara, 2)["ok"] is True
    w.tick(2)
    # a draft that takes Rita in leaves her out of its waitlist already
    draft = {"id": tid, "ln": kara, "members": {K("Lee"): True, K("Rita"): True}}
    assert [e["key"] for e in lst(rp(bob, "GetWaitlist", draft))] == [K("Sam")]
    assert team(bob, "Main", ["Lee", "Rita"], [{"id": ssc, "name": "SSC", "size": 25},
                                               {"id": kara, "name": "Kara A", "size": 10, "groups": {"Rita": 1}}],
                tid) == tid
    w.tick(2)
    for n, x in c.items():
        assert waitlist(x, tid, ssc) == [] and [k for k, _, _ in waitlist(x, tid, kara)] == [K("Sam")], n
        assert x.eval("local r = %s; return r.W[...][select(2, ...)][select(3, ...)].x" % ROOT, tid, ssc, K("Rita")) is True
    # a deleted lineup's waitlist goes with it (prune), a deleted team's at once
    assert team(bob, "Main", ["Lee", "Rita"], [{"id": ssc, "name": "SSC", "size": 25}], tid) == tid
    w.tick(2)
    sam.eval("ns.RaidPlan:Prune()")
    assert sam.eval("local r = %s; return r.W[...] and r.W[...][select(2, ...)] ~= nil" % ROOT, tid, kara) is False
    assert call(bob, "DeleteTeam", tid)["ok"] is True
    w.tick(2)
    assert sam.eval("return %s.W[...] == nil" % ROOT, tid) is True
    w.assert_no_errors()


@case
def raids_use_a_lineup_of_their_size():
    w, c = world()
    bob, gina, lee, rita, sam = c["Bob"], c["Gina"], c["Lee"], c["Rita"], c["Sam"]
    tid = team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], [
        {"name": "SSC", "size": 25, "groups": {"Lee": 1, "Rita": 1}, "comp": {"WARRIOR": [0, 0, 1], "PALADIN": [1]}},
        {"name": "Kara A", "size": 10, "groups": {"Lee": 1}, "specs": {"Lee": 3}, "comp": {"WARRIOR": [0, 0, 1]}},
        {"name": "Kara B", "size": 10, "groups": {"Rita": 2, "Sam": 1}, "specs": {"Rita": 2, "Sam": 2},
         "comp": {"ROGUE": [0, 1], "PRIEST": [0, 1], "MAGE": [0, 1]}}])
    w.tick(2)
    ssc, ka, kb = (ln_id(bob, tid, i) for i in range(3))
    first = create(bob, i="kara", t=now(bob) + DAY, tm=[tid])
    second = create(bob, i="kara", t=now(bob) + 2 * DAY, tm=[tid], tl={tid: kb})
    big = create(bob, i="ssc", t=now(bob) + 3 * DAY, tm=[tid])
    w.tick(2)
    assert rp(rita, "GetRaidLineup", first, tid)["id"] == ka
    assert rp(rita, "GetRaidLineup", second, tid)["id"] == kb
    assert rp(rita, "GetRaidLineup", big, tid)["id"] == ssc
    assert rp(rita, "GetRaid", second)["tl"] == {tid: kb}
    # the open slots: the named lineup's comp
    ct = rp(rita, "GetRaidCompTeam", second)
    assert ct["id"] == tid and ct["ln"] == kb and ct["lineupName"] == "Kara B", ct
    o = rp(rita, "GetRaidOpenSlots", second)
    assert o["wanted"] == 3 and o["ln"] == kb and o["teamName"] == "Main", o
    # the starting groups: Kara B's
    for x in (rita, sam, lee):
        assert signup(x, second, "A")["ok"] is True
    w.tick(2)
    grp = rp(bob, "BuildLayout", second)
    assert grp.get(K("Rita")) == 2 and grp.get(K("Sam")) == 1, grp
    # the team's next raid and LF line, per lineup
    assert rp(rita, "GetTeamNextRaid", tid, kb)["id"] == second and rp(rita, "GetTeamNextRaid", tid, ka)["id"] == first
    assert rp(rita, "GetTeamNextRaid", tid, ssc)["id"] == big and rp(rita, "GetTeamNextRaid", tid)["id"] == first
    lf = rp(rita, "GetLFMessage", {"id": tid, "ln": kb})
    assert lf and "LF Combat Rogue" not in lf and "Holy Priest" not in lf and "Fire Mage" in lf, lf   # (Sam, Rita in)
    # who is invited: the players in the lineup's groups (not the rest of the roster, not the waitlist)
    assert call(gina, "JoinWaitlist", tid, kb, 1)["ok"] is True
    w.tick(2)
    assert set(rp(rita, "GetInvited", second)) == {K("Rita"), K("Sam")}
    assert set(rp(rita, "GetInvited", first)) == {K("Lee")} and set(rp(rita, "GetInvited", big)) == {K("Lee"), K("Rita")}
    assert lst(rp(rita, "GetRaidTeamPlayers", second, tid)) == [K("Rita"), K("Sam")]
    # who could fill an open slot: the lineup's players who haven't answered (Bob, on the roster but not in Kara B,
    # isn't one of them)
    f = rp(rita, "RaidCanFill", second, "MAGE", 2)
    assert lst(f["unanswered"]) == [], f
    # the editor's change of lineup; an older client's copy of that version without tl never replaces it
    assert call(bob, "EditRaid", first, {"tl": {tid: kb}})["ok"] is True
    w.tick(2)
    assert rp(lee, "GetRaidLineup", first, tid)["id"] == kb
    assert set(rp(lee, "GetInvited", first)) == {K("Rita"), K("Sam")}
    old = rita.eval_py("local e = %s.E[...]; local copy = {}; for k, v in pairs(e) do copy[k] = v end; copy.tl = nil; "
                       "return copy" % ROOT, first)
    rita.eval("local r, to = ...; ns.Comm:Send({ t = 'RPG', o = r.id, e = r }, 'WHISPER', to, 'data')", old, K("Lee"))
    w.tick(2)
    assert rp(lee, "GetRaidLineup", first, tid)["id"] == kb
    # a lineup of another size only: the team gives no starting groups and invites its whole roster (a 25 raid, the
    # 25 lineup deleted); a lineup with nobody in its groups yet invites the roster too
    assert team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], [
        {"id": ka, "name": "Kara A", "size": 10, "groups": {"Lee": 1}}, {"id": kb, "name": "Kara B", "size": 10}],
        tid) == tid
    w.tick(2)
    assert rp(rita, "GetRaidLineup", big, tid) is None and rp(rita, "GetRaidCompTeam", big) is None
    assert set(rp(rita, "GetInvited", big)) == {K("Lee"), K("Rita"), K("Sam"), K("Bob")}
    assert set(rp(rita, "GetInvited", second)) == {K("Lee"), K("Rita"), K("Sam"), K("Bob")}
    assert set(rp(rita, "GetInvited", first)) == {K("Lee"), K("Rita"), K("Sam"), K("Bob")}       # (Kara B now)
    w.assert_no_errors()


@case
def an_older_clients_copies_and_edits_keep_the_lineups():
    w, c = world()
    bob, lee, rita = c["Bob"], c["Lee"], c["Rita"]
    tid = team(bob, "Main", ["Lee", "Rita", "Sam"], [
        {"name": "SSC", "size": 25, "groups": {"Lee": 1}, "comp": {"WARRIOR": [0, 0, 1]}},
        {"name": "Kara A", "size": 10, "groups": {"Rita": 1, "Sam": 2}, "comp": {"PRIEST": [0, 1]}}])
    w.tick(2)
    ka = ln_id(bob, tid, 1)
    # a 1.3.1 client's copy of this version keeps cp but drops L: it never replaces the full one
    old = rita.eval_py("local t = %s.T[...]; local copy = {}; for k, v in pairs(t) do copy[k] = v end; copy.L = nil; "
                       "return copy" % ROOT, tid)
    rita.eval("local r, to = ...; ns.Comm:Send({ t = 'RPG', T = r }, 'WHISPER', to, 'data')", old, K("Lee"))
    w.tick(2)
    assert len(lineups(lee, tid)) == 2
    # an edit made on such a client (no L, newer): the roster and the first lineup change, the others stay
    edit = bob.eval_py("local t = %s.T[...]; local copy = {}; for k, v in pairs(t) do copy[k] = v end; copy.L = nil; "
                       "copy.rev = t.rev + 10; copy.m = { select(2, ...) }; copy.grp = { [select(2, ...)] = 2 }; "
                       "return copy" % ROOT, tid, K("Lee"), K("Rita"))
    bob.eval("local r = ...; ns.Comm:Send({ t = 'RPU', k = 'T', r = r }, 'GUILD', nil, 'data')", edit)
    w.tick(2)
    for n, x in c.items():
        if n == "Bob":
            continue
        ls = lineups(x, tid)
        assert [(l["name"], l["size"]) for l in ls] == [("SSC", 25), ("Kara A", 10)], (n, ls)
        assert ls[0]["groups"] == {K("Lee"): 2} and ls[0]["comp"] == {"WARRIOR": [0, 0, 1]}, (n, ls)
        assert ls[1]["groups"] == {K("Rita"): 1} and ls[1]["id"] == ka, (n, ls)      # Sam left the roster
        assert sorted(get_team(x, tid)["members"].values() if isinstance(get_team(x, tid)["members"], dict)
                      else get_team(x, tid)["members"]) == [K("Lee"), K("Rita")]
    w.assert_no_errors()


@case
def the_teams_page_lineups_and_waitlist():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    tid = team(bob, "Main", ["Lee", "Sam"], [
        {"name": "SSC", "size": 25, "groups": {"Lee": 1}},
        {"name": "Kara A", "size": 10, "groups": {"Sam": 1}}])
    w.tick(2)
    ka = ln_id(bob, tid, 1)
    # Rita (not on the roster): the lineup chips, the waitlist with Join
    open_teams(w, rita, tid)
    assert lineup_chips(rita) == [("SSC", True), ("Kara A", False)], lineup_chips(rita)
    rita.eval("ns.RaidPlanUI:SelectLineup(2)")
    w.tick(0.3)
    assert lineup_chips(rita) == [("Kara A", True), ("SSC", False)] or lineup_chips(rita)[1] == ("Kara A", True)
    # the waitlist is an icon at the end of the lineup tabs; its list says nobody waits yet and offers Join
    assert shown(rita, D + ".wlBtn") and not shown(rita, D + ".wlBtn.badge")
    rita.click(rita.eval("return %s.wlBtn" % D))
    assert shown(rita, D + ".wl") and shown(rita, D + ".wl.join")
    assert rita.find_text("Nobody is waiting for a spot yet.", True, True)
    # a member of the roster sees no icon while nobody waits
    lee = c["Lee"]
    open_teams(w, lee, tid)
    assert not shown(lee, D + ".wlBtn")
    # Join: pick the spec, then Join
    rita.click(rita.eval("return %s.wl.spec" % D))
    entries = [strip_codes(e.get("text") or "").strip() for e in rita.last_menu()["children"] if e.get("text")]
    assert entries[:3] == ["Discipline", "Holy", "Shadow"], entries
    hit = [e.get("text") for e in rita.last_menu()["children"] if strip_codes(e.get("text") or "").strip() == "Holy"]
    rita.menu_select(hit[0])
    rita.click(rita.eval("return %s.wl.join" % D))
    w.tick(2)
    assert waitlist(bob, tid, ka) == [(K("Rita"), 2, 1)]
    # her own row: Leave; the badge counts her
    assert shown(rita, D + ".wl") and shown(rita, D + ".wl.rows[1].leave") and not shown(rita, D + ".wl.join")
    assert strip_codes(rita.eval("return %s.wlBtn.badge.fs:GetText()" % D)) == "1"
    assert strip_codes(rita.eval("return %s.card.you.fs:GetText()" % TV)) == "You: Kara A · #1 on the waitlist"
    # the organizer: the badge, the list, Rita's row dragged into group 2 (the list fades out of the way, then closes)
    open_teams(w, bob, tid)
    bob.eval("ns.RaidPlanUI:SelectLineup(2)")
    w.tick(0.3)
    grid = "ns.RaidPlanUI:GetTeamGrid()"
    assert strip_codes(bob.eval("return %s.wlBtn.badge.fs:GetText()" % D)) == "1"
    assert bob.eval("return %s.wait" % grid) is None                     # no waitlist block under the groups
    bob.click(bob.eval("return %s.wlBtn" % D))
    row = D + ".wl.rows[1]"
    assert bob.eval("return %s.member.key" % row) == K("Rita") and shown(bob, row + ".more")
    assert strip_codes(bob.eval("return %s.pool.label:GetText()" % grid)).startswith("UNASSIGNED") and bob.eval(
        "local n = 0; for _, c in ipairs(%s.pool.chips) do if c:IsShown() then n = n + 1 end end; return n" % grid) == 1   # Lee (in SSC)
    bob.eval("_G.IsMouseButtonDown = function() return true end")
    bob.eval("local r = %s; r:GetScript('OnDragStart')(r)" % row)
    assert bob.eval("return %s.wl:GetAlpha()" % D) == 0 and shown(bob, row)
    bob.eval("local g = %s; g.boxes[2].IsMouseOver = function() return true end" % grid)
    w.tick(0.2)
    bob.eval("local r = %s; r:GetScript('OnDragStop')(r)" % row)
    bob.eval("_G.IsMouseButtonDown = function() return false end; %s.boxes[2].IsMouseOver = nil" % grid)
    w.tick(0.3)
    dr = bob.eval_py("return ns.RaidPlanUI:GetDraft()")
    assert dr["members"].get(K("Rita")) and dr["grp"].get(K("Rita")) == 2, dr
    assert not shown(bob, D + ".wl")
    assert bob.eval("return ns.RaidPlanUI:AddLineup(10)") is True
    w.tick(0.3)
    assert [n for n, _ in lineup_chips(bob)] == ["SSC", "Kara A", "10-man"], lineup_chips(bob)
    bob.eval("ns.RaidPlanUI:RenameLineup(3, 'Kara B')")
    w.tick(0.3)
    assert lineup_chips(bob)[2] == ("Kara B", True), lineup_chips(bob)
    bob.click(bob.eval("return %s.saveBtn" % D))
    w.tick(2)
    ls = lineups(rita, tid)
    assert [l["name"] for l in ls] == ["SSC", "Kara A", "Kara B"] and ls[1]["groups"].get(K("Rita")) == 2, ls
    assert waitlist(rita, tid, ka) == []
    assert bob.eval("return ns.RaidPlanUI:GetLineupIndex()") == 3            # (the new one stays open)
    # the lineup menu: a click on the open chip
    chip = bob.eval("for _, c in ipairs(%s.lcards) do if c:IsShown() and c.name:GetText() == 'Kara B' then return c end end"
                    % D)
    bob.click(chip)
    entries = [strip_codes(e.get("text") or "").strip() for e in bob.last_menu()["children"] if e.get("text")]
    assert entries == ["Kara B", "Rename", "Size", "Copy", "To the front", "Delete"], entries
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

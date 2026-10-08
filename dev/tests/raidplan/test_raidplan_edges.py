"""Raid management edge cases found in the 2026-10-08 review, each fixed, on the real addon.

Covers: a stale team draft saved after another organizer's save (both edits kept, a deleted team not brought back),
the blacklist kept per entry (an officer who missed an entry no longer erases it; removals stay removed), deletions
outliving Prune (a stopped / cancelled series, a deleted team or raid sent back by a long-absent member is refused),
a lineup a locked raid picked being deleted or resized, a locked raid whose teams were all deleted, a player who
answers Absent after the groups were saved (left out of the layout and of Invite & sort), typed names in the wrong
case (blacklist, guests), and "Every week" edits made from a week with its own time.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_edges.py [-k name]
"""
import copy
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import world, K, DAY, now, team, create, signup, signups, call, raid, raids  # noqa: E402
from _common import case, run_all, strip_codes  # noqa: E402

NAMES = (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"),
         ("Sam", 3, "ROGUE"), ("Tom", 3, "HUNTER"))


def lst(v):
    if v is None:
        return []
    return list(v.values()) if isinstance(v, dict) else list(v)


def names(keys):
    return sorted(k.split("-")[0] for k in keys)


def save(cl, tid, name, members, opts=None):
    return cl.eval_py("local id, n, m, o = ...; local ok, r, mg = ns.RaidPlan:SaveTeam(id, n, m, o);"
                      " return { ok = ok, r = r, merged = mg }", tid, name, [K(m) for m in members], opts or {})


def get_team(cl, tid):
    return cl.eval_py("return ns.RaidPlan:GetTeam(...)", tid)


def as_opts(t, **over):
    """A GetTeam copy as SaveTeam's opts.lineups (what the Teams view sends), base = that version."""
    t = copy.deepcopy(t)
    ls = [{"id": l["id"], "name": l.get("name"), "size": l["size"], "specs": dict(l.get("specs") or {}),
           "groups": dict(l.get("groups") or {}), "seats": dict(l.get("seats") or {}), "comp": l.get("comp")}
          for l in lst(t["lineups"])]
    o = {"lineups": ls, "base": t, "theme": False}
    o.update(over)
    return o


def wait_keys(cl, tid):
    return names(e["key"] for e in lst(cl.eval_py("return ns.RaidPlan:GetWaitlist(...)", tid)))


# --- 1. a stale team draft ----------------------------------------------------------------------------------------

@case
def stale_team_draft_keeps_the_other_organizers_save():
    w, c = world(NAMES)
    gina, bob = c["Gina"], c["Bob"]
    tid = save(gina, None, "Kara A", ["Lee"])["r"]
    w.tick(2)
    assert c["Sam"].eval_py("return { ns.RaidPlan:JoinWaitlist(...) }", tid)[0] is True
    w.tick(2)
    assert wait_keys(gina, tid) == ["Sam"]
    stale = get_team(gina, tid)              # Gina opens the team (her draft's base)
    # Bob takes Sam from the waitlist onto the roster and saves
    r = save(bob, tid, "Kara A", ["Lee", "Sam"], as_opts(get_team(bob, tid)))
    assert r["ok"] is True and not r.get("merged"), r
    w.tick(2)
    # Gina's draft: renamed, Rita added, roster otherwise as she opened it
    r = save(gina, tid, "Kara Alpha", ["Lee", "Rita"], as_opts(stale))
    assert r["ok"] is True and r["merged"] is True, r
    w.tick(3)
    for n in ("Gina", "Bob", "Sam"):
        t = get_team(c[n], tid)
        assert t["name"] == "Kara Alpha", (n, t["name"])
        assert names(lst(t["members"])) == ["Lee", "Rita", "Sam"], (n, lst(t["members"]))
    assert wait_keys(gina, tid) == [], wait_keys(gina, tid)
    # a removal in the draft still removes; a lineup the other organizer added stays
    base = get_team(gina, tid)
    t2 = get_team(bob, tid)
    o = as_opts(t2)
    o["lineups"].append({"name": "Kara B", "size": 10, "specs": {}, "groups": {}, "seats": {}})
    assert save(bob, tid, "Kara Alpha", ["Lee", "Rita", "Sam"], o)["ok"] is True
    w.tick(2)
    r = save(gina, tid, "Kara Alpha", ["Rita", "Sam"], as_opts(base))
    assert r["merged"] is True, r
    w.tick(2)
    t = get_team(bob, tid)
    assert names(lst(t["members"])) == ["Rita", "Sam"], lst(t["members"])
    assert [l.get("name") for l in lst(t["lineups"])][1:] == ["Kara B"], lst(t["lineups"])
    w.assert_no_errors()


@case
def stale_team_draft_groups_merge_per_player():
    w, c = world(NAMES)
    gina, bob = c["Gina"], c["Bob"]
    tid = save(gina, None, "Kara", ["Lee", "Rita", "Sam", "Tom"],
               {"lineups": [{"name": "A", "size": 10, "groups": {K("Lee"): 1, K("Rita"): 1}}]})["r"]
    w.tick(2)
    stale = get_team(gina, tid)
    o = as_opts(get_team(bob, tid))
    o["lineups"][0]["groups"][K("Sam")] = 2            # Bob places Sam
    assert save(bob, tid, "Kara", ["Lee", "Rita", "Sam", "Tom"], o)["ok"] is True
    w.tick(2)
    o = as_opts(stale)
    o["lineups"][0]["groups"][K("Tom")] = 2            # Gina places Tom, from her old draft
    del o["lineups"][0]["groups"][K("Lee")]            # and takes Lee out
    assert save(gina, tid, "Kara", ["Lee", "Rita", "Sam", "Tom"], o)["merged"] is True
    w.tick(2)
    grp = lst(get_team(bob, tid)["lineups"])[0]["groups"]
    assert {k.split("-")[0]: v for k, v in grp.items()} == {"Rita": 1, "Sam": 2, "Tom": 2}, grp
    w.assert_no_errors()


@case
def stale_team_draft_of_a_deleted_team_is_refused():
    w, c = world(NAMES)
    gina, bob = c["Gina"], c["Bob"]
    tid = save(gina, None, "Kara A", ["Lee"])["r"]
    w.tick(2)
    stale = get_team(gina, tid)
    assert call(bob, "DeleteTeam", tid)["ok"] is True
    w.tick(2)
    r = save(gina, tid, "Kara A", ["Lee", "Rita"], as_opts(stale))
    assert r["ok"] is False and "deleted" in r["r"], r
    assert get_team(bob, tid) is None
    w.assert_no_errors()


# --- 2. the blacklist per entry -----------------------------------------------------------------------------------

def bl(cl):
    return names(e["key"] for e in cl.eval_py("return ns.RaidPlan:GetBlacklist()"))


def bl_add(cl, name):
    r = cl.eval_py("local ok, k = ns.RaidPlan:SetBlacklisted(...); return { ok = ok, k = k }", name)
    assert r["ok"] is True, r


@case
def blacklist_officer_who_missed_an_entry_does_not_erase_it():
    w, c = world(NAMES)
    gina, bob, lee = c["Gina"], c["Bob"], c["Lee"]
    bob.logout()
    w.tick(2)
    bl_add(gina, "Xavier")
    w.tick(3)
    assert bl(lee) == ["Xavier"]
    gina.logout()
    w.tick(2)
    bob.login()                 # only members online: nobody hands Bob the list
    w.tick(20)
    assert bl(bob) == []
    bl_add(bob, "Yuri")
    w.tick(3)
    assert bl(lee) == ["Xavier", "Yuri"], bl(lee)
    assert lee.eval("return ns.RaidPlan:IsBlacklisted(...)", K("Xavier")) is True
    gina.login()
    w.tick(30)
    for n in ("Gina", "Bob", "Lee", "Rita"):
        assert bl(c[n]) == ["Xavier", "Yuri"], (n, bl(c[n]))
    w.assert_no_errors()


@case
def blacklist_removal_is_not_undone_by_an_old_copy():
    w, c = world(NAMES)
    gina, bob, lee = c["Gina"], c["Bob"], c["Lee"]
    bl_add(gina, "Xavier")
    w.tick(3)
    assert bl(bob) == ["Xavier"]
    bob.logout()
    w.tick(2)
    assert call(gina, "RemoveBlacklisted", K("Xavier"))["ok"] is True
    w.tick(3)
    assert bl(lee) == []
    gina.logout()
    w.tick(2)
    bob.login()                 # still holds Xavier, and adds Yuri
    w.tick(20)
    bl_add(bob, "Yuri")
    w.tick(3)
    assert bl(lee) == ["Yuri"], bl(lee)
    gina.login()
    w.tick(30)
    for n in ("Gina", "Bob", "Lee"):
        assert bl(c[n]) == ["Yuri"], (n, bl(c[n]))
    # blacklisted again later: the newer entry beats the old removal
    bl_add(bob, "Xavier")
    w.tick(3)
    assert bl(lee) == ["Xavier", "Yuri"], bl(lee)
    w.assert_no_errors()


@case
def blacklist_from_an_older_client_only_adds():
    w, c = world(NAMES)
    gina, bob, lee = c["Gina"], c["Bob"], c["Lee"]
    bl_add(gina, "Xavier")
    w.tick(3)
    # a client before 1.3.3 sends its whole list (no f, no versions) with a newer rev: Xavier is not in it
    bob.eval("ns.Comm:Send({ t = 'BLL', rev = GetServerTime() + 5, by = ns.Util.PlayerKey(),"
             " l = { { k = ..., b = ns.Util.PlayerKey(), a = GetServerTime() } } }, 'GUILD', nil, 'data')", K("Yuri"))
    w.tick(3)
    assert bl(lee) == ["Xavier", "Yuri"], bl(lee)
    w.assert_no_errors()


# --- 3. deletions outlive Prune -----------------------------------------------------------------------------------

ROOT = "ns.db.raidplan['Casual Disaster-Thunderstrike']"


@case
def pruned_deletions_are_not_brought_back_by_a_long_absent_member():
    w, c = world(NAMES + (("Uma", 3, "HUNTER"),))
    bob, uma, sam = c["Bob"], c["Uma"], c["Sam"]
    wk = create(bob, i="kara", t=now(bob) + DAY, weekly=True)
    sid = wk.split("#")[0]
    tid = team(bob, "Old team", ["Lee"])
    gone = create(bob, i="gruul", t=now(bob) + 40 * DAY)       # a one-off raid far ahead, deleted below
    w.tick(3)
    assert uma.eval("return %s.S[...] ~= nil" % ROOT, sid) is True
    assert uma.eval("return %s.E[...] ~= nil" % ROOT, gone) is True
    uma.logout()
    w.tick(2)
    assert call(bob, "StopRepeating", wk)["ok"] is True
    assert call(bob, "DeleteTeam", tid)["ok"] is True
    assert call(bob, "DeleteRaid", gone)["ok"] is True
    w.tick(3)
    w.server_time0 += 32 * DAY          # a month later: everyone online prunes the deletions
    for x in c.values():
        if x.online:
            x.eval("ns.RaidPlan:Prune()")
    assert sam.eval("return %s.S[...]" % ROOT, sid) is None
    assert sam.eval("return %s.T[...]" % ROOT, tid) is None
    assert sam.eval("return %s.E[...]" % ROOT, gone) is None
    create(bob, i="mag", t=now(bob) + 2 * DAY)                 # (something live, so a login sync happens)
    w.tick(25)
    uma.login()                          # still holds the series without its end, the team and the raid
    w.tick(60)
    for n in ("Sam", "Bob", "Lee", "Gina"):
        x = c[n]
        assert x.eval("return %s.S[...]" % ROOT, sid) is None, n
        assert x.eval("return %s.T[...]" % ROOT, tid) is None, n
        assert x.eval("return %s.E[...] == nil or %s.E[...].del == true" % (ROOT, ROOT), gone, gone) is True, n
        assert "Old team" not in [t["name"] for t in x.eval_py("return ns.RaidPlan:GetTeams()")], n
        assert not [r for r in raids(x) if r["id"].split("#")[0] in (sid, gone)], (n, raids(x))
    # Uma got the deletions back: her copies are gone as well
    assert "Old team" not in [t["name"] for t in uma.eval_py("return ns.RaidPlan:GetTeams()")]
    assert not [r for r in raids(uma) if r["id"].split("#")[0] in (sid, gone)], raids(uma)
    # her old answers for weeks of the ended series are not taken in either
    uma.eval("ns.RaidPlan:Prune()")
    sam.logout()
    w.tick(30)
    sam.login()
    w.tick(60)
    assert not [r for r in raids(sam) if r["id"].split("#")[0] in (sid, gone)], raids(sam)
    w.assert_no_errors()


# --- 4. a locked raid's lineup or teams deleted -------------------------------------------------------------------

def two_lineups(gina):
    return save(gina, None, "Team", ["Lee", "Rita", "Sam", "Tom"], {"lineups": [
        {"name": "Kara A", "size": 10, "groups": {K("Lee"): 1, K("Rita"): 1}},
        {"name": "Kara B", "size": 10, "groups": {K("Sam"): 1, K("Tom"): 1}},
    ]})["r"]


@case
def locked_raid_whose_lineup_was_deleted_counts_the_whole_roster():
    w, c = world(NAMES)
    gina, bob = c["Gina"], c["Bob"]
    tid = two_lineups(gina)
    w.tick(2)
    ls = lst(get_team(gina, tid)["lineups"])
    occ = create(bob, i="kara", t=now(bob) + 2 * DAY, tm=[tid], tl={tid: ls[1]["id"]}, lk=True)
    w.tick(2)
    assert signup(c["Sam"], occ, "A")["ok"] is True and signup(c["Tom"], occ, "A")["ok"] is True
    assert c["Lee"].eval("return ns.RaidPlan:GetSignupBlock(...)", occ) == "lock"     # (Kara A isn't invited)
    w.tick(2)
    assert names(signups(bob, occ)) == ["Sam", "Tom"]
    # Kara B deleted: the raid doesn't fall over to Kara A's players; the whole roster counts
    o = as_opts(get_team(gina, tid))
    o["lineups"] = o["lineups"][:1]
    assert save(gina, tid, "Team", ["Lee", "Rita", "Sam", "Tom"], o)["ok"] is True
    w.tick(2)
    assert names(signups(bob, occ)) == ["Sam", "Tom"], signups(bob, occ)
    assert c["Sam"].eval("return ns.RaidPlan:GetSignupBlock(...)", occ) is None
    assert c["Lee"].eval("return ns.RaidPlan:GetSignupBlock(...)", occ) is None
    w.assert_no_errors()


@case
def locked_raid_whose_lineup_was_resized_counts_the_whole_roster():
    w, c = world(NAMES)
    gina, bob = c["Gina"], c["Bob"]
    tid = two_lineups(gina)
    w.tick(2)
    ls = lst(get_team(gina, tid)["lineups"])
    occ = create(bob, i="kara", t=now(bob) + 2 * DAY, tm=[tid], tl={tid: ls[1]["id"]}, lk=True)
    w.tick(2)
    assert signup(c["Sam"], occ, "A")["ok"] is True
    w.tick(2)
    o = as_opts(get_team(gina, tid))
    o["lineups"][1]["size"] = 25
    assert save(gina, tid, "Team", ["Lee", "Rita", "Sam", "Tom"], o)["ok"] is True
    w.tick(2)
    assert names(signups(bob, occ)) == ["Sam"], signups(bob, occ)
    w.assert_no_errors()


@case
def locked_raid_whose_teams_were_all_deleted_opens_up():
    w, c = world(NAMES)
    gina, bob = c["Gina"], c["Bob"]
    tid = save(gina, None, "Kara A", ["Lee", "Rita"])["r"]
    w.tick(2)
    occ = create(bob, i="kara", t=now(bob) + 2 * DAY, tm=[tid], lk=True)
    w.tick(2)
    assert signup(c["Lee"], occ, "A")["ok"] is True
    assert c["Tom"].eval("return ns.RaidPlan:GetSignupBlock(...)", occ) == "lock"
    w.tick(2)
    # the Delete prompt says so
    gina.slash("/dz raids")
    w.tick(0.5)
    gina.eval("ns.RaidsUI:SetView('teams')")
    w.tick(0.5)
    gina.eval("ns.RaidPlanUI:SelectTeam(...)", tid)
    w.tick(0.3)
    text = strip_codes(gina.eval("return ns.RaidPlanUI:GetTeamDeleteText()"))
    assert "is locked to this team only: it opens to everyone." in text, text
    assert call(gina, "DeleteTeam", tid)["ok"] is True
    w.tick(2)
    assert names(signups(bob, occ)) == ["Lee"], signups(bob, occ)
    for n in ("Lee", "Bob", "Gina", "Tom"):
        assert c[n].eval("return ns.RaidPlan:GetSignupBlock(...)", occ) is None, n
    assert signup(c["Tom"], occ, "A")["ok"] is True
    w.assert_no_errors()


# --- 5. the saved groups as they hold now -------------------------------------------------------------------------

def alt_world():
    """NAMES plus Lalt, Lee's alt (both characters vouch for each other)."""
    w, c = world(NAMES + (("Lalt", 3, "WARLOCK"),))
    for main, alt in (("Lee", "Lalt"), ("Lalt", "Lee")):
        c[main].eval("local gk = ns.Guild:GetGuildKey(); ns.db.accounts = ns.db.accounts or {}; "
                     "ns.db.accounts[gk] = ns.db.accounts[gk] or { mine = {}, v = {} }; "
                     "ns.db.accounts[gk].mine[...] = true", K(alt))
    w.tick(50)
    assert c["Bob"].eval("return ns.Guild:SameAccount(...)", K("Lee"), K("Lalt")) is True
    return w, c


def su(cl, occ, st, char=None):
    return cl.eval_py("local o, st, ch = ...; local ok, e = ns.RaidPlan:SignUp(o, st, nil, nil, ch);"
                      " return { ok = ok, e = e }", occ, st, char)


def layout(cl, occ):
    return {k.split("-")[0]: g for k, g in (cl.eval_py("return (ns.RaidPlan:GetLayout(...))", occ) or {}).items()}


def members(cl, occ):
    return names(m["key"] for m in lst(cl.eval_py("return ns.RaidPlan:GetLayoutMembers(...)", occ)))


@case
def absent_after_the_groups_were_saved_is_not_invited():
    w, c = world(NAMES)
    bob = c["Bob"]
    occ = create(bob, i="kara", t=now(bob) + 600)
    w.tick(2)
    for n in ("Lee", "Rita"):
        assert signup(c[n], occ, "A")["ok"] is True
    w.tick(2)
    assert call(bob, "SetGroups", occ, {K("Lee"): 2, K("Rita"): 1})["ok"] is True
    w.tick(2)
    assert signup(c["Lee"], occ, "X")["ok"] is True
    w.tick(2)
    assert layout(bob, occ) == {"Rita": 1}, layout(bob, occ)
    assert members(bob, occ) == ["Rita"]
    assert bob.eval("return ns.RaidPlan:IsAbsent(...)", occ, K("Lee")) is True
    # Invite & sort with an older plan that still has him: he is skipped
    r = bob.eval_py("local o, a, b = ...; local ok, e = ns.RaidInvite:Start(o, { [a] = 2, [b] = 1 }, 'x');"
                    " return { ok = ok, e = e }", occ, K("Lee"), K("Rita"))
    assert r["ok"] is True, r
    w.tick(2)
    st = bob.eval_py("return ns.RaidInvite:GetStatus()")
    assert st["invited"] == 1 and K("Lee") not in lst(st.get("pending")), st
    w.assert_no_errors()


@case
def saved_groups_follow_a_switch_to_another_character():
    w, c = alt_world()
    bob, lee = c["Bob"], c["Lee"]
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(2)
    assert su(lee, occ, "A")["ok"] is True
    assert signup(c["Rita"], occ, "A")["ok"] is True
    w.tick(2)
    assert call(bob, "SetGroups", occ, {K("Lee"): 1, K("Rita"): 2})["ok"] is True
    w.tick(2)
    assert su(lee, occ, "A", K("Lalt"))["ok"] is True      # Lee comes on his warlock
    w.tick(3)
    assert members(bob, occ) == ["Lalt", "Rita"], members(bob, occ)    # once, not Lee and Lalt
    assert layout(bob, occ) == {"Lalt": 1, "Rita": 2}, layout(bob, occ)
    assert su(lee, occ, "X", K("Lalt"))["ok"] is True      # then can't come at all
    w.tick(3)
    assert members(bob, occ) == ["Rita"], members(bob, occ)
    assert layout(bob, occ) == {"Rita": 2}, layout(bob, occ)
    w.assert_no_errors()


@case
def saved_groups_past_the_raids_size_are_left_out():
    w, c = world(NAMES)
    bob = c["Bob"]
    occ = create(bob, i="gruul", t=now(bob) + DAY)
    w.tick(2)
    for n in ("Lee", "Rita"):
        assert signup(c[n], occ, "A")["ok"] is True
    w.tick(2)
    assert call(bob, "SetGroups", occ, {K("Lee"): 1, K("Rita"): 4, K("Sam"): 5})["ok"] is True
    w.tick(2)
    assert call(bob, "EditRaid", occ, {"sz": 10})["ok"] is True
    w.tick(2)
    assert layout(bob, occ) == {"Lee": 1}, layout(bob, occ)
    assert members(bob, occ) == ["Lee", "Rita"], members(bob, occ)   # Rita: accepted, now without a group
    w.assert_no_errors()


# --- 6. raid invites from someone with a dungeon run listed -------------------------------------------------------

def toast(cl):
    return cl.eval_py("local t = ns.DungeonsUI:GetToast(); if not (t and t:IsShown()) then return nil end;"
                      " return { run = t.run, mode = t.mode }")


def blizzard_popup(cl):
    return cl.eval_py("return StaticPopup_FindVisible('PARTY_INVITE') ~= nil")


@case
def raid_invite_from_a_run_leader_is_left_to_the_games_popup():
    w, c = world(NAMES)
    w.auto_accept_invites = False
    bob, lee, rita = c["Bob"], c["Lee"], c["Rita"]
    for x in (lee, rita):
        x.eval("ns.DungeonRuns:SetMyRole('dps', true)")
    # Bob listed a Shattered Halls run for later tonight, then forms the planned Kara raid
    rid = bob.eval_py("local r, why = ns.DungeonRuns:List({ d = 'ShatteredHalls', h = true, role = 'tank',"
                      " at = GetServerTime() + 4 * 3600 }); return r and r.id or why")
    assert isinstance(rid, str) and ":" in rid, rid
    occ = create(bob, i="kara", t=now(bob) + 900)
    w.tick(3)
    assert signup(lee, occ, "A")["ok"] is True
    w.tick(3)
    bob.eval("C_PartyInfo.InviteUnit('Lee')")
    w.tick(1)
    assert toast(lee) is None or toast(lee)["mode"] != "invite", toast(lee)
    assert blizzard_popup(lee) is True
    w.tick(65)                          # the run's toast would have declined it after a minute
    assert w.invite_log[-1]["result"] == "pending", w.invite_log[-1]
    # someone not in tonight's raid still gets the run's invite
    bob.eval("C_PartyInfo.InviteUnit('Rita')")
    w.tick(1)
    assert toast(rita) and toast(rita)["mode"] == "invite", toast(rita)
    w.assert_no_errors()


# --- 9. typed names in the game's case ----------------------------------------------------------------------------

@case
def typed_names_take_the_games_case():
    w, c = world(NAMES)
    bob, rita = c["Bob"], c["Rita"]
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(2)
    # the blacklist: "rita" is Rita (and blocks her)
    r = call(bob, "SetBlacklisted", "rita", "afk")
    assert r["ok"] is True and r["e"] == K("Rita"), r
    w.tick(3)
    assert rita.eval("return ns.RaidPlan:GetSignupBlock(...)", occ) == "blacklist"
    assert signup(rita, occ, "A")["ok"] is False
    # typed again in another case: the same entry, not a second one
    assert call(bob, "SetBlacklisted", "RITA", "afk twice")["e"] == K("Rita")
    assert bl(bob) == ["Rita"]
    # guests: "lee" is the guild's Lee (refused); "pugsy" is stored as Pugsy, and typed again it is the same guest
    r = call(bob, "AddGuest", occ, "lee", "WARRIOR")
    assert r["ok"] is False and "in the guild" in r["e"], r
    r = call(bob, "AddGuest", occ, "pugsy", "MAGE")
    assert r["ok"] is True and r["e"] == K("Pugsy"), r
    r = call(bob, "AddGuest", occ, "PUGSY", "MAGE", 1)
    assert r["ok"] is True and r["e"] == K("Pugsy"), r
    w.tick(2)
    assert names(signups(c["Sam"], occ)) == ["Pugsy"], signups(c["Sam"], occ)
    w.assert_no_errors()


# --- 10. "Every week" edits ---------------------------------------------------------------------------------------

def wall(t):
    return time.strftime("%a %H:%M", time.localtime(t))


@case
def every_week_from_a_week_with_its_own_time_moves_every_week_there():
    w, c = world(NAMES)
    bob = c["Bob"]
    t0 = now(bob) + DAY
    sid = create(bob, i="kara", t=t0, weekly=True).split("#")[0]
    w.tick(2)
    v1 = raid(bob, sid + "#1")
    assert call(bob, "EditRaid", sid + "#1", {"t": v1["t"] + DAY, "ti": "Kara late"}, "one")["ok"] is True
    v1 = raid(bob, sid + "#1")
    picked = v1["t"] + 3600               # what the sheet sends: the week's shown time + 1 hour
    r = call(bob, "EditRaid", sid + "#1", {"t": picked, "ti": "Kara night"}, "series")
    assert r["ok"] is True, r
    w.tick(2)
    for x in (bob, c["Lee"]):
        times = [raid(x, sid + "#%d" % k)["t"] for k in range(3)]
        assert times[1] == picked, (wall(times[1]), wall(picked))
        assert len({wall(t) for t in times}) == 1, [wall(t) for t in times]      # same weekday and time every week
        assert [raid(x, sid + "#%d" % k)["ti"] for k in range(3)] == ["Kara night"] * 3
    w.assert_no_errors()


@case
def every_week_can_not_hand_a_weeks_answers_to_another_week():
    w, c = world(NAMES)
    bob, lee = c["Bob"], c["Lee"]
    t0 = now(bob) + DAY
    sid = create(bob, i="kara", t=t0, weekly=True).split("#")[0]
    w.tick(2)
    assert signup(lee, sid + "#0", "X")["ok"] is True
    w.tick(2)
    r = call(bob, "EditRaid", sid + "#0", {"t": t0 + 7 * DAY}, "series")      # "skip this week"
    assert r["ok"] is False and "cancel" in r["e"], r
    assert raid(bob, sid + "#0")["t"] == t0
    r = call(bob, "EditRaid", sid + "#0", {"t": t0 + 2 * DAY}, "series")      # within the week: fine
    assert r["ok"] is True, r
    w.assert_no_errors()


@case
def every_week_across_a_clock_change_keeps_the_picked_time():
    st = int(time.mktime((2026, 10, 10, 12, 0, 0, 0, 0, -1)))
    import rp_common
    real = rp_common.World
    rp_common.World = lambda **kw: real(server_time=st, **kw)
    try:
        w, c = world(NAMES)
    finally:
        rp_common.World = real
    bob = c["Bob"]
    t0 = int(time.mktime((2026, 10, 14, 20, 0, 0, 0, 0, -1)))              # Wed 14 Oct 20:00
    sid = create(bob, i="kara", t=t0, weekly=True).split("#")[0]
    # from week 1 (Wed 21 Oct), every week: Sunday 25 Oct 20:00 (in Europe, after the clock change)
    target = int(time.mktime((2026, 10, 25, 20, 0, 0, 0, 0, -1)))
    assert call(bob, "EditRaid", sid + "#1", {"t": target}, "series")["ok"] is True
    for k in range(3):
        want = int(time.mktime((2026, 10, 18 + 7 * k, 20, 0, 0, 0, 0, -1)))
        got = raid(bob, sid + "#%d" % k)["t"]
        assert got == want, (k, time.ctime(got), time.ctime(want))
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

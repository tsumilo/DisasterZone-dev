"""ADDENDUM J §60: a raid's group layout (starting from the team's), the Upcoming Groups tab, Invite & sort and
Re-sort, on the real addon with the mock's invites / ConvertToRaid / SetRaidSubgroup / SwapRaidSubgroup.

Covers: the starting layout (team seats kept, open seats filled by the same role, Tentative / Absent left out, no team
layout = Auto-fill), the Groups tab (organizer edits + Save, members read-only, the layout following sign-ups until
saved), Invite & sort from no group (party, convert to raid, everyone invited and sorted, offline players reported), a
late joiner sorted automatically, Re-sort after manual moves (unplanned players pushed to groups 6-8), a raider who
isn't leader / assistant refused, no moves in combat, and the run stopping when the raid session ends.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_invite.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import World, Client, gm_pick, K, DAY, now, create, signup, raid, set_raid_leaders  # noqa: E402
from _common import case, run_all, printed_since, strip_codes  # noqa: E402

# name, class, spec index (their sign-up spec)
TEAM = [
    ("Tank", "WARRIOR", 3), ("Ena", "SHAMAN", 2), ("Rog", "ROGUE", 2), ("War", "WARRIOR", 2), ("Cat", "DRUID", 2),
    ("Moon", "DRUID", 1), ("Pip", "PRIEST", 2), ("Holly", "PALADIN", 1), ("Lock", "WARLOCK", 3), ("Hunt", "HUNTER", 2),
]
EXTRA = [("Eli", "SHAMAN", 3), ("Sam", "ROGUE", 2)]
LAYOUT = {"Tank": 1, "Ena": 1, "Rog": 1, "War": 1, "Cat": 1, "Moon": 2, "Pip": 2, "Holly": 2, "Lock": 2, "Hunt": 2}


def world():
    w = World()
    c = {}
    for n, cls, rank in (("Gina", "PALADIN", 0), ("Bob", "MAGE", 1)):
        c[n] = Client(w, n, guild_rank=rank, class_file=cls)
    for n, cls, _ in TEAM + EXTRA:
        c[n] = Client(w, n, guild_rank=3, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ["Bob"])
    w.tick(2)
    return w, c


def make_team(bob, layout=LAYOUT, size=10):
    res = bob.eval_py("local m, g, sz = ...; local ok, id = ns.RaidPlan:SaveTeam(nil, 'Kara A', m, { size = sz, groups = g });"
                      " return { ok = ok, id = id }",
                      [K(n) for n, _, _ in TEAM], {K(n): g for n, g in layout.items()}, size)
    assert res["ok"] is True, res
    return res["id"]


def answer_all(w, c, occ, skip=(), status=None):
    status = status or {}
    for n, _, sp in TEAM + EXTRA:
        if n in skip:
            continue
        r = signup(c[n], occ, status.get(n, "A"), sp)
        assert r["ok"] is True, (n, r)
    w.tick(3)


def layout(cl, occ):
    res = cl.eval_py("return (ns.RaidPlan:GetLayout(...))", occ) or {}
    return {k.split("-")[0]: g for k, g in res.items()}


def setup(skip=(), status=None, team_layout=True):
    w, c = world()
    bob = c["Bob"]
    tid = make_team(bob, LAYOUT if team_layout else {})
    occ = create(bob, i="kara", t=now(bob) + DAY, tm=[tid])
    w.tick(2)
    answer_all(w, c, occ, skip, status)
    return w, c, occ


# ------------------------------------------------------------------------------------------------------------------
@case
def starting_layout_keeps_team_seats_and_fills_open_ones_by_role():
    # Ena (Enhancement, melee seat in group 1) is absent; Pip (Holy priest, healer seat in group 2) is tentative.
    w, c, occ = setup(status={"Ena": "X", "Pip": "T"})
    lay = layout(c["Bob"], occ)
    for n in ("Tank", "Rog", "War", "Cat"):
        assert lay[n] == 1, lay
    for n in ("Moon", "Holly", "Lock", "Hunt"):
        assert lay[n] == 2, lay
    assert lay["Sam"] == 1, lay            # rogue (melee) takes Ena's melee seat
    assert lay["Eli"] == 2, lay            # resto shaman (healer) takes Pip's healer seat
    assert "Ena" not in lay and "Pip" not in lay, lay
    members = c["Bob"].eval_py("local out = {}; for _, m in ipairs(ns.RaidPlan:GetLayoutMembers(...)) do"
                               " out[m.key] = m.st or 'none' end; return out", occ)
    assert K("Ena") not in members and members[K("Pip")] == "T", members
    w.assert_no_errors()


@case
def without_a_team_layout_the_raid_is_autofilled():
    w, c, occ = setup(team_layout=False)
    lay = layout(c["Bob"], occ)
    assert len(lay) == 10 and set(lay.values()) == {1, 2}, lay
    w.assert_no_errors()


def open_groups(w, cl, occ):
    cl.slash("/dz raids")
    w.tick(0.3)
    cl.eval("ns.RaidPlanUI:SelectRaid(...)", occ)
    cl.click(cl.eval("return ns.RaidsUI:GetPanel().upcoming.detail.tabGroups"))
    w.tick(0.3)
    assert cl.eval("return ns.RaidsUI:GetPanel().upcoming.detail.groups:IsVisible()") is True


def grid_groups(cl):
    res = cl.eval_py("""
      local grid = ns.RaidPlanUI:GetRaidGrid(); local out = {}
      for g, box in ipairs(grid.boxes) do
        if box:IsShown() then
          local names = {}
          for _, chip in ipairs(box.chips) do if chip.key then names[#names + 1] = chip.key end end
          out[#out + 1] = names
        end
      end
      return out""")
    return [sorted(k.split("-")[0] for k in (g or [])) for g in res]


@case
def groups_tab_edit_save_and_read_only_for_members():
    w, c, occ = setup(skip=("Sam", "Eli"))
    bob, rita = c["Bob"], c["Pip"]
    open_groups(w, bob, occ)
    g = grid_groups(bob)
    assert g[0] == ["Cat", "Ena", "Rog", "Tank", "War"] and g[1] == ["Holly", "Hunt", "Lock", "Moon", "Pip"], g
    assert bob.find_text("Starting layout", True, True)
    # the starting layout follows sign-ups until saved
    signup(c["Sam"], occ, "A", 2)
    w.tick(2)
    assert "Sam" not in sum(grid_groups(bob), [])        # both groups full: Sam waits in the pool
    assert bob.find_text("Not in a group (1)", True, True)
    # swap Sam with War, save
    bob.eval("ns.RaidPlanUI:GetRaidGrid():Drop(..., 1, select(2, ...))", K("Sam"), K("War"))
    w.tick(0.3)
    assert bob.find_text("Changed, not saved.", True, True)
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().upcoming.detail.groups.saveBtn"))
    w.tick(2)
    v = raid(rita, occ)
    assert v["grp"][K("Sam")] == 1 and K("War") not in v["grp"], v["grp"]
    # a member sees it, can't change it
    open_groups(w, rita, occ)
    assert "Sam" in grid_groups(rita)[0]
    assert not rita.eval("return ns.RaidsUI:GetPanel().upcoming.detail.groups.saveBtn:IsShown()")
    assert not rita.eval("return ns.RaidsUI:GetPanel().upcoming.detail.groups.inviteBtn:IsShown()")
    rita.eval("ns.RaidPlanUI:GetRaidGrid():Drop(..., 2)", K("Sam"))
    assert raid(rita, occ)["grp"][K("Sam")] == 1
    w.assert_no_errors()


def planned_ok(w, occ, cl):
    lay = layout(cl, occ)
    wrong = {n: (g, w.subgroup_of(n)) for n, g in lay.items() if w.subgroup_of(n) != g}
    return wrong


@case
def invite_and_sort_builds_the_raid_from_nothing():
    w, c, occ = setup(skip=("Sam", "Eli"))
    bob = c["Bob"]
    c["Lock"].logout()
    w.tick(1)
    open_groups(w, bob, occ)
    n0 = len(bob.chat_frame)
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().upcoming.detail.groups.inviteBtn"))
    w.tick(20)
    assert raid(bob, occ)["grp"], "the starting layout was saved before inviting"
    assert w.group and w.group["kind"] == "raid", w.group
    members = {m.name for m in w.group_members()}
    expect = {n for n in LAYOUT if n != "Lock"} | {"Bob"}
    assert members == expect, members
    wrong = {n: x for n, x in planned_ok(w, occ, bob).items() if n != "Lock"}
    assert wrong == {}, wrong
    assert w.subgroup_of("Bob") not in (1, 2), w.subgroup_of("Bob")     # not planned: out of the planned groups
    offline = [e for e in w.invite_log if e["result"] == "offline"]
    assert offline == [], offline                                     # offline players are not invited at all
    said = [strip_codes(l) for l in printed_since(bob, n0)]
    assert any("Inviting and sorting 10 players" in l for l in said), said
    assert any("Groups sorted" in l for l in said), said
    assert bob.find_text("1 offline (Lock)", False, True) or bob.find_text("offline (Lock)", False, True)
    # the late joiner: Lock logs in, the leader invites again, Lock is sorted automatically
    c["Lock"].login()
    w.tick(5)
    bob.eval("ns.RaidPlanUI:InviteRaid()")
    w.tick(10)
    assert w.subgroup_of("Lock") == 2, w.subgroup_of("Lock")
    assert planned_ok(w, occ, bob) == {}
    w.assert_no_errors()


@case
def resort_after_manual_moves_and_late_manual_joiner():
    w, c, occ = setup(skip=("Sam", "Eli"))
    bob = c["Bob"]
    order = [c["Bob"]] + [c[n] for n, _, _ in TEAM]
    w.make_raid(order, leader=bob)                      # everyone in list order: planned groups are wrong
    w.tick(2)
    assert planned_ok(w, occ, bob) != {}
    open_groups(w, bob, occ)
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().upcoming.detail.groups.resortBtn"))
    w.tick(15)
    assert planned_ok(w, occ, bob) == {}, planned_ok(w, occ, bob)
    assert w.subgroup_of("Bob") >= 3
    # a player who isn't planned joins (someone else invited him): he goes where there is room, planned groups stay
    w.invite(bob, "Sam")
    w.tick(5)
    assert w.subgroup_of("Sam") not in (1, 2) and planned_ok(w, occ, bob) == {}
    # the plan changes (Sam replaces War): Save moves them while the run is on
    bob.eval("ns.RaidPlanUI:GetRaidGrid():Drop(..., 1, select(2, ...))", K("Sam"), K("War"))
    bob.eval("ns.RaidPlanUI:SaveRaidLayout()")
    w.tick(10)
    assert w.subgroup_of("Sam") == 1 and w.subgroup_of("War") not in (1,), (w.subgroup_of("Sam"), w.subgroup_of("War"))
    w.assert_no_errors()


@case
def only_leader_or_assistant_and_never_in_combat():
    w, c, occ = setup(skip=("Sam", "Eli"))
    bob, tank = c["Bob"], c["Tank"]
    w.make_raid([bob] + [c[n] for n, _, _ in reversed(TEAM)], leader=tank)    # out of order
    w.tick(2)
    n0 = len(bob.chat_frame)
    open_groups(w, bob, occ)
    bob.eval("ns.RaidPlanUI:InviteRaid()")
    assert any("raid leader or an assistant" in strip_codes(l) for l in printed_since(bob, n0))
    assert not bob.eval("return ns.RaidsUI:GetPanel().upcoming.detail.groups.resortBtn:IsEnabled()")
    # promoted to assistant: allowed; in combat nothing moves until combat ends
    w.group["assistants"].append(bob)
    w._roster_changed_group()
    w.tick(1)
    bob.set_combat(True)
    bob.eval("ns.RaidPlanUI:ResortRaid()")
    w.tick(5)
    assert planned_ok(w, occ, bob) != {}
    open_groups(w, bob, occ)
    assert bob.find_text("waiting for combat to end", True, True)
    bob.set_combat(False)
    bob.fire("PLAYER_REGEN_ENABLED")
    w.tick(15)
    assert planned_ok(w, occ, bob) == {}, planned_ok(w, occ, bob)
    w.assert_no_errors()


@case
def the_run_stops_when_the_raid_session_ends():
    w, c, occ = setup(skip=("Sam", "Eli"))
    bob = c["Bob"]
    w.make_raid([bob] + [c[n] for n, _, _ in TEAM], leader=bob)
    w.tick(2)
    bob.slash("/dz raid start")
    w.tick(2)
    open_groups(w, bob, occ)
    bob.eval("ns.RaidPlanUI:ResortRaid()")
    w.tick(10)
    assert bob.eval("return ns.RaidInvite:IsActive()") is True
    bob.slash("/dz raid end")
    w.tick(2)
    assert bob.eval("return ns.RaidInvite:IsActive()") is False
    # a late joiner is not moved any more
    w.invite(bob, "Sam")
    w.tick(5)
    w.assert_no_errors()


@case
def whole_groups_swap_in_the_raid_and_the_team_and_resort_follows():
    w, c, occ = setup(skip=("Sam", "Eli"))
    bob, pip = c["Bob"], c["Pip"]
    w.make_raid([bob] + [c[n] for n, _, _ in TEAM], leader=bob)
    w.tick(2)
    open_groups(w, bob, occ)
    bob.eval("ns.RaidPlanUI:ResortRaid()")
    w.tick(10)
    assert planned_ok(w, occ, bob) == {}
    before = grid_groups(bob)
    grid = "ns.RaidPlanUI:GetRaidGrid()"
    # click "swap" on group 1, cancel, then swap group 1 with group 2 (click on group 2's box)
    bob.click(bob.eval("return %s.boxes[1].swap" % grid))
    assert bob.eval("return %s.boxes[1].swap.fs:GetText()" % grid).endswith("cancel|r")
    bob.click(bob.eval("return %s.boxes[1].swap" % grid))
    assert bob.eval("return %s.swapFrom" % grid) is None
    bob.click(bob.eval("return %s.boxes[1].swap" % grid))
    bob.click(bob.eval("return %s.boxes[2]" % grid))
    w.tick(0.3)
    after = grid_groups(bob)
    assert after[0] == before[1] and after[1] == before[0], (before, after)
    assert bob.find_text("Changed, not saved.", True, True)
    # saving during the run moves the raid
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().upcoming.detail.groups.saveBtn"))
    w.tick(15)
    assert w.subgroup_of("Tank") == 2 and w.subgroup_of("Moon") == 1, (w.subgroup_of("Tank"), w.subgroup_of("Moon"))
    assert planned_ok(w, occ, bob) == {}
    # members don't get the swap link
    open_groups(w, pip, occ)
    assert not pip.eval("return %s.boxes[1].swap:IsShown()" % grid)
    # the Teams view swaps the same way
    bob.eval("ns.RaidsUI:SetView('teams'); ns.RaidPlanUI:SelectTeam(ns.RaidPlan:GetTeams()[1].id)")
    w.tick(0.3)
    bob.eval("ns.RaidPlanUI:GetTeamGrid():SwapGroups(1, 2)")
    w.tick(0.3)
    dr = bob.eval_py("return ns.RaidPlanUI:GetDraft()")
    assert dr["grp"][K("Tank")] == 2 and dr["grp"][K("Moon")] == 1, dr["grp"]
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

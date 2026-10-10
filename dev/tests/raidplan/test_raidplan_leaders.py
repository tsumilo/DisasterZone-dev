"""ADDENDUM J §62: raid leaders and who may plan raids, on the real addon.

Rules (user, 2026-09-29): officers (guild rank 0-1) pick the raid leaders; the GM and the raid leaders plan raids
(the guild council doesn't); with nobody on the list only the GM plans. Raid leaders have no loot council access; the
raid log is for the GM, the council and the raid leaders, items only for the loot council.

Covers: officers (not a council member of a lower rank, not members) saving the list and every member learning it
(RLL; after a relog; from an officer who logs in later when no officer was online), forged / relayed-by-member lists
ignored; planning rights (GM only by default, then raid leaders; council refused); a raid leader taken off the list
keeping their raids visible; raid leaders getting no loot council data; the Raid log view (council yes, raid leaders
without items, a mere group leader no); the raid log synced to a raid leader who logs in later; the window.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_leaders.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import World, Client, gm_pick, K, DAY, now, raids, set_raid_leaders  # noqa: E402
from _common import case, run_all, printed_since, strip_codes  # noqa: E402
import lr_common as lr  # noqa: E402

# name, rank, class
NAMES = (("Gina", 0, "PALADIN"), ("Otto", 1, "WARRIOR"), ("Cora", 3, "MAGE"), ("Rhea", 3, "SHAMAN"),
         ("Lee", 3, "WARRIOR"), ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE"))


def world(leaders=("Rhea",)):
    """Gina = GM, Otto = officer (rank 1), Cora = guild council (rank 3), Rhea = raid leader, Lee / Rita / Sam = members."""
    w = World()
    c = {}
    for name, rank, cls in NAMES:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Cora"])
    if leaders:
        set_raid_leaders(w, c["Otto"], list(leaders))
    return w, c


def can_plan(cl):
    return cl.eval("return ns.RaidPlan:CanOrganize()")


def create_raid(cl, days=1):
    return cl.eval_py("local d = ...; local ok, r = ns.RaidPlan:CreateRaid({ i = 'kara', t = GetServerTime() + d * 86400 });"
                      " return { ok = ok, r = r }", days)


def tabs(cl):
    cl.slash("/dz")
    cl.world.tick(0.3)
    out = cl.eval_py("""
      local out = {}
      local f = DisasterZoneMainFrame
      if not f or not f.Tabs then return out end
      for _, k in ipairs(ns.MainFrame:GetShownPages()) do out[#out + 1] = k end
      return out""") or []
    cl.slash("/dz")
    return out


def whispered_to(w, who, types, start):
    dec = next(x for x in w.clients if x.runtime is not None and x.loaded)
    out = []
    for e in w.addon_log[start:]:
        if e["prefix"].startswith("CDL") and e["chat_type"] == "WHISPER" and str(e["target"]).split("-")[0] == who:
            m = lr.decode_msg(dec, e["text"])
            if m and m.get("t") in types:
                out.append(m)
    return out


# ------------------------------------------------------------------------------------------------------------------
@case
def only_the_gm_plans_raids_until_raid_leaders_are_picked():
    w, c = world(leaders=())
    assert can_plan(c["Gina"]) is True
    for n in ("Otto", "Cora", "Rhea", "Sam"):
        assert can_plan(c[n]) is False, n
    res = create_raid(c["Cora"])
    assert res["ok"] is False and "raid leaders" in res["r"], res         # the council can't
    set_raid_leaders(w, c["Otto"], ["Rhea"])
    assert can_plan(c["Rhea"]) is True and can_plan(c["Gina"]) is True
    assert can_plan(c["Cora"]) is False and can_plan(c["Otto"]) is False  # officers pick; they plan only when listed
    w.assert_no_errors()


@case
def officers_pick_the_raid_leaders_and_everyone_learns_them():
    w, c = world()
    for n, x in c.items():
        assert x.eval_py("return ns.Guild:GetRaidLeaders()") == [K("Rhea")], n
        assert x.eval("return ns.Guild:IsRaidPlanner(...)", K("Rhea")) is True, n
        assert x.eval("return ns.Guild:IsCouncil(...)", K("Rhea")) is False, n
        assert x.eval("return ns.Guild:IsRaidPlanner(...)", K("Cora")) is False, n
    # the GM can too; a council member of a lower rank and members can't
    set_raid_leaders(w, c["Gina"], ["Rhea", "Lee"])
    for n in ("Cora", "Sam", "Rhea"):
        res = c[n].eval_py("local ok, err = ns.Guild:SetRaidLeaders({ ... }); return { ok = ok, err = err }", K(n))
        assert res["ok"] is False and "officers" in res["err"], (n, res)
    # a forged list from a member (even naming an officer as the author) is ignored
    c["Sam"].eval("ns.Comm:Send({ t = 'RLL', rev = GetServerTime() + 5, m = { 'Sam-Thunderstrike' }, by = 'Otto-Thunderstrike' },"
                  " 'GUILD', nil, 'ctrl')")
    w.tick(2)
    assert c["Rita"].eval_py("return ns.Guild:GetRaidLeaders()") == [K("Lee"), K("Rhea")]
    # the guild council list saves don't touch it
    gm_pick(w, c["Gina"], ["Cora", "Sam"])
    assert c["Rita"].eval_py("return ns.Guild:GetRaidLeaders()") == [K("Lee"), K("Rhea")]
    w.assert_no_errors()


@case
def a_member_gets_the_list_from_an_officer_who_logs_in_later():
    w, c = world(leaders=())
    c["Sam"].logout()
    w.tick(1)
    set_raid_leaders(w, c["Otto"], ["Rhea"])
    c["Gina"].logout()
    c["Otto"].logout()
    w.tick(1)
    c["Sam"].login()
    w.tick(40)
    assert c["Sam"].eval_py("return ns.Guild:GetRaidLeaders()") == [], "no officer online: nobody may relay it"
    c["Otto"].login()
    w.tick(60)
    assert c["Sam"].eval_py("return ns.Guild:GetRaidLeaders()") == [K("Rhea")]
    # a member logging in while an officer is online gets it through the HELLO
    c["Lee"].relog(reload=False)
    w.tick(40)
    assert c["Lee"].eval_py("return ns.Guild:GetRaidLeaders()") == [K("Rhea")]
    w.assert_no_errors()


@case
def a_raid_leader_taken_off_the_list_keeps_their_raids_visible():
    w, c = world()
    res = create_raid(c["Rhea"])
    assert res["ok"] is True, res
    w.tick(2)
    set_raid_leaders(w, c["Otto"], ["Lee"])
    for n, x in c.items():
        assert [r["id"] for r in raids(x)] == [res["r"]], n
    assert can_plan(c["Rhea"]) is False
    assert c["Rhea"].eval_py("local ok, e = ns.RaidPlan:CancelRaid(...); return { ok = ok }", res["r"])["ok"] is False
    # a raid "by" Rhea arriving after she left the list is not shown
    c["Sam"].eval("ns.Comm:Send({ t = 'RPU', k = 'E', r = { id = 'late1', rev = GetServerTime(), by = 'Sam-Thunderstrike',"
                  " t = GetServerTime() + 3600, i = 'kara', sz = 10 } }, 'GUILD', nil, 'data')")
    w.tick(2)
    assert all(r["id"] != "late1" for r in raids(c["Rita"]))
    w.assert_no_errors()


@case
def the_raid_leaders_window_is_for_officers_to_edit():
    w, c = world()
    otto, rita = c["Otto"], c["Rita"]
    otto.slash("/dz raids")
    w.tick(0.3)
    otto.eval("ns.RaidsUI:SetView('teams')")
    w.tick(0.3)
    otto.click(otto.eval("return ns.RaidsUI:GetPanel().leadersBtn"))
    w.tick(0.2)
    assert otto.eval("return DisasterZoneRaidLeaders:IsShown()") is True
    otto.eval("ns.RaidLeadersUI:Toggle(...)", K("Lee"))
    w.tick(0.2)
    assert otto.find_text("Unsaved changes", True, True)
    otto.click(otto.eval("return ns.RaidLeadersUI:GetWindow().save"))
    w.tick(2)
    assert rita.eval_py("return ns.Guild:GetRaidLeaders()") == [K("Lee"), K("Rhea")]
    rita.slash("/dz raids")
    w.tick(0.3)
    rita.eval("ns.RaidsUI:SetView('teams'); ns.RaidLeadersUI:Open()")
    w.tick(0.2)
    assert rita.find_text("Only officers and the Guild Master can change this list.", True, True)
    assert not rita.eval("return ns.RaidLeadersUI:GetWindow().save:IsShown()")
    assert rita.eval("return ns.RaidLeadersUI:Toggle(...)", K("Sam")) is False
    w.assert_no_errors()


@case
def a_raid_leader_gets_no_loot_council_data():
    w, c = world()
    rhea, cora = c["Rhea"], c["Cora"]
    assert tabs(rhea) == ["home", "mybis", "atlas", "raids", "mylog", "dungeons", "events", "polls", "members", "map", "games", "feedback", "changelog", "settings"], tabs(rhea)
    ct = tabs(cora)
    assert "council" in ct, ct
    cora.eval("ns.Ledger:Award(28477, ..., 'Karazhan:Attumen', 'test')", K("Rita"))
    mark = len(w.addon_log)
    rhea.relog(reload=False)
    w.tick(40)
    got = whispered_to(w, "Rhea", ("L", "R", "LG", "M"), mark)
    assert not got, [m["t"] for m in got]
    assert rhea.eval("return next(ns.db.lists or {}) == nil") is True
    assert rhea.eval("return next(ns.db.ledger or {}) == nil") is True
    w.assert_no_errors()


def run_raid(w, c, leader, members):
    w.make_raid([c[leader]] + [c[n] for n in members], leader=c[leader])
    w.tick(4)
    c[leader].slash("/dz raid start")
    w.tick(4)
    w.encounter(652, "Attumen the Huntsman")
    w.tick(2)
    return c[leader].eval("return ns.GroupRules:GetSession().id")


@case
def the_raid_log_for_council_and_raid_leaders_items_for_council_only():
    w, c = world()
    rhea, cora, lee = c["Rhea"], c["Cora"], c["Lee"]
    sid = run_raid(w, c, "Gina", ["Rhea", "Cora", "Rita", "Sam"])
    c["Gina"].eval("ns.Ledger:Award(28477, ..., 'Karazhan:Attumen', 'x')", K("Rita"))
    w.tick(2)
    c["Gina"].slash("/dz raid end")
    w.tick(3)
    # Rhea: the Raid log without items
    rhea.slash("/dz raids")
    w.tick(0.3)
    assert rhea.eval("return ns.RaidsUI:GetPanel().logBtn:IsShown()") is True
    rhea.eval("ns.RaidsUI:Select(...)", sid)
    w.tick(0.3)
    assert rhea.find_text("Attendance", True, True)
    assert not rhea.find_text("Awards", True, True) and not rhea.find_text(" items", True, True)
    # 1.3.5: the Attendance page; a player's page names the items received only for the loot council
    rhea.eval("ns.RaidsUI:SetMode('players', 8)")
    w.tick(0.3)
    rhea.eval("ns.RaidsUI:ShowAttendancePlayer(...)", K("Rita"))
    w.tick(0.3)
    assert "item" not in rhea.eval("return ns.RaidsUI:GetPanel().playerPage.banner.sub:GetText() or ''")
    # Cora (council, no planner): the Raid log with items
    cora.slash("/dz raids")
    w.tick(0.3)
    assert cora.eval("return ns.RaidsUI:GetPanel().logBtn:IsShown()") is True
    cora.eval("ns.RaidsUI:Select(...)", sid)
    w.tick(0.3)
    assert cora.find_text("Awards", True, True)
    cora.eval("ns.RaidsUI:ShowAttendancePlayer(...)", K("Rita"))
    w.tick(0.3)
    assert "1 item" in cora.eval("return ns.RaidsUI:GetPanel().playerPage.banner.sub:GetText() or ''")
    # Lee leads a group (loot council for that raid) but is neither: no Raid log view, no bench edits
    w.disband()
    w.tick(2)
    w.make_raid([lee, c["Sam"]], leader=lee)
    w.tick(4)
    assert lee.eval("return ns.Guild:AmICouncil()") is True
    lee.slash("/dz raids")
    w.tick(0.3)
    assert lee.eval("return ns.RaidsUI:GetPanel().logBtn:IsShown()") is False
    lee.eval("ns.RaidsUI:SetView('log')")
    assert lee.eval("return ns.RaidsUI:GetView()") == "upcoming"
    assert lee.eval("return ns.RaidLog:SetBench(..., 'Sam-Thunderstrike', true)", sid) is False
    w.assert_no_errors()


@case
def a_raid_leader_who_missed_the_raid_gets_the_log_at_login():
    w, c = world()
    rhea = c["Rhea"]
    rhea.logout()
    w.tick(1)
    sid = run_raid(w, c, "Gina", ["Rita", "Sam", "Cora"])
    c["Gina"].slash("/dz raid end")
    w.tick(5)
    w.disband()
    w.tick(2)
    rhea.login()
    w.tick(60)
    rec = rhea.eval_py("return ns.RaidLog:GetRaid(...)", sid)
    assert rec and rec.get("stop") and set(rec["att"]) >= {K("Rita"), K("Sam")}, rec
    w.assert_no_errors()


@case
def council_for_one_raid_sees_only_that_raids_lists_and_awards():
    w, c = world(leaders=())
    lee, rita, sam, cora = c["Lee"], c["Rita"], c["Sam"], c["Cora"]
    # Lee's client has cached lists of Rita and Sam from earlier raids, and an old award
    for n in ("Rita", "Sam"):
        lee.eval("local k = ...; ns.db.lists[k] = { rev = 3, ts = GetServerTime() - 86400, data = { cl = 'PRIEST', ph = {} } }",
                 K(n))
    cora.eval("ns.Ledger:Award(28477, ..., 'Karazhan:Attumen', 'old')", K("Sam"))
    w.tick(2)
    old = cora.eval("return ns.Ledger:GetEntries({})[1].id")
    lee.eval("local e = ...; local c = {}; for k, v in pairs(e) do c[k] = v end; c.ts = GetServerTime() - 7 * 86400;"
             " ns.Ledger:Merge(c, 'Cora-Thunderstrike')", cora.eval_py("return ns.Ledger:GetEntry(...)", old))
    assert lee.eval("return ns.Ledger:GetEntry(...) ~= nil", old) is True
    # Lee leads a raid with Sam only: raid-scope council for that raid
    w.make_raid([lee, sam], leader=lee)
    w.tick(5)
    assert lee.eval("return ns.Guild:AmICouncil()") is True
    keys = lee.eval_py("return ns.Store:GetAllKeys()") or []
    assert K("Sam") in keys and K("Rita") not in keys, keys
    vis = lee.eval_py("local out = {}; for _, e in ipairs(ns.Ledger:GetVisibleEntries({})) do out[#out + 1] = e.id end; return out") or []
    assert old not in vis, vis
    # an award during this raid is visible
    lee.eval("ns.Ledger:Award(28477, ..., 'Karazhan:Attumen', 'now')", K("Sam"))
    vis = lee.eval_py("local out = {}; for _, e in ipairs(ns.Ledger:GetVisibleEntries({})) do out[#out + 1] = e.id end; return out") or []
    assert len(vis) == 1 and vis[0] != old, (old, vis)
    # out of the raid: nothing
    w.disband()
    w.tick(3)
    assert lee.eval("return #ns.Ledger:GetVisibleEntries({})") == 0
    # the guild council sees everything
    assert cora.eval("return #ns.Ledger:GetVisibleEntries({}) == #ns.Ledger:GetEntries({})") is True
    w.assert_no_errors()


@case
def raid_leaders_manage_raids_and_their_groups_the_council_teams_and_groups():
    w, c = world()
    rhea, cora, sam = c["Rhea"], c["Cora"], c["Sam"]
    call = lambda cl, code, *a: cl.eval_py("local ok, r = " + code + "; return { ok = ok, r = r }", *a)
    # teams: the GM and the council, not raid leaders
    res = call(rhea, "ns.RaidPlan:SaveTeam(nil, 'X', {})")
    assert res["ok"] is False and "guild council" in res["r"], res
    res = call(cora, "ns.RaidPlan:SaveTeam(nil, 'Kara A', { ... })", K("Sam"))
    assert res["ok"] is True, res
    tid = res["r"]
    # raids: the GM and raid leaders, not the council
    assert call(cora, "ns.RaidPlan:CreateRaid({ i = 'kara', t = GetServerTime() + 86400 })")["ok"] is False
    res = call(rhea, "ns.RaidPlan:CreateRaid({ i = 'kara', t = GetServerTime() + 86400, tm = { ... } })", tid)
    assert res["ok"] is True, res
    occ = res["r"]
    w.tick(2)
    # a raid's groups: raid leaders and the council (and the GM); members not
    assert call(rhea, "ns.RaidPlan:SetGroups(..., { ['Sam-Thunderstrike'] = 1 })", occ)["ok"] is True
    w.tick(2)
    assert call(cora, "ns.RaidPlan:SetGroups(..., { ['Sam-Thunderstrike'] = 2 })", occ)["ok"] is True
    w.tick(2)
    assert call(sam, "ns.RaidPlan:SetGroups(..., { ['Sam-Thunderstrike'] = 3 })", occ)["ok"] is False
    for n, x in c.items():
        v = x.eval_py("return ns.RaidPlan:GetRaid(...)", occ)
        assert v and v["grp"] == {K("Sam"): 2}, (n, v)                  # the council's layout edit is shown
        assert x.eval_py("return ns.RaidPlan:GetTeam(...)", tid)["name"] == "Kara A", n
    # the UI follows: Rhea gets New raid but no New team; Cora the other way round
    for cl, raid_btn, team_btn in ((rhea, True, False), (cora, False, True)):
        cl.slash("/dz raids")
        w.tick(0.3)
        assert cl.eval("return ns.RaidsUI:GetPanel().newRaidBtn:IsShown()") is raid_btn
        cl.eval("ns.RaidsUI:SetView('teams'); if ns.RaidPlanUI:IsTeamBoard() then ns.RaidPlanUI:SelectTeam(ns.RaidPlanUI:GetSelectedTeam()) end")
        w.tick(0.3)
        assert cl.eval("return ns.RaidsUI:GetPanel().newTeamBtn:IsShown()") is team_btn
        assert cl.eval("return ns.RaidsUI:GetPanel().teams.picker.frame:IsShown()") is team_btn
        cl.eval("ns.RaidsUI:SetView('upcoming'); ns.RaidPlanUI:SelectRaid(...)", occ)
        cl.click(cl.eval("return ns.RaidsUI:GetPanel().upcoming.detail.tabGroups"))
        w.tick(0.3)
        assert cl.eval("return ns.RaidPlanUI:GetRaidGrid().opts.isEditable()") is True
        cl.click(cl.eval("return ns.RaidsUI:GetPanel().upcoming.detail.tabSignups"))
        assert cl.eval("return ns.RaidPlanUI:GetRaidActions().edit") is raid_btn
    w.assert_no_errors()


@case
def tsumil_can_pretend_roles_on_their_own_screen_only():
    w, c = world()
    t = Client(w, "Tsumil", guild_rank=3, class_file="DRUID")
    t.load_addon()
    w.tick(5)
    state = lambda: t.eval_py("""
      local G, me = ns.Guild, ns.Util.PlayerKey()
      return { gm = G:IsGM(me), officer = G:CanEditRaidLeaders(), council = G:AmICouncil(), guild = G:IsGuildCouncil(me),
               raids = ns.RaidPlan:CanOrganize(), teams = ns.RaidPlan:CanManageTeams(), groups = ns.RaidPlan:CanEditGroups(),
               log = G:AmIRaidLogMember(), gmEdit = G:CanEditGuildCouncil() }""")
    base = state()
    assert not any(base.values()), base
    expect = {
        "gm":         dict(gm=True, officer=True, council=True, guild=True, raids=True, teams=True, groups=True, log=True, gmEdit=True),
        "officer":    dict(gm=False, officer=True, council=False, guild=False, raids=False, teams=False, groups=False, log=False, gmEdit=False),
        "council":    dict(gm=False, officer=False, council=True, guild=True, raids=False, teams=True, groups=True, log=True, gmEdit=False),
        "raidleader": dict(gm=False, officer=False, council=False, guild=False, raids=True, teams=False, groups=True, log=True, gmEdit=False),
        "raider":     dict(gm=False, officer=False, council=False, guild=False, raids=False, teams=False, groups=False, log=False, gmEdit=False),
    }
    for role, want in expect.items():
        t.slash("/dz role " + role)
        w.tick(0.5)
        got = state()
        assert got == want, (role, got)
    t.slash("/dz role council")
    assert "council" in tabs(t)
    # other clients still see Tsumil's real role
    for n, x in c.items():
        assert x.eval("return ns.Guild:IsCouncil(...)", K("Tsumil")) is False, n
    # it survives a /reload; off restores the real role
    t.relog()
    w.tick(10)
    assert state()["guild"] is True
    n0 = len(t.chat_frame)
    t.slash("/dz role off")
    assert state() == base
    t.slash("/dz role")
    assert any("off (your real role)" in strip_codes(l) for l in printed_since(t, n0))
    # nobody else has the command
    n0 = len(c["Sam"].chat_frame)
    c["Sam"].slash("/dz role council")
    assert c["Sam"].eval("return ns.Guild:AmICouncil()") is False
    assert c["Sam"].eval("return ns.db.debugRole") is None
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

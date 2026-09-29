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
    cl.slash("/cdl")
    cl.world.tick(0.3)
    out = cl.eval_py("""
      local out = {}
      local f = CDLootMainFrame
      if not f or not f.Tabs then return out end
      for _, t in ipairs(f.Tabs) do if t:IsShown() then out[#out + 1] = t.cdlKey end end
      return out""") or []
    cl.slash("/cdl")
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
    otto.slash("/cdl raids")
    w.tick(0.3)
    otto.eval("ns.RaidsUI:SetView('teams')")
    w.tick(0.3)
    otto.click(otto.eval("return ns.RaidsUI:GetPanel().leadersBtn"))
    w.tick(0.2)
    assert otto.eval("return CDLootRaidLeaders:IsShown()") is True
    otto.eval("ns.RaidLeadersUI:Toggle(...)", K("Lee"))
    w.tick(0.2)
    assert otto.find_text("Unsaved changes", True, True)
    otto.click(otto.eval("return ns.RaidLeadersUI:GetWindow().save"))
    w.tick(2)
    assert rita.eval_py("return ns.Guild:GetRaidLeaders()") == [K("Lee"), K("Rhea")]
    rita.slash("/cdl raids")
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
    assert tabs(rhea) == ["mybis", "raids", "games", "settings"], tabs(rhea)
    ct = tabs(cora)
    assert "council" in ct and "loot" in ct, ct
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
    c[leader].slash("/cdl raid start")
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
    c["Gina"].slash("/cdl raid end")
    w.tick(3)
    # Rhea: the Raid log without items
    rhea.slash("/cdl raids")
    w.tick(0.3)
    assert rhea.eval("return ns.RaidsUI:GetPanel().logBtn:IsShown()") is True
    rhea.eval("ns.RaidsUI:Select(...)", sid)
    w.tick(0.3)
    assert rhea.find_text("Attendance", True, True)
    assert not rhea.find_text("Awards", True, True) and not rhea.find_text(" items", True, True)
    rhea.eval("ns.RaidsUI:SetMode('players', 8)")
    w.tick(0.3)
    last_col = rhea.eval_py("""
      local out = {}
      ns.RaidsUI:GetPanel().players.box:ForEachFrame(function(r) out[#out + 1] = r.cols[5]:GetText() or '' end)
      return out""")
    assert all(x in ("", "Items (last)") for x in last_col), last_col
    # Cora (council, no planner): the Raid log with items
    cora.slash("/cdl raids")
    w.tick(0.3)
    assert cora.eval("return ns.RaidsUI:GetPanel().logBtn:IsShown()") is True
    cora.eval("ns.RaidsUI:Select(...)", sid)
    w.tick(0.3)
    assert cora.find_text("Awards", True, True)
    # Lee leads a group (loot council for that raid) but is neither: no Raid log view, no bench edits
    w.disband()
    w.tick(2)
    w.make_raid([lee, c["Sam"]], leader=lee)
    w.tick(4)
    assert lee.eval("return ns.Guild:AmICouncil()") is True
    lee.slash("/cdl raids")
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
    c["Gina"].slash("/cdl raid end")
    w.tick(5)
    w.disband()
    w.tick(2)
    rhea.login()
    w.tick(60)
    rec = rhea.eval_py("return ns.RaidLog:GetRaid(...)", sid)
    assert rec and rec.get("stop") and set(rec["att"]) >= {K("Rita"), K("Sam")}, rec
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

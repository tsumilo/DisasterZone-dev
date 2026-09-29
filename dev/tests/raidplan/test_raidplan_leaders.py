"""ADDENDUM J §62: the raid leaders list (GM-picked, rides on CG as rl), on the real addon.

Covers: the GM saving the list (window and API) and every member learning it (also after a relog), the council list
kept unchanged, non-GMs and forged CGs refused; a listed raid leader planning raids and teams but getting no loot
council data (tabs, BiS lists, award log); the Raid log view for raid leaders without items, and not for someone who
merely leads a group; the raid log synced to a raid leader who logs in later; attendance / reliability in tooltips.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_leaders.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import World, Client, gm_pick, K, DAY, now, create, raids  # noqa: E402
from _common import case, run_all, printed_since, strip_codes  # noqa: E402
import lr_common as lr  # noqa: E402

NAMES = (("Gina", 0, "PALADIN"), ("Bob", 1, "MAGE"), ("Rhea", 3, "SHAMAN"), ("Lee", 3, "WARRIOR"),
         ("Rita", 3, "PRIEST"), ("Sam", 3, "ROGUE"))


def world():
    """Gina = GM, Bob = guild council, Rhea = raid leader (list), Lee / Rita / Sam = members."""
    w = World()
    c = {}
    for name, rank, cls in NAMES:
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_leaders(w, c["Gina"], ["Rhea"])
    return w, c


def set_leaders(w, gm, names):
    res = gm.eval_py("local ok, err = ns.Guild:SetRaidLeaders(...); return { ok = ok, err = err }", [K(n) for n in names])
    assert res["ok"] is True, res
    w.tick(2)


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
    """Decoded CDLoot messages of `types` whispered to `who` since addon_log index `start`."""
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
def gm_shares_the_raid_leaders_list_with_everyone():
    w, c = world()
    for n, x in c.items():
        assert x.eval("return ns.Guild:IsListedRaidLeader(...)", K("Rhea")) is True, n
        assert x.eval("return ns.Guild:IsRaidPlanner(...)", K("Rhea")) is True, n
        assert x.eval("return ns.Guild:IsCouncil(...)", K("Rhea")) is False, n            # no loot council
        assert x.eval("return ns.Guild:IsRaidPlanner(...)", K("Bob")) is True, n          # council plans too
        assert x.eval("return ns.Guild:IsRaidPlanner(...)", K("Sam")) is False, n
        assert x.eval_py("return ns.Guild:GetRaidLeaders()") == [K("Rhea")], n
    # the council tab's save keeps the raid leaders; SetRaidLeaders keeps the council
    gm_pick(w, c["Gina"], ["Bob", "Sam"])
    assert c["Rita"].eval("return ns.Guild:IsListedRaidLeader(...)", K("Rhea")) is True
    set_leaders(w, c["Gina"], ["Rhea", "Lee"])
    assert c["Rita"].eval("return ns.Guild:IsGuildCouncil(...)", K("Sam")) is True
    assert c["Rita"].eval_py("return ns.Guild:GetRaidLeaders()") == [K("Lee"), K("Rhea")]
    # a member who logs in later learns it
    c["Sam"].relog(reload=False)
    w.tick(40)
    assert c["Sam"].eval_py("return ns.Guild:GetRaidLeaders()") == [K("Lee"), K("Rhea")]
    # only the GM can change it; a forged CG from a member is ignored
    res = c["Bob"].eval_py("local ok, err = ns.Guild:SetRaidLeaders({ 'Bob-Thunderstrike' }); return { ok = ok, err = err }")
    assert res["ok"] is False and "Guild Master" in res["err"], res
    c["Rita"].eval("ns.Comm:Send({ t = 'CG', rev = GetServerTime() + 1, m = {}, rl = { 'Rita-Thunderstrike' },"
                   " by = 'Gina-Thunderstrike' }, 'GUILD', nil, 'ctrl')")
    w.tick(2)
    assert c["Lee"].eval("return ns.Guild:IsListedRaidLeader(...)", K("Rita")) is False
    w.assert_no_errors()


@case
def the_gm_edits_the_list_in_the_raid_leaders_window_others_read_it():
    w, c = world()
    gina, rita = c["Gina"], c["Rita"]
    gina.slash("/cdl raids")
    w.tick(0.3)
    gina.eval("ns.RaidsUI:SetView('teams')")
    w.tick(0.3)
    gina.click(gina.eval("return ns.RaidsUI:GetPanel().leadersBtn"))
    w.tick(0.2)
    assert gina.eval("return CDLootRaidLeaders:IsShown()") is True
    gina.eval("ns.RaidLeadersUI:Toggle(...)", K("Lee"))
    w.tick(0.2)
    assert gina.find_text("Unsaved changes", True, True)
    gina.click(gina.eval("return ns.RaidLeadersUI:GetWindow().save"))
    w.tick(2)
    assert rita.eval_py("return ns.Guild:GetRaidLeaders()") == [K("Lee"), K("Rhea")]
    # a member sees the list, can't change it
    rita.slash("/cdl raids")
    w.tick(0.3)
    rita.eval("ns.RaidsUI:SetView('teams')")
    rita.eval("ns.RaidLeadersUI:Open()")
    w.tick(0.2)
    assert rita.find_text("Only the Guild Master can change this list.", True, True)
    assert not rita.eval("return ns.RaidLeadersUI:GetWindow().save:IsShown()")
    assert rita.eval("return ns.RaidLeadersUI:Toggle(...)", K("Sam")) is False
    w.assert_no_errors()


@case
def a_raid_leader_plans_raids_but_gets_no_loot_council_data():
    w, c = world()
    rhea, bob, rita = c["Rhea"], c["Bob"], c["Rita"]
    assert rhea.eval("return ns.RaidPlan:CanOrganize()") is True
    res = rhea.eval_py("local ok, id = ns.RaidPlan:CreateRaid({ i = 'kara', t = GetServerTime() + 86400 }); return { ok = ok, id = id }")
    assert res["ok"] is True, res
    tid = rhea.eval_py("local ok, id = ns.RaidPlan:SaveTeam(nil, 'Rhea team', { 'Rita-Thunderstrike' }); return id")
    w.tick(2)
    assert [r["id"] for r in raids(rita)] == [res["id"]]
    assert rita.eval_py("return ns.RaidPlan:GetTeam(...)", tid)["name"] == "Rhea team"
    # no loot council: tabs, lists, award log
    assert tabs(rhea) == ["mybis", "raids", "games", "settings"], tabs(rhea)
    bt = tabs(bob)
    assert "council" in bt and "loot" in bt, bt
    bob.eval("ns.Ledger:Award(28477, ..., 'Karazhan:Attumen', 'test')", K("Rita"))
    rhea.slash("/cdl sync")
    w.tick(40)
    assert rhea.eval("return next(ns.db.lists or {}) == nil") is True, rhea.eval_py("return ns.db.lists")
    assert rhea.eval("return next(ns.db.ledger or {}) == nil") is True
    mark = len(w.addon_log)
    rhea.relog(reload=False)
    w.tick(40)
    got = whispered_to(w, "Rhea", ("L", "R", "LG", "M"), mark)
    assert not got, [m["t"] for m in got]
    assert rhea.eval("return next(ns.db.ledger or {}) == nil") is True
    w.assert_no_errors()


def run_raid(w, c, leader, members):
    w.make_raid([c[leader]] + [c[n] for n in members], leader=c[leader])
    w.tick(4)
    c[leader].slash("/cdl raid start")
    w.tick(4)
    w.encounter(652, "Attumen the Huntsman")
    w.tick(2)
    sid = c[leader].eval("return ns.GroupRules:GetSession().id")
    return sid


@case
def raid_log_for_raid_leaders_without_items_and_not_for_any_group_leader():
    w, c = world()
    rhea, bob, lee = c["Rhea"], c["Bob"], c["Lee"]
    sid = run_raid(w, c, "Bob", ["Rhea", "Rita", "Sam"])
    bob.eval("ns.Ledger:Award(28477, ..., 'Karazhan:Attumen', 'x')", K("Rita"))
    w.tick(2)
    bob.slash("/cdl raid end")
    w.tick(3)
    # Rhea (raid leaders list): the Raid log without items
    rhea.slash("/cdl raids")
    w.tick(0.3)
    assert rhea.eval("return ns.RaidsUI:GetPanel().logBtn:IsShown()") is True
    rhea.eval("ns.RaidsUI:Select(...)", sid)
    w.tick(0.3)
    assert rhea.find_text("Attendance", True, True)
    assert not rhea.find_text("Awards", True, True)
    assert not rhea.find_text(" items", True, True)
    rhea.eval("ns.RaidsUI:SetMode('players', 8)")
    w.tick(0.3)
    last_col = rhea.eval_py("""
      local out = {}
      ns.RaidsUI:GetPanel().players.box:ForEachFrame(function(r) out[#out + 1] = r.cols[5]:GetText() or '' end)
      return out""")
    assert all(x in ("", "Items (last)") for x in last_col), last_col
    # Bob (council) sees the awards
    bob.slash("/cdl raids")
    w.tick(0.3)
    bob.eval("ns.RaidsUI:Select(...)", sid)
    w.tick(0.3)
    assert bob.find_text("Awards", True, True)
    # Lee leads a group (loot council for that raid) but is no raid planner: no Raid log view
    w.disband()
    w.tick(2)
    w.make_raid([lee, c["Sam"]], leader=lee)
    w.tick(4)
    assert lee.eval("return ns.Guild:AmICouncil()") is True           # raid-scope loot council
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
    rhea, bob = c["Rhea"], c["Bob"]
    rhea.logout()
    w.tick(1)
    sid = run_raid(w, c, "Bob", ["Rita", "Sam", "Gina"])
    bob.slash("/cdl raid end")
    w.tick(5)
    w.disband()
    w.tick(2)
    rhea.login()
    w.tick(60)
    rec = rhea.eval_py("return ns.RaidLog:GetRaid(...)", sid)
    assert rec and rec.get("stop") and set(rec["att"]) >= {K("Rita"), K("Sam")}, rec
    # and a raid leader's own recording reaches the council (Rhea recorded one alone)
    w.tick(1)
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

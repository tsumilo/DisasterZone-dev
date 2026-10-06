"""Raids > New raid / Edit raid as a sheet (1.3.2 makeover) and raids of several instances, on the real addon.

Covers: the sheet over the Raids tab (the page under it steps aside and comes back), the raid tiles (several picked in
the order clicked: the night's order; the size follows the larger raid until set by hand; mixed sizes allowed), the
preview card ("GRUUL + MAG · 25", "Gruul + Mag"), Sign-ups as one choice (Everyone / Teams + invited / Private ->
lk / pv), team chips per lineup with how many they invite and the who-can-sign-up line, saving a raid of two
instances (i + ix, synced, named "Gruul + Mag"), editing it (order, taking one out; a weekly raid's one week holds its
first instance alone while the others keep both), an older client's copy without ix never replacing the full one,
the board's raid filter finding it under either instance, the bosses of every instance in night order (Assignments,
GetRaidBosses), the running raid's link matching it in either instance, a linked record's boss total over both.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_sheet.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import world, K, DAY, now, create, raid, raids, call  # noqa: E402
from _common import case, run_all, strip_codes  # noqa: E402

P = "ns.RaidsUI:GetPanel()"
ED = "ns.RaidPlanUI:GetEditor()"
ROOT = "ns.db.raidplan[ns.Guild:GetGuildKey()]"


def lst(v):
    if v is None:
        return []
    return list(v.values()) if isinstance(v, dict) else list(v)


def open_tab(w, cl):
    cl.slash("/dz raids")
    w.tick(0.5)


def shown(cl, expr):
    return cl.eval("local f = %s; return f ~= nil and f:IsShown() and f:IsVisible()" % expr) is True


def text_of(cl, expr):
    return strip_codes(cl.eval("local f = %s; return f and f:GetText()" % expr) or "")


def f(cl):
    return cl.eval_py("local f = %s.f; return { list = f.list, sz = f.sz, i = f.i, ix = f.ix, access = f.access, "
                      "lk = f.lk, pv = f.pv }" % ED)


def cards(cl):
    """The team cards shown: [(value, "name · lineup count", picked)]."""
    rows = cl.eval_py("local out = {}; for _, c in ipairs(%s.cards) do if c:IsShown() then out[#out + 1] = "
                      "{ c.entry.value, c.name:GetText() .. c.what:GetText() .. ' ' .. c.count:GetText(), "
                      "c.check:IsShown() } end end; return out" % ED)
    return [tuple(x) for x in lst(rows)]


def save_team(cl, name, members, lineups):
    out = []
    for l in lineups:
        e = {k: v for k, v in l.items() if k in ("name", "size")}
        e["groups"] = {K(n): g for n, g in l.get("groups", {}).items()}
        out.append(e)
    res = cl.eval_py("local n, m, o = ...; local ok, r = ns.RaidPlan:SaveTeam(nil, n, m, o); return { ok = ok, r = r }",
                     name, [K(m) for m in members], {"lineups": out})
    assert res["ok"] is True, res
    return res["r"]


# ------------------------------------------------------------------------------------------------------------------
@case
def the_sheet_makes_one_raid_of_two_instances():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    open_tab(w, bob)
    assert shown(bob, P + ".upcoming")
    bob.click(bob.eval("return %s.newRaidBtn" % P))
    w.tick(0.3)
    # a sheet over the tab: the page under it steps aside
    assert shown(bob, ED) and not shown(bob, P + ".upcoming") and not shown(bob, P + ".newRaidBtn")
    assert text_of(bob, ED + ".title") == "New raid"
    assert f(bob)["list"] == ["kara"] and f(bob)["sz"] == 10
    # Gruul, then Magtheridon (Karazhan out): the order clicked is the night's; the size follows: 25
    bob.eval("ns.RaidPlanUI:ToggleEditorRaid('kara'); ns.RaidPlanUI:ToggleEditorRaid('gruul');"
             " ns.RaidPlanUI:ToggleEditorRaid('mag')")
    w.tick(0.2)
    st = f(bob)
    assert st["list"] == ["gruul", "mag"] and st["i"] == "gruul" and lst(st["ix"]) == ["mag"] and st["sz"] == 25, st
    badges = bob.eval_py("local out = {}; for _, t in ipairs(%s.tiles) do if t.badge:IsShown() then "
                         "out[t.key] = t.num:GetText() end end; return out" % ED)
    assert badges == {"gruul": "1", "mag": "2"}, badges
    # the preview: the board's card
    assert text_of(bob, ED + ".preview.inst") == "GRUUL + MAG · 25"
    assert text_of(bob, ED + ".preview.t1") == "Gruul + Mag"
    assert bob.eval("return %s.preview.art2:IsShown()" % ED) is True
    assert text_of(bob, ED + ".who").startswith("Every guild member can sign up.")
    bob.click(bob.eval("return %s.saveBtn" % ED))
    w.tick(2)
    # saved, the sheet gone and the page back, on the new raid's page
    assert not shown(bob, ED) and shown(bob, P + ".upcoming")
    occ = bob.eval("return ns.RaidPlanUI:GetSelectedRaid()")
    v = raid(rita, occ)
    assert v["i"] == "gruul" and lst(v["ix"]) == ["mag"] and v["sz"] == 25 and v["ml"] == 70, v
    assert rita.eval("return ns.RaidPlan:GetRaidName(ns.RaidPlan:GetRaid(...))", occ) == "Gruul + Mag"
    assert lst(rita.eval_py("return ns.RaidPlan:GetRaidInstances(ns.RaidPlan:GetRaid(...))", occ)) == ["gruul", "mag"]
    assert rita.eval("return ns.RaidComp:ShortRaidName(ns.RaidPlan:GetRaid(...))", occ) == "Gruul + Mag"
    # the board's raid filter finds it under either instance
    for key, n in (("mag", 1), ("gruul", 1), ("ssc", 0)):
        bob.eval("ns.RaidPlanUI:ShowBoard(); ns.RaidPlanUI:SetFilter(...)", key)
        w.tick(0.3)
        assert bool(bob.find_text("Gruul + Mag", True, True)) == (n == 1), key
    # mixed sizes are allowed: Karazhan + Gruul is a 25 (no size to pick: the raids say it); Other alone a 25
    bob.eval("ns.RaidPlanUI:OpenEditor(); ns.RaidPlanUI:ToggleEditorRaid('gruul')")
    assert f(bob)["sz"] == 25 and f(bob)["list"] == ["kara", "gruul"]
    bob.eval("ns.RaidPlanUI:ToggleEditorRaid('gruul')")
    assert f(bob)["sz"] == 10
    bob.eval("ns.RaidPlanUI:ToggleEditorRaid('kara'); ns.RaidPlanUI:ToggleEditorRaid('other')")
    assert f(bob)["sz"] == 25
    bob.eval("ns.RaidPlanUI:ToggleEditorRaid('other'); ns.RaidPlanUI:ToggleEditorRaid('kara');"
             " ns.RaidPlanUI:ToggleEditorRaid('gruul'); ns.RaidPlanUI:ToggleEditorRaid('mag')")
    # the date strip: a week of days, the picked one (tomorrow) lit; the time steps 15 minutes
    days = bob.eval_py("local out = {}; for _, c in ipairs(%s.days) do out[#out + 1] = { c.wd:GetText(), "
                       "c.dn:GetText(), c.picked or false } end; return out" % ED)
    days = [tuple(x) for x in lst(days)]
    assert len(days) == 7 and days[0][0] == "TODAY", days
    assert bob.eval("return %s.days[2].edges[1]:GetVertexColor() > 0.8" % ED) is True    # (gold: tomorrow)
    bob.eval("ns.RaidPlanUI:StepEditorTime(1); ns.RaidPlanUI:StepEditorTime(1)")
    assert text_of(bob, ED + ".timeStep.fs") == "20:30"
    bob.eval("ns.RaidPlanUI:PickEditorDay(3)")
    assert bob.eval("return %s.days[4].edges[1]:GetVertexColor() > 0.8" % ED) is True
    # the week arrows move the week on its own (the picked day stays picked, out of sight), and back
    first = lambda: bob.eval("return %s.days[1].d" % ED)
    day = lambda n: bob.eval("return date('*t', GetServerTime() + ... * 86400).day", n)
    assert first() == day(0) and bob.eval("return %s.prevWeek:IsEnabled()" % ED) is False
    bob.click(bob.eval("return %s.nextWeek" % ED))
    assert first() == day(7)
    bob.click(bob.eval("return %s.nextWeek" % ED))
    assert first() == day(14)
    bob.click(bob.eval("return %s.prevWeek" % ED))
    assert first() == day(7)
    assert bob.eval_py("local f = %s.f; return { f.y, f.m, f.d }" % ED) == bob.eval_py(
        "local t = date('*t', GetServerTime() + 3 * 86400); return { t.year, t.month, t.day }")
    # picking a day there moves nothing; a day from the calendar brings the week to it
    bob.click(bob.eval("return %s.days[3]" % ED))
    assert first() == day(7) and bob.eval("return %s.f.d" % ED) == day(9)
    bob.eval("ns.RaidPlanUI:PickEditorDay(30)")
    assert first() == day(29)
    # nothing picked: an error, nothing saved
    bob.eval("for _, k in ipairs({ 'kara', 'gruul', 'mag' }) do ns.RaidPlanUI:ToggleEditorRaid(k) end")
    assert f(bob)["list"] == [] and shown(bob, ED + ".pick")
    bob.click(bob.eval("return %s.saveBtn" % ED))
    assert text_of(bob, ED + ".err") == "Pick a raid above."
    bob.click(bob.eval("return %s.cancelBtn" % ED))
    assert not shown(bob, ED) and len(raids(rita)) == 1
    # members can't open it
    n0 = len(rita.chat_frame)
    open_tab(w, rita)
    rita.eval("ns.RaidPlanUI:OpenEditor()")
    assert not shown(rita, ED) if rita.eval("return ns.RaidPlanUI:GetEditor() ~= nil") else True
    w.assert_no_errors()


@case
def sign_ups_and_team_chips():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam"], [
        {"name": "Kara A", "size": 10, "groups": {"Lee": 1, "Rita": 1}},
        {"name": "Kara B", "size": 10, "groups": {"Sam": 1}},
        {"name": "SSC", "size": 25, "groups": {"Lee": 1}}])
    w.tick(2)
    open_tab(w, bob)
    bob.eval("ns.RaidPlanUI:OpenEditor()")
    # a 10: one card per 10-man lineup, with how many it invites
    chips = cards(bob)
    assert [(t, k) for _, t, k in chips] == [("Main · Kara A 2", False), ("Main · Kara B 1", False)], chips
    bob.eval("ns.RaidPlanUI:PickEditorTeam(...)", chips[1][0])          # Kara B
    bob.click(bob.eval("return %s.access[2]" % ED))                     # Teams + invited
    w.tick(0.2)
    assert f(bob)["access"] == "locked" and f(bob)["lk"] is True and f(bob)["pv"] is False
    assert text_of(bob, ED + ".who") == "1 can sign up (Main · Kara B); the rest can ask to join. Level 70 only."
    # the other lineup of the same team replaces it
    bob.eval("ns.RaidPlanUI:PickEditorTeam(...)", chips[0][0])
    kinds = [ch[2] for ch in cards(bob)]
    assert kinds == [True, False], kinds
    bob.click(bob.eval("return %s.access[3]" % ED))                     # Private
    assert f(bob)["pv"] is True and text_of(bob, ED + ".who").startswith("Private: only these 2 players see it")
    bob.click(bob.eval("return %s.saveBtn" % ED))
    w.tick(2)
    occ = bob.eval("return ns.RaidPlanUI:GetSelectedRaid()")
    v = raid(rita, occ)
    ka = bob.eval_py("return ns.RaidPlan:GetTeam(...).lineups[1].id", tid)
    assert v["lk"] is True and v["pv"] is True and lst(v["tm"]) == [tid] and v["tl"] == {tid: ka}, v
    # a 25: the team's one 25 lineup, no lineup name needed... the chip says it (the team has others)
    bob.eval("ns.RaidPlanUI:OpenEditor(); ns.RaidPlanUI:ToggleEditorRaid('kara'); ns.RaidPlanUI:ToggleEditorRaid('ssc')")
    texts = [ch[1] for ch in cards(bob)]
    assert texts == ["Main · SSC 1"], texts
    bob.eval("ns.RaidPlanUI:CloseEditor()")
    w.assert_no_errors()


@case
def editing_a_raid_of_two_instances():
    w, c = world()
    bob, rita, lee = c["Bob"], c["Rita"], c["Lee"]
    one = create(bob, i="ssc", ix=["tk"], t=now(bob) + DAY)
    weekly = create(bob, i="gruul", ix=["mag"], t=now(bob) + 2 * DAY, weekly=True)
    w.tick(2)
    assert raid(rita, one)["sz"] == 25 and lst(raid(rita, one)["ix"]) == ["tk"]
    open_tab(w, bob)
    # the sheet opens with the night in order; Tempest Keep first, then Serpentshrine
    bob.eval("ns.RaidPlanUI:OpenEditor(...)", one)
    assert f(bob)["list"] == ["ssc", "tk"] and text_of(bob, ED + ".title") == "Edit raid"
    bob.eval("ns.RaidPlanUI:ToggleEditorRaid('ssc'); ns.RaidPlanUI:ToggleEditorRaid('ssc')")
    assert f(bob)["list"] == ["tk", "ssc"]
    bob.click(bob.eval("return %s.saveBtn" % ED))
    w.tick(2)
    v = raid(rita, one)
    assert v["i"] == "tk" and lst(v["ix"]) == ["ssc"] and rita.eval("return ns.RaidPlan:GetRaidName(...)", v) == "TK + SSC"
    # a weekly raid: this week only without Magtheridon; the other weeks keep both
    ws = [r for r in raids(rita) if r.get("weekly")]
    w0, w1 = ws[0]["id"], ws[1]["id"]
    bob.eval("ns.RaidPlanUI:OpenEditor(...); ns.RaidPlanUI:ToggleEditorRaid('mag')", w0)
    assert shown(bob, ED + ".saveAllBtn") and text_of(bob, ED + ".saveBtn") == "This week only"
    bob.click(bob.eval("return %s.saveBtn" % ED))
    w.tick(2)
    assert lst(rita.eval_py("return ns.RaidPlan:GetRaidInstances(ns.RaidPlan:GetRaid(...))", w0)) == ["gruul"]
    assert lst(rita.eval_py("return ns.RaidPlan:GetRaidInstances(ns.RaidPlan:GetRaid(...))", w1)) == ["gruul", "mag"]
    # an older client's copy of a version without ix never replaces the full one
    old = rita.eval_py("local e = %s.E[...]; local copy = {}; for k, v in pairs(e) do copy[k] = v end; copy.ix = nil; "
                       "return copy" % ROOT, one)
    rita.eval("local r, to = ...; ns.Comm:Send({ t = 'RPG', o = r.id, e = r }, 'WHISPER', to, 'data')", old, K("Lee"))
    w.tick(2)
    assert lst(raid(lee, one)["ix"]) == ["ssc"]
    # hostile lists are refused whole: an unknown instance, a double
    for bad in (["tk", "nope"], ["mag", "mag"]):
        res = call(bob, "CreateRaid", {"i": "gruul", "ix": bad, "t": now(bob) + 3 * DAY})
        assert res["ok"] is False, (bad, res)
    w.assert_no_errors()


@case
def bosses_links_and_boss_totals_cover_every_instance():
    w, c = world()
    bob = c["Bob"]
    occ = create(bob, i="gruul", ix=["mag"], t=now(bob) + 3600)
    w.tick(2)
    # the bosses of the night, in its order: Gruul's Lair's, then Magtheridon's
    bosses = lst(bob.eval_py("return ns.Strategy:GetRaidBosses(ns.RaidPlan:GetRaid(...))", occ))
    raids_ = []
    for b in bosses:
        if not raids_ or raids_[-1] != b["raid"]:
            raids_.append(b["raid"])
    names = [b["name"] for b in bosses]
    assert len(raids_) == 2 and "Gruul the Dragonkiller" in names and "Magtheridon" in names, names
    assert names.index("Gruul the Dragonkiller") < names.index("Magtheridon"), names
    # the running raid links to it while standing in either instance (not in Serpentshrine)
    roster = {K("Bob"): True, K("Lee"): True}
    for instID, want in ((565, occ), (544, occ), (548, None)):
        got = bob.eval("local s, r, i, o = ...; return (ns.RaidLink:Match(s, r, i, o))", now(bob), roster, instID, occ)
        assert got == want, (instID, got)
    # a raid-log record linked to it counts the bosses of both instances
    total = bob.eval("return ns.RaidLog:GetRecordBossTotal({ pl = ..., instID = 544 })", occ)
    gruul = bob.eval("return ns.RaidLog:GetBossTotal(565)")
    mag = bob.eval("return ns.RaidLog:GetBossTotal(544)")
    assert gruul and mag and total == gruul + mag, (total, gruul, mag)
    assert bob.eval("return ns.RaidLog:GetRecordBossTotal({ instID = 544 })") == mag
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

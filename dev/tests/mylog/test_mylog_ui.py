"""My Log page (UI/MyLogUI.lua) and its queries (MyLog:GetInstances / GetRuns / BossRows / RunNumbers).

Covers: the page under Raids; off -> the explainer and its Turn on button; on without pulls -> "No boss pulls yet";
pulls grouped into runs (raid nights) per instance, newest first; a boss row's number from the run's kill and its
change from my previous kill of that boss in the same spec (another spec only when there is none, marked *); wipes
showing the lowest boss health; the sparkline holding up to 8 kills; the view following the role played in the run
(healer -> Healing) until I pick one; tiles with the change from the run before; the run picker; a recorded pull
appearing while the page is open.

Run: luaenv\\Scripts\\python.exe tests\\mylog\\test_mylog_ui.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, install_helpers  # noqa: E402

WEEK = 7 * 86400

SEED = r"""
local now = GetServerTime()
local WEEK = 7 * 86400
local chars = DisasterZoneLogDB.chars
local key = ns.Util.PlayerKey()
local c = { n = 0, pulls = {} }
chars[key] = c
local function pull(at, enc, boss, kill, dps, opts)
  opts = opts or {}
  c.n = c.n + 1
  local p = { id = c.n, at = at, enc = enc, boss = boss, zone = opts.zone or "Serpentshrine Cavern",
    iid = opts.iid or 548, kill = kill, dur = 240, spec = opts.spec or "Destruction", role = opts.role or "caster",
    cls = "WARLOCK", ilvl = opts.ilvl or 120, pct = (not kill) and opts.pct or nil, deaths = {},
    s = { d = dps * 240, dps = dps, hps = opts.hps or 0, h = (opts.hps or 0) * 240, oh = opts.oh or 0, sh = 0,
          t = 0, dtps = opts.dtps or 100, act = opts.act or 0.9, dc = opts.dc or 0, cpm = 38, sw = 0, avd = 0 } }
  c.pulls[#c.pulls + 1] = p
  return p
end
-- three weekly SSC runs, Hydross improving; Vashj wipes in the last one; one TK run in between
for w = 3, 1, -1 do
  local t = now - w * WEEK
  pull(t, 623, "Hydross the Unstable", true, 1000 + (3 - w) * 100, { ilvl = 118 + (3 - w) })
  pull(t + 1800, 624, "The Lurker Below", true, 1300 - (3 - w) * 50, { act = 0.85 + (3 - w) * 0.02 })
end
pull(now - 2 * WEEK + 3600 * 24, 730, "Al'ar", true, 900, { zone = "Tempest Keep", iid = 550 })
local t = now - 3600
pull(t, 623, "Hydross the Unstable", true, 1400, { ilvl = 124, dc = 1 })
pull(t + 900, 624, "The Lurker Below", true, 1250)
pull(t + 2400, 628, "Lady Vashj", false, 1100, { pct = 42.5, dc = 1 })
pull(t + 3000, 628, "Lady Vashj", false, 1150, { pct = 18.3 })
ns:Fire("MYLOG_CHANGED")
"""


def client(enabled=True, seed=True):
    w, c = solo("Lux", class_file="WARLOCK", tick=3)
    install_helpers(c)
    if enabled:
        c.eval("ns.DB:SetSetting('mylog.enabled', true)")
    if seed:
        c.eval(SEED)
    return w, c


def open_page(w, c):
    c.eval("ns.MainFrame:Open('mylog')")
    w.tick(0.5)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "mylog"


def rows(c):
    return c.eval_py("""
      local out = {}
      for _, r in ipairs(ns.MyLogUI:GetBossRows()) do
        out[#out + 1] = { boss = r.boss, pulls = r.pulls, value = r.value, change = r.change, best = r.best,
                          spark = r.spark, same = r.sameSpec }
      end
      return out""") or []


@case
def queries_group_runs_and_compare_kills():
    w, c = client()
    inst = c.eval_py("return ns.MyLog:GetInstances()")
    assert [i["name"] for i in inst] == ["Serpentshrine Cavern", "Tempest Keep"], inst
    runs = c.eval_py("local r = ns.MyLog:GetRuns(548); local o = {}; for i, x in ipairs(r) do o[i] = "
                     "{ n = #x.pulls, k = x.kills, w = x.wipes } end; return o")
    assert runs == [{"n": 4, "k": 2, "w": 2}, {"n": 2, "k": 2, "w": 0}, {"n": 2, "k": 2, "w": 0},
                    {"n": 2, "k": 2, "w": 0}], runs
    r = c.eval_py("""local run = ns.MyLog:GetRuns(548)[1]
      local out = {}
      for _, x in ipairs(ns.MyLog:BossRows(run, 'damage')) do
        out[#out + 1] = { boss = x.boss, value = x.value, change = x.change, best = x.best, spark = x.spark }
      end
      return out""")
    assert [x["boss"] for x in r] == ["Hydross the Unstable", "The Lurker Below", "Lady Vashj"]
    hyd = r[0]
    assert hyd["value"] == 1400 and abs(hyd["change"] - (1400 - 1200) / 1200 * 100) < 0.01
    assert hyd["spark"] == [1000, 1100, 1200, 1400]
    assert abs(r[1]["change"] - (1250 - 1200) / 1200 * 100) < 0.01
    assert r[2].get("value") is None and r[2]["best"] == 18.3
    nums = c.eval_py("local r = ns.MyLog:GetRuns(548); return ns.MyLog:RunNumbers(r[1], 'damage')")
    assert nums["value"] == (1400 + 1250) / 2 and nums["deaths"] == 2 and nums["kills"] == 2


@case
def other_spec_kills_count_only_when_there_is_no_same_spec_kill():
    w, c = client()
    c.eval("""local p = ns.MyLog:GetPulls()
      for _, x in ipairs(p) do if x.enc == 624 and x.at > GetServerTime() - 7200 then x.spec = 'Affliction' end end""")
    r = c.eval_py("""local x = ns.MyLog:BossRows(ns.MyLog:GetRuns(548)[1], 'damage')[2]
      return { same = x.sameSpec, change = x.change, spark = x.spark }""")
    assert r["same"] is False and r["spark"][-1] == 1250 and len(r["spark"]) == 4
    c.eval("""for _, x in ipairs(ns.MyLog:GetPulls()) do if x.enc == 623 then x.spec = 'Affliction' end end""")
    r = c.eval_py("""local x = ns.MyLog:BossRows(ns.MyLog:GetRuns(548)[1], 'damage')[1]
      return { same = x.sameSpec, spark = x.spark }""")
    assert r["same"] is True and r["spark"] == [1000, 1100, 1200, 1400], r


@case
def off_shows_the_explainer_and_turns_on():
    w, c = client(enabled=False, seed=False)
    open_page(w, c)
    p = "ns.MainFrame:GetPanel('mylog')"
    assert c.eval("return %s.empty:IsShown()" % p) is True
    assert c.eval("return %s.empty.title:GetText()" % p) == "My Log is off"
    c.click(c.eval("return %s.empty.btn" % p))
    assert c.eval("return ns.MyLog:IsEnabled()") is True
    assert c.eval("return %s.empty.title:GetText()" % p) == "No boss pulls yet"
    assert c.eval("return %s.empty.btn:IsShown()" % p) is False


@case
def page_shows_the_newest_run_against_the_one_before():
    w, c = client()
    open_page(w, c)
    p = "ns.MainFrame:GetPanel('mylog')"
    assert c.eval("return %s.body:IsShown()" % p) is True
    rs = rows(c)
    assert [r["boss"] for r in rs] == ["Hydross the Unstable", "The Lurker Below", "Lady Vashj"]
    hero = c.eval_py("local h = %s.hero; return { h.num:GetText(), h.metric:GetText(), h.change:IsShown() and h.change.fs:GetText(), "
                     "(function() local o = {}; for _, x in ipairs(h.cells) do o[#o + 1] = x.lab:GetText() .. '=' .. x.val:GetText() .. ' ' .. x.delta:GetText() end; return table.concat(o, '|') end)(), "
                     "h.best:IsShown() }" % p)
    assert hero[0] == "1,325" and hero[1] == "Avg DPS on kills", hero
    assert "+10.4%" in hero[2], hero              # 1325 vs 1200
    assert "Item level=121.0 +1" in hero[3] and "Deaths=2 +2" in hero[3] and "Active=90.0%" in hero[3], hero
    assert hero[4] is True                          # the best night here
    crumb = c.eval_py("local o = {}; for _, b in ipairs(%s.crumb.parts) do if b:IsShown() then o[#o + 1] = b.fs:GetText() end end; return o" % p)
    assert crumb == ["My Log", "Serpentshrine Cavern"], crumb
    # a card per boss, the wipe-only boss as progress
    cards = c.eval_py("local o = {}; for _, x in ipairs(%s.cards) do if x:IsShown() then o[#o + 1] = { x.name:GetText(), "
                      "x.num:IsShown() and x.num:GetText() or false, x.prog:IsShown() } end end; return o" % p)
    assert cards == [["Hydross the Unstable", "1,400", False], ["The Lurker Below", "1,250", False],
                     ["Lady Vashj", False, True]], cards
    # the nights strip: four SSC nights, the newest picked
    bars = c.eval_py("local o = {}; for _, b in ipairs(%s.nights) do if b:IsShown() then o[#o + 1] = b.on and 1 or 0 end end; return o" % p)
    assert bars == [0, 0, 0, 1], bars
    assert c.eval("return %s.deathsBtn:GetText()" % p) == "Deaths"      # (the seed has no recaps)
    # the trend chart drew lines and dots
    assert c.eval("return (%s.hero.trend.used.line or 0)" % p) == 6       # 3 segments + their glow


@case
def views_follow_the_role_until_picked():
    w, c = client()
    c.eval("for _, x in ipairs(ns.MyLog:GetPulls()) do x.role = 'healer'; x.spec = 'Holy' end")
    open_page(w, c)
    p = "ns.MainFrame:GetPanel('mylog')"
    assert c.eval("return %s.hero.metric:GetText()" % p) == "Avg HPS on kills"
    assert c.eval("return %s.hero.cells[1].lab:GetText()" % p) == "Overheal"
    c.eval("ns.MyLogUI:SetView('damage')")
    assert c.eval("return %s.hero.metric:GetText()" % p) == "Avg DPS on kills"
    c.eval("ns.MyLogUI:SetView('tanking')")
    assert c.eval("return %s.hero.metric:GetText()" % p) == "Avg damage taken per second"
    on = c.eval_py("local o = {}; for _, b in ipairs(%s.seg.buttons) do if b.on then o[#o + 1] = b.key end end; return o" % p)
    assert on == ["tanking"], on


@case
def run_picker_and_instances():
    w, c = client()
    open_page(w, c)
    p = "ns.MainFrame:GetPanel('mylog')"
    c.eval("ns.MyLogUI:SelectRun(2)")
    rs = rows(c)
    assert [r["boss"] for r in rs] == ["Hydross the Unstable", "The Lurker Below"] and rs[0]["value"] == 1200
    c.eval("ns.MyLogUI:SelectInstance(550)")
    rs = rows(c)
    assert [r["boss"] for r in rs] == ["Al'ar"] and rs[0].get("change") is None
    assert c.eval("return %s.hero.change:IsShown()" % p) is False      # no night before to compare with


@case
def a_new_pull_shows_up_while_open():
    w, c = client(seed=False)
    open_page(w, c)
    w.enter_instance("Serpentshrine Cavern", 548, "raid", 25, difficulty_id=4)
    w.tick(1)
    c.fire("ENCOUNTER_START", 623, "Hydross the Unstable", 4, 25)
    w.tick(5)
    c.fire("ENCOUNTER_END", 623, "Hydross the Unstable", 4, 25, 1)
    w.tick(0.5)
    assert [r["boss"] for r in rows(c)] == ["Hydross the Unstable"]
    assert c.eval("return ns.MainFrame:GetPanel('mylog').body:IsShown()") is True


def demo_client():
    w, c = client(enabled=False, seed=False)
    c.eval("ns.Demo:SetEnabled(true)")
    w.tick(0.5)
    open_page(w, c)
    return w, c


P = "ns.MainFrame:GetPanel('mylog')"


@case
def demo_mode_shows_demo_pulls_and_leaves_my_log_alone():
    w, c = demo_client()
    assert c.eval("return %s.body:IsShown()" % P) is True
    assert c.eval("return %s.demoTag:IsShown()" % P) is True
    names = c.eval_py("local o = {}; for _, e in ipairs(ns.MyLog:GetInstances()) do o[#o + 1] = e.name end; return o")
    assert names == ["Serpentshrine Cavern", "Tempest Keep"], names
    names = [r["boss"] for r in rows(c)]
    assert names[0] == "Hydross the Unstable" and names[-1] == "Lady Vashj" and len(names) == 6, names
    assert all(r["value"] for r in rows(c)[:5])
    # the stored log is untouched, and the demo goes away with demo mode
    assert c.eval("local n = 0; for _, ch in pairs(DisasterZoneLogDB.chars) do n = n + #ch.pulls end; return n") == 0
    c.eval("ns.Demo:SetEnabled(false)")
    w.tick(0.5)
    assert c.eval("return %s.empty:IsShown()" % P) is True


@case
def demo_runs_improve_week_by_week():
    w, c = demo_client()
    vals = c.eval_py("""local out = {}
      for i, run in ipairs(ns.MyLog:GetRuns(548)) do out[i] = ns.MyLog:RunNumbers(run, 'damage').value end
      return out""")
    assert len(vals) == 7 and vals[0] > vals[-1], vals
    assert c.eval_py("return ns.MyLog:RunNumbers(ns.MyLog:GetRuns(548)[1], 'damage').avoidable") > 0


@case
def boss_detail_compares_two_kills():
    w, c = demo_client()
    c.eval("ns.MyLogDetail:ShowBoss(ns.MyLogUI:GetBossRows()[3])")        # Leotheras
    assert c.eval("return ns.MyLogUI:GetState().mode") == "boss"
    pull = c.eval_py("local p, q = ns.MyLogDetail:GetCurrent(); return { p.boss, p.kill, q and q.kill, q and q.at < p.at, p.spec == q.spec }")
    assert pull == ["Leotheras the Blind", True, True, True, True], pull
    assert c.eval("return %s.runsView:IsShown()" % P) is False
    rows_ = c.eval_py("""local out = {}
      local p = ns.MyLogDetail:GetCurrent()
      local t = 0
      for _, r in ipairs(ns.MyLogDetail:AbilityRows(p, 'damage')) do t = t + r.share; out[#out + 1] = r.name end
      return { names = out, total = t }""")
    assert rows_["names"][0] == "Shadow Bolt" and "Firebolt (Imp)" in rows_["names"], rows_
    assert abs(rows_["total"] - 1) < 1e-6
    # tanking lists what hit me, the avoidable whirlwind marked
    tk = c.eval_py("""local p = ns.MyLogDetail:GetCurrent(); local out = {}
      for _, r in ipairs(ns.MyLogDetail:AbilityRows(p, 'tanking')) do out[r.name] = r.avoidable and true or false end
      return out""")
    assert tk == {"Whirlwind": True, "Chaos Blast": False}, tk
    # the chart: two series drawn, the whirlwinds as bands, idle gaps as ticks
    used = c.eval_py("local b = ns.MyLogDetail:GetViews(); local u = b.chart.used; return { u.line or 0, u.band or 0, u.tick or 0, u.fill or 0 }")
    assert used[0] > 100 and used[1] == 3 and used[2] >= 3 and used[3] > 50, used
    cells = c.eval_py("local b = ns.MyLogDetail:GetViews(); local o = {}; for _, x in ipairs(b.stats.cells) do o[#o + 1] = x.lab:GetText() end; return o")
    assert cells[0] == "DPS" and cells[1] == "Active time" and cells[2].startswith("Idle gaps") and cells[3] == "Back after Whirlwind", cells
    crumb = c.eval_py("local o = {}; for _, b in ipairs(%s.crumb.parts) do if b:IsShown() then o[#o + 1] = b.fs:GetText() end end; return o" % P)
    assert crumb == ["My Log", "Serpentshrine Cavern", "Leotheras the Blind"], crumb
    c.eval("ns.MyLogUI:SetView('tanking')")
    assert c.eval("return ns.MyLogUI:GetState().mode") == "boss"
    # back
    c.eval("ns.MyLogUI:SetMode('runs')")
    assert c.eval("return %s.runsView:IsShown()" % P) is True


@case
def a_wipe_only_boss_opens_its_best_pull():
    w, c = demo_client()
    c.eval("ns.MyLogDetail:ShowBoss(ns.MyLogUI:GetBossRows()[6])")        # Lady Vashj, wipes only
    pct = c.eval_py("local p, q = ns.MyLogDetail:GetCurrent(); return { p.kill, p.pct, q ~= nil }")
    assert pct == [False, 17.9, True], pct


@case
def deaths_grouped_by_cause_with_recaps():
    w, c = demo_client()
    c.eval("ns.MyLogUI:SetMode('deaths')")
    groups = c.eval_py("""local out = {}
      for _, g in ipairs(ns.MyLogDetail:DeathGroups(548)) do out[#out + 1] = { g.name, g.count } end
      return out""")
    # the demo dies to many things (so the list has to scroll): most deaths first
    assert len(groups) == 19 and sum(n for _, n in groups) == 34, groups
    assert groups[0] == ["Whirlwind", 4] and groups[1] == ["Toxic Spores", 3], groups
    assert all(groups[i][1] >= groups[i + 1][1] for i in range(len(groups) - 1)), groups
    # the rail: All deaths first (picked), then one row per cause
    rail = c.eval_py("""local _, d = ns.MyLogDetail:GetViews(); local o = {}
      for _, r in ipairs(d.causes.data) do o[#o + 1] = { r.all and 'all' or r.group.name, r.count } end
      return o""")
    assert rail[0] == ["all", 34] and len(rail) == 20 and rail[1] == ["Whirlwind", 4], rail
    # newest death first: tonight's last Vashj wipe
    sel = c.eval_py("local e = ns.MyLogDetail:GetSelectedDeath(); return { e.pull.boss, e.death.by }")
    assert sel == ["Lady Vashj", "38280"], sel
    c.eval("ns.MyLogDetail:StepDeath(1)")
    c.eval("ns.MyLogDetail:StepDeath(1)")
    sel = c.eval_py("local e = ns.MyLogDetail:GetSelectedDeath(); return { e.pull.boss, #e.death.ring, e.death.by }")
    assert sel == ["Lady Vashj", 9, "38575"], sel
    # the health line: one fill series + a coloured segment per step, dots for hits and heals, ticks for casts
    used = c.eval_py("local _, d = ns.MyLogDetail:GetViews(); local u = d.chart.used; return { u.line or 0, u.dot or 0, u.tick or 0 }")
    assert used == [6, 12, 3], used       # 6 segments; a dark ring + a dot per hit or heal
    # every demo death ends at 0 and no hit before the last one kills
    ok = c.eval_py("""local bad = {}
      for _, p in ipairs(ns.MyLog:GetPulls()) do for _, d in ipairs(p.deaths or {}) do
        for i, e in ipairs(d.ring) do
          if i < #d.ring and e[5] <= 0 then bad[#bad + 1] = d.by end
        end
      end end
      return bad""")
    assert ok == [], ok
    # pick a cause: only its deaths, then All again
    c.eval("ns.MyLogDetail:PickCause('37640')")
    sel = c.eval_py("local e = ns.MyLogDetail:GetSelectedDeath(); local _, d = ns.MyLogDetail:GetViews(); return { e.pull.boss, d.pos:GetText() }")
    assert sel == ["Leotheras the Blind", "1 of 4"], sel
    c.eval("ns.MyLogDetail:PickCause(nil)")
    assert c.eval("local _, d = ns.MyLogDetail:GetViews(); return d.pos:GetText()") == "1 of 34"


@case
def recorder_counts_avoidable_damage():
    w, c = client(seed=False)
    w.enter_instance("Serpentshrine Cavern", 548, "raid", 25, difficulty_id=4)
    w.tick(1)
    me = c.eval("return UnitGUID('player')")
    c.fire("ENCOUNTER_START", 628, "Lady Vashj", 4, 25)
    for spell, amount in ((38575, 3000), (38253, 1200)):
        c.combat_log(0, "SPELL_DAMAGE", False, "Creature-0-1-2-3-21212-1", "Lady Vashj", 0xA48, 0, me, "Lux", 0x511, 0,
                     spell, "x", 8, amount, -1, 8, None, None, None, False, False, False, False)
    w.tick(3)
    c.fire("ENCOUNTER_END", 628, "Lady Vashj", 4, 25, 0)
    s = c.eval_py("local p = ns.MyLog:GetPulls(); return p[#p].s")
    assert s["av"] == 3000 and s["t"] == 4200, s


@case
def timeline_lays_out_my_casts_and_the_boss():
    w, c = demo_client()
    c.eval("ns.MyLogDetail:ShowBoss(ns.MyLogUI:GetBossRows()[3])")        # Leotheras
    # the chart shows the boss's whirlwinds (auras with their length) and its yells
    used = c.eval_py("local b = ns.MyLogDetail:GetViews(); local u = b.chart.used; return { u.band or 0, u.mark or 0 }")
    assert used == [3, 3], used
    # switch to the timeline
    c.click(c.eval("local b = ns.MyLogDetail:GetViews(); return b.modeSeg.buttons[2]"))
    info = c.eval_py("""local b = ns.MyLogDetail:GetViews(); local t = b.timeline
      local names = {}; for i, l in ipairs(t.lanes) do names[i] = l.name end
      return { shown = t:IsShown(), list = b.list.frame:IsShown(), lanes = names, bars = t.used.bar or 0,
               dots = t.used.dot or 0, gaps = t.used.barBORDER or 0 }""")
    assert info["shown"] is True and info["list"] is False, info
    assert info["lanes"][0] == "Shadow Bolt" and "Immolate" in info["lanes"] and "Corruption" in info["lanes"], info
    assert info["bars"] > 100 and info["dots"] >= 3 and info["gaps"] >= 3, info
    # zoom in around the middle, then back out
    z = c.eval_py("local t = select(1, ns.MyLogDetail:GetViews()).timeline; t:Zoom(0.5, 0.5); return { t.z0, t.z1 }")
    assert abs(z[0] - 0.25) < 1e-6 and abs(z[1] - 0.75) < 1e-6, z
    text = c.eval("local t = select(1, ns.MyLogDetail:GetViews()).timeline; return ns.MyLogTimeline:BossEventText(t.pull, t.pull.bev[1])")
    assert text, text
    # the choice stays for the next boss
    c.eval("ns.MyLogDetail:ShowBoss(ns.MyLogUI:GetBossRows()[1])")
    assert c.eval("return select(1, ns.MyLogDetail:GetViews()).timeline:IsShown()") is True


if __name__ == "__main__":
    run_all()

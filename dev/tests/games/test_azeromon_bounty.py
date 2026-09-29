"""Azeromon: the bounty board.

Covers: days and weeks following WoW's resets (daily reset hour, weekly on Wednesday in Europe / Tuesday elsewhere);
the whole guild getting the same three bounties each day; progress from the event feed, paying out once with a
toast (and only for real taming); a new day bringing new bounties while the week keeps its count; the weekly guild
goal adding up guildmates' summaries and paying each tier once to everyone who helped (not to someone who didn't);
the board by the inn and BOUNTIES in the start menu; Illusion Dust.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_bounty.py [-k name]
"""
import datetime
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors, World, Client  # noqa: E402
from _azero_bot import BOT  # noqa: E402


def ts(mo, d, h, mi=0):
    return int(datetime.datetime(2026, mo, d, h, mi, tzinfo=datetime.timezone.utc).timestamp())


# Tuesday 29 September 2026, 12:00 UTC; the EU daily reset is at 03:00 UTC
NOW = ts(9, 29, 12)


def at(c, t, reset_hour=3, region=3):
    left = ((reset_hour * 3600) - t % 86400) % 86400 or 86400
    c.eval("local B = ns.AzeroBounty B.clock = %d B.resetIn = %d B.region = %d" % (t, left, region))


def game(seed=7, ui=False, c_w=None, t=NOW):
    w, c = c_w or solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    at(c, t)
    c.eval("ns.Azero:NewGame()")
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('owlet', 3, ns.Azero.rng), 'caught')")
    if ui:
        c.slash("/cdl play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.3)
        c.eval("T_AZ.settle()")
    return w, c


def keys(c):
    return c.eval_py("local B = ns.AzeroBounty local wk = B.WeekKey() return { day = B.DayKey(), week = wk }")


def earned(c):
    return sorted(c.eval_py("local t = {} for id in pairs(ns.AzeroAch.Earned()) do t[#t + 1] = id end return t") or [])


@case
def days_and_weeks_follow_the_wow_resets():
    w, c = game()
    at(c, ts(9, 29, 2, 59))
    before_daily = keys(c)
    at(c, ts(9, 29, 3, 1))
    after_daily = keys(c)
    assert after_daily["day"] == before_daily["day"] + 24, (before_daily, after_daily)
    assert after_daily["week"] == before_daily["week"], (before_daily, after_daily)      # Tuesday: not the EU reset
    at(c, ts(9, 30, 2, 59))
    wed_before = keys(c)
    at(c, ts(9, 30, 3, 1))
    wed_after = keys(c)
    assert wed_before["week"] == after_daily["week"] and wed_after["week"] == wed_before["week"] + 1, (wed_before, wed_after)
    # the next week begins exactly 7 days later
    at(c, ts(10, 7, 3, 1))
    assert keys(c)["week"] == wed_after["week"] + 1
    at(c, ts(10, 7, 2, 59))
    assert keys(c)["week"] == wed_after["week"]
    # the Americas reset on Tuesday (15:00 UTC here)
    at(c, ts(9, 29, 14, 59), reset_hour=15, region=1)
    us_before = keys(c)
    at(c, ts(9, 29, 15, 1), reset_hour=15, region=1)
    assert keys(c)["week"] == us_before["week"] + 1
    # time left in the week
    at(c, ts(9, 30, 3, 1))
    left = c.eval("local _, left = ns.AzeroBounty.WeekKey() return left")
    assert abs(left - 7 * 86400 + 60) <= 1, left
    no_errors(w)


@case
def the_whole_guild_gets_the_same_bounties():
    w = World()
    cs = {n: Client(w, n, guild_rank=3) for n in ("Alice", "Bob")}
    for c in cs.values():
        c.load_addon()
    w.tick(3)
    lists = {}
    for i, (name, c) in enumerate(cs.items()):
        game(seed=3 + i * 11, c_w=(w, c))
        lists[name] = c.eval_py("""local out = {}
          for _, b in ipairs(ns.AzeroBounty:State().list) do out[#out + 1] = b.id .. ":" .. tostring(b.arg) .. ":" .. b.n end
          return out""")
    assert lists["Alice"] == lists["Bob"] and len(lists["Alice"]) == 3, lists
    ids = [x.split(":")[0] for x in lists["Alice"]]
    assert len(set(ids)) == 3, ids                                  # three different kinds
    days = set()
    c = cs["Alice"]
    for d in range(6):
        at(c, NOW + d * 86400)
        days.add(tuple(c.eval_py("local o = {} for _, b in ipairs(ns.AzeroBounty:State().list) do o[#o + 1] = b.id .. tostring(b.arg) .. b.n end return o")))
    assert len(days) >= 4, days
    no_errors(w)


@case
def a_bounty_counts_pays_once_and_toasts():
    w, c = game()
    c.eval("""local st = ns.AzeroBounty:State()
      st.list = {
        { id = 'tame', n = 2, got = 0, money = 300, item = 'potion', count = 2 },
        { id = 'steps', n = 3, got = 0, money = 200, item = 'net', count = 2 },
        { id = 'tametype', arg = 'AIR', n = 1, got = 0, money = 250, item = 'greatnet', count = 1 },
      }
      ns.Azero.save.money = 1000
      ns.Azero.save.bag = {}""")
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('wolfpup', 3, ns.Azero.rng), 'gift')")      # a gift is not a tame
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('wolfpup', 3, ns.Azero.rng), 'caught')")
    r = c.eval_py("local st = ns.AzeroBounty:State() return { got = st.list[1].got, money = ns.Azero.save.money }")
    assert r == {"got": 1, "money": 1000}, r
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('owlet', 3, ns.Azero.rng), 'caught')")        # 2nd tame + the Air one
    c.eval("ns.Azero:AddMon(ns.AzeroMon.New('owlet', 3, ns.Azero.rng), 'caught')")        # no more pay
    r = c.eval_py("""local st = ns.AzeroBounty:State()
      return { d1 = st.list[1].done == true, d3 = st.list[3].done == true, money = ns.Azero.save.money,
               potion = ns.Azero.save.bag.potion, greatnet = ns.Azero.save.bag.greatnet }""")
    assert r == {"d1": True, "d3": True, "money": 1550, "potion": 2, "greatnet": 1}, r
    toast = c.eval_py("local f = ns.AzeroAch:ToastFrame() return { shown = f:IsShown(), label = f.unlocked:GetText() }")
    assert toast["shown"] and toast["label"] in ("Bounty Complete", "Azeromon Achievement"), toast
    c.eval("for i = 1, 3 do ns.Azero:Emit('step') end")
    r = c.eval_py("local st = ns.AzeroBounty:State() return { d = st.list[2].done == true, net = ns.Azero.save.bag.net }")
    assert r == {"d": True, "net": 2}, r
    assert "bounty1" in earned(c)
    assert c.eval("return ns.AzeroAch.Stat('bounties')") == 3
    no_errors(w)


@case
def a_new_day_brings_new_bounties_and_the_week_keeps_its_count():
    w, c = game()
    c.eval("local st = ns.AzeroBounty:State() st.list[1].got = 1 st.wn = 5 st.tiers = { true }")
    at(c, NOW + 86400)                                           # Wednesday 12:00: after the EU weekly reset
    r = c.eval_py("local st = ns.AzeroBounty:State() return { got = st.list[1].got, wn = st.wn, t = st.tiers[1] or false }")
    assert r == {"got": 0, "wn": 0, "t": False}, r
    c.eval("local st = ns.AzeroBounty:State() st.wn = 7")
    at(c, NOW + 2 * 86400)                                       # Thursday: same week
    r = c.eval_py("local st = ns.AzeroBounty:State() return { got = st.list[1].got, wn = st.wn }")
    assert r == {"got": 0, "wn": 7}, r
    no_errors(w)


CONTRIBUTE = """local B, G = ns.AzeroBounty, ns.Azero
  local goal = B.Goal(B:State().week)
  for i = 1, %d do
    if goal.id == 'tame' then G:AddMon(ns.AzeroMon.New('wolfpup', 3, G.rng), 'caught')
    elseif goal.id == 'wild' then G:Emit('battle', { wild = true, result = 'win', foes = { 'wolfpup' } })
    elseif goal.id == 'step' or goal.id == 'steps' then G:Emit('step')
    else G:Emit('level', { mon = G.save.party[1], lvl = 5 }) end
  end
  return goal.tiers"""


@case
def the_guild_goal_adds_up_and_pays_each_tier_once_to_helpers():
    w = World()
    cs = {n: Client(w, n, guild_rank=3) for n in ("Alice", "Bob", "Carol")}
    for c in cs.values():
        c.load_addon()
    w.tick(3)
    for i, c in enumerate(cs.values()):
        game(seed=5 + i, c_w=(w, c))
        c.eval("ns.Azero.save.money = 0 ns.Azero.save.bag = {} ns.AzeroGuild._Reset() ns.AzeroNet:SetActive(true)")
        c.eval("local st = ns.AzeroBounty:State() st.list = {} st.wn = 0")   # only the guild goal pays here; setup tamed
    a, b, carol = cs["Alice"], cs["Bob"], cs["Carol"]
    tiers = a.eval_py(CONTRIBUTE % 0)
    a.eval("ns.AzeroBounty:State().wn = %d" % (tiers[0] - 1))
    for c in (a, b, carol):
        c.eval("ns.AzeroGuild:Update()")
    w.tick(3)
    # Bob's one contribution completes Bronze: he is paid; Alice is paid when his summary reaches her
    b.eval_py(CONTRIBUTE % 1)
    r = b.eval_py("local st = ns.AzeroBounty:State() return { t = st.tiers[1] or false, money = ns.Azero.save.money, sp = ns.Azero.save.bag.superpotion }")
    assert r == {"t": True, "money": 500, "sp": 2}, r
    b.eval("ns.AzeroGuild._Reset() ns.AzeroGuild:Update()")
    w.tick(3)
    r = a.eval_py("local st = ns.AzeroBounty:State() return { t = st.tiers[1] or false, money = ns.Azero.save.money }")
    assert r == {"t": True, "money": 500}, r
    # paid once only
    b.eval_py(CONTRIBUTE % 1)
    assert b.eval("return ns.Azero.save.money") == 500
    # Carol never helped: nothing for her
    carol.eval("ns.AzeroBounty:CheckTiers()")
    assert carol.eval("return ns.Azero.save.money") == 0
    total = carol.eval_py("local mine, total, people = ns.AzeroBounty:Weekly() return { total = total, people = people }")
    assert total == {"total": tiers[0], "people": 2}, total          # Bob's last summary predates his 2nd
    no_errors(w)


@case
def the_boards_in_every_town_and_the_start_menu_show_the_bounties():
    w, c = game(ui=True)
    c.eval("ns.Azero:EnterMap('town', 10, 15, 'left', true)")
    w.tick(0.2)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.2)
    lv = c.eval_py("return ns.AzeroUI._Levels()")
    assert lv and lv[-1]["title"] == "BOUNTY BOARD", lv
    L = c.eval_py("return ns.AzeroUI._MenuLayout()")
    assert L["n"] == 5 and -L["y"] + L["h"] <= L["SH"] - L["desc"], L
    desc = c.eval("return ns.AzeroUI._DescText()")
    assert desc.startswith("Reward: ") and "New bounties in " in desc, desc
    for _ in range(3):
        c.eval("ns.AzeroUI._HandleKey('down')")
    desc = c.eval("return ns.AzeroUI._DescText()")
    assert "Bronze" in desc and "Each tier pays everyone who helped." in desc, desc
    c.eval("ns.AzeroUI._HandleKey('B')")
    w.tick(0.2)
    assert c.eval("return ns.Azero.pending == nil") and c.eval("return ns.AzeroUI._State().stack") == 0
    # the same board, the same bounties, in Sentinel Hill
    goldshire = c.eval_py("local o = {} for _, b in ipairs(ns.AzeroBounty:State().list) do o[#o + 1] = ns.AzeroBounty.Text(b) end return o")
    c.eval("ns.Azero:EnterMap('sentinel', 7, 9, 'up', true)")
    w.tick(0.2)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.2)
    assert c.eval_py("return ns.AzeroUI._Levels()")[-1]["title"] == "BOUNTY BOARD"
    shown = c.eval_py("local o = {} for i, it in ipairs(ns.AzeroUI._MenuItems()) do o[i] = it end return o")
    assert shown[:3] == goldshire, (shown, goldshire)
    c.eval("ns.AzeroUI._HandleKey('B')")
    w.tick(0.2)
    # BOUNTIES in the start menu
    for k in ("START", "down", "down", "down", "down", "down", "A"):
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.05)
    assert c.eval_py("return ns.AzeroUI._Levels()")[-1]["title"] == "BOUNTY BOARD"
    no_errors(w)


@case
def illusion_dust_doubles_the_shiny_chance_for_half_an_hour():
    w, c = game(ui=True)
    c.eval("ns.Azero.save.bag.illusiondust = 1")
    # from the bag in the start menu
    for k in ("START", "down", "down", "A"):
        c.eval("ns.AzeroUI._HandleKey('%s')" % k)
        w.tick(0.05)
    items = c.eval_py("return ns.AzeroUI._MenuLayout().n")
    for _ in range(items - 1):
        c.eval("ns.AzeroUI._HandleKey('down')")
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.1)
    r = c.eval_py("""local G = ns.Azero
      local odds
      G.shinyRng = function(a, b) odds = b return 2 end
      G:RollShiny()
      return { boosted = G:ShinyBoosted(), left = G:ShinyBoostLeft(), dust = G.save.bag.illusiondust or 0, odds = odds }""")
    assert r == {"boosted": True, "left": 1800, "dust": 0, "odds": 200}, r
    at(c, NOW + 1801)
    assert c.eval("return ns.Azero:ShinyBoosted()") is False
    no_errors(w)


if __name__ == "__main__":
    run_all()

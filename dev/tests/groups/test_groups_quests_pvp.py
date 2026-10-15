"""Groups, steps 4-6: quest groups, PvP groups, Other, planned raids on the board, the clash warning.

Covers: the group quests in my log reach the guild (who has which quest); quests of two zones can't be one group, and
a quest another guildie already lists can't be listed again; the Quest sheet lists my log, ticks quests into one
group and lists it; a quest group pings a guildie with the quest in their log even when they aren't up for quests;
my quest group ends once its quests are turned in. PvP: rated needs my team of that bracket; a guildie on another
team of it can't join; who joins gets a team invite when accepted; a rated group doesn't ping below its rating; the
PvP sheet lists a rated arena group. Other: "Anything else" needs a note. A planned raid with Fill open places shows
on the board and asking signs up for it. Joining a group that clashes with a raid I signed up for asks first.

Run: luaenv\\Scripts\\python.exe tests\\groups\\test_groups_quests_pvp.py [-k name]   (from dev)
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import World, Client, case, run_all  # noqa: E402

HELLO = 50
DURN, GUROK, RING, TEROKK = 9937, 9853, 9977, 11073   # (Nagrand x3, Terokkar)


def guild(names, tick=HELLO):
    w = World()
    c = {}
    for i, (name, cls) in enumerate(names):
        c[name] = Client(w, name, class_file=cls, guild_rank=0 if i == 0 else 3)
    for x in c.values():
        x.load_addon()
    w.tick(tick)
    return w, c


def K(cl):
    return cl.full_name


def roles(cl, *on):
    for r in ("tank", "healer", "dps"):
        cl.eval("ns.DungeonRuns:SetMyRole(...)", r, r in on)


def list_group(cl, **opts):
    return cl.eval_py("""
      local o = ...
      local t = {}
      for k, v in pairs(o) do t[k] = v end
      local r, why = ns.DungeonRuns:List(t)
      return r and r.id or why""", opts)


def strip_codes(s):
    s = re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", s or "")
    return re.sub(r"\|T[^|]*\|t", "", s)


def quests_on(cl, *ids):
    cl.eval("for _, id in ipairs({ ... }) do __MOCK.quests_on[id] = true end; ns.GroupQuests:Scan()", *ids)


# ------------------------------------------------------------------------------------------------------------------
@case
def my_group_quests_reach_the_guild_and_the_rules_hold():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "WARRIOR"), ("Cara", "MAGE")])
    g, b, cara = c["Gina"], c["Bert"], c["Cara"]
    assert g.eval_py("return ns.GroupQuests:Count()") > 100
    quests_on(b, DURN, RING)
    w.tick(5)
    assert g.eval_py("return ns.DungeonRuns:GetQuestHolders(...)", DURN) == [K(b)]
    assert g.eval_py("return ns.DungeonRuns:GetGuildQuests()[...]", RING) == 1
    # quests of two zones are two groups
    assert list_group(g, k="quest", a=[DURN, TEROKK], role="healer") == "Quests of one zone make one group."
    rid = list_group(g, k="quest", a=[DURN, GUROK], role="healer")
    assert ":" in rid, rid
    w.tick(3)
    x = cara.eval_py("local r = ns.DungeonRuns:GetGroup(...); return { a = r.a, n = ns.DungeonRuns:GetSize(r) }", rid)
    assert x == {"a": [DURN, GUROK], "n": 5}, x
    # the same quest can't get a second group: join that one
    why = list_group(cara, k="quest", a=[GUROK], role="dps")
    assert why == "Gina already has a group for Gurok the Usurper: join it.", why
    w.assert_no_errors()


@case
def the_quest_sheet_lists_my_log_and_makes_one_group():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "WARRIOR")])
    g, b = c["Gina"], c["Bert"]
    quests_on(g, DURN, GUROK, TEROKK)
    w.tick(2)
    g.eval("ns.MainFrame:Open('dungeons')")
    w.tick(1)
    g.eval("ns.DungeonsUI:SetTab('quest')")
    g.eval("ns.DungeonsUI:OpenSheet()")
    sh = "local sh = ns.DungeonsUI:GetPanel().sheet; "
    assert g.eval_py("return ns.DungeonsUI:GetSheetState().kind") == "quest"
    rows = g.eval_py(sh + "local out = {}; for _, r in ipairs(sh.quest.rows) do "
                          "if r:IsShown() then out[#out + 1] = r.name:GetText() end end; return out")
    assert sorted(rows) == sorted(["Wanted: Durn the Hungerer", "Gurok the Usurper", "Terokk's Downfall"]), rows
    # tick Durn and Gurok (Nagrand), then Terokk (Terokkar): another zone starts over
    def tick_quest(name):
        g.eval(sh + "for _, r in ipairs(sh.quest.rows) do if r:IsShown() and r.name:GetText() == ... then "
                    "r:GetScript('OnClick')(r) end end", name)
    tick_quest("Wanted: Durn the Hungerer")
    tick_quest("Gurok the Usurper")
    assert g.eval_py("return ns.DungeonsUI:GetSheetState().qs") == [DURN, GUROK]
    assert strip_codes(g.eval_py(sh + "return sh.pickedPill.fs:GetText()")) == "2 quests, one group"
    tick_quest("Terokk's Downfall")
    assert g.eval_py("return ns.DungeonsUI:GetSheetState().qs") == [TEROKK]
    tick_quest("Terokk's Downfall")
    tick_quest("Wanted: Durn the Hungerer")
    tick_quest("Gurok the Usurper")
    g.eval(sh + "sh.go:Click()")
    w.tick(3)
    x = b.eval_py("local r = ns.DungeonRuns:GetGroups('quest')[1]; return r and r.a")
    assert x == [DURN, GUROK], x
    w.assert_no_errors()


@case
def a_quest_group_pings_who_has_the_quest_and_ends_when_turned_in():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "WARRIOR")])
    g, b = c["Gina"], c["Bert"]
    roles(b, "tank")
    b.eval("ns.DungeonRuns:SetUp(true)")
    assert "quest" not in b.eval_py("return ns.DungeonRuns:GetMyKinds()")
    quests_on(b, RING)
    quests_on(g, RING)
    w.tick(3)
    rid = list_group(g, k="quest", a=[RING], role="healer")
    w.tick(3)
    t = b.eval_py("local t = ns.DungeonsUI:GetToast(); return t and t:IsShown() and t.run")
    assert t == rid, t
    # Gina turns it in: her quest group comes off the board
    g.eval("__MOCK.quests_on[...] = nil; ns.GroupQuests:Scan()", RING)
    w.tick(3)
    assert b.eval_py("return ns.DungeonRuns:GetGroup(...) ~= nil", rid) is False
    w.assert_no_errors()


@case
def rated_arena_groups_are_a_teams():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "WARRIOR"), ("Cara", "MAGE"), ("Dora", "DRUID")])
    g, b, cara, d = c["Gina"], c["Bert"], c["Cara"], c["Dora"]
    g.eval("__MOCK.arena[1] = { name = 'Disastrous Decisions', size = 3, rating = 1712, personal = 1700, "
           "members = { 'Gina' } }")
    cara.eval("__MOCK.arena[1] = { name = 'Other Team', size = 3, rating = 1500, personal = 1500, members = { 'Cara' } }")
    d.eval("__MOCK.arena[1] = { name = 'Low Team', size = 3, rating = 1300, personal = 1300, members = { 'Dora' } }")
    w.tick(3)
    roles(b, "dps")
    roles(cara, "dps")
    roles(d, "dps")
    d.eval("ns.DungeonRuns:SetMyKind('pvp', true); ns.DungeonRuns:SetUp(true)")
    w.tick(3)
    rid = list_group(g, k="pvp", a=["arena3"], role="healer", pr=True, mr=1600)
    w.tick(3)
    # Cara is on another 3v3 team: she can't join
    why = cara.eval_py("return (ns.DungeonRuns:GetGroupBlocker(ns.DungeonRuns:GetGroup(...)))", rid)
    assert why == "You're on another 3v3 team", why
    # Dora's rating is under 1600: no ping
    assert d.eval_py("local t = ns.DungeonsUI:GetToast(); return t and t:IsShown() and t.run") in (None, False)
    # Bert (no team) joins; accepting him sends a team invite first
    assert b.eval_py("return ns.DungeonRuns:Join(...)", rid) is True
    w.tick(2)
    assert g.eval_py("return ns.DungeonRuns:Accept(...)", rid, K(b)) is True
    inv = g.eval_py("return __MOCK.team_invites[1]")
    assert inv and inv[0] == 1 and inv[1].startswith("Bert"), inv
    w.assert_no_errors()


@case
def the_pvp_sheet_lists_a_rated_arena_group():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "WARRIOR")])
    g, b = c["Gina"], c["Bert"]
    g.eval("ns.MainFrame:Open('dungeons')")
    w.tick(1)
    g.eval("ns.DungeonsUI:SetTab('pvp')")
    g.eval("ns.DungeonsUI:OpenSheet()")
    sh = "local sh = ns.DungeonsUI:GetPanel().sheet; "
    s = g.eval_py("local s = ns.DungeonsUI:GetSheetState(); return { s.kind, s.pm, s.pa }")
    assert s == ["pvp", "arena", "arena3"], s
    # rated without a team: List group is off and the strip says why
    g.eval(sh + "sh.games:Select('rated', true)")
    assert g.eval_py(sh + "return sh.go:IsEnabled()") is False
    assert "You have no 3v3 team" in strip_codes(g.eval_py(sh + "return sh.team.title:GetText()"))
    g.eval("__MOCK.arena[1] = { name = 'Disastrous Decisions', size = 3, rating = 1712, personal = 1700, "
           "members = { 'Gina' } }; ns.DungeonsUI:RefreshSheet()")
    assert g.eval_py(sh + "return sh.go:IsEnabled()") is True
    assert g.eval_py(sh + "return sh.steppers.tank:IsShown()") is False   # (no tanks in PvP)
    g.eval(sh + "sh.go:Click()")
    w.tick(3)
    x = b.eval_py("local r = ns.DungeonRuns:GetGroups('pvp')[1]; return r and { r.a[1], r.pr, r.mr, r.tn }")
    assert x == ["arena3", True, 1600, "Disastrous Decisions"], x
    w.assert_no_errors()


@case
def anything_else_needs_a_note():
    w, c = guild([("Gina", "PALADIN")])
    g = c["Gina"]
    g.eval("ns.MainFrame:Open('dungeons')")
    w.tick(1)
    g.eval("ns.DungeonsUI:OpenSheet(); ns.DungeonsUI:SetSheet({ kind = 'other', oa = 'any' })")
    sh = "local sh = ns.DungeonsUI:GetPanel().sheet; "
    g.eval(sh + "sh.go:Click()")
    assert g.eval_py("return ns.DungeonsUI:GetSheetState().err") == "Say what the group is for in the note."
    g.eval(sh + "sh.note:SetText('Netherwing eggs')")
    g.eval(sh + "sh.go:Click()")
    w.tick(1)
    x = g.eval_py("local r = ns.DungeonRuns:GetMyGroup(); return r and { r.k, r.a[1], r.no }")
    assert x == ["other", "any", "Netherwing eggs"], x
    w.assert_no_errors()


# A planned raid as the planner would give it (stubbed: the planner's own suites cover how it gets there).
PLANNED = """
  local RP = ns.RaidPlan
  local leader = ...
  local t = GetServerTime() + 7200
  local v = { id = 'occ1', t = t, i = 'gruul', ix = {}, sz = 25, fo = true, cancelled = false, rl = leader,
              rev = 1, by = leader }
  __planned = { v = v, signups = {} }
  RP.GetRaids = function() return { v } end
  RP.GetRaidOpenSlots = function() return { teamName = 'Main', size = 25, openCount = 2,
      slots = { { role = 'healer' }, { role = 'melee' } } } end
  RP.GetSignups = function() return { [leader] = { st = 'A', c = 'PALADIN' } } end
  RP.GetRaidInstances = function() return { 'GruulsLair' } end
  RP.GetRaidLeader = function() return leader end
  RP.SignUp = function(self, occ, st) __planned.signed = { occ, st } return true end
  RP.GetMySignup = function(self, occ) return __planned.mine end
  RP.GetRaidName = function() return "Gruul's Lair" end
"""


@case
def a_planned_raid_fills_its_open_places_from_the_board():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "PRIEST")])
    g, b = c["Gina"], c["Bert"]
    b.eval(PLANNED, K(g))
    roles(b, "healer")
    run = b.eval_py("local r = ns.DungeonRuns:GetGroup('rp:occ1'); return r and { r.k, r.a[1], r.n, r.o, r.no }")
    assert run == ["raid", "GruulsLair", 25, K(g), "Main raid: 2 open places"], run
    assert any(x == "rp:occ1" for x in b.eval_py("local out = {}; for _, r in ipairs(ns.DungeonRuns:GetGroups('raid')) "
                                                  "do out[#out + 1] = r.id end; return out"))
    assert b.eval_py("return ns.DungeonRuns:Join('rp:occ1')") is True
    assert b.eval_py("return __planned.signed") == ["occ1", "A"]
    w.assert_no_errors()


@case
def joining_a_group_that_clashes_with_my_raid_asks_first():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "PRIEST")])
    g, b = c["Gina"], c["Bert"]
    roles(b, "healer")
    rid = list_group(g, k="quest", a=[RING], role="dps")
    w.tick(3)
    b.eval(PLANNED, K(g))
    b.eval("__planned.mine = { st = 'A' }; __planned.v.t = GetServerTime() + 1800")
    assert b.eval_py("return ns.DungeonRuns:GetOverlap(ns.DungeonRuns:GetGroup(...)) ~= nil", rid) is True
    b.eval("""__asked = nil
      ns.Popup.Confirm = function(self, o) __asked = o.text; __accept = o.onAccept end""")
    b.eval("ns.GroupsCard.TryJoin(ns.DungeonRuns:GetGroup(...))", rid)
    assert "Gruul's Lair" in (b.eval_py("return __asked") or ""), b.eval_py("return __asked")
    assert g.eval_py("return #ns.DungeonRuns:GetRequests(...)", rid) == 0
    b.eval("__accept()")
    w.tick(2)
    assert g.eval_py("return #ns.DungeonRuns:GetRequests(...)", rid) == 1
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())

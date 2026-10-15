"""Groups, step 3: raid groups (Core/DungeonRuns.lua, UI/DungeonsTab.lua, UI/GroupsCard.lua).

Covers: a BiS pick that drops in a raid flags the raid group (and only its picked bosses), and the guild learns I have
BiS there; the sheet lists a raid group (raid tiles by phase, a raid of another size starts the pick over, places, soft
reserves, picked bosses) and edits it again; a missing attunement is a hint on the opened card, never a block; the
leader's own raid card shows its roster, and its requests say who is on the blacklist and who brings a buff the group
lacks; members up for dungeons only aren't offered for a raid; the raid session starts as the group listed its loot,
from the menu or from the pop-up on arriving.

Run: luaenv\\Scripts\\python.exe tests\\groups\\test_groups_raids.py [-k name]   (from dev)
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import World, Client, case, run_all  # noqa: E402

HELLO = 50


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
    rid = cl.eval_py("""
      local o = ...
      local t = {}
      for k, v in pairs(o) do t[k] = v end
      local r, why = ns.DungeonRuns:List(t)
      return r and r.id or why""", opts)
    assert isinstance(rid, str) and ":" in rid, rid
    return rid


def strip_codes(s):
    s = re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", s or "")
    return re.sub(r"\|T[^|]*\|t", "", s)


def card_eval(cl, rid, body, *args):
    """Runs body with `c` = rid's card on cl's board (shown), returns its value."""
    return cl.eval_py("""
      local rid = ...
      for _, c in ipairs(ns.DungeonsUI:GetPanel().cards) do
        if c:IsShown() and c.runId == rid then
          """ + body + """
        end
      end""", rid, *args)


# A Karazhan item a priest wears, its boss, and another boss of Karazhan.
KARA_PICK = """
  local raid = ns.ItemDB:GetRaid('Karazhan')
  for bi, boss in ipairs(raid.bosses) do
    if not boss.isTrash then
      for _, id in ipairs(boss.items or {}) do
        for _, sid in ipairs(ns.ItemDB:GetSlotsForItem(id) or {}) do
          if ns.ItemDB:IsUsableBy(id, 'PRIEST', sid) and not ns.ItemDB:IsToken(id) then
            local srcs = ns.ItemDB:GetSources(id, 'raids') or {}
            if #srcs == 1 and ns.BiS:SetSlot(1, sid, 'main', id) then
              local other
              for _, b in ipairs(raid.bosses) do
                if b ~= boss and not b.isTrash then other = b.key break end
              end
              return { id = id, boss = 'Karazhan:' .. tostring(boss.key), other = 'Karazhan:' .. tostring(other) }
            end
          end
        end
      end
    end
  end"""


# ------------------------------------------------------------------------------------------------------------------
@case
def a_raid_bis_pick_flags_the_raid_group_and_its_picked_bosses():
    w, c = guild([("Gina", "PALADIN"), ("Pia", "PRIEST")])
    g, p = c["Gina"], c["Pia"]
    pick = p.eval_py(KARA_PICK)
    assert pick, "no Karazhan pick for a priest"
    w.tick(3)   # (the needs follow the pick after their debounce, and the profile goes out)
    full = list_group(g, k="raid", a=["Karazhan"], role="tank")
    w.tick(3)
    drops = p.eval_py("return ns.DungeonRuns:GetGroupBiSDrops(ns.DungeonRuns:GetGroup(...))", full)
    assert drops == [pick["id"]], (drops, pick)
    # picked bosses: only theirs count
    probe = "return #ns.DungeonRuns:GetGroupBiSDrops({ k = 'raid', a = { 'Karazhan' }, bo = { ... } })"
    assert p.eval_py(probe, pick["boss"]) == 1
    assert p.eval_py(probe, pick["other"]) == 0
    # the card's line says so, and the guild learns Pia has BiS in Karazhan (her profile)
    p.eval("ns.MainFrame:Open('dungeons')")
    w.tick(1)
    hint = p.eval_py("local t = ns.GroupsCard.HintFor(ns.DungeonRuns:GetGroup(...)); return t", full)
    assert "Drops your BiS" in strip_codes(hint), hint
    w.tick(5)
    assert g.eval_py("return ns.DungeonRuns:HasRaidBiS(...)", K(p), "Karazhan") is True
    assert g.eval_py("return ns.DungeonRuns:HasRaidBiS(...)", K(p), "GruulsLair") is False
    w.assert_no_errors()


@case
def the_sheet_lists_a_raid_group_and_edits_it():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "WARRIOR")])
    g, b = c["Gina"], c["Bert"]
    g.eval("ns.MainFrame:Open('dungeons')")
    w.tick(1)
    g.eval("ns.DungeonsUI:SetTab('raid')")
    g.eval("ns.DungeonsUI:OpenSheet()")
    s = g.eval_py("local s = ns.DungeonsUI:GetSheetState(); return { kind = s.kind, n = #s.ra }")
    assert s == {"kind": "raid", "n": 0}, s
    sh = "local sh = ns.DungeonsUI:GetPanel().sheet; "
    assert g.eval_py(sh + "return { sh.go:IsEnabled(), sh.mode:IsShown(), sh.title:GetText() }") == \
        [False, False, "List a group"]
    # the raids as tiles (Karazhan, Gruul, Magtheridon first); the kind tabs on the head
    names = g.eval_py(sh + "local out = {}; for _, t in ipairs(sh.raidTiles) do "
                      "if t:IsShown() then out[#out + 1] = t.name:GetText() end end; return out")
    assert names[:3] == ["Karazhan", "Gruul's Lair", "Magtheridon's Lair"] and len(names) == 9, names
    assert g.eval_py(sh + "local out = {}; for _, b in ipairs(sh.tabs) do out[#out + 1] = b:GetText() end; "
                          "return out") == ["Dungeon", "Raid", "Quest", "PvP", "Other"]
    # a raid of another size starts the pick over
    g.eval(sh + "sh.raidTiles[1]:Click()")
    assert g.eval_py("return ns.DungeonsUI:GetSheetState().ra") == ["Karazhan"]
    g.eval(sh + "sh.raidTiles[2]:Click()")
    g.eval(sh + "sh.raidTiles[3]:Click()")
    assert g.eval_py("return ns.DungeonsUI:GetSheetState().ra") == ["GruulsLair", "MagtheridonsLair"]
    # places: a damage place becomes a fourth tank; soft reserves, 2 each; bosses picked: Gruul only
    g.eval(sh + "sh.steppers.dps.prev:Click()")
    g.eval(sh + "sh.steppers.tank.next:Click()")
    assert strip_codes(g.eval_py(sh + "return sh.placesText:GetText()")) == "25 of 25"
    g.eval(sh + "sh.loot:Select('sr', true)")
    g.eval(sh + "sh.reserves.next:Click()")
    assert g.eval_py(sh + "return sh.reserves:IsShown()") is True
    g.eval(sh + "sh.bossMode:Select('pick', true)")
    assert g.eval_py(sh + "return sh.bossPick:IsShown()") is True
    gruul = g.eval_py("""for _, b in ipairs(ns.ItemDB:GetRaid('GruulsLair').bosses) do
        if b.name:find('Gruul') then return 'GruulsLair:' .. b.key end end""")
    g.eval("ns.DungeonsUI:GetSheetState().bo[...] = true; ns.DungeonsUI:RefreshSheet()", gruul)
    assert strip_codes(g.eval_py(sh + "return sh.bossPick:GetText()")) == "1 of 3 bosses"
    assert g.eval_py(sh + "return sh.preview:IsShown()") is True
    g.eval(sh + "sh.go:Click()")
    w.tick(3)
    assert g.eval_py("return ns.DungeonsUI:GetSheetState()") is None
    # a group bigger than a party opens its own page once listed
    assert g.eval_py("return ns.GroupsLead:IsOpen()") is True
    run = b.eval_py("""local r = ns.DungeonRuns:GetGroups('raid')[1]
      return r and { a = r.a, n = r.n, w = ns.DungeonRuns:GetWant(r), lo = r.lo, lr = r.lr, bo = r.bo }""")
    assert run == {"a": ["GruulsLair", "MagtheridonsLair"], "n": 25, "w": {"tank": 4, "healer": 6, "dps": 15},
                   "lo": "sr", "lr": 2, "bo": [gruul]}, run
    # Edit: the sheet comes back with the group as listed
    g.eval("ns.GroupsLead:Close()")
    g.eval("ns.DungeonsUI:OpenSheet(true)")
    s = g.eval_py("local s = ns.DungeonsUI:GetSheetState(); "
                  "return { kind = s.kind, ra = s.ra, wt = s.w.tank, lo = s.lo, lr = s.lr, edit = s.edit }")
    assert s == {"kind": "raid", "ra": ["GruulsLair", "MagtheridonsLair"], "wt": 4, "lo": "sr", "lr": 2,
                 "edit": True}, s
    assert g.eval_py(sh + "return sh.go:GetText()") == "Save"
    w.assert_no_errors()


@case
def a_saved_raid_is_off_in_the_sheet():
    w, c = guild([("Gina", "PALADIN")])
    g = c["Gina"]
    g.eval("""__MOCK.saved = { { 'Karazhan', 123, 3 * 86400, 3, true, false, 0, true, 10, '10 Player', 11, 4, false,
                                 532 } }""")
    g.eval("ns.DungeonRuns:ScanSaved()")
    g.eval("ns.MainFrame:Open('dungeons')")
    w.tick(1)
    g.eval("ns.DungeonsUI:SetTab('raid')")
    g.eval("ns.DungeonsUI:OpenSheet()")
    sh = "local sh = ns.DungeonsUI:GetPanel().sheet; "
    g.eval(sh + "sh.raidTiles[1]:Click()")
    assert g.eval_py("return #ns.DungeonsUI:GetSheetState().ra") == 0
    assert g.eval_py(sh + "return sh.raidTiles[1].lock:IsShown()") is True
    assert "saved" in g.eval_py(sh + "return sh.raidTiles[1].sub:GetText()")
    w.assert_no_errors()


@case
def a_missing_attunement_is_a_hint_not_a_block():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "WARRIOR")])
    g, b = c["Gina"], c["Bert"]
    roles(b, "tank")
    rid = list_group(g, k="raid", a=["Karazhan"], role="healer")
    w.tick(3)
    assert b.eval_py("return ns.DungeonRuns:GetMissingAttunements(ns.DungeonRuns:GetGroup(...))", rid) == \
        ["the Master's Key"]
    b.eval("ns.MainFrame:Open('dungeons')")
    w.tick(1)
    b.eval("ns.DungeonsUI:OpenCard(...)", rid)
    fit = strip_codes(card_eval(b, rid, "return c.open.fit:GetText()"))
    assert "check your attunement: the Master's Key" in fit, fit
    assert card_eval(b, rid, "return c.open.join:IsEnabled() and c.open.join:GetText()") == "Join as tank"
    # done: no hint
    b.eval("__MOCK.quests_done[9837] = true")
    b.eval("ns.DungeonsUI:Refresh()")
    w.tick(1)
    fit = strip_codes(card_eval(b, rid, "return c.open.fit:GetText()"))
    assert "attunement" not in fit, fit
    w.assert_no_errors()


@case
def the_leaders_page_shows_its_roster_and_request_hints():
    w, c = guild([("Gina", "PALADIN"), ("Dora", "DRUID"), ("Rory", "ROGUE"), ("Wes", "WARRIOR"), ("Hal", "HUNTER")])
    g, d, r, wes, hal = c["Gina"], c["Dora"], c["Rory"], c["Wes"], c["Hal"]
    assert g.eval_py("return (ns.RaidPlan:SetBlacklisted(...))", K(r), "ninja") is True
    w.tick(3)
    rid = list_group(g, k="raid", a=["Karazhan"], role="healer")
    w.tick(3)
    roles(d, "dps")
    roles(r, "dps")
    for x in (d, r):
        assert x.eval_py("return ns.DungeonRuns:Join(...)", rid) is True
    # Wes is up for dungeons only, Hal for raids too: only Hal is offered
    roles(wes, "tank")
    roles(hal, "dps")
    wes.eval("ns.DungeonRuns:SetMyKind('raid', false)")
    for x in (wes, hal):
        x.eval("ns.DungeonRuns:SetUp(true)")
    w.tick(5)
    g.eval("ns.MainFrame:Open('dungeons')")
    w.tick(1)
    g.eval("ns.DungeonsUI:SetTab('raid')")
    # my card: one line and Manage group; the page: 10 places by role, the requests, who fits
    line = strip_codes(card_eval(g, rid, "return c.manage:IsShown() and c.manage.text:GetText()"))
    assert line == "2 asking  ·  9 open places", line
    card_eval(g, rid, "c.manage.btn:Click()")
    assert g.eval_py("return ns.GroupsLead:IsOpen()") is True
    lead = "local sh = ns.GroupsLead:Get(); "
    # (players as rows, each role's free places as one "+n open" line)
    cells = g.eval_py("""local P, n, open = ns.GroupsLead.pools, 0, {}
      for _, r in ipairs(P.rows) do if r:IsShown() then n = n + 1 end end
      for _, o in ipairs(P.opens) do if o:IsShown() then open[#open + 1] = o.text:GetText() end end
      return { n, open }""")
    assert cells[0] == 1 and [strip_codes(x) for x in cells[1]] == ["+2 open", "+2 open", "+5 open"], cells
    hints = g.eval_py(lead + """local out = {}
      for _, q in ipairs(sh.reqRows) do
        if q:IsShown() then out[#out + 1] = (q.name:GetText() or '') .. '=' .. (q.what:GetText() or '') end
      end
      return out""")
    hints = dict(strip_codes(x).split("=", 1) for x in hints)
    assert "brings Mark of the Wild" in hints.get("Dora", ""), hints
    assert "On the blacklist" in hints.get("Rory", ""), hints
    offered = g.eval_py(lead + """local out = {}
      for _, ch in ipairs(sh.upChips) do if ch:IsShown() then out[#out + 1] = ch.p.fs:GetText() end end
      return out""") or []
    offered = [strip_codes(x) for x in offered]
    assert any("Hal" in x for x in offered) and not any("Wes" in x for x in offered), offered
    w.assert_no_errors()


@case
def the_raid_session_starts_as_the_group_listed_its_loot():
    w, c = guild([("Gina", "PALADIN"), ("Bert", "WARRIOR")])
    g = c["Gina"]
    rid = list_group(g, k="raid", a=["Karazhan"], role="healer", lo="sr", lr=2)
    w.tick(3)
    g.eval("InviteUnit('Bert')")
    w.tick(2)
    g.eval("ConvertToRaid()")
    w.tick(2)
    # arriving in Karazhan: the pop-up offers to start it
    g.eval("ns:Fire('GROUP_RAID_ARRIVED', ...)", rid)
    t = g.eval_py("local t = ns.DungeonsUI:GetToast(); return t and t:IsShown() and { run = t.run, "
                  "btn = t.btn:GetText() }")
    assert t == {"run": rid, "btn": "Start"}, t
    g.eval("ns.DungeonsUI:GetToast().btn:Click()")
    w.tick(2)
    f = g.eval_py("local f = ns.GroupRules:GetSessionFeatures(); return f and { reserve = f.reserve, loot = f.loot }")
    assert f == {"reserve": True, "loot": True}, f
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())

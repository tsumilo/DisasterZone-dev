"""ADDENDUM J §59-§60: team specs, the group grid (layout, buff icons) and Auto-fill, on the real addon.

Covers: RaidComp data (spec icons for every spec, buff providers by spec, coverage), Auto-fill for 25 and 10 players,
a team's size / specs / layout saved and synced (validated: entries of non-members dropped), specs picked
automatically from sign-ups, the Teams grid (click to pick + click a group, swap by dropping onto a member, a full
group refused, take out, right-click menu spec and moves, Auto-fill button, size change), seats kept within a group
(swap, empty seat, first free seat, group swap, saved and synced, raid layouts), party buff icons per group
and the raid-wide strip, and the read-only grid for members.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_groups.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import World, Client, gm_pick, K, DAY, now, team, create, signup, set_raid_leaders  # noqa: E402
from _common import case, run_all, printed_since, strip_codes, install_helpers, tt_lines  # noqa: E402

# name, class, rank
ROSTER = [
    ("Gina", "PALADIN", 0), ("Bob", "MAGE", 1), ("Lee", "WARRIOR", 3), ("Rita", "PRIEST", 3), ("Sam", "ROGUE", 3),
]
OFFLINE = [
    ("Ena", "SHAMAN"), ("Eli", "SHAMAN"), ("Rhea", "SHAMAN"), ("Tank", "WARRIOR"), ("Bear", "DRUID"),
    ("Holly", "PALADIN"), ("Hunt", "HUNTER"), ("Lock", "WARLOCK"), ("Moon", "DRUID"), ("Pip", "PRIEST"),
]


def guild():
    w = World()
    for n, cls in OFFLINE:
        w.add_offline_member(n, cls, 3)
    c = {}
    for n, cls, rank in ROSTER:
        c[n] = Client(w, n, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Bob"])
    set_raid_leaders(w, c["Gina"], ["Bob"])
    w.tick(2)
    return w, c


def autofill(cl, members, size):
    """members: [(name, class, spec index or None)] -> {name: group}"""
    ms = [{"key": K(n), "c": c, "sp": sp} for n, c, sp in members]
    res = cl.eval_py("local ms, size = ...; for _, m in ipairs(ms) do if m.sp == false then m.sp = nil end end;"
                     " return ns.RaidComp:AutoFill(ms, size)",
                     [dict(m, sp=(m["sp"] if m["sp"] is not None else False)) for m in ms], size)
    return {k.split("-")[0]: g for k, g in (res or {}).items()}


# ------------------------------------------------------------------------------------------------------------------
@case
def comp_data_covers_every_spec_and_buffs_follow_the_spec():
    w, c = guild()
    bob = c["Bob"]
    missing = bob.eval_py("local out = {}; for cls, specs in pairs(ns.SPECS) do for i in ipairs(specs) do"
                          " if not ns.RaidComp:SpecIcon(cls, i) then out[#out + 1] = cls .. i end end end; return out")
    assert missing == [], missing
    prov = lambda b, cls, sp: bob.eval("return ns.RaidComp:Provides(...)", b, cls, sp)
    assert prov("windfury", "SHAMAN", 3) is True and prov("totemofwrath", "SHAMAN", 1) is True
    assert prov("totemofwrath", "SHAMAN", 2) is False and prov("unleashedrage", "SHAMAN", 2) is True
    assert prov("trueshot", "HUNTER", 2) is True and prov("trueshot", "HUNTER", 1) is False
    assert prov("lotp", "DRUID", 3) is True and prov("lotp", "DRUID", 2) is True and prov("moonkin", "DRUID", 2) is False
    assert prov("fortitude", "PRIEST", None) is True and prov("misery", "PRIEST", None) is False   # spec unknown
    cov = bob.eval_py("return ns.RaidComp:Coverage({ { key = 'A', c = 'PRIEST', sp = 3 }, { key = 'B', c = 'MAGE', sp = 2 } }, 'raid')")
    lit = {e["buff"]["key"] for e in cov if e["providers"]}
    assert lit == {"fortitude", "misery", "arcaneint", "impscorch"}, lit
    party = bob.eval_py("return ns.RaidComp:Coverage({ { key = 'A', c = 'PRIEST', sp = 3 } }, 'party')")
    assert [e["buff"]["key"] for e in party if e["providers"]] == ["vampirictouch"]
    w.assert_no_errors()


@case
def shaman_air_totem_follows_the_group():
    w, c = guild()
    bob = c["Bob"]

    def party(*members):
        """members: (name, class, spec index or None) -> {lit party buff: its note ('' without one)}"""
        ms = [{"key": K(n), "c": cl, "sp": (sp if sp is not None else False)} for n, cl, sp in members]
        return bob.eval_py("local ms = ...; for _, m in ipairs(ms) do if m.sp == false then m.sp = nil end end;"
                           " local out = {}; for _, e in ipairs(ns.RaidComp:Coverage(ms, 'party')) do"
                           " if #e.providers > 0 then out[e.buff.key] = e.note or '' end end; return out", ms) or {}

    def air(*members):
        return sorted(k for k in party(*members) if k in ("windfury", "wrathofair"))

    # mostly melee (a rogue and a warrior count without a spec: all their specs are melee): Windfury
    melee = party(("Enh", "SHAMAN", 2), ("Rog", "ROGUE", None), ("War", "WARRIOR", None), ("Ret", "PALADIN", 3))
    assert "windfury" in melee and "wrathofair" not in melee, melee
    assert melee["windfury"] == "Picked for this group: mostly melee.", melee
    assert air(("Resto", "SHAMAN", 3), ("Tank", "WARRIOR", 3), ("Cat", "DRUID", 2), ("Rog", "ROGUE", 3)) == ["windfury"]
    # mostly casters, or healers: Wrath of Air
    assert air(("Ele", "SHAMAN", 1), ("Mage", "MAGE", None), ("Lock", "WARLOCK", 3), ("Sp", "PRIEST", 3)) == ["wrathofair"]
    heal = party(("Resto", "SHAMAN", 3), ("Hp", "PRIEST", 2), ("Hpal", "PALADIN", 1), ("Rog", "ROGUE", 2))
    assert "wrathofair" in heal and "windfury" not in heal, heal
    assert heal["wrathofair"] == "Picked for this group: mostly casters and healers.", heal
    # hunters gain from neither; a druid without a spec could be either: neither counts
    assert air(("Sha", "SHAMAN", None), ("H1", "HUNTER", 2), ("H2", "HUNTER", 1), ("Rog", "ROGUE", 1)) == ["windfury"]
    assert air(("Sha", "SHAMAN", None), ("Dru", "DRUID", None), ("Mage", "MAGE", 1)) == ["wrathofair"]
    # uncertain: both show, and say why
    even = party(("Sha", "SHAMAN", None), ("Rog", "ROGUE", 1), ("Mage", "MAGE", 1))
    assert {"windfury", "wrathofair"} <= set(even), even
    assert even["windfury"] == "Melee and casters are even here, so both show.", even
    assert air(("Sha", "SHAMAN", None)) == ["windfury", "wrathofair"]
    # two shamans: one of each when both kinds are there, else still the group's one
    two = party(("Enh", "SHAMAN", 2), ("Ele", "SHAMAN", 1), ("Rog", "ROGUE", 1), ("Mage", "MAGE", 1), ("War", "WARRIOR", 2))
    assert {"windfury", "wrathofair"} <= set(two) and two["wrathofair"] == "Two shamans here: one of each air totem.", two
    assert air(("E1", "SHAMAN", 2), ("E2", "SHAMAN", 2), ("Rog", "ROGUE", 1), ("War", "WARRIOR", 2)) == ["windfury"]
    # the raid-wide strip is not touched; other party buffs carry no note
    assert bob.eval("return ns.RaidComp:AirTotem({ { key = 'x', c = 'MAGE', sp = 1 } })") is None
    assert melee["heroism"] == "", melee
    w.assert_no_errors()


@case
def autofill_builds_a_sensible_starting_layout():
    w, c = guild()
    bob = c["Bob"]
    roster = [
        ("Tank1", "WARRIOR", 3), ("Tank2", "PALADIN", 2), ("Bear", "DRUID", 3),
        ("War", "WARRIOR", 2), ("Rog1", "ROGUE", 2), ("Rog2", "ROGUE", 2), ("Ret", "PALADIN", 3), ("Cat", "DRUID", 2),
        ("Enh", "SHAMAN", 2), ("Resto", "SHAMAN", 3), ("Ele", "SHAMAN", 1),
        ("Mage1", "MAGE", 3), ("Mage2", "MAGE", 2), ("Lock", "WARLOCK", 3), ("Spriest", "PRIEST", 3), ("Hunt", "HUNTER", 2),
        ("Heal1", "PRIEST", 2), ("Heal2", "PALADIN", 1), ("Heal3", "DRUID", 4), ("Heal4", "PALADIN", 1),
        ("Odd", "MAGE", None),
    ]
    g = autofill(bob, roster, 25)
    assert set(g) == {n for n, _, _ in roster}, g
    assert g["Tank1"] == 1 and g["Tank2"] == 1 and g["Bear"] == 1, g
    assert g["Enh"] in (2, 3) and g["Resto"] in (2, 3) and g["Enh"] != g["Resto"], g     # one shaman per melee group
    assert g["Ele"] == 4 and g["Spriest"] == 4 and g["Mage1"] == 4, g
    assert {g["Heal1"], g["Heal2"], g["Heal3"], g["Heal4"]} == {5}, g
    assert all(list(g.values()).count(x) <= 5 for x in range(1, 6)), g
    # 10-man: two groups, the rest stays out
    ten = autofill(bob, roster[:12], 10)
    assert set(ten.values()) <= {1, 2} and len(ten) == 10, ten
    assert ten["Ele"] == 2 and ten["Enh"] == 1, ten
    w.assert_no_errors()


@case
def team_size_specs_and_layout_save_sync_and_validate():
    w, c = guild()
    bob, rita = c["Bob"], c["Rita"]
    res = bob.eval_py("local ok, id = ns.RaidPlan:SaveTeam(nil, 'Main', { ...}, { size = 10, specs = { [...] = 2 },"
                      " groups = { ['Ena-Thunderstrike'] = 1, ['Lee-Thunderstrike'] = 2, ['Nope-Thunderstrike'] = 1 } });"
                      " return { ok = ok, id = id }", K("Ena"), K("Lee"), K("Rita"))
    # (the varargs above: members Ena / Lee / Rita; specs keyed by Ena)
    assert res["ok"] is True, res
    w.tick(2)
    t = rita.eval_py("return ns.RaidPlan:GetTeam(...)", res["id"])
    assert t["size"] == 10 and t["groups"] == {K("Ena"): 1, K("Lee"): 2}, t      # non-member entry dropped
    assert t["specs"] == {K("Ena"): 2}, t
    # a forged record with a spec out of range is refused as a whole
    rita.eval("ns.Comm:Send({ t = 'RPU', k = 'T', r = { id = 'x1', rev = GetServerTime(), by = 'Rita-Thunderstrike', n = 'X',"
              " m = { 'Rita-Thunderstrike' }, s = { ['Rita-Thunderstrike'] = 9 } } }, 'GUILD', nil, 'data')")
    w.tick(2)
    assert bob.eval("return ns.db.raidplan['Casual Disaster-Thunderstrike'].T.x1") is None
    # spec source: the team's pick, else the latest sign-up
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(2)
    signup(rita, occ, "A", 3)
    w.tick(2)
    assert bob.eval_py("return { ns.RaidPlan:GetMemberSpec(...) }", K("Rita")) == [3, "PRIEST", "signup"]
    assert bob.eval_py("return { ns.RaidPlan:GetMemberSpec(..., ns.RaidPlan:GetTeam(select(2, ...))) }",
                       K("Ena"), res["id"]) == [2, "SHAMAN", "team"]
    assert bob.eval_py("return { ns.RaidPlan:GetMemberSpec(...) }", K("Lee")) == [None, "WARRIOR"]
    w.assert_no_errors()


def grid_state(cl):
    """{group: [names]}, pool names, party buffs per shown group, lit raid-wide buffs."""
    st = cl.eval_py("""
      local grid = ns.RaidPlanUI:GetTeamGrid()
      local out = { groups = {}, buffs = {}, strip = {} }
      for g, box in ipairs(grid.boxes) do
        if box:IsShown() then
          local names, buffs = {}, {}
          for _, chip in ipairs(box.chips) do if chip.key then names[#names + 1] = chip.key end end
          for _, b in ipairs(box.buffs) do if b:IsShown() then buffs[#buffs + 1] = b.entry.buff.key end end
          out.groups[g], out.buffs[g] = names, buffs
        end
      end
      for _, b in ipairs(grid.strip) do
        if b:IsShown() and #b.entry.providers > 0 then out.strip[#out.strip + 1] = b.entry.buff.key end
      end
      return out""")
    for k in ("groups", "buffs"):
        v = st.get(k)
        if isinstance(v, list):
            st[k] = {i + 1: list(x) for i, x in enumerate(v)}
        elif not v:
            st[k] = {}
    return st


def short(keys):
    return sorted(k.split("-")[0] for k in keys)


@case
def teams_grid_moves_swaps_buffs_and_saves():
    w, c = guild()
    bob, rita = c["Bob"], c["Rita"]
    c["Rita"].slash("/dz raids")
    bob.slash("/dz raids")
    w.tick(0.5)
    bob.eval("ns.RaidsUI:SetView('teams')")
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().teams.empty.newBtn"))     # (no teams yet: the empty card's)
    w.tick(0.2)
    bob.eval("ns.RaidsUI:GetPanel().teams.nameBox:SetText('Kara A')")
    for n in ("Lee", "Rita", "Sam", "Ena", "Moon", "Holly", "Tank"):
        bob.eval("ns.RaidPlanUI:ToggleDraftMember(...)", K(n))
    bob.eval("ns.RaidPlanUI:SetDraftSize(10)")
    bob.eval("ns.RaidPlanUI:SetDraftSpec(..., 2)", K("Ena"))      # Enhancement
    bob.eval("ns.RaidPlanUI:SetDraftSpec(..., 1)", K("Moon"))     # Balance
    bob.eval("ns.RaidPlanUI:SetDraftSpec(..., 3)", K("Tank"))     # Protection
    w.tick(0.3)
    st = grid_state(bob)
    assert set(st["groups"]) == {1, 2} and all(v == [] for v in st["groups"].values()), st
    # the raid-wide strip lights what the players in the groups bring (nobody is placed yet)
    assert st["strip"] == [], st["strip"]
    # click a member, then a group
    grid = "ns.RaidPlanUI:GetTeamGrid()"
    bob.eval("%s:Pick(...)" % grid, K("Ena"))
    bob.click(bob.eval("return %s.boxes[1]" % grid))
    bob.eval("%s:Pick(...); %s:OnGroupClick(1)" % (grid, grid), K("Lee"))
    for n in ("Sam", "Tank", "Holly"):
        bob.eval("%s:Drop(..., 1)" % grid, K(n))
    w.tick(0.3)
    st = grid_state(bob)
    assert short(st["groups"][1]) == ["Ena", "Holly", "Lee", "Sam", "Tank"], st
    assert "sunder" in st["strip"] and "fortitude" not in st["strip"] and "motw" not in st["strip"], st["strip"]
    assert "arcaneint" not in st["strip"], st["strip"]            # no mage on the team
    assert {"heroism", "windfury", "unleashedrage", "battleshout", "paladinaura"} <= set(st["buffs"][1]), st["buffs"]
    assert "moonkin" not in st["buffs"][1]
    assert "wrathofair" not in st["buffs"][1], st["buffs"]     # a melee group: its shaman's air totem is Windfury
    install_helpers(bob)
    ena = bob.eval("for _, ch in ipairs(%s.boxes[1].chips) do if ch.key == ... then return ch end end" % grid, K("Ena"))
    bob.hover(ena)
    tip = [strip_codes(l) for l, _ in tt_lines(bob)]
    bob.leave(ena)
    assert any("Windfury Totem" in l for l in tip) and not any("Wrath of Air" in l for l in tip), tip
    wf = bob.eval("for _, b in ipairs(%s.boxes[1].buffs) do if b:IsShown() and b.entry.buff.key == 'windfury' then"
                  " return b end end" % grid)
    bob.hover(wf)
    tip = [strip_codes(l) for l, _ in tt_lines(bob)]
    bob.leave(wf)
    assert "Picked for this group: mostly melee." in tip, tip
    # empty seats: a faint fill for who can drop a player there (no lines between the seats)
    seats = bob.eval_py("local out = {}; for s, ch in ipairs(%s.boxes[2].chips) do out[s] = ch.seat:IsShown() end;"
                        " return out" % grid)
    assert list(seats.values() if isinstance(seats, dict) else seats) == [True] * 5, seats
    # group 1 is full: dropping on the box is refused, dropping onto a member swaps
    n0 = len(bob.chat_frame)
    bob.eval("%s:Drop(..., 1)" % grid, K("Moon"))
    assert any("Group 1 is full" in strip_codes(l) for l in printed_since(bob, n0))
    bob.eval("%s:Drop(..., 2)" % grid, K("Rita"))
    bob.eval("%s:Drop(..., 1, select(2, ...))" % grid, K("Rita"), K("Sam"))   # Rita <-> Sam
    w.tick(0.3)
    st = grid_state(bob)
    assert "Rita" in short(st["groups"][1]) and "Sam" in short(st["groups"][2]), st
    # the right-click menu: spec and moves
    chip = bob.eval("for _, ch in ipairs(%s.boxes[2].chips) do if ch.key == ... then return ch end end" % grid, K("Sam"))
    bob.click(chip, "RightButton")
    menu = [e["text"] for e in bob.last_menu()["children"] if e.get("text")]
    assert "Spec: Combat" in menu and "Move to group 1" in menu and "Remove from the team" in menu, menu
    assert "Unassign" in menu, menu
    bob.menu_select("Unassign")
    w.tick(0.3)
    assert "Sam" not in short(grid_state(bob)["groups"][2])
    assert bob.find_text("not saved", True, True)
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().teams.detail.saveBtn"))
    w.tick(2)
    t = rita.eval_py("return ns.RaidPlan:GetTeams()[1]")
    assert t["name"] == "Kara A" and t["size"] == 10, t
    assert t["specs"] == {K("Ena"): 2, K("Moon"): 1, K("Tank"): 3}, t["specs"]
    assert t["groups"][K("Rita")] == 1 and K("Sam") not in t["groups"], t["groups"]
    # members see the same grid, read-only
    rita.eval("ns.RaidsUI:SetView('teams')")
    w.tick(0.3)
    st = grid_state(rita)
    assert short(st["groups"][1]) == ["Ena", "Holly", "Lee", "Rita", "Tank"], st
    rita.eval("%s:Pick(...)" % grid, K("Lee"))
    rita.eval("%s:OnGroupClick(2)" % grid)
    rita.eval("ns.RaidPlanUI:MoveDraftMember(..., 2)", K("Lee"))
    w.tick(0.3)
    assert short(grid_state(rita)["groups"][1]) == ["Ena", "Holly", "Lee", "Rita", "Tank"]
    assert not rita.eval("return ns.RaidsUI:GetPanel().teams.detail.autoBtn:IsShown()")
    w.assert_no_errors()


@case
def autofill_button_and_size_change():
    w, c = guild()
    bob = c["Bob"]
    tid = team(bob, "Main", ["Lee", "Rita", "Sam", "Ena", "Eli", "Rhea", "Tank", "Bear", "Holly", "Hunt", "Lock", "Moon", "Pip"])
    bob.slash("/dz raids")
    w.tick(0.3)
    bob.eval("ns.RaidsUI:SetView('teams'); ns.RaidPlanUI:SelectTeam(...)", tid)
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().teams.detail.autoBtn"))
    w.tick(0.3)
    dr = bob.eval_py("return ns.RaidPlanUI:GetDraft()")
    assert len(dr["grp"]) == 13 and set(dr["grp"].values()) <= {1, 2, 3, 4, 5}, dr["grp"]
    shaman_groups = {dr["grp"][K(n)] for n in ("Ena", "Eli", "Rhea")}
    assert len(shaman_groups) == 3, dr["grp"]                        # one shaman per group
    bob.eval("ns.RaidPlanUI:SetDraftSize(10)")
    dr = bob.eval_py("return ns.RaidPlanUI:GetDraft()")
    assert set(dr["grp"].values()) <= {1, 2}, dr["grp"]
    st = grid_state(bob)
    assert set(st["groups"]) == {1, 2}
    w.assert_no_errors()


def seat_order(cl, grid="ns.RaidPlanUI:GetTeamGrid()", g=1):
    """Group g's seats top to bottom: short name or None for an empty seat."""
    keys = cl.eval_py("local grid, g = %s, ...; local out = {}; for s, ch in ipairs(grid.boxes[g].chips) do"
                      " out[s] = ch.key or false end; return out" % grid, g)
    keys = list(keys.values()) if isinstance(keys, dict) else list(keys)
    return [k.split("-")[0] if k else None for k in keys]


@case
def members_keep_the_seat_they_are_dropped_on():
    w, c = guild()
    bob, rita = c["Bob"], c["Rita"]
    rita.slash("/dz raids")
    bob.slash("/dz raids")
    w.tick(0.5)
    bob.eval("ns.RaidsUI:SetView('teams')")
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().teams.empty.newBtn"))     # (no teams yet: the empty card's)
    w.tick(0.2)
    bob.eval("ns.RaidsUI:GetPanel().teams.nameBox:SetText('Seats')")
    for n in ("Lee", "Rita", "Sam", "Holly"):
        bob.eval("ns.RaidPlanUI:ToggleDraftMember(...)", K(n))
    grid = "ns.RaidPlanUI:GetTeamGrid()"
    for n in ("Lee", "Holly", "Sam", "Rita"):
        bob.eval("%s:Drop(..., 1)" % grid, K(n))
    w.tick(0.3)
    assert seat_order(bob) == ["Lee", "Holly", "Sam", "Rita", None], seat_order(bob)
    # onto another member: the two trade seats
    bob.eval("%s:Drop(..., 1, select(2, ...))" % grid, K("Lee"), K("Rita"))
    w.tick(0.3)
    assert seat_order(bob) == ["Rita", "Holly", "Sam", "Lee", None], seat_order(bob)
    # onto an empty seat: that seat; the old one stays empty and nobody else moves
    bob.eval("%s:Drop(..., 1, nil, 5)" % grid, K("Holly"))
    w.tick(0.3)
    assert seat_order(bob) == ["Rita", None, "Sam", "Lee", "Holly"], seat_order(bob)
    # pick + click an empty seat
    bob.eval("%s:Pick(...)" % grid, K("Rita"))
    bob.click(bob.eval("return %s.boxes[1].chips[2]" % grid))
    w.tick(0.3)
    assert seat_order(bob) == [None, "Rita", "Sam", "Lee", "Holly"], seat_order(bob)
    # a newcomer takes the first free seat; out of the groups frees the seat
    bob.eval("ns.RaidPlanUI:ToggleDraftMember(...)", K("Ena"))
    bob.eval("%s:Drop(..., 1)" % grid, K("Ena"))
    bob.eval("%s:Drop(..., nil)" % grid, K("Sam"))
    w.tick(0.3)
    assert seat_order(bob) == ["Ena", "Rita", None, "Lee", "Holly"], seat_order(bob)
    # whole groups swap with their seats
    bob.eval("%s:SwapGroups(1, 2)" % grid)
    w.tick(0.3)
    assert seat_order(bob, g=2) == ["Ena", "Rita", None, "Lee", "Holly"], seat_order(bob, g=2)
    bob.eval("%s:SwapGroups(1, 2)" % grid)
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().teams.detail.saveBtn"))
    w.tick(2)
    t = rita.eval_py("return ns.RaidPlan:GetTeams()[1]")
    assert t["seats"] == {K("Ena"): 1, K("Rita"): 2, K("Lee"): 4, K("Holly"): 5}, t["seats"]
    rita.eval("ns.RaidsUI:SetView('teams')")
    w.tick(0.3)
    assert seat_order(rita) == ["Ena", "Rita", None, "Lee", "Holly"], seat_order(rita)
    # a raid layout keeps its seats too (bad seats are dropped, not the layout)
    occ = create(bob, i="kara", t=now(bob) + DAY)
    w.tick(1)
    res = bob.eval_py("local o, a, b = ...; local ok, e = ns.RaidPlan:SetGroups(o, { [a] = 1, [b] = 2 },"
                      " { [a] = 3, [b] = 9 }); return { ok = ok, e = e }", occ, K("Lee"), K("Sam"))
    assert res["ok"] is True, res
    w.tick(2)
    lay = rita.eval_py("local grp, saved, gs = ns.RaidPlan:GetLayout(...); return { grp = grp, saved = saved, gs = gs }",
                       occ)
    assert lay["saved"] is True and lay["gs"] == {K("Lee"): 3}, lay
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

"""ADDENDUM J §59-§60: team specs, the group grid (layout, buff icons) and Auto-fill, on the real addon.

Covers: RaidComp data (spec icons for every spec, buff providers by spec, coverage), Auto-fill for 25 and 10 players,
a team's size / specs / layout saved and synced (validated: entries of non-members dropped), specs picked
automatically from sign-ups, the Teams grid (click to pick + click a group, swap by dropping onto a member, a full
group refused, take out, right-click menu spec and moves, Auto-fill button, size change), party buff icons per group
and the raid-wide strip, and the read-only grid for members.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_groups.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import World, Client, gm_pick, K, DAY, now, team, create, signup, set_raid_leaders  # noqa: E402
from _common import case, run_all, printed_since, strip_codes  # noqa: E402

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
    c["Rita"].slash("/cdl raids")
    bob.slash("/cdl raids")
    w.tick(0.5)
    bob.eval("ns.RaidsUI:SetView('teams')")
    bob.click(bob.eval("return ns.RaidsUI:GetPanel().newTeamBtn"))
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
    assert "fortitude" in st["strip"] and "sunder" in st["strip"] and "motw" in st["strip"], st["strip"]
    assert "arcaneint" not in st["strip"], st["strip"]            # no mage on the team
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
    assert {"heroism", "windfury", "unleashedrage", "battleshout", "paladinaura"} <= set(st["buffs"][1]), st["buffs"]
    assert "moonkin" not in st["buffs"][1]
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
    bob.menu_select("Take out of the groups")
    w.tick(0.3)
    assert "Sam" not in short(grid_state(bob)["groups"][2])
    assert bob.find_text("(not saved)", True, True)
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
    bob.slash("/cdl raids")
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


if __name__ == "__main__":
    run_all()

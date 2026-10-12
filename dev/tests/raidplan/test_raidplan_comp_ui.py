"""Raids > Teams, the target comp's UI (dev/art/casc/teams_mockup sections 8-13), on the real addon.

Covers: the Groups | Comp tabs (organizers always, members once the team has a comp), the empty Comp card and Start
from, the steppers (+ hidden at the team's size), Save / Undo of the comp with the team, a size change that the comp
doesn't fit (offers the preset), the lineup row's meter and Needs (only players in a group count), the read-only Comp
view (my row lit, no +),
the strip's planned state, the open slots in a raid's Sign-ups (Add players with the spec ready) and the LF message.

Run: luaenv\\Scripts\\python.exe tests\\raidplan\\test_raidplan_comp_ui.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from rp_common import world, K, DAY, now, create, signup  # noqa: E402
from _common import case, run_all, strip_codes, install_helpers, tt_lines  # noqa: E402

P = "ns.RaidsUI:GetPanel()"
TV = P + ".teams"
D = TV + ".detail"
# name, spec index (ns.SPECS)
SPECS = {"Lee": ("WARRIOR", 3), "Rita": ("PRIEST", 2), "Sam": ("ROGUE", 2), "Bob": ("MAGE", 2)}


def shown(cl, expr):
    return cl.eval("local f = %s; return f ~= nil and f:IsShown() and f:IsVisible()" % expr) is True


def text_of(cl, expr):
    return strip_codes(cl.eval("local f = %s; return f and f:GetText()" % expr) or "")


def save_team(cl, name, members, size=10, comp=None, groups=None):
    res = cl.eval_py("local n, m, sz, s, cp, g = ...; local ok, r = ns.RaidPlan:SaveTeam(nil, n, m, { size = sz, specs = s, "
                     "groups = g, comp = cp or nil }); return { ok = ok, r = r }",
                     name, [K(n) for n in members], size, {K(n): SPECS[n][1] for n in members}, comp,
                     {K(n): g for n, g in (groups or {}).items()} or None)
    assert res["ok"] is True, res
    return res["r"]


def preset(cl, key):
    return cl.eval_py("return ns.RaidComp:GetPreset(...).cp", key)


def open_teams(w, cl, tid=None, tab="groups"):
    cl.slash("/dz raids")
    w.tick(0.5)
    cl.eval("ns.RaidsUI:SetView('teams')")
    if tid:
        cl.eval("ns.RaidPlanUI:SelectTeam(...)", tid)
    cl.eval("ns.RaidPlanUI:SetTeamTab(...)", tab)
    w.tick(0.3)


def click(cl, expr):
    cl.eval("local b = %s; b:GetScript('OnClick')(b, 'LeftButton')" % expr)


def menu_pick(cl, word):
    entries = [e.get("text") for e in (cl.last_menu() or {}).get("children", []) if e.get("text")]
    hit = [t for t in entries if strip_codes(t).strip() == word]
    assert hit, entries
    cl.menu_select(hit[0])


def col_rows(cl, i):
    """Column i of the Comp view: [(name, open)] of the shown rows."""
    rows = cl.eval_py("local out = {}; for _, r in ipairs(%s.cols[%d].rows) do if r:IsShown() then out[#out + 1] = "
                      "{ r.slot.member and r.fs:GetText() or r.slot.name, r.slot.member == nil } end end; return out"
                      % (D, i)) or []
    rows = rows.values() if isinstance(rows, dict) else rows
    return [(strip_codes(t), bool(o)) for t, o in rows]


@case
def organizers_draft_the_comp_and_save_it_with_the_team():
    w, c = world()
    bob = c["Bob"]
    tid = save_team(bob, "Kara A", ["Lee", "Rita", "Sam", "Bob"], groups={"Lee": 1, "Rita": 1, "Sam": 2, "Bob": 2})
    w.tick(1)
    open_teams(w, bob, tid, "comp")
    # tabs for organizers; no comp yet: the empty card with its starts, no tool row (nothing to save)
    assert shown(bob, D + ".views") and shown(bob, D + ".compEmpty") and not shown(bob, D + ".tool")
    tiles = [text_of(bob, "%s.compEmpty.tiles[%d].t1" % (D, i)) for i in (1, 2, 3)
             if shown(bob, "%s.compEmpty.tiles[%d]" % (D, i))]
    assert tiles == ["Kara 10", "The team as it is"], tiles
    click(bob, D + ".compEmpty.tiles[2]")
    w.tick(0.3)
    cp = bob.eval_py("return ns.RaidPlanUI:GetDraft().cp")
    assert cp == {"WARRIOR": [0, 0, 1], "PRIEST": [0, 1], "ROGUE": [0, 1], "MAGE": [0, 1]}, cp
    assert shown(bob, D + ".compScroll") and shown(bob, D + ".saveBtn") and shown(bob, D + ".startBtn")
    assert text_of(bob, D + ".tabComp") == "Comp  4/4"
    assert col_rows(bob, 2) == [("Rita", False)], col_rows(bob, 2)
    # + on Healers: the steppers; Restoration Druid 0 -> 1
    click(bob, D + ".cols[2].add")
    steps = "ns.RaidPlanUI:GetCompSteps()"
    assert shown(bob, steps)
    names = [strip_codes(bob.eval("return %s.rows[%d].fs:GetText()" % (steps, i))) for i in range(1, 6)]
    assert names == ["Holy Paladin", "Discipline Priest", "Holy Priest", "Restoration Shaman", "Restoration Druid"], names
    assert not shown(bob, steps + ".rows[5].minus") and shown(bob, steps + ".rows[5].plus")
    click(bob, steps + ".rows[5].plus")
    w.tick(0.3)
    assert bob.eval("return ns.RaidComp:GetCount(ns.RaidPlanUI:GetDraft().cp, 'DRUID', 4)") == 1
    assert text_of(bob, steps + ".foot") == "5 of 10 slots"
    assert col_rows(bob, 2) == [("Rita", False), ("Restoration Druid", True)], col_rows(bob, 2)
    # the lineup's tab follows the draft: its count, the open slots in its tooltip
    assert text_of(bob, D + ".lcards[1].count") == "4/5"
    tip = [strip_codes(t[0]) for t in (lambda r: r.values() if isinstance(r, dict) else r)(
        bob.eval_py("return %s.lcards[1].tipLines" % D))]
    assert any(t.endswith("Restoration Druid") for t in tip), tip
    # Save: the comp goes with the team
    bob.click(bob.eval("return %s.saveBtn" % D))
    w.tick(1)
    t = c["Rita"].eval_py("return ns.RaidPlan:GetTeam(...)", tid)
    assert t["comp"] == {"WARRIOR": [0, 0, 1], "PRIEST": [0, 1], "ROGUE": [0, 1], "MAGE": [0, 1], "DRUID": [0, 0, 0, 1]}, t
    assert not shown(bob, D + ".saveBtn")
    # Undo brings a changed comp back; "No comp" empties it (saved: the team has none)
    click(bob, steps + ".rows[1].plus")
    w.tick(0.3)
    bob.click(bob.eval("return %s.revertBtn" % D))
    w.tick(0.3)
    assert bob.eval("return ns.RaidComp:CompSize(ns.RaidPlanUI:GetDraft().cp)") == 5
    bob.click(bob.eval("return %s.startBtn" % D))
    menu_pick(bob, "No comp")
    w.tick(0.3)
    assert shown(bob, D + ".compEmpty") and shown(bob, D + ".saveBtn")
    bob.click(bob.eval("return %s.saveBtn" % D))
    w.tick(1)
    assert c["Rita"].eval_py("return ns.RaidPlan:GetTeam(...)", tid).get("comp") is None
    w.assert_no_errors()


@case
def a_full_comp_hides_plus_and_a_smaller_size_offers_the_preset():
    w, c = world()
    bob = c["Bob"]
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, comp=preset(bob, "std25"))
    w.tick(1)
    open_teams(w, bob, tid, "comp")
    assert all(not shown(bob, "%s.cols[%d].add" % (D, i)) for i in range(1, 5))
    # a slot clicked opens the steppers too: the footer says why + is gone
    click(bob, D + ".cols[1].rows[1]")
    assert "25 of 25 slots · take one out to add another" == text_of(bob, "ns.RaidPlanUI:GetCompSteps().foot")
    # 10-man: the comp has 25 slots, so the size waits for Kara 10
    bob.eval("ns.RaidPlanUI:SetDraftSize(10)")
    assert bob.popups() == ["DISASTERZONE_TEAM_COMP_SIZE"]
    assert bob.eval("return ns.RaidPlanUI:GetDraft().sz") == 25
    bob.accept_popup("DISASTERZONE_TEAM_COMP_SIZE")
    w.tick(0.3)
    dr = bob.eval_py("return ns.RaidPlanUI:GetDraft()")
    assert dr["sz"] == 10 and dr["cp"] == preset(bob, "kara10"), dr
    w.assert_no_errors()


@case
def members_see_the_meter_needs_and_a_read_only_comp():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    plain = save_team(bob, "Alt", ["Rita", "Lee"])
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, comp=preset(bob, "std25"),
                    groups={"Rita": 1, "Lee": 1})
    w.tick(2)
    open_teams(w, rita, tid, "groups")
    # the Comp tab shows; the lineup's tab lists the open slots (comp order) in its tooltip
    assert shown(rita, D + ".tabComp") and text_of(rita, D + ".lcards[1].count") == "2/25"
    tip = [strip_codes(t[0]).strip() for t in (lambda r: r.values() if isinstance(r, dict) else r)(
        rita.eval_py("return %s.lcards[1].tipLines" % D))]
    opened = tip[tip.index("Still open:") + 1:]
    assert opened[0].endswith("Protection Paladin") and opened[1].endswith("Feral Druid (Bear)"), opened
    # the Comp view: read-only, my row lit, the raid buffs in the toolbar, no Start from, no +
    rita.eval("ns.RaidPlanUI:SetTeamTab('comp')")
    w.tick(0.3)
    assert not shown(rita, D + ".startBtn") and shown(rita, D + ".compStrip") and shown(rita, D + ".compScroll")
    # hover an open slot: who could fill it (nobody here plays Protection Paladin)
    install_helpers(rita)
    row = rita.eval("for _, r in ipairs(%s.cols[1].rows) do if r:IsShown() and not r.slot.member then return r end end" % D)
    rita.hover(row)
    tip = [strip_codes(l).strip() for l, _ in tt_lines(rita)]
    rita.leave(row)
    assert "Protection Paladin" in tip[0], tip
    assert "Nobody in the guild plays it yet." in tip, tip
    assert all(not shown(rita, "%s.cols[%d].add" % (D, i)) for i in range(1, 5))
    lit = rita.eval_py("local out = {}; for _, col in ipairs(%s.cols) do for _, r in ipairs(col.rows) do "
                       "if r:IsShown() and r.me:IsShown() then out[#out + 1] = r.slot.member.key end end end; "
                       "return out" % D)
    assert list(lit.values() if isinstance(lit, dict) else lit) == [K("Rita")], lit
    # a team without a comp: no Comp tab for members, back on Groups
    rita.eval("ns.RaidPlanUI:SelectTeam(...)", plain)
    w.tick(0.3)
    assert not shown(rita, D + ".tabComp") and shown(rita, D + ".scroll")
    assert rita.eval("return ns.RaidPlanUI:GetTeamTab()") == "groups"
    w.assert_no_errors()


@case
def a_comp_saved_elsewhere_shows_at_once():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, groups={"Lee": 1, "Rita": 1, "Sam": 2})
    w.tick(2)
    open_teams(w, rita, tid, "groups")
    assert not shown(rita, D + ".tabComp")
    # the GM / council saves a comp: the member's view (nothing edited there) takes the new version
    res = bob.eval_py("local ok, r = ns.RaidPlan:SetTeamComp(..., ns.RaidComp:GetPreset('std25').cp); "
                      "return { ok = ok, r = r }", tid)
    assert res["ok"] is True, res
    w.tick(3)
    assert shown(rita, D + ".tabComp")
    assert text_of(rita, D + ".tabComp") == "Comp  3/25"                # (Bob is unassigned: he doesn't count)
    w.assert_no_errors()


@case
def the_strip_shows_what_the_comp_plans():
    w, c = world()
    bob = c["Bob"]
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, comp=preset(bob, "std25"),
                    groups={"Lee": 1, "Rita": 1})
    w.tick(1)
    open_teams(w, bob, tid, "comp")
    states = bob.eval_py("local out = {}; for _, b in ipairs(%s.compStrip.icons) do if b:IsShown() then "
                         "out[b.entry.key] = { b.entry.state, b.edges[1]:IsShown() } end end; return out" % D)
    assert states["fortitude"] == ["have", False], states          # Rita fills Holy Priest
    assert states["faeriefire"] == ["planned", True], states       # Balance / Feral slots open
    # the Groups strip: who is in the groups lights, the open slots are planned
    bob.eval("ns.RaidPlanUI:SetTeamTab('groups')")
    w.tick(0.3)
    g = bob.eval_py("local out = {}; for _, b in ipairs(ns.RaidPlanUI:GetTeamGrid().strip) do if b:IsShown() then "
                    "out[b.entry.key] = b.entry.state end end; return out")
    assert g["sunder"] == "have" and g["arcaneint"] == "planned", g    # Bob (Fire Mage) sits in no group
    w.assert_no_errors()


GRID = "ns.RaidPlanUI:GetTeamGrid()"


def plate_of(cl, key):
    return cl.eval("local g = %s; for _, box in ipairs(g.boxes) do for _, ch in ipairs(box.chips) do "
                   "if box:IsShown() and ch.key == ... then return ch end end end" % GRID, key)


@case
def the_groups_show_plates_ghost_seats_and_a_plate_can_be_dragged():
    w, c = world()
    bob = c["Bob"]
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, comp=preset(bob, "std25"),
                    groups={"Lee": 1, "Rita": 1, "Sam": 2})
    w.tick(1)
    open_teams(w, bob, tid, "groups")
    # plates: the spec under the name, no class circle or role icon of the old chip
    lee = plate_of(bob, K("Lee"))
    assert lee is not None
    assert text_of(bob, GRID + ".boxes[1].chips[1].pSub") != ""
    assert bob.eval("local ch = ...; return ch.cls:IsShown() or ch.spec:IsShown()", lee) is False
    # the comp's open slots wait in the free seats (25 - 3 placed = 22 ghosts at most, every free seat here)
    ghosts = bob.eval("local n = 0; for _, box in ipairs(%s.boxes) do if box:IsShown() then for _, ch in "
                      "ipairs(box.chips) do if ch.ghost then n = n + 1 end end end end; return n" % GRID)
    assert ghosts == 22, ghosts
    # drag Lee onto group 3's second seat: lifted plate, the seat lit, the label says where
    bob.eval("_G.IsMouseButtonDown = function() return true end")
    bob.eval("%s:BeginDrag(...)" % GRID, lee)
    assert plate_of(bob, K("Lee")) is None
    bob.eval("local g = %s; g.boxes[3].IsMouseOver = function() return true end; "
             "g.boxes[3].chips[2].IsMouseOver = function() return true end" % GRID)
    w.tick(0.2)
    assert bob.eval("local m = %s.marker; return m ~= nil and m:IsShown()" % GRID) is True
    assert "Group 3, seat 2" in text_of(bob, "ns.RaidGroupsUI.__plateGhost.tip.fs")
    bob.eval("_G.IsMouseButtonDown = function() return false end")
    w.tick(0.2)
    bob.eval("local g = %s; g.boxes[3].IsMouseOver = nil; g.boxes[3].chips[2].IsMouseOver = nil" % GRID)
    w.tick(0.3)
    dr = bob.eval_py("return ns.RaidPlanUI:GetDraft()")
    assert dr["grp"][K("Lee")] == 3 and dr["gs"][K("Lee")] == 2, dr
    assert not bob.eval("return %s.marker:IsShown()" % GRID)
    # the last unassigned card (Bob): lifted, its frame stays up as the spot it left (in game only a shown frame hears
    # that its drag ended), and the drop lands
    last = bob.eval("local g = %s; local last; for _, ch in ipairs(g.pool.chips) do if ch:IsShown() and ch.key then "
                    "last = ch end end; return last" % GRID)
    assert bob.eval("return (...).key", last) == K("Bob")
    bob.eval("_G.IsMouseButtonDown = function() return true end")
    bob.eval("%s:BeginDrag(...)" % GRID, last)
    assert bob.eval("local ch = ...; return ch:IsShown() and ch.key == nil and ch.holding == true", last) is True
    bob.eval("local g = %s; g.boxes[4].IsMouseOver = function() return true end; "
             "g.boxes[4].chips[1].IsMouseOver = function() return true end" % GRID)
    bob.eval("local ch = ...; ch:GetScript('OnDragStop')(ch)", last)
    bob.eval("_G.IsMouseButtonDown = function() return false end; local g = %s; g.boxes[4].IsMouseOver = nil; "
             "g.boxes[4].chips[1].IsMouseOver = nil" % GRID)
    w.tick(0.3)
    dr = bob.eval_py("return ns.RaidPlanUI:GetDraft()")
    assert dr["grp"][K("Bob")] == 4 and dr["gs"][K("Bob")] == 1, dr
    # a drag whose lifted card never came up (an error on the way, in game) can't keep a player out of the layout
    bob.eval("local g = %s; g.dragging = ...; g.dragCard = nil; g:Refresh()" % GRID, K("Lee"))
    assert plate_of(bob, K("Lee")) is not None and bob.eval("return %s.dragging" % GRID) is None
    w.assert_no_errors()


def comp_drag(cl, w, src, over):
    """Drags src onto the frame `over` (nil: nowhere) in the Comp view; returns the lifted card's label."""
    cl.eval("_G.IsMouseButtonDown = function() return true end")
    cl.eval("local s = ...; s:GetScript('OnDragStart')(s)", src)
    if over:
        cl.eval("local f = ...; f.IsMouseOver = function() return true end", over)
    w.tick(0.2)
    label = strip_codes(cl.eval("local g = ns.RaidGroupsUI.__plateGhost; return g and g.tip:IsShown() and "
                                "g.tip.fs:GetText() or ''") or "")
    cl.eval("local s = ...; s:GetScript('OnDragStop')(s)", src)
    if over:
        cl.eval("local f = ...; f.IsMouseOver = nil", over)
    cl.eval("_G.IsMouseButtonDown = function() return false end")
    w.tick(0.3)
    return label


@case
def comp_slots_fill_by_dragging_and_a_slots_player_drags_out():
    w, c = world()
    bob = c["Bob"]
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, comp=preset(bob, "std25"),
                    groups={"Lee": 1, "Rita": 1})
    w.tick(1)
    open_teams(w, bob, tid, "comp")
    # Sam (Combat Rogue, unassigned) onto an open Rogue slot: he takes the seat where it waits, as its spec
    find = ("for _, col in ipairs(%s.cols) do for _, r in ipairs(col.rows) do if r:IsShown() and r.slot and "
            "not r.slot.member and r.slot.c == ... then return r end end end" % D)
    sam = bob.eval("for _, ch in ipairs(%s.unassigned.chips) do if ch:IsShown() and ch.member and ch.member.key == ... "
                   "then return ch end end" % D, K("Sam"))
    assert sam is not None
    priest = bob.eval(find, "PRIEST")
    label = comp_drag(bob, w, sam, priest)
    assert label.startswith("Only a Priest"), label
    assert bob.eval_py("return ns.RaidPlanUI:GetDraft().grp").get(K("Sam")) is None
    rogue = bob.eval(find, "ROGUE")
    slot = bob.eval_py("local r = ...; return { sp = r.slot.sp }", rogue)
    label = comp_drag(bob, w, sam, rogue)
    assert label.startswith("Group "), label
    dr = bob.eval_py("return ns.RaidPlanUI:GetDraft()")
    assert dr["grp"].get(K("Sam")) is not None, dr
    assert dr["s"][K("Sam")] == slot["sp"], (dr["s"], slot)
    # a slot's player (Lee) onto Unassigned: out of the groups, the slot opens again
    lee = bob.eval("for _, col in ipairs(%s.cols) do for _, r in ipairs(col.rows) do if r:IsShown() and r.slot and "
                   "r.slot.member and r.slot.member.key == ... then return r end end end" % D, K("Lee"))
    assert lee is not None
    label = comp_drag(bob, w, lee, bob.eval("return %s.unassigned" % D))
    assert label == "Out of the groups", label
    assert bob.eval_py("return ns.RaidPlanUI:GetDraft().grp").get(K("Lee")) is None
    assert shown(bob, D + ".saveBtn")
    w.assert_no_errors()


@case
def a_group_title_dragged_onto_another_group_swaps_them():
    w, c = world()
    bob = c["Bob"]
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, groups={"Lee": 1, "Rita": 1, "Sam": 2})
    w.tick(1)
    open_teams(w, bob, tid, "groups")
    title = bob.eval("return %s.boxes[1].swap" % GRID)
    # a click does nothing now (no picked state, no outlines, no SWAPPING)
    bob.click(title)
    assert bob.eval("return %s.swapFrom" % GRID) is None
    assert strip_codes(bob.eval("return %s.boxes[1].countFs:GetText()" % GRID) or "") == ""
    label = comp_drag(bob, w, title, bob.eval("return %s.boxes[3]" % GRID))
    assert label == "Swap with Group 3", label
    dr = bob.eval_py("return ns.RaidPlanUI:GetDraft()")
    assert dr["grp"][K("Lee")] == 3 and dr["grp"][K("Rita")] == 3 and dr["grp"][K("Sam")] == 2, dr["grp"]
    w.assert_no_errors()


@case
def switching_groups_and_comp_slides_the_thumb_and_fades_the_view_in():
    # (1.4: Groups | Comp are the tool row's tabs; the view still fades in, the open tab is the selected one)
    w, c = world()
    bob = c["Bob"]
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, comp=preset(bob, "std25"),
                    groups={"Lee": 1, "Rita": 1})
    w.tick(1)
    open_teams(w, bob, tid, "groups")
    bar = D + ".views"
    assert bob.eval("return %s:GetSelectedTab()" % bar) == "groups"
    bob.click(bob.eval("return %s.tabComp" % D))
    # right after the click: on its way (the view still faint), Comp the open tab
    assert bob.eval("return %s.compScroll:GetAlpha()" % D) < 0.5
    assert bob.eval("return %s:GetSelectedTab()" % bar) == "comp"
    w.tick(0.5)
    assert bob.eval("return %s.compScroll:GetAlpha()" % D) == 1
    # and back: the groups fade in
    bob.click(bob.eval("return %s.tabGroups" % D))
    assert bob.eval("return %s.scroll:GetAlpha()" % D) < 0.5
    w.tick(0.5)
    assert bob.eval("return %s.scroll:GetAlpha()" % D) == 1 and bob.eval("return %s:GetSelectedTab()" % bar) == "groups"
    w.assert_no_errors()


@case
def a_raid_lists_the_open_slots_and_the_lf_message():
    w, c = world()
    bob, rita = c["Bob"], c["Rita"]
    tid = save_team(bob, "Main", ["Lee", "Rita", "Sam", "Bob"], size=25, comp=preset(bob, "std25"),
                    groups={"Lee": 1, "Rita": 1, "Sam": 2, "Bob": 2})
    occ = create(bob, i="ssc", t=now(bob) + 2 * DAY, tm=[tid])
    w.tick(2)
    signup(rita, occ, "A", 2)
    w.tick(2)
    # Sign-ups: the healers' band ends with the open slots (ghost plates: the spec, the class under it); the count
    # stays the answers
    bob.slash("/dz raids")
    w.tick(0.3)
    bob.eval("ns.RaidsUI:SetView('upcoming'); ns.RaidPlanUI:SelectRaid(...); ns.RaidPlanUI:SetDetailTab('signups')", occ)
    w.tick(0.3)
    rows = bob.eval_py("local out = {}; for _, r in ipairs(%s.upcoming.detail.roster.cols[2].rows) do if r:IsShown() then "
                       "out[#out + 1] = { r.fs:GetText(), r.cdlCell.open == true } end end; return out" % P)
    rows = [(strip_codes(t), bool(o)) for t, o in (rows.values() if isinstance(rows, dict) else rows)]
    assert rows[0] == ("Rita", False) and ("Holy", True) in rows and ("Restoration", True) in rows, rows
    assert text_of(bob, P + ".upcoming.detail.roster.cols[2].count") == "1"
    # who runs the raid: a click opens Add players with that class and spec ready for a guest
    bob.eval("for _, r in ipairs(%s.upcoming.detail.roster.cols[2].rows) do if r:IsShown() and r.cdlCell.open "
             "and r.cdlCell.c == 'DRUID' then r:GetScript('OnClick')(r, 'LeftButton') end end" % P)
    w.tick(0.3)
    win = bob.eval_py("local w = ns.RaidPlanUI:GetInviteWindow(); return { shown = w:IsShown(), c = w.cls, sp = w.sp }")
    assert win == {"shown": True, "c": "DRUID", "sp": 4}, win
    bob.eval("ns.RaidPlanUI:GetInviteWindow():Hide()")
    # the team's ... menu: LF message puts the line in the chat box
    bob.eval("ns.RaidsUI:SetView('teams'); ns.RaidPlanUI:SelectTeam(...)", tid)
    w.tick(0.3)
    bob.click(bob.eval("return %s.moreBtn" % D))
    menu_pick(bob, "LF message")
    line = bob.eval("return __MOCK.opened_chat")
    assert line and "LF Protection Paladin" in line and "SSC" in line and line.endswith("/w me"), line
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

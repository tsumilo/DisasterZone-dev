#!/usr/bin/env python
"""Main tanks and the raid frames (Core/Tanks.lua, UI/LookTanks.lua, UI/LookUnits.lua; mockup
claude.ai/artifact/CsS7UiuQrEXProchyuQ7jb, the user's picks 2026-10-13): party frames hide in a raid unless asked;
one list of main tanks (the game's flag, the leader's order shared with the raid, the plan's order); the tank block
(a secure header by name, tank + mob halves, the x, the plan's one-click button); shields on the raid cells; the
target and hover marks; boss mods and the threat meter read the same list.

Run: luaenv\\Scripts\\python.exe tests\\uilook\\test_tanks.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

from _common import case, run_all, solo  # noqa: E402


def halo_raid(extra=("Bob", "Carol", "Dave", "Erin"), lead=True):
    """Alice (Halo raid frames) in a raid with extra members; Alice leads unless lead=False."""
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.look', 'halo')")
    c.relog()
    w.tick(2)
    w.auto_session = False
    others = list(extra)
    if lead:
        w.make_raid([c], extra_members=others)
    else:
        w.make_raid([c], extra_members=others, leader=others[0])
    w.tick(1)
    return w, c


def set_mt(c, unit):
    """The game's flag on unit, as the client sees it (the mock keeps it per client)."""
    c.eval("local m = __MOCK.unit_rec(...); __MOCK.assign.MAINTANK[m.full or (m.name .. '-' .. __MOCK.norm_realm(m.realm))]"
           " = true; __MOCK.fire('GROUP_ROSTER_UPDATE')", unit)


def tank_names(c):
    return c.eval_py("local o = {} for i, e in ipairs(ns.Tanks:List()) do o[i] = e.name end return o")


# Fake units for a tank's target and who it hits: __MOB = { name, hp, on = unit token }
MOB_STUB = """
    _G.__MOB = { name = 'High King Maulgar', hp = 88, on = 'raid2' }
    local R = {}
    for _, f in ipairs({ 'UnitExists', 'UnitName', 'UnitIsPlayer', 'UnitIsUnit', 'UnitCanAttack', 'UnitHealth',
                         'UnitHealthMax', 'UnitClass', 'UnitReaction', 'GetRaidTargetIndex', 'UnitIsDeadOrGhost',
                         'UnitLevel', 'UnitClassification' }) do R[f] = _G[f] end
    local function mob(u) return type(u) == 'string' and u:match('^raid%d+target$') ~= nil end
    local function tt(u) return type(u) == 'string' and u:match('^raid%d+targettarget$') ~= nil end
    UnitExists = function(u) if mob(u) then return __MOB.name ~= nil end if tt(u) then return __MOB.on ~= nil end return R.UnitExists(u) end
    UnitName = function(u) if mob(u) then return __MOB.name end if tt(u) then return R.UnitName(__MOB.on) end return R.UnitName(u) end
    UnitIsPlayer = function(u) if mob(u) then return false end if tt(u) then return true end return R.UnitIsPlayer(u) end
    UnitIsUnit = function(a, b) if tt(a) then return __MOB.on == b end if mob(a) then return b == 'target' and __MOB.targeted == true end return R.UnitIsUnit(a, b) end
    UnitCanAttack = function(a, u) if mob(u) then return true end return R.UnitCanAttack and R.UnitCanAttack(a, u) end
    UnitHealth = function(u) if mob(u) then return __MOB.hp end return R.UnitHealth(u) end
    UnitHealthMax = function(u) if mob(u) then return 100 end return R.UnitHealthMax(u) end
    UnitClass = function(u) if mob(u) then return nil end if tt(u) then return R.UnitClass(__MOB.on) end return R.UnitClass(u) end
    UnitReaction = function(a, b) if mob(a) then return 2 end return R.UnitReaction and R.UnitReaction(a, b) end
    GetRaidTargetIndex = function(u) if mob(u) then return 8 end return R.GetRaidTargetIndex(u) end
    UnitIsDeadOrGhost = function(u) if mob(u) then return false end return R.UnitIsDeadOrGhost(u) end
    UnitLevel = function(u) if mob(u) then return -1 end return R.UnitLevel(u) end
    UnitClassification = function(u) if mob(u) then return 'worldboss' end return R.UnitClassification and R.UnitClassification(u) end
"""


# ------------------------------------------------------------------------------------------------------------------
@case
def party_frames_hide_in_a_raid_unless_asked():
    w, c = halo_raid()
    vis = "return ns.LookUnits:Header('party').dzVisibility"
    assert c.eval(vis) == "[group:raid] hide; show"
    # (the game's state driver: hidden while in a raid)
    assert c.eval("return ns.LookUnits:Header('party'):IsShown()") is False
    # the switch in Settings > Interface > Looks > Party & raid frames
    c.eval("ns.DB:SetSetting('ui.group.partyInRaid', true)")
    w.tick(0.2)
    assert c.eval(vis) == "show"
    assert c.eval("return ns.LookUnits:Header('party'):IsShown()") is True
    c.eval("ns.DB:SetSetting('ui.group.partyInRaid', false)")
    w.tick(0.2)
    assert c.eval(vis) == "[group:raid] hide; show"
    # "Me in my party" now applies at once too
    c.eval("ns.DB:SetSetting('ui.group.player', true)")
    w.tick(0.2)
    assert c.eval("return ns.LookUnits:Header('party'):GetAttribute('showPlayer')") is True
    w.assert_no_errors()


@case
def the_tanks_are_the_games_flag_in_order():
    w, c = halo_raid()
    assert tank_names(c) == []
    assert c.eval("return ns.Tanks:CanSet()") is True
    # the leader flags two (SetPartyAssignment: the game's own, a secure click in game)
    c.eval("SetPartyAssignment('MAINTANK', 'raid4'); SetPartyAssignment('MAINTANK', 'raid2')")
    w.tick(0.2)
    assert tank_names(c) == ["Bob", "Dave"]                      # (the raid's order without anything else)
    key = c.eval("return ns.Util.NormalizeName('Dave')")
    assert c.eval("return ns.Tanks:Number(...)", key) == 2
    assert c.eval("return ns.Tanks:NumberOfUnit('raid4')") == 2
    # the tank block's header shows them by name, in that order
    hd = c.eval_py("local h = ns.LookTanks:Header(); return { h:GetAttribute('nameList'), h:GetAttribute('sortMethod'), "
                   "h:GetAttribute('showRaid'), h:GetAttribute('initialConfigFunction') }")
    assert hd[0] == "Bob,Dave" and hd[1] == "NAMELIST" and hd[2] is True, hd
    assert "SetWidth(170)" in hd[3] and "SetHeight(32)" in hd[3], hd[3]      # (two Halo cells and 2 px)
    # a member can't set them
    w2, m = halo_raid(lead=False)
    assert m.eval("return ns.Tanks:CanSet()") is False
    m.eval("SetPartyAssignment('MAINTANK', 'raid3')")
    w2.tick(0.2)
    assert tank_names(m) == []
    w.assert_no_errors()


@case
def the_leaders_order_reaches_the_raid():
    w, c = halo_raid(extra=("Dave", "Erin"))
    bob = w.add_client("Bob", class_file="WARRIOR", guild_rank=3)
    bob.load_addon()
    w.tick(2)
    w.make_raid([c, bob], extra_members=["Dave", "Erin"])
    w.tick(1)
    for cl in (c, bob):
        set_mt(cl, "raid2")
        set_mt(cl, "raid3")
    w.tick(0.5)
    assert tank_names(c) == ["Bob", "Dave"] and tank_names(bob) == ["Bob", "Dave"]
    # the leader drags Dave on top: everyone with DisasterZone follows
    c.eval("ns.Tanks:Move(ns.Util.NormalizeName('Dave'), 1)")
    w.tick(2)
    assert tank_names(c) == ["Dave", "Bob"]
    assert tank_names(bob) == ["Dave", "Bob"]
    assert c.eval("return ns.LookTanks:Header():GetAttribute('nameList')") == "Dave,Bob"
    # an order from somebody who isn't the leader or an assistant is ignored
    bob.eval("ns.Tanks:SetOrder({ ns.Util.NormalizeName('Bob'), ns.Util.NormalizeName('Dave') })")
    w.tick(2)
    assert tank_names(c) == ["Dave", "Bob"]
    w.assert_no_errors()


@case
def the_plan_orders_them_and_one_click_sets_them():
    w, c = halo_raid()
    plan = """
        local K = ns.Util.NormalizeName
        ns.StrategyLive.PlanTanks = function() return {
            { key = K('Dave'), label = 'High King Maulgar', mark = 8 }, { key = K('Bob'), label = 'Blindeye the Seer', mark = 7 },
            { key = K('Zed'), label = 'Olm' } } end
        ns.Tanks:Rebuild()"""
    c.eval(plan)
    w.tick(0.2)
    # nobody set: the plan's tanks in the raid, greyed, and the leader's one-click button
    assert c.eval_py("local o = {} for i, p in ipairs(ns.Tanks:PlanInRaid()) do o[i] = p.name end return o") == ["Dave", "Bob"]
    g = c.eval_py("local o = {} for i, g in ipairs(ns.LookTanks:Ghosts()) do if g:IsShown() then "
                  "o[#o + 1] = { g.face.name:GetText(), g.face2.name:GetText(), g.face2.status:GetText() } end end return o")
    assert g == [["Dave", "Maulgar", "planned"], ["Bob", "Blindeye", "planned"]], g
    b = c.eval_py("local b = ns.LookTanks:PlanButton(); return { b:IsShown(), b:GetAttribute('type'), "
                  "b:GetAttribute('macrotext') }")
    assert b == [True, "macro", "/maintank Dave\n/maintank Bob"], b
    assert c.eval("return ns.LookTanks:PlanNote():GetText()") == "From the plan"
    # the click (the macro's lines): set in the plan's order, whatever the raid's order is
    c.eval("SetPartyAssignment('MAINTANK', 'raid2'); SetPartyAssignment('MAINTANK', 'raid4')")
    w.tick(0.2)
    assert tank_names(c) == ["Dave", "Bob"]
    assert c.eval("return ns.LookTanks:PlanButton():IsShown()") is False
    assert c.eval("local n = 0 for _, g in ipairs(ns.LookTanks:Ghosts()) do if g:IsShown() then n = n + 1 end end return n") == 0
    # blessings: with nobody set, the plan's tanks count as tanks
    c.eval("ClearPartyAssignment('MAINTANK', 'raid2'); ClearPartyAssignment('MAINTANK', 'raid4')")
    w.tick(0.2)
    tanks = c.eval_py("local o = {} for _, m in ipairs(ns.Blessings:ScanRoster(false)) do "
                      "if m.tank then o[#o + 1] = m.name end end return o")
    assert sorted(t.split("-")[0] for t in tanks) == ["Bob", "Dave"], tanks
    # a member sees the plan too, with a note instead of the button
    w2, m = halo_raid(lead=False)
    m.eval(plan)
    w2.tick(0.2)
    assert m.eval("return ns.LookTanks:PlanButton():IsShown()") is False
    assert m.eval("return ns.LookTanks:PlanNote():GetText()") == "From the plan · not set in game yet"
    w.assert_no_errors()


@case
def a_row_is_the_tank_and_the_mob_it_holds():
    w, c = halo_raid()
    c.eval(MOB_STUB)
    c.eval("SetPartyAssignment('MAINTANK', 'raid2'); SetPartyAssignment('MAINTANK', 'raid3')")
    w.tick(0.2)
    # (the mock's header makes no children: one row by hand, as the header's snippet would)
    c.eval("""
        local hd = ns.LookTanks:Header()
        local b = CreateFrame('Button', 'TestTankRow', hd, 'SecureUnitButtonTemplate')
        ns.LookTanks.InitRow('TestTankRow')
        b:SetAttribute('unit', 'raid2')
        b:Show()
        ns.LookTanks.RefreshRow(b)""")
    r = c.eval_py("local b = TestTankRow; return { b.face.name:GetText(), b.mob.face.name:GetText(), "
                  "b.mob.face.status:GetText(), b.face.mt:IsShown(), b.face.mtNo:GetText() }")
    assert r == ["Bob", "Maulgar", "88%", True, "1"], r
    # the halves are secure: the mob is the tank's target, the x the game's maintank action
    a = c.eval_py("local m, x = TestTankRow.mob, TestTankRow.x; return { m:GetAttribute('useparent-unit'), "
                  "m:GetAttribute('unitsuffix'), m:GetAttribute('*type1'), x:GetAttribute('type'), x:GetAttribute('action'), "
                  "x:GetAttribute('useparent-unit') }")
    assert a == [True, "target", "target", "maintank", "clear", True], a
    # the mob on another main tank: "on Carol", grey; on someone else: red, the ring lit
    c.eval("__MOB.on = 'raid3'; ns.LookTanks.RefreshRow(TestTankRow)")
    assert c.eval("return TestTankRow.mob.face.status:GetText()") == "on Carol"
    assert c.eval("return TestTankRow.mobData.lost") is None
    c.eval("__MOB.on = 'raid5'; ns.LookTanks.RefreshRow(TestTankRow)")
    assert c.eval("return TestTankRow.mob.face.status:GetText()") == "on Erin"
    assert c.eval("return TestTankRow.mobData.lost") is True
    assert c.eval_py("local r, g, b = TestTankRow.mob.face.ring.l:GetVertexColor(); return { r, g, b }") == [1, 0.25, 0.2]
    # no target: the plan's job, greyed
    c.eval("""
        __MOB.name = nil
        ns.StrategyLive.PlanTanks = function() return { { key = ns.Util.NormalizeName('Bob'), label = 'Blindeye the Seer', mark = 7 } } end
        ns.Tanks:Rebuild(); ns.LookTanks.RefreshRow(TestTankRow)""")
    r = c.eval_py("local f = TestTankRow.mob.face; return { f.name:GetText(), f.status:GetText(), TestTankRow.mob.host:GetAlpha() }")
    assert r == ["Blindeye", "planned", 0.55], r
    assert c.eval("return ns.LookTanks.ShortMob('High King Maulgar')") == "Maulgar"
    assert c.eval("return ns.LookTanks.ShortMob('Gruul the Dragonkiller')") == "Gruul"
    assert c.eval("return ns.LookTanks.ShortMob('Void Reaver')") == "Void Reaver"
    w.assert_no_errors()


@case
def the_x_shows_for_the_leader_out_of_combat_only():
    w, c = halo_raid()
    c.eval("SetPartyAssignment('MAINTANK', 'raid2')")
    w.tick(0.2)
    c.eval("""
        local b = CreateFrame('Button', 'TestTankRow', ns.LookTanks:Header(), 'SecureUnitButtonTemplate')
        ns.LookTanks.InitRow('TestTankRow'); b:SetAttribute('unit', 'raid2'); b:Show()""")
    c.eval("__MOCK.hover(TestTankRow)")
    assert c.eval("return TestTankRow.x:IsShown()") is True
    # a fight starts: the x goes before the lock
    c.eval("TestTankRow.x:Hide(); __MOCK.combat = true; __MOCK.fire('PLAYER_REGEN_DISABLED')")
    c.eval("__MOCK.hover(TestTankRow)")
    assert c.eval("return TestTankRow.x:IsShown()") is False
    c.eval("__MOCK.combat = false; __MOCK.fire('PLAYER_REGEN_ENABLED')")
    # no "+ Main tank" (the user's call: the raid's right-click menu, /maintank or the plan set them)
    assert c.eval("return ns.LookTanks.OpenPicker == nil and ns.LookTanks.Plus == nil") is True
    w.assert_no_errors()


@case
def raid_cells_wear_the_shield_and_the_target_marks():
    w, c = halo_raid()
    c.eval("""
        _G.__H = CreateFrame('Frame', nil, UIParent)
        _G.__F = ns.LookUnits:NewFace(__H, 'cell', 'group', 'left')
        __F:Apply(ns.Look.BY_KEY.halo)
        local d = ns.LookUnits.Fake('member', 5); d.mt = 2; d.leader = nil; __F:Set(d)""")
    # the shield and its number before the name (the name moves over)
    assert c.eval_py("return { __F.mt:IsShown(), __F.mtNo:GetText() }") == [True, "2"]
    assert c.eval_py("local _, _, _, x = __F.name:GetPoint(1); return x") == 29
    # my target: a white ring past the rim; pointing at it: a faint one; neither: none
    c.eval("local d = ns.LookUnits.Fake('member', 5); d.selected = true; __F:Set(d)")
    assert c.eval_py("local r, g, b, a = __F.selRing.l:GetVertexColor(); return { r, g, b, a, __F.selRing.l:IsShown() }") == [1, 1, 1, 0.95, True]
    c.eval("local d = ns.LookUnits.Fake('member', 5); __F:Set(d); __F:SetHover(true)")
    assert c.eval_py("local _, _, _, a = __F.selRing.l:GetVertexColor(); return a") == 0.4
    c.eval("__F:SetHover(false)")
    assert c.eval("return __F.selRing.l:IsShown()") is False
    # the other looks: a white outline past the edge light
    c.eval("__F:Apply(ns.Look.BY_KEY.flat); __F:SetTarget(true)")
    assert c.eval("return __F.sel[1]:IsShown() and not __F.selRing.l:IsShown()") is True
    # Classic: the game's own yellow frame
    c.eval("__F:Apply(ns.Look.BY_KEY.classic); __F:SetTarget(false); __F:SetHover(true)")
    assert c.eval_py("return { __F.cl.sel:IsShown(), __F.cl.sel:GetAlpha() }") == [True, 0.4]
    # the live raid frames: the cell of my target changes with PLAYER_TARGET_CHANGED
    c.eval("""
        local hd = ns.LookUnits:Header('raid')
        local b = CreateFrame('Button', 'TestRaidCell', hd, 'SecureUnitButtonTemplate')
        hd:SetAttribute('child1', b)
        hd:InitChild('TestRaidCell'); b:SetAttribute('unit', 'raid3'); b:Show()
        __MOCK.target = 'Carol'; __MOCK.fire('PLAYER_TARGET_CHANGED')""")
    assert c.eval("return TestRaidCell.face.targeted") is True
    c.eval("__MOCK.target = nil; __MOCK.fire('PLAYER_TARGET_CHANGED')")
    assert c.eval("return TestRaidCell.face.targeted") is False
    w.assert_no_errors()


@case
def a_leader_main_tank_player_frame_never_anchors_in_a_loop():
    # 2026-10-16 in game: PlaceMarks hung the crown off the shield, the next Set hung the shield off the crown
    # ("Cannot anchor to a region dependent on it", 17x on the player frame). The client checks at each SetPoint.
    w, c = halo_raid()
    for look in ("flat", "classic", "halo"):
        bad = c.eval_py("""
            _G.__H = CreateFrame('Frame', nil, UIParent)
            _G.__F = ns.LookUnits:NewFace(__H, 'big', 'units', 'left')
            __F:Apply(ns.Look.BY_KEY[...])
            local bad = {}
            local function on(r, target, seen)
                if r == target then return true end
                if not r or r == UIParent or seen[r] then return false end
                seen[r] = true
                for i = 1, r:GetNumPoints() do
                    local _, rel = r:GetPoint(i)
                    if on(rel, target, seen) then return true end
                end
                return false
            end
            for _, k in ipairs({ 'mt', 'mtNo', 'leader', 'level' }) do
                local r = __F[k]
                local sp = r.SetPoint
                r.SetPoint = function(self, p, rel, ...)
                    if type(rel) == 'table' and on(rel, self, {}) then bad[#bad + 1] = k end
                    return sp(self, p, rel, ...)
                end
            end
            local d = ns.LookUnits.Fake('player', 1); d.mt = 1; d.leader = true
            __F:Set(d); __F:Set(d)
            d.mt = nil; __F:Set(d); d.mt = 2; __F:Set(d)
            return { #bad, __F.mt:IsShown(), __F.leader:IsShown() }""", look)
        assert bad == [0, True, True], (look, bad)
    w.assert_no_errors()


@case
def boss_mods_and_the_threat_meter_know_my_flag():
    w, c = halo_raid()
    c.eval("ns.DB:SetSetting('bossmods.role', 'auto')")
    c.eval("SetPartyAssignment('MAINTANK', 'player')")
    w.tick(6)                                    # (the boss mods' role is read again after 5 s)
    assert c.eval("return ns.Tanks:IsMe()") is True
    assert c.eval("return ns.BossMod:MyRole()") == "tank"
    assert c.eval("return ns.Threat:TankView(nil)") is True
    w.assert_no_errors()


@case
def edit_layout_and_demo_show_made_up_tanks():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.look', 'halo')")
    c.relog()
    w.tick(2)
    assert c.eval("return ns.Layout:Item('group.tanks') ~= nil") is True
    c.eval("ns.LookTanks:ShowPreview(true)")
    r = c.eval_py("local o = {} for i, r in ipairs(ns.LookTanks:Preview().rows) do "
                  "o[i] = { r.face.name:GetText(), r.face2.name:GetText(), r.face2.status:GetText() } end return o")
    assert r == [["Victhar", "Maulgar", "88%"], ["Ironbark", "Blindeye", "on Dreadhex"], ["Moonwhisper", "Olm", "93%"]], r
    c.eval("ns.LookTanks:ShowPreview(false)")
    # (2026-10-17: the demo guild alone shows nothing on screen; the Demo page's Main tanks part does)
    c.eval("ns.Demo:SetEnabled(true)")
    w.tick(0.2)
    assert c.eval("return ns.LookTanks:Preview():IsShown()") is False
    c.eval("ns.Demo:SetOn('tanks', true)")
    w.tick(0.2)
    assert c.eval("return ns.LookTanks:Preview():IsShown()") is True
    c.eval("ns.Demo:SetOn('tanks', false)")
    w.tick(0.2)
    assert c.eval("return ns.LookTanks:Preview():IsShown()") is False
    # the switch hides the block
    c.eval("ns.DB:SetSetting('ui.group.tanks', false)")
    w.tick(0.2)
    assert c.eval("return ns.LookTanks:Header().dzVisibility") == "hide"
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

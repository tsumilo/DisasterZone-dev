#!/usr/bin/env python
"""The Dock (UI/LookDock.lua, Settings > UI > Action bars > Dock): every bottom bar on one grid in the part's look.
The game's bars are stood in for here (containers of 45 px buttons, as the client's), the Dock scales and anchors
the containers, the bags and the menu, the crown and the rail; the experience bar takes the block's width; Edit
layout has the dock instead of the bars; in combat it waits.

Run: luaenv\\Scripts\\python.exe tests\\uilook\\test_dock.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

from _common import case, run_all, solo  # noqa: E402

# The game's bottom bars, stood in for: each bar a frame with 12 containers holding a 45 px button (buttons know
# their container, as ActionBarMixin makes them); stance (3 forms), pet (hidden), bags and menu buttons.
FAKE_BARS = """
    local function Bar(name, prefix, n, shown, size)
        local bar = CreateFrame('Frame', name, UIParent)
        bar:SetSize(500, 50); bar:SetPoint('BOTTOM')
        for i = 1, n do
            local cont = CreateFrame('Frame', name .. 'ButtonContainer' .. i, bar)
            cont:SetSize(size or 45, size or 45); cont:SetPoint('LEFT', bar, 'LEFT', (i - 1) * 47, 0)
            local b = CreateFrame('CheckButton', prefix .. i, cont)
            b:SetSize(size or 45, size or 45); b:SetPoint('CENTER')
            b.container, b.index, b.bar = cont, i, bar
            b.icon = b:CreateTexture(); b.icon:SetAllPoints()
            b.HotKey = b:CreateFontString(nil, 'OVERLAY', 'GameFontHighlight'); b.HotKey:SetText(tostring(i))
            b.action = i
            function b:Update() end
            function b:UpdateUsable() end
        end
        function bar:UpdateGridLayout() end
        bar:SetShown(shown)
        return bar
    end
    Bar('MainActionBar', 'ActionButton', 12, true)
    Bar('MultiBarBottomLeft', 'MultiBarBottomLeftButton', 12, true)
    Bar('MultiBarBottomRight', 'MultiBarBottomRightButton', 12, true)
    Bar('MultiBarRight', 'MultiBarRightButton', 12, true)
    Bar('MultiBarLeft', 'MultiBarLeftButton', 12, false)
    local st = Bar('StanceBar', 'StanceButton', 10, true, 30)
    for i = 4, 10 do _G['StanceButton' .. i].container:Hide() end
    Bar('PetActionBar', 'PetActionButton', 10, false, 30)
    local bags = CreateFrame('Frame', 'BagsBar', UIParent); bags:SetSize(200, 40); bags:SetPoint('BOTTOMRIGHT')
    for _, n in ipairs({ 'MainMenuBarBackpackButton', 'CharacterBag0Slot', 'CharacterBag1Slot', 'CharacterBag2Slot',
                         'CharacterBag3Slot', 'KeyRingButton' }) do
        local b = CreateFrame('Button', n, bags); b:SetSize(40, 40); b:SetPoint('LEFT')
        b.Icon = b:CreateTexture(); b.Icon:SetTexture(133633)
    end
    local menu = CreateFrame('Frame', 'MicroMenuContainer', UIParent); menu:SetSize(300, 40); menu:SetPoint('BOTTOMRIGHT')
    for _, n in ipairs({ 'CharacterMicroButton', 'SpellbookMicroButton', 'TalentMicroButton', 'QuestLogMicroButton',
                         'SocialsMicroButton', 'GuildMicroButton', 'WorldMapMicroButton', 'LFGMicroButton',
                         'PVPMicroButton', 'MainMenuMicroButton', 'HelpMicroButton' }) do
        local b = CreateFrame('Button', n, menu); b:SetSize(28, 36); b:SetPoint('LEFT')
    end
"""


def docked(look="flat", size=36):
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.look', ...)", look)
    c.eval("ns.DB:SetSetting('ui.bars.size', ...)", size)
    c.relog()
    w.tick(2)
    c.eval("__MOCK.real_geometry = true")
    c.eval(FAKE_BARS)
    c.eval("ns.LookBars:Restyle(); ns.LookDock:Start(); ns.LookDock:Layout()")
    return w, c


# a frame's box in dock units, from the dock's top-left (y down)
BOX = """
    local f, d = ...
    f = type(f) == 'string' and _G[f] or f
    d = d or DisasterZoneDock
    local fe, de = f:GetEffectiveScale(), d:GetEffectiveScale()
    local x = (f:GetLeft() * fe - d:GetLeft() * de) / de
    local y = (d:GetTop() * de - f:GetTop() * fe) / de
    return { math.floor(x * 100 + 0.5) / 100, math.floor(y * 100 + 0.5) / 100,
             math.floor(f:GetWidth() * fe / de * 100 + 0.5) / 100, math.floor(f:GetHeight() * fe / de * 100 + 0.5) / 100 }
"""


def box(c, name, dock=None):
    return c.eval_py(BOX, name, dock) if dock is None else c.eval_py(BOX.replace("d = d or DisasterZoneDock", "d = _G[d]"), name, dock)


# ------------------------------------------------------------------------------------------------------------------
@case
def the_grid_follows_the_five_rules():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    g = c.eval_py("""
        local D = ns.LookDock
        local T = D.Tokens('flat', 36)
        return { T = T, g = D.Grid(T, { rows = 3, bags = 6, menu = 12, stance = 8, pet = 10 }),
                 g2 = D.Grid(T, { rows = 2, bags = 6, menu = 12, stance = 0, pet = 0, rep = true }),
                 big = D.Tokens('gilded', 42) }
    """)
    T, g, g2 = g["T"], g["g"], g["g2"]
    assert (T["S"], T["G"], T["P"], T["R"], T["s"]) == (36, 2, 5, 12, 27), T
    # 1: one 12 x 3 block
    assert g["block"]["w"] == 12 * 36 + 11 * 2 and g["block"]["h"] == 3 * 36 + 2 * 2, g["block"]
    assert g["rows"] == [g["block"]["y"], g["block"]["y"] + 38, g["block"]["y"] + 76]
    # 2: the wings are the block's height: bags 2 x 3 (the backpack at the bottom of the first column), menu 4 x 3
    ys = sorted({p[1] for p in g["bags"]})
    assert ys[0] == g["block"]["y"] and ys[-1] + 36 == g["block"]["y"] + g["block"]["h"], g["bags"]
    assert len({p[0] for p in g["menu"]}) == 4 and len({p[1] for p in g["menu"]}) == 3
    # two rows: the wings reflow (3 x 2, 6 x 2)
    assert len({p[0] for p in g2["bags"]}) == 3 and len({p[0] for p in g2["menu"]}) == 6
    # 3: stance from the block's left edge, pet ending at its right edge, one R over the block
    assert g["stance"][0][0] == g["block"]["x"]
    assert g["pet"][-1][0] + 27 == g["block"]["x"] + g["block"]["w"]
    assert g["stance"][0][1] + 27 + 12 == g["block"]["y"]
    # 4: the experience bar is the block's width, one G under the main row; reputation under it
    assert g["xp"]["x"] == g["block"]["x"] and g["xp"]["w"] == g["block"]["w"]
    assert g["xp"]["y"] == g["block"]["y"] + g["block"]["h"] + 2
    assert g2["rep"]["y"] > g2["xp"]["y"]
    # 5: a seam in the middle of each R
    assert g["seams"] == [5 + (2 * 36 + 2) + 6, g["block"]["x"] + g["block"]["w"] + 6], g["seams"]
    # every number grows with the size
    assert c.eval_py("return ns.LookDock.Tokens('gilded', 42)")["G"] == 5


@case
def the_bars_buttons_bags_and_menu_sit_on_the_grid():
    w, c = docked("flat", 36)
    g = c.eval_py("return ns.LookDock.grid")
    blk = g["block"]
    # action bar 1 is the bottom row, 3 the top; each button 36 dock units, G apart
    a1 = box(c, "ActionButton1")
    assert a1 == [blk["x"], g["rows"][2], 36, 36], (a1, blk)
    a12 = box(c, "ActionButton12")
    assert a12[0] == blk["x"] + 11 * 38 and a12[1] == g["rows"][2], a12
    assert box(c, "MultiBarBottomLeftButton1")[1] == g["rows"][1]
    assert box(c, "MultiBarBottomRightButton1")[1] == g["rows"][0]
    # the buttons stay the game's, on their own bars (only the containers moved)
    assert c.eval("return ActionButton1:GetParent() == MainActionBarButtonContainer1 and "
                  "MainActionBarButtonContainer1:GetParent() == MainActionBar") is True
    # bags: the backpack at the bottom of the first column, the block's height in all
    bp = box(c, "MainMenuBarBackpackButton")
    assert bp[0] == g["bags"][0][0] and bp[1] + bp[3] == blk["y"] + blk["h"] and bp[2] == 36, bp
    # the menu: squares on the grid, the DisasterZone tile last
    assert box(c, "CharacterMicroButton")[:3] == [g["menu"][0][0], blk["y"], 36]
    assert c.eval("return ns.LookBars.tiles[DisasterZoneDockMenuButton] ~= nil") is True
    assert c.eval("return #ns.LookDock.grid.menu") == 12
    # the crown: three stances (0.75 S) on the block's left edge
    st = box(c, "StanceButton1")
    assert st[0] == blk["x"] and st[2] == 27, st
    # the experience bar: the block's width, one gap under action bar 1
    xp = box(c, "DisasterZoneXPBar")
    assert xp[0] == blk["x"] and xp[1] == blk["y"] + blk["h"] + 2 and xp[2] == blk["w"], xp
    # bar 4 on the rail (bar 5 is off: one column)
    r1 = box(c, "MultiBarRightButton1", "DisasterZoneDockRail")
    assert r1[2] == 36 and r1[0] == 5, r1
    w.assert_no_errors()


@case
def edit_layout_moves_the_dock_not_the_bars():
    w, c = docked("halo")
    assert c.eval("return ns.Layout:Item('bars.dock') ~= nil and ns.Layout:Item('bars.rail') ~= nil") is True
    assert c.eval("return ns.Layout:Item('blizz:MainActionBar') == nil and ns.Layout:Item('bars.xp') == nil") is True
    c.eval("ns.Layout:RegisterBlizzard()")
    assert c.eval("return ns.Layout:Item('blizz:MainActionBar') == nil") is True
    # its size in Edit layout is the button size
    c.eval("ns.Layout:Item('bars.dock').scale.set(42 / 36)")
    assert c.eval("return ns.LookDock:Size()") == 42
    w.tick(0.2)
    assert box(c, "ActionButton1")[2] == 42
    w.assert_no_errors()


@case
def in_combat_it_waits_for_the_fight_to_end():
    w, c = docked("sigil")
    c.eval("__MOCK.in_combat = true; InCombatLockdown = function() return __MOCK.in_combat end")
    c.eval("ns.DB:SetSetting('ui.bars.size', 30)")
    assert c.eval("return ns.LookDock:Layout()") is False
    assert box(c, "ActionButton1")[2] == 36
    c.eval("__MOCK.in_combat = false; __MOCK.fire('PLAYER_REGEN_ENABLED')")
    assert box(c, "ActionButton1")[2] == 30
    w.assert_no_errors()


@case
def each_look_wears_its_state():
    for look in ("flat", "halo", "sigil", "slate", "gilded"):
        w, c = docked(look)
        st = c.eval_py("""
            local b = ActionButton3
            b:GetScript('OnEnter')(b)
            local s = ns.LookBars.skinned[b]
            local hover = { s.state.hover, s.ring:IsShown(), select(4, s.ring:GetVertexColor()) }
            b:GetScript('OnLeave')(b)
            b.GetChecked = function() return true end
            ns.LookBars:Status(b)
            return { hover = hover, active = s.state.active, plate = DisasterZoneDock.panel.bg:IsShown(),
                     floor = DisasterZoneDock.floor:IsShown(), under = s.under:IsShown(), hot = s.bezelHot:IsShown() }
        """)
        assert st["hover"][0] is True and st["active"] is True, (look, st)
        assert st["plate"] is (look != "halo") and st["floor"] is (look == "halo"), (look, st)
        assert st["under"] is (look == "slate") and st["hot"] is (look == "gilded"), (look, st)
        w.assert_no_errors()


@case
def turning_it_off_hands_the_bars_back_after_a_reload():
    w, c = docked("flat")
    c.eval("ns.DB:SetSetting('ui.bars.dock', false)")
    assert c.eval("return DisasterZoneDock:IsShown()") is False
    assert c.eval("return ns.Layout:Item('bars.dock') == nil and ns.Layout:Item('bars.xp') ~= nil") is True
    assert c.eval("return DisasterZoneXPBar:GetParent() == UIParent") is True
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

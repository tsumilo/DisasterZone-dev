#!/usr/bin/env python
"""Classic (UI/Look.lua, 2026-10-13): our layouts in the game's own art. The shared pieces (Look.GAME cuts, the
tooltip edge, the tiler, the 3-slice, the action button frame), "Use Classic everywhere", and each part in Classic.

Run: luaenv\\Scripts\\python.exe tests\\uilook\\test_classic.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

from _common import case, run_all, solo  # noqa: E402


def classic(**parts):
    """A client that reloaded with ui.look = classic."""
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.look', 'classic')")
    for p, k in parts.items():
        c.eval("ns.DB:SetSetting(...)", "ui.%s.look" % p, k)
    c.relog()
    w.tick(2)
    c.eval("__MOCK.real_geometry = true")
    return w, c


# ------------------------------------------------------------------------------------------------------------------
@case
def classic_is_a_look_with_the_games_art():
    w, c = classic()
    assert c.eval("return ns.Look:Key('units')") == "classic"
    assert c.eval("return ns.Look:For('bars').game") is True
    # a piece: the file and its cut as tex coords
    r = c.eval_py("""
        local t = UIParent:CreateTexture()
        local pw, ph = ns.Look:GameTex(t, 'well')
        local l, tp, _, b, r = t:GetTexCoord()     -- (UL x, UL y, LL x, LL y, UR x, ...)
        return { t:GetTexture(), pw, ph, l, r, tp, b }""")
    assert r[0].endswith("UI-MainMenuBar-Dwarf") and r[1:3] == [42, 42], r
    assert abs(r[3] - 42 / 256) < 1e-6 and abs(r[4] - 84 / 256) < 1e-6 and abs(r[5] - 148 / 256) < 1e-6, r
    w.assert_no_errors()


@case
def the_tooltip_edge_sits_on_the_frames_edge():
    w, c = classic()
    r = c.eval_py("""
        local f = CreateFrame('Frame', nil, UIParent); f:SetSize(100, 60); f:SetPoint('CENTER')
        local e = ns.Look:Edge9(f, 'tip'); e:Show(true)
        local tl, top = e.t[5], e.t[3]
        return { tl:GetWidth(), tl:GetLeft() - f:GetLeft(), top:GetRight() - top:GetLeft(), e.t[1]:GetTop() - e.t[1]:GetBottom(), top:IsShown() }""")
    # (16 px corners reaching 4 px out: the edges fill the rest)
    assert r[0] == 16 and r[1] == -4 and r[2] == 100 + 8 - 32 and r[3] == 60 + 8 - 32 and r[4] is True, r
    w.assert_no_errors()


@case
def a_tile_covers_an_area_with_whole_pieces_and_cuts_the_last():
    w, c = classic()
    r = c.eval_py("""
        local f = CreateFrame('Frame', nil, UIParent); f:SetSize(200, 50); f:SetPoint('CENTER')
        local t = ns.Look:GameTile(f, 'rail')
        t:Fill(f, 0, 0, 120, 11, 51, 11)
        local last = t.t[3]
        local l, _, _, _, r = last:GetTexCoord()
        return { t.n, last:GetWidth(), (r - l) * 256 }""")
    assert r[0] == 3 and r[1] == 18, r              # (51 + 51 + 18)
    assert abs(r[2] - 18) < 1e-6, r                 # (the last piece shows 18 of its 51 px)
    w.assert_no_errors()


@case
def a_three_slice_keeps_its_ends_and_mirrors():
    w, c = classic()
    r = c.eval_py("""
        local f = CreateFrame('Frame', nil, UIParent); f:SetSize(300, 50); f:SetPoint('TOPLEFT')
        local s = ns.Look:GameSlice3(f, 'tf_bars', 5, 8)
        s:Place(f, 10, 0, 200, 50)
        local a = { s.t[1]:GetWidth(), s.t[2]:GetWidth(), s.t[3]:GetWidth() }
        s:SetFlipX(true); s:Place(f, 10, 0, 200, 50)
        local l, _, _, _, r = s.t[1]:GetTexCoord()
        return { a[1], a[2], a[3], s.t[1]:GetWidth(), l > r }""")
    assert r[:3] == [5, 187, 8] and r[3] == 8 and r[4] is True, r
    w.assert_no_errors()


@case
def use_classic_everywhere_sets_every_picker():
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.units.look', 'halo'); ns.Look:UseEverywhere('classic')")
    got = c.eval_py("local G = function(p) return ns.DB:GetSetting(p) end; return { G('ui.look'), G('ui.units.look'), "
                    "G('meters.theme'), G('classbar.theme'), G('swing.theme'), G('shot.theme') }")
    assert got[0] == "classic" and got[1] == "inherit", got
    w.assert_no_errors()


@case
def the_cast_bar_wears_the_games_border_the_shield_and_the_flash():
    w, c = classic()
    c.eval("ns.LookCast:Preview('player', true)")
    r = c.eval_py("""
        local f = ns.LookCast:Bar('player')
        local b = f.cl.border.t[1]
        return { f:GetHeight(), b:IsShown(), f.cl.shield.t[1]:IsShown(), b:GetTexture(), f.spark:GetTexture() }""")
    assert r[0] == 34 and r[1] is True and r[2] is False, r
    assert r[3].endswith("UI-CastingBar-Border") and r[4].endswith("UI-CastingBar-Spark"), r
    # a cast that can't be interrupted: the shield frame, the icon in its box, grey
    c.eval("ns.LookCast:Preview('target', true)")
    r = c.eval_py("""
        local f = ns.LookCast:Bar('target')
        local rr, gg, bb = f.bar.fill:GetVertexColor()
        return { f.cl.shield.t[1]:IsShown(), f.cl.border.t[1]:IsShown(), f.lock:IsShown(), rr, gg, bb, f.icon.f:GetWidth() }""")
    assert r[0] is True and r[1] is False and r[2] is False, r
    assert abs(r[3] - 0.7) < 1e-6 and abs(r[4] - 0.7) < 1e-6 and r[6] == 18, r
    # a cast that lands: green and the flash, then it fades
    c.eval("ns.LookCast:Preview('player', false); local f = ns.LookCast:Bar('player'); "
           "ns.LookCast:Start(f, { name = 'Exorcism', icon = 1, dur = 1.5, done = 0.2 }); ns.LookCast:Stop(f)")
    r = c.eval_py("local f = ns.LookCast:Bar('player'); local rr, gg = f.bar.fill:GetVertexColor(); "
                  "return { rr, gg, f.cl.flash.t[2]:IsShown() }")
    assert r == [0, 1, True], r
    w.tick(1)
    assert c.eval("return ns.LookCast:Bar('player'):IsShown()") is False
    # back to another look: the game's frames hidden
    c.eval("ns.DB:SetSetting('ui.cast.look', 'flat')")
    assert c.eval("local f = ns.LookCast:Bar('player'); return f.cl.border.t[1]:IsShown() or f.cl.shield.t[1]:IsShown()") is False
    w.assert_no_errors()


@case
def unit_frames_wear_the_target_frame_the_dragon_for_a_boss_and_game_green():
    w, c = classic()
    c.eval("""
        _G.__H = CreateFrame('Frame', nil, UIParent); __H:SetPoint('TOPLEFT')
        _G.__T = ns.LookUnits:NewFace(__H, 'big', 'units', 'right')
        __T:Apply(ns.Look.BY_KEY.classic); __T:Set(ns.LookUnits.Fake('target'))
        _G.__H2 = CreateFrame('Frame', nil, UIParent); __H2:SetPoint('TOPLEFT')
        _G.__P = ns.LookUnits:NewFace(__H2, 'big', 'units', 'left')
        __P:Apply(ns.Look.BY_KEY.classic); __P:Set(ns.LookUnits.Fake('player'))""")
    r = c.eval_py("""
        local t = __T.cl.ring:GetTexture()
        local r, g, b = __T.hp.fill:GetVertexColor()
        return { __H:GetWidth(), __H:GetHeight(), t, r, g, b, __T.cl.nbg:IsShown(), __T.skull:IsShown() }""")
    assert r[0] == 220 and r[1] == 80, r
    assert r[2].endswith("UI-TargetingFrame-Elite") and r[3:6] == [0, 1, 0] and r[6] is True and r[7] is True, r
    # the player's: mirrored (the ring on the left of the rails), no name band
    r = c.eval_py("""
        local ringX = __P.cl.ring:GetLeft() - __H2:GetLeft()
        local railsX = __P.cl.rails.t[1]:GetLeft() - __H2:GetLeft()
        return { ringX, railsX, __P.cl.nbg:IsShown(), __P.cl.ring:GetTexture() }""")
    assert r[0] == 0 and r[1] > 50 and r[2] is False and r[3].endswith("UI-TargetingFrame"), r
    # a plain mob: the plain ring; back to Flat: the game's art hidden
    c.eval("local d = ns.LookUnits.Fake('target'); d.classif = 'normal'; d.level = 70; __T:Set(d)")
    assert c.eval("return __T.cl.ring:GetTexture()").endswith("UI-TargetingFrame")
    c.eval("__T:Apply(ns.Look.BY_KEY.flat)")
    assert c.eval("return __T.cl.art:IsShown() or __T.cl.nbg:IsShown()") is False
    assert c.eval("return __H:GetWidth()") == 214
    w.assert_no_errors()


@case
def raid_cells_are_the_games_cells_in_class_colours_and_frame_the_target():
    w, c = classic()
    r = c.eval_py("""
        local h = CreateFrame('Frame', nil, UIParent); h:SetPoint('TOPLEFT')
        local f = ns.LookUnits:NewFace(h, 'cell', 'group', 'left')
        f:Apply(ns.Look.BY_KEY.classic)
        local d = ns.LookUnits.Fake('member', 7); d.selected = true; d.far = nil
        f:Set(d)
        local rr, gg, bb = f.hp.fill:GetVertexColor()
        local cr, cg, cb = ns.Look.ClassColor('ROGUE')
        return { h:GetWidth(), h:GetHeight(), f.hp.fill:GetTexture(), math.abs(rr - cr) + math.abs(gg - cg) + math.abs(bb - cb),
                 f.cl.sel:IsShown(), f.name:GetText(), f.cl.ground:GetTexture() }""")
    assert r[0] == 86 and r[1] == 36 and r[2].endswith("Raid-Bar-Hp-Fill") and r[3] < 1e-6, r
    assert r[4] is True and r[5] == "Shadowmelder" and r[6].endswith("Raid-Bar-Hp-Bg"), r
    w.assert_no_errors()


@case
def action_buttons_wear_the_action_button_frame_and_the_games_states():
    w, c = classic()
    c.eval("""
        local b = CreateFrame('CheckButton', 'ActionButton1', UIParent)
        b:SetSize(36, 36); b:SetPoint('CENTER')
        b.icon = b:CreateTexture(); b.icon:SetAllPoints()
        b.NormalTexture = b:CreateTexture(); b.SlotBackground = b:CreateTexture()
        b.HotKey = b:CreateFontString(nil, 'OVERLAY', 'GameFontHighlight'); b.HotKey:SetText('1')
        b.PushedTexture = b:CreateTexture(); b.HighlightTexture = b:CreateTexture(); b.CheckedTexture = b:CreateTexture()
        b.cooldown = CreateFrame('Cooldown', nil, b)
        b.action = 1
        function b:Update() end
        function b:UpdateUsable() end
        ns.LookBars:Restyle()""")
    r = c.eval_py("""
        local s = ns.LookBars.skinned[ActionButton1]
        local b = ActionButton1
        return { s.qs:IsShown(), s.qs:GetTexture(), s.qs:GetRight() - s.qs:GetLeft(), b.PushedTexture:GetTexture(), b.PushedTexture:GetWidth(),
                 b.HighlightTexture:GetTexture(), b.CheckedTexture:GetTexture(), b.NormalTexture:GetAlpha() }""")
    assert r[0] is True and r[1].endswith("UI-Quickslot2") and r[2] == 66, r
    # (the depressed frame fills its file: the button's own size, not the frame's)
    assert r[3].endswith("UI-Quickslot-Depress") and r[4] == 36, r
    assert r[5].endswith("ButtonHilight-Square") and r[6].endswith("CheckButtonHilight") and r[7] == 0, r
    w.assert_no_errors()


@case
def the_dock_is_the_games_stride_with_room_for_the_gryphons_and_a_packed_menu():
    w, c = classic()
    T = c.eval_py("return ns.LookDock.Tokens('classic', 36)")
    assert T["G"] == 6 and T["P"] == 10 and T["S"] + T["G"] == 42, T
    g = c.eval_py("""
        local T = ns.LookDock.Tokens('classic', 36)
        T.side, T.menuW, T.menuG = 14, 28, 4
        local g = ns.LookDock.Grid(T, { rows = 3, bags = 6, menu = 12, stance = 3, pet = 0, pager = true })
        local g0 = ns.LookDock.Grid(ns.LookDock.Tokens('classic', 36), { rows = 3, bags = 6, menu = 12, stance = 3, pet = 0, pager = true })
        return { g.bags[1][1], g.menu[2][1] - g.menu[1][1], g.w - g0.w, g.menuW }""")
    # (bags 14 px further in, the menu 32 px apart (28 + 4), the dock 28 + the narrower menu)
    assert g[0] == 10 + 14 and g[1] == 32 and g[3] == 4 * 28 + 3 * 4, g
    w.assert_no_errors()


BAG_ITEMS = """
    local D = __MOCK.define_item
    D(28830, 'Dragonspine Trophy', 4, 'INVTYPE_TRINKET', 4, 0, 'Interface\\\\Icons\\\\INV_Misc_Bone_10')
    D(22838, 'Haste Potion', 1, 'INVTYPE_NON_EQUIP_IGNORE', 0, 1, 'Interface\\\\Icons\\\\INV_Potion_108')
    D(3300, "Rabbit's Foot", 0, 'INVTYPE_NON_EQUIP_IGNORE', 15, 0, 'Interface\\\\Icons\\\\INV_Misc_Foot_Kodo')
    __MOCK.bags[1] = { size = 16, slots = {} }
    __MOCK.set_bags({ { 0, 1, 28830, 1 }, { 0, 2, 22838, 10 }, { 0, 5, 3300, 2 } })
"""


@case
def the_bag_window_is_the_backpack_grown_with_a_carved_cell_per_slot():
    w, c = classic()
    c.eval(BAG_ITEMS)
    w.tick(0.2)
    c.eval("ns.LookBags:Open('bags'); ns.LookBags:Refresh('bags')")
    r = c.eval_py("""
        local f = ns.LookBags.windows.bags
        local n = 0
        for _, t in ipairs(f.cells) do if t:IsShown() then n = n + 1 end end
        local b = _G['DisasterZoneBagSlot3_1']                 -- (backpack slot 1)
        local cell = f.cells[1]
        local q1, q2, q3 = b.dzQ:GetVertexColor()
        return { n, f.clf.hl:GetTexture(), b:GetWidth(), b:GetLeft() - cell:GetLeft(), cell:GetTop() - b:GetTop(),
                 b.dzQ:IsShown(), q1, q2, q3, ns.LookBars.skinned[b].qs:IsShown(), f.close.cl.tex:IsShown(),
                 f.sort.cl.text:GetText() }""")
    assert r[0] == 32 and r[1].endswith("UI-BackpackBackground") and r[2] == 37, r
    assert r[3] == 2.5 and r[4] == 2, r                     # (the item 2.5, 2 inside its cell)
    assert r[5] is True and abs(r[6] - 0.64) < 0.01 and r[9] is False and r[10] is True and r[11] == "Sort", r
    # the footer's bag icons, slot count and money on one line, in the money box
    r = c.eval_py("""
        local f = ns.LookBags.windows.bags
        local _, ic = f.bagIcons[1]:GetCenter()
        local _, sl = f.slots:GetCenter()
        local _, mo = f.money:GetCenter()
        local _, ft = f.ft:GetCenter()
        return { ic, sl, mo, ft, f:GetBottom() }""")
    # (the texts hang on the row's centre line by their LEFT / RIGHT points; the harness has no text geometry)
    assert r[0] == r[3] and abs((r[3] - r[4]) - 20.5) < 0.01, r
    # Shelves: the headings carry the main bar's rail
    c.eval("ns.DB:SetSetting('ui.bags.layout', 'shelves'); ns.LookBags:Refresh('bags')")
    r = c.eval_py("local h = ns.LookBags.windows.bags.heads[1]; return { h.crail ~= nil and h.crail.n or 0, h.rule:IsShown() }")
    assert r[0] > 0 and r[1] is False, r
    # back to Flat: the backpack's art gone
    c.eval("ns.DB:SetSetting('ui.bags.look', 'flat'); ns.Look:SetApplied('bags', 'flat'); ns.LookBags:Refresh('bags')")
    r = c.eval_py("local f = ns.LookBags.windows.bags; return { f.clf.hl:IsShown(), f.cells[1]:IsShown(), f.close.cl.tex:IsShown() }")
    assert r == [False, False, False], r
    w.assert_no_errors()


@case
def the_minimap_is_the_games_own_with_our_drawer_knob_on_the_ring():
    w, c = classic()
    assert c.eval("return GetMinimapShape and GetMinimapShape()") == "ROUND"
    c.eval("ns.DB:SetSetting('ui.minimap.buttons', 'drawer')")
    r = c.eval_py("""
        local k = ns.LookMinimap:Knob()
        return { k:IsShown(), k.cl and k.cl.ring:GetTexture() or '', k:GetWidth() }""")
    assert r[0] is True and r[1].endswith("MiniMap-TrackingBorder") and r[2] == 31, r
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())

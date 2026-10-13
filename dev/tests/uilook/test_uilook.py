#!/usr/bin/env python
"""The game's UI in the addon's looks (Settings > UI, UI/Look.lua and its parts): Blizzard by default and untouched;
a look for everything or per part; unit / party / raid frames and cast bars replaced by our own (secure unit buttons,
secure group headers), action bars and the minimap reskinned; switching a replaced part to or from Blizzard asks for
a reload.

Run: luaenv\\Scripts\\python.exe tests\\uilook\\test_uilook.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

from _common import case, run_all, solo  # noqa: E402


def with_look(look="flat", **parts):
    """A client that reloaded with ui.look = look (and ui.<part>.look = ...)."""
    w, c = solo("Alice", class_file="ROGUE", guild_rank=0)
    c.eval("ns.DB:SetSetting('ui.look', ...)", look)
    for p, k in parts.items():
        c.eval("ns.DB:SetSetting(...)", "ui.%s.look" % p, k)
    c.relog()
    w.tick(2)
    c.eval("__MOCK.real_geometry = true")
    return w, c


# ------------------------------------------------------------------------------------------------------------------
@case
def blizzard_is_the_default_and_nothing_is_made():
    w, c = solo("Alice", class_file="ROGUE", guild_rank=0)
    assert c.eval("return ns.Look:Key('units')") == "blizzard"
    assert c.eval("return ns.LookUnits:Frame('player') == nil and ns.LookCast:Bar('player') == nil") is True
    assert c.eval("return DisasterZoneLookHidden == nil") is True        # (nothing retired)
    w.assert_no_errors()


@case
def a_look_makes_secure_unit_frames_that_target_and_open_the_menu():
    w, c = with_look("flat")
    for key, unit in [("player", "player"), ("target", "target"), ("tot", "targettarget"), ("focus", "focus"),
                      ("pet", "pet")]:
        r = c.eval_py("local b = ns.LookUnits:Frame(...); return { b:GetAttribute('unit'), b:GetAttribute('*type1'), "
                      "b:GetAttribute('*type2') }", key)
        assert r == [unit, "target", "togglemenu"], (key, r)
    assert c.eval_py("local b = ns.LookUnits:Frame('player'); return { b:GetWidth(), b:GetHeight() }") == [214, 42]
    # the group headers: party in a party, raid in a raid, made with their children's size
    p = c.eval_py("local h = ns.LookUnits:Header('party'); return { h:GetAttribute('showParty'), "
                  "h:GetAttribute('showRaid'), h:GetAttribute('template') }")
    assert p == [True, False, "SecureUnitButtonTemplate"], p
    r = c.eval_py("local h = ns.LookUnits:Header('raid'); return { h:GetAttribute('groupBy'), "
                  "h:GetAttribute('maxColumns'), h:GetAttribute('unitsPerColumn') }")
    assert r == ["GROUP", 8, 5], r
    assert "SetWidth(184)" in c.eval("return ns.LookUnits:Header('party'):GetAttribute('initialConfigFunction')")
    w.assert_no_errors()


@case
def the_face_writes_names_numbers_and_the_options():
    w, c = with_look("flat")
    c.eval("""
        _G.__H = CreateFrame('Frame', nil, UIParent)
        _G.__F = ns.LookUnits:NewFace(__H, 'big', 'units', 'left')
        __F:Apply(ns.Look.BY_KEY.flat)
        __F:Set(ns.LookUnits.Fake('player'))""")
    assert c.eval("return __F.value:GetText()") == "14.2k  84%"
    c.eval("ns.DB:SetSetting('ui.units.healthText', 'full'); __F:Set(__F.d)")
    assert c.eval("return __F.value:GetText()") == "14,212 / 16,840"
    c.eval("ns.DB:SetSetting('ui.units.healthText', 'pct'); __F:Set(__F.d)")
    assert c.eval("return __F.value:GetText()") == "84%"
    # the boss: a skull for its level, its name in Sigil's capitals
    c.eval("__F:Apply(ns.Look.BY_KEY.sigil); __F:Set(ns.LookUnits.Fake('target'))")
    assert c.eval("return __F.name:GetText()") == "VOID REAVER"
    assert c.eval("return __F.skull:IsShown()") is True
    # Slate: no portrait, the name in class colour
    c.eval("__F:Apply(ns.Look.BY_KEY.slate); __F:Set(ns.LookUnits.Fake('player'))")
    assert c.eval("return __F.portrait.f:IsShown()") is False
    # dead / offline
    c.eval("local d = ns.LookUnits.Fake('member', 12); __F:Apply(ns.Look.BY_KEY.flat); __F:Set(d)")
    assert c.eval("return __F.value:GetText()") == "Dead"
    w.assert_no_errors()


@case
def every_look_lays_every_kind_out():
    w, c = with_look("flat")
    for look in ["flat", "halo", "sigil", "slate", "gilded"]:
        for kind, fake in [("big", "player"), ("big", "target"), ("small", "tot"), ("cell", "member")]:
            c.eval("""
                local look, kind, fake = ...
                local h = CreateFrame('Frame', nil, UIParent)
                local f = ns.LookUnits:NewFace(h, kind, kind == 'cell' and 'group' or 'units', 'right')
                f.showAuras = fake == 'target'; f.showCombo = fake == 'target'
                f:Apply(ns.Look.BY_KEY[look]); f:Set(ns.LookUnits.Fake(fake, 3))""", look, kind, fake)
    w.assert_no_errors()


@case
def changing_the_look_restyles_and_blizzard_asks_for_a_reload():
    w, c = with_look("flat")
    c.eval("ns.DB:SetSetting('ui.look', 'halo')")
    w.tick(0.1)
    assert c.eval("return ns.Look:Key('units')") == "halo"
    assert c.eval("return ns.LookUnits:Frame('player'):GetHeight()") == 46
    assert c.eval("return ns.Look:NeedsReload('units')") is False
    c.eval("ns.DB:SetSetting('ui.look', 'blizzard')")
    w.tick(0.1)
    assert c.eval("return ns.Look:NeedsReload('units')") is True
    assert c.eval("return ns.Look:Key('units')") == "halo"       # (our frames stay until the reload)
    assert c.popup_text("DISASTERZONE_CONFIRM_uilookreload")
    # a part on its own look: only that one changes
    c.eval("ns.DB:SetSetting('ui.look', 'halo'); ns.DB:SetSetting('ui.cast.look', 'slate')")
    assert c.eval("return ns.Look:Key('cast')") == "slate" and c.eval("return ns.Look:Key('units')") == "halo"
    w.assert_no_errors()


@case
def cast_bars_show_a_cast_with_latency_and_a_lock():
    w, c = with_look("flat")
    c.eval("ns.LookCast:Preview('player', true)")
    assert c.eval("return ns.LookCast:Bar('player'):IsShown()") is True
    assert c.eval("return ns.LookCast:Bar('player').name:GetText()") == "Slam"
    c.eval("ns.LookCast:Preview('target', true)")
    assert c.eval("return ns.LookCast:Bar('target').lock:IsShown()") is True
    c.eval("ns.LookCast:Preview('player', false)")
    assert c.eval("return ns.LookCast:Bar('player'):IsShown()") is False
    # an interrupted cast: red, its word, then it fades
    c.eval("local f = ns.LookCast:Bar('player'); ns.LookCast:Start(f, { name = 'Slam', icon = 1, dur = 1.5, done = 0.2 }); "
           "ns.LookCast:Stop(f, 'Interrupted')")
    assert c.eval("return ns.LookCast:Bar('player').name:GetText()") == "Interrupted"
    w.tick(1.5)
    assert c.eval("return ns.LookCast:Bar('player'):IsShown()") is False
    w.assert_no_errors()


@case
def edit_layout_moves_ours_and_shows_them_with_made_up_units():
    w, c = with_look("flat")
    ids = c.eval_py("local o = {} for _, d in ipairs(ns.Layout:Items()) do o[#o + 1] = d.id end return o")
    for i in ["uf.player", "uf.target", "uf.tot", "uf.focus", "uf.pet", "group.party", "group.raid", "cast.player"]:
        assert i in ids, (i, ids)
    assert c.eval("return ns.Layout:Partner('uf.player')") == "uf.target"
    c.slash("/dz edit")
    w.tick(0.3)
    assert c.eval("local p = ns.LookUnits:PreviewFrame('raid'); return p and p:IsShown() or false") is True
    assert c.eval("return ns.Layout:Rect('uf.target') ~= nil") is True
    c.slash("/dz edit")
    w.tick(0.2)
    assert c.eval("local p = ns.LookUnits:PreviewFrame('raid'); return p:IsShown()") is False
    w.assert_no_errors()


@case
def action_buttons_are_reskinned_not_replaced():
    w, c = with_look("halo")
    c.eval("""
        local b = CreateFrame('CheckButton', 'ActionButton1', UIParent)
        b:SetSize(36, 36)
        b.icon = b:CreateTexture(); b.icon:SetAllPoints()
        b.NormalTexture = b:CreateTexture(); b.SlotBackground = b:CreateTexture()
        b.HotKey = b:CreateFontString(nil, 'OVERLAY', 'GameFontHighlight'); b.HotKey:SetText('1')
        b.Count = b:CreateFontString(nil, 'OVERLAY', 'GameFontHighlight')
        b.cooldown = CreateFrame('Cooldown', nil, b)
        b.action = 1
        function b:Update() end
        function b:UpdateUsable() end
        ns.LookBars:Restyle()""")
    assert c.eval("return ActionButton1.NormalTexture:GetAlpha()") == 0
    assert c.eval("return ActionButton1.SlotBackground:GetAlpha()") == 0
    assert c.eval("local p, rel, rp = ActionButton1.HotKey:GetPoint(1); return p .. '>' .. rp") == "BOTTOM>BOTTOM"
    # Halo cuts the icon round, again whenever the game sets a new one
    assert c.eval("return ns.LookBars.skinned[ActionButton1].round") is True
    # (round by the portrait disc as a mask on the icon, where the client has masks)
    assert c.eval("return ActionButton1.CreateMaskTexture == nil or ns.LookBars.skinned[ActionButton1].maskOn") is True
    # the bags and the menu: their art hidden, a tile of the look over each (the button stays the game's)
    c.eval("""
        local bag = CreateFrame('Button', 'CharacterBag0Slot', UIParent); bag:SetSize(30, 30)
        bag.Icon = bag:CreateTexture(); bag.Icon:SetTexture(133633)
        bag.art = bag:CreateTexture(); bag.art:SetTexture('Interface/Buttons/UI-Quickslot2')
        local mb = CreateFrame('Button', 'SpellbookMicroButton', UIParent); mb:SetSize(28, 36)
        mb.art = mb:CreateTexture(); mb.art:SetTexture('Interface/Buttons/UI-MicroButton-Spellbook-Up')
        ns.LookBars:Restyle()""")
    assert c.eval("return CharacterBag0Slot.art:GetAlpha()") == 0
    assert c.eval("return ns.LookBars.tiles[CharacterBag0Slot].shown") == 133633
    assert c.eval("return ns.LookBars.tiles[CharacterBag0Slot].icon.shape") == "round"
    # the menu: the addon's own flat glyphs (the book from the second sheet, art pack 8)
    assert "uiglyphs" in c.eval("return ns.LookBars.tiles[SpellbookMicroButton].glyph:GetTexture()")
    assert c.eval("return SpellbookMicroButton.art:GetAlpha()") == 0
    # the bag slots get the same face; the experience bar is ours
    assert c.eval("return DisasterZoneXPBar ~= nil") is True
    # back to Blizzard: after a reload (the game's status bars were retired)
    c.eval("ns.DB:SetSetting('ui.bars.look', 'blizzard')")
    assert c.eval("return ns.Look:NeedsReload('bars')") is True
    w.assert_no_errors()


@case
def the_minimap_goes_square_and_says_so():
    w, c = with_look("flat")
    assert c.eval("return GetMinimapShape and GetMinimapShape()") == "SQUARE"
    c.eval("ns.DB:SetSetting('ui.minimap.look', 'gilded')")
    assert c.eval("return GetMinimapShape()") == "ROUND"
    c.eval("ns.DB:SetSetting('ui.minimap.shape', 'square')")
    assert c.eval("return GetMinimapShape()") == "SQUARE"
    w.assert_no_errors()


@case
def demo_mode_shows_a_made_up_party():
    w, c = with_look("sigil")
    c.slash("/dz demo on")
    w.tick(1)
    assert c.eval("local p = ns.LookUnits:PreviewFrame('party'); return p and p:IsShown() or false") is True
    c.slash("/dz demo off")
    w.tick(1)
    assert c.eval("return ns.LookUnits:PreviewFrame('party'):IsShown()") is False
    w.assert_no_errors()


@case
def settings_ui_has_every_part():
    w, c = solo("Alice", class_file="ROGUE", guild_rank=0)
    c.eval("ns.MainFrame:Open('settings'); ns.SettingsUI:SelectSection('ui')")
    w.tick(0.3)
    texts = c.eval_py("local o = {} local function walk(f) for _, r in ipairs({ f:GetRegions() }) do "
                      "if r.GetText and r:GetText() then o[#o + 1] = r:GetText() end end "
                      "for _, ch in ipairs({ f:GetChildren() }) do walk(ch) end end "
                      "walk(ns.SettingsUI.sections.ui) return o")
    for t in ["Look for everything", "Unit frames", "Party and raid", "Cast bars", "Action bars", "Minimap", "Flat",
              "Gilded"]:
        assert t in texts, (t, texts)
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

#!/usr/bin/env python
"""UI profiles (Core/Profiles.lua, UI/ProfilesUI.lua), built 2026-10-15 from the mockup's direction A "Profile cards":
Layout's profiles hold looks, layout and key binds, each part on or off per profile; changes save into the profile in
use by themselves; a spec gets a profile and a respec switches to it (a spec without one keeps what you have); looks
that replace whole frames ask for a reload in the toast; a fight holds the switch until it ends; sharing sends the
whole profile and the receiver picks the parts; Settings > Profiles shows the cards; demo mode's profiles are made up.

Run: luaenv\\Scripts\\python.exe tests\\profiles\\test_profiles.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "boot-ui"))
sys.path.insert(0, os.path.join(HERE, "..", "uilook"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "tools"))

import _common  # noqa: E402
from _common import case, run_all, solo  # noqa: E402

_n = len(_common._CASES)
from test_dock import FAKE_BARS  # noqa: E402
del _common._CASES[_n:]


def boot(talents=(41, 20, 0)):
    w, c = solo("Alice", class_file="PALADIN", guild_rank=0, talents=talents)
    c.eval(FAKE_BARS)
    c.eval("__MOCK.bindings = { { 'ACTIONBUTTON1', '1' }, { 'ACTIONBUTTON2', '2' } }")
    return w, c


def look(c):
    return c.eval("return ns.DB:GetSetting('ui.look')")


def keys(c, cmd):
    return c.eval_py("return { GetBindingKey(...) }", cmd) or []


def new(c, name, look_key=None, parts=None):
    """A profile made while look_key is worn; parts: { looks, layout, keys } overrides."""
    if look_key:
        c.eval("ns.DB:SetSetting('ui.look', ...)", look_key)
    pid = c.eval("return ns.Profiles:New(...)", name)
    for part, on in (parts or {}).items():
        c.eval("ns.Profiles:SetPart(...)", pid, part, on)
    return pid


def toast(c):
    return c.eval_py("""local t = ns.UI:GetToast('profile'); if not (t and t:IsShown()) then return nil end
        local o = t.opts or t.o or {}
        return { title = t.title and t.title:GetText() or o.title, kicker = t.kicker and t.kicker:GetText() or o.kicker,
                 text = t.text and t.text:GetText() or o.text, buttons = o.buttons and #o.buttons or 0 }""")


@case
def old_profiles_hold_a_layout_and_new_ones_all_three():
    w, c = boot()
    assert c.eval_py("return ns.Profiles.Parts(ns.Layout:Profile('default'))") == {"layout": True}
    pid = new(c, "Raid healer", "halo")
    assert c.eval_py("return ns.Profiles.Parts(ns.Layout:Profile(...))", pid) == {"looks": True, "layout": True, "keys": True}
    assert c.eval("return ns.Layout:Profile(...).looks['ui.look']", pid) == "halo"
    assert c.eval("return ns.Layout:Profile(...).keys.ACTIONBUTTON1[1]", pid) == "1"


@case
def using_a_profile_puts_its_looks_and_keys_on():
    w, c = boot()
    healer = new(c, "Raid healer", "halo")
    c.eval("SetBinding('F', 'ACTIONBUTTON3')")
    quest = new(c, "Questing", "flat")
    assert c.eval("return ns.Profiles:InUseId()") == "default"
    c.eval("ns.Profiles:Use(...)", healer)
    assert look(c) == "halo"
    assert keys(c, "ACTIONBUTTON3") == []
    assert c.eval("return ns.Profiles:InUseId()") == healer
    c.eval("ns.Profiles:Use(...)", quest)
    assert look(c) == "flat"
    assert keys(c, "ACTIONBUTTON3") == ["F"]
    assert c.eval("return ns.Layout:ActiveId()") == quest
    w.assert_no_errors()


@case
def a_part_switched_off_is_left_as_it_is():
    w, c = boot()
    healer = new(c, "Raid healer", "halo")
    tank = new(c, "Tanking", "slate", {"looks": False, "layout": False})
    c.eval("ns.Profiles:Use(...)", healer)
    c.eval("ns.Profiles:Use(...)", tank)
    assert look(c) == "halo"                                     # (Tanking holds no looks)
    assert c.eval("return ns.Layout:ActiveId()") == healer       # (nor a layout: the frames stay Raid healer's)
    assert c.eval("return ns.Profiles:InUseId()") == tank


@case
def changes_save_into_the_profile_in_use():
    w, c = boot()
    healer = new(c, "Raid healer", "halo")
    c.eval("ns.Profiles:Use(...)", healer)
    c.eval("ns.DB:SetSetting('ui.look', 'gilded')")
    w.tick(1)
    assert c.eval("return ns.Layout:Profile(...).looks['ui.look']", healer) == "gilded"
    # a key bound in Key binds saves into it when Key binds closes
    c.slash("/dz keys")
    w.tick(0.6)
    c.eval("local bd = ns.KeyBinds:Binder(ActionButton4); bd:GetScript('OnEnter')(bd)")
    c.eval("DisasterZoneKeyBinds:GetScript('OnKeyDown')(DisasterZoneKeyBinds, 'G')")
    c.eval("ns.KeyBinds:Close(true)")
    assert c.eval("return ns.Layout:Profile(...).keys.ACTIONBUTTON4[1]", healer) == "G"
    # the game's own key bindings save too
    c.eval("SetBinding('H', 'ACTIONBUTTON5')")
    c.fire("UPDATE_BINDINGS")
    w.tick(1)
    assert c.eval("return ns.Layout:Profile(...).keys.ACTIONBUTTON5[1]", healer) == "H"
    # a profile that holds no looks saves none
    tank = new(c, "Tanking", None, {"looks": False})
    c.eval("ns.Profiles:Use(...)", tank)
    c.eval("ns.DB:SetSetting('ui.look', 'flat')")
    w.tick(1)
    assert c.eval("return ns.Layout:Profile(...).looks['ui.look']", healer) == "gilded"


@case
def a_respec_switches_to_the_specs_profile():
    w, c = boot(talents=(41, 20, 0))
    w.tick(3)                                                   # (the spec at login is noted)
    healer = new(c, "Raid healer", "halo")
    tank = new(c, "Tanking", "slate")
    c.eval("ns.Profiles:Use(...)", healer)
    c.eval("ns.Profiles:SetSpec('Holy', ...)", healer)
    c.eval("ns.Profiles:SetSpec('Protection', ...)", tank)
    assert c.eval_py("local o = {} for _, s in ipairs(ns.Profiles:SpecsOf(...)) do o[#o + 1] = s.label end return o", tank) == ["Protection"]
    c.eval("__MOCK.talents = { 0, 41, 20 }")
    c.fire("PLAYER_TALENT_UPDATE")
    w.tick(1.5)
    assert c.eval("return ns.Profiles:InUseId()") == tank
    assert look(c) == "slate"
    t = toast(c)
    assert t and "Protection" in (t["kicker"] or ""), t
    # a spec without a profile keeps what you have
    c.eval("__MOCK.talents = { 0, 0, 41 }")
    c.fire("PLAYER_TALENT_UPDATE")
    w.tick(1.5)
    assert c.eval("return ns.Profiles:InUseId()") == tank
    # a spec has one profile: giving it to another takes it from the first
    c.eval("ns.Profiles:SetSpec('Protection', ...)", healer)
    assert c.eval("return #ns.Profiles:SpecsOf(...)", tank) == 0


@case
def looks_that_replace_frames_ask_for_a_reload_in_the_toast():
    w, c = boot()
    flat = new(c, "Flat", "flat")
    c.eval("ns.DB:SetSetting('ui.look', 'blizzard')")
    c.eval("ns.Look:SetApplied('units', 'blizzard'); ns.Popup:HideAll()")
    c.eval("ns.Profiles:Use(...)", flat)
    t = toast(c)
    assert t and t["buttons"] == 2, t
    assert "reload" in (t["text"] or ""), t
    # (Look's own reload pop-up stays quiet: the toast asked)
    assert c.eval("return ns.Popup:FindVisible('DISASTERZONE_CONFIRM_uilookreload') == nil") is True


@case
def a_fight_holds_the_switch_until_it_ends():
    w, c = boot()
    healer = new(c, "Raid healer", "halo")
    c.eval("ns.DB:SetSetting('ui.look', 'flat')")
    c.set_combat(True)
    c.eval("ns.Profiles:Use(...)", healer)
    assert look(c) == "flat"
    assert c.eval("return ns.Profiles:Pending().id") == healer
    c.set_combat(False)
    w.tick(1)
    assert look(c) == "halo"
    assert c.eval("return ns.Profiles:InUseId()") == healer


@case
def a_shared_profile_carries_its_parts_looks_and_keys():
    w, c = boot()
    pid = new(c, "Raid healer", "halo", {"keys": False})
    data = c.eval_py("return ns.Layout:Export(...)", pid)
    assert data["pa"] == {"looks": True, "layout": True}
    assert data["lk"]["ui.look"] == "halo"
    nid = c.eval("return ns.Layout:Import(ns.Layout:Export(...), 'Bob-Realm')", pid)
    assert c.eval_py("return ns.Profiles.Parts(ns.Layout:Profile(...))", nid) == {"looks": True, "layout": True}
    assert c.eval("return ns.Layout:Profile(...).looks['ui.look']", nid) == "halo"
    assert c.eval("return ns.Layout:Profile(...).name", nid).startswith("Raid healer (Bob")


@case
def settings_shows_the_cards_and_the_open_profile():
    w, c = boot()
    healer = new(c, "Raid healer", "halo")
    c.eval("ns.MainFrame:Open('settings'); ns.SettingsUI:SelectSection('layout')")
    w.tick(0.3)
    # (Default, Raid healer, and the New card)
    assert c.eval("local n = 0 for _, k in ipairs(ns.ProfilesUI.block.cards) do if k:IsShown() then n = n + 1 end end return n") == 2
    assert c.eval("return ns.ProfilesUI:Selected()") == "default"
    c.eval("ns.ProfilesUI.block.cards[2]:Click()")
    assert c.eval("return ns.ProfilesUI:Selected()") == healer
    d = "ns.ProfilesUI.block.detail"
    assert c.eval(f"return {d}.useNow:IsShown()") is True
    assert c.eval(f"return {d}.rows.looks.desc:GetText()").startswith("Halo")
    # a part's switch
    c.eval(f"{d}.rows.keys.sw:Click()")
    assert c.eval("return ns.Profiles:Has(ns.Layout:Profile(...), 'keys')", healer) is False
    assert c.eval(f"return {d}.rows.keys.desc:GetText()").startswith("Off")
    # a spec
    c.eval(f"for _, b in ipairs({d}.specBtns) do if b.spec == 'Holy' then b:Click() end end")
    assert c.eval("return ns.Profiles:ProfileOfSpec('Holy')") == healer
    assert c.eval("return ns.ProfilesUI.block.cards[2].specs[1]:IsShown()") is True
    # Use now
    c.eval(f"{d}.useNow:Click()")
    assert c.eval("return ns.Profiles:InUseId()") == healer
    assert c.eval(f"return {d}.use:IsShown()") is True
    w.assert_no_errors()


@case
def the_bars_show_the_profile_in_use():
    w, c = boot()
    healer = new(c, "Raid healer", "halo")
    c.eval("ns.Profiles:Use(...)", healer)
    c.slash("/dz edit")
    w.tick(0.4)
    assert "Raid healer" in c.eval("return ns.EditMode:GetBar().b.profile.fs:GetText()")
    c.slash("/dz keys")
    w.tick(0.4)
    assert "Raid healer" in c.eval("return DisasterZoneKeyBindsBar.b.profile.fs:GetText()")


@case
def demo_mode_shows_made_up_profiles():
    w, c = boot()
    c.eval("ns.Demo:SetEnabled(true)")
    names = c.eval_py("local o = {} for _, p in ipairs(ns.Profiles:List()) do o[#o + 1] = p.name end return o")
    assert names == ["Default", "Raid healer", "Tanking", "Questing"], names
    assert c.eval("return ns.Profiles:ProfileOfSpec('Holy')") == "dhealer"
    c.eval("ns.Profiles:UseDemo('dtank')")
    assert c.eval("return ns.Profiles:CurrentId()") == "dtank"
    assert c.eval("return ns.Profiles:InUseId()") == "default"
    assert look(c) in (None, "blizzard")
    c.eval("ns.Demo:SetEnabled(false)")
    assert c.eval("return ns.Profiles.demo == nil") is True


@case
def a_profile_goes_to_a_character_of_mine():
    w, c = boot()
    me = c.eval("return ns.Util.PlayerKey()")
    realm = me.split("-", 1)[1]
    alt = "Mendalot-" + realm
    c.eval("ns.Layout.Store().seen[...] = { c = 'PRIEST' }", alt)
    chars = c.eval_py("local o = {} for _, ch in ipairs(ns.Profiles:MyCharacters()) do o[#o + 1] = ch.key end return o")
    assert chars[0] == me and alt in chars, chars
    healer = new(c, "Raid healer", "halo")
    c.eval("ns.DB:SetSetting('ui.look', 'flat')")
    # the alt gets it: nothing changes here, its next login wears it
    c.eval("ns.Profiles:SetCharacter(...)", alt, healer)
    assert c.eval("return ns.Profiles:ProfileOfChar(...)", alt) == healer
    assert c.eval("return ns.Profiles:InUseId()") == "default"
    assert look(c) == "flat"
    assert c.eval("return ns.Layout.Store().chars[...]", alt) == healer
    # my own: it comes on now
    c.eval("ns.Profiles:SetCharacter(...)", me, healer)
    assert look(c) == "halo"
    names = c.eval_py("local o = {} for _, ch in ipairs(ns.Profiles:CharsOf(...)) do o[#o + 1] = ch.key end return o", healer)
    assert sorted(names) == sorted([me, alt]), names
    # back to Default
    c.eval("ns.Profiles:SetCharacter(...)", alt, None)
    assert c.eval("return ns.Profiles:ProfileOfChar(...)", alt) == "default"


@case
def each_character_puts_its_own_profile_on_at_login():
    w, c = boot()
    healer = new(c, "Raid healer", "halo")
    c.eval("ns.Profiles:Use(...)", healer)
    # (another character logged in meanwhile and wore its own looks and keys)
    c.eval("ns.DB:SetSetting('ui.look', 'gilded'); SetBinding('Z', 'ACTIONBUTTON1')")
    c.eval("ns.Profiles.demo = nil; local P = ns.Profiles; P.PutOnAtLogin(P)")
    assert look(c) == "halo"
    assert keys(c, "ACTIONBUTTON1") == ["1"]


@case
def the_meters_look_and_places_go_with_the_profile():
    # feedback #45: the meters' options (look, when they show, which are on, the threat warning) save into the profile in
    # use and come back with it; a profile saved before 1.5.5 (no meter options) leaves them alone; the meters' places
    # are the character's own at login (one account-wide setting: the last character's were left on)
    w, c = boot()
    healer = new(c, "Raid healer", "halo")
    c.eval("ns.Profiles:Use(...)", healer)
    c.eval("ns.DB:SetSetting('meters.barColor', 'role'); ns.DB:SetSetting('meters.size', 'large'); "
           "ns.DB:SetSetting('meters.thr', true); ns.DB:SetSetting('meters.tankView', 'always')")
    w.tick(1)
    snap = c.eval_py("return ns.Layout:Profile(...).looks", healer)
    assert snap["meters.barColor"] == "role" and snap["meters.size"] == "large" and snap["meters.thr"] is True, snap
    assert snap["meters.tankView"] == "always" and snap["meters.inProfile"] is True, snap
    assert "meters.keep" not in snap                                  # (the meter's data: not a profile's)
    tank = new(c, "Tanking", "flat")
    c.eval("ns.Profiles:Use(...)", tank)
    c.eval("ns.DB:SetSetting('meters.barColor', 'one'); ns.DB:SetSetting('meters.tankView', 'never')")
    w.tick(1)
    c.eval("ns.Profiles:Use(...)", healer)
    w.tick(0.5)
    assert c.eval("return ns.DB:GetSetting('meters.barColor')") == "role"
    assert c.eval("return ns.DB:GetSetting('meters.tankView')") == "always"
    # an older snapshot: its looks go on, the meter options stay as they are
    c.eval("local p = ns.Layout:Profile(...); for k in pairs(p.looks) do if k:find('^meters%.') and k ~= 'meters.theme' then "
           "p.looks[k] = nil end end", tank)
    c.eval("ns.Profiles:Use(...)", tank)
    w.tick(0.5)
    assert look(c) == "flat"
    assert c.eval("return ns.DB:GetSetting('meters.barColor')") == "role"
    # the meters' places at login: the character's layout, not what the last character left
    c.eval("ns.MeterPanels:ResetLayout(); local L = ns.MeterPanels.Layout(); L.stacks[1].x, L.stacks[1].y = 111, 222; "
           "ns.Layout:Capture()")
    c.eval("local L = ns.MeterPanels.Layout(); L.stacks[1].x, L.stacks[1].y = 999, 888")
    c.eval("ns.Profiles.demo = nil; local P = ns.Profiles; P.PutOnAtLogin(P)")
    assert c.eval_py("local s = ns.DB:GetSetting('meters.layout').stacks[1]; return { s.x, s.y }") == [111, 222]
    w.assert_no_errors()


@case
def the_card_lists_my_characters():
    w, c = boot()
    me = c.eval("return ns.Util.PlayerKey()")
    alt = "Mendalot-" + me.split("-", 1)[1]
    c.eval("ns.Layout.Store().seen[...] = { c = 'PRIEST' }", alt)
    # (a guild alt never seen with the addon: its class from the guild roster)
    c.eval("local realm = ...; ns.Guild.GetMyCharacters = function() return { 'Ussyp-' .. realm } end; "
           "local gc = ns.Guild.GetClass; ns.Guild.GetClass = function(self, k) if k:find('^Ussyp') then return 'MAGE' end return gc(self, k) end",
           me.split("-", 1)[1])
    ussyp = [ch for ch in c.eval_py("return ns.Profiles:MyCharacters()") if ch["key"].startswith("Ussyp")]
    assert ussyp and ussyp[0].get("class") == "MAGE", ussyp
    healer = new(c, "Raid healer", "halo")
    c.eval("ns.MainFrame:Open('settings'); ns.SettingsUI:SelectSection('layout'); ns.ProfilesUI:Select(...)", healer)
    d = "ns.ProfilesUI.block.detail"
    assert c.eval(f"local n = 0 for _, b in ipairs({d}.charBtns) do if b:IsShown() then n = n + 1 end end return n") == 3
    c.eval(f"for _, b in ipairs({d}.charBtns) do if b.key == ... then b:Click() end end", alt)
    assert c.eval("return ns.Profiles:ProfileOfChar(...)", alt) == healer
    assert c.eval(f"for _, b in ipairs({d}.charBtns) do if b.key == ... then return b.on end end", alt) is True
    w.assert_no_errors()


if __name__ == "__main__":
    sys.exit(run_all())

"""Settings tab: every checkbox and dropdown writes its setting (and follows external changes), the minimap
toggle, demo / simulate / demo-roll buttons, the Loot Council section (Addendum E §30: a read-only summary for
everyone, "Edit council..." for the Guild Master, which opens the picker; the Guild Info text is never touched),
the Blizzard Settings entry.

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_settings.py
"""
from _common import (case, run_all, toc_version, solo, no_errors, World, Client, install_helpers, menu_texts, printed_since,
                     strip_codes, tt_lines, gm_pick, GUILD_INFO_SPY, guild_info_calls)

CHECKS = [
    ("Boss drop panel (Loot Council)", "alerts.councilPanel", False),
    ('"On your BiS list!" toast', "alerts.personalToast", False),
    ("Play a sound with drop alerts", "alerts.sound", False),
    ("Glow loot buttons for your BiS items", "alerts.glow", False),
    ("Chat message when your BiS item drops", "alerts.chat", False),
    ("BiS badges on the loot window", "alerts.lootBadges", False),
    ("Announce rolls and winners in raid chat", "roll.announce", False),
    ("Show the Roll / Pass popup", "roll.popup", False),
    ("Show DisasterZone lines on item tooltips", "tooltip.enabled", False),
    ("Council: list who wants the item", "tooltip.council", False),
    ("Debug messages in chat", "debug", False),
]

# first option text -> (setting path, [(option text, stored value)])
DROPDOWNS = {
    "Attach to loot window when open": ("dropPanelMode", [("Always floating", "floating"),
                                                          ("Attach to loot window when open", "auto")]),
    "Epic": ("qualityThreshold", [("Rare", 3), ("Epic", 4)]),
    "Raid": ("announceChannel", [("Raid Warning", "RAID_WARNING"), ("Raid", "RAID")]),
    "15 seconds": ("roll.duration", [("15 seconds", 15), ("20 seconds", 20), ("45 seconds", 45),
                                     ("60 seconds", 60), ("30 seconds", 30)]),
    "3": ("tooltip.maxNames", [("3", 3), ("8", 8), ("12", 12), ("5", 5)]),
}

DD_LIST = r"""
function T_settings() return ns.MainFrame:GetPanel("settings") end
function T_dropdowns(root)
  local out = {}
  for _, f in ipairs(T_dropdown_list(root)) do
    local m = T_menu(f)
    local first = m and m.children[1] and m.children[1].text or ""
    out[#out + 1] = { f, first, f:GetText() or "", f:IsVisible() and 1 or 0 }
  end
  return out
end
function T_dd_by_first(root, first)
  for _, e in ipairs(T_dropdowns(root)) do if e[2] == first then return e[1] end end
end
function T_last_popup_text()
  local log = __MOCK.popup_log
  return log and log[#log] and log[#log].text
end
"""


def open_settings(c):
    c.slash("/dz settings")
    c.world.tick(0.5)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "settings"


def setting(c, path):
    return c.eval("return ns.DB:GetSetting(...)", path)


def checkbox(c, label):
    cb = c.eval("return T_checkbox(T_settings(), ...)", label)
    assert cb is not None, "no checkbox %r" % label
    return cb


def checked(c, cb):
    return bool(c.eval("local b = ...; return b:GetChecked()", cb))


def settings_client(**kw):
    w, c = solo(kw.pop("name", "Alice"), tick=3, **kw)
    install_helpers(c)
    c.eval(DD_LIST)
    open_settings(c)
    return w, c


# ------------------------------------------------------------------------------------------------------------------
@case
def every_checkbox_writes_its_setting_and_follows_changes():
    w, c = settings_client(guild_rank=3)
    for label, path, _ in CHECKS:
        cb = checkbox(c, label)
        before = setting(c, path)
        assert checked(c, cb) == bool(before), (label, before)
        c.click(cb)
        w.tick(0.2)
        assert setting(c, path) == (not before), "%s did not toggle %s" % (label, path)
        assert checked(c, cb) == (not before)
        c.click(cb)
        w.tick(0.2)
        assert setting(c, path) == before, (label, path)
    # external change (slash command) is reflected by the checkbox after the debounced refresh
    cb = checkbox(c, "Debug messages in chat")
    c.slash("/dz debug")
    w.tick(0.3)
    assert setting(c, "debug") is True and checked(c, cb) is True
    c.slash("/dz debug")
    w.tick(0.3)
    assert checked(c, cb) is False
    # persisted across relog
    c.click(checkbox(c, "Play a sound with drop alerts"))
    c.relog()
    w.tick(2)
    assert c.eval("return DisasterZoneDB.settings.alerts.sound") is False
    no_errors(w)


@case
def every_dropdown_writes_its_setting():
    w, c = settings_client(guild_rank=3)
    dds = c.eval_py("local o = {} for i, e in ipairs(T_dropdowns(T_settings())) do o[i] = { e[2], e[3], e[4] } end return o")
    firsts = [d[0] for d in dds]
    for first in DROPDOWNS:
        assert first in firsts, (first, firsts)
    for first, (path, options) in DROPDOWNS.items():
        dd = c.eval("return T_dd_by_first(T_settings(), ...)", first)
        for text, value in options:
            menu = c.dropdown_menu(dd)
            assert text in [e[2] for e in menu_texts(menu)], (text, menu_texts(menu))
            c.menu_select(text)
            w.tick(0.2)
            assert setting(c, path) == value, "%s -> %s = %r, expected %r" % (text, path, setting(c, path), value)
            c.eval("local d = ...; d:Refresh()", dd)
            assert c.eval("local d = ...; return d:GetText()", dd) == text, (path, c.eval("local d = ...; return d:GetText()", dd))
    # view phase: "Follow guild (P1)" = nil, P3 = 3
    vp = c.eval("return T_dd_by_first(T_settings(), 'Follow guild (P1)')")
    assert vp is not None, firsts
    menu = c.dropdown_menu(vp)
    texts = [e[2] for e in menu_texts(menu)]
    assert texts[0] == "Follow guild (P1)" and texts[3].startswith("P3 · "), texts
    c.menu_select(texts[3])
    w.tick(0.2)
    assert setting(c, "viewPhase") == 3 and c.eval("return ns.Guild:GetViewPhase()") == 3
    c.dropdown_menu(vp)
    c.menu_select("Follow guild (P1)")
    w.tick(0.2)
    assert setting(c, "viewPhase") is None and c.eval("return ns.Guild:GetViewPhase()") == 1
    no_errors(w)


@case
def minimap_toggle_hides_and_shows_the_button():
    w, c = settings_client(guild_rank=3)
    btn = "LibDBIcon10_DisasterZone"
    assert c.frame(btn) is not None, "LibDBIcon button not created"
    assert c.eval("return LibDBIcon10_DisasterZone:IsShown()") is True
    cb = checkbox(c, "Show the minimap button")
    assert checked(c, cb) is True
    c.click(cb)
    w.tick(0.2)
    assert c.eval("return DisasterZoneDB.settings.minimap.hide") is True
    assert c.eval("return LibDBIcon10_DisasterZone:IsShown()") is False
    c.relog()
    w.tick(2)
    assert c.eval("return LibDBIcon10_DisasterZone:IsShown()") is False, "hidden minimap button came back after relog"
    install_helpers(c)
    c.eval(DD_LIST)
    open_settings(c)
    cb = checkbox(c, "Show the minimap button")
    assert checked(c, cb) is False
    c.click(cb)
    w.tick(0.2)
    assert c.eval("return DisasterZoneDB.settings.minimap.hide") is False
    assert c.eval("return LibDBIcon10_DisasterZone:IsShown()") is True
    # launcher: left click toggles, right click opens settings, tooltip lines
    obj = "LibStub('LibDataBroker-1.1'):GetDataObjectByName('DisasterZone')"
    c.slash("/dz")
    w.tick(0.1)
    assert c.eval("return ns.MainFrame:IsShown()") is False
    c.eval("%s.OnClick(nil, 'RightButton')" % obj)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "settings"
    c.eval("%s.OnClick(nil, 'LeftButton')" % obj)
    assert c.eval("return ns.MainFrame:IsShown()") is False
    c.eval("GameTooltip:SetOwner(UIParent, 'ANCHOR_NONE'); %s.OnTooltipShow(GameTooltip)" % obj)
    lines = [strip_codes(l[0]) for l in tt_lines(c)]
    assert lines[0] == "DisasterZone" and lines[1] == "Raider" and "Right-click: settings" in lines[-2], lines
    assert lines[-1] == "Shift-click: boss drops", lines
    no_errors(w)


@case
def demo_simulate_and_demo_roll_buttons():
    w, c = settings_client(guild_rank=3)
    cb = checkbox(c, "Demo data (fake guild members & raid)")
    c.click(cb)
    w.tick(0.3)
    assert c.eval("return ns.Demo:IsEnabled()") is True
    status = strip_codes(c.eval("return DisasterZoneMainFrame and T_textregion(DisasterZoneMainFrame, 'Demo mode') and T_textregion(DisasterZoneMainFrame, 'Demo mode'):GetText()") or "")
    assert status.startswith("Demo mode"), status
    council = strip_codes(c.eval("return T_textregion(T_settings(), 'Loot Council.'):GetText()"))
    assert council == "You are on the Loot Council. (demo mode)", council
    c.click(c.eval("return T_button(T_settings(), 'Simulate a boss drop')"))
    w.tick(0.5)
    assert c.eval("return DisasterZoneDropPanel and DisasterZoneDropPanel:IsShown()") is True
    c.click(cb)
    w.tick(0.3)
    assert c.eval("return ns.Demo:IsEnabled()") is False
    c.click(c.eval("return T_button(T_settings(), 'Demo a roll')"))
    w.tick(0.5)
    assert c.eval("return ns.Demo:IsEnabled()") is True
    assert c.eval("return ns.Roll:GetActive() ~= nil") is True
    assert c.eval("return DisasterZoneRollFrame and DisasterZoneRollFrame:IsShown()") is True
    w.tick(40)
    # about text
    about = strip_codes(c.eval("return ns.SettingsUI.aboutText:GetText()"))
    assert about.startswith("Version %s · protocol 1" % toc_version()), about
    assert [e for e in w.addon_log if e["chat_type"] in ("RAID", "WHISPER")] == [], "demo actions sent addon messages"
    no_errors(w)


def gm_world(text="Welcome to Casual Disaster!"):
    """A GM, a raider and an officer (Ann, not picked) online; Bob / Carl / Dora offline. The guild info text is set
    to prove that DisasterZone never reads or writes it (every client spies on the Guild Information API)."""
    w = World()
    w.set_guild_info_text(text)
    w.add_offline_member("Bob", "MAGE", 3)
    w.add_offline_member("Carl", "ROGUE", 1)
    w.add_offline_member("Dora", "PRIEST", 2)
    gm = Client(w, "Gm", guild_rank=0, class_file="WARRIOR", preload_lua=GUILD_INFO_SPY)
    rai = Client(w, "Rai", guild_rank=3, class_file="HUNTER", preload_lua=GUILD_INFO_SPY)
    ann = Client(w, "Ann", guild_rank=1, class_file="PRIEST", preload_lua=GUILD_INFO_SPY)
    for x in (gm, rai, ann):
        x.load_addon()
    w.tick(3)
    for x in (gm, rai, ann):
        install_helpers(x)
        x.eval(DD_LIST)
    open_settings(gm)
    return w, gm, rai, ann


def council_state(c):
    """[status, summary, [guild member keys], edit button shown, info text] of the Settings council section."""
    c.eval("ns.SettingsUI:Refresh()")
    return c.eval_py("""
      local cs = ns.SettingsUI.cs
      local keys = {}
      for _, e in ipairs(cs.members) do if e:IsShown() then keys[#keys + 1] = e.key end end
      return { cs.status:GetText() or "", cs.summary:GetText() or "", keys, cs.editBtn:IsShown() and 1 or 0,
               cs.info:GetText() or "" }""")


def picker_section(c, kind="guild"):
    return "DisasterZoneCouncilPanel.councilView.%s" % kind


@case
def gm_edits_the_council_from_settings_and_everyone_follows():
    w, gm, rai, ann = gm_world()
    st = council_state(gm)
    assert strip_codes(st[0]) == "You are on the Loot Council. · Guild Master", st[0]
    assert strip_codes(st[1]) == "Guild council: only the Guild Master so far (no list shared yet).", st[1]
    assert st[2] == ["Gm-Thunderstrike"], st[2]
    assert st[3] == 1 and "the guild council (Guild Master)" in st[4], st
    # "Edit council..." opens the picker (Council tab > Loot Council)
    gm.click(gm.eval("return ns.SettingsUI.cs.editBtn"))
    w.tick(0.3)
    assert gm.eval("return ns.MainFrame:GetSelectedTab()") == "council"
    assert gm.eval("return ns.CouncilUI:GetView()") == "council"
    sec = picker_section(gm)
    assert gm.eval("return %s.picker.frame:IsShown()" % sec) is True
    assert gm.eval("return %s.save:IsEnabled()" % sec) is False, "Save & share must wait for a change"
    # pick Rai (online) and Bob (offline, via "Show offline members"), phase P3, save & share
    eb = gm.eval("return %s.picker.editBox" % sec)
    gm.type_text(eb, "rai")
    gm.press_enter(eb)
    gm.type_text(eb, "")
    gm.click(gm.eval("return %s.picker.toggleCheck" % sec))
    gm.type_text(eb, "bo")
    gm.press_enter(eb)
    gm.press_escape(eb)
    dd = gm.eval("return %s.phaseDD" % sec)
    menu = gm.dropdown_menu(dd)
    gm.menu_select([ch["text"] for ch in menu["children"]][2])
    w.tick(0.3)
    assert gm.eval("return %s.save:IsEnabled()" % sec) is True
    p0 = len(gm.chat_frame)
    gm.click(gm.eval("return %s.save" % sec))
    w.tick(1)
    assert any("Guild council saved and shared" in l for l in printed_since(gm, p0)), printed_since(gm, p0)
    # the Settings summary follows on every client
    for c in (gm, rai, ann):
        open_settings(c)
        st = council_state(c)
        assert strip_codes(st[1]) == "Guild council (set by Gm just now · phase P3):", (c.full_name, st[1])
        assert st[2] == ["Gm-Thunderstrike", "Bob-Thunderstrike", "Rai-Thunderstrike"], (c.full_name, st[2])
        assert c.eval("return ns.Guild:GetGuildPhase()") == 3
    assert strip_codes(council_state(rai)[0]) == "You are on the Loot Council. · guild council list"
    assert strip_codes(council_state(ann)[0]) == "You are not on the Loot Council.", "an officer is council only when picked"
    # nothing ever went through the Guild Information text
    assert w.guild_info_text() == "Welcome to Casual Disaster!"
    for c in (gm, rai, ann):
        assert guild_info_calls(c) == [], (c.full_name, guild_info_calls(c))
    no_errors(w)


@case
def council_list_limits_are_enforced_and_guild_info_untouched():
    # The old 500-character Guild Info limit is gone; the list itself is capped at 40 names (Addendum E §31).
    w, gm, rai, ann = gm_world(text="x" * 495)
    too_many = {"Name%02d-Thunderstrike" % i: True for i in range(41)}
    res = gm.eval_py("local ok, err = ns.Guild:SetGuildCouncil(...); return { ok = ok, err = err }", too_many)
    assert res.get("ok") is False and "40" in (res.get("err") or ""), res
    assert gm.eval("return ns.Guild:GetGuildCouncil()") is None, "a refused save must not store anything"
    forty = dict(list(too_many.items())[:40])
    gm_pick(w, gm, list(forty))
    assert rai.eval("local n = 0 for _ in pairs(ns.Guild:GetGuildCouncil().members) do n = n + 1 end return n") == 40
    bad = gm.eval_py("local ok, err = ns.Guild:SetGuildCouncil({ ['Bad|Name'] = true }); return { ok = ok, err = err }")
    assert bad.get("ok") is False, bad
    bad = gm.eval_py("local ok, err = ns.Guild:SetGuildCouncil({}, 9); return { ok = ok, err = err }")
    assert bad.get("ok") is False, bad
    assert w.guild_info_text() == "x" * 495, "guild info was changed"
    for c in (gm, rai, ann):
        assert guild_info_calls(c) == [], (c.full_name, guild_info_calls(c))
    no_errors(w)


@case
def non_gm_sees_read_only_council_section():
    w, gm, rai, ann = gm_world()
    gm_pick(w, gm, ["Rai"], phase=2)
    for c in (rai, ann):
        open_settings(c)
        st = council_state(c)
        assert strip_codes(st[1]) == "Guild council (set by Gm just now · phase P2):", st[1]
        assert st[2] == ["Gm-Thunderstrike", "Rai-Thunderstrike"], st[2]
        assert st[3] == 0, "only the Guild Master / a raid leader gets Edit council..."
        assert st[4].startswith("The Guild Master picks the guild council in DisasterZone."), st[4]
    assert strip_codes(council_state(rai)[0]) == "You are on the Loot Council. · guild council list"
    # the old editor, its popup and the tag writer are gone
    assert rai.eval("return ns.SettingsUI.cs.editor") is None
    assert rai.eval("return ns.SettingsUI.ConfirmSave") is None
    assert rai.eval("return StaticPopupDialogs.DISASTERZONE_SAVE_CONFIG") is None
    assert rai.eval("return ns.Guild.WriteConfig") is None
    # a non-GM (an officer too) cannot save the guild list
    for c in (rai, ann):
        res = c.eval_py("local ok, err = ns.Guild:SetGuildCouncil({ ['Ann-Thunderstrike'] = true }); "
                        "return { ok = ok, err = err }")
        assert res.get("ok") is False and "Guild Master" in (res.get("err") or ""), res
    w.tick(1)
    assert ann.eval("return ns.Guild:AmICouncil()") is False
    assert rai.eval("return ns.Guild:IsCouncil('Ann-Thunderstrike')") is False
    no_errors(w)


@case
def blizzard_settings_entry_opens_the_tab():
    w, c = solo("Alice", guild_rank=3, tick=3)
    install_helpers(c)
    assert c.eval("return ns.SettingsUI.category ~= nil") is True
    canvas = c.frame("DisasterZoneBlizzardOptions")
    assert canvas is not None
    btn = c.eval("return T_button(DisasterZoneBlizzardOptions, 'Open DisasterZone settings')")
    c.click(btn)
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "settings"
    no_errors(w)


@case
def settings_request_sync_when_not_in_guild_does_not_claim_success():
    # Settings > About > "Request sync" is shown to guildless players too; SendHello() refuses (not in a guild)
    # but the button still prints "Sync requested." (/dz sync says "You are not in a guild").
    w, c = settings_client(name="Solo", guild=None)
    p0 = len(c.chat_frame)
    c.click(c.eval("return T_button(T_settings(), 'Request sync')"))
    w.tick(0.5)
    said = printed_since(c, p0)
    assert [e for e in w.addon_log if e["sender"] == c.full_name] == []
    assert not any("Sync requested" in l for l in said), "guildless player told %r" % said
    no_errors(w)


if __name__ == "__main__":
    run_all()

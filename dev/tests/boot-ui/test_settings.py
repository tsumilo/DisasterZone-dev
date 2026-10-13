"""Settings tab: every checkbox and dropdown writes its setting (and follows external changes), the minimap
toggle, demo / simulate / demo-roll buttons, the Loot Council section (Addendum E §30: a read-only summary for
everyone, "Edit council..." for the Guild Master, which opens the picker; the Guild Info text is never touched),
the Blizzard Settings entry.

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_settings.py
"""
from _common import (menu_pick, menu_labels, case, run_all, toc_version, solo, no_errors, World, Client, install_helpers, menu_texts, printed_since,
                     strip_codes, tt_lines, gm_pick, GUILD_INFO_SPY, guild_info_calls)

CHECKS = [
    ("Boss drop panel", "alerts.councilPanel", False),
    ("On your BiS list!", "alerts.personalToast", False),      # (the alerts grid's row: its first switch, Pop-up)
    ("Glow on BiS loot buttons", "alerts.glow", False),
    ("BiS badges on the loot window", "alerts.lootBadges", False),
    ("Off-spec items too", "alerts.offspec", False),
    ("Announce rolls and winners", "roll.announce", False),
    ("Roll / Pass popup", "roll.popup", False),
    ("Auto-mark the planned mobs", "strategy.autoMark", False),
    ("Show my jobs near a planned boss", "strategy.reminder", False),
    ("DisasterZone lines on item tooltips", "tooltip.enabled", False),
    ("Who wants it (Loot Council)", "tooltip.council", False),
    ("Debug messages in chat", "debug", False),
]

# first option text -> (setting path, [(option text, stored value)])
DROPDOWNS = {
    "Attach to the loot window": ("dropPanelMode", [("Always floating", "floating"),
                                                    ("Attach to the loot window", "auto")]),
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
-- opens the Settings page that holds f (one page shows at a time; its More options fold opened), as a player would
function T_show_section_of(f)
  return ns.SettingsUI:Reveal(f)
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
    assert cb is not None, "no switch %r" % label
    c.eval("T_show_section_of(...)", cb)
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
    c.click(checkbox(c, "Glow on BiS loot buttons"))
    c.relog()
    w.tick(2)
    assert c.eval("return DisasterZoneDB.settings.alerts.glow") is False
    no_errors(w)


SWITCH_GEO = """local s = ...
return { kl = s.kl, kr = s.kr, mix = s.mix, press = s.press, ring = s.ringT ~= nil,
         moving = s:GetScript('OnUpdate') ~= nil, on = s:GetChecked() and true or false }"""


@case
def switches_slide_settle_and_squeeze():
    w, c = settings_client(guild_rank=3)
    cb = checkbox(c, "Debug messages in chat")
    geo = lambda: c.eval_py(SWITCH_GEO, cb)
    g = geo()
    assert g["on"] is False and g["kl"] == 3 and g["kr"] == 15 and g["mix"] == 0 and not g["moving"], g
    # a click: the knob slides right, its front edge ahead (it stretches), the green comes in, a ring goes out
    c.click(cb)
    g = geo()
    assert g["on"] is True and g["moving"] and g["ring"] and g["kl"] == 3, g
    w.tick(0.12, step=0.02)
    g = geo()
    assert 3 < g["kl"] < 19 and g["kr"] - g["kl"] > 13 and 0 < g["mix"] < 1, g
    w.tick(0.6, step=0.02)
    g = geo()
    assert g["kl"] == 19 and g["kr"] == 31 and g["mix"] == 1 and not g["ring"] and not g["moving"], g
    # back off: no ring, the knob home on the left, grey again
    c.click(cb)
    w.tick(0.05, step=0.02)
    assert geo()["ring"] is False and geo()["moving"]
    w.tick(0.6, step=0.02)
    g = geo()
    assert g["on"] is False and g["kl"] == 3 and g["kr"] == 15 and g["mix"] == 0 and not g["moving"], g
    # a held button squeezes the knob; letting go eases it back
    c.eval("__MOCK.call_script(..., 'OnMouseDown', 'LeftButton')", cb)
    w.tick(0.2, step=0.02)
    assert geo()["press"] == 1
    c.eval("__MOCK.call_script(..., 'OnMouseUp', 'LeftButton')", cb)
    w.tick(0.2, step=0.02)
    g = geo()
    assert g["press"] == 0 and not g["moving"] and g["on"] is False, g
    # a change from code while it is on screen moves too (the slash command, after the debounced refresh)
    c.slash("/dz debug")
    w.tick(0.9, step=0.02)
    g = geo()
    assert g["on"] is True and g["kl"] == 19 and g["mix"] == 1 and not g["moving"], g
    # ... and off screen it is set at once
    c.eval("ns.MainFrame:Close()")
    c.eval("local s = ...; s:SetChecked(false)", cb)
    g = geo()
    assert g["kl"] == 3 and g["mix"] == 0 and not g["moving"], g
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
        c.eval("T_show_section_of(...)", dd)
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
    c.eval("T_show_section_of(...)", vp)
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
    cb = checkbox(c, "Minimap button")
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
    cb = checkbox(c, "Minimap button")
    assert checked(c, cb) is False
    c.click(cb)
    w.tick(0.2)
    assert c.eval("return DisasterZoneDB.settings.minimap.hide") is False
    assert c.eval("return LibDBIcon10_DisasterZone:IsShown()") is True
    # launcher (the minimap arc, 1.3.2): right click opens / closes the window, left click fans out the pinned
    # sections, tooltip lines
    obj = "LibStub('LibDataBroker-1.1'):GetDataObjectByName('DisasterZone')"
    c.slash("/dz")
    w.tick(0.1)
    assert c.eval("return ns.MainFrame:IsShown()") is False
    c.eval("%s.OnClick(LibDBIcon10_DisasterZone, 'RightButton')" % obj)
    w.tick(0.1)
    assert c.eval("return ns.MainFrame:IsShown()") is True
    c.eval("%s.OnClick(LibDBIcon10_DisasterZone, 'RightButton')" % obj)
    w.tick(0.1)
    assert c.eval("return ns.MainFrame:IsShown()") is False
    c.eval("%s.OnClick(LibDBIcon10_DisasterZone, 'LeftButton')" % obj)
    w.tick(0.1)
    assert c.eval("return ns.MinimapArc:IsOpen()") is True
    assert c.eval("return ns.MainFrame:IsShown()") is False
    c.eval("ns.MinimapArc:Close(true)")
    c.eval("GameTooltip:SetOwner(UIParent, 'ANCHOR_NONE'); %s.OnTooltipShow(GameTooltip)" % obj)
    lines = [strip_codes(l[0]) for l in tt_lines(c)]
    assert lines[0] == "DisasterZone" and lines[1] == "Raider", lines
    assert "Left-click: your pinned sections" in lines[-2] and "Right-click: open" in lines[-2], lines
    assert lines[-1] == "Shift-click: boss drops", lines
    no_errors(w)


@case
def demo_simulate_and_demo_roll_buttons():
    w, c = settings_client(guild_rank=3)
    cb = checkbox(c, "Demo data")
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
    # (1.3.5: Demo a roll is a menu - a random prized drop or a loot rules scenario)
    c.click(c.eval("return T_button(T_settings(), 'Demo a roll')"))
    w.tick(0.2)
    labels = menu_labels(c)
    assert "Random prized drop" in labels and "Split vote" in labels, labels
    menu_pick(c, "Random prized drop")
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
    assert strip_codes(st[1]) == "Guild council · only the Guild Master so far", st[1]
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
        assert strip_codes(st[1]) == "Guild council · set by Gm just now · phase P3", (c.full_name, st[1])
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
        assert strip_codes(st[1]) == "Guild council · set by Gm just now · phase P2", st[1]
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
    c.eval("DisasterZoneBlizzardOptions:Hide(); DisasterZoneBlizzardOptions:Show()")   # built on its first show
    w.tick(0.2)
    btn = c.eval("return T_button(DisasterZoneBlizzardOptions, 'Settings')")
    c.click(btn)
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "settings"
    no_errors(w)


@case
def a_page_cards_tooltip_follows_a_right_click_pin():
    """Blizzard Options > DisasterZone: right-clicking a page card pins / unpins it, and the open tooltip's line says
    so at once (1.3.5 rebuilt it; it used to keep the old line until the mouse came back)."""
    w, c = solo("Alice", guild_rank=3, tick=3)
    install_helpers(c)
    c.eval("DisasterZoneBlizzardOptions:Hide(); DisasterZoneBlizzardOptions:Show()")
    w.tick(0.3)
    card = c.eval("""local found
      local function walk(f)
        for _, ch in ipairs({ f:GetChildren() }) do
          if not found and ch.key == 'atlas' and ch.pill and ch.Layout then found = ch end
          if not found then walk(ch) end
        end
      end
      walk(DisasterZoneBlizzardOptions)
      return found""")
    assert card is not None
    was = c.eval("return ns.MinimapArc:IsPinned('atlas')") is True
    c.hover(card)

    def pin_line():
        return [strip_codes(l[0]) for l in tt_lines(c) if "minimap" in strip_codes(l[0])]

    assert pin_line() == ["Right-click: unpin from the minimap" if was else "Right-click: pin to the minimap"],         pin_line()
    c.eval("local f = ...; f:GetScript('OnMouseUp')(f, 'RightButton')", card)
    assert (c.eval("return ns.MinimapArc:IsPinned('atlas')") is True) == (not was)
    assert pin_line() == ["Right-click: pin to the minimap" if was else "Right-click: unpin from the minimap"],         pin_line()
    no_errors(w)


@case
def a_council_member_outside_the_guild_roster_keeps_their_class_icon():
    """Settings > Loot Council: a listed member the guild roster does not know (a raid leader from no guild, a
    council pick who left) takes their class from my group, as in 1.3.5 (not the unknown player's dark disc)."""
    w, gm, rai, ann = gm_world()
    gm_pick(w, gm, ["Bob"])
    open_settings(gm)
    res = gm.eval_py("""
      local key = 'Bob-Thunderstrike'
      local get = ns.Guild.GetClass
      ns.Guild.GetClass = function(self, k) if k == key then return nil end return get(self, k) end
      ns.Util.group = ns.Util.group or {}
      ns.Util.group[key] = { classFile = 'MAGE' }
      ns.SettingsUI:Refresh()
      local out
      for _, e in ipairs(ns.SettingsUI.cs.members) do
        if e:IsShown() and e.key == key then
          local l, t = e.cls:GetTexCoord()
          local m = CLASS_ICON_TCOORDS.MAGE
          out = { shown = e.cls:IsShown(), mage = math.abs(l - m[1]) < 1e-6 and math.abs(t - m[3]) < 1e-6 }
        end
      end
      ns.Guild.GetClass = get
      return out""")
    assert res == {"shown": True, "mage": True}, res
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


# ------------------------------------------------------------------------------------------------------------------
# 1.4.2: the groups in a rail, a group's cards, search, Back to defaults, the look pages (UI/Settings.lua)
# ------------------------------------------------------------------------------------------------------------------
@case
def the_bis_alert_is_a_row_of_the_alerts_grid():
    w, c = settings_client(guild_rank=3)
    c.eval("ns.SettingsUI:SelectSection('reach')")
    w.tick(0.2)
    FIND = """local what = ...
      for _, r in ipairs(ns.SettingsUI.sections.reach.rows) do
        if r.switches and r.title:GetText() == 'On your BiS list!' then return r.switches[what] end
      end"""
    for what, path in (("popup", "alerts.personalToast"), ("sound", "alerts.sound"), ("chat", "alerts.chat")):
        sw = c.eval(FIND, what)
        assert sw is not None, what
        before = c.eval("return ns.DB:GetSetting(...) ~= false", path)
        c.click(sw)
        w.tick(0.2)
        assert (setting(c, path) is not False) == (not before), (what, path)
        assert c.eval("return ns.SettingsUI:ChangedIn('reach')") == (1 if before else 0)
        c.click(sw)
        w.tick(0.2)
    no_errors(w)


@case
def old_section_names_open_their_cards_and_groups_open_from_the_top():
    w, c = settings_client(guild_rank=3, class_file="PALADIN")
    for old, card, cat in (("alerts", "reach", "alerts"), ("notify", "reach", "alerts"), ("ui", "looks", "interface"),
                           ("rules", "rules", "loot"), ("rolls", "rolls", "loot"), ("tooltips", "tooltips", "general"),
                           ("window", "window", "general"), ("meters", "meters", "combat"), ("bless", "classtools", "combat"),
                           ("tutorials", "tutorials", "help"), ("about", "about", "help")):
        c.eval("ns.SettingsUI:SelectSection(...)", old)
        w.tick(0.1)
        assert c.eval("return ns.SettingsUI:GetSection()") == card, old
        assert c.eval("return ns.SettingsUI.cat") == cat, old
        assert c.eval("return ns.SettingsUI.cards[...]:IsVisible()", card) is True, old
    # a group opens on its tiles; the rail lights it and says how it is set
    c.eval("ns.SettingsUI:OpenCategory('combat')")
    w.tick(0.1)
    assert c.eval("return ns.SettingsUI.mode") == "tiles"
    assert c.eval("return ns.SettingsUI:GetSection()") == "combat"
    assert c.eval("return ns.SettingsUI.rail.rows.combat:IsSelected()") is True
    assert "Damage" in c.eval("return ns.SettingsUI.rail.rows.combat.line:GetText()")
    assert c.eval("return ns.SettingsUI.head.lead:GetText()") == "What runs while you fight."
    no_errors(w)


@case
def search_finds_options_with_working_controls_and_jumps_to_them():
    w, c = settings_client(guild_rank=3, class_file="PALADIN")
    c.eval("ns.SettingsUI.searchBox:SetText('warning sound'); ns.SettingsUI:Search('warning sound')")
    w.tick(0.3)
    assert c.eval("return ns.SettingsUI.mode") == "search"
    assert c.eval("return ns.SettingsUI.results:IsVisible()") is True
    hit = c.eval_py("""for _, e in ipairs(ns.SettingsUI.index) do
        if e.title == 'Warning sound' then return { e.card, e.result and e.result:IsVisible() or false } end end""")
    assert hit == ["meters", True], hit
    # its switch in the results writes the setting
    before = c.eval("return ns.DB:GetSetting('meters.sound') ~= false")
    c.click(c.eval("for _, e in ipairs(ns.SettingsUI.index) do if e.title == 'Warning sound' then return e.result.control end end"))
    w.tick(0.2)
    assert (setting(c, "meters.sound") is not False) == (not before)
    # a click on its name opens its card (the search box empties)
    c.click(c.eval("for _, e in ipairs(ns.SettingsUI.index) do if e.title == 'Warning sound' then return e.result.jump end end"))
    w.tick(0.3)
    assert c.eval("return ns.SettingsUI.mode") == "card"
    assert c.eval("return ns.SettingsUI:GetSection()") == "meters"
    assert c.eval("return ns.SettingsUI.searchBox:GetText()") == ""
    # a class tool's option and a look page's option are found too; nothing matches says so
    c.eval("ns.SettingsUI:Search('twist zone')")
    w.tick(0.2)
    assert c.eval_py("local o = {} for _, e in ipairs(ns.SettingsUI.index) do if e.result and e.result:IsShown() "
                     "then o[#o + 1] = e.kit or '' end end return o") == ["swing"]
    c.eval("ns.SettingsUI:Search('macro names')")
    w.tick(0.2)
    assert c.eval_py("local o = {} for _, e in ipairs(ns.SettingsUI.index) do if e.result and e.result:IsShown() "
                     "then o[#o + 1] = e.part or '' end end return o") == ["bars"]
    c.eval("ns.SettingsUI:Search('qqqzz')")
    w.tick(0.2)
    assert c.eval("return ns.SettingsUI.results.empty:IsShown()") is True
    no_errors(w)


@case
def a_changed_option_has_a_dot_and_back_to_defaults_puts_the_card_back():
    w, c = settings_client(guild_rank=3)
    c.eval("ns.DB:SetSetting('tooltip.maxNames', 8); ns.DB:SetSetting('minimap.hide', true)")
    w.tick(0.3)
    c.eval("ns.SettingsUI:SelectSection('tooltips'); ns.SettingsUI:Refresh()")
    assert c.eval("return ns.SettingsUI:ChangedIn('tooltips')") == 1
    assert c.eval("return ns.SettingsUI:ChangedIn('window')") == 1
    assert c.eval("return ns.SettingsUI.cards.tooltips.head.reset:IsShown()") is True
    assert c.eval("""for _, r in ipairs(ns.SettingsUI.sections.tooltips.rows) do
        if r.title:GetText() == 'Names shown' then return r.dot and r.dot:IsShown() end end""") is True
    c.click(c.eval("return ns.SettingsUI.cards.tooltips.head.reset"))
    w.tick(0.3)
    assert setting(c, "tooltip.maxNames") in (5, None)
    assert c.eval("return ns.SettingsUI:ChangedIn('tooltips')") == 0
    assert c.eval("return ns.SettingsUI.cards.tooltips.head.reset:IsShown()") is False
    # (the window card keeps its own change)
    assert setting(c, "minimap.hide") is True
    no_errors(w)


@case
def every_look_is_picked_in_interface_looks():
    w, c = settings_client(guild_rank=3, class_file="PALADIN")
    c.eval("ns.SettingsUI:SelectSection('looks')")
    w.tick(0.2)
    tiles = c.eval_py("local o = {} for _, t in ipairs(ns.SettingsUI.looksSec.partTiles) do "
                      "if t:IsShown() then o[#o + 1] = t.part end end return o")
    assert tiles == ["units", "group", "cast", "bars", "bags", "minimap", "sct", "bossmods", "meters", "classbars",
                     "timers"], tiles
    # a part's page: its sample stage, its look tiles, its options; its own look shows on its tile
    c.eval("ns.SettingsUI:OpenPart('units')")
    w.tick(0.2)
    assert c.eval("return ns.SettingsUI.mode") == "part"
    assert c.eval("return ns.SettingsUI.parts.units:IsVisible()") is True
    c.eval("ns.DB:SetSetting('ui.units.look', 'halo'); if ns.Popup then ns.Popup:HideAll() end")
    w.tick(0.3)
    assert c.eval("return ns.SettingsUI:PartLookName('units')") == "Halo"
    assert c.eval("return ns.SettingsUI:ChangedIn('part:units')") == 1
    c.eval("ns.SettingsUI:ResetCard('part:units'); if ns.Popup then ns.Popup:HideAll() end")
    w.tick(0.3)
    assert setting(c, "ui.units.look") is None
    # the meters' card links to their look page (their theme rows moved there)
    c.eval("ns.SettingsUI:SelectSection('meters')")
    w.tick(0.2)
    link = c.eval("""for _, r in ipairs(ns.SettingsUI.sections.meters.rows) do
        if r.title:GetText() == 'Look' then return r.control end end""")
    assert link is not None
    c.eval("T_show_section_of(...)", link)          # (it is under More options)
    assert c.eval("local b = ...; return b:IsVisible()", link) is True
    c.click(link)
    w.tick(0.2)
    assert c.eval("return ns.SettingsUI.mode") == "part" and c.eval("return ns.SettingsUI.part") == "meters"
    assert c.eval("return ns.SettingsUI.sections['look.meters'] ~= nil") is True
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# The clean-up (mockup "B · Feature tiles"): a group's tiles, a card's own page, More options, off means off
# ------------------------------------------------------------------------------------------------------------------
SHOWN_TILES = "local o = {} for k, t in pairs(ns.SettingsUI.tiles) do if t:IsVisible() then o[k] = t.sum:GetText() end end return o"
ROW = """local key, title = ...
  for _, r in ipairs(ns.SettingsUI.sections[key].rows) do if r.title:GetText() == title then return r end end"""


def row_y(c, key, title):
    """A row's top (its anchor's y in its section) and whether it shows."""
    return c.eval_py("local r = (function(...) " + ROW + " end)(...); local _, _, _, _, y = r:GetPoint(1); "
                     "return { y, r:IsShown() }", key, title)


@case
def a_group_opens_as_tiles_and_a_tile_opens_its_card():
    w, c = settings_client(guild_rank=3, class_file="PALADIN")
    c.eval("ns.DB:SetSetting('meters.dmg', true)")
    c.eval("ns.SettingsUI:SelectSection('combat')")
    w.tick(0.3)
    tiles = c.eval_py(SHOWN_TILES)
    assert sorted(tiles) == ["bossmods", "classtools", "meters", "mylog", "strategy"], tiles
    assert tiles["meters"] == "Damage on · threat off · in a group", tiles
    assert tiles["bossmods"].startswith("Off · pull timers still work"), tiles
    assert tiles["mylog"] == "Off · records nothing", tiles
    # (only the cards with a switch for the whole feature have one on their tile)
    assert c.eval("return ns.SettingsUI.tiles.meters.switch == nil and ns.SettingsUI.tiles.bossmods.switch ~= nil")
    # a click on the tile opens the card's page: the way back, its name, its lead line
    c.click(c.eval("return ns.SettingsUI.tiles.meters"))
    w.tick(0.2)
    assert c.eval("return ns.SettingsUI.mode") == "card" and c.eval("return ns.SettingsUI:GetSection()") == "meters"
    assert c.eval("return ns.SettingsUI.cards.meters.head:IsVisible()") is True
    assert c.eval("return ns.SettingsUI.head.back:GetText()") == "Combat"
    assert c.eval("return ns.SettingsUI.head.lead:GetText()").startswith("Damage and threat from your own combat log")
    assert c.eval("return ns.SettingsUI.tiles.meters:IsVisible()") is False
    # back to the group's tiles
    c.click(c.eval("return ns.SettingsUI.head.back"))
    w.tick(0.2)
    assert c.eval("return ns.SettingsUI.mode") == "tiles" and c.eval("return ns.SettingsUI.cat") == "combat"
    # the Guild Master's set-up card is a tile only for the Guild Master; Help is a group of tiles too
    c.eval("ns.SettingsUI:SelectSection('guild')")
    assert "setup" not in c.eval_py(SHOWN_TILES)
    c.eval("ns.SettingsUI:SelectSection('help')")
    assert sorted(c.eval_py(SHOWN_TILES)) == ["about", "demo", "tutorials"]
    no_errors(w)


@case
def a_tiles_master_switch_flips_the_feature_in_place():
    w, c = settings_client(guild_rank=3)
    c.eval("ns.SettingsUI:SelectSection('combat')")
    w.tick(0.2)
    sw = c.eval("return ns.SettingsUI.tiles.bossmods.switch")
    assert c.eval("local s = ...; return s:GetChecked()", sw) is False
    c.click(sw)
    w.tick(0.3)
    assert setting(c, "bossmods.on") is True
    assert c.eval("return ns.SettingsUI.mode") == "tiles", "the switch flips it, the tile does not open"
    # (learning is on by default: the line says where the timers come from)
    assert c.eval("return ns.SettingsUI.tiles.bossmods.sum:GetText()") == "On · learning from our pulls"
    c.eval("ns.DB:SetSetting('bossmods.learn', false); ns.SettingsUI:SelectSection('combat')")
    w.tick(0.2)
    assert c.eval("return ns.SettingsUI.tiles.bossmods.sum:GetText()").startswith("On · auto: ")
    c.eval("ns.DB:SetSetting('bossmods.learn', true)")
    # the card's head switch follows; switched off there, the tile follows back
    c.eval("ns.SettingsUI:SelectSection('bossmods')")
    head = c.eval("return ns.SettingsUI.cards.bossmods.head.master")
    assert c.eval("local h = ...; return h.switch:GetChecked()", head) is True
    assert strip_codes(c.eval("local h = ...; return h.state:GetText()", head)) == "On"
    c.click(c.eval("local h = ...; return h.switch", head))
    w.tick(0.3)
    assert setting(c, "bossmods.on") is False
    assert c.eval("return ns.SettingsUI.tiles.bossmods.switch:GetChecked()") is False
    no_errors(w)


@case
def a_card_switched_off_is_one_box_and_switch_on_brings_its_options():
    w, c = settings_client(guild_rank=3)
    c.eval("ns.SettingsUI:SelectSection('bossmods')")
    w.tick(0.2)
    card = "ns.SettingsUI.cards.bossmods"
    assert c.eval("return %s.sec:IsShown()" % card) is False, "no greyed rows"
    assert c.eval("return %s.off:IsVisible()" % card) is True
    assert c.eval("return %s.off.title:GetText()" % card) == "Boss mods is off"
    assert c.eval("return %s.off.try:IsVisible()" % card) is True
    # its options are not on the page, nor its raid list
    assert c.eval("local r = (function(...) " + ROW + " end)(...); return r:IsVisible()", "bossmods", "Timer bars") is False
    # Switch on: the rows come back, the box goes
    c.click(c.eval("return %s.off.on" % card))
    w.tick(0.3)
    assert setting(c, "bossmods.on") is True
    assert c.eval("return %s.off:IsShown()" % card) is False
    assert c.eval("return %s.sec:IsVisible()" % card) is True
    assert c.eval("local r = (function(...) " + ROW + " end)(...); return r:IsVisible()", "bossmods", "Timer bars") is True
    # My Log off: the box, and it still offers to delete what is stored (only then)
    c.eval("ns.SettingsUI:SelectSection('mylog')")
    w.tick(0.2)
    assert c.eval("return ns.SettingsUI.cards.mylog.off:IsVisible()") is True
    assert c.eval("return ns.SettingsUI.cards.mylog.off.buttons[2]:IsShown()") is False
    # a look part with a switch of its own: combat text
    c.eval("ns.SettingsUI:OpenPart('sct')")
    w.tick(0.2)
    assert c.eval("return ns.SettingsUI.parts.sct.off:IsVisible()") is True
    assert c.eval("return ns.SettingsUI.parts.sct.stage:IsShown() or ns.SettingsUI.parts.sct.sec:IsShown()") is False
    c.click(c.eval("return ns.SettingsUI.parts.sct.off.on"))
    w.tick(0.3)
    assert setting(c, "ui.sct.on") is True
    assert c.eval("return ns.SettingsUI.parts.sct.sec:IsVisible()") is True
    no_errors(w, allow=("reload",))


@case
def more_options_fold_the_rest_and_remember_open_or_shut():
    w, c = settings_client(guild_rank=3)
    c.eval("ns.DB:SetSetting('bossmods.on', true)")
    c.eval("ns.SettingsUI:SelectSection('bossmods')")
    w.tick(0.2)
    fold = "ns.SettingsUI.sections.bossmods.fold"
    assert c.eval("return %s:IsVisible()" % fold) is True
    assert c.eval("return %s.badge.fs:GetText()" % fold) == "9"
    assert c.eval("return %s.list:GetText()" % fold).startswith("Size, Warning size, Range frame")
    assert row_y(c, "bossmods", "Range frame")[1] is False
    raids_top = c.eval("return ns.SettingsUI.sections.bossmods.top")
    c.click(c.eval("return " + fold))
    w.tick(0.2)
    assert setting(c, "settingsMore.bossmods") is True
    assert row_y(c, "bossmods", "Range frame")[1] is True
    # (the raid list under the rows moves down past them)
    assert c.eval("return ns.SettingsUI.sections.bossmods.top") > raids_top + 9 * 40
    # open stays open on the next visit (and after a relog: an account setting)
    c.eval("ns.SettingsUI:SelectSection('combat'); ns.SettingsUI:SelectSection('bossmods')")
    assert row_y(c, "bossmods", "Range frame")[1] is True
    c.click(c.eval("return " + fold))
    w.tick(0.2)
    assert row_y(c, "bossmods", "Range frame")[1] is False
    assert c.eval("return ns.SettingsUI.sections.bossmods.top") == raids_top
    no_errors(w)


@case
def a_row_that_needs_a_switch_hides_and_the_rows_under_it_move_up():
    w, c = settings_client(guild_rank=3)
    c.eval("ns.DB:SetSetting('meters.dmg', true); ns.DB:SetSetting('meters.thr', true)")
    c.eval("ns.SettingsUI:SelectSection('meters'); ns.SettingsUI:Refresh()")
    w.tick(0.2)
    warn = row_y(c, "meters", "Warn me at")
    show = row_y(c, "meters", "Show them")
    assert warn[1] is True and show[1] is True
    # the threat meter off: its warning row is gone (not greyed) and "Show them" takes its place
    c.click(c.eval("return T_checkbox(T_settings(), 'Show the threat meter')"))
    w.tick(0.3)
    assert row_y(c, "meters", "Warn me at")[1] is False
    assert row_y(c, "meters", "Show them") == [warn[0], True]
    assert c.eval("local r = (function(...) " + ROW + " end)(...); return r:GetAlpha()", "meters", "Show them") == 1
    # both meters off: the panels' rows go too
    c.eval("ns.DB:SetSetting('meters.dmg', false)")
    w.tick(0.3)
    assert row_y(c, "meters", "Show them")[1] is False
    # the fold counts only what would show
    c.eval("ns.SettingsUI:SetMoreOpen(ns.SettingsUI.sections.meters, true)")
    assert c.eval("return ns.SettingsUI.sections.meters.fold.badge.fs:GetText()") == "1"      # (Look)
    assert row_y(c, "meters", "Fights to keep")[1] is False
    # the drop panel's position needs the drop panel
    c.eval("ns.DB:SetSetting('alerts.councilPanel', false); ns.SettingsUI:SelectSection('drops'); ns.SettingsUI:Refresh()")
    assert row_y(c, "drops", "Drop panel position")[1] is False
    assert row_y(c, "drops", "Glow on BiS loot buttons")[1] is True
    no_errors(w)


@case
def search_finds_rows_in_a_fold_and_rows_a_switch_hides():
    w, c = settings_client(guild_rank=3)
    c.eval("ns.DB:SetSetting('meters.thr', true); ns.DB:SetSetting('settingsMore.meters', nil)")
    JUMP = "local t = ...; for _, e in ipairs(ns.SettingsUI.index) do if e.title == t then ns.SettingsUI:Jump(e) return end end"
    c.eval("ns.SettingsUI.searchBox:SetText('tank view'); ns.SettingsUI:Search('tank view')")
    w.tick(0.2)
    assert c.eval("for _, e in ipairs(ns.SettingsUI.index) do if e.title == 'Tank view' then return e.result:IsVisible() end end")
    c.eval(JUMP, "Tank view")
    w.tick(0.2)
    # its card, the fold opened, the row shown and lit
    assert c.eval("return ns.SettingsUI.mode") == "card" and c.eval("return ns.SettingsUI:GetSection()") == "meters"
    assert setting(c, "settingsMore.meters") is True
    assert row_y(c, "meters", "Tank view")[1] is True
    assert c.eval("local r = (function(...) " + ROW + " end)(...); return r.dzFlash and r.dzFlash:IsShown()",
                  "meters", "Tank view") is True
    # a row hidden by the switch it needs: the page opens on that switch, lit
    c.eval("ns.DB:SetSetting('meters.thr', false); ns.SettingsUI:Refresh()")
    c.eval(JUMP, "Warn me at")
    w.tick(0.2)
    assert row_y(c, "meters", "Warn me at")[1] is False
    assert c.eval("local r = (function(...) " + ROW + " end)(...); return r.dzFlash and r.dzFlash:IsShown()",
                  "meters", "Show the threat meter") is True
    # on a page that is switched off: the box, its switch lit
    c.eval(JUMP, "Timer bars")
    w.tick(0.2)
    assert c.eval("return ns.SettingsUI:GetSection()") == "bossmods"
    assert c.eval("return ns.SettingsUI.cards.bossmods.off:IsVisible()") is True
    assert c.eval("local m = ns.SettingsUI.cards.bossmods.head.master; return m.dzFlash and m.dzFlash:IsShown()") is True
    # the master switches are found too, with a working switch
    c.eval("ns.SettingsUI.searchBox:SetText('record my'); ns.SettingsUI:Search('record my')")
    w.tick(0.2)
    sw = c.eval("for _, e in ipairs(ns.SettingsUI.index) do if e.title == 'Record my raid performance' then "
                "return e.result and e.result.control end end")
    assert sw is not None
    c.click(sw)
    assert setting(c, "mylog.enabled") is True
    no_errors(w)


if __name__ == "__main__":
    run_all()

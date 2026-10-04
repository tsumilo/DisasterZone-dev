"""Council membership (Addendum E §29: the Guild Master, the guild council list the GM picks, no guild) and the
main-window tabs that depend on it (CONFIG_UPDATED / DEMO_TOGGLED). Guild ranks other than the GM's no longer
matter, and nothing is read from the Guild Information text.

The raid-scope council (raid leader + the raid leader's list) is covered by tests/council/test_council_picker.py.

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_access.py
"""
from _common import (case, run_all, solo, no_errors, World, Client, printed_since, install_helpers,
                     seed_guild_council, gm_pick)

TABS_LUA = """
local out = {}
local f = DisasterZoneMainFrame
if not f or not f.Tabs then return out end
for _, t in ipairs(f.Tabs) do
  if t:IsShown() then out[#out + 1] = t.cdlKey end
end
return out"""

# The navigation strip: text tabs, then the Games, Changelog and Settings icons.
ALL_TABS = ["home", "mybis", "atlas", "council", "raids", "members", "games", "changelog", "settings"]
# Addendum J: every guild member has the Raids tab (Upcoming / Teams); its Raid log view stays council only.
PERSONAL_TABS = ["home", "mybis", "atlas", "raids", "members", "games", "changelog", "settings"]
GUILDLESS_TABS = ["home", "mybis", "atlas", "members", "games", "changelog", "settings"]


def shown_tabs(c):
    return c.eval_py(TABS_LUA) or []


def panel_shown(c, key):
    return bool(c.eval("local p = ns.MainFrame:GetPanel(...); return p ~= nil and p:IsVisible()", key))


def log_shown(c):
    """The Council tab's Loot Log view is on screen."""
    return bool(c.eval("return DisasterZoneLootLogPanel ~= nil and DisasterZoneLootLogPanel:IsVisible()"))


def open_window(c):
    c.slash("/dz")
    c.world.tick(0.3)


@case
def not_in_guild_only_personal_tabs():
    w, c = solo("Solo", guild=None, tick=3)
    open_window(c)
    assert shown_tabs(c) == GUILDLESS_TABS, shown_tabs(c)
    n0 = len(c.chat_frame)
    c.slash("/dz council")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "home"
    c.slash("/dz log")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "home"
    assert c.eval("return ns.MainFrame:GetPanel('council')") is None, "council panel built for a non-member"
    c.slash("/dz sync")
    assert any("not in a guild" in l for l in printed_since(c, n0)), printed_since(c, n0)
    c.slash("/dz settings")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "settings"
    assert c.find_text("You are not in a guild", True, True), "settings should explain the guildless state"
    # the title has no guild suffix
    assert c.eval("return DisasterZoneMainFrame.titleText:GetText()") == "DisasterZone"
    no_errors(w)


@case
def plain_raider_is_not_council():
    w, c = solo("Rai", guild_rank=3, tick=3, council=["Bob"], members=[("Bob", "MAGE", 3)])
    assert c.eval("return ns.Guild:AmICouncil()") is False
    assert c.eval("return ns.Guild:IsCouncil('Bob-Thunderstrike')") is True
    open_window(c)
    assert shown_tabs(c) == PERSONAL_TABS, shown_tabs(c)
    assert c.eval("return DisasterZoneMainFrame.titleText:GetText()") == "DisasterZone - <Casual Disaster>"
    c.slash("/dz council")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "home"
    # a raider only ever sees his own list in the Store
    assert c.eval_py("return ns.Store:GetAllKeys()") == ["Rai-Thunderstrike"]
    no_errors(w)


@case
def council_is_the_gm_plus_the_picked_list_not_a_rank():
    # (guild rank, on the GM's list, expected council, expected source)
    cases = [
        (0, False, True, "gm"),          # the Guild Master is always council
        (0, True, True, "gm"),
        (1, False, False, None),         # an officer is council only when picked
        (1, True, True, "guild"),
        (2, False, False, None),
        (3, True, True, "guild"),        # any rank can be picked
        (4, True, True, "guild"),
    ]
    for rank, listed, expect, source in cases:
        w, c = solo("Cee", guild_rank=rank, tick=2, council=(["Cee"] if listed else ["Somebody"]))
        got = c.eval("return ns.Guild:AmICouncil()")
        assert got is expect, "rank %d listed %r: council=%r, expected %r" % (rank, listed, got, expect)
        assert c.eval("return ns.Guild:GetCouncilSource('Cee-Thunderstrike')") == source, (rank, listed)
        assert c.eval("return ns.Guild:IsGM('Cee-Thunderstrike')") is (rank == 0)
        open_window(c)
        tabs = shown_tabs(c)
        assert tabs == (ALL_TABS if expect else PERSONAL_TABS), (rank, listed, tabs)
        no_errors(w)
    # no list stored at all: only the GM
    w, c = solo("Cee", guild_rank=1, tick=2)
    assert c.eval("return ns.Guild:AmICouncil()") is False
    assert c.eval("return ns.Guild:GetGuildCouncil()") is None
    no_errors(w)


@case
def listed_names_resolve_and_unknown_names_are_ignored_until_they_join():
    members = [("Bob", "MAGE", 3), ("Carl", "ROGUE", 0)]
    w, c = solo("Rai", guild_rank=3, tick=2, council=["Rai-Thunderstrike", "Stranger-OtherRealm", "Ghost"],
                members=members)
    assert c.eval("return ns.Guild:AmICouncil()") is True
    assert c.eval("return ns.Guild:IsCouncil('Bob-Thunderstrike')") is False
    assert c.eval("return ns.Guild:IsCouncil('Carl-Thunderstrike')") is True, "the GM (rank 0, offline) is council"
    # a listed name that is not in the guild roster does not count (and does not error)
    assert c.eval("return ns.Guild:IsCouncil('Ghost-Thunderstrike')") is False
    assert c.eval("return ns.Guild:IsCouncil('Stranger-OtherRealm')") is False
    assert "Ghost-Thunderstrike" not in c.eval_py("return ns.Guild:GetCouncilMembers()")
    open_window(c)
    assert shown_tabs(c) == ALL_TABS, shown_tabs(c)
    # ... until Ghost joins the guild
    w.add_offline_member("Ghost", "PRIEST", 4)
    c.eval("C_GuildInfo.GuildRoster()")
    w.tick(1)
    assert c.eval("return ns.Guild:IsCouncil('Ghost-Thunderstrike')") is True
    assert "Ghost-Thunderstrike" in c.eval_py("return ns.Guild:GetCouncilMembers()")
    no_errors(w)


@case
def tabs_follow_config_updates_while_window_open():
    w = World()
    gm = Client(w, "Gm", guild_rank=0, class_file="WARRIOR")
    rai = Client(w, "Rai", guild_rank=3, class_file="MAGE")
    for x in (gm, rai):
        x.load_addon()
    w.tick(3)
    open_window(rai)
    assert shown_tabs(rai) == PERSONAL_TABS
    # the GM picks Rai (phase 2) through the real Guild:SetGuildCouncil path (CG on GUILD)
    gm_pick(w, gm, ["Rai"], phase=2)
    assert rai.eval("return ns.Guild:AmICouncil()") is True
    assert shown_tabs(rai) == ALL_TABS, shown_tabs(rai)
    # phase follows the list: the My BiS panel switches to the guild phase until the user picks one
    assert rai.eval("return ns.Guild:GetGuildPhase()") == 2
    assert rai.eval("return ns.MyBiS:GetPhase()") == 2
    # Rai opens the council tab, then gets removed while looking at it
    rai.slash("/dz council")
    w.tick(0.5)
    assert rai.eval("return ns.MainFrame:GetSelectedTab()") == "council"
    assert panel_shown(rai, "council")
    gm_pick(w, gm, [])
    assert rai.eval("return ns.Guild:AmICouncil()") is False
    assert shown_tabs(rai) == PERSONAL_TABS, shown_tabs(rai)
    assert rai.eval("return ns.MainFrame:GetSelectedTab()") == "home", "window kept showing the council tab"
    assert not panel_shown(rai, "council"), "council panel still visible after losing council status"
    assert rai.eval("return ns.Guild:GetGuildPhase()") == 2, "an empty list keeps the GM's phase"
    no_errors(w)


@case
def tabs_follow_demo_toggle():
    w, c = solo("Rai", guild_rank=3, tick=3)
    open_window(c)
    for i in range(3):
        c.slash("/dz demo on")
        w.tick(0.3)
        assert shown_tabs(c) == ALL_TABS, shown_tabs(c)
        c.slash("/dz council")
        w.tick(0.5)
        assert panel_shown(c, "council")
        assert c.eval("return DisasterZoneMainFrame.titleText:GetText()") == "DisasterZone - <Casual Disaster>"
        c.slash("/dz demo off")
        w.tick(0.3)
        assert shown_tabs(c) == PERSONAL_TABS, shown_tabs(c)
        assert c.eval("return ns.MainFrame:GetSelectedTab()") == "home"
        assert not panel_shown(c, "council")
    # demo toggled while the window is closed: reopening lands on an available tab
    c.slash("/dz demo on")
    c.slash("/dz log")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab() == 'council' and ns.CouncilUI:GetView()") == "log"
    c.slash("/dz")          # close
    w.tick(0.1)
    assert c.eval("return ns.MainFrame:IsShown()") is False
    c.slash("/dz demo off")
    c.slash("/dz")          # reopen: lands on Home
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "home"
    assert shown_tabs(c) == PERSONAL_TABS
    no_errors(w)


@case
def stored_list_applies_once_the_roster_arrives():
    # The list is stored (SavedVariables), but a listed member counts only once the guild roster confirms the
    # name; right after login the roster can be late.
    w = World(roster_delay=4)
    seed_guild_council(w, ["Rai"], phase=3)
    c = Client(w, "Rai", guild_rank=3, online=False)
    c.preload_lua = """
      local readyAt = GetTime() + 4
      local orig = C_GuildInfo.GuildRoster
      C_GuildInfo.GuildRoster = function(...)
        local d = readyAt - GetTime()
        if d > 0 then __MOCK.after(d, function() orig() end, "slow guild roster") return end
        return orig(...)
      end"""
    c.login()
    w.tick(1)
    assert c.eval("return ns.Guild:IsReady()") is False
    assert c.eval("return ns.Guild:AmICouncil()") is False
    w.tick(5)
    assert c.eval("return ns.Guild:IsReady()") is True
    assert c.eval("return ns.Guild:AmICouncil()") is True
    assert c.eval("return ns.Guild:GetGuildPhase()") == 3
    open_window(c)
    assert shown_tabs(c) == ALL_TABS
    no_errors(w)


@case
def stored_list_survives_relog_and_belongs_to_its_guild():
    # The accepted list lives in SavedVariables "until changed": a relog needs no network to restore it.
    w, c = solo("Rai", guild_rank=3, tick=3, council=["Rai"], phase=4)
    assert c.eval("return ns.Guild:GetGuildPhase()") == 4
    assert c.eval("return ns.Guild:AmICouncil()") is True
    w.cdl_council_seed = {}                  # no more seeding: only the saved copy remains
    c.relog()
    w.tick(2)
    assert c.eval("return ns.Guild:IsReady()") is True
    assert c.eval("return ns.Guild:GetGuildPhase()") == 4, "the stored phase was not applied after the relog"
    assert c.eval("return ns.Guild:AmICouncil()") is True, "the stored list was not applied after the relog"
    # the list belongs to this guild only: a character of another guild ignores it
    w2 = World()
    w2.saved = {"Other-Thunderstrike": dict(w.saved.get("Rai-Thunderstrike", {}))}
    o = Client(w2, "Other", guild="Some Other Guild", guild_rank=3)
    o.load_addon()
    w2.tick(2)
    assert o.eval("return ns.Guild:GetGuildPhase()") == 1
    assert o.eval("return ns.Guild:AmICouncil()") is False
    assert o.eval("return ns.Guild:GetGuildCouncil()") is None
    no_errors(w)
    no_errors(w2)


def leave_guild(w, c):
    """Harness shim: the harness has no leave/join-guild helper."""
    c.guild = None
    w._sync(roster_changed=True)
    c.fire("PLAYER_GUILD_UPDATE", "player")
    w.tick(1)


def join_guild(w, c, guild, rank):
    c.guild, c.guild_rank = guild, rank
    w._sync(roster_changed=True)
    c.fire("PLAYER_GUILD_UPDATE", "player")
    c.eval("C_GuildInfo.GuildRoster()")
    w.tick(2)


@case
def leaving_the_guild_mid_session_drops_council_views():
    w, c = solo("Cou", guild_rank=1, tick=3, council=["Cou"], phase=3, members=[("Bob", "MAGE", 3)])
    c.eval("""local d = { v = 1, cl = 'MAGE', sp = '', ph = { [1] = { [1] = { 28744, 0 } } }, ob = {}, eq = {} }
      ns.Store:Put('Bob-Thunderstrike', { r = 1, ts = GetServerTime(), h = ns.Util.Hash(d), d = d }, 'direct')""")
    c.slash("/dz council")
    w.tick(0.5)
    assert shown_tabs(c) == ALL_TABS
    assert c.eval("return ns.Guild:GetGuildPhase()") == 3
    leave_guild(w, c)
    assert c.eval("return ns.Guild:AmICouncil()") is False
    assert c.eval("return ns.Guild:GetGuildPhase()") == 1
    assert shown_tabs(c) == GUILDLESS_TABS, shown_tabs(c)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "home"
    assert not panel_shown(c, "council")
    assert c.eval("return DisasterZoneMainFrame.titleText:GetText()") == "DisasterZone", c.eval("return DisasterZoneMainFrame.titleText:GetText()")
    assert c.eval_py("return ns.Store:GetAllKeys()") == ["Cou-Thunderstrike"]
    assert c.eval("return ns.Sync:GetStatusText()") == "Not in a guild"
    # joining another guild as a plain member keeps the old guild's lists (and its council list) out of sight
    join_guild(w, c, "Other Guild", 3)
    assert c.eval("return ns.Guild:GetGuildName()") == "Other Guild"
    assert c.eval("return DisasterZoneMainFrame.titleText:GetText()") == "DisasterZone - <Other Guild>"
    assert c.eval_py("return ns.Store:GetAllKeys()") == ["Cou-Thunderstrike"]
    assert c.eval("return ns.Guild:AmICouncil()") is False
    assert c.eval("return ns.Guild:GetGuildPhase()") == 1
    no_errors(w)


@case
def account_wide_saved_variables_with_an_alt_in_another_guild():
    # WoW SavedVariables are per account; the harness stores them per character, so copy them over (shim).
    w = World()
    seed_guild_council(w, ["Main"], phase=2)
    seed_guild_council(w, [], phase=5, guild="Alt Guild")      # the alt's guild: its GM (the alt) set P5
    w.add_offline_member("Bob", "MAGE", 3)
    main = Client(w, "Main", guild_rank=1)
    main.load_addon()
    w.tick(3)
    assert main.eval("return ns.Guild:AmICouncil()") is True
    main.eval("""local d = { v = 1, cl = 'MAGE', sp = '', ph = { [1] = { [1] = { 28744, 0 } } }, ob = {}, eq = {} }
      ns.Store:Put('Bob-Thunderstrike', { r = 1, ts = GetServerTime(), h = ns.Util.Hash(d), d = d }, 'direct')""")
    main.eval("ns.DB:SetSetting('alerts.sound', false)")
    main.eval("ns.BiS:SetSlot(1, 1, 'main', ns.ItemDB:GetCandidates(1, {maxPhase=1})[1].itemID)")
    main.logout()
    alt = Client(w, "Alty", guild="Alt Guild", guild_rank=0, class_file="DRUID", online=False)
    w.saved[alt.full_name] = dict(w.saved[main.full_name])
    alt.login()
    w.tick(3)
    assert alt.eval("return ns.Guild:AmICouncil()") is True, "the alt is its guild's GM"
    assert alt.eval("return ns.Guild:GetGuildPhase()") == 5, "alt did not use its own guild's council list"
    assert alt.eval("return ns.Guild:IsCouncil('Main-Thunderstrike')") is False, "the main's guild list leaked"
    assert alt.eval_py("return ns.Store:GetAllKeys()") == ["Alty-Thunderstrike"], "other guild's lists shown"
    assert alt.eval("return ns.db.settings.alerts.sound") is False          # settings are account-wide
    assert alt.eval("return ns.BiS:GetData().cl") == "DRUID"
    assert alt.eval_py("return {ns.BiS:GetSlot(1, 1)}") == [], "alt sees the main's BiS list"
    alt.slash("/dz council")
    w.tick(0.5)
    assert alt.eval("return #ns.Loot:GetHistory() >= 0") is True
    alt.logout()
    # back on the main: its own record, the guild's lists and its guild's council list are intact
    w.saved[main.full_name] = dict(w.saved[alt.full_name])
    main.login()
    w.tick(3)
    assert main.eval_py("return ns.Store:GetAllKeys()") == ["Bob-Thunderstrike", "Main-Thunderstrike"]
    assert main.eval("return ns.BiS:GetSlot(1, 1)") is not None
    assert main.eval("return ns.Guild:GetGuildPhase()") == 2
    assert main.eval("return ns.Guild:AmICouncil()") is True
    assert main.eval("return DisasterZoneDB.chars['Alty-Thunderstrike'].data.cl") == "DRUID"
    no_errors(w)


@case
def accented_and_cross_realm_names_on_the_list():
    w = World()
    w.add_offline_member("Bob", "MAGE", 3, realm="Other Realm")
    gm = Client(w, "Gm", guild_rank=0)
    dov = Client(w, "Dövid", guild_rank=3, class_file="SHAMAN")
    for x in (gm, dov):
        x.load_addon()
    w.tick(3)
    gm_pick(w, gm, ["Dövid-Thunderstrike", "Bob-OtherRealm"])
    assert dov.eval("return ns.Guild:AmICouncil()") is True
    assert gm.eval("return ns.Guild:IsCouncil('Bob-OtherRealm')") is True
    assert dov.eval("return ns.Guild:IsCouncil('Bob-OtherRealm')") is True
    members = sorted(dov.eval_py("local o = {} for k in pairs(ns.Guild:GetGuildCouncil().members) do o[#o + 1] = k end return o"))
    assert members == ["Bob-OtherRealm", "Dövid-Thunderstrike"], members
    # a typed name in another case resolves to the roster's spelling
    gm_pick(w, gm, ["dövid", "BOB-OtherRealm"])
    members = sorted(dov.eval_py("local o = {} for k in pairs(ns.Guild:GetGuildCouncil().members) do o[#o + 1] = k end return o"))
    assert members == ["Bob-OtherRealm", "Dövid-Thunderstrike"], members
    install_helpers(dov)
    dov.slash("/dz")
    w.tick(0.3)
    assert shown_tabs(dov) == ALL_TABS
    assert w.guild_info_text() == "", "DisasterZone must never write the Guild Information"
    no_errors(w)


@case
def guild_rank_changes_do_not_change_council_only_the_list_and_the_gm_do():
    w = World()
    gm = Client(w, "Gm", guild_rank=0, class_file="WARRIOR")
    rai = Client(w, "Rai", guild_rank=3, class_file="MAGE")
    for x in (gm, rai):
        x.load_addon()
    w.tick(3)
    open_window(rai)
    assert shown_tabs(rai) == PERSONAL_TABS
    rai.guild_rank = 1                   # promoted to officer: not council by rank any more
    w._sync(roster_changed=True)
    w.tick(1)
    assert rai.eval("return ns.Guild:AmICouncil()") is False
    assert shown_tabs(rai) == PERSONAL_TABS, shown_tabs(rai)
    gm_pick(w, gm, ["Rai"])              # picked
    assert shown_tabs(rai) == ALL_TABS, shown_tabs(rai)
    rai.slash("/dz log")
    w.tick(0.3)
    assert log_shown(rai)
    rai.guild_rank = 4                   # demoted: still on the list
    w._sync(roster_changed=True)
    w.tick(1)
    assert rai.eval("return ns.Guild:AmICouncil()") is True
    gm_pick(w, gm, [])                   # removed from the list
    assert rai.eval("return ns.Guild:AmICouncil()") is False
    assert shown_tabs(rai) == PERSONAL_TABS, shown_tabs(rai)
    assert not log_shown(rai)
    assert rai.eval("return ns.MainFrame:GetSelectedTab()") == "home"
    # the guild is handed over: the new GM is council, the old one only if picked
    rai.guild_rank, gm.guild_rank = 0, 1
    w._sync(roster_changed=True)
    w.tick(1)
    for c in (gm, rai):
        assert c.eval("return ns.Guild:GetGM()") == "Rai-Thunderstrike", c
        assert c.eval("return ns.Guild:IsCouncil('Rai-Thunderstrike')") is True, c
        assert c.eval("return ns.Guild:IsCouncil('Gm-Thunderstrike')") is False, c
    assert shown_tabs(rai) == ALL_TABS, shown_tabs(rai)
    assert rai.eval("return ns.Guild:CanEditGuildCouncil()") is True
    assert gm.eval("return ns.Guild:CanEditGuildCouncil()") is False
    no_errors(w)


if __name__ == "__main__":
    run_all()

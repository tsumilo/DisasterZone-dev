"""Boot / relog / SavedVariables scenarios for DisasterZone (real addon, mocked client).

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_boot.py
"""
import copy

from _common import case, run_all, toc_version, solo, no_errors, World, Client, printed_since

EXPECTED_SETTINGS = {
    "mylog": {"enabled": False, "heroics": False, "keepWeeks": 12},
    "minimap": {"hide": False},
    "openOn": "home",
    "alerts": {"councilPanel": True, "personalToast": True, "sound": True, "glow": True, "chat": True,
               "lootBadges": True, "offspec": True},
    "dropPanelMode": "auto",
    "tooltip": {"enabled": True, "council": True, "maxNames": 5},
    "announceChannel": "RAID",
    "qualityThreshold": 4,
    "roll": {"duration": 30, "announce": True, "popup": True},
    "dungeon": {"enabled": False, "quality": 3},   # Addendum B §22.1
    # Addendum F §35: the item picker's Sources (default Raids + 5-man dungeons)
    "pickerSources": {"raids": True, "dungeons": True, "crafted": False, "rep": False, "badges": False, "pvp": False},
    "atlas": {"show": "all"},   # the Atlas tab's Show filter
    "raidlog": {"keepDays": 365}, "strategy": {"autoMark": True, "reminder": True},
    "debug": False,
    "windows": {},
}

# Records the lifecycle as the addon dispatches it: installed before the addon files run; wraps every
# module's OnInit / OnLogin at ADDON_LOADED (our frame is registered first, so it runs before Init.lua's).
LIFECYCLE_PRELOAD = r"""
__LC = { calls = {}, events = {} }
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, ev, name)
  table.insert(__LC.events, ev)
  if ev ~= "ADDON_LOADED" or name ~= "DisasterZone" or not DisasterZone then return end
  local ns = DisasterZone
  for _, M in ipairs(ns:GetModules()) do
    for _, meth in ipairs({ "OnInit", "OnLogin" }) do
      local orig = M[meth]
      if type(orig) == "function" then
        M[meth] = function(self, ...)
          table.insert(__LC.calls, { M.name, meth,
            (ns.db ~= nil and ns.db == DisasterZoneDB) and 1 or 0,
            ns.loggedIn and 1 or 0,
            (ns.Util.PlayerKey() ~= nil) and 1 or 0,
            ns.initialized and 1 or 0 })
          return orig(self, ...)
        end
      end
    end
  end
end)
"""


def strip_volatile(db):
    return copy.deepcopy(db)


@case
def fresh_boot_defaults_and_globals():
    w, c = solo("Alice", guild_rank=3, tick=30)
    no_errors(w)
    assert c.eval("return DisasterZone == ns") is True, "global DisasterZone must be the namespace"
    assert c.eval("return ns.initialized") is True and c.eval("return ns.loggedIn") is True
    assert c.eval("return ns.version") == toc_version(), c.eval("return ns.version")
    assert c.eval("return ns.PROTO") == 1
    db = c.eval_py("return DisasterZoneDB")
    assert db["schema"] == 1, db.get("schema")
    assert db["settings"] == EXPECTED_SETTINGS, db["settings"]
    for k in ("lists", "ledger", "peers", "dropHistory", "raids"):
        assert db[k] == {}, (k, db[k])
    assert "viewPhase" not in db["settings"]
    me = db["chars"]["Alice-Thunderstrike"]
    assert me["rev"] == 0 and me["data"]["cl"] == "PALADIN" and me["data"]["v"] == 1, me
    # talents (41,20,0) -> Holy is detected when the record is created
    assert me["data"]["sp"] == "Holy", me["data"]["sp"]
    # nothing was chosen, so nothing may be committed or shared (rev stays 0 for restore-on-reinstall)
    assert c.eval("return ns.BiS:IsDirty()") is False
    # ns.db is the SavedVariables table itself
    assert c.eval("return ns.db == DisasterZoneDB") is True
    no_errors(w)


@case
def lifecycle_order_oninit_then_onlogin():
    for reload in (False, True):
        w = World()
        c = Client(w, "Alice", guild_rank=1, preload_lua=LIFECYCLE_PRELOAD)
        c.load_addon()
        w.tick(1)
        if reload:
            c.relog()   # fresh runtime: preload runs again
            w.tick(1)
        calls = c.eval_py("return __LC.calls")
        modules = [c.eval("local m = ...; return m.name", m) for m in c.eval("return ns:GetModules()").values()]
        inits = [x for x in calls if x[1] == "OnInit"]
        logins = [x for x in calls if x[1] == "OnLogin"]
        assert modules[:2] == ["ItemDB", "DB"], modules
        # every OnInit before any OnLogin, both in module (TOC) order, each exactly once
        first_login = next(i for i, x in enumerate(calls) if x[1] == "OnLogin")
        assert all(x[1] == "OnInit" for x in calls[:first_login]), calls
        assert all(x[1] == "OnLogin" for x in calls[first_login:]), calls
        order_init = [x[0] for x in inits]
        order_login = [x[0] for x in logins]
        assert order_init == [m for m in modules if m in order_init], (order_init, modules)
        assert order_login == [m for m in modules if m in order_login], (order_login, modules)
        assert len(set(order_init)) == len(order_init) and len(set(order_login)) == len(order_login)
        # ns.db is ready for DB and every module after it; loggedIn only in OnLogin
        after_db = False
        for name, meth, db_ok, logged, has_key, inited in inits:
            if name == "DB":
                after_db = True
                continue
            if after_db:
                assert db_ok == 1, "%s:OnInit ran before ns.db was set" % name
            assert logged == 0, "%s:OnInit ran after loggedIn" % name
            assert inited == 1
        for name, meth, db_ok, logged, has_key, inited in logins:
            assert logged == 1 and has_key == 1 and db_ok == 1, (name, db_ok, logged, has_key)
        events = c.eval_py("return __LC.events")
        assert events.index("ADDON_LOADED") < events.index("PLAYER_LOGIN"), events
        no_errors(w)


@case
def relog_persists_settings_edits_and_commits_on_logout():
    w, c = solo("Alice", guild_rank=3, tick=5)
    c.eval("ns.DB:SetSetting('alerts.sound', false); ns.DB:SetSetting('tooltip.maxNames', 12); "
           "ns.DB:SetSetting('viewPhase', 3)")
    # 28770 = Tier-4 style helm? use a real P1 head that fits: pick the first head candidate
    head = c.eval("return ns.ItemDB:GetCandidates(1, {maxPhase=1, class='PALADIN', usableOnly=true})[1].itemID")
    assert c.eval("return ns.BiS:SetSlot(1, 1, 'main', ...)", head) is True
    assert c.eval("return ns.BiS:IsDirty()") is True
    # /reload before the 8 s commit debounce: PLAYER_LOGOUT must commit (rev 1) and persist
    c.relog()
    w.tick(5)
    db = c.eval_py("return DisasterZoneDB")
    s = db["settings"]
    assert s["alerts"]["sound"] is False and s["tooltip"]["maxNames"] == 12 and s["viewPhase"] == 3, s
    me = db["chars"]["Alice-Thunderstrike"]
    assert me["rev"] == 1, me["rev"]
    assert c.eval_py("return {DisasterZoneDB.chars['Alice-Thunderstrike'].data.ph[1][1][1], "
                     "DisasterZoneDB.chars['Alice-Thunderstrike'].data.ph[1][1][2]}") == [head, 0]
    assert c.eval("return ns.BiS:GetSlot(1, 1)") == head
    assert c.eval("return ns.Guild:GetViewPhase()") == 3
    # full logout + login keeps it too
    c.relog(reload=False)
    w.tick(5)
    assert c.eval("return ns.BiS:GetSlot(1, 1)") == head
    assert c.eval("return ns.db.chars['Alice-Thunderstrike'].rev") == 1
    no_errors(w)


@case
def migration_and_defaults_are_idempotent_across_relogs():
    w, c = solo("Alice", guild_rank=0, tick=30, council=["Bob"], phase=2)
    first = strip_volatile(c.eval_py("return DisasterZoneDB"))
    src1 = w.saved_variables(c)  # empty until the first logout
    c.relog()
    w.tick(30)
    second = strip_volatile(c.eval_py("return DisasterZoneDB"))
    c.relog()
    w.tick(30)
    third = strip_volatile(c.eval_py("return DisasterZoneDB"))
    assert first == second == third, (first, second, third)
    assert third["schema"] == 1
    no_errors(w)


@case
def corrupt_saved_variables_are_repaired_not_fatal():
    w = World()
    c = Client(w, "Alice", guild_rank=3)
    c.set_saved_variable("DisasterZoneDB", """{
        settings = { alerts = "loud", tooltip = 7, minimap = true, sound = 1, dropPanelMode = "floating",
                     qualityThreshold = 3, windows = { DisasterZoneMainFrame = "x" } },
        chars = "none", lists = 5, ledger = { "junk", [3] = 4 }, peers = false, guildCfg = "x",
        dropHistory = { 1, 2, 3 }, extra = { keep = true }, schema = 1 }""")
    c.load_addon()
    w.tick(20)
    db = c.eval_py("return DisasterZoneDB")
    s = db["settings"]
    # invalid sub-tables replaced by defaults, valid saved values kept, unknown keys kept
    assert s["alerts"] == EXPECTED_SETTINGS["alerts"], s["alerts"]
    assert s["tooltip"] == EXPECTED_SETTINGS["tooltip"], s["tooltip"]
    assert s["minimap"] == {"hide": False}, s["minimap"]
    assert s["dropPanelMode"] == "floating" and s["qualityThreshold"] == 3, s
    assert db["extra"] == {"keep": True}
    assert isinstance(db["chars"], dict) and "Alice-Thunderstrike" in db["chars"], db["chars"]
    assert db["lists"] == {} and db["peers"] == {}
    # a corrupt saved window position must not break the main window
    c.slash("/dz")
    w.tick(1)
    assert c.eval("return DisasterZoneMainFrame:IsShown()") is True
    no_errors(w)


@case
def non_table_saved_variable_is_replaced():
    w = World()
    c = Client(w, "Alice", guild_rank=3)
    c.set_saved_variable("DisasterZoneDB", '"garbage"')
    c.load_addon()
    w.tick(5)
    assert c.eval("return type(DisasterZoneDB)") == "table"
    assert c.eval("return DisasterZoneDB.schema") == 1
    no_errors(w)


@case
def saved_by_newer_version_is_kept_and_warned():
    w = World()
    c = Client(w, "Alice", guild_rank=3)
    c.set_saved_variable("DisasterZoneDB", "{ schema = 99, settings = { debug = false }, futureThing = { a = 1 } }")
    c.load_addon()
    w.tick(5)
    assert c.eval("return DisasterZoneDB.schema") == 99
    assert any("newer DisasterZone version" in str(x) for x in c.chat_frame), c.chat_frame
    c.relog()
    w.tick(5)
    assert c.eval("return DisasterZoneDB.schema") == 99, "schema was downgraded on relog"
    assert c.eval("return DisasterZoneDB.futureThing.a") == 1
    no_errors(w)


@case
def missing_schema_with_data_is_migrated_once():
    w = World()
    c = Client(w, "Alice", guild_rank=3)
    c.set_saved_variable("DisasterZoneDB", "{ settings = { alerts = { sound = false } }, ledger = {} }")
    c.load_addon()
    w.tick(5)
    assert c.eval("return DisasterZoneDB.schema") == 1
    assert c.eval("return DisasterZoneDB.settings.alerts.sound") is False
    assert c.eval("return DisasterZoneDB.settings.alerts.glow") is True
    no_errors(w)


@case
def corrupt_own_record_is_sanitized_and_ui_opens():
    w = World()
    c = Client(w, "Alice", guild_rank=3)
    c.set_saved_variable("DisasterZoneDB", """{ schema = 1, chars = { ["Alice-Thunderstrike"] = {
        rev = "x", ts = {}, hash = 5, manual = 3, bank = "b",
        data = { v = "1", cl = 5, sp = "SomeVeryLongSpecNameThatIsWayTooLong", ob = "o", eq = 9,
                 ph = { [9] = { [1] = { 1, 2 } }, [1] = { [99] = { 30000, 0 }, [1] = { "x", 5 }, [2] = { 0, 0 },
                        [3] = { 29076, 29076 } }, [2] = "bad" } } } } }""")
    c.load_addon()
    w.tick(5)
    rec = c.eval_py("return ns.BiS:GetRecord()")
    assert rec["rev"] == 0 and rec["hash"] == "" and rec["manual"] == {} and rec["bank"] == {}, rec
    d = rec["data"]
    assert d["cl"] == "PALADIN" and len(d["sp"]) <= 24, d
    keys = c.eval_py("local t = {} for p in pairs(ns.BiS:GetData().ph) do t[#t+1] = p end table.sort(t) return t")
    assert keys == [1], keys
    sids = c.eval_py("local t = {} for s in pairs(ns.BiS:GetData().ph[1]) do t[#t+1] = s end table.sort(t) return t")
    assert sids == [1, 3], sids
    # {"x", 5} -> main invalid (0) but alt 5 kept; {29076, 29076} -> alt dropped (same as main)
    assert c.eval_py("local s = ns.BiS:GetData().ph[1][1]; return {s[1], s[2]}") == [0, 5]
    assert c.eval_py("local s = ns.BiS:GetData().ph[1][3]; return {s[1], s[2]}") == [29076, 0]
    c.slash("/dz")
    w.tick(1)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "home"
    c.slash("/dz bis")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "mybis"
    no_errors(w)


@case
def not_in_guild_boot_is_quiet():
    w, c = solo("Solo", guild=None, tick=60)
    assert c.eval("return ns.Guild:IsReady()") is False
    assert c.eval("return ns.Guild:AmICouncil()") is False
    assert c.eval("return ns.Sync:GetStatusText()") == "Not in a guild"
    assert [e for e in w.addon_log if e["sender"] == c.full_name] == [], "a guildless client sent addon messages"
    c.relog()
    w.tick(30)
    no_errors(w)


@case
def window_positions_saved_and_restored():
    w, c = solo("Alice", guild_rank=3, tick=3)
    c.slash("/dz")
    w.tick(0.2)
    c.eval("""
      local f = DisasterZoneMainFrame
      __MOCK.call_script(f, 'OnDragStart')
      f:ClearAllPoints(); f:SetPoint('TOPLEFT', UIParent, 'TOPLEFT', 123.4, -56.6)
      __MOCK.call_script(f, 'OnDragStop')""")
    assert c.eval_py("return DisasterZoneDB.settings.windows.DisasterZoneMainFrame") == ["TOPLEFT", "TOPLEFT", 123, -57]
    c.relog()
    w.tick(2)
    c.slash("/dz")
    w.tick(0.2)
    assert c.eval_py("local p, rel, rp, x, y = DisasterZoneMainFrame:GetPoint(1); return { p, rp, x, y }") == ["TOPLEFT", "TOPLEFT", 123, -57]
    # the picker never saves its position; every DisasterZone window closes with Escape
    specials = c.eval_py("return UISpecialFrames")
    assert "DisasterZoneMainFrame" in specials
    no_errors(w)


@case
def late_load_after_login_runs_both_stages():
    # Loaded after PLAYER_LOGIN (load-on-demand / enabled mid-session): ADDON_LOADED must run OnInit AND OnLogin.
    w = World()
    c = Client(w, "Alice", guild_rank=1, preload_lua=LIFECYCLE_PRELOAD)
    headers, files = c.toc()
    c.M.set_toc_meta("DisasterZone", c._to_lua(headers))
    c.eval("__MOCK.logged_in = true")             # the player is already in the world
    c.load_files(files)
    # SavedVariables are assigned right before ADDON_LOADED: a stored guild council list (Addendum E) naming
    # Alice, guild phase 2
    c.eval("""DisasterZoneDB = { council = { guild = { rev = 1789900000, members = { ['Alice-Thunderstrike'] = true },
      phase = 2, recvAt = GetServerTime() } } }""")
    c.M.addon_loaded("DisasterZone")                    # no PLAYER_LOGIN follows
    w.tick(3)
    assert c.eval("return ns.loggedIn") is True
    calls = c.eval_py("return __LC.calls")
    assert [x for x in calls if x[1] == "OnLogin"], "OnLogin never ran for a late load"
    assert c.eval("return ns.Guild:IsReady()") is True
    assert c.eval("return ns.Guild:GetGuildPhase()") == 2
    assert c.eval("return LibDBIcon10_DisasterZone ~= nil") is True
    c.slash("/dz council")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "council"
    lines = c.show_tooltip_item(28770)
    no_errors(w)


if __name__ == "__main__":
    run_all()

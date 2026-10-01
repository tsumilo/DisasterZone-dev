"""Moving from CDLoot (the addon's name before 0.12) to DisasterZone: Core/Boot.lua, "Moving from CDLoot".

DisasterZone is a new addon folder with its own saved-variables file. While the old addon is loaded (both folders
installed) DisasterZone must not run at all, and offers to copy CDLootDB into DisasterZoneDB, switch CDLoot off and
reload. Covers: the dormant session, the import at the click, "Later", data that changed between login and click,
an existing DisasterZoneDB (never overwritten unasked), /dzpatch import, CDLoot installed but switched off, a
client that loads saved variables after the files, detection without C_AddOns, and the legacy DisableAddOn.

The old addon is simulated the way the client presents it to us: IsAddOnLoaded("CDLoot") is true and its saved
variable CDLootDB is a global that exists before our first file runs (Client.other_addons / Client.other_saved).

Run: luaenv\\Scripts\\python.exe tests\\migrate\\test_migrate.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import case, run_all, no_errors, World, Client, printed_since, strip_codes  # noqa: E402

OLD = "CDLoot"
DIALOG = "DisasterZoneBootDialog"


def old_data():
    """Saved data as a real session leaves it (the schema did not change with the rename), plus markers."""
    w = World()
    c = Client(w, "Alice", guild_rank=3)
    c.load_addon()
    w.tick(2)
    c.eval("""
      DisasterZoneDB.settings.debug = true
      DisasterZoneDB.games = DisasterZoneDB.games or {}
      DisasterZoneDB.games.azeromon = { save = { name = "Ash", party = { { id = 7, lvl = 12 } } } }
      DisasterZoneDB.marker = { 1, 2, { deep = "yes" } }""")
    src = c.saved_variables()["DisasterZoneDB"]
    assert "migratedFrom" not in src
    return src


def both(db=None, dz=None, loaded=True, **kw):
    """A client with the old addon loaded (or only installed) next to DisasterZone. db: CDLootDB source;
    dz: an existing DisasterZoneDB source."""
    w = World()
    c = Client(w, "Alice", guild_rank=3, other_addons=[OLD] if loaded else [], **kw)
    if db is not None and loaded:
        c.other_saved["CDLootDB"] = db
    if dz is not None:
        c.set_saved_variable("DisasterZoneDB", dz)
    return w, c


def start(w, c):
    c.load_addon()
    w.tick(2)
    return c


def dialog(c):
    """(shown, text, accept label)"""
    if not c.eval("return %s ~= nil and %s:IsShown()" % (DIALOG, DIALOG)):
        return False, None, None
    return True, c.eval("return %s.text:GetText()" % DIALOG), c.eval("return %s.accept:GetText()" % DIALOG)


def press(c, which):
    c.eval("%s.%s:GetScript('OnClick')(%s.%s, 'LeftButton')" % (DIALOG, which, DIALOG, which))


def disabled(c):
    return bool(c.eval("local M = ...; return M.disabled_addons and M.disabled_addons.CDLoot or false", c.M))


def reload_asked(c):
    return bool(c.M.reload_requested)


def dormant(c):
    return bool(c.eval("return DisasterZoneBoot.dormant")) and c.eval("return ns.MainFrame == nil and DisasterZone == nil")


def after_reload(c, old_still_on=False):
    """The reload the dialog asked for; the old addon is gone unless old_still_on."""
    if not old_still_on:
        c.other_addons = []
        c.other_saved = {}
    c.relog()
    c.world.tick(2)
    return c


@case
def without_cdloot_nothing_changes():
    w, c = both(loaded=False)
    start(w, c)
    assert not c.eval("return DisasterZoneBoot.dormant")
    assert c.eval("return DisasterZoneBoot.state") in ("none", "applied")     # applied: tools/patched_run.py
    assert dialog(c)[0] is False
    assert c.eval("return DisasterZoneDB.migratedFrom") is None
    assert c.slash("/dz") is True and c.slash("/cdl") is True, "the old slash command is an alias"
    assert not any(OLD in strip_codes(l) for l in printed_since(c, 0)), printed_since(c, 0)
    no_errors(w)


@case
def with_cdloot_loaded_nothing_of_disasterzone_runs():
    src = old_data()
    w, c = both(src)
    start(w, c)
    assert dormant(c)
    assert c.eval("return DisasterZoneBoot.state") == "dormant"
    assert c.slash("/dz") is False and c.slash("/cdl") is False, "the main slash command belongs to CDLoot now"
    assert c.eval("return DisasterZoneDB") is None, "nothing is written before the click"
    assert c.eval("return C_ChatInfo.IsAddonMessagePrefixRegistered('CDLc')") in (False, None), "no comm in a dormant session"
    shown, text, accept = dialog(c)
    assert shown and accept == "Import + reload", (shown, accept)
    assert "CDLoot is now called DisasterZone" in text and "backup" in text, text
    lines = [strip_codes(l) for l in printed_since(c, 0)]
    assert any("CDLoot is now called DisasterZone" in l for l in lines), lines
    assert not disabled(c) and not reload_asked(c)
    no_errors(w)


@case
def import_copies_everything_switches_cdloot_off_and_reloads():
    src = old_data()
    w, c = both(src)
    c.other_saved["CDLootPatchDB"] = '{ active = { seq = 99, version = "0.11.9" } }'
    start(w, c)
    before = c.eval_py("return CDLootDB")
    press(c, "accept")
    assert disabled(c), "CDLoot was not switched off"
    assert reload_asked(c), "no reload"
    got = c.eval_py("return DisasterZoneDB")
    stamp = got.pop("migratedFrom")
    assert stamp["addon"] == OLD and stamp["at"] > 0, stamp
    assert got == before, "the copy differs from CDLootDB"
    assert c.eval("return DisasterZoneDB ~= CDLootDB and DisasterZoneDB.marker ~= CDLootDB.marker"), "not a deep copy"
    assert c.eval_py("return CDLootDB") == before, "CDLootDB was changed"
    assert c.eval("return CDLootDB.migratedFrom") is None
    assert c.eval("return CDLootPatchDB.active.seq") == 99
    assert c.eval("return (DisasterZonePatchDB.active or {}).seq") != 99, "the old stored update must not come along"

    after_reload(c)
    assert not c.eval("return DisasterZoneBoot.dormant")
    assert dialog(c)[0] is False
    assert c.eval("return ns.db == DisasterZoneDB and ns.db.settings.debug") is True
    assert c.eval("return ns.db.games.azeromon.save.name") == "Ash"
    assert c.eval("return ns.db.marker[3].deep") == "yes"
    assert c.eval("return ns.db.migratedFrom.addon") == OLD
    lines = [strip_codes(l) for l in printed_since(c, 0)]
    told = [l for l in lines if "CDLoot data was imported" in l]
    assert len(told) == 1, lines
    assert c.slash("/dz") is True
    no_errors(w)

    n0 = len(c.chat_frame)
    after_reload(c)
    assert not any("imported" in strip_codes(l) for l in printed_since(c, n0)), "the note is said once"
    assert c.eval("return ns.db.games.azeromon.save.name") == "Ash"
    no_errors(w)


@case
def later_copies_nothing_and_asks_again_next_time():
    src = old_data()
    w, c = both(src)
    start(w, c)
    press(c, "cancel")
    assert dialog(c)[0] is False
    assert c.eval("return DisasterZoneDB") is None and not disabled(c) and not reload_asked(c)
    assert c.slash("/dzpatch") is True
    assert dialog(c)[0] is True, "/dzpatch brings the question back"
    press(c, "cancel")
    after_reload(c, old_still_on=True)
    assert "DisasterZoneDB" not in w.saved[c.full_name], "a dormant session must not create saved data"
    assert dormant(c)
    assert dialog(c)[1] is not None and dialog(c)[2] == "Import + reload"
    no_errors(w)


@case
def the_copy_is_made_at_the_click_not_at_login():
    src = old_data()
    w, c = both(src)
    start(w, c)
    c.eval("CDLootDB.lateEdit = { 'written by CDLoot after login' }")
    press(c, "accept")
    assert c.eval("return DisasterZoneDB.lateEdit[1]") == "written by CDLoot after login"
    c.eval("CDLootDB.lateEdit[1] = 'changed after the copy'")
    assert c.eval("return DisasterZoneDB.lateEdit[1]") == "written by CDLoot after login"
    no_errors(w)


@case
def existing_disasterzone_data_is_never_overwritten_unasked():
    src = old_data()
    mine = '{ schema = 1, settings = { debug = false }, marker = { "mine" } }'
    w, c = both(src, dz=mine)
    start(w, c)
    assert dormant(c), "the two must not run together even when nothing is imported"
    shown, text, accept = dialog(c)
    assert shown and accept == "Switch off + reload", (shown, accept)
    assert "still switched on" in text and "AddOns list" in text, text
    assert c.eval("return DisasterZoneBoot.ImportOld()") == (False, "hasdata")
    press(c, "accept")
    assert disabled(c) and reload_asked(c)
    assert c.eval("return DisasterZoneDB.marker[1]") == "mine" and c.eval("return DisasterZoneDB.migratedFrom") is None
    after_reload(c)
    assert c.eval("return ns.db.marker[1]") == "mine"
    no_errors(w)


@case
def dzpatch_import_replaces_existing_data_on_request():
    src = old_data()
    w, c = both(src, dz='{ schema = 1, marker = { "mine" } }')
    start(w, c)
    press(c, "cancel")
    n0 = len(c.chat_frame)
    assert c.slash("/dzpatch import") is True
    assert any("copied your CDLoot data" in strip_codes(l) for l in printed_since(c, n0)), printed_since(c, n0)
    assert c.eval("return DisasterZoneDB.marker[3].deep") == "yes"
    shown, text, accept = dialog(c)
    assert shown and accept == "Switch off + reload" and "is copied" in text, (shown, accept, text)
    assert not reload_asked(c), "the reload waits for the click"
    press(c, "accept")
    assert disabled(c) and reload_asked(c)
    after_reload(c)
    assert c.eval("return ns.db.games.azeromon.save.name") == "Ash"
    no_errors(w)


@case
def dzpatch_import_without_cdloot_explains():
    w, c = both(loaded=False)
    start(w, c)
    c.eval("DisasterZoneDB.marker = 'kept'")
    n0 = len(c.chat_frame)
    c.slash("/dzpatch import")
    assert any("import needs CDLoot switched on" in strip_codes(l) for l in printed_since(c, n0)), printed_since(c, n0)
    assert c.eval("return DisasterZoneDB.marker") == "kept" and dialog(c)[0] is False
    no_errors(w)


@case
def cdloot_loaded_but_without_saved_data():
    w, c = both(None)
    start(w, c)
    assert dormant(c)
    shown, text, accept = dialog(c)
    assert shown and accept == "Switch off + reload", (shown, accept)
    n0 = len(c.chat_frame)
    c.slash("/dzpatch import")
    assert any("no saved data to import" in strip_codes(l) for l in printed_since(c, n0)), printed_since(c, n0)
    assert c.eval("return DisasterZoneDB") is None
    no_errors(w)


@case
def cdloot_installed_but_switched_off_gets_one_hint():
    w, c = both(loaded=False)
    c.eval("local M = ...; M.set_toc_meta('CDLoot', { title = 'CDLoot', version = '0.11.0' })", c.M)
    start(w, c)
    assert not c.eval("return DisasterZoneBoot.dormant")
    hints = [l for l in printed_since(c, 0) if "installed but switched off" in strip_codes(l)]
    assert len(hints) == 1 and "/dzpatch import" in strip_codes(hints[0]), printed_since(c, 0)
    n0 = len(c.chat_frame)
    c.relog()
    c.eval("local M = ...; M.set_toc_meta('CDLoot', { title = 'CDLoot', version = '0.11.0' })", c.M)
    w.tick(2)
    assert not any("installed but switched off" in strip_codes(l) for l in printed_since(c, n0)), "hint repeats"
    no_errors(w)


@case
def saved_variables_after_the_files_still_never_overwrites():
    """A client that ignores LoadSavedVariablesFirst: DisasterZoneDB does not exist at file time."""
    src = old_data()
    w, c = both(src, dz='{ schema = 1, marker = { "mine" } }', sv_before_files=False)
    start(w, c)
    assert dormant(c)
    assert dialog(c)[2] == "Switch off + reload", dialog(c)
    press(c, "accept")
    assert c.eval("return DisasterZoneDB.marker[1]") == "mine"
    w2, c2 = both(src, sv_before_files=False)
    start(w2, c2)
    assert dialog(c2)[2] == "Import + reload", dialog(c2)
    press(c2, "accept")
    assert c2.eval("return DisasterZoneDB.games.azeromon.save.name") == "Ash"
    no_errors(w)
    no_errors(w2)


@case
def detection_and_switch_off_without_c_addons():
    """Older API surface: no C_AddOns at all. The old addon's globals give it away; DisableAddOn is the global."""
    src = old_data()
    w = World()
    c = Client(w, "Alice", guild_rank=3)
    c.other_saved["CDLootDB"] = src
    c.eval("""
      CDLootBoot = {}
      __disabled = {}
      C_AddOns.IsAddOnLoaded, C_AddOns.DisableAddOn, C_AddOns.DoesAddOnExist = nil, nil, nil
      IsAddOnLoaded = function() return false end
      DisableAddOn = function(name, character) __disabled[#__disabled + 1] = { name, character } end""")
    start(w, c)
    assert dormant(c)
    assert dialog(c)[2] == "Import + reload", dialog(c)
    press(c, "accept")
    assert c.eval_py("return __disabled") == [[OLD, True]], c.eval_py("return __disabled")
    assert reload_asked(c) and c.eval("return DisasterZoneDB.migratedFrom.addon") == OLD
    no_errors(w)


@case
def a_failing_switch_off_still_imports_and_reloads():
    src = old_data()
    w, c = both(src)
    c.eval("C_AddOns.DisableAddOn = function() error('blocked') end")
    start(w, c)
    press(c, "accept")
    assert reload_asked(c) and c.eval("return DisasterZoneDB.games.azeromon.save.name") == "Ash"
    after_reload(c, old_still_on=True)          # CDLoot is still ticked: no second import, a clear message
    assert dormant(c)
    shown, text, accept = dialog(c)
    assert accept == "Switch off + reload" and "untick it in the AddOns list" in text, (accept, text)
    assert c.eval("return DisasterZoneDB.games.azeromon.save.name") == "Ash"
    no_errors(w)


@case
def odd_values_in_the_old_data_do_not_break_the_copy():
    w, c = both('{ schema = 1, a = { 1, 2 } }')
    start(w, c)
    c.eval("""
      CDLootDB.loop = { name = "loop" }; CDLootDB.loop.self = CDLootDB.loop
      CDLootDB.shared1 = CDLootDB.a; CDLootDB.shared2 = CDLootDB.a
      CDLootDB.fn = function() end
      CDLootDB[true] = "bool key"; CDLootDB[{}] = "table key"; CDLootDB[1.5] = "float key\"""")
    press(c, "accept")
    assert c.eval("return DisasterZoneDB.loop.self == DisasterZoneDB.loop and DisasterZoneDB.loop ~= CDLootDB.loop")
    assert c.eval("return DisasterZoneDB.shared1 == DisasterZoneDB.shared2 and DisasterZoneDB.shared1 == DisasterZoneDB.a")
    assert c.eval("return DisasterZoneDB.fn") is None
    assert c.eval("return DisasterZoneDB[true]") == "bool key" and c.eval("return DisasterZoneDB[1.5]") == "float key"
    assert c.eval("local n = 0; for k in pairs(DisasterZoneDB) do if type(k) == 'table' then n = n + 1 end end; return n") == 0
    no_errors(w)


if __name__ == "__main__":
    run_all()

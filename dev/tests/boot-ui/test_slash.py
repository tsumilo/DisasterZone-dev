"""Every /cdl subcommand: (empty), help, ?, unknown, debug, version, demo, test, drop, drops, roll, sync, council,
log, settings, config; the /cdloot alias; odd spacing and casing.

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_slash.py
"""
from _common import (case, run_all, solo, no_errors, World, Client, install_helpers, printed_since, strip_codes,
                     seed_guild_council)

# Addendum E removed "/cdl guildinfo"; Addendum D added "/cdl rules".
# Addendum F §38 added "lock" / "unlock" (raid BiS list lock).
SUBCOMMANDS = ["config", "council", "debug", "demo", "drop", "drops", "dungeon", "lock", "log", "roll", "rules",
               "settings", "sync", "test", "unlock", "version"]


def said(c, n0):
    return [strip_codes(l) for l in printed_since(c, n0)]


@case
def empty_toggles_window_and_alias_works():
    w, c = solo("Alice", guild_rank=3, tick=3)
    assert c.slash("/cdl") is True
    assert c.eval("return ns.MainFrame:IsShown()") is True
    c.slash("/cdl")
    assert c.eval("return ns.MainFrame:IsShown()") is False
    assert c.slash("/cdloot") is True
    assert c.eval("return ns.MainFrame:IsShown()") is True
    c.slash("/CDLOOT")
    assert c.eval("return ns.MainFrame:IsShown()") is False
    c.slash("/cdl    settings   ")
    w.tick(0.2)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "settings"
    c.slash("/cdl CONFIG")
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "settings"
    no_errors(w)


@case
def help_lists_every_subcommand_and_unknown_prints_help():
    w, c = solo("Alice", guild_rank=3, tick=3)
    for cmd in ("/cdl help", "/cdl ?", "/cdl HELP"):
        n0 = len(c.chat_frame)
        c.slash(cmd)
        lines = said(c, n0)
        assert lines[0] == "CDLoot: commands (/cdl or /cdloot):", lines
        assert lines[1].startswith("  /cdl - open or close"), lines
        listed = [l.split()[1] for l in lines[2:]]
        assert listed == SUBCOMMANDS, listed
        assert all(" - " in l for l in lines[2:]), "a subcommand has no help text: %r" % lines
    n0 = len(c.chat_frame)
    c.slash("/cdl frobnicate now")
    lines = said(c, n0)
    assert lines[0] == "CDLoot: unknown command 'frobnicate'.", lines
    assert "CDLoot: commands (/cdl or /cdloot):" in lines
    assert c.eval("return ns.MainFrame:IsShown()") is False
    no_errors(w)


@case
def debug_toggle_and_debug_output():
    w, c = solo("Alice", guild_rank=3, tick=3)
    n0 = len(c.chat_frame)
    c.slash("/cdl debug")
    assert c.eval("return ns.db.settings.debug") is True
    assert "CDLoot: debug output enabled." in said(c, n0)
    n1 = len(c.chat_frame)
    c.eval("ns:Debug('probe %d', 42)")
    assert "CDLoot: [debug] probe 42" in said(c, n1)
    c.slash("/cdl debug")
    assert c.eval("return ns.db.settings.debug") is False
    n2 = len(c.chat_frame)
    c.eval("ns:Debug('hidden')")
    assert said(c, n2) == []
    no_errors(w)


@case
def version_lists_peers():
    w = World()
    seed_guild_council(w, ["Alice"])        # Addendum E: Alice is on the GM's guild council list
    a = Client(w, "Alice", guild_rank=1)
    b = Client(w, "Bob", guild_rank=3)
    for x in (a, b):
        x.load_addon()
    w.tick(40)                       # both HELLOs exchanged
    n0 = len(a.chat_frame)
    a.slash("/cdl version")
    lines = said(a, n0)
    # (the TOC version: 0.6.0)
    assert lines[0] == "CDLoot: CDLoot 0.6.0 (protocol 1). Addon users seen: 1", lines
    assert any(l.strip().startswith("Alice  0.6.0  (online, council)") for l in lines), lines
    assert any(l.strip().startswith("Bob  0.6.0  (online") for l in lines), lines
    # guildless: only me
    w2, s = solo("Solo", guild=None, tick=2)
    n0 = len(s.chat_frame)
    s.slash("/cdl version")
    assert said(s, n0)[0] == "CDLoot: CDLoot 0.6.0 (protocol 1). Addon users seen: 0"
    no_errors(w)
    no_errors(w2)


@case
def demo_on_off_toggle_forms():
    w, c = solo("Alice", guild_rank=3, tick=3)
    for arg, want in (("on", True), ("off", False), ("1", True), ("0", False), ("", True), ("", False),
                      ("ON", True), ("Off", False)):
        n0 = len(c.chat_frame)
        c.slash(("/cdl demo " + arg).strip())
        assert c.eval("return ns.Demo:IsEnabled()") is want, (arg, want)
        lines = said(c, n0)
        if want:
            assert lines and lines[0].startswith("CDLoot: demo mode on: 18 fake guild members"), lines
        else:
            assert lines == ["CDLoot: demo mode off."], lines
    no_errors(w)


@case
def test_and_drops_and_drop():
    w, c = solo("Alice", guild_rank=3, tick=3)
    install_helpers(c)
    n0 = len(c.chat_frame)
    c.slash("/cdl drops")
    assert said(c, n0) == ["CDLoot: No boss drops recorded in the last 24 hours."], said(c, n0)
    c.slash("/cdl test")
    w.tick(0.5)
    lines = said(c, n0)
    assert any(l.startswith("CDLoot: Simulated a drop from ") for l in lines), lines
    assert c.eval("return #ns.Loot:GetHistory()") == 1
    # a raider gets no council drop panel
    assert c.eval("return CDLootDropPanel ~= nil and CDLootDropPanel:IsShown()") in (False, None)
    n1 = len(c.chat_frame)
    c.slash("/cdl drops")
    assert not any("No boss drops" in l for l in said(c, n1))
    # /cdl drop: a raider not leading the raid is refused; council gets usage / a drop
    n2 = len(c.chat_frame)
    c.slash("/cdl drop |cffa335ee|Hitem:28770::::::::70:::::::::|h[Nathrezim Mindblade]|h|r")
    assert said(c, n2) == ["CDLoot: Only loot council members or the raid leader / assistants can announce drops."]
    w2 = World()
    seed_guild_council(w2, ["Cou"])
    cou = Client(w2, "Cou", guild_rank=1)
    rai = Client(w2, "Rai", guild_rank=3)
    for x in (cou, rai):
        x.load_addon()
    w2.tick(3)
    w2.make_raid([cou, rai])
    w2.tick(1)
    n3 = len(cou.chat_frame)
    cou.slash("/cdl drop")
    assert said(cou, n3) == ["CDLoot: Usage: /cdl drop [item link] [item link] ... (shift-click items into the command)"], said(cou, n3)
    m0 = len(w2.addon_log)
    cou.slash("/cdl drop |cffa335ee|Hitem:28770::::::::70:::::::::|h[Nathrezim Mindblade]|h|r")
    w2.tick(1)
    assert cou.eval("return #ns.Loot:GetHistory()") == 1
    sent = [e for e in w2.addon_log[m0:] if e["sender"] == cou.full_name]
    assert len(sent) == 1 and sent[0]["chat_type"] == "RAID" and sent[0]["prefix"] == "CDLa", sent
    assert rai.eval("return #ns.Loot:GetHistory()") == 1, "raider did not receive the drop"
    no_errors(w)
    no_errors(w2)


@case
def roll_usage_permission_demo_and_end():
    w, c = solo("Alice", guild_rank=3, tick=3)
    link = "|cffa335ee|Hitem:28770::::::::70:::::::::|h[Nathrezim Mindblade]|h|r"
    n0 = len(c.chat_frame)
    c.slash("/cdl roll")
    assert said(c, n0)[0].startswith("CDLoot: Usage: /cdl roll [item link]"), said(c, n0)
    n1 = len(c.chat_frame)
    c.slash("/cdl roll " + link)
    assert said(c, n1) == ["CDLoot: Only loot council members, the master looter or the raid leader / assistants can start rolls, in a raid."]
    n2 = len(c.chat_frame)
    c.slash("/cdl roll end")
    assert said(c, n2) == ["CDLoot: No roll is running."]
    # demo: allowed, local only
    c.slash("/cdl demo on")
    m0 = len(w.addon_log)
    c.slash("/cdl roll " + link)
    w.tick(0.5)
    active = c.eval_py("local s = ns.Roll:GetActive(); return s and { s.i, s.state }")
    assert active == [28770, "open"], active
    c.slash("/cdl roll 28770")        # a bare item id also works; queued behind the open one
    c.slash("/cdl roll stop")
    w.tick(3)
    assert c.eval("local s = ns.Roll:GetActive(); return s and s.state") in (None, "open")
    assert [e for e in w.addon_log[m0:] if e["sender"] == c.full_name] == [], "demo roll sent addon messages"
    w.tick(60)
    no_errors(w)


@case
def sync_before_roster_ok_and_rate_limited():
    w = World(roster_delay=5)
    c = Client(w, "Alice", guild_rank=3)
    c.load_addon()
    # the harness serves the roster right after the addon asks for it; block that to test the early path
    c.eval("__MOCK.guild_loaded = false")
    c.eval("ns.Guild.RequestRoster = function() return false end")
    n0 = len(c.chat_frame)
    c.slash("/cdl sync")
    lines = said(c, n0)
    assert c.eval("return ns.Guild:IsReady()") is False
    assert lines == ["CDLoot: Waiting for the guild roster; try again in a moment."], lines
    w.tick(30)
    assert c.eval("return ns.Guild:IsReady()") is True
    w.tick(30)                        # automatic HELLO + rate window over
    m0, n1 = len(w.addon_log), len(c.chat_frame)
    c.slash("/cdl sync")
    w.tick(0.5)
    assert said(c, n1) == ["CDLoot: Sync requested."], said(c, n1)
    assert len([e for e in w.addon_log[m0:] if e["sender"] == c.full_name]) == 1
    n2 = len(c.chat_frame)
    c.slash("/cdl sync")
    assert said(c, n2) == ["CDLoot: A sync was requested less than 30 seconds ago; please wait."], said(c, n2)
    no_errors(w)


@case
def council_log_settings_open_their_tabs():
    w, c = solo("Cou", guild_rank=1, tick=3, council=["Cou"])
    for cmd, tab in (("council", "council"), ("log", "loot"), ("settings", "settings"), ("config", "settings")):
        c.slash("/cdl " + cmd)
        w.tick(0.3)
        assert c.eval("return ns.MainFrame:GetSelectedTab()") == tab, (cmd, tab)
        assert c.eval("return ns.MainFrame:GetPanel(...):IsVisible()", tab) is True
    no_errors(w)


if __name__ == "__main__":
    run_all()

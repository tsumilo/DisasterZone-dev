"""Broad multi-client UI scenario (GM + officer + two raiders) that touches every tab and window, then prints
world.report() and checks the unknown template fields / methods the addon relies on. Also the main window's
background build of every page after it first opens: the harness leaves that off elsewhere (World(prebuild_pages)).

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_broad.py
"""
from _common import case, run_all, no_errors, World, Client, install_helpers, strip_codes, gm_pick

# Template children the addon reads that the mock does not model (and that are expected to be nil-guarded).
# Anything else showing up in report_unknown_fields() is reported as a failure of this test.
KNOWN_OK_FIELDS = set()


def built_pages(c):
    return set(c.eval_py("""
      local out = {}
      for _, p in ipairs(ns.MainFrame:GetPageStats()) do if p.panel then out[#out + 1] = p.key end end
      return out""") or [])


@case
def opening_the_window_builds_every_other_page_in_the_background():
    # the game's way (the harness leaves it off unless asked: World(prebuild_pages=True)): after the window first
    # opens, every page the player can open is built (and the heavy ones painted once), one per frame, quietly
    w = World(prebuild_pages=True)
    gm = Client(w, "Gm", guild_rank=0, class_file="WARRIOR", talents=(0, 5, 51))
    gm.load_addon()
    w.tick(3)
    gm.slash("/dz")
    w.tick(0.1)
    first = built_pages(gm)
    w.tick(10)
    built = built_pages(gm)
    assert len(first) == 1 and len(built) > 15, (first, built)
    # nothing is left for a first visit: opening every page builds no other
    keys = gm.eval_py("local out = {} for _, p in ipairs(ns.MainFrame:GetPageStats()) do out[#out + 1] = p.key end "
                      "return out")
    for key in keys:
        gm.eval("ns.MainFrame:Open(...)", key)
        w.tick(0.1)
    assert built_pages(gm) == built, sorted(built_pages(gm) - built)
    no_errors(w)
    # the harness's default: a page is built when it is first shown
    w2 = World()
    c = Client(w2, "Gm", guild_rank=0, class_file="WARRIOR", talents=(0, 5, 51))
    c.load_addon()
    w2.tick(3)
    c.slash("/dz")
    w2.tick(10)
    assert built_pages(c) == first, built_pages(c)
    no_errors(w2)


@case
def broad_session_all_windows_then_report():
    w = World(prebuild_pages=True)    # (as in the game: every page built in the background too)
    gm = Client(w, "Gm", guild_rank=0, class_file="WARRIOR", talents=(0, 5, 51))
    off = Client(w, "Off", guild_rank=1, class_file="PRIEST", talents=(10, 41, 0))
    r1 = Client(w, "Rai", guild_rank=3, class_file="MAGE", talents=(0, 0, 41))
    r2 = Client(w, "Rog", guild_rank=3, class_file="ROGUE", talents=(20, 41, 0))
    for c in w.clients:
        c.load_addon()
    w.tick(3)
    gm_pick(w, gm, ["Off"])          # Addendum E: the GM picks the officer for the loot council (CG)
    for c in w.clients:
        install_helpers(c)
    # raiders build lists through the UI (picker) and they sync to the council
    for c in (r1, r2):
        c.slash("/dz bis")
        w.tick(0.2)
        for sid in (1, 2, 3, 5, 11, 13, 15):
            c.click(c.eval("local s = ...; return T_tile(s).main", sid))
            row = c.eval("""
              for _, r in ipairs(T_rows(T_box(DisasterZonePicker))) do
                local d = rawget(r, '__cdlData')
                if d and d.type == 'item' then return r end
              end""")
            c.click(row)
        c.slash("/dz")        # closing commits
    w.tick(60)
    for c in (gm, off):
        keys = c.eval_py("return ns.Store:GetAllKeys()")
        assert "Rai-Thunderstrike" in keys and "Rog-Thunderstrike" in keys, (c.full_name, keys)
    # raid night
    w.make_raid([gm, off, r1, r2], master_looter=gm)
    w.enter_instance("Karazhan", 532)
    w.encounter(661, "Prince Malchezaar")
    w.tick(1)
    wanted = r1.eval("return ns.BiS:GetSlot(1, 1)")
    gm.open_loot([(28770, 4), (28762, 4)])
    w.tick(2)
    assert gm.eval("return DisasterZoneDropPanel ~= nil and DisasterZoneDropPanel:IsShown()") is True
    # every tab on every client
    for c in w.clients:
        for cmd in ("/dz council", "/dz log", "/dz settings", "/dz"):
            c.slash(cmd)
            w.tick(0.3)
        c.slash("/dz")
        w.tick(0.2)
        if c.eval("return ns.Guild:AmICouncil()"):
            for view in ("items", "member", "council", "roster"):
                c.slash("/dz council")
                c.eval("ns.CouncilUI:SetView(...)", view)
                w.tick(0.3)
            rows = c.eval("return #T_rows(DisasterZoneCouncilPanel.rosterView.list.box)")
            for i in range(1, rows + 1):
                c.hover(c.eval("local i = ...; return T_rows(DisasterZoneCouncilPanel.rosterView.list.box)[i].cells[1]", i))
        for item in (28770, 28762, 32385, wanted or 28770):
            c.show_tooltip_item(item)
    # a roll from the drop panel item, raiders roll through the popup
    gm.eval("ns.Roll:Start(28770, ns.Loot:GetHistory()[#ns.Loot:GetHistory()])")
    w.tick(1)
    for c in (off, r1, r2):
        if c.eval("return DisasterZoneRollFrame ~= nil and DisasterZoneRollFrame:IsShown()"):
            btn = c.eval("return T_button(DisasterZoneRollFrame, 'Roll')")
            if btn:
                c.click(btn)
    w.tick(40)
    # the award dialog and the log
    gm.slash("/dz log")
    w.tick(0.3)
    gm.click(gm.eval("return DisasterZoneLootLogPanel.addBtn"))
    gm.type_text(gm.eval("return DisasterZoneAwardDialog.itemBox"), "28762")
    gm.type_text(gm.eval("return DisasterZoneAwardDialog.winBox"), "rog")
    gm.click(gm.eval("return DisasterZoneAwardDialog.saveBtn"))
    w.tick(2)
    assert off.eval("return #ns.Ledger:GetEntries({})") >= 1, "award not synced to the officer"
    # demo on/off on the officer, settings editor on the GM
    off.slash("/dz demo on")
    off.slash("/dz council")
    w.tick(0.5)
    off.slash("/dz demo off")
    gm.slash("/dz settings")
    w.tick(0.5)
    gm.close_loot()
    w.tick(1)
    # everyone reloads
    for c in list(w.clients):
        c.relog()
    w.tick(30)
    for c in w.clients:
        install_helpers(c)
        c.slash("/dz")
        w.tick(0.2)
    rep = w.report()
    print(rep)
    print("== unknown fields incl. lowercase ==")
    print(w.report_unknown_fields(lowercase=True))
    no_errors(w)
    fields = w.report_unknown_fields()
    unknown = [l for l in fields.splitlines() if l and not l.startswith("(")]
    assert not [l for l in unknown if l.split()[1].lstrip(".") not in KNOWN_OK_FIELDS], unknown
    methods = w.report_unknown_methods()
    assert methods == "(no unknown method calls)", methods


if __name__ == "__main__":
    run_all()

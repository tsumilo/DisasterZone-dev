"""Demo mode on/off repeatedly: nothing leaks into DisasterZoneDB (lists, ledger, peers, dropHistory, SavedVariables
text) and no addon message is sent; real data is hidden while demo is on and comes back afterwards.

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_demo.py
"""
from _common import (case, run_all, solo, no_errors, World, Client, install_helpers, menu_texts, menu_find,
                     printed_since, strip_codes, plain, seed_guild_council)

FAKE = ["Aldrin", "Brakka", "Caelith", "Dornoth", "Elowen", "Faelar", "Grimtusk", "Halvard", "Isolde", "Jorvik",
        "Kaelyn", "Lorvane", "Mirabel", "Nortok", "Orinel", "Pyria", "Quillon", "Rhosyn"]

SUB_SELECT = r"""
function T_menu_sub_select(subText, text)
  local function find(d, t)
    for _, ch in ipairs(d.children) do
      if ch.text == t then return ch end
      local r = find(ch, t)
      if r then return r end
    end
  end
  return __MOCK.menu_select(text, find(__MOCK.last_menu, subText))
end
"""


def snapshot(c):
    db = plain(c.eval_py("return DisasterZoneDB"))
    db.get("guildCfg", {}).pop("fetchedAt", None)
    for p in (db.get("peers") or {}).values():
        if isinstance(p, dict):
            p.pop("lastSeen", None)
    db.get("settings", {}).pop("windows", None)     # window positions may legitimately be saved
    db.get("settings", {}).pop("navLast", None)     # (the page used last in a nav group: a UI preference)
    return db


def sv_text(c):
    # the addon's data; DisasterZonePatchDB may hold source code (an in-game update), which names the demo raiders
    return "\n".join(v for k, v in c.saved_variables().items() if k != "DisasterZonePatchDB")


def exercise_demo_ui(c, w):
    """Touch every demo-backed view once."""
    c.slash("/dz council")
    w.tick(0.4)
    for view in ("items", "member", "roster"):
        c.eval("ns.CouncilUI:SetView(...)", view)
        w.tick(0.3)
    row = c.eval("return T_rows(DisasterZoneCouncilPanel.rosterView.list.box)[1]")
    c.hover(row)
    cell = c.eval("local r = ...; for s = 1, 17 do if r.cells[s].itemID then return r.cells[s] end end", row)
    if cell:
        c.hover(cell)
    c.show_tooltip_item(32385)
    c.slash("/dz log")
    w.tick(0.3)
    c.slash("/dz settings")
    w.tick(0.3)


@case
def demo_toggle_repeatedly_changes_nothing_saved_and_sends_nothing():
    for rank in (3, 1):        # a raider and a real council member
        w, c = solo("Alice", guild_rank=rank, tick=60)
        install_helpers(c)
        c.eval(SUB_SELECT)
        before = snapshot(c)
        m0 = len(w.addon_log)
        for i in range(10):
            c.slash("/dz demo on")
            w.tick(0.3)
            if i % 3 == 0:
                exercise_demo_ui(c, w)
            c.slash("/dz demo off")
            w.tick(0.3)
        w.tick(5)
        after = snapshot(c)
        assert after == before, (rank, before, after)
        sent = [e for e in w.addon_log[m0:] if e["sender"] == c.full_name and e["prefix"] != "CDLm"]
        assert sent == [], "rank %d: demo toggling sent %r" % (rank, [(e["prefix"], str(e.get("msg") or e.get("message") or e)[:160]) for e in sent])
        text = sv_text(c)
        leaked = [n for n in FAKE if n in text]
        assert not leaked, "demo names in SavedVariables: %r" % leaked
        assert c.eval("return ns.Demo:IsEnabled()") is False
        assert c.eval_py("return ns.Store:GetAllKeys()") == ["Alice-Thunderstrike"]
        no_errors(w)


@case
def demo_awards_rolls_drops_stay_out_of_saved_data():
    w, c = solo("Alice", guild_rank=3, tick=60)
    install_helpers(c)
    c.eval(SUB_SELECT)
    m0 = len(w.addon_log)
    c.slash("/dz demo on")
    w.tick(0.3)
    # award through the Items view menu, the award dialog (typed fake name), and the API; then void one
    c.slash("/dz council")
    c.eval("ns.CouncilUI:SetView('items')")
    w.tick(0.4)
    row = c.eval("""
      for _, r in ipairs(T_rows(DisasterZoneCouncilPanel.itemsView.list.box)) do
        if rawget(r, 'cdlData') and r.cdlData.n > 0 then return r end
      end""")
    c.click(row)
    award = menu_find(c.last_menu(), "Record award to")
    c.eval("T_menu_sub_select('Record award to', ...)", award["children"][0]["text"])
    c.eval("ns.LootLogUI:OpenAwardDialog(28770)")
    c.type_text(c.eval("return DisasterZoneAwardDialog.winBox"), "grimtusk")
    c.click(c.eval("return DisasterZoneAwardDialog.saveBtn"))
    e = c.eval("return ns.Ledger:Award(28785, 'Pyria-Thunderstrike', '', 'x')")
    c.eval("local e = ...; ns.Ledger:Void(e.id, true)", e)
    w.tick(0.5)
    assert c.eval("return #ns.Ledger:GetEntries({ includeVoid = true })") == 3
    # simulated drop + a demo roll that runs to the end, award the suggested winner
    c.slash("/dz test")
    w.tick(0.5)
    drop = c.eval_py("local h = ns.Loot:GetHistory(); local d = h[#h]; return { d.s, d.from, d.i[1] }")
    c.eval("local id = ...; ns.Roll:Start(id, ns.Loot:GetHistory()[#ns.Loot:GetHistory()])", drop[2])
    w.tick(45)
    sess = c.eval("return ns.Roll:GetForItem(...)", drop[2], drop[0])
    if sess is not None:
        res = c.eval_py("local s = ...; local r = ns.Roll:GetResults(s.id); return r[1] and r[1].key", sess)
        if res:
            c.eval("local s, k = ...; ns.Roll:Award(s.id, k)", sess, res)
            for p in c.popups():
                c.accept_popup(p)
    w.tick(2)
    c.slash("/dz demo off")
    w.tick(1)
    # nothing of that reached the saved ledger / lists / peers, nothing was sent
    assert c.eval("return next(DisasterZoneDB.ledger)") is None, c.eval_py("return DisasterZoneDB.ledger")
    assert c.eval("return next(DisasterZoneDB.lists)") is None
    assert c.eval("return #ns.Ledger:GetEntries({ includeVoid = true })") == 0, "demo ledger survived demo off"
    peers = c.eval_py("local o = {} for k in pairs(DisasterZoneDB.peers) do o[#o + 1] = k end return o") or []
    assert not [p for p in peers if p.split("-")[0] in FAKE], peers
    for d in c.eval_py("local o = {} for i, d in ipairs(DisasterZoneDB.dropHistory) do o[i] = { d.s, d.from or '', d.test and 1 or 0 } end return o") or []:
        assert d[1].split("-")[0] not in FAKE, d
    sent = [e for e in w.addon_log[m0:] if e["sender"] == c.full_name and e["prefix"] != "CDLm"]
    assert sent == [], [(e["prefix"], e["chat_type"]) for e in sent]
    raid_chat = [x for x in w.chat_log if x.get("sender") == c.full_name]
    assert raid_chat == [], raid_chat
    c.relog()
    w.tick(5)
    text = sv_text(c)
    assert not [n for n in FAKE if n in text], [n for n in FAKE if n in text]
    no_errors(w)


@case
def real_data_hidden_in_demo_and_back_afterwards():
    w = World()
    seed_guild_council(w, ["Cou"])          # Addendum E: Cou is on the GM's guild council list
    w.add_offline_member("Bob", "MAGE", 3)
    c = Client(w, "Cou", guild_rank=1)
    c.load_addon()
    w.tick(3)
    install_helpers(c)
    data = c.eval("""
      local d = { v = 1, cl = 'MAGE', sp = 'Fire', ph = { [1] = { [1] = { 28744, 0 } } }, ob = {}, eq = {} }
      return ns.Store:Put('Bob-Thunderstrike', { r = 3, ts = GetServerTime(), h = ns.Util.Hash(d), d = d }, 'direct')""")
    assert data is True
    c.eval("ns.Ledger:Award(28744, 'Bob-Thunderstrike', '', 'real')")
    w.tick(1)
    assert c.eval_py("return ns.Store:GetAllKeys()") == ["Bob-Thunderstrike", "Cou-Thunderstrike"]
    c.slash("/dz demo on")
    keys = c.eval_py("return ns.Store:GetAllKeys()")
    assert "Bob-Thunderstrike" not in keys and len(keys) == 19, keys
    assert c.eval("return #ns.Ledger:GetEntries({})") == 0, "real awards shown in demo mode"
    c.slash("/dz demo off")
    w.tick(0.5)
    assert c.eval_py("return ns.Store:GetAllKeys()") == ["Bob-Thunderstrike", "Cou-Thunderstrike"]
    assert c.eval("return #ns.Ledger:GetEntries({})") == 1
    assert c.eval("return ns.Store:Get('Bob-Thunderstrike').rev") == 3
    # the council roster shows the real list again
    c.slash("/dz council")
    w.tick(0.5)
    rows = c.eval_py("local o = {} for i, d in ipairs(T_data(DisasterZoneCouncilPanel.rosterView.list.box)) do o[i] = d.key end return o")
    assert rows == ["Cou-Thunderstrike", "Bob-Thunderstrike"] or sorted(rows) == ["Bob-Thunderstrike", "Cou-Thunderstrike"], rows
    no_errors(w)


@case
def demo_off_does_not_leave_fake_member_in_council_views():
    # A real council member looks at a demo member, then turns demo mode off: the member view keeps showing
    # the fake player ("no list received", position "- / 1") instead of a real member.
    w, c = solo("Cou", guild_rank=1, tick=3, council=["Cou"])
    install_helpers(c)
    c.slash("/dz demo on")
    c.slash("/dz council")
    w.tick(0.3)
    c.eval("ns.CouncilUI:ShowMember('Aldrin-Thunderstrike')")
    w.tick(0.3)
    assert strip_codes(c.eval("return DisasterZoneCouncilPanel.memberView.name:GetText()")) == "Aldrin"
    c.slash("/dz demo off")
    w.tick(0.5)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "council"     # still council for real
    shown = strip_codes(c.eval("return DisasterZoneCouncilPanel.memberView.name:GetText()") or "")
    pos = c.eval("return DisasterZoneCouncilPanel.memberView.pos:GetText()")
    assert shown.split("-")[0] not in FAKE, "member view still shows demo member %r (pos %r)" % (shown, pos)
    no_errors(w)


@case
def demo_works_without_a_guild_and_sends_nothing():
    w, c = solo("Solo", guild=None, tick=5)
    install_helpers(c)
    c.eval(SUB_SELECT)
    before = snapshot(c)
    m0 = len(w.addon_log)
    c.slash("/dz demo on")
    c.slash("/dz")
    w.tick(0.3)
    tabs = c.eval_py("local o = {} for _, k in ipairs(ns.MainFrame:GetShownPages()) do o[#o + 1] = k end return o")
    assert tabs == ["home", "mybis", "gearsim", "consumables", "wardrobe", "atlas", "council", "raids", "lootrules", "mylog", "dungeons", "events", "polls", "recruit", "audit", "members", "games", "feedback", "changelog", "settings"], tabs
    exercise_demo_ui(c, w)
    assert c.eval("return #T_data(DisasterZoneCouncilPanel.rosterView.list.box)") == 19
    c.slash("/dz test")
    w.tick(1)
    c.slash("/dz demo off")
    w.tick(1)
    assert [e for e in w.addon_log[m0:] if e["sender"] == c.full_name and e["prefix"] != "CDLm"] == []
    after = snapshot(c)
    after.pop("dropHistory", None)
    before.pop("dropHistory", None)
    assert after == before, (before, after)
    no_errors(w)


if __name__ == "__main__":
    run_all()

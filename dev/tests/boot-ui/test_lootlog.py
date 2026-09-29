"""Loot Log tab: add-award dialog (item by ID / link / shift-click / drag, winner menu and typed names, note,
validation), void / restore, "Show voided", search, row menu and tooltip, auto entries, non-council refusal.

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_lootlog.py
"""
from _common import (case, run_all, solo, no_errors, World, Client, install_helpers, menu_texts, menu_find,
                     printed_since, strip_codes, tt_lines, seed_guild_council)

PRINCE_ITEM = 28770      # Nathrezim Mindblade (Prince Malchezaar, Karazhan)
SUB_SELECT = r"""
function T_menu_sub_select(subText, text)
  local function find(d, t)
    for _, ch in ipairs(d.children) do
      if ch.text == t then return ch end
      local r = find(ch, t)
      if r then return r end
    end
  end
  local sub = find(__MOCK.last_menu, subText)
  return __MOCK.menu_select(text, sub)
end
function T_log_rows()
  local o = {}
  for i, d in ipairs(T_data(CDLootLootLogPanel.list.box)) do
    local e = d.entry
    o[i] = { e.id, e.i, e.w, e.b or '', e.s, e.n or '', e.vd and 1 or 0 }
  end
  return o
end
"""


def council_world(rank=1, members=(("Bob", "MAGE", 3), ("Carl", "ROGUE", 2), ("Dora", "PRIEST", 3))):
    w = World()
    seed_guild_council(w, ["Cou"] if rank <= 1 else [])   # Addendum E: the GM's list names the officer
    for n, cl, r in members:
        w.add_offline_member(n, cl, r)
    c = Client(w, "Cou", guild_rank=rank, class_file="PALADIN")
    c.load_addon()
    w.tick(3)
    install_helpers(c)
    c.eval(SUB_SELECT)
    return w, c


def open_log(c):
    c.slash("/cdl log")
    c.world.tick(0.5)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "loot"


def log_rows(c):
    return c.eval_py("return T_log_rows()") or []


def dialog(c, field):
    return c.eval("return CDLootAwardDialog.%s" % field)


# ------------------------------------------------------------------------------------------------------------------
@case
def empty_log_and_add_award_dialog_happy_path():
    w, c = council_world()
    open_log(c)
    assert c.eval("return CDLootLootLogPanel.count:GetText()") == "0 awards"
    assert "No awards recorded yet" in c.eval("return CDLootLootLogPanel.empty:GetText()")
    assert c.eval("return CDLootLootLogPanel.empty:IsShown()") is True
    c.click(c.eval("return CDLootLootLogPanel.addBtn"))
    assert c.eval("return CDLootAwardDialog:IsShown()") is True
    assert c.eval("return CDLootAwardDialog.itemBox:HasFocus()") is True
    # save with nothing -> validation messages, nothing recorded
    c.click(dialog(c, "saveBtn"))
    assert "Enter an item" in c.eval("return CDLootAwardDialog.status:GetText()")
    c.type_text(dialog(c, "itemBox"), str(PRINCE_ITEM))
    assert "Nathrezim Mindblade" in strip_codes(c.eval("return CDLootAwardDialog.itemHint:GetText()"))
    assert strip_codes(c.eval("return CDLootAwardDialog.bossText:GetText()")) == "Boss: Prince Malchezaar · Karazhan"
    c.click(dialog(c, "saveBtn"))
    assert c.eval("return CDLootAwardDialog.status:GetText()") == "Choose who received the item."
    assert c.eval("return next(CDLootDB.ledger)") is None
    # winner menu: not in a group, guild online / all submenus
    c.click(dialog(c, "pickBtn"))
    texts = [e[2] for e in menu_texts(c.last_menu())]
    assert texts[0] == "Not in a group", texts
    assert "Guild - online (1)" in texts and "Guild - all (4)" in texts, texts
    bob = next(t for t in texts if t and strip_codes(t) == "Bob")
    c.eval("T_menu_sub_select('Guild - all (4)', ...)", bob)
    assert c.eval("return CDLootAwardDialog.winBox:GetText()") == "Bob"
    c.type_text(dialog(c, "noteBox"), "  first kill  ")
    p0 = len(c.chat_frame)
    c.click(dialog(c, "saveBtn"))
    w.tick(0.5)
    assert c.eval("return CDLootAwardDialog:IsShown()") is False
    rows = log_rows(c)
    assert len(rows) == 1, rows
    _, iid, win, boss, kind, note, vd = rows[0]
    assert (iid, win, boss, kind, note, vd) == (PRINCE_ITEM, "Bob-Thunderstrike", "Karazhan:Prince", "m", "first kill", 0), rows[0]
    assert any("Recorded award" in l and "Bob" in l for l in printed_since(c, p0)), printed_since(c, p0)
    assert c.eval("return CDLootLootLogPanel.count:GetText()") == "1 award"
    # the row widgets
    r = c.eval_py("""local r = T_rows(CDLootLootLogPanel.list.box)[1]
      return { r.item:GetText(), r.winner:GetText(), r.boss:GetText(), r.by:GetText(), r.date:GetText() }""")
    assert "Nathrezim Mindblade" in r[0] and strip_codes(r[1]) == "Bob" and r[2] == "Prince Malchezaar", r
    assert r[3] == "manual · Cou · note" and len(r[4]) == len("09/21 12:00"), r
    no_errors(w)


@case
def award_dialog_item_inputs_and_typed_winners():
    w, c = council_world()
    open_log(c)
    c.click(c.eval("return CDLootLootLogPanel.addBtn"))
    ib = dialog(c, "itemBox")
    link = c.eval("return (select(2, C_Item.GetItemInfo(...)))", PRINCE_ITEM)
    # a pasted link, junk, out-of-range IDs
    for text, ok in ((link, True), ("abc", False), ("999999", False), ("0", False), ("  28770  ", True)):
        c.type_text(ib, text)
        got = c.eval("return CDLootAwardDialog.itemID")
        assert (got == PRINCE_ITEM) == ok, (text, got)
    # shift-click while the item box has focus
    other = 28785
    c.eval("CDLootAwardDialog.itemBox:SetFocus()")
    c.eval("ChatFrameUtil.InsertLink((select(2, C_Item.GetItemInfo(...))))", other)
    assert c.eval("return CDLootAwardDialog.itemID") == other
    # ... but not when another box has focus
    c.eval("CDLootAwardDialog.noteBox:SetFocus()")
    c.eval("ChatFrameUtil.InsertLink((select(2, C_Item.GetItemInfo(...))))", PRINCE_ITEM)
    assert c.eval("return CDLootAwardDialog.itemID") == other
    # drag onto the item button / the box
    c.set_cursor_item(PRINCE_ITEM)
    c.eval("T_script(CDLootAwardDialog.itemBtn, 'OnReceiveDrag')")
    assert c.eval("return CDLootAwardDialog.itemID") == PRINCE_ITEM
    c.set_cursor_item(other)
    c.eval("T_script(CDLootAwardDialog.itemBox, 'OnReceiveDrag')")
    assert c.eval("return CDLootAwardDialog.itemID") == other
    assert c.eval("return GetCursorInfo()") is None
    # an item without a raid source: boss "none"
    w.define_item(190002, "Crafted Ring", 4, "INVTYPE_FINGER", 4, 0)
    c.type_text(ib, "190002")
    assert strip_codes(c.eval("return CDLootAwardDialog.bossText:GetText()")) == "Boss: none"
    # typed winners: case-insensitive guild match, unknown name normalised
    c.type_text(ib, str(PRINCE_ITEM))
    for typed, want in (("carl", "Carl-Thunderstrike"), ("DORA", "Dora-Thunderstrike"),
                        ("zed", "Zed-Thunderstrike"), ("Ann-Other Realm", "Ann-OtherRealm")):
        c.type_text(dialog(c, "winBox"), typed)
        c.click(dialog(c, "saveBtn"))
        w.tick(0.3)
        e = c.eval_py("local e = ns.Ledger:GetEntries({})[1]; return { e.w, e.i }")
        assert e == [want, PRINCE_ITEM], (typed, e)
        c.click(c.eval("return CDLootLootLogPanel.addBtn"))
        c.type_text(ib, str(PRINCE_ITEM))
    # a long note is cut to 60 characters
    c.type_text(dialog(c, "winBox"), "Bob")
    c.type_text(dialog(c, "noteBox"), "x" * 100)
    c.click(dialog(c, "saveBtn"))
    w.tick(0.3)
    note = c.eval("return ns.Ledger:GetEntries({})[1].n")
    assert note and len(note) <= 60, note
    # prefilled dialog from other views (item, winner, boss, note)
    c.eval("ns.LootLogUI:OpenAwardDialog(28785, 'Carl-Thunderstrike', 'Karazhan:Illhoof', 'pre')")
    assert c.eval("return CDLootAwardDialog.itemID") == 28785
    assert c.eval("return CDLootAwardDialog.winBox:GetText()") == "Carl"
    assert c.eval("return CDLootAwardDialog.noteBox:GetText()") == "pre"
    assert strip_codes(c.eval("return CDLootAwardDialog.bossText:GetText()")) == "Boss: Terestian Illhoof · Karazhan"
    c.click(dialog(c, "cancelBtn"))
    assert c.eval("return CDLootAwardDialog:IsShown()") is False
    no_errors(w)


@case
def void_restore_show_voided_and_row_menu():
    w, c = council_world()
    for item, who in ((28770, "Bob-Thunderstrike"), (28785, "Carl-Thunderstrike"), (28762, "Dora-Thunderstrike")):
        c.eval("local i, k = ...; ns.Ledger:Award(i, k, '', nil)", item, who)
        w.tick(1)
    open_log(c)
    assert len(log_rows(c)) == 3
    row_for = lambda item: c.eval("""
      local id = ...
      for _, r in ipairs(T_rows(CDLootLootLogPanel.list.box)) do
        if rawget(r, 'cdlEntry') and r.cdlEntry.i == id then return r end
      end""", item)
    c.click(row_for(28785), "RightButton")
    texts = [e[2] for e in menu_texts(c.last_menu())]
    # Addendum G: "Reason: ..." (with the reasons as a submenu) comes first
    assert texts[1:] == ["Reason: none", "BiS", "Alt", "Upgrade", "Offspec", "Disenchant", "Guild bank",
                         "Void entry", "Link item in chat", "Show member"], texts
    c.menu_select("Void entry")
    w.tick(0.5)
    assert [r[1] for r in log_rows(c)] == [28762, 28770], log_rows(c)
    assert c.eval("return CDLootLootLogPanel.count:GetText()") == "2 awards"
    # the saved entry is voided, not deleted
    assert c.eval("for _, e in pairs(CDLootDB.ledger) do if e.i == 28785 then return e.vd end end") is True
    c.click(c.eval("return CDLootLootLogPanel.voidCB"))
    w.tick(0.3)
    rows = log_rows(c)
    assert len(rows) == 3 and [r[6] for r in rows if r[1] == 28785] == [1], rows
    txt = c.eval("local r = ...; return r.item:GetText(), r:GetAlpha()", row_for(28785))
    assert "(void)" in txt[0] and txt[1] < 1, txt
    c.hover(row_for(28785))
    assert any(l[0].startswith("Voided") for l in tt_lines(c)), tt_lines(c)
    c.click(row_for(28785), "RightButton")
    assert "Restore entry" in [e[2] for e in menu_texts(c.last_menu())]
    c.menu_select("Restore entry")
    w.tick(0.5)
    assert [r[6] for r in log_rows(c)] == [0, 0, 0]
    # tooltip of a normal row
    c.hover(row_for(28770))
    lines = [(strip_codes(a), strip_codes(b)) for a, b in tt_lines(c)]
    assert ("Winner", "Bob") in lines and any(a == "Recorded" and b == "Manual by Cou" for a, b in lines), lines
    # link + show member
    c.eval("T_clear_links()")
    c.click(row_for(28770), "RightButton")
    c.menu_select("Link item in chat")
    assert c.eval_py("return T_links()")
    c.click(row_for(28770), "RightButton")
    c.menu_select("Show member")
    w.tick(0.5)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "council"
    assert c.eval("return ns.CouncilUI:GetView()") == "member"
    assert strip_codes(c.eval("return CDLootCouncilPanel.memberView.name:GetText()")) == "Bob"
    no_errors(w)


@case
def search_filters_by_winner_item_boss_and_id():
    w, c = council_world()
    c.eval("ns.Ledger:Award(28770, 'Bob-Thunderstrike', 'Karazhan:Prince', 'offspec')")
    c.eval("ns.Ledger:Award(28785, 'Carl-Thunderstrike', 'Karazhan:Illhoof', nil)")
    w.tick(1)
    open_log(c)
    sb = c.eval("return CDLootLootLogPanel.search")
    for text, want in (("bob", [28770]), ("CARL", [28785]), ("mindblade", [28770]), ("illhoof", [28785]),
                       ("28785", [28785]), ("offspec", [28770]), ("cou", [28770, 28785]), ("", [28770, 28785])):
        c.type_text(sb, text)
        w.tick(0.5)
        got = sorted(r[1] for r in log_rows(c))
        assert got == want, (text, got)
    c.type_text(sb, "nothing matches")
    w.tick(0.5)
    assert c.eval("return CDLootLootLogPanel.count:GetText()") == "0 of 2 awards"
    assert c.eval("return CDLootLootLogPanel.empty:GetText()") == "No awards match the search."
    no_errors(w)


@case
def auto_entries_from_loot_messages_show_in_the_log():
    w = World()
    seed_guild_council(w, ["Cou"])
    cou = Client(w, "Cou", guild_rank=1, class_file="PALADIN")
    bob = Client(w, "Bob", guild_rank=3, class_file="MAGE")
    for x in (cou, bob):
        x.load_addon()
    w.tick(3)
    install_helpers(cou)
    cou.eval(SUB_SELECT)
    w.make_raid([cou, bob], master_looter=cou)
    w.enter_instance("Karazhan", 532)
    w.encounter(661, "Prince Malchezaar")
    w.tick(1)
    open_log(cou)
    w.broadcast_loot_received(bob, PRINCE_ITEM)
    w.tick(1)
    rows = log_rows(cou)
    assert len(rows) == 1 and rows[0][1:5] == [PRINCE_ITEM, "Bob-Thunderstrike", "Karazhan:Prince", "a"], rows
    by = cou.eval("return T_rows(CDLootLootLogPanel.list.box)[1].by:GetText()")
    assert by.startswith("auto"), by
    # a manual award for the same item/winner right after hides the auto entry (manual wins)
    cou.eval("ns.Ledger:Award(...)", PRINCE_ITEM, "Bob-Thunderstrike", "Karazhan:Prince", None)
    w.tick(1)
    rows = log_rows(cou)
    assert len(rows) == 1 and rows[0][4] == "m", rows
    no_errors(w)


@case
def non_council_cannot_record_or_see_the_log():
    w, c = council_world(rank=3)
    c.slash("/cdl log")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "home"
    c.eval("ns.LootLogUI:OpenAwardDialog(28770, 'Bob-Thunderstrike')")
    p0 = len(c.chat_frame)
    c.click(dialog(c, "saveBtn"))
    w.tick(0.3)
    assert c.eval("return next(CDLootDB.ledger)") is None
    assert "council members only" in c.eval("return CDLootAwardDialog.status:GetText()")
    assert any("Only loot council members can record awards" in l for l in printed_since(c, p0))
    assert [e for e in w.addon_log if e["sender"] == c.full_name and e["chat_type"] == "WHISPER"] == []
    no_errors(w)


@case
def log_refreshes_live_and_survives_relog():
    w, c = council_world()
    open_log(c)
    c.eval("ns.Ledger:Award(28770, 'Bob-Thunderstrike', '', nil)")
    w.tick(0.5)                                   # LEDGER_UPDATED -> debounced refresh while visible
    assert len(log_rows(c)) == 1
    c.slash("/cdl")                               # hide; an award while hidden marks the panel dirty
    c.eval("ns.Ledger:Award(28785, 'Carl-Thunderstrike', '', nil)")
    w.tick(0.5)
    open_log(c)
    assert len(log_rows(c)) == 2
    c.relog()
    w.tick(3)
    install_helpers(c)
    c.eval(SUB_SELECT)
    open_log(c)
    assert sorted(r[1] for r in log_rows(c)) == [28770, 28785]
    no_errors(w)


if __name__ == "__main__":
    run_all()

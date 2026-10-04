"""Council tab: roster / items / member views with demo data and with real cached lists; filters, sort, search,
cell tooltips and clicks, the phase dropdown, "Request sync".

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_council_ui.py
"""
from _common import (case, run_all, solo, no_errors, World, Client, ExtraMember, install_helpers, menu_texts,
                     menu_find, printed_since, strip_codes, tt_lines, seed_guild_council)

ROSTER = """
local o = {}
for i, d in ipairs(T_data(DisasterZoneCouncilPanel.rosterView.list.box)) do
  o[i] = { d.key, d.classFile or '', d.spec or '', d.presence, d.need, d.filled, d.ts }
end
return o"""

# Deterministic list builder for real cached lists (Store:Put path, validated + hashed like a received LIST).
LIST_LUA = r"""
function T_make_list(klass, seed, phases, nob, neq)
  local specs = ns.SPECS[klass]
  local data = { v = 1, cl = klass, sp = specs[(seed % #specs) + 1].label, ph = {}, ob = {}, eq = {} }
  for p = 1, phases do
    local slots = {}
    for sid = 1, 17 do
      local c = ns.ItemDB:GetCandidates(sid, { maxPhase = p, class = klass, usableOnly = true, primaryArmorOnly = true })
      if #c > 0 then
        local i = ((seed * 7 + sid * 3 + p) % #c) + 1
        local a = ((seed * 5 + sid + p * 2) % #c) + 1
        slots[sid] = { c[i].itemID, (a ~= i) and c[a].itemID or 0 }
      end
    end
    data.ph[p] = slots
  end
  local ob, seen = {}, {}
  for sid = 1, 17 do
    local s = data.ph[1] and data.ph[1][sid]
    if s and #ob < (nob or 3) and not seen[s[1]] then ob[#ob + 1] = s[1]; seen[s[1]] = true end
  end
  table.sort(ob)
  data.ob = ob
  for sid = 1, (neq or 2) do
    local s = data.ph[1] and data.ph[1][sid]
    if s then data.eq[sid] = s[1] end
  end
  return data
end
function T_put(key, data, rev, ts, via)
  return ns.Store:Put(key, { r = rev or 1, ts = ts or GetServerTime(), h = ns.Util.Hash(data), d = data }, via or "direct")
end
-- invoke an entry inside a named submenu of the last opened menu (names repeat across submenus)
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
"""


def roster(c):
    return c.eval_py(ROSTER) or []


def names(rows):
    return [r[0].split("-")[0] for r in rows]


def demo_council(name="Alice", rank=3):
    w, c = solo(name, guild_rank=rank, tick=3)
    install_helpers(c)
    c.slash("/dz demo on")
    c.slash("/dz council")
    w.tick(0.5)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "council"
    return w, c


def select_option(c, dd_expr, text_contains):
    menu = c.dropdown_menu(c.eval("return " + dd_expr))
    for e in menu_texts(menu):
        if e[2] and text_contains in strip_codes(e[2]):
            c.menu_select(e[2])
            c.world.tick(0.3)
            return e[2]
    raise AssertionError("no option %r in %r" % (text_contains, menu_texts(menu)))


def cell_of(c, row_index, want_main=True):
    return c.eval("""
      local i, want = ...
      local r = T_rows(DisasterZoneCouncilPanel.rosterView.list.box)[i]
      for s = 1, 17 do
        local cell = r.cells[s]
        if (cell.itemID ~= nil) == want then return cell, s end
      end""", row_index, want_main)


# ------------------------------------------------------------------------------------------------------------------
@case
def demo_roster_view_rows_footer_and_rows():
    w, c = demo_council()
    rows = roster(c)
    assert len(rows) == 19, len(rows)
    # presence order: raid (11: me + 10 demo) then online then offline, names ascending inside
    pres = [r[3] for r in rows]
    assert pres == sorted(pres, key=lambda p: {"raid": 0, "online": 1, "offline": 2}[p]), pres
    assert pres.count("raid") == 11
    footer = strip_codes(c.eval("return DisasterZoneCouncilPanel.footer.text:GetText()"))
    assert footer.startswith("19 members with lists · 11 in raid · "), footer
    stale = sum(1 for r in rows if r[6] and (c.eval("return GetServerTime()") - r[6]) > 7 * 86400)
    assert ("%d lists older than 7 days" % stale) in footer, (stale, footer)
    # row widgets show what the data says
    ui = c.eval_py("""
      local o = {}
      for i, r in ipairs(T_rows(DisasterZoneCouncilPanel.rosterView.list.box)) do
        local cells = 0
        for s = 1, 17 do if r.cells[s].itemID then cells = cells + 1 end end
        o[i] = { r.name:GetText(), r.spec:GetText(), r.need:GetText(), cells, r.age:GetText() }
      end
      return o""")
    for (key, cl, spec, pres_, need, filled, ts), (nm, sp, nd, cells, age) in zip(rows, ui):
        assert strip_codes(nm) == key.split("-")[0], (nm, key)
        assert sp == (spec or "-"), (sp, spec)
        assert cells == filled, (key, cells, filled)
        if filled:
            assert strip_codes(nd) == str(need), (key, nd, need)
        assert age and age != "", age
    no_errors(w)


@case
def demo_filters_class_role_raid_hide_obtained_search():
    w, c = demo_council()
    select_option(c, "DisasterZoneCouncilPanel.classDD", "Warrior")
    assert sorted(names(roster(c))) == ["Aldrin", "Brakka"], names(roster(c))
    assert strip_codes(c.eval("return DisasterZoneCouncilPanel.classDD:GetText()")) == "Warrior"
    select_option(c, "DisasterZoneCouncilPanel.roleDD", "Tank")
    assert names(roster(c)) == ["Aldrin"], names(roster(c))
    select_option(c, "DisasterZoneCouncilPanel.classDD", "All classes")
    assert sorted(names(roster(c))) == ["Aldrin", "Rhosyn"], names(roster(c))
    select_option(c, "DisasterZoneCouncilPanel.roleDD", "Healer")
    healers = names(roster(c))
    assert set(healers) == {"Alice", "Caelith", "Isolde", "Kaelyn", "Quillon"}, healers
    select_option(c, "DisasterZoneCouncilPanel.roleDD", "All roles")
    # footer counts are totals, independent of the filters
    assert strip_codes(c.eval("return DisasterZoneCouncilPanel.footer.text:GetText()")).startswith("19 members")
    # raid only
    c.click(c.eval("return DisasterZoneCouncilPanel.raidCB"))
    w.tick(0.3)
    rows = roster(c)
    assert len(rows) == 11 and all(r[3] == "raid" for r in rows), rows
    c.click(c.eval("return DisasterZoneCouncilPanel.raidCB"))
    w.tick(0.3)
    assert len(roster(c)) == 19
    # hide obtained: obtained cells dimmed while ticked, full alpha when unticked
    def dimmed():
        return c.eval("""
          local n = 0
          for _, r in ipairs(T_rows(DisasterZoneCouncilPanel.rosterView.list.box)) do
            for s = 1, 17 do if r.cells[s].state == 'obtained' and r.cells[s]:GetAlpha() < 1 then n = n + 1 end end
          end
          return n""")
    assert dimmed() > 0
    c.click(c.eval("return DisasterZoneCouncilPanel.obtainedCB"))
    w.tick(0.3)
    assert c.eval("return DisasterZoneCouncilPanel.obtainedCB:GetChecked()") in (False, 0, None)
    assert dimmed() == 0
    # search (debounced) by name, case-insensitive; empty result explains itself
    sb = c.eval("return DisasterZoneCouncilPanel.search")
    c.type_text(sb, "ALD")
    w.tick(0.5)
    assert names(roster(c)) == ["Aldrin"], names(roster(c))
    c.type_text(sb, "nobody-like-this")
    w.tick(0.5)
    assert roster(c) == []
    assert c.eval("return DisasterZoneCouncilPanel.rosterView.empty:IsShown()") is True
    assert "No members match" in c.eval("return DisasterZoneCouncilPanel.rosterView.empty:GetText()")
    c.type_text(sb, "")
    w.tick(0.5)
    assert len(roster(c)) == 19
    no_errors(w)


@case
def demo_sort_headers_cycle():
    w, c = demo_council()
    headers = c.eval_py("""
      local o = {}
      for i, b in ipairs(DisasterZoneCouncilPanel.rosterView.header.sortButtons) do o[i] = b.label:GetText() end
      return o""")
    assert headers == ["Name", "Need", "Age"], headers
    btn = lambda i: c.eval("local i = ...; return DisasterZoneCouncilPanel.rosterView.header.sortButtons[i]", i)
    c.click(btn(1))                  # presence -> name
    w.tick(0.2)
    n = names(roster(c))
    assert n == sorted(n, key=str.lower), n
    c.click(btn(1))                  # name -> presence
    w.tick(0.2)
    assert roster(c)[0][3] == "raid" and roster(c)[-1][3] == "offline"
    c.click(btn(2))                  # need: most needed first
    w.tick(0.2)
    needs = [r[4] for r in roster(c)]
    assert needs == sorted(needs, reverse=True), needs
    c.click(btn(3))                  # age: oldest list first (0 = never last? my own list has ts 0)
    w.tick(0.2)
    ts = [r[6] for r in roster(c)]
    assert ts == sorted(ts), ts
    # hover explains the current sort
    c.hover(btn(3))
    lines = [l[0] for l in tt_lines(c)]
    assert lines[0] == "Sort by oldest list" and lines[1] == "Current: oldest list", lines
    no_errors(w)


@case
def demo_cell_tooltip_click_and_rightclick():
    w, c = demo_council()
    rows = roster(c)
    # a member with an equipped ring pair shows both rings
    idx = None
    for i, r in enumerate(rows):
        both = c.eval("""
          local k = ...
          local d = ns.Store:Get(k).data
          return d.eq[11] ~= nil and d.eq[12] ~= nil and d.ph[1] and d.ph[1][11] ~= nil""", r[0])
        if both:
            idx = i
            break
    assert idx is not None, "no demo member wears two rings"
    cell = c.eval("local i = ...; return T_rows(DisasterZoneCouncilPanel.rosterView.list.box)[i].cells[11]", idx + 1)
    c.hover(cell)
    lines = [strip_codes(l[0]) for l in tt_lines(c)]
    key = rows[idx][0]
    assert any(("DisasterZone · %s - Ring 1" % key.split("-")[0]) in l for l in lines), lines
    assert "Main (P1)" in lines, lines
    wear = [l for l in lines if l.startswith("Wearing: ") or l == "Wearing it"]
    assert wear, lines
    if wear[0].startswith("Wearing: "):
        assert wear[0].count(",") == 1, wear   # both rings of the pair
    assert "Click: who wants items from this boss" in lines
    c.leave(cell)
    # hover twice: the tooltip is rebuilt, not appended
    c.hover(cell)
    lines2 = [strip_codes(l[0]) for l in tt_lines(c)]
    assert lines2 == lines, (lines, lines2)
    # left click -> Items view focused on the boss dropping it
    main = c.eval("local c = ...; return c.itemID", cell)
    c.click(cell)
    w.tick(0.3)
    assert c.eval("return ns.CouncilUI:GetView()") == "items"
    src = c.eval("local id = ...; return ns.ItemDB:GetSources(id)[1].ref.key", main)
    focus = c.eval_py("""
      local o = {}
      for _, d in ipairs(T_data(DisasterZoneCouncilPanel.itemsView.list.box)) do if d.focus then o[#o + 1] = d.itemID end end
      return o""")
    assert focus, "no focused row in the Items view"
    title = strip_codes(c.eval("return DisasterZoneCouncilPanel.itemsView.title:GetText()"))
    boss = c.eval("local k = ...; return ns.ItemDB:GetBossRef(k).boss.name", src)
    assert title.startswith(boss), (title, boss)
    # right click on a cell -> member view of that row
    c.eval("ns.CouncilUI:SetView('roster')")
    w.tick(0.3)
    cell = c.eval("local i = ...; return T_rows(DisasterZoneCouncilPanel.rosterView.list.box)[i].cells[11]", idx + 1)
    c.click(cell, "RightButton")
    w.tick(0.3)
    assert c.eval("return ns.CouncilUI:GetView()") == "member"
    assert strip_codes(c.eval("return DisasterZoneCouncilPanel.memberView.name:GetText()")) == key.split("-")[0]
    # empty cell: tooltip says so, click opens the member view
    c.eval("ns.CouncilUI:SetView('roster')")
    w.tick(0.3)
    me_row = next(i for i, r in enumerate(roster(c)) if r[0] == "Alice-Thunderstrike")
    ecell = c.eval("local i = ...; return T_rows(DisasterZoneCouncilPanel.rosterView.list.box)[i].cells[1]", me_row + 1)
    c.hover(ecell)
    lines = [strip_codes(l[0]) for l in tt_lines(c)]
    assert lines[0] == "Head" and "Alice has no P1 pick here." in lines, lines
    c.click(ecell)
    w.tick(0.3)
    assert c.eval("return ns.CouncilUI:GetView()") == "member"
    no_errors(w)


@case
def demo_items_view_tree_rows_tooltip_and_menu():
    w, c = demo_council()
    c.eval(LIST_LUA)
    c.click(c.eval("return T_button(DisasterZoneCouncilPanel, 'Items')"))
    w.tick(0.3)
    tree = c.eval_py("""
      local o = {}
      for i, d in ipairs(T_data(DisasterZoneCouncilPanel.itemsView.tree.box)) do o[i] = { d.type, d.key or '', d.count, d.name } end
      return o""")
    assert tree[0][0] == "raid" and tree[0][3] == "Karazhan", tree[:3]
    bosses = [t for t in tree if t[0] == "boss"]
    assert bosses and any(b[2] > 0 for b in bosses)
    # select another boss by clicking its tree row
    target = next(b for b in bosses if b[2] > 0 and b[3] == "Prince Malchezaar")
    ti = [i for i, t in enumerate(tree) if t[1] == target[1]][0]
    c.click(c.eval("local i = ...; return T_rows(DisasterZoneCouncilPanel.itemsView.tree.box)[i]", ti + 1))
    w.tick(0.3)
    title = strip_codes(c.eval("return DisasterZoneCouncilPanel.itemsView.title:GetText()"))
    assert title.startswith("Prince Malchezaar · Karazhan"), title
    items = c.eval_py("""
      local o = {}
      for i, d in ipairs(T_data(DisasterZoneCouncilPanel.itemsView.list.box)) do o[i] = { d.itemID, d.n, #d.wanters } end
      return o""")
    claims = sum(i[1] for i in items)
    assert ("%d items · %d claims" % (len(items), claims)) in title, (title, items)
    assert [i[1] for i in items] == sorted([i[1] for i in items], reverse=True), items
    # the tree count equals the claims counted per member (one per member and item)
    assert target[2] >= max(i[1] for i in items)
    # hover a wanted item row
    wanted = next(i for i, it in enumerate(items) if it[1] > 0)
    row = c.eval("local i = ...; return T_rows(DisasterZoneCouncilPanel.itemsView.list.box)[i]", wanted + 1)
    c.hover(row)
    lines = [strip_codes(l[0]) for l in tt_lines(c)]
    assert any(l.startswith("DisasterZone · P1: %d wanting" % items[wanted][1]) for l in lines), lines
    who = strip_codes(c.eval("local r = ...; return r.who:GetText()", row))
    assert who and "Nobody" not in who, who
    # click -> menu
    c.click(row)
    menu = c.last_menu()
    texts = [e[2] for e in menu_texts(menu)]
    for t in ("Link item in chat", "Announce to raid", "Show member", "Record award to", "Someone else..."):
        assert t in texts, (t, texts)
    # link in chat
    c.eval("T_clear_links()")
    c.menu_select("Link item in chat")
    assert c.eval_py("return T_links()"), "no link inserted"
    # announce while not in a group: printed locally, nothing sent to chat channels
    n0, chat0 = len(c.chat_frame), len(w.chat_log)
    c.click(row)
    c.menu_select("Announce to raid")
    assert len(w.chat_log) == chat0
    assert any("DisasterZone:" in l and "BiS:" in l or "Alt:" in l for l in printed_since(c, n0)), printed_since(c, n0)
    # record award to a wanter (demo -> in-memory ledger only)
    c.click(row)
    award_menu = menu_find(c.last_menu(), "Record award to")
    first_wanter = award_menu["children"][0]["text"]
    c.eval("T_menu_sub_select('Record award to', ...)", first_wanter)
    w.tick(0.5)
    assert c.eval("return #ns.Ledger:GetEntries({})") == 1
    assert c.eval("return next(DisasterZoneDB.ledger)") is None, "demo award written to the saved ledger"
    # someone else -> award dialog prefilled with the item and the boss
    c.click(row)
    c.menu_select("Someone else...")
    assert c.eval("return DisasterZoneAwardDialog:IsShown()") is True
    item_text = c.eval("return DisasterZoneAwardDialog.itemBox:GetText()")
    assert ("item:%d:" % items[wanted][0]) in item_text, item_text
    assert "Prince Malchezaar" in strip_codes(c.eval("return DisasterZoneAwardDialog.bossText:GetText()"))
    c.click(c.eval("return DisasterZoneAwardDialog.cancelBtn"))
    # search inside the items view by member name
    c.type_text(c.eval("return DisasterZoneCouncilPanel.search"), "zzz")
    w.tick(0.5)
    assert c.eval("return #T_data(DisasterZoneCouncilPanel.itemsView.list.box)") == 0
    assert c.eval("return DisasterZoneCouncilPanel.itemsView.empty:GetText()") == "No items match the search."
    no_errors(w)


@case
def demo_member_view_arrows_readonly_doll():
    w, c = demo_council()
    rows = roster(c)
    c.click(c.eval("return T_rows(DisasterZoneCouncilPanel.rosterView.list.box)[1]"))
    w.tick(0.3)
    assert c.eval("return ns.CouncilUI:GetView()") == "member"
    mv = "DisasterZoneCouncilPanel.memberView"
    assert strip_codes(c.eval("return %s.name:GetText()" % mv)) == rows[0][0].split("-")[0]
    assert c.eval("return %s.pos:GetText()" % mv) == "1 / 19"
    info = strip_codes(c.eval("return %s.info:GetText()" % mv))
    assert "In your raid" in info and "updated" in info, info
    # the toolbar row 2 and the footer are hidden in the member view
    assert c.eval("return DisasterZoneCouncilPanel.row2:IsShown()") is False
    assert c.eval("return DisasterZoneCouncilPanel.footer:IsShown()") is False
    seen = []
    for _ in range(19):
        seen.append(strip_codes(c.eval("return %s.name:GetText()" % mv)))
        c.click(c.eval("return %s.nextBtn" % mv))
        w.tick(0.1)
    assert seen == [r[0].split("-")[0] for r in rows], (seen, names(rows))
    assert c.eval("return %s.pos:GetText()" % mv) == "1 / 19"   # wrapped around
    c.click(c.eval("return %s.prevBtn" % mv))
    assert c.eval("return %s.pos:GetText()" % mv) == "19 / 19"
    # read-only doll: clicking a tile never opens the picker; it shows the member's picks
    doll = c.eval("return T_doll(DisasterZoneCouncilPanel.memberView)")
    key = c.eval("return ns.CouncilUI and nil")  # placeholder to keep the eval env warm
    k = [r[0] for r in rows][-1]
    main = c.eval("local k = ...; local d = ns.Store:Get(k).data; return d.ph[1][2] and d.ph[1][2][1]", k)
    tile = c.eval("local d = ...; return rawget(d, 'tiles')[2]", doll)
    assert c.eval("local t = ...; return t.main.itemID", tile) == main
    c.click(c.eval("local t = ...; return t.main", tile))
    assert c.eval("return ns.Picker:IsOpen()") is False
    c.click(c.eval("local t = ...; return t.main", tile), "RightButton")
    # summary card
    summ = c.eval("return %s.centerParts.summary:GetText()" % mv)
    assert summ.startswith("P1: "), summ
    assert c.eval("return %s.centerParts.lines[1]:GetText()" % mv).find("No awards recorded") >= 0
    # the member's award shows up in the centre after an award
    c.eval("local k = ...; ns.Ledger:Award(ns.Store:Get(k).data.ph[1][2][1], k, '', 'test')", k)
    w.tick(0.5)
    line = strip_codes(c.eval("return %s.centerParts.lines[1]:GetText()" % mv))
    assert "No awards" not in line and "ago" in line or "just now" in line, line
    # the model: a demo member isn't nearby -> a note instead of a model
    note = c.eval("return %s.centerParts.noModel:GetText()" % mv)
    assert "model shows when nearby" in note, note
    no_errors(w)


@case
def phase_dropdown_switches_all_views():
    w, c = demo_council()
    p1 = [r[5] for r in roster(c)]
    select_option(c, "DisasterZoneCouncilPanel.phaseDD", "P3")
    assert c.eval("return DisasterZoneCouncilPanel.phaseDD:GetText()") == "P3"
    p3 = [r[5] for r in roster(c)]
    assert p1 != p3
    cells = c.eval_py("""
      local o = {}
      local r = T_rows(DisasterZoneCouncilPanel.rosterView.list.box)[1]
      local d = rawget(r, 'cdlData')
      for s = 1, 17 do
        local want = d.data.ph[3] and d.data.ph[3][s] and d.data.ph[3][s][1] or 0
        o[s] = { r.cells[s].itemID or 0, want }
      end
      return o""")
    assert all(a == b for a, b in cells), cells
    c.click(c.eval("return T_button(DisasterZoneCouncilPanel, 'Items')"))
    w.tick(0.3)
    tree = c.eval_py("local o = {} for i, d in ipairs(T_data(DisasterZoneCouncilPanel.itemsView.tree.box)) do o[i] = { d.type, d.name, d.phase or 0 } end return o")
    assert tree[0][0] == "raid" and tree[0][2] == 3, tree[:2]
    # the view phase setting (Settings) drives the default when the dropdown was never used
    w2, d = demo_council(name="Bea")
    d.eval("ns.DB:SetSetting('viewPhase', 2)")
    w2.tick(0.5)
    assert d.eval("return DisasterZoneCouncilPanel.phaseDD:GetText()") == "P2"
    no_errors(w)
    no_errors(w2)


@case
def items_view_follows_the_phase_dropdown():
    # Items view on a P1 boss, then the council switches the Phase dropdown to P3: the selection should move to
    # the new phase (its first boss with demand), not stay on the P1 boss with "0 claims".
    w, c = demo_council()
    c.click(c.eval("return T_button(DisasterZoneCouncilPanel, 'Items')"))
    w.tick(0.3)
    before = strip_codes(c.eval("return DisasterZoneCouncilPanel.itemsView.title:GetText()"))
    assert before.startswith("Attumen the Huntsman · Karazhan"), before
    select_option(c, "DisasterZoneCouncilPanel.phaseDD", "P3")
    sel = c.eval_py("""
      for _, r in ipairs(T_rows(DisasterZoneCouncilPanel.itemsView.tree.box)) do
        local d = rawget(r, 'cdlData')
        if d and r.sel:IsShown() then
          local ref = ns.ItemDB:GetBossRef(d.key)
          return { d.key, ref and ref.raid.phase or 0, d.count }
        end
      end""")
    title = strip_codes(c.eval("return DisasterZoneCouncilPanel.itemsView.title:GetText()"))
    assert sel and sel[1] == 3, "after switching to P3 the Items view still shows %r (%r)" % (title, sel)
    no_errors(w)


@case
def search_boxes_accept_lua_pattern_characters():
    w, c = demo_council(rank=1)
    boxes = [("council", "DisasterZoneCouncilPanel.search")]
    for text in ("[", "%", "(a", "a-", "^$", ".*", "%d+"):
        c.type_text(c.eval("return DisasterZoneCouncilPanel.search"), text)
        w.tick(0.5)
        for view in ("items", "roster"):
            c.eval("ns.CouncilUI:SetView(...)", view)
            w.tick(0.3)
    c.slash("/dz log")
    w.tick(0.3)
    for text in ("[", "%", "(a"):
        c.type_text(c.eval("return DisasterZoneLootLogPanel.search"), text)
        w.tick(0.5)
    c.slash("/dz")
    w.tick(0.1)
    c.slash("/dz")
    w.tick(0.1)
    c.eval("ns.MainFrame:Open('mybis')")
    w.tick(0.2)
    c.click(c.eval("return T_tile(1).main"))
    sb = c.eval("return T_template(DisasterZonePicker, 'SearchBoxTemplate')[1]")
    for text in ("[", "%", "(a", "%d+"):
        c.type_text(sb, text)
        w.tick(0.5)
    no_errors(w)


def real_council_world(n_members=6, stale=(), extra_raid=(), with_leaver=False):
    w = World()
    seed_guild_council(w, ["Cou"])          # Addendum E: Cou is on the GM's guild council list
    classes = ["WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID"]
    members = []
    for i in range(n_members):
        members.append(w.add_offline_member("Mem%02d" % i, classes[i % 9], 3))
    cou = Client(w, "Cou", guild_rank=1, class_file="PRIEST", talents=(10, 41, 0))
    cou.load_addon()
    w.tick(3)
    install_helpers(cou)
    cou.eval(LIST_LUA)
    now = cou.eval("return GetServerTime()")
    for i, m in enumerate(members):
        ts = now - (10 * 86400 if i in stale else 3600 * (i + 1))
        ok = cou.eval("local k, cl, s, ts = ...; return T_put(k, T_make_list(cl, s, 3), 1, ts)",
                      m.full_name, m.class_file, i, ts)
        assert ok is True, "Store:Put refused %s" % m.full_name
    if extra_raid:
        w.make_raid([cou], extra_members=[members[i] for i in extra_raid])
        w.tick(1)
    return w, cou, members


@case
def real_cached_lists_roster_items_member():
    w, c, members = real_council_world(n_members=6, stale=(4, 5), extra_raid=(0, 1))
    c.slash("/dz council")
    w.tick(0.5)
    rows = roster(c)
    assert len(rows) == 7, rows            # 6 cached + me
    by_key = {r[0]: r for r in rows}
    assert by_key["Mem00-Thunderstrike"][3] == "raid" and by_key["Mem01-Thunderstrike"][3] == "raid"
    assert by_key["Mem02-Thunderstrike"][3] == "offline"
    assert by_key["Cou-Thunderstrike"][3] == "raid"
    footer = strip_codes(c.eval("return DisasterZoneCouncilPanel.footer.text:GetText()"))
    assert footer == "7 members with lists · 3 in raid · 2 lists older than 7 days", footer
    ages = c.eval_py("local o = {} for i, r in ipairs(T_rows(DisasterZoneCouncilPanel.rosterView.list.box)) do o[i] = { rawget(r,'cdlData').key, r.age:GetText() } end return o")
    assert dict(ages)["Mem04-Thunderstrike"] == "10d", ages
    # a list for someone outside the guild is refused; a newer rev replaces; LIST_UPDATED refreshes the view
    assert c.eval("return T_put('Stranger-Thunderstrike', T_make_list('MAGE', 1, 1), 1)") is False
    # same rev, different content: only the owner's direct copy may replace it, a relay may not
    assert c.eval("return T_put('Mem02-Thunderstrike', T_make_list('HUNTER', 99, 1, 0, 0), 1, nil, 'Cou-Thunderstrike')") is False
    assert c.eval("return T_put('Mem02-Thunderstrike', T_make_list('HUNTER', 99, 1, 0, 0), 2)") is True
    w.tick(0.5)
    rows = roster(c)
    assert {r[0]: r for r in rows}["Mem02-Thunderstrike"][4] == {r[0]: r for r in rows}["Mem02-Thunderstrike"][5]
    # tamper: hash mismatch refused
    assert c.eval("""
      local d = T_make_list('MAGE', 3, 1)
      return ns.Store:Put('Mem03-Thunderstrike', { r = 9, ts = GetServerTime(), h = 'deadbeef', d = d }, 'direct')""") is False
    # items view: wanters come from the cached lists
    c.click(c.eval("return T_button(DisasterZoneCouncilPanel, 'Items')"))
    w.tick(0.3)
    total_claims = c.eval("local n = 0 for _, d in ipairs(T_data(DisasterZoneCouncilPanel.itemsView.tree.box)) do if d.type == 'boss' then n = n + d.count end end return n")
    assert total_claims > 0
    # member view of a cached member: version unknown (never seen), stale warning coloured
    c.eval("ns.CouncilUI:ShowMember('Mem04-Thunderstrike')")
    w.tick(0.3)
    info = c.eval("return DisasterZoneCouncilPanel.memberView.info:GetText()")
    assert "Member" in strip_codes(info) and "10d ago" in strip_codes(info) and "|cff" in info, info
    # a member leaving the guild disappears from the council views
    w.offline_members = [m for m in w.offline_members if m.name != "Mem03"]
    w._sync(roster_changed=True)
    w.tick(1)
    c.eval("ns.CouncilUI:SetView('roster')")
    w.tick(0.5)
    assert "Mem03-Thunderstrike" not in [r[0] for r in roster(c)]
    assert c.eval("return DisasterZoneDB.lists['Mem03-Thunderstrike'] ~= nil") is True, "pruned before 30 days"
    no_errors(w)


@case
def items_view_other_sources_node():
    w, c, members = real_council_world(n_members=2)
    w.define_item(190003, "Crafted Belt of Testing", 4, "INVTYPE_WAIST", 4, 4, ilvl=115)
    ok = c.eval("""
      local d = T_make_list('WARRIOR', 1, 1, 0, 0)
      d.ph[1][8] = { 190003, 0 }
      return T_put('Mem00-Thunderstrike', d, 5)""")
    assert ok is True
    c.slash("/dz council")
    c.eval("ns.CouncilUI:SetView('items')")
    w.tick(0.5)
    tree = c.eval_py("local o = {} for i, d in ipairs(T_data(DisasterZoneCouncilPanel.itemsView.tree.box)) do o[i] = { d.type, d.name, d.count } end return o")
    other = [t for t in tree if t[0] == "other"]
    assert other == [["other", "Other / no raid source", 1]], tree[-3:]
    idx = [i for i, t in enumerate(tree) if t[0] == "other"][0]
    c.click(c.eval("local i = ...; return T_rows(DisasterZoneCouncilPanel.itemsView.tree.box)[i]", idx + 1))
    w.tick(0.3)
    title = strip_codes(c.eval("return DisasterZoneCouncilPanel.itemsView.title:GetText()"))
    assert title == "Other / no raid source  -  1 items · 1 claims", title
    row = c.eval_py("local d = T_data(DisasterZoneCouncilPanel.itemsView.list.box)[1]; return { d.itemID, d.n }")
    assert row == [190003, 1], row
    src = strip_codes(c.eval("return T_rows(DisasterZoneCouncilPanel.itemsView.list.box)[1].source:GetText()"))
    assert src.startswith("No raid source"), src
    # a roster cell with that item jumps to the Other node (it has no boss)
    c.eval("ns.CouncilUI:SetView('roster')")
    w.tick(0.3)
    cell = c.eval("""
      for _, r in ipairs(T_rows(DisasterZoneCouncilPanel.rosterView.list.box)) do
        if rawget(r, 'cdlData') and r.cdlData.key == 'Mem00-Thunderstrike' then return r.cells[8] end
      end""")
    c.click(cell)
    w.tick(0.3)
    assert c.eval("return ns.CouncilUI:GetView()") == "member", "no-source item should open the member view"
    no_errors(w)


@case
def request_sync_button_real_council():
    w, c, members = real_council_world(n_members=2)
    w.tick(60)        # the automatic login HELLO (8-20 s after the roster) and its 30 s rate limit are over
    auto = [e for e in w.addon_log if e["sender"] == c.full_name and e["chat_type"] == "GUILD"
            and not e["prefix"].startswith("CDLp")]            # (CDLp*: the in-game update channel)
    assert len(auto) == 1, "expected exactly one automatic HELLO, got %d" % len(auto)
    c.slash("/dz council")
    w.tick(0.5)
    n0 = len(w.addon_log)
    btn = c.eval("return T_button(DisasterZoneCouncilPanel.footer, 'Request sync')")
    p0 = len(c.chat_frame)
    c.click(btn)
    w.tick(0.5)
    sent = [e for e in w.addon_log[n0:] if e["sender"] == c.full_name]
    assert len(sent) == 1 and sent[0]["chat_type"] == "GUILD" and sent[0]["prefix"] == "CDLc", sent
    assert any("Sync requested" in l for l in printed_since(c, p0))
    assert c.eval("local b = ...; return b:IsEnabled()", btn) in (False, 0), "button not disabled after a request"
    w.tick(31)
    assert c.eval("local b = ...; return b:IsEnabled()", btn) in (True, 1)
    c.hover(btn)
    assert tt_lines(c)[0][0] == "Request sync"
    no_errors(w)


@case
def request_sync_buttons_do_not_claim_success_when_rate_limited():
    # The automatic HELLO goes out 8-20 s after login and rate-limits the next one for 30 s. Clicking
    # "Request sync" (Council footer or Settings > About) in that window sends nothing; the player must not be
    # told "Sync requested." (/dz sync correctly says "please wait").
    w, c, members = real_council_world(n_members=2)
    w.run_until(lambda: any(e["sender"] == c.full_name and e["chat_type"] == "GUILD" for e in w.addon_log), 40)
    problems = []
    for where, expr in (("council footer", "T_button(DisasterZoneCouncilPanel.footer, 'Request sync')"),
                        ("settings", "T_button(ns.MainFrame:GetPanel('settings'), 'Request sync')")):
        c.slash("/dz council" if where == "council footer" else "/dz settings")
        w.tick(0.3)
        n0, p0 = len(w.addon_log), len(c.chat_frame)
        c.click(c.eval("return " + expr))
        w.tick(0.5)
        sent = [e for e in w.addon_log[n0:] if e["sender"] == c.full_name]
        said = printed_since(c, p0)
        if not sent and any("Sync requested" in l for l in said):
            problems.append("%s: nothing was sent (rate limited) but chat says %r" % (where, said))
    # /dz sync is the reference behaviour
    p0 = len(c.chat_frame)
    c.slash("/dz sync")
    assert any("please wait" in l for l in printed_since(c, p0)), printed_since(c, p0)
    assert not problems, " | ".join(problems)
    no_errors(w)


@case
def corrupt_cached_lists_do_not_break_the_council_tab():
    w = World()
    seed_guild_council(w, ["Cou"])
    for n in ("Bad1", "Bad2", "Bad3", "Bad4"):
        w.add_offline_member(n, "MAGE", 3)
    c = Client(w, "Cou", guild_rank=1)
    c.set_saved_variable("DisasterZoneDB", """{ schema = 1, lists = {
        ["Bad1-Thunderstrike"] = { rev = 1, ts = "x", data = { ph = { [1] = { [1] = "junk", [2] = { "a", -3 } } }, ob = 7, eq = { [1] = "x" } } },
        ["Bad2-Thunderstrike"] = { rev = 2, data = "nope" },
        ["Bad3-Thunderstrike"] = "garbage",
        ["Bad4-Thunderstrike"] = { rev = 3, ts = 100, data = { cl = 5, sp = {}, ph = { [7] = {}, x = 1 } } } },
      ledger = { bad = "entry", ["a1"] = { id = "a1", i = "x", w = 5 }, ["m2"] = { id = "m2", i = 28770, w = "Bad1-Thunderstrike", ts = "y" } } }""")
    c.load_addon()
    w.tick(3)
    install_helpers(c)
    for view in ("roster", "items", "member"):
        c.slash("/dz council")
        c.eval("ns.CouncilUI:SetView(...)", view)
        w.tick(0.5)
        if view == "roster":
            for i in range(1, 1 + c.eval("return #T_rows(DisasterZoneCouncilPanel.rosterView.list.box)")):
                cell = c.eval("local i = ...; return T_rows(DisasterZoneCouncilPanel.rosterView.list.box)[i].cells[1]", i)
                c.hover(cell)
                c.hover(c.eval("local i = ...; return T_rows(DisasterZoneCouncilPanel.rosterView.list.box)[i]", i))
    c.eval("ns.CouncilUI:ShowMember('Bad1-Thunderstrike')")
    w.tick(0.3)
    c.slash("/dz log")
    w.tick(0.5)
    c.show_tooltip_item(28770)
    no_errors(w)


if __name__ == "__main__":
    run_all()

"""My BiS tab: phase buttons, picker (every slot, main + alt, every class), selecting, context menu, copy / clear
phase, drag & drop, shift-click links, two-hander rule, progress card, spec dropdown.

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_mybis.py
"""
from _common import (case, run_all, solo, no_errors, World, Client, install_helpers, menu_texts, menu_find,
                     printed_since, strip_codes, tt_lines, seed_guild_council)

CLASSES = ["WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID"]
DUAL_WIELD = {"WARRIOR", "ROGUE", "HUNTER", "SHAMAN"}
ARMOR_SIDS = {1, 3, 5, 6, 7, 8, 9, 10}
SLOT_LABELS = {1: "Head", 2: "Neck", 3: "Shoulder", 4: "Back", 5: "Chest", 6: "Wrist", 7: "Hands", 8: "Waist",
               9: "Legs", 10: "Feet", 11: "Ring 1", 12: "Ring 2", 13: "Trinket 1", 14: "Trinket 2",
               15: "Main Hand", 16: "Off Hand", 17: "Ranged / Relic"}
CRAFTED_HELM = 190001   # custom non-raid item defined in the world

PICKER_ROWS = """
local box = T_box(CDLootPicker)
local out = {}
for i, d in ipairs(T_data(box)) do
  local loc = d.itemID and select(4, C_Item.GetItemInfoInstant(d.itemID)) or ""
  local tier = d.itemID and ns.Data.TierPieceClass and ns.Data.TierPieceClass[d.itemID] or ""
  out[i] = { d.type, d.itemID or 0, d.via or "", d.viaItem or 0, loc or "", tier,
             d.itemID and ns.ItemDB:IsToken(d.itemID) and 1 or 0 }
end
return out"""


def setup(name="Alice", class_file="PALADIN", phase=1, talents=(41, 20, 0), **kw):
    """A raider whose stored guild council list (Addendum E, no members needed here) carries the guild phase."""
    w, c = solo(name, class_file=class_file, guild_rank=3, tick=4, council=[], phase=phase, talents=talents, **kw)
    w.define_item(CRAFTED_HELM, "Crafted Test Helm", 4, "INVTYPE_HEAD", 4, 4, ilvl=115)
    install_helpers(c)
    c.slash("/cdl")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "mybis"
    return w, c


def tile_btn(c, sid, which="main"):
    return c.eval("local s, w = ...; return T_tile(s)[w]", sid, which)


def tile_text(c, sid):
    return c.eval("local t = T_tile(...); return t.line1:GetText(), t.line2:GetText()", sid)


def picker_rows(c):
    return c.eval_py(PICKER_ROWS) or []


def item_rows(c):
    return [r for r in picker_rows(c) if r[0] == "item"]


def click_row(c, item_id):
    idx = c.eval("""
      local id = ...
      for i, r in ipairs(T_rows(T_box(CDLootPicker))) do
        local d = rawget(r, "__cdlData")
        if d and d.type == "item" and d.itemID == id then return i end
      end""", item_id)
    assert idx, "item %s not in the picker list" % item_id
    row = c.eval("local i = ...; return T_rows(T_box(CDLootPicker))[i]", idx)
    c.click(row)
    c.world.tick(0.1)


def candidate(c, sid, pred_lua="return true", phase=5, klass=None):
    """First candidate id for sid (usable by the player's class) matching a Lua predicate on (id, loc)."""
    return c.eval("""
      local sid, phase, klass, pred = ...
      local f = loadstring(pred)
      for _, r in ipairs(ns.ItemDB:GetCandidates(sid, { maxPhase = phase, class = klass, usableOnly = true })) do
        local loc = select(4, C_Item.GetItemInfoInstant(r.itemID))
        if f(r.itemID, loc) then return r.itemID end
      end""", sid, phase, klass or c.class_file, "local id, loc = ...; " + pred_lua)


def card_texts(c):
    return c.eval_py("""
      return { T_card().title:GetText() }""")


def progress(c, phase=None):
    return c.eval_py("local p = ns.MyBiS:GetProgress(...); return { p.filled, p.total, p.disabled, p.obtained }", phase)


def tried_on(c):
    """item IDs the card's model was dressed in on its last Dress (the mock records TryOn)."""
    return c.eval_py("""
      local m = T_card().model
      local out = {}
      for _, v in ipairs(m.T_tried or {}) do out[#out + 1] = tonumber(v:match("item:(%d+)")) end
      table.sort(out)
      return out""")


# ------------------------------------------------------------------------------------------------------------------
@case
def phase_buttons_select_phase_and_mark_guild_phase():
    w, c = setup(phase=2)
    assert c.eval("return ns.MyBiS:GetPhase()") == 2, "default phase must be the guild phase"
    for p in (1, 2, 3, 4, 5, 3):
        c.click(c.eval("return T_button(T_mybis(), ...)", "P%d" % p))
        w.tick(0.1)
        assert c.eval("return ns.MyBiS:GetPhase()") == p
        prog = card_texts(c)[0]
        assert prog.startswith("P%d" % p), prog
        states = c.eval_py("""
          local out = {}
          for p = 1, 5 do
            local b = T_button(T_mybis(), "P" .. p)
            out[p] = { T_state(b).highlight_locked and 1 or 0, rawget(b, "marker"):IsShown() and 1 or 0 }
          end
          return out""")
        assert [s[0] for s in states] == [1 if i == p else 0 for i in range(1, 6)], states
        assert [s[1] for s in states] == [1 if i == 2 else 0 for i in range(1, 6)], states
    # the user picked a phase: a later CONFIG_UPDATED (the GM's list moves the guild to P4) must not override it
    seed_guild_council(w, [], phase=4)
    w.tick(1)
    assert c.eval("return ns.Guild:GetGuildPhase()") == 4
    assert c.eval("return ns.MyBiS:GetPhase()") == 3
    # hovering a phase button shows its raids and the guild marker line
    c.hover(c.eval("return T_button(T_mybis(), 'P4')"))
    lines = [strip_codes(l[0]) for l in c.eval_py("return T_ttlines()")]
    assert lines[0] == "Phase 4" and "Guild's current phase" in lines, lines
    no_errors(w)


@case
def picker_every_slot_main_and_alt_every_class():
    w = World()
    clients = []
    for i, klass in enumerate(CLASSES):
        c = Client(w, "Pick" + "abcdefghi"[i], class_file=klass, guild_rank=3)
        c.load_addon()
        clients.append(c)
    w.tick(3)
    problems = []
    for c in clients:
        install_helpers(c)
        c.slash("/cdl")
        w.tick(0.1)
        klass = c.class_file
        for sid in range(1, 18):
            for which in ("main", "alt"):
                c.click(tile_btn(c, sid, which))
                st = c.eval_py("return {ns.Picker:IsOpen(), ns.Picker:GetState()}")
                if st != [True, 1, sid, which]:
                    problems.append("%s sid %d %s: picker state %r" % (klass, sid, which, st))
                    continue
                title = c.eval("return CDLootPicker.titleText:GetText()")
                want = "Choose %s (%s)  ·  P1" % (SLOT_LABELS[sid], "Alt" if which == "alt" else "Main")
                if title != want:
                    problems.append("%s sid %d: title %r" % (klass, sid, title))
                armor_cb = c.eval("return T_checkbox(CDLootPicker, 'My armor type only'):IsShown()")
                if bool(armor_cb) != (sid in ARMOR_SIDS):
                    problems.append("%s sid %d: armor checkbox shown=%r" % (klass, sid, armor_cb))
                items = item_rows(c)
                if not items:
                    problems.append("%s sid %d %s: empty candidate list" % (klass, sid, which))
                for _, iid, via, via_item, loc, tier, is_token in items:
                    fits = c.eval("return ns.ItemDB:FitsSlot(...)", iid, sid)
                    if not fits:
                        problems.append("%s sid %d: %d (%s) does not fit" % (klass, sid, iid, loc))
                    if is_token:
                        problems.append("%s sid %d: token %d listed (pieces expected)" % (klass, sid, iid))
                    if tier and tier != klass:
                        problems.append("%s sid %d: other class tier piece %d (%s)" % (klass, sid, iid, tier))
                    if via == "token" and not tier and sid not in (2, 11, 12):
                        problems.append("%s sid %d: token piece %d without class" % (klass, sid, iid))
                    if sid == 16 and loc in ("INVTYPE_WEAPON", "INVTYPE_WEAPONOFFHAND") and klass not in DUAL_WIELD:
                        problems.append("%s: one-hander %d (%s) offered for the off hand" % (klass, iid, loc))
                    if sid == 16 and loc == "INVTYPE_SHIELD" and klass not in ("WARRIOR", "PALADIN", "SHAMAN"):
                        problems.append("%s: shield %d offered" % (klass, iid))
                if sid == 16 and klass in DUAL_WIELD and not any(
                        r[4] in ("INVTYPE_WEAPON", "INVTYPE_WEAPONOFFHAND") for r in items):
                    problems.append("%s: dual wielder gets no one-handers for the off hand" % klass)
                # the highlighted tile is the one being edited
                hl = c.eval_py("local o = {} for s = 1, 17 do o[s] = T_tile(s).editBorder:IsShown() and 1 or 0 end return o")
                if hl != [1 if s == sid else 0 for s in range(1, 18)]:
                    problems.append("%s sid %d: highlight %r" % (klass, sid, hl))
        # own tier pieces must appear for the tier slots somewhere up to P5 ("All phases"; Addendum F §35 replaced
        # the old scope dropdown's "All raids" with the phase dropdown's "All phases")
        c.click(tile_btn(c, 1))
        c.dropdown_menu(c.eval("return T_dropdown(CDLootPicker, '-')"))
        c.menu_select("All phases")
        tier_rows = [r for r in item_rows(c) if r[5]]
        if not tier_rows or any(r[5] != klass for r in tier_rows):
            problems.append("%s: tier heads with 'All phases': %r" % (klass, [(r[1], r[5]) for r in tier_rows][:5]))
        c.eval("ns.Picker:Close()")
        # closing the picker clears the tile highlight
        if c.eval("local n = 0 for s = 1, 17 do if T_tile(s).editBorder:IsShown() then n = n + 1 end end return n") != 0:
            problems.append("%s: highlight left after closing the picker" % klass)
    assert not problems, "\n".join(problems[:40]) + ("\n... %d more" % (len(problems) - 40) if len(problems) > 40 else "")
    no_errors(w)


@case
def picker_select_item_updates_tile_and_commits():
    w, c = setup()
    c.click(tile_btn(c, 1))
    first = item_rows(c)[0][1]
    click_row(c, first)
    assert c.eval("return ns.Picker:IsOpen()") is False
    assert c.eval_py("return {ns.BiS:GetSlot(1, 1)}") == [first]
    name = c.eval("return ns.ItemDB:GetName(...)", first)
    l1, l2 = tile_text(c, 1)
    assert name in l1, (name, l1)
    assert c.eval("return T_tile(1).main.itemID") == first
    # alt for the same slot
    c.click(tile_btn(c, 1, "alt"))
    rows = item_rows(c)
    marks = c.eval_py("""
      local o = {}
      for _, r in ipairs(T_rows(T_box(CDLootPicker))) do
        local d = rawget(r, "__cdlData")
        if d.type == "item" and r.mark1:IsShown() then o[#o + 1] = { d.itemID, r.mark1:GetText() } end
      end
      return o""")
    assert any(m[0] == first and "Main" in m[1] for m in marks), marks
    alt = next(r[1] for r in rows if r[1] != first)
    click_row(c, alt)
    assert c.eval_py("return {ns.BiS:GetSlot(1, 1)}") == [first, alt]
    assert c.eval("return T_tile(1).alt.itemID") == alt
    # picking the current main as alt swaps them
    c.click(tile_btn(c, 1, "alt"))
    click_row(c, first)
    assert c.eval_py("return {ns.BiS:GetSlot(1, 1)}") == [alt, first]
    # the list is committed 8 s after the last edit (rev 1), and the status line follows
    assert c.eval("return ns.BiS:IsDirty()") is True
    w.tick(9)
    assert c.eval("return ns.BiS:GetRecord().rev") == 1
    assert c.eval("return ns.BiS:IsDirty()") is False
    # closing the window commits immediately
    c.click(tile_btn(c, 2))
    click_row(c, item_rows(c)[0][1])
    c.slash("/cdl")
    w.tick(0.1)
    assert c.eval("return ns.BiS:GetRecord().rev") == 2
    no_errors(w)


@case
def picker_search_scope_filters_and_clear():
    w, c = setup(class_file="WARRIOR", talents=(0, 41, 20))
    c.click(tile_btn(c, 15))
    base = item_rows(c)
    assert base
    sb = c.eval("return T_template(CDLootPicker, 'SearchBoxTemplate')[1]")
    # search by item name (case-insensitive) and by numeric item ID
    target = base[3][1]
    tname = c.eval("return ns.ItemDB:GetName(...)", target)
    c.type_text(sb, tname[:6].upper())
    w.tick(0.3)
    got = item_rows(c)
    assert got and all(tname[:6].lower() in c.eval("return ns.ItemDB:GetName(...)", r[1]).lower()
                       or c.eval("return (ns.ItemDB:GetSourceText(...) or ''):lower()", r[1]) for r in got), got
    c.type_text(sb, str(target))
    w.tick(0.3)
    assert [r[1] for r in item_rows(c)] == [target]
    c.type_text(sb, "zzzz no such item")
    w.tick(0.3)
    assert item_rows(c) == []
    # Addendum F §35: the empty text names every source now ("No items match. Try 'All phases', ...")
    assert c.eval("return T_textregion(CDLootPicker, 'No items match'):IsVisible()") is True
    # boss search
    c.type_text(sb, "prince")
    w.tick(0.3)
    assert item_rows(c), "boss-name search found nothing"
    c.type_text(sb, "")
    w.tick(0.3)
    assert len(item_rows(c)) == len(base)
    # Addendum F §35: the old scope dropdown (Addendum B §21.3) became a phase dropdown + a Sources checkbox
    # dropdown (default Raids + 5-man dungeons)
    dd = c.eval("return T_dropdown(CDLootPicker, '-')")
    menu = c.dropdown_menu(dd)
    assert [e[2] for e in menu_texts(menu)] == ["Up to P1", "Only P1", "All phases"], menu_texts(menu)
    sdd = c.eval("return T_dropdown(CDLootPicker, 'Raids + 5-man')")
    assert sdd, "no Sources dropdown"
    assert [(e[1], e[2]) for e in menu_texts(c.dropdown_menu(sdd))] == [
        ("title", "Show items from"), ("checkbox", "Raids"), ("checkbox", "5-man dungeons"), ("checkbox", "Crafted"),
        ("checkbox", "Reputation"), ("checkbox", "Badge vendors"), ("checkbox", "PvP")]
    kinds = set(c.eval_py("local o = {} for _, d in ipairs(T_data(T_box(CDLootPicker))) do "
                          "if d.type == 'item' then o[#o + 1] = d.kind end end return o"))
    assert kinds == {"raid", "dungeon"}, kinds
    c.dropdown_menu(dd)
    c.menu_select("All phases")
    allr = item_rows(c)
    assert len(allr) > len(base)
    c.dropdown_menu(dd)
    c.menu_select("Only P1")
    phases = c.eval_py("""
      local o = {}
      for _, d in ipairs(T_data(T_box(CDLootPicker))) do if d.type == 'item' then o[#o + 1] = d.ref.phase end end
      return o""")
    assert phases and set(phases) == {1}, set(phases)
    # unticking "5-man dungeons" leaves the raid items only (the old "Raids up to P1" list)
    c.dropdown_menu(sdd)
    c.menu_select("5-man dungeons")
    kinds = set(c.eval_py("local o = {} for _, d in ipairs(T_data(T_box(CDLootPicker))) do "
                          "if d.type == 'item' then o[#o + 1] = d.kind end end return o"))
    assert kinds == {"raid"}, kinds
    c.eval("ns.Picker:SetSourceEnabled('dungeons', true)")
    # "Usable by my class": off shows more, and unusable ones dimmed
    c.dropdown_menu(dd)
    c.menu_select("Up to P1")
    c.click(c.eval("return T_checkbox(CDLootPicker, 'Usable by my class')"))
    w.tick(0.1)
    assert c.eval("return ns.ItemDB:GetCandidates(15, {maxPhase = 1})") is not None
    unfiltered = item_rows(c)
    assert len(unfiltered) >= len(base)
    dims = c.eval("local n = 0 for _, r in ipairs(T_rows(T_box(CDLootPicker))) do if r:GetAlpha() < 1 then n = n + 1 end end return n")
    assert dims == len(unfiltered) - len(base), (dims, len(unfiltered), len(base))
    c.click(c.eval("return T_checkbox(CDLootPicker, 'Usable by my class')"))
    # the filter state is kept for the next opening (session), the search is reset
    c.eval("ns.Picker:Close()")
    c.click(tile_btn(c, 16))
    assert c.eval("return T_template(CDLootPicker, 'SearchBoxTemplate')[1]:GetText()") == ""
    # Clear button: disabled without a pick, clears the pick with one
    clear = c.eval("return T_button(CDLootPicker, 'Clear')")
    assert c.eval("local b = ...; return b:IsEnabled()", clear) in (False, 0)
    click_row(c, item_rows(c)[0][1])
    c.click(tile_btn(c, 16))
    assert c.eval("local b = ...; return b:IsEnabled()", clear) in (True, 1)
    c.click(clear)
    assert c.eval_py("return {ns.BiS:GetSlot(1, 16)}") == []
    assert c.eval("return ns.Picker:IsOpen()") is True
    no_errors(w)


@case
def context_menu_swap_mark_clear_link():
    w, c = setup()
    ids = [r[1] for r in (c.click(tile_btn(c, 5)) or item_rows(c))][:2]
    c.eval("ns.Picker:Close()")
    c.eval("ns.BiS:SetSlot(1, 5, 'main', ...)", ids[0])
    c.eval("ns.BiS:SetSlot(1, 5, 'alt', ...)", ids[1])
    w.tick(0.2)
    # empty slot menu: only choose entries (+ Addendum F §36: disable the slot)
    c.click(tile_btn(c, 6), "RightButton")
    assert [e[2] for e in menu_texts(c.last_menu())] == ["Wrist  ·  P1", "Choose main...", "Choose alt...", None,
                                                         "Disable slot (P1)", "Disable in all phases"]
    c.menu_select("Choose alt...")
    assert c.eval_py("return {ns.Picker:GetState()}") == [1, 6, "alt"]
    c.eval("ns.Picker:Close()")
    # full menu
    c.click(tile_btn(c, 5), "RightButton")
    texts = [e[2] for e in menu_texts(c.last_menu())]
    assert texts == ["Chest  ·  P1", "Choose main...", "Choose alt...", "Swap main / alt", "Mark obtained",
                     "Clear slot", "Link main in chat", None, "Disable slot (P1)", "Disable in all phases"], texts
    c.menu_select("Swap main / alt")
    w.tick(0.2)
    assert c.eval_py("return {ns.BiS:GetSlot(1, 5)}") == [ids[1], ids[0]]
    assert c.eval("return T_tile(5).main.itemID") == ids[1]
    # mark obtained (manual) -> tile shows it, card counts it, menu offers the undo
    c.click(tile_btn(c, 5), "RightButton")
    c.menu_select("Mark obtained")
    w.tick(0.2)
    assert c.eval("return ns.BiS:GetObtainedState(...)", ids[1]) == "manual"
    assert "Marked obtained" in tile_text(c, 5)[1]
    assert card_texts(c)[0].startswith("P1  ·  1 / 17 obtained"), card_texts(c)[0]
    assert ids[1] in (c.eval_py("return ns.BiS:GetData().ob") or [])
    c.click(tile_btn(c, 5), "RightButton")
    assert "Mark not obtained" in [e[2] for e in menu_texts(c.last_menu())]
    c.menu_select("Mark not obtained")
    w.tick(0.2)
    assert c.eval("return ns.BiS:GetObtainedState(...)", ids[1]) is None
    # equipped item: no manual toggle, a title explains why
    c.equip({5: ids[1]})
    w.tick(2)
    c.click(tile_btn(c, 5), "RightButton")
    texts = [e[2] for e in menu_texts(c.last_menu())]
    assert "Obtained: Equipped" in texts and "Mark obtained" not in texts, texts
    assert "Equipped" in tile_text(c, 5)[1]
    # link in chat
    c.eval("T_clear_links()")
    c.menu_select("Link main in chat")
    links = c.eval_py("return T_links()")
    assert links and ("item:%d:" % ids[1]) in links[-1], links
    # clear
    c.click(tile_btn(c, 5), "RightButton")
    c.menu_select("Clear slot")
    w.tick(0.2)
    assert c.eval_py("return {ns.BiS:GetSlot(1, 5)}") == []
    assert "click to choose" in tile_text(c, 5)[0]
    # right-click on the ALT button opens the same menu
    c.eval("ns.BiS:SetSlot(1, 7, 'alt', ...)", c.eval("return ns.ItemDB:GetCandidates(7, {maxPhase=1, class='PALADIN', usableOnly=true})[1].itemID"))
    c.click(tile_btn(c, 7, "alt"), "RightButton")
    texts = [e[2] for e in menu_texts(c.last_menu())]
    assert texts[:1] == ["Hands  ·  P1"] and "Swap main / alt" in texts, texts
    no_errors(w)


@case
def copy_phase_and_clear_phase():
    w, c = setup()
    ids = {}
    for sid in (1, 2, 3):
        ids[sid] = c.eval("local s = ...; return ns.ItemDB:GetCandidates(s, {maxPhase=1, class='PALADIN', usableOnly=true})[2].itemID", sid)
        c.eval("local s, id = ...; ns.BiS:SetSlot(1, s, 'main', id)", sid, ids[sid])
    other_neck = c.eval("return ns.ItemDB:GetCandidates(2, {maxPhase=1, class='PALADIN', usableOnly=true})[3].itemID")
    c.click(c.eval("return T_button(T_mybis(), 'P2')"))
    c.eval("ns.BiS:SetSlot(2, 2, 'main', ...)", other_neck)
    copy = c.eval("return T_dropdown(T_mybis(), 'Copy from')")
    menu = c.dropdown_menu(copy)
    texts = [e[2] for e in menu_texts(menu)]
    assert texts == ["Copy into P2", "Copy P1 (fill empty)", "Copy P1 (overwrite)"], texts
    c.menu_select("Copy P1 (fill empty)")
    w.tick(0.2)
    assert c.eval("return ns.BiS:GetSlot(2, 1)") == ids[1]
    assert c.eval("return ns.BiS:GetSlot(2, 2)") == other_neck, "fill-empty overwrote a chosen slot"
    assert c.eval("return T_tile(1).main.itemID") == ids[1], "doll not refreshed after copy"
    c.dropdown_menu(copy)
    c.menu_select("Copy P1 (overwrite)")
    w.tick(0.2)
    assert c.eval("return ns.BiS:GetSlot(2, 2)") == ids[2]
    # phase with nothing elsewhere: explanatory title
    c.click(c.eval("return T_button(T_mybis(), 'P5')"))
    menu = c.dropdown_menu(copy)
    assert "Copy P1 (fill empty)" in [e[2] for e in menu_texts(menu)]
    # clear phase: confirmation popup, then empty
    c.click(c.eval("return T_button(T_mybis(), 'P2')"))
    n0 = len(c.chat_frame)
    c.click(c.eval("return T_button(T_mybis(), 'Clear phase')"))
    assert "CDLOOT_CLEAR_PHASE" in c.popups()
    c.cancel_popup("CDLOOT_CLEAR_PHASE")
    assert c.eval("return #ns.BiS:GetPhaseItems(2)") == 3
    c.click(c.eval("return T_button(T_mybis(), 'Clear phase')"))
    c.accept_popup("CDLOOT_CLEAR_PHASE")
    w.tick(0.2)
    assert c.eval("return #ns.BiS:GetPhaseItems(2)") == 0
    assert c.eval("return #ns.BiS:GetPhaseItems(1)") == 3, "clearing P2 touched P1"
    assert progress(c, 2)[0] == 0
    # clearing an empty phase only explains
    c.click(c.eval("return T_button(T_mybis(), 'Clear phase')"))
    assert "CDLOOT_CLEAR_PHASE" not in c.popups()
    assert any("P2 has no picks to clear" in l for l in printed_since(c, n0))
    # Suggest is hidden without LoonBestInSlot
    assert c.eval("return T_dropdown(T_mybis(), 'Suggest'):IsShown()") is False
    no_errors(w)


@case
def drag_item_onto_tile():
    w, c = setup()
    ring = c.eval("return ns.ItemDB:GetCandidates(11, {maxPhase=1})[1].itemID")
    head = c.eval("return ns.ItemDB:GetCandidates(1, {maxPhase=1, class='PALADIN', usableOnly=true})[1].itemID")
    n0 = len(c.chat_frame)
    # 1) drag-release (OnReceiveDrag) of a crafted helm onto the head main button
    c.set_cursor_item(CRAFTED_HELM)
    c.eval("T_script(T_tile(1).main, 'OnReceiveDrag')")
    w.tick(0.1)
    assert c.eval("return ns.BiS:GetSlot(1, 1)") == CRAFTED_HELM
    assert c.eval("return GetCursorInfo()") is None, "cursor not cleared after the drop"
    assert c.eval("return ns.Picker:IsOpen()") is False
    assert "Other source" in strip_codes(tile_text(c, 1)[1]), tile_text(c, 1)
    # 2) click-drop (OnMouseUp + OnClick in the same frame) on the alt button: sets alt, no picker
    c.set_cursor_item(head)
    c.eval("T_script(T_tile(1).alt, 'OnMouseUp', 'LeftButton')")
    c.click(tile_btn(c, 1, "alt"))
    w.tick(0.1)
    assert c.eval_py("return {ns.BiS:GetSlot(1, 1)}") == [CRAFTED_HELM, head]
    assert c.eval("return ns.Picker:IsOpen()") is False, "the click that dropped the item also opened the picker"
    # 3) an item that does not fit is refused with a message, the cursor keeps nothing weird
    c.set_cursor_item(ring)
    c.eval("T_script(T_tile(1).main, 'OnReceiveDrag')")
    w.tick(0.1)
    assert c.eval_py("return {ns.BiS:GetSlot(1, 1)}") == [CRAFTED_HELM, head]
    assert any("doesn't fit the Head slot" in l for l in printed_since(c, n0)), printed_since(c, n0)
    # 4) dropping on the tile text area sets the main
    c.set_cursor_item(ring)
    c.eval("T_script(T_tile(12), 'OnReceiveDrag')")
    w.tick(0.1)
    assert c.eval("return ns.BiS:GetSlot(1, 12)") == ring
    # 5) dropping while the picker is open (on the picker window) sets the picker's slot
    c.click(tile_btn(c, 11))
    c.set_cursor_item(ring)
    c.eval("T_script(CDLootPicker, 'OnReceiveDrag')")
    w.tick(0.1)
    assert c.eval("return ns.BiS:GetSlot(1, 11)") == ring
    assert c.eval("return ns.Picker:IsOpen()") is False
    # 6) nothing on the cursor: a plain drop event does nothing
    c.eval("T_script(T_tile(2).main, 'OnReceiveDrag')")
    assert c.eval_py("return {ns.BiS:GetSlot(1, 2)}") == []
    no_errors(w)


@case
def shift_click_link_into_picker():
    w, c = setup()
    link = c.eval("return (select(2, C_Item.GetItemInfo(...)))", CRAFTED_HELM)
    ring = c.eval("return ns.ItemDB:GetCandidates(11, {maxPhase=1})[1].itemID")
    ring_link = c.eval("return (select(2, C_Item.GetItemInfo(...)))", ring)
    # picker closed: links are ignored
    c.eval("ChatFrameUtil.InsertLink(...)", link)
    assert c.eval_py("return {ns.BiS:GetSlot(1, 1)}") == []
    c.click(tile_btn(c, 1))
    n0 = len(c.chat_frame)
    # a link that does not fit: refused, picker stays open
    c.eval("ChatFrameUtil.InsertLink(...)", ring_link)
    assert c.eval("return ns.Picker:IsOpen()") is True
    assert c.eval_py("return {ns.BiS:GetSlot(1, 1)}") == []
    assert any("doesn't fit" in l for l in printed_since(c, n0))
    # our own link clicks (shift-click inside the picker list) must not pick
    first = item_rows(c)[0][1]
    c.set_modifiers(shift=True)
    row = c.eval("return T_rows(T_box(CDLootPicker))[3]")
    c.click(row)
    c.set_modifiers()
    assert c.eval_py("return {ns.BiS:GetSlot(1, 1)}") == [], "shift-clicking a picker row picked it"
    assert c.eval("return ns.Picker:IsOpen()") is True
    assert c.eval_py("return T_links()")[-1].find("item:%d:" % first) >= 0
    # an external shift-click (bags / chat) picks the item and closes
    c.eval("ChatFrameUtil.InsertLink(...)", link)
    w.tick(0.1)
    assert c.eval_py("return {ns.BiS:GetSlot(1, 1)}") == [CRAFTED_HELM]
    assert c.eval("return ns.Picker:IsOpen()") is False
    # alt via link
    c.click(tile_btn(c, 1, "alt"))
    head = item_rows(c)[0][1]
    c.eval("ChatFrameUtil.InsertLink(select(2, C_Item.GetItemInfo(...)))", head)
    assert c.eval_py("return {ns.BiS:GetSlot(1, 1)}") == [CRAFTED_HELM, head]
    no_errors(w)


@case
def two_hander_locks_off_hand():
    w, c = setup()
    two_h = candidate(c, 15, "return loc == 'INVTYPE_2HWEAPON'")
    one_h = candidate(c, 15, "return loc == 'INVTYPE_WEAPON' or loc == 'INVTYPE_WEAPONMAINHAND'")
    shield = candidate(c, 16, "return loc == 'INVTYPE_SHIELD'")
    assert two_h and one_h and shield, (two_h, one_h, shield)
    c.click(tile_btn(c, 15))
    click_row(c, two_h)
    w.tick(0.1)
    oh_alpha = c.eval("return T_tile(16):GetAlpha()")
    assert oh_alpha < 1, oh_alpha
    assert "Two-hander equipped in main hand" in strip_codes(tile_text(c, 16)[1])
    prog = card_texts(c)
    assert "0 / 16 obtained" in prog[0] and progress(c)[:2] == [1, 16], prog
    # still clickable: the off hand picker opens (a 2H + shield list is allowed but stays flagged)
    c.click(tile_btn(c, 16))
    assert c.eval_py("return {ns.Picker:GetState()}") == [1, 16, "main"]
    click_row(c, shield)
    assert c.eval("return T_tile(16):GetAlpha()") < 1
    assert "Two-hander equipped in main hand" in strip_codes(tile_text(c, 16)[1])
    # hover tooltip explains it
    c.hover(tile_btn(c, 16))
    tt = [strip_codes(l[0]) for l in c.eval_py("return T_ttlines()")]
    assert "Two-hander equipped in main hand" in tt, tt
    # switching to a one-hander unlocks the off hand
    c.eval("ns.BiS:SetSlot(1, 15, 'main', ...)", one_h)
    w.tick(0.2)
    assert c.eval("return T_tile(16):GetAlpha()") == 1
    assert "Two-hander" not in strip_codes(tile_text(c, 16)[1] or "")
    assert "/ 17 obtained" in card_texts(c)[0]
    no_errors(w)


@case
def progress_card_model_wears_bis_picks():
    w, c = setup()
    assert card_texts(c)[0] == "P1  ·  0 / 17 obtained", card_texts(c)
    # record what the model is dressed in (the mock's DressUpModel has no state for it)
    c.eval("""
      local m = T_card().model
      local tryOn = m.TryOn
      m.TryOn = function(self, link, ...) self.T_tried[#self.T_tried + 1] = link; if tryOn then return tryOn(self, link, ...) end end
      local setUnit = m.SetUnit
      m.SetUnit = function(self, ...) self.T_tried = {}; if setUnit then return setUnit(self, ...) end end
      m.T_tried = {}""")

    def tried():
        return sorted(c.eval_py("""local o = {}
          for _, v in ipairs(T_card().model.T_tried) do o[#o + 1] = tonumber(v:match("item:(%d+)")) end
          return o""") or [])

    kara = c.eval_py("""
      local out = {}
      for sid = 2, 4 do
        for _, r in ipairs(ns.ItemDB:GetCandidates(sid, {maxPhase=1, class='PALADIN', usableOnly=true})) do
          if r.ref.raid.key == 'Karazhan' and not r.ref.boss.isTrash then out[#out + 1] = { sid, r.itemID } break end
        end
      end
      return out""")
    assert len(kara) == 3, kara
    for sid, iid in kara:
        c.eval("local s, i = ...; ns.BiS:SetSlot(1, s, 'main', i)", sid, iid)
    c.eval("ns.BiS:SetSlot(1, 1, 'main', ...)", CRAFTED_HELM)
    w.tick(0.2)
    assert card_texts(c)[0] == "P1  ·  0 / 17 obtained" and progress(c, 1)[0] == 4
    assert tried() == sorted([CRAFTED_HELM] + [k[1] for k in kara]), tried()
    # a disabled slot keeps the equipped item (its pick isn't tried on)
    c.eval("ns.BiS:SetSlotDisabled(1, 1, true)")
    w.tick(0.2)
    assert CRAFTED_HELM not in tried(), tried()
    # obtained items count in the title
    c.equip({2: kara[0][1]})
    w.tick(2)
    assert card_texts(c)[0] == "P1  ·  1 / 16 obtained", card_texts(c)
    no_errors(w)


@case
def spec_dropdown_and_auto_detect():
    w, c = setup(talents=(41, 20, 0))
    dd = c.eval("return T_dropdown(T_mybis(), 'Choose spec')")
    menu = c.dropdown_menu(dd)
    entries = menu_texts(menu)
    assert [e[2] for e in entries] == ["Holy", "Protection", "Retribution", "Auto-detect"], entries
    sel = [e for e in menu["children"] if e.get("selected")]
    assert [e["text"] for e in sel] == ["Holy"], sel
    c.menu_select("Retribution")
    w.tick(0.1)
    assert c.eval("return ns.BiS:GetSpec()") == "Retribution"
    assert c.eval("local d = ...; return d:GetText()", dd) == "Retribution"
    # auto-detect follows the talent tree with the most points
    c.set_talents((0, 45, 16))
    c.dropdown_menu(dd)
    n0 = len(c.chat_frame)
    c.menu_select("Auto-detect")
    assert c.eval("return ns.BiS:GetSpec()") == "Protection"
    assert any("Spec detected: Protection" in l for l in printed_since(c, n0))
    # no talents: nothing changes, the player is told
    c.set_talents((0, 0, 0))
    c.dropdown_menu(dd)
    c.menu_select("Auto-detect")
    assert c.eval("return ns.BiS:GetSpec()") == "Protection"
    assert any("Couldn't detect a spec" in l for l in printed_since(c, n0))
    # druid feral maps to the first spec of the tab
    w2, d = setup(name="Dru", class_file="DRUID", talents=(0, 50, 11))
    assert d.eval("return ns.BiS:GetSpec()") == "Feral (Cat)"
    menu = d.dropdown_menu(d.eval("return T_dropdown(T_mybis(), 'Choose spec')"))
    assert [e[2] for e in menu_texts(menu)] == ["Balance", "Feral (Cat)", "Feral (Bear)", "Restoration", "Auto-detect"]
    d.menu_select("Feral (Bear)")
    assert d.eval("return ns.BiS:GetSpec()") == "Feral (Bear)"
    # a character with no talents at login keeps an empty spec, dropdown shows its default text
    w3, e = setup(name="Fresh", class_file="MAGE", talents=(0, 0, 0))
    assert e.eval("return ns.BiS:GetSpec()") == ""
    assert e.eval("return T_dropdown(T_mybis(), 'Choose spec'):GetText()") == "Choose spec"
    no_errors(w)
    no_errors(w2)
    no_errors(w3)


@case
def picker_closes_with_window_phase_change_and_escape():
    w, c = setup()
    c.click(tile_btn(c, 3))
    assert c.eval("return ns.Picker:IsOpen()") is True
    c.click(c.eval("return T_button(T_mybis(), 'P2')"))
    assert c.eval("return ns.Picker:IsOpen()") is False, "picker stayed open for the old phase"
    c.click(tile_btn(c, 3))
    assert c.eval_py("return {ns.Picker:GetState()}") == [2, 3, "main"]
    assert "P2" in c.eval("return CDLootPicker.titleText:GetText()")
    c.slash("/cdl settings")
    w.tick(0.1)
    assert c.eval("return ns.Picker:IsOpen()") is False, "picker stayed open after switching tabs"
    c.slash("/cdl")
    w.tick(0.1)
    c.slash("/cdl")
    w.tick(0.1)
    c.click(tile_btn(c, 3))
    c.slash("/cdl")   # close the main window
    w.tick(0.1)
    assert c.eval("return ns.Picker:IsOpen()") is False
    # both windows are closable with Escape (UISpecialFrames)
    specials = c.eval_py("return UISpecialFrames")
    assert "CDLootMainFrame" in specials and "CDLootPicker" in specials, specials
    no_errors(w)


@case
def uncached_item_names_fill_in_after_load():
    # First login of the week: the client has no item data cached; names arrive via GET_ITEM_INFO_RECEIVED.
    w, c = solo("Alice", guild_rank=3, tick=3, items_uncached=True)
    install_helpers(c)
    c.slash("/cdl")
    w.tick(0.3)
    head = c.eval("return ns.ItemDB:GetCandidates(1, {maxPhase=1, class='PALADIN', usableOnly=true})[1].itemID")
    c.eval("ns.BiS:SetSlot(1, 1, 'main', ...)", head)
    w.tick(0.06)
    assert "Loading..." in tile_text(c, 1)[0], tile_text(c, 1)
    w.tick(1)
    name = c.eval("return (C_Item.GetItemInfo(...))", head)
    assert name and name in tile_text(c, 1)[0], (name, tile_text(c, 1))
    # picker rows repaint once the names are in
    c.click(tile_btn(c, 2))
    w.tick(0.05)
    names = lambda: c.eval_py("""local o = {}
      for _, r in ipairs(T_rows(T_box(CDLootPicker))) do
        local d = rawget(r, '__cdlData')
        if d.type == 'item' then o[#o + 1] = r.name:GetText() end
      end
      return o""")
    assert all("Loading" in n for n in names()), names()
    w.tick(1)
    assert not any("Loading" in n for n in names()), names()
    # the quality border of the tile button is applied late too
    assert c.eval("return T_tile(1).main.border:IsShown()") is True
    no_errors(w)


@case
def many_raids_collapse_into_more_line_and_wearing_icon():
    w, c = setup()
    # P5 list spread over as many raids as possible + one crafted item
    raids = c.eval_py("""
      local used, picks = {}, {}
      for sid = 2, 17 do
        for _, r in ipairs(ns.ItemDB:GetCandidates(sid, { maxPhase = 5, class = 'PALADIN', usableOnly = true })) do
          local rk = r.ref.raid.key
          if not used[rk] and not r.ref.boss.isTrash and r.via == nil then
            used[rk] = true
            picks[#picks + 1] = { sid, r.itemID, rk }
            break
          end
        end
      end
      return picks""")
    for sid, iid, _ in raids:
        c.eval("local s, i = ...; ns.BiS:SetSlot(5, s, 'main', i)", sid, iid)
    c.eval("ns.BiS:SetSlot(5, 1, 'main', ...)", CRAFTED_HELM)
    c.click(c.eval("return T_button(T_mybis(), 'P5')"))
    w.tick(0.2)
    # wearing something else in a slot shows the small "wearing" icon with its own tooltip
    main2 = c.eval("return ns.BiS:GetSlot(5, 2)")
    other = c.eval("local m = ...; for _, r in ipairs(ns.ItemDB:GetCandidates(2, {maxPhase = 1})) do if r.itemID ~= m then return r.itemID end end", main2)
    c.equip({2: other})
    w.tick(2)
    assert c.eval("return T_tile(2).wear:IsShown()") is True
    assert c.eval("return T_tile(2).wear.itemID") == other
    c.hover(c.eval("return T_tile(2).wear"))
    assert [l for l, _ in tt_lines(c)][-1] == "Currently wearing (Neck)"
    # wearing the main itself: no extra icon, the tile says "Equipped"
    c.equip({2: main2})
    w.tick(2)
    assert c.eval("return T_tile(2).wear:IsShown()") is False
    assert "Equipped" in strip_codes(tile_text(c, 2)[1])
    no_errors(w)


FAKE_LOON = r"""
-- Minimal stand-in for LoonBestInSlot's guide API (the real addon is optional); items come from __LOON_ITEMS
LBIS = { L = setmetatable({}, { __index = function(_, k) return k end }) }
function LBIS:RegisterSpec(class, spec, phase) return { class = class, spec = spec, phase = phase } end
function LBIS:AddItem(entry, id, slot, rank) end
function LBIS:AddGem() end
function LBIS:AddEnchant() end
function LBIS:LoadPaladinHoly()
  local p1 = LBIS:RegisterSpec(LBIS.L["Paladin"], LBIS.L["Holy"], "1")
  for _, e in ipairs(__LOON_ITEMS or {}) do LBIS:AddItem(p1, tostring(e[1]), LBIS.L[e[2]], e[3]) end
end
"""


@case
def suggest_menu_with_loonbestinslot():
    w, c = solo("Alice", guild_rank=3, tick=3, preload_lua=FAKE_LOON)
    install_helpers(c)
    items = c.eval_py("""
      local o = {}
      local h = ns.ItemDB:GetCandidates(1, { maxPhase = 1, class = 'PALADIN', usableOnly = true })
      local r = ns.ItemDB:GetCandidates(11, { maxPhase = 1 })
      o[1] = { h[1].itemID, 'Head', 'BIS' }
      o[2] = { h[2].itemID, 'Head', 'Alt' }
      o[3] = { r[1].itemID, 'Ring', 'BIS' }
      o[4] = { r[2].itemID, 'Ring', 'BIS' }
      o[5] = { r[3].itemID, 'Ring', 'Alt' }
      o[6] = { r[1].itemID, 'Head', 'BIS' }     -- a ring listed as head: must be skipped (does not fit)
      return o""")
    c.eval("__LOON_ITEMS = ...", items)
    c.slash("/cdl")
    w.tick(0.3)
    sug = c.eval("return T_dropdown(T_mybis(), 'Suggest')")
    assert c.eval("local d = ...; return d:IsShown()", sug) is True, "Suggest hidden although LBIS is loaded"
    c.eval("ns.BiS:SetSlot(1, 12, 'main', ...)", items[4][0])   # an existing pick is kept by "fill empty"
    menu = c.dropdown_menu(sug)
    texts = [e[2] for e in menu_texts(menu)]
    assert "Fill empty slots from LoonBestInSlot (Holy P1)" in texts and "Replace all (confirm)" in texts, texts
    c.menu_select("Fill empty slots from LoonBestInSlot (Holy P1)")
    w.tick(0.2)
    assert c.eval_py("return {ns.BiS:GetSlot(1, 1)}") == [items[0][0], items[1][0]]
    assert c.eval_py("return {ns.BiS:GetSlot(1, 11)}")[0] == items[2][0]
    assert c.eval_py("return {ns.BiS:GetSlot(1, 12)}")[0] == items[4][0], "fill-empty replaced an existing pick"
    assert c.eval("return T_tile(1).main.itemID") == items[0][0], "doll not refreshed"
    # LBIS functions are restored after the capture
    assert c.eval("return LBIS.AddItem ~= nil and LBIS.RegisterSpec ~= nil") is True
    # replace all asks first
    c.eval("ns.BiS:SetSlot(1, 3, 'main', ns.ItemDB:GetCandidates(3, {maxPhase=1, class='PALADIN', usableOnly=true})[1].itemID)")
    c.dropdown_menu(sug)
    c.menu_select("Replace all (confirm)")
    assert "CDLOOT_REPLACE_TEMPLATE" in c.popups()
    c.accept_popup("CDLOOT_REPLACE_TEMPLATE")
    w.tick(0.2)
    assert c.eval_py("return {ns.BiS:GetSlot(1, 3)}") == [], "replace-all kept a slot the template does not have"
    # no spec chosen: the menu explains instead of offering actions
    c.eval("ns.BiS:SetSpec('')")
    menu = c.dropdown_menu(sug)
    assert "Choose your spec first" in [e[2] for e in menu_texts(menu)]
    # a spec Loon has no guide for this phase: a message, nothing changes
    c.eval("ns.BiS:SetSpec('Holy')")
    c.click(c.eval("return T_button(T_mybis(), 'P2')"))
    p0 = len(c.chat_frame)
    c.eval("ns.MyBiS:ApplySuggestion(2, false)")
    assert any("has no Holy suggestions for P2" in l for l in printed_since(c, p0)), printed_since(c, p0)
    assert c.eval("return #ns.BiS:GetPhaseItems(2)") == 0
    no_errors(w)


@case
def tier_token_link_in_picker_does_not_become_a_stuck_pick():
    # Shift-clicking (or dragging) a tier TOKEN into the head picker stores the token itself as the BiS pick
    # (the token "fits" the head slot via its first piece). Equipping the class's tier helm afterwards never
    # marks that pick obtained, so the list (and the council views) keep showing the helm as still needed.
    w, c = setup()
    token = 29760                       # Helm of the Fallen Champion (Paladin / Rogue / Shaman)
    piece = c.eval("for _, p in ipairs(ns.Data.Tokens[29760]) do if ns.Data.TierPieceClass[p] == 'PALADIN' then return p end end")
    c.click(tile_btn(c, 1))
    c.eval("ChatFrameUtil.InsertLink((select(2, C_Item.GetItemInfo(...))))", token)
    w.tick(0.1)
    main = c.eval("return ns.BiS:GetSlot(1, 1)")
    c.equip({1: piece})
    w.tick(2)
    obtained = c.eval("return ns.BiS:IsObtained(ns.BiS:GetSlot(1, 1))")
    assert main != token or obtained, (
        "token %d stored as the head pick; after equipping the Paladin tier helm %d it is still not obtained "
        "(card: %r)" % (token, piece, card_texts(c)[0]))
    no_errors(w)


if __name__ == "__main__":
    run_all()

"""ADDENDUM F §36: disabled BiS slots (ListData dx = { [phase] = { [sid] = true } }) on the real addon.

Covers: the BiS API and data model (dx omitted when empty, picks kept, hash covers dx), the My BiS tile menu,
the greyed paper-doll tile, "x / 16" progress and "Still needed from", MatchItem / GetWanters / GetPlayerSummary
skipping the slot, drop alerts and personal toasts not firing for it, CopyPhase / LoonBestInSlot suggestions never
filling it, sync to the council (roster "–" cell, member view, Items view counts), the Store validator limits,
the own record being sanitized after a /reload, and a mixed guild where a CDLoot 0.2 council member
(tests/grouprules/addon02, whose Store validator is the same as 0.3's) accepts, keeps and relays a list with dx.

Run: luaenv\\Scripts\\python.exe tests\\disabled_slots\\test_disabled_slots.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(TESTS, "loot-roll"))

from _common import (case, run_all, solo, no_errors, World, Client, install_helpers, menu_texts,  # noqa: E402
                     printed_since, strip_codes, tt_lines, seed_guild_council, gm_pick)
import lr_common as lr  # noqa: E402

ADDON_02 = os.path.join(TESTS, "grouprules", "addon02", "CDLoot")
REALM = "Thunderstrike"
SID_HEAD, SID_NECK, SID_SHOULDER, SID_CHEST, SID_RING1 = 1, 2, 3, 5, 11


def K(name):
    return "%s-%s" % (name, REALM)


def cand(c, sid, n=1, klass=None, phase=1):
    return c.eval("local s, n, k, p = ...; return ns.ItemDB:GetCandidates(s, {maxPhase=p, class=k, usableOnly=true})[n].itemID",
                  sid, n, klass or c.class_file, phase)


def is_disabled(c, phase, sid):
    return c.eval("return ns.BiS:IsSlotDisabled(...)", phase, sid)


def dx_of(c, lua_data="ns.BiS:GetData()"):
    """dx as a sorted list of (phase, sid) pairs (None when the key is absent)."""
    return c.eval_py("""
      local dx = %s.dx
      if dx == nil then return nil end
      local out = {}
      for p, slots in pairs(dx) do for s, v in pairs(slots) do out[#out + 1] = { p, s, v == true } end end
      table.sort(out, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
      return out""" % lua_data)


def tile_btn(c, sid, which="main"):
    return c.eval("local s, w = ...; return T_tile(s)[w]", sid, which)


def card_texts(c):
    return c.eval_py("""
      return { T_card().title:GetText() }""")


def menu_labels(c):
    return [e[2] for e in menu_texts(c.last_menu())]


def ui_setup(name="Alice", class_file="PALADIN", **kw):
    w, c = solo(name, class_file=class_file, guild_rank=3, tick=4, council=[], phase=1, **kw)
    install_helpers(c)
    c.slash("/dz bis")
    w.tick(0.3)
    assert c.eval("return ns.MainFrame:GetSelectedTab()") == "mybis"
    return w, c


def council_world(raider_class="PRIEST"):
    """GM Gina (council implicitly), council member Cou, raider Rita; all loaded, council list shared."""
    w = World()
    c = {}
    for name, rank, cls in (("Gina", 0, "PALADIN"), ("Cou", 1, "MAGE"), ("Rita", 3, raider_class)):
        c[name] = Client(w, name, guild_rank=rank, class_file=cls)
    for x in c.values():
        x.load_addon()
    w.tick(3)
    gm_pick(w, c["Gina"], ["Cou"])
    return w, c


# ------------------------------------------------------------------------------------------------------------------
@case
def api_model_dx_shape_hash_and_picks_kept():
    w, c = solo("Rita", class_file="PRIEST", tick=3)
    head, chest = cand(c, SID_HEAD), cand(c, SID_CHEST)
    lr.seed_bis(c, [(1, SID_HEAD, "main", head), (1, SID_CHEST, "main", chest), (2, SID_HEAD, "main", head)])
    rev0, h0 = c.eval("local r = ns.BiS:GetRecord(); return r.rev, r.hash")
    assert dx_of(c) is None, "no dx key before anything is disabled"
    c.eval("__MC = {} ns:On('MYLIST_CHANGED', function(p, s) __MC[#__MC + 1] = { p or 0, s or 0 } end)")
    assert c.eval("return ns.BiS:SetSlotDisabled(1, 1, true)") is True
    assert is_disabled(c, 1, SID_HEAD) is True and is_disabled(c, 2, SID_HEAD) is False
    assert c.eval("return ns.BiS:GetSlot(1, 1)") == head, "the pick is kept"
    assert dx_of(c) == [[1, 1, True]], dx_of(c)
    assert c.eval_py("return __MC") == [[1, 1]]
    assert c.eval("return ns.BiS:IsDirty()") is True
    # idempotent (no second change / event), GetPhaseItems marks the pick, GetDisabledSlots
    assert c.eval("return ns.BiS:SetSlotDisabled(1, 1, true)") is True
    assert len(c.eval_py("return __MC")) == 1
    items = c.eval_py("local o = {} for _, e in ipairs(ns.BiS:GetPhaseItems(1)) do o[#o + 1] = { e.sid, e.disabled or false } end return o")
    assert sorted(items) == [[1, True], [5, False]], items
    assert c.eval_py("local o = {} for s in pairs(ns.BiS:GetDisabledSlots(1)) do o[#o + 1] = s end return o") == [1]
    # the hash covers dx
    c.eval("ns.BiS:Commit()")
    rev1, h1 = c.eval("local r = ns.BiS:GetRecord(); return r.rev, r.hash")
    assert rev1 == rev0 + 1 and h1 != h0, (rev0, rev1, h0, h1)
    assert c.eval("return ns.Util.Hash(ns.BiS:GetData())") == h1
    # all phases, then enable again: dx omitted when empty, same hash as before any disable
    assert c.eval("return ns.BiS:SetSlotDisabledAllPhases(1, true)") is True
    assert [is_disabled(c, p, SID_HEAD) for p in range(1, 6)] == [True] * 5
    assert c.eval("return ns.BiS:SetSlotDisabledAllPhases(1, false)") is True
    assert dx_of(c) is None, dx_of(c)
    assert c.eval("return ns.Util.Hash(ns.BiS:GetData())") == h0, "enabling everything restores the old hash"
    # invalid arguments are refused and change nothing
    for code in ("ns.BiS:SetSlotDisabled(0, 1, true)", "ns.BiS:SetSlotDisabled(6, 1, true)",
                 "ns.BiS:SetSlotDisabled(1, 18, true)", "ns.BiS:SetSlotDisabled(1, 'x', true)",
                 "ns.BiS:SetSlotDisabledAllPhases(0, true)", "ns.BiS:SetSlotDisabledAllPhases(nil, true)"):
        assert c.eval("return " + code) is False, code
    assert c.eval("return ns.BiS:IsSlotDisabled(9, 1)") is False and c.eval("return ns.BiS:IsSlotDisabled(1, nil)") is False
    assert dx_of(c) is None
    # the saved record keeps dx across a relog
    c.eval("ns.BiS:SetSlotDisabled(3, 13, true)")
    c.eval("ns.BiS:Commit()")
    c.relog()
    w.tick(3)
    assert is_disabled(c, 3, 13) is True and dx_of(c) == [[3, 13, True]]
    no_errors(w)


@case
def my_bis_menu_greyed_tile_progress_and_enable():
    w, c = ui_setup()
    head, chest, neck = cand(c, SID_HEAD), cand(c, SID_CHEST), cand(c, SID_NECK)
    for sid, iid in ((SID_HEAD, head), (SID_CHEST, chest), (SID_NECK, neck)):
        c.eval("local s, i = ...; ns.BiS:SetSlot(1, s, 'main', i)", sid, iid)
    w.tick(0.2)
    before = card_texts(c)
    assert before[0].startswith("P1  ·  0 / 17 obtained"), before[0]
    c.click(tile_btn(c, SID_CHEST), "RightButton")
    labels = menu_labels(c)
    assert labels[-3:] == [None, "Disable slot (P1)", "Disable in all phases"], labels
    c.menu_select("Disable slot (P1)")
    w.tick(0.2)
    assert is_disabled(c, 1, SID_CHEST) is True
    tile = c.eval_py("""
      local t = T_tile(5)
      local icon = t.main.icon
      return { t.line1:GetText(), t.line2:GetText(), T_doll():IsTileDisabled(5), t:GetAlpha(),
               icon:IsDesaturated() and 1 or 0, t.main.itemID or 0 }""")
    assert "Disabled" in strip_codes(tile[0]) and "not needed" in strip_codes(tile[0]), tile
    assert "pick kept" in strip_codes(tile[1]), tile
    assert tile[2] is True and tile[3] < 1 and tile[4] == 1 and tile[5] == chest, tile
    # other tiles are untouched
    assert c.eval("return T_doll():IsTileDisabled(1)") is False
    assert "Disabled" not in strip_codes(c.eval("return T_tile(1).line1:GetText()"))
    # progress: x / 16, "· 1 disabled"; the chest is no longer "still needed"
    after = card_texts(c)
    assert after[0].startswith("P1  ·  0 / 16 obtained"), after[0]
    prog = c.eval_py("local p = ns.MyBiS:GetProgress(1); return { p.filled, p.total, p.disabled, p.obtained }")
    assert prog == [2, 16, 1, 0], prog
    # the tile tooltip explains it
    c.eval("T_tile(5).main:GetScript('OnEnter')(T_tile(5).main)")
    tt = [strip_codes(l[0]) for l in tt_lines(c)]
    assert any("disabled" in l for l in tt) and "Click: Enable slot" in tt, tt
    # a left click on a disabled tile offers "Enable slot" instead of the picker
    c.click(tile_btn(c, SID_CHEST))
    assert c.eval("return ns.Picker:IsOpen()") is False
    labels = menu_labels(c)
    assert labels[0].endswith("disabled") and "Enable slot (P1)" in labels and "Choose main..." not in labels, labels
    # dropping an item onto it is refused
    n0 = len(c.chat_frame)
    c.eval("local t = T_tile(5).main; if t.onReceiveItem then t.onReceiveItem(t, ...) end", cand(c, SID_CHEST, 2))
    assert c.eval("return ns.BiS:GetSlot(1, 5)") == chest, "a drop replaced the pick of a disabled slot"
    assert any("is disabled in P1" in l for l in printed_since(c, n0)), printed_since(c, n0)
    # all phases from the menu; P2 shows it disabled too
    c.menu_select("Disable in all phases")
    w.tick(0.2)
    assert [is_disabled(c, p, SID_CHEST) for p in range(1, 6)] == [True] * 5
    c.click(c.eval("return T_button(T_mybis(), 'P2')"))
    w.tick(0.2)
    assert c.eval("return T_doll():IsTileDisabled(5)") is True
    assert card_texts(c)[0].startswith("P2  ·  0 / 16 obtained"), card_texts(c)[0]
    c.click(tile_btn(c, SID_CHEST))
    assert "Enable in all phases" in menu_labels(c)
    c.menu_select("Enable in all phases")
    w.tick(0.2)
    assert [is_disabled(c, p, SID_CHEST) for p in range(1, 6)] == [False] * 5
    assert c.eval("return T_doll():IsTileDisabled(5)") is False
    c.click(c.eval("return T_button(T_mybis(), 'P1')"))
    w.tick(0.2)
    assert c.eval("return T_doll():IsTileDisabled(5)") is False
    assert card_texts(c)[0].startswith("P1  ·  0 / 17 obtained"), card_texts(c)[0]
    assert c.eval("return T_tile(5).main.itemID") == chest and "Disabled" not in strip_codes(
        c.eval("return T_tile(5).line1:GetText()"))
    # an empty slot can be disabled too (and then counts as not needed)
    c.click(tile_btn(c, 7), "RightButton")
    c.menu_select("Disable slot (P1)")
    w.tick(0.2)
    assert c.eval_py("local p = ns.MyBiS:GetProgress(1); return { p.filled, p.total, p.disabled }") == [3, 16, 1]
    no_errors(w)


@case
def match_item_wanters_summary_and_council_views_skip_disabled():
    w, c = council_world()
    rita, cou = c["Rita"], c["Cou"]
    head, neck, chest = cand(rita, SID_HEAD), cand(rita, SID_NECK), cand(rita, SID_CHEST)
    lr.seed_bis(rita, [(1, SID_HEAD, "main", head), (1, SID_NECK, "main", neck), (1, SID_CHEST, "main", chest),
                       (2, SID_HEAD, "main", head)])
    w.tick(10)
    assert cou.eval("return ns.Store:GetCached(...) ~= nil", K("Rita")), "council has Rita's list"
    head_wanters = cou.eval_py("local o = {} for _, x in ipairs(ns.Store:GetWanters(...)) do o[#o + 1] = { x.key, x.phase } end return o", head)
    assert head_wanters and all(x[0] == K("Rita") for x in head_wanters), head_wanters
    rita.eval("ns.BiS:SetSlotDisabled(1, 1, true); ns.BiS:SetSlotDisabled(1, 5, true); ns.BiS:Commit()")
    w.tick(10)
    # owner: MatchItem skips the P1 head (the P2 pick of the same item still matches)
    m = rita.eval_py("local o = {} for _, x in ipairs(ns.BiS:MatchItem(...)) do o[#o + 1] = { x.phase, x.sid } end return o", head)
    assert m == [[2, 1]], m
    assert rita.eval("return #ns.BiS:MatchItem(...)", chest) == 0
    assert rita.eval("return #ns.BiS:MatchItem(...)", neck) == 1
    # council: synced dx, wanters / summary skip the slots
    assert cou.eval("return ns.Store:IsSlotDisabled(..., 1, 1)", K("Rita")) is True
    assert cou.eval("return ns.Store:IsSlotDisabled(ns.Store:Get(...), 1, 5)", K("Rita")) is True
    assert cou.eval("return ns.Store:IsSlotDisabled(ns.Store:Get(...).data, 1, 2)", K("Rita")) is False
    assert cou.eval("return ns.Store:IsSlotDisabled(nil, 1, 1)") is False
    assert cou.eval("return ns.Store:IsSlotDisabled('Nobody-Thunderstrike', 1, 1)") is False
    ws = cou.eval_py("local o = {} for _, x in ipairs(ns.Store:GetWanters(...)) do o[#o + 1] = { x.key, x.phase } end return o", head)
    assert ws == [[K("Rita"), 2]], ws
    assert cou.eval("return #ns.Store:GetWanters(...)", chest) == 0
    assert cou.eval("return #ns.Store:GetWanters(...)", neck) == 1
    s = cou.eval_py("return ns.Store:GetPlayerSummary(..., 1)", K("Rita"))
    assert s["disabled"] == 2 and s["total"] == 15 and s["filled"] == 1 and s["needed"] == 1, s
    s2 = cou.eval_py("return ns.Store:GetPlayerSummary(..., 2)", K("Rita"))
    assert s2["disabled"] == 0 and s2["total"] == 17 and s2["filled"] == 1, s2
    # Council tab: roster "–" cells with the tooltip, member view greyed tiles, counts without the slots
    install_helpers(cou)
    cou.slash("/dz council")
    w.tick(0.5)
    row = cou.eval_py("""
      for _, r in ipairs(T_rows(DisasterZoneCouncilPanel.rosterView.list.box)) do
        local d = rawget(r, 'cdlData')
        if d and d.key == ... then
          local o = { cells = {}, filled = d.filled, need = d.need, disabled = d.disabled }
          for sid = 1, 17 do
            local cell = r.cells[sid]
            o.cells[sid] = (cell.cdlDisabled and 1 or 0) + ((cell.cdlDash and cell.cdlDash:IsShown()) and 10 or 0)
          end
          return o
        end
      end""", K("Rita"))
    assert row, "Rita not in the roster"
    assert row["cells"][0] == 11 and row["cells"][4] == 11 and sum(row["cells"]) == 22, row["cells"]
    assert (row["filled"], row["need"], row["disabled"]) == (1, 1, 2), row
    dash = cou.eval("""
      for _, r in ipairs(T_rows(DisasterZoneCouncilPanel.rosterView.list.box)) do
        local d = rawget(r, 'cdlData')
        if d and d.key == ... then return r.cells[1].cdlDash:GetText() end
      end""", K("Rita"))
    assert dash == "–", dash
    cou.eval("""
      for _, r in ipairs(T_rows(DisasterZoneCouncilPanel.rosterView.list.box)) do
        local d = rawget(r, 'cdlData')
        if d and d.key == ... then local cell = r.cells[1]; cell:GetScript('OnEnter')(cell) end
      end""", K("Rita"))
    tt = [strip_codes(l[0]) for l in tt_lines(cou)]
    assert "Disabled by player" in tt, tt
    cou.eval("ns.CouncilUI:ShowMember(...)", K("Rita"))
    w.tick(0.3)
    dis = cou.eval_py("local d = T_doll(DisasterZoneCouncilPanel.memberView); local o = {} "
                      "for s = 1, 17 do o[s] = d:IsTileDisabled(s) and 1 or 0 end return o")
    assert dis[0] == 1 and dis[4] == 1 and sum(dis) == 2, dis
    summary = strip_codes(cou.eval("return DisasterZoneCouncilPanel.memberView.centerParts.summary:GetText()"))
    assert "2 disabled" in summary and "1 needed" in summary, summary
    # enabling again restores everything on the council
    rita.eval("ns.BiS:SetSlotDisabled(1, 1, false); ns.BiS:SetSlotDisabled(1, 5, false); ns.BiS:Commit()")
    w.tick(10)
    assert cou.eval("return ns.Store:IsSlotDisabled(..., 1, 1)", K("Rita")) is False
    assert cou.eval("return ns.Store:GetCached(...).data.dx", K("Rita")) is None
    assert cou.eval_py("local o = {} for _, x in ipairs(ns.Store:GetWanters(...)) do o[#o + 1] = { x.key, x.phase } end return o", head) == head_wanters
    s = cou.eval_py("return ns.Store:GetPlayerSummary(..., 1)", K("Rita"))
    assert s["disabled"] == 0 and s["total"] == 17 and s["filled"] == 3, s
    no_errors(w)


@case
def drop_alert_toast_and_panel_skip_a_disabled_slot():
    bis = dict(lr.BIS)
    r = lr.Raid(bis=bis, sync=False, encounter=False)
    w = r.w
    carol = r["Carol"]
    # Carol wants Band of a Thousand Marks as her ring (main); she disables that ring slot for P1
    assert carol.eval("return ns.BiS:SetSlotDisabled(1, 11, true)") is True
    r.sync()
    assert r["Bob"].eval("return ns.Store:IsSlotDisabled(..., 1, 11)", K("Carol")) is True
    assert carol.eval("return #ns.BiS:MatchItem(...)", lr.THOUSAND_MARKS) == 0
    w.encounter(lr.PRINCE_ENCOUNTER, "Prince Malchezaar")
    w.tick(0.5)
    r["Alice"].open_loot([(lr.THOUSAND_MARKS, 4), (lr.RUBY_DRAPE, 4)], source_guid=lr.PRINCE_GUID)
    w.tick(2)
    for name in ("Alice", "Bob"):
        by = {b["item"]: b for b in lr.panel_blocks(r[name])}
        assert list(by[lr.THOUSAND_MARKS]["names"]) == [K("Erin")], (name, by[lr.THOUSAND_MARKS])
    assert not lr.toast_state(carol)["shown"], lr.toast_state(carol)
    assert not [l for l in lr.printed_lines(carol) if "is on your BiS list" in l]
    assert lr.toast_state(r["Erin"])["item"] == lr.THOUSAND_MARKS, lr.toast_state(r["Erin"])
    assert lr.toast_state(r["Dave"])["item"] in (lr.RUBY_DRAPE, lr.THOUSAND_MARKS)
    # enabled again: the next drop (another corpse, after the dedupe window) alerts her and lists her
    assert carol.eval("return ns.BiS:SetSlotDisabled(1, 11, false)") is True
    carol.eval("ns.BiS:Commit()")
    w.tick(100)
    r["Alice"].close_loot()
    w.tick(0.5)
    r["Alice"].open_loot([(lr.THOUSAND_MARKS, 4)], source_guid="Creature-0-1-2-3-15690-000ABD")
    w.tick(2)
    by = {b["item"]: b for b in lr.panel_blocks(r["Bob"])}
    assert K("Carol") in list(by[lr.THOUSAND_MARKS]["names"]), by[lr.THOUSAND_MARKS]
    assert lr.toast_state(carol)["item"] == lr.THOUSAND_MARKS, lr.toast_state(carol)
    w.assert_no_errors()


SET_LISTS = r"""
-- Replaces the shipped Paladin Holy list (Data/BiSLists.lua) with P1 = the given { item, slot name, rank } rows
local names = { Head = 1, Neck = 2, Shoulder = 3, Back = 4, Chest = 5, Wrist = 6, Hands = 7, Waist = 8, Legs = 9,
                Feet = 10, Ring = 11, Trinket = 12, ["Main Hand"] = 13, ["Off Hand"] = 14, ["Two Hand"] = 15 }
local parts = {}
for _, e in ipairs(... or {}) do
  parts[#parts + 1] = names[e[2]] .. ":" .. e[1] .. (e[3] == "BIS" and "*" or "")
end
ns.Data.BiSLists.PaladinHoly = { [1] = table.concat(parts, ",") }
ns.Loon:ClearCache()
"""


@case
def copy_phase_and_loon_suggestions_never_fill_a_disabled_slot():
    w, c = ui_setup()
    head, head2 = cand(c, SID_HEAD, 1), cand(c, SID_HEAD, 2)
    ring = cand(c, SID_RING1, 1)
    chest = cand(c, SID_CHEST, 1)
    for sid, iid in ((SID_HEAD, head), (SID_RING1, ring), (SID_CHEST, chest)):
        c.eval("local s, i = ...; ns.BiS:SetSlot(1, s, 'main', i)", sid, iid)
    # P2: chest disabled and empty, head disabled with its own pick
    c.eval("ns.BiS:SetSlot(2, 1, 'main', ...)", head2)
    c.eval("ns.BiS:SetSlotDisabled(2, 5, true); ns.BiS:SetSlotDisabled(2, 1, true)")
    assert c.eval("return ns.BiS:CopyPhase(1, 2, false)") is True
    assert c.eval("return ns.BiS:GetSlot(2, 5)") is None, "fill-empty filled a disabled slot"
    assert c.eval("return ns.BiS:GetSlot(2, 11)") == ring
    assert c.eval("return ns.BiS:GetSlot(2, 1)") == head2
    assert c.eval("return ns.BiS:CopyPhase(1, 2, true)") is True
    assert c.eval("return ns.BiS:GetSlot(2, 5)") is None, "overwrite filled a disabled slot"
    assert c.eval("return ns.BiS:GetSlot(2, 1)") == head2, "overwrite dropped a disabled slot's pick"
    # ApplyTemplate (the Loon path): fill-empty and replace-all skip the disabled slots
    # (replace-all with a template of only disabled slots: the ring copied above is dropped, 1 change)
    n = c.eval("return ns.BiS:ApplyTemplate(2, { [1] = { ... }, [5] = { ... } }, true)", head, chest)
    assert n == 1 and c.eval("return ns.BiS:GetSlot(2, 11)") is None, n
    assert c.eval("return ns.BiS:GetSlot(2, 5)") is None and c.eval("return ns.BiS:GetSlot(2, 1)") == head2
    n = c.eval("return ns.BiS:ApplyTemplate(2, { [1] = { ... }, [5] = { ... } }, false)", head, chest)
    assert n == 0 and c.eval("return ns.BiS:GetSlot(2, 5)") is None and c.eval("return ns.BiS:GetSlot(2, 1)") == head2, n
    # the Suggest menu (LoonBestInSlot stand-in) on P1 with the chest disabled
    c.eval("ns.BiS:ClearPhase(1)")
    c.eval("ns.BiS:SetSlotDisabled(1, 5, true)")
    c.eval(SET_LISTS, [[head, "Head", "BIS"], [chest, "Chest", "BIS"], [ring, "Ring", "BIS"]])
    c.eval("ns.MyBiS:Refresh()")
    w.tick(0.2)
    sug = c.eval("return T_dropdown(T_mybis(), 'Suggest')")
    assert c.eval("local d = ...; return d:IsShown()", sug) is True
    c.dropdown_menu(sug)
    c.menu_select("Fill empty slots (Holy P1)")
    w.tick(0.2)
    assert c.eval("return ns.BiS:GetSlot(1, 1)") == head and c.eval("return ns.BiS:GetSlot(1, 11)") == ring
    assert c.eval("return ns.BiS:GetSlot(1, 5)") is None, "Loon filled a disabled slot"
    c.dropdown_menu(sug)
    c.menu_select("Replace all (confirm)")
    c.accept_popup("DISASTERZONE_REPLACE_TEMPLATE")
    w.tick(0.2)
    assert c.eval("return ns.BiS:GetSlot(1, 5)") is None and is_disabled(c, 1, SID_CHEST) is True
    no_errors(w)


@case
def validator_limits_and_rejected_lists():
    w, c = council_world()
    cou = c["Cou"]
    ok = [
        {"v": 1, "ph": {}, "dx": {1: {3: True}}},
        {"v": 1, "dx": {5: {17: True, 1: True}, 2: {9: True}}},
        {"v": 1, "dx": {}},
        {"v": 1, "zz": {"future": 1}, "dx": {1: {1: True}}},     # unknown top-level keys stay accepted
    ]
    bad = [
        {"v": 1, "dx": 5}, {"v": 1, "dx": {1: {3: 1}}}, {"v": 1, "dx": {1: {3: "true"}}},
        {"v": 1, "dx": {0: {3: True}}}, {"v": 1, "dx": {6: {3: True}}}, {"v": 1, "dx": {1: {18: True}}},
        {"v": 1, "dx": {1: {0: True}}}, {"v": 1, "dx": {1: True}}, {"v": 1, "dx": {"a": {1: True}}},
        {"v": 1, "dx": {1: {1.5: True}}}, {"v": 1, "dx": {1: {"x": True}}},
    ]
    for d in ok:
        assert cou.eval("return ns.Store:ValidateData(...)", d) is True, d
    for d in bad:
        res = cou.eval_py("return { ns.Store:ValidateData(...) }", d)
        assert res[0] is False and "disabled" in res[1], (d, res)
    # a list with a bad dx is not stored (and nothing breaks)
    stored = cou.eval("""
      local data = { v = 1, cl = 'PRIEST', sp = '', ph = {}, dx = { [1] = { [3] = 1 } } }
      return ns.Store:Put(..., { r = 5, ts = GetServerTime(), h = ns.Util.Hash(data), d = data }, 'direct')""", K("Rita"))
    assert stored is False
    good = cou.eval("""
      local data = { v = 1, cl = 'PRIEST', sp = '', ph = {}, dx = { [2] = { [3] = true } } }
      return ns.Store:Put(..., { r = 6, ts = GetServerTime(), h = ns.Util.Hash(data), d = data }, 'direct')""", K("Rita"))
    assert good is True and cou.eval("return ns.Store:IsSlotDisabled(..., 2, 3)", K("Rita")) is True
    # a record whose hash was made without dx does not match once dx is added (the hash covers dx)
    tampered = cou.eval("""
      local data = { v = 1, cl = 'PRIEST', sp = '', ph = {} }
      local h = ns.Util.Hash(data)
      data.dx = { [1] = { [1] = true } }
      return ns.Store:Put(..., { r = 7, ts = GetServerTime(), h = h, d = data }, 'direct')""", K("Rita"))
    assert tampered is False
    no_errors(w)


@case
def own_record_dx_is_sanitized_on_load():
    w = World()
    c = Client(w, "Rita", guild_rank=3, class_file="PRIEST")
    c.load_addon()
    w.tick(2)
    head = cand(c, SID_HEAD)
    lr.seed_bis(c, [(1, SID_HEAD, "main", head)])
    # damage the saved dx the way a hand-edited SavedVariables file could
    c.eval("""
      local rec = ns.db.chars[ns.Util.PlayerKey()]
      rec.data.dx = { [1] = { [1] = true, [40] = true, [3] = 1, x = true }, [9] = { [1] = true },
                      [2] = 'junk', [3] = {} }""")
    c.relog()
    w.tick(3)
    assert dx_of(c) == [[1, 1, True]], dx_of(c)
    assert c.eval("return ns.BiS:IsSlotDisabled(1, 1)") is True
    c.eval("ns.db.chars[ns.Util.PlayerKey()].data.dx = 'junk'")
    c.relog()
    w.tick(3)
    assert dx_of(c) is None
    assert c.eval("return ns.BiS:GetSlot(1, 1)") == head
    no_errors(w)


@case
def mixed_guild_02_council_accepts_keeps_and_relays_dx():
    assert os.path.exists(os.path.join(ADDON_02, "CDLoot.toc")), "missing the CDLoot 0.2 fixture: %s" % ADDON_02
    w = World()
    gina = Client(w, "Gina", guild_rank=0, class_file="PALADIN")                  # GM, 0.4
    old = Client(w, "Old", guild_rank=1, class_file="MAGE", addon_dir=ADDON_02)   # council, CDLoot 0.2
    new = Client(w, "New", guild_rank=3, class_file="PRIEST")                     # raider, 0.4
    cou = Client(w, "Cou", guild_rank=1, class_file="WARRIOR")                    # council, 0.4 (offline later)
    for x in (gina, old, new, cou):
        x.load_addon()
    w.tick(3)
    assert old.eval("return ns.version") == "0.2.0"
    gm_pick(w, gina, ["Old", "Cou"])
    w.tick(2)
    assert old.eval("return ns.Guild:AmICouncil(true)") is True
    cou.logout()
    w.tick(2)
    head, chest = cand(new, SID_HEAD), cand(new, SID_CHEST)
    lr.seed_bis(new, [(1, SID_HEAD, "main", head), (1, SID_CHEST, "main", chest)])
    new.eval("ns.BiS:SetSlotDisabled(1, 5, true); ns.BiS:SetSlotDisabled(3, 2, true); ns.BiS:Commit()")
    w.make_raid([gina, old, new], leader=gina)
    w.tick(20)
    new.slash("/dz sync")
    w.tick(20)
    own_rev, own_hash = new.eval("local r = ns.BiS:GetRecord(); return r.rev, r.hash")
    # the 0.2 council member stored the list as sent: dx kept, hash verified
    rec = old.eval_py("local r = ns.Store:GetCached(...); return r and { r.rev, r.hash } or false", K("New"))
    assert rec == [own_rev, own_hash], (rec, own_rev, own_hash)
    assert dx_of(old, "ns.Store:GetCached('%s').data" % K("New")) == [[1, 5, True], [3, 2, True]]
    assert old.eval("return ns.Store:ValidateData({ v = 1, ph = {}, dx = { [1] = { [3] = true } } })") is True
    # (a 0.2 client doesn't know dx: it still counts the slot - informational only)
    print("   0.2 wanters of the disabled chest:", old.eval("return #ns.Store:GetWanters(...)", chest))
    # the 0.4 GM sees it disabled
    assert gina.eval("return ns.Store:IsSlotDisabled(..., 1, 5)", K("New")) is True
    # relay through the 0.2 council member: New and the GM go offline, Cou logs in and syncs from Old
    new.logout()
    gina.logout()
    w.tick(2)
    cou.login()
    w.tick(60)
    got = cou.eval_py("local r = ns.Store:GetCached(...); return r and { r.rev, r.hash, r.via } or false", K("New"))
    assert got and got[0] == own_rev and got[1] == own_hash, got
    assert cou.eval("return ns.Store:IsSlotDisabled(..., 1, 5)", K("New")) is True
    assert cou.eval("return ns.Store:IsSlotDisabled(..., 3, 2)", K("New")) is True
    assert cou.eval("return #ns.Store:GetWanters(...)", chest) == 0
    print("   Cou's copy came via:", got[2])
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

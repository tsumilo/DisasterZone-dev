#!/usr/bin/env python
"""Addendum H: main-spec / off-spec lists.

The off-spec list is stored flat on the synced list (os label, op phases, ox disabled slots) so older validators
accept it; BiS edit APIs take a list argument; council wanters, roll tiers (off spec = tier 3, before players who
don't list the item), award reasons (Offspec), drop panel / tooltips / toast / roll popup texts, the My BiS
Main spec / Off spec switch, the picker, the council's "Off-spec lists" view, and the raid lock.

Run: luaenv\\Scripts\\python.exe tests\\offspec\\test_offspec.py   [-k substring]
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "loot-roll"))

from lr_common import *  # noqa: F401,F403,E402
from test_rolls import setup, click_roll, ADDON_USERS  # noqa: E402

R = Runner("off-spec lists (Addendum H)")

SID_OH = 16


def os_pick(c, phase, sid, which, item, commit=True):
    ok = c.eval("return ns.BiS:SetSlot(...)", phase, sid, which, item, "os")
    assert ok, "%s: off-spec SetSlot refused" % c.name
    if commit:
        c.eval("ns.BiS:Commit()")


def with_offspec(r, sync=True):
    """Carol (WARRIOR, main Fury): off spec Protection with Mindblade as P1 main-hand main.
    Dave (PRIEST): Mindblade as MAIN-spec alt. Nobody else lists it."""
    C, D = r["Carol"], r["Dave"]
    assert C.eval("return ns.BiS:SetSpec('Protection', 'os')") is True
    os_pick(C, 1, SID_MH, "main", MINDBLADE)
    assert D.eval("return ns.BiS:SetSlot(1, 15, 'alt', ...)", MINDBLADE)
    D.eval("ns.BiS:Commit()")
    if sync:
        r.w.tick(2)
        for n in ("Carol", "Dave"):
            r[n].slash("/dz sync")
            r.w.tick(0.5)
        r.w.tick(30)


def data_of(c, key_=None):
    if key_ is None:
        return c.eval_py("return ns.BiS:GetData()")
    return c.eval_py("local r = ns.Store:Get(...) return r and r.data", key_)


# ----------------------------------------------------------------------------------------------------------------
@R.case
def data_shape_is_flat_and_main_list_untouched():
    r = setup()
    C = r["Carol"]
    before = data_of(C)
    h0 = C.eval("return ns.BiS:GetRecord().hash")
    assert C.eval("return ns.BiS:HasOffSpec()") is False
    assert "os" not in before and "op" not in before
    with_offspec(r, sync=False)
    d = data_of(C)
    # (tables with key 1 come back as lists: op[0] is phase 1)
    assert d["os"] == "Protection" and d["op"] == [{SID_MH: [MINDBLADE, 0]}], d
    assert d["ph"] == before["ph"] and d["sp"] == before["sp"], "main list unchanged"
    assert C.eval("return (ns.BiS:GetSlot(1, 15, 'os'))") == MINDBLADE
    assert C.eval("return (ns.BiS:GetSlot(1, 15))") is None
    assert C.eval("return ns.BiS:GetSpec('os')") == "Protection"
    assert C.eval("return ns.BiS:GetRecord().hash") != h0
    # the validator (same depth / shape limits as 0.6) accepts it
    assert C.eval("return ns.Store:ValidateData(ns.BiS:GetData())") is True
    # disabled slots are per list
    assert C.eval("return ns.BiS:SetSlotDisabled(1, 16, true, 'os')") is True
    d = data_of(C)
    assert d["ox"] == [{16: True}] and "dx" not in d, d
    assert C.eval("return ns.BiS:IsSlotDisabled(1, 16, 'os')") is True
    assert C.eval("return ns.BiS:IsSlotDisabled(1, 16)") is False
    # the off spec's Pre-raid list: flat opr / opx, next to the main spec's pr / px
    assert C.eval("return ns.BiS:SetSlot(0, 15, 'main', ..., 'os')", MINDBLADE) is True
    assert C.eval("return ns.BiS:SetSlotDisabled(0, 16, true, 'os')") is True
    assert C.eval_py("local d = ns.BiS:GetData() return { d.opr[15][1], d.opr[15][2], d.opx[16], d.pr == nil, "
                     "d.px == nil }") == [MINDBLADE, 0, True, True, True]
    assert C.eval("return ns.BiS:IsSlotDisabled(0, 16, 'os')") is True
    assert C.eval("return ns.BiS:IsSlotDisabled(0, 16)") is False
    assert C.eval("return ns.Store:ValidateData(ns.BiS:GetData())") is True
    # an off spec with only a Pre-raid list is still an off spec
    assert C.eval("local d = ns.Util.CopyTable(ns.BiS:GetData()) d.os, d.op, d.ox = nil, nil, nil "
                  "return ns.HasOffSpec(d)") is True
    # removing the off spec restores the old shape
    assert C.eval("return ns.BiS:RemoveOffSpec()") is True
    d = data_of(C)
    assert "os" not in d and "op" not in d and "ox" not in d and "opr" not in d and "opx" not in d, d
    r.w.assert_no_errors()


@R.case
def copy_between_lists_and_obtained_covers_off_spec():
    r = setup()
    C = r["Carol"]
    C.eval("ns.BiS:SetSpec('Protection', 'os')")
    # copy the main spec's P1 into the off spec (fill empty)
    assert C.eval("return ns.BiS:CopyPhase(1, 1, false, 'os', 'ms')") is True
    ms = data_of(C)["ph"][0]
    assert data_of(C)["op"][0] == ms, (data_of(C)["op"], ms)
    # an off-spec item Carol holds is in the synced obtained list
    os_pick(C, 1, SID_MH, "main", MINDBLADE)
    C.set_bags({(0, 1): MINDBLADE})
    r.w.tick(3)
    assert MINDBLADE in data_of(C)["ob"]
    r.w.assert_no_errors()


@R.case
def council_gets_off_spec_and_wanters_modes():
    r = setup()
    with_offspec(r)
    A = r["Alice"]
    d = data_of(A, key("Carol"))
    assert d and d.get("os") == "Protection" and d.get("op"), d
    ms = wanter_keys(A, MINDBLADE)
    assert ms == [key("Dave") + ":alt"], ms
    both = A.eval_py("""
        local out = {}
        for _, w in ipairs(ns.Store:GetWanters(..., { list = 'both' })) do
          out[#out + 1] = { key = w.key, os = w.os or false, spec = w.spec, which = w.which }
        end
        return out""", MINDBLADE)
    assert [(x["key"], x["os"]) for x in both] == [(key("Dave"), False), (key("Carol"), True)], both
    assert both[1]["spec"] == "Protection" and both[1]["which"] == "main"
    only = A.eval_py("local out = {} for _, w in ipairs(ns.Store:GetWanters(..., { list = 'os' })) do out[#out+1] = w.key end return out", MINDBLADE)
    assert only == [key("Carol")], only
    # a player who has the item on their main list is not listed a second time for the off spec
    os_pick(r["Dave"], 1, SID_MH, "main", MINDBLADE)
    r.w.tick(12)
    both = A.eval_py("local out = {} for _, w in ipairs(ns.Store:GetWanters(..., { list = 'both' })) do out[#out+1] = w.key end return out", MINDBLADE)
    assert both.count(key("Dave")) == 1, both
    s = A.eval_py("return ns.Store:GetPlayerSummary(...)", key("Carol"), 1, "os")
    assert s["filled"] == 1 and s["needed"] == 1, s
    r.w.assert_no_errors()


@R.case
def roll_ranks_off_spec_between_alt_and_everyone_else():
    r = setup()
    w = r.w
    with_offspec(r)
    A = r["Alice"]
    A.eval("ns.DropPanel:StartRoll(...)", MINDBLADE, 1)
    w.tick(1)
    sid = active_session(A)["id"]
    click_roll(r, "Frank", 99)     # not listed
    click_roll(r, "Carol", 50)     # off spec
    click_roll(r, "Dave", 5)       # main-spec alt
    w.tick(1)
    res = results(A, sid)
    assert [(x["key"], x["tier"]) for x in res[:3]] == [(key("Dave"), 2), (key("Carol"), 3), (key("Frank"), 4)], res
    assert res[0]["suggested"]
    # without Dave, the off-spec player beats the higher roll of someone who doesn't list it
    r["Dave"].eval("ns.BiS:ClearSlot(1, 15)")
    r["Dave"].eval("ns.BiS:Commit()")
    w.tick(12)
    A.eval("ns.Roll:End(...)", sid)
    w.tick(1)
    A.eval("ns.DropPanel:StartRoll(...)", MINDBLADE, 1)
    w.tick(5)          # (a re-roll waits out the previous roll's grace period)
    sid2 = active_session(A)["id"]
    assert sid2 != sid
    click_roll(r, "Frank", 99)
    click_roll(r, "Carol", 50)
    w.tick(1)
    A.eval("ns.Roll:End(...)", sid2)
    w.tick(1)
    res = results(A, sid2)
    assert res[0]["key"] == key("Carol") and res[0]["suggested"] and res[0]["tier"] == 3, res
    chat0 = len(w.chat_log)
    A.eval("ns.DropPanel:AwardSuggested(...)", A.eval(
        "for _, b in ipairs(ns.DropPanel.blocks) do if b.itemID == %d then return b end end" % MINDBLADE))
    w.tick(0.2)
    A.accept_popup(A.popups()[0])
    w.tick(3)
    line = [e for e in w.chat_log[chat0:] if "->" in e["text"]]
    assert strip_codes(line[0]["text"]).endswith("-> Carol (rolled 50, Offspec)"), line
    vis = ledger_visible(r["Bob"])
    assert vis[0]["w"] == key("Carol")
    assert r["Bob"].eval("return ns.Ledger:CountSince(...)", key("Carol"), 0) == 0   # offspec: not loot won
    w.assert_no_errors()


@R.case
def drop_panel_shows_off_spec_after_main_spec():
    r = setup()
    with_offspec(r)
    A = r["Alice"]
    A.eval("ns.DropPanel:ShowHistory()")
    r.w.tick(0.5)
    A.eval("ns.DropPanel:Render()")
    blk = [b for b in panel_blocks(A) if b["item"] == MINDBLADE][0]
    assert blk["names"] == [key("Dave"), key("Carol")], blk
    # (1.3.1: no "1 want +1 OS" count: the rows show it; the row's pill says OS)
    badge = strip_codes(A.eval("""
        for _, b in ipairs(ns.DropPanel.blocks) do if b.itemID == ... then
          for _, row in ipairs(b.rows) do if row.data and row.data.key == ns.Util.NormalizeName('Carol') then return row.badge:GetText() end end
        end end""", MINDBLADE))
    assert badge == "OS", badge
    line = A.eval("return ns.DropPanel:BuildAnnounceLine(...)", MINDBLADE)
    assert strip_codes(line).endswith("Alt: Dave; OS: Carol"), line
    r.w.assert_no_errors()


@R.case
def personal_alerts_for_off_spec_items():
    r = Raid()
    C = r["Carol"]
    with_offspec(r, sync=False)
    C.open_loot([(MINDBLADE, 4)], source_guid=PRINCE_GUID)
    r.w.tick(2)
    st = toast_state(C)
    assert st["shown"] and st["item"] == MINDBLADE, st
    assert strip_codes(st["kicker"]).lower() == "on your off-spec list (protection)", st   # (1.4: the UI:Toast kicker)
    assert any("is on your off-spec list (Protection)" in strip_codes(l) for l in printed_lines(C))
    rows = C.show_tooltip_item(MINDBLADE)
    assert any("Your off-spec BiS P1 (Protection) · Main Hand" in strip_codes(l or "") for l, _ in rows), rows
    # the setting turns them off
    C.close_loot()
    C.eval("ns.DB:SetSetting('alerts.offspec', false) ns.DropPanel.recentAlerts = {} ns.DropPanel:DismissToast()")
    C.eval("ns.DropPanel.toastQueue = {}")
    C.open_loot([(MINDBLADE, 4)], source_guid="Creature-0-1-2-3-15690-000ABD")
    r.w.tick(2)
    assert not toast_state(C)["shown"], toast_state(C)
    r.w.assert_no_errors()


@R.case
def spec_pill_swap_lists():
    r = setup()
    C = r["Carol"]
    C.eval("ns.MainFrame:Open('mybis')")
    r.w.tick(0.5)
    C.eval("ns.BiS:SetSlot(1, 15, 'main', ...)", MINDBLADE)
    assert C.eval("return ns.BiS:SwapLists()") is False, "no off spec yet"
    ms = C.eval("return ns.BiS:GetSpec()")
    other = C.eval("for _, s in ipairs(ns.SPECS[ns.BiS:GetData().cl]) do if s.label ~= ns.BiS:GetSpec() then return s.label end end")
    assert C.eval("return ns.BiS:SetSpec(..., 'os')", other) is True
    assert C.eval("return ns.BiS:SwapLists()") is True
    r.w.tick(0.4)
    assert C.eval("return ns.BiS:GetSpec()") == other
    assert C.eval("return ns.BiS:GetSpec('os')") == ms
    assert C.eval("return (ns.BiS:GetSlot(1, 15, 'os'))") == MINDBLADE
    assert C.eval("return (ns.BiS:GetSlot(1, 15))") is None
    assert C.find_text(other)
    r.w.assert_no_errors()


@R.case
def spec_tabs_keep_picks_with_their_spec():
    r = setup()
    C = r["Carol"]
    C.eval("ns.MainFrame:Open('mybis')")
    r.w.tick(0.5)
    C.eval("ns.BiS:SetSlot(1, 15, 'main', ...)", MINDBLADE)
    specs = C.eval("local t = {} for _, s in ipairs(ns.SPECS[ns.BiS:GetData().cl]) do t[#t + 1] = s.label end "
                   "return table.concat(t, '|')").split("|")
    ms = C.eval("return ns.BiS:GetSpec()")
    others = [s for s in specs if s != ms]
    C.eval("ns.BiS:SetSpec(..., 'os')", others[0])
    C.eval("ns.MyBiS:Refresh()")
    n = C.eval("return #ns.MyBiS:GetSpecTabs()")
    assert n == len(specs), (n, specs)
    # an unused spec as the main spec relabels the picks: asks first
    C.eval("local want = ...; for _, t in ipairs(ns.MyBiS:GetSpecTabs()) do if t.spec == want then T_SPEC_TAB = t.btn end end", others[1])
    C.click("T_SPEC_TAB", "RightButton")
    r.w.tick(0.1)
    C.menu_select("Make main spec")
    r.w.tick(0.1)
    assert C.eval("return ns.BiS:GetSpec()") == ms, "not before the popup is accepted"
    C.accept_popup("DISASTERZONE_RELABEL_LIST")
    r.w.tick(0.2)
    assert C.eval("return ns.BiS:GetSpec()") == others[1]
    assert C.eval("return (ns.BiS:GetSlot(1, 15))") == MINDBLADE
    # the off spec as the main spec swaps the lists, picks and all, without asking
    C.eval("local want = ...; for _, t in ipairs(ns.MyBiS:GetSpecTabs()) do if t.spec == want then T_SPEC_TAB = t.btn end end", others[0])
    C.click("T_SPEC_TAB", "RightButton")
    r.w.tick(0.1)
    C.menu_select("Make main spec (swap the lists)")
    r.w.tick(0.2)
    assert C.eval("return ns.BiS:GetSpec()") == others[0]
    assert C.eval("return ns.BiS:GetSpec('os')") == others[1]
    assert C.eval("return (ns.BiS:GetSlot(1, 15, 'os'))") == MINDBLADE
    r.w.assert_no_errors()


@R.case
def my_bis_switch_picker_and_remove():
    r = setup()
    C = r["Carol"]
    C.eval("ns.MainFrame:Open('mybis')")
    r.w.tick(0.5)
    assert C.eval("return ns.MyBiS:GetList()") == "ms"
    C.eval("ns.MyBiS:SetList('os')")
    r.w.tick(0.2)
    assert C.eval("return ns.MyBiS:GetList()") == "os"
    assert C.find_text("Off"), "the spec pill's tag"
    # the picker opened from the off-spec view writes the off-spec list
    C.eval("ns.Picker:Open(1, 15, 'main', nil, 'os')")
    assert "Off spec" in (C.eval("return DisasterZonePicker.TitleText and DisasterZonePicker.TitleText:GetText() or ''") or "")
    C.eval("ns.BiS:SetSlot(1, 15, 'main', ..., select(4, ns.Picker:GetState()))", MINDBLADE)
    assert C.eval("return (ns.BiS:GetSlot(1, 15, 'os'))") == MINDBLADE
    assert C.eval("return (ns.BiS:GetSlot(1, 15))") is None
    # removal asks first
    assert C.eval("return ns.BiS:HasOffSpec()") is True
    assert C.eval("return ns.MyBiS:ConfirmRemoveOffSpec()") is True
    C.accept_popup("DISASTERZONE_REMOVE_OFFSPEC")
    r.w.tick(0.2)
    assert C.eval("return ns.BiS:HasOffSpec()") is False
    assert C.eval("return ns.MyBiS:GetList()") == "ms"
    r.w.assert_no_errors()


@R.case
def council_off_spec_view():
    r = setup()
    with_offspec(r)
    A = r["Alice"]
    A.eval("ns.MainFrame:Open('council')")
    r.w.tick(0.5)
    A.eval("DisasterZoneCouncilPanel.offspecCB:Click()")
    r.w.tick(0.5)
    # the roster only holds players with an off-spec list, shown with the off-spec spec
    keys = A.eval_py("""
        local out = {}
        local list = DisasterZoneCouncilPanel.rosterView and DisasterZoneCouncilPanel.rosterView.list
        local data = list and list.data or {}
        for _, m in ipairs(data) do out[#out + 1] = m.key .. ':' .. (m.spec or '') end
        return out""")
    assert keys == [key("Carol") + ":Protection"], keys
    r.w.assert_no_errors()


@R.case
def lock_covers_off_spec():
    r = setup()
    w = r.w
    with_offspec(r)
    A, C = r["Alice"], r["Carol"]
    A.slash("/dz lock")
    w.tick(6)          # (lists committed up to 3 s after the lock count as saved before it)
    assert C.eval("return ns.BiS:SetSlot(1, 16, 'main', ..., 'os')", LIGHTS_JUSTICE) is False
    assert C.eval("return ns.BiS:SetSpec('Arms', 'os')") is False
    # a forged off-spec edit (bypassing the API) is flagged by the council
    C.eval("local d = ns.BiS:GetData() d.op[1][16] = { ..., 0 } ns.BiS:Commit()", LIGHTS_JUSTICE)
    w.tick(12)
    assert A.eval("return ns.Store:GetLockFlag(...) ~= nil", key("Carol")) is True
    w.assert_no_errors()


if __name__ == "__main__":
    main(R)

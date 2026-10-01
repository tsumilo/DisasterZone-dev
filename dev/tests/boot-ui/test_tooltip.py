"""Item tooltips: own BiS line (main / alt / obtained / token / other phases), council lines (limit, "+K more",
Shift at show time, Shift pressed later), settings switches, no duplicate lines on repeated OnTooltipSetItem,
cache invalidation, ItemRefTooltip.

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_tooltip.py
"""
from _common import case, run_all, solo, no_errors, install_helpers, strip_codes, tt_lines

MAG_HEAD = 32385          # Magtheridon's Head: quest item -> 4 rings; 15 demo wanters


def cdl_lines(lines):
    return [strip_codes(l) for l, _ in lines if "DisasterZone" in l]


def show(c, item_id):
    lines = c.show_tooltip_item(item_id)
    return [(l or "", r or "") for l, r in lines]


def first_candidate(c, sid, phase=1, lua_pred="return true"):
    return c.eval("""
      local sid, phase, pred = ...
      local f = loadstring(pred)
      for _, r in ipairs(ns.ItemDB:GetCandidates(sid, { maxPhase = phase, class = 'PALADIN', usableOnly = true })) do
        if f(r) then return r.itemID end
      end""", sid, phase, "local r = ...; " + lua_pred)


@case
def own_lines_main_alt_obtained_other_phases():
    w, c = solo("Alice", guild_rank=3, tick=4)
    install_helpers(c)
    head = first_candidate(c, 1)
    ring = first_candidate(c, 11)
    c.eval("ns.BiS:SetSlot(1, 1, 'main', ...)", head)
    c.eval("ns.BiS:SetSlot(2, 1, 'main', ...)", head)
    c.eval("ns.BiS:SetSlot(3, 1, 'main', ...)", head)
    c.eval("ns.BiS:SetSlot(2, 12, 'alt', ...)", ring)
    lines = cdl_lines(show(c, head))
    assert lines == ["DisasterZone  Your P1 BiS (main) - Head  also P2, P3"], lines
    lines = cdl_lines(show(c, ring))
    assert lines == ["DisasterZone Your P2 alt - Ring 2"], lines
    # the view phase is listed first
    c.eval("ns.DB:SetSetting('viewPhase', 3)")
    assert cdl_lines(show(c, head)) == ["DisasterZone  Your P3 BiS (main) - Head  also P1, P2"]
    c.eval("ns.DB:SetSetting('viewPhase', nil)")
    # obtained suffix once the item is in the bags (after the debounced scan)
    c.set_bags({(0, 1): head})
    w.tick(2)
    lines = cdl_lines(show(c, head))
    assert lines == ["DisasterZone  Your P1 BiS (main) - Head obtained  also P2, P3"], lines
    # unrelated item: no DisasterZone line at all; non-council: never council lines
    other = first_candidate(c, 7)
    assert cdl_lines(show(c, other)) == []
    assert c.eval("return ns.Guild:AmICouncil()") is False
    no_errors(w)


@case
def token_and_upgrade_via_lines():
    w, c = solo("Alice", guild_rank=3, tick=4)
    install_helpers(c)
    piece, token = c.eval("""
      for _, r in ipairs(ns.ItemDB:GetCandidates(1, { maxPhase = 1, class = 'PALADIN', usableOnly = true })) do
        if r.via == 'token' then return r.itemID, r.viaItem end
      end""")
    assert piece and token, (piece, token)
    c.eval("ns.BiS:SetSlot(1, 1, 'main', ...)", piece)
    pname = c.eval("return ns.ItemDB:GetName(...)", piece)
    lines = cdl_lines(show(c, token))
    assert lines == ["DisasterZone  Your P1 BiS (main) - Head (via token: %s)" % pname], lines
    # holding the token counts the piece as obtained ("Have token")
    c.set_bags({(0, 1): token})
    w.tick(2)
    assert c.eval("return ns.BiS:GetObtainedState(...)", piece) == "token"
    assert "obtained" in cdl_lines(show(c, token))[0]
    # Sunmote upgrade: the base item shows the upgraded pick
    base, up = c.eval("for b, u in pairs(ns.Data.Upgrades) do return b, u end")
    if base:
        sid = c.eval("return ns.ItemDB:GetSlotsForItem(...)[1]", up)
        if c.eval("local id, s = ...; return ns.ItemDB:FitsSlot(id, s)", up, sid):
            c.eval("local s, id = ...; ns.BiS:SetSlot(5, s, 'main', id)", sid, up)
            lines = cdl_lines(show(c, base))
            assert lines and "via Sunmote upgrade" in lines[0], lines
    no_errors(w)


@case
def council_lines_limit_shift_and_expand():
    w, c = solo("Alice", guild_rank=3, tick=4)
    install_helpers(c)
    c.slash("/dz demo on")
    w.tick(0.3)
    # DisasterZone 0.5: the expected counts come from the demo data (they depend on the item database), the header says
    # "wanted by N" like the drop panel ("N want"), and the " · K BiS" part appears when some picks are alts.
    need, have, inraid, mains = c.eval_py("""
        local seen, need, have, inraid, mains = {}, 0, 0, 0, 0
        for _, w in ipairs(ns.Store:GetWanters(..., { includeObtained = true })) do
          if not seen[w.key] then
            seen[w.key] = true
            if w.obtained then have = have + 1 else
              need = need + 1
              if w.inRaid then inraid = inraid + 1 end
              if w.which ~= "alt" then mains = mains + 1 end
            end
          end
        end
        return { need, have, inraid, mains }""", MAG_HEAD)
    total = need + have
    assert total > 6 and have > 0 and inraid > 0, (need, have, inraid)
    lines = show(c, MAG_HEAD)
    head = [strip_codes(l) for l, _ in lines if l.startswith("|cffff8000DisasterZone|r: wanted by")]
    want = "DisasterZone: wanted by %d (%d in raid)%s, %d obtained" % (need, inraid,
                                                             (" · %d BiS" % mains) if mains < need else "", have)
    assert head == [want], (head, want)
    names = [l for l, r in lines if l.startswith("  |c") or l.startswith("  ")]
    name_lines = [l for l in names if not l.strip().startswith("Wearing") and "more (hold Shift)" not in l]
    assert len(name_lines) == 5, name_lines
    assert not any(l.strip().startswith("Wearing") for l, _ in lines), "wear lines only while Shift is held"
    assert [strip_codes(l) for l, _ in lines if "more (hold Shift)" in l] == ["  +%d more (hold Shift)" % (total - 5)]
    # in-raid players are listed first, with "in raid" on the right
    k = min(5, inraid)
    assert [r for l, r in lines if l in name_lines][:k] == ["in raid"] * k
    # bigger limit from the setting
    c.eval("ns.DB:SetSetting('tooltip.maxNames', 12)")
    lines = show(c, MAG_HEAD)
    assert [strip_codes(l) for l, _ in lines if "more (hold Shift)" in l] == (
        ["  +%d more (hold Shift)" % (total - 12)] if total > 12 else [])
    c.eval("ns.DB:SetSetting('tooltip.maxNames', 5)")
    # Shift held while the tooltip is built: every name
    c.set_modifiers(shift=True)
    full = show(c, MAG_HEAD)
    c.set_modifiers()
    assert not any("more (hold Shift)" in l for l, _ in full)
    full_names = [l for l, _ in full if l.startswith("  ") and not l.strip().startswith("Wearing")]
    assert len(full_names) == total, full_names
    # Shift pressed after the tooltip is shown: the "+K more" line becomes the next name, the rest is appended
    show(c, MAG_HEAD)
    c.set_modifiers(shift=True)
    expanded = tt_lines(c)
    c.set_modifiers()
    exp_names = [l for l, _ in expanded if l.startswith("  ") and not l.strip().startswith("Wearing")]
    assert not any("more (hold Shift)" in l for l, _ in expanded), expanded
    assert [strip_codes(x) for x in exp_names] == [strip_codes(x) for x in full_names], (exp_names, full_names)
    # obtained players are listed last with "obtained" on the right
    rights = [r for l, r in full if l in full_names]
    assert rights[-have:] == ["obtained"] * have, rights
    no_errors(w)


@case
def settings_switch_lines_off():
    w, c = solo("Alice", guild_rank=3, tick=4)
    install_helpers(c)
    c.slash("/dz demo on")
    head = first_candidate(c, 1)
    c.eval("ns.BiS:SetSlot(1, 1, 'main', ...)", head)
    c.eval("ns.BiS:SetSlot(1, 11, 'main', 28791)") if c.eval("return ns.ItemDB:FitsSlot(28791, 11)") else None
    assert cdl_lines(show(c, MAG_HEAD))
    c.eval("ns.DB:SetSetting('tooltip.council', false)")
    assert not any("wanted by" in l for l in cdl_lines(show(c, MAG_HEAD)))
    assert cdl_lines(show(c, head)) == ["DisasterZone  Your P1 BiS (main) - Head"]
    c.eval("ns.DB:SetSetting('tooltip.enabled', false)")
    assert cdl_lines(show(c, head)) == []
    assert cdl_lines(show(c, MAG_HEAD)) == []
    c.eval("ns.DB:SetSetting('tooltip.enabled', true); ns.DB:SetSetting('tooltip.council', true)")
    assert cdl_lines(show(c, MAG_HEAD))
    # demo off: back to a plain raider -> no council lines
    c.slash("/dz demo off")
    assert not any("wanted by" in l for l in cdl_lines(show(c, MAG_HEAD)))
    no_errors(w)


@case
def no_duplicate_lines_on_repeated_set_item():
    w, c = solo("Alice", guild_rank=3, tick=4)
    install_helpers(c)
    c.slash("/dz demo on")
    head = first_candidate(c, 1)
    c.eval("ns.BiS:SetSlot(1, 1, 'main', ...)", head)
    for item in (MAG_HEAD, head):
        base = show(c, item)
        for _ in range(3):
            c.eval("__MOCK.call_script(GameTooltip, 'OnTooltipSetItem')")
        again = tt_lines(c)
        assert again == base, (item, len(base), len(again))
        assert sum(1 for l, _ in again if "DisasterZone" in l) == sum(1 for l, _ in base if "DisasterZone" in l)
    # ItemRefTooltip (chat links) is hooked too, also without duplicates
    link = c.eval("return (select(2, C_Item.GetItemInfo(...)))", head)
    c.eval("ItemRefTooltip:SetOwner(UIParent, 'ANCHOR_PRESERVE'); ItemRefTooltip:SetHyperlink(...)", link)
    c.eval("__MOCK.call_script(ItemRefTooltip, 'OnTooltipSetItem')")
    ref = tt_lines(c, "ItemRefTooltip")
    own = [strip_codes(l) for l, _ in ref if "DisasterZone" in l and "wanted by" not in l]
    assert own == ["DisasterZone  Your P1 BiS (main) - Head"], ref
    assert sum(1 for l, _ in ref if "wanted by" in l) == 1, ref
    # a DisasterZone item button tooltip (SetItemByID + extra lines) does not duplicate the own line either
    c.slash("/dz bis")
    w.tick(0.3)
    c.hover(c.eval("return T_tile(1).main"))
    tl = [strip_codes(l) for l, _ in tt_lines(c)]
    assert sum(1 for l in tl if l.startswith("DisasterZone ") and "Your P1 BiS" in l) == 1, tl
    no_errors(w)


@case
def cache_is_invalidated_by_list_changes():
    w, c = solo("Alice", guild_rank=3, tick=4)
    install_helpers(c)
    head = first_candidate(c, 1)
    assert cdl_lines(show(c, head)) == []
    c.eval("ns.BiS:SetSlot(1, 1, 'main', ...)", head)       # within the 2 s cache window
    assert cdl_lines(show(c, head)) == ["DisasterZone  Your P1 BiS (main) - Head"]
    c.eval("ns.BiS:SwapMainAlt(1, 1)")
    assert cdl_lines(show(c, head)) == ["DisasterZone Your P1 alt - Head"]
    c.eval("ns.BiS:SetManualObtained(..., true)", head)
    assert "obtained" in cdl_lines(show(c, head))[0]
    c.eval("ns.BiS:ClearSlot(1, 1)")
    assert cdl_lines(show(c, head)) == []
    # council side: an award (LEDGER_UPDATED) shows immediately
    c.slash("/dz demo on")
    before = show(c, MAG_HEAD)
    first_name = next(l for l, _ in before if l.startswith("  |c"))
    key = strip_codes(first_name).strip() + "-Thunderstrike"
    wanted = c.eval("local k = ...; for _, e in ipairs(ns.Store:GetWanters(32385, {})) do if e.key == k then return e.wanted end end", key)
    assert wanted, key
    assert c.eval("local id, k = ...; return ns.Ledger:Award(id, k, '', nil) ~= nil", wanted, key) is True
    w.tick(0.3)                         # LEDGER_UPDATED is debounced (0.2 s)
    assert c.eval("local id, k = ...; return ns.Ledger:HasAward(k, id)", wanted, key) is True
    after = show(c, MAG_HEAD)
    rights = {strip_codes(l).strip(): r for l, r in after if l.startswith("  |c")}
    assert rights.get(strip_codes(first_name).strip()) == "awarded", rights
    no_errors(w)


if __name__ == "__main__":
    run_all()

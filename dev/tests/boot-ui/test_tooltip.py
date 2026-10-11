"""Item tooltips (1.3.5 compact block): own BiS line (main / alt / obtained / token / phase ranges), the council's
one-line wanters list and the full block with Shift (held at show time, or pressed later: expanded in place),
comparison tooltips staying compact, settings switches, no duplicate lines on repeated OnTooltipSetItem, cache
invalidation, ItemRefTooltip.

Run: luaenv\\Scripts\\python.exe tests\\boot-ui\\test_tooltip.py
"""
import re

from _common import case, run_all, solo, no_errors, install_helpers, strip_codes, tt_lines

MAG_HEAD = 32385          # Magtheridon's Head: quest item -> 4 rings; 15 demo wanters
SEAL = "Launcher\\seal"   # every DisasterZone item tooltip line starts with the seal icon


def plain(l):
    return " ".join(strip_codes(l or "").split())   # an icon leaves two spaces


def cdl_lines(lines):
    return [plain(l) for l, _ in lines if SEAL in (l or "")]


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
def own_lines_main_alt_obtained_phase_ranges():
    w, c = solo("Alice", guild_rank=3, tick=4)
    install_helpers(c)
    head = first_candidate(c, 1)
    ring = first_candidate(c, 11)
    c.eval("ns.BiS:SetSlot(1, 1, 'main', ...)", head)
    c.eval("ns.BiS:SetSlot(2, 1, 'main', ...)", head)
    c.eval("ns.BiS:SetSlot(3, 1, 'main', ...)", head)
    c.eval("ns.BiS:SetSlot(2, 12, 'alt', ...)", ring)
    # three phases in a row become a range; "(main)" is gone (only alt / off-spec picks are labelled)
    lines = cdl_lines(show(c, head))
    assert lines == ["Your BiS P1–P3 · Head"], lines
    lines = cdl_lines(show(c, ring))
    assert lines == ["Your alt P2 · Ring 2"], lines
    # two phases are listed, not ranged; the view phase no longer reorders them
    c.eval("ns.BiS:ClearSlot(2, 1)")
    c.eval("ns.DB:SetSetting('viewPhase', 3)")
    assert cdl_lines(show(c, head)) == ["Your BiS P1, P3 · Head"]
    c.eval("ns.DB:SetSetting('viewPhase', nil)")
    c.eval("ns.BiS:SetSlot(2, 1, 'main', ...)", head)
    # BiS in P1 but only the alt pick in P2 and P3 (another item is BiS there): never "BiS P1–P3"
    other_head = first_candidate(c, 1, 3, "return r.itemID ~= %d" % head)
    for p in (2, 3):
        c.eval("local p, a, b = ...; ns.BiS:SetSlot(p, 1, 'main', a); ns.BiS:SetSlot(p, 1, 'alt', b)", p, other_head, head)
    lines = cdl_lines(show(c, head))
    assert lines == ["Your BiS P1 · Head · alt P2, P3"], lines
    # only ever the alt pick
    c.eval("local a, b = ...; ns.BiS:SetSlot(1, 1, 'main', a); ns.BiS:SetSlot(1, 1, 'alt', b)", other_head, head)
    lines = cdl_lines(show(c, head))
    assert lines == ["Your alt P1–P3 · Head"], lines
    for p in (1, 2, 3):
        c.eval("local p, a = ...; ns.BiS:ClearSlot(p, 1); ns.BiS:SetSlot(p, 1, 'main', a)", p, head)
    lines = cdl_lines(show(c, head))
    assert lines == ["Your BiS P1–P3 · Head"], lines
    # obtained suffix once the item is in the bags (after the debounced scan)
    c.set_bags({(0, 1): head})
    w.tick(2)
    lines = cdl_lines(show(c, head))
    assert lines == ["Your BiS P1–P3 · Head obtained"], lines
    # unrelated item: no DisasterZone line at all; non-council: never council lines
    other = first_candidate(c, 7)
    assert cdl_lines(show(c, other)) == []
    assert c.eval("return ns.Guild:AmICouncil()") is False
    # nothing to expand: Shift shows the same single line
    c.set_modifiers(shift=True)
    assert cdl_lines(show(c, head)) == ["Your BiS P1–P3 · Head obtained"]
    c.set_modifiers()
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
    assert lines == ["Your BiS P1 · Head (via token: %s)" % pname], lines
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


def wanter_counts(c):
    return c.eval_py("""
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


def compact_names(line):
    """The names of a compact wanters line and its "+K"."""
    m = re.match(r"^\d+ want(?: · \d+ here)?: (.*?)(?: \+(\d+))?$", line)
    assert m, line
    return m.group(1).split(", "), int(m.group(2) or 0)


@case
def council_compact_line_and_shift_detail():
    w, c = solo("Alice", guild_rank=3, tick=4)
    install_helpers(c)
    c.slash("/dz demo on")
    w.tick(0.3)
    need, have, inraid, mains = wanter_counts(c)
    total = need + have
    assert total > 6 and have > 0 and inraid > 0, (need, have, inraid)
    # compact: ONE line, "N want · K here: A, B, C +R", no per-name lines
    lines = show(c, MAG_HEAD)
    ours = cdl_lines(lines)
    want = [l for l in ours if " want" in l]
    assert len(want) == 1 and want[0].startswith("%d want · %d here: " % (need, inraid)), ours
    names, rest = compact_names(want[0])
    assert 1 <= len(names) <= 5 and len(names) + rest == need, (names, rest, need)
    assert not any(l.startswith("  ") for l, _ in lines), "no name lines without Shift"
    # those in the raid come first
    in_raid = set(c.eval_py("""
        local out = {}
        for _, w in ipairs(ns.Store:GetWanters(..., {})) do
          if w.inRaid then out[#out + 1] = ns.Util.ShortName(w.key) end
        end
        return out""", MAG_HEAD))
    k = min(len(names), inraid)
    assert all(n in in_raid for n in names[:k]), (names, in_raid)
    # the maxNames setting caps the names (the line also stops at about 40 letters)
    c.eval("ns.DB:SetSetting('tooltip.maxNames', 1)")
    names1, rest1 = compact_names([l for l in cdl_lines(show(c, MAG_HEAD)) if " want" in l][0])
    assert len(names1) == 1 and rest1 == need - 1, (names1, rest1)
    c.eval("ns.DB:SetSetting('tooltip.maxNames', 5)")
    # Shift held while the tooltip is built: the counts, then every player on a line of their own
    c.set_modifiers(shift=True)
    full = show(c, MAG_HEAD)
    c.set_modifiers()
    head = [plain(l) for l, _ in full if "Wanted by" in l]
    want_head = "Wanted by %d%s · %d here · %d %s it" % (need, (" · %d BiS" % mains) if mains < need else "", inraid,
                                                       have, "has" if have == 1 else "have")
    assert head == [want_head], (head, want_head)
    full_names = [(l, r) for l, r in full if l.startswith("  ") and SEAL not in l]
    assert len(full_names) == total, full_names
    # in-raid players first with "in raid" on the right; obtained ones last
    rights = [r for _, r in full_names]
    assert all(r.startswith("in raid") for r in rights[:min(5, inraid)]), rights
    assert rights[-have:] == ["obtained"] * have, rights
    # Shift pressed after the tooltip is shown: the compact block turns into the full one in place
    show(c, MAG_HEAD)
    c.set_modifiers(shift=True)
    expanded = tt_lines(c)
    c.set_modifiers()
    assert [(plain(l), r) for l, r in expanded] == [(plain(l), r) for l, r in full], (expanded, full)
    no_errors(w)


@case
def shift_with_lines_under_the_block_redraws_via_owner():
    w, c = solo("Alice", guild_rank=3, tick=4)
    install_helpers(c)
    c.slash("/dz demo on")
    w.tick(0.3)
    show(c, MAG_HEAD)
    # another addon's line under ours: no in-place rewrite (it would land above that line)
    c.eval("GameTooltip:AddLine('Other addon line')")
    before = tt_lines(c)
    c.set_modifiers(shift=True)
    after = tt_lines(c)
    c.set_modifiers()
    assert after == before, (before, after)
    no_errors(w)


@case
def comparison_tooltips_stay_compact():
    w, c = solo("Alice", guild_rank=3, tick=4)
    install_helpers(c)
    c.slash("/dz demo on")
    w.tick(0.3)
    link = c.eval("return (select(2, C_Item.GetItemInfo(...)))", MAG_HEAD)
    c.set_modifiers(shift=True)
    c.eval("ShoppingTooltip1:SetOwner(UIParent, 'ANCHOR_NONE'); ShoppingTooltip1:SetHyperlink(...)", link)
    c.eval("__MOCK.call_script(ShoppingTooltip1, 'OnTooltipSetItem')")
    lines = tt_lines(c, "ShoppingTooltip1")
    c.set_modifiers()
    ours = cdl_lines(lines)
    assert any(" want" in l for l in ours) and not any("Wanted by" in l for l in ours), ours
    no_errors(w)


@case
def prized_item_one_line_and_rules_on_shift():
    w, c = solo("Alice", guild_rank=0, tick=4)       # the GM may make prized items
    install_helpers(c)
    head = first_candidate(c, 1)
    assert c.eval("""return ns.Prized:Add({ ... }, { main = { m = 'r' }, guild = { m = 'r' }, bis = { m = 'r' },
                       vote = { s = 'all' } }) ~= nil""", head) is True
    w.tick(0.5)
    c.eval("ns.Tooltip:Invalidate()")
    # not on my list: only the rule I miss, and how it's decided
    lines = cdl_lines(show(c, head))
    assert lines == ["Prized · not on your BiS list · council decides"], lines
    # on my list: one line, I qualify
    c.eval("ns.BiS:SetSlot(1, 1, 'main', ...)", head)
    lines = cdl_lines(show(c, head))
    assert lines == ["Your BiS P1 · Head", "Prized · you qualify · council decides", "1 want: Alice"], lines
    # Shift: every rule ticked on a line of its own (the vote rule says it in the head line)
    c.set_modifiers(shift=True)
    full = show(c, head)
    c.set_modifiers()
    i = next(n for n, (l, _) in enumerate(full) if "Prized" in l)
    assert plain(full[i][0]) == "Prized · the Loot Council decides, no rolls", full[i:]
    rules = [plain(l) for l, _ in full[i + 1:i + 4]]
    assert rules == ["Main characters only", "Guild members only", "Only players with it on their BiS list"], rules
    assert all("ReadyCheck-Ready" in l for l, _ in full[i + 1:i + 4]), full[i + 1:i + 4]
    # Shift pressed later: expanded in place
    show(c, head)
    c.set_modifiers(shift=True)
    assert [plain(l) for l, _ in tt_lines(c)] == [plain(l) for l, _ in full]
    c.set_modifiers()
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
    assert not any(" want" in l for l in cdl_lines(show(c, MAG_HEAD)))
    assert cdl_lines(show(c, head)) == ["Your BiS P1 · Head"]
    c.eval("ns.DB:SetSetting('tooltip.enabled', false)")
    assert cdl_lines(show(c, head)) == []
    assert cdl_lines(show(c, MAG_HEAD)) == []
    c.eval("ns.DB:SetSetting('tooltip.enabled', true); ns.DB:SetSetting('tooltip.council', true)")
    assert cdl_lines(show(c, MAG_HEAD))
    # demo off: back to a plain raider -> no council lines
    c.slash("/dz demo off")
    assert not any(" want" in l for l in cdl_lines(show(c, MAG_HEAD)))
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
        assert sum(1 for l, _ in again if SEAL in l) == sum(1 for l, _ in base if SEAL in l)
    # ItemRefTooltip (chat links) is hooked too, also without duplicates
    link = c.eval("return (select(2, C_Item.GetItemInfo(...)))", head)
    c.eval("ItemRefTooltip:SetOwner(UIParent, 'ANCHOR_PRESERVE'); ItemRefTooltip:SetHyperlink(...)", link)
    c.eval("__MOCK.call_script(ItemRefTooltip, 'OnTooltipSetItem')")
    ref = cdl_lines(tt_lines(c, "ItemRefTooltip"))
    assert [l for l in ref if " want" not in l] == ["Your BiS P1 · Head"], ref
    assert sum(1 for l in ref if " want" in l) == 1, ref
    # a DisasterZone item button tooltip (SetItemByID + extra lines) does not duplicate the own line either
    c.slash("/dz bis")
    w.tick(0.3)
    c.hover(c.eval("return T_tile(1).main"))
    tl = cdl_lines(tt_lines(c))
    assert sum(1 for l in tl if l.startswith("Your BiS P1")) == 1, tl
    no_errors(w)


@case
def cache_is_invalidated_by_list_changes():
    w, c = solo("Alice", guild_rank=3, tick=4)
    install_helpers(c)
    head = first_candidate(c, 1)
    assert cdl_lines(show(c, head)) == []
    c.eval("ns.BiS:SetSlot(1, 1, 'main', ...)", head)       # within the 2 s cache window
    assert cdl_lines(show(c, head)) == ["Your BiS P1 · Head"]
    c.eval("ns.BiS:SwapMainAlt(1, 1)")
    assert cdl_lines(show(c, head)) == ["Your alt P1 · Head"]
    c.eval("ns.BiS:SetManualObtained(..., true)", head)
    assert "obtained" in cdl_lines(show(c, head))[0]
    c.eval("ns.BiS:ClearSlot(1, 1)")
    assert cdl_lines(show(c, head)) == []
    # council side: an award (LEDGER_UPDATED) shows immediately (the full block names it "awarded")
    c.slash("/dz demo on")
    c.set_modifiers(shift=True)
    before = show(c, MAG_HEAD)
    first_name = next(l for l, _ in before if l.startswith("  |c"))
    key = plain(first_name) + "-Thunderstrike"
    wanted = c.eval("local k = ...; for _, e in ipairs(ns.Store:GetWanters(32385, {})) do if e.key == k then return e.wanted end end", key)
    assert wanted, key
    assert c.eval("local id, k = ...; return ns.Ledger:Award(id, k, '', nil) ~= nil", wanted, key) is True
    w.tick(0.3)                         # LEDGER_UPDATED is debounced (0.2 s)
    assert c.eval("local id, k = ...; return ns.Ledger:HasAward(k, id)", wanted, key) is True
    after = show(c, MAG_HEAD)
    c.set_modifiers()
    rights = {plain(l): r for l, r in after if l.startswith("  |c")}
    assert rights.get(plain(first_name), "").startswith("awarded"), rights
    no_errors(w)


if __name__ == "__main__":
    run_all()

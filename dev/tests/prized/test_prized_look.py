"""The prized look (1.3.5, the user's picks 2026-10-11): a prized item's tooltip gets the PRIZED ITEM ribbon above it and
an orange edge (anywhere: GameTooltip, ItemRefTooltip, the comparison tooltips), cleared with the tooltip; the drop
panel's card of a prized item glows amber (edge, tint, inner glow, a light running along the top edge).

Run: luaenv\\Scripts\\python.exe tests\\prized\\test_prized_look.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "boot-ui"))

from _common import case, run_all, solo, visible_texts  # noqa: E402

DST = 28830   # Dragonspine Trophy: prized in demo mode
OTHER = 28830 + 1


def demo(c, w):
    c.slash("/dz demo on")
    w.tick(2)
    assert c.eval("return ns.Prized:ForItem(...) ~= nil", DST), "DST should be prized in demo mode"


def ribbon_shown(c, tt="GameTooltip"):
    return c.eval("local tt = _G[...]; return tt.dzPrized ~= nil and tt.dzPrized:IsShown() or false", tt)


@case
def prized_tooltip_gets_the_ribbon_and_loses_it_when_cleared():
    w, c = solo("Alice", guild_rank=0, tick=4)
    demo(c, w)
    c.show_tooltip_item(DST)
    assert ribbon_shown(c)
    txt = c.eval("return GameTooltip.dzPrized.band.text:GetText()")
    assert "P R I Z E D" in txt, txt
    # another, not prized item: no ribbon
    plain = c.eval("""for _, raid in ipairs(ns.ItemDB:GetRaids()) do for _, b in ipairs(raid.bosses or {}) do
        for _, id in ipairs(b.items or {}) do if not ns.Prized:ForItem(id) then return id end end end end""")
    c.show_tooltip_item(plain)
    assert not ribbon_shown(c)
    c.show_tooltip_item(DST)
    c.eval("GameTooltip:Hide()")
    assert not ribbon_shown(c)


@case
def item_link_tooltip_too():
    w, c = solo("Alice", guild_rank=0, tick=4)
    demo(c, w)
    link = c.eval("return (select(2, C_Item.GetItemInfo(...)))", DST)
    c.eval("ItemRefTooltip:SetOwner(UIParent, 'ANCHOR_PRESERVE'); ItemRefTooltip:SetHyperlink(...)", link)
    c.eval("__MOCK.call_script(ItemRefTooltip, 'OnTooltipSetItem')")
    assert ribbon_shown(c, "ItemRefTooltip")


@case
def prized_card_glows_amber_in_the_drop_panel():
    w, c = solo("Alice", guild_rank=0, tick=4)
    demo(c, w)
    c.eval("""local db = ns.ItemDB
        for _, raid in ipairs(db:GetRaids()) do for _, boss in ipairs(raid.bosses or {}) do
            for _, id in ipairs(boss.items or {}) do
                if id == ... then
                    local ref = db:GetBossRef(raid.key .. ":" .. boss.key)
                    ns.Loot:HandleDrop({ s = "TEST-look", b = ref.key, i = { id }, ts = GetServerTime(), test = true },
                        ns.Util.PlayerKey())
                    return
                end
            end
        end end""", DST)
    w.tick(1)
    res = c.eval_py("""local b = ns.DropPanel.blocks[1]
        local k = b.przGlow
        return { glow = k ~= nil and k.tint:IsShown() and k.run:IsShown() or false, item = b.itemID }""")
    assert res["item"] == DST and res["glow"], res
    # the light runs: after a moment it is somewhere along the top edge
    w.tick(1)
    a = c.eval("return ns.DropPanel.blocks[1].przGlow.core:GetAlpha()")
    assert a is not None
    # the same card for a plain item: the glow goes
    c.eval("local b = ns.DropPanel.blocks[1]; ns.DropPanel.PrzGlow(b, false)")
    assert c.eval("return ns.DropPanel.blocks[1].przGlow.tint:IsShown()") is False



@case
def demo_a_roll_rolls_a_prized_item_i_qualify_for():
    w, c = solo("Alice", guild_rank=0, tick=4)
    c.eval("ns.SettingsUI:DemoRoll()")
    w.tick(2)
    res = c.eval_py("""local out = {}
        for i, b in ipairs(ns.DropPanel.blocks or {}) do
            if b:IsShown() and b.itemID then
                out[#out + 1] = { item = b.itemID, prized = ns.Prized:ForItem(b.itemID) ~= nil,
                                  glow = b.przGlow ~= nil and b.przGlow.tint:IsShown() or false,
                                  rolling = b.rollSession ~= nil }
            end
        end
        return out""")
    rows = list(res.values()) if isinstance(res, dict) else list(res or [])
    prized = [r for r in rows if r["prized"]]
    assert prized and all(r["glow"] for r in prized), rows
    assert rows[0]["rolling"] and rows[0]["prized"], rows              # the demo rolls the prized item, first
    # in demo mode I meet its rules: the roll window, not the notice
    assert c.eval("return ns.RollFrame.frame ~= nil and ns.RollFrame.frame:IsShown() or false")
    assert c.eval("return ns.RollFrame.przBlocked") is False
    assert "meet all" in (c.eval("return ns.RollFrame.frame.wearLabel:GetText()") or "")


NOT_OK = ("ns.Prized.Check = function() return { ok = false, fail = '62% attendance, needs 75%', failKey = 'att', "
          "by = { att = { free = nil } }, rules = {}, met = 0, required = 4 } end")


def roll_dst(c, w):
    c.eval("""local db = ns.ItemDB
        for _, raid in ipairs(db:GetRaids()) do for _, boss in ipairs(raid.bosses or {}) do
            for _, id in ipairs(boss.items or {}) do if id == ... then
                local ref = db:GetBossRef(raid.key .. ":" .. boss.key)
                ns.Loot:HandleDrop({ s = "TEST-q" .. GetTime(), b = ref.key, i = { id }, ts = GetServerTime(), test = true },
                    ns.Util.PlayerKey())
                return end end end end""", DST)
    w.tick(1)
    c.eval("ns.RollFrame:Hide(); ns.DropPanel:StartRoll(...)", DST)
    w.tick(1)


def notices(c):
    res = c.eval_py("local out = {}; for i, it in ipairs(ns.Notify:List({ kind = 'lootNotEligible' })) do "
                    "out[i] = { title = it.title, text = it.text } end; return out")
    return list(res.values()) if isinstance(res, dict) else list(res or [])


def roll_window(c):
    return c.eval("return ns.RollFrame.frame ~= nil and ns.RollFrame.frame:IsShown() or false")


@case
def not_qualified_gets_a_notice_instead_of_the_roll_window():
    w, c = solo("Alice", guild_rank=0, tick=4)
    demo(c, w)
    c.eval(NOT_OK)
    roll_dst(c, w)
    assert not roll_window(c)
    n = notices(c)
    assert n and "being rolled" in n[0]["title"] and "62% attendance" in n[0]["text"], n


@case
def the_gm_can_show_the_roll_window_anyway():
    w, c = solo("Alice", guild_rank=0, tick=4)
    demo(c, w)
    c.eval(NOT_OK)
    rules = c.eval_py("return ns.Guild:GetLootRules()")
    assert rules["q"] == "h", rules
    rules["q"] = "s"
    assert c.eval_py("return (ns.Guild:SetLootRules(...))", rules) is True
    roll_dst(c, w)
    assert roll_window(c)
    assert c.eval("return ns.RollFrame.przBlocked") is True    # (Roll greyed out, as before)
    assert not notices(c)


@case
def qualified_or_unknown_still_get_the_roll_window():
    w, c = solo("Alice", guild_rank=0, tick=4)
    demo(c, w)
    c.eval("ns.Prized.Check = function() return { ok = nil, rules = {}, met = 2, required = 4, by = {} } end")
    roll_dst(c, w)
    assert roll_window(c) and not notices(c)


@case
def in_demo_mode_i_meet_every_prized_rule_others_dont():
    w, c = solo("Alice", guild_rank=0, tick=4)
    demo(c, w)
    res = c.eval_py("""local out = {}
        for _, rec in ipairs(ns.Prized:GetItems()) do
            local me = ns.Prized:Check(rec, ns.Util.PlayerKey())
            out[#out + 1] = { ok = me.ok, met = me.met, required = me.required }
        end
        return out""")
    rows = list(res.values()) if isinstance(res, dict) else list(res or [])
    assert rows and all(r["ok"] is True and r["met"] == r["required"] for r in rows), rows
    c.slash("/dz demo off")
    w.tick(1)
    assert c.eval("return ns.Prized:IsPrized(28830)") is False   # (the demo's items are gone with it)


@case
def award_is_greyed_until_allowed_and_an_override_needs_a_reason():
    w, c = solo("Alice", guild_rank=0, tick=4)
    demo(c, w)
    assert c.eval_py("local ok, e = ns.Demo:RunScenario('prized'); return { ok = ok, e = e }")["ok"] is True
    w.tick(9, 0.5)
    c.eval("local a = ns.Roll:GetActive(); ns.Roll:End(a.id)")
    w.tick(1)
    c.eval("ns.DropPanel:Render()")
    st = c.eval_py("""local b = ns.DropPanel.blocks[1]
        local g = b.awardRoll.przGate
        local lit = 0
        for _, t in ipairs(b.awardRoll.przPips or {}) do if t:IsShown() then lit = lit + 1 end end
        return { shown = b.awardRoll:IsShown(), ok = g and g.ok, need = g and g.need, votes = g and g.votes,
                 pips = lit, who = b.suggested and b.suggested.key }""")
    assert st["shown"] and st["ok"] is False and st["pips"] == st["need"] and st["votes"] < st["need"], st
    tip = c.eval("return ns.DropPanel:AwardSuggestedTooltip(ns.DropPanel.blocks[1])")
    assert tip.startswith("Not yet:") and "votes" in tip, tip
    # the click asks why (an empty reason is refused), then awards
    c.click(c.eval("return ns.DropPanel.blocks[1].awardRoll"))
    w.tick(0.3)
    for p in ("DISASTERZONE_CONFIRM_AWARD",):
        if p in c.popups():
            c.accept_popup(p)
            w.tick(0.3)
    assert "DISASTERZONE_PRIZED_OVERRIDE" in c.popups(), c.popups()
    assert "council votes it needs" in c.popup_text("DISASTERZONE_PRIZED_OVERRIDE")
    sid = c.eval("return ns.DropPanel.blocks[1].rollSession.id")
    c.eval("ns.Popup:HideAll()")
    c.eval("ns.Roll:Award(...)", sid, st["who"])          # (no reason: asks again, awards nothing)
    w.tick(0.3)
    assert c.eval("return ns.Roll:Get(...).state", sid) != "awarded"
    c.eval("ns.Popup:HideAll()")
    c.eval("local id, k = ...; ns.Roll:Award(id, k, 'bis', 'Only Grimtusk raids every week')", sid, st["who"])
    w.tick(1)
    for p in ("DISASTERZONE_CONFIRM_AWARD", "DISASTERZONE_GIVE_ITEM"):
        if p in c.popups():
            c.accept_popup(p)
            w.tick(0.5)
    assert c.eval("return ns.Roll:Get(...).state", sid) == "awarded"

def tip_lines(c):
    return c.eval_py("""local out = {}
        for i = 1, GameTooltip:NumLines() do local fs = _G['GameTooltipTextLeft' .. i]; out[i] = fs and fs:GetText() end
        return out""")


@case
def qualify_today_names_a_line_only_when_there_is_an_order():
    # (2026-10-11, the user: "First: Amaria, Dyrma..." read as an order but was only alphabetical)
    w, c = solo("Alice", guild_rank=0, tick=4)
    demo(c, w)
    c.eval("ns.MainFrame:Open('council'); ns.CouncilUI:SetView('rules'); ns.CouncilRulesUI:Select(...)",
           c.eval("return ns.Prized:ForItem(...).id", DST))
    w.tick(1)
    count = visible_texts(c, " raiders")
    assert count, "the Qualify today count should show"
    assert not visible_texts(c, "First: ")
    # DST has a priority rule (the spec order): the line names who is next
    assert visible_texts(c, "Next in line: ")
    # hovering the count lists every qualifier, numbered
    c.eval("local r = ...; local h = r:GetParent().qualHit; __MOCK.call_script(h, 'OnEnter')", count[0])
    lines = tip_lines(c)
    lines = list(lines.values()) if isinstance(lines, dict) else list(lines or [])
    assert lines and lines[0].startswith("Qualify") and len(lines) > 1 and lines[1].startswith("1. "), lines
    c.eval("GameTooltip:Hide()")
    # no priority rules: everyone ties, so no names line (the icons + count stay; names are on hover)
    c.eval("""local rec = ns.Prized:ForItem(...)
        for k, v in pairs(rec.r) do if k ~= 'vote' and (v.m or 'r') == 'p' then rec.r[k] = nil end end
        ns.PrizedUI:Refresh()""", DST)
    w.tick(1)
    assert visible_texts(c, " raiders")
    assert not visible_texts(c, "Next in line: ") and not visible_texts(c, "First: ")
    c.eval("local r = ...; local h = r:GetParent().qualHit; __MOCK.call_script(h, 'OnEnter')", visible_texts(c, " raiders")[0])
    lines = tip_lines(c)
    lines = list(lines.values()) if isinstance(lines, dict) else list(lines or [])
    assert lines and lines[0] == "Qualify today" and not lines[1].startswith("1. "), lines


@case
def the_prized_banner_says_my_standing_in_words():
    # (fix 1.4: the banner's pill is standing()'s long text, as in 1.3.5 and on the Loot rules page; the list's row
    # keeps the short words)
    w, c = solo("Alice", guild_rank=0, tick=4)
    demo(c, w)
    c.eval("ns.MainFrame:Open('council'); ns.CouncilUI:SetView('rules'); ns.CouncilRulesUI:Select(...)",
           c.eval("return ns.Prized:ForItem(...).id", DST))
    w.tick(1)
    st = c.eval_py("local s, k, l = ns.PrizedUI:Standing(ns.Prized:ForItem(...)); return { s, k, l }", DST)
    assert st and st[2] and st[0] != st[2], st
    assert visible_texts(c, st[2]), st
    # editing the rules: the pill says so instead
    c.eval("ns.PrizedUI:StartEdit()")
    w.tick(0.5)
    assert visible_texts(c, "Editing the rules") and not visible_texts(c, st[2]), st
    c.eval("ns.PrizedUI:CancelEdit()")
    w.tick(0.5)
    assert visible_texts(c, st[2]), st
    w.assert_no_errors()


if __name__ == "__main__":
    run_all(globals())

"""Refactor 1.4, phase 2: the shared controls of UI/Comp/Controls.lua.

UI:CreatePill (THE pill: every look of UI.PILL_LOOK = UI.TAG_LOOK plus the event kinds; the old aliases
UI:CreateTagPill / EUI:CreatePill / EUI:CreateChip / EUI:CreateSegments are gone, their call shapes stay),
UI:CreateChip (the events' chip looks, plus opts / click / selected), UI:CreateSegments (a row of choices; the
(parent, w, h, look) shape is the route-steps bar) and UI:CreateRailNav (the side menu of Settings / Notifications).

Run: luaenv\\Scripts\\python.exe tests\\style\\test_components_controls.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors  # noqa: E402


def near(a, b, eps=1e-4):
    return len(a) >= len(b) and all(abs(x - y) < eps for x, y in zip(a, b))


# ------------------------------------------------------------------------------------------------------------------
# Pills
# ------------------------------------------------------------------------------------------------------------------
@case
def the_pill_looks_are_one_table_with_the_event_looks_in_it():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local L = UI.PILL_LOOK
        local names = {}
        for k in pairs(L) do names[#names + 1] = k end
        table.sort(names)
        return { same = UI.TAG_LOOK == L, names = names, live = L.live.text, rank = L.rank.text,
                 bis = L.bis.text, gold = ns.Style.C.GOLD }""")
    assert out["same"] is True, out
    assert out["names"] == ["alt", "bad", "bis", "live", "mute", "ok", "os", "rank", "warn"], out   # (1.4 cleanup: "bad" for a worse number)
    assert near(out["live"], [1, 0.77, 0.72]) and near(out["rank"], [1, 0.88, 0.54]), out
    assert near(out["bis"], out["gold"][:3]), out
    no_errors(w)


@case
def create_pill_takes_a_kind_and_text_and_sizes_itself():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local p = UI:CreatePill(UIParent, "bis", "BiS")
        local res = { text = p.fs:GetText(), col = { p.fs:GetTextColor() }, h = p:GetHeight(), w = p:GetWidth(),
                      icon = p.icon:IsShown() }
        -- an event kind: rank wears its own look and the star (top-left quarter of the texture)
        local r = UI:CreatePill(UIParent, "rank", "Ranked", 18)
        res.rankH = r:GetHeight()
        res.rankIcon = r.icon:IsShown()
        res.rankTex = r.icon:GetTexture()
        res.rankCol = { r.fs:GetTextColor() }
        -- review / draft wear warn / mute
        local v = UI:CreatePill(UIParent, "review", "In review")
        res.reviewCol = { v.fs:GetTextColor() }
        local d = UI:CreatePill(UIParent, "draft", "Draft")
        res.draftCol = { d.fs:GetTextColor() }
        -- an unknown kind reads mute; no kind = an empty pill to set later
        local u = UI:CreatePill(UIParent, "nonsense", "X")
        res.unknownCol = { u.fs:GetTextColor() }
        local e = UI:CreatePill(UIParent)
        res.emptyText = e.fs:GetText()
        e:SetPill("ok", "Done")
        res.setPill = { e.fs:GetText(), e.fs:GetTextColor() }
        res.wider = UI:CreatePill(UIParent, "ok", "A much longer label"):GetWidth() > p:GetWidth()
        return res""")
    assert out["text"] == "BiS" and near(out["col"], [1, 0.82, 0]), out
    assert out["h"] == 16 and out["w"] > 14 and out["icon"] is False, out
    assert out["rankH"] == 18 and out["rankIcon"] is True and "ReputationStar" in str(out["rankTex"]), out
    assert near(out["rankCol"], [1, 0.88, 0.54]), out
    assert near(out["reviewCol"], [1, 0.69, 0.40]) and near(out["draftCol"], [0.72, 0.72, 0.72]), out
    assert near(out["unknownCol"], [0.72, 0.72, 0.72]), out
    assert out.get("emptyText") in (None, ""), out
    assert out["setPill"][0] == "Done" and near(out["setPill"][1:], [0.62, 0.94, 0.69]), out
    assert out["wider"] is True, out
    no_errors(w)


@case
def the_pill_keeps_the_old_call_shapes():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI, EUI = ns.UI, ns.EventUI
        -- UI:CreatePill(parent, h) + p:Set(text, look, icon) + p:SetBase(r, g, b)
        local t = UI:CreatePill(UIParent, 13)
        t:SetBase(0, 0, 0)
        t:Set("Alt P2", "alt")
        local res = { tagH = t:GetHeight(), tagText = t.fs:GetText(), tagCol = { t.fs:GetTextColor() } }
        t:Set("With icon", "os", "Interface\\\\Icons\\\\INV_Misc_QuestionMark")
        res.tagIcon = t.icon:IsShown()
        res.tagDefault = UI:CreatePill(UIParent):GetHeight()
        -- UI:CreatePill(parent, h) + p:SetKind(text, kind) (the events' call)
        local e = UI:CreatePill(UIParent, 17)
        e:SetKind("Live", "live")
        res.eH = e:GetHeight()
        res.eText = e.fs:GetText()
        res.eCol = { e.fs:GetTextColor() }
        e:SetKind("Back", "back")
        res.backCol = { e.fs:GetTextColor() }
        -- a kind the event pill never knew (bis) reads mute there, as before
        e:SetKind("BiS", "bis")
        res.bisCol = { e.fs:GetTextColor() }
        e:SetKind("Ranked", "rank")
        res.rankIcon = e.icon:IsShown()
        res.eDefault = UI:CreatePill(UIParent):GetHeight()
        res.aliasesGone = UI.CreateTagPill == nil and EUI.CreatePill == nil and EUI.CreateSegments == nil
            and EUI.CreateChip == nil
        return res""")
    assert out["tagH"] == 13 and out["tagText"] == "Alt P2" and near(out["tagCol"], [0.56, 0.78, 1]), out
    assert out["tagIcon"] is True and out["tagDefault"] == 16, out
    assert out["eH"] == 17 and out["eText"] == "Live" and near(out["eCol"], [1, 0.77, 0.72]), out
    assert near(out["backCol"], [1, 0.69, 0.40]), out
    assert near(out["bisCol"], [0.72, 0.72, 0.72]), out
    assert out["rankIcon"] is True and out["eDefault"] == 16, out
    assert out["aliasesGone"] is True, out
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# Chips
# ------------------------------------------------------------------------------------------------------------------
@case
def chips_keep_the_event_looks_and_take_options():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI, EUI = ns.UI, ns.EventUI
        local tr = UI:CreateChip(UIParent, "track")
        tr:Set("Hogger", { 1, 0, 0 })
        local res = { trH = tr:GetHeight(), trText = tr.fs:GetText(), dot = tr.dot:IsShown(), cls = tr.cls:IsShown(),
                      trCol = { tr.fs:GetTextColor() }, trW = tr:GetWidth() }
        local you = UI:CreateChip(UIParent, "you")
        you:Set("Rai", nil, "PALADIN")
        res.youH = you:GetHeight()
        res.youCls = you.cls:IsShown()
        res.youDot = you.dot:IsShown()
        res.youCol = { you.fs:GetTextColor() }
        res.plainH = UI:CreateChip(UIParent):GetHeight()
        -- opts: text + icon, a click handler (a Button), selected = gold text
        T_clicks = 0
        local ch = UI:CreateChip(UIParent, { text = "Fire", icon = "Interface\\\\Icons\\\\Spell_Fire_Fire",
            onClick = function(self, btn) T_clicks = T_clicks + 1; T_btn = btn end })
        res.isButton = ch:GetObjectType() == "Button"
        res.chText = ch.fs:GetText()
        res.chIcon = ch.icon:IsShown()
        ch:Click()
        res.clicks = T_clicks
        ch:SetSelected(true)
        res.selCol = { ch.fs:GetTextColor() }
        res.isSel = ch:IsSelected()
        ch:SetSelected(false)
        res.offCol = { ch.fs:GetTextColor() }
        return res""")
    assert out["trH"] == 18 and out["trText"] == "Hogger" and out["dot"] is True and out["cls"] is False, out
    assert near(out["trCol"], [0.94, 0.94, 0.94]) and out["trW"] > 20, out
    assert out["youH"] == 22 and out["youCls"] is True and out["youDot"] is False, out
    assert near(out["youCol"], [0.84, 0.93, 1]), out
    assert out["plainH"] == 18, out
    assert out["isButton"] is True and out["chText"] == "Fire" and out["chIcon"] is True, out
    assert out["clicks"] == 1, out
    assert near(out["selCol"], [1, 0.82, 0]) and out["isSel"] is True, out
    assert near(out["offCol"], [0.94, 0.94, 0.94]), out
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# Segments
# ------------------------------------------------------------------------------------------------------------------
@case
def segments_pick_one_and_report_changes():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        T_log = {}
        local seg = UI:CreateSegments(UIParent, { { "dmg", "Damage" }, { key = "heal", label = "Healing" },
            { value = "taken", text = "Taken" } }, function(key, i) T_log[#T_log + 1] = key .. i end,
            { selected = "dmg" })
        local res = { sel = { seg:GetSelected() }, n = #seg.buttons, label2 = seg.buttons[2].label:GetText(),
                      h = seg:GetHeight() }
        seg.buttons[2]:Click()
        res.afterClick = { seg:GetSelected() }
        res.log = table.concat(T_log, ",")
        seg:Select("taken")                       -- no callback
        res.afterSelect = { seg:GetSelected() }
        res.log2 = table.concat(T_log, ",")
        seg:Select(1, true)                       -- by index, firing
        res.log3 = table.concat(T_log, ",")
        -- the picked label is white, the others grey
        res.onCol = { seg.buttons[1].label:GetTextColor() }
        res.offCol = { seg.buttons[2].label:GetTextColor() }
        -- a handler that returns false keeps the old pick
        local keep = UI:CreateSegments(UIParent, { "A", "B" }, function() return false end, { selected = 1 })
        keep.buttons[2]:Click()
        res.kept = { keep:GetSelected() }
        -- read-only: clicks do nothing
        local ro = UI:CreateSegments(UIParent, { "A", "B" }, function() T_ro = true end,
            { selected = 1, readOnly = true })
        ro:Click(2)
        res.ro = { ro:GetSelected() }
        res.roFired = T_ro == true
        -- equal widths of opts.width, pill look
        local eq = UI:CreateSegments(UIParent, { "x", "yy", "zzzzzz" }, nil, { width = 120, look = "pill", h = 20 })
        res.eqW = eq:GetWidth()
        res.eqWidths = { eq.buttons[1]:GetWidth(), eq.buttons[2]:GetWidth(), eq.buttons[3]:GetWidth() }
        res.noneSel = eq:GetSelected() == nil
        -- the old names: My Log's SetSelected, the builder's Set
        eq:SetSelected(2)
        res.viaSetSelected = { eq:GetSelected() }
        eq:Set(3)
        res.viaSet = { eq:GetSelected() }
        -- disabled items and new items keep the pick by key
        seg:SetItemEnabled("heal", false)
        seg.buttons[2]:Click()
        res.disabledIgnored = { seg:GetSelected() }
        seg:SetItems({ { "heal", "Healing" }, { "dmg", "Damage" } })
        res.keyKept = { seg:GetSelected() }
        return res""")
    assert out["sel"] == ["dmg", 1] and out["n"] == 3 and out["label2"] == "Healing" and out["h"] == 22, out
    assert out["afterClick"] == ["heal", 2] and out["log"] == "heal2", out
    assert out["afterSelect"] == ["taken", 3] and out["log2"] == "heal2", out
    assert out["log3"] == "heal2,dmg1", out
    assert near(out["onCol"], [1, 1, 1]) and near(out["offCol"], [0.66, 0.66, 0.70]), out
    assert out["kept"] == ["A", 1] or out["kept"] == [1, 1], out
    assert out["ro"][1] == 1 and out["roFired"] is False, out
    assert out["eqW"] == 120 and sum(out["eqWidths"]) == 116, out
    assert out["noneSel"] is True, out
    assert out["viaSetSelected"][1] == 2 and out["viaSet"][1] == 3, out
    assert out["disabledIgnored"] == ["dmg", 1], out
    assert out["keyKept"] == ["dmg", 2], out
    no_errors(w)


@case
def the_old_segments_shape_is_the_route_steps_bar():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI, EUI = ns.UI, ns.EventUI
        local s = UI:CreateSegments(UIParent, 128, 6, "board")
        s:Set(5, 2)
        local res = { w = s:GetWidth(), h = s:GetHeight(), look = s.look, n = #s.segs }
        local shown = 0
        for _, g in ipairs(s.segs) do if g.bg:IsShown() then shown = shown + 1 end end
        res.shown = shown
        res.nextEdge = s.segs[3].edge[1]:IsShown()
        res.doneEdge = s.segs[1].edge[1]:IsShown()
        s:Set(2, 2)
        shown = 0
        for _, g in ipairs(s.segs) do if g.bg:IsShown() then shown = shown + 1 end end
        res.shrunk = shown
        local t = UI:CreateSegments(UIParent, 200, 5, "track")
        t:Set(3, 1, true)
        res.trackShade = t.segs[1].shade:IsShown()
        res.trackLook = t.look
        return res""")
    assert out["w"] == 128 and out["h"] == 6 and out["look"] == "board" and out["n"] == 5, out
    assert out["shown"] == 5 and out["nextEdge"] is True and out["doneEdge"] is False, out
    assert out["shrunk"] == 2, out
    assert out["trackShade"] is True and out["trackLook"] == "track", out
    no_errors(w)


# ------------------------------------------------------------------------------------------------------------------
# Rail nav
# ------------------------------------------------------------------------------------------------------------------
@case
def the_rail_nav_opens_one_item_and_shows_counts():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        T_sel = {}
        local holder = CreateFrame("Frame", nil, UIParent)
        holder:SetSize(170, 300)
        local rail = UI:CreateRailNav(holder, {
            { key = "needs", label = "Needs you", icon = "Interface\\\\Icons\\\\INV_Misc_Bell", gold = true },
            { key = "all", label = "Everything" },
            { sep = true },
            { header = "Old" },
            { key = "done", label = "Handled", tip = "What you answered" },
        }, function(key) T_sel[#T_sel + 1] = key end, { selected = "needs", rowH = 26 })
        rail:SetPoint("TOPLEFT")
        rail:SetPoint("BOTTOMRIGHT")
        local res = { h = rail:GetContentHeight(), n = 0 }
        for _, b in ipairs(rail.buttons) do if b:IsShown() then res.n = res.n + 1 end end
        local needs, all = rail.byKey.needs, rail.byKey.all
        res.sel = rail:GetSelected()
        res.needsBar = needs.bar:IsShown()
        res.needsCol = { needs.text:GetTextColor() }
        res.allBar = all.bar:IsShown()
        res.allCol = { all.text:GetTextColor() }
        res.iconShown = needs.icon:IsShown()
        res.allIcon = all.icon:IsShown()
        all:Click()
        res.afterClick = rail:GetSelected()
        res.log = table.concat(T_sel, ",")
        res.allBar2 = all.bar:IsShown()
        res.needsBar2 = needs.bar:IsShown()
        rail:Select("done")
        res.log2 = table.concat(T_sel, ",")
        rail:SetCount("needs", 3)
        res.count = needs.count:GetText()
        res.countCol = { needs.count:GetTextColor() }
        rail:SetCount("all", 0)
        res.zero = all.count:GetText()
        rail:SetLabel("all", "All of it")
        res.label = all.text:GetText()
        res.header = rail.seps[2].text:GetText()
        return res""")
    assert out["n"] == 3 and out["h"] == 26 * 3 + 13 + 22, out
    assert out["sel"] == "needs" and out["needsBar"] is True and near(out["needsCol"], [1, 0.82, 0]), out
    assert out["allBar"] is False and near(out["allCol"], [0.78, 0.78, 0.78]), out
    assert out["iconShown"] is True and out["allIcon"] is False, out
    assert out["afterClick"] == "all" and out["log"] == "all", out
    assert out["allBar2"] is True and out["needsBar2"] is False, out
    assert out["log2"] == "all", out
    assert out["count"] == "3" and near(out["countCol"], [1, 0.86, 0.62]), out
    assert out.get("zero") in ("", None), out
    assert out["label"] == "All of it" and out["header"] == "OLD", out
    no_errors(w)


if __name__ == "__main__":
    run_all()

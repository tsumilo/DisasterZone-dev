"""Refactor 1.4 cleanup: the needs the migration left as local TODO(refactor) copies, now in the shared components.

ns.Style (S:Alpha / WithAlpha / RGB / Hex of a table), Widgets (UI:SetTextSize, UI:ClassOf, UI:Tween, UI:SetGlyph,
UI:CreateDot, UI:GradientRGBA, UI:SetEdges, UI:IconText crop), Surfaces (UI:CreateFace, DecorateRow's "you" look,
UI:CreateCard onClick, two pictures in an art row), Controls (UI:CreateProgressBar, UI:CreateStepper, UI:CreateKeyCap,
UI:CreateStar, the "bad" pill, the chip looks and kept icon coords), PageParts (UI:CreateTextLink, the forward back
link, ASCII-only caps, the banner's title steps / any pill kind / icon options / second icon / tools text / chevron
tools / kicker tooltip / right shade) and Layouts (a hidden tabs strip gives its room back, unused separators hide,
the primary's glyph beside its words, NewSeparator).

Run: luaenv\\Scripts\\python.exe tests\\style\\test_components_cleanup.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors  # noqa: E402


def near(a, b, eps=1e-4):
    return len(a) >= len(b) and all(abs(x - y) < eps for x, y in zip(a, b))


@case
def style_and_widget_helpers():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local S, UI = ns.Style, ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        local res = { alpha = { S:Alpha("GOLD", 0.5) }, own = { S:Alpha("EDGE") }, rgb = { S:RGB("CARD") },
                      with = S:WithAlpha("SUB", 0.3), hex = S:Hex({ 1, 0.82, 0 }), hexName = S:Hex("GOLD") }
        res.fresh = S:WithAlpha("GOLD") ~= S.C.GOLD
        -- a size step that keeps the colour (SetTextStyle would set the style's)
        local fs = UI:Text(f, "body", "GOLD")
        UI:SetTextSize(fs, 12.5)
        local _, size = fs:GetFont()
        res.size, res.col = size, { fs:GetTextColor() }
        -- the class: known, else the guild's
        res.known = UI:ClassOf("Nobody-Thunderstrike", "MAGE")
        res.none = UI:ClassOf("Nobody-Thunderstrike") == nil
        -- one eased driver: a new tween on a key finishes the old one
        local seen = {}
        UI:Tween("k", 1, function(e) seen[#seen + 1] = e end)
        UI:Tween("k", 1, function(e) seen[#seen + 1] = -e end, true)
        res.tween = seen
        -- a glyph by name, a dot, an inline icon with its border cut
        local t = f:CreateTexture()
        UI:SetGlyph(t, "plus", "GOLD")
        res.glyph = { __MOCK.S(t).texture == UI.ICON_ATLAS, { t:GetVertexColor() } }
        local d = UI:CreateDot(f, 6, "YOU", { alpha = 0.5, hidden = true })
        res.dot = { d:IsShown(), d:GetWidth(), { d:GetVertexColor() } }
        res.icon = UI:IconText("x", 12, true)
        res.plain = UI:IconText("x", 12)
        local e = CreateFrame("Frame", nil, f)
        UI:SetEdges(e, 1, 0, 0, 1)
        res.edges = e.edges ~= nil
        return res""")
    assert near(out["alpha"], [1, 0.82, 0, 0.5]) and near(out["own"], [0.34, 0.34, 0.38, 0.55]), out
    assert len(out["rgb"]) == 3 and near(out["with"], [0.62, 0.62, 0.62, 0.3]), out
    assert out["hex"] == out["hexName"] == "|cffffd100" and out["fresh"] is True, out
    assert out["size"] == 12 and near(out["col"], [1, 0.82, 0]), out           # (12.5 snaps to 12, the gold stays)
    assert out["known"] == "MAGE" and out["none"] is True, out
    assert out["tween"] == [0, 1, -1], out                                      # (the old one finished, the new one jumped)
    assert out["glyph"][0] is True and near(out["glyph"][1], [1, 0.82, 0]), out
    assert out["dot"][0] is False and out["dot"][1] == 6 and near(out["dot"][2], [0.4, 0.72, 1, 0.5]), out
    assert out["icon"] == "|Tx:12:12:0:0:64:64:5:59:5:59|t" and out["plain"] == "|Tx:12:12|t", out
    assert out["edges"] is True, out
    no_errors(w)


@case
def face_you_row_clickable_card_and_two_pictures():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(400, 300)
        local face = UI:CreateFace(f, 30, { glyph = "plus" })
        local res = { face = { face:GetWidth(), face.ring:GetWidth(), face.icon:IsShown() } }
        face:SetPhoto(134400)
        res.photo = { face.photo:IsShown(), face.icon:IsShown() }
        local r = CreateFrame("Frame", nil, f)
        UI:DecorateRow(r, { you = true, hover = false })
        res.you0 = r.dzYouFill:IsShown()
        r:SetYou(true)
        res.you1 = { r.dzYouFill:IsShown(), r.dzYouBar:IsShown(), r.dzYouBar:GetWidth() }
        local clicks = {}
        local card = UI:CreateCard(f, { onClick = function(self, b) clicks[#clicks + 1] = b end })
        res.card = { card:GetObjectType(), card.dzHover ~= nil }
        card:Click("LeftButton")
        res.clicks = clicks
        local row = UI:CreateArtRow(f, {})
        row:SetWidth(380)
        row:SetData({ art = { 134400, 0, 1, 0, 1 }, art2 = { 134400, 0, 1, 0, 1 }, title = "Mag + Gruul" })
        res.two = { row.art.art2 ~= nil and row.art.art2:IsShown(), row.art.tex:GetWidth() }
        row:SetData({ art = { 134400, 0, 1, 0, 1 }, title = "Kara" })
        res.one = row.art.art2:IsShown()
        return res""")
    assert out["face"] == [30, 34, True] and out["photo"] == [True, False], out
    assert out["you0"] is False and out["you1"] == [True, True, 2], out
    assert out["card"] == ["Button", True] and out["clicks"] == ["LeftButton"], out
    assert out["two"] == [True, 32] and out["one"] is False, out
    no_errors(w)


@case
def progress_bar_stepper_key_cap_star_and_chip_looks():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        local bar = UI:CreateProgressBar(f, { width = 200, height = 3 })
        bar:Set(0.25, "OK")
        local res = { bar = { bar.fill:GetWidth(), bar.fill:IsShown(), __MOCK.S(bar.fill).color } }
        bar:Set(0)
        res.empty = bar.fill:IsShown()
        local steps = {}
        local st = UI:CreateStepper(f, 120, function(d) steps[#steps + 1] = d end, { tip = "Pick" })
        st:Set("Today", false, true)
        st.next:Click()
        st.prev:Click()
        res.step = { st.text:GetText(), st.prev:IsEnabled() and true or false, steps }
        local cap = UI:CreateKeyCap(f, 30, 18)
        cap.key:SetText("2")
        local star = UI:CreateStar(f, 16)
        star:SetLit(false)
        res.cap = { cap:GetWidth(), cap.key:GetText(), star:GetWidth() }
        local chip = UI:CreateChip(f, { kind = "you" })
        chip:SetIcon(UI.ICON_ATLAS, UI:IconCoords(UI.ICON.gear), "GOLD")
        chip:Set("Settings")
        chip:Set("Settings again")
        res.chip = { chip.icon:IsShown(), { chip.icon:GetVertexColor() } }
        chip:SetLook("live")
        res.live = chip.look == UI.CHIP_LOOK.live and UI.CHIP_LOOK.bad ~= nil and UI.PILL_LOOK.bad ~= nil
        return res""")
    assert out["bar"][0] == 50 and out["bar"][1] is True and near(out["bar"][2], [0.3, 0.9, 0.4]), out
    assert out["empty"] is False, out
    assert out["step"][0] == "Today" and out["step"][1] is False and out["step"][2] == [1], out   # (prev is off)
    assert out["cap"] == [30, "2", 16], out
    assert out["chip"][0] is True and near(out["chip"][1], [1, 0.82, 0]), out
    assert out["live"] is True, out
    no_errors(w)


@case
def text_link_back_link_and_caps():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        local n = 0
        local l = UI:CreateTextLink(f, "Show me", function() n = n + 1 end, { color = "GOLD", hover = "TEXT", chevron = "right" })
        local res = { label = l.fs:GetText(), chev = l.chev ~= nil, col = { l.fs:GetTextColor() } }
        l:GetScript("OnEnter")(l)
        res.hover = { l.fs:GetTextColor() }
        l:GetScript("OnLeave")(l)
        l:Click()
        res.clicks = n
        local w1 = l:GetWidth()
        l:SetLabel("Show me everything")
        res.wider = l:GetWidth() > w1
        local back = UI:CreateBackLink(f, "Recent runs", nil, { forward = true })
        res.fwd = { select(1, back.text:GetPoint(1)), select(1, back.icon:GetPoint(1)), back.text:GetText() }
        res.caps = UI:CapsText("0.1 \\226\\128\\147 0.12 beta")
        return res""")
    assert out["label"] == "Show me" and out["chev"] is True and near(out["col"], [1, 0.82, 0]), out
    assert near(out["hover"], [0.88, 0.88, 0.88]) and out["clicks"] == 1 and out["wider"] is True, out
    assert out["fwd"] == ["LEFT", "LEFT", "RECENT RUNS"], out
    assert out["caps"] == "0.1 – 0.12 BETA", out
    no_errors(w)


@case
def banner_options():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(600, 300)
        local b = UI:CreatePageBanner(f, { size = "hero", width = 600, title = "A title", icon = 134400,
            kickerTip = { "Latency", { "What it is." } }, kicker = "Your latency 80 ms", shadeRight = 120 })
        b:SetWidth(600)
        local res = {}
        b:SetPill("bis", "BiS")
        res.pill = { b.pill.fs:GetText(), { b.pill.fs:GetTextColor() } }
        b:SetTitleFit({ "hero", "page", "title" }, 470)
        b:SetTitle("A very long title that cannot fit beside the blocks at all")
        local _, size = b.title:GetFont()
        res.stepped = size
        b:SetIcon(134400, { glyph = "GOLD", glyphSize = 20 })
        res.glyph = { b.icon.tex:GetWidth(), { b.icon.tex:GetVertexColor() } }
        b:SetIcon(134400)
        res.plain = b.icon.tex:GetWidth()
        b:SetSecondIcon(134400, 1234)
        res.second = { b.icon2:IsShown(), b.icon2.itemID }
        b:SetSecondIcon(nil)
        res.secondGone = b.icon2:IsShown()
        b:SetTools({ { icon = "chevron", chevron = "right", title = "Next" }, { icon = "chevron", chevron = "left", title = "Prev" } })
        b:SetToolsText("3 / 19")
        res.tt = { b.toolsText:GetText(), b.toolsText:IsShown() }
        res.kick = b.kickerHit ~= nil and b.kickerHit:IsShown()
        res.shade = b.shadeR:IsShown() and b.shadeR:GetWidth()
        b:SetArt({ 134400, 0, 1, 0, 1 }, nil, { 134400, 0, 1, 0, 1 })
        res.art2 = b.art2 ~= nil and b.art2:IsShown()
        -- the text set before the tools (the Council member page's first open) shows once they come
        b:SetTools(nil)
        b:SetToolsText("1 / 19")
        res.ttNoTools = b.toolsText:IsShown()
        b:SetTools({ { icon = "chevron", chevron = "right", title = "Next" }, { icon = "chevron", chevron = "left", title = "Prev" } })
        res.ttLate = { b.toolsText:GetText(), b.toolsText:IsShown() }
        return res""")
    assert out["pill"][0] == "BiS" and near(out["pill"][1], [1, 0.82, 0]), out           # (bis no longer reads mute)
    assert out["stepped"] < 19, out
    assert out["glyph"][0] == 20 and near(out["glyph"][1], [1, 0.82, 0]) and out["plain"] != 20, out
    assert out["second"] == [True, 1234] and out["secondGone"] is False, out
    assert out["tt"] == ["3 / 19", True] and out["kick"] is True and out["shade"] == 120, out
    assert out["art2"] is True, out
    assert out["ttNoTools"] is False and out["ttLate"] == ["1 / 19", True], out
    no_errors(w)


@case
def layout_tabs_strip_separators_and_primary_glyph():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local host = CreateFrame("Frame", nil, UIParent)
        host:SetSize(790, 548)
        local L = UI:CreateLayout("listdetail", host, { tabs = { { key = "a", text = "A" }, { key = "b", text = "B" } } })
        local function top(fr) return select(5, fr:GetPoint(1)) end
        local res = { with = top(L.body) }
        L:SetTabsShown(false)
        res.without = top(L.body)
        L:SetTabsShown(true)
        res.back = top(L.body)
        local tb = L.toolbar
        tb:SetTabs({ { key = "x", text = "X" }, { key = "s1", text = "S1", small = true }, { key = "s2", text = "S2", small = true } })
        res.sep1 = tb.tabSeps[1] and tb.tabSeps[1]:IsShown()
        tb:SetTabShown("s1", false)
        tb:SetTabShown("s2", false)
        res.sep0 = tb.tabSeps[1]:IsShown()
        local p = tb:SetPrimary({ text = "New poll", icon = "plus" })
        res.prim = { p:GetText(), p.glyph ~= nil and p.glyph:IsShown() }
        local sep = tb:NewSeparator()
        tb:SetFilters({ sep })
        res.sepW = sep:GetWidth()
        return res""")
    assert out["without"] > out["with"] and out["back"] == out["with"], out   # (the strip's room comes back)
    assert out["sep1"] is True and out["sep0"] is False, out
    assert out["prim"] == ["New poll", True] and out["sepW"] == 1, out
    no_errors(w)


if __name__ == "__main__":
    run_all()

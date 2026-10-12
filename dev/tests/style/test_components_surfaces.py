"""The surfaces of refactor 1.4 phase 2 (UI/Comp/Surfaces.lua, REFACTOR_API.md "Surfaces.lua"): UI:CreateCard (the card /
inset / quiet tones, title and body), UI:DecorateRow (one hover, one selected look: the gold wash + 2 px bar, the
stripe and the hairline), UI:CreateArtRow (the 50 px row with the 64x38 picture and the 20 px icon tile),
UI:CreateEmptyState (My Log's illustrated empty state), UI:CreateNotice (read-only / locked / loading / info) and
scrollList:SetEmptyState (UI/Widgets.lua, next to SetEmptyText, whose behaviour stays as it was).

Run: luaenv\\Scripts\\python.exe tests\\style\\test_components_surfaces.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors  # noqa: E402


def near(a, b, eps=1e-6):
    return a is not None and len(a) == len(b) and all(abs(x - y) < eps for x, y in zip(a, b))


@case
def a_card_paints_its_tone_and_lays_its_body_under_the_title():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(400, 300)
        local function pts(t)
          local out = {}
          for i = 1, t:GetNumPoints() do
            local p, rel, rp, x, y = t:GetPoint(i)
            out[#out + 1] = { p, rp, x, y, rel == t:GetParent() and "parent" or (rel and "other" or "none") }
          end
          return out
        end
        local card = UI:CreateCard(f, { title = "Bosses", width = 200, height = 120 })
        local inset = UI:CreateCard(f, { tone = "inset", pad = 12 })
        local quiet = UI:CreateCard(f, { tone = "quiet" })
        local quietR = UI:CreateCard(f, { tone = "quiet", fade = "right" })
        local caps = UI:CreateCard(f, { title = "Heading", titleStyle = "caps" })
        local res = {
          size = { card:GetWidth(), card:GetHeight() },
          cardBg = __MOCK.S(card.bg).color, cardEdge = __MOCK.S(card.edges[1]).color, nEdges = #card.edges,
          title = card.title:GetText(), titleC = { card.title:GetTextColor() }, titleSize = select(2, card.title:GetFont()),
          titlePts = pts(card.title), bodyWithTitle = pts(card.body),
          insetBg = __MOCK.S(inset.bg).color, insetEdge = __MOCK.S(inset.edges[1]).color, insetBody = pts(inset.body),
          quietGrad = __MOCK.S(quiet.bg).gradient, quietTex = __MOCK.S(quiet.bg).texture,
          quietEdgeA = __MOCK.S(quiet.edges[1]).color[4], quietRGrad = __MOCK.S(quietR.bg).gradient,
          caps = caps.title:GetText(), tone = { card.tone, inset.tone, quiet.tone },
        }
        quiet:SetHovered(true)
        res.quietHover = __MOCK.S(quiet.bg).gradient
        card:SetTitle(nil)
        res.titleGone = card.title:IsShown()
        res.bodyNoTitle = pts(card.body)
        card:SetTone("inset")
        res.retoned = { card.tone, __MOCK.S(card.bg).color }
        card:SetTone("nope")
        res.unknown = card.tone
        return res""")
    assert out["size"] == [200, 120], out["size"]
    assert near(out["cardBg"], [0.10, 0.10, 0.12, 0.92]) and near(out["cardEdge"], [0.34, 0.34, 0.38, 0.55]), out
    assert out["nEdges"] == 4, out
    assert out["title"] == "Bosses" and near(out["titleC"][:3], [1, 0.82, 0]) and out["titleSize"] == 13, out
    assert out["titlePts"][0][:4] == ["TOPLEFT", "TOPLEFT", 8, -8], out["titlePts"]
    assert out["bodyWithTitle"][0][:4] == ["TOPLEFT", "BOTTOMLEFT", 0, -6] and out["bodyWithTitle"][0][4] == "other", out
    assert out["bodyWithTitle"][1][:4] == ["BOTTOMRIGHT", "BOTTOMRIGHT", -8, 8], out
    assert near(out["insetBg"], [0.06, 0.06, 0.07, 1]) and near(out["insetEdge"], [0.34, 0.34, 0.38, 0.45]), out
    assert out["insetBody"][0][:4] == ["TOPLEFT", "TOPLEFT", 12, -12], out["insetBody"]
    # the quiet lift: KitView's / the paper doll's fading grey-blue, strong on the left by default, no edge
    g = out["quietGrad"]
    assert out["quietTex"] == "Color" and g[0] == "HORIZONTAL", g
    assert near(g[1], [0.55, 0.55, 0.62, 0.11]) and near(g[2], [0.55, 0.55, 0.62, 0.0275]), g
    assert out["quietEdgeA"] == 0, out
    gr = out["quietRGrad"]
    assert near(gr[1], [0.55, 0.55, 0.62, 0.0275]) and near(gr[2], [0.55, 0.55, 0.62, 0.11]), gr
    assert near(out["quietHover"][1], [0.55, 0.55, 0.62, 0.16]), out["quietHover"]
    assert out["caps"] == "HEADING", out
    assert out["tone"] == ["card", "inset", "quiet"], out
    assert out["titleGone"] is False and out["bodyNoTitle"][0][:4] == ["TOPLEFT", "TOPLEFT", 8, -8], out
    assert out["retoned"][0] == "inset" and near(out["retoned"][1], [0.06, 0.06, 0.07, 1]), out
    assert out["unknown"] == "card", out
    no_errors(w)


@case
def decorate_row_gives_one_hover_one_selected_look_a_stripe_and_a_hairline():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(300, 200)
        local b = CreateFrame("Button", nil, f)
        b:SetSize(300, 26)
        UI:DecorateRow(b, { selectable = true, stripe = true, rule = true })
        local res = {
          hoverLayer = b.dzHover:GetDrawLayer(), hoverC = __MOCK.S(b.dzHover).color,
          selShown = { b.dzSelFill:IsShown(), b.dzSelBar:IsShown() }, sel0 = b:IsSelected(),
          selC = __MOCK.S(b.dzSelFill).color, barC = __MOCK.S(b.dzSelBar).color, barW = b.dzSelBar:GetWidth(),
          stripeC = __MOCK.S(b.dzStripe).color, ruleC = __MOCK.S(b.dzRule).color, ruleH = b.dzRule:GetHeight(),
        }
        b:SetSelected(true)
        res.sel1 = { b:IsSelected(), b.dzSelFill:IsShown(), b.dzSelBar:IsShown() }
        b:SetSelected(false)
        res.sel2 = { b:IsSelected(), b.dzSelFill:IsShown() }
        b:SetStripe(1); res.st1 = b.dzStripe:IsShown()
        b:SetStripe(2); res.st2 = b.dzStripe:IsShown()
        b:SetStripe(nil); res.st3 = b.dzStripe:IsShown()
        b:SetHover(true); res.locked = __MOCK.S(b).highlight_locked
        -- a second call adds only what is missing (no second hover / fill)
        local hover, fill = b.dzHover, b.dzSelFill
        UI:DecorateRow(b, { selectable = true })
        res.same = hover == b.dzHover and fill == b.dzSelFill
        -- a plain frame: its hover is hooked to OnEnter / OnLeave (and survives the row's own handlers)
        local fr = CreateFrame("Frame", nil, f)
        fr:SetSize(300, 26)
        T_entered = 0
        fr:SetScript("OnEnter", function() T_entered = T_entered + 1 end)
        UI:DecorateRow(fr)
        res.frHidden = fr.dzHover:IsShown()
        res.frLayer = { fr.dzHover:GetDrawLayer() }
        __MOCK.hover(fr)
        res.frOn = fr.dzHover:IsShown()
        __MOCK.call_script(fr, "OnLeave")
        res.frOff = fr.dzHover:IsShown()
        res.entered = T_entered
        res.noSel = fr.dzSelFill == nil and fr.dzStripe == nil and fr.dzRule == nil
        fr:SetSelected(true)   -- (harmless without the selected look)
        local none = CreateFrame("Button", nil, f)
        UI:DecorateRow(none, { hover = false })
        res.noHover = none.dzHover == nil
        return res""")
    assert out["hoverLayer"] == "HIGHLIGHT" and near(out["hoverC"], [1, 1, 1, 0.05]), out
    assert out["selShown"] == [False, False] and out["sel0"] is False, out
    assert near(out["selC"], [1, 0.82, 0, 0.10]) and near(out["barC"], [1, 0.82, 0, 1]) and out["barW"] == 2, out
    assert near(out["stripeC"], [1, 1, 1, 0.025]) and near(out["ruleC"], [1, 1, 1, 0.07]) and out["ruleH"] == 1, out
    assert out["sel1"] == [True, True, True] and out["sel2"] == [False, False], out
    assert out["st1"] is False and out["st2"] is True and out["st3"] is False, out
    assert out["locked"] is True and out["same"] is True, out
    assert out["frHidden"] is False and out["frLayer"] == ["BACKGROUND", 3], out
    assert out["frOn"] is True and out["frOff"] is False and out["entered"] == 1, out
    assert out["noSel"] is True and out["noHover"] is True, out
    no_errors(w)


@case
def an_art_row_shows_its_picture_icon_title_sub_pill_and_right_text():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(500, 300)
        T_clicked = nil
        local r = UI:CreateArtRow(f, { width = 420, selectable = true, onClick = function(row, button) T_clicked = button end })
        local res = { h = r:GetHeight(), art = { r.art:GetWidth(), r.art:GetHeight() }, icon = { r.icon:GetWidth(), r.icon:IsShown() },
                      hasRule = r.dzRule ~= nil, selectable = r.dzSelFill ~= nil, artPt = { select(4, r.art:GetPoint(1)) } }
        local p0, l0, r0, t0, b0 = ns.ItemDB:RaidArt("kara", 64, 38, 0.6, true)
        r:SetData({ art = "kara", icon = 134400, title = "Karazhan", sub = "Tuesday 20:00", right = "10 of 10",
                    pill = { "ok", "Open" } })
        res.tex = __MOCK.S(r.art.tex).texture
        res.coords = __MOCK.S(r.art.tex).texcoord
        res.want = { p0, l0, r0, t0, b0 }
        res.icon2 = { r.icon:IsShown(), __MOCK.S(r.icon.tex).texture }
        res.title = r.title:GetText()
        res.titleSize = select(2, r.title:GetFont())
        res.sub = { r.sub:GetText(), r.sub:IsShown() }
        res.right = { r.rightText:GetText(), r.rightText:IsShown() }
        res.pill = { r.pill:IsShown(), r.pill.fs:GetText() }
        res.titlePt = { r.title:GetPoint(1) }
        res.titlePt[2] = res.titlePt[2] == r.art and "art" or "?"
        -- a path, a coords table, no sub (the title alone, centred), no pill, no right text
        r:SetData({ art = { "Interface\\\\Glues\\\\x", 0.1, 0.9, 0.2, 0.8 }, title = "Alone" })
        res.tex2 = { __MOCK.S(r.art.tex).texture, __MOCK.S(r.art.tex).texcoord }
        res.alone = { r.title:GetPoint(1) }
        res.alone[2] = nil
        res.sub2 = r.sub:IsShown()
        res.pill2 = r.pill:IsShown()
        res.right2 = r.rightText:IsShown()
        res.icon3 = r.icon:IsShown()
        r:SetData({ art = "Interface\\\\Glues\\\\whole", title = "Whole" })
        res.tex3 = { __MOCK.S(r.art.tex).texture, __MOCK.S(r.art.tex).texcoord }
        -- a pill kind that is an alias (the Upcoming rows' "Asked to join": "review") reads as the banners show it
        r:SetData({ art = "kara", title = "Asked", pill = { "review", "Asked to join" } })
        res.review = { r.pill.fs:GetTextColor() }
        res.warn = UI.PILL_LOOK.warn.text
        res.mute = UI.PILL_LOOK.mute.text
        -- a long title is cut to the room the right side leaves
        r:SetData({ art = "kara", title = string.rep("Long name ", 12), sub = "x", right = "right side" })
        res.cut = r.title:GetText()
        r:SetRightWidth(200)
        res.cut2 = r.title:GetText()
        r:SetData({ title = "Picked", selected = true })
        res.sel = { r:IsSelected(), r.dzSelFill:IsShown() }
        __MOCK.click(r, "RightButton")
        res.clicked = T_clicked
        res.tile = UI:CreateIconTile(f):GetWidth()
        return res""")
    assert out["h"] == 50 and out["art"] == [64, 38] and out["icon"] == [20, False], out
    assert out["hasRule"] is True and out["selectable"] is True and out["artPt"] == [2, 0], out
    assert out["tex"] == out["want"][0] and near(out["coords"], out["want"][1:]), out
    assert out["icon2"] == [True, 134400], out
    assert out["title"] == "Karazhan" and out["titleSize"] == 12, out
    assert out["sub"] == ["Tuesday 20:00", True] and out["right"] == ["10 of 10", True], out
    assert out["pill"] == [True, "Open"], out
    assert out["titlePt"][0] == "BOTTOMLEFT" and out["titlePt"][1] == "art" and out["titlePt"][2] == "RIGHT", out
    assert out["titlePt"][3:] == [14, 1], out
    assert out["tex2"] == ["Interface\\Glues\\x", [0.1, 0.9, 0.2, 0.8]], out
    assert out["alone"][0] == "LEFT" and out["alone"][2:] == ["RIGHT", 14, 0], out
    assert out["sub2"] is False and out["pill2"] is False and out["right2"] is False and out["icon3"] is False, out
    assert out["tex3"] == ["Interface\\Glues\\whole", [0, 1, 0, 1]], out
    assert near(out["review"][:3], out["warn"][:3], 1e-4) and not near(out["warn"][:3], out["mute"][:3], 1e-4), out
    assert out["cut"].endswith("...") and len(out["cut"]) < 120, out["cut"]
    assert out["cut2"].endswith("...") and len(out["cut2"]) < len(out["cut"]), (out["cut"], out["cut2"])
    assert out["sel"] == [True, True], out
    assert out["clicked"] == "RightButton", out
    assert out["tile"] == 20, out
    no_errors(w)


@case
def the_empty_state_shows_icon_title_text_and_one_action():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(600, 400)
        T_act = 0
        local e = UI:CreateEmptyState(f, { title = "No raid nights yet", text = "Turn it on to start.",
          action = { text = "Turn on My Log", onClick = function() T_act = T_act + 1 end } })
        local res = {
          w = e:GetWidth(), h = e:GetHeight(), port = { e.port:GetWidth(), __MOCK.S(e.port).vcolor },
          icon = { e.icon:GetWidth(), __MOCK.S(e.icon).texture }, title = { e.title:GetText(), e.title:IsShown() },
          titleC = { e.title:GetTextColor() }, text = { e.text:GetText(), e.text:IsShown() },
          btn = { e.btn:GetText(), e.btn:IsShown(), e.btn:GetHeight() },
        }
        __MOCK.click(e.btn)
        res.act = T_act
        -- refilled without an action or title, with an atlas glyph
        e:SetContent({ glyph = UI.ICON.notes, text = "Nothing here." })
        res.h2 = e:GetHeight()
        res.btn2 = e.btn:IsShown()
        res.title2 = e.title:IsShown()
        res.glyph = { __MOCK.S(e.icon).texture == UI.ICON_ATLAS, __MOCK.S(e.icon).vcolor }
        __MOCK.click(e.btn)
        res.act2 = T_act
        local small = UI:CreateEmptyState(f, { compact = true, title = "Empty" })
        res.small = { small:GetWidth(), small.port:GetWidth(), small.btn == nil }
        small:SetBoxWidth(220)
        res.small2 = { small:GetWidth(), small.title:GetWidth() }
        return res""")
    assert out["w"] == 430, out
    # disc 54 + 12 + title 14 + 10 + text 12 + 16 + button 24
    assert out["h"] == 54 + 12 + 14 + 10 + 12 + 16 + 24, out["h"]
    assert out["port"][0] == 54 and near(out["port"][1], [1, 0.82, 0, 0.12]), out
    assert out["icon"] == [30, 134939], out
    assert out["title"] == ["No raid nights yet", True] and near(out["titleC"][:3], [1, 0.82, 0]), out
    assert out["text"] == ["Turn it on to start.", True], out
    assert out["btn"] == ["Turn on My Log", True, 24] and out["act"] == 1, out
    assert out["h2"] == 54 + 12 + 12, out["h2"]
    assert out["btn2"] is False and out["title2"] is False, out
    assert out["glyph"][0] is True and near(out["glyph"][1], [1, 0.82, 0, 1]), out
    assert out["small"] == [360, 40, True] and out["small2"] == [220, 220], out
    no_errors(w)


@case
def a_notice_shows_its_kind_and_grows_with_its_text():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(600, 400)
        local n = UI:CreateNotice(f, "locked", "Locked by the raid leader")
        n:SetWidth(400)
        local res = { kind = n.kind, h = n:GetHeight(), text = n.text:GetText(), bar = __MOCK.S(n.bar).color,
                      bg = __MOCK.S(n.bg).color, icon = __MOCK.S(n.icon).texture, tw = n.text:GetWidth(),
                      shown = n:IsShown() }
        local kinds = {}
        for _, k in ipairs({ "readonly", "loading", "info", "whatever" }) do
          n:SetNotice(k, "x")
          kinds[#kinds + 1] = { n.kind, __MOCK.S(n.bar).color }
        end
        res.kinds = kinds
        res.readonlyGlyph = (function() n:SetNotice("readonly", "Only officers can change this")
          return __MOCK.S(n.icon).texture == UI.ICON_ATLAS end)()
        n:SetNotice("info", "one\\ntwo\\nthree")
        res.h3 = n:GetHeight()
        return res""")
    assert out["kind"] == "locked" and out["h"] == 26 and out["text"] == "Locked by the raid leader", out
    assert near(out["bar"], [1, 0.55, 0.20, 0.8]) and near(out["bg"], [1, 0.55, 0.20, 0.08]), out
    assert out["icon"] == "Interface\\PetBattles\\PetBattle-LockIcon" and out["tw"] == 400 - 28 - 10, out
    assert out["shown"] is True, out
    k = out["kinds"]
    assert k[0][0] == "readonly" and near(k[0][1], [0.4, 0.72, 1, 0.8]), k
    assert k[1][0] == "loading" and near(k[1][1], [0.62, 0.62, 0.62, 0.8]), k
    assert k[2][0] == "info" and near(k[2][1], [1, 0.82, 0, 0.8]), k
    assert k[3][0] == "info", k
    assert out["readonlyGlyph"] is True, out
    assert out["h3"] == 36 + 14, out["h3"]
    no_errors(w)


@case
def a_scroll_list_shows_its_empty_state_in_place_of_the_empty_text():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(400, 300)
        local list = UI:CreateScrollList(f, 26, function(row, d) end)
        list.frame:SetAllPoints(f)
        local res = {}
        -- the plain text as before
        list:SetEmptyText("Nothing yet")
        res.text1 = list.emptyText:IsShown()
        list:SetData({ 1, 2 })
        res.text2 = list.emptyText:IsShown()
        list:SetData({})
        res.text3 = list.emptyText:IsShown()
        -- the illustrated state takes the text's place
        list:SetEmptyState({ title = "No guests", text = "Pugs you raid with show here." })
        res.state1 = { list.emptyState:IsShown(), list.emptyText:IsShown(), list.emptyState.compact,
                       list.emptyState:GetWidth(), list.emptyState.title:GetText() }
        list:SetData({ 1 })
        res.state2 = { list.emptyState:IsShown(), list.emptyText:IsShown() }
        list:SetData({})
        res.state3 = list.emptyState:IsShown()
        list:SetEmptyState({ title = "Changed" })
        res.state4 = { list.emptyState.title:GetText(), list.emptyState.text:IsShown() }
        -- taken away: the text shows again
        list:SetEmptyState(nil)
        res.state5 = { list.emptyState:IsShown(), list.emptyText:IsShown() }
        list:SetEmptyText("")
        res.text4 = list.emptyText:IsShown()
        return res""")
    assert out["text1"] is True and out["text2"] is False and out["text3"] is True, out
    assert out["state1"] == [True, False, True, 344, "No guests"], out["state1"]
    assert out["state2"] == [False, False] and out["state3"] is True, out
    assert out["state4"] == ["Changed", False], out
    assert out["state5"] == [False, True] and out["text4"] is False, out
    no_errors(w)


if __name__ == "__main__":
    run_all()

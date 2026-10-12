"""The design values and UI primitives of refactor 1.4 (phase 1A / 1B): ns.Style (UI/Style.lua) - colour tokens and
their hex, the font scale with the legacy sizes snapped to it (D2), the named text styles, spacing - and the
primitives on ns.UI (UI/Widgets.lua): UI:Text / SetTextStyle, Fill, Gradient (white first), Rule, FitText, TextWidth,
AttachTooltip, Pool / HideFrom, the item helpers (the question-mark fallback) and the one window-position store
(SavePosition / RestorePosition on settings.windows). The old EUI / UI colour fields are the same tables as the tokens.

Run: luaenv\\Scripts\\python.exe tests\\style\\test_style.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors  # noqa: E402


def near(a, b, eps=1e-6):
    return len(a) == len(b) and all(abs(x - y) < eps for x, y in zip(a, b))


@case
def the_tokens_have_the_common_values_and_the_old_fields_are_the_same_tables():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local S, C, UI, EUI = ns.Style, ns.Style.C, ns.UI, ns.EventUI
        return {
          gold = C.GOLD, deep = C.GOLD_DEEP, sub = C.SUB, card = C.CARD, edge = C.EDGE, win = C.SURFACE_WINDOW,
          hair = C.HAIRLINE, hover = C.HOVER, select = C.SELECT,
          same = {
            EUI.GOLD == C.GOLD, EUI.GREY == C.SUB, EUI.DIM == C.DIM, EUI.TEXT == C.TEXT, EUI.CARD == C.CARD,
            EUI.EDGE == C.EDGE, EUI.YOU == C.YOU, EUI.LIVE == C.LIVE, UI.WIN_BG == C.SURFACE_WINDOW,
            UI.HUD_BG == C.HUD_BG, UI.HUD_BORDER == C.HUD_EDGE, UI.DROP_BG == C.DROP_BG, UI.DROP_EDGE == C.DROP_EDGE,
            UI.COUNT_SURFACE == C.SURFACE_WINDOW, C.SELECT_BAR == C.GOLD,
          },
          old = { EUI.GOLD, EUI.GREY, EUI.DIM, EUI.TEXT, EUI.YOU, EUI.LIVE, UI.WIN_BG, UI.HUD_BG, UI.HUD_BORDER,
                  UI.DROP_BG, UI.DROP_EDGE },
          pad = { EUI.PAD, EUI.GAP, S.PAD, S.GAP, S.IN },
          hex = { S.HEX.GOLD, S:Hex("GOLD"), S:Wrap("SUB", "x"), S:Hex("nope") },
          col = { S:Color("GOLD") }, colT = { S:Color({ 0.1, 0.2, 0.3 }) }, colX = { S:Color("nope") },
          sizes = { S.ROW.compact, S.ROW.list, S.ROW.rich, S.ROW.art, S.BANNER.hero, S.BANNER.tool, S.BANNER.strip,
                    S.BTN_H, S.PAGE_W, S.PAGE_H, S.INNER_W },
        }""")
    assert out["gold"] == [1, 0.82, 0] and near(out["deep"], [0.91, 0.73, 0.14]), out
    assert out["sub"] == [0.62, 0.62, 0.62] and near(out["card"], [0.10, 0.10, 0.12, 0.92]), out
    assert near(out["edge"], [0.34, 0.34, 0.38, 0.55]) and near(out["win"], [0.078, 0.078, 0.09]), out
    assert near(out["hair"], [1, 1, 1, 0.07]) and near(out["hover"], [1, 1, 1, 0.05]), out
    assert near(out["select"], [1, 0.82, 0, 0.10]), out
    assert all(out["same"]), out["same"]
    # the old fields keep their numbers and their length (callers unpack them)
    old = out["old"]
    assert old[0] == [1, 0.82, 0] and old[1] == [0.62, 0.62, 0.62] and near(old[2], [0.44, 0.44, 0.46]), old
    assert near(old[3], [0.88, 0.88, 0.88]) and near(old[4], [0.4, 0.72, 1]) and near(old[5], [1, 0.35, 0.27]), old
    assert near(old[6], [0.078, 0.078, 0.09]) and near(old[7], [0.04, 0.04, 0.05, 0.82]), old
    assert near(old[8], [0.4, 0.4, 0.4, 0.9]) and near(old[9], [0.06, 0.06, 0.07, 0.98]), old
    assert near(old[10], [0.34, 0.34, 0.38, 1]), old
    assert out["pad"] == [10, 8, 10, 8, 8], out["pad"]
    assert out["hex"] == ["ffd100", "|cffffd100", "|cff9e9e9ex|r", "|cffffffff"], out["hex"]
    assert out["col"] == [1, 0.82, 0, 1] and near(out["colT"], [0.1, 0.2, 0.3, 1]) and out["colX"] == [1, 1, 1, 1], out
    assert out["sizes"] == [22, 26, 38, 50, 128, 84, 46, 24, 790, 548, 770], out["sizes"]
    no_errors(w)


@case
def legacy_font_sizes_snap_to_the_nearest_step_of_the_scale():
    w, c = solo("Rai", guild_rank=0, tick=2)
    got = c.eval_py("""
        local S = ns.Style
        local out = {}
        for _, n in ipairs({ 7.5, 8, 9, 9.5, 10, 10.5, 11, 11.5, 12, 12.5, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 46 }) do
          out[#out + 1] = S:Size(n)
        end
        out[#out + 1] = S:Size("title")
        out[#out + 1] = S:Size("num")
        out[#out + 1] = S:Size(nil)
        out[#out + 1] = S:Size(10.4)
        return out""")
    # ties go to the smaller step; past 21 a size is a display numeral and passes through
    assert got == [9.5, 9.5, 9.5, 9.5, 10, 10, 11, 11, 12, 12, 13, 13, 13, 17, 17, 17, 19, 19, 19, 22, 46,
                   13, 11, 11, 10], got
    scale = c.eval_py("local F = ns.Style.FONT; return { F.hero, F.page, F.title, F.emph, F.body, F.small, F.caps }")
    assert scale == [19, 17, 13, 12, 11, 10, 9.5], scale
    no_errors(w)


@case
def ui_text_makes_a_styled_line_and_set_text_style_restyles_it():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        local t = UI:Text(f, "title")
        local n = UI:Text(f, "num", "GOLD", { justify = "RIGHT", layer = "ARTWORK" })
        local cap = UI:Text(f, "caps", nil, { text = "signed up" })
        local legacy = UI:Text(f, 10.5, { 0.5, 0.6, 0.7 })
        local wrap = UI:Text(f, "body", nil, { wrap = true, width = 120 })
        local function font(fs) local p, s, fl = fs:GetFont(); return { p, s, fl } end
        local function col(fs) return { fs:GetTextColor() } end
        local out = {
          title = font(t), titleC = col(t), num = font(n), numC = col(n), numJ = n:GetJustifyH(),
          numLayer = n:GetDrawLayer(), cap = cap:GetText(), capF = font(cap), capC = col(cap),
          legacy = font(legacy), legacyC = col(legacy), wrap = wrap:CanWordWrap(), noWrap = t:CanWordWrap(),
          wrapW = wrap:GetWidth(), j = t:GetJustifyH(),
        }
        UI:SetTextStyle(t, "small")
        out.restyled = font(t)
        out.restyledC = col(t)
        UI:SetTextStyle(n, 12.5)                 -- a legacy size keeps the face (the narrow digits)
        out.keptFace = font(n)
        return out""")
    assert out["title"][1:] == [13, ""] and out["titleC"] == [1, 0.82, 0, 1], out
    assert out["num"] == ["Fonts\\ARIALN.TTF", 11, ""] and out["numC"] == [1, 0.82, 0, 1], out
    assert out["numJ"] == "RIGHT" and out["numLayer"] == "ARTWORK" and out["j"] == "LEFT", out
    assert out["cap"] == "SIGNED UP" and out["capF"][1] == 9.5 and out["capC"] == [0.62, 0.62, 0.62, 1], out
    assert out["legacy"][1] == 10 and near(out["legacyC"], [0.5, 0.6, 0.7, 1]), out
    assert out["wrap"] is True and out["noWrap"] is False and out["wrapW"] == 120, out
    assert out["restyled"][1] == 10 and out["restyledC"] == [0.62, 0.62, 0.62, 1], out
    assert out["keptFace"] == ["Fonts\\ARIALN.TTF", 12, ""], out
    no_errors(w)


@case
def gradient_whitens_the_texture_first_and_fill_and_rule_paint_tokens():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(200, 100)
        local tex = f:CreateTexture()
        tex:SetTexture("Interface\\\\Buttons\\\\UI-Quickslot2")
        UI:Gradient(tex, "VERTICAL", "CARD", { 1, 0, 0, 0.5 })
        local st = __MOCK.S(tex)
        local fill = UI:Fill(f, "HOVER", "BORDER", 2)
        local fst = __MOCK.S(fill)
        local r1 = UI:Rule(f, { top = 30, left = 4, right = 6 })
        local r2 = UI:Rule(f, { vertical = true, right = 10, color = "GOLD", alpha = 0.3 })
        local r3 = UI:Rule(f, { bottom = 2 })
        local function pts(t)
          local out = {}
          for i = 1, t:GetNumPoints() do
            local p, rel, rp, x, y = t:GetPoint(i)
            out[#out + 1] = { p, rp, x, y }
          end
          return out
        end
        return {
          tex = st.texture, grad = st.gradient, fillC = fst.color, fillLayer = { fill:GetDrawLayer() },
          r1 = pts(r1), r1h = r1:GetHeight(), r1c = __MOCK.S(r1).color,
          r2 = pts(r2), r2w = r2:GetWidth(), r2c = __MOCK.S(r2).color, r3 = pts(r3),
        }""")
    assert out["tex"] == "Color", out["tex"]            # set white (a colour texture) before the gradient
    g = out["grad"]
    assert g[0] == "VERTICAL" and near(g[1], [0.10, 0.10, 0.12, 0.92]) and near(g[2], [1, 0, 0, 0.5]), g
    assert near(out["fillC"], [1, 1, 1, 0.05]) and out["fillLayer"] == ["BORDER", 2], out
    assert out["r1"] == [["TOPLEFT", "TOPLEFT", 4, -30], ["TOPRIGHT", "TOPRIGHT", -6, -30]] and out["r1h"] == 1, out
    assert near(out["r1c"], [1, 1, 1, 0.07]), out
    assert out["r2"] == [["TOPRIGHT", "TOPRIGHT", -10, 0], ["BOTTOMRIGHT", "BOTTOMRIGHT", -10, 0]], out
    assert out["r2w"] == 1 and near(out["r2c"], [1, 0.82, 0, 0.3]), out
    assert out["r3"] == [["BOTTOMLEFT", "BOTTOMLEFT", 0, 2], ["BOTTOMRIGHT", "BOTTOMRIGHT", 0, 2]], out
    no_errors(w)


@case
def fit_text_cuts_with_dots_and_text_width_measures_one_line():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        local fs = UI:Text(f, "body")
        local out = {}
        out.short = { UI:FitText(fs, "Short", 100), fs:GetText() }
        out.long = { UI:FitText(fs, "A rather long name", 60), fs:GetText() }       -- (the mock: 6 px a character)
        out.coded = { UI:FitText(fs, "|cffffd100Golden words here|r", 60), fs:GetText() }
        out.utf = { UI:FitText(fs, "\\195\\132\\195\\132\\195\\132\\195\\132\\195\\132\\195\\132\\195\\132\\195\\132\\195\\132\\195\\132\\195\\132", 42), fs:GetText() }
        out.w1 = UI:TextWidth("abcd")
        out.w2 = UI:TextWidth(fs)
        out.w3 = ns.UI:TextWidth(fs)
        return out""")
    assert out["short"] == [False, "Short"], out
    assert out["long"] == [True, "A rathe..."], out           # 7 characters + "..." = 60 px
    assert out["coded"] == [True, "|cffffd100Golden ...|r"], out
    # whole characters only (the mock measures bytes: two 2-byte letters + "..." = 42 px)
    assert out["utf"][0] is True and out["utf"][1] == "Ä" * 2 + "...", out
    assert out["w1"] == 24 and out["w2"] == out["w3"] and out["w2"] > 0, out
    no_errors(w)


@case
def attach_tooltip_fills_the_tooltip_on_enter_and_hides_on_leave():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(40, 20)
        T_own = 0
        f:SetScript("OnEnter", function() T_own = T_own + 1 end)
        UI:AttachTooltip(f, "Title", { "a line", { "red", 1, 0, 0 }, { "gold", "GOLD" } })
        local function lines()
          local out = {}
          for i = 1, GameTooltip:NumLines() do out[#out + 1] = _G["GameTooltipTextLeft" .. i]:GetText() end
          return out
        end
        local res = { mouse = f:IsMouseEnabled() }
        __MOCK.hover(f)
        res.first = lines()
        res.owner = GameTooltip:GetOwner() == f
        res.shown = GameTooltip:IsShown()
        res.titleC = { _G.GameTooltipTextLeft1:GetTextColor() }
        res.goldC = { _G.GameTooltipTextLeft4:GetTextColor() }
        res.own = T_own
        __MOCK.call_script(f, "OnLeave")
        res.hidden = not GameTooltip:IsShown()
        -- a function title fills the tooltip itself; attaching again replaces the content (hooked once)
        UI:AttachTooltip(f, function(self, tt) tt:AddLine("built " .. (self == f and "for f" or "?")) end,
                         function() return { "more" } end, { anchor = "ANCHOR_TOP" })
        __MOCK.hover(f)
        res.second = lines()
        res.anchor = GameTooltip:GetAnchorType()
        res.own2 = T_own
        UI:AttachTooltip(f, function() return false end)
        __MOCK.hover(f)
        res.vetoed = not GameTooltip:IsShown()
        return res""")
    assert out["mouse"] is True, out
    assert out["first"] == ["Title", "a line", "red", "gold"] and out["owner"] and out["shown"], out
    assert out["titleC"][:3] == [1, 0.82, 0] and out["goldC"][:3] == [1, 0.82, 0], out
    assert out["own"] == 1 and out["hidden"], out
    assert out["second"] == ["built for f", "more"] and out["anchor"] == "ANCHOR_TOP" and out["own2"] == 2, out
    assert out["vetoed"], out
    no_errors(w)


@case
def a_pool_reuses_its_rows_and_hide_from_hides_the_rest():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local parent = CreateFrame("Frame", nil, UIParent)
        local made, resets = 0, 0
        local pool = UI:Pool(parent, function(p, i)
          made = made + 1
          local r = CreateFrame("Frame", nil, p)
          r.index = i
          return r
        end, function(r) resets = resets + 1 end)
        local a = pool:Acquire()
        local b, ib = pool:Acquire()
        local res = { made1 = made, ib = ib, active1 = pool:Active(), aShown = a:IsShown() }
        pool:ReleaseAll()
        res.hiddenAfter = not a:IsShown() and not b:IsShown()
        res.active0 = pool:Active()
        res.resets = resets
        local a2 = pool:Acquire()
        res.reused = a2 == a and made == 2
        local seen = {}
        pool:Each(function(r, i) seen[#seen + 1] = i end)
        res.each = seen
        local list = {}
        for i = 1, 4 do list[i] = CreateFrame("Frame", nil, parent) end
        UI:HideFrom(list, 3)
        res.hide = { list[1]:IsShown(), list[2]:IsShown(), list[3]:IsShown(), list[4]:IsShown() }
        return res""")
    assert out["made1"] == 2 and out["ib"] == 2 and out["active1"] == 2 and out["aShown"], out
    assert out["hiddenAfter"] and out["active0"] == 0 and out["resets"] == 2, out
    assert out["reused"] and out["each"] == [1], out
    assert out["hide"] == [True, True, False, False], out
    no_errors(w)


@case
def item_helpers_fall_back_to_the_question_mark_and_name_items():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local known = 28830                      -- Dragonspine Trophy (in the mock's item data)
        return {
          icon0 = UI:ItemIcon(nil), iconBad = UI:ItemIcon(999999999), icon = UI:ItemIcon(known),
          name = UI:ItemName(known) or "nil", label = UI:ItemLabel(known) or "nil", text = UI:ItemText(known),
          noName = UI:ItemName(999999999) == nil, noLabel = UI:ItemLabel(999999999) == nil,
        }""")
    assert out["icon0"] == 134400 and out["iconBad"] == 134400, out
    assert out["icon"] != 134400, out
    assert out["name"] == "Dragonspine Trophy", out
    assert "Dragonspine Trophy" in out["label"] and out["label"].startswith("|c"), out
    assert "Dragonspine Trophy" in out["text"], out
    assert out["noName"] and out["noLabel"], out
    no_errors(w, allow=("999999999",))


@case
def save_and_restore_position_round_trip_through_settings_windows():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(100, 100)
        f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 120.4, -57.6)
        local res = { saved = UI:SavePosition(f, "DZStyleTest") }
        res.stored = DisasterZoneDB.settings.windows.DZStyleTest
        f:ClearAllPoints()
        f:SetPoint("CENTER")
        res.restored = UI:RestorePosition(f, "DZStyleTest")
        res.point = { f:GetPoint(1) }
        res.point[2] = res.point[2] == UIParent
        -- nothing saved: the default given, else the centre
        local g = CreateFrame("Frame", nil, UIParent)
        res.def = UI:RestorePosition(g, "DZStyleNone", "TOP", UIParent, "TOP", 0, -120)
        res.defPoint = { g:GetPoint(1) }
        res.defPoint[2] = res.defPoint[2] == UIParent
        UI:RestorePosition(g, "DZStyleNone")
        res.centre = { g:GetPoint(1) }
        res.centre[2] = res.centre[2] == UIParent
        -- a window: its name is the key; noSavePosition keeps none
        local win = UI:CreateWindow("DZStyleWin", "Test", 200, 120)
        win:ClearAllPoints()
        win:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -30, 40)
        res.win = UI:SavePosition(win)
        res.winStored = DisasterZoneDB.settings.windows.DZStyleWin
        local quiet = UI:CreateWindow("DZStyleQuiet", "Test", 200, 120, { noSavePosition = true })
        res.quiet = UI:SavePosition(quiet)
        res.quietStored = DisasterZoneDB.settings.windows.DZStyleQuiet == nil
        return res""")
    assert out["saved"] is True and out["stored"] == ["TOPLEFT", "TOPLEFT", 120, -58], out
    assert out["restored"] is True and out["point"] == ["TOPLEFT", True, "TOPLEFT", 120, -58], out
    assert out["def"] is False and out["defPoint"] == ["TOP", True, "TOP", 0, -120], out
    assert out["centre"] == ["CENTER", True, "CENTER", 0, 0], out
    assert out["win"] is True and out["winStored"] == ["BOTTOMRIGHT", "BOTTOMRIGHT", -30, 40], out
    assert out["quiet"] is False and out["quietStored"], out
    no_errors(w)


@case
def the_old_widgets_and_aliases_are_gone_and_the_real_ones_work():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py("""
        local UI = ns.UI
        local f = CreateFrame("Frame", nil, UIParent)
        local b = UI:CreateSleekButton(f, "Go", nil, nil, function() end)
        local dd = UI:CreateSleekDropdown(f, 120, function() return {} end, function() return nil end, function() end)
        local mb = UI:CreateSleekMenuButton(f, "More", 80, function() end)
        local lbl = UI:CreateLabel(f, "label")
        return { flat = UI.CreateFlatButton == nil and UI.CreateButton == nil and UI.CreateDropdown == nil
                     and UI.CreateMenuButton == nil and b:GetHeight() == 22,
                 kept = b ~= nil and dd ~= nil and mb ~= nil and lbl:GetText() == "label",
                 cam = type(UI.FitModelCamera) == "function" }""")
    assert out == {"flat": True, "kept": True, "cam": True}, out
    no_errors(w)


if __name__ == "__main__":
    run_all()

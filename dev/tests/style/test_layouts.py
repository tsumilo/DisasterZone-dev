"""The page layouts of refactor 1.4 phase 3 (UI/Comp/Layouts.lua, REFACTOR_API.md "Layouts.lua"): UI:CreateLayout's
five kinds - board (toolbar, hero, body, side card), listdetail (list, nav column, detail banner, tabs on its foot,
body), detail (back + hero banner, block tabs, tool row, body), rail (side menu, hairline, body, scrolling body) and
tool (tool banner, tool row, body) - on today's geometry (the Raids tab's view row, the Guest book, the raid page,
Settings, the Swing practice window); the toolbar (tabs + small tabs in their own group, counts, hidden tabs, the
primary action far right at S.BTN_H, the "···" menu, filters before it); the empty and notice slots; the main
window's RegisterTab(..., opts) and S.PAGE_W / PAGE_H / INNER_W; and the component gallery (dev/tools/ui_gallery.py)
building without an error.

Run: luaenv\\Scripts\\python.exe tests\\style\\test_layouts.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
DEV = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(DEV, "tools"))

from _common import case, run_all, solo, no_errors  # noqa: E402

# (Lua helpers: the points of a region, relative to "parent" / a named frame / "other")
PTS = """
local UI, S = ns.UI, ns.Style
local function pts(t, names)
  local out = {}
  for i = 1, t:GetNumPoints() do
    local p, rel, rp, x, y = t:GetPoint(i)
    local who = "none"
    if names then for k, v in pairs(names) do if v == rel then who = k end end end
    if who == "none" and rel == t:GetParent() then who = "parent" end
    if who == "none" and rel then who = "other" end
    out[#out + 1] = { p, rp, x, y, who }
  end
  return out
end
local host = CreateFrame("Frame", nil, UIParent)
host:SetSize(790, 548)
"""


@case
def board_toolbar_row_hero_body_and_side_card_on_the_raids_tab_geometry():
    w, c = solo()
    out = c.eval_py(PTS + """
        local L = UI:CreateLayout("board", host, { hero = { title = "Kara full clear", art = "kara" }, side = true })
        local t = L.toolbar
        local clicked = {}
        t:SetTabs({ "Upcoming", "Teams", { key = "guests", text = "Guests", count = 2 } }, function(k) clicked[#clicked + 1] = k end)
        local f1 = UI:CreateSleekMenuButton(host, "All lineups", 116, function() end)
        local f2 = UI:CreateSleekButton(host, "Guests", 64, 22, function() end)
        t:SetFilters({ f1, f2 })
        t:SetMore(function(root) end, "Hide, share")
        local prim = t:SetPrimary({ text = "New raid", onClick = function() clicked[#clicked + 1] = "primary" end })
        local res = { kind = L.kind, top = pts(t, { L = L }), tbH = t:GetHeight(),
          tab1 = pts(t.tabButtons[1], { t = t }), tab2 = pts(t.tabButtons[2], { prev = t.tabButtons[1] }),
          sel = t:GetSelectedTab(), cnt = t.tabButtons[3].cnt and t.tabButtons[3].cnt:IsShown(),
          prim = pts(prim, { t = t }), primH = prim:GetHeight(), primW = prim:GetWidth(),
          more = pts(t.more, { prim = prim }), moreH = t.more:GetHeight(),
          f2 = pts(f2, { more = t.more }), f1 = pts(f1, { f2 = f2 }), fparent = f1:GetParent() == t,
          content = pts(L.content, { L = L }), banner = pts(L.banner, { content = L.content }),
          bannerH = L.banner:GetHeight(), side = pts(L.side, { content = L.content }), sideW = L.side:GetWidth(),
          body = pts(L.body, { content = L.content }), bodyW = L.bodyW, innerW = L.innerW, hero = L.hero == L.banner }
        -- a hidden filter leaves no gap; clicks
        f2:Hide()
        res.f1Hidden = pts(f1, { more = t.more })
        t.tabButtons[2]:Click()
        prim:Click()
        res.clicked = clicked
        res.sel2 = t:GetSelectedTab()
        res.active = { t.tabButtons[1].active, t.tabButtons[2].active }
        t:SetPrimary(nil)
        res.moreAfter = pts(t.more, { t = t })
        return res""")
    assert out["kind"] == "board", out
    assert out["top"] == [["TOPLEFT", "TOPLEFT", 0, 0, "L"], ["TOPRIGHT", "TOPRIGHT", 0, 0, "L"]], out["top"]
    assert out["tbH"] == 36, out
    assert out["tab1"] == [["TOPLEFT", "TOPLEFT", 6, -6, "t"]], out["tab1"]
    assert out["tab2"] == [["LEFT", "RIGHT", 4, 0, "prev"]], out["tab2"]
    assert out["sel"] == "Upcoming" and out["cnt"], out
    assert out["prim"] == [["RIGHT", "TOPRIGHT", -10, -17, "t"]], out["prim"]
    assert out["primH"] == 24 and out["primW"] >= 90, out
    assert out["more"] == [["RIGHT", "LEFT", -6, 0, "prim"]] and out["moreH"] == 24, out
    assert out["f2"] == [["RIGHT", "LEFT", -6, 0, "more"]] and out["f1"] == [["RIGHT", "LEFT", -6, 0, "f2"]], out
    assert out["fparent"], out
    assert out["content"] == [["TOPLEFT", "TOPLEFT", 10, -36, "L"], ["BOTTOMRIGHT", "BOTTOMRIGHT", -10, 4, "L"]], out
    assert out["banner"][0] == ["TOPLEFT", "TOPLEFT", 0, 0, "content"] and out["bannerH"] == 128, out
    assert out["side"] == [["TOPRIGHT", "TOPRIGHT", 0, -136, "content"], ["BOTTOMRIGHT", "BOTTOMRIGHT", 0, 0, "content"]], out
    assert out["sideW"] == 250, out
    assert out["body"] == [["TOPLEFT", "TOPLEFT", 0, -136, "content"], ["BOTTOMRIGHT", "BOTTOMRIGHT", -258, 0, "content"]], out
    assert out["innerW"] == 770 and out["bodyW"] == 770 - 258 and out["hero"], out
    assert out["f1Hidden"] == [["RIGHT", "LEFT", -6, 0, "more"]], out
    assert out["clicked"] == ["Teams", "primary"] and out["sel2"] == "Teams", out
    assert out["active"] == [False, True], out
    assert out["moreAfter"] == [["RIGHT", "TOPRIGHT", -10, -17, "t"]], out
    no_errors(w)


@case
def board_without_toolbar_hero_or_side_starts_at_the_top_and_takes_the_width():
    w, c = solo()
    out = c.eval_py(PTS + """
        local L = UI:CreateLayout("board", host, { toolbar = false, pad = 0, bottom = 0 })
        return { tb = L.toolbar == nil, banner = L.banner == nil, side = L.side == nil,
          content = pts(L.content, { L = L }), body = pts(L.body, { content = L.content }), bodyW = L.bodyW,
          all = L:GetNumPoints() }""")
    assert out["tb"] and out["banner"] and out["side"], out
    assert out["content"] == [["TOPLEFT", "TOPLEFT", 0, 0, "L"], ["BOTTOMRIGHT", "BOTTOMRIGHT", 0, 0, "L"]], out
    assert out["body"] == [["TOPLEFT", "TOPLEFT", 0, 0, "content"], ["BOTTOMRIGHT", "BOTTOMRIGHT", 0, 0, "content"]], out
    assert out["bodyW"] == 790 and out["all"] == 2, out
    no_errors(w)


@case
def toolbar_small_tabs_are_their_own_group_after_a_separator_and_tabs_relayout():
    w, c = solo()
    out = c.eval_py(PTS + """
        local L = UI:CreateLayout("board", host)
        local t = L.toolbar
        local got = {}
        t:SetTabs({ "Upcoming", "Guests", "Raid log", { key = "raids", text = "Raids", small = true },
          { key = "att", text = "Attendance", small = true, tip = "Who came" }, selected = "Raid log" },
          function(k, item, b) got[#got + 1] = k end)
        local b = t.tabByKey
        local res = { sel = t:GetSelectedTab(), sub = t:GetSelectedTab("sub"),
          raids = pts(b.raids, { log = b["Raid log"] }), att = pts(b.att, { raids = b.raids }),
          sep = t.tabSeps[1]:IsShown(), sepPts = pts(t.tabSeps[1], { log = b["Raid log"] }),
          kinds = { b.Upcoming.tabKind, b.raids.tabKind } }
        t:SelectTab("att", true)
        res.afterSub = { t:GetSelectedTab(), t:GetSelectedTab("sub"), b["Raid log"].active, b.att.active, b.raids.active }
        t:SetTabShown("Guests", false)
        res.logAfterHide = pts(b["Raid log"], { up = b.Upcoming })
        t:SetTabCount("Upcoming", 3)
        res.count = b.Upcoming.cnt and b.Upcoming.cnt:IsShown()
        t:SetTabCount("Upcoming", 0)
        res.countOff = b.Upcoming.cnt:IsShown()
        t:SetTabLabel("Upcoming", "Next")
        res.label = b.Upcoming:GetText()
        -- new tabs keep the open one where it still exists, without a click
        t:SetTabs({ "Upcoming", "Raid log", "Teams" })
        res.keep = t:GetSelectedTab()
        res.sepGone = not t.tabSeps[1]:IsShown()
        res.got = got
        t:SelectTab("nope", true)
        t:SetText("6 accepted")
        res.text = { t.label:IsShown(), t.label:GetText(), pts(t.label, { last = t.lastTab }) }
        return res""")
    assert out["sel"] == "Raid log" and out["sub"] == "raids", out
    assert out["raids"] == [["LEFT", "RIGHT", 16, -1, "log"]], out["raids"]
    assert out["att"] == [["LEFT", "RIGHT", 2, 0, "raids"]], out["att"]
    assert out["sep"] and out["sepPts"] == [["LEFT", "RIGHT", 8, -1, "log"]], out
    assert out["kinds"] == ["page", "small"], out
    assert out["afterSub"] == ["Raid log", "att", True, True, False], out
    assert out["logAfterHide"] == [["LEFT", "RIGHT", 4, 0, "up"]], out
    assert out["count"] and not out["countOff"] and out["label"] == "Next", out
    assert out["keep"] == "Raid log" and out["sepGone"], out
    assert out["got"] == ["att"], out
    assert out["text"][0] and out["text"][1] == "6 accepted", out
    assert out["text"][2] == [["LEFT", "RIGHT", 12, 0, "last"]], out
    no_errors(w)


@case
def listdetail_list_detail_banner_tabs_and_body_like_the_guest_book():
    w, c = solo()
    out = c.eval_py(PTS + """
        local L = UI:CreateLayout("listdetail", host, { listWidth = 250, banner = { title = "Pugsyhealer", sub = "Priest" },
          tabs = { { key = "raids", text = "Raids", count = { 1, 2 } }, { key = "items", text = "Items", count = 1 } } })
        local res = { list = pts(L.list, { content = L.content }), listW = L.list:GetWidth(),
          detail = pts(L.detail, { content = L.content }), detailW = L.detailW,
          banner = pts(L.banner, { detail = L.detail }), bannerW = L.banner:GetWidth(), bannerH = L.banner:GetHeight(),
          tabs = pts(L.tabs, { detail = L.detail }), tabsH = L.tabs:GetHeight(),
          body = pts(L.body, { detail = L.detail }), bodyW = L.bodyW,
          block = L.tabs.tabStyle, tab1 = pts(L.tabs.tabButtons[1], { s = L.tabs }),
          tab2 = pts(L.tabs.tabButtons[2], { prev = L.tabs.tabButtons[1] }),
          tabW = L.tabs.tabButtons[1]:GetWidth(), fill = L.tabs.tabButtons[1].fill:IsShown(),
          count = L.tabs.tabButtons[2].count:GetText(), nav = L.nav == nil, tb = L.toolbar ~= nil }
        -- the default list width; a nav column (Atlas); no banner
        local L2 = UI:CreateLayout("listdetail", host, { navWidth = true, banner = false })
        res.def = { L2.listW, L2.navW, pts(L2.nav, { content = L2.content }), pts(L2.list, { content = L2.content }),
          pts(L2.detail, { content = L2.content }), pts(L2.body, { detail = L2.detail }), L2.detailW, L2.banner == nil }
        return res""")
    assert out["list"] == [["TOPLEFT", "TOPLEFT", 0, 0, "content"], ["BOTTOMLEFT", "BOTTOMLEFT", 0, 0, "content"]], out
    assert out["listW"] == 250 and out["detailW"] == 770 - 258, out
    assert out["detail"] == [["TOPLEFT", "TOPLEFT", 258, 0, "content"], ["BOTTOMRIGHT", "BOTTOMRIGHT", 0, 0, "content"]], out
    assert out["banner"][0] == ["TOPLEFT", "TOPLEFT", 0, 0, "detail"] and out["bannerW"] == 512, out
    assert out["bannerH"] == 128, out
    assert out["tabs"][0] == ["TOPLEFT", "TOPLEFT", 0, -128, "detail"] and out["tabsH"] == 34, out
    assert out["body"] == [["TOPLEFT", "TOPLEFT", 0, -170, "detail"], ["BOTTOMRIGHT", "BOTTOMRIGHT", 0, 0, "detail"]], out
    assert out["bodyW"] == 512 and out["block"] == "block", out
    assert out["tab1"] == [["TOPLEFT", "TOPLEFT", 0, 0, "s"]] and out["tab2"] == [["TOPLEFT", "TOPRIGHT", 0, 0, "prev"]]
    assert out["tabW"] >= 170 and out["fill"], out
    assert "1" in out["count"], out
    assert out["nav"] and out["tb"], out
    d = out["def"]
    assert d[0] == 300 and d[1] == 180, d
    assert d[2][0] == ["TOPLEFT", "TOPLEFT", 0, 0, "content"], d
    assert d[3][0] == ["TOPLEFT", "TOPLEFT", 188, 0, "content"], d
    assert d[4][0] == ["TOPLEFT", "TOPLEFT", 188 + 308, 0, "content"], d
    assert d[5][0] == ["TOPLEFT", "TOPLEFT", 0, 0, "detail"], d
    assert d[6] == 770 - 188 - 308 and d[7], d
    no_errors(w)


@case
def detail_back_hero_tabs_tool_row_and_body_at_the_raid_pages_offsets():
    w, c = solo()
    out = c.eval_py(PTS + """
        local backed = 0
        local L = UI:CreateLayout("detail", host, { top = 36, back = { "All raids", function() backed = backed + 1 end },
          banner = { title = "Kara full clear", art = "kara" },
          tabs = { { key = "signups", text = "Sign-ups", count = { 6, 10 } }, { key = "groups", text = "Groups" } } })
        local res = { banner = pts(L.banner, { L = L }), back = L.banner.back and L.banner.back:IsShown(),
          tabs = pts(L.tabs, { L = L }), tb = pts(L.toolbar, { L = L }), tbH = L.toolbar:GetHeight(),
          body = pts(L.body, { L = L }), sel = L.tabs:GetSelectedTab() }
        if L.banner.back then L.banner.back:Click() end
        res.backed = backed
        local p = L.toolbar:SetPrimary({ text = "Add players", kind = "secondary", icon = 19 })
        res.prim = pts(p, { tb = L.toolbar })
        local L2 = UI:CreateLayout("detail", host, { toolbar = false })
        res.noTb = { L2.toolbar == nil, pts(L2.body, { L = L2 }) }
        return res""")
    assert out["banner"][0] == ["TOPLEFT", "TOPLEFT", 10, -36, "L"], out
    assert out["back"] and out["backed"] == 1, out
    assert out["tabs"][0] == ["TOPLEFT", "TOPLEFT", 10, -164, "L"], out
    assert out["tb"][0] == ["TOPLEFT", "TOPLEFT", 10, -(164 + 34 + 10), "L"] and out["tbH"] == 26, out
    # (the raid page: BODY_Y = 128 + 34 + 10 + 26 + 8)
    assert out["body"] == [["TOPLEFT", "TOPLEFT", 10, -(36 + 206), "L"], ["BOTTOMRIGHT", "BOTTOMRIGHT", -10, 4, "L"]], out
    assert out["sel"] == "signups", out
    assert out["prim"] == [["RIGHT", "TOPRIGHT", 0, -13, "tb"]], out
    assert out["noTb"][0] and out["noTb"][1][0] == ["TOPLEFT", "TOPLEFT", 10, -(128 + 34 + 8), "L"], out
    no_errors(w)


@case
def rail_side_menu_hairline_and_body_like_settings():
    w, c = solo()
    out = c.eval_py(PTS + """
        local picked = {}
        local L = UI:CreateLayout("rail", host, { items = { { key = "alerts", label = "Alerts" },
          { key = "about", label = "About" } }, selected = "alerts", onSelect = function(k) picked[#picked + 1] = k end })
        local res = { rail = pts(L.rail, { L = L }), railW = L.rail:GetWidth(), sel = L.rail:GetSelected(),
          rule = pts(L.rule, { L = L }), body = pts(L.body, { L = L }), bodyW = L.bodyW, tb = L.toolbar == nil }
        L.rail:Select("about", true)
        res.picked = picked
        local L2 = UI:CreateLayout("rail", host, { scroll = true, toolbar = true })
        res.scroll = { L2.scroll ~= nil, L2.body:GetParent() == L2.scroll, L2.scroll:GetScrollChild() == L2.body,
          pts(L2.scroll, { L = L2 }), pts(L2.rail, { L = L2 }), L2.toolbar ~= nil }
        return res""")
    assert out["rail"] == [["TOPLEFT", "TOPLEFT", 10, -8, "L"]] and out["railW"] == 150, out
    assert out["sel"] == "alerts" and out["picked"] == ["about"], out
    assert out["rule"] == [["TOPLEFT", "TOPLEFT", 160, -8, "L"], ["BOTTOMLEFT", "BOTTOMLEFT", 160, 10, "L"]], out
    assert out["body"] == [["TOPLEFT", "TOPLEFT", 178, -8, "L"], ["BOTTOMRIGHT", "BOTTOMRIGHT", -10, 10, "L"]], out
    assert out["bodyW"] == 602 and out["tb"], out
    s = out["scroll"]
    assert s[0] and s[1] and s[2] and s[5], s
    assert s[3][0] == ["TOPLEFT", "TOPLEFT", 178, -36, "L"] and s[4][0] == ["TOPLEFT", "TOPLEFT", 10, -36, "L"], s
    no_errors(w)


@case
def tool_banner_tool_row_and_body_like_the_swing_practice_window():
    w, c = solo()
    out = c.eval_py(PTS + """
        local win = CreateFrame("Frame", nil, UIParent)
        win:SetSize(550, 500)
        local L = UI:CreateLayout("tool", win, { width = 550, banner = { title = "Twist practice", art = "kara" } })
        local res = { banner = pts(L.banner, { L = L }), bh = L.banner:GetHeight(), bw = L.banner:GetWidth(),
          body = pts(L.body, { L = L }), tb = L.toolbar == nil, innerW = L.innerW }
        local L2 = UI:CreateLayout("tool", win, { toolbar = true })
        res.row = pts(L2.toolbar, { L = L2 })
        res.body2 = pts(L2.body, { L = L2 })
        res.w2 = L2.innerW
        return res""")
    assert out["banner"][0] == ["TOPLEFT", "TOPLEFT", 10, -10, "L"] and out["bh"] == 84, out
    assert out["bw"] == 530 and out["innerW"] == 530 and out["tb"], out
    assert out["body"] == [["TOPLEFT", "TOPLEFT", 10, -102, "L"], ["BOTTOMRIGHT", "BOTTOMRIGHT", -10, 10, "L"]], out
    assert out["row"][0] == ["TOPLEFT", "TOPLEFT", 10, -102, "L"], out
    assert out["body2"][0] == ["TOPLEFT", "TOPLEFT", 10, -136, "L"] and out["w2"] == 520, out
    no_errors(w)


@case
def a_notice_pushes_the_content_down_and_hiding_it_puts_it_back():
    w, c = solo()
    out = c.eval_py(PTS + """
        local res = {}
        for _, kind in ipairs({ "board", "listdetail", "detail", "rail", "tool" }) do
          local L = UI:CreateLayout(kind, host)
          local moved = L.content or (L.scroll or L.body)
          local before = pts(moved, { L = L })
          local n = L:ShowNotice("readonly", "Only officers change these.")
          local h = n:GetHeight()
          local during = pts(moved, { L = L })
          local np = pts(n, { L = L })
          L:ShowNotice("locked", "Locked now.")
          local again = n.kind
          L:HideNotice()
          res[kind] = { before = before, during = during, np = np, h = h, w = n:GetWidth(), kind = again,
            after = pts(moved, { L = L }), shown = n:IsShown() }
        end
        return res""")
    for kind, r in out.items():
        assert r["after"] == r["before"] and not r["shown"] and r["kind"] == "locked", (kind, r)
        shift = round(r["h"]) + 8
        assert r["during"][0][3] == r["before"][0][3] - shift, (kind, r)
        assert r["np"][0][3] <= r["before"][0][3] and r["np"][0][3] - r["h"] >= r["during"][0][3] - 0.01, (kind, r)
    assert out["board"]["np"][0] == ["TOPLEFT", "TOPLEFT", 10, -36, "L"], out["board"]
    assert out["rail"]["np"][0] == ["TOPLEFT", "TOPLEFT", 178, -8, "L"] and out["rail"]["w"] == 602, out["rail"]
    assert out["board"]["w"] == 770, out["board"]
    no_errors(w)


@case
def the_empty_state_replaces_the_content_or_sits_in_a_region():
    w, c = solo()
    out = c.eval_py(PTS + """
        local res = {}
        local clicked = 0
        local L = UI:CreateLayout("listdetail", host, {})
        local e = L:ShowEmpty({ title = "No raids logged yet", text = "The raid leader starts one.",
          action = { text = "Start raid", onClick = function() clicked = clicked + 1 end } })
        res.content = { L.content:IsShown(), e:IsShown(), L:IsEmptyShown(), e.title:GetText(), pts(e, { content = L.content }),
          e.btn and e.btn:IsShown() }
        if e.btn then e.btn:Click() end
        res.clicked = clicked
        L:HideEmpty()
        res.back = { L.content:IsShown(), e:IsShown(), L:IsEmptyShown() }
        local e2 = L:ShowEmpty({ region = "detail", title = "Pick one" })
        res.region = { L.content:IsShown(), L.detail:IsShown(), e2:GetParent() == L.detail, e2.compact,
          pts(e2, { detail = L.detail }) }
        L:HideEmpty()
        local D = UI:CreateLayout("detail", host, {})
        local e3 = D:ShowEmpty({ title = "No answers yet" })
        res.detail = { D.body:IsShown(), D.banner:IsShown(), e3:IsShown(), pts(e3, { body = D.body }) }
        D:HideEmpty()
        res.detailBack = D.body:IsShown()
        local R = UI:CreateLayout("rail", host, { scroll = true })
        R:ShowEmpty({ title = "Nothing" })
        res.rail = { R.scroll:IsShown() }
        R:HideEmpty()
        res.rail[2] = R.scroll:IsShown()
        return res""")
    ct = out["content"]
    assert ct[0] is False and ct[1] and ct[2] and ct[3] == "No raids logged yet" and ct[5], ct
    assert ct[4] == [["TOP", "TOP", 0, -60, "content"]], ct
    assert out["clicked"] == 1 and out["back"] == [True, False, False], out
    r = out["region"]
    assert r[0] and r[1] and r[2] and not r[3] and r[4] == [["TOP", "TOP", 0, -60, "detail"]], r
    d = out["detail"]
    assert d[0] is False and d[1] and d[2] and d[3] == [["TOP", "TOP", 0, -60, "body"]], d
    assert out["detailBack"] and out["rail"] == [False, True], out
    no_errors(w)


@case
def an_unknown_kind_is_an_error_and_every_kind_has_the_api():
    w, c = solo()
    out = c.eval_py(PTS + """
        local ok, err = pcall(UI.CreateLayout, UI, "grid", host)
        local res = { ok = ok, err = tostring(err), kinds = UI.LAYOUT_KINDS, G = UI.LAYOUT.TOP }
        for _, k in ipairs(UI.LAYOUT_KINDS) do
          local L = UI:CreateLayout(k, host)
          res[k] = { L.body ~= nil, type(L.ShowEmpty) == "function", type(L.HideEmpty) == "function",
            type(L.ShowNotice) == "function", type(L.HideNotice) == "function", L.toolbar ~= nil,
            L.banner ~= nil, L.rail ~= nil, L.list ~= nil, L.tabs ~= nil }
        end
        return res""")
    assert out["ok"] is False and "unknown layout kind" in out["err"], out
    assert out["kinds"] == ["board", "listdetail", "detail", "rail", "tool"] and out["G"] == 36, out
    assert out["board"] == [True, True, True, True, True, True, False, False, False, False], out
    assert out["listdetail"] == [True, True, True, True, True, True, True, False, True, False], out
    assert out["detail"] == [True, True, True, True, True, True, True, False, False, True], out
    assert out["rail"] == [True, True, True, True, True, False, False, True, False, False], out
    assert out["tool"] == [True, True, True, True, True, False, True, False, False, False], out
    no_errors(w)


@case
def register_tab_keeps_a_layout_and_the_page_area_comes_from_the_main_window():
    w, c = solo()
    out = c.eval_py("""
        local MF, S = ns.MainFrame, ns.Style
        MF:RegisterTab("zzlayout", "Zz", 999, function(parent)
          local p = CreateFrame("Frame", nil, parent)
          ns.__zzL = ns.UI:CreateLayout("board", p)
          return p
        end, nil, { layout = "board" })
        MF:RegisterTab("zzplain", "Zp", 998, function(parent) return CreateFrame("Frame", nil, parent) end)
        MF:Open("zzlayout")
        local f = DisasterZoneMainFrame
        return { lay = MF:GetTabLayout("zzlayout"), plain = MF:GetTabLayout("zzplain"), none = MF:GetTabLayout("nope"),
          raids = MF:GetTabLayout("raids"), W = S.PAGE_W, H = S.PAGE_H, IW = S.INNER_W,
          fw = f:GetWidth() - 10, built = ns.__zzL ~= nil, ch = f.content:GetHeight() }""")
    assert out["lay"] == "board" and out.get("plain") is None and out.get("none") is None and out.get("raids") == "board", out
    assert out["W"] == 790 and out["H"] == 548 and out["IW"] == 770 and out["fw"] == 790 and out["built"], out
    no_errors(w)


@case
def the_component_gallery_builds_every_component_and_layout_without_an_error():
    import ui_gallery
    w, c = solo()
    for lua in (ui_gallery.GALLERY_COMPONENTS, ui_gallery.GALLERY_LAYOUTS):
        i = lua.rfind("return f")
        name = c.eval_py(lua[:i] + "return f:GetName()")
        assert name.startswith("DisasterZoneGallery"), name
    out = c.eval_py("""
        local G = ns.__gallery
        local res = {}
        for k, L in pairs(G) do res[k] = L.kind end
        res.empty = G.detail:IsEmptyShown()
        res.notice = G.rail.notice and G.rail.notice:IsShown()
        return res""")
    assert out["board"] == "board" and out["listdetail"] == "listdetail" and out["detail"] == "detail", out
    assert out["rail"] == "rail" and out["tool"] == "tool" and out["listdetail3"] == "listdetail", out
    assert out["empty"] and out["notice"], out
    no_errors(w)


if __name__ == "__main__":
    run_all()

"""The page parts of refactor 1.4 phase 2 (UI/Comp/PageParts.lua, REFACTOR_API.md "PageParts.lua"):
UI:CreatePageBanner (hero / tool / strip / a number; art under the shade, the plain card without art, icon tile,
kicker, 19 px title cut to fit, pill after it, sub line, back link, tools at the top right, actions at the bottom right
with the first at the far right, banner.foot), UI:CreateBackLink (chevron + caps text, grey, gold under the mouse) and
UI:CreateSectionHeader ("title": gold 12 with a hairline under it; "caps": grey capitals, a count and a fading rule),
each built with every option, then changed through its setters.

Run: luaenv\\Scripts\\python.exe tests\\style\\test_components_pageparts.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))

from _common import case, run_all, solo, no_errors  # noqa: E402

GOLD = [1, 0.82, 0]
SUB = [0.62, 0.62, 0.62]

# (Lua helpers every case uses: the points of a region, relative to "parent" / a named frame / "other")
PTS = """
local UI = ns.UI
local function pts(t, names)
  local out = {}
  for i = 1, t:GetNumPoints() do
    local p, rel, rp, x, y = t:GetPoint(i)
    local who = "none"
    if rel == t:GetParent() then who = "parent"
    elseif rel and names then for k, v in pairs(names) do if v == rel then who = k end end end
    if who == "none" and rel then who = "other" end
    out[#out + 1] = { p, rp, x, y, who }
  end
  return out
end
local function col(fs) local r, g, b = fs:GetTextColor(); return { r, g, b } end
local function size(fs) return select(2, fs:GetFont()) end
local host = CreateFrame("Frame", nil, UIParent)
host:SetSize(800, 600)
"""


def near(a, b, eps=1e-3):
    return a is not None and len(a) == len(b) and all(abs(x - y) < eps for x, y in zip(a, b))


@case
def back_link_is_a_caps_chevron_link_grey_then_gold_and_clicks():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py(PTS + """
        local clicks = {}
        local b = UI:CreateBackLink(host, "All raids", function(self, btn) clicks[#clicks + 1] = btn or "?" end)
        local res = {
          text = b.text:GetText(), label = b:GetText(), fsIsText = b.fs == b.text, h = b:GetHeight(),
          w = b:GetWidth(), textW = UI:TextWidth(b.text), iconSize = { b.icon:GetWidth(), b.icon:GetHeight() },
          iconTex = __MOCK.S(b.icon).texture, iconPts = pts(b.icon), textPts = pts(b.text, { icon = b.icon }),
          rest = col(b.text), textSize = size(b.text),
        }
        b:GetScript("OnEnter")(b)
        res.hover = col(b.text)
        res.hoverIcon = { b.icon:GetVertexColor() }
        b:GetScript("OnLeave")(b)
        res.left = col(b.text)
        b:GetScript("OnClick")(b, "LeftButton")
        b:SetText("Guest book")
        res.text2 = b.text:GetText()
        res.w2 = b:GetWidth()
        local other = {}
        b:SetOnClick(function() other[#other + 1] = true end)
        b:GetScript("OnClick")(b, "LeftButton")
        res.clicks, res.other = #clicks, #other
        local d = UI:CreateBackLink(host)
        res.default = d.text:GetText()
        res.coded = UI:CapsText("|cffffd100gold|r and |TInterface\\\\Icons\\\\Abc:12|t x")
        return res""")
    assert out["text"] == "ALL RAIDS" and out["label"] == "All raids" and out["fsIsText"], out
    assert out["h"] == 14 and out["iconSize"] == [10, 10], out
    assert out["w"] == int(14 + out["textW"] + 0.5), out
    assert out["iconTex"] == "Interface\\AddOns\\DisasterZone\\Media\\icons" or out["iconTex"], out
    assert out["iconPts"][0][:4] == ["LEFT", "LEFT", 0, 0], out["iconPts"]
    assert out["textPts"][0] == ["LEFT", "RIGHT", 4, 0, "icon"], out["textPts"]
    assert out["textSize"] == 10, out
    assert near(out["rest"], SUB) and near(out["hover"], GOLD) and near(out["hoverIcon"][:3], GOLD), out
    assert near(out["left"], SUB), out
    assert out["text2"] == "GUEST BOOK" and out["w2"] != out["w"], out
    assert out["clicks"] == 1 and out["other"] == 1, out
    assert out["default"] == "BACK", out
    # caps leave the escapes alone (a colour code, an inline texture)
    assert out["coded"] == "|cffffd100GOLD|r AND |TInterface\\Icons\\Abc:12|t X", out["coded"]
    no_errors(w)


@case
def hero_banner_with_every_option_lays_out_like_the_raid_page_hero():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py(PTS + """
        local hits = {}
        local b = UI:CreatePageBanner(host, {
          size = "hero", art = "SerpentshrineCavern", icon = 134400, kicker = "Raid night", title = "Serpentshrine Cavern",
          sub = "Thursday 20:00 - 25 players", pill = { "live", "Live" },
          back = { "All raids", function() hits[#hits + 1] = "back" end },
          tools = { { icon = "more", title = "More", text = "Raid actions", onClick = function() hits[#hits + 1] = "tool" end } },
          actions = {
            { text = "Sign up", kind = "primary", onClick = function() hits[#hits + 1] = "primary" end, tip = "Join it" },
            { text = "Share", onClick = function() hits[#hits + 1] = "share" end, width = 90 },
            { icon = "gear", onClick = function() hits[#hits + 1] = "gear" end, tip = { "Settings", "Open them" } },
            { text = "Off", enabled = false },
          },
        })
        b:SetPoint("TOPLEFT", host, "TOPLEFT", 10, -10)
        local N = { back = b.back, icon = b.icon, title = b.title, a1 = b.actions[1], a2 = b.actions[2],
                    a3 = b.actions[3] }
        local artS = __MOCK.S(b.art)
        local path, l, r, t, bt = ns.ItemDB:RaidArt("SerpentshrineCavern", 768, 126, 0.95)
        local res = {
          size = { b:GetWidth(), b:GetHeight() },
          artShown = b.art:IsShown(), plainShown = b.plain:IsShown(), glowShown = b.glow:IsShown(),
          artTex = artS.texture, artCoords = artS.texcoord, want = { path, l, r, t, bt },
          shade = type(b.shade) == "table" and #b.shade or 0, fadeShown = b.fade:IsShown(),
          kicker = b.kicker:GetText(), kickerC = col(b.kicker), kickerSize = size(b.kicker), kickerPts = pts(b.kicker),
          title = b.title:GetText(), titleC = col(b.title), titleSize = size(b.title), titlePts = pts(b.title),
          sub = b.sub:GetText(), subSize = size(b.sub), subPts = pts(b.sub),
          pillShown = b.pill:IsShown(), pillText = b.pill.fs:GetText(), pillPts = pts(b.pill, N),
          backPts = pts(b.back), backText = b.back.text:GetText(),
          iconPts = pts(b.icon), iconSize = { b.icon:GetWidth(), b.icon:GetHeight() },
          iconTex = __MOCK.S(b.icon.tex).texture, iconCrop = __MOCK.S(b.icon.tex).texcoord,
          nTools = #b.tools, toolPts = pts(b.tools[1]), toolSize = { b.tools[1]:GetWidth(), b.tools[1]:GetHeight() },
          nActs = #b.actions, a1 = pts(b.actions[1]), a2 = pts(b.actions[2], N), a3 = pts(b.actions[3], N),
          a4 = pts(b.actions[4], N),
          a1kind = b.actions[1].kind, a2kind = b.actions[2].kind, a1h = b.actions[1]:GetHeight(),
          a1text = b.actions[1]:GetText(), a2w = b.actions[2]:GetWidth(), a3size = b.actions[3]:GetWidth(),
          a4enabled = b.actions[4]:IsEnabled() and true or false, a1tip = b.actions[1].cdlTip and b.actions[1].cdlTip.title,
          a3tip = b.actions[3].cdlTip and b.actions[3].cdlTip.title, toolTip = b.tools[1].cdlTip and b.tools[1].cdlTip.title,
          foot = pts(b.foot), footH = b.foot:GetHeight(), footLevel = b.foot:GetFrameLevel() > b:GetFrameLevel(),
          textX = b.textX,
        }
        b.back:GetScript("OnClick")(b.back, "LeftButton")
        b.tools[1]:GetScript("OnClick")(b.tools[1], "LeftButton")
        for i = 1, 3 do b.actions[i]:GetScript("OnClick")(b.actions[i], "LeftButton") end
        res.hits = hits
        return res""")
    assert out["size"] == [770, 128], out["size"]
    assert out["artShown"] and not out["plainShown"] and not out["glowShown"], out
    assert out["artTex"] == out["want"][0] and near(out["artCoords"], out["want"][1:]), (out["artCoords"], out["want"])
    assert out["shade"] == 2 and out["fadeShown"] is False, out
    # the back link on the top row, the icon and the text stack under it
    assert out["backPts"][0][:4] == ["TOPLEFT", "TOPLEFT", 14, -11] and out["backText"] == "ALL RAIDS", out
    assert out["iconPts"][0][:4] == ["TOPLEFT", "TOPLEFT", 14, -34] and out["iconSize"] == [44, 44], out
    assert out["iconTex"] == 134400 and near(out["iconCrop"], [0.07, 0.93, 0.07, 0.93]), out
    x = 14 + 44 + 12
    assert out["textX"] == x, out["textX"]
    assert out["kicker"] == "RAID NIGHT" and near(out["kickerC"], GOLD) and out["kickerSize"] == 10, out
    assert out["title"] == "Serpentshrine Cavern" and near(out["titleC"], [1, 1, 1]) and out["titleSize"] == 19, out
    assert out["sub"] == "Thursday 20:00 - 25 players" and out["subSize"] == 11, out
    k, t, s = out["kickerPts"][0], out["titlePts"][0], out["subPts"][0]
    assert k[:3] == ["TOPLEFT", "TOPLEFT", x] and t[:3] == ["TOPLEFT", "TOPLEFT", x] and s[:3] == ["TOPLEFT", "TOPLEFT", x]
    # kicker 10 + 6 + title 19 + 6 + sub 11 = 52 > the 44 px icon: the stack hangs from the top
    assert k[3] == -34 and t[3] == -34 - 10 - 6 and s[3] == -34 - 10 - 6 - 19 - 6, (k, t, s)
    assert out["pillShown"] and out["pillText"] == "Live" and out["pillPts"][0] == ["LEFT", "RIGHT", 10, 0, "title"], out
    # tools at the top right, actions at the bottom right: the first at the far right, each next one left of it
    assert out["nTools"] == 1 and out["toolPts"][0][:4] == ["TOPRIGHT", "TOPRIGHT", -12, -9], out
    assert out["toolSize"] == [22, 22] and out["toolTip"] == "More", out
    assert out["nActs"] == 4 and out["a1"][0][:4] == ["BOTTOMRIGHT", "BOTTOMRIGHT", -12, 12], out["a1"]
    assert out["a2"][0] == ["RIGHT", "LEFT", -6, 0, "a1"] and out["a3"][0] == ["RIGHT", "LEFT", -6, 0, "a2"], out
    assert out["a4"][0] == ["RIGHT", "LEFT", -6, 0, "a3"], out
    assert out["a1kind"] == "primary" and out["a2kind"] == "secondary" and out["a1h"] == 24, out
    assert out["a1text"] == "Sign up" and out["a2w"] == 90 and out["a3size"] == 24, out
    assert out["a4enabled"] is False and out["a1tip"] == "Join it" and out["a3tip"] == "Settings", out
    assert out["foot"][0][:4] == ["BOTTOMLEFT", "BOTTOMLEFT", 0, 0] and out["foot"][1][:4] == ["BOTTOMRIGHT", "BOTTOMRIGHT", 0, 0]
    assert out["footH"] == 26 and out["footLevel"], out
    assert out["hits"] == ["back", "tool", "primary", "share", "gear"], out["hits"]
    no_errors(w)


@case
def banner_setters_change_and_take_away_each_part():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py(PTS + """
        local b = UI:CreatePageBanner(host, { title = "Guest", kicker = "Guest book", sub = "Seen 3 times",
          back = { text = "Guests", onClick = function() end }, icon = "person",
          actions = { { text = "Invite", kind = "primary" } } })
        b:SetWidth(600)
        local res = { plain = b.plain:IsShown(), glow = b.glow:IsShown(), art = b.art:IsShown(),
                      iconAtlas = __MOCK.S(b.icon.tex).texture == UI.ICON_ATLAS }
        b:SetTitle("Another name")
        b:SetSub("Seen once")
        b:SetKicker("Pug")
        b:SetPill("rank", "Ranked")
        res.set = { b.title:GetText(), b.sub:GetText(), b.kicker:GetText(), b.pill:IsShown(), b.pill.fs:GetText() }
        b:SetArt({ "Interface\\\\Glues\\\\LoadingScreens\\\\X", 0.1, 0.9, 0.2, 0.8 }, true)
        local s = __MOCK.S(b.art)
        res.artTable = { b.art:IsShown(), b.plain:IsShown(), s.texture, s.texcoord, s.desat }
        b:SetArt("BlackTemple")
        res.artKey = { __MOCK.S(b.art).texture, __MOCK.S(b.art).desat }
        b:SetBack("Board", function() end)
        res.back = b.back.text:GetText()
        b:SetActions({ { text = "One" }, { text = "Two", kind = "primary" } })
        res.acts = { #b.actions, b.actions[1]:GetText(), b.actions[2]:GetText(), b.actions[2].kind }
        b:SetTools({ { icon = "gear" }, { title = "More" } })
        res.tools = #b.tools
        res.toolsTwo = pts(b.tools[2], { t1 = b.tools[1] })
        -- take everything away
        b:SetSub(nil); b:SetKicker(""); b:SetPill(nil); b:SetBack(nil); b:SetIcon(nil); b:SetArt(nil)
        b:SetActions(nil); b:SetTools({})
        res.gone = { b.sub:IsShown(), b.kicker:IsShown(), b.pill:IsShown(), b.back:IsShown(), b.icon:IsShown(),
                     b.art:IsShown(), b.plain:IsShown(), #b.actions, #b.tools }
        local anyShown = false
        for _, f in ipairs(b.btnPool) do anyShown = anyShown or f:IsShown() end
        for _, f in ipairs(b.toolPool) do anyShown = anyShown or f:IsShown() end
        res.poolShown = anyShown
        -- only the title: it sits at the top margin and the left margin
        res.titleOnly = pts(b.title)
        b:SetTitle(nil)
        res.titleGone = b.title:IsShown()
        -- a long title is cut to the room the tools and the pill leave
        b:SetTitle(string.rep("Very long title ", 20))
        b:SetPill("live", "Live")
        res.cut = b.title:GetText() ~= string.rep("Very long title ", 20)
        res.titleW = b.title:GetWidth()
        res.pillW = b.pill:GetWidth()
        return res""")
    assert out["plain"] and out["glow"] and not out["art"] and out["iconAtlas"], out
    assert out["set"] == ["Another name", "Seen once", "PUG", True, "Ranked"], out["set"]
    a = out["artTable"]
    assert a[0] and not a[1] and a[2] == "Interface\\Glues\\LoadingScreens\\X" and near(a[3], [0.1, 0.9, 0.2, 0.8]), a
    assert a[4] is True, a
    assert out["artKey"][0] == 131826 and out["artKey"][1] is True, out["artKey"]     # desaturate kept
    assert out["back"] == "BOARD", out
    assert out["acts"] == [2, "One", "Two", "primary"], out["acts"]
    assert out["tools"] == 2 and out["toolsTwo"][0] == ["RIGHT", "LEFT", -4, 0, "t1"], out
    assert out["gone"] == [False, False, False, False, False, False, True, 0, 0], out["gone"]
    assert out["poolShown"] is False, out
    assert out["titleOnly"][0][:4] == ["TOPLEFT", "TOPLEFT", 14, -14], out["titleOnly"]
    assert out["titleGone"] is False, out
    assert out["cut"] and out["titleW"] <= 600 - 14 - 16 - (out["pillW"] + 10) + 1, out
    no_errors(w)


@case
def tool_strip_and_numeric_sizes_and_a_reserved_foot():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py(PTS + """
        local tool = UI:CreatePageBanner(host, { size = "tool", title = "Blessings", kicker = "Class tools",
          icon = "gear", width = 500 })
        local strip = UI:CreatePageBanner(host, { size = "strip", title = "Polls", sub = "2 open",
          back = { "Back", function() end }, icon = "ballot",
          actions = { { text = "New poll", kind = "primary" } }, tools = { { icon = "more" } } })
        local num = UI:CreatePageBanner(host, { size = 100, title = "Custom" })
        local foot = UI:CreatePageBanner(host, { size = "hero", title = "Raid", art = 548, footH = 26,
          actions = { { text = "Go", kind = "primary" } } })
        local N = { back = strip.back, icon = strip.icon, a1 = strip.actions[1] }
        return {
          toolH = tool:GetHeight(), toolW = tool:GetWidth(), toolTitleC = col(tool.title), toolTitleSize = size(tool.title),
          toolIcon = { tool.icon:GetWidth(), tool.icon:GetHeight() },
          stripH = strip:GetHeight(), stripTitleSize = size(strip.title), stripIcon = strip.icon:GetWidth(),
          stripBack = pts(strip.back), stripIconPts = pts(strip.icon), stripA1 = pts(strip.actions[1]),
          stripTool = pts(strip.tools[1], N), stripTitle = pts(strip.title), stripSub = pts(strip.sub),
          stripBackW = strip.back:GetWidth(), stripTextX = strip.textX,
          numH = num:GetHeight(), numTitleSize = size(num.title),
          footFade = foot.fade:IsShown(), footA1 = pts(foot.actions[1]), footArt = __MOCK.S(foot.art).texture,
        }""")
    assert out["toolH"] == 84 and out["toolW"] == 500, out
    assert near(out["toolTitleC"], GOLD) and out["toolTitleSize"] == 19 and out["toolIcon"] == [40, 40], out
    assert out["stripH"] == 46 and out["stripTitleSize"] == 13 and out["stripIcon"] == 26, out
    # a strip: back link, icon and text in one row on its middle; actions then tools from the right
    assert out["stripBack"][0][:4] == ["LEFT", "LEFT", 14, 0], out["stripBack"]
    ix = 14 + out["stripBackW"] + 12
    assert out["stripIconPts"][0][:4] == ["LEFT", "LEFT", ix, 0], out["stripIconPts"]
    assert out["stripTextX"] == ix + 26 + 12, out
    assert out["stripA1"][0][:4] == ["RIGHT", "RIGHT", -12, 0], out["stripA1"]
    assert out["stripTool"][0] == ["RIGHT", "LEFT", -4, 0, "a1"], out["stripTool"]
    # title 13 + 2 + sub 11 = 26, centred in 46: the stack starts 10 px down
    assert out["stripTitle"][0][:4] == ["TOPLEFT", "TOPLEFT", out["stripTextX"], -10], out["stripTitle"]
    assert out["stripSub"][0][:4] == ["TOPLEFT", "TOPLEFT", out["stripTextX"], -10 - 13 - 2], out["stripSub"]
    assert out["numH"] == 100 and out["numTitleSize"] == 19, out
    # the reserved foot: the art fades out and the actions sit above the tabs
    assert out["footFade"] is True and out["footA1"][0][:4] == ["BOTTOMRIGHT", "BOTTOMRIGHT", -12, 12 + 26], out
    assert out["footArt"] == 131832, out          # an instance id finds its raid's art
    no_errors(w)


@case
def banner_relays_out_when_resized():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py(PTS + """
        local b = UI:CreatePageBanner(host, { title = string.rep("Wide ", 60), art = "Karazhan", width = 300 })
        local w1 = b.title:GetWidth()
        local c1 = __MOCK.S(b.art).texcoord
        b:SetWidth(700)
        local s = b:GetScript("OnSizeChanged")
        if s then s(b, 700, b:GetHeight()) end
        return { w1 = w1, w2 = b.title:GetWidth(), c1 = c1, c2 = __MOCK.S(b.art).texcoord }""")
    assert out["w2"] > out["w1"], out
    assert out["c1"] != out["c2"], out          # the art's crop follows the shape
    no_errors(w)


@case
def section_header_title_style_with_count_right_text_and_link():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py(PTS + """
        local hits = {}
        local h = UI:CreateSectionHeader(host, "Upcoming", { count = 3, right = "This week", width = 400,
          action = { text = "See all", onClick = function() hits[#hits + 1] = "all" end, tip = "Every event" } })
        local N = { title = h.title, action = h.action, right = h.right }
        local res = {
          size = { h:GetWidth(), h:GetHeight() }, style = h.style,
          title = h.title:GetText(), titleC = col(h.title), titleSize = size(h.title), titlePts = pts(h.title),
          count = h.count:GetText(), countC = col(h.count), countPts = pts(h.count, N),
          right = h.right:GetText(), rightPts = pts(h.right, N),
          action = h.action and h.action.fs:GetText(), actionPts = pts(h.action), actionTip = h.action.cdlTip.title,
          rule = pts(h.rule), ruleC = __MOCK.S(h.rule).color,
        }
        h.action:GetScript("OnClick")(h.action, "LeftButton")
        h:GetScript("OnSizeChanged")
        h:SetTitle("Past"); h:SetCount(nil); h:SetRight(""); h:SetAction(nil)
        res.after = { h.title:GetText(), h.count:IsShown(), h.right:IsShown(), h.action == nil, h.link:IsShown() }
        res.hits = hits
        local bare = UI:CreateSectionHeader(host, "Plain", { rule = false })
        res.bareRule = bare.rule == nil
        res.bareW = bare:GetWidth()
        return res""")
    assert out["size"] == [400, 24] and out["style"] == "title", out
    assert out["title"] == "Upcoming" and near(out["titleC"], GOLD) and out["titleSize"] == 12, out
    assert out["titlePts"][0][:4] == ["LEFT", "LEFT", 2, 1], out["titlePts"]
    assert out["count"] == "3" and near(out["countC"], SUB) and out["countPts"][0] == ["LEFT", "RIGHT", 6, 0, "title"]
    assert out["action"] == "See all" and out["actionPts"][0][:4] == ["RIGHT", "RIGHT", -2, 1], out
    assert out["actionTip"] == "Every event", out
    assert out["right"] == "This week" and out["rightPts"][0] == ["RIGHT", "LEFT", -8, 0, "action"], out
    assert out["rule"] == [["BOTTOMLEFT", "BOTTOMLEFT", 0, 0, "parent"], ["BOTTOMRIGHT", "BOTTOMRIGHT", 0, 0, "parent"]]
    assert near(out["ruleC"], [1, 1, 1, 0.07]), out
    assert out["after"] == ["Past", False, False, True, False], out["after"]
    assert out["hits"] == ["all"], out
    assert out["bareRule"] and out["bareW"] == 200, out
    no_errors(w)


@case
def section_header_caps_style_with_a_fading_rule_and_an_icon_action():
    w, c = solo("Rai", guild_rank=0, tick=2)
    out = c.eval_py(PTS + """
        local hits = {}
        local h = UI:CreateSectionHeader(host, "Greater blessings", { style = "caps", count = "4/5", right = "Auto",
          width = 300, action = { icon = "gear", onClick = function() hits[#hits + 1] = "gear" end, tip = "Options" } })
        local N = { title = h.title, count = h.count, action = h.action, right = h.right }
        local res = {
          size = { h:GetWidth(), h:GetHeight() }, style = h.style,
          title = h.title:GetText(), titleC = col(h.title), titleSize = size(h.title), titlePts = pts(h.title),
          countPts = pts(h.count, N), countC = col(h.count),
          rightPts = pts(h.right, N), rightSize = size(h.right),
          actionSize = { h.action:GetWidth(), h.action:GetHeight() }, actionPts = pts(h.action),
          actionAtlas = __MOCK.S(h.action.icon).texture == UI.ICON_ATLAS,
          rule = pts(h.rule, N), ruleGrad = __MOCK.S(h.rule).gradient, ruleH = h.rule:GetHeight(),
        }
        h.action:GetScript("OnClick")(h.action, "LeftButton")
        h:SetCount(nil)
        res.ruleNoCount = pts(h.rule, N)
        h:SetRight(nil)
        res.ruleNoRight = pts(h.rule, N)
        h:SetAction(nil)
        res.ruleBare = pts(h.rule, N)
        h:SetAction({ text = "Reset", menu = function(root) hits[#hits + 1] = "menu" end })
        res.link = { h.action == h.link, h.link:IsShown(), h.iconBtn:IsShown() }
        h:SetTitle("in |cffffd100gold|r")
        res.capsCoded = h.title:GetText()
        res.hits = hits
        return res""")
    assert out["size"] == [300, 18] and out["style"] == "caps", out
    assert out["title"] == "GREATER BLESSINGS" and near(out["titleC"], SUB) and out["titleSize"] == 9.5, out
    assert out["titlePts"][0][:4] == ["LEFT", "LEFT", 2, 0], out["titlePts"]
    assert out["countPts"][0] == ["LEFT", "RIGHT", 8, 0, "title"] and near(out["countC"], [0.44, 0.44, 0.46]), out
    assert out["actionSize"] == [18, 18] and out["actionPts"][0][:4] == ["RIGHT", "RIGHT", -2, 0], out
    assert out["actionAtlas"], out
    assert out["rightPts"][0] == ["RIGHT", "LEFT", -8, 0, "action"] and out["rightSize"] == 10, out
    assert out["rule"] == [["LEFT", "RIGHT", 10, 0, "count"], ["RIGHT", "LEFT", -10, 0, "right"]], out["rule"]
    g = out["ruleGrad"]
    assert g[0] == "HORIZONTAL" and near(g[1], [1, 1, 1, 0.14]) and near(g[2], [1, 1, 1, 0.04]), g
    assert out["ruleH"] == 1, out
    assert out["ruleNoCount"][0] == ["LEFT", "RIGHT", 10, 0, "title"], out["ruleNoCount"]
    assert out["ruleNoRight"][1] == ["RIGHT", "LEFT", -8, 0, "action"], out["ruleNoRight"]
    assert out["ruleBare"][1][:4] == ["RIGHT", "RIGHT", -2, 0], out["ruleBare"]
    assert out["link"] == [True, True, False], out["link"]
    assert out["capsCoded"] == "IN |cffffd100GOLD|r", out
    assert out["hits"] == ["gear"], out
    no_errors(w)


if __name__ == "__main__":
    run_all()

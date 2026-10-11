"""The component gallery of refactor 1.4 (ui_audit states "Gallery - components" and "Gallery - layouts").

Two plain windows that build every shared component (UI/Comp/*.lua: every kind and option) and every page layout
(UI:CreateLayout's five kinds, filled with sample content) so their look can be judged with ui_audit --look, next to
the pages they replace. dev/tests/style/test_layouts.py builds them too (no errors, nothing missing).

GALLERY_COMPONENTS / GALLERY_LAYOUTS: Lua run in a client (ns = the addon); each returns the window it built.
"""

# Shared helpers: a window, a caption over each sample.
_HEAD = r"""
local UI, S = ns.UI, ns.Style
local function win(name, title, w, h)
  local f = _G[name] or UI:CreateWindow(name, title, w, h, { noSavePosition = true })
  f:ClearAllPoints()
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  f:Show()
  return f
end
local function cap(parent, text, x, y)
  local fs = UI:Text(parent, "caps", "DIM")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
  fs:SetText(text:upper())
  return fs
end
"""

GALLERY_COMPONENTS = _HEAD + r"""
local f = win("DisasterZoneGalleryComponents", "Components", 1800, 840)
if f.built then return f end
f.built = true
local c = f.content
local COL = { 12, 612, 1212 }
local W = 576

-- column 1 ---------------------------------------------------------------------------------------------------
local x, y = COL[1], 10
cap(c, "Pills - every kind", x, y)
local kinds = { "bis", "alt", "os", "ok", "warn", "mute", "live", "rank", "review", "back", "changed", "draft", "ended" }
local px, py = x, y + 16
for _, k in ipairs(kinds) do
  local p = UI:CreatePill(c, k, k:sub(1, 1):upper() .. k:sub(2))
  p:SetPoint("TOPLEFT", c, "TOPLEFT", px, -py)
  px = px + (p:GetWidth() or 50) + 6
  if px > x + W - 70 then px, py = x, py + 24 end
end
y = py + 32

cap(c, "Chips - track, selected, icon, class, you, clickable", x, y)
local chips = {
  { text = "Tank" , rgb = { 0.4, 0.72, 1 } },
  { text = "Healer", rgb = { 0.3, 0.9, 0.4 }, selected = true },
  { text = "Kara", icon = "Interface\\Icons\\INV_Misc_Key_07" },
  { text = "Me (class)", key = ns.Util.PlayerKey() },
  { text = "You", kind = "you" },
  { text = "Click me", onClick = function() end },
}
px = x
for _, o in ipairs(chips) do
  local ch = UI:CreateChip(c, o)
  ch:SetPoint("TOPLEFT", c, "TOPLEFT", px, -(y + 16))
  px = px + (ch:GetWidth() or 60) + 6
end
y = y + 50

cap(c, "Segments - frame, pill, fixed width, disabled item, accent OK, read-only", x, y)
local items = { { key = "a", label = "Accept" }, { key = "t", label = "Tentative" }, { key = "b", label = "Bench" },
  { key = "x", label = "Absent" } }
local s1 = UI:CreateSegments(c, items, function() end, { selected = "t" })
s1:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 16))
local s2 = UI:CreateSegments(c, { "Day", "Week", "Month" }, function() end, { look = "pill", selected = 2 })
s2:SetPoint("TOPLEFT", c, "TOPLEFT", x + 330, -(y + 16))
local s3 = UI:CreateSegments(c, items, function() end, { width = 300, accent = "OK", selected = "a" })
s3:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 46))
s3:SetItemEnabled("x", false)
local s4 = UI:CreateSegments(c, { "Mine", "Guild" }, nil, { readOnly = true, selected = 1 })
s4:SetPoint("TOPLEFT", c, "TOPLEFT", x + 330, -(y + 46))
local steps = UI:CreateSegments(c, 300, 22)
steps:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 76))
if steps.Set then steps:Set(4, 2) end
y = y + 112

cap(c, "Section headers - title / caps, count, right, action", x, y)
local h1 = UI:CreateSectionHeader(c, "This week", { count = 4, right = "since 21 Sep",
  action = { text = "All", onClick = function() end } })
h1:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 16))
h1:SetPoint("TOPRIGHT", c, "TOPLEFT", x + W, -(y + 16))
local h2 = UI:CreateSectionHeader(c, "Blessings", { style = "caps", count = "3 / 5",
  action = { icon = UI.ICON.gear, onClick = function() end, tip = "Settings" } })
h2:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 50))
h2:SetPoint("TOPRIGHT", c, "TOPLEFT", x + W, -(y + 50))
local h3 = UI:CreateSectionHeader(c, "No rule", { rule = false, right = "right text" })
h3:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 76))
h3:SetPoint("TOPRIGHT", c, "TOPLEFT", x + W, -(y + 76))
y = y + 112

cap(c, "Back link", x, y)
local back = UI:CreateBackLink(c, "All raids", function() end)
back:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 16))
y = y + 44

cap(c, "Notices - readonly, locked, loading, info (wrapping)", x, y)
local ny = y + 16
for _, n in ipairs({ { "readonly", "Only officers change the loot rules: you see them as they are." },
    { "locked", "The raid is locked: ask who runs it to join." },
    { "loading", "Waiting for the guild's data..." },
    { "info", "A long notice wraps to the width it is given, and its height follows the text, so it never clips "
      .. "a second line like this one." } }) do
  local nt = UI:CreateNotice(c, n[1], n[2])
  nt:SetPoint("TOPLEFT", c, "TOPLEFT", x, -ny)
  nt:SetWidth(W)
  ny = ny + (nt:GetHeight() or 26) + 6
end
y = ny + 10

cap(c, "Rail nav - icons, counts, the open one", x, y)
local rail = UI:CreateRailNav(c, { { key = "alerts", label = "Alerts" },
  { key = "notify", label = "Notifications", count = 3 }, { key = "rules", label = "Group loot rules" },
  { key = "about", label = "About", icon = "Interface\\Icons\\INV_Misc_Note_01" } }, function() end,
  { selected = "notify", width = 180 })
rail:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 16))
rail:SetCount("notify", 3, true)
rail:SetCount("rules", 12)

-- column 2 ---------------------------------------------------------------------------------------------------
x, y = COL[2], 10
cap(c, "Cards - card (titled), inset, quiet (left / right fade)", x, y)
local cards = { { tone = "card", title = "A card" }, { tone = "inset", title = "Inset", titleStyle = "caps" },
  { tone = "quiet" }, { tone = "quiet", fade = "right" } }
for i, o in ipairs(cards) do
  local cd = UI:CreateCard(c, o)
  cd:SetSize(138, 80)
  cd:SetPoint("TOPLEFT", c, "TOPLEFT", x + (i - 1) * 146, -(y + 16))
  local t = UI:Text(cd.body, "small", "SUB")
  t:SetPoint("TOPLEFT", cd.body, "TOPLEFT", 0, 0)
  t:SetText(o.tone .. (o.fade and (" / " .. o.fade) or ""))
end
y = y + 112

cap(c, "Art rows - art + icon + pill + right, selected, title only, stripe", x, y)
local rows = {
  { art = "kara", icon = "Interface\\Icons\\INV_Misc_Key_07", title = "Kara full clear + Gruul if time",
    sub = "Mon 21 Sep - 19:45 - Shadowmelder", right = "6 / 10", pill = { "live", "Live" } },
  { art = "ssc", icon = 135226, title = "SSC progression night", sub = "Thu 24 Sep - 20:00", right = "3 / 25",
    selected = true },
  { art = "bt", title = "Black Temple (a title alone)" },
}
for i, d in ipairs(rows) do
  local r = UI:CreateArtRow(c, { selectable = true, stripe = true })
  r:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 16 + (i - 1) * 52))
  r:SetWidth(W)
  r:SetData(d)
  if r.SetStripe then r:SetStripe(i) end
end
y = y + 16 + 3 * 52 + 16

cap(c, "Row looks - plain, stripe, selected, rule", x, y)
for i = 1, 4 do
  local r = CreateFrame("Button", nil, c)
  r:SetSize(W, S.ROW.list)
  r:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 16 + (i - 1) * S.ROW.list))
  UI:DecorateRow(r, { selectable = true, stripe = true, rule = true })
  r:SetStripe(i)
  if i == 3 then r:SetSelected(true) end
  local t = UI:Text(r, "body")
  t:SetPoint("LEFT", r, "LEFT", 10, 0)
  t:SetText(({ "Victhar", "Shadowmelder", "Vaenyria (selected)", "Thunderhoofx" })[i])
end
y = y + 16 + 4 * S.ROW.list + 16

cap(c, "Empty states - full (with action), compact", x, y)
local e1 = UI:CreateEmptyState(c, { title = "No raids logged yet", text = "The raid leader starts one with Start raid "
  .. "(or /dz raid start).", action = { text = "Start raid", onClick = function() end } })
e1:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 20))
e1:SetBoxWidth(300)
local e2 = UI:CreateEmptyState(c, { compact = true, glyph = UI.ICON.notes, title = "Nothing here",
  text = "A compact one, inside a list." })
e2:SetPoint("TOPLEFT", c, "TOPLEFT", x + 320, -(y + 20))
e2:SetBoxWidth(250)
y = y + 230

cap(c, "Toolbar buttons - primary, secondary, danger, menu, more", x, y)
local b1 = UI:CreateSleekButton(c, "New raid", 96, S.BTN_H, function() end, "primary")
b1:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 16))
local b2 = UI:CreateSleekButton(c, "Examples", 96, S.BTN_H, function() end)
b2:SetPoint("LEFT", b1, "RIGHT", 6, 0)
local b3 = UI:CreateSleekButton(c, "Delete", 80, S.BTN_H, function() end, "danger")
b3:SetPoint("LEFT", b2, "RIGHT", 6, 0)
local b4 = UI:CreateSleekMenuButton(c, "All lineups", 120, function() end, S.BTN_H)
b4:SetPoint("LEFT", b3, "RIGHT", 6, 0)
local b5 = UI:CreateTipIconButton(c, S.BTN_H, UI.ICON.more, "More", nil, function() end)
b5:SetPoint("LEFT", b4, "RIGHT", 6, 0)

-- column 3 ---------------------------------------------------------------------------------------------------
x, y = COL[3], 10
cap(c, "Page banner - hero: art, back, kicker, title + pill, sub, tools, actions", x, y)
local ban = UI:CreatePageBanner(c, { size = "hero", width = W, art = "kara", kicker = "In 4 min  Mon 21 Sep",
  title = "Kara full clear + Gruul if time", pill = { "live", "Live" }, sub = "Karazhan - 10-player - Shadowmelder leads",
  back = { "All raids", function() end }, tools = { { icon = UI.ICON.more, title = "More", menu = function() end } },
  actions = { { text = "Sign up", kind = "primary", onClick = function() end }, { text = "Bench", onClick = function() end } } })
ban:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 16))
ban:SetWidth(W)
y = y + 16 + S.BANNER.hero + 16

cap(c, "Page banner - hero with an icon tile, no art", x, y)
local ban2 = UI:CreatePageBanner(c, { size = "hero", width = W, icon = "Interface\\Icons\\INV_Sword_27",
  title = "Friday duel cup", pill = { "rank", "Ranked" }, sub = "16 duelists - Ring of Trials, Nagrand",
  actions = { { text = "Watch", kind = "primary", onClick = function() end } } })
ban2:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 16))
ban2:SetWidth(W)
y = y + 16 + S.BANNER.hero + 16

cap(c, "Page banner - tool (84)", x, y)
local ban3 = UI:CreatePageBanner(c, { size = "tool", width = W, art = "kara", icon = 135961,
  title = "Twist practice", sub = "Six lessons, from the swing to the twist.",
  actions = { { text = "Start", kind = "primary", onClick = function() end } } })
ban3:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 16))
ban3:SetWidth(W)
y = y + 16 + S.BANNER.tool + 16

cap(c, "Page banner - strip (46)", x, y)
local ban4 = UI:CreatePageBanner(c, { size = "strip", width = W, art = "ssc", back = { "Back", function() end },
  title = "Lady Vashj", sub = "Serpentshrine Cavern",
  actions = { { text = "Award", kind = "primary", onClick = function() end } } })
ban4:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 16))
ban4:SetWidth(W)
y = y + 16 + S.BANNER.strip + 16

local themes = ns.Themes and ns.Themes.kinds and ns.Themes.kinds.meters
if themes and UI.CreateThemeTiles then
  cap(c, "Theme tiles (meters)", x, y)
  local tiles = UI:CreateThemeTiles(c, "meters", { tileW = 84, tileH = 64 })
  tiles:SetPoint("TOPLEFT", c, "TOPLEFT", x, -(y + 16))
  tiles:SetWidth(W)
end
return f
"""

GALLERY_LAYOUTS = _HEAD + r"""
local f = win("DisasterZoneGalleryLayouts", "Layouts", 1700, 790)
if f.built then return f end
f.built = true
local c = f.content
local K = 0.66                     -- each page at two thirds (five 790 x 548 pages fit the screen)
local PW, PH = S.PAGE_W, S.PAGE_H
local function page(i, title)
  local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
  local holder = CreateFrame("Frame", nil, c)
  holder:SetSize(PW * K, PH * K + 18)
  holder:SetPoint("TOPLEFT", c, "TOPLEFT", 10 + col * (PW * K + 22), -(8 + row * (PH * K + 34)))
  cap(holder, title, 0, 0)
  local pg = CreateFrame("Frame", nil, holder)
  pg:SetScale(K)
  pg:SetSize(PW, PH)
  pg:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -16 / K)
  UI:Fill(pg, "SURFACE_WINDOW", "BACKGROUND")
  UI:AddEdges(pg, "BORDER")
  UI:SetEdgeColor(pg, S:Color("EDGE"))
  return pg
end
local function text(parent, style, s, x, y, color)
  local t = UI:Text(parent, style, color)
  t:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
  t:SetText(s)
  return t
end
local function rows(parent, n, w, titles, sub)
  for i = 1, n do
    local r = UI:CreateArtRow(parent, { selectable = true })
    r:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((i - 1) * 52))
    r:SetWidth(w)
    r:SetData({ art = ({ "kara", "ssc", "tk", "bt", "hyjal" })[(i - 1) % 5 + 1], title = titles[(i - 1) % #titles + 1],
      sub = sub, selected = i == 2 })
  end
end
local menu = function(root) root:CreateButton("Hide", function() end) end
local G = {}

-- Board: Raids > Upcoming / Events
local p1 = page(1, "board - toolbar, hero, sections, side card")
local L1 = UI:CreateLayout("board", p1, { hero = { art = "kara", kicker = "Next up", title = "Kara full clear",
  sub = "Mon 21 Sep - 19:45", actions = { { text = "Sign up", kind = "primary", onClick = function() end } } },
  side = true })
L1.toolbar:SetTabs({ "Upcoming", "Teams", "Strategies", { key = "Guests", count = 2 }, "Raid log" })
local lineups = UI:CreateSleekMenuButton(L1.toolbar, "All lineups", 116, menu)
L1.toolbar:SetFilters({ lineups })
L1.toolbar:SetMore(menu)
L1.toolbar:SetPrimary({ text = "New raid", onClick = function() end })
local h = UI:CreateSectionHeader(L1.body, "This week", { count = 3 })
h:SetPoint("TOPLEFT", L1.body, "TOPLEFT", 0, 0)
h:SetPoint("TOPRIGHT", L1.body, "TOPRIGHT", 0, 0)
local rb = CreateFrame("Frame", nil, L1.body)
rb:SetPoint("TOPLEFT", L1.body, "TOPLEFT", 0, -30)
rb:SetSize(L1.bodyW, 200)
rows(rb, 3, L1.bodyW, { "Kara full clear", "SSC progression night", "TK farm" }, "Thu 24 Sep - 20:00")
L1.side:SetTitle("Season 1")
text(L1.side.body, "body", "#9   45 points", 0, 0)
G.board = L1

-- List + detail: Raids > Guests
local p2 = page(2, "listdetail - list, detail banner, tabs on its foot")
local L2 = UI:CreateLayout("listdetail", p2, { listWidth = 250, banner = { art = "ssc", icon = 135940,
  title = "Pugsyhealer", sub = "Priest", actions = { { text = "Add to a raid", kind = "primary", onClick = function() end },
  { text = "Recruit", onClick = function() end } }, tools = { { icon = UI.ICON.more, title = "More", menu = menu } } },
  tabs = { { key = "raids", text = "Raids", count = { 1, 1 } }, { key = "items", text = "Items", count = 1 } } })
L2.toolbar:SetTabs({ "Upcoming", "Teams", "Strategies", "Guests", "Raid log", { key = "raids", text = "Raids", small = true },
  { key = "att", text = "Attendance", small = true }, { key = "rev", text = "Reviews", small = true }, selected = "Guests" })
L2.toolbar:SelectTab("raids")
local search = UI:CreateSearchBox(L2.list, L2.listW, function() end, "Search or add a player")
search:SetPoint("TOPLEFT", L2.list, "TOPLEFT", 0, 0)
local lr = CreateFrame("Frame", nil, L2.list)
lr:SetPoint("TOPLEFT", L2.list, "TOPLEFT", 0, -32)
lr:SetSize(L2.listW, 300)
rows(lr, 5, L2.listW, { "Belgaegroot", "Ciciocul", "Damazzus", "Dyrma", "Ellesara" }, "Guest Thu 24 Sep - SSC")
local h2 = UI:CreateSectionHeader(L2.body, "Raids", { right = "since 21 Sep" })
h2:SetPoint("TOPLEFT", L2.body, "TOPLEFT", 0, 0)
h2:SetPoint("TOPRIGHT", L2.body, "TOPRIGHT", 0, 0)
G.listdetail = L2

-- Detail: the raid page
local p3 = page(3, "detail - back, hero, tabs, tool row, body")
local L3 = UI:CreateLayout("detail", p3, { top = 36, back = { "All raids", function() end }, banner = { art = "kara",
  kicker = "In 4 min  Mon 21 Sep - 16:28", title = "Kara full clear + Gruul if time",
  sub = "Karazhan - 10-player - Shadowmelder leads", tools = { { icon = UI.ICON.more, title = "More", menu = menu } } },
  tabs = { { key = "signups", text = "Sign-ups", count = { 6, 10 } }, { key = "groups", text = "Groups" },
    { key = "assign", text = "Assignments", count = { 16, 16 } } } })
L3.toolbar:SetText("6 accepted")
L3.toolbar:SetPrimary({ text = "Add players", kind = "secondary", icon = 19, onClick = function() end })
local e3 = L3:ShowEmpty({ title = "No answers yet", text = "Players show here by role as they answer." })
G.detail = L3

-- Rail: Settings
local p4 = page(4, "rail - side menu, notice, titled sections")
local L4 = UI:CreateLayout("rail", p4, { items = { { key = "alerts", label = "Alerts" },
  { key = "notify", label = "Notifications" }, { key = "rules", label = "Group loot rules" }, { key = "rolls", label = "Rolls" },
  { key = "about", label = "About" } }, selected = "alerts", scroll = true })
L4:ShowNotice("readonly", "Only officers change these: you see them as they are.")
local h4 = UI:CreateSectionHeader(L4.body, "Alerts", { rule = false })
h4:SetPoint("TOPLEFT", L4.body, "TOPLEFT", 0, 0)
h4:SetPoint("TOPRIGHT", L4.body, "TOPRIGHT", 0, 0)
for i, s in ipairs({ "Boss drop panel", "Sound with drop alerts", "Chat message for BiS drops" }) do
  local r = CreateFrame("Frame", nil, L4.body)
  r:SetPoint("TOPLEFT", L4.body, "TOPLEFT", 0, -(32 + (i - 1) * 44))
  r:SetSize(L4.bodyW, 44)
  UI:DecorateRow(r, { rule = true, hover = false })
  text(r, "emph", s, 0, 6)
  text(r, "small", "Opens on boss drops for the Loot Council.", 0, 24)
end
G.rail = L4

-- Tool window: Swing practice / Blessings
local p5 = page(5, "tool - banner, tool row, body (window content 540)")
local tw = CreateFrame("Frame", nil, p5)
tw:SetPoint("TOPLEFT", p5, "TOPLEFT", 0, 0)
tw:SetSize(540, PH)
local L5 = UI:CreateLayout("tool", tw, { width = 540, toolbar = true, banner = { art = "kara", icon = 135961,
  title = "Twist practice", sub = "Six lessons, from the swing to the twist." } })
L5.toolbar:SetTabs({ "Lessons", "Free play", "Keys" })
L5.toolbar:SetPrimary({ text = "Start", onClick = function() end })
local h5 = UI:CreateSectionHeader(L5.body, "Lessons", { style = "caps", count = "2 / 6" })
h5:SetPoint("TOPLEFT", L5.body, "TOPLEFT", 0, 0)
h5:SetPoint("TOPRIGHT", L5.body, "TOPRIGHT", 0, 0)
G.tool = L5

-- List + detail, 3 columns (Atlas), with a notice and an empty detail
local p6 = page(6, "listdetail - nav column, notice, empty detail")
local L6 = UI:CreateLayout("listdetail", p6, { navWidth = true, listWidth = 220, banner = false })
L6.toolbar:SetTabs({ "Raids", "Dungeons", "Vendors" })
L6.toolbar:SetPrimary({ text = "Shopping list", onClick = function() end })
L6:ShowNotice("loading", "Waiting for the item data...")
local rail6 = UI:CreateRailNav(L6.nav, { { key = "kara", label = "Karazhan" }, { key = "gruul", label = "Gruul's Lair" },
  { key = "mag", label = "Magtheridon" } }, function() end, { selected = "kara", width = L6.navW })
rail6:SetPoint("TOPLEFT", L6.nav, "TOPLEFT", 0, 0)
local lr6 = CreateFrame("Frame", nil, L6.list)
lr6:SetPoint("TOPLEFT", L6.list, "TOPLEFT", 0, 0)
lr6:SetSize(L6.listW, 200)
rows(lr6, 3, L6.listW, { "Attumen", "Moroes", "Maiden" }, "Karazhan")
L6:ShowEmpty({ region = "detail", compact = true, title = "Pick a boss", text = "Its loot shows here." })
G.listdetail3 = L6
ns.__gallery = G
return f
"""


def gallery(which):
    """A ui_audit state: Gina's screen with the gallery window `which` ("components" | "layouts")."""
    lua = GALLERY_COMPONENTS if which == "components" else GALLERY_LAYOUTS

    def fn(w, c):
        import ui_audit_states as st
        g = c["Gina"]
        st.demo_off(w, c)
        st.close_all(g)
        g.eval(lua)
        w.tick(0.5)
        return g
    return fn

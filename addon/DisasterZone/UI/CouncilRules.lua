if DisasterZoneBoot and DisasterZoneBoot.Run("UI/CouncilRules.lua", ...) then return end -- DisasterZone: UI/CouncilRules.lua
-- Council > Rules (1.3.5, the user's pick 2026-10-11): every loot rule of the guild, on two pages with small tabs at the
-- top (the user asked to split them for room, 2026-10-11):
--   Picking the winner: the GM's loot rules (Guild:GetLootRules) as a column of choices on the left (it scrolls: more
--   options can join), and on the right a "Try it" card - the drop panel's own roll rows (DropPanel:NewPreviewRow) on an
--   example roll, ranked by Roll:RankRows with the rules as they are being edited. Rows that move show it and the line
--   above the card says what changed against the saved rules; the line under the rows says why the suggestion is who it
--   is. The GM saves (Save & share, top right; shared with the guild on RLL); the rest of the council sees them
--   read-only.
--   Prized items: the loot rules session's view (PrizedUI:Mount, its list and the picked item) over the whole width,
--   Add item top right.
-- CouncilUI hosts it as its view "rules".
local addonName, ns = ...

local CouncilRulesUI = ns:NewModule("CouncilRulesUI")

local UI = ns.UI
local S = ns.Style

local floor, max, min = math.floor, math.max, math.min
local format, tconcat = string.format, table.concat

-- (readability pass after the user's in-game shot, "barely readable": the picked choice gold, sub-lines 11 px light
-- grey, the choices in one right-hand column of equal buttons, the example's scenarios on their own row, 5 rows)
-- (two pages, 2026-10-11: the choices stacked in a left column - title, the line under it, the buttons across the
-- column - and the example over the right column's whole height)
-- (the visual pass, 2026-10-11 "give it some love, same fidelity as other pages": a banner of raid art with the status
-- and Save & share, icon tiles on the choices, a gold thumb gliding between a line's choices, the example's rows
-- sliding to their new places when a choice re-ranks them)
local K = { W = S.INNER_W, GAP = 8, TABS_H = 28, BAN_H = 76, LEFT_W = 304, STEP_H = 70, SEG_H = 22, CARD_PAD = 12,
            PREVIEW_ROWS = 8, ITEM = 30687,    -- (Ravager's Bracers: the example roll's item)
            ICON_X = 34, GLIDE = 0.22, SLIDE = 0.30 }
K.CHOICE_W = K.LEFT_W - 32                      -- the buttons, across the column (inside its padding and scroll bar)
local MEDIA = "Interface\\AddOns\\DisasterZone\\Media\\"
-- each line's icon (UI.ICON names; the art pack 7 ones fall back without it)
local STEP_ICON = { f = "calendar", s = "ballot", l = "bis", w = "trophy", o = "stopwatch", y = "team", q = "prized" }
local ICON_FALLBACK = { ballot = "poll", stopwatch = "calendar", prized = "trophy" }
K.RIGHT_X = K.LEFT_W + K.GAP
K.RIGHT_W = K.W - K.RIGHT_X                     -- 458: the drop panel's rows fit
local ICON_TINT = { 1, 0.86, 0.4 }            -- an atlas icon in a gold ring (the banner's)
local WHY = { 0.91, 0.85, 0.66 }              -- the line under the example: why the suggestion is who it is

-- The choices, in the order the lines show them (keys of Guild.LOOT_RULES).
local STEPS = {
    { key = "f", title = "Attendance floor", sub = "below it: listed, never suggested",
      opts = { { 0, "Off" }, { 50, "50%" }, { 60, "60%" }, { 75, "75%" } },
      tip = "Players whose attendance (Raid log, the last 8 raids that expected them) is under it are still listed "
          .. "with a warning, but never the suggested winner, and their votes don't decide. The council can still "
          .. "award them by hand. (Never suggested either way: a pass, a player who left, a class that can't use "
          .. "it.)" },
    { key = "s", title = "When votes split", sub = "votes decide; who rolled comes first",
      opts = { { "r", "Highest roll" }, { "p", "Council picks" } },
      tip = "Several players with the most votes: the highest roll among them is suggested (whoever didn't roll "
          .. "never is), or nobody is suggested and the council picks one." },
    { key = "l", title = "Before anyone votes", sub = "the suggestion until the council votes",
      opts = { { "l", "Lists first" }, { "r", "Roll only" } },
      tip = "Lists first: BiS mains, then BiS alts, then off-spec lists, then everyone else. Roll only: the lists "
          .. "don't matter, the highest roll wins." },
    { key = "w", title = "Then, among them", sub = "who wins inside a list",
      opts = { { "r", "Highest roll" }, { "d", "Driest first" } },
      tip = "The highest roll wins, or the player with the most raids since their last item (the roll breaks a tie). "
          .. "With Longest use on, it comes first: then this." },
    { key = "o", title = "Longest use", sub = "phases on their list, counted up to",
      opts = { { 0, "Off" }, { 3, "P3" }, { 4, "P4" }, { 5, "P5" } },
      tip = "Inside a list, the player who keeps the item on their BiS list for more phases goes first (then the "
          .. "line above, then the roll). Counted from the guild's phase up to the one you pick: with P4, a pick kept "
          .. "P2-P4 and replaced in P5 counts the same as one kept in P5 too. Off: phases don't matter." },
    { key = "y", title = "Since loot counts", sub = "raids since their last item",
      opts = { { "n", "Nights there" }, { "a", "Any night" } },
      tip = "The SINCE LOOT column (the dry streak): only nights they were really there for (a boss kill or half "
          .. "the night), or any night they showed up. Offspec, disenchant and guild bank items never end a streak." },
}

-- 1.3.5: a prized item rolled out, for players who don't meet its rules
STEPS[#STEPS + 1] = { key = "q", title = "Prized: not qualified", sub = "players who can't get a rolled one",
    opts = { { "h", "A notice" }, { "s", "Roll window" } },
    tip = "When a prized item is rolled out, players who don't meet its rules can only pass. A notice: no roll "
        .. "window for them, a short notice says why (it fades, and stays in the bell). Roll window: they get it "
        .. "anyway, with Roll greyed out. Players whose client can't tell get the roll window either way." }

-- The example roll: name, class, spec, tier (1 BiS, 2 Alt, 3 OS, 4 not on a list), attendance %, raids since loot
-- (really there / came at all), roll (nil = no roll), times rolled, bad range, passed.
-- (12: the last phase they keep it on their list, from P2: Longest use counts up to the GM's phase)
local EXAMPLE = {
    { "Orinel", "WARLOCK", "Destruction", 4, 60, 5, 5, 93, nil, nil, nil, 2 },
    { "Brakka", "WARRIOR", "Protection", 4, 88, 1, 1, nil, nil, nil, nil, 4 },
    { "Quillon", "DRUID", "Restoration", 3, 14, 1, 5, nil, nil, nil, nil, 3 },
    { "Kaelyn", "SHAMAN", "Restoration", 4, 78, 0, 0, 98, 2, nil, nil, 3 },
    { "Caelith", "PALADIN", "Protection", 3, 100, 1, 1, 27, nil, nil, nil, 5 },
    { "Mirabel", "MAGE", "Frost", 4, 75, 5, 5, 8, nil, nil, nil, 4 },
    { "Aldrin", "WARRIOR", "Protection", 2, 100, 3, 3, nil, nil, nil, nil, 5 },
    { "Isolde", "PRIEST", "Holy", 4, 69, 0, 0, 11, 1, { 1, 50 }, nil, 2 },
    { "Elowen", "HUNTER", "Marksmanship", 4, 100, 0, 0, nil, 1, nil, true, 2 },
    { "Grimtusk", "ROGUE", "Combat", 4, 88, 6, 6, nil, 1, nil, true, 3 },
}
local SCENES = {
    { key = "split", label = "Split vote", votes = { Quillon = 1, Orinel = 1, Brakka = 1 } },
    { key = "one", label = "Clear vote", votes = { Quillon = 2, Orinel = 1 } },
    { key = "none", label = "No votes", votes = {} },
}

local view                    -- the frame (CouncilRulesUI:Create)
local state = { page = "winner", sel = nil, scene = "split", draft = nil }

-- The rows' slide when a choice re-ranks them: one shared driver of eased tweens.
-- TODO(refactor): move into Widgets (a shared UI:Tween(key, dur, fn, instant))
local tweens = {}
local driver
local function EaseOut(t) return 1 - (1 - t) ^ 3 end
local function StepTweens(_, dt)
    local snap = {}
    for k, tw in pairs(tweens) do snap[k] = tw end
    for k, tw in pairs(snap) do
        if tweens[k] == tw then
            tw.t = tw.t + (dt or 0)
            local pr = min(1, tw.t / tw.dur)
            tw.fn(EaseOut(pr))
            if pr >= 1 then tweens[k] = nil end
        end
    end
    if not next(tweens) and driver then driver:SetScript("OnUpdate", nil) end
end
-- instant: jump to the end (the first paint, a hidden page)
local function Tween(key, dur, fn, instant)
    local old = tweens[key]
    if old then
        tweens[key] = nil
        old.fn(1)
    end
    if instant then
        fn(1)
        return
    end
    tweens[key] = { t = 0, dur = max(0.001, dur), fn = fn }
    fn(0)
    driver = driver or CreateFrame("Frame")
    driver:SetScript("OnUpdate", StepTweens)
end

local function IconName(name)
    if ICON_FALLBACK[name] and not (ns.HasAssets and ns:HasAssets(7)) then return ICON_FALLBACK[name] end
    return name
end

local function AtlasIcon(tex, name, color)
    if name == "bis" then
        tex:SetTexture(MEDIA .. "Icons\\bis")
        tex:SetTexCoord(0, 1, 0, 1)
    else
        local I = UI.ICON
        tex:SetTexture(UI.ICON_ATLAS)
        tex:SetTexCoord(unpack(UI:IconCoords(I[IconName(name)] or I.notes)))
    end
    tex:SetVertexColor(S:Color(color or { 1, 1, 1 }))
end

local function Rules()
    local G = ns.Guild
    return G and G.GetLootRules and G:GetLootRules() or { f = 0, s = "r", l = "l", w = "r", y = "n", o = 0, q = "h" }
end

local function CanEdit()
    local G = ns.Guild
    return G and G.CanEditLootRules and G:CanEditLootRules() or false
end

local function Copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

local function Same(a, b)
    for k in pairs(ns.Guild and ns.Guild.LOOT_RULES or { f = 1, s = 1, l = 1, w = 1, y = 1 }) do
        if a[k] ~= b[k] then return false end
    end
    return true
end

-- The rules as being edited: the draft once the GM picked something, else the saved ones.
local function Draft()
    return state.draft or Copy(Rules())
end

---------------------------------------------------------------------------
-- The example roll, ranked
---------------------------------------------------------------------------

local function ExampleRows(rules)
    local scene
    for _, s in ipairs(SCENES) do
        if s.key == state.scene then scene = s end
    end
    local votes = scene and scene.votes or {}
    local rows = {}
    local me = ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey()
    local realm = me and me:match("%-(.+)$") or "Example"   -- (my realm: no "another realm" star on the names)
    for i, p in ipairs(EXAMPLE) do
        local name, cls, spec, tier, att, dryN, dryA, roll, count, bad, pass, keepTo = unpack(p, 1, 12)
        local dryCount = (rules.y == "a") and dryA or dryN
        local upTo = tonumber(rules.o) or 0
        local longevity = (keepTo and upTo > 0) and math.max(0, math.min(keepTo, upTo) - 2 + 1) or 0
        local key = name .. "-" .. realm
        rows[i] = { key = key, name = name, classFile = cls, spec = spec, tier = tier, os = tier == 3 or nil,
                    which = (tier == 2 and "alt") or (tier <= 3 and "main") or nil, roll = roll,
                    invalid = bad ~= nil, min = bad and bad[1], max = bad and bad[2], count = count or (roll and 1 or 0),
                    response = pass and "pass" or (roll and "roll" or nil), inRaid = true, votes = votes[name] or 0,
                    voters = {}, att = att, dry = dryCount, longevity = longevity, equippedList = {},
                    preview = { att = att, dry = { nights = dryCount, bosses = dryCount * 4, came = dryA } } }
    end
    local R = ns.Roll
    if R and R.RankRows then R:RankRows(rows, { rules = rules }) end
    return rows
end

local function Suggested(rows)
    for _, r in ipairs(rows) do
        if r.suggested then return r end
    end
end

-- Why the suggestion is who it is (or why there is none), one or two lines.
local function WhyText(rows, rules)
    local s = Suggested(rows)
    local split = {}
    for _, r in ipairs(rows) do
        if r.split then split[#split + 1] = r end
    end
    local gold = S:Hex("GOLD") .. "%s|r"
    if #split > 1 then
        if not s then
            if rules.s == "p" then
                return format("Votes split %d ways: " .. gold .. " (Award opens the list).", #split, "the council picks")
            end
            return format("Votes split %d ways and none of them rolled: " .. gold .. ".", #split, "the council picks")
        end
        local others = {}
        for _, r in ipairs(split) do
            if r ~= s then others[#others + 1] = r.name end
        end
        local rolled = 0
        for _, r in ipairs(split) do
            if r.roll and not r.invalid then rolled = rolled + 1 end
        end
        return format(gold .. ": %d vote, tied with %s · rolled %d, %s.", s.name, s.votes, tconcat(others, " and "),
            s.roll, rolled > 1 and "the highest of them" or "the only one of them who rolled")
    end
    if s and s.votes > 0 then return format(gold .. ": the most votes (%d).", s.name, s.votes) end
    if s then
        local bits = {}
        if rules.l ~= "r" and s.tier < 4 then
            bits[#bits + 1] = ({ "BiS list", "BiS alt list", "off-spec list" })[s.tier] .. ", before players not on a list"
        end
        if rules.w == "d" and (s.dry or 0) > 0 then bits[#bits + 1] = format("%d raids without loot", s.dry) end
        if (tonumber(rules.o) or 0) > 0 and (s.longevity or 0) > 0 then
            bits[#bits + 1] = format("on their list to P%d", 1 + s.longevity)
        end
        bits[#bits + 1] = "rolled " .. tostring(s.roll)
        return "No votes yet. " .. format(gold, s.name) .. ": " .. tconcat(bits, " · ") .. "."
    end
    return "Nobody can be suggested yet."
end

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------

-- A row of choices (UI:CreateSegments): one framed control of equal parts, the picked one under a gold thumb that
-- glides to a new pick; the others grey text, a soft wash under the mouse. Read-only (not the GM): the same look, no
-- clicks (seg:SetEnabled(false)).
local function Seg(parent, key, opts, onPick, width)
    width = width or K.CHOICE_W
    width = floor(width / #opts) * #opts
    local items = {}
    for i, o in ipairs(opts) do items[i] = { key = o[1], label = o[2] } end
    local s = UI:CreateSegments(parent, items, function(value) onPick(key, value) end,
        { width = width, h = K.SEG_H })
    s.key = key
    return s
end

local function Pick(key, value)
    if not CanEdit() then return end
    state.draft = state.draft or Copy(Rules())
    state.draft[key] = value
    CouncilRulesUI:Refresh()
end

-- The two pages' tabs (small, on the layout's toolbar) and its main action: Add item (Prized items).
local function BuildTop(v)
    -- (top -8: the toolbar row is 36 high, the pages start where they did under the 28 px tabs row - the prized
    -- items' add sheet needs all of that height)
    local L = UI:CreateLayout("board", v, { pad = 0, top = -(36 - K.TABS_H), bottom = 0, width = K.W })
    v.layout = L
    L.toolbar:SetTabs({ { key = "winner", text = "Picking the winner", small = true },
        { key = "prized", text = "Prized items", small = true }, selected = "winner" },
        function(key) CouncilRulesUI:SetPage(key) end)
    v.tabWinner = L.toolbar:GetTab("winner")
    v.tabPrized = L.toolbar:GetTab("prized")
    v.add = L.toolbar:SetPrimary({ text = "Add item", tip = "A drop with stricter loot rules (attendance, rank, a "
        .. "queue...). Raiders see them.", tipTitle = "Add a prized item", onClick = function()
            if ns.PrizedUI and ns.PrizedUI.StartAdd then ns.PrizedUI:StartAdd() end
        end })
    v.add:Hide()
    return L.body
end

-- Undo / Save & share on the banner (the GM's draft).
local function BannerActions(b, dirty)
    if dirty then
        b:SetActions({
            { text = "Save & share", kind = "primary", width = 100, onClick = function() CouncilRulesUI:Save() end },
            { text = "Undo", width = 60, onClick = function()
                state.draft = nil
                CouncilRulesUI:Refresh()
            end },
        })
    else
        b:SetActions(nil)
    end
    view.save, view.undo = b.actions[1], b.actions[2]
end

-- Picking the winner: the banner, the choices (left, scrolling) and the example (right).
local function RulesBanner(page)
    local b = UI:CreatePageBanner(page, { size = K.BAN_H, art = "kara", artUnder = true, width = K.W,
        icon = IconName("ballot"), kicker = "Guild loot rules", title = "Picking the winner", titleColor = "TEXT",
        sub = "How the drop panel suggests who gets an item" })
    if b.icon then b.icon.tex:SetVertexColor(S:Color(ICON_TINT)) end
    b:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    b:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
    page.banner = b
end

local function BuildWinner(v, host)
    local page = CreateFrame("Frame", nil, host)
    page:SetAllPoints(host)
    v.winner = page
    RulesBanner(page)
    local top = K.BAN_H + K.GAP
    -- the choices
    local left = UI:CreateCard(page, { tone = "inset" })
    left:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -top)
    left:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
    left:SetWidth(K.LEFT_W)
    page.left = left
    local sf = UI:CreateScrollFrame(left)
    sf:SetPoint("TOPLEFT", left, "TOPLEFT", 12, -6)
    sf:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", -20, 6)
    local body = CreateFrame("Frame", nil, sf)
    body:SetSize(K.CHOICE_W, 10)
    sf:SetScrollChild(body)
    page.scroll, page.body = sf, body
    page.steps = {}
    local y = 0
    for i, st in ipairs(STEPS) do
        local f = CreateFrame("Frame", nil, body)
        f:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
        f:SetSize(K.CHOICE_W, K.STEP_H)
        if i < #STEPS then UI:Rule(f, { bottom = 0, layer = "BORDER" }) end
        -- the icon tile
        f.box = f:CreateTexture(nil, "BACKGROUND")
        f.box:SetSize(26, 26)
        f.box:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -6)
        f.box:SetColorTexture(S:Color("CARD"))
        local boxEdge = CreateFrame("Frame", nil, f)
        boxEdge:SetAllPoints(f.box)
        UI:AddEdges(boxEdge, "BORDER")
        f.icon = f:CreateTexture(nil, "ARTWORK")
        f.icon:SetSize(15, 15)
        f.icon:SetPoint("CENTER", f.box)
        AtlasIcon(f.icon, STEP_ICON[st.key] or "notes", "TEXT")
        f.title = UI:Text(f, "title", "TEXT", { text = st.title })
        f.title:SetPoint("TOPLEFT", f, "TOPLEFT", K.ICON_X, -5)
        f.sub = UI:Text(f, "sub", nil, { width = K.CHOICE_W - K.ICON_X, text = st.sub })
        f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
        local hit = CreateFrame("Frame", nil, f)
        hit:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        hit:SetSize(K.CHOICE_W, 38)
        UI:AttachTooltip(hit, st.title, { { st.tip, "TEXT", wrap = true } })
        f.seg = Seg(f, st.key, st.opts, Pick)
        f.seg:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -40)
        f.def = st
        page.steps[i] = f
        y = y + K.STEP_H
    end
    body:SetHeight(y + 4)
    -- the example
    local right = CreateFrame("Frame", nil, page)
    right:SetPoint("TOPLEFT", page, "TOPLEFT", K.RIGHT_X, -top)
    right:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    page.right = right
    right.kicker = UI:Text(right, "small", "GOLD", { text = "TRY IT" })
    right.kicker:SetPoint("TOPLEFT", right, "TOPLEFT", 2, -2)
    right.change = UI:Text(right, "body", nil, { width = K.RIGHT_W - 280 })
    right.change:SetPoint("TOPLEFT", right.kicker, "BOTTOMLEFT", 0, -4)
    local scenes = {}
    for i, sc in ipairs(SCENES) do scenes[i] = { sc.key, sc.label } end
    right.scenes = Seg(right, "scene", scenes, function(_, value)
        state.scene = value
        CouncilRulesUI:Refresh()
    end, 264)
    right.scenes:SetPoint("TOPRIGHT", right, "TOPRIGHT", 0, -2)
    local c = UI:CreateCard(right, { tone = "card" })
    c:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -32)
    c:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 0)
    c:SetClipsChildren(true)
    page.card = c
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(26, 26)
    c.icon:SetPoint("TOPLEFT", c, "TOPLEFT", K.CARD_PAD, -8)
    c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    c.name = UI:Text(c, "emph", "GOLD")
    c.name:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 8, 0)
    c.sub = UI:Text(c, "body")
    c.sub:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -3)
    c.rows, c.byKey = {}, {}
    c.more = UI:Text(c, "sub")
    c.why = UI:Text(c, "emph", WHY, { wrap = true, width = K.RIGHT_W - 2 * K.CARD_PAD })
    c.never = UI:Text(c, "sub", nil, { width = K.RIGHT_W - 2 * K.CARD_PAD,
        text = "Never suggested: a pass, a player who left, a class that can't use it." })
    c.never:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", K.CARD_PAD, 8)
end

function CouncilRulesUI:Create(parent)
    if view then
        if view:GetParent() ~= parent then view:SetParent(parent) end
        return view
    end
    local v = CreateFrame("Frame", "DisasterZoneCouncilRules", parent)
    v:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -36)
    v:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -10, 10)
    view = v
    local host = BuildTop(v)
    BuildWinner(v, host)
    v.prized = CreateFrame("Frame", nil, host)
    v.prized:SetAllPoints(host)
    for _, m in ipairs({ "LOOT_RULES_CHANGED", "PRIZED_UPDATED", "RAIDLOG_CHANGED", "DEMO_TOGGLED" }) do
        ns:On(m, function() CouncilRulesUI:RequestRefresh() end)
    end
    v:SetScript("OnShow", function() CouncilRulesUI:Refresh() end)
    return v
end

---------------------------------------------------------------------------
-- Filling
---------------------------------------------------------------------------

local function MoveMark(r)
    if not r.move then
        r.move = UI:Text(r, "small")
        r.move:SetPoint("RIGHT", r, "RIGHT", 0, 0)
    end
    return r.move
end

local function FillWinner(v)
    local page = v.winner
    local saved, draft = Rules(), Draft()
    local edit = CanEdit()
    local G = ns.Guild
    local by = G and G.GetLootRulesBy and G:GetLootRulesBy()
    for _, f in ipairs(page.steps) do
        f.seg:Select(draft[f.def.key])
        if f.seg.enabled ~= edit then f.seg:SetEnabled(edit) end
    end
    local right = page.right
    right.scenes:Select(state.scene)
    local dirty = edit and not Same(saved, draft)
    -- the banner: who set them, the status, Save & share
    local b = page.banner
    b:SetSub(edit and "How the drop panel suggests who gets an item · you set these for the guild"
        or ("How the drop panel suggests who gets an item · set by " .. (by and ns.Util.ShortName(by) or "the Guild Master")))
    BannerActions(b, dirty)
    if dirty then
        b:SetPill("warn", "Not shared yet")
    elseif edit then
        b:SetPill("ok", "Shared with the guild")
    else
        b:SetPill("mute", "Read-only")
    end
    -- the example roll, with the draft and with the saved rules (what moved)
    local rows = ExampleRows(draft)
    local base = ExampleRows(saved)
    local basePos = {}
    for i, r in ipairs(base) do basePos[r.key] = i end
    local c = page.card
    c.icon:SetTexture(UI:ItemIcon(K.ITEM))
    c.name:SetText(UI:ItemText(K.ITEM) or "Ravager's Bracers")
    local split = 0
    for _, r in ipairs(rows) do if r.split then split = split + 1 end end
    c.sub:SetText(S:Wrap("WARN", "Rolls closed") .. "  " .. S:Wrap("SUB", "·  an example roll")
        .. (split > 1 and ("  " .. S:Wrap("WARN", format("·  votes split %d ways", split))) or ""))
    local DP = ns.DropPanel
    local P = DP and DP.PREVIEW
    local top = 8 + 26 + 8
    local n = min(#rows, K.PREVIEW_ROWS)
    local rowH = P and P.ROW_H or 22
    local headH = P and P.HEAD_H or 13
    if DP and DP.PreviewHead then DP:PreviewHead(c, top, n * rowH) end
    local session = { state = "closed" }
    local moved = 0
    local visible = c:IsVisible()
    local seen = {}
    for i, row in ipairs(rows) do
        if basePos[row.key] ~= i then moved = moved + 1 end
        -- one frame per player, so a re-rank slides it from its old place to the new one
        local r = c.byKey[row.key]
        if i <= n and DP and DP.NewPreviewRow then
            if not r then
                r = DP:NewPreviewRow(c)
                c.byKey[row.key] = r
                c.rows[#c.rows + 1] = r
            end
            seen[r] = true
            DP:FillPreviewRow(r, row, session, K.ITEM)
            local toY = -(top + headH + (i - 1) * rowH)
            local fromY = r.cdlY or toY
            local fresh = not r:IsShown()
            r.cdlY = toY
            r:Show()
            Tween(r, K.SLIDE, function(e)
                local yy = fromY + (toY - fromY) * e
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", c, "TOPLEFT", K.CARD_PAD, yy)
                r:SetPoint("TOPRIGHT", c, "TOPRIGHT", -K.CARD_PAD, yy)
                if fresh and visible then r:SetAlpha(e) end
            end, not visible or fromY == toY and not fresh)
            local mk = MoveMark(r)
            local dpos = (basePos[row.key] or i) - i
            if dirty and dpos > 0 then
                mk:SetText(S:Wrap("OK", "+" .. dpos))
            elseif dirty and dpos < 0 then
                mk:SetText(S:Wrap("BAD", dpos))
            else
                mk:SetText("")
            end
        end
    end
    for _, r in ipairs(c.rows) do
        if not seen[r] then
            r:Hide()
            r.cdlY = nil
        end
    end
    local y = top + headH + n * rowH
    c.more:ClearAllPoints()
    c.more:SetPoint("TOPLEFT", c, "TOPLEFT", K.CARD_PAD + 22, -(y + 4))
    c.more:SetText(#rows > n and format("+%d more", #rows - n) or "")
    c.why:ClearAllPoints()
    c.why:SetPoint("TOPLEFT", c, "TOPLEFT", K.CARD_PAD, -(y + 24))
    c.why:SetText(WhyText(rows, draft))
    -- what the draft changes against the saved rules
    if dirty then
        local was, now = Suggested(base), Suggested(rows)
        local w, nn = was and was.name or "nobody", now and now.name or "nobody"
        local head = (w == nn) and (nn .. " stays on top") or ("was " .. w .. ", now " .. nn)
        -- (how many moved: the rows' own +/- marks say it)
        right.change:SetText(S:Wrap("OK", head))
    else
        right.change:SetText(S:Wrap("SUB", edit and "Pick a choice: the rows re-rank."
            or "The example uses the guild's rules."))
    end
end

function CouncilRulesUI:Refresh()
    local v = view
    if not v or not v:IsVisible() then return end
    local winner = state.page ~= "prized"
    v.layout.toolbar:SelectTab(winner and "winner" or "prized")
    v.winner:SetShown(winner)
    v.prized:SetShown(not winner)
    if winner then
        v.add:Hide()
        FillWinner(v)
    else
        local P = ns.Prized
        v.add:SetShown(P and P.CanEdit and P:CanEdit() or false)
        local PU = ns.PrizedUI
        if PU and PU.Mount then
            PU:Mount(v.prized, { x = -10 })
            if state.sel and PU.Select and PU.GetSelected and PU:GetSelected() ~= state.sel then PU:Select(state.sel) end
        end
    end
end

function CouncilRulesUI:RequestRefresh()
    if ns.Util and ns.Util.Debounce then
        ns.Util.Debounce("council-rules", 0.1, function() CouncilRulesUI:Refresh() end)
    else
        self:Refresh()
    end
end

-- "winner" (Picking the winner) or a prized record id (Prized items, that item).
function CouncilRulesUI:Select(id)
    if id == nil or id == "winner" then
        state.page = "winner"
    else
        state.page, state.sel = "prized", id
    end
    self:Refresh()
end

-- "winner", or the prized item shown on the Prized items page.
function CouncilRulesUI:GetSelected()
    if state.page ~= "prized" then return "winner" end
    local PU = ns.PrizedUI
    return (PU and PU.GetSelected and PU:GetSelected()) or state.sel
end

-- "winner" | "prized": the page.
function CouncilRulesUI:SetPage(page)
    state.page = page == "prized" and "prized" or "winner"
    self:Refresh()
end

function CouncilRulesUI:GetPage() return state.page == "prized" and "prized" or "winner" end

-- The draft of the loot rules (a copy) and whether it differs from the saved ones.
function CouncilRulesUI:GetDraft()
    return Copy(Draft()), not Same(Rules(), Draft())
end

function CouncilRulesUI:SetChoice(key, value) Pick(key, value) end

function CouncilRulesUI:SetScene(key)
    state.scene = key
    self:Refresh()
end

-- The example roll ranked with the draft: { { key, name, suggested, split, lowAtt }, ... } (tests).
function CouncilRulesUI:GetExample()
    local out = {}
    for i, r in ipairs(ExampleRows(Draft())) do
        out[i] = { name = r.name, suggested = r.suggested or false, split = r.split or false, low = r.lowAtt or false }
    end
    return out, WhyText(ExampleRows(Draft()), Draft())
end

function CouncilRulesUI:Save()
    local G = ns.Guild
    if not (G and G.SetLootRules) then return false end
    local ok, err = G:SetLootRules(Draft())
    if ok then
        state.draft = nil
        ns:Print("Loot rules saved and shared with the guild.")
    else
        ns:Print("Loot rules not saved: %s", tostring(err))
    end
    self:Refresh()
    return ok, err
end

function CouncilRulesUI:OnInit()
    ns:On("LOOT_RULES_CHANGED", function()
        -- (a change from the GM elsewhere: an untouched draft follows it)
        if state.draft and Same(state.draft, Rules()) then state.draft = nil end
    end)
end

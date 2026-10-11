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

local floor, max, min = math.floor, math.max, math.min
local format, tconcat = string.format, table.concat

-- (readability pass after the user's in-game shot, "barely readable": the picked choice gold, sub-lines 11 px light
-- grey, the choices in one right-hand column of equal buttons, the example's scenarios on their own row, 5 rows)
-- (two pages, 2026-10-11: the choices stacked in a left column - title, the line under it, the buttons across the
-- column - and the example over the right column's whole height)
local K = { W = 770, GAP = 8, TABS_H = 28, LEFT_W = 304, STEP_H = 68, SEG_H = 22, CARD_PAD = 12,
            PREVIEW_ROWS = 10, ITEM = 30687 }   -- (Ravager's Bracers: the example roll's item)
K.CHOICE_W = K.LEFT_W - 32                      -- the buttons, across the column (inside its padding and scroll bar)
K.RIGHT_X = K.LEFT_W + K.GAP
K.RIGHT_W = K.W - K.RIGHT_X                     -- 458: the drop panel's rows fit
local GOLD, GREY, DIM = { 1, 0.82, 0 }, { 0.72, 0.72, 0.75 }, { 0.50, 0.50, 0.53 }
local CARD_BG, EDGE = { 0.10, 0.10, 0.12, 0.92 }, { 0.34, 0.34, 0.38, 0.5 }

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
    { key = "o", title = "Longest use", sub = "phases they keep it on their list, counted up to",
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

local function UI() return ns.UI end

local function Text(parent, font, size, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    if size then
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags) end
    end
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if r then fs:SetTextColor(r, g, b) end
    return fs
end

local function Fill(frame, c, layer)
    local t = frame:CreateTexture(nil, layer or "BACKGROUND")
    t:SetAllPoints()
    t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    return t
end

local function Edge(frame, c)
    local function line(p1, p2, w, h)
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetColorTexture(c[1], c[2], c[3], c[4])
        t:SetPoint(p1)
        t:SetPoint(p2)
        if w then t:SetWidth(w) else t:SetHeight(h) end
    end
    line("TOPLEFT", "TOPRIGHT", nil, 1)
    line("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    line("TOPLEFT", "BOTTOMLEFT", 1)
    line("TOPRIGHT", "BOTTOMRIGHT", 1)
end

local function Tip(frame, title, text)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, 0.82, 0)
        if text then GameTooltip:AddLine(text, 0.85, 0.85, 0.85, true) end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
    local gold = "|cffffd100%s|r"
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

-- A row of choices: equal buttons over K.CHOICE_W; the picked one gold-edged with a faint gold fill and white text,
-- the others dark with grey text. Read-only (not the GM): the same look, no clicks.
local function SegButton(parent, w, label, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, K.SEG_H)
    b.fill = b:CreateTexture(nil, "BACKGROUND")
    b.fill:SetAllPoints()
    b.edges = {}
    for i, pts in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" },
                           { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local t = b:CreateTexture(nil, "BORDER")
        t:SetPoint(pts[1])
        t:SetPoint(pts[2])
        if i <= 2 then t:SetHeight(1) else t:SetWidth(1) end
        b.edges[i] = t
    end
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    b.label = Text(b, "GameFontHighlightSmall", 11)
    b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.label:SetText(label)
    b:SetScript("OnClick", onClick)
    function b:Paint(on)
        local e = on and { 1, 0.82, 0, 0.95 } or { 0.30, 0.30, 0.34, 1 }
        if on then self.fill:SetColorTexture(0.32, 0.25, 0.05, 0.85) else self.fill:SetColorTexture(0.09, 0.09, 0.10, 0.95) end
        for _, t in ipairs(self.edges) do t:SetColorTexture(e[1], e[2], e[3], e[4]) end
        if on then self.label:SetTextColor(1, 1, 1) else self.label:SetTextColor(0.62, 0.62, 0.65) end
    end
    return b
end

local function Seg(parent, key, opts, onPick, width)
    local s = CreateFrame("Frame", nil, parent)
    s.buttons, s.key = {}, key
    width = width or K.CHOICE_W
    local w = floor((width + #opts - 1) / #opts)
    for i, o in ipairs(opts) do
        local b = SegButton(s, w, o[2], function() onPick(key, o[1]) end)
        b:SetPoint("LEFT", s, "LEFT", (i - 1) * (w - 1), 0)
        b.value = o[1]
        s.buttons[i] = b
    end
    s:SetSize(#opts * (w - 1) + 1, K.SEG_H)
    function s:Paint(value, enabled)
        for _, b in ipairs(self.buttons) do
            b:Paint(b.value == value)
            b:EnableMouse(enabled and true or false)
        end
    end
    return s
end

local function Pick(key, value)
    if not CanEdit() then return end
    state.draft = state.draft or Copy(Rules())
    state.draft[key] = value
    CouncilRulesUI:Refresh()
end

-- The two pages' tabs (small, at the top left) and the top right: Save & share / Undo (the GM's draft), Add item.
local function BuildTop(v)
    local UIx = UI()
    v.tabWinner = UIx:CreateUnderlineTab(v, "Picking the winner", function() CouncilRulesUI:SetPage("winner") end, "small")
    v.tabWinner:SetPoint("TOPLEFT", v, "TOPLEFT", -4, 0)
    v.tabPrized = UIx:CreateUnderlineTab(v, "Prized items", function() CouncilRulesUI:SetPage("prized") end, "small")
    v.tabPrized:SetPoint("LEFT", v.tabWinner, "RIGHT", 6, 0)
    v.tabLine = v:CreateTexture(nil, "BORDER")
    v.tabLine:SetColorTexture(1, 1, 1, 0.08)
    v.tabLine:SetHeight(1)
    v.tabLine:SetPoint("TOPLEFT", v, "TOPLEFT", 0, -(K.TABS_H - 6))
    v.tabLine:SetPoint("TOPRIGHT", v, "TOPRIGHT", 0, -(K.TABS_H - 6))
    v.who = Text(v, "GameFontHighlightSmall", 11, GREY[1], GREY[2], GREY[3])
    v.who:SetPoint("TOPRIGHT", v, "TOPRIGHT", 0, -4)
    v.save = UIx:CreateSleekButton(v, "Save & share", 100, 20, function() CouncilRulesUI:Save() end, "primary")
    v.save:SetPoint("TOPRIGHT", v, "TOPRIGHT", 0, 0)
    v.undo = UIx:CreateSleekButton(v, "Undo", 56, 20, function()
        state.draft = nil
        CouncilRulesUI:Refresh()
    end, "secondary")
    v.undo:SetPoint("RIGHT", v.save, "LEFT", -6, 0)
    v.add = UIx:CreateSleekButton(v, "Add item", 84, 20, function()
        if ns.PrizedUI and ns.PrizedUI.StartAdd then ns.PrizedUI:StartAdd() end
    end, "primary")
    v.add:SetPoint("TOPRIGHT", v, "TOPRIGHT", 0, 0)
    Tip(v.add, "Add a prized item", "A drop with stricter loot rules (attendance, rank, a queue...). Raiders see them.")
end

-- Picking the winner: the choices (left, scrolling) and the example (right).
local function BuildWinner(v)
    local page = CreateFrame("Frame", nil, v)
    page:SetPoint("TOPLEFT", v, "TOPLEFT", 0, -K.TABS_H)
    page:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", 0, 0)
    v.winner = page
    -- the choices
    local left = CreateFrame("Frame", nil, page)
    left:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
    left:SetWidth(K.LEFT_W)
    Fill(left, { 0.06, 0.06, 0.07, 0.9 })
    Edge(left, EDGE)
    page.left = left
    local sf = UI():CreateScrollFrame(left)
    sf:SetPoint("TOPLEFT", left, "TOPLEFT", 12, -8)
    sf:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", -20, 8)
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
        if i < #STEPS then
            local line = f:CreateTexture(nil, "BORDER")
            line:SetColorTexture(1, 1, 1, 0.07)
            line:SetHeight(1)
            line:SetPoint("BOTTOMLEFT")
            line:SetPoint("BOTTOMRIGHT")
        end
        f.title = Text(f, "GameFontHighlight", 13)
        f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -4)
        f.title:SetText(st.title)
        f.sub = Text(f, "GameFontHighlightSmall", 11, GREY[1], GREY[2], GREY[3])
        f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
        f.sub:SetWidth(K.CHOICE_W)
        f.sub:SetText(st.sub)
        local hit = CreateFrame("Frame", nil, f)
        hit:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        hit:SetSize(K.CHOICE_W, 36)
        Tip(hit, st.title, st.tip)
        f.seg = Seg(f, st.key, st.opts, Pick)
        f.seg:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -39)
        f.def = st
        page.steps[i] = f
        y = y + K.STEP_H
    end
    body:SetHeight(y + 4)
    -- the example
    local right = CreateFrame("Frame", nil, page)
    right:SetPoint("TOPLEFT", page, "TOPLEFT", K.RIGHT_X, 0)
    right:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    page.right = right
    right.tryLabel = Text(right, "GameFontNormal", 13)
    right.tryLabel:SetPoint("TOPLEFT", right, "TOPLEFT", 2, -4)
    right.tryLabel:SetText("Try it")
    right.scenes = Seg(right, "scene", (function()
        local o = {}
        for i, sc in ipairs(SCENES) do o[i] = { sc.key, sc.label } end
        return o
    end)(), function(_, value)
        state.scene = value
        CouncilRulesUI:Refresh()
    end, 270)
    right.scenes:SetPoint("TOPRIGHT", right, "TOPRIGHT", 0, 0)
    right.change = Text(right, "GameFontHighlightSmall", 11)
    right.change:SetPoint("TOPLEFT", right, "TOPLEFT", 2, -30)
    right.change:SetWidth(K.RIGHT_W - 4)
    local c = CreateFrame("Frame", nil, right)
    c:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -48)
    c:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 0)
    Fill(c, CARD_BG)
    Edge(c, EDGE)
    page.card = c
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(26, 26)
    c.icon:SetPoint("TOPLEFT", c, "TOPLEFT", K.CARD_PAD, -8)
    c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    c.name = Text(c, "GameFontNormal", 12)
    c.name:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 8, 0)
    c.sub = Text(c, "GameFontHighlightSmall", 11)
    c.sub:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -3)
    c.rows = {}
    c.more = Text(c, "GameFontHighlightSmall", 11, GREY[1], GREY[2], GREY[3])
    c.why = Text(c, "GameFontHighlight", 12)
    c.why:SetWordWrap(true)
    c.why:SetWidth(K.RIGHT_W - 2 * K.CARD_PAD)
    c.why:SetTextColor(0.91, 0.85, 0.66)
    c.never = Text(c, "GameFontHighlightSmall", 11, GREY[1], GREY[2], GREY[3])
    c.never:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", K.CARD_PAD, 10)
    c.never:SetWidth(K.RIGHT_W - 2 * K.CARD_PAD)
    c.never:SetText("Never suggested: a pass, a player who left, a class that can't use it.")
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
    BuildTop(v)
    BuildWinner(v)
    v.prized = CreateFrame("Frame", nil, v)
    v.prized:SetPoint("TOPLEFT", v, "TOPLEFT", 0, -K.TABS_H)
    v.prized:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", 0, 0)
    for _, m in ipairs({ "LOOT_RULES_CHANGED", "PRIZED_UPDATED", "RAIDLOG_CHANGED", "DEMO_TOGGLED" }) do
        ns:On(m, function() CouncilRulesUI:RequestRefresh() end)
    end
    v:SetScript("OnShow", function() CouncilRulesUI:Refresh() end)
    return v
end

---------------------------------------------------------------------------
-- Filling
---------------------------------------------------------------------------

local function ItemIcon(itemID)
    local db = ns.ItemDB
    return db and db.GetIcon and db:GetIcon(itemID) or 134400
end

local function MoveMark(r)
    if not r.move then
        r.move = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
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
    for _, f in ipairs(page.steps) do f.seg:Paint(draft[f.def.key], edit) end
    local right = page.right
    right.scenes:Paint(state.scene, true)
    local dirty = edit and not Same(saved, draft)
    v.save:SetShown(dirty)
    v.undo:SetShown(dirty)
    v.who:SetShown(not dirty)
    v.who:SetText(edit and "you set these for the guild" or ("set by " .. (by and ns.Util.ShortName(by) or "the Guild Master")))
    -- the example roll, with the draft and with the saved rules (what moved)
    local rows = ExampleRows(draft)
    local base = ExampleRows(saved)
    local basePos = {}
    for i, r in ipairs(base) do basePos[r.key] = i end
    local c = page.card
    c.icon:SetTexture(ItemIcon(K.ITEM))
    c.name:SetText((ns.UI and ns.UI.ItemText and ns.UI:ItemText(K.ITEM)) or "Ravager's Bracers")
    local split = 0
    for _, r in ipairs(rows) do if r.split then split = split + 1 end end
    c.sub:SetText("|cffff9f40Rolls closed|r  |cffb8b8bc·  an example roll|r"
        .. (split > 1 and format("  |cffffa040·  votes split %d ways|r", split) or ""))
    local DP = ns.DropPanel
    local P = DP and DP.PREVIEW
    local top = 8 + 26 + 8
    local n = min(#rows, K.PREVIEW_ROWS)
    local rowH = P and P.ROW_H or 22
    local headH = P and P.HEAD_H or 13
    if DP and DP.PreviewHead then DP:PreviewHead(c, top, n * rowH) end
    local session = { state = "closed" }
    local moved = 0
    for i, row in ipairs(rows) do
        if basePos[row.key] ~= i then moved = moved + 1 end
        local r = c.rows[i]
        if i <= n and DP and DP.NewPreviewRow then
            if not r then
                r = DP:NewPreviewRow(c)
                c.rows[i] = r
            end
            DP:FillPreviewRow(r, row, session, K.ITEM)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", c, "TOPLEFT", K.CARD_PAD, -(top + headH + (i - 1) * rowH))
            r:SetPoint("TOPRIGHT", c, "TOPRIGHT", -K.CARD_PAD, -(top + headH + (i - 1) * rowH))
            r:Show()
            local mk = MoveMark(r)
            local dpos = (basePos[row.key] or i) - i
            if dirty and dpos > 0 then
                mk:SetText("|cff4fd36b+" .. dpos .. "|r")
            elseif dirty and dpos < 0 then
                mk:SetText("|cffff7a6a" .. dpos .. "|r")
            else
                mk:SetText("")
            end
        elseif r then
            r:Hide()
        end
    end
    for i = #rows + 1, #c.rows do c.rows[i]:Hide() end
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
        local head = (w == nn) and (nn .. " stays on top") or (w .. " -> " .. nn)
        right.change:SetText(format("|cffb7f5c3Your change: %s · %d moved|r", head, moved))
    else
        right.change:SetText(edit and "|cffb8b8bcClick a choice on the left: the example re-ranks.|r"
            or "|cffb8b8bcThe Guild Master sets these; the example uses them.|r")
    end
end

function CouncilRulesUI:Refresh()
    local v = view
    if not v or not v:IsVisible() then return end
    local winner = state.page ~= "prized"
    v.tabWinner:SetActive(winner)
    v.tabPrized:SetActive(not winner)
    v.winner:SetShown(winner)
    v.prized:SetShown(not winner)
    if winner then
        v.add:Hide()
        FillWinner(v)
    else
        v.save:Hide()
        v.undo:Hide()
        v.who:Hide()
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

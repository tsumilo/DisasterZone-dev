if DisasterZoneBoot and DisasterZoneBoot.Run("UI/CouncilRules.lua", ...) then return end -- DisasterZone: UI/CouncilRules.lua
-- Council > Rules (1.3.5, the user's pick 2026-10-11): every loot rule of the guild in one place. A list on the left
-- ("Picking the winner", then the prized items) and the picked entry on the right:
--   Picking the winner: the GM's loot rules (Guild:GetLootRules) as four lines of choices, and a "Try it" card - the
--   drop panel's own roll rows (DropPanel:NewPreviewRow) on an example roll, ranked by Roll:RankRows with the rules as
--   they are being edited. Rows that move show it and the header says what changed against the saved rules; the line
--   under the rows says why the suggestion is who it is. The GM saves (shared with the guild on RLL); everyone else on
--   the council sees the rules read-only.
--   A prized item: the loot rules session's own view (PrizedUI:Mount, detail only) in the right-hand column.
-- CouncilUI hosts it as its view "rules".
local addonName, ns = ...

local CouncilRulesUI = ns:NewModule("CouncilRulesUI")

local floor, max, min = math.floor, math.max, math.min
local format, tconcat = string.format, table.concat

-- (readability pass after the user's in-game shot, "barely readable": the picked choice gold, sub-lines 11 px light
-- grey, the choices in one right-hand column of equal buttons, the example's scenarios on their own row, 5 rows)
local K = { W = 770, LIST_W = 300, GAP = 8, ROW = 30, STRIP = 22, STEP_H = 34, SEG_H = 20, CARD_PAD = 12,
            PREVIEW_ROWS = 5, ITEM = 30687,   -- (Ravager's Bracers: the example roll's item)
            CHOICE_W = 220 }                   -- the choices' column (right-aligned, equal buttons per line)
K.DETAIL_X = K.LIST_W + K.GAP
K.DETAIL_W = K.W - K.DETAIL_X                    -- 462 (PrizedUI's detail column is as wide)
local GOLD, GREY, DIM = { 1, 0.82, 0 }, { 0.72, 0.72, 0.75 }, { 0.50, 0.50, 0.53 }
local CARD_BG, EDGE = { 0.10, 0.10, 0.12, 0.92 }, { 0.34, 0.34, 0.38, 0.5 }

-- The choices, in the order the lines show them (keys of Guild.LOOT_RULES).
local STEPS = {
    { key = "f", title = "Attendance floor", sub = "below it: listed, never suggested",
      opts = { { 0, "Off" }, { 50, "50%" }, { 60, "60%" }, { 75, "75%" } },
      tip = "Players whose attendance (Raid log, the last 8 raids that expected them) is under it are still listed "
          .. "with a warning, but never the suggested winner, and their votes don't decide. The council can still "
          .. "award them by hand." },
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
      tip = "The highest roll wins, or the player with the most raids since their last item (the roll breaks a "
          .. "tie). Driest first helps players on a dry streak." },
    { key = "y", title = "Since loot counts", sub = "raids since their last item",
      opts = { { "n", "Nights there" }, { "a", "Any night" } },
      tip = "The SINCE LOOT column (the dry streak): only nights they were really there for (a boss kill or half "
          .. "the night), or any night they showed up. Offspec, disenchant and guild bank items never end a streak." },
}

-- The example roll: name, class, spec, tier (1 BiS, 2 Alt, 3 OS, 4 not on a list), attendance %, raids since loot
-- (really there / came at all), roll (nil = no roll), times rolled, bad range, passed.
local EXAMPLE = {
    { "Orinel", "WARLOCK", "Destruction", 4, 60, 5, 5, 93 },
    { "Brakka", "WARRIOR", "Protection", 4, 88, 1, 1 },
    { "Quillon", "DRUID", "Restoration", 3, 14, 1, 5 },
    { "Kaelyn", "SHAMAN", "Restoration", 4, 78, 0, 0, 98, 2 },
    { "Caelith", "PALADIN", "Protection", 3, 100, 1, 1, 27 },
    { "Mirabel", "MAGE", "Frost", 4, 75, 5, 5, 8 },
    { "Aldrin", "WARRIOR", "Protection", 2, 100, 3, 3 },
    { "Isolde", "PRIEST", "Holy", 4, 69, 0, 0, 11, 1, { 1, 50 } },
    { "Elowen", "HUNTER", "Marksmanship", 4, 100, 0, 0, nil, 1, nil, true },
    { "Grimtusk", "ROGUE", "Combat", 4, 88, 6, 6, nil, 1, nil, true },
}
local SCENES = {
    { key = "split", label = "Split vote", votes = { Quillon = 1, Orinel = 1, Brakka = 1 } },
    { key = "one", label = "Clear vote", votes = { Quillon = 2, Orinel = 1 } },
    { key = "none", label = "No votes", votes = {} },
}

local view                    -- the frame (CouncilRulesUI:Create)
local state = { sel = "winner", scene = "split", draft = nil }

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
    return G and G.GetLootRules and G:GetLootRules() or { f = 0, s = "r", l = "l", w = "r", y = "n" }
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
        local name, cls, spec, tier, att, dryN, dryA, roll, count, bad, pass = unpack(p, 1, 11)
        local dryCount = (rules.y == "a") and dryA or dryN
        local key = name .. "-" .. realm
        rows[i] = { key = key, name = name, classFile = cls, spec = spec, tier = tier, os = tier == 3 or nil,
                    which = (tier == 2 and "alt") or (tier <= 3 and "main") or nil, roll = roll,
                    invalid = bad ~= nil, min = bad and bad[1], max = bad and bad[2], count = count or (roll and 1 or 0),
                    response = pass and "pass" or (roll and "roll" or nil), inRaid = true, votes = votes[name] or 0,
                    voters = {}, att = att, dry = dryCount, equippedList = {},
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

local function NewStrip(parent, text, right)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(K.STRIP)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 1)
    if bg.SetGradient and CreateColor then
        bg:SetGradient("HORIZONTAL", CreateColor(0.16, 0.14, 0.07, 0.95), CreateColor(0.07, 0.07, 0.08, 0.9))
    else
        bg:SetColorTexture(0.13, 0.12, 0.07, 0.95)
    end
    f.text = Text(f, "GameFontNormal", 12)
    f.text:SetPoint("LEFT", f, "LEFT", 8, 0)
    f.text:SetText(text)
    if right then
        f.right = Text(f, "GameFontHighlightSmall", 10, GREY[1], GREY[2], GREY[3])
        f.right:SetPoint("RIGHT", f, "RIGHT", -8, 0)
        f.right:SetText(right)
    end
    return f
end

local function NewListRow(parent, onClick)
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(K.ROW)
    r.bg = Fill(r, { 0.07, 0.07, 0.085, 0.85 })
    r.sel = r:CreateTexture(nil, "BORDER")
    r.sel:SetAllPoints()
    r.sel:SetColorTexture(0.18, 0.16, 0.10, 0.9)
    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetPoint("TOPLEFT")
    r.bar:SetPoint("BOTTOMLEFT")
    r.bar:SetWidth(2)
    r.bar:SetColorTexture(1, 0.82, 0, 1)
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.05)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(22, 22)
    r.icon:SetPoint("LEFT", r, "LEFT", 8, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.name = Text(r, "GameFontHighlight", 12)
    r.name:SetPoint("TOPLEFT", r, "TOPLEFT", 38, -3)
    r.name:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    r.sub = Text(r, "GameFontDisableSmall", 10)
    r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -1)
    r.sub:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    r:SetScript("OnClick", onClick)
    return r
end

local function BuildList(v)
    local l = CreateFrame("Frame", nil, v)
    l:SetPoint("TOPLEFT", v, "TOPLEFT", 0, 0)
    l:SetPoint("BOTTOMLEFT", v, "BOTTOMLEFT", 0, 0)
    l:SetWidth(K.LIST_W)
    v.list = l
    l.strip1 = NewStrip(l, "Guild loot rules", "set by the Guild Master")
    l.strip1:SetPoint("TOPLEFT", l, "TOPLEFT", 0, 0)
    l.strip1:SetPoint("TOPRIGHT", l, "TOPRIGHT", 0, 0)
    l.winner = NewListRow(l, function() CouncilRulesUI:Select("winner") end)
    l.winner:SetPoint("TOPLEFT", l.strip1, "BOTTOMLEFT", 0, -2)
    l.winner:SetPoint("TOPRIGHT", l.strip1, "BOTTOMRIGHT", 0, -2)
    l.winner.icon:SetTexture("Interface\\Icons\\INV_Misc_Note_02")
    l.winner.name:SetText("Picking the winner")
    l.winner.sub:SetText("votes, rolls, lists, attendance")
    l.strip2 = NewStrip(l, "Prized items", "their own stricter rules")
    l.strip2:SetPoint("TOPLEFT", l.winner, "BOTTOMLEFT", 0, -K.GAP)
    l.strip2:SetPoint("TOPRIGHT", l.winner, "BOTTOMRIGHT", 0, -K.GAP)
    l.rows = {}
    l.empty = Text(l, "GameFontDisableSmall", 11)
    l.empty:SetText("No prized items yet.")
    l.add = UI():CreateSleekButton(l, "Add item", 90, 22, function()
        state.sel = "prized"
        CouncilRulesUI:Refresh()
        if ns.PrizedUI and ns.PrizedUI.StartAdd then ns.PrizedUI:StartAdd() end
    end, "secondary")
    Tip(l.add, "Add a prized item", "A drop with stricter loot rules (attendance, rank, a queue...). Raiders see them.")
end

local function BuildWinner(v)
    local d = CreateFrame("Frame", nil, v)
    d:SetPoint("TOPLEFT", v, "TOPLEFT", K.DETAIL_X, 0)
    d:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", 0, 0)
    v.winner = d
    Fill(d, { 0.06, 0.06, 0.07, 0.9 })
    Edge(d, EDGE)
    local W = K.DETAIL_W - 24
    d.title = Text(d, "GameFontNormalLarge", 15)
    d.title:SetPoint("TOPLEFT", d, "TOPLEFT", 12, -10)
    d.title:SetText("Picking the winner")
    d.who = Text(d, "GameFontDisableSmall", 10)
    d.who:SetPoint("TOPRIGHT", d, "TOPRIGHT", -12, -14)
    d.steps = {}
    local y = -34
    for i, st in ipairs(STEPS) do
        local f = CreateFrame("Frame", nil, d)
        f:SetPoint("TOPLEFT", d, "TOPLEFT", 12, y)
        f:SetSize(W, K.STEP_H)
        local line = f:CreateTexture(nil, "BORDER")
        line:SetColorTexture(1, 1, 1, 0.06)
        line:SetHeight(1)
        line:SetPoint("BOTTOMLEFT")
        line:SetPoint("BOTTOMRIGHT")
        f.title = Text(f, "GameFontHighlight", 12)
        f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -3)
        f.title:SetText(st.title)
        f.sub = Text(f, "GameFontHighlightSmall", 11, GREY[1], GREY[2], GREY[3])
        f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -2)
        f.sub:SetWidth(W - K.CHOICE_W - 10)
        f.sub:SetText(st.sub)
        local hit = CreateFrame("Frame", nil, f)
        hit:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        hit:SetSize(W - K.CHOICE_W - 10, K.STEP_H)
        Tip(hit, st.title, st.tip)
        f.seg = Seg(f, st.key, st.opts, Pick)
        f.seg:SetPoint("RIGHT", f, "RIGHT", 0, 0)
        f.def = st
        d.steps[i] = f
        y = y - K.STEP_H
    end
    d.always = Text(d, "GameFontHighlightSmall", 11, GREY[1], GREY[2], GREY[3])
    d.always:SetPoint("TOPLEFT", d, "TOPLEFT", 12, y - 6)
    d.always:SetWidth(W)
    d.always:SetText("Never suggested: a pass, a player who left, a class that can't use it.")
    y = y - 24
    -- what the draft changes, Undo / Save & share (the GM, when the draft differs)
    d.save = UI():CreateSleekButton(d, "Save & share", 96, 20, function() CouncilRulesUI:Save() end, "primary")
    d.undo = UI():CreateSleekButton(d, "Undo", 56, 20, function()
        state.draft = nil
        CouncilRulesUI:Refresh()
    end, "secondary")
    d.save:SetPoint("TOPRIGHT", d, "TOPRIGHT", -12, y - 2)
    d.undo:SetPoint("RIGHT", d.save, "LEFT", -6, 0)
    d.change = Text(d, "GameFontHighlightSmall", 11)
    d.change:SetPoint("TOPLEFT", d, "TOPLEFT", 12, y - 6)
    y = y - 26
    -- Try it: the label and the example's scenarios on their own row
    d.tryLabel = Text(d, "GameFontHighlightSmall", 11, GREY[1], GREY[2], GREY[3])
    d.tryLabel:SetPoint("TOPLEFT", d, "TOPLEFT", 12, y - 4)
    d.tryLabel:SetText("TRY IT")
    d.scenes = Seg(d, "scene", (function()
        local o = {}
        for i, sc in ipairs(SCENES) do o[i] = { sc.key, sc.label } end
        return o
    end)(), function(_, value)
        state.scene = value
        CouncilRulesUI:Refresh()
    end, 246)
    d.scenes:SetPoint("TOPRIGHT", d, "TOPRIGHT", -12, y)
    y = y - 26
    local c = CreateFrame("Frame", nil, d)
    c:SetPoint("TOPLEFT", d, "TOPLEFT", 6, y)
    c:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -6, 6)
    Fill(c, CARD_BG)
    Edge(c, EDGE)
    d.card = c
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(26, 26)
    c.icon:SetPoint("TOPLEFT", c, "TOPLEFT", K.CARD_PAD, -8)
    c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    c.name = Text(c, "GameFontNormal", 12)
    c.name:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 8, 0)
    c.sub = Text(c, "GameFontHighlightSmall", 10)
    c.sub:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -3)
    c.rows = {}
    c.more = Text(c, "GameFontDisableSmall", 10)
    c.why = Text(c, "GameFontHighlight", 12)
    c.why:SetWordWrap(true)
    c.why:SetWidth(K.DETAIL_W - 12 - 2 * K.CARD_PAD)
    c.why:SetTextColor(0.91, 0.85, 0.66)
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
    BuildList(v)
    BuildWinner(v)
    v.prized = CreateFrame("Frame", nil, v)
    v.prized:SetPoint("TOPLEFT", v, "TOPLEFT", K.DETAIL_X, 0)
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

local function FillList(v)
    local l = v.list
    local P = ns.Prized
    local items = P and P.GetItems and P:GetItems() or {}
    local winnerOn = state.sel == "winner"
    l.winner.sel:SetShown(winnerOn)
    l.winner.bar:SetShown(winnerOn)
    local prev = l.strip2
    local shown = 0
    local room = floor(((l:GetHeight() or 0) > 0 and l:GetHeight() or 500) - 2 * K.STRIP - K.ROW - 40) / (K.ROW + 2)
    for i, rec in ipairs(items) do
        local r = l.rows[i]
        if not r then
            r = NewListRow(l, function(self) CouncilRulesUI:Select(self.recId) end)
            l.rows[i] = r
        end
        if i <= room then
            r.recId = rec.id
            r.icon:SetTexture(ItemIcon(rec.ids[1]))
            local name = P:Name(rec)
            local q = ns.ItemDB and ns.ItemDB.GetQuality and ns.ItemDB:GetQuality(rec.ids[1])
            local col = (q == 5 and "|cffff8000") or "|cffa335ee"
            r.name:SetText(col .. name .. "|r")
            local place = P:Place(rec.ids[1])
            r.sub:SetText((place.bossName and (place.bossName .. " · ") or "") .. (place.raidName or ""))
            local on = state.sel == rec.id
            r.sel:SetShown(on)
            r.bar:SetShown(on)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -2)
            r:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -2)
            r:Show()
            prev = r
            shown = shown + 1
        else
            r:Hide()
        end
    end
    for i = #items + 1, #l.rows do l.rows[i]:Hide() end
    l.empty:ClearAllPoints()
    l.empty:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 8, -8)
    l.empty:SetShown(#items == 0)
    if #items > shown then
        l.empty:SetText(format("+%d more", #items - shown))
        l.empty:Show()
    elseif #items == 0 then
        l.empty:SetText("No prized items yet.")
    end
    l.add:ClearAllPoints()
    l.add:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, (l.empty:IsShown() and -28) or -8)
    l.add:SetShown(P and P.CanEdit and P:CanEdit() or false)
end

local function MoveMark(r)
    if not r.move then
        r.move = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.move:SetPoint("RIGHT", r, "RIGHT", 0, 0)
    end
    return r.move
end

local function FillWinner(v)
    local d = v.winner
    local saved, draft = Rules(), Draft()
    local edit = CanEdit()
    local G = ns.Guild
    local by = G and G.GetLootRulesBy and G:GetLootRulesBy()
    d.who:SetText(edit and "you set these for the guild" or ("set by " .. (by and ns.Util.ShortName(by) or "the Guild Master")))
    for _, f in ipairs(d.steps) do f.seg:Paint(draft[f.def.key], edit) end
    d.scenes:Paint(state.scene, true)
    local dirty = edit and not Same(saved, draft)
    d.save:SetShown(dirty)
    d.undo:SetShown(dirty)
    -- the example roll, with the draft and with the saved rules (what moved)
    local rows = ExampleRows(draft)
    local base = ExampleRows(saved)
    local basePos = {}
    for i, r in ipairs(base) do basePos[r.key] = i end
    local c = d.card
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
    c.more:SetPoint("TOPLEFT", c, "TOPLEFT", K.CARD_PAD + 22, -(y + 2))
    c.more:SetText(#rows > n and format("+%d more", #rows - n) or "")
    c.why:ClearAllPoints()
    c.why:SetPoint("TOPLEFT", c, "TOPLEFT", K.CARD_PAD, -(y + 18))
    c.why:SetText(WhyText(rows, draft))
    -- what the draft changes against the saved rules
    if dirty then
        local was, now = Suggested(base), Suggested(rows)
        local w, nn = was and was.name or "nobody", now and now.name or "nobody"
        local head = (w == nn) and (nn .. " stays on top") or (w .. " -> " .. nn)
        d.change:SetText(format("|cffb7f5c3Your change: %s · %d moved|r", head, moved))
    else
        d.change:SetText(edit and "|cffb8b8bcClick a choice: the example below re-ranks.|r"
            or "|cffb8b8bcThe Guild Master sets these; the example uses them.|r")
    end
end

function CouncilRulesUI:Refresh()
    local v = view
    if not v or not v:IsVisible() then return end
    FillList(v)
    local winner = state.sel == "winner"
    v.winner:SetShown(winner)
    v.prized:SetShown(not winner)
    if winner then
        FillWinner(v)
    else
        local PU = ns.PrizedUI
        if PU and PU.Mount then
            PU:Mount(v.prized, { list = false })
            if state.sel ~= "prized" and PU.Select then PU:Select(state.sel) end
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

-- "winner" or a prized record id.
function CouncilRulesUI:Select(id)
    state.sel = id or "winner"
    self:Refresh()
end

function CouncilRulesUI:GetSelected() return state.sel end

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

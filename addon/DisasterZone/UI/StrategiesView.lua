if DisasterZoneBoot and DisasterZoneBoot.Run("UI/StrategiesView.lua", ...) then return end -- DisasterZone: UI/StrategiesView.lua
-- Where the strategy boards live in the Raids tab (Addendum K):
--   Strategies view   - the library, for every guild member to explore and build in. A search and a guild member
--                       filter on top; on the left the raids as strips of their loading screens (a raid without a
--                       match fades, the open raid unfolds its bosses: All raids / a raid / one boss), on the right
--                       the matching strategies as cards. A click on a card opens the board; Edit for the owner, the
--                       collaborators, the GM and the guild council; the card's More menu: Copy (the copy is yours)
--                       and Share (a link in chat) for everyone, Collaborators for the owner, Delete for the owner,
--                       the GM and the guild council. My unsaved drafts sit on top (continue / discard; saving one
--                       makes it a strategy). New strategy and the tutorial (?) sit on the Raids tab's view row.
--   Assignments tab   - of a planned raid (Upcoming): its bosses as tiles with their journal pictures, the strategy
--                       each uses and how many slots are filled; a click opens the board (everyone), Assign fills
--                       it. Who leads the raid (its own leader; a raid without one: the raid leaders) and the GM
--                       pick each boss' strategy in the tile's link-dropdown, saved at once; a boss not picked yet
--                       uses the one the guild used last.
local addonName, ns = ...

local View = ns:NewModule("StrategiesUI")

local tsort, tconcat = table.sort, table.concat
local min, max, ceil, floor = math.min, math.max, math.ceil, math.floor

-- The library: the Raids tab's spacing grid (PAD at the page's sides, GAP between blocks).
local PAD, GAP = 10, 8
local INNER_W = 770                  -- the page inside its sides (the mock's anchored frames have no width)
local TREE_W = 200                   -- the raids column
local FILTER_H = 22                  -- the search / By row
local ALL_H, STRIP_H, BOSS_H = 26, 30, 22
local STRIP_GAP = 4                  -- under a raid's strip
local CARD_H, CARD_GAP = 46, 6       -- a strategy: its card and the gap under it
local THUMB_W = 64                   -- its raid's art
local ACT = 24                       -- a card's icon buttons
local CARD_BG = { 0.10, 0.10, 0.12, 0.92 }
local DRAFT_BG = { 0.16, 0.115, 0.06, 0.94 }
local MENU_GOLD, MENU_RED = { 1, 0.82, 0 }, { 1, 0.4, 0.35 }
local PILL = {                       -- fill, edge (mixed with the card's fill), text
    warn = { { 0.28, 0.18, 0.07, 1 }, { 0.58, 0.34, 0.09, 1 }, "ffb066" },
    ok = { { 0.12, 0.18, 0.15, 1 }, { 0.23, 0.48, 0.3, 1 }, "9ff0b0" },
}
local ART_TOP = 0.29                 -- a loading screen's picture starts under the game's logo
-- A planned raid's Assignments tab.
local RAID_TILE_H = 62               -- a raid's boss tile (two a row)
local RAID_TEXT_X = 104              -- its texts start right of the boss's picture
local RAID_PICK_MAX = 200            -- its strategy's link-dropdown: as wide as the name, at most this
local RAID_TOP = 34                  -- the tab's tool row above the tiles

local function S() return ns.Strategy end
local function UI() return ns.UI end
local function Board() return ns.StrategyBoard end
local function grey(t) return "|cff808080" .. tostring(t) .. "|r" end
local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

-- The library's filter: raid (an ItemDB raid key) or boss (a boss ref) picked on the left (neither: all raids),
-- text = the free search, by = nil (anyone) | "@me" | "@co" (shared with me) | a member's key.
local state = { raid = nil, boss = nil, text = "", by = nil }
local lib, assign, shareWin

local function raidOf(ref)
    return type(ref) == "string" and ref:match("^(%w+):") or nil
end

local function newText(parent, font, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags) end
    end
    return fs
end

local function gradient(tex, orient, r, g, b, a1, a2)
    tex:SetColorTexture(1, 1, 1, 1)
    if tex.SetGradient and CreateColor then tex:SetGradient(orient, CreateColor(r, g, b, a1), CreateColor(r, g, b, a2)) end
end

-- The first of the texts that fits in `room` (the last one when none does): never cut off with "...".
-- (measured without its colour codes: the game's width ignores them, the test harness's doesn't)
local function fitText(fs, variants, room)
    for i, text in ipairs(variants) do
        fs:SetText((text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
        local fits = (fs:GetStringWidth() or 0) <= room
        fs:SetText(text)
        if i == #variants or fits then return text end
    end
end

-- A small rounded tag after a name ("Draft", "shared with you"): p:Set(text, kind).
local function newPill(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetHeight(16)
    UI():AddPillShape(p, 16)
    p.fs = newText(p, "GameFontHighlightSmall", 10)
    p.fs:SetPoint("CENTER", 0, 0)
    function p:Set(text, kind)
        local c = PILL[kind] or PILL.ok
        self:SetPillColors(c[1], c[2])
        self.fs:SetText("|cff" .. c[3] .. text .. "|r")
        self:SetWidth(floor((self.fs:GetStringWidth() or 40) + 14 + 0.5))
    end
    return p
end

-- A raid's loading screen (UI/RaidPlanUI.lua has the crops): the raid plan's instance key of an ItemDB raid key.
local INST_SHORT = { kara = "Kara", gruul = "Gruul", mag = "Mag", ssc = "SSC", tk = "TK", hyjal = "Hyjal", bt = "BT",
                     za = "ZA", swp = "Sunwell" }
local instCache = {}
local function instOf(raidKey)
    if not raidKey then return "other" end
    if instCache[raidKey] then return instCache[raidKey] end
    local raid = ns.ItemDB and ns.ItemDB.GetRaid and ns.ItemDB:GetRaid(raidKey)
    local id, out = raid and raid.instanceID, "other"
    local RP = ns.RaidPlan
    for _, inst in ipairs((id and RP and RP.GetInstances) and RP:GetInstances() or {}) do
        if inst.instID == id then out = inst.key end
    end
    instCache[raidKey] = out
    return out
end

local function setArt(tex, raidKey, w, h, fw, small)
    local PlanUI = ns.RaidPlanUI
    if not (PlanUI and PlanUI.RaidArt) then
        tex:Hide()
        return
    end
    local inst = instOf(raidKey)
    local file, l, r, t, b = PlanUI:RaidArt(inst, w, h, fw)
    -- (a small crop stays under the game's logo at the top of the screen)
    if small and t < ART_TOP then t, b = ART_TOP, b + ART_TOP - t end
    tex:SetTexture(file)
    tex:SetTexCoord(l, r, t, b)
    tex:Show()
end

-- A boss' name, then shorter forms for a narrow place: without its title ("Attumen", "Solarian"), its first name.
local TITLES = { "High King ", "High Astromancer ", "High Warlord ", "Fathom%-Lord ", "Hex Lord ", "Doom Lord ",
                 "Lady ", "Mother ", "Prince ", "Shade of " }
local function bossVariants(name)
    local out = { name }
    local n = name:gsub("^The ", ""):gsub(" the .*$", "")
    for _, t in ipairs(TITLES) do n = n:gsub("^" .. t, "") end
    n = n:gsub(" of .*$", "")
    if n ~= name then out[#out + 1] = n end
    local first = n:match("^(%S+) ")
    if first then out[#out + 1] = first end
    return out
end

-- "21 Sep" this year, "21 Sep 2025" before.
local function shortDate(t)
    if date("%Y", t) == date("%Y") then return date("%d %b", t) end
    return date("%d %b %Y", t)
end

-- " · 3 pages" (nothing for one page).
local function pagesText(n)
    n = tonumber(n) or 1
    return n > 1 and (" · " .. n .. " pages") or ""
end

-- The filter as Strategy:Find takes it; `scoped` adds the raid / boss picked on the left.
local function findFilter(scoped)
    local me = ns.Util.PlayerKey()
    local f = { text = state.text }
    if state.by == "@me" then f.by = me
    elseif state.by == "@co" then f.co = me
    elseif state.by then f.by = state.by end
    if scoped then f.raid, f.boss = state.raid, state.boss end
    return f
end

local function filtered()
    return state.by ~= nil or (state.text or ""):find("%S") ~= nil
end

-- Does one of my drafts pass the filter (drafts are mine: the member filter keeps them for "anyone" and "mine")?
local function draftShown(dr, scoped)
    if state.by ~= nil and state.by ~= "@me" and state.by ~= ns.Util.PlayerKey() then return false end
    if scoped and ((state.boss and dr.b ~= state.boss) or (state.raid and raidOf(dr.b) ~= state.raid)) then return false end
    local hay = (dr.n .. "\n" .. S():GetBossName(dr.b) .. "\n" .. S():GetRaidName(dr.b)):lower()
    for w in (state.text or ""):lower():gmatch("%S+") do
        if not hay:find(w, 1, true) then return false end
    end
    return true
end

---------------------------------------------------------------------------
-- Library (Strategies view): the raids on the left
---------------------------------------------------------------------------

-- "3", and my unsaved drafts as an orange "+1".
local function countText(d)
    local parts = {}
    if d.count > 0 then parts[#parts + 1] = tostring(d.count) end
    if (d.drafts or 0) > 0 then parts[#parts + 1] = "|cffff9933+" .. d.drafts .. "|r" end
    return tconcat(parts, " ")
end

local function treeClick(self)
    local d = self.__cdlData
    if not d then return end
    if d.ref then View:SelectBoss(d.ref)
    elseif d.raid then View:SelectRaid(d.raid)
    else View:SelectRaid(nil) end
end

-- (what the orange count means)
local function treeTip(self)
    local d = self.__cdlData
    if not (d and (d.drafts or 0) > 0) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(d.name)
    if d.count > 0 then GameTooltip:AddLine(d.count == 1 and "1 strategy" or (d.count .. " strategies"), 1, 1, 1) end
    GameTooltip:AddLine(("%d unsaved %s of yours"):format(d.drafts, d.drafts == 1 and "draft" or "drafts"), 1, 0.6, 0.2)
    GameTooltip:Show()
end

-- One row of the left column: All raids, a raid (a strip of its loading screen) or a boss of the open raid.
local function initTreeRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        local box = CreateFrame("Frame", nil, row)
        box:SetPoint("TOPLEFT")
        box:SetPoint("TOPRIGHT")
        row.box = box
        row.art = box:CreateTexture(nil, "BACKGROUND", nil, 0)
        row.art:SetAllPoints()
        row.shade = box:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.shade:SetAllPoints()
        gradient(row.shade, "HORIZONTAL", 0.035, 0.035, 0.043, 0.9, 0.4)
        -- the picked one: a soft gold fill and a gold mark on its left (a raid: a gold edge)
        row.fill = box:CreateTexture(nil, "BACKGROUND", nil, 2)
        row.fill:SetAllPoints()
        row.fill:SetColorTexture(1, 0.82, 0, 0.1)
        row.bar = box:CreateTexture(nil, "ARTWORK")
        row.bar:SetPoint("TOPLEFT")
        row.bar:SetPoint("BOTTOMLEFT")
        row.bar:SetWidth(2)
        row.bar:SetColorTexture(1, 0.82, 0, 0.9)
        UI():AddEdges(box, "ARTWORK")
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints(box)
        row.hl:SetColorTexture(1, 1, 1, 0.05)
        row.fs = newText(box, "GameFontHighlight", 12)
        row.n = newText(box, "GameFontHighlightSmall", 11)
        row.n:SetJustifyH("RIGHT")
        row.n:SetPoint("RIGHT", -10, 0)
        row:SetScript("OnClick", treeClick)
        row:SetScript("OnEnter", treeTip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local kind = d.ref and "boss" or (d.raid and "raid" or "all")
    row.box:SetHeight(kind == "raid" and STRIP_H or (kind == "all" and ALL_H or BOSS_H))
    local lit = d.count > 0 or (d.drafts or 0) > 0
    row.n:SetText(countText(d))
    local room = TREE_W - 20 - (lit and ((row.n:GetStringWidth() or 0) + 8) or 0)
    row.fs:ClearAllPoints()
    local picked
    if kind == "raid" then
        -- a raid without a match fades
        setArt(row.art, d.raid, TREE_W, STRIP_H, 0.9)
        row.art:SetDesaturated(not lit)
        row.art:SetAlpha(lit and 1 or 0.4)
        row.shade:Show()
        row.fs:SetPoint("LEFT", 10, 0)
        if lit then row.fs:SetTextColor(1, 0.82, 0) else row.fs:SetTextColor(0.6, 0.6, 0.6) end
        fitText(row.fs, { d.name, d.short or d.name }, room)
        row.fs:SetAlpha(lit and 1 or 0.75)
        -- the picked raid: a gold edge; the open one (a boss of it picked): a faint one
        local edge = (state.boss == nil and state.raid == d.raid) and 0.85 or (raidOf(state.boss) == d.raid and 0.3) or 0
        UI():SetEdgeColor(row.box, 1, 0.82, 0, edge)
    else
        row.art:Hide()
        row.shade:Hide()
        UI():SetEdgeColor(row.box, 0, 0, 0, 0)
        row.fs:SetAlpha(1)
        if kind == "all" then
            row.fs:SetPoint("LEFT", 10, 0)
            row.fs:SetTextColor(1, 1, 1)
            row.fs:SetText(d.name)
            picked = state.boss == nil and state.raid == nil
        else
            row.fs:SetPoint("LEFT", 22, 0)
            if lit then row.fs:SetTextColor(0.9, 0.9, 0.9) else row.fs:SetTextColor(0.5, 0.5, 0.5) end
            fitText(row.fs, bossVariants(d.name), room - 12)
            picked = state.boss == d.ref
        end
    end
    row.fill:SetShown(picked and true or false)
    row.bar:SetShown(picked and true or false)
end

local function treeExtent(d)
    if d.ref then return BOSS_H + (d.last and 6 or 0) end
    if d.raid then return STRIP_H + STRIP_GAP end
    return ALL_H + 6
end

---------------------------------------------------------------------------
-- Library: the strategies on the right
---------------------------------------------------------------------------

-- The members changing a strategy right now (Core/StrategyCollab.lua): "A, B editing" in green, or nil.
local function editingText(id)
    local Collab = ns.StrategyCollab
    local names = {}
    for _, key in ipairs(Collab and Collab:GetEditors(id) or {}) do names[#names + 1] = shortName(key) end
    if #names == 0 then return nil end
    return "|cff33ff99" .. tconcat(names, ", ") .. " editing|r"
end

local function copyStrategy(s)
    Board():Prompt("Name of your copy", (s.n .. " (copy)"):sub(1, S().MAX_NAME_LEN), function(text)
        text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_NAME_LEN)
        if text == "" then return end
        local ok, id = S():CopyStrategy(s.id, text)
        if ok then Board():OpenStrategy(id, "edit") else ns:Print("Could not copy it: %s", tostring(id)) end
    end)
end

local function deleteStrategy(s)
    local owner = S():GetOwner(s.id)
    local whose = (owner and not ns.Util.IsMe(owner)) and (" by " .. shortName(owner)) or ""
    ns.RaidPlanUI:Confirm(("Delete the strategy \"%s\"%s for everyone?"):format(s.n, whose), function()
        local ok, err = S():DeleteStrategy(s.id)
        if not ok then ns:Print("Could not delete it: %s", tostring(err)) end
    end)
end

local function discardDraft(draft)
    ns.RaidPlanUI:Confirm(("Discard the draft \"%s\"? Its unsaved work is lost."):format(draft.n), function()
        Board():DiscardDraft(draft.did)
    end)
end

-- A link to the board for the chat (UI/Share.lua): the Share window, or with Shift straight into the chat box.
local function shareStrategy(s, anchor)
    local ref = ns.Share and ns.Share:StrategyRef(s.id)
    if not ref then return end
    if IsShiftKeyDown() then ns.Share:PutInChat(ref) elseif ns.ShareWindow then ns.ShareWindow:Open(ref, anchor) end
end

-- What a card's More menu holds for me: { icon, word, tooltip, fn, red }.
local function moreEntries(d, anchor)
    if d.draft then
        return { { UI().ICON.trash, "Discard", "Throws the draft's unsaved work away.",
                   function() discardDraft(d.draft) end, true } }
    end
    local s = d.s
    local out = {}
    if S():CanBuild() then
        out[#out + 1] = { 17, "Copy", "Makes a copy that is yours: change it, then pick it for your raids.",
                          function() copyStrategy(s) end }
    end
    out[#out + 1] = { 18, "Share", "Post a link in chat that opens it in DisasterZone (Shift: into your chat box).",
                      function() shareStrategy(s, anchor) end }
    if (s.ow or s.by) == ns.Util.PlayerKey() then
        out[#out + 1] = { 19, "Collaborators", "Pick the guild members who build it with you.",
                          function() View:OpenShare(s.id) end }
    end
    if S():CanDeleteStrategy(s.id) then
        out[#out + 1] = { UI().ICON.trash, "Delete", "Removes the strategy for everyone.", function() deleteStrategy(s) end,
                          true }
    end
    return out
end

-- The same entries for another place (the strategy board's ⋯ menu), without Share (the board has its own button).
function View:StrategyMoreEntries(s)
    local out = {}
    for _, e in ipairs(moreEntries({ s = s })) do
        if e[2] ~= "Share" then out[#out + 1] = e end
    end
    return out
end

local function openMore(btn)
    local row = btn:GetParent():GetParent()
    local d = row.__cdlData
    if not d then return end
    local entries = moreEntries(d, btn)
    UI():ContextMenu(btn, function(root)
        for _, e in ipairs(entries) do
            if e[5] and #entries > 1 and root.CreateDivider then root:CreateDivider() end
            local text = e[5] and ("|cffff8d80" .. e[2] .. "|r") or e[2]
            local b = root:CreateButton(UI():AtlasIconText(e[1], 14, e[5] and MENU_RED or MENU_GOLD) .. "  " .. text, e[4])
            if b and b.SetTooltip then
                b:SetTooltip(function(tt)
                    tt:AddLine(e[2], 1, 0.82, 0)
                    tt:AddLine(e[3], 1, 1, 1, true)
                end)
            end
        end
    end)
end

-- The card's edge lights while the mouse is on it (or on one of its buttons).
local function lightCard(row, on)
    if on then UI():SetEdgeColor(row.card, 1, 0.82, 0, 0.5) else UI():SetEdgeColor(row.card, 0, 0, 0, 0) end
end

-- A card's icon button stays quiet (a grey icon, no box) until the mouse is on it.
local function quietIcon(b)
    local function quiet(self)
        if self.hovered then return end
        self.bg:SetColorTexture(0, 0, 0, 0)
        UI():SetEdgeColor(self, 0, 0, 0, 0)
        self.icon:SetVertexColor(0.72, 0.72, 0.72)
    end
    b:HookScript("OnLeave", quiet)
    quiet(b)
end

local function initStratRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        local card = CreateFrame("Frame", nil, row)
        card:SetPoint("TOPLEFT")
        card:SetPoint("TOPRIGHT")
        card:SetHeight(CARD_H)
        row.card = card
        card.bg = card:CreateTexture(nil, "BACKGROUND")
        card.bg:SetAllPoints()
        UI():AddEdges(card, "OVERLAY")
        lightCard(row, false)
        row.art = card:CreateTexture(nil, "ARTWORK", nil, 0)
        row.art:SetPoint("TOPLEFT")
        row.art:SetSize(THUMB_W, CARD_H)
        row.fade = card:CreateTexture(nil, "ARTWORK", nil, 1)
        row.fade:SetPoint("TOPRIGHT", row.art, "TOPRIGHT")
        row.fade:SetPoint("BOTTOMRIGHT", row.art, "BOTTOMRIGHT")
        row.fade:SetWidth(22)
        row.l1 = newText(card, "GameFontHighlight", 13)
        row.l1:SetPoint("TOPLEFT", THUMB_W + 12, -8)
        row.pill = newPill(card)
        row.pill:SetPoint("LEFT", row.l1, "RIGHT", 8, 0)
        row.l2 = newText(card, "GameFontHighlightSmall", 11)
        row.l2:SetTextColor(0.62, 0.62, 0.62)
        row.l2:SetPoint("TOPLEFT", THUMB_W + 12, -27)
        row.more = UI():CreateTipIconButton(card, ACT, UI().ICON.more, "More", "", openMore)
        row.more:SetPoint("RIGHT", card, "RIGHT", -11, 0)
        row.edit = UI():CreateTipIconButton(card, ACT, 16, "Edit", "", function(self)
            local data = self:GetParent():GetParent().__cdlData
            if data and data.draft then Board():OpenDraft(data.draft.did)
            elseif data and data.s then Board():OpenStrategy(data.s.id, "edit") end
        end)
        row.edit:SetPoint("RIGHT", row.more, "LEFT", -4, 0)
        for _, b in ipairs({ row.more, row.edit }) do
            b:HookScript("OnEnter", function() lightCard(row, true) end)
            b:HookScript("OnLeave", function() lightCard(row, row:IsMouseOver()) end)
            quietIcon(b)
        end
        -- a click on the card opens the board to look at it (my draft: where I left it)
        row:SetScript("OnClick", function(self)
            local data = self.__cdlData
            if data and data.draft then Board():OpenDraft(data.draft.did)
            elseif data and data.s then Board():OpenStrategy(data.s.id) end
        end)
        row:SetScript("OnEnter", function(self) lightCard(self, true) end)
        row:SetScript("OnLeave", function(self) lightCard(self, false) end)
    end
    local draft, s = d.draft, d.s
    local item = draft or s
    local bg = draft and DRAFT_BG or CARD_BG
    row.card.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    gradient(row.fade, "HORIZONTAL", bg[1], bg[2], bg[3], 0, 1)
    setArt(row.art, raidOf(item.b), THUMB_W, CARD_H, 0.36, true)

    -- what I can do: Edit (a draft: Continue) on the card, the rest in its More menu
    local canEdit = draft ~= nil or S():CanEditStrategy(s.id)
    row.edit:SetShown(canEdit)
    row.edit.tipTitle = draft and "Continue" or "Edit"
    row.edit.tipText = draft and "Opens the draft where you left it." or "Opens the strategy to change it."
    local words = {}
    for _, e in ipairs(moreEntries(d, row.more)) do words[#words + 1] = e[2] end
    row.more.tipText = tconcat(words, ", ")

    -- line 1: the name and its tag; line 2: the boss (unless the list is one boss'), who, when, how big, who edits now
    row.l1:SetText(item.n)
    local tag = draft and "Draft" or (S():IsCollaborator(s.id) and "shared with you") or nil
    row.pill:SetShown(tag ~= nil)
    if tag then row.pill:Set(tag, draft and "warn" or "ok") end
    local boss = state.boss == nil and S():GetBossName(item.b) or nil
    local function line(bossName, pages, when)
        local parts = { bossName }
        if draft then
            parts[#parts + 1] = draft.id and "unsaved changes" or "not saved yet"
            if when then parts[#parts + 1] = "edited " .. date("%d %b %H:%M", draft.at) end
        else
            local owner = s.ow or s.by
            local co = #(s.co or {})
            parts[#parts + 1] = "by " .. (owner == ns.Util.PlayerKey() and "you" or UI():ColoredName(owner))
                .. (co > 0 and (" +" .. co) or "")
            if when then parts[#parts + 1] = shortDate(s.rev) end
        end
        local text = tconcat(parts, " · ") .. (pages and pagesText(draft and draft.pages or #s.p) or "")
        local live = s and editingText(s.id)
        return live and (text .. " · " .. live) or text
    end
    local cardW = row:GetWidth() or 0
    if cardW < 200 then cardW = INNER_W - TREE_W - GAP end
    local room = cardW - THUMB_W - 12 - (11 + ACT + (canEdit and (4 + ACT) or 0) + 12)
    -- (too long: the boss without its title, then without the pages, then without the date)
    local short = boss and bossVariants(boss)[2] or boss
    local variants = { line(boss, true, true) }
    if short ~= boss then variants[#variants + 1] = line(short, true, true) end
    variants[#variants + 1] = line(short, false, true)
    variants[#variants + 1] = line(short, false, false)
    fitText(row.l2, variants, room)
end

---------------------------------------------------------------------------
-- Library: the filter row and New strategy
---------------------------------------------------------------------------

local function byOptions()
    local out = {
        { value = nil, text = "Anyone" },
        { value = "@me", text = "My strategies" },
        { value = "@co", text = "Shared with me" },
    }
    local authors = S():GetAuthors()
    tsort(authors, function(a, b) return shortName(a.key):lower() < shortName(b.key):lower() end)
    if #authors > 0 then out[#out + 1] = { isTitle = true, text = "Guild members" } end
    for _, a in ipairs(authors) do
        out[#out + 1] = { value = a.key, text = shortName(a.key) .. "  (" .. a.n .. ")" }
    end
    -- a member picked earlier who has no strategy any more stays pickable (and so visible)
    if state.by and state.by:sub(1, 1) ~= "@" then
        local found = false
        for _, a in ipairs(authors) do found = found or a.key == state.by end
        if not found then out[#out + 1] = { value = state.by, text = shortName(state.by) .. "  (0)" } end
    end
    return out
end

local function askName(bossRef)
    Board():Prompt("Name of the new strategy for " .. S():GetBossName(bossRef) .. " (e.g. 25 farm)", "", function(text)
        text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_NAME_LEN)
        if text ~= "" then Board():NewStrategy(bossRef, text) end
    end)
end

-- New strategy: for the boss picked on the left, else a menu of bosses to pick from.
local function newStrategy(btn)
    if state.boss then return askName(state.boss) end
    UI():ContextMenu(btn, function(root)
        root:CreateTitle("New strategy for...")
        for _, raid in ipairs(S():GetRaidTree()) do
            if state.raid == raid.key then
                for _, b in ipairs(raid.bosses) do
                    root:CreateButton(b.name, function() askName(b.ref) end)
                end
            elseif not state.raid then
                local sub = root:CreateButton(raid.name)
                for _, b in ipairs(raid.bosses) do
                    sub:CreateButton(b.name, function() askName(b.ref) end)
                end
            end
        end
    end)
end

local HELP = "Everyone builds strategies here: a map with zones, arrows and icons, plus tables of jobs. You change your "
    .. "own and the ones shared with you; Copy makes any strategy yours. For a raid, its leader fills in the names "
    .. "(Raids > Upcoming > Assignments)."

function View:CreateLibrary(parent)
    local f = CreateFrame("Frame", nil, parent)
    lib = f
    -- the filter row: the search over the raids column, By over the strategies, Clear filters while filtering
    f.search = UI():CreateSearchBox(f, TREE_W, function(text)
        text = ns.Util.Trim(text or "")
        if text == state.text then return end
        state.text = text
        View:RefreshLibrary()
    end, "Search strategies")
    f.search:SetPoint("TOPLEFT", PAD, 0)
    f.by = UI():CreateDropdown(f, 170, byOptions, function() return state.by end, function(value)
        state.by = value
        View:RefreshLibrary()
    end)
    f.by:SetPoint("TOPLEFT", PAD + TREE_W + GAP, 0)
    -- ("By" inside the dropdown, in front of the pick)
    local refreshBy = f.by.Refresh
    function f.by:Refresh()
        refreshBy(self)
        self:SetText("|cff8c8c8cBy|r  " .. (self:GetText() or ""))
    end
    f.by:Refresh()
    f.clear = UI():CreateButton(f, "Clear filters", 96, 22, function() View:SetFilter({}) end)
    f.clear:SetPoint("TOPRIGHT", -PAD, 0)

    -- the raids (the box keeps the column's width; its bar sits in the gap beside it)
    f.list = UI():CreateScrollList(f, BOSS_H, initTreeRow, treeExtent)
    f.list.frame:SetPoint("TOPLEFT", PAD, -(FILTER_H + GAP))
    f.list.frame:SetPoint("BOTTOMLEFT", PAD, 0)
    f.list.frame:SetWidth(TREE_W + 20)
    if f.list.bar then
        f.list.bar:ClearAllPoints()
        f.list.bar:SetPoint("TOPLEFT", f.list.box, "TOPRIGHT", 1, 0)
        f.list.bar:SetPoint("BOTTOMLEFT", f.list.box, "BOTTOMRIGHT", 1, 0)
    end

    -- the strategies (the scroll bar in the page's right margin)
    local d = CreateFrame("Frame", nil, f)
    d:SetPoint("TOPLEFT", PAD + TREE_W + GAP, -(FILTER_H + GAP))
    d:SetPoint("BOTTOMRIGHT", -PAD, 0)
    f.detail = d
    d.list = UI():CreateScrollList(d, CARD_H + CARD_GAP, initStratRow)
    d.list.frame:SetPoint("TOPLEFT", 0, 0)
    d.list.frame:SetPoint("BOTTOMRIGHT", 20, 0)
    if d.list.bar then
        d.list.bar:ClearAllPoints()
        d.list.bar:SetPoint("TOPLEFT", d.list.box, "TOPRIGHT", 4, 0)
        d.list.bar:SetPoint("BOTTOMLEFT", d.list.box, "BOTTOMRIGHT", 4, 0)
    end

    -- the view's actions on the Raids tab's view row (30 above the library, like New raid): the tutorial behind a ?
    -- (what this view is in its tooltip), New strategy
    d.newBtn = UI():CreateSleekButton(d, "New strategy", 110, 22, function(self) newStrategy(self) end, "primary")
    d.tourBtn = UI():CreateTipIconButton(d, 22, 11, "Strategies", HELP, function(self)
        if S():CanBuild() then ns.Tour:Menu(self, "strategy") end
    end)
    d.tourBtn:HookScript("OnEnter", function()
        if not S():CanBuild() then return end
        GameTooltip:AddLine("Click for the tutorial: a guided tour on a practice board (building a strategy, the "
            .. "room in 3D, assigning a raid). Nothing you do there is saved or shared.", 0.62, 0.62, 0.62, true)
        GameTooltip:Show()
    end)
    -- who is editing what right now: ask once the list is looked at
    f:HookScript("OnShow", function()
        if ns.StrategyCollab then ns.StrategyCollab:Query() end
    end)
    return f
end

-- New strategy and the ? at the top right of the Raids tab (left of Start / End raid while it shows).
local function placeActions(d)
    local p = lib:GetParent()
    local session = p and p.sessionBtn and p.sessionBtn:IsShown() and p.sessionBtn or nil
    local prev = session
    for _, b in ipairs({ d.newBtn, d.tourBtn }) do
        b:ClearAllPoints()
        if b:IsShown() then
            if prev then b:SetPoint("RIGHT", prev, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", lib, "TOPRIGHT", -PAD, 30) end
            prev = b
        end
    end
end

function View:RefreshLibrary()
    if not lib or not lib:IsVisible() then return end
    local tree = S():GetRaidTree()
    -- what was picked on the left must still exist
    local okBoss, okRaid = false, false
    for _, raid in ipairs(tree) do
        okRaid = okRaid or raid.key == state.raid
        for _, b in ipairs(raid.bosses) do okBoss = okBoss or b.ref == state.boss end
    end
    if not okBoss then state.boss = nil end
    if not okRaid then state.raid = nil end

    -- the raids: how many strategies (and drafts of mine) pass the search / member filter under each; the raid picked
    -- (or the picked boss') shows its bosses
    local counts, drafts = {}, {}
    local total, totalDrafts = 0, 0
    for _, s in ipairs(S():Find(findFilter(false))) do
        counts[s.b] = (counts[s.b] or 0) + 1
        total = total + 1
    end
    local myDrafts = Board():GetDrafts()
    for _, dr in ipairs(myDrafts) do
        if draftShown(dr, false) then
            drafts[dr.b] = (drafts[dr.b] or 0) + 1
            totalDrafts = totalDrafts + 1
        end
    end
    local open = state.raid or raidOf(state.boss)
    local rows = { { name = "All raids", count = total, drafts = totalDrafts } }
    for _, raid in ipairs(tree) do
        local head = { raid = raid.key, name = raid.name, short = INST_SHORT[instOf(raid.key)], count = 0, drafts = 0 }
        rows[#rows + 1] = head
        local last
        for _, b in ipairs(raid.bosses) do
            head.count = head.count + (counts[b.ref] or 0)
            head.drafts = head.drafts + (drafts[b.ref] or 0)
            if open == raid.key then
                last = { ref = b.ref, name = b.name, count = counts[b.ref] or 0, drafts = drafts[b.ref] or 0 }
                rows[#rows + 1] = last
            end
        end
        if last then last.last = true end
    end
    lib.list:SetData(rows)

    -- the filter row
    if lib.by.Refresh then lib.by:Refresh() end
    lib.clear:SetShown(filtered())

    -- the strategies
    local d = lib.detail
    d.newBtn:SetShown(S():CanBuild())
    placeActions(d)
    -- never looked at the tutorial: offer it (once per session, until it is started or turned down)
    if S():CanBuild() then ns.Tour:Offer("strategy", function() return d.tourBtn end) end
    local list = {}
    for _, dr in ipairs(myDrafts) do
        if draftShown(dr, true) then list[#list + 1] = { draft = dr } end
    end
    for _, s in ipairs(S():Find(findFilter(true))) do list[#list + 1] = { s = s } end
    if filtered() then
        d.list:SetEmptyText("No strategy matches the filters.")
    elseif state.boss then
        d.list:SetEmptyText("No strategy for this boss yet.")
    elseif state.raid then
        d.list:SetEmptyText("No strategy for this raid yet.")
    else
        d.list:SetEmptyText("No strategies yet.")
    end
    d.list:SetData(list)
end

function View:SelectBoss(ref)
    state.boss, state.raid = ref, nil
    self:RefreshLibrary()
end

-- A raid (an ItemDB raid key), or nil for all raids.
function View:SelectRaid(key)
    state.boss, state.raid = nil, key
    self:RefreshLibrary()
end

-- Sets the whole filter: { raid =, boss =, text =, by = nil | "@me" | "@co" | a member's key }.
function View:SetFilter(f)
    f = type(f) == "table" and f or {}
    state.raid, state.boss = f.raid, f.boss
    if state.boss then state.raid = nil end
    state.text = ns.Util.Trim(tostring(f.text or ""))
    state.by = type(f.by) == "string" and f.by or nil
    if lib and lib.search:GetText() ~= state.text then lib.search:SetText(state.text) end
    self:RefreshLibrary()
end

function View:GetFilter()
    return { raid = state.raid, boss = state.boss, text = state.text, by = state.by }
end

-- The library's frame (nil until the Raids tab made it): the tutorial points at its controls.
function View:GetLibrary() return lib end

-- The library's rows as shown (for tests): the raids column's rows and the strategy rows.
function View:GetRows()
    return lib and lib.list:GetData() or {}, lib and lib.detail.list:GetData() or {}
end

---------------------------------------------------------------------------
-- Share: the collaborators of one of my strategies
---------------------------------------------------------------------------

local function shareSet()
    local set = {}
    for _, key in ipairs(shareWin and shareWin.id and S():GetCollaborators(shareWin.id) or {}) do set[key] = true end
    return set
end

local function shareItems()
    local g = ns.Guild
    local out = {}
    local set = shareSet()
    for _, key in ipairs(g and g.GetMembers and g:GetMembers() or {}) do
        if not ns.Util.IsMe(key) then
            out[#out + 1] = { key = key, text = shortName(key), classFile = g:GetClass(key), note = g:GetRankName(key),
                              dim = not g:IsOnline(key) }
            set[key] = nil
        end
    end
    -- a collaborator who left the guild can still be taken off
    for key in pairs(set) do out[#out + 1] = { key = key, text = shortName(key), note = "not in the guild", dim = true } end
    tsort(out, function(a, b) return a.text:lower() < b.text:lower() end)
    return out
end

-- A collaborator: class circle, name, guild rank, and the bin that takes them off (quiet until hovered).
local function initShareRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(1, 1, 1, 0.05)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 0, 0)
        row.fs = newText(row, "GameFontHighlight", 12)
        row.fs:SetPoint("LEFT", 22, 0)
        row.note = newText(row, "GameFontHighlightSmall", 11)
        row.note:SetTextColor(0.62, 0.62, 0.62)
        row.note:SetPoint("LEFT", 170, 0)
        row.remove = UI():CreateRemoveButton(row, "No longer a collaborator")
        row.remove:SetPoint("RIGHT", 0, 0)
        row.remove:SetScript("OnClick", function(self)
            local data = self:GetParent().__cdlData
            if data then View:ToggleCollaborator(data.key) end
        end)
        quietIcon(row.remove)
    end
    local g = ns.Guild
    UI():ClassIcon(row.icon, g and g.GetClass and g:GetClass(d.key))
    row.fs:SetText(UI():ColoredName(d.key))
    local rank = g and g.GetRankName and g:GetRankName(d.key) or nil
    row.note:SetText(rank or "not in the guild")
end

local SHARE_W = 340                  -- the window's content inside its sides

local function createShare()
    local w = UI():CreateWindow("DisasterZoneStrategyShare", "Collaborators", 380, 380)
    shareWin = w
    local c = w.content
    -- the strategy and its boss; what collaborators may do
    w.name = newText(c, "GameFontHighlight", 14)
    w.name:SetPoint("TOPLEFT", PAD, -10)
    w.boss = newText(c, "GameFontHighlightSmall", 11)
    w.boss:SetTextColor(0.62, 0.62, 0.62)
    w.boss:SetPoint("BOTTOMLEFT", w.name, "BOTTOMRIGHT", 8, 1)
    w.info = newText(c, "GameFontHighlightSmall", 11)
    w.info:SetTextColor(0.62, 0.62, 0.62)
    w.info:SetPoint("TOPLEFT", PAD, -32)
    w.info:SetWidth(SHARE_W)
    w.info:SetWordWrap(true)
    w.info:SetText("The guild members you invite here can change this strategy with you. Only you invite and remove; "
        .. "you, the GM and the guild council delete.")
    w.picker = UI():CreateSearchDropdown(c, SHARE_W, {
        placeholder = "Invite guild members...",
        emptyText = "No matching guild members.",
        getItems = shareItems,
        isChecked = function(key) return shareSet()[key] and true or false end,
        onToggle = function(key) View:ToggleCollaborator(key) end,
    })
    local y = 32 + 3 * 13 + 12       -- (the explanation takes three lines)
    w.picker.frame:SetPoint("TOPLEFT", PAD, -y)
    -- the collaborators: how many of the most, then the list
    y = y + 22 + 16
    w.status = newText(c, "GameFontNormalSmall", 11)
    w.status:SetPoint("TOPLEFT", PAD, -y)
    w.line = c:CreateTexture(nil, "BORDER")
    w.line:SetPoint("TOPLEFT", PAD, -(y + 18))
    w.line:SetSize(SHARE_W, 1)
    w.line:SetColorTexture(1, 1, 1, 0.08)
    w.list = UI():CreateScrollList(c, 24, initShareRow)
    w.list.frame:SetPoint("TOPLEFT", PAD, -(y + 22))
    w.list.frame:SetPoint("BOTTOMLEFT", PAD, PAD)
    w.list.frame:SetWidth(SHARE_W + 20)
    w.list.emptyText:SetFontObject("GameFontDisableSmall")
    w.list:SetEmptyText("Nobody yet: only you, the GM and the guild council can change it.")
    w:Hide()
    return w
end

-- Opens the collaborators of one of my strategies.
function View:OpenShare(id)
    if not S():IsOwner(id) then
        ns:Print("Only the owner of a strategy picks its collaborators.")
        return false
    end
    if not shareWin then createShare() end
    shareWin.id = id
    shareWin:Show()
    shareWin:Raise()
    self:RefreshShare()
    return true
end

function View:GetShareWindow() return shareWin end

-- Invites a guild member to my strategy, or takes them off (shared at once).
function View:ToggleCollaborator(key)
    local id = shareWin and shareWin.id
    if not id or type(key) ~= "string" then return false end
    local ok, err
    if shareSet()[key] then ok, err = S():RemoveCollaborator(id, key) else ok, err = S():AddCollaborator(id, key) end
    if not ok then ns:Print("Could not change the collaborators: %s", tostring(err)) end
    self:RefreshShare()
    return ok and true or false
end

function View:RefreshShare()
    if not shareWin or not shareWin:IsShown() then return end
    local s = shareWin.id and S():GetStrategy(shareWin.id)
    if not s or not S():IsOwner(s.id) then
        shareWin:Hide()
        return
    end
    shareWin.name:SetText(s.n)
    fitText(shareWin.boss, bossVariants(S():GetBossName(s.b)), SHARE_W - (shareWin.name:GetStringWidth() or 0) - 8)
    local rows = {}
    for _, key in ipairs(s.co or {}) do rows[#rows + 1] = { key = key } end
    tsort(rows, function(a, b) return shortName(a.key):lower() < shortName(b.key):lower() end)
    shareWin.status:SetText(#rows .. " / " .. S().MAX_COLLAB .. " collaborators")
    shareWin.list:SetData(rows)
    if shareWin.picker.IsOpen and shareWin.picker:IsOpen() then shareWin.picker:RefreshRows() end
end

---------------------------------------------------------------------------
-- A planned raid's Assignments tab
---------------------------------------------------------------------------

-- The strategy picker of a raid's boss row: every strategy of the boss, who made it and how big; the one the raid
-- uses is ticked. A pick is saved at once.
local function pickMenu(row, root)
    local d = row.__cdlData
    if not d then return end
    root:CreateTitle(d.name)
    local last = S():GetLastPick(d.ref, d.occ)
    for _, s in ipairs(S():GetStrategies(d.ref)) do
        local owner = s.ow or s.by
        local extra = ("%s · %d slots%s"):format(shortName(owner), #S():GetSlots(s), pagesText(#s.p))
        if s.id == last then extra = extra .. " · used last time" end
        local radio = root:CreateRadio(s.n .. "  " .. grey(extra), function() return d.s and d.s.id == s.id end,
            function() View:PickStrategy(d.occ, d.ref, s.id) end)
        if radio and radio.SetTooltip then
            radio:SetTooltip(function(tooltip)
                tooltip:AddLine(s.n, 1, 0.82, 0)
                tooltip:AddLine(("By %s, saved %s"):format(shortName(owner), shortDate(s.rev)), 1, 1, 1)
                tooltip:AddLine(("%d player slots%s"):format(#S():GetSlots(s), pagesText(#s.p)), 1, 1, 1)
                if s.id == last then tooltip:AddLine("The guild used it for this boss last time.", 0.2, 1, 0.6, true) end
            end)
        end
    end
    -- none at all: the raid goes without a strategy for this boss (e.g. its only one is still a work in progress)
    root:CreateDivider()
    local radio = root:CreateRadio("No strategy", function() return d.how == "none" end,
        function() View:PickStrategy(d.occ, d.ref, nil) end)
    if radio and radio.SetTooltip then
        radio:SetTooltip(function(tooltip)
            tooltip:AddLine("No strategy", 1, 0.82, 0)
            tooltip:AddLine("This raid goes without one for this boss: nothing is assigned, no raid marks. The names "
                .. "already in its slots stay for a later pick.", 1, 1, 1, true)
        end)
    end
end

-- A raid's boss as a tile (the Teams plates' look, two a row): the boss's Encounter Journal picture on the left
-- (Data/BossJournal.lua; else the creature's portrait), its name and how many of its strategy's slots are filled,
-- under them the strategy (a gold link-dropdown for who arranges the raid, the name for everyone else) and my jobs,
-- Assign on the right, a bar along the bottom that fills with the slots. A boss without a strategy is a well (Create
-- for who builds strategies). A click opens the boss's board.

-- The strategy's link-dropdown: the name with a small gold chevron (b:SetText / GetText / OpenMenu).
local function newPickLink(row)
    local b = CreateFrame("Button", nil, row)
    b:SetHeight(16)
    local fs = newText(b, "GameFontHighlightSmall", 11)
    fs:SetPoint("LEFT", 0, 0)
    fs:SetTextColor(0.9, 0.85, 0.66)
    b:SetFontString(fs)
    b.fs = fs
    b.chev = b:CreateTexture(nil, "ARTWORK")
    b.chev:SetSize(9, 9)
    b.chev:SetTexture(UI().ICON_ATLAS)
    b.chev:SetTexCoord(unpack(UI():IconCoords(UI().ICON.chevron)))
    b.chev:SetVertexColor(1, 0.82, 0)
    b.chev:SetPoint("LEFT", fs, "RIGHT", 4, -1)
    -- (b.warn: "not picked yet" / "unsaved names" turns it orange)
    function b:Paint()
        local data = row.__cdlData
        if self.warn then self.fs:SetTextColor(1, 0.6, 0.2)
        elseif data and data.how == "none" then self.fs:SetTextColor(0.6, 0.6, 0.6)
        else self.fs:SetTextColor(0.9, 0.85, 0.66) end
    end
    function b:OpenMenu() UI():ContextMenu(self, function(root) pickMenu(row, root) end) end
    b:SetScript("OnClick", function(self) self:OpenMenu() end)
    b:SetScript("OnEnter", function(self)
        self.fs:SetTextColor(1, 0.82, 0)
        local data = row.__cdlData
        if data and data.how == "none" then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("No strategy for " .. data.name)
            GameTooltip:AddLine("Picked for this raid. Pick a strategy to use one again.", 1, 1, 1, true)
            GameTooltip:Show()
            return
        end
        if not (data and data.s) then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(data.s.n)
        GameTooltip:AddLine("The strategy for " .. data.name, 0.7, 0.7, 0.7)
        if self.warn == "unsaved names" then
            GameTooltip:AddLine("Names typed on its board are not saved yet: open the board to save them.", 1, 0.6, 0.2, true)
        end
        if data.how == "picked" then
            GameTooltip:AddLine("Picked for this raid. Pick another to switch: names in the slots both strategies "
                .. "have stay.", 1, 1, 1, true)
        elseif data.how == "last" then
            GameTooltip:AddLine("Not picked yet: this raid uses the strategy the guild used last time. Pick one to "
                .. "keep it.", 1, 1, 1, true)
        elseif data.how == "first" then
            GameTooltip:AddLine("Not picked yet: this raid uses the first one by name. Pick one to keep it.", 1, 1, 1, true)
        else
            GameTooltip:AddLine("The only strategy for this boss.", 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        self:Paint()
        GameTooltip:Hide()
    end)
    return b
end

local function newBossTile(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(RAID_TILE_H)
    row.base = row:CreateTexture(nil, "BACKGROUND", nil, -2)
    row.base:SetAllPoints()
    row.tint = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row.tint:SetAllPoints()
    gradient(row.tint, "HORIZONTAL", 1, 1, 1, 0.035, 0.012)
    row.top = row:CreateTexture(nil, "BORDER")
    row.top:SetPoint("TOPLEFT", 0, 0)
    row.top:SetPoint("TOPRIGHT", 0, 0)
    row.top:SetHeight(1)
    row.top:SetColorTexture(1, 1, 1, 0.06)
    row.shade = row:CreateTexture(nil, "BACKGROUND", nil, 0)
    row.shade:SetPoint("TOPLEFT", 0, 0)
    row.shade:SetPoint("TOPRIGHT", 0, 0)
    row.shade:SetHeight(4)
    gradient(row.shade, "VERTICAL", 0, 0, 0, 0, 0.85)
    row.hl = row:CreateTexture(nil, "HIGHLIGHT")
    row.hl:SetAllPoints()
    row.hl:SetColorTexture(1, 1, 1, 0.04)
    -- the slots' bar along the bottom
    row.track = row:CreateTexture(nil, "BORDER")
    row.track:SetPoint("BOTTOMLEFT", 0, 0)
    row.track:SetPoint("BOTTOMRIGHT", 0, 0)
    row.track:SetHeight(2)
    row.track:SetColorTexture(1, 1, 1, 0.05)
    row.bar = row:CreateTexture(nil, "ARTWORK", nil, 1)
    row.bar:SetPoint("BOTTOMLEFT", 0, 0)
    row.bar:SetHeight(2)
    -- the boss: the journal's picture (128x64, its feet on the tile's foot), else a round portrait
    row.ej = row:CreateTexture(nil, "ARTWORK")
    row.ej:SetSize(100, 50)
    row.ej:SetPoint("BOTTOMLEFT", -6, 2)
    row.face = row:CreateTexture(nil, "ARTWORK")
    row.face:SetSize(34, 34)
    row.face:SetPoint("LEFT", 22, 0)
    row.l1 = newText(row, "GameFontHighlight", 13)
    row.l1:SetPoint("TOPLEFT", RAID_TEXT_X, -15)
    row.stat = newText(row, "GameFontHighlightSmall", 11)
    row.stat:SetJustifyH("RIGHT")
    row.pick = newPickLink(row)
    row.pick:SetPoint("TOPLEFT", RAID_TEXT_X, -34)
    row.l2 = newText(row, "GameFontHighlightSmall", 11)
    row.jobs = newText(row, "GameFontHighlightSmall", 10)
    row.jobs:SetJustifyH("RIGHT")
    row.jobs:SetTextColor(0.56, 0.89, 0.62)
    row.assign = UI():CreateSleekButton(row, "Assign", 62, 20, function(self)
        local data = self:GetParent().__cdlData
        if data then Board():OpenRaid(data.occ, data.ref, "fill") end
    end)
    row.assign:SetPoint("RIGHT", -10, 0)
    row.create = UI():CreateSleekButton(row, "Create", 62, 20, function(self)
        local data = self:GetParent().__cdlData
        if data then Board():OpenRaid(data.occ, data.ref) end
    end)
    row.create:SetPoint("RIGHT", -10, 0)
    row:SetScript("OnClick", function(self)
        local data = self.__cdlData
        if data and data.s then Board():OpenRaid(data.occ, data.ref) end
    end)
    row:SetScript("OnEnter", function(self)
        local data = self.__cdlData
        if not data then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(data.name)
        GameTooltip:AddLine(data.s and "Click to open its board: who does what."
            or (data.how == "none" and "This raid goes without a strategy for this boss.")
            or "No strategy for this boss yet.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

-- The boss's picture on the tile: the journal's, else the creature's portrait (round), else the raid's skull.
local function paintBossArt(row, ref, none)
    local fid = ns.Data and ns.Data.BossJournal and ns.Data.BossJournal[ref]
    row.ej:SetShown(fid ~= nil)
    row.face:SetShown(fid == nil)
    if fid then
        row.ej:SetTexture(fid)
        row.ej:SetTexCoord(0, 1, 0, 1)
        if row.ej.SetDesaturated then row.ej:SetDesaturated(none) end
        row.ej:SetAlpha(none and 0.35 or 1)
        return
    end
    local list = ns.Data and ns.Data.BossPortraits and ns.Data.BossPortraits[ref]
    local disp = list and list[1] and list[1].d
    if disp and SetPortraitTextureFromCreatureDisplayID then
        row.face:SetTexCoord(0, 1, 0, 1)
        pcall(SetPortraitTextureFromCreatureDisplayID, row.face, disp)
    else
        row.face:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
        row.face:SetTexCoord(0, 1, 0, 1)
    end
    if row.face.SetDesaturated then row.face:SetDesaturated(none) end
    row.face:SetAlpha(none and 0.35 or 1)
end

-- n of the strategy's slots filled, n of them mine (the raid's fill for it).
local function slotCounts(s, fill)
    local slots = S():GetSlots(s)
    local a = (fill and fill.s == s.id) and fill.a or {}
    local n, mine = 0, 0
    local me = ns.Util.PlayerKey()
    for _, slot in ipairs(slots) do
        if a[slot.ref] then
            n = n + 1
            if a[slot.ref] == me then mine = mine + 1 end
        end
    end
    return n, #slots, mine
end

local function fillBossTile(row, d)
    row.__cdlData = d
    local s, fill = d.s, d.fill
    local arranger = S():CanAssign(d.occ)
    local none = s == nil
    -- (the raid picked none, though the boss has strategies: who arranges can pick one again from the link)
    local off = none and d.how == "none"
    row.base:SetColorTexture(none and 0.051 or 0.094, none and 0.051 or 0.094, none and 0.063 or 0.11, 1)
    row.tint:SetShown(not none)
    row.top:SetShown(not none)
    row.shade:SetShown(none)
    paintBossArt(row, d.ref, none)
    row.l1:SetText(d.name)
    row.l1:SetTextColor(none and 0.54 or 1, none and 0.54 or 1, none and 0.54 or 1)
    local filled, total, mine = 0, 0, 0
    if s then filled, total, mine = slotCounts(s, fill) end
    local full = total > 0 and filled >= total
    row.stat:SetText(s and ((full and "|cff8fe39d" .. filled .. "|r" or filled) .. grey("/" .. total)) or "")
    row.jobs:SetText(mine > 0 and (mine .. (mine == 1 and " job" or " jobs") .. " for you") or "")
    local share = total > 0 and min(1, filled / total) or 0
    row.track:SetShown(not none)
    row.bar:SetShown(share > 0)
    row.bar:SetWidth(max(1, floor((row:GetWidth() or 0) * share + 0.5)))
    if full then row.bar:SetColorTexture(0.56, 0.89, 0.62, 0.9) else row.bar:SetColorTexture(1, 0.82, 0, 0.7) end
    -- line 2: the strategy (who arranges: its dropdown, then whether it still has to be picked; else the name)
    row.pick:SetShown(arranger and (s ~= nil or off))
    row.l2:ClearAllPoints()
    if arranger and off then
        row.pick.warn = nil
        row.pick.fs:SetWidth(0)
        row.pick:SetText("No strategy")
        row.pick.fs:SetTextColor(0.6, 0.6, 0.6)
        row.pick:SetWidth(ceil((row.pick.fs.GetUnboundedStringWidth and row.pick.fs:GetUnboundedStringWidth()
            or row.pick.fs:GetStringWidth()) or 70) + 14)
        row.l2:SetPoint("LEFT", row.pick, "RIGHT", 8, 1)
        row.l2:SetText("")
    elseif arranger and s then
        -- names typed on the board but not saved, else a boss with several strategies where none was picked: the
        -- link turns orange (its tooltip says why; the tool row counts the bosses to pick)
        row.pick.warn = (Board():FillDraft(d.occ, d.ref) and "unsaved names")
            or ((d.count > 1 and d.how ~= "picked") and "not picked yet") or nil
        -- (as wide as the name, up to where my jobs and Assign start; a longer name is cut, its tooltip has it)
        local room = floor((row:GetWidth() or 0) - RAID_TEXT_X - 84 - (mine > 0 and ((row.jobs:GetStringWidth() or 0) + 10) or 0))
        if room < 60 then room = RAID_PICK_MAX end
        row.pick.fs:SetWidth(0)
        row.pick:SetText(s.n)
        row.pick:Paint()
        local fs = row.pick.fs
        local tw = ceil((fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()) or 0)
        if tw + 14 > room then row.pick.fs:SetWidth(room - 14) end
        row.pick:SetWidth(min(room, tw + 14))
        row.l2:SetPoint("LEFT", row.pick, "RIGHT", 8, 1)
        row.l2:SetText("")
    else
        row.l2:SetPoint("TOPLEFT", RAID_TEXT_X, -36)
        row.l2:SetText(s and ("|cffe6d9a8" .. s.n .. "|r")
            or grey(off and "No strategy for this raid" or "No strategy for this boss yet"))
    end
    row.assign:SetShown(arranger and s ~= nil)
    row.create:SetShown(none and not off and S():CanBuild())
    local btn = row.assign:IsShown() and row.assign or (row.create:IsShown() and row.create) or nil
    -- the count and my jobs end where the button starts
    row.stat:ClearAllPoints()
    row.stat:SetPoint("RIGHT", row, "TOPRIGHT", btn and -84 or -12, -22)
    row.jobs:ClearAllPoints()
    row.jobs:SetPoint("RIGHT", row, "TOPRIGHT", btn and -84 or -12, -41)
    row:Show()
end

-- The raid picks a strategy for a boss (the tile's dropdown).
function View:PickStrategy(occId, bossRef, stratId)
    local ok, err = S():PickStrategy(occId, bossRef, stratId)
    if not ok then
        ns:Print("Could not pick the strategy: %s", tostring(err))
        return false
    end
    if ns.RaidPlanUI and ns.RaidPlanUI.RefreshUpcoming then ns.RaidPlanUI:RefreshUpcoming() end
    return true
end

-- The frame shown in a planned raid's page (RaidPlanUI adds it as the Assignments tab): a tool row (what the tiles
-- add up to), the tiles two a row in a scroll frame. f.list keeps the old list's handles (tests, tools):
-- list.box:ForEachFrame(fn) over the shown tiles.
function View:CreateRaidAssignments(parent)
    local f = CreateFrame("Frame", nil, parent)
    assign = f
    f.hint = newText(f, "GameFontHighlightSmall", 11)
    f.hint:SetTextColor(0.55, 0.55, 0.55)
    f.hint:SetPoint("LEFT", f, "TOPLEFT", 0, -13)
    f.scroll = UI():CreateScrollFrame(f)
    f.scroll:SetPoint("TOPLEFT", 0, -RAID_TOP)
    f.scroll:SetPoint("BOTTOMRIGHT", 0, 0)
    f.content = CreateFrame("Frame", nil, f.scroll)
    f.content:SetSize(INNER_W, 10)
    f.scroll:SetScrollChild(f.content)
    f.tiles = {}
    f.empty = newText(f, "GameFontDisable", 12)
    f.empty:SetJustifyH("CENTER")
    f.empty:SetPoint("TOP", f, "TOP", 0, -RAID_TOP - 30)
    f.list = {
        box = { ForEachFrame = function(_, fn)
            for _, t in ipairs(f.tiles) do if t:IsShown() then fn(t) end end
        end },
        SetEmptyText = function(_, text) f.empty:SetText(text or "") end,
        GetData = function() return f.rows or {} end,
    }
    return f
end

-- What a raid's bosses add up to: { bosses, ready (every slot filled), toPick (several strategies, none picked),
-- none (no strategy), jobs (slots with my name) }.
function View:RaidSummary(v)
    local out = { bosses = 0, ready = 0, toPick = 0, none = 0, jobs = 0 }
    if not v then return out end
    local counts = S():CountByBoss()
    for _, b in ipairs(S():GetRaidBosses(v)) do
        out.bosses = out.bosses + 1
        local s, fill, how = S():GetRaidStrategy(v.id, b.ref)
        if s then
            local n, total, mine = slotCounts(s, fill)
            if total > 0 and n >= total then out.ready = out.ready + 1 end
            out.jobs = out.jobs + mine
            if (counts[b.ref] or 0) > 1 and how ~= "picked" then out.toPick = out.toPick + 1 end
        elseif how ~= "none" then
            out.none = out.none + 1
        end
    end
    return out
end

function View:RefreshRaid(v)
    if not assign then return end
    local f = assign
    local rows = {}
    if v then
        local counts = S():CountByBoss()
        for _, b in ipairs(S():GetRaidBosses(v)) do
            local s, fill, how = S():GetRaidStrategy(v.id, b.ref)
            rows[#rows + 1] = { occ = v.id, ref = b.ref, name = b.name, s = s, fill = fill, how = how,
                                count = counts[b.ref] or 0 }
        end
    end
    f.rows = rows
    -- the tool row: my jobs, the bosses still to pick (who arranges), those without a strategy
    local parts = {}
    if v and #rows > 0 then
        local sum = self:RaidSummary(v)
        if sum.jobs > 0 then parts[#parts + 1] = "|cff8fe39d" .. sum.jobs .. (sum.jobs == 1 and " job" or " jobs") .. " for you|r" end
        if sum.toPick > 0 and S():CanAssign(v.id) then
            parts[#parts + 1] = "|cffe8e8e8" .. sum.toPick .. "|r" .. (sum.toPick == 1 and " boss" or " bosses") .. " to pick"
        end
        if sum.none > 0 then parts[#parts + 1] = "|cffe8e8e8" .. sum.none .. "|r without a strategy" end
        if #parts == 0 then parts[1] = "Click a boss to open its board: who does what." end
    end
    f.hint:SetText(tconcat(parts, "   ·   "))
    -- the tiles, two a row
    local width = (f:GetWidth() or 0)
    if width < 300 then width = INNER_W end
    local w = floor((width - GAP) / 2)
    for i, d in ipairs(rows) do
        local t = f.tiles[i] or newBossTile(f.content)
        f.tiles[i] = t
        local c, r = (i - 1) % 2, floor((i - 1) / 2)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", f.content, "TOPLEFT", c * (w + GAP) + (c == 1 and (width - 2 * w - GAP) or 0), -r * (RAID_TILE_H + GAP))
        t:SetSize(w, RAID_TILE_H)
        fillBossTile(t, d)
    end
    for i = #rows + 1, #f.tiles do
        f.tiles[i]:Hide()
        f.tiles[i].__cdlData = nil
    end
    f.content:SetSize(width, max(1, ceil(#rows / 2) * (RAID_TILE_H + GAP) - GAP))
    f.empty:SetText(v and #rows == 0 and "This raid has no boss list (\"Other\" raids have no strategy boards)." or "")
    f.empty:SetShown(v ~= nil and #rows == 0)
end

function View:OnInit()
    ns:On("STRATEGY_DRAFTS_CHANGED", function()
        ns.Util.Debounce("strategies-ui-drafts", 0.3, function()
            View:RefreshLibrary()
            if assign and assign:IsVisible() and ns.RaidPlanUI and ns.RaidPlanUI.RefreshUpcoming then
                ns.RaidPlanUI:RefreshUpcoming()
            end
        end)
    end)
    ns:On("ROSTER_UPDATED", function() View:RefreshShare() end)
    ns:On("STRATEGY_PRESENCE_CHANGED", function()
        ns.Util.Debounce("strategies-ui-presence", 0.3, function() View:RefreshLibrary() end)
    end)
    ns:On("STRATEGY_CHANGED", function()
        ns.Util.Debounce("strategies-ui", 0.2, function()
            View:RefreshLibrary()
            View:RefreshShare()
            if assign and assign:IsVisible() and ns.RaidPlanUI and ns.RaidPlanUI.RefreshUpcoming then
                ns.RaidPlanUI:RefreshUpcoming()
            end
        end)
    end)
end

if DisasterZoneBoot and DisasterZoneBoot.Run("UI/StrategiesView.lua", ...) then return end -- DisasterZone: UI/StrategiesView.lua
-- Where the strategy boards live in the Raids tab (Addendum K):
--   Strategies view   - the library, for every guild member to explore and build in (1.4: the board layout). A strip
--                       banner says what the list holds (all raids, a raid, a boss); under it the matching strategies
--                       as art rows grouped under their raid's header, and on the right a side card - the search, then
--                       the raids (a raid without a match greys, the open raid unfolds its bosses: All raids / a raid
--                       / one boss). A click on a row opens the board; Edit for the owner, the collaborators, the GM
--                       and the guild council; the row's More menu: Copy (the copy is yours) and Share (a link in
--                       chat) for everyone, Collaborators for the owner, Delete for the owner, the GM and the guild
--                       council. My unsaved drafts sit on top of their raid (continue / discard; saving one makes it a
--                       strategy). The member filter (By), the tutorial (?) and New strategy (the main action) sit on
--                       the Raids tab's view row, at its right.
--   Assignments tab   - of a planned raid (Upcoming): its bosses as tiles with their journal pictures, the strategy
--                       each uses and how many slots are filled; a click opens the board (everyone), Assign fills
--                       it. Who leads the raid (its own leader; a raid without one: the raid leaders) and the GM
--                       pick each boss' strategy in the tile's link-dropdown, saved at once; a boss not picked yet
--                       uses the one the guild used last.
local addonName, ns = ...

local View = ns:NewModule("StrategiesUI")

local Style = ns.Style

local tsort, tconcat = table.sort, table.concat
local min, max, ceil, floor = math.min, math.max, math.ceil, math.floor

-- The library: the board layout (Style.PAD at the page's sides, Style.GAP between blocks).
local PAD, GAP = Style.PAD, Style.GAP
local INNER_W = Style.INNER_W        -- the page inside its sides (the mock's anchored frames have no width)
local SIDE_W = 220                   -- the raids card on the right
local BY_W = 150                     -- the member filter on the view row
local HEAD_H = 24                    -- a raid's header over its strategies (UI:CreateSectionHeader "title")
local ACT = 24                       -- a row's icon buttons
-- A planned raid's Assignments tab.
local RAID_TILE_H = 62               -- a raid's boss tile (two a row)
local RAID_TEXT_X = 104              -- its texts start right of the boss's picture
local RAID_PICK_MAX = 200            -- its strategy's link-dropdown: as wide as the name, at most this
local RAID_TOP = 34                  -- the tab's tool row above the tiles

local function S() return ns.Strategy end
local function UI() return ns.UI end
local function Board() return ns.StrategyBoard end

-- The library's filter: raid (an ItemDB raid key) or boss (a boss ref) picked on the right (neither: all raids),
-- text = the free search, by = nil (anyone) | "@me" | "@co" (shared with me) | a member's key.
local state = { raid = nil, boss = nil, text = "", by = nil }
local lib, assign, shareWin

local function raidOf(ref)
    return type(ref) == "string" and ref:match("^(%w+):") or nil
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

local function plural(n, one, many) return n == 1 and ("1 " .. one) or (n .. " " .. (many or (one .. "s"))) end

-- The filter as Strategy:Find takes it; `scoped` adds the raid / boss picked on the right.
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
-- Library (Strategies view): the raids in the side card
---------------------------------------------------------------------------

-- "3", and my unsaved drafts as an orange "+1".
local function countText(d)
    local parts = {}
    if d.count > 0 then parts[#parts + 1] = tostring(d.count) end
    if (d.drafts or 0) > 0 then parts[#parts + 1] = Style:Wrap("WARN", "+" .. d.drafts) end
    return tconcat(parts, " ")
end

local function treeClick(self)
    local d = self.__cdlData
    if not d then return end
    if d.ref then View:SelectBoss(d.ref)
    elseif d.raid then View:SelectRaid(d.raid)
    else View:SelectRaid(nil) end
end

-- (what the orange count means; UI:AttachTooltip's title function: false = no tooltip)
local function treeTip(self, tt)
    local d = self.__cdlData
    if not (d and (d.drafts or 0) > 0) then return false end
    tt:AddLine(d.name, Style:Color("GOLD"))
    if d.count > 0 then tt:AddLine(plural(d.count, "strategy", "strategies"), Style:Color("TEXT")) end
    tt:AddLine(("%d unsaved %s of yours"):format(d.drafts, d.drafts == 1 and "draft" or "drafts"), Style:Color("WARN"))
end

-- One row of the raids list: All raids, a raid, or a boss of the open raid (indented) - the shared row looks
-- (UI:DecorateRow: the hover, the picked one's gold wash and bar), the name and its count.
local function initTreeRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        UI():DecorateRow(row, { selectable = true })
        row.fs = UI():Text(row, "emph", "TEXT")
        row.n = UI():Text(row, "small", "SUB", { justify = "RIGHT" })
        row.n:SetPoint("RIGHT", -6, 0)
        row:SetScript("OnClick", treeClick)
        UI():AttachTooltip(row, treeTip)
    end
    local kind = d.ref and "boss" or (d.raid and "raid" or "all")
    local lit = d.count > 0 or (d.drafts or 0) > 0
    row.n:SetText(countText(d))
    local room = (row:GetWidth() or 0) - 20 - (lit and ((row.n:GetStringWidth() or 0) + 8) or 0)
    if room < 60 then room = SIDE_W - 2 * Style.IN - 40 end
    row.fs:ClearAllPoints()
    local picked
    if kind == "raid" then
        -- a raid without a match greys
        UI():SetTextStyle(row.fs, "emph", lit and "GOLD" or "DIM")
        row.fs:SetPoint("LEFT", 8, 0)
        fitText(row.fs, { d.name, d.short or d.name }, room)
        picked = state.boss == nil and state.raid == d.raid
    elseif kind == "all" then
        UI():SetTextStyle(row.fs, "emph", "TEXT")
        row.fs:SetPoint("LEFT", 8, 0)
        row.fs:SetText(d.name)
        picked = state.boss == nil and state.raid == nil
    else
        UI():SetTextStyle(row.fs, "body", lit and "TEXT" or "DIM")
        row.fs:SetPoint("LEFT", 20, 0)
        fitText(row.fs, bossVariants(d.name), room - 12)
        picked = state.boss == d.ref
    end
    row:SetSelected(picked and true or false)
end

local function treeExtent(d)
    if d.ref then return Style.ROW.compact end
    return Style.ROW.list
end

---------------------------------------------------------------------------
-- Library: the strategies
---------------------------------------------------------------------------

-- The members changing a strategy right now (Core/StrategyCollab.lua): "A, B editing" in green, or nil.
local function editingText(id)
    local Collab = ns.StrategyCollab
    local names = {}
    for _, key in ipairs(Collab and Collab:GetEditors(id) or {}) do names[#names + 1] = ns.Util.ShortName(key) end
    if #names == 0 then return nil end
    return Style:Wrap("OK", tconcat(names, ", ") .. " editing")
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
    local whose = (owner and not ns.Util.IsMe(owner)) and (" by " .. ns.Util.ShortName(owner)) or ""
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

-- What a row's More menu holds for me: { icon, word, tooltip, fn, red }.
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
    local d = btn.row and btn.row.__cdlData
    if not d then return end
    local entries = moreEntries(d, btn)
    UI():ContextMenu(btn, function(root)
        for _, e in ipairs(entries) do
            if e[5] and #entries > 1 and root.CreateDivider then root:CreateDivider() end
            local text = e[5] and Style:Wrap("BAD", e[2]) or e[2]
            local b = root:CreateButton(UI():AtlasIconText(e[1], 14, Style.C[e[5] and "BAD" or "GOLD"]) .. "  " .. text, e[4])
            if b and b.SetTooltip then
                b:SetTooltip(function(tt)
                    tt:AddLine(e[2], Style:Color("GOLD"))
                    tt:AddLine(e[3], 1, 1, 1, true)
                end)
            end
        end
    end)
end

-- A click on a row opens the board to look at it (my draft: where I left it); Edit opens it to change it.
local function openRow(row, edit)
    local data = row.__cdlData
    if data and data.draft then Board():OpenDraft(data.draft.did)
    elseif data and data.s then Board():OpenStrategy(data.s.id, edit and "edit" or nil) end
end

-- A row of the strategies list: a raid's header (d.head) or a strategy / one of my drafts as an art row (the raid's
-- picture, the name and its tag, the second line; Edit and More at its right). row.edit, row.more, row.a (the art
-- row), row.head.
local function initStratRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        row.a = UI():CreateArtRow(row, { onClick = function() openRow(row) end })
        row.a:SetAllPoints()
        row.a.pill = UI():CreateTagPill(row.a, 16)      -- (made now: the row's tag is always there to ask)
        row.a.pill:Hide()
        row.more = UI():CreateTipIconButton(row.a.right, ACT, UI().ICON.more, "More", "", openMore)
        row.more.row = row
        row.more:SetPoint("RIGHT", row.a.right, "RIGHT", 0, 0)
        row.edit = UI():CreateTipIconButton(row.a.right, ACT, 16, "Edit", "", function() openRow(row, true) end)
        row.edit:SetPoint("RIGHT", row.more, "LEFT", -4, 0)
        row.head = UI():CreateSectionHeader(row, "", { style = "title" })
        row.head:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        row.head:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    end
    row.head:SetShown(d.head ~= nil)
    row.a:SetShown(d.head == nil)
    if d.head then
        row.head:SetTitle(d.name)
        row.head:SetCount(d.count)
        return
    end
    local draft, s = d.draft, d.s
    local item = draft or s

    -- what I can do: Edit (a draft: Continue) on the row, the rest in its More menu
    local canEdit = draft ~= nil or S():CanEditStrategy(s.id)
    row.edit:SetShown(canEdit)
    row.edit.tipTitle = draft and "Continue" or "Edit"
    row.edit.tipText = draft and "Opens the draft where you left it." or "Opens the strategy to change it."
    local words = {}
    for _, e in ipairs(moreEntries(d, row.more)) do words[#words + 1] = e[2] end
    row.more.tipText = tconcat(words, ", ")
    local rightW = ACT + (canEdit and (4 + ACT) or 0) + 8
    row.a:SetRightWidth(rightW)

    -- line 1: the name and its tag; line 2: the boss (unless the list is one boss'), who, when, how big, who edits now
    local tag = draft and "Draft" or (S():IsCollaborator(s.id) and "shared with you") or nil
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
    row.a:SetData({ art = raidOf(item.b) or "other", title = item.n, sub = line(boss, true, true),
        pill = tag and { draft and "warn" or "ok", tag } or nil })
    -- (too long: the boss without its title, then without the pages, then without the date - never cut)
    local rowW = row:GetWidth() or 0
    if rowW < 200 then rowW = INNER_W - SIDE_W - GAP - 20 end
    local room = rowW - row.a.textX - rightW - 8
    local short = boss and bossVariants(boss)[2] or boss
    local variants = { line(boss, true, true) }
    if short ~= boss then variants[#variants + 1] = line(short, true, true) end
    variants[#variants + 1] = line(short, false, true)
    variants[#variants + 1] = line(short, false, false)
    row.a.subText = fitText(row.a.sub, variants, room)
    row.a.l1, row.a.l2 = row.a.title, row.a.sub
    row.l1, row.l2, row.pill = row.a.title, row.a.sub, row.a.pill
end

local function stratExtent(d)
    if d.head then return HEAD_H + (d.first and 0 or GAP) end
    return Style.ROW.art
end

---------------------------------------------------------------------------
-- Library: the view row's controls (By, ?, New strategy) and the page
---------------------------------------------------------------------------

local function byOptions()
    local out = {
        { value = nil, text = "Anyone" },
        { value = "@me", text = "My strategies" },
        { value = "@co", text = "Shared with me" },
    }
    local authors = S():GetAuthors()
    tsort(authors, function(a, b) return ns.Util.ShortName(a.key):lower() < ns.Util.ShortName(b.key):lower() end)
    if #authors > 0 then out[#out + 1] = { isTitle = true, text = "Guild members" } end
    for _, a in ipairs(authors) do
        out[#out + 1] = { value = a.key, text = ns.Util.ShortName(a.key) .. "  (" .. a.n .. ")" }
    end
    -- a member picked earlier who has no strategy any more stays pickable (and so visible)
    if state.by and state.by:sub(1, 1) ~= "@" then
        local found = false
        for _, a in ipairs(authors) do found = found or a.key == state.by end
        if not found then out[#out + 1] = { value = state.by, text = ns.Util.ShortName(state.by) .. "  (0)" } end
    end
    return out
end

local function askName(bossRef)
    Board():Prompt("Name of the new strategy for " .. S():GetBossName(bossRef) .. " (e.g. 25 farm)", "", function(text)
        text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_NAME_LEN)
        if text ~= "" then Board():NewStrategy(bossRef, text) end
    end)
end

-- New strategy: for the boss picked on the right, else a menu of bosses to pick from.
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

local CLEAR = { text = "Clear filters", onClick = function() View:SetFilter({}) end }

-- The library on the board layout (the Raids tab's view row is its toolbar): a strip banner over the strategies and
-- the raids' side card. Fields the tutorial and the tests use: lib.search, lib.by, lib.clear, lib.list (the raids),
-- lib.detail (.list = the strategies, .newBtn, .tourBtn), lib.layout.
function View:CreateLibrary(parent)
    local f = CreateFrame("Frame", nil, parent)
    lib = f
    local L = UI():CreateLayout("board", f, { toolbar = false, bottom = 0, side = SIDE_W,
        hero = { size = "strip", title = "All raids" } })
    f.layout = L
    f.banner = L.banner

    -- the side card: the search, then the raids (Clear filters on their header while filtering)
    local side = L.side.body
    f.search = UI():CreateSearchBox(side, SIDE_W - 2 * Style.IN, function(text)
        text = ns.Util.Trim(text or "")
        if text == state.text then return end
        state.text = text
        View:RefreshLibrary()
    end, "Search strategies")
    f.search:SetPoint("TOPLEFT", side, "TOPLEFT", 0, 0)
    f.raidsHead = UI():CreateSectionHeader(side, "Raids", { style = "caps", action = CLEAR })
    f.raidsHead:SetPoint("TOPLEFT", f.search, "BOTTOMLEFT", 0, -GAP)
    f.raidsHead:SetPoint("RIGHT", side, "RIGHT", 0, 0)
    f.clear = f.raidsHead.action
    f.list = UI():CreateScrollList(side, Style.ROW.list, initTreeRow, treeExtent)
    f.list.frame:SetPoint("TOPLEFT", f.raidsHead, "BOTTOMLEFT", 0, -4)
    f.list.frame:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", 6, 0)

    -- the strategies
    local d = L.body
    f.detail = d
    d.list = UI():CreateScrollList(d, Style.ROW.art, initStratRow, stratExtent)
    d.list.frame:SetPoint("TOPLEFT", 0, 0)
    d.list.frame:SetPoint("BOTTOMRIGHT", 6, 0)

    -- the view's controls on the Raids tab's view row (its middle, 19 above the library): By, the tutorial behind a
    -- ? (what this view is in its tooltip), New strategy - the main action, at the far right
    f.by = UI():CreateDropdown(f, BY_W, byOptions, function() return state.by end, function(value)
        state.by = value
        View:RefreshLibrary()
    end)
    -- ("By" inside the dropdown, in front of the pick)
    local refreshBy = f.by.Refresh
    function f.by:Refresh()
        refreshBy(self)
        self:SetText(Style:Wrap("SUB", "By") .. "  " .. (self:GetText() or ""))
    end
    f.by:Refresh()
    d.newBtn = UI():CreateSleekButton(f, "New strategy", 110, Style.BTN_H, function(self) newStrategy(self) end, "primary")
    d.tourBtn = UI():CreateTipIconButton(f, Style.BTN_H, 11, "Strategies", HELP, function(self)
        if S():CanBuild() then ns.Tour:Menu(self, "strategy") end
    end)
    d.tourBtn:HookScript("OnEnter", function()
        if not S():CanBuild() then return end
        GameTooltip:AddLine("Click for the tutorial: a guided tour on a practice board (building a strategy, the "
            .. "room in 3D, assigning a raid). Nothing you do there is saved or shared.", Style.C.SUB[1], Style.C.SUB[2],
            Style.C.SUB[3], true)
        GameTooltip:Show()
    end)
    -- who is editing what right now: ask once the list is looked at
    f:HookScript("OnShow", function()
        if ns.StrategyCollab then ns.StrategyCollab:Query() end
    end)
    return f
end

-- New strategy, the ? and By at the right of the Raids tab's view row (left of Start / End raid while it shows),
-- on the row's middle.
local function placeActions(d)
    local p = lib:GetParent()
    local session = p and p.sessionBtn and p.sessionBtn:IsShown() and p.sessionBtn or nil
    local prev = session
    for _, b in ipairs({ d.newBtn, d.tourBtn, lib.by }) do
        b:ClearAllPoints()
        if b:IsShown() then
            if prev then b:SetPoint("RIGHT", prev, "LEFT", -6, 0) else b:SetPoint("RIGHT", lib, "TOPRIGHT", -PAD, 19) end
            prev = b
        end
    end
end

-- The strip banner: what the list holds (all raids, the raid or the boss picked), how many.
local function fillBanner(n, drafts, raidNames)
    local b = lib.banner
    if not b then return end
    local counts = plural(n, "strategy", "strategies")
        .. (drafts > 0 and (" · " .. plural(drafts, "unsaved draft") .. " of yours") or "")
    if state.boss then
        b:SetArt(raidOf(state.boss))
        b:SetTitle(S():GetBossName(state.boss))
        b:SetSub(S():GetRaidName(state.boss) .. " · " .. counts)
    elseif state.raid then
        b:SetArt(state.raid)
        b:SetTitle(raidNames[state.raid] or state.raid)
        b:SetSub(counts)
    else
        b:SetArt(nil)
        b:SetTitle("All raids")
        b:SetSub(counts .. (filtered() and " · filtered" or ""))
    end
end

function View:RefreshLibrary()
    if not lib or not lib:IsVisible() then return end
    local tree = S():GetRaidTree()
    -- what was picked on the right must still exist
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
    local raidNames = {}
    for _, raid in ipairs(tree) do
        raidNames[raid.key] = raid.name
        local head = { raid = raid.key, name = raid.name, short = ns.ItemDB:RaidShort(raid.key), count = 0, drafts = 0 }
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

    -- the controls: By, Clear filters (on the raids' header) while filtering
    if lib.by.Refresh then lib.by:Refresh() end
    lib.raidsHead:SetAction(filtered() and CLEAR or nil)
    lib.clear:SetShown(filtered())

    -- the strategies
    local d = lib.detail
    d.newBtn:SetShown(S():CanBuild())
    placeActions(d)
    -- (who can't build - outside a guild: a read-only notice over the board, as New strategy is left out)
    if S():CanBuild() then
        lib.layout:HideNotice()
    else
        lib.layout:ShowNotice("readonly", "Strategies are built inside a guild: you can look at them, not build or copy.")
    end
    -- never looked at the tutorial: offer it (once per session, until it is started or turned down)
    if S():CanBuild() then ns.Tour:Offer("strategy", function() return d.tourBtn end) end
    -- (my drafts first, then the strategies; grouped by raid in the raids' order, each group under its header)
    local list = {}
    for _, dr in ipairs(myDrafts) do
        if draftShown(dr, true) then list[#list + 1] = { draft = dr } end
    end
    local nDrafts = #list
    for _, s in ipairs(S():Find(findFilter(true))) do list[#list + 1] = { s = s } end
    local byRaid, order = {}, {}
    for _, e in ipairs(list) do
        local k = raidOf((e.draft or e.s).b) or "other"
        if not byRaid[k] then
            byRaid[k] = {}
            order[#order + 1] = k
        end
        local g = byRaid[k]
        g[#g + 1] = e
    end
    local rank = {}
    for i, raid in ipairs(tree) do rank[raid.key] = i end
    tsort(order, function(a, b) return (rank[a] or 999) < (rank[b] or 999) end)
    local shown = {}
    for gi, k in ipairs(order) do
        shown[#shown + 1] = { head = k, name = raidNames[k] or k, count = #byRaid[k],
                              first = gi == 1 }
        for _, e in ipairs(byRaid[k]) do shown[#shown + 1] = e end
    end
    d.rows = list
    fillBanner(#list - nDrafts, nDrafts, raidNames)
    -- (the illustrated empty state: what is missing, and the way on - Clear filters, or New strategy for who builds)
    local build = S():CanBuild()
    local newAction = build and { text = "New strategy", onClick = function(b) newStrategy(b) end } or nil
    if filtered() then
        d.list:SetEmptyState({ glyph = UI().ICON.notes, title = "No strategy matches the filters.",
            action = { text = "Clear filters", kind = "secondary", onClick = function() View:SetFilter({}) end } })
    elseif state.boss then
        d.list:SetEmptyState({ glyph = UI().ICON.notes, title = "No strategy for this boss yet.",
            text = build and "Draw one: a map with zones and arrows, and tables of jobs." or nil, action = newAction })
    elseif state.raid then
        d.list:SetEmptyState({ glyph = UI().ICON.notes, title = "No strategy for this raid yet.",
            text = build and "Draw one for any of its bosses." or nil, action = newAction })
    else
        d.list:SetEmptyState({ glyph = UI().ICON.notes, title = "No strategies yet.", text = HELP, action = newAction })
    end
    d.list:SetData(shown)
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

-- The library's rows as shown (for tests): the raids' rows and the strategy rows (my drafts, then the strategies;
-- without the raids' headers).
function View:GetRows()
    return lib and lib.list:GetData() or {}, lib and lib.detail.rows or {}
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
            out[#out + 1] = { key = key, text = ns.Util.ShortName(key), classFile = g:GetClass(key), note = g:GetRankName(key),
                              dim = not g:IsOnline(key) }
            set[key] = nil
        end
    end
    -- a collaborator who left the guild can still be taken off
    for key in pairs(set) do out[#out + 1] = { key = key, text = ns.Util.ShortName(key), note = "not in the guild", dim = true } end
    tsort(out, function(a, b) return a.text:lower() < b.text:lower() end)
    return out
end

-- A collaborator: class circle, name, guild rank, and the bin that takes them off (the shared row hover).
local function initShareRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        UI():DecorateRow(row, { hover = true })
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 2, 0)
        row.fs = UI():Text(row, "emph", "TEXT")
        row.fs:SetPoint("LEFT", 24, 0)
        row.note = UI():Text(row, "body", "SUB")
        row.note:SetPoint("LEFT", 170, 0)
        row.remove = UI():CreateRemoveButton(row, "No longer a collaborator")
        row.remove:SetPoint("RIGHT", 0, 0)
        row.remove:SetScript("OnClick", function(self)
            local data = self:GetParent().__cdlData
            if data then View:ToggleCollaborator(data.key) end
        end)
    end
    local g = ns.Guild
    UI():ClassIcon(row.icon, g and g.GetClass and g:GetClass(d.key))
    row.fs:SetText(UI():ColoredName(d.key))
    local rank = g and g.GetRankName and g:GetRankName(d.key) or nil
    row.note:SetText(rank or "not in the guild")
end

local SHARE_W, SHARE_H = 380, 420    -- the window

-- The Collaborators window on the tool layout: a strip banner (the strategy, its boss), what collaborators may do,
-- the picker, then who builds it under a caps header that counts them.
local function createShare()
    local w = UI():CreateWindow("DisasterZoneStrategyShare", "Collaborators", SHARE_W, SHARE_H)
    shareWin = w
    local L = UI():CreateLayout("tool", w.content, { width = SHARE_W - 10, banner = { size = "strip", icon = 19,
        title = " " } })
    w.layout = L
    local body = L.body
    w.name, w.boss = L.banner.title, L.banner.sub
    w.info = UI():Text(body, "body", "SUB", { wrap = true })
    w.info:SetPoint("TOPLEFT", 0, 0)
    w.info:SetPoint("RIGHT", 0, 0)
    w.info:SetText("The guild members you invite here can change this strategy with you. Only you invite and remove; "
        .. "you, the GM and the guild council delete.")
    w.picker = UI():CreateSearchDropdown(body, L.bodyW, {
        placeholder = "Invite guild members...",
        emptyText = "No matching guild members.",
        getItems = shareItems,
        isChecked = function(key) return shareSet()[key] and true or false end,
        onToggle = function(key) View:ToggleCollaborator(key) end,
    })
    w.picker.frame:SetPoint("TOPLEFT", 0, -(3 * 13 + GAP + 4))       -- (the explanation takes three lines)
    w.head = UI():CreateSectionHeader(body, "Who builds it", { style = "caps" })
    w.head:SetPoint("TOPLEFT", w.picker.frame, "BOTTOMLEFT", 0, -(GAP + 6))
    w.head:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    w.status = w.head.right
    w.list = UI():CreateScrollList(body, Style.ROW.list - 2, initShareRow)
    w.list.frame:SetPoint("TOPLEFT", w.head, "BOTTOMLEFT", 0, -4)
    w.list.frame:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 6, 0)
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
    local b = shareWin.layout.banner
    b:SetArt(raidOf(s.b))
    b:SetTitle(s.n)
    b:SetSub(fitText(b.sub, bossVariants(S():GetBossName(s.b)), shareWin.layout.innerW - 60))
    local rows = {}
    for _, key in ipairs(s.co or {}) do rows[#rows + 1] = { key = key } end
    tsort(rows, function(a, c) return ns.Util.ShortName(a.key):lower() < ns.Util.ShortName(c.key):lower() end)
    shareWin.head:SetRight(#rows .. " / " .. S().MAX_COLLAB .. " collaborators")
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
        local extra = ("%s · %d slots%s"):format(ns.Util.ShortName(owner), #S():GetSlots(s), pagesText(#s.p))
        if s.id == last then extra = extra .. " · used last time" end
        local radio = root:CreateRadio(s.n .. "  " .. Style:Wrap("DIM", extra), function() return d.s and d.s.id == s.id end,
            function() View:PickStrategy(d.occ, d.ref, s.id) end)
        if radio and radio.SetTooltip then
            radio:SetTooltip(function(tooltip)
                tooltip:AddLine(s.n, Style:Color("GOLD"))
                tooltip:AddLine(("By %s, saved %s"):format(ns.Util.ShortName(owner), shortDate(s.rev)), 1, 1, 1)
                tooltip:AddLine(("%d player slots%s"):format(#S():GetSlots(s), pagesText(#s.p)), 1, 1, 1)
                if s.id == last then tooltip:AddLine("The guild used it for this boss last time.", Style:Color("OK")) end
            end)
        end
    end
    -- none at all: the raid goes without a strategy for this boss (e.g. its only one is still a work in progress)
    root:CreateDivider()
    local radio = root:CreateRadio("No strategy", function() return d.how == "none" end,
        function() View:PickStrategy(d.occ, d.ref, nil) end)
    if radio and radio.SetTooltip then
        radio:SetTooltip(function(tooltip)
            tooltip:AddLine("No strategy", Style:Color("GOLD"))
            tooltip:AddLine("This raid goes without one for this boss: nothing is assigned, no raid marks. The names "
                .. "already in its slots stay for a later pick.", 1, 1, 1, true)
        end)
    end
end

-- A raid's boss as a tile (two a row): a card (inset for a boss without a strategy) with the boss's Encounter Journal
-- picture on the left (Data/BossJournal.lua; else the creature's portrait), its name and how many of its strategy's
-- slots are filled, under them the strategy (a link-dropdown for who arranges the raid, the name for everyone else)
-- and my jobs, Assign on the right, a bar along the bottom that fills with the slots. A boss without a strategy has
-- Create for who builds strategies. A click opens the boss's board.

-- The strategy's link-dropdown (UI:CreateLinkDropdown): b:SetText / GetText / OpenMenu; b.warn ("not picked yet" /
-- "unsaved names") turns it orange, a raid going without one is grey.
local function pickTip(row, tt)
    local data = row.__cdlData
    if data and data.how == "none" then
        tt:AddLine("No strategy for " .. data.name)
        tt:AddLine("Picked for this raid. Pick a strategy to use one again.", 1, 1, 1, true)
        return
    end
    if not (data and data.s) then return end
    tt:AddLine(data.s.n)
    tt:AddLine("The strategy for " .. data.name, Style:Color("SUB"))
    if row.pick.warn == "unsaved names" then
        tt:AddLine("Names typed on its board are not saved yet: open the board to save them.", Style:Color("WARN"))
    end
    if data.how == "picked" then
        tt:AddLine("Picked for this raid. Pick another to switch: names in the slots both strategies have stay.",
            1, 1, 1, true)
    elseif data.how == "last" then
        tt:AddLine("Not picked yet: this raid uses the strategy the guild used last time. Pick one to keep it.",
            1, 1, 1, true)
    elseif data.how == "first" then
        tt:AddLine("Not picked yet: this raid uses the first one by name. Pick one to keep it.", 1, 1, 1, true)
    else
        tt:AddLine("The only strategy for this boss.", 1, 1, 1, true)
    end
end

local function newPickLink(row)
    local b = UI():CreateLinkDropdown(row, { height = 16, size = Style.FONT.body, color = Style.C.TEXT,
        build = function(root) pickMenu(row, root) end, tip = function(tt) pickTip(row, tt) end })
    b:SetFontString(b.fs)
    -- (the warning colour stays while the mouse is off it)
    function b:Paint()
        local data = row.__cdlData
        if self.warn then self.fs:SetTextColor(Style:Color("WARN"))
        elseif data and data.how == "none" then self.fs:SetTextColor(Style:Color("SUB"))
        else self.fs:SetTextColor(Style:Color("TEXT")) end
    end
    b:HookScript("OnLeave", function(self) self:Paint() end)
    return b
end

-- (the tile is a card: it takes the clicks itself)
local function tileClick(self, button)
    if button ~= "LeftButton" or not self:IsMouseOver() then return end
    local data = self.__cdlData
    if data and data.s then Board():OpenRaid(data.occ, data.ref) end
end

local function newBossTile(parent)
    local row = UI():CreateCard(parent, { tone = "card" })
    row:SetHeight(RAID_TILE_H)
    row:EnableMouse(true)
    row:SetScript("OnMouseUp", tileClick)
    UI():DecorateRow(row, { hover = true })
    -- the slots' bar along the bottom (a hairline track, the filled share over it)
    row.track = UI():Rule(row, { bottom = 0 })
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
    row.l1 = UI():Text(row, "title", "TEXT")
    row.l1:SetPoint("TOPLEFT", RAID_TEXT_X, -15)
    row.stat = UI():Text(row, "body", "TEXT", { justify = "RIGHT" })
    row.pick = newPickLink(row)
    row.pick:SetPoint("TOPLEFT", RAID_TEXT_X, -34)
    row.l2 = UI():Text(row, "body", "TEXT")
    row.jobs = UI():Text(row, "small", "OK", { justify = "RIGHT" })
    row.assign = UI():CreateSleekButton(row, "Assign", 62, Style.ROW.compact - 2, function(self)
        local data = self:GetParent().__cdlData
        if data then Board():OpenRaid(data.occ, data.ref, "fill") end
    end)
    row.assign:SetPoint("RIGHT", -10, 0)
    row.create = UI():CreateSleekButton(row, "Create", 62, Style.ROW.compact - 2, function(self)
        local data = self:GetParent().__cdlData
        if data then Board():OpenRaid(data.occ, data.ref) end
    end)
    row.create:SetPoint("RIGHT", -10, 0)
    UI():AttachTooltip(row, function(self, tt)
        local data = self.__cdlData
        if not data then return false end
        tt:AddLine(data.name, Style:Color("GOLD"))
        tt:AddLine(data.s and "Click to open its board: who does what."
            or (data.how == "none" and "This raid goes without a strategy for this boss.")
            or "No strategy for this boss yet.", 1, 1, 1, true)
    end, nil, { anchor = "ANCHOR_TOP" })
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
    -- (a boss without a strategy: the inset well, its picture and name greyed)
    row:SetTone(none and "inset" or "card")
    paintBossArt(row, d.ref, none)
    row.l1:SetText(d.name)
    row.l1:SetTextColor(Style:Color(none and "SUB" or "TEXT"))
    local filled, total, mine = 0, 0, 0
    if s then filled, total, mine = slotCounts(s, fill) end
    local full = total > 0 and filled >= total
    row.stat:SetText(s and ((full and Style:Wrap("OK", filled) or filled) .. Style:Wrap("DIM", "/" .. total)) or "")
    row.jobs:SetText(mine > 0 and (mine .. (mine == 1 and " job" or " jobs") .. " for you") or "")
    local share = total > 0 and min(1, filled / total) or 0
    row.track:SetShown(not none)
    row.bar:SetShown(share > 0)
    row.bar:SetWidth(max(1, floor((row:GetWidth() or 0) * share + 0.5)))
    row.bar:SetColorTexture(Style:Color(full and "OK" or "GOLD"))
    -- line 2: the strategy (who arranges: its dropdown, then whether it still has to be picked; else the name)
    row.pick:SetShown(arranger and (s ~= nil or off))
    row.l2:ClearAllPoints()
    if arranger and off then
        row.pick.warn = nil
        row.pick.fs:SetWidth(0)
        row.pick:SetText("No strategy")
        row.pick:Paint()
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
        row.l2:SetText(s and Style:Wrap("TEXT", s.n)
            or Style:Wrap("DIM", off and "No strategy for this raid" or "No strategy for this boss yet"))
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
    f.hint = UI():Text(f, "body", "SUB")
    f.hint:SetPoint("LEFT", f, "TOPLEFT", 0, -13)
    f.scroll = UI():CreateScrollFrame(f)
    f.scroll:SetPoint("TOPLEFT", 0, -RAID_TOP)
    f.scroll:SetPoint("BOTTOMRIGHT", 0, 0)
    f.content = CreateFrame("Frame", nil, f.scroll)
    f.content:SetSize(INNER_W, 10)
    f.scroll:SetScrollChild(f.content)
    f.tiles = {}
    -- (a raid without a boss list: the illustrated empty state)
    f.empty = UI():CreateEmptyState(f, { glyph = UI().ICON.notes, title = "No boss list",
        text = "This raid has no boss list (\"Other\" raids have no strategy boards)." })
    f.empty:SetPoint("TOP", f, "TOP", 0, -RAID_TOP - 30)
    f.empty:Hide()
    f.list = {
        box = { ForEachFrame = function(_, fn)
            for _, t in ipairs(f.tiles) do if t:IsShown() then fn(t) end end
        end },
        SetEmptyText = function(_, text) f.empty:SetContent({ glyph = UI().ICON.notes, text = text }) end,
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
        if sum.jobs > 0 then parts[#parts + 1] = Style:Wrap("OK", sum.jobs .. (sum.jobs == 1 and " job" or " jobs") .. " for you") end
        if sum.toPick > 0 and S():CanAssign(v.id) then
            parts[#parts + 1] = Style:Wrap("TEXT", sum.toPick) .. (sum.toPick == 1 and " boss" or " bosses") .. " to pick"
        end
        if sum.none > 0 then parts[#parts + 1] = Style:Wrap("TEXT", sum.none) .. " without a strategy" end
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

if DisasterZoneBoot and DisasterZoneBoot.Run("UI/StrategiesView.lua", ...) then return end -- DisasterZone: UI/StrategiesView.lua
-- Where the strategy boards live in the Raids tab (Addendum K):
--   Strategies view   - the library, for every guild member to explore and build in. A filter bar (free search, a
--                       guild member) over the raids and their bosses on the left (All raids / a raid / one boss) and
--                       the matching strategies on the right: Open for everyone, Edit for the owner, the
--                       collaborators, the GM and the guild council, Share (the collaborators) for the owner, Copy
--                       for everyone (the copy is yours), Delete for the owner, the GM and the guild council. My
--                       unsaved drafts sit on top (continue / discard; saving one makes it a strategy).
--   Assignments tab   - of a planned raid (Upcoming): its bosses, the strategy each uses and how many slots are
--                       filled, with Open (everyone) and Assign. Who leads the raid (its own leader; a raid without
--                       one: the raid leaders) and the GM pick each boss' strategy in the row's dropdown, saved at
--                       once; a boss not picked yet uses the one the guild used last.
local addonName, ns = ...

local View = ns:NewModule("StrategiesUI")

local tsort = table.sort
local min, max, ceil = math.min, math.max, math.ceil

local LIST_W = 290
local BOSS_ROW_H = 22
local STRAT_ROW_H = 40
local RAID_ROW_H = 46
local PICK_MIN, PICK_MAX = 110, 230  -- a raid's strategy dropdown: as wide as the name (32 characters fit)
local TEXT_END = 160                 -- a raid's boss row: its texts end where Open / Assign start
local FILTER_H = 28
local ROW_BTN = 24

local function S() return ns.Strategy end
local function UI() return ns.UI end
local function Board() return ns.StrategyBoard end
local function grey(t) return "|cff808080" .. tostring(t) .. "|r" end
local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

-- The library's filter: raid (an ItemDB raid key) or boss (a boss ref) picked on the left (neither: all raids),
-- text = the free search, by = nil (anyone) | "@me" | "@co" (shared with me) | a member's key.
local state = { raid = nil, boss = nil, text = "", by = nil }
local lib, assign, shareWin

local function addHighlight(row)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.5)
end

local function raidOf(ref)
    return type(ref) == "string" and ref:match("^(%w+):") or nil
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
-- Library (Strategies view)
---------------------------------------------------------------------------

local function initBossRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        addHighlight(row)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, 0.82, 0, 0.12)
        row.fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.fs:SetPoint("LEFT", 6, 0)
        row.fs:SetJustifyH("LEFT")
        row.n = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.n:SetPoint("RIGHT", -8, 0)
        row:SetScript("OnClick", function(self)
            local data = self.__cdlData
            if not data then return end
            if data.ref then View:SelectBoss(data.ref)
            elseif data.raid then View:SelectRaid(data.raid)
            else View:SelectRaid(nil) end
        end)
    end
    local drafts = d.drafts or 0
    local counts = (drafts > 0 and ("|cffff9933" .. drafts .. (drafts == 1 and " draft" or " drafts") .. "|r"
        .. (d.count > 0 and "  " or "")) or "") .. (d.count > 0 and tostring(d.count) or "")
    row.n:SetText(counts)
    if d.ref then
        row.fs:SetFontObject((d.count > 0 or drafts > 0) and "GameFontHighlight" or "GameFontDisable")
        row.fs:SetText("   " .. d.name)
        row.sel:SetShown(d.ref == state.boss)
    else
        -- "All raids" or a raid: picks everything under it
        row.fs:SetFontObject("GameFontNormal")
        row.fs:SetText(d.name)
        row.sel:SetShown(state.boss == nil and state.raid == d.raid)
    end
end

-- A row's action as an icon (UI.ICON_ATLAS); what it does is in its tooltip (b.tipTitle, b.tipText).
local function iconButton(row, icon, title, text, onClick)
    local b = UI():CreateIconButton(row, ROW_BTN, UI().ICON_ATLAS, UI():IconCoords(icon), onClick)
    b.tipTitle, b.tipText = title, text
    b:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(self.tipTitle)
        if self.tipText then GameTooltip:AddLine(self.tipText, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

-- "  ·  A, B editing": the members changing a strategy right now (Core/StrategyCollab.lua).
local function editingText(id)
    local Collab = ns.StrategyCollab
    local names = {}
    for _, key in ipairs(Collab and Collab:GetEditors(id) or {}) do names[#names + 1] = shortName(key) end
    if #names == 0 then return "" end
    return "  ·  |cff33ff99" .. table.concat(names, ", ") .. " editing|r"
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

local function initStratRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        addHighlight(row)
        row.l1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.l1:SetPoint("TOPLEFT", 8, -4)
        row.l1:SetJustifyH("LEFT")
        row.l1:SetWordWrap(false)
        row.l2 = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.l2:SetPoint("TOPLEFT", 8, -21)
        row.l2:SetJustifyH("LEFT")
        row.l2:SetWordWrap(false)
        -- a draft: an orange strip on the left
        row.strip = row:CreateTexture(nil, "ARTWORK")
        row.strip:SetPoint("TOPLEFT", 0, -3)
        row.strip:SetPoint("BOTTOMLEFT", 0, 3)
        row.strip:SetWidth(3)
        row.strip:SetColorTexture(1, 0.6, 0.2, 1)
        row.del = iconButton(row, 12, "Delete", "Removes the strategy for everyone.", function(self)
            local s = self:GetParent().__cdlData
            local draft = s and s.draft
            if draft then
                ns.RaidPlanUI:Confirm(("Discard the draft \"%s\"? Its unsaved work is lost."):format(draft.n), function()
                    Board():DiscardDraft(draft.did)
                end)
                return
            end
            s = s and s.s
            if not s then return end
            local owner = S():GetOwner(s.id)
            local whose = (owner and not ns.Util.IsMe(owner)) and (" by " .. shortName(owner)) or ""
            ns.RaidPlanUI:Confirm(("Delete the strategy \"%s\"%s for everyone?"):format(s.n, whose), function()
                local ok, err = S():DeleteStrategy(s.id)
                if not ok then ns:Print("Could not delete it: %s", tostring(err)) end
            end)
        end)
        row.share = iconButton(row, 18, "Share", "Pick the guild members who build it with you.", function(self)
            local s = self:GetParent().__cdlData
            if s and s.s then View:OpenShare(s.s.id) end
        end)
        row.copy = iconButton(row, 17, "Copy", "Makes a copy that is yours.", function(self)
            local s = self:GetParent().__cdlData
            s = s and s.s
            if not s then return end
            Board():Prompt("Name of your copy", (s.n .. " (copy)"):sub(1, S().MAX_NAME_LEN), function(text)
                text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_NAME_LEN)
                if text == "" then return end
                local ok, id = S():CopyStrategy(s.id, text)
                if ok then Board():OpenStrategy(id, "edit") else ns:Print("Could not copy it: %s", tostring(id)) end
            end)
        end)
        row.edit = iconButton(row, 16, "Edit", "Opens the strategy to change it.", function(self)
            local s = self:GetParent().__cdlData
            if s and s.draft then Board():OpenDraft(s.draft.did)
            elseif s and s.s then Board():OpenStrategy(s.s.id, "edit") end
        end)
        row.open = iconButton(row, 15, "Open", "Opens the strategy to look at it.", function(self)
            local s = self:GetParent().__cdlData
            if s and s.s then Board():OpenStrategy(s.s.id) end
        end)
        row:SetScript("OnClick", function(self)
            local s = self.__cdlData
            if s and s.draft then Board():OpenDraft(s.draft.did)
            elseif s and s.s then Board():OpenStrategy(s.s.id) end
        end)
    end
    local draft = d.draft
    local s = d.s
    row.strip:SetShown(draft ~= nil)
    row.edit.tipTitle = draft and "Continue" or "Edit"
    row.edit.tipText = draft and "Opens the draft where you left it." or "Opens the strategy to change it."
    row.del.tipTitle = draft and "Discard" or "Delete"
    row.del.tipText = draft and "Throws the draft's unsaved work away." or "Removes the strategy for everyone."
    -- the boss, unless the list is one boss'
    local where = state.boss == nil and ("  " .. grey(S():GetBossName((draft or s).b))) or ""
    local show
    if draft then
        -- my unsaved work: only I see it, saving it makes it a strategy (or updates the one it changes)
        row.l1:SetText(draft.n .. "  |cffff9933Draft|r" .. where)
        row.l2:SetText(("%s · last edited %s%s"):format(draft.id and "unsaved changes" or "not saved yet",
            date("%d %b %H:%M", draft.at), pagesText(draft.pages)))
        show = { del = true, edit = true }
    else
        local owner = s.ow or s.by
        local me = ns.Util.PlayerKey()
        local co = #(s.co or {})
        local mine = S():CanEditStrategy(s.id)
        row.l1:SetText(s.n .. where)
        -- who, when, how big: what tells strategies apart at a glance (blocks and the full date are in the board)
        row.l2:SetText(("by %s%s · %s%s%s"):format(owner == me and "you" or shortName(owner),
            co > 0 and (" +" .. co) or "", shortDate(s.rev), pagesText(#s.p),
            S():IsCollaborator(s.id) and " · |cff33ff99shared with you|r" or "") .. editingText(s.id))
        show = { del = S():CanDeleteStrategy(s.id), share = owner == me, copy = S():CanBuild(), edit = mine, open = true }
    end
    -- the buttons this member has, right to left; the texts end where they start
    local prev, used = nil, 6
    for _, k in ipairs({ "del", "share", "copy", "edit", "open" }) do
        local b = row[k]
        b:SetShown(show[k] and true or false)
        if show[k] then
            b:ClearAllPoints()
            if prev then b:SetPoint("RIGHT", prev, "LEFT", -2, 0) else b:SetPoint("RIGHT", -6, 0) end
            used = used + b:GetWidth() + 2
            prev = b
        end
    end
    row.l1:SetPoint("RIGHT", -(used + 6), 0)
    row.l2:SetPoint("RIGHT", -(used + 6), 0)
end

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

function View:CreateLibrary(parent)
    local f = CreateFrame("Frame", nil, parent)
    lib = f
    f.search = UI():CreateSearchBox(f, LIST_W - 30, function(text)
        text = ns.Util.Trim(text or "")
        if text == state.text then return end
        state.text = text
        View:RefreshLibrary()
    end, "Search strategies...")
    f.search:SetPoint("TOPLEFT", 8, -2)
    f.byLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.byLabel:SetPoint("TOPLEFT", LIST_W + 12, -7)
    f.byLabel:SetText("By")
    f.by = UI():CreateDropdown(f, 190, byOptions, function() return state.by end, function(value)
        state.by = value
        View:RefreshLibrary()
    end)
    f.by:SetPoint("LEFT", f.byLabel, "RIGHT", 6, 0)
    f.clear = UI():CreateButton(f, "Clear filters", 96, 22, function() View:SetFilter({}) end)
    f.clear:SetPoint("LEFT", f.by, "RIGHT", 8, 0)
    f.found = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.found:SetPoint("LEFT", f.clear, "RIGHT", 10, 0)

    f.list = UI():CreateScrollList(f, BOSS_ROW_H, initBossRow)
    f.list.frame:SetPoint("TOPLEFT", 0, -FILTER_H)
    f.list.frame:SetPoint("BOTTOMLEFT", 0, 0)
    f.list.frame:SetWidth(LIST_W)

    local d = CreateFrame("Frame", nil, f)
    d:SetPoint("TOPLEFT", LIST_W + 10, -FILTER_H)
    d:SetPoint("BOTTOMRIGHT", 0, 0)
    f.detail = d
    d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d.title:SetPoint("TOPLEFT", 2, -2)
    d.title:SetJustifyH("LEFT")
    d.sub = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    d.sub:SetPoint("TOPLEFT", 2, -24)
    d.sub:SetPoint("RIGHT", -210, 0)
    d.sub:SetJustifyH("LEFT")
    d.sub:SetWordWrap(false)
    d.newBtn = UI():CreateSleekButton(d, "New strategy", 110, 22, function(self) newStrategy(self) end, "primary")
    d.newBtn:SetPoint("TOPRIGHT", -2, -2)
    -- what this view is: in its help icon, not on the screen
    d.help = UI():CreateTipIconButton(d, 22, 11, "Strategies",
        "Everyone builds strategies here: a map with zones, arrows and icons, plus tables of jobs. You change your own "
        .. "and the ones shared with you; Copy makes any strategy yours. For a raid, the raid leader fills in the "
        .. "names (Raids > Upcoming > Assignments).")
    d.help:SetPoint("LEFT", d.title, "RIGHT", 6, 0)
    -- the guided tour of the strategy board (Data/Tours/Strategy.lua)
    d.tourBtn = UI():CreateSleekButton(d, "Tutorial", 70, 22, function(self) ns.Tour:Menu(self, "strategy") end)
    d.tourBtn:SetPoint("RIGHT", d.newBtn, "LEFT", -6, 0)
    d.tourBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Tutorial")
        GameTooltip:AddLine("A guided tour on a practice board: building a strategy, assigning a raid, reading a plan. "
            .. "Nothing you do there is saved or shared.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    d.tourBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    d.list = UI():CreateScrollList(d, STRAT_ROW_H, initStratRow)
    d.list.frame:SetPoint("TOPLEFT", 0, -46)
    d.list.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    -- who is editing what right now: ask once the list is looked at
    f:HookScript("OnShow", function()
        if ns.StrategyCollab then ns.StrategyCollab:Query() end
    end)
    return f
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

    -- the tree: how many strategies (and drafts of mine) pass the search / member filter under each row
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
    local rows = { { name = "All raids", count = total, drafts = totalDrafts } }
    for _, raid in ipairs(tree) do
        local head = { raid = raid.key, name = raid.name, count = 0, drafts = 0 }
        rows[#rows + 1] = head
        for _, b in ipairs(raid.bosses) do
            rows[#rows + 1] = { ref = b.ref, name = b.name, count = counts[b.ref] or 0, drafts = drafts[b.ref] or 0 }
            head.count = head.count + (counts[b.ref] or 0)
            head.drafts = head.drafts + (drafts[b.ref] or 0)
        end
    end
    lib.list:SetData(rows)

    -- the filter bar
    if lib.by.Refresh then lib.by:Refresh() end
    lib.clear:SetShown(filtered())
    lib.found:SetShown(filtered())
    lib.found:SetText(total .. (total == 1 and " strategy" or " strategies") .. " found")

    -- the strategies
    local d = lib.detail
    d.newBtn:SetShown(S():CanBuild())
    d.tourBtn:SetShown(S():CanBuild())
    -- never looked at the tutorial: offer it (once per session, until it is started or turned down)
    if S():CanBuild() then ns.Tour:Offer("strategy", function() return d.tourBtn end) end
    local list = {}
    for _, dr in ipairs(myDrafts) do
        if draftShown(dr, true) then list[#list + 1] = { draft = dr } end
    end
    for _, s in ipairs(S():Find(findFilter(true))) do list[#list + 1] = { s = s } end
    local count = #list == 1 and "1 strategy" or (#list .. " strategies")
    if state.boss then
        d.title:SetText(S():GetBossName(state.boss))
        d.sub:SetText(grey(S():GetRaidName(state.boss) .. "  ·  " .. count))
    else
        d.title:SetText(state.raid and S():GetRaidName(state.raid .. ":x") or "All raids")
        d.sub:SetText(grey(count))
    end
    if filtered() then
        d.list:SetEmptyText("No strategy matches the filters.")
    elseif state.boss then
        d.list:SetEmptyText("No strategy for this boss yet.\nClick New strategy to build one.")
    else
        d.list:SetEmptyText("No strategies yet.\nClick New strategy to build the first one.")
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

-- The library's rows as shown (for tests): the tree rows and the strategy rows.
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

local function initShareRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        row.fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.fs:SetPoint("LEFT", 6, 0)
        row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.note:SetPoint("LEFT", 150, 0)
        row.remove = UI():CreateRemoveButton(row, "No longer a collaborator")
        row.remove:SetPoint("RIGHT", -4, 0)
        row.remove:SetScript("OnClick", function(self)
            local data = self:GetParent().__cdlData
            if data then View:ToggleCollaborator(data.key) end
        end)
    end
    local g = ns.Guild
    row.fs:SetText(UI():ColoredName(d.key))
    row.note:SetText(g and g.GetRankName and g:GetRankName(d.key) or "")
end

local function createShare()
    local w = UI():CreateWindow("DisasterZoneStrategyShare", "Collaborators", 380, 380)
    shareWin = w
    local c = w.content
    w.info = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.info:SetPoint("TOPLEFT", 10, -8)
    w.info:SetPoint("RIGHT", -10, 0)
    w.info:SetJustifyH("LEFT")
    w.picker = UI():CreateSearchDropdown(c, 240, {
        placeholder = "Invite guild members...",
        emptyText = "No matching guild members.",
        getItems = shareItems,
        isChecked = function(key) return shareSet()[key] and true or false end,
        onToggle = function(key) View:ToggleCollaborator(key) end,
    })
    w.picker.frame:SetPoint("TOPLEFT", 6, -64)
    w.status = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    w.status:SetPoint("TOPLEFT", 10, -92)
    w.list = UI():CreateScrollList(c, 22, initShareRow)
    w.list.frame:SetPoint("TOPLEFT", 4, -108)
    w.list.frame:SetPoint("BOTTOMRIGHT", -4, 8)
    w.list:SetEmptyText("Nobody yet: only you, the GM and the guild council can change it.\nInvite guild members with the search box.")
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
    shareWin.info:SetText(("|cffffd100%s|r  %s\nThe guild members you invite here can change this strategy with you. "
        .. "Only you invite and remove; you, the GM and the guild council delete."):format(s.n, grey(S():GetBossName(s.b))))
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
end

local function initRaidBossRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        addHighlight(row)
        row.assign = UI():CreateButton(row, "Assign", 70, 20, function(self)
            local data = self:GetParent().__cdlData
            if data then Board():OpenRaid(data.occ, data.ref, "fill") end
        end)
        row.assign:SetPoint("RIGHT", -6, 0)
        row.open = UI():CreateButton(row, "Open", 70, 20, function(self)
            local data = self:GetParent().__cdlData
            if data then Board():OpenRaid(data.occ, data.ref) end
        end)
        -- line 1: the boss, and on the right how many of its slots are filled (my jobs in green); line 2: the
        -- strategy (a dropdown as wide as its name for who arranges the raid, the name for everyone else) and, for
        -- the arrangers, whether it still has to be picked
        row.l1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.l1:SetPoint("TOPLEFT", 8, -5)
        row.l1:SetJustifyH("LEFT")
        row.l1:SetWordWrap(false)
        row.stat = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.stat:SetPoint("LEFT", row.l1, "RIGHT", 8, 0)
        row.stat:SetPoint("RIGHT", row, "TOPRIGHT", -TEXT_END, -11)
        row.stat:SetJustifyH("RIGHT")
        row.stat:SetWordWrap(false)
        row.pick = UI():CreateSleekMenuButton(row, "", PICK_MIN, function(root) pickMenu(row, root) end, 20)
        row.pick:SetPoint("TOPLEFT", 6, -22)
        row.pick:HookScript("OnEnter", function(self)
            local data = row.__cdlData
            if not (data and data.s) then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("Strategy for " .. data.name)
            if data.how == "picked" then
                GameTooltip:AddLine("Picked for this raid. Pick another to switch: names in the slots both "
                    .. "strategies have stay.", 1, 1, 1, true)
            elseif data.how == "last" then
                GameTooltip:AddLine("Not picked yet: this raid uses the strategy the guild used last time. Pick one "
                    .. "to keep it.", 1, 1, 1, true)
            elseif data.how == "first" then
                GameTooltip:AddLine("Not picked yet: this raid uses the first one by name. Pick one to keep it.",
                    1, 1, 1, true)
            else
                GameTooltip:AddLine("The only strategy for this boss.", 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
        row.pick:HookScript("OnLeave", function() GameTooltip:Hide() end)
        row.l2 = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.l2:SetJustifyH("LEFT")
        row.l2:SetWordWrap(false)
        row:SetScript("OnClick", function(self)
            local data = self.__cdlData
            if data then Board():OpenRaid(data.occ, data.ref) end
        end)
    end
    local s, fill = d.s, d.fill
    local arranger = S():CanAssign(d.occ)
    row.l1:SetText(d.name)
    local stat = ""
    if s then
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
        stat = ("%d/%d filled"):format(n, #slots)
        if mine > 0 then stat = stat .. " · |cff33ff99" .. mine .. (mine == 1 and " job" or " jobs") .. " for you|r" end
    end
    row.stat:SetText(stat)
    row.pick:SetShown(arranger and s ~= nil)
    row.l2:ClearAllPoints()
    if arranger and s then
        -- as wide as the name: its label measured on one anchor (unbounded), then put back between the edges
        row.pick:SetText(s.n)
        local fs = row.pick:GetFontString()
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", 8, 0)
        row.pick:SetWidth(min(PICK_MAX, max(PICK_MIN, ceil(fs:GetStringWidth() or 0) + 32)))
        fs:SetPoint("RIGHT", -20, 0)
        row.l2:SetPoint("LEFT", row.pick, "RIGHT", 8, 0)
        -- names typed on the board but not saved, else a boss with several strategies where none was picked
        row.l2:SetText((Board():FillDraft(d.occ, d.ref) and "|cffff9933unsaved names|r")
            or ((d.count > 1 and d.how ~= "picked") and "|cffff9933not picked yet|r") or "")
    else
        row.l2:SetPoint("TOPLEFT", 8, -27)
        row.l2:SetText(s and ("|cffffffff" .. s.n .. "|r") or "No strategy for this boss yet")
    end
    row.l2:SetPoint("RIGHT", row, "TOPRIGHT", -TEXT_END, -32)
    row.assign:SetShown(arranger and s ~= nil)
    row.open:ClearAllPoints()
    if arranger and s then row.open:SetPoint("RIGHT", row.assign, "LEFT", -4, 0) else row.open:SetPoint("RIGHT", -6, 0) end
    row.open:SetShown(s ~= nil or S():CanBuild())
end

-- The raid picks a strategy for a boss (the row's dropdown).
function View:PickStrategy(occId, bossRef, stratId)
    local ok, err = S():PickStrategy(occId, bossRef, stratId)
    if not ok then
        ns:Print("Could not pick the strategy: %s", tostring(err))
        return false
    end
    if ns.RaidPlanUI and ns.RaidPlanUI.RefreshUpcoming then ns.RaidPlanUI:RefreshUpcoming() end
    return true
end

-- The frame shown in a planned raid's detail (RaidPlanUI adds it as the Assignments tab).
function View:CreateRaidAssignments(parent)
    local f = CreateFrame("Frame", nil, parent)
    assign = f
    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hint:SetPoint("TOPLEFT", 2, -2)
    f.hint:SetPoint("RIGHT", -2, 0)
    f.hint:SetJustifyH("LEFT")
    f.list = UI():CreateScrollList(f, RAID_ROW_H, initRaidBossRow)
    f.list.frame:SetPoint("TOPLEFT", 0, -20)
    f.list.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    return f
end

function View:RefreshRaid(v)
    if not assign then return end
    if not v then
        assign.list:SetData({})
        return
    end
    local bosses = S():GetBosses(v.i)
    local counts = S():CountByBoss()
    local rows = {}
    for _, b in ipairs(bosses) do
        local s, fill, how = S():GetRaidStrategy(v.id, b.ref)
        rows[#rows + 1] = { occ = v.id, ref = b.ref, name = b.name, s = s, fill = fill, how = how,
                            count = counts[b.ref] or 0 }
    end
    local hint = "Who does what on each boss. Open a boss to see its board."
    if S():CanAssign(v.id) then hint = "Pick the strategy for each boss here; Assign puts names in its slots." end
    assign.hint:SetText(#rows > 0 and hint or "")
    assign.list:SetEmptyText("This raid has no boss list (\"Other\" raids have no strategy boards).")
    assign.list:SetData(rows)
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

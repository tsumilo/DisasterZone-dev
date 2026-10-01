if DisasterZoneBoot and DisasterZoneBoot.Run("UI/StrategiesView.lua", ...) then return end -- DisasterZone: UI/StrategiesView.lua
-- Where the strategy boards live in the Raids tab (Addendum K):
--   Strategies view   - the library: raids and their bosses on the left, the selected boss' strategies on the right
--                       (open / edit / copy / delete; New strategy for the GM, guild council and raid leaders), with
--                       my unsaved drafts on top (continue / discard; saving one makes it a strategy).
--   Assignments tab   - of a planned raid (Upcoming): its bosses, the strategy each uses and how many slots are
--                       filled, with Open (everyone) and Assign (authors).
local addonName, ns = ...

local View = ns:NewModule("StrategiesUI")

local LIST_W = 290
local BOSS_ROW_H = 22
local STRAT_ROW_H = 40
local RAID_ROW_H = 38

local function S() return ns.Strategy end
local function UI() return ns.UI end
local function Board() return ns.StrategyBoard end
local function grey(t) return "|cff808080" .. tostring(t) .. "|r" end
local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

local state = { boss = nil }
local lib, assign

local function addHighlight(row)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.5)
end

local function countBlocks(s)
    local n = 0
    for _, p in ipairs(s.p or {}) do n = n + #(p.k or {}) end
    return n
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
            if data and data.ref then
                state.boss = data.ref
                View:RefreshLibrary()
            end
        end)
    end
    if d.header then
        row.fs:SetFontObject("GameFontNormal")
        row.fs:SetText(d.name)
        row.n:SetText("")
        row.sel:Hide()
        row:EnableMouse(false)
    else
        row:EnableMouse(true)
        local drafts = d.drafts or 0
        row.fs:SetFontObject((d.count > 0 or drafts > 0) and "GameFontHighlight" or "GameFontDisable")
        row.fs:SetText("   " .. d.name)
        row.n:SetText((drafts > 0 and ("|cffff9933" .. drafts .. (drafts == 1 and " draft" or " drafts") .. "|r"
            .. (d.count > 0 and "  " or "")) or "") .. (d.count > 0 and tostring(d.count) or ""))
        row.sel:SetShown(d.ref == state.boss)
    end
end

local function initStratRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        addHighlight(row)
        row.l1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.l1:SetPoint("TOPLEFT", 8, -4)
        row.l1:SetPoint("RIGHT", -250, 0)
        row.l1:SetJustifyH("LEFT")
        row.l1:SetWordWrap(false)
        row.l2 = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.l2:SetPoint("TOPLEFT", 8, -21)
        row.l2:SetPoint("RIGHT", -250, 0)
        row.l2:SetJustifyH("LEFT")
        row.l2:SetWordWrap(false)
        -- a draft: an orange strip on the left
        row.strip = row:CreateTexture(nil, "ARTWORK")
        row.strip:SetPoint("TOPLEFT", 0, -3)
        row.strip:SetPoint("BOTTOMLEFT", 0, 3)
        row.strip:SetWidth(3)
        row.strip:SetColorTexture(1, 0.6, 0.2, 1)
        row.del = UI():CreateButton(row, "Delete", 60, 20, function(self)
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
            ns.RaidPlanUI:Confirm(("Delete the strategy \"%s\" for everyone?"):format(s.n), function()
                local ok, err = S():DeleteStrategy(s.id)
                if not ok then ns:Print("Could not delete it: %s", tostring(err)) end
            end)
        end)
        row.del:SetPoint("RIGHT", -6, 0)
        row.copy = UI():CreateButton(row, "Copy", 56, 20, function(self)
            local s = self:GetParent().__cdlData
            s = s and s.s
            if not s then return end
            Board():Prompt("Name of the copy", (s.n .. " (copy)"):sub(1, S().MAX_NAME_LEN), function(text)
                text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_NAME_LEN)
                if text == "" then return end
                local ok, id = S():CopyStrategy(s.id, text)
                if ok then Board():OpenStrategy(id, "edit") else ns:Print("Could not copy it: %s", tostring(id)) end
            end)
        end)
        row.copy:SetPoint("RIGHT", row.del, "LEFT", -4, 0)
        row.edit = UI():CreateButton(row, "Edit", 56, 20, function(self)
            local s = self:GetParent().__cdlData
            if s and s.draft then Board():OpenDraft(s.draft.did)
            elseif s and s.s then Board():OpenStrategy(s.s.id, "edit") end
        end)
        row.edit:SetPoint("RIGHT", row.copy, "LEFT", -4, 0)
        row.open = UI():CreateButton(row, "Open", 56, 20, function(self)
            local s = self:GetParent().__cdlData
            if s and s.s then Board():OpenStrategy(s.s.id) end
        end)
        row.open:SetPoint("RIGHT", row.edit, "LEFT", -4, 0)
        row:SetScript("OnClick", function(self)
            local s = self.__cdlData
            if s and s.draft then Board():OpenDraft(s.draft.did)
            elseif s and s.s then Board():OpenStrategy(s.s.id) end
        end)
    end
    local draft = d.draft
    row.strip:SetShown(draft ~= nil)
    row.edit:SetText(draft and "Continue" or "Edit")
    row.edit:SetWidth(draft and 76 or 56)
    row.del:SetText(draft and "Discard" or "Delete")
    if draft then
        -- my unsaved work: only I see it, saving it makes it a strategy (or updates the one it changes)
        row.l1:SetText(draft.n .. "  |cffff9933Draft|r")
        row.l2:SetText(("%s · %d page%s · %d block%s · last edited %s"):format(
            draft.id and "unsaved changes" or "not saved yet", draft.pages, draft.pages == 1 and "" or "s",
            draft.blocks, draft.blocks == 1 and "" or "s", date("%d %b %H:%M", draft.at)))
        row.edit:Show()
        row.del:Show()
        row.copy:Hide()
        row.open:Hide()
        row.edit:ClearAllPoints()
        row.edit:SetPoint("RIGHT", row.del, "LEFT", -4, 0)
        return
    end
    row.edit:ClearAllPoints()
    row.edit:SetPoint("RIGHT", row.copy, "LEFT", -4, 0)
    row.open:Show()
    local s = d.s
    row.l1:SetText(s.n)
    row.l2:SetText(("%d page%s · %d block%s · by %s, %s"):format(#s.p, #s.p == 1 and "" or "s", countBlocks(s),
        countBlocks(s) == 1 and "" or "s", shortName(s.by), date("%d %b %Y", s.rev)))
    local editor = S():CanEdit()
    row.edit:SetShown(editor)
    row.copy:SetShown(editor)
    row.del:SetShown(editor)
    row.open:ClearAllPoints()
    if editor then row.open:SetPoint("RIGHT", row.edit, "LEFT", -4, 0) else row.open:SetPoint("RIGHT", -6, 0) end
end

function View:CreateLibrary(parent)
    local f = CreateFrame("Frame", nil, parent)
    lib = f
    f.list = UI():CreateScrollList(f, BOSS_ROW_H, initBossRow)
    f.list.frame:SetPoint("TOPLEFT", 0, 0)
    f.list.frame:SetPoint("BOTTOMLEFT", 0, 0)
    f.list.frame:SetWidth(LIST_W)

    local d = CreateFrame("Frame", nil, f)
    d:SetPoint("TOPLEFT", LIST_W + 10, 0)
    d:SetPoint("BOTTOMRIGHT", 0, 0)
    f.detail = d
    d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d.title:SetPoint("TOPLEFT", 2, -2)
    d.title:SetJustifyH("LEFT")
    d.sub = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    d.sub:SetPoint("TOPLEFT", 2, -24)
    d.sub:SetPoint("RIGHT", -130, 0)
    d.sub:SetJustifyH("LEFT")
    d.newBtn = UI():CreateButton(d, "New strategy", 110, 22, function()
        if not state.boss then return end
        Board():Prompt("Name of the new strategy (e.g. 25 farm)", "", function(text)
            text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_NAME_LEN)
            if text ~= "" then Board():NewStrategy(state.boss, text) end
        end)
    end)
    d.newBtn:SetPoint("TOPRIGHT", -2, -2)
    d.list = UI():CreateScrollList(d, STRAT_ROW_H, initStratRow)
    d.list.frame:SetPoint("TOPLEFT", 0, -46)
    d.list.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    return f
end

function View:RefreshLibrary()
    if not lib or not lib:IsVisible() then return end
    local counts = S():CountByBoss()
    local drafts = {}
    for _, dr in ipairs(Board():GetDrafts()) do drafts[dr.b] = (drafts[dr.b] or 0) + 1 end
    local rows = {}
    local first, firstWith
    for _, raid in ipairs(S():GetRaidTree()) do
        rows[#rows + 1] = { header = true, name = raid.name }
        for _, b in ipairs(raid.bosses) do
            rows[#rows + 1] = { ref = b.ref, name = b.name, count = counts[b.ref] or 0, drafts = drafts[b.ref] }
            first = first or b.ref
            if not firstWith and (counts[b.ref] or 0) > 0 then firstWith = b.ref end
        end
    end
    if not state.boss then state.boss = firstWith or first end
    lib.list:SetData(rows)
    local d = lib.detail
    local editor = S():CanEdit()
    d.newBtn:SetShown(editor and state.boss ~= nil)
    if not state.boss then
        d.title:SetText("")
        d.sub:SetText("")
        d.list:SetData({})
        return
    end
    d.title:SetText(S():GetBossName(state.boss))
    d.sub:SetText(S():GetRaidName(state.boss) .. grey("  ·  a strategy is a map with zones, arrows and icons plus "
        .. "blocks of jobs; the raid leader fills in the names per raid"))
    local list = {}
    for _, dr in ipairs(Board():GetDrafts(state.boss)) do list[#list + 1] = { draft = dr } end
    for _, s in ipairs(S():GetStrategies(state.boss)) do list[#list + 1] = { s = s } end
    d.list:SetEmptyText(editor and "No strategy for this boss yet.\nClick New strategy to build one."
        or "No strategy for this boss yet.\nThe Guild Master, the guild council and the raid leaders build them here.")
    d.list:SetData(list)
end

function View:SelectBoss(ref)
    state.boss = ref
    self:RefreshLibrary()
end

---------------------------------------------------------------------------
-- A planned raid's Assignments tab
---------------------------------------------------------------------------

local function initRaidBossRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        addHighlight(row)
        row.l1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.l1:SetPoint("TOPLEFT", 8, -4)
        row.l1:SetPoint("RIGHT", -170, 0)
        row.l1:SetJustifyH("LEFT")
        row.l1:SetWordWrap(false)
        row.l2 = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.l2:SetPoint("TOPLEFT", 8, -20)
        row.l2:SetPoint("RIGHT", -170, 0)
        row.l2:SetJustifyH("LEFT")
        row.l2:SetWordWrap(false)
        row.assign = UI():CreateButton(row, "Assign", 70, 20, function(self)
            local data = self:GetParent().__cdlData
            if data then Board():OpenRaid(data.occ, data.ref, "fill") end
        end)
        row.assign:SetPoint("RIGHT", -6, 0)
        row.open = UI():CreateButton(row, "Open", 70, 20, function(self)
            local data = self:GetParent().__cdlData
            if data then Board():OpenRaid(data.occ, data.ref) end
        end)
        row:SetScript("OnClick", function(self)
            local data = self.__cdlData
            if data then Board():OpenRaid(data.occ, data.ref) end
        end)
    end
    local s, fill = d.s, d.fill
    row.l1:SetText(d.name .. (s and ("  " .. grey(s.n)) or ""))
    local line
    if not s then
        line = grey("No strategy for this boss yet")
    else
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
        line = ("%d / %d slots filled"):format(n, #slots)
        if mine > 0 then line = line .. "  ·  |cff33ff99you have " .. mine .. (mine == 1 and " job" or " jobs") .. "|r" end
        if fill and fill.by then line = line .. grey("  ·  by " .. shortName(fill.by)) end
        if Board():FillDraft(d.occ, d.ref) then line = line .. "  ·  |cffff9933unsaved draft|r" end
    end
    row.l2:SetText(line)
    local editor = S():CanEdit()
    row.assign:SetShown(editor and s ~= nil)
    row.open:ClearAllPoints()
    if editor and s then row.open:SetPoint("RIGHT", row.assign, "LEFT", -4, 0) else row.open:SetPoint("RIGHT", -6, 0) end
    row.open:SetShown(s ~= nil or editor)
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
    local rows = {}
    for _, b in ipairs(bosses) do
        local s, fill = S():GetRaidStrategy(v.id, b.ref)
        rows[#rows + 1] = { occ = v.id, ref = b.ref, name = b.name, s = s, fill = fill }
    end
    assign.hint:SetText(#rows > 0 and "Who does what on each boss. Open a boss to see its board." or "")
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
    ns:On("STRATEGY_CHANGED", function()
        ns.Util.Debounce("strategies-ui", 0.2, function()
            View:RefreshLibrary()
            if assign and assign:IsVisible() and ns.RaidPlanUI and ns.RaidPlanUI.RefreshUpcoming then
                ns.RaidPlanUI:RefreshUpcoming()
            end
        end)
    end)
end

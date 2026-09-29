-- CDLoot: UI/RaidLeadersUI.lua
-- The raid leaders window (Addendum J §62), opened from the Raids tab's Teams view. Everyone sees who is on the list;
-- the Guild Master edits it (search picker, Save & share). Raid leaders plan raids, build teams and groups, invite
-- and see the raid log without items; they get no loot council access.
local addonName, ns = ...

local LeadersUI = ns:NewModule("RaidLeadersUI")

local tsort = table.sort

local win
local draft          -- { [key] = true } while the GM edits; nil = follow the shared list

local function G() return ns.Guild end

local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

local function canEdit()
    local g = G()
    return g and g.CanEditGuildCouncil and g:CanEditGuildCouncil() or false
end

local function shared()
    local set = {}
    for _, key in ipairs(G() and G().GetRaidLeaders and G():GetRaidLeaders() or {}) do set[key] = true end
    return set
end

local function current()
    return draft or shared()
end

local function sameSet(a, b)
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end

local function pickerItems()
    local g = G()
    local out = {}
    for _, key in ipairs(g and g.GetMembers and g:GetMembers() or {}) do
        out[#out + 1] = { key = key, text = shortName(key), classFile = g:GetClass(key), note = g:GetRankName(key),
                          dim = not g:IsOnline(key) }
    end
    tsort(out, function(a, b) return shortName(a.key):lower() < shortName(b.key):lower() end)
    return out
end

local function initRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        row.fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.fs:SetPoint("LEFT", 6, 0)
        row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.note:SetPoint("LEFT", 150, 0)
        row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
        row.remove:SetSize(20, 20)
        row.remove:SetPoint("RIGHT", -4, 0)
        row.remove:SetScript("OnClick", function(self)
            local data = self:GetParent().__cdlData
            if data then LeadersUI:Toggle(data.key) end
        end)
    end
    local g = G()
    row.fs:SetText(ns.UI:ColoredName(d.key))
    local note = g and g.GetRankName and g:GetRankName(d.key) or ""
    if g and g.IsGuildCouncil and g:IsGuildCouncil(d.key) then note = note .. "  |cffffd100(also loot council)|r" end
    row.note:SetText(note)
    row.remove:SetShown(canEdit())
end

local function create()
    local UI = ns.UI
    local w = UI:CreateWindow("CDLootRaidLeaders", "Raid leaders", 380, 400)
    win = w
    local c = w.content
    w.info = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.info:SetPoint("TOPLEFT", 10, -8)
    w.info:SetPoint("RIGHT", -10, 0)
    w.info:SetJustifyH("LEFT")
    w.info:SetText("Raid leaders plan raids, build teams and groups, use Invite & sort and see the raid log "
        .. "(attendance, bench, no-shows; not the items). They get no loot council access: no BiS lists, drop panel, "
        .. "votes or Loot Log. The Guild Master and the guild council can do all of this anyway.")
    w.picker = UI:CreateSearchDropdown(c, 240, {
        placeholder = "Add guild members...",
        emptyText = "No matching guild members.",
        getItems = pickerItems,
        isChecked = function(key) return current()[key] and true or false end,
        onToggle = function(key) LeadersUI:Toggle(key) end,
    })
    w.picker.frame:SetPoint("TOPLEFT", 6, -76)
    w.status = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.status:SetPoint("TOPLEFT", 10, -104)
    w.status:SetPoint("RIGHT", -10, 0)
    w.status:SetJustifyH("LEFT")
    w.list = UI:CreateScrollList(c, 22, initRow)
    w.list.frame:SetPoint("TOPLEFT", 4, -122)
    w.list.frame:SetPoint("BOTTOMRIGHT", -4, 40)
    w.save = UI:CreateButton(c, "Save & share", 110, 22, function() LeadersUI:Save() end)
    w.save:SetPoint("BOTTOMLEFT", 8, 8)
    w.revert = UI:CreateButton(c, "Revert", 70, 22, function()
        draft = nil
        LeadersUI:Refresh()
    end)
    w.revert:SetPoint("LEFT", w.save, "RIGHT", 6, 0)
    w.foot = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    w.foot:SetPoint("BOTTOMLEFT", 10, 12)
    w.foot:SetText("Only the Guild Master can change this list.")
    w:Hide()
    return w
end

function LeadersUI:Open()
    if not win then create() end
    draft = nil
    win:Show()
    win:Raise()
    self:Refresh()
end

function LeadersUI:GetWindow() return win end

function LeadersUI:Toggle(key)
    if not canEdit() or type(key) ~= "string" then return false end
    draft = draft or shared()
    draft[key] = not draft[key] or nil
    self:Refresh()
    return true
end

function LeadersUI:Save()
    if not canEdit() then
        ns:Print("Only the Guild Master can change the raid leaders.")
        return false
    end
    local ok, err = G():SetRaidLeaders(current())
    if not ok then
        ns:Print("The raid leaders were not saved: %s", tostring(err))
        return false
    end
    local n = 0
    for _ in pairs(current()) do n = n + 1 end
    draft = nil
    ns:Print("Raid leaders saved and shared: %d.", n)
    self:Refresh()
    return true
end

function LeadersUI:Refresh()
    if not win or not win:IsShown() then return end
    local edit = canEdit()
    local set = current()
    local keys = {}
    for key in pairs(set) do keys[#keys + 1] = key end
    tsort(keys, function(a, b) return shortName(a):lower() < shortName(b):lower() end)
    local rows = {}
    for _, key in ipairs(keys) do rows[#rows + 1] = { key = key } end
    win.picker.frame:SetShown(edit)
    win.save:SetShown(edit)
    win.revert:SetShown(edit)
    win.foot:SetShown(not edit)
    local dirty = draft ~= nil and not sameSet(draft, shared())
    win.save:SetEnabled(dirty)
    win.revert:SetEnabled(dirty)
    win.status:SetText((dirty and "|cffff9933Unsaved changes|r · " or "") .. #keys .. " raid leader" .. (#keys == 1 and "" or "s"))
    win.list:SetEmptyText(edit and "Nobody yet. Add guild members with the search box." or "No raid leaders picked yet.")
    win.list:SetData(rows)
    if win.picker.IsOpen and win.picker:IsOpen() then win.picker:RefreshRows() end
end

function LeadersUI:OnInit()
    ns:On("CONFIG_UPDATED", function() LeadersUI:Refresh() end)
    ns:On("ROSTER_UPDATED", function() LeadersUI:Refresh() end)
end

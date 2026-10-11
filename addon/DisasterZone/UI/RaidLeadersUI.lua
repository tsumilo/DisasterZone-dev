if DisasterZoneBoot and DisasterZoneBoot.Run("UI/RaidLeadersUI.lua", ...) then return end -- DisasterZone: UI/RaidLeadersUI.lua
-- The raid leaders window (Addendum J §62), opened from the Raids tab's Teams view; 1.4: on the tool layout. Everyone
-- sees who is on the list; the Guild Master edits it (search picker, Save & share). Raid leaders plan raids, build
-- teams and groups, invite and see the raid log without items; they get no loot council access.
local addonName, ns = ...

local LeadersUI = ns:NewModule("RaidLeadersUI")

local S = ns.Style
local tsort = table.sort

local win
local draft          -- { [key] = true } while the GM edits; nil = follow the shared list

local function G() return ns.Guild end

local function short(key) return ns.Util.ShortName(key) or tostring(key) end

local function canEdit()
    local g = G()
    return g and g.CanEditRaidLeaders and g:CanEditRaidLeaders() or false
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
        out[#out + 1] = { key = key, text = short(key), classFile = g:GetClass(key), note = g:GetRankName(key),
                          dim = not g:IsOnline(key) }
    end
    tsort(out, function(a, b) return short(a.key):lower() < short(b.key):lower() end)
    return out
end

local function initRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        local UI = ns.UI
        UI:DecorateRow(row, { rule = true })
        row.fs = UI:Text(row, "body", "TEXT")
        row.fs:SetPoint("LEFT", 6, 0)
        row.note = UI:Text(row, "small", "DIM")
        row.note:SetPoint("LEFT", 150, 0)
        row.remove = UI:CreateRemoveButton(row, "Take off the raid leaders")
        row.remove:SetPoint("RIGHT", -4, 0)
        row.remove:SetScript("OnClick", function(self)
            local data = self:GetParent().__cdlData
            if data then LeadersUI:Toggle(data.key) end
        end)
    end
    local g = G()
    row.fs:SetText(ns.UI:ColoredName(d.key))
    local note = g and g.GetRankName and g:GetRankName(d.key) or ""
    if g and g.IsGuildCouncil and g:IsGuildCouncil(d.key) then note = note .. "  " .. S:Wrap("GOLD", "(also loot council)") end
    if g and g.IsGM and g:IsGM(d.key) then note = note .. "  " .. S:Wrap("GOLD", "(Guild Master)") end
    row.note:SetText(note)
    row.remove:SetShown(canEdit())
end

-- The window's content on the tool layout: a strip banner (who the raid leaders are, how many), the tool row (Revert
-- and Save & share, the main action, for officers and the GM), then the explanation, the picker and the list; a
-- read-only notice for everyone else.
local function create()
    local UI = ns.UI
    local w = UI:CreateWindow("DisasterZoneRaidLeaders", "Raid leaders", 380, 400)
    win = w
    local c = w.content
    local L = UI:CreateLayout("tool", c, { width = 370, toolbar = true, banner = { size = "strip", icon = "crown",
        title = "Who plans and leads raids" } })
    w.layout = L
    local body = L.body
    w.status = L.banner.sub
    -- the tool row: Revert, then Save & share at the far right
    w.revert = UI:CreateSleekButton(L.toolbar, "Revert", 70, S.BTN_H, function()
        draft = nil
        LeadersUI:Refresh()
    end)
    L.toolbar:SetFilters({ w.revert })
    w.save = L.toolbar:SetPrimary({ text = "Save & share", onClick = function() LeadersUI:Save() end,
        tip = "Every officer and raid leader gets the new list." })
    w.info = UI:Text(body, "small", "SUB", { wrap = true })
    w.info:SetPoint("TOPLEFT", 0, 0)
    w.info:SetPoint("RIGHT", 0, 0)
    w.info:SetText("Raid leaders plan raids, build teams and groups, use Invite & sort and see the raid log "
        .. "(attendance, bench, no-shows; not the items). They get no loot council access: no BiS lists, drop panel, "
        .. "votes or Loot Log. With nobody on the list, only the Guild Master plans raids.")
    w.picker = UI:CreateSearchDropdown(body, 240, {
        placeholder = "Add guild members...",
        emptyText = "No matching guild members.",
        getItems = pickerItems,
        isChecked = function(key) return current()[key] and true or false end,
        onToggle = function(key) LeadersUI:Toggle(key) end,
    })
    w.picker.frame:SetPoint("TOPLEFT", -4, -62)
    w.list = UI:CreateScrollList(body, S.ROW.compact, initRow)
    w.list.frame:SetPoint("TOPLEFT", -6, -92)
    w.list.frame:SetPoint("BOTTOMRIGHT", 6, 0)
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
        ns:Print("Only officers and the Guild Master can change the raid leaders.")
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
    tsort(keys, function(a, b) return short(a):lower() < short(b):lower() end)
    local rows = {}
    for _, key in ipairs(keys) do rows[#rows + 1] = { key = key } end
    win.picker.frame:SetShown(edit)
    win.save:SetShown(edit)
    win.revert:SetShown(edit)
    win.layout.toolbar:LayoutRight()
    -- (everyone looks; only officers and the Guild Master change it: a read-only notice says so)
    if edit then
        win.layout:HideNotice()
    else
        win.layout:ShowNotice("readonly", "Only officers and the Guild Master can change this list.")
    end
    local dirty = draft ~= nil and not sameSet(draft, shared())
    win.save:SetEnabled(dirty)
    win.revert:SetEnabled(dirty)
    win.layout.banner:SetSub((dirty and S:Wrap("WARN", "Unsaved changes") .. " · " or "") .. #keys .. " raid leader"
        .. (#keys == 1 and "" or "s"))
    win.list:SetEmptyState({ glyph = ns.UI.ICON.crown, text = edit and "Nobody yet. Add guild members with the search box."
        or "No raid leaders picked yet." })
    win.list:SetData(rows)
    if win.picker.IsOpen and win.picker:IsOpen() then win.picker:RefreshRows() end
end

function LeadersUI:OnInit()
    ns:On("CONFIG_UPDATED", function() LeadersUI:Refresh() end)
    ns:On("ROSTER_UPDATED", function() LeadersUI:Refresh() end)
end

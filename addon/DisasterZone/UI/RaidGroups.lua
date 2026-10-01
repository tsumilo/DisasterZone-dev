if DisasterZoneBoot and DisasterZoneBoot.Run("UI/RaidGroups.lua", ...) then return end -- DisasterZone: UI/RaidGroups.lua
-- The group grid (Addendum J §59-§60): a raid-wide buff strip, group boxes (2 for 10-man, 5 for 25-man) with the party
-- buffs each group has, and a "Not in a group" pool. Members are chips (class icon, spec icon, name). Organizers move
-- them by dragging, or by clicking a chip and then a group (or another chip, to swap; or an empty slot, to take it);
-- right-click opens the caller's menu. Each player keeps a seat (1-5) in their group, so the order is the organizer's. Used by the Teams view (a team's layout) and, in step 4, by the raid group builder.
local addonName, ns = ...

local GroupsUI = ns:NewModule("RaidGroupsUI")

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tsort, tconcat = table.sort, table.concat

local BOX_W, CHIP_H, GAP = 154, 16, 6
local COLS = 3
local HEADER_H, BUFF_H = 16, 18
local SLOTS = 5
local BOX_H = HEADER_H + SLOTS * CHIP_H + BUFF_H + 6
local STRIP_H = 22
local POOL_COLS = 3

local ghost          -- the frame following the cursor while dragging

local function Comp() return ns.RaidComp end
local function UI() return ns.UI end

local function iconText(path, size)
    return path and ("|T" .. path .. ":" .. (size or 12) .. "|t") or ""
end

local function hideTooltip() GameTooltip:Hide() end

---------------------------------------------------------------------------
-- Chips
---------------------------------------------------------------------------

local function chipTooltip(chip)
    local m = chip.member
    if not m then return end
    GameTooltip:SetOwner(chip, "ANCHOR_RIGHT")
    GameTooltip:AddLine(UI():ColoredName(m.key, m.c))
    local label = Comp():SpecLabel(m.c, m.sp)
    local cls = m.c and ns.CLASS_NAMES[m.c] or ""
    if label then
        GameTooltip:AddLine(label .. " " .. cls, 1, 1, 1)
        if m.auto then GameTooltip:AddLine(m.source == "bis" and "Spec from their BiS list" or "Spec from their last sign-up",
            0.6, 0.6, 0.6) end
    else
        GameTooltip:AddLine(cls .. " · spec unknown", 1, 1, 1)
    end
    local brings = {}
    for _, b in ipairs(Comp().BUFFS) do
        if Comp():Provides(b.key, m.c, m.sp) then brings[#brings + 1] = iconText(Comp():BuffIcon(b)) .. " " .. b.name end
    end
    if #brings > 0 then
        GameTooltip:AddLine(" ")
        for _, line in ipairs(brings) do GameTooltip:AddLine(line, 0.85, 0.85, 0.85) end
    end
    if m.extra then GameTooltip:AddLine(m.extra, 1, 0.82, 0, true) end
    for _, line in ipairs(m.info or {}) do GameTooltip:AddLine(line, 0.75, 0.75, 0.75, true) end
    local grid = chip.grid
    if grid and grid.opts.isEditable() then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Drag to a group, onto a player to swap places or onto an empty slot to take it (or click it, "
            .. "then the spot). Right-click for more.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

-- An empty seat in a group: a place to drop (or click, with a player picked).
local function emptyTooltip(chip)
    local grid, g = chip.grid, chip:GetParent().group
    if not (grid.picked and g) then return end
    GameTooltip:SetOwner(chip, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Click to move " .. ns.Util.ShortName(grid.picked) .. " to group " .. g .. ", slot " .. chip.slot)
    GameTooltip:Show()
end

local function createChip(parent, grid)
    local chip = CreateFrame("Button", nil, parent)
    chip:SetSize(BOX_W - 8, CHIP_H)
    chip.grid = grid
    chip.cls = chip:CreateTexture(nil, "ARTWORK")
    chip.cls:SetSize(14, 14)
    chip.cls:SetPoint("LEFT", 1, 0)
    chip.spec = chip:CreateTexture(nil, "ARTWORK")
    chip.spec:SetSize(14, 14)
    chip.spec:SetPoint("LEFT", chip.cls, "RIGHT", 2, 0)
    chip.fs = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    chip.fs:SetPoint("LEFT", chip.spec, "RIGHT", 4, 0)
    chip.fs:SetPoint("RIGHT", -2, 0)
    chip.fs:SetJustifyH("LEFT")
    chip.fs:SetWordWrap(false)
    local hl = chip:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)
    chip.picked = chip:CreateTexture(nil, "BACKGROUND")
    chip.picked:SetAllPoints()
    chip.picked:SetColorTexture(1, 0.82, 0, 0.35)
    chip.picked:Hide()
    chip:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    chip:RegisterForDrag("LeftButton")
    chip:SetScript("OnEnter", function(self)
        if self.key then chipTooltip(self) else emptyTooltip(self) end
    end)
    chip:SetScript("OnLeave", hideTooltip)
    chip:SetScript("OnClick", function(self, button) self.grid:OnChipClick(self, button) end)
    chip:SetScript("OnDragStart", function(self) self.grid:BeginDrag(self) end)
    chip:SetScript("OnDragStop", function(self) self.grid:EndDrag(self) end)
    return chip
end

local function setChip(chip, m)
    chip.member = m
    chip.key = m and m.key or nil
    if not m then
        chip.cls:Hide()
        chip.spec:Hide()
        chip.fs:SetText("|cff505050empty|r")
        chip.picked:Hide()
        chip:EnableMouse(chip.slot ~= nil and chip.grid.opts.isEditable())
        return
    end
    chip:EnableMouse(true)
    UI():ClassIcon(chip.cls, m.c)
    local icon = Comp():SpecIcon(m.c, m.sp)
    if icon then
        chip.spec:SetTexture(icon)
        chip.spec:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        chip.spec:SetAlpha(m.auto and 0.55 or 1)
        chip.spec:Show()
    else
        chip.spec:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        chip.spec:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        chip.spec:SetAlpha(0.5)
        chip.spec:Show()
    end
    chip.fs:SetText(UI():ColoredName(m.key, m.c))
    chip.fs:SetAlpha(m.dim and 0.55 or 1)
    chip.cls:SetAlpha(m.dim and 0.55 or 1)
    chip.picked:SetShown(chip.grid.picked == m.key)
end

---------------------------------------------------------------------------
-- Buff icons
---------------------------------------------------------------------------

local function buffTooltip(btn)
    local e = btn.entry
    if not e then return end
    GameTooltip:SetOwner(btn, "ANCHOR_TOP")
    GameTooltip:AddLine(e.buff.name .. (e.buff.debuff and " (debuff)" or ""))
    if e.buff.tip then GameTooltip:AddLine(e.buff.tip, 1, 1, 1, true) end
    if #e.providers > 0 then
        local names = {}
        for _, key in ipairs(e.providers) do names[#names + 1] = UI():ColoredName(key) end
        GameTooltip:AddLine("From: " .. tconcat(names, ", "), 0.85, 0.85, 0.85, true)
    else
        GameTooltip:AddLine(btn.missingText or "Nobody brings this.", 1, 0.4, 0.4, true)
    end
    GameTooltip:Show()
end

local function createBuffIcon(parent, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetAllPoints()
    b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    b.count:SetPoint("BOTTOMRIGHT", 2, -1)
    b:SetScript("OnEnter", buffTooltip)
    b:SetScript("OnLeave", hideTooltip)
    return b
end

local function setBuffIcon(b, entry, lit)
    b.entry = entry
    b.tex:SetTexture(Comp():BuffIcon(entry.buff))
    if b.tex.SetDesaturated then b.tex:SetDesaturated(not lit) end
    b.tex:SetAlpha(lit and 1 or 0.35)
    b.count:SetText(entry.buff.count and #entry.providers > 1 and #entry.providers or "")
    b:Show()
end

---------------------------------------------------------------------------
-- Grid
---------------------------------------------------------------------------

local Grid = {}
Grid.__index = Grid

-- Whole groups trade places with the "swap" link on a group's header: click it, then click the other group (its
-- swap link or anywhere on it); opts.onSwapGroups(a, b) does the change.
-- opts = { getSize() -> 10|25, getMembers() -> { { key, c, sp, auto, source, extra } }, getGroups() -> { [key] = g },
--          getSeats() -> { [key] = 1..5 } (optional; players without a valid seat fill the free ones in role order),
--          onSwapGroups(a, b),
--          isEditable() -> bool, onDrop(key, group|nil, targetKey|nil, seat|nil, shown), onMenu(root, key) (optional),
--          (shown = every placed player's seat as drawn { [key] = 1..5 })
--          poolLabel = "Not in a group" }
function GroupsUI:CreateGrid(parent, opts)
    local grid = setmetatable({ opts = opts, boxes = {}, picked = nil }, Grid)
    local f = CreateFrame("Frame", nil, parent)
    grid.frame = f

    -- Raid-wide strip
    f.stripLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.stripLabel:SetPoint("TOPLEFT", 2, -4)
    f.stripLabel:SetText("Raid-wide")
    grid.strip = {}
    for i = 1, 20 do
        local b = createBuffIcon(f, 18)
        if i == 1 then b:SetPoint("LEFT", f.stripLabel, "RIGHT", 6, 0) else b:SetPoint("LEFT", grid.strip[i - 1], "RIGHT", 2, 0) end
        b:Hide()
        grid.strip[i] = b
    end

    -- Group boxes (up to 8; 2 or 5 are shown)
    for g = 1, 8 do
        local box = CreateFrame("Button", nil, f, "BackdropTemplate")
        box:SetSize(BOX_W, BOX_H)
        local col, row = (g - 1) % COLS, floor((g - 1) / COLS)
        box:SetPoint("TOPLEFT", col * (BOX_W + GAP), -(STRIP_H + 4) - row * (BOX_H + GAP))
        if box.SetBackdrop then
            box:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12,
                insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            box:SetBackdropColor(0.08, 0.08, 0.08, 0.85)
            box:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)
        end
        box.group = g
        box.title = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        box.title:SetPoint("TOPLEFT", 6, -4)
        box.title:SetText("Group " .. g)
        box.countFs = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        box.countFs:SetPoint("TOPRIGHT", -6, -4)
        local swap = CreateFrame("Button", nil, box)
        swap:SetSize(40, 14)
        swap:SetPoint("RIGHT", box.countFs, "LEFT", -6, 0)
        swap.fs = swap:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        swap.fs:SetPoint("CENTER")
        local shl = swap:CreateTexture(nil, "HIGHLIGHT")
        shl:SetAllPoints()
        shl:SetColorTexture(1, 1, 1, 0.15)
        swap:SetScript("OnClick", function() grid:OnSwapClick(g) end)
        swap:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            if grid.swapFrom == g then
                GameTooltip:AddLine("Click another group to swap it with group " .. g .. ", or here to cancel.", 1, 1, 1, true)
            elseif grid.swapFrom then
                GameTooltip:AddLine("Swap group " .. grid.swapFrom .. " with group " .. g, 1, 1, 1, true)
            else
                GameTooltip:AddLine("Swap groups")
                GameTooltip:AddLine("Click here, then click another group: all their players trade places.", 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
        swap:SetScript("OnLeave", hideTooltip)
        box.swap = swap
        box.chips = {}
        for s = 1, SLOTS do
            local chip = createChip(box, grid)
            chip.slot = s
            chip:SetPoint("TOPLEFT", 4, -HEADER_H - (s - 1) * CHIP_H)
            box.chips[s] = chip
        end
        box.buffs = {}
        for i = 1, 9 do
            local b = createBuffIcon(box, 15)
            b:SetPoint("BOTTOMLEFT", 5 + (i - 1) * 16, 5)
            b.missingText = "Not in this group."
            b:Hide()
            box.buffs[i] = b
        end
        box:RegisterForClicks("LeftButtonUp")
        box:SetScript("OnClick", function(self) grid:OnGroupClick(self.group) end)
        box:SetScript("OnEnter", function(self)
            if grid.picked then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine("Click to move " .. ns.Util.ShortName(grid.picked) .. " to group " .. self.group)
                GameTooltip:Show()
            end
        end)
        box:SetScript("OnLeave", hideTooltip)
        grid.boxes[g] = box
    end

    -- Pool of members without a group
    local pool = CreateFrame("Button", nil, f)
    grid.pool = pool
    pool:RegisterForClicks("LeftButtonUp")
    pool:SetScript("OnClick", function() grid:OnPoolClick() end)
    pool.label = pool:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pool.label:SetPoint("TOPLEFT", 2, -2)
    pool.list = UI():CreateScrollList(pool, CHIP_H + 2, function(row, d) grid:InitPoolRow(row, d) end)
    pool.list.frame:SetPoint("TOPLEFT", 0, -18)
    pool.list.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    pool.list:SetEmptyText("")
    return grid
end

function Grid:GroupCount()
    return Comp():GroupCount(self.opts.getSize())
end

function Grid:InitPoolRow(row, d)
    if not row.chips then
        row.chips = {}
        for i = 1, POOL_COLS do
            local chip = createChip(row, self)
            chip:SetPoint("LEFT", (i - 1) * (BOX_W + GAP) + 4, 0)
            row.chips[i] = chip
        end
        row:SetScript("OnClick", function() self:OnPoolClick() end)
    end
    for i, chip in ipairs(row.chips) do
        local m = d[i]
        chip:SetShown(m ~= nil)
        if m then setChip(chip, m) end
    end
end

local function memberLess(a, b)
    local ra = Comp():RoleOf(a.c, a.sp) or "z"
    local rb = Comp():RoleOf(b.c, b.sp) or "z"
    local order = { tank = 1, healer = 2, melee = 3, ranged = 4, z = 5 }
    if order[ra] ~= order[rb] then return order[ra] < order[rb] end
    return ns.Util.ShortName(a.key):lower() < ns.Util.ShortName(b.key):lower()
end

function Grid:Refresh()
    local members = self.opts.getMembers() or {}
    local groups = self.opts.getGroups() or {}
    local seats = self.opts.getSeats and self.opts.getSeats() or {}
    self.shown = {}
    local n = self:GroupCount()
    local byGroup, pool = {}, {}
    for g = 1, 8 do byGroup[g] = {} end
    for _, m in ipairs(members) do
        local g = groups[m.key]
        if g and g <= n and #byGroup[g] < SLOTS then
            local list = byGroup[g]
            list[#list + 1] = m
        else
            pool[#pool + 1] = m
        end
    end
    if self.picked then
        local found = false
        for _, m in ipairs(members) do if m.key == self.picked then found = true end end
        if not found or not self.opts.isEditable() then self.picked = nil end
    end

    -- raid-wide strip: every member of the team / raid counts
    local cov = Comp():Coverage(members, "raid")
    for i, b in ipairs(self.strip) do
        local e = cov[i]
        if e then setBuffIcon(b, e, #e.providers > 0) else b:Hide() end
    end

    for g, box in ipairs(self.boxes) do
        local shown = g <= n
        box:SetShown(shown)
        if shown then
            local list = byGroup[g]
            -- players sit in their seat; those without one (or whose seat is taken) fill the free seats by role
            local bySeat, rest = {}, {}
            for _, m in ipairs(list) do
                local s = seats[m.key]
                if type(s) == "number" and s >= 1 and s <= SLOTS and not bySeat[s] then bySeat[s] = m
                else rest[#rest + 1] = m end
            end
            tsort(rest, memberLess)
            local r = 1
            for s = 1, SLOTS do
                if not bySeat[s] and rest[r] then bySeat[s], r = rest[r], r + 1 end
                if bySeat[s] then self.shown[bySeat[s].key] = s end
            end
            for s, chip in ipairs(box.chips) do setChip(chip, bySeat[s]) end
            box.countFs:SetText(#list .. "/" .. SLOTS)
            local canSwap = self.opts.isEditable() and self.opts.onSwapGroups ~= nil
            box.swap:SetShown(canSwap)
            if self.swapFrom == g then
                box.swap.fs:SetText("|cff33ff33cancel|r")
            elseif self.swapFrom then
                box.swap.fs:SetText("|cffffd100here|r")
            else
                box.swap.fs:SetText("swap")
            end
            local present = {}
            for _, e in ipairs(Comp():Coverage(list, "party")) do
                if #e.providers > 0 then present[#present + 1] = e end
            end
            for i, b in ipairs(box.buffs) do
                if present[i] then setBuffIcon(b, present[i], true) else b:Hide() end
            end
            if box.SetBackdropBorderColor then
                if self.swapFrom == g then box:SetBackdropBorderColor(0.2, 1, 0.2, 1)
                elseif self.picked or self.swapFrom then box:SetBackdropBorderColor(1, 0.82, 0, 1)
                else box:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9) end
            end
        end
    end

    -- pool below the last row of boxes
    local rows = ceil(n / COLS)
    self.pool:ClearAllPoints()
    self.pool:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -(STRIP_H + 4) - rows * (BOX_H + GAP))
    self.pool:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", 0, 0)
    tsort(pool, memberLess)
    self.pool.label:SetText((self.opts.poolLabel or "Not in a group") .. " (" .. #pool .. ")")
    local rowsData = {}
    for i = 1, #pool, POOL_COLS do
        rowsData[#rowsData + 1] = { pool[i], pool[i + 1], pool[i + 2] }
    end
    self.pool.list:SetData(rowsData)
end

---------------------------------------------------------------------------
-- Moving members
---------------------------------------------------------------------------

-- group nil = out of the groups; targetKey = the member dropped onto (swap); seat = the empty seat dropped onto.
function Grid:Drop(key, group, targetKey, seat)
    self.picked = nil
    if key and self.opts.isEditable() then self.opts.onDrop(key, group, targetKey, seat, self.shown or {}) end
    self:Refresh()
end

function Grid:Pick(key)
    self.picked = key
    self:Refresh()
end

function Grid:GetPicked() return self.picked end

local function groupOfChip(chip)
    local parent = chip:GetParent()
    return parent and parent.group or nil
end

function Grid:OnChipClick(chip, button)
    if not chip.key then
        -- an empty seat: take it with the picked player (or act as the group box)
        local g = groupOfChip(chip)
        if button ~= "LeftButton" or not g or not self.opts.isEditable() then return end
        if self.swapFrom then return self:OnSwapClick(g) end
        if self.picked then self:Drop(self.picked, g, nil, chip.slot) end
        return
    end
    if button == "RightButton" then
        if self.opts.onMenu and self.opts.isEditable() then
            local key = chip.key
            UI():ContextMenu(chip, function(root) self.opts.onMenu(root, key) end)
        end
        return
    end
    if not self.opts.isEditable() then return end
    if self.picked == chip.key then
        self:Pick(nil)
    elseif self.picked then
        self:Drop(self.picked, groupOfChip(chip), chip.key)
    else
        self:Pick(chip.key)
    end
end

function Grid:OnGroupClick(g)
    if self.swapFrom then return self:OnSwapClick(g) end
    if self.picked then self:Drop(self.picked, g) end
end

-- Swaps every player of group a with every player of group b.
function Grid:SwapGroups(a, b)
    self.swapFrom = nil
    if a and b and a ~= b and self.opts.isEditable() and self.opts.onSwapGroups then self.opts.onSwapGroups(a, b) end
    self:Refresh()
end

function Grid:OnSwapClick(g)
    if not self.opts.isEditable() then return end
    self.picked = nil
    if self.swapFrom == g then
        self.swapFrom = nil
        self:Refresh()
    elseif self.swapFrom then
        self:SwapGroups(self.swapFrom, g)
    else
        self.swapFrom = g
        self:Refresh()
    end
end

function Grid:OnPoolClick()
    if self.picked then self:Drop(self.picked, nil) end
end

local function ensureGhost()
    if ghost then return ghost end
    ghost = CreateFrame("Frame", nil, UIParent)
    ghost:SetSize(BOX_W - 8, CHIP_H)
    ghost:SetFrameStrata("TOOLTIP")
    ghost.fs = ghost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ghost.fs:SetPoint("LEFT", 2, 0)
    ghost.bg = ghost:CreateTexture(nil, "BACKGROUND")
    ghost.bg:SetAllPoints()
    ghost.bg:SetColorTexture(0, 0, 0, 0.7)
    ghost:SetScript("OnUpdate", function(self)
        local x, y = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        self:ClearAllPoints()
        self:SetPoint("LEFT", UIParent, "BOTTOMLEFT", x / s + 8, y / s)
    end)
    ghost:Hide()
    return ghost
end

function Grid:BeginDrag(chip)
    if not chip.key or not self.opts.isEditable() then return end
    self.dragging = chip.key
    local g = ensureGhost()
    g.fs:SetText(UI():ColoredName(chip.key, chip.member and chip.member.c))
    g:Show()
end

-- Finds what the cursor is over: a chip in a group (swap), an empty seat, a group box, or the pool.
function Grid:EndDrag()
    local key = self.dragging
    self.dragging = nil
    if ghost then ghost:Hide() end
    if not key then return end
    for g, box in ipairs(self.boxes) do
        if box:IsShown() and box:IsMouseOver() then
            local target, seat
            for _, chip in ipairs(box.chips) do
                if chip:IsMouseOver() then
                    if chip.key and chip.key ~= key then target = chip.key
                    elseif not chip.key then seat = chip.slot end
                end
            end
            self:Drop(key, g, target, seat)
            return
        end
    end
    if self.pool:IsMouseOver() then self:Drop(key, nil) end
end

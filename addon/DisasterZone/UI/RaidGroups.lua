if DisasterZoneBoot and DisasterZoneBoot.Run("UI/RaidGroups.lua", ...) then return end -- DisasterZone: UI/RaidGroups.lua
-- The group grid (Addendum J §59-§60): a raid-wide buff strip, group boxes (2 for 10-man, 5 for 25-man) with the party
-- buffs each group has in its header, a "Not in a group" pool, and (opts.waitlist, the Teams page) a waitlist under it. Members are chips (class circle, name, role icon;
-- the spec is in the tooltip). The boxes share the grid's width, three to a row. Organizers move them by dragging, or
-- by clicking a chip and then a group (or another chip, to swap; or an empty slot, to take it); right-click opens the
-- caller's menu. Each player keeps a seat (1-5) in their group, so the order is the organizer's. Used by the Teams
-- view (a team's layout) and by a raid's Groups tab.
local addonName, ns = ...

local GroupsUI = ns:NewModule("RaidGroupsUI")

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tsort, tconcat = table.sort, table.concat

local BOX_W, CHIP_H, GAP = 154, 20, 6   -- BOX_W: the narrowest a box gets; boxes share the grid's width
local COLS = 3
local HEADER_H = 26
local SLOTS = 5
local BOX_H = HEADER_H + SLOTS * CHIP_H + 7
local STRIP_H = 26
local POOL_COLS = 3
-- the row layout (opts.layout = "row", a raid's Groups tab): five columns, the party buffs in a footer
local ROW_COLS, ROW_GAP = 5, 8
local FOOTER_H = 24
local ROW_BOX_H = HEADER_H + SLOTS * CHIP_H + FOOTER_H + 4
local BUFF_ROW = 18                      -- a party buff icon and its gap

local ghost          -- the frame following the cursor while dragging

local function Comp() return ns.RaidComp end
local function UI() return ns.UI end

-- A flat panel: dark fill and 1px edges (the Dungeons tab's cards).
local function flatPanel(f, a)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0.08, 0.08, 0.095, a or 0.92)
    UI():AddEdges(f, "BORDER")
    UI():SetEdgeColor(f, 0.34, 0.34, 0.38, 0.5)
end

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
    local grid = chip.grid
    local mine = grid and grid.opts.isMe and grid.opts.isMe(m.key)
    GameTooltip:SetOwner(chip, "ANCHOR_RIGHT")
    GameTooltip:AddLine(UI():ColoredName(m.key, m.c) .. (mine and " |cff9e9e9e(you)|r" or ""))
    local label = Comp():SpecLabel(m.c, m.sp)
    local cls = m.c and ns.CLASS_NAMES[m.c] or ""
    if label then
        GameTooltip:AddLine(label .. " " .. cls, 1, 1, 1)
        local whose = mine and "your" or "their"
        if m.auto then GameTooltip:AddLine(m.source == "bis" and ("Spec from " .. whose .. " BiS list")
            or ("Spec from " .. whose .. " last sign-up"), 0.6, 0.6, 0.6) end
    else
        GameTooltip:AddLine(cls .. " · spec unknown", 1, 1, 1)
    end
    -- in a group, a shaman lists only the air totem that group gets
    local g = chip:GetParent().group
    local air = g and grid and grid.air and grid.air[g]
    local brings = {}
    for _, b in ipairs(Comp().BUFFS) do
        if Comp():Provides(b.key, m.c, m.sp) and not (b.air and air and air ~= b.key) then
            brings[#brings + 1] = iconText(Comp():BuffIcon(b)) .. " " .. b.name
        end
    end
    if #brings > 0 then
        GameTooltip:AddLine(" ")
        for _, line in ipairs(brings) do GameTooltip:AddLine(line, 0.85, 0.85, 0.85) end
    end
    if m.extra then GameTooltip:AddLine(m.extra, 1, 0.82, 0, true) end
    for _, line in ipairs(m.info or {}) do GameTooltip:AddLine(line, 0.75, 0.75, 0.75, true) end
    if grid and grid.opts.isEditable() then
        GameTooltip:AddLine(" ")
        if grid.opts.onRoleClick and m.c then
            GameTooltip:AddLine("Click the role icon to set the spec.", 0.6, 0.6, 0.6, true)
        end
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
    chip.cls:SetSize(16, 16)
    chip.cls:SetPoint("LEFT", 2, 0)
    chip.spec = chip:CreateTexture(nil, "ARTWORK")
    chip.spec:SetSize(13, 13)
    chip.spec:SetPoint("RIGHT", -3, 0)
    chip.spec:SetTexture(UI().ROLE_TEX)
    chip.fs = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    do
        local path, _, flags = chip.fs:GetFont()
        if path then chip.fs:SetFont(path, 12, flags) end
    end
    chip.fs:SetPoint("LEFT", chip.cls, "RIGHT", 6, 0)
    chip.fs:SetPoint("RIGHT", chip.spec, "LEFT", -4, 0)
    chip.fs:SetJustifyH("LEFT")
    chip.fs:SetWordWrap(false)
    local hl = chip:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.07)
    chip.picked = chip:CreateTexture(nil, "BACKGROUND")
    chip.picked:SetAllPoints()
    chip.picked:SetColorTexture(1, 0.82, 0, 0.25)
    chip.picked:Hide()
    -- an empty seat is a faint fill, for who can drop a player there (the group's "4/5" already counts them)
    chip.seat = chip:CreateTexture(nil, "BACKGROUND")
    chip.seat:SetPoint("TOPLEFT", 0, -1)
    chip.seat:SetPoint("BOTTOMRIGHT", 0, 1)
    chip.seat:SetColorTexture(1, 1, 1, 0.035)
    chip.seat:Hide()
    -- my own chip in a read-only grid (opts.isMe): a gold wash and a 2px gold bar in the box's margin
    chip.me = chip:CreateTexture(nil, "BACKGROUND")
    chip.me:SetAllPoints()
    chip.me:SetColorTexture(1, 0.82, 0, 0.12)
    chip.me:Hide()
    chip.meBar = chip:CreateTexture(nil, "BORDER")
    chip.meBar:SetPoint("TOPLEFT", chip, "TOPLEFT", -4, -2)
    chip.meBar:SetPoint("BOTTOMLEFT", chip, "BOTTOMLEFT", -4, 2)
    chip.meBar:SetWidth(2)
    chip.meBar:SetColorTexture(1, 0.82, 0, 1)
    chip.meBar:Hide()
    -- (opts.onRoleClick) the role icon is a small button of its own: a click picks the spec
    local rb = CreateFrame("Button", nil, chip)
    rb:SetSize(19, 18)
    rb:SetPoint("CENTER", chip.spec, "CENTER", 0, 0)
    rb.hl = rb:CreateTexture(nil, "BACKGROUND")
    rb.hl:SetAllPoints()
    rb.hl:SetColorTexture(1, 1, 1, 0.12)
    UI():AddEdges(rb, "BORDER")
    UI():SetEdgeColor(rb, 1, 0.82, 0, 0.6)
    local function lit(on)
        rb.hl:SetShown(on)
        for _, e in ipairs(rb.edges) do e:SetShown(on) end
    end
    lit(false)
    -- (no spec known yet: a grey "?" where the role icon goes)
    rb.unknown = rb:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    rb.unknown:SetPoint("CENTER", 0, 0)
    rb.unknown:SetText("?")
    rb:RegisterForClicks("LeftButtonUp")
    rb:RegisterForDrag("LeftButton")
    rb:SetScript("OnEnter", function() lit(true); chipTooltip(chip) end)
    rb:SetScript("OnLeave", function() lit(false); hideTooltip() end)
    rb:SetScript("OnClick", function()
        local g = chip.grid
        if chip.key and g.opts.onRoleClick and g.opts.isEditable() then g.opts.onRoleClick(chip.key, rb) end
    end)
    rb:SetScript("OnDragStart", function() chip.grid:BeginDrag(chip) end)
    rb:SetScript("OnDragStop", function() chip.grid:EndDrag(chip) end)
    rb:Hide()
    chip.roleBtn = rb
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
    local opts = chip.grid.opts
    local editable = opts.isEditable()
    chip.seat:SetShown(m == nil and chip.slot ~= nil and editable)
    local mine = m ~= nil and not editable and opts.isMe ~= nil and opts.isMe(m.key) and true or false
    chip.me:SetShown(mine)
    chip.meBar:SetShown(mine)
    if not m then
        chip.cls:Hide()
        chip.spec:Hide()
        chip.roleBtn:Hide()
        chip.fs:SetText("")
        chip.picked:Hide()
        chip:EnableMouse(chip.slot ~= nil and editable)
        return
    end
    chip:EnableMouse(true)
    UI():ClassIcon(chip.cls, m.c)
    -- the role (the spec is in the tooltip); a spec guessed from a BiS list or an old sign-up shows fainter
    local role = Comp():RoleOf(m.c, m.sp)
    if role then
        UI():SetRoleIcon(chip.spec, role)
        chip.spec:SetAlpha(m.auto and 0.5 or 1)
        chip.spec:Show()
    else
        chip.spec:Hide()
    end
    local rb = chip.roleBtn
    rb:SetShown(editable and opts.onRoleClick ~= nil and m.c ~= nil and not m.noRole)
    rb.unknown:SetShown(role == nil)
    chip.fs:SetText((m.prefix or "") .. UI():ColoredName(m.key, m.c))
    chip.fs:SetAlpha(m.dim and 0.55 or 1)
    chip.cls:SetAlpha(m.dim and 0.55 or 1)
    chip.picked:SetShown(chip.grid.picked == m.key)
end

---------------------------------------------------------------------------
-- Buff icons
---------------------------------------------------------------------------

-- "the Survival Hunter slot" / "the Survival Hunter and Arms Warrior slots" (gold names)
local function slotWords(slots)
    local names = {}
    for i, sl in ipairs(slots or {}) do names[i] = "|cffffd100" .. tostring(sl.name) .. "|r" end
    if #names == 0 then return nil end
    if #names == 1 then return "the " .. names[1] .. " slot is" end
    return "the " .. tconcat(names, ", ", 1, #names - 1) .. " and " .. names[#names] .. " slots are"
end

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
    elseif e.state == "planned" and slotWords(e.slots) then
        -- (a target comp plans it: its slot is open)
        GameTooltip:AddLine("Planned: " .. slotWords(e.slots) .. " open.", 1, 1, 1, true)
    else
        GameTooltip:AddLine(e.offText or btn.missingText or "Nobody brings this.", 1, 0.4, 0.4, true)
    end
    if e.note then GameTooltip:AddLine(e.note, 0.6, 0.6, 0.6, true) end
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
    -- planned (a target comp's open slot would bring it): a gold outline
    UI():AddEdges(b, "OVERLAY")
    UI():SetEdgeColor(b, 1, 0.82, 0, 0.9)
    for _, e in ipairs(b.edges) do e:Hide() end
    b:SetScript("OnEnter", buffTooltip)
    b:SetScript("OnLeave", hideTooltip)
    return b
end

-- entry.state (RaidComp:BuffStates): "have" lit, "planned" dimmed with a gold outline, "off" faded; without a state
-- `lit` says it.
local function setBuffIcon(b, entry, lit)
    b.entry = entry
    if entry.state then lit = entry.state == "have" end
    local planned = entry.state == "planned"
    b.tex:SetTexture(Comp():BuffIcon(entry.buff))
    if b.tex.SetDesaturated then b.tex:SetDesaturated(not lit and not planned) end
    b.tex:SetAlpha((lit and 1) or (planned and 0.5) or 0.35)
    for _, e in ipairs(b.edges or {}) do e:SetShown(planned) end
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
--          poolLabel = "Not in a group",
--          stripParent = a frame for the raid-buff icons (no label; the grid starts with the groups),
--          stripRoom() -> the width they may take there (optional),
--          layout = "row" (optional: all groups side by side, the pool on their columns, the grid as tall as its
--                   content; the default is three columns with a scrolling pool under them),
--          isMe(key) -> bool (optional: my own chip is lit gold in a read-only grid),
--          onRoleClick(key, button) (optional: editors click a chip's role icon, e.g. to pick the spec),
--          poolEmpty() -> text (optional: the empty pool's line for editors),
--          poolTip = { title, text } (optional: the pool's tooltip, on its empty space),
--          buffStates(placed, members) -> the strip's entries (optional, RaidComp:BuffStates' shape: lit / planned /
--                   off; placed = the members in the shown groups),
--          waitlist = (optional, row layout) a second pool under everything, in its own order: { label, tip = { title,
--                   text }, getMembers() -> { member, ... } (shown in that order; prefix = text before the name,
--                   noRole = no spec button), empty() -> text or nil (nil and nobody on it: hidden) }. Its players
--                   are dragged (or picked) into a group or the pool like the others (onDrop); nothing is dropped
--                   onto it. grid.wait is its frame (the caller may put a button in its header). }
function GroupsUI:CreateGrid(parent, opts)
    local grid = setmetatable({ opts = opts, boxes = {}, picked = nil }, Grid)
    local f = CreateFrame("Frame", nil, parent)
    grid.frame = f

    -- Raid-wide strip: under a label on top of the grid, or (opts.stripParent) icons alone on the caller's row
    local host = opts.stripParent or f
    grid.top = opts.stripParent and 0 or (STRIP_H + 6)
    if not opts.stripParent then
        f.stripLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.stripLabel:SetPoint("TOPLEFT", 2, -7)
        f.stripLabel:SetTextColor(0.62, 0.62, 0.62)
        f.stripLabel:SetText("Raid buffs")
    end
    grid.strip = {}
    for i = 1, 20 do
        local b = createBuffIcon(host, 20)
        if i > 1 then b:SetPoint("LEFT", grid.strip[i - 1], "RIGHT", 2, 0)
        elseif f.stripLabel then b:SetPoint("LEFT", f.stripLabel, "RIGHT", 6, 0)
        else b:SetPoint("LEFT", host, "LEFT", 0, 0) end
        b:Hide()
        grid.strip[i] = b
    end

    -- Group boxes (up to 8; 2 or 5 are shown)
    for g = 1, 8 do
        local box = CreateFrame("Button", nil, f)
        box:SetSize(BOX_W, BOX_H)
        flatPanel(box)
        box.group = g
        box.title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        box.title:SetPoint("TOPLEFT", 8, -7)
        box.title:SetText("Group " .. g)
        box.countFs = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        box.countFs:SetPoint("TOPRIGHT", -8, -8)
        box.rule = box:CreateTexture(nil, "BORDER")
        box.rule:SetColorTexture(1, 1, 1, 0.07)
        box.rule:SetHeight(1)
        box.rule:SetPoint("TOPLEFT", 6, -HEADER_H + 2)
        box.rule:SetPoint("TOPRIGHT", -6, -HEADER_H + 2)
        local swap = CreateFrame("Button", nil, box)
        swap:SetSize(36, 14)
        swap:SetPoint("LEFT", box.title, "RIGHT", 8, 0)
        swap.fs = swap:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        swap.fs:SetPoint("CENTER")
        local shl = swap:CreateTexture(nil, "HIGHLIGHT")
        shl:SetAllPoints()
        shl:SetColorTexture(1, 1, 1, 0)
        swap:SetScript("OnClick", function() grid:OnSwapClick(g) end)
        swap:SetScript("OnEnter", function(self)
            if not grid.swapFrom then self.fs:SetText("|cffffd100swap|r") end
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
        swap:SetScript("OnLeave", function(self)
            if not grid.swapFrom then self.fs:SetText("|cff8c8c8cswap|r") end
            hideTooltip()
        end)
        box.swap = swap
        box.chips = {}
        for s = 1, SLOTS do
            local chip = createChip(box, grid)
            chip.slot = s
            chip:SetPoint("TOPLEFT", 6, -HEADER_H - 1 - (s - 1) * CHIP_H)
            chip:SetPoint("RIGHT", box, "RIGHT", -6, 0)
            chip:SetHeight(CHIP_H)
            box.chips[s] = chip
        end
        box.buffs = {}
        -- what the party gets from its own members: right to left before the count, or (row layout) in the footer
        for i = 1, 9 do
            local b = createBuffIcon(box, opts.layout == "row" and 16 or 14)
            if opts.layout == "row" then
                b:SetPoint("BOTTOMLEFT", 8 + (i - 1) * BUFF_ROW, 6)
            elseif i == 1 then
                b:SetPoint("RIGHT", box.countFs, "LEFT", -6, 0)
            else
                b:SetPoint("RIGHT", box.buffs[i - 1], "LEFT", -2, 0)
            end
            b.missingText = "Not in this group."
            b:Hide()
            box.buffs[i] = b
        end
        if opts.layout == "row" then
            box.footRule = box:CreateTexture(nil, "BORDER")
            box.footRule:SetColorTexture(1, 1, 1, 0.05)
            box.footRule:SetHeight(1)
            box.footRule:SetPoint("BOTTOMLEFT", 6, FOOTER_H)
            box.footRule:SetPoint("BOTTOMRIGHT", -6, FOOTER_H)
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
    flatPanel(pool, 0.6)
    pool:RegisterForClicks("LeftButtonUp")
    pool:SetScript("OnClick", function() grid:OnPoolClick() end)
    pool.label = pool:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pool.label:SetTextColor(0.62, 0.62, 0.62)
    pool.label:SetPoint("TOPLEFT", 8, -7)
    pool.label:SetJustifyH("LEFT")
    if opts.layout == "row" then
        pool.chips = {}
        pool.empty = pool:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        pool.empty:SetPoint("TOPLEFT", 8, -26)
        pool.empty:SetJustifyH("LEFT")
        pool.empty:SetText("Drop a player here to take them out of the groups.")
    else
        pool.list = UI():CreateScrollList(pool, CHIP_H + 2, function(row, d) grid:InitPoolRow(row, d) end)
        pool.list.frame:SetPoint("TOPLEFT", 2, -22)
        pool.list.frame:SetPoint("BOTTOMRIGHT", -2, 2)
        pool.list:SetEmptyText("")
    end
    local function tipOn(frame, tip)
        if not tip then return end
        frame:SetScript("OnEnter", function(self)
            if grid.dragging or grid.picked then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(tip[1])
            GameTooltip:AddLine(tip[2], 1, 1, 1, true)
            GameTooltip:Show()
        end)
        frame:SetScript("OnLeave", hideTooltip)
    end
    tipOn(pool, opts.poolTip)
    -- (the Teams page) the waitlist: a pool of its own under everything, in its own order
    if opts.waitlist and opts.layout == "row" then
        local w = CreateFrame("Frame", nil, f)
        grid.wait = w
        flatPanel(w, 0.6)
        w:EnableMouse(true)
        w.label = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        w.label:SetTextColor(0.62, 0.62, 0.62)
        w.label:SetPoint("TOPLEFT", 8, -7)
        w.label:SetJustifyH("LEFT")
        w.chips = {}
        w.empty = w:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        w.empty:SetPoint("TOPLEFT", 8, -26)
        w.empty:SetPoint("RIGHT", w, "RIGHT", -8, 0)
        w.empty:SetJustifyH("LEFT")
        tipOn(w, opts.waitlist.tip)
        w:Hide()
    end
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
            row.chips[i] = chip
        end
        row:SetScript("OnClick", function() self:OnPoolClick() end)
    end
    local w = self.boxW or BOX_W
    for i, chip in ipairs(row.chips) do
        local m = d[i]
        chip:ClearAllPoints()
        chip:SetPoint("LEFT", (i - 1) * (w + GAP) + 6, 0)
        chip:SetSize(w - 12, CHIP_H)
        chip:SetShown(m ~= nil)
        if m then setChip(chip, m) end
    end
end

-- (m.later: after the others, e.g. the Teams page's players placed in another lineup)
local function memberLess(a, b)
    if (a.later and true or false) ~= (b.later and true or false) then return not a.later end
    local ra = Comp():RoleOf(a.c, a.sp) or "z"
    local rb = Comp():RoleOf(b.c, b.sp) or "z"
    local order = { tank = 1, healer = 2, melee = 3, ranged = 4, z = 5 }
    if order[ra] ~= order[rb] then return order[ra] < order[rb] end
    return ns.Util.ShortName(a.key):lower() < ns.Util.ShortName(b.key):lower()
end

function Grid:Refresh()
    local members = self.opts.getMembers() or {}
    local waiting = self.wait and self.opts.waitlist.getMembers() or {}
    if self.dragging then
        local rest, wrest = {}, {}
        for _, m in ipairs(members) do if m.key ~= self.dragging then rest[#rest + 1] = m end end
        for _, m in ipairs(waiting) do if m.key ~= self.dragging then wrest[#wrest + 1] = m end end
        members, waiting = rest, wrest
    end
    local groups = self.opts.getGroups() or {}
    local seats = self.opts.getSeats and self.opts.getSeats() or {}
    self.shown, self.air = {}, {}
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
        for _, m in ipairs(waiting) do if m.key == self.picked then found = true end end
        if not found or not self.opts.isEditable() then self.picked = nil end
    end

    -- raid-wide strip: every member of the team / raid counts, or (opts.buffStates) what the caller makes of who
    -- sits in the groups (RaidComp:BuffStates: lit / planned / off)
    local cov
    if self.opts.buffStates then
        local placed = {}
        for g = 1, n do
            for _, m in ipairs(byGroup[g]) do placed[#placed + 1] = m end
        end
        cov = self.opts.buffStates(placed, members) or {}
    else
        cov = Comp():Coverage(members, "raid")
    end
    -- (on the caller's row: as large as the room left there allows, 20 down to 14)
    local size = 20
    local room = self.opts.stripRoom and self.opts.stripRoom()
    if room then
        while size > 14 and #cov * (size + 2) > room do size = size - 2 end
    end
    for i, b in ipairs(self.strip) do
        local e = cov[i]
        b:SetSize(size, size)
        if e and (not room or i * (size + 2) <= room + 2) then setBuffIcon(b, e, #(e.providers or {}) > 0) else b:Hide() end
    end

    local row_ = self.opts.layout == "row"
    local cols, gap, boxH = row_ and ROW_COLS or COLS, row_ and ROW_GAP or GAP, row_ and ROW_BOX_H or BOX_H
    local fw = self.frame:GetWidth() or 0
    local bw = floor((fw - (cols - 1) * gap) / cols)
    if fw < 100 then bw = BOX_W end
    if not row_ then bw = max(BOX_W, bw) end
    self.boxW = bw
    -- (row layout: column i starts at x(i); the widths share the rounding, so the last ends on the frame's edge)
    local function x(i) return row_ and fw >= 100 and floor(i * (fw + gap) / cols + 0.5) or i * (bw + gap) end
    self.colX = x
    for g, box in ipairs(self.boxes) do
        local shown = g <= n
        box:SetShown(shown)
        local col, row = (g - 1) % cols, floor((g - 1) / cols)
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x(col), -self.top - row * (boxH + gap))
        box:SetSize(x(col + 1) - gap - x(col), boxH)
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
            -- (a group without players has nothing to swap; while a swap is picked every group takes it)
            local canSwap = self.opts.isEditable() and self.opts.onSwapGroups ~= nil
            box.swap:SetShown(canSwap and (#list > 0 or self.swapFrom ~= nil))
            if self.swapFrom == g then
                box.swap.fs:SetText("|cff33ff33cancel|r")
            elseif self.swapFrom then
                box.swap.fs:SetText("|cffffd100here|r")
            else
                box.swap.fs:SetText("|cff8c8c8cswap|r")
            end
            self.air[g] = Comp():AirTotem(list)
            local present = {}
            for _, e in ipairs(Comp():Coverage(list, "party")) do
                if #e.providers > 0 then present[#present + 1] = e end
            end
            -- (the footer holds as many as its width does; the tooltip of each names who brings it)
            local room = row_ and floor((bw - 16 + 2) / BUFF_ROW) or #box.buffs
            for i, b in ipairs(box.buffs) do
                if present[i] and i <= room then setBuffIcon(b, present[i], true) else b:Hide() end
            end
            if self.swapFrom == g then UI():SetEdgeColor(box, 0.2, 1, 0.2, 0.9)
            elseif self.picked or self.swapFrom then UI():SetEdgeColor(box, 1, 0.82, 0, 0.75)
            else UI():SetEdgeColor(box, 0.34, 0.34, 0.38, 0.5) end
        end
    end

    tsort(pool, memberLess)
    self.pool.label:SetText((self.opts.poolLabel or "Not in a group") .. " (" .. #pool .. ")")
    if row_ then
        self:LayoutPoolRow(pool, n, bw, boxH)
        return self:LayoutWaitRow(waiting)
    end
    -- pool below the last row of boxes
    local rows = ceil(n / COLS)
    self.pool:ClearAllPoints()
    self.pool:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -self.top - rows * (BOX_H + GAP))
    self.pool:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", 0, 0)
    local rowsData = {}
    for i = 1, #pool, POOL_COLS do
        rowsData[#rowsData + 1] = { pool[i], pool[i + 1], pool[i + 2] }
    end
    self.pool.list:SetData(rowsData)
end

-- The row layout's pool: beside the groups when they leave columns free (10 players: two groups, the pool in the
-- other three), else under them across the width; its players on the groups' columns. The grid takes the height of
-- what it shows (the page around it scrolls).
function Grid:LayoutPoolRow(pool, n, bw, boxH)
    local p = self.pool
    local beside = n < ROW_COLS
    local col0 = beside and n or 0
    local pc = ROW_COLS - col0
    local boxesBottom = self.top + ceil(n / ROW_COLS) * (boxH + ROW_GAP) - ROW_GAP
    local top = self.top + (beside and 0 or (ceil(n / ROW_COLS) * (boxH + ROW_GAP)))
    local editable = self.opts.isEditable()
    local rows = max(1, ceil(#pool / pc))
    local h = 26 + rows * CHIP_H + 8
    if beside then h = max(h, boxH) end
    -- read-only and nobody outside the groups: nothing to show
    local show = #pool > 0 or editable
    p:SetShown(show)
    p:ClearAllPoints()
    local x = self.colX
    p:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x(col0), -top)
    p:SetSize(x(ROW_COLS) - ROW_GAP - x(col0), h)
    for i, m in ipairs(pool) do
        local chip = p.chips[i]
        if not chip then
            chip = createChip(p, self)
            p.chips[i] = chip
        end
        local c, r = (i - 1) % pc, floor((i - 1) / pc)
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", p, "TOPLEFT", x(col0 + c) - x(col0) + 6, -26 - r * CHIP_H)
        chip:SetSize(x(col0 + c + 1) - ROW_GAP - x(col0 + c) - 12, CHIP_H)
        chip:Show()
        setChip(chip, m)
    end
    for i = #pool + 1, #p.chips do
        p.chips[i]:Hide()
        p.chips[i].member, p.chips[i].key = nil, nil
    end
    p.empty:SetText(self.opts.poolEmpty and self.opts.poolEmpty() or "Drop a player here to take them out of the groups.")
    p.empty:SetShown(#pool == 0 and editable)
    self.height = max(boxesBottom, top + (show and h or 0))
    self.frame:SetHeight(self.height)
end

-- The waitlist (opts.waitlist) under the groups and the pool, across the width, its players on the groups' columns
-- in its order (row by row).
function Grid:LayoutWaitRow(list)
    local w = self.wait
    if not w then return end
    local wo = self.opts.waitlist
    local empty = wo.empty and wo.empty() or nil
    local show = #list > 0 or empty ~= nil
    w:SetShown(show)
    if not show then return end
    local x = self.colX
    local top = self.height + ROW_GAP
    local h = 26 + (#list > 0 and (ceil(#list / ROW_COLS) * CHIP_H) or 14) + 8
    w:ClearAllPoints()
    w:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -top)
    w:SetSize(x(ROW_COLS) - ROW_GAP, h)
    w.label:SetText(wo.label .. " (" .. #list .. ")")
    for i, m in ipairs(list) do
        local chip = w.chips[i]
        if not chip then
            chip = createChip(w, self)
            w.chips[i] = chip
        end
        local c, r = (i - 1) % ROW_COLS, floor((i - 1) / ROW_COLS)
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", w, "TOPLEFT", x(c) + 6, -26 - r * CHIP_H)
        chip:SetSize(x(c + 1) - ROW_GAP - x(c) - 12, CHIP_H)
        chip:Show()
        setChip(chip, m)
    end
    for i = #list + 1, #w.chips do
        w.chips[i]:Hide()
        w.chips[i].member, w.chips[i].key = nil, nil
    end
    w.empty:SetText(empty or "")
    w.empty:SetShown(#list == 0)
    self.height = top + h
    self.frame:SetHeight(self.height)
end

-- How tall the grid's content is (row layout), for a scroll frame around it.
function Grid:GetContentHeight() return self.height or 0 end

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
    elseif self.picked and self.wait and chip:GetParent() == self.wait then
        -- (nothing is put onto the waitlist: a click there picks that player instead)
        self:Pick(chip.key)
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

-- The card under the cursor while a player is dragged: the chip itself, lifted (a gold edge and a shadow), held
-- where it was grabbed.
local function ensureGhost()
    if ghost then return ghost end
    ghost = CreateFrame("Frame", nil, UIParent)
    ghost:SetSize(BOX_W - 12, CHIP_H)
    ghost:SetFrameStrata("TOOLTIP")
    ghost.shadow = ghost:CreateTexture(nil, "BACKGROUND", nil, -1)
    ghost.shadow:SetPoint("TOPLEFT", -3, 3)
    ghost.shadow:SetPoint("BOTTOMRIGHT", 4, -4)
    ghost.shadow:SetColorTexture(0, 0, 0, 0.45)
    ghost.bg = ghost:CreateTexture(nil, "BACKGROUND")
    ghost.bg:SetAllPoints()
    ghost.bg:SetColorTexture(0.14, 0.14, 0.16, 0.97)
    UI():AddEdges(ghost, "BORDER")
    UI():SetEdgeColor(ghost, 1, 0.82, 0, 0.85)
    ghost.cls = ghost:CreateTexture(nil, "ARTWORK")
    ghost.cls:SetSize(16, 16)
    ghost.cls:SetPoint("LEFT", 4, 0)
    ghost.role = ghost:CreateTexture(nil, "ARTWORK")
    ghost.role:SetSize(13, 13)
    ghost.role:SetPoint("RIGHT", -5, 0)
    ghost.role:SetTexture(UI().ROLE_TEX)
    ghost.fs = ghost:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    do
        local path, _, flags = ghost.fs:GetFont()
        if path then ghost.fs:SetFont(path, 12, flags) end
    end
    ghost.fs:SetPoint("LEFT", ghost.cls, "RIGHT", 6, 0)
    ghost.fs:SetPoint("RIGHT", ghost.role, "LEFT", -4, 0)
    ghost.fs:SetJustifyH("LEFT")
    ghost.fs:SetWordWrap(false)
    ghost:Hide()
    return ghost
end

local function cursorIn(frame)
    local x, y = GetCursorPosition()
    local s = frame:GetEffectiveScale()
    return x / s, y / s
end

-- The spot a drop would land on: lit gold (an empty seat, a player to swap with, the pool), red on a full group.
function Grid:ShowDropMarker(t)
    local m = self.marker
    if not m then
        m = CreateFrame("Frame", nil, self.frame)
        m.fill = m:CreateTexture(nil, "BACKGROUND")
        m.fill:SetAllPoints()
        UI():AddEdges(m, "BORDER")
        m:EnableMouse(false)
        self.marker = m
    end
    local over = t and (t.chip or t.box or (t.pool and self.pool))
    if not over then
        m:Hide()
        return
    end
    m:ClearAllPoints()
    m:SetAllPoints(over)
    m:SetFrameLevel(over:GetFrameLevel() + 5)
    if t.full then
        m.fill:SetColorTexture(1, 0.25, 0.25, 0.06)
        UI():SetEdgeColor(m, 1, 0.3, 0.3, 0.8)
    else
        m.fill:SetColorTexture(1, 0.82, 0, t.chip and 0.14 or 0.05)
        UI():SetEdgeColor(m, 1, 0.82, 0, 0.85)
    end
    m:Show()
end

-- What the cursor is over while dragging: { g, box, chip (the seat or player lit), target (swap), seat, full } or
-- { pool = true }, or nil.
function Grid:DropTarget()
    local key = self.dragging
    for g, box in ipairs(self.boxes) do
        if box:IsShown() and box:IsMouseOver() then
            local t = { g = g, box = box }
            for _, chip in ipairs(box.chips) do
                if chip:IsMouseOver() then
                    if chip.key and chip.key ~= key then t.target, t.chip = chip.key, chip
                    elseif not chip.key then t.seat, t.chip = chip.slot, chip end
                end
            end
            if not t.chip then
                -- the group itself: the first free seat, or full
                for _, chip in ipairs(box.chips) do
                    if not chip.key then
                        t.chip, t.seat = chip, chip.slot
                        break
                    end
                end
                t.full = t.chip == nil
            end
            return t
        end
    end
    if self.pool:IsShown() and self.pool:IsMouseOver() then return { pool = true } end
    return nil
end

function Grid:BeginDrag(chip)
    if not chip.key or not self.opts.isEditable() then return end
    local m = chip.member
    self.dragging = chip.key
    self.picked = nil
    local g = ensureGhost()
    -- the same size and scale as the chip, held where it was grabbed
    g:SetScale(chip:GetEffectiveScale() / UIParent:GetEffectiveScale())
    g:SetSize(chip:GetWidth(), chip:GetHeight())
    local cx, cy = cursorIn(g)
    g.dx, g.dy = (chip:GetLeft() or cx) - cx, (chip:GetTop() or cy) - cy
    UI():ClassIcon(g.cls, m and m.c)
    g.fs:SetText(UI():ColoredName(chip.key, m and m.c))
    local role = m and Comp():RoleOf(m.c, m.sp)
    g.role:SetShown(role ~= nil)
    if role then UI():SetRoleIcon(g.role, role) end
    local grid = self
    g:SetScript("OnUpdate", function(f)
        -- (a drop outside every frame, or a hidden source, ends the drag here)
        if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then return grid:EndDrag() end
        local x, y = cursorIn(f)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x + f.dx, y + f.dy)
        local t = grid:DropTarget()
        local sig = t and ((t.g or "p") .. ":" .. tostring(t.chip or t.box)) or ""
        if sig ~= grid.dropSig then
            grid.dropSig = sig
            grid:ShowDropMarker(t)
        end
    end)
    local x, y = cursorIn(g)
    g:ClearAllPoints()
    g:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x + g.dx, y + g.dy)
    g:Show()
    if GameTooltip then GameTooltip:Hide() end
    self:Refresh()
end

-- The drop: onto a player (swap), an empty seat, a group (its first free seat), the pool; anywhere else puts the
-- player back.
function Grid:EndDrag()
    local key = self.dragging
    if not key then return end
    local t = self:DropTarget()
    self.dragging, self.dropSig = nil, nil
    if ghost then
        ghost:SetScript("OnUpdate", nil)
        ghost:Hide()
    end
    if self.marker then self.marker:Hide() end
    if t and t.g then
        self:Drop(key, t.g, t.target, t.seat)
    elseif t and t.pool then
        self:Drop(key, nil)
    else
        self:Refresh()
    end
end

-- A raid-buff icon for a strip outside the grid (the Teams page's Comp view): GroupsUI:SetBuffIcon(b, entry) fills it
-- from a RaidComp:BuffStates entry (lit / planned / off, with its tooltip).
function GroupsUI:CreateBuffIcon(parent, size) return createBuffIcon(parent, size or 20) end

function GroupsUI:SetBuffIcon(b, entry) setBuffIcon(b, entry, #(entry.providers or {}) > 0) end

if DisasterZoneBoot and DisasterZoneBoot.Run("UI/RaidGroups.lua", ...) then return end -- DisasterZone: UI/RaidGroups.lua
-- The group grid (Addendum J §59-§60): a raid-wide buff strip, group boxes (2 for 10-man, 5 for 25-man) with the party
-- buffs each group has in its header, a "Not in a group" pool, and (opts.waitlist, the Teams page) a waitlist under it.
-- Members are chips (class circle, name, role icon; the spec is in the tooltip), or in the quiet look (opts.quiet, the
-- Teams page) plates with the spec under the name, empty seats being wells. The boxes share the grid's width, three to a row. Organizers move them by dragging, or
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
-- the quiet look (opts.quiet, the Teams page): no frames or swap link; the group's title (its swap button) and the
-- party buffs it gets on one line, then five seats: players as plates, empty seats as wells (the comp's open slots
-- waiting in them as ghosts, opts.getGhosts); the unassigned players and the waitlist as plates on the groups'
-- columns under them (10-man: the unassigned beside the two groups)
local QUIET_BG = { 0.105, 0.105, 0.12, 0.9 }
local PLATE_H, PLATE_GAP = 34, 4
local QUIET_HEAD = 24
local QUIET_BOX_H = QUIET_HEAD + SLOTS * PLATE_H + (SLOTS - 1) * PLATE_GAP

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
-- Plates (the quiet look, and the Teams page's Comp view): a player is a plate like a raid frame (a class tint from
-- the left, a 2px class edge, the spec icon, the name over the spec); an empty seat is a well as big as a plate,
-- sunk into the page; an open comp slot waits in a well as a ghost (its spec icon greyed, the spec, the class and
-- how many could fill it). The look of the Teams v4 mockup (dev/art/casc/teams_mockup/build_v4.py).
---------------------------------------------------------------------------

local PLATE_BASE = { 0.106, 0.106, 0.125 }
local WELL_BASE = { 0.051, 0.051, 0.063 }
local gradA = CreateColor and CreateColor(0, 0, 0, 0)
local gradB = CreateColor and CreateColor(0, 0, 0, 0)

local function gradient(tex, orient, r, g, b, a1, a2)
    if gradA and tex.SetGradient then
        tex:SetColorTexture(1, 1, 1, 1)
        gradA:SetRGBA(r, g, b, a1)
        gradB:SetRGBA(r, g, b, a2)
        tex:SetGradient(orient, gradA, gradB)
    else
        tex:SetColorTexture(r, g, b, (a1 + a2) / 2)
    end
end

local function fontOf(fs, size)
    local path, _, flags = fs:GetFont()
    if path then fs:SetFont(path, size, flags) end
end

-- Adds the plate's textures to a frame (a Button the caller sized); GroupsUI:PaintPlate fills them.
local function decoratePlate(b)
    b.pBase = b:CreateTexture(nil, "BACKGROUND", nil, -2)
    b.pBase:SetAllPoints()
    b.pTint = b:CreateTexture(nil, "BACKGROUND", nil, -1)
    b.pTint:SetAllPoints()
    -- (a well: an inner shadow under its top edge)
    b.pShade = b:CreateTexture(nil, "BACKGROUND", nil, 0)
    b.pShade:SetPoint("TOPLEFT", 0, 0)
    b.pShade:SetPoint("TOPRIGHT", 0, 0)
    b.pShade:SetHeight(4)
    -- (a plate: a light line along the top, a dark one along the bottom)
    b.pTop = b:CreateTexture(nil, "BORDER")
    b.pTop:SetPoint("TOPLEFT", 0, 0)
    b.pTop:SetPoint("TOPRIGHT", 0, 0)
    b.pTop:SetHeight(1)
    b.pTop:SetColorTexture(1, 1, 1, 0.06)
    b.pBot = b:CreateTexture(nil, "BORDER")
    b.pBot:SetPoint("BOTTOMLEFT", 0, 0)
    b.pBot:SetPoint("BOTTOMRIGHT", 0, 0)
    b.pBot:SetHeight(1)
    b.pBot:SetColorTexture(0, 0, 0, 0.5)
    b.pBar = b:CreateTexture(nil, "BORDER", nil, 1)
    b.pBar:SetPoint("TOPLEFT", 0, 0)
    b.pBar:SetPoint("BOTTOMLEFT", 0, 0)
    b.pBar:SetWidth(2)
    b.pIconBg = b:CreateTexture(nil, "ARTWORK", nil, -1)
    b.pIconBg:SetSize(24, 24)
    b.pIconBg:SetPoint("LEFT", b, "LEFT", 6, 0)
    b.pIconBg:SetColorTexture(0, 0, 0, 1)
    b.pIcon = b:CreateTexture(nil, "ARTWORK")
    b.pIcon:SetSize(22, 22)
    b.pIcon:SetPoint("CENTER", b.pIconBg, "CENTER", 0, 0)
    b.pName = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fontOf(b.pName, 12)
    b.pName:SetPoint("BOTTOMLEFT", b.pIconBg, "RIGHT", 7, 0)
    b.pName:SetPoint("RIGHT", b, "RIGHT", -6, 0)
    b.pName:SetJustifyH("LEFT")
    b.pName:SetWordWrap(false)
    b.pSub = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fontOf(b.pSub, 10)
    b.pSub:SetPoint("TOPLEFT", b.pIconBg, "RIGHT", 7, -2)
    b.pSub:SetPoint("RIGHT", b, "RIGHT", -6, 0)
    b.pSub:SetJustifyH("LEFT")
    b.pSub:SetWordWrap(false)
    b.pPlus = b:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    fontOf(b.pPlus, 15)
    b.pPlus:SetPoint("CENTER", 0, 0)
    b.pPlus:SetTextColor(0.26, 0.26, 0.29)
    b.pPlus:SetText("+")
    b.pPlus:Hide()
    UI():AddEdges(b, "OVERLAY")
    b.pLit = b:CreateTexture(nil, "ARTWORK", nil, 2)
    b.pLit:SetAllPoints()
    b.pLit:Hide()
end

-- p = { kind = "player" | "ghost" | "empty", c, sp, name (text, colours included), sub (text), auto (a guessed spec:
-- the spec line fainter), dim, edge = "me" | "picked" | "from" | nil, plus (an empty seat for organizers), hint (the
-- ghost's "· n can fill") }.
local function paintPlate(b, p)
    local kind = p.kind or "empty"
    local player = kind == "player"
    local r, g, bl = UI():ClassColor(p.c)
    local base = player and PLATE_BASE or WELL_BASE
    b.pBase:SetColorTexture(base[1], base[2], base[3], 1)
    b.pTint:SetShown(player)
    if player then gradient(b.pTint, "HORIZONTAL", r, g, bl, 0.20, 0.02) end
    b.pShade:SetShown(not player)
    if not player then gradient(b.pShade, "VERTICAL", 0, 0, 0, 0, 0.85) end
    b.pTop:SetShown(player)
    b.pBot:SetShown(player)
    b.pBar:SetShown(player)
    b.pBar:SetColorTexture(r, g, bl, 0.9)
    local icon = (player or kind == "ghost") and p.c and Comp():SpecIcon(p.c, p.sp) or nil
    local showIcon = player or (kind == "ghost" and icon ~= nil)
    b.pIconBg:SetShown(showIcon)
    b.pIcon:SetShown(showIcon)
    if showIcon then
        if icon then
            b.pIcon:SetTexture(icon)
            b.pIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        else
            UI():ClassIcon(b.pIcon, p.c)
        end
        local ghost = kind == "ghost"
        if b.pIcon.SetDesaturated then b.pIcon:SetDesaturated(ghost) end
        b.pIcon:SetAlpha(ghost and 0.32 or (p.dim and 0.55 or 1))
        b.pIconBg:SetAlpha(ghost and 0.6 or 1)
    end
    b.pName:SetText(p.name or "")
    b.pSub:SetText(p.sub or "")
    -- (a narrow tile, e.g. the Comp view's: a ghost's line too long for it drops the class, the spec takes its colour)
    local room = (b:GetWidth() or 0) - 43
    local short = p.subShort and room > 0 and (b.pSub:GetStringWidth() or 0) > room
    if short then b.pSub:SetText(p.subShort) end
    b.pName:SetAlpha(p.dim and 0.55 or 1)
    if player then b.pSub:SetTextColor(p.auto and 0.42 or 0.56, p.auto and 0.42 or 0.56, p.auto and 0.45 or 0.6)
    else b.pSub:SetTextColor(0.37, 0.37, 0.39) end
    if kind == "ghost" and short then b.pName:SetTextColor(r * 0.6, g * 0.6, bl * 0.6)
    elseif kind == "ghost" then b.pName:SetTextColor(0.49, 0.49, 0.51)
    else b.pName:SetTextColor(1, 1, 1) end
    b.pPlus:SetShown(kind == "empty" and p.plus == true)
    -- the rim: mine / picked / where a dragged player came from; a ghost's in its class colour; a well's faint
    b.pLit:SetShown(p.edge == "picked")
    b.pLit:SetColorTexture(1, 0.82, 0, 0.12)
    if p.edge == "me" then UI():SetEdgeColor(b, 1, 0.82, 0, 0.75)
    elseif p.edge == "picked" then UI():SetEdgeColor(b, 1, 0.82, 0, 0.9)
    elseif p.edge == "from" then UI():SetEdgeColor(b, 1, 0.82, 0, 0.3)
    elseif kind == "ghost" then UI():SetEdgeColor(b, r, g, bl, 0.16)
    elseif kind == "empty" then UI():SetEdgeColor(b, 1, 1, 1, 0.035)
    else UI():SetEdgeColor(b, 0, 0, 0, 0) end
end

-- A player's plate fields from a member { key, c, sp, auto, dim, prefix }.
local function playerPlate(m, edge)
    local label = Comp():SpecLabel(m.c, m.sp)
    return { kind = "player", c = m.c, sp = m.sp, name = (m.prefix or "") .. UI():ColoredName(m.key, m.c),
             sub = label or "Spec unknown", auto = m.auto or label == nil, dim = m.dim, edge = edge }
end

-- An open slot's ghost fields from a slot { c, sp, canFill = n | nil }.
local function ghostPlate(s, edge)
    local cls = Comp():ClassName(s.c) or ""
    -- (the class name in its colour, faded)
    local r, g, b = UI():ClassColor(s.c)
    local faded = ("ff%02x%02x%02x"):format(floor(r * 255 * 0.6 + 0.5), floor(g * 255 * 0.6 + 0.5), floor(b * 255 * 0.6 + 0.5))
    local sub = "|c" .. faded .. cls .. "|r"
    local fill = s.canFill ~= nil and (s.canFill > 0 and ("|cff7e9c84" .. s.canFill .. " can fill|r") or "none yet") or nil
    if fill then sub = sub .. " · " .. fill end
    return { kind = "ghost", c = s.c, sp = s.sp, name = Comp():SpecLabel(s.c, s.sp) or tostring(s.name or "?"),
             sub = sub, subShort = fill, edge = edge }
end

function GroupsUI:DecoratePlate(b) decoratePlate(b) end
function GroupsUI:PaintPlate(b, p) paintPlate(b, p) end
function GroupsUI:PlayerPlate(m, edge) return playerPlate(m, edge) end
function GroupsUI:GhostPlate(s, edge) return ghostPlate(s, edge) end

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
    if grid.opts.quiet then
        chip.seat:ClearAllPoints()
        chip.seat:SetPoint("LEFT", 3, 0)
        chip.seat:SetPoint("RIGHT", -3, 0)
        chip.seat:SetHeight(1)
        chip.seat:SetColorTexture(1, 1, 1, 0.08)
    end
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
    if grid.opts.quiet then
        -- a plate: the spec icon is the spec button; the old chip's parts stay (hidden) for the shared code
        decoratePlate(chip)
        chip.cls:SetAlpha(0)
        chip.spec:SetAlpha(0)
        chip.fs:Hide()
        chip.fs = chip.pName
        chip.seat = chip.pShade
        chip.picked:SetAlpha(0)
        chip.me:SetAlpha(0)
        chip.meBar:SetAlpha(0)
        hl:ClearAllPoints()
        hl:SetPoint("TOPLEFT", 0, 0)
        hl:SetPoint("BOTTOMRIGHT", 0, 0)
        hl:SetColorTexture(1, 1, 1, 0.045)
        rb:ClearAllPoints()
        rb:SetSize(26, 26)
        rb:SetPoint("CENTER", chip.pIconBg, "CENTER", 0, 0)
        rb.unknown:SetAlpha(0)
    end
    chip:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    chip:RegisterForDrag("LeftButton")
    chip:SetScript("OnEnter", function(self)
        local o = self.grid.opts
        if self.key then chipTooltip(self)
        elseif self.ghost and o.ghostTooltip and not self.grid.picked then o.ghostTooltip(self, self.ghost)
        else emptyTooltip(self) end
    end)
    chip:SetScript("OnLeave", hideTooltip)
    chip:SetScript("OnClick", function(self, button) self.grid:OnChipClick(self, button) end)
    chip:SetScript("OnDragStart", function(self) self.grid:BeginDrag(self) end)
    chip:SetScript("OnDragStop", function(self) self.grid:EndDrag(self) end)
    return chip
end

-- ghost (the quiet look, an empty seat): the comp's open slot that waits there; from = the seat a dragged player
-- left. The player being dragged keeps their chip, drawn as the empty spot they left: the game only tells the frame a
-- drag began on that it ended while that frame (and its spec button) is still shown, so it is never hidden mid-drag.
local function setChip(chip, m, ghost, from)
    local holding = m ~= nil and chip.grid.dragging == m.key
    if holding then m, ghost, from = nil, nil, true end
    chip.holding = holding
    chip.roleBtn:SetAlpha(holding and 0 or 1)
    chip.member = m
    chip.key = m and m.key or nil
    chip.ghost = not m and ghost or nil
    local opts = chip.grid.opts
    local editable = opts.isEditable()
    chip.seat:SetShown(m == nil and chip.slot ~= nil and (editable or opts.quiet ~= nil))
    local mine = m ~= nil and not editable and opts.isMe ~= nil and opts.isMe(m.key) and true or false
    chip.me:SetShown(mine)
    chip.meBar:SetShown(mine)
    if opts.quiet then
        local picked = m ~= nil and chip.grid.picked == m.key
        if m then
            paintPlate(chip, playerPlate(m, picked and "picked" or mine and "me" or nil))
        elseif ghost then
            paintPlate(chip, ghostPlate(ghost, from and "from" or nil))
        else
            paintPlate(chip, { kind = "empty", plus = editable and chip.slot ~= nil, edge = from and "from" or nil })
        end
        chip.seat:SetShown(m == nil)
        if not m then
            chip.cls:Hide()
            chip.spec:Hide()
            if not holding then chip.roleBtn:Hide() end
            chip.picked:Hide()
            -- (a ghost's tooltip says who could fill it, for everyone)
            chip:EnableMouse(holding or (chip.slot ~= nil and (editable or ghost ~= nil)))
            return
        end
    end
    if not m then
        chip.cls:Hide()
        chip.spec:Hide()
        if not holding then chip.roleBtn:Hide() end
        chip.fs:SetText("")
        chip.picked:Hide()
        chip:EnableMouse(holding or (chip.slot ~= nil and editable))
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
    if opts.quiet then
        -- (a plate shows the spec icon itself: the chip's class circle and role icon stay hidden)
        chip.cls:Hide()
        chip.spec:Hide()
    end
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
    b.count:SetPoint("BOTTOMRIGHT", 0, 1)
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
--                   onto it. grid.wait is its frame (the caller may put a button in its header).
--          quiet = true (optional: the Teams page's plates and wells, see QUIET_BOX_H),
--          getGhosts(byGroup, n) -> { [g] = { slot, ... } } (optional, quiet: the open slots that wait in each
--                   group's free seats, in seat order; slot = { c, sp, name, canFill }),
--          ghostTooltip(seat, slot) (optional, quiet: hovering a ghost) }
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
        if opts.quiet then
            -- (no panel: the plates and wells make the column; the title on the header line, flush left)
            box.bg:SetColorTexture(0, 0, 0, 0)
            UI():SetEdgeColor(box, 0, 0, 0, 0)
            box.title:SetFontObject("GameFontNormalSmall")
            box.title:SetTextColor(0.66, 0.66, 0.68)
            box.title:SetText("GROUP " .. g)
            box.title:ClearAllPoints()
            box.title:SetPoint("LEFT", box, "TOPLEFT", 1, -10)
        end
        box.countFs = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        box.countFs:SetPoint("TOPRIGHT", -8, -8)
        box.rule = box:CreateTexture(nil, "BORDER")
        box.rule:SetColorTexture(1, 1, 1, 0.07)
        box.rule:SetHeight(1)
        box.rule:SetPoint("TOPLEFT", 6, -HEADER_H + 2)
        box.rule:SetPoint("TOPRIGHT", -6, -HEADER_H + 2)
        if opts.quiet then box.rule:Hide() end
        local swap = CreateFrame("Button", nil, box)
        swap:SetSize(36, 14)
        swap:SetPoint("LEFT", box.title, "RIGHT", 8, 0)
        if opts.quiet then
            -- (the group's header is the swap button; its tooltip lists the party buffs)
            swap:ClearAllPoints()
            swap:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
            swap:SetPoint("BOTTOMRIGHT", box, "TOPRIGHT", 0, -20)
            box.title:SetParent(swap)
            box.countFs:SetParent(swap)
            box.countFs:ClearAllPoints()
            box.countFs:SetPoint("LEFT", box.title, "RIGHT", 8, 0)
        end
        swap.fs = swap:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        swap.fs:SetPoint("CENTER")
        local shl = swap:CreateTexture(nil, "HIGHLIGHT")
        shl:SetAllPoints()
        shl:SetColorTexture(1, 1, 1, 0)
        swap:SetScript("OnClick", function() grid:OnSwapClick(g) end)
        swap:SetScript("OnEnter", function(self)
            if opts.quiet then
                box.title:SetTextColor(1, 0.82, 0)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine("Group " .. g)
                for _, e in ipairs(box.present or {}) do
                    GameTooltip:AddLine(iconText(Comp():BuffIcon(e.buff), 14) .. " " .. e.buff.name, 0.85, 0.85, 0.85)
                end
                if grid.opts.isEditable() and grid.opts.onSwapGroups then
                    GameTooltip:AddLine(grid.swapFrom == g and "Click again to cancel the swap."
                        or grid.swapFrom and ("Click to swap group " .. grid.swapFrom .. " with this one.")
                        or "Click, then another group's title: all their players trade places.", 0.6, 0.6, 0.6, true)
                end
                GameTooltip:Show()
                return
            end
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
            if opts.quiet then
                box.title:SetTextColor(0.69, 0.69, 0.69)
                hideTooltip()
                return
            end
            if not grid.swapFrom then self.fs:SetText("|cff8c8c8cswap|r") end
            hideTooltip()
        end)
        box.swap = swap
        if opts.quiet then
            swap:SetScript("OnClick", function()
                if grid.opts.isEditable() and grid.opts.onSwapGroups then grid:OnSwapClick(g) end
            end)
        end
        box.chips = {}
        for s = 1, SLOTS do
            local chip = createChip(box, grid)
            chip.slot = s
            if opts.quiet then
                chip:SetPoint("TOPLEFT", 0, -QUIET_HEAD - (s - 1) * (PLATE_H + PLATE_GAP))
                chip:SetPoint("RIGHT", box, "RIGHT", 0, 0)
                chip:SetHeight(PLATE_H)
            else
                chip:SetPoint("TOPLEFT", 6, -HEADER_H - 1 - (s - 1) * CHIP_H)
                chip:SetPoint("RIGHT", box, "RIGHT", -6, 0)
                chip:SetHeight(CHIP_H)
            end
            box.chips[s] = chip
        end
        box.buffs = {}
        -- what the party gets from its own members: right to left before the count, or (row layout) in the footer
        for i = 1, 9 do
            local b = createBuffIcon(box, opts.layout == "row" and 16 or 14)
            if opts.quiet then
                -- (the header line's right end, right to left)
                b:SetSize(14, 14)
                if i == 1 then b:SetPoint("RIGHT", box, "TOPRIGHT", 0, -10)
                else b:SetPoint("RIGHT", box.buffs[i - 1], "LEFT", -2, 0) end
            elseif opts.layout == "row" then
                b:SetPoint("BOTTOMLEFT", 8 + (i - 1) * BUFF_ROW, 6)
            elseif i == 1 then
                b:SetPoint("RIGHT", box.countFs, "LEFT", -6, 0)
            else
                b:SetPoint("RIGHT", box.buffs[i - 1], "LEFT", -2, 0)
            end
            b.missingText = "Not in this group."
            -- (above the header's swap button, so each icon keeps its own tooltip)
            if opts.quiet then b:SetFrameLevel(box:GetFrameLevel() + 4) end
            b:Hide()
            box.buffs[i] = b
        end
        if opts.layout == "row" and not opts.quiet then
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
    if opts.quiet then
        pool.bg:SetColorTexture(QUIET_BG[1], QUIET_BG[2], QUIET_BG[3], QUIET_BG[4])
        UI():SetEdgeColor(pool, 0, 0, 0, 0)
    end
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
        if opts.quiet then
            w.bg:SetColorTexture(QUIET_BG[1], QUIET_BG[2], QUIET_BG[3], QUIET_BG[4])
            UI():SetEdgeColor(w, 0, 0, 0, 0)
        end
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
    -- (a drag whose card is no longer up has ended: the player comes back)
    if self.dragging and not (self.dragCard and self.dragCard:IsShown()) then
        self.dragging, self.dragFrom, self.dragCard = nil, nil, nil
    end
    -- (the dragged player stays in the layout: setChip draws their chip as the spot they left)
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
    -- (on the caller's row: as large as the room left there allows, 20 (quiet: 18) down to 14)
    local size = self.opts.quiet and 18 or 20
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
    local quiet = self.opts.quiet ~= nil
    if quiet then boxH = QUIET_BOX_H end
    -- (the quiet look) the comp's open slots, as ghosts in the free seats: worked out from the groups as they are,
    -- and kept while a player is dragged (the seat they left stays theirs until the drop)
    if quiet and not self.dragging then
        self.ghosts = self.opts.getGhosts and self.opts.getGhosts(byGroup, n) or nil
    end
    local ghosts = quiet and self.ghosts or nil
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
            local gl, gi = ghosts and ghosts[g] or nil, 0
            local from = self.dragging and self.dragFrom
            for s, chip in ipairs(box.chips) do
                local gh
                if not bySeat[s] and gl then
                    gi = gi + 1
                    gh = gl[gi]
                end
                setChip(chip, bySeat[s], gh, from and from.g == g and from.s == s)
            end
            box.countFs:SetText(#list .. "/" .. SLOTS)
            -- (a group without players has nothing to swap; while a swap is picked every group takes it)
            local canSwap = self.opts.isEditable() and self.opts.onSwapGroups ~= nil
            box.swap:SetShown(self.opts.quiet ~= nil or (canSwap and (#list > 0 or self.swapFrom ~= nil)))
            if self.opts.quiet then
                box.swap.fs:SetText("")
                -- (the seats show how full it is: the line only says a swap is under way)
                box.countFs:SetText(self.swapFrom == g and "|cff33ff33SWAPPING|r" or "")
            elseif self.swapFrom == g then
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
            box.present = present
            -- (the footer holds as many as its width does; the tooltip of each names who brings it)
            local room = quiet and floor((bw - 64) / 16) or row_ and floor((bw - 16 + 2) / BUFF_ROW) or #box.buffs
            for i, b in ipairs(box.buffs) do
                if present[i] and i <= room then setBuffIcon(b, present[i], true) else b:Hide() end
            end
            if self.swapFrom == g then UI():SetEdgeColor(box, 0.2, 1, 0.2, 0.9)
            elseif self.picked or self.swapFrom then UI():SetEdgeColor(box, 1, 0.82, 0, 0.75)
            elseif self.opts.quiet then UI():SetEdgeColor(box, 0, 0, 0, 0)
            else UI():SetEdgeColor(box, 0.34, 0.34, 0.38, 0.5) end
        end
    end

    tsort(pool, memberLess)
    self.pool.label:SetText((self.opts.poolLabel or "Not in a group") .. " (" .. #pool .. ")")
    if self.opts.quiet then
        self:LayoutBench(pool, waiting, n, boxH)
        return
    end
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

-- The quiet look's bench: the unassigned players as plates on the groups' columns under them (a 10-man lineup: in the
-- free columns beside its two groups, on a faint panel), a small caps header over them and "Drag into a group" on
-- its right; the waitlist the same way under everything while anyone is on it (or opts.waitlist.empty() says
-- something). Nobody there: a well across the width that says what it is for.
local function benchWell(host)
    if host.drop then return host.drop end
    local d = CreateFrame("Frame", nil, host)
    decoratePlate(d)
    paintPlate(d, { kind = "empty" })
    d.fs = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fontOf(d.fs, 11)
    d.fs:SetPoint("LEFT", d, "LEFT", 12, 0)
    d.fs:SetPoint("RIGHT", d, "RIGHT", -12, 0)
    d.fs:SetJustifyH("CENTER")
    d.fs:SetWordWrap(false)
    d:EnableMouse(false)
    host.drop = d
    return d
end

-- host's plates: `list` on `cols` columns, column c at colX(c) and colW(c) wide, from y0 down; returns their height.
local function platesOn(self, host, list, cols, colX, colW, y0)
    for i, m in ipairs(list) do
        local chip = host.chips[i]
        if not chip then
            chip = createChip(host, self)
            host.chips[i] = chip
        end
        local c, r = (i - 1) % cols, floor((i - 1) / cols)
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", host, "TOPLEFT", colX(c), -(y0 + r * (PLATE_H + PLATE_GAP)))
        chip:SetSize(colW(c), PLATE_H)
        chip:Show()
        setChip(chip, m)
    end
    for i = #list + 1, #host.chips do
        host.chips[i]:Hide()
        host.chips[i].member, host.chips[i].key = nil, nil
    end
    local rows = ceil(#list / cols)
    return rows > 0 and (rows * (PLATE_H + PLATE_GAP) - PLATE_GAP) or 0
end

-- One bench block (the unassigned or the waitlist) at (x, y), w wide: its header, then its plates or the well with
-- `emptyText`; pad = the inset (a panel beside the groups) or 0. Returns its height.
local function benchBlock(self, host, list, label, hint, emptyText, x, y, w, cols, pad, y0)
    host.label:SetFontObject("GameFontNormalSmall")
    host.label:SetTextColor(0.66, 0.66, 0.68)
    host.label:SetText(label .. "  |cff8c8c8c" .. #list .. "|r")
    host.label:ClearAllPoints()
    host.label:SetPoint("LEFT", host, "TOPLEFT", pad + 1, -(pad + 9))
    local iw = w - 2 * pad
    local cw = (iw - (cols - 1) * ROW_GAP) / cols
    local colX = self.colX
    local function cx(c)
        if pad == 0 and colX then return colX(c) end
        return pad + floor(c * (cw + ROW_GAP) + 0.5)
    end
    local function cwOf(c)
        if pad == 0 and colX then return colX(c + 1) - ROW_GAP - colX(c) end
        return cx(c + 1) - ROW_GAP - cx(c)
    end
    local hgt = platesOn(self, host, list, cols, cx, cwOf, pad + y0)
    local d = benchWell(host)
    d:SetShown(#list == 0 and emptyText ~= nil)
    if #list == 0 and emptyText then
        d:ClearAllPoints()
        d:SetPoint("TOPLEFT", host, "TOPLEFT", pad, -(pad + y0))
        d:SetSize(iw, PLATE_H)
        d.fs:SetText(emptyText)
        hgt = PLATE_H
    end
    host.empty:ClearAllPoints()
    host.empty:SetPoint("RIGHT", host, "TOPRIGHT", -pad - 1, -(pad + 9))
    host.empty:SetJustifyH("RIGHT")
    host.empty:SetText(hint or "")
    host.empty:SetShown(hint ~= nil and #list > 0)
    host:ClearAllPoints()
    host:SetPoint("TOPLEFT", self.frame, "TOPLEFT", x, -y)
    local h = pad + y0 + hgt + pad
    host:SetSize(w, h)
    return h
end

function Grid:LayoutBench(pool, waiting, n, boxH)
    local fw = self.frame:GetWidth() or 0
    if fw < 100 then fw = ROW_COLS * (BOX_W + ROW_GAP) - ROW_GAP end
    local editable = self.opts.isEditable()
    local x = self.colX
    local p = self.pool
    local beside = n < ROW_COLS
    local boxesBottom = self.top + ceil(n / ROW_COLS) * (boxH + ROW_GAP) - ROW_GAP
    local label = (self.opts.poolLabel or "Not in a group"):upper()
    local emptyText = self.opts.poolEmpty and self.opts.poolEmpty() or "Drop a player here to take them out of the groups."
    local show = #pool > 0 or editable
    p:SetShown(show)
    -- (beside the groups: a faint panel; under them: no panel, the plates line up with the groups)
    if beside then
        p.bg:SetColorTexture(1, 1, 1, 0.02)
        UI():SetEdgeColor(p, 1, 1, 1, 0.035)
    else
        p.bg:SetColorTexture(0, 0, 0, 0)
        UI():SetEdgeColor(p, 0, 0, 0, 0)
    end
    self.height = boxesBottom
    if show then
        if beside then
            local px = x(n)
            local h = benchBlock(self, p, pool, label, editable and "Drag into a group" or nil,
                editable and emptyText or nil, px, self.top, x(ROW_COLS) - ROW_GAP - px, ROW_COLS - n, 8, 18)
            if h < boxH then
                p:SetHeight(boxH)
                h = boxH
            end
            self.height = max(boxesBottom, self.top + h)
        else
            local top = boxesBottom + 16
            local h = benchBlock(self, p, pool, label, editable and "Drag into a group" or nil,
                editable and emptyText or nil, 0, top, fw, ROW_COLS, 0, 20)
            self.height = top + h
        end
    end
    local w = self.wait
    if w then
        local wo = self.opts.waitlist
        local empty = wo.empty and wo.empty() or nil
        local wshow = #waiting > 0 or empty ~= nil
        w:SetShown(wshow)
        w.bg:SetColorTexture(0, 0, 0, 0)
        UI():SetEdgeColor(w, 0, 0, 0, 0)
        if not wshow then
            for _, chip in ipairs(w.chips) do
                chip:Hide()
                chip.member, chip.key = nil, nil
            end
        else
            local top = self.height + 16
            -- (a taller header: the caller's Join / Leave button sits on its right)
            local h = benchBlock(self, w, waiting, (wo.label or "Waitlist"):upper(), nil, empty, 0, top, fw, ROW_COLS, 0, 26)
            self.height = top + h
        end
    end
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

-- (the quiet look) the lifted plate: the player's plate, a gold rim and a deep shadow, with a small label under it that
-- says where it would land
local plateGhost
local function ensurePlateGhost()
    if plateGhost then return plateGhost end
    local g = CreateFrame("Frame", nil, UIParent)
    g:SetSize(140, PLATE_H)
    g:SetFrameStrata("TOOLTIP")
    -- (the shadow: two soft layers under the plate, offset down)
    g.sh1 = g:CreateTexture(nil, "BACKGROUND", nil, -7)
    g.sh1:SetPoint("TOPLEFT", -4, -2)
    g.sh1:SetPoint("BOTTOMRIGHT", 5, -10)
    g.sh1:SetColorTexture(0, 0, 0, 0.35)
    g.sh2 = g:CreateTexture(nil, "BACKGROUND", nil, -6)
    g.sh2:SetPoint("TOPLEFT", -1, 0)
    g.sh2:SetPoint("BOTTOMRIGHT", 2, -4)
    g.sh2:SetColorTexture(0, 0, 0, 0.45)
    decoratePlate(g)
    g.tip = CreateFrame("Frame", nil, g)
    g.tip:SetPoint("TOPLEFT", g, "BOTTOMLEFT", 8, -6)
    g.tip:SetSize(10, 18)
    g.tip.bg = g.tip:CreateTexture(nil, "BACKGROUND")
    g.tip.bg:SetAllPoints()
    g.tip.bg:SetColorTexture(0.03, 0.03, 0.04, 0.94)
    UI():AddEdges(g.tip, "BORDER")
    UI():SetEdgeColor(g.tip, 1, 1, 1, 0.12)
    g.tip.fs = g.tip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fontOf(g.tip.fs, 11)
    g.tip.fs:SetPoint("TOPLEFT", 8, -5)
    g.tip.fs:SetJustifyH("LEFT")
    g.tip.fs:SetSpacing(2)
    g.tip:Hide()
    g:Hide()
    plateGhost = g
    GroupsUI.__plateGhost = g          -- (for the tests)
    return g
end

-- The lifted plate's label: where a drop at `t` lands (nil: hidden).
-- The lifted plate's label (nil: hidden).
local function setLiftTip(text)
    local g = plateGhost
    if not g then return end
    g.tip:SetShown(text ~= nil)
    if text then
        g.tip.fs:SetText(text)
        g.tip:SetSize(floor((g.tip.fs:GetStringWidth() or 100) + 16 + 0.5), floor((g.tip.fs:GetStringHeight() or 12) + 10 + 0.5))
    end
end

local function plateGhostTip(grid, t)
    local g = plateGhost
    if not g then return end
    local text
    if t and t.full then
        text = "|cffff6060Group " .. t.g .. " is full|r"
    elseif t and t.target then
        text = "Swap with " .. UI():ColoredName(t.target, t.chip and t.chip.member and t.chip.member.c)
    elseif t and t.g then
        text = "Group " .. t.g .. ", seat " .. tostring(t.seat or "?")
        local gh = t.chip and t.chip.ghost
        if gh then text = text .. "\n|cff9e9e9eplanned: " .. tostring(Comp():SlotName(gh.c, gh.sp) or gh.name or "?") .. "|r" end
    elseif t and t.pool then
        text = "Out of the groups"
    end
    setLiftTip(text)
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
    if self.opts.quiet then plateGhostTip(self, t) end
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
        m.fill:SetColorTexture(1, 0.82, 0, t.chip and (self.opts.quiet and 0.1 or 0.14) or 0.05)
        UI():SetEdgeColor(m, 1, 0.82, 0, 0.85)
    end
    m:Show()
end

-- What the cursor is over while dragging: { g, box, chip (the seat or player lit), target (swap), seat, full } or
-- { pool = true }, or nil.
function Grid:DropTarget(key)
    key = key or self.dragging
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

-- The lifted card for chip: the plate look (quiet) or the chip look; returns the frame, ready but not shown.
local function liftCard(grid, chip, quiet)
    local m = chip.member
    local g = quiet and ensurePlateGhost() or ensureGhost()
    -- the same size and scale as the chip, held where it was grabbed
    g:SetScale(chip:GetEffectiveScale() / UIParent:GetEffectiveScale())
    g:SetSize(chip:GetWidth(), chip:GetHeight())
    local cx, cy = cursorIn(g)
    g.dx, g.dy = (chip:GetLeft() or cx) - cx, (chip:GetTop() or cy) - cy
    if quiet then
        paintPlate(g, playerPlate(m or { key = chip.key }))
        g.pBase:SetColorTexture(0.137, 0.137, 0.16, 1)
        UI():SetEdgeColor(g, 1, 0.82, 0, 0.9)
        g.tip:Hide()
    else
        UI():ClassIcon(g.cls, m and m.c)
        g.fs:SetText(UI():ColoredName(chip.key, m and m.c))
        local role = m and Comp():RoleOf(m.c, m.sp)
        g.role:SetShown(role ~= nil)
        if role then UI():SetRoleIcon(g.role, role) end
    end
    return g
end

-- A player picked up: the lifted card follows the cursor (its OnUpdate also ends the drag when the button is up,
-- since the frame the drag began on may be hidden by then), the player leaves the layout until the drop. The drag
-- only counts once the card is up: a failure on the way never leaves a player out of the layout.
function Grid:BeginDrag(chip)
    if not chip.key or not self.opts.isEditable() or self.dragging then return end
    local key = chip.key
    local quiet = self.opts.quiet ~= nil
    local ok, g = pcall(liftCard, self, chip, quiet)
    if not ok then
        -- (said once in BugSack; the chip look still works)
        local handler = geterrorhandler and geterrorhandler()
        if handler then handler(g) end
        if not quiet then return end
        ok, g = pcall(liftCard, self, chip, false)
        if not ok then return end
    end
    local grid = self
    g:SetScript("OnUpdate", function(f)
        if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then return grid:EndDrag() end
        local x, y = cursorIn(f)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x + f.dx, y + f.dy)
        local t = grid:DropTarget(key)
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
    -- (the seat it leaves: lit faintly until the drop)
    local from = groupOfChip(chip)
    self.dragFrom = from and { g = from, s = chip.slot } or nil
    self.dragging, self.dragCard, self.picked = key, g, nil
    if GameTooltip then GameTooltip:Hide() end
    self:Refresh()
end

-- The drop: onto a player (swap), an empty seat, a group (its first free seat), the pool; anywhere else puts the
-- player back. The drag is over first, whatever happens next.
function Grid:EndDrag()
    local key = self.dragging
    if not key then return end
    local ok, t = pcall(self.DropTarget, self, key)
    self.dragging, self.dropSig, self.dragFrom, self.dragCard = nil, nil, nil, nil
    for _, gf in ipairs({ ghost or false, plateGhost or false }) do
        if gf then
            gf:SetScript("OnUpdate", nil)
            gf:Hide()
        end
    end
    if self.marker then self.marker:Hide() end
    if not ok then t = nil end
    if t and t.g then
        self:Drop(key, t.g, t.target, t.seat)
    elseif t and t.pool then
        self:Drop(key, nil)
    else
        self:Refresh()
    end
end

---------------------------------------------------------------------------
-- Card drags outside the grid (the Teams page's Comp view): the same lifted plate and label, the spot under the
-- cursor lit gold (a drop does something) or red (it can't land there). The caller decides what is under the
-- cursor and what a drop does; nothing is re-laid out during the drag, so the frame it began on stays shown (only
-- that frame hears OnDragStop: call GroupsUI:EndCardDrag() from it; the lifted plate also ends it when the button
-- is up).
---------------------------------------------------------------------------

local cardDrag, cardMarker

local function cardMark(t)
    local m = cardMarker
    if not m then
        m = CreateFrame("Frame", nil, UIParent)
        m.fill = m:CreateTexture(nil, "OVERLAY")
        m.fill:SetAllPoints()
        UI():AddEdges(m, "OVERLAY")
        m:EnableMouse(false)
        cardMarker = m
    end
    local f = t and t.frame
    if not f then
        m:Hide()
        return
    end
    m:SetParent(f)
    m:ClearAllPoints()
    m:SetAllPoints(f)
    m:SetFrameLevel(f:GetFrameLevel() + 5)
    if t.ok then
        m.fill:SetColorTexture(1, 0.82, 0, 0.1)
        UI():SetEdgeColor(m, 1, 0.82, 0, 0.85)
    else
        m.fill:SetColorTexture(1, 0.25, 0.25, 0.06)
        UI():SetEdgeColor(m, 1, 0.3, 0.3, 0.8)
    end
    m:Show()
end

-- src = the frame the drag began on (dimmed until the drop), plate = its PaintPlate fields; opts = { target() ->
-- { frame, ok, label, ... } | nil (asked every frame), drop(t) (a release over an ok target), finish() (after
-- every drag, dropped or not) }. Returns true when the drag began.
function GroupsUI:StartCardDrag(src, plate, opts)
    if cardDrag then return false end
    local ok, g = pcall(function()
        local f = ensurePlateGhost()
        f:SetScale(src:GetEffectiveScale() / UIParent:GetEffectiveScale())
        f:SetSize(src:GetWidth(), src:GetHeight())
        local cx, cy = cursorIn(f)
        f.dx, f.dy = (src:GetLeft() or cx) - cx, (src:GetTop() or cy) - cy
        paintPlate(f, plate)
        f.pBase:SetColorTexture(0.137, 0.137, 0.16, 1)
        UI():SetEdgeColor(f, 1, 0.82, 0, 0.9)
        f.tip:Hide()
        return f
    end)
    if not ok then
        local handler = geterrorhandler and geterrorhandler()
        if handler then handler(g) end
        return false
    end
    cardDrag = { src = src, opts = opts }
    src:SetAlpha(0.35)
    g:SetScript("OnUpdate", function(f)
        if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then return GroupsUI:EndCardDrag() end
        local x, y = cursorIn(f)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x + f.dx, y + f.dy)
        local d = cardDrag
        if not d then return end
        local t = d.opts.target()
        local sig = t and (tostring(t.frame) .. ":" .. tostring(t.ok) .. ":" .. tostring(t.label)) or ""
        if sig ~= d.sig then
            d.sig = sig
            cardMark(t)
            setLiftTip(t and t.label or nil)
        end
    end)
    local x, y = cursorIn(g)
    g:ClearAllPoints()
    g:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x + g.dx, y + g.dy)
    g:Show()
    if GameTooltip then GameTooltip:Hide() end
    return true
end

function GroupsUI:EndCardDrag()
    local d = cardDrag
    if not d then return end
    cardDrag = nil
    local ok, t = pcall(d.opts.target)
    if plateGhost then
        plateGhost:SetScript("OnUpdate", nil)
        plateGhost:Hide()
    end
    if cardMarker then cardMarker:Hide() end
    d.src:SetAlpha(1)
    if ok and t and t.ok and d.opts.drop then d.opts.drop(t) end
    if d.opts.finish then d.opts.finish() end
end

function GroupsUI:IsCardDragging() return cardDrag ~= nil end

-- A raid-buff icon for a strip outside the grid (the Teams page's Comp view): GroupsUI:SetBuffIcon(b, entry) fills it
-- from a RaidComp:BuffStates entry (lit / planned / off, with its tooltip).
function GroupsUI:CreateBuffIcon(parent, size) return createBuffIcon(parent, size or 20) end

function GroupsUI:SetBuffIcon(b, entry) setBuffIcon(b, entry, #(entry.providers or {}) > 0) end

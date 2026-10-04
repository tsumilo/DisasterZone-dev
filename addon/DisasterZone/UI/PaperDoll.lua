if DisasterZoneBoot and DisasterZoneBoot.Run("UI/PaperDoll.lua", ...) then return end -- DisasterZone UI/PaperDoll.lua
-- ns.PaperDoll: reusable 17-slot paper-doll layout (left / right columns + weapon row) showing a
-- BiS list for one phase. Editable (My BiS) or read-only (Council member view). Slots the player disabled
-- (ADDENDUM F §36, ListData dx) are greyed; while the group's BiS lists are locked (§38) an editable doll
-- shows the lock in its tooltips (SetLocked).
local addonName, ns = ...

local PaperDoll = {}
ns.PaperDoll = PaperDoll

-- Layout (fits a ~774 x 430 area): side tiles 260 x 42 on a 46px pitch, so the longest raid item names
-- (36 letters) fit on one line; the weapon row's three tiles span the same width as the two columns.
local TILE_W, TILE_H, PITCH = 260, 42, 46
local BOTTOM_W, BOTTOM_GAP_X = 246, 10
local MAIN_SIZE, ALT_SIZE, WEAR_SIZE = 36, 22, 14
local TEXT_X = 66
local SIDE_X, TOP_Y = 8, -4
local BOTTOM_GAP, CENTER_GAP = 8, 10

local DEFAULT_LEFT = { 1, 2, 3, 4, 5, 6 }
local DEFAULT_RIGHT = { 7, 8, 9, 10, 11, 12, 13, 14 }
local DEFAULT_BOTTOM = { 15, 16, 17 }

local SID_MAINHAND, SID_OFFHAND = 15, 16

local liveDolls = setmetatable({}, { __mode = "k" })

local Doll = {}

local function SlotLabel(sid)
    local s = ns.SLOTS and ns.SLOTS[sid]
    return s and s.label or ("Slot " .. tostring(sid))
end

local function ValidID(v)
    v = tonumber(v)
    if v and v > 0 and v == math.floor(v) then return v end
    return nil
end

local function SlotEntry(ph, sid)
    local e = ph and ph[sid]
    if type(e) ~= "table" then return nil, nil end
    return ValidID(e[1]), ValidID(e[2])
end

local function Grey(text) return "|cff808080" .. text .. "|r" end

local function ColorKey(key, text)
    return ns.UI:Colorize(text, ns.COLORS and ns.COLORS[key])
end

local function EquipLoc(itemID)
    if not itemID then return nil end
    if ns.ItemDB and ns.ItemDB.GetEquipLoc then return ns.ItemDB:GetEquipLoc(itemID) end
    if C_Item and C_Item.GetItemInfoInstant then
        local _, _, _, loc = C_Item.GetItemInfoInstant(itemID)
        return loc
    end
    return nil
end

local function SourceText(itemID)
    if ns.ItemDB and ns.ItemDB.GetSourceText then
        return ns.ItemDB:GetSourceText(itemID, true)
    end
    return nil
end

local DISABLED_TEXT = "Disabled \226\128\148 not needed"

-- §36: the player disabled this slot for the phase (Store:IsSlotDisabled, else ListData dx directly).
local function SlotDisabled(record, phase, sid)
    local S = ns.Store
    if type(S) == "table" and type(S.IsSlotDisabled) == "function" then
        return S:IsSlotDisabled(record, phase, sid) and true or false
    end
    local data = type(record) == "table" and type(record.data) == "table" and record.data or nil
    local dx = data and type(data.dx) == "table" and data.dx[phase]
    return type(dx) == "table" and dx[sid] == true
end
PaperDoll.IsSlotDisabled = function(_, record, phase, sid) return SlotDisabled(record, phase, sid) end

local function LockHint(tt)
    tt:AddLine((ns.UI.LockIcon and (ns.UI:LockIcon(12) .. " ") or "") .. "BiS lists are locked during the raid",
        1, 0.55, 0.2)
end

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------

local function StateLine(tt, state, awarded)
    local labels = ns.UI.OBTAINED_LABELS
    local r, g, b = ns.UI:Color("obtained")
    if state then
        tt:AddLine(labels[state] or "Obtained", r, g, b)
    elseif awarded then
        tt:AddLine("Awarded", r, g, b)
    end
end

local function DisabledTooltip(doll, tile, tt)
    local label = SlotLabel(tile.sid)
    if tile.mainID then tt:AddLine(" ") end
    tt:AddLine(label .. (doll.phase and (" (P" .. doll.phase .. ")") or "") .. " \226\128\148 disabled", 0.75, 0.75, 0.75)
    if doll.readOnly then
        tt:AddLine("Disabled by player: not needed, not counted and no drop alerts.", 0.6, 0.6, 0.6, true)
    else
        tt:AddLine("Not needed: left out of your progress, the council's need counts and drop alerts.",
            0.6, 0.6, 0.6, true)
    end
    if tile.mainID then tt:AddLine("The pick is kept for when you enable the slot again.", 0.5, 0.5, 0.5, true) end
    if not doll.readOnly then
        if doll.locked then LockHint(tt) end
        tt:AddLine("Click: Enable slot", 0.5, 0.5, 0.5)
    end
end

local function MainTooltip(doll, tile, tt)
    local label = SlotLabel(tile.sid)
    local editable = not doll.readOnly
    if tile.disabled then
        DisabledTooltip(doll, tile, tt)
        return
    end
    if tile.mainID then
        tt:AddLine(" ")
        local r, g, b = ns.UI:Color("main")
        tt:AddLine("DisasterZone: main BiS - " .. label .. (doll.phase and (" (P" .. doll.phase .. ")") or ""), r, g, b)
        if tile.mainState or tile.mainAwarded then
            StateLine(tt, tile.mainState, tile.mainAwarded)
        else
            local src = SourceText(tile.mainID)
            tt:AddLine(src or "Not from a raid boss", 0.7, 0.7, 0.7, true)
        end
        if tile.twoHandBlocked then
            tt:AddLine("Two-hander equipped in main hand", 1, 0.55, 0.2)
        end
        if editable and doll.locked then
            LockHint(tt)
            tt:AddLine("Right-click for options", 0.5, 0.5, 0.5)
        elseif editable then
            tt:AddLine("Click to change  ·  Right-click for options", 0.5, 0.5, 0.5)
        end
    else
        tt:AddLine(label, 1, 1, 1)
        if tile.twoHandBlocked then
            tt:AddLine("Two-hander equipped in main hand", 1, 0.55, 0.2)
        end
        if editable and doll.locked then
            LockHint(tt)
        elseif editable then
            tt:AddLine("Click to choose your best-in-slot item.", 0.8, 0.8, 0.8, true)
            tt:AddLine("Drag an item from your bags here to use any other item.", 0.5, 0.5, 0.5, true)
            tt:AddLine("Right-click for options (disable a slot you don't need)", 0.5, 0.5, 0.5, true)
        else
            tt:AddLine("No item chosen", 0.5, 0.5, 0.5)
        end
    end
end

local function AltTooltip(doll, tile, tt)
    local label = SlotLabel(tile.sid)
    if tile.disabled then
        DisabledTooltip(doll, tile, tt)
        return
    end
    if tile.altID then
        tt:AddLine(" ")
        local r, g, b = ns.UI:Color("alt")
        tt:AddLine("DisasterZone: alt pick - " .. label, r, g, b)
        StateLine(tt, tile.altState, tile.altAwarded)
        if not doll.readOnly and doll.locked then
            LockHint(tt)
        elseif not doll.readOnly then
            tt:AddLine("Click to change  ·  Right-click for options", 0.5, 0.5, 0.5)
        end
    else
        tt:AddLine("Alt pick - " .. label, 1, 1, 1)
        tt:AddLine("Add a backup or upgrade-path item for this slot.", 0.8, 0.8, 0.8, true)
    end
end

---------------------------------------------------------------------------
-- Tiles
---------------------------------------------------------------------------

local function HandleClick(doll, tile, which, mouseButton)
    if doll.readOnly then return end
    local cb = doll.opts.onSlotClick
    if cb then cb(tile.sid, which, mouseButton, tile) end
end

local function HandleDrop(doll, tile, itemID, which)
    if doll.readOnly then return end
    local cb = doll.opts.onSlotReceiveItem
    if cb then cb(tile.sid, itemID, which) end
end

local function CreateTile(doll, sid, side, width)
    local UI = ns.UI
    local tile = CreateFrame("Button", nil, doll)
    tile:SetSize(width, TILE_H)
    tile.sid = sid
    tile.side = side
    tile:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    tile:SetHighlightTexture(UI:Tex("rowHilight"), "ADD")
    local hl = tile:GetHighlightTexture()
    if hl then hl:SetAlpha(0.35) end

    -- gold border while this slot is being edited (SetHighlight)
    tile.editBorder = CreateFrame("Frame", nil, tile, "BackdropTemplate")
    tile.editBorder:SetPoint("TOPLEFT", tile, "TOPLEFT", -4, 2)
    tile.editBorder:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", 4, -3)
    tile.editBorder:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
    tile.editBorder:SetBackdropBorderColor(1, 0.82, 0, 1)
    tile.editBorder:Hide()

    tile.main = UI:CreateItemButton(tile, MAIN_SIZE)
    tile.alt = UI:CreateItemButton(tile, ALT_SIZE)
    tile.alt.badge:ClearAllPoints()
    tile.alt.badge:SetPoint("CENTER", tile.alt, "CENTER", 0, 0)
    tile.wear = UI:CreateItemButton(tile, WEAR_SIZE)
    tile.wear:Hide()

    tile.line1 = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tile.line2 = tile:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    for _, fs in ipairs({ tile.line1, tile.line2 }) do
        fs:SetWidth(width - TEXT_X)
        fs:SetHeight(14)
        fs:SetWordWrap(false)
    end

    if side == "R" then
        tile.main:SetPoint("TOPRIGHT", tile, "TOPRIGHT", 0, -3)
        tile.alt:SetPoint("BOTTOMRIGHT", tile.main, "BOTTOMLEFT", -3, -3)
        tile.wear:SetPoint("TOPRIGHT", tile.main, "TOPLEFT", -3, 0)
        tile.line1:SetPoint("TOPRIGHT", tile, "TOPRIGHT", -TEXT_X, -5)
        tile.line2:SetPoint("TOPRIGHT", tile, "TOPRIGHT", -TEXT_X, -21)
        tile.line1:SetJustifyH("RIGHT")
        tile.line2:SetJustifyH("RIGHT")
    else
        tile.main:SetPoint("TOPLEFT", tile, "TOPLEFT", 0, -3)
        tile.alt:SetPoint("BOTTOMLEFT", tile.main, "BOTTOMRIGHT", 3, -3)
        tile.wear:SetPoint("TOPLEFT", tile.main, "TOPRIGHT", 3, 0)
        tile.line1:SetPoint("TOPLEFT", tile, "TOPLEFT", TEXT_X, -5)
        tile.line2:SetPoint("TOPLEFT", tile, "TOPLEFT", TEXT_X, -21)
        tile.line1:SetJustifyH("LEFT")
        tile.line2:SetJustifyH("LEFT")
    end

    tile.main.onClick = function(_, mouseButton) HandleClick(doll, tile, "main", mouseButton) end
    tile.alt.onClick = function(_, mouseButton) HandleClick(doll, tile, "alt", mouseButton) end
    tile.main.onReceiveItem = function(_, itemID) HandleDrop(doll, tile, itemID, "main") end
    tile.alt.onReceiveItem = function(_, itemID) HandleDrop(doll, tile, itemID, "alt") end
    tile.main.onTooltip = function(_, tt) MainTooltip(doll, tile, tt) end
    tile.alt.onTooltip = function(_, tt) AltTooltip(doll, tile, tt) end
    tile.wear.onTooltip = function(_, tt)
        tt:AddLine(" ")
        tt:AddLine("Currently wearing (" .. SlotLabel(tile.sid) .. ")", 0.7, 0.7, 0.7)
    end

    -- the text area acts like the main button
    tile:SetScript("OnClick", function(self, mouseButton)
        if self.__cdlDropTime and self.__cdlDropTime == GetTime() then return end
        if self.mainID and UI:HandleModifiedItemClick(self.mainID) then return end
        HandleClick(doll, self, "main", mouseButton)
    end)
    tile:SetScript("OnEnter", function(self)
        UI:SetItemTooltip(self, self.mainID, function(tt) MainTooltip(doll, self, tt) end)
    end)
    tile:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UI:AttachItemDrop(tile, function(self, itemID) HandleDrop(doll, self, itemID, "main") end)

    return tile
end

---------------------------------------------------------------------------
-- Painting
---------------------------------------------------------------------------

local function ApplyButtonState(button, state, awarded)
    if state == "equipped" then
        button:SetState("equipped")
    elseif state then
        button:SetState("obtained")
    elseif awarded then
        button:SetState("awarded")
    end
end

local function Desaturate(button)
    local icon = button and button.icon
    if not icon then return end
    if icon.SetDesaturation then icon:SetDesaturation(1) else icon:SetDesaturated(true) end
end

-- §36: a disabled slot is greyed (desaturated slot texture), labelled "Disabled — not needed"; its picks
-- are kept but dimmed.
local function PaintDisabledTile(doll, tile, main, alt)
    local UI = ns.UI
    local sid = tile.sid
    tile.mainID, tile.altID = main, alt
    tile.twoHandBlocked = nil
    tile.mainState, tile.mainAwarded, tile.altState, tile.altAwarded = nil, nil, nil, nil
    tile.main:SetItem(main, UI:EmptySlotTexture(sid))
    tile.main:SetState("dim")
    Desaturate(tile.main)
    tile.line1:SetText(Grey(DISABLED_TEXT))
    tile.line2:SetText(Grey(SlotLabel(sid) .. (main and "  ·  pick kept" or "")))
    if alt then
        tile.alt:SetItem(alt)
        tile.alt:SetBadge(nil)
        tile.alt:SetState("dim")
        Desaturate(tile.alt)
        tile.alt:Show()
    else
        tile.alt:SetItem(nil)
        tile.alt:SetBadge(nil)
        tile.alt:Hide()
    end
    tile.wear:SetItem(nil)
    tile.wear:Hide()
    tile:SetAlpha(0.8)
    return false
end

-- Returns true when some item name is still loading.
local function PaintTile(doll, tile, main, alt, ctx, eqID, twoHandBlocked, disabled)
    local UI = ns.UI
    local sid = tile.sid
    local label = SlotLabel(sid)
    local editable = not doll.readOnly
    local locked = editable and doll.locked
    local pending = false

    tile.disabled = disabled and true or nil
    if disabled then return PaintDisabledTile(doll, tile, main, alt) end
    tile.mainID, tile.altID = main, alt
    tile.twoHandBlocked = twoHandBlocked or nil
    tile.mainState, tile.mainAwarded, tile.altState, tile.altAwarded = nil, nil, nil, nil

    -- main
    if main then
        local state = ctx.obtainedState and ctx.obtainedState(main) or nil
        local awarded = (not state) and ctx.awarded and ctx.awarded(main) or nil
        tile.mainState, tile.mainAwarded = state, awarded and true or nil
        tile.main:SetItem(main)
        ApplyButtonState(tile.main, state, awarded)
        local text, loading = UI:ItemText(main)
        pending = pending or loading
        tile.line1:SetText(text)
        if twoHandBlocked then
            tile.line2:SetText(ColorKey("warn", "Two-hander in main hand"))
        elseif state then
            tile.line2:SetText(ColorKey("obtained", UI.OBTAINED_LABELS[state] or "Obtained"))
        elseif awarded then
            tile.line2:SetText(ColorKey("obtained", "Awarded"))
        else
            tile.line2:SetText(Grey(SourceText(main) or "Other source (quest, world drop...)"))
        end
    else
        tile.main:SetItem(nil, UI:EmptySlotTexture(sid))
        if editable and not locked then
            tile.line1:SetText(Grey(label .. " - click to choose"))
        else
            tile.line1:SetText(Grey(label))
        end
        if twoHandBlocked then
            tile.line2:SetText(Grey("Two-hander in main hand"))
        else
            tile.line2:SetText(editable and "" or Grey("No item chosen"))
        end
    end
    tile:SetAlpha(twoHandBlocked and 0.55 or 1)

    -- alt
    if alt then
        local state = ctx.obtainedState and ctx.obtainedState(alt) or nil
        local awarded = (not state) and ctx.awarded and ctx.awarded(alt) or nil
        tile.altState, tile.altAwarded = state, awarded and true or nil
        tile.alt:SetItem(alt)
        tile.alt:SetBadge(nil)
        ApplyButtonState(tile.alt, state, awarded)
        tile.alt:Show()
    elseif editable and not locked then
        tile.alt:SetItem(nil, UI:Tex("slotBg"))
        tile.alt:SetBadge("+", 0.75, 0.75, 0.75)
        tile.alt:Show()
    else
        tile.alt:Hide()
    end

    -- what the player is wearing in this slot, when it isn't the main pick
    if ctx.showEquipped and eqID and eqID ~= main then
        tile.wear:SetItem(eqID)
        tile.wear:Show()
    else
        tile.wear:SetItem(nil)
        tile.wear:Hide()
    end

    return pending
end

---------------------------------------------------------------------------
-- Doll methods
---------------------------------------------------------------------------

-- record: { data = ListData } (own record or a Store record); phase 1..5;
-- ctx: { obtainedState = fn(itemID) -> state|nil, awarded = fn(itemID) -> bool, showEquipped = bool,
--        isDisabled = fn(sid) -> bool (optional; default: the record's disabled slots, §36) }
function Doll:Update(record, phase, ctx)
    ctx = ctx or {}
    self.lastRecord, self.lastPhase, self.lastCtx = record, phase, ctx
    self.phase = phase
    local data = type(record) == "table" and type(record.data) == "table" and record.data or nil
    local phases = data and type(data.ph) == "table" and data.ph or nil
    local ph = phases and phases[phase]
    if type(ph) ~= "table" then ph = nil end
    local eq = data and type(data.eq) == "table" and data.eq or nil

    local mhMain = SlotEntry(ph, SID_MAINHAND)
    local twoHander = mhMain and EquipLoc(mhMain) == "INVTYPE_2HWEAPON"
        and not SlotDisabled(record, phase, SID_MAINHAND)

    local pending = false
    for sid, tile in pairs(self.tiles) do
        local main, alt = SlotEntry(ph, sid)
        local eqID = eq and ValidID(eq[sid]) or nil
        local disabled
        if ctx.isDisabled then disabled = ctx.isDisabled(sid) else disabled = SlotDisabled(record, phase, sid) end
        if PaintTile(self, tile, main, alt, ctx, eqID, sid == SID_OFFHAND and twoHander, disabled) then
            pending = true
        end
    end
    self.pending = pending
end

-- DisasterZone extension (§36): the tile of sid shows a disabled slot.
function Doll:IsTileDisabled(sid)
    local tile = self.tiles[sid]
    return (tile and tile.disabled) and true or false
end

-- DisasterZone extension (§38): an editable doll whose list is locked (tooltips say so, no "+" alt placeholders).
function Doll:SetLocked(locked)
    locked = locked and true or false
    if self.locked == locked then return end
    self.locked = locked
    if self.lastRecord then self:Update(self.lastRecord, self.lastPhase, self.lastCtx) end
end

function Doll:SetHighlight(sid)
    for tsid, tile in pairs(self.tiles) do
        tile.editBorder:SetShown(tsid == sid)
    end
end

function Doll:GetTile(sid)
    return self.tiles[sid]
end

function Doll:SetReadOnly(readOnly)
    self.readOnly = readOnly and true or false
    if self.lastRecord then self:Update(self.lastRecord, self.lastPhase, self.lastCtx) end
end

---------------------------------------------------------------------------
-- Factory
---------------------------------------------------------------------------

-- opts = { readOnly = bool, onSlotClick = fn(sid, which, mouseButton, tile),
--          onSlotReceiveItem = fn(sid, itemID, which) }
-- Returns a Frame (filling `parent`; re-anchor it freely) with the Doll methods, `.center` and `.tiles`.
function PaperDoll:Create(parent, opts)
    local doll = CreateFrame("Frame", nil, parent)
    doll:SetAllPoints(parent)
    for k, fn in pairs(Doll) do doll[k] = fn end
    doll.frame = doll
    doll.opts = opts or {}
    doll.readOnly = doll.opts.readOnly and true or false
    doll.tiles = {}

    local left = ns.DOLL_LEFT or DEFAULT_LEFT
    local right = ns.DOLL_RIGHT or DEFAULT_RIGHT
    local bottom = ns.DOLL_BOTTOM or DEFAULT_BOTTOM

    for i, sid in ipairs(left) do
        local tile = CreateTile(doll, sid, "L", TILE_W)
        tile:SetPoint("TOPLEFT", doll, "TOPLEFT", SIDE_X, TOP_Y - (i - 1) * PITCH)
        doll.tiles[sid] = tile
    end
    for i, sid in ipairs(right) do
        local tile = CreateTile(doll, sid, "R", TILE_W)
        tile:SetPoint("TOPRIGHT", doll, "TOPRIGHT", -SIDE_X, TOP_Y - (i - 1) * PITCH)
        doll.tiles[sid] = tile
    end

    local rows = math.max(#left, #right)
    local bottomY = TOP_Y - rows * PITCH - BOTTOM_GAP
    local gap = BOTTOM_GAP_X
    local totalW = #bottom * BOTTOM_W + math.max(0, #bottom - 1) * gap
    for i, sid in ipairs(bottom) do
        local tile = CreateTile(doll, sid, "L", BOTTOM_W)
        tile:SetPoint("TOPLEFT", doll, "TOP", -totalW / 2 + (i - 1) * (BOTTOM_W + gap), bottomY)
        doll.tiles[sid] = tile
    end

    -- free area between the two columns, above the weapon row
    local inner = SIDE_X + TILE_W + CENTER_GAP
    doll.center = CreateFrame("Frame", nil, doll)
    doll.center:SetPoint("TOPLEFT", doll, "TOPLEFT", inner, TOP_Y)
    doll.center:SetPoint("BOTTOMRIGHT", doll, "TOPRIGHT", -inner, bottomY + BOTTOM_GAP)

    doll.layoutHeight = -(bottomY - TILE_H) + 4

    liveDolls[doll] = true
    return doll
end

-- Item names that were still loading get repainted once the client has them.
ns:On("ITEMINFO_READY", function()
    for doll in pairs(liveDolls) do
        if doll.pending and doll.lastRecord and doll:IsVisible() then
            doll:Update(doll.lastRecord, doll.lastPhase, doll.lastCtx)
        end
    end
end)

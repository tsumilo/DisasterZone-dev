if DisasterZoneBoot and DisasterZoneBoot.Run("UI/PaperDoll.lua", ...) then return end -- DisasterZone UI/PaperDoll.lua
-- ns.PaperDoll: reusable 17-slot paper-doll layout (left / right columns + weapon row) showing a
-- BiS list for one phase. Editable (My BiS) or read-only (Council member view). Slots the player disabled
-- (ADDENDUM F §36, ListData dx) are greyed; while the group's BiS lists are locked (§38) an editable doll
-- shows the lock in its tooltips (SetLocked).
-- The flat look: every slot is a dark tile with a 1px edge (lighter while hovered, gold while its item is being
-- picked), the main pick's icon with the alt pick as a small icon on its corner ("+" while hovered, to add one) and
-- what is worn in that slot now on the other corner; the item's name (two lines when long), then one line: obtained,
-- or where the item comes from (ctx.source, else the item database's text).
-- Gems and enchants (ctx.gems): at the inner end of that line a strip of small chips, one per socket (the gem in a
-- socket-coloured edge, or the empty socket), then the
-- enchant (green edge; a quiet "+" when it can take one and has none). Clicking the strip calls opts.onGemsClick.
local addonName, ns = ...

local PaperDoll = {}
ns.PaperDoll = PaperDoll

local S = ns.Style
local floor = math.floor

---------------------------------------------------------------------------
-- ns.GearUI: the small helpers the Gear pages shared as copies (My BiS, the Atlas, the picker, Import / Export).
-- (Their home is here: this file loads first of the Gear pages.)
---------------------------------------------------------------------------

local GearUI = {}
ns.GearUI = GearUI

-- The reputation standings by index (1 Hated .. 8 Exalted), in English (the client's own: GearUI.StandingName).
GearUI.STANDINGS = { "Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted" }

-- A standing's name in the client's language (FACTION_STANDING_LABELn), else the English one; "?" for none.
function GearUI.StandingName(i)
    local label = i and _G["FACTION_STANDING_LABEL" .. i]
    return (type(label) == "string" and label ~= "") and label or (i and GearUI.STANDINGS[i]) or "?"
end

-- "Pre-raid" / "P2".
function GearUI.PL(p)
    if ns.PhaseLabel then return ns.PhaseLabel(p) end
    return "P" .. tostring(p)
end

-- The guild's (or the group's) phase as a number (whole), or nil when unknown.
function GearUI.GuildPhase()
    local p = ns.Guild and ns.Guild.GetGuildPhase and tonumber(ns.Guild:GetGuildPhase())
    return p and floor(p) or nil
end

-- §38: my list is locked by the group's raid leader (UI:IsMyListLocked). locked, { by, at } | nil.
function GearUI.ListLocked()
    if ns.UI and ns.UI.IsMyListLocked then return ns.UI:IsMyListLocked() end
    return false, nil
end

-- Addendum H: I have an off-spec list.
function GearUI.HasOffSpec()
    return ns.BiS and ns.BiS.HasOffSpec and ns.BiS:HasOffSpec() or false
end

-- A gem socket / enchant chip (the doll's strip, the gem editor's rows): an icon in a 1 px edge of the socket's colour
-- on the inset well, or a quiet "+" while empty. plusStyle: the "+"'s text style ("small"). The chip is a slot's
-- small icon well, not a UI:CreateChip toggle; GearUI.PaintSocketChip paints it.
function GearUI.CreateSocketChip(parent, size, plusStyle)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(size, size)
    c.bg = ns.UI:Fill(c, "INSET")
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetPoint("TOPLEFT", 1, -1)
    c.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    c.plus = ns.UI:Text(c, plusStyle or "small", { 0.6, 0.6, 0.64 }, { justify = "CENTER", text = "+" })
    c.plus:SetPoint("CENTER", 0, 0)
    ns.UI:AddEdges(c, "OVERLAY")
    return c
end

-- icon (nil: none), edge { r, g, b[, a] }, crop (an item / spell icon: trim its border), plus (show the "+").
function GearUI.PaintSocketChip(c, icon, edge, crop, plus)
    c.icon:SetTexture(icon)
    c.icon:SetShown(icon ~= nil)
    if crop then c.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) else c.icon:SetTexCoord(0, 1, 0, 1) end
    c.plus:SetShown(plus and true or false)
    ns.UI:SetEdgeColor(c, edge[1], edge[2], edge[3], edge[4] or 1)
    c:Show()
end

-- Layouts (opts.layout):
--   default  the Council member view (fits a ~774 x 430 area, its own summary in the centre): 260 x 42 tiles on a
--            46px pitch, one-line names, the weapon row centred
--   page     My BiS (770 x 496): two columns of eight 262 x 56 tiles (the armour, then main and off hand at the
--            bottom left; hands to trinkets on the right), the ranged slot under the model in the centre column;
--            quiet tiles (a fill fading toward the model, none for an empty or disabled slot, edges only under the
--            mouse), names on up to two lines
local LAYOUTS = {
    default = { width = nil, tileW = 260, tileH = 42, gap = 4, colX = 8, top = -4, bottom = "center", bottomW = 246,
                bottomGapX = 10, bottomGap = 8, centerGap = 10, centerBottom = 8, icon = 32, alt = 15, wear = 13,
                pad = 7, textGap = 8, nameStyle = "small", nameColor = "TEXT", srcStyle = "small", srcColor = "SUB",
                wrap = false, lineGap = 2, chip = 11 },
    page    = { width = 770, tileW = 262, tileH = 56, gap = 6, colX = 0, top = 0, bottom = "centre", bottomGap = 0,
                centerGap = 8, centerBottom = 8, icon = 40, alt = 17, wear = 15, pad = 8, textGap = 10,
                nameStyle = "emph", nameColor = "TEXT", srcStyle = "small", srcColor = "TEXT", wrap = true, lineGap = 4,
                quiet = true, chip = 13, left = { 1, 2, 3, 4, 5, 6, 15, 16 }, right = { 7, 8, 9, 10, 11, 12, 13, 14 },
                bottomSlots = { 17 } },
}

local TILE_BG = { 0.08, 0.08, 0.095, 0.9 }
local TILE_BG_HOVER = { 0.13, 0.13, 0.155, 0.95 }
local EDGE = S.C.EDGE
local EDGE_HOVER = { 0.72, 0.72, 0.76, 0.75 }
local ALT_EDGE = { 0.56, 0.78, 1, 0.75 }
local WEAR_EDGE = { 0.62, 0.62, 0.66, 0.8 }

local DEFAULT_LEFT = { 1, 2, 3, 4, 5, 6 }
local DEFAULT_RIGHT = { 7, 8, 9, 10, 11, 12, 13, 14 }
local DEFAULT_BOTTOM = { 15, 16, 17 }

local SID_MAINHAND, SID_OFFHAND = 15, 16

local liveDolls = setmetatable({}, { __mode = "k" })

local Doll = {}

local SlotLabel = ns.SlotLabel

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

local function Grey(text) return S:Wrap("DIM", text) end
local function Soft(text) return S:Wrap("SUB", text) end
local Dim = Grey

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
    local Store = ns.Store
    if type(Store) == "table" and type(Store.IsSlotDisabled) == "function" then
        return Store:IsSlotDisabled(record, phase, sid) and true or false
    end
    local data = type(record) == "table" and type(record.data) == "table" and record.data or nil
    local dx
    if ns.ListDisabled then
        dx = ns.ListDisabled(data, phase)
    else
        dx = data and type(data.dx) == "table" and data.dx[phase]
    end
    return type(dx) == "table" and dx[sid] == true
end
PaperDoll.IsSlotDisabled = function(_, record, phase, sid) return SlotDisabled(record, phase, sid) end

-- " (P1)" / " (Pre-raid)" after a slot's name in a tooltip, or "" without a phase.
local function PhaseSuffix(phase)
    if not phase then return "" end
    return " (" .. (ns.PhaseLabel and ns.PhaseLabel(phase) or ("P" .. tostring(phase))) .. ")"
end

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
    tt:AddLine(label .. PhaseSuffix(doll.phase) .. " \226\128\148 disabled", 0.75, 0.75, 0.75)
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
    local ctx = doll.lastCtx or {}
    if tile.mainID then
        tt:AddLine(" ")
        local r, g, b = ns.UI:Color("main")
        tt:AddLine("DisasterZone: main BiS - " .. label .. PhaseSuffix(doll.phase), r, g, b)
        if tile.mainState or tile.mainAwarded then
            StateLine(tt, tile.mainState, tile.mainAwarded)
        elseif ctx.sourceTip then
            ctx.sourceTip(tile.mainID, tt)
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
            tt:AddLine("Shift-click to link  ·  Drop an item from your bags to use it", 0.5, 0.5, 0.5, true)
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

local function Paint(f, c) f:SetColorTexture(c[1], c[2], c[3], c[4]) end

-- The quiet look (page): a fill that fades toward the model when the slot holds a pick, nothing when it is empty or
-- disabled; under the mouse a light fill and edges.
-- TODO(refactor): move into UI:CreateCard (a Button card: the tiles take clicks and dropped items, and a centre tile
-- fades both ways) - the numbers are the card's quiet tone.
local function PaintQuiet(tile, hov)
    local a = (hov and 0.16) or (tile.filled and 0.11) or 0
    local fade = tile.side == "R" and { 0.25, 1 } or (tile.side == "C" and { 1, 1 } or { 1, 0.25 })
    ns.UI:Gradient(tile.bg, "HORIZONTAL", { 0.55, 0.55, 0.62, a * fade[1] }, { 0.55, 0.55, 0.62, a * fade[2] })
    ns.UI:SetEdgeColor(tile, EDGE_HOVER[1], EDGE_HOVER[2], EDGE_HOVER[3], hov and 0.45 or 0)
end

-- The tile's look: hover (the tile or one of its icons), and the "+" alt placeholder that only shows while hovered.
local function PaintHover(tile)
    local hov = tile.hovered and true or false
    if tile.L.quiet then
        PaintQuiet(tile, hov)
    else
        Paint(tile.bg, hov and TILE_BG_HOVER or TILE_BG)
        local e = hov and EDGE_HOVER or EDGE
        ns.UI:SetEdgeColor(tile, e[1], e[2], e[3], e[4])
    end
    if tile.altPlaceholder then tile.alt:SetAlpha(hov and 1 or 0) else tile.alt:SetAlpha(1) end
end

local function SetHovered(tile, on)
    tile.hovered = on and true or false
    PaintHover(tile)
end

-- A small icon on a corner of the main icon (the alt pick, what is worn now): its own 1px edge.
local function CornerIcon(tile, size, edge)
    local b = ns.UI:CreateItemButton(tile, size)
    b:SetFrameLevel(tile.main:GetFrameLevel() + 2)
    ns.UI:AddEdges(b, "OVERLAY")
    ns.UI:SetEdgeColor(b, edge[1], edge[2], edge[3], edge[4])
    b.badge:ClearAllPoints()
    b.badge:SetPoint("CENTER", b, "CENTER", 0, 0)
    return b
end

-- Gems and enchants strip

local CHIP_GAP, ENCHANT_GAP = 3, 6
local ENCHANT_EDGE = { 0.25, 0.85, 0.3, 0.95 }
local EMPTY_EDGE = { 0.42, 0.42, 0.46, 0.9 }

local function GemColor(letter)
    local c = ns.Gems and ns.Gems.COLORS[letter]
    return c or { 0.6, 0.6, 0.6 }
end

local CreateChip = GearUI.CreateSocketChip
local function SetChip(c, icon, edge, crop) GearUI.PaintSocketChip(c, icon, edge, crop, false) end

-- The strip's tooltip, laid out like the game's own: the item as the title, then a line per gem and the enchant
-- (icon and name on the left, what it gives on the right, soft), the socket bonus as a line of its own (dim until
-- it is on). An empty socket or no enchant: a dim line; a meta gem that is not active: "inactive" after its name.
local SOFT = { 0.62, 0.85, 0.62 }
local DIMMED = { 0.47, 0.47, 0.5 }

local function IconText(tex, text)
    return tex and ("|T" .. tex .. ":13:13:0:0:64:64:5:59:5:59|t  " .. text) or text
end

local function GemTooltip(doll, tile, tt)
    local G = ns.Gems
    local st = tile.gemState
    if not (G and st) then return end
    local name, _, quality = nil, nil, nil
    if ns.ItemDB and ns.ItemDB.GetInfo then name, _, quality = ns.ItemDB:GetInfo(tile.mainID) end
    tt:AddLine(name or SlotLabel(tile.sid), ns.UI:QualityColor(quality or 4))
    local sockets, bonus = G:Sockets(tile.mainID)
    for i, s in ipairs(sockets) do
        local g = G:Gem(st.gems[i])
        if g then
            local r, gg, b = ns.UI:QualityColor(g.quality)
            local label = g.name
            if g.color == "M" and not (G:MetaState(g.id, doll.metaCounts)) then
                label = label .. "  |cffe6735ainactive|r"
            end
            tt:AddDoubleLine(IconText(g.icon, label), g.text or "", r, gg, b, SOFT[1], SOFT[2], SOFT[3])
        else
            tt:AddLine(IconText(G.EMPTY_SOCKET[s], "Empty " .. G.SOCKET_NAMES[s]:lower() .. " socket"),
                DIMMED[1], DIMMED[2], DIMMED[3])
        end
    end
    if bonus then
        local c = st.bonus and SOFT or DIMMED          -- (the whole line: green while it is on, grey while it isn't)
        tt:AddDoubleLine("Socket bonus", bonus, c[1], c[2], c[3], c[1], c[2], c[3])
    end
    if st.enchantable then
        local e = G:Enchant(st.enchant)
        if e then
            tt:AddDoubleLine(IconText(e.icon, e.short), e.text or "", 0.12, 1, 0, SOFT[1], SOFT[2], SOFT[3])
        else
            tt:AddLine("No enchant", DIMMED[1], DIMMED[2], DIMMED[3])
        end
    end
end

local function CreateStrip(doll, tile)
    local strip = CreateFrame("Button", nil, tile)
    strip:SetFrameLevel(tile:GetFrameLevel() + 3)
    strip:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    strip.chips = {}
    strip:SetScript("OnClick", function(_, mouseButton)
        if doll.readOnly or doll.locked then return end
        local cb = doll.opts.onGemsClick
        if cb then cb(tile.sid, tile, mouseButton) end
    end)
    strip:SetScript("OnEnter", function() SetHovered(tile, true) end)
    strip:SetScript("OnLeave", function() SetHovered(tile, false) end)
    ns.UI:AttachTooltip(strip, function(_, tt) GemTooltip(doll, tile, tt) end)
    strip:Hide()
    return strip
end

-- Paints the strip for the tile's main pick; returns its width (0 when hidden).
local function PaintStrip(doll, tile, data, ctx)
    local G = ns.Gems
    local strip = tile.strip
    tile.gemState = nil
    if not (G and ctx.gems and tile.mainID and data) then
        strip:Hide()
        return 0
    end
    local st = G:State(data, tile.mainID, ctx.gemProfs)
    if st.sockets == 0 and not st.enchantable then
        strip:Hide()
        return 0
    end
    tile.gemState = st
    local sockets = G:Sockets(tile.mainID)
    local editable = not doll.readOnly and not doll.locked
    local size = tile.L.chip or 12
    local n, x = 0, 0
    local function chip()
        n = n + 1
        local c = strip.chips[n]
        if not c then
            c = CreateChip(strip, size)
            strip.chips[n] = c
        end
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", strip, "TOPLEFT", x, 0)
        x = x + size + CHIP_GAP
        return c
    end
    for i, s in ipairs(sockets) do
        local c = chip()
        local g = G:Gem(st.gems[i])
        local col = GemColor(s)
        if g then
            SetChip(c, g.icon, { col[1], col[2], col[3], 1 }, true)
        else
            SetChip(c, G.EMPTY_SOCKET[s], { col[1] * 0.75, col[2] * 0.75, col[3] * 0.75, 0.9 }, false)
        end
    end
    if st.enchantable then
        if n > 0 then x = x + ENCHANT_GAP - CHIP_GAP end
        local c = chip()
        local e = G:Enchant(st.enchant)
        if e then
            SetChip(c, e.icon, ENCHANT_EDGE, true)
        else
            SetChip(c, nil, EMPTY_EDGE)
            c.plus:SetShown(editable)
        end
    end
    for i = n + 1, #strip.chips do strip.chips[i]:Hide() end
    local w = x - CHIP_GAP
    strip:SetSize(w, size)
    strip:Show()
    return w
end

local function CreateTile(doll, sid, side, width)
    local UI = ns.UI
    local L = doll.L
    local tile = CreateFrame("Button", nil, doll)
    tile:SetSize(width, L.tileH)
    tile.sid = sid
    tile.side = side
    tile.L = L
    tile.textW = width - L.pad - L.icon - L.textGap - L.pad
    tile:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    tile.bg = tile:CreateTexture(nil, "BACKGROUND")
    tile.bg:SetAllPoints()
    UI:AddEdges(tile, "BORDER")

    -- gold edges while this slot's item is being picked (SetHighlight)
    tile.editBorder = CreateFrame("Frame", nil, tile)
    tile.editBorder:SetAllPoints(tile)
    tile.editBorder:SetFrameLevel(tile:GetFrameLevel() + 4)
    UI:AddEdges(tile.editBorder, "OVERLAY")
    local gr, gg, gb = S:Color("GOLD")
    UI:SetEdgeColor(tile.editBorder, gr, gg, gb, 0.95)
    tile.editBorder:Hide()

    local right = side == "R"          -- ("C": a centre tile, laid out like the left column)
    local near = right and "RIGHT" or "LEFT"
    local dir = right and -1 or 1
    tile.main = UI:CreateItemButton(tile, L.icon)
    tile.main:SetPoint(near, tile, near, dir * L.pad, 0)
    -- the obtained check sits on the corner away from the alt pick
    tile.main.overlay:ClearAllPoints()
    if right then
        tile.main.overlay:SetPoint("BOTTOMRIGHT", tile.main, "BOTTOMRIGHT", 3, -3)
    else
        tile.main.overlay:SetPoint("BOTTOMLEFT", tile.main, "BOTTOMLEFT", -3, -3)
    end
    tile.alt = CornerIcon(tile, L.alt, ALT_EDGE)
    tile.wear = CornerIcon(tile, L.wear, WEAR_EDGE)
    if right then
        tile.alt:SetPoint("BOTTOMLEFT", tile.main, "BOTTOMLEFT", -5, -5)
        tile.wear:SetPoint("TOPRIGHT", tile.main, "TOPRIGHT", 4, 4)
    else
        tile.alt:SetPoint("BOTTOMRIGHT", tile.main, "BOTTOMRIGHT", 5, -5)
        tile.wear:SetPoint("TOPLEFT", tile.main, "TOPLEFT", -4, 4)
    end
    tile.wear:SetAlpha(0.9)
    tile.wear:Hide()

    tile.line1 = UI:Text(tile, L.nameStyle, L.nameColor)
    tile.line2 = UI:Text(tile, L.srcStyle, L.srcColor)
    tile.line1:SetWidth(tile.textW)
    tile.line2:SetWidth(tile.textW)
    if L.wrap then
        tile.line1:SetWordWrap(true)
        if tile.line1.SetMaxLines then tile.line1:SetMaxLines(2) end
    else
        tile.line1:SetWordWrap(false)
        tile.line1:SetHeight(14)
    end
    tile.line2:SetWordWrap(false)
    tile.line2:SetHeight(14)
    local justify = right and "RIGHT" or "LEFT"
    tile.line1:SetJustifyH(justify)
    tile.line2:SetJustifyH(justify)
    tile.line1:SetJustifyV("TOP")
    tile.line2:SetPoint("TOP" .. justify, tile.line1, "BOTTOM" .. justify, 0, -L.lineGap)
    tile.strip = CreateStrip(doll, tile)

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
    -- the icons keep the tile's hover look (and its "+")
    for _, b in ipairs({ tile.main, tile.alt, tile.wear }) do
        b:HookScript("OnEnter", function() SetHovered(tile, true) end)
        b:HookScript("OnLeave", function() SetHovered(tile, false) end)
    end

    -- the text area acts like the main button
    tile:SetScript("OnClick", function(self, mouseButton)
        if self.__cdlDropTime and self.__cdlDropTime == GetTime() then return end
        if self.mainID and UI:HandleModifiedItemClick(self.mainID) then return end
        HandleClick(doll, self, "main", mouseButton)
    end)
    tile:SetScript("OnEnter", function(self)
        SetHovered(self, true)
        UI:SetItemTooltip(self, self.mainLink or self.mainID, function(tt) MainTooltip(doll, self, tt) end)
    end)
    tile:SetScript("OnLeave", function(self)
        SetHovered(self, false)
        GameTooltip:Hide()
    end)
    UI:AttachItemDrop(tile, function(self, itemID) HandleDrop(doll, self, itemID, "main") end)

    PaintHover(tile)
    return tile
end

-- Centres the name (one or two lines) and the line under it in the tile.
local function PlaceText(tile)
    local L = tile.L
    local h1 = 14
    if L.wrap then
        h1 = tonumber(tile.line1:GetStringHeight()) or 0
        if h1 <= 0 then h1 = 14 end
        if h1 > 30 then h1 = 30 end
    end
    local hasSecond = (tile.line2:GetText() or "") ~= ""
    local total = h1 + (hasSecond and (L.lineGap + 12) or 0)
    local top = floor((L.tileH - total) / 2 + 0.5)
    if top < 2 then top = 2 end
    local x = L.pad + L.icon + L.textGap
    tile.line1:ClearAllPoints()
    if tile.side == "R" then
        tile.line1:SetPoint("TOPRIGHT", tile, "TOPRIGHT", -x, -top)
    else
        tile.line1:SetPoint("TOPLEFT", tile, "TOPLEFT", x, -top)
    end
    -- the gem strip: at the inner end of the second line (its row: the first line's height and the gap below it)
    local strip = tile.strip
    if strip and strip:IsShown() then
        local y = -(top + h1 + L.lineGap) + floor(((L.chip or 12) - 12) / 2 + 0.5)
        strip:ClearAllPoints()
        if tile.side == "R" then
            strip:SetPoint("TOPLEFT", tile, "TOPLEFT", L.pad, y)
        else
            strip:SetPoint("TOPRIGHT", tile, "TOPRIGHT", -L.pad, y)
        end
    end
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
    tile.altPlaceholder = nil
    tile.main:SetItem(main, UI:EmptySlotTexture(sid))
    tile.main:SetState("dim")
    Desaturate(tile.main)
    tile.filled = nil
    if doll.L.quiet then
        tile.line1:SetText(Dim(SlotLabel(sid)))
        tile.line2:SetText(Dim("Not needed"))
    else
        tile.line1:SetText(Grey(DISABLED_TEXT))
        tile.line2:SetText(Grey(SlotLabel(sid) .. (main and "  ·  pick kept" or "")))
    end
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
    tile:SetAlpha(doll.L.quiet and 0.7 or 0.8)
    PaintHover(tile)
    PlaceText(tile)
    return false
end

-- Returns true when some item name is still loading.
local function PaintTile(doll, tile, main, alt, ctx, eqID, twoHandBlocked, disabled, data)
    local UI = ns.UI
    local sid = tile.sid
    local label = SlotLabel(sid)
    local editable = not doll.readOnly
    local locked = editable and doll.locked
    local pending = false

    tile.disabled = disabled and true or nil
    tile.mainLink, tile.main.itemLink = nil, nil
    if disabled then
        tile.strip:Hide()
        tile.line2:SetWidth(tile.textW)
        return PaintDisabledTile(doll, tile, main, alt)
    end
    tile.mainID, tile.altID = main, alt
    tile.twoHandBlocked = twoHandBlocked or nil
    -- gems and enchant: the strip first (the line beside it gets what is left of the width)
    local stripW = 0
    if main and not twoHandBlocked then stripW = PaintStrip(doll, tile, data, ctx) else tile.strip:Hide() end
    local lineW = stripW > 0 and (tile.textW - stripW - 8) or tile.textW
    tile.line2:SetWidth(lineW)
    if main and ns.Gems and ctx.gems then
        tile.mainLink = ns.Gems:LinkFor(data, main)
        tile.main.itemLink = tile.mainLink
    end
    tile.mainState, tile.mainAwarded, tile.altState, tile.altAwarded = nil, nil, nil, nil
    tile.filled = main and not twoHandBlocked or nil

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
            local src = ctx.source and ctx.source(main, sid, tile.line2, lineW)
            tile.line2:SetText(src or Soft(SourceText(main) or "Other source"))
        end
    else
        tile.main:SetItem(nil, UI:EmptySlotTexture(sid))
        if doll.L.wrap then
            -- (My BiS) the slot's name, and what a click does
            -- (the slot's name alone: a click chooses, as its tooltip says; the page says it once, not 17 times)
            tile.line1:SetText(doll.L.quiet and Soft(label) or Grey(label))
            if twoHandBlocked then
                tile.line2:SetText(Dim("Two-hander in main hand"))
            elseif doll.L.quiet then
                tile.line2:SetText("")
            else
                tile.line2:SetText((editable and not locked) and Grey("Click to choose") or "")
            end
        else
            tile.line1:SetText(Grey((editable and not locked) and (label .. " - click to choose") or label))
            if twoHandBlocked then
                tile.line2:SetText(Grey("Two-hander in main hand"))
            else
                tile.line2:SetText(editable and "" or Grey("No item chosen"))
            end
        end
    end
    tile:SetAlpha(twoHandBlocked and 0.55 or 1)

    -- alt (a "+" to add one, only while the tile is hovered)
    tile.altPlaceholder = nil
    if alt then
        local state = ctx.obtainedState and ctx.obtainedState(alt) or nil
        local awarded = (not state) and ctx.awarded and ctx.awarded(alt) or nil
        tile.altState, tile.altAwarded = state, awarded and true or nil
        tile.alt:SetItem(alt)
        tile.alt:SetBadge(nil)
        ApplyButtonState(tile.alt, state, awarded)
        if tile.alt.overlay then tile.alt.overlay:Hide() end   -- (too small for a check: the tooltip says it)
        tile.alt:Show()
    elseif editable and not locked then
        tile.alt:SetItem(nil, UI:Tex("slotBg"))
        tile.alt:SetBadge("+", 0.85, 0.85, 0.85)
        tile.altPlaceholder = true
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

    PaintHover(tile)
    PlaceText(tile)
    return pending
end

---------------------------------------------------------------------------
-- Doll methods
---------------------------------------------------------------------------

-- record: { data = ListData } (own record or a Store record); phase 1..5, or 0 = the Pre-raid list (own lists only);
-- ctx: { obtainedState = fn(itemID) -> state|nil, awarded = fn(itemID) -> bool, showEquipped = bool,
--        isDisabled = fn(sid) -> bool (optional; default: the record's disabled slots, §36),
--        source = fn(itemID, sid, fontString, width) -> text | nil (optional: the line under a pick that is not
--                 obtained; default: the item database's short source text),
--        sourceTip = fn(itemID, tooltip) (optional: the tooltip's lines about where the item comes from) }
function Doll:Update(record, phase, ctx)
    ctx = ctx or {}
    self.lastRecord, self.lastPhase, self.lastCtx = record, phase, ctx
    self.phase = phase
    local data = type(record) == "table" and type(record.data) == "table" and record.data or nil
    local ph
    if ns.ListPhase then
        ph = ns.ListPhase(data, phase)
    else
        local phases = data and type(data.ph) == "table" and data.ph or nil
        ph = phases and phases[phase]
    end
    if type(ph) ~= "table" then ph = nil end
    local eq = data and type(data.eq) == "table" and data.eq or nil

    local mhMain = SlotEntry(ph, SID_MAINHAND)
    local twoHander = mhMain and EquipLoc(mhMain) == "INVTYPE_2HWEAPON"
        and not SlotDisabled(record, phase, SID_MAINHAND)

    self.metaCounts = (ctx.gems and data and ns.Gems) and ns.Gems:ColorCounts(data, phase) or nil
    local pending = false
    for sid, tile in pairs(self.tiles) do
        local main, alt = SlotEntry(ph, sid)
        local eqID = eq and ValidID(eq[sid]) or nil
        local disabled
        if ctx.isDisabled then disabled = ctx.isDisabled(sid) else disabled = SlotDisabled(record, phase, sid) end
        if PaintTile(self, tile, main, alt, ctx, eqID, sid == SID_OFFHAND and twoHander, disabled, data) then
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
--          onSlotReceiveItem = fn(sid, itemID, which), layout = "default" | "page" }
-- Returns a Frame (filling `parent`; re-anchor it freely; the "page" layout is 770 x 496 at the parent's top left)
-- with the Doll methods, `.center` (the free area between the columns, above the weapon row) and `.tiles`.
function PaperDoll:Create(parent, opts)
    opts = opts or {}
    local L = LAYOUTS[opts.layout or "default"] or LAYOUTS.default
    local doll = CreateFrame("Frame", nil, parent)
    if L.width then
        doll:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    else
        doll:SetAllPoints(parent)
    end
    for k, fn in pairs(Doll) do doll[k] = fn end
    doll.frame = doll
    doll.opts = opts
    doll.L = L
    doll.readOnly = opts.readOnly and true or false
    doll.tiles = {}

    local left = L.left or ns.DOLL_LEFT or DEFAULT_LEFT
    local right = L.right or ns.DOLL_RIGHT or DEFAULT_RIGHT
    local bottom = L.bottomSlots or ns.DOLL_BOTTOM or DEFAULT_BOTTOM
    local pitch = L.tileH + L.gap

    for i, sid in ipairs(left) do
        local tile = CreateTile(doll, sid, "L", L.tileW)
        tile:SetPoint("TOPLEFT", doll, "TOPLEFT", L.colX, L.top - (i - 1) * pitch)
        doll.tiles[sid] = tile
    end
    for i, sid in ipairs(right) do
        local tile = CreateTile(doll, sid, "R", L.tileW)
        tile:SetPoint("TOPRIGHT", doll, "TOPRIGHT", -L.colX, L.top - (i - 1) * pitch)
        doll.tiles[sid] = tile
    end

    local rows = math.max(#left, #right)
    local bottomY = L.top - rows * pitch - L.bottomGap
    if L.bottom == "centre" then
        -- in the centre column, on the columns' last row (the model above them)
        local inner = L.colX + L.tileW + L.centerGap
        local midW = L.width - 2 * inner
        bottomY = L.top - (rows - #bottom) * pitch
        for i, sid in ipairs(bottom) do
            local tile = CreateTile(doll, sid, "C", midW)
            tile:SetPoint("TOPLEFT", doll, "TOPLEFT", inner, bottomY - (i - 1) * pitch)
            doll.tiles[sid] = tile
        end
        doll.center = CreateFrame("Frame", nil, doll)
        doll.center:SetPoint("TOPLEFT", doll, "TOPLEFT", inner, L.top)
        doll.center:SetPoint("BOTTOMRIGHT", doll, "TOPRIGHT", -inner, bottomY + L.centerBottom)
        doll.layoutHeight = -(L.top - rows * pitch + L.gap)
        doll:SetSize(L.width, doll.layoutHeight)
        doll.centerWidth = midW
        doll.centerHeight = -(bottomY + L.centerBottom) + L.top
        liveDolls[doll] = true
        return doll
    elseif L.bottom == "align" and #bottom == 3 then
        -- the outer tiles under the columns, the middle one as wide as the centre
        local midW = L.width - 2 * (L.colX + L.tileW + L.gap)
        local xs = { L.colX, L.colX + L.tileW + L.gap, L.width - L.colX - L.tileW }
        local ws = { L.tileW, midW, L.tileW }
        for i, sid in ipairs(bottom) do
            local tile = CreateTile(doll, sid, "L", ws[i])
            tile:SetPoint("TOPLEFT", doll, "TOPLEFT", xs[i], bottomY)
            doll.tiles[sid] = tile
        end
    else
        local gap = L.bottomGapX or L.gap
        local w = L.bottomW or L.tileW
        local totalW = #bottom * w + math.max(0, #bottom - 1) * gap
        for i, sid in ipairs(bottom) do
            local tile = CreateTile(doll, sid, "L", w)
            tile:SetPoint("TOPLEFT", doll, "TOP", -totalW / 2 + (i - 1) * (w + gap), bottomY)
            doll.tiles[sid] = tile
        end
    end

    -- free area between the two columns, above the weapon row
    local inner = L.colX + L.tileW + L.centerGap
    doll.center = CreateFrame("Frame", nil, doll)
    doll.center:SetPoint("TOPLEFT", doll, "TOPLEFT", inner, L.top)
    doll.center:SetPoint("BOTTOMRIGHT", doll, "TOPRIGHT", -inner, bottomY + L.centerBottom)

    doll.layoutHeight = -(bottomY - L.tileH) + (L.width and 0 or 4)
    if L.width then
        doll:SetSize(L.width, doll.layoutHeight)
        doll.centerWidth = L.width - 2 * inner
        doll.centerHeight = -(bottomY + L.centerBottom) + L.top
    end

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

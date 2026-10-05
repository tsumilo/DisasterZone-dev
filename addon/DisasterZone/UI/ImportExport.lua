if DisasterZoneBoot and DisasterZoneBoot.Run("UI/ImportExport.lua", ...) then return end -- DisasterZone: UI/ImportExport.lua
-- ns.ImportExport: the window My BiS's Import and Export buttons open, one tab each.
-- Import: paste a list from That's My BiS, Sixty Upgrades, WoWSims, a Wowhead gear planner link or item links; the
-- format is recognised as soon as it is pasted (Core/BiSImport.lua). It goes into the phase (and list) picked under
-- the box; the preview lists every slot the import fills, or that Replace would empty, next to what is there now.
-- "Fill empty slots" and "Replace Px" write it; That's My BiS's received items can be marked obtained. The phase can
-- also be Pre-raid (phase 0).
-- Export: my gear or a BiS phase for WoWSims (Import > Addon), a WoWSims Bulk list, or a Wowhead gear planner link
-- (Core/BiSExport.lua), in a box that is selected for Ctrl+C.
-- Big pastes (a guild's That's My BiS export can be hundreds of KB): the box shows only the start (SetMaxBytes) and
-- the whole text is collected from OnChar, as WeakAuras does, so the client doesn't stall on it.
local addonName, ns = ...

local Win = ns:NewModule("ImportExport")

local type, tostring, tonumber, ipairs, pairs = type, tostring, tonumber, ipairs, pairs
local tconcat = table.concat

local W, H = 640, 560
local MAX_SHOWN = 16000
local ROW_H, HEADER_ROW_H = 32, 20
local NUM_SLOTS = 17

local win
local state = {
    tab = "import",
    source = "",
    parsed = nil, err = nil,
    character = nil,
    phase = 1, list = "ms",
    markReceived = true,
    done = nil,
    what = "bis", format = "wowsims",
    exPhase = 1, exList = "ms",
}

-- the OnChar burst of the paste being collected
local burst, burstN, burstAt = {}, 0, nil

local function UI() return ns.UI end
local function Imp() return ns.BiSImport end
local function Exp() return ns.BiSExport end
local function BiS() return ns.BiS end

-- "Pre-raid" or "P<n>".
local function PL(p) return ns.PhaseLabel and ns.PhaseLabel(p) or ("P" .. tostring(p)) end

local function SlotLabel(sid)
    local s = ns.SLOTS and ns.SLOTS[sid]
    return s and s.label or ("Slot " .. tostring(sid))
end

local function ClassName(classFile)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile]) or classFile or "?"
end

local function MyClass()
    local _, classFile = UnitClass("player")
    return classFile
end

local function ListLocked()
    local ui = UI()
    if ui and ui.IsMyListLocked then return ui:IsMyListLocked() end
    return false
end

local function HasOffSpec()
    return BiS() and BiS():HasOffSpec() or false
end

local function Plural(n, one, many)
    return n == 1 and ("1 " .. one) or (tostring(n) .. " " .. (many or (one .. "s")))
end

local GREEN, GREY, ORANGE, RED = { 0.3, 0.9, 0.3 }, { 0.6, 0.6, 0.6 }, { 1, 0.6, 0.2 }, { 1, 0.35, 0.3 }
local function Tint(text, c) return UI():Colorize(text, c) end

---------------------------------------------------------------------------
-- Text boxes (a flat field with a scroll frame around a multi-line edit box)
---------------------------------------------------------------------------

local function CreateTextBox(parent, height)
    local ui = UI()
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(height)
    holder.bg = holder:CreateTexture(nil, "BACKGROUND")
    holder.bg:SetAllPoints()
    holder.bg:SetColorTexture(0.10, 0.10, 0.12, 0.92)
    ui:AddEdges(holder)
    ui:SetEdgeColor(holder, 0.34, 0.34, 0.38, 0.9)

    local sf = ui:CreateScrollFrame(holder)
    sf:SetPoint("TOPLEFT", holder, "TOPLEFT", 6, -5)
    sf:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -18, 5)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetWidth(W - 60)
    eb:SetHeight(height - 10)
    sf:SetScrollChild(eb)
    sf:HookScript("OnSizeChanged", function(self, w)
        if tonumber(w) and w > 0 then eb:SetWidth(w) end
    end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- keep the cursor in view while typing or moving through the text
    eb:SetScript("OnCursorChanged", function(_, _, y, _, h)
        local top, view = sf:GetVerticalScroll() or 0, sf:GetHeight() or 0
        local range = sf:GetVerticalScrollRange() or 0
        y, h = -(tonumber(y) or 0), tonumber(h) or 0
        local to
        if y < top then
            to = y
        elseif view > 0 and y + h > top + view then
            to = y + h - view
        end
        if to then sf:SetVerticalScroll(math.max(0, math.min(range, to))) end
    end)
    eb:SetScript("OnEditFocusGained", function(self)
        ui:SetEdgeColor(holder, 1, 0.82, 0, 0.75)
        self:HighlightText()
    end)
    eb:SetScript("OnEditFocusLost", function(self)
        ui:SetEdgeColor(holder, 0.34, 0.34, 0.38, 0.9)
        self:HighlightText(0, 0)
    end)
    holder:EnableMouse(true)
    holder:SetScript("OnMouseDown", function() eb:SetFocus() end)
    sf:EnableMouse(true)
    sf:SetScript("OnMouseDown", function() eb:SetFocus() end)
    holder.eb, holder.sf = eb, sf
    return holder
end

---------------------------------------------------------------------------
-- Import
---------------------------------------------------------------------------

local WHERE_LINES = {
    { "That's My BiS", "Guild > Exports > \"Just Wishlists\" > View CSV, then copy everything. Your character is "
        .. "picked out of the guild's list; off-spec items go to your off-spec list." },
    { "Sixty Upgrades", "Open the set, Export, and copy the text." },
    { "WoWSims", "Export > JSON (or the WoWSims exporter addon's text)." },
    { "Wowhead", "The gear planner page's link (wowhead.com/tbc/gear-planner/...)." },
    { "Anything else", "Item links from chat, Wowhead item links, item numbers or item names, one per line "
        .. "(a table copied from a guide works too)." },
}

local function ImportPlan()
    if not state.parsed then return nil end
    return Imp():Plan(state.parsed, { character = state.character, list = state.list })
end

local function StatusText(plan)
    if state.done then return Tint(state.done, GREEN) end
    if state.err then return Tint(state.err, RED) end
    local p = state.parsed
    if not p then return "" end
    local label = "|cffffd100" .. p.label .. "|r"
    if p.format == "tmb" then
        local text = label .. "  ·  " .. Plural(#p.characters, "character")
        local c = state.character and p.byChar[state.character]
        if not c then return text .. "  ·  " .. Tint("pick your character", ORANGE) end
        text = text .. "  ·  " .. c.name .. ": " .. Plural(#c.items, "wishlist item")
        if #c.items == 0 then text = text .. "  ·  " .. Tint("nothing on the wishlist", ORANGE) end
        if c.class and c.class ~= MyClass() then
            text = text .. "  ·  " .. Tint("a " .. ClassName(c.class) .. "'s list", ORANGE)
        end
        return text
    end
    local text = label .. "  ·  " .. Plural(#p.items, "item")
    if p.class and p.class ~= MyClass() then
        text = text .. "  ·  " .. Tint("this set is for a " .. ClassName(p.class), ORANGE)
    end
    return text
end

local function UnplacedTooltip(owner, plan)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:AddLine("Not placed", 1, 0.82, 0)
    GameTooltip:AddLine("Add these yourself if you want them (click a slot in My BiS).", 1, 1, 1, true)
    for _, u in ipairs(plan.unplaced) do
        local why = Imp().WHY[u.why] or u.why or "?"
        if u.why == "full" and u.sid then why = SlotLabel(u.sid) .. " already has a main and an alt pick" end
        GameTooltip:AddDoubleLine(UI():ItemText(u.id), why, 1, 1, 1, 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

local function PreviewData(plan)
    local rows, fill, replace = Imp():Preview(plan, state.phase)
    local data = {}
    local both = plan and plan.lists.ms and plan.lists.os
    local lastList
    for _, r in ipairs(rows) do
        if both and r.list ~= lastList then
            data[#data + 1] = { header = true, text = r.list == "os" and "Off spec" or "Main spec" }
            lastList = r.list
        end
        data[#data + 1] = r
    end
    return data, fill, replace
end

local function InitPreviewRow(row, d)
    local ui = UI()
    if not row.cdlInit then
        row.cdlInit = true
        row.head = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.head:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.slot = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.slot:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
        row.slot:SetWidth(76)
        row.slot:SetJustifyH("LEFT")
        row.slot:SetWordWrap(false)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(22, 22)
        row.icon:SetPoint("LEFT", row, "LEFT", 84, 0)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 112, -4)
        row.name:SetWidth(246)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.alt = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.alt:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
        row.alt:SetWidth(246)
        row.alt:SetJustifyH("LEFT")
        row.alt:SetWordWrap(false)
        row.now = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.now:SetPoint("TOPLEFT", row, "TOPLEFT", 366, -4)
        row.now:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.now:SetJustifyH("LEFT")
        row.now:SetWordWrap(false)
        row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.note:SetPoint("TOPLEFT", row.now, "BOTTOMLEFT", 0, -3)
        row.note:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.note:SetJustifyH("LEFT")
        row.note:SetWordWrap(false)
        row.line = row:CreateTexture(nil, "BACKGROUND")
        row.line:SetPoint("BOTTOMLEFT", 4, 0)
        row.line:SetPoint("BOTTOMRIGHT", -4, 0)
        row.line:SetHeight(1)
        row.line:SetColorTexture(1, 1, 1, 0.06)
        row:SetScript("OnEnter", function(self)
            local data = self.__cdlData
            if data and not data.header then
                local id = (data.main ~= 0 and data.main) or data.nowMain
                if id and id ~= 0 then ui:SetItemTooltip(self, id) end
            end
        end)
        row:SetScript("OnLeave", function() ui:HideTooltip() end)
    end
    local header = d.header and true or false
    row.head:SetShown(header)
    for _, r in ipairs({ row.slot, row.icon, row.name, row.alt, row.now, row.note }) do r:SetShown(not header) end
    if header then
        row.head:SetText(d.text)
        return
    end
    row.slot:SetText(SlotLabel(d.sid))
    if d.main ~= 0 then
        row.icon:SetTexture(ns.ItemDB:GetIcon(d.main))
        row.icon:SetDesaturated(d.state == "disabled")
        row.name:SetText(ui:ItemText(d.main))
        row.alt:SetText(d.alt ~= 0 and ("Alt: " .. ui:ItemText(d.alt)) or "")
    else
        row.icon:SetTexture(ui:EmptySlotTexture(d.sid))
        row.icon:SetDesaturated(true)
        row.name:SetText(Tint("Not in the import", GREY))
        row.alt:SetText("")
    end
    local now, note = "", ""
    if d.state == "new" then
        now = Tint("Empty", GREEN)
    elseif d.state == "same" then
        now = Tint("Same", GREY)
    elseif d.state == "disabled" then
        now = d.nowMain ~= 0 and ui:ItemText(d.nowMain) or Tint("Empty", GREY)
        note = "Slot disabled in " .. PL(state.phase) .. ": skipped"
    else
        now = d.nowMain ~= 0 and ui:ItemText(d.nowMain) or Tint("Empty", GREY)
        if d.state == "clear" then
            note = Tint("Replace empties it", ORANGE)
        elseif d.nowAlt ~= 0 then
            note = "Alt: " .. ui:ItemText(d.nowAlt)
        end
    end
    row.now:SetText(now)
    row.note:SetText(note)
end

local function PhaseOptions()
    local out = {}
    for _, p in ipairs(ns.LIST_PHASES or { 1, 2, 3, 4, 5 }) do
        local info = ns.PHASE_INFO and ns.PHASE_INFO[p]
        out[#out + 1] = { value = p, text = PL(p), tooltip = info and info.raids or nil }
    end
    return out
end

local function ListOptions()
    return {
        { value = "ms", text = "Main spec" },
        { value = "os", text = HasOffSpec() and "Off spec" or "Off spec (new)" },
    }
end

local function BuildCharacterMenu(root)
    local p = state.parsed
    if not (p and p.format == "tmb") then return end
    if root.SetScrollMode then root:SetScrollMode(360) end
    root:CreateTitle("Whose wishlist?")
    for _, name in ipairs(p.characters) do
        local c = p.byChar[name]
        local text = name .. "  |cff808080" .. #c.items .. "|r"
        root:CreateRadio(text, function(v) return state.character == v end, function(v)
            state.character = v
            state.done = nil
            Win:RefreshImport()
        end, name)
    end
end

local CONFIRM = "DISASTERZONE_IMPORT_REPLACE"
local function EnsurePopup()
    if StaticPopupDialogs[CONFIRM] then return end
    StaticPopupDialogs[CONFIRM] = {
        text = "Replace every pick in %s with the imported list?",
        button1 = YES or "Yes",
        button2 = NO or "No",
        OnAccept = function() Win:Apply(true) end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

-- The lists Replace changes, for the popup: "P2", "P2 (off spec)" or "P2 (main and off spec)" ("Pre-raid ...").
local function ReplaceTarget(plan)
    local ms, os = plan and plan.lists.ms, plan and plan.lists.os
    if ms and os then return PL(state.phase) .. " (main and off spec)" end
    if os then return PL(state.phase) .. " (off spec)" end
    return PL(state.phase)
end

local function PhaseHasPicks(plan)
    for _, list in ipairs({ "ms", "os" }) do
        if plan.lists[list] then
            for sid = 1, NUM_SLOTS do
                local m, a = BiS():GetSlot(state.phase, sid, list == "os" and "os" or nil)
                if m or a then return true end
            end
        end
    end
    return false
end

local function CreateImportPane(parent)
    local ui = UI()
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)

    p.hint = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.hint:SetPoint("TOPLEFT", p, "TOPLEFT", 8, -4)
    p.hint:SetPoint("RIGHT", p, "RIGHT", -150, 0)
    p.hint:SetJustifyH("LEFT")
    p.hint:SetText("Paste a list from That's My BiS, Sixty Upgrades, WoWSims, a Wowhead gear planner link, or "
        .. "item links. Nothing changes until you click Fill or Replace.")

    p.where = CreateFrame("Button", nil, p)
    p.where:SetPoint("TOPRIGHT", p, "TOPRIGHT", -8, -4)
    p.where.fs = p.where:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.where.fs:SetPoint("RIGHT")
    p.where.fs:SetText("Where do I copy it?")
    p.where:SetSize((p.where.fs:GetStringWidth() or 110) + 4, 16)
    p.where:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("Where to copy it", 1, 0.82, 0)
        for _, l in ipairs(WHERE_LINES) do
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(l[1], 1, 0.82, 0)
            GameTooltip:AddLine(l[2], 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    p.where:SetScript("OnLeave", function() GameTooltip:Hide() end)

    p.box = CreateTextBox(p, 90)
    p.box:SetPoint("TOPLEFT", p, "TOPLEFT", 6, -34)
    p.box:SetPoint("TOPRIGHT", p, "TOPRIGHT", -6, -34)
    local eb = p.box.eb
    eb:SetMaxBytes(MAX_SHOWN)
    eb:SetScript("OnChar", function(_, c)
        local now = GetTime()
        if burstAt ~= now then burst, burstN, burstAt = {}, 0, now end
        burstN = burstN + 1
        burst[burstN] = c
        p.driver:Show()
    end)
    eb:SetScript("OnTextChanged", function(_, userInput)
        if userInput then p.driver:Show() end
    end)
    ui:SetEditPlaceholder(eb, "Paste here (Ctrl+V)")
    if eb.cdlHint then
        eb.cdlHint:ClearAllPoints()
        eb.cdlHint:SetPoint("TOPLEFT", eb, "TOPLEFT", 0, -1)
    end
    p.clear = ui:CreateRemoveButton(p.box, "Clear the pasted text")
    p.clear:SetPoint("TOPRIGHT", p.box, "TOPRIGHT", -2, -2)
    p.clear:SetFrameLevel(p.box.sf:GetFrameLevel() + 5)
    p.clear:SetScript("OnClick", function()
        eb:SetText("")
        eb:ClearFocus()
        Win:SetSource("")
    end)

    -- the next frame after a paste / an edit: read the whole text (see the file header)
    p.driver = CreateFrame("Frame", nil, p)
    p.driver:Hide()
    p.driver:SetScript("OnUpdate", function(self)
        self:Hide()
        local shown = eb:GetText() or ""
        local text = shown
        if burstN > 0 then
            local pasted = tconcat(burst, "", 1, burstN)
            if #pasted > #shown then text = pasted end   -- the box shows only the start of a big paste
        end
        burst, burstN, burstAt = {}, 0, nil
        Win:SetSource(text)
    end)

    p.status = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.status:SetPoint("TOPLEFT", p.box, "BOTTOMLEFT", 2, -6)
    p.status:SetPoint("RIGHT", p, "RIGHT", -8, 0)
    p.status:SetJustifyH("LEFT")
    p.status:SetHeight(26)
    p.status:SetJustifyV("TOP")

    -- where it goes: [character] Into [P1] [Main spec]
    local rowY = -166
    p.rowY = rowY
    p.charBtn = ui:CreateSleekMenuButton(p, "", 170, BuildCharacterMenu)
    p.charBtn:SetPoint("TOPLEFT", p, "TOPLEFT", 6, rowY)
    p.into = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.into:SetText("Into")
    p.phaseDD = ui:CreateDropdown(p, 84, PhaseOptions, function() return state.phase end, function(v)
        state.phase = tonumber(v) or 1
        state.done = nil
        Win:RefreshImport()
    end)
    p.listDD = ui:CreateDropdown(p, 120, ListOptions, function() return state.list end, function(v)
        state.list = (v == "os") and "os" or "ms"
        state.done = nil
        Win:RefreshImport()
    end)
    p.listDD:SetPoint("LEFT", p.phaseDD, "RIGHT", 6, 0)
    p.osNote = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.osNote:SetPoint("LEFT", p.phaseDD, "RIGHT", 10, 0)
    p.osNote:SetText("Off-spec items go to your off-spec list")

    p.header = ui:CreateColumnHeader(p, 18)
    p.header:SetPoint("TOPLEFT", p, "TOPLEFT", 4, rowY - 30)
    p.header:SetPoint("TOPRIGHT", p, "TOPRIGHT", -24, rowY - 30)
    p.header:AddColumn("Slot", 6, 70)
    p.header:AddColumn("Imported", 112, 240)
    p.nowCol = p.header:AddColumn("Now in P1", 366, 150)

    p.list = ui:CreateScrollList(p, ROW_H, InitPreviewRow, function(d) return d.header and HEADER_ROW_H or ROW_H end)
    p.list.frame:SetPoint("TOPLEFT", p, "TOPLEFT", 4, rowY - 50)
    p.list.frame:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -4, 64)
    p.list:SetEmptyText("")

    p.received = ui:CreateCheckbox(p, "", function() return state.markReceived end, function(v)
        state.markReceived = v and true or false
    end)
    p.received:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 4, 36)

    p.unplaced = CreateFrame("Button", nil, p)
    p.unplaced:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -8, 40)
    p.unplaced:SetHeight(16)
    p.unplaced.fs = p.unplaced:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.unplaced.fs:SetPoint("RIGHT")
    p.unplaced:SetScript("OnEnter", function(self) if self.plan then UnplacedTooltip(self, self.plan) end end)
    p.unplaced:SetScript("OnLeave", function() GameTooltip:Hide() end)

    p.replace = ui:CreateButton(p, "Replace P1", 130, 24, function()
        local plan = ImportPlan()
        if not plan then return end
        if PhaseHasPicks(plan) then
            EnsurePopup()
            StaticPopup_Show(CONFIRM, ReplaceTarget(plan))
        else
            Win:Apply(true)
        end
    end)
    p.replace:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -8, 8)
    if p.replace.SetKind then p.replace:SetKind("primary") end
    p.fill = ui:CreateButton(p, "Fill empty slots", 130, 24, function() Win:Apply(false) end)
    p.fill:SetPoint("RIGHT", p.replace, "LEFT", -6, 0)
    for _, b in ipairs({ p.fill, p.replace }) do
        b:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            if self == p.fill then
                GameTooltip:AddLine("Fill empty slots", 1, 0.82, 0)
                GameTooltip:AddLine("Puts the import into the slots of " .. PL(state.phase) .. " that have no main pick. "
                    .. "Your other picks stay.", 1, 1, 1, true)
            else
                GameTooltip:AddLine("Replace " .. PL(state.phase), 1, 0.82, 0)
                GameTooltip:AddLine("Makes " .. PL(state.phase) .. " exactly the imported list: slots it doesn't fill "
                    .. "are emptied (disabled slots stay as they are).", 1, 1, 1, true)
            end
            if self.count then GameTooltip:AddLine(Plural(self.count, "slot") .. " change.", 0.7, 0.7, 0.7) end
            if ListLocked() then GameTooltip:AddLine("BiS lists are locked during the raid.", 1, 0.35, 0.3, true) end
            GameTooltip:Show()
        end)
        b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return p
end

function Win:RefreshImport()
    if not (win and win.import) then return end
    local p = win.import
    local parsed = state.parsed
    local tmb = parsed and parsed.format == "tmb"
    local plan = ImportPlan()

    p.status:SetText(StatusText(plan))
    p.charBtn:SetShown(tmb and true or false)
    p.charBtn:SetText(tmb and (state.character or "Pick your character") or "")
    p.into:ClearAllPoints()
    if tmb then
        p.into:SetPoint("LEFT", p.charBtn, "RIGHT", 14, 0)
    else
        p.into:SetPoint("LEFT", p, "TOPLEFT", 8, p.rowY - 11)
    end
    p.phaseDD:ClearAllPoints()
    p.phaseDD:SetPoint("LEFT", p.into, "RIGHT", 6, 0)
    p.phaseDD:Refresh()
    -- where it goes: only once there is something to import
    p.into:SetShown(parsed ~= nil)
    p.phaseDD:SetShown(parsed ~= nil)
    p.listDD:SetShown(parsed ~= nil and not tmb)
    p.listDD:Refresh()
    p.osNote:SetShown(tmb and plan and plan.lists.os and true or false)
    p.nowCol.label:SetText("Now in " .. PL(state.phase))

    local data, fill, replace = {}, 0, 0
    if plan then data, fill, replace = PreviewData(plan) end
    p.header:SetShown(#data > 0)
    p.list:SetData(data, true)
    if parsed and plan and #data == 0 then
        p.list:SetEmptyText(tmb and not state.character and "Pick your character above."
            or "Nothing on this list fits a slot.")
    else
        p.list:SetEmptyText("")
    end

    local nReceived = plan and #plan.received or 0
    p.received:SetShown(nReceived > 0)
    p.received:SetLabel("Mark " .. Plural(nReceived, "received item") .. " as obtained")
    p.received:Refresh()

    local nUnplaced = plan and #plan.unplaced or 0
    p.unplaced.plan = plan
    p.unplaced:SetShown(nUnplaced > 0)
    p.unplaced.fs:SetText(Tint(Plural(nUnplaced, "item") .. " not placed", ORANGE))
    p.unplaced:SetWidth((p.unplaced.fs:GetStringWidth() or 100) + 4)

    local locked = ListLocked()
    p.fill.count, p.replace.count = fill, replace
    p.fill:SetText(fill > 0 and ("Fill empty slots (" .. fill .. ")") or "Fill empty slots")
    p.replace:SetText("Replace " .. PL(state.phase) .. (replace > 0 and (" (" .. replace .. ")") or ""))
    p.fill:SetEnabled(plan ~= nil and fill > 0 and not locked)
    p.replace:SetEnabled(plan ~= nil and replace > 0 and not locked)
end

-- The whole pasted text (also for tests): parses it and refreshes the preview.
function Win:SetSource(text)
    state.source = type(text) == "string" and text or ""
    state.done = nil
    local parsed, err = Imp():Parse(state.source)
    state.parsed, state.err = parsed, err
    if parsed and parsed.format == "tmb" then
        if not (state.character and parsed.byChar[state.character]) then
            state.character = Imp():DefaultCharacter(parsed)
        end
    end
    self:RefreshImport()
end

-- Writes the import (replace: Replace, else Fill empty slots). Returns the number of slots changed or false.
function Win:Apply(replace)
    local plan = ImportPlan()
    if not plan then return false end
    local tmb = state.parsed and state.parsed.format == "tmb"
    local n = Imp():Apply(plan, state.phase, replace, tmb and state.markReceived)
    if n == false then
        self:RefreshImport()
        return false
    end
    local where = ReplaceTarget(plan)
    state.done = ("Done: %s changed in %s."):format(Plural(n, "slot"), where)
    ns:Print("Imported %s into %s (%s).", state.parsed.label, where, Plural(n, "slot") .. " changed")
    if ns.MyBiS then
        if ns.MyBiS.SetPhase then ns.MyBiS:SetPhase(state.phase, true) end
        if ns.MyBiS.SetList and not plan.lists.ms and plan.lists.os then ns.MyBiS:SetList("os") end
    end
    self:RefreshImport()
    return n
end

---------------------------------------------------------------------------
-- Export
---------------------------------------------------------------------------

local FORMATS = {
    { key = "wowsims", label = "WoWSims" },
    { key = "bulk", label = "WoWSims Bulk" },
    { key = "wowhead", label = "Wowhead link" },
}

-- text, help line
local function ExportText()
    local exp = Exp()
    local bis = state.what == "bis"
    local list = state.exList == "os" and "os" or nil
    if state.format == "bulk" then
        if not bis then return "", "A Bulk list holds BiS picks: choose BiS list above." end
        local text, n = exp:Bulk(state.exPhase, list)
        if n == 0 then return "", PL(state.exPhase) .. " has no picks yet." end
        return text, ("On wowsims.com/tbc open your spec's sim, then the Bulk tab > Import, and paste. It lists the "
            .. "%s of %s so the sim can rank them."):format(Plural(n, "main and alt pick", "main and alt picks"),
            PL(state.exPhase))
    end
    local specs, kept = nil, 0
    if bis then specs, kept = exp:PhaseSpecs(state.exPhase, list) else specs = exp:EquippedSpecs() end
    local keptText = (bis and kept > 0) and ("  " .. Plural(kept, "slot") .. " without a pick use what you wear.") or ""
    if state.format == "wowhead" then
        return exp:WowheadLink(specs), "Paste the link into your browser: Wowhead's TBC gear planner opens with these "
            .. "items and gems (enchants are left out)." .. keptText
    end
    return exp:WoWSims(specs), "On wowsims.com/tbc open your spec's sim, click Import > Addon and paste. Brings gear, "
        .. "enchants, gems, talents, race and professions." .. keptText
end

local function CreateExportPane(parent)
    local ui = UI()
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)

    p.whatLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.whatLabel:SetPoint("TOPLEFT", p, "TOPLEFT", 8, -10)
    p.whatLabel:SetWidth(44)
    p.whatLabel:SetJustifyH("LEFT")
    p.whatLabel:SetText("Export")
    p.gearBtn = ui:CreateButton(p, "Current gear", 104, 22, function() Win:SetExport("gear") end)
    p.gearBtn:SetPoint("LEFT", p.whatLabel, "RIGHT", 4, 0)
    p.bisBtn = ui:CreateButton(p, "BiS list", 80, 22, function() Win:SetExport("bis") end)
    p.bisBtn:SetPoint("LEFT", p.gearBtn, "RIGHT", 4, 0)
    p.phaseDD = ui:CreateDropdown(p, 84, PhaseOptions, function() return state.exPhase end, function(v)
        state.exPhase = tonumber(v) or 1
        Win:RefreshExport()
    end)
    p.phaseDD:SetPoint("LEFT", p.bisBtn, "RIGHT", 10, 0)
    p.listDD = ui:CreateDropdown(p, 110, function()
        return { { value = "ms", text = "Main spec" }, { value = "os", text = "Off spec" } }
    end, function() return state.exList end, function(v)
        state.exList = (v == "os") and "os" or "ms"
        Win:RefreshExport()
    end)
    p.listDD:SetPoint("LEFT", p.phaseDD, "RIGHT", 6, 0)

    p.forLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.forLabel:SetPoint("TOPLEFT", p, "TOPLEFT", 8, -40)
    p.forLabel:SetWidth(44)
    p.forLabel:SetJustifyH("LEFT")
    p.forLabel:SetText("For")
    p.formatBtns = {}
    local prev
    for _, f in ipairs(FORMATS) do
        local b = ui:CreateButton(p, f.label, nil, 22, function() Win:SetExport(nil, f.key) end)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("LEFT", p.forLabel, "RIGHT", 4, 0) end
        b.key = f.key
        p.formatBtns[#p.formatBtns + 1] = b
        prev = b
    end

    p.help = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.help:SetPoint("TOPLEFT", p, "TOPLEFT", 8, -68)
    p.help:SetPoint("RIGHT", p, "RIGHT", -8, 0)
    p.help:SetHeight(40)
    p.help:SetJustifyH("LEFT")
    p.help:SetJustifyV("TOP")

    p.box = CreateTextBox(p, 200)
    p.box:SetPoint("TOPLEFT", p, "TOPLEFT", 6, -112)
    p.box:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -6, 34)
    local eb = p.box.eb
    -- read only: typing puts the export back
    eb:SetScript("OnTextChanged", function(self, userInput)
        if userInput and self:GetText() ~= (p.text or "") then
            self:SetText(p.text or "")
            self:HighlightText()
        end
    end)

    p.copy = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.copy:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 8, 12)
    p.copy:SetText("The text is selected: press Ctrl+C to copy it.")
    p.select = ui:CreateButton(p, "Select all", 90, 22, function()
        eb:SetFocus()
        eb:HighlightText()
    end)
    p.select:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -8, 6)
    return p
end

-- A Bulk list only holds BiS picks: choosing Current gear switches it to WoWSims, choosing Bulk switches to BiS list.
function Win:SetExport(what, format)
    if what then
        state.what = (what == "bis") and "bis" or "gear"
        if state.what == "gear" and state.format == "bulk" then state.format = "wowsims" end
    end
    if format then
        state.format = format
        if format == "bulk" then state.what = "bis" end
    end
    self:RefreshExport()
end

function Win:RefreshExport()
    if not (win and win.export) then return end
    local p = win.export
    local bis = state.what == "bis"
    p.gearBtn:SetKind(bis and "secondary" or "chosen")
    p.bisBtn:SetKind(bis and "chosen" or "secondary")
    if state.exList == "os" and not HasOffSpec() then state.exList = "ms" end
    p.phaseDD:SetShown(bis)
    p.listDD:SetShown(bis and HasOffSpec())
    p.phaseDD:Refresh()
    p.listDD:Refresh()
    for _, b in ipairs(p.formatBtns) do b:SetKind(b.key == state.format and "chosen" or "secondary") end
    local text, help = ExportText()
    p.text = text
    p.help:SetText(help or "")
    p.box.eb:SetText(text)
    p.copy:SetShown(text ~= "")
    p.select:SetEnabled(text ~= "")
    if text ~= "" and p:IsVisible() then
        p.box.eb:SetFocus()
        p.box.eb:HighlightText()
    end
end

-- The export text shown now (for tests).
function Win:GetExportText()
    return win and win.export and win.export.text or nil
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function Create()
    local ui = UI()
    win = ui:CreateWindow("DisasterZoneImportExport", "Import / Export BiS list", W, H)
    local c = win.content
    win.tabs = {}
    local prev
    for _, t in ipairs({ { "import", "Import" }, { "export", "Export" } }) do
        local b = ui:CreateUnderlineTab(c, t[2], function() Win:SetTab(t[1]) end)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", c, "TOPLEFT", 6, -2) end
        b.key = t[1]
        win.tabs[#win.tabs + 1] = b
        prev = b
    end
    local body = CreateFrame("Frame", nil, c)
    body:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -28)
    body:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 0)
    win.body = body
    win.import = CreateImportPane(body)
    win.export = CreateExportPane(body)
    win:SetScript("OnHide", function()
        if win.import then win.import.box.eb:ClearFocus() end
        if win.export then win.export.box.eb:ClearFocus() end
    end)
    win:Hide()
end

function Win:SetTab(tab)
    state.tab = (tab == "export") and "export" or "import"
    if not win then return end
    for _, b in ipairs(win.tabs) do b:SetActive(b.key == state.tab) end
    win.import:SetShown(state.tab == "import")
    win.export:SetShown(state.tab == "export")
    if state.tab == "import" then self:RefreshImport() else self:RefreshExport() end
end

-- tab: "import" | "export". Starts on the phase and list My BiS shows.
function Win:Open(tab)
    if not win then Create() end
    local mb = ns.MyBiS
    local phase = mb and mb.GetPhase and mb:GetPhase() or 1
    local list = mb and mb.GetList and mb:GetList() or "ms"
    state.phase, state.exPhase = phase, phase
    state.list, state.exList = list, list
    state.done = nil
    win:Show()
    win:Raise()
    self:SetTab(tab or state.tab)
end

function Win:Close()
    if win then win:Hide() end
end

function Win:IsOpen()
    return win ~= nil and win:IsShown()
end

function Win:GetFrame()
    return win
end

-- For tests: the import state and the preview rows.
function Win:GetImportState()
    return state
end

function Win:GetPreviewRows()
    return win and win.import and win.import.list:GetData() or {}
end

local function RefreshOpen()
    if not Win:IsOpen() then return end
    if state.tab == "import" then Win:RefreshImport() else Win:RefreshExport() end
end

ns:On("MYLIST_CHANGED", function() if Win:IsOpen() and state.tab == "import" then Win:RefreshImport() end end)
ns:On("ITEMINFO_READY", function()
    if Win:IsOpen() and state.tab == "import" and win.import then win.import.list:Refresh() end
end)
ns:On("BIS_LOCK_CHANGED", RefreshOpen)
ns:On("GROUP_RULES_CHANGED", RefreshOpen)

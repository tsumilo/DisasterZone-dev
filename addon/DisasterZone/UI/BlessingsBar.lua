if DisasterZoneBoot and DisasterZoneBoot.Run("UI/BlessingsBar.lua", ...) then return end -- DisasterZone: blessings bar.
-- The paladin's buff bar for the Blessings planner (Core/Blessings.lua), shown in a party or raid:
--   top row   my aura (click casts it), Righteous Fury for Protection (click casts it), Symbols of Kings in my bags,
--             the planner (click opens it)
--   rows      one per class I bless: the class, my blessing for it, the time left (the class's lowest) or how many
--             are missing it, and how many have it. Click casts the Greater Blessing on a class member in range;
--             right-click opens the class's players (click: their blessing, right-click: the single one).
--   gold edge the row to do next: someone missing it, else the one running out first
-- Every cast is a secure button whose target is chosen out of combat (WoW forbids changing them in combat): in a
-- fight the bar dims and keeps its targets, and catches up as soon as the fight ends. Key binding: "Bless next".
local addonName, ns = ...

local Bar = ns:NewModule("BlessingsBar")

local floor, max, min = math.floor, math.max, math.min
local strformat = string.format

local W, ROW_H, ROW_GAP, HEAD_H, POP_W = 156, 23, 3, 30, 178
local WHITE8 = "Interface\\Buttons\\WHITE8X8"
local CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
local GOLD = { 1, 0.82, 0 }

local function B() return ns.Blessings end
local function UI() return ns.UI end

local frame, rows, pop, nextBtn
local dirty = false

local function Text(parent, size, color, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    local path, _, flags = fs:GetFont()
    if path and size then fs:SetFont(path, size, flags) end
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 1)
    return fs
end

local function Fill(tex, r, g, b, a)
    tex:SetTexture(WHITE8)
    tex:SetVertexColor(r, g, b, a or 1)
    return tex
end

local function Edge(f, r, g, b, a)
    if not f.edges then UI():AddEdges(f) end
    UI():SetEdgeColor(f, r, g, b, a)
end

local function Secure(parent, name)
    local b = CreateFrame("Button", name, parent, "SecureActionButtonTemplate")
    b:RegisterForClicks("AnyUp")
    return b
end

local function Minutes(left)
    if not left then return "" end
    if left >= 60 then return strformat("%dm", floor(left / 60)) end
    return strformat("%ds", floor(left))
end

-- Is the bar for me now: a paladin (the class tool), in a group the setting allows, with an aura or a blessing to give?
function Bar:Wanted()
    if not (ns.ClassKit and ns.ClassKit:IsMine("bless")) then return false end
    local mode = B().Setting("bar", "group")
    if mode == "off" then return false end
    if mode == "raid" and not IsInRaid() then return false end
    if not B():InGroup() then return false end
    local me = B():Me()
    if not me then return false end
    if B():GetAura(me) then return true end
    for ci = 1, #B().D.CLASSES do
        if B():GetAssign(me, ci) or next(B():GetSingles(me)[ci] or {}) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------------------------------------------
local function SavePos()
    local point, _, rel, x, y = frame:GetPoint(1)
    if point then ns.DB:SetSetting("bless.pos", { point, rel, floor(x + 0.5), floor(y + 0.5) }) end
end

local function RestorePos()
    frame:ClearAllPoints()
    local pos = B().Setting("pos")
    if type(pos) == "table" and pos[1] then
        frame:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3] or 0, pos[4] or 0)
    else
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -260, 60)
    end
end

local function NewRow(i)
    local r = Secure(frame, "DisasterZoneBlessRow" .. i)
    r:SetSize(W - 8, ROW_H)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bg:SetTexture(WHITE8)
    Edge(r, 0.17, 0.17, 0.19, 1)
    r.cls = r:CreateTexture(nil, "ARTWORK")
    r.cls:SetSize(19, 19)
    r.cls:SetPoint("LEFT", r, "LEFT", 3, 0)
    r.cls:SetTexture(CIRCLES)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(19, 19)
    r.icon:SetPoint("LEFT", r.cls, "RIGHT", 5, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.state = Text(r, 11.5)
    r.state:SetPoint("LEFT", r.icon, "RIGHT", 7, 0)
    r.count = Text(r, 10.5, { 0.55, 0.55, 0.58 })
    r.count:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    r.count:SetJustifyH("RIGHT")
    r:SetAttribute("type1", "spell")
    r:RegisterForClicks("AnyUp")
    r:SetScript("PostClick", function(self, button)
        if button == "RightButton" and not InCombatLockdown() then Bar:TogglePop(self) end
    end)
    r:HookScript("OnEnter", function(self) Bar:RowTip(self) end)
    r:HookScript("OnLeave", function() GameTooltip:Hide() end)
    return r
end

local function NewPopRow(i)
    local p = Secure(pop, "DisasterZoneBlessPop" .. i)
    p:SetSize(POP_W - 8, 22)
    p:SetPoint("TOPLEFT", pop, "TOPLEFT", 4, -(22 + (i - 1) * 23))
    p.hl = p:CreateTexture(nil, "HIGHLIGHT")
    p.hl:SetAllPoints()
    Fill(p.hl, 1, 0.82, 0, 0.08)
    p.icon = p:CreateTexture(nil, "ARTWORK")
    p.icon:SetSize(17, 17)
    p.icon:SetPoint("LEFT", p, "LEFT", 4, 0)
    p.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    p.name = Text(p, 11.5)
    p.name:SetPoint("LEFT", p.icon, "RIGHT", 7, 0)
    p.state = Text(p, 10, { 0.62, 0.62, 0.64 })
    p.state:SetPoint("RIGHT", p, "RIGHT", -4, 0)
    p.state:SetJustifyH("RIGHT")
    p:SetAttribute("type1", "spell")
    p:SetAttribute("type2", "spell")
    p:RegisterForClicks("AnyUp")
    return p
end

local function Build()
    frame = CreateFrame("Frame", "DisasterZoneBlessBar", UIParent, "BackdropTemplate")
    frame:SetSize(W, HEAD_H + 8)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame.bg = Fill(frame:CreateTexture(nil, "BACKGROUND"), 0.055, 0.055, 0.065, 0.88)
    frame.bg:SetAllPoints()
    Edge(frame, 0.23, 0.23, 0.25, 1)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not B().Setting("locked", true) and not InCombatLockdown() then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePos()
    end)
    RestorePos()

    -- top row: aura, Righteous Fury, Symbols, planner
    local aura = Secure(frame, "DisasterZoneBlessAura")
    aura:SetSize(20, 20)
    aura:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -5)
    aura.icon = aura:CreateTexture(nil, "ARTWORK")
    aura.icon:SetAllPoints()
    aura.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    Edge(aura, 0, 0, 0, 1)
    aura:SetAttribute("type", "spell")
    aura:SetAttribute("unit", "player")
    aura:HookScript("OnEnter", function(self)
        local ai = B():GetAura(B():Me())
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(ai and B():AuraName(ai) or "No aura assigned")
        GameTooltip:AddLine(self.on and "On" or "Click to turn it on", 0.85, 0.85, 0.85)
        GameTooltip:Show()
    end)
    aura:HookScript("OnLeave", function() GameTooltip:Hide() end)
    frame.aura = aura

    local rf = Secure(frame, "DisasterZoneBlessRF")
    rf:SetSize(20, 20)
    rf:SetPoint("LEFT", aura, "RIGHT", 4, 0)
    rf.icon = rf:CreateTexture(nil, "ARTWORK")
    rf.icon:SetAllPoints()
    rf.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    rf.icon:SetTexture(B().D.RF_ICON)
    Edge(rf, 0, 0, 0, 1)
    rf:SetAttribute("type", "spell")
    rf:SetAttribute("unit", "player")
    rf:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(GetSpellInfo(B().D.RIGHTEOUS_FURY) or "Righteous Fury")
        GameTooltip:AddLine(self.on and "On" or "Off: click to cast it", 0.85, 0.85, 0.85)
        GameTooltip:Show()
    end)
    rf:HookScript("OnLeave", function() GameTooltip:Hide() end)
    frame.rf = rf

    local planner = CreateFrame("Button", nil, frame)
    planner:SetSize(18, 18)
    planner:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)
    planner.icon = planner:CreateTexture(nil, "ARTWORK")
    planner.icon:SetAllPoints()
    planner.icon:SetTexture(UI().ICON_ATLAS)
    local cc = UI():IconCoords(UI().ICON.notes)
    planner.icon:SetTexCoord(cc[1], cc[2], cc[3], cc[4])
    planner.icon:SetVertexColor(0.75, 0.75, 0.78)
    planner:SetScript("OnClick", function() if ns.BlessingsUI then ns.BlessingsUI:Toggle() end end)
    planner:SetScript("OnEnter", function(self)
        self.icon:SetVertexColor(1, 0.82, 0)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Blessings planner")
        if not B().Setting("locked", true) then GameTooltip:AddLine("Drag the bar to move it.", 0.85, 0.85, 0.85) end
        GameTooltip:Show()
    end)
    planner:SetScript("OnLeave", function(self)
        self.icon:SetVertexColor(0.75, 0.75, 0.78)
        GameTooltip:Hide()
    end)

    frame.sym = frame:CreateTexture(nil, "ARTWORK")
    frame.sym:SetSize(18, 18)
    frame.sym:SetPoint("RIGHT", planner, "LEFT", -34, 0)
    frame.sym:SetTexture(B().D.SYMBOL_ICON)
    frame.sym:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    frame.symN = Text(frame, 11.5)
    frame.symN:SetPoint("LEFT", frame.sym, "RIGHT", 4, 0)

    -- the next blessing to cast (the key binding clicks it)
    nextBtn = Secure(frame, "DisasterZoneBlessNext")
    nextBtn:SetSize(1, 1)
    nextBtn:SetPoint("TOPLEFT")
    nextBtn:RegisterForClicks("AnyUp", "AnyDown")
    nextBtn:SetAttribute("type", "spell")
    nextBtn:SetScript("PreClick", function(self, _, down)
        if InCombatLockdown() then return end
        local useDown = GetCVarBool and GetCVarBool("ActionButtonUseKeyDown")
        if (down and true or false) ~= (useDown and true or false) then
            self:SetAttribute("spell", nil)
            return
        end
        local spell, unit = Bar:NextCast()
        if B():IsDemo() then spell, unit = nil, nil end
        self:SetAttribute("spell", spell)
        self:SetAttribute("unit", unit)
    end)
    nextBtn:SetScript("PostClick", function(self)
        if InCombatLockdown() then return end
        self:SetAttribute("spell", nil)
        self:SetAttribute("unit", nil)
    end)

    rows = {}
    pop = CreateFrame("Frame", "DisasterZoneBlessPopout", UIParent)
    pop:SetSize(POP_W, 40)
    pop:SetFrameStrata("DIALOG")
    pop.bg = Fill(pop:CreateTexture(nil, "BACKGROUND"), 0.075, 0.075, 0.085, 0.97)
    pop.bg:SetAllPoints()
    Edge(pop, 0.27, 0.27, 0.3, 1)
    pop.title = Text(pop, 9.5, { 0.62, 0.62, 0.64 })
    pop.title:SetPoint("TOPLEFT", pop, "TOPLEFT", 8, -6)
    pop.rows = {}
    pop:Hide()

    local acc = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc >= 1 then
            acc = 0
            Bar:Update()
        end
    end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- What to cast
-- ---------------------------------------------------------------------------------------------------------------
-- A member of the class to cast a Greater on: someone missing it first, in range, alive, level 50+.
local function GreaterTarget(members, greaterName, bi)
    local best, bestScore
    for _, m in ipairs(members) do
        if m.online and not m.dead and (m.level or 70) >= B().D.GREATER_MIN_LEVEL and (m.demo or UnitIsVisible(m.unit)) then
            local inRange = m.demo or not greaterName or not IsSpellInRange or IsSpellInRange(greaterName, m.unit) ~= 0
            if inRange then
                local left = B():BuffLeft(m.unit, bi) or 0
                local score = left - (m.pet and 1 or 0)
                if not bestScore or score < bestScore then best, bestScore = m, score end
            end
        end
    end
    return best
end

-- My rows: { ci, bi, members, state, unit, greaterName }, in the planner's class order.
function Bar:MyRows()
    local Bl = B()
    local me = Bl:Me()
    local out = {}
    if not me then return out end
    local byClass = Bl:ByClass()
    for _, cls in ipairs(Bl.D.DISPLAY) do
        local ci = Bl.CLASS_INDEX[cls]
        local bi = Bl:GetAssign(me, ci)
        local singles = Bl:GetSingles(me)[ci]
        if (bi or (singles and next(singles))) and #byClass[ci] > 0 then
            local st = Bl:ClassState(me, ci, byClass)
            local gname = bi and Bl:BlessingName(bi, true)
            local t = bi and GreaterTarget(byClass[ci], gname, bi)
            out[#out + 1] = { ci = ci, cls = cls, bi = bi, members = byClass[ci], state = st, unit = t and t.unit,
                greaterName = gname }
        end
    end
    return out
end

-- The row to do next: someone missing their blessing, else the one running out first (under the warning time).
function Bar:Urgent(list)
    local warn = (tonumber(B().Setting("warnMin", 5)) or 5) * 60
    local best, bestKey
    for _, r in ipairs(list) do
        local key
        if #r.state.missing > 0 then key = -1000 + (r.state.left or 0) / 10000
        elseif r.state.left and r.state.left < warn then key = r.state.left end
        if key and (not bestKey or key < bestKey) then best, bestKey = r, key end
    end
    return best
end

-- spell, unit for the "Bless next" key: a missing single blessing first, else the urgent class's Greater.
function Bar:NextCast()
    local Bl = B()
    local list = self:MyRows()
    local me = Bl:Me()
    for _, r in ipairs(list) do
        for _, m in ipairs(r.state.missing) do
            local sbi = Bl:GetSingle(me, r.ci, m.name)
            if sbi and UnitIsVisible(m.unit) then return Bl:BlessingName(sbi), m.unit end
        end
    end
    local u = self:Urgent(list)
    if u and u.unit then return u.greaterName, u.unit end
    return nil, nil
end

-- ---------------------------------------------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------------------------------------------
function Bar:Update()
    if not frame then
        if not self:Wanted() then return end
        Build()
    end
    local combat = InCombatLockdown()
    if not self:Wanted() then
        if combat then dirty = true return end
        frame:Hide()
        return
    end
    local Bl = B()
    local me = Bl:Me()
    local list = self:MyRows()
    local urgent = self:Urgent(list)

    -- what changes the secure buttons (targets, spells, rows) waits for the end of a fight
    if not combat then
        frame:SetScale(tonumber(Bl.Setting("scale", 1)) or 1)
        local ai = Bl:GetAura(me)
        frame.aura:SetAttribute("spell", ai and Bl:AuraName(ai) or nil)
        frame.aura:SetShown(ai ~= nil)
        local hasRF = IsSpellKnown and IsSpellKnown(Bl.D.RIGHTEOUS_FURY)
        local prot = Bl:SpecOf(me) == "Protection"
        frame.rf:SetAttribute("spell", (hasRF and prot) and GetSpellInfo(Bl.D.RIGHTEOUS_FURY) or nil)
        frame.rf:SetShown(hasRF and prot or false)
        if not frame.aura:IsShown() then
            frame.rf:ClearAllPoints()
            frame.rf:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -5)
        else
            frame.rf:ClearAllPoints()
            frame.rf:SetPoint("LEFT", frame.aura, "RIGHT", 4, 0)
        end
        for i, r in ipairs(list) do
            local row = rows[i] or NewRow(i)
            rows[i] = row
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -(HEAD_H + (i - 1) * (ROW_H + ROW_GAP)))
            -- (demo mode: nothing to cast on)
            local real = r.unit and not Bl:IsDemo()
            row:SetAttribute("spell1", real and r.greaterName or nil)
            row:SetAttribute("unit1", real and r.unit or nil)
            row.data = r
            row:Show()
        end
        for i = #list + 1, #rows do
            rows[i]:Hide()
            rows[i].data = nil
        end
        frame:SetHeight(HEAD_H + max(0, #list) * (ROW_H + ROW_GAP) + 4)
        frame:Show()
        dirty = false
    end

    -- looks (safe in combat)
    frame:SetAlpha(combat and 0.75 or 1)
    local ai = Bl:GetAura(me)
    if ai then
        frame.aura.icon:SetTexture(Bl:AuraIcon(ai))
        local on = false
        for i = 1, 40 do
            local name, _, _, _, _, _, _, _, _, id = UnitAura("player", i, "HELPFUL")
            if not name then break end
            if id and Bl.AURA_BY_ID[id] == ai then on = true break end
        end
        frame.aura.on = on
        frame.aura.icon:SetDesaturated(not on)
        Edge(frame.aura, on and 0 or 0.88, on and 0 or 0.38, on and 0 or 0.31, 1)
    end
    if frame.rf:IsShown() then
        local on = false
        local rfName = GetSpellInfo(Bl.D.RIGHTEOUS_FURY)
        for i = 1, 40 do
            local name, _, _, _, _, _, _, _, _, id = UnitAura("player", i, "HELPFUL")
            if not name then break end
            if id == Bl.D.RIGHTEOUS_FURY or (rfName and name == rfName) then on = true break end
        end
        frame.rf.on = on
        frame.rf.icon:SetDesaturated(not on)
    end
    local p = me and Bl.pals[me]
    local n = GetItemCount and GetItemCount(Bl.D.SYMBOL_OF_KINGS) or (p and p.symbols) or 0
    frame.symN:SetText(n)
    local low = n < (tonumber(Bl.Setting("symbols", 20)) or 20)
    frame.symN:SetTextColor(low and 1 or 0.9, low and 0.48 or 0.9, low and 0.42 or 0.9)
    local warn = (tonumber(Bl.Setting("warnMin", 5)) or 5) * 60
    for _, row in ipairs(rows) do
        local r = row.data
        if r and row:IsShown() then
            local cr, cg, cb = UI():ClassColor(r.cls)
            if row.bg.SetGradient and CreateColor then
                row.bg:SetGradient("HORIZONTAL", CreateColor(cr * 0.35, cg * 0.35, cb * 0.35, 0.9), CreateColor(0.11, 0.11, 0.13, 0.9))
            else
                row.bg:SetVertexColor(0.12, 0.12, 0.14, 0.9)
            end
            local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[r.cls]
            if c then row.cls:SetTexCoord(c[1], c[2], c[3], c[4]) end
            row.icon:SetTexture(r.bi and Bl:BlessingIcon(r.bi, true) or Bl:BlessingIcon(1))
            local st = r.state
            if #st.missing > 0 then
                row.state:SetText(strformat("%d missing", #st.missing))
                row.state:SetTextColor(1, 0.54, 0.48)
            else
                row.state:SetText(Minutes(st.left))
                local soon = st.left and st.left < warn
                row.state:SetTextColor(soon and 1 or 0.81, soon and 0.82 or 0.81, soon and 0 or 0.83)
            end
            row.count:SetText(strformat("%d/%d", st.have, st.total))
            local isNext = urgent and urgent.ci == r.ci
            if isNext then Edge(row, 1, 0.82, 0, 1) else Edge(row, 0.17, 0.17, 0.19, 1) end
            row.icon:SetAlpha(r.unit and 1 or 0.45)
        end
    end
    if pop:IsShown() and pop.row and pop.row.data then self:FillPop(pop.row) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Popout (players of one class)
-- ---------------------------------------------------------------------------------------------------------------
function Bar:FillPop(row)
    local Bl = B()
    local r = row.data
    local me = Bl:Me()
    pop.title:SetText((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[r.cls] or r.cls):upper())
    local combat = InCombatLockdown()
    for i, m in ipairs(r.members) do
        local p = pop.rows[i]
        if not p then
            if combat then break end
            p = NewPopRow(i)
            pop.rows[i] = p
        end
        local sbi = Bl:GetSingle(me, r.ci, m.name)
        local bi = sbi or r.bi
        if not combat then
            local real = not m.demo
            p:SetAttribute("unit1", real and m.unit or nil)
            p:SetAttribute("unit2", real and m.unit or nil)
            p:SetAttribute("spell1", (real and r.bi) and Bl:BlessingName(r.bi, true) or nil)
            p:SetAttribute("spell2", (real and bi) and Bl:BlessingName(bi) or nil)
            p:Show()
        end
        p.icon:SetTexture(bi and Bl:BlessingIcon(bi, sbi == nil) or "Interface\\Icons\\INV_Misc_QuestionMark")
        local left = bi and Bl:BuffLeft(m.unit, bi)
        local cr, cg, cb = UI():ClassColor(r.cls)
        p.name:SetText(m.name .. (m.pet and " (pet)" or ""))
        p.name:SetTextColor(cr, cg, cb)
        if left then
            p.state:SetText(Minutes(left))
            p.state:SetTextColor(0.62, 0.62, 0.64)
            p.icon:SetAlpha(1)
        else
            local far = not m.demo and not UnitIsVisible(m.unit) or (IsSpellInRange and bi and IsSpellInRange(Bl:BlessingName(bi), m.unit) == 0)
            p.state:SetText(m.dead and "dead" or (not m.online and "offline") or (far and "out of range") or "missing")
            p.state:SetTextColor(0.88, 0.38, 0.31)
            p.icon:SetAlpha(0.5)
        end
    end
    if not combat then
        for i = #r.members + 1, #pop.rows do pop.rows[i]:Hide() end
        pop:SetHeight(26 + #r.members * 23)
    end
end

function Bar:TogglePop(row)
    if InCombatLockdown() then return end
    if pop:IsShown() and pop.row == row then
        pop:Hide()
        return
    end
    pop.row = row
    pop:ClearAllPoints()
    pop:SetPoint("TOPRIGHT", row, "TOPLEFT", -6, 4)
    self:FillPop(row)
    pop:Show()
end

function Bar:RowTip(row)
    local r = row.data
    if not r then return end
    local Bl = B()
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    GameTooltip:AddLine(strformat("%s · %s", LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[r.cls] or r.cls,
        r.greaterName or "single blessings"))
    for _, m in ipairs(r.state.missing) do GameTooltip:AddLine("Missing: " .. m.name, 1, 0.55, 0.45) end
    if r.unit then
        GameTooltip:AddLine("Click: cast it on " .. (GetUnitName(r.unit, true) or "?"), 0.85, 0.85, 0.85)
    elseif r.bi then
        GameTooltip:AddLine("Nobody of the class is in range", 1, 0.55, 0.45)
    end
    GameTooltip:AddLine("Right-click: the players (single blessings)", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Lifecycle, settings
-- ---------------------------------------------------------------------------------------------------------------
function Bar:OnLogin()
    ns:On("BLESSINGS_CHANGED", function() Bar:Update() end)
    ns:On("CLASSKIT_CHANGED", function() Bar:Update() end)
    ns:On("GROUP_UPDATED", function() Bar:Update() end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() Bar:Update() end)
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if pop and pop:IsShown() then pop:Hide() end
        if frame then frame:SetAlpha(0.75) end
    end)
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and path:find("^bless") and path ~= "bless.pos" then
            if frame and path == "bless.locked" and not InCombatLockdown() then RestorePos() end
            Bar:Update()
        end
    end)
    self:Update()
end

function Bar:GetFrame() return frame end

-- The kit's Settings section (UI/Settings.lua gives every class tool one; this one shows for every paladin spec).
if ns.ClassKit then ns.ClassKit:Extend("bless", {
    iconPath = "Interface\\Icons\\Spell_Magic_GreaterBlessingofKings",
    action = { label = "Open planner", run = function() if ns.BlessingsUI then ns.BlessingsUI:Open() end end },
    settings = function(S, sec)
    S:DropdownSetting(sec, "Buff bar", "Your blessings per class: click to cast, right-click for single players.",
        "bless.bar", "group", { { value = "group", text = "Party and raid" }, { value = "raid", text = "Raids only" },
            { value = "off", text = "Off" } })
    local mins = {}
    for _, n in ipairs({ 2, 3, 5, 8, 10 }) do mins[#mins + 1] = { value = n, text = n .. " minutes" } end
    S:DropdownSetting(sec, "Running out", "The bar and the planner warn this long before a blessing ends.",
        "bless.warnMin", 5, mins)
    S:SwitchSetting(sec, "Anyone may assign me", "Not only the leader and assistants (Pally Power's Free Assignment).",
        "bless.free", false)
    local syms = {}
    for _, n in ipairs({ 0, 10, 20, 40, 60, 100 }) do syms[#syms + 1] = { value = n, text = n == 0 and "Never" or tostring(n) } end
    S:DropdownSetting(sec, "Symbols of Kings", "Warn when you carry fewer than this.", "bless.symbols", 20, syms)
    S:SwitchSetting(sec, "Pets", "Hunter and warlock pets count in their class.", "bless.pets", true)
    S:SwitchSetting(sec, "Locked", "Unlock to drag the bar where you want it.", "bless.locked", true)
    local scales = {}
    for _, n in ipairs({ 0.8, 0.9, 1, 1.15, 1.3 }) do scales[#scales + 1] = { value = n, text = floor(n * 100) .. "%" } end
    S:DropdownSetting(sec, "Size", "", "bless.scale", 1, scales)
    S:EndSection(sec)
end }) end

-- Key Bindings > AddOns: "Bless next" (Bindings.xml clicks DisasterZoneBlessNext)
BINDING_HEADER_DISASTERZONE = "DisasterZone"
_G["BINDING_NAME_CLICK DisasterZoneBlessNext:LeftButton"] = "Bless next (paladin)"

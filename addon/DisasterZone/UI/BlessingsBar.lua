if DisasterZoneBoot and DisasterZoneBoot.Run("UI/BlessingsBar.lua", ...) then return end -- DisasterZone: blessings bar.
-- The paladin's buff bar for the Blessings planner (Core/Blessings.lua), shown in a party or raid when I have an aura
-- or a blessing to give. Two layouts (settings bless.layout, also in the planner's More menu; mockup
-- dev/art/casc/pally_mockup/build_bar.py):
--   "vertical"   Rail: a slim column of class circles. A ring around each drains as my blessing on the class runs
--                out (the game's cooldown swipe: nothing ticks); my blessing for them in the corner; a red count of
--                who is missing it; the class to do next glows and names itself on the left ("Priests · Wisdom ·
--                1m"). Top: my aura (gold ring = on), Righteous Fury for Protection, Symbols of Kings.
--   "horizontal" Strip: a tray of blessing tiles (the class on the corner, a hairline in the class colour that
--                shrinks with the time left); the tile to do next lifts with its time on a gold chip. Aura on the
--                left, Symbols on the right.
-- No panel behind it (only a faint one while unlocked, to drag it by).
-- Motion: the urgent look eases in and out (the strip's tile lifts and settles, the chip / label fades and drifts,
-- the hairline refills, gold blends back to calm), and a class that was missing or running out blooms once when
-- it is blessed again. All of it on the faces (not secure), so it runs in combat too.
-- Click a class: the next thing it needs, in order: the Greater (someone on it is missing it or it runs short; it goes
-- first, it overwrites single blessings), then each exception's single blessing, one per click; nothing due: the
-- Greater again. Right-click a class for its players (nothing pops up on hover): click = recast their own blessing
-- now (their single, else the Greater), right-click = the small one on them only, wheel = a single blessing
-- instead.
-- Every cast is a secure button whose target is chosen out of combat (WoW forbids changing them in combat): in a
-- fight the bar dims and keeps its targets, and catches up when the fight ends. Key binding: "Bless next".
local addonName, ns = ...

local Bar = ns:NewModule("BlessingsBar")

local floor, max, min = math.floor, math.max, math.min
local strformat = string.format

local RING = "Interface\\AddOns\\DisasterZone\\Media\\Blessings\\ring"
local SOFT = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
local WHITE8 = "Interface\\Buttons\\WHITE8X8"
local CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
local GOLD = { 1, 0.82, 0 }
local RED = { 0.91, 0.38, 0.3 }
local CALM = { 0.91, 0.89, 0.82, 0.75 }      -- a ring with time to spare
local GLASS = { 0.047, 0.047, 0.059, 0.78 }

-- geometry: rail (vertical) and strip (horizontal)
local R_S, R_GAP, R_PAD, R_HEAD = 28, 9, 9, 50
local S_T, S_GAP, S_PAD, S_SIDE = 30, 6, 12, 44
local POP_W, POP_ROW = 172, 22

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

-- A round icon the way the game makes portraits round (a mask on an icon came out in stripes on this client).
local function SetRoundIcon(tex, path)
    if tex.roundPath == path then return end
    tex.roundPath = path
    tex:SetTexture(path)
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    if SetPortraitToTexture and type(path) == "string" then
        tex:SetTexCoord(0, 1, 0, 1)
        SetPortraitToTexture(tex, path)
    end
end

-- A secure button that casts on a click. It takes the press and the release: with "cast on key down" on (the
-- client's default) the secure template acts on the press only and ignores a button that hears only releases.
local function Secure(parent, name)
    local b = CreateFrame("Button", name, parent, "SecureActionButtonTemplate")
    b:RegisterForClicks("AnyUp", "AnyDown")
    return b
end

-- (our own click handling runs once: on the release)
local function Released(down) return not down end

local function Minutes(left)
    if not left then return "" end
    if left >= 60 then return strformat("%dm", floor(left / 60)) end
    return strformat("%ds", floor(left))
end

local function Plural(cls)
    local n = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls]) or cls
    return n:sub(-1) == "f" and n or (n .. "s")
end

local function Layout()
    return B().Setting("layout", "vertical") == "horizontal" and "horizontal" or "vertical"
end
Bar.Layout = Layout

-- A small red count of who is missing it (the gold count badge, red: someone needs you).
local function MissingBadge(parent)
    local b = UI():CreateCountBadge(parent, 12)
    for _, t in ipairs(b.body or {}) do t:SetVertexColor(RED[1], RED[2], RED[3], 1) end
    if b.fs then b.fs:SetTextColor(1, 1, 1) end
    if b.SetCutout then b:SetCutout(GLASS[1], GLASS[2], GLASS[3]) end
    return b
end

-- Is the bar for me now: a paladin (the class tool), in a group the setting allows, with an aura or a blessing to give?
function Bar:Wanted()
    if not (ns.ClassKit and ns.ClassKit:IsMine("bless") and ns.ClassKit:IsOn("bless")) then return false end
    local mode = B().Setting("bar", "group")
    if mode == "off" then return false end
    if mode == "raid" and not IsInRaid() then return false end
    if mode == "always" and not B():InGroup() then return B():Me() ~= nil end   -- (solo: my own class)
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
-- (a place per layout: the rail sits right of centre, the strip over the action bars)
local function SavePos()
    local point, _, rel, x, y = frame:GetPoint(1)
    if not point then return end
    local pos = B().Setting("pos")
    pos = (type(pos) == "table" and not pos[1]) and pos or {}
    local copy = {}
    for k, v in pairs(pos) do copy[k] = v end
    copy[Layout()] = { point, rel, floor(x + 0.5), floor(y + 0.5) }
    ns.DB:SetSetting("bless.pos", copy)
end

local function RestorePos()
    frame:ClearAllPoints()
    local pos = B().Setting("pos")
    local p = type(pos) == "table" and pos[Layout()]
    if type(p) == "table" and p[1] then
        frame:SetPoint(p[1], UIParent, p[2] or p[1], p[3] or 0, p[4] or 0)
    elseif Layout() == "horizontal" then
        frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 150)
    else
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -220, 40)
    end
end

-- One class: a secure button; its looks sit on a face (moved for the strip's lift without touching the button).
local function NewRow(i)
    local r = Secure(frame, "DisasterZoneBlessRow" .. i)
    r:SetSize(R_S, R_S)
    r:SetAttribute("type1", "spell")
    r:SetScript("PreClick", function(self)
        if InCombatLockdown() or not self.data then return end
        local spell, unit = Bar:NextFor(self.data)
        if B():IsDemo() then spell, unit = nil, nil end
        self:SetAttribute("spell1", spell)
        self:SetAttribute("unit1", unit)
    end)
    local face = CreateFrame("Frame", nil, r)
    face:SetSize(R_S, R_S)
    face:SetPoint("CENTER")
    r.face = face
    face.glow = face:CreateTexture(nil, "BACKGROUND")
    face.glow:SetTexture(SOFT)
    face.glow:SetPoint("CENTER")
    face.glow:SetVertexColor(1, 0.78, 0.16, 0.55)
    face.glow:SetAlpha(0)
    -- the bloom when a class is blessed again: a ring (rail) or a soft light (strip) that opens and fades
    face.bloom = face:CreateTexture(nil, "OVERLAY", nil, 2)
    face.bloom:SetPoint("CENTER")
    face.bloom:SetBlendMode("ADD")
    face.bloom:Hide()
    -- hover: a faint white halo behind the circle (rail) / a faint light over the tile (strip)
    face.halo = face:CreateTexture(nil, "BACKGROUND", nil, 1)
    face.halo:SetTexture(SOFT)
    face.halo:SetPoint("CENTER")
    face.halo:SetBlendMode("ADD")
    face.halo:SetVertexColor(1, 1, 1)
    face.halo:SetAlpha(0)
    -- rail: the track, the draining ring (a cooldown swipe), the class circle
    face.track = face:CreateTexture(nil, "BORDER")
    face.track:SetTexture(RING)
    face.track:SetVertexColor(1, 1, 1, 0.12)
    face.cd = CreateFrame("Cooldown", nil, face, "CooldownFrameTemplate")
    face.cd:SetFrameLevel(face:GetFrameLevel() + 1)
    if face.cd.SetSwipeTexture then face.cd:SetSwipeTexture(RING) end
    if face.cd.SetDrawEdge then face.cd:SetDrawEdge(false) end
    if face.cd.SetDrawBling then face.cd:SetDrawBling(false) end
    if face.cd.SetHideCountdownNumbers then face.cd:SetHideCountdownNumbers(true) end
    if face.cd.SetUseCircularEdge then face.cd:SetUseCircularEdge(true) end
    face.cd:EnableMouse(false)
    face.top = CreateFrame("Frame", nil, face)
    face.top:SetAllPoints()
    face.top:SetFrameLevel(face:GetFrameLevel() + 3)
    face.cls = face.top:CreateTexture(nil, "ARTWORK")
    face.cls:SetTexture(CIRCLES)
    -- strip: the blessing tile and its hairline
    face.tile = face:CreateTexture(nil, "ARTWORK")
    face.tile:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    face.tileEdge = CreateFrame("Frame", nil, face)
    face.line = Fill(face:CreateTexture(nil, "ARTWORK"), 1, 1, 1, 0.1)
    face.lineFill = face:CreateTexture(nil, "OVERLAY")
    face.lineFill:SetTexture(WHITE8)
    face.sheen = face:CreateTexture(nil, "ARTWORK", nil, 3)
    face.sheen:SetTexture(WHITE8)
    face.sheen:SetBlendMode("ADD")
    face.sheen:SetVertexColor(1, 1, 1)
    face.sheen:SetAlpha(0)
    -- both: my blessing in the corner (rail) / the class in the corner (strip), the missing count
    face.corner = face.top:CreateTexture(nil, "OVERLAY")
    face.corner:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    face.cornerBox = CreateFrame("Frame", nil, face.top)
    face.miss = MissingBadge(face.top)
    face.miss:SetFrameLevel(face.top:GetFrameLevel() + 2)
    -- the urgent class: a label (rail, on the left) or a gold chip (strip, above)
    face.label = CreateFrame("Frame", nil, face)
    face.label:SetHeight(16)
    face.label.bg = Fill(face.label:CreateTexture(nil, "BACKGROUND"), GLASS[1], GLASS[2], GLASS[3], 0.9)
    face.label.bg:SetAllPoints()
    face.label.text = Text(face.label, 10, { 1, 0.9, 0.55 })
    face.label.text:SetPoint("CENTER", 0, 0)
    face.label:Hide()
    r:HookScript("OnEnter", function(self) Bar:Hover(self, true) end)
    r:HookScript("OnLeave", function(self) Bar:Hover(self, false) end)
    r:SetScript("PostClick", function(self, button, down)
        if Released(down) and button == "RightButton" and not InCombatLockdown() then Bar:TogglePop(self) end
    end)
    return r
end

local function NewPopRow(i)
    local p = Secure(pop, "DisasterZoneBlessPop" .. i)
    p:SetSize(POP_W - 16, POP_ROW)
    p:SetPoint("TOPLEFT", pop, "TOPLEFT", 8, -(24 + (i - 1) * POP_ROW))
    p.hl = p:CreateTexture(nil, "HIGHLIGHT")
    p.hl:SetAllPoints()
    Fill(p.hl, 1, 0.82, 0, 0.07)
    -- the icon in a frame of its own: a gold edge while the player has a single blessing of mine
    p.iconBox = CreateFrame("Frame", nil, p)
    p.iconBox:SetSize(15, 15)
    p.iconBox:SetPoint("TOPLEFT", p, "TOPLEFT", 4, -2)
    p.icon = p.iconBox:CreateTexture(nil, "ARTWORK")
    p.icon:SetAllPoints()
    p.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    p.name = Text(p, 11)
    p.name:SetPoint("TOPLEFT", p, "TOPLEFT", 26, -2)
    p.state = Text(p, 10, { 0.6, 0.6, 0.64 })
    p.state:SetPoint("TOPRIGHT", p, "TOPRIGHT", -4, -3)
    p.state:SetJustifyH("RIGHT")
    p.bar = Fill(p:CreateTexture(nil, "ARTWORK"), 1, 1, 1, 0.08)
    p.bar:SetPoint("TOPLEFT", p, "TOPLEFT", 26, -17)
    p.bar:SetPoint("TOPRIGHT", p, "TOPRIGHT", -4, -17)
    p.bar:SetHeight(2)
    p.barFill = Fill(p:CreateTexture(nil, "OVERLAY"), CALM[1], CALM[2], CALM[3], 0.55)
    p.barFill:SetPoint("TOPLEFT", p.bar, "TOPLEFT")
    p.barFill:SetHeight(2)
    p:SetAttribute("type1", "spell")
    p:SetAttribute("type2", "spell")
    -- the wheel steps through the single blessings I can give this player (back to the class's at the end)
    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", function(self, delta)
        if not InCombatLockdown() and self.member then Bar:CycleSingle(self, delta) end
    end)
    p:HookScript("OnEnter", function(self) Bar:PopTip(self) end)
    p:HookScript("OnLeave", function() GameTooltip:Hide() end)
    return p
end

local function HeaderIcon(name, size)
    local b = Secure(frame, name)
    b:SetSize(size, size)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.ring = b:CreateTexture(nil, "OVERLAY")
    b.ring:SetTexture(RING)
    b.ring:SetPoint("TOPLEFT", -2, 2)
    b.ring:SetPoint("BOTTOMRIGHT", 2, -2)
    b:SetAttribute("type", "spell")
    b:SetAttribute("unit", "player")
    return b
end

local function Build()
    frame = CreateFrame("Frame", "DisasterZoneBlessBar", UIParent)
    frame:SetSize(R_S + 2 * R_PAD, 100)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame.bg = Fill(frame:CreateTexture(nil, "BACKGROUND"), GLASS[1], GLASS[2], GLASS[3], GLASS[4])
    frame.bg:SetAllPoints()
    Edge(frame, 1, 1, 1, 0.08)
    frame.shadow = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    frame.shadow:SetTexture(SOFT)
    frame.shadow:SetVertexColor(0, 0, 0, 0.55)
    frame.shadow:SetPoint("TOPLEFT", -14, 10)
    frame.shadow:SetPoint("BOTTOMRIGHT", 14, -18)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not B().Setting("locked", true) and not InCombatLockdown() then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePos()
    end)

    local aura = HeaderIcon("DisasterZoneBlessAura", 20)
    aura:HookScript("OnEnter", function(self)
        local ai = B():GetAura(B():Me())
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(ai and B():AuraName(ai) or "No aura assigned")
        GameTooltip:AddLine(self.on and "On" or "Click to turn it on", 0.85, 0.85, 0.85)
        GameTooltip:Show()
    end)
    aura:HookScript("OnLeave", function() GameTooltip:Hide() end)
    frame.aura = aura

    local rf = HeaderIcon("DisasterZoneBlessRF", 16)
    SetRoundIcon(rf.icon, B().D.RF_ICON)
    rf:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(GetSpellInfo(B().D.RIGHTEOUS_FURY) or "Righteous Fury")
        GameTooltip:AddLine(self.on and "On" or "Off: click to cast it", 0.85, 0.85, 0.85)
        GameTooltip:Show()
    end)
    rf:HookScript("OnLeave", function() GameTooltip:Hide() end)
    frame.rf = rf

    -- Symbols of Kings: the count (the strip shows the reagent's icon too); a click opens the planner
    local sym = CreateFrame("Button", nil, frame)
    sym:SetSize(36, 14)
    sym.icon = sym:CreateTexture(nil, "ARTWORK")
    sym.icon:SetSize(14, 14)
    sym.icon:SetTexture(B().D.SYMBOL_ICON)
    sym.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    sym.n = Text(sym, 10, { 0.81, 0.81, 0.84 }, "GameFontHighlightSmall")
    sym:SetScript("OnClick", function() if ns.BlessingsUI then ns.BlessingsUI:Toggle() end end)
    sym:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(strformat("%s Symbols of Kings", self.n:GetText() or "0"))
        GameTooltip:AddLine("Click: the Blessings planner", 0.85, 0.85, 0.85)
        if not B().Setting("locked", true) then GameTooltip:AddLine("Drag the bar to move it.", 0.6, 0.6, 0.6) end
        GameTooltip:Show()
    end)
    sym:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame.sym = sym

    -- dividers (strip)
    frame.div1 = Fill(frame:CreateTexture(nil, "ARTWORK"), 1, 1, 1, 0.08)
    frame.div2 = Fill(frame:CreateTexture(nil, "ARTWORK"), 1, 1, 1, 0.08)

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
    pop.bg = Fill(pop:CreateTexture(nil, "BACKGROUND"), GLASS[1], GLASS[2], GLASS[3], 0.94)
    pop.bg:SetAllPoints()
    Edge(pop, 1, 1, 1, 0.09)
    pop.title = Text(pop, 8.5, { 0.6, 0.6, 0.65 })
    pop.title:SetPoint("TOPLEFT", pop, "TOPLEFT", 12, -9)
    pop.hint = Text(pop, 8.5, { 0.47, 0.47, 0.51 })
    pop.hint:SetText("wheel: a single blessing instead")
    pop.rows = {}
    pop:Hide()
    -- (it goes a second after the mouse leaves both it and its class; a right-click on the class closes it too)
    local away = 0
    pop:SetScript("OnUpdate", function(self, elapsed)
        if InCombatLockdown() then return end
        if self.fadeT then
            -- fading out: the drop-in played backwards
            self.fadeT = self.fadeT + (elapsed or 0)
            local e = min(1, self.fadeT / (UI().DROP_TIME or 0.14))
            self:SetAlpha(1 - e)
            if self.place then self.place(self.dx * e, self.dy * e) end
            if e >= 1 then
                self.fadeT = nil
                self:Hide()
            end
            return
        end
        if self:IsMouseOver() or (self.row and self.row:IsMouseOver()) then away = 0 return end
        away = away + (elapsed or 0)
        if away > 1 then
            away = 0
            Bar:HidePop()
        end
    end)

    local acc = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc >= 1 then
            acc = 0
            Bar:Update()
        end
    end)
    RestorePos()
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
-- Solo (bar set to "Always"), my own class gets a blessing even when none is assigned: the one my spec wants
-- (Holy Wisdom, Retribution Might, Protection Kings or Sanctuary), else the first I know.
local SOLO_PICK = { Holy = { 1, 3, 2 }, Retribution = { 2, 3, 1 }, Protection = { 3, 6, 2, 1 } }
function Bar:SoloPick()
    local Bl = B()
    local me = Bl:Me()
    for _, bi in ipairs(SOLO_PICK[Bl:SpecOf(me)] or { 3, 2, 1 }) do
        if Bl:Can(me, bi) then return bi end
    end
    for bi = 1, Bl.D.GREATER_MAX do
        if Bl:Can(me, bi) then return bi end
    end
    return nil
end

function Bar:MyRows()
    local Bl = B()
    local me = Bl:Me()
    local out = {}
    if not me then return out end
    local byClass = Bl:ByClass()
    local solo = not Bl:InGroup()
    local _, myClass = UnitClass("player")
    for _, cls in ipairs(Bl.D.DISPLAY) do
        local ci = Bl.CLASS_INDEX[cls]
        local bi = Bl:GetAssign(me, ci)
        local singles = Bl:GetSingles(me)[ci]
        if solo and not bi and not (singles and next(singles)) and cls == myClass then bi = self:SoloPick() end
        if (bi or (singles and next(singles))) and #byClass[ci] > 0 then
            local st = Bl:ClassState(me, ci, byClass, bi)
            local gname = bi and Bl:BlessingName(bi, true)
            local t = bi and GreaterTarget(byClass[ci], gname, bi)
            -- the icon: the Greater, or (everyone here is an exception, e.g. me alone with my own) the single
            local icon = bi and Bl:BlessingIcon(bi, true)
            local plain = false
            for _, m in ipairs(byClass[ci]) do
                if not (singles and singles[m.name]) then plain = true end
            end
            if (not plain or not bi) and singles then
                local _, sbi = next(singles)
                if sbi then icon = Bl:BlessingIcon(sbi) end
            end
            out[#out + 1] = { ci = ci, cls = cls, bi = bi, members = byClass[ci], state = st, unit = t and t.unit,
                greaterName = gname, icon = icon or Bl:BlessingIcon(1) }
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
-- What a click on class row r casts: spell, unit, kind ("greater" | "single"), member. In order: the Greater when
-- someone on it (not an exception) is missing it or has it running short (it goes first: casting it overwrites my
-- single blessings on the class); then each exception missing their single or running short, one per click;
-- nothing due: the Greater again (unless needOnly).
function Bar:NextFor(r, needOnly)
    local Bl = B()
    local me = Bl:Me()
    local warn = (tonumber(Bl.Setting("warnMin", 5)) or 5) * 60
    local function ok(m) return m.online and not m.dead and (m.demo or UnitIsVisible(m.unit)) end
    if r.bi and r.unit then
        for _, m in ipairs(r.members) do
            if not Bl:GetSingle(me, r.ci, m.name) and ok(m) then
                local left = Bl:BuffLeft(m.unit, r.bi)
                if not left or left < warn then return r.greaterName, r.unit, "greater", m end
            end
        end
    end
    for _, m in ipairs(r.members) do
        local sbi = Bl:GetSingle(me, r.ci, m.name)
        if sbi and ok(m) then
            local name = Bl:BlessingName(sbi)
            local inRange = m.demo or not IsSpellInRange or IsSpellInRange(name, m.unit) ~= 0
            local left = Bl:BuffLeft(m.unit, sbi)
            if inRange and (not left or left < warn) then return name, m.unit, "single", m end
        end
    end
    if needOnly then return nil end
    -- nothing due: the Greater again, but only when someone here is on it (it would overwrite the singles of the
    -- others); a class of exceptions only (me alone with my own single) refreshes the single running lowest
    local plain, best, bestLeft = false, nil, nil
    for _, m in ipairs(r.members) do
        local sbi = Bl:GetSingle(me, r.ci, m.name)
        if not sbi then
            if ok(m) then plain = true end
        elseif ok(m) then
            local left = Bl:BuffLeft(m.unit, sbi) or 0
            if not bestLeft or left < bestLeft then best, bestLeft = m, left end
        end
    end
    if plain and r.unit and r.greaterName then return r.greaterName, r.unit, "greater" end
    if best then return Bl:BlessingName(Bl:GetSingle(me, r.ci, best.name)), best.unit, "single", best end
    return nil
end

-- spell, unit for the "Bless next" key: the next thing the most urgent class needs, else any class's next need.
function Bar:NextCast()
    local list = self:MyRows()
    local u = self:Urgent(list)
    if u then
        local spell, unit = self:NextFor(u)
        if spell then return spell, unit end
    end
    for _, r in ipairs(list) do
        local spell, unit = self:NextFor(r, true)
        if spell then return spell, unit end
    end
    return nil, nil
end

-- ---------------------------------------------------------------------------------------------------------------
-- Layout (out of combat: it moves secure buttons)
-- ---------------------------------------------------------------------------------------------------------------
-- ---------------------------------------------------------------------------------------------------------------
-- Motion: each face eases its "hot" (urgent) look, its lift and its hairline toward targets (an exponential
-- approach: quick at first, settling softly), and plays a bloom when a class is blessed again.
-- ---------------------------------------------------------------------------------------------------------------
local exp, abs = math.exp, math.abs
local TAU = { hot = 0.11, lift = 0.09, line = 0.22, hover = 0.07 }
local BLOOM_TAU = 0.3

local function Mix(a, b, t) return a + (b - a) * t end

-- Places and colours what moves, from the face's current values.
local function ApplyMotion(f)
    local m = f.motion
    if not m or not f.row then return end
    local hot, lift, line = m.cur.hot or 0, m.cur.lift or 0, m.cur.line or 0
    local hover = m.cur.hover or 0
    f:ClearAllPoints()
    f:SetPoint("CENTER", f.row, "CENTER", 0, lift + (f.layout == "horizontal" and 2 * hover or 0))
    f.glow:SetAlpha(0.55 * hot)
    f.label:SetAlpha(hot)
    f.label:SetShown(hot > 0.01)
    f.label:ClearAllPoints()
    if f.layout == "horizontal" then
        f.label:SetPoint("BOTTOM", f, "TOP", 0, 8 - (1 - hot) * 5)
        -- the edge: black at rest, soft white on hover, gold when it is the one to do next
        local er, eg, eb, ea = Mix(0, 0.85, hover), Mix(0, 0.85, hover), Mix(0, 0.88, hover), Mix(0.9, 0.7, hover)
        Edge(f.tileEdge, Mix(er, 1, hot), Mix(eg, 0.82, hot), Mix(eb, 0, hot), Mix(ea, 1, hot))
        local g = hover
        f.tile:ClearAllPoints()
        f.tile:SetPoint("TOPLEFT", -g, g)
        f.tile:SetPoint("BOTTOMRIGHT", g, -g)
        f.sheen:ClearAllPoints()
        f.sheen:SetAllPoints(f.tile)
        f.sheen:SetAlpha(0.09 * hover)
        f.sheen:SetShown(hover > 0.01)
        f.halo:Hide()
        local cr, cg, cb = f.classRGB[1], f.classRGB[2], f.classRGB[3]
        f.lineFill:SetVertexColor(Mix(cr, GOLD[1], hot), Mix(cg, GOLD[2], hot), Mix(cb, GOLD[3], hot), 0.95)
        f.lineFill:SetWidth(max(0.5, (S_T - 4) * line))
        f.lineFill:SetShown(line > 0.004)
    else
        f.label:SetPoint("RIGHT", f, "LEFT", -12 - (1 - hot) * 8, 0)
        -- hover: the circle grows a little, a faint halo behind it, the ring's track brightens
        local g = 2 - 1.5 * hover
        f.cls:ClearAllPoints()
        f.cls:SetPoint("TOPLEFT", g, -g)
        f.cls:SetPoint("BOTTOMRIGHT", -g, g)
        f.halo:SetSize(R_S * 2, R_S * 2)
        f.halo:SetAlpha(0.16 * hover)
        f.halo:SetShown(hover > 0.01)
        f.track:SetVertexColor(1, 1, 1, 0.12 + 0.2 * hover)
        f.sheen:Hide()
        if f.cd.SetSwipeColor then
            f.cd:SetSwipeColor(Mix(CALM[1], GOLD[1], hot), Mix(CALM[2], GOLD[2], hot), Mix(CALM[3], GOLD[3], hot),
                Mix(CALM[4], 1, hot))
        end
    end
    local b = m.bloom
    if b and b > 0.01 then
        local base = f.layout == "horizontal" and S_T * 1.4 or R_S + 6
        local size = base * (1 + 0.65 * (1 - b))
        f.bloom:SetSize(size, size)
        f.bloom:SetAlpha(0.85 * b)
        f.bloom:Show()
    else
        f.bloom:Hide()
    end
end

local function Step(f, dt)
    local m = f.motion
    local settled = true
    for k, target in pairs(m.tgt) do
        local v = m.cur[k] or target
        v = v + (target - v) * (1 - exp(-dt / (TAU[k] or 0.12)))
        if abs(v - target) < 0.003 then v = target else settled = false end
        m.cur[k] = v
    end
    if m.bloom then
        m.bloom = m.bloom * exp(-dt / BLOOM_TAU)
        if m.bloom < 0.01 then m.bloom = nil else settled = false end
    end
    ApplyMotion(f)
    return settled
end

local function Run(f)
    if f.moving then return end
    f.moving = true
    f:SetScript("OnUpdate", function(self, elapsed)
        if Step(self, min(elapsed or 0, 0.1)) then
            self.moving = false
            self:SetScript("OnUpdate", nil)
        end
    end)
end

-- New targets for a face (hot 0..1, lift px, line 0..1); bloom: play the "blessed again" bloom. The first targets
-- are taken as they are (no motion when the bar first shows).
local function Aim(f, tgt, bloom)
    local m = f.motion
    if not m then
        f.motion = { cur = {}, tgt = tgt }
        for k, v in pairs(tgt) do f.motion.cur[k] = v end
        ApplyMotion(f)
        return
    end
    m.tgt = tgt
    if bloom then m.bloom = 1 end
    local moving = m.bloom ~= nil
    for k, v in pairs(tgt) do
        if abs((m.cur[k] or v) - v) > 0.003 then moving = true end
    end
    if moving then Run(f) else ApplyMotion(f) end
end
Bar.Aim, Bar.Step = Aim, Step

-- The mouse over a class: its face eases into the hover look (and back when it leaves). Nothing pops up.
function Bar:Hover(row, on)
    local f = row.face
    f.hoverOn = on and true or false
    local m = f.motion
    if not m then return end
    local t = {}
    for k, v in pairs(m.tgt) do t[k] = v end
    t.hover = on and 1 or 0
    Aim(f, t)
end

-- No panel: the circles, tiles and text float on the world. While unlocked a faint panel shows what to drag.
local function ApplyChrome()
    local unlocked = not B().Setting("locked", true)
    frame.bg:SetShown(unlocked)
    frame.shadow:SetShown(unlocked)
    for _, e in ipairs(frame.edges or {}) do e:SetShown(unlocked) end
    frame:EnableMouse(unlocked)
    if not unlocked then
        frame.div1:Hide()
        frame.div2:Hide()
    end
end

local function PlaceRail(list)
    local x = R_PAD
    frame.aura:ClearAllPoints()
    frame.aura:SetPoint("TOP", frame, "TOP", 0, -8)
    frame.rf:ClearAllPoints()
    frame.rf:SetPoint("LEFT", frame.aura, "RIGHT", 3, 0)
    frame.sym:ClearAllPoints()
    frame.sym:SetPoint("TOP", frame, "TOP", 0, -32)
    frame.sym.icon:Hide()
    frame.sym.n:ClearAllPoints()
    frame.sym.n:SetPoint("CENTER", frame.sym, "CENTER", 0, 0)
    frame.div1:ClearAllPoints()
    frame.div1:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -(R_HEAD - 5))
    frame.div1:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -(R_HEAD - 5))
    frame.div1:SetHeight(1)
    frame.div2:Hide()
    frame.div1:Show()
    for i = 1, #list do
        local row = rows[i]
        row:ClearAllPoints()
        row:SetSize(R_S, R_S)
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -(R_HEAD + (i - 1) * (R_S + R_GAP)))
        local f = row.face
        f.row, f.layout = row, "vertical"
        f.bloom:SetTexture(RING)
        f.bloom:SetVertexColor(1, 0.86, 0.4)
        f:SetSize(R_S, R_S)
        f.glow:SetSize(R_S * 2.4, R_S * 2.4)
        f.track:ClearAllPoints()
        f.track:SetPoint("TOPLEFT", -3, 3)
        f.track:SetPoint("BOTTOMRIGHT", 3, -3)
        f.cd:ClearAllPoints()
        f.cd:SetPoint("TOPLEFT", -3, 3)
        f.cd:SetPoint("BOTTOMRIGHT", 3, -3)
        f.cls:ClearAllPoints()
        f.cls:SetPoint("TOPLEFT", 2, -2)
        f.cls:SetPoint("BOTTOMRIGHT", -2, 2)
        f.corner:ClearAllPoints()
        f.corner:SetSize(12, 12)
        f.corner:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 3, -3)
        f.cornerBox:ClearAllPoints()
        f.cornerBox:SetPoint("TOPLEFT", f.corner, "TOPLEFT", -1, 1)
        f.cornerBox:SetPoint("BOTTOMRIGHT", f.corner, "BOTTOMRIGHT", 1, -1)
        Edge(f.cornerBox, GLASS[1], GLASS[2], GLASS[3], 1)
        f.cornerBox:Show()
        f.miss:ClearAllPoints()
        f.miss:SetPoint("CENTER", f, "TOPLEFT", 1, -1)
        f.label:ClearAllPoints()
        f.label:SetPoint("RIGHT", f, "LEFT", -12, 0)
        f.track:Show()
        f.cd:Show()
        f.cls:Show()
        f.tile:Hide()
        f.tileEdge:Hide()
        f.line:Hide()
        f.lineFill:Hide()
    end
    frame:SetSize(R_S + 2 * R_PAD, R_HEAD + #list * (R_S + R_GAP) + 2)
end

local function PlaceStrip(list)
    local n = #list
    local w = n * (S_T + S_GAP) - S_GAP + 2 * S_PAD + 2 * S_SIDE
    frame:SetSize(w, S_T + 18)
    frame.aura:ClearAllPoints()
    frame.aura:SetPoint("LEFT", frame, "LEFT", 13, 1)
    frame.rf:ClearAllPoints()
    frame.rf:SetPoint("TOPLEFT", frame.aura, "BOTTOMRIGHT", -6, 6)
    frame.div1:ClearAllPoints()
    frame.div1:SetPoint("LEFT", frame, "LEFT", S_SIDE, 0)
    frame.div1:SetSize(1, S_T - 4)
    frame.div2:ClearAllPoints()
    frame.div2:SetPoint("RIGHT", frame, "RIGHT", -S_SIDE, 0)
    frame.div2:SetSize(1, S_T - 4)
    frame.div1:Show()
    frame.div2:Show()
    frame.sym:ClearAllPoints()
    frame.sym:SetPoint("RIGHT", frame, "RIGHT", -6, 1)
    frame.sym.icon:Show()
    frame.sym.icon:ClearAllPoints()
    frame.sym.icon:SetPoint("LEFT", frame.sym, "LEFT", 0, 0)
    frame.sym.n:ClearAllPoints()
    frame.sym.n:SetPoint("LEFT", frame.sym.icon, "RIGHT", 3, 0)
    for i = 1, n do
        local row = rows[i]
        row:ClearAllPoints()
        row:SetSize(S_T, S_T)
        row:SetPoint("LEFT", frame, "LEFT", S_SIDE + 8 + (i - 1) * (S_T + S_GAP), 2)
        local f = row.face
        f.row, f.layout = row, "horizontal"
        f.bloom:SetTexture(SOFT)
        f.bloom:SetVertexColor(1, 0.9, 0.55)
        f:SetSize(S_T, S_T)
        f.glow:SetSize(S_T * 2.2, S_T * 2.2)
        f.tile:ClearAllPoints()
        f.tile:SetAllPoints()
        f.tileEdge:ClearAllPoints()
        f.tileEdge:SetPoint("TOPLEFT", -1, 1)
        f.tileEdge:SetPoint("BOTTOMRIGHT", 1, -1)
        f.corner:ClearAllPoints()
        f.corner:SetSize(15, 15)
        f.corner:SetPoint("TOPRIGHT", f, "TOPRIGHT", 4, 4)
        f.cornerBox:Hide()                -- (the class circle is round: no frame)
        f.line:ClearAllPoints()
        f.line:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 2, -4)
        f.line:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", -2, -4)
        f.line:SetHeight(2)
        f.lineFill:ClearAllPoints()
        f.lineFill:SetPoint("TOPLEFT", f.line, "TOPLEFT")
        f.lineFill:SetHeight(2)
        f.miss:ClearAllPoints()
        f.miss:SetPoint("CENTER", f, "TOPLEFT", 0, 0)
        f.label:ClearAllPoints()
        f.label:SetPoint("BOTTOM", f, "TOP", 0, 8)
        f.track:Hide()
        f.cd:Hide()
        f.cls:Hide()
        f.tile:Show()
        f.tileEdge:Show()
        f.line:Show()
        f.lineFill:Show()
    end
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
        if pop then Bar:HidePop(true) end
        return
    end
    local Bl = B()
    local me = Bl:Me()
    local list = self:MyRows()
    local urgent = self:Urgent(list)
    local layout = Layout()

    -- what changes the secure buttons (targets, spells, rows, places) waits for the end of a fight
    if not combat then
        frame:SetScale(tonumber(Bl.Setting("scale", 1)) or 1)
        if frame.layout ~= layout then
            frame.layout = layout
            RestorePos()
            if pop then Bar:HidePop(true) end
        end
        local ai = Bl:GetAura(me)
        frame.aura:SetAttribute("spell", (ai and not Bl:IsDemo()) and Bl:AuraName(ai) or nil)
        frame.aura:SetShown(ai ~= nil)
        local hasRF = IsSpellKnown and IsSpellKnown(Bl.D.RIGHTEOUS_FURY)
        local prot = Bl:SpecOf(me) == "Protection"
        frame.rf:SetAttribute("spell", (hasRF and prot) and GetSpellInfo(Bl.D.RIGHTEOUS_FURY) or nil)
        frame.rf:SetShown(hasRF and prot or false)
        for i, r in ipairs(list) do
            local row = rows[i] or NewRow(i)
            rows[i] = row
            -- (demo mode: nothing to cast on)
            local spell, unit = self:NextFor(r)
            if Bl:IsDemo() then spell, unit = nil, nil end
            row:SetAttribute("spell1", spell)
            row:SetAttribute("unit1", unit)
            row.data = r
            row:Show()
        end
        for i = #list + 1, #rows do
            rows[i]:Hide()
            rows[i].data = nil
        end
        if layout == "horizontal" then PlaceStrip(list) else PlaceRail(list) end
        ApplyChrome()
        frame:Show()
        dirty = false
    end

    -- looks (safe in combat)
    frame:SetAlpha(combat and 0.75 or 1)
    local ai = Bl:GetAura(me)
    if ai then
        SetRoundIcon(frame.aura.icon, Bl:AuraIcon(ai))
        local on = Bl:IsDemo()
        for i = 1, 40 do
            local name, _, _, _, _, _, _, _, _, id = UnitAura("player", i, "HELPFUL")
            if not name then break end
            if id and Bl.AURA_BY_ID[id] == ai then on = true break end
        end
        frame.aura.on = on
        frame.aura.icon:SetDesaturated(not on)
        frame.aura.ring:SetVertexColor(on and 1 or 0.91, on and 0.82 or 0.38, on and 0 or 0.3, on and 1 or 0.9)
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
        frame.rf.ring:SetVertexColor(on and 1 or 0.6, on and 0.82 or 0.6, on and 0 or 0.62, on and 1 or 0.5)
    end
    local p = me and Bl.pals[me]
    local n = GetItemCount and GetItemCount(Bl.D.SYMBOL_OF_KINGS) or (p and p.symbols) or 0
    if Bl:IsDemo() and p and p.symbols then n = p.symbols end
    frame.sym.n:SetText(n)
    local low = n < (tonumber(Bl.Setting("symbols", 20)) or 20)
    frame.sym.n:SetTextColor(low and 1 or 0.81, low and 0.48 or 0.81, low and 0.42 or 0.84)

    local now = GetTime()
    local total = Bl.D.GDURATION
    for _, row in ipairs(rows) do
        local r = row.data
        if r and row:IsShown() then
            local f = row.face
            local st = r.state
            local isNext = urgent and urgent.ci == r.ci
            local cr, cg, cb = UI():ClassColor(r.cls)
            local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[r.cls]
            local frac = st.left and max(0, min(1, st.left / total)) or 0
            f.miss:SetCount(#st.missing)
            f.glow:Show()
            f.classRGB = { cr, cg, cb }
            local reach = r.unit and 1 or 0.5
            if layout == "horizontal" then
                f.tile:SetTexture(r.icon)
                f.tile:SetAlpha(reach)
                f.corner:SetTexture(CIRCLES)
                if c then f.corner:SetTexCoord(c[1], c[2], c[3], c[4]) end
                if isNext then
                    f.label.text:SetText(#st.missing > 0 and strformat("%d missing", #st.missing) or Minutes(st.left))
                    f.label.text:SetTextColor(0.1, 0.08, 0.01)
                    f.label.bg:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
                    Edge(f.label, GOLD[1], GOLD[2], GOLD[3], 1)
                end
            else
                f.cls:SetTexture(CIRCLES)
                if c then f.cls:SetTexCoord(c[1], c[2], c[3], c[4]) end
                f.cls:SetAlpha(reach)
                f.corner:SetTexture(r.icon)
                if st.left and st.left > 0 then
                    -- (started total - left ago: the swipe shows what is left and drains on its own)
                    local start = floor((now - (total - st.left)) * 2 + 0.5) / 2
                    if f.cd.cdStart ~= start then
                        f.cd.cdStart = start
                        f.cd:SetCooldown(start, total)
                    end
                elseif f.cd.cdStart then
                    f.cd.cdStart = nil
                    if f.cd.Clear then f.cd:Clear() else f.cd:SetCooldown(0, 0) end
                end
                if isNext then
                    local what = r.bi and Bl.D.BLESSINGS[r.bi].short or "Single blessings"
                    local when = #st.missing > 0 and strformat("%d missing", #st.missing) or Minutes(st.left)
                    f.label.text:SetText(strformat("%s · %s · %s", Plural(r.cls), what, when))
                    f.label.text:SetTextColor(1, 0.9, 0.55)
                    f.label.bg:SetVertexColor(GLASS[1], GLASS[2], GLASS[3], 0.92)
                    Edge(f.label, GOLD[1], GOLD[2], GOLD[3], 0.55)
                end
            end
            if isNext then f.label:SetWidth((f.label.text:GetStringWidth() or 40) + 16) end
            -- motion: ease toward the new look; bloom when it was urgent or missing and no longer is
            local blessed = (f.wasHot and not isNext) or ((f.wasMissing or 0) > #st.missing)
            Aim(f, { hot = isNext and 1 or 0, lift = (isNext and layout == "horizontal") and 7 or 0, line = frac,
                hover = f.hoverOn and 1 or 0 },
                blessed and f.motion ~= nil)
            f.wasHot, f.wasMissing = isNext and true or false, #st.missing
        end
    end
    if pop and pop:IsShown() and pop.row and pop.row.data then self:FillPop(pop.row) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Popout (players of one class)
-- ---------------------------------------------------------------------------------------------------------------
function Bar:FillPop(row)
    local Bl = B()
    local r = row.data
    local me = Bl:Me()
    pop.title:SetText(Plural(r.cls):upper())
    local combat = InCombatLockdown()
    local total = Bl.D.GDURATION
    for i, m in ipairs(r.members) do
        local p = pop.rows[i]
        if not p then
            if combat then break end
            p = NewPopRow(i)
            pop.rows[i] = p
        end
        local sbi = Bl:GetSingle(me, r.ci, m.name)
        local bi = sbi or r.bi
        p.member, p.ci, p.greater = m, r.ci, r.bi
        if sbi then Edge(p.iconBox, 1, 0.82, 0, 1) else Edge(p.iconBox, 0, 0, 0, 0.9) end
        if not combat then
            local real = not m.demo
            p:SetAttribute("unit1", real and m.unit or nil)
            p:SetAttribute("unit2", real and m.unit or nil)
            -- click: their own blessing now, whatever is left (their single, else the Greater); right-click: the
            -- small one on them only
            local own = sbi and Bl:BlessingName(sbi) or (r.bi and Bl:BlessingName(r.bi, true))
            p:SetAttribute("spell1", real and own or nil)
            p:SetAttribute("spell2", (real and bi) and Bl:BlessingName(bi) or nil)
            p:Show()
        end
        p.icon:SetTexture(bi and Bl:BlessingIcon(bi, sbi == nil) or "Interface\\Icons\\INV_Misc_QuestionMark")
        local left = bi and Bl:BuffLeft(m.unit, bi)
        local cr, cg, cb = UI():ClassColor(r.cls)
        p.name:SetText(m.name .. (m.pet and " (pet)" or ""))
        p.name:SetTextColor(cr, cg, cb)
        local w = (POP_W - 16) - 30
        if left then
            p.state:SetText(Minutes(left))
            p.state:SetTextColor(0.6, 0.6, 0.64)
            p.icon:SetDesaturated(false)
            p.icon:SetAlpha(1)
            p.barFill:SetWidth(max(0.5, w * max(0, min(1, left / (sbi and Bl.D.DURATION or total)))))
            p.barFill:Show()
        else
            local far = not m.demo and not UnitIsVisible(m.unit) or (IsSpellInRange and bi and IsSpellInRange(Bl:BlessingName(bi), m.unit) == 0)
            p.state:SetText(m.dead and "dead" or (not m.online and "offline") or (far and "out of range") or "missing")
            p.state:SetTextColor(1, 0.54, 0.47)
            p.icon:SetDesaturated(true)
            p.icon:SetAlpha(0.6)
            p.barFill:Hide()
        end
    end
    if not combat then
        for i = #r.members + 1, #pop.rows do pop.rows[i]:Hide() end
        pop.hint:ClearAllPoints()
        pop.hint:SetPoint("TOPLEFT", pop, "TOPLEFT", 12, -(26 + #r.members * POP_ROW + 2))
        pop:SetHeight(26 + #r.members * POP_ROW + 20)
    end
end

-- Right-click: a class's players next to it (left of the rail, above the strip); again: closed.
function Bar:TogglePop(row)
    if InCombatLockdown() or not row.data then return end
    if pop:IsShown() and pop.row == row and not pop.fadeT then
        self:HidePop()
        return
    end
    pop.row = row
    pop.fadeT = nil
    -- it comes in like the addon's dropdowns (UI:DropIn: fades up while it moves the last few px): out of the
    -- rail from the circle's side, up out of the strip
    local fall = UI().DROP_FALL or 6
    local strip = Layout() == "horizontal"
    pop.dx, pop.dy = strip and 0 or fall, strip and -fall or 0
    pop.place = function(dx, dy)
        pop:ClearAllPoints()
        if strip then pop:SetPoint("BOTTOM", row, "TOP", dx, 18 + dy)
        else pop:SetPoint("RIGHT", row, "LEFT", -14 + dx, dy) end
    end
    self:FillPop(row)
    pop:Show()
    if UI().DropIn then UI():DropIn(pop, pop.place, pop.dx, pop.dy) else pop.place(0, 0) end
end

-- Closes the players: fades out toward its class (instant: at once, e.g. as a fight starts, when it can't wait).
function Bar:HidePop(instant)
    if not pop or not pop:IsShown() then return end
    if instant or InCombatLockdown() or not pop.place then
        pop.fadeT = nil
        pop:Hide()
        return
    end
    if not pop.fadeT then pop.fadeT = 0 end
end

-- Wheel on a player: my single blessing for them steps to the next (or previous) one I can give, skipping the
-- class's Greater (they have it already) and Sacrifice on myself; past the last it goes back to the class's.
function Bar:CycleSingle(p, delta)
    local Bl = B()
    local me, m = Bl:Me(), p.member
    local options = { 0 }
    for bi = 1, #Bl.D.BLESSINGS do
        if Bl:Can(me, bi) and bi ~= p.greater and not (bi == 7 and m.name == me) then options[#options + 1] = bi end
    end
    local cur = Bl:GetSingle(me, p.ci, m.name) or 0
    local at = 1
    for i, bi in ipairs(options) do if bi == cur then at = i end end
    at = (at - 1 - delta) % #options + 1
    Bl:SetSingle(me, p.ci, m.name, options[at])
    self:FillPop(pop.row)
    self:PopTip(p)
end

function Bar:PopTip(p)
    local m = p.member
    if not m then return end
    local Bl = B()
    local me = Bl:Me()
    local sbi = Bl:GetSingle(me, p.ci, m.name)
    GameTooltip:SetOwner(p, Layout() == "horizontal" and "ANCHOR_TOP" or "ANCHOR_LEFT")
    GameTooltip:AddLine(m.name)
    if sbi then
        GameTooltip:AddLine(strformat("Gets %s from you instead of the class's", Bl:BlessingName(sbi)), 1, 0.82, 0, true)
    end
    if sbi then
        GameTooltip:AddLine("Click: " .. Bl:BlessingName(sbi), 0.85, 0.85, 0.85)
    elseif p.greater then
        GameTooltip:AddLine("Click: " .. Bl:BlessingName(p.greater, true) .. " (the whole class)", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Right-click: " .. Bl:BlessingName(p.greater) .. " (them only)", 0.85, 0.85, 0.85)
    end
    GameTooltip:AddLine("Wheel: give them a single blessing instead", 0.6, 0.6, 0.6)
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
        if pop and pop:IsShown() then
            Bar:HidePop(true)
        end
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
function Bar:GetPopout() return pop end

Bar.LAYOUTS = { { value = "vertical", text = "Rail (vertical)" }, { value = "horizontal", text = "Strip (horizontal)" } }

-- The kit's Settings card (Settings > Class tools; every paladin spec).
if ns.ClassKit then ns.ClassKit:Extend("bless", {
    iconPath = "Interface\\Icons\\Spell_Magic_GreaterBlessingofKings",
    action = { label = "Open planner", run = function() if ns.BlessingsUI then ns.BlessingsUI:Open() end end },
    settings = function(S, sec)
    S:DropdownSetting(sec, "Buff bar", "Your blessings per class: click to cast, right-click for the players.",
        "bless.bar", "group", { { value = "group", text = "Party and raid" }, { value = "raid", text = "Raids only" },
            { value = "always", text = "Always" }, { value = "off", text = "Off" } })
    S:DropdownSetting(sec, "Bar layout", "A rail of class rings, or a strip of tiles over your action bars.",
        "bless.layout", "vertical", Bar.LAYOUTS)
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

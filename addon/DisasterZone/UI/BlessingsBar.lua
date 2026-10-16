if DisasterZoneBoot and DisasterZoneBoot.Run("UI/BlessingsBar.lua", ...) then return end -- DisasterZone: blessings bar.
-- The paladin's buff bar for the Blessings planner (Core/Blessings.lua), shown in a party or raid when I have an aura
-- or a blessing to give. Two layouts (settings bless.layout, also in the planner's More menu): "vertical" (Rail, a
-- column) and "horizontal" (Strip, a row) - the same cells in both, only the axis turns. The cells are the theme's
-- faces (UI/BarFace.lua, setting classbar.theme; mockup dev/art/casc/bar_themes/build_themes.py): first the planner
-- (a click opens it; it never casts), my aura (gold = on), Righteous Fury for Protection and Symbols of Kings (its
-- count), a divider, then a cell per class: the
-- blessing's icon, the time left draining (ring, swipe or bar by theme: calm, red when short), the class in the
-- corner, a red count of who is missing it. The class to do next lifts out of the line (up in the strip, left in the
-- rail) in gold, with its time on a chip when nobody is missing it.
-- No panel behind it (only a faint one while unlocked, to drag it by).
-- Motion (BarFace): the next look eases in and out, and a class that was missing or running out blooms once when it
-- is blessed again. All of it on the faces (not secure), so it runs in combat too.
-- Click a class: the next thing it needs, in order: the Greater (someone on it is missing it or it runs short; it goes
-- first, it overwrites single blessings), then each exception's single blessing, one per click; nothing due: the
-- Greater again. Right-click a class for its players (nothing pops up on hover): click = recast their own blessing
-- now (their single, else the Greater), right-click = the small one on them only, wheel = a single blessing
-- instead.
-- Every cast is a secure button whose target is chosen out of combat (WoW forbids changing them in combat): in a
-- fight the bar dims and keeps its targets, and catches up when the fight ends. Key binding: "Bless next".
-- The frame, its chrome and places, the header cells, the popout's frame and the Settings card's common rows are the
-- class bar's (UI/ClassBar.lua).
local addonName, ns = ...

local Bar = ns:NewModule("BlessingsBar")

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local strformat = string.format

local CALM = { 0.91, 0.89, 0.82, 0.75 }
local GOLD, LINE = ns.Style.C.GOLD, ns.Style.C.HAIRLINE

local POP_W, POP_ROW = 172, 22

local function B() return ns.Blessings end
local function UI() return ns.UI end
local function Face() return ns.BarFace end
local CB = ns.ClassBar
local Text = CB.Text

-- the bar (a place per layout: the rail sits right of centre, the strip over the action bars)
local cb = CB:New({ name = "DisasterZoneBlessBar", setting = "bless", railPos = { "RIGHT", -220, 40 },
    stripPos = { "BOTTOM", 0, 150 } })

local frame, rows, pop, nextBtn
local dirty = false
local stale = true      -- something the every-second look can't see changed (a pet, a name, a level): update in full

local function Secure(parent, name) return cb:Secure(parent, name) end

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

local function Layout() return cb:Layout() end
Bar.Layout = Layout

-- Is the bar for me now: a paladin (the class tool), in a group the setting allows, with an aura or a blessing to give?
function Bar:Wanted()
    if not (ns.ClassKit and ns.ClassKit:IsLive("bless")) then return false end
    if cb.preview then return B():Me() ~= nil end      -- (Edit layout: shown to be moved)
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
local function RestorePos() cb:RestorePos() end

-- One class: a secure button; its looks sit on a face (BarFace: it moves for the lift without touching the button).
local function NewRow(i)
    local r = Secure(frame, "DisasterZoneBlessRow" .. i)
    r:SetSize(34, 34)
    r:SetAttribute("type1", "spell")
    r:SetScript("PreClick", function(self)
        if InCombatLockdown() or not self.data then return end
        local spell, unit = Bar:NextFor(self.data)
        if B():IsDemo() then spell, unit = nil, nil end
        self:SetAttribute("spell1", spell)
        self:SetAttribute("unit1", unit)
    end)
    r.face = Face():New(r)
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
    p.hl = UI():Fill(p, { GOLD[1], GOLD[2], GOLD[3], 0.07 }, "HIGHLIGHT")
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
    p.bar = UI():Fill(p, { LINE[1], LINE[2], LINE[3], 0.08 }, "ARTWORK")
    p.bar:ClearAllPoints()
    p.bar:SetPoint("TOPLEFT", p, "TOPLEFT", 26, -17)
    p.bar:SetPoint("TOPRIGHT", p, "TOPRIGHT", -4, -17)
    p.bar:SetHeight(2)
    p.barFill = UI():Fill(p, { CALM[1], CALM[2], CALM[3], 0.55 }, "OVERLAY")
    p.barFill:ClearAllPoints()
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

-- A header cell (aura, Righteous Fury): secure, the same face as the classes.
local function HeaderIcon(name) return cb:HeaderIcon(name, "player") end

local function Build()
    frame = cb:Build()

    local aura = HeaderIcon("DisasterZoneBlessAura")
    aura:HookScript("OnEnter", function(self)
        local ai = B():GetAura(B():Me())
        GameTooltip:SetOwner(self, UI():TowardMiddle(self, "x"))
        GameTooltip:AddLine(ai and B():AuraName(ai) or "No aura assigned")
        GameTooltip:AddLine(self.on and "On" or "Click to turn it on", 0.85, 0.85, 0.85)
        GameTooltip:Show()
    end)
    aura:HookScript("OnLeave", function() GameTooltip:Hide() end)
    frame.aura = aura

    local rf = HeaderIcon("DisasterZoneBlessRF")
    rf:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, UI():TowardMiddle(self, "x"))
        GameTooltip:AddLine(GetSpellInfo(B().D.RIGHTEOUS_FURY) or "Righteous Fury")
        GameTooltip:AddLine(self.on and "On" or "Off: click to cast it", 0.85, 0.85, 0.85)
        GameTooltip:Show()
    end)
    rf:HookScript("OnLeave", function() GameTooltip:Hide() end)
    frame.rf = rf

    -- the planner (the bar's first cell)
    frame.plan = Face():PlannerCell(frame, "Blessings planner", function()
        if ns.BlessingsUI then ns.BlessingsUI:Toggle() end
    end)

    -- Symbols of Kings: the reagent with its count
    local sym = CreateFrame("Button", nil, frame)
    sym:SetSize(34, 34)
    sym.face = Face():New(sym)
    sym:SetScript("OnEnter", function(self)
        Face():Hover(self.face, true)
        GameTooltip:SetOwner(self, UI():TowardMiddle(self, "x"))
        GameTooltip:AddLine(strformat("%s Symbols of Kings", self.count or 0))
        if not B().Setting("locked", true) then GameTooltip:AddLine("Drag the bar to move it.", 0.6, 0.6, 0.6) end
        GameTooltip:Show()
    end)
    sym:SetScript("OnLeave", function(self)
        Face():Hover(self.face, false)
        GameTooltip:Hide()
    end)
    frame.sym = sym

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
    pop = cb:NewPop("DisasterZoneBlessPopout", POP_W)
    pop.hint:SetText("wheel: a single blessing instead")
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

    -- once a second a look that makes no garbage; the full update only when it finds a change (Bar:Tick)
    local acc = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc >= 1 then
            acc = 0
            Bar:Tick()
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
-- Motion and layout: the faces' (UI/BarFace.lua). Aim / Step stay here for the tests.
-- ---------------------------------------------------------------------------------------------------------------
local function Aim(f, tgt, bloom) return Face().Aim(f, tgt, bloom) end
Bar.Aim = Aim
Bar.Step = function(f, dt) return Face().Step(f, dt) end

-- The mouse over a class: its face eases into the hover look (and back when it leaves). Nothing pops up.
function Bar:Hover(row, on)
    Face():Hover(row.face, on)
end

-- No panel: the circles, tiles and text float on the world (ClassBar: a faint panel while unlocked).
local function ApplyChrome() cb:ApplyChrome() end

-- The cells in order: the planner, the header that is shown (aura, Righteous Fury, Symbols), then the classes.
local function Place(list, axis, theme)
    local cells = {}
    for i = 1, #list do cells[i] = rows[i] end
    cb:Place({ frame.plan, frame.aura, frame.rf, frame.sym }, cells, axis, theme)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------------------------------------------
-- Is my aura (ai) on me? (The demo's always is.)
local function AuraOn(Bl, ai)
    if Bl:IsDemo() then return true end
    for i = 1, 40 do
        local name, _, _, _, _, _, _, _, _, id = UnitAura("player", i, "HELPFUL")
        if not name then break end
        if id and Bl.AURA_BY_ID[id] == ai then return true end
    end
    return false
end

local function RfOn(Bl)
    local rfName = GetSpellInfo(Bl.D.RIGHTEOUS_FURY)
    for i = 1, 40 do
        local name, _, _, _, _, _, _, _, _, id = UnitAura("player", i, "HELPFUL")
        if not name then break end
        if id == Bl.D.RIGHTEOUS_FURY or (rfName and name == rfName) then return true end
    end
    return false
end

local function SymbolCount(Bl, me)
    local p = me and Bl.pals[me]
    local n = GetItemCount and GetItemCount(Bl.D.SYMBOL_OF_KINGS) or (p and p.symbols) or 0
    if Bl:IsDemo() and p and p.symbols then n = p.symbols end
    return n
end

-- When member m's blessing from me (their single, else the row's Greater) runs out, on GetTime()'s clock; 0 when they
-- have none, or are offline or dead (ClassState counts them as having it).
local function Expiry(Bl, singles, r, m, now)
    local sbi = singles and singles[m.name]
    local bi = (sbi and sbi > 0) and sbi or r.bi
    if not bi or not m.online or m.dead then return 0 end
    local left = Bl:BuffLeft(m.unit, bi)
    return left and (now + left) or 0
end

-- The chip's text as a number (Minutes: whole minutes, under one whole seconds), to see it change without a string.
local function ChipKey(left)
    if not left then return -1 end
    if left >= 60 then return floor(left / 60) end
    return 100000 + floor(left)
end

function Bar:Update()
    if not frame then
        if not self:Wanted() then return end
        Build()
    end
    stale = false
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
        -- (placed again only when the layout, the theme or the cells change: re-anchoring the cooldown rings every
        -- second made them blink in game)
        local theme = Face():Theme()
        local axis = layout == "horizontal" and "h" or "v"
        local sig = strformat("%s:%s:%d:%s%s", axis, theme.key, #list, frame.aura:IsShown() and "a" or "",
            frame.rf:IsShown() and "r" or "")
        if frame.placed ~= sig then
            frame.placed = sig
            Place(list, axis, theme)
        end
        ApplyChrome()
        frame:Show()
        dirty = false
    end

    -- looks (safe in combat)
    frame:SetAlpha(combat and 0.75 or 1)
    local ai = Bl:GetAura(me)
    if ai then
        local on = AuraOn(Bl, ai)
        frame.aura.on = on
        -- gold = on; red = it should be on
        Face():Set(frame.aura.face, { icon = Bl:AuraIcon(ai), desat = not on, tone = on and "on" or "warn" })
        Aim(frame.aura.face, Face():Targets(frame.aura.face, false))
    end
    if frame.rf:IsShown() then
        local on = RfOn(Bl)
        frame.rf.on = on
        Face():Set(frame.rf.face, { icon = Bl.D.RF_ICON, desat = not on, tone = on and "on" or "dim" })
        Aim(frame.rf.face, Face():Targets(frame.rf.face, false))
    end
    local n = SymbolCount(Bl, me)
    frame.sym.count = n
    Face():ShowPlanner(frame.plan)
    local low = n < (tonumber(Bl.Setting("symbols", 20)) or 20)
    Face():Set(frame.sym.face, { icon = Bl.D.SYMBOL_ICON, num = tostring(n), tone = low and "warn" or nil,
        numColor = low and { 1, 0.55, 0.47 } or nil })
    Aim(frame.sym.face, Face():Targets(frame.sym.face, false))

    local now = GetTime()
    local total = Bl.D.GDURATION
    local warn = (tonumber(Bl.Setting("warnMin", 5)) or 5) * 60
    local singlesAll = Bl:GetSingles(me)
    for _, row in ipairs(rows) do
        local r = row.data
        if r and row:IsShown() then
            -- (in a fight the rows keep their places and casts, but show their class as it is now)
            if combat then
                for _, x in ipairs(list) do
                    if x.ci == r.ci then r = x; row.data = x; break end
                end
            end
            local f = row.face
            local st = r.state
            local isNext = urgent and urgent.ci == r.ci
            local look = { icon = r.icon, cornerClass = r.cls, missing = #st.missing, alpha = r.unit and 1 or 0.5,
                short = st.left ~= nil and st.left < warn }
            if st.left and st.left > 0 then
                -- (started total - left ago: the swipe / bar shows what is left and drains on its own)
                look.start, look.total = now - (total - st.left), total
            else
                look.frac = 0
            end
            -- the red count already says who is missing: the chip only says when it runs out
            if isNext and #st.missing == 0 then look.chip = Minutes(st.left) end
            Face():Set(f, look)
            -- motion: ease toward the new look; bloom when it was next or missing and no longer is
            local blessed = (f.wasHot and not isNext) or ((f.wasMissing or 0) > #st.missing)
            Aim(f, Face():Targets(f, isNext), blessed and f.motion ~= nil)
            f.wasHot, f.wasMissing = isNext and true or false, #st.missing
            -- what the every-second look compares (NeedsUpdate)
            local singles, exp = singlesAll[r.ci], {}
            for i, m in ipairs(r.members) do exp[i] = Expiry(Bl, singles, r, m, now) end
            r.exp, r.short, r.chipKey = exp, look.short, look.chip and ChipKey(st.left) or nil
        end
    end
    if pop and pop:IsShown() and pop.row and pop.row.data then self:FillPop(pop.row) end
end

-- The every-second look (it makes no tables): does the bar show something that is no longer so? A blessing given,
-- refreshed or gone, someone offline or dead (or back), the Greater's target out of range or another one in range,
-- a class running short, the next class's chip a minute on (under one: a second), my aura or Righteous Fury on or
-- off, Symbols used. The plan, the roster, settings and fights come as events (OnLogin) and update at once.
function Bar:NeedsUpdate()
    if stale or not frame or not rows then return true end
    local Bl = B()
    local me = Bl:Me()
    if not me then return true end
    local ai = Bl:GetAura(me)
    if ai and AuraOn(Bl, ai) ~= (frame.aura.on or false) then return true end
    if frame.rf:IsShown() and RfOn(Bl) ~= (frame.rf.on or false) then return true end
    if SymbolCount(Bl, me) ~= frame.sym.count then return true end
    local now = GetTime()
    local warn = (tonumber(Bl.Setting("warnMin", 5)) or 5) * 60
    local singlesAll = Bl:GetSingles(me)
    for _, row in ipairs(rows) do
        local r = row.data
        if r and row:IsShown() then
            if not r.exp then return true end
            local singles, first = singlesAll[r.ci], nil
            for i, m in ipairs(r.members) do
                if not m.demo and ((UnitIsConnected(m.unit) and true or false) ~= m.online
                    or (UnitIsDeadOrGhost(m.unit) and true or false) ~= m.dead) then
                    return true
                end
                local e, was = Expiry(Bl, singles, r, m, now), r.exp[i] or 0
                if (e == 0) ~= (was == 0) or abs(e - was) > 0.5 then return true end
                if e > 0 and (not first or e < first) then first = e end
            end
            local left = first and (first - now)
            if (left ~= nil and left < warn) ~= (r.short and true or false) then return true end
            if r.chipKey and ChipKey(left) ~= r.chipKey then return true end
            if r.bi then
                local t = GreaterTarget(r.members, r.greaterName, r.bi)
                if (t and t.unit) ~= r.unit then return true end
            end
        end
    end
    return false
end

-- Once a second: the full update when something changed, else only what runs on the clock (the slate and pips
-- themes' time bars, the open players list's times).
function Bar:Tick()
    if self:NeedsUpdate() then return self:Update() end
    for _, row in ipairs(rows) do
        if row.data and row:IsShown() then Face():Drain(row.face) end
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
        if not p.iconBox.edges then UI():AddEdges(p.iconBox) end
        if sbi then UI():SetEdgeColor(p.iconBox, GOLD[1], GOLD[2], GOLD[3], 1) else UI():SetEdgeColor(p.iconBox, 0, 0, 0, 0.9) end
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

-- Right-click: a class's players next to it, toward the screen's middle (beside the rail, over/under the strip);
-- again: closed.
function Bar:TogglePop(row)
    if InCombatLockdown() or not row.data then return end
    if pop:IsShown() and pop.row == row and not pop.fadeT then
        self:HidePop()
        return
    end
    pop.row = row
    pop.fadeT = nil
    -- it comes in like the addon's dropdowns (UI:DropIn: fades up while it moves the last few px): out of the
    -- rail's / strip's side that faces the screen's middle
    local strip = Layout() == "horizontal"
    pop.place, pop.dx, pop.dy = UI():PlaceToward(pop, row, strip and "y" or "x", strip and 18 or 14, UI().DROP_FALL or 6)
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
    GameTooltip:SetOwner(p, UI():TowardMiddle(p, Layout() == "horizontal" and "y" or "x"))
    GameTooltip:AddLine(m.name)
    if sbi then
        GameTooltip:AddLine(strformat("Gets %s from you instead of the class's", Bl:BlessingName(sbi)), GOLD[1], GOLD[2], GOLD[3], true)
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
    -- what the every-second look can't see: a pet summoned or gone, a name or level known late, talents
    local function GroupUnit(unit)
        return type(unit) == "string" and (unit == "player" or unit == "pet" or unit:find("^party") ~= nil
            or unit:find("^raid") ~= nil)
    end
    for _, ev in ipairs({ "UNIT_PET", "UNIT_NAME_UPDATE", "UNIT_LEVEL" }) do
        ns:RegisterEvent(ev, function(_, unit) if GroupUnit(unit) then stale = true end end)
    end
    for _, ev in ipairs({ "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE" }) do
        ns:RegisterEvent(ev, function() stale = true end)
    end
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() Bar:Update() end)
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if pop and pop:IsShown() then
            Bar:HidePop(true)
        end
        if frame then frame:SetAlpha(0.75) end
    end)
    cb:OnSettings(function() Bar:Update() end)
    cb:RegisterLayout(function() Bar:Update() end, "Blessings bar", 10)
    self:Update()
end

function Bar:GetFrame() return frame end
function Bar:GetPopout() return pop end

Bar.LAYOUTS = CB.LAYOUTS

-- The kit's Settings card (Settings > Class tools; every paladin spec).
if ns.ClassKit then ns.ClassKit:Extend("bless", {
    iconPath = "Interface\\Icons\\Spell_Magic_GreaterBlessingofKings",
    action = { label = "Open planner", run = function() if ns.BlessingsUI then ns.BlessingsUI:Open() end end },
    settings = function(S, sec)
    CB.SettingsHead(S, sec, "bless", "Buff bar", "Your blessings per class: click to cast, right-click for the players.")
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
    CB.SettingsTail(S, sec, "bless")
end }) end

-- Key Bindings > AddOns: "Bless next" (Bindings.xml clicks DisasterZoneBlessNext)
BINDING_HEADER_DISASTERZONE = "DisasterZone"
_G["BINDING_NAME_CLICK DisasterZoneBlessNext:LeftButton"] = "Bless next (paladin)"

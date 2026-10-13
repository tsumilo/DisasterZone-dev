if DisasterZoneBoot and DisasterZoneBoot.Run("UI/LookTanks.lua", ...) then return end -- DisasterZone: UI/LookTanks.lua
-- The main tanks block: part of the party and raid frames (UI/LookUnits.lua's "group" part, option group.tanks, on),
-- in their look. Mockup claude.ai/artifact/CsS7UiuQrEXProchyuQ7jb, the user's pick B, 2026-10-13.
--   * one row per main tank (Core/Tanks.lua, in its order): the tank's raid cell (click: target them) and beside it
--     the mob they target (click: target it). Its second line says the mob's health, "on <name>" in grey when it hits
--     another main tank, "on <name>" in red with the ring lit when it hits someone who isn't one. With no target, the
--     plan's job greyed ("planned": the boss's strategy, StrategyLive:PlanTanks);
--   * a secure group header filtered by name (nameList = Tanks:Names(), sortMethod NAMELIST): the game keeps the rows
--     right in combat. The rows grow toward the raid frames: placed over them, they stack up from the block's foot
--     (point BOTTOM, sortDir DESC: tank 1 still on top); placed anywhere else, down from its top;
--   * the raid leader or an assistant, out of combat: drag a row to reorder (Tanks:SetOrder, shared with the raid);
--     the x at a row's end (a secure button: the game's maintank action, clear); with nobody set, the plan's tanks
--     greyed and "Set as main tanks" (a secure macro of /maintank lines). Setting a main tank is protected: only such
--     clicks do it. (No "+ Main tank": the user sets them from the raid's right-click menu, /maintank or the plan.)
--   * my target's cells (the tank, or the mob half) wear the raid frames' target mark, the hovered half its faint one;
--   * Edit layout item "group.tanks" (under the raid frames until moved); made-up rows while editing and in demo mode.
local addonName, ns = ...

local LT = ns:NewModule("LookTanks")
local UI = ns.UI
local Util = ns.Util

local floor, max, min = math.floor, math.max, math.min
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local tinsert, tremove, tsort, tconcat = table.insert, table.remove, table.sort, table.concat

local function Look() return ns.Look end
local function U() return ns.LookUnits end
local function T() return ns.Tanks end
local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end

local ROWS = 5            -- the block's box in Edit layout: five rows (more grow past it)
local MAX_ROWS = 8        -- rows made at login (nothing secure is made in a fight)
local HALF_GAP = 2        -- between a row's two halves (one object: closer than the raid cells' gap)
local X_SIZE = 16
local GOLD = ns.Style.C.GOLD
local RED = { 1, 0.42, 0.36 }
local GREY = { 0.62, 0.6, 0.55 }
local PLAN_ALPHA = 0.55

local holder, hd, planBtn, planNote, preview, ghost, line
local ghosts = {}         -- the plan's rows while nobody is set (insecure, made up from the plan)
local rows = {}           -- the header's rows (its children), in the order they were made
local up = false          -- the rows stack upward (the block sits over the raid frames)
local pending = false
local extrasPending = false

---------------------------------------------------------------------------
-- Sizes
---------------------------------------------------------------------------

local function Geometry()
    local look = Look():For("group")
    local cw, ch = U().CellSize(look)
    local gap = max(2, look.gap or 2)
    return cw, ch, gap, look
end

local function RowW()
    local cw = Geometry()
    return 2 * cw + HALF_GAP
end

local function BoxH()
    local _, ch, gap = Geometry()
    return ROWS * ch + (ROWS - 1) * gap
end

local function On()
    return Look():IsOn("group") and Look():Opt("group", "tanks", true) and true or false
end
LT.On = On

---------------------------------------------------------------------------
-- What a row shows
---------------------------------------------------------------------------

local TITLES = { High = true, King = true, Lady = true, Lord = true, Prince = true, Warlord = true, Overlord = true,
                 ["Fathom-Lord"] = true }
-- "High King Maulgar" -> "Maulgar", "Blindeye the Seer" -> "Blindeye": the half is one raid cell wide.
local function ShortMob(name)
    if type(name) ~= "string" then return "" end
    name = name:gsub(" the .*$", "")
    local words = {}
    for w in name:gmatch("%S+") do words[#words + 1] = w end
    while #words > 1 and TITLES[words[1]] do tremove(words, 1) end
    return tconcat(words, " ")
end
LT.ShortMob = ShortMob

local function Wipe(t)
    for k in pairs(t) do t[k] = nil end
    return t
end

-- The mob half's data: tank unit tu's target (or the plan's job for tank key when there is none).
local function MobData(tank, key, d)
    d = Wipe(d or {})
    local mu = tank and (tank .. "target")
    if mu and UnitExists and UnitExists(mu) then
        d.exists, d.unit = true, mu
        d.isPlayer = UnitIsPlayer(mu) and true or false
        d.name = UnitName(mu)
        if not d.isPlayer then d.name = ShortMob(d.name) end
        local _, class = UnitClass(mu)
        d.class = class
        d.level = UnitLevel(mu)
        d.classif = UnitClassification and UnitClassification(mu)
        d.hp, d.hpMax = UnitHealth(mu) or 0, UnitHealthMax(mu) or 1
        d.dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost(mu) or false
        d.reaction = UnitReaction and UnitReaction(mu, "player") or 4
        d.raidIcon = GetRaidTargetIndex and GetRaidTargetIndex(mu) or nil
        d.selected = UnitExists("target") and UnitIsUnit(mu, "target") or false
        if not d.dead and UnitCanAttack and UnitCanAttack("player", mu) then
            local tt = mu .. "target"
            local pct = floor(((d.hpMax > 0) and d.hp / d.hpMax or 0) * 100 + 0.5)
            if UnitExists(tt) and not UnitIsUnit(tt, tank) then
                local who, realm = UnitName(tt)
                who = who or "?"
                d.statusText = "on " .. who
                local whoKey = Util.NormalizeName((realm and realm ~= "") and (who .. "-" .. realm) or who)
                if UnitIsPlayer(tt) and not T():IsMain(whoKey) then
                    -- (it hits somebody who isn't a main tank: the half lights red)
                    d.statusColor, d.threat, d.lost = RED, 3, true
                else
                    d.statusColor = GREY
                end
            else
                d.statusText = pct .. "%"
            end
        end
        return d
    end
    local p = key and T():PlanFor(key)
    d.exists, d.isPlayer, d.reaction, d.hp, d.hpMax, d.plan = true, false, 2, 0, 1, true
    if p then
        d.name, d.raidIcon, d.statusText = ShortMob(p.label or ""), p.mark, "planned"
    else
        d.name, d.statusText = "", "no target"
    end
    d.statusColor = GREY
    return d
end
LT.MobData = MobData

local function PaintMob(mob, d)
    mob.face:Set(d)
    mob.host:SetAlpha(d.plan and PLAN_ALPHA or 1)
end

local function RefreshRow(row)
    if not row.face or not row.face.look then return end
    local unit = row:GetAttribute("unit")
    row.unitKey = unit
    if not unit then row.key = nil return end
    local d = U().Data(unit, row.data)
    row.data = d
    row.key = Util.UnitKey and Util.UnitKey(unit) or nil
    row.face:Set(d)
    row.mobData = MobData(unit, row.key, row.mobData)
    PaintMob(row.mob, row.mobData)
end
LT.RefreshRow = RefreshRow

local function EachRow(fn)
    for _, row in ipairs(rows) do
        if row:IsShown() then fn(row) end
    end
end

---------------------------------------------------------------------------
-- Tooltips, ×, drag to reorder
---------------------------------------------------------------------------

local function Tip(owner)
    local tt = GameTooltip
    if not tt then return nil end
    if GameTooltip_SetDefaultAnchor then GameTooltip_SetDefaultAnchor(tt, owner) else tt:SetOwner(owner, "ANCHOR_BOTTOMRIGHT") end
    return tt
end

local function ShowX(row)
    if row.x and not InCombat() and T():CanSet() then row.x:Show() end
end

local function HideXSoon(row)
    if not row.x then return end
    Util.After(0.25, function()
        if InCombat() or not row.x:IsShown() then return end
        if row:IsMouseOver() or row.x:IsMouseOver() then return end
        row.x:Hide()
    end)
end

local function RowEnter(row)
    ShowX(row)
    if row.face then row.face:SetHover(true) end
    local unit = row:GetAttribute("unit")
    local tt = unit and Tip(row)
    if not tt then return end
    tt:SetUnit(unit)
    local n = row.key and T():Number(row.key)
    if n then tt:AddLine("Main tank " .. n, GOLD[1], GOLD[2], GOLD[3]) end
    local p = row.key and T():PlanFor(row.key)
    if p and p.label then tt:AddLine("The plan: " .. p.label, 0.8, 0.8, 0.8) end
    if T():CanSet() and not InCombat() then
        tt:AddLine("Drag to reorder. The x at the row's end removes them.", 0.55, 0.55, 0.55, true)
    end
    tt:Show()
end

local function MobEnter(row)
    ShowX(row)
    if row.mob and row.mob.face then row.mob.face:SetHover(true) end
    local unit = row:GetAttribute("unit")
    local tt = unit and Tip(row.mob)
    if not tt then return end
    local mu = unit .. "target"
    if UnitExists(mu) then
        tt:SetUnit(mu)
        local d = row.mobData
        if d and d.lost then tt:AddLine(d.statusText .. ": not a main tank", RED[1], RED[2], RED[3]) end
    else
        local p = row.key and T():PlanFor(row.key)
        tt:SetText(p and p.label or "No target", 1, 1, 1)
        if p then tt:AddLine("Their job in the plan. Click once they target it.", 0.8, 0.8, 0.8, true) end
    end
    tt:Show()
end

local function Leave(row)
    if GameTooltip then GameTooltip:Hide() end
    if row.face then row.face:SetHover(false) end
    if row.mob and row.mob.face then row.mob.face:SetHover(false) end
    HideXSoon(row)
end

-- The rows on screen in their order, top to bottom: { { row, key } }.
local function ShownInOrder()
    local out = {}
    for _, e in ipairs(T():List()) do
        for _, row in ipairs(rows) do
            if row:IsShown() and row.key == e.key then out[#out + 1] = row end
        end
    end
    return out
end

local drag
local function Follow()
    if not drag then return end
    local x, y = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    x, y = x / s, y / s
    ghost:ClearAllPoints()
    ghost:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    -- the place: after every shown row whose middle is above the cursor
    local list, pos = {}, 1
    for _, row in ipairs(ShownInOrder()) do
        if row ~= drag.row then list[#list + 1] = row end
    end
    for _, row in ipairs(list) do
        local _, cy = row:GetCenter()
        local rs = row:GetEffectiveScale() / s
        if cy and cy * rs > y then pos = pos + 1 end
    end
    drag.pos = pos
    line:ClearAllPoints()
    local _, _, gap = Geometry()
    if list[pos] then line:SetPoint("BOTTOMLEFT", list[pos], "TOPLEFT", 0, floor(gap / 2))
    elseif list[pos - 1] then line:SetPoint("TOPLEFT", list[pos - 1], "BOTTOMLEFT", 0, -floor(gap / 2))
    else line:SetPoint("TOPLEFT", drag.row, "TOPLEFT", 0, 0) end
    line:SetWidth(RowW())
end

local function DragStart(row)
    if InCombat() or not T():CanSet() or not row.key or not T():IsMain(row.key) then return end
    if not ghost then
        ghost = CreateFrame("Frame", nil, UIParent)
        ghost:SetFrameStrata("TOOLTIP")
        ghost.face = U():NewFace(ghost, "cell", "group", "left")
        line = UIParent:CreateTexture(nil, "OVERLAY")
        line:SetHeight(2)
        line:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    end
    local _, _, _, look = Geometry()
    ghost.face:Apply(look)
    ghost.face:Set(row.data or {})
    ghost:SetAlpha(0.9)
    ghost:Show()
    line:Show()
    row:SetAlpha(0.35)
    drag = { row = row, key = row.key, pos = T():Number(row.key) or 1 }
    ghost:SetScript("OnUpdate", Follow)
    if GameTooltip then GameTooltip:Hide() end
end

local function DragStop()
    local d = drag
    drag = nil
    if ghost then ghost:SetScript("OnUpdate", nil); ghost:Hide() end
    if line then line:Hide() end
    if not d then return end
    d.row:SetAlpha(1)
    if d.pos and d.pos ~= T():Number(d.key) and not InCombat() then T():Move(d.key, d.pos) end
end
LT.DragStart, LT.DragStop = DragStart, DragStop

---------------------------------------------------------------------------
-- Rows (the header's children)
---------------------------------------------------------------------------

-- The ×: a secure button doing the game's own "maintank" action (clear) on its row's unit, drawn as the windows'
-- flat close X on a dark disc (red under the mouse).
local function NewX(row, name)
    local x = CreateFrame("Button", name .. "Clear", row, "SecureActionButtonTemplate")
    x:SetSize(X_SIZE, X_SIZE)
    x:SetAttribute("type", "maintank")
    x:SetAttribute("action", "clear")
    x:SetAttribute("useparent-unit", true)
    x:SetAttribute("useOnKeyDown", false)
    x:RegisterForClicks("AnyUp")
    x.bg = x:CreateTexture(nil, "BACKGROUND")
    x.bg:SetAllPoints()
    x.bg:SetTexture(Look().DISC)
    x.bg:SetVertexColor(0.11, 0.11, 0.13, 0.95)
    x.strokes = {}
    for i, sy in ipairs({ 1, -1 }) do
        local s = x:CreateLine(nil, "ARTWORK")
        s:SetColorTexture(1, 1, 1, 1)
        s:SetVertexColor(0.84, 0.84, 0.86)
        s:SetThickness(1.5)
        s:SetStartPoint("CENTER", x, -3, -3 * sy)
        s:SetEndPoint("CENTER", x, 3, 3 * sy)
        x.strokes[i] = s
    end
    x:SetScript("OnEnter", function(self)
        self.bg:SetVertexColor(0.64, 0.14, 0.12, 1)
        local tt = Tip(self)
        if tt then
            tt:SetText("No longer a main tank", 1, 1, 1)
            tt:Show()
        end
    end)
    x:SetScript("OnLeave", function(self)
        self.bg:SetVertexColor(0.11, 0.11, 0.13, 0.95)
        Leave(row)
    end)
    x:HookScript("PostClick", function(self) if not InCombat() then self:Hide() end end)
    x:Hide()
    return x
end

local function LayRow(row)
    local cw, ch = Geometry()
    row.left:SetSize(cw, ch)
    row.mob:ClearAllPoints()
    row.mob:SetPoint("TOPLEFT", row, "TOPLEFT", cw + HALF_GAP, 0)
    if not (row:IsProtected() and InCombat()) then
        row:SetSize(RowW(), ch)
        row.mob:SetSize(cw, ch)
        if row.x then
            row.x:ClearAllPoints()
            row.x:SetPoint("LEFT", row, "RIGHT", 4, 0)
        end
    end
end

local function InitRow(name)
    local row = _G[name]
    if not row or row.dzRow then return end
    row.dzRow = true
    row:RegisterForClicks("AnyUp")
    row:SetFrameStrata("LOW")
    local _, _, _, look = Geometry()
    -- the tank: a raid cell
    row.left = CreateFrame("Frame", nil, row)
    row.left:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.face = U():NewFace(row.left, "cell", "group", "left")
    -- the mob: the game's "<tank>target" unit, a click targets it
    local mob = CreateFrame("Button", name .. "Mob", row, "SecureUnitButtonTemplate")
    mob:SetAttribute("useparent-unit", true)
    mob:SetAttribute("unitsuffix", "target")
    mob:SetAttribute("*type1", "target")
    mob:RegisterForClicks("AnyUp")
    mob.host = CreateFrame("Frame", nil, mob)
    mob.host:SetPoint("TOPLEFT", mob, "TOPLEFT", 0, 0)
    mob.face = U():NewFace(mob.host, "cell", "group", "left")
    row.mob = mob
    row.x = NewX(row, name)
    row.face:Apply(look)
    mob.face:Apply(look)
    LayRow(row)
    row:HookScript("OnShow", RefreshRow)
    row:HookScript("OnAttributeChanged", function(self, attr) if attr == "unit" then RefreshRow(self) end end)
    row:HookScript("OnEnter", RowEnter)
    row:HookScript("OnLeave", Leave)
    mob:HookScript("OnEnter", function() MobEnter(row) end)
    mob:HookScript("OnLeave", function() Leave(row) end)
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", DragStart)
    row:SetScript("OnDragStop", DragStop)
    rows[#rows + 1] = row
end
LT.InitRow = InitRow

-- (the restricted snippet each row runs when the header makes it: size, clicks, then InitRow)
local CHILD = [[
    self:SetWidth(%d)
    self:SetHeight(%d)
    self:SetAttribute("*type1", "target")
    self:SetAttribute("*type2", "togglemenu")
    self:GetParent():CallMethod("InitRow", self:GetName())
]]

---------------------------------------------------------------------------
-- Leader's tools: + and its list, the plan's button
---------------------------------------------------------------------------

-- "Set as main tanks": a secure macro button, dressed as the addon's primary button (the look under it).
local function NewPlanButton()
    local b = CreateFrame("Button", "DisasterZoneTankPlanButton", holder, "SecureActionButtonTemplate")
    b:SetAttribute("type", "macro")
    b:SetAttribute("useOnKeyDown", false)
    b:RegisterForClicks("AnyUp")
    b:SetSize(130, 22)
    b.look = UI:CreateSleekButton(b, "Set as main tanks", 130, 22, nil, "primary")
    b.look:SetAllPoints(b)
    b.look:EnableMouse(false)
    b:SetScript("OnEnter", function(self)
        self.look.hovered = true
        if self.look.cdlPaint then self.look:cdlPaint() end
        local tt = Tip(self)
        if tt then
            tt:SetText("Set as main tanks", 1, 1, 1)
            tt:AddLine("Makes the plan's tanks main tanks, in its order.", 0.8, 0.8, 0.8, true)
            tt:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        self.look.hovered = nil
        if self.look.cdlPaint then self.look:cdlPaint() end
        if GameTooltip then GameTooltip:Hide() end
    end)
    b:Hide()
    return b
end

---------------------------------------------------------------------------
-- Placing the rows and the extras
---------------------------------------------------------------------------

-- Does the block sit over the raid frames (its middle above theirs)?
local function OverRaid()
    local rh = U().holders and U().holders.raid
    if not (rh and holder) then return false end
    local _, hy = holder:GetCenter()
    local _, ry = rh:GetCenter()
    if not hy or not ry then return false end
    return hy * holder:GetEffectiveScale() > ry * rh:GetEffectiveScale()
end

-- The ghost rows: the plan's tanks, greyed, while nobody is set.
local function Ghost(i)
    local g = ghosts[i]
    if g then return g end
    g = CreateFrame("Frame", nil, holder)
    g.left = CreateFrame("Frame", nil, g)
    g.left:SetPoint("TOPLEFT")
    g.face = U():NewFace(g.left, "cell", "group", "left")
    g.right = CreateFrame("Frame", nil, g)
    g.face2 = U():NewFace(g.right, "cell", "group", "left")
    g:SetAlpha(PLAN_ALPHA)
    ghosts[i] = g
    return g
end

-- Position of row slot i (1 = tank 1) in the block: its offset from the holder's top (down) or foot (up).
local function SlotPoint(f, i, n)
    local _, ch, gap = Geometry()
    f:ClearAllPoints()
    if up then f:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, (n - i) * (ch + gap))
    else f:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -(i - 1) * (ch + gap)) end
end

local function PlaceExtras()
    if not holder then return end
    if InCombat() then extrasPending = true return end
    extrasPending = false
    local cw, ch, gap, look = Geometry()
    local tanks = T():List()
    local lead = T():CanSet()
    local inRaid = IsInRaid and IsInRaid() and On()
    -- the plan, greyed, while nobody is set
    local planList = (inRaid and #tanks == 0) and T():PlanInRaid() or {}
    for i, p in ipairs(planList) do
        local g = Ghost(i)
        g:SetSize(RowW(), ch)
        g.left:SetSize(cw, ch)
        g.right:ClearAllPoints()
        g.right:SetPoint("TOPLEFT", g, "TOPLEFT", cw + HALF_GAP, 0)
        g.right:SetSize(cw, ch)
        g.face:Apply(look)
        g.face2:Apply(look)
        local _, class = UnitClass(p.unit)
        g.face:Set({ exists = true, name = p.name:match("^[^%-]+") or p.name, class = class, isPlayer = true,
                     hp = 0, hpMax = 1, statusText = "" })
        g.face2:Set(MobData(nil, p.key))
        SlotPoint(g, i, #planList)
        g:Show()
    end
    for i = #planList + 1, #ghosts do ghosts[i]:Hide() end
    -- what sits past the stack (over it when the rows grow up, under it when they grow down)
    local n = #planList > 0 and #planList or min(#tanks, MAX_ROWS)
    local function Past(f, dy)
        f:ClearAllPoints()
        if up then f:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, n * (ch + gap) + (dy or 0))
        else f:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -(n * (ch + gap)) - (dy or 0)) end
    end
    -- "Set as main tanks" (leader / assistants) or a note (everyone else)
    local macro = (#planList > 0 and lead) and T():PlanMacro() or nil
    if macro then
        planBtn:SetAttribute("macrotext", macro)
        Past(planBtn)
        planBtn:Show()
    else
        planBtn:Hide()
        planBtn:SetAttribute("macrotext", nil)
    end
    if #planList > 0 then
        planNote:ClearAllPoints()
        if macro then planNote:SetPoint("LEFT", planBtn, "RIGHT", 8, 0)
        else Past(planNote, 4) end
        planNote:SetText(macro and "From the plan" or "From the plan · not set in game yet")
        planNote:Show()
    else
        planNote:Hide()
    end
end
LT.PlaceExtras = PlaceExtras

-- The rows grow toward the raid frames; the header's names follow the tanks' order.
function LT:Orient()
    if not hd or InCombat() then pending = true return end
    local _, _, gap = Geometry()
    up = OverRaid()
    hd:ClearAllPoints()
    if up then
        hd:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
        hd:SetAttribute("sortDir", "DESC")
        hd:SetAttribute("yOffset", gap)
        hd:SetAttribute("point", "BOTTOM")
    else
        hd:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        hd:SetAttribute("sortDir", "ASC")
        hd:SetAttribute("yOffset", -gap)
        hd:SetAttribute("point", "TOP")
    end
    PlaceExtras()
end

function LT:Names()
    if not hd then return end
    if InCombat() then pending = true return end
    local names = On() and T():Names() or ""
    if hd:GetAttribute("nameList") ~= names then hd:SetAttribute("nameList", names) end
end

---------------------------------------------------------------------------
-- Made-up rows (Edit layout, demo mode)
---------------------------------------------------------------------------

local FAKE = {
    { "Victhar", "WARRIOR", 0.72, "Maulgar", 8, 0.88 },
    { "Ironbark", "WARRIOR", 0.85, "Blindeye", 7, 0.41, "Dreadhex" },
    { "Moonwhisper", "DRUID", 0.91, "Olm", 6, 0.93 },
}

local function FillPreview()
    local cw, ch, gap, look = Geometry()
    preview:SetAllPoints(holder)
    preview.rows = preview.rows or {}
    up = OverRaid()
    for i, f in ipairs(FAKE) do
        local r = preview.rows[i]
        if not r then
            r = CreateFrame("Frame", nil, preview)
            r.left = CreateFrame("Frame", nil, r)
            r.left:SetPoint("TOPLEFT")
            r.face = U():NewFace(r.left, "cell", "group", "left")
            r.right = CreateFrame("Frame", nil, r)
            r.face2 = U():NewFace(r.right, "cell", "group", "left")
            preview.rows[i] = r
        end
        r:SetSize(RowW(), ch)
        r.left:SetSize(cw, ch)
        r.right:ClearAllPoints()
        r.right:SetPoint("TOPLEFT", r, "TOPLEFT", cw + HALF_GAP, 0)
        r.right:SetSize(cw, ch)
        r.face:Apply(look)
        r.face2:Apply(look)
        local max = 15000 + i * 900
        r.face:Set({ exists = true, name = f[1], class = f[2], isPlayer = true, hp = floor(max * f[3]), hpMax = max, mt = i })
        local lost = f[7] ~= nil
        r.face2:Set({ exists = true, name = f[4], isPlayer = false, reaction = 2, hp = floor(1e6 * f[6]), hpMax = 1e6,
                      raidIcon = f[5], statusText = lost and ("on " .. f[7]) or (floor(f[6] * 100 + 0.5) .. "%"),
                      statusColor = lost and RED or nil, threat = lost and 3 or nil })
        r:ClearAllPoints()
        if up then r:SetPoint("BOTTOMLEFT", preview, "BOTTOMLEFT", 0, (#FAKE - i) * (ch + gap))
        else r:SetPoint("TOPLEFT", preview, "TOPLEFT", 0, -(i - 1) * (ch + gap)) end
        r:Show()
    end
end

function LT:ShowPreview(on)
    if not holder then return end
    if not preview then
        preview = CreateFrame("Frame", nil, holder)
        preview:SetFrameStrata("LOW")
    end
    if not on then preview:Hide() return end
    FillPreview()
    preview:Show()
end

function LT:Demo()
    if not holder then return end
    local on = On() and ns.Demo and ns.Demo:IsEnabled() and not (IsInRaid and IsInRaid())
    self:ShowPreview(on and true or false)
end

---------------------------------------------------------------------------
-- Building, restyling, events
---------------------------------------------------------------------------

local function Visibility()
    if not hd or InCombat() then pending = true return end
    if On() then
        if RegisterAttributeDriver then RegisterAttributeDriver(hd, "state-visibility", "[group:raid] show; hide")
        else hd:SetShown(IsInRaid and IsInRaid() or false) end
        hd.dzVisibility = "[group:raid] show; hide"
    else
        if UnregisterAttributeDriver then UnregisterAttributeDriver(hd, "state-visibility") end
        hd:Hide()
        hd.dzVisibility = "hide"
    end
end

-- Under the raid frames, at their left edge (until it is moved in Edit layout).
local function DefaultPlace()
    local _, ch, gap = Geometry()
    local rh = U().holders and U().holders.raid
    local l, b = rh and rh:GetLeft(), rh and rh:GetBottom()
    if l and b and rh:GetWidth() and rh:GetWidth() > 0 then
        local r = rh:GetEffectiveScale() / max(0.01, UIParent:GetEffectiveScale())
        local H = UIParent:GetHeight() or 768
        return { "TOPLEFT", floor(l * r + 0.5), floor(b * r - 10 - H + 0.5) }
    end
    return { "TOPLEFT", 20, -220 - (5 * ch + 4 * gap) - 10 }
end

local function RegisterItem()
    local Lay = ns.Layout
    if not Lay then return end
    Lay:Register("group.tanks", { name = "Main tanks", group = "Game frames", order = 8, protected = true, noHide = true,
        default = DefaultPlace,
        frame = function() return holder end,
        box = function()
            for _, row in ipairs(rows) do
                if row:IsVisible() then return holder end
            end
            if preview and preview:IsVisible() then return holder end
            return false
        end,
        when = "in a raid with main tanks",
        preview = function(on) LT:ShowPreview(on) end })
end

function LT:Setup()
    if not Look():IsOn("group") or not U() or not U().holders then return end
    if InCombat() then pending = true return end
    pending = false
    if not holder then
        local _, ch = Geometry()
        holder = CreateFrame("Frame", "DisasterZoneTankFrames", UIParent)
        holder:SetFrameStrata("LOW")
        holder:SetSize(RowW(), BoxH())
        hd = CreateFrame("Frame", "DisasterZoneTankHeader", holder, "SecureGroupHeaderTemplate")
        hd:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        hd:SetAttribute("template", "SecureUnitButtonTemplate")
        hd:SetAttribute("initialConfigFunction", CHILD:format(RowW(), ch))
        hd:SetAttribute("showRaid", true)
        hd:SetAttribute("showParty", false)
        hd:SetAttribute("sortMethod", "NAMELIST")
        hd:SetAttribute("nameList", "")
        hd:SetAttribute("point", "TOP")
        function hd:InitRow(name) InitRow(name) end
        -- every row made now, out of combat (as the raid frames' buttons are)
        hd:SetAttribute("startingIndex", -MAX_ROWS + 1)
        hd:Show()
        hd:SetAttribute("startingIndex", 1)
        planBtn = NewPlanButton()
        planNote = UI:Text(holder, "small", "SUB")
        planNote:Hide()
        RegisterItem()
    end
    holder:SetSize(RowW(), BoxH())
    if ns.Layout then ns.Layout:Place("group.tanks") end
    self:Names()
    Visibility()
    self:Orient()
    self:Refresh()
end

-- The look changed (UI/LookUnits.lua Restyle): new sizes and faces.
function LT:Restyle()
    if not holder then return self:Setup() end
    local _, _, _, look = Geometry()
    for _, row in ipairs(rows) do
        row.face:Apply(look)
        row.mob.face:Apply(look)
        LayRow(row)
    end
    if not InCombat() then
        holder:SetSize(RowW(), BoxH())
        local _, ch = Geometry()
        hd:SetAttribute("initialConfigFunction", CHILD:format(RowW(), ch))
    end
    Visibility()
    self:Names()
    self:Orient()
    self:Refresh()
    if preview and preview:IsShown() then FillPreview() end
end

function LT:Refresh()
    EachRow(RefreshRow)
    PlaceExtras()
end

function LT:Header() return hd end
function LT:Holder() return holder end
function LT:Rows() return rows end
function LT:PlanButton() return planBtn end
function LT:PlanNote() return planNote end
function LT:Ghosts() return ghosts end
function LT:Preview() return preview end
function LT:IsUp() return up end

local since = 0
local function OnUpdate(_, dt)
    since = since + (dt or 0)
    if since < 0.2 then return end
    since = 0
    -- (no event says a tank's target changed health or turned: every 0.2 s)
    for _, row in ipairs(rows) do
        if row:IsShown() and row.unitKey then
            row.mobData = MobData(row.unitKey, row.key, row.mobData)
            PaintMob(row.mob, row.mobData)
        end
    end
end

local UNIT_EVENTS = { UNIT_HEALTH = true, UNIT_MAXHEALTH = true, UNIT_CONNECTION = true, UNIT_AURA = true,
                      UNIT_THREAT_SITUATION_UPDATE = true, UNIT_TARGET = true, UNIT_FLAGS = true, UNIT_NAME_UPDATE = true }

local function OnEvent(_, event, unit)
    if UNIT_EVENTS[event] then
        for _, row in ipairs(rows) do
            if row:IsShown() and row.unitKey == unit then RefreshRow(row) end
        end
        return
    end
    if event == "PLAYER_TARGET_CHANGED" then
        -- (the target marks only: my target's tank or mob half)
        local has = UnitExists("target")
        for _, row in ipairs(rows) do
            if row:IsShown() and row.unitKey then
                row.face:SetTarget(has and UnitIsUnit(row.unitKey, "target"))
                row.mob.face:SetTarget(has and UnitIsUnit(row.unitKey .. "target", "target"))
            end
        end
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then
        -- (the last moment our secure frames may hide before the fight locks them)
        if planBtn then planBtn:Hide() end
        for _, row in ipairs(rows) do if row.x then row.x:Hide() end end
        DragStop()
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        if pending then LT:Setup() elseif extrasPending then PlaceExtras() end
        return
    end
    LT:Refresh()
end

function LT:OnLogin()
    self:Setup()
    local f = CreateFrame("Frame")
    for e in pairs(UNIT_EVENTS) do pcall(f.RegisterEvent, f, e) end
    for _, e in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "RAID_TARGET_UPDATE", "GROUP_ROSTER_UPDATE",
                         "PARTY_LEADER_CHANGED", "PLAYER_TARGET_CHANGED" }) do pcall(f.RegisterEvent, f, e) end
    f:SetScript("OnEvent", OnEvent)
    f:SetScript("OnUpdate", OnUpdate)
    ns:On("TANKS_CHANGED", function()
        LT:Names()
        LT:Refresh()
    end)
    ns:On("DEMO_TOGGLED", function() LT:Demo() end)
    ns:On("EDIT_LAYOUT", function(on) if not on then LT:Orient() end end)
    ns:On("LAYOUT_CHANGED", function(what) if what == "applied" or what == "profile" then LT:Orient() end end)
    self:Demo()
end

if DisasterZoneBoot and DisasterZoneBoot.Run("UI/TotemBar.lua", ...) then return end -- DisasterZone: totem bar.
-- The shaman's totem bar for the Totem planner (Core/Totems.lua), shown in a party or raid when I have totems
-- planned. It is the Blessings bar's sibling (UI/BlessingsBar.lua): the same sizes, header, motion and two layouts
-- (setting totems.layout, also in the planner's More menu):
--   "vertical"   Rail: a slim column of round totem icons. A ring around each drains as my totem runs out (the
--                game's cooldown swipe: nothing ticks); the second totem (twist partner or a boss's next phase) in
--                the corner; a red count of party members out of its range; the one thing to do glows and names
--                itself on the left ("Windfury · drop now"). Top: Heroism (gold ring = ready), its plan under it,
--                Mana Tide beside it.
--   "horizontal" Strip: a tray of totem tiles with a hairline in the element's colour that shrinks with the time
--                left; the tile to do next lifts with a gold chip. Heroism and Mana Tide on the left.
-- The twisting shaman's Air ring is Windfury on the party's weapons (10 s after a drop), not the totem. One thing at a
-- time is named: twist due, Earth Shield low or missing, a totem about to end in combat, a missing imbue.
-- No panel behind it (only a faint one while unlocked, to drag it by). The faces ease with the Blessings bar's own
-- motion (BlessingsBar.Aim): hot looks fade in and out, the strip's tile lifts, a bloom when it is done.
-- Clicks: a totem casts the planned one (twisting: Windfury and its partner in turn); right-click casts the second.
-- Every cast is a secure button set out of combat (WoW forbids changing them in a fight): in combat the bar keeps
-- its spells, and catches up when the fight ends. Hover a totem with someone out of range for who.
local addonName, ns = ...

local Bar = ns:NewModule("TotemBar")

local floor, max, min = math.floor, math.max, math.min
local strformat = string.format

local RING = "Interface\\AddOns\\DisasterZone\\Media\\Blessings\\ring"
local SOFT = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
local WHITE8 = "Interface\\Buttons\\WHITE8X8"
local CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
local GOLD = { 1, 0.82, 0 }
local RED = { 0.91, 0.38, 0.3 }
local GLASS = { 0.047, 0.047, 0.059, 0.78 }

-- the Blessings bar's geometry: rail (vertical) and strip (horizontal)
local R_S, R_GAP, R_PAD, R_HEAD = 28, 9, 9, 50
local S_T, S_GAP, S_PAD, S_SIDE = 30, 6, 12, 44
local POP_W, POP_ROW = 186, 21
local KINDS = { "el1", "el2", "el3", "el4", "es", "mh", "oh" }

local function T() return ns.Totems end
local function UI() return ns.UI end
local function Motion() return ns.BlessingsBar end

local frame, pop
local rows = {}                             -- by kind (KINDS)

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

local function SetSquareIcon(tex, path)
    tex.roundPath = nil
    tex:SetTexture(path)
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
end

-- (presses and releases: the client's "cast on key down" makes the secure template act on the press)
local function Secure(parent, name)
    local b = CreateFrame("Button", name, parent, "SecureActionButtonTemplate")
    b:RegisterForClicks("AnyUp", "AnyDown")
    return b
end

local function Seconds(left)
    if not left then return "" end
    if left >= 60 then return strformat("%dm", floor(left / 60 + 0.5)) end
    return strformat("%ds", floor(left + 0.5))
end

local function Layout()
    return T().Setting("layout", "vertical") == "horizontal" and "horizontal" or "vertical"
end
Bar.Layout = Layout

local function MissingBadge(parent)
    local b = UI():CreateCountBadge(parent, 12)
    for _, t in ipairs(b.body or {}) do t:SetVertexColor(RED[1], RED[2], RED[3], 1) end
    if b.fs then b.fs:SetTextColor(1, 1, 1) end
    if b.SetCutout then b:SetCutout(GLASS[1], GLASS[2], GLASS[3]) end
    return b
end

-- Is the bar for me now: a shaman (the class tool), in a group the setting allows, with totems planned?
function Bar:Wanted()
    if not (ns.ClassKit and ns.ClassKit:IsMine("totems") and ns.ClassKit:IsOn("totems")) then return false end
    local Tm = T()
    local mode = Tm.Setting("bar", "group")
    if mode == "off" then return false end
    if mode == "raid" and not (IsInRaid() or Tm:IsDemo()) then return false end
    if mode == "always" then return Tm:Me() ~= nil end
    if not Tm:InGroup() then return false end
    local me = Tm:Me()
    if not me then return false end
    for el = 1, 4 do
        if Tm:GetAssign(me, el) then return true end
    end
    return Tm:GetES(me) ~= nil
end

-- ---------------------------------------------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------------------------------------------
local function SavePos()
    local point, _, rel, x, y = frame:GetPoint(1)
    if not point then return end
    local pos = T().Setting("pos")
    pos = type(pos) == "table" and pos or {}
    local copy = {}
    for k, v in pairs(pos) do copy[k] = v end
    copy[Layout()] = { point, rel, floor(x + 0.5), floor(y + 0.5) }
    ns.DB:SetSetting("totems.pos", copy)
end

-- (its own places, clear of the Blessings bar's: the rail left of it, the strip above it)
local function RestorePos()
    frame:ClearAllPoints()
    local pos = T().Setting("pos")
    local p = type(pos) == "table" and pos[Layout()]
    if type(p) == "table" and p[1] then
        frame:SetPoint(p[1], UIParent, p[2] or p[1], p[3] or 0, p[4] or 0)
    elseif Layout() == "horizontal" then
        frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 205)
    else
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -420, 40)
    end
end

-- One totem (or Earth Shield, an imbue): a secure button; its looks sit on a face with the Blessings bar's parts, so
-- BlessingsBar.Aim can move it.
local function NewRow(kind)
    local r = Secure(frame, "DisasterZoneTotem_" .. kind)
    r:SetSize(R_S, R_S)
    r.kind = kind
    local face = CreateFrame("Frame", nil, r)
    face:SetSize(R_S, R_S)
    face:SetPoint("CENTER")
    r.face = face
    face.glow = face:CreateTexture(nil, "BACKGROUND")
    face.glow:SetTexture(SOFT)
    face.glow:SetPoint("CENTER")
    face.glow:SetVertexColor(1, 0.78, 0.16, 0.55)
    face.glow:SetAlpha(0)
    face.bloom = face:CreateTexture(nil, "OVERLAY", nil, 2)
    face.bloom:SetPoint("CENTER")
    face.bloom:SetBlendMode("ADD")
    face.bloom:Hide()
    face.halo = face:CreateTexture(nil, "BACKGROUND", nil, 1)
    face.halo:SetTexture(SOFT)
    face.halo:SetPoint("CENTER")
    face.halo:SetBlendMode("ADD")
    face.halo:SetVertexColor(1, 1, 1)
    face.halo:SetAlpha(0)
    -- rail: the track, the draining ring, the round icon (the Blessings rail's class circle)
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
    -- strip: the totem tile and its hairline
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
    -- both: the second totem in the corner, the out-of-range count, Earth Shield's charges
    face.corner = face.top:CreateTexture(nil, "OVERLAY")
    face.corner:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    face.cornerBox = CreateFrame("Frame", nil, face.top)
    face.miss = MissingBadge(face.top)
    face.miss:SetFrameLevel(face.top:GetFrameLevel() + 2)
    face.count = UI():CreateCountBadge(face.top, 12)
    face.count:SetFrameLevel(face.top:GetFrameLevel() + 2)
    face.label = CreateFrame("Frame", nil, face)
    face.label:SetHeight(16)
    face.label.bg = Fill(face.label:CreateTexture(nil, "BACKGROUND"), GLASS[1], GLASS[2], GLASS[3], 0.9)
    face.label.bg:SetAllPoints()
    face.label.text = Text(face.label, 10, { 1, 0.9, 0.55 })
    face.label.text:SetPoint("CENTER", 0, 0)
    face.label:Hide()
    r:HookScript("OnEnter", function(self) Bar:Hover(self, true) end)
    r:HookScript("OnLeave", function(self) Bar:Hover(self, false) end)
    rows[kind] = r
    return r
end

-- A small round header icon (Heroism, Mana Tide): secure, with a ring (the Blessings bar's aura / Righteous Fury).
local function HeaderIcon(name, size)
    local b = Secure(frame, name)
    b:SetSize(size, size)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.ring = b:CreateTexture(nil, "OVERLAY")
    b.ring:SetTexture(RING)
    b.ring:SetPoint("TOPLEFT", -2, 2)
    b.ring:SetPoint("BOTTOMRIGHT", 2, -2)
    b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cd:SetAllPoints()
    if b.cd.SetHideCountdownNumbers then b.cd:SetHideCountdownNumbers(true) end
    if b.cd.SetDrawEdge then b.cd:SetDrawEdge(false) end
    b.cd:EnableMouse(false)
    b:SetAttribute("type", "spell")
    return b
end

local function Build()
    frame = CreateFrame("Frame", "DisasterZoneTotemBar", UIParent)
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
        if not T().Setting("locked", true) and not InCombatLockdown() then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePos()
    end)

    local hero = HeaderIcon("DisasterZoneTotem_hero", 20)
    hero:HookScript("OnEnter", function(self) Bar:HeaderTip(self, "hero") end)
    hero:HookScript("OnLeave", function() GameTooltip:Hide() end)
    frame.hero = hero
    local tide = HeaderIcon("DisasterZoneTotem_tide", 16)
    tide:HookScript("OnEnter", function(self) Bar:HeaderTip(self, "tide") end)
    tide:HookScript("OnLeave", function() GameTooltip:Hide() end)
    frame.tide = tide
    -- the Heroism plan under it ("Pull"), like the Blessings rail's Symbols count
    frame.plan = Text(frame, 10, { 0.81, 0.81, 0.84 }, "GameFontHighlightSmall")
    frame.div1 = Fill(frame:CreateTexture(nil, "ARTWORK"), 1, 1, 1, 0.08)
    for _, kind in ipairs(KINDS) do NewRow(kind) end

    pop = CreateFrame("Frame", "DisasterZoneTotemRange", UIParent)
    pop:SetSize(POP_W, 40)
    pop:SetFrameStrata("DIALOG")
    pop.bg = Fill(pop:CreateTexture(nil, "BACKGROUND"), GLASS[1], GLASS[2], GLASS[3], 0.94)
    pop.bg:SetAllPoints()
    Edge(pop, 1, 1, 1, 0.09)
    pop.title = Text(pop, 8.5, { 0.6, 0.6, 0.65 })
    pop.title:SetPoint("TOPLEFT", pop, "TOPLEFT", 12, -9)
    pop.rows = {}
    pop.hint = Text(pop, 8.5, { 0.47, 0.47, 0.51 })
    pop:Hide()

    local acc, live = 0, 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        live = live + (elapsed or 0)
        if live >= 0.25 then
            live = 0
            Bar:UpdateLooks()
        end
        if acc >= 2 then
            acc = 0
            Bar:Update()
        end
    end)
    RestorePos()
end

-- ---------------------------------------------------------------------------------------------------------------
-- What each button is now
-- ---------------------------------------------------------------------------------------------------------------
local function MainHandImbue()
    local Tm = T()
    local v = Tm.Setting("imbueMH", "auto")
    if v == "auto" then v = (Tm:SpecOf(Tm:Me()) == "Enhancement") and "wf" or "ft" end
    return v
end

local function OffHandImbue()
    local Tm = T()
    local v = Tm.Setting("imbueOH", "auto")
    if v == "auto" then
        local dual = OffhandHasWeapon and OffhandHasWeapon()
        if Tm:IsDemo() then dual = Tm:SpecOf(Tm:Me()) == "Enhancement" end
        v = (dual and Tm:SpecOf(Tm:Me()) == "Enhancement") and "ft" or "none"
    end
    return v
end

local function Imbue(key)
    for _, i in ipairs(T().D.IMBUES) do if i.key == key then return i end end
    return nil
end

-- seconds left of my weapon imbue in a hand (nil: none)
local function ImbueLeft(hand)
    if T():IsDemo() then return 1200 end
    if not GetWeaponEnchantInfo then return nil end
    local hasMH, mhExp, _, _, hasOH, ohExp = GetWeaponEnchantInfo()
    if hand == "mh" then return hasMH and (mhExp or 0) / 1000 or nil end
    return hasOH and (ohExp or 0) / 1000 or nil
end

local function SpellCooldown(id)
    if not GetSpellCooldown then return nil end
    local start, dur = GetSpellCooldown(id)
    if start and dur and dur > 1.5 then return start, dur end
    return nil
end

-- The rows the bar shows: { kind, el, main, alt, why, target, imbue, hand }; .tide = Mana Tide in the header.
function Bar:Plan()
    local Tm = T()
    local me = Tm:Me()
    local boss = Tm:CurrentBoss()
    local out = {}
    for el = 1, 4 do
        local main, alt, why = Tm:Effective(me, el, boss)
        if main or alt then
            out[#out + 1] = { kind = "el" .. el, el = el, main = main or alt, alt = main and alt or nil, why = why }
        end
    end
    local s = Tm.shamans[me]
    local target = Tm:GetES(me)
    if target and s and s.es then out[#out + 1] = { kind = "es", target = target } end
    if Tm.Setting("imbue", false) then
        local mh = Imbue(MainHandImbue())
        if mh then out[#out + 1] = { kind = "mh", imbue = mh, hand = "mh" } end
        local oh = Imbue(OffHandImbue())
        if oh then out[#out + 1] = { kind = "oh", imbue = oh, hand = "oh" } end
    end
    local tideKnown = s and s.known[Tm.D.MANA_TIDE[1]][Tm.D.MANA_TIDE[2]]
    local planned3 = Tm:Effective(me, 3, boss)
    out.tide = (tideKnown and planned3 ~= Tm.D.MANA_TIDE[2]) and true or false
    return out
end

-- The one thing to do now: { kind, text (rail), short (strip) }.
function Bar:Urgent(list)
    local Tm = T()
    local fight = InCombatLockdown() or Tm:IsDemo()
    local warnTwist = tonumber(Tm.Setting("twistWarn", 3)) or 3
    for _, p in ipairs(list) do
        if p.why == "twist" and fight then
            local left = Tm:WindfuryLeft()
            if not left or left <= warnTwist then
                return { kind = p.kind, text = Tm.D.TOTEMS[4][Tm.D.WINDFURY[2]].short .. " · drop now", short = "drop now" }
            end
        end
    end
    local esWarn = tonumber(Tm.Setting("esWarn", 2)) or 2
    for _, p in ipairs(list) do
        if p.kind == "es" and esWarn > 0 then
            local n = Tm:ESCharges(p.target)
            if n == 0 and Tm:InGroup() then
                return { kind = "es", text = strformat("Earth Shield · %s · missing", p.target), short = "missing" }
            end
            if n > 0 and n <= esWarn then
                return { kind = "es", text = strformat("Earth Shield · %s · %d left", p.target, n), short = n .. " left" }
            end
        end
    end
    if InCombatLockdown() then
        for _, p in ipairs(list) do
            if p.el and p.why ~= "twist" then
                local _, start, dur = Tm:MyTotem(p.el)
                local left = start and (start + dur - GetTime())
                if left and left < 10 then
                    return { kind = p.kind, text = strformat("%s · %s", Tm:TotemShort(p.el, p.main), Seconds(left)),
                        short = Seconds(left) }
                end
            end
        end
    end
    for _, p in ipairs(list) do
        if p.imbue and not ImbueLeft(p.hand) then
            return { kind = p.kind, text = p.imbue.short .. " · missing", short = "missing" }
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------------------------
-- Layout and secure attributes (out of combat)
-- ---------------------------------------------------------------------------------------------------------------
local function SetAttributes(b, p)
    local Tm = T()
    for _, k in ipairs({ "type1", "spell1", "macrotext1", "type2", "spell2" }) do b:SetAttribute(k, nil) end
    if Tm:IsDemo() then return end
    if p.el then
        local mainName = Tm:TotemName(p.el, p.main)
        local altName = p.alt and Tm:TotemName(p.el, p.alt)
        if p.why == "twist" and altName then
            b:SetAttribute("type1", "macro")
            b:SetAttribute("macrotext1", strformat("/castsequence reset=combat %s, %s", mainName, altName))
        else
            b:SetAttribute("type1", "spell")
            b:SetAttribute("spell1", mainName)
        end
        if altName then
            b:SetAttribute("type2", "spell")
            b:SetAttribute("spell2", altName)
        end
    elseif p.kind == "es" then
        b:SetAttribute("type1", "macro")
        b:SetAttribute("macrotext1", strformat("/cast [@%s] %s", p.target, Tm:ESName()))
    elseif p.imbue then
        local name = (GetSpellInfo and GetSpellInfo(p.imbue.id)) or p.imbue.short
        b:SetAttribute("type1", "macro")
        b:SetAttribute("macrotext1", strformat("/cast %s\n/use %d", name, p.hand == "mh" and 16 or 17))
    end
end

local function PlaceRail(list)
    frame.hero:ClearAllPoints()
    frame.hero:SetPoint("TOP", frame, "TOP", frame.tide:IsShown() and -8 or 0, -8)
    frame.tide:ClearAllPoints()
    frame.tide:SetPoint("LEFT", frame.hero, "RIGHT", 3, 0)
    frame.plan:ClearAllPoints()
    frame.plan:SetPoint("TOP", frame, "TOP", 0, -32)
    frame.plan:Show()
    frame.div1:ClearAllPoints()
    frame.div1:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -(R_HEAD - 5))
    frame.div1:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -(R_HEAD - 5))
    frame.div1:SetHeight(1)
    frame.div1:Show()
    for i, p in ipairs(list) do
        local row = rows[p.kind]
        row:ClearAllPoints()
        row:SetSize(R_S, R_S)
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", R_PAD, -(R_HEAD + (i - 1) * (R_S + R_GAP)))
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
        f.miss:ClearAllPoints()
        f.miss:SetPoint("CENTER", f, "TOPLEFT", 1, -1)
        f.count:ClearAllPoints()
        f.count:SetPoint("CENTER", f, "BOTTOMRIGHT", 0, 1)
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
    frame:SetSize(n * (S_T + S_GAP) - S_GAP + S_PAD + S_SIDE + 8, S_T + 18)
    frame.hero:ClearAllPoints()
    frame.hero:SetPoint("LEFT", frame, "LEFT", 13, 1)
    frame.tide:ClearAllPoints()
    frame.tide:SetPoint("TOPLEFT", frame.hero, "BOTTOMRIGHT", -6, 6)
    frame.plan:Hide()
    frame.div1:ClearAllPoints()
    frame.div1:SetPoint("LEFT", frame, "LEFT", S_SIDE, 0)
    frame.div1:SetSize(1, S_T - 4)
    frame.div1:Show()
    for i, p in ipairs(list) do
        local row = rows[p.kind]
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
        f.corner:SetSize(14, 14)
        f.corner:SetPoint("TOPRIGHT", f, "TOPRIGHT", 4, 4)
        f.cornerBox:ClearAllPoints()
        f.cornerBox:SetPoint("TOPLEFT", f.corner, "TOPLEFT", -1, 1)
        f.cornerBox:SetPoint("BOTTOMRIGHT", f.corner, "BOTTOMRIGHT", 1, -1)
        Edge(f.cornerBox, GLASS[1], GLASS[2], GLASS[3], 1)
        f.line:ClearAllPoints()
        f.line:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 2, -4)
        f.line:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", -2, -4)
        f.line:SetHeight(2)
        f.lineFill:ClearAllPoints()
        f.lineFill:SetPoint("TOPLEFT", f.line, "TOPLEFT")
        f.lineFill:SetHeight(2)
        f.miss:ClearAllPoints()
        f.miss:SetPoint("CENTER", f, "TOPLEFT", 0, 0)
        f.count:ClearAllPoints()
        f.count:SetPoint("CENTER", f, "BOTTOMRIGHT", 0, 1)
        f.track:Hide()
        f.cd:Hide()
        f.cls:Hide()
        f.tile:Show()
        f.tileEdge:Show()
        f.line:Show()
        f.lineFill:Show()
    end
end

-- No panel: icons and text float on the world. While unlocked a faint panel shows what to drag.
local function ApplyChrome()
    local unlocked = not T().Setting("locked", true)
    frame.bg:SetShown(unlocked)
    frame.shadow:SetShown(unlocked)
    for _, e in ipairs(frame.edges or {}) do e:SetShown(unlocked) end
    frame:EnableMouse(unlocked)
end

function Bar:Update()
    if not frame then
        if not self:Wanted() then return end
        Build()
    end
    local combat = InCombatLockdown()
    if not self:Wanted() then
        if combat then return end
        frame:Hide()
        if pop then pop:Hide() end
        return
    end
    if combat then
        self:UpdateLooks()
        return
    end
    local Tm = T()
    frame:SetScale(tonumber(Tm.Setting("scale", 1)) or 1)
    if frame.layout ~= Layout() then
        frame.layout = Layout()
        RestorePos()
    end
    local list = self:Plan()
    local used = {}
    for _, p in ipairs(list) do
        local r = rows[p.kind]
        r.data = p
        used[p.kind] = true
        SetAttributes(r, p)
        r:Show()
    end
    for kind, r in pairs(rows) do
        if not used[kind] then
            r:Hide()
            r.data = nil
        end
    end
    -- header: Heroism, Mana Tide
    local heroId, heroIcon = Tm:HeroSpell()
    frame.hero.spellId = heroId
    frame.hero:SetAttribute("spell", (not Tm:IsDemo()) and Tm:HeroName() or nil)
    SetRoundIcon(frame.hero.icon, heroIcon)
    frame.tide:SetShown(list.tide)
    frame.tide:SetAttribute("spell", (list.tide and not Tm:IsDemo()) and Tm:TotemName(3, 3) or nil)
    SetRoundIcon(frame.tide.icon, Tm:TotemIcon(3, 3))
    if Layout() == "horizontal" then PlaceStrip(list) else PlaceRail(list) end
    frame.list = list
    ApplyChrome()
    frame:Show()
    self:UpdateLooks()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Looks (safe in combat)
-- ---------------------------------------------------------------------------------------------------------------
local function SetSwipe(cd, start, total)
    if start and total and total > 0 then
        local s = floor(start * 2 + 0.5) / 2
        if cd.cdStart ~= s or cd.cdDur ~= total then
            cd.cdStart, cd.cdDur = s, total
            cd:SetCooldown(s, total)
        end
    elseif cd.cdStart then
        cd.cdStart, cd.cdDur = nil, nil
        if cd.Clear then cd:Clear() else cd:SetCooldown(0, 0) end
    end
end

-- What a row shows: icon, corner icon, fraction left (0..1), start + total for the swipe, element colour.
local function RowState(p)
    local Tm = T()
    local now = GetTime()
    local st = { color = { 0.91, 0.89, 0.82 } }
    if p.el then
        st.color = Tm.D.ELEMENTS[p.el].color
        st.icon = Tm:TotemIcon(p.el, p.main)
        st.corner = p.alt and Tm:TotemIcon(p.el, p.alt)
        local name, start, dur = Tm:MyTotem(p.el)
        st.down = name ~= nil
        if p.why == "twist" then
            local left = Tm:WindfuryLeft()
            if left then
                st.frac, st.start, st.total = left / Tm.D.TWIST_WINDOW, now - (Tm.D.TWIST_WINDOW - left), Tm.D.TWIST_WINDOW
                st.down = true
            end
        elseif start then
            local left = max(0, start + dur - now)
            st.frac, st.start, st.total = left / dur, start, dur
        end
    elseif p.kind == "es" then
        st.icon = Tm.D.EARTH_SHIELD_ICON
        st.color = Tm.D.ELEMENTS[1].color
        local n = Tm:ESCharges(p.target)
        st.count = n
        st.down = n > 0
        if n > 0 then st.frac = n / Tm.D.EARTH_SHIELD_CHARGES end
    elseif p.imbue then
        st.icon = p.imbue.icon
        local left = ImbueLeft(p.hand)
        st.down = left ~= nil
        if left then st.frac, st.start, st.total = min(1, left / 1800), now - (1800 - left), 1800 end
    end
    return st
end

function Bar:UpdateLooks()
    if not frame or not frame:IsShown() or not frame.list then return end
    local Tm = T()
    local layout = Layout()
    local list = frame.list
    local urgent = self:Urgent(list)
    local now = GetTime()
    -- header: Heroism (gold ring = ready; on cooldown the swipe runs and the ring greys), Mana Tide the same
    local start, dur = SpellCooldown(frame.hero.spellId or 0)
    if Tm:IsDemo() then start, dur = nil, nil end
    SetSwipe(frame.hero.cd, start, dur)
    frame.hero.icon:SetDesaturated(start ~= nil)
    if start then frame.hero.ring:SetVertexColor(0.6, 0.6, 0.62, 0.5)
    else frame.hero.ring:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1) end
    local hk = Tm:GetHero(Tm:Me())
    for _, x in ipairs(Tm.D.HERO_WHEN) do if x.key == hk then frame.plan:SetText(x.text) end end
    if frame.tide:IsShown() then
        local ts, td = SpellCooldown(Tm:Totem(3, 3).id)
        if Tm:IsDemo() then
            local ds = Tm:DemoState()
            if ds and ds.manaTide then ts, td = ds.manaTide() end
        end
        local ready = not (ts and ts + td > now)
        SetSwipe(frame.tide.cd, (not ready) and ts or nil, td)
        frame.tide.icon:SetDesaturated(not ready)
        if ready then frame.tide.ring:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
        else frame.tide.ring:SetVertexColor(0.6, 0.6, 0.62, 0.5) end
    end
    local roster
    local M = Motion()
    for _, p in ipairs(list) do
        local row = rows[p.kind]
        local f = row.face
        local st = RowState(p)
        local isNext = urgent and urgent.kind == p.kind
        local reach = st.down and 1 or 0.55
        f.classRGB = { st.color[1], st.color[2], st.color[3] }
        f.glow:Show()
        f.corner:SetShown(st.corner ~= nil)
        f.cornerBox:SetShown(st.corner ~= nil)
        if st.corner then f.corner:SetTexture(st.corner) end
        f.count:SetCount(st.count or 0)
        -- the party out of range of my totem
        if p.el and st.down and Tm:InGroup() and Tm.Setting("range", true) then
            roster = roster or Tm:Roster()
            row.state = Tm:PartyState(Tm:Me(), p.el, p.main, roster)
            f.miss:SetCount(#row.state.missing)
        else
            row.state = nil
            f.miss:SetCount(0)
        end
        if layout == "horizontal" then
            SetSquareIcon(f.tile, st.icon)
            f.tile:SetAlpha(reach)
            f.tile:SetDesaturated(not st.down)
            if isNext then
                f.label.text:SetText(urgent.short)
                f.label.text:SetTextColor(0.1, 0.08, 0.01)
                f.label.bg:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
                Edge(f.label, GOLD[1], GOLD[2], GOLD[3], 1)
            end
        else
            SetRoundIcon(f.cls, st.icon)
            f.cls:SetAlpha(reach)
            f.cls:SetDesaturated(not st.down)
            SetSwipe(f.cd, st.start, st.total)
            if isNext then
                f.label.text:SetText(urgent.text)
                f.label.text:SetTextColor(1, 0.9, 0.55)
                f.label.bg:SetVertexColor(GLASS[1], GLASS[2], GLASS[3], 0.92)
                Edge(f.label, GOLD[1], GOLD[2], GOLD[3], 0.55)
            end
        end
        if isNext then f.label:SetWidth((f.label.text:GetStringWidth() or 40) + 16) end
        -- motion (the Blessings bar's): ease toward the new look; bloom when the urgent thing is done
        local done = f.wasHot and not isNext
        if M and M.Aim then
            M.Aim(f, { hot = isNext and 1 or 0, lift = (isNext and layout == "horizontal") and 7 or 0,
                line = st.frac or 0, hover = f.hoverOn and 1 or 0 }, done and f.motion ~= nil)
        else
            f.label:SetShown(isNext and true or false)
            f.glow:SetAlpha(isNext and 0.55 or 0)
        end
        f.wasHot = isNext and true or false
    end
    if pop and pop:IsShown() and pop.button then self:FillPop(pop.button) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Hover: the face eases into its hover look; a totem with someone out of range lists the party
-- ---------------------------------------------------------------------------------------------------------------
function Bar:FillPop(b)
    local Tm = T()
    local p = b.data
    if not p or not p.el then return end
    local roster = Tm:Roster()
    local sub = Tm:SubgroupOf(Tm:Me(), roster)
    pop.title:SetText(strformat("%s · GROUP %s", (Tm:TotemShort(p.el, p.main) or ""):upper(), sub or "?"))
    local list = {}
    local st = b.state
    for _, m in ipairs(roster) do
        if m.subgroup == sub and m.name ~= Tm:Me() then list[#list + 1] = m end
    end
    for i, m in ipairs(list) do
        local r = pop.rows[i]
        if not r then
            r = CreateFrame("Frame", nil, pop)
            r:SetSize(POP_W - 16, POP_ROW)
            r:SetPoint("TOPLEFT", pop, "TOPLEFT", 8, -(24 + (i - 1) * POP_ROW))
            r.cls = r:CreateTexture(nil, "ARTWORK")
            r.cls:SetSize(15, 15)
            r.cls:SetPoint("LEFT", r, "LEFT", 4, 0)
            r.name = Text(r, 11)
            r.name:SetPoint("LEFT", r, "LEFT", 26, 0)
            r.state = Text(r, 10, { 0.6, 0.6, 0.64 })
            r.state:SetPoint("RIGHT", r, "RIGHT", -4, 0)
            r.state:SetJustifyH("RIGHT")
            pop.rows[i] = r
        end
        local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[m.class]
        r.cls:SetTexture(CIRCLES)
        if c then r.cls:SetTexCoord(c[1], c[2], c[3], c[4]) end
        local cr, cg, cb = UI():ClassColor(m.class)
        r.name:SetText(m.name)
        r.name:SetTextColor(cr, cg, cb)
        local out = false
        for _, x in ipairs((st and st.missing) or {}) do if x.name == m.name then out = true end end
        r.state:SetText((m.dead and "dead") or (not m.online and "offline") or (out and "out of range") or "in range")
        if out then r.state:SetTextColor(1, 0.54, 0.47) else r.state:SetTextColor(0.5, 0.5, 0.53) end
        r.cls:SetAlpha(out and 0.5 or 1)
        r.name:SetAlpha(out and 0.65 or 1)
        r:Show()
    end
    for i = #list + 1, #pop.rows do pop.rows[i]:Hide() end
    pop.hint:ClearAllPoints()
    pop.hint:SetPoint("TOPLEFT", pop, "TOPLEFT", 12, -(26 + #list * POP_ROW + 2))
    pop.hint:SetText(p.alt and ("right-click: " .. (Tm:TotemShort(p.el, p.alt) or "")) or "")
    pop:SetHeight(26 + #list * POP_ROW + (p.alt and 20 or 6))
end

function Bar:Hover(b, on)
    local Tm = T()
    local f = b.face
    f.hoverOn = on and true or false
    local M = Motion()
    if f.motion and M and M.Aim then
        local t = {}
        for k, v in pairs(f.motion.tgt) do t[k] = v end
        t.hover = on and 1 or 0
        M.Aim(f, t)
    end
    if not on then
        GameTooltip:Hide()
        if pop then pop:Hide() end
        return
    end
    local p = b.data
    if not p then return end
    -- someone out of range: the party next to it (left of the rail, above the strip)
    if p.el and b.state and #b.state.missing > 0 then
        pop.button = b
        self:FillPop(b)
        pop:ClearAllPoints()
        if Layout() == "horizontal" then pop:SetPoint("BOTTOM", b, "TOP", 0, 34)
        else pop:SetPoint("RIGHT", b, "LEFT", -14, 0) end
        pop:Show()
        return
    end
    GameTooltip:SetOwner(b, Layout() == "horizontal" and "ANCHOR_TOP" or "ANCHOR_LEFT")
    if p.el then
        GameTooltip:AddLine(Tm:TotemName(p.el, p.main) or "")
        if p.why == "twist" then
            GameTooltip:AddLine("Click: Windfury and " .. Tm:TotemShort(p.el, p.alt) .. " in turn", 0.85, 0.85, 0.85)
            GameTooltip:AddLine("The ring is Windfury on the party's weapons (10 s).", 0.6, 0.6, 0.6)
        end
        if p.alt then GameTooltip:AddLine("Right-click: " .. (Tm:TotemName(p.el, p.alt) or ""), 0.85, 0.85, 0.85) end
    elseif p.kind == "es" then
        GameTooltip:AddLine(strformat("%s on %s", Tm:ESName(), p.target))
        GameTooltip:AddLine(strformat("%d charges left", Tm:ESCharges(p.target)), 0.85, 0.85, 0.85)
    elseif p.imbue then
        GameTooltip:AddLine(p.imbue.short .. (p.hand == "mh" and " (main hand)" or " (off hand)"))
        local left = ImbueLeft(p.hand)
        GameTooltip:AddLine(left and (Seconds(left) .. " left") or "Missing: click to apply", 0.85, 0.85, 0.85)
    end
    if not Tm.Setting("locked", true) then GameTooltip:AddLine("Drag the bar to move it.", 0.6, 0.6, 0.6) end
    GameTooltip:Show()
end

function Bar:HeaderTip(b, which)
    local Tm = T()
    GameTooltip:SetOwner(b, "ANCHOR_LEFT")
    if which == "hero" then
        GameTooltip:AddLine(Tm:HeroName())
        local h = Tm:GetHero(Tm:Me())
        for _, x in ipairs(Tm.D.HERO_WHEN) do
            if x.key == h then GameTooltip:AddLine("Plan: " .. x.long, 0.85, 0.85, 0.85) end
        end
        GameTooltip:AddLine("The whole raid gets it; one shaman casts it.", 0.6, 0.6, 0.6)
    else
        GameTooltip:AddLine(Tm:TotemName(3, 3) or "Mana Tide")
        GameTooltip:AddLine("Your party's mana, 5 min cooldown", 0.85, 0.85, 0.85)
    end
    GameTooltip:Show()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Lifecycle, settings
-- ---------------------------------------------------------------------------------------------------------------
function Bar:OnLogin()
    ns:On("TOTEMS_CHANGED", function() Bar:Update() end)
    ns:On("TOTEMS_LIVE", function() Bar:UpdateLooks() end)
    ns:On("CLASSKIT_CHANGED", function() Bar:Update() end)
    ns:On("GROUP_UPDATED", function() Bar:Update() end)
    ns:RegisterEvent("PLAYER_TOTEM_UPDATE", function() Bar:UpdateLooks() end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() Bar:Update() end)
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if pop and pop:IsShown() then pop:Hide() end
    end)
    ns:RegisterEvent("PLAYER_TARGET_CHANGED", function()
        if not InCombatLockdown() then ns.Util.Debounce("dz-totembar-target", 0.3, function() Bar:Update() end) end
    end)
    ns:RegisterEvent("UNIT_INVENTORY_CHANGED", function(_, unit)
        if unit == "player" then Bar:UpdateLooks() end
    end)
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and path:find("^totems") and path ~= "totems.pos" then
            if frame and path == "totems.locked" and not InCombatLockdown() then RestorePos() end
            Bar:Update()
        end
    end)
    self:Update()
end

function Bar:GetFrame() return frame end
function Bar:GetPopout() return pop end
function Bar:Button(kind)
    if kind == "hero" or kind == "tide" then return frame and frame[kind] end
    return rows[kind]
end

Bar.LAYOUTS = { { value = "vertical", text = "Rail (vertical)" }, { value = "horizontal", text = "Strip (horizontal)" } }

-- The kit's Settings card (Settings > Class tools; every shaman spec).
if ns.ClassKit then ns.ClassKit:Extend("totems", {
    iconPath = "Interface\\Icons\\Spell_Nature_Windfury",
    action = { label = "Open planner", run = function() if ns.TotemsUI then ns.TotemsUI:Open() end end },
    settings = function(S, sec)
    S:DropdownSetting(sec, "Totem bar", "Your planned totems: click to drop, right-click for the second one.",
        "totems.bar", "group", { { value = "group", text = "Party and raid" }, { value = "raid", text = "Raids only" },
            { value = "always", text = "Always" }, { value = "off", text = "Off" } })
    S:DropdownSetting(sec, "Bar layout", "A rail of totem rings, or a strip of tiles over your action bars.",
        "totems.layout", "vertical", Bar.LAYOUTS)
    local D = ns.ClassData.SHAMAN
    S:DropdownSetting(sec, "Twist Windfury with", "Enhancement: the totem dropped between Windfury drops.",
        "totems.twistWith", 2, { { value = 2, text = D.TOTEMS[4][2].short }, { value = 3, text = D.TOTEMS[4][3].short },
            { value = 4, text = D.TOTEMS[4][4].short } })
    local secs = {}
    for _, n in ipairs({ 2, 3, 4 }) do secs[#secs + 1] = { value = n, text = n .. " seconds left" } end
    S:DropdownSetting(sec, "Twist warning", "When the bar says to drop Windfury again.", "totems.twistWarn", 3, secs)
    S:SwitchSetting(sec, "Who is out of range", "A red count on a totem for party members out of its reach.",
        "totems.range", true)
    local ch = { { value = 0, text = "Never" } }
    for _, n in ipairs({ 1, 2, 3 }) do ch[#ch + 1] = { value = n, text = "At " .. n .. (n == 1 and " charge" or " charges") } end
    S:DropdownSetting(sec, "Earth Shield reminder", "Restoration: warn when it runs low on the tank.", "totems.esWarn", 2, ch)
    S:SwitchSetting(sec, "Weapon imbue reminder", "Adds your weapon imbues to the bar; it says when one is missing.",
        "totems.imbue", false)
    local imbues = { { value = "auto", text = "By spec" } }
    for _, i in ipairs(D.IMBUES) do imbues[#imbues + 1] = { value = i.key, text = i.short } end
    S:DropdownSetting(sec, "Main hand imbue", "", "totems.imbueMH", "auto", imbues)
    local oh = { { value = "auto", text = "By spec" }, { value = "none", text = "None" } }
    for _, i in ipairs(D.IMBUES) do oh[#oh + 1] = { value = i.key, text = i.short } end
    S:DropdownSetting(sec, "Off hand imbue", "", "totems.imbueOH", "auto", oh)
    S:SwitchSetting(sec, "Anyone may assign me", "Not only the leader and assistants.", "totems.free", false)
    S:SwitchSetting(sec, "Locked", "Unlock to drag the bar where you want it.", "totems.locked", true)
    local scales = {}
    for _, n in ipairs({ 0.8, 0.9, 1, 1.15, 1.3 }) do scales[#scales + 1] = { value = n, text = floor(n * 100) .. "%" } end
    S:DropdownSetting(sec, "Size", "", "totems.scale", 1, scales)
    S:EndSection(sec)
end }) end

if DisasterZoneBoot and DisasterZoneBoot.Run("UI/TotemBar.lua", ...) then return end -- DisasterZone: totem bar.
-- The shaman's totem bar for the Totem planner (Core/Totems.lua), shown in a party or raid when I have totems
-- planned. It is the Blessings bar's sibling (UI/BlessingsBar.lua): the same faces, themes, motion and two layouts
-- (setting totems.layout, also in the planner's More menu): "vertical" (Rail, a column) and "horizontal" (Strip, a
-- row) - the same cells in both, only the axis turns (UI/BarFace.lua, setting classbar.theme). First the planner (a
-- click opens it; it never casts), Heroism (gold = ready, a dark swipe while it cools down) and Mana Tide, a divider,
-- then my totems: the icon, the time left draining
-- (ring, swipe or bar by theme: calm, red when short), the second totem (twist partner or a boss's next phase) in the
-- corner, a red count of party members out of its range; Earth Shield with its charges, the weapon imbues. The one
-- thing to do lifts out of the line (up in the strip, left in the rail) in gold with a chip ("drop now").
-- The twisting shaman's Air ring is Windfury on the party's weapons (10 s after a drop), not the totem. One thing at a
-- time is named: twist due, Earth Shield low or missing, a totem about to end in combat, a missing imbue.
-- No panel behind it (only a faint one while unlocked, to drag it by).
-- Clicks: a totem casts the planned one (twisting: Windfury and its partner in turn); right-click casts the second.
-- Every cast is a secure button set out of combat (WoW forbids changing them in a fight): in combat the bar keeps
-- its spells, and catches up when the fight ends. Hover a totem with someone out of range for who.
local addonName, ns = ...

local Bar = ns:NewModule("TotemBar")

local floor, max, min = math.floor, math.max, math.min
local strformat = string.format

local SOFT = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
local WHITE8 = "Interface\\Buttons\\WHITE8X8"
local CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
local GLASS = { 0.047, 0.047, 0.059, 0.78 }

local POP_W, POP_ROW = 186, 21
local KINDS = { "el1", "el2", "el3", "el4", "es", "mh", "oh" }

local function T() return ns.Totems end
local function UI() return ns.UI end
local function Face() return ns.BarFace end

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
        frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 240)
    else
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -420, 40)
    end
end

-- One totem (or Earth Shield, an imbue): a secure button; its looks sit on a face (UI/BarFace.lua).
local function NewRow(kind)
    local r = Secure(frame, "DisasterZoneTotem_" .. kind)
    r:SetSize(34, 34)
    r.kind = kind
    r.face = Face():New(r)
    r:HookScript("OnEnter", function(self) Bar:Hover(self, true) end)
    r:HookScript("OnLeave", function(self) Bar:Hover(self, false) end)
    rows[kind] = r
    return r
end

-- A header cell (Heroism, Mana Tide): secure, the same face as the totems.
local function HeaderIcon(name)
    local b = Secure(frame, name)
    b:SetSize(34, 34)
    b.face = Face():New(b)
    b:HookScript("OnEnter", function(self) Face():Hover(self.face, true) end)
    b:HookScript("OnLeave", function(self) Face():Hover(self.face, false) end)
    b:SetAttribute("type", "spell")
    return b
end

local function Build()
    frame = CreateFrame("Frame", "DisasterZoneTotemBar", UIParent)
    frame:SetSize(50, 100)
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

    -- the planner (the bar's first cell)
    frame.plan = Face():PlannerCell(frame, "Totem planner", function()
        if ns.TotemsUI then ns.TotemsUI:Toggle() end
    end)
    local hero = HeaderIcon("DisasterZoneTotem_hero")
    hero:HookScript("OnEnter", function(self) Bar:HeaderTip(self, "hero") end)
    hero:HookScript("OnLeave", function() GameTooltip:Hide() end)
    frame.hero = hero
    local tide = HeaderIcon("DisasterZoneTotem_tide")
    tide:HookScript("OnEnter", function(self) Bar:HeaderTip(self, "tide") end)
    tide:HookScript("OnLeave", function() GameTooltip:Hide() end)
    frame.tide = tide
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

-- The cells in order: the planner, the header that is shown (Heroism, Mana Tide), then the totems.
local function Place(list, axis, theme)
    local cells = {}
    for _, b in ipairs({ frame.plan, frame.hero, frame.tide }) do
        if b:IsShown() then cells[#cells + 1] = b end
    end
    local nHead = #cells
    for _, p in ipairs(list) do cells[#cells + 1] = rows[p.kind] end
    Face():Place(frame, cells, nHead, axis, theme)
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
    frame.hero.iconPath = heroIcon
    frame.tide:SetShown(list.tide)
    frame.tide:SetAttribute("spell", (list.tide and not Tm:IsDemo()) and Tm:TotemName(3, 3) or nil)
    frame.tide.iconPath = Tm:TotemIcon(3, 3)
    -- (placed again only when the layout, the theme or the cells change: re-anchoring a cooldown ring redraws it)
    local theme = Face():Theme()
    local axis = Layout() == "horizontal" and "h" or "v"
    local kinds = {}
    for _, p in ipairs(list) do kinds[#kinds + 1] = p.kind end
    local sig = strformat("%s:%s:%s:%s", axis, theme.key, list.tide and "t" or "", table.concat(kinds, ","))
    if frame.placed ~= sig then
        frame.placed = sig
        Place(list, axis, theme)
    end
    frame.list = list
    ApplyChrome()
    frame:Show()
    self:UpdateLooks()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Looks (safe in combat)
-- ---------------------------------------------------------------------------------------------------------------
-- What a row shows: icon, corner icon, fraction left (0..1), start + total for the swipe, short (runs out soon).
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
            st.short = left < 10
        end
    elseif p.kind == "es" then
        st.icon = Tm.D.EARTH_SHIELD_ICON
        st.color = Tm.D.ELEMENTS[1].color
        local n = Tm:ESCharges(p.target)
        st.count = n
        st.down = n > 0
        if n > 0 then st.frac = n / Tm.D.EARTH_SHIELD_CHARGES end
        st.short = n > 0 and n <= (tonumber(Tm.Setting("esWarn", 2)) or 2)
    elseif p.imbue then
        st.icon = p.imbue.icon
        local left = ImbueLeft(p.hand)
        st.down = left ~= nil
        if left then
            st.frac, st.start, st.total = min(1, left / 1800), now - (1800 - left), 1800
            st.short = left < 300
        end
    end
    return st
end

function Bar:UpdateLooks()
    if not frame or not frame:IsShown() or not frame.list then return end
    local Tm = T()
    local F = Face()
    local list = frame.list
    local urgent = self:Urgent(list)
    local now = GetTime()
    -- header: Heroism (gold = ready; on cooldown it greys and a dark swipe runs over it), Mana Tide the same
    local start, dur = SpellCooldown(frame.hero.spellId or 0)
    if Tm:IsDemo() then start, dur = nil, nil end
    F:ShowPlanner(frame.plan)
    F:Set(frame.hero.face, { icon = frame.hero.iconPath, desat = start ~= nil, tone = start and "dim" or "on",
        cdStart = start, cdDur = dur })
    F.Aim(frame.hero.face, F:Targets(frame.hero.face, false))
    if frame.tide:IsShown() then
        local ts, td = SpellCooldown(Tm:Totem(3, 3).id)
        if Tm:IsDemo() then
            local ds = Tm:DemoState()
            if ds and ds.manaTide then ts, td = ds.manaTide() end
        end
        local ready = not (ts and ts + td > now)
        F:Set(frame.tide.face, { icon = frame.tide.iconPath, desat = not ready, tone = ready and "on" or "dim",
            cdStart = (not ready) and ts or nil, cdDur = td })
        F.Aim(frame.tide.face, F:Targets(frame.tide.face, false))
    end
    local roster
    for _, p in ipairs(list) do
        local row = rows[p.kind]
        local f = row.face
        local st = RowState(p)
        local isNext = urgent and urgent.kind == p.kind
        -- the party out of range of my totem
        local missing = 0
        if p.el and st.down and Tm:InGroup() and Tm.Setting("range", true) then
            roster = roster or Tm:Roster()
            row.state = Tm:PartyState(Tm:Me(), p.el, p.main, roster)
            missing = #row.state.missing
        else
            row.state = nil
        end
        local look = { icon = st.icon, cornerIcon = st.corner, missing = missing, alpha = st.down and 1 or 0.55,
            desat = not st.down, start = st.start, total = st.total, frac = (not st.start) and (st.frac or 0) or nil,
            num = (st.count and st.count > 0) and tostring(st.count) or nil, short = st.short,
            chip = isNext and urgent.short or nil }
        F:Set(f, look)
        -- motion: ease toward the new look; bloom when the urgent thing is done
        local done = f.wasHot and not isNext
        F.Aim(f, F:Targets(f, isNext), done and f.motion ~= nil)
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
    Face():Hover(b.face, on)
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
        if type(path) == "string" and (path:find("^totems") or path == "classbar.theme") and path ~= "totems.pos" then
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
    S:DropdownSetting(sec, "Bar layout", "A column at the side or a row over your action bars: the same cells.",
        "totems.layout", "vertical", Bar.LAYOUTS)
    if ns.BarFace then ns.BarFace:SettingsRow(S, sec) end
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

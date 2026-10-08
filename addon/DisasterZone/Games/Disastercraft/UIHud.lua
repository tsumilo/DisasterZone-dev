if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/UIHud.lua", ...) then return end -- DisasterZone Games/Disastercraft/UIHud.lua
-- CraftUI's heads-up display, laid out like WoW 2.x: the player frame (your own portrait) and the target frame
-- (the creature's 3D portrait, its level in difficulty colour, the elite dragon), buffs at the top right, the main
-- menu bar with its gryphons (twelve action buttons on 1-0 - =, a second row on Shift), the experience bar, the micro
-- menu and the bag buttons, the cast bar, the chat box, the red error line and the yellow notices, the zone text,
-- the quest tracker, the death popups.
local addonName, ns = ...

local UI = ns.CraftUI
local K = UI.Kit
local Craft = ns.Craft
local D = Craft.D
local Combat = Craft.Combat

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local Now = Craft.Now
local H = {}
UI.Hud = H

---------------------------------------------------------------------------
-- Unit frames
---------------------------------------------------------------------------

local function Portrait(t, u)
    if not u then t:SetTexture(nil) return end
    if t.unitKey == u.guid then return end
    t.unitKey = u.guid
    if u.kind == "player" then
        K.HeroPortrait(t, (u.char and u.char.sex) or u.sex or (Craft.char and Craft.char.sex) or 0)
        return
    end
    if Combat.IsPlayer(u) then
        t:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[Craft.CLASS_TOKENS[u.class] or "WARRIOR"]
        if c then t:SetTexCoord(c[1], c[2], c[3], c[4]) end
        return
    end
    local disp = u.cr and u.cr.disp
    t:SetTexCoord(0, 1, 0, 1)
    if disp and SetPortraitTextureFromCreatureDisplayID then
        local ok = pcall(SetPortraitTextureFromCreatureDisplayID, t, disp)
        if ok then return end
    end
    t:SetTexture("Interface\\CharacterFrame\\TempPortrait")
end
H.Portrait = Portrait

local function PowerColor(u)
    if u.powerType == Craft.POWER_RAGE then return 1, 0, 0 end
    if u.powerType == Craft.POWER_ENERGY then return 1, 1, 0 end
    return 0, 0, 1
end

local function BarText(bar, cur, maxv, rage)
    if rage then bar.text:SetText(floor(cur / 10) .. " / " .. floor(maxv / 10))
    else bar.text:SetText(floor(cur) .. " / " .. floor(maxv)) end
end

-- a 232 x 100 frame on WoW's targeting art (flipped for the player)
local function UnitFrame(parent, flip)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(232, 100)
    f.bg = K.Tex(f, "BACKGROUND")
    f.bg:SetColorTexture(0, 0, 0, 0.55)
    f.bg:SetSize(119, 41)
    f.portrait = K.Tex(f, "BACKGROUND", nil, 1)
    f.portrait:SetSize(64, 64)
    f.art = K.Tex(f, "BORDER", "Interface\\TargetingFrame\\UI-TargetingFrame")
    f.art:SetSize(232, 100)
    f.art:SetPoint("TOPLEFT")
    f.hp = K.Bar(f, 119, 12, 0, 1, 0)
    f.hp.bg:Hide()
    f.mp = K.Bar(f, 119, 12, 0, 0, 1)
    f.mp.bg:Hide()
    f.name = K.Text(f, "GameFontNormalSmall", "OVERLAY", "CENTER")
    f.name:SetWidth(110)
    f.level = K.Text(f, "GameNormalNumberFont", "OVERLAY", "CENTER")
    f.nameBg = K.Tex(f, "BACKGROUND", K.WHITE, 2)
    f.nameBg:SetSize(119, 19)
    if flip then
        f.art:SetTexCoord(1, 0.09375, 0, 0.78125)
        f.portrait:SetPoint("TOPLEFT", 42, -12)
        f.bg:SetPoint("TOPLEFT", 106, -22)
        f.hp:SetPoint("TOPLEFT", 106, -41)
        f.mp:SetPoint("TOPLEFT", 106, -52)
        f.name:SetPoint("CENTER", f, "CENTER", 50, 19)
        f.level:SetPoint("CENTER", f, "CENTER", -63, -16)
        f.nameBg:Hide()
    else
        f.art:SetTexCoord(0.09375, 1, 0, 0.78125)
        f.portrait:SetPoint("TOPRIGHT", -42, -12)
        f.bg:SetPoint("TOPLEFT", 6, -22)
        f.hp:SetPoint("TOPLEFT", 6, -41)
        f.mp:SetPoint("TOPLEFT", 6, -52)
        f.name:SetPoint("CENTER", f, "CENTER", -50, 19)
        f.level:SetPoint("CENTER", f, "CENTER", 63, -16)
        f.nameBg:SetPoint("TOPLEFT", 6, -22)
    end
    f.combat = K.Tex(f, "OVERLAY", "Interface\\CharacterFrame\\UI-StateIcon")
    f.combat:SetSize(32, 31)
    f.combat:SetTexCoord(0.5, 1, 0, 0.484375)
    f.combat:SetPoint("CENTER", f.level, "CENTER", 0, 0)
    f.combat:Hide()
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    return f
end

local function UpdateUnitFrame(f, u)
    if not u then f:Hide() return end
    f:Show()
    Portrait(f.portrait, u)
    if u.dead then f.portrait:SetVertexColor(0.5, 0.5, 0.5) else f.portrait:SetVertexColor(1, 1, 1) end
    f.name:SetText(u.name or "")
    local lvl = u.level or 1
    local p = Craft.player
    if f ~= H.player then
        local r, g, b = Craft.Quests.Color(lvl, p.level)
        f.level:SetTextColor(r, g, b)
        f.level:SetText((u.elite and (lvl .. "+")) or lvl)
        local react = Combat.Reaction(p, u)
        local c = (react == "hostile" and { 1, 0, 0 }) or (react == "friendly" and { 0, 1, 0 }) or { 1, 1, 0 }
        if Combat.IsPlayer(u) then c = { 0, 0, 1 } end
        if u.tapper and u.kind == "mob" and not Craft.Loot.Mine(u) then c = { 0.5, 0.5, 0.5 } end
        f.nameBg:SetVertexColor(c[1], c[2], c[3], 0.75)
        f.art:SetTexture(u.elite and "Interface\\TargetingFrame\\UI-TargetingFrame-Elite" or "Interface\\TargetingFrame\\UI-TargetingFrame")
    else
        f.level:SetText(lvl)
        f.level:SetTextColor(1, 0.82, 0)
        f.combat:SetShown(u.inCombat and true or false)
        f.level:SetShown(not u.inCombat)
    end
    f.hp:SetMinMaxValues(0, max(1, u.hpMax or 1))
    f.hp:SetValue(u.dead and 0 or (u.hp or 0))
    if f == H.player or Combat.IsPlayer(u) then BarText(f.hp, u.dead and 0 or u.hp, u.hpMax)
    else f.hp.text:SetText(floor((u.hp or 0) / max(1, u.hpMax) * 100 + 0.5) .. "%") end
    local pm = u.powerMax or 0
    if pm > 0 then
        f.mp:Show()
        f.mp:SetStatusBarColor(PowerColor(u))
        f.mp:SetMinMaxValues(0, pm)
        f.mp:SetValue(u.power or 0)
        BarText(f.mp, u.power or 0, pm, u.powerType == Craft.POWER_RAGE)
        f.mp.text:SetShown(f == H.player or Combat.IsPlayer(u))
    else
        f.mp:Hide()
    end
    -- the health colour: green, getting yellow then red as it drops (like WoW's)
    local pct = (u.hp or 0) / max(1, u.hpMax or 1)
    if pct > 0.5 then f.hp:SetStatusBarColor((1 - pct) * 2, 1, 0) else f.hp:SetStatusBarColor(1, pct * 2, 0) end
    if u.ghost then f.hp.text:SetText("Ghost") end
end

---------------------------------------------------------------------------
-- Aura buttons
---------------------------------------------------------------------------

local function AuraButton(parent, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.icon = K.Tex(b, "ARTWORK")
    b.icon:SetAllPoints()
    b.border = K.Tex(b, "OVERLAY", "Interface\\Buttons\\UI-Debuff-Overlays")
    b.border:SetPoint("TOPLEFT", -1, 1)
    b.border:SetPoint("BOTTOMRIGHT", 1, -1)
    b.border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
    b.dur = K.Text(b, "GameFontNormalSmall", "OVERLAY", "CENTER")
    b.dur:SetPoint("TOP", b, "BOTTOM", 0, -1)
    b.count = K.Text(b, "NumberFontNormalSmall", "OVERLAY", "RIGHT")
    b.count:SetPoint("BOTTOMRIGHT", 0, 0)
    b:RegisterForClicks("RightButtonUp")
    b:SetScript("OnEnter", function(self)
        if not self.aura then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        local sp = D.spells[self.aura.spell]
        GameTooltip:SetText(sp and sp.n or "?", 1, 0.82, 0)
        local text = Craft.Combat.SpellText(self.aura.spell, Combat.units[self.aura.caster or ""] or Craft.player, true)
        if text ~= "" then GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", K.HideTooltip)
    b:SetScript("OnClick", function(self)
        if self.aura and self.unit == Craft.player then Combat.CancelAura(Craft.player, self.aura) end
    end)
    return b
end

local function DurText(s)
    if s >= 3600 then return floor(s / 3600 + 0.5) .. " h" end
    if s >= 60 then return floor(s / 60 + 0.5) .. " m" end
    return floor(s + 0.5) .. " s"
end

local function UpdateAuras(list, u, helpfulFirst, onlyMine)
    local i = 0
    local now = Now()
    if u then
        for pass = 1, 2 do
            for _, a in ipairs(u.auras) do
                local want = (pass == 1) == (a.helpful and true or false)
                if not helpfulFirst then want = (pass == 1) == (not a.helpful) end
                local sp = D.spells[a.spell]
                if want and sp and sp.icon and not (sp.n == "Battle Stance") and i < #list then
                    i = i + 1
                    local b = list[i]
                    b.aura, b.unit = a, u
                    b.icon:SetTexture(sp.icon)
                    b.border:SetShown(not a.helpful)
                    if a.expires then b.dur:SetText(DurText(a.expires - now)) else b.dur:SetText("") end
                    b:Show()
                end
            end
        end
    end
    for j = i + 1, #list do list[j]:Hide() list[j].aura = nil end
end

---------------------------------------------------------------------------
-- Action buttons
---------------------------------------------------------------------------

local KEYS = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=" }
H.KEYS = KEYS

local function ActionButton(parent, slot)
    local b = K.SlotButton(parent, 36, "Interface\\Buttons\\UI-Quickslot2")
    b.bg:SetSize(64, 64)
    b.slot = slot
    b.hotkey = K.Text(b, "NumberFontNormalSmallGray", "OVERLAY", "RIGHT")
    b.hotkey:SetPoint("TOPRIGHT", -2, -2)
    local key = KEYS[(slot - 1) % 12 + 1]
    b.hotkey:SetText(slot > 12 and ("s" .. key) or key)
    b.queued = K.Tex(b, "OVERLAY", "Interface\\Buttons\\CheckButtonHilight")
    b.queued:SetAllPoints()
    b.queued:SetBlendMode("ADD")
    b.queued:Hide()
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnClick", function(self, button)
        if UI.cursorAction then
            local held = UI.cursorAction
            local old = Craft.Npc.PlaceAction(self.slot, held[1], held[2])
            UI.ClearCursorItem()
            if old then UI.PickupAction(old[1], old[2]) end
            return
        end
        if IsShiftKeyDown and IsShiftKeyDown() and button == "LeftButton" then
            local a = Craft.char.bar[self.slot]
            if a then
                Craft.Npc.PlaceAction(self.slot, nil)
                UI.PickupAction(a[1], a[2])
            end
            return
        end
        Craft.Npc.UseAction(self.slot)
        UI.Flash(self)
    end)
    b:SetScript("OnDragStart", function(self)
        local a = Craft.char.bar[self.slot]
        if a then Craft.Npc.PlaceAction(self.slot, nil) UI.PickupAction(a[1], a[2]) end
    end)
    b:SetScript("OnReceiveDrag", function(self)
        if UI.cursorAction then self:GetScript("OnClick")(self, "LeftButton") end
    end)
    b:SetScript("OnEnter", function(self)
        local a = Craft.char and Craft.char.bar[self.slot]
        if not a then return end
        if a[1] == "spell" then K.SpellTooltip(self, a[2]) else K.ItemTooltip(self, a[2], "nosell") end
    end)
    b:SetScript("OnLeave", K.HideTooltip)
    return b
end

function UI.Flash(b)
    b.flashAt = Now()
end

local function UpdateAction(b)
    local c = Craft.char
    local p = Craft.player
    local a = c and c.bar[b.slot]
    if b.slot > 12 then b:SetShown(a ~= nil or UI.cursorAction ~= nil) end
    if not a then
        b.icon:Hide()
        b.count:SetText("")
        b.cd:Hide()
        b.queued:Hide()
        b.hotkey:SetTextColor(0.6, 0.6, 0.6)
        b.border:Hide()
        return
    end
    local id = a[2]
    local usable, nomana, far = true, false, false
    if a[1] == "spell" then
        local sp = D.spells[id]
        b.icon:SetTexture(Combat.SpellIcon(id, c))
        b.count:SetText("")
        local left, total = Combat.CooldownLeft(p, id)
        if left > 0 and total > 0 then
            if b.cdEnd ~= floor((Now() + left) * 10) then
                b.cdEnd = floor((Now() + left) * 10)
                b.cd:SetCooldown(GetTime() - (total - left), total)
                b.cd:Show()
            end
        else
            b.cdEnd = nil
            b.cd:Hide()
        end
        if sp then
            local cost, pt = Combat.Cost(sp, p)
            if cost > 0 and pt ~= -2 and (p.power or 0) < cost then nomana = true end
            local kind = Combat.TargetKind(sp)
            if kind == "enemy" and p.target and not p.target.dead and sp.range and id ~= 6603 then
                local ok = Combat.InRange(p, p.target, sp.range, sp.minRange)
                far = not ok
            end
            if id == 100 and p.inCombat then usable = false end
            if id == 6603 then b.queued:SetShown(p.attacking and true or false)
            elseif Combat.IsNextSwing(sp) then b.queued:SetShown(p.nextSwing == id)
            else b.queued:SetShown(p.casting and p.casting.spell == id or false) end
        end
        if not c.spells[id] then usable = false end
    else
        b.icon:SetTexture(Craft.Items.Icon(id))
        local n = Craft.Items.Count(id)
        b.count:SetText(n > 1 and n or (n == 1 and "" or "0"))
        usable = n > 0
        b.cd:Hide()
        b.queued:Hide()
        local it = D.items[id]
        local spid = it and it.spells and it.spells[1]
        if spid then
            local sp = D.spells[spid[1]]
            local left = 0
            if sp and sp.cat and p.cooldowns["c" .. sp.cat] then left = p.cooldowns["c" .. sp.cat] - Now() end
            if spid[5] and p.cooldowns["c" .. spid[5]] then left = max(left, p.cooldowns["c" .. spid[5]] - Now()) end
            if left > 0 then
                local total = (p.cdTotal and (p.cdTotal["c" .. (spid[5] or 0)] or p.cdTotal["c" .. (sp and sp.cat or 0)])) or left
                if b.cdEnd ~= floor((Now() + left) * 10) then
                    b.cdEnd = floor((Now() + left) * 10)
                    b.cd:SetCooldown(GetTime() - (total - left), total)
                    b.cd:Show()
                end
            end
        end
    end
    b.icon:Show()
    if not usable then b.icon:SetVertexColor(0.4, 0.4, 0.4)
    elseif nomana then b.icon:SetVertexColor(0.5, 0.5, 1)
    elseif far then b.icon:SetVertexColor(0.8, 0.1, 0.1)
    else b.icon:SetVertexColor(1, 1, 1) end
    b.hotkey:SetTextColor(far and 1 or 0.6, far and 0.1 or 0.6, far and 0.1 or 0.6)
    if b.flashAt and Now() - b.flashAt < 0.15 then b:LockHighlight() else b:UnlockHighlight() end
end

---------------------------------------------------------------------------
-- Building the HUD
---------------------------------------------------------------------------

function UI.BuildHud(parent)
    local hud = CreateFrame("Frame", nil, parent)
    hud:SetAllPoints()
    hud:SetFrameLevel(parent:GetFrameLevel() + 20)
    H.frame = hud
    -- player and target frames
    H.player = UnitFrame(hud, true)
    H.player:SetPoint("TOPLEFT", -19, -4)
    H.player:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then Craft.World.SetTarget(Craft.player) end
    end)
    H.target = UnitFrame(hud, false)
    H.target:SetPoint("TOPLEFT", 250, -4)
    H.target:SetScript("OnEnter", function(self) if Craft.player.target then K.UnitTooltip(self, Craft.player.target, "ANCHOR_BOTTOMRIGHT") end end)
    H.target:SetScript("OnLeave", K.HideTooltip)
    H.target:SetScript("OnClick", function(_, button)
        if button == "RightButton" and Craft.player.target then Craft.World.Interact(Craft.player.target) end
    end)
    H.target:Hide()
    H.targetAuras = {}
    for i = 1, 16 do
        local b = AuraButton(H.target, 17)
        b:SetPoint("TOPLEFT", H.target, "BOTTOMLEFT", 5 + ((i - 1) % 8) * 19, 32 - floor((i - 1) / 8) * 30)
        H.targetAuras[i] = b
    end
    -- the target's cast bar
    H.tcast = K.Bar(H.target, 150, 10, 1, 0.7, 0)
    H.tcast:SetPoint("TOPLEFT", H.target, "BOTTOMLEFT", 25, 0)
    H.tcast.border = K.Tex(H.tcast, "OVERLAY", "Interface\\CastingBar\\UI-CastingBar-Border-Small")
    H.tcast.border:SetSize(197, 49)
    H.tcast.border:SetPoint("CENTER", 0, 0)
    H.tcast.text:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 9, "")
    H.tcast:Hide()
    -- your buffs (top right)
    H.buffs = {}
    for i = 1, 16 do
        local b = AuraButton(hud, 30)
        b:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -16 - (i - 1) % 8 * 34, -14 - floor((i - 1) / 8) * 48)
        H.buffs[i] = b
    end
    UI.BuildBar(hud)
    UI.BuildCastBar(hud)
    UI.BuildChat(hud)
    UI.BuildTexts(hud)
    UI.BuildTracker(hud)
    UI.BuildPopups(hud)
    return hud
end

---------------------------------------------------------------------------
-- The main menu bar: art, action buttons, experience, micro menu, bags
---------------------------------------------------------------------------

function UI.BuildBar(hud)
    local bar = CreateFrame("Frame", nil, hud)
    bar:SetSize(1024, 53)
    bar:SetPoint("BOTTOM", 0, 0)
    H.bar = bar
    local coords = { { 0.83203125, 1 }, { 0.58203125, 0.75 }, { 0.33203125, 0.5 }, { 0.08203125, 0.25 } }
    for i = 1, 4 do
        local t = K.Tex(bar, "BACKGROUND", "Interface\\MainMenuBar\\UI-MainMenuBar-Dwarf")
        t:SetSize(256, 43)
        t:SetPoint("BOTTOMLEFT", (i - 1) * 256, 0)
        t:SetTexCoord(0, 1, coords[i][1], coords[i][2])
    end
    local capL = K.Tex(bar, "OVERLAY", "Interface\\MainMenuBar\\UI-MainMenuBar-EndCap-Human")
    capL:SetSize(128, 128)
    capL:SetPoint("BOTTOM", bar, "BOTTOMLEFT", -32, 0)
    local capR = K.Tex(bar, "OVERLAY", "Interface\\MainMenuBar\\UI-MainMenuBar-EndCap-Human")
    capR:SetSize(128, 128)
    capR:SetTexCoord(1, 0, 0, 1)
    capR:SetPoint("BOTTOM", bar, "BOTTOMRIGHT", 32, 0)
    -- the action buttons: the main row, then the second row above it (Shift + the key)
    H.actions = {}
    for i = 1, 12 do
        local b = ActionButton(bar, i)
        b:SetPoint("BOTTOMLEFT", 8 + (i - 1) * 42, 4)
        H.actions[i] = b
    end
    local row2 = CreateFrame("Frame", nil, hud)
    row2:SetSize(500, 40)
    row2:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 8, 18)
    for i = 13, 24 do
        local b = ActionButton(row2, i)
        b:SetPoint("BOTTOMLEFT", (i - 13) * 42, 0)
        H.actions[i] = b
    end
    -- experience, as the client lays it on the bar (StatusTrackingBar.xml / ExpBar.xml): a 1024 x 13 strip on the
    -- bar's top edge, an 8-high purple bar inside it and the Dwarf art's own frame strip (with its notches) over it
    local strip = CreateFrame("Frame", nil, bar)
    strip:SetSize(1024, 13)
    strip:SetPoint("TOP", bar, "TOP", 0, 0)
    strip:SetFrameLevel(bar:GetFrameLevel() + 2)
    local xp = K.Bar(strip, 1024, 8, 0.58, 0, 0.55)
    xp:SetPoint("RIGHT", strip, "RIGHT", 0, 0)
    xp.bg:SetColorTexture(0, 0, 0, 0.5)
    local frameCoords = { { 0.79296875, 0.83203125 }, { 0.54296875, 0.58203125 }, { 0.29296875, 0.33203125 },
                          { 0.04296875, 0.08203125 } }
    for i = 1, 4 do
        local t = K.Tex(strip, "OVERLAY", "Interface\\MainMenuBar\\UI-MainMenuBar-Dwarf")
        t:SetSize(256, 10)
        t:SetPoint("TOPLEFT", (i - 1) * 256, 0)
        t:SetTexCoord(0, 1, frameCoords[i][1], frameCoords[i][2])
    end
    -- the text sits over the frame (TextStatusBar: shown while the mouse is on the bar)
    local over = CreateFrame("Frame", nil, strip)
    over:SetAllPoints()
    over:SetFrameLevel(strip:GetFrameLevel() + 3)
    xp.text:Hide()
    xp.text = K.Text(over, "TextStatusBarText", "OVERLAY", "CENTER")
    xp.text:SetPoint("CENTER", strip, "CENTER", 0, 1)
    xp.text:Hide()
    strip:EnableMouse(true)
    strip:SetScript("OnEnter", function() xp.text:Show() end)
    strip:SetScript("OnLeave", function() xp.text:Hide() end)
    H.xp = xp
    -- micro menu: character, spellbook, quest log, social (party), main menu
    local micro = {
        { "Character Info (C)", "Interface\\Buttons\\UI-MicroButton-Socials-Up", function() UI.Toggle("character") end, true },
        { "Spellbook & Abilities (P)", "Interface\\Buttons\\UI-MicroButton-Spellbook-Up", function() UI.Toggle("spellbook") end },
        { "Quest Log (L)", "Interface\\Buttons\\UI-MicroButton-Quest-Up", function() UI.Toggle("questlog") end },
        { "Party (O)", "Interface\\Buttons\\UI-MicroButton-Socials-Up", function() UI.Toggle("party") end },
        { "Game Menu (Esc)", "Interface\\Buttons\\UI-MicroButton-MainMenu-Up", function() UI.Toggle("menu") end },
    }
    H.micro = {}
    for i, m in ipairs(micro) do
        local b = CreateFrame("Button", nil, bar)
        b:SetSize(28, 58)
        b:SetPoint("BOTTOMLEFT", 552 + (i - 1) * 29, 2)
        b:SetNormalTexture(m[2])
        b:SetHighlightTexture("Interface\\Buttons\\UI-MicroButton-Hilight", "ADD")
        if m[4] then
            -- the character button: your portrait on the blank button
            local t = K.Tex(b, "OVERLAY")
            t:SetSize(18, 25)
            t:SetPoint("TOP", 0, -28)
            K.HeroPortrait(t, Craft.char and Craft.char.sex or 0)
            t:SetTexCoord(0.2, 0.8, 0.0666, 0.9)
            b.portrait = t
        end
        b:SetScript("OnClick", m[3])
        b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_TOP") GameTooltip:SetText(m[1], 1, 1, 1) GameTooltip:Show() end)
        b:SetScript("OnLeave", K.HideTooltip)
        H.micro[i] = b
    end
    -- bags: the backpack and four bag slots (right to left)
    H.bagButtons = {}
    for i = 0, 4 do
        local b = K.SlotButton(bar, i == 0 and 37 or 30)
        if i == 0 then b:SetPoint("BOTTOMRIGHT", -6, 4)
        else b:SetPoint("RIGHT", H.bagButtons[i - 1], "LEFT", -4, 0) end
        b.bag = i
        b:SetScript("OnClick", function(self, button)
            if UI.cursorItem and self.bag > 0 then UI.DropOnBagSlot(self.bag) return end
            UI.ToggleBag(self.bag)
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            local c = Craft.char
            if self.bag == 0 then GameTooltip:SetText("Backpack", 1, 1, 1)
            elseif c.bags[self.bag] and c.bags[self.bag].item then K.ItemTooltip(self, c.bags[self.bag].item, "nosell") return
            else GameTooltip:SetText("Bag Slot", 1, 1, 1) end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", K.HideTooltip)
        b:RegisterForDrag("LeftButton")
        b:SetScript("OnDragStart", function(self) if self.bag > 0 then Craft.Items.UnequipBag(self.bag) end end)
        H.bagButtons[i] = b
    end
    -- the free slots counter on the backpack
    H.free = K.Text(H.bagButtons[0], "NumberFontNormal", "OVERLAY", "RIGHT")
    H.free:SetPoint("BOTTOMRIGHT", -2, 2)
end

---------------------------------------------------------------------------
-- Cast bar
---------------------------------------------------------------------------

function UI.BuildCastBar(hud)
    local cb = K.Bar(hud, 195, 13, 1, 0.7, 0)
    cb:SetPoint("BOTTOM", 0, 150)
    cb.bg:SetColorTexture(0, 0, 0, 0.6)
    cb.border = K.Tex(cb, "OVERLAY", "Interface\\CastingBar\\UI-CastingBar-Border")
    cb.border:SetSize(256, 64)
    cb.border:SetPoint("TOP", 0, 28)
    cb.spark = K.Tex(cb, "OVERLAY", "Interface\\CastingBar\\UI-CastingBar-Spark")
    cb.spark:SetSize(32, 32)
    cb.spark:SetBlendMode("ADD")
    cb.flash = K.Tex(cb, "OVERLAY", "Interface\\CastingBar\\UI-CastingBar-Flash")
    cb.flash:SetSize(256, 64)
    cb.flash:SetPoint("TOP", 0, 28)
    cb.flash:SetBlendMode("ADD")
    cb.flash:Hide()
    cb.text:SetFontObject(GameFontHighlight)
    cb.text:ClearAllPoints()
    cb.text:SetPoint("TOP", 0, 5)
    cb:Hide()
    H.cast = cb
end

local function UpdateCastBar()
    local cb = H.cast
    local p = Craft.player
    local c = p.casting
    local now = Now()
    if c then
        cb.fadeAt = nil
        cb.flash:Hide()
        cb:SetAlpha(1)
        cb:Show()
        local sp = D.spells[c.spell]
        cb.text:SetText(c.name or (sp and sp.n) or "")
        local total = max(0.01, c.ends - c.start)
        local f = Craft.Clamp((now - c.start) / total, 0, 1)
        if c.channel then f = 1 - f cb:SetStatusBarColor(0, 1, 0) else cb:SetStatusBarColor(1, 0.7, 0) end
        cb:SetValue(f)
        cb.spark:ClearAllPoints()
        cb.spark:SetPoint("CENTER", cb, "LEFT", f * 195, 2)
        cb.spark:Show()
        H.castWas = c
    elseif H.castWas then
        -- the end: a green flash when it went off, red when it was stopped
        cb.fadeAt = now
        cb.spark:Hide()
        if H.castResult == "interrupted" or H.castResult == "failed" then
            cb:SetStatusBarColor(1, 0, 0)
            cb:SetValue(1)
            cb.text:SetText(H.castResult == "failed" and "Failed" or "Interrupted")
        else
            cb:SetStatusBarColor(0, 1, 0)
            cb:SetValue(1)
            cb.flash:Show()
        end
        H.castWas = nil
    end
    if cb.fadeAt then
        local a = 1 - (now - cb.fadeAt) / 0.5
        if a <= 0 then cb:Hide() cb.fadeAt = nil else cb:SetAlpha(a) end
    end
end

---------------------------------------------------------------------------
-- Chat box, errors, notices, zone text
---------------------------------------------------------------------------

local CHAT_LINES = 9
function UI.BuildChat(hud)
    local f = CreateFrame("Frame", nil, hud)
    f:SetSize(400, CHAT_LINES * 15 + 8)
    f:SetPoint("BOTTOMLEFT", 16, 112)
    f.bg = K.Tex(f, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0, 0, 0, 0.25)
    f.lines = {}
    for i = 1, CHAT_LINES do
        local fs = K.Font(f, 12, "OUTLINE")
        fs:SetPoint("BOTTOMLEFT", 4, 4 + (i - 1) * 15)
        fs:SetWidth(392)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        f.lines[i] = fs
    end
    H.chat = f
    -- typing: Enter opens it; /s, /p, /e as in WoW
    local eb = CreateFrame("EditBox", nil, hud, BackdropTemplateMixin and "BackdropTemplate" or nil)
    eb:SetSize(400, 24)
    eb:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -2)
    eb:SetFontObject(ChatFontNormal or GameFontHighlight)
    eb:SetAutoFocus(false)
    if eb.SetBackdrop then eb:SetBackdrop(K.TOOLTIP_BACKDROP) eb:SetBackdropColor(0, 0, 0, 0.8) end
    eb:SetTextInsets(8, 8, 0, 0)
    eb:Hide()
    eb:SetScript("OnEscapePressed", function(self) self:SetText("") self:ClearFocus() self:Hide() end)
    eb:SetScript("OnEnterPressed", function(self)
        local text = self:GetText() or ""
        self:SetText("")
        self:ClearFocus()
        self:Hide()
        if text ~= "" then UI.SayLine(text) end
    end)
    H.edit = eb
end

function UI.OpenChat()
    H.edit:Show()
    H.edit:SetFocus()
end

function UI.SayLine(text)
    local kind, msg = "say", text
    local cmd, rest = text:match("^/(%S+)%s*(.*)$")
    if cmd then
        cmd = cmd:lower()
        if cmd == "p" or cmd == "party" then kind, msg = "party", rest
        elseif cmd == "s" or cmd == "say" then kind, msg = "say", rest
        elseif cmd == "e" or cmd == "me" or cmd == "emote" then kind, msg = "emote", rest
        elseif cmd == "invite" or cmd == "inv" then if Craft.Party then Craft.Party.Invite(rest) end return
        elseif cmd == "leave" then if Craft.Party then Craft.Party.Leave() end return
        elseif cmd == "sit" then Craft.World.ToggleSit() return
        else Craft:Msg("Unknown command: /" .. cmd, "system") return end
    end
    if msg == "" then return end
    local p = Craft.player
    if kind == "emote" then Craft:Msg(p.name .. " " .. msg, "emote")
    elseif kind == "party" then Craft:Msg("[Party] " .. p.name .. ": " .. msg, "party")
    else
        Craft:Msg(p.name .. " says: " .. msg, "say")
        UI.Bubble(p, msg)
    end
    if Craft.Party and Craft.Party.Chat then Craft.Party.Chat(kind, msg) end
end

local function UpdateChat()
    local log = Craft.log
    local now = Now()
    local n = #log
    local f = H.chat
    local anyShown = false
    local y = 4
    for i = 1, CHAT_LINES do
        local e = log[n - i + 1]
        local fs = f.lines[i]
        if e and y < CHAT_LINES * 15 then
            local age = now - e.t
            local fade = H.edit:IsShown() and 1 or (age < 20 and 1 or max(0, 1 - (age - 20) / 3))
            local c = Craft.CHAT_COLORS[e.kind] or Craft.CHAT_COLORS.system
            fs:SetText(e.text)
            fs:SetTextColor(c[1], c[2], c[3])
            fs:SetAlpha(fade)
            fs:SetShown(fade > 0)
            fs:ClearAllPoints()
            fs:SetPoint("BOTTOMLEFT", 4, y)
            y = y + (fs:GetStringHeight() or 14) + 1
            if fade > 0 then anyShown = true end
        else
            fs:SetText("")
            fs:Hide()
        end
    end
    f.bg:SetAlpha((anyShown or H.edit:IsShown()) and 1 or 0)
end

function UI.BuildTexts(hud)
    -- the red error line and the yellow quest line (UIErrorsFrame)
    H.errors = {}
    for i = 1, 3 do
        local fs = K.Font(hud, 16, "OUTLINE")
        fs:SetPoint("TOP", 0, -122 - (i - 1) * 19)
        fs:Hide()
        H.errors[i] = { fs = fs, t = 0 }
    end
    -- the zone's name, big and gold, fading (ZoneTextFrame)
    H.zone = K.Font(hud, 30, "THICKOUTLINE")
    H.zone:SetPoint("TOP", 0, -180)
    H.zone:SetTextColor(1, 0.9294, 0.7607)
    H.zone:Hide()
    H.subzone = K.Font(hud, 20, "THICKOUTLINE")
    H.subzone:SetPoint("TOP", H.zone, "BOTTOM", 0, -4)
    H.subzone:SetTextColor(1, 0.9294, 0.7607)
    H.subzone:Hide()
    -- level up
    H.levelup = K.Font(hud, 26, "THICKOUTLINE")
    H.levelup:SetPoint("TOP", 0, -240)
    H.levelup:SetTextColor(1, 0.82, 0)
    H.levelup:Hide()
end

local function PushLine(text, r, g, b)
    local L = H.errors
    for i = #L, 2, -1 do L[i].text, L[i].t, L[i].c = L[i - 1].text, L[i - 1].t, L[i - 1].c end
    L[1].text, L[1].t, L[1].c = text, Now(), { r, g, b }
end

local function UpdateTexts()
    local now = Now()
    for _, e in ipairs(H.errors) do
        if e.text and now - e.t < 4 then
            e.fs:SetText(e.text)
            e.fs:SetTextColor(e.c[1], e.c[2], e.c[3])
            e.fs:SetAlpha(now - e.t < 3 and 1 or (4 - (now - e.t)))
            e.fs:Show()
        else
            e.fs:Hide()
        end
    end
    if H.zoneAt then
        local age = now - H.zoneAt
        local a = age < 0.5 and age / 0.5 or (age < 3.5 and 1 or max(0, 1 - (age - 3.5) / 1.5))
        H.zone:SetAlpha(a) H.subzone:SetAlpha(a)
        H.zone:SetShown(a > 0) H.subzone:SetShown(a > 0 and H.subzone:GetText() ~= "")
        if a <= 0 and age > 1 then H.zoneAt = nil end
    end
    if H.levelAt then
        local age = now - H.levelAt
        local a = age < 4 and 1 or max(0, 1 - (age - 4))
        H.levelup:SetAlpha(a)
        H.levelup:SetShown(a > 0)
        if a <= 0 then H.levelAt = nil end
    end
end

---------------------------------------------------------------------------
-- Quest tracker (the watch frame under the buffs)
---------------------------------------------------------------------------

function UI.BuildTracker(hud)
    local f = CreateFrame("Frame", nil, hud)
    f:SetSize(250, 300)
    f:SetPoint("TOPRIGHT", -16, -130)
    f.lines = {}
    H.tracker = f
end

local function UpdateTracker()
    local f = H.tracker
    local log = Craft.Quests.Log()
    local i = 0
    local y = 0
    local function line(text, font, r, g, b, indent)
        i = i + 1
        local fs = f.lines[i]
        if not fs then fs = K.Font(f, 12, "OUTLINE") fs:SetJustifyH("LEFT") fs:SetWidth(240) f.lines[i] = fs end
        fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", font, "OUTLINE")
        fs:SetText(text)
        fs:SetTextColor(r, g, b)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", indent or 0, -y)
        fs:Show()
        y = y + (fs:GetStringHeight() or 13) + 2
    end
    local unwatch = Craft.char and Craft.char.unwatch or {}
    local shown = 0
    -- (the quest log's Track box takes a quest off; five at most, like WoW)
    for _, q in ipairs(log) do
        if not unwatch[q.id] and shown < 5 then
            shown = shown + 1
            line(q.title, 13, 1, 0.82, 0)
            if q.done then line("- Complete", 12, 0.2, 1, 0.2, 8)
            elseif #q.lines > 0 then
                for _, l in ipairs(q.lines) do
                    if l.done then line("- " .. l.text, 12, 0.6, 0.6, 0.6, 8) else line("- " .. l.text, 12, 1, 1, 1, 8) end
                end
            else
                line("- " .. (q.goal or ""), 12, 1, 1, 1, 8)
            end
            y = y + 4
        end
    end
    for j = i + 1, #f.lines do f.lines[j]:Hide() end
end

---------------------------------------------------------------------------
-- Popups: Release Spirit, Resurrect, the spirit healer, a party invite
---------------------------------------------------------------------------

function UI.BuildPopups(hud)
    local p = K.Frame(hud, 320, 100, K.BACKDROP)
    p:SetPoint("TOP", 0, -140)
    p:SetFrameLevel(hud:GetFrameLevel() + 90)
    p.text = K.Text(p, "GameFontHighlight", "OVERLAY", "CENTER")
    p.text:SetPoint("TOP", 0, -20)
    p.text:SetWidth(290)
    p.b1 = K.Button(p, "", 128, 22)
    p.b1:SetPoint("BOTTOMLEFT", 24, 18)
    p.b2 = K.Button(p, "", 128, 22)
    p.b2:SetPoint("BOTTOMRIGHT", -24, 18)
    p:EnableMouse(true)
    p:Hide()
    H.popup = p
end

-- popup(text, button1 = { label, fn }, button2 = { label, fn } or nil)
function UI.Popup(key, text, b1, b2)
    local p = H.popup
    if p.key == key and p:IsShown() then return end
    p.key = key
    p.text:SetText(text)
    p.b1:SetText(b1[1])
    p.b1:SetScript("OnClick", function() p:Hide() p.key = nil b1[2]() end)
    if b2 then
        p.b2:SetText(b2[1])
        p.b2:SetScript("OnClick", function() p:Hide() p.key = nil b2[2]() end)
        p.b2:Show()
        p.b1:ClearAllPoints() p.b1:SetPoint("BOTTOMLEFT", 24, 18)
    else
        p.b2:Hide()
        p.b1:ClearAllPoints() p.b1:SetPoint("BOTTOM", 0, 18)
    end
    p:SetHeight(max(90, (p.text:GetStringHeight() or 20) + 70))
    p:Show()
end

function UI.HidePopup(key)
    if H.popup.key == key then H.popup:Hide() H.popup.key = nil end
end

local function UpdatePopups()
    local p = Craft.player
    if p.dead and not p.ghost then
        UI.Popup("release", "You have died. Release your spirit to the nearest graveyard.",
                 { "Release Spirit", function() Craft.World.ReleaseSpirit() end })
    elseif p.ghost then
        UI.HidePopup("release")
        if Craft.World.CorpseDistance() <= 40 then
            UI.Popup("res", "Resurrect now?", { "Resurrect", function() Craft.World.Revive(true) end })
        else
            UI.HidePopup("res")
        end
    else
        UI.HidePopup("release")
        UI.HidePopup("res")
    end
end

---------------------------------------------------------------------------
-- Every frame
---------------------------------------------------------------------------

function UI.UpdateHud(dt)
    local p = Craft.player
    if not p or not H.frame then return end
    UpdateUnitFrame(H.player, p)
    local t = p.target
    if t and (t.rec and t.rec.hidden) then Craft.World.SetTarget(nil) t = nil end
    UpdateUnitFrame(H.target, t)
    if t then
        UpdateAuras(H.targetAuras, t, false)
        local c = t.casting
        if c and t ~= p then
            local sp = D.spells[c.spell]
            H.tcast:Show()
            H.tcast.text:SetText(sp and sp.n or "")
            H.tcast:SetValue(Craft.Clamp((Now() - c.start) / max(0.01, c.ends - c.start), 0, 1))
        else
            H.tcast:Hide()
        end
    end
    UpdateAuras(H.buffs, p, true)
    for _, b in ipairs(H.actions) do UpdateAction(b) end
    -- experience
    local c = Craft.char
    local need = Craft:XPToLevel(c.level)
    H.xp:SetMinMaxValues(0, max(1, need))
    H.xp:SetValue(c.level >= D.MAX_LEVEL and need or c.xp)
    H.xp.text:SetText(c.level >= D.MAX_LEVEL and "Max level" or ("XP: " .. c.xp .. " / " .. need))
    -- bags
    for i = 0, 4 do
        local b = H.bagButtons[i]
        if i == 0 then b.icon:SetTexture("Interface\\Buttons\\Button-Backpack-Up") b.icon:Show()
        else
            local bag = c.bags[i]
            if bag and bag.item then K.SetItem(b, bag.item) else K.SetItem(b, nil) end
        end
    end
    H.free:SetText("(" .. Craft.Items.FreeSlots() .. ")")
    UpdateCastBar()
    UpdateChat()
    UpdateTexts()
    UpdateTracker()
    UpdatePopups()
end

---------------------------------------------------------------------------
-- Game events -> the HUD
---------------------------------------------------------------------------

Craft:On("error", function(text)
    if not H.frame then return end
    PushLine(text, 1, 0.1, 0.1)
    K.Play(K.SFX.error, 0.5)
end)

Craft:On("notice", function(text)
    if not H.frame then return end
    PushLine(text, 1, 1, 0)
end)

Craft:On("area", function(name, zone, quiet)
    if not H.frame then return end
    H.zone:SetText(zone and zone ~= name and zone or name)
    H.subzone:SetText(zone and zone ~= name and name or "")
    H.zoneAt = Now()
end)

Craft:On("level", function(lvl)
    if not H.frame then return end
    H.levelup:SetText("You have reached level " .. lvl .. "!")
    H.levelAt = Now()
    K.Play(K.SFX.levelup)
    if Craft.player and UI.FX then UI.LevelUpEffect(Craft.player) end
end)

Craft:On("cast", function(u, id, what, target)
    if u == Craft.player then
        if what == "interrupted" or what == "failed" or what == "done" then H.castResult = what end
        if what == "start" or what == "channel" then H.castResult = nil end
    end
    -- (the spell's own models and sound kits: UIEffects.lua)
end)

local RESULT_TEXT = { miss = "Miss", dodge = "Dodge", parry = "Parry", resist = "Resist", block = "Block", absorb = "Absorb" }
Craft:On("damage", function(src, dst, amount, info)
    local p = Craft.player
    if not p or not H.frame then return end
    if dst.map ~= p.map then return end
    local mine = src == p or dst == p
    if not mine and not (src and Craft.Party and Craft.Party.IsMember and Craft.Party.IsMember(src)) then return end
    if info.result and RESULT_TEXT[info.result] and amount == 0 then
        UI.FCT(dst, RESULT_TEXT[info.result], 1, 1, 1)
        if info.kind == "melee" then K.Play(K.SFX.miss, 0.1) end
        return
    end
    if amount <= 0 and not info.absorbed then return end
    local text = tostring(amount)
    if info.absorbed and amount == 0 then text = "Absorb" end
    if dst == p then
        UI.FCT(dst, "-" .. text, 1, 0.1, 0.1, info.crit)
        dst.flashUntil = Now() + 0.15
    else
        local c = (info.kind == "melee" and info.school == 1) and { 1, 1, 1 } or (Combat.SCHOOL_COLORS[info.school or 1] or { 1, 1, 0 })
        if info.kind == "dot" then c = { 1, 1, 0 } end
        UI.FCT(dst, text, c[1], c[2], c[3], info.crit)
        dst.flashUntil = Now() + 0.12
    end
    if info.kind == "melee" then K.Play(info.crit and K.SFX.crit or K.SFX.hit, 0.06) end
end)

Craft:On("heal", function(src, dst, amount, info)
    local p = Craft.player
    if not p or not H.frame or amount <= 0 then return end
    if src ~= p and dst ~= p then return end
    if info.kind == "hot" and amount < 1 then return end
    UI.FCT(dst, "+" .. amount, 0.1, 1, 0.1, info.crit)
    -- (the heal's own impact model and sound: UIEffects.lua)
end)

Craft:On("xp", function(xp, gained)
    if gained and gained > 0 and Craft.player and H.frame then
        UI.FCT(Craft.player, "+" .. gained .. " XP", 0.6, 0.4, 1)
    end
end)

Craft:On("bubble", function(u, text) if text then UI.Bubble(u, text) end end)
Craft:On("quest", function(id, what)
    if what == "accepted" then K.Play(K.SFX.quest)
    elseif what == "done" then K.Play(K.SFX.questdone)
    elseif what == "complete" then K.Play(K.SFX.quest) end
end)
Craft:On("money", function(total, delta) if delta and delta > 0 then K.Play(K.SFX.coin, 0.1) end end)
Craft:On("death", function(u)
    if u.kind == "mob" and u.entry and (u.cr and u.cr.type == 7) and (u.name or ""):find("Kobold") then K.Play(K.SFX.kobold.death, 0.2) end
end)
Craft:On("engage", function(mob)
    if (mob.name or ""):find("Kobold") then K.Play(K.SFX.kobold.aggro, 0.5) end
end)

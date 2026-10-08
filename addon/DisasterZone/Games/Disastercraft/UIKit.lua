if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/UIKit.lua", ...) then return end -- DisasterZone Games/Disastercraft/UIKit.lua
-- ns.CraftUI: Disastercraft's interface - World of Warcraft's own, built from the client's classic interface art
-- (Interface\TargetingFrame, MainMenuBar, Buttons, QuestFrame, ...) and its fonts. This file: the shared kit (frames,
-- texts, buttons, item and spell buttons, tooltips, sounds); UIWorld draws the map, UIHud the frames on it,
-- UIWindows the windows, UIGlue the character screens, UIMain wires it together.
local addonName, ns = ...

local UI = ns:NewModule("CraftUI")
local Craft = ns.Craft
local D = Craft.D
UI.Kit = {}
local K = UI.Kit

local floor, max, min = math.floor, math.max, math.min

K.MEDIA = "Interface\\AddOns\\DisasterZone\\Media\\Azeromon\\"
K.WHITE = "Interface\\Buttons\\WHITE8X8"
K.BACKDROP = { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
               tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } }
K.TOOLTIP_BACKDROP = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                       tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } }

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

function K.Frame(parent, w, h, backdrop, level)
    local f = CreateFrame("Frame", nil, parent, BACKDROP_TEMPLATE)
    if w then f:SetSize(w, h) end
    if backdrop and f.SetBackdrop then
        f:SetBackdrop(backdrop)
        if backdrop == K.TOOLTIP_BACKDROP then
            f:SetBackdropColor(0, 0, 0, 0.85)
            f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        end
    end
    if level then f:SetFrameLevel(level) end
    return f
end

-- the hero's face in the frames: a round portrait drawn from the same bare human as the pixel sprite
-- (dev/generators/gen_dc_portraits.py: Media/Azeromon/Outfit/portrait0 male, portrait1 female) - never your own
-- WoW character, never an untextured model
function K.HeroPortrait(t, sex)
    t:SetTexture(K.MEDIA .. "Outfit\\portrait" .. (sex == 1 and 1 or 0))
    t:SetTexCoord(0, 1, 0, 1)
end

-- a portrait cut round (SetPortraitTextureFromCreatureDisplayID hands out a square picture; the classic unit frames
-- only frame a circle) - the client's own portrait mask
function K.RoundMask(t)
    if t.dzMask or not t.GetParent then return end
    local p = t:GetParent()
    if not (p and p.CreateMaskTexture and t.AddMaskTexture) then return end
    local m = p:CreateMaskTexture()
    m:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    m:SetAllPoints(t)
    t:AddMaskTexture(m)
    t.dzMask = m
end

-- a DressUpModel showing a human of this sex in these items. A model loads after SetUnit / SetCustomRace return,
-- and a load landing late puts the unit's own look back - so it goes a step at a time: the unit (the first time),
-- once that has loaded the race and sex, once that has loaded undress and try the items on (and again for a
-- moment after, for a load that lands late).
local DRESS_WAIT = 0.6
function K.DressModel(m, sex, items)
    if not m then return end
    m.dzOutfit = { sex = sex or 0, items = items or {} }
    if not m.dzHooked then
        m.dzHooked = true
        pcall(m.HookScript, m, "OnModelLoaded", function(self) self.dzLoaded = true end)
    end
    local step, wait, dressing, at = 2, 0, 0, 1
    if not m.dzUnit then
        m.dzUnit, m.dzLoaded = true, false
        pcall(m.SetUnit, m, "player")
        step = 1
    end
    local function dress()
        if m.Undress then pcall(m.Undress, m) end
        for _, id in ipairs(m.dzOutfit.items) do
            if m.TryOn then pcall(m.TryOn, m, "item:" .. id) end
        end
    end
    m:SetScript("OnUpdate", function(self, dt)
        wait = wait + dt
        if step == 1 then                                   -- the unit's model
            if self.dzLoaded or wait > DRESS_WAIT then step, wait = 2, 0 end
        elseif step == 2 then                               -- a human of the hero's sex
            if self.SetCustomRace and self.dzSex ~= self.dzOutfit.sex then
                self.dzLoaded, self.dzSex = false, self.dzOutfit.sex
                pcall(self.SetCustomRace, self, 1, self.dzOutfit.sex)
                step, wait = 3, 0
            else
                step, wait = 4, 0
            end
        elseif step == 3 then
            if self.dzLoaded or wait > DRESS_WAIT then step, wait = 4, 0 end
        else                                                -- the outfit, a few times over
            at = at + dt
            if at >= 0.1 then at = 0 dress() end
            dressing = dressing + dt
            if dressing > 1.0 then self:SetScript("OnUpdate", nil) end
        end
    end)
end

function K.Tex(parent, layer, file, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
    if file then t:SetTexture(file) end
    return t
end

-- WoW's fonts by their font objects (GameFontNormal = gold Friz Quadrata, Highlight = white, ...)
function K.Text(parent, font, layer, justify)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontNormal")
    if not fs:GetFont() then fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "") end
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

-- a font string with an explicit size (Friz Quadrata), outlined when asked
function K.Font(parent, size, flags, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size or 12, flags or "")
    return fs
end

-- the red-and-gold panel button (UIPanelButtonTemplate)
function K.Button(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 100, h or 22)
    b:SetText(text or "")
    if onClick then
        b:SetScript("OnClick", function(self, button)
            if PlaySound then pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION or 852) end
            onClick(self, button)
        end)
    end
    return b
end

function K.CloseButton(parent, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    b:SetPoint("TOPRIGHT", -4, -4)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

-- a window with WoW's dialog border, a title bar and a close button
function K.Window(parent, w, h, title, onClose)
    local f = K.Frame(parent, w, h, K.BACKDROP)
    f:EnableMouse(true)
    f:SetFrameStrata("HIGH")
    f.title = K.Text(f, "GameFontNormal")
    f.title:SetPoint("TOP", 0, -16)
    f.title:SetText(title or "")
    local hdr = K.Tex(f, "ARTWORK", "Interface\\DialogFrame\\UI-DialogBox-Header")
    hdr:SetSize(max(180, w * 0.6), 64)
    hdr:SetPoint("TOP", 0, 12)
    f.header = hdr
    f.title:ClearAllPoints()
    f.title:SetPoint("TOP", hdr, "TOP", 0, -14)
    f.close = K.CloseButton(f, function() if onClose then onClose() else f:Hide() end end)
    f:Hide()
    return f
end

-- a status bar (health, mana, xp, cast)
function K.Bar(parent, w, h, r, g, b, tex)
    local s = CreateFrame("StatusBar", nil, parent)
    s:SetSize(w, h)
    s:SetStatusBarTexture(tex or "Interface\\TargetingFrame\\UI-StatusBar")
    s:SetStatusBarColor(r or 0, g or 1, b or 0)
    s:SetMinMaxValues(0, 1)
    s:SetValue(1)
    s.text = K.Font(s, max(8, floor(h * 0.75)), "OUTLINE")
    s.text:SetPoint("CENTER", 0, 1)
    s.bg = K.Tex(s, "BACKGROUND")
    s.bg:SetAllPoints()
    s.bg:SetColorTexture(0, 0, 0, 0.5)
    return s
end

---------------------------------------------------------------------------
-- Item and spell buttons (the square slot with the icon, the count, the cooldown swirl)
---------------------------------------------------------------------------

function K.SlotButton(parent, size, empty)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size or 37, size or 37)
    b.bg = K.Tex(b, "BACKGROUND", empty or "Interface\\Buttons\\UI-EmptySlot")
    b.bg:SetPoint("CENTER")
    b.bg:SetSize((size or 37) * 1.73, (size or 37) * 1.73)
    b.icon = K.Tex(b, "ARTWORK")
    b.icon:SetAllPoints()
    b.count = K.Text(b, "NumberFontNormal", "OVERLAY", "RIGHT")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    b.border = K.Tex(b, "OVERLAY", "Interface\\Buttons\\UI-ActionButton-Border")
    b.border:SetBlendMode("ADD")
    b.border:SetPoint("CENTER")
    b.border:SetSize((size or 37) * 1.8, (size or 37) * 1.8)
    b.border:Hide()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cd:SetAllPoints()
    if b.cd.SetDrawEdge then b.cd:SetDrawEdge(false) end
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    return b
end

-- shows item `id` (count n) on a slot button, with its quality border
function K.SetItem(b, id, n)
    b.itemId = id
    if not id then
        b.icon:Hide()
        b.count:SetText("")
        b.border:Hide()
        if b.bg then b.bg:Show() end
        return
    end
    b.icon:SetTexture(Craft.Items.Icon(id))
    b.icon:Show()
    b.count:SetText((n and n > 1) and n or "")
    local it = D.items[id]
    local q = it and it.q or 1
    if q >= 2 then
        local c = Craft.Items.QUALITY_RGB[q]
        b.border:SetVertexColor(c[1], c[2], c[3], 0.6)
        b.border:Show()
    else
        b.border:Hide()
    end
end

---------------------------------------------------------------------------
-- Tooltips (the client's own GameTooltip: real item tooltips, WoW-style unit and spell lines)
---------------------------------------------------------------------------

local function Q(it) return Craft.Items.QUALITY_RGB[it and it.q or 1] end

function K.ItemTooltip(owner, id, extra)
    local tt = GameTooltip
    tt:SetOwner(owner, "ANCHOR_RIGHT")
    local it = D.items[id]
    local ok = false
    if tt.SetItemByID then ok = pcall(tt.SetItemByID, tt, id) end
    if not ok or tt:NumLines() == 0 then
        -- (our own lines, WoW's order)
        local c = Q(it)
        tt:SetText(it and it.n or "?", c[1], c[2], c[3])
        if it then
            if it.bind == 1 then tt:AddLine("Binds when picked up", 1, 1, 1) elseif it.bind == 2 then tt:AddLine("Binds when equipped", 1, 1, 1) end
            if it.inv and Craft.Items.INV_NAMES[it.inv] then
                local sub = (it.c == 2 and Craft.Items.WEAPON_NAMES[it.s]) or (it.c == 4 and it.s > 0 and Craft.Items.ARMOR_NAMES[it.s]) or ""
                tt:AddDoubleLine(Craft.Items.INV_NAMES[it.inv], sub, 1, 1, 1, 1, 1, 1)
            end
            if it.dmg then
                tt:AddDoubleLine(string.format("%d - %d Damage", it.dmg[1], it.dmg[2]), string.format("Speed %.2f", (it.spd or 2000) / 1000), 1, 1, 1, 1, 1, 1)
                tt:AddLine(string.format("(%.1f damage per second)", (it.dmg[1] + it.dmg[2]) / 2 / ((it.spd or 2000) / 1000)), 1, 1, 1)
            end
            if it.armor then tt:AddLine(it.armor .. " Armor", 1, 1, 1) end
            local names = { [3] = "Agility", [4] = "Strength", [5] = "Intellect", [6] = "Spirit", [7] = "Stamina" }
            for i = 1, #(it.stats or {}), 2 do
                local n = names[it.stats[i]]
                if n then tt:AddLine(string.format("+%d %s", it.stats[i + 1], n), 1, 1, 1) end
            end
            if it.slots then tt:AddLine(it.slots .. " Slot Bag", 1, 1, 1) end
            if it.req and it.req > 1 then
                local lv = Craft.char and Craft.char.level or 1
                tt:AddLine("Requires Level " .. it.req, lv >= it.req and 1 or 1, lv >= it.req and 1 or 0.1, lv >= it.req and 1 or 0.1)
            end
            for _, sp in ipairs(it.spells or {}) do
                local s = D.spells[sp[1]]
                if s and sp[2] == 0 then tt:AddLine("Use: " .. Craft.Combat.SpellText(sp[1], Craft.player), 0, 1, 0, true) end
            end
            if it.desc then tt:AddLine('"' .. it.desc .. '"', 1, 0.82, 0, true) end
        end
    end
    if it and it.sell and it.sell > 0 and extra ~= "nosell" then
        if tt.SetItemByID and ok then
            -- (the client shows its own sell price line on a vendor; outside, add ours)
        end
        tt:AddLine("Sell Price: " .. Craft.MoneyText(it.sell, true), 1, 1, 1)
    end
    if type(extra) == "string" and extra ~= "nosell" then tt:AddLine(extra, 0, 1, 0, true) end
    tt:Show()
end

function K.SpellTooltip(owner, id, extra)
    local tt = GameTooltip
    tt:SetOwner(owner, "ANCHOR_RIGHT")
    local sp = D.spells[id]
    if not sp then tt:Hide() return end
    local u = Craft.player
    tt:SetText(sp.n, 1, 1, 1)
    if sp.r then tt:AddLine(sp.r, 0.5, 0.5, 0.5) end
    local cost, pt = Craft.Combat.Cost(sp, u)
    local left = cost > 0 and ((pt == 1 and (floor(cost / 10) .. " Rage")) or (pt == -2 and (cost .. " Health")) or (cost .. " Mana")) or nil
    local right = sp.range and sp.range > 5 and (floor(sp.range) .. " yd range") or (sp.range == 5 and "Melee Range" or nil)
    if left or right then tt:AddDoubleLine(left or " ", right or " ", 1, 1, 1, 1, 1, 1) end
    local ct = (sp.cast or 0) / 1000
    local castText = Craft.Combat.IsChannel(sp) and "Channeled" or (ct > 0 and (string.format("%g", ct) .. " sec cast") or (Craft.Combat.IsNextSwing(sp) and "Next melee" or "Instant"))
    local cd = (sp.cd or 0) > 0 and sp.cd or ((sp.catCd or 0) > 0 and sp.catCd) or 0
    local cdText = cd > 0 and ((cd >= 60000 and (floor(cd / 60000) .. " min cooldown")) or (floor(cd / 1000) .. " sec cooldown")) or nil
    if not Craft.Combat.IsPassive(sp) then tt:AddDoubleLine(castText, cdText or " ", 1, 1, 1, 1, 1, 1) end
    local text = Craft.Combat.SpellText(id, u)
    if text ~= "" then tt:AddLine(text, 1, 0.82, 0, true) end
    if extra then tt:AddLine(extra, 0, 1, 0, true) end
    tt:Show()
end

-- a unit's tooltip: name, level and type, like hovering a mob in WoW
function K.UnitTooltip(owner, u, anchor)
    local tt = GameTooltip
    tt:SetOwner(owner, anchor or "ANCHOR_CURSOR")
    local p = Craft.player
    local r = Craft.Combat.Reaction(p, u)
    local cr, cg, cb = 1, 1, 0
    if r == "hostile" then cr, cg, cb = 1, 0.1, 0.1 elseif r == "friendly" then cr, cg, cb = 0.1, 1, 0.1 end
    if Craft.Combat.IsPlayer(u) then
        local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[Craft.CLASS_TOKENS[u.class] or ""]
        if c then cr, cg, cb = c.r, c.g, c.b end
    end
    tt:SetText(u.name or "?", cr, cg, cb)
    if u.title then tt:AddLine("<" .. u.title .. ">", 1, 1, 1) end
    local lvl = u.level or 1
    local types = { [1] = "Beast", [2] = "Dragonkin", [3] = "Demon", [4] = "Elemental", [5] = "Giant", [6] = "Undead",
                    [7] = "Humanoid", [8] = "Critter", [9] = "Mechanical" }
    local typ = Craft.Combat.IsPlayer(u) and ("Human " .. (Craft.CLASS_NAMES[u.class] or "")) or
                (u.cr and types[u.cr.type or 0]) or ""
    if u.elite then typ = typ .. " (Elite)" end
    local qr, qg, qb = Craft.Quests.Color(lvl, p and p.level or 1)
    tt:AddLine(string.format("Level %d %s", lvl, typ), qr, qg, qb)
    if u.dead then tt:AddLine("Corpse", 0.5, 0.5, 0.5) end
    -- quest objectives this creature counts for (WoW's quest tooltip lines)
    if u.entry and Craft.char then
        for id in pairs(Craft.char.quests) do
            local q = Craft.Quests.Get(id)
            for _, k in ipairs(q and q.kill or {}) do
                if k.entry == u.entry then
                    tt:AddLine(q.title, 1, 0.82, 0)
                    local st = Craft.Quests.State(id)
                    tt:AddLine(string.format(" - %s slain: %d/%d", k.name, min(k.count, st.k[k.entry] or 0), k.count), 1, 1, 1)
                end
            end
        end
    end
    tt:Show()
end

function K.HideTooltip() GameTooltip:Hide() end

---------------------------------------------------------------------------
-- Sounds (WoW's own files and sound kits)
---------------------------------------------------------------------------

K.SFX = {
    hit = { 567621, 567620, 567632 }, crit = 567619, miss = 569774,
    precast = { [4] = 569045, [16] = 568119, [2] = 568915, [32] = 569424, [64] = 568938, [8] = 568091 },
    impact = { [4] = 568461, [16] = 569378, [2] = 569402, [32] = 568353, [64] = 569631, [8] = 569708 },
    heal = 569570, shout = 568028, thunder = 569222, strike = 569059, frostarmor = 569286,
    levelup = 567431, quest = 567400, questdone = 567439, coin = 567428, loot = 567517, bag = 567543,
    sheet = 567507, book = 567545, questlog = 567504, error = 567520, open = 567490, close = 567464,
    equip = 567560, drink = 567492, start = 567419, page = 567472,
    kobold = { aggro = 553311, attack = 553319, wound = 553313, death = 553318 },
}

local lastPlay = {}
function K.Play(id, gap)
    if not id then return end
    if type(id) == "table" then id = id[math.random(1, #id)] end
    local now = GetTime and GetTime() or 0
    if lastPlay[id] and now - lastPlay[id] < (gap or 0.05) then return end
    lastPlay[id] = now
    local data = Craft:Data()
    if data.sfx == false then return end
    if PlaySoundFile then pcall(PlaySoundFile, id, "Master") end
end

-- a little helper to make a frame fade in / out
function K.Fade(f, show, t)
    if show then f:Show() f:SetAlpha(1) else f:Hide() end
end

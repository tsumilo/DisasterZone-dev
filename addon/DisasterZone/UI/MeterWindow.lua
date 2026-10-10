if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MeterWindow.lua", ...) then return end -- DisasterZone: meter drawing helpers.
-- Shared drawing helpers of the meters (MeterWindow.K): fonts, the HUD panel, gradients, numbers, class colours,
-- spec icons, ability names and icons (melee = the player's main hand), glyphs, places and sizes. The panels
-- themselves (dockable stacks of meter and threat views) are UI/MeterPanels.lua, the breakdown UI/MeterDetail.lua.
-- MeterWindow also keeps the facade other code calls: Toggle, OpenSettings, IsMe.
local addonName, ns = ...

local MW = ns:NewModule("MeterWindow")

local floor, max, min, abs, exp = math.floor, math.max, math.min, math.abs, math.exp
local pairs, ipairs, type, tonumber, tostring = pairs, ipairs, type, tonumber, tostring
local strformat = string.format

---------------------------------------------------------------------------
-- Shared drawing helpers (K)
---------------------------------------------------------------------------

local K = {}
MW.K = K
K.WHITE = "Interface\\Buttons\\WHITE8X8"
K.BAR = "Interface\\TargetingFrame\\UI-StatusBar"
K.DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
K.SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
K.FRIZ = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
K.NARROW = "Fonts\\ARIALN.TTF"
K.GOLD = { 1, 0.82, 0 }
K.INK = { 0.93, 0.91, 0.85 }
K.DIM = { 0.64, 0.62, 0.56 }
K.GREEN = { 0.27, 0.83, 0.45 }
K.RED = { 1, 0.36, 0.30 }

function K.Tex(parent, layer, path, r, g, b, a, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub)
    t:SetTexture(path or K.WHITE)
    if r then t:SetVertexColor(r, g, b, a or 1) end
    return t
end

function K.Font(parent, font, size, c, layer)
    local f = parent:CreateFontString(nil, layer or "OVERLAY")
    f:SetFont(font or K.FRIZ, size or 12, "")
    c = c or K.INK
    f:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    f:SetShadowColor(0, 0, 0, 1)
    f:SetShadowOffset(1, -1)
    f:SetWordWrap(false)
    return f
end

-- A two-colour gradient (bottom, top) where the client has one; the mean colour otherwise.
function K.Gradient(t, orient, c1, c2)
    t:SetTexture(K.WHITE)
    t:SetVertexColor((c1[1] + c2[1]) / 2, (c1[2] + c2[2]) / 2, (c1[3] + c2[3]) / 2, ((c1[4] or 1) + (c2[4] or 1)) / 2)
    if t.SetGradient and CreateColor then
        t:SetVertexColor(1, 1, 1, 1)
        pcall(t.SetGradient, t, orient or "VERTICAL", CreateColor(c1[1], c1[2], c1[3], c1[4] or 1),
            CreateColor(c2[1], c2[2], c2[3], c2[4] or 1))
    elseif t.SetGradientAlpha then
        pcall(t.SetGradientAlpha, t, orient or "VERTICAL", c1[1], c1[2], c1[3], c1[4] or 1, c2[1], c2[2], c2[3], c2[4] or 1)
    end
end

-- The HUD panel: a translucent dark fill, a black outer pixel and a faint light inner edge (f:SetEdge(r, g, b, a)).
function K.Panel(f, alpha)
    f.outer = K.Tex(f, "BACKGROUND", K.WHITE, 0, 0, 0, 0.9, -8)
    f.outer:SetPoint("TOPLEFT", -1, 1)
    f.outer:SetPoint("BOTTOMRIGHT", 1, -1)
    f.fill = K.Tex(f, "BACKGROUND", K.WHITE, 0.051, 0.051, 0.063, alpha or 0.9, -7)
    f.fill:SetAllPoints()
    f.edges = {}
    for i, pts in ipairs({ { "TOPLEFT", "TOPRIGHT", "h" }, { "BOTTOMLEFT", "BOTTOMRIGHT", "h" },
                           { "TOPLEFT", "BOTTOMLEFT", "v" }, { "TOPRIGHT", "BOTTOMRIGHT", "v" } }) do
        local e = K.Tex(f, "BORDER", K.WHITE, 1, 1, 1, 0.07, -8)
        e:SetPoint(pts[1]); e:SetPoint(pts[2])
        if pts[3] == "h" then e:SetHeight(1) else e:SetWidth(1) end
        f.edges[i] = e
    end
    function f:SetEdge(r, g, b, a) for _, e in ipairs(self.edges) do e:SetVertexColor(r, g, b, a) end end
end

-- Numbers: 1.24M, 824.1k, 9,845
function K.Int(v)
    v = floor((tonumber(v) or 0) + 0.5)
    local s = tostring(abs(v))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (v < 0 and "-" or "") .. out
end
function K.Fmt(v)
    v = tonumber(v) or 0
    if v >= 1e6 then return strformat("%.2fM", v / 1e6) end
    if v >= 1e4 then return strformat("%.1fk", v / 1e3) end
    return K.Int(v)
end
function K.Clock(s)
    s = floor((tonumber(s) or 0) + 0.5)
    if s >= 3600 then return strformat("%d:%02d:%02d", floor(s / 3600), floor(s % 3600 / 60), s % 60) end
    return strformat("%d:%02d", floor(s / 60), s % 60)
end
function K.Pct(v) return strformat("%.1f%%", tonumber(v) or 0) end

function K.ClassColor(cls)
    local c = cls and ((CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[cls]) or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]))
    if c then return c.r, c.g, c.b end
    return 0.6, 0.6, 0.6
end
function K.ClassHex(cls)
    local r, g, b = K.ClassColor(cls)
    return strformat("|cff%02x%02x%02x", floor(r * 255), floor(g * 255), floor(b * 255))
end

-- Spec icons by class and spec label (Core/Meter.lua's labels; RaidComp's set, which is keyed by spec index)
local SPEC_ICONS = {
    WARRIOR = { Arms = "Ability_Warrior_SavageBlow", Fury = "Ability_Warrior_InnerRage",
                Protection = "Ability_Warrior_DefensiveStance" },
    PALADIN = { Holy = "Spell_Holy_HolyBolt", Protection = "Spell_Holy_DevotionAura",
                Retribution = "Spell_Holy_AuraOfLight" },
    HUNTER = { ["Beast Mastery"] = "Ability_Hunter_BeastTaming", Marksmanship = "Ability_Marksmanship",
               Survival = "Ability_Hunter_SwiftStrike" },
    ROGUE = { Assassination = "Ability_Rogue_Eviscerate", Combat = "Ability_BackStab", Subtlety = "Ability_Stealth" },
    PRIEST = { Discipline = "Spell_Holy_WordFortitude", Holy = "Spell_Holy_HolyBolt",
               Shadow = "Spell_Shadow_ShadowWordPain" },
    SHAMAN = { Elemental = "Spell_Nature_Lightning", Enhancement = "Spell_Nature_LightningShield",
               Restoration = "Spell_Nature_MagicImmunity" },
    MAGE = { Arcane = "Spell_Holy_MagicalSentry", Fire = "Spell_Fire_FireBolt02", Frost = "Spell_Frost_FrostBolt02" },
    WARLOCK = { Affliction = "Spell_Shadow_DeathCoil", Demonology = "Spell_Shadow_Metamorphosis",
                Destruction = "Spell_Shadow_RainOfFire" },
    DRUID = { Balance = "Spell_Nature_StarFall", ["Feral (Cat)"] = "Ability_Druid_CatForm",
              ["Feral (Bear)"] = "Ability_Racial_BearForm", Restoration = "Spell_Nature_HealingTouch" },
}
function K.SpecIcon(cls, spec)
    local name = cls and spec and SPEC_ICONS[cls] and SPEC_ICONS[cls][spec]
    return name and ("Interface\\Icons\\" .. name) or nil
end

-- A player's icon: their spec's, else their class's (UI:ClassIcon's texture coords).
function K.SetPlayerIcon(tex, cls, spec)
    local path = K.SpecIcon(cls, spec)
    if path then
        tex:SetTexture(path)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        tex:Show()
    elseif ns.UI and ns.UI.ClassIcon and cls then
        ns.UI:ClassIcon(tex, cls)
    else
        tex:SetTexture(134400)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

-- Ability keys (Core/Meter.lua): a spell id, 0 melee, "p<id>" a pet's, "m<name>" an enemy's melee, "e<type>" falling,
-- drowning, fire, ...
local ENV = { FALLING = "Falling", DROWNING = "Drowning", FATIGUE = "Fatigue", FIRE = "Fire", LAVA = "Lava",
              SLIME = "Slime" }
function K.SpellName(key, pn)
    if key == 0 or key == "0" then return "Melee" end
    if type(key) == "string" then
        local c, rest = key:sub(1, 1), key:sub(2)
        if c == "p" then
            local pet = pn and pn[key] or "Pet"
            if rest == "0" then return pet .. " (melee)" end
            local n = GetSpellInfo and GetSpellInfo(tonumber(rest) or 0)
            return (n or ("Spell " .. rest)) .. " (" .. pet .. ")"
        elseif c == "m" then
            return "Melee (" .. rest .. ")"
        elseif c == "e" then
            return ENV[rest] or rest
        end
    end
    local n = GetSpellInfo and GetSpellInfo(tonumber(key) or 0)
    return n or ("Spell " .. tostring(key))
end
-- An ability's icon. Melee shows the player's main hand (a = the actor, a.wi), else a sword; a pet's melee a paw.
local SWORD = "Interface\\Icons\\INV_Sword_04"
local PAW = "Interface\\Icons\\Ability_Hunter_Pet_Wolf"
function K.SpellIcon(key, a)
    if key == 0 or key == "0" then return (a and a.wi) or SWORD end
    if key == "p0" then return PAW end
    if type(key) == "string" and key:sub(1, 1) == "m" then return SWORD end
    if type(key) == "string" and key:sub(1, 1) == "e" then return 135805 end
    local id = tonumber((type(key) == "string" and (key:gsub("^p", ""))) or key)
    local tex = id and GetSpellTexture and GetSpellTexture(id)
    return tex or 134400
end
function K.IconText(key, size, a)
    return strformat("|T%s:%d:%d:0:0:64:64:5:59:5:59|t", tostring(K.SpellIcon(key, a)), size or 14, size or 14)
end

-- The flat atlas glyph (UI.ICON) on a texture.
function K.Glyph(tex, name)
    local UI = ns.UI
    tex:SetTexture(UI.ICON_ATLAS)
    local c = UI:IconCoords(UI.ICON[name] or UI.ICON.more)
    tex:SetTexCoord(c[1], c[2], c[3], c[4])
end

-- Window place and size in meters.<posKey> / meters.<sizeKey>.
function K.SavePlace(f, posKey, sizeKey)
    local p, _, rp, x, y = f:GetPoint()
    if p then ns.DB:SetSetting("meters." .. posKey, { p, rp, floor(x + 0.5), floor(y + 0.5) }) end
    if sizeKey then ns.DB:SetSetting("meters." .. sizeKey, { floor(f:GetWidth() + 0.5), floor(f:GetHeight() + 0.5) }) end
end
function K.RestorePlace(f, posKey, defaultPoint)
    local pos = ns.DB:GetSetting("meters." .. posKey)
    f:ClearAllPoints()
    if type(pos) == "table" and type(pos[1]) == "string" and
        pcall(f.SetPoint, f, pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0) then
        return
    end
    f:SetPoint(defaultPoint[1], UIParent, defaultPoint[2], defaultPoint[3], defaultPoint[4])
end
function K.SetResizeBounds(f, minW, minH, maxW, maxH)
    if f.SetResizeBounds then f:SetResizeBounds(minW, minH, maxW, maxH)
    else
        if f.SetMinResize then f:SetMinResize(minW, minH) end
        if f.SetMaxResize then f:SetMaxResize(maxW, maxH) end
    end
end

-- A small header button (text and/or icon, hover wash). b:SetLit(on) while its menu is open.
function K.HeadButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(22)
    b.wash = K.Tex(b, "BACKGROUND", K.WHITE, 1, 1, 1, 0)
    b.wash:SetAllPoints()
    b:SetScript("OnEnter", function(self) self.wash:SetVertexColor(1, 1, 1, 0.07) end)
    b:SetScript("OnLeave", function(self) if not self.lit then self.wash:SetVertexColor(1, 1, 1, 0) end end)
    function b:SetLit(on)
        self.lit = on
        self.wash:SetVertexColor(1, 1, 1, on and 0.09 or 0)
    end
    function b:OnMenuShown(on) self:SetLit(on) end
    return b
end

-- A chevron (the atlas one points down).
function K.Chevron(parent, size, c)
    local t = parent:CreateTexture(nil, "OVERLAY")
    K.Glyph(t, "chevron")
    t:SetSize(size or 10, size or 10)
    c = c or K.GOLD
    t:SetVertexColor(c[1], c[2], c[3], 0.85)
    return t
end

---------------------------------------------------------------------------
-- Facade
---------------------------------------------------------------------------

-- Is this GUID me (the demo's "me" in demo mode)?
function MW.IsMe(g)
    local d = ns.Meter and ns.Meter:Data()
    if d and d.me then return g == d.me end
    return g == (UnitGUID and UnitGUID("player"))
end

function MW.OpenSettings()
    if not ns.MainFrame then return end
    ns.MainFrame:Open("settings")
    local S = ns.SettingsUI
    if S and S.SelectSection then S:SelectSection("meters") end
end

function MW:Toggle() if ns.MeterPanels then ns.MeterPanels:Toggle() end end
function MW:Refresh() if ns.MeterPanels then ns.MeterPanels:Refresh() end end

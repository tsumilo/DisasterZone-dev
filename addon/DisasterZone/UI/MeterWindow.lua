if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MeterWindow.lua", ...) then return end -- DisasterZone: meter drawing helpers.
-- What the meters share (MeterWindow.K): textures and fonts by name, the design tokens they paint with (ns.Style),
-- numbers, class colours, spec icons, ability names and icons (melee = the player's main hand), glyphs and where the
-- panels sit. No look builders live here: text is UI:Text on the type scale, fills / rules / gradients the UI
-- primitives, rows and cards the shared components, the panels' faces the themes (UI/MeterTheme.lua, ns.Themes
-- "meters"). The panels themselves (dockable stacks of meter and threat views) are UI/MeterPanels.lua, the breakdown
-- UI/MeterDetail.lua. MeterWindow also keeps the facade other code calls: Toggle, OpenSettings, IsMe.
local addonName, ns = ...

local MW = ns:NewModule("MeterWindow")
local S = ns.Style

local floor, abs = math.floor, math.abs
local type, tonumber, tostring = type, tonumber, tostring
local strformat = string.format

---------------------------------------------------------------------------
-- Shared values and helpers (K)
---------------------------------------------------------------------------

local K = {}
MW.K = K
K.WHITE = "Interface\\Buttons\\WHITE8X8"
K.BAR = "Interface\\TargetingFrame\\UI-StatusBar"
K.DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
K.SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
K.FRIZ = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
K.NARROW = S.FONT_NUM                     -- the narrow digits of the meters, tables and badges
-- (the meters' colours are the design tokens: the same tables, read-only)
K.GOLD = S.C.GOLD
K.INK = S.C.TEXT
K.DIM = S.C.SUB
K.GREEN = S.C.OK
K.RED = S.C.BAD

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
function K.Ordinal(n)
    n = tonumber(n) or 0
    local s = (n % 10 == 1 and n % 100 ~= 11) and "st" or (n % 10 == 2 and n % 100 ~= 12) and "nd"
        or (n % 10 == 3 and n % 100 ~= 13) and "rd" or "th"
    return n .. s
end

-- A class's colour (a player's addon colours first); grey for an unknown class. (UI:ClassColor reads only the game's
-- table and gives white for none: the meters' bars of an unknown player stay grey.)
local UNKNOWN = S.C.SUB
function K.ClassColor(cls)
    local c = cls and ((CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[cls]) or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]))
    if c then return c.r, c.g, c.b end
    return UNKNOWN[1], UNKNOWN[2], UNKNOWN[3]
end
function K.ClassHex(cls)
    local r, g, b = K.ClassColor(cls)
    return strformat("|cff%02x%02x%02x", floor(r * 255), floor(g * 255), floor(b * 255))
end

-- A spec's icon by class and spec label (Core/Meter.lua's labels: the specs' own icons, ns.SPECS).
function K.SpecIcon(cls, spec)
    return ns.SpecIcon and ns.SpecIcon(cls, spec) or nil
end

-- "Retribution Paladin" ("Guardian" for a bear, the cat's "(Cat)" dropped); the class alone without a spec.
function K.SpecText(a)
    local cls = a and a.c and ns.ClassName(a.c, true) or ""
    local spec = a and a.s and (a.s == "Feral (Bear)" and "Guardian" or (a.s:gsub(" %(.*%)", ""))) or nil
    return spec and (spec .. " " .. cls) or cls
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
    if type(key) == "string" and key:sub(1, 1) == "e" then return ns.Util.EnvIcon(key:sub(2)) end
    local id = tonumber((type(key) == "string" and (key:gsub("^p", ""))) or key)
    -- (the game's placeholder face: the actor's weapon, the proc's likely source; feedback #39)
    local tex, temp = ns.Util.SpellIcon(id)
    if temp then return (a and a.wi) or SWORD end
    return tex or 134400
end
function K.IconText(key, size, a)
    return ns.UI:IconText(K.SpellIcon(key, a), size or 14, true)
end

-- The flat atlas glyph (UI.ICON) on a texture.
function K.Glyph(tex, name)
    local UI = ns.UI
    tex:SetTexture(UI.ICON_ATLAS)
    local c = UI:IconCoords(UI.ICON[name] or UI.ICON.more)
    tex:SetTexCoord(c[1], c[2], c[3], c[4])
end

-- Window place and size in meters.<posKey> / meters.<sizeKey> (the meters' own saved places, kept where they are).
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
    local SU = ns.SettingsUI
    if SU and SU.SelectSection then SU:SelectSection("meters") end
end

function MW:Toggle() if ns.MeterPanels then ns.MeterPanels:Toggle() end end
function MW:Refresh() if ns.MeterPanels then ns.MeterPanels:Refresh() end end

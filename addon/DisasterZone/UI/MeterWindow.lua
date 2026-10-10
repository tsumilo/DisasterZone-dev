if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MeterWindow.lua", ...) then return end -- DisasterZone: the damage meter window.
-- The on-screen part of Core/Meter.lua (the approved mockup): a small flat window with a header (the mode, the fight,
-- a ··· menu), a total line and one bar per player in their class colour with the spec icon, rank, name, the value
-- and a second number (per second, or the total in DPS mode). Bars glide to their new place as the ranking changes;
-- my own bar stays in view (below the last visible row it takes that row, with its real rank and a gold line over
-- it). Hover: the player's top abilities; click: the breakdown (UI/MeterDetail.lua), in Deaths mode the death recap;
-- right-click: the window menu.
-- Out of combat (meters.ooc) it fades to FADED a few seconds after the fight, hides, or stays. Unlocked (meters.locked
-- false) it shows a gold edge, a resize corner and a hint; the header drags it.
-- Shared drawing helpers for the threat window and the breakdown: MeterWindow.K.
local addonName, ns = ...

local MW = ns:NewModule("MeterWindow")

local floor, max, min, abs, exp = math.floor, math.max, math.min, math.abs, math.exp
local pairs, ipairs, type, tonumber, tostring = pairs, ipairs, type, tonumber, tostring
local strformat = string.format

local ROW_H, ROW_GAP = 21, 1
local HEAD_H, TOT_H, INSET = 28, 22, 3
local DEFAULT_W, DEFAULT_H = 312, 236
local MIN_W, MIN_H, MAX_W, MAX_H = 210, 110, 640, 760
local FADED, FADE_AFTER = 0.38, 3
local EASE = 0.09                 -- seconds: how fast bars glide (exponential)
local SCALES = { small = 0.9, normal = 1, large = 1.15 }

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
-- State
---------------------------------------------------------------------------

local Meter
local frame
local rowsByKey, pool = {}, {}
local dirty = true
local lastDraw = 0
local userHidden = false
local combatEndedAt = 0
local alpha = 1

local function Setting(path, default)
    local v = ns.DB and ns.DB:GetSetting("meters." .. path)
    if v == nil then return default end
    return v
end
local function Set(path, v) ns.DB:SetSetting("meters." .. path, v) end

local function IsMe(g)
    local d = Meter:Data()
    if d.me then return g == d.me end
    return g == (UnitGUID and UnitGUID("player"))
end
MW.IsMe = IsMe

local function InCombat()
    return (Meter and Meter:GetLive() ~= nil) or (UnitAffectingCombat and UnitAffectingCombat("player")) or false
end

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------

local function ModeMenu(owner)
    ns.UI:ContextMenu(owner, function(root)
        for i, m in ipairs(Meter.MODES) do
            if m.group and i > 1 then root:CreateDivider() end
            local text = strformat("|T%s:14:14:0:0:64:64:5:59:5:59|t  %s", m.icon, m.label)
            root:CreateRadio(text, function() return Setting("mode", "damage") == m.key end,
                function() Set("mode", m.key) end, m.key)
        end
    end)
end

local function EJText(seg)
    local key = seg.name and ns.MyLog and ns.MyLog.BossDataKey and ns.MyLog:BossDataKey(seg.name)
    local fid = key and ns.Data and ns.Data.BossJournal and ns.Data.BossJournal[key]
    if fid then return strformat("|T%s:16:32:0:0:128:64:0:128:0:64|t ", tostring(fid)) end
    return ""
end

local function FightSub(seg)
    local parts = {}
    if seg.kind == "boss" then
        if seg.live then parts[#parts + 1] = "Live"
        elseif seg.kill then parts[#parts + 1] = "|cff45d474Kill|r"
        else parts[#parts + 1] = "|cffff7e6bWipe" .. (seg.pct and strformat(" %d%%", floor(seg.pct + 0.5)) or "") .. "|r" end
    elseif seg.kind == "trash" then
        parts[#parts + 1] = seg.live and "Live" or "Trash"
    end
    parts[#parts + 1] = K.Clock(Meter:Duration(seg))
    if seg.at and date then parts[#parts + 1] = date("%H:%M", seg.at) end
    if seg.cut then parts[#parts + 1] = "cut short" end
    return table.concat(parts, " · ")
end

local function FightMenu(owner)
    ns.UI:ContextMenu(owner, function(root)
        local fights, all = Meter:GetFights()
        local sel = Setting("seg", "cur")
        if #fights == 0 then
            root:CreateTitle("No fights yet")
            return
        end
        for i, seg in ipairs(fights) do
            local title = EJText(seg) .. (seg.live and "Current fight" or Meter:SegName(seg))
            local e = root:CreateRadio(title, function()
                if sel == "cur" then return i == 1 end
                return sel == seg.id
            end, function() Set("seg", i == 1 and "cur" or seg.id) end, seg.id)
            e:SetSubtext(FightSub(seg))
            if seg.live then e:SetBadge("Live", { 1, 0.42, 0.33 }) end
        end
        if all then
            root:CreateDivider()
            local e = root:CreateRadio(Meter:SegName(all), function() return sel == "all" end,
                function() Set("seg", "all") end, "all")
            local since = all.at and date and (" · since " .. date("%H:%M", all.at)) or ""
            e:SetSubtext((all.zone or "") .. since .. " · " .. K.Clock(Meter:Duration(all)))
        end
    end)
end

local function OpenSettings()
    if not ns.MainFrame then return end
    ns.MainFrame:Open("settings")
    local S = ns.SettingsUI
    if S and S.SelectSection then S:SelectSection("meters") end
end
MW.OpenSettings = OpenSettings

local function WindowMenu(owner)
    ns.UI:ContextMenu(owner, function(root)
        root:CreateCheckbox("Lock window", function() return Setting("locked", true) end,
            function() Set("locked", not Setting("locked", true)) end)
        root:CreateCheckbox("Fade out of combat", function() return Setting("ooc", "fade") == "fade" end,
            function() Set("ooc", Setting("ooc", "fade") == "fade" and "stay" or "fade") end)
        root:CreateCheckbox("Threat window", function() return Setting("thr", false) end,
            function() Set("thr", not Setting("thr", false)) end)
        root:CreateDivider()
        root:CreateButton(ns.UI:AtlasIconText(ns.UI.ICON.gear, 14) .. " Settings", OpenSettings)
        local clear = root:CreateButton("|cffff7d6e" .. ns.UI:AtlasIconText(ns.UI.ICON.trash, 14, { 1, 0.49, 0.43 })
            .. " Clear all fights|r")
        clear:CreateButton("|cffff7d6eYes, clear every fight|r", function() Meter:ClearAll(); Set("seg", "cur") end)
        root:CreateButton("Hide until /dz meter", function() userHidden = true; MW:UpdateVisibility() end)
    end)
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function RowTooltip(row)
    local r = row.data
    if not r then return end
    local seg = Meter:GetSegment(Setting("seg", "cur"))
    local mode = Setting("mode", "damage")
    local a = r.a
    local tt = GameTooltip
    tt:SetOwner(row, "ANCHOR_NONE")
    tt:ClearAllPoints()
    local left = frame:GetLeft() or 0
    if left > (UIParent:GetWidth() or 1000) / 2 then tt:SetPoint("TOPRIGHT", row, "TOPLEFT", -10, 4)
    else tt:SetPoint("TOPLEFT", row, "TOPRIGHT", 10, 4) end
    local spec = a.s and ((a.s:gsub(" %(.*%)", "")) .. " ") or ""
    tt:AddDoubleLine(K.ClassHex(a.c) .. (a.n or "?") .. "|r",
        "|cffa29d90" .. spec .. (a.c and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[a.c] or a.c) or "") .. "|r")
    local dur = Meter:Duration(seg)
    local act = Meter:ActiveTime(seg, a)
    local function top(list, total, fmt)
        local arr = {}
        for k, s in pairs(list or {}) do arr[#arr + 1] = { k, type(s) == "table" and s.a or s } end
        table.sort(arr, function(x, y) return x[2] > y[2] end)
        for i = 1, min(5, #arr) do
            local k, v = arr[i][1], arr[i][2]
            tt:AddDoubleLine(K.IconText(k, 14, a) .. " " .. (fmt and fmt(k) or K.SpellName(k, a.pn)),
                K.Fmt(v) .. strformat("  |cffa29d90%d%%|r", total > 0 and floor(v / total * 100 + 0.5) or 0),
                1, 1, 1, 1, 1, 1)
        end
    end
    if mode == "deaths" and r.d then
        local d = r.d
        tt:AddLine(strformat("Died at %s to %s", K.Clock(d.t), d.by and K.SpellName(d.by) or "?"), 1, 0.48, 0.42)
        for i = #(d.ev or {}), max(1, #(d.ev or {}) - 3), -1 do
            local e = d.ev[i]
            local amt = (e[2] == "d" and "|cffff6b5c-" or "|cff45d474+") .. K.Int(e[4]) .. "|r"
            tt:AddDoubleLine(strformat("|cffa29d90%.1f s|r %s %s", e[1], K.IconText(e[3], 14), K.SpellName(e[3])), amt,
                1, 1, 1, 1, 1, 1)
        end
        tt:AddLine("Click for the death recap", 0.2, 0.87, 0.2)
    elseif mode == "healing" then
        tt:AddLine(strformat("%s healing · %s per second · %d%% overhealing", K.Fmt(a.h), K.Int(a.h / act),
            (a.h + a.oh) > 0 and floor(a.oh / (a.h + a.oh) * 100 + 0.5) or 0), 0.64, 0.62, 0.56)
        top(a.hs, a.h)
        tt:AddLine("Click for the full breakdown", 0.2, 0.87, 0.2)
    elseif mode == "taken" then
        tt:AddLine(strformat("%s taken · %s per second", K.Fmt(a.t), K.Int(a.t / dur)), 0.64, 0.62, 0.56)
        top(a.ts, a.t)
        tt:AddLine("Click for the full breakdown", 0.2, 0.87, 0.2)
    elseif mode == "kicks" or mode == "dispels" then
        local by, cut = mode == "kicks" and a.ks or a.ds, mode == "kicks" and a.kx or a.dx
        for k, n in pairs(by or {}) do tt:AddDoubleLine(K.IconText(k, 14) .. " " .. K.SpellName(k), tostring(n), 1, 1, 1, 1, 1, 1) end
        if cut and next(cut) then
            tt:AddLine(mode == "kicks" and "What they interrupted" or "What they removed", 0.64, 0.62, 0.56)
            for k, n in pairs(cut) do tt:AddDoubleLine(K.IconText(k, 14) .. " " .. K.SpellName(k), tostring(n), 1, 1, 1, 1, 1, 1) end
        end
    else
        tt:AddLine(strformat("%s damage · %s per second · %d%% active", K.Fmt(a.d), K.Int(a.d / act),
            floor(min(dur, a.act or 0) / dur * 100 + 0.5)), 0.64, 0.62, 0.56)
        top(a.sp, a.d)
        tt:AddLine("Click for the full breakdown", 0.2, 0.87, 0.2)
    end
    tt:Show()
end

local function RowClick(row, button)
    if button == "RightButton" then WindowMenu(row) return end
    local r = row.data
    if not r or not ns.MeterDetail then return end
    GameTooltip:Hide()
    local sel = Setting("seg", "cur")
    local mode = Setting("mode", "damage")
    if mode == "deaths" and r.d then ns.MeterDetail:OpenDeath(sel, r.d)
    else ns.MeterDetail:Open(sel, r.g, mode) end
end

local function NewRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.bg = K.Tex(row, "BACKGROUND", K.WHITE, 1, 1, 1, 0.025)
    row.bg:SetAllPoints()
    row.fill = K.Tex(row, "BORDER", K.BAR)
    row.fill:SetPoint("TOPLEFT")
    row.fill:SetPoint("BOTTOMLEFT")
    row.shine = K.Tex(row, "BORDER", K.WHITE, 1, 1, 1, 0.12, 1)
    row.shine:SetPoint("TOPLEFT", row.fill, "TOPLEFT")
    row.shine:SetPoint("TOPRIGHT", row.fill, "TOPRIGHT")
    row.shine:SetHeight(1)
    row.ext = K.Tex(row, "BORDER", K.WHITE)
    row.ext:SetPoint("TOPLEFT", row.fill, "TOPRIGHT")
    row.ext:SetPoint("BOTTOMLEFT", row.fill, "BOTTOMRIGHT")
    row.you = K.Tex(row, "ARTWORK", K.WHITE, K.GOLD[1], K.GOLD[2], K.GOLD[3], 1)
    row.you:SetPoint("TOPLEFT")
    row.you:SetPoint("BOTTOMLEFT")
    row.you:SetWidth(2)
    row.pinLine = K.Tex(row, "ARTWORK", K.WHITE, K.GOLD[1], K.GOLD[2], K.GOLD[3], 0.5)
    row.pinLine:SetPoint("BOTTOMLEFT", row, "TOPLEFT", 0, 0)
    row.pinLine:SetPoint("BOTTOMRIGHT", row, "TOPRIGHT", 0, 0)
    row.pinLine:SetHeight(1)
    row.hover = K.Tex(row, "HIGHLIGHT", K.WHITE, 1, 1, 1, 0.08)
    row.hover:SetAllPoints()
    row.rank = K.Font(row, K.NARROW, 11.5, { 1, 1, 1, 0.75 })
    row.rank:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.rank:SetWidth(14)
    row.rank:SetJustifyH("RIGHT")
    row.icon = K.Tex(row, "ARTWORK", 134400)
    row.icon:SetSize(17, 17)
    row.icon:SetPoint("LEFT", row, "LEFT", 21, 0)
    row.value = K.Font(row, K.NARROW, 14, { 1, 1, 1 })
    row.sub = K.Font(row, K.NARROW, 12.5, { 0.93, 0.91, 0.85, 0.72 })
    row.sub:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.sub:SetJustifyH("RIGHT")
    row.kb = K.Tex(row, "ARTWORK", 134400)
    row.kb:SetSize(15, 15)
    row.kb:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.skull = K.Tex(row, "ARTWORK", K.SKULL)
    row.skull:SetSize(12, 12)
    row.name = K.Font(row, K.FRIZ, 12.5, { 1, 1, 1 })
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
    row.name:SetJustifyH("LEFT")
    row:SetScript("OnEnter", RowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", RowClick)
    row.y, row.w, row.ew = nil, 0, 0
    return row
end

local function TakeRow(key)
    local row = rowsByKey[key]
    if row then return row, false end
    row = table.remove(pool)
    if not row then row = NewRow(frame.rows) end
    rowsByKey[key] = row
    row.key = key
    row.y = nil
    row.w, row.ew = 0, 0
    return row, true
end

-- Lays out the right side of a row: [kb] value [sub]
local function PlaceRight(row, hasSub, hasKb)
    row.value:ClearAllPoints()
    if hasSub then
        row.sub:Show()
        local sw = max(44, row.sub:GetStringWidth() + 2)
        row.sub:SetWidth(sw)
        row.value:SetPoint("RIGHT", row.sub, "LEFT", -6, 0)
    else
        row.sub:Hide()
        row.value:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    end
    row.kb:ClearAllPoints()
    if hasKb then
        row.kb:Show()
        row.kb:SetPoint("RIGHT", row.value, "LEFT", -5, 0)
    else
        row.kb:Hide()
    end
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
    row.name:SetPoint("RIGHT", hasKb and row.kb or row.value, "LEFT", -18, 0)
end

-- (per second: by the player's active time, like Details; taken by the fight's length)
local VALUE = {
    damage = function(r, dur, seg) return K.Fmt(r.v), K.Int(r.v / Meter:ActiveTime(seg, r.a)) end,
    dps = function(r) return K.Int(r.v), K.Fmt(r.a.d) end,
    healing = function(r, dur, seg) return K.Fmt(r.v), K.Int(r.v / Meter:ActiveTime(seg, r.a)) end,
    taken = function(r, dur) return K.Fmt(r.v), K.Int(r.v / dur) end,
    deaths = function(r) return K.Clock(r.v), nil end,
    kicks = function(r) return tostring(r.v), nil end,
    dispels = function(r) return tostring(r.v), nil end,
    active = function(r, dur) return K.Pct(min(100, r.v / dur * 100)), K.Clock(r.v) end,
}

local function TopKey(map)
    local best, bv = nil, -1
    for k, v in pairs(map or {}) do if v > bv then best, bv = k, v end end
    return best
end

local function TotalText(seg, mode, rows, total, dur)
    local party = seg and (seg.size or 25) <= 5
    local who = party and "Party" or "Raid"
    if mode == "damage" then return who, K.Fmt(total), K.Int(total / dur) .. "/s" end
    if mode == "dps" then
        local d = 0
        for _, r in ipairs(rows) do d = d + (r.a.d or 0) end
        return who, K.Int(d / dur), K.Fmt(d)
    end
    if mode == "healing" then
        local oh = 0
        for _, r in ipairs(rows) do oh = oh + (r.ext or 0) end
        return who, K.Fmt(total), (total + oh) > 0 and strformat("%d%% over", floor(oh / (total + oh) * 100 + 0.5)) or ""
    end
    if mode == "taken" then return who, K.Fmt(total), K.Int(total / dur) .. "/s" end
    if mode == "deaths" then return "Deaths", tostring(total), "" end
    if mode == "kicks" then return who, tostring(total), "interrupts" end
    if mode == "dispels" then return who, tostring(total), "dispels" end
    return who .. " average", K.Pct(min(100, total / dur * 100)), ""
end

local EMPTY = {
    nofight = { "No fights yet", "Bars fill in as soon as your group enters combat." },
    deaths = { "Nobody has died", "Deaths show here with what killed them." },
    kicks = { "No interrupts", "Nobody interrupted anything in this fight." },
    dispels = { "No dispels", "Nobody removed anything in this fight." },
    other = { "Nothing yet", "Nobody has done this in this fight." },
}

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

function MW:Draw()
    if not frame then return end
    dirty = false
    lastDraw = GetTime()
    local sel = Setting("seg", "cur")
    local mode = Setting("mode", "damage")
    if not Meter.MODE[mode] then mode = "damage" end
    local seg = Meter:GetSegment(sel)
    local m = Meter.MODE[mode]
    local dur = Meter:Duration(seg)

    -- header
    local h = frame.head
    h.modeIcon:SetTexture(m.icon)
    h.modeText:SetText(m.label)
    local live = seg and seg.live
    h.dot:SetShown(live and true or false)
    h.segText:SetText(seg and (live and "Current fight" or Meter:SegName(seg)) or "No fights yet")
    h.segTime:SetText(seg and K.Clock(dur) or "")
    self:LayoutHeader()

    -- total
    local rows, total = Meter:Rows(seg, mode)
    local l, v, s = TotalText(seg, mode, rows, total, dur)
    frame.totLabel:SetText(l)
    frame.totValue:SetText(seg and v or "0")
    frame.totSub:SetText(seg and s or "")

    -- rows
    local areaH = frame.rows:GetHeight() or 0
    if areaH <= 0 then areaH = (frame:GetHeight() or DEFAULT_H) - HEAD_H - TOT_H - INSET * 2 end
    local V = max(1, floor((areaH + ROW_GAP) / (ROW_H + ROW_GAP)))
    local order = {}
    local meIdx
    for i, r in ipairs(rows) do
        r.rank = i
        r.me = r.d == nil and IsMe(r.g) or (r.d ~= nil and IsMe(r.d.g))
        if r.me and not meIdx then meIdx = i end
        order[i] = r
    end
    if meIdx and meIdx > V and V >= 2 then
        local me = table.remove(order, meIdx)
        me.pinned = true
        table.insert(order, V, me)
    end
    local topV = 0
    for _, r in ipairs(rows) do topV = max(topV, r.v + (r.ext or 0)) end
    if mode == "active" then topV = dur end
    if topV <= 0 then topV = 1 end
    local rowW = (frame.rows:GetWidth() or 0)
    if rowW <= 0 then rowW = (frame:GetWidth() or DEFAULT_W) - INSET * 2 end

    local seen = {}
    local valueFn = VALUE[mode] or VALUE.damage
    for i, r in ipairs(order) do
        local key = r.d and ("d" .. tostring(r.d.t) .. tostring(r.d.g)) or r.g
        seen[key] = true
        local row, fresh = TakeRow(key)
        row.data = r
        local a = r.a
        local cr, cg, cb = K.ClassColor(a.c)
        row.fill:SetVertexColor(cr, cg, cb, 0.85)
        row.ext:SetVertexColor(cr, cg, cb, 0.3)
        K.SetPlayerIcon(row.icon, a.c, a.s)
        row.rank:SetText(r.rank)
        row.name:SetText(a.n or "?")
        row.name:SetAlpha((r.d == nil and seg and seg.deaths and Meter.IsDead and Meter:IsDead(seg, r.g)) and 0.7 or 1)
        local v1, v2 = valueFn(r, dur, seg)
        row.value:SetText(v1)
        row.sub:SetText(v2 or "")
        local kbKey = r.d and r.d.by or (mode == "kicks" and TopKey(a.ks)) or (mode == "dispels" and TopKey(a.ds)) or nil
        if kbKey then row.kb:SetTexture(K.SpellIcon(kbKey)) end
        PlaceRight(row, v2 ~= nil, kbKey ~= nil)
        local dead = r.d == nil and Meter.IsDead and Meter:IsDead(seg, r.g)
        row.skull:SetShown(dead and true or false)
        if dead then
            row.skull:ClearAllPoints()
            row.skull:SetPoint("LEFT", row.name, "LEFT", min(row.name:GetStringWidth() + 4, (row.name:GetWidth() or 100) + 2), 0)
        end
        row.you:SetShown(r.me and true or false)
        row.pinLine:SetShown(r.pinned and true or false)
        row.ty = -((i - 1) * (ROW_H + ROW_GAP))
        local fw = (mode == "deaths") and rowW or (r.v / topV * rowW)
        row.tw = max(1, fw)
        row.tew = (r.ext and r.ext > 0) and (r.ext / topV * rowW) or 0
        if fresh or not row.y then
            if frame.drawn and mode ~= "deaths" then
                row.y = -(V * (ROW_H + ROW_GAP))       -- a new player comes in from below
                row.w, row.ew = 0, 0
            else
                row.y, row.w, row.ew = row.ty, row.tw, row.tew
            end
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame.rows, "TOPLEFT", 0, row.y)
        row:SetPoint("RIGHT", frame.rows, "RIGHT", 0, 0)
        row.fill:SetWidth(max(1, row.w))
        row.ext:SetWidth(max(0.01, row.ew))
        row.ext:SetShown(row.ew > 0.5)
        row:Show()
    end
    for key, row in pairs(rowsByKey) do
        if not seen[key] then
            row:Hide()
            row.data = nil
            rowsByKey[key] = nil
            pool[#pool + 1] = row
        end
    end
    frame.drawn = true

    -- empty
    local empty
    if not seg then empty = EMPTY.nofight
    elseif #rows == 0 then empty = EMPTY[mode] or EMPTY.other end
    frame.emptyBig:SetShown(empty ~= nil)
    frame.emptySmall:SetShown(empty ~= nil)
    if empty then
        frame.emptyBig:SetText(empty[1])
        frame.emptySmall:SetText(empty[2])
    end
end

-- Bars glide (exponential ease) toward their targets.
local function Animate(elapsed)
    local k = 1 - exp(-elapsed / EASE)
    local moving = false
    for _, row in pairs(rowsByKey) do
        if row.ty then
            local dy, dw, de = row.ty - row.y, row.tw - row.w, row.tew - row.ew
            if abs(dy) > 0.3 or abs(dw) > 0.3 or abs(de) > 0.3 then
                row.y = row.y + dy * k
                row.w = row.w + dw * k
                row.ew = row.ew + de * k
                moving = true
            else
                row.y, row.w, row.ew = row.ty, row.tw, row.tew
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", frame.rows, "TOPLEFT", 0, row.y)
            row:SetPoint("RIGHT", frame.rows, "RIGHT", 0, 0)
            row.fill:SetWidth(max(1, row.w))
            row.ext:SetWidth(max(0.01, row.ew))
            row.ext:SetShown(row.ew > 0.5)
        end
    end
    return moving
end

-- The mode keeps its name; the fight's name gives way first (it shortens), and only in a very narrow window does
-- the mode drop to its icon.
function MW:LayoutHeader()
    local h = frame.head
    local W = frame:GetWidth() or DEFAULT_W
    local modeW = 6 + 16 + 6 + h.modeText:GetStringWidth() + 6 + 9 + 6
    local dotW = h.dot:IsShown() and 13 or 0
    local fixed = dotW + 6 + 5 + h.segTime:GetStringWidth() + 6 + 9 + 6        -- the fight button without its name
    local avail = W - 4 - 2 - 22 - 4
    local showLabel = avail - modeW - fixed >= 70
    h.modeText:SetShown(showLabel)
    h.mode:SetWidth(showLabel and modeW or (6 + 16 + 4 + 9 + 6))
    local nameRoom = max(30, avail - h.mode:GetWidth() - fixed)
    local nameW = min(h.segText:GetStringWidth() + 1, nameRoom)
    h.segText:SetWidth(nameW)
    h.seg:SetWidth(fixed + nameW)
    h.modeChev:ClearAllPoints()
    h.modeChev:SetPoint("LEFT", showLabel and h.modeText or h.modeIcon, "RIGHT", showLabel and 6 or 4, -1)
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

local function Build()
    frame = CreateFrame("Frame", "DisasterZoneMeter", UIParent)
    local size = Setting("msize")
    local w, h = DEFAULT_W, DEFAULT_H
    if type(size) == "table" then w, h = tonumber(size[1]) or w, tonumber(size[2]) or h end
    frame:SetSize(min(MAX_W, max(MIN_W, w)), min(MAX_H, max(MIN_H, h)))
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    K.SetResizeBounds(frame, MIN_W, MIN_H, MAX_W, MAX_H)
    frame:EnableMouse(true)
    K.RestorePlace(frame, "mpos", { "BOTTOMRIGHT", "BOTTOMRIGHT", -60, 200 })
    K.Panel(frame)

    -- header
    local head = CreateFrame("Button", nil, frame)
    head:SetPoint("TOPLEFT")
    head:SetPoint("TOPRIGHT")
    head:SetHeight(HEAD_H)
    head:RegisterForDrag("LeftButton")
    head:RegisterForClicks("RightButtonUp")
    head:SetScript("OnDragStart", function() if not Setting("locked", true) then frame:StartMoving() end end)
    head:SetScript("OnDragStop", function() frame:StopMovingOrSizing(); K.SavePlace(frame, "mpos") end)
    head:SetScript("OnClick", function(self, button) if button == "RightButton" then WindowMenu(self) end end)
    head.bg = head:CreateTexture(nil, "BACKGROUND", nil, -6)
    head.bg:SetAllPoints()
    K.Gradient(head.bg, "VERTICAL", { 0.09, 0.09, 0.11, 0.95 }, { 0.125, 0.125, 0.153, 0.95 })
    head.line = K.Tex(head, "BORDER", K.WHITE, 1, 1, 1, 0.06)
    head.line:SetPoint("BOTTOMLEFT")
    head.line:SetPoint("BOTTOMRIGHT")
    head.line:SetHeight(1)
    frame.head = head

    local mode = K.HeadButton(head)
    mode:SetPoint("LEFT", head, "LEFT", 4, 0)
    head.modeIcon = K.Tex(mode, "ARTWORK", 134400)
    head.modeIcon:SetSize(16, 16)
    head.modeIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    head.modeIcon:SetPoint("LEFT", mode, "LEFT", 6, 0)
    head.modeText = K.Font(mode, K.FRIZ, 13, K.GOLD)
    head.modeText:SetPoint("LEFT", head.modeIcon, "RIGHT", 6, 0)
    head.modeChev = K.Chevron(mode, 10, K.GOLD)
    mode:SetScript("OnClick", ModeMenu)
    head.mode = mode

    local more = K.HeadButton(head)
    more:SetSize(22, 22)
    more:SetPoint("RIGHT", head, "RIGHT", -4, 0)
    more.icon = more:CreateTexture(nil, "ARTWORK")
    K.Glyph(more.icon, "more")
    more.icon:SetSize(14, 14)
    more.icon:SetPoint("CENTER")
    more.icon:SetVertexColor(0.62, 0.6, 0.56)
    more:HookScript("OnEnter", function(self) self.icon:SetVertexColor(1, 1, 1) end)
    more:HookScript("OnLeave", function(self) self.icon:SetVertexColor(0.62, 0.6, 0.56) end)
    more:SetScript("OnClick", WindowMenu)
    head.more = more

    local seg = K.HeadButton(head)
    seg:SetPoint("RIGHT", more, "LEFT", -2, 0)
    head.dot = K.Tex(seg, "ARTWORK", K.DISC, 1, 0.27, 0.2, 1)
    head.dot:SetSize(7, 7)
    head.dot:SetPoint("LEFT", seg, "LEFT", 6, 0)
    head.segText = K.Font(seg, K.FRIZ, 13, K.INK)
    head.segTime = K.Font(seg, K.NARROW, 13, K.DIM)
    head.segChev = K.Chevron(seg, 10, K.DIM)
    head.segChev:SetPoint("RIGHT", seg, "RIGHT", -6, -1)
    head.segTime:SetPoint("RIGHT", head.segChev, "LEFT", -6, 1)
    head.segText:SetPoint("RIGHT", head.segTime, "LEFT", -5, 0)
    head.segText:SetJustifyH("RIGHT")
    seg:SetScript("OnClick", FightMenu)
    head.seg = seg

    -- total line
    local tot = CreateFrame("Frame", nil, frame)
    tot:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, 0)
    tot:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT", 0, 0)
    tot:SetHeight(TOT_H)
    frame.totLabel = K.Font(tot, K.FRIZ, 12, K.DIM)
    frame.totLabel:SetPoint("LEFT", tot, "LEFT", 8, 0)
    frame.totSub = K.Font(tot, K.NARROW, 13, K.DIM)
    frame.totSub:SetPoint("RIGHT", tot, "RIGHT", -9, 0)
    frame.totSub:SetJustifyH("RIGHT")
    frame.totValue = K.Font(tot, K.NARROW, 14, K.INK)
    frame.totValue:SetPoint("RIGHT", frame.totSub, "LEFT", -8, 0)
    local tl = K.Tex(tot, "BORDER", K.WHITE, 1, 1, 1, 0.04)
    tl:SetPoint("BOTTOMLEFT")
    tl:SetPoint("BOTTOMRIGHT")
    tl:SetHeight(1)
    frame.tot = tot

    -- the bars (clipped)
    local rows = CreateFrame("Frame", nil, frame)
    rows:SetPoint("TOPLEFT", tot, "BOTTOMLEFT", INSET, -INSET)
    rows:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -INSET, INSET)
    if rows.SetClipsChildren then rows:SetClipsChildren(true) end
    frame.rows = rows
    frame.emptyBig = K.Font(rows, K.FRIZ, 14, K.INK)
    frame.emptyBig:SetPoint("BOTTOM", rows, "CENTER", 0, 2)
    frame.emptySmall = K.Font(rows, K.FRIZ, 12, K.DIM)
    frame.emptySmall:SetPoint("TOP", rows, "CENTER", 0, -2)
    frame.emptySmall:SetWidth(DEFAULT_W - 40)
    frame.emptySmall:SetWordWrap(true)
    frame.emptySmall:SetJustifyH("CENTER")

    -- unlocked: a resize corner and a hint
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", -1, 1)
    grip:SetFrameLevel(frame:GetFrameLevel() + 10)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        K.SavePlace(frame, "mpos", "msize")
        MW:Draw()
    end)
    frame.grip = grip
    frame.hint = K.Font(frame, K.FRIZ, 12, K.GOLD)
    frame.hint:SetPoint("BOTTOM", frame, "TOP", 0, 4)
    frame.hint:SetText("Drag the header to move · the corner to resize")

    frame:SetScript("OnSizeChanged", function()
        frame.emptySmall:SetWidth(max(120, (frame:GetWidth() or DEFAULT_W) - 40))
        dirty = true
    end)
    frame:SetScript("OnUpdate", function(_, elapsed) MW:OnUpdate(elapsed) end)
    frame:Hide()
end

function MW:ApplyLock()
    if not frame then return end
    local locked = Setting("locked", true)
    frame.grip:SetShown(not locked)
    frame.hint:Hide()                                   -- (shown while the mouse is over an unlocked window)
    if locked then frame:SetEdge(1, 1, 1, 0.07) else frame:SetEdge(1, 0.82, 0, 0.55) end
    frame:SetScale(SCALES[Setting("size", "normal")] or 1)
end

function MW:OnUpdate(elapsed)
    frame.hint:SetShown(not Setting("locked", true) and frame:IsMouseOver())
    -- fade out of combat
    local fight = InCombat()
    if fight then combatEndedAt = GetTime() end
    local want = 1
    if not fight and Setting("ooc", "fade") == "fade" and Setting("locked", true)
        and GetTime() - combatEndedAt > FADE_AFTER and not frame:IsMouseOver() and not ns.UI:GetOpenMenu() then
        want = FADED
    end
    if abs(alpha - want) > 0.005 then
        alpha = alpha + (want - alpha) * (1 - exp(-elapsed / 0.25))
        frame:SetAlpha(alpha)
    end
    -- redraw: at most 4 times a second while numbers change
    local now = GetTime()
    if (dirty or (Meter:GetLive() and now - lastDraw > 0.25)) and now - lastDraw > 0.1 then self:Draw() end
    Animate(elapsed)
end

---------------------------------------------------------------------------
-- Showing
---------------------------------------------------------------------------

local function ShowWanted()
    if not Meter:IsEnabled() then return false end           -- (demo mode only fills a window that is on)
    if userHidden then return false end
    if not Setting("locked", true) then return true end
    if Meter:IsDemo() then return true end
    local show = Setting("show", "group")
    if show == "group" and not (IsInGroup and IsInGroup()) and not Meter:GetLive() then return false end
    if show == "instance" and not (IsInInstance and IsInInstance()) then return false end
    if Setting("ooc", "fade") == "hide" and not InCombat() then return false end
    return true
end

function MW:UpdateVisibility()
    local want = ShowWanted()
    if want and not frame then Build() end
    if not frame then return end
    if want then
        self:ApplyLock()
        if not frame:IsShown() then
            alpha = 1
            frame:SetAlpha(1)
            frame:Show()
        end
        dirty = true
    else
        frame:Hide()
    end
end

function MW:Toggle()
    if frame and frame:IsShown() then
        userHidden = true
    else
        userHidden = false
        if not Meter:IsEnabled() then
            ns:Print("the damage meter is off: turn it on in Settings > Meters (or /dz meter on).")
            return
        end
        if not frame then Build() end
        self:ApplyLock()
        frame:Show()
        dirty = true
        return
    end
    self:UpdateVisibility()
end

function MW:GetFrame() return frame end
function MW:Refresh() dirty = true; self:UpdateVisibility() end

function MW:OnLogin()
    Meter = ns.Meter
    Meter:OnChange(function(what)
        if what == "start" then
            if Setting("seg", "cur") ~= "all" then ns.DB:SetSetting("meters.seg", "cur") end
            combatEndedAt = GetTime()
            MW:UpdateVisibility()
        elseif what == "end" then
            combatEndedAt = GetTime()
            MW:UpdateVisibility()
        end
        dirty = true
    end)
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and path:sub(1, 7) == "meters." then MW:Refresh() end
    end)
    ns:On("DEMO_TOGGLED", function() if ns.MeterDemo then ns.MeterDemo:Reset() end MW:Refresh() end)
    for _, ev in ipairs({ "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
        ns:RegisterEvent(ev, function() MW:UpdateVisibility() end)
    end
    self:UpdateVisibility()
end

-- Test hooks
MW._Rows = function() return rowsByKey end

if DisasterZoneBoot and DisasterZoneBoot.Run("UI/LookCast.lua", ...) then return end -- DisasterZone UI/LookCast.lua
-- Cast bars in the addon's looks (UI/Look.lua part "cast"): replaced, as the mockup's looks need the whole bar (a
-- hairline for Slate, the latency end piece, a lock for a cast that can't be interrupted). Not secure: a cast bar is
-- only drawn. The game's bars (PlayerCastingBarFrame, the target's and the focus's spell bars) are retired at login
-- when the part has a look; left on Blizzard nothing is touched.
-- Bars: cast.player, cast.target, cast.focus (Core/Layout.lua items: Edit layout places them, previews show a made-up
-- cast). Options (ui.cast.*): latency (the end piece on my casts), time ("left" 0.6 | "both" 0.6 / 1.5 | "none"),
-- icon, target, focus (show those bars).
local addonName, ns = ...

local Cast = ns:NewModule("LookCast")
local UI = ns.UI

local floor, max, min = math.floor, math.max, math.min
local pairs, ipairs, type, tonumber = pairs, ipairs, type, tonumber
local strformat = string.format

local function Look() return ns.Look end

local BARS = {
    player = { unit = "player", name = "Your cast bar", w = 236, order = 8, default = { "BOTTOM", 0, 190 } },
    target = { unit = "target", name = "Target cast bar", w = 214, order = 9, default = { "TOPLEFT", 290, -100 } },
    focus = { unit = "focus", name = "Focus cast bar", w = 214, order = 10, default = { "LEFT", 290, 70 } },
}
local ORDER = { "player", "target", "focus" }
local GOLD = { 1, 0.82, 0 }
local GREY = { 0.55, 0.55, 0.55 }
local RED = { 0.85, 0.2, 0.15 }

local bars = {}
Cast.bars = bars

---------------------------------------------------------------------------
-- A bar
---------------------------------------------------------------------------

local function NewBar(key, parent, sample)
    local L = Look()
    local def = BARS[key]
    local f = CreateFrame("Frame", (not sample) and ("DisasterZoneCast_" .. key) or nil, parent or UIParent)
    f:SetFrameStrata("MEDIUM")
    f.key, f.unit = key, def.unit
    f.panel = L:Panel(f)
    f.icon = L:Icon(f)
    f.bar = L:Bar(f)
    f.bar.fixedW = true
    -- the moving end (Halo): a soft round glow in warm gold, added on, with a thin bright core at the edge
    f.spark = f.bar.f:CreateTexture(nil, "OVERLAY", nil, 4)
    f.spark:SetTexture("Interface\\AddOns\\DisasterZone\\Media\\SoftGlow")
    f.spark:SetBlendMode("ADD")
    f.spark:SetVertexColor(1, 0.86, 0.45, 0.95)
    f.core = L.Tex(f.bar.f, "OVERLAY", 5)
    f.core:SetVertexColor(1, 0.97, 0.85, 0.9)
    if f.core.SetBlendMode then f.core:SetBlendMode("ADD") end
    local over = CreateFrame("Frame", nil, f)
    over:SetAllPoints(f)
    over:SetFrameLevel(f:GetFrameLevel() + 5)
    f.name = L:Text(over, "body")
    f.time = L:Text(over, "small", "TEXT", { justify = "RIGHT" })
    f.lock = over:CreateTexture(nil, "OVERLAY")
    f.lock:SetTexture("Interface\\PetBattles\\PetBattle-LockIcon")
    f.lock:SetSize(10, 12)
    f.lock:Hide()
    f.studs = {}
    for i = 1, 2 do
        local s = L.Tex(over, "OVERLAY", 5)
        s:SetSize(6, 6)
        if s.SetRotation then s:SetRotation(math.pi / 4) end
        f.studs[i] = s
    end
    f:Hide()
    f:SetScript("OnUpdate", function(self, dt) Cast:Step(self, dt) end)
    if not sample then bars[key] = f end
    return f
end

-- A bar showing a made-up cast in a look, outside the live ones (the look tiles, the audit's gallery).
function Cast:Sample(parent, key, look)
    local f = NewBar(key, parent, true)
    self:Apply(f, look)
    f.preview = true
    self:Start(f, ({ player = { name = "Slam", icon = 132340, dur = 1.5, done = 0.9 },
        target = { name = "Arcane Orb", icon = 136096, dur = 3, done = 1.1, ni = true } })[key])
    f:SetScript("OnUpdate", nil)
    return f
end

-- Classic: the game's cast bar border (or the shield frame for a cast that can't be interrupted), its spark and the
-- flash when a cast lands, round our bar (the icon left of it, name left, time right, latency at the end). The fill
-- stays where it is between the two frames: the shield reaches out over the icon's place.
-- (the fill and its dark ground fill the border's whole inside: x 9..w-10, y 9..26; the border draws over its edge)
local CL = { h = 34, bx = 26, fx = 9, fr = 10, fy = 9, fh = 17 }
local function Classic(f)
    if f.cl then return f.cl end
    local L = Look()
    local cl = {}
    cl.over = CreateFrame("Frame", nil, f)
    cl.over:SetAllPoints(f)
    cl.over:SetFrameLevel(f:GetFrameLevel() + 4)
    cl.ground = L.Tex(f, "BACKGROUND", 0)
    cl.border = L:GameSlice3(cl.over, "cast", 12, 12, "ARTWORK", 1)
    cl.shield = L:GameSlice3(cl.over, "castShield", 50, 12, "ARTWORK", 1)
    cl.flash = L:GameSlice3(cl.over, "castFlash", 12, 12, "ARTWORK", 2)
    cl.flash:SetBlend("ADD")
    f.cl = cl
    return cl
end

function Cast:ApplyClassic(f, look, w)
    local L = Look()
    local cl = Classic(f)
    local iconOn = L:Opt("cast", "icon", true)
    f:SetSize(w, CL.h)
    f.panel:Apply(nil)
    for _, s in ipairs(f.studs) do s:Hide() end
    local bx = iconOn and CL.bx or 0
    cl.bx, cl.w, cl.iconOn = bx, w, iconOn
    cl.border:Place(f, bx, 0, w - bx, CL.h)
    -- (the shield's 50 px end holds its icon box: put it so the fill starts where the border's does)
    cl.shield:Place(f, bx + CL.fx - 44, CL.fy + CL.fh / 2 - 25.5, w - bx - CL.fx + 44, 48)
    cl.flash:Place(f, bx, 0, w - bx, CL.h)
    cl.flash:Show(false)
    local fw = w - bx - CL.fx - CL.fr
    cl.ground:ClearAllPoints()
    cl.ground:SetPoint("TOPLEFT", f, "TOPLEFT", bx + CL.fx, -CL.fy)
    cl.ground:SetSize(fw, CL.fh)
    L.Color(cl.ground, { 0, 0, 0, 0.6 })
    f.bar.trackC = { 0, 0, 0, 0 }           -- (the ground under the fill is cl.ground)
    f.bar:Apply(look, "gilt", CL.fh)
    f.bar.f:ClearAllPoints()
    f.bar.f:SetPoint("TOPLEFT", f, "TOPLEFT", bx + CL.fx, -CL.fy)
    f.bar:SetWidthNow(fw)
    f.bar.f:SetFrameLevel(f:GetFrameLevel() + 1)
    f.icon.f:ClearAllPoints()
    if iconOn then
        f.icon:Apply(look, "square")
        f.icon.f:SetFrameLevel(f:GetFrameLevel() + 2)
        f.icon.f:Show()
    else
        f.icon.f:Hide()
    end
    f.name:ClearAllPoints(); f.time:ClearAllPoints()
    UI:SetTextSize(f.name, "body")
    f.name:SetPoint("LEFT", f.bar.f, "LEFT", 5, 0)
    f.time:SetPoint("RIGHT", f.bar.f, "RIGHT", -5, 0)
    f.name:SetWidth(fw - 46)
    f.spark:SetTexture(Look().GAME.spark[1])
    f.spark:SetTexCoord(0, 1, 0, 1)
    f.spark:SetSize(32, CL.fh + 18)
    f.spark:SetShown(true)
    f.core:SetShown(false)
    f.look = look
    self:Paint(f)
end

-- The bar's face in a look.
function Cast:Apply(f, look)
    local L = Look()
    local def = BARS[f.key]
    local k = look.key
    local w = (ns.Layout and ns.Layout:Size("cast." .. f.key)) or def.w      -- (stretched in Edit layout)
    if look.game then return self:ApplyClassic(f, look, w) end
    if f.cl then
        f.cl.border:Show(false); f.cl.shield:Show(false); f.cl.flash:Show(false); f.cl.ground:Hide()
        f.bar.trackC = nil
        f.spark:SetTexture("Interface\\AddOns\\DisasterZone\\Media\\SoftGlow")
    end
    local iconOn = L:Opt("cast", "icon", true) and k ~= "slate"
    local h, ih, bh = 22, 20, 20
    if k == "halo" then h, ih, bh = 24, 24, 16
    elseif k == "sigil" then h, ih, bh = 22, 16, 16
    elseif k == "slate" then h, ih, bh = 24, 0, 3
    elseif k == "gilded" then h, ih, bh = 24, 18, 18 end
    if not iconOn then ih = 0 end
    f:SetSize(w, h)
    f.panel:Apply(k ~= "halo" and k ~= "slate" and look or nil)
    f.icon.f:ClearAllPoints()
    local x = 0
    if ih > 0 then
        f.icon:Apply(look, (k == "flat") and "square" or look.icon)
        f.icon.f:SetSize(ih, ih)
        local inset = (k == "flat") and 1 or ((k == "halo") and 0 or 3)
        f.icon.f:SetPoint("LEFT", f, "LEFT", inset, 0)
        f.icon.f:SetFrameLevel(f:GetFrameLevel() + ((k == "halo") and 3 or 1))
        f.icon.f:Show()
        x = ih + inset + ((k == "halo") and -12 or 2)
    else
        f.icon.f:Hide()
        x = (k == "slate") and 0 or 3
    end
    local bw = w - x - ((k == "slate") and 0 or 3)
    f.bar:Apply(look, nil, bh)
    f.bar.f:ClearAllPoints()
    if k == "slate" then f.bar.f:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, 3)
    else f.bar.f:SetPoint("LEFT", f, "LEFT", x, 0) end
    f.bar:SetWidthNow(bw)
    f.name:ClearAllPoints(); f.time:ClearAllPoints()
    UI:SetTextSize(f.name, (k == "sigil") and "caps" or "body")
    if k == "slate" then
        f.name:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        f.time:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    else
        f.name:SetPoint("LEFT", f.bar.f, "LEFT", (k == "halo") and 18 or 6, 0)
        f.time:SetPoint("RIGHT", f.bar.f, "RIGHT", (k == "halo") and -10 or -6, 0)
    end
    f.name:SetWidth(bw - 50)
    f.spark:SetShown(k == "halo")
    f.spark:SetSize(bh * 2.2, bh * 2.2)
    f.core:SetShown(false)          -- (a line inside the round end looked odd: the glow alone)
    f.core:SetSize(2, math.max(2, bh - 4))
    for i, s in ipairs(f.studs) do
        s:ClearAllPoints()
        if look.studs then
            L.Color(s, look.panel.corners)
            s:SetPoint("CENTER", f, i == 1 and "LEFT" or "RIGHT", i == 1 and -1 or 1, 0)
        else s:Hide() end
    end
    f.look = look
    self:Paint(f)
end

-- Classic's colours: the game's cast bar ones
local GAME_C = { cast = { 1, 0.7, 0 }, chan = { 0, 1, 0 }, done = { 0, 1, 0 }, fail = { 1, 0, 0 }, ni = { 0.7, 0.7, 0.7 } }

function Cast:PaintClassic(f)
    local cl = f.cl
    local c = f.failed and GAME_C.fail or f.done and GAME_C.done or f.ni and GAME_C.ni or f.chan and GAME_C.chan or GAME_C.cast
    f.bar:SetColor(c[1], c[2], c[3])
    f.lock:Hide()
    local ni = f.ni and true or false
    cl.border:Show(not ni)
    cl.shield:Show(ni)
    -- the icon: left of the border, or inside the shield's box
    f.icon.f:ClearAllPoints()
    if ni then
        f.icon.f:SetSize(18, 18)
        f.icon.f:SetPoint("TOPLEFT", f, "TOPLEFT", cl.bx + CL.fx - 44 + 14, -(CL.fy + CL.fh / 2 - 25.5 + 17))
        f.icon.f:Show()
    elseif cl.iconOn then
        f.icon.f:SetSize(20, 20)
        f.icon.f:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(CL.fy + CL.fh / 2 - 10))
        f.icon.f:Show()
    else
        f.icon.f:Hide()
    end
    f.spark:SetVertexColor(1, 1, 1, 0.9)
    f.spark:SetBlendMode("ADD")
end

function Cast:Paint(f)
    if f.look and f.look.game and f.cl then return self:PaintClassic(f) end
    local c = f.ni and GREY or (f.failed and RED or GOLD)
    if f.look and f.look.key == "slate" and not f.ni and not f.failed then c = GOLD end
    f.bar:SetColor(c[1], c[2], c[3])
    f.lock:ClearAllPoints()
    f.lock:SetPoint("RIGHT", f.name, "LEFT", -2, 0)
    f.lock:SetShown(f.ni and true or false)
    -- the glow takes the bar's colour, lighter (warm gold, or a pale grey for a cast that can't be interrupted)
    if f.spark then f.spark:SetVertexColor(math.min(1, c[1] + 0.25), math.min(1, c[2] + 0.2), math.min(1, c[3] + 0.3), 0.8) end
end

-- What a unit is casting: name, icon, start, end (seconds), channel, can't be interrupted.
local function Info(unit)
    if UnitCastingInfo then
        local name, _, icon, s, e, _, _, ni = UnitCastingInfo(unit)
        if name then return name, icon, s / 1000, e / 1000, false, ni end
    end
    if UnitChannelInfo then
        local name, _, icon, s, e, _, ni = UnitChannelInfo(unit)
        if name then return name, icon, s / 1000, e / 1000, true, ni end
    end
    return nil
end

-- Starts (or re-reads) a bar from the unit's cast; a made-up cast with fake = { name, icon, dur, done, ni }.
function Cast:Start(f, fake)
    local name, icon, s, e, chan, ni
    if fake then
        local now = GetTime and GetTime() or 0
        name, icon, s, e, chan, ni = fake.name, fake.icon, now - fake.done, now - fake.done + fake.dur, false, fake.ni
        f.fake = true
    else
        name, icon, s, e, chan, ni = Info(f.unit)
        f.fake = nil
    end
    if not name then return self:Stop(f) end
    f.s, f.e, f.chan, f.ni, f.failed, f.done = s, e, chan, ni and true or false, nil, nil
    f.fadeAt = nil
    f:SetAlpha(1)
    if f.cl then f.cl.flash:Show(false) end
    f.name:SetText((f.look and f.look.upper) and name:upper() or name)
    f.icon:SetTexture(icon)
    -- my casts: the time the server needs (world latency) as the end piece
    if f.unit == "player" and Look():Opt("cast", "latency", true) and not chan and GetNetStats then
        local _, _, _, world = GetNetStats()
        local dur = max(0.05, e - s)
        f.bar:SetEnd(min(0.5, (world or 0) / 1000 / dur), 0.9, 0.22, 0.16, 0.3)
    else
        f.bar:SetEnd(nil)
    end
    self:Paint(f)
    f:Show()
    self:Step(f, 0)
end

function Cast:Stop(f, failed)
    if not f:IsShown() then return end
    if failed then
        f.failed = true
        f.name:SetText(failed)
        f.bar:SetValue(1)
        self:Paint(f)
    elseif f.look and f.look.game and f.cl and not f.chan then
        -- (Classic: a cast that lands fills green and flashes, as the game's does)
        f.done = true
        f.bar:SetValue(1)
        self:Paint(f)
        f.cl.flash:Show(true)
        f.cl.flash:SetAlpha(1)
        f.spark:SetAlpha(0)
    end
    f.fadeAt = (GetTime and GetTime() or 0) + (failed and 0.6 or (f.done and 0.2 or 0.15))
end

function Cast:Step(f, dt)
    local now = GetTime and GetTime() or 0
    if f.fadeAt then
        local a = 1 - (now - f.fadeAt) / 0.3
        if now >= f.fadeAt then
            if a <= 0 then f:Hide(); f.fadeAt = nil; f.failed = nil; f.done = nil; f.fake = nil return end
            f:SetAlpha(a)
        end
        return
    end
    if not f.s or not f.e then return end
    local dur = max(0.001, f.e - f.s)
    local p = (now - f.s) / dur
    if f.fake and p >= 1 then f.s = now; p = 0 end            -- (a preview loops)
    p = max(0, min(1, p))
    f.bar:SetValue(f.chan and (1 - p) or p)
    local left = max(0, f.e - now)
    local tm = Look():Opt("cast", "time", "left")
    if tm == "none" then f.time:SetText("")
    elseif tm == "both" then f.time:SetText(strformat("%.1f / %.1f", left, dur))
    else f.time:SetText(strformat("%.1f", left)) end
    if f.spark:IsShown() and f.bar.w then
        -- (where the fill ends: past a pill's left cap, the fill runs on the track between the caps)
        local cap = (f.bar.kind == "pill") and math.floor((f.bar.h or 0) / 2) or 0
        -- (the visible end: past the fill's own round cap)
        local x = cap + (f.bar.w - 2 * cap) * (f.chan and (1 - p) or p) + cap * 0.45
        f.spark:ClearAllPoints()
        f.spark:SetPoint("CENTER", f.bar.f, "LEFT", x, 0)
        f.core:ClearAllPoints()
        f.core:SetPoint("CENTER", f.bar.f, "LEFT", x, 0)
        local show = p > 0.01 and p < 0.995
        f.spark:SetAlpha(show and 1 or 0)
        f.core:SetAlpha(show and 1 or 0)
    end
    if not f.fake and p >= 1 and not f.chan then self:Stop(f) end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function Wanted(key)
    if key == "player" then return true end
    return Look():Opt("cast", key, true) and true or false
end

local EVENTS = { "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_UPDATE",
    "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_INTERRUPTIBLE", "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
    "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED" }

local function OnEvent(_, event, unit)
    if event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_FOCUS_CHANGED" then
        local key = event == "PLAYER_TARGET_CHANGED" and "target" or "focus"
        local f = bars[key]
        if f and Wanted(key) then
            if Info(key) then Cast:Start(f) else f:Hide() end
        end
        return
    end
    for _, key in ipairs(ORDER) do
        local f = bars[key]
        if f and unit == f.unit and Wanted(key) and not f.preview then
            if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START"
                or event == "UNIT_SPELLCAST_DELAYED" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
                Cast:Start(f)
            elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
                Cast:Stop(f, "Interrupted")
            elseif event == "UNIT_SPELLCAST_FAILED" then
                if f:IsShown() and not Info(f.unit) then Cast:Stop(f, "Failed") end
            elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
                Cast:Stop(f)
            elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" or event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
                f.ni = event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE"
                Cast:Paint(f)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Setup, previews, the layout
---------------------------------------------------------------------------

local FAKE = {
    player = { name = "Slam", icon = 132340, dur = 1.5, done = 0.9 },
    target = { name = "Arcane Orb", icon = 136096, dur = 3, done = 1.1, ni = true },
    focus = { name = "Arcane Missiles", icon = 136096, dur = 5, done = 2 },
}

function Cast:Preview(key, on)
    local f = bars[key]
    if not f then return end
    if on then
        if f:IsShown() and not f.preview then return end
        f.preview = true
        self:Start(f, FAKE[key])
    elseif f.preview then
        f.preview = nil
        f:Hide()
    end
end

function Cast:Restyle()
    local look = Look():For("cast")
    for _, key in ipairs(ORDER) do
        local f = bars[key]
        if f then self:Apply(f, look) end
    end
end

local BLIZZ = { "PlayerCastingBarFrame", "CastingBarFrame", "TargetFrameSpellBar", "FocusFrameSpellBar" }

local pending = false
function Cast:Setup()
    local L = Look()
    L:SetApplied("cast", L:Key("cast"))
    if not L:IsOn("cast") then return end
    if InCombatLockdown and InCombatLockdown() then pending = true return end
    pending = false
    if bars.player then return end
    for _, name in ipairs(BLIZZ) do
        local f = _G[name]
        if f then L:Retire(f) end
        if ns.Layout and ns.Layout.Unregister then ns.Layout:Unregister("blizz:" .. name) end
    end
    for _, key in ipairs(ORDER) do NewBar(key) end
    local ev = CreateFrame("Frame")
    for _, e in ipairs(EVENTS) do pcall(ev.RegisterEvent, ev, e) end
    ev:SetScript("OnEvent", OnEvent)
    self:Restyle()
    if ns.Layout then
        for _, key in ipairs(ORDER) do
            local def = BARS[key]
            ns.Layout:Register("cast." .. key, { name = def.name, group = "Game frames", order = def.order,
                noHide = true, default = def.default, frame = function() return bars[key] end,
                stretch = { x = { 120, 640 }, apply = function() if bars[key] then Cast:Apply(bars[key], Look():For("cast")) end end },
                when = "while casting",
                mine = function() return Wanted(key) end,
                preview = function(on) Cast:Preview(key, on) end })
            ns.Layout:Place("cast." .. key)
        end
    end
end

function Cast:OnLogin()
    self:Setup()
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() if pending then Cast:Setup() end end)
    ns:On("UI_LOOK_CHANGED", function(part)
        if part == "cast" and not Look():NeedsReload("cast") then Cast:Restyle() end
    end)
end

function Cast:Bar(key) return bars[key] end

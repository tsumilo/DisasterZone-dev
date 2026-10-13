if DisasterZoneBoot and DisasterZoneBoot.Run("UI/LookUnits.lua", ...) then return end -- DisasterZone UI/LookUnits.lua
-- Unit, party and raid frames in the addon's looks (UI/Look.lua parts "units" and "group"): the game's frames are
-- replaced (their look can't be reached by restyling them), so these are our own, built to work every time:
--   * secure unit buttons (SecureUnitButtonTemplate: left click targets, right click opens the game's own unit menu
--     with "togglemenu"), shown and hidden by the game's unit watch; party and raid by the game's secure group headers
--     (every button made out of combat at login: nothing secure is touched in a fight);
--   * the face is apart from the unit: Face:Set(data) draws a plain table (name, class, health ...), filled from the unit
--     API for live frames and made up for previews (Edit layout, demo mode, Settings), so a solo player still sees
--     the party and raid frames to place them;
--   * the game's frames for a replaced part are retired at login (Look:Retire: no events, hidden, under a hidden
--     parent), never touched for a part left on Blizzard. Switching back needs a reload (Look:NeedsReload).
-- Kinds and their places (Core/Layout.lua items): uf.player, uf.target, uf.tot, uf.focus, uf.pet, group.party,
-- group.raid. Options (ui.units.* / ui.group.*): portrait (class | portrait | none), healthColor (theme: the look's,
-- green in Classic, class in the rest | class | green | gradient), healthText (both | pct | full | none), debuffs (all | mine | onlymine), timers, combo; group: player
-- (party shows me too), range (fade out of range), dispel (debuffs I can remove light the frame).
local addonName, ns = ...

local Units = ns:NewModule("LookUnits")
local UI, S = ns.UI, ns.Style

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local pairs, ipairs, type, tonumber, tostring, select = pairs, ipairs, type, tonumber, tostring, select
local strformat = string.format

local function Look() return ns.Look end
local function InCombat() return InCombatLockdown and InCombatLockdown() and true or false end

local UNITS = {
    player = { unit = "player", kind = "big", name = "Player", order = 1, side = "left", default = { "TOPLEFT", 30, -30 } },
    target = { unit = "target", kind = "big", name = "Target", order = 2, side = "right", auras = true, combo = true,
               default = { "TOPLEFT", 290, -30 } },
    tot = { unit = "targettarget", kind = "small", name = "Target of target", order = 3, default = { "TOPLEFT", 510, -40 } },
    focus = { unit = "focus", kind = "big", name = "Focus", order = 4, side = "right", auras = true,
              default = { "LEFT", 290, 120 } },
    pet = { unit = "pet", kind = "small", name = "Pet", order = 5, default = { "TOPLEFT", 30, -96 } },
}
Units.UNITS = UNITS
local ORDER = { "player", "target", "tot", "focus", "pet" }

-- sizes per kind: big (player, target, focus, party), small (target of target, pet), cell (raid)
local W = { big = 214, small = 104, party = 184, cell = 72 }
-- a raid cell's width and height per look (Halo's capsules are wider: a full name and the deficit fit inside)
local CELL = { halo = { 84, 32 }, slate = { 72, 30 }, classic = { 86, 36 } }
local function CellSize(look)
    local c = CELL[look and look.key]
    if c then return c[1], c[2] end
    return W.cell, 34
end
Units.CellSize = CellSize
-- Halo's cell: a near-opaque track (the ring round it shows only at its rim), the ring's resting colour
local HALO_TRACK = { 0.035, 0.035, 0.047, 0.9 }
local HALO_RIM = { 0, 0, 0, 0.85 }

---------------------------------------------------------------------------
-- Numbers and colours
---------------------------------------------------------------------------

local function Short(v)
    v = tonumber(v) or 0
    if v >= 1e6 then return strformat("%.2fM", v / 1e6) end
    if v >= 1e4 then return strformat("%.1fk", v / 1e3) end
    return tostring(floor(v + 0.5))
end
Units.Short = Short

local function Int(v)
    local s = tostring(floor((tonumber(v) or 0) + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- The health bar's colour for data d on part `part`.
local function HealthColor(part, d, look, kind)
    local mode = Look():Opt(part, "healthColor", "theme")
    look = look or Look():For(part)          -- (the face's own look: previews and the gallery wear one apart)
    if mode == "theme" then mode = (kind == "cell" and look.healthCell) or look.health or "class" end
    local frac = (d.hpMax and d.hpMax > 0) and (d.hp or 0) / d.hpMax or 0
    if mode == "green" then
        if d.offline or d.dead then return 0.45, 0.45, 0.45 end
        -- (Classic: the game's own pure green, darkened by its status bar texture)
        if look.game then return 0, 1, 0 end
        return 0.2, 0.8, 0.25
    end
    if mode == "gradient" then
        if frac > 0.5 then return (1 - frac) * 2, 0.85, 0.2 end
        return 1, frac * 2 * 0.85, 0.2
    end
    if d.offline or d.dead then return 0.45, 0.45, 0.45 end
    if d.isPlayer and d.class then return Look().ClassColor(d.class) end
    if d.tapped then return 0.55, 0.55, 0.55 end
    local r = d.reaction or 4
    local c = (r <= 3) and Look().HOSTILE or (r == 4 and Look().NEUTRAL or Look().FRIEND)
    return c[1], c[2], c[3]
end

-- (Classic: the game's own power colours)
local GAME_POWER = { [0] = { 0, 0, 1 }, [1] = { 1, 0, 0 }, [2] = { 1, 0.5, 0.25 }, [3] = { 1, 1, 0 } }
local function PowerColor(d, look)
    local c = (look and look.game and GAME_POWER[d.pt or 0]) or Look().POWER[d.pt or 0] or Look().POWER[0]
    return c[1], c[2], c[3]
end

---------------------------------------------------------------------------
-- Data: from the unit API, or made up
---------------------------------------------------------------------------

local function Aura(unit, i, filter)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local a = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
        if not a then return nil end
        return a.name, a.icon, a.applications, a.dispelName, a.duration, a.expirationTime, a.sourceUnit
    end
    if UnitAura then
        local name, icon, count, dtype, dur, exp, source = UnitAura(unit, i, filter)
        return name, icon, count, dtype, dur, exp, source
    end
    return nil
end
Units.Aura = Aura

local DISPEL_CLASS = { PRIEST = { Magic = true, Disease = true }, PALADIN = { Magic = true, Poison = true, Disease = true },
    SHAMAN = { Poison = true, Disease = true }, DRUID = { Curse = true, Poison = true }, MAGE = { Curse = true } }
local DEBUFF_COLOR = { Magic = { 0.2, 0.6, 1 }, Curse = { 0.6, 0, 1 }, Disease = { 0.6, 0.4, 0 }, Poison = { 0, 0.6, 0 } }
Units.DEBUFF_COLOR = DEBUFF_COLOR

function Units.Data(unit, d)
    d = d or {}
    for k in pairs(d) do d[k] = nil end
    if not (UnitExists and UnitExists(unit)) then return d end
    d.exists, d.unit = true, unit
    d.name = UnitName(unit)
    d.level = UnitLevel(unit)
    local _, class = UnitClass(unit)
    d.class = class
    d.isPlayer = UnitIsPlayer(unit) and true or false
    d.classif = UnitClassification and UnitClassification(unit)
    d.hp, d.hpMax = UnitHealth(unit) or 0, UnitHealthMax(unit) or 1
    d.pt = UnitPowerType and UnitPowerType(unit) or 0
    d.pw, d.pwMax = UnitPower(unit) or 0, UnitPowerMax(unit) or 0
    d.dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) or false
    d.ghost = UnitIsGhost and UnitIsGhost(unit) or false
    d.offline = d.isPlayer and UnitIsConnected and not UnitIsConnected(unit) or false
    d.reaction = UnitReaction and UnitReaction(unit, "player") or 4
    d.tapped = UnitIsTapDenied and not (UnitPlayerControlled and UnitPlayerControlled(unit)) and UnitIsTapDenied(unit) or false
    d.leader = UnitIsGroupLeader and UnitIsGroupLeader(unit) or false
    d.raidIcon = GetRaidTargetIndex and GetRaidTargetIndex(unit) or nil
    d.heal = UnitGetIncomingHeals and UnitGetIncomingHeals(unit) or nil
    if UnitInRange and (unit:find("^party") or unit:find("^raid")) then
        local inRange, checked = UnitInRange(unit)
        d.far = checked and not inRange or false
    end
    if UnitThreatSituation then d.threat = UnitThreatSituation(unit) end
    d.selected = UnitIsUnit and UnitExists("target") and UnitIsUnit(unit, "target") and true or false
    -- the first debuff I could remove (the group frames' light)
    local _, me = UnitClass("player")
    local can = DISPEL_CLASS[me]
    if can then
        for i = 1, 40 do
            local name, _, _, dtype = Aura(unit, i, "HARMFUL")
            if not name then break end
            if dtype and can[dtype] then d.dispel = dtype break end
        end
    end
    return d
end

-- The auras a frame shows: { { icon, count, dur, exp, mine, dtype } } (debuffs on hostile, buffs on friendly).
function Units.Auras(unit, part, out)
    out = out or {}
    for i = #out, 1, -1 do out[i] = nil end
    if not (UnitExists and UnitExists(unit)) then return out end
    local filter = (UnitIsFriend and UnitIsFriend("player", unit)) and "HELPFUL" or "HARMFUL"
    local mode = Look():Opt(part, "debuffs", "mine")
    local mine, other = {}, {}
    for i = 1, 40 do
        local name, icon, count, dtype, dur, exp, src = Aura(unit, i, filter)
        if not name then break end
        local isMine = src == "player" or src == "pet" or src == "vehicle"
        local a = { icon = icon, count = count, dur = dur, exp = exp, mine = isMine, dtype = dtype }
        if isMine then mine[#mine + 1] = a elseif mode ~= "onlymine" then other[#other + 1] = a end
    end
    if mode == "all" then
        for i = 1, 40 do
            local name, icon, count, dtype, dur, exp, src = Aura(unit, i, filter)
            if not name then break end
            out[#out + 1] = { icon = icon, count = count, dur = dur, exp = exp,
                              mine = src == "player" or src == "pet", dtype = dtype }
        end
    else
        for _, a in ipairs(mine) do out[#out + 1] = a end
        for _, a in ipairs(other) do out[#out + 1] = a end
    end
    return out
end

-- Made-up units: the mockup's moment (Tsumil on Void Reaver) and a demo party / raid.
local FAKE_RAID = {
    { "Victhar", "WARRIOR", 0.92 }, { "Moonwhisper", "DRUID", 1 }, { "Kaelthrin", "MAGE", 0.71 },
    { "Sylvaris", "HUNTER", 0.88 }, { "Brightmane", "PALADIN", 0.64 }, { "Dreadhex", "WARLOCK", 0.83 },
    { "Shadowmelder", "ROGUE", 0.4 }, { "Stormcall", "SHAMAN", 1 }, { "Lumina", "PRIEST", 0.97 },
    { "Quentrell", "HUNTER", 0.55 }, { "Ironbark", "WARRIOR", 0.77 }, { "Vexmora", "WARLOCK", 0 },
    { "Thalara", "PRIEST", 0.9 }, { "Gorm", "SHAMAN", 0.66 }, { "Feyra", "DRUID", 0.81 },
    { "Ashlen", "MAGE", 1 }, { "Torvald", "PALADIN", 0.73 }, { "Nyx", "ROGUE", 0.95 },
    { "Brannoc", "WARRIOR", 0.61 }, { "Seliora", "PRIEST", 1 }, { "Kragg", "SHAMAN", 0.86 },
    { "Elowen", "DRUID", 0.79 }, { "Marwyn", "MAGE", 0.5 }, { "Ravik", "HUNTER", 1 }, { "Oswin", "PALADIN", 0.9 },
}
function Units.Fake(key, i)
    if key == "target" then
        return { exists = true, name = "Void Reaver", level = -1, classif = "worldboss", hp = 2712400, hpMax = 4375000,
                 pt = 0, pw = 1, pwMax = 1, reaction = 2, isPlayer = false, combo = 3,
                 portrait = "Interface\\Icons\\Spell_Shadow_SummonVoidWalker",
                 auras = { { icon = 132354, count = 5, dur = 30, exp = (GetTime and GetTime() or 0) + 27, mine = true },
                           { icon = 136105, dur = 30, exp = (GetTime and GetTime() or 0) + 22, mine = true },
                           { icon = 135970, dur = 20, exp = (GetTime and GetTime() or 0) + 14 } } }
    elseif key == "tot" then
        return { exists = true, name = "Victhar", class = "WARRIOR", isPlayer = true, level = 70, hp = 15400, hpMax = 16700 }
    elseif key == "focus" then
        return { exists = true, name = "Astromancer", level = 70, classif = "elite", hp = 41000, hpMax = 62000, pt = 0,
                 portrait = "Interface\\Icons\\Spell_Fire_SoulBurn",
                 pw = 18000, pwMax = 25000, reaction = 2, isPlayer = false }
    elseif key == "pet" then
        return { exists = true, name = "Grimtooth", level = 69, hp = 5200, hpMax = 6100, pt = 2, pw = 70, pwMax = 100,
                 portrait = "Interface\\Icons\\Ability_Hunter_Pet_Wolf",
                 reaction = 5, isPlayer = false }
    elseif key == "member" then
        local m = FAKE_RAID[((i or 1) - 1) % #FAKE_RAID + 1]
        local max = 9000 + ((i or 1) * 371) % 6000
        return { exists = true, name = m[1], class = m[2], isPlayer = true, level = 70, hp = floor(max * m[3]),
                 hpMax = max, pt = (m[2] == "WARRIOR") and 1 or ((m[2] == "ROGUE") and 3 or 0), pw = 60, pwMax = 100,
                 dead = m[3] == 0, leader = i == 1, dispel = (i == 3) and "Magic" or nil, far = (i == 7) }
    end
    local _, class = UnitClass and UnitClass("player")
    return { exists = true, name = UnitName and UnitName("player") or "Tsumil", class = class or "WARRIOR",
             isPlayer = true, level = UnitLevel and UnitLevel("player") or 70, hp = 14212, hpMax = 16840,
             pt = 1, pw = 45, pwMax = 100, leader = true }
end

---------------------------------------------------------------------------
-- The face: one drawing for every kind, look and source
---------------------------------------------------------------------------

local Face = {}
Face.__index = Face

-- kind: big | small | cell; part: "units" | "group"; side: "left" | "right" (the portrait's).
function Units:NewFace(host, kind, part, side)
    local L = Look()
    local F = setmetatable({ host = host, kind = kind, part = part, side = side or "left" }, Face)
    F.panel = L:Panel(host)
    F.head = L.Tex(host, "BORDER", 0)
    F.headLine = L.Tex(host, "BORDER", 3)
    F.portrait = L:Icon(host)
    F.model = nil
    F.hp = L:Bar(host)
    F.pp = L:Bar(host)
    F.heal = L.Tex(F.hp.f, "ARTWORK", 0)
    F.heal:SetVertexColor(0.3, 1, 0.4, 0.35)
    F.healCap = L.Tex(F.hp.f, "ARTWORK", 0, L.DISC)  -- (a pill's heal ends round, past the fill's round end)
    F.healCap:SetTexCoord(0.5, 1, 0, 1)
    F.healCap:SetVertexColor(0.3, 1, 0.4, 0.35)
    local over = CreateFrame("Frame", nil, host)
    over:SetAllPoints(host)
    over:SetFrameLevel(host:GetFrameLevel() + 6)
    F.over = over
    F.name = L:Text(over, kind == "cell" and "small" or "body")
    F.level = L:Text(over, "small", "GOLD")
    F.value = L:Text(over, "small", "TEXT", { justify = "RIGHT" })
    F.status = L:Text(over, "small", "SUB", { justify = "CENTER" })
    F.icon = over:CreateTexture(nil, "OVERLAY")
    F.icon:SetSize(14, 14)
    F.icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    F.leader = over:CreateTexture(nil, "OVERLAY")
    F.leader:SetSize(12, 12)
    F.leader:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
    F.skull = over:CreateTexture(nil, "OVERLAY")
    F.skull:SetSize(11, 11)
    F.skull:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
    F.light = L.Edges(over, "OVERLAY", 4)           -- a debuff I can remove / aggro: the frame's edge lights
    F.light:Place(host, 1)
    F.ring = L.PillRing(host, "BACKGROUND", -7)     -- (Halo's cell: a ring round the capsule lights instead)
    F.glow = L.PillRing(host, "BACKGROUND", -8)
    F.auras = {}
    F.pips = {}
    return F
end

---------------------------------------------------------------------------
-- Classic: the game's own frames, sized to ours (Look.GAME; mockup claude.ai/artifact/3MHRTnR18XaYMLqYj5cuHx)
--   big    the target frame: its rails stretched to RAIL_W, its ring whole (the gold dragon for elites and bosses,
--          the silver one for rares); the player's mirrored, the ring on the left. Name in the top band (the target's
--          on its reaction colour, as the game paints it), numbers in the bars, the level in the ring's small circle.
--   party  the party frame: ring and short rails, the name over them.
--   small  the target of target's frame (target of target, pet).
--   cell   the raid frames' own cell: its ground, the textured fill, the yellow frame round your target.
---------------------------------------------------------------------------

local RAIL_W = 150
-- the target frame's rails (from their top): inside x 4..w-7, y 5..45 (a dark ground fills all of it, as the game's
-- own frame has: nothing of the world shows through); the name band 5..22, health 23..35 and power 35..45 meet under
-- the straight lines between them, never past the rounded outer corners.
local TF = { band = { 5, 17 }, hp = { 23, 12 }, pp = { 35, 10 }, inL = 4, inR = 7, ground = { 4, 5, 7, 45 } }
-- per kind: host w, h; the ring's piece, place and size; the rails' piece, ends, place, size; inside bars; portrait
local CLASSIC = {
    big = { w = RAIL_W - 7 + 77, h = 80, ring = "tf_ring", rx = RAIL_W - 7, ry = 0, rw = 77, rh = 80,
            rails = "tf_bars", ends = { 5, 8 }, bx = 0, by = 14, bw = RAIL_W, bh = 50,
            port = { RAIL_W - 7 + 37, 39, 30 }, level = { RAIL_W - 7 + 60, 62 } },
    party = { w = 184, h = 56, ring = "party_ring", rx = 0, ry = 8, rw = 48, rh = 48,
              rails = "party_bars", ends = { 4, 6 }, bx = 44, by = 10, bw = 140, bh = 30,
              hp = { 3, 8, 6 }, pp = { 3, 14, 7 }, inR = 8, ground = { 3, 8, 8, 21 }, port = { 24, 32, 18 } },
    small = { w = 112, h = 54, ring = "tot_ring", rx = 0, ry = 6, rw = 46, rh = 48,
              rails = "tot_bars", ends = { 4, 6 }, bx = 42, by = 14, bw = 70, bh = 28,
              hp = { 3, 7, 6 }, pp = { 3, 13, 7 }, inR = 6, ground = { 3, 7, 6, 20 }, port = { 23, 29, 17 } },
}
Units.CLASSIC = CLASSIC
-- the name band's colour (the game's selection colours)
local function BandColor(d)
    if d.isPlayer then
        if (d.reaction or 4) <= 3 then return 0.8, 0, 0 end
        return 0, 0, 0.8
    end
    if d.tapped then return 0.5, 0.5, 0.5 end
    local r = d.reaction or 4
    if r <= 3 then return 0.8, 0, 0 elseif r == 4 then return 0.85, 0.75, 0 end
    return 0, 0.8, 0
end

function Face:ClassicParts()
    if self.cl then return self.cl end
    local L = Look()
    local host = self.host
    local cl = {}
    cl.art = CreateFrame("Frame", nil, host)
    cl.art:SetAllPoints(host)
    cl.art:SetFrameLevel(host:GetFrameLevel() + 3)
    cl.ring = cl.art:CreateTexture(nil, "ARTWORK", nil, 1)
    cl.nbg = L.Tex(host, "BORDER", 1)
    cl.ground = L.Tex(host, "BACKGROUND", -5)
    cl.sel = cl.art:CreateTexture(nil, "OVERLAY", nil, 2)
    Look():GameTex(cl.sel, "raidSelected")
    cl.sel:SetPoint("TOPLEFT", host, "TOPLEFT", -1, 1)
    cl.sel:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 1, -1)
    cl.sel:Hide()
    cl.ptext = L:Text(self.over, "small", "TEXT", { justify = "CENTER" })
    cl.ptext:Hide()
    self.cl = cl
    return cl
end

function Face:ClassicOff()
    local cl = self.cl
    if not cl then return end
    cl.art:Hide(); cl.nbg:Hide(); cl.ground:Hide(); cl.sel:Hide(); cl.ptext:Hide()
    if cl.rails then cl.rails:Show(false) end
    self.ckind = nil
end

-- the ring's piece for a unit's classification (big frames)
local function RingFor(d)
    local c = d and d.classif
    if c == "worldboss" or c == "elite" or (d and (d.level or 0) < 0) then return "tfe_ring", "tfe_bars" end
    if c == "rareelite" then return "tfre_ring", "tfe_bars" end
    if c == "rare" then return "tfr_ring", "tf_bars" end
    return "tf_ring", "tf_bars"
end

function Face:PlaceRing(key, railsKey)
    local cl, c = self.cl, CLASSIC[self.ckind]
    if not c then return end
    local L = Look()
    local mir = self.mirror
    local w, h = c.rw, c.rh
    local y = c.ry
    -- (the dragon rings are cut 4 px higher and reach further right and down: the ring itself stays put)
    if key ~= c.ring and self.ckind == "big" then w, h, y = 113, 104, c.ry - 4 end
    L:GameTex(cl.ring, key)
    if mir then
        local p = L.GAME[key]
        cl.ring:SetTexCoord(p[6] / p[2], p[4] / p[2], p[5] / p[3], p[7] / p[3])
    end
    cl.ring:ClearAllPoints()
    cl.ring:SetSize(w, h)
    local x = mir and (c.w - c.rx - w) or c.rx
    cl.ring:SetPoint("TOPLEFT", self.host, "TOPLEFT", x, -y)
    if railsKey and cl.rails and cl.rails.key ~= railsKey then
        cl.rails.key = railsKey
        for _, t in ipairs(cl.rails.t) do t:SetTexture(L.GAME[railsKey][1]) end
        cl.rails:Place(self.host, mir and (c.w - c.bx - c.bw) or c.bx, c.by, c.bw, c.bh)
    end
    self.ringKey = key
end

function Face:ApplyClassic(look)
    local L = Look()
    local host, kind = self.host, self.kind
    local cl = self:ClassicParts()
    local ckind = kind == "cell" and "cell" or ((kind == "big" and self.width == W.party) and "party" or kind)
    self.ckind = ckind
    self.panel:Apply(nil)
    self.head:Hide(); self.headLine:Hide()
    self.ringOn, self.lit, self.marks = false, nil, nil
    self.ring:Paint(nil); self.glow:Paint(nil)
    self.hp.trackC, self.hp.fadeFrom = nil, nil
    local name, value, level, status = self.name, self.value, self.level, self.status
    for _, r in ipairs({ name, value, level, status, cl.ptext }) do r:ClearAllPoints() end
    self.fit, self.fitW = nil, nil
    cl.art:Show()
    local function At(r, x, y) r:SetPoint("TOPLEFT", host, "TOPLEFT", x, -y) end
    local function Bar(bar, x, y, w2, h2)
        bar.fixedW = true
        bar:Apply(look, "gilt", h2)
        bar.f:ClearAllPoints()
        At(bar.f, x, y)
        bar:SetWidthNow(w2)
        bar.f:Show()
    end
    if ckind == "cell" then
        local w, h = CellSize(look)
        if not (host.IsProtected and host:IsProtected() and InCombat()) then host:SetSize(w, h) end
        self.h = h
        if cl.rails then cl.rails:Show(false) end
        cl.ring:Hide(); cl.nbg:Hide(); cl.ptext:Hide()
        L:GameTex(cl.ground, "raidBg")
        cl.ground:SetVertexColor(1, 1, 1, 1)
        cl.ground:ClearAllPoints(); cl.ground:SetAllPoints(host); cl.ground:Show()
        self.portrait.f:Hide()
        self.portOn = false
        Bar(self.hp, 1, 1, w - 2, h - 2)
        self.hp.fill:SetTexture(L.GAME.raidFill[1])
        self.pp.f:Hide()
        UI:SetTextSize(name, "small")
        name:SetPoint("TOPLEFT", host, "TOPLEFT", 4, -4)
        self.nameW = w - 8
        name:SetWidth(self.nameW)
        status:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -4, 4)
        value:Hide(); level:Hide()
        self.icon:ClearAllPoints(); self.icon:SetSize(14, 14); self.icon:SetPoint("CENTER", host, "TOP", 0, 0)
        self.leader:ClearAllPoints(); self.leader:SetPoint("CENTER", host, "TOPLEFT", 4, 0)
        if self.d then self:Set(self.d) end
        return
    end
    cl.sel:Hide()
    local c = CLASSIC[ckind]
    local mir = ckind == "big" and self.side ~= "right"           -- (the player's frame: the ring on the left)
    self.mirror = mir
    local W0 = c.w
    if not (host.IsProtected and host:IsProtected() and InCombat()) then host:SetSize(W0, c.h) end
    self.h = c.h
    local function X(x, w2) return mir and (W0 - x - w2) or x end
    if not cl.rails then cl.rails = L:GameSlice3(cl.art, c.rails, c.ends[1], c.ends[2], "ARTWORK", 0) end
    cl.rails.key = nil                                             -- (placed by PlaceRing below)
    cl.rails.l, cl.rails.r = c.ends[1], c.ends[2]
    cl.rails:SetFlipX(mir)
    cl.rails:Show(true)
    cl.ring:Show()
    self:PlaceRing(c.ring, c.rails)
    -- the bars inside the rails
    local hx, hy, hh, px, py, ph, iw
    if ckind == "big" then
        iw = c.bw - TF.inL - TF.inR
        hx, hy, hh = c.bx + TF.inL, c.by + TF.hp[1], TF.hp[2]
        px, py, ph = hx, c.by + TF.pp[1], TF.pp[2]
    else
        iw = c.bw - c.hp[1] - c.inR
        hx, hy, hh = c.bx + c.hp[1], c.by + c.hp[2], c.hp[3]
        px, py, ph = c.bx + c.pp[1], c.by + c.pp[2], c.pp[3]
    end
    Bar(self.hp, X(hx, iw), hy, iw, hh)
    Bar(self.pp, X(px, iw), py, iw, ph)
    -- (the dark inside of the rails: x0, y0 from the rails' top left, right inset, bottom)
    local gr = (ckind == "big") and TF.ground or c.ground
    local gw = c.bw - gr[1] - gr[3]
    cl.ground:SetTexture(L.WHITE)
    cl.ground:SetTexCoord(0, 1, 0, 1)
    cl.ground:SetVertexColor(0, 0, 0, 0.6)
    cl.ground:ClearAllPoints()
    At(cl.ground, X(c.bx + gr[1], gw), c.by + gr[2])
    cl.ground:SetSize(gw, gr[4] - gr[2])
    cl.ground:Show()
    -- the portrait: round, under the ring
    local pc = c.port
    self.portOn = L:Opt(self.part, "portrait", "class") ~= "none"
    self.portrait.f:ClearAllPoints()
    if self.portOn then
        self.portrait:Apply(look, "round")
        self.portrait.ring:Hide(); self.portrait.ringIn:Hide()
        self.portrait.f:SetSize(2 * pc[3], 2 * pc[3])
        At(self.portrait.f, X(pc[1] - pc[3], 2 * pc[3]), pc[2] - pc[3])
        self.portrait.f:SetFrameLevel(host:GetFrameLevel() + 1)
        self.portrait.f:Show()
    else
        self.portrait.f:Hide()
    end
    -- the words
    if ckind == "big" then
        local bx = X(c.bx + TF.inL, iw)
        cl.nbg:ClearAllPoints()
        At(cl.nbg, bx, c.by + TF.band[1])
        cl.nbg:SetSize(iw, TF.band[2])
        UI:SetTextSize(name, "body")
        name:SetPoint("LEFT", host, "TOPLEFT", bx + 5, -(c.by + TF.band[1] + TF.band[2] / 2))
        self.fit = { room = iw - 10 }
        UI:SetTextSize(value, "small")
        value:SetPoint("CENTER", host, "TOPLEFT", bx + iw / 2, -(hy + hh / 2))
        cl.ptext:SetPoint("CENTER", host, "TOPLEFT", bx + iw / 2, -(py + ph / 2))
        UI:SetTextSize(cl.ptext, "small")
        level:SetPoint("CENTER", host, "TOPLEFT", X(c.level[1] - 11, 22) + 11, -c.level[2])
        level:SetJustifyH("CENTER")
        level:Show()
        status:SetPoint("CENTER", host, "TOPLEFT", bx + iw / 2, -(hy + hh / 2))
        self.leader:ClearAllPoints()
        self.leader:SetPoint("CENTER", host, "TOPLEFT", X(c.rx + 10, 0), -4)
        self.icon:ClearAllPoints(); self.icon:SetSize(16, 16)
        self.icon:SetPoint("CENTER", host, "TOPLEFT", X(c.port[1], 0), -2)
    else
        -- party / small: the name over the rails, the numbers at the end of its row
        cl.nbg:Hide()
        UI:SetTextSize(name, "small")
        name:SetPoint("BOTTOMLEFT", host, "TOPLEFT", c.bx + 3, -(c.by - 1))
        UI:SetTextSize(value, "small")
        value:SetPoint("BOTTOMRIGHT", host, "TOPLEFT", c.bx + c.bw - c.inR, -(c.by - 1))
        self.fit = { room = iw, value = ckind == "party" }
        level:Hide()
        cl.ptext:Hide()
        status:SetPoint("BOTTOMRIGHT", host, "TOPLEFT", c.bx + c.bw - c.inR, -(c.by - 1))
        self.leader:ClearAllPoints()
        self.leader:SetPoint("CENTER", host, "TOPLEFT", c.rx + 8, -(c.ry + 2))
        self.icon:ClearAllPoints(); self.icon:SetSize(14, 14)
        self.icon:SetPoint("CENTER", host, "TOPLEFT", c.port[1], -(c.ry))
    end
    value:SetShown(ckind ~= "small")
    if self.fit then self:FitName() end
    if self.d then self:Set(self.d) end
end

-- What Set draws that only Classic has: the ring by classification, the name band's colour, the power numbers,
-- the raid cell's frame round your target.
function Face:SetClassic(d)
    local cl = self.cl
    if self.ckind == "cell" then
        cl.sel:SetShown(d.selected and true or false)
        self.name:SetTextColor(1, 1, 1)
        if d.dead or d.offline then self.name:SetTextColor(0.5, 0.5, 0.5) end
        return
    end
    if self.ckind == "big" then
        local ring, rails = RingFor(d)
        if ring ~= self.ringKey then self:PlaceRing(ring, rails) end
        if self.mirror then cl.nbg:Hide()
        else
            local r, g, b = BandColor(d)
            cl.nbg:SetVertexColor(r, g, b, 0.85)
            cl.nbg:Show()
        end
        local txt = ""
        if (d.pwMax or 0) > 1 and not d.dead and not d.offline then
            txt = Short(d.pw) .. " / " .. Short(d.pwMax)
        end
        cl.ptext:SetText(txt)
        cl.ptext:SetShown(txt ~= "")
        self.level:SetTextColor(1, 0.82, 0)
    end
    self.name:SetTextColor(1, 0.82, 0)
    -- (the portrait's own ring only shows lit: a debuff to remove, aggro)
    local lit = (d.dispel and Look():Opt("group", "dispel", true)) or (d.threat and d.threat >= 2 and self.kind ~= "big")
    if not lit then self.portrait.ring:Hide(); self.portrait.ringIn:Hide() end
end

-- Lays the face out in a look (its sizes are the look's, from the mockup).
function Face:Apply(look)
    self.look = look
    if look.game then return self:ApplyClassic(look) end
    self:ClassicOff()
    local L = Look()
    local host, kind, k = self.host, self.kind, look.key
    local left = self.side ~= "right"
    local w = self.width or W[kind] or 214
    local cellH
    if kind == "cell" then w, cellH = CellSize(look) end
    local portOn = kind == "big" and look.icon ~= "none" and L:Opt(self.part, "portrait", "class") ~= "none"
    self.portOn = portOn
    self.panel:Apply(look)
    self.head:Hide(); self.headLine:Hide()
    local ph, top, hpH, ppH, gap, nameIn = 0, 0, 0, 0, 0, false
    -- per look and kind: frame height h, portrait size ph, the bars' heights and the name row
    local h
    if kind == "cell" then
        h = cellH
    elseif kind == "small" then
        h = (k == "slate") and 24 or ((k == "flat") and 20 or 24)
    elseif k == "flat" then h, ph, hpH, ppH, nameIn = 42, 40, 28, 12, true
    elseif k == "halo" then h, ph, hpH, ppH = 46, 42, 16, 4
    elseif k == "sigil" then h, ph, hpH, ppH = 46, 44, 17, 5
    elseif k == "slate" then h, ph, hpH, ppH = 38, 0, 3, 1
    else h, ph, hpH, ppH = 48, 46, 17, 6 end
    if not portOn then ph = 0 end
    -- (a secure button is sized out of combat only; the look is re-applied after the fight)
    if not (host.IsProtected and host:IsProtected() and InCombat()) then host:SetSize(w, h) end
    self.h = h
    local bx, bw                                       -- the bars' left and width
    -- the portrait
    self.portrait.f:ClearAllPoints()
    if ph > 0 then
        self.portrait:Apply(look, look.icon == "none" and "square" or look.icon)
        self.portrait.f:SetSize(ph, ph)
        local inset = (k == "flat") and 1 or (k == "halo" and 2 or 1)
        if left then self.portrait.f:SetPoint("LEFT", host, "LEFT", inset, 0)
        else self.portrait.f:SetPoint("RIGHT", host, "RIGHT", -inset, 0) end
        self.portrait.f:SetFrameLevel(host:GetFrameLevel() + ((k == "halo") and 4 or 1))
        self.portrait.f:Show()
    else
        self.portrait.f:Hide()
    end
    local overlap = (k == "halo") and 14 or 0
    bx = (ph > 0) and (ph + 2 - overlap) or 0
    bw = w - bx
    self.hp.trackC, self.hp.fadeFrom = nil, nil
    self.ringOn, self.lit, self.marks = false, nil, nil
    self.ring:Paint(nil); self.glow:Paint(nil)
    local function Bars(x, w2, yHp, yPp)
        self.hp.fixedW = true
        self.pp.fixedW = true
        self.hp:Apply(look, nil, hpH)
        self.hp.f:ClearAllPoints()
        self.hp.f:SetPoint("TOPLEFT", host, "TOPLEFT", left and x or (w - x - w2), yHp)
        self.hp:SetWidthNow(w2)
        if ppH > 0 then
            self.pp:Apply(look, nil, ppH)
            self.pp.f:ClearAllPoints()
            self.pp.f:SetPoint("TOPLEFT", host, "TOPLEFT", left and x or (w - x - w2), yPp)
            self.pp:SetWidthNow(w2)
            self.pp.f:Show()
        else
            self.pp.f:Hide()
        end
    end
    local name, value, level = self.name, self.value, self.level
    name:ClearAllPoints(); value:ClearAllPoints(); level:ClearAllPoints()
    -- fit: the name's row (room, from the level's start), whether the level and the numbers share it (sized in Set)
    self.fit, self.fitW = nil, nil
    self.status:ClearAllPoints()
    UI:SetTextSize(name, kind == "cell" and "small" or (k == "slate" and "emph" or "body"))
    UI:SetTextSize(value, (k == "slate" and kind == "big") and "emph" or "small")
    if kind == "cell" then
        ppH = 0
        self.nameW = w - 10
        if k == "slate" then
            hpH = 3
            Bars(4, w - 8, -h + 7, 0)
            name:SetPoint("TOPLEFT", host, "TOPLEFT", 5, -5)
        elseif k == "halo" then
            -- one capsule as tall as the cell: the name and under it the deficit (or Dead) over the fill's dark,
            -- faded start, readable on any class colour; the ring round it lights (Set)
            hpH = h
            self.hp.trackC, self.hp.fadeFrom = HALO_TRACK, 0.3
            Bars(0, w, 0, 0)
            name:SetPoint("TOPLEFT", host, "TOPLEFT", 10, -5)
            self.nameW = w - 20
            self.ringOn = true
            self.ring:Place(self.hp.f, w, h, 1)
            self.ring:Paint(HALO_RIM)
        else
            hpH = h - ((k == "flat") and 2 or 6)
            local inset = (k == "flat") and 1 or 3
            Bars(inset, w - 2 * inset, -inset, 0)
            name:SetPoint("TOPLEFT", self.hp.f, "TOPLEFT", 4, -4)
        end
        name:SetWidth(self.nameW)
        if k == "halo" then self.status:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 10, 5)
        else self.status:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -4, 4) end
        value:Hide()
        level:Hide()
    elseif kind == "small" then
        ppH = 0
        if k == "slate" then
            hpH = 2
            Bars(6, w - 12, -h + 6, 0)
            name:SetPoint("TOPLEFT", host, "TOPLEFT", 6, -4)
            value:SetPoint("TOPRIGHT", host, "TOPRIGHT", -6, -4)
        elseif k == "halo" then
            hpH = 8
            Bars(0, w, -14, 0)
            name:SetPoint("TOPLEFT", host, "TOPLEFT", 6, -1)
            value:SetPoint("TOPRIGHT", host, "TOPRIGHT", -4, -1)
        else
            hpH = (k == "flat") and (h - 2) or 9
            local y = (k == "flat") and -1 or -(h - hpH - 3)
            Bars(1, w - 2, y, 0)
            if k == "flat" then
                name:SetPoint("LEFT", self.hp.f, "LEFT", 4, 0)
                value:SetPoint("RIGHT", self.hp.f, "RIGHT", -4, 0)
            else
                name:SetPoint("TOPLEFT", host, "TOPLEFT", 4, -2)
                value:SetPoint("TOPRIGHT", host, "TOPRIGHT", -4, -2)
            end
        end
        UI:SetTextSize(name, "small")
        self.fit = { room = w - 10, value = true }
        value:Show()
        level:Hide()
    else
        -- big: per look. The numbers sit in the health bar where it's tall enough (Flat, Halo, Sigil, Gilded), so the
        -- name has its row to itself; Slate's bar is a line, its numbers share the name's row (fit: Set)
        if k == "flat" then
            Bars(bx, bw - 1, -1, -1 - hpH - 1)
            level:SetPoint("LEFT", self.hp.f, "LEFT", 5, 0)
            name:SetPoint("LEFT", level, "RIGHT", 4, 0)
            value:SetPoint("RIGHT", self.hp.f, "RIGHT", -5, 0)
            self.fit = { room = bw - 11, level = true, value = true }
        elseif k == "halo" then
            Bars(bx, bw - 2, -17, -17 - hpH - 3)
            local pad = (ph > 0) and 20 or 6
            level:SetPoint("TOPLEFT", host, "TOPLEFT", left and (bx + pad) or (w - bx - bw + 6), -1)
            name:SetPoint("LEFT", level, "RIGHT", 4, 0)
            -- (in the pill's far end, clear of its round cap, or of the portrait where it covers that end)
            value:SetPoint("RIGHT", self.hp.f, "RIGHT", (left or ph == 0) and -8 or -(overlap + 6), 0)
            self.fit = { room = bw - pad - 6, level = true }
            self.pp.f:ClearAllPoints()
            local inset = 20
            self.pp:SetWidthNow(max(10, bw - inset - 10))
            self.pp.f:SetPoint("TOPLEFT", self.hp.f, "BOTTOMLEFT", left and inset or 10, -3)
        elseif k == "slate" then
            Bars(8, w - 16, -26, -31)
            level:SetPoint("TOPLEFT", host, "TOPLEFT", 8, -6)
            name:SetPoint("LEFT", level, "RIGHT", 4, 0)
            value:SetPoint("TOPRIGHT", host, "TOPRIGHT", -8, -4)
            self.fit = { room = w - 16, level = true, value = true }
        else
            -- sigil / gilded: a header strip with the name, the bars under it (the numbers in the health bar)
            local hh = (k == "gilded") and 15 or 14
            local hx = left and (ph > 0 and ph + 1 or 0) or 0
            self.head:ClearAllPoints()
            self.head:SetPoint("TOPLEFT", host, "TOPLEFT", left and hx or 0, 0)
            self.head:SetPoint("TOPRIGHT", host, "TOPRIGHT", left and 0 or -(ph > 0 and ph + 1 or 0), 0)
            self.head:SetHeight(hh)
            L.Gradient(self.head, look.head.bottom, look.head.top)
            self.headLine:ClearAllPoints()
            self.headLine:SetPoint("TOPLEFT", self.head, "BOTTOMLEFT")
            self.headLine:SetPoint("TOPRIGHT", self.head, "BOTTOMRIGHT")
            self.headLine:SetHeight(1)
            L.Color(self.headLine, look.head.line)
            Bars(bx + 2, bw - 5, -hh - 3, -hh - 3 - hpH - 2)
            level:SetPoint("LEFT", self.head, "LEFT", 5, 0)
            name:SetPoint("LEFT", level, "RIGHT", 4, 0)
            value:SetPoint("RIGHT", self.hp.f, "RIGHT", -5, 0)
            self.fit = { room = w - (ph > 0 and ph + 1 or 0) - 10, level = true }
        end
        level:Show()
        value:Show()
        self.status:SetPoint("CENTER", self.hp.f, "CENTER", 0, 0)
    end
    if look.upper and kind == "big" then UI:SetTextSize(name, "caps") end
    if self.fit then self:FitName() end
    self.name:SetTextColor(look.nameC[1], look.nameC[2], look.nameC[3])
    -- the marks: raid icon on the top edge, the leader crown at the top left
    -- (Halo's cell: both on the name's row, clear of the cell above: the crown before the name, the icon after it)
    self.icon:ClearAllPoints()
    self.leader:ClearAllPoints()
    if self.ringOn then
        self.icon:SetSize(12, 12)
        self.icon:SetPoint("TOPRIGHT", host, "TOPRIGHT", -9, -4)
        self.leader:SetPoint("CENTER", host, "TOPLEFT", 15, -10)
    else
        self.icon:SetSize(14, 14)
        self.icon:SetPoint("CENTER", host, "TOP", 0, 0)
        self.leader:SetPoint("CENTER", host, "TOPLEFT", (kind == "cell") and 4 or (left and (ph > 0 and ph - 4 or 6) or 8), 0)
    end
    if self.d then self:Set(self.d) end
end

-- Draws data d (Units.Data or Units.Fake).
function Face:Set(d)
    self.d = d
    local look = self.look
    if not look or not d then return end
    local L = Look()
    if not d.exists then return end
    local part = self.part
    local frac = (d.hpMax and d.hpMax > 0) and (d.hp or 0) / d.hpMax or 0
    if d.dead or d.offline then frac = d.dead and 0 or frac end
    self.hp:SetColor(HealthColor(part, d, look, self.kind))
    self.hp:SetValue(frac)
    if self.pp.f:IsShown() then
        self.pp:SetColor(PowerColor(d, look))
        self.pp:SetValue((d.pwMax and d.pwMax > 0) and (d.pw or 0) / d.pwMax or 0)
    end
    -- incoming heals: a faint stretch after the fill
    local heal = d.heal and d.hpMax and d.hpMax > 0 and d.heal / d.hpMax or 0
    local x0, span = self.hp:Span()
    self.healCap:Hide()
    if heal > 0 and not d.dead and span > 0 and frac < 1 then
        local fw = span * frac
        local hw = max(0.01, min(span - fw, span * heal))
        self.heal:ClearAllPoints()
        self.heal:SetPoint("TOPLEFT", self.hp.f, "TOPLEFT", x0 + fw, 0)
        self.heal:SetPoint("BOTTOMLEFT", self.hp.f, "BOTTOMLEFT", x0 + fw, 0)
        self.heal:SetWidth(hw)
        self.heal:Show()
        if x0 > 0 then
            self.healCap:ClearAllPoints()
            self.healCap:SetSize(x0, self.hp.h or 0)
            self.healCap:SetPoint("LEFT", self.heal, "RIGHT", 0, 0)
            self.healCap:Show()
        end
    else
        self.heal:Hide()
    end
    -- the name (Slate: in class colour), level (?? and a skull for a boss)
    local name = d.name or ""
    if look.upper and self.kind == "big" then name = name:upper() end
    self.name:SetText(name)
    if look.nameClass and d.isPlayer and d.class then self.name:SetTextColor(L.ClassColor(d.class))
    elseif look.nameClass and not d.isPlayer then
        local r, g, b = HealthColor(part, d, look)
        self.name:SetTextColor(r, g, b)
    else self.name:SetTextColor(look.nameC[1], look.nameC[2], look.nameC[3]) end
    if self.kind == "cell" and (d.dead or d.offline) then self.name:SetTextColor(0.5, 0.5, 0.5) end
    -- (Halo's cell: the crown and the raid icon share the name's row)
    local marks = (d.leader and 1 or 0) + (d.raidIcon and 2 or 0)
    if self.ringOn and marks ~= self.marks then
        self.marks = marks
        local lead = d.leader and true or false
        self.name:ClearAllPoints()
        self.name:SetPoint("TOPLEFT", self.host, "TOPLEFT", lead and 23 or 10, -5)
        self.name:SetWidth(self.nameW - (lead and 13 or 0) - (d.raidIcon and 14 or 0))
    end
    local boss = d.classif == "worldboss" or (d.level or 0) < 0
    self.skull:ClearAllPoints()
    if self.kind == "big" then
        if boss then
            self.level:SetText("")
            self.skull:SetPoint("CENTER", self.level, "LEFT", 5, 0)
            self.skull:Show()
            self.level:SetWidth(10)
        else
            self.skull:Hide()
            local lv = tostring(d.level or "")
            if d.classif == "elite" or d.classif == "rareelite" then lv = lv .. "+" end
            self.level:SetText(lv)
            self.level:SetWidth(0)
        end
    else
        self.skull:Hide()
    end
    -- numbers
    local mode = L:Opt(part, "healthText", "both")
    local pct = floor(frac * 100 + 0.5)
    local txt
    if d.dead then txt = d.ghost and "Ghost" or "Dead"
    elseif d.offline then txt = "Offline"
    elseif self.kind == "small" or mode == "pct" or self.width == W.party then txt = pct .. "%"
    elseif mode == "full" then txt = Int(d.hp) .. " / " .. Int(d.hpMax)
    elseif mode == "none" then txt = ""
    elseif look.key == "slate" then txt = Short(d.hp) .. "  |cffffffff" .. pct .. "%|r"
    else txt = Short(d.hp) .. "  " .. pct .. "%" end
    self.value:SetText(txt)
    if self.fit then self:FitName() end
    if self.kind == "cell" then
        local st = d.dead and (d.ghost and "Ghost" or "Dead") or (d.offline and "Offline" or "")
        if st == "" and frac < 0.995 and frac > 0 then st = "-" .. Short(d.hpMax - d.hp) end
        self.status:SetText(st)
        self.status:Show()
    else
        self.status:SetText("")
    end
    -- marks
    if d.raidIcon and SetRaidTargetIconTexture then
        pcall(SetRaidTargetIconTexture, self.icon, d.raidIcon)
        self.icon:Show()
    else
        self.icon:Hide()
    end
    self.leader:SetShown(d.leader and self.kind ~= "small" or false)
    -- the portrait: the class icon for players (and the option), the game's portrait otherwise
    if self.portOn then
        local opt = L:Opt(part, "portrait", "class")
        local round = self.portrait.shape == "round"
        if d.isPlayer and opt == "class" and d.class then
            local path, l, r, t, b = L.ClassIcon(d.class, round)
            if round then self.portrait:SetTexture(path, l, r, t, b); self.portrait.tex:SetTexCoord(l, r, t, b)
            else self.portrait:SetTexture(path, l, r, t, b) end
        elseif d.unit then
            self.portrait:SetPortrait(d.unit)
        elseif d.portrait then
            self.portrait:SetTexture(d.portrait)
        else
            local path, l, r, t, b = L.ClassIcon(d.class or "WARRIOR", round)
            self.portrait:SetTexture(path, l, r, t, b)
        end
        if round then
            if d.isPlayer and d.class then self.portrait:SetRing(L.ClassColor(d.class))
            else self.portrait:SetRing(HealthColor(part, d, look)) end
        end
    end
    -- the light: a debuff I can remove, else aggro
    local lc
    if d.dispel and L:Opt("group", "dispel", true) then lc = DEBUFF_COLOR[d.dispel]
    elseif d.threat and d.threat >= 2 and self.kind ~= "big" then lc = { 1, 0.25, 0.2 } end
    if self.kind == "small" then lc = nil end
    if self.ringOn then
        -- Halo's cell: the ring round the capsule takes the colour, thicker, with a soft glow beyond it
        self.light:Paint(nil)
        local key = lc and (lc[1] .. "," .. lc[2] .. "," .. lc[3]) or false
        if key ~= self.lit then
            self.lit = key
            local w, h = self.hp.w or 0, self.h or 0
            self.ring:Place(self.hp.f, w, h, lc and 2 or 1)
            self.ring:Paint(lc and { lc[1], lc[2], lc[3], 1 } or HALO_RIM)
            if lc then self.glow:Place(self.hp.f, w, h, 5) end
            self.glow:Paint(lc and { lc[1], lc[2], lc[3], 0.28 } or nil)
        end
    elseif lc and self.portOn and self.portrait.shape == "round" then
        -- Halo's portrait frames: the portrait's ring lights
        self.light:Paint(nil)
        self.portrait:SetRing(lc[1], lc[2], lc[3])
    elseif lc then
        self.light:Paint({ lc[1], lc[2], lc[3], 1 })
    else
        self.light:Paint(nil)
    end
    -- out of range (party / raid)
    if self.kind == "cell" or self.width == W.party then
        self.host:SetAlpha((d.far and L:Opt("group", "range", true)) and 0.45 or 1)
    end
    if self.showAuras then self:SetAuras(d.auras or {}) end
    if self.showCombo then self:SetCombo(d.combo or 0) end
    if self.cl and look.game then self:SetClassic(d) end
end

-- The name ends where the level and numbers on its row leave off (a long name is cut with "..."), never under them.
function Face:FitName()
    local fit = self.fit
    local room = fit.room
    if fit.level then
        room = room - (self.skull:IsShown() and 10 or self.level:GetStringWidth()) - 4
    end
    if fit.value then
        local vw = self.value:GetStringWidth() or 0
        if vw > 0 then room = room - vw - 8 end
    end
    room = max(30, floor(room))
    if room ~= self.fitW then
        self.fitW = room
        self.name:SetWidth(room)
    end
end

-- Auras under the frame: up to 8, mine first (the option), timers under them.
function Face:SetAuras(list)
    local L = Look()
    local look = self.look
    local size = (look.key == "slate") and 16 or 20
    local timers = L:Opt(self.part, "timers", true)
    for i = 1, 8 do
        local a = list[i]
        local slot = self.auras[i]
        if a and not slot then
            local holder = CreateFrame("Frame", nil, self.over)
            slot = { f = holder, icon = L:Icon(holder) }
            slot.icon.f:SetAllPoints(holder)
            slot.count = L:Text(holder, "small", "TEXT", { justify = "RIGHT" })
            slot.count:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 1, -1)
            slot.dur = L:Text(holder, "small", "TEXT", { justify = "CENTER" })
            slot.dur:SetPoint("TOP", holder, "BOTTOM", 0, -1)
            slot.durC = { slot.dur:GetTextColor() }
            self.auras[i] = slot
        end
        if slot then
            if a then
                slot.f:SetSize(size, size)
                slot.f:ClearAllPoints()
                local left = self.side ~= "right" or true
                -- (Classic: on the rails' inside edge, the game's square aura with its debuff-type border)
                local x0 = (look.game and self.ckind == "big") and TF.inL or 0
                slot.f:SetPoint("TOPLEFT", self.host, "BOTTOMLEFT", x0 + (i - 1) * (size + 3) + (left and 0 or 0), -4)
                slot.icon:Apply(look, look.game and "square" or (look.icon == "none" and "small" or look.icon))
                slot.icon:SetTexture(a.icon)
                if look.game then
                    local c = DEBUFF_COLOR[a.dtype] or { 0.8, 0, 0 }
                    slot.icon.edge:Paint({ c[1], c[2], c[3], 1 })
                    slot.dur:SetTextColor(1, 0.82, 0)
                else
                    slot.dur:SetTextColor(slot.durC[1] or 1, slot.durC[2] or 1, slot.durC[3] or 1)
                end
                if look.icon == "round" then slot.icon:SetRing(a.mine and 1 or 1, a.mine and 0.82 or 1, a.mine and 0 or 1) end
                slot.f:SetAlpha(a.mine and 1 or 0.75)
                slot.count:SetText((a.count and a.count > 1) and a.count or "")
                slot.a = a
                slot.timers = timers
                slot.f:Show()
            else
                slot.f:Hide()
                slot.a = nil
            end
        end
    end
    self:TickAuras()
end

function Face:TickAuras()
    local now = GetTime and GetTime() or 0
    for _, slot in ipairs(self.auras) do
        local a = slot.a
        if a and slot.timers and a.exp and a.exp > 0 then
            local left = a.exp - now
            slot.dur:SetText(left > 60 and (floor(left / 60) .. "m") or (left > 0 and floor(left + 0.5) or ""))
        elseif slot.dur then
            slot.dur:SetText("")
        end
    end
end

-- Combo points: five pips under the target's bars (rogues and druids).
function Face:SetCombo(n)
    local look = self.look
    for i = 1, 5 do
        local p = self.pips[i]
        if not p then
            p = Look().Tex(self.over, "OVERLAY", 2, look.icon == "round" and Look().DISC or nil)
            self.pips[i] = p
        end
        p:SetTexture(look.icon == "round" and Look().DISC or Look().WHITE)
        p:SetSize(8, look.key == "slate" and 3 or 6)
        p:ClearAllPoints()
        p:SetPoint("TOPRIGHT", self.host, "BOTTOMRIGHT", -(5 - i) * 11, -4)
        if i <= n then p:SetVertexColor(1, 0.82, 0, 1) else p:SetVertexColor(1, 1, 1, 0.12) end
        p:SetShown(n > 0)
    end
end

---------------------------------------------------------------------------
-- Live frames
---------------------------------------------------------------------------

local frames = {}        -- key -> secure button
local byUnit = {}        -- unit token -> { button = true }
local faces = {}         -- every live face (for restyling)
local header = {}        -- "party" | "raid" -> header
local holders = {}       -- "party" | "raid" -> the frame the header hangs from (and the layout moves)
local previews = {}      -- key -> a non-secure frame with a made-up face
Units.frames, Units.header, Units.holders = frames, header, holders

local function Track(b, unit)
    if b.unitKey then
        local set = byUnit[b.unitKey]
        if set then set[b] = nil end
    end
    b.unitKey = unit
    if unit then
        byUnit[unit] = byUnit[unit] or {}
        byUnit[unit][b] = true
    end
end

local function Refresh(b)
    if not b.face or not b.face.look then return end
    local unit = b:GetAttribute("unit")
    if unit ~= b.unitKey then Track(b, unit) end
    if not unit then return end
    local d = Units.Data(unit, b.data)
    b.data = d
    if b.face.showAuras then d.auras = Units.Auras(unit, b.face.part, b.auraList); b.auraList = d.auras end
    if b.face.showCombo then d.combo = (GetComboPoints and GetComboPoints("player", "target")) or 0 end
    b.face:Set(d)
end
Units.Refresh = Refresh

local function OnEnter(self)
    local unit = self:GetAttribute("unit")
    if not unit or not GameTooltip then return end
    if GameTooltip_SetDefaultAnchor then GameTooltip_SetDefaultAnchor(GameTooltip, self) else GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT") end
    GameTooltip:SetUnit(unit)
    GameTooltip:Show()
end

local function StyleButton(b, kind, part, side, width)
    b:RegisterForClicks("AnyUp")
    b.face = Units:NewFace(b, kind, part, side)
    b.face.width = width
    faces[#faces + 1] = b.face
    b:HookScript("OnShow", function(self) Refresh(self) end)
    b:HookScript("OnAttributeChanged", function(self, name)
        if name == "unit" then Refresh(self) end
    end)
    b:HookScript("OnEnter", OnEnter)
    b:HookScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end

local function NewUnitButton(key)
    local def = UNITS[key]
    local b = CreateFrame("Button", "DisasterZoneUnit_" .. key, UIParent, "SecureUnitButtonTemplate")
    b:SetAttribute("unit", def.unit)
    b:SetAttribute("*type1", "target")
    b:SetAttribute("*type2", "togglemenu")
    b:SetFrameStrata("LOW")
    StyleButton(b, def.kind, "units", def.side)
    b.face.showAuras = def.auras
    b.face.showCombo = def.combo
    if key ~= "player" and RegisterUnitWatch then RegisterUnitWatch(b) end
    frames[key] = b
    Track(b, def.unit)
    return b
end

-- (the restricted snippet each header child runs when it's made: its size and clicks, then our styling)
local CHILD = [[
    self:SetWidth(%d)
    self:SetHeight(%d)
    self:SetAttribute("*type1", "target")
    self:SetAttribute("*type2", "togglemenu")
    self:GetParent():CallMethod("InitChild", self:GetName())
]]

local function GroupSize(which, look)
    if which == "party" then
        return W.party, ({ flat = 42, halo = 46, sigil = 46, slate = 38, gilded = 48, classic = 56 })[look.key] or 42
    end
    return CellSize(look)
end

local function NewHeader(which, look)
    local w, h = GroupSize(which, look)
    local holder = CreateFrame("Frame", "DisasterZone" .. (which == "party" and "Party" or "Raid") .. "Frames", UIParent)
    holder:SetFrameStrata("LOW")
    holders[which] = holder
    local hd = CreateFrame("Frame", "DisasterZone" .. (which == "party" and "Party" or "Raid") .. "Header", holder,
        "SecureGroupHeaderTemplate")
    hd:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    hd:SetAttribute("template", "SecureUnitButtonTemplate")
    hd:SetAttribute("initialConfigFunction", CHILD:format(w, h))
    local gap = which == "party" and 10 or max(2, look.gap or 2)
    if which == "party" then
        hd:SetAttribute("showParty", true)
        hd:SetAttribute("showRaid", false)
        hd:SetAttribute("showPlayer", Look():Opt("group", "player", false) and true or false)
        hd:SetAttribute("point", "TOP")
        hd:SetAttribute("yOffset", -gap)
        holder:SetSize(w, 5 * h + 4 * gap)
    else
        hd:SetAttribute("showRaid", true)
        hd:SetAttribute("showParty", false)
        hd:SetAttribute("groupBy", "GROUP")
        hd:SetAttribute("groupingOrder", "1,2,3,4,5,6,7,8")
        hd:SetAttribute("maxColumns", 8)
        hd:SetAttribute("unitsPerColumn", 5)
        hd:SetAttribute("point", "TOP")
        hd:SetAttribute("yOffset", -gap)
        hd:SetAttribute("columnAnchorPoint", "LEFT")
        hd:SetAttribute("columnSpacing", gap)
        holder:SetSize(8 * w + 7 * gap, 5 * h + 4 * gap)
    end
    hd.which, hd.w = which, w
    function hd:InitChild(name)
        local child = _G[name]
        if not child or child.face then return end
        StyleButton(child, which == "party" and "big" or "cell", "group", "left", which == "party" and W.party or W.cell)
        child:SetFrameStrata("LOW")
        child.face:Apply(Look():For("group"))
    end
    -- every button made now, out of combat (as unit frame addons do): nothing is made in a fight
    local n = which == "party" and 5 or 40
    hd:SetAttribute("startingIndex", -n + 1)
    hd:Show()
    hd:SetAttribute("startingIndex", 1)
    header[which] = hd
    return hd
end

-- The made-up frames for previews (Edit layout, demo mode): over the live frame's place.
local function Preview(key)
    if previews[key] then return previews[key] end
    local p
    if key == "party" or key == "raid" then
        p = CreateFrame("Frame", nil, holders[key] or UIParent)
        p:SetAllPoints(holders[key] or UIParent)
        p.cells = {}
    else
        local b = frames[key]
        p = CreateFrame("Frame", nil, UIParent)
        p:SetPoint("TOPLEFT", b, "TOPLEFT")
        local def = UNITS[key]
        p.face = Units:NewFace(p, def.kind, "units", def.side)
        p.face.showAuras, p.face.showCombo = def.auras, def.combo
    end
    p:SetFrameStrata("LOW")
    p:Hide()
    previews[key] = p
    return p
end

local function FillGroupPreview(key, look)
    local p = Preview(key)
    local w, h = GroupSize(key, look)
    local gap = key == "party" and 10 or max(2, look.gap or 2)
    local n = key == "party" and 4 or 25
    for i = 1, n do
        local c = p.cells[i]
        if not c then
            c = CreateFrame("Frame", nil, p)
            c.face = Units:NewFace(c, key == "party" and "big" or "cell", "group", "left")
            c.face.width = key == "party" and W.party or W.cell
            p.cells[i] = c
        end
        c.face:Apply(look)
        c:ClearAllPoints()
        if key == "party" then
            c:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -(i - 1) * (h + gap))
        else
            local col, row = floor((i - 1) / 5), (i - 1) % 5
            c:SetPoint("TOPLEFT", p, "TOPLEFT", col * (w + gap), -row * (h + gap))
        end
        c.face:Set(Units.Fake("member", i + (key == "party" and 0 or 4)))
        c:Show()
    end
end

function Units:ShowPreview(key, on)
    local p = Preview(key)
    if not on then p:Hide() return end
    if key == "party" or key == "raid" then
        FillGroupPreview(key, Look():For("group"))
        -- (the live frames show over it when there is a group)
        p:Show()
        return
    end
    local b = frames[key]
    if b and b:IsShown() then p:Hide() return end
    p.face:Apply(Look():For("units"))
    local d = Units.Fake(key)
    if d.auras then d.combo = 3 end
    p.face:Set(d)
    p:Show()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local UNIT_EVENTS = { "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_POWER_FREQUENT", "UNIT_MAXPOWER",
    "UNIT_DISPLAYPOWER", "UNIT_NAME_UPDATE", "UNIT_LEVEL", "UNIT_AURA", "UNIT_PORTRAIT_UPDATE", "UNIT_FACTION",
    "UNIT_FLAGS", "UNIT_CONNECTION", "UNIT_THREAT_SITUATION_UPDATE", "UNIT_HEAL_PREDICTION", "UNIT_CLASSIFICATION_CHANGED" }
local ALL_EVENTS = { "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "GROUP_ROSTER_UPDATE", "RAID_TARGET_UPDATE",
    "PARTY_LEADER_CHANGED", "UNIT_PET", "UNIT_TARGET", "PLAYER_ENTERING_WORLD" }

local driver
local function RefreshAll()
    for _, b in pairs(frames) do if b:IsShown() then Refresh(b) end end
    for _, hd in pairs(header) do
        for i = 1, 40 do
            local c = hd:GetAttribute("child" .. i)
            if not c then break end
            if c:IsShown() then Refresh(c) end
        end
    end
end
Units.RefreshAll = RefreshAll

local function OnEvent(_, event, unit, extra)
    if event == "PLAYER_TARGET_CHANGED" then
        if frames.target then Refresh(frames.target) end
        if frames.tot then Refresh(frames.tot) end
        return
    elseif event == "PLAYER_FOCUS_CHANGED" then
        if frames.focus then Refresh(frames.focus) end
        return
    elseif event == "UNIT_TARGET" then
        if unit == "target" and frames.tot then Refresh(frames.tot) end
        return
    elseif event == "UNIT_PET" then
        if unit == "player" and frames.pet then Refresh(frames.pet) end
        return
    elseif event == "UNIT_POWER_UPDATE" and unit == "player" and extra == "COMBO_POINTS" then
        if frames.target then Refresh(frames.target) end
    end
    if unit and byUnit[unit] then
        for b in pairs(byUnit[unit]) do if b:IsShown() then Refresh(b) end end
        return
    end
    if not unit then RefreshAll() end
end

-- every 0.2 s: the target of target (no event says it changed), aura timers, the group's range
local since = 0
local function OnUpdate(_, dt)
    since = since + (dt or 0)
    if since < 0.2 then return end
    since = 0
    local tot = frames.tot
    if tot and tot:IsShown() then Refresh(tot) end
    for _, key in ipairs({ "target", "focus" }) do
        local b = frames[key]
        if b and b:IsShown() and b.face then b.face:TickAuras() end
    end
end

local rangeSince = 0
local function RangeTick(_, dt)
    rangeSince = rangeSince + (dt or 0)
    if rangeSince < 0.5 then return end
    rangeSince = 0
    for _, hd in pairs(header) do
        for i = 1, 40 do
            local c = hd:GetAttribute("child" .. i)
            if not c then break end
            if c:IsShown() then Refresh(c) end
        end
    end
end

---------------------------------------------------------------------------
-- Putting them up, restyling, the layout
---------------------------------------------------------------------------

local BLIZZ_UNITS = { "PlayerFrame", "TargetFrame", "FocusFrame", "PetFrame" }
local BLIZZ_GROUP = { "PartyFrame", "CompactPartyFrame", "CompactRaidFrameManager", "CompactRaidFrameContainer" }

local function RetireAll(list)
    local ok = true
    for _, name in ipairs(list) do
        local f = _G[name]
        if f then
            if name == "PartyFrame" and f.PartyMemberFramePool and f.PartyMemberFramePool.EnumerateActive then
                for m in f.PartyMemberFramePool:EnumerateActive() do Look():Retire(m, true) end
            end
            for i = 1, 4 do
                local m = _G["PartyMemberFrame" .. i]
                if m and name == "PartyFrame" then Look():Retire(m) end
            end
            ok = Look():Retire(f) and ok
        end
    end
    -- (and their Edit layout items: ours take their place)
    if ns.Layout and ns.Layout.Unregister then
        for _, name in ipairs(list) do ns.Layout:Unregister("blizz:" .. name) end
    end
    return ok
end

function Units:Restyle(part)
    local L = Look()
    if part == "units" or part == nil then
        local look = L:For("units")
        for _, key in ipairs(ORDER) do
            local b = frames[key]
            if b then
                b.face:Apply(look)
                if not InCombat() then b:SetSize(b.face.host:GetWidth(), b.face.host:GetHeight()) end
                Refresh(b)
            end
            local p = previews[key]
            if p and p:IsShown() then self:ShowPreview(key, true) end
        end
    end
    if part == "group" or part == nil then
        local look = L:For("group")
        for which, holder in pairs(holders) do
            if not InCombat() then
                local w, h = GroupSize(which, look)
                local gap = which == "party" and 10 or max(2, look.gap or 2)
                if which == "party" then holder:SetSize(w, 5 * h + 4 * gap)
                else holder:SetSize(8 * w + 7 * gap, 5 * h + 4 * gap) end
                local hd = header[which]
                if hd and which == "raid" then hd:SetAttribute("columnSpacing", gap); hd:SetAttribute("yOffset", -gap) end
            end
        end
        for which, hd in pairs(header) do
            for i = 1, 40 do
                local c = hd:GetAttribute("child" .. i)
                if not c then break end
                if c.face then c.face:Apply(look); Refresh(c) end
            end
            local p = previews[which]
            if p and p:IsShown() then self:ShowPreview(which, true) end
        end
    end
end

local function RegisterItems()
    local Lay = ns.Layout
    if not Lay then return end
    if Look():IsOn("units") then
        for _, key in ipairs(ORDER) do
            local def = UNITS[key]
            Lay:Register("uf." .. key, { name = def.name, group = "Game frames", order = def.order, protected = true,
                noHide = true, default = def.default,
                frame = function() return frames[key] end,
                box = function()
                    local b = frames[key]
                    if b and b:IsVisible() then return b end
                    local p = previews[key]
                    return p and p:IsVisible() and p or nil
                end,
                mine = function() return key ~= "pet" or (UnitExists and UnitExists("pet")) or true end,
                when = (key ~= "player") and ("when you have a " .. ((key == "tot") and "target" or key)) or nil,
                preview = (key ~= "player") and function(on) Units:ShowPreview(key, on) end or nil })
        end
    end
    if Look():IsOn("group") then
        for _, which in ipairs({ "party", "raid" }) do
            Lay:Register("group." .. which, { name = (which == "party") and "Party frames" or "Raid frames",
                group = "Game frames", order = (which == "party") and 6 or 7, protected = true, noHide = true,
                default = (which == "party") and { "LEFT", 20, 120 } or { "TOPLEFT", 20, -220 },
                frame = function() return holders[which] end,
                -- (the holder is always there: what shows is its units, or the made-up ones)
                box = function()
                    local hd = header[which]
                    local c1 = hd and hd:GetAttribute("child1")
                    if c1 and c1:IsVisible() then return holders[which] end
                    local p = previews[which]
                    return p and p:IsVisible() and p or false
                end,
                when = "in a " .. which,
                preview = function(on) Units:ShowPreview(which, on) end })
        end
    end
    -- a mirrored pair to start from: player and target
    local m = Lay:Active().mirror
    if Look():IsOn("units") and not next(m) and not Lay:Entry("uf.player") then
        m["uf.player"], m["uf.target"] = "uf.target", "uf.player"
    end
end

local pending = false
function Units:Setup()
    local L = Look()
    local unitsOn, groupOn = L:IsOn("units"), L:IsOn("group")
    L:SetApplied("units", L:Key("units"))
    L:SetApplied("group", L:Key("group"))
    if not unitsOn and not groupOn then return end
    if InCombat() then pending = true return end
    pending = false
    if unitsOn and not frames.player then
        RetireAll(BLIZZ_UNITS)
        for _, key in ipairs(ORDER) do NewUnitButton(key) end
    end
    if groupOn and not header.party then
        RetireAll(BLIZZ_GROUP)
        local look = L:For("group")
        NewHeader("party", look)
        NewHeader("raid", look)
    end
    if not driver then
        driver = CreateFrame("Frame")
        for _, e in ipairs(UNIT_EVENTS) do pcall(driver.RegisterEvent, driver, e) end
        for _, e in ipairs(ALL_EVENTS) do pcall(driver.RegisterEvent, driver, e) end
        driver:SetScript("OnEvent", OnEvent)
        driver:SetScript("OnUpdate", function(f, dt) OnUpdate(f, dt); RangeTick(f, dt) end)
    end
    RegisterItems()
    self:Restyle()
    for _, key in ipairs(ORDER) do if ns.Layout then ns.Layout:Place("uf." .. key) end end
    for _, which in ipairs({ "party", "raid" }) do if ns.Layout then ns.Layout:Place("group." .. which) end end
    RefreshAll()
end

-- Demo mode: a made-up party beside you when you're not in a group.
function Units:Demo()
    if not Look():IsOn("group") or not holders.party then return end
    local on = ns.Demo and ns.Demo:IsEnabled() and not (IsInGroup and IsInGroup())
    self:ShowPreview("party", on and true or false)
end

function Units:OnLogin()
    self:Setup()
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() if pending then Units:Setup() end end)
    ns:On("UI_LOOK_CHANGED", function(part)
        if (part == "units" or part == "group") and not Look():NeedsReload(part) then Units:Restyle(part) end
    end)
    ns:On("DEMO_TOGGLED", function() Units:Demo() end)
    self:Demo()
end

function Units:Frame(key) return frames[key] end
function Units:Header(which) return header[which] end
function Units:PreviewFrame(key) return previews[key] end
Units.Face = Face

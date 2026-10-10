if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SwingTimerHUD.lua", ...) then return end -- DisasterZone: swing timer HUD.
-- The on-screen part of Core/SwingTimer.lua. The swing is a ring of dots around the next press: gold fills
-- clockwise from 12 o'clock, the twist window orange, the server's window dim red; it flashes when a swing lands
-- and glows while the twist is open. Notes from the earlier bar layout:
--   queue   NEXT: the next press large in a gold frame (its name and what to do), the three after it smaller,
--           Judgement (off the GCD) on the left
--   bar     the swing in a dark panel with a gold rim: gold fill and spark, the orange press zone (the twist window
--           moved one round trip earlier, the latency bracket under it), the server's real window as a dim red edge,
--           a blue line where a GCD pressed now would end (red when it would run through the window), the weapon on
--           the left and the seal on the right
--   dots    the last swings: green twisted, gold late, red clipped, grey plain
--   lane    the planner's next ~7 s: swings, twist windows and every GCD block it placed (fillers in blue)
-- When auto attack is not running it rests: an empty bar and nothing else moves.
-- Style (settings swing.style): "bar", "lane" or "both". Unlock with /dz swing unlock to drag it.
local addonName, ns = ...

local HUD = ns:NewModule("SwingTimerHUD")

local floor, max, min, sin = math.floor, math.max, math.min, math.sin
local strformat = string.format

local RING, RING_R, DOTS, DOT = 128, 54, 200, 6
local BIG, SMALL, SIDE = 70, 28, 22
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SOFT = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"   -- white, alpha fading out from the center
local LANE_W, LANE_H, LANE_SPAN, LANE_BACK = 500, 46, 7.5, 0.5
local STATUSBAR = "Interface\\TargetingFrame\\UI-StatusBar"
local SPARK = "Interface\\CastingBar\\UI-CastingBar-Spark"
local HALO = "Interface\\Buttons\\UI-ActionButton-Border"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local FRIZ = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local NARROW = "Fonts\\ARIALN.TTF"
local GOLD = { 0.95, 0.74, 0.30 }
local ZONE = { 1.0, 0.56, 0.20 }
local FILLER = { 0.45, 0.72, 1.0 }
local KIND_COLOR = { twist = { 0.31, 0.83, 0.42 }, late = { 0.89, 0.70, 0.24 }, clip = { 0.88, 0.38, 0.31 },
    plain = { 0.30, 0.30, 0.34 } }
local FILLERS = { exo = true, cons = true }

local ST                         -- ns.SwingTimer
local frame
local zoneWasOpen
local lastNext, flashAt, shownKey, shownAt, lastExtra = nil, nil, nil, 0, nil

local function Get(path, default) return ST.Get(path, default) end

local function Tex(parent, layer, path, r, g, b, a, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub)
    t:SetTexture(path or WHITE)
    if r then t:SetVertexColor(r, g, b, a or 1) end
    return t
end

local function Font(parent, font, size, r, g, b, flags)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFont(font, size, flags or "")
    f:SetTextColor(r or 1, g or 1, b or 1)
    f:SetShadowColor(0, 0, 0, 1)
    f:SetShadowOffset(1, -1)
    return f
end

-- A two-color gradient where the client has one (SetGradient with colors on newer clients, SetGradientAlpha on
-- older ones); the flat average color underneath either way, so it never comes out white.
local function Gradient(t, orient, r1, g1, b1, a1, r2, g2, b2, a2)
    t:SetVertexColor((r1 + r2) / 2, (g1 + g2) / 2, (b1 + b2) / 2, (a1 + a2) / 2)
    if t.SetGradient and CreateColor then
        pcall(t.SetGradient, t, orient, CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
    elseif t.SetGradientAlpha then
        pcall(t.SetGradientAlpha, t, orient, r1, g1, b1, a1, r2, g2, b2, a2)
    end
end

-- A flat panel: a 1 px dark edge around a translucent dark fill, nothing else.
local function Panel(f, alpha)
    local edge = Tex(f, "BACKGROUND", WHITE, 0, 0, 0, 0.9, -7)
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    local fill = Tex(f, "BACKGROUND", WHITE, 0.06, 0.06, 0.07, alpha or 0.75, -5)
    fill:SetAllPoints()
end

-- An icon with a black edge (the client's icons with their own border trimmed); gold = the gold frame of the next press.
local function Icon(parent, size, gold)
    local h = CreateFrame("Frame", nil, parent)
    h:SetSize(size, size)
    if gold then
        h.halo = Tex(h, "BACKGROUND", HALO, 1, 0.72, 0.3, 0.9, -8)
        h.halo:SetBlendMode("ADD")
        h.halo:SetPoint("CENTER")
        h.halo:SetSize(size * 1.7, size * 1.7)
        local g = Tex(h, "BACKGROUND", WHITE, 1, 0.84, 0.42, 1, -7)
        g:SetPoint("TOPLEFT", -2, 2)
        g:SetPoint("BOTTOMRIGHT", 2, -2)
        h.goldRim = g
    end
    local edge = Tex(h, "BACKGROUND", WHITE, 0, 0, 0, 1, -6)
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    h.icon = Tex(h, "ARTWORK")
    h.icon:SetAllPoints()
    h.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    h.text = Font(h, NARROW, max(11, floor(size * 0.36)), 0.81, 0.77, 0.65)
    h.text:SetPoint("TOP", h, "BOTTOM", 0, -3)
    h.center = Font(h, NARROW, max(13, floor(size * 0.4)), 1, 1, 1, "OUTLINE")
    h.center:SetPoint("CENTER")
    return h
end

-- Crops a texture to a circle where the client has mask textures.
local function Round(holder, tex)
    if not holder.CreateMaskTexture then return end
    local m = holder:CreateMaskTexture()
    m:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    m:SetAllPoints(tex)
    tex:AddMaskTexture(m)
end

local function SavePos()
    local p, _, rp, x, y = frame:GetPoint()
    ns.DB:SetSetting("swing.pos", { p, rp, floor(x + 0.5), floor(y + 0.5) })
end

local function Build()
    frame = CreateFrame("Frame", "DisasterZoneSwingTimer", UIParent)
    frame:SetSize(LANE_W + 40, 260)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f) if not Get("locked", true) then f:StartMoving() end end)
    frame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing(); SavePos() end)
    local pos = Get("pos")
    if type(pos) == "table" and pos[1] then frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else frame:SetPoint("CENTER", UIParent, "CENTER", 0, -170) end

    frame.mover = Tex(frame, "BACKGROUND", WHITE, 0.2, 0.6, 1, 0.15, -8)
    frame.mover:SetAllPoints()
    frame.moverText = Font(frame, FRIZ, 12, 0.6, 0.85, 1)
    frame.moverText:SetPoint("TOP", 0, -2)
    frame.moverText:SetText("Swing timer: drag it, then /dz swing lock")

    -- the ring (kept as frame.bar so Layout's bar/lane switch still works)
    local ring = CreateFrame("Frame", nil, frame)
    ring:SetSize(RING, RING)
    ring:SetPoint("TOP", frame, "TOP", 0, -20)
    frame.bar = ring
    ring.glow = Tex(ring, "BACKGROUND", SOFT, ZONE[1], ZONE[2], ZONE[3], 0, -8)
    ring.glow:SetBlendMode("ADD")
    ring.glow:SetPoint("CENTER")
    ring.glow:SetSize(RING * 1.9, RING * 1.9)
    ring.well = Tex(ring, "BACKGROUND", DISC, 0, 0, 0, 0.55, -6)
    ring.well:SetPoint("CENTER")
    ring.well:SetSize(RING_R * 2 + 12, RING_R * 2 + 12)
    ring.dots = {}
    for i = 1, DOTS do
        local f = (i - 0.5) / DOTS
        local a = math.pi / 2 - 2 * math.pi * f
        local d = Tex(ring, "ARTWORK", DISC)
        d:SetSize(DOT, DOT)
        d:SetPoint("CENTER", ring, "CENTER", RING_R * math.cos(a), RING_R * math.sin(a))
        d.f = f
        ring.dots[i] = d
    end
    ring.head = Tex(ring, "OVERLAY", SOFT, 1, 0.92, 0.66, 0.9)
    ring.head:SetBlendMode("ADD")
    ring.head:SetSize(DOT * 5, DOT * 5)
    ring.tip = Tex(ring, "OVERLAY", DISC, 1, 1, 1, 1, 1)
    ring.tip:SetSize(DOT, DOT)
    ring.flash = Tex(ring, "BACKGROUND", SOFT, 1, 0.86, 0.5, 0, 2)
    ring.flash:SetBlendMode("ADD")
    ring.flash:SetPoint("CENTER")
    ring.flash:SetSize(RING * 1.9, RING * 1.9)

    -- the next press, round, in the middle
    local big = CreateFrame("Frame", nil, ring)
    big:SetSize(BIG, BIG)
    big:SetPoint("CENTER")
    big.icon = Tex(big, "ARTWORK")
    big.icon:SetAllPoints()
    big.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    Round(big, big.icon)
    big.shade = Tex(big, "OVERLAY", DISC, 0, 0, 0, 0)
    big.shade:SetAllPoints()
    frame.big = big

    -- the seal, a small badge on the ring's lower right
    local seal = CreateFrame("Frame", nil, ring)
    seal:SetSize(SIDE, SIDE)
    seal:SetPoint("CENTER", ring, "CENTER", RING_R * 0.72, -RING_R * 0.72)
    seal:SetFrameLevel(ring:GetFrameLevel() + 3)
    local sb = Tex(seal, "BACKGROUND", DISC, 0, 0, 0, 1)
    sb:SetPoint("CENTER")
    sb:SetSize(SIDE + 4, SIDE + 4)
    seal.icon = Tex(seal, "ARTWORK")
    seal.icon:SetAllPoints()
    seal.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    Round(seal, seal.icon)
    seal.text = Font(seal, NARROW, 10, 1, 1, 1, "OUTLINE")
    seal.text:SetPoint("CENTER", 0, 0)
    frame.seal = seal

    -- name and countdown to the right
    big.name = Font(ring, FRIZ, 15, 1, 0.88, 0.54)
    big.name:SetPoint("LEFT", ring, "RIGHT", 6, 7)
    big.name:SetJustifyH("LEFT")
    big.hint = Font(ring, NARROW, 12, 0.75, 0.70, 0.58)
    big.hint:SetPoint("TOPLEFT", big.name, "BOTTOMLEFT", 0, -2)
    big.name:Hide()   -- the ring shows the time and the icon the spell: no text beside it
    big.hint:Hide()

    -- the presses after it, small and fading, to the left
    frame.small = {}
    for i = 1, 3 do
        local s = CreateFrame("Frame", nil, ring)
        local size = i == 1 and SMALL or SMALL - 6
        s:SetSize(size, size)
        s.icon = Tex(s, "ARTWORK")
        s.icon:SetAllPoints()
        s.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        Round(s, s.icon)
        s.text = Font(s, NARROW, 10)
        s:SetAlpha(i == 1 and 0.8 or 0.45)
        if i == 1 then s:SetPoint("RIGHT", ring, "LEFT", -4, 0)
        else s:SetPoint("RIGHT", frame.small[i - 1], "LEFT", -6, 0) end
        frame.small[i] = s
    end
    frame.dots = {}

    -- lane
    local lane = CreateFrame("Frame", nil, frame)
    lane:SetSize(LANE_W, LANE_H)
    lane:SetPoint("TOP", ring, "BOTTOM", 0, -14)
    frame.lane = lane
    Panel(lane, 0.82)
    for s = 1, 7 do
        local g = Tex(lane, "BORDER", WHITE, 1, 1, 1, 0.05)
        g:SetWidth(1)
        g:SetPoint("TOP")
        g:SetPoint("BOTTOM")
        g:SetPoint("LEFT", lane, "LEFT", (s + LANE_BACK) / LANE_SPAN * LANE_W, 0)
    end
    lane.now = Tex(lane, "OVERLAY", WHITE, 1, 1, 1, 1)
    lane.now:SetWidth(2)
    lane.now:SetPoint("TOP", 0, 4)
    lane.now:SetPoint("BOTTOM", 0, -4)
    lane.now:SetPoint("LEFT", lane, "LEFT", LANE_BACK / LANE_SPAN * LANE_W, 0)
    lane.gain = Font(lane, FRIZ, 11, 0.5, 0.88, 0.56)
    lane.gain:SetPoint("TOPRIGHT", lane, "BOTTOMRIGHT", 0, -6)
    lane.ticks, lane.windows, lane.blocks = {}, {}, {}
    for i = 1, 4 do
        local w = Tex(lane, "BORDER", WHITE)
        Gradient(w, "HORIZONTAL", ZONE[1], ZONE[2], ZONE[3], 0.04, ZONE[1], ZONE[2], ZONE[3], 0.38)
        lane.windows[i] = w
        local t = Tex(lane, "OVERLAY", WHITE, GOLD[1], GOLD[2], GOLD[3], 1)
        t:SetWidth(2)
        lane.ticks[i] = t
    end
    for i = 1, 6 do
        local b = CreateFrame("Frame", nil, lane)
        b:SetHeight(LANE_H - 12)
        b.bg = Tex(b, "BACKGROUND", WHITE, 1, 1, 1, 0.07)
        b.bg:SetAllPoints()
        b.line = Tex(b, "BORDER", WHITE, 1, 1, 1, 0.16)
        b.line:SetPoint("TOPLEFT")
        b.line:SetPoint("TOPRIGHT")
        b.line:SetHeight(1)
        b.icon = Tex(b, "ARTWORK")
        b.icon:SetSize(LANE_H - 18, LANE_H - 18)
        b.icon:SetPoint("LEFT", 3, 0)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.name = Font(b, NARROW, 12, 0.94, 0.89, 0.74)
        b.name:SetPoint("LEFT", b.icon, "RIGHT", 5, 0)
        b.name:SetPoint("RIGHT", b, "RIGHT", -3, 0)
        b.name:SetJustifyH("LEFT")
        b.name:SetWordWrap(false)
        lane.blocks[i] = b
    end

    frame:SetScript("OnUpdate", function() HUD:Update() end)
end

-- What a step is called and what to tell the player.
local function StepText(step, now)
    local key = step.key
    local name = key == "wait" and "Hold" or (ST.NameOf(key) or key)
    local dt = step.at - now
    local hint
    if key == "wait" then hint = ""
    elseif key == "sob" and step.twist then hint = dt > 0.05 and "" or "twist"
    elseif dt > 0.05 then hint = ""
    elseif FILLERS[key] then hint = ""
    else hint = "" end
    return name, hint
end

-- Lane labels have about 60 px: the word that tells the spells apart.
local SHORT = { cs = "Strike", soc = "Command", exo = "Exorcism", cons = "Consec." }
local function Short(key)
    if SHORT[key] then return SHORT[key] end
    local n = ST.NameOf(key) or key
    return (n:gsub("^Seal of the ", ""):gsub("^Seal of ", ""))
end

function HUD:Layout()
    local style = Get("style", "bar")
    frame:SetScale(tonumber(Get("scale", 1)) or 1)
    local showBar, showLane = style ~= "lane", style ~= "bar"
    frame.bar:SetShown(showBar)
    frame.lane:ClearAllPoints()
    if showBar then frame.lane:SetPoint("TOP", frame.bar, "BOTTOM", 0, -14)
    else frame.lane:SetPoint("TOP", frame, "TOP", 0, -20) end
    frame.laneWanted = showLane
    local locked = Get("locked", true)
    frame.mover:SetShown(not locked)
    frame.moverText:SetShown(not locked)
    frame:EnableMouse(not locked)
end

function HUD:UpdateVisibility()
    if not frame then return end
    local show = ST.active and (not Get("locked", true) or Get("idle", false) or InCombatLockdown()
        or UnitAffectingCombat("player") or ST:IsDemo())
    frame:SetShown(show and true or false)
end

-- Resting: auto attack is not running, so there is nothing to time. A faint empty ring, the rest hidden.
local function Rest()
    local ring = frame.bar
    frame.lane:Hide()
    ring:SetAlpha(0.35)
    for _, d in ipairs(ring.dots) do d:SetVertexColor(0.13, 0.13, 0.14) end
    ring.head:Hide()
    ring.tip:Hide()
    ring.glow:SetAlpha(0)
    ring.flash:SetAlpha(0)
    frame.big:SetScale(1)
    frame.big.icon:SetTexture(GetInventoryItemTexture("player", 16) or ST.ICONS.wait)
    frame.big.icon:SetDesaturated(true)
    frame.big.shade:SetAlpha(0)
    frame.big.name:SetText("")
    frame.big.hint:SetText("")
    for _, s in ipairs(frame.small) do s:Hide() end
    local seal = ST.state.seal
    frame.seal:SetShown(seal ~= nil)
    if seal then frame.seal.icon:SetTexture(ST.ICONS[seal]); frame.seal.text:SetText("") end
    lastNext, shownKey = nil, nil
end

local function Ease(x) return 1 - (1 - x) * (1 - x) end

function HUD:Update()
    local now = GetTime()
    local ok, cur = pcall(ST.Current, ST)
    if not ok or not cur then Rest() return end
    local snap, steps = cur.snap, cur.plan.steps
    local speed, nxt = snap.speed, ST:NextSwing(now)
    local elapsed = max(0, speed - (nxt - now))
    local frac = min(1, elapsed / speed)
    local lat = snap.lat
    local zone0, zone1 = nxt - ST.OVERLAP + ST.MARGIN - lat, nxt - ST.MARGIN - lat
    local inZone = now >= zone0 and now <= zone1
    local first = steps[1]
    local wantsTwist = first and first.key == "sob" and first.twist
    frame.lane:SetShown(frame.laneWanted)

    -- a swing landed: the ring flashes
    if lastNext and nxt > lastNext + 0.2 then flashAt = now end
    lastNext = nxt
    -- an extra attack (Reckoning and the like): the same flash, the swing keeps its time
    local ex = ST.state.extraAt
    if ex and ex ~= lastExtra then lastExtra, flashAt = ex, now end

    local ring = frame.bar
    ring:SetAlpha(1)
    local start = nxt - speed
    local z0, z1 = (zone0 - start) / speed, (zone1 - start) / speed
    local s0 = 1 - ST.OVERLAP / speed
    local pulse = 0.5 + 0.5 * sin(now * 9)
    for _, d in ipairs(ring.dots) do
        local f = d.f
        if f <= frac then
            -- opaque colors only: the dots overlap into one smooth band
            if f >= z0 and f <= z1 then d:SetVertexColor(1, 0.62 + 0.2 * pulse, 0.3)
            else d:SetVertexColor(0.62 + 0.36 * f, 0.46 + 0.36 * f, 0.18 + 0.30 * f) end
        elseif f >= z0 and f <= z1 then
            if wantsTwist then d:SetVertexColor(0.62, 0.32, 0.10) else d:SetVertexColor(0.30, 0.19, 0.10) end
        elseif f >= s0 then
            d:SetVertexColor(0.30, 0.09, 0.07)
        else
            d:SetVertexColor(0.13, 0.13, 0.14)
        end
    end
    local a = math.pi / 2 - 2 * math.pi * frac
    local hx, hy = RING_R * math.cos(a), RING_R * math.sin(a)
    ring.head:ClearAllPoints()
    ring.head:SetPoint("CENTER", ring, "CENTER", hx, hy)
    ring.tip:ClearAllPoints()
    ring.tip:SetPoint("CENTER", ring, "CENTER", hx, hy)
    ring.head:Show()
    ring.tip:Show()
    if inZone and wantsTwist then
        ring.head:SetVertexColor(1, 0.6, 0.25, 1)
        ring.glow:SetAlpha(0.25 + 0.25 * pulse)
    else
        ring.head:SetVertexColor(1, 0.92, 0.66, 0.9)
        ring.glow:SetAlpha(0)
    end
    local ft = flashAt and (now - flashAt) / 0.35 or 1
    ring.flash:SetAlpha(ft < 1 and 0.6 * (1 - Ease(ft)) or 0)

    local seal = ST.state.seal
    frame.seal:SetShown(seal ~= nil)
    if seal then
        frame.seal.icon:SetTexture(ST.ICONS[seal])
        local left = (ST.state.sealExpires or 0) - now
        frame.seal.text:SetText(left > 0 and left < 6 and strformat("%d", left) or "")
    end

    if inZone and not zoneWasOpen and Get("sound", false) and wantsTwist then
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856, "Master")
    end
    zoneWasOpen = inZone

    -- the next press in the middle: dimmed until due, a small pop when it changes
    local big = frame.big
    if first then
        local dt = first.at - now
        local waiting = first.key == "wait"
        local nowPress = dt <= 0.05 and not waiting
        if first.key ~= shownKey then shownKey, shownAt = first.key, now end
        local pop = min(1, (now - shownAt) / 0.18)
        big:SetScale(0.82 + 0.18 * Ease(pop))
        big.icon:SetTexture(ST.ICONS[first.key])
        big.icon:SetDesaturated(waiting)
        big.shade:SetAlpha(nowPress and 0 or 0.45)
        local name = StepText(first, now)
        big.name:SetText(name)
        if waiting then big.name:SetTextColor(0.62, 0.58, 0.48)
        elseif wantsTwist then big.name:SetTextColor(1, 0.66, 0.34)
        else big.name:SetTextColor(1, 0.88, 0.54) end
        if waiting then big.hint:SetText("hold")
        elseif nowPress then big.hint:SetText(wantsTwist and "twist now" or "now")
        else big.hint:SetText(strformat("%.1f", dt)) end
        if nowPress then big.hint:SetTextColor(1, 0.86, 0.5) else big.hint:SetTextColor(0.7, 0.66, 0.56) end
    end
    local si = 1
    for i = 2, #steps do
        if si > 2 then break end
        local st = steps[i]
        if st.key ~= "wait" then
            local s = frame.small[si]
            s.icon:SetTexture(ST.ICONS[st.key])
            s:Show()
            si = si + 1
        end
    end
    for i = si, 3 do frame.small[i]:Hide() end

    -- lane
    local lane = frame.lane
    if lane:IsShown() then
        local lw = LANE_W
        local t0 = now - LANE_BACK
        local function X(t) return (t - t0) / LANE_SPAN * lw end
        local twistAt = {}
        for _, st in ipairs(steps) do if st.twist then twistAt[floor(st.twist * 10 + 0.5)] = true end end
        local ts = nxt - speed
        for i = 1, 4 do
            local tick, win = lane.ticks[i], lane.windows[i]
            local x = X(ts)
            if x >= 0 and x <= lw then
                local tw = twistAt[floor(ts * 10 + 0.5)]
                tick:ClearAllPoints()
                tick:SetPoint("TOP", lane, "TOPLEFT", x, 3)
                tick:SetPoint("BOTTOM", lane, "BOTTOMLEFT", x, -3)
                tick:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], tw and 1 or 0.35)
                tick:Show()
                local wx0, wx1 = max(0, X(ts - ST.OVERLAP - lat)), min(lw, X(ts - lat))
                if tw and wx1 > wx0 then
                    win:ClearAllPoints()
                    win:SetPoint("TOPLEFT", lane, "TOPLEFT", wx0, 0)
                    win:SetPoint("BOTTOMLEFT", lane, "BOTTOMLEFT", wx0, 0)
                    win:SetWidth(wx1 - wx0)
                    win:Show()
                else win:Hide() end
            else
                tick:Hide()
                win:Hide()
            end
            ts = ts + speed
        end
        local bi = 1
        for _, st in ipairs(steps) do
            if st.key ~= "wait" and bi <= #lane.blocks then
                local b = lane.blocks[bi]
                local at = max(st.at, now)          -- a due press sits on the now line until it is made
                local x0, x1 = max(0, X(at)), min(lw, X(at + (st.key == "judge" and 0.4 or snap.gcd)))
                if x1 - x0 > 6 then
                    b:ClearAllPoints()
                    b:SetPoint("LEFT", lane, "LEFT", x0 + 1, 0)
                    b:SetWidth(x1 - x0 - 2)
                    b.icon:SetTexture(ST.ICONS[st.key])
                    b.name:SetText(x1 - x0 > 70 and Short(st.key) or "")
                    if FILLERS[st.key] then
                        b.bg:SetVertexColor(FILLER[1], FILLER[2], FILLER[3], 0.22)
                        b.line:SetVertexColor(FILLER[1], FILLER[2], FILLER[3], 0.7)
                        b.name:SetTextColor(0.66, 0.84, 1)
                    else
                        b.bg:SetVertexColor(1, 1, 1, 0.07)
                        b.line:SetVertexColor(1, 1, 1, 0.16)
                        b.name:SetTextColor(0.94, 0.89, 0.74)
                    end
                    b:Show()
                    bi = bi + 1
                end
            end
        end
        for i = bi, #lane.blocks do lane.blocks[i]:Hide() end
        lane.gain:SetText("")
    end
end

function HUD:Refresh()
    if not ST.active then
        if frame then frame:Hide() end
        return
    end
    if not frame then Build() end
    self:Layout()
    self:UpdateVisibility()
end

function HUD:OnLogin()
    ST = ns.SwingTimer
    if not ST then return end
    ns:On("SWING_STATE", function() HUD:Refresh() end)
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and path:find("^swing") and path ~= "swing.reports" and path ~= "swing.values"
            and path ~= "swing.pos" then HUD:Refresh() end
    end)
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function() HUD:UpdateVisibility() end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if C_Timer then C_Timer.After(1.5, function() HUD:UpdateVisibility() end) else HUD:UpdateVisibility() end
    end)
    self:Refresh()
end

-- The kit's Settings section (UI/Settings.lua gives every class tool one; this one shows for Retribution only).
if ns.ClassKit then ns.ClassKit:Extend("swing", { iconPath = "Interface\\Icons\\Spell_Holy_SealOfBlood",
    settings = function(S, sec)
    S:SwitchSetting(sec, "Swing timer", "Seal twisting for Retribution: when to press Seal of Blood, and what fits between.",
        "swing.enabled", true, "Only shows on a Retribution Paladin. /dz swing unlock lets you drag it.")
    S:DropdownSetting(sec, "Look", "The twist bar, the plan lane (the next 7 seconds) or both.", "swing.style", "bar", {
        { value = "bar", text = "Twist bar" }, { value = "lane", text = "Plan lane" }, { value = "both", text = "Both" } })
    S:SwitchSetting(sec, "Show out of combat", "Keep it on screen when you are not fighting.", "swing.idle", false)
    S:SwitchSetting(sec, "Locked", "Unlock to drag it where you want it.", "swing.locked", true)
    local scales = {}
    for _, n in ipairs({ 0.8, 0.9, 1, 1.15, 1.3, 1.5 }) do scales[#scales + 1] = { value = n, text = floor(n * 100) .. "%" } end
    S:DropdownSetting(sec, "Size", "", "swing.scale", 1, scales)
    local lats = { { value = 0, text = "Auto" } }
    for _, n in ipairs({ 20, 40, 60, 80, 100, 150, 200, 300 }) do lats[#lats + 1] = { value = n, text = n .. " ms" } end
    S:DropdownSetting(sec, "Latency", "Moves the press zone earlier. Auto measures it for you.",
        "swing.latencyMs", 0, lats, "Auto averages your world latency with what it measures from your own seal casts "
            .. "(the time from pressing to the seal landing). /dz swing shows both.")
    S:SwitchSetting(sec, "Exorcism", "On demons and undead. Off in WoWSims' rotation: turn on only if your sim says so.", "swing.use.exo", false)
    S:SwitchSetting(sec, "Consecration", "Off in WoWSims' rotation: turn on only if your sim says so.", "swing.use.cons", false)
    local manas = {}
    for _, n in ipairs({ 0, 20, 30, 40, 50, 60, 80 }) do manas[#manas + 1] = { value = n, text = n .. "%" } end
    S:DropdownSetting(sec, "Consecration above", "Only suggest it with at least this much mana.", "swing.consMana", 40, manas)
    S:SwitchSetting(sec, "Sound in the twist zone", "A click when it is time to press Seal of Blood.", "swing.sound", false)
    local row = S:Row(sec, "Last fight", "")
    row.hasDesc = true
    S.PlaceText(row, 0)
    S.refreshers[#S.refreshers + 1] = {
        Refresh = function()
            local r = ns.SwingTimer and ns.SwingTimer:Reports()[1]
            if not r then row.desc:SetText("No fight yet. /dz swing report prints the latest one.") return end
            local c = r.counts or {}
            local tw, late, clip = c.twist or 0, c.late or 0, c.clip or 0
            local f = r.fillers or {}
            local fill = (f.exo or 0) + (f.cons or 0) + (f.how or 0)
            row.desc:SetText(strformat("%s: %d/%d twists landed, %d late, %d clipped, %d fillers.",
                r.target or "Fight", tw, tw + late + clip, late, clip, fill))
        end,
    }
    S:EndSection(sec)
end }) end

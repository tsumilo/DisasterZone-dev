if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SwingTimerHUD.lua", ...) then return end -- DisasterZone: swing timer HUD.
-- The on-screen part of Core/SwingTimer.lua, built to the mockup (dev kit dev/art/casc/swing_mockup):
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

local BAR_W, BAR_H = 440, 24
local BIG, SMALL, SIDE = 56, 34, 38
local LANE_W, LANE_H, LANE_SPAN, LANE_BACK = 500, 46, 7.5, 0.5
local STATUSBAR = "Interface\\TargetingFrame\\UI-StatusBar"
local SPARK = "Interface\\CastingBar\\UI-CastingBar-Spark"
local HALO = "Interface\\Buttons\\UI-ActionButton-Border"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local FRIZ = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local NARROW = "Fonts\\ARIALN.TTF"
local GOLD = { 0.95, 0.74, 0.30 }
local RIM = { 0.79, 0.64, 0.29 }
local ZONE = { 1.0, 0.56, 0.20 }
local FILLER = { 0.45, 0.72, 1.0 }
local KIND_COLOR = { twist = { 0.31, 0.83, 0.42 }, late = { 0.89, 0.70, 0.24 }, clip = { 0.88, 0.38, 0.31 },
    plain = { 0.30, 0.30, 0.34 } }
local FILLERS = { exo = true, cons = true }

local ST                         -- ns.SwingTimer
local frame
local zoneWasOpen

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

-- A panel: black edge, a thin gold rim, a dark fill and a soft shadow under it.
local function Panel(f, alpha)
    local sh = Tex(f, "BACKGROUND", WHITE, 0, 0, 0, 0.35, -8)
    sh:SetPoint("TOPLEFT", -8, 6)
    sh:SetPoint("BOTTOMRIGHT", 8, -10)
    local edge = Tex(f, "BACKGROUND", WHITE, 0, 0, 0, 1, -7)
    edge:SetPoint("TOPLEFT", -4, 4)
    edge:SetPoint("BOTTOMRIGHT", 4, -4)
    local rim = Tex(f, "BACKGROUND", WHITE, RIM[1], RIM[2], RIM[3], 0.5, -6)
    rim:SetPoint("TOPLEFT", -3, 3)
    rim:SetPoint("BOTTOMRIGHT", 3, -3)
    local fill = Tex(f, "BACKGROUND", WHITE, 0.03, 0.03, 0.04, alpha or 0.88, -5)
    fill:SetPoint("TOPLEFT", -2, 2)
    fill:SetPoint("BOTTOMRIGHT", 2, -2)
end

-- An icon with a black edge (the client's icons with their own border trimmed); gold = the gold frame of the next press.
local function Icon(parent, size, gold)
    local h = CreateFrame("Frame", nil, parent)
    h:SetSize(size, size)
    if gold then
        h.halo = Tex(h, "BACKGROUND", HALO, 1, 0.72, 0.3, 0.9, -8)
        h.halo:SetBlendMode("ADD")
        h.halo:SetPoint("CENTER")
        h.halo:SetSize(size * 1.95, size * 1.95)
        local g = Tex(h, "BACKGROUND", WHITE, 1, 0.84, 0.42, 1, -7)
        g:SetPoint("TOPLEFT", -3, 3)
        g:SetPoint("BOTTOMRIGHT", 3, -3)
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

local function SavePos()
    local p, _, rp, x, y = frame:GetPoint()
    ns.DB:SetSetting("swing.pos", { p, rp, floor(x + 0.5), floor(y + 0.5) })
end

local function Build()
    frame = CreateFrame("Frame", "DisasterZoneSwingTimer", UIParent)
    frame:SetSize(LANE_W + 40, 330)
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

    -- bar
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetSize(BAR_W, BAR_H)
    bar:SetPoint("CENTER", frame, "CENTER", 0, -20)
    frame.bar = bar
    Panel(bar)
    bar.server = Tex(bar, "ARTWORK", WHITE, 0.63, 0.16, 0.12, 0.38, 1)
    bar.server:SetPoint("TOP")
    bar.server:SetPoint("BOTTOM")
    bar.server:SetPoint("RIGHT")
    bar.fill = Tex(bar, "ARTWORK", STATUSBAR, nil, nil, nil, nil, 2)
    bar.fill:SetPoint("TOPLEFT")
    bar.fill:SetPoint("BOTTOMLEFT")
    bar.zone = Tex(bar, "ARTWORK", WHITE, nil, nil, nil, nil, 3)
    bar.zone:SetPoint("TOP")
    bar.zone:SetPoint("BOTTOM")
    Gradient(bar.zone, "VERTICAL", 0.95, 0.42, 0.12, 0.9, 1, 0.70, 0.32, 0.9)
    bar.zoneTop = Tex(bar, "OVERLAY", WHITE, 1, 0.86, 0.59, 0.9)
    bar.zoneTop:SetHeight(1)
    bar.zoneTop:SetPoint("TOPLEFT", bar.zone, "TOPLEFT")
    bar.zoneTop:SetPoint("TOPRIGHT", bar.zone, "TOPRIGHT")
    bar.zoneBot = Tex(bar, "OVERLAY", WHITE, 1, 0.86, 0.59, 0.9)
    bar.zoneBot:SetHeight(1)
    bar.zoneBot:SetPoint("BOTTOMLEFT", bar.zone, "BOTTOMLEFT")
    bar.zoneBot:SetPoint("BOTTOMRIGHT", bar.zone, "BOTTOMRIGHT")
    bar.edge = Tex(bar, "OVERLAY", WHITE, 1, 0.89, 0.63, 1)
    bar.edge:SetSize(2, BAR_H + 10)
    bar.edge:SetPoint("CENTER", bar, "RIGHT", 0, 0)
    bar.spark = Tex(bar, "OVERLAY", SPARK)
    bar.spark:SetBlendMode("ADD")
    bar.spark:SetSize(30, BAR_H * 2.3)
    bar.left = Font(bar, NARROW, 15, 1, 1, 1)
    bar.left:SetPoint("LEFT", 8, 0)
    bar.right = Font(bar, NARROW, 15, 1, 1, 1)
    bar.right:SetPoint("RIGHT", bar.zone, "LEFT", -6, 0)
    bar.rest = Font(bar, FRIZ, 12, 0.62, 0.58, 0.48)
    bar.rest:SetPoint("CENTER")
    bar.rest:SetText("Start attacking: the timer follows your swings")
    bar.zoneText = Font(bar, FRIZ, 13, 1, 0.70, 0.42)
    bar.zoneText:SetPoint("BOTTOMLEFT", bar.zone, "TOPLEFT", 2, 6)
    bar.zoneText:SetText("twist")
    bar.bracket = Tex(bar, "OVERLAY", WHITE, 1, 0.81, 0.54, 0.9)
    bar.bracket:SetHeight(1)
    bar.lat = Font(bar, NARROW, 13, 1, 0.81, 0.54)
    bar.lat:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -6)
    -- GCD ghost
    bar.gcdBg = Tex(bar, "BORDER", WHITE, 1, 1, 1, 0.07)
    bar.gcdBg:SetHeight(4)
    bar.gcdBg:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -10)
    bar.gcdBg:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", -46, -10)
    bar.gcd = Tex(bar, "ARTWORK", WHITE, 0.44, 0.72, 1, 1)
    bar.gcd:SetHeight(4)
    -- weapon and seal
    frame.weapon = Icon(frame, SIDE)
    frame.weapon:SetPoint("RIGHT", bar, "LEFT", -16, 0)
    frame.seal = Icon(frame, SIDE)
    frame.seal:SetPoint("LEFT", bar, "RIGHT", 16, 0)
    local sl = Font(frame, FRIZ, 9, 0.6, 0.57, 0.48)
    sl:SetPoint("BOTTOM", frame.seal, "TOP", 0, 4)
    sl:SetText("SEAL")
    frame.seal.label = sl
    -- recent swings
    frame.dots = {}
    for i = 1, 12 do
        local d = Tex(frame, "ARTWORK", WHITE)
        d:SetSize(9, 5)
        d:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", (i - 1) * 12, -20)
        frame.dots[i] = d
    end

    -- queue
    local q = CreateFrame("Frame", nil, frame)
    q:SetSize(LANE_W, BIG + 70)
    q:SetPoint("BOTTOM", bar, "TOP", 0, 26)
    frame.queue = q
    local cap = Font(q, FRIZ, 11, 0.79, 0.73, 0.54)
    cap:SetPoint("TOP", q, "TOP", 0, 0)
    cap:SetText("N E X T")
    local big = Icon(q, BIG, true)
    big:SetPoint("TOP", cap, "BOTTOM", 0, -9)
    frame.big = big
    big.name = Font(q, FRIZ, 20, 1, 0.88, 0.54)
    big.name:SetPoint("TOP", big, "BOTTOM", 0, -8)
    big.hint = Font(q, FRIZ, 13, 0.91, 0.85, 0.68)
    big.hint:SetPoint("TOP", big.name, "BOTTOM", 0, -3)
    frame.small = {}
    for i = 1, 3 do
        local s = Icon(q, SMALL)
        s:SetPoint("LEFT", big, "RIGHT", 22 + (i - 1) * (SMALL + 14), 10)
        s.icon:SetVertexColor(0.85, 0.85, 0.85)
        frame.small[i] = s
    end
    frame.judge = Icon(q, SMALL)
    frame.judge:SetPoint("RIGHT", big, "LEFT", -22, 10)
    frame.judge.icon:SetTexture(ST.ICONS.judge)
    local og = Font(q, FRIZ, 9, 0.6, 0.57, 0.48)
    og:SetPoint("BOTTOM", frame.judge, "TOP", 0, 5)
    og:SetText("OFF GCD")
    frame.judgeLabel = og

    -- lane
    local lane = CreateFrame("Frame", nil, frame)
    lane:SetSize(LANE_W, LANE_H)
    lane:SetPoint("TOP", bar, "BOTTOM", 0, -44)
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
    if key == "wait" then hint = "nothing fits before the twist"
    elseif key == "sob" and step.twist then hint = dt > 0.05 and "wait for the orange zone" or "press now · twist lands on this swing"
    elseif dt > 0.05 then hint = ""
    elseif FILLERS[key] then hint = "filler · fits before the twist"
    else hint = "press now" end
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
    frame.weapon:Hide()
    frame.seal:SetShown(showBar)
    frame.seal.label:Hide()
    for _, d in ipairs(frame.dots) do d:Hide() end
    frame.lane:ClearAllPoints()
    if showBar then frame.lane:SetPoint("TOP", frame.bar, "BOTTOM", 0, -44)
    else frame.lane:SetPoint("TOP", frame.queue, "BOTTOM", 0, -12) end
    frame.laneWanted = showLane
    local locked = Get("locked", true)
    frame.mover:SetShown(not locked)
    frame.moverText:SetShown(not locked)
    frame:EnableMouse(not locked)
end

function HUD:UpdateVisibility()
    if not frame then return end
    local show = ST.active and (not Get("locked", true) or Get("idle", false) or InCombatLockdown()
        or UnitAffectingCombat("player"))
    frame:SetShown(show and true or false)
end

-- Resting: auto attack is not running, so there is nothing to time. An empty bar, the rest hidden.
local function Rest()
    local bar = frame.bar
    frame.queue:Hide()
    frame.lane:Hide()
    bar.fill:Hide()
    bar.spark:Hide()
    for _, t in ipairs({ bar.zone, bar.zoneTop, bar.zoneBot, bar.zoneText, bar.bracket, bar.gcd }) do t:Hide() end
    bar.left:SetText("")
    bar.right:SetText("")
    bar.lat:SetText("")
    bar.rest:Show()
    frame.weapon.icon:SetTexture(GetInventoryItemTexture("player", 16) or ST.ICONS.wait)
    frame.weapon.text:SetText(strformat("%.2f", ST.state.speed or 0))
    local seal = ST.state.seal
    frame.seal:SetShown(seal ~= nil and bar:IsShown())
    if seal then frame.seal.icon:SetTexture(ST.ICONS[seal]); frame.seal.text:SetText("") end
end

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
    frame.queue:Show()
    frame.lane:SetShown(frame.laneWanted)

    local bar = frame.bar
    if bar:IsShown() then
        local w = BAR_W
        bar.rest:Hide()
        bar.fill:Show()
        bar.spark:Show()
        bar.fill:SetWidth(max(1, frac * w))
        if inZone and wantsTwist then
            Gradient(bar.fill, "VERTICAL", 0.80, 0.36, 0.12, 1, 1, 0.66, 0.30, 1)
        else
            Gradient(bar.fill, "VERTICAL", 0.72, 0.50, 0.15, 1, 1, 0.82, 0.40, 1)
        end
        local start = nxt - speed
        local z0 = max(0, (zone0 - start) / speed)
        local z1 = min(1, (zone1 - start) / speed)
        bar.zone:ClearAllPoints()
        bar.zone:SetPoint("TOP")
        bar.zone:SetPoint("BOTTOM")
        bar.zone:SetPoint("LEFT", bar, "LEFT", z0 * w, 0)
        bar.zone:SetWidth(max(1, (z1 - z0) * w))
        bar.zone:SetAlpha(inZone and 1 or 0.6)
        for _, t in ipairs({ bar.zone, bar.zoneTop, bar.zoneBot, bar.zoneText }) do t:Show() end
        bar.server:SetWidth(ST.OVERLAP / speed * w)
        bar.spark:ClearAllPoints()
        bar.spark:SetPoint("CENTER", bar, "LEFT", frac * w, 0)
        bar.left:SetText("")
        bar.right:SetText("")
        -- latency bracket: from the zone's late edge to the swing
        bar.bracket:ClearAllPoints()
        bar.bracket:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", z1 * w, -3)
        bar.bracket:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -3)
        bar.bracket:Show()
        bar.lat:SetText(strformat("%d ms", floor(lat * 1000 + 0.5)))
        -- GCD ghost from now
        local g1 = min(1, frac + ST.GCD / speed)
        local gw = w - 46
        bar.gcd:ClearAllPoints()
        bar.gcd:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", frac * gw, -10)
        bar.gcd:SetWidth(max(1, (g1 - frac) * gw))
        local clips = wantsTwist and now < zone0 and now + ST.GCD > zone0
        bar.gcd:SetShown(clips and true or false)
        bar.gcdBg:SetShown(clips and true or false)
        bar.gcd:SetVertexColor(0.95, 0.42, 0.35, 1)
        local seal = ST.state.seal
        frame.seal:SetShown(seal ~= nil)
        if seal then
            frame.seal.icon:SetTexture(ST.ICONS[seal])
            local left = (ST.state.sealExpires or 0) - now
            frame.seal.text:SetText(left > 0 and left < 6 and strformat("%ds", left) or "")
        end
        local rec = {}
        for i = 1, 0 do
            local r = rec[#rec - 12 + i]
            local d = frame.dots[i]
            if r then
                local c = KIND_COLOR[r.kind] or KIND_COLOR.plain
                d:SetVertexColor(c[1], c[2], c[3], 1)
                d:Show()
            else d:Hide() end
        end
    end

    if inZone and not zoneWasOpen and Get("sound", false) and wantsTwist then
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856, "Master")
    end
    zoneWasOpen = inZone

    -- queue
    local big = frame.big
    if first then
        local dt = first.at - now
        local nowPress = dt <= 0.05 and first.key ~= "wait"
        local waiting = first.key == "wait"
        big.icon:SetTexture(ST.ICONS[first.key])
        local name, hint = StepText(first, now)
        big.name:SetText(name)
        if waiting then big.name:SetTextColor(0.62, 0.58, 0.48) else big.name:SetTextColor(1, 0.88, 0.54) end
        big.hint:SetText(hint)
        big.center:SetText("")
        big.icon:SetDesaturated(waiting)
        big.icon:SetAlpha(nowPress and 1 or 0.55)
        big.goldRim:SetAlpha(nowPress and 1 or 0.35)
        big.halo:SetShown(nowPress)
        if nowPress then big.halo:SetAlpha(0.65 + 0.35 * sin(now * 7)) end
    end
    local si = 1
    for i = 2, #steps do
        if si > 2 then break end
        local st = steps[i]
        if st.key ~= "wait" then
            local s = frame.small[si]
            s.icon:SetTexture(ST.ICONS[st.key])
            s.text:SetText("")
            s:Show()
            si = si + 1
        end
    end
    for i = si, 3 do frame.small[i]:Hide() end
    frame.small[3]:Hide()
    local j = frame.judge
    local jLeft = snap.judgeReady - now
    j:SetShown(cur.judge and jLeft <= 0.05 or false)
    j.text:SetText("")
    frame.judgeLabel:SetShown(j:IsShown())

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
                local x0, x1 = max(0, X(st.at)), min(lw, X(st.at + ST.GCD))
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
        if cur ~= lane.gainFor then
            lane.gainFor = cur
            local usesFiller
            for _, st in ipairs(steps) do if FILLERS[st.key] then usesFiller = true end end
            local g = usesFiller and select(2, pcall(ST.PlanGain, snap, cur.plan))
            lane.gain:SetText(type(g) == "number" and g > 0.5 and strformat("fillers +%d dps", floor(g + 0.5)) or "")
        end
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

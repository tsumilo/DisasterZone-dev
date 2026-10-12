if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SwingTimerHUD.lua", ...) then return end -- DisasterZone: swing timer HUD.
-- The on-screen part of Core/SwingTimer.lua. The swing is a ring of flat strokes around the next press: gold fills
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
-- The frame is a UI:CreateHudFrame (no look of its own: the ring is the face; locked by swing.locked, its place kept in
-- swing.pos as before); while unlocked it shows the shared info notice. Texts are UI:Text on the type scale, the
-- lane the HUD surface (ns.Style HUD_BG), its colours the tokens (D1: the deep gold for the swing ticks). The ring's
-- 200 strokes and their colours are drawn here: no component draws a swing ring.
local addonName, ns = ...

local HUD = ns:NewModule("SwingTimerHUD")
local UI = ns.UI
local S = ns.Style

local floor, max, min, sin = math.floor, math.max, math.min, math.sin
local strformat = string.format

local RING, RING_R, DOTS, DOT = 128, 54, 200, 6
local BIG, SMALL, SIDE = 70, 28, 22
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SOFT = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"   -- white, alpha fading out from the center
local LANE_W, LANE_H, LANE_SPAN, LANE_BACK = 500, 46, 7.5, 0.5
local WHITE = "Interface\\Buttons\\WHITE8X8"
local NARROW = S.FONT_NUM
local GOLD = S.C.GOLD_DEEP                 -- (D1: the swing ticks are fills)
local ZONE = { 1.0, 0.56, 0.20 }
local FILLER = S.C.YOU                     -- (a filler's block: the blue of "you can fit this")
local FILLERS = { exo = true, cons = true }

local ST                         -- ns.SwingTimer
local frame
local zoneWasOpen
local lastNext, flashAt, shownKey, shownAt, lastExtra = nil, nil, nil, 0, nil
local rested, restWeapon, restSeal = false, nil, nil   -- (Rest's look is on, for this weapon and seal)

local function Get(path, default) return ST.Get(path, default) end

-- A texture of the ring (a path, white by default) tinted r, g, b, a (the ring's parts are coloured each frame).
local function Part(parent, layer, path, r, g, b, a, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub)
    t:SetTexture(path or WHITE)
    if r then t:SetVertexColor(r, g, b, a or 1) end
    return t
end

-- Crops a texture to a circle where the client has mask textures.
local function Round(holder, tex)
    if not holder.CreateMaskTexture then return end
    local m = holder:CreateMaskTexture()
    m:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    m:SetAllPoints(tex)
    tex:AddMaskTexture(m)
end

-- (where it sits: swing.pos, as before)
local function SavePos()
    local p, _, rp, x, y = frame:GetPoint()
    ns.DB:SetSetting("swing.pos", { p, rp, floor(x + 0.5), floor(y + 0.5) })
end

local function Build()
    frame = UI:CreateHudFrame("DisasterZoneSwingTimer", { width = LANE_W + 40, height = 260, look = "none",
        position = false, strata = "MEDIUM", isLocked = function() return Get("locked", true) and true or false end,
        onMoved = SavePos })
    local pos = Get("pos")
    frame:ClearAllPoints()
    if type(pos) == "table" and pos[1] then frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else frame:SetPoint("CENTER", UIParent, "CENTER", 0, -170) end

    -- unlocked: a faint wash over its place and the shared notice saying how to lock it
    local you = S.C.YOU
    frame.mover = UI:Fill(frame, { you[1], you[2], you[3], 0.15 }, "BACKGROUND", -8)
    frame.moverText = UI:CreateNotice(frame, "info", "Swing timer: drag it, then /dz swing lock")
    frame.moverText:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    frame.moverText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)

    -- the ring (kept as frame.bar so Layout's bar/lane switch still works)
    local ring = CreateFrame("Frame", nil, frame)
    ring:SetSize(RING, RING)
    ring:SetPoint("TOP", frame, "TOP", 0, -20)
    frame.bar = ring
    ring.glow = Part(ring, "BACKGROUND", SOFT, ZONE[1], ZONE[2], ZONE[3], 0, -8)
    ring.glow:SetBlendMode("ADD")
    ring.glow:SetPoint("CENTER")
    ring.glow:SetSize(RING * 1.9, RING * 1.9)
    ring.well = Part(ring, "BACKGROUND", DISC, 0, 0, 0, 0.55, -6)
    ring.well:SetPoint("CENTER")
    ring.well:SetSize(RING_R * 2 + 12, RING_R * 2 + 12)
    -- the band is 200 short radial strokes, not discs, so where one color meets the next the edge is cut flat
    -- (discs left a round cap at every color change and at the fill's end)
    ring.dots = {}
    local thick = 2 * math.pi * (RING_R + DOT / 2) / DOTS + 0.7   -- a little overlap: no gaps on the outer edge
    for i = 1, DOTS do
        local f = (i - 0.5) / DOTS
        local a = math.pi / 2 - 2 * math.pi * f
        local c, s = math.cos(a), math.sin(a)
        local d = ring:CreateLine(nil, "ARTWORK")
        d:SetColorTexture(1, 1, 1, 1)
        d:SetThickness(thick)
        d:SetStartPoint("CENTER", ring, (RING_R - DOT / 2) * c, (RING_R - DOT / 2) * s)
        d:SetEndPoint("CENTER", ring, (RING_R + DOT / 2) * c, (RING_R + DOT / 2) * s)
        d.f = f
        ring.dots[i] = d
    end
    ring.head = Part(ring, "OVERLAY", SOFT, 1, 0.92, 0.66, 0.9)
    ring.head:SetBlendMode("ADD")
    ring.head:SetSize(DOT * 5, DOT * 5)
    ring.tip = ring:CreateLine(nil, "OVERLAY", nil, 1)   -- a flat bright edge where the fill ends
    ring.tip:SetColorTexture(1, 1, 1, 1)
    ring.tip:SetThickness(2)
    ring.flash = Part(ring, "BACKGROUND", SOFT, 1, 0.86, 0.5, 0, 2)
    ring.flash:SetBlendMode("ADD")
    ring.flash:SetPoint("CENTER")
    ring.flash:SetSize(RING * 1.9, RING * 1.9)

    -- the next press, round, in the middle
    local big = CreateFrame("Frame", nil, ring)
    big:SetSize(BIG, BIG)
    big:SetPoint("CENTER")
    big.icon = Part(big, "ARTWORK")
    big.icon:SetAllPoints()
    big.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    Round(big, big.icon)
    big.shade = Part(big, "OVERLAY", DISC, 0, 0, 0, 0)
    big.shade:SetAllPoints()
    frame.big = big

    -- the seal, a small badge on the ring's lower right
    local seal = CreateFrame("Frame", nil, ring)
    seal:SetSize(SIDE, SIDE)
    seal:SetPoint("CENTER", ring, "CENTER", RING_R * 0.72, -RING_R * 0.72)
    seal:SetFrameLevel(ring:GetFrameLevel() + 3)
    local sb = Part(seal, "BACKGROUND", DISC, 0, 0, 0, 1)
    sb:SetPoint("CENTER")
    sb:SetSize(SIDE + 4, SIDE + 4)
    seal.icon = Part(seal, "ARTWORK")
    seal.icon:SetAllPoints()
    seal.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    Round(seal, seal.icon)
    seal.text = UI:Text(seal, "small", { 1, 1, 1 }, { font = NARROW, flags = "OUTLINE", justify = "CENTER" })
    seal.text:SetPoint("CENTER", 0, 0)
    frame.seal = seal

    -- name and countdown to the right
    big.name = UI:Text(ring, "page", { 1, 0.88, 0.54 }, { shadow = true })
    big.name:SetPoint("LEFT", ring, "RIGHT", 6, 7)
    big.hint = UI:Text(ring, "emph", "SUB", { font = NARROW, shadow = true })
    big.hint:SetPoint("TOPLEFT", big.name, "BOTTOMLEFT", 0, -2)
    big.name:Hide()   -- the ring shows the time and the icon the spell: no text beside it
    big.hint:Hide()

    -- the presses after it, small and fading, to the left
    frame.small = {}
    for i = 1, 3 do
        local s = CreateFrame("Frame", nil, ring)
        local size = i == 1 and SMALL or SMALL - 6
        s:SetSize(size, size)
        s.icon = Part(s, "ARTWORK")
        s.icon:SetAllPoints()
        s.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        Round(s, s.icon)
        s.text = UI:Text(s, "small", { 1, 1, 1 }, { font = NARROW, shadow = true })
        s:SetAlpha(i == 1 and 0.8 or 0.45)
        if i == 1 then s:SetPoint("RIGHT", ring, "LEFT", -4, 0)
        else s:SetPoint("RIGHT", frame.small[i - 1], "LEFT", -6, 0) end
        frame.small[i] = s
    end
    frame.dots = {}

    -- lane: the HUD surface with a black edge, a hairline each second, the now line
    local lane = CreateFrame("Frame", nil, frame)
    lane:SetSize(LANE_W, LANE_H)
    lane:SetPoint("TOP", ring, "BOTTOM", 0, -14)
    frame.lane = lane
    lane.bg = UI:Fill(lane, "HUD_BG", "BACKGROUND", -5)
    UI:AddEdges(lane, "BACKGROUND")
    UI:SetEdgeColor(lane, 0, 0, 0, 0.9)
    for s = 1, 7 do
        local g = UI:Rule(lane, { vertical = true, color = "HOVER", layer = "BORDER",
            left = (s + LANE_BACK) / LANE_SPAN * LANE_W })
        lane["grid" .. s] = g
    end
    lane.now = UI:Fill(lane, { 1, 1, 1, 1 }, "OVERLAY")
    lane.now:ClearAllPoints()
    lane.now:SetWidth(2)
    lane.now:SetPoint("TOP", 0, 4)
    lane.now:SetPoint("BOTTOM", 0, -4)
    lane.now:SetPoint("LEFT", lane, "LEFT", LANE_BACK / LANE_SPAN * LANE_W, 0)
    lane.gain = UI:Text(lane, "body", "OK", { shadow = true })
    lane.gain:SetPoint("TOPRIGHT", lane, "BOTTOMRIGHT", 0, -6)
    lane.ticks, lane.windows, lane.blocks = {}, {}, {}
    for i = 1, 4 do
        local w = lane:CreateTexture(nil, "BORDER")
        UI:Gradient(w, "HORIZONTAL", { ZONE[1], ZONE[2], ZONE[3], 0.04 }, { ZONE[1], ZONE[2], ZONE[3], 0.38 })
        lane.windows[i] = w
        local t = Part(lane, "OVERLAY", WHITE, GOLD[1], GOLD[2], GOLD[3], 1)
        t:SetWidth(2)
        lane.ticks[i] = t
    end
    for i = 1, 6 do
        local b = CreateFrame("Frame", nil, lane)
        b:SetHeight(LANE_H - 12)
        b.bg = Part(b, "BACKGROUND")
        b.bg:SetAllPoints()
        b.line = Part(b, "BORDER")
        b.line:SetPoint("TOPLEFT")
        b.line:SetPoint("TOPRIGHT")
        b.line:SetHeight(1)
        b.icon = Part(b, "ARTWORK")
        b.icon:SetSize(LANE_H - 18, LANE_H - 18)
        b.icon:SetPoint("LEFT", 3, 0)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.name = UI:Text(b, "emph", "TEXT", { font = NARROW, shadow = true })
        b.name:SetPoint("LEFT", b.icon, "RIGHT", 5, 0)
        b.name:SetPoint("RIGHT", b, "RIGHT", -3, 0)
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
    rested = false
    local style = ST.practice and "bar" or Get("style", "bar")   -- practice puts its own parts under the ring
    frame:SetScale(tonumber(Get("scale", 1)) or 1)
    local showBar, showLane = style ~= "lane", style ~= "bar"
    frame.bar:SetShown(showBar)
    frame.lane:ClearAllPoints()
    if showBar then frame.lane:SetPoint("TOP", frame.bar, "BOTTOM", 0, -14)
    else frame.lane:SetPoint("TOP", frame, "TOP", 0, -20) end
    frame.laneWanted = showLane
    local locked = Get("locked", true)
    frame.mover:SetShown(not locked and not ST.practice)
    frame.moverText:SetShown(not locked and not ST.practice)
    frame:EnableMouse(not locked and not ST.practice)
end

-- The ring's frame (twist practice puts its parts around it).
function HUD:Ring() return frame and frame.bar end

function HUD:UpdateVisibility()
    if not frame then return end
    local show = ST.active and (ST.practice or not Get("locked", true) or Get("idle", false) or InCombatLockdown()
        or UnitAffectingCombat("player") or ST:IsDemo())
    frame:SetShown(show and true or false)
end

-- Resting: auto attack is not running, so there is nothing to time. A faint empty ring, the rest hidden.
-- (drawn once, then again only when the weapon or the seal changes: repainting the 200 dots every idle frame was
-- the addon's top CPU handler out of combat; Performance page 2026-10-11)
local function Rest()
    local weapon = GetInventoryItemTexture("player", 16) or ST.ICONS.wait
    local seal = ST.state.seal
    if rested and weapon == restWeapon and seal == restSeal then return end
    rested, restWeapon, restSeal = true, weapon, seal
    local ring = frame.bar
    frame.lane:Hide()
    ring:SetAlpha(0.35)
    for _, d in ipairs(ring.dots) do d:SetVertexColor(0.13, 0.13, 0.14) end
    ring.head:Hide()
    ring.tip:Hide()
    ring.glow:SetAlpha(0)
    ring.flash:SetAlpha(0)
    frame.big:SetScale(1)
    frame.big.icon:SetTexture(weapon)
    frame.big.icon:SetDesaturated(true)
    frame.big.shade:SetAlpha(0)
    frame.big.name:SetText("")
    frame.big.hint:SetText("")
    for _, s in ipairs(frame.small) do s:Hide() end
    frame.seal:SetShown(seal ~= nil)
    if seal then frame.seal.icon:SetTexture(ST.ICONS[seal]); frame.seal.text:SetText("") end
    lastNext, shownKey = nil, nil
end

local function Ease(x) return 1 - (1 - x) * (1 - x) end

function HUD:Update()
    local now = GetTime()
    local ok, cur = pcall(ST.Current, ST)
    if not ok or not cur then Rest() return end
    rested = false
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
    local c, s = math.cos(a), math.sin(a)
    ring.tip:SetStartPoint("CENTER", ring, (RING_R - DOT / 2) * c, (RING_R - DOT / 2) * s)
    ring.tip:SetEndPoint("CENTER", ring, (RING_R + DOT / 2) * c, (RING_R + DOT / 2) * s)
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
                        b.name:SetTextColor(S:Color("YOU"))
                    else
                        b.bg:SetVertexColor(S:Color("HAIRLINE"))
                        b.line:SetVertexColor(S:Color("EDGE"))
                        b.name:SetTextColor(S:Color("TEXT"))
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
            and path ~= "swing.pos" and not path:find("^swing%.practice") then HUD:Refresh() end
    end)
    ns:On("SWING_PRACTICE", function() HUD:Refresh() end)
    ns:RegisterEvent("PLAYER_REGEN_DISABLED", function() HUD:UpdateVisibility() end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if C_Timer then C_Timer.After(1.5, function() HUD:UpdateVisibility() end) else HUD:UpdateVisibility() end
    end)
    self:Refresh()
end

-- The kit's Settings section (UI/Settings.lua gives every class tool one; this one shows for Retribution only).
if ns.ClassKit then ns.ClassKit:Extend("swing", { iconPath = "Interface\\Icons\\Spell_Holy_SealOfBlood",
    action = { label = "Practice", width = 90, run = function() if ns.SwingPracticeUI then ns.SwingPracticeUI:Open() end end },
    settings = function(S, sec)
    -- (on/off is the switch on the card's header: swing.enabled)
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
    S:SwitchSetting(sec, "Sound in the twist zone", "A click when it is time to twist.", "swing.sound", false)
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

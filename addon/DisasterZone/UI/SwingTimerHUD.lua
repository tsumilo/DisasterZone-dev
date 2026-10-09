if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SwingTimerHUD.lua", ...) then return end -- DisasterZone: swing timer HUD.
-- The on-screen part of Core/SwingTimer.lua, drawn with the client's own cast bar art:
--   queue   the next press (big icon, its name and when), the three after it, Judgement (off the GCD) on the left
--   bar     the swing: gold fill and spark, the orange press zone (the twist window moved one round trip earlier),
--           the server's real window as a dim red edge, a blue line where a GCD pressed now would end (red when it
--           would run through the window), the weapon on the left and the seal on the right
--   lane    the planner's next ~7 s: swings, twist windows and every GCD block it placed (fillers in blue)
--   dots    the last swings: green twisted, gold late, red clipped, grey plain
-- Style (settings swing.style): "bar", "lane" or "both". Unlock with /dz swing unlock to drag it.
local addonName, ns = ...

local HUD = ns:NewModule("SwingTimerHUD")

local floor, max, min = math.floor, math.max, math.min
local strformat = string.format

local BAR_W, BAR_H = 360, 18
local BIG, SMALL = 42, 26
local LANE_H, LANE_SPAN, LANE_BACK = 40, 7.5, 0.5
local STATUSBAR = "Interface\\TargetingFrame\\UI-StatusBar"
local SPARK = "Interface\\CastingBar\\UI-CastingBar-Spark"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local GOLD = { 0.95, 0.72, 0.25 }
local ZONE = { 1.0, 0.52, 0.15 }
local FILLER = { 0.45, 0.72, 1.0 }
local KIND_COLOR = { twist = { 0.31, 0.83, 0.42 }, late = { 0.89, 0.70, 0.24 }, clip = { 0.88, 0.38, 0.31 },
    plain = { 0.30, 0.30, 0.34 } }
local FILLERS = { exo = true, cons = true, how = true }

local ST                         -- ns.SwingTimer
local frame
local lastPlanAt, cur = 0, nil
local zoneWasOpen

local function Get(path, default) return ST.Get(path, default) end

local function Tex(parent, layer, path, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetTexture(path or WHITE)
    if r then t:SetVertexColor(r, g, b, a or 1) end
    return t
end

local function Font(parent, size, r, g, b)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
    f:SetTextColor(r or 1, g or 0.86, b or 0.42)
    f:SetShadowOffset(1, -1)
    return f
end

-- An icon with a thin black edge (the client's icons with their own border trimmed off).
local function Icon(parent, size)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(size, size)
    local edge = Tex(holder, "BACKGROUND", WHITE, 0, 0, 0, 1)
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    holder.icon = Tex(holder, "ARTWORK")
    holder.icon:SetAllPoints()
    holder.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    holder.text = Font(holder, max(10, floor(size * 0.32)), 1, 1, 1)
    holder.text:SetPoint("TOP", holder, "BOTTOM", 0, -2)
    holder.center = Font(holder, max(11, floor(size * 0.38)), 1, 1, 1)
    holder.center:SetPoint("CENTER")
    return holder
end

local function Glow(f, on)
    local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
    if not LCG then return end
    if on and not f.glowing then
        LCG.PixelGlow_Start(f, { 1, 0.75, 0.3, 1 }, 10, 0.25, nil, 2, 0, 0, false, "dzswing")
        f.glowing = true
    elseif not on and f.glowing then
        LCG.PixelGlow_Stop(f, "dzswing")
        f.glowing = nil
    end
end

local function SavePos()
    local p, _, rp, x, y = frame:GetPoint()
    ns.DB:SetSetting("swing.pos", { p, rp, floor(x + 0.5), floor(y + 0.5) })
end

local function Build()
    frame = CreateFrame("Frame", "DisasterZoneSwingTimer", UIParent)
    frame:SetSize(BAR_W + 120, 200)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f) if not Get("locked", true) then f:StartMoving() end end)
    frame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing(); SavePos() end)
    local pos = Get("pos")
    if type(pos) == "table" and pos[1] then frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else frame:SetPoint("CENTER", UIParent, "CENTER", 0, -190) end

    -- unlock backdrop
    frame.mover = Tex(frame, "BACKGROUND", WHITE, 0.2, 0.6, 1, 0.18)
    frame.mover:SetAllPoints()
    frame.moverText = Font(frame, 12, 0.6, 0.85, 1)
    frame.moverText:SetPoint("TOP", 0, -2)
    frame.moverText:SetText("Swing timer: drag me, then /dz swing lock")

    -- bar
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetSize(BAR_W, BAR_H)
    bar:SetPoint("CENTER", frame, "CENTER", 0, -10)
    frame.bar = bar
    local edge = Tex(bar, "BACKGROUND", WHITE, 0, 0, 0, 0.9)
    edge:SetPoint("TOPLEFT", -3, 3)
    edge:SetPoint("BOTTOMRIGHT", 3, -3)
    local rim = Tex(bar, "BACKGROUND", WHITE, GOLD[1], GOLD[2], GOLD[3], 0.35)
    rim:SetPoint("TOPLEFT", -2, 2)
    rim:SetPoint("BOTTOMRIGHT", 2, -2)
    local bg = Tex(bar, "BORDER", WHITE, 0.05, 0.05, 0.06, 0.95)
    bg:SetAllPoints()
    bar.server = Tex(bar, "ARTWORK", WHITE, 0.65, 0.16, 0.12, 0.5)
    bar.server:SetPoint("TOP")
    bar.server:SetPoint("BOTTOM")
    bar.fill = Tex(bar, "ARTWORK", STATUSBAR, GOLD[1], GOLD[2], GOLD[3], 0.95)
    bar.fill:SetPoint("TOPLEFT")
    bar.fill:SetPoint("BOTTOMLEFT")
    bar.zone = Tex(bar, "OVERLAY", WHITE, ZONE[1], ZONE[2], ZONE[3], 0.55)
    bar.zone:SetBlendMode("ADD")
    bar.zone:SetPoint("TOP")
    bar.zone:SetPoint("BOTTOM")
    bar.spark = Tex(bar, "OVERLAY", SPARK)
    bar.spark:SetBlendMode("ADD")
    bar.spark:SetSize(24, BAR_H * 2.4)
    bar.left = Font(bar, 12, 1, 1, 1)
    bar.left:SetPoint("LEFT", 6, 0)
    bar.right = Font(bar, 12, 1, 1, 1)
    bar.right:SetPoint("RIGHT", bar.zone, "LEFT", -4, 0)
    bar.zoneText = Font(bar, 11, 1, 0.7, 0.42)
    bar.zoneText:SetPoint("BOTTOMLEFT", bar.zone, "TOPLEFT", 0, 4)
    bar.zoneText:SetText("twist")
    bar.lat = Font(bar, 10, 1, 0.8, 0.55)
    bar.lat:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -2)
    -- GCD ghost
    bar.gcdBg = Tex(bar, "BORDER", WHITE, 1, 1, 1, 0.07)
    bar.gcdBg:SetHeight(3)
    bar.gcdBg:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -6)
    bar.gcdBg:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", -40, -6)
    bar.gcd = Tex(bar, "ARTWORK", WHITE, 0.43, 0.72, 1, 0.9)
    bar.gcd:SetHeight(3)
    -- weapon and seal
    frame.weapon = Icon(frame, 30)
    frame.weapon:SetPoint("RIGHT", bar, "LEFT", -10, 0)
    frame.seal = Icon(frame, 30)
    frame.seal:SetPoint("LEFT", bar, "RIGHT", 10, 0)
    -- recent swings
    frame.dots = {}
    for i = 1, 12 do
        local d = Tex(frame, "ARTWORK", WHITE)
        d:SetSize(8, 5)
        d:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", (i - 1) * 10, -14)
        frame.dots[i] = d
    end

    -- queue
    local big = Icon(frame, BIG)
    big:SetPoint("BOTTOM", bar, "TOP", 0, 50)
    frame.big = big
    big.name = Font(frame, 15, 1, 0.86, 0.45)
    big.name:SetPoint("TOP", big, "BOTTOM", 0, -3)
    big.hint = Font(frame, 11, 0.85, 0.8, 0.68)
    big.hint:SetPoint("TOP", big.name, "BOTTOM", 0, -1)
    frame.small = {}
    for i = 1, 3 do
        local s = Icon(frame, SMALL)
        s:SetPoint("LEFT", big, "RIGHT", 18 + (i - 1) * (SMALL + 10), 0)
        s.icon:SetDesaturated(false)
        s:SetAlpha(0.85)
        frame.small[i] = s
    end
    frame.judge = Icon(frame, SMALL)
    frame.judge:SetPoint("RIGHT", big, "LEFT", -18, 0)
    frame.judge.icon:SetTexture(ST.ICONS.judge)
    local og = Font(frame, 9, 0.6, 0.57, 0.48)
    og:SetPoint("BOTTOM", frame.judge, "TOP", 0, 3)
    og:SetText("OFF GCD")
    frame.judge.label = og

    -- lane
    local lane = CreateFrame("Frame", nil, frame)
    lane:SetSize(BAR_W + 80, LANE_H)
    lane:SetPoint("TOP", bar, "BOTTOM", 0, -26)
    frame.lane = lane
    local lbg = Tex(lane, "BACKGROUND", WHITE, 0.03, 0.03, 0.04, 0.8)
    lbg:SetAllPoints()
    lane.now = Tex(lane, "OVERLAY", WHITE, 1, 1, 1, 0.95)
    lane.now:SetWidth(2)
    lane.now:SetPoint("TOP")
    lane.now:SetPoint("BOTTOM")
    lane.now:SetPoint("LEFT", lane, "LEFT", LANE_BACK / LANE_SPAN * lane:GetWidth(), 0)
    lane.gain = Font(lane, 11, 0.5, 0.88, 0.56)
    lane.gain:SetPoint("TOPRIGHT", lane, "BOTTOMRIGHT", 0, -3)
    lane.ticks, lane.windows, lane.blocks = {}, {}, {}
    for i = 1, 4 do
        lane.windows[i] = Tex(lane, "BORDER", WHITE, ZONE[1], ZONE[2], ZONE[3], 0.28)
        lane.ticks[i] = Tex(lane, "ARTWORK", WHITE, GOLD[1], GOLD[2], GOLD[3], 1)
        lane.ticks[i]:SetWidth(2)
    end
    for i = 1, 6 do
        local b = CreateFrame("Frame", nil, lane)
        b:SetHeight(LANE_H - 10)
        b.bg = Tex(b, "BACKGROUND", WHITE, 1, 1, 1, 0.08)
        b.bg:SetAllPoints()
        b.icon = Tex(b, "ARTWORK")
        b.icon:SetSize(LANE_H - 14, LANE_H - 14)
        b.icon:SetPoint("LEFT", 2, 0)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        lane.blocks[i] = b
    end

    frame:SetScript("OnUpdate", function() HUD:Update() end)
end

-- What a step should be called and what to tell the player.
local function StepText(step, now)
    local key = step.key
    local name = key == "wait" and "Hold" or (ST.NameOf(key) or key)
    local dt = step.at - now
    local hint
    if key == "wait" then hint = "let the swing go, nothing fits before the twist"
    elseif key == "sob" and step.twist then hint = dt > 0.05 and strformat("twist in %.1f", dt) or "press now, twist lands on this swing"
    elseif dt > 0.05 then hint = strformat("in %.1f", dt)
    elseif FILLERS[key] then hint = "filler, fits before the next twist"
    else hint = "press now" end
    return name, hint
end

function HUD:Layout()
    local style = Get("style", "both")
    frame:SetScale(tonumber(Get("scale", 1)) or 1)
    local showBar = style ~= "lane"
    local showLane = style ~= "bar"
    frame.bar:SetShown(showBar)
    frame.weapon:SetShown(showBar)
    frame.seal:SetShown(showBar)
    for _, d in ipairs(frame.dots) do d:SetShown(showBar) end
    frame.lane:SetShown(showLane)
    frame.lane:ClearAllPoints()
    if showBar then frame.lane:SetPoint("TOP", frame.bar, "BOTTOM", 0, -26)
    else frame.lane:SetPoint("TOP", frame.big.hint, "BOTTOM", 0, -14) end
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

function HUD:Update()
    local now = GetTime()
    if now - lastPlanAt > 0.08 or not cur then
        lastPlanAt = now
        local ok, res = pcall(ST.Current, ST)
        if ok then cur = res end
    end
    if not cur then return end
    local snap, steps = cur.snap, cur.plan.steps
    local speed, nxt = snap.speed, ST:NextSwing(now)
    local elapsed = max(0, speed - (nxt - now))
    local frac = min(1, elapsed / speed)
    local zone0, zone1 = nxt - ST.OVERLAP + ST.MARGIN - snap.lat, nxt - ST.MARGIN - snap.lat
    local inZone = now >= zone0 and now <= zone1
    local first = steps[1]

    -- bar
    local bar = frame.bar
    if bar:IsShown() then
        local w = BAR_W
        bar.fill:SetWidth(max(1, frac * w))
        local z0 = max(0, (zone0 - (nxt - speed)) / speed)
        local z1 = min(1, (zone1 - (nxt - speed)) / speed)
        bar.zone:ClearAllPoints()
        bar.zone:SetPoint("TOP")
        bar.zone:SetPoint("BOTTOM")
        bar.zone:SetPoint("LEFT", bar, "LEFT", z0 * w, 0)
        bar.zone:SetWidth(max(1, (z1 - z0) * w))
        bar.zone:SetAlpha(inZone and 1 or 0.55)
        local s0 = (speed - ST.OVERLAP) / speed
        bar.server:ClearAllPoints()
        bar.server:SetPoint("TOP")
        bar.server:SetPoint("BOTTOM")
        bar.server:SetPoint("LEFT", bar, "LEFT", s0 * w, 0)
        bar.server:SetPoint("RIGHT")
        bar.spark:ClearAllPoints()
        bar.spark:SetPoint("CENTER", bar, "LEFT", frac * w, 0)
        if inZone then bar.fill:SetVertexColor(ZONE[1], ZONE[2] + 0.1, ZONE[3]) else bar.fill:SetVertexColor(GOLD[1], GOLD[2], GOLD[3]) end
        bar.left:SetText(strformat("%.2f", elapsed))
        bar.right:SetText(strformat("%.2f", max(0, zone0 - now)))
        bar.right:SetShown(now < zone0)
        bar.lat:SetText(strformat("%d ms", floor(snap.lat * 1000 + 0.5)))
        -- GCD ghost from now, wrapping is clamped at the bar's end
        local g1 = min(1, frac + ST.GCD / speed)
        bar.gcd:ClearAllPoints()
        bar.gcd:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", frac * w, -6)
        bar.gcd:SetWidth(max(1, (g1 - frac) * (w - 40)))
        local clips = now < zone0 and now + ST.GCD > zone0 and snap.seal == "soc"
        if clips then bar.gcd:SetVertexColor(0.95, 0.4, 0.33, 1) else bar.gcd:SetVertexColor(0.43, 0.72, 1, 0.9) end
        -- weapon and seal
        frame.weapon.icon:SetTexture(GetInventoryItemTexture("player", 16) or ST.ICONS.wait)
        frame.weapon.text:SetText(strformat("%.2f", speed))
        local seal = ST.state.seal
        frame.seal:SetShown(seal ~= nil)
        if seal then
            frame.seal.icon:SetTexture(ST.ICONS[seal])
            local left = (ST.state.sealExpires or 0) - now
            frame.seal.text:SetText(left > 0 and strformat("%d", left) or "")
        end
        local rec = ST:Recent()
        for i = 1, 12 do
            local r = rec[#rec - 12 + i]
            local d = frame.dots[i]
            if r then
                local c = KIND_COLOR[r.kind] or KIND_COLOR.plain
                d:SetVertexColor(c[1], c[2], c[3], 1)
                d:Show()
            else d:Hide() end
        end
    end

    -- sound when the zone opens and the planner wants the twist
    if inZone and not zoneWasOpen and Get("sound", false) and first and first.key == "sob" then
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856, "Master")
    end
    zoneWasOpen = inZone

    -- queue
    local big = frame.big
    if first then
        big.icon:SetTexture(ST.ICONS[first.key])
        local name, hint = StepText(first, now)
        big.name:SetText(name)
        big.hint:SetText(hint)
        local dt = first.at - now
        big.center:SetText(dt > 0.05 and strformat("%.1f", dt) or "")
        big.icon:SetDesaturated(dt > 0.05 or first.key == "wait")
        Glow(big, dt <= 0.05 and first.key ~= "wait")
    else
        big.icon:SetTexture(ST.ICONS.wait)
        big.name:SetText("")
        big.hint:SetText("")
        big.center:SetText("")
        Glow(big, false)
    end
    local si = 1
    for i = 2, #steps do
        if si > 3 then break end
        local st = steps[i]
        if st.key ~= "wait" then
            local s = frame.small[si]
            s.icon:SetTexture(ST.ICONS[st.key])
            s.text:SetText(strformat("%.1f", max(0, st.at - now)))
            s:Show()
            si = si + 1
        end
    end
    for i = si, 3 do frame.small[i]:Hide() end
    local j = frame.judge
    local jLeft = snap.judgeReady - now
    j.text:SetText(jLeft > 0.05 and strformat("%d", math.ceil(jLeft)) or (cur.judge and "now" or "ready"))
    j.icon:SetDesaturated(jLeft > 0.05)
    Glow(j, cur.judge and true or false)

    -- lane
    local lane = frame.lane
    if lane:IsShown() then
        local lw = lane:GetWidth()
        local t0 = now - LANE_BACK
        local function X(t) return (t - t0) / LANE_SPAN * lw end
        local twistAt = {}
        for _, st in ipairs(steps) do if st.twist then twistAt[floor(st.twist * 20 + 0.5)] = true end end
        local ts = nxt - speed
        for i = 1, 4 do
            local tick, win = lane.ticks[i], lane.windows[i]
            local x = X(ts)
            if x >= 0 and x <= lw then
                local tw = twistAt[floor(ts * 20 + 0.5)]
                tick:ClearAllPoints()
                tick:SetPoint("TOP", lane, "TOPLEFT", x, 0)
                tick:SetPoint("BOTTOM", lane, "BOTTOMLEFT", x, 0)
                tick:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], tw and 1 or 0.4)
                tick:Show()
                local wx0 = max(0, X(ts - ST.OVERLAP - snap.lat))
                local wx1 = X(ts - snap.lat)
                win:ClearAllPoints()
                win:SetPoint("TOPLEFT", lane, "TOPLEFT", wx0, 0)
                win:SetPoint("BOTTOMLEFT", lane, "BOTTOMLEFT", wx0, 0)
                win:SetWidth(max(1, wx1 - wx0))
                win:SetShown(tw and true or false)
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
                local x0, x1 = X(st.at), min(lw, X(st.at + ST.GCD))
                if x1 > 0 and x0 < lw then
                    b:ClearAllPoints()
                    b:SetPoint("LEFT", lane, "LEFT", max(0, x0) + 1, 0)
                    b:SetWidth(max(4, x1 - max(0, x0) - 2))
                    b.icon:SetTexture(ST.ICONS[st.key])
                    if FILLERS[st.key] then b.bg:SetVertexColor(FILLER[1], FILLER[2], FILLER[3], 0.28)
                    else b.bg:SetVertexColor(1, 1, 1, 0.09) end
                    b:Show()
                    bi = bi + 1
                end
            end
        end
        for i = bi, #lane.blocks do lane.blocks[i]:Hide() end
        local usesFiller
        for _, st in ipairs(steps) do if FILLERS[st.key] then usesFiller = true end end
        if usesFiller and now - (lane.gainAt or 0) > 1 then
            lane.gainAt = now
            local ok, g = pcall(ST.PlanGain, snap, cur.plan)
            lane.gain:SetText(ok and g and g > 0.5 and strformat("fillers +%d dps", floor(g + 0.5)) or "")
        elseif not usesFiller then lane.gain:SetText("") end
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

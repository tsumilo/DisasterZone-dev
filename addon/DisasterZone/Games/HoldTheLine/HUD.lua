if DisasterZoneBoot and DisasterZoneBoot.Run("Games/HoldTheLine/HUD.lua", ...) then return end -- DisasterZone Games/HoldTheLine/HUD.lua
-- Hold the Line's HUD, drawn in the view's units over the world (the mockup's drawHud): the XP bar, the clock, the
-- spell and blessing slots (icons, a cooldown sweep, the loot frames' gold / legendary borders, rank pips), kills and
-- gold, the boss's bar, the raid warning, and arrows to coffers and bosses off screen.
local _, ns = ...

local D, A, Rd = ns.HTLData, ns.HTLArt, ns.HTLRender
local floor, min, max, sin, cos, atan2, pi = math.floor, math.min, math.max, math.sin, math.cos, math.atan2 or math.atan, math.pi
local SPELLS, PASSIVES, LEGEND, MOBS = D.SPELLS, D.PASSIVES, D.LEGEND, D.MOBS
local Take, File = Rd.Take, Rd.File
local SKULL, GOLDICON = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull", "Interface\\MoneyFrame\\UI-GoldIcon"
local ARROW = "Interface\\Minimap\\MiniMap-QuestArrow"
local TIMER, TIMER_LATE, WHITE, GOLD = { 248 / 255, 216 / 255, 120 / 255 }, { 1, 80 / 255, 64 / 255 }, { 1, 1, 1 }, { 1, 208 / 255, 64 / 255 }

local V
local function Rect(pool, x, y, w, h, r, g, b, a)
    local t = Take(V.pools[pool])
    File(t, nil) t.file = nil
    t:SetColorTexture(r, g, b, a or 1)
    t:SetVertexColor(1, 1, 1, 1)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", V.scaler, "TOPLEFT", x, -y)
    t:SetSize(max(0.05, w), max(0.05, h))
    return t
end
local function Pic(pool, file, x, y, w, h, a, u0, u1, v0, v1)
    local t = Take(V.pools[pool])
    File(t, file)
    t:SetTexCoord(u0 or 0, u1 or 1, v0 or 0, v1 or 1)
    t:SetVertexColor(1, 1, 1, a or 1)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", V.scaler, "TOPLEFT", x, -y)
    t:SetSize(max(0.05, w), max(0.05, h))
    return t
end
local function Text(s, x, y, size, c, font, align, outline)
    local fs = Take(V.pools.hudText)
    Rd.Font(fs, size, font)
    if outline and fs.outline ~= outline then fs:SetFont(fs.ffile, fs.size, outline) fs.outline = outline end
    fs:SetText(s)
    fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    fs:ClearAllPoints()
    local pt = align == "right" and "BOTTOMRIGHT" or align == "center" and "BOTTOM" or "BOTTOMLEFT"
    fs:SetPoint(pt, V.scaler, "TOPLEFT", x, -y - size * 0.22)
    return fs
end
local function Client(k) return A.CLIENT[k] end

local function Swipe(i, x, y, sz, k)
    local cd = V.cdSwipe[i]
    if not cd then
        cd = CreateFrame("Cooldown", nil, V.hud, "CooldownFrameTemplate")
        pcall(cd.SetDrawEdge, cd, false)
        pcall(cd.SetHideCountdownNumbers, cd, true)
        pcall(cd.SetSwipeColor, cd, 0, 0, 0, 0.55)
        cd:SetFrameLevel(V.hud:GetFrameLevel() + 2)
        V.cdSwipe[i] = cd
    end
    cd:ClearAllPoints()
    cd:SetPoint("TOPLEFT", V.scaler, "TOPLEFT", x, -y)
    cd:SetSize(sz, sz)
    if k > 0.02 and GetTime then
        local dur = 10
        pcall(cd.SetCooldown, cd, GetTime() - dur * (1 - k), dur)
        pcall(cd.Pause, cd)
        cd:Show()
    else
        cd:Hide()
    end
end

local function Slot(i, x, y, sz, icon, rank, maxr, legend, cdK, fl, run)
    Rect("hudBack", x - 2, y - 2, sz + 4, sz + 4, 0, 0, 0, 0.75)
    Pic("hud", D.ICON(icon), x, y, sz, sz, 1, 5 / 64, 59 / 64, 5 / 64, 59 / 64)
    if i then Swipe(i, x, y, sz, cdK or 0) end
    local gl = Rect("hudTop", x, y, sz, sz * 0.5, 1, 1, 1, 1)
    ns.UI:GradientRGBA(gl, "VERTICAL", 1, 1, 1, 0, 1, 1, 1, 0.2, true)
    local b = Client(legend and "bd_orange" or "bd_gold")
    Pic("hudFrame", b[1], x - sz * 0.13, y - sz * 0.13, sz * 1.26, sz * 1.26, 1, b[2], b[3], b[4], b[5])
    if legend or (fl and fl > 0) then
        local c = legend and Rd.GLOWC.fire or Rd.GLOWC.gold
        local a = legend and 0.35 + sin(run.t * 3) * 0.1 or fl * 0.9
        local r = sz * (1 + (fl or 0))
        local t = Pic("hudGlow", D.MEDIA .. "UI\\glow", x + sz / 2 - r, y + sz / 2 - r, r * 2, r * 2, 1)
        t:SetVertexColor(c[1], c[2], c[3], a)
    end
    if maxr and maxr > 0 then
        for k = 0, maxr - 1 do
            local px, w = x + 1 + k * ((sz - 2) / maxr), (sz - 2) / maxr - 1.5
            Rect("hudBack", px - 0.5, y + sz + 3.5, w + 1, 4, 0, 0, 0, 0.85)
            if k < rank then
                if legend then Rect("hud", px, y + sz + 4, w, 3, 1, 154 / 255, 42 / 255) else Rect("hud", px, y + sz + 4, w, 3, 1, 208 / 255, 64 / 255) end
            else
                Rect("hud", px, y + sz + 4, w, 3, 60 / 255, 50 / 255, 40 / 255, 0.9)
            end
        end
    end
end

local function Clock(t) t = max(0, floor(t)) return string.format("%02d:%02d", floor(t / 60), t % 60) end
Rd.Clock = Clock

function Rd.SlotPos(kind, i) if kind == "spell" then return 10 + i * 37, 26, 32 end return 10 + i * 28, 72, 23 end

function Rd.DrawHud(v, run)
    V = v
    if run.attract then for _, cd in pairs(v.cdSwipe) do cd:Hide() end return end
    local VW = v.VW
    -- XP bar
    local bw, bx, by, bh = VW - 16, 8, 6, 12
    Rect("hudBack", bx, by, bw, bh, 10 / 255, 6 / 255, 16 / 255, 0.85)
    local xw = (bw - 2) * min(1, run.xp / run.xpNext)
    if xw > 0.1 then
        local f = Rect("hud", bx + 1, by + 1, xw, bh - 2, 1, 1, 1, 1)
        ns.UI:GradientRGBA(f, "VERTICAL", 75 / 255, 21 / 255, 128 / 255, 1, 192 / 255, 124 / 255, 1, 1, true)
        if run.xpPulse > 0 then
            local pu = Rect("hudGlow", bx + 1, by + 1, xw, bh - 2, 220 / 255, 160 / 255, 1, run.xpPulse * 0.5)
            local g = Pic("hudGlow", D.MEDIA .. "UI\\glow", bx + xw - 14, by + bh / 2 - 14, 28, 28, 1)
            g:SetVertexColor(200 / 255, 120 / 255, 1, run.xpPulse)
        end
    end
    Rect("hudTop", bx + 1, by + 1, bw - 2, 3, 1, 1, 1, 0.14)
    for k = 1, 19 do Rect("hudTop", bx + bw * k / 20, by + 1, 1, bh - 2, 0, 0, 0, 0.6) end
    Rect("hudTop", bx, by, bw, 1, 160 / 255, 138 / 255, 90 / 255)
    Rect("hudTop", bx, by + bh - 1, bw, 1, 160 / 255, 138 / 255, 90 / 255)
    Rect("hudTop", bx, by, 1, bh, 160 / 255, 138 / 255, 90 / 255)
    Rect("hudTop", bx + bw - 1, by, 1, bh, 160 / 255, 138 / 255, 90 / 255)
    Text("Level " .. run.level, bx + bw - 6, by + 10, 10, WHITE, nil, "right")
    Text(run.lab and "Spell lab" or Clock(run.t), VW / 2, 50, 30, run.t >= 840 and TIMER_LATE or TIMER, Rd.MORPHEUS, "center", "THICKOUTLINE")
    -- slots
    for i, id in ipairs(run.order) do
        local x, y, sz = Rd.SlotPos("spell", i - 1)
        local s = run.spells[id]
        local cdK = (s.cdMax > 0 and id ~= "consecration" and id ~= "dragonling") and min(1, max(0, s.cd / s.cdMax)) or 0
        Slot(i, x, y, sz, run.legend[id] and LEGEND[id].icon or SPELLS[id].icon, s.r, SPELLS[id].max, run.legend[id], cdK, run.slotFlash[id], run)
    end
    for i = #run.order + 1, #v.cdSwipe do v.cdSwipe[i]:Hide() end
    for i, id in ipairs(run.porder) do
        local x, y, sz = Rd.SlotPos("passive", i - 1)
        Slot(nil, x, y, sz, PASSIVES[id].icon, run.passives[id], 5, false, 0, run.slotFlash[id], run)
    end
    -- kills / gold
    Pic("hud", SKULL, VW - 150, 24, 18, 18, 1)
    Text(tostring(run.kills), VW - 128, 39, 14, WHITE)
    Pic("hud", GOLDICON, VW - 74, 27, 13, 13, 1)
    Text(tostring(run.gold), VW - 58, 39, 14, GOLD)
    -- the boss
    local b = run.boss
    if b and not b.dead then
        local w = 380
        local x0, y0 = VW / 2 - w / 2, 66
        Rect("hudBack", x0, y0, w, 20, 8 / 255, 4 / 255, 10 / 255, 0.85)
        local hp = max(0, b.hp / b.maxHp)
        if hp > 0 then
            local f = Rect("hud", x0 + 2, y0 + 2, (w - 4) * hp, 16, 1, 1, 1, 1)
            ns.UI:GradientRGBA(f, "VERTICAL", 122 / 255, 20 / 255, 8 / 255, 1, 224 / 255, 58 / 255, 34 / 255, 1, true)
        end
        for _, q in ipairs({ { x0, y0, w, 1.5 }, { x0, y0 + 18.5, w, 1.5 }, { x0, y0, 1.5, 20 }, { x0 + w - 1.5, y0, 1.5, 20 } }) do Rect("hudTop", q[1], q[2], q[3], q[4], 212 / 255, 176 / 255, 106 / 255) end
        Pic("hudFrame", SKULL, x0 - 26, y0 - 3, 26, 26, 1)
        Text(MOBS[b.type].name, VW / 2, y0 + 15, 12, WHITE, nil, "center")
        Text(floor(100 * hp + 0.5) .. "%", x0 + w - 6, y0 + 15, 11, { 1, 208 / 255, 192 / 255 }, nil, "right")
    end
    -- the raid warning
    local wn = run.warn
    if wn then
        local age = wn.t0 - wn.t
        local pop = age < 0.15 and 1 + (1 - age / 0.15) * 0.4 or 1
        local c = wn.col
        Text(wn.msg, VW / 2, 140, 21 * pop, { c[1], c[2], c[3], min(1, wn.t * 1.5) }, nil, "center", "THICKOUTLINE")
    end
    -- arrows to coffers and the boss off screen
    local cx, cy = Rd.Camera(v, run)
    local function Arrow(tx, ty, c)
        local sx, sy = tx - cx, ty - cy
        if sx > 0 and sx < VW and sy > 0 and sy < v.VH then return end
        local a = atan2(sy - v.VH / 2, sx - VW / 2)
        local ex = math.max(24, math.min(VW - 24, VW / 2 + cos(a) * 600))
        local ey = math.max(90, math.min(v.VH - 24, v.VH / 2 + sin(a) * 600))
        local t = Pic("hudTop", ARROW, ex - 12, ey - 12, 24, 24, 1)
        Rd.Rot(t, a - pi / 2)
        t:SetVertexColor(c[1], c[2], c[3], 1)
    end
    for _, k in ipairs(run.pick) do if k.kind == "chest" then Arrow(k.x, k.y, GOLD) end end
    if b and not b.dead and not (math.abs(b.x - run.p.x) < VW / 2 + 20 and math.abs(b.y - run.p.y) < v.VH / 2 + 20) then Arrow(b.x, b.y, { 1, 64 / 255, 48 / 255 }) end
end

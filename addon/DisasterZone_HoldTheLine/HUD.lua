if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_HoldTheLine/HUD.lua", ...) then return end -- DisasterZone_HoldTheLine/HUD.lua
-- Hold the Line's HUD, drawn in the view's units over the world (the mockup's drawHud): the XP bar, the clock, the
-- spell and blessing slots (icons, a cooldown sweep, the loot frames' gold / legendary borders, rank pips), kills and
-- gold, the boss's bar, the raid warning, and arrows to coffers and bosses off screen.
local _, ns = ...

local D, A, Rd = ns.HTLData, ns.HTLArt, ns.HTLRender
local floor, min, max, sin, cos, atan2, pi = math.floor, math.min, math.max, math.sin, math.cos, math.atan2 or math.atan, math.pi
local SPELLS, PASSIVES, LEGEND, MOBS = D.SPELLS, D.PASSIVES, D.LEGEND, D.MOBS
local Take, File, Fill, VC, TC, Size = Rd.Take, Rd.File, Rd.Fill, Rd.VC, Rd.TC, Rd.Size
local SKULL, GOLDICON = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull", "Interface\\MoneyFrame\\UI-GoldIcon"
local ARROW = "Interface\\Minimap\\MiniMap-QuestArrow"
local TIMER, TIMER_LATE, WHITE, GOLD = { 248 / 255, 216 / 255, 120 / 255 }, { 1, 80 / 255, 64 / 255 }, { 1, 1, 1 }, { 1, 208 / 255, 64 / 255 }
local FROSTC, IMMUNEC, PCTC, BERSERKC, BOSSARROW = { 0.7, 0.88, 1 }, { 1, 0.9, 0.6 }, { 1, 208 / 255, 192 / 255 }, { 1, 0.6, 0.5 }, { 1, 64 / 255, 48 / 255 }
local WARNC = { 1, 1, 1, 1 }
local GLOWFILE = D.MEDIA .. "UI\\glow"

local V
-- (HUD textures hang by their TOPLEFT from the scaler; the place, like everything else, is only set when it changed)
local function Place(t, x, y, w, h)
    if t.px ~= x or t.py ~= y then t:SetPoint("TOPLEFT", V.scaler, "TOPLEFT", x, -y) t.px, t.py = x, y end
    Size(t, w, h)
end
local function Rect(pool, x, y, w, h, r, g, b, a)
    local t = Take(V.pools[pool])
    Fill(t, r, g, b, a or 1)
    VC(t, 1, 1, 1, 1)
    Place(t, x, y, w, h)
    return t
end
-- a white rect with a vertical gradient (ns.UI:GradientRGBA's, kept on the fill), set as before: white, then the
-- gradient over it. A vertex colour would undo the gradient, so the colour cache is cleared (the next VC sets one).
local function GradRect(pool, x, y, w, h, r1, g1, b1, a1, r2, g2, b2, a2)
    local t = Take(V.pools[pool])
    Fill(t, 1, 1, 1, 1)
    Place(t, x, y, w, h)
    local g = t.gk
    if not g or g[1] ~= r1 or g[2] ~= g1 or g[3] ~= b1 or g[4] ~= a1 or g[5] ~= r2 or g[6] ~= g2 or g[7] ~= b2 or g[8] ~= a2 then
        t:SetVertexColor(1, 1, 1, 1)
        ns.UI:GradientRGBA(t, "VERTICAL", r1, g1, b1, a1, r2, g2, b2, a2, true)
        g = t.gkT or {}
        g[1], g[2], g[3], g[4], g[5], g[6], g[7], g[8] = r1, g1, b1, a1, r2, g2, b2, a2
        t.gk, t.gkT, t.cr = g, g, nil
    end
    return t
end
local function Pic(pool, file, x, y, w, h, a, u0, u1, v0, v1)
    local t = Take(V.pools[pool])
    File(t, file)
    TC(t, u0 or 0, u1 or 1, v0 or 0, v1 or 1)
    VC(t, 1, 1, 1, a or 1)
    Place(t, x, y, w, h)
    return t
end
-- a picture tinted c at alpha a, turned by rot (the glows, the arrows)
local function Tinted(pool, file, x, y, w, h, c, a, rot)
    local t = Take(V.pools[pool])
    File(t, file)
    Rd.RotC(t, rot or 0)
    VC(t, c[1], c[2], c[3], a)
    Place(t, x, y, w, h)
    return t
end
local XPGLOW, PARGLOW, WAITC, WAITW = { 200 / 255, 120 / 255, 1 }, { 1, 200 / 255, 90 / 255 }, { 1, 226 / 255, 150 / 255, 1 }, { 1, 1, 1, 1 }
local function Text(s, x, y, size, c, font, align, outline)
    local fs = Take(V.pools.hudText)
    local sz = floor(size + 0.5)
    font, outline = font or Rd.FONT, outline or "OUTLINE"
    if fs.size ~= sz or fs.ffile ~= font or fs.outline ~= outline then fs:SetFont(font, sz, outline) fs.size, fs.ffile, fs.outline = sz, font, outline end
    if fs.txt ~= s then fs:SetText(s) fs.txt = s end
    Rd.TextCol(fs, c[1], c[2], c[3], c[4] or 1)
    local pt = align == "right" and "BOTTOMRIGHT" or align == "center" and "BOTTOM" or "BOTTOMLEFT"
    local ty = -y - size * 0.22
    if fs.pt ~= pt or fs.px ~= x or fs.py ~= ty then
        if fs.pt ~= pt then fs:ClearAllPoints() end
        fs:SetPoint(pt, V.scaler, "TOPLEFT", x, ty) fs.pt, fs.px, fs.py = pt, x, ty
    end
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
    if cd.px ~= x or cd.py ~= y or cd.sz ~= sz then
        cd:ClearAllPoints()
        cd:SetPoint("TOPLEFT", V.scaler, "TOPLEFT", x, -y)
        cd:SetSize(sz, sz)
        cd.px, cd.py, cd.sz = x, y, sz
    end
    if k > 0.02 and GetTime then
        if cd.k ~= k or not cd.on then
            local dur = 10
            pcall(cd.SetCooldown, cd, GetTime() - dur * (1 - k), dur)
            pcall(cd.Pause, cd)
            cd.k = k
        end
        if not cd.on then cd:Show() cd.on = true end
    elseif cd.on ~= false then
        cd:Hide() cd.on = false
    end
end
local function HideSwipe(cd) if cd.on ~= false then cd:Hide() cd.on = false end end
local function Slot(i, x, y, sz, icon, rank, maxr, legend, cdK, fl, run)
    Rect("hudBack", x - 2, y - 2, sz + 4, sz + 4, 0, 0, 0, 0.75)
    Pic("hud", D.ICON(icon), x, y, sz, sz, 1, 5 / 64, 59 / 64, 5 / 64, 59 / 64)
    if i then Swipe(i, x, y, sz, cdK or 0) end
    GradRect("hudTop", x, y, sz, sz * 0.5, 1, 1, 1, 0, 1, 1, 1, 0.2)
    local b = Client(legend and "bd_orange" or "bd_gold")
    Pic("hudFrame", b[1], x - sz * 0.13, y - sz * 0.13, sz * 1.26, sz * 1.26, 1, b[2], b[3], b[4], b[5])
    if legend or (fl and fl > 0) then
        local c = legend and Rd.GLOWC.fire or Rd.GLOWC.gold
        local a = legend and 0.35 + sin(run.t * 3) * 0.1 or fl * 0.9
        local r = sz * (1 + (fl or 0))
        Tinted("hudGlow", GLOWFILE, x + sz / 2 - r, y + sz / 2 - r, r * 2, r * 2, c, a)
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

local CLOCKS = {}                  -- (a second's text, made once)
local function Clock(t)
    t = max(0, floor(t))
    local s = CLOCKS[t]
    if not s then s = string.format("%02d:%02d", floor(t / 60), t % 60) CLOCKS[t] = s end
    return s
end
Rd.Clock = Clock

-- an arrow at the view's edge to something off screen (cx, cy: the camera)
local function Arrow(v, cx, cy, tx, ty, c)
    local VW = v.VW
    local sx, sy = tx - cx, ty - cy
    if sx > 0 and sx < VW and sy > 0 and sy < v.VH then return end
    local a = atan2(sy - v.VH / 2, sx - VW / 2)
    local ex = math.max(24, math.min(VW - 24, VW / 2 + cos(a) * 600))
    local ey = math.max(90, math.min(v.VH - 24, v.VH / 2 + sin(a) * 600))
    Tinted("hudTop", ARROW, ex - 12, ey - 12, 24, 24, c, 1, a - pi / 2)
end

function Rd.SlotPos(kind, i) if kind == "spell" then return 10 + i * 37, 26, 32 end return 10 + i * 28, 72, 23 end

function Rd.DrawHud(v, run)
    V = v
    if run.attract then for _, cd in pairs(v.cdSwipe) do HideSwipe(cd) end return end
    local VW = v.VW
    -- XP bar: purple, gold once the build is full (Paragon levels); XP past a level waits on it (the pace)
    local bw, bx, by, bh = VW - 16, 8, 6, 12
    local par = (run.paragon or 0) > 0
    Rect("hudBack", bx, by, bw, bh, 10 / 255, 6 / 255, 16 / 255, 0.85)
    local xw = (bw - 2) * min(1, run.xp / run.xpNext)
    if xw > 0.1 then
        if par then GradRect("hud", bx + 1, by + 1, xw, bh - 2, 140 / 255, 92 / 255, 16 / 255, 1, 1, 214 / 255, 96 / 255, 1)
        else GradRect("hud", bx + 1, by + 1, xw, bh - 2, 75 / 255, 21 / 255, 128 / 255, 1, 192 / 255, 124 / 255, 1, 1) end
        if run.xpPulse > 0 then
            Rect("hudGlow", bx + 1, by + 1, xw, bh - 2, 220 / 255, par and 200 / 255 or 160 / 255, par and 120 / 255 or 1, run.xpPulse * 0.5)
            Tinted("hudGlow", GLOWFILE, bx + xw - 14, by + bh / 2 - 14, 28, 28, par and PARGLOW or XPGLOW, run.xpPulse)
        end
    end
    local wait = run.xp >= run.xpNext and ns.HTL.Waiting(run) or 0
    if wait > 0 then                                -- (a level is ready and waits for the pace: the bar's end breathes)
        local a = 0.55 + 0.35 * sin(run.t * 5)
        Tinted("hudGlow", GLOWFILE, bx + bw - 30, by + bh / 2 - 16, 32, 32, par and PARGLOW or XPGLOW, a)
    end
    Rect("hudTop", bx + 1, by + 1, bw - 2, 3, 1, 1, 1, 0.14)
    for k = 1, 19 do Rect("hudTop", bx + bw * k / 20, by + 1, 1, bh - 2, 0, 0, 0, 0.6) end
    Rect("hudTop", bx, by, bw, 1, 160 / 255, 138 / 255, 90 / 255)
    Rect("hudTop", bx, by + bh - 1, bw, 1, 160 / 255, 138 / 255, 90 / 255)
    Rect("hudTop", bx, by, 1, bh, 160 / 255, 138 / 255, 90 / 255)
    Rect("hudTop", bx + bw - 1, by, 1, bh, 160 / 255, 138 / 255, 90 / 255)
    local key = run.level * 4096 + (run.paragon or 0) * 64 + min(63, wait)
    if v.lvlN ~= key then
        v.lvlN = key
        v.lvlS = par and ("Level " .. run.level .. "  \194\183  Paragon " .. run.paragon .. "  +" .. floor(run.paragon * (D.PARAGON or 0.01) * 100 + 0.5) .. "% damage") or ("Level " .. run.level)
        v.waitS = wait > 0 and ("+" .. wait .. (wait == 1 and " level waiting" or " levels waiting")) or nil
    end
    Text(v.lvlS, bx + bw - 6, by + 10, 10, par and GOLD or WHITE, nil, "right")
    if v.waitS then local wc = par and WAITW or WAITC wc[4] = 0.7 + 0.3 * sin(run.t * 5) Text(v.waitS, bx + 6, by + 10, 10, wc) end     -- (white on the gold bar)
    local late = run.ST and not run.ST.reaper and run.finaleOn or (not run.ST or run.ST.reaper) and run.t >= 840
    Text(run.lab and "Spell lab" or Clock(run.t), VW / 2, 50, 30, late and TIMER_LATE or TIMER, Rd.MORPHEUS, "center", "THICKOUTLINE")
    -- slots
    for i, id in ipairs(run.order) do
        local x, y, sz = Rd.SlotPos("spell", i - 1)
        local s = run.spells[id]
        local cdK = (s.cdMax > 0 and id ~= "consecration" and id ~= "dragonling") and min(1, max(0, s.cd / s.cdMax)) or 0
        Slot(i, x, y, sz, run.legend[id] and LEGEND[id].icon or SPELLS[id].icon, s.r, SPELLS[id].max, run.legend[id], cdK, run.slotFlash[id], run)
    end
    for i = #run.order + 1, #v.cdSwipe do HideSwipe(v.cdSwipe[i]) end
    for i, id in ipairs(run.porder) do
        local x, y, sz = Rd.SlotPos("passive", i - 1)
        Slot(nil, x, y, sz, PASSIVES[id].icon, run.passives[id], 5, false, 0, run.slotFlash[id], run)
    end
    -- kills / gold
    Pic("hud", SKULL, VW - 150, 24, 18, 18, 1)
    Text(tostring(run.kills), VW - 128, 39, 14, WHITE)
    Pic("hud", GOLDICON, VW - 74, 27, 13, 13, 1)
    Text(tostring(run.gold), VW - 58, 39, 14, GOLD)
    if run.ST and run.ST.key ~= "epl" then                  -- (Frozen Runes, the necropolis's)
        Pic("hud", D.ICON("inv_misc_rune_09"), VW - 74, 46, 14, 14, 1, 0.08, 0.92, 0.08, 0.92)
        Text(tostring(run.frozen or 0), VW - 58, 59, 13, FROSTC)
    end
    -- the boss
    local b = run.boss
    if b and not b.dead then
        local w = 380
        local x0, y0 = VW / 2 - w / 2, 66
        Rect("hudBack", x0, y0, w, 20, 8 / 255, 4 / 255, 10 / 255, 0.85)
        local hp = max(0, b.hp / b.maxHp)
        local name = MOBS[b.type].name
        if run.groupName then                                   -- (a group: the Four Horsemen, the twins)
            local sum, n = 0, 0
            for _, e in ipairs(run.en) do if e.M.boss and not e.dead and e.M.finale then sum, n = sum + e.hp / e.maxHp, n + 1 end end
            local tot = max(n, run.groupN or n)
            hp = tot > 0 and sum / tot or 0
            name = run.groupName .. "  \194\183  " .. n .. " left"
        end
        if hp > 0 then
            GradRect("hud", x0 + 2, y0 + 2, (w - 4) * hp, 16, 122 / 255, 20 / 255, 8 / 255, 1, 224 / 255, 58 / 255, 34 / 255, 1)
        end
        Rect("hudTop", x0, y0, w, 1.5, 212 / 255, 176 / 255, 106 / 255)
        Rect("hudTop", x0, y0 + 18.5, w, 1.5, 212 / 255, 176 / 255, 106 / 255)
        Rect("hudTop", x0, y0, 1.5, 20, 212 / 255, 176 / 255, 106 / 255)
        Rect("hudTop", x0 + w - 1.5, y0, 1.5, 20, 212 / 255, 176 / 255, 106 / 255)
        Pic("hudFrame", SKULL, x0 - 26, y0 - 3, 26, 26, 1)
        Text(name, VW / 2, y0 + 15, 12, WHITE, nil, "center")
        Text(b.immune and "Immune" or (floor(100 * hp + 0.5) .. "%"), x0 + w - 6, y0 + 15, 11, b.immune and IMMUNEC or PCTC, nil, "right")
        if b.berserk then Text("BERSERK", x0 + w, y0 + 36, 12, TIMER_LATE, nil, "right", "THICKOUTLINE")
        elseif b.berserkAt then Text("Berserk in " .. Clock(b.berserkAt - run.t), x0 + w, y0 + 36, 11, BERSERKC, nil, "right") end
        if b.cast and b.castName and b.castDur then              -- the boss's cast bar
            local cw, cx2, cy2 = 240, VW / 2 - 120, y0 + 26
            local k = min(1, (b.castT or 0) / b.castDur)
            Rect("hudBack", cx2 - 2, cy2 - 2, cw + 4, 16, 0, 0, 0, 0.8)
            GradRect("hud", cx2, cy2, max(0.1, cw * k), 12, 0.55, 0.38, 0.06, 1, 1, 0.78, 0.25, 1)
            Rect("hudTop", cx2 + cw * k - 1, cy2 - 1, 2, 14, 1, 1, 1, 0.9)
            Text(b.castName, VW / 2, cy2 + 11, 10, WHITE, nil, "center")
        end
    end
    -- the necropolis's notes (a curse's count, marks, charges) and the Chill
    local notes = run.hudNotes
    if notes then for i, nt in ipairs(notes) do Text(nt[1], VW / 2, v.VH - 34 - (i - 1) * 18, 13, nt[2], nil, "center", "OUTLINE") end end
    if run.ST and run.ST.hazard == "chill" then
        local cw, cx2, cy2 = 200, VW / 2 - 100, v.VH - 22
        local k = min(1, (run.cold or 0) / 100)
        Rect("hudBack", cx2 - 2, cy2 - 2, cw + 4, 12, 0, 0, 0, 0.8)
        if k >= 1 then GradRect("hud", cx2, cy2, max(0.1, cw * k), 8, 0.6, 0.1, 0.1, 1, 1, 0.4, 0.3, 1)
        else GradRect("hud", cx2, cy2, max(0.1, cw * k), 8, 0.2, 0.45, 0.75, 1, 0.75, 0.92, 1, 1) end
        Text("Chill", cx2 - 6, cy2 + 8, 10, FROSTC, nil, "right")
    end
    -- the raid warning
    local wn = run.warn
    if wn then
        local age = wn.t0 - wn.t
        local pop = age < 0.15 and 1 + (1 - age / 0.15) * 0.4 or 1
        local c = wn.col
        WARNC[1], WARNC[2], WARNC[3], WARNC[4] = c[1], c[2], c[3], min(1, wn.t * 1.5)
        Text(wn.msg, VW / 2, 140, 21 * pop, WARNC, nil, "center", "THICKOUTLINE")
    end
    -- arrows to coffers and the boss off screen
    local cx, cy = Rd.Camera(v, run)
    for _, k in ipairs(run.pick) do if k.kind == "chest" then Arrow(v, cx, cy, k.x, k.y, GOLD) end end
    local cr = run.courier                                   -- (a fleeing courier: Encounters.lua)
    if cr and not cr.dead then Arrow(v, cx, cy, cr.x, cr.y, GOLD) end
    if b and not b.dead and not (math.abs(b.x - run.p.x) < VW / 2 + 20 and math.abs(b.y - run.p.y) < v.VH / 2 + 20) then Arrow(v, cx, cy, b.x, b.y, BOSSARROW) end
end

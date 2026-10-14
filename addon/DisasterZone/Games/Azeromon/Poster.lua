if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Poster.lua", ...) then return end -- DisasterZone Games/Azeromon/Poster.lua
-- ns.AzeroPoster: Azeromon's poster in the Games hub, a short film of the game as it looks now. Real maps (the baked
-- ground, the props, the people where the map puts them) with the hero walking a road through each, and the zone's
-- light and weather (clouds, smoke, mist, dusk and night). Each shot cross-fades into the next while its hero is still
-- walking; nothing here touches the save. The game's drawing helpers come from ns.AzeroUI.Kit (UI.lua), looked up
-- when the poster is made.
local addonName, ns = ...

local P = {}
ns.AzeroPoster = P

local floor, min, max, sin, abs = math.floor, math.min, math.max, math.sin, math.abs
local MEDIA = "Interface\\AddOns\\DisasterZone\\Media\\Azeromon\\"
local GLOW = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
local SHOT_T, FADE = 8, 1.6            -- a shot's length (the fade into the next one included), the cross-fade
local SPEED = 2.2                      -- the hero's pace, in tiles a second

-- Each shot: the map, its light, and the hero's road (tiles; the camera follows the hero, as in the game). Every road
-- is longer than a shot, so the hero is still walking while the next shot fades in. (on roads only: the hero never
-- walks through a prop)
P.SHOTS = {
    { map = "town", period = "day", path = { { 10.5, 18 }, { 10.5, 8 }, { 18, 8 } } },
    { map = "route1", period = "day", path = { { 14.5, 25 }, { 14.5, 15 }, { 10.5, 15 }, { 10.5, 4 } } },
    { map = "westfall", period = "dusk", path = { { 11.5, 32 }, { 11.5, 23.5 }, { 20, 23.5 } } },
    { map = "darkshire", period = "night", path = { { 11.5, 19 }, { 11.5, 9.5 }, { 22, 9.5 } } },
    { map = "stvnorth", period = "day", path = { { 15.5, 30 }, { 15.5, 17 }, { 16, 17 }, { 16, 1 } } },
    { map = "wildshore", period = "day", path = { { 11.5, 27 }, { 11.5, 21.5 }, { 16, 21.5 }, { 16, 2 } } },
}

-- the zones' moods (UI.lua Amb.MOODS: the same tints, mist and shafts)
local MOODS = {
    elwynn = { tint = { 1, 0.95, 0.86 }, motes = { 1, 0.96, 0.75 }, duskMotes = { 1, 0.81, 0.47 } },
    westfall = { tint = { 1, 0.95, 0.84 }, motes = { 0.96, 0.88, 0.62 }, duskMotes = { 1, 0.78, 0.44 } },
    duskwood = { tint = { 0.86, 0.9, 1 }, mist = true },
    jungle = { tint = { 0.92, 1, 0.94 }, motes = { 0.9, 1, 0.7 }, shafts = true },
}
-- while a shot fades in (or the poster turns) its multiplied light can't fade with it: a flat shade stands in
local FLAT_DARK = { dusk = { 0.16, 0.1, 0.12, 0.35 }, night = { 0.02, 0.03, 0.08, 0.6 } }
local CHIMNEY = { house = true, darkhouse = true, farmhouse = true, stonehouse = true }
local FACES = { down = true, left = true, right = true, up = true }

-- the hero's place and facing at time t of a shot (walks the path, then stands at its end)
local function HeroAt(path, t)
    local d = t * SPEED
    for i = 1, #path - 1 do
        local a, b = path[i], path[i + 1]
        local len = abs(b[1] - a[1]) + abs(b[2] - a[2])
        if d <= len then
            local f = (len > 0) and d / len or 0
            local face = (b[1] > a[1] and "right") or (b[1] < a[1] and "left") or (b[2] < a[2] and "up") or "down"
            return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, face, true
        end
        d = d - len
    end
    local e, p = path[#path], path[#path - 1] or path[#path]
    local face = (e[1] > p[1] and "right") or (e[1] < p[1] and "left") or (e[2] < p[2] and "up") or "down"
    return e[1], e[2], face, false
end

-- A reel: one shot drawn on its own frame (two of them cross-fade). Its textures are pooled by kind and reused
-- every frame; Draw(shot, t, w, h, clock, mod) places them, mod = the multiplied layers may show.
local function NewReel(c, Kit, G)
    local view = CreateFrame("Frame", nil, c)
    view:SetAllPoints()
    local r = { view = view, pools = {}, used = {} }

    local function Take(kind, layer, sub, make)
        local list = r.pools[kind]
        if not list then list = {} r.pools[kind] = list end
        local n = (r.used[kind] or 0) + 1
        r.used[kind] = n
        local t = list[n]
        if not t then
            t = view:CreateTexture(nil, layer, nil, sub)
            if make then make(t) end
            list[n] = t
        end
        return t
    end
    local function HideRest()
        for kind, list in pairs(r.pools) do
            for i = (r.used[kind] or 0) + 1, #list do
                local t = list[i]
                t:Hide()
                if t.shadow then t.shadow:Hide() end
            end
        end
        wipe(r.used)
    end
    local function File(t, file, blend)
        if t.file ~= file then
            t.file = file
            t.loaded = Kit.PixelTexture(t, file)
            if blend then pcall(t.SetBlendMode, t, blend) end
        end
        return t.loaded ~= false
    end
    local function Over(file, blend, wrap, sub)
        local t = view:CreateTexture(nil, "OVERLAY", nil, sub or 4)
        local ok, loaded
        if wrap then ok, loaded = pcall(t.SetTexture, t, file, "REPEAT", "REPEAT") end
        if not ok then loaded = t:SetTexture(file) end
        t.ready = loaded ~= false
        if blend then pcall(t.SetBlendMode, t, blend) end
        t:SetAllPoints()
        t:Hide()
        return t
    end
    r.clouds = Over(MEDIA .. "Ground\\clouds", nil, true)
    r.mist = Over(MEDIA .. "Ground\\mist", "BLEND", true, 3)
    r.shafts = Over(MEDIA .. "Ground\\shafts", "ADD", true)
    r.mood = view:CreateTexture(nil, "OVERLAY", nil, 4)
    r.mood:SetAllPoints()
    r.modOK = pcall(r.mood.SetBlendMode, r.mood, "MOD")
    r.vignette = Over(MEDIA .. "Ground\\vignette", "MOD", false, 5)
    r.flat = view:CreateTexture(nil, "OVERLAY", nil, 5)
    r.flat:SetAllPoints()
    r.hero = view:CreateTexture(nil, "ARTWORK", nil, 2)
    Kit.PixelTexture(r.hero, MEDIA .. "chars")
    r.heroShadow = view:CreateTexture(nil, "BORDER", nil, 1)
    Kit.Tile(r.heroShadow, "shadow")

    function r.Draw(shot, t, w, h, clock, mod)
        local m = G.Compile(shot.map)
        local g = m and ns.AzeroGround[shot.map]
        if not (m and g) then HideRest() return end
        local T = max(w / 14, h / 12, 12)          -- (the game's 14 tiles across; a tall poster sees 12 down)
        local S = T / 16
        local hx, hy, face, walking = HeroAt(shot.path, t)
        local ox, oy = hx + 0.5 - w / T / 2, hy + 0.5 - h / T / 2       -- the view's top-left, in tiles
        local vw, vh = w / T, h / T
        local function At(tx, x, y)                                  -- a texture's top-left on map tile x, y
            tx:ClearAllPoints()
            tx:SetPoint("TOPLEFT", view, "TOPLEFT", (x - ox) * T, -(y - oy) * T)
        end
        local function InView(x, y, bw, bh) return x < ox + vw and y < oy + vh and x + bw > ox and y + bh > oy end
        -- the baked ground (map pixel = picture pixel - mx * 16)
        for _, ch in ipairs(g.chunks) do
            local x0, y0, cw, chh, tw, th = ch[1], ch[2], ch[3], ch[4], ch[5], ch[6]
            local tx, ty = x0 / 16 - g.mx, y0 / 16 - g.my
            if InView(tx, ty, cw / 16, chh / 16) then
                local tex = Take("ground", "BACKGROUND", 1)
                File(tex, MEDIA .. "Ground\\" .. shot.map .. "_" .. floor(x0 / 256) .. "_" .. floor(y0 / 256))
                tex:SetTexCoord(0, cw / tw, 0, chh / th)
                tex:SetSize(cw * S, chh * S)
                At(tex, tx, ty)
                tex:Show()
            end
        end
        -- ponds' moving water
        local wf = floor(clock * 4) % 12
        for i, wv in ipairs(g.water or {}) do
            local x0, y0, ww, wh, cols, tw, th = wv[1], wv[2], wv[3], wv[4], wv[5], wv[7], wv[8]
            local tx, ty = x0 / 16 - g.mx, y0 / 16 - g.my
            if InView(tx, ty, ww / 16, wh / 16) then
                local tex = Take("water", "BACKGROUND", 2)
                File(tex, MEDIA .. "Ground\\" .. shot.map .. "_w" .. i)
                local cc, rr = wf % cols, floor(wf / cols)
                tex:SetTexCoord(cc * ww / tw, (cc + 1) * ww / tw, rr * wh / th, (rr + 1) * wh / th)
                tex:SetSize(ww * S, wh * S)
                At(tex, tx, ty)
                tex:Show()
            end
        end
        -- the props on their tiles (houses, trees, fences...), and past the map's edge the forest, as in the game
        local th = m.theme
        local torch = "torch" .. (floor(clock * 6) % 3 + 1)
        for y = floor(oy) - 1, floor(oy + vh) + 1 do
            for x = floor(ox) - 1, floor(ox + vw) + 1 do
                local base, over
                if x < 0 or y < 0 or x >= m.w or y >= m.h then
                    local cx, cy = max(0, min(m.w - 1, x)), max(0, min(m.h - 1, y))
                    local ch = m.def.rows[cy + 1]:sub(cx + 1, cx + 1)
                    if abs(x - cx) > g.mx or abs(y - cy) > g.my then
                        base = Kit.HasTile(th.grass1 .. "_forest") and (th.grass1 .. "_forest") or th.grass1
                    end
                    if ch ~= "=" and ch ~= "w" then over = th.tree end
                else
                    local k = m.key(x, y)
                    over = m.over[k]
                    if over == "torch1" then over = torch end
                    if m.chest[k] then over = "chest" end
                end
                if base then
                    local tex = Take("base", "BACKGROUND", 0, function(tx) Kit.PixelTexture(tx, MEDIA .. "atlas") end)
                    Kit.SetTile(tex, base)
                    tex:SetShown(Kit.HasTile(base))
                    tex:SetSize(T, T)
                    At(tex, x, y)
                end
                if over then
                    local tex = Take("over", "BORDER", 0, function(tx) Kit.PixelTexture(tx, MEDIA .. "atlas") end)
                    Kit.SetTile(tex, over)
                    tex:SetShown(Kit.HasTile(over))
                    tex:SetSize(T, T)
                    At(tex, x, y)
                end
            end
        end
        -- the people where the map puts them (now and then one glances aside), and the hero on the road
        for i, npc in ipairs(m.def.npcs or {}) do
            local nx, ny = npc.x, npc.y
            if nx and InView(nx, ny, 1, 1) then
                local tex = Take("npc", "ARTWORK", 1, function(tx)
                    Kit.PixelTexture(tx, MEDIA .. "chars")
                    tx.shadow = view:CreateTexture(nil, "BORDER", nil, 1)
                    Kit.Tile(tx.shadow, "shadow")
                end)
                local f = FACES[npc.face] and npc.face or "down"
                if (clock + i * 2.3) % 7 < 1 then f = (f == "left" or f == "right") and "down" or ((i % 2 == 0) and "left" or "right") end
                Kit.Char(tex, npc.sprite or "bald", f, 1)
                local tint = npc.tint
                tex:SetVertexColor(tint and tint[1] or 1, tint and tint[2] or 1, tint and tint[3] or 1)
                tex:SetSize(T, T)
                At(tex, nx, ny)
                tex:Show()
                tex.shadow:SetSize(T, T)
                tex.shadow:ClearAllPoints()
                tex.shadow:SetPoint("TOPLEFT", tex)
                tex.shadow:Show()
            end
        end
        local steps = { 0, 1, 2, 1 }
        Kit.Char(r.hero, "hero", face, walking and steps[floor(clock * 7) % 4 + 1] or 1)
        r.hero:SetSize(T, T)
        At(r.hero, hx, hy)
        r.hero:Show()
        r.heroShadow:SetSize(T, T)
        r.heroShadow:ClearAllPoints()
        r.heroShadow:SetPoint("TOPLEFT", r.hero)
        r.heroShadow:Show()
        -- one-colour squares: chimney smoke, motes in the air
        local function Pix(mx, my, pw, ph, cr, cg, cb, a, layer, sub)
            local tex = Take("pix", "ARTWORK", 5)
            tex:SetDrawLayer(layer or "ARTWORK", sub or 5)
            tex:SetColorTexture(cr, cg, cb, a)
            tex:SetSize(pw * S, ph * S)
            At(tex, floor(mx) / 16, floor(my) / 16)
            tex:Show()
        end
        for ci, st in ipairs(m.def.stamps or {}) do
            if CHIMNEY[st.kind] then
                for k = 0, 6 do
                    local age = (clock * 0.32 + k / 7) % 1
                    if ((floor(clock * 6) * 7 + k * 13 + ci * 31) % 100) / 100 >= age * 0.55 then
                        local sz, gr = age < 0.3 and 2 or 3, (220 - age * 60) / 255
                        Pix(st.x * 16 + 16 + age * 14 + sin(age * 7 + k) * 2, st.y * 16 + 13 - age * 26, sz, sz, gr, gr,
                            gr + 0.02, 0.85 - age * 0.6)
                    end
                end
            end
        end
        local mood = MOODS[m.def.theme or "elwynn"] or MOODS.elwynn
        local period = shot.period
        local col = mood.motes and ((period == "dusk") and (mood.duskMotes or mood.motes) or mood.motes)
        if col and period ~= "night" then
            local W, H = m.w * 16, m.h * 16
            for k = 0, 33 do
                local h1, h2, h3 = (k * 0.6180339) % 1, (k * 0.4142135) % 1, (k * 0.7320508) % 1
                if sin(clock * 1.7 + k * 1.3) > 0.2 then
                    Pix((h1 * W + clock * (3 + h2 * 4)) % W, (h3 * H + sin(clock * 0.8 + k) * 6 - clock * 1.5 + H * 10) % H,
                        1, 1, col[1], col[2], col[3], 0.85, "ARTWORK", 6)
                end
            end
        end
        -- the sky: clouds drifting by day, mist in Duskwood, sun shafts in the jungle, the zone's tint and frame
        local px0, py0, pw, ph = ox * 16, oy * 16, vw * 16, vh * 16
        if r.clouds.ready and period == "day" then
            local u, v = px0 - clock * 7, py0 - clock * 3
            r.clouds:SetTexCoord(u / 256, (u + pw) / 256, v / 256, (v + ph) / 256)
            r.clouds:SetAlpha(0.17)
            r.clouds:Show()
        else
            r.clouds:Hide()
        end
        if mood.mist and r.mist.ready then
            local u = px0 + clock * 5
            r.mist:SetTexCoord(u / 256, (u + pw) / 256, py0 / 256, (py0 + ph) / 256)
            r.mist:SetAlpha(0.45)
            r.mist:Show()
        else
            r.mist:Hide()
        end
        if mood.shafts and period == "day" and r.shafts.ready then
            r.shafts:SetTexCoord(px0 / 256, (px0 + pw) / 256, py0 / 256, (py0 + ph) / 256)
            r.shafts:SetAlpha(0.45 + 0.12 * sin(clock * 0.6))
            r.shafts:Show()
        else
            r.shafts:Hide()
        end
        mod = mod and r.modOK
        r.mood:SetColorTexture(mood.tint[1], mood.tint[2], mood.tint[3], 1)
        r.mood:SetShown(mod and true or false)
        r.vignette:SetShown((mod and r.vignette.ready) and true or false)
        -- dusk and night: the baked darkness with its pools of light, glows over the lamps, the hero's lantern
        local key = (period == "night" and "n") or (period == "dusk" and "d") or nil
        local flat = key and not mod and FLAT_DARK[period]
        if flat then r.flat:SetColorTexture(flat[1], flat[2], flat[3], flat[4]) end
        r.flat:SetShown(flat and true or false)
        if key and g.lightChunks then
            local sc = g.lightScale or 2
            if mod then
                for _, lc in ipairs(g.lightChunks) do
                    local x0, y0, lw, lh, tw, th2 = lc[1], lc[2], lc[3], lc[4], lc[5], lc[6]
                    local tex = Take("light", "OVERLAY", 5)
                    if File(tex, MEDIA .. "Ground\\" .. shot.map .. "_" .. key .. "_" .. floor(x0 / 256) .. "_" .. floor(y0 / 256), "MOD") then
                        tex:SetTexCoord(0, lw / tw, 0, lh / th2)
                        tex:SetSize(lw * sc * S, lh * sc * S)
                        At(tex, x0 * sc / 16 - g.mx, y0 * sc / 16 - g.my)
                        tex:Show()
                    end
                end
            end
            local k = (key == "n") and 1 or 0.6
            local function Glow(x, y, size, a)
                local tex = Take("glow", "OVERLAY", 7, function(tx)
                    tx:SetTexture(GLOW)
                    pcall(tx.SetBlendMode, tx, "ADD")
                end)
                tex:SetSize(size, size)
                tex:SetVertexColor(1, 0.68, 0.33, a)
                tex:ClearAllPoints()
                tex:SetPoint("CENTER", view, "TOPLEFT", (x - ox) * T, -(y - oy) * T)
                tex:Show()
            end
            for _, l in ipairs(g.lights or {}) do
                local lx, ly = l[1] / 16 - g.mx, l[2] / 16 - g.my
                if InView(lx - 2, ly - 2, 4, 4) then
                    local fl = (l[4] == 1) and (0.75 + 0.25 * sin(clock * 9 + l[1]) * sin(clock * 5.3 + l[2])) or 1
                    Glow(lx, ly, l[3] * 1.5 * S, (l[5] == 1 and 0.3 or 0.45) * fl * k)
                end
            end
            Glow(hx + 0.5, hy + 0.6, 44 * S, (0.4 + 0.05 * sin(clock * 7)) * k)
        end
        HideRest()
    end
    return r
end

function P:New(parent)
    local Kit = ns.AzeroUI and ns.AzeroUI.Kit
    local G = ns.Azero
    local c = CreateFrame("Frame", nil, parent)
    c:SetAllPoints(parent)
    pcall(c.SetClipsChildren, c, true)
    function c:Layout() end
    function c:Refresh() end
    function c:Tick() end
    if not (Kit and Kit.Char and G and G.Compile and ns.AzeroGround) then return c end
    -- the box: the art frame (the hub's Layout gets the poster's width and the art's height less 52)
    function c:Layout(w, h) self.boxW, self.boxH = w - 2, h + 51 end

    -- the shot playing (c.shot, c.t seconds in) on the lower reel; in its last FADE seconds the next shot starts on
    -- the upper reel and fades in over it, then the reels swap
    c.reels = { NewReel(c, Kit, G), NewReel(c, Kit, G) }
    c.shot, c.t, c.clock = 1, 0, 0
    local function Stack()
        c.reels[1].view:SetFrameLevel(c:GetFrameLevel() + 1)
        c.reels[2].view:SetFrameLevel(c:GetFrameLevel() + 2)
    end
    Stack()

    function c:Seek(i, t)
        self.shot, self.t = ((i - 1) % #P.SHOTS) + 1, t or 0
    end
    -- a side poster (the hub's poster.off ~= 0) holds a still of the shot it was on, drawn again only when its size
    -- or the shot changes; the film plays in front only
    local poster = parent:GetParent()
    function c:Tick(elapsed)
        if poster and poster.off and poster.off ~= 0 then
            local w, h = self:GetSize()
            if not (w and h and w > 1 and h > 1) then w, h = self.boxW, self.boxH end
            if not (w and h and w > 1 and h > 1) then return end
            local key = self.shot .. ":" .. floor(w) .. "x" .. floor(h)
            if self.still == key then return end
            self.still = key
            self.reels[1].view:Show()
            self.reels[1].view:SetAlpha(1)
            self.reels[1].Draw(P.SHOTS[self.shot], 3, w, h, self.clock, self:GetEffectiveAlpha() > 0.99)
            self.reels[2].view:Hide()
            return
        end
        self.still = nil
        elapsed = min(elapsed or 0, 0.1)
        self.clock, self.t = self.clock + elapsed, self.t + elapsed
        if self.t >= SHOT_T then
            self:Seek(self.shot + 1, self.t - SHOT_T + FADE)       -- (the next shot is FADE seconds in already)
            self.reels[1], self.reels[2] = self.reels[2], self.reels[1]
            Stack()
        end
        local w, h = self:GetSize()
        if not (w and h and w > 1 and h > 1) then w, h = self.boxW, self.boxH end
        if not (w and h and w > 1 and h > 1) then return end
        -- (multiplied layers don't fade with their frame: while the poster turns, both reels use the flat shade)
        local solid = self:GetEffectiveAlpha() > 0.99
        local low, up = self.reels[1], self.reels[2]
        low.view:Show()
        low.view:SetAlpha(1)
        low.Draw(P.SHOTS[self.shot], self.t, w, h, self.clock, solid)
        local f = (self.t - (SHOT_T - FADE)) / FADE
        if f > 0 then
            local e = f * f * (3 - 2 * f)
            up.view:Show()
            up.view:SetAlpha(e)
            up.Draw(P.SHOTS[(self.shot % #P.SHOTS) + 1], self.t - (SHOT_T - FADE), w, h, self.clock, false)
        else
            up.view:Hide()
        end
    end
    return c
end

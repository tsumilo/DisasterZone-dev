if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_HoldTheLine/UI.lua", ...) then return end -- DisasterZone_HoldTheLine/UI.lua
-- ns.HTLUI: Hold the Line's panel in the Games hub - the mockup's page in the client. The world is drawn by
-- HoldTheLine/Render.lua (+ HUD.lua) into a view filling the panel; over it the overlays, laid out in the mockup's
-- CSS px on a stage scaled to the panel (OV_W wide): the title screen, the level-up picker (cards dealt and turned
-- over, each running a live preview of the real spell in its own little world), the coffer with its Need rolls,
-- the legendary, the end of a run, the pause and the spell lab. Their pieces come from ns.HTLKit (the mockup's own
-- CSS, cut by dev/generators/gen_htl_kit.py); icons, words and previews are laid on top here.
-- Keys (while the game has focus: a click gives it, Esc pauses): WASD / arrows move, 1-3 pick a blessing, Space or
-- Enter takes a coffer.
local _, ns = ...

local D, A, K, E, Rd = ns.HTLData, ns.HTLArt, ns.HTLKit, ns.HTL, ns.HTLRender
local UI = {}
ns.HTLUI = UI

local floor, min, max, abs, sin, cos, pi = math.floor, math.min, math.max, math.abs, math.sin, math.cos, math.pi
local SPELLS, PASSIVES, LEGEND, CLASSES = D.SPELLS, D.PASSIVES, D.LEGEND, D.CLASSES
local STEP = 1 / 60
local OV_W = 1148                 -- the mockup's game frame, CSS px: the overlays are laid out in these
local FONT, MORPHEUS = Rd.FONT, Rd.MORPHEUS
local Q = {   -- quality: name colour, the glow round a card
    rare = { 0.31, 0.64, 1 }, uncommon = { 0.24, 0.95, 0.31 }, epic = { 0.76, 0.48, 1 }, legendary = { 1, 0.55, 0.1 }, common = { 1, 1, 1 } }
local YELLOW, GREY, MUTE = { 1, 0.82, 0 }, { 0.64, 0.6, 0.67 }, { 0.66, 0.61, 0.69 }

local root, view, ov, stage, run, acc, focused = nil, nil, nil, nil, nil, 0, false
local held = {}
local overlay                  -- what is up over the world: nil, "title", "level", "choosing", "chest", "legend", "end", "pause"
local previews = {}            -- the cards' little worlds (kept, reused)

---------------------------------------------------------------------------
-- pieces
---------------------------------------------------------------------------
-- a kit piece, its element (pad excluded) at x, y, w, h in the stage's CSS px
local function KitTex(parent, name, layer, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
    local k = K[name]
    if k then t:SetTexture(k[1]) t:SetTexCoord(k[2], k[3], k[4], k[5]) end
    t.kit = name
    return t
end
local function KitSet(t, name)
    local k = K[name]
    if not k or t.kit == name then return end
    t:SetTexture(k[1]) t:SetTexCoord(k[2], k[3], k[4], k[5])
    t.kit = name
end
-- place a kit piece by its element's box (the pad round it spills out)
local function KitAt(t, rel, x, y, w, h)
    local k = K[t.kit]
    local pad = k and k[8] or 0
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", rel, "TOPLEFT", x - pad, -(y - pad))
    t:SetSize((w or (k[6] - 2 * pad)) + 2 * pad, (h or (k[7] - 2 * pad)) + 2 * pad)
end
-- three-slice (rounded pills, buttons): caps of c px stay, the middle stretches
local function Slice3(parent, name, layer, sub, c)
    local o = { parts = {}, name = name }
    for i = 1, 3 do o.parts[i] = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0) end
    function o:SetKit(n) self.name = n end
    function o:Place(rel, x, y, w, h)
        local k = K[self.name]
        if not k then return end
        local pad = k[8]
        local cw, ch = k[6], k[7]
        local du = (k[3] - k[2]) / cw
        local cap = c + pad
        local xs = { x - pad, x - pad + cap, x + w + pad - cap }
        local ws = { cap, max(0.1, w + 2 * pad - 2 * cap), cap }
        local us = { { k[2], k[2] + cap * du }, { k[2] + cap * du, k[3] - cap * du }, { k[3] - cap * du, k[3] } }
        for i = 1, 3 do
            local t = self.parts[i]
            t:SetTexture(k[1])
            t:SetTexCoord(us[i][1], us[i][2], k[4], k[5])
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", rel, "TOPLEFT", xs[i], -(y - pad))
            t:SetSize(ws[i], h + 2 * pad)
        end
    end
    function o:SetShown(on) for _, t in ipairs(self.parts) do t:SetShown(on) end end
    function o:SetAlpha(a) for _, t in ipairs(self.parts) do t:SetAlpha(a) end end
    return o
end
local function Words(parent, size, font, layer, flags)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont(font or FONT, size, flags or "")
    fs:SetShadowOffset(0, -1)
    fs:SetShadowColor(0, 0, 0, 1)
    return fs
end
-- WoW's own legendary glow (the loot toast's sheet, Interface\LootFrame\LegendaryToast): two starbursts turning
-- against each other, a ring that swells out and fades, and sparkles drifting up - behind the logo and the legendary
local LTOAST = "Interface\\LootFrame\\LegendaryToast"
local LT_STAR = { 0, 0, 204 / 512, 204 / 512 }
local LT_RING = { 0, 224 / 512, 132 / 512, 356 / 512 }
local LT_SPARK = { 190 / 512, 132 / 512, 405 / 512, 455 / 512 }
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local function RotTC(t, ang, u0, v0, u1, v1)       -- the sub-picture turned by ang round its centre
    local cu, cv, hu, hv = (u0 + u1) / 2, (v0 + v1) / 2, (u1 - u0) / 2, (v1 - v0) / 2
    local c, s = cos(ang), sin(ang)
    local function p(x, y) return cu + (x * c - y * s) * hu, cv + (x * s + y * c) * hv end
    local ulx, uly = p(-1, -1)
    local llx, lly = p(-1, 1)
    local urx, ury = p(1, -1)
    local lrx, lry = p(1, 1)
    t:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
end
local function LegendGlow(parent, layer, sub)
    local g = { parent = parent, stars = {}, sparks = {} }
    for i = 1, 2 do
        local t = parent:CreateTexture(nil, layer, nil, sub)
        t:SetTexture(LTOAST) t:SetBlendMode("ADD")
        local m = parent:CreateMaskTexture()
        m:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        m:SetAllPoints(t)
        t:AddMaskTexture(m)
        g.stars[i] = t
    end
    g.ring = parent:CreateTexture(nil, layer, nil, sub)
    g.ring:SetTexture(LTOAST) g.ring:SetBlendMode("ADD") g.ring:SetTexCoord(LT_RING[1], LT_RING[3], LT_RING[2], LT_RING[4])
    g.ring:SetVertexColor(1, 0.8, 0.4, 1)
    for i = 1, 3 do
        local t = parent:CreateTexture(nil, layer, nil, sub)
        t:SetTexture(LTOAST) t:SetBlendMode("ADD")
        g.sparks[i] = t
    end
    function g:Place(cx, cy, size)
        self.cx, self.cy, self.size = cx, cy, size
    end
    -- k: how far it has bloomed (0..1), a: its strength
    function g:Tick(t, k, a)
        k, a = k or 1, a or 1
        local cx, cy, size = self.cx or 0, self.cy or 0, self.size or 300
        for i, s in ipairs(self.stars) do
            local sz = size * (i == 1 and 1 or 0.78) * (0.4 + 0.6 * k) * (1 + 0.04 * sin(t * 1.7 + i))
            s:ClearAllPoints() s:SetPoint("CENTER", self.parent, "TOPLEFT", cx, -cy) s:SetSize(sz, sz)
            RotTC(s, (i == 1 and 1 or -1.6) * t * 0.18, LT_STAR[1], LT_STAR[2], LT_STAR[3], LT_STAR[4])
            s:SetVertexColor(1, i == 1 and 0.86 or 0.72, i == 1 and 0.6 or 0.36, a * (i == 1 and 0.95 or 0.7))
        end
        local rk = (t % 2.6) / 2.6
        local rs = size * (0.35 + rk * 0.9)
        self.ring:ClearAllPoints() self.ring:SetPoint("CENTER", self.parent, "TOPLEFT", cx, -cy) self.ring:SetSize(rs, rs)
        self.ring:SetAlpha(a * k * (1 - rk) * 0.9)
        for i, s in ipairs(self.sparks) do
            local sk = ((t / 4.5) + (i - 1) / 3) % 1
            local w = size * 0.62
            local h = w * (323 / 215)
            s:ClearAllPoints()
            s:SetPoint("CENTER", self.parent, "TOPLEFT", cx + (i - 2) * size * 0.22, -(cy - sk * size * 0.28 + size * 0.06))
            s:SetSize(w, h)
            if i == 2 then s:SetTexCoord(LT_SPARK[3], LT_SPARK[1], LT_SPARK[2], LT_SPARK[4]) else s:SetTexCoord(LT_SPARK[1], LT_SPARK[3], LT_SPARK[2], LT_SPARK[4]) end
            s:SetAlpha(a * k * sin(sk * pi) * 0.9)
        end
    end
    function g:SetShown(on)
        for _, s in ipairs(self.stars) do s:SetShown(on) end
        for _, s in ipairs(self.sparks) do s:SetShown(on) end
        self.ring:SetShown(on)
    end
    return g
end

-- a kit piece at k times its size, its element's top left at x, y
local function KitAtK(t, rel, x, y, k)
    local e = K[t.kit]
    local pad = e[8] * k
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", rel, "TOPLEFT", x - pad, -(y - pad))
    t:SetSize(e[6] * k, e[7] * k)
end
local function Icon(name) return D.ICON(name) end
-- one line, never wrapped or cut: a long name ("Power Word: Fortitude", "Thunderfury, Blessed Blade...") steps its size
-- down until it fits maxW
local function FitLine(fs, font, size, minSize, maxW)
    fs:SetWordWrap(false)
    local s = size
    fs:SetFont(font or FONT, s, "")
    while s > minSize and (fs:GetStringWidth() or 0) > maxW do s = s - 1 fs:SetFont(font or FONT, s, "") end
    return s
end
local function Sound(name, gap, vol)
    local id = A.SOUND[name]
    if not id or not PlaySoundFile then return end
    UI.lastSound = UI.lastSound or {}
    local now = GetTime and GetTime() or 0
    if UI.lastSound[name] and now - UI.lastSound[name] < (gap or 0.05) then return end
    UI.lastSound[name] = now
    pcall(PlaySoundFile, id, "SFX")
end
UI.Sound = Sound

---------------------------------------------------------------------------
-- the run
---------------------------------------------------------------------------
local function Class()
    local cls = UnitClass and select(2, UnitClass("player"))
    return CLASSES[cls or ""] and cls or "PALADIN"
end
UI.Class = Class

local function Hook(r)
    r.onSound = function(name, gap, vol) Sound(name, gap, vol) end
    return r
end

local function NewRun(cls, opts)
    opts = opts or {}
    opts.cls = cls
    if not opts.attract and not opts.lab and ns.HTLGame then opts.talents = ns.HTLGame:RunTalents() end
    if not opts.attract and not opts.lab and ns.HTLSocial then opts.perks = ns.HTLSocial:RunPerks() end
    if not opts.attract and not opts.lab and ns.HTLGame and ns.HTLGame.RunNaxx then
        local nx = ns.HTLGame:RunNaxx(cls)
        opts.frostRes, opts.t3n, opts.ktSlain = nx.frostRes, nx.t3n, nx.ktSlain
        if nx.t3Look and opts.perks then opts.perks.t3 = true end
        if opts.stage and not ns.HTLGame:StageOpen(opts.stage) and not opts.challenge and not opts.dev then opts.stage = nil end
    end
    opts.seed = opts.seed or floor(((time and time() or 1) * 7 + math.random(1, 100000)) % 2000000000)
    run = Hook(E.New(opts))
    acc = 0
    if not opts.attract and view then view.scaler:SetAlpha(1) end
    if ns.HTLGame and not opts.attract and not opts.lab and not opts.dev then ns.HTLGame:Started(run) end
    return run
end

local ShowTitle, OpenLevelUp, ShowChest, ShowEnd, ClosePause, CloseOv, OpenLab, ShowLab
local function Attract()
    run = NewRun("PALADIN", { bot = true, god = true, attract = true, seed = 7 })
    E.AddSpell(run, "avenger") E.AddSpell(run, "avenger") E.AddSpell(run, "exorcism") E.AddPassive(run, "might")
    E.JumpStart(run, 95)      -- busy at once (no long fast-forward); a second and a half of play settles it
    run.warm = 1.5
    run.paused = false
    view.scaler:SetAlpha(0)
end

---------------------------------------------------------------------------
-- overlays: the stage
---------------------------------------------------------------------------
local function StageScale()
    local w = root:GetWidth() or 0
    if w < 100 then w = 786 end
    return w / OV_W
end
local function StageH()                -- the stage's height in its CSS px (Layout sizes it from the panel)
    local h = stage and stage:GetHeight() or 0
    if h < 100 then h = 518 / StageScale() end
    return h
end
local function ClearOv()
    for _, f in ipairs({ ov.title, ov.picker, ov.coffer, ov.loot, ov.legend, ov["end"], ov.pause, ov.talents, ov.board, ov.ach, ov.dawn, ov.naxx, ov.t3 }) do if f then f:Hide() end end
    ov.dim:Hide()
    for _, pv in ipairs(previews) do pv.on = false end
end

local function NewPreview(parent)
    local pv = { frame = CreateFrame("Frame", nil, parent) }
    pcall(pv.frame.SetClipsChildren, pv.frame, true)
    pv.view = Rd.NewView(pv.frame, { preview = true })
    previews[#previews + 1] = pv
    return pv
end
-- a little world running one spell (or blessing) of `cls`
local function StartPreview(pv, w, h, o)
    pv.frame:SetSize(w, h)
    Rd.LayoutWide(pv.view, w, h, o.vw or 280)
    local r = E.New({ cls = o.cls, preview = true, god = true, noStart = true, seed = math.random(1, 1000000) })
    r.pvN, r.pvR0, r.pvR1, r.pvCamY, r.pvMove, r.pvFace = o.n or 7, o.r0, o.r1, o.camY, o.move, 2
    if o.spell then
        r.spells[o.spell] = { r = o.r or 1, cd = 0.2, acc = 0, a = 0, cdMax = 1 }
        r.order[#r.order + 1] = o.spell
        if o.legend then r.legend[o.spell] = true if o.spell == "consecration" then r.ashbringer = true end end
    end
    if o.passive then r.passives[o.passive] = o.r or 1 r.pvPassive = o.passive end
    E.Use(r)
    r.st = r.st or {}
    E.SetView(r, pv.view.VW, pv.view.VH)
    for _ = 1, 24 do E.Step(r, 1 / 30, 0, 0) end
    pv.run, pv.on, pv.fast, pv.acc = r, true, 1, 0
end
local function PassiveFx(r, dt)
    local p, id = r.p, r.pvPassive
    local c = PASSIVES[id].tint
    r.pvAcc = (r.pvAcc or 0) + dt
    if r.pvAcc > 1.1 then
        r.pvAcc = 0
        E.Use(r)
        E.emit({ img = "sun_ring", tint = c, x = p.x, y = p.y - 24, life = 0.6, s0 = 54, s1 = 90, a0 = 1, a1 = 0, rot = "rnd", light = 120 })
        E.emit({ img = "ring_soft", tint = c, x = p.x, y = p.y, life = 0.6, s0 = 20, s1 = 140, a0 = 0.9, a1 = 0, flat = true, rot = "rnd" })
        for k = 0, 9 do local a = k / 10 * pi * 2 E.emit({ img = "levelup_rays", tint = c, x = p.x + cos(a) * 20, y = p.y + sin(a) * 12 - 24, life = 0.9, s0 = 20, s1 = 30, sx = 0.6, sy = 2, a0 = 0.8, a1 = 0, fi = 0.2 }) end
    end
    if math.random() < 0.5 then E.Use(r) E.emit({ img = "sparkle", tint = c, x = p.x + (math.random() - 0.5) * 32, y = p.y + (math.random() - 0.5) * 8, vz = 30 + math.random() * 50, life = 0.7, s0 = 8, s1 = 1 }) end
end
local function TickPreviews(dt)
    for _, pv in ipairs(previews) do
        if pv.on and pv.frame:IsVisible() and pv.run then
            pv.acc = min(pv.acc + dt * (pv.fast or 1), STEP * 4)
            local stepped = pv.drawn ~= pv.run
            while pv.acc >= STEP do
                pv.acc = pv.acc - STEP
                E.Step(pv.run, STEP, 0, 0)
                if pv.run.pvPassive then PassiveFx(pv.run, STEP) end
                stepped = true
            end
            pv.idle = (pv.idle or 0) + dt
            if stepped or pv.view.dirty or pv.idle >= 0.25 then Rd.Draw(pv.view, pv.run) pv.drawn, pv.idle = pv.run, 0 end
        end
    end
end

---------------------------------------------------------------------------
-- the level-up picker
---------------------------------------------------------------------------
local W_CARD, H_CARD = 252, 412
local WIN_X, WIN_Y, WIN_W, WIN_H = 10, 10, 232, 168       -- the preview's window, cut out of the card's face
local MEDAL_Y, NAME_Y, TYPE_Y, SEP_Y, DESC_Y = 142, 240, 268, 287, 296
local CARD_GAP = 20
local RAQUO, DOT = "\194\187", " \194\183 "

local function numbersDiff(prev, nxt)      -- the numbers a rank changes, with the step in green
    if not prev then return nxt end
    local old = {}
    for n in prev:gmatch("%-?%d+%.?%d*") do old[#old + 1] = n end
    local i = 0
    return (nxt:gsub("%-?%d+%.?%d*", function(m)
        i = i + 1
        local o = old[i]
        if not o or o == m or not tonumber(o) or not tonumber(m) then return m end
        local d = tonumber(m) - tonumber(o)
        local ds = (d > 0 and "+" or "") .. (abs(d - floor(d)) > 0.01 and string.format("%.1f", d) or tostring(floor(d + 0.5)))
        return m .. "|cff4dff5e" .. ds .. "|r|cffffffff"
    end))
end

local function OptInfo(o)
    if o.kind == "spell" then
        local s = SPELLS[o.id]
        local L = LEGEND[o.id]
        return { name = s.name, icon = s.icon, desc = numbersDiff(o.r > 1 and s.desc(o.r - 1) or nil, s.desc(o.r)), r = o.r, max = s.max, isNew = o.r == 1, school = s.school,
            sub = s.cls and (CLASSES[s.cls].name .. " spell") or "Engineering gadget", q = s.gadget and "epic" or "rare", evo = (L and not run.legend[o.id]) and L or nil, evoNeed = L and PASSIVES[L.need] }
    elseif o.kind == "passive" then
        local s = PASSIVES[o.id]
        local evoFor
        for sid, l in pairs(LEGEND) do if l.need == o.id and run.spells[sid] and SPELLS[sid].cls == run.cls then evoFor = { spell = SPELLS[sid], legend = l } end end
        return { name = s.name, icon = s.icon, desc = numbersDiff(o.r > 1 and s.desc(o.r - 1) or nil, s.desc(o.r)), r = o.r, max = 5, isNew = o.r == 1, sub = "Blessing", q = "uncommon", evoFor = evoFor }
    elseif o.kind == "legend" then
        local s = LEGEND[o.id]
        return { name = s.name, icon = s.icon, desc = s.desc, r = 0, max = 0, sub = SPELLS[o.id].name .. " + " .. PASSIVES[s.need].name, q = "legendary" }
    elseif o.kind == "gold" then
        return { name = "Purse of Gold", icon = "inv_misc_coin_02", desc = "|cffffffff+25|r gold.", r = 0, max = 0, sub = "Loot", q = "common" }
    elseif o.kind == "relic" then
        local rl = D.RELICS[o.id]
        local from = rl.legend and "Kel'Thuzad" or (rl.from and D.MOBS[rl.from[1]] and D.MOBS[rl.from[1]].name) or "Naxxramas"
        return { name = rl.name, icon = rl.icon, desc = rl.desc, r = 0, max = 0, sub = (rl.legend and "Legendary relic" or "Relic") .. " \194\183 " .. from, q = rl.legend and "legendary" or "epic" }
    end
    return { name = "Major Healthstone", icon = "inv_stone_04", desc = "Restores all health.", r = 0, max = 0, sub = "Loot", q = "common" }
end

-- the plate a card wears: its quality, lit when hovered, gold when chosen, red when it is about to be banished
local function CardPlate(c)
    local p = ov.picker
    local name = "c2_" .. c.q
    if c.state == "chosen" then name = "c2_pick"
    elseif c.state == "banished" or (c.hov and p.banishing) then name = "c2_ban"
    elseif c.hov then name = name .. "_hov" end
    KitSet(c.plate, name)
    c.plateDirty = true
end

-- a card: the live preview at the bottom, the face (its window cut out) over it, the glass and the words over that,
-- the back over everything while it is turned away. The face turns in whole: the client cannot squeeze a frame or a
-- line of text, so the preview and the words stay drawn and are seen through clips that narrow with the plate (the
-- plate, the medal and the rank gems are squeezed for real).
local function NewCard(parent, i)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(W_CARD, H_CARD)
    c.i = i
    local L = c:GetFrameLevel()
    c.pvClip = CreateFrame("Frame", nil, c)
    pcall(c.pvClip.SetClipsChildren, c.pvClip, true)
    c.pvClip:SetFrameLevel(L + 1)
    c.pv = NewPreview(c.pvClip)
    c.pv.frame:SetPoint("TOPLEFT", c, "TOPLEFT", WIN_X, -WIN_Y)
    c.pv.frame:SetFrameLevel(L + 1)
    c.face = CreateFrame("Frame", nil, c)
    c.face:SetAllPoints()
    c.face:SetFrameLevel(L + 60)
    c.plate = KitTex(c.face, "c2_rare", "BACKGROUND")
    c.topClip = CreateFrame("Frame", nil, c.face)
    pcall(c.topClip.SetClipsChildren, c.topClip, true)
    c.topClip:SetFrameLevel(L + 62)
    c.top = CreateFrame("Frame", nil, c.topClip)
    c.top:SetPoint("TOPLEFT", c.face, "TOPLEFT", 0, 0)
    c.top:SetSize(W_CARD, H_CARD)
    c.top:SetFrameLevel(L + 62)
    c.glass = KitTex(c.top, "c2_glass", "BACKGROUND")
    KitAt(c.glass, c.top, WIN_X, WIN_Y, WIN_W, WIN_H)
    c.ribbon = KitTex(c.top, "c2_new", "ARTWORK", 4)
    KitAt(c.ribbon, c.top, 6, 18)
    c.ribbonL = Words(c.top, 9) c.ribbonL:SetText("N E W") c.ribbonL:SetTextColor(42 / 255, 22 / 255, 0) c.ribbonL:SetShadowColor(0, 0, 0, 0)
    c.ribbonL:SetPoint("LEFT", c.top, "TOPLEFT", 16, -28.5)
    c.medalIcon = c.top:CreateTexture(nil, "ARTWORK", nil, 1)
    c.medalIcon:SetPoint("TOPLEFT", c.top, "TOPLEFT", W_CARD / 2 - 36, -MEDAL_Y)
    c.medalIcon:SetSize(72, 72)
    c.mask = c.top:CreateMaskTexture()
    c.mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    c.mask:SetAllPoints(c.medalIcon)
    c.medalIcon:AddMaskTexture(c.mask)
    c.ring = KitTex(c.top, "c2_ring_rare", "ARTWORK", 2)
    c.gems = {}
    for g = 1, 5 do c.gems[g] = KitTex(c.top, "gem_off", "ARTWORK", 3) end
    c.name = Words(c.top, 23, MORPHEUS)
    c.name:SetPoint("TOP", c.top, "TOPLEFT", W_CARD / 2, -NAME_Y)
    c.name:SetWidth(W_CARD - 20)
    c.name:SetShadowOffset(0, -2)
    c.type = Words(c.top, 11)
    c.type:SetPoint("TOP", c.top, "TOPLEFT", W_CARD / 2, -TYPE_Y)
    c.type:SetWidth(W_CARD - 20)
    c.type:SetTextColor(162 / 255, 153 / 255, 170 / 255)
    c.sep = KitTex(c.top, "c2_sep", "ARTWORK")
    KitAt(c.sep, c.top, W_CARD / 2 - 60, SEP_Y, 120, 1)
    c.desc = Words(c.top, 13)
    c.desc:SetPoint("TOP", c.top, "TOPLEFT", W_CARD / 2, -DESC_Y)
    c.desc:SetWidth(W_CARD - 36)
    c.desc:SetSpacing(4)
    c.desc:SetTextColor(YELLOW[1], YELLOW[2], YELLOW[3])
    c.chips = {}
    for k = 1, 2 do c.chips[k] = { bg = Slice3(c.top, "c2chip_plain", "ARTWORK", 1, 9), fs = Words(c.top, 10) } end
    c.evo = KitTex(c.top, "c2_evo", "ARTWORK", 1)
    c.evoL = Words(c.top, 11) c.evoL:SetTextColor(203 / 255, 185 / 255, 148 / 255)
    c.evoI1 = c.top:CreateTexture(nil, "OVERLAY") c.evoI1:SetSize(20, 20)
    c.evoA = Words(c.top, 12) c.evoA:SetText(RAQUO) c.evoA:SetTextColor(217 / 255, 178 / 255, 94 / 255)
    c.evoI2 = c.top:CreateTexture(nil, "OVERLAY") c.evoI2:SetSize(20, 20)
    c.evoGlow = c.top:CreateTexture(nil, "OVERLAY", nil, -1) c.evoGlow:SetTexture(D.MEDIA .. "UI\\glow") c.evoGlow:SetBlendMode("ADD") c.evoGlow:SetVertexColor(1, 0.5, 0, 0.8) c.evoGlow:SetSize(34, 34)
    c.evoN = Words(c.top, 11) c.evoN:SetTextColor(1, 0.55, 0.1)
    -- its key, a little cap in the window's corner
    c.kbd = KitTex(c.top, "c2_key", "OVERLAY", 3)
    KitAt(c.kbd, c.top, WIN_X + WIN_W - 8 - 18, WIN_Y + 8, 18, 18)
    c.key = Words(c.top, 10) c.key:SetPoint("CENTER", c.kbd, "CENTER", 0, 0) c.key:SetText(tostring(i)) c.key:SetTextColor(217 / 255, 205 / 255, 180 / 255)
    -- the light that sweeps a chosen card (its own layer: it spills past the card's edges, the clip would cut it)
    c.fx = CreateFrame("Frame", nil, c)
    c.fx:SetAllPoints()
    c.fx:SetFrameLevel(L + 66)
    c.flash = c.fx:CreateTexture(nil, "OVERLAY", nil, 6)
    c.flash:SetTexture(D.MEDIA .. "UI\\glow") c.flash:SetBlendMode("ADD") c.flash:SetVertexColor(1, 0.86, 0.5, 1)
    c.flash:SetPoint("CENTER", c.top, "TOPLEFT", W_CARD / 2, -(MEDAL_Y + 36)) c.flash:SetSize(W_CARD * 1.5, W_CARD * 1.5)
    c.flash:Hide()
    c.back = CreateFrame("Frame", nil, c)
    c.back:SetAllPoints()
    c.back:SetFrameLevel(L + 70)
    c.backTex = KitTex(c.back, "card_back", "BACKGROUND")
    KitAt(c.backTex, c.back, 0, 0, W_CARD, H_CARD)
    c.backRune = c.back:CreateTexture(nil, "ARTWORK")
    c.backRune:SetTexture(Rd.FxFile("rune_circle"))
    c.backRune:SetBlendMode("ADD")
    c.backRune:SetVertexColor(1, 206 / 255, 110 / 255, 1)
    c.backRune:SetPoint("CENTER")
    c.backRune:SetSize(W_CARD * 0.8, W_CARD * 0.8)
    c:SetScript("OnEnter", function(self)
        if overlay ~= "level" then return end
        self.hov = true Sound("hover", 0.03) self.pv.fast = 1.5 CardPlate(self)
    end)
    c:SetScript("OnLeave", function(self) self.hov = false self.pv.fast = 1 if not self.state then CardPlate(self) end end)
    c:SetScript("OnClick", function(self) UI.TakeLevel(self.i) end)
    return c
end

local MELEE_PV = { cleave = true, thunderclap = true, execute = true }
local function FillCard(c, o)
    local f = OptInfo(o)
    c.o, c.q, c.state, c.hov = o, f.q, nil, false
    CardPlate(c)
    KitSet(c.ring, "c2_ring_" .. f.q)
    KitAt(c.ring, c.top, W_CARD / 2 - 36, MEDAL_Y, 72, 72)
    c.medalIcon:SetTexture(Icon(f.icon))
    c.medalIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    c.ribbon:SetShown(f.isNew and true or false)
    c.ribbonL:SetShown(f.isNew and true or false)
    -- gems: one per rank, the one this card gives lit
    local n = f.max or 0
    local gw = n * 8 + (n - 1) * 7
    c.gemN, c.faSet = n, nil
    for g = 1, 5 do
        local t = c.gems[g]
        if g <= n then
            KitSet(t, g < f.r and "gem_on" or g == f.r and "gem_next" or "gem_off")
            KitAt(t, c.top, W_CARD / 2 - gw / 2 + (g - 1) * 15, MEDAL_Y + 84, 8, 8)
            t:Show()
        else t:Hide() end
    end
    local qc = Q[f.q]
    c.name:SetText(f.name)
    FitLine(c.name, MORPHEUS, 23, 13, W_CARD - 26)
    c.name:SetTextColor(qc[1], qc[2], qc[3])
    local rank = f.r > 0 and (f.isNew and "Rank 1" or ("Rank " .. (f.r - 1) .. " " .. RAQUO .. " " .. f.r)) or nil
    c.type:SetText(f.sub .. (rank and (DOT .. "|cfff4cf6a" .. rank .. "|r") or ""))
    FitLine(c.type, FONT, 11, 8, W_CARD - 26)
    c.desc:SetText(f.desc)
    -- the legendary it leads to sits low on the card; without one, the stat chips do
    local evo = f.evo or (f.evoFor and f.evoFor.legend)
    local evoShow = evo ~= nil
    for _, w in ipairs({ c.evo, c.evoL, c.evoI1, c.evoA, c.evoI2, c.evoN, c.evoGlow }) do w:SetShown(evoShow) end
    if evoShow then
        local ey = H_CARD - 16 - 30
        KitAt(c.evo, c.top, 6, ey, W_CARD - 12, 30)
        c.evoL:SetText(f.evo and "Rank 5 +" or "Awakens")
        c.evoI1:SetTexture(Icon(f.evo and f.evoNeed.icon or f.evoFor.spell.icon))
        c.evoI1:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        c.evoI2:SetTexture(Icon(evo.icon))
        c.evoI2:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        c.evoN:SetText(evo.name:match("^[^,]+"))
        local wl, wa, wn = c.evoL:GetStringWidth() or 50, c.evoA:GetStringWidth() or 8, c.evoN:GetStringWidth() or 60
        local tot = wl + 5 + 20 + 5 + wa + 5 + 20 + 5 + wn
        local x = W_CARD / 2 - tot / 2
        local y = ey + 15
        c.evoL:ClearAllPoints() c.evoL:SetPoint("LEFT", c.top, "TOPLEFT", x, -y) x = x + wl + 5
        c.evoI1:ClearAllPoints() c.evoI1:SetPoint("LEFT", c.top, "TOPLEFT", x, -y) x = x + 25
        c.evoA:ClearAllPoints() c.evoA:SetPoint("LEFT", c.top, "TOPLEFT", x, -y) x = x + wa + 5
        c.evoI2:ClearAllPoints() c.evoI2:SetPoint("LEFT", c.top, "TOPLEFT", x, -y)
        c.evoGlow:ClearAllPoints() c.evoGlow:SetPoint("CENTER", c.evoI2, "CENTER") x = x + 25
        c.evoN:ClearAllPoints() c.evoN:SetPoint("LEFT", c.top, "TOPLEFT", x, -y)
    end
    local chips
    if evoShow then chips = nil
    elseif o.kind == "spell" then
        local s = SPELLS[o.id]
        local cd = D.CD[o.id] and ("Every " .. string.format("%.1f", D.CD[o.id](o.r)) .. " s") or (o.id == "consecration" and "Aura" or "Always on")
        chips = { { D.SCHOOL_NAME[s.school], "c2chip_" .. s.school, true }, { cd, "c2chip_plain" } }
    elseif o.kind == "passive" then
        chips = { { "Passive", "c2chip_pass", true }, { "Stacks to rank 5", "c2chip_plain" } }
    end
    local tw, total = {}, 0
    for k = 1, 2 do
        local cd = chips and chips[k]
        if cd then
            c.chips[k].fs:SetText(cd[1])
            tw[k] = (c.chips[k].fs:GetStringWidth() or 40) + 16
            total = total + tw[k] + (k > 1 and 6 or 0)
        end
    end
    local cx, cy = W_CARD / 2 - total / 2, H_CARD - 18 - 18
    for k = 1, 2 do
        local ch, cd = c.chips[k], chips and chips[k]
        if cd then
            ch.bg:SetKit(K[cd[2]] and cd[2] or "c2chip_plain")
            ch.bg:Place(c.top, cx, cy, tw[k], 18)
            ch.bg:SetShown(true)
            ch.fs:SetTextColor(cd[3] and 1 or 154 / 255, cd[3] and 1 or 144 / 255, cd[3] and 1 or 162 / 255)
            ch.fs:ClearAllPoints()
            ch.fs:SetPoint("CENTER", c.top, "TOPLEFT", cx + tw[k] / 2, -(cy + 9.5))
            ch.fs:Show()
            cx = cx + tw[k] + 6
        else
            ch.bg:SetShown(false) ch.fs:Hide()
        end
    end
    -- the preview
    c.pv.frame:Show()
    if o.kind == "spell" then
        local id = o.id
        StartPreview(c.pv, WIN_W, WIN_H, { spell = id, r = o.r, cls = run.cls, n = 7, vw = 258,
            r0 = (id == "consecration" or MELEE_PV[id]) and 40 or id == "charge" and 150 or (id == "nova" or id == "holywrath") and 55 or 80,
            r1 = (id == "consecration" or MELEE_PV[id]) and 75 or id == "charge" and 210 or (id == "nova" or id == "holywrath") and 85 or 110 })
    elseif o.kind == "passive" then
        StartPreview(c.pv, WIN_W, WIN_H, { passive = o.id, r = o.r, cls = run.cls, n = 4, vw = 258, move = o.id == "cheetah" })
    else
        c.pv.on = false
    end
end

-- deal-in + turn-over: the card rises in (0.55 s, from 90 px lower, 0.82 scale, faded), its back turns away and the
-- face turns in (0.75 s from 0.12 s after the deal starts) - the turn is a squeeze across, the client has no 3D.
-- Picked: the chosen card lifts, goes gold, a light sweeps it and it dissolves upward as its icon flies to the bar;
-- the others sink and fade at once (their previews stop).
local function Easing(k) return 1 - (1 - k) ^ 3 end
local function OvershootEase(k) local c1, c3 = 1.15, 2.15 return 1 + c3 * (k - 1) ^ 3 + c1 * (k - 1) ^ 2 end
local function AnimateCard(c, t)
    local d = c.delay
    local k = min(1, max(0, (t - d) / 0.55))
    local e = OvershootEase(k)
    local fk = min(1, max(0, (t - d - 0.12) / 0.75))
    local fe = Easing(fk)
    local half = fe < 0.5
    local sq = half and (1 - fe * 2) or (fe - 0.5) * 2
    c.back:SetShown(half)
    c.face:SetShown(not half)
    local w = max(0.02, sq)
    if half then
        KitAt(c.backTex, c.back, W_CARD * (1 - w) / 2, 0, W_CARD * w, H_CARD)
        c.backRune:SetSize(W_CARD * 0.8 * w, W_CARD * 0.8)
    end
    local lift = (c.hov and not c.state) and 10 or 0
    if c.state == "chosen" then lift = 16 end
    c.liftNow = (c.liftNow or 0) + (lift - (c.liftNow or 0)) * 0.25
    local gone = c.state == "gone" and Easing(min(1, (t - (c.goneT or t)) / 0.28)) or 0
    local out = c.state == "chosen" and Easing(min(1, max(0, (t - (c.goneT or t) - 0.42) / 0.36))) or 0
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", c:GetParent(), "TOPLEFT", c.x, -(c.y + (1 - e) * 90 - c.liftNow + gone * 40 - out * 24))
    local sc = (0.82 + 0.18 * e) * (c.state == "chosen" and (1.05 + out * 0.04) or 1) * (1 - gone * 0.1)
    c:SetScale(max(0.05, sc))
    c:SetAlpha(min(1, k * 2) * (1 - gone) * (1 - out))
    -- the face's turn: the plate, the medal and the gems squeezed across; the words and the live preview seen through
    -- clips as wide as the squeezed plate and its window (centred, so nothing slides)
    local fa = not half and w or 0
    if fa < 0.999 or c.faSet ~= fa or c.plateDirty then
        local x0 = W_CARD * (1 - fa) / 2
        KitAt(c.plate, c.face, x0, 0, max(0.1, W_CARD * fa), H_CARD)
        c.topClip:ClearAllPoints()
        c.topClip:SetPoint("TOPLEFT", c.face, "TOPLEFT", x0, 0)
        c.topClip:SetSize(max(0.1, W_CARD * fa), H_CARD)
        c.pvClip:ClearAllPoints()
        c.pvClip:SetPoint("TOPLEFT", c, "TOPLEFT", x0 + WIN_X * fa, -WIN_Y)
        c.pvClip:SetSize(max(0.1, WIN_W * fa), WIN_H)
        local mw = max(0.1, 72 * fa)
        c.medalIcon:ClearAllPoints()
        c.medalIcon:SetPoint("TOPLEFT", c.top, "TOPLEFT", W_CARD / 2 - mw / 2, -MEDAL_Y)
        c.medalIcon:SetSize(mw, 72)
        KitAt(c.ring, c.top, W_CARD / 2 - mw / 2, MEDAL_Y, mw, 72)
        local n = c.gemN or 0
        local gw = n * 8 + (n - 1) * 7
        for g = 1, n do
            local gx = W_CARD / 2 - gw / 2 + (g - 1) * 15
            KitAt(c.gems[g], c.top, W_CARD / 2 + (gx - W_CARD / 2) * fa, MEDAL_Y + 84, max(0.1, 8 * fa), 8)
        end
        c.faSet = fa c.plateDirty = nil
    end
end

local function BuildPicker()
    local p = CreateFrame("Frame", nil, stage)
    p:SetAllPoints()
    p.head = KitTex(p, "hd_frame", "BACKGROUND", 1)
    p.word = KitTex(p, "lv_word", "ARTWORK", 1)
    p.digits = {}
    for i = 1, 3 do p.digits[i] = KitTex(p, "lvd_0", "ARTWORK", 1) end
    p.sub = KitTex(p, "hd_bless", "ARTWORK", 1)
    p.cards = {}
    for i = 1, 3 do p.cards[i] = NewCard(p, i) end
    p.btns = {}
    for i, def in ipairs({ { "reroll", "Reroll", "Interface\\Buttons\\UI-GroupLoot-Dice-Up" }, { "banish", "Banish", "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8" }, { "skip", "Skip" } }) do
        local b = CreateFrame("Button", nil, p)
        b.bg = Slice3(b, "gb", "BACKGROUND", 0, 15)
        b.label = Words(b, 12) b.label:SetTextColor(234 / 255, 223 / 255, 198 / 255)
        b.badge = Slice3(b, "gb_n", "ARTWORK", 0, 9)
        b.count = Words(b, 11, nil, "OVERLAY") b.count:SetTextColor(42 / 255, 22 / 255, 0) b.count:SetShadowColor(0, 0, 0, 0)
        if def[3] then b.icon = b:CreateTexture(nil, "ARTWORK") b.icon:SetTexture(def[3]) b.icon:SetSize(18, 18) end
        b.key, b.text = def[1], def[2]
        b:SetScript("OnClick", function() UI.PickerButton(def[1]) end)
        b:SetScript("OnEnter", function(self) self.hov = true Sound("hover", 0.03) self:Look() end)
        b:SetScript("OnLeave", function(self) self.hov = false self:Look() end)
        function b:Look()
            local on = self.key == "banish" and p.banishing
            self.bg:SetKit(on and "gb_danger" or self.hov and "gb_hov" or "gb")
            self.bg:Place(self, 0, 0, self:GetWidth(), 30)
            self.label:SetTextColor(on and 1 or self.hov and 1 or 234 / 255, on and 214 / 255 or self.hov and 246 / 255 or 223 / 255, on and 204 / 255 or self.hov and 220 / 255 or 198 / 255)
        end
        p.btns[i] = b
    end
    p.fly = p:CreateTexture(nil, "OVERLAY", nil, 7)
    p.flyMask = p:CreateMaskTexture()
    p.flyMask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    p.flyMask:SetAllPoints(p.fly)
    p.fly:AddMaskTexture(p.flyMask)
    p.flyRing = KitTex(p, "fly", "OVERLAY", 7)
    p:Hide()
    return p
end

local function LayoutPicker(p)
    local sk = StageScale()
    local H = StageH()
    local total = 3 * W_CARD + 2 * CARD_GAP
    local x0 = OV_W / 2 - total / 2
    local headH, gap = 112, 10
    local blockH = headH + gap + H_CARD + 22 + 30
    local clockB = 68 * (view.K or 1) / sk + 4                -- under the HUD's clock
    local y0 = max(clockB, H / 2 - blockH / 2)
    p.y0 = y0
    KitAt(p.head, p, OV_W / 2 - 260, y0, 520, 112)
    p.subY = y0 + 92
    for i, c in ipairs(p.cards) do c.x, c.y = x0 + (i - 1) * (W_CARD + CARD_GAP), y0 + headH + gap end
    p.btnY = y0 + headH + gap + H_CARD + 22
end

-- "Level 12": the word and the digits are pieces on one baseline, set as one line centred between the rules
local function SetLevelWord(p, lvl)
    local s = tostring(lvl)
    local function ew(name) local k = K[name] return k[6] - 2 * k[8] end
    local tot = ew("lv_word")
    for i = 1, min(3, #s) do tot = tot + ew("lvd_" .. s:sub(i, i)) end
    local x = OV_W / 2 - tot / 2
    local y = p.y0 + 20
    KitAt(p.word, p, x, y)
    x = x + ew("lv_word")
    for i = 1, 3 do
        local ch = s:sub(i, i)
        local t = p.digits[i]
        if ch ~= "" then KitSet(t, "lvd_" .. ch) KitAt(t, p, x, y) x = x + ew("lvd_" .. ch) t:Show() else t:Hide() end
    end
end
local function SetSub(p, name)
    KitSet(p.sub, name)
    local k = K[name]
    KitAt(p.sub, p, OV_W / 2 - (k[6] - 2 * k[8]) / 2, p.subY)
end

local function LayoutPickerButtons(p)
    local ws, tot = {}, 0
    for i, b in ipairs(p.btns) do
        local n = b.key == "reroll" and run.rerolls or b.key == "banish" and run.banish or nil
        b.n = n
        b.label:SetText(b.text)
        b.count:SetText(n and tostring(n) or "")
        b.nw = n and max(18, (b.count:GetStringWidth() or 6) + 10) or 0
        local w = 14 + (b.icon and 26 or 0) + (b.label:GetStringWidth() or 40) + (n and 8 + b.nw or 0) + 16
        ws[i] = floor(w + 0.5)
        tot = tot + ws[i] + (i > 1 and 12 or 0)
        local off = (b.key == "reroll" and run.rerolls == 0) or (b.key == "banish" and run.banish == 0)
        b:SetEnabled(not off)
        b:SetAlpha(off and 0.4 or 1)
    end
    local x = OV_W / 2 - tot / 2
    for i, b in ipairs(p.btns) do
        local w = ws[i]
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", p, "TOPLEFT", x, -p.btnY)
        b:SetSize(w, 30)
        b:Look()
        local ix = 14
        if b.icon then b.icon:ClearAllPoints() b.icon:SetPoint("LEFT", b, "LEFT", ix, 0) ix = ix + 26 end
        b.label:ClearAllPoints() b.label:SetPoint("LEFT", b, "LEFT", ix, 0)
        b.badge:SetShown(b.n ~= nil) b.count:SetShown(b.n ~= nil)
        if b.n then
            local bx = ix + (b.label:GetStringWidth() or 40) + 8
            b.badge:Place(b, bx, 6, b.nw, 18)
            b.count:ClearAllPoints() b.count:SetPoint("CENTER", b, "TOPLEFT", bx + b.nw / 2, -15.5)
        end
        x = x + w + 12
    end
end

local pickT = 0
OpenLevelUp = function(preset)
    overlay = "level"
    run.paused = true
    local p = ov.picker
    ClearOv()
    ov.dim:Show()
    p:Show()
    p.banishing = false
    LayoutPicker(p)
    SetLevelWord(p, run.level - run.pending + 1)
    SetSub(p, "hd_bless")
    local opts = preset or E.Choices(run, 3)
    run.lvlOpts = opts
    for i, c in ipairs(p.cards) do
        c.delay = (i - 1) * 0.11
        c.state, c.goneT, c.liftNow = nil, nil, 0
        if opts[i] then FillCard(c, opts[i]) c:Show() c.key:SetText(tostring(i)) else c:Hide() c.pv.on = false end
    end
    LayoutPickerButtons(p)
    p.fly:Hide() p.flyRing:Hide()
    pickT = 0
    Sound("open")
end

function UI.PickerButton(key)
    local p = ov.picker
    if overlay ~= "level" then return end
    if key == "reroll" and run.rerolls > 0 then run.rerolls = run.rerolls - 1 Sound("coin") OpenLevelUp()
    elseif key == "banish" and run.banish > 0 then
        p.banishing = not p.banishing
        SetSub(p, p.banishing and "hd_banish" or "hd_bless")
        for _, c in ipairs(p.cards) do if c:IsShown() and not c.state then CardPlate(c) end end
        LayoutPickerButtons(p)
    elseif key == "skip" then UI.TakeLevel(0) end
end

local flyT, flyFrom, flyTo, chosen
function UI.TakeLevel(i)
    if overlay ~= "level" then return end
    local p = ov.picker
    if p.banishing and i > 0 then        -- off the list for this run, and a new hand
        local c = p.cards[i]
        run.banished[run.lvlOpts[i].id] = true
        run.banish = run.banish - 1
        Sound("fear", 0.1, 0.5)
        c.state = "banished"
        CardPlate(c)
        c:SetAlpha(0.4)
        c.pv.on = false
        C_Timer.After(0.38, function() if overlay == "level" then OpenLevelUp() end end)
        return
    end
    overlay = "choosing"
    local o = i > 0 and run.lvlOpts[i] or nil
    for j, c in ipairs(p.cards) do
        c.goneT = pickT
        if j == i then c.state = "chosen" CardPlate(c) c.flash:Show() c.flashT = 0
        else c.state = "gone" c.pv.on = false c.pv.frame:Hide() end
    end
    chosen = o
    if o then
        Sound("pick")
        -- the icon flies to its slot on the bar
        local c = p.cards[i]
        local kind = o.kind == "passive" and "passive" or "spell"
        local idx
        if kind == "spell" then idx = #run.order for k, id in ipairs(run.order) do if id == o.id then idx = k - 1 end end
        else idx = #run.porder for k, id in ipairs(run.porder) do if id == o.id then idx = k - 1 end end end
        local sx, sy, sz = Rd.SlotPos(kind, idx)
        local sk = StageScale()
        local vk = view.K / sk                               -- view units -> stage px
        flyFrom = { c.x + W_CARD / 2 - 36, c.y - 16 + MEDAL_Y, 72 }
        flyTo = { sx * vk, sy * vk, sz * vk }
        p.fly:SetTexture(Icon(OptInfo(o).icon))
        p.fly:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        flyT = -0.3
    else
        flyT = nil
    end
    p.doneT = pickT + (o and 0.86 or 0.3)
end

local function FinishPick()
    local p = ov.picker
    p.fly:Hide() p.flyRing:Hide()
    for _, c in ipairs(p.cards) do c.pv.on = false end
    if chosen then E.Apply(run, chosen) end
    chosen = nil
    run.pending = max(0, run.pending - 1)
    if run.pending > 0 then OpenLevelUp() return end
    CloseOv(true)
end

local function TickPicker(dt)
    local p = ov.picker
    if not p:IsShown() then return end
    pickT = pickT + dt
    for _, c in ipairs(p.cards) do
        if c:IsShown() then
            AnimateCard(c, pickT)
            if c.flashT then
                c.flashT = c.flashT + dt
                local k = c.flashT / 0.6
                c.flash:SetAlpha(max(0, sin(min(1, k) * pi)) * 0.9)
                c.flash:SetSize(W_CARD * (1.1 + k * 0.6), W_CARD * (1.1 + k * 0.6))
                if k >= 1 then c.flash:Hide() c.flashT = nil end
            end
        end
    end
    for _, b in ipairs(p.btns) do if overlay == "choosing" then b:SetAlpha(max(0, b:GetAlpha() - dt * 5)) end end
    if overlay == "choosing" and flyT then
        flyT = flyT + dt
        if flyT >= 0 then
            local k = min(1, flyT / 0.52)
            local e = k < 0.5 and 4 * k * k * k or 1 - (-2 * k + 2) ^ 3 / 2
            local x = flyFrom[1] + (flyTo[1] - flyFrom[1]) * e
            local y = flyFrom[2] + (flyTo[2] - flyFrom[2]) * e - sin(k * pi) * 60
            local s = flyFrom[3] + (flyTo[3] - flyFrom[3]) * e
            p.fly:ClearAllPoints() p.fly:SetPoint("TOPLEFT", p, "TOPLEFT", x, -y) p.fly:SetSize(s, s) p.fly:Show()
            p.flyRing:Show() KitAt(p.flyRing, p, x, y, s, s)
        end
    end
    if p.doneT and overlay == "choosing" and pickT >= p.doneT then p.doneT = nil FinishPick() end
end

---------------------------------------------------------------------------
-- the coffer, its rewards, the legendary
---------------------------------------------------------------------------
local QBD = { legendary = "bd_orange", epic = "bd_purple", rare = "bd_blue", uncommon = "bd_green", common = "bd_gold" }
local function Burst(parent, n, len, w, tint)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(1, 1)
    f.rays = {}
    for i = 1, n do
        local l = f:CreateLine(nil, "BACKGROUND")
        l:SetTexture(Rd.FxFile("rays"))
        l:SetBlendMode("ADD")
        l:SetVertexColor(tint[1], tint[2], tint[3], 0.55)
        f.rays[i] = { l = l, a = (i - 1) / n * pi * 2, len = len * (0.7 + ((i - 1) % 3) * 0.18), w = w }
    end
    function f:Spin(t, k)
        for _, r in ipairs(self.rays) do
            local a = r.a + t * (pi * 2 / 40)
            local l = r.len * k
            r.l:SetStartPoint("CENTER", self, 0, 0)
            r.l:SetEndPoint("CENTER", self, sin(a) * l, cos(a) * l)
            r.l:SetThickness(r.w)
        end
    end
    return f
end

local cofferT = 0
local function BuildCoffer()
    local f = CreateFrame("Frame", nil, stage)
    f:SetAllPoints()
    f.burst = Burst(f, 14, 230, 52, D.C.GOLD)
    f.box = f:CreateTexture(nil, "ARTWORK")
    f.box:SetTexture(Icon("inv_box_02"))
    f.boxFrame = KitTex(f, "cfbox", "ARTWORK", 1)
    f.title = Words(f, 26, MORPHEUS) f.title:SetText("Scourge Coffer") f.title:SetTextColor(244 / 255, 207 / 255, 106 / 255)
    f:Hide()
    -- the rewards
    local l = CreateFrame("Frame", nil, stage)
    l:SetAllPoints()
    l.rule = l:CreateTexture(nil, "ARTWORK")
    local r = A.CLIENT.lvl_rule
    l.rule:SetTexture(r[1]) l.rule:SetTexCoord(r[2], r[3], r[4], r[5]) l.rule:SetBlendMode("ADD")
    l.head = KitTex(l, "level_small", "ARTWORK", 1)
    l.sub = Words(l, 12) l.sub:SetTextColor(234 / 255, 219 / 255, 189 / 255)
    l.rows = {}
    for i = 1, 8 do
        local row = CreateFrame("Frame", nil, l)
        row:SetSize(540, 68)
        row.bg = KitTex(row, "lt_rare", "BACKGROUND")
        row.icon = row:CreateTexture(nil, "ARTWORK") row.icon:SetSize(42, 42)
        row.bd = row:CreateTexture(nil, "ARTWORK", nil, 1) row.bd:SetSize(56, 56)
        row.name = Words(row, 18, MORPHEUS)
        row.type = Words(row, 11) row.type:SetTextColor(GREY[1], GREY[2], GREY[3])
        row.dice = row:CreateTexture(nil, "ARTWORK") row.dice:SetTexture("Interface\\Buttons\\UI-GroupLoot-Dice-Up") row.dice:SetSize(26, 26)
        row.roll = Words(row, 20)
        row.desc = Words(row, 10.5) row.desc:SetTextColor(0.8, 0.76, 0.7) row.desc:SetJustifyH("LEFT") row.desc:SetWidth(330)
        row:EnableMouse(true)
        row:SetScript("OnMouseDown", function(self) if self.relic then l.chosen = self.relic UI.PickRelic() end end)
        l.rows[i] = row
    end
    l.goldIcon = l:CreateTexture(nil, "ARTWORK") l.goldIcon:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon") l.goldIcon:SetSize(14, 14)
    l.gold = Words(l, 13) l.gold:SetTextColor(1, 208 / 255, 64 / 255)
    l.take = CreateFrame("Button", nil, l)
    l.take.bg = Slice3(l.take, "gb_big", "BACKGROUND", 0, 19)
    l.take.label = Words(l.take, 15, MORPHEUS) l.take.label:SetText("Take all") l.take.label:SetTextColor(1, 231 / 255, 168 / 255) l.take.label:SetPoint("CENTER")
    l.take:SetScript("OnClick", function()
        if l.relics then
            if not l.chosen then return end
            E.Apply(run, { kind = "relic", id = l.chosen })
            Sound("uber")
        end
        CloseOv(true)
    end)
    l:Hide()
    -- the legendary: WoW's legendary glow blooms, the item pops in its ring, then its name, what made it, the
    -- weapon at work in a window, and the button
    local g = CreateFrame("Frame", nil, stage)
    g:SetAllPoints()
    g.glow = LegendGlow(g, "BACKGROUND", 2)
    g.icon = g:CreateTexture(nil, "ARTWORK", nil, 1)
    g.mask = g:CreateMaskTexture()
    g.mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    g.mask:SetAllPoints(g.icon)
    g.icon:AddMaskTexture(g.mask)
    g.ring = KitTex(g, "c2_ring_legendary", "ARTWORK", 2)
    g.eyebrow = Words(g, 11) g.eyebrow:SetText("L E G E N D A R Y") g.eyebrow:SetTextColor(1, 0.62, 0.22)
    g.name = KitTex(g, "lgname_ashbringer", "ARTWORK", 1)
    g.recipe = Words(g, 12) g.recipe:SetTextColor(203 / 255, 185 / 255, 148 / 255)
    g.pvHost = CreateFrame("Frame", nil, g)
    g.pvHost:SetSize(560, 210)
    g.pv = NewPreview(g.pvHost)
    g.pv.frame:SetAllPoints()
    g.pvTop = CreateFrame("Frame", nil, g.pvHost)
    g.pvTop:SetAllPoints()
    g.pvTop:SetFrameLevel(g.pvHost:GetFrameLevel() + 60)
    g.glass = Slice3(g.pvTop, "c2_glass", "OVERLAY", 0, 30)
    g.edge = g.pvTop:CreateTexture(nil, "BORDER")
    g.edge:SetPoint("TOPLEFT", -2, 2) g.edge:SetPoint("BOTTOMRIGHT", 2, -2) g.edge:SetColorTexture(1, 0.5, 0, 0.5)
    g.edgeIn = g.pvHost:CreateTexture(nil, "BACKGROUND", nil, -8)
    g.edgeIn:SetPoint("TOPLEFT", -3, 3) g.edgeIn:SetPoint("BOTTOMRIGHT", 3, -3) g.edgeIn:SetColorTexture(0, 0, 0, 1)
    g.edge:Hide()
    g.desc = Words(g, 14) g.desc:SetTextColor(YELLOW[1], YELLOW[2], YELLOW[3]) g.desc:SetWidth(520) g.desc:SetSpacing(4)
    g.rest = Words(g, 12) g.rest:SetTextColor(MUTE[1], MUTE[2], MUTE[3])
    g.take = CreateFrame("Button", nil, g)
    g.take.bg = Slice3(g.take, "gb_big", "BACKGROUND", 0, 19)
    g.take.label = Words(g.take, 15, MORPHEUS) g.take.label:SetTextColor(1, 231 / 255, 168 / 255) g.take.label:SetPoint("CENTER")
    g.take:SetScript("OnClick", function() UI.TakeLegend() end)
    g.take:SetScript("OnEnter", function(self) Sound("hover", 0.03) self.bg:SetKit("gb_bighov") self.bg:Place(self, 0, 0, self:GetWidth(), 36) end)
    g.take:SetScript("OnLeave", function(self) self.bg:SetKit("gb_big") self.bg:Place(self, 0, 0, self:GetWidth(), 36) end)
    g:Hide()
    return f, l, g
end

ShowChest = function()
    local ch = run.chest
    run.chest = nil
    overlay = "chest"
    run.paused = true
    ClearOv()
    ov.dim:Show()
    local f = ov.coffer
    f:Show()
    f.legend = nil
    for _, it in ipairs(ch.items) do if it.kind == "legend" then f.legend = it end end
    f.items, f.gold, f.relics = ch.items, ch.gold, ch.relics
    local H = StageH()
    local cx, cy = OV_W / 2, H / 2 - 20
    f.burst:ClearAllPoints() f.burst:SetPoint("CENTER", f, "TOPLEFT", cx, -cy)
    f.box:ClearAllPoints() f.box:SetPoint("CENTER", f, "TOPLEFT", cx, -cy) f.box:SetSize(88, 88) f.box:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    KitSet(f.boxFrame, f.legend and "cfbox_leg" or "cfbox")
    KitAt(f.boxFrame, f, cx - 46, cy - 46, 92, 92)
    f.title:ClearAllPoints() f.title:SetPoint("TOP", f, "TOPLEFT", cx, -(cy + 76 + 8))
    cofferT = 0
    Sound("coin")
end

local function ShowLoot(items, gold, relics)
    overlay = "chest"
    ClearOv()
    ov.dim:Show()
    local l = ov.loot
    l:Show()
    l.relics, l.chosen = relics, nil
    if relics then
        local all = {}
        for _, o in ipairs(items) do all[#all + 1] = o end
        for _, o in ipairs(relics) do all[#all + 1] = o end
        items = all
    end
    local H = StageH()
    local n = #items
    local step = n > 5 and 70 or 76               -- (a boss coffer's relics: a tighter list)
    local blockH = 14 + 44 + 18 + n * step + 30 + 40
    local y = max(10, H / 2 - blockH / 2)
    local x0 = OV_W / 2 - 270
    l.rule:ClearAllPoints() l.rule:SetPoint("TOP", l, "TOPLEFT", OV_W / 2, -y) l.rule:SetSize(440, 14)
    local hw = K.level_small[6] - 2 * K.level_small[8]
    KitAt(l.head, l, OV_W / 2 - hw / 2, y + 14)
    l.sub:SetText(relics and "Need one relic \194\183 it lasts this run" or (n .. " reward" .. (n > 1 and "s" or "") .. " \194\183 Need rolls"))
    l.sub:ClearAllPoints() l.sub:SetPoint("TOP", l, "TOPLEFT", OV_W / 2, -(y + 14 + 46))
    y = y + 14 + 46 + 24
    l.rolls = {}
    for i, row in ipairs(l.rows) do
        local o = items[i]
        if o then
            local f = OptInfo(o)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", l, "TOPLEFT", x0, -y)
            KitSet(row.bg, "lt_" .. f.q)
            KitAt(row.bg, row, 0, 0, 540, 68)
            row.icon:SetTexture(Icon(f.icon)) row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            row.icon:ClearAllPoints() row.icon:SetPoint("LEFT", row, "LEFT", 16, 0)
            local bd = A.CLIENT[QBD[f.q]]
            row.bd:SetTexture(bd[1]) row.bd:SetTexCoord(bd[2], bd[3], bd[4], bd[5])
            row.bd:ClearAllPoints() row.bd:SetPoint("CENTER", row.icon, "CENTER")
            row.name:SetText(f.name)
            FitLine(row.name, MORPHEUS, 18, 11, 330)
            local qc = Q[f.q]
            row.name:SetTextColor(qc[1], qc[2], qc[3])
            row.name:ClearAllPoints() row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 76, -16)
            row.type:SetText(f.sub .. (f.r > 0 and (" \194\183 Rank " .. f.r) or ""))
            row.type:ClearAllPoints() row.type:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
            row.dice:ClearAllPoints() row.dice:SetPoint("RIGHT", row, "RIGHT", -60, 0)
            row.roll:ClearAllPoints() row.roll:SetPoint("LEFT", row.dice, "RIGHT", 6, 0)
            row.roll:SetText("\226\128\147")
            row.roll:SetTextColor(0.53, 0.53, 0.53)
            row.relic = o.kind == "relic" and o.id or nil
            row.dim = nil
            row.desc:SetShown(row.relic ~= nil)
            if row.relic then
                row.name:ClearAllPoints() row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 76, -9)
                row.type:SetText(f.sub)
                row.desc:SetText(f.desc) row.desc:ClearAllPoints() row.desc:SetPoint("TOPLEFT", row.type, "BOTTOMLEFT", 0, -2)
                row.dice:Hide() row.roll:SetText("Need") row.roll:SetTextColor(1, 0.82, 0.25)
            else row.dice:Show() end
            row.delay = (i - 1) * 0.28
            row.final = 40 + floor(math.random() * 59)
            row.done = false
            row:SetAlpha(0)
            row:Show()
            l.rolls[#l.rolls + 1] = row
            y = y + step
        else
            row:Hide()
        end
    end
    l.gold:SetText(gold .. " gold")
    l.gold:ClearAllPoints() l.gold:SetPoint("TOP", l, "TOPLEFT", OV_W / 2 + 10, -(y + 6))
    l.goldIcon:ClearAllPoints() l.goldIcon:SetPoint("RIGHT", l.gold, "LEFT", -6, 0)
    l.take:ClearAllPoints() l.take:SetPoint("TOP", l, "TOPLEFT", OV_W / 2, -(y + 34)) l.take:SetSize(124, 36) l.take.bg:Place(l.take, 0, 0, 124, 36)
    l.take.label:SetText(relics and "Choose a relic" or "Take all")
    l.take:SetAlpha(relics and 0.55 or 1)
    l.t = 0
end
UI._ShowLoot = ShowLoot
function UI.PickRelic(id)
    local l = ov.loot
    if id then l.chosen = id end
    for _, row in ipairs(l.rows) do
        if row:IsShown() and row.relic then
            local on = row.relic == l.chosen
            local rl = D.RELICS[row.relic]
            KitSet(row.bg, on and "lt_legendary" or (rl.legend and "lt_legendary" or "lt_epic"))
            KitAt(row.bg, row, 0, 0, 540, 68)
            row.dim = (not l.chosen or on) and 1 or 0.5
            row:SetAlpha(row.dim)
            row.roll:SetText(on and "Chosen" or "Need")
        end
    end
    if l.chosen then l.take.label:SetText("Take relic") l.take:SetAlpha(1) Sound("hover", 0.02) end
end

local function ShowLegend(id, rest, gold)
    overlay = "legend"
    ClearOv()
    ov.dim:Show()
    local g = ov.legend
    g:Show()
    g.id = id
    local L = LEGEND[id]
    for _, o in ipairs(rest) do E.Apply(run, o) end
    local H = StageH()
    local cx = OV_W / 2
    local nk = id == "consecration" and "lgname_ashbringer" or id == "cleave" and "lgname_thunderfury" or "lgname_atiesh"
    KitSet(g.name, nk)
    local nw, nh = K[nk][6] - 2 * K[nk][8], K[nk][7] - 2 * K[nk][8]
    g.desc:SetText(L.desc)
    local dh = g.desc:GetStringHeight() or 40
    local blockH = 96 + 22 + nh + 30 + 210 + 14 + dh + (#rest > 0 and 26 or 0) + 12 + 36
    local y = max(8, H / 2 - blockH / 2)
    -- the glow and the item, in its ring
    local iy = y + 48
    g.glow:Place(cx, iy, 360)
    g.icon:ClearAllPoints() g.icon:SetPoint("CENTER", g, "TOPLEFT", cx, -iy) g.icon:SetTexture(Icon(L.icon)) g.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    g.iconY = iy
    y = y + 96 + 6
    g.eyebrow:ClearAllPoints() g.eyebrow:SetPoint("TOP", g, "TOPLEFT", cx, -y)
    y = y + 16
    KitAt(g.name, g, cx - nw / 2, y)
    y = y + nh + 4
    g.recipe:SetText(string.format("|T%s:16:16|t %s rank 5   |cffd9b25e+|r   |T%s:16:16|t %s", Icon(SPELLS[id].icon), SPELLS[id].name, Icon(PASSIVES[L.need].icon), PASSIVES[L.need].name))
    g.recipe:ClearAllPoints() g.recipe:SetPoint("TOP", g, "TOPLEFT", cx, -y)
    y = y + 26
    g.pvHost:ClearAllPoints() g.pvHost:SetPoint("TOPLEFT", g, "TOPLEFT", cx - 280, -y)
    g.glass:Place(g.pvTop, 0, 0, 560, 210)
    StartPreview(g.pv, 560, 210, { spell = id, r = 5, legend = true, cls = SPELLS[id].cls, n = 12, vw = 520, camY = 0.55, r0 = id == "cleave" and 40 or 60, r1 = id == "cleave" and 110 or 170 })
    y = y + 210 + 14
    g.desc:ClearAllPoints() g.desc:SetPoint("TOP", g, "TOPLEFT", cx, -y)
    y = y + dh + 6
    if #rest > 0 then
        local s = "Also in the coffer: "
        for _, o in ipairs(rest) do s = s .. "|T" .. Icon(OptInfo(o).icon) .. ":18:18|t " end
        g.rest:SetText(s .. "\194\183 " .. gold .. " gold")
        g.rest:ClearAllPoints() g.rest:SetPoint("TOP", g, "TOPLEFT", cx, -y) g.rest:Show()
        y = y + 26
    else g.rest:Hide() end
    g.take.label:SetText("Take up " .. L.name:match("^[^,]+"))
    local w = floor((g.take.label:GetStringWidth() or 120) + 48)
    g.take:ClearAllPoints() g.take:SetPoint("TOP", g, "TOPLEFT", cx, -(y + 6)) g.take:SetSize(w, 36)
    g.take.bg:SetKit("gb_big") g.take.bg:Place(g.take, 0, 0, w, 36)
    g.t = 0
    UI.TickLegend(0)
end
function UI.TakeLegend()
    if overlay ~= "legend" then return end
    E.Apply(run, { kind = "legend", id = ov.legend.id })
    Sound("uber")
    if UI.pendingRelics then local r = UI.pendingRelics UI.pendingRelics = nil ShowLoot({}, 0, r) return end
    CloseOv(true)
end

function UI.TickLegend(dt)
    local g = ov.legend
    g.t = g.t + dt
    local t = g.t
    local function at(t0, d) return min(1, max(0, (t - t0) / d)) end
    g.glow:Tick(t, Easing(at(0, 0.7)), 1)
    local k = at(0.15, 0.6)
    local e = max(0.05, OvershootEase(k))
    g.icon:SetSize(84 * e, 84 * e) g.icon:SetAlpha(k)
    g.ring:SetAlpha(k)
    KitAtK(g.ring, g, OV_W / 2 - 46 * e, g.iconY - 46 * e, 92 / 72 * e)
    local a1, a2, a3 = at(0.45, 0.4), at(0.7, 0.45), at(0.95, 0.4)
    g.eyebrow:SetAlpha(a1) g.name:SetAlpha(a1)
    g.recipe:SetAlpha(a2) g.pvHost:SetAlpha(a2)
    g.desc:SetAlpha(a3) g.rest:SetAlpha(a3) g.take:SetAlpha(a3)
end

local function TickChest(dt)
    local f = ov.coffer
    if f:IsShown() then
        cofferT = cofferT + dt
        local k = min(1, cofferT / 1.1)
        f.burst:Spin(cofferT, min(1, cofferT / 0.9))
        -- the box: pops in, shakes, flares (the mockup's cfshake)
        local s, rot, br = 1, 0, 1
        if k < 0.2 then s = 0.3 + (1.1 - 0.3) * k / 0.2 elseif k < 0.92 then s = 1.1 - 0.1 * min(1, (k - 0.2) / 0.1) + (k > 0.8 and (k - 0.8) / 0.12 * 0.15 or 0) rot = (k < 0.8 and sin((k - 0.2) / 0.1 * pi) * 5 or 0) else s = 1.15 + (k - 0.92) / 0.08 * 0.15 br = 1 + (k - 0.92) / 0.08 * 2 end
        local sz = 88 * s
        f.box:SetSize(sz, sz)
        Rd.Rot(f.box, rot * pi / 180, 0.07, 0.07, 0.93, 0.93)
        f.box:SetVertexColor(min(1, br), min(1, br), min(1, br), k > 0.92 and max(0.2, 1 - (k - 0.92) / 0.08 * 0.8) or 1)
        f.boxFrame:SetAlpha(f.box:GetAlpha())
        if cofferT >= 1.1 then
            if f.legend then
                Sound("rep") Sound("naaru")
                local rest = {}
                for _, it in ipairs(f.items) do if it ~= f.legend then rest[#rest + 1] = it end end
                UI.pendingRelics = f.relics
                ShowLegend(f.legend.id, rest, f.gold)
            else
                Sound("pick")
                ShowLoot(f.items, f.gold, f.relics)
            end
        end
    end
    local l = ov.loot
    if l:IsShown() then
        l.t = l.t + dt
        for i, row in ipairs(l.rolls or {}) do
            if row.relic then row.done = true end
            local k = min(1, max(0, (l.t - row.delay) / 0.5))
            local e = OvershootEase(k)
            row:SetAlpha(min(1, k * 2) * (row.dim or 1))
            if not row.done then
                local n = floor((l.t - row.delay) / 0.045)
                if n > 10 + (i - 1) * 6 then
                    row.done = true row.roll:SetText(tostring(row.final)) row.roll:SetTextColor(1, 1, 1) Sound("hover", 0.02)
                elseif n > 0 then row.roll:SetText(tostring(1 + floor(math.random() * 100))) end
            end
        end
    end
    local g = ov.legend
    if g:IsShown() then UI.TickLegend(dt) end
end

---------------------------------------------------------------------------
-- the end of a run, the pause, the title
---------------------------------------------------------------------------
-- the end of a run: no box - the world sinks into a red (or gold) dusk, the verdict between the header's rules, what
-- you did as numbers on hairlines, your kit as medals, the Argent Dawn's thanks on a standing bar, then the buttons
local STANDING = { { 42000, "Exalted" }, { 21000, "Revered" }, { 9000, "Honored" }, { 3000, "Friendly" }, { 0, "Neutral" } }
local function Standing(rep)
    for i, s in ipairs(STANDING) do
        if rep >= s[1] then return s[2], s[1], (STANDING[i - 1] or s)[1] end
    end
    return "Neutral", 0, 3000
end
UI.Standing = Standing

local function BuildEnd()
    local f = CreateFrame("Frame", nil, stage)
    f:SetAllPoints()
    f.dusk = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    f.dusk:SetAllPoints() f.dusk:SetColorTexture(1, 1, 1, 1)
    f.vig = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.vig:SetTexture(D.MEDIA .. "UI\\dark_hole")
    f.glow = LegendGlow(f, "BACKGROUND", 2)
    f.head = KitTex(f, "hd_frame", "BACKGROUND", 3)
    f.eyebrow = Words(f, 11)
    f.title = Words(f, 44, MORPHEUS)
    f.title:SetShadowOffset(0, -3)
    f.lede = Words(f, 14) f.lede:SetTextColor(0.86, 0.82, 0.76)
    f.best = Words(f, 11) f.best:SetTextColor(1, 0.82, 0.3)
    f.stats = {}
    for i = 1, 5 do
        local s = { v = Words(f, 26, MORPHEUS), l = Words(f, 10) }
        s.v:SetTextColor(1, 1, 1)
        s.l:SetTextColor(157 / 255, 147 / 255, 163 / 255)
        if i > 1 then s.sep = f:CreateTexture(nil, "ARTWORK") s.sep:SetColorTexture(1, 1, 1, 1) end
        f.stats[i] = s
    end
    f.medals = {}
    for i = 1, 14 do
        local m = { icon = f:CreateTexture(nil, "ARTWORK", nil, 1), ring = KitTex(f, "c2_ring_rare", "ARTWORK", 2) }
        m.mask = f:CreateMaskTexture()
        m.mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        m.mask:SetAllPoints(m.icon)
        m.icon:AddMaskTexture(m.mask)
        f.medals[i] = m
    end
    -- the Argent Dawn: standing, a bar to the next one, what this run gave
    f.repL = Words(f, 11) f.repL:SetTextColor(0.86, 0.82, 0.76)
    f.repR = Words(f, 11) f.repR:SetTextColor(0.65, 0.95, 0.45)
    f.barBg = f:CreateTexture(nil, "ARTWORK", nil, 0) f.barBg:SetColorTexture(0, 0, 0, 0.7)
    f.barEdge = f:CreateTexture(nil, "ARTWORK", nil, -1) f.barEdge:SetColorTexture(201 / 255, 163 / 255, 90 / 255, 0.55)
    f.barOld = f:CreateTexture(nil, "ARTWORK", nil, 1) f.barOld:SetColorTexture(1, 1, 1, 1)
    ns.UI:GradientRGBA(f.barOld, "VERTICAL", 0.1, 0.45, 0.12, 1, 0.3, 0.75, 0.25, 1)
    f.barNew = f:CreateTexture(nil, "ARTWORK", nil, 1) f.barNew:SetColorTexture(1, 1, 1, 1)
    ns.UI:GradientRGBA(f.barNew, "VERTICAL", 0.45, 0.85, 0.3, 1, 0.75, 1, 0.55, 1)
    f.again = CreateFrame("Button", nil, f)
    f.again.bg = Slice3(f.again, "gb_big", "BACKGROUND", 0, 19)
    f.again.label = Words(f.again, 16, MORPHEUS) f.again.label:SetTextColor(1, 231 / 255, 168 / 255) f.again.label:SetPoint("CENTER")
    f.again:SetScript("OnClick", function() UI.Start(run.cls, { stage = run.stage ~= "epl" and run.stage or nil }) end)
    f.again:SetScript("OnEnter", function(self) Sound("hover", 0.03) self.bg:SetKit("gb_bighov") self.bg:Place(self, 0, 0, self:GetWidth(), 38) end)
    f.again:SetScript("OnLeave", function(self) self.bg:SetKit("gb_big") self.bg:Place(self, 0, 0, self:GetWidth(), 38) end)
    f.menu = CreateFrame("Button", nil, f)
    f.menu.bg = Slice3(f.menu, "gb", "BACKGROUND", 0, 15)
    f.menu.label = Words(f.menu, 12) f.menu.label:SetTextColor(234 / 255, 223 / 255, 198 / 255) f.menu.label:SetPoint("CENTER") f.menu.label:SetText("Choose class")
    f.menu:SetScript("OnClick", function() if run.stage and run.stage ~= "epl" then UI.ShowNaxx() else ShowTitle() end end)
    f.menu:SetScript("OnEnter", function(self) Sound("hover", 0.03) self.bg:SetKit("gb_hov") self.bg:Place(self, 0, 0, self:GetWidth(), 30) end)
    f.menu:SetScript("OnLeave", function(self) self.bg:SetKit("gb") self.bg:Place(self, 0, 0, self:GetWidth(), 30) end)
    f:Hide()
    return f
end

ShowEnd = function(kind)
    overlay = "end"
    run.paused = true
    ClearOv()
    local f = ov["end"]
    f:Show()
    local win = kind == "victory"
    f.win = win
    local naxx = run.stage and run.stage ~= "epl"
    local ST = run.ST or {}
    local rep = floor((run.t * 0.9 + run.kills * 0.4 + run.bossKills * 150 + (run.stones or 0) * D.STONE_REP) * (naxx and 1.5 or 1) + 0.5)
    local d = ns.HTLGame and ns.HTLGame.Data() or { best = 0, rep = 0 }
    local prevBest, prevRep = d.best or 0, d.rep or 0
    if ns.HTLGame then ns.HTLGame:Finished(run, win, rep) end
    local H = StageH()
    local cx = OV_W / 2
    -- the dusk: red for a death, a warm gold for the line held
    if win then ns.UI:GradientRGBA(f.dusk, "VERTICAL", 0.05, 0.03, 0.01, 0.92, 0.12, 0.08, 0.02, 0.72)
    else ns.UI:GradientRGBA(f.dusk, "VERTICAL", 0.03, 0, 0, 0.94, 0.16, 0.01, 0.01, 0.74) end
    f.vig:ClearAllPoints() f.vig:SetPoint("CENTER", f, "TOPLEFT", cx, -H * 0.45) f.vig:SetSize(OV_W * 1.4, H * 1.5)
    f.vig:SetVertexColor(win and 0.2 or 0.15, win and 0.12 or 0, 0, 0.9)
    local blockH = 112 + 22 + 58 + 30 + 46 + 28 + 44 + 30 + 38
    local y = max(10, H / 2 - blockH / 2)
    -- the verdict between the rules
    KitAt(f.head, f, cx - 260, y, 520, 112)
    f.head:SetVertexColor(1, win and 1 or 0.45, win and 1 or 0.35, 1)
    f.glow:SetShown(win)
    if win then f.glow:Place(cx, y + 52, 420) end
    f.eyebrow:SetText(naxx and ((ST.name or "Naxxramas"):upper():gsub("(.)", "%1 "):gsub(" $", ""):gsub("   ", "   ")) or win and "T H E   L I N E   H E L D" or "E A S T E R N   P L A G U E L A N D S")
    f.eyebrow:SetTextColor(win and 1 or 0.9, win and 0.82 or 0.55, win and 0.4 or 0.5)
    f.eyebrow:ClearAllPoints() f.eyebrow:SetPoint("TOP", f, "TOPLEFT", cx, -(y + 22))
    f.title:SetText(win and "Victory" or "You have died")
    if win then f.title:SetTextColor(1, 0.84, 0.42) else f.title:SetTextColor(0.92, 0.26, 0.2) end
    f.title:ClearAllPoints() f.title:SetPoint("TOP", f, "TOPLEFT", cx, -(y + 35))
    y = y + 112
    local finale = naxx and ST.finale and D.MOBS[ST.finale]
    f.lede:SetText(naxx and win and (run.stage == "frost" and "Kel'Thuzad falls. The necropolis lurches and lifts away north."
            or ((finale and finale.horseman and "The Four Horsemen fall" or ((finale and finale.name or "The master") .. " falls")) .. " at " .. Rd.Clock(run.t) .. ". " .. (ST.name or "The quarter") .. " is cleared."))
        or win and "The Pale Rider claimed you at the fifteenth minute. The Argent Dawn counts it a victory."
        or run.gaveUp and ("You gave up the line at " .. Rd.Clock(run.t) .. ".")
        or ("Slain by |cffffffff" .. (run.killer or "the Scourge") .. "|r at " .. Rd.Clock(run.t) .. "."))
    f.lede:ClearAllPoints() f.lede:SetPoint("TOP", f, "TOPLEFT", cx, -y)
    local newBest = floor(run.t) > prevBest and prevBest > 0
    f.best:SetText(newBest and not naxx and ("N E W   B E S T  \194\183  was " .. Rd.Clock(prevBest)) or "")
    if naxx then
        local bits = {}
        if (run.frozen or 0) > 0 then bits[#bits + 1] = "+" .. run.frozen .. " Frozen Runes" end
        for _, slot in ipairs(run.awarded or {}) do bits[#bits + 1] = "|T" .. Icon(D.T3Icon(run.cls, slot)) .. ":16:16|t Desecrated " .. D.T3_SLOT[slot].name end
        f.best:SetText(table.concat(bits, "   "))
    end
    f.best:ClearAllPoints() f.best:SetPoint("TOP", f, "TOPLEFT", cx, -(y + 20))
    y = y + 22 + 30
    -- the numbers: five plates on hairlines
    local vals = { { naxx and "TIME" or "SURVIVED", Rd.Clock(run.t) }, { "LEVEL", tostring(run.level) }, { "SLAIN", tostring(run.kills) }, { "BOSSES", tostring(run.bossKills) }, { "GOLD BANKED", tostring(run.gold) } }
    local pw = 118
    local x0 = cx - pw * 5 / 2
    for i, s in ipairs(f.stats) do
        local sx = x0 + (i - 1) * pw
        s.v:SetText(vals[i][2]) s.v:ClearAllPoints() s.v:SetPoint("TOP", f, "TOPLEFT", sx + pw / 2, -y)
        s.l:SetText(vals[i][1]) s.l:ClearAllPoints() s.l:SetPoint("TOP", f, "TOPLEFT", sx + pw / 2, -(y + 32))
        if s.sep then s.sep:ClearAllPoints() s.sep:SetPoint("TOPLEFT", f, "TOPLEFT", sx, -(y + 2)) s.sep:SetSize(1, 40)
            ns.UI:GradientRGBA(s.sep, "VERTICAL", 1, 1, 1, 0, 1, 1, 1, 0.16) end
    end
    y = y + 46 + 28
    -- the kit: spells then blessings, as medals (legendaries in orange)
    local list = {}
    for _, id in ipairs(run.order) do list[#list + 1] = { run.legend[id] and LEGEND[id].icon or SPELLS[id].icon, run.legend[id] and "legendary" or "rare", 38 } end
    for _, id in ipairs(run.porder) do list[#list + 1] = { PASSIVES[id].icon, "uncommon", 30 } end
    for _, id in ipairs(run.rorder or {}) do local rl = D.RELICS[id] list[#list + 1] = { rl.icon, rl.legend and "legendary" or "epic", 34 } end
    local tot = 0
    for _, m in ipairs(list) do tot = tot + m[3] + 10 end
    local mx = cx - (tot - 10) / 2
    for i, m in ipairs(f.medals) do
        local e = list[i]
        if e then
            local s = e[3]
            m.icon:SetTexture(Icon(e[1])) m.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            m.icon:ClearAllPoints() m.icon:SetPoint("TOPLEFT", f, "TOPLEFT", mx, -(y + (38 - s) / 2)) m.icon:SetSize(s, s)
            KitSet(m.ring, "c2_ring_" .. e[2])
            KitAtK(m.ring, f, mx - s * 0.06, y + (38 - s) / 2 - s * 0.06, s * 1.12 / 72)
            m.icon:Show() m.ring:Show()
            mx = mx + s + 10
        else m.icon:Hide() m.ring:Hide() end
    end
    y = y + 44 + 22
    -- the Argent Dawn
    local name, lo, hi = Standing(prevRep + rep)
    local span = max(1, hi - lo)
    local bw = 360
    f.repL:SetText("Argent Dawn  |cfff4cf6a" .. name .. "|r")
    f.repL:ClearAllPoints() f.repL:SetPoint("BOTTOMLEFT", f, "TOPLEFT", cx - bw / 2, -(y - 4))
    f.repR:SetText("+" .. rep .. " reputation")
    f.repR:ClearAllPoints() f.repR:SetPoint("BOTTOMRIGHT", f, "TOPLEFT", cx + bw / 2, -(y - 4))
    f.barEdge:ClearAllPoints() f.barEdge:SetPoint("TOPLEFT", f, "TOPLEFT", cx - bw / 2 - 1, -(y - 1)) f.barEdge:SetSize(bw + 2, 10)
    f.barBg:ClearAllPoints() f.barBg:SetPoint("TOPLEFT", f, "TOPLEFT", cx - bw / 2, -y) f.barBg:SetSize(bw, 8)
    local k0 = min(1, max(0, (prevRep - lo) / span))
    local k1 = min(1, max(0, (prevRep + rep - lo) / span))
    if prevRep < lo then k0 = 0 end
    f.barOld:ClearAllPoints() f.barOld:SetPoint("TOPLEFT", f, "TOPLEFT", cx - bw / 2, -y) f.barOld:SetSize(max(0.1, bw * k0), 8)
    f.barNew:ClearAllPoints() f.barNew:SetPoint("TOPLEFT", f, "TOPLEFT", cx - bw / 2 + bw * k0, -y) f.barNew:SetSize(max(0.1, bw * (k1 - k0)), 8)
    y = y + 8 + 30
    -- the buttons
    f.again.label:SetText(naxx and (win and "Again" or "Release Spirit") or win and "Hold it again" or "Release Spirit")
    f.menu.label:SetText(naxx and "Necropolis" or "Choose class")
    local aw = floor((f.again.label:GetStringWidth() or 100) + 52)
    f.again:ClearAllPoints() f.again:SetPoint("TOPRIGHT", f, "TOPLEFT", cx - 6, -y) f.again:SetSize(aw, 38)
    f.again.bg:SetKit("gb_big") f.again.bg:Place(f.again, 0, 0, aw, 38)
    f.menu:ClearAllPoints() f.menu:SetPoint("TOPLEFT", f, "TOPLEFT", cx + 6, -(y + 4)) f.menu:SetSize(124, 30)
    f.menu.bg:SetKit("gb") f.menu.bg:Place(f.menu, 0, 0, 124, 30)
    f.t = 0
end
local function TickEnd(dt)
    local f = ov["end"]
    if not f:IsShown() then return end
    f.t = f.t + dt
    local k = min(1, f.t / 0.6)
    f:SetAlpha(k)
    if f.win then f.glow:Tick(f.t, Easing(k), 0.85) end
end


---------------------------------------------------------------------------
-- talents: the Argent Dawn's three trees on the classic talent frame's paintings, bought with banked gold
---------------------------------------------------------------------------
local TW, TH, TGAP = 300, 430, 24
local TB, TB5 = 40, 48                      -- a talent's button; the capstone's
local GOLDICON = "Interface\\MoneyFrame\\UI-GoldIcon"
local function TalentXY(t)
    return TW / 2 + (t.col - 2.5) * 66, 70 + (t.tier - 1) * 70
end
local function Edge(f, layer, r, g, b, a, inset)
    local e = {}
    for i = 1, 4 do e[i] = f:CreateTexture(nil, layer) e[i]:SetColorTexture(r, g, b, a) end
    inset = inset or 0
    e[1]:SetPoint("TOPLEFT", -inset, inset) e[1]:SetPoint("TOPRIGHT", inset, inset) e[1]:SetHeight(1)
    e[2]:SetPoint("BOTTOMLEFT", -inset, -inset) e[2]:SetPoint("BOTTOMRIGHT", inset, -inset) e[2]:SetHeight(1)
    e[3]:SetPoint("TOPLEFT", -inset, inset) e[3]:SetPoint("BOTTOMLEFT", -inset, -inset) e[3]:SetWidth(1)
    e[4]:SetPoint("TOPRIGHT", inset, inset) e[4]:SetPoint("BOTTOMRIGHT", inset, -inset) e[4]:SetWidth(1)
    return e
end
local function TalentTip(b)
    local t, G = b.t, ns.HTLGame
    if not (GameTooltip and G) then return end
    local r = G:Rank(t.id)
    local ok, why, need = G:CanBuy(t.id)
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    GameTooltip:AddLine(t.name, 1, 1, 1)
    GameTooltip:AddLine("Rank " .. r .. "/" .. t.max, 1, 0.82, 0)
    if r > 0 then GameTooltip:AddLine(t.desc(r), 1, 0.82, 0, true) end
    if r < t.max then
        if r > 0 then GameTooltip:AddLine(" ") GameTooltip:AddLine("Next rank:", 1, 1, 1) end
        GameTooltip:AddLine(t.desc(r + 1), 1, 0.82, 0, true)
        GameTooltip:AddLine(" ")
        if why == "locked" then
            local tr
            for _, x in ipairs(D.TALENT_TREES) do if x.id == t.tree then tr = x end end
            GameTooltip:AddLine("Requires " .. need .. " points in " .. tr.name, 1, 0.25, 0.25)
        end
        local cost = G:Cost(t.id)
        GameTooltip:AddLine(string.format("|T%s:12:12|t %d gold", GOLDICON, cost), why == "gold" and 1 or 1, why == "gold" and 0.25 or 1, why == "gold" and 0.25 or 1)
        if ok then GameTooltip:AddLine("Click to learn", 0.25, 1, 0.25) end
    end
    GameTooltip:Show()
end

local function BuildTalents()
    local f = CreateFrame("Frame", nil, stage)
    f:SetAllPoints()
    f.night = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    f.night:SetAllPoints() f.night:SetColorTexture(1, 1, 1, 1)
    ns.UI:GradientRGBA(f.night, "VERTICAL", 4 / 255, 3 / 255, 7 / 255, 0.97, 14 / 255, 10 / 255, 20 / 255, 0.9)
    f.head = KitTex(f, "hd_frame", "BACKGROUND", 1)
    f.title = Words(f, 30, MORPHEUS) f.title:SetText("Argent Dawn Talents") f.title:SetTextColor(244 / 255, 207 / 255, 106 / 255)
    f.title:SetShadowOffset(0, -2)
    f.sub = Words(f, 11) f.sub:SetTextColor(157 / 255, 147 / 255, 163 / 255)
    f.sub:SetText("Bought with the gold you carry home  \194\183  every class, every character")
    f.coin = f:CreateTexture(nil, "ARTWORK") f.coin:SetTexture(GOLDICON) f.coin:SetSize(16, 16)
    f.bank = Words(f, 22, MORPHEUS) f.bank:SetTextColor(1, 0.84, 0.3)
    f.trees, f.btns = {}, {}
    for i, tr in ipairs(D.TALENT_TREES) do
        local p = CreateFrame("Frame", nil, f)
        p:SetSize(TW, TH)
        pcall(p.SetClipsChildren, p, true)
        -- the painting: the classic frame's four pieces (320 x 384 together), covering the tree
        local k = math.max(TW / 320, TH / 384)
        local ox = (TW - 320 * k) / 2
        local base = "Interface\\TalentFrame\\" .. tr.art
        local pieces = { { "-TopLeft", 0, 0, 256, 256 }, { "-TopRight", 256, 0, 64, 256 }, { "-BottomLeft", 0, 256, 256, 128 }, { "-BottomRight", 256, 256, 64, 128 } }
        for _, pc in ipairs(pieces) do
            local t = p:CreateTexture(nil, "BACKGROUND", nil, 0)
            t:SetTexture(base .. pc[1])
            t:SetTexCoord(0, pc[4] / (pc[4] > 64 and 256 or 64), 0, pc[5] / (pc[5] > 128 and 256 or 128))
            t:SetPoint("TOPLEFT", p, "TOPLEFT", ox + pc[2] * k, -pc[3] * k)
            t:SetSize(pc[4] * k, pc[5] * k)
            t:SetVertexColor(0.62, 0.6, 0.62, 1)
        end
        p.shade = p:CreateTexture(nil, "BACKGROUND", nil, 2)
        p.shade:SetAllPoints() p.shade:SetColorTexture(1, 1, 1, 1)
        ns.UI:GradientRGBA(p.shade, "VERTICAL", 6 / 255, 4 / 255, 10 / 255, 0.85, 6 / 255, 4 / 255, 10 / 255, 0.25)
        p.top = p:CreateTexture(nil, "BACKGROUND", nil, 3)
        p.top:SetPoint("TOPLEFT") p.top:SetPoint("TOPRIGHT") p.top:SetHeight(48) p.top:SetColorTexture(1, 1, 1, 1)
        ns.UI:GradientRGBA(p.top, "VERTICAL", 6 / 255, 4 / 255, 10 / 255, 0, 6 / 255, 4 / 255, 10 / 255, 0.85)
        Edge(p, "BORDER", 201 / 255, 163 / 255, 90 / 255, 0.6)
        p.outer = CreateFrame("Frame", nil, f)
        p.outer:SetAllPoints(p)
        Edge(p.outer, "BACKGROUND", 0, 0, 0, 1, 1)
        p.name = Words(p, 22, MORPHEUS) p.name:SetTextColor(tr.color[1], tr.color[2], tr.color[3])
        p.name:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -12) p.name:SetText(tr.name)
        p.pts = Words(p, 11) p.pts:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, -18)
        p.blurb = Words(p, 10) p.blurb:SetTextColor(0.8, 0.76, 0.7) p.blurb:SetPoint("TOPLEFT", p.name, "BOTTOMLEFT", 0, -2) p.blurb:SetText(tr.blurb)
        p.tr = tr
        f.trees[i] = p
    end
    for _, t in ipairs(D.TALENTS) do
        local p
        for _, x in ipairs(f.trees) do if x.tr.id == t.tree then p = x end end
        local sz = t.tier == 5 and TB5 or TB
        local b = CreateFrame("Button", nil, p)
        b:SetSize(sz, sz)
        local x, y = TalentXY(t)
        b:SetPoint("CENTER", p, "TOPLEFT", x, -(y + TB / 2))
        b.t = t
        b.glow = b:CreateTexture(nil, "BACKGROUND", nil, -1)
        b.glow:SetTexture(D.MEDIA .. "UI\\glow") b.glow:SetBlendMode("ADD")
        b.glow:SetPoint("CENTER") b.glow:SetSize(sz * 2.2, sz * 2.2)
        b.edge = b:CreateTexture(nil, "BACKGROUND", nil, 0)
        b.edge:SetPoint("TOPLEFT", -2, 2) b.edge:SetPoint("BOTTOMRIGHT", 2, -2) b.edge:SetColorTexture(1, 1, 1, 1)
        b.black = b:CreateTexture(nil, "BACKGROUND", nil, 1)
        b.black:SetPoint("TOPLEFT", -1, 1) b.black:SetPoint("BOTTOMRIGHT", 1, -1) b.black:SetColorTexture(0, 0, 0, 1)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints() b.icon:SetTexture(Icon(t.icon)) b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        b.hi = b:CreateTexture(nil, "HIGHLIGHT")
        b.hi:SetAllPoints() b.hi:SetColorTexture(1, 1, 1, 0.15)
        b.rankBg = b:CreateTexture(nil, "OVERLAY", nil, 0)
        b.rankBg:SetColorTexture(0, 0, 0, 0.9)
        b.rankBg:SetPoint("CENTER", b, "BOTTOMRIGHT", -2, 2) b.rankBg:SetSize(t.max > 1 and 26 or 16, 14)
        b.rankEdge = b:CreateTexture(nil, "OVERLAY", nil, -1)
        b.rankEdge:SetPoint("TOPLEFT", b.rankBg, "TOPLEFT", -1, 1) b.rankEdge:SetPoint("BOTTOMRIGHT", b.rankBg, "BOTTOMRIGHT", 1, -1)
        b.rank = Words(b, 10, nil, "OVERLAY") b.rank:SetPoint("CENTER", b.rankBg, "CENTER", 0, 0)
        b.flash = b:CreateTexture(nil, "OVERLAY", nil, 6)
        b.flash:SetTexture(D.MEDIA .. "UI\\glow") b.flash:SetBlendMode("ADD") b.flash:SetPoint("CENTER") b.flash:SetSize(sz * 3, sz * 3) b.flash:Hide()
        b:SetScript("OnEnter", function(self) Sound("hover", 0.03) TalentTip(self) end)
        b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        b:SetScript("OnClick", function(self)
            if ns.HTLGame and ns.HTLGame:Buy(self.t.id) then
                Sound("pick")
                self.flashT = 0 self.flash:Show()
                UI.RefreshTalents()
                TalentTip(self)
            end
        end)
        f.btns[#f.btns + 1] = b
    end
    f.reset = CreateFrame("Button", nil, f)
    f.reset.bg = Slice3(f.reset, "gb", "BACKGROUND", 0, 15)
    f.reset.label = Words(f.reset, 12) f.reset.label:SetText("Unlearn all") f.reset.label:SetPoint("CENTER")
    f.reset:SetScript("OnClick", function() if ns.HTLGame then ns.HTLGame:Reset() Sound("coin") UI.RefreshTalents() end end)
    f.done = CreateFrame("Button", nil, f)
    f.done.bg = Slice3(f.done, "gb_big", "BACKGROUND", 0, 19)
    f.done.label = Words(f.done, 16, MORPHEUS) f.done.label:SetText("Done") f.done.label:SetTextColor(1, 231 / 255, 168 / 255) f.done.label:SetPoint("CENTER")
    f.done:SetScript("OnClick", function() ShowTitle() end)
    for _, bt in ipairs({ f.reset, f.done }) do
        bt:SetScript("OnEnter", function(self) Sound("hover", 0.03) self.bg:SetKit(self == f.done and "gb_bighov" or "gb_hov") self.bg:Place(self, 0, 0, self:GetWidth(), self:GetHeight()) end)
        bt:SetScript("OnLeave", function(self) self.bg:SetKit(self == f.done and "gb_big" or "gb") self.bg:Place(self, 0, 0, self:GetWidth(), self:GetHeight()) end)
    end
    f:Hide()
    return f
end

function UI.RefreshTalents()
    local f, G = ov.talents, ns.HTLGame
    if not (f and G) then return end
    f.bank:SetText(tostring(G.Data().bank))
    for _, p in ipairs(f.trees) do
        local n = G:Spent(p.tr.id)
        p.pts:SetText(n .. (n == 1 and " point" or " points"))
        p.pts:SetTextColor(n > 0 and 1 or 0.6, n > 0 and 0.84 or 0.58, n > 0 and 0.3 or 0.62)
    end
    for _, b in ipairs(f.btns) do
        local t = b.t
        local r = G:Rank(t.id)
        local ok, why = G:CanBuy(t.id)
        local locked = why == "locked"
        local maxed = r >= t.max
        b.icon:SetDesaturated(locked and r == 0)
        b.icon:SetVertexColor(locked and 0.55 or 1, locked and 0.55 or 1, locked and 0.55 or 1)
        local col = maxed and { 1, 0.82, 0.2 } or (r > 0 or ok) and { 0.25, 1, 0.25 } or why == "gold" and { 0.75, 0.62, 0.35 } or { 0.4, 0.4, 0.42 }
        b.edge:SetVertexColor(col[1], col[2], col[3], (locked and r == 0) and 0.45 or 1)
        b.rankEdge:SetColorTexture(col[1], col[2], col[3], 0.9)
        b.rank:SetText(t.max > 1 and (r .. "/" .. t.max) or (maxed and "1" or "0"))
        b.rank:SetTextColor(maxed and 1 or (r > 0 or ok) and 0.25 or 0.62, maxed and 0.82 or (r > 0 or ok) and 1 or 0.6, maxed and 0 or (r > 0 or ok) and 0.25 or 0.64)
        local tc = D.TALENT_TREES[1].color
        for _, x in ipairs(D.TALENT_TREES) do if x.id == t.tree then tc = x.color end end
        b.glow:SetVertexColor(tc[1], tc[2], tc[3], 1)
        b.glow:SetAlpha(maxed and 0.7 or (ok and 0.35 or 0))
    end
end

local talT = 0
local function ShowTalents()
    overlay = "talents"
    ClearOv()
    local f = ov.talents
    f:Show()
    local H = StageH()
    local total = 3 * TW + 2 * TGAP
    local x0 = OV_W / 2 - total / 2
    local blockH = 96 + TH + 22 + 38
    local y = max(8, H / 2 - blockH / 2)
    KitAt(f.head, f, OV_W / 2 - 260, y - 14, 520, 112)
    f.title:ClearAllPoints() f.title:SetPoint("TOP", f, "TOPLEFT", OV_W / 2, -(y + 12))
    f.sub:ClearAllPoints() f.sub:SetPoint("TOP", f, "TOPLEFT", OV_W / 2, -(y + 50))
    f.bank:ClearAllPoints() f.bank:SetPoint("BOTTOMRIGHT", f, "TOPLEFT", x0 + total, -(y + 88))
    f.coin:ClearAllPoints() f.coin:SetPoint("RIGHT", f.bank, "LEFT", -6, 1)
    y = y + 96
    for i, p in ipairs(f.trees) do
        p:ClearAllPoints() p:SetPoint("TOPLEFT", f, "TOPLEFT", x0 + (i - 1) * (TW + TGAP), -y)
    end
    y = y + TH + 22
    f.reset:ClearAllPoints() f.reset:SetPoint("TOPRIGHT", f, "TOPLEFT", OV_W / 2 - 6, -(y + 4)) f.reset:SetSize(120, 30)
    f.reset.bg:SetKit("gb") f.reset.bg:Place(f.reset, 0, 0, 120, 30)
    f.done:ClearAllPoints() f.done:SetPoint("TOPLEFT", f, "TOPLEFT", OV_W / 2 + 6, -y) f.done:SetSize(120, 38)
    f.done.bg:SetKit("gb_big") f.done.bg:Place(f.done, 0, 0, 120, 38)
    talT = 0
    UI.RefreshTalents()
end
UI.ShowTalents = function() ShowTalents() end
local function TickTalents(dt)
    local f = ov.talents
    if not f or not f:IsShown() then return end
    talT = talT + dt
    f:SetAlpha(min(1, talT / 0.25))
    for _, b in ipairs(f.btns) do
        if b.flashT then
            b.flashT = b.flashT + dt
            b.flash:SetAlpha(max(0, 1 - b.flashT / 0.5))
            if b.flashT > 0.5 then b.flash:Hide() b.flashT = nil end
        end
    end
end

---------------------------------------------------------------------------
-- the menu screens' pieces (the approved mockup: dev/art/casc/survivors_mockup/hall_design.html, cut into the kit by
-- kit3.html): nine-sliced plates and glass, medallions, the header, the veil. Every screen is laid out in the
-- mockup's 1148 x 646 and centred in a taller stage.
---------------------------------------------------------------------------
local MOCK_H = 646
local CLS_ICON = { PALADIN = { 0, 0.25, 0.5, 0.75 }, MAGE = { 0.25, 0.5, 0, 0.25 }, WARRIOR = { 0, 0.25, 0, 0.25 } }
local CLS_TEX = "Interface\\TargetingFrame\\UI-Classes-Circles"
local CLS_PLATE = { PALADIN = "pal", MAGE = "mage", WARRIOR = "war" }
local function Spaced(s) return (s:upper():gsub("([%z\1-\127\194-\244][\128-\191]*)", "%1 "):gsub(" $", "")) end
local function ClassRGB(cls) local c = CLASSES[cls] and CLASSES[cls].color or { 0.92, 0.88, 0.81 } return c[1], c[2], c[3] end
local function Hex(h) return tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255 end
local function Oy() return max(0, floor((StageH() - MOCK_H) / 2)) end

-- nine-slice: corners of c CSS px (+ the piece's pad) stay, edges and middle stretch; :Place(rel, x, y, w, h) by the
-- element's box, :Kit(name) swaps the art
local function Slice9(parent, name, layer, sub, c)
    local o = { t = {}, name = name, c = c }
    for i = 1, 9 do o.t[i] = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub or 0) end
    function o:Kit(n) self.name = n end
    function o:Place(rel, x, y, w, h)
        local k = K[self.name]
        if not k then return end
        local pad = k[8]
        local tw, th = k[6], k[7]
        local du, dv = (k[3] - k[2]) / tw, (k[5] - k[4]) / th
        local cap = self.c + pad
        local xs = { x - pad, x - pad + cap, x + w + pad - cap }
        local ws = { cap, max(0.1, w + 2 * pad - 2 * cap), cap }
        local ys = { y - pad, y - pad + cap, y + h + pad - cap }
        local hs = { cap, max(0.1, h + 2 * pad - 2 * cap), cap }
        local us = { { k[2], k[2] + cap * du }, { k[2] + cap * du, k[3] - cap * du }, { k[3] - cap * du, k[3] } }
        local vs = { { k[4], k[4] + cap * dv }, { k[4] + cap * dv, k[5] - cap * dv }, { k[5] - cap * dv, k[5] } }
        for r = 1, 3 do
            for q = 1, 3 do
                local t = self.t[(r - 1) * 3 + q]
                t:SetTexture(k[1])
                t:SetTexCoord(us[q][1], us[q][2], vs[r][1], vs[r][2])
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", rel, "TOPLEFT", xs[q], -ys[r])
                t:SetSize(ws[q], hs[r])
            end
        end
    end
    function o:SetShown(on) for _, t in ipairs(self.t) do t:SetShown(on) end end
    function o:SetAlpha(a) for _, t in ipairs(self.t) do t:SetAlpha(a) end end
    return o
end
-- a medallion: the icon masked round in a gilt ring (ring "ring" | "ring_dim" | "ring_gold" | "ring_green")
local function Medal(parent, layer, sub)
    local m = { icon = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 1) }
    m.mask = parent:CreateMaskTexture()
    m.mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    m.mask:SetAllPoints(m.icon)
    m.icon:AddMaskTexture(m.mask)
    m.ring = KitTex(parent, "ring", layer or "ARTWORK", (sub or 1) + 1)
    function m:Set(tex, ring, tc)
        self.icon:SetTexture(tex)
        if tc then self.icon:SetTexCoord(tc[1], tc[2], tc[3], tc[4]) else self.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
        self.icon:SetDesaturated(ring == "ring_dim")
        self.icon:SetVertexColor(ring == "ring_dim" and 0.6 or 1, ring == "ring_dim" and 0.6 or 1, ring == "ring_dim" and 0.6 or 1)
        KitSet(self.ring, ring or "ring")
    end
    function m:Place(rel, x, y, size)
        self.icon:ClearAllPoints() self.icon:SetPoint("TOPLEFT", rel, "TOPLEFT", x, -y) self.icon:SetSize(size, size)
        KitAtK(self.ring, rel, x, y, size / 64)
    end
    function m:SetShown(on) self.icon:SetShown(on) self.ring:SetShown(on) end
    return m
end
local function ClassIcon(m, cls, ring) m:Set(CLS_TEX, ring, CLS_ICON[cls] or CLS_ICON.PALADIN) end
local function Rect(parent, layer, r, g, b, a, sub)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub or 0)
    t:SetColorTexture(r, g, b, a)
    return t
end
local function Txt(parent, size, font, r, g, b)
    local fs = Words(parent, size, font)
    if r then fs:SetTextColor(r, g, b) end
    return fs
end
local function At(fs, rel, point, x, y) fs:ClearAllPoints() fs:SetPoint(point or "TOPLEFT", rel, "TOPLEFT", x, -y) end
-- the veil over the world (the mockup's: a dark ring round a lit middle, darker above and below)
local function Veil(f)
    f.dim = Rect(f, "BACKGROUND", 8 / 255, 6 / 255, 11 / 255, 0.62, -8)
    f.dim:SetAllPoints()
    f.vig = f:CreateTexture(nil, "BACKGROUND", nil, -7) f.vig:SetTexture(D.MEDIA .. "UI\\dark_hole") f.vig:SetVertexColor(6 / 255, 4 / 255, 10 / 255, 0.86)
    f.vtop = Rect(f, "BACKGROUND", 1, 1, 1, 1, -6) f.vbot = Rect(f, "BACKGROUND", 1, 1, 1, 1, -6)
end
local function LayoutVeil(f)
    local H = StageH()
    f.vig:ClearAllPoints() f.vig:SetPoint("CENTER", f, "TOPLEFT", OV_W / 2, -H * 0.4) f.vig:SetSize(OV_W * 1.5, H * 1.5)
    f.vtop:ClearAllPoints() f.vtop:SetPoint("TOPLEFT") f.vtop:SetSize(OV_W, H * 0.32)
    ns.UI:GradientRGBA(f.vtop, "VERTICAL", 6 / 255, 4 / 255, 10 / 255, 0.18, 6 / 255, 4 / 255, 10 / 255, 0.6)
    f.vbot:ClearAllPoints() f.vbot:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -H * 0.32) f.vbot:SetSize(OV_W, H * 0.68)
    ns.UI:GradientRGBA(f.vbot, "VERTICAL", 6 / 255, 4 / 255, 10 / 255, 0.92, 6 / 255, 4 / 255, 10 / 255, 0.18)
end
-- a glass pill (gb): icon (round) + label + count badge
local function Pill(parent, onClick, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent)
    b.bg = Slice3(b, opts.big and "gb_big" or "gb", "BACKGROUND", 0, opts.big and 19 or 15)
    b.label = Words(b, opts.size or 12, opts.big and MORPHEUS or nil)
    if opts.icon then
        b.icon = b:CreateTexture(nil, "ARTWORK") b.mask = b:CreateMaskTexture()
        b.mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE") b.mask:SetAllPoints(b.icon) b.icon:AddMaskTexture(b.mask)
    end
    b.badge = Slice3(b, "gb_n", "ARTWORK", 0, 9)
    b.count = Words(b, 11, nil, "OVERLAY") b.count:SetTextColor(42 / 255, 22 / 255, 0) b.count:SetShadowColor(0, 0, 0, 0)
    b:SetScript("OnEnter", function(self) self.hov = true Sound("hover", 0.03) self:Look() end)
    b:SetScript("OnLeave", function(self) self.hov = false self:Look() end)
    b:SetScript("OnClick", function(self) if onClick then onClick(self) end end)
    -- (h: 30 / 26 / 38; the mockup's paddings: 12 left (8 with an icon gap), 16 right)
    function b:Set(text, on, h, iconTex, badge, padL, padR)
        self.on, self.h = on and true or false, h or (opts.big and 38 or 30)
        self.label:SetText(text)
        local x = padL or (opts.big and 26 or 12)
        local isz = self.h <= 26 and 16 or 18
        if self.icon then
            self.icon:SetShown(iconTex ~= nil)
            if iconTex then
                if type(iconTex) == "table" then self.icon:SetTexture(CLS_TEX) self.icon:SetTexCoord(unpack(iconTex)) else self.icon:SetTexture(iconTex) self.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
                self.icon:ClearAllPoints() self.icon:SetPoint("LEFT", self, "LEFT", x, 0) self.icon:SetSize(isz, isz)
                x = x + isz + 8
            end
        end
        self.label:ClearAllPoints() self.label:SetPoint("LEFT", self, "LEFT", x, 0)
        x = x + (self.label:GetStringWidth() or 40)
        self.badge:SetShown(badge ~= nil) self.count:SetShown(badge ~= nil)
        if badge then
            self.count:SetText(badge)
            local bw = max(18, (self.count:GetStringWidth() or 8) + 12)
            x = x + 8
            self.badge:Place(self, x, (self.h - 18) / 2, bw, 18)
            self.count:ClearAllPoints() self.count:SetPoint("CENTER", self, "TOPLEFT", x + bw / 2, -(self.h / 2) - 0.5)
            x = x + bw
        end
        local w = floor(x + (padR or (opts.big and 26 or 16)) + 0.5)
        self:SetSize(w, self.h)
        self:Look()
        return w
    end
    function b:Look()
        local lit = self.on or self.hov
        if opts.big then self.bg:SetKit(self.hov and "gb_bighov" or "gb_big") else self.bg:SetKit(lit and "gb_hov" or "gb") end
        self.bg:Place(self, 0, 0, self:GetWidth(), self:GetHeight())
        if opts.big then self.label:SetTextColor(1, 231 / 255, 168 / 255)
        else self.label:SetTextColor(lit and 1 or 234 / 255, lit and 246 / 255 or 223 / 255, lit and 220 / 255 or 198 / 255) end
    end
    return b
end
-- the header: the glow and two gold rules (hd2), the title in gold lettering (a kit piece), the caption
local function Header(f, ttl)
    f.hd = KitTex(f, "hd2", "BACKGROUND", 2)
    f.ttl = KitTex(f, ttl, "ARTWORK", 2)
    f.cap = Txt(f, 10, nil, 234 / 255, 219 / 255, 189 / 255)
    f.cap:SetShadowOffset(0, -1)
end
local function LayoutHeader(f, oy, caption)
    KitAt(f.hd, f, OV_W / 2 - 260, oy + 14, 520, 96)
    local k = K[f.ttl.kit]
    local tw = k[6] - 2 * k[8]
    KitAt(f.ttl, f, OV_W / 2 - tw / 2, oy + 28)
    f.cap:SetText(Spaced(caption))
    f.cap:ClearAllPoints() f.cap:SetPoint("TOP", f, "TOPLEFT", OV_W / 2, -(oy + 94))
end
-- a menu screen: veil, Back, header
local function MenuScreen(ttl)
    local f = CreateFrame("Frame", nil, stage)
    f:SetAllPoints()
    Veil(f)
    Header(f, ttl)
    f.back = Pill(f, function() ShowTitle() end)
    f:Hide()
    return f
end
local function LayoutMenu(f, caption)
    local oy = Oy()
    LayoutVeil(f)
    LayoutHeader(f, 0, caption)                 -- (the header and Back sit at the top of the stage; the page itself stays centred)
    f.back:Set("\194\171 Back", false, 30)
    f.back:ClearAllPoints() f.back:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -22)
    return oy
end
-- a tab down the left (200 x 42): medallion, label, a note on the right (when it fits)
local function Tab(parent, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(200, 42)
    b.bg = Slice3(b, "tab", "BACKGROUND", 0, 21)
    b.m = Medal(b, "ARTWORK", 1)
    b.label = Txt(b, 12)
    b.note = Txt(b, 9, nil, 110 / 255, 100 / 255, 118 / 255)
    b:SetScript("OnEnter", function(self) self.hov = true self:Look() end)
    b:SetScript("OnLeave", function(self) self.hov = false self:Look() end)
    b:SetScript("OnClick", function(self) Sound("hover", 0.03) onClick(self) end)
    function b:Look()
        self.bg:SetKit((self.on or self.hov) and "tab_on" or "tab")
        self.bg:Place(self, 0, 0, 200, 42)
        self.m:Place(self, 9, 8, 26)
        self.label:ClearAllPoints() self.label:SetPoint("LEFT", self, "TOPLEFT", 46, -21)
        self.label:SetTextColor(self.on and 1 or 201 / 255, self.on and 246 / 255 or 191 / 255, self.on and 220 / 255 or 208 / 255)
        self.note:ClearAllPoints() self.note:SetPoint("RIGHT", self, "TOPLEFT", 188, -21)
        local room = 188 - 46 - (self.note:GetStringWidth() or 0) - 8
        self.note:SetShown((self.label:GetStringWidth() or 0) <= room)
    end
    return b
end
-- a hero's little stage inside a glass window: a lit floor, rays, the class's light, the hero (standing)
local function Scene(parent, level)
    local s = CreateFrame("Frame", nil, parent)
    if level then s:SetFrameLevel(level) end
    pcall(s.SetClipsChildren, s, true)
    s.base = Rect(s, "BACKGROUND", 1, 1, 1, 1, 0) s.base:SetAllPoints()
    s.light = s:CreateTexture(nil, "BACKGROUND", nil, 1) s.light:SetTexture(D.MEDIA .. "UI\\glow") s.light:SetBlendMode("ADD")
    s.rays = KitTex(s, "rays", "BACKGROUND", 2) s.rays:SetBlendMode("ADD")
    s.pool = s:CreateTexture(nil, "BORDER", nil, 0) s.pool:SetTexture(D.MEDIA .. "UI\\glow") s.pool:SetBlendMode("ADD")
    s.hero = s:CreateTexture(nil, "ARTWORK", nil, 0)
    s.glass = Slice9(s, "glass9", "OVERLAY", 7, 12)
    -- cls: the hero; tint {r,g,b}: the class's light; base: top and bottom colours; heroH, heroBottom: the mockup's
    function s:Set(w, h, cls, tint, base, opts)
        self:SetSize(w, h)
        ns.UI:GradientRGBA(self.base, "VERTICAL", base[4], base[5], base[6], 1, base[1], base[2], base[3], 1)
        self.light:ClearAllPoints() self.light:SetPoint("CENTER", self, "BOTTOM", 0, 0) self.light:SetSize(w * 1.4, h * 1.4)
        self.light:SetVertexColor(tint[1], tint[2], tint[3], opts.lightA or 0.35)
        self.rays:ClearAllPoints() self.rays:SetPoint("CENTER", self, "TOPLEFT", w / 2, -(opts.raysY or 114)) self.rays:SetSize(opts.raysS or 220, opts.raysS or 220)
        self.rays:SetVertexColor(tint[1], tint[2], tint[3], opts.raysA or 0.22)
        self.pool:SetShown(opts.pool ~= false)
        self.pool:ClearAllPoints() self.pool:SetPoint("CENTER", self, "BOTTOM", 0, (opts.poolY or 21)) self.pool:SetSize(150, 26)
        self.pool:SetVertexColor(tint[1], tint[2], tint[3], 0.55)
        local key = CLASSES[cls].sprite
        local pg, fx, fy, fw, fh, dx, dy = Rd.Frame(key, 2, 0)
        if pg then
            local sc = (opts.heroH or 112) / fh
            self.hero:SetTexture(pg[1]) self.hero:SetTexCoord(fx / pg[2], (fx + fw) / pg[2], fy / pg[3], (fy + fh) / pg[3])
            self.hero:ClearAllPoints()
            self.hero:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", w / 2 - fw * sc / 2, opts.heroBottom or 14)
            self.hero:SetSize(fw * sc, fh * sc)
            self.heroKey = key
        end
        self.glass:Place(self, 0, 0, w, h)
    end
    return s
end

-- the pause: the world dimmed, a plate with where the run stands, Resume and a way out (the run ends as a death:
-- its gold is banked as usual)
local function BuildPause()
    local f = CreateFrame("Frame", nil, stage)
    f:SetAllPoints()
    f.dim = f:CreateTexture(nil, "BACKGROUND", nil, -8) f.dim:SetAllPoints() f.dim:SetColorTexture(6 / 255, 4 / 255, 10 / 255, 0.55)
    f.plate = Slice9(f, "pl_grey", "BACKGROUND", 0, 18)
    f.eyebrow = Words(f, 9) f.eyebrow:SetTextColor(MUTE[1], MUTE[2], MUTE[3])
    f.title = Words(f, 30, MORPHEUS) f.title:SetText("Paused") f.title:SetTextColor(244 / 255, 207 / 255, 106 / 255) f.title:SetShadowOffset(0, -2)
    f.stats = Words(f, 11) f.stats:SetTextColor(0.85, 0.8, 0.72)
    f.go = CreateFrame("Button", nil, f)
    f.go.bg = Slice3(f.go, "gb_big", "BACKGROUND", 0, 19)
    f.go.label = Words(f.go, 15, MORPHEUS) f.go.label:SetText("Resume") f.go.label:SetTextColor(1, 231 / 255, 168 / 255) f.go.label:SetPoint("CENTER")
    f.go:SetScript("OnClick", function() ClosePause() end)
    f.go:SetScript("OnEnter", function(self) self.bg:SetKit("gb_bighov") Sound("hover", 0.03) end)
    f.go:SetScript("OnLeave", function(self) self.bg:SetKit("gb_big") end)
    f.quit = Pill(f, function() UI.GiveUp() end, { size = 11 })
    f.hint = Words(f, 9) f.hint:SetTextColor(110 / 255, 100 / 255, 118 / 255) f.hint:SetText("Esc resumes")
    f:Hide()
    return f
end
local function ShowPause()
    overlay = "pause"
    run.paused = true
    wipe(held)
    ClearOv()
    local f = ov.pause
    f:Show()
    local H = StageH()
    local W, PH = 340, 236
    local x, y = OV_W / 2 - W / 2, floor(H / 2 - PH / 2)
    local cx = OV_W / 2
    f.plate:Place(f, x, y, W, PH)
    local ST = run.ST
    f.eyebrow:SetText((ST and ST.name or "Eastern Plaguelands"):upper():gsub("(.)", "%1 "):gsub(" $", ""))
    f.eyebrow:ClearAllPoints() f.eyebrow:SetPoint("TOP", f, "TOPLEFT", cx, -(y + 26))
    f.title:ClearAllPoints() f.title:SetPoint("TOP", f, "TOPLEFT", cx, -(y + 42))
    f.stats:SetText(Rd.Clock(run.t) .. "   \194\183   level " .. run.level .. "   \194\183   " .. run.kills .. " slain   \194\183   " .. run.gold .. " gold")
    f.stats:ClearAllPoints() f.stats:SetPoint("TOP", f, "TOPLEFT", cx, -(y + 86))
    f.go:ClearAllPoints() f.go:SetPoint("TOP", f, "TOPLEFT", cx, -(y + 116)) f.go:SetSize(150, 38) f.go.bg:Place(f.go, 0, 0, 150, 38)
    f.go.bg:SetKit("gb_big")
    local qw = f.quit:Set(run.attract and "Back to the title" or "Give up the run", false, 26)
    f.quit:ClearAllPoints() f.quit:SetPoint("TOPLEFT", f, "TOPLEFT", cx - qw / 2, -(y + 166))
    f.hint:SetText(focused and "Esc resumes 9483 the game has your keys meanwhile" or "Your keys are the game's until you resume")
    f.hint:ClearAllPoints() f.hint:SetPoint("TOP", f, "TOPLEFT", cx, -(y + 204))
end
-- giving up: the run ends where it stands (a death: gold banked, the end screen as usual)
function UI.GiveUp()
    if not run or run.over then return end
    run.over, run.gaveUp = "death", true
    ShowEnd("death")
end
ClosePause = function() wipe(held) CloseOv(false) end

-- the title (the mockup's): the logo with the legendary star behind it, three hero cards (plate, a glass window with
-- the hero on a lit floor, name, difficulty, kit), the menu of glass pills, the week's challenge and the Argent
-- Dawn in the corners
local HERO_ORDER = { "PALADIN", "MAGE", "WARRIOR" }
local DIFFICULTY, DIFF_WORD = { PALADIN = 1, MAGE = 2, WARRIOR = 3 }, { "EASY", "HARDER", "HARDEST" }
local HERO_W, HERO_H = 232, 236

local function BuildTitle()
    local f = CreateFrame("Frame", nil, stage)
    f:SetAllPoints()
    Veil(f)
    f.glow = LegendGlow(f, "BACKGROUND", 3)
    f.logo = KitTex(f, "logo_main", "ARTWORK")
    f.heroes = {}
    for i, cls in ipairs(HERO_ORDER) do
        local C = CLASSES[cls]
        local b = CreateFrame("Button", nil, f)
        b:SetSize(HERO_W, HERO_H)
        b.cls = cls
        b.plate = Slice9(b, "pl_" .. CLS_PLATE[cls], "BACKGROUND", 0, 18)
        b.scene = Scene(b, b:GetFrameLevel() + 1)
        b.scene:SetPoint("TOPLEFT", b, "TOPLEFT", 10, -10)
        b.top = CreateFrame("Frame", nil, b) b.top:SetAllPoints() b.top:SetFrameLevel(b:GetFrameLevel() + 6)
        b.nmGlow = b.top:CreateTexture(nil, "BACKGROUND") b.nmGlow:SetTexture(D.MEDIA .. "UI\\glow") b.nmGlow:SetBlendMode("ADD")
        b.nmGlow:SetVertexColor(C.color[1], C.color[2], C.color[3], 0.3) b.nmGlow:SetPoint("CENTER", b, "TOPLEFT", HERO_W / 2, -163) b.nmGlow:SetSize(150, 44)
        b.name = Txt(b.top, 25, MORPHEUS, C.color[1], C.color[2], C.color[3]) b.name:SetText(C.name) b.name:SetShadowOffset(0, -2)
        b.name:SetPoint("TOP", b, "TOPLEFT", HERO_W / 2, -148)
        local dn = DIFFICULTY[cls]
        b.df = Txt(b.top, 9, nil, MUTE[1], MUTE[2], MUTE[3]) b.df:SetText(Spaced(DIFF_WORD[dn]))
        local dw = (b.df:GetStringWidth() or 40)
        local rowW = 3 * 8 + 2 * 6 + 8 + dw
        local x0 = HERO_W / 2 - rowW / 2
        b.gems = {}
        for g = 1, 3 do local t = KitTex(b.top, g <= dn and "gem_on" or "gem_off", "ARTWORK", 3) KitAt(t, b, x0 + (g - 1) * 14, 181, 8, 8) b.gems[g] = t end
        b.df:SetPoint("LEFT", b, "TOPLEFT", x0 + 3 * 8 + 2 * 6 + 8, -185.5)
        b.kit = {}
        local ids = {}
        for _, id in ipairs(D.SPELL_ORDER) do if SPELLS[id].cls == cls then ids[#ids + 1] = id end end
        local kx = HERO_W / 2 - (#ids * 22 + (#ids - 1) * 9) / 2
        for k, id in ipairs(ids) do
            local m = Medal(b.top, "ARTWORK", 1)
            m:Set(Icon(SPELLS[id].icon), "ring")
            m:Place(b, kx + (k - 1) * 31, 200, 22)
            b.kit[k] = m
        end
        b:SetScript("OnEnter", function(self) self.hov = true Sound("hover", 0.03) self:Look() end)
        b:SetScript("OnLeave", function(self) self.hov = false self:Look() end)
        b:SetScript("OnClick", function() UI.Start(cls) end)
        function b:Look()
            self.plate:Kit((self.hov and "pl_lit_" or "pl_") .. CLS_PLATE[self.cls])
            self.plate:Place(self, 0, 0, HERO_W, HERO_H)
            self.scene:Set(212, 132, self.cls, CLASSES[self.cls].color, { 26 / 255, 20 / 255, 32 / 255, 11 / 255, 9 / 255, 16 / 255 }, { heroH = 112, heroBottom = 14, raysY = 106, poolY = 21 })
        end
        f.heroes[i] = b
    end
    f.menu = {}
    for _, def in ipairs({ { "naxx", "Necropolis", "spell_shadow_raisedead", function() UI.ShowNaxx() end },
                           { "talents", "Talents", "spell_holy_sealofmight", function() UI.ShowTalents() end },
                           { "board", "Leaderboard", "spell_holy_holybolt", function() UI.ShowBoard() end },
                           { "ach", "Achievements", "spell_holy_avenginewrath", function() UI.ShowAch() end },
                           { "dawn", "Argent Dawn", "inv_misc_token_argentdawn3", function() UI.ShowDawn() end },
                           { "lab", "Spell lab", "spell_holy_innerfire", function() OpenLab(Class()) end } }) do
        local p = Pill(f, def[4], { icon = true })
        p.key, p.text, p.iconTex = def[1], def[2], Icon(def[3])
        f.menu[#f.menu + 1] = p
    end
    -- the corners: this week's challenge, your standing
    f.chStrip = Slice3(f, "strip", "ARTWORK", 0, 20)
    f.chMedal = Medal(f, "ARTWORK", 2)
    f.chText = Txt(f, 11, nil, MUTE[1], MUTE[2], MUTE[3])
    f.chBtn = CreateFrame("Button", nil, f) f.chBtn:SetScript("OnClick", function() UI.ShowBoard() end)
    f.adStrip = Slice3(f, "strip", "ARTWORK", 0, 20)
    f.adMedal = Medal(f, "ARTWORK", 2)
    f.adText = Txt(f, 11, nil, MUTE[1], MUTE[2], MUTE[3])
    f.adBar = KitTex(f, "barbg", "ARTWORK", 3)
    f.adFill = KitTex(f, "fill_g", "ARTWORK", 4)
    f.adBtn = CreateFrame("Button", nil, f) f.adBtn:SetScript("OnClick", function() UI.ShowDawn() end)
    f:Hide()
    return f
end

local titleT = 0
local function TickTitle(dt)
    local f = ov.title
    if not f:IsShown() then return end
    titleT = titleT + dt
    f.glow:Tick(titleT, Easing(min(1, titleT / 0.9)), 0.9)
    for _, b in ipairs(f.heroes) do
        if b.hov and b.scene.heroKey then          -- (the hero walks in place while you point at it)
            local U = A.UNITS[b.scene.heroKey]
            local pg, fx, fy, fw, fh = Rd.Frame(b.scene.heroKey, 2, floor(titleT * 9) % U.walk)
            if pg then b.scene.hero:SetTexCoord(fx / pg[2], (fx + fw) / pg[2], fy / pg[3], (fy + fh) / pg[3]) end
        end
    end
end

local function LayoutTitle()
    local f = ov.title
    local oy = Oy()
    LayoutVeil(f)
    local lk = 610 / K.logo_main[6]
    local ly = oy - 6 + K.logo_main[8] * lk
    KitAtK(f.logo, f, OV_W / 2 - 305 + K.logo_main[8] * lk, ly, lk)
    f.glow:Place(OV_W / 2, ly + 112 * lk, 400 * lk / 0.86)       -- (round the crest, as before)
    for i, b in ipairs(f.heroes) do
        b.hov = false
        b:ClearAllPoints() b:SetPoint("TOPLEFT", f, "TOPLEFT", 204 + (i - 1) * 254, -(oy + 290))
        b:Look()
    end
    -- the menu
    local S, d = ns.HTLSocial, ns.HTLGame and ns.HTLGame.Data() or {}
    local ws, tot = {}, 0
    local got = S and select(1, S:Count()) or 0
    local G = ns.HTLGame
    for i, p in ipairs(f.menu) do
        local show = p.key ~= "naxx" or (G and G:NaxxReady())
        p:SetShown(show)
        local badge = p.key == "talents" and (BreakUpLargeNumbers and BreakUpLargeNumbers(d.bank or 0) or tostring(d.bank or 0)) or p.key == "ach" and tostring(got) or nil
        ws[i] = show and p:Set(p.text, false, 30, p.iconTex, badge) or 0
        tot = tot + ws[i] + ((i > 1 and show) and 10 or 0)
    end
    local x = OV_W / 2 - tot / 2
    for i, p in ipairs(f.menu) do if p:IsShown() then p:ClearAllPoints() p:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(oy + 544)) x = x + ws[i] + 10 end end
    -- the corners
    local y = StageH() - 22 - 40                -- (the corners: 22 from the bottom, as from the sides)
    if S then
        local ch = S:Challenge()
        local left = S:WeekLeft()
        f.chText:SetText("Weekly challenge \194\183 |cffebe1cf" .. ch.name .. "|r \194\183 |cfff4cf6a" .. floor(left / 86400) .. "d " .. floor(left % 86400 / 3600) .. "h|r")
        ClassIcon(f.chMedal, ch.cls or Class(), "ring")
        local w = 6 + 28 + 10 + (f.chText:GetStringWidth() or 200) + 14
        f.chStrip:Place(f, 22, y, w, 40)
        f.chMedal:Place(f, 22 + 6, y + 6, 28)
        f.chText:ClearAllPoints() f.chText:SetPoint("LEFT", f, "TOPLEFT", 22 + 44, -(y + 20))
        f.chBtn:ClearAllPoints() f.chBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -y) f.chBtn:SetSize(w, 40)
        local st, _, nxt = S:Standing(d.rep or 0)
        f.adText:SetText("Argent Dawn |cfff4cf6a" .. st.name .. "|r")
        f.adMedal:Set(Icon("inv_misc_token_argentdawn3"), "ring")
        local aw = 6 + 28 + 10 + (f.adText:GetStringWidth() or 120) + 10 + 90 + 14
        local ax = OV_W - 22 - aw
        f.adStrip:Place(f, ax, y, aw, 40)
        f.adMedal:Place(f, ax + 6, y + 6, 28)
        f.adText:ClearAllPoints() f.adText:SetPoint("LEFT", f, "TOPLEFT", ax + 44, -(y + 20))
        local bx = ax + aw - 14 - 90
        KitAt(f.adBar, f, bx, y + 16.5, 90, 7)
        local k = nxt and min(1, ((d.rep or 0) - st.at) / max(1, nxt.at - st.at)) or 1
        KitAt(f.adFill, f, bx, y + 16.5, max(0.1, 90 * k), 7)
        f.adBtn:ClearAllPoints() f.adBtn:SetPoint("TOPLEFT", f, "TOPLEFT", ax, -y) f.adBtn:SetSize(aw, 40)
    end
end
UI.LayoutTitle = LayoutTitle

ShowTitle = function()
    Attract()
    overlay = "title"
    ClearOv()
    ov.title:Show()
    if UI.lab then UI.lab:Hide() end
    titleT = 0
    LayoutTitle()
    UI.DevTitlePill()
end

CloseOv = function(resume)
    ClearOv()
    overlay = nil
    if run then run.paused = false run.tsGoal = 1 if resume then run.ts = 0.05 end end
end

function UI.Start(cls, opts)
    if UI.lab then UI.lab:Hide() end
    CloseOv()
    NewRun(cls or Class(), opts or {})
    overlay = nil
    Sound("crusader")
    UI.SetFocus(true)
end

---------------------------------------------------------------------------
-- the spell lab
---------------------------------------------------------------------------
local function BuildLab()
    local f = CreateFrame("Frame", nil, stage)
    f:SetFrameLevel(stage:GetFrameLevel() + 20)
    f.shade = f:CreateTexture(nil, "BACKGROUND")
    f.shade:SetAllPoints() f.shade:SetColorTexture(1, 1, 1, 1)
    ns.UI:GradientRGBA(f.shade, "VERTICAL", 6 / 255, 4 / 255, 10 / 255, 0.94, 6 / 255, 4 / 255, 10 / 255, 0.55)
    -- a gold rule along the top, bright in the middle
    f.ruleL = f:CreateTexture(nil, "BORDER")
    f.ruleL:SetPoint("TOPLEFT") f.ruleL:SetPoint("TOPRIGHT", f, "TOP") f.ruleL:SetHeight(1)
    f.ruleL:SetColorTexture(1, 1, 1, 1)
    ns.UI:GradientRGBA(f.ruleL, "HORIZONTAL", 233 / 255, 192 / 255, 106 / 255, 0, 233 / 255, 192 / 255, 106 / 255, 0.7)
    f.ruleR = f:CreateTexture(nil, "BORDER")
    f.ruleR:SetPoint("TOPLEFT", f, "TOP") f.ruleR:SetPoint("TOPRIGHT") f.ruleR:SetHeight(1)
    f.ruleR:SetColorTexture(1, 1, 1, 1)
    ns.UI:GradientRGBA(f.ruleR, "HORIZONTAL", 233 / 255, 192 / 255, 106 / 255, 0.7, 233 / 255, 192 / 255, 106 / 255, 0)
    f.title = Words(f, 22, MORPHEUS) f.title:SetText("Spell lab") f.title:SetTextColor(244 / 255, 207 / 255, 106 / 255)
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -18)
    f.hint = Words(f, 10) f.hint:SetTextColor(157 / 255, 147 / 255, 163 / 255) f.hint:SetWidth(140) f.hint:SetJustifyH("LEFT")
    f.hint:SetText("Click a spell to toggle it.")
    f.hint:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
    f.chips, f.segs, f.groups = {}, {}, {}
    f:Hide()
    return f
end
-- a glass pill: an icon (or none) and a label; on = lit gold, leg + on = the legendary orange
local function LabPill(f, list, i)
    local b = list[i]
    if not b then
        b = CreateFrame("Button", nil, f)
        b.bg = Slice3(b, "gb", "BACKGROUND", 0, 15)
        b.icon = b:CreateTexture(nil, "ARTWORK") b.icon:SetSize(20, 20)
        b.mask = b:CreateMaskTexture()
        b.mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        b.mask:SetAllPoints(b.icon)
        b.icon:AddMaskTexture(b.mask)
        b.label = Words(b, 11)
        b:SetScript("OnEnter", function(self) self.hov = true Sound("hover", 0.03) self:Look() end)
        b:SetScript("OnLeave", function(self) self.hov = false self:Look() end)
        function b:Look()
            self.bg:SetKit(self.leg and self.on and "gb_bighov" or self.on and "gb_hov" or "gb")
            self.bg:Place(self, 0, 0, self:GetWidth(), self:GetHeight())
            local lit = self.on or self.hov
            if self.leg and self.on then self.label:SetTextColor(1, 0.75, 0.4)
            elseif lit then self.label:SetTextColor(1, 0.96, 0.86)
            else self.label:SetTextColor(0.78, 0.73, 0.8) end
            self:SetAlpha((self.on or self.hov or not self.dimOff) and 1 or 0.6)
        end
        list[i] = b
    end
    return b
end
local function LabLay(b, label, icon, on, leg, x, y, h)
    b.on, b.leg = on and true or false, leg and true or false
    b.label:SetText(label)
    local ix = icon and 6 or 14
    if icon then
        b.icon:SetTexture(Icon(icon)) b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.icon:ClearAllPoints() b.icon:SetPoint("LEFT", b, "LEFT", ix, 0) b.icon:Show()
        ix = ix + 26
    else b.icon:Hide() end
    b.label:ClearAllPoints() b.label:SetPoint("LEFT", b, "LEFT", ix, 0)
    local w = floor(ix + (b.label:GetStringWidth() or 40) + 14 + 0.5)
    b:SetSize(w, h)
    b:ClearAllPoints() b:SetPoint("TOPLEFT", b:GetParent(), "TOPLEFT", x, -y)
    b:Look()
    b:Show()
    return w
end
ShowLab = function()
    local f = UI.lab
    if not run or not run.lab then f:Hide() return end
    f:ClearAllPoints() f:SetPoint("BOTTOMLEFT", stage, "BOTTOMLEFT", 0, 0) f:SetSize(OV_W, 104)
    f:Show()
    -- the spells of this class (and the gadgets): one pill each, lit when in the lab
    local ids = {}
    for _, id in ipairs(D.SPELL_ORDER) do if not SPELLS[id].cls or SPELLS[id].cls == run.cls then ids[#ids + 1] = id end end
    local x = 168
    for i, id in ipairs(ids) do
        local b = LabPill(f, f.chips, i)
        b.dimOff = true
        local w = LabLay(b, SPELLS[id].name, run.legend[id] and LEGEND[id].icon or SPELLS[id].icon, run.spells[id] ~= nil, run.legend[id], x, 16, 30)
        b:SetScript("OnClick", function()
            if run.spells[id] then
                run.spells[id] = nil
                for k = #run.order, 1, -1 do if run.order[k] == id then table.remove(run.order, k) end end
                run.legend[id] = nil
                if id == "consecration" then run.ashbringer = false end
            else
                run.spells[id] = { r = run.labRank or 3, cd = 0.2, acc = 0, a = 0, cdMax = 1 }
                run.order[#run.order + 1] = id
                if run.labLegend and LEGEND[id] then run.legend[id] = true if id == "consecration" then run.ashbringer = true end end
            end
            ShowLab()
        end)
        x = x + w + 8
    end
    for i = #ids + 1, #f.chips do f.chips[i]:Hide() end
    -- the settings, in labelled groups of pills
    local function rank(n) return function() run.labRank = n for _, id in ipairs(run.order) do run.spells[id].r = n end end end
    local groups = {
        { "RANK", { { "1", run.labRank == 1, rank(1) }, { "3", (run.labRank or 3) == 3, rank(3) }, { "5", run.labRank == 5, rank(5) } } },
        { "LEGENDARY", { { run.labLegend and "On" or "Off", run.labLegend, function()
            run.labLegend = not run.labLegend
            for _, id in ipairs(run.order) do
                if LEGEND[id] then
                    if run.labLegend then run.legend[id] = true run.spells[id].r = 5 if id == "consecration" then run.ashbringer = true end E.LegendFx(run)
                    else run.legend[id] = nil run.ashbringer = false end
                end
            end
        end, true } } },
        { "SCOURGE", { { "30", run.labN == 30, function() run.labN = 30 end }, { "70", run.labN == 70, function() run.labN = 70 end }, { "160", run.labN == 160, function() run.labN = 160 end } } },
        { "CLASS", { { "Paladin", run.cls == "PALADIN", function() OpenLab("PALADIN") end }, { "Mage", run.cls == "MAGE", function() OpenLab("MAGE") end }, { "Warrior", run.cls == "WARRIOR", function() OpenLab("WARRIOR") end } } },
    }
    x = 168
    local n = 0
    for gi, g in ipairs(groups) do
        local lab = f.groups[gi] or Words(f, 9)
        f.groups[gi] = lab
        lab:SetText(g[1]) lab:SetTextColor(157 / 255, 147 / 255, 163 / 255)
        lab:ClearAllPoints() lab:SetPoint("LEFT", f, "TOPLEFT", x, -(60 + 14))
        x = x + (lab:GetStringWidth() or 40) + 8
        for _, s in ipairs(g[2]) do
            n = n + 1
            local b = LabPill(f, f.segs, n)
            b.dimOff = false
            local w = LabLay(b, s[1], nil, s[2], s[4], x, 60, 28)
            b:SetScript("OnClick", function() s[3]() if run and run.lab then ShowLab() end end)
            x = x + w + 4
        end
        x = x + 22
    end
    for i = n + 1, #f.segs do f.segs[i]:Hide() end
    -- leave: back to the title, the bar goes with it
    f.leaveList = f.leaveList or {}
    local lb = LabPill(f, f.leaveList, 1)
    lb.dimOff = false
    local lw = LabLay(lb, "Leave lab", nil, false, false, 0, 0, 30)
    lb:ClearAllPoints() lb:SetPoint("TOPLEFT", f, "TOPLEFT", OV_W - 22 - lw, -59)
    lb:SetScript("OnClick", function() f:Hide() ShowTitle() end)
end
OpenLab = function(cls)
    CloseOv()
    run = NewRun(cls or (run and not run.attract and run.cls) or Class(), { lab = true, god = true, noStart = true })
    run.lab = true
    run.labN, run.labRank = 70, 3
    for _, id in ipairs(D.SPELL_ORDER) do if SPELLS[id].cls == run.cls then run.spells[id] = { r = 3, cd = 0.3, acc = 0, a = 0, cdMax = 1 } run.order[#run.order + 1] = id end end
    overlay = nil
    ShowLab()
    UI.SetFocus(true)
end
UI.OpenLab = function(cls) OpenLab(cls) end

---------------------------------------------------------------------------
-- Dev scenarios (a development copy only: DisasterZoneBoot.isDev, never a release). Pick a class, a level and god
-- mode, a stage and one of its moments - the start, a boss, an elite, the ring - and the run starts 5 s before it
-- (Engine's DevJump: the clock moved on, the crowd for that time round the hero, levels picked as the bot picks). A dev
-- run is never recorded: no stats, gold, clears, tokens, achievements or boards. Under a dev run the dev bar jumps to
-- the next moment, gives levels, toggles god mode. Opened from the title's pill or /dz htl dev.
-- (UI.lua's main chunk is at Lua's 200-local limit: all of this lives in UI fields.)
---------------------------------------------------------------------------
UI.dev = { stage = "epl", level = "auto", god = false }
UI.DEV_KIND = { ring = "The dead encircle", brood = "Spider brood", swarm = "Bat swarm", dark = "Darkness", storm = "Storm", reaper = "The Pale Rider" }
function UI.IsDev() return DisasterZoneBoot ~= nil and DisasterZoneBoot.isDev == true end
function UI.DevLabel(ev)
    local M = ev.mob and D.MOBS[ev.mob]
    local name = M and M.name or UI.DEV_KIND[ev.kind] or ev.msg or ev.kind
    if M and (ev.n or 1) > 1 then name = name .. " x" .. ev.n end
    return Rd.Clock(ev.t) .. "  " .. name
end
function UI.DevStages()
    local out = { "epl" }
    if D.STAGES and ns.HTLGame and ns.HTLGame:NaxxReady() then
        for _, k in ipairs({ "arachnid", "plague", "military", "construct", "frost" }) do if D.STAGES[k] then out[#out + 1] = k end end
    end
    return out
end
function UI.DevMoments(key)
    local ST = D.STAGES and D.STAGES[key]
    local out = { { t = 0, label = "00:00  Start" } }
    for _, ev in ipairs(ST and ST.events or D.EVENTS) do out[#out + 1] = { t = ev.t, label = UI.DevLabel(ev) } end
    return out
end
function UI.DevLevelAt(t) return min(60, floor(2 + t / 18)) end         -- (Auto: about where a player stands)
function UI.DevStart(cls, key, t)
    if not UI.IsDev() then return end
    local dv = UI.dev
    if UI.lab then UI.lab:Hide() end
    if UI.devPanel then UI.devPanel:Hide() end
    CloseOv()
    NewRun(cls or dv.cls or Class(), { stage = key ~= "epl" and key or nil, dev = true, god = dv.god })
    run.dev = true
    local at = t > 0 and max(0, t - 5) or 0
    if at > 0 then
        E.DevJump(run, at)
        run.pending, run.wantLevelUp, run.blessOnly = 0, nil, nil     -- (a start's own pick - Head Start, the Seal - is moot mid-run)
    end
    local lv = dv.level == "auto" and UI.DevLevelAt(at) or dv.level
    if lv > 1 then E.DevLevels(run, lv - 1) end
    overlay = nil
    Sound("crusader")
    UI.SetFocus(true)
    UI.DevBar()
end

-- the sheet: class / level / god, the stages, the chosen stage's moments
function UI.ShowDev()
    if not UI.IsDev() or not stage then return end
    local f = UI.devPanel
    if not f then
        f = CreateFrame("Frame", nil, stage)
        f:SetAllPoints(stage)
        f:SetFrameLevel(stage:GetFrameLevel() + 24)
        f:EnableMouse(true)
        f.shade = f:CreateTexture(nil, "BACKGROUND")
        f.shade:SetAllPoints() f.shade:SetColorTexture(1, 1, 1, 1)
        ns.UI:GradientRGBA(f.shade, "VERTICAL", 6 / 255, 4 / 255, 10 / 255, 0.96, 6 / 255, 4 / 255, 10 / 255, 0.8)
        f.title = Words(f, 26, MORPHEUS) f.title:SetText("Dev scenarios") f.title:SetTextColor(244 / 255, 207 / 255, 106 / 255)
        f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 40, -34)
        f.hint = Words(f, 11) f.hint:SetTextColor(157 / 255, 147 / 255, 163 / 255)
        f.hint:SetText("This development copy only. A moment starts 5 seconds before it; dev runs are never recorded.")
        f.hint:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6)
        f.pills, f.groups = {}, {}
        UI.devPanel = f
    end
    if run and run.dev and not run.over then run.paused = true end
    ClearOv()
    overlay = "dev"
    if UI.devBar then UI.devBar:Hide() end
    f:Show()
    UI.DevLayout()
end
function UI.CloseDev()
    if UI.devPanel then UI.devPanel:Hide() end
    if run and run.dev and not run.over then
        overlay = nil
        run.paused = false
        UI.SetFocus(true)
        UI.DevBar()
    else
        ShowTitle()
    end
end
function UI.DevLayout()
    local f, dv = UI.devPanel, UI.dev
    if not f or not f:IsShown() then return end
    local n, gi = 0, 0
    local function Pill(label, icon, on, x, y, h, fn)
        n = n + 1
        local b = LabPill(f, f.pills, n)
        b.dimOff = false
        local w = LabLay(b, label, icon, on, false, x, y, h)
        b:SetScript("OnClick", function() Sound("hover", 0.03) fn() end)
        return b, w
    end
    local function Group(label, x, y)
        gi = gi + 1
        local lab = f.groups[gi] or Words(f, 9)
        f.groups[gi] = lab
        lab:SetText(label) lab:SetTextColor(157 / 255, 147 / 255, 163 / 255)
        lab:ClearAllPoints() lab:SetPoint("LEFT", f, "TOPLEFT", x, -(y + 14)) lab:Show()
        return x + (lab:GetStringWidth() or 40) + 10
    end
    local cls = dv.cls or Class()
    -- the run: class, level, god mode
    local y = 104
    local x = Group("CLASS", 40, y)
    for _, c in ipairs({ { "PALADIN", "Paladin" }, { "MAGE", "Mage" }, { "WARRIOR", "Warrior" } }) do
        local _, w = Pill(c[2], nil, cls == c[1], x, y, 28, function() dv.cls = c[1] UI.DevLayout() end)
        x = x + w + 4
    end
    x = Group("LEVEL", x + 26, y)
    for _, lv in ipairs({ "auto", 1, 10, 25, 50 }) do
        local _, w = Pill(lv == "auto" and "Auto" or tostring(lv), nil, dv.level == lv, x, y, 28, function() dv.level = lv UI.DevLayout() end)
        x = x + w + 4
    end
    x = Group("GOD MODE", x + 26, y)
    Pill(dv.god and "On" or "Off", nil, dv.god, x, y, 28, function() dv.god = not dv.god UI.DevLayout() end)
    -- the stages
    y = 150
    x = Group("STAGE", 40, y)
    for _, k in ipairs(UI.DevStages()) do
        local ST = D.STAGES and D.STAGES[k]
        local label = k == "epl" and "Plaguelands" or ST.short or ST.name
        local _, w = Pill(label, k == "epl" and "spell_shadow_raisedead" or ST.icon, dv.stage == k, x, y, 30, function() dv.stage = k UI.DevLayout() end)
        x = x + w + 4
    end
    -- the moments: each a pill, wrapped to the sheet
    y = 206
    Group("MOMENTS  \194\183  " .. (dv.stage == "epl" and "Eastern Plaguelands" or D.STAGES[dv.stage].name), 40, y)
    y, x = y + 30, 40
    for _, m in ipairs(UI.DevMoments(dv.stage)) do
        local b, w = Pill(m.label, nil, false, x, y, 30, function() UI.DevStart(cls, dv.stage, m.t) end)
        if x + w > OV_W - 40 and x > 40 then
            x, y = 40, y + 38
            b:ClearAllPoints() b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
        end
        x = x + w + 6
    end
    -- close (back to the paused dev run, or the title)
    local cb, cw = Pill("Close", nil, false, 0, 0, 28, function() UI.CloseDev() end)
    cb:ClearAllPoints() cb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -40, -38)
    for i = n + 1, #f.pills do f.pills[i]:Hide() end
    for i = gi + 1, #f.groups do f.groups[i]:Hide() end
end

-- the dev bar: a column of pills at the left under the slots while a dev run plays (or is paused)
function UI.DevBar()
    local f = UI.devBar
    local show = run and run.dev and not run.over and (overlay == nil or overlay == "pause") and stage ~= nil
    if not show then if f and f:IsShown() then f:Hide() end return end
    if not f then
        f = CreateFrame("Frame", nil, stage)
        f:SetFrameLevel(stage:GetFrameLevel() + 20)
        f:SetSize(10, 10)
        f.tag = Words(f, 9) f.tag:SetText("DEV") f.tag:SetTextColor(244 / 255, 207 / 255, 106 / 255)
        f.tag:SetPoint("TOPLEFT", f, "TOPLEFT", 2, 0)
        f.pills = {}
        UI.devBar = f
    end
    if f:IsShown() and f.run == run and f.evI == run.evI and f.god == run.god and f.lvl == run.level then return end
    f.run, f.evI, f.god, f.lvl = run, run.evI, run.god, run.level
    f:ClearAllPoints() f:SetPoint("TOPLEFT", stage, "TOPLEFT", 12, -166)
    f:Show()
    local n, y = 0, 16
    local function Pill(label, on, fn)
        n = n + 1
        local b = LabPill(f, f.pills, n)
        b.dimOff = false
        LabLay(b, label, nil, on, false, 0, y, 26)
        b:SetScript("OnClick", function() Sound("hover", 0.03) fn() end)
        y = y + 30
    end
    Pill("Scenarios", false, function() UI.ShowDev() end)
    local ev, k = E.DevNext(run)
    if ev then Pill("Next: " .. UI.DevLabel(ev), false, function() E.DevJump(run, max(run.t, ev.t * k - 5)) UI.SetFocus(true) UI.DevBar() end) end
    Pill("+5 levels  \194\183  " .. run.level, false, function() E.DevLevels(run, 5) UI.SetFocus(true) UI.DevBar() end)
    Pill("God mode " .. (run.god and "on" or "off"), run.god, function() run.god = not run.god UI.SetFocus(true) UI.DevBar() end)
    Pill("Leave", false, function() f:Hide() ShowTitle() end)
    for i = n + 1, #f.pills do f.pills[i]:Hide() end
end
-- the title's way in (top right, a development copy only)
function UI.DevTitlePill()
    if not UI.IsDev() or not ov or not ov.title then return end
    UI.devTitleList = UI.devTitleList or {}
    local b = LabPill(ov.title, UI.devTitleList, 1)
    b.dimOff = false
    LabLay(b, "Dev scenarios", nil, false, false, 0, 0, 28)
    b:ClearAllPoints() b:SetPoint("TOPRIGHT", ov.title, "TOPRIGHT", -22, -22)
    b:SetScript("OnClick", function() Sound("hover", 0.03) UI.ShowDev() end)
end

---------------------------------------------------------------------------
-- the guild hall: leaderboard (and the week's challenge), achievements, the Argent Dawn - the mockup's, piece by piece
---------------------------------------------------------------------------
local function Num(n) return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n) end

-- the toast: an achievement earned (mid-run too), sliding up at the bottom for three seconds
local toast
local function BuildToast()
    local f = CreateFrame("Frame", nil, ov)
    f:SetFrameLevel(ov:GetFrameLevel() + 40)
    f:SetSize(380, 74)
    f.plate = Slice9(f, "pl_done", "BACKGROUND", 0, 18)
    f.m = Medal(f, "ARTWORK", 1)
    f.eb = Txt(f, 9, nil, 230 / 255, 192 / 255, 106 / 255) f.eb:SetText(Spaced("Achievement earned"))
    f.name = Txt(f, 20, MORPHEUS, 1, 0.89, 0.6) f.name:SetShadowOffset(0, -2)
    f.sh = KitTex(f, "sh_gold_10", "ARTWORK", 2)
    f:Hide()
    return f
end
local function ShowToast(id)
    local a = D.ACH[id]
    if not a or not toast then return end
    toast.plate:Kit(a.feat and "pl_feat" or "pl_done")
    toast.plate:Place(toast, 0, 0, 380, 74)
    toast.m:Set(Icon(a.icon), "ring") toast.m:Place(toast, 14, 11, 52)
    toast.eb:ClearAllPoints() toast.eb:SetPoint("TOPLEFT", toast, "TOPLEFT", 80, -16)
    toast.name:SetText(a.name) FitLine(toast.name, MORPHEUS, 20, 12, 220)
    toast.name:ClearAllPoints() toast.name:SetPoint("TOPLEFT", toast, "TOPLEFT", 80, -30)
    KitSet(toast.sh, a.feat and "sh_feat" or ("sh_gold_" .. a.pts))
    KitAt(toast.sh, toast, 380 - 16 - 46, 11, 46, 52)
    toast.t = 0
    toast:Show()
    Sound("rep")
end
local function TickToast(dt)
    local S = ns.HTLSocial
    if not toast then return end
    if not toast:IsShown() and S and S.toasts[1] then ShowToast(table.remove(S.toasts, 1)) end
    if not toast:IsShown() then return end
    toast.t = toast.t + dt
    local t = toast.t
    local k = t < 0.35 and Easing(t / 0.35) or t > 3.2 and max(0, 1 - (t - 3.2) / 0.35) or 1
    local sk = StageScale()
    toast:SetScale(sk)
    toast:ClearAllPoints()
    toast:SetPoint("BOTTOM", ov, "BOTTOMLEFT", (root:GetWidth() or 786) / 2 / sk, 16 - (1 - k) * 40)
    toast:SetAlpha(k)
    if t > 3.55 then toast:Hide() end
end
UI._TickToast = TickToast

---------------------------------------------------------------------------
-- the leaderboard
---------------------------------------------------------------------------
local BOARDS = {
    { "time", "Longest held", "spell_holy_holybolt" }, { "kills", "Most slain", "inv_misc_bone_humanskull_01" },
    { "level", "Highest level", "spell_holy_championsbond" }, { "gold", "Gold home", "inv_misc_coin_02" },
    { "points", "Points", "spell_holy_avenginewrath" }, { "rep", "Argent Dawn", "inv_misc_token_argentdawn3" },
    { "kt", "Kel'Thuzad", "spell_shadow_raisedead" }, { "desecrated", "Desecrated", "inv_misc_desecrated_platechest" },
}
local lbState = { kind = "time", period = "week", cls = nil }
local PL, PR = 244, 290                       -- the middle column's edges
local function Metal(name, hex, pool) local r, g, b = Hex(hex) return { name, r, g, b, pool } end
local METAL = { Metal("silver", "e6ecf6", { 0.78, 0.84, 1, 0.35 }), Metal("gold", "ffe39a", { 1, 0.78, 0.35, 0.55 }), Metal("bronze", "f0b070", { 0.9, 0.55, 0.24, 0.4 }) }
local function BoardValue(kind, row)
    if kind == "time" or kind == "challenge" then return Rd.Clock(floor(row.v / 1000000)):gsub("^0", "") end
    if kind == "kt" then return Rd.Clock(100000 - row.v):gsub("^0", "") end
    if kind == "desecrated" then return row.v .. " / 27" end
    return Num(row.v)
end
local function BoardSub(kind, row)
    local b = row.b
    if kind == "gold" or kind == "rep" or kind == "points" then return row.e.ti or "" end
    if kind == "kt" then return "Kel'Thuzad slain" end
    if kind == "desecrated" then return "Tier 3 pieces" end
    if not b then return "" end
    if (b.w or 0) > 0 and floor(row.v / 1000000) >= 900 then return "Victory \194\183 Level " .. (b.l or 0) end
    return string.format("Level %d \194\183 %s slain", b.l or 0, Num(b.k or 0))
end

local function BuildBoard()
    local f = MenuScreen("ttl_hall")
    f.tabs = {}
    for i, def in ipairs(BOARDS) do
        local t = Tab(f, function() lbState.kind = def[1] UI.ShowBoard() end)
        t.m:Set(Icon(def[3]), "ring") t.label:SetText(def[2])
        t.kind = def[1]
        f.tabs[i] = t
    end
    f.period = { Pill(f, function() lbState.period = "week" UI.ShowBoard() end), Pill(f, function() lbState.period = "all" UI.ShowBoard() end) }
    f.clsb = {}
    for i, c in ipairs({ false, "PALADIN", "MAGE", "WARRIOR" }) do
        local b = Pill(f, function() lbState.cls = c or nil UI.ShowBoard() end, { icon = c and true, size = 11 })
        b.cls = c
        f.clsb[i] = b
    end
    -- the podium: places 2, 1, 3
    f.pods = {}
    for slot = 1, 3 do
        local p = CreateFrame("Frame", nil, f)
        p:SetAllPoints()
        p.beam = KitTex(p, "beam", "BACKGROUND", 1) p.beam:SetBlendMode("ADD")
        p.pool = p:CreateTexture(nil, "BACKGROUND", nil, 2) p.pool:SetTexture(D.MEDIA .. "UI\\glow") p.pool:SetBlendMode("ADD")
        p.hero = p:CreateTexture(nil, "ARTWORK", nil, 1)
        p.md = KitTex(p, "md_1", "ARTWORK", 3)
        p.name = Txt(p, 17, MORPHEUS) p.name:SetShadowOffset(0, -2)
        p.v = Txt(p, slot == 2 and 38 or 30, MORPHEUS) p.v:SetShadowOffset(0, -2)
        p.sb = Txt(p, 10, nil, MUTE[1], MUTE[2], MUTE[3])
        f.pods[slot] = p
    end
    f.rows = {}
    for i = 1, 5 do
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(OV_W - PL - PR, 34)
        r.bg = Slice3(r, "lrow", "BACKGROUND", 0, 17)
        r.rk = KitTex(r, "rk", "ARTWORK", 1)
        r.rkN = Txt(r, 14, MORPHEUS)
        r.ic = Medal(r, "ARTWORK", 2)
        r.name = Txt(r, 13) r.you = Txt(r, 10, nil, 110 / 255, 100 / 255, 118 / 255)
        r.meta = Txt(r, 11, nil, MUTE[1], MUTE[2], MUTE[3])
        r.v = Txt(r, 19, MORPHEUS, 1, 1, 1)
        f.rows[i] = r
    end
    f.empty = Txt(f, 13, nil, MUTE[1], MUTE[2], MUTE[3]) f.empty:SetWidth(520)
    -- the week's challenge: a plate, a window onto its hero, the name, the clock, the leaders, the reward, the button
    local c = CreateFrame("Frame", nil, f)
    c:SetSize(252, 508)
    c.plate = Slice9(c, "pl_war", "BACKGROUND", 0, 18)
    c.scene = Scene(c, c:GetFrameLevel() + 1)
    c.scene:SetPoint("TOPLEFT", c, "TOPLEFT", 10, -10)
    c.top = CreateFrame("Frame", nil, c) c.top:SetAllPoints() c.top:SetFrameLevel(c:GetFrameLevel() + 6)
    c.eb = Txt(c.top, 9, nil, Hex("a6d873")) c.eb:SetText(Spaced("Weekly challenge")) c.eb:SetPoint("TOP", c, "TOPLEFT", 126, -136)
    c.name = Txt(c.top, 25, MORPHEUS) c.name:SetShadowOffset(0, -2) c.name:SetPoint("TOP", c, "TOPLEFT", 126, -150)
    c.desc = Txt(c.top, 11.5, nil, MUTE[1], MUTE[2], MUTE[3]) c.desc:SetWidth(216) c.desc:SetSpacing(2) c.desc:SetPoint("TOP", c, "TOPLEFT", 126, -184)
    c.tiles = {}
    for i, l in ipairs({ "DAYS", "HOURS", "MIN" }) do
        local t = { bg = KitTex(c.top, "tile", "ARTWORK", 0), v = Txt(c.top, 22, MORPHEUS, 1, 1, 1), l = Txt(c.top, 8, nil, 110 / 255, 100 / 255, 118 / 255) }
        t.l:SetText(Spaced(l))
        local tx = 18 + (i - 1) * (216 + 8) / 3
        KitAt(t.bg, c, tx, 232, (216 - 16) / 3, 40)
        t.v:SetPoint("TOP", c, "TOPLEFT", tx + (216 - 16) / 6, -236)
        t.l:SetPoint("TOP", c, "TOPLEFT", tx + (216 - 16) / 6, -261)
        c.tiles[i] = t
    end
    c.mini = {}
    for i = 1, 3 do
        local m = { n = Txt(c.top, 12, MORPHEUS, 0.96, 0.81, 0.42), ic = Medal(c.top, "ARTWORK", 2), name = Txt(c.top, 12), v = Txt(c.top, 16, MORPHEUS, 1, 1, 1) }
        m.n:SetText(i)
        c.mini[i] = m
    end
    c.reward = Slice9(c.top, "reward", "ARTWORK", 0, 10)
    c.rewardM = Medal(c.top, "ARTWORK", 2)
    c.rewardT = Txt(c.top, 11) c.rewardT:SetWidth(166) c.rewardT:SetJustifyH("LEFT")
    c.go = Pill(c.top, function() UI.StartChallenge() end, { big = true, size = 16 })
    f.chal = c
    f:Hide()
    return f
end

function UI.ShowBoard()
    overlay = "board"
    ClearOv()
    local f, S = ov.board, ns.HTLSocial
    f:Show()
    if S then S:Settle() S:Ask() end
    local wk = S and S:Week() or ""
    local y0, m0, d0 = wk:match("(%d+)%-(%d+)%-(%d+)")
    local oy = LayoutMenu(f, "Casual Disaster \194\183 week of " .. (d0 and (tonumber(d0) .. " " .. date("%B", time({ year = tonumber(y0), month = tonumber(m0), day = tonumber(d0), hour = 12 }))) or wk))
    if IsInGuild and GetGuildInfo then local g = GetGuildInfo("player") if g then f.cap:SetText(Spaced(g .. " \194\183 week of " .. (d0 and (tonumber(d0) .. " " .. date("%B", time({ year = tonumber(y0), month = tonumber(m0), day = tonumber(d0), hour = 12 }))) or wk))) end end
    for i, t in ipairs(f.tabs) do
        t:ClearAllPoints() t:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -(oy + 116 + (i - 1) * 50))
        t.on = t.kind == lbState.kind t:Look()
    end
    -- filters
    local x = PL
    local pw = { f.period[1]:Set("This week", lbState.period == "week", 26, nil, nil, 11, 11), f.period[2]:Set("All time", lbState.period == "all", 26, nil, nil, 11, 11) }
    for i, b in ipairs(f.period) do b:ClearAllPoints() b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(oy + 118)) x = x + pw[i] + 6 end
    local names = { "All", "Paladin", "Mage", "Warrior" }
    local cw, tot = {}, 0
    for i, b in ipairs(f.clsb) do cw[i] = b:Set(names[i], (b.cls or nil) == lbState.cls, 26, b.cls and CLS_ICON[b.cls] or nil, nil, 11, 11) tot = tot + cw[i] + (i > 1 and 6 or 0) end
    x = OV_W - PR - tot
    for i, b in ipairs(f.clsb) do b:ClearAllPoints() b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(oy + 118)) x = x + cw[i] + 6 end
    local list = S and S:Board(lbState.kind, lbState.period, lbState.cls) or {}
    -- the podium (the mockup's grid: 1fr 1.18fr 1fr, gap 10; places sit at 8 / 26 / 0 above the bottom)
    local W = OV_W - PL - PR
    local unit = (W - 20) / 3.18
    local cols = { { PL + unit / 2, 2 }, { PL + unit + 10 + unit * 1.18 / 2, 1 }, { PL + unit * 2.18 + 20 + unit / 2, 3 } }
    for slot, col in ipairs(cols) do
        local p, place = f.pods[slot], col[2]
        local row = list[place]
        p:SetShown(row ~= nil)
        if row then
            local cx = col[1]
            local mt = METAL[place == 1 and 2 or place == 2 and 1 or 3]
            local bottom = oy + 154 + 240 - (place == 1 and 26 or place == 2 and 8 or 0)
            local vH = place == 1 and 38 or 30
            local mdW = place == 1 and 44 or 38
            local sbTop = bottom - 15
            local vTop = sbTop - 3 - vH
            local nmTop = vTop - 25.5
            local mdTop = nmTop - mdW * 58 / 48 + 2
            local feet = mdTop + 8
            p.sb:SetText(BoardSub(lbState.kind, row)) p.sb:ClearAllPoints() p.sb:SetPoint("TOP", f, "TOPLEFT", cx, -sbTop)
            p.v:SetText(BoardValue(lbState.kind, row)) p.v:SetTextColor(mt[2], mt[3], mt[4]) p.v:ClearAllPoints() p.v:SetPoint("TOP", f, "TOPLEFT", cx, -vTop)
            p.name:SetText(row.name) p.name:SetTextColor(ClassRGB(row.cls)) p.name:ClearAllPoints() p.name:SetPoint("TOP", f, "TOPLEFT", cx, -nmTop)
            KitSet(p.md, "md_" .. place) KitAtK(p.md, f, cx - mdW / 2, mdTop, mdW / 48)
            local key = CLASSES[row.cls or "PALADIN"].sprite
            local pg, fx, fy, fw, fh, dx, dy = Rd.Frame(key, 2, 0)
            if pg then
                local sc = (place == 1 and 102 or 84) / fh
                p.hero:SetTexture(pg[1]) p.hero:SetTexCoord(fx / pg[2], (fx + fw) / pg[2], fy / pg[3], (fy + fh) / pg[3])
                p.hero:ClearAllPoints() p.hero:SetPoint("TOPLEFT", f, "TOPLEFT", cx - fw * sc / 2, -(feet - fh * sc)) p.hero:SetSize(fw * sc, fh * sc)
            end
            p.pool:ClearAllPoints() p.pool:SetPoint("CENTER", f, "TOPLEFT", cx, -(feet - 5)) p.pool:SetSize(170, 34) p.pool:SetVertexColor(mt[5][1], mt[5][2], mt[5][3], mt[5][4])
            p.beam:SetShown(place == 1)
            KitAt(p.beam, f, cx - 60, feet + 10 - 230, 120, 230)
        end
    end
    -- the rows: 4.. and you
    local y = oy + 410
    for _, r in ipairs(f.rows) do r:Hide() end
    local function Row(r, rank, row)
        r:ClearAllPoints() r:SetPoint("TOPLEFT", f, "TOPLEFT", PL, -y)
        r.bg:SetKit(row.me and "lrow_me" or "lrow") r.bg:Place(r, 0, 0, W, 34)
        KitSet(r.rk, row.me and "rk_me" or "rk") KitAt(r.rk, r, 8, 4, 26, 26)
        r.rkN:SetText(rank) r.rkN:SetTextColor(row.me and 42 / 255 or 216 / 255, row.me and 22 / 255 or 200 / 255, row.me and 0 or 168 / 255)
        r.rkN:ClearAllPoints() r.rkN:SetPoint("CENTER", r, "TOPLEFT", 21, -17)
        ClassIcon(r.ic, row.cls or "PALADIN", "ring") r.ic:Place(r, 46, 6, 22)
        r.name:SetText(row.name) r.name:SetTextColor(ClassRGB(row.cls)) r.name:ClearAllPoints() r.name:SetPoint("LEFT", r, "TOPLEFT", 77, -17)
        r.you:SetText(row.me and "you" or "") r.you:ClearAllPoints() r.you:SetPoint("LEFT", r.name, "RIGHT", 8, 0)
        r.meta:SetText(BoardSub(lbState.kind, row)) r.meta:ClearAllPoints() r.meta:SetPoint("RIGHT", r, "TOPLEFT", W - 14 - 60 - 10, -17)
        r.v:SetText(BoardValue(lbState.kind, row)) r.v:ClearAllPoints() r.v:SetPoint("RIGHT", r, "TOPLEFT", W - 14, -17)
        r:Show()
        y = y + 41
    end
    local shown, meIn = 0, false
    for i = 1, min(3, #list) do if list[i].me then meIn = true end end
    for i = 4, min(#list, 6) do if list[i].me then meIn = true end shown = shown + 1 Row(f.rows[shown], i, list[i]) end
    if not meIn then for i = 7, #list do if list[i].me then shown = shown + 1 Row(f.rows[shown], i, list[i]) break end end end
    f.empty:SetShown(#list == 0)
    f.empty:SetText("No runs on this board yet. Finish a run and the guild sees it here.")
    f.empty:ClearAllPoints() f.empty:SetPoint("TOP", f, "TOPLEFT", PL + W / 2, -(oy + 260))
    -- the challenge
    local c = f.chal
    c:ClearAllPoints() c:SetPoint("TOPLEFT", f, "TOPLEFT", OV_W - 22 - 252, -(oy + 116))
    c.plate:Place(c, 0, 0, 252, 508)
    local ch = S and S:Challenge()
    if ch then
        local cls = ch.cls or Class()
        c.scene:Set(232, 116, cls, { 1, 0.59, 0.31 }, { 36 / 255, 20 / 255, 14 / 255, 11 / 255, 8 / 255, 6 / 255 }, { heroH = 96, heroBottom = 8, raysY = 100, raysS = 240, raysA = 0.18, lightA = 0.4, pool = false })
        c.name:SetText(ch.name) c.name:SetTextColor(ClassRGB(cls))
        c.desc:SetText(ch.desc)
        local left = S:WeekLeft()
        local vals = { floor(left / 86400), floor(left % 86400 / 3600), floor(left % 3600 / 60) }
        for i, t in ipairs(c.tiles) do t.v:SetText(vals[i]) end
        local top = S:Board("challenge", "week")
        for i, m in ipairs(c.mini) do
            local row = top[i]
            local ry = 296 + (i - 1) * 26
            for _, w in ipairs({ m.n, m.name, m.v }) do w:SetShown(row ~= nil) end
            m.ic:SetShown(row ~= nil)
            if row then
                m.n:ClearAllPoints() m.n:SetPoint("LEFT", c, "TOPLEFT", 18, -(ry + 10))
                ClassIcon(m.ic, row.cls, "ring") m.ic:Place(c, 38, ry, 20)
                m.name:SetText(row.name) m.name:SetTextColor(ClassRGB(row.cls)) m.name:ClearAllPoints() m.name:SetPoint("LEFT", c, "TOPLEFT", 66, -(ry + 10))
                m.v:SetText(Rd.Clock(floor(row.v / 1000000)):gsub("^0", "")) m.v:ClearAllPoints() m.v:SetPoint("RIGHT", c, "TOPLEFT", 234, -(ry + 10))
            end
        end
        c.reward:Place(c, 14, 386, 224, 46)
        c.rewardM:Set(Icon("inv_misc_token_argentdawn2"), "ring") c.rewardM:Place(c, 24, 394, 30)
        c.rewardT:SetText("Winner: |cffa6d873+" .. Num(D.CHALLENGE_REP) .. " Argent Dawn|r and the title |cfff4cf6a" .. D.CHALLENGE_TITLE .. "|r")
        c.rewardT:ClearAllPoints() c.rewardT:SetPoint("LEFT", c, "TOPLEFT", 64, -409)
        local gw = c.go:Set("Take the challenge", false, 38)
        c.go:ClearAllPoints() c.go:SetPoint("TOPLEFT", c, "TOPLEFT", 126 - gw / 2, -448)
    end
end

---------------------------------------------------------------------------
-- achievements
---------------------------------------------------------------------------
local achCat = nil
local function BuildAch()
    local f = MenuScreen("ttl_deeds")
    f.tabs = {}
    local cats = { { id = false, name = "Summary", icon = "spell_holy_championsbond" } }
    for _, c in ipairs(D.ACH_CATS) do cats[#cats + 1] = { id = c.id, name = c.id == "feats" and "Feats" or c.name, icon = c.icon } end
    for i, c in ipairs(cats) do
        local t = Tab(f, function() achCat = c.id or nil UI.ShowAch() end)
        t.m:Set(Icon(c.icon), "ring") t.label:SetText(c.name) t.cat = c.id
        f.tabs[i] = t
    end
    f.big = KitTex(f, "sh_big", "ARTWORK", 1)
    f.digits = {}
    for i = 1, 4 do f.digits[i] = KitTex(f, "shd_0", "ARTWORK", 3) end
    f.ptsL = Txt(f, 30, MORPHEUS, 1, 1, 1) f.ptsL:SetShadowOffset(0, -2)
    f.ptsS = Txt(f, 9, nil, MUTE[1], MUTE[2], MUTE[3])
    f.sumL = Txt(f, 11, nil, MUTE[1], MUTE[2], MUTE[3]) f.sumL:SetText("Progress")
    f.sumR = Txt(f, 11, nil, MUTE[1], MUTE[2], MUTE[3])
    f.barBg = Slice3(f, "barbg", "ARTWORK", 0, 5)
    f.bar = Slice3(f, "fill", "ARTWORK", 1, 5)
    f.cards = {}
    for i = 1, 8 do
        local c = CreateFrame("Frame", nil, f)
        c.plate = Slice9(c, "pl_done", "BACKGROUND", 0, 18)
        c.m = Medal(c, "ARTWORK", 1)
        c.name = Txt(c, 18, MORPHEUS) c.name:SetShadowOffset(0, -2) c.name:SetJustifyH("LEFT")
        c.desc = Txt(c, 11.5, nil, 216 / 255, 204 / 255, 178 / 255) c.desc:SetJustifyH("LEFT") c.desc:SetSpacing(1.5)
        c.note = Txt(c, 10, nil, 110 / 255, 100 / 255, 118 / 255) c.note:SetJustifyH("LEFT")
        c.pbg = Slice3(c, "barbg", "ARTWORK", 0, 4) c.pbar = Slice3(c, "fill_g", "ARTWORK", 1, 4)
        c.sh = KitTex(c, "sh_gold_10", "ARTWORK", 2)
        c.first = Slice3(c, "gb_n", "ARTWORK", 3, 9)
        c.firstL = Txt(c, 8) c.firstL:SetText(Spaced("Guild first")) c.firstL:SetTextColor(42 / 255, 22 / 255, 0) c.firstL:SetShadowColor(0, 0, 0, 0)
        c.firstL:SetDrawLayer("OVERLAY", 7)
        f.cards[i] = c
    end
    return f
end
local function SetPoints(f, n, cx, y)
    local s = tostring(n)
    local k = #s > 3 and 0.6 or 0.7
    local ws, tot = {}, 0
    for i = 1, #s do local e = K["shd_" .. s:sub(i, i)] ws[i] = (e[6] - 2 * e[8]) * k tot = tot + ws[i] - 1 end
    local dx = cx - tot / 2
    for i, t in ipairs(f.digits) do
        local ch = s:sub(i, i)
        if ch ~= "" then KitSet(t, "shd_" .. ch) KitAtK(t, f, dx, y, k) dx = dx + ws[i] - 1 t:Show() else t:Hide() end
    end
end
function UI.ShowAch()
    overlay = "ach"
    ClearOv()
    local f, S = ov.ach, ns.HTLSocial
    f:Show()
    if S then S:CheckProfile() end
    local have, all, got, total, firsts = 0, 0, 0, #D.ACHIEVEMENTS, 0
    if S then
        have, all = S:Points() got, total = S:Count()
        for _, v in pairs(S.Data().firsts) do if ns.Util.IsMe(v.who) then firsts = firsts + 1 end end
    end
    local oy = LayoutMenu(f, got .. " of " .. total .. " earned \194\183 " .. firsts .. " guild first" .. (firsts == 1 and "" or "s"))
    local counts = {}
    if S then for _, row in ipairs(S:List()) do local c = row.a.cat counts[c] = counts[c] or { 0, 0 } counts[c][2] = counts[c][2] + 1 if row.earned then counts[c][1] = counts[c][1] + 1 end end end
    for i, t in ipairs(f.tabs) do
        t:ClearAllPoints() t:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -(oy + 116 + (i - 1) * 50))
        local c = t.cat and counts[t.cat] or { got, total }
        t.note:SetText(c and (c[1] .. "/" .. c[2]) or "")
        t.on = (t.cat or nil) == achCat t:Look()
    end
    -- the points: the big shield and its number, the total beside it
    KitAtK(f.big, f, OV_W - 26 - 60, 20, 60 / 64)
    SetPoints(f, have, OV_W - 26 - 30, 20 + 17)
    f.ptsL:SetText(Num(have)) f.ptsL:ClearAllPoints()
    local ph = (f.ptsL:GetStringHeight() or 30) + 2 + (f.ptsS:GetStringHeight() or 9)
    f.ptsL:SetPoint("TOPRIGHT", f, "TOPLEFT", OV_W - 26 - 60 - 12, -(20 + 30 - ph / 2))
    f.ptsS:SetText(Spaced("of " .. Num(all) .. " points")) f.ptsS:ClearAllPoints() f.ptsS:SetPoint("TOPRIGHT", f.ptsL, "BOTTOMRIGHT", 0, -2)
    -- progress
    f.sumL:ClearAllPoints() f.sumL:SetPoint("LEFT", f, "TOPLEFT", PL, -(oy + 125))
    f.sumR:SetText(got .. " / " .. total) f.sumR:ClearAllPoints() f.sumR:SetPoint("RIGHT", f, "TOPLEFT", OV_W - 26, -(oy + 125))
    local bx = PL + (f.sumL:GetStringWidth() or 50) + 12
    local bw = OV_W - 26 - (f.sumR:GetStringWidth() or 40) - 12 - bx
    f.barBg:Place(f, bx, oy + 120, bw, 10)
    f.bar:Place(f, bx, oy + 120, max(10, bw * got / max(1, total)), 10)
    -- the cards: two columns of 104-high plates
    local list = S and S:List(achCat) or {}
    local cw = (OV_W - PL - 26 - 16) / 2
    for i, c in ipairs(f.cards) do
        local row = list[i]
        c:SetShown(row ~= nil)
        if row then
            local a = row.a
            local kind = a.feat and "feat" or row.earned and "done" or "todo"
            local col, line = (i - 1) % 2, floor((i - 1) / 2)
            c:ClearAllPoints() c:SetPoint("TOPLEFT", f, "TOPLEFT", PL + col * (cw + 16), -(oy + 146 + line * 118)) c:SetSize(cw, 104)
            c.plate:Kit("pl_" .. kind) c.plate:Place(c, 0, 0, cw, 104)
            c.m:Set(Icon(a.icon), kind == "todo" and "ring_dim" or "ring") c.m:Place(c, 18, 24, 56)
            local mine = row.earned and row.first and ns.Util.IsMe(row.first.who)
            c.name:SetText(a.name) FitLine(c.name, MORPHEUS, 18, 12, cw - 92 - 76 - (mine and 84 or 0))
            if kind == "feat" then c.name:SetTextColor(1, 0.57, 0.16) elseif kind == "done" then c.name:SetTextColor(1, 0.89, 0.6) else c.name:SetTextColor(0.92, 0.88, 0.81) end
            c.name:ClearAllPoints() c.name:SetPoint("TOPLEFT", c, "TOPLEFT", 92, -18)
            c.desc:SetText(a.desc) c.desc:SetWidth(cw - 92 - 76) c.desc:ClearAllPoints() c.desc:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -4)
            local note
            if row.earned then note = "Earned " .. date("%d %B", row.earned):gsub("^0", "")
            elseif kind == "feat" and row.first then note = (ns.Util.ShortName(row.first.who) or row.first.who) .. " \194\183 " .. date("%d %B", row.first.t):gsub("^0", "")
            elseif row.need and row.need > 1 then note = Num(row.have or 0) .. " / " .. Num(row.need)
            elseif row.first then note = "First in guild: " .. (ns.Util.ShortName(row.first.who) or row.first.who)
            else note = "No one in the guild yet" end
            local showBar = not row.earned and row.need and row.need > 1
            c.pbg:SetShown(showBar) c.pbar:SetShown(showBar)
            if showBar then
                local dh = c.desc:GetStringHeight() or 14
                local by = 18 + 22 + 4 + dh + 7
                c.pbg:Place(c, 92, by, cw - 92 - 76, 8)
                c.pbar:Place(c, 92, by, max(8, (cw - 92 - 76) * min(1, (row.have or 0) / row.need)), 8)
                c.note:ClearAllPoints() c.note:SetPoint("TOPLEFT", c, "TOPLEFT", 92, -(by + 8 + 5))
            else
                c.note:ClearAllPoints() c.note:SetPoint("TOPLEFT", c.desc, "BOTTOMLEFT", 0, -5)
            end
            c.note:SetText(note)
            KitSet(c.sh, a.feat and "sh_feat" or ((row.earned and "sh_gold_" or "sh_grey_") .. a.pts))
            KitAtK(c.sh, c, cw - 18 - 48, 22, 48 / 46)
            c.first:SetShown(mine and true or false) c.firstL:SetShown(mine and true or false)
            if mine then
                local tw = floor((c.firstL:GetStringWidth() or 70) + 16 + 0.5)
                local tx = cw - 18 - 48 - 10 - tw
                c.first:Place(c, tx, 37, tw, 18)
                c.firstL:ClearAllPoints() c.firstL:SetPoint("CENTER", c, "TOPLEFT", tx + tw / 2, -46)
            end
        end
    end
end

---------------------------------------------------------------------------
-- the Argent Dawn
---------------------------------------------------------------------------
local function BuildDawn()
    local f = MenuScreen("ttl_dawn")
    local cr = CreateFrame("Frame", nil, f)
    cr:SetSize(330, 516)
    cr.plate = Slice9(cr, "pl_green", "BACKGROUND", 0, 18)
    cr.star = cr:CreateTexture(nil, "BACKGROUND", nil, 2) cr.star:SetTexture(LTOAST) cr.star:SetTexCoord(LT_STAR[1], LT_STAR[3], LT_STAR[2], LT_STAR[4]) cr.star:SetBlendMode("ADD")
    cr.starMask = cr:CreateMaskTexture() cr.starMask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE") cr.starMask:SetAllPoints(cr.star) cr.star:AddMaskTexture(cr.starMask)
    cr.star:SetPoint("CENTER", cr, "TOPLEFT", 165, -130) cr.star:SetSize(300, 300) cr.star:SetVertexColor(0.55, 1, 0.45, 0.6)
    cr.seal = Medal(cr, "ARTWORK", 1) cr.seal:Set(Icon("inv_misc_token_argentdawn3"), "ring_green") cr.seal:Place(cr, 165 - 46, 40, 92)
    cr.name = KitTex(cr, "ttl_ad", "ARTWORK", 2)
    local k = K.ttl_ad
    KitAt(cr.name, cr, 165 - (k[6] - 2 * k[8]) / 2, 140)
    cr.st = Txt(cr, 19, MORPHEUS, 0.96, 0.81, 0.42) cr.st:SetShadowOffset(0, -2) cr.st:SetPoint("TOP", cr, "TOPLEFT", 165, -182)
    cr.barBg = Slice3(cr, "barbg14", "ARTWORK", 0, 7) cr.barBg:Place(cr, 24, 220, 282, 14)
    cr.bar = Slice3(cr, "fill_g", "ARTWORK", 1, 5)
    cr.num = Txt(cr, 10, nil, 1, 1, 1) cr.num:SetDrawLayer("OVERLAY", 7) cr.num:SetPoint("CENTER", cr, "TOPLEFT", 165, -227)
    cr.tl = Txt(cr, 9, nil, 110 / 255, 100 / 255, 118 / 255) cr.tl:SetPoint("TOPLEFT", cr, "TOPLEFT", 24, -238)
    cr.tr = Txt(cr, 9, nil, 110 / 255, 100 / 255, 118 / 255) cr.tr:SetPoint("TOPRIGHT", cr, "TOPLEFT", 306, -238)
    cr.ways = {}
    for i, w in ipairs({ { "spell_holy_holybolt", "Every minute held", "+54" }, { "inv_misc_bone_humanskull_01", "Scourgestones from elites", "+" .. D.STONE_REP .. " each" },
                         { "spell_shadow_deathcoil", "Bosses slain", "+150" }, { "inv_misc_token_argentdawn2", "Weekly challenge win", "+" .. Num(D.CHALLENGE_REP) } }) do
        local wy = 270 + (i - 1) * 48
        local r = { bg = Slice3(cr, "lrow", "ARTWORK", 0, 17), m = Medal(cr, "ARTWORK", 2), l = Txt(cr, 11.5, nil, 216 / 255, 204 / 255, 178 / 255), v = Txt(cr, 11.5, nil, Hex("a6d873")) }
        r.bg:Place(cr, 18, wy, 294, 40)
        r.m:Set(Icon(w[1]), "ring") r.m:Place(cr, 24, wy + 6, 28)
        r.l:SetText(w[2]) r.l:SetPoint("LEFT", cr, "TOPLEFT", 62, -(wy + 20))
        r.v:SetText(w[3]) r.v:SetPoint("RIGHT", cr, "TOPLEFT", 298, -(wy + 20))
        cr.ways[i] = r
    end
    f.crest = cr
    -- the ladder: a spine of light, a medallion per standing, its rewards as small plates
    local ld = CreateFrame("Frame", nil, f)
    ld:SetSize(730, 516)
    ld.spineA = Rect(ld, "BACKGROUND", 1, 1, 1, 1, 1) ld.spineB = Rect(ld, "BACKGROUND", 1, 1, 1, 1, 1)
    ld.spineGlow = ld:CreateTexture(nil, "BACKGROUND", nil, 0) ld.spineGlow:SetTexture(D.MEDIA .. "UI\\glow") ld.spineGlow:SetBlendMode("ADD")
    ld.rungs = {}
    for i = 2, #D.STANDINGS do
        local st = D.STANDINGS[i]
        local r = { node = Medal(ld, "ARTWORK", 3), name = Txt(ld, 16, MORPHEUS), at = Txt(ld, 9, nil, 110 / 255, 100 / 255, 118 / 255), cards = {} }
        r.name:SetText(st.name) r.name:SetShadowOffset(0, -2)
        r.at:SetJustifyH("CENTER") r.at:SetWidth(82)
        for kk, rw in ipairs(st.rewards or {}) do
            local c = CreateFrame("Frame", nil, ld)
            c:SetSize(314, 94)
            c.plate = Slice9(c, "pl_grey", "BACKGROUND", 0, 18)
            c.m = Medal(c, "ARTWORK", 1)
            c.tg = Txt(c, 8) c.tg:SetText(Spaced((rw.kind == "stage" and "New stage" or rw.kind == "perk" and "Every run" or rw.kind == "look" and "Look" or "Title") .. (rw.soon and " \194\183 soon" or "")))
            c.tg:SetPoint("TOPLEFT", c, "TOPLEFT", 82, -14)
            c.name = Txt(c, 17, MORPHEUS) c.name:SetShadowOffset(0, -2) c.name:SetJustifyH("LEFT") c.name:SetText(rw.name) c.name:SetPoint("TOPLEFT", c, "TOPLEFT", 82, -28)
            c.desc = Txt(c, 10.5, nil, MUTE[1], MUTE[2], MUTE[3]) c.desc:SetJustifyH("LEFT") c.desc:SetWidth(314 - 94) c.desc:SetText(rw.desc) c.desc:SetPoint("TOPLEFT", c, "TOPLEFT", 82, -50)
            if rw.kind == "look" then
                c.wear = Pill(c, function()
                    local d = ns.HTLSocial.Data()
                    d.look[rw.id] = d.look[rw.id] == false and true or false
                    UI.ShowDawn()
                end, { size = 10 })
            end
            c.rw = rw
            r.cards[kk] = c
        end
        ld.rungs[#ld.rungs + 1] = r
    end
    f.ladder = ld
    return f
end
function UI.ShowDawn()
    overlay = "dawn"
    ClearOv()
    local f, S = ov.dawn, ns.HTLSocial
    f:Show()
    local d = S and S.Data() or { rep = 0, look = {} }
    local rep = d.rep or 0
    local cur, ci, nxt = D.STANDINGS[1], 1, D.STANDINGS[2]
    if S then cur, ci, nxt = S:Standing(rep) end
    local oy = LayoutMenu(f, "Light's Hope Chapel \194\183 quartermaster")
    local cr = f.crest
    cr:ClearAllPoints() cr:SetPoint("TOPLEFT", f, "TOPLEFT", 30, -(oy + 108))
    cr.plate:Place(cr, 0, 0, 330, 516)
    cr.st:SetText(cur.name)
    local lo, hi = cur.at, nxt and nxt.at or cur.at
    local k = nxt and min(1, (rep - lo) / max(1, hi - lo)) or 1
    cr.bar:Place(cr, 24, 222, max(10, 282 * k), 10)
    cr.num:SetText(nxt and (Num(rep - lo) .. " / " .. Num(hi - lo)) or "Exalted")
    cr.tl:SetText(Spaced(cur.name)) cr.tr:SetText(nxt and Spaced(nxt.name) or "")
    -- the ladder
    local ld = f.ladder
    ld:ClearAllPoints() ld:SetPoint("TOPLEFT", f, "TOPLEFT", 392, -(oy + 108))
    local split = 30 + (ci - 2 + 0.5) * 128 + 23
    ld.spineA:ClearAllPoints() ld.spineA:SetPoint("TOPLEFT", ld, "TOPLEFT", 34, -30) ld.spineA:SetSize(2, max(0.1, split - 30))
    ns.UI:GradientRGBA(ld.spineA, "VERTICAL", 0.96, 0.81, 0.42, 0.9, 0.65, 0.85, 0.45, 0.9)
    ld.spineB:ClearAllPoints() ld.spineB:SetPoint("TOPLEFT", ld, "TOPLEFT", 34, -split) ld.spineB:SetSize(2, max(0.1, 516 - 40 - split))
    ns.UI:GradientRGBA(ld.spineB, "VERTICAL", 0.43, 0.39, 0.46, 0.2, 0.43, 0.39, 0.46, 0.45)
    ld.spineGlow:ClearAllPoints() ld.spineGlow:SetPoint("CENTER", ld, "TOPLEFT", 35, -(30 + split) / 2) ld.spineGlow:SetSize(26, split) ld.spineGlow:SetVertexColor(0.65, 0.85, 0.45, 0.35)
    for i, r in ipairs(ld.rungs) do
        local st = D.STANDINGS[i + 1]
        local state = rep >= st.at and (ci == i + 1 and "now" or "done") or (ci == i and "next" or "later")
        local ry = (i - 1) * 128
        local dim = state == "next" or state == "later"
        r.node:Set(Icon(i == 1 and "inv_misc_token_argentdawn" or i == 2 and "inv_misc_token_argentdawn2" or i == 3 and "inv_misc_token_argentdawn3" or "spell_holy_championsbond"), state == "now" and "ring_gold" or dim and "ring_dim" or "ring")
        r.node:Place(ld, 12, ry + 22, 46)
        r.name:ClearAllPoints() r.name:SetPoint("TOP", ld, "TOPLEFT", 35, -(ry + 74))
        r.name:SetTextColor(state == "done" and 0.65 or state == "now" and 0.96 or 0.92, state == "done" and 0.85 or state == "now" and 0.81 or 0.88, state == "done" and 0.45 or state == "now" and 0.42 or 0.81)
        r.at:SetText(Num(st.at) .. (state == "now" and "\n|cfff4cf6ayou are here|r" or ""))
        r.at:ClearAllPoints() r.at:SetPoint("TOP", r.name, "BOTTOM", 0, -1)
        for kk, c in ipairs(r.cards) do
            c:ClearAllPoints() c:SetPoint("TOPLEFT", ld, "TOPLEFT", 90 + (kk - 1) * (314 + 12), -(ry + 6))
            c.plate:Kit(dim and "pl_grey" or "pl_done") c.plate:Place(c, 0, 0, 314, 94)
            c.m:Set(Icon(c.rw.icon), dim and "ring_dim" or "ring") c.m:Place(c, 16, 20, 50)
            c.tg:SetTextColor(c.rw.soon and 110 / 255 or 0.65, c.rw.soon and 100 / 255 or 0.85, c.rw.soon and 118 / 255 or 0.45)
            c.name:SetTextColor(dim and 0.92 or 1, dim and 0.88 or 0.89, dim and 0.81 or 0.6)
            FitLine(c.name, MORPHEUS, 17, 12, 314 - 94 - (c.wear and 80 or 0))
            c:SetAlpha(state == "later" and 0.55 or 1)
            if c.wear then
                local on = not dim and d.look[c.rw.id] ~= false
                c.wear:SetShown(not dim)
                local w = c.wear:Set(on and "Wearing" or "Hidden", on, 22, nil, nil, 10, 10)
                c.wear:ClearAllPoints() c.wear:SetPoint("TOPLEFT", c, "TOPLEFT", 314 - 12 - w, -10)
            end
        end
    end
end


---------------------------------------------------------------------------
-- the Necropolis: Naxxramas's five runs (four quarters round the Frostwyrm Lair), a side panel for the chosen one,
-- your Tier 3 and Frost Resistance in the corners; then the Desecrated screen (the sets, Craftsman Wilhelm)
---------------------------------------------------------------------------
do                                              -- (a block: UI.lua's main chunk is at Lua's 200 locals)
local MOBS = D.MOBS
local nxState = { sel = "arachnid", cls = nil }
local Q_POS = { arachnid = { 22, 130 }, plague = { 436, 130 }, military = { 22, 362 }, construct = { 436, 362 } }
local function SpriteTC(key, dir, col, square)      -- a unit's frame: its page and texcoords (square: the top of it)
    local pg, fx, fy, fw, fh = Rd.Frame(key, dir or 2, col or 0)
    if not pg then return nil end
    local u0, u1, v0, v1 = fx / pg[2], (fx + fw) / pg[2], fy / pg[3], (fy + fh) / pg[3]
    if square then
        local side = min(fw, fh)
        local cx = fx + fw / 2
        u0, u1 = (cx - side / 2) / pg[2], (cx + side / 2) / pg[2]
        v0, v1 = (fy + (fh > fw and fh * 0.04 or 0)) / pg[3], (fy + (fh > fw and fh * 0.04 or 0) + side) / pg[3]
    end
    return pg[1], u0, u1, v0, v1, fw, fh
end
local function FloorTex(t, ST, w, h, k)               -- the stage's own floor, tiled into a window
    t:SetTexture(ST.ground[1], "REPEAT", "REPEAT")
    t:SetTexCoord(0, w / (k or 110), 0, h / (k or 110))
end
local function Window(parent)                          -- a glass window that clips what it holds
    local wnd = CreateFrame("Frame", nil, parent)
    pcall(wnd.SetClipsChildren, wnd, true)
    wnd.floor = wnd:CreateTexture(nil, "BACKGROUND", nil, 0)
    wnd.floor:SetAllPoints()
    wnd.shade = Rect(wnd, "BACKGROUND", 1, 1, 1, 1, 1) wnd.shade:SetAllPoints()
    wnd.boss = wnd:CreateTexture(nil, "ARTWORK", nil, 0)
    wnd.glass = Slice9(wnd, "glass9", "OVERLAY", 7, 12)
    return wnd
end
local function SetBoss(tex, key, h, x, bottom, rel, dir)
    local file, u0, u1, v0, v1, fw, fh = SpriteTC(key, dir or 3, 0)
    if not file then tex:Hide() return end
    local sc = h / fh
    tex:SetTexture(file) tex:SetTexCoord(u0, u1, v0, v1)
    tex:ClearAllPoints() tex:SetPoint("BOTTOMLEFT", rel, "BOTTOMLEFT", x - fw * sc / 2, bottom) tex:SetSize(fw * sc, fh * sc)
    tex:Show()
end

function UI._BuildNaxx()
    local f = MenuScreen("ttl_naxx")
    f.runes = { strip = Slice3(f, "strip", "ARTWORK", 0, 20), m = Medal(f, "ARTWORK", 2), t = Txt(f, 11, nil, MUTE[1], MUTE[2], MUTE[3]) }
    f.q = {}
    for _, key in ipairs(D.WINGS) do
        local q = CreateFrame("Button", nil, f)
        q:SetSize(384, 214)
        q.key = key
        q.plate = Slice9(q, "pl_grey", "BACKGROUND", 0, 18)
        q.wnd = Window(q)
        q.wnd:SetPoint("TOPLEFT", 10, -10) q.wnd:SetSize(364, 194)
        q.top = CreateFrame("Frame", nil, q) q.top:SetAllPoints() q.top:SetFrameLevel(q.wnd:GetFrameLevel() + 3)
        q.state = Txt(q.top, 9) q.name = Txt(q.top, 23, MORPHEUS, 0.95, 0.92, 0.85) q.name:SetShadowOffset(0, -2)
        q.sub = Txt(q.top, 11, nil, MUTE[1], MUTE[2], MUTE[3])
        q.pips, q.toks = {}, {}
        for i = 1, 4 do q.pips[i] = Medal(q.top, "ARTWORK", 2) end
        for i = 1, 2 do local t = q.top:CreateTexture(nil, "ARTWORK", nil, 3) t:SetSize(20, 20) q.toks[i] = t end
        q:SetScript("OnClick", function() nxState.sel = key Sound("hover", 0.03) UI.ShowNaxx() end)
        q:SetScript("OnEnter", function(self) self.hov = true UI.NaxxLook(self) end)
        q:SetScript("OnLeave", function(self) self.hov = false UI.NaxxLook(self) end)
        f.q[key] = q
    end
    -- the lair: a round window on the ice in the middle
    local lr = CreateFrame("Button", nil, f)
    lr:SetSize(196, 196)
    lr:SetFrameLevel(f:GetFrameLevel() + 20)
    local function disc(layer, sub, inset)
        local t = lr:CreateTexture(nil, layer, nil, sub)
        t:SetPoint("TOPLEFT", inset, -inset) t:SetPoint("BOTTOMRIGHT", -inset, inset)
        local m = lr:CreateMaskTexture() m:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE") m:SetAllPoints(t) t:AddMaskTexture(m)
        t.m = m
        return t
    end
    lr.rimO = disc("BACKGROUND", -3, 0) lr.rimO:SetColorTexture(0.05, 0.03, 0.02, 1)
    lr.rim = disc("BACKGROUND", -2, 2) lr.rim:SetColorTexture(1, 1, 1, 1)
    lr.rimI = disc("BACKGROUND", -1, 8) lr.rimI:SetColorTexture(0.05, 0.03, 0.02, 1)
    lr.floor = lr:CreateTexture(nil, "BACKGROUND", nil, 0) lr.floor:SetPoint("TOPLEFT", 10, -10) lr.floor:SetPoint("BOTTOMRIGHT", -10, 10)
    lr.mask = lr:CreateMaskTexture() lr.mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE") lr.mask:SetAllPoints(lr.floor) lr.floor:AddMaskTexture(lr.mask)
    lr.shade = lr:CreateTexture(nil, "BACKGROUND", nil, 1) lr.shade:SetAllPoints(lr.floor) lr.shade:SetTexture(D.MEDIA .. "UI\\dark_hole") lr.shade:SetVertexColor(0.02, 0.04, 0.1, 0.8) lr.shade:AddMaskTexture(lr.mask)
    lr.glow = lr:CreateTexture(nil, "BACKGROUND", nil, 2) lr.glow:SetTexture(D.MEDIA .. "UI\\glow") lr.glow:SetBlendMode("ADD") lr.glow:SetPoint("CENTER") lr.glow:SetSize(260, 260)
    lr.boss = lr:CreateTexture(nil, "ARTWORK", nil, 0)
    lr.bossMask = lr:CreateMaskTexture() lr.bossMask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE") lr.bossMask:SetAllPoints(lr.floor) lr.boss:AddMaskTexture(lr.bossMask)
    lr.name = Txt(lr, 17, MORPHEUS, 0.88, 0.95, 1) lr.name:SetShadowOffset(0, -2) lr.name:SetText("Frostwyrm Lair") lr.name:SetPoint("BOTTOM", lr, "BOTTOM", 0, 42)
    -- (the state: a gold tag across the foot of the rim, where the circle is too narrow for words)
    lr.tagF = CreateFrame("Frame", nil, lr) lr.tagF:SetAllPoints() lr.tagF:SetFrameLevel(lr:GetFrameLevel() + 2)
    lr.tag = Slice3(lr.tagF, "gb_n", "ARTWORK", 0, 9)
    lr.sub = Txt(lr.tagF, 8.5) lr.sub:SetTextColor(42 / 255, 22 / 255, 0) lr.sub:SetShadowColor(0, 0, 0, 0) lr.sub:SetDrawLayer("OVERLAY", 7)
    lr:SetScript("OnClick", function() nxState.sel = "frost" Sound("hover", 0.03) UI.ShowNaxx() end)
    f.lair = lr
    -- the side panel: the chosen run
    local sd = CreateFrame("Frame", nil, f)
    sd:SetSize(280, 446)
    sd.plate = Slice9(sd, "pl_green", "BACKGROUND", 0, 18)
    sd.wnd = Window(sd) sd.wnd:SetPoint("TOPLEFT", 10, -10) sd.wnd:SetSize(260, 112)
    sd.top = CreateFrame("Frame", nil, sd) sd.top:SetAllPoints() sd.top:SetFrameLevel(sd.wnd:GetFrameLevel() + 3)
    sd.name = Txt(sd.top, 22, MORPHEUS) sd.name:SetShadowOffset(0, -2) sd.name:SetPoint("TOP", sd, "TOPLEFT", 140, -130)
    sd.blurb = Txt(sd.top, 10.5, nil, MUTE[1], MUTE[2], MUTE[3]) sd.blurb:SetWidth(240) sd.blurb:SetJustifyH("CENTER") sd.blurb:SetPoint("TOP", sd, "TOPLEFT", 140, -160)
    sd.rows = {}
    for i = 1, 4 do
        local r = { bg = Slice3(sd.top, "lrow", "ARTWORK", 0, 17), m = Medal(sd.top, "ARTWORK", 2), l = Txt(sd.top, 11.5, nil, 0.92, 0.88, 0.8), v = Txt(sd.top, 9.5, nil, 110 / 255, 100 / 255, 118 / 255) }
        sd.rows[i] = r
    end
    sd.cls = {}
    for i, cls in ipairs({ "PALADIN", "MAGE", "WARRIOR" }) do
        local b = Pill(sd.top, function() nxState.cls = cls UI.ShowNaxx() end, { icon = true, size = 10 })
        b.cls = cls
        sd.cls[i] = b
    end
    sd.go = Pill(sd.top, function() UI.EnterNaxx() end, { big = true, size = 15 })
    sd.lock = Txt(sd.top, 11, nil, 0.85, 0.7, 0.55) sd.lock:SetWidth(240) sd.lock:SetJustifyH("CENTER")
    f.side = sd
    -- the corners
    f.t3 = { strip = Slice3(f, "strip", "ARTWORK", 0, 20), m = Medal(f, "ARTWORK", 2), t = Txt(f, 11, nil, MUTE[1], MUTE[2], MUTE[3]), b = CreateFrame("Button", nil, f) }
    f.t3.b:SetScript("OnClick", function() UI.ShowT3() end)
    f.fr = { strip = Slice3(f, "strip", "ARTWORK", 0, 20), m = Medal(f, "ARTWORK", 2), t = Txt(f, 11, nil, MUTE[1], MUTE[2], MUTE[3]), b = CreateFrame("Button", nil, f) }
    f.fr.b:SetScript("OnClick", function() UI.ShowT3() end)
    return f
end

function UI.NaxxLook(q)
    local G = ns.HTLGame
    local done = G and G:Cleared(q.key)
    local sel = nxState.sel == q.key
    q.plate:Kit(sel and "pl_green" or done and "pl_done" or "pl_grey")
    q.plate:Place(q, 0, 0, 384, 214)
    q:SetAlpha((G and G:NaxxOpen() or q.hov or sel) and 1 or 0.6)
end

function UI.ShowNaxx()
    overlay = "naxx"
    ClearOv()
    local f, G = ov.naxx, ns.HTLGame
    f:Show()
    local d = G and G.Data() or { naxx = { cleared = {}, best = {} }, frozen = 0, bank = 0, frostRes = 0 }
    local cls = nxState.cls or Class()
    nxState.cls = cls
    local n = 0
    for _, k in ipairs(D.STAGE_ORDER) do if d.naxx.cleared[k] then n = n + 1 end end
    local oy = LayoutMenu(f, "The Necropolis \194\183 " .. n .. " of 5 runs cleared")
    -- Frozen Runes, top right
    local rn = f.runes
    rn.t:SetText("|cfff4cf6a" .. (d.frozen or 0) .. "|r Frozen Runes")
    rn.m:Set(Icon("inv_misc_rune_09"), "ring")
    local rw = 6 + 24 + 10 + (rn.t:GetStringWidth() or 90) + 14
    rn.strip:Place(f, OV_W - 22 - rw, 22, rw, 34)
    rn.m:Place(f, OV_W - 22 - rw + 6, 27, 24)
    rn.t:ClearAllPoints() rn.t:SetPoint("LEFT", f, "TOPLEFT", OV_W - 22 - rw + 40, -39)
    -- the quarters
    for _, key in ipairs(D.WINGS) do
        local ST, q = D.STAGES[key], f.q[key]
        local pos = Q_POS[key]
        local right = pos[1] > 300
        q:ClearAllPoints() q:SetPoint("TOPLEFT", f, "TOPLEFT", pos[1], -(oy + pos[2]))
        UI.NaxxLook(q)
        FloorTex(q.wnd.floor, ST, 364, 194, 100)
        q.wnd.floor:SetVertexColor(0.55, 0.55, 0.55)
        ns.UI:GradientRGBA(q.wnd.shade, "HORIZONTAL", 0.03, 0.02, 0.05, right and 0.1 or 0.92, 0.03, 0.02, 0.05, right and 0.92 or 0.1)
        q.wnd.glass:Place(q.wnd, 0, 0, 364, 194)
        SetBoss(q.wnd.boss, MOBS[ST.finale].sprite or ST.finale, key == "arachnid" and 130 or 160, right and 92 or 272, 6, q.wnd, right and 1 or 3)
        local done = G and G:Cleared(key)
        local slain = 0
        for _, b in ipairs(ST.bosses) do if G and G:Slain(b) then slain = slain + 1 end end
        q.state:SetText(Spaced(done and "Cleared" or slain > 0 and (slain .. " of " .. #ST.bosses .. " slain") or (G and G:NaxxOpen()) and "Not cleared" or "Locked"))
        q.state:SetTextColor(done and 0.96 or ST.color[1], done and 0.81 or ST.color[2], done and 0.42 or ST.color[3])
        q.name:SetText(ST.name:gsub("^The ", ""))
        local best = d.naxx.best[key]
        q.sub:SetText(best and ("Best " .. Rd.Clock(best)) or (#ST.bosses .. " bosses"))
        local tx = right and (384 - 24) or 24
        local pt = right and "TOPRIGHT" or "TOPLEFT"
        for _, fs in ipairs({ q.state, q.name, q.sub }) do fs:ClearAllPoints() end
        q.state:SetPoint(pt, q, "TOPLEFT", tx, -24)
        q.name:SetPoint(pt, q, "TOPLEFT", tx, -38)
        q.sub:SetPoint(pt, q, "TOPLEFT", tx, -66)
        for i, m in ipairs(q.pips) do
            local b = ST.bosses[i]
            m:SetShown(b ~= nil)
            if b then
                local file, u0, u1, v0, v1 = SpriteTC(MOBS[b].sprite or b, 2, 0, true)
                local got = G and G:Slain(b)
                m:Set(file, got and "ring_gold" or "ring_dim", { u0, u1, v0, v1 })
                m.icon:SetDesaturated(false) m.icon:SetVertexColor(got and 1 or 0.55, got and 1 or 0.55, got and 1 or 0.55)
                m:Place(q, right and (384 - 24 - 34 - (i - 1) * 43) or (24 + (i - 1) * 43), 90, 34)
            end
        end
        for i, t in ipairs(q.toks) do
            local slot = ST.tokens[i]
            t:SetShown(slot ~= nil)
            if slot then
                local have = G and G:T3(cls)[slot]
                t:SetTexture(Icon(D.T3Icon(cls, slot))) t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                t:SetDesaturated(not have) t:SetVertexColor(have and 1 or 0.5, have and 1 or 0.5, have and 1 or 0.5)
                t:ClearAllPoints() t:SetPoint("TOPLEFT", q, "TOPLEFT", right and (384 - 24 - 20 - (i - 1) * 26) or (24 + (i - 1) * 26), -170)
            end
        end
    end
    -- the lair
    local lr, LST = f.lair, D.STAGES.frost
    local open = G and G:LairOpen()
    lr:ClearAllPoints() lr:SetPoint("TOPLEFT", f, "TOPLEFT", 328, -(oy + 262))
    FloorTex(lr.floor, LST, 196, 196, 90)
    lr.glow:SetVertexColor(0.45, 0.7, 1, open and 0.5 or 0.2)
    local file, u0, u1, v0, v1, fw, fh = SpriteTC("n_sapphiron", 2, 0)
    if file then
        local sc = 120 / fh
        lr.boss:SetTexture(file) lr.boss:SetTexCoord(u0, u1, v0, v1)
        lr.boss:ClearAllPoints() lr.boss:SetPoint("BOTTOM", lr, "BOTTOM", 0, 44) lr.boss:SetSize(fw * sc, fh * sc)
        lr.boss:SetDesaturated(not open) lr.boss:SetAlpha(open and 1 or 0.55)
    end
    if nxState.sel == "frost" then ns.UI:GradientRGBA(lr.rim, "VERTICAL", 0.3, 0.55, 0.2, 1, 0.68, 0.9, 0.45, 1)
    else ns.UI:GradientRGBA(lr.rim, "VERTICAL", 0.55, 0.36, 0.1, 1, 0.98, 0.8, 0.4, 1) end
    local left = 0
    for _, w in ipairs(D.WINGS) do if not d.naxx.cleared[w] then left = left + 1 end end
    lr.sub:SetText(Spaced((G and G:Cleared("frost")) and "Cleared" or open and "Open" or (left .. " quarter" .. (left == 1 and "" or "s") .. " to go")))
    local tw = floor((lr.sub:GetStringWidth() or 100) + 22 + 0.5)
    lr.tag:Place(lr, 98 - tw / 2, 196 - 11, tw, 20)
    lr.sub:ClearAllPoints() lr.sub:SetPoint("CENTER", lr, "TOPLEFT", 98, -(196 - 1))
    -- the side panel
    local sel = nxState.sel
    local ST = D.STAGES[sel]
    local sd = f.side
    sd:ClearAllPoints() sd:SetPoint("TOPLEFT", f, "TOPLEFT", 846, -(oy + 130))
    sd.plate:Place(sd, 0, 0, 280, 446)
    FloorTex(sd.wnd.floor, ST, 260, 112, 90)
    sd.wnd.floor:SetVertexColor(0.6, 0.6, 0.6)
    ns.UI:GradientRGBA(sd.wnd.shade, "VERTICAL", 0.03, 0.02, 0.05, 0.75, 0.03, 0.02, 0.05, 0.05)
    sd.wnd.glass:Place(sd.wnd, 0, 0, 260, 112)
    SetBoss(sd.wnd.boss, MOBS[ST.finale].sprite or ST.finale, 104, 130, 4, sd.wnd, 2)
    sd.name:SetText(ST.name) sd.name:SetTextColor(ST.color[1], ST.color[2], ST.color[3])
    FitLine(sd.name, MORPHEUS, 22, 14, 256)
    sd.blurb:SetText(ST.blurb)
    local times = {}
    for _, ev in ipairs(ST.events) do if ev.kind == "boss" or ev.kind == "finale" then times[ev.mob] = ev.t end end
    times.n_thaddius = times.n_thaddius or 900
    for i, r in ipairs(sd.rows) do
        local b = ST.bosses[i]
        local on = b ~= nil
        r.bg:SetShown(on) r.m:SetShown(on) r.l:SetShown(on) r.v:SetShown(on)
        if on then
            local y = 196 + (i - 1) * 40
            r.bg:Place(sd, 14, y, 252, 34)
            local file2, a0, a1, b0, b1 = SpriteTC(MOBS[b].sprite or b, 2, 0, true)
            local got = G and G:Slain(b)
            r.m:Set(file2, got and "ring_gold" or "ring", { a0, a1, b0, b1 })
            r.m.icon:SetDesaturated(false)
            r.m:Place(sd, 19, y + 4, 26)
            local nm = MOBS[b].horseman and "The Four Horsemen" or MOBS[b].name
            r.l:SetText(nm) r.l:ClearAllPoints() r.l:SetPoint("LEFT", sd, "TOPLEFT", 54, -(y + 17))
            FitLine(r.l, nil, 11.5, 9, 150)
            local tt = times[b] or (b == "n_thaddius" and 900)
            r.v:SetText((tt and Rd.Clock(tt):gsub("^0", "") or "") .. (got and " \194\183 slain" or ""))
            r.v:SetTextColor(got and 0.65 or 110 / 255, got and 0.85 or 100 / 255, got and 0.45 or 118 / 255)
            r.v:ClearAllPoints() r.v:SetPoint("RIGHT", sd, "TOPLEFT", 258, -(y + 17))
        end
    end
    local cy = 196 + #ST.bosses * 40 + 6
    local ws, tot = {}, 0
    for i, b in ipairs(sd.cls) do ws[i] = b:Set(CLASSES[b.cls].name, b.cls == cls, 26, CLS_ICON[b.cls], nil, 9, 10) tot = tot + ws[i] + (i > 1 and 4 or 0) end
    local x = 140 - tot / 2
    for i, b in ipairs(sd.cls) do b:ClearAllPoints() b:SetPoint("TOPLEFT", sd, "TOPLEFT", x, -cy) x = x + ws[i] + 4 end
    local can = G and G:StageOpen(sel)
    sd.go:SetShown(can and true or false)
    sd.lock:SetShown(not can)
    if can then
        local gw = sd.go:Set("Enter " .. (ST.short or ST.name), false, 38)
        sd.go:ClearAllPoints() sd.go:SetPoint("TOPLEFT", sd, "TOPLEFT", 140 - gw / 2, -(446 - 22 - 38))
    else
        sd.lock:SetText(not (G and G:NaxxOpen()) and "Hold the line once in Eastern Plaguelands to open Naxxramas." or "Slay the four masters of the quarters to open the lair.")
        sd.lock:ClearAllPoints() sd.lock:SetPoint("TOP", sd, "TOPLEFT", 140, -(446 - 22 - 34))
    end
    -- the corners: Tier 3 and Frost Resistance
    local y = StageH() - 22 - 40
    local t3 = f.t3
    local parts = {}
    for _, c in ipairs({ "PALADIN", "MAGE", "WARRIOR" }) do parts[#parts + 1] = CLASSES[c].name .. " |cfff4cf6a" .. (G and G:T3Count(c) or 0) .. " / 9|r" end
    t3.t:SetText("Tier 3 \194\183 " .. table.concat(parts, " \194\183 "))
    t3.m:Set(Icon(D.T3Icon(cls, "chest")), "ring")
    local tw = 6 + 28 + 10 + (t3.t:GetStringWidth() or 200) + 14
    t3.strip:Place(f, 22, y, tw, 40) t3.m:Place(f, 28, y + 6, 28)
    t3.t:ClearAllPoints() t3.t:SetPoint("LEFT", f, "TOPLEFT", 66, -(y + 20))
    t3.b:ClearAllPoints() t3.b:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -y) t3.b:SetSize(tw, 40)
    local fr = f.fr
    fr.t:SetText("Frost Resistance |cfff4cf6arank " .. (d.frostRes or 0) .. "|r of " .. #D.FROST_RES)
    fr.m:Set(Icon("spell_frost_frostarmor02"), "ring")
    local fw2 = 6 + 28 + 10 + (fr.t:GetStringWidth() or 160) + 14
    fr.strip:Place(f, OV_W - 22 - fw2, y, fw2, 40) fr.m:Place(f, OV_W - 22 - fw2 + 6, y + 6, 28)
    fr.t:ClearAllPoints() fr.t:SetPoint("LEFT", f, "TOPLEFT", OV_W - 22 - fw2 + 44, -(y + 20))
    fr.b:ClearAllPoints() fr.b:SetPoint("TOPLEFT", f, "TOPLEFT", OV_W - 22 - fw2, -y) fr.b:SetSize(fw2, 40)
end

function UI.EnterNaxx()
    local G = ns.HTLGame
    if not (G and G:StageOpen(nxState.sel)) then return end
    UI.Start(nxState.cls or Class(), { stage = nxState.sel })
end

-- the Desecrated screen: a column per class (the set on the hero, nine tokens and where they drop, the bonuses),
-- and Craftsman Wilhelm's shelf (Frost Resistance for Frozen Runes and gold)
function UI._BuildT3()
    local f = MenuScreen("ttl_t3")
    f.back:SetScript("OnClick", function() UI.ShowNaxx() end)
    f.cols = {}
    for i, cls in ipairs({ "PALADIN", "MAGE", "WARRIOR" }) do
        local c = CreateFrame("Frame", nil, f)
        c:SetSize(356, 330)
        c.cls = cls
        c.plate = Slice9(c, "pl_" .. CLS_PLATE[cls], "BACKGROUND", 0, 18)
        c.scene = Scene(c, c:GetFrameLevel() + 1)
        c.scene:SetPoint("TOPLEFT", c, "TOPLEFT", 10, -10)
        c.top = CreateFrame("Frame", nil, c) c.top:SetAllPoints() c.top:SetFrameLevel(c:GetFrameLevel() + 6)
        c.name = Txt(c.top, 19, MORPHEUS, CLASSES[cls].color[1], CLASSES[cls].color[2], CLASSES[cls].color[3]) c.name:SetShadowOffset(0, -2)
        c.name:SetPoint("TOP", c, "TOPLEFT", 178, -128)
        c.n = Txt(c.top, 9, nil, MUTE[1], MUTE[2], MUTE[3]) c.n:SetPoint("TOP", c, "TOPLEFT", 178, -151)
        c.slots = {}
        for k = 1, 9 do
            local s = { icon = c.top:CreateTexture(nil, "ARTWORK", nil, 1), ring = c.top:CreateTexture(nil, "ARTWORK", nil, 0), l = Txt(c.top, 9, nil, 0.85, 0.8, 0.72), src = Txt(c.top, 8, nil, 110 / 255, 100 / 255, 118 / 255) }
            s.ring:SetColorTexture(0, 0, 0, 0.85)
            c.slots[k] = s
        end
        c.bonus = Txt(c.top, 10, nil, MUTE[1], MUTE[2], MUTE[3]) c.bonus:SetWidth(330) c.bonus:SetJustifyH("CENTER")
        c.wear = Pill(c.top, function() ns.HTLGame:ToggleT3Look() UI.ShowT3() end, { size = 10 })
        f.cols[i] = c
    end
    local w = CreateFrame("Frame", nil, f)
    w:SetSize(1104, 120)
    w.plate = Slice9(w, "pl_grey", "BACKGROUND", 0, 18)
    w.m = Medal(w, "ARTWORK", 2)
    w.name = Txt(w, 19, MORPHEUS, 0.62, 0.85, 1) w.name:SetText("Craftsman Wilhelm") w.name:SetShadowOffset(0, -2)
    w.desc = Txt(w, 10.5, nil, MUTE[1], MUTE[2], MUTE[3]) w.desc:SetWidth(300) w.desc:SetJustifyH("LEFT")
    w.desc:SetText("Light's Hope Chapel. Turns Frozen Runes and banked gold into Frost Resistance: the Chill in the Frostwyrm Lair fills more slowly.")
    w.cells = {}
    for k = 1, #D.FROST_RES do w.cells[k] = { bg = Slice3(w, "lrow", "ARTWORK", 0, 17), r = Txt(w, 18, MORPHEUS), e = Txt(w, 9, nil, 0.85, 0.8, 0.72), c = Txt(w, 8, nil, 110 / 255, 100 / 255, 118 / 255) } end
    w.buy = Pill(w, function() if ns.HTLGame:BuyFrost() then Sound("coin") end UI.ShowT3() end, { big = true, size = 14 })
    w.have = Txt(w, 10, nil, MUTE[1], MUTE[2], MUTE[3])
    f.wil = w
    return f
end

function UI.ShowT3()
    overlay = "t3"
    ClearOv()
    local f, G = ov.t3, ns.HTLGame
    f:Show()
    local d = G and G.Data() or { frozen = 0, bank = 0, frostRes = 0 }
    local oy = LayoutMenu(f, "Tier 3 \194\183 nine tokens make a set")
    f.back:Set("\194\171 Necropolis", false, 30)
    -- which master drops which piece
    local from = {}
    local function short(boss) return MOBS[boss].horseman and "Four Horsemen" or (MOBS[boss].name:gsub("^Grand Widow ", ""):gsub("^Instructor ", ""):gsub(" the .*$", "")) end
    for _, b in ipairs({ "n_anub", "n_faerlina", "n_maexxna", "n_noth", "n_heigan", "n_loatheb", "n_razuvious", "n_gothik", "n_mograine", "n_patchwerk", "n_grobbulus", "n_gluth", "n_thaddius", "n_kelthuzad" }) do
        local slot = D.T3_FROM[b]
        if slot and slot ~= "any" then from[slot] = from[slot] and (from[slot] .. " \194\183 " .. short(b)) or short(b) end
    end
    for i, c in ipairs(f.cols) do
        local cls, set = c.cls, D.T3_SETS[c.cls]
        c:ClearAllPoints() c:SetPoint("TOPLEFT", f, "TOPLEFT", 22 + (i - 1) * 374, -(oy + 106))
        c.plate:Place(c, 0, 0, 356, 330)
        local mine = G and G:T3(cls) or {}
        local n = G and G:T3Count(cls) or 0
        c.scene:Set(336, 110, cls, CLASSES[cls].color, { 26 / 255, 20 / 255, 32 / 255, 11 / 255, 9 / 255, 16 / 255 }, { heroH = 96, heroBottom = 8, raysY = 84, poolY = 14 })
        local file, u0, u1, v0, v1, fw, fh = SpriteTC(set.sprite, 2, 0)
        if file then
            local sc = 96 / fh
            c.scene.hero:SetTexture(file) c.scene.hero:SetTexCoord(u0, u1, v0, v1)
            c.scene.hero:ClearAllPoints() c.scene.hero:SetPoint("BOTTOMLEFT", c.scene, "BOTTOMLEFT", 168 - fw * sc / 2, 8) c.scene.hero:SetSize(fw * sc, fh * sc)
            c.scene.hero:SetDesaturated(false) c.scene.hero:SetVertexColor(n < 9 and 0.72 or 1, n < 9 and 0.72 or 1, n < 9 and 0.72 or 1)
        end
        c.name:SetText(set.name) FitLine(c.name, MORPHEUS, 19, 13, 330)
        c.n:SetText(Spaced(n .. " of 9"))
        for k, s in ipairs(c.slots) do
            local sl = D.T3_SLOTS[k]
            local have = mine[sl.id]
            local col, row = (k - 1) % 3, floor((k - 1) / 3)
            local x, y = 14 + col * 112, 170 + row * 42
            s.ring:ClearAllPoints() s.ring:SetPoint("TOPLEFT", c, "TOPLEFT", x - 1, -(y - 1)) s.ring:SetSize(32, 32)
            s.ring:SetColorTexture(have and 0.64 or 0.23, have and 0.21 or 0.2, have and 0.93 or 0.25, 1)
            s.icon:SetTexture(Icon(D.T3Icon(cls, sl.id))) s.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            s.icon:ClearAllPoints() s.icon:SetPoint("TOPLEFT", c, "TOPLEFT", x, -y) s.icon:SetSize(30, 30)
            s.icon:SetDesaturated(not have) s.icon:SetVertexColor(have and 1 or 0.45, have and 1 or 0.45, have and 1 or 0.45)
            s.l:SetText(sl.name) s.l:ClearAllPoints() s.l:SetPoint("TOPLEFT", c, "TOPLEFT", x + 36, -(y + 3))
            s.src:SetText(sl.id == "ring" and "Kel'Thuzad" or from[sl.id] or "") s.src:ClearAllPoints() s.src:SetPoint("TOPLEFT", c, "TOPLEFT", x + 36, -(y + 17))
            s.src:SetWidth(74) s.src:SetJustifyH("LEFT") s.src:SetWordWrap(true) s.src:SetMaxLines(2)
        end
        c.bonus:SetText((n >= 3 and "|cffa6d873" or "") .. "3: +5% damage|r   " .. (n >= 6 and "|cffa6d873" or "") .. "6: +15 health|r   " .. (n >= 9 and "|cffa6d873" or "") .. "9: the set's look|r")
        c.bonus:ClearAllPoints() c.bonus:SetPoint("TOP", c, "TOPLEFT", 178, -(170 + 3 * 42 + 4))
        c.wear:SetShown(n >= 9)
        if n >= 9 then
            local on = d.t3Look ~= false
            local ww = c.wear:Set(on and "Wearing" or "Hidden", on, 22, nil, nil, 10, 10)
            c.wear:ClearAllPoints() c.wear:SetPoint("TOPLEFT", c, "TOPLEFT", 356 - 14 - ww, -14)
        end
    end
    -- Craftsman Wilhelm
    local w = f.wil
    w:ClearAllPoints() w:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -(oy + 452))
    w.plate:Place(w, 0, 0, 1104, 120)
    w.m:Set(Icon("inv_misc_rune_09"), "ring") w.m:Place(w, 20, 32, 56)
    w.name:ClearAllPoints() w.name:SetPoint("TOPLEFT", w, "TOPLEFT", 92, -20)
    w.desc:ClearAllPoints() w.desc:SetPoint("TOPLEFT", w, "TOPLEFT", 92, -46)
    local rank = d.frostRes or 0
    for k, cell in ipairs(w.cells) do
        local cfg = D.FROST_RES[k]
        local x = 400 + (k - 1) * 102
        local got = k <= rank
        cell.bg:SetKit(got and "lrow_me" or "lrow") cell.bg:Place(w, x, 16, 96, 58)
        cell.r:SetText(tostring(k)) cell.r:SetTextColor(got and 1 or 0.62, got and 0.86 or 0.85, got and 0.45 or 1)
        cell.r:ClearAllPoints() cell.r:SetPoint("TOP", w, "TOPLEFT", x + 48, -20)
        cell.e:SetText(floor(D.FROST_RES_SLOW * 100 * k + 0.5) .. "% slower") cell.e:ClearAllPoints() cell.e:SetPoint("TOP", w, "TOPLEFT", x + 48, -42)
        cell.c:SetText(cfg.runes .. " runes \194\183 " .. cfg.gold .. "g") cell.c:ClearAllPoints() cell.c:SetPoint("TOP", w, "TOPLEFT", x + 48, -56)
    end
    local nxt = G and G:FrostNext()
    local ok = G and G:CanBuyFrost()
    w.buy:SetShown(nxt ~= nil)
    if nxt then
        local bw = w.buy:Set("Learn rank " .. (rank + 1), false, 38)
        w.buy:ClearAllPoints() w.buy:SetPoint("TOPLEFT", w, "TOPLEFT", 1104 - 22 - bw, -22)
        w.buy:SetAlpha(ok and 1 or 0.55)
    end
    local need = nxt and ("Rank " .. (rank + 1) .. " costs " .. nxt.runes .. " runes and " .. Num(nxt.gold) .. " gold \194\183 ") or "Every rank learned \194\183 "
    w.have:SetText(need .. "you have |cfff4cf6a" .. (d.frozen or 0) .. "|r runes, |cfff4cf6a" .. Num(d.bank or 0) .. "|r gold")
    w.have:ClearAllPoints() w.have:SetPoint("BOTTOMRIGHT", w, "TOPLEFT", 1104 - 22, -96)
end
end

-- a run of the week's challenge: its rules, its seed, its board
function UI.StartChallenge()
    local S = ns.HTLSocial
    if not S then return end
    local ch, seed = S:Challenge()
    UI.Start(ch.cls or Class(), { rules = ch, seed = seed, challenge = S:Week(), stage = ch.stage })
end

---------------------------------------------------------------------------
-- the loop, keys and focus
---------------------------------------------------------------------------
local function Input()
    local ix = (held.D or held.RIGHT) and 1 or 0
    ix = ix - ((held.A or held.LEFT) and 1 or 0)
    local iy = (held.S or held.DOWN) and 1 or 0
    iy = iy - ((held.W or held.UP) and 1 or 0)
    return ix, iy
end

-- (the world is drawn only when it changed: a step ran, the overlay or the run changed, the view was laid out; a
-- frame in between two 60 Hz steps would draw the same picture again. A slow redraw covers anything else.)
UI.drawIdle = 0
local function OnUpdate(_, elapsed)
    elapsed = min(elapsed, 0.1)
    if run then
        local stepped = false
        if run.attract and run.warm then
            local s = min(run.warm, 0.5)
            E.FastForward(run, s, true)
            run.warm = run.warm - s
            if run.warm <= 0 then run.warm, run.fadeIn = nil, 0 end
            stepped = true
        elseif run.attract then
            acc = min(acc + elapsed, STEP * 4)
            while acc >= STEP do acc = acc - STEP E.Step(run, STEP, 0, 0) stepped = true end
            if run.fadeIn then run.fadeIn = run.fadeIn + elapsed view.scaler:SetAlpha(min(1, run.fadeIn / 0.5)) if run.fadeIn >= 0.5 then run.fadeIn = nil end end
            if run.t > 400 then Attract() end
        elseif (focused or overlay) and not run.paused and not run.over then
            acc = min(acc + elapsed, STEP * 4)
            local ix, iy = 0, 0
            if focused then ix, iy = Input() end
            while acc >= STEP do
                acc = acc - STEP
                for _ = 1, run.speed or 1 do E.Step(run, STEP, ix, iy) end
                stepped = true
            end
        end
        if overlay == "choosing" then E.StepParts(run, elapsed) stepped = true end
        if run.wantLevelUp and overlay == nil then run.wantLevelUp = nil OpenLevelUp() end
        if run.chest and overlay == nil then ShowChest() end
        if run.over and overlay ~= "end" and not run.attract then ShowEnd(run.over) end
        UI.drawIdle = UI.drawIdle + elapsed
        if stepped or run ~= UI.drawnRun or overlay ~= UI.drawnOv or view.dirty or UI.drawIdle >= 0.25 then
            Rd.Draw(view, run)
            UI.drawnRun, UI.drawnOv, UI.drawIdle = run, overlay, 0
        end
        view.hud:SetShown(not run.attract)
    end
    TickPicker(elapsed)
    TickTitle(elapsed)
    TickTalents(elapsed)
    TickToast(elapsed)
    if run and not run.attract and not run.lab and not run.god and not run.dev and not run.over and ns.HTLSocial then
        UI.achAcc = (UI.achAcc or 0) + elapsed
        if UI.achAcc >= 1 then UI.achAcc = 0 ns.HTLSocial:CheckRun(run, false) end
    end
    TickEnd(elapsed)
    TickChest(elapsed)
    TickPreviews(elapsed)
    if UI.devBar or (run and run.dev) then UI.DevBar() end
    if overlay == nil and run and not run.attract and not focused and not run.over then UI.pausedHint:Show() else UI.pausedHint:Hide() end
end

local KEYS = { W = true, A = true, S = true, D = true, UP = true, DOWN = true, LEFT = true, RIGHT = true, SPACE = true, ENTER = true, ["1"] = true, ["2"] = true, ["3"] = true }
function UI.SetFocus(on)
    focused = on and true or false
    if root then pcall(root.EnableKeyboard, root, focused) end
    wipe(held)
    acc = 0
end
local function OnKeyDown(self, key)
    if key == "ESCAPE" then
        if overlay == "dev" then UI.CloseDev() pcall(self.SetPropagateKeyboardInput, self, false) return end
        if overlay == "pause" then ClosePause() pcall(self.SetPropagateKeyboardInput, self, false) return end
        if run and not run.attract and not run.over and overlay == nil then ShowPause() pcall(self.SetPropagateKeyboardInput, self, false) return end
        UI.SetFocus(false)
        pcall(self.SetPropagateKeyboardInput, self, false)
        return
    end
    -- (paused, every key but Esc goes on to the game: move, cast, open bags like in WoW's own menu-less pause)
    local mine = KEYS[key] and overlay ~= "pause"
    if not InCombatLockdown() and self.SetPropagateKeyboardInput then pcall(self.SetPropagateKeyboardInput, self, not mine) end
    if not mine then return end
    held[key] = true
    if overlay == "level" and (key == "1" or key == "2" or key == "3") then UI.TakeLevel(tonumber(key)) end
    if (overlay == "chest" or overlay == "legend") and (key == "SPACE" or key == "ENTER") then
        if overlay == "legend" then UI.TakeLegend() elseif ov.loot:IsShown() then CloseOv(true) end
    end
end
local function OnKeyUp(_, key) held[key] = nil end

local function Layout()
    if not root then return end
    local w, h = root:GetWidth(), root:GetHeight()
    if not w or w < 100 then w, h = 786, 518 end
    Rd.Layout(view, w, h)
    local k = w / OV_W
    stage:SetScale(k)
    stage:SetSize(OV_W, h / k)
    if overlay == "title" and ov and ov.title then UI.LayoutTitle() end
    if UI.lab and UI.lab:IsShown() then ShowLab() end
end

function UI:CreatePanel(parent)
    root = CreateFrame("Frame", nil, parent)
    root:SetAllPoints()
    view = Rd.NewView(root)
    ov = CreateFrame("Frame", nil, root)
    ov:SetAllPoints()
    pcall(ov.SetClipsChildren, ov, true)      -- the glows and sparkles stay inside the game
    ov:SetFrameLevel(view.top:GetFrameLevel() + 4)
    ov.dim = ov:CreateTexture(nil, "BACKGROUND")
    ov.dim:SetAllPoints()
    ov.dim:SetColorTexture(1, 1, 1, 1)
    ns.UI:GradientRGBA(ov.dim, "VERTICAL", 0, 0, 0, 0.82, 0.02, 0.01, 0.03, 0.7)
    ov.dim:Hide()
    stage = CreateFrame("Frame", nil, ov)
    stage:SetPoint("TOPLEFT")
    ov.title = BuildTitle()
    ov.talents = BuildTalents()
    ov.board, ov.ach, ov.dawn = BuildBoard(), BuildAch(), BuildDawn()
    ov.naxx, ov.t3 = UI._BuildNaxx(), UI._BuildT3()
    toast = BuildToast()
    ov.picker = BuildPicker()
    ov.coffer, ov.loot, ov.legend = BuildCoffer()
    ov["end"] = BuildEnd()
    ov.pause = BuildPause()
    UI.lab = BuildLab()
    UI.pausedHint = ov:CreateFontString(nil, "OVERLAY")
    UI.pausedHint:SetFont(FONT, 16, "OUTLINE")
    UI.pausedHint:SetPoint("CENTER")
    UI.pausedHint:SetText("Paused \194\183 click to play")
    UI.pausedHint:SetTextColor(244 / 255, 207 / 255, 106 / 255)
    UI.pausedHint:Hide()
    root:EnableMouse(true)
    root:SetScript("OnSizeChanged", Layout)
    root:SetScript("OnMouseDown", function() UI.SetFocus(true) end)
    root:SetScript("OnKeyDown", OnKeyDown)
    root:SetScript("OnKeyUp", OnKeyUp)
    root:SetScript("OnUpdate", OnUpdate)
    root:SetScript("OnHide", function() UI.SetFocus(false) end)
    pcall(root.EnableKeyboard, root, false)
    Layout()
    ShowTitle()
    function root:OnGameShown() Layout() end
    function root:OnGameHidden() UI.SetFocus(false) end
    ns:On("GAMES_COMBAT", function(inCombat) if inCombat then UI.SetFocus(false) if run and not run.attract and overlay == nil then ShowPause() end end end)
    Rd.Draw(view, run)
    return root
end

---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- the hub's poster: the game playing itself in its own view (a Paladin or a Mage, the bot at the wheel, god mode),
-- warmed up a slice a frame and faded in; a new scene every few minutes. :Tick(elapsed) is called by the hub while
-- the poster is in front.
---------------------------------------------------------------------------
local POSTER_KIT = {
    PALADIN = { spells = { "avenger", "avenger", "exorcism", "holywrath", "holywrath" }, passives = { "might", "crusader" } },
    MAGE = { spells = { "arcane", "arcane", "nova", "blizzard", "flamestrike" }, passives = { "intellect", "might" } },
    WARRIOR = { spells = { "cleave", "cleave", "thunderclap", "charge", "execute" }, passives = { "might", "fortitude" } },
}
function UI:NewPoster(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetAllPoints(parent)
    pcall(c.SetClipsChildren, c, true)
    c.view = Rd.NewView(c)
    c.view.scaler:SetAlpha(0)
    c.view.hud:Hide()
    c.n = 0
    local function Scene()
        c.n = c.n + 1
        local cls = ({ "PALADIN", "MAGE", "WARRIOR" })[(c.n - 1) % 3 + 1]
        local r = E.New({ cls = cls, bot = true, god = true, attract = true, seed = math.random(1, 1000000) })
        for _, id in ipairs(POSTER_KIT[cls].spells) do E.AddSpell(r, id) end
        for _, id in ipairs(POSTER_KIT[cls].passives) do E.AddPassive(r, id) end
        E.JumpStart(r, 110)
        r.warm, r.paused = 1.5, false
        c.run, c.acc, c.fade = r, 0, 0
    end
    function c:Layout() end
    function c:Refresh() end
    function c:Tick(elapsed)
        elapsed = min(elapsed or 0, 0.1)
        if not self.run then Scene() end
        local r = self.run
        local w, h = self:GetWidth() or 0, self:GetHeight() or 0
        if w < 50 then w = 300 end
        if h < 50 then h = 320 end
        if self.w ~= w or self.h ~= h then Rd.LayoutWide(self.view, w, h, 380) self.w, self.h = w, h end
        if r.warm then
            local s = min(r.warm, 0.5)
            E.FastForward(r, s, true)
            r.warm = r.warm - s
            if r.warm <= 0 then r.warm = nil end
            return
        end
        self.acc = min(self.acc + elapsed, STEP * 4)
        local stepped = self.drawn ~= r
        while self.acc >= STEP do
            self.acc = self.acc - STEP
            if r.lvlT and r.lvlT >= 0 then r.lvlT, r.tsGoal, r.ts = -1, 1, 1 end
            r.wantLevelUp, r.chest, r.pending = nil, nil, 0
            E.Step(r, STEP, 0, 0)
            stepped = true
        end
        -- the scene's end: it fades out over its last second, then the next one warms up
        self.fade = min(1, self.fade + elapsed * 1.5)
        local left = 300 - r.t
        self.view.scaler:SetAlpha(min(self.fade, max(0, left)))
        if stepped or self.view.dirty then Rd.Draw(self.view, r) self.drawn = r end
        self.view.hud:Hide()
        if left <= 0 or r.over then Scene() end
    end
    return c
end

-- (tests and the audit)
function UI._Run() return run end
function UI._SetRun(r) run = Hook(r) end
function UI._View() return view end
function UI._Root() return root end
function UI._Overlay() return overlay end
function UI._Key(key, up) if up then OnKeyUp(root, key) else OnKeyDown(root, key) end end
function UI._Tick(dt) OnUpdate(root, dt) end
function UI._OpenLevelUp(preset) OpenLevelUp(preset) end
function UI._ShowChest() ShowChest() end
function UI._ShowEnd(kind) ShowEnd(kind) end
function UI._ShowTitle() ShowTitle() end
function UI._Previews() return previews end
function UI._Picker() return ov.picker end
function UI._Loot() return ov.loot end
function UI._TakeLoot() ov.loot.take:GetScript("OnClick")(ov.loot.take) end

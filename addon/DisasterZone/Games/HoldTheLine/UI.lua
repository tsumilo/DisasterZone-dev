if DisasterZoneBoot and DisasterZoneBoot.Run("Games/HoldTheLine/UI.lua", ...) then return end -- DisasterZone Games/HoldTheLine/UI.lua
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
    opts.seed = opts.seed or floor(((time and time() or 1) * 7 + math.random(1, 100000)) % 2000000000)
    run = Hook(E.New(opts))
    acc = 0
    if not opts.attract and view then view.scaler:SetAlpha(1) end
    if ns.HTLGame and not opts.attract and not opts.lab then ns.HTLGame:Started(run) end
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
    for _, f in ipairs({ ov.title, ov.picker, ov.coffer, ov.loot, ov.legend, ov["end"], ov.pause, ov.talents, ov.board, ov.ach, ov.dawn }) do if f then f:Hide() end end
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
            while pv.acc >= STEP do
                pv.acc = pv.acc - STEP
                E.Step(pv.run, STEP, 0, 0)
                if pv.run.pvPassive then PassiveFx(pv.run, STEP) end
            end
            Rd.Draw(pv.view, pv.run)
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
-- the back over everything while it is turned away
local function NewCard(parent, i)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(W_CARD, H_CARD)
    c.i = i
    local L = c:GetFrameLevel()
    c.pv = NewPreview(c)
    c.pv.frame:SetPoint("TOPLEFT", c, "TOPLEFT", WIN_X, -WIN_Y)
    c.pv.frame:SetFrameLevel(L + 1)
    c.face = CreateFrame("Frame", nil, c)
    c.face:SetAllPoints()
    c.face:SetFrameLevel(L + 60)
    c.plate = KitTex(c.face, "c2_rare", "BACKGROUND")
    c.top = CreateFrame("Frame", nil, c.face)
    c.top:SetAllPoints()
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
    -- the light that sweeps a chosen card
    c.flash = c.top:CreateTexture(nil, "OVERLAY", nil, 6)
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
    -- the face's squeeze: scale its art across (a squeezed card shows no words and no preview)
    local fa = not half and w or 0
    if fa < 0.999 or c.faSet ~= fa or c.plateDirty then KitAt(c.plate, c.face, W_CARD * (1 - fa) / 2, 0, max(0.1, W_CARD * fa), H_CARD) c.faSet = fa c.plateDirty = nil end
    c.top:SetAlpha(fa > 0.85 and 1 or 0)
    c.pv.frame:SetAlpha(fa > 0.85 and 1 or 0)
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
    for i = 1, 6 do
        local row = CreateFrame("Frame", nil, l)
        row:SetSize(540, 68)
        row.bg = KitTex(row, "lt_rare", "BACKGROUND")
        row.icon = row:CreateTexture(nil, "ARTWORK") row.icon:SetSize(42, 42)
        row.bd = row:CreateTexture(nil, "ARTWORK", nil, 1) row.bd:SetSize(56, 56)
        row.name = Words(row, 18, MORPHEUS)
        row.type = Words(row, 11) row.type:SetTextColor(GREY[1], GREY[2], GREY[3])
        row.dice = row:CreateTexture(nil, "ARTWORK") row.dice:SetTexture("Interface\\Buttons\\UI-GroupLoot-Dice-Up") row.dice:SetSize(26, 26)
        row.roll = Words(row, 20)
        l.rows[i] = row
    end
    l.goldIcon = l:CreateTexture(nil, "ARTWORK") l.goldIcon:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon") l.goldIcon:SetSize(14, 14)
    l.gold = Words(l, 13) l.gold:SetTextColor(1, 208 / 255, 64 / 255)
    l.take = CreateFrame("Button", nil, l)
    l.take.bg = Slice3(l.take, "gb_big", "BACKGROUND", 0, 19)
    l.take.label = Words(l.take, 15, MORPHEUS) l.take.label:SetText("Take all") l.take.label:SetTextColor(1, 231 / 255, 168 / 255) l.take.label:SetPoint("CENTER")
    l.take:SetScript("OnClick", function() CloseOv(true) end)
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
    f.items, f.gold = ch.items, ch.gold
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

local function ShowLoot(items, gold)
    overlay = "chest"
    ClearOv()
    ov.dim:Show()
    local l = ov.loot
    l:Show()
    local H = StageH()
    local n = #items
    local blockH = 14 + 44 + 18 + n * 76 + 30 + 40
    local y = max(10, H / 2 - blockH / 2)
    local x0 = OV_W / 2 - 270
    l.rule:ClearAllPoints() l.rule:SetPoint("TOP", l, "TOPLEFT", OV_W / 2, -y) l.rule:SetSize(440, 14)
    local hw = K.level_small[6] - 2 * K.level_small[8]
    KitAt(l.head, l, OV_W / 2 - hw / 2, y + 14)
    l.sub:SetText(n .. " reward" .. (n > 1 and "s" or "") .. " \194\183 Need rolls")
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
            row.delay = (i - 1) * 0.28
            row.final = 40 + floor(math.random() * 59)
            row.done = false
            row:SetAlpha(0)
            row:Show()
            l.rolls[#l.rolls + 1] = row
            y = y + 76
        else
            row:Hide()
        end
    end
    l.gold:SetText(gold .. " gold")
    l.gold:ClearAllPoints() l.gold:SetPoint("TOP", l, "TOPLEFT", OV_W / 2 + 10, -(y + 6))
    l.goldIcon:ClearAllPoints() l.goldIcon:SetPoint("RIGHT", l.gold, "LEFT", -6, 0)
    l.take:ClearAllPoints() l.take:SetPoint("TOP", l, "TOPLEFT", OV_W / 2, -(y + 34)) l.take:SetSize(124, 36) l.take.bg:Place(l.take, 0, 0, 124, 36)
    l.t = 0
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
                ShowLegend(f.legend.id, rest, f.gold)
            else
                Sound("pick")
                ShowLoot(f.items, f.gold)
            end
        end
    end
    local l = ov.loot
    if l:IsShown() then
        l.t = l.t + dt
        for i, row in ipairs(l.rolls or {}) do
            local k = min(1, max(0, (l.t - row.delay) / 0.5))
            local e = OvershootEase(k)
            row:SetAlpha(min(1, k * 2))
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
    f.again:SetScript("OnClick", function() UI.Start(run.cls) end)
    f.again:SetScript("OnEnter", function(self) Sound("hover", 0.03) self.bg:SetKit("gb_bighov") self.bg:Place(self, 0, 0, self:GetWidth(), 38) end)
    f.again:SetScript("OnLeave", function(self) self.bg:SetKit("gb_big") self.bg:Place(self, 0, 0, self:GetWidth(), 38) end)
    f.menu = CreateFrame("Button", nil, f)
    f.menu.bg = Slice3(f.menu, "gb", "BACKGROUND", 0, 15)
    f.menu.label = Words(f.menu, 12) f.menu.label:SetTextColor(234 / 255, 223 / 255, 198 / 255) f.menu.label:SetPoint("CENTER") f.menu.label:SetText("Choose class")
    f.menu:SetScript("OnClick", function() ShowTitle() end)
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
    local rep = floor(run.t * 0.9 + run.kills * 0.4 + run.bossKills * 150 + (run.stones or 0) * D.STONE_REP + 0.5)
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
    f.eyebrow:SetText(win and "T H E   L I N E   H E L D" or "E A S T E R N   P L A G U E L A N D S")
    f.eyebrow:SetTextColor(win and 1 or 0.9, win and 0.82 or 0.55, win and 0.4 or 0.5)
    f.eyebrow:ClearAllPoints() f.eyebrow:SetPoint("TOP", f, "TOPLEFT", cx, -(y + 22))
    f.title:SetText(win and "Victory" or "You have died")
    if win then f.title:SetTextColor(1, 0.84, 0.42) else f.title:SetTextColor(0.92, 0.26, 0.2) end
    f.title:ClearAllPoints() f.title:SetPoint("TOP", f, "TOPLEFT", cx, -(y + 35))
    y = y + 112
    f.lede:SetText(win and "The Pale Rider claimed you at the fifteenth minute. The Argent Dawn counts it a victory."
        or ("Slain by |cffffffff" .. (run.killer or "the Scourge") .. "|r at " .. Rd.Clock(run.t) .. "."))
    f.lede:ClearAllPoints() f.lede:SetPoint("TOP", f, "TOPLEFT", cx, -y)
    local newBest = floor(run.t) > prevBest and prevBest > 0
    f.best:SetText(newBest and ("N E W   B E S T  \194\183  was " .. Rd.Clock(prevBest)) or "")
    f.best:ClearAllPoints() f.best:SetPoint("TOP", f, "TOPLEFT", cx, -(y + 20))
    y = y + 22 + 30
    -- the numbers: five plates on hairlines
    local vals = { { "SURVIVED", Rd.Clock(run.t) }, { "LEVEL", tostring(run.level) }, { "SLAIN", tostring(run.kills) }, { "BOSSES", tostring(run.bossKills) }, { "GOLD BANKED", tostring(run.gold) } }
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
    f.again.label:SetText(win and "Hold it again" or "Release Spirit")
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

local function BuildPause()
    local f = CreateFrame("Frame", nil, stage)
    f:SetAllPoints()
    f.panel = KitTex(f, "panel", "BACKGROUND")
    f.title = Words(f, 28, MORPHEUS) f.title:SetText("Paused") f.title:SetTextColor(244 / 255, 207 / 255, 106 / 255)
    f.go = CreateFrame("Button", nil, f)
    f.go.bg = Slice3(f.go, "gb_big", "BACKGROUND", 0, 19)
    f.go.label = Words(f.go, 15, MORPHEUS) f.go.label:SetText("Resume") f.go.label:SetTextColor(1, 231 / 255, 168 / 255) f.go.label:SetPoint("CENTER")
    f.go:SetScript("OnClick", function() ClosePause() end)
    f:Hide()
    return f
end
local function ShowPause()
    overlay = "pause"
    run.paused = true
    ClearOv()
    local f = ov.pause
    f:Show()
    local H = StageH()
    local x, y = OV_W / 2 - 130, H / 2 - 60
    KitAt(f.panel, f, x, y, 260, 120)
    f.title:ClearAllPoints() f.title:SetPoint("TOP", f, "TOPLEFT", OV_W / 2, -(y + 18))
    f.go:ClearAllPoints() f.go:SetPoint("TOP", f, "TOPLEFT", OV_W / 2, -(y + 66)) f.go:SetSize(116, 36) f.go.bg:Place(f.go, 0, 0, 116, 36)
end
ClosePause = function() CloseOv(false) end

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

-- the title: the logo over the attract run, a hero plate per class (its sprite, name and kit; it walks when you
-- point at it), the spell lab, and your record along the foot
local HERO_W, HERO_H, LOGO_K = 236, 214, 0.86
local HERO_ORDER = { "PALADIN", "MAGE", "WARRIOR" }
local DIFFICULTY, DIFF_WORD = { PALADIN = 1, MAGE = 2, WARRIOR = 3 }, { "EASY", "HARDER", "HARDEST" }

local function BuildTitle()
    local f = CreateFrame("Frame", nil, stage)
    f:SetAllPoints()
    f.night = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    f.night:SetAllPoints() f.night:SetColorTexture(1, 1, 1, 1)
    ns.UI:GradientRGBA(f.night, "VERTICAL", 4 / 255, 3 / 255, 7 / 255, 1, 18 / 255, 12 / 255, 24 / 255, 1)
    f.vig = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    f.vig:SetTexture(D.MEDIA .. "UI\\dark_hole")
    f.vig:SetVertexColor(4 / 255, 3 / 255, 8 / 255, 0.85)
    f.shade = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.shade:SetColorTexture(1, 1, 1, 1)
    f.foot = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.foot:SetColorTexture(1, 1, 1, 1)
    f.glow = LegendGlow(f, "BACKGROUND", 3)
    f.logo = KitTex(f, "logo_main", "ARTWORK")
    f.heroes = {}
    for i, cls in ipairs(HERO_ORDER) do
        local C = CLASSES[cls]
        local b = CreateFrame("Button", nil, f)
        b:SetSize(HERO_W, HERO_H)
        b.cls = cls
        b.plate = KitTex(b, "hero", "BACKGROUND")
        b.floor = KitTex(b, "hero_floor", "BORDER")
        b.floor:SetBlendMode("ADD")
        b.floor:SetVertexColor(C.color[1], C.color[2], C.color[3], 0.5)
        KitAt(b.floor, b, HERO_W / 2 - 75, 104, 150, 46)
        b.sprite = b:CreateTexture(nil, "ARTWORK")
        b.name = Words(b, 26, MORPHEUS)
        b.name:SetText(C.name) b.name:SetTextColor(C.color[1], C.color[2], C.color[3])
        b.name:SetShadowOffset(0, -2)
        b.name:SetPoint("TOP", b, "TOPLEFT", HERO_W / 2, -142)
        -- how hard it is: lit gems, and the word
        b.diff = {}
        local dn = DIFFICULTY[cls] or 1
        for g = 1, 3 do
            local t = KitTex(b, g <= dn and "gem_on" or "gem_off", "ARTWORK", 3)
            KitAt(t, b, HERO_W - 14 - 46 + (g - 1) * 15, 16, 8, 8)
            b.diff[g] = t
        end
        b.diffL = Words(b, 9) b.diffL:SetText(DIFF_WORD[dn]) b.diffL:SetTextColor(0.62, 0.58, 0.66)
        b.diffL:SetPoint("TOPRIGHT", b, "TOPLEFT", HERO_W - 14, -28)
        b.kit = {}
        local ids = {}
        for _, id in ipairs(D.SPELL_ORDER) do if SPELLS[id].cls == cls then ids[#ids + 1] = id end end
        local x0 = HERO_W / 2 - (#ids * 24 + (#ids - 1) * 6) / 2
        for k, id in ipairs(ids) do
            local edge = b:CreateTexture(nil, "ARTWORK", nil, 0)
            edge:SetColorTexture(109 / 255, 90 / 255, 58 / 255, 1)
            edge:SetPoint("TOPLEFT", b, "TOPLEFT", x0 + (k - 1) * 30 - 2, -(176 - 2)) edge:SetSize(28, 28)
            local inner = b:CreateTexture(nil, "ARTWORK", nil, 1)
            inner:SetColorTexture(0, 0, 0, 1)
            inner:SetPoint("TOPLEFT", edge, "TOPLEFT", 1, -1) inner:SetSize(26, 26)
            local t = b:CreateTexture(nil, "ARTWORK", nil, 2)
            t:SetTexture(Icon(SPELLS[id].icon)) t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            t:SetPoint("TOPLEFT", edge, "TOPLEFT", 2, -2) t:SetSize(24, 24)
            b.kit[k] = t
        end
        b:SetScript("OnEnter", function(self) self.hov = true Sound("hover", 0.03) self:Look() end)
        b:SetScript("OnLeave", function(self) self.hov = false self:Look() end)
        b:SetScript("OnClick", function() UI.Start(cls) end)
        function b:Look()
            KitSet(self.plate, self.hov and "hero_hov" or "hero")
            KitAt(self.plate, self, 0, 0, HERO_W, HERO_H)
            self.floor:SetAlpha(self.hov and 1 or 0.6)
        end
        b:Look()
        f.heroes[i] = b
    end
    f.lab = CreateFrame("Button", nil, f)
    f.lab.bg = Slice3(f.lab, "gb", "BACKGROUND", 0, 15)
    f.lab.label = Words(f.lab, 12) f.lab.label:SetText("Spell lab") f.lab.label:SetPoint("CENTER", 0, 0)
    f.lab:SetScript("OnEnter", function(self) self.hov = true Sound("hover", 0.03) self:Look() end)
    f.lab:SetScript("OnLeave", function(self) self.hov = false self:Look() end)
    f.lab:SetScript("OnClick", function() OpenLab(Class()) end)
    function f.lab:Look()
        self.bg:SetKit(self.hov and "gb_hov" or "gb")
        self.bg:Place(self, 0, 0, self:GetWidth(), 30)
        self.label:SetTextColor(self.hov and 1 or 234 / 255, self.hov and 246 / 255 or 223 / 255, self.hov and 220 / 255 or 198 / 255)
    end
    f.tal = CreateFrame("Button", nil, f)
    f.tal.bg = Slice3(f.tal, "gb", "BACKGROUND", 0, 15)
    f.tal.label = Words(f.tal, 12) f.tal.label:SetPoint("CENTER", 0, 0)
    f.tal:SetScript("OnEnter", function(self) self.hov = true Sound("hover", 0.03) self:Look() end)
    f.tal:SetScript("OnLeave", function(self) self.hov = false self:Look() end)
    f.tal:SetScript("OnClick", function() UI.ShowTalents() end)
    f.tal.Look = f.lab.Look
    f.menu = { f.tal }
    for _, def in ipairs({ { "Leaderboard", function() UI.ShowBoard() end }, { "Achievements", function() UI.ShowAch() end }, { "Argent Dawn", function() UI.ShowDawn() end } }) do
        local b = CreateFrame("Button", nil, f)
        b.bg = Slice3(b, "gb", "BACKGROUND", 0, 15)
        b.label = Words(b, 12) b.label:SetPoint("CENTER", 0, 0) b.label:SetText(def[1])
        b:SetScript("OnEnter", function(self) self.hov = true Sound("hover", 0.03) self:Look() end)
        b:SetScript("OnLeave", function(self) self.hov = false self:Look() end)
        b:SetScript("OnClick", def[2])
        b.Look = f.lab.Look
        f.menu[#f.menu + 1] = b
    end
    f.menu[#f.menu + 1] = f.lab
    f.left = Words(f, 11) f.left:SetTextColor(157 / 255, 147 / 255, 163 / 255) f.left:SetJustifyH("LEFT")
    f.right = Words(f, 11) f.right:SetTextColor(157 / 255, 147 / 255, 163 / 255) f.right:SetJustifyH("RIGHT")
    f.right:SetText("WASD to move" .. DOT .. "spells cast themselves" .. DOT .. "Esc pauses")
    f:Hide()
    return f
end

local titleT = 0
local function TickTitle(dt)
    local f = ov.title
    if not f:IsShown() then return end
    titleT = titleT + dt
    f.glow:Tick(titleT, Easing(min(1, titleT / 0.9)), 0.9)
    f.night:SetAlpha(1 - view.scaler:GetAlpha())
    for _, b in ipairs(f.heroes) do
        local key = CLASSES[b.cls].sprite
        local U = A.UNITS[key]
        local col = b.hov and floor(titleT * 9) % U.walk or 0
        local pg, fx, fy, fw, fh, dx, dy = Rd.Frame(key, 2, col)
        if pg then
            local s = 2.3
            b.sprite:SetTexture(pg[1])
            b.sprite:SetTexCoord(fx / pg[2], (fx + fw) / pg[2], fy / pg[3], (fy + fh) / pg[3])
            b.sprite:ClearAllPoints()
            b.sprite:SetPoint("TOPLEFT", b, "TOPLEFT", HERO_W / 2 + dx * s, -(124 + dy * s))
            b.sprite:SetSize(fw * s, fh * s)
        end
    end
end

local function LayoutTitle()
    local f = ov.title
    local H = StageH()
    f.vig:ClearAllPoints() f.vig:SetPoint("CENTER", f, "TOPLEFT", OV_W / 2, -H * 0.42) f.vig:SetSize(OV_W * 1.5, H * 1.6)
    f.shade:ClearAllPoints() f.shade:SetPoint("TOPLEFT") f.shade:SetSize(OV_W, H * 0.3)
    ns.UI:GradientRGBA(f.shade, "VERTICAL", 6 / 255, 4 / 255, 10 / 255, 0, 6 / 255, 4 / 255, 10 / 255, 0.55)
    f.foot:ClearAllPoints() f.foot:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -H * 0.62) f.foot:SetSize(OV_W, H * 0.38)
    ns.UI:GradientRGBA(f.foot, "VERTICAL", 6 / 255, 4 / 255, 10 / 255, 0.92, 6 / 255, 4 / 255, 10 / 255, 0)
    local lw, lh = 760 * LOGO_K, 330 * LOGO_K
    local blockH = lh + 14 + HERO_H + 26 + 30
    local y = max(6, (H - 30) / 2 - blockH / 2)
    f.glow:Place(OV_W / 2, y + 112 * LOGO_K, 400)
    KitAtK(f.logo, f, OV_W / 2 - lw / 2, y, LOGO_K)
    y = y + lh + 14
    for i, b in ipairs(f.heroes) do
        b.hov = false b:Look()
        local n = #f.heroes
        b:ClearAllPoints() b:SetPoint("TOPLEFT", f, "TOPLEFT", OV_W / 2 - (n * HERO_W + (n - 1) * 22) / 2 + (i - 1) * (HERO_W + 22), -y)
    end
    y = y + HERO_H + 26
    local bank = ns.HTLGame and ns.HTLGame.Data().bank or 0
    f.tal.label:SetText(string.format("Talents    |T%s:12:12|t %d", "Interface\\MoneyFrame\\UI-GoldIcon", bank))
    local ws, tot = {}, 0
    for i, b in ipairs(f.menu) do ws[i] = floor((b.label:GetStringWidth() or 60) + 36) tot = tot + ws[i] + (i > 1 and 8 or 0) end
    local bx = OV_W / 2 - tot / 2
    for i, b in ipairs(f.menu) do
        b:ClearAllPoints() b:SetPoint("TOPLEFT", f, "TOPLEFT", bx, -y) b:SetSize(ws[i], 30)
        b.hov = false b:Look()
        bx = bx + ws[i] + 8
    end
    local d = ns.HTLGame and ns.HTLGame.Data() or { runs = 0, wins = 0, best = 0, rep = 0 }
    local standing = "Neutral"
    for _, s in ipairs(STANDING) do if (d.rep or 0) >= s[1] then standing = s[2] break end end
    f.left:SetText(d.runs > 0 and ("Best |cfff4cf6a" .. Rd.Clock(d.best) .. "|r" .. DOT .. d.wins .. (d.wins == 1 and " win" or " wins") .. DOT .. d.runs .. (d.runs == 1 and " run" or " runs") .. DOT .. "Argent Dawn |cfff4cf6a" .. standing .. "|r")
        or "Fifteen minutes. One class. The whole Scourge.")
    f.left:ClearAllPoints() f.left:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 22, 14)
    f.right:ClearAllPoints() f.right:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -22, 14)
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
-- the guild hall: the leaderboard (with the week's challenge), achievements, the Argent Dawn; and the toast that
-- slides in when an achievement is earned mid-run. Laid out as the mockup (dev: the Guild Hall artifact).
---------------------------------------------------------------------------
local CLS_ICON = { PALADIN = { 0, 0.25, 0.5, 0.75 }, MAGE = { 0.25, 0.5, 0, 0.25 }, WARRIOR = { 0, 0.25, 0, 0.25 } }
local CLS_TEX = "Interface\\TargetingFrame\\UI-Classes-Circles"
local METAL = { { 1, 0.86, 0.45 }, { 0.82, 0.86, 0.92 }, { 0.86, 0.56, 0.29 } }
local function Spaced(s) return (s:upper():gsub("([%z\1-\127\194-\244][\128-\191]*)", "%1 "):gsub(" $", "")) end     -- (letter by letter, whole UTF-8 characters)
local function ClassIcon(t, cls)
    local tc = CLS_ICON[cls] or CLS_ICON.PALADIN
    t:SetTexture(CLS_TEX) t:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
end
local function ClassRGB(cls) local c = CLASSES[cls] and CLASSES[cls].color or { 0.92, 0.88, 0.81 } return c[1], c[2], c[3] end
local function Rect(parent, layer, r, g, b, a, sub)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub or 0)
    t:SetColorTexture(r, g, b, a)
    return t
end
-- a dark panel with a thin gilt edge (the mockup's .frame)
local function Panel(parent, level)
    local f = CreateFrame("Frame", nil, parent)
    if level then f:SetFrameLevel(level) end
    f.bg = Rect(f, "BACKGROUND", 1, 1, 1, 1)
    f.bg:SetAllPoints()
    ns.UI:GradientRGBA(f.bg, "VERTICAL", 10 / 255, 8 / 255, 14 / 255, 0.94, 26 / 255, 20 / 255, 32 / 255, 0.9)
    f.edge = {}
    for i = 1, 4 do f.edge[i] = Rect(f, "BORDER", 93 / 255, 74 / 255, 42 / 255, 1) end
    f.edge[1]:SetPoint("TOPLEFT") f.edge[1]:SetPoint("TOPRIGHT") f.edge[1]:SetHeight(1)
    f.edge[2]:SetPoint("BOTTOMLEFT") f.edge[2]:SetPoint("BOTTOMRIGHT") f.edge[2]:SetHeight(1)
    f.edge[3]:SetPoint("TOPLEFT") f.edge[3]:SetPoint("BOTTOMLEFT") f.edge[3]:SetWidth(1)
    f.edge[4]:SetPoint("TOPRIGHT") f.edge[4]:SetPoint("BOTTOMRIGHT") f.edge[4]:SetWidth(1)
    return f
end
-- a glass pill button (gb), its look kept by :Look()
local function Pill(parent, label, onClick, icon)
    local b = CreateFrame("Button", nil, parent)
    b.bg = Slice3(b, "gb", "BACKGROUND", 0, 15)
    b.label = Words(b, 11)
    if icon then b.icon = b:CreateTexture(nil, "ARTWORK") b.icon:SetSize(16, 16) end
    b:SetScript("OnEnter", function(self) self.hov = true Sound("hover", 0.03) self:Look() end)
    b:SetScript("OnLeave", function(self) self.hov = false self:Look() end)
    b:SetScript("OnClick", function(self) if onClick then onClick(self) end end)
    function b:Set(text, on, h)
        self.on = on and true or false
        self.label:SetText(text)
        local ix = 12
        if self.icon then self.icon:ClearAllPoints() self.icon:SetPoint("LEFT", self, "LEFT", 10, 0) ix = 32 end
        self.label:ClearAllPoints() self.label:SetPoint("LEFT", self, "LEFT", ix, 0)
        local w = floor(ix + (self.label:GetStringWidth() or 40) + 12 + 0.5)
        self:SetSize(w, h or 26)
        self:Look()
        return w
    end
    function b:Look()
        self.bg:SetKit((self.on or self.hov) and "gb_hov" or "gb")
        self.bg:Place(self, 0, 0, self:GetWidth(), self:GetHeight())
        local lit = self.on or self.hov
        self.label:SetTextColor(lit and 1 or 0.85, lit and 0.96 or 0.8, lit and 0.86 or 0.71)
    end
    return b
end
-- a screen of the hall: night, the header's rules, the title and its caption, a Back button
local function HallScreen(title)
    local f = CreateFrame("Frame", nil, stage)
    f:SetAllPoints()
    f.night = Rect(f, "BACKGROUND", 1, 1, 1, 1, -8)
    f.night:SetAllPoints()
    ns.UI:GradientRGBA(f.night, "VERTICAL", 4 / 255, 3 / 255, 7 / 255, 0.97, 14 / 255, 10 / 255, 20 / 255, 0.9)
    f.head = KitTex(f, "hd_frame", "BACKGROUND", 1)
    f.title = Words(f, 32, MORPHEUS) f.title:SetText(title) f.title:SetTextColor(1, 0.86, 0.45) f.title:SetShadowOffset(0, -2)
    f.sub = Words(f, 10) f.sub:SetTextColor(234 / 255, 219 / 255, 189 / 255)
    f.back = Pill(f, "Back", function() ShowTitle() end)
    f:Hide()
    return f
end
local function LayoutHead(f, sub)
    KitAt(f.head, f, OV_W / 2 - 260, 2, 520, 112)
    f.title:ClearAllPoints() f.title:SetPoint("TOP", f, "TOPLEFT", OV_W / 2, -26)
    f.sub:SetText(Spaced(sub))
    f.sub:ClearAllPoints() f.sub:SetPoint("TOP", f, "TOPLEFT", OV_W / 2, -94)
    f.back:Set("Back", false, 28)
    f.back:ClearAllPoints() f.back:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -22)
end
-- a tab down the left: icon, label, a small note on the right
local function Tab(parent, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(196, 36)
    b.bg = Rect(b, "BACKGROUND", 1, 1, 1, 0.03) b.bg:SetAllPoints()
    b.edge = {}
    for i = 1, 4 do b.edge[i] = Rect(b, "BORDER", 46 / 255, 38 / 255, 54 / 255, 1) end
    b.edge[1]:SetPoint("TOPLEFT") b.edge[1]:SetPoint("TOPRIGHT") b.edge[1]:SetHeight(1)
    b.edge[2]:SetPoint("BOTTOMLEFT") b.edge[2]:SetPoint("BOTTOMRIGHT") b.edge[2]:SetHeight(1)
    b.edge[3]:SetPoint("TOPLEFT") b.edge[3]:SetPoint("BOTTOMLEFT") b.edge[3]:SetWidth(1)
    b.edge[4]:SetPoint("TOPRIGHT") b.edge[4]:SetPoint("BOTTOMRIGHT") b.edge[4]:SetWidth(1)
    b.icon = b:CreateTexture(nil, "ARTWORK") b.icon:SetSize(24, 24) b.icon:SetPoint("LEFT", 8, 0)
    b.label = Words(b, 12) b.label:SetPoint("LEFT", b.icon, "RIGHT", 9, 0)
    b.note = Words(b, 9) b.note:SetPoint("RIGHT", b, "RIGHT", -10, 0) b.note:SetTextColor(110 / 255, 100 / 255, 118 / 255)
    b:SetScript("OnEnter", function(self) self.hov = true self:Look() end)
    b:SetScript("OnLeave", function(self) self.hov = false self:Look() end)
    b:SetScript("OnClick", function(self) Sound("hover", 0.03) onClick(self) end)
    function b:Look()
        local on = self.on
        -- the note on the right only when the label leaves room for it
        local room = 196 - 41 - 10 - (self.note:GetStringWidth() or 0) - 10
        self.note:SetShown((self.label:GetStringWidth() or 0) <= room)
        self.bg:SetColorTexture(1, 0.81, 0.42, on and 0.12 or (self.hov and 0.06 or 0.03))
        for _, e in ipairs(self.edge) do e:SetColorTexture(on and 0.95 or 0.18, on and 0.81 or 0.15, on and 0.48 or 0.21, 1) end
        self.label:SetTextColor(on and 1 or 0.66, on and 0.96 or 0.61, on and 0.86 or 0.69)
    end
    return b
end

-- the toast: an achievement earned mid-run (or anywhere), sliding up at the bottom, three seconds
local toast
local function BuildToast()
    local f = CreateFrame("Frame", nil, ov)
    f:SetFrameLevel(ov:GetFrameLevel() + 40)
    f:SetSize(380, 74)
    f.bg = Rect(f, "BACKGROUND", 1, 1, 1, 1) f.bg:SetAllPoints()
    ns.UI:GradientRGBA(f.bg, "VERTICAL", 18 / 255, 12 / 255, 6 / 255, 0.97, 42 / 255, 29 / 255, 12 / 255, 0.97)
    for i = 1, 4 do
        local e = Rect(f, "BORDER", 226 / 255, 182 / 255, 90 / 255, 1)
        if i == 1 then e:SetPoint("TOPLEFT") e:SetPoint("TOPRIGHT") e:SetHeight(2)
        elseif i == 2 then e:SetPoint("BOTTOMLEFT") e:SetPoint("BOTTOMRIGHT") e:SetHeight(2)
        elseif i == 3 then e:SetPoint("TOPLEFT") e:SetPoint("BOTTOMLEFT") e:SetWidth(2)
        else e:SetPoint("TOPRIGHT") e:SetPoint("BOTTOMRIGHT") e:SetWidth(2) end
    end
    f.glow = f:CreateTexture(nil, "BACKGROUND", nil, -1) f.glow:SetTexture(D.MEDIA .. "UI\\glow") f.glow:SetBlendMode("ADD")
    f.glow:SetVertexColor(1, 0.75, 0.3, 0.5) f.glow:SetPoint("CENTER") f.glow:SetSize(520, 200)
    f.icon = f:CreateTexture(nil, "ARTWORK") f.icon:SetSize(50, 50) f.icon:SetPoint("LEFT", 14, 0) f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.eb = Words(f, 9) f.eb:SetText(Spaced("Achievement earned")) f.eb:SetTextColor(230 / 255, 192 / 255, 106 / 255)
    f.eb:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 12, -6)
    f.name = Words(f, 20, MORPHEUS) f.name:SetTextColor(1, 0.95, 0.81) f.name:SetPoint("TOPLEFT", f.eb, "BOTTOMLEFT", 0, -4)
    f.sh = KitTex(f, "sh_gold_10", "ARTWORK", 2)
    f:Hide()
    return f
end
local function ShowToast(id)
    local a = D.ACH[id]
    if not a or not toast then return end
    toast.icon:SetTexture(Icon(a.icon))
    toast.name:SetText(a.name)
    FitLine(toast.name, MORPHEUS, 20, 12, 230)
    KitSet(toast.sh, a.feat and "sh_feat" or ("sh_gold_" .. a.pts))
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
    local W = root:GetWidth() or 786
    toast:SetScale(sk)
    toast:ClearAllPoints()
    toast:SetPoint("BOTTOM", ov, "BOTTOMLEFT", W / 2 / sk, (16 + (1 - k) * -40) / 1)
    toast:SetAlpha(k)
    KitAt(toast.sh, toast, 380 - 14 - 46, 11, 46, 52)
    if t > 3.55 then toast:Hide() end
end
UI._TickToast = TickToast

---------------------------------------------------------------------------
-- the leaderboard
---------------------------------------------------------------------------
local BOARDS = {
    { "time", "Longest held", "spell_holy_holybolt", "time" },
    { "kills", "Most slain", "inv_misc_bone_humanskull_01", "one run" },
    { "level", "Highest level", "spell_holy_championsbond", "one run" },
    { "gold", "Gold carried home", "inv_misc_coin_02", "week" },
    { "points", "Achievement points", "spell_holy_avenginewrath", "points" },
    { "rep", "Argent Dawn", "inv_misc_token_argentdawn3", "reputation" },
}
local lbState = { kind = "time", period = "week", cls = nil }
local LB_X, LB_R = 236, 286
local function BoardValue(kind, row)
    if kind == "time" then return Rd.Clock(floor(row.v / 1000000)) end
    if kind == "challenge" then return Rd.Clock(floor(row.v / 1000000)) end
    return BreakUpLargeNumbers and BreakUpLargeNumbers(row.v) or tostring(row.v)
end
local function BoardSub(kind, row)
    local b = row.b
    if kind == "gold" or kind == "rep" or kind == "points" then return row.e.ti or "" end
    if not b then return "" end
    return string.format("Level %d \194\183 %s slain", b.l or 0, BreakUpLargeNumbers and BreakUpLargeNumbers(b.k or 0) or tostring(b.k or 0))
end

local function BuildBoard()
    local f = HallScreen("Hall of the Line")
    f.tabs = {}
    for i, def in ipairs(BOARDS) do
        local t = Tab(f, function() lbState.kind = def[1] UI.ShowBoard() end)
        t.icon:SetTexture(Icon(def[3])) t.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        t.label:SetText(def[2]) t.note:SetText(def[4])
        t.kind = def[1]
        t:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -(112 + (i - 1) * 42))
        f.tabs[i] = t
    end
    f.period = {
        Pill(f, "This week", function() lbState.period = "week" UI.ShowBoard() end),
        Pill(f, "All time", function() lbState.period = "all" UI.ShowBoard() end),
    }
    f.clsb = {}
    for i, c in ipairs({ false, "PALADIN", "MAGE", "WARRIOR" }) do
        local b = Pill(f, nil, function() lbState.cls = c or nil UI.ShowBoard() end, c and true)
        if c then ClassIcon(b.icon, c) end
        b.cls = c
        f.clsb[i] = b
    end
    -- the podium: three places, each a hero on a pool of light, its medal, name, value
    f.pods = {}
    for i = 1, 3 do
        local p = CreateFrame("Frame", nil, f)
        p.pool = p:CreateTexture(nil, "BACKGROUND", nil, 2) p.pool:SetTexture(D.MEDIA .. "UI\\glow") p.pool:SetBlendMode("ADD")
        p.shadow = p:CreateTexture(nil, "BACKGROUND", nil, 3) p.shadow:SetTexture(D.MEDIA .. "UI\\shadow")
        p.hero = p:CreateTexture(nil, "ARTWORK", nil, 1)
        p.medal = KitTex(p, "md_" .. i, "ARTWORK", 3)
        p.name = Words(p, 18, MORPHEUS)
        p.v = Words(p, i == 1 and 38 or 30, MORPHEUS) p.v:SetShadowOffset(0, -2)
        p.sub = Words(p, 10) p.sub:SetTextColor(MUTE[1], MUTE[2], MUTE[3])
        p.rule = p:CreateTexture(nil, "ARTWORK") p.rule:SetColorTexture(1, 1, 1, 1)
        f.pods[i] = p
    end
    f.beam = f:CreateTexture(nil, "BACKGROUND", nil, 1) f.beam:SetTexture(D.MEDIA .. "UI\\glow") f.beam:SetBlendMode("ADD")
    f.rows = {}
    for i = 1, 5 do
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(OV_W - LB_X - LB_R, 31)
        r.bg = Rect(r, "BACKGROUND", 1, 1, 1, 0.025) r.bg:SetAllPoints()
        r.rk = Words(r, 16, MORPHEUS) r.rk:SetPoint("CENTER", r, "LEFT", 22, 0)
        r.ic = r:CreateTexture(nil, "ARTWORK") r.ic:SetSize(20, 20) r.ic:SetPoint("LEFT", 44, 0)
        r.name = Words(r, 13) r.name:SetPoint("LEFT", r.ic, "RIGHT", 8, 0)
        r.you = Words(r, 9) r.you:SetPoint("LEFT", r.name, "RIGHT", 8, 0) r.you:SetTextColor(110 / 255, 100 / 255, 118 / 255)
        r.sub = Words(r, 11) r.sub:SetPoint("RIGHT", r, "RIGHT", -90, 0) r.sub:SetTextColor(MUTE[1], MUTE[2], MUTE[3])
        r.v = Words(r, 18, MORPHEUS) r.v:SetPoint("RIGHT", r, "RIGHT", -12, 0) r.v:SetTextColor(1, 1, 1)
        f.rows[i] = r
    end
    f.empty = Words(f, 13) f.empty:SetTextColor(MUTE[1], MUTE[2], MUTE[3]) f.empty:SetWidth(520)
    -- the week's challenge
    local c = Panel(f)
    c.eb = Words(c, 9) c.eb:SetText(Spaced("Weekly challenge")) c.eb:SetTextColor(166 / 255, 216 / 255, 115 / 255) c.eb:SetPoint("TOPLEFT", 16, -16)
    c.name = Words(c, 22, MORPHEUS) c.name:SetPoint("TOPLEFT", c.eb, "BOTTOMLEFT", 0, -6) c.name:SetWidth(216) c.name:SetJustifyH("LEFT")
    c.desc = Words(c, 11) c.desc:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -6) c.desc:SetWidth(216) c.desc:SetJustifyH("LEFT") c.desc:SetSpacing(2)
    c.desc:SetTextColor(MUTE[1], MUTE[2], MUTE[3])
    c.clock = {}
    for i, l in ipairs({ "DAYS", "HOURS", "MIN" }) do
        local box = CreateFrame("Frame", nil, c) box:SetSize(66, 40)
        box.bg = Rect(box, "BACKGROUND", 0, 0, 0, 0.45) box.bg:SetAllPoints()
        box.v = Words(box, 18, MORPHEUS) box.v:SetPoint("TOP", 0, -4) box.v:SetTextColor(1, 1, 1)
        box.l = Words(box, 8) box.l:SetPoint("BOTTOM", 0, 4) box.l:SetText(l) box.l:SetTextColor(110 / 255, 100 / 255, 118 / 255)
        c.clock[i] = box
    end
    c.mini = {}
    for i = 1, 3 do
        local m = { ic = c:CreateTexture(nil, "ARTWORK"), name = Words(c, 12), v = Words(c, 15, MORPHEUS) }
        m.ic:SetSize(18, 18) m.v:SetTextColor(1, 1, 1)
        c.mini[i] = m
    end
    c.reward = Words(c, 11) c.reward:SetWidth(176) c.reward:SetJustifyH("LEFT") c.reward:SetSpacing(2)
    c.rewardIcon = c:CreateTexture(nil, "ARTWORK") c.rewardIcon:SetSize(30, 30) c.rewardIcon:SetTexture(Icon("inv_misc_token_argentdawn2"))
    c.go = Pill(c, "Take the challenge", function() UI.StartChallenge() end)
    f.chal = c
    return f
end

function UI.ShowBoard()
    overlay = "board"
    ClearOv()
    local f, S = ov.board, ns.HTLSocial
    f:Show()
    if S then S:Settle() S:Ask() end
    LayoutHead(f, "Casual Disaster \194\183 week of " .. (S and S:Week() or ""))
    for _, t in ipairs(f.tabs) do t.on = t.kind == lbState.kind t:Look() end
    -- period + class filters
    local x = LB_X
    f.period[1]:Set("This week", lbState.period == "week") f.period[2]:Set("All time", lbState.period == "all")
    for _, b in ipairs(f.period) do b:ClearAllPoints() b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -112) x = x + b:GetWidth() + 6 end
    local names = { "All", "Paladin", "Mage", "Warrior" }
    local wsum = 0
    for i, b in ipairs(f.clsb) do wsum = wsum + b:Set(names[i], (b.cls or nil) == lbState.cls) + 6 end
    x = OV_W - LB_R - wsum + 6
    for _, b in ipairs(f.clsb) do b:ClearAllPoints() b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -112) x = x + b:GetWidth() + 6 end
    local list = S and S:Board(lbState.kind, lbState.period, lbState.cls) or {}
    -- the podium: 2, 1, 3 left to right; first a step up, in a light from above
    local colW = (OV_W - LB_X - LB_R - 20) / 3
    local order = { 2, 1, 3 }
    for slot, place in ipairs(order) do
        local p, row = f.pods[place], list[place]
        p:SetShown(row ~= nil)
        if row then
            local cx = LB_X + (slot - 1) * (colW + 10) + colW / 2
            local lift = place == 1 and 30 or place == 2 and 10 or 0
            local feet = 262 - lift                        -- the heroes' feet
            local m = METAL[place]
            local key = CLASSES[row.cls or "PALADIN"].sprite
            local pg, fx, fy, fw, fh, dx, dy = Rd.Frame(key, 2, 0)
            local s = place == 1 and 2.7 or 2.25
            if pg then
                p.hero:SetTexture(pg[1]) p.hero:SetTexCoord(fx / pg[2], (fx + fw) / pg[2], fy / pg[3], (fy + fh) / pg[3])
                p.hero:ClearAllPoints() p.hero:SetPoint("TOPLEFT", f, "TOPLEFT", cx + dx * s, -(feet + dy * s)) p.hero:SetSize(fw * s, fh * s)
            end
            p.pool:ClearAllPoints() p.pool:SetPoint("CENTER", f, "TOPLEFT", cx, -(feet + 2)) p.pool:SetSize(176, 40) p.pool:SetVertexColor(m[1], m[2], m[3], place == 1 and 0.55 or 0.35)
            p.shadow:ClearAllPoints() p.shadow:SetPoint("CENTER", f, "TOPLEFT", cx, -(feet + 1)) p.shadow:SetSize(60, 12) p.shadow:SetVertexColor(1, 1, 1, 0.8)
            local my = feet + 6
            local mw = place == 1 and 46 or 40
            p.medal:ClearAllPoints()
            KitAtK(p.medal, f, cx - mw / 2, my, mw / 48)
            local ty = my + mw * 58 / 48 - 4
            p.name:SetText(row.name) p.name:SetTextColor(ClassRGB(row.cls))
            p.name:ClearAllPoints() p.name:SetPoint("TOP", f, "TOPLEFT", cx, -ty)
            p.v:SetText(BoardValue(lbState.kind, row)) p.v:SetTextColor(m[1], m[2], m[3])
            p.v:ClearAllPoints() p.v:SetPoint("TOP", p.name, "BOTTOM", 0, -1)
            p.sub:SetText(BoardSub(lbState.kind, row))
            p.sub:ClearAllPoints() p.sub:SetPoint("TOP", p.v, "BOTTOM", 0, -2)
            p.rule:ClearAllPoints() p.rule:SetPoint("TOP", p.sub, "BOTTOM", 0, -7) p.rule:SetSize(colW * 0.76, 1)
            ns.UI:GradientRGBA(p.rule, "HORIZONTAL", m[1], m[2], m[3], 0.5, m[1], m[2], m[3], 0.5)
        end
    end
    f.beam:SetShown(list[1] ~= nil)
    f.beam:ClearAllPoints() f.beam:SetPoint("CENTER", f, "TOPLEFT", LB_X + colW + 10 + colW / 2, -200) f.beam:SetSize(260, 300) f.beam:SetVertexColor(1, 0.82, 0.45, 0.35)
    -- the rest: 4.. and you
    local y = 414
    local meIn = false
    for i = 1, 3 do if list[i] and list[i].me then meIn = true end end
    local shown = 0
    for i, r in ipairs(f.rows) do r:Hide() end
    local function Row(r, rank, row)
        r:ClearAllPoints() r:SetPoint("TOPLEFT", f, "TOPLEFT", LB_X, -y)
        r.rk:SetText(rank) r.rk:SetTextColor(row.me and 1 or 0.43, row.me and 0.82 or 0.39, row.me and 0.42 or 0.46)
        ClassIcon(r.ic, row.cls or "PALADIN")
        r.name:SetText(row.name) r.name:SetTextColor(ClassRGB(row.cls))
        r.you:SetText(row.me and "you" or "")
        r.sub:SetText(BoardSub(lbState.kind, row))
        r.v:SetText(BoardValue(lbState.kind, row))
        r.bg:SetColorTexture(1, 0.81, 0.42, row.me and 0.12 or 0.025)
        r:Show()
        y = y + 34
    end
    for i = 4, min(#list, 7) do
        if list[i].me then meIn = true end
        shown = shown + 1
        Row(f.rows[shown], i, list[i])
    end
    if not meIn then
        for i = 8, #list do if list[i].me then y = y + 8 shown = shown + 1 Row(f.rows[min(5, shown)], i, list[i]) break end end
    end
    f.empty:SetShown(#list == 0)
    f.empty:SetText("No runs on this board yet. Finish a run and the guild sees it here.")
    f.empty:ClearAllPoints() f.empty:SetPoint("TOP", f, "TOPLEFT", LB_X + (OV_W - LB_X - LB_R) / 2, -260)
    -- the challenge
    local c = f.chal
    local ch = S and S:Challenge()
    c:ClearAllPoints() c:SetPoint("TOPLEFT", f, "TOPLEFT", OV_W - 22 - 248, -112) c:SetSize(248, StageH() - 112 - 22)
    if ch then
        c.name:SetText(ch.name) c.name:SetTextColor(ClassRGB(ch.cls))
        c.desc:SetText(ch.desc)
        local left = S:WeekLeft()
        local vals = { floor(left / 86400), floor(left % 86400 / 3600), floor(left % 3600 / 60) }
        local cy = 16 + 9 + 6 + 26 + 6 + (c.desc:GetStringHeight() or 40) + 12
        for i, box in ipairs(c.clock) do box:ClearAllPoints() box:SetPoint("TOPLEFT", c, "TOPLEFT", 16 + (i - 1) * 75, -cy) box.v:SetText(vals[i]) end
        cy = cy + 52
        local top = S:Board("challenge", "week")
        for i, m in ipairs(c.mini) do
            local row = top[i]
            m.ic:SetShown(row ~= nil) m.name:SetShown(row ~= nil) m.v:SetShown(row ~= nil)
            if row then
                ClassIcon(m.ic, row.cls)
                m.ic:ClearAllPoints() m.ic:SetPoint("TOPLEFT", c, "TOPLEFT", 16, -(cy + (i - 1) * 24))
                m.name:SetText(row.name) m.name:SetTextColor(ClassRGB(row.cls))
                m.name:ClearAllPoints() m.name:SetPoint("LEFT", m.ic, "RIGHT", 7, 0)
                m.v:SetText(Rd.Clock(floor(row.v / 1000000)))
                m.v:ClearAllPoints() m.v:SetPoint("RIGHT", c, "TOPLEFT", 232, -(cy + (i - 1) * 24 + 9))
            end
        end
        cy = cy + (#top > 0 and min(3, #top) * 24 + 10 or 0)
        c.rewardIcon:ClearAllPoints() c.rewardIcon:SetPoint("TOPLEFT", c, "TOPLEFT", 16, -cy)
        c.reward:SetText("Winner: |cffa6d873+" .. D.CHALLENGE_REP .. " Argent Dawn|r and the title |cfff4cf6a" .. D.CHALLENGE_TITLE .. "|r until next week.")
        c.reward:ClearAllPoints() c.reward:SetPoint("TOPLEFT", c.rewardIcon, "TOPRIGHT", 9, 0)
        local gw = c.go:Set("Take the challenge", true, 30)
        c.go:ClearAllPoints() c.go:SetPoint("TOPLEFT", c, "TOPLEFT", 124 - gw / 2, -(cy + 48))
    end
end

---------------------------------------------------------------------------
-- achievements
---------------------------------------------------------------------------
local achCat = nil
local function BuildAch()
    local f = HallScreen("Deeds of the Line")
    f.tabs = {}
    local cats = { { id = false, name = "Summary", icon = "spell_holy_championsbond" } }
    for _, c in ipairs(D.ACH_CATS) do cats[#cats + 1] = c end
    for i, c in ipairs(cats) do
        local t = Tab(f, function() achCat = c.id or nil UI.ShowAch() end)
        t.icon:SetTexture(Icon(c.icon)) t.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        t.label:SetText(c.name) t.cat = c.id
        t:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -(112 + (i - 1) * 42))
        f.tabs[i] = t
    end
    f.big = KitTex(f, "sh_big", "ARTWORK", 1)
    f.digits = {}
    for i = 1, 4 do f.digits[i] = KitTex(f, "shd_0", "ARTWORK", 3) end
    f.ptsL = Words(f, 26, MORPHEUS) f.ptsL:SetTextColor(1, 1, 1)
    f.ptsS = Words(f, 9) f.ptsS:SetTextColor(MUTE[1], MUTE[2], MUTE[3])
    f.barBg = Rect(f, "ARTWORK", 0, 0, 0, 0.6)
    f.bar = Rect(f, "ARTWORK", 1, 1, 1, 1, 1)
    ns.UI:GradientRGBA(f.bar, "VERTICAL", 0.25, 0.54, 0.16, 1, 0.65, 0.91, 0.42, 1)
    f.barL = Words(f, 11) f.barL:SetTextColor(MUTE[1], MUTE[2], MUTE[3])
    f.cards = {}
    for i = 1, 8 do
        local c = Panel(f)
        c:SetSize(0, 62)
        c.icon = c:CreateTexture(nil, "ARTWORK") c.icon:SetSize(42, 42) c.icon:SetPoint("LEFT", 11, 0) c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        c.name = Words(c, 16, MORPHEUS) c.name:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 11, 1) c.name:SetJustifyH("LEFT")
        c.desc = Words(c, 11) c.desc:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -2) c.desc:SetJustifyH("LEFT") c.desc:SetTextColor(216 / 255, 204 / 255, 178 / 255)
        c.note = Words(c, 10) c.note:SetJustifyH("LEFT") c.note:SetTextColor(110 / 255, 100 / 255, 118 / 255)
        c.pbg = Rect(c, "ARTWORK", 0, 0, 0, 0.6) c.pbar = Rect(c, "ARTWORK", 1, 1, 1, 1, 1)
        ns.UI:GradientRGBA(c.pbar, "VERTICAL", 0.25, 0.54, 0.16, 1, 0.65, 0.91, 0.42, 1)
        c.sh = KitTex(c, "sh_gold_10", "ARTWORK", 2)
        c.first = KitTex(c, "c2_new", "ARTWORK", 3)
        c.firstL = Words(c, 8, nil, "OVERLAY") c.firstL:SetText("G U I L D   F I R S T") c.firstL:SetTextColor(42 / 255, 22 / 255, 0) c.firstL:SetShadowColor(0, 0, 0, 0)
        f.cards[i] = c
    end
    return f
end
local function SetPoints(f, n, x, y)
    local s = tostring(n)
    local ws, tot = {}, 0
    local k = #s > 3 and 0.62 or 0.72
    for i = 1, #s do local e = K["shd_" .. s:sub(i, i)] ws[i] = (e[6] - 2 * e[8]) * k tot = tot + ws[i] - 1 end
    local dx = x - tot / 2
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
    local have, all = 0, 0
    local got, total = 0, #D.ACHIEVEMENTS
    if S then have, all = S:Points() got, total = S:Count() end
    local firsts = 0
    if S then for _, v in pairs(S.Data().firsts) do if ns.Util.IsMe(v.who) then firsts = firsts + 1 end end end
    LayoutHead(f, got .. " of " .. total .. " earned \194\183 " .. firsts .. " guild first" .. (firsts == 1 and "" or "s"))
    for _, t in ipairs(f.tabs) do t.on = (t.cat or nil) == achCat t:Look() end
    -- the points: a big shield, the number in its lettering, the total beside it
    KitAt(f.big, f, OV_W - 24 - 64, 22, 64, 72)
    SetPoints(f, have, OV_W - 24 - 32, 22 + 18)
    f.ptsL:SetText(BreakUpLargeNumbers and BreakUpLargeNumbers(have) or tostring(have))
    f.ptsL:ClearAllPoints() f.ptsL:SetPoint("TOPRIGHT", f, "TOPLEFT", OV_W - 24 - 64 - 12, -34)
    f.ptsS:SetText(Spaced("of " .. all .. " points"))
    f.ptsS:ClearAllPoints() f.ptsS:SetPoint("TOPRIGHT", f.ptsL, "BOTTOMRIGHT", 0, -2)
    -- progress
    local bw = OV_W - 236 - 22 - 70
    f.barBg:ClearAllPoints() f.barBg:SetPoint("TOPLEFT", f, "TOPLEFT", 236, -118) f.barBg:SetSize(bw, 8)
    f.bar:ClearAllPoints() f.bar:SetPoint("TOPLEFT", f, "TOPLEFT", 236, -118) f.bar:SetSize(max(0.1, bw * got / max(1, total)), 8)
    f.barL:SetText(got .. " / " .. total)
    f.barL:ClearAllPoints() f.barL:SetPoint("LEFT", f.barBg, "RIGHT", 10, 0)
    -- the cards: two columns
    local list = S and S:List(achCat) or {}
    local cw = (OV_W - 236 - 22 - 8) / 2
    for i, c in ipairs(f.cards) do
        local row = list[i]
        c:SetShown(row ~= nil)
        if row then
            local a = row.a
            local col, line = (i - 1) % 2, floor((i - 1) / 2)
            c:ClearAllPoints() c:SetPoint("TOPLEFT", f, "TOPLEFT", 236 + col * (cw + 8), -(140 + line * 70)) c:SetSize(cw, 62)
            c.icon:SetTexture(Icon(a.icon)) c.icon:SetDesaturated(not row.earned)
            c.name:SetText(a.name) c.name:SetWidth(cw - 130) FitLine(c.name, MORPHEUS, 16, 11, cw - 130)
            if a.feat then c.name:SetTextColor(1, 0.57, 0.16) elseif row.earned then c.name:SetTextColor(1, 0.89, 0.6) else c.name:SetTextColor(0.92, 0.88, 0.81) end
            c.desc:SetText(a.desc) c.desc:SetWidth(cw - 130)
            local note
            if row.earned then note = "Earned " .. date("%d %B", row.earned)
            elseif row.first then note = "First in guild: " .. (ns.Util.ShortName(row.first.who) or row.first.who) .. ", " .. date("%d %B", row.first.t)
            elseif row.need then note = (BreakUpLargeNumbers and BreakUpLargeNumbers(row.have or 0) or tostring(row.have or 0)) .. " / " .. (BreakUpLargeNumbers and BreakUpLargeNumbers(row.need) or tostring(row.need))
            else note = "No one in the guild yet" end
            local showBar = not row.earned and row.need and row.need > 1
            c.pbg:SetShown(showBar) c.pbar:SetShown(showBar)
            if showBar then
                c.pbg:ClearAllPoints() c.pbg:SetPoint("TOPLEFT", c.desc, "BOTTOMLEFT", 0, -4) c.pbg:SetSize(cw - 140, 6)
                c.pbar:ClearAllPoints() c.pbar:SetPoint("TOPLEFT", c.pbg, "TOPLEFT") c.pbar:SetSize(max(0.1, (cw - 140) * min(1, (row.have or 0) / row.need)), 6)
                c.note:ClearAllPoints() c.note:SetPoint("TOPLEFT", c.pbg, "BOTTOMLEFT", 0, -2)
            else
                c.note:ClearAllPoints() c.note:SetPoint("TOPLEFT", c.desc, "BOTTOMLEFT", 0, -3)
            end
            c.note:SetText(note)
            KitSet(c.sh, a.feat and "sh_feat" or ((row.earned and "sh_gold_" or "sh_grey_") .. a.pts))
            KitAt(c.sh, c, cw - 12 - 46, 5, 46, 52)
            local mine = row.earned and row.first and ns.Util.IsMe(row.first.who)
            c.first:SetShown(mine and true or false) c.firstL:SetShown(mine and true or false)
            if mine then KitAtK(c.first, c, cw - 64 - 92, 7, 92 / 60) c.firstL:ClearAllPoints() c.firstL:SetPoint("LEFT", c, "TOPLEFT", cw - 64 - 84, -22.5) end
            for _, e in ipairs(c.edge) do
                if a.feat then e:SetColorTexture(1, 0.57, 0.16, 1) elseif row.earned then e:SetColorTexture(106 / 255, 83 / 255, 40 / 255, 1) else e:SetColorTexture(58 / 255, 48 / 255, 66 / 255, 1) end
            end
        end
    end
end

---------------------------------------------------------------------------
-- the Argent Dawn
---------------------------------------------------------------------------
local function BuildDawn()
    local f = HallScreen("The Argent Dawn")
    f.seal = f:CreateTexture(nil, "ARTWORK", nil, 1) f.seal:SetTexture(Icon("inv_misc_token_argentdawn3"))
    f.sealMask = f:CreateMaskTexture() f.sealMask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE") f.sealMask:SetAllPoints(f.seal) f.seal:AddMaskTexture(f.sealMask)
    f.ring = KitTex(f, "c2_ring_uncommon", "ARTWORK", 2)
    f.sealGlow = f:CreateTexture(nil, "BACKGROUND", nil, 2) f.sealGlow:SetTexture(D.MEDIA .. "UI\\glow") f.sealGlow:SetBlendMode("ADD") f.sealGlow:SetVertexColor(0.65, 0.85, 0.45, 0.6)
    f.faction = Words(f, 28, MORPHEUS) f.faction:SetText("Argent Dawn") f.faction:SetTextColor(0.65, 0.85, 0.45)
    f.standing = Words(f, 18, MORPHEUS) f.standing:SetTextColor(1, 0.81, 0.42)
    f.barEdge = Rect(f, "ARTWORK", 93 / 255, 74 / 255, 42 / 255, 1, -1)
    f.barBg = Rect(f, "ARTWORK", 0, 0, 0, 0.75)
    f.bar = Rect(f, "ARTWORK", 1, 1, 1, 1, 1)
    ns.UI:GradientRGBA(f.bar, "VERTICAL", 0.12, 0.42, 0.09, 1, 0.37, 0.76, 0.24, 1)
    f.barL = Words(f, 10, nil, "OVERLAY") f.barL:SetTextColor(1, 1, 1)
    f.next = Words(f, 11) f.next:SetTextColor(MUTE[1], MUTE[2], MUTE[3])
    f.ways = {}
    for i, w in ipairs({ { "spell_holy_holybolt", "Every minute held", "+54" }, { "inv_misc_bone_humanskull_01", "Scourgestones from elites", "+" .. D.STONE_REP .. " each" },
                         { "spell_shadow_deathcoil", "Bosses slain", "+150" }, { "inv_misc_token_argentdawn2", "Weekly challenge win", "+" .. D.CHALLENGE_REP } }) do
        local r = CreateFrame("Frame", nil, f) r:SetSize(300, 30)
        r.bg = Rect(r, "BACKGROUND", 1, 1, 1, 0.03) r.bg:SetAllPoints()
        r.ic = r:CreateTexture(nil, "ARTWORK") r.ic:SetSize(22, 22) r.ic:SetPoint("LEFT", 6, 0) r.ic:SetTexture(Icon(w[1])) r.ic:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.l = Words(r, 11) r.l:SetPoint("LEFT", r.ic, "RIGHT", 8, 0) r.l:SetText(w[2]) r.l:SetTextColor(216 / 255, 204 / 255, 178 / 255)
        r.v = Words(r, 11) r.v:SetPoint("RIGHT", -8, 0) r.v:SetText(w[3]) r.v:SetTextColor(0.65, 0.85, 0.45)
        f.ways[i] = r
    end
    f.rungs = {}
    for i = 2, #D.STANDINGS do
        local st = D.STANDINGS[i]
        local r = { box = Panel(f), cards = {} }
        r.name = Words(r.box, 18, MORPHEUS) r.name:SetPoint("TOPLEFT", 12, -12) r.name:SetText(st.name)
        r.at = Words(r.box, 10) r.at:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -2) r.at:SetTextColor(110 / 255, 100 / 255, 118 / 255)
        for k, rw in ipairs(st.rewards or {}) do
            local c = Panel(f)
            c.icon = c:CreateTexture(nil, "ARTWORK") c.icon:SetSize(40, 40) c.icon:SetPoint("LEFT", 10, 0) c.icon:SetTexture(Icon(rw.icon)) c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            c.tag = Words(c, 8) c.tag:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 9, 2) c.tag:SetTextColor(0.65, 0.85, 0.45)
            c.tag:SetText(Spaced((rw.kind == "stage" and "New stage" or rw.kind == "perk" and "Every run" or rw.kind == "look" and "Look" or "Title") .. (rw.soon and " \194\183 soon" or "")))
            c.name = Words(c, 15, MORPHEUS) c.name:SetPoint("TOPLEFT", c.tag, "BOTTOMLEFT", 0, -2) c.name:SetText(rw.name) c.name:SetJustifyH("LEFT")
            c.desc = Words(c, 10) c.desc:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -1) c.desc:SetText(rw.desc) c.desc:SetJustifyH("LEFT") c.desc:SetTextColor(MUTE[1], MUTE[2], MUTE[3])
            if rw.kind == "look" then
                c.wear = Pill(c, "Wear", function()
                    local d = ns.HTLSocial.Data()
                    d.look[rw.id] = d.look[rw.id] == false and true or false
                    UI.ShowDawn()
                end)
            end
            c.rw = rw
            r.cards[k] = c
        end
        f.rungs[#f.rungs + 1] = r
    end
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
    LayoutHead(f, "Light's Hope Chapel \194\183 quartermaster")
    local cx = 40 + 150
    f.sealGlow:ClearAllPoints() f.sealGlow:SetPoint("CENTER", f, "TOPLEFT", cx, -150) f.sealGlow:SetSize(150, 150)
    f.seal:ClearAllPoints() f.seal:SetPoint("CENTER", f, "TOPLEFT", cx, -150) f.seal:SetSize(62, 62)
    KitAtK(f.ring, f, cx - 34, 150 - 34, 68 / 72)
    f.faction:ClearAllPoints() f.faction:SetPoint("TOP", f, "TOPLEFT", cx, -194)
    f.standing:SetText(cur.name) f.standing:ClearAllPoints() f.standing:SetPoint("TOP", f.faction, "BOTTOM", 0, -2)
    local lo, hi = cur.at, nxt and nxt.at or cur.at
    local k = nxt and min(1, (rep - lo) / max(1, hi - lo)) or 1
    f.barEdge:ClearAllPoints() f.barEdge:SetPoint("TOPLEFT", f, "TOPLEFT", 40, -(254 - 1)) f.barEdge:SetSize(302, 16)
    f.barBg:ClearAllPoints() f.barBg:SetPoint("TOPLEFT", f, "TOPLEFT", 41, -254) f.barBg:SetSize(300, 14)
    f.bar:ClearAllPoints() f.bar:SetPoint("TOPLEFT", f, "TOPLEFT", 41, -254) f.bar:SetSize(max(0.1, 300 * k), 14)
    f.barL:SetText(nxt and ((BreakUpLargeNumbers and BreakUpLargeNumbers(rep - lo) or (rep - lo)) .. " / " .. (BreakUpLargeNumbers and BreakUpLargeNumbers(hi - lo) or (hi - lo))) or "Exalted")
    f.barL:ClearAllPoints() f.barL:SetPoint("CENTER", f.barBg, "CENTER")
    f.next:SetText(nxt and ("Next: |cffebe1cf" .. nxt.name .. "|r") or "The Dawn has nothing more to give.")
    f.next:ClearAllPoints() f.next:SetPoint("TOP", f, "TOPLEFT", cx, -276)
    for i, r in ipairs(f.ways) do r:ClearAllPoints() r:SetPoint("TOPLEFT", f, "TOPLEFT", 40, -(300 + (i - 1) * 34)) end
    -- the ladder
    local x0, cw = 372, (OV_W - 372 - 22 - 120 - 16) / 2
    for i, r in ipairs(f.rungs) do
        local st = D.STANDINGS[i + 1]
        local reached = rep >= st.at
        local here = ci == i + 1
        local y = 112 + (i - 1) * 74
        r.box:ClearAllPoints() r.box:SetPoint("TOPLEFT", f, "TOPLEFT", x0, -y) r.box:SetSize(110, 66)
        r.at:SetText(here and (BreakUpLargeNumbers and BreakUpLargeNumbers(st.at) or st.at) .. " \194\183 you are here" or (BreakUpLargeNumbers and BreakUpLargeNumbers(st.at) or tostring(st.at)))
        r.name:SetTextColor(here and 1 or reached and 0.65 or 0.92, here and 0.81 or reached and 0.85 or 0.88, here and 0.42 or reached and 0.45 or 0.81)
        for _, e in ipairs(r.box.edge) do e:SetColorTexture(here and 0.95 or reached and 0.65 or 0.18, here and 0.81 or reached and 0.85 or 0.15, here and 0.48 or reached and 0.45 or 0.21, 1) end
        for k2, c in ipairs(r.cards) do
            c:ClearAllPoints() c:SetPoint("TOPLEFT", f, "TOPLEFT", x0 + 120 + (k2 - 1) * (cw + 8), -y) c:SetSize(cw, 66)
            c.name:SetWidth(cw - 70) FitLine(c.name, MORPHEUS, 15, 11, cw - (c.wear and 130 or 70))
            c.desc:SetWidth(cw - 70)
            c:SetAlpha(reached and 1 or 0.6)
            c.icon:SetDesaturated(not reached)
            if c.wear then
                local on = reached and d.look[c.rw.id] ~= false
                c.wear:SetShown(reached)
                local w = c.wear:Set(on and "Wearing" or "Hidden", on, 22)
                c.wear:ClearAllPoints() c.wear:SetPoint("TOPRIGHT", c, "TOPRIGHT", -8, -8)
            end
        end
    end
end

-- a run of the week's challenge: its rules, its seed, its board
function UI.StartChallenge()
    local S = ns.HTLSocial
    if not S then return end
    local ch, seed = S:Challenge()
    UI.Start(ch.cls or Class(), { rules = ch, seed = seed, challenge = S:Week() })
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

local function OnUpdate(_, elapsed)
    elapsed = min(elapsed, 0.1)
    if run then
        if run.attract and run.warm then
            local s = min(run.warm, 0.5)
            E.FastForward(run, s, true)
            run.warm = run.warm - s
            if run.warm <= 0 then run.warm, run.fadeIn = nil, 0 end
        elseif run.attract then
            acc = min(acc + elapsed, STEP * 4)
            while acc >= STEP do acc = acc - STEP E.Step(run, STEP, 0, 0) end
            if run.fadeIn then run.fadeIn = run.fadeIn + elapsed view.scaler:SetAlpha(min(1, run.fadeIn / 0.5)) if run.fadeIn >= 0.5 then run.fadeIn = nil end end
            if run.t > 400 then Attract() end
        elseif (focused or overlay) and not run.paused and not run.over then
            acc = min(acc + elapsed, STEP * 4)
            local ix, iy = 0, 0
            if focused then ix, iy = Input() end
            while acc >= STEP do
                acc = acc - STEP
                for _ = 1, run.speed or 1 do E.Step(run, STEP, ix, iy) end
            end
        end
        if overlay == "choosing" then E.StepParts(run, elapsed) end
        if run.wantLevelUp and overlay == nil then run.wantLevelUp = nil OpenLevelUp() end
        if run.chest and overlay == nil then ShowChest() end
        if run.over and overlay ~= "end" and not run.attract then ShowEnd(run.over) end
        Rd.Draw(view, run)
        view.hud:SetShown(not run.attract)
    end
    TickPicker(elapsed)
    TickTitle(elapsed)
    TickTalents(elapsed)
    TickToast(elapsed)
    if run and not run.attract and not run.lab and not run.god and not run.over and ns.HTLSocial then
        UI.achAcc = (UI.achAcc or 0) + elapsed
        if UI.achAcc >= 1 then UI.achAcc = 0 ns.HTLSocial:CheckRun(run, false) end
    end
    TickEnd(elapsed)
    TickChest(elapsed)
    TickPreviews(elapsed)
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
        if overlay == "pause" then ClosePause() pcall(self.SetPropagateKeyboardInput, self, false) return end
        if run and not run.attract and not run.over and overlay == nil then ShowPause() pcall(self.SetPropagateKeyboardInput, self, false) return end
        UI.SetFocus(false)
        pcall(self.SetPropagateKeyboardInput, self, false)
        return
    end
    if not InCombatLockdown() and self.SetPropagateKeyboardInput then pcall(self.SetPropagateKeyboardInput, self, not KEYS[key]) end
    if not KEYS[key] then return end
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
        while self.acc >= STEP do
            self.acc = self.acc - STEP
            if r.lvlT and r.lvlT >= 0 then r.lvlT, r.tsGoal, r.ts = -1, 1, 1 end
            r.wantLevelUp, r.chest, r.pending = nil, nil, 0
            E.Step(r, STEP, 0, 0)
        end
        -- the scene's end: it fades out over its last second, then the next one warms up
        self.fade = min(1, self.fade + elapsed * 1.5)
        local left = 300 - r.t
        self.view.scaler:SetAlpha(min(self.fade, max(0, left)))
        Rd.Draw(self.view, r)
        self.view.hud:Hide()
        if left <= 0 or r.over then Scene() end
    end
    return c
end

-- (tests and the audit)
function UI._Run() return run end
function UI._SetRun(r) run = Hook(r) end
function UI._View() return view end
function UI._Overlay() return overlay end
function UI._Key(key, up) if up then OnKeyUp(root, key) else OnKeyDown(root, key) end end
function UI._Tick(dt) OnUpdate(root, dt) end
function UI._OpenLevelUp(preset) OpenLevelUp(preset) end
function UI._ShowChest() ShowChest() end
function UI._ShowEnd(kind) ShowEnd(kind) end
function UI._ShowTitle() ShowTitle() end
function UI._Previews() return previews end
function UI._Picker() return ov.picker end

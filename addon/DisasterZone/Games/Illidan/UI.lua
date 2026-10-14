if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Illidan/UI.lua", ...) then return end -- DisasterZone Games/Illidan/UI.lua
-- ns.BoIUI: The Binding of Illidan's panel in the Games hub. The room is drawn from the run (ns.BoI) every frame:
-- the raid's floor and wall textures, gilded doors, round tokens for you and the enemies (icons in a ring; bosses
-- are their encounter-journal busts), glowing tears and shots, the bosses' telegraphs, then the HUD (healthstones,
-- soul shards, gold / bombs / keys, items, the minimap, a boss and cast bar, yells and emotes) and the cards (the
-- floor's title, the boss's versus, the end of a run).
--
-- The room is laid out in its own 720 x 432 units in one frame, scaled to fit the stage. Drawing is immediate:
-- every frame takes textures from pools and hides what it did not use.
-- Keys (only while the game has focus, like Azeromon: a click gives it, Esc takes it back and pauses):
-- WASD move, arrow keys shoot, E drops a Goblin Bomb, Space uses your active item, Enter starts, R starts over.
local addonName, ns = ...

local UI = {}
ns.BoIUI = UI

local D, E = ns.BoIData, ns.BoI
local floor, min, max, abs, sin, cos, pi = math.floor, math.min, math.max, math.abs, math.sin, math.cos, math.pi
local W, H = D.W, D.H
local X0, Y0, X1, Y1, CX, CY = E.X0, E.Y0, E.X1, E.Y1, E.CX, E.CY
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local RADIAL = "Interface\\AddOns\\" .. addonName .. "\\Media\\MyBiS\\Radial"
local FONT = "Fonts\\FRIZQT__.TTF"
local CLASS_CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
local STEP = 1 / 60
local GOLD, FELC, WHITE = ns.Style.C.GOLD, { 0.65, 0.94, 0.29 }, { 1, 1, 1 }
local LOADING = { mag = 131846, bt = 131826 }

local root, screen, layers, focusOverlay
local pools = {}
local hud = {}
local run, acc, focused = nil, 0, false
local held = {}            -- keys held now
local shootOrder = {}      -- the shooting keys in the order pressed (the newest wins)
local edge = {}            -- keys pressed since the last step (bomb, use)

local function Game() return ns.BoIGame end
local function Board() return ns.BoIBoard end

---------------------------------------------------------------------------
-- Pools
---------------------------------------------------------------------------

local function NewPool(frame, kind, layer, sub, blend, file)
    return { frame = frame, kind = kind, layer = layer, sub = sub, blend = blend, file = file, items = {}, n = 0 }
end

local function Take(pool)
    pool.n = pool.n + 1
    local t = pool.items[pool.n]
    if not t then
        if pool.kind == "line" then
            t = pool.frame:CreateLine(nil, pool.layer, nil, pool.sub)
        else
            t = pool.frame:CreateTexture(nil, pool.layer, nil, pool.sub)
            if pool.file then t:SetTexture(pool.file) end
            if pool.blend then t:SetBlendMode(pool.blend) end
        end
        pool.items[pool.n] = t
    end
    t:Show()
    return t
end

local function Begin() for _, p in pairs(pools) do p.n = 0 end end
local function Finish()
    for _, p in pairs(pools) do
        for i = p.n + 1, #p.items do
            local t = p.items[i]
            if p.kind == "token" then t.Hide() else t:Hide() end
        end
    end
end

local function Place(t, x, y, w, h)
    t:ClearAllPoints()
    t:SetPoint("CENTER", screen, "TOPLEFT", x, -y)
    t:SetSize(max(0.1, w), max(0.1, h or w))
end

local function Glow(pool, x, y, r, c, a)
    local t = Take(pools[pool])
    t:SetVertexColor(c[1], c[2], c[3], a or 1)
    Place(t, x, y, r * 2)
    return t
end

local function Disc(pool, x, y, r, c, a, w, h)
    local t = Take(pools[pool])
    t:SetVertexColor(c[1], c[2], c[3], a or 1)
    Place(t, x, y, w or r * 2, h or r * 2)
    return t
end

local function Icon(pool, file, x, y, s, a, crop)
    local t = Take(pools[pool])
    if t.file ~= file then t:SetTexture(file) t.file = file end
    if crop == false then t:SetTexCoord(0, 1, 0, 1) else t:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    t:SetVertexColor(1, 1, 1, a or 1)
    Place(t, x, y, s, s)
    return t
end

local function Rect(pool, x, y, w, h, c, a)
    local t = Take(pools[pool])
    t:SetColorTexture(c[1], c[2], c[3], a or 1)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", screen, "TOPLEFT", x, -y)
    t:SetSize(max(0.1, w), max(0.1, h))
    return t
end

local function Line(pool, x1, y1, x2, y2, thick, c, a)
    local l = Take(pools[pool])
    l:SetColorTexture(c[1], c[2], c[3], a or 1)
    l:SetStartPoint("TOPLEFT", screen, x1, -y1)
    l:SetEndPoint("TOPLEFT", screen, x2, -y2)
    l:SetThickness(thick)
    return l
end

-- a round token: shadow, a ring in `ring`, a black rim, the picture (an icon, a class circle or an EJ bust)
local function NewToken(frame)
    local o = { kind = "token" }
    o.shadow = frame:CreateTexture(nil, "ARTWORK", nil, 0)
    o.shadow:SetTexture(CIRCLE)
    o.shadow:SetVertexColor(0, 0, 0, 0.45)
    o.ring = frame:CreateTexture(nil, "ARTWORK", nil, 1)
    o.ring:SetTexture(CIRCLE)
    o.rim = frame:CreateTexture(nil, "ARTWORK", nil, 2)
    o.rim:SetTexture(CIRCLE)
    o.rim:SetVertexColor(0, 0, 0, 1)
    o.bg = frame:CreateTexture(nil, "ARTWORK", nil, 3)
    o.bg:SetTexture(CIRCLE)
    o.bg:SetVertexColor(0.13, 0.08, 0.06, 1)
    o.pic = frame:CreateTexture(nil, "ARTWORK", nil, 4)
    o.mask = frame:CreateMaskTexture()
    o.mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    o.pic:AddMaskTexture(o.mask)
    o.flash = frame:CreateTexture(nil, "ARTWORK", nil, 5)
    o.flash:SetTexture(CIRCLE)
    function o.Show() for _, k in ipairs({ "shadow", "ring", "rim", "bg", "pic", "flash" }) do o[k]:Show() end end
    function o.Hide() for _, k in ipairs({ "shadow", "ring", "rim", "bg", "pic", "flash" }) do o[k]:Hide() end end
    return o
end

-- pic: an icon path / FileDataID; opts = { ej = true (a 128 x 64 bust), cls = "MAGE" (a class circle), flash, alpha,
-- shadow = false, lift (px the token floats above its shadow) }
local function Token(x, y, r, pic, ring, opts)
    opts = opts or {}
    local pool = pools.token
    pool.n = pool.n + 1
    local o = pool.items[pool.n]
    if not o then o = NewToken(pool.frame) pool.items[pool.n] = o end
    o.Show()
    local a, lift = opts.alpha or 1, opts.lift or 0
    if opts.shadow == false then o.shadow:Hide() else Place(o.shadow, x, y + r * 0.85, r * 1.8, r * 0.64) end
    o.ring:SetVertexColor(ring[1], ring[2], ring[3], a)
    Place(o.ring, x, y - lift, r * 2 + 5)
    o.rim:SetAlpha(a)
    Place(o.rim, x, y - lift, r * 2 + 2)
    o.bg:SetAlpha(a)
    Place(o.bg, x, y - lift, r * 2)
    if o.file ~= pic then o.pic:SetTexture(pic) o.file = pic end
    if opts.cls and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[opts.cls] then
        local c = CLASS_ICON_TCOORDS[opts.cls]
        o.pic:SetTexCoord(c[1] + 0.02, c[2] - 0.02, c[3] + 0.02, c[4] - 0.02)
        Place(o.pic, x, y - lift, r * 2)
    elseif opts.ej then
        o.pic:SetTexCoord(22 / 128, 106 / 128, 0, 1)
        o.pic:ClearAllPoints()
        o.pic:SetPoint("CENTER", screen, "TOPLEFT", x, -(y - lift) + r * 0.1)
        o.pic:SetSize(r * 2.5, r * 2.5 * 64 / 84)
    else
        o.pic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        Place(o.pic, x, y - lift, r * 2)
    end
    o.pic:SetAlpha(a)
    Place(o.mask, x, y - lift, r * 2)
    o.flash:SetVertexColor(1, 1, 1, opts.flash or 0)
    Place(o.flash, x, y - lift, r * 2)
    return o
end

local function Label(key, parent, size, x, y, text, c, a, justify)
    local fs = hud[key]
    if not fs then
        fs = parent:CreateFontString(nil, "OVERLAY")
        fs:SetFont(FONT, size, "OUTLINE")
        fs:SetShadowOffset(1, -1)
        hud[key] = fs
    end
    fs:ClearAllPoints()
    local j = justify or "CENTER"
    fs:SetJustifyH(j)
    fs:SetPoint(j == "LEFT" and "LEFT" or j == "RIGHT" and "RIGHT" or "CENTER", screen, "TOPLEFT", x, -y)
    fs:SetText(text or "")
    c = c or WHITE
    fs:SetTextColor(c[1], c[2], c[3], a or 1)
    fs:Show()
    hud.used[key] = true
    return fs
end

local function ClassColor(cls)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
    return c and { c.r, c.g, c.b } or WHITE
end

---------------------------------------------------------------------------
-- The room
---------------------------------------------------------------------------

local DOOR_COORDS = {   -- the door picture turned so its top faces out of the room (UL, LL, UR, LR)
    up = { 0, 0, 0, 1, 1, 0, 1, 1 }, down = { 1, 1, 1, 0, 0, 1, 0, 0 },
    left = { 1, 0, 0, 0, 1, 1, 0, 1 }, right = { 0, 1, 1, 1, 0, 0, 1, 0 },
}

local function DrawStatic()
    local F = run.F
    local k = F.floorK or 0.5
    local fl = layers.floorTex
    if fl.fid ~= F.floor then
        fl:SetTexture(F.floor, "REPEAT", "REPEAT")
        fl.fid = F.floor
        for _, w in ipairs(layers.walls) do w:SetTexture(F.wall, "REPEAT", "REPEAT") end
    end
    fl:SetVertexColor(k, k, k)
    layers.tint:SetColorTexture(F.tint[1], F.tint[2], F.tint[3], F.tint[4])
end

local function DrawDoors()
    for _, d in ipairs(E.Doors(run)) do
        local x, y = E.DOOR[d.dir][1], E.DOOR[d.dir][2]
        local vert = d.dir == "left" or d.dir == "right"
        local ox, oy = (d.dir == "left" and -20) or (d.dir == "right" and 20) or 0, (d.dir == "up" and -20) or (d.dir == "down" and 20) or 0
        Rect("floorRect", x + ox - (vert and 20 or 26), y + oy - (vert and 26 or 20), vert and 40 or 52, vert and 52 or 40,
            d.open and { 0.02, 0.015, 0.01 } or { 0.1, 0.08, 0.06 }, 1)
        if d.open then
            local c = d.kind == "boss" and { 1, 0.16, 0.12 } or d.kind == "treasure" and GOLD or d.kind == "shop" and { 0.4, 0.85, 1 }
                or { 1, 1, 1 }
            Glow("floorGlow", x + ox * 0.5, y + oy * 0.5, 34, c, d.kind == "normal" and 0.08 or 0.35)
        end
        local t = Take(pools.door)
        t:SetTexCoord(unpack(DOOR_COORDS[d.dir]))
        Place(t, x + ox * 0.6, y + oy * 0.6, vert and 52 or 72, vert and 72 or 52)
        if not d.open and not d.locked then
            for i = -2, 2 do
                Rect("doorBar", vert and (x + ox - 18) or (x + ox + i * 9 - 2), vert and (y + oy + i * 9 - 2) or (y + oy - 18),
                    vert and 36 or 4, vert and 4 or 36, { 0.08, 0.06, 0.05 }, 0.9)
            end
        end
        if d.locked then Icon("fx", D.icon("INV_Misc_Key_10"), x + ox * 0.4, y + oy * 0.4, 22) end
        if d.kind == "boss" then Icon("fx", D.SKULL, x + ox * 1.6, y + oy * 1.6, 20, 0.9, false) end
    end
end

local function DrawFloorThings()
    local room = run.room
    -- the controls, painted on the first room's floor
    if room.type == "start" and run.floorN == 1 then
        local c = { 0.85, 0.81, 0.75 }
        Label("ctrl1", layers.low, 20, CX - 130, CY - 8, "W A S D", c, 0.45)
        Label("ctrl2", layers.low, 13, CX - 130, CY + 16, "move", c, 0.45)
        Label("ctrl3", layers.low, 20, CX + 130, CY - 8, "Arrow keys", c, 0.45)
        Label("ctrl4", layers.low, 13, CX + 130, CY + 16, "shoot", c, 0.45)
        Label("ctrl5", layers.low, 13, CX, CY + 70, "E  bomb      Space  item      Esc  pause", c, 0.45)
    end
    for _, q in ipairs(run.patches) do
        local a = min(1, q.life / 60)
        Glow("lowGlow", q.x, q.y, q.r * 1.6, q.col, 0.5 * a)
        Glow("lowGlow", q.x, q.y - 2, q.r * 0.8, q.col, 0.7 * a)
    end
    for _, fi in ipairs(run.fires) do
        local a = min(1, fi.life / 30)
        Glow("lowGlow", fi.x, fi.y, 22, { 1, 0.47, 0.12 }, 0.75 * a)
        Glow("lowGlow", fi.x, fi.y - 3, 10, { 1, 0.9, 0.47 }, 0.9 * a)
    end
    if run.cubes then
        for _, c in ipairs(run.cubes) do
            if run.cast and c.ex == 0 then Glow("lowGlow", c.x, c.y, 40, { 0.67, 0.43, 1 }, 0.5) end
            local t = Take(pools.pedestal)
            t:SetVertexColor(1, 1, 1, c.ex > 0 and 0.3 or 1)
            Place(t, c.x, c.y, 34)
            if c.hold > 0 then Disc("lowDisc", c.x, c.y, 24 * c.hold / 55, { 0.78, 0.6, 1 }, 0.35) end
        end
    end
    for _, t in ipairs(run.traps) do
        Token(t.x, t.y, 13, D.SPELL.prison, t.forBoss and FELC or { 0.48, 0.24, 1 }, { alpha = t.arm > 0 and 0.45 or 1, shadow = false })
    end
    if run.glaives then
        for _, b in ipairs(run.glaives) do
            Disc("lowDisc", b.x, b.y, 220, FELC, 0.04)
            Glow("lowGlow", b.x, b.y, 30, FELC, 0.35)
            Token(b.x, b.y, 13, D.ITEMS.glaive.i, { 0.49, 1, 0.23 })
        end
    end
    for _, v in ipairs(run.volcs) do
        Glow("lowGlow", v.x, v.y, 34, { 1, 0.43, 0.12 }, 0.6)
        Token(v.x, v.y, 14, D.SPELL.geyser, { 1, 0.35, 0.1 }, { shadow = false })
    end
    for _, h in ipairs(run.hz) do
        local k = h.t / h.delay
        Disc("lowDisc", h.x, h.y, h.r, h.col, 0.16)
        Disc("lowDisc", h.x, h.y, h.r * k, h.col, 0.18 + 0.3 * k)
    end
    if run.beam and run.beam.t <= run.beam.warn then
        local b = run.beam
        Line("lowLine", b.ax, b.ay, b.bx, b.by, 3, FELC, 0.6 + 0.3 * sin(run.frame * 0.4))
    end
    for _, b in ipairs(run.beams) do
        if b.t < b.warn then Line("lowLine", b.ax, b.ay, b.bx, b.by, 2, b.col, 0.4 + 0.4 * b.t / b.warn) end
    end
    local f = run.bossF
    if f and f.swing then   -- the swing's cone: three discs in front, filling
        local k = min(1, f.swing.t / 32)
        for i, s in ipairs({ { 30, 26 }, { 58, 34 }, { 86, 40 } }) do
            Disc("lowDisc", f.x + cos(f.swing.a) * (f.r * 0.5 + s[1]), f.y + sin(f.swing.a) * (f.r * 0.5 + s[1]), s[2], { 1, 0.24, 0.16 }, 0.1 + 0.22 * k)
        end
    end
    -- pedestals, the shop's shelf, the trapdoor, pickups, bombs
    local function Pedestal(x, y, item, label, labelC)
        Disc("lowDisc", x, y + 10, 22, { 0, 0, 0 }, 0.45, 40, 16)
        local t = Take(pools.pedestal)
        t:SetVertexColor(1, 1, 1, 1)
        Place(t, x, y + 6, 40)
        if item then
            local it = D.ITEMS[item]
            local bob = sin(run.frame * 0.06) * 4
            Glow("lowGlow", x, y - 18 + bob, 36, D.QUALITY[it.q] or GOLD, 0.35)
            Token(x, y - 22 + bob, 16, it.i, D.QUALITY[it.q] or GOLD, { shadow = false })
        end
        if label then Label("lbl" .. x .. "_" .. y, layers.low, 11, x, y + 30, label, labelC or GOLD) end
    end
    if (room.type == "treasure" or room.type == "secret") and (room.item or room.type == "treasure") then Pedestal(CX, CY - 30, room.item) end
    if room.pedestal then Pedestal(room.pedestal.x, room.pedestal.y, room.item) end
    if room.deal then
        local dl = room.deal
        Pedestal(dl.x, dl.y, dl.item, dl.item and (dl.kind == "naaru" and "A gift of the Naaru" or "Fel bargain: 1 healthstone") or nil,
            dl.kind == "naaru" and { 1, 0.95, 0.7 } or { 1, 0.35, 0.3 })
    end
    for _, s in ipairs(room.shop or {}) do
        if not s.sold then
            if s.item then Pedestal(s.x, s.y, s.item, string.format("%d gold", s.price))
            else
                Disc("lowDisc", s.x, s.y + 10, 14, { 0, 0, 0 }, 0.45, 28, 10)
                Token(s.x, s.y - 4, 12, D.PICKUPS[s.kind].i, { 0.23, 0.18, 0.15 }, { shadow = false })
                Label("lbl" .. s.x, layers.low, 11, s.x, s.y + 24, string.format("%d gold", s.price), GOLD)
            end
        end
    end
    for i, g in ipairs(E.GravesHere(run)) do
        Token(g.x, g.y, 12, D.icon("INV_Misc_Bone_HumanSkull_01"), g.read and { 0.3, 0.3, 0.3 } or { 0.75, 0.75, 0.75 }, { alpha = g.read and 0.6 or 1 })
        Label("grave" .. i, layers.low, 10, g.x, g.y - 22, g.who, ClassColor(g.cls), g.read and 0.5 or 0.9)
    end
    if room.type == "shop" then Label("shopTitle", layers.low, 15, CX, Y0 + 40, "Goblin vendor", { 0.4, 0.85, 1 }, 0.8) end
    if room.trapdoor then
        local t = room.trapdoor
        Disc("lowDisc", t.x, t.y, 26, { 0, 0, 0 }, 1, 52, 36)
        Glow("lowGlow", t.x, t.y, 34, { 0.55, 0.24, 1 }, 0.45)
        Icon("low", D.TRAPDOOR, t.x, t.y, 30, 0.8)
    end
    for _, k in ipairs(room.pickups) do
        local bob = sin((run.frame + k.x) * 0.08) * 2
        Token(k.x, k.y - 4 + bob, 11, D.PICKUPS[k.kind].i, k.kind == "gold" and GOLD or { 0.23, 0.18, 0.15 })
    end
    for _, b in ipairs(run.bombsLive) do
        local on = b.t < 30 and (b.t % 6 < 3) or (b.t % 16 < 8)
        Token(b.x, b.y, 12, D.PICKUPS.bomb.i, on and { 1, 0.23, 0.18 } or { 0, 0, 0 })
    end
end

local function DrawActors()
    local room, p = run.room, run.p
    local f = run.bossF
    if f and f.key == "magtheridon" and f.phase == 1 then
        for _, c in ipairs(room.foes) do if c.kind == "mchan" then Line("airLine", c.x, c.y, f.x, f.y, 3, { 0.67, 0.35, 1 }, 0.55) end end
        Disc("airDisc", f.x, f.y, f.r + 12, { 0.75, 0.47, 1 }, 0.18 + 0.05 * sin(run.frame * 0.1))
    end
    if run.cast and run.cubes then
        for _, c in ipairs(run.cubes) do if c.hold > 0 then Line("airLine", c.x, c.y, f.x, f.y, 2, { 0.78, 0.6, 1 }, 0.85) end end
    end
    for _, x in ipairs(room.foes) do
        local boss = x.kind == "boss"
        if boss then Glow("airGlow", x.x, x.y, x.r * 2.2, x.boss.glow, x.immune and 0.4 or 0.8) end
        if x.kind == "azflame" and x.enraged then Glow("airGlow", x.x, x.y, 44, { 1, 0.31, 0.16 }, 0.6) end
        if x.kind == "sdemon" then Line("airLine", x.x, x.y, p.x, p.y, 2, { 0.63, 0.24, 1 }, 0.5) end
        if x.kind == "dash" or (x.d.ai == "dash" and x.state > 0) then Glow("airGlow", x.x, x.y, x.r * 1.8, FELC, 0.3) end
        local ring = boss and { 1, 0.23, 0.18 } or x.kind == "sheep" and WHITE or x.spiritOnly and { 0.6, 0.9, 1 } or { 0.48, 0.1, 0.07 }
        local bob = boss and sin(x.t * 0.05) * 3 or sin(x.t * 0.15) * 1.5
        local lift = x.d.ai == "flit" and 8 or 0
        Token(x.x, x.y + bob, x.r, x.d.i, ring, { ej = x.d.ej, flash = x.flash > 0 and (boss and 0.22 or 0.55) or 0, lift = lift,
                                                   alpha = x.spiritOnly and 0.7 or 1 })
    end
    for _, m in ipairs(run.mflames) do
        Glow("airGlow", m.x, m.y, 26, { 0.31, 0.67, 1 }, 0.6)
        Token(m.x, m.y, 10, D.BLUE_FLAME, { 0.31, 0.72, 1 }, { shadow = false })
    end
    if run.maiev then
        Token(run.maiev.x, run.maiev.y, 16, D.MAIEV_ICON, FELC)
        Label("maiev", layers.air, 11, run.maiev.x, run.maiev.y + 28, "Maiev", FELC)
    end
    for i, fm in ipairs(run.fams) do Token(fm.x, fm.y, 10, D.ITEMS[fm.k].i, fm.k == "imp" and { 1, 0.55, 0.2 } or { 0.58, 0.51, 0.79 }) end
    if run.orbital then Token(run.orbital.x, run.orbital.y, 11, D.ITEMS.elemental.i, { 0.45, 0.8, 1 }) end
    -- you (a body left behind while a spirit)
    if run.corpse then Token(run.corpse.x, run.corpse.y, p.r, CLASS_CIRCLES, { 0.3, 0.3, 0.3 }, { cls = run.class, alpha = 0.55 }) end
    -- fallen: the body sinks and greys (the spirit rising from it is drawn over the dark, on the card layer)
    local fallen = run.mode == "dying" or run.mode == "dead"
    if fallen then
        local k = min(1, (run.dyingT or E.DYING) / 30)
        Token(p.x, p.y + k * 4, p.r * (1 - 0.15 * k), CLASS_CIRCLES, { 0.35, 0.35, 0.35 }, { cls = run.class, alpha = 1 - 0.45 * k })
    end
    local blink = not fallen and p.inv > 0 and floor(p.inv / 5) % 2 == 1 and not run.spirit
    if not blink and not fallen then
        local c = run.cdef.tear
        local moving = E.Hyp(p.vx, p.vy) > 0.5
        local lift = moving and abs(sin(run.frame * 0.25)) * 3 or 0
        if run.meta then
            Glow("airGlow", p.x, p.y, 30, FELC, 0.5)
            Token(p.x, p.y, p.r + 3, D.METAMORPH, FELC, { lift = lift })
        else
            Token(p.x, p.y, p.r, CLASS_CIRCLES, c, { cls = run.class, lift = lift, alpha = run.spirit and 0.6 or 1 })
        end
        if run.shield then
            Disc("airDisc", p.x, p.y, p.r + 8, { 1, 0.94, 0.67 }, 0.22)
        end
        if run.sod then
            Icon("air", D.SPELL.shadowOfDeath, p.x, p.y - p.r - 16, 18)
            Label("sod", layers.air, 13, p.x + 16, p.y - p.r - 16, tostring(math.ceil(run.sod / 60)), { 1, 0.3, 0.3 }, 1, "LEFT")
        end
        if run.paraOn > 0 then Glow("airGlow", p.x, p.y, 30, { 0.55, 0.24, 1 }, 0.5) end
        if run.pcaged > 0 then
            for _ = 1, 3 do Line("airLine", p.x + math.random(-30, 30), p.y - 40, p.x + math.random(-8, 8), p.y, 1.5, { 0.67, 0.55, 1 }, 0.85) end
        end
    end
    -- tears and shots
    for _, t in ipairs(run.tears) do
        Glow("airGlow", t.x, t.y, t.r * 2.4, t.col, 0.45)
        Disc("airDisc", t.x, t.y, t.r * 0.75, t.col, 1)
        Disc("airDisc", t.x - t.r * 0.2, t.y - t.r * 0.25, t.r * 0.3, WHITE, 0.85)
    end
    for _, s in ipairs(run.shots) do
        Glow("airGlow", s.x, s.y, s.r * 2.2, s.col, 0.5)
        Disc("airDisc", s.x, s.y, s.r * 0.75, { 0, 0, 0 }, 0.7)
        Disc("airDisc", s.x, s.y, s.r * 0.62, s.col, 1)
    end
    for _, o in ipairs(run.orbs) do
        local k = o.t / o.max
        Glow("airGlow", o.x0 + (o.x - o.x0) * k, o.y0 + (o.y - o.y0) * k - sin(k * pi) * 40, 20, o.col, 0.85)
    end
    if run.beam and run.beam.t > run.beam.warn and f then
        local b = run.beam
        local k = min(1, (b.t - b.warn) / b.run)
        local hx, hy = b.ax + (b.bx - b.ax) * k, b.ay + (b.by - b.ay) * k
        Line("airLine", f.x, f.y, hx, hy, 7, FELC, 0.85)
        Line("airLine", f.x, f.y, hx, hy, 2, { 0.9, 1, 0.8 }, 0.95)
        Glow("airGlow", hx, hy, 34, FELC, 0.7)
    end
    for _, b in ipairs(run.beams) do
        if b.t >= b.warn then
            Line("airLine", b.ax, b.ay, b.bx, b.by, 9, b.col, 0.8 * (1 - (b.t - b.warn) / 12))
            Line("airLine", b.ax, b.ay, b.bx, b.by, 2, WHITE, 0.9 * (1 - (b.t - b.warn) / 12))
        end
    end
    for _, z in ipairs(run.zaps) do
        if z.boom then
            Glow("airGlow", z.x, z.y, 110 * (1 - z.life / 22), z.col or { 1, 0.63, 0.16 }, min(1, z.life / 14))
        else
            Line("airLine", z.x1, z.y1, z.x2, z.y2, 2, { 0.67, 0.86, 1 }, 0.9)
        end
    end
    if f and f.caged then Glow("airGlow", f.x, f.y, f.r * 1.8, { 0.67, 0.55, 1 }, 0.4) end
end

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------

local function Stone(file, x, y, half, dim)
    local t = Icon("hud", file, x + 9, y + 9, 18, dim and 0.22 or 1)
    if half then
        t:SetTexCoord(0.08, 0.5, 0.08, 0.92)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", screen, "TOPLEFT", x, -y)
        t:SetSize(9, 18)
    end
end

local function DrawHud()
    Rect("hudBack", 6, 4, 286, 40, { 0, 0, 0 }, 0.55)
    if run.daily then Label("daily", layers.hud, 10, CX + 70, 14, run.counted and "TODAY'S DUNGEON" or "PRACTICE", run.counted and FELC or { 0.64, 0.59, 0.52 }, 0.9, "LEFT") end
    local x = 12
    for i = 0, run.maxHp - 1 do
        local full = run.hp - i * 2
        Stone(D.PICKUPS.heart.i, x, 8, false, true)
        if full >= 2 then Stone(D.PICKUPS.heart.i, x, 8) elseif full == 1 then Stone(D.PICKUPS.heart.i, x, 8, true) end
        x = x + 21
    end
    local s = run.soul
    while s > 0 do
        Stone(D.PICKUPS.soul.i, x, 8, s == 1)
        s, x = s - 2, x + 21
    end
    for i, c in ipairs({ { "gold", run.gold }, { "bomb", run.bombs }, { "key", run.keys } }) do
        Icon("hud", D.PICKUPS[c[1]].i, 18 + (i - 1) * 52, 35, 13, 1, c[1] ~= "gold" and nil or false)
        Label("count" .. i, layers.hud, 11, 28 + (i - 1) * 52, 35, string.format("%02d", c[2]), { 0.95, 0.92, 0.85 }, 1, "LEFT")
    end
    for i, k in ipairs(run.items) do Icon("hud", D.ITEMS[k].i, 300 + (i - 1) * 21, 18, 18) end
    if run.active then
        local it = D.ITEMS[run.active]
        Icon("hud", it.i, 228, 24, 26, run.charge >= run.chargeMax and 1 or 0.45)
        Rect("hudBar", 216, 40, 24, 3, { 0.15, 0.15, 0.15 })
        Rect("hudBar", 216, 40, 24 * run.charge / run.chargeMax, 3, run.charge >= run.chargeMax and FELC or { 0.6, 0.6, 0.6 })
    end
    -- the minimap
    local mx, my = W - 128, 4
    Rect("hudBack", mx - 4, my, 124, 40, { 0, 0, 0 }, 0.6)
    local minx, miny, maxx, maxy = 9, 9, 0, 0
    for _, r in ipairs(run.map.list) do
        minx, maxx, miny, maxy = min(minx, r.x), max(maxx, r.x), min(miny, r.y), max(maxy, r.y)
    end
    local cw, ch = min(14, 116 / (maxx - minx + 1)), min(8, 36 / (maxy - miny + 1))
    for _, r in ipairs(run.map.list) do
        local seen = r.visited
        if not seen and (r.type ~= "secret" or r.revealed) then
            for _, nb in ipairs(E.Neighbours(run.map, r)) do if nb.room.visited then seen = "near" end end
        end
        if seen then
            local rx, ry = mx + (r.x - minx) * cw, my + 2 + (r.y - miny) * ch
            Rect("hudMap", rx, ry, cw - 2, ch - 2, r == run.room and WHITE or (seen == true) and { 0.55, 0.49, 0.42 } or { 0.24, 0.2, 0.17 })
            local ic = (r.type == "boss" and D.SKULL) or (r.type == "treasure" and D.icon("INV_Misc_Key_10")) or (r.type == "shop" and D.PICKUPS.gold.i) or nil
            if ic then Icon("hud", ic, rx + cw / 2 - 1, ry + ch / 2 - 1, 9, 1, false) end
        end
    end
    -- the boss's bar, the cast bar, words
    local boss = run.bossF and run.room.foes[1] and run.bossF
    if boss and boss.hp > 0 then
        local bw, bx, by = 300, CX - 150, H - 30
        Rect("hudBack", bx - 34, by - 6, bw + 40, 24, { 0, 0, 0 }, 0.75)
        Token(bx - 20, by + 6, 10, boss.d.i, { 1, 0.23, 0.18 }, { ej = boss.d.ej, shadow = false })
        Rect("hudBar", bx, by, bw, 12, { 0.23, 0.05, 0.04 })
        Rect("hudBar", bx, by, bw * max(0, boss.hp / boss.max), 12, { 0.78, 0.15, 0.1 })
        Rect("hudBar", bx, by, bw * max(0, boss.hp / boss.max), 4, WHITE, 0.18)
        Label("bossName", layers.hud, 10, CX, by + 6,
            boss.d.n .. ((boss.phaseName and boss.phaseName ~= "") and ("  \194\183  " .. boss.phaseName) or ""), WHITE)
    end
    if run.cast then
        local cw2, cx0, cy0 = 220, CX - 110, H - 60
        Rect("hudBack", cx0 - 26, cy0 - 4, cw2 + 30, 20, { 0, 0, 0 }, 0.75)
        Icon("hud", run.cast.icon, cx0 - 15, cy0 + 6, 16)
        Rect("hudBar", cx0, cy0, cw2, 12, { 0.23, 0.16, 0.03 })
        Rect("hudBar", cx0, cy0, cw2 * run.cast.t / run.cast.max, 12, { 1, 0.69, 0 })
        Label("castName", layers.hud, 10, CX, cy0 + 6, run.cast.name, WHITE)
    end
    if run.toast then Label("toast", layers.hud, 14, CX, H - 88, run.toast.t, { 0.95, 0.92, 0.85 }) end
    if run.say then
        local yell = run.say.kind == "yell"
        Label("say", layers.hud, 13, CX, 62, yell and (run.say.who .. " yells: " .. run.say.text) or run.say.text,
            yell and { 1, 0.25, 0.25 } or { 1, 0.7, 0.28 }, min(1, run.say.life / 30))
    end
    if run.banner then
        local b = run.banner
        local a = min(1, b.life / 20, (170 - b.life) / 12)
        Rect("hudBack", 0, 70, W, 74, { 0, 0, 0 }, 0.6 * a)
        Label("bannerN", layers.hud, 26, CX, 98, b.n, D.QUALITY[b.q] or GOLD, a)
        Label("bannerT", layers.hud, 14, CX, 128, b.t, { 0.95, 0.92, 0.85 }, a)
    end
    if run.fade and run.fade > 0 then Rect("hudBack", 0, 0, W, H, { 0, 0, 0 }, run.fade / 14) end
end

---------------------------------------------------------------------------
-- Cards
---------------------------------------------------------------------------

local function CardArt(key, a)
    local t = layers.cardArt
    t:SetTexture(LOADING[key] or LOADING.bt)
    t:SetTexCoord(0, 1, 0.24, 0.84)
    t:SetAlpha(a)
    t:Show()
    layers.cardShade:SetAlpha(a)
    layers.cardShade:Show()
end

local function DrawCards()
    local cf = layers.card
    local keep = pools.token
    pools.token = pools.cardToken
    layers.cardArt:Hide()
    layers.cardShade:Hide()
    if run.mode == "floorcard" then
        local k = run.cardT
        local a = min(1, k / 20, (150 - k) / 15 + 0.2)
        Rect("card", 0, 0, W, H, { 0, 0, 0 }, a)
        CardArt(run.F.art, a)
        Label("cardSub", cf, 13, CX, H - 118, string.format("FLOOR %d OF %d", run.floorN, #D.FLOORS), FELC, a)
        Label("cardTitle", cf, 34, CX, H - 84, run.F.name, GOLD, a)
    elseif run.mode == "vs" then
        local f = run.bossF
        local k = 1 - run.cardT / 110
        local off = max(0, 1 - k * 4) * 300
        Rect("card", 0, 0, W, H, { 0, 0, 0 }, 0.72)
        Rect("card", 0, 110, W, 230, { 0.1, 0.04, 0.03 }, 0.95)
        Token(160 - off, CY - 6, 54, CLASS_CIRCLES, run.cdef.tear, { cls = run.class, shadow = false })
        Token(W - 200 + off, CY - 16, 70, f.d.i, { 1, 0.23, 0.18 }, { ej = f.d.ej, shadow = false })
        Label("vsMe", cf, 20, 160 - off, CY + 70, UnitName and UnitName("player") or "You", { 0.95, 0.92, 0.85 })
        Label("vsBoss", cf, 24, W - 200 + off, CY + 80, f.d.n, GOLD)
        Label("vsVs", cf, 44, CX, CY - 10, "VS", { 1, 0.23, 0.18 })
    elseif run.mode == "dying" then
        -- the killing blow: a red flash, the room slows and darkens, the killer is marked, your spirit leaves
        local t, p = run.dyingT, run.p
        if t < 22 then Rect("card", 0, 0, W, H, { 0.75, 0.05, 0.03 }, 0.4 * (1 - t / 22)) end
        Rect("card", 0, 0, W, H, { 0, 0, 0 }, min(0.62, t / 90 * 0.62))
        local kf = run.killerFoe
        if kf and kf.hp > 0 then
            local pulse = 0.5 + 0.5 * sin(t * 0.25)
            Glow("cardGlow", kf.x, kf.y, kf.r * 2.6, { 1, 0.2, 0.15 }, 0.35 + 0.3 * pulse)
            Token(kf.x, kf.y, kf.r, kf.d.i, { 1, 0.23, 0.18 }, { ej = kf.d.ej, shadow = false })
            if t > 30 then Label("dieKiller", cf, 12, kf.x, kf.y - kf.r - 14, kf.d.n, { 1, 0.4, 0.33 }, min(1, (t - 30) / 20)) end
        end
        if t > 24 then
            local k = min(1, (t - 24) / 110)
            local sy = p.y - k * 80
            Glow("cardGlow", p.x, sy, 34, { 0.6, 0.85, 1 }, 0.55 * (1 - k * 0.7))
            Token(p.x, sy, p.r, CLASS_CIRCLES, { 0.7, 0.9, 1 }, { cls = run.class, alpha = 0.6 * (1 - k), shadow = false })
        end
        if t > 45 then Label("dieTitle", cf, 40, CX, 70, "You died", { 0.89, 0.25, 0.2 }, min(1, (t - 45) / 30)) end
        if t > 75 then Label("dieSub", cf, 15, CX, 104, "Slain by " .. tostring(run.killer), { 0.95, 0.92, 0.85 }, min(1, (t - 75) / 25)) end
    elseif run.mode == "dead" then
        -- the card rises in: who killed you, how far you got, what you carried; the restart waits a second
        local t = run.deadT or 99
        local e = 1 - (1 - min(1, t / 20)) ^ 3
        local oy = (1 - e) * 30
        local dim, ink = { 0.64, 0.59, 0.52 }, { 0.95, 0.92, 0.85 }
        Rect("card", 0, 0, W, H, { 0, 0, 0 }, 0.62 + 0.2 * e)
        Label("dieTitle", cf, 40, CX, 70 - 16 * e, "You died", { 0.89, 0.25, 0.2 })
        Rect("card", CX - 230, 96 + oy, 460, 262, { 0.09, 0.07, 0.05 }, e)
        Rect("card", CX - 226, 100 + oy, 452, 1, { 0.35, 0.27, 0.19 }, e)
        Rect("card", CX - 226, 353 + oy, 452, 1, { 0.35, 0.27, 0.19 }, e)
        Rect("card", CX - 70, 132 + oy, 1, 128, { 0.35, 0.27, 0.19 }, e)
        Label("dieSub", cf, 13, CX, 116 + oy, string.format("Floor %d of %d  \194\183  %s", run.floorN, #D.FLOORS, run.F.name), ink, e)
        -- who
        Label("dieBy", cf, 10, CX - 150, 146 + oy, "SLAIN BY", dim, e)
        local kfile = run.killerIcon or D.icon("INV_Misc_Bone_HumanSkull_01")
        Glow("cardGlow", CX - 150, 196 + oy, 60, { 1, 0.2, 0.15 }, 0.3 * e)
        Token(CX - 150, 196 + oy, 32, kfile, { 1, 0.23, 0.18 }, { ej = run.killerEj, shadow = false, alpha = e })
        Label("dieName", cf, 14, CX - 150, 248 + oy, tostring(run.killer), GOLD, e)
        -- how far
        local seen, all = 0, 0
        for _, r in ipairs(run.map.list) do
            if r.type ~= "secret" then all = all + 1 if r.visited then seen = seen + 1 end end
        end
        local secs = floor(run.time / 60)
        for i, row in ipairs({ { "Time", string.format("%d:%02d", floor(secs / 60), secs % 60) }, { "Rooms", string.format("%d of %d", seen, all) },
                               { "Kills", tostring(run.kills) }, { "Gold", tostring(run.gold) } }) do
            Label("dieK" .. i, cf, 12, CX - 40, 150 + (i - 1) * 26 + oy, row[1], dim, e, "LEFT")
            Label("dieV" .. i, cf, 14, CX + 40, 150 + (i - 1) * 26 + oy, row[2], ink, e, "LEFT")
        end
        if run.newBest then Label("dieBest", cf, 12, CX + 170, 150 + oy, "New best!", FELC, e) end
        -- what you carried
        local items = {}
        for _, k in ipairs(run.items) do items[#items + 1] = k end
        if run.active then items[#items + 1] = run.active end
        for i, k in ipairs(items) do Icon("card", D.ITEMS[k].i, CX - #items * 15 + (i - 1) * 30 + 15, 300 + oy, 26, e) end
        if #items == 0 then Label("endNone", cf, 12, CX, 300 + oy, "No items this run", dim, e) end
        if run.daily and run.counted and Board() then
            local list = Board():Board(run.daily)
            for i, row in ipairs(list) do
                if row.me then Label("dieRank", cf, 12, CX + 170, 176 + oy, string.format("Today: #%d of %d", i, #list), GOLD, e) end
            end
        elseif run.daily then
            Label("dieRank", cf, 11, CX + 170, 176 + oy, "Practice: not on the board", dim, e)
        end
        local ready = t > 60
        Label("endKeys", cf, 15, CX, 384, run.daily and "R  try again (practice)     Enter  today's board" or "R  try again     Enter  today's board",
            GOLD, ready and (0.75 + 0.25 * sin(t * 0.08)) or 0.2)
    elseif run.mode == "won" then
        Rect("card", 0, 0, W, H, { 0, 0, 0 }, 0.72)
        Rect("card", CX - 210, 60, 420, 300, { 0.09, 0.07, 0.05 }, 1)
        Rect("card", CX - 206, 64, 412, 1, { 0.35, 0.27, 0.19 })
        Rect("card", CX - 206, 355, 412, 1, { 0.35, 0.27, 0.19 })
        Label("endTitle", cf, 28, CX, 100, "The Betrayer falls", FELC)
        Label("endSub", cf, 14, CX, 134, "You beat all five floors.", { 0.95, 0.92, 0.85 })
        local secs = floor(run.time / 60)
        Label("endStats", cf, 12, CX, 200, string.format("%s  \194\183  %d:%02d  \194\183  %d kills  \194\183  %d gold",
            run.F.name, floor(secs / 60), secs % 60, run.kills, run.gold), { 0.64, 0.59, 0.52 })
        local items = {}
        for _, k in ipairs(run.items) do items[#items + 1] = k end
        if run.active then items[#items + 1] = run.active end
        for i, k in ipairs(items) do Icon("card", D.ITEMS[k].i, CX - #items * 15 + (i - 1) * 30 + 15, 238, 26) end
        if #items == 0 then Label("endNone", cf, 12, CX, 238, "No items this run", { 0.64, 0.59, 0.52 }) end
        Label("endKeys", cf, 14, CX, 320, "R  new run     Enter  today's board", GOLD)
    end
    pools.token = keep
end

local function DrawTitle()
    local keep = pools.token
    pools.token = pools.cardToken
    local dim, ink = { 0.64, 0.59, 0.52 }, { 0.95, 0.92, 0.85 }
    Rect("card", 0, 0, W, H, { 0, 0, 0 }, 1)
    CardArt("bt", 0.55)
    Label("tTitle", layers.card, 34, CX, 54, "The Binding of Illidan", GOLD)
    Label("tSub", layers.card, 13, CX, 86, "Five floors of the Black Temple. The bosses fight like the raid.", { 0.85, 0.81, 0.75 })
    -- you
    local cls = UI.Class()
    local c = D.CLASSES[cls]
    local lx = 190
    Glow("cardGlow", lx, 176, 64, c.tear, 0.35)
    Token(lx, 176, 38, CLASS_CIRCLES, c.tear, { cls = cls, shadow = false })
    Label("tClass", layers.card, 18, lx, 232, LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls] or cls, ClassColor(cls))
    Label("tStats", layers.card, 11, lx, 254, string.format("%s  \194\183  %d healthstones%s", c.bolt, c.hp,
        (c.soul or 0) > 0 and string.format(" + %d shard", c.soul / 2) or ""), dim)
    Label("tNote", layers.card, 11, lx, 272, c.note, dim)
    Label("tBest", layers.card, 11, lx, 300, Game() and Game():BestLine() or "", dim)
    -- today's dungeon and the guild's board for it
    local B = Board()
    local bx, bw = 372, 318
    Rect("card", bx, 118, bw, 222, { 0.05, 0.04, 0.03 }, 0.82)
    Rect("card", bx, 118, bw, 1, { 0.35, 0.27, 0.19 })
    Label("tToday", layers.card, 10, bx + 12, 134, "TODAY'S DUNGEON", FELC, 1, "LEFT")
    Label("tDay", layers.card, 10, bx + bw - 12, 134, B and B:Today() or "", dim, 1, "RIGHT")
    local list = B and B:Board() or {}
    if #list == 0 then
        Label("tEmpty", layers.card, 12, bx + bw / 2, 210, "Nobody has tried it yet.", dim)
        Label("tEmpty2", layers.card, 11, bx + bw / 2, 230, "The same dungeon for the whole guild, one try a day.", dim)
    end
    for i = 1, min(7, #list) do
        local row = list[i]
        local y = 158 + (i - 1) * 24
        if row.me then Rect("card", bx + 4, y - 11, bw - 8, 22, FELC, 0.08) end
        Label("tRk" .. i, layers.card, 11, bx + 22, y, tostring(i), dim, 1, "RIGHT")
        Token(bx + 38, y, 8, CLASS_CIRCLES, { 0, 0, 0 }, { cls = row.e.c, shadow = false })
        Label("tNm" .. i, layers.card, 12, bx + 52, y, row.name, ClassColor(row.e.c), 1, "LEFT")
        Label("tRs" .. i, layers.card, 11, bx + bw - 12, y, B:ResultText(row.e), row.e.w and FELC or ink, 1, "RIGHT")
    end
    local tried = B and B:Tried()
    if not focused then
        Label("tGo", layers.card, 16, CX, H - 52, "Click here to play", FELC)
    else
        Label("tGo", layers.card, 15, CX, H - 62, tried and "Enter  today's dungeon again (practice)" or "Enter  today's dungeon (your try counts)", FELC)
        Label("tGo2", layers.card, 13, CX, H - 38, "N  a random dungeon", ink)
    end
    pools.token = keep
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

local function Draw()
    Begin()
    hud.used = {}
    if not run then
        DrawTitle()
    else
        if run.mode ~= "floorcard" then
            DrawStatic()
            DrawDoors()
            DrawFloorThings()
            DrawActors()
            DrawHud()
        end
        DrawCards()
        if not focused and run.mode == "play" then
            Rect("card", 0, 0, W, H, { 0, 0, 0 }, 0.6)
            Label("paused", layers.card, 24, CX, CY, "Paused \194\183 click to play", GOLD)
        end
    end
    Finish()
    for k, fs in pairs(hud) do
        if k ~= "used" and not hud.used[k] then fs:Hide() end
    end
    local shake = run and run.shake and run.shake > 0 and run.mode == "play"
    screen:ClearAllPoints()
    screen:SetPoint("CENTER", root, "CENTER", shake and (run.frame % 4 < 2 and 3 or -3) or 0, 0)
    layers.static:SetShown(run ~= nil and run.mode ~= "floorcard")
end

local function Input()
    local mx = (held.D and 1 or 0) - (held.A and 1 or 0)
    local my = (held.S and 1 or 0) - (held.W and 1 or 0)
    local shoot
    for i = #shootOrder, 1, -1 do
        if held[shootOrder[i]] then shoot = ({ UP = "up", DOWN = "down", LEFT = "left", RIGHT = "right" })[shootOrder[i]] break end
    end
    local inp = { mx = mx, my = my, shoot = shoot, bomb = edge.E, use = edge.SPACE }
    edge = {}
    return inp
end

local function OnUpdate(_, elapsed)
    if run and focused then
        acc = min(acc + elapsed, STEP * 4)
        while acc >= STEP do
            acc = acc - STEP
            E.Step(run, Input())
        end
    end
    Draw()
end

---------------------------------------------------------------------------
-- Keys and focus
---------------------------------------------------------------------------

local KEYS = { W = true, A = true, S = true, D = true, UP = true, DOWN = true, LEFT = true, RIGHT = true, E = true, SPACE = true,
               ENTER = true, R = true, N = true }

local function SetFocus(on)
    focused = on and true or false
    if root then pcall(root.EnableKeyboard, root, focused) end
    wipe(held)
    wipe(shootOrder)
    edge = {}
    acc = 0
end
UI.SetFocus = SetFocus

function UI.Class()
    local cls
    if UnitClass then cls = select(2, UnitClass("player")) end
    return D.CLASSES[cls or ""] and cls or "WARRIOR"
end

-- daily: today's dungeon (the guild's; your first try counts), else a random one
function UI:NewRun(daily)
    run = Game() and Game():NewRun(UI.Class(), daily) or E.New({ class = UI.Class(), seed = floor((time and time() or 1) % 2000000000) })
    acc = 0
    return run
end

local function OnKeyDown(self, key)
    if key == "ESCAPE" then
        SetFocus(false)
        pcall(self.SetPropagateKeyboardInput, self, false)
        return
    end
    if not InCombatLockdown() and self.SetPropagateKeyboardInput then pcall(self.SetPropagateKeyboardInput, self, not KEYS[key]) end
    if not KEYS[key] then return end
    held[key] = true
    edge[key] = true
    if key == "UP" or key == "DOWN" or key == "LEFT" or key == "RIGHT" then shootOrder[#shootOrder + 1] = key end
    if not run then
        if key == "ENTER" then UI:NewRun(true) elseif key == "N" then UI:NewRun(false) end
        return
    end
    -- (the death card holds its keys back a second: a key still held from the fight must not skip it)
    local over = (run.mode == "dead" and (run.deadT or 0) > 60) or run.mode == "won"
    if over and key == "R" then UI:NewRun(run.daily ~= nil) end
    if over and key == "ENTER" then
        run = nil
        if Board() then Board():Ask() end
    end
end

local function OnKeyUp(_, key)
    held[key] = nil
    for i = #shootOrder, 1, -1 do if shootOrder[i] == key then table.remove(shootOrder, i) end end
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------

local function Layout()
    local w, h = root:GetWidth(), root:GetHeight()
    if not w or w < 100 then w, h = 786, 518 end
    screen:SetScale(max(0.3, min(w / W, h / H)))
end

function UI:CreatePanel(parent)
    root = CreateFrame("Frame", nil, parent)
    root:SetAllPoints()
    root:EnableMouse(true)
    local bg = root:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 1)
    screen = CreateFrame("Frame", nil, root)
    screen:SetSize(W, H)
    screen:SetPoint("CENTER")
    screen:SetClipsChildren(true)
    layers = {}
    local lv = root:GetFrameLevel()
    for i, k in ipairs({ "static", "low", "act", "air", "hud", "card" }) do
        local f = CreateFrame("Frame", nil, screen)
        f:SetAllPoints()
        f:SetFrameLevel(lv + i * 3)
        layers[k] = f
    end
    -- the room's fixed parts: floor, tint, walls, the trim along the wall's inner edge, the shadows
    local st = layers.static
    layers.floorTex = st:CreateTexture(nil, "BACKGROUND", nil, 0)
    layers.floorTex:SetPoint("TOPLEFT", X0, -Y0)
    layers.floorTex:SetSize(X1 - X0, Y1 - Y0)
    layers.floorTex:SetTexCoord(0, (X1 - X0) / 160, 0, (Y1 - Y0) / 160)
    layers.tint = st:CreateTexture(nil, "BACKGROUND", nil, 1)
    layers.tint:SetAllPoints(layers.floorTex)
    layers.walls = {}
    for _, r in ipairs({ { 0, 0, W, Y0 }, { 0, Y1, W, H - Y1 }, { 0, Y0, X0, Y1 - Y0 }, { X1, Y0, W - X1, Y1 - Y0 } }) do
        local t = st:CreateTexture(nil, "BACKGROUND", nil, 2)
        t:SetPoint("TOPLEFT", r[1], -r[2])
        t:SetSize(r[3], r[4])
        t:SetTexCoord(0, r[3] / 128, 0, r[4] / 128)
        t:SetVertexColor(0.8, 0.8, 0.8)
        layers.walls[#layers.walls + 1] = t
    end
    for _, y in ipairs({ Y0 - 14, Y1 - 10 }) do
        local t = st:CreateTexture(nil, "BORDER", nil, 0)
        t:SetTexture(D.TRIM, "REPEAT", "CLAMP")
        t:SetPoint("TOPLEFT", 0, -y)
        t:SetSize(W, 24)
        if y < CY then t:SetTexCoord(0, W / 96, 0.5, 1) else t:SetTexCoord(0, W / 96, 0, 0.5) end
        t:SetAlpha(0.85)
    end
    for _, s in ipairs({ { "TOP", "VERTICAL", X0, Y0, X1 - X0, 22, true }, { "BOTTOM", "VERTICAL", X0, Y1 - 22, X1 - X0, 22, false },
                         { "LEFT", "HORIZONTAL", X0, Y0, 22, Y1 - Y0, false }, { "RIGHT", "HORIZONTAL", X1 - 22, Y0, 22, Y1 - Y0, true } }) do
        local t = st:CreateTexture(nil, "BORDER", nil, 1)
        t:SetPoint("TOPLEFT", s[3], -s[4])
        t:SetSize(s[5], s[6])
        t:SetColorTexture(1, 1, 1, 1)
        if s[7] then ns.UI:GradientRGBA(t, s[2], 0, 0, 0, 0, 0, 0, 0, 0.55) else ns.UI:GradientRGBA(t, s[2], 0, 0, 0, 0.55, 0, 0, 0, 0) end
    end
    -- pools by layer: the low layer (on the floor), the actors, the air (tears, shots, beams), the HUD, the cards
    pools.floorRect = NewPool(st, "tex", "ARTWORK", 0)
    pools.floorGlow = NewPool(st, "tex", "ARTWORK", 1, "ADD", RADIAL)
    pools.door = NewPool(st, "tex", "ARTWORK", 2, nil, D.DOOR)
    pools.doorBar = NewPool(st, "tex", "ARTWORK", 3)
    pools.lowGlow = NewPool(layers.low, "tex", "BACKGROUND", 0, "ADD", RADIAL)
    pools.lowDisc = NewPool(layers.low, "tex", "BORDER", 0, nil, CIRCLE)
    pools.lowLine = NewPool(layers.low, "line", "BORDER", 1)
    pools.pedestal = NewPool(layers.low, "tex", "ARTWORK", 0, nil, D.PEDESTAL)
    pools.low = NewPool(layers.low, "tex", "ARTWORK", 1)
    pools.fx = NewPool(layers.low, "tex", "OVERLAY", 0)
    pools.token = { frame = layers.act, kind = "token", items = {}, n = 0 }
    pools.airGlow = NewPool(layers.air, "tex", "BACKGROUND", 0, "ADD", RADIAL)
    pools.airDisc = NewPool(layers.air, "tex", "ARTWORK", 0, nil, CIRCLE)
    pools.airLine = NewPool(layers.air, "line", "ARTWORK", 1)
    pools.air = NewPool(layers.air, "tex", "OVERLAY", 0)
    pools.hudBack = NewPool(layers.hud, "tex", "BACKGROUND", 0)
    pools.hudBar = NewPool(layers.hud, "tex", "BORDER", 0)
    pools.hudMap = NewPool(layers.hud, "tex", "BORDER", 1)
    pools.hud = NewPool(layers.hud, "tex", "ARTWORK", 0)
    pools.card = NewPool(layers.card, "tex", "BACKGROUND", 2)
    pools.cardGlow = NewPool(layers.card, "tex", "BORDER", 0, "ADD", RADIAL)
    layers.cardArt = layers.card:CreateTexture(nil, "BACKGROUND", nil, 3)
    layers.cardArt:SetPoint("TOPLEFT")
    layers.cardArt:SetSize(W, W * 0.6)
    layers.cardShade = layers.card:CreateTexture(nil, "BACKGROUND", nil, 4)
    layers.cardShade:SetAllPoints()
    layers.cardShade:SetColorTexture(1, 1, 1, 1)
    ns.UI:GradientRGBA(layers.cardShade, "VERTICAL", 0, 0, 0, 0.96, 0, 0, 0, 0.1)
    -- (the tokens draw in the actor layer; the vs card's and the title's tokens borrow it too: the card layer's
    -- frame sits over it, so they are drawn on a second token pool there)
    pools.cardToken = { frame = layers.card, kind = "token", items = {}, n = 0 }

    root:SetScript("OnSizeChanged", Layout)
    root:SetScript("OnMouseDown", function() SetFocus(true) end)
    root:SetScript("OnKeyDown", OnKeyDown)
    root:SetScript("OnKeyUp", OnKeyUp)
    root:SetScript("OnUpdate", OnUpdate)
    root:SetScript("OnHide", function() SetFocus(false) end)
    pcall(root.EnableKeyboard, root, false)
    Layout()
    function root:OnGameShown()
        Layout()
        if ns.BoIBoard then ns.BoIBoard:Ask() end
    end
    function root:OnGameHidden() SetFocus(false) end
    ns:On("GAMES_COMBAT", function(inCombat) if inCombat then SetFocus(false) end end)
    Draw()
    return root
end

-- (tests and the audit)
function UI._Run() return run end
function UI._SetRun(r) run = r end
function UI._Focus(on) SetFocus(on) end
function UI._Draw() Draw() end
function UI._Key(key, up) if up then OnKeyUp(root, key) else OnKeyDown(root, key) end end
function UI._Pools() return pools end
function UI._Hud() return hud end

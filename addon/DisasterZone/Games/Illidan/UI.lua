if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Illidan/UI.lua", ...) then return end -- DisasterZone Games/Illidan/UI.lua
-- ns.BoIUI: The Binding of Illidan's panel in the Games hub. The room is drawn from the run (ns.BoI) every frame:
-- the raid's floor and wall textures lit by the floor's sconces, gilded doors, round tokens for you and the enemies (icons in a ring; bosses
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
local RADIAL = ns.MEDIA .. "MyBiS\\Radial"
local FONT = "Fonts\\FRIZQT__.TTF"
local CLASS_CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
local STEP = 1 / 60
local GOLD, FELC, WHITE = ns.Style.C.GOLD, { 0.65, 0.94, 0.29 }, { 1, 1, 1 }
-- colours drawn every frame live here: a table written inside a call is a new one on every call (garbage per frame)
local BLACK, INK = { 0, 0, 0 }, { 0.95, 0.92, 0.85 }
local IRON, IRON_DARK = { 0.08, 0.06, 0.05 }, { 0.05, 0.04, 0.03 }
local RING = { boss = { 1, 0.23, 0.18 }, spirit = { 0.6, 0.9, 1 }, foe = { 0.48, 0.1, 0.07 }, heart = { 0.45, 0.75, 0.25 },
               soul = { 0.62, 0.38, 1 }, glaive = { 0.49, 1, 0.23 }, shade = { 0.63, 0.24, 1 } }
local DOOR_LIGHT = { boss = { 1, 0.16, 0.12 }, treasure = GOLD, shop = { 0.4, 0.85, 1 }, secret = { 0.6, 0.45, 1 },
                     normal = { 1, 0.85, 0.6 } }
local BARS_GOLD, BARS_IRON = { 1, 0.85, 0.5 }, { 0.85, 0.85, 0.9 }
local MAP_HERE, MAP_SEEN, MAP_NEAR, MAP_EDGE = { 1, 0.95, 0.8 }, { 0.5, 0.45, 0.38 }, { 0.2, 0.17, 0.14 }, { 0.02, 0.015, 0.01 }
local NOOPTS, TOK = {}, {}
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
local TOKEN_PARTS = { "shadow", "ring", "rim", "bg", "pic", "flash" }
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
    function o.Show() for _, k in ipairs(TOKEN_PARTS) do o[k]:Show() end end
    function o.Hide() for _, k in ipairs(TOKEN_PARTS) do o[k]:Hide() end end
    return o
end

-- pic: an icon path / FileDataID; opts = { ej = true (a 128 x 64 bust), cls = "MAGE" (a class circle), flash, alpha,
-- shadow = false, lift (px the token floats above its shadow) }
local function Token(x, y, r, pic, ring, opts)
    opts = opts or NOOPTS
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

-- Token's options for the calls made every frame, in one table refilled each time (Token keeps nothing of it)
local function Opts(ej, cls, flash, alpha, lift, shadow)
    TOK.ej, TOK.cls, TOK.flash, TOK.alpha, TOK.lift, TOK.shadow = ej, cls, flash, alpha, lift, shadow
    return TOK
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

-- the sconces: x, y on the wall band, which way the room is (their light's pool lies that way)
local SCONCES = { { 225, Y0 - 20, 1 }, { 495, Y0 - 20, 1 }, { 225, Y1 + 20, -1 }, { 495, Y1 + 20, -1 } }
local FLAME = { 1, 0.95, 0.8 }

local function DrawStatic()
    local F = run.F
    local k = F.floorK or 0.5
    local fl = layers.floorTex
    if fl.fid ~= F.floor then
        fl:SetTexture(F.floor, "REPEAT", "REPEAT")
        fl.fid = F.floor
        for _, w in ipairs(layers.walls) do w:SetTexture(F.wall, "REPEAT", "REPEAT") end
        layers.surround:SetTexture(F.wall, "REPEAT", "REPEAT")
    end
    fl:SetVertexColor(k, k, k)
    layers.tint:SetColorTexture(F.tint[1], F.tint[2], F.tint[3], F.tint[4])
    -- the floor's light: sconces on the top and bottom walls (an iron bracket, a flickering flame, its halo on the
    -- wall, a pool spilling onto the floor in the floor's colour) and one glow in the room's middle
    local c, t = F.light or WHITE, (run.frame or 0) / 60
    for i, s in ipairs(SCONCES) do
        local f = 0.88 + 0.08 * sin(t * 7 + i * 1.7) + 0.04 * sin(t * 13 + i)
        Glow("floorGlow", s[1], s[2] + s[3] * 46, 130, c, (F.lightK or 0.25) * f)
        Glow("floorGlow", s[1], s[2] - 3, 30 * f, c, 0.5 * f)
        Rect("floorRect", s[1] - 6, s[2] + 3.5, 12, 5, IRON, 0.95)
        Rect("floorRect", s[1] - 2, s[2] + 7, 4, 6, IRON_DARK, 0.9)
        Place(Glow("floorGlow", 0, 0, 1, c, 0.95), s[1], s[2] - 4, 13, 24 * f)
        Place(Glow("floorGlow", 0, 0, 1, FLAME, 0.95), s[1], s[2] - 1, 6, 11 * f)
    end
    local g = F.glow
    if g then Glow("floorGlow", CX, CY, g[4], g, g[5]) end
end

-- The doors. Each is the gilded door frame of the Black Temple with its recess opened up, and a portcullis of the
-- temple's own spiked iron (128035) in it: cleared rooms lift it into the wall (0.4 s), walking into a fight drops it
-- with a thud and dust; the vault's is gilded and padlocked until your key turns (the lock pops, then it lifts).
-- A door is drawn in its own coordinates - u along the wall, v out into it (0 = the wall's inner edge) - and turned
-- for its side, so all four sides share one drawing.
local KIT = "Interface\\AddOns\\" .. addonName .. "\\Media\\Illidan\\"   -- (dev/generators/gen_boi_media.py)
local DOOR_FRAME, BARS, PASSAGE = KIT .. "door", KIT .. "bars", KIT .. "passage"
local LOCK = 648430                       -- Interface\PetBattles\PetBattle-LockIcon (the gold padlock)
local doorState, doorRoom = {}, nil       -- dir -> { open (0 shut .. 1 up), lockFx (s since the lock opened), dust }

local function DoorQuad(pool, dir, u0, u1, v0, v1, l, r, t, b)
    local x0, x1, y0, y1
    if dir == "up" then x0, x1, y0, y1 = CX + u0, CX + u1, Y0 - v1, Y0 - v0
    elseif dir == "down" then x0, x1, y0, y1 = CX - u1, CX - u0, Y1 + v0, Y1 + v1
    elseif dir == "left" then x0, x1, y0, y1 = X0 - v1, X0 - v0, CY - u1, CY - u0
    else x0, x1, y0, y1 = X1 + v0, X1 + v1, CY + u0, CY + u1 end
    local tx = Take(pools[pool])
    tx:ClearAllPoints()
    tx:SetPoint("TOPLEFT", screen, "TOPLEFT", x0, -y0)
    tx:SetSize(max(0.1, x1 - x0), max(0.1, y1 - y0))
    l, r, t, b = l or 0, r or 1, t or 0, b or 1          -- (t: the picture's outer edge)
    if dir == "up" then tx:SetTexCoord(l, t, l, b, r, t, r, b)
    elseif dir == "down" then tx:SetTexCoord(r, b, r, t, l, b, l, t)
    elseif dir == "left" then tx:SetTexCoord(r, t, l, t, r, b, l, b)
    else tx:SetTexCoord(l, b, r, b, l, t, r, t) end
    return tx
end

-- a point in a door's coordinates -> the room's
local function DoorPoint(dir, u, v)
    if dir == "up" then return CX + u, Y0 - v elseif dir == "down" then return CX - u, Y1 + v
    elseif dir == "left" then return X0 - v, CY - u else return X1 + v, CY + u end
end

-- the doors' motion, once a frame (in seconds, so it runs the same on any frame rate)
local function UpdateDoors(elapsed)
    if not run or not run.room or run.mode == "floorcard" then return end
    if doorRoom ~= run.room then
        -- a new room: open doors stay up; in a fight they start up and drop
        doorRoom = run.room
        wipe(doorState)
        for _, d in ipairs(E.Doors(run)) do doorState[d.dir] = { open = d.locked and 0 or 1, locked = d.locked } end
    end
    for _, d in ipairs(E.Doors(run)) do
        local st = doorState[d.dir]
        if not st then st = { open = 0 } doorState[d.dir] = st end
        if st.locked and not d.locked then st.lockFx = 0 end    -- the key turned
        st.locked = d.locked
        if st.lockFx then st.lockFx = st.lockFx + elapsed end
        local want = (d.open and (not st.lockFx or st.lockFx > 0.35)) and 1 or 0
        if st.open > want then
            st.open = max(want, st.open - elapsed * 6)
            if st.open == 0 then st.dust = 0.35 end            -- it hit the floor
        elseif st.open < want then
            st.open = min(want, st.open + elapsed * 2.5)
        end
        if st.dust then st.dust = st.dust - elapsed if st.dust <= 0 then st.dust = nil end end
    end
end

local DOOR_TINT = { boss = { 1, 0.62, 0.55 }, treasure = { 1, 0.95, 0.72 }, secret = { 0.8, 0.72, 1 } }

-- a door takes the room's light: the top and bottom walls' stand between two sconces, the side walls' in the dark;
-- a little of the floor's colour in it
local function DoorLight(dir, c)
    local L = run.F.light or WHITE
    local k = (dir == "up" or dir == "down") and 0.78 or 0.6
    return k * c[1] * (0.82 + 0.18 * L[1]), k * c[2] * (0.82 + 0.18 * L[2]), k * c[3] * (0.82 + 0.18 * L[3])
end

local function DrawDoors()
    -- each door, in its own coordinates (u along the wall, v out into it): the next room's floor running in under
    -- the arch and fading into the passage's dark, a light from beyond, the portcullis, the frame over it all
    for _, d in ipairs(E.Doors(run)) do
        local st = doorState[d.dir] or { open = d.open and 1 or 0 }
        local c = DOOR_LIGHT[d.kind] or DOOR_LIGHT.normal
        local fl = DoorQuad("doorFloor", d.dir, -17, 17, -12, 36, 0, 0.21, 0, 0.3)
        if fl.file ~= run.F.floor then fl:SetTexture(run.F.floor) fl.file = run.F.floor end
        local k = (run.F.floorK or 0.5) * 0.8
        fl:SetVertexColor(k, k, k, 1)
        DoorQuad("passage", d.dir, -17, 17, -12, 36)
        if st.open > 0 then
            -- the light of the room beyond, far down the passage, and spilling out onto this room's floor
            local fx, fy = DoorPoint(d.dir, 0, 30)
            Glow("doorGlow", fx, fy, 16, c, (d.kind == "normal" and 0.18 or 0.45) * st.open)
            local sx, sy = DoorPoint(d.dir, 0, -24)
            Glow("floorGlow", sx, sy, 46, c, (d.kind == "normal" and 0.07 or 0.2) * st.open)
        end
        local shut = 1 - st.open
        if shut > 0.01 then
            local bars = DoorQuad("bars", d.dir, -17, 17, 36 - 48 * shut, 36, 0, 1, 1 - shut, 1)
            local r, g, b = DoorLight(d.dir, d.kind == "treasure" and BARS_GOLD or BARS_IRON)
            bars:SetVertexColor(r, g, b, 1)
        end
        local fr = DoorQuad("door", d.dir, -30, 30, -12, 48)
        local r, g, b = DoorLight(d.dir, DOOR_TINT[d.kind] or WHITE)
        fr:SetVertexColor(r, g, b, 1)
        if st.dust then
            local kk = st.dust / 0.35
            for _, u in ipairs({ -12, 0, 12 }) do
                local x, y = DoorPoint(d.dir, u, -8)
                Glow("doorGlow", x, y, 14 + 12 * (1 - kk), { 0.55, 0.45, 0.35 }, 0.5 * kk)
            end
        end
        if d.locked or (st.lockFx and st.lockFx < 0.35) then
            local kk = st.lockFx and st.lockFx / 0.35 or 0
            local x, y = DoorPoint(d.dir, 0, 12)
            Glow("doorGlow", x, y, 20 + 18 * kk, GOLD, 0.3 * (1 - kk) + 0.12)
            local t = Take(pools.doorLock)
            t:SetVertexColor(1, 1, 1, 1 - kk)
            Place(t, x, y, 22 * (1 + 0.6 * kk))
        end
        if d.kind == "boss" then
            local x, y = DoorPoint(d.dir, 0, 42)
            Glow("doorGlow", x, y, 16, { 1, 0.15, 0.1 }, 0.5)
            Icon("doorTop", D.SKULL, x, y, 15, 0.95, false)
        end
    end
end

-- how each kind of stain looks: brightness, alpha, a glow (ADD) over it
local STAIN = { blood = { 1.05, 0.9 }, demon = { 0.5, 0.88, 0.22 }, shadow = { 1, 0.8 }, fire = { 1.2, 0.85, 0.3 },
                undead = { 1.1, 0.55 } }

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
    for _, dc in ipairs(room.decals or {}) do
        -- a stain: one of the four splats (Media/Illidan/splat), mirrored by its seed; it splashes out over the first
        -- 10 frames, stays for 15 s and is gone by 25 s. Fel ichor and embers glow a little; bone dust is thin.
        local a = dc.t < 900 and 1 or max(0, 1 - (dc.t - 900) / 600)
        if a > 0 then
            local sd, look = dc.seed, STAIN[dc.ichor] or STAIN.blood
            local k = min(1, (dc.t + 2) / 10)
            local s = dc.r * 3.2 * (0.55 + 0.45 * (1 - (1 - k) * (1 - k)))
            local l, r = (sd % 4) / 4, (sd % 4 + 1) / 4
            if floor(sd / 4) % 2 == 1 then l, r = r, l end
            local t0, t1 = 0, 1
            if floor(sd / 8) % 2 == 1 then t0, t1 = 1, 0 end
            -- the soak (the floor gone dark and wet under it, a little wider), then the stain itself, the floor's
            -- grain showing through
            for i = 1, 2 do
                local t = Take(pools.splat)
                t:SetTexCoord(l, r, t0, t1)
                local b, al, w = look[1] * (i == 1 and 0.3 or 1), look[2] * (i == 1 and 0.6 or 0.72) * a, i == 1 and 1.08 or 1
                t:SetVertexColor(dc.col[1] * b, dc.col[2] * b, dc.col[3] * b, al)
                Place(t, dc.x, dc.y + 2, s * w, s * 0.82 * w)
            end
            if look[3] then Glow("lowGlow", dc.x, dc.y + 2, dc.r * 1.5, dc.col, look[3] * a) end
        end
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
            Token(b.x, b.y, 13, D.ITEMS.glaive.i, RING.glaive)
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
        if x.kind == "sdemon" then Line("airLine", x.x, x.y, p.x, p.y, 2, RING.shade, 0.5) end
        if x.kind == "dash" or (x.d.ai == "dash" and x.state > 0) then Glow("airGlow", x.x, x.y, x.r * 1.8, FELC, 0.3) end
        local ring = boss and RING.boss or x.kind == "sheep" and WHITE or x.spiritOnly and RING.spirit or RING.foe
        local bob = boss and sin(x.t * 0.05) * 3 or sin(x.t * 0.15) * 1.5
        local lift = x.d.ai == "flit" and 8 or 0
        Token(x.x, x.y + bob, x.r, x.d.i, ring, Opts(x.d.ej, nil, x.flash > 0 and (boss and 0.22 or 0.55) or 0,
                                                     x.spiritOnly and 0.7 or 1, lift))
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
            Token(p.x, p.y, p.r + 3, D.METAMORPH, FELC, Opts(nil, nil, nil, nil, lift))
        else
            Token(p.x, p.y, p.r, CLASS_CIRCLES, c, Opts(nil, run.class, nil, run.spirit and 0.6 or 1, lift))
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
    for _, x in ipairs(run.fx or {}) do
        local k = x.t / x.max
        if x.k == "splash" then
            -- a tear bursts: a fading bloom and four droplets thrown out
            Glow("airGlow", x.x, x.y, x.r * (1.2 + 1.6 * k), x.col, 0.55 * (1 - k))
            for i = 0, 3 do
                local a = (x.x + x.y) * 0.1 + i * pi / 2 + pi / 4
                local dd = x.r * (0.6 + 2.4 * k)
                Disc("airDisc", x.x + cos(a) * dd, x.y + sin(a) * dd, x.r * 0.32 * (1 - k) + 0.4, x.col, 0.9 * (1 - k))
            end
        elseif x.k == "pop" then
            Glow("airGlow", x.x, x.y, x.r * (1 + 1.6 * k), x.col, 0.6 * (1 - k))
            Disc("airDisc", x.x, x.y, x.r * 0.7 * (1 - k), x.col, 1 - k)
        elseif x.k == "die" then
            -- an enemy goes: it flashes white, swells and fades, and bursts into its own colour
            local o = x.o
            local n = o.boss and 14 or 8
            Glow("airGlow", x.x, x.y, x.r * (1.6 + 1.8 * k), x.col, 0.75 * (1 - k) * (1 - k))
            if o.boss then Glow("airGlow", x.x, x.y, x.r * 3 * k + 10, WHITE, 0.5 * (1 - k)) end
            for i = 0, n - 1 do
                local a = i * 2 * pi / n + (x.x * 0.05)
                local dd = x.r * (0.3 + (o.boss and 3.4 or 2.6) * k) * (0.8 + 0.4 * ((i * 7) % 5) / 4)
                Disc("airDisc", x.x + cos(a) * dd, x.y + sin(a) * dd, x.r * 0.2 * (1 - k) + 0.5, x.col, 0.95 * (1 - k))
            end
            if k < 0.6 then
                local kk = k / 0.6
                Token(x.x, x.y, x.r * (1 + 0.35 * kk), o.i, o.ring, { ej = o.ej, alpha = 1 - kk, flash = max(0, 1 - x.t / 6), shadow = false })
            end
        end
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

-- The HUD sits on gilded plates (the cards' moulding, smaller): real frames under the HUD's own layer.
local plates = {}

local function HudPlate(key, x, y, w, h, a)
    local p = plates[key]
    if not p then
        p = CreateFrame("Frame", nil, layers.hudBase)
        p.bg = p:CreateTexture(nil, "BACKGROUND", nil, -6)
        p.bg:SetAllPoints()
        p.bg:SetColorTexture(0.05, 0.04, 0.03, 0.9)
        p.sh = p:CreateTexture(nil, "BACKGROUND", nil, -5)
        p.sh:SetAllPoints()
        p.sh:SetColorTexture(1, 1, 1, 1)
        ns.UI:GradientRGBA(p.sh, "VERTICAL", 0, 0, 0, 0.35, 1, 0.85, 0.5, 0.06)
        if ns.Look and ns.Look.Gilt then
            p.gilt = ns.Look:Gilt(p)
            p.gilt:Show(true, { trim = 2, corner = 9, grain = 0.08 })
        end
        plates[key] = p
    end
    p.used = true
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", screen, "TOPLEFT", x, -y)
    p:SetSize(w, h)
    p:SetAlpha(a or 1)
    p:Show()
    return p
end

-- a healthstone or soul shard: a round gem in a socket; half: its right half dark; empty: the bare socket
local function Gem(x, y, file, ring, fill)
    Disc("hudDisc", x, y, 9.5, BLACK, 0.75)
    if fill > 0 then
        Token(x, y, 8, file, ring, Opts(nil, nil, nil, nil, nil, false))
        if fill == 1 then
            local t = Take(pools.hudHalf)
            t:SetTexCoord(0.5, 1, 0, 1)
            t:SetVertexColor(0, 0, 0, 0.72)
            t:ClearAllPoints()
            t:SetPoint("LEFT", screen, "TOPLEFT", x, -y)
            t:SetSize(8.5, 17)
        end
    else
        Disc("hudDisc", x, y, 7.5, ring, 0.12)
    end
end

local COUNTS, COUNT_KEYS, COUNT_FIELD = { "gold", "bomb", "key" }, { "count1", "count2", "count3" },
                                          { gold = "gold", bomb = "bombs", key = "keys" }

local function DrawHud()
    local keep = pools.token
    pools.token = pools.hudToken
    local ink = INK
    -- left: healthstones and shards over gold, bombs, keys; the active item in its slot at the end
    local gems = run.maxHp + math.ceil(run.soul / 2)
    local pw = max(150, 18 + gems * 21) + (run.active and 40 or 0)
    HudPlate("left", 8, 5, pw, 40)
    local x = 20
    for i = 0, run.maxHp - 1 do
        Gem(x, 16, D.PICKUPS.heart.i, RING.heart, max(0, min(2, run.hp - i * 2)))
        x = x + 21
    end
    local sl = run.soul
    while sl > 0 do
        Gem(x, 16, D.PICKUPS.soul.i, RING.soul, min(2, sl))
        sl, x = sl - 2, x + 21
    end
    for i, k in ipairs(COUNTS) do
        local cx = 18 + (i - 1) * 46
        Icon("hud", D.PICKUPS[k].i, cx, 34, 12, 1, k ~= "gold" and nil or false)
        Label(COUNT_KEYS[i], layers.hud, 11, cx + 9, 34, string.format("%02d", run[COUNT_FIELD[k]]), ink, 1, "LEFT")
    end
    if run.active then
        local it = D.ITEMS[run.active]
        local ax = 8 + pw - 22
        local ready = run.charge >= run.chargeMax
        local slot = Take(pools.hudSlot)
        Place(slot, ax, 22, 28 * 64 / 39)
        if ready then Glow("hudGlow", ax, 22, 22, FELC, 0.35 + 0.15 * sin(run.frame * 0.12)) end
        Icon("hud", it.i, ax, 22, 26, ready and 1 or 0.45)
        for n = 1, run.chargeMax do
            local px = ax - 13 + (n - 0.5) * 26 / run.chargeMax
            Rect("hudBar", px - 26 / run.chargeMax / 2 + 1, 38, 26 / run.chargeMax - 2, 3, n <= run.charge and FELC or { 0.2, 0.2, 0.2 })
        end
    end
    -- what you carry: slots along the bottom wall
    for n, k in ipairs(run.items) do
        local ix = 22 + (n - 1) * 26
        local it = D.ITEMS[k]
        local slot = Take(pools.hudSlot)
        Place(slot, ix, H - 22, 20 * 64 / 39)
        Icon("hud", it.i, ix, H - 22, 20)
        local q = Take(pools.hudQ)
        local qc = D.QUALITY[it.q] or WHITE
        q:SetVertexColor(qc[1], qc[2], qc[3], 0.9)
        Place(q, ix, H - 22, 21)
    end
    if run.daily then
        local txt = run.counted and "TODAY'S DUNGEON" or "PRACTICE"
        local c = run.counted and FELC or { 0.64, 0.59, 0.52 }
        Rect("hudBar", W - 124, H - 32, 112, 18, c, 0.12)
        Rect("hudBar", W - 124, H - 32, 112, 1, c, 0.5)
        Label("daily", layers.hud, 9, W - 68, H - 23, txt, c, 0.95)
    end
    -- the minimap: the floor's rooms you know, the one you are in lit, the boss, the vault and the shop marked
    local minx, miny, maxx, maxy = 9, 9, 0, 0
    for _, r in ipairs(run.map.list) do
        minx, maxx, miny, maxy = min(minx, r.x), max(maxx, r.x), min(miny, r.y), max(maxy, r.y)
    end
    local cols, rows = maxx - minx + 1, maxy - miny + 1
    local cw, ch = min(17, 126 / cols), min(10, 32 / rows)
    local mw, mh = cols * cw + 12, rows * ch + 10
    local mx, my = W - 8 - mw, 5
    HudPlate("map", mx, my, mw, max(40, mh))
    local oy = my + (max(40, mh) - rows * ch) / 2
    for _, r in ipairs(run.map.list) do
        local seen = r.visited
        if not seen and (r.type ~= "secret" or r.revealed) then
            for _, nb in ipairs(E.Neighbours(run.map, r)) do if nb.room.visited then seen = "near" end end
        end
        if seen then
            local rx, ry = mx + 6 + (r.x - minx) * cw, oy + (r.y - miny) * ch
            local here = r == run.room
            Rect("hudMap", rx, ry, cw - 1.5, ch - 1.5, here and GOLD or MAP_EDGE, here and 1 or 0.9)
            Rect("hudMap", rx + 1, ry + 1, cw - 3.5, ch - 3.5, here and MAP_HERE or (seen == true) and MAP_SEEN or MAP_NEAR)
            local ic = (r.type == "boss" and D.SKULL) or (r.type == "treasure" and D.icon("INV_Misc_Key_10"))
                or (r.type == "shop" and D.PICKUPS.gold.i) or nil
            if ic then Icon("hud", ic, rx + cw / 2 - 0.75, ry + ch / 2 - 0.75, min(10, ch + 1), 1, false) end
        end
    end
    -- the boss: a gilded bar over the arena's foot, the portrait in its ring at the left end, the phase after the name
    local boss = run.bossF and run.room.foes[1] and run.bossF
    if boss and boss.hp > 0 then
        local bw, bx, by = 300, CX - 150, Y1 - 34
        HudPlate("boss", bx - 4, by - 4, bw + 8, 20)
        local f = max(0, boss.hp / boss.max)
        local bar = Take(pools.hudStatus)
        bar:SetVertexColor(0.78, 0.13, 0.08, 1)
        bar:SetTexCoord(0, f, 0, 1)
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", screen, "TOPLEFT", bx, -by)
        bar:SetSize(max(0.1, bw * f), 12)
        Rect("hudBar", bx, by, bw * f, 3, WHITE, 0.16)
        Token(bx - 16, by + 6, 15, boss.d.i, IRON_DARK, Opts(boss.d.ej, nil, nil, nil, nil, false))
        local ring = Take(pools.hudRing)
        ring:SetTexCoord(0, 40 / 64, 0, 40 / 64)
        ring:ClearAllPoints()
        ring:SetPoint("CENTER", screen, "TOPLEFT", bx - 16 + 1, -(by + 6 + 1))
        ring:SetSize(43, 43)
        Label("bossName", layers.hud, 11, bx + 6, by - 12, boss.d.n, GOLD, 1, "LEFT")
        if boss.phaseName and boss.phaseName ~= "" then
            Label("bossPhase", layers.hud, 10, bx + bw, by - 12, boss.phaseName, ink, 0.85, "RIGHT")
        end
    end
    if run.cast then
        local cw2, cx0, cy0 = 200, CX - 100, Y1 - 76
        HudPlate("cast", cx0 - 3, cy0 - 3, cw2 + 6, 16)
        Icon("hud", run.cast.icon, cx0 - 14, cy0 + 5, 16)
        local bar = Take(pools.hudStatus)
        local f = run.cast.t / run.cast.max
        bar:SetVertexColor(1, 0.69, 0, 1)
        bar:SetTexCoord(0, f, 0, 1)
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", screen, "TOPLEFT", cx0, -cy0)
        bar:SetSize(max(0.1, cw2 * f), 10)
        Label("castName", layers.hud, 10, CX, cy0 + 5, run.cast.name, WHITE)
    end
    if run.toast then Label("toast", layers.hud, 14, CX, Y1 - 104, run.toast.t, ink) end
    if run.say then
        local yell = run.say.kind == "yell"
        Label("say", layers.hud, 13, CX, 64, yell and (run.say.who .. " yells: " .. run.say.text) or run.say.text,
            yell and { 1, 0.25, 0.25 } or { 1, 0.7, 0.28 }, min(1, run.say.life / 30))
    end
    if run.banner then
        -- an item: its name in its quality over a band with gold edges
        local b = run.banner
        local a = min(1, b.life / 20, (170 - b.life) / 12)
        Rect("hudBack", 0, 76, W, 64, { 0, 0, 0 }, 0.62 * a)
        Rect("hudBack", 0, 76, W, 1, GOLD, 0.45 * a)
        Rect("hudBack", 0, 139, W, 1, GOLD, 0.45 * a)
        Label("bannerN", layers.hud, 26, CX, 99, b.n, D.QUALITY[b.q] or GOLD, a)
        Label("bannerT", layers.hud, 14, CX, 125, b.t, ink, a)
    end
    if run.fade and run.fade > 0 then Rect("hudBack", 0, 0, W, H, { 0, 0, 0 }, run.fade / 14) end
    pools.token = keep
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

-- The cards' frames: real panels in the client's and the addon's own art - a dark ground over the floor's loading
-- screen, the gilded moulding (ns.Look:Gilt: trim, corner studs, grain), a gilded header banner on the top edge - and
-- their content on the layer above (layers.cardTop).
local RING, SLOT, QFRAME = 136430, 130841, 651080
local PLATE_SIZE = 19       -- (in room units, like every text here: the room scales as a whole)
local panels = {}

local function Panel(key, x, y, w, h, art)
    local p = panels[key]
    if not p then
        p = CreateFrame("Frame", nil, layers.card)
        p:SetFrameLevel(layers.card:GetFrameLevel() + 2)
        p.bg = p:CreateTexture(nil, "BACKGROUND", nil, -6)
        p.bg:SetAllPoints()
        p.bg:SetColorTexture(0.055, 0.045, 0.035, 0.97)
        p.art = p:CreateTexture(nil, "BACKGROUND", nil, -4)
        p.art:SetAllPoints()
        p.shade = p:CreateTexture(nil, "BACKGROUND", nil, -3)
        p.shade:SetAllPoints()
        p.shade:SetColorTexture(1, 1, 1, 1)
        ns.UI:GradientRGBA(p.shade, "VERTICAL", 0.03, 0.02, 0.015, 0.96, 0.03, 0.02, 0.015, 0.5)
        if ns.Look and ns.Look.Gilt then
            p.gilt = ns.Look:Gilt(p)
            p.gilt:Show(true, { trim = 3, corner = 14, grain = 0.06 })
        end
        p.plate = CreateFrame("Frame", nil, p)
        p.plate:SetFrameLevel(p:GetFrameLevel() + 4)
        p.plate:SetPoint("CENTER", p, "TOP", 0, 0)
        local pb = p.plate:CreateTexture(nil, "BACKGROUND", nil, -6)
        pb:SetAllPoints()
        pb:SetColorTexture(0.075, 0.06, 0.045, 1)
        local ps = p.plate:CreateTexture(nil, "BACKGROUND", nil, -4)
        ps:SetAllPoints()
        ps:SetColorTexture(1, 1, 1, 1)
        ns.UI:GradientRGBA(ps, "VERTICAL", 0, 0, 0, 0.45, 1, 0.85, 0.5, 0.06)
        if ns.Look and ns.Look.Gilt then
            p.plate.gilt = ns.Look:Gilt(p.plate)
            p.plate.gilt:Show(true, { trim = 3, corner = 12, grain = 0.1 })
        end
        p.title = p.plate:CreateFontString(nil, "OVERLAY")
        p.title:SetFont(FONT, PLATE_SIZE, "OUTLINE")
        p.title:SetShadowOffset(1, -1)
        -- (Friz's capitals sit above the line's middle: one unit down puts the words on the plate's middle)
        p.title:SetPoint("CENTER", p.plate, "CENTER", 0, -1)
        p.buttons = {}
        panels[key] = p
    end
    p.used = true
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", screen, "TOPLEFT", x, -y)
    p:SetSize(w, h)
    if art then
        p.art:SetTexture(LOADING[art] or LOADING.bt)
        local fh = min(0.55, h / w)
        p.art:SetTexCoord(0, 1, 0.26, 0.26 + fh)
        p.art:SetAlpha(0.24)
        p.art:Show()
    else
        p.art:Hide()
    end
    p:Show()
    return p
end

local function Plate(p, text, c, wide)
    if not text then p.plate:Hide() p.title:Hide() return end
    p.plate:SetSize(wide or 250, 38)
    p.plate:Show()
    p.title:SetText(text)
    p.title:SetTextColor(c[1], c[2], c[3])
    p.title:Show()
end

-- a button on a panel: made once, re-labelled and placed each frame
local function PanelButton(p, i, text, kind, x, y, w, onClick, enabled)
    local b = p.buttons[i]
    if not b then
        b = ns.UI:CreateSleekButton(p, text, w, 26, function() if b.onClick then b.onClick() end end, kind)
        p.buttons[i] = b
    end
    b.onClick = onClick
    b:SetText(text)
    b:SetSize(w, 26)
    b:ClearAllPoints()
    b:SetPoint("CENTER", screen, "TOPLEFT", x, -y)
    b:SetEnabled(enabled ~= false)
    b:Show()
    return b
end

local function HideButtons(p) for _, b in ipairs(p.buttons) do b:Hide() end end

-- a portrait in the minimap's gold tracking ring (Interface\Minimap\MiniMap-TrackingBorder: the ring in its top
-- left 40 x 40 of 64, the hole a little up and left of its middle)
local function Portrait(x, y, r, pic, opts)
    Token(x, y, r, pic, { 0.05, 0.04, 0.03 }, opts)
    local t = Take(pools.topRing)
    t:SetTexCoord(0, 40 / 64, 0, 40 / 64)
    t:SetVertexColor(1, 1, 1, opts and opts.alpha or 1)
    local size = r * 2 * 1.42
    t:ClearAllPoints()
    t:SetPoint("CENTER", screen, "TOPLEFT", x + r * 0.07, -(y + r * 0.07))
    t:SetSize(size, size)
end

-- an item in the client's own slot frame, its quality on the border
local function ItemSlot(x, y, k, a)
    local it = D.ITEMS[k]
    local slot = Take(pools.topSlot)
    slot:SetVertexColor(1, 1, 1, a)
    Place(slot, x, y, 26 * 64 / 39)
    Icon("top", it.i, x, y, 26, a)
    local q = Take(pools.topQ)
    local c = D.QUALITY[it.q] or WHITE
    q:SetVertexColor(c[1], c[2], c[3], a)
    Place(q, x, y, 27)
end

-- a stat tile: a dark inset with a hairline on top, the name small, the value big
local function Tile(key, x, y, w, name, value, a, vc)
    Rect("topBack", x, y, w, 46, { 0, 0, 0 }, 0.38 * a)
    Rect("topBack", x, y, w, 1, GOLD, 0.25 * a)
    Label(key .. "n", layers.cardTop, 9, x + 10, y + 13, name:upper(), { 0.64, 0.59, 0.52 }, a, "LEFT")
    Label(key .. "v", layers.cardTop, 18, x + 10, y + 31, value, vc or { 0.95, 0.92, 0.85 }, a, "LEFT")
end

local function Pill(key, x, y, text, c, a)
    local w = 12 + #text * 6.4
    Rect("topBack", x - w / 2, y - 10, w, 20, c, 0.16 * a)
    Rect("topBack", x - w / 2, y - 10, w, 1, c, 0.5 * a)
    Label(key, layers.cardTop, 11, x, y, text, c, a)
end

local function RunItems(r)
    local items = {}
    for _, k in ipairs(r.items) do items[#items + 1] = k end
    if r.active then items[#items + 1] = r.active end
    return items
end

local function Back() run = nil if Board() then Board():Ask() end end

-- the end of a run, died or won: the same panel, its words and colour changed
local function EndPanel(won)
    local t = run.deadT or 99
    if won then t = (run.wonT or 0) end
    local e = 1 - (1 - min(1, t / 20)) ^ 3
    local oy = (1 - e) * 30
    local dim, ink = { 0.64, 0.59, 0.52 }, { 0.95, 0.92, 0.85 }
    local accent = won and FELC or { 0.89, 0.25, 0.2 }
    Rect("card", 0, 0, W, H, { 0, 0, 0 }, 0.62 + 0.2 * e)
    local px, py, pw, ph = CX - 250, 92 + oy, 500, 262
    local p = Panel("end", px, py, pw, ph, run.F.art)
    p:SetAlpha(e)
    Plate(p, won and "The Betrayer falls" or "You died", accent, won and 290 or 230)
    Label("endSub", layers.cardTop, 12, CX, py + 44, string.format("Floor %d of %d  \194\183  %s", run.floorN, #D.FLOORS, run.F.name), ink, e)
    -- who: what killed you, or the Betrayer beaten
    local lx = px + 92
    Label("endBy", layers.cardTop, 9, lx, py + 74, won and "DEFEATED" or "SLAIN BY", dim, e)
    if won then
        Glow("topGlow", lx, py + 128, 62, FELC, 0.35 * e)
        Portrait(lx, py + 128, 34, D.BOSSES.illidan.ej, { ej = true, alpha = e, shadow = false })
        Label("endName", layers.cardTop, 14, lx, py + 182, D.BOSSES.illidan.n, GOLD, e)
    else
        Glow("topGlow", lx, py + 128, 62, { 1, 0.2, 0.15 }, 0.3 * e)
        Portrait(lx, py + 128, 34, run.killerIcon or D.icon("INV_Misc_Bone_HumanSkull_01"), { ej = run.killerEj, alpha = e, shadow = false })
        Label("endName", layers.cardTop, 13, lx, py + 182, tostring(run.killer), GOLD, e)
    end
    Rect("topBack", px + 180, py + 66, 1, 140, GOLD, 0.22 * e)
    -- how far: four tiles
    local seen, all = 0, 0
    for _, r in ipairs(run.map.list) do
        if r.type ~= "secret" then all = all + 1 if r.visited then seen = seen + 1 end end
    end
    local secs = floor(run.time / 60)
    local tx = px + 200
    Tile("endT1", tx, py + 66, 136, "Time", string.format("%d:%02d", floor(secs / 60), secs % 60), e)
    Tile("endT2", tx + 146, py + 66, 136, "Rooms", string.format("%d of %d", seen, all), e)
    Tile("endT3", tx, py + 120, 136, "Kills", tostring(run.kills), e)
    Tile("endT4", tx + 146, py + 120, 136, "Gold", tostring(run.gold), e)
    -- badges
    local bx = tx + 141
    if run.daily and run.counted and Board() then
        for i, row in ipairs(Board():Board(run.daily)) do
            if row.me then Pill("endRank", bx - (run.newBest and 70 or 0), py + 190, string.format("Today: #%d of %d", i, #Board():Board(run.daily)), GOLD, e) end
        end
    elseif run.daily then
        Pill("endRank", bx - (run.newBest and 70 or 0), py + 190, "Practice run", dim, e)
    end
    if run.newBest then Pill("endBest", bx + 80, py + 190, "New best!", FELC, e) end
    -- what you carried
    local items = RunItems(run)
    Rect("topBack", px + 20, py + 210, pw - 40, 1, GOLD, 0.18 * e)
    for n, k in ipairs(items) do ItemSlot(CX - #items * 19 + (n - 1) * 38 + 19, py + 236, k, e) end
    if #items == 0 then Label("endNone", layers.cardTop, 11, CX, py + 236, "No items this run", dim, e) end
    -- the way on: buttons (and their keys), held back a second
    local ready = won or t > 60
    PanelButton(p, 1, run.daily and "Try again  (R)" or "New run  (R)", "primary", CX - 82, py + ph + 26, 150,
        function() UI.SetFocus(true) UI:NewRun(run.daily ~= nil) end, ready)
    PanelButton(p, 2, "Today's board  (Enter)", "secondary", CX + 82, py + ph + 26, 150, function() UI.SetFocus(true) Back() end, ready)
end

local function DrawCards()
    local cf = layers.cardTop
    local keep = pools.token
    pools.token = pools.cardToken
    layers.cardArt:Hide()
    layers.cardShade:Hide()
    if run.mode == "floorcard" then
        local k = run.cardT
        local a = min(1, k / 20, (150 - k) / 15 + 0.2)
        Rect("card", 0, 0, W, H, { 0, 0, 0 }, a)
        CardArt(run.F.art, a)
        Label("cardSub", cf, 13, CX, H - 122, string.format("FLOOR %d OF %d", run.floorN, #D.FLOORS), FELC, a)
        Rect("topBack", CX - 150, H - 108, 300, 1, GOLD, 0.45 * a)
        Label("cardTitle", cf, 34, CX, H - 82, run.F.name, GOLD, a)
        Rect("topBack", CX - 150, H - 58, 300, 1, GOLD, 0.45 * a)
    elseif run.mode == "vs" then
        local f = run.bossF
        local k = 1 - run.cardT / 110
        local off = max(0, 1 - k * 4) * 300
        Rect("card", 0, 0, W, H, { 0, 0, 0 }, 0.72)
        local p = Panel("vs", -10, 110, W + 20, 210, run.F.art)
        Plate(p, nil)
        HideButtons(p)
        pools.token = pools.topToken
        Glow("topGlow", 170 - off, CY - 4, 90, run.cdef.tear, 0.3)
        Portrait(170 - off, CY - 4, 50, CLASS_CIRCLES, { cls = run.class, shadow = false })
        Glow("topGlow", W - 190 + off, CY - 14, 120, f.boss.glow, 0.35)
        Portrait(W - 190 + off, CY - 14, 66, f.d.i, { ej = f.d.ej, shadow = false })
        Label("vsMe", cf, 18, 170 - off, CY + 66, UnitName and UnitName("player") or "You", ClassColor(run.class))
        Label("vsBoss", cf, 24, W - 190 + off, CY + 78, f.d.n, GOLD)
        Label("vsVs", cf, 44, CX, CY - 8, "VS", { 1, 0.23, 0.18 }, min(1, k * 3))
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
    elseif run.mode == "dead" or run.mode == "won" then
        pools.token = pools.topToken
        EndPanel(run.mode == "won")
    end
    pools.token = keep
end

-- The title screen's logo (Games/HubUI.lua's, art pack 14), made once; nil until then or without its art.
local titleLogo, titleLogoTried

local function DrawTitle()
    local keep = pools.token
    pools.token = pools.topToken
    local dim, ink = { 0.64, 0.59, 0.52 }, { 0.95, 0.92, 0.85 }
    local cf = layers.cardTop
    Rect("card", 0, 0, W, H, { 0, 0, 0 }, 1)
    CardArt("bt", 0.55)
    if not titleLogoTried then
        titleLogoTried = true
        titleLogo = ns.GamesUI and ns.GamesUI.CreateLogo and ns.GamesUI:CreateLogo(cf, "illidan", 1.15)
    end
    if titleLogo then
        titleLogo:ClearAllPoints()
        titleLogo:SetPoint("CENTER", screen, "TOPLEFT", CX, -52)
        titleLogo:Show()
        Label("tSub", cf, 13, CX, 98, "Five floors of the Black Temple. The bosses fight like the raid.", { 0.85, 0.81, 0.75 })
    else
        Label("tTitle", cf, 34, CX, 48, "The Binding of Illidan", GOLD)
        Label("tSub", cf, 13, CX, 78, "Five floors of the Black Temple. The bosses fight like the raid.", { 0.85, 0.81, 0.75 })
    end
    -- you
    local cls = UI.Class()
    local c = D.CLASSES[cls]
    local lx = 176
    Glow("topGlow", lx, 178, 70, c.tear, 0.35)
    Portrait(lx, 178, 38, CLASS_CIRCLES, { cls = cls, shadow = false })
    Label("tClass", cf, 18, lx, 240, LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls] or cls, ClassColor(cls))
    Label("tStats", cf, 11, lx, 262, string.format("%s  \194\183  %d healthstones%s", c.bolt, c.hp,
        (c.soul or 0) > 0 and string.format(" + %d shard", c.soul / 2) or ""), dim)
    Label("tNote", cf, 11, lx, 280, c.note, dim)
    Label("tBest", cf, 11, lx, 306, Game() and Game():BestLine() or "", dim)
    -- today's dungeon and the guild's board for it, in a gilded panel under the dialog plate
    local B = Board()
    local bx, by, bw, bh = 352, 128, 336, 214
    local p = Panel("board", bx, by, bw, bh, nil)
    Plate(p, "Today's dungeon", GOLD, 250)
    Label("tDay", cf, 10, bx + bw / 2, by + 34, B and B:Today() or "", dim)
    local list = B and B:Board() or {}
    if #list == 0 then
        Label("tEmpty", cf, 12, bx + bw / 2, by + 110, "Nobody has tried it yet.", dim)
        Label("tEmpty2", cf, 11, bx + bw / 2, by + 130, "The same dungeon for the whole guild, one try a day.", dim)
    end
    for i = 1, min(7, #list) do
        local row = list[i]
        local y = by + 58 + (i - 1) * 22
        if row.me then Rect("topBack", bx + 6, y - 10, bw - 12, 20, FELC, 0.1) end
        if i % 2 == 0 then Rect("topBack", bx + 6, y - 10, bw - 12, 20, { 1, 1, 1 }, 0.025) end
        Label("tRk" .. i, cf, 11, bx + 24, y, tostring(i), i == 1 and GOLD or dim, 1, "RIGHT")
        Token(bx + 40, y, 8, CLASS_CIRCLES, { 0, 0, 0 }, { cls = row.e.c, shadow = false })
        Label("tNm" .. i, cf, 12, bx + 54, y, row.name, ClassColor(row.e.c), 1, "LEFT")
        Label("tRs" .. i, cf, 11, bx + bw - 14, y, B:ResultText(row.e), row.e.w and FELC or ink, 1, "RIGHT")
    end
    -- the way in
    local tried = B and B:Tried()
    PanelButton(p, 1, tried and "Today's dungeon again  (Enter)" or "Today's dungeon  (Enter)", "primary", CX - 96, H - 40, 200,
        function() UI.SetFocus(true) UI:NewRun(true) end)
    PanelButton(p, 2, "Random dungeon  (N)", "secondary", CX + 116, H - 40, 160, function() UI.SetFocus(true) UI:NewRun(false) end)
    Label("tGo", cf, 11, CX, H - 14, not focused and "Click the game to play with the keyboard"
        or (tried and "Your try today is spent: this one is practice." or "Your first try today goes on the guild's board."), not focused and FELC or dim)
    pools.token = keep
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

local attract = false        -- (drawing the poster's view: the room only)

local function Draw()
    Begin()
    hud.used = hud.used or {}
    wipe(hud.used)
    for _, p in pairs(panels) do p.used = false end
    for _, p in pairs(plates) do p.used = false end
    if not run then
        DrawTitle()
    else
        if run.mode ~= "floorcard" then
            DrawStatic()
            DrawDoors()
            DrawFloorThings()
            DrawActors()
            if not attract then DrawHud() end
        end
        if not attract then DrawCards() end
        if not focused and run.mode == "play" and not attract then
            Rect("card", 0, 0, W, H, { 0, 0, 0 }, 0.6)
            Label("paused", layers.card, 24, CX, CY, "Paused \194\183 click to play", GOLD)
        end
    end
    Finish()
    for k, fs in pairs(hud) do
        if k ~= "used" and not hud.used[k] then fs:Hide() end
    end
    for _, p in pairs(panels) do if not p.used then p:Hide() end end
    for _, p in pairs(plates) do if not p.used then p:Hide() end end
    if titleLogo and run then titleLogo:Hide() end
    layers.static:SetShown(run ~= nil and run.mode ~= "floorcard")
    if attract then return end
    local shake = run and run.shake and run.shake > 0 and run.mode == "play"
    screen:ClearAllPoints()
    screen:SetPoint("CENTER", root, "CENTER", shake and (run.frame % 4 < 2 and 3 or -3) or 0, 0)
    layers.surround:SetShown(run ~= nil and run.mode ~= "floorcard")
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
    UpdateDoors(elapsed)
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
    local sc = max(0.3, min(w / W, h / H))
    screen:SetScale(sc)
    -- the surround: the wall texture over the whole panel, its tiles in step with the room's (128 room units a tile,
    -- counted from the room's top left corner, which sits centred in the panel)
    local tile = 128 * sc
    local ox, oy = (w - W * sc) / 2, (h - H * sc) / 2
    layers.surround:SetTexCoord(-ox / tile, (w - ox) / tile, -oy / tile, (h - oy) / tile)
end

-- Views: the panel and the hub's poster each draw with this file's functions, into their own frames and pools.
-- Capture keeps a view's state, Use puts one back.
local function Capture()
    return { root = root, screen = screen, layers = layers, pools = pools, hud = hud, run = run, focused = focused,
             doorState = doorState, doorRoom = doorRoom, panels = panels, plates = plates }
end
local function Use(v)
    root, screen, layers, pools, hud, run, focused = v.root, v.screen, v.layers, v.pools, v.hud, v.run, v.focused
    doorState, doorRoom, panels, plates = v.doorState, v.doorRoom, v.panels, v.plates
end

local function BuildScreen(parent)
    root = CreateFrame("Frame", nil, parent)
    root:SetAllPoints()
    local bg = root:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 1)
    layers = {}
    layers.surround = root:CreateTexture(nil, "BACKGROUND", nil, -7)
    layers.surround:SetAllPoints()
    layers.surround:SetVertexColor(0.3, 0.3, 0.3)      -- (the far wall, in the dark)
    layers.surround:Hide()
    screen = CreateFrame("Frame", nil, root)
    screen:SetSize(W, H)
    screen:SetPoint("CENTER")
    screen:SetClipsChildren(true)
    local lv = root:GetFrameLevel()
    for i, k in ipairs({ "static", "low", "act", "air", "hud", "card" }) do
        local f = CreateFrame("Frame", nil, screen)
        f:SetAllPoints()
        f:SetFrameLevel(lv + i * 3)
        layers[k] = f
    end
    layers.hudBase = CreateFrame("Frame", nil, screen)      -- (the HUD's plates: over the air, under the HUD's words)
    layers.hudBase:SetAllPoints()
    layers.hudBase:SetFrameLevel(lv + 13)
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
        t:SetVertexColor(0.62, 0.62, 0.62)
        layers.walls[#layers.walls + 1] = t
    end
    -- the walls' faces: darker away from the room (Gradient: VERTICAL runs bottom -> top, HORIZONTAL left -> right)
    for _, s in ipairs({ { "VERTICAL", 0, 0, W, Y0, 0, 0.7 }, { "VERTICAL", 0, Y1, W, H - Y1, 0.7, 0 },
                         { "HORIZONTAL", 0, Y0, X0, Y1 - Y0, 0.7, 0 }, { "HORIZONTAL", X1, Y0, W - X1, Y1 - Y0, 0, 0.7 } }) do
        local t = st:CreateTexture(nil, "BACKGROUND", nil, 3)
        t:SetPoint("TOPLEFT", s[2], -s[3])
        t:SetSize(s[4], s[5])
        t:SetColorTexture(1, 1, 1, 1)
        ns.UI:GradientRGBA(t, s[1], 0, 0, 0, s[6], 0, 0, 0, s[7])
    end
    for _, y in ipairs({ Y0 - 14, Y1 - 10 }) do
        local t = st:CreateTexture(nil, "BORDER", nil, 0)
        t:SetTexture(D.TRIM, "REPEAT", "CLAMP")
        t:SetPoint("TOPLEFT", 0, -y)
        t:SetSize(W, 24)
        if y < CY then t:SetTexCoord(0, W / 96, 0.5, 1) else t:SetTexCoord(0, W / 96, 0, 0.5) end
        -- (the bottom trim faces away from the light)
        if y < CY then t:SetAlpha(0.85) else t:SetVertexColor(0.24, 0.24, 0.24) t:SetAlpha(0.9) end
    end
    -- a lit lip along the top wall's foot, catching the room's light
    local lip = st:CreateTexture(nil, "BORDER", nil, 2)
    lip:SetPoint("TOPLEFT", X0, -(Y0 - 5))
    lip:SetSize(X1 - X0, 5)
    lip:SetColorTexture(1, 1, 1, 1)
    ns.UI:GradientRGBA(lip, "VERTICAL", 1, 0.85, 0.6, 0, 1, 0.85, 0.6, 0.16)
    -- the walls' shadows on the floor: deep under the top wall (it stands over the floor), shallow at the foot
    for _, s in ipairs({ { "VERTICAL", X0, Y0, X1 - X0, 54, true, 0.8 }, { "VERTICAL", X0, Y1 - 18, X1 - X0, 18, false, 0.45 },
                         { "HORIZONTAL", X0, Y0, 34, Y1 - Y0, false, 0.65 }, { "HORIZONTAL", X1 - 34, Y0, 34, Y1 - Y0, true, 0.65 } }) do
        local t = st:CreateTexture(nil, "BORDER", nil, 1)
        t:SetPoint("TOPLEFT", s[2], -s[3])
        t:SetSize(s[4], s[5])
        t:SetColorTexture(1, 1, 1, 1)
        if s[6] then ns.UI:GradientRGBA(t, s[1], 0, 0, 0, 0, 0, 0, 0, s[7]) else ns.UI:GradientRGBA(t, s[1], 0, 0, 0, s[7], 0, 0, 0, 0) end
    end
    -- the vignette: the floor darkening towards its corners (Media/Illidan/vignette)
    local vig = st:CreateTexture(nil, "BORDER", nil, 3)
    vig:SetTexture(KIT .. "vignette")
    vig:SetPoint("TOPLEFT", X0, -Y0)
    vig:SetSize(X1 - X0, Y1 - Y0)
    vig:SetAlpha(0.4)           -- (gentle: enemies and shots by the walls stay easy to see)
    -- pools by layer: the low layer (on the floor), the actors, the air (tears, shots, beams), the HUD, the cards
    pools.floorRect = NewPool(st, "tex", "ARTWORK", 0)
    pools.floorGlow = NewPool(st, "tex", "ARTWORK", 1, "ADD", RADIAL)
    pools.doorFloor = NewPool(st, "tex", "ARTWORK", 1)
    pools.passage = NewPool(st, "tex", "ARTWORK", 2, nil, PASSAGE)
    pools.doorGlow = NewPool(st, "tex", "ARTWORK", 3, "ADD", RADIAL)
    pools.bars = NewPool(st, "tex", "ARTWORK", 4, nil, BARS)
    pools.door = NewPool(st, "tex", "ARTWORK", 5, nil, DOOR_FRAME)
    pools.doorLock = NewPool(st, "tex", "OVERLAY", 0, nil, LOCK)
    pools.doorTop = NewPool(st, "tex", "OVERLAY", 1)
    pools.lowGlow = NewPool(layers.low, "tex", "BACKGROUND", 0, "ADD", RADIAL)
    pools.splat = NewPool(layers.low, "tex", "BACKGROUND", -1, nil, KIT .. "splat")
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
    pools.hudDisc = NewPool(layers.hud, "tex", "BORDER", 2, nil, CIRCLE)
    pools.hudHalf = NewPool(layers.hud, "tex", "OVERLAY", 2, nil, CIRCLE)
    pools.hudGlow = NewPool(layers.hud, "tex", "BORDER", 3, "ADD", RADIAL)
    pools.hudSlot = NewPool(layers.hud, "tex", "BORDER", 4, nil, SLOT)
    pools.hudQ = NewPool(layers.hud, "tex", "ARTWORK", 3, nil, QFRAME)
    pools.hudRing = NewPool(layers.hud, "tex", "OVERLAY", 3, nil, RING)
    pools.hudStatus = NewPool(layers.hud, "tex", "BORDER", 5, nil, "Interface\\TargetingFrame\\UI-StatusBar")
    pools.hudToken = { frame = layers.hud, kind = "token", items = {}, n = 0 }
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
    layers.cardTop = CreateFrame("Frame", nil, screen)
    layers.cardTop:SetAllPoints()
    layers.cardTop:SetFrameLevel(layers.card:GetFrameLevel() + 8)
    pools.topBack = NewPool(layers.cardTop, "tex", "BACKGROUND", 0)
    pools.topGlow = NewPool(layers.cardTop, "tex", "BORDER", 0, "ADD", RADIAL)
    pools.topSlot = NewPool(layers.cardTop, "tex", "ARTWORK", 0, nil, SLOT)
    pools.top = NewPool(layers.cardTop, "tex", "ARTWORK", 1)
    pools.topQ = NewPool(layers.cardTop, "tex", "ARTWORK", 2, nil, QFRAME)
    pools.topRing = NewPool(layers.cardTop, "tex", "OVERLAY", 7, nil, RING)
    pools.topToken = { frame = layers.cardTop, kind = "token", items = {}, n = 0 }
end

function UI:CreatePanel(parent)
    BuildScreen(parent)
    root:EnableMouse(true)
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

-- The hub's poster: a second view, playing demo scenes. :Tick(elapsed) steps and draws it; it is drawn only while
-- the poster is in front (the hub ticks front covers only).
function UI:NewAttract(parent)
    local main = Capture()
    pools, hud, panels, plates, doorState, doorRoom, run, focused = {}, {}, {}, {}, {}, nil, nil, true
    BuildScreen(parent)
    root:EnableMouse(false)
    layers.surround:Hide()
    -- the camera moves an unscaled carrier, the room hangs from its middle (an offset on the scaled room itself
    -- would be in the room's units)
    local rig = CreateFrame("Frame", nil, root)
    rig:SetSize(1, 1)
    rig:SetPoint("CENTER")
    screen:ClearAllPoints()
    screen:SetPoint("CENTER", rig, "CENTER")
    local a = { view = Capture(), acc = 0, cam = 0, fade = 0, rig = rig }
    Use(main)
    local function Scene()
        a.scene = ns.BoIAttract.NewScene(UI.Class())
        a.view.run, a.view.doorRoom, a.fade = a.scene.run, nil, 0
    end
    function a:Tick(elapsed)
        local keep = Capture()
        Use(self.view)
        if not self.scene then Scene() run = self.view.run end
        self.acc = min(self.acc + elapsed, STEP * 4)
        while self.acc >= STEP do
            self.acc = self.acc - STEP
            E.Step(run, ns.BoIAttract.Input(run))
            if run.mode == "floorcard" or run.mode == "vs" then run.mode = "play" end
        end
        self.scene.left = self.scene.left - elapsed
        self.fade = min(1, self.fade + elapsed * 2)
        UpdateDoors(elapsed)
        attract = true
        Draw()
        attract = false
        -- the camera: the room fills the poster's height; across, it follows you (eased), never past the walls
        local w, h = root:GetWidth() or 0, root:GetHeight() or 0
        if w < 50 then w = 300 end   -- (a frame sized by its anchors can read 0 before it is laid out: the poster's width)
        if h < 50 then h = 320 end
        local sc = max(0.2, h / H)
        screen:SetScale(sc)
        local span = max(0, (W * sc - w) / 2)
        local want = -(run.p.x - CX) * sc
        self.cam = self.cam + (max(-span, min(span, want)) - self.cam) * min(1, elapsed * 3)
        self.rig:ClearAllPoints()
        self.rig:SetPoint("CENTER", root, "CENTER", self.cam, 0)
        -- the scene's end: fade out over its last half second, then the next
        root:SetAlpha(min(self.fade, max(0, self.scene.left * 2)))
        self.view = Capture()
        if self.scene.left <= 0 or run.mode == "won" then
            Use(self.view)
            Scene()
        end
        Use(keep)
    end
    return a
end

-- (tests and the audit)
function UI._Run() return run end
function UI._SetRun(r) run = r end
function UI._Focus(on) SetFocus(on) end
function UI._Draw() Draw() end
function UI._Key(key, up) if up then OnKeyUp(root, key) else OnKeyDown(root, key) end end
function UI._Pools() return pools end
function UI._Hud() return hud end

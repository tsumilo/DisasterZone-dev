if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/UIKit.lua", ...) then return end -- DisasterZone Games/Disastercraft/UIKit.lua
-- ns.CraftUI: Disastercraft's interface - World of Warcraft's own, built from the client's classic interface art
-- (Interface\TargetingFrame, MainMenuBar, Buttons, QuestFrame, ...) and its fonts. This file: the shared kit (frames,
-- texts, buttons, item and spell buttons, tooltips, sounds); UIWorld draws the map, UIHud the frames on it,
-- UIWindows the windows, UIGlue the character screens, UIMain wires it together.
local addonName, ns = ...

local UI = ns:NewModule("CraftUI")
local Craft = ns.Craft
local D = Craft.D
UI.Kit = {}
local K = UI.Kit

local floor, max, min = math.floor, math.max, math.min

K.MEDIA = "Interface\\AddOns\\DisasterZone\\Media\\Azeromon\\"
K.WHITE = "Interface\\Buttons\\WHITE8X8"
K.BACKDROP = { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
               tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } }
K.TOOLTIP_BACKDROP = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                       tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } }

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

function K.Frame(parent, w, h, backdrop, level)
    local f = CreateFrame("Frame", nil, parent, BACKDROP_TEMPLATE)
    if w then f:SetSize(w, h) end
    if backdrop and f.SetBackdrop then
        f:SetBackdrop(backdrop)
        if backdrop == K.TOOLTIP_BACKDROP then
            f:SetBackdropColor(0, 0, 0, 0.85)
            f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        end
    end
    if level then f:SetFrameLevel(level) end
    return f
end

---------------------------------------------------------------------------
-- The pixel body in a frame: the character screens, the character sheet and every portrait show the same
-- sprite as the map (its gear layers for a hero), scaled up with crisp pixels.
---------------------------------------------------------------------------

-- a body's cell on the model sheets -> file, l, r, t, b: walk frame 0-2 on mobs*.blp, or action column `act`
-- (0 wind-up, 1 strike, 2 ready, 3 release, 4 dead, 5 seated) on mobs_act*.blp
function K.BodyCoords(spr, face, frame, act)
    local A = ns.AzeroData or {}
    local H, per, nf = A.MOB_SHEET_H or 2048, A.MOB_PER_SHEET or 1e9, A.MOB_FACES or 4
    local k = floor(spr / per)
    spr = spr - k * per
    local row = floor(spr / 5) * nf + Craft.FaceRow(face, nf)
    local t, b = row * 32 / H, (row + 1) * 32 / H
    local file = K.MEDIA .. (act and "mobs_act" or "mobs") .. (k > 0 and ("_" .. k) or "") .. ".blp"
    if act then
        local c = (spr % 5) * 6 + act
        return file, c * 32 / 1024, (c + 1) * 32 / 1024, t, b
    end
    local c = (spr % 5) * 3 + (frame or 1)
    return file, c * 32 / 512, (c + 1) * 32 / 512, t, b
end

-- the sheet index of whoever `who` is: a unit (UI.SpriteOf), a saved character { class, sex }, or { spr = n }
local function SprOf(who)
    if who.spr then return who.spr end
    if who.guid and UI.SpriteOf then return UI.SpriteOf(who) end
    local spr = ns.AzeroData and ns.AzeroData.CLASS_SPR
    return spr and spr[(Craft.CLASS_TOKENS[who.class] or "WARRIOR") .. (who.sex or 0)] or 0
end
K.SprOf = SprOf

-- the pictures that make up `who` in one frame, bottom first: { { file, l, r, t, b, x, y, w, h }, ... } with x, y,
-- w, h in the 32 px cell. A hero with gear: the bare body and its gear layers (Outfit.lua); else the sheet's cell.
-- kind "walk" (col 0-2) or "act" (col as K.BodyCoords' act)
function K.BodyLayers(who, kind, col, face)
    if not who then return {} end
    local c = who.char or who
    local hero = who.kind == "player" or who.kind == "remote" or (who.class and not who.guid)
    if hero and c.equip and UI.OutfitLayers and not (kind == "act" and col == 5) then
        local got = UI.OutfitLayers(who, kind, col, face)
        if got and got[1] then return got end
    end
    local file, l, r, t, b = K.BodyCoords(SprOf(who), face, kind ~= "act" and col or nil, kind == "act" and col or nil)
    return { { file, l, r, t, b, 0, 0, 32, 32 } }
end

-- K.Sprite(parent, w, h): a frame showing a body. :SetWho(who) (a unit, a saved character or { spr = n }),
-- :SetPose(face, kind, col), :SetCrop(x0, y0, x1, y1) (the part of the 32 px cell to fit in the frame; default
-- the whole cell), :SetRound(true) (cut round, as a portrait). The pixels stay crisp (NEAREST filtering).
local function PaintSprite(f)
    for _, t in ipairs(f.tex) do t:Hide() end
    if not f.who then return end
    local host, at = f.host or f, f.anchor or f
    local w, h = f.w or at:GetWidth(), f.h or at:GetHeight()
    if not w or w < 2 then w, h = 64, 64 end
    local x0, y0, x1, y1 = f.crop[1], f.crop[2], f.crop[3], f.crop[4]
    local k = min(w / max(1, x1 - x0), h / max(1, y1 - y0))
    if f.intScale and k >= 2 then k = floor(k) end            -- (whole pixels: every sprite pixel the same size)
    local ox, oy = (w - (x1 - x0) * k) / 2, (h - (y1 - y0) * k)          -- (centred, standing on the bottom)
    if f.round then oy = (h - (y1 - y0) * k) / 2 end
    for i, L in ipairs(K.BodyLayers(f.who, f.kind, f.col, f.face)) do
        local t = f.tex[i]
        if not t then
            t = host:CreateTexture(nil, f.layer or "ARTWORK", nil, min(7, (f.sub or 0) + i - 1))
            if f.mask then t:AddMaskTexture(f.mask) end
            f.tex[i] = t
        end
        if t.file ~= L[1] then
            if not pcall(t.SetTexture, t, L[1], "CLAMP", "CLAMP", "NEAREST") then t:SetTexture(L[1]) end
            t.file = L[1]
        end
        t:SetTexCoord(L[2], L[3], L[4], L[5])
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", at, "TOPLEFT", ox + (L[6] - x0) * k, -(oy + (L[7] - y0) * k))
        t:SetSize(max(1, L[8] * k), max(1, L[9] * k))
        t:SetVertexColor(f.cr or 1, f.cg or 1, f.cb or 1)
        t:Show()
    end
end

function K.Sprite(parent, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    f.w, f.h = w, h
    pcall(f.SetClipsChildren, f, true)
    f.tex, f.crop = {}, { 0, 0, 32, 32 }
    f.face, f.kind, f.col = "down", "walk", 1
    function f:SetWho(who) self.who = who PaintSprite(self) end
    function f:SetPose(face, kind, col)
        self.face, self.kind, self.col = face or self.face, kind or self.kind, col or self.col
        PaintSprite(self)
    end
    function f:SetCrop(a, b, c, d) self.crop = { a, b, c, d } PaintSprite(self) end
    function f:SetBox(w2, h2) self.w, self.h = w2, h2 self:SetSize(w2, h2) PaintSprite(self) end
    function f:SetTint(r, g, b) self.cr, self.cg, self.cb = r, g, b PaintSprite(self) end
    function f:SetRound(on)
        self.round = on
        local host = self.host or self
        if on and not self.mask and host.CreateMaskTexture then
            local m = host:CreateMaskTexture()
            m:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            m:SetAllPoints(self.anchor or self)
            self.mask = m
            for _, t in ipairs(self.tex) do t:AddMaskTexture(m) end
        end
        PaintSprite(self)
    end
    f.Repaint = PaintSprite
    return f
end

-- the facings in turning order (a quarter-turn is two steps)
K.RING = { "down", "downleft", "left", "upleft", "up", "upright", "right", "downright" }

-- makes K.Sprite sv turn like the client's character model: sv:Turn(steps) one facing a step; dragging across it
-- (unless noMouse: the caller forwards drags with sv:Drag(dx px)) turns a facing every 24 px; auto: it turns on
-- its own, a facing a second, resting facing you, until you drag it
function K.Turntable(sv, auto, noMouse)
    sv.ring, sv.auto, sv.idle, sv.spin, sv.acc = 1, auto, 0, 0, 0
    function sv:Turn(d)
        self.ring = (self.ring - 1 + d) % #K.RING + 1
        self:SetPose(K.RING[self.ring])
    end
    function sv:Drag(dx)
        self.idle, self.acc = 0, self.acc + dx
        while self.acc >= 24 do self.acc = self.acc - 24 self:Turn(1) end
        while self.acc <= -24 do self.acc = self.acc + 24 self:Turn(-1) end
    end
    function sv:Face(face)
        for i, f in ipairs(K.RING) do if f == face then self.ring = i end end
        self:SetPose(face)
    end
    if not noMouse then
        sv:EnableMouse(true)
        sv:SetScript("OnMouseDown", function(self) self.dragX = GetCursorPosition() end)
        sv:SetScript("OnMouseUp", function(self) self.dragX = nil end)
    end
    sv:SetScript("OnUpdate", function(self, el)
        if self.dragX then
            local x = GetCursorPosition()
            self:Drag((x - self.dragX) / max(0.01, self:GetEffectiveScale() or 1))
            self.dragX = x
            return
        end
        if not self.auto then return end
        self.idle = self.idle + el
        if self.idle < 5 then return end                    -- (left alone a while after a drag)
        self.spin = self.spin + el
        if self.spin >= (self.ring == 1 and 2.6 or 0.9) then
            self.spin = 0
            self:Turn(1)
        end
    end)
    sv.idle = 5
end

-- a portrait's crop: the head and shoulders of the standing body facing you (D.BOX: its opaque box), a square
local function PortraitCrop(who)
    local box = ns.AzeroData and ns.AzeroData.BOX and ns.AzeroData.BOX[SprOf(who)]
    local x0, y0, x1, y1 = 3, 1, 29, 31
    if box then x0, y0, x1, y1 = box[1], box[2], box[3], box[4] end
    local w, h = x1 - x0, y1 - y0
    local s = max(8, min(w, h, h > w * 1.4 and h * 0.55 or h))          -- (a person: the top half; a beast: all)
    s = max(s, min(w, 18))
    local cx = (x0 + x1) / 2
    return cx - s / 2, y0 - 1, cx + s / 2, y0 - 1 + s
end

-- the pixel portrait of `who` in place of texture t (a unit frame's or a window's round portrait): drawn in t's
-- own frame and draw layer just over it, so the frame's ring art stays on top; cut round. t itself becomes the
-- dark disc behind the body. who nil: just the disc.
function K.SpritePortrait(t, who)
    local sv = t.dzSprite
    if not sv then
        local layer, sub = t:GetDrawLayer()
        sv = K.Sprite(t:GetParent(), 1, 1)
        sv:Hide()
        sv.host, sv.anchor, sv.layer, sv.sub = t:GetParent(), t, layer or "BACKGROUND", min(6, (sub or 0) + 1)
        sv.w, sv.h = nil, nil
        sv:SetRound(true)
        t.dzSprite = sv
    end
    t:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    t:SetTexCoord(0, 1, 0, 1)
    t:SetVertexColor(0.1, 0.09, 0.08)
    sv.who = who
    if who then
        local a, b, c, d = PortraitCrop(who)
        sv.crop = { a, b, c, d }
        sv.face, sv.kind, sv.col = "down", "walk", 1
    end
    sv:Repaint()
end

function K.Tex(parent, layer, file, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
    if file then t:SetTexture(file) end
    return t
end

-- WoW's fonts by their font objects (GameFontNormal = gold Friz Quadrata, Highlight = white, ...)
function K.Text(parent, font, layer, justify)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontNormal")
    if not fs:GetFont() then fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "") end
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

-- a font string with an explicit size (Friz Quadrata), outlined when asked
function K.Font(parent, size, flags, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size or 12, flags or "")
    return fs
end

-- the red-and-gold panel button (UIPanelButtonTemplate)
function K.Button(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 100, h or 22)
    b:SetText(text or "")
    if onClick then
        b:SetScript("OnClick", function(self, button)
            if PlaySound then pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION or 852) end
            onClick(self, button)
        end)
    end
    return b
end

function K.CloseButton(parent, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    b:SetPoint("TOPRIGHT", -4, -4)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

-- a window with WoW's dialog border, a title bar and a close button
function K.Window(parent, w, h, title, onClose)
    local f = K.Frame(parent, w, h, K.BACKDROP)
    f:EnableMouse(true)
    f:SetFrameStrata("HIGH")
    f.title = K.Text(f, "GameFontNormal")
    f.title:SetPoint("TOP", 0, -16)
    f.title:SetText(title or "")
    local hdr = K.Tex(f, "ARTWORK", "Interface\\DialogFrame\\UI-DialogBox-Header")
    hdr:SetSize(max(180, w * 0.6), 64)
    hdr:SetPoint("TOP", 0, 12)
    f.header = hdr
    f.title:ClearAllPoints()
    f.title:SetPoint("TOP", hdr, "TOP", 0, -14)
    f.close = K.CloseButton(f, function() if onClose then onClose() else f:Hide() end end)
    f:Hide()
    return f
end

-- a status bar (health, mana, xp, cast)
function K.Bar(parent, w, h, r, g, b, tex)
    local s = CreateFrame("StatusBar", nil, parent)
    s:SetSize(w, h)
    s:SetStatusBarTexture(tex or "Interface\\TargetingFrame\\UI-StatusBar")
    s:SetStatusBarColor(r or 0, g or 1, b or 0)
    s:SetMinMaxValues(0, 1)
    s:SetValue(1)
    s.text = K.Font(s, max(8, floor(h * 0.75)), "OUTLINE")
    s.text:SetPoint("CENTER", 0, 1)
    s.bg = K.Tex(s, "BACKGROUND")
    s.bg:SetAllPoints()
    s.bg:SetColorTexture(0, 0, 0, 0.5)
    return s
end

---------------------------------------------------------------------------
-- Item and spell buttons (the square slot with the icon, the count, the cooldown swirl)
---------------------------------------------------------------------------

function K.SlotButton(parent, size, empty)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size or 37, size or 37)
    b.bg = K.Tex(b, "BACKGROUND", empty or "Interface\\Buttons\\UI-EmptySlot")
    b.bg:SetPoint("CENTER")
    b.bg:SetSize((size or 37) * 1.73, (size or 37) * 1.73)
    b.icon = K.Tex(b, "ARTWORK")
    b.icon:SetAllPoints()
    b.count = K.Text(b, "NumberFontNormal", "OVERLAY", "RIGHT")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    b.border = K.Tex(b, "OVERLAY", "Interface\\Buttons\\UI-ActionButton-Border")
    b.border:SetBlendMode("ADD")
    b.border:SetPoint("CENTER")
    b.border:SetSize((size or 37) * 1.8, (size or 37) * 1.8)
    b.border:Hide()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cd:SetAllPoints()
    if b.cd.SetDrawEdge then b.cd:SetDrawEdge(false) end
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    return b
end

-- shows item `id` (count n) on a slot button, with its quality border
function K.SetItem(b, id, n)
    b.itemId = id
    if not id then
        b.icon:Hide()
        b.count:SetText("")
        b.border:Hide()
        if b.bg then b.bg:Show() end
        return
    end
    b.icon:SetTexture(Craft.Items.Icon(id))
    b.icon:Show()
    b.count:SetText((n and n > 1) and n or "")
    local it = D.items[id]
    local q = it and it.q or 1
    if q >= 2 then
        local c = Craft.Items.QUALITY_RGB[q]
        b.border:SetVertexColor(c[1], c[2], c[3], 0.6)
        b.border:Show()
    else
        b.border:Hide()
    end
end

---------------------------------------------------------------------------
-- Tooltips (the client's own GameTooltip: real item tooltips, WoW-style unit and spell lines)
---------------------------------------------------------------------------

local function Q(it) return Craft.Items.QUALITY_RGB[it and it.q or 1] end

function K.ItemTooltip(owner, id, extra)
    local tt = GameTooltip
    tt:SetOwner(owner, "ANCHOR_RIGHT")
    local it = D.items[id]
    local ok = false
    if tt.SetItemByID then ok = pcall(tt.SetItemByID, tt, id) end
    if not ok or tt:NumLines() == 0 then
        -- (our own lines, WoW's order)
        local c = Q(it)
        tt:SetText(it and it.n or "?", c[1], c[2], c[3])
        if it then
            if it.bind == 1 then tt:AddLine("Binds when picked up", 1, 1, 1) elseif it.bind == 2 then tt:AddLine("Binds when equipped", 1, 1, 1) end
            if it.inv and Craft.Items.INV_NAMES[it.inv] then
                local sub = (it.c == 2 and Craft.Items.WEAPON_NAMES[it.s]) or (it.c == 4 and it.s > 0 and Craft.Items.ARMOR_NAMES[it.s]) or ""
                tt:AddDoubleLine(Craft.Items.INV_NAMES[it.inv], sub, 1, 1, 1, 1, 1, 1)
            end
            if it.dmg then
                tt:AddDoubleLine(string.format("%d - %d Damage", it.dmg[1], it.dmg[2]), string.format("Speed %.2f", (it.spd or 2000) / 1000), 1, 1, 1, 1, 1, 1)
                tt:AddLine(string.format("(%.1f damage per second)", (it.dmg[1] + it.dmg[2]) / 2 / ((it.spd or 2000) / 1000)), 1, 1, 1)
            end
            if it.armor then tt:AddLine(it.armor .. " Armor", 1, 1, 1) end
            local names = { [3] = "Agility", [4] = "Strength", [5] = "Intellect", [6] = "Spirit", [7] = "Stamina" }
            for i = 1, #(it.stats or {}), 2 do
                local n = names[it.stats[i]]
                if n then tt:AddLine(string.format("+%d %s", it.stats[i + 1], n), 1, 1, 1) end
            end
            if it.slots then tt:AddLine(it.slots .. " Slot Bag", 1, 1, 1) end
            if it.req and it.req > 1 then
                local lv = Craft.char and Craft.char.level or 1
                tt:AddLine("Requires Level " .. it.req, lv >= it.req and 1 or 1, lv >= it.req and 1 or 0.1, lv >= it.req and 1 or 0.1)
            end
            for _, sp in ipairs(it.spells or {}) do
                local s = D.spells[sp[1]]
                if s and sp[2] == 0 then tt:AddLine("Use: " .. Craft.Combat.SpellText(sp[1], Craft.player), 0, 1, 0, true) end
            end
            if it.desc then tt:AddLine('"' .. it.desc .. '"', 1, 0.82, 0, true) end
        end
    end
    if it and it.sell and it.sell > 0 and extra ~= "nosell" then
        if tt.SetItemByID and ok then
            -- (the client shows its own sell price line on a vendor; outside, add ours)
        end
        tt:AddLine("Sell Price: " .. Craft.MoneyText(it.sell, true), 1, 1, 1)
    end
    if type(extra) == "string" and extra ~= "nosell" then tt:AddLine(extra, 0, 1, 0, true) end
    tt:Show()
end

function K.SpellTooltip(owner, id, extra)
    local tt = GameTooltip
    tt:SetOwner(owner, "ANCHOR_RIGHT")
    local sp = D.spells[id]
    if not sp then tt:Hide() return end
    local u = Craft.player
    tt:SetText(sp.n, 1, 1, 1)
    if sp.r then tt:AddLine(sp.r, 0.5, 0.5, 0.5) end
    local cost, pt = Craft.Combat.Cost(sp, u)
    local left = cost > 0 and ((pt == 1 and (floor(cost / 10) .. " Rage")) or (pt == -2 and (cost .. " Health")) or (cost .. " Mana")) or nil
    local right = sp.range and sp.range > 5 and (floor(sp.range) .. " yd range") or (sp.range == 5 and "Melee Range" or nil)
    if left or right then tt:AddDoubleLine(left or " ", right or " ", 1, 1, 1, 1, 1, 1) end
    local ct = (sp.cast or 0) / 1000
    local castText = Craft.Combat.IsChannel(sp) and "Channeled" or (ct > 0 and (string.format("%g", ct) .. " sec cast") or (Craft.Combat.IsNextSwing(sp) and "Next melee" or "Instant"))
    local cd = (sp.cd or 0) > 0 and sp.cd or ((sp.catCd or 0) > 0 and sp.catCd) or 0
    local cdText = cd > 0 and ((cd >= 60000 and (floor(cd / 60000) .. " min cooldown")) or (floor(cd / 1000) .. " sec cooldown")) or nil
    if not Craft.Combat.IsPassive(sp) then tt:AddDoubleLine(castText, cdText or " ", 1, 1, 1, 1, 1, 1) end
    local text = Craft.Combat.SpellText(id, u)
    if text ~= "" then tt:AddLine(text, 1, 0.82, 0, true) end
    if extra then tt:AddLine(extra, 0, 1, 0, true) end
    tt:Show()
end

-- a unit's tooltip: name, level and type, like hovering a mob in WoW
function K.UnitTooltip(owner, u, anchor)
    local tt = GameTooltip
    tt:SetOwner(owner, anchor or "ANCHOR_CURSOR")
    local p = Craft.player
    local r = Craft.Combat.Reaction(p, u)
    local cr, cg, cb = 1, 1, 0
    if r == "hostile" then cr, cg, cb = 1, 0.1, 0.1 elseif r == "friendly" then cr, cg, cb = 0.1, 1, 0.1 end
    if Craft.Combat.IsPlayer(u) then
        local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[Craft.CLASS_TOKENS[u.class] or ""]
        if c then cr, cg, cb = c.r, c.g, c.b end
    end
    tt:SetText(u.name or "?", cr, cg, cb)
    if u.title then tt:AddLine("<" .. u.title .. ">", 1, 1, 1) end
    local lvl = u.level or 1
    local types = { [1] = "Beast", [2] = "Dragonkin", [3] = "Demon", [4] = "Elemental", [5] = "Giant", [6] = "Undead",
                    [7] = "Humanoid", [8] = "Critter", [9] = "Mechanical" }
    local typ = Craft.Combat.IsPlayer(u) and ("Human " .. (Craft.CLASS_NAMES[u.class] or "")) or
                (u.cr and types[u.cr.type or 0]) or ""
    if u.elite then typ = typ .. " (Elite)" end
    local qr, qg, qb = Craft.Quests.Color(lvl, p and p.level or 1)
    tt:AddLine(string.format("Level %d %s", lvl, typ), qr, qg, qb)
    if u.dead then tt:AddLine("Corpse", 0.5, 0.5, 0.5) end
    -- quest objectives this creature counts for (WoW's quest tooltip lines)
    if u.entry and Craft.char then
        for id in pairs(Craft.char.quests) do
            local q = Craft.Quests.Get(id)
            for _, k in ipairs(q and q.kill or {}) do
                if k.entry == u.entry then
                    tt:AddLine(q.title, 1, 0.82, 0)
                    local st = Craft.Quests.State(id)
                    tt:AddLine(string.format(" - %s slain: %d/%d", k.name, min(k.count, st.k[k.entry] or 0), k.count), 1, 1, 1)
                end
            end
        end
    end
    tt:Show()
end

function K.HideTooltip() GameTooltip:Hide() end

---------------------------------------------------------------------------
-- Sounds (WoW's own files and sound kits)
---------------------------------------------------------------------------

K.SFX = {
    hit = { 567621, 567620, 567632 }, crit = 567619, miss = 569774,
    precast = { [4] = 569045, [16] = 568119, [2] = 568915, [32] = 569424, [64] = 568938, [8] = 568091 },
    impact = { [4] = 568461, [16] = 569378, [2] = 569402, [32] = 568353, [64] = 569631, [8] = 569708 },
    heal = 569570, shout = 568028, thunder = 569222, strike = 569059, frostarmor = 569286,
    levelup = 567431, quest = 567400, questdone = 567439, coin = 567428, loot = 567517, bag = 567543,
    sheet = 567507, book = 567545, questlog = 567504, error = 567520, open = 567490, close = 567464,
    equip = 567560, drink = 567492, start = 567419, page = 567472,
    kobold = { aggro = 553311, attack = 553319, wound = 553313, death = 553318 },
}

local lastPlay = {}
function K.Play(id, gap)
    if not id then return end
    if type(id) == "table" then id = id[math.random(1, #id)] end
    local now = GetTime and GetTime() or 0
    if lastPlay[id] and now - lastPlay[id] < (gap or 0.05) then return end
    lastPlay[id] = now
    local data = Craft:Data()
    if data.sfx == false then return end
    if PlaySoundFile then pcall(PlaySoundFile, id, "Master") end
end

-- a little helper to make a frame fade in / out
function K.Fade(f, show, t)
    if show then f:Show() f:SetAlpha(1) else f:Hide() end
end

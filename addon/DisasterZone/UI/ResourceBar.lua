if DisasterZoneBoot and DisasterZoneBoot.Run("UI/ResourceBar.lua", ...) then return end -- DisasterZone: resource bar HUD.
-- The resource bar on screen (Core/Resource.lua; feedback #26, #27's combo points on it): one frame in Edit layout
-- ("Resource bar", Class tools) wearing its theme's face in its shape (UI/ResourceFace.lua). Shown while the tool is
-- on and the Show setting says so (by default in combat, or while the power is not at rest: rage above nothing, energy
-- or mana below full), at the out-of-combat opacity outside fights. Edit layout stretches a bar along its length (an
-- upright one along its height); a globe only scales. Its demo part (Settings > Help > Demo mode) plays a made-up fight
-- for your class's power. The Settings card (Settings > Class tools > Resource bar) is at the bottom.
local addonName, ns = ...

local HUD = ns:NewModule("ResourceBar")
local RF = ns.ResourceFace
local UI = ns.UI
local Res                        -- ns.Resource

local floor, max, min = math.floor, math.max, math.min

local FRAME = "DisasterZoneResourceBar"
local KIND = "power"             -- the theme kind (ns.Themes) and the setting prefix
local TICK_HZ = 0.05             -- the face repaints this often while shown (the tick ring runs smoothly)

local frame
local faces = {}                 -- ["theme/shape"] = face
local layoutDef

local function Get(path, default) return Res.Get(path, default) end

local function Theme()
    local t = ns.Themes and ns.Themes:Current(KIND)
    return t and t.key or "halo"
end

local function Shape()
    local s = Get("shape", "bar")
    if s ~= "upright" and s ~= "globe" then s = "bar" end
    return s
end

function HUD:Options(now)
    return { num = Get("num", "ring"), marks = Get("icons", false) and "icons" or "pegs", tick = Get("tick", "ring"),
             color = Get("color", "game"), class = ns.ClassKit:MyClass(), own = Get("own"), now = now }
end

-- The bar's length: Edit layout's stretch (the whole face's width / an upright one's height), else its theme's own.
local function Length(face)
    local g = face.g
    local w, h
    if ns.Layout and ns.Layout.Size then w, h = ns.Layout:Size(KIND) end
    local rest = g.C + g.gap + 2 * (g.pad or 0)
    if face.shape == "bar" and w then return w - rest end
    if face.shape == "upright" and h then return h - rest end
    return g.len
end

-- Puts on the face of the theme and shape now (built once each) and sizes the frame round it.
function HUD:Wear()
    if not frame then return end
    local theme, shape = Theme(), Shape()
    local key = theme .. "/" .. shape
    if frame.key ~= key then
        if frame.face then frame.face.root:Hide() end
        local face = faces[key]
        if not face then
            face = RF:Build(frame, theme, shape)
            faces[key] = face
        end
        face.root:ClearAllPoints()
        face.root:SetPoint("CENTER", frame, "CENTER")
        face.root:Show()
        frame.face, frame.key = face, key
    end
    local face = frame.face
    if face.shape ~= "globe" then face:Layout(Length(face)) end
    frame:SetSize(face.W, face.H)
    frame.w, frame.h = face.W, face.H
    frame:SetScale(tonumber(Get("scale", 1)) or 1)
    -- (what Edit layout's side handles stretch: a bar's length, an upright one's height, nothing of a globe)
    if layoutDef then
        layoutDef.stretch.x = shape == "bar" and { 100, 640 } or nil
        layoutDef.stretch.y = shape == "upright" and { 70, 520 } or nil
    end
end

-- A made-up moment for previews (Edit layout with the tool off, the Settings tiles): your class's power.
function HUD:Sample(kind)
    kind = kind or (Res and Res:DemoKind()) or "rage"
    if kind == "rage" then
        return { kind = "rage", v = 62, mx = 100, line = 40, fight = true,
                 marks = { { key = "ww", cost = 25 }, { key = "bt", cost = 30 } } }
    elseif kind == "energy" then
        return { kind = "energy", v = 31, mx = 100, tick = 0.8, ghost = 20, cp = 3, fight = true,
                 marks = { { key = "snd", cost = 25 }, { key = "evis", cost = 35 }, { key = "ss", cost = 40 } } }
    end
    return { kind = "mana", v = 8100, mx = 10000, tick = 0.6, ghost = 150, fight = true, marks = {} }
end

function HUD:Update()
    if not frame then return end
    local now = GetTime()
    local playing = Res:DemoPlaying()
    if not (self.preview or playing or Res:IsLive()) then frame:Hide() return end
    local s = Res:Snapshot(now)
    if self.preview and not playing and not Res:IsLive() then s = self:Sample() end
    if not (self.preview or Res:Wanted(s)) then frame:Hide() return end
    self.snap = s
    if not frame:IsShown() then frame:Show() end
    frame:SetAlpha(self.preview and 1 or Res:Alpha())
    local face = frame.face
    RF:Paint(face, s, self:Options(now))
    -- (the face fits the rows it shows: combo points, druid mana)
    if frame.w ~= face.W or frame.h ~= face.H then
        frame.w, frame.h = face.W, face.H
        frame:SetSize(face.W, face.H)
    end
end

function HUD:Refresh()
    if not frame then return end
    self:Wear()
    self:Update()
end

function HUD:Frame() return frame end
function HUD:Face() return frame and frame.face end

local function Build()
    frame = UI:CreateHudFrame(FRAME, { width = 220, height = 30, look = "none", position = false, strata = "MEDIUM",
                                       layout = KIND })
    frame:EnableMouse(false)
    frame:Hide()
    local acc = 0
    frame:SetScript("OnUpdate", function(_, dt)
        acc = acc + (dt or 0)
        if acc < TICK_HZ then return end
        acc = 0
        HUD:Update()
    end)
    HUD:Wear()
end

function HUD:OnLogin()
    Res = ns.Resource
    if not (Res and RF) then return end
    ns.Themes:Define(KIND, RF.THEMES, "halo", { setting = "power.theme", onPreview = function() HUD:Refresh() end })
    Build()
    if ns.Layout then
        layoutDef = { name = "Resource bar", group = "Class tools", order = 29, frame = function() return frame end,
            mine = function() return Res:IsLive() and true or false end,
            when = "in combat, or while your power is not at rest",
            default = { "CENTER", 0, -262 },
            scale = { get = function() return tonumber(Get("scale", 1)) or 1 end,
                      set = function(v) ns.DB:SetSetting("power.scale", v) end },
            stretch = { x = { 100, 640 }, apply = function() HUD:Refresh() end },
            preview = function(on) HUD.preview = on and true or nil; HUD:Refresh() end }
        ns.Layout:Register(KIND, layoutDef)
        ns.Layout:Place(KIND)
    end
    HUD:Refresh()
    ns:On("RESOURCE_CHANGED", function() HUD:Update() end)
    ns:On("CLASSKIT_CHANGED", function() HUD:Refresh() end)
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and path:find("^power%.") then HUD:Refresh() end
    end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Settings > Class tools > Resource bar
-- ---------------------------------------------------------------------------------------------------------------
local TILE_W, TILE_H = 104, 58

-- A theme tile's sample: the face in the shape picked, at your class's sample moment.
local function PaintTile(tile, t)
    if tile.face then return end
    local face = RF:Build(tile, t.key, Shape())
    local s = HUD:Sample()
    RF:Paint(face, s, HUD:Options(0))
    local w, h = face.W, face.H
    local k = min((TILE_W - 12) / w, (TILE_H - 24) / h)
    face.root:SetScale(k)
    face.root:SetPoint("CENTER", tile, "TOPLEFT", (TILE_W / 2) / k, -((TILE_H - 18) / 2 + 2) / k)
    tile.face = face
end

-- Eight colours for "my own"
local OWN = {
    { 0.62, 0.36, 1 }, { 0.2, 0.8, 0.75 }, { 0.3, 0.85, 0.35 }, { 1, 0.5, 0.15 },
    { 0.95, 0.3, 0.55 }, { 0.35, 0.6, 1 }, { 0.92, 0.9, 0.85 }, { 0.85, 0.7, 0.3 },
}

local function Is(cls) return function() return ns.ClassKit:MyClass() == cls end end
local function IsAny(...)
    local want = { ... }
    return function()
        local mine = ns.ClassKit:MyClass()
        for _, c in ipairs(want) do if c == mine then return true end end
        return false
    end
end

-- The marks row: a toggle per press of your class you know (its icon, name and cost), none picked at first.
local function MarksRow(S, sec)
    local row = S:Row(sec, "Marks", "None until you pick. A line at what each picked press costs, lit while you "
        .. "can press it. Costs come from the game, so talents count.")
    row.hasDesc = true
    S.PlaceText(row, 0)
    local box = CreateFrame("Frame", nil, sec)
    box:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y)
    box:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y)
    box.buttons = {}
    local BTN_H, GAP = 22, 6
    local function Lay()
        for _, b in ipairs(box.buttons) do b:Hide() end
        local x, y, n = 0, 0, 0
        local width = (sec.fitW or 560)
        local cls = ns.ClassKit:MyClass()
        local picked = Res:Picked(cls)
        for _, e in ipairs(Res:Presses(cls)) do
            local p = e.press
            if Res.Known(p.id) then
                n = n + 1
                local b = box.buttons[n]
                if not b then
                    b = UI:CreateSleekButton(box, "", 120, BTN_H, function(self)
                        Res:SetPicked(self.key, not Res:Picked()[self.key])
                    end)
                    b.icon = b:CreateTexture(nil, "ARTWORK")
                    b.icon:SetSize(14, 14)
                    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    box.buttons[n] = b
                end
                b.key = p.key
                local name = GetSpellInfo and GetSpellInfo(p.id) or p.key
                local cost = Res:Cost(p)
                local label = cost and (name .. " " .. floor(cost + 0.5)) or name
                b:SetText(label)
                local tw = (b.GetFontString and b:GetFontString() and b:GetFontString():GetStringWidth()) or (#label * 6)
                local bw = max(70, floor(tw + 40))
                b:SetWidth(bw)
                b.icon:SetTexture(GetSpellTexture and GetSpellTexture(p.id))
                b.icon:ClearAllPoints()
                b.icon:SetPoint("LEFT", b, "LEFT", 6, 0)
                b:SetKind(picked[p.key] and "chosen" or "secondary")
                if x > 0 and x + bw > width then x, y = 0, y + BTN_H + GAP end
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", box, "TOPLEFT", x, -y)
                b:Show()
                x = x + bw + GAP
            end
        end
        if n == 0 then
            box.none = box.none or UI:Text(box, "small", "SUB")
            box.none:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
            box.none:SetText("No presses known yet that spend your power.")
            box.none:Show()
            y = 14 - BTN_H
        elseif box.none then
            box.none:Hide()
        end
        box:SetHeight(y + BTN_H + 8)
        return y + BTN_H + 8
    end
    local h = Lay()
    sec.y = sec.y - h
    S.refreshers[#S.refreshers + 1] = { Refresh = function() Lay() end }
    sec.rows[#sec.rows + 1] = { line = box:CreateTexture(nil, "BORDER") }
    return row
end

-- The shape: Bar | Upright | Globe in one control.
local function ShapeRow(S, sec)
    local row = S:Row(sec, "Shape", "A bar, the bar standing up (it fills from the bottom), or a globe.")
    local items = {}
    for _, s in ipairs(RF.SHAPES) do items[#items + 1] = { key = s.key, label = s.name } end
    local seg = UI:CreateSegments(row, items, function(key) Res.Set("shape", key) end, { width = 210, selected = Shape() })
    seg:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.control = seg
    S.PlaceText(row, 210)
    S.refreshers[#S.refreshers + 1] = { Refresh = function() seg:Select(Shape()) end }
    return row
end

-- The colour: the game's, your class's, or one of eight of your own.
local function OwnRow(S, sec)
    local row = S:Row(sec, "Your colour", "Picked here, used while Colour is My own.")
    local box = CreateFrame("Frame", nil, row)
    box:SetSize(8 * 24 - 4, 20)
    box:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    box.sw = {}
    for i, c in ipairs(OWN) do
        local b = CreateFrame("Button", nil, box)
        b:SetSize(20, 20)
        b:SetPoint("LEFT", box, "LEFT", (i - 1) * 24, 0)
        b.fill = b:CreateTexture(nil, "ARTWORK")
        b.fill:SetPoint("TOPLEFT", 2, -2); b.fill:SetPoint("BOTTOMRIGHT", -2, 2)
        b.fill:SetColorTexture(c[1], c[2], c[3], 1)
        b.ring = UI:Fill(b, "SUB", "BACKGROUND")
        b:SetScript("OnClick", function()
            Res.Set("own", { r = c[1], g = c[2], b = c[3] })
            Res.Set("color", "own")
        end)
        box.sw[i] = b
    end
    row.control = box
    S.PlaceText(row, 8 * 24)
    S.refreshers[#S.refreshers + 1] = { Refresh = function()
        local own = Get("own") or {}
        for i, c in ipairs(OWN) do
            local on = math.abs((own.r or -1) - c[1]) < 0.01 and math.abs((own.g or -1) - c[2]) < 0.01
                and math.abs((own.b or -1) - c[3]) < 0.01
            box.sw[i].ring:SetColorTexture(ns.Style:Color(on and "GOLD" or "HAIRLINE"))
        end
    end }
    return row
end

if ns.ClassKit then ns.ClassKit:Extend("power", { iconPath = "Interface\\Icons\\Ability_Warrior_EndlessRage",
    settings = function(S, sec)
    -- (on/off is the switch on the card's header: power.enabled)
    ns.Themes:SettingsRow(S, sec, KIND, "Theme", "The look of the bar.",
        { tileW = TILE_W, tileH = TILE_H, gap = 8, nameY = 6, clip = true, paint = PaintTile,
          hint = "Your bar shows it while you point at it.", onPick = function() HUD:Refresh() end })
    ShapeRow(S, sec)
    S:DropdownSetting(sec, "Number", "Where the number sits. Mana shows a percent.", "power.num", "ring", {
        { value = "ring", text = "In its holder" }, { value = "bar", text = "On the bar" },
        { value = "pct", text = "As a percent" }, { value = "full", text = "Now / most" }, { value = "off", text = "No number" } })
    S:EditLayoutRow(sec, "Place and size", "Move it, and pull its ends to stretch it, in Edit layout.")
    MarksRow(S, sec)
    -- the warrior's extras
    local _, r1 = S:SwitchSetting(sec, "Heroic Strike line", "The swing timer's line (Fury 40, Arms 80). Rage over "
        .. "it glows.", "power.hsLine", true)
    S:Needs(r1, Is("WARRIOR"))
    local _, r2 = S:SwitchSetting(sec, "Queued Heroic Strike", "The rage it will take shows darkened.", "power.queued", true)
    S:Needs(r2, Is("WARRIOR"))
    local _, r3 = S:SwitchSetting(sec, "Next swing's rage", "A faint estimate of what the next main-hand hit gives "
        .. "(a dodge or miss makes it wrong).", "power.swing", false)
    S:Needs(r3, Is("WARRIOR"))
    -- energy, mana, combo points
    local _, r4 = S:DropdownSetting(sec, "Next energy tick", "Energy comes in steps of 20 every 2 seconds.",
        "power.tick", "ring", { { value = "ring", text = "On the holder" }, { value = "spark", text = "Spark on the bar" },
        { value = "off", text = "Off" } })
    S:Needs(r4, IsAny("ROGUE", "DRUID"))
    local _, r5 = S:SwitchSetting(sec, "Five-second rule", "Mana: the ring runs the 5 seconds after you spend mana, "
        .. "then the regen ticks.", "power.rule", true)
    S:Needs(r5, function() local c = ns.ClassKit:MyClass(); return c ~= "WARRIOR" and c ~= "ROGUE" end)
    local _, r6 = S:SwitchSetting(sec, "Combo points", "Five points under the bar (Rogues, Cat form).", "power.combo", true)
    S:Needs(r6, IsAny("ROGUE", "DRUID"))
    local _, r7 = S:SwitchSetting(sec, "Mana in forms", "Druids: a mana line under Bear and Cat, a mark per shapeshift "
        .. "it pays for.", "power.formMana", true)
    S:Needs(r7, Is("DRUID"))
    S:SwitchSetting(sec, "Warn before capping", "The bar glows when rage is full or the next tick would waste energy.",
        "power.cap", true)
    S:MoreOptions(sec)
    S:SwitchSetting(sec, "Spell icons on marks", "Each mark's spell icon on the edge instead of a peg.", "power.icons", false)
    S:DropdownSetting(sec, "Colour", "The game's power colours, your class's, or your own.", "power.color", "game", {
        { value = "game", text = "The game's" }, { value = "class", text = "Class colour" }, { value = "own", text = "My own" } })
    local own = OwnRow(S, sec)
    S:Needs(own, function() return Get("color", "game") == "own" end)
    S:DropdownSetting(sec, "Show", "At rest = rage empty, energy and mana full.", "power.show", "active", {
        { value = "active", text = "In combat or not at rest" }, { value = "combat", text = "In combat only" },
        { value = "always", text = "Always" } })
    local fades = {}
    for _, a in ipairs({ 0.2, 0.4, 0.6, 0.8, 1 }) do fades[#fades + 1] = { value = a, text = floor(a * 100) .. "%" } end
    S:DropdownSetting(sec, "Out of combat", "How much of it shows outside fights.", "power.restAlpha", 0.4, fades)
    S:EndSection(sec)
end }) end

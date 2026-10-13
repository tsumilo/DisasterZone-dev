if DisasterZoneBoot and DisasterZoneBoot.Run("UI/CombatText.lua", ...) then return end -- DisasterZone UI/CombatText.lua
-- Combat text on screen (ns.CombatTextUI): the stage the six looks draw on (UI/CombatTextLooks.lua, with the pen of
-- UI/CombatTextPen.lua). Core/CombatText.lua reads the combat log and hands every hit, heal, proc and alert here as
-- an event (Emit); the look of Settings > UI ("Combat text", ui.sct.look, following ui.look) spawns its numbers.
-- Off by default: only its own switch (ui.sct.on) turns it on, whatever look everything else wears; with it on and
-- the look on Blizzard, it wears Classic (the game's own way).
-- Anchors (where a number stands, in the mockup's px, y down from the overlay's top left): a hit rides the
-- nameplate of the mob it hit (nameplate units carry the mob's GUID), 66 px under the plate's centre as in the
-- mockup; with no plate, or in Columns mode, the target spot. The player's numbers stand round the "you" spot, procs
-- and alerts at the alerts spot: three Edit layout items (Core/Layout.lua), previewed with the demo pull.
-- The stage keeps numbers (sprites), groups (hits that join), feeds (Slate's lines), lanes per anchor and its own
-- clock; it runs on one OnUpdate only while something is on screen.
local addonName, ns = ...

local CT = ns:NewModule("CombatTextUI")
local Pen = ns.CTPen

local floor, max, min = math.floor, math.max, math.min
local ipairs, pairs, type, pcall = ipairs, pairs, type, pcall
local tremove = table.remove

local LANES = { 0, -66, 60, -30, 32 }
local HIT_DROP = 66       -- (px under a plate's centre: the mockup's plate at 192, the hit at 262 minus the bar's 4)
CT.LANES = LANES

-- The spots (Edit layout items): size in the mockup's px, default centre in the mockup's px (x from the screen's
-- centre; y from the bottom for you, from the top for the others).
local SPOTS = {
    you = { name = "Combat text: you", order = 41, w = 380, h = 120, x = 0, bottom = 150 },
    target = { name = "Combat text: target", order = 42, w = 300, h = 120, x = 0, top = 262 },
    alerts = { name = "Combat text: alerts", order = 43, w = 400, h = 120, x = 0, top = 82 },
}
CT.SPOTS = SPOTS

---------------------------------------------------------------------------
-- The stage
---------------------------------------------------------------------------

local st = { sprites = {}, groups = {}, feeds = {}, queue = {}, clock = 0, seq = 0, frame = 0 }
CT.st = st
local awake = false
local anchors = {}           -- [guid] = a plate anchor
local plates = {}            -- [guid] = nameplate unit token
local reported = false

function st:Add(s, at)
    s.age = 0
    s.at = at or self.screen
    self.seq = self.seq + 1
    s.host = Pen:Host(s.under and 3 or (10 + self.seq % 4000))
    self.sprites[#self.sprites + 1] = s
    CT:Wake()
    return s
end

-- The next lane of an anchor (the mockup's nextLane: 0, -66, 60, -30, 32 px across).
function st:Lane(ev)
    local a = ev.hit or self.spot
    a.lane = (a.lane or 1) % #LANES + 1
    return LANES[a.lane]
end

-- Halo's side: left, right, left ... per anchor.
function st:Side(ev)
    local a = ev.hit or self.spot
    a.side = -(a.side or 1)
    return a.side
end

-- Hits that join (the mockup's group()): one number fed by every hit of the group.
function st:Group(ev, hold, make, at)
    local key = ev.gkey or ev.group
    local g = self.groups[key]
    if not g or g.done then
        g = { total = 0, n = 0, shown = 0, pulse = 0, last = 0, ticks = {}, born = self.clock }
        self.groups[key] = g
        local s = { life = 999, g = g, gkey = key }
        s.update = function(s, dt, st)
            g.shown = g.shown + (g.total - g.shown) * min(1, dt * 11)
            g.pulse = max(0, g.pulse - dt * 5)
            if not s.ending and st.clock - g.last > hold then
                s.ending = true
                s.life = s.age + 0.35
                g.done = true
            end
        end
        s.draw = make(g, s)
        self:Add(s, at or ev.hit)
    end
    g.total = g.total + (ev.amt or 0)
    g.n = g.n + 1
    g.last = self.clock
    g.pulse = 1
    g.ev = ev
    if ev.icon then g.icon = ev.icon end
    g.ticks[#g.ticks + 1] = { n = g.n, at = self.clock, amt = ev.amt or 0 }
    g.spell = ev.gname or ev.spell
    return g
end

-- A feed (Slate's lines) by name and anchor.
function st:Feed(name, at)
    local key = name .. tostring(at and at.id or "")
    local f = self.feeds[key]
    if not f then f = {}; self.feeds[key] = f end
    return f, key
end

function st:Queue(delay, ev)
    local q = self.queue
    local at = self.clock + delay
    local i = #q + 1
    while i > 1 and q[i - 1].at > at do i = i - 1 end
    table.insert(q, i, { at = at, ev = ev })
    CT:Wake()
end

function st:Clear()
    for _, s in ipairs(self.sprites) do if s.host then Pen:Free(s.host); s.host = nil end end
    self.sprites, self.groups, self.feeds, self.queue = {}, {}, {}, {}
    for k in pairs(anchors) do anchors[k] = nil end
    for _, a in ipairs({ self.spot, self.you, self.top }) do if a then a.lane, a.side = nil, nil end end
    self.fctLane, self.fctNext = 0, nil
end

function st:Step(dt)
    self.clock = self.clock + dt
    self.frame = self.frame + 1
    local q = self.queue
    while q[1] and q[1].at <= self.clock do CT:Emit(tremove(q, 1).ev) end
    if CT.previewing and #q == 0 and self.clock >= (CT.nextLoop or 0) then CT:QueuePull(true) end
    local list = self.sprites
    for i = 1, #list do
        local s = list[i]
        s.age = s.age + dt
        if s.update then
            local ok, err = pcall(s.update, s, dt, self)
            if not ok then s.life = 0; CT:Report(err) end
        end
    end
    local n = 0
    for i = 1, #list do
        local s = list[i]
        if s.age < s.life then
            n = n + 1
            list[n] = s
        else
            if s.host then Pen:Free(s.host); s.host = nil end
            if s.g and self.groups[s.gkey] == s.g then self.groups[s.gkey] = nil end
        end
    end
    for i = #list, n + 1, -1 do list[i] = nil end
    for key, f in pairs(self.feeds) do
        local m = 0
        for i = 1, #f do
            local l = f[i]
            if l.age < l.life then m = m + 1; f[m] = l end
        end
        for i = #f, m + 1, -1 do f[i] = nil end
        if m == 0 then self.feeds[key] = nil end
    end
end

-- Keeping numbers apart: each frame, a number whose box (last frame's, from the pen) overlaps an older one's is
-- given a push away from it, mostly up or down, and eases there; pushes only grow while it lives, so nothing
-- bounces back into the crowd. Wide things (banners) and the screen's own drawings are left where they are.
local PAD, PUSH_MAX, WIDE = 3, 70, 320

local function Spread(list, dt)
    local n = #list
    for i = 1, n do
        local a = list[i]
        if a.bx0 and not a.under and a.at ~= st.screen and a.bx1 - a.bx0 < WIDE then
            local ax0, ay0 = a.bx0 + (a.nx or 0), a.by0 + (a.ny or 0)
            local ax1, ay1 = a.bx1 + (a.nx or 0), a.by1 + (a.ny or 0)
            for j = 1, n do
                local b = list[j]
                -- (the younger of the two moves: the older one is already being read)
                if b ~= a and b.bx0 and not b.under and b.at ~= st.screen and b.bx1 - b.bx0 < WIDE
                    and (b.age > a.age or (b.age == a.age and j < i)) then
                    local bx0, by0 = b.bx0 + (b.nx or 0), b.by0 + (b.ny or 0)
                    local bx1, by1 = b.bx1 + (b.nx or 0), b.by1 + (b.ny or 0)
                    local px = min(ax1, bx1) - max(ax0, bx0) + PAD
                    local py = min(ay1, by1) - max(ay0, by0) + PAD
                    if px > 0 and py > 0 then
                        local acy, bcy = (ay0 + ay1) / 2, (by0 + by1) / 2
                        if px < py * 0.5 then
                            local d = ((ax0 + ax1) / 2 < (bx0 + bx1) / 2) and -1 or 1
                            a.tx = max(-PUSH_MAX, min(PUSH_MAX, (a.tx or 0) + d * px))
                        else
                            local d = (acy <= bcy) and -1 or 1
                            a.ty = max(-PUSH_MAX, min(PUSH_MAX, (a.ty or 0) + d * py))
                        end
                    end
                end
            end
        end
    end
    local k = min(1, dt * 12)
    for i = 1, n do
        local s = list[i]
        if s.tx or s.ty then
            s.nx = (s.nx or 0) + ((s.tx or 0) - (s.nx or 0)) * k
            s.ny = (s.ny or 0) + ((s.ty or 0) - (s.ny or 0)) * k
        end
    end
end

function st:Render(dt)
    local c = Pen.c
    Spread(self.sprites, dt or 1 / 60)
    for pass = 1, 2 do
        local under = pass == 1
        for _, s in ipairs(self.sprites) do
            if (s.under and true or false) == under and s.host then
                local x, y = s.at:Pos(self)
                local nx, ny = s.nx or 0, s.ny or 0
                Pen:Begin(s.host, x + nx, y + ny)
                local ok, err = pcall(s.draw, c, s, self)
                -- (the box without the push: Spread adds it back)
                if c.bx0 then s.bx0, s.by0, s.bx1, s.by1 = c.bx0 - nx, c.by0 - ny, c.bx1 - nx, c.by1 - ny
                else s.bx0 = nil end
                Pen:End()
                if not ok then s.life = 0; CT:Report(err) end
            end
        end
    end
end

function CT:Report(err)
    if reported then return end
    reported = true
    local h = geterrorhandler and geterrorhandler()
    if h then h(err) end
end

local function OnUpdate(_, elapsed)
    local dt = min(0.05, elapsed or 0)
    st:Step(dt)
    st:Render(dt)
    if #st.sprites == 0 and #st.queue == 0 and not CT.previewing then CT:Sleep() end
end

function CT:Wake()
    if awake then return end
    awake = true
    local o = Pen:Overlay()
    o:Show()
    o:SetScript("OnUpdate", OnUpdate)
end

function CT:Sleep()
    if not awake then return end
    awake = false
    local o = Pen:Overlay()
    o:SetScript("OnUpdate", nil)
    for k in pairs(anchors) do anchors[k] = nil end
end

function CT:IsAwake() return awake end

-- One step by hand (tests): dt seconds, then draw.
function CT:Tick(dt)
    st:Step(dt or 1 / 60)
    st:Render(dt or 1 / 60)
end

---------------------------------------------------------------------------
-- Scale and anchors
---------------------------------------------------------------------------

function CT:Size() return tonumber(ns.Look and ns.Look:Opt("sct", "size", 1)) or 1 end

-- 540 of the overlay's units = the screen's height / size (the mockup's px).
function CT:Rescale()
    local o = Pen:Overlay()
    local h = UIParent:GetHeight() or 0
    if h <= 0 then h = 768 end
    local s = max(0.4, min(2, self:Size()))
    o:SetScale(max(0.05, h / 540 * s))
    self:PlaceSpots()
end

-- A frame's centre in the overlay's units (y down from its top).
local function Center(f)
    if not (f and f.GetCenter) then return nil end
    local x, y = f:GetCenter()
    if not x then return nil end
    local o = Pen:Overlay()
    local es, os = f:GetEffectiveScale() or 1, o:GetEffectiveScale() or 1
    if os <= 0 then os = 1 end
    local s = es / os
    local _, H = Pen:Size()
    return x * s, H - y * s
end
CT.Center = Center

local spots = {}             -- [key] = holder frame (UIParent child, placed by Edit layout)
CT.spots = spots

-- A spot's centre in the mockup's px, from its frame or its default place.
local function SpotPos(key)
    local f = spots[key]
    local x, y
    if f then x, y = Center(f) end
    if x then return x, y end
    local d = SPOTS[key]
    local W, H = Pen:Size()
    local s = CT:Size()
    -- (the default is in screen px of the mockup at size 1; the overlay holds 540 / size of them)
    local k = 1 / s
    if d.bottom then return W / 2 + d.x * k, H - d.bottom * k end
    return W / 2 + d.x * k, d.top * k
end

local function FixedPos(a, s)
    if a.fr == s.frame then return a.x, a.y end
    a.fr = s.frame
    a.x, a.y = SpotPos(a.key)
    return a.x, a.y
end

st.you = { id = "you", key = "you", Pos = FixedPos }
st.spot = { id = "spot", key = "target", Pos = FixedPos }
st.top = { id = "top", key = "alerts", Pos = FixedPos }
st.screen = { id = "screen", Pos = function() return 0, 0 end }

function st:ScreenSize() return Pen:Size() end

local function PlatePos(a, s)
    if a.fr == s.frame then return a.x, a.y end
    a.fr = s.frame
    local token = plates[a.guid]
    local p = token and C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(token)
    if p and type(p) == "table" and p.GetCenter and (not p.IsVisible or p:IsVisible()) then
        local ok, x, y = pcall(Center, p)
        if ok and x then
            a.x, a.y = x, y + HIT_DROP
            return a.x, a.y
        end
    end
    if not a.x then a.x, a.y = SpotPos("target") end
    return a.x, a.y
end

-- The anchor a hit on `guid` stands on: its nameplate (Nameplate mode, a plate shown), else the target spot.
function CT:HitAnchor(guid)
    if not guid or self:Mode() ~= "plate" or not plates[guid] then return st.spot end
    local a = anchors[guid]
    if not a then
        a = { id = guid, guid = guid, Pos = PlatePos }
        anchors[guid] = a
    end
    return a
end

function CT:Mode() return ns.Look and ns.Look:Opt("sct", "place", "plate") or "plate" end

-- Where taken hits and heals stand round you: the mockup's left and right of you; Columns puts the heals over the
-- hits taken, left of you.
function CT:SetZones()
    if self:Mode() == "columns" then
        st.IN, st.HEAL = { x = -150, y = -36 }, { x = -150, y = -100 }
    else
        st.IN, st.HEAL = { x = -124, y = -36 }, { x = 124, y = -36 }
    end
end
CT:SetZones()

local function OnPlateAdded(_, token)
    local g = UnitGUID and UnitGUID(token)
    if g then plates[g] = token end
end
local function OnPlateRemoved(_, token)
    local g = UnitGUID and UnitGUID(token)
    if g and plates[g] == token then plates[g] = nil end
    for guid, t in pairs(plates) do if t == token then plates[guid] = nil end end
end
CT.plates = plates

---------------------------------------------------------------------------
-- The look and the events
---------------------------------------------------------------------------

-- The look the numbers wear (Blizzard: Classic, the game's own way).
function CT:LookKey()
    local L = ns.Look
    local key = L and L:Key("sct") or "classic"
    if key == "blizzard" then key = "classic" end
    return key
end

function CT:IsOn() return ns.Look and ns.Look:Opt("sct", "on", false) == true or false end

-- An event from Core/CombatText.lua (or the demo pull): k = out | tick | miss | taken | heal | proc | alert | lowhp,
-- with its fields (amt, spell, icon, school, crit, group / gkey / gname, overkill, who, resist, what, pct, dur, peak,
-- maxHP, dst). Nothing is drawn while combat text is off, but the demo pull (Try it).
function CT:Emit(ev)
    if not ev.demo and not self:IsOn() then return end
    local key = ev.look or self:LookKey()
    local looks = ns.CombatTextLooks
    local face = looks and (looks[key] or looks.flat)
    if not face then return end
    if not ev.hit then ev.hit = (ev.demo and st.spot) or self:HitAnchor(ev.dst) end
    local f = face[ev.k] or (ev.k == "tick" and face.out)
    if not f then return end
    local ok, err = pcall(f, st, ev)
    if not ok then self:Report(err) end
end

function CT:Restyle()
    st:Clear()
    self:SetZones()
    self:Rescale()
end

---------------------------------------------------------------------------
-- The demo pull: the mockup's Void Reaver pull (Try it, demo mode, Edit layout's preview)
---------------------------------------------------------------------------

local I = "Interface\\Icons\\"
local PULL = {
    { 0.40, "out", 1284, "Melee", nil, "phys" },
    { 0.46, "out", 618, "Seal of Command", "Ability_Warrior_InnerRage", "holy" },
    { 1.30, "out", 3412, "Crusader Strike", "Spell_Holy_CrusaderStrike", "phys", { crit = true } },
    { 1.80, "tick", 214, "Consecration", "Spell_Holy_InnerFire", "holy", { group = "tick", gkey = "demo:cons" } },
    { 2.20, "out", 1946, "Judgement of Command", "Spell_Holy_RighteousFury", "holy" },
    { 2.80, "tick", 221, "Consecration", "Spell_Holy_InnerFire", "holy", { group = "tick", gkey = "demo:cons" } },
    { 2.95, "taken", 2410, "Pounding", "Spell_Nature_Earthquake", "phys" },
    { 3.45, "heal", 2104, "Holy Light", "Spell_Holy_HolyBolt", "holy", { who = "Brightsong", whoClass = "PRIEST" } },
    { 3.80, "tick", 209, "Consecration", "Spell_Holy_InnerFire", "holy", { group = "tick", gkey = "demo:cons" } },
    { 4.05, "out", 1190, "Melee", nil, "phys", { group = "multi", gkey = "demo:wf", gname = "Melee" } },
    { 4.11, "out", 1233, "Windfury Attack", "Spell_Nature_Windfury", "phys",
      { group = "multi", gkey = "demo:wf", gname = "Melee + Windfury" } },
    { 4.60, "miss", nil, nil, nil, nil, { what = "Parry" } },
    { 4.80, "tick", 218, "Consecration", "Spell_Holy_InnerFire", "holy", { group = "tick", gkey = "demo:cons" } },
    { 5.10, "proc", nil, "Bloodlust", "Spell_Nature_BloodLust", nil, { dur = 40 } },
    { 5.70, "out", 4812, "Crusader Strike", "Spell_Holy_CrusaderStrike", "phys", { crit = true } },
    { 6.45, "taken", 3150, "Arcane Orb", "Spell_Arcane_Blast", "arcane", { resist = 812 } },
    { 6.75, "lowhp", nil, nil, nil, nil, { pct = 35 } },
    { 7.60, "alert", nil, "Hammer of Wrath", "Ability_ThunderClap" },
    { 8.10, "out", 2890, "Hammer of Wrath", "Ability_ThunderClap", "holy" },
    { 8.70, "out", 2640, "Melee", nil, "phys", { crit = true } },
    { 8.75, "out", 1402, "Seal of Command", "Ability_Warrior_InnerRage", "holy", { crit = true } },
    { 9.40, "out", 2010, "Judgement of Command", "Spell_Holy_RighteousFury", "holy" },
    { 10.20, "out", 5921, "Hammer of Wrath", "Ability_ThunderClap", "holy", { crit = true, overkill = 1380 } },
}
CT.PULL_LENGTH = 12

function CT.PullEvent(row)
    local ev = { k = row[2], amt = row[3], spell = row[4], icon = row[5] and (I .. row[5]) or nil, school = row[6],
                 demo = true, peak = 6240, maxHP = 9800 }
    if row[7] then for k, v in pairs(row[7]) do ev[k] = v end end
    return ev
end

-- Puts the pull on the stage's queue (loop: again when it is over, while previewing).
function CT:QueuePull(loop)
    local salt = st.clock
    for _, row in ipairs(PULL) do
        local ev = self.PullEvent(row)
        if ev.gkey then ev.gkey = ev.gkey .. salt end
        st:Queue(row[1], ev)
    end
    if loop then self.nextLoop = st.clock + self.PULL_LENGTH end
end

-- Settings' Try it (also while it is off: a look at the chosen look), demo mode: the pull once, on the target spot.
function CT:TryIt()
    self:Rescale()
    self:QueuePull(false)
    return true
end

-- Edit layout's preview: the pull again and again while it is on.
function CT:Preview(on)
    if on then
        if not self:IsOn() then return end
        self.previewing = true
        self:Rescale()
        if #st.queue == 0 then self:QueuePull(true) end
    else
        self.previewing = false
        self.nextLoop = nil
        st:Clear()
    end
end

---------------------------------------------------------------------------
-- The spots (Edit layout)
---------------------------------------------------------------------------

function CT:PlaceSpots()
    local h = UIParent:GetHeight() or 0
    if h <= 0 then h = 768 end
    local k = h / 540
    for key, d in pairs(SPOTS) do
        local f = spots[key]
        if f then
            f:SetSize(d.w * k, d.h * k)
            if ns.Layout then ns.Layout:Place("sct." .. key) end
        end
    end
end

local function SpotDefault(key)
    return function()
        local d = SPOTS[key]
        local H = UIParent:GetHeight() or 768
        if H <= 0 then H = 768 end
        local k = H / 540
        if d.bottom then return { "BOTTOM", d.x * k, d.bottom * k - d.h * k / 2 } end
        return { "TOP", d.x * k, -(d.top * k - d.h * k / 2) }
    end
end

function CT:SetupSpots()
    if not ns.Layout or spots.you then return end
    for key, d in pairs(SPOTS) do
        local f = CreateFrame("Frame", "DisasterZoneCombatText_" .. key, UIParent)
        f:SetFrameStrata("LOW")
        spots[key] = f
        ns.Layout:Register("sct." .. key, { name = d.name, group = "Game frames", order = d.order, noHide = true,
            default = SpotDefault(key), frame = function() return spots[key] end, when = "in combat",
            mine = function() return CT:IsOn() end,
            preview = function(on) CT:Preview(on) end })
    end
    self:PlaceSpots()
end

function CT:OnLogin()
    Pen:Overlay()
    self:SetupSpots()
    self:Rescale()
    ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", OnPlateAdded)
    ns:RegisterEvent("NAME_PLATE_UNIT_REMOVED", OnPlateRemoved)
    for _, e in ipairs({ "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" }) do
        ns:RegisterEvent(e, function() CT:Rescale() end)
    end
    ns:On("UI_LOOK_CHANGED", function(part)
        if part == "sct" then CT:Restyle() end
    end)
    ns:On("DEMO_TOGGLED", function(on)
        if on and CT:IsOn() then CT:TryIt() end
    end)
end

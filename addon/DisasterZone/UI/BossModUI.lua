if DisasterZoneBoot and DisasterZoneBoot.Run("UI/BossModUI.lua", ...) then return end -- DisasterZone UI/BossModUI.lua
-- The boss mods on screen (ns.BossModUI): the bars, the warnings, the pull countdown and the range frame that
-- Core/BossMod.lua runs, drawn in the look of Settings > Interface > Looks ("Boss mods": ui.bossmods.look, following
-- ui.look; Blizzard wears Classic) by UI/BossModLooks.lua.
-- Four Edit layout spots (Core/Layout.lua): bars, warnings (with Flat's soon lane and Halo's rings under them),
-- countdown, range. Everything draws on one screen-sized overlay scaled so 540 of its units are the screen's height
-- (the looks draw in the mockup's px), each part at its spot's place and scale as measured every frame: no scaled
-- frame is anchored away from the screen's corner. One OnUpdate runs only while something shows.
-- Sounds (bossmods.sounds): the game's raid warning sound for warnings, an alarm when it's on you.
-- Try it (Settings, demo mode, Edit layout's preview): a made-up Gruul pull through the real engine and data, the
-- range frame with made-up raiders; nothing is read or sent.
local addonName, ns = ...

local UI = ns:NewModule("BossModUI")
local Pen = ns.CTPen

local floor, max, min, abs, sin, cos = math.floor, math.max, math.min, math.abs, math.sin, math.cos
local ipairs, pairs, type, tonumber = ipairs, pairs, type, tonumber

local function BM() return ns.BossMod end
local function Looks() return ns.BossModLooks end
local function Now() return GetTime() end
local function Get(path, default)
    local v = ns.DB and ns.DB:GetSetting(path)
    if v == nil then return default end
    return v
end

local WARN_LIFE = 3
local SOON = 5

-- The spots: size and default centre in the mockup's px (x from the screen's centre, top = the centre's distance
-- from the top).
local SPOTS = {
    bars = { name = "Boss mods: timer bars", order = 50, w = 256, h = 270, x = 300, top = 150 + 135 },
    warns = { name = "Boss mods: warnings", order = 51, w = 560, h = 230, x = 0, top = 50 + 115 },
    count = { name = "Boss mods: pull countdown", order = 52, w = 200, h = 140, x = 0, top = 270 },
    range = { name = "Boss mods: range frame", order = 53, w = 190, h = 230, x = 356, top = 420 },
}
UI.SPOTS = SPOTS
local MID_Y = 34                  -- (the warning's middle in its spot; the soon lane 78 px under it)

local spots = {}
local overlay                     -- the screen-sized canvas everything draws on
local hosts = { bars = {}, soon = {}, warn = nil, count = nil, range = nil, fx = nil }
local ys = {}                     -- [bar id] = its y now (bars glide to their place)
local warns = {}                  -- newest first: { kind, text, sub, icon, t }
local youAt = -99
local driver
local awake = false

---------------------------------------------------------------------------
-- The look
---------------------------------------------------------------------------

function UI:LookKey()
    local own = Get("ui.bossmods.look", "inherit")
    if own == nil or own == "inherit" then own = Get("ui.look", "blizzard") end
    if own == "blizzard" or not Looks()[own] then return "classic" end
    return own
end
function UI:Look() return Looks()[self:LookKey()] end

---------------------------------------------------------------------------
-- Spots and canvases
---------------------------------------------------------------------------

local function K()
    local h = UIParent:GetHeight() or 0
    if h <= 0 then h = 768 end
    return h / 540
end

-- (on a narrow screen a spot right of the middle moves in so it stays 30 px inside the edge)
-- The size settings (Settings > Combat > Boss mods): bossmods.size for the bars, the countdown and the range frame,
-- bossmods.warnSize for the warnings (and the last seconds under them). Smaller than the mockup by default.
local SIZE, WARN_SIZE = 0.7, 0.8
UI.SIZE, UI.WARN_SIZE = SIZE, WARN_SIZE
local function SizeOf(key)
    local v = key == "warns" and Get("bossmods.warnSize", WARN_SIZE) or Get("bossmods.size", SIZE)
    v = tonumber(v) or 1
    if v < 0.3 then v = 0.3 elseif v > 2 then v = 2 end
    return v
end
UI.SizeOf = SizeOf

-- (its top edge where the mockup has it, its middle the mockup's middle scaled in from the screen's centre)
local function SpotDefault(key)
    return function()
        local d, k, z = SPOTS[key], K(), SizeOf(key)
        local half = (UIParent:GetWidth() or 1024) / k / 2
        local x = d.x > 0 and min(d.x - d.w * (1 - z) / 2, half - d.w * z / 2 - 30) or d.x
        return { "TOP", x * k, -(d.top - d.h / 2) * k }
    end
end

function UI:Rescale()
    local k = K()
    for key, d in pairs(SPOTS) do
        local f = spots[key]
        if f then
            local z = SizeOf(key)
            f:SetSize(d.w * k * z, d.h * k * z)
            if ns.Layout then ns.Layout:Place("bossmods." .. key) end
        end
    end
    if overlay then overlay:SetScale(k) end
end

-- A spot's top left on the overlay (its units) and its scale there (Edit layout's size).
local function Origin(key)
    local f = spots[key]
    local l, t = f and f:GetLeft(), f and f:GetTop()
    if not (l and t and overlay) then return 0, 0, 1 end
    local oe = overlay:GetEffectiveScale()
    if not oe or oe <= 0 then return 0, 0, 1 end
    local r = f:GetEffectiveScale() / oe
    local ot = overlay:GetTop() or 540
    local ol = overlay:GetLeft() or 0
    return l * r - ol, ot - t * r, f:GetEffectiveScale() / (UIParent:GetEffectiveScale() or 1)
end
UI.Origin = Origin

function UI:Setup()
    if spots.bars then return end
    for key, d in pairs(SPOTS) do
        local f = CreateFrame("Frame", "DisasterZoneBossMods_" .. key, UIParent)
        f:SetFrameStrata(key == "bars" and "MEDIUM" or "HIGH")
        f:SetFrameLevel(5)
        if f.EnableMouse then f:EnableMouse(false) end
        spots[key] = f
        if ns.Layout then
            ns.Layout:Register("bossmods." .. key, { name = d.name, group = "Raid", order = d.order, noHide = true,
                default = SpotDefault(key), frame = function() return spots[key] end, when = "in boss fights",
                mine = function() return BM() and BM():IsOn() end,
                preview = function(on) UI:Preview(on) end })
        end
    end
    overlay = CreateFrame("Frame", "DisasterZoneBossModsOverlay", UIParent)
    overlay:SetFrameStrata("HIGH")
    overlay:SetFrameLevel(1)
    overlay:SetAllPoints(UIParent)
    if overlay.EnableMouse then overlay:EnableMouse(false) end
    driver = CreateFrame("Frame")
    self:Rescale()
end

local function Host(slot, i, level)
    local list = hosts[slot]
    if i then
        local h = list[i]
        if not h then h = Pen:Host(level or 10, overlay); list[i] = h end
        return h
    end
    if not hosts[slot] then hosts[slot] = Pen:Host(level or 10, overlay) end
    return hosts[slot]
end

-- Starts drawing a part at its spot (x, y: the spot's own mockup px); returns the pen.
local function Begin(h, key, x, y)
    local ox, oy, s = Origin(key)
    s = s * SizeOf(key)
    Pen:Begin(h, ox + (x or 0) * s, oy + (y or 0) * s)
    local c = Pen.c
    if s ~= 1 then c:Scale(s) end
    return c
end

-- Hides what a host drew last frame (it draws nothing this frame).
local function Blank(h)
    if not h then return end
    Pen:Begin(h, 0, 0)
    Pen:End()
end

---------------------------------------------------------------------------
-- The range frame's measuring: positions (a radar) where the game gives them, else distances (a list), else
-- nothing (UnitPosition is nil in instances; the item checks may be blocked in combat: BM.rangeMode says which).
---------------------------------------------------------------------------

-- The TBC items DBM's range check found exact to half a yard (DBM-RangeCheck.lua, the TBC table).
local ITEMS = { { 8, 8149 }, { 11, 34368 }, { 13, 17626 }, { 18, 30651 }, { 23, 17757 }, { 28, 13289 }, { 33, 17202 },
                { 38, 18904 }, { 43, 34255 } }
local units = {}
local function Members()
    for i = #units, 1, -1 do units[i] = nil end
    if IsInRaid and IsInRaid() then
        for i = 1, (GetNumGroupMembers and GetNumGroupMembers() or 0) do units[#units + 1] = "raid" .. i end
    elseif IsInGroup and IsInGroup() then
        for i = 1, 4 do units[#units + 1] = "party" .. i end
    end
    return units
end
local function Usable(u)
    return UnitExists(u) and not UnitIsUnit(u, "player") and not UnitIsDeadOrGhost(u) and UnitIsConnected(u)
end
local R = { dots = {}, near = {} }
local pool = {}
local function Dot(i)
    local d = pool[i]
    if not d then d = {}; pool[i] = d end
    return d
end
local IsItemInRange = (C_Item and C_Item.IsItemInRange) or _G.IsItemInRange

function UI:Measure(yd)
    R.yd, R.n, R.noPos = yd, 0, false; R.blocked = false
    local dots, near = R.dots, R.near
    for i = #dots, 1, -1 do dots[i] = nil end
    for i = #near, 1, -1 do near[i] = nil end
    local px, py = UnitPosition and UnitPosition("player")
    local list = Members()
    if px and py then
        BM().rangeMode = "positions"
        for _, u in ipairs(list) do
            if Usable(u) then
                local x, y = UnitPosition(u)
                if x and y then
                    local d = Dot(#dots + 1)
                    d.x, d.y = -(y - py), -(x - px)
                    d.d = (d.x * d.x + d.y * d.y) ^ 0.5
                    d.close = d.d < yd
                    d.n = UnitName(u)
                    local _, cls = UnitClass(u)
                    d.cls = cls
                    dots[#dots + 1] = d
                    if d.close then R.n = R.n + 1; near[#near + 1] = d end
                end
            end
        end
        table.sort(near, function(p, q) return p.d < q.d end)
        return R
    end
    R.noPos = true
    local item
    for _, it in ipairs(ITEMS) do if it[1] >= yd then item = it[2] break end end
    local answered = false
    for _, u in ipairs(list) do
        if Usable(u) then
            local d2, checked = nil, false
            if UnitDistanceSquared then d2, checked = UnitDistanceSquared(u) end
            local dist, close
            if checked and d2 then
                dist = d2 ^ 0.5
                close = dist < yd
                answered = true
            elseif item and IsItemInRange and not (InCombatLockdown and InCombatLockdown()) then
                -- friendly item checks are protected in combat (verified in Ramparts 2026-10-13: nil + "Interface action failed")
                local r = IsItemInRange(item, u)
                if r ~= nil then answered = true; close = r end
            end
            if close then
                local d = Dot(#near + 1)
                d.d, d.close, d.n = dist, true, UnitName(u)
                local _, cls = UnitClass(u)
                d.cls = cls
                near[#near + 1] = d
                R.n = R.n + 1
            end
        end
    end
    if not answered and #list > 0 then
        -- nothing could measure (instance + combat): say so rather than an empty "nobody near" frame
        BM().rangeMode = "none"
        R.blocked = true
        return R
    end
    R.blocked = false
    BM().rangeMode = "distances"
    table.sort(near, function(p, q) return (p.d or 0) < (q.d or 0) end)
    return R
end

-- Try it: made-up raiders that crowd round you at Ground Slam and spread out (the mockup's raid).
local DEMO_RAID = { { "Victhar", "WARRIOR" }, { "Moonwhisper", "DRUID" }, { "Quentrell", "HUNTER" }, { "Dreadhex", "WARLOCK" },
                    { "Kaelthrin", "MAGE" }, { "Shadowmelder", "ROGUE" }, { "Brightsong", "PRIEST" }, { "Stormcall", "SHAMAN" },
                    { "Grumpykat", "WARRIOR" }, { "Sylvaris", "HUNTER" }, { "Vexmora", "WARLOCK" }, { "Gina", "PALADIN" },
                    { "Lumenwyn", "PRIEST" } }
local function rnd(s) local x = sin(s * 12.9898 + 4.1414) * 43758.5453; return x - floor(x) end
local function io(k) k = max(0, min(1, k)); return k < 0.5 and 4 * k * k * k or 1 - ((-2 * k + 2) ^ 3) / 2 end
function UI:DemoRange(yd, t)
    R.yd, R.n, R.noPos = yd, 0, false; R.blocked = false
    local dots, near = R.dots, R.near
    for i = #dots, 1, -1 do dots[i] = nil end
    for i = #near, 1, -1 do near[i] = nil end
    for i, p in ipairs(DEMO_RAID) do
        local j = i - 1
        local a = rnd(j * 3.7) * math.pi * 2
        local d0, d1 = 3 + rnd(j * 5.1) * yd * 0.6, yd + 1 + rnd(j * 1.9) * 4.5
        local late = p[1] == "Moonwhisper" and 6.2 or p[1] == "Dreadhex" and 3.4 or p[1] == "Gina" and 4.4 or 0.6 + rnd(j * 2.3) * 2.2
        local k = io((t - late) / (1.6 + rnd(j * 4.4)))
        local x0, y0, x1, y1 = cos(a) * d0, sin(a) * d0, cos(a + 0.3) * d1, sin(a + 0.3) * d1
        local d = Dot(i)
        d.x, d.y = x0 + (x1 - x0) * k, y0 + (y1 - y0) * k
        d.d = (d.x * d.x + d.y * d.y) ^ 0.5
        d.close, d.n, d.cls = d.d < yd, p[1], p[2]
        dots[i] = d
        if d.close then R.n = R.n + 1; near[#near + 1] = d end
    end
    table.sort(near, function(p, q) return p.d < q.d end)
    return R
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function Soon(b) return b.kind == nil and (b.rem <= SOON or b.win ~= nil) end

function UI:Draw(dt)
    local L = self:Look()
    local bm = BM()
    local t = Now()
    local any = false
    -- bars
    local list = bm:Bars(t)
    local stackI, soonI = 0, 0
    local laneOn = L.soonLane or L.soonRing
    local nSoon = 0
    if laneOn then for _, o in ipairs(list) do if Soon(o) then nSoon = nSoon + 1 end end end
    local y = 0
    for _, b in ipairs(list) do
        local soon = Soon(b)
        if laneOn and soon then
            soonI = soonI + 1
            local k = b.win and 1 or max(0, min(1, (SOON - b.rem) / 0.3))
            local c = Begin(Host("soon", soonI, 20), "warns")
            if L.soonLane then
                local S = L.soonLane
                c.a = k
                L.bar(c, b, SPOTS.warns.w / 2 - S.w / 2, MID_Y + 78 + (soonI - 1) * (S.h + S.gap) + 10 * (1 - k), S.w, S.h, true, t)
            else
                L.ring(c, b, SPOTS.warns.w / 2 + (soonI - 1 - (nSoon - 1) / 2) * 90, MID_Y + 104, SOON - b.rem)
            end
            Pen:End()
        else
            stackI = stackI + 1
            local h = L.barH + ((soon and not laneOn) and (L.soonExtra or 6) or 0)
            local cur = ys[b.id]
            cur = cur and (cur + (y - cur) * min(1, (dt or 0) * 12)) or y
            ys[b.id] = cur
            local c = Begin(Host("bars", stackI, 10), "bars", 0, cur)
            c.a = max(0, min(1, (t - b.t0) / 0.25 + (b.kind and 1 or 0)))
            L.bar(c, b, 2, 0, SPOTS.bars.w - 4, h, soon, t)
            Pen:End()
            y = y + h + L.gap + ((soon and L.soonBelow) or 0)
        end
        any = true
    end
    for i = stackI + 1, #hosts.bars do Blank(hosts.bars[i]) end
    for i = soonI + 1, #hosts.soon do Blank(hosts.soon[i]) end
    -- the warning (the newest; an older one gives way)
    local w = warns[1]
    if w and t - w.t >= WARN_LIFE then
        for i = #warns, 1, -1 do warns[i] = nil end
        w = nil
    end
    local c = Begin(Host("warn", nil, 30), "warns")
    if w then
        local a = t - w.t
        c.a = max(0, min(1, a / 0.12)) * max(0, min(1, (WARN_LIFE - a) / 0.4))
        L.warn(c, w, SPOTS.warns.w / 2, MID_Y, a, WARN_LIFE)
        any = true
    end
    Pen:End()
    -- "on you" (the whole screen)
    Pen:Begin(Host("fx", nil, 1), 0, 0)
    local ya = t - youAt
    if ya >= 0 and ya < 3 then
        local sw = (UIParent:GetWidth() or 1024) / K()
        L.you(Pen.c, ya, sw, 540)
        any = true
    end
    Pen:End()
    -- the countdown
    c = Begin(Host("count", nil, 30), "count")
    local left = bm:Countdown(t)
    if not (bm:IsOn() or bm.preview) then left = nil end
    if left and left <= 5 then
        local n = math.ceil(left)
        L.count(c, n, 1 - (left - (n - 1)), SPOTS.count.w / 2, SPOTS.count.h / 2)
    end
    if left then any = true end
    Pen:End()
    -- the range frame
    c = Begin(Host("range", nil, 10), "range")
    local open = bm:Ranges(t)[1]
    if open then
        local Rm
        if open.m.demo then Rm = self:DemoRange(open.a.yd or 10, t - open.at) else Rm = self:Measure(open.a.yd or 10) end
        if Rm then
            c.a = max(0, min(1, (t - open.at) / 0.25))
            L.range(c, Rm, t - open.at, SPOTS.range.w / 2, SPOTS.range.h / 2)
        end
        any = true
    end
    Pen:End()
    if not any then self:Sleep() end
end

function UI:Wake()
    if awake or not driver then return end
    awake = true
    local last = Now()
    driver:SetScript("OnUpdate", function()
        local t = Now()
        local dt = t - last
        last = t
        local ok, err = pcall(UI.Draw, UI, dt)
        if not ok and ns.Debug then ns:Debug("boss mods draw: %s", tostring(err)) end
    end)
end

function UI:Sleep()
    if not awake then return end
    awake = false
    driver:SetScript("OnUpdate", nil)
    for _, h in ipairs(hosts.bars) do Blank(h) end
    for _, h in ipairs(hosts.soon) do Blank(h) end
    Blank(hosts.warn); Blank(hosts.count); Blank(hosts.range); Blank(hosts.fx)
end

function UI:IsAwake() return awake end

---------------------------------------------------------------------------
-- Warnings and their sounds
---------------------------------------------------------------------------

local SOUND = { warn = 8959, you = 12889 }     -- the raid warning; the alarm clock (SOUNDKIT.ALARM_CLOCK_WARNING_3)
function UI:OnWarn(w)
    if type(w) ~= "table" then return end
    if not (BM():IsOn() or BM().preview) then return end
    w.t = w.t or Now()
    table.insert(warns, 1, w)
    for i = #warns, 3, -1 do warns[i] = nil end
    if w.kind == "you" then youAt = w.t end
    if Get("bossmods.sounds", true) and PlaySound then
        local kit = w.kind == "you" and SOUND.you
            or w.kind == "warn" and SOUND.warn or nil
        if kit then pcall(PlaySound, kit, "Master") end
    end
    self:Wake()
end

---------------------------------------------------------------------------
-- Try it: a made-up Gruul pull (5 s countdown, then 18 s of the fight) through the real engine and data
---------------------------------------------------------------------------

local DEMO_BOSS = "GruulsLair:Gruul"
local demoTimers = {}
local demoFight
local looping = false

local function AlertBySpell(def, kind, spell)
    for _, a in ipairs(def.alerts or {}) do
        if a.spell == spell and (kind == nil or a.kind == kind) then return a end
    end
end

local function After(s, fn)
    if not C_Timer then return end
    local h = C_Timer.NewTimer(s, fn)
    demoTimers[#demoTimers + 1] = h
end

function UI:StopTry()
    for i = #demoTimers, 1, -1 do demoTimers[i]:Cancel(); demoTimers[i] = nil end
    local bm = BM()
    if demoFight then bm:EndFight(demoFight); demoFight = nil end
    bm.preview = false
    bm:OnCountdownCancel()
    UI.trying = nil
    if overlay then overlay:SetFrameStrata("HIGH") end
end

-- While a pull is tried the overlay sits above the windows (Try it is clicked in Settings, in the middle of the screen).
local function Showing()
    if overlay then overlay:SetFrameStrata("FULLSCREEN_DIALOG") end
end

function UI:TryIt(loop)
    local bm = BM()
    local def = bm and bm:Mod(DEMO_BOSS)
    if not def then return end
    self:Setup()
    self:StopTry()
    looping = loop and true or false
    bm.preview = true
    UI.trying = DEMO_BOSS
    if not looping then Showing() end
    bm:OnCountdown(5, "Kaelor")
    self:Wake()
    After(5, function()
        demoFight = bm:StartFight(def, { demo = true })
        local m = demoFight
        -- (the fight as the mockup shows it, a minute in: the bars a few seconds from their next cast)
        for _, seed in ipairs({ { 36300, 3 }, { 33525, 6 }, { 33813, 4.5 }, { 36297, 9 } }) do
            local a = AlertBySpell(def, "bar", seed[1])
            if a then m:Bar(a.key, seed[2]) end
        end
        local steps = {
            { 3, "AURA 36300", { amount = 4 } }, { 4.5, "SUCCESS 33813" }, { 6, "CAST 33525" }, { 9, "SUCCESS 36297" },
            { 10.5, "AURA 36240", { me = true, dstName = UnitName and UnitName("player") } }, { 12.5, "SUCCESS 33813" },
            { 16, "CAST 33654" },
        }
        for _, s in ipairs(steps) do After(s[1], function() bm:Inject(m, s[2], s[3]) end) end
        After(18, function()
            if demoFight then bm:EndFight(demoFight); demoFight = nil end
            if looping then UI:TryIt(true) else UI:StopTry() end
        end)
    end)
end

function UI:IsTrying() return BM() and BM().preview or false end

---------------------------------------------------------------------------
-- Try a boss: a short pull made from its own data (every fight, no script per boss). After a 3 s countdown each
-- phase in turn: its bars a few seconds from their next cast (and that cast then lands, so the bar starts again with
-- its real timer), its warnings one after another (the ones "on you" on you, the others on a made-up raider), its
-- range frame opening and closing, then the alert that moves the fight on (or the phase change itself).
---------------------------------------------------------------------------

local REEL_NAMES = { "Moonwhisper", "Dreadhex", "Victhar", "Brightsong", "Kaelthrin", "Gina" }
local REEL_BARS, REEL_WARNS = 5, 6

local function FirstTrigger(list)
    if type(list) == "table" then list = list[1] end
    return type(list) == "string" and list or nil
end

-- The event's details for an alert: on me when it is "you" (or every other time it has a "you" text), else on a
-- raider; a stack of 2 for stack counts; the caster its own creature.
local function Fields(a, i)
    local f = {}
    if a.count == "stack" or a.count == "next" then f.amount = 2 end
    if a.kind == "you" or a.me or (a.meText and i % 2 == 0) then f.me = true
    else f.dstName = REEL_NAMES[(i % #REEL_NAMES) + 1] end
    if type(a.src) == "table" and a.src[1] then f.srcNpc = a.src[1] end
    return f
end

-- The phases a boss's alerts name, in order (1 = the pull).
local function Phases(def)
    local list, seen = { 1 }, { [1] = true }
    local function Add(p) if type(p) == "number" and not seen[p] then seen[p] = true; list[#list + 1] = p end end
    for _, a in ipairs(def.alerts or {}) do
        if type(a.phase) == "number" then Add(a.phase) elseif type(a.phase) == "table" then for _, q in ipairs(a.phase) do Add(q) end end
        Add(a.setPhase)
    end
    table.sort(list)
    return list
end

local function InPhase(a, p)
    if a.phase == nil then return p == 1 end
    if type(a.phase) == "number" then return a.phase == p end
    for _, q in ipairs(a.phase) do if q == p then return true end end
    return false
end

-- Plans the reel: { { at, fn(m) }, ... } and its length.
function UI:Reel(def)
    local bm = BM()
    local steps, t = {}, 0.8
    local function At(at, fn) steps[#steps + 1] = { at, fn } end
    for pi, p in ipairs(Phases(def)) do
        if pi > 1 then
            local setter
            for _, a in ipairs(def.alerts or {}) do
                if a.setPhase == p and FirstTrigger(a.on) then setter = a break end
            end
            At(t, function(m)
                if setter then bm:Inject(m, FirstTrigger(setter.on), Fields(setter, 0)) end
                if m.phase ~= p then m:Phase(p) end
            end)
            t = t + 3.2
        end
        local seg, bars, warns, last = t, 0, 0, t
        for _, a in ipairs(def.alerts or {}) do
            if InPhase(a, p) and not a.setPhase then
                local on = FirstTrigger(a.on)
                if a.kind == "bar" and bars < REEL_BARS then
                    local lead = 3 + 1.6 * bars
                    bars = bars + 1
                    At(seg, function(m) m:Bar(a.key, lead) end)
                    if on and on ~= "ENGAGE" then
                        local i = bars
                        At(seg + lead, function(m) bm:Inject(m, on, Fields(a, i)) end)
                    end
                    last = math.max(last, seg + lead)
                elseif (a.kind == "warn" or a.kind == "you") and on and on ~= "ENGAGE" and warns < REEL_WARNS then
                    local at, i = seg + 1.2 + 2.4 * warns, warns
                    warns = warns + 1
                    At(at, function(m) bm:Inject(m, on, Fields(a, i)) end)
                    last = math.max(last, at + 2.2)
                elseif a.kind == "range" then
                    At(seg + 0.4, function(m)
                        if on and on ~= "ENGAGE" then bm:Inject(m, on, Fields(a, 0)) end
                        m:Range(a.key, true)
                    end)
                    At(seg + 7, function(m) m:Range(a.key, false) end)
                    last = math.max(last, seg + 7.5)
                end
            end
        end
        -- (a counter on screen drives the fight, Hyjal's waves: it counts on, wave 2, wave 3)
        if pi == 1 and type(def.fn) == "table" then
            for trig in pairs(def.fn) do
                if trig:match("^WIDGET") then
                    for n = 2, 3 do
                        local at = seg + 1.5 + (n - 2) * 4.5
                        At(at, function(m) bm:Inject(m, trig, { amount = n, text = "Wave " .. n .. " of 8" }) end)
                        last = math.max(last, at + 3)
                    end
                end
            end
        end
        t = math.max(last + 2, seg + 5)
    end
    return steps, t
end

-- Plays a boss's reel (Settings > Combat > Boss mods: the Try it of each fight).
function UI:TryBoss(key)
    local bm = BM()
    local def = bm and bm:Mod(key)
    if not def then return false end
    self:Setup()
    self:StopTry()
    looping = false
    bm.preview = true
    UI.trying = key
    Showing()
    bm:OnCountdown(3, "Kaelor")
    self:Wake()
    local steps, len = self:Reel(def)
    After(3, function()
        demoFight = bm:StartFight(def, { demo = true })
        local m = demoFight
        for _, st in ipairs(steps) do
            After(st[1], function() if m.live then st[2](m) end end)
        end
        After(len, function()
            if demoFight then bm:EndFight(demoFight); demoFight = nil end
            bm.preview = false
            UI.trying = nil
            if overlay then overlay:SetFrameStrata("HIGH") end
        end)
    end)
    return true, len + 3
end

-- Edit layout: the pull plays over and over while the spots are being moved.
function UI:Preview(on)
    if on then self:TryIt(true) else looping = false; self:StopTry() end
end

---------------------------------------------------------------------------
-- Login
---------------------------------------------------------------------------

function UI:OnLogin()
    self:Setup()
    for _, e in ipairs({ "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" }) do
        ns:RegisterEvent(e, function() UI:Rescale() end)
    end
    ns:On("BOSSMOD_WARN", function(w) UI:OnWarn(w) end)
    ns:On("SETTINGS_CHANGED", function(path)
        if path == "bossmods.size" or path == "bossmods.warnSize" then UI:Rescale() end
    end)
    for _, m in ipairs({ "BOSSMOD_BARS", "BOSSMOD_RANGE", "BOSSMOD_FIGHT" }) do ns:On(m, function() UI:Wake() end) end
    ns:On("DEMO_TOGGLED", function(on)
        if on and BM() and BM():IsOn() then UI:TryIt() end
    end)
end

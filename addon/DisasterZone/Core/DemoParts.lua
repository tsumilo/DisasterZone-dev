if DisasterZoneBoot and DisasterZoneBoot.Run("Core/DemoParts.lua", ...) then return end -- DisasterZone: Core/DemoParts.lua
-- The demo picker (2026-10-17, mockup claude.ai/artifact/TDAHyoxc54tzx3zTcFDHzn; the user: demo mode "plays literally
-- everything", pick what to demo from one place). Demo mode is three kinds of thing now:
--   the demo guild   Demo:IsEnabled (Core/Demo.lua): 18 made-up members fill the pages. Quiet: one switch.
--   screen parts     what shows outside the window (meters, plates, boss mods, timers, bars): each its own switch,
--                    Demo:IsOn(key). A part shows only while it is picked, and shows even if its feature is off.
--   moments          a scene played once that ends by itself (a loot rules scenario, the reserves night, the crest's
--                    night): Demo:Play(key).
-- UI/DemoList.lua registers every part and moment and the /dz demo command; Settings > Help > Demo mode
-- (UI/DemoPage.lua) lists them, the demo bar (UI/DemoBar.lua) shows what plays. Combat parts
-- play one pull of PULL seconds, or loop (demo.mode). The last picks are kept (demo.picks, demo.classes) for "Play my
-- picks"; nothing starts by itself after a reload. Everything stays in memory: nothing is sent or cast.
-- Messages: DEMO_PARTS_CHANGED(key, on) (a part, or "classes" / "mode" / "stop"), DEMO_PULL(started),
-- DEMO_MOMENT(key or nil).
local addonName, ns = ...

local Demo = ns.Demo
local Util = ns.Util

local ipairs, pairs, type, pcall, tostring = ipairs, pairs, type, pcall, tostring
local floor, max = math.floor, math.max
local tsort = table.sort

local PULL = 30                     -- a demo pull, in seconds
Demo.PULL = PULL

-- The page's groups, in order.
Demo.GROUPS = {
    screen = { { "combat", "Combat" }, { "frames", "Frames and bars" }, { "class", "Class tools" }, { "guild", "Guild" } },
    moment = { { "loot", "Loot" }, { "rules", "Loot rules scenarios" }, { "raid", "Raid night" },
               { "class", "Class tools" }, { "tour", "Look around" } },
}

local parts, order = {}, {}         -- key -> def; every def in page order
local on = {}                       -- [key] = true: a screen part playing now (this session)
local picked                        -- [CLASS] = true: other classes whose tools the demo shows (demo.classes)
local pullEnd, pullToken = nil, 0   -- GetTime() when the pull ends (one pull); a token voids old end timers
local loopAll = false               -- /dz demo on: everything, looping, until stopped
local moment                        -- { key, at, dur, token } while a moment plays
local momentToken = 0

local function Clock() return GetTime and GetTime() or 0 end
local function After(s, fn) if Util.After then Util.After(s, fn) elseif C_Timer then C_Timer.After(s, fn) end end
local function Setting(path) return ns.DB and ns.DB.GetSetting and ns.DB:GetSetting(path) end
local function Save(path, v) if ns.DB and ns.DB.SetSetting then ns.DB:SetSetting(path, v) end end
local function MyClass() local _, c = UnitClass("player"); return c end

---------------------------------------------------------------------------
-- The registry
---------------------------------------------------------------------------

-- def: { key, kind = "screen" | "moment", group (Demo.GROUPS), label, desc, icon (UI.ICON atlas index, or a texture /
-- spell id), order, word (/dz demo <word>; the key by default), class (a class tool's: listed while that class is
-- picked), kit (its ClassKit key), guild (runs on the demo guild: switches it on), pull (plays per pull: combat),
-- ready() -> ok, why (a part that needs one of its feature's switches), play(owner) -> ok, why (a moment),
-- stop() (a moment cut short), dur (a moment's seconds), running() (a moment that ends when this turns false) }
function Demo:RegisterPart(def)
    if type(def) ~= "table" or type(def.key) ~= "string" or parts[def.key] then
        error("Demo:RegisterPart: a new key is required", 2)
    end
    def.kind = def.kind or "screen"
    def.word = def.word or def.key
    def.order = def.order or 50
    parts[def.key] = def
    order[#order + 1] = def
    tsort(order, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.key < b.key
    end)
    return def
end

function Demo:GetPart(key) return parts[key] end

-- Every part of a kind ("screen" / "moment"), in page order; group: only that group's.
function Demo:Parts(kind, group)
    local out = {}
    for _, d in ipairs(order) do
        if (not kind or d.kind == kind) and (not group or d.group == group) then out[#out + 1] = d end
    end
    return out
end

local function ByWord(word)
    for _, d in ipairs(order) do
        if d.word == word or d.key == word then return d end
    end
end
Demo.ByWord = function(_, word) return ByWord(word) end   -- (a part or moment by its /dz demo word or key)

---------------------------------------------------------------------------
-- Classes: whose class tools the demo shows (mine always)
---------------------------------------------------------------------------

local function Picked()
    if not picked then
        picked = {}
        local saved = Setting("demo.classes")
        if type(saved) == "table" then for cls, v in pairs(saved) do if v then picked[cls] = true end end end
    end
    return picked
end

function Demo:IsClassPicked(cls)
    if type(cls) ~= "string" then return false end
    return cls == MyClass() or Picked()[cls] == true
end

function Demo:SetClassPicked(cls, want)
    if type(cls) ~= "string" or cls == MyClass() then return end
    local p = Picked()
    want = want and true or nil
    if p[cls] == want then return end
    p[cls] = want
    -- (a class put away takes its tools off the screen)
    if not want then
        for key, d in pairs(parts) do if d.class == cls and on[key] then self:SetOn(key, false) end end
    end
    local copy = {}
    for c in pairs(p) do copy[c] = true end
    Save("demo.classes", copy)
    ns:Fire("DEMO_PARTS_CHANGED", "classes", want and true or false)
end

---------------------------------------------------------------------------
-- Screen parts
---------------------------------------------------------------------------

-- Is that part playing now (picked, and its class picked for a class tool)?
function Demo:IsOn(key)
    if not on[key] then return false end
    local d = parts[key]
    return not (d and d.class) or self:IsClassPicked(d.class)
end

-- The parts playing now, in page order.
function Demo:OnList()
    local out = {}
    for _, d in ipairs(order) do
        if d.kind == "screen" and self:IsOn(d.key) then out[#out + 1] = d end
    end
    return out
end

-- Anything of demo mode going: the guild, a part or a moment.
function Demo:IsActive()
    return self:IsEnabled() or next(on) ~= nil or moment ~= nil
end

-- A part that needs one of its feature's switches first: false, why.
function Demo:Ready(key)
    local d = parts[key]
    if not (d and d.ready) then return true end
    local ok, ready, why = pcall(d.ready)
    if not ok then return true end
    return ready and true or false, why
end

-- Keeps the picks for "Play my picks" (never empty: stopping keeps the last set).
local function SavePicks()
    local copy, any = {}, false
    for key in pairs(on) do copy[key] = true; any = true end
    if any then Save("demo.picks", copy) end
end

-- Switches a part on or off without keeping the picks or starting the pull. Returns the new state.
local function Switch(key, want)
    local d = parts[key]
    if not (d and d.kind == "screen") then return false end
    want = want and true or false
    if (on[key] or false) == want then return want end
    if want then
        if d.guild and not Demo:IsEnabled() then
            Demo:SetEnabled(true)
            if not Demo:IsEnabled() then return false end   -- (not logged in yet: SetEnabled said so)
        end
        if d.class and d.class ~= MyClass() and not Picked()[d.class] then Demo:SetClassPicked(d.class, true) end
        on[key] = true
    else
        on[key] = nil
        if not next(on) then loopAll = false end
    end
    ns:Fire("DEMO_PARTS_CHANGED", key, want)
    return want
end

function Demo:SetOn(key, want)
    local d = parts[key]
    if not (d and d.kind == "screen") then return false end
    local was = on[key] or false
    local now = Switch(key, want)
    if now ~= was then
        SavePicks()
        if now and d.pull then self:StartPull() end
    end
    return now
end

function Demo:TogglePart(key) return self:SetOn(key, not on[key]) end

-- Several at once: the picks kept (unless keep == false) and the pull started once.
local function SetMany(keys, want, keep)
    local pull = false
    for _, key in ipairs(keys) do
        local d = parts[key]
        if d and d.kind == "screen" and (on[key] or false) ~= want then
            Switch(key, want)
            if want and d.pull then pull = true end
        end
    end
    if keep ~= false then SavePicks() end
    if pull then Demo:StartPull() end
end

---------------------------------------------------------------------------
-- The pull: combat parts play PULL seconds (or loop), then stop
---------------------------------------------------------------------------

function Demo:GetMode() return loopAll and "loop" or (Setting("demo.mode") == "loop" and "loop" or "once") end
function Demo:IsLooping() return self:GetMode() == "loop" end

function Demo:SetMode(mode)
    mode = mode == "loop" and "loop" or "once"
    Save("demo.mode", mode)
    if mode == "once" then loopAll = false end
    ns:Fire("DEMO_PARTS_CHANGED", "mode", mode == "loop")
    if self:AnyPull() then self:StartPull() end
end

-- Is a part that plays per pull on?
function Demo:AnyPull()
    for key in pairs(on) do
        local d = parts[key]
        if d and d.pull and self:IsOn(key) then return true end
    end
    return false
end

-- A pull is playing: looping, or inside the one pull's PULL seconds.
function Demo:IsPulling()
    if not next(on) then return false end
    if self:IsLooping() then return true end
    return pullEnd ~= nil and Clock() < pullEnd
end

-- That part is on and its pull is playing (timers swing only then).
function Demo:IsPlaying(key) return self:IsOn(key) and self:IsPulling() end

-- Seconds left of the one pull (nil: looping or no pull).
function Demo:PullLeft()
    if self:IsLooping() or not pullEnd then return nil end
    return max(0, pullEnd - Clock())
end

function Demo:StartPull()
    pullToken = pullToken + 1
    local token = pullToken
    pullEnd = Clock() + PULL
    ns:Fire("DEMO_PULL", true)
    if not self:IsLooping() then
        After(PULL + 0.05, function()
            if token ~= pullToken then return end
            pullEnd = nil
            ns:Fire("DEMO_PULL", false)
        end)
    end
end

---------------------------------------------------------------------------
-- Moments
---------------------------------------------------------------------------

function Demo:GetMoment() return moment and moment.key or nil, moment end

-- Seconds a moment has played and its length (nil for one that ends by itself).
function Demo:MomentTime()
    if not moment then return nil end
    return Clock() - moment.at, moment.dur
end

function Demo:StopMoment(quiet)
    if not moment then return end
    local d = parts[moment.key]
    moment = nil
    if d and d.stop then pcall(d.stop) end
    if not quiet then ns:Fire("DEMO_MOMENT", nil) end
end

local function Watch(token, d)
    After(1, function()
        if not (moment and moment.token == token) then return end
        local ok, running = pcall(d.running)
        if ok and not running then Demo:StopMoment() else Watch(token, d) end
    end)
end

-- Plays a moment (owner: the button a menu opens at). Returns true, or false + why.
function Demo:Play(key, owner)
    local d = parts[key]
    if not (d and d.kind == "moment" and d.play) then return false, "no such moment" end
    if d.guild ~= false and not self:IsEnabled() then
        self:SetEnabled(true)
        if not self:IsEnabled() then return false, "demo mode could not be turned on" end
    end
    self:StopMoment(true)
    momentToken = momentToken + 1
    local token = momentToken
    moment = { key = key, at = Clock(), dur = d.dur, token = token }
    local ok, played, why = pcall(d.play, owner)
    if not ok or played == false then
        moment = nil
        ns:Fire("DEMO_MOMENT", nil)
        return false, ok and why or tostring(played)
    end
    if d.dur then
        After(d.dur, function() if moment and moment.token == token then Demo:StopMoment() end end)
    elseif d.running then
        Watch(token, d)
    end
    ns:Fire("DEMO_MOMENT", key)
    return true
end

---------------------------------------------------------------------------
-- Sets
---------------------------------------------------------------------------

-- Stops every part and moment (the guild stays; guild = true: the guild too).
function Demo:StopAll(guild)
    local keys = {}
    for key in pairs(on) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do on[key] = nil; ns:Fire("DEMO_PARTS_CHANGED", key, false) end
    loopAll = false
    picked = nil                       -- (read again from demo.classes: /dz demo on's every class is not kept)
    pullEnd = nil
    pullToken = pullToken + 1
    self:StopMoment(true)
    if guild and self:IsEnabled() then self:SetEnabled(false) end
    ns:Fire("DEMO_PARTS_CHANGED", "stop", false)
    ns:Fire("DEMO_MOMENT", nil)
end

-- The parts last picked (demo.picks), in page order.
function Demo:SavedPicks()
    local saved, out = Setting("demo.picks"), {}
    if type(saved) ~= "table" then return out end
    for _, d in ipairs(order) do
        if d.kind == "screen" and saved[d.key] then out[#out + 1] = d.key end
    end
    return out
end

function Demo:PlayPicks()
    local keys = self:SavedPicks()
    if #keys == 0 then return false end
    SetMany(keys, true)
    return true
end

-- Quick picks: { key, label, tip }; the page draws them in this order.
Demo.PRESETS = {
    { key = "pages", label = "Pages only", tip = "The demo guild fills the pages. Nothing plays on screen." },
    { key = "combat", label = "In combat", tip = "Meters, combat text, boss mods and nameplates: one made-up pull." },
    { key = "frames", label = "Raid frames", tip = "A made-up party and main tanks next to you." },
    { key = "class", label = "My class", tip = "Your class's tools with made-up data." },
    { key = "all", label = "Everything", tip = "The demo guild and every part, for every class." },
}

local function PresetKeys(key)
    local out = {}
    if key == "combat" then
        out = { "meters", "threat", "sct", "bossmods", "plates" }
    elseif key == "frames" then
        out = { "party", "tanks" }
    elseif key == "class" then
        for _, d in ipairs(order) do if d.kind == "screen" and d.class == MyClass() then out[#out + 1] = d.key end end
    elseif key == "all" then
        for _, d in ipairs(order) do if d.kind == "screen" then out[#out + 1] = d.key end end
    end
    return out
end

-- Switches on a quick pick (the others off). Returns true.
function Demo:Preset(key)
    if key == "all" then
        for _, d in ipairs(order) do
            if d.class and d.class ~= MyClass() then Picked()[d.class] = true end
        end
        local copy = {}
        for c in pairs(Picked()) do copy[c] = true end
        Save("demo.classes", copy)
        ns:Fire("DEMO_PARTS_CHANGED", "classes", true)
    end
    if key == "pages" or key == "all" then
        if not self:IsEnabled() then self:SetEnabled(true) end
    end
    local want = {}
    for _, k in ipairs(PresetKeys(key)) do want[k] = true end
    local off = {}
    for k in pairs(on) do if not want[k] then off[#off + 1] = k end end
    for _, k in ipairs(off) do Switch(k, false) end
    local list = {}
    for k in pairs(want) do list[#list + 1] = k end
    SetMany(list, true)
    return true
end

-- The quick pick matching what plays now (nil: none does).
function Demo:CurrentPreset()
    local now = {}
    local n = 0
    for _, d in ipairs(self:OnList()) do now[d.key] = true; n = n + 1 end
    if n == 0 then return (self:IsEnabled() and not moment) and "pages" or nil end
    for _, p in ipairs(self.PRESETS) do
        if p.key ~= "pages" then
            local keys = PresetKeys(p.key)
            if #keys == n then
                local same = true
                for _, k in ipairs(keys) do if not now[k] then same = false break end end
                if same and (p.key ~= "all" or self:IsEnabled()) then return p.key end
            end
        end
    end
    return nil
end

-- /dz demo on: the demo guild and every part, looping, until it is stopped (what one switch did before 1.6.0).
function Demo:Everything()
    if not self:IsEnabled() then self:SetEnabled(true) end
    if not self:IsEnabled() then return false end
    loopAll = true
    -- (every class for now, not kept: Stop all goes back to the classes picked on the page)
    for _, d in ipairs(order) do if d.class and d.class ~= MyClass() then Picked()[d.class] = true end end
    ns:Fire("DEMO_PARTS_CHANGED", "classes", true)
    SetMany(PresetKeys("all"), true, false)
    return true
end

-- The guild switched off takes the parts and moments that run on it along.
ns:On("DEMO_TOGGLED", function(enabled)
    if enabled then return end
    for key, d in pairs(parts) do
        if d.guild and on[key] then Switch(key, false) end
    end
    if moment and parts[moment.key] and parts[moment.key].guild ~= false then Demo:StopMoment() end
end)

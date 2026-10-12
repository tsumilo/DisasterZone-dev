if DisasterZoneBoot and DisasterZoneBoot.Run("UI/ShotTimerHUD.lua", ...) then return end -- DisasterZone: shot timer HUD.
-- The on-screen part of Core/ShotTimer.lua: the swing timer's ring (ns.SwingRing, UI/SwingTimerHUD.lua) driven by the
-- Hunter's Auto Shot. One turn of the ring is one Auto Shot to the next: gold fills from the shot that just left, the
-- orange window is when the next cast (Steady Shot, or Multi-Shot) fits before the next shot, brightest right after the
-- shot (the best moment) and fading toward its end (still worth it, but it starts to delay the shot); an instant next
-- (Arcane Shot, Kill Command) has no window, only its icon. The dim red end is
-- the next shot's windup (stand still, cast nothing). It flashes when a shot leaves; the badge is your aspect.
-- The lane shows the next ~7 s: the shots, the cast windows and every press the planner placed (fillers in blue).
local addonName, ns = ...

local HUD = ns:NewModule("ShotTimerHUD")
local ST                         -- ns.ShotTimer

local floor, max, min = math.floor, math.max, math.min
local strformat = string.format

-- Lane labels have about 60 px.
local SHORT = { steady = "Steady", multi = "Multi", arcane = "Arcane", kc = "Kill Cmd", hawk = "Hawk", viper = "Viper" }

local D = {
    prefix = "shot", frameName = "DisasterZoneShotTimer", lockHint = "Shot timer: drag it, then /dz shot lock",
    FILLERS = { multi = true, arcane = true },
    FADE = true,                 -- best right after the shot, still worth it (but late) toward the window's end
}
function D.Get(path, default) return ST.Get(path, default) end
function D:IsActive() return ST.active end
function D:IsDemo() return ST:IsDemo() end
function D:Current() return ST:Current() end
function D.Icon(key) return ST.ICONS[key] end
function D.NameOf(key) return ST.NameOf(key) end
function D.Short(key) return SHORT[key] or ST.NameOf(key) or key end
-- (a cast's block is its cast; Kill Command is off the GCD)
function D.StepWidth(st, snap)
    if st.off then return 0.4 end
    return max(st.cast or 0, snap.gcd)
end
-- Where it sits at first: the swing timer's place; in demo mode on another class's character, beside it (both show).
function D:DefaultPos()
    local _, cls = UnitClass("player")
    if cls ~= "HUNTER" and ns.ClassKit:IsDemo() then return 280, -170 end
    return 0, -170
end
function D:RestIcon() return GetInventoryItemTexture("player", 18) or ST.ICONS.auto end
function D:Badge()
    local a = ST:IsDemo() and "hawk" or ST.state.aspect
    if not a then return nil end
    return ST.ICONS[a], ""
end

-- The next cast-time shot in the plan before the next Auto Shot leaves: its window, from when it can be pressed to
-- the last moment it still fits.
local function CastWindow(cur)
    local snap, steps = cur.snap, cur.plan.steps
    local fire = snap.nextStart + snap.windup
    for _, st in ipairs(steps) do
        if st.at >= fire then break end
        if st.cast and st.latest then
            -- (a press due now has been possible since the shot, GCD or cast before it ended)
            local z0 = st.at <= snap.now + 0.001 and min(st.at, max(snap.readySince or st.at, snap.now - snap.cycle)) or st.at
            return st, z0, min(st.latest, snap.nextStart - snap.lat)
        end
    end
end

function D:Face(cur, now)
    local snap, steps = cur.snap, cur.plan.steps
    local to = snap.nextStart + snap.windup
    local from = snap.lastShot or (to - snap.cycle)
    if from >= to then from = to - snap.cycle end
    local st, z0, z1 = CastWindow(cur)
    if st and z1 < z0 then st = nil end
    -- hot: that cast is the next press on the GCD (Kill Command, off the GCD, may come first)
    local nextOn
    for _, s in ipairs(steps) do if not s.off then nextOn = s break end end
    -- (only when that cast is the next press: an instant first shows no window, just its icon)
    if nextOn ~= st then st = nil end
    return { from = from, to = to, z0 = st and z0 or nil, z1 = st and z1 or nil, hot = st ~= nil,
             red0 = snap.nextStart, landed = ST.state.last }
end

-- The last shot and the next ones; the window of every cast the planner placed.
function D:Lane(cur, now)
    local snap = cur.snap
    local marks, windows = {}, {}
    if snap.lastShot then marks[1] = { t = snap.lastShot, strong = true } end
    for _, t in ipairs(cur.plan.shots) do
        if #marks >= 4 then break end
        marks[#marks + 1] = { t = t, strong = true }
    end
    for _, st in ipairs(cur.plan.steps) do
        if st.cast and st.latest and st.latest > st.at then windows[#windows + 1] = { st.at, st.latest } end
    end
    return marks, windows
end

local ring = ns.SwingRing(D)
HUD.ring = ring
function HUD:Update() return ring:Update() end
function HUD:Ring() return ring:Ring() end
function HUD:Refresh() return ring:Refresh() end

function HUD:OnLogin()
    ST = ns.ShotTimer
    if not ST then return end
    ring:Hook("SHOT_STATE")
end

-- The kit's Settings card (Settings > Class tools; every Hunter spec).
if ns.ClassKit then ns.ClassKit:Extend("shot", { iconPath = "Interface\\Icons\\Ability_Hunter_SteadyShot",
    settings = function(S, sec)
    -- (on/off is the switch on the card's header: shot.enabled)
    ns.SwingRingSettings(S, sec, "shot", "Auto averages your world latency with what it measures from your own "
        .. "casts (the time from pressing Steady Shot to it starting). /dz shot shows both.")
    S:SwitchSetting(sec, "Multi-Shot", "When its cast fits before the next Auto Shot. On in WoWSims' rotation.", "shot.use.multi", true)
    S:SwitchSetting(sec, "Arcane Shot", "When nothing with a cast fits. On in WoWSims' rotation.", "shot.use.arcane", true)
    S:SwitchSetting(sec, "Kill Command", "Off the GCD, after you crit.", "shot.use.kc", true)
    S:SwitchSetting(sec, "Aspect hints", "Viper when you run dry, Hawk once you have mana again.", "shot.aspects", true)
    local lows, highs = {}, {}
    for _, n in ipairs({ 5, 10, 15, 20, 30 }) do lows[#lows + 1] = { value = n, text = n .. "%" } end
    for _, n in ipairs({ 20, 25, 30, 40, 50, 60, 80 }) do highs[#highs + 1] = { value = n, text = n .. "%" } end
    S:DropdownSetting(sec, "Viper below", "WoWSims: 5% mana.", "shot.viperStart", 5, lows)
    S:DropdownSetting(sec, "Hawk again at", "WoWSims: 25% mana.", "shot.viperStop", 25, highs)
    S:SwitchSetting(sec, "Sound in the cast window", "A click when it is time for Steady Shot.", "shot.sound", false)
    local row = S:Row(sec, "Last fight", "")
    row.hasDesc = true
    S.PlaceText(row, 0)
    S.refreshers[#S.refreshers + 1] = {
        Refresh = function()
            local r = ns.ShotTimer and ns.ShotTimer:Reports()[1]
            if not r then row.desc:SetText("No fight yet. /dz shot report prints the latest one.") return end
            local c = r.counts or {}
            local clean, clip, moved = c.clean or 0, c.clip or 0, c.moved or 0
            row.desc:SetText(strformat("%s: %d/%d Auto Shots on time, %d clipped (%.1f s lost), %d held by moving.",
                r.target or "Fight", clean, clean + clip + moved, clip, r.lost or 0, moved))
        end,
    }
    S:EndSection(sec)
end }) end

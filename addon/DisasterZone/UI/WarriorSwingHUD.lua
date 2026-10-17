if DisasterZoneBoot and DisasterZoneBoot.Run("UI/WarriorSwingHUD.lua", ...) then return end -- DisasterZone: warrior swing timer HUD.
-- The on-screen part of Core/WarriorSwing.lua: the swing timer's ring (ns.SwingRing, UI/SwingTimerHUD.lua) in its
-- "warrior" variant (UI/RingFace.lua RF.VARIANT.warrior). One turn of the outer cycle is the main hand's swing: gold
-- fills toward the next hit, orange is the last stretch where queueing Heroic Strike is the call (hot while the lamp
-- says "queue"), dim red your latency at its end (too late). Two-handed Arms: the window sits at the start instead,
-- Slam right after the swing. The inner cycle is the off hand (pale, brighter while Heroic Strike is queued: the queue
-- lifts the dual-wield miss penalty). Rage: the globe in the middle (Halo, Sigil, Gilded) or a third bar (Slate, Pips,
-- Classic), the gold line the Heroic Strike line, rage over it bright. The lamp sits on the main hand's landing point.
-- The next press and the two after it sit beside the ring; the badge is Rampage (or Battle Shout without it).
local addonName, ns = ...

local HUD = ns:NewModule("WarriorSwingHUD")
local ST                         -- ns.WarriorSwing

local floor, max, min = math.floor, math.max, math.min
local strformat = string.format

local SHORT = { bt = "Bloodthirst", ms = "Mortal", ww = "Whirlwind", exe = "Execute", slam = "Slam", shout = "Shout",
                rampage = "Rampage", ham = "Hamstring", brage = "Bloodrage", sweep = "Sweeping", op = "Overpower",
                rend = "Rend" }

local D = {
    prefix = "war", frameName = "DisasterZoneWarriorSwing", layoutName = "Swing timer (Warrior)", layoutOrder = 32,
    FILLERS = { ham = true },
    VARIANT = "warrior",
}
function D.Get(path, default) return ST.Get(path, default) end
-- "Rage in the timer" (war.rage) off: the face without the globe or rage row (RingFace's warrior_bare); the resource bar
-- (UI/ResourceBar.lua) can carry the rage instead.
function D:Variant() return ST.Get("rage", true) and "warrior" or "warrior_bare" end
function D:IsActive() return ST.active end
function D:IsDemo() return ST:IsDemo() end
function D:Current() return ST:Current() end
function D.Icon(key) return ST.ICONS[key] end
function D.NameOf(key) return ST.NameOf(key) end
function D.Short(key) return SHORT[key] or ST.NameOf(key) or key end
function D.StanceIcon(n) return ST.ICONS["st" .. tostring(n)] end
function D.StepWidth(st, snap)
    if st.off then return 0.4 end
    return max(st.cast or 0, snap.gcd)
end
-- Where it sits at first: the swing timer's place; in demo mode on another class's character, left of the others.
function D:DefaultPos()
    local _, cls = UnitClass("player")
    if cls ~= "WARRIOR" and ns.ClassKit:IsDemo("war") then return -300, -170 end
    return 0, -170
end
function D:RestIcon() return GetInventoryItemTexture("player", 16) or ST.ICONS.wait end
function D:Badge()
    local key = ST.Known("rampage") and "rampage" or (ST.Known("shout") and "shout" or nil)
    if not key then return nil end
    local left = ST.BuffLeft(key, GetTime())
    return ST.ICONS[key], (left > 0 and left < 6) and strformat("%d", left) or ""
end

local function FirstOnGcd(steps)
    for _, s in ipairs(steps) do if not s.off then return s end end
end

function D:Face(cur, now)
    local snap = cur.snap
    local nxt, lat = snap.mhNext, snap.lat
    local from = nxt - snap.mhSpeed
    local first = FirstOnGcd(cur.plan.steps)
    local z0, z1, hot
    if snap.spec == "arms" and snap.twoHand and snap.use.slam then
        -- Slam right after the swing
        z0, z1 = from, from + lat + ST.SLAM_AFTER
        hot = first ~= nil and first.key == "slam"
    elseif cur.lamp then
        z0, z1 = nxt - ST.HS_WINDOW - lat, nxt - lat
        hot = cur.lamp == "queue"
    end
    return { from = from, to = nxt, z0 = z0, z1 = z1, hot = hot or false, red0 = nxt - lat,
             landed = ST.state.mhLast, extraAt = ST.state.extraAt }
end

function D:Extra(cur, now)
    local snap = cur.snap
    local oh
    if snap.ohSpeed and snap.ohNext then
        local f = 1 - (snap.ohNext - now) / snap.ohSpeed
        oh = { max(0, min(1, f)), snap.queued ~= nil and ST.Get("ohBright", true) and true or false }
    end
    return { oh = oh, rage = { snap.rage / 100, snap.line / 100 },
             num = ST.Get("number", true) and floor(snap.rage + 0.5) or nil,
             lamp = cur.lamp, lampIcon = ST.ICONS[snap.queued or cur.lampKey or "hs"],
             still = not ST.Get("motion", true) }
end

function D:RestExtra()
    local info = ST:RestInfo()
    return { oh = info.oh, rage = info.rage / 100, line = info.line / 100 }
end

-- The main-hand swings; the press windows before them (Heroic Strike) or after them (Slam).
function D:Lane(cur, now)
    local snap = cur.snap
    local marks, windows = {}, {}
    local t = snap.mhNext - snap.mhSpeed
    local slam = snap.spec == "arms" and snap.twoHand and snap.use.slam
    for i = 1, 4 do
        marks[i] = { t = t, strong = true }
        if slam then windows[#windows + 1] = { t, t + snap.lat + ST.SLAM_AFTER }
        elseif i == 2 and cur.lamp == "queue" then windows[#windows + 1] = { t - ST.HS_WINDOW - snap.lat, t - snap.lat } end
        t = t + snap.mhSpeed
    end
    return marks, windows
end

local ring = ns.SwingRing(D)
HUD.ring = ring
function HUD:Update() return ring:Update() end
function HUD:Ring() return ring:Ring() end
function HUD:Frame() return ring:Frame() end
function HUD:Refresh() return ring:Refresh() end

function HUD:OnLogin()
    ST = ns.WarriorSwing
    if not ST then return end
    ring:Hook("WAR_STATE")
end

-- The kit's Settings card (Settings > Class tools; Arms and Fury).
if ns.ClassKit then ns.ClassKit:Extend("war", { iconPath = "Interface\\Icons\\Ability_Rogue_Ambush",
    settings = function(S, sec)
    -- (on/off is the switch on the card's header: war.enabled)
    ns.SwingRingSettings(S, sec, "war", "Auto averages your world latency with what it measures from your own "
        .. "presses (the time from pressing to the server answering). /dz war shows both.")
    local lines = { { value = 0, text = "Auto" } }
    for _, n in ipairs({ 30, 40, 50, 60, 70, 80 }) do lines[#lines + 1] = { value = n, text = n .. " rage" } end
    S:DropdownSetting(sec, "Heroic Strike line", "Queue it when your rage is over this.", "war.hsLine", 0, lines,
        "Auto uses WoWSims' line: 40 rage for Fury and dual-wield Arms, 80 for Arms with a two-hander. Raise it if "
            .. "you run out of rage for Bloodthirst or Mortal Strike.")
    S:SwitchSetting(sec, "Rage in the timer", "Off: the globe (or the rage bar) goes and the next press takes the middle "
        .. "of the ring, as on the Ret and Hunter rings. The resource bar (Class tools) can show your rage instead.",
        "war.rage", true)
    S:SwitchSetting(sec, "Rage number", "Your rage in numbers on the globe or bar.", "war.number", true)
    S:SwitchSetting(sec, "Moving rage", "The globe's rage sways, sloshes when it changes and bubbles; "
        .. "bars slide to the new value. Off: it just shows the level.", "war.motion", true)
    S:SwitchSetting(sec, "Brighter off hand", "The off-hand ring brightens while Heroic Strike is queued "
        .. "(the queue lifts the dual-wield miss penalty).", "war.ohBright", true)
    S:SwitchSetting(sec, "Whirlwind", "In Berserker stance. On in WoWSims' rotation.", "war.use.ww", true)
    S:SwitchSetting(sec, "Slam", "Arms with a two-hander: right after each swing.", "war.use.slam", true)
    S:SwitchSetting(sec, "Rampage", "When it is usable and running out.", "war.use.rampage", true)
    S:SwitchSetting(sec, "Battle Shout", "With 10 seconds or less left.", "war.use.shout", true)
    S:SwitchSetting(sec, "Bloodrage", "Off the GCD, under 90 rage.", "war.use.brage", true)
    S:SwitchSetting(sec, "Hamstring weaving", "Over 60 rage when nothing else is up. Only pays with Sword "
        .. "Specialization or Windfury.", "war.use.ham", false)
    S:SwitchSetting(sec, "Sound in the window", "A click when it is time to queue Heroic Strike.", "war.sound", false)
    local row = S:Row(sec, "Last fight", "")
    row.hasDesc = true
    S.PlaceText(row, 0)
    S.refreshers[#S.refreshers + 1] = {
        Refresh = function()
            local r = ns.WarriorSwing and ns.WarriorSwing:Reports()[1]
            if not r then row.desc:SetText("No fight yet. /dz war report prints the latest one.") return end
            row.desc:SetText(strformat("%s: %d main-hand swings, %d Heroic Strikes, %d at full rage.",
                r.target or "Fight", r.mh or 0, r.hs or 0, r.capped or 0))
        end,
    }
    local Ch = ns.SituationChoices
    ns.SituationSettings(S, sec, "war", { pack = true,
        packRows = function(S, sec, R)
            R(select(2, S:DropdownSetting(sec, "Cleave line", "Queue Cleave from this much rage in a pack (WoWSims: "
                .. "40 for every spec).", "war.cleaveLine", 40, Ch({ 20, 30, 40, 50, 60, 70, 80 }, "%d rage"))))
            R(select(2, ns.SituationPicks(S, sec, "Pack presses", "WoWSims' list for more than one target. Each only "
                .. "shows when you have the spell.", "war.pack.", { { "sweep", "Sweeping Strikes" },
                    { "ww", "Whirlwind" }, { "slam", "Slam" }, { "ms", "Mortal Strike" }, { "exe", "Execute" },
                    { "cleave", "Cleave" } })))
        end,
        playerRows = function(S, sec, R)
            R(select(2, S:DropdownSetting(sec, "Stance dancing", "Show the stance a press needs in its corner "
                .. "(Overpower: Battle, Whirlwind: Berserker).", "war.dance", "players",
                Ch({ { "never", "Never" }, { "players", "Against players" }, { "always", "Always" } }))))
            R(select(2, S:DropdownSetting(sec, "Most rage a swap may cost", "A swap keeps 10 rage, 25 with 3/3 "
                .. "Tactical Mastery. If it would throw away more than this, the press waits for your stance.",
                "war.danceRage", 10, Ch({ 0, 5, 10, 15, 20, 30, 50 }, "%d rage"))))
            R(select(2, S:DropdownSetting(sec, "Refresh Hamstring", "Press it again this long before it runs out.",
                "war.hamRefresh", 2, Ch({ 1, 2, 3, 4, 5 }, "%d s"))))
            local lines = { { 0, "Same as one target" } }
            for _, n in ipairs({ 30, 40, 50, 60, 70, 80 }) do lines[#lines + 1] = { n, n .. " rage" } end
            R(select(2, S:DropdownSetting(sec, "Heroic Strike line", "Against players.", "war.hsLinePlayer", 0,
                Ch(lines))))
            R(select(2, ns.SituationPicks(S, sec, "Player presses", "Each only shows when you have the spell. Slam "
                .. "(a cast: you stand still) and Rend are off until you pick them.", "war.player.",
                { { "ham", "Hamstring" }, { "ms", "Mortal Strike" }, { "op", "Overpower" }, { "ww", "Whirlwind" },
                  { "exe", "Execute" }, { "hs", "Heroic Strike" }, { "slam", "Slam" }, { "rend", "Rend" } },
                { slam = false, rend = false })))
        end })
    S:EndSection(sec)
end }) end

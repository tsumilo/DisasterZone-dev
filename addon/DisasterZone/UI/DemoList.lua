if DisasterZoneBoot and DisasterZoneBoot.Run("UI/DemoList.lua", ...) then return end -- DisasterZone UI/DemoList.lua
-- Every demo the addon has, for the Demo picker (Core/DemoParts.lua: the registry; mockup
-- claude.ai/artifact/TDAHyoxc54tzx3zTcFDHzn): the parts that show on screen, the moments played once, and /dz demo.
-- A new feature with a demo adds its entry here; its own code asks ns.Demo:IsOn("<key>") (or listens to DEMO_PULL).
local addonName, ns = ...

local Demo = ns.Demo

local ipairs, type, tostring, max = ipairs, type, tostring, math.max

local function After(s, fn) if ns.Util.After then ns.Util.After(s, fn) elseif C_Timer then C_Timer.After(s, fn) end end

---------------------------------------------------------------------------
-- The parts
---------------------------------------------------------------------------

local function Look() return ns.Look end
local function EndDemoRoll()
    local R = ns.Roll
    local a = R and R.GetActive and R:GetActive()
    if a and a.demo and R.End then pcall(R.End, R, a.id) end
end

-- combat
Demo:RegisterPart({ key = "meters", group = "combat", order = 10, label = "Damage meter", icon = 58,
    desc = "Your damage panels show a made-up Tempest Keep night.",
    ready = function()
        local M = ns.Meter
        return not (M and M.IsEnabled) or M:IsEnabled(), "Switch the damage meter on first: Settings > Combat > Meters."
    end })
Demo:RegisterPart({ key = "threat", group = "combat", order = 11, label = "Threat meter", icon = 58,
    desc = "The threat panel shows a Void Reaver pull.",
    ready = function()
        local T = ns.Threat
        return not (T and T.IsEnabled) or T:IsEnabled(), "Switch the threat meter on first: Settings > Combat > Meters."
    end })
Demo:RegisterPart({ key = "sct", group = "combat", order = 12, label = "Combat text", icon = 8, word = "text", pull = true,
    desc = "A 12-second pull in your combat text look." })
Demo:RegisterPart({ key = "bossmods", group = "combat", order = 13, label = "Boss mods", icon = 37, pull = true,
    desc = "A Gruul pull: countdown, timer bars, warnings with sound, range frame." })
Demo:RegisterPart({ key = "plates", group = "combat", order = 14, label = "Nameplates", icon = 61, pull = true,
    desc = "The Maulgar council in your plate look, two of them casting." })
-- frames and bars
Demo:RegisterPart({ key = "party", group = "frames", order = 20, label = "Party frames", icon = 46,
    desc = "A made-up party next to you while you aren't grouped, their threat drifting.",
    ready = function()
        local L = Look()
        return not (L and L.IsOn) or L:IsOn("group"), "Give party frames a look first: Interface > Looks > Party."
    end })
Demo:RegisterPart({ key = "tanks", group = "frames", order = 21, label = "Main tanks", icon = 62,
    desc = "Made-up main tank rows and what they are holding.",
    ready = function()
        local LT = ns.LookTanks
        return not (LT and LT.On) or LT.On(), "Switch tank rows on first: Interface > Looks > Party."
    end })
Demo:RegisterPart({ key = "outfits", group = "frames", order = 22, label = "Outfit bar", icon = 40,
    desc = "The quick-swap bar with four made-up Retribution outfits." })
-- class tools (their kits: the icon and the class)
local function ClassPart(key, kit, class, order, label, desc, pull, word)
    Demo:RegisterPart({ key = key, kit = kit, class = class, group = "class", order = order, label = label, desc = desc,
        pull = pull, word = word })
end
ClassPart("swing", "swing", "PALADIN", 30, "Seal twist timer", "A swing every 3.5 s with Seal of Command and the twist window.", true)
ClassPart("bless", "bless", "PALADIN", 31, "Blessings", "A made-up Black Temple raid in the planner and on your blessings bar.", false, "blessings")
ClassPart("totems", "totems", "SHAMAN", 32, "Totems", "A made-up raid in the planner; the bar's totems tick and Windfury counts down.")
ClassPart("shot", "shot", "HUNTER", 33, "Shot timer", "Auto Shot every 2.6 s, Steady Shot in between.", true)
ClassPart("war", "war", "WARRIOR", 34, "Swing timer", "A Fury bot: both hands, rage and a queued Heroic Strike.", true, "warrior")

-- Situations (Core/Situation.lua): a pack or a player played on your class's timer (a Warrior's for everyone else;
-- Ret has no pack, so a Paladin's pack pull shows the Warrior's too). One pull; nothing is cast.
local SIT_TIMER = { WARRIOR = "war", PALADIN = "swing", HUNTER = "shot" }
local function PlaySituation(sit, noRet)
    local _, cls = UnitClass("player")
    local key = SIT_TIMER[cls]
    if not key or (noRet and key == "swing") then
        key = "war"
        if cls ~= "WARRIOR" then Demo:SetClassPicked("WARRIOR", true) end
    end
    if not Demo:SetOn(key, true) and not Demo:IsOn(key) then return false, "the class timer could not start" end
    ns.Situation:SetDemo(sit)
    Demo:StartPull()
    return true
end
local function StopSituation() if ns.Situation then ns.Situation:SetDemo(nil) end end
Demo:RegisterPart({ key = "sitpack", word = "pack", kind = "moment", group = "class", order = 85, guild = false,
    label = "A pack pull", icon = 12328, dur = Demo.PULL,
    desc = "Four enemies in reach: your timer plays its pack presses (Warriors: Sweeping Strikes, Whirlwind, Cleave).",
    play = function() return PlaySituation({ kind = "pack", n = 4 }, true) end, stop = StopSituation })
Demo:RegisterPart({ key = "sitduel", word = "duel", kind = "moment", group = "class", order = 86, guild = false,
    label = "A duel", icon = "Interface\\Icons\\Achievement_Arena_2v2_7", dur = Demo.PULL,
    desc = "Your target is a Rogue: your timer plays its presses against a player.",
    play = function()
        local who = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE.ROGUE or "Rogue"
        return PlaySituation({ kind = "player", cls = "ROGUE", who = who })
    end, stop = StopSituation })
-- guild
Demo:RegisterPart({ key = "tracker", group = "guild", order = 40, label = "Event tracker", icon = 50, guild = true,
    desc = "The demo guild's duel cup in progress, its goals ticking up." })
Demo:RegisterPart({ key = "mapdots", group = "guild", order = 41, label = "World map dots", icon = 7, guild = true, word = "map",
    desc = "Guild members on your world map, some of them walking.",
    ready = function()
        local G = ns.GuildMap
        return not (G and G.GetShowOnWorldMap) or G:GetShowOnWorldMap(), "Switch on Dots on the world map first: Guild > Map."
    end })

-- moments
Demo:RegisterPart({ key = "roll", kind = "moment", group = "loot", order = 60, label = "A prized drop", icon = 60, dur = 25,
    desc = "A prized item drops; the demo raid rolls and the council votes.",
    play = function() if ns.SettingsUI and ns.SettingsUI.DemoRoll then ns.SettingsUI:DemoRoll() end return true end,
    stop = EndDemoRoll })
Demo:RegisterPart({ key = "drop", kind = "moment", group = "loot", order = 61, label = "Boss drop panel", icon = 40, dur = 15,
    desc = "A made-up boss drop opens the drop panel: click Roll to watch one.",
    play = function() if ns.Loot and ns.Loot.SimulateDrop then ns.Loot:SimulateDrop() end return true end })
for i, def in ipairs(Demo.SCENARIOS or {}) do
    Demo:RegisterPart({ key = "scn_" .. def.key, word = def.key, kind = "moment", group = "rules", order = 70 + i,
        label = def.label, desc = def.desc, icon = 64, item = def.item, dur = 25,
        play = function() return Demo:RunScenario(def.key) end,
        stop = function() EndDemoRoll(); if Demo.ClearScenario then Demo:ClearScenario() end end })
end
Demo:RegisterPart({ key = "reserves", kind = "moment", group = "raid", order = 80, label = "Loot reserves: a pug night",
    icon = 7, desc = "Step through Serpentshrine as the raid leader, a raider or a pug with chat only.",
    play = function() if ns.ReserveDemo then ns.ReserveDemo:Start() end return true end,
    stop = function() if ns.ReserveDemo and ns.ReserveDemo:IsRunning() then ns.ReserveDemo:Stop() end end,
    running = function() return ns.ReserveDemo and ns.ReserveDemo:IsRunning() or false end })
local CREST = { "idle", "between", "pull", "loot", "done" }
Demo:RegisterPart({ key = "crest", kind = "moment", group = "raid", order = 81, label = "A raid night on the crest",
    icon = 26, dur = 5 * #CREST,
    desc = "The raid session crest through a made-up night: idle, between pulls, a pull, loot, done.",
    play = function()
        local SB = ns.SessionBar
        if not (SB and SB.Demo) then return false, "the crest is not loaded" end
        local _, m = Demo:GetMoment()
        local token = m and m.token
        for i, step in ipairs(CREST) do
            After((i - 1) * 5, function()
                local _, cur = Demo:GetMoment()
                if cur and cur.token == token then SB:Demo(step) end
            end)
        end
        return true
    end,
    stop = function() if ns.SessionBar and ns.SessionBar.Demo then ns.SessionBar:Demo("off") end end })
Demo:RegisterPart({ key = "attendance", kind = "moment", group = "raid", order = 82, label = "Attendance prompts",
    icon = 61, dur = 15, desc = "Someone left the raid early: the two pop-ups that ask about it.",
    play = function() if ns.AttendanceUI and ns.AttendanceUI.ShowDemo then ns.AttendanceUI:ShowDemo() end return true end })
Demo:RegisterPart({ key = "start", kind = "moment", group = "raid", order = 83, label = "Start raid window", icon = 47,
    dur = 15, desc = "What the raid leader sees before the first pull.",
    play = function() if ns.SessionBar and ns.SessionBar.OpenOptions then ns.SessionBar:OpenOptions() end return true end })
Demo:RegisterPart({ key = "peek", kind = "moment", group = "tour", order = 90, label = "What the others see", icon = 15,
    dur = 20, desc = "A short tour of the pages officers, raid leaders and raiders use, on demo data.",
    play = function(owner)
        local SU, W = ns.SettingsUI, ns.WelcomeTour
        if owner and SU and SU.OpenTourPeekMenu then SU:OpenTourPeekMenu(owner) return true end
        if not W then return false, "the tours are not loaded" end
        local mine = W:Roles()
        for _, key in ipairs(W.ORDER) do
            if not mine[key] then W:StartPart(key, true) return true end
        end
        return false, "you already have every role"
    end })

---------------------------------------------------------------------------
-- /dz demo
---------------------------------------------------------------------------

function Demo:OpenPage()
    if ns.MainFrame then ns.MainFrame:Open("settings") end
    local SU = ns.SettingsUI
    if SU and SU.SelectSection then SU:SelectSection("demo") end
end

local function PrintList()
    ns:Print("Demo (/dz demo <word>): on | off | stop | guild | mine | list")
    local function line(kind, title)
        local words = {}
        for _, d in ipairs(Demo:Parts(kind)) do words[#words + 1] = d.word end
        ns:Print("  |cffffd100%s|r %s", title, table.concat(words, ", "))
    end
    line("screen", "On screen:")
    line("moment", "Moments:")
end

-- arg: the words after /dz demo. Returns true when it was a demo word.
function Demo:Slash(arg)
    arg = type(arg) == "string" and arg:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
    if arg == "" then self:OpenPage() return true end
    if arg == "on" or arg == "1" then
        if not self:Everything() then return true end
        local raidCount = #self:GetRaidKeys() - 1
        ns:Print("demo mode on: %d fake guild members with BiS lists, %d of them in your demo raid, and every part on "
            .. "screen. /dz demo opens the Demo page to pick, /dz demo off stops it.", #self:GetMembers(), max(0, raidCount))
        return true
    end
    if arg == "off" or arg == "0" or arg == "stop" then
        self:StopAll(true)
        ns:Print("demo mode off.")
        return true
    end
    if arg == "list" or arg == "scenarios" then PrintList() return true end
    if arg == "guild" or arg == "pages" then
        self:SetEnabled(not self:IsEnabled())
        ns:Print("Demo guild %s.", self:IsEnabled() and "|cff33ff33on|r" or "|cffff3333off|r")
        return true
    end
    if arg == "mine" or arg == "picks" then
        if not self:PlayPicks() then ns:Print("No picks yet: /dz demo opens the Demo page.") end
        return true
    end
    local d = self:ByWord(arg)
    if not d then
        ns:Print("No demo called \"%s\". /dz demo list shows them all.", arg)
        return true
    end
    if d.kind == "moment" then
        local ok, why = self:Play(d.key)
        if not ok then ns:Print("Demo not started: %s", tostring(why)) end
        return true
    end
    local ready, why = self:Ready(d.key)
    local now = self:TogglePart(d.key)
    ns:Print("Demo: %s %s.", d.label, now and "|cff33ff33on|r" or "|cffff3333off|r")
    if now and not ready and why then ns:Print("%s", why) end
    return true
end

ns:RegisterSlash("demo", function(rest) Demo:Slash(rest) end,
    "the Demo page: try parts of the addon with made-up data (on, off, list, a part's word)")

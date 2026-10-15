if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Share.lua", ...) then return end -- DisasterZone: UI/Share.lua
-- ns.Share: links to places in DisasterZone that travel through chat (a raid, a member, a strategy, a game, a page).
--
-- A link goes out as plain text, its label then its reference:
--     [DisasterZone: Black Temple · Thu 9 Oct 20:00 #raid:19a2b3c4d5e6]
-- The server keeps custom hyperlinks out of chat, so players without the addon read just that. Every client with
-- DisasterZone rewrites the text in its chat frames (a message event filter) into a link of the client's own "addon"
-- type: an icon and the label in DisasterZone orange, the label drawn from its own data when it has the place (a raid
-- in the reader's local time, a member in their class colour), else the text as sent. SetItemRef hands "addon" links to
-- EventRegistry "SetItemRef": a click opens the place, shift-click puts the link back into the chat box, right-click
-- shares it on; hovering shows what it is (EventRegistry "ChatFrame.OnHyperlinkEnter").
--
-- References: a page (home, mybis, council, loot, raids, teams, strategies, raidlog, dungeons, events, season,
-- members, recipes, map, polls, atlas, mylog, feedback, notify, games, changelog, settings), raid:<occ>[:groups |
-- :assign], team:<id>, strat:<id>, board:<occ>:<boss>, member:<name>, recipe:<spell>, game:<id>, ver:<version>,
-- run:<id> (a dungeon run, Core/DungeonRuns.lua), event:<occ> (a calendar event or its results), edef:<id> (an event of
-- the library), fb:<id> (a feedback item, Core/Feedback.lua).
-- UI/ShareWindow.lua is the window that sends one.
local addonName, ns = ...

local Share = ns:NewModule("Share")

local tconcat = table.concat
local floor = math.floor

local LINK_PREFIX = "addon:DisasterZone:"
local ORANGE = "ffff8000"
local MAX_LABEL = 70
local MAX_CHAT = 255
-- [DisasterZone: <label> #<ref>]: the label has no brackets or bars, the reference no spaces either
local TOKEN = "%[DisasterZone: ([^%[%]|]-) #([^%s%[%]|]+)%]"

local ICON = {
    addon   = ns:HasAssets(4) and "Interface\\AddOns\\DisasterZone\\Media\\Launcher\\seal"
        or "Interface\\Icons\\INV_Misc_Bag_10_Blue",
    raid    = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
    team    = "Interface\\Icons\\INV_Shirt_GuildTabard_01",
    board   = "Interface\\Icons\\INV_Misc_Map_01",
    layout  = "Interface\\Icons\\INV_Misc_Spyglass_03",
    games   = "Interface\\Icons\\INV_Misc_Dice_01",
    events  = "Interface\\Icons\\Ability_DualWield",
    version = "Interface\\Icons\\INV_Misc_Note_01",
    feedback = "Interface\\Icons\\INV_Letter_15",
}

-- The pages: their label, the tab (and the Raids / Members / Council view) they open, a line for the tooltip.
local PAGES = {
    home       = { label = "Home", tab = "home", desc = "Your raids, BiS progress and what's new." },
    mybis      = { label = "My BiS", tab = "mybis", desc = "Your best in slot lists." },
    gearsim    = { label = "Gear sim", tab = "gearsim", desc = "Simulated fights to compare gear before you have it." },
    consumables = { label = "Consumables", tab = "consumables", desc = "The flask, food and potions for each spec." },
    council    = { label = "Council", tab = "council", desc = "The loot council's view.",
                   closed = "The Council tab is for the loot council." },
    loot       = { label = "Council: Loot Log", tab = "council", councilView = "log", desc = "Every item handed out.",
                   closed = "The Loot Log is for the loot council." },
    raids      = { label = "Raids", tab = "raids", view = "upcoming", desc = "Planned raids and sign-ups." },
    teams      = { label = "Raids: Teams", tab = "raids", view = "teams", desc = "The raid teams." },
    strategies = { label = "Raids: Strategies", tab = "raids", view = "strategies",
                   desc = "The strategy boards for every boss." },
    raidlog    = { label = "Raids: Raid log", tab = "raids", view = "log", desc = "The raids we ran and who came.",
                   closed = "The Raid log is for the Guild Master, the guild council and the raid leaders." },
    dungeons   = { label = "Groups", tab = "dungeons", desc = "The guild's groups: dungeons, raids, quests and PvP." },
    events     = { label = "Events", tab = "events", icon = ICON.events,
                   desc = "The guild's own events: duel cups, races, contests. Sign up or build one." },
    season     = { label = "Events: Season", tab = "events", eventsView = "season", icon = ICON.events,
                   desc = "The season's standings, badges and titles." },
    members    = { label = "Members", tab = "members", mode = "roster", desc = "The guild: characters, specs, gear." },
    recipes    = { label = "Members: Recipes", tab = "members", mode = "recipes",
                   desc = "Who in the guild can make what." },
    games      = { label = "Games", tab = "games", icon = ICON.games, desc = "Bingo and the other games." },
    map        = { label = "Guild map", tab = "map", desc = "Where the guild is right now.",
                   closed = "The guild map is for guild members." },
    polls      = { label = "Polls", tab = "polls", desc = "The guild's polls: answer them or see the results." },
    atlas      = { label = "Atlas", tab = "atlas", desc = "Every raid and dungeon's loot, with what it costs." },
    mylog      = { label = "My Log", tab = "mylog", desc = "Your own raid log: every pull and your numbers." },
    feedback   = { label = "Feedback", tab = "feedback", icon = ICON.feedback,
                   desc = "Bugs, ideas and changes the guild sent the developer." },
    notify     = { label = "Notifications", tab = "notify", desc = "Everything DisasterZone told you lately." },
    changelog  = { label = "What's new", tab = "changelog", icon = ICON.version,
                   desc = "The changes of every DisasterZone release." },
    settings   = { label = "Settings", tab = "settings", desc = "DisasterZone's settings." },
}
Share.PAGES = PAGES

local DETAIL_TABS = { groups = "Groups", assign = "Assignments" }

local function RP() return ns.RaidPlan end
local function Strat() return ns.Strategy end
local function G() return ns.Guild end
local function P() return ns.Professions end
local function Util() return ns.Util end

local S = ns.Style

-- A tooltip line in a ns.Style colour.
local function Line(tt, text, color, wrap)
    local r, g, b = S:Color(color)
    tt:AddLine(text, r, g, b, wrap)
end

-- The first n bytes of s, without a UTF-8 character cut in half at the end.
local function CutUTF8(s, n)
    if #s <= n then return s end
    s = s:sub(1, math.max(0, n))
    local lead = s:match("()[\192-\255][\128-\191]*$")
    if lead then
        local b = s:byte(lead)
        local size = (b >= 240 and 4) or (b >= 224 and 3) or 2
        if #s - lead + 1 < size then s = s:sub(1, lead - 1) end
    end
    return s
end

-- Label text that can travel in a token: no colour codes, bars or brackets, one line, not too long.
local function Clean(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|H.-|h(.-)|h", "%1")
    text = text:gsub("[|%[%]\r\n]", ""):gsub("%s+", " ")
    text = Util().Trim(text) or ""
    if #text > MAX_LABEL then text = (Util().Trim(CutUTF8(text, MAX_LABEL - 3)) or "") .. "..." end
    return text ~= "" and text or nil
end

-- "Thu 9 Oct 20:00" in this client's local time.
local function When(t)
    return ("%s %d %s %s"):format(date("%a", t), tonumber((date("%d", t))), date("%b", t), date("%H:%M", t))
end

local function TexIcon(path)
    return path and ("|T%s:0:0:0:0:64:64:5:59:5:59|t"):format(path) or ""
end

local function ClassTexIcon(classFile)
    local c = classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
    if not c then return TexIcon(ICON.addon) end
    return ("|TInterface\\TargetingFrame\\UI-Classes-Circles:0:0:0:0:256:256:%d:%d:%d:%d|t"):format(
        floor(c[1] * 256 + 0.5), floor(c[2] * 256 + 0.5), floor(c[3] * 256 + 0.5), floor(c[4] * 256 + 0.5))
end

local function ClassHex(classFile)
    local hex = classFile and Util().ClassColorHex and Util().ClassColorHex(classFile)
    if type(hex) == "string" and #hex == 8 then return hex end
    return "ffffffff"
end

---------------------------------------------------------------------------
-- References
---------------------------------------------------------------------------

-- "raid:abc#2:groups" -> "raid", "abc#2:groups"; "raids" -> "raids", nil.
local function SplitRef(ref)
    if type(ref) ~= "string" then return nil end
    local kind, arg = ref:match("^(%a+):(.+)$")
    if kind then return kind, arg end
    if ref:match("^%a+$") then return ref, nil end
    return nil
end

-- "abc#2:groups" -> "abc#2", "groups" (an occurrence id never holds a colon).
local function SplitRaid(arg)
    local occ, tab = arg:match("^([^:]+):(%a+)$")
    if occ and DETAIL_TABS[tab] then return occ, tab end
    return arg, nil
end

local function MemberKey(arg)
    local key = Util().NormalizeName(arg)
    if not key then return nil end
    -- a character's name the way the guild roster spells it (typed links can differ in case)
    local g = G()
    if g and g.GetMember and not g:GetMember(key) and g.GetMembers then
        local fold = Util().FoldCase(key)
        for _, k in ipairs(g:GetMembers()) do
            if Util().FoldCase(k) == fold then return k end
        end
    end
    return key
end

local function Recipe(arg)
    local spell = tonumber(arg)
    return spell and P() and P():GetRecipe(spell) or nil
end

local function ChangelogEntry(version)
    for _, e in ipairs(ns.CHANGELOG or {}) do
        if e.version == version then return e end
    end
    return nil
end

local function BossName(ref)
    return Strat() and Strat():GetBossName(ref) or tostring(ref)
end

---------------------------------------------------------------------------
-- What a reference is: Describe(ref) -> { kind, arg, label (plain), rich (coloured, nil = label), icon (texture
-- escape), known (the place exists here) } or nil for a reference this version doesn't know.
---------------------------------------------------------------------------

local KINDS = {}

KINDS.raid = function(arg)
    local occ, tab = SplitRaid(arg)
    local v = RP() and RP():GetRaid(occ)
    if not v then return { icon = TexIcon(ICON.raid) } end
    local label = RP():GetRaidName(v) .. " · " .. When(v.t) .. (tab and (" · " .. DETAIL_TABS[tab]) or "")
    return { label = label, icon = TexIcon(ICON.raid), known = true }
end

KINDS.team = function(arg)
    local t = RP() and RP():GetTeam(arg)
    if not t then return { icon = TexIcon(ICON.team) } end
    return { label = "Team: " .. t.name, icon = TexIcon(ICON.team), known = true }
end

KINDS.strat = function(arg)
    local s = Strat() and Strat():GetStrategy(arg)
    if not s then return { icon = TexIcon(ICON.board) } end
    return { label = BossName(s.b) .. ": " .. s.n, icon = TexIcon(ICON.board), known = true }
end

KINDS.board = function(arg)
    local occ, boss = arg:match("^([^:]+):(.+)$")
    local v = occ and RP() and RP():GetRaid(occ)
    if not v then return { icon = TexIcon(ICON.board) } end
    local day = ("%s %d %s"):format(date("%a", v.t), tonumber((date("%d", v.t))), date("%b", v.t))
    return { label = BossName(boss) .. " · " .. RP():GetRaidName(v) .. " " .. day, icon = TexIcon(ICON.board),
             known = true }
end

-- A layout profile (Core/Layout.lua): "layout:<owner>:<profile id>". Only its owner has it: a click asks them for it.
KINDS.layout = function(arg)
    local owner, pid = ns.Layout.ParseRef(arg)
    local p = owner and Util().IsMe(owner) and ns.Layout:Profile(pid)
    if not p then return { icon = TexIcon(ICON.layout) } end
    return { label = "Layout: " .. tostring(p.name), icon = TexIcon(ICON.layout), known = true }
end

KINDS.member = function(arg)
    local key = MemberKey(arg)
    local g = G()
    local m = key and g and g:GetMember(key)
    local name = Util().ShortName(key or arg)
    if not m then return { label = name, icon = TexIcon(ICON.addon) } end
    local classFile = g:GetClass(key)
    return { label = name, rich = "|c" .. ClassHex(classFile) .. name .. "|r", icon = ClassTexIcon(classFile),
             known = true }
end

KINDS.recipe = function(arg)
    local r = Recipe(arg)
    if not r or not r.name then return { icon = TexIcon(ICON.addon) } end
    local icon = P().GetRecipeIcon and P():GetRecipeIcon(r)
    return { label = "Crafters: " .. r.name, icon = TexIcon(icon or ICON.addon), known = true }
end

KINDS.game = function(arg)
    local def = ns.Games and ns.Games:Get(arg)
    if not def then return { icon = TexIcon(ICON.games) } end
    return { label = def.name, icon = TexIcon(def.icon or ICON.games), known = true }
end

local function Runs() return ns.DungeonRuns end

-- "The Shattered Halls (Heroic)", "now" / "Thu 9 Oct 20:00", the complex's icon.
local function RunParts(run)
    local d = Runs():GetDungeon(run.d)
    local name = (d and d.name or tostring(run.d)) .. (run.h and " (Heroic)" or "")
    local when = (run.at or 0) > GetServerTime() and When(run.at) or "now"
    return name, when, d and d.complex and d.complex.icon
end

KINDS.run = function(arg)
    local run = Runs() and Runs():GetRun(arg)
    if not run then return { icon = TexIcon(ICON.raid) } end
    local name, when, icon = RunParts(run)
    return { label = name .. " · " .. when, icon = TexIcon(icon or ICON.raid), known = true }
end

KINDS.ver = function(arg)
    local e = ChangelogEntry(arg)
    return { label = "What's new in " .. arg, icon = TexIcon(ICON.version), known = e ~= nil }
end

local function Ev() return ns.Events end

-- A calendar event: its occurrence, else its results (once the occurrence is gone). -> o, r
local function EventOf(occId)
    local E = Ev()
    if not E then return nil end
    return E:GetOcc(occId), E:GetResult(occId)
end

KINDS.event = function(arg)
    local o, r = EventOf(arg)
    local d = o and o.def
    if not d and not r then return { icon = TexIcon(ICON.events) } end
    local name = d and d.name or r.name
    local when = (o and o.at) or (r and r.at)
    local label = name .. (r and " · results" or (when and (" · " .. When(when)) or ""))
    return { label = label, icon = TexIcon((d and d.icon) or (r and r.icon) or ICON.events), known = true }
end

KINDS.edef = function(arg)
    local d = Ev() and Ev():GetDef(arg)
    if not d then return { icon = TexIcon(ICON.events) } end
    return { label = "Event: " .. (d.name or "?"), icon = TexIcon(d.icon or ICON.events), known = true }
end

local function FB() return ns.Feedback end

-- "Bug: the share icon can't be clicked", the kind's icon.
local function FeedbackParts(item)
    local info = FB().KIND_INFO and FB().KIND_INFO[item.kind] or {}
    return (info.short or "Feedback") .. ": " .. (item.text or ""), info.icon
end

KINDS.fb = function(arg)
    local item = FB() and FB():Get(arg)
    if not item then return { icon = TexIcon(ICON.feedback) } end
    local label, icon = FeedbackParts(item)
    return { label = label, icon = TexIcon(icon or ICON.feedback), known = true }
end

function Share:Describe(ref)
    local kind, arg = SplitRef(ref)
    if not kind then return nil end
    local d
    if arg == nil then
        local page = PAGES[kind]
        if not page then return nil end
        d = { label = page.label, icon = TexIcon(page.icon or ICON.addon), known = true }
    else
        local fn = KINDS[kind]
        if not fn then return nil end
        local ok, res = pcall(fn, arg)
        if not ok or type(res) ~= "table" then return nil end
        d = res
    end
    d.kind, d.arg, d.ref = kind, arg, ref
    return d
end

-- References to build links from code.
function Share:RaidRef(occ, detailTab)
    if type(occ) ~= "string" then return nil end
    return "raid:" .. occ .. (DETAIL_TABS[detailTab] and (":" .. detailTab) or "")
end
function Share:MemberRef(key) return type(key) == "string" and ("member:" .. Util().ShortName(key)) or nil end
function Share:StrategyRef(id) return type(id) == "string" and ("strat:" .. id) or nil end
function Share:BoardRef(occ, boss)
    return type(occ) == "string" and type(boss) == "string" and ("board:" .. occ .. ":" .. boss) or nil
end
function Share:GameRef(id) return type(id) == "string" and ("game:" .. id) or nil end
function Share:RecipeRef(spell) return tonumber(spell) and ("recipe:" .. tonumber(spell)) or nil end
function Share:TeamRef(id) return type(id) == "string" and ("team:" .. id) or nil end
function Share:RunRef(id) return type(id) == "string" and ("run:" .. id) or nil end
function Share:EventRef(occId) return type(occId) == "string" and ("event:" .. occId) or nil end
function Share:EventDefRef(id) return type(id) == "string" and ("edef:" .. id) or nil end
function Share:FeedbackRef(id) return type(id) == "string" and ("fb:" .. id) or nil end

---------------------------------------------------------------------------
-- Text: what goes out in chat; ChatLink: what a chat frame shows
---------------------------------------------------------------------------

-- The plain token for a reference (nil when it can't be shared). fallback: the label when this client doesn't know the
-- place (a link passed on).
function Share:Text(ref, fallback)
    local d = self:Describe(ref)
    if not d or ref:find("[%s%[%]|]") then return nil end
    local label = Clean(d.known and d.label or fallback or d.label) or Clean(d.label) or ref
    return "[DisasterZone: " .. label .. " #" .. ref .. "]"
end

-- The longest message that still fits in one chat line before the token (and a space).
function Share:MaxMessageBytes(ref)
    local token = self:Text(ref)
    return token and math.max(0, MAX_CHAT - #token - 1) or 0
end

-- The clickable link for a chat frame: icon, then [label] in orange, the label from my own data when I have the place.
function Share:ChatLink(ref, sentLabel)
    local d = self:Describe(ref)
    if not d then return nil end
    local label = d.known and (d.rich or d.label) or Clean(sentLabel) or Clean(d.label) or ref
    -- a colour inside the label ends with |r: the brackets after it are orange again
    label = label:gsub("|r", "|r|c" .. ORANGE)
    return ("%s |c%s|H%s%s|h[%s]|h|r"):format(d.icon or TexIcon(ICON.addon), ORANGE, LINK_PREFIX, ref, label)
end

-- Every [DisasterZone: ...] token of a message as a link (nil when there is none).
function Share:Rewrite(msg)
    if type(msg) ~= "string" or not msg:find("[DisasterZone: ", 1, true) then return nil end
    local n = 0
    msg = msg:gsub(TOKEN, function(label, ref)
        local link = Share:ChatLink(ref, label)
        if link then n = n + 1 end
        return link
    end)
    return n > 0 and msg or nil
end

-- The references in a message, in order (for tests and tools).
function Share:Parse(msg)
    local out = {}
    if type(msg) ~= "string" then return out end
    for label, ref in msg:gmatch(TOKEN) do out[#out + 1] = { label = label, ref = ref } end
    return out
end

---------------------------------------------------------------------------
-- Opening a place
---------------------------------------------------------------------------

local function OpenTab(key)
    local MF = ns.MainFrame
    if not MF then return false end
    MF:Open(key)
    return MF:GetSelectedTab() == key
end

local function OpenRaids(view)
    if not OpenTab("raids") then return false end
    ns.RaidsUI:SetView(view)
    return ns.RaidsUI:GetView() == view
end

local NOT_IN_GUILD = "The Raids tab is for guild members."

local OPEN = {}

OPEN.raid = function(arg)
    local occ, tab = SplitRaid(arg)
    if not OpenRaids("upcoming") then return false, NOT_IN_GUILD end
    if not RP():GetRaid(occ) then
        return false, "That raid isn't here: it hasn't reached you yet, or it was deleted."
    end
    ns.RaidPlanUI:SelectRaid(occ)
    ns.RaidPlanUI:SetDetailTab(tab or "signups")
    return true
end

OPEN.layout = function(arg)
    local owner, pid = ns.Layout.ParseRef(arg)
    if not owner then return false end
    if Util().IsMe(owner) then
        if not ns.Layout:Profile(pid) then return false, "That layout profile was deleted." end
        ns.Layout:Use(pid)
        if ns.EditMode then ns.EditMode:Open() end
        return true
    end
    if ns.Layout:Request(owner, pid) then
        ns:Print("Asking %s for the layout...", Util().ShortName(owner))
        return true
    end
    return false, "Only a guildmate or someone in your group can send you their layout, and they need to be online."
end

OPEN.team = function(arg)
    if not OpenRaids("teams") then return false, NOT_IN_GUILD end
    if not RP():GetTeam(arg) then return false, "That team isn't here: it hasn't reached you yet, or it was deleted." end
    ns.RaidPlanUI:SelectTeam(arg)
    return true
end

OPEN.strat = function(arg)
    if Strat() and Strat():GetStrategy(arg) and ns.StrategyBoard then
        ns.StrategyBoard:OpenStrategy(arg)
        return true
    end
    OpenRaids("strategies")
    return false, "That strategy isn't here: it hasn't reached you yet, or it was deleted."
end

OPEN.board = function(arg)
    local occ, boss = arg:match("^([^:]+):(.+)$")
    if occ and RP() and RP():GetRaid(occ) and ns.StrategyBoard then
        ns.StrategyBoard:OpenRaid(occ, boss)
        return true
    end
    OpenRaids("upcoming")
    return false, "That raid isn't here: it hasn't reached you yet, or it was deleted."
end

OPEN.member = function(arg)
    local key = MemberKey(arg)
    if not OpenTab("members") then return false end
    if not key or not G():GetMember(key) then return false, ("%s is not in the guild."):format(arg) end
    ns.MembersUI:ShowMember(key)
    return true
end

OPEN.recipe = function(arg)
    if not OpenTab("members") then return false end
    local r = Recipe(arg)
    if not r then
        ns.MembersUI:SetMode("recipes")
        return false, "Nobody in the guild has shared that recipe (yet)."
    end
    ns.MembersUI:ShowRecipe(r.spell or tonumber(arg))
    return true
end

OPEN.game = function(arg)
    if not OpenTab("games") then return false end
    if not (ns.Games and ns.Games:Get(arg)) then return false, "That game isn't in your DisasterZone version." end
    ns.GamesUI:Select(arg)
    return true
end

OPEN.run = function(arg)
    if not OpenTab("dungeons") then return false end
    if not (ns.DungeonsUI and ns.DungeonsUI:Focus(arg)) then
        return false, "That run is over, or it hasn't reached you yet."
    end
    return true
end

OPEN.event = function(arg)
    local UIx = ns.EventsUI
    if not UIx then return false end
    local o, r = EventOf(arg)
    if not (o or r) then
        UIx:Open("upcoming")
        return false, "That event isn't here: it hasn't reached you yet, or it was deleted."
    end
    return UIx:OpenEvent(arg)
end

OPEN.edef = function(arg)
    local d = Ev() and Ev():GetDef(arg)
    if not d then
        if ns.EventsUI then ns.EventsUI:Open("library") end
        return false, "That event isn't in the guild's library: it hasn't reached you yet, or it was deleted."
    end
    if not ns.EventBuilder then return false end
    ns.EventBuilder:Open(d)
    return ns.EventBuilder:IsShown()
end

OPEN.fb = function(arg)
    if not ns.FeedbackUI then return false end
    if not (FB() and FB():Get(arg)) then
        ns.FeedbackUI:Open("all")
        return false, "That feedback isn't here: it hasn't reached you yet, or it was withdrawn."
    end
    ns.FeedbackUI:Open("all", arg)
    return true
end

OPEN.ver = function(arg)
    if not ChangelogEntry(arg) then
        OpenTab("changelog")
        return false, ("Version %s isn't in your DisasterZone yet: update to read it."):format(arg)
    end
    ns.ChangelogUI:Open(arg)
    return true
end

-- Opens the place a reference points at. Returns ok, why (said in chat when it can't).
function Share:Open(ref)
    local kind, arg = SplitRef(ref)
    local ok, why
    if kind and arg == nil and PAGES[kind] then
        local page = PAGES[kind]
        ok = OpenTab(page.tab)
        if ok and page.view then ok = OpenRaids(page.view) end
        if ok and page.mode then ns.MembersUI:SetMode(page.mode) end
        if ok and page.eventsView then
            ns.EventsUI:SetView(page.eventsView)
            ok = ns.EventsUI:GetView() == page.eventsView
        end
        if ok and page.councilView then
            ns.CouncilUI:SetView(page.councilView)
            ok = ns.CouncilUI:GetView() == page.councilView
        end
        if not ok then why = page.closed or (page.view and NOT_IN_GUILD) or "That page isn't open to you." end
    elseif kind and OPEN[kind] then
        local fine, a, b = pcall(OPEN[kind], arg)
        if fine then ok, why = a, b else ok, why = false, nil; geterrorhandler()(a) end
    else
        why = "That link is from a newer DisasterZone: update to open it."
    end
    if not ok and why then ns:Print("%s", why) end
    return ok and true or false, why
end

---------------------------------------------------------------------------
-- What a link is (its tooltip)
---------------------------------------------------------------------------

local TIPS = {}

TIPS.layout = function(tt, arg)
    local _, pid = ns.Layout.ParseRef(arg)
    local p = ns.Layout:Profile(pid)
    local n = 0
    for _ in pairs(p.frames or {}) do n = n + 1 end
    Line(tt, tostring(p.name), "GOLD")
    Line(tt, ("Your layout profile: %d frames placed"):format(n), "TEXT")
    Line(tt, "Click to use it and open Edit layout", "SUB")
end

TIPS.raid = function(tt, arg)
    local occ, tab = SplitRaid(arg)
    local v = RP():GetRaid(occ)
    Line(tt, RP():GetRaidName(v) .. (v.sz and (" (" .. v.sz .. ")") or ""), "GOLD")
    tt:AddLine(date("%A %d %B · %H:%M", v.t), 1, 1, 1)
    if v.cancelled then Line(tt, "Cancelled", "BAD") end
    local counts = { A = 0, T = 0, B = 0 }
    for _, s in pairs(RP():GetSignups(occ)) do
        if counts[s.st] then counts[s.st] = counts[s.st] + 1 end
    end
    local parts = { ("%d/%d accepted"):format(counts.A, v.sz or 0) }
    if counts.T > 0 then parts[#parts + 1] = counts.T .. " tentative" end
    if counts.B > 0 then parts[#parts + 1] = counts.B .. " bench" end
    Line(tt, tconcat(parts, " · "), "TEXT")
    if v.rl then Line(tt, "Led by " .. Util().ShortName(v.rl), "TEXT") end
    local mine = RP():GetMySignup(occ)
    local STATUS = { A = "Accepted", T = "Tentative", B = "Bench", X = "Absent" }
    if mine and STATUS[mine.st] then
        Line(tt, "You: " .. STATUS[mine.st], "OK")
    elseif not v.cancelled and v.t > GetServerTime() then
        Line(tt, "You haven't answered yet", "WARN")
    end
    if v.no and v.no ~= "" then tt:AddLine(v.no, 1, 1, 1, true) end
    if tab then Line(tt, "Opens its " .. DETAIL_TABS[tab] .. " tab.", "SUB") end
end

TIPS.team = function(tt, arg)
    local t = RP():GetTeam(arg)
    Line(tt, t.name, "GOLD")
    Line(tt, ("Raid team · %d members"):format(#(t.members or {})), "TEXT")
end

TIPS.strat = function(tt, arg)
    local s = Strat():GetStrategy(arg)
    Line(tt, s.n, "GOLD")
    tt:AddLine(BossName(s.b) .. " · " .. (Strat():GetRaidName(s.b) or ""), 1, 1, 1)
    local owner = s.ow or s.by
    local pages = #(s.p or {})
    Line(tt, ("Strategy board by %s%s"):format(Util().ShortName(owner or "?"),
        pages > 1 and (" · " .. pages .. " pages") or ""), "TEXT")
end

TIPS.board = function(tt, arg)
    local occ, boss = arg:match("^([^:]+):(.+)$")
    local v = RP():GetRaid(occ)
    Line(tt, BossName(boss), "GOLD")
    tt:AddLine(RP():GetRaidName(v) .. " · " .. date("%A %d %B · %H:%M", v.t), 1, 1, 1)
    local s = Strat() and Strat().GetRaidStrategy and Strat():GetRaidStrategy(occ, boss)
    if s and s.n then Line(tt, "Strategy: " .. s.n, "TEXT") end
    Line(tt, "The raid's board for this boss: who does what.", "TEXT", true)
end

TIPS.member = function(tt, arg)
    local key = MemberKey(arg)
    local g = G()
    local m = g:GetMember(key)
    local classFile = g:GetClass(key)
    tt:AddLine("|c" .. ClassHex(classFile) .. Util().ShortName(key) .. "|r")
    local parts = {}
    if m.level then parts[#parts + 1] = "Level " .. m.level end
    local className = classFile and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile]
    if className then parts[#parts + 1] = className end
    if m.rankName then parts[#parts + 1] = m.rankName end
    if #parts > 0 then tt:AddLine(tconcat(parts, " · "), 1, 1, 1) end
    if g:IsOnline(key) then Line(tt, "Online", "OK") else Line(tt, "Offline", "DIM") end
    local profs = {}
    for _, e in ipairs(P() and P():GetMember(key) or {}) do
        profs[#profs + 1] = ("%s %d"):format(P():GetName(e.id) or "?", e.rank or 0)
    end
    if #profs > 0 then Line(tt, tconcat(profs, " · "), "TEXT", true) end
end

TIPS.recipe = function(tt, arg)
    local r = Recipe(arg)
    Line(tt, r.name, "GOLD")
    local n, online = 0, 0
    for _, key in ipairs(r.crafters or {}) do
        n = n + 1
        if G():IsOnline(key) then online = online + 1 end
    end
    Line(tt, ("%s · %d in the guild can make it, %d online"):format(P():GetName(r.prof) or "", n, online),
        "TEXT", true)
end

TIPS.game = function(tt, arg)
    local def = ns.Games:Get(arg)
    Line(tt, def.name, "GOLD")
    if def.desc and def.desc ~= "" then tt:AddLine(def.desc, 1, 1, 1, true) end
end

TIPS.run = function(tt, arg)
    local R = Runs()
    local run = R:GetRun(arg)
    local name, when = RunParts(run)
    Line(tt, name, "GOLD")
    tt:AddLine("Dungeon run led by " .. Util().ShortName(run.o) .. " · " .. when, 1, 1, 1)
    local open, parts = R:GetOpenRoles(run), {}
    for _, role in ipairs(R.ROLES) do
        local n = open[role]
        if n then parts[#parts + 1] = (n > 1 and (n .. " ") or "") .. R.ROLE_LABEL[role] end
    end
    if #parts > 0 then
        Line(tt, "Looking for " .. tconcat(parts, ", "), "TEXT")
    else
        Line(tt, "The party is full", "TEXT")
    end
    if R:IsInRun(run) then Line(tt, "You're in", "OK") end
    if run.no then tt:AddLine(run.no, 1, 1, 1, true) end
end

TIPS.event = function(tt, arg)
    local o, r = EventOf(arg)
    local E = Ev()
    local d = o and o.def
    Line(tt, (d and d.name) or r.name, "GOLD")
    if (o and o.ranked) or (r and r.ranked) then Line(tt, "Ranked: counts for the season", "GOLD") end
    if o then
        tt:AddLine(date("%A %d %B · %H:%M", o.at) .. (o.where and o.where ~= "" and (" · " .. o.where) or ""), 1, 1, 1)
        Line(tt, "Hosted by " .. Util().ShortName(E:HostOf(o) or "?"), "TEXT")
    end
    local st = o and E:OccState(o)
    if r and not r.cancel then
        if r.champ then Line(tt, "Won by " .. Util().ShortName(r.champ), "OK") end
        Line(tt, ("%d entrants"):format(r.n or 0), "TEXT")
    elseif st == "live" then
        Line(tt, "Live now", "OK")
    elseif st == "cancelled" or (r and r.cancel) then
        Line(tt, "Cancelled", "BAD")
    elseif o then
        local n = #E:GetSignups(o.id)
        Line(tt, ("%d signed up"):format(n), "TEXT")
        if E:IsSignedUp(o.id) then Line(tt, "You're signed up", "OK") end
    end
    if o and o.note and o.note ~= "" then tt:AddLine(o.note, 1, 1, 1, true) end
end

TIPS.edef = function(tt, arg)
    local E = Ev()
    local d = E:GetDef(arg)
    Line(tt, d.name, "GOLD")
    local runs = E:RunCount(d.id)
    local parts = { "Built by " .. Util().ShortName(d.by or "?") }
    if E:IsRanked(d) then parts[#parts + 1] = "ranked" end
    if (runs or 0) > 0 then parts[#parts + 1] = runs == 1 and "run once" or ("run " .. runs .. " times") end
    Line(tt, tconcat(parts, " · "), "TEXT")
    tt:AddLine("Opens it in the event builder: see its pieces, practise it, host it.", 1, 1, 1, true)
end

TIPS.fb = function(tt, arg)
    local F = FB()
    local item = F:Get(arg)
    local info = F.KIND_INFO[item.kind] or {}
    local c = info.color or S.C.GOLD
    tt:AddLine(info.label or "Feedback", c[1], c[2], c[3])
    tt:AddLine(item.text or "", 1, 1, 1, true)
    local parts = {}
    if not item.anon and item.author then parts[#parts + 1] = "From " .. Util().ShortName(item.author) end
    if (item.voteCount or 0) > 0 then parts[#parts + 1] = item.voteCount .. " me too" end
    if #parts > 0 then Line(tt, tconcat(parts, " · "), "TEXT") end
    local shipped = F:ShippedText(item)
    if shipped then
        Line(tt, shipped, "OK")
    elseif item.state == "planned" then
        Line(tt, "Planned", "GOLD")
    elseif item.closed then
        Line(tt, "Closed", "SUB")
    end
end

TIPS.ver = function(tt, arg)
    local e = ChangelogEntry(arg)
    Line(tt, "DisasterZone " .. arg, "GOLD")
    if e.title then tt:AddLine(e.title, 1, 1, 1, true) end
    if e.date then Line(tt, e.date, "SUB") end
end

-- Fills a tooltip for a reference: what the place is, then what a click does. sentLabel: the link's own text, for a
-- place this client doesn't have.
function Share:FillTooltip(tt, ref, sentLabel)
    local d = self:Describe(ref)
    if not d then
        Line(tt, Clean(sentLabel) or "DisasterZone link", "GOLD")
        tt:AddLine("This link is from a newer DisasterZone: update to open it.", 1, 1, 1, true)
        return
    end
    if not d.known then
        Line(tt, Clean(sentLabel) or d.label or "DisasterZone link", "GOLD")
        Line(tt, "Not here: it hasn't reached you yet, or it was deleted.", "WARN", true)
        return
    end
    local page = d.arg == nil and PAGES[d.kind]
    local ok
    if page then
        Line(tt, "DisasterZone: " .. page.label, "GOLD")
        tt:AddLine(page.desc, 1, 1, 1, true)
        ok = true
    elseif TIPS[d.kind] then
        ok = pcall(TIPS[d.kind], tt, d.arg)
    end
    if not ok then Line(tt, d.label or ref, "GOLD") end
    tt:AddLine(" ")
    tt:AddLine(S:Wrap("OK", "Click to open in DisasterZone"))
    tt:AddLine(S:Wrap("DIM", "Shift-click: into your chat box · Right-click: share"))
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

-- Puts the link into the chat box (opens it when none is open), like shift-clicking an item.
function Share:PutInChat(ref, fallback)
    local token = self:Text(ref, fallback)
    if not token then return false end
    local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
    if insert and insert(token) then return true end
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if open then
        open(token)
        return true
    end
    return false
end

-- Sends the link (after an optional message) to a chat: "GUILD" | "OFFICER" | "RAID" | "PARTY" | "SAY" | "WHISPER"
-- (target: the player). Must run from a click or key press: Say only goes out from one.
function Share:Send(ref, chatType, target, message)
    local token = self:Text(ref)
    if not token then return false end
    message = Util().Trim(((message or ""):gsub("[|\r\n]", " "))) or ""
    -- one chat line: a long message is cut short
    message = Util().Trim(CutUTF8(message, MAX_CHAT - #token - 1)) or ""
    local text = message ~= "" and (message .. " " .. token) or token
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if not send then return false end
    if chatType == "WHISPER" then
        if type(target) ~= "string" or target == "" then return false end
        send(text, "WHISPER", nil, Util().ShortName(target))
    else
        send(text, chatType)
    end
    return true
end

---------------------------------------------------------------------------
-- What the main window shows now (the Share icon of the navigation strip)
---------------------------------------------------------------------------

function Share:CurrentRef()
    local MF = ns.MainFrame
    local tab = MF and MF:GetSelectedTab()
    if not tab then return nil end
    if tab == "raids" and ns.RaidsUI then
        local view = ns.RaidsUI:GetView()
        if view == "upcoming" then
            -- a raid's page: that raid; the board: the page
            local onPage = ns.RaidPlanUI and (not ns.RaidPlanUI.GetPage or ns.RaidPlanUI:GetPage() == "raid")
            local occ = onPage and ns.RaidPlanUI:GetSelectedRaid()
            if occ and RP():GetRaid(occ) then return self:RaidRef(occ, ns.RaidPlanUI:GetDetailTab()) end
            return "raids"
        elseif view == "teams" then
            local id = ns.RaidPlanUI and ns.RaidPlanUI.GetSelectedTeam and ns.RaidPlanUI:GetSelectedTeam()
            if id and RP():GetTeam(id) then return self:TeamRef(id) end
            return "teams"
        elseif view == "log" then
            return "raidlog"
        end
        return "strategies"
    elseif tab == "members" and ns.MembersUI then
        local st = ns.MembersUI:GetState() or {}
        if st.mode == "recipes" then
            return (st.recipe and Recipe(st.recipe)) and self:RecipeRef(st.recipe) or "recipes"
        end
        return (st.member and G():GetMember(st.member)) and self:MemberRef(st.member) or "members"
    elseif tab == "games" and ns.GamesUI then
        local id = ns.GamesUI.GetSelected and ns.GamesUI:GetSelected()
        return id and self:GameRef(id) or "games"
    elseif tab == "changelog" and ns.ChangelogUI then
        local v = ns.ChangelogUI:GetSelected()
        return (v and ChangelogEntry(v)) and ("ver:" .. v) or "changelog"
    elseif tab == "dungeons" and ns.DungeonRuns then
        local mine = ns.DungeonRuns:GetMine()
        return mine and self:RunRef(mine.id) or "dungeons"
    elseif tab == "council" and ns.CouncilUI then
        return ns.CouncilUI:GetView() == "log" and "loot" or "council"
    elseif tab == "events" and ns.EventsUI then
        local view = ns.EventsUI:GetView()
        local st = ns.EventsUI.GetState and ns.EventsUI:GetState() or {}
        if view == "event" and st.occ then
            local o, r = EventOf(st.occ)
            if o or r then return self:EventRef(st.occ) end
        end
        return view == "season" and "season" or "events"
    elseif tab == "feedback" and ns.FeedbackUI then
        local sel = (ns.FeedbackUI:GetState() or {}).sel
        return (sel and FB() and FB():Get(sel)) and self:FeedbackRef(sel) or "feedback"
    end
    return PAGES[tab] and tab or nil
end

---------------------------------------------------------------------------
-- Share buttons
---------------------------------------------------------------------------

local SHARE_ICON = 18

local function OnShareClick(self)
    local ref = self.getRef and self.getRef(self)
    if not ref or not Share:Describe(ref) then return end
    if IsShiftKeyDown() then
        Share:PutInChat(ref)
        return
    end
    if ns.ShareWindow then ns.ShareWindow:Open(ref, self) end
end

-- The share icon's tooltip (UI:AttachTooltip's title function): what a click posts.
local function ShareTip(self, tt)
    local ref = self.getRef and self.getRef(self)
    local d = ref and Share:Describe(ref)
    Line(tt, self.tipTitle or "Share", "GOLD")
    tt:AddLine("Post a link in chat that opens " .. (d and d.label and ("|c" .. ORANGE .. d.label .. "|r")
        or "this") .. " in DisasterZone.", 1, 1, 1, true)
    tt:AddLine(S:Wrap("DIM", "Shift-click: into your chat box"))
end

-- A share icon button (the flat icon look). getRef(button) -> the reference to share (nil: nothing to share).
function Share:CreateButton(parent, size, getRef, tipTitle)
    local UI = ns.UI
    local b = UI:CreateIconButton(parent, size or 22, UI.ICON_ATLAS, UI:IconCoords(SHARE_ICON), OnShareClick)
    b.getRef, b.tipTitle = getRef, tipTitle
    UI:AttachTooltip(b, ShareTip, nil, { anchor = "ANCHOR_TOP" })
    return b
end

-- A banner tool for sharing (Banner:SetTools' entry): the share icon, its tooltip and the click (the share window;
-- Shift: straight into the chat box). getRef() -> the reference to share (nil: nothing to share); the tooltip names
-- what the reference opens now.
function Share:Tool(getRef, title)
    local ref = getRef and getRef()
    local d = ref and self:Describe(ref)
    return { icon = SHARE_ICON, title = title or "Share",
        text = "Post a link in chat that opens " .. (d and d.label and S:Wrap("WARN", d.label) or "this")
            .. " in DisasterZone.\n" .. S:Wrap("SUB", "Shift-click: into your chat box"),
        onClick = function(btn)
            local r = getRef and getRef()
            if not (r and Share:Describe(r)) then return end
            if IsShiftKeyDown() then
                Share:PutInChat(r)
            elseif ns.ShareWindow then
                ns.ShareWindow:Open(r, btn)
            end
        end }
end

-- The bare icon of the navigation strip (grey, white on hover, like the icon tabs beside it).
function Share:CreateNavButton(parent, getRef)
    local UI = ns.UI
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(28, 26)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(16, 16)
    b.icon:SetPoint("CENTER", 0, 1)
    b.icon:SetTexture(UI.ICON_ATLAS)
    b.icon:SetTexCoord(unpack(UI:IconCoords(SHARE_ICON)))
    b.icon:SetVertexColor(S:Color("SUB"))
    b.getRef, b.tipTitle = getRef, "Share this page"
    b:SetScript("OnEnter", function(self) self.icon:SetVertexColor(1, 1, 1) end)
    b:SetScript("OnLeave", function(self) self.icon:SetVertexColor(S:Color("SUB")) end)
    UI:AttachTooltip(b, ShareTip, nil, { anchor = "ANCHOR_BOTTOM" })
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", OnShareClick)
    return b
end

---------------------------------------------------------------------------
-- Chat: the message filter, clicks and hovers
---------------------------------------------------------------------------

local CHAT_EVENTS = {
    "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_CHANNEL",
}

local function Filter(_, event, msg, ...)
    -- the zone channels (General, Trade, ...): strangers' text, nothing of ours
    if event == "CHAT_MSG_CHANNEL" and (tonumber((select(6, ...))) or 0) > 0 then return false end
    local ok, out = pcall(Share.Rewrite, Share, msg)
    if ok and out then return false, out, ... end
    return false
end

-- [label] out of a link's text.
local function LinkLabel(text)
    local label = type(text) == "string" and text:match("|h%[(.-)%]|h") or nil
    return Clean(label)
end

local hovering

function Share:OnLogin()
    -- links only turn clickable on a client that hands "addon" links to the addons (2.5.5 does)
    local canClick = EventRegistry and LinkUtil and LinkUtil.IsLinkHandlerRegistered
        and LinkUtil.IsLinkHandlerRegistered("addon")
    if not canClick then return end
    local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if not addFilter then return end
    for _, event in ipairs(CHAT_EVENTS) do addFilter(event, Filter) end

    EventRegistry:RegisterCallback("SetItemRef", function(_, link, text, button)
        local ref = type(link) == "string" and link:match("^addon:DisasterZone:(.+)$")
        if not ref then return end
        if IsModifiedClick("CHATLINK") or IsShiftKeyDown() then
            Share:PutInChat(ref, LinkLabel(text))
        elseif button == "RightButton" then
            if ns.ShareWindow then ns.ShareWindow:Open(ref, nil, LinkLabel(text)) end
        else
            Share:Open(ref)
        end
    end, Share)
    EventRegistry:RegisterCallback("ChatFrame.OnHyperlinkEnter", function(_, chatFrame, link, text)
        local ref = type(link) == "string" and link:match("^addon:DisasterZone:(.+)$")
        if not ref then return end
        GameTooltip:SetOwner(chatFrame or UIParent, "ANCHOR_CURSOR")
        Share:FillTooltip(GameTooltip, ref, LinkLabel(text))
        GameTooltip:Show()
        hovering = true
    end, Share)
    EventRegistry:RegisterCallback("ChatFrame.OnHyperlinkLeave", function()
        if hovering then
            hovering = nil
            GameTooltip:Hide()
        end
    end, Share)
end

function Share:OnInit()
    ns:RegisterSlash("share", function()
        local ref = Share:CurrentRef() or "home"
        if ns.ShareWindow then ns.ShareWindow:Open(ref) end
    end, "share a link to the page you are on (a raid, a member, ...) in chat")
end

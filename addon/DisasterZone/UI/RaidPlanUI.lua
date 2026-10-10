if DisasterZoneBoot and DisasterZoneBoot.Run("UI/RaidPlanUI.lua", ...) then return end -- DisasterZone: UI/RaidPlanUI.lua
-- Raid planning views of the Raids tab (Addendum J §58): "Upcoming" (a board of raid cards with the raid's loading-screen
-- art and my answer on each; a raid's page: a banner with the facts and my answer, then Sign-ups as role columns,
-- Groups, Assignments) and "Teams" (team lists), plus the New / Edit raid window and the Add players window (invited
-- guild members and guests from outside the guild). The blacklist lives in the Guests window (UI/GuestBook.lua). RaidsTab
-- owns the tab and its toolbar and creates these views inside its panel.
local addonName, ns = ...

local PlanUI = ns:NewModule("RaidPlanUI")

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tsort, tconcat = table.sort, table.concat

local DAY = 86400

local STATUS_ORDER = { "A", "T", "B", "X" }
local STATUS = {
    A = { button = "Accept", label = "Accepted", color = "33ff33" },
    T = { button = "Tentative", label = "Tentative", color = "ffd100" },
    B = { button = "Bench", label = "Bench", color = "99bbff" },
    X = { button = "Absent", label = "Absent", color = "ff5555" },
}
-- filterRaid: an instance key or "all"; filterWhen: "all" | "today" | "week" | "next" | "later" | "past";
-- pendingChar: the character of mine picked to answer with, before the answer is sent
local state = { selected = nil, team = nil, draft = nil, pendingSpec = nil, pendingNote = nil, pendingChar = nil,
                detailTab = "signups", filterRaid = "all", filterWhen = "all" }
local upcoming, teamsView

local function RP() return ns.RaidPlan end
local function UI() return ns.UI end

local function Now() return GetServerTime() end

local function grey(text) return "|cff808080" .. tostring(text) .. "|r" end

local function colorize(hex, text) return "|cff" .. hex .. tostring(text) .. "|r" end

local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

local function classOf(key, s)
    if s and s.c then return s.c end
    local G = ns.Guild
    return G and G.GetClass and G:GetClass(key) or nil
end

local function colored(key, classFile)
    return UI():ColoredName(key, classFile or classOf(key))
end

local function nameLess(a, b) return shortName(a):lower() < shortName(b):lower() end

local function specOf(s)
    local specs = s and s.c and ns.SPECS[s.c]
    return specs and s.sp and specs[s.sp] or nil
end

-- tank / healer / melee / ranged (casters count as ranged), or nil when no spec was picked.
local function roleOf(s)
    local spec = specOf(s)
    if not spec then return nil end
    return spec.role == "caster" and "ranged" or spec.role
end

local function fmtDay(t) return date("%a %d %b", t) end
local function fmtTime(t) return date("%H:%M", t) end
-- "Sun 5 Oct"
local function shortDay(t) return ("%s %d %s"):format(date("%a", t), tonumber(date("%d", t)), date("%b", t)) end

local function raidTitle(v)
    return ("%s (%d)"):format(RP():GetRaidName(v), v.sz or 0)
end

local function hexRGB(hex)
    return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

-- Who the raid is for: its teams, how many players are invited on top, and whether it is locked to them
-- (plain: without the "Locked" mark). keep (a one-line place): name that many teams, then "and N more teams" (0:
-- "9 teams"); nil names them all.
local function teamNames(v, plain, keep)
    local names = {}
    for _, id in ipairs(v.tm or {}) do
        local t = RP():GetTeam(id)
        if t then
            -- (a team with more than one lineup of the raid's size: the one it uses)
            local l = RP():GetRaidLineup(v, id)
            local n = 0
            for _, o in ipairs(t.lineups) do if o.size == v.sz then n = n + 1 end end
            names[#names + 1] = t.name .. ((l and n > 1) and (" · " .. RP():LineupName(t, l)) or "")
        end
    end
    local extra = #(v.inv or {})
    local locked = RP():IsLocked(v)
    local text
    if keep and #names > keep and #names > 1 then
        local n = #names
        if keep < 1 then
            names = { n .. " teams" }
        else
            for i = n, keep + 1, -1 do names[i] = nil end
            names[keep] = names[keep] .. (" and %d more %s"):format(n - keep, n - keep == 1 and "team" or "teams")
        end
    end
    if #names > 0 then
        text = tconcat(names, ", ") .. (extra > 0 and (" +" .. extra .. " invited") or "")
    elseif locked then
        text = extra .. " invited"
    else
        text = "Everyone"
    end
    return (locked and not plain) and ("|cffff9933Locked|r: " .. text) or text
end

-- Monday 00:00 of the week of `t`.
local function weekStart(t)
    local d = date("*t", t)
    local sinceMonday = (d.wday + 5) % 7
    d.day, d.hour, d.min, d.sec, d.isdst = d.day - sinceMonday, 0, 0, 0, nil
    return time(d)
end

local function hideTooltip() GameTooltip:Hide() end

-- guests = how many of the accepted are guests
local function counts(occId)
    local c = { A = 0, T = 0, B = 0, X = 0, guests = 0 }
    for _, s in pairs(RP():GetSignups(occId)) do
        c[s.st] = (c[s.st] or 0) + 1
        if s.guest then c.guests = c.guests + 1 end
    end
    return c
end

-- The invited members still to answer (declined and blacklisted players are not waited for; a player who answered
-- with another character has answered).
local function noResponse(v, signups)
    local out = {}
    for key in pairs(RP():GetInvited(v) or {}) do
        if not RP():HasAnswered(signups, key) then
            local block = RP():GetSignupBlock(v, key)
            if block ~= "declined" and block ~= "blacklist" then out[#out + 1] = key end
        end
    end
    return out
end

local function isMe(key) return ns.Util.IsMe(key) end

-- The character I answer the raid with: the one picked, the one my answer is for, else the one logged in.
local function myChar(occId)
    if state.pendingChar and occId == state.selected then return state.pendingChar end
    return (occId and RP():GetMySignupCharacter(occId)) or ns.Util.PlayerKey()
end

local function classOfChar(key)
    if not key or isMe(key) then
        local _, classFile = UnitClass("player")
        return classFile
    end
    return ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key) or nil
end

local function Print(...) ns:Print(...) end

---------------------------------------------------------------------------
-- Upcoming: what the board and the page share (my answer in words, a raid's tooltip, the filters, the rows)
---------------------------------------------------------------------------

local function myStatusText(v)
    local mine = RP():GetMySignup(v.id)
    if mine then return colorize(STATUS[mine.st].color, STATUS[mine.st].label), STATUS[mine.st].color end
    local block = RP():GetSignupBlock(v)
    if block == "blacklist" then return grey("blocked"), nil end
    if block == "declined" then return colorize("ff5555", "declined"), "ff5555" end
    local inv = RP():GetInvited(v)
    local me = ns.Util.PlayerKey()
    if inv and me and inv[me] then return colorize("ff9933", "not answered"), "ff9933" end
    if block == "level" then return grey("level " .. v.ml .. " only"), nil end
    if RP():GetMyRequest(v.id) then return colorize("ffd100", "requested"), "ffd100" end
    if RP():CanRequest(v) then return grey("ask to join"), nil end
    if block then return grey("not invited"), nil end
    return grey("not answered"), nil
end

-- Hovering a raid in the list: everything about it, in full (the row cuts long names and lines off).
-- The names of a raid's instances, joined ("Gruul's Lair + Magtheridon's Lair"); short = the short forms ("Gruul +
-- Mag"); nil for a raid of "Other" alone.
local function instNames(v, short)
    local list = RP():GetRaidInstances(v)
    if short then return #list > 0 and ns.RaidComp:ShortInstanceNames(list) or nil end
    local names = {}
    for _, key in ipairs(list) do
        local inst = RP():GetInstance(key)
        if inst and key ~= "other" then names[#names + 1] = inst.name end
    end
    return #names > 0 and tconcat(names, " + ") or nil
end

local function raidRowTooltip(row)
    local d = row.__cdlData
    local v = d and d.v
    if not v then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(raidTitle(v) .. (v.cancelled and "  |cffff5555CANCELLED|r" or ""))
    GameTooltip:AddLine(date("%A %d %B", v.t) .. " · " .. fmtTime(v.t) .. (v.weekly and " · weekly" or ""), 1, 1, 1)
    local names = instNames(v)
    if (v.ti or #RP():GetRaidInstances(v) > 1) and names then GameTooltip:AddLine(names, 0.8, 0.8, 0.8, true) end
    GameTooltip:AddLine("For: " .. teamNames(v), 0.8, 0.8, 0.8, true)
    if v.ml then GameTooltip:AddLine(("Level %d characters only"):format(v.ml), 0.8, 0.8, 0.8) end
    local c = counts(v.id)
    local parts = { ("%d/%d accepted"):format(c.A, v.sz or 0) }
    if c.guests > 0 then parts[#parts + 1] = c.guests .. (c.guests == 1 and " guest" or " guests") end
    if c.T > 0 then parts[#parts + 1] = c.T .. " tentative" end
    if c.B > 0 then parts[#parts + 1] = c.B .. " bench" end
    if c.X > 0 then parts[#parts + 1] = c.X .. " absent" end
    local waiting = #noResponse(v, RP():GetSignups(v.id))
    if waiting > 0 then parts[#parts + 1] = waiting .. " no response" end
    GameTooltip:AddLine(tconcat(parts, " · "), 1, 1, 1, true)
    if v.no then GameTooltip:AddLine('"' .. v.no .. '"', 1, 0.82, 0, true) end
    if v.by then GameTooltip:AddLine("Planned by " .. shortName(v.by), 0.6, 0.6, 0.6) end
    if not v.cancelled then
        local status = myStatusText(v)
        GameTooltip:AddLine("You: " .. status, 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end

local WHEN_OPTIONS = {
    { value = "all", text = "Any time" },
    { value = "today", text = "Today" },
    { value = "week", text = "This week" },
    { value = "next", text = "Next week" },
    { value = "later", text = "Later" },
    { value = "past", text = "Past raids" },
}

local function raidFilterOptions()
    local out = { { value = "all", text = "All raids" } }
    for _, inst in ipairs(RP():GetInstances()) do out[#out + 1] = { value = inst.key, text = inst.name } end
    return out
end

local function filtered()
    return state.filterRaid ~= "all" or state.filterWhen ~= "all"
end

-- Does the raid pass the list's filters (which raid, and when)?
local function passesFilter(v, now, ws)
    if state.filterRaid ~= "all" then
        -- (a raid of several instances shows under each of them)
        local hit = false
        for _, key in ipairs(RP():GetRaidInstances(v)) do
            if key == state.filterRaid then hit = true end
        end
        if not hit then return false end
    end
    local when = state.filterWhen
    if when == "today" then
        local d = date("*t", now)
        d.hour, d.min, d.sec, d.isdst = 0, 0, 0, nil
        local from = time(d)
        return v.t >= from and v.t < from + DAY
    elseif when == "week" then
        return v.t >= ws and v.t < ws + 7 * DAY
    elseif when == "next" then
        return v.t >= ws + 7 * DAY and v.t < ws + 14 * DAY
    elseif when == "later" then
        return v.t >= ws + 14 * DAY
    elseif when == "past" then
        return v.t < now - 6 * 3600
    end
    return true
end

-- { header } / { v } rows: This week, Next week, Later, then Recent (past) newest first.
local function raidRows()
    local now = Now()
    local ws = weekStart(now)
    local buckets = { {}, {}, {}, {} }
    local labels = { "This week", "Next week", "Later", "Recent" }
    local function add(v)
        local b
        if v.t < now - 6 * 3600 then b = 4
        elseif v.t < ws + 7 * DAY then b = 1
        elseif v.t < ws + 14 * DAY then b = 2
        else b = 3
        end
        if passesFilter(v, now, ws) then buckets[b][#buckets[b] + 1] = v end
    end
    local listed = false
    for _, v in ipairs(RP():GetRaids()) do
        if v.id == state.opened then listed = true end
        add(v)
    end
    -- a raid opened from elsewhere that the list doesn't reach (the Home calendar: a weekly raid further ahead)
    local opened = not listed and state.opened and RP():GetRaid(state.opened)
    if opened then
        add(opened)
        tsort(buckets[3], function(a, b) return a.t < b.t end)
    end
    local r = buckets[4]
    tsort(r, function(a, b) return a.t > b.t end)
    local rows = {}
    for i, list in ipairs(buckets) do
        if #list > 0 then
            rows[#rows + 1] = { header = labels[i] }
            for _, v in ipairs(list) do rows[#rows + 1] = { v = v } end
        end
    end
    return rows
end

-- The raid to show when nothing (valid) is selected: the first I still have to answer, else the next one.
local function defaultSelection(rows)
    local first
    for _, d in ipairs(rows) do
        local v = d.v
        if v and not v.cancelled and v.t >= Now() - 6 * 3600 then
            first = first or v.id
            local inv = RP():GetInvited(v)
            local me = ns.Util.PlayerKey()
            if inv and me and inv[me] and not RP():GetMySignup(v.id) then return v.id end
        end
    end
    if first then return first end
    for _, d in ipairs(rows) do
        if d.v then return d.v.id end
    end
    return nil
end

---------------------------------------------------------------------------
-- Upcoming: the roster's tooltip and menu
---------------------------------------------------------------------------

-- "Sign-up #7 of 23 · Tue 30 Sep 20:14" (+ "Changed to Accepted Wed 01 Oct 18:02" when the answer changed later).
local function signupLines(s, order, total)
    local out = {}
    if not s then return out end
    local at = s.at or s.rev
    if order then
        out[#out + 1] = ("Sign-up #%d of %d · %s"):format(order, total or order, date("%a %d %b %H:%M", at))
    end
    if s.rev and at and s.rev - at >= 60 then
        out[#out + 1] = ("Changed to %s %s"):format(STATUS[s.st].label, date("%a %d %b %H:%M", s.rev))
    end
    return out
end

local function cellTooltip(cell)
    local d = cell.cdlCell
    if not d then return end
    if d.open then return PlanUI:OpenSlotTooltip(cell) end   -- (an open slot of the team's comp)
    local s = d.s
    GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
    GameTooltip:AddLine(colored(d.key, classOf(d.key, s)))
    local spec = specOf(s)
    local cls = classOf(d.key, s)
    GameTooltip:AddLine(((spec and spec.label .. " ") or "") .. (cls and ns.CLASS_NAMES[cls] or ""), 1, 1, 1)
    if d.declined then
        GameTooltip:AddLine("Declined for this raid", 1, 0.33, 0.33)
        if s and s.st and STATUS[s.st] then GameTooltip:AddLine("Had answered " .. STATUS[s.st].label, 0.7, 0.7, 0.7) end
    elseif d.request then
        GameTooltip:AddLine("Asks to join this raid (outside its teams)", 1, 0.82, 0, true)
        if s and s.n then GameTooltip:AddLine('"' .. s.n .. '"', 1, 0.82, 0, true) end
        if state.selected and RP():CanManageRaid(state.selected) then
            GameTooltip:AddLine("Click to approve or deny", 0.5, 0.5, 0.5)
        end
    elseif d.guest then
        GameTooltip:AddLine("Guest: a player outside the guild", 0.4, 0.8, 1, true)
        -- 1.3: what the guest book knows about them (roster managers)
        local summary = RP():CanManageRoster() and ns.GuestBook and ns.GuestBook:Summary(d.key)
        if summary then GameTooltip:AddLine(summary, 0.7, 0.7, 0.7, true) end
    elseif s then
        GameTooltip:AddLine(STATUS[s.st].label, 0.8, 0.8, 0.8)
        if s.n then GameTooltip:AddLine('"' .. s.n .. '"', 1, 0.82, 0, true) end
        for _, line in ipairs(signupLines(s, d.order, d.total)) do GameTooltip:AddLine(line, 0.7, 0.7, 0.7) end
    end
    if not d.request and state.selected and RP():CanManageRoster(state.selected) then
        GameTooltip:AddLine("Right-click for options", 0.5, 0.5, 0.5)
    end
    local RL = ns.RaidLog
    if ns.Guild and ns.Guild.AmIRaidLogMember and ns.Guild:AmIRaidLogMember() and RL and RL.GetAttendanceText then
        local att = RL:GetAttendanceText(d.key)
        if att then GameTooltip:AddLine("Attendance " .. att, 0.7, 0.7, 0.7) end
        local rel = RL.GetReliabilityText and RL:GetReliabilityText(d.key)
        if rel then GameTooltip:AddLine("Sign-ups: " .. rel, 0.7, 0.7, 0.7) end
    end
    GameTooltip:Show()
end

-- Right-click on a player of the roster (roster managers): decline, remove the answer, restore, remove a guest; the
-- blacklist and the guest book for who keeps them (the GM, officers, the raid leaders on the list: a raid's own leader
-- only runs that raid's roster).
local function rosterMenu(cell)
    local d = cell.cdlCell
    local occ = state.selected
    if not d or not occ then return end
    local function run(fn, ...)
        local ok, err = fn(RP(), occ, ...)
        if not ok then Print(err or "Could not change the raid.") end
    end
    -- a request to join: who runs the raid answers it (approve: invited to this raid only; deny: declined)
    if d.request then
        if not RP():CanManageRaid(occ) then return end
        UI():ContextMenu(cell, function(root)
            root:CreateTitle(shortName(d.key) .. " asks to join")
            root:CreateButton("|cff33dd33Approve|r: invite to this raid", function() run(RP().ApproveRequest, d.key) end)
            root:CreateButton("|cffff5555Deny|r", function() run(RP().DeclineSignup, d.key) end)
        end)
        return
    end
    if not RP():CanManageRoster(occ) then return end
    UI():ContextMenu(cell, function(root)
        root:CreateTitle(shortName(d.key))
        if d.guest then
            root:CreateButton("Remove guest", function() run(RP().RemoveGuest, d.key) end)
        elseif d.declined then
            root:CreateButton("Restore: their answer counts again", function() run(RP().RestoreSignup, d.key) end)
        else
            root:CreateButton("Decline for this raid", function() run(RP().DeclineSignup, d.key) end)
            if d.s then
                root:CreateButton("Remove their answer", function() run(RP().RemoveSignup, d.key) end)
            end
        end
        if RP():CanManageRoster() then
            root:CreateDivider()
            root:CreateButton("Blacklist...", function() PlanUI:OpenBlacklist(d.key) end)
            if d.guest then root:CreateButton("Guest book...", function() ns.GuestBookUI:OpenGuest(d.key) end) end
        end
    end)
end

---------------------------------------------------------------------------
-- Upcoming: the board (every raid as a card) and the raid's page (a banner with my answer, then Sign-ups / Groups /
-- Assignments). The raids' own loading screens are the art. One spacing grid everywhere: PAD at the sides (the
-- Dungeons tab's), GAP between cards and columns, 12 inside the banner; scroll bars sit in the right margin.
---------------------------------------------------------------------------

-- Loading screens (2048x2048 textures shown at 4:3) and the part a card shows: centre cx, cy as a share.
local RAID_ART = {
    kara = { 131849, 0.30, 0.45 }, gruul = { 131842, 0.30, 0.45 }, mag = { 131846, 0.50, 0.42 },
    ssc = { 131832, 0.32, 0.46 }, tk = { 131875, 0.50, 0.40 }, hyjal = { 131847, 0.40, 0.45 },
    bt = { 131826, 0.30, 0.56 }, za = { 131884, 0.30, 0.45 }, swp = { 131873, 0.55, 0.50 },
    other = { 131860, 0.50, 0.45 },
}
local PAD, GAP = 10, 8
local CARD_H = 92                    -- a raid on the board: a banner of its loading screen (the Teams board's height)
local FILTER_ROW = 22
local SECTION_H = 30
local HERO_H = 128                   -- the raid's banner (the same on every tab); its tabs sit on its foot
local TABS_H = 34
local CARD_BG = { 0.10, 0.10, 0.12, 0.92 }
local PANEL_BG = { 0.08, 0.08, 0.095, 0.9 }
local EDGE = { 0.34, 0.34, 0.38, 0.5 }
local PILL = {
    A = { 0.16, 0.43, 0.22, 0.35, 0.35, 0.86, 0.47, "b7f5c3" }, T = { 0.47, 0.39, 0.08, 0.35, 1, 0.82, 0, "ffe680" },
    B = { 0.20, 0.27, 0.45, 0.35, 0.6, 0.73, 1, "c4d6ff" }, X = { 0.45, 0.10, 0.10, 0.35, 1, 0.33, 0.33, "ffb0b0" },
    R = { 0.47, 0.39, 0.08, 0.35, 1, 0.82, 0, "ffe680" }, N = { 0.2, 0.2, 0.22, 0.6, 0.45, 0.45, 0.48, "9e9e9e" },
}
-- The raid page in the Teams look (2026-10-08, dev/art/casc/teams_mockup/build_raidpage.py): its sizes and helpers
-- (one local: this file is near Lua's 200 locals).
local UP = {
    W = 770,                 -- the width inside PAD (GetWidth is 0 before a layout)
    LT_BG = { 0.085, 0.085, 0.1 },   -- the tabs' strip, and the banner's foot fading into it
    TB_H = 26,               -- the open tab's tool row, under the tabs
    TAB_MIN = 170,           -- a page tab's least width
    -- Sign-ups as the Comp view's role bands: the gutter (role, count, pips), five plates a row after it
    GUT = 104, GUT_W = 96, TILES = 5, TILE_H = 30, TILE_GAP = 4, TILE_GAPX = 6, BAND_GAP = 12,
    ANS_W = 330,             -- the banner's answer side (the title never runs under it)
}
UP.TB_Y = HERO_H + TABS_H + 10                   -- the tool row's top
UP.BODY_Y = UP.TB_Y + UP.TB_H + 8                -- where a tab's content starts

-- (melee, ranged and casters share the damage icon)
local function roleIcon(role, size) return UI():RoleIconText(role, size) end

-- The loading screen and tex coords (l, r, t, b) that show raid `inst` in a w x h box; fw = share of its width.
local function artCoords(inst, w, h, fw, cy)
    local a = RAID_ART[inst] or RAID_ART.other
    fw = fw or 0.5
    local fh = fw * (4 / 3) * (h / w)
    local l = min(max(a[2] - fw / 2, 0), 1 - fw)
    local t = min(max((cy or a[3]) - fh / 2, 0.02), 0.98 - fh)
    return a[1], l, l + fw, t, t + fh
end

local function textOf(parent, font, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags) end
    end
    return fs
end

local function setSize(fs, size)
    local path, _, flags = fs:GetFont()
    if path then fs:SetFont(path, size, flags) end
end

local function gradient(tex, orient, r, g, b, a1, a2)
    tex:SetColorTexture(1, 1, 1, 1)
    if tex.SetGradient and CreateColor then tex:SetGradient(orient, CreateColor(r, g, b, a1), CreateColor(r, g, b, a2)) end
end

local function panel(f, bg, edge)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    bg = bg or PANEL_BG
    f.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    UI():AddEdges(f, "BORDER")
    edge = edge or EDGE
    UI():SetEdgeColor(f, edge[1], edge[2], edge[3], edge[4])
end

-- The atlas chevron (it points down) turned to point left: the back link's arrow.
local function leftChevron(tex)
    local c = UI():IconCoords(UI().ICON.chevron)
    local l, r, t, b = c[1], c[2], c[3], c[4]
    tex:SetTexture(UI().ICON_ATLAS)
    tex:SetTexCoord(l, b, r, b, l, t, r, t)
end

-- "today", "tomorrow", "in 3 days", "next week", "2 weeks ago".
local function relDay(t)
    local now = Now()
    local d0, d1 = date("*t", now), date("*t", t)
    local n0 = time({ year = d0.year, month = d0.month, day = d0.day, hour = 12 })
    local n1 = time({ year = d1.year, month = d1.month, day = d1.day, hour = 12 })
    local days = floor((n1 - n0) / DAY + 0.5)
    if days == 0 then
        if t > now then
            local h = floor((t - now) / 3600)
            return h >= 1 and ("in " .. h .. " h") or ("in " .. max(1, floor((t - now) / 60)) .. " min")
        end
        return "today"
    end
    if days == 1 then return "tomorrow" end
    if days == -1 then return "yesterday" end
    if days > 1 and days < 7 then return "in " .. days .. " days" end
    if days >= 7 then return "in " .. floor(days / 7 + 0.5) .. (floor(days / 7 + 0.5) == 1 and " week" or " weeks") end
    return (-days) .. " days ago"
end

-- My answer to a raid as the card / page shows it: kind ("A" | "T" | "B" | "X" | "R" request | "N" no answer |
-- "C" cancelled | "past"), the block reason, whether I can answer, can ask to join, my sign-up.
local function myState(v)
    local char = (state.selected == v.id and state.pendingChar) or RP():GetMySignupCharacter(v.id) or ns.Util.PlayerKey()
    local mine = RP():GetMySignup(v.id)
    local open = not v.cancelled and v.t >= Now() - 6 * 3600
    local block = RP():GetSignupBlock(v, char)
    local canAsk = block == "lock" and RP():CanRequest(v, char)
    local request = canAsk and RP():GetMyRequest(v.id)
    if v.cancelled then return "C", block, false, false, mine end
    if mine then return mine.st, block, open, canAsk, mine end
    if request then return "R", block, open, canAsk, request end
    if not open then return "past", block, false, false, nil end
    return "N", block, open and (block == nil or canAsk), canAsk, nil
end

-- Why I can't answer, in a few words (the card) / a sentence (the banner); nil when I can.
local function blockWords(v, block, organizer)
    if block == "blacklist" then return "Can't sign up", "You can't sign up for raids. Contact an officer." end
    if block == "declined" then return "Taken off this raid", "You were taken off this raid." end
    if block == "level" then
        return ("Level %d only"):format(v.ml), ("This raid is for level %d characters."):format(v.ml)
    end
    if block == "lock" then
        if organizer then return "Not invited", (v.pv and "Private" or "Locked") .. ": you are not in this raid (Invite adds you)" end
        return v.pv and "Private" or "Locked to its teams", "Private: ask a raid leader for an invite"
    end
    return nil
end

-- Accepted (and tentative) players by role: { tank, healer, melee, ranged, nospec }, tentative count.
local function roleCounts(v)
    local out = { tank = 0, healer = 0, melee = 0, ranged = 0, nospec = 0 }
    local tentative = 0
    for _, s in pairs(RP():GetSignups(v.id)) do
        if s.st == "A" then
            local role = roleOf(s) or "nospec"
            out[role] = out[role] + 1
        elseif s.st == "T" then
            tentative = tentative + 1
        end
    end
    return out, tentative
end

-- The answer pill (my answer, my request, cancelled): a flat tag in the answer's colour with a dot. p:Set(kind, text,
-- sub); sub is a line under it (the banner's), nil for none.
local function newPill(parent)
    local p = CreateFrame("Button", nil, parent)
    p:SetHeight(20)
    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints()
    UI():AddEdges(p, "BORDER")
    p.dot = p:CreateTexture(nil, "ARTWORK")
    p.dot:SetSize(6, 6)
    p.dot:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    p.dot:SetPoint("LEFT", 10, 0)
    p.text = textOf(p, "GameFontHighlight", 11)
    p.text:SetPoint("LEFT", p.dot, "RIGHT", 7, 0)
    p.sub = textOf(parent, "GameFontHighlightSmall", 10)
    p.sub:SetTextColor(0.62, 0.62, 0.62)
    p.sub:SetJustifyH("RIGHT")
    p.sub:SetPoint("TOPRIGHT", p, "BOTTOMRIGHT", -2, -4)
    function p:Set(kind, text, sub)
        local c = PILL[kind] or PILL.N
        self.bg:SetColorTexture(c[1], c[2], c[3], 0.5)
        UI():SetEdgeColor(self, c[5], c[6], c[7], 0.4)
        self.dot:SetVertexColor(c[5], c[6], c[7], 1)
        self.text:SetText("|cff" .. c[8] .. text .. "|r")
        self:SetWidth(floor(10 + 6 + 7 + (self.text:GetStringWidth() or 40) + 11 + 0.5))
        self.sub:SetText(sub or "")
        self.sub:SetShown(sub ~= nil)
    end
    function p:SetPillShown(on)
        self:SetShown(on)
        if not on then self.sub:Hide() end
    end
    return p
end

local PILL_TEXT = { A = "Accepted", T = "Tentative", B = "Bench", X = "Absent", R = "Asked to join", C = "Cancelled" }

local function specLabelOf(s)
    local spec = specOf(s)
    return spec and spec.label or nil
end

-- The answers menu of a card's ... button / pill: every answer, the current one ticked.
local function answerMenu(owner, v, current)
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(raidTitle(v))
        for _, st in ipairs(STATUS_ORDER) do
            local label = (current == st and "|cff33ff33" .. STATUS[st].button .. " (yours)|r") or STATUS[st].button
            root:CreateButton(label, function() PlanUI:Answer(st, v.id) end)
        end
        if root.CreateDivider then root:CreateDivider() end
        root:CreateButton("Open the raid", function() PlanUI:SelectRaid(v.id) end)
    end)
end

-- The board's raid: a banner of its loading screen (a raid of several instances: two screens side by side), like the
-- Teams board's teams. Left: when (gold while it is close), the name, where / who leads / who it is for. Right: my
-- answer (a pill once given; Accept / Tentative / ... while not; Ask to join; or why I can't) and under it who accepted
-- by role and how full it is. The New raid sheet shows one as its preview (PlanUI:CreateRaidCard).
local function newRaidCard(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(CARD_H)
    c:RegisterForClicks("LeftButtonUp")
    c.bg = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    c.bg:SetAllPoints()
    c.bg:SetColorTexture(0.055, 0.055, 0.067, 1)
    c.art = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.art:SetPoint("TOPLEFT", 0, 0)
    c.art:SetPoint("BOTTOMLEFT", 0, 0)
    c.art:SetVertexColor(0.85, 0.85, 0.85)
    c.art2 = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.art2:SetPoint("TOPLEFT", c.art, "TOPRIGHT", 0, 0)
    c.art2:SetPoint("BOTTOMRIGHT", 0, 0)
    c.art2:SetVertexColor(0.85, 0.85, 0.85)
    c.art2:Hide()
    c.artLine = c:CreateTexture(nil, "BACKGROUND", nil, 4)
    c.artLine:SetColorTexture(0, 0, 0, 0.6)
    c.artLine:SetWidth(2)
    c.artLine:SetPoint("TOPLEFT", c.art2, "TOPLEFT", -1, 0)
    c.artLine:SetPoint("BOTTOMLEFT", c.art2, "BOTTOMLEFT", -1, 0)
    c.artLine:Hide()
    c.fadeL = c:CreateTexture(nil, "BACKGROUND", nil, 3)
    c.fadeL:SetPoint("TOPLEFT", 0, 0)
    c.fadeL:SetPoint("BOTTOMLEFT", 0, 0)
    c.fadeL:SetWidth(460)
    gradient(c.fadeL, "HORIZONTAL", 0.055, 0.055, 0.067, 0.96, 0.28)
    c.fadeR = c:CreateTexture(nil, "BACKGROUND", nil, 3)
    c.fadeR:SetPoint("TOPLEFT", c.fadeL, "TOPRIGHT", 0, 0)
    c.fadeR:SetPoint("BOTTOMRIGHT", 0, 0)
    gradient(c.fadeR, "HORIZONTAL", 0.055, 0.055, 0.067, 0.28, 0.8)
    UI():AddEdges(c, "BORDER")
    UI():SetEdgeColor(c, 1, 1, 1, 0.07)
    -- the left: when, the name, where and who
    c.kick = textOf(c, "GameFontNormalSmall", 10)
    c.kick:SetTextColor(0.72, 0.72, 0.72)
    c.kick:SetPoint("LEFT", c, "TOPLEFT", 18, -21)
    c.t1 = textOf(c, "GameFontHighlightLarge", 20)
    c.t1:SetPoint("TOPLEFT", 18, -34)
    c.t2 = textOf(c, "GameFontHighlightSmall", 11)
    c.t2:SetTextColor(0.66, 0.66, 0.66)
    c.t2:SetPoint("TOPLEFT", 18, -64)
    -- the right, on top: my answer
    c.more = UI():CreateTipIconButton(c, 22, UI().ICON.more, "More answers", "Bench or Absent, or open the raid.")
    c.more:SetPoint("TOPRIGHT", -18, -15)
    c.tentative = UI():CreateSleekButton(c, "Tentative", 76, 22, nil)
    c.tentative:SetPoint("RIGHT", c.more, "LEFT", -4, 0)
    c.accept = UI():CreateSleekButton(c, "Accept", 64, 22, nil, "primary")
    c.accept:SetPoint("RIGHT", c.tentative, "LEFT", -4, 0)
    c.ask = UI():CreateSleekButton(c, "Ask to join", 90, 22, nil)
    c.ask:SetPoint("TOPRIGHT", -18, -15)
    c.why = textOf(c, "GameFontHighlightSmall", 11)
    c.why:SetTextColor(0.62, 0.62, 0.62)
    c.why:SetJustifyH("RIGHT")
    c.why:SetPoint("RIGHT", c, "TOPRIGHT", -18, -26)
    c.pill = newPill(c)
    c.pill:SetPoint("TOPRIGHT", -18, -16)
    -- the right, under it: who accepted by role, and how full it is
    c.r3 = textOf(c, "GameFontHighlightSmall", 11)
    c.r3:SetJustifyH("RIGHT")
    c.r3:SetPoint("RIGHT", c, "TOPRIGHT", -18, -65)
    c.track = c:CreateTexture(nil, "ARTWORK")
    c.track:SetSize(110, 3)
    c.track:SetColorTexture(1, 1, 1, 0.14)
    c.track:SetPoint("RIGHT", c.r3, "LEFT", -8, 0)
    c.fill = c:CreateTexture(nil, "ARTWORK", nil, 1)
    c.fill:SetHeight(3)
    c.fill:SetPoint("LEFT", c.track, "LEFT", 0, 0)
    c.fill:SetColorTexture(0.56, 0.89, 0.62, 1)
    c.meter = textOf(c, "GameFontHighlightSmall", 11)
    c.meter:SetJustifyH("RIGHT")
    c:SetScript("OnEnter", function(self)
        UI():SetEdgeColor(self, 1, 0.82, 0, 0.55)
        raidRowTooltip(self)
    end)
    c:SetScript("OnLeave", function(self)
        UI():SetEdgeColor(self, 1, 1, 1, 0.07)
        hideTooltip()
    end)
    c:SetScript("OnClick", function(self)
        local d = self.__cdlData
        if d and d.v then PlanUI:SelectRaid(d.v.id) end
    end)
    return c
end

-- The banner's kicker: "TOMORROW   FRI 9 OCT · 20:00" (the countdown in gold within a week; a raid that is over says
-- how long ago in grey; a cancelled one says so in red).
function UP.kicker(v)
    local when = (date("%a ", v.t) .. tonumber(date("%d", v.t)) .. date(" %b", v.t)):upper() .. " · " .. fmtTime(v.t)
    local now = Now()
    local lead
    if v.cancelled then lead = colorize("ff5555", "CANCELLED")
    elseif v.t < now - 6 * 3600 then lead = grey(relDay(v.t):upper())
    elseif v.t - now < 7 * DAY then lead = colorize("ffd100", relDay(v.t):upper()) end
    return lead and (lead .. "    " .. when) or when
end

local function fillRaidCard(c, v, width)
    c.__cdlData = { v = v }
    c:SetWidth(width)
    UI():SetEdgeColor(c, 1, 1, 1, 0.07)
    local list = RP():GetRaidInstances(v)
    local two = #list > 1
    local aw = two and floor(width / 2) or width
    local file, l, r, t, b = artCoords(list[1] or v.i, aw, CARD_H, two and 0.5 or 0.95)
    c.art:SetTexture(file)
    c.art:SetTexCoord(l, r, t, b)
    c.art:SetWidth(aw)
    c.art2:SetShown(two)
    c.artLine:SetShown(two)
    if two then
        local f2, l2, r2, t2, b2 = artCoords(list[2], width - aw, CARD_H, 0.5)
        c.art2:SetTexture(f2)
        c.art2:SetTexCoord(l2, r2, t2, b2)
    end
    c.fadeL:SetWidth(floor(width * 0.6))
    local past = v.t < Now() - 6 * 3600
    local dim = v.cancelled or past
    for _, art in ipairs({ c.art, c.art2 }) do
        art:SetDesaturated(dim and true or false)
        art:SetAlpha(dim and 0.6 or 1)
    end
    for _, fs in ipairs({ c.t1, c.meter, c.r3 }) do fs:SetAlpha(dim and 0.55 or 1) end
    c.kick:SetText(UP.kicker(v))
    c.t1:SetText(RP():GetRaidName(v))
    setSize(c.t1, 20)
    if (c.t1:GetStringWidth() or 0) > width - 18 - 260 then setSize(c.t1, 16) end
    -- where, who leads, who it is for; for who runs it, the requests waiting. Many teams: as many named as fit
    local inst = RP():GetInstance(list[1] or v.i)
    local where = ((two and instNames(v, true)) or (inst and inst.name) or "Raid") .. " · " .. (v.sz or 0)
    local nReq = (v.lk and RP():CanManageRaid(v)) and #RP():GetRequests(v.id) or 0
    local function line(keep)
        local parts = { where }
        if v.rl then parts[#parts + 1] = colored(v.rl) .. grey(" leads")
        elseif v.by then parts[#parts + 1] = "by " .. shortName(v.by) end
        local teams = teamNames(v, true, keep)
        if teams ~= "Everyone" then
            parts[#parts + 1] = (v.lk and ("|T" .. UI().ICON_LOCK .. ":11:11|t ") or "") .. teams
        end
        if v.weekly then parts[#parts + 1] = "weekly" end
        if nReq > 0 then parts[#parts + 1] = colorize("ffd100", nReq .. (nReq == 1 and " request" or " requests")) end
        return tconcat(parts, "   ·   ")
    end
    local lineW = width - 18 - 280
    for _, keep in ipairs({ false, 2, 1, 0 }) do
        c.t2:SetText(line(keep or nil))
        -- (the unbounded width: GetStringWidth stops at the width the line was given)
        local tw = c.t2.GetUnboundedStringWidth and c.t2:GetUnboundedStringWidth() or c.t2:GetStringWidth()
        if (tw or 0) <= lineW then break end
    end
    c.t1:SetWidth(width - 18 - 230)
    c.t2:SetWidth(lineW)

    -- who accepted by role and how full it is (no targets: the raid has none), or that nobody answered yet
    local rc, tentative = roleCounts(v)
    local cnt = counts(v.id)
    local any = cnt.A > 0 or tentative > 0
    c.track:SetShown(any)
    c.r3:SetShown(any)
    c.meter:ClearAllPoints()
    if any then
        c.meter:SetText(("%s %d      %s %d      %s %d"):format(roleIcon("tank", 12), rc.tank, roleIcon("healer", 12),
            rc.healer, roleIcon("dps", 12), rc.melee + rc.ranged + rc.nospec))
        c.meter:SetPoint("RIGHT", c.track, "LEFT", -14, 0)
        local of = v.sz or 0
        c.r3:SetText(colorize("ffffff", cnt.A) .. colorize("808080", "/" .. of))
        local share = of > 0 and min(1, cnt.A / of) or 0
        c.fill:SetShown(share > 0)
        c.fill:SetWidth(max(1, floor(110 * share + 0.5)))
    else
        c.fill:Hide()
        c.meter:SetText(grey("No answers yet"))
        c.meter:SetPoint("RIGHT", c, "TOPRIGHT", -18, -65)
    end

    -- my answer
    local kind, block, canAnswer, canAsk, mine = myState(v)
    for _, w in ipairs({ c.accept, c.tentative, c.more, c.ask }) do w:Hide() end
    c.why:Hide()
    c.pill:SetPillShown(false)
    local id = v.id
    if kind == "C" then
        c.pill:Set("N", "Cancelled")
        c.pill:SetPillShown(true)
        c.pill:SetScript("OnClick", nil)
        c.pill:SetScript("OnEnter", nil)
        c.pill:SetAlpha(1)
    elseif STATUS[kind] or kind == "R" then
        local spec = kind ~= "R" and mine and specLabelOf(mine)
        c.pill:Set(kind, PILL_TEXT[kind] .. (spec and ("  ·  " .. spec) or ""))
        c.pill:SetPillShown(true)
        local open = not v.cancelled and not past
        c.pill:SetScript("OnClick", open and function(self) answerMenu(self, v, kind) end or nil)
        c.pill:SetScript("OnEnter", function(self)
            if kind == "R" then UI():SetTextTooltip(self, { "Asked to join", "A raid leader approves it." }, "ANCHOR_TOP")
            elseif open then UI():SetTextTooltip(self, { "Your answer", "Click to change it." }, "ANCHOR_TOP") end
        end)
        c.pill:SetScript("OnLeave", hideTooltip)
        c.pill:SetAlpha(open and 1 or 0.6)
    elseif kind == "N" and canAsk then
        c.ask:SetScript("OnClick", function() PlanUI:Answer("A", id) end)
        c.ask:Show()
    elseif kind == "N" and canAnswer then
        c.accept:SetScript("OnClick", function() PlanUI:Answer("A", id) end)
        c.tentative:SetScript("OnClick", function() PlanUI:Answer("T", id) end)
        c.more:SetScript("OnClick", function(self) answerMenu(self, v, nil) end)
        c.accept:Show()
        c.tentative:Show()
        c.more:Show()
    elseif kind ~= "past" then
        local words = blockWords(v, block, RP():CanManageRaid(v))
        c.why:SetText(words or "")
        c.why:SetShown(words ~= nil)
    end
end

-- For other pages (Home): a raid card as the board draws it (a click opens the raid's page on the Raids tab), and a
-- raid's loading screen cropped for a w x h box (file, l, r, t, b; fw = the share of the screen's width shown).
function PlanUI:CreateRaidCard(parent) return newRaidCard(parent) end
function PlanUI:FillRaidCard(card, v, width) fillRaidCard(card, v, width) end
function PlanUI:RaidArt(inst, w, h, fw) return artCoords(inst, w, h, fw) end
function PlanUI:RaidCardHeight() return CARD_H end

---------------------------------------------------------------------------
-- The raid page: Sign-ups as role bands (the Teams Comp view's): the role, its count and a pip per player in a gutter
-- on the left, the players as plates five a row. Requests to join on top (Approve / Deny on the plate for who runs
-- the raid); the players outside the roles (spec not set, bench, absent, declined, no answer) in bands of their own
-- under them, dimmed.
---------------------------------------------------------------------------

local COLS = {
    { key = "tank", label = "Tanks" }, { key = "healer", label = "Healers" },
    { key = "melee", label = "Melee" }, { key = "ranged", label = "Ranged" },
}

local function cellRowClick(self, button)
    -- (an open slot of the team's comp: Add players; a request opens with either button; the rest of the roster
    -- with the right one)
    if self.cdlCell and self.cdlCell.open then
        if button == "LeftButton" then PlanUI:OpenSlotClick(self.cdlCell) end
        return
    end
    if button == "RightButton" or (self.cdlCell and self.cdlCell.request) then rosterMenu(self) end
end

-- A tile's x and width in the bands (column c of UP.TILES, after the gutter).
function UP.tileX(c)
    return UP.GUT + floor(c * (UP.W - UP.GUT + UP.TILE_GAPX) / UP.TILES + 0.5)
end

function UP.tileW(c)
    return UP.tileX(c + 1) - UP.TILE_GAPX - UP.tileX(c)
end

-- A small square button on a request's plate: Approve (the ready check's tick) or Deny (its cross).
function UP.reqButton(plate, tex, title, fn)
    local b = CreateFrame("Button", nil, plate)
    b:SetSize(20, 20)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0, 0, 0, 0.4)
    UI():AddEdges(b, "BORDER")
    UI():SetEdgeColor(b, 1, 1, 1, 0.12)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(13, 13)
    b.icon:SetPoint("CENTER", 0, 0)
    b.icon:SetTexture(tex)
    b:SetScript("OnClick", function()
        local d, occ = plate.cdlCell, state.selected
        if d and occ then fn(d, occ) end
    end)
    b:SetScript("OnEnter", function(self)
        UI():SetEdgeColor(self, 1, 0.82, 0, 0.7)
        UI():SetTextTooltip(self, title, "ANCHOR_TOP")
    end)
    b:SetScript("OnLeave", function(self)
        UI():SetEdgeColor(self, 1, 1, 1, 0.12)
        hideTooltip()
    end)
    return b
end

-- One player (or an open slot of the team's comp) as a plate. On its right: a ? for tentative, the note's icon, or on
-- a request Approve / Deny (who runs the raid).
function UP.newCell(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(UP.TILE_H)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", cellRowClick)
    b:SetScript("OnEnter", function(self) cellTooltip(self) end)
    b:SetScript("OnLeave", hideTooltip)
    ns.RaidGroupsUI:DecoratePlate(b)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.05)
    b.fs = b.pName                 -- (the name: tests and tools read it here)
    b.mark = b:CreateTexture(nil, "OVERLAY")
    b.mark:SetSize(12, 12)
    b.mark:SetPoint("RIGHT", -8, 0)
    b.no = UP.reqButton(b, "Interface\\RaidFrame\\ReadyCheck-NotReady", { "Deny", "They stay out of this raid." },
        function(d, occ)
            local ok, err = RP():DeclineSignup(occ, d.key)
            if not ok then Print(err or "Could not change the raid.") end
        end)
    b.no:SetPoint("RIGHT", -6, 0)
    b.yes = UP.reqButton(b, "Interface\\RaidFrame\\ReadyCheck-Ready", { "Approve", "Invites them to this raid (only)." },
        function(d, occ)
            local ok, err = RP():ApproveRequest(occ, d.key)
            if not ok then Print(err or "Could not change the raid.") end
        end)
    b.yes:SetPoint("RIGHT", b.no, "LEFT", -4, 0)
    return b
end

-- (the name and spec lines end before what the plate shows on its right)
function UP.cellRoom(b, right)
    b.pName:SetPoint("RIGHT", b, "RIGHT", right, 0)
    b.pSub:SetPoint("RIGHT", b, "RIGHT", right, 0)
end

function UP.fillCell(b, cell, organizer)
    b.cdlCell = cell
    local G = ns.RaidGroupsUI
    b.mark:Hide()
    b.yes:Hide()
    b.no:Hide()
    b:SetAlpha(1)
    if cell.open then
        G:PaintPlate(b, G:GhostPlate({ c = cell.c, sp = cell.sp, name = cell.name }))
        UP.cellRoom(b, -6)
        b:Show()
        return
    end
    local s = cell.s
    local cls = (s and s.c) or classOf(cell.key, s)
    local spec = specLabelOf(s)
    local st = s and s.st
    local sub = spec or "Spec not set"
    local short
    if cell.request then sub, short = sub .. " · wants to join", "wants to join"
    elseif cell.declined then sub = "declined"
    elseif cell.dim then sub = "no answer yet" end
    -- (a guest: "Guest" in blue before the spec; a narrow plate keeps "Guest" alone)
    if cell.guest then sub, short = "|cff66ccffGuest|r · " .. sub, "|cff66ccffGuest|r" end
    G:PaintPlate(b, { kind = "player", c = cls, sp = s and s.sp, name = colored(cell.key, cls), sub = sub,
                      subShort = short, auto = spec == nil, dim = cell.out, edge = isMe(cell.key) and "me" or nil })
    local right = -6
    if cell.request then
        UI():SetEdgeColor(b, 1, 0.82, 0, 0.55)
        if organizer then
            b.yes:Show()
            b.no:Show()
            right = -54
        end
    elseif st == "T" and not cell.out then
        b.mark:SetTexture("Interface\\RaidFrame\\ReadyCheck-Waiting")
        b.mark:SetTexCoord(0, 1, 0, 1)
        b.mark:SetVertexColor(1, 1, 1)
        b.mark:Show()
        right = -24
    elseif s and s.n and s.n ~= "" and not cell.out then
        b.mark:SetTexture(UI().ICON_ATLAS)
        b.mark:SetTexCoord(unpack(UI():IconCoords(UI().ICON.notes)))
        b.mark:SetVertexColor(1, 0.82, 0)
        b.mark:Show()
        right = -24
    end
    UP.cellRoom(b, right)
    b:SetAlpha((cell.out and 0.6) or (st == "T" and 0.8) or 1)
    b:Show()
end

-- The roster model: { cols = { [i] = { label, role, count, more, cells } }, boxes = { { label, color, cells, req } } }.
local function rosterModel(v)
    local signups = RP():GetSignups(v.id)
    local order, total = RP():GetSignupOrder(v.id)
    local declined = RP():GetDeclined(v)
    local function cell(key)
        if declined[key] and not signups[key] then return { key = key, s = declined[key], declined = true } end
        local s = signups[key]
        return { key = key, s = s, order = order[key], total = total, guest = s and s.guest or nil }
    end
    local byRole = { tank = {}, healer = {}, melee = {}, ranged = {} }
    local other = { B = {}, X = {}, nospec = {} }
    for key, s in pairs(signups) do
        if s.st == "A" or s.st == "T" then
            local role = roleOf(s)
            if role then byRole[role][#byRole[role] + 1] = key else other.nospec[#other.nospec + 1] = key end
        else
            other[s.st][#other[s.st] + 1] = key
        end
    end
    local model = { cols = {}, boxes = {} }
    for i, col in ipairs(COLS) do
        local list = byRole[col.key]
        tsort(list, function(a, b)
            local sa, sb = signups[a].st, signups[b].st
            if sa ~= sb then return sa == "A" end
            return (order[a] or 0) < (order[b] or 0)
        end)
        local accepted = 0
        for _, key in ipairs(list) do if signups[key].st == "A" then accepted = accepted + 1 end end
        local cells = {}
        for _, key in ipairs(list) do cells[#cells + 1] = cell(key) end
        model.cols[i] = { label = col.label, role = col.key, count = accepted, more = #list - accepted, cells = cells }
    end
    -- 1.3.1: the open slots of the team's target comp, as ghosts at the end of each role's band (the counts stay the
    -- answers); a raid that is over has none
    local open = v.t >= Now() - 6 * 3600 and RP():GetRaidOpenSlots(v) or nil
    if open then
        local colOf = { tank = 1, healer = 2, melee = 3, ranged = 4 }
        for _, sl in ipairs(open.slots or {}) do
            local col = model.cols[colOf[sl.role] or 0]
            if col then
                col.cells[#col.cells + 1] = { open = true, c = sl.c, sp = sl.sp, name = sl.name, occ = v.id,
                                              team = open.teamName }
            end
        end
    end
    local function box(label, color, keys, less, dim)
        if #keys == 0 then return end
        tsort(keys, less or function(a, b) return (order[a] or 0) < (order[b] or 0) end)
        local cells = {}
        for _, key in ipairs(keys) do
            local c = cell(key)
            c.dim = dim
            c.out = true
            cells[#cells + 1] = c
        end
        model.boxes[#model.boxes + 1] = { label = label, color = color, cells = cells, n = #keys }
    end
    -- requests to join first: who runs the raid answers them (on the plate)
    local requests = RP():GetRequests(v.id)
    if #requests > 0 then
        local cells = {}
        for _, r in ipairs(requests) do
            cells[#cells + 1] = { key = r.key, s = { c = r.c, sp = r.sp, n = r.n }, request = true }
        end
        model.boxes[#model.boxes + 1] = { label = "Requests", color = "ffd100", cells = cells, n = #requests,
                                          req = true }
    end
    box("Spec not set", STATUS.T.color, other.nospec)
    box("Bench", STATUS.B.color, other.B)
    box("Absent", STATUS.X.color, other.X)
    local out = {}
    for key in pairs(declined) do
        if not signups[key] then out[#out + 1] = key end
    end
    box("Declined", "ff5555", out, nameLess)
    box("To answer", "ff9933", noResponse(v, signups), nameLess, true)
    return model
end

-- A band: its label (a role's icon first) and count in the gutter, a rule above it (but the first), its plates.
function UP.newBand(parent, role)
    local col = CreateFrame("Frame", nil, parent)
    col.role = col:CreateTexture(nil, "ARTWORK")
    col.role:SetTexture(UI().ROLE_TEX)
    col.role:SetSize(15, 15)
    col.role:SetPoint("LEFT", col, "TOPLEFT", 0, -8)
    col.role:SetShown(role and true or false)
    col.title = textOf(col, "GameFontHighlight", 12)
    col.title:SetPoint("LEFT", col, "TOPLEFT", role and 21 or 0, -8)
    col.count = textOf(col, "GameFontHighlight", 11)
    col.count:SetJustifyH("RIGHT")
    col.count:SetPoint("RIGHT", col, "TOPLEFT", UP.GUT_W, -8)
    col.rule = col:CreateTexture(nil, "BORDER")
    col.rule:SetColorTexture(1, 1, 1, 0.055)
    col.rule:SetHeight(1)
    col.rule:SetPoint("BOTTOMLEFT", col, "TOPLEFT", 0, 6)
    col.rule:SetPoint("BOTTOMRIGHT", col, "TOPRIGHT", 0, 6)
    -- (requests: a soft gold wash behind the band)
    col.wash = col:CreateTexture(nil, "BACKGROUND")
    col.wash:SetPoint("TOPLEFT", 0, 6)
    col.wash:SetPoint("BOTTOMRIGHT", 0, -6)
    gradient(col.wash, "HORIZONTAL", 1, 0.82, 0, 0.07, 0)
    col.wash:Hide()
    col.none = textOf(col, "GameFontDisableSmall", 11)
    col.none:SetPoint("LEFT", col, "TOPLEFT", UP.GUT + 2, -15)
    col.none:SetText("Nobody yet")
    col.pips = {}
    col.pipsH = 0
    col.rows = {}
    col.cells = col.rows
    return col
end

-- The gutter's pips: a square per player in their class colour (faded: tentative), hollow for an open slot.
function UP.fillPips(col, cells)
    local per = max(1, floor((UP.GUT_W + 2) / 8))
    local n = 0
    for j, cell in ipairs(cells) do
        n = j
        local pip = col.pips[j]
        if not pip then
            pip = CreateFrame("Frame", nil, col)
            pip:SetSize(6, 6)
            pip.edge = pip:CreateTexture(nil, "ARTWORK", nil, 1)
            pip.edge:SetAllPoints()
            pip.hole = pip:CreateTexture(nil, "ARTWORK", nil, 2)
            pip.hole:SetPoint("TOPLEFT", 1, -1)
            pip.hole:SetPoint("BOTTOMRIGHT", -1, 1)
            pip.hole:SetColorTexture(0.055, 0.055, 0.065, 1)
            col.pips[j] = pip
        end
        local cls = cell.open and cell.c or ((cell.s and cell.s.c) or classOf(cell.key, cell.s))
        local r, g, b = UI():ClassColor(cls)
        local maybe = cell.s and cell.s.st == "T"
        pip.edge:SetColorTexture(r, g, b, cell.open and 0.6 or (maybe and 0.45 or 1))
        pip.hole:SetShown(cell.open == true)
        pip:ClearAllPoints()
        pip:SetPoint("TOPLEFT", col, "TOPLEFT", ((j - 1) % per) * 8, -22 - floor((j - 1) / per) * 8)
        pip:Show()
    end
    for j = n + 1, #col.pips do col.pips[j]:Hide() end
    col.pipsH = n > 0 and (ceil(n / per) * 8 - 2) or 0
end

-- The Sign-ups view: d.roster = { frame (scroll frame), content, box = { ForEachFrame(fn) } over the bands (each with
-- .cells, the shown plates) }.
local function createRoster(d)
    local sf = UI():CreateScrollFrame(d)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(UP.W, 10)
    sf:SetScrollChild(content)
    local r = { frame = sf, content = content, cols = {}, boxes = {} }
    for i = 1, #COLS do r.cols[i] = UP.newBand(content, COLS[i].key) end
    r.empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    r.empty:SetText("No answers yet: players show here by role as they answer.")
    function r:ForEachGroup(fn)
        for _, col in ipairs(self.cols) do fn(col) end
        for _, bx in ipairs(self.boxes) do if bx:IsShown() then fn(bx) end end
    end
    r.box = { ForEachFrame = function(_, fn) r:ForEachGroup(fn) end }
    function r:SetEmptyText() end
    d.roster = r
    return r
end

-- Lays one band out at y (its plates five a row, the gutter's pips; span 2: two tiles each, two a row, for the
-- requests' Approve / Deny); returns its height.
function UP.layBand(col, cells, y, organizer, first, span)
    span = span or 1
    local per = floor(UP.TILES / span)
    for j, cell in ipairs(cells) do
        local row = col.rows[j] or UP.newCell(col)
        col.rows[j] = row
        local c, rr = ((j - 1) % per) * span, floor((j - 1) / per)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", col, "TOPLEFT", UP.tileX(c), -rr * (UP.TILE_H + UP.TILE_GAP))
        row:SetSize(UP.tileX(c + span) - UP.TILE_GAPX - UP.tileX(c), UP.TILE_H)
        UP.fillCell(row, cell, organizer)
    end
    for j = #cells + 1, #col.rows do
        col.rows[j]:Hide()
        col.rows[j].cdlCell = nil
    end
    UP.fillPips(col, cells)
    col.none:SetShown(#cells == 0)
    local rows = ceil(max(1, #cells) / per)
    local h = max(rows * (UP.TILE_H + UP.TILE_GAP) - UP.TILE_GAP, 22 + col.pipsH)
    col.rule:SetShown(not first)
    col:ClearAllPoints()
    col:SetPoint("TOPLEFT", col:GetParent(), "TOPLEFT", 0, -y)
    col:SetSize(UP.W, h)
    col:Show()
    return h
end

local function refreshRoster(d, v, width)
    local r = d.roster
    local model = rosterModel(v)
    local organizer = RP():CanManageRaid(v)
    UP.W = width
    local y = 0
    local bi = 0
    local function boxBand(m)
        bi = bi + 1
        local bx = r.boxes[bi] or UP.newBand(r.content, nil)
        r.boxes[bi] = bx
        bx.title:SetText(m.req and colorize("ffd100", m.label) or colorize("a8a8ad", m.label))
        bx.count:SetText(m.req and colorize("ffd100", m.n) or grey(m.n))
        bx.wash:SetShown(m.req and true or false)
        local h = UP.layBand(bx, m.cells, y, organizer, y == 0, m.req and 2 or 1)
        -- (only the role bands have pips)
        for _, pip in ipairs(bx.pips) do pip:Hide() end
        y = y + h + UP.BAND_GAP + (m.req and 6 or 0)
    end
    -- requests on top, then the roles, then the players outside them
    for _, m in ipairs(model.boxes) do if m.req then boxBand(m) end end
    local depth = 0
    for i, col in ipairs(r.cols) do
        local m = model.cols[i]
        UI():SetRoleIcon(col.role, m.role)
        col.title:SetText(m.label)
        col.count:SetText(m.count .. (m.more > 0 and grey(" +" .. m.more) or ""))
        local h = UP.layBand(col, m.cells, y, organizer, y == 0)
        y = y + h + UP.BAND_GAP
        depth = max(depth, #m.cells)
    end
    for _, m in ipairs(model.boxes) do if not m.req then boxBand(m) end end
    for i = bi + 1, #r.boxes do r.boxes[i]:Hide() end
    r.content:SetWidth(width)
    r.content:SetHeight(max(1, y - UP.BAND_GAP))
    -- nobody answered and nobody is waited for: one line instead of four empty bands
    local any = depth > 0 or #model.boxes > 0
    for _, col in ipairs(r.cols) do col:SetShown(any) end
    r.empty:SetShown(not any)
    r.empty:ClearAllPoints()
    r.empty:SetPoint("TOP", r.content, "TOP", 0, -40)
    if not any then r.content:SetHeight(80) end
end

---------------------------------------------------------------------------
-- Upcoming: my answer (spec, character, note) and the organizer's raid actions
---------------------------------------------------------------------------

local function mySpecOptions()
    local classFile = classOfChar(myChar(state.selected))
    local out = {}
    for i, spec in ipairs(ns.SPECS[classFile] or {}) do
        out[#out + 1] = { value = i, text = spec.label }
    end
    return out
end

-- The spec shown in my dropdown: my sign-up's, a pick not sent yet, the one the character used last, my BiS list's.
local function mySpec(occId)
    local char = myChar(occId)
    local mine = occId and RP():GetMySignup(occId)
    if state.pendingSpec and occId == state.selected then return state.pendingSpec end
    if mine and mine.sp and RP():GetMySignupCharacter(occId) == char then return mine.sp end
    local last = RP():GetLastSpec(char)
    if last then return last end
    if not isMe(char) then return nil end
    local BiS = ns.BiS
    local label = BiS and BiS.GetSpec and BiS:GetSpec() or ""
    local _, classFile = UnitClass("player")
    for i, spec in ipairs(ns.SPECS[classFile] or {}) do
        if spec.label == label then return i end
    end
    return nil
end

-- My characters that can answer the selected raid (the one my answer is for is always listed).
local function myCharOptions()
    local occ = state.selected
    local cur = myChar(occ)
    local out = {}
    for _, key in ipairs(RP():GetMyCharacters()) do
        if key == cur or (occ and (RP():CanSignUp(occ, key) or RP():CanRequest(occ, key))) then
            local cls = classOfChar(key)
            out[#out + 1] = { value = key, text = shortName(key) .. (cls and (" (" .. (ns.CLASS_NAMES[cls] or cls) .. ")") or "") }
        end
    end
    return out
end

-- Answering with another of my characters: an answer already given moves to that character at once.
local function setChar(key)
    local occ = state.selected
    local mine = occ and RP():GetMySignup(occ)
    if key == myChar(occ) then return end
    if mine then
        local ok, err = RP():SignUp(occ, mine.st, nil, mine.n or false, key)
        if not ok then Print(err or "Could not change the character.") end
        state.pendingChar, state.pendingSpec = nil, nil
    else
        state.pendingChar, state.pendingSpec = key, nil
    end
    PlanUI:Refresh()
end

-- My answer to a raid (occ: default the one on the page; a card answers its own raid).
function PlanUI:Answer(status, occ)
    occ = occ or state.selected
    if not occ then return end
    local onPage = occ == state.selected and state.page == "raid"
    local note = onPage and state.pendingNote or nil
    if onPage and note == nil and upcoming then
        local text = ns.Util.Trim(upcoming.noteBox:GetText() or "")
        local mine = RP():GetMySignup(occ)
        if text ~= ((mine and mine.n) or "") then note = text ~= "" and text or false end
    end
    local ok, err = RP():SignUp(occ, status, mySpec(occ), note, myChar(occ))
    if not ok then
        Print(err or "Could not save your answer.")
        return false
    end
    if occ == state.selected then
        state.pendingSpec, state.pendingNote, state.noteEdited, state.pendingChar = nil, nil, nil, nil
    end
    if status ~= "X" and RP():GetMyRequest(occ) then
        Print("Asked to join: whoever runs this raid will approve or deny it.")
    end
    return true
end

local function setSpec(i)
    local occ = state.selected
    local mine = occ and RP():GetMySignup(occ)
    if mine then
        local ok, err = RP():SignUp(occ, mine.st, i, nil, myChar(occ))
        if not ok then Print(err or "Could not change your spec.") end
    else
        state.pendingSpec = i
        PlanUI:Refresh()
    end
end

local function saveNote(box)
    box:ClearFocus()
    state.noteEdited = nil
    local occ = state.selected
    local text = ns.Util.Trim(box:GetText() or "")
    local mine = occ and RP():GetMySignup(occ)
    if mine then
        if text ~= (mine.n or "") then
            local ok, err = RP():SignUp(occ, mine.st, nil, text ~= "" and text or false, myChar(occ))
            if not ok then Print(err or "Could not save the note.") end
        end
    else
        state.pendingNote = text ~= "" and text or false
    end
end

local function cancelMenu(root)
    local v = state.selected and RP():GetRaid(state.selected)
    if not v then return end
    local function run(fn, ...)
        local ok, err = fn(RP(), ...)
        if not ok then Print(err or "Could not change the raid.") end
    end
    if v.cancelled then
        root:CreateButton("Restore this raid", function() run(RP().EditRaid, v.id, { x = false }) end)
    else
        root:CreateButton(v.weekly and "Cancel this week's raid" or "Cancel this raid", function()
            run(RP().CancelRaid, v.id)
        end)
    end
    -- the whole weekly raid, and deleting, only for who may (a leader of one week cancels that week, nothing more)
    local series = v.weekly and RP():CanManageSeries(v)
    if series then
        root:CreateButton("Stop repeating after this raid", function() run(RP().StopRepeating, v.id) end)
    end
    -- deleting removes the raid for everyone, with its sign-ups and groups (cancelling keeps it listed)
    local one = RP():CanDeleteRaid(v)
    if not one and not series then return end
    root:CreateDivider()
    if v.weekly then
        if one then root:CreateButton("Delete this week's raid...", function() PlanUI:ConfirmDelete(nil) end) end
        if series then
            root:CreateButton("Delete the whole weekly raid...", function() PlanUI:ConfirmDelete("series") end)
        end
    else
        root:CreateButton("Delete raid...", function() PlanUI:ConfirmDelete(nil) end)
    end
end

-- Delete in the menu above: confirm, then delete (scope "series" = every week of a weekly raid).
function PlanUI:ConfirmDelete(scope)
    local v = state.selected and RP():GetRaid(state.selected)
    if not v then return end
    local what
    if scope == "series" then
        what = ("the weekly raid %s and every week of it"):format(raidTitle(v))
    else
        what = ("%s on %s"):format(raidTitle(v), date("%a %d %b %H:%M", v.t))
    end
    ns.Popup:Show("DISASTERZONE_PLAN_DELETE", what, nil, { fn = function()
        local ok, err = RP():DeleteRaid(v.id, scope)
        if not ok then Print(err or "Could not delete the raid.") end
    end })
end

function PlanUI:Confirm(text, fn)
    ns.Popup:Show("DISASTERZONE_PLAN_CONFIRM", text, nil, { fn = fn })
end

---------------------------------------------------------------------------
-- Upcoming: Groups tab (§60): the raid's group layout in the group grid, Invite & sort and Re-sort
---------------------------------------------------------------------------

local STATUS_EXTRA = { T = "Signed up as Tentative", B = "Signed up as Bench" }

local function leadsGroup()
    if not IsInGroup() then return false end
    return (UnitIsGroupLeader("player") or (IsInRaid() and UnitIsGroupAssistant("player"))) and true or false
end

-- The first seat of group g nobody (but `key`) holds, or nil.
local function freeSeat(grp, gs, isMember, g, key)
    local used = {}
    for k, x in pairs(grp) do
        if x == g and k ~= key and isMember(k) and gs[k] then used[gs[k]] = true end
    end
    for s = 1, ns.RaidComp.GROUP_SIZE do
        if not used[s] then return s end
    end
end

-- Moves key to group g (nil = out of the groups) in a layout; dropped onto `target` in group g = the two trade
-- places (seats too); `seat` = dropped onto that empty seat of group g. gs = the seats { [key] = 1..5 }; `shown`
-- (from the grid) = the seats as drawn, pinned first so nobody else shifts. isMember(k) tells which layout entries
-- still count. Returns ok (false: the group is full).
local function moveInLayout(grp, gs, isMember, key, g, target, seat, shown)
    if shown then
        for k in pairs(gs) do gs[k] = nil end
        for k, s in pairs(shown) do
            if grp[k] then gs[k] = s end
        end
    end
    local old, oldSeat = grp[key], gs[key]
    if g == nil then
        grp[key], gs[key] = nil, nil
        return true
    end
    if target and target ~= key and grp[target] == g then
        grp[key], grp[target] = g, old
        gs[key], gs[target] = gs[target], old and oldSeat or nil
        return true
    end
    if old == g then
        if seat then gs[key] = seat end
        return true
    end
    local n = 0
    for k, x in pairs(grp) do
        if x == g and k ~= key and isMember(k) then n = n + 1 end
    end
    if n >= ns.RaidComp.GROUP_SIZE then
        Print("Group %d is full. Drop onto a player there to swap places.", g)
        return false
    end
    grp[key] = g
    gs[key] = seat or freeSeat(grp, gs, isMember, g, key)
    return true
end

-- Every player of group a goes to group b and the other way round.
local function swapGroups(grp, a, b)
    for key, g in pairs(grp) do
        if g == a then grp[key] = b elseif g == b then grp[key] = a end
    end
end

local function selectedRaid()
    return state.selected and RP():GetRaid(state.selected) or nil
end

-- The layout being shown: the saved one (or the starting one) until an organizer changes it.
local function raidDraft(v)
    local dr = state.raidDraft
    if dr and dr.occ == v.id and dr.dirty then return dr end
    local grp, saved, seats = RP():GetLayout(v)
    state.raidDraft = { occ = v.id, grp = grp, gs = seats or {}, saved = saved, dirty = false }
    return state.raidDraft
end

local function raidMembers()
    local v = selectedRaid()
    local out = {}
    if not v then return out end
    local seen = {}
    local signups = RP():GetSignups(v.id)
    local order, total = RP():GetSignupOrder(v.id)
    for _, m in ipairs(RP():GetLayoutMembers(v)) do
        out[#out + 1] = { key = m.key, c = m.c, sp = m.sp, dim = m.st ~= "A",
                          extra = m.guest and "Guest (not in the guild)" or (m.st and STATUS_EXTRA[m.st])
                              or (m.st == nil and "No sign-up" or nil),
                          info = signupLines(signups[m.key], order[m.key], total) }
        seen[m.key] = true
    end
    -- people in my raid who didn't sign up (late joiners, fill-ins) can be placed too
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() or 0 do
            local name, _, _, _, _, classFile = GetRaidRosterInfo(i)
            local key = type(name) == "string" and ns.Util.NormalizeName(name) or nil
            if key and not seen[key] and not (signups[key] and signups[key].st == "X") then
                local sp, c = RP():GetMemberSpec(key)
                out[#out + 1] = { key = key, c = c or classFile, sp = sp, dim = true, extra = "In your raid, no sign-up" }
                seen[key] = true
            end
        end
    end
    return out
end

function PlanUI:GetRaidDraft()
    local v = selectedRaid()
    return v and raidDraft(v) or nil
end

function PlanUI:MoveRaidMember(key, g, target, seat, shown)
    local v = selectedRaid()
    if not v or not RP():CanEditGroups(v) then return false end
    local dr = raidDraft(v)
    local valid = {}
    for _, m in ipairs(raidMembers()) do valid[m.key] = true end
    if not valid[key] then return false end
    local ok = moveInLayout(dr.grp, dr.gs, function(k) return valid[k] end, key, g, target, seat, shown)
    if ok then dr.dirty = true end
    return ok
end

function PlanUI:SwapRaidGroups(a, b)
    local v = selectedRaid()
    if not v or not RP():CanEditGroups(v) then return end
    local dr = raidDraft(v)
    swapGroups(dr.grp, a, b)
    dr.dirty = true
    self:RequestRefresh()
end

function PlanUI:AutoFillRaid()
    local v = selectedRaid()
    if not v or not RP():CanEditGroups(v) then return end
    local accepted = {}
    for _, m in ipairs(RP():GetLayoutMembers(v)) do
        if m.st == "A" then accepted[#accepted + 1] = m end
    end
    local dr = raidDraft(v)
    dr.grp, dr.gs, dr.dirty = ns.RaidComp:AutoFill(accepted, v.sz), {}, true
    self:RefreshUpcoming()
end

-- Back to the starting layout (the teams' layouts adjusted to who accepted).
function PlanUI:ResetRaidLayout()
    local v = selectedRaid()
    if not v or not RP():CanEditGroups(v) then return end
    local dr = raidDraft(v)
    local grp, seats = RP():BuildLayout(v)
    dr.grp, dr.gs, dr.dirty = grp, seats or {}, true
    self:RefreshUpcoming()
end

function PlanUI:UndoRaidLayout()
    state.raidDraft = nil
    self:RefreshUpcoming()
end

function PlanUI:SaveRaidLayout()
    local v = selectedRaid()
    if not v then return false end
    local dr = raidDraft(v)
    local ok, err = RP():SetGroups(v.id, dr.grp, dr.gs)
    if not ok then
        Print(err or "Could not save the groups.")
        return false
    end
    dr.dirty, dr.saved = false, true
    ns.RaidInvite:UpdatePlan(v.id, dr.grp)
    self:RefreshUpcoming()
    return true
end

-- Invite & sort: an organizer's unsaved layout is saved first (so the other officers see what was used).
function PlanUI:InviteRaid()
    local v = selectedRaid()
    if not v then return false end
    local dr = raidDraft(v)
    if not next(dr.grp) then
        Print("Nobody is in a group yet. Place players in groups first (or use Auto-fill).")
        return false
    end
    if RP():CanEditGroups(v) and (dr.dirty or not dr.saved) and not self:SaveRaidLayout() then return false end
    -- the groups are who has a spot: only they are invited; who accepted without a group is named
    local ok, err = ns.RaidInvite:Start(v.id, dr.grp, raidTitle(v))
    if not ok then
        Print(err or "Could not invite.")
    else
        local left = {}
        for _, m in ipairs(RP():GetLayoutMembers(v)) do
            if m.st == "A" and not dr.grp[m.key] then left[#left + 1] = shortName(m.key) end
        end
        table.sort(left)
        if #left > 0 then
            Print("Not invited, no group: %s. Place them in a group to invite them.", tconcat(left, ", "))
        end
    end
    self:RefreshUpcoming()
    return ok
end

function PlanUI:ResortRaid()
    local v = selectedRaid()
    if not v then return false end
    local dr = raidDraft(v)
    local ok, err = ns.RaidInvite:Resort(v.id, dr.grp, raidTitle(v))
    if not ok then Print(err or "Could not sort the groups.") end
    self:RefreshUpcoming()
    return ok
end

function PlanUI:GetRaidGrid() return upcoming and upcoming.detail.groups.grid end

local function tipButton(b, title, text)
    b:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(title)
        GameTooltip:AddLine(text, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:HookScript("OnLeave", hideTooltip)
end

-- The Groups tab: a bar with the layout's state and its actions (only those that can be taken now), Invite & sort's
-- progress while it runs, then the group grid (all groups side by side) in a scroll frame.
local function createRaidGroups(d)
    local g = CreateFrame("Frame", nil, d)
    d.groups = g

    local bar = CreateFrame("Frame", nil, g)
    bar:SetPoint("TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetHeight(24)
    g.bar = bar
    g.buffs = CreateFrame("Frame", nil, bar)
    g.buffs:SetPoint("LEFT", 0, 0)
    g.buffs:SetSize(1, 22)
    g.autoBtn = UI():CreateSleekButton(bar, "Auto-fill", 70, 22, function() PlanUI:AutoFillRaid() end)
    tipButton(g.autoBtn, "Auto-fill", "A fresh layout of everyone who accepted: tanks, melee groups with a shaman each, "
        .. "casters, healers.")
    g.teamBtn = UI():CreateSleekButton(bar, "From team", 80, 22, function() PlanUI:ResetRaidLayout() end)
    tipButton(g.teamBtn, "From team", "Start again from the team's group layout: players keep their team seat, others "
        .. "who accepted fill the seats of team members who didn't.")
    g.undoBtn = UI():CreateSleekButton(bar, "Undo", 56, 22, function() PlanUI:UndoRaidLayout() end)
    tipButton(g.undoBtn, "Undo", "Back to the layout as it was saved.")
    g.saveBtn = UI():CreateSleekButton(bar, "Save", 56, 22, function() PlanUI:SaveRaidLayout() end)
    tipButton(g.saveBtn, "Save", "Keeps this layout for the raid (until then it follows the sign-ups) and shares it "
        .. "with the other organizers.")
    g.inviteBtn = UI():CreateSleekButton(bar, "Invite & sort", 100, 22, function() PlanUI:InviteRaid() end, "primary")
    tipButton(g.inviteBtn, "Invite & sort", "Invites everyone placed in a group, guests too (an accepted player "
        .. "without a group is not invited), makes the group a raid and moves each player into their group as they "
        .. "join. Players who join later are sorted too, until the raid ends. Missing shows who has not joined and "
        .. "why. Needs the raid leader or an assistant.")
    g.resortBtn = UI():CreateSleekButton(bar, "Re-sort", 70, 22, function() PlanUI:ResortRaid() end)
    tipButton(g.resortBtn, "Re-sort groups", "Moves everyone in your raid to their planned group now, e.g. after late "
        .. "joiners or a change of plan. Players who aren't planned go to groups 6-8.")

    -- while Invite & sort runs: who joined, who is missing, Stop
    local run = CreateFrame("Frame", nil, g)
    run:SetHeight(22)
    g.run = run
    g.runText = textOf(run, "GameFontHighlightSmall", 11)
    g.runText:SetPoint("LEFT", 1, 0)
    g.stopBtn = UI():CreateSleekButton(run, "Stop", 56, 22, function()
        ns.RaidInvite:Stop()
        PlanUI:RefreshUpcoming()
    end)
    g.stopBtn:SetPoint("RIGHT", 0, 0)
    g.missingBtn = UI():CreateSleekMenuButton(run, "Missing", 100, function(root)
        local st = ns.RaidInvite:GetStatus()
        if not st then return end
        local function section(title, list)
            if #list == 0 then return end
            root:CreateTitle(("%s (%d)"):format(title, #list))
            for _, key in ipairs(list) do
                local b = root:CreateButton(shortName(key), function() end)
                if b and b.SetEnabled then b:SetEnabled(false) end
            end
        end
        section("Offline or not found", st.offline)
        section("Declined the invite", st.declined)
        section("Already in a group", st.grouped)
        section("Invited, not joined yet", st.pending)
        section("In the raid, not on the roster", st.unlisted)
        root:CreateDivider()
        root:CreateButton("Invite the missing players again", function() PlanUI:InviteRaid() end)
    end, 22)
    g.missingBtn:SetPoint("RIGHT", g.stopBtn, "LEFT", -6, 0)

    g.empty = textOf(g, "GameFontDisable", 12)
    g.empty:SetJustifyH("CENTER")
    g.empty:SetPoint("TOP", 0, -40)
    g.empty:SetText("Nobody to place yet: the groups fill as players accept.")
    g.scroll = UI():CreateScrollFrame(g)
    g.grid = ns.RaidGroupsUI:CreateGrid(g.scroll, {
        layout = "row",
        getSize = function()
            local v = selectedRaid()
            return v and v.sz or 25
        end,
        getMembers = raidMembers,
        getGroups = function()
            local v = selectedRaid()
            return v and raidDraft(v).grp or {}
        end,
        getSeats = function()
            local v = selectedRaid()
            return v and raidDraft(v).gs or {}
        end,
        isEditable = function()
            local v = selectedRaid()
            return v ~= nil and RP():CanEditGroups(v)
        end,
        onDrop = function(key, grp, target, seat, shown)
            PlanUI:MoveRaidMember(key, grp, target, seat, shown)
            PlanUI:RequestRefresh()
        end,
        onSwapGroups = function(a, b) PlanUI:SwapRaidGroups(a, b) end,
        onMenu = function(root, key)
            local v = selectedRaid()
            if not v then return end
            root:CreateTitle(shortName(key))
            for grpN = 1, ns.RaidComp:GroupCount(v.sz) do
                root:CreateButton("Move to group " .. grpN, function()
                    PlanUI:MoveRaidMember(key, grpN)
                    PlanUI:RefreshUpcoming()
                end)
            end
            root:CreateButton("Take out of the groups", function()
                PlanUI:MoveRaidMember(key, nil)
                PlanUI:RefreshUpcoming()
            end)
        end,
        -- the Teams look: players as plates, empty seats as wells, the raid comp's open slots waiting in them
        quiet = true,
        isMe = isMe,
        getGhosts = function(byGroup, n)
            local v = selectedRaid()
            local open = v and v.t >= Now() - 6 * 3600 and RP():GetRaidOpenSlots(v) or nil
            if not (open and open.slots and #open.slots > 0) then return nil end
            return ns.RaidComp:PlaceOpen(byGroup, open.slots, n)
        end,
        ghostTooltip = function(seat, slot)
            local v = selectedRaid()
            if not v then return end
            local open = RP():GetRaidOpenSlots(v)
            seat.cdlCell = { open = true, c = slot.c, sp = slot.sp, name = slot.name, occ = v.id,
                             team = open and open.teamName }
            PlanUI:OpenSlotTooltip(seat)
        end,
        poolLabel = "Not in a group",
        poolTip = { "Not in a group", "Accepted, but in none of the groups: Invite & sort leaves them out. Drag them "
            .. "into a group." },
        stripParent = g.buffs,
        stripRoom = function() return g.stripRoom end,
        buffStates = function(placed)
            local v = selectedRaid()
            return v and RP():GetRaidBuffStates(v, placed) or ns.RaidComp:BuffStates(placed, {})
        end,
    })
    g.scroll:SetScrollChild(g.grid.frame)
end

local function refreshGroups(v)
    local d = upcoming.detail
    local g = d.groups
    local organizer = RP():CanEditGroups(v)
    local dr = raidDraft(v)
    local lead = leadsGroup()
    local dirty = dr.dirty and true or false
    local canInvite = (organizer or lead) and not v.cancelled
    local placed, total = 0, 0
    for _, m in ipairs(raidMembers()) do
        total = total + 1
        if dr.grp[m.key] then placed = placed + 1 end
    end
    local st = ns.RaidInvite:IsActive(v.id) and ns.RaidInvite:GetStatus() or nil
    -- nobody to place yet: one line instead of empty groups
    local none = total == 0 and not st
    g.empty:SetShown(none)
    g.scroll:SetShown(not none)

    -- only the actions that can be taken now; one gold button: Save while there are changes, else Invite & sort
    g.autoBtn:SetShown(organizer)
    g.teamBtn:SetShown(organizer and v.tm ~= nil and #v.tm > 0)
    g.undoBtn:SetShown(organizer and dirty)
    g.saveBtn:SetShown(organizer and (dirty or not dr.saved))
    g.inviteBtn:SetShown(canInvite)
    g.resortBtn:SetShown(canInvite and IsInRaid() and lead)
    g.saveBtn:SetKind(dirty and "primary" or "secondary")
    g.inviteBtn:SetKind((organizer and dirty) and "secondary" or "primary")
    local prev
    for _, b in ipairs({ g.resortBtn, g.inviteBtn, g.saveBtn, g.undoBtn, g.teamBtn, g.autoBtn }) do
        b:ClearAllPoints()
        if b:IsShown() then
            -- (the raid's actions stand apart from the layout's)
            if prev then b:SetPoint("RIGHT", prev, "LEFT", prev == g.inviteBtn and -12 or -4, 0)
            else b:SetPoint("RIGHT", g.bar, "RIGHT", 0, 0) end
            prev = b
        end
    end
    -- the buffs take the room the actions leave
    local width = (d:GetWidth() or 0) - 2 * PAD
    if width < 300 then width = 770 end
    local used = 0
    for _, b in ipairs({ g.resortBtn, g.inviteBtn, g.saveBtn, g.undoBtn, g.teamBtn, g.autoBtn }) do
        if b:IsShown() then used = used + b:GetWidth() + (b == g.inviteBtn and 12 or 4) end
    end
    g.stripRoom = width - used - 16
    local showBar = not none
    g.bar:SetShown(showBar)

    local missing = st and (#st.offline + #st.declined + #st.grouped + #st.pending + #st.unlisted) or 0
    g.run:SetShown(st ~= nil)
    g.missingBtn:SetShown(missing > 0)
    g.missingBtn:SetText(("Missing (%d)"):format(missing))
    if st then
        local rt = colorize("33ff33", "Inviting: ") .. ("%d/%d in the raid · %d sorted"):format(st.inRaid, st.planned, st.sorted)
        for _, e in ipairs({ { st.offline, "offline" }, { st.declined, "declined" }, { st.grouped, "in another group" },
                             { st.pending, "not joined yet" }, { st.unlisted, "not on the roster" } }) do
            if #e[1] > 0 then rt = rt .. colorize("ff9933", (" · %d %s"):format(#e[1], e[2])) end
        end
        if st.waitCombat then rt = rt .. colorize("ff5555", " · waiting for combat to end") end
        g.runText:SetText(rt)
        g.runText:ClearAllPoints()
        g.runText:SetPoint("LEFT", 1, 0)
        g.runText:SetPoint("RIGHT", missing > 0 and g.missingBtn or g.stopBtn, "LEFT", -12, 0)
    end
    local top = showBar and 32 or 0
    g.run:ClearAllPoints()
    g.run:SetPoint("TOPLEFT", 0, -top)
    g.run:SetPoint("TOPRIGHT", 0, -top)
    if st then top = top + 30 end
    g.scroll:ClearAllPoints()
    g.scroll:SetPoint("TOPLEFT", 0, -top)
    g.scroll:SetPoint("BOTTOMRIGHT", 0, 0)
    g.grid.frame:SetWidth(width)
    g.grid:Refresh()
end

-- A dropdown that reads as text: "Holy" with a small gold chevron (my spec / character in the banner).
-- opts = { options(), selected(), select(value), display(value) -> text (optional), title, tip }
local function linkDropdown(parent, opts)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(18)
    b.fs = textOf(b, "GameFontHighlight", 12)
    b.fs:SetPoint("LEFT", 0, 0)
    b.chev = b:CreateTexture(nil, "ARTWORK")
    b.chev:SetSize(10, 10)
    b.chev:SetTexture(UI().ICON_ATLAS)
    b.chev:SetTexCoord(unpack(UI():IconCoords(UI().ICON.chevron)))
    b.chev:SetVertexColor(1, 0.82, 0)
    b.chev:SetPoint("LEFT", b.fs, "RIGHT", 3, -1)
    function b:Refresh()
        local sel = opts.selected()
        local text
        if opts.display and sel ~= nil then text = opts.display(sel) end
        if not text then
            for _, o in ipairs(opts.options() or {}) do if o.value == sel then text = o.text end end
        end
        self.fs:SetText(text or grey("pick"))
        self:SetWidth(floor((self.fs:GetStringWidth() or 40) + 13 + 0.5))
    end
    function b:OpenMenu()
        UI():ContextMenu(self, function(root)
            for _, o in ipairs(opts.options() or {}) do
                root:CreateRadio(o.text, function(data) return opts.selected() == data end, function(data)
                    opts.select(data)
                    b:Refresh()
                    return MenuResponse and MenuResponse.Close or nil
                end, o.value)
            end
        end)
    end
    b:SetScript("OnClick", function(self) self:OpenMenu() end)
    b:SetScript("OnEnter", function(self)
        self.chev:SetVertexColor(1, 1, 1)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(opts.title)
        GameTooltip:AddLine(opts.tip, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        self.chev:SetVertexColor(1, 0.82, 0)
        hideTooltip()
    end)
    return b
end

local NOTE_W = 150               -- the note field, and the most the note's link shows of it

-- The note's link: "Add a note", or the note (when it fits; else "Your note", the note in its tooltip).
local function paintNoteLink(d)
    local link = d.noteLink
    local note = ns.Util.Trim(upcoming.noteBox:GetText() or "")
    link.note = note ~= "" and note or nil
    if link.note then
        link.fs:SetText('"' .. note .. '"')
        if (link.fs:GetStringWidth() or 0) > NOTE_W then link.fs:SetText("Your note") end
        link.cdlR, link.cdlG, link.cdlB = 0.9, 0.9, 0.9
        link.icon:SetVertexColor(1, 0.82, 0)
    else
        link.fs:SetText("Add a note")
        link.cdlR, link.cdlG, link.cdlB = 0.62, 0.62, 0.62
        link.icon:SetVertexColor(0.62, 0.62, 0.62)
    end
    link.fs:SetTextColor(link.cdlR, link.cdlG, link.cdlB)
    link:SetWidth(floor(16 + (link.fs:GetStringWidth() or 60) + 0.5))
end

-- My spec, character and note under the answers, right to left; the note is its link or, while typing, its field.
local function layoutMine(d)
    local box, link = upcoming.noteBox, d.noteLink
    local editing = box:IsShown()
    link:SetShown(not editing)
    local parts = { d.asLabel, upcoming.specDD }
    if upcoming.charDD:IsShown() then
        parts[#parts + 1] = d.onLabel
        parts[#parts + 1] = upcoming.charDD
    end
    parts[#parts + 1] = editing and box or link
    local x = 0
    for i = #parts, 1, -1 do
        local part = parts[i]
        part:ClearAllPoints()
        part:SetPoint("RIGHT", d.mine, "RIGHT", -x, 0)
        local w = part.GetStringWidth and part:GetStringWidth() or part:GetWidth()
        -- (a label sits close to its value; the note stands apart)
        x = x + (w or 0) + ((part == d.asLabel or part == d.onLabel) and 5 or (i == #parts and 18 or 10))
    end
    d.mine:SetWidth(max(1, x))
end

-- One answer of the banner's switch: its word; mine is lit in the answer's colour (b.chosen; b:Paint()).
function UP.newAnswer(parent, st)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(22)
    b.st = st
    b.fill = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.fill:SetAllPoints()
    UI():AddEdges(b, "BORDER")
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.05)
    b.fs = textOf(b, "GameFontHighlight", 12)
    b.fs:SetJustifyH("CENTER")
    b.fs:SetPoint("CENTER", 0, 0)
    b.fs:SetText(STATUS[st].button)
    b:SetWidth(floor((b.fs:GetStringWidth() or 50) + 26 + 0.5))
    function b:Paint()
        local r, g, bl = hexRGB(STATUS[self.st].color)
        local on = self.chosen
        self.fill:SetShown(on and true or false)
        if on then
            self.fill:SetColorTexture(r * 0.45, g * 0.45, bl * 0.45, 0.85)
            UI():SetEdgeColor(self, r, g, bl, 0.6)
            self.fs:SetTextColor(min(1, r * 0.5 + 0.55), min(1, g * 0.5 + 0.55), min(1, bl * 0.5 + 0.55))
        else
            UI():SetEdgeColor(self, 0, 0, 0, 0)
            local c = self:IsEnabled() and 0.66 or 0.4
            self.fs:SetTextColor(c, c, c)
        end
    end
    b:SetScript("OnClick", function(self) PlanUI:Answer(self.st) end)
    b:SetScript("OnEnter", function(self)
        if self.chosen and self.since then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("Your answer")
            GameTooltip:AddLine("Since " .. self.since, 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", hideTooltip)
    b:Paint()
    return b
end

-- A tab on the banner's foot (the Teams lineup tab's look): the name, a count on the right, a bar along the bottom;
-- the open one lit with a gold top edge. t:SetActive(on), t:SetCount(have, of).
function UP.newPageTab(parent, label, key, tip)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(TABS_H)
    c.key = key
    c.bg = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    c.bg:SetAllPoints()
    c.bg:SetColorTexture(0.125, 0.125, 0.145, 1)
    c.top = c:CreateTexture(nil, "ARTWORK", nil, 3)
    c.top:SetPoint("TOPLEFT", 0, 0)
    c.top:SetPoint("TOPRIGHT", 0, 0)
    c.top:SetHeight(2)
    c.top:SetColorTexture(1, 0.82, 0, 1)
    c.sep = c:CreateTexture(nil, "BORDER")
    c.sep:SetPoint("TOPRIGHT", 0, 0)
    c.sep:SetPoint("BOTTOMRIGHT", 0, 0)
    c.sep:SetWidth(1)
    c.sep:SetColorTexture(1, 1, 1, 0.06)
    c.hl = c:CreateTexture(nil, "HIGHLIGHT")
    c.hl:SetAllPoints()
    c.hl:SetColorTexture(1, 1, 1, 0.04)
    c.name = textOf(c, "GameFontHighlight", 13)
    c.name:SetPoint("LEFT", 14, 0)
    c.name:SetText(label)
    c.count = textOf(c, "GameFontHighlight", 12)
    c.count:SetJustifyH("RIGHT")
    c.count:SetPoint("RIGHT", -16, 0)
    c.fill = c:CreateTexture(nil, "ARTWORK", nil, 2)
    c.fill:SetPoint("BOTTOMLEFT", 0, 0)
    c.fill:SetHeight(2)
    c:SetScript("OnClick", function(self)
        state.detailTab = self.key
        PlanUI:RefreshUpcoming()
    end)
    c:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(label)
        GameTooltip:AddLine(tip, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    c:SetScript("OnLeave", hideTooltip)
    function c:SetActive(on)
        self.active = on and true or false
        self.bg:SetShown(self.active)
        self.top:SetShown(self.active)
        local g = self.active and 1 or 0.66
        self.name:SetTextColor(g, g, g)
        self:Paint()
    end
    function c:SetCount(have, of)
        self.have, self.of = have, of
        self:Paint()
    end
    function c:Paint()
        local have, of = self.have, self.of
        local full = of and of > 0 and have >= of
        if have and of then
            self.count:SetText((full and colorize("8fe39d", have) or (self.active and colorize("ffffff", have)
                or colorize("bdbdbd", have))) .. colorize("808080", "/" .. of))
        else
            self.count:SetText("")
        end
        local w = max(UP.TAB_MIN, floor(14 + (self.name:GetStringWidth() or 60) + 24 + (self.count:GetStringWidth() or 30)
            + 16 + 0.5))
        self:SetWidth(w)
        local share = (have and of and of > 0) and min(1, have / of) or 0
        self.fill:SetShown(share > 0)
        self.fill:SetWidth(max(1, floor(w * share + 0.5)))
        if full then self.fill:SetColorTexture(0.56, 0.89, 0.62, self.active and 1 or 0.5)
        else self.fill:SetColorTexture(1, 0.82, 0, self.active and 1 or 0.35) end
    end
    c:SetActive(false)
    return c
end

-- What I may do to the raid on the page: { leader, edit, cancel, invite } (the banner's ··· menu; Add players is on the
-- Sign-ups tab).
function UP.actions(v)
    local a = { leader = false, edit = false, cancel = false, invite = false }
    if not v then return a end
    local organizer = RP():CanManageRaid(v)
    a.leader = RP():CanAssignLeader() and true or false
    a.edit, a.cancel = organizer and true or false, organizer and true or false
    a.invite = (organizer or RP():CanManageRoster(v)) and true or false
    return a
end

function PlanUI:GetRaidActions()
    return UP.actions(state.selected and RP():GetRaid(state.selected) or nil)
end

-- The banner's ··· menu: Raid leader, Edit, then cancelling / deleting (cancelMenu's entries).
function UP.actionsMenu(owner)
    local v = state.selected and RP():GetRaid(state.selected)
    if not v then return end
    local a = UP.actions(v)
    UI():ContextMenu(owner, function(root)
        if a.leader then
            root:CreateButton(UI():AtlasIconText(UI().ICON.crown, 13) .. "  Raid leader", function() PlanUI:OpenLeader(v.id) end)
        end
        if a.edit then
            root:CreateButton(UI():AtlasIconText(16, 13) .. "  Edit", function() PlanUI:OpenEditor(v.id) end)
        end
        if a.cancel then
            if a.leader or a.edit then root:CreateDivider() end
            cancelMenu(root)
        end
    end)
end

function PlanUI:CreateUpcoming(parent)
    local u = CreateFrame("Frame", nil, parent)
    upcoming = u

    ---------------------------------------------------------------- the board
    local board = CreateFrame("Frame", nil, u)
    board:SetAllPoints(u)
    u.board = board
    -- the filters (which raid, and when), on the first section header's row
    u.whenDD = UI():CreateSleekDropdown(board, 112, function() return WHEN_OPTIONS end,
        function() return state.filterWhen end, function(val)
            state.filterWhen = val
            PlanUI:RefreshUpcoming()
        end)
    u.whenDD:SetPoint("TOPRIGHT", -PAD, 0)
    u.raidDD = UI():CreateSleekDropdown(board, 150, raidFilterOptions, function() return state.filterRaid end,
        function(val)
            state.filterRaid = val
            PlanUI:RefreshUpcoming()
        end)
    u.raidDD:SetPoint("RIGHT", u.whenDD, "LEFT", -6, 0)
    board.scroll = UI():CreateScrollFrame(board)
    board.scroll:SetPoint("TOPLEFT", PAD, -(FILTER_ROW + 6))
    board.scroll:SetPoint("BOTTOMRIGHT", -PAD, 4)
    board.content = CreateFrame("Frame", nil, board.scroll)
    board.content:SetSize(700, 10)
    board.scroll:SetScrollChild(board.content)
    board.cards, board.heads = {}, {}
    -- (the section headers: small grey capitals, the Teams board's)
    board.firstHead = textOf(board, "GameFontNormalSmall", 10)
    board.firstHead:SetTextColor(0.55, 0.55, 0.55)
    board.firstHead:SetPoint("LEFT", board, "TOPLEFT", PAD + 1, -FILTER_ROW / 2)
    board.empty = board:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    board.empty:SetPoint("TOP", 0, -100)
    board.empty:SetJustifyH("CENTER")
    -- the list's old handles (tools and tests): rows = the shown cards, data = the board's rows
    u.list = {
        box = { ForEachFrame = function(_, fn)
            for _, c in ipairs(board.cards) do if c:IsShown() then fn(c) end end
        end },
        GetData = function() return board.rows or {} end,
        SetEmptyText = function(_, text) board.empty:SetText(text or "") end,
    }

    ---------------------------------------------------------------- the raid's page
    local d = CreateFrame("Frame", nil, u)
    d:SetAllPoints(u)
    u.detail = d
    d.empty = d:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    d.empty:SetPoint("TOP", 0, -60)
    d.empty:SetText("Pick a raid.")

    -- the banner (every tab), the Teams banner's look: the raid's loading screen, dark under its facts (left) and my
    -- answer (right), its foot fading into the tabs
    local hero = CreateFrame("Frame", nil, d)
    hero:SetPoint("TOPLEFT", PAD, 0)
    hero:SetPoint("TOPRIGHT", -PAD, 0)
    hero:SetHeight(HERO_H)
    d.hero = hero
    hero.bg = hero:CreateTexture(nil, "BACKGROUND", nil, 1)
    hero.bg:SetAllPoints()
    hero.bg:SetColorTexture(UP.LT_BG[1], UP.LT_BG[2], UP.LT_BG[3], 1)
    hero.art = hero:CreateTexture(nil, "BACKGROUND", nil, 2)
    hero.art:SetAllPoints()
    hero.art:SetVertexColor(0.85, 0.85, 0.85)
    hero.fadeL = hero:CreateTexture(nil, "BACKGROUND", nil, 3)
    hero.fadeL:SetPoint("TOPLEFT", 0, 0)
    hero.fadeL:SetPoint("BOTTOMLEFT", 0, 0)
    hero.fadeL:SetWidth(470)
    gradient(hero.fadeL, "HORIZONTAL", 0.055, 0.055, 0.067, 0.97, 0.3)
    hero.fadeR = hero:CreateTexture(nil, "BACKGROUND", nil, 3)
    hero.fadeR:SetPoint("TOPLEFT", hero.fadeL, "TOPRIGHT", 0, 0)
    hero.fadeR:SetPoint("BOTTOMRIGHT", 0, 0)
    gradient(hero.fadeR, "HORIZONTAL", 0.055, 0.055, 0.067, 0.3, 0.82)
    hero.fadeB = hero:CreateTexture(nil, "BACKGROUND", nil, 4)
    hero.fadeB:SetPoint("BOTTOMLEFT", 0, 0)
    hero.fadeB:SetPoint("BOTTOMRIGHT", 0, 0)
    hero.fadeB:SetHeight(44)
    gradient(hero.fadeB, "VERTICAL", UP.LT_BG[1], UP.LT_BG[2], UP.LT_BG[3], 1, 0)

    -- its top row: back to the board; the raid's actions in one ··· menu (who may run them)
    d.back = CreateFrame("Button", nil, hero)
    d.back:SetSize(80, 14)
    d.back:SetPoint("TOPLEFT", 16, -11)
    d.back.icon = d.back:CreateTexture(nil, "ARTWORK")
    d.back.icon:SetSize(10, 10)
    d.back.icon:SetPoint("LEFT", 0, 0)
    leftChevron(d.back.icon)
    d.back.text = textOf(d.back, "GameFontNormalSmall", 10)
    d.back.text:SetPoint("LEFT", d.back.icon, "RIGHT", 4, 0)
    d.back.text:SetText("ALL RAIDS")
    local function backColor(self, on)
        local r, g, b = 0.65, 0.65, 0.65
        if on then r, g, b = 1, 0.82, 0 end
        self.text:SetTextColor(r, g, b)
        self.icon:SetVertexColor(r, g, b)
    end
    backColor(d.back, false)
    d.back:SetScript("OnEnter", function(self) backColor(self, true) end)
    d.back:SetScript("OnLeave", function(self) backColor(self, false) end)
    d.back:SetScript("OnClick", function() PlanUI:ShowBoard() end)
    d.moreBtn = UI():CreateTipIconButton(hero, 22, UI().ICON.more, "Raid actions", "Raid leader, Edit, Cancel or "
        .. "Delete.", function(self) UP.actionsMenu(self) end)
    function d.moreBtn:OpenMenu() UP.actionsMenu(self) end
    d.moreBtn:SetPoint("TOPRIGHT", -10, -9)

    -- the facts, top to bottom: when (the countdown in gold), the name, where / by / for, the raid's note
    d.kick = textOf(hero, "GameFontNormalSmall", 10)
    d.kick:SetTextColor(0.72, 0.72, 0.72)
    d.kick:SetPoint("TOPLEFT", 16, -31)
    d.title = textOf(hero, "GameFontHighlightLarge", 22)
    d.title:SetPoint("TOPLEFT", d.kick, "BOTTOMLEFT", 0, -6)
    d.sub2 = textOf(hero, "GameFontHighlightSmall", 11)
    d.sub2:SetTextColor(0.66, 0.66, 0.66)
    d.sub2:SetPoint("TOPLEFT", d.title, "BOTTOMLEFT", 0, -7)
    -- the raid's own note (only when it has one): two lines at most, all of it in the tooltip
    local nl = CreateFrame("Frame", nil, hero)
    d.noteLine = nl
    nl:SetPoint("TOPLEFT", d.sub2, "BOTTOMLEFT", 0, -7)
    nl:SetSize(400, 14)
    nl.icon = nl:CreateTexture(nil, "ARTWORK")
    nl.icon:SetSize(11, 11)
    nl.icon:SetPoint("TOPLEFT", 0, 0)
    nl.icon:SetTexture(UI().ICON_ATLAS)
    nl.icon:SetTexCoord(unpack(UI():IconCoords(UI().ICON.notes)))
    nl.icon:SetVertexColor(0.62, 0.62, 0.62)
    nl.fs = nl:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    setSize(nl.fs, 11)
    nl.fs:SetTextColor(0.6, 0.6, 0.6)
    nl.fs:SetJustifyH("LEFT")
    nl.fs:SetPoint("TOPLEFT", nl.icon, "TOPRIGHT", 6, 0)
    nl.fs:SetWordWrap(true)
    nl.fs:SetMaxLines(2)
    nl:EnableMouse(true)
    nl:SetScript("OnEnter", function(self)
        if not self.note then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("The raid's note")
        GameTooltip:AddLine(self.note, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    nl:SetScript("OnLeave", hideTooltip)

    -- my answer, on the right: a kicker ("YOUR ANSWER", or what a request means), the four answers as one switch (mine
    -- lit in its colour), under them my spec, character and note. Who can't answer sees why instead (and their
    -- answer, on a raid that is over).
    d.hint = textOf(hero, "GameFontNormalSmall", 10)
    d.hint:SetJustifyH("RIGHT")
    d.hint:SetPoint("TOPRIGHT", -16, -40)
    local seg = CreateFrame("Frame", nil, hero)
    seg:SetHeight(26)
    seg:SetPoint("TOPRIGHT", -16, -54)
    seg.bg = seg:CreateTexture(nil, "BACKGROUND")
    seg.bg:SetAllPoints()
    seg.bg:SetColorTexture(0, 0, 0, 0.45)
    UI():AddEdges(seg, "BORDER")
    UI():SetEdgeColor(seg, 1, 1, 1, 0.08)
    d.aseg = seg
    u.statusBtns = {}
    local x = 2
    for _, st in ipairs(STATUS_ORDER) do
        local b = UP.newAnswer(seg, st)
        b:SetPoint("LEFT", seg, "LEFT", x, 0)
        x = x + b:GetWidth()
        u.statusBtns[st] = b
    end
    seg:SetWidth(x + 2)
    d.pill = newPill(hero)
    d.pill:SetPoint("TOPRIGHT", -16, -57)
    d.reason = textOf(hero, "GameFontHighlight", 12)
    d.reason:SetJustifyH("RIGHT")

    local mine = CreateFrame("Frame", nil, hero)
    mine:SetHeight(18)
    mine:SetPoint("TOPRIGHT", -16, -88)
    d.mine = mine
    d.asLabel = textOf(mine, "GameFontHighlightSmall", 11)
    d.asLabel:SetTextColor(0.62, 0.62, 0.62)
    d.asLabel:SetText("As")
    u.specDD = linkDropdown(mine, { options = mySpecOptions, selected = function() return mySpec(state.selected) end,
        select = setSpec, title = "Spec", tip = "The spec you come as: it puts you in the right role." })
    d.onLabel = textOf(mine, "GameFontHighlightSmall", 11)
    d.onLabel:SetTextColor(0.62, 0.62, 0.62)
    d.onLabel:SetText("on")
    u.charDD = linkDropdown(mine, { options = myCharOptions, selected = function() return myChar(state.selected) end,
        select = setChar, display = function(key) return colored(key, classOfChar(key)) end, title = "Sign up as",
        tip = "Answer with another of your characters in the guild, whichever one you are logged in on. Your "
            .. "characters count as one player: the last answer is the one that counts." })
    -- the note: a link ("Add a note" / the note); a click turns it into a field (Enter or a click elsewhere keeps
    -- it, Escape drops the change)
    d.noteLink = CreateFrame("Button", nil, mine)
    d.noteLink:SetHeight(18)
    d.noteLink.icon = d.noteLink:CreateTexture(nil, "ARTWORK")
    d.noteLink.icon:SetSize(12, 12)
    d.noteLink.icon:SetPoint("LEFT", 0, 0)
    d.noteLink.icon:SetTexture(UI().ICON_ATLAS)
    d.noteLink.icon:SetTexCoord(unpack(UI():IconCoords(UI().ICON.notes)))
    d.noteLink.fs = textOf(d.noteLink, "GameFontHighlightSmall", 11)
    d.noteLink.fs:SetPoint("LEFT", d.noteLink.icon, "RIGHT", 4, 0)
    u.noteBox = UI():CreateSleekEditBox(mine, NOTE_W, 20, "GameFontHighlightSmall")
    u.noteBox:SetMaxLetters(40)
    u.noteBox:Hide()
    local closing = false
    local function closeNote(keep)
        if closing then return end
        closing = true
        local box = upcoming.noteBox
        if keep then
            saveNote(box)
        else
            -- Escape: back to the note as it was
            state.noteEdited = nil
            local mine = state.selected and RP():GetMySignup(state.selected)
            local keep = state.pendingNote
            if keep == nil then keep = mine and mine.n end
            box:SetText(keep or "")
            box:ClearFocus()
        end
        box:Hide()
        paintNoteLink(d)
        layoutMine(d)
        closing = false
        PlanUI:Refresh()
    end
    u.noteBox:SetScript("OnEnterPressed", function() closeNote(true) end)
    u.noteBox:SetScript("OnEscapePressed", function() closeNote(false) end)
    u.noteBox:HookScript("OnEditFocusLost", function(self) if self:IsShown() then closeNote(true) end end)
    -- A typed note is kept through repaints (a spec pick repaints) until it is saved or another raid is picked.
    u.noteBox:SetScript("OnTextChanged", function(_, userInput) if userInput then state.noteEdited = true end end)
    UI():SetEditPlaceholder(u.noteBox, "e.g. late 20 min")
    d.noteLink:SetScript("OnClick", function()
        local box = upcoming.noteBox
        hideTooltip()
        box:Show()
        layoutMine(d)
        box:SetFocus()
        box:HighlightText()
    end)
    d.noteLink:SetScript("OnEnter", function(self)
        self.fs:SetTextColor(1, 0.82, 0)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Your note")
        if self.note then GameTooltip:AddLine(self.note, 1, 1, 1, true) end
        GameTooltip:AddLine("A short note for the organizers, e.g. \"late 20 min\". Click to "
            .. (self.note and "change" or "write") .. " it.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    d.noteLink:SetScript("OnLeave", function(self)
        self.fs:SetTextColor(self.cdlR or 0.62, self.cdlG or 0.62, self.cdlB or 0.62)
        hideTooltip()
    end)

    -- Sign-ups / Groups / Assignments (Addendum K: the raid's strategy boards, who does what on each boss) as tabs on
    -- the banner's foot, like a team's lineups: the name, how far along it is, a bar along the bottom
    local tabs = CreateFrame("Frame", nil, d)
    tabs:SetHeight(TABS_H)
    tabs:SetPoint("TOPLEFT", PAD, -HERO_H)
    tabs:SetPoint("TOPRIGHT", -PAD, -HERO_H)
    tabs.bg = tabs:CreateTexture(nil, "BACKGROUND")
    tabs.bg:SetAllPoints()
    tabs.bg:SetColorTexture(UP.LT_BG[1], UP.LT_BG[2], UP.LT_BG[3], 1)
    tabs.rule = tabs:CreateTexture(nil, "BORDER")
    tabs.rule:SetPoint("BOTTOMLEFT", 0, 0)
    tabs.rule:SetPoint("BOTTOMRIGHT", 0, 0)
    tabs.rule:SetHeight(1)
    tabs.rule:SetColorTexture(1, 1, 1, 0.08)
    d.tabs = tabs
    d.tabSignups = UP.newPageTab(tabs, "Sign-ups", "signups", "Who answered, by role.")
    d.tabGroups = UP.newPageTab(tabs, "Groups", "groups", "Who goes in which group: who accepted, placed.")
    d.tabAssign = UP.newPageTab(tabs, "Assignments", "assign", "Each boss's strategy and who does what on it: the "
        .. "bosses whose slots are all filled.")

    -- the open tab's tool row (Sign-ups: the counts, Add players; Groups and Assignments have their own)
    local bar = CreateFrame("Frame", nil, d)
    bar:SetHeight(UP.TB_H)
    bar:SetPoint("TOPLEFT", PAD, -UP.TB_Y)
    bar:SetPoint("TOPRIGHT", -PAD, -UP.TB_Y)
    d.rosterBar = bar
    d.counts = textOf(bar, "GameFontHighlightSmall", 11)
    d.counts:SetTextColor(0.55, 0.55, 0.55)
    d.counts:SetPoint("LEFT", 0, 0)
    d.inviteBtn = UI():CreateSleekButton(bar, UI():AtlasIconText(19, 13) .. "  Add players", 110, 22, function()
        if state.selected then PlanUI:OpenInvites(state.selected) end
    end)
    d.inviteBtn:SetPoint("RIGHT", 0, 0)
    tipButton(d.inviteBtn, "Add players", "Guild members outside the raid's teams (on a locked raid they are the only "
        .. "ones besides the teams), and guests: players who are not in the guild, added by name.")

    createRoster(d)
    createRaidGroups(d)
    d.assign = ns.StrategiesUI:CreateRaidAssignments(d)
    return u
end

-- The page's parts top to bottom: the banner and its tabs (the same on every tab), the open tab's tool row, the open
-- tab (Groups and Assignments draw their own tool row at their top).
local function layoutPage(d)
    d.roster.frame:ClearAllPoints()
    d.roster.frame:SetPoint("TOPLEFT", PAD, -UP.BODY_Y)
    d.roster.frame:SetPoint("BOTTOMRIGHT", -PAD, 4)
    for _, f in ipairs({ d.groups, d.assign }) do
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", PAD, -UP.TB_Y)
        f:SetPoint("BOTTOMRIGHT", -PAD, 4)
    end
end

-- The title in the room left of the answers: 22, else 19, else 16 (wrapping to two lines at worst), never cut.
local function fitTitle(fs, text, room)
    fs:SetWordWrap(false)
    fs:SetWidth(0)
    for _, size in ipairs({ 22, 19, 16 }) do
        setSize(fs, size)
        fs:SetText(text)
        if (fs:GetStringWidth() or 0) <= room then return end
    end
    fs:SetWidth(room)
    fs:SetWordWrap(true)
end

-- My answer on the banner: the answers I can give (mine lit), my spec / character / note, or why I can't answer.
local function refreshAnswer(d, v)
    local organizer = RP():CanManageRaid(v)
    local mine = RP():GetMySignup(v.id)
    local open = not v.cancelled and v.t >= Now() - 6 * 3600
    local char = myChar(v.id)
    -- "lock": locked to its teams and invited players, and I'm not one; "level": the character's level is too low;
    -- "blacklist" / "declined": the organizers keep me out (of every raid / of this one)
    local block = RP():GetSignupBlock(v, char)
    -- a locked raid I'm outside of: answering asks to join it (RaidPlan CanRequest); my request lights its answer
    local canAsk = block == "lock" and RP():CanRequest(v, char)
    local request = canAsk and RP():GetMyRequest(v.id)
    local canAnswer = open and (block == nil or canAsk)
    if request and not mine then mine = request end
    d.aseg:SetShown(canAnswer)
    for st, bt in pairs(upcoming.statusBtns) do
        bt:SetShown(canAnswer)
        bt:SetEnabled(canAnswer)
        bt.chosen = (mine and mine.st == st) and true or false
        bt.since = bt.chosen and (mine.rev or mine.at) and shortDay(mine.rev or mine.at) or nil
        bt:Paint()
    end
    d.mine:SetShown(canAnswer)
    -- can't answer: why, and on a raid that is over or closed to me, the answer I had
    local why
    if not canAnswer then
        if v.cancelled then why = grey("This raid was cancelled.")
        elseif not open then why = grey("Sign-ups are closed.")
        else
            local _, sentence = blockWords(v, block, organizer)
            local color = (block == "blacklist" or block == "declined") and "ff5555" or "ff9933"
            why = sentence and colorize(color, sentence) or nil
        end
    end
    local had = not canAnswer and mine and STATUS[mine.st]
    -- the kicker: what a request means, else "YOUR ANSWER" over the answers or the answer I had
    local hint = (canAnswer and request and colorize("ffd100", "REQUEST SENT: A RAID LEADER APPROVES IT"))
        or (canAnswer and canAsk and colorize("ffd100", "LOCKED TO ITS TEAMS: ANSWER TO ASK TO JOIN"))
        or ((canAnswer or had) and "YOUR ANSWER") or ""
    d.hint:SetText(hint)
    d.hint:SetTextColor(0.72, 0.72, 0.72)
    d.pill:SetPillShown(had and true or false)
    if had then
        local kind = (request and not RP():GetMySignup(v.id)) and "R" or mine.st
        local spec = kind ~= "R" and specLabelOf(mine)
        d.pill:Set(kind, PILL_TEXT[kind] .. (spec and ("  ·  " .. spec) or ""))
        d.pill:SetScript("OnClick", nil)
    end
    d.reason:SetText(why or "")
    d.reason:SetShown(why ~= nil)
    d.reason:ClearAllPoints()
    d.reason:SetPoint("TOPRIGHT", d.hero, "TOPRIGHT", -16, had and -88 or -60)
    if not canAnswer then return end

    -- under the answers, right to left: note, character (when I have more than one), spec
    local several = #RP():GetMyCharacters() > 1
    upcoming.charDD:SetShown(several)
    d.onLabel:SetShown(several)
    upcoming.specDD:Refresh()
    if several then upcoming.charDD:Refresh() end
    local box = upcoming.noteBox
    if not box:HasFocus() and not state.noteEdited then
        local note = state.pendingNote
        if note == nil then note = mine and mine.n or "" end
        box:SetText(note or "")
    end
    paintNoteLink(d)
    layoutMine(d)
end

-- The tabs' counts (accepted of the raid's size; placed of who accepted; bosses whose slots are all filled) and
-- places, left to right.
function UP.layoutTabs(d, v)
    local c = counts(v.id)
    d.tabSignups:SetCount(c.A, v.sz or 0)
    local dr = raidDraft(v)
    local placed, total = 0, 0
    for _, m in ipairs(raidMembers()) do
        total = total + 1
        if dr.grp[m.key] then placed = placed + 1 end
    end
    if total > 0 then d.tabGroups:SetCount(placed, total) else d.tabGroups:SetCount(nil, nil) end
    local sum = ns.StrategiesUI.RaidSummary and ns.StrategiesUI:RaidSummary(v)
    if sum and sum.bosses > 0 then d.tabAssign:SetCount(sum.ready, sum.bosses) else d.tabAssign:SetCount(nil, nil) end
    local x = 0
    for _, t in ipairs({ d.tabSignups, d.tabGroups, d.tabAssign }) do
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", d.tabs, "TOPLEFT", x, 0)
        x = x + t:GetWidth()
    end
end

-- Sign-ups' tool row: what the bands don't add up at a glance ("18 accepted · 1 tentative · 4 absent · 2 to answer").
function UP.countsText(v)
    local c = counts(v.id)
    local function n(x) return colorize("e8e8e8", x) end
    local parts = { n(c.A) .. " accepted" }
    if c.T > 0 then parts[#parts + 1] = n(c.T) .. " tentative" end
    if c.B > 0 then parts[#parts + 1] = n(c.B) .. " on the bench" end
    if c.X > 0 then parts[#parts + 1] = n(c.X) .. " absent" end
    local waiting = #noResponse(v, RP():GetSignups(v.id))
    if waiting > 0 then parts[#parts + 1] = n(waiting) .. " to answer" end
    if c.guests > 0 then parts[#parts + 1] = n(c.guests) .. (c.guests == 1 and " guest" or " guests") end
    return tconcat(parts, "   ·   ")
end

local function refreshDetail(v)
    local d = upcoming.detail
    local has = v ~= nil
    local tab = (state.detailTab == "groups" or state.detailTab == "assign") and state.detailTab or "signups"
    for _, region in ipairs({ d.hero, d.tabs }) do region:SetShown(has) end
    d.empty:SetShown(not has)
    d.rosterBar:SetShown(has and tab == "signups")
    d.roster.frame:SetShown(has and tab == "signups")
    d.groups:SetShown(has and tab == "groups")
    d.assign:SetShown(has and tab == "assign")
    d.tabSignups:SetActive(tab == "signups")
    d.tabGroups:SetActive(tab == "groups")
    d.tabAssign:SetActive(tab == "assign")
    -- who runs this raid (the raid planners: GM, raid leaders; and the raid's own leader): the ··· menu, Add players
    local a = UP.actions(v)
    d.moreBtn:SetShown(a.leader or a.edit or a.cancel)
    d.inviteBtn:SetShown(a.invite)
    if not has then return end

    local width = (d:GetWidth() or 0) - 2 * PAD
    if width < 300 then width = 770 end
    UP.W = width
    local file, l, r, t, b = artCoords(v.i, width, HERO_H, 0.95)
    d.hero.art:SetTexture(file)
    d.hero.art:SetTexCoord(l, r, t, b)
    d.hero.art:SetDesaturated(v.cancelled and true or false)
    d.hero.fadeL:SetWidth(floor(width * 0.62))
    d.kick:SetText(UP.kicker(v))
    fitTitle(d.title, RP():GetRaidName(v), width - 16 - UP.ANS_W)
    -- where, how many; who leads it (or made it); who it is for
    local names = instNames(v)
    local inst = RP():GetInstance(v.i)
    local parts = { (names or (inst and inst.name) or "Raid") .. " · " .. (v.sz or 0) .. "-player" }
    if v.rl then parts[#parts + 1] = colored(v.rl) .. " leads" elseif v.by then parts[#parts + 1] = "by " .. shortName(v.by) end
    parts[#parts + 1] = teamNames(v, false, 2)
    if v.weekly then parts[#parts + 1] = "every week" end
    d.sub2:SetText(tconcat(parts, "   ·   "))
    local nl = d.noteLine
    nl.note = (v.no and v.no ~= "") and v.no or nil
    nl:SetShown(nl.note ~= nil)
    if nl.note then
        local w = width - 16 - UP.ANS_W - 10
        nl.fs:SetWidth(w - 17)
        nl.fs:SetText(nl.note)
        nl:SetSize(w, max(14, floor((nl.fs:GetStringHeight() or 13) + 1.5)))
    end
    refreshAnswer(d, v)
    UP.layoutTabs(d, v)
    layoutPage(d)

    if tab == "groups" then
        refreshGroups(v)
        return
    elseif tab == "assign" then
        ns.StrategiesUI:RefreshRaid(v)
        return
    end
    d.counts:SetText(UP.countsText(v))
    refreshRoster(d, v, width)
end

-- The board: section headers and raid cards (the first header shares the filters' row).
local function refreshBoard(rows)
    local board = upcoming.board
    local width = (board:GetWidth() or 0) - 2 * PAD
    if width < 300 then width = 770 end
    board.content:SetWidth(width)
    local y, ci, hi = 0, 0, 0
    board.firstHead:SetText("")
    for _, d in ipairs(rows) do
        if d.header then
            if ci == 0 and hi == 0 then
                board.firstHead:SetText(d.header:upper())
            else
                hi = hi + 1
                local h = board.heads[hi] or textOf(board.content, "GameFontNormalSmall", 10)
                h:SetTextColor(0.55, 0.55, 0.55)
                board.heads[hi] = h
                h:SetText(d.header:upper())
                h:ClearAllPoints()
                h:SetPoint("TOPLEFT", board.content, "TOPLEFT", 1, -y - 8)
                h:Show()
                y = y + SECTION_H
            end
        else
            ci = ci + 1
            local c = board.cards[ci] or newRaidCard(board.content)
            board.cards[ci] = c
            fillRaidCard(c, d.v, width)
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", board.content, "TOPLEFT", 0, -y)
            c:Show()
            y = y + CARD_H + GAP
        end
    end
    for i = ci + 1, #board.cards do
        board.cards[i]:Hide()
        board.cards[i].__cdlData = nil
    end
    for i = hi + 1, #board.heads do board.heads[i]:Hide() end
    board.content:SetHeight(max(1, y - GAP))
    board.empty:SetShown(ci == 0)
end

function PlanUI:RefreshUpcoming()
    if not upcoming or not upcoming:IsVisible() then return end
    local rows = raidRows()
    upcoming.board.rows = rows
    local found = false
    for _, d in ipairs(rows) do
        if d.v and d.v.id == state.selected then found = true end
    end
    if not found then
        -- a raid that left the list (deleted, filtered out): back to the board
        if state.page == "raid" and not (state.selected and RP():GetRaid(state.selected)) then state.page = "board" end
        if state.page ~= "raid" then state.selected = defaultSelection(rows) end
        state.pendingSpec, state.pendingNote, state.noteEdited, state.pendingChar = nil, nil, nil, nil
    end
    if upcoming.raidDD.Refresh then upcoming.raidDD:Refresh() end
    if upcoming.whenDD.Refresh then upcoming.whenDD:Refresh() end
    upcoming.list:SetEmptyText(filtered() and "No raids match the filters."
        or RP():CanOrganize() and "No raids planned yet.\nClick New raid to plan one."
        or "No raids planned yet.\nThe Guild Master and the raid leaders plan raids here.")
    local onPage = state.page == "raid"
    upcoming.board:SetShown(not onPage)
    upcoming.detail:SetShown(onPage)
    if onPage then
        refreshDetail(state.selected and RP():GetRaid(state.selected) or nil)
    else
        refreshBoard(rows)
    end
end

-- Opens a raid's page.
function PlanUI:SelectRaid(occId)
    if occId ~= state.selected then
        state.pendingSpec, state.pendingNote, state.noteEdited, state.pendingChar = nil, nil, nil, nil
        if upcoming then upcoming.noteBox:Hide() end
        -- a raid opened from elsewhere (the Home tab, a link) must not be hidden by the list's filters
        local v = RP():GetRaid(occId)
        if v and filtered() and not passesFilter(v, Now(), weekStart(Now())) then
            state.filterRaid, state.filterWhen = "all", "all"
        end
    end
    state.selected, state.opened = occId, occId
    state.page = occId and "raid" or "board"
    self:RefreshUpcoming()
end

-- Back to the board (the page's "All raids").
function PlanUI:ShowBoard()
    state.page = "board"
    if upcoming then upcoming.noteBox:Hide() end
    self:RefreshUpcoming()
end

-- "board" | "raid": what Upcoming shows.
function PlanUI:GetPage() return state.page or "board" end

-- raid: an instance key or "all"; when: "all" | "today" | "week" | "next" | "later" | "past" (nil keeps it).
function PlanUI:SetFilter(raid, when)
    if raid ~= nil then state.filterRaid = (raid ~= "all" and RP():GetInstance(raid)) and raid or "all" end
    if when ~= nil then
        state.filterWhen = "all"
        for _, opt in ipairs(WHEN_OPTIONS) do
            if opt.value == when then state.filterWhen = when end
        end
    end
    self:RefreshUpcoming()
end

function PlanUI:GetFilter() return state.filterRaid, state.filterWhen end

function PlanUI:GetSelectedRaid() return state.selected end

-- "signups" | "groups" | "assign" (Addendum K: the raid's strategy boards).
function PlanUI:SetDetailTab(key)
    state.detailTab = (key == "groups" or key == "assign") and key or "signups"
    self:RefreshUpcoming()
end

function PlanUI:GetDetailTab() return state.detailTab end

---------------------------------------------------------------------------
-- Teams view (§58-§59): a chip per team (the open one lit, a gold dot on mine), the open team's card (name and size,
-- the players by role, where I play, who changed it last, the raids that invite it), for organizers a tool row (Add
-- members, Auto-fill; "Changed, not saved", Undo and Save once something changed) and the group grid in the raid
-- page's row layout. The open team is a draft (name, members, size, each member's spec, group layout): organizers
-- edit it and Save, everyone else sees it read-only. Unsaved changes are never dropped silently: another team, New
-- team, Copy, another Raids view or closing the window ask Save / Discard / Cancel (TV.guard). One spacing grid with
-- the raid pages: PAD at the sides (770 inside), GAP between blocks, 12 inside the card.
---------------------------------------------------------------------------

local TV = {                -- the Teams view's sizes and helpers (one local: this file is near Lua's 200 locals)
    W = 770,                -- the width inside PAD (the Raids views are 790 wide; GetWidth is 0 before a layout)
    CHIP_H = 22, CARD_H = 104, TOOL_H = 22, BAR_H = 26,
    LT_H = 34, LT_MIN = 150,  -- the lineup tabs on the banner's foot: height, a tab's least width
    TB_H = 26,
    -- the Comp view's bands: the gutter (role, count, pips), five tiles a row after it
    GUT = 104, GUT_W = 96, TILES = 5, TILE_H = 30, TILE_GAP = 4, TILE_GAPX = 6, BAND_GAP = 12,
    LEFT_W = 450,           -- the banner's left side (the name and the line under it); the next raid has the rest              -- the toolbar: Groups | Comp on the left, the view's actions on the right
    BANNER_H = 92,          -- a team on the board
    QUIET = { 0.105, 0.105, 0.12, 0.9 },   -- the panels of the groups and comp columns (no frames)
    LT_BG = { 0.085, 0.085, 0.1 },          -- the lineup tabs' strip, and the banner's foot fading into it
    COL2 = 400,             -- the card's right column (the raids that invite the team): x, and its width 358
    COL2_W = 358,
    NAME_MIN = 140, NAME_MAX = 300,        -- (300: the raid nights' block starts at 326)
    -- the themes a team can pick (their loading screen is its banner); a team without one takes its next raid's
    THEMES = { "kara", "gruul", "mag", "ssc", "tk", "hyjal", "bt", "za", "swp" },
    MAX = 40,               -- members a team holds (RaidPlan's MAX_TEAM_MEMBERS)
    MAX_LINEUPS = 10,       -- lineups a team holds (RaidPlan's Lineup.MAX)
    NEW_NAME = "New team",
    SHORT = { kara = "Kara", gruul = "Gruul", mag = "Mag", ssc = "SSC", tk = "TK", hyjal = "Hyjal", bt = "BT",
              za = "ZA", swp = "Sunwell" },
    -- the empty card's picture: five groups of class circles
    MINI = { { "WARRIOR", "PALADIN", "DRUID", "SHAMAN", "ROGUE" }, { "ROGUE", "DRUID", "SHAMAN", "PALADIN", "WARRIOR" },
             { "WARLOCK", "PRIEST", "SHAMAN", "DRUID", "MAGE" }, { "MAGE", "MAGE", "HUNTER", "HUNTER", "WARLOCK" },
             { "PALADIN", "PRIEST", "SHAMAN", "PRIEST", "DRUID" } },
}

function TV.sameMap(a, b)
    a, b = a or {}, b or {}
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

local function copyMap(m)
    local out = {}
    for k, v in pairs(m or {}) do out[k] = v end
    return out
end

-- Is the key me, or another character of my account (Guild:SameAccount)?
function TV.isMine(key)
    if isMe(key) then return true end
    local G, me = ns.Guild, ns.Util.PlayerKey()
    return (me and G and G.SameAccount and G:SameAccount(me, key)) and true or false
end

-- My character among the members (an array or a set { [key] = true }), or nil.
function TV.myKey(members)
    if members[1] ~= nil then
        for _, key in ipairs(members) do if isMe(key) then return key end end
        for _, key in ipairs(members) do if TV.isMine(key) then return key end end
        return nil
    end
    local found
    for key in pairs(members) do
        if isMe(key) then return key end
        if not found and TV.isMine(key) then found = key end
    end
    return found
end

-- Does the draft differ from team t (its name as typed, roster, and each lineup: id, name, size, specs, groups,
-- seats, comp)?
function TV.differs(dr, t)
    if not t then return true end
    if dr == state.draft then TV.stash() end
    if t.name ~= ns.Util.Trim(teamsView.nameBox:GetText() or "") or dr.th ~= t.theme then return true end
    if not ns.RaidNights:Same(dr.nights, t.nights) or dr.note ~= t.note then return true end
    local set = {}
    for _, key in ipairs(t.members) do set[key] = true end
    if not TV.sameMap(dr.members, set) or #dr.lineups ~= #t.lineups then return true end
    for i, l in ipairs(dr.lineups) do
        local o = t.lineups[i]
        if l.id ~= o.id or l.name ~= o.name or l.sz ~= o.size or not TV.sameMap(l.s, o.specs)
            or not TV.sameMap(l.grp, o.groups) or not TV.sameMap(l.gs, o.seats)
            or not ns.RaidComp:SameComp(l.cp, o.comp) then
            return true
        end
    end
    return false
end

-- The draft's open lineup is worked on in dr.sz / s / grp / gs / cp (what the grid, the comp and the older helpers
-- read and replace): stash puts them back into dr.lineups[dr.li], useLineup(i) opens lineup i.
function TV.stash()
    local dr = state.draft
    local l = dr and dr.lineups and dr.lineups[dr.li]
    if l then l.sz, l.s, l.grp, l.gs, l.cp = dr.sz, dr.s, dr.grp, dr.gs, dr.cp end
end

function TV.useLineup(i, fresh)
    local dr = state.draft
    if not fresh then TV.stash() end
    i = (dr.lineups[i] and i) or 1
    local l = dr.lineups[i]
    dr.li = i
    dr.sz, dr.s, dr.grp, dr.gs, dr.cp, dr.ln = l.sz, l.s, l.grp, l.gs, l.cp, l.id
    state.ln = l.id
end

-- A lineup's name as shown: its own, else "25-man" ("25-man 2" for the second unnamed 25).
function TV.lineupName(dr, i)
    local l = dr.lineups[i]
    if not l then return "" end
    if l.name then return l.name end
    local n = 0
    for j = 1, i do
        local o = dr.lineups[j]
        if not o.name and o.sz == l.sz then n = n + 1 end
    end
    return l.sz .. "-man" .. (n > 1 and (" " .. n) or "")
end

-- The draft's open lineup in the shape RaidPlan reads (ResolveTeam's draft form).
function TV.ref(dr)
    dr = dr or state.draft
    if not dr then return nil end
    return { id = dr.id, ln = dr.ln, lineupName = TV.lineupName(dr, dr.li), members = dr.members, s = dr.s, grp = dr.grp,
             sz = dr.sz, cp = dr.cp }
end

-- Has the draft changed from the saved team? (A new team has: it isn't saved.)
function TV.dirty()
    local dr = state.draft
    if not dr then return false end
    if not dr.id then return true end
    return TV.differs(dr, RP():GetTeam(dr.id))
end

-- Would leaving the draft lose something? (An untouched new team loses nothing.)
function TV.unsaved()
    local dr = state.draft
    if not dr or not teamsView or not RP():CanManageTeams() then return false end
    if not dr.id then
        TV.stash()
        local name = ns.Util.Trim(teamsView.nameBox:GetText() or "")
        return next(dr.members) ~= nil or next(dr.cp or {}) ~= nil or #dr.lineups > 1 or #(dr.nights or {}) > 0
            or dr.note ~= nil
            or (name ~= "" and name ~= TV.NEW_NAME)
    end
    return TV.dirty()
end

-- name, cut to n bytes without splitting a character (team names are at most 32).
function TV.cut(name, n)
    if #name <= n then return name end
    local s = name:sub(1, n)
    local i = #s
    while i > 0 and s:byte(i) >= 128 and s:byte(i) < 192 do i = i - 1 end
    if i > 0 and s:byte(i) >= 192 then
        local b = s:byte(i)
        local need = (b >= 240 and 4) or (b >= 224 and 3) or 2
        if #s - i + 1 < need then s = s:sub(1, i - 1) end
    end
    return (s:gsub("%s+$", ""))
end

-- "Kara A" -> "Kara A 2" (the first number no team has yet).
function TV.copyName(name)
    local taken = {}
    for _, t in ipairs(RP():GetTeams()) do taken[t.name:lower()] = true end
    for n = 2, 99 do
        local suffix = " " .. n
        local out = TV.cut(name, 32 - #suffix) .. suffix
        if not taken[out:lower()] then return out end
    end
    return name
end

-- Opens team `id` as the draft (nil: an empty new team with one 25-player lineup); `copy` (a team) makes a new draft
-- with its roster and lineups (their groups, specs and target comps, as new lineups). The lineup opened: state.ln's,
-- else the first.
function TV.load(id, copy)
    local t = copy or (id and RP():GetTeam(id))
    local members = {}
    if t then for _, key in ipairs(t.members) do members[key] = true end end
    local lineups = {}
    for i, l in ipairs(t and t.lineups or {}) do
        lineups[i] = { id = not copy and l.id or nil, name = l.name, sz = l.size, s = copyMap(l.specs),
                       grp = copyMap(l.groups), gs = copyMap(l.seats), cp = ns.RaidComp:CopyComp(l.comp) or {} }
    end
    if #lineups == 0 then lineups[1] = { sz = 25, s = {}, grp = {}, gs = {}, cp = {} } end
    state.draft = {
        id = (t and not copy) and t.id or nil,
        name = copy and TV.copyName(copy.name) or (t and t.name or TV.NEW_NAME),
        members = members, lineups = lineups,
        th = t and t.theme or nil,
        nights = ns.RaidNights:Copy(t and t.nights) or {}, note = t and t.note or nil,     -- (1.3.5)
        base = (t and not copy) and t or nil,     -- (the saved version it started from: a newer one replaces it)
    }
    local li = 1
    for i, l in ipairs(lineups) do
        if l.id ~= nil and l.id == state.ln then li = i end
    end
    TV.useLineup(li, true)
    if teamsView then teamsView.nameBox:SetText(state.draft.name) end
end

-- Roster members placed in another lineup of the open one's size: { [key] = that lineup's name }.
function TV.elsewhere(dr)
    local out = {}
    for i, l in ipairs(dr.lineups) do
        if i ~= dr.li and l.sz == dr.sz then
            local n = ns.RaidComp:GroupCount(l.sz)
            for key, g in pairs(l.grp or {}) do
                if dr.members[key] and not out[key] and type(g) == "number" and g >= 1 and g <= n then
                    out[key] = TV.lineupName(dr, i)
                end
            end
        end
    end
    return out
end

-- The roster for the grid: { key, c, sp, auto, source }. Unassigned members who are in another lineup of this size
-- show greyed after the others (later), with that lineup named in their tooltip.
function TV.members()
    local dr = state.draft
    local out = {}
    if not dr then return out end
    local other = TV.elsewhere(dr)
    for key in pairs(dr.members) do
        local sp, c, source = RP():GetMemberSpec(key, { specs = dr.s })
        local m = { key = key, c = c, sp = sp, auto = source ~= "team", source = source }
        if other[key] and not TV.inGroup(dr, key) then
            m.dim, m.later, m.info = true, true, { "In " .. other[key] .. "'s groups." }
        end
        out[#out + 1] = m
    end
    return out
end

-- The open lineup's waitlist for the grid, first in line first (players the draft takes onto the roster left out).
function TV.waitMembers()
    local dr = state.draft
    local out = {}
    if not dr or not dr.id or not dr.ln then return out end
    for _, w in ipairs(RP():GetWaitlist(TV.ref(dr))) do
        out[#out + 1] = { key = w.key, c = w.c, sp = w.sp, auto = w.source ~= "waitlist", source = w.source,
                          prefix = colorize("9e9e9e", w.n .. ". "), noRole = true, n = w.n, waiting = true, at = w.at,
                          info = { ("Waitlist #%d, joined %s."):format(w.n, relDay(w.at)) } }
    end
    return out
end

-- Is the key on the open lineup's waitlist (and not taken onto the draft's roster)? Returns that entry.
function TV.waiting(key)
    for _, w in ipairs(TV.waitMembers()) do
        if w.key == key then return w end
    end
    return nil
end

function TV.count(set)
    local n = 0
    for _ in pairs(set or {}) do n = n + 1 end
    return n
end

-- Is the draft's member in one of its groups (not benched)?
function TV.inGroup(dr, key)
    local g = dr and dr.grp[key]
    return type(g) == "number" and g >= 1 and g <= ns.RaidComp:GroupCount(dr.sz)
end

-- Tanks, healers and damage among the members (a member without a known spec isn't counted).
function TV.roleCounts(list)
    local n = { tank = 0, healer = 0, dps = 0 }
    for _, m in ipairs(list) do
        local role = ns.RaidComp:RoleOf(m.c, m.sp)
        if role == "tank" or role == "healer" then n[role] = n[role] + 1 elseif role then n.dps = n.dps + 1 end
    end
    return n
end

-- "Changed by Caelith, 2 days ago" / "changed by you, today 18:40" (grey, the name in its class colour).
function TV.changed(t, lower)
    if not t or not t.rev then return nil end
    local when = relDay(t.rev)
    if when == "today" or when:find("^in ") then when = "today " .. fmtTime(t.rev)
    elseif Now() - t.rev > 14 * DAY then when = shortDay(t.rev) end
    local who = (not t.by or isMe(t.by)) and grey("you") or colored(t.by)
    return grey(lower and "changed by " or "Changed by ") .. who .. grey(", " .. when)
end

-- Upcoming raids that invite a team, soonest first.
function TV.raids(id)
    local out = {}
    for _, v in ipairs(RP():GetRaids(Now() - 6 * 3600)) do
        if not v.cancelled then
            for _, tid in ipairs(v.tm or {}) do
                if tid == id then out[#out + 1] = v break end
            end
        end
    end
    tsort(out, function(a, b) return a.t < b.t end)
    return out
end

-- "+n more" on the card's raids: every raid that invites the team, one per line.
function TV.raidsTooltip(self)
    local raids = self.raids
    if not raids or #raids == 0 then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Invited to")
    for _, v in ipairs(raids) do
        GameTooltip:AddDoubleLine(RP():GetRaidName(v), shortDay(v.t) .. "  " .. fmtTime(v.t), 1, 1, 1, 0.7, 0.7, 0.7)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click a raid to open it.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

-- Is the member key (or another character of that player) in the set?
function TV.inSet(set, key)
    if set[key] then return true end
    local G = ns.Guild
    for _, m in ipairs(G and G.GetLinkedCharacters and G:GetLinkedCharacters(key) or {}) do
        if set[m] then return true end
    end
    return false
end

-- How many of the team accepted the raid.
-- How many of the players the raid invites through the team (its lineup's, else the roster: GetRaidTeamPlayers)
-- accepted it, and how many it invites that way.
function TV.accepted(v, team)
    local set = {}
    local players = RP():GetRaidTeamPlayers(v, team.id) or team.members
    for _, key in ipairs(players) do set[key] = true end
    local n = 0
    for key, s in pairs(RP():GetSignups(v.id)) do
        if s.st == "A" and not s.guest and TV.inSet(set, key) then n = n + 1 end
    end
    return n, #players
end

-- "Sun 12"
function TV.day(t) return ("%s %d"):format(date("%a", t), tonumber(date("%d", t))) end

-- Add several: the guild members in my raid group (or party) who aren't on the team.
function TV.groupKeys()
    local dr = state.draft
    local G = ns.Guild
    local out, seen = {}, {}
    local function add(name)
        local key = type(name) == "string" and name ~= "" and ns.Util.NormalizeName(name) or nil
        if key and not seen[key] and not dr.members[key] and G and G.IsInGuild and G:IsInGuild(key) then
            seen[key] = true
            out[#out + 1] = key
        end
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() or 0 do add((GetRaidRosterInfo(i))) end
    elseif IsInGroup() then
        add(ns.Util.PlayerKey())
        for i = 1, 4 do
            local name, realm = UnitName("party" .. i)
            if name then add(realm and realm ~= "" and (name .. "-" .. realm) or name) end
        end
    end
    tsort(out)
    return out
end

-- Add several: who accepted the raid but isn't on the team (guild members; a player whose other character is on
-- the team is in already).
function TV.acceptedKeys(v)
    local dr = state.draft
    local G = ns.Guild
    local out = {}
    for key, s in pairs(RP():GetSignups(v.id)) do
        if s.st == "A" and not s.guest and not TV.inSet(dr.members, key) and G and G.IsInGuild and G:IsInGuild(key) then
            out[#out + 1] = key
        end
    end
    tsort(out)
    return out
end

-- The Add members list: Add several on top (only what adds someone), then the guild with each one's role and the
-- other teams they're in (else their rank); offline players greyed, or left out with Online only.
function TV.pickerItems()
    local G = ns.Guild
    local dr = state.draft
    local out = {}
    if not dr or not G then return out end
    local others = {}
    for _, t in ipairs(RP():GetTeams()) do
        if t.id ~= dr.id then
            for _, key in ipairs(t.members) do others[key] = others[key] and (others[key] .. ", " .. t.name) or t.name end
        end
    end
    local acts = {}
    local group = TV.groupKeys()
    if #group > 0 then
        acts[#acts + 1] = { key = "@group", text = IsInRaid() and "Everyone in my raid group" or "Everyone in my party",
                            note = #group .. " new", tip = "Adds the guild members in your group who aren't on the team.",
                            action = function() PlanUI:AddDraftMembers(TV.groupKeys()) end }
    end
    local v, acc = nil, {}
    for _, raid in ipairs(dr.id and TV.raids(dr.id) or {}) do
        acc = TV.acceptedKeys(raid)
        if #acc > 0 then
            v = raid
            break
        end
    end
    if v then
        acts[#acts + 1] = { key = "@accepted", text = "Accepted for " .. TV.day(v.t) .. " " .. RP():GetRaidName(v),
                            note = #acc .. " new", tip = "Adds who accepted this raid of the team but isn't on the team.",
                            action = function() PlanUI:AddDraftMembers(TV.acceptedKeys(v)) end }
    end
    if #acts > 0 then
        out[#out + 1] = { header = "ADD SEVERAL" }
        for _, a in ipairs(acts) do out[#out + 1] = a end
        out[#out + 1] = { header = "GUILD MEMBERS" }
    end
    local list = {}
    for _, key in ipairs(G.GetMembers and G:GetMembers() or {}) do
        local online = G:IsOnline(key)
        if online or not state.pickOnline or dr.members[key] then
            local sp, c, source = RP():GetMemberSpec(key, { specs = dr.s })
            local cls = c or G:GetClass(key)
            list[#list + 1] = { key = key, text = shortName(key), classFile = cls, note = others[key] or G:GetRankName(key),
                                dim = not online, role = ns.RaidComp:RoleOf(cls, sp), roleFaint = source == "bis" }
        end
    end
    tsort(list, function(a, b) return nameLess(a.key, b.key) end)
    for _, e in ipairs(list) do out[#out + 1] = e end
    return out
end

-- The role icon's menu: the spec this player plays in the team (Automatic says what it picked and from where).
function TV.specMenu(root, key)
    local dr = state.draft
    if not dr or not dr.members[key] then return end
    local _, c = RP():GetMemberSpec(key, { specs = dr.s })
    root:CreateTitle(shortName(key))
    local asp, ac, asrc = RP():GetMemberSpec(key)
    local label = asp and ns.RaidComp:SpecLabel(ac, asp)
    local auto = "Automatic"
    if label then
        auto = auto .. colorize("9e9e9e", " · " .. label .. ", from " .. (asrc == "bis" and "the BiS list" or "the last sign-up"))
    end
    root:CreateRadio(auto, function() return dr.s[key] == nil end, function() PlanUI:SetDraftSpec(key, nil) end)
    for i, spec in ipairs(c and ns.SPECS[c] or {}) do
        root:CreateRadio(spec.label, function() return dr.s[key] == i end, function() PlanUI:SetDraftSpec(key, i) end)
    end
end

-- A waitlisted player's menu (organizers): their place (right away, for everyone), onto the roster (into a group or
-- Unassigned: saved with the team), off the waitlist (right away).
function TV.waitMenu(root, key)
    local dr = state.draft
    local w = dr and TV.waiting(key)
    if not w then return end
    local list = TV.waitMembers()
    root:CreateTitle(shortName(key) .. " " .. colorize("9e9e9e", "#" .. w.n .. " on the waitlist"))
    if w.n > 1 then root:CreateButton("Move up", function() RP():MoveWaitlist(dr.id, dr.ln, key, -1) end) end
    if w.n < #list then root:CreateButton("Move down", function() RP():MoveWaitlist(dr.id, dr.ln, key, 1) end) end
    if root.CreateDivider then root:CreateDivider() end
    for g = 1, ns.RaidComp:GroupCount(dr.sz) do
        root:CreateButton("Move to group " .. g, function()
            PlanUI:MoveDraftMember(key, g)
            PlanUI:RefreshTeams()
        end)
    end
    root:CreateButton("Add to the roster (Unassigned)", function()
        PlanUI:MoveDraftMember(key, nil)
        PlanUI:RefreshTeams()
    end)
    if root.CreateDivider then root:CreateDivider() end
    local b = root:CreateButton("|cffff8a8aTake off the waitlist|r", function() RP():LeaveWaitlist(dr.id, dr.ln, key) end)
    if b and b.SetTooltip then
        b:SetTooltip(function(tt)
            tt:AddLine("Take off the waitlist")
            tt:AddLine("Right away, for everyone: no Save needed. They can put themselves on it again.", 1, 1, 1, true)
        end)
    end
end

-- The right-click menu: spec, moves, unassign, off the team (a waitlisted player: TV.waitMenu).
function TV.memberMenu(root, key)
    local dr = state.draft
    if not dr then return end
    if not dr.members[key] then return TV.waitMenu(root, key) end
    local _, c = RP():GetMemberSpec(key, { specs = dr.s })
    root:CreateTitle(shortName(key))
    root:CreateRadio("Spec: automatic", function() return dr.s[key] == nil end, function() PlanUI:SetDraftSpec(key, nil) end)
    for i, spec in ipairs(c and ns.SPECS[c] or {}) do
        root:CreateRadio("Spec: " .. spec.label, function() return dr.s[key] == i end, function() PlanUI:SetDraftSpec(key, i) end)
    end
    if root.CreateDivider then root:CreateDivider() end
    for g = 1, ns.RaidComp:GroupCount(dr.sz) do
        root:CreateButton("Move to group " .. g, function()
            PlanUI:MoveDraftMember(key, g)
            PlanUI:RefreshTeams()
        end)
    end
    if TV.inGroup(dr, key) then
        root:CreateButton("Unassign", function()
            PlanUI:MoveDraftMember(key, nil)
            PlanUI:RefreshTeams()
        end)
    end
    if root.CreateDivider then root:CreateDivider() end
    root:CreateButton("Remove from the team", function() PlanUI:ToggleDraftMember(key) end)
end

-- The draft's name as typed (for the popups).
function TV.draftName()
    local name = ns.Util.Trim(teamsView and teamsView.nameBox:GetText() or "")
    return name ~= "" and name or TV.NEW_NAME
end

-- Runs fn now, or, with unsaved changes, after Save or Discard in a popup (Cancel stays on the team).
function TV.guard(fn)
    if not TV.unsaved() then return fn() end
    ns.Popup:Show("DISASTERZONE_TEAM_UNSAVED", TV.draftName(), nil, { fn = fn })
end

-- Delete, in words from the real data: which raids invite the team and what a raid locked to its teams loses.
function TV.deleteText(team)
    local lines = { ("Delete the team %s?"):format(colorize("ffd100", team.name)) }
    local raids = TV.raids(team.id)
    if #raids == 0 then
        lines[#lines + 1] = "\nNo planned raid invites it."
        return tconcat(lines, "\n")
    end
    local names = {}
    for i = 1, min(2, #raids) do names[i] = TV.day(raids[i].t) .. " " .. RP():GetRaidName(raids[i]) end
    local list = #raids == 1 and names[1] or #raids == 2 and (names[1] .. " and " .. names[2])
        or (names[1] .. ", " .. names[2] .. (" and %d more"):format(#raids - 2))
    -- (the players those raids invite through it: each raid's lineup of the team, or its roster)
    local through = {}
    for _, v in ipairs(raids) do
        for _, key in ipairs(RP():GetRaidTeamPlayers(v, team.id) or {}) do through[key] = true end
    end
    lines[#lines + 1] = ("\n%s invite%s it: its %d players are no longer invited through it."):format(list,
        #raids == 1 and "s" or "", TV.count(through))
    for _, v in ipairs(raids) do
        if v.lk then
            -- who is still in through the raid's other teams and its extra invites
            local keep, others = {}, 0
            for _, id in ipairs(v.tm or {}) do
                if id ~= team.id then
                    local players = RP():GetRaidTeamPlayers(v, id)
                    if players then others = others + 1 end
                    for _, key in ipairs(players or {}) do keep[key] = true end
                end
            end
            for _, key in ipairs(v.inv or {}) do keep[key] = true end
            local lose, answers = {}, 0
            for _, key in ipairs(RP():GetRaidTeamPlayers(v, team.id) or {}) do
                if not keep[key] then lose[key] = true end
            end
            if others == 0 and #(v.inv or {}) == 0 then
                -- (no team left and nobody invited: the raid opens up, GetInvited)
                lines[#lines + 1] = colorize("ffd100", ("%s is locked to this team only: it opens to everyone."):format(
                    TV.day(v.t)))
            elseif next(lose) then
                for key, s in pairs(RP():GetSignups(v.id)) do
                    if not s.guest and TV.inSet(lose, key) then answers = answers + 1 end
                end
                lines[#lines + 1] = colorize("ffd100", answers > 0
                    and ("%s is locked to its teams: %d %s from this team stop counting."):format(TV.day(v.t), answers,
                        answers == 1 and "answer" or "answers")
                    or ("%s is locked to its teams: this team's players can't sign up any more."):format(TV.day(v.t)))
            end
        end
    end
    return tconcat(lines, "\n")
end

function PlanUI:ToggleDraftMember(key)
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return end
    if dr.members[key] then
        -- (off the roster: out of every lineup)
        TV.stash()
        dr.members[key] = nil
        for _, l in ipairs(dr.lineups) do
            l.s[key], l.grp[key], l.gs[key] = nil, nil, nil
        end
    elseif TV.count(dr.members) >= TV.MAX then
        Print("A team holds at most %d members.", TV.MAX)
        return
    else
        dr.members[key] = true
    end
    self:RefreshTeams()
end

-- Add several: adds the keys (up to the team limit). Returns how many joined.
function PlanUI:AddDraftMembers(keys)
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return 0 end
    local n, added = TV.count(dr.members), 0
    for _, key in ipairs(keys or {}) do
        if not dr.members[key] then
            if n >= TV.MAX then
                Print("A team holds at most %d members.", TV.MAX)
                break
            end
            dr.members[key] = true
            n, added = n + 1, added + 1
        end
    end
    self:RefreshTeams()
    return added
end

-- sp = spec index, or nil for automatic (latest sign-up / BiS list).
function PlanUI:SetDraftSpec(key, sp)
    local dr = state.draft
    if not dr or not dr.members[key] or not RP():CanManageTeams() then return end
    dr.s[key] = sp
    self:RefreshTeams()
end

function PlanUI:SetDraftSize(size)
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return end
    size = size == 10 and 10 or 25
    -- a target comp bigger than the new size: offer to start it again from the preset of that size
    local slots = ns.RaidComp:CompSize(dr.cp)
    if slots > size then
        local preset = ns.RaidComp:GetPresets(size)[1]
        ns.Popup:Show("DISASTERZONE_TEAM_COMP_SIZE", ("The target comp has %d slots, more than the team's %d.\n\n"
            .. "Start it again from %s?"):format(slots, size, preset and preset.name or "nothing"), nil, { fn = function()
                dr.cp = preset and preset.cp or {}
                PlanUI:SetDraftSize(size)
            end })
        return false
    end
    dr.sz = size
    local n = ns.RaidComp:GroupCount(dr.sz)
    for key, g in pairs(dr.grp) do
        if g > n then dr.grp[key], dr.gs[key] = nil, nil end
    end
    self:RefreshTeams()
end

-- The grid's drop: move `key` to group g (nil = Unassigned); dropped onto `target` in a group = swap, onto an empty
-- `seat` = that seat. A player from the waitlist joins the roster with it (Save takes them off the waitlist).
function PlanUI:MoveDraftMember(key, g, target, seat, shown)
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return false end
    if not dr.members[key] then
        if not TV.waiting(key) then return false end
        if TV.count(dr.members) >= TV.MAX then
            Print("A team holds at most %d members.", TV.MAX)
            return false
        end
        dr.members[key] = true
    end
    return moveInLayout(dr.grp, dr.gs, function(k) return dr.members[k] end, key, g, target, seat, shown)
end

function PlanUI:SwapDraftGroups(a, b)
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return end
    swapGroups(dr.grp, a, b)
    self:RequestRefresh()
end

-- Auto-fill: the open lineup's groups from the roster, leaving out who is in another lineup of its size.
function PlanUI:AutoFillDraft()
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return end
    local list = {}
    for _, m in ipairs(TV.members()) do
        if not m.later then list[#list + 1] = m end
    end
    dr.grp, dr.gs = ns.RaidComp:AutoFill(list, dr.sz), {}
    self:RefreshTeams()
end

-- ... > Clear groups: everyone in the open lineup to Unassigned (Save keeps it).
function PlanUI:ClearDraftGroups()
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return end
    dr.grp, dr.gs = {}, {}
    self:RefreshTeams()
end

function PlanUI:NewTeam()
    if not RP():CanManageTeams() then return end
    TV.guard(function()
        state.team, state.newTeam, state.board = nil, true, false
        TV.load(nil)
        PlanUI:RefreshTeams()
        if teamsView and teamsView.nameBox:IsVisible() then
            teamsView.nameBox:SetFocus()
            teamsView.nameBox:HighlightText()
        end
    end)
end

-- ... > Copy: a new team with the team's roster and lineups ("Kara A 2"), saved with Save.
function PlanUI:CopyTeam(id)
    local team = id and RP():GetTeam(id)
    if not team or not RP():CanManageTeams() then return end
    TV.guard(function()
        state.team, state.newTeam, state.board = nil, true, false
        TV.load(nil, team)
        PlanUI:RefreshTeams()
        if teamsView and teamsView.nameBox:IsVisible() then
            teamsView.nameBox:SetFocus()
            teamsView.nameBox:HighlightText()
        end
    end)
end

function PlanUI:SaveTeam()
    local dr = state.draft
    if not dr then return false end
    TV.stash()
    local lineups = {}
    for i, l in ipairs(dr.lineups) do
        lineups[i] = { id = l.id, name = l.name, size = l.sz, specs = l.s, groups = l.grp, seats = l.gs, comp = l.cp }
    end
    local ok, res, merged = RP():SaveTeam(dr.id, teamsView.nameBox:GetText(), dr.members, { lineups = lineups,
        theme = dr.th or false, nights = dr.nights or false, note = dr.note or false, base = dr.base })
    if not ok then
        Print(res or "Could not save the team.")
        return false
    end
    if merged then
        Print("Someone else saved this team while you were editing it: your changes were saved on top of theirs.")
    end
    state.team, state.newTeam = res, nil
    -- (the open lineup stays open: a new one got its id now)
    local saved = RP():GetTeam(res)
    local l = saved and saved.lineups[dr.li]
    state.ln = l and l.id or nil
    TV.load(res)
    self:RefreshTeams()
    return true
end

---------------------------------------------------------------------------
-- Teams view: lineups (1.3.2). A team has one roster and any number of 10- and 25-player lineups, each with its own
-- groups, specs, target comp and waitlist; the chips under the card pick the one open. Adding, renaming, resizing,
-- copying, reordering and deleting them are draft changes (Save / Undo), like the groups.
---------------------------------------------------------------------------

function PlanUI:SelectLineup(i)
    local dr = state.draft
    if not dr or not dr.lineups[i] then return end
    TV.useLineup(i)
    if teamsView then teamsView.detail.steps:Hide() end
    self:RefreshTeams()
end

function PlanUI:GetLineupIndex() return state.draft and state.draft.li end

-- A new lineup of `size` (10 or 25), opened.
function PlanUI:AddLineup(size)
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return false end
    if #dr.lineups >= TV.MAX_LINEUPS then
        Print("A team has at most %d lineups.", TV.MAX_LINEUPS)
        return false
    end
    TV.stash()
    dr.lineups[#dr.lineups + 1] = { sz = size == 10 and 10 or 25, s = {}, grp = {}, gs = {}, cp = {} }
    TV.useLineup(#dr.lineups, true)
    self:RefreshTeams()
    return true
end

-- name: text, or nil / "" for the default ("25-man").
function PlanUI:RenameLineup(i, name)
    local dr = state.draft
    local l = dr and dr.lineups[i]
    if not l or not RP():CanManageTeams() then return false end
    name = ns.Util.Trim(tostring(name or ""))
    if #name > 32 or name:find("[%c|]") then
        Print("Lineup names are at most 32 characters.")
        return false
    end
    l.name = name ~= "" and name or nil
    self:RefreshTeams()
    return true
end

-- Copy: a new lineup with the same size, groups, specs and comp, right after it.
function PlanUI:CopyLineup(i)
    local dr = state.draft
    local l = dr and dr.lineups[i]
    if not l or not RP():CanManageTeams() then return false end
    if #dr.lineups >= TV.MAX_LINEUPS then
        Print("A team has at most %d lineups.", TV.MAX_LINEUPS)
        return false
    end
    TV.stash()
    local c = { sz = l.sz, s = copyMap(l.s), grp = copyMap(l.grp), gs = copyMap(l.gs),
                cp = ns.RaidComp:CopyComp(l.cp) or {}, name = TV.cut(TV.lineupName(dr, i), 30) .. " 2" }
    table.insert(dr.lineups, i + 1, c)
    TV.useLineup(i + 1, true)
    self:RefreshTeams()
    return true
end

-- To the front: raids that invite the team use its first lineup of their size unless they pick another.
function PlanUI:MoveLineupFirst(i)
    local dr = state.draft
    if not dr or not dr.lineups[i] or i == 1 or not RP():CanManageTeams() then return false end
    TV.stash()
    local li = dr.li
    table.insert(dr.lineups, 1, table.remove(dr.lineups, i))
    TV.useLineup((li == i and 1) or (li < i and li + 1) or li, true)
    self:RefreshTeams()
    return true
end

-- Delete (a team keeps at least one); asks first when it holds groups, a comp or a waitlist.
function PlanUI:DeleteLineup(i, sure)
    local dr = state.draft
    local l = dr and dr.lineups[i]
    if not l or #dr.lineups < 2 or not RP():CanManageTeams() then return false end
    TV.stash()
    local waiting = (dr.id and l.id) and #RP():GetWaitlist({ id = dr.id, ln = l.id, members = dr.members }) or 0
    -- (1.3.3) the raids that picked it: they count the team's whole roster instead (RaidPlan:GetRaidLineup)
    local using = {}
    if dr.id and l.id then
        for _, v in ipairs(TV.raids(dr.id)) do
            if v.tl and v.tl[dr.id] == l.id then using[#using + 1] = TV.day(v.t) .. " " .. RP():GetRaidName(v) end
        end
    end
    if not sure and (next(l.grp) or next(l.cp) or waiting > 0 or #using > 0) then
        local parts = {}
        if next(l.grp) then parts[#parts + 1] = "its groups" end
        if next(l.cp) then parts[#parts + 1] = "its target comp" end
        if waiting > 0 then parts[#parts + 1] = ("its waitlist (%d)"):format(waiting) end
        local text = #parts > 0 and ("Delete the lineup %s, with %s?"):format(colorize("ffd100", TV.lineupName(dr, i)),
            tconcat(parts, ", ")) or ("Delete the lineup %s?"):format(colorize("ffd100", TV.lineupName(dr, i)))
        if #using > 0 then
            text = text .. "\n\n" .. colorize("ffd100", ("%s use%s it: the whole team is invited there instead."):format(
                #using > 2 and (using[1] .. (" and %d more"):format(#using - 1)) or tconcat(using, " and "),
                #using == 1 and "s" or ""))
        end
        ns.Popup:Show("DISASTERZONE_PLAN_CONFIRM", text .. "\n\nIt goes when you save the team; Undo brings it back "
            .. "until then.", nil, { fn = function() PlanUI:DeleteLineup(i, true) end })
        return false
    end
    local li = dr.li
    table.remove(dr.lineups, i)
    TV.useLineup(min(#dr.lineups, li > i and li - 1 or li), true)
    self:RefreshTeams()
    return true
end

-- A lineup chip's menu (organizers): Rename, Size, Copy, To the front, Delete.
function TV.lineupMenu(owner, i)
    local dr = state.draft
    if not dr or not dr.lineups[i] or not RP():CanManageTeams() then return end
    if dr.li ~= i then PlanUI:SelectLineup(i) end
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(TV.lineupName(dr, i))
        root:CreateButton(UI():AtlasIconText(16, 14, { 0.9, 0.9, 0.9 }) .. "  Rename", function()
            ns.Popup:Show("DISASTERZONE_LINEUP_NAME", nil, nil, { i = i, name = dr.lineups[i].name or "" })
        end)
        local sub = root:CreateButton("Size")
        sub:CreateRadio("10-man", function() return dr.sz == 10 end, function() PlanUI:SetDraftSize(10) end)
        sub:CreateRadio("25-man", function() return dr.sz == 25 end, function() PlanUI:SetDraftSize(25) end)
        if #dr.lineups < TV.MAX_LINEUPS then
            root:CreateButton(UI():AtlasIconText(17, 14, { 0.9, 0.9, 0.9 }) .. "  Copy", function() PlanUI:CopyLineup(i) end)
        end
        if i > 1 then
            local b = root:CreateButton("To the front", function() PlanUI:MoveLineupFirst(i) end)
            if b and b.SetTooltip then
                b:SetTooltip(function(tt)
                    tt:AddLine("To the front")
                    tt:AddLine("Raids that invite the team use its first lineup of their size, unless they pick "
                        .. "another.", 1, 1, 1, true)
                end)
            end
        end
        if #dr.lineups > 1 then
            if root.CreateDivider then root:CreateDivider() end
            root:CreateButton(UI():AtlasIconText(UI().ICON.trash, 14, { 1, 0.55, 0.55 }) .. "  |cffff8a8aDelete|r",
                function() PlanUI:DeleteLineup(i) end)
        end
    end)
end

-- Undo (back to the saved team) or, for a new team, Cancel (the draft is dropped).
function PlanUI:RevertTeam()
    if state.newTeam then
        state.newTeam, state.draft = nil, nil
    else
        TV.load(state.team)
    end
    self:RefreshTeams()
end

-- Drops the unsaved changes (the popups' Discard).
function PlanUI:DiscardDraft()
    if teamsView and teamsView.nameBox:HasFocus() then teamsView.nameBox:ClearFocus() end
    state.newTeam, state.draft = nil, nil
    self:RefreshTeams()
end

function PlanUI:SelectTeam(id)
    TV.closeNights()
    TV.guard(function()
        state.team, state.newTeam, state.board = id, nil, false
        TV.load(id)
        PlanUI:RefreshTeams()
    end)
end

-- ... > Delete: asks with what it changes, then deletes the team for everyone.
function PlanUI:DeleteTeam()
    local team = state.team and RP():GetTeam(state.team)
    if not team or not RP():CanManageTeams() then return end
    ns.Popup:Show("DISASTERZONE_TEAM_DELETE", TV.deleteText(team), nil, { fn = function()
        local ok, err = RP():DeleteTeam(team.id)
        if not ok then
            Print(err or "Could not delete the team.")
            return
        end
        state.team, state.draft, state.newTeam, state.board = nil, nil, nil, true
        PlanUI:RefreshTeams()
    end })
end

-- For RaidsTab (leaving the view) and tests: run fn, or ask first while the team has unsaved changes.
function PlanUI:GuardDraft(fn) return TV.guard(fn) end

function PlanUI:HasUnsavedTeam() return TV.unsaved() end

function PlanUI:GetSelectedTeam() return state.team end

function PlanUI:GetTeamGrid() return teamsView and teamsView.grid end

function PlanUI:GetDraft() return state.draft end

-- For tests: the Delete popup's text for the open team.
function PlanUI:GetTeamDeleteText()
    local team = state.team and RP():GetTeam(state.team)
    return team and TV.deleteText(team) or nil
end

---------------------------------------------------------------------------
-- Teams view: the frames
---------------------------------------------------------------------------

TV.ANSWER = { A = { "8fe39d", "Interface\\RaidFrame\\ReadyCheck-Ready" },
                      T = { "ffd100", "Interface\\RaidFrame\\ReadyCheck-Waiting" }, B = { "99bbff" },
                      X = { "ff5555", "Interface\\RaidFrame\\ReadyCheck-NotReady" }, R = { "ffd100" } }

-- The card's left column, stacked: line 1 (the name), line 2 (the roster), line 3 (me, who changed it). Rows that
-- hold nothing fold away; the card grows if a row is added.
function TV.layoutCard()
    local card = teamsView.card
    local y, last = 30, 0
    for _, row in ipairs(card.rows) do
        if row:IsShown() then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -y)
            last = y + row:GetHeight()
            y = last + (row.gapBelow or 4)
        end
    end
    card:SetHeight(max(TV.CARD_H, last + 10))
end

-- The name field grows with the name (140-250 px); a name too long for that drops to a smaller font, never cut.
function TV.fitName()
    local nb = teamsView.nameBox
    local m = nb.measure
    local text = nb:GetText() or ""
    local inset = nb:HasFocus() and 10 or 24
    for _, size in ipairs({ 20, 17, 14 }) do
        setSize(m, size)
        m:SetText(text)
        local w = (m:GetStringWidth() or 0) + 6 + inset + 2
        if w <= TV.NAME_MAX or size == 14 then
            local path, _, flags = nb:GetFont()
            if path and nb.fontSize ~= size then
                nb:SetFont(path, size, flags)
                nb.fontSize = size
            end
            nb:SetWidth(floor(min(TV.NAME_MAX, max(TV.NAME_MIN, w)) + 0.5))
            return
        end
    end
end

function PlanUI:CreateTeams(parent)
    local t = CreateFrame("Frame", nil, parent)
    teamsView = t
    -- everything of a team (hidden while there is none)
    local d = CreateFrame("Frame", nil, t)
    d:SetAllPoints()
    t.detail = d

    -- the team's banner: its theme's loading screen across it, dark under the name (left) and the next raid (right),
    -- its foot fading into the lineup tabs
    local card = CreateFrame("Frame", nil, d)
    card:SetSize(TV.W, TV.CARD_H)
    t.card = card
    card.bg = card:CreateTexture(nil, "BACKGROUND", nil, 1)
    card.bg:SetAllPoints()
    card.bg:SetColorTexture(TV.LT_BG[1], TV.LT_BG[2], TV.LT_BG[3], 1)
    card.art = card:CreateTexture(nil, "BACKGROUND", nil, 2)
    card.art:SetAllPoints()
    card.art:SetVertexColor(0.85, 0.85, 0.85)
    local split = floor(TV.W * 0.62)
    card.fadeL = card:CreateTexture(nil, "BACKGROUND", nil, 3)
    card.fadeL:SetPoint("TOPLEFT", 0, 0)
    card.fadeL:SetPoint("BOTTOMLEFT", 0, 0)
    card.fadeL:SetWidth(split)
    gradient(card.fadeL, "HORIZONTAL", 0.055, 0.055, 0.067, 0.97, 0.3)
    card.fadeR = card:CreateTexture(nil, "BACKGROUND", nil, 3)
    card.fadeR:SetPoint("TOPLEFT", card.fadeL, "TOPRIGHT", 0, 0)
    card.fadeR:SetPoint("BOTTOMRIGHT", 0, 0)
    gradient(card.fadeR, "HORIZONTAL", 0.055, 0.055, 0.067, 0.3, 0.78)
    card.fadeB = card:CreateTexture(nil, "BACKGROUND", nil, 4)
    card.fadeB:SetPoint("BOTTOMLEFT", 0, 0)
    card.fadeB:SetPoint("BOTTOMRIGHT", 0, 0)
    card.fadeB:SetHeight(44)
    gradient(card.fadeB, "VERTICAL", TV.LT_BG[1], TV.LT_BG[2], TV.LT_BG[3], 1, 0)

    -- the way back to the board
    local back = CreateFrame("Button", nil, card)
    back:SetSize(80, 14)
    back:SetPoint("TOPLEFT", 16, -11)
    back.icon = back:CreateTexture(nil, "ARTWORK")
    back.icon:SetSize(10, 10)
    back.icon:SetPoint("LEFT", 0, 0)
    leftChevron(back.icon)
    back.icon:SetVertexColor(0.65, 0.65, 0.65)
    back.fs = textOf(back, "GameFontNormalSmall", 10)
    back.fs:SetPoint("LEFT", back.icon, "RIGHT", 4, 0)
    back.fs:SetText("ALL TEAMS")
    back.fs:SetTextColor(0.65, 0.65, 0.65)
    back:SetScript("OnEnter", function(self)
        self.fs:SetTextColor(1, 0.82, 0)
        self.icon:SetVertexColor(1, 0.82, 0)
    end)
    back:SetScript("OnLeave", function(self)
        self.fs:SetTextColor(0.65, 0.65, 0.65)
        self.icon:SetVertexColor(0.65, 0.65, 0.65)
    end)
    back:SetScript("OnClick", function() PlanUI:ShowTeamBoard() end)
    d.back = back

    local colW = TV.LEFT_W
    local l1, l2 = CreateFrame("Frame", nil, card), CreateFrame("Frame", nil, card)
    l1:SetSize(colW, 26)
    l1.gapBelow = 6
    l2:SetSize(colW, 14)
    card.l1, card.l2 = l1, l2
    card.rows = { l1, l2 }

    -- line 1: the name as plain text; for organizers a field whose frame and pencil only show on hover or while typing
    card.title = textOf(l1, "GameFontHighlightLarge", 20)
    card.title:SetPoint("LEFT", l1, "LEFT", 0, 0)
    t.nameBox = UI():CreateSleekEditBox(l1, TV.NAME_MIN, 28, "GameFontHighlightLarge")
    t.nameBox:SetTextInsets(6, 24, 0, 0)
    t.nameBox:SetMaxLetters(32)
    t.nameBox:SetPoint("LEFT", l1, "LEFT", -6, 0)
    t.nameBox.measure = textOf(l1, "GameFontHighlightLarge", 20)
    t.nameBox.measure:SetPoint("LEFT", l1, "LEFT", 0, 0)
    t.nameBox.measure:Hide()
    t.nameBox.pencil = t.nameBox:CreateTexture(nil, "ARTWORK")
    t.nameBox.pencil:SetSize(12, 12)
    t.nameBox.pencil:SetPoint("RIGHT", -7, 0)
    t.nameBox.pencil:SetTexture(UI().ICON_ATLAS)
    t.nameBox.pencil:SetTexCoord(unpack(UI():IconCoords(16)))
    t.nameBox.pencil:SetVertexColor(0.7, 0.7, 0.7)
    t.nameBox:SetScript("OnTextChanged", function()
        TV.fitName()
        PlanUI:RefreshTeamButtons()
    end)
    t.nameBox:HookScript("OnEditFocusGained", function(self)
        self:SetTextInsets(6, 10, 0, 0)
        TV.fitName()
        TV.paintName()
    end)
    t.nameBox:HookScript("OnEditFocusLost", function(self)
        self:SetTextInsets(6, 24, 0, 0)
        TV.fitName()
        TV.paintName()
    end)
    t.nameBox:HookScript("OnEnter", function(self)
        self.hover = true
        TV.paintName()
    end)
    t.nameBox:HookScript("OnLeave", function(self)
        self.hover = nil
        TV.paintName()
    end)

    -- line 2: the roster · where I play in the open lineup · who changed it last
    card.count = textOf(l2, "GameFontHighlightSmall", 11)
    card.count:SetPoint("LEFT", l2, "LEFT", 0, 0)
    local you = CreateFrame("Button", nil, l2)
    you:SetHeight(14)
    you.dot = you:CreateTexture(nil, "ARTWORK")
    you.dot:SetSize(6, 6)
    you.dot:SetPoint("LEFT", 0, 0)
    you.dot:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    you.dot:SetVertexColor(1, 0.82, 0)
    you.fs = textOf(you, "GameFontHighlightSmall", 11)
    you.fs:SetTextColor(0.91, 0.91, 0.91)
    you.fs:SetPoint("LEFT", you.dot, "RIGHT", 6, 0)
    you:SetScript("OnEnter", function(self)
        if not self.tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        for i, line in ipairs(self.tip) do
            if i == 1 then GameTooltip:AddLine(line) else GameTooltip:AddLine(line, 1, 1, 1, true) end
        end
        GameTooltip:Show()
    end)
    you:SetScript("OnLeave", hideTooltip)
    card.you = you
    card.changed = textOf(l2, "GameFontHighlightSmall", 11)

    -- the team's ... (organizers): Theme, Copy, Clear groups, LF message, Delete
    d.moreBtn = UI():CreateTipIconButton(card, 22, UI().ICON.more, "Team actions",
        "Theme, Copy, Clear groups, LF message or Delete.", function(self) TV.moreMenu(self) end)
    d.moreBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -9)

    -- the right: the next raid that invites the team (a click opens it), "+n more" for the others
    local nx = CreateFrame("Button", nil, card)
    nx:SetSize(TV.COL2_W, 54)
    card.next = nx
    nx.label = textOf(nx, "GameFontNormalSmall", 10)
    nx.label:SetTextColor(0.72, 0.72, 0.72)
    nx.label:SetJustifyH("RIGHT")
    nx.label:SetPoint("TOPRIGHT", nx, "TOPRIGHT", 0, 0)
    nx.label:SetText("NEXT RAID")
    nx.lock = nx:CreateTexture(nil, "ARTWORK")
    nx.lock:SetSize(11, 11)
    nx.lock:SetTexture(UI().ICON_LOCK)
    nx.lock:SetPoint("TOPRIGHT", nx, "TOPRIGHT", 0, -18)
    nx.line = textOf(nx, "GameFontHighlight", 13)
    nx.line:SetJustifyH("RIGHT")
    nx.extra = CreateFrame("Button", nil, nx)
    nx.extra:SetHeight(14)
    nx.extra:SetPoint("TOPRIGHT", nx, "TOPRIGHT", 0, -36)
    nx.extra.fs = textOf(nx.extra, "GameFontHighlightSmall", 11)
    nx.extra.fs:SetTextColor(0.62, 0.62, 0.62)
    nx.extra.fs:SetPoint("RIGHT", 0, 0)
    nx.extra:SetScript("OnEnter", TV.raidsTooltip)
    nx.extra:SetScript("OnLeave", hideTooltip)
    nx.sub = textOf(nx, "GameFontHighlightSmall", 11)
    nx.sub:SetJustifyH("RIGHT")
    nx.icon = nx:CreateTexture(nil, "ARTWORK")
    nx.icon:SetSize(12, 12)
    nx:SetScript("OnEnter", function(self)
        raidRowTooltip(self)
        GameTooltip:AddLine("Its groups start from this team's groups.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    nx:SetScript("OnLeave", hideTooltip)
    nx:SetScript("OnClick", function(self)
        local v = self.__cdlData and self.__cdlData.v
        if not v then return end
        TV.guard(function()
            ns.RaidsUI:SetView("upcoming")
            PlanUI:SelectRaid(v.id)
        end)
    end)
    -- no raid invites it yet (or it isn't saved): what a team is for, in its place
    card.note = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    setSize(card.note, 11)
    card.note:SetWidth(300)
    card.note:SetJustifyH("RIGHT")
    card.note:SetSpacing(3)

    -- the banner's foot: the lineups as tabs (TV.layoutLineupTabs)
    TV.createLineupTabs(d)

    -- the tool row (organizers): Add members and Auto-fill; "Changed, not saved", Undo and Save once something changed
    local tool = CreateFrame("Frame", nil, d)
    tool:SetSize(TV.W, TV.TOOL_H)
    d.tool = tool
    t.picker = UI():CreateSearchDropdown(tool, 200, {
        placeholder = "Add members",
        emptyText = "No matching guild members.",
        panelWidth = 320,
        getItems = TV.pickerItems,
        isChecked = function(key) return state.draft and state.draft.members[key] and true or false end,
        onToggle = function(key) PlanUI:ToggleDraftMember(key) end,
        toggle = { label = "Online only", get = function() return state.pickOnline and true or false end,
                   set = function(on) state.pickOnline = on end },
        footerText = function()
            return colorize("ffffff", TV.count(state.draft and state.draft.members)) .. (" of %d in the team"):format(TV.MAX)
        end,
    })
    -- (its list is a top-level frame like a menu, drawn over the page; the window's scale is taken on when it opens.
    -- A new parent hands a frame its strata: UIParent's MEDIUM put the list behind the window (HIGH), so it seemed
    -- not to open in game. Its own strata again, fixed.)
    local pp = t.picker.panel
    pp:SetParent(UIParent)
    pp:SetFrameStrata("FULLSCREEN_DIALOG")
    if pp.SetFixedFrameStrata then pp:SetFixedFrameStrata(true) end
    local pickerOpen = t.picker.Open
    function t.picker:Open(...)
        self.panel:SetScale((self.frame:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1))
        self.panel:SetFrameStrata("FULLSCREEN_DIALOG")
        self.panel:Raise()
        return pickerOpen(self, ...)
    end
    d.autoBtn = UI():CreateSleekButton(tool, "Auto-fill", 70, 22, function() PlanUI:AutoFillDraft() end)
    tipButton(d.autoBtn, "Auto-fill groups", "A starting layout: tanks, melee groups with a shaman each, casters, "
        .. "healers. Adjust it by dragging, then Save.")
    d.saveBtn = UI():CreateSleekButton(tool, "Save", 56, 22, function() PlanUI:SaveTeam() end, "primary")
    d.revertBtn = UI():CreateSleekButton(tool, "Undo", 56, 22, function() PlanUI:RevertTeam() end)
    d.status = textOf(tool, "GameFontHighlightSmall", 11)
    d.status:SetTextColor(1, 0.6, 0.2)

    -- the toolbar: Groups | Comp on the left (TV.createComp), the open view's actions on the right (d.tool, laid out by
    -- TV.layoutTool)
    d.views = CreateFrame("Frame", nil, d)
    d.views:SetSize(TV.W, TV.TB_H)
    d.views:Hide()

    d.scroll = UI():CreateScrollFrame(d)
    d.buffs = CreateFrame("Frame", nil, d)
    t.grid = ns.RaidGroupsUI:CreateGrid(d.scroll, {
        layout = "row",
        getSize = function() return state.draft and state.draft.sz or 25 end,
        getMembers = TV.members,
        getGroups = function() return state.draft and state.draft.grp or {} end,
        getSeats = function() return state.draft and state.draft.gs or {} end,
        isEditable = function() return RP():CanManageTeams() end,
        onDrop = function(key, g, target, seat, shown)
            PlanUI:MoveDraftMember(key, g, target, seat, shown)
            PlanUI:RequestRefresh()
        end,
        onSwapGroups = function(a, b) PlanUI:SwapDraftGroups(a, b) end,
        onMenu = TV.memberMenu,
        onRoleClick = function(key, btn) UI():ContextMenu(btn, function(root) TV.specMenu(root, key) end) end,
        isMe = TV.isMine,
        -- Unassigned: on the roster, in none of this lineup's groups; the waitlist: not on the roster, waiting for a
        -- spot. Neither counts for the comp, its slots or the raid buffs.
        poolLabel = "Unassigned",
        poolTip = { "Unassigned", "On the roster, but in none of this lineup's groups: they don't count for its comp. "
            .. "Drag them into a group." },
        poolEmpty = function()
            local dr = state.draft
            return (dr and not next(dr.members)) and "Add members with the search above: they land here, then drag "
                .. "them into groups." or "Drop a player here to take them out of the groups."
        end,
        -- (the waitlist is an icon at the end of the lineup tabs: TV.createWaitlist)
        stripParent = d.buffs,
        quiet = true,
        getGhosts = function(byGroup, n) return TV.ghosts(byGroup, n) end,
        ghostTooltip = function(seat, slot) TV.canFillTooltip(seat, slot.c, slot.sp) end,
        stripRoom = function() return d.stripRoom end,
        buffStates = function(placed) return TV.groupStates(placed) end,
    })
    t.grid.frame:SetWidth(TV.W)
    d.scroll:SetScrollChild(t.grid.frame)
    -- the raid buffs of who sits in the groups: in the toolbar, after Groups | Comp (anchored by TV.layoutTool)
    d.buffs:SetParent(d.views)
    d.buffs:SetSize(1, 20)
    -- the target comp: the Groups | Comp tabs, the Comp view
    TV.createComp(t, d)
    -- every team as a banner (the view opens on it)
    TV.createBoard(t)

    -- no teams yet: one card that says what a team is for (organizers: its New team is the only one)
    local e = CreateFrame("Frame", nil, t)
    e:SetSize(490, 227)
    e:SetPoint("TOP", t, "TOP", 0, -70)
    panel(e, CARD_BG, { EDGE[1], EDGE[2], EDGE[3], 0.6 })
    t.empty = e
    for g, classes in ipairs(TV.MINI) do
        local m = CreateFrame("Frame", nil, e)
        m:SetSize(74, 42)
        m:SetPoint("TOPLEFT", e, "TOPLEFT", 44 + (g - 1) * 82, -22)
        panel(m)
        m:SetAlpha(0.6)
        m.title = textOf(m, "GameFontNormalSmall", 10)
        m.title:SetPoint("TOP", m, "TOP", 0, -8)
        m.title:SetText("Group " .. g)
        for i, cls in ipairs(classes) do
            local dot = m:CreateTexture(nil, "ARTWORK")
            dot:SetSize(10, 10)
            dot:SetPoint("BOTTOMLEFT", m, "BOTTOMLEFT", 8 + (i - 1) * 12, 8)
            UI():ClassIcon(dot, cls)
        end
    end
    e.title = textOf(e, "GameFontHighlightLarge", 16)
    e.title:SetJustifyH("CENTER")
    e.title:SetPoint("TOP", e, "TOP", 0, -82)
    e.title:SetText("No teams yet")
    e.body = e:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    setSize(e.body, 12)
    e.body:SetTextColor(0.62, 0.62, 0.62)
    e.body:SetWidth(438)
    e.body:SetJustifyH("CENTER")
    e.body:SetSpacing(3)
    e.body:SetPoint("TOP", e.title, "BOTTOM", 0, -8)
    e.body:SetText("A team is the list of players who raid together: who plays which spec and who goes in which "
        .. "group. Raids can be opened to a team, and the raid's groups then start from the team's layout.")
    e.who = textOf(e, "GameFontHighlight", 12)
    e.who:SetJustifyH("CENTER")
    e.who:SetTextColor(0.85, 0.85, 0.85)
    e.who:SetPoint("TOP", e.body, "BOTTOM", 0, -12)
    e.who:SetText("Teams are made by the Guild Master and the guild council.")
    e.newBtn = UI():CreateSleekButton(e, "New team", 110, 26, function() PlanUI:NewTeam() end, "primary")
    e.newBtn:SetPoint("TOP", e.body, "BOTTOM", 0, -16)

    -- leaving with unsaved changes another way (another tab, the window closed): ask now, Cancel comes back here
    t:SetScript("OnHide", function()
        if t.detail.steps then t.detail.steps:Hide() end
        if t.detail.wl then t.detail.wl:Hide() end
        TV.closeNights()
        if not TV.unsaved() then return end
        ns.Popup:Show("DISASTERZONE_TEAM_UNSAVED", TV.draftName(), nil, { stay = function()
            if ns.MainFrame and ns.MainFrame.Open then ns.MainFrame:Open("raids") end
            if ns.RaidsUI and ns.RaidsUI.SetView then ns.RaidsUI:SetView("teams") end
        end })
    end)
    return t
end

-- The team's ... menu (organizers): Theme; a saved team also Copy, Clear groups (when there are groups), LF message
-- (open slots), Delete.
function TV.moreMenu(owner)
    local dr = state.draft
    if not dr then return end
    local id = dr.id
    UI():ContextMenu(owner, function(root)
        local function tip(b, title, text)
            if b and b.SetTooltip then
                b:SetTooltip(function(tt)
                    tt:AddLine(title)
                    tt:AddLine(text, 1, 1, 1, true)
                end)
            end
        end
        tip(root:CreateButton(UI():AtlasIconText(UI().ICON.eye, 14, { 0.9, 0.9, 0.9 }) .. "  Theme", function()
            C_Timer.After(0, function() UI():ContextMenu(owner, TV.themeMenu) end)
        end), "Theme", "The raid whose loading screen is the team's banner, here and on the board. Saved with the team.")
        tip(root:CreateButton(UI():AtlasIconText(16, 14, { 0.9, 0.9, 0.9 }) .. "  Raid nights", function()
            C_Timer.After(0, function() PlanUI:OpenNightsEditor() end)
        end), "Raid nights", "The nights the team raids and their hours, shown on its banner and to players who "
            .. "want to join. Saved with the team.")
        if not id then return end
        tip(root:CreateButton(UI():AtlasIconText(17, 14, { 0.9, 0.9, 0.9 }) .. "  Copy", function() PlanUI:CopyTeam(id) end),
            "Copy", "A new team with the same roster and lineups (groups, specs, comps). It is saved when you "
            .. "click Save.")
        if next(dr.grp) then
            tip(root:CreateButton(UI():AtlasIconText(9, 14, { 0.9, 0.9, 0.9 }) .. "  Clear groups",
                function() PlanUI:ClearDraftGroups() end),
                "Clear groups", "Everyone in this lineup to Unassigned. Save keeps it, Undo brings the groups back.")
        end
        -- (only while the comp has open slots)
        local lf = RP():GetLFMessage(TV.ref(dr))
        if lf then
            tip(root:CreateButton(UI():AtlasIconText(19, 14, { 0.9, 0.9, 0.9 }) .. "  LF message",
                function() TV.openChat(lf) end),
                "LF message", "Puts a line asking for the open slots in your chat box, with the team's next raid. Pick "
                .. "the channel and press Enter.")
        end
        if root.CreateDivider then root:CreateDivider() end
        root:CreateButton(UI():AtlasIconText(UI().ICON.trash, 14, { 1, 0.55, 0.55 }) .. "  |cffff8a8aDelete|r",
            function() PlanUI:DeleteTeam() end)
    end)
end

-- The first team I'm on, else the first.
function TV.defaultTeam(teams)
    for _, tm in ipairs(teams) do
        if TV.myKey(tm.members) then return tm.id end
    end
    return teams[1] and teams[1].id or nil
end

-- The name field at rest reads as the banner's title: no fill, no frame, no pencil; hovering shows the frame and the
-- pencil, typing the gold edge.
function TV.paintName()
    local nb = teamsView and teamsView.nameBox
    if not nb then return end
    local focus = nb:HasFocus()
    local on = focus or nb.hover
    nb.bg:SetAlpha(on and 1 or 0)
    for _, e in ipairs(nb.edges or {}) do e:SetShown(on and true or false) end
    nb.pencil:SetShown(nb.hover and not focus or false)
end

-- What the banner says of a raid: organizers how many of the team accepted, members their answer (or Answer).
-- Returns text, icon|nil.
function TV.raidStatus(v, team, organizer)
    if organizer then
        local n, of = TV.accepted(v, team)
        return colorize("ffffff", n) .. colorize("c4c4c4", (" of %d accepted"):format(of)), nil
    end
    local kind, block, canAnswer = myState(v)
    local look = TV.ANSWER[kind]
    if look then return colorize(look[1], PILL_TEXT[kind]), look[2] end
    if kind == "N" and canAnswer then return colorize("ffd100", "Answer"), nil end
    return grey(blockWords(v, block, false) or ""), nil
end

-- The banner: its art, the name, the line under it (the roster, me, who changed it), the next raid on the right.
function TV.fillCard(dr, organizer)
    local t = teamsView
    local card = t.card
    local saved = dr.id and RP():GetTeam(dr.id) or nil
    local n = TV.count(dr.members)
    -- the name
    t.nameBox:SetShown(organizer)
    card.title:SetShown(not organizer)
    if organizer then
        TV.fitName()
        TV.paintName()
    else
        card.title:SetText(dr.name)
        setSize(card.title, 20)
        if (card.title:GetStringWidth() or 0) > TV.LEFT_W then setSize(card.title, 16) end
    end
    -- "17 players · You: Group 5 · Holy · changed by Bob, yesterday" (what doesn't fit is left out)
    card.count:SetText(grey(n == 0 and "No players yet" or n == 1 and "1 player" or (n .. " players")))
    local mine = not organizer and TV.myKey(dr.members) or nil
    local waiting = not organizer and not mine and TV.waiting(ns.Util.PlayerKey()) or nil
    local you = card.you
    you:SetShown(mine ~= nil or waiting ~= nil)
    you.tip = nil
    local lineup = #dr.lineups > 1 and (TV.lineupName(dr, dr.li) .. " · ") or ""
    if mine then
        local where = TV.inGroup(dr, mine) and ("Group " .. dr.grp[mine]) or "Unassigned"
        local sp, c, source = RP():GetMemberSpec(mine, { specs = dr.s })
        local label = sp and ns.RaidComp:SpecLabel(c, sp)
        you.fs:SetText("You: " .. lineup .. where .. (label and (" · " .. label) or ""))
        if label then
            you.tip = { "Your spec in this lineup: " .. label,
                        source == "team" and "Set by the team's organizers."
                            or source == "bis" and "From your BiS list: signing up as another spec changes it."
                            or "From your last sign-up: signing up as another spec changes it." }
        end
        if where == "Unassigned" then
            you.tip = you.tip or { "Unassigned" }
            you.tip[#you.tip + 1] = "On the roster, in none of this lineup's groups: you don't count for its comp yet."
        end
    elseif waiting then
        you.fs:SetText("You: " .. lineup .. "#" .. waiting.n .. " on the waitlist")
        you.tip = { "Waitlist", "You're waiting for a spot: not on the roster yet, so not invited to the team's raids." }
    end
    you:SetWidth(floor(6 + 6 + (you.fs:GetStringWidth() or 100) + 0.5))
    you:ClearAllPoints()
    you:SetPoint("LEFT", card.count, "RIGHT", 10, 0)
    local changed = saved and TV.changed(saved, true) or nil
    -- (an organizer's unsaved edits: said here, in orange, instead of who changed it last)
    if organizer and TV.dirty() then changed = colorize("ff9933", dr.id and "changed, not saved" or "new team, not saved") end
    card.changed:ClearAllPoints()
    if you:IsShown() then card.changed:SetPoint("LEFT", you.fs, "RIGHT", 8, 0)
    else card.changed:SetPoint("LEFT", card.count, "RIGHT", 8, 0) end
    card.changed:SetText(changed and (grey("·  ") .. changed) or "")
    local used = (card.count:GetStringWidth() or 0) + (you:IsShown() and (10 + you:GetWidth()) or 0)
    -- (left of the raid nights when the banner shows them: organizers always, else a team with nights)
    local room = (organizer or (dr.nights and #dr.nights > 0)) and (TV.N.X - 36) or TV.LEFT_W
    if used + 8 + (card.changed:GetStringWidth() or 0) > room then card.changed:SetText("") end
    TV.layoutCard()

    -- the right: the next raid, or what a team is for
    local raids = saved and TV.raids(saved.id) or {}
    local v = raids[1]
    local nx = card.next
    local d = t.detail
    d.moreBtn:SetShown(organizer)
    nx:ClearAllPoints()
    nx:SetPoint("TOPRIGHT", card, "TOPRIGHT", d.moreBtn:IsShown() and -40 or -16, -14)
    nx:SetShown(v ~= nil)
    if v then
        nx.__cdlData = { v = v }
        nx.lock:SetShown(RP():IsLocked(v))
        local several = #RP():GetRaidInstances(v) > 1
        local inst = RP():GetInstance(v.i)
        local name = several and instNames(v, true) or (inst and inst.name) or RP():GetRaidName(v)
        nx.line:SetText(colorize("ffd100", TV.day(v.t):upper()) .. "   " .. name)
        nx.line:ClearAllPoints()
        if nx.lock:IsShown() then nx.line:SetPoint("RIGHT", nx.lock, "LEFT", -5, 0)
        else nx.line:SetPoint("TOPRIGHT", nx, "TOPRIGHT", 0, -17) end
        if (nx.line:GetStringWidth() or 0) > TV.COL2_W - 20 and not several and TV.SHORT[v.i] then
            nx.line:SetText(colorize("ffd100", TV.day(v.t):upper()) .. "   " .. TV.SHORT[v.i])
        end
        local text, icon = TV.raidStatus(v, saved, organizer)
        nx.extra.raids = raids
        nx.extra:SetShown(#raids > 1)
        if #raids > 1 then
            nx.extra.fs:SetText(("·  +%d more"):format(#raids - 1))
            nx.extra:SetWidth(floor((nx.extra.fs:GetStringWidth() or 50) + 0.5))
        end
        nx.sub:SetText(text)
        nx.sub:ClearAllPoints()
        if nx.extra:IsShown() then nx.sub:SetPoint("RIGHT", nx.extra, "LEFT", -6, 0)
        else nx.sub:SetPoint("TOPRIGHT", nx, "TOPRIGHT", 0, -37) end
        nx.icon:SetShown(icon ~= nil)
        if icon then
            nx.icon:SetTexture(icon)
            nx.icon:ClearAllPoints()
            nx.icon:SetPoint("RIGHT", nx.sub, "LEFT", -4, 0)
        end
    end
    card.note:SetShown(v == nil)
    if not v then
        if not saved then
            card.note:SetText(colorize("9e9e9e", "Once it's saved, raid leaders can invite it when they plan a raid, "
                .. "and its groups become the raid's starting groups."))
        else
            card.note:SetText(colorize("d0d0d0", "No raid invites this team yet.") .. "\n" .. colorize("9e9e9e",
                "Raid leaders pick it when they plan a raid" .. (organizer and " (New raid › Teams)." or ".")))
        end
        card.note:ClearAllPoints()
        card.note:SetPoint("TOPRIGHT", card, "TOPRIGHT", d.moreBtn:IsShown() and -40 or -16, -16)
    end
    -- the art: the team's theme (else its next raid's)
    local th = TV.themeOf(dr.th, v, dr.id)
    card.th = th
    local file, l, r, tt, b = artCoords(th, TV.W, TV.CARD_H, 0.95)
    card.art:SetTexture(file)
    card.art:SetTexCoord(l, r, tt, b)
    TV.paintHeroNights(dr, organizer)
end

-- A team's theme: its own, else its next raid's first instance, else one picked from its id (so it stays put).
function TV.themeOf(th, v, id)
    if th then return th end
    if v then return RP():GetRaidInstances(v)[1] or v.i end
    local n = 0
    for i = 1, #(id or "") do n = n + id:byte(i) end
    return TV.THEMES[n % #TV.THEMES + 1]
end

-- Theme: the raids, the one picked checked; Automatic = the next raid's. A draft change (Save / Undo).
function TV.themeMenu(root)
    local dr = state.draft
    if not dr then return end
    root:CreateTitle("Team theme")
    local function pick(key)
        dr.th = key
        PlanUI:RefreshTeams()
    end
    local function mark(on) return on and "|cffffd100•|r  " or "    " end
    root:CreateButton(mark(dr.th == nil) .. "Automatic (the next raid)", function() pick(nil) end)
    for _, key in ipairs(TV.THEMES) do
        local inst = RP():GetInstance(key)
        root:CreateButton(mark(dr.th == key) .. (inst and inst.name or key), function() pick(key) end)
    end
end

function PlanUI:RefreshTeamButtons()
    if not teamsView then return end
    local d = teamsView.detail
    local organizer = RP():CanManageTeams()
    local dr = state.draft
    local dirty = organizer and dr ~= nil and TV.dirty()
    local new = dr ~= nil and dr.id == nil
    -- (only while something changed: nothing greyed out)
    d.saveBtn:SetShown(dirty)
    d.revertBtn:SetShown(dirty)
    -- (the banner's line says it: TV.fillCard)
    d.status:SetShown(false)
    d.revertBtn:SetText(new and "Cancel" or "Undo")
    d.revertBtn:SetWidth(new and 64 or 56)
    d.status:SetText(new and "New team, not saved" or "Changed, not saved")
end

function PlanUI:RefreshTeams()
    if not teamsView or not teamsView:IsVisible() then return end
    if ns.RaidGroupsUI:IsCardDragging() then
        TV.deferred = true
        return
    end
    local t, d = teamsView, teamsView.detail
    local teams = RP():GetTeams()
    local organizer = RP():CanManageTeams()
    if not (state.newTeam and organizer) then
        state.newTeam = nil
        local found = false
        for _, tm in ipairs(teams) do if tm.id == state.team then found = true end end
        if not found then state.team = TV.defaultTeam(teams) end
        if not state.draft or state.draft.id ~= state.team then
            TV.load(state.team)
        elseif state.draft.base then
            -- the team changed elsewhere (sync): an untouched draft takes the new version, edits in progress stay
            local saved = RP():GetTeam(state.team)
            if saved and saved.rev ~= state.draft.base.rev and not TV.differs(state.draft, state.draft.base) then
                TV.load(state.team)
            end
        end
    end
    local dr = (state.team or state.newTeam) and state.draft or nil
    if dr then TV.stash() end
    -- the Raids toolbar's New team stands only next to teams: a team saved or deleted here (or synced in) updates it
    -- (asked once per change, so a toolbar that differs can't keep refreshing)
    local rp = ns.RaidsUI and ns.RaidsUI.GetPanel and ns.RaidsUI:GetPanel()
    local want = organizer and #teams > 0
    if rp and rp.newTeamBtn and rp.newTeamBtn:IsShown() ~= want then
        if TV.askedToolbar ~= want then
            TV.askedToolbar = want
            ns.RaidsUI:RequestRefresh()
        end
    else
        TV.askedToolbar = nil
    end
    -- the board (every team as a banner) until a team is opened; no teams: the empty card
    local board = state.board ~= false and not state.newTeam and dr ~= nil
    t.board:SetShown(board)
    d:SetShown(dr ~= nil and not board)
    t.empty:SetShown(dr == nil)
    if not dr then
        d.steps:Hide()
        local e = t.empty
        e.newBtn:SetShown(organizer)
        e.who:SetShown(not organizer)
        local bodyH = e.body:GetStringHeight() or 0
        if bodyH < 20 then bodyH = 51 end
        e:SetHeight(floor(82 + (e.title:GetStringHeight() or 20) + 8 + bodyH
            + (organizer and (16 + 26) or (12 + (e.who:GetStringHeight() or 16))) + 24 + 0.5))
        return
    end
    if board then
        d.steps:Hide()
        d.wl:Hide()
        if t.picker.IsOpen and t.picker:IsOpen() then t.picker:Close() end
        TV.fillBoard(teams)
        return
    end

    -- the waitlist's dropdown follows the open lineup (another one: it closes)
    if d.wl:IsShown() then
        if d.wl.team ~= dr.id or d.wl.ln ~= dr.ln then d.wl:Hide() else TV.fillWaitlist() end
    end
    -- the target comp: who fills which slot (nil without one), the strip's states
    local m = TV.match(dr)
    TV.cur = { match = m }
    TV.states = m and TV.compStates(dr) or nil
    -- Groups | Comp (Comp: organizers always, members once the lineup has a comp)
    local compTab = organizer or m ~= nil
    local tab = self:GetTeamTab()
    if tab == "comp" and not compTab then
        tab = "groups"
        state.teamTab = tab
    end
    d.views:Show()
    d.tabComp:SetShown(compTab)
    d.tabGroups:SetActive(tab == "groups")
    d.tabComp:SetActive(tab == "comp")
    d.tabComp:SetLabel(m and ("Comp  " .. colorize("9e9e9e", m.filled .. "/" .. m.total)) or "Comp")
    TV.layoutSeg()

    -- top to bottom: the banner, the lineup tabs on its foot, the toolbar (Groups | Comp, the view's actions), then
    -- the groups and the bench, or the comp
    TV.fillCard(dr, organizer)
    t.card:ClearAllPoints()
    t.card:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, 0)
    local y = TV.CARD_H
    TV.layoutLineupTabs(dr, organizer, m, y)
    y = y + TV.LT_H + 10
    d.views:ClearAllPoints()
    d.views:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, -y)
    y = y + TV.TB_H + 10
    local groups = tab == "groups"
    d.scroll:SetShown(groups)
    if not groups then
        d.compEmpty:Hide()
        self:RefreshTeamButtons()
        TV.layoutComp(y, organizer, dr, m)
        TV.fillSteps()
        if t.picker.IsOpen and t.picker:IsOpen() then t.picker:Close() end
        return
    end
    d.startBtn:Hide()
    d.compStrip:Hide()
    d.compBar:Hide()
    d.compScroll:Hide()
    d.compEmpty:Hide()
    d.steps:Hide()
    d.tool:SetShown(organizer)
    t.picker.frame:SetShown(organizer)
    d.autoBtn:SetShown(organizer and next(dr.members) ~= nil)
    self:RefreshTeamButtons()
    TV.layoutTool("groups")
    d.scroll:ClearAllPoints()
    d.scroll:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, -y)
    d.scroll:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -PAD, 0)
    t.grid.frame:SetWidth(TV.W)
    t.grid:Refresh()
    t.grid.frame:SetHeight(t.grid:GetContentHeight() + 6)
    if t.picker.IsOpen and t.picker:IsOpen() then t.picker:Refresh(true) end
end

-- The toolbar's right end, right to left: Save and Undo (while something changed), then the view's own actions:
-- Groups: Auto-fill and Add members; Comp: Start from and the raid buffs. "Changed, not saved" sits after the switch.
-- The raid buffs sit after the switch (d.buffs on Groups, d.compStrip on Comp); d.stripRoom = the width left them.
-- While something is unsaved the search field narrows (200 down to 120) so every raid buff still fits at 14 px.
function TV.layoutTool(kind)
    local t, d = teamsView, teamsView.detail
    local tool = d.tool
    tool:ClearAllPoints()
    tool:SetPoint("LEFT", d.views, "LEFT", 0, 0)
    d.status:ClearAllPoints()
    d.status:SetPoint("LEFT", d.seg, "RIGHT", 14, 0)
    local anchor
    local used = 0
    local function place(f, gap, w)
        f:ClearAllPoints()
        if anchor then f:SetPoint("RIGHT", anchor, "LEFT", -gap, 0)
        else f:SetPoint("RIGHT", tool, "RIGHT", 0, 0) end
        anchor = f
        used = used + (anchor and gap or 0) + (w or f:GetWidth() or 0)
    end
    local shown = tool:IsShown()
    if shown and d.saveBtn:IsShown() then
        place(d.saveBtn, 0)
        place(d.revertBtn, 4)
    end
    local left = d.seg:GetWidth() + 16
    if kind == "groups" then
        if shown and d.autoBtn:IsShown() then place(d.autoBtn, 12) end
        if shown and t.picker.frame:IsShown() then
            local w = 200
            if d.saveBtn:IsShown() then w = max(120, min(200, TV.W - left - used - 8 - 12 - #ns.RaidComp:BuffStates({}, {}) * 16)) end
            t.picker.frame:SetWidth(w)
            place(t.picker.frame, 8, w)
        end
    elseif shown and d.startBtn:IsShown() then
        place(d.startBtn, 12)
    end
    d.stripRoom = TV.W - left - used - (used > 0 and 12 or 0)
    local strip = kind == "groups" and d.buffs or d.compStrip
    strip:ClearAllPoints()
    strip:SetPoint("LEFT", d.seg, "RIGHT", 16, 0)
    -- (both sit in the same place: only the open view's)
    d.buffs:SetShown(kind == "groups")
end

function TV.inMembers(team, key)
    for _, k in ipairs(team.members or {}) do
        if k == key then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Teams view: the waitlist as an icon (2026-10-08, dev/art/casc/teams_mockup/build_v5.py). At the right end of the
-- lineup tabs, for the open lineup: the team icon with a gold badge counting who waits (a soft glow when someone new
-- joins). A click drops the list: each player's place, card and how long they've waited; organizers get ··· (Move
-- up / down, a group, the roster, off the waitlist) and drag a row straight into a group or onto an open Comp slot
-- (the list fades out of the way meanwhile, still there so the drop is heard); my own row has Leave; someone not on
-- the roster gets "Play [spec] Join the waitlist". Shown to organizers and to players not on the roster always, to
-- roster members while someone waits.
---------------------------------------------------------------------------

TV.WL = { ICON_W = 44, W = 316, ROW = 40, PLATE_W = 168, HEAD = 40 }

function TV.createWaitlist(d)
    local row = d.lc
    local b = CreateFrame("Button", nil, row)
    b:SetSize(TV.WL.ICON_W, TV.LT_H)
    b:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    b.bg = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0.125, 0.125, 0.145, 1)
    b.sep = b:CreateTexture(nil, "BORDER")
    b.sep:SetPoint("TOPLEFT", 0, 0)
    b.sep:SetPoint("BOTTOMLEFT", 0, 0)
    b.sep:SetWidth(1)
    b.sep:SetColorTexture(1, 1, 1, 0.06)
    b.under = b:CreateTexture(nil, "ARTWORK", nil, 3)
    b.under:SetPoint("BOTTOMLEFT", 0, 0)
    b.under:SetPoint("BOTTOMRIGHT", 0, 0)
    b.under:SetHeight(2)
    b.under:SetColorTexture(1, 0.82, 0, 1)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.05)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("CENTER", -2, 0)
    if ns:HasAssets(4) then
        b.icon:SetTexture(UI().ICON_ATLAS)
        b.icon:SetTexCoord(unpack(UI():IconCoords(UI().ICON.team)))
    else
        b.icon:SetTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    -- the badge: the count badge, ringed in the strip's colour; it flashes when the count grows
    local g = UI():CreateCountBadge(b, 14)
    g:SetCutout(TV.LT_BG[1], TV.LT_BG[2], TV.LT_BG[3])
    g:SetPoint("LEFT", b, "CENTER", 4, 7)
    g:SetFrameLevel(b:GetFrameLevel() + 3)
    b.badge = g
    b:SetScript("OnClick", function() TV.toggleWaitlist() end)
    b:SetScript("OnEnter", function(self)
        self.icon:SetAlpha(1)
        if d.wl:IsShown() then return end
        local dr = state.draft
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Waitlist")
        local n = self.n or 0
        GameTooltip:AddLine((n == 0 and "Nobody is waiting" or n == 1 and "1 player is waiting" or (n .. " players are waiting"))
            .. " for a spot in " .. (dr and TV.lineupName(dr, dr.li) or "this lineup") .. ".", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        TV.paintWaitlistIcon()
        hideTooltip()
    end)
    d.wlBtn = b

    -- the dropdown: a top-level panel (it takes the window's scale when it opens), a catcher behind it closes it
    local p = CreateFrame("Frame", nil, UIParent)
    p:SetFrameStrata("DIALOG")
    p:SetToplevel(true)
    p:SetClampedToScreen(true)
    p:EnableMouse(true)
    p:SetSize(TV.WL.W, 120)
    for i, o in ipairs({ { 0, -10, 0.35 }, { 0, -3, 0.45 } }) do
        local sh = p:CreateTexture(nil, "BACKGROUND", nil, -8 + i)
        sh:SetPoint("TOPLEFT", -3 - o[1], 1 + o[2] / 3)
        sh:SetPoint("BOTTOMRIGHT", 3 + o[1], o[2])
        sh:SetColorTexture(0, 0, 0, o[3])
    end
    p.bg = p:CreateTexture(nil, "BACKGROUND", nil, 0)
    p.bg:SetAllPoints()
    p.bg:SetColorTexture(0.078, 0.078, 0.09, 1)
    UI():AddEdges(p, "BORDER")
    UI():SetEdgeColor(p, 1, 1, 1, 0.11)
    p.title = textOf(p, "GameFontNormalSmall", 10)
    p.title:SetTextColor(0.69, 0.69, 0.71)
    p.title:SetPoint("LEFT", p, "TOPLEFT", 12, -20)
    p.count = textOf(p, "GameFontHighlightSmall", 11)
    p.count:SetTextColor(0.54, 0.54, 0.56)
    p.count:SetJustifyH("RIGHT")
    p.count:SetPoint("RIGHT", p, "TOPRIGHT", -12, -20)
    p.rows = {}
    p.empty = textOf(p, "GameFontHighlight", 12)
    p.empty:SetTextColor(0.75, 0.75, 0.77)
    p.empty:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -TV.WL.HEAD - 4)
    p.empty:SetText("Nobody is waiting for a spot yet.")
    p.emptySub = textOf(p, "GameFontHighlightSmall", 11)
    p.emptySub:SetTextColor(0.5, 0.5, 0.52)
    p.emptySub:SetPoint("TOPLEFT", p.empty, "BOTTOMLEFT", 0, -6)
    p.emptySub:SetWidth(TV.WL.W - 24)
    p.emptySub:SetJustifyH("LEFT")
    p.emptySub:SetWordWrap(true)
    p.emptySub:SetSpacing(2)
    p.emptySub:SetText("Players who aren't on the roster can put themselves in line here; organizers drag them in.")
    p.rule = p:CreateTexture(nil, "BORDER")
    p.rule:SetHeight(1)
    p.rule:SetColorTexture(1, 1, 1, 0.06)
    p.foot = textOf(p, "GameFontHighlightSmall", 11)
    p.foot:SetTextColor(0.42, 0.42, 0.45)
    -- Join (not on the roster): the spec I'd play, then the button
    p.play = textOf(p, "GameFontHighlight", 12)
    p.play:SetTextColor(0.63, 0.63, 0.65)
    p.play:SetText("Play")
    p.spec = UI():CreateSleekMenuButton(p, "", 104, function(root) TV.waitSpecMenu(root) end)
    p.join = UI():CreateSleekButton(p, "Join the waitlist", 124, 22, function() TV.joinWaitlist() end, "primary")
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("DIALOG")
    catcher:SetFrameLevel(max(0, p:GetFrameLevel() - 1))
    catcher:RegisterForClicks("AnyUp")
    catcher:SetScript("OnClick", function() p:Hide() end)
    catcher:Hide()
    p.catcher = catcher
    p:SetScript("OnShow", function() catcher:Show() end)
    p:SetScript("OnHide", function()
        catcher:Hide()
        p:SetAlpha(1)
        TV.paintWaitlistIcon()
    end)
    p:Hide()
    d.wl = p
end

-- The icon: shown (organizers, players not on the roster, else while someone waits), the badge, the open look.
-- Returns whether it shows. dr / organizer default to the open draft and me.
function TV.paintWaitlistIcon(dr, organizer)
    local d = teamsView and teamsView.detail
    local b = d and d.wlBtn
    if not b then return false end
    dr = dr or state.draft
    if organizer == nil then organizer = RP():CanManageTeams() end
    local saved = dr ~= nil and dr.id ~= nil and dr.ln ~= nil
    local n = saved and #TV.waitMembers() or 0
    local show = saved and (organizer or TV.notOnRoster(dr) or n > 0)
    b:SetShown(show)
    b.n = n
    if not show then return false end
    local open = d.wl:IsShown()
    b.bg:SetShown(open)
    b.under:SetShown(open)
    b.icon:SetAlpha((open or b:IsMouseOver()) and 1 or (n > 0 and 0.78 or 0.32))
    b.badge:SetCount(n)
    -- someone new in line since I last looked at this lineup: the badge glows once
    local key = dr.id .. ":" .. dr.ln
    TV.wlSeen = TV.wlSeen or {}
    if TV.wlSeen[key] and n > TV.wlSeen[key] then TV.glowBadge() end
    TV.wlSeen[key] = n
    return true
end

function TV.notOnRoster(dr)
    local me = ns.Util.PlayerKey()
    return not dr.members[me] and not (dr.base and TV.inMembers(dr.base, me))
end

function TV.glowBadge()
    teamsView.detail.wlBtn.badge:Pulse()
end

function TV.toggleWaitlist()
    local d, dr = teamsView.detail, state.draft
    local p = d.wl
    if p:IsShown() or not (dr and dr.id and dr.ln) then return p:Hide() end
    p.team, p.ln = dr.id, dr.ln
    p:SetScale((d:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1))
    p:Show()
    TV.fillWaitlist()
    UI():DropIn(p, function(dx, dy)
        p:ClearAllPoints()
        p:SetPoint("TOPRIGHT", d.wlBtn, "BOTTOMRIGHT", dx, -6 + dy)
    end)
    TV.paintWaitlistIcon()
    hideTooltip()
end

-- "12 min", "5 h", "2 days" since t.
function TV.waited(t)
    local s = max(0, Now() - (tonumber(t) or Now()))
    if s < 3600 then return max(1, floor(s / 60)) .. " min" end
    if s < 86400 then return floor(s / 3600) .. " h" end
    local days = floor(s / 86400)
    return days == 1 and "1 day" or (days .. " days")
end

function TV.newWaitRow(p)
    local r = CreateFrame("Button", nil, p)
    r:SetSize(TV.WL.W - 16, TV.WL.ROW - 4)
    r:RegisterForClicks("RightButtonUp")
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.03)
    r.n = textOf(r, "GameFontHighlightSmall", 11)
    r.n:SetTextColor(0.48, 0.48, 0.5)
    r.n:SetJustifyH("RIGHT")
    r.n:SetWidth(14)
    r.n:SetPoint("LEFT", r, "LEFT", 2, 0)
    r.plate = CreateFrame("Frame", nil, r)
    r.plate:SetSize(TV.WL.PLATE_W, 32)
    r.plate:SetPoint("LEFT", r, "LEFT", 24, 0)
    ns.RaidGroupsUI:DecoratePlate(r.plate)
    r.time = textOf(r, "GameFontHighlightSmall", 11)
    r.time:SetTextColor(0.48, 0.48, 0.5)
    r.time:SetJustifyH("RIGHT")
    r.more = UI():CreateTipIconButton(r, 20, UI().ICON.more, "More", nil, function(self)
        local key = r.member and r.member.key
        if key then UI():ContextMenu(self, function(root) TV.waitMenu(root, key) end) end
    end)
    r.more:SetPoint("RIGHT", r, "RIGHT", -2, 0)
    r.leave = UI():CreateSleekButton(r, "Leave", 54, 20, function()
        local dr = state.draft
        local ok, err = RP():LeaveWaitlist(dr.id, dr.ln)
        if not ok then Print(err or "Could not leave the waitlist.") end
    end)
    setSize(r.leave:GetFontString(), 11)
    r.leave:SetPoint("RIGHT", r, "RIGHT", -2, 0)
    r:SetScript("OnClick", function(self)
        if self.member and RP():CanManageTeams() then
            local key = self.member.key
            UI():ContextMenu(self, function(root) TV.waitMenu(root, key) end)
        end
    end)
    r:SetScript("OnEnter", function(self)
        local w = self.member
        if not w then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(colored(w.key, w.c) .. (TV.isMine(w.key) and " |cff9e9e9e(you)|r" or ""))
        GameTooltip:AddLine((w.sp and ns.RaidComp:SlotName(w.c, w.sp)) or "Spec unknown", 1, 1, 1)
        for _, line in ipairs(w.info or {}) do GameTooltip:AddLine(line, 0.75, 0.75, 0.75, true) end
        if RP():CanManageTeams() then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Drag into a group (or onto an open Comp slot) to put them on the roster.", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", hideTooltip)
    r:RegisterForDrag("LeftButton")
    r:SetScript("OnDragStart", function(self) TV.waitDragStart(self) end)
    r:SetScript("OnDragStop", function() ns.RaidGroupsUI:EndCardDrag() end)
    return r
end

function TV.fillWaitlist()
    local d, dr = teamsView.detail, state.draft
    local p = d.wl
    if not (p:IsShown() and dr and dr.id and dr.ln) then return end
    local organizer = RP():CanManageTeams()
    local me = ns.Util.PlayerKey()
    local list = TV.waitMembers()
    p.title:SetText("WAITLIST" .. colorize("8c8c8c", "  ·  " .. TV.lineupName(dr, dr.li)))
    p.count:SetText(#list > 0 and (#list .. " waiting") or "")
    local mine = false
    for i, w in ipairs(list) do
        local r = p.rows[i] or TV.newWaitRow(p)
        p.rows[i] = r
        r.member = w
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", p, "TOPLEFT", 8, -TV.WL.HEAD - (i - 1) * TV.WL.ROW)
        r.n:SetText(w.n)
        local own = w.key == me
        mine = mine or own
        ns.RaidGroupsUI:PaintPlate(r.plate, ns.RaidGroupsUI:PlayerPlate({ key = w.key, c = w.c, sp = w.sp, auto = w.auto },
            own and "me" or nil))
        r.plate:SetAlpha(1)
        r.time:SetText(TV.waited(w.at))
        r.more:SetShown(organizer and not own)
        r.leave:SetShown(own)
        r.time:ClearAllPoints()
        if r.more:IsShown() then r.time:SetPoint("RIGHT", r.more, "LEFT", -6, 0)
        elseif own then r.time:SetPoint("RIGHT", r.leave, "LEFT", -8, 0)
        else r.time:SetPoint("RIGHT", r, "RIGHT", -2, 0) end
        r:Show()
    end
    for i = #list + 1, #p.rows do
        p.rows[i]:Hide()
        p.rows[i].member = nil
    end
    local y = TV.WL.HEAD + #list * TV.WL.ROW
    p.empty:SetShown(#list == 0)
    p.emptySub:SetShown(#list == 0)
    if #list == 0 then y = TV.WL.HEAD + 4 + (p.empty:GetStringHeight() or 14) + 6 + max(14, p.emptySub:GetStringHeight() or 28) + 8 end
    -- the foot: Join for someone not on the roster and not in line yet; else a line on how it works
    local canJoin = TV.notOnRoster(dr) and not mine
    y = TV.wlNights(p, dr, y)
    p.rule:ClearAllPoints()
    p.rule:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -(y + 2))
    p.rule:SetPoint("TOPRIGHT", p, "TOPRIGHT", -12, -(y + 2))
    p.play:SetShown(canJoin)
    p.spec:SetShown(canJoin)
    p.join:SetShown(canJoin)
    p.foot:SetShown(not canJoin and (#list > 0 or not organizer))
    if canJoin then
        TV.paintWaitSpec()
        p.play:ClearAllPoints()
        p.play:SetPoint("LEFT", p, "TOPLEFT", 12, -(y + 22))
        p.spec:ClearAllPoints()
        p.spec:SetPoint("LEFT", p.play, "RIGHT", 8, 0)
        p.join:ClearAllPoints()
        p.join:SetPoint("RIGHT", p, "TOPRIGHT", -12, -(y + 22))
        y = y + 42
    else
        p.foot:SetText(organizer and "Drag a player into a group to put them on the roster"
            or (mine and "First in line gets the next spot" or "Players waiting for a spot in this lineup"))
        p.foot:ClearAllPoints()
        p.foot:SetPoint("LEFT", p, "TOPLEFT", 12, -(y + 16))
        y = y + (p.foot:IsShown() and 30 or 4)
    end
    p.rule:SetShown(p.foot:IsShown() or canJoin)
    p:SetHeight(floor(y + 0.5))
end

-- Join's spec (nil: as my sign-ups say) and its menu.
function TV.paintWaitSpec()
    local p = teamsView.detail.wl
    local _, cls = UnitClass("player")
    local sp = TV.wlSpec
    if not sp then sp = RP():GetMemberSpec(ns.Util.PlayerKey()) end
    local label = sp and cls and ns.RaidComp:SpecLabel(cls, sp)
    p.spec:SetText(label or "My spec")
end

function TV.waitSpecMenu(root)
    local _, cls = UnitClass("player")
    for i, spec in ipairs(cls and ns.SPECS[cls] or {}) do
        root:CreateButton(TV.specIconText(cls, i, 14) .. " " .. spec.label, function()
            TV.wlSpec = i
            TV.paintWaitSpec()
        end)
    end
    local asp, ac = RP():GetMemberSpec(ns.Util.PlayerKey())
    local label = asp and ns.RaidComp:SpecLabel(ac, asp)
    if label then
        root:CreateButton(colorize("9e9e9e", "As my sign-ups say (" .. label .. ")"), function()
            TV.wlSpec = nil
            TV.paintWaitSpec()
        end)
    end
end

function TV.joinWaitlist()
    local dr = state.draft
    if not (dr and dr.id and dr.ln) then return end
    local ok, err = RP():JoinWaitlist(dr.id, dr.ln, TV.wlSpec)
    if not ok then Print(err or "Could not join the waitlist.") end
end

-- A waitlisted player dragged out of the list (organizers): into a group, onto Unassigned, or (Comp) onto an open
-- slot; they join the roster where they land (Save keeps it). The list fades out of the way while the card moves
-- and closes on a drop; released anywhere else it comes back.
function TV.waitDragStart(r)
    if not RP():CanManageTeams() or not r.member then return end
    local d = teamsView.detail
    local w = r.member
    local comp = PlanUI:GetTeamTab() == "comp" and TV.cur and TV.cur.match ~= nil
    teamsView.grid:Refresh()
    local drag = { key = w.key, c = w.c, sp = w.sp, from = "waitlist" }
    local dropped = false
    local ok = ns.RaidGroupsUI:StartCardDrag(r.plate, ns.RaidGroupsUI:PlayerPlate({ key = w.key, c = w.c, sp = w.sp }), {
        target = function()
            if comp then return TV.compTarget(drag) end
            return TV.gridTarget(drag)
        end,
        drop = function(t)
            dropped = true
            if comp then return TV.compDrop(drag, t) end
            TV.gridDrop(drag, t)
        end,
        finish = function()
            if dropped then d.wl:Hide() else d.wl:SetAlpha(1) end
        end,
    })
    if ok then d.wl:SetAlpha(0) end
end

-- What a dragged waitlisted player is over on the Groups tab (the grid's own drop rules), as a card-drag target.
function TV.gridTarget(drag)
    local grid = teamsView.grid
    local t = grid:DropTarget(drag.key)
    if not t then return nil end
    if t.pool then
        return { frame = grid.pool, ok = true, kind = "pool", label = "Onto the roster (Unassigned)" }
    end
    if t.full then return { frame = t.box, ok = false, label = "Group " .. t.g .. " is full" } end
    if t.target then
        local m = t.chip and t.chip.member
        return { frame = t.chip, ok = true, kind = "group", g = t.g, target = t.target,
                 label = "Swap with " .. colored(t.target, m and m.c) .. "\n" .. colorize("9e9e9e", "they go to Unassigned") }
    end
    local label = "Group " .. t.g .. (t.seat and (", seat " .. t.seat) or "")
    local gh = t.chip and t.chip.ghost
    label = label .. "\n" .. colorize("9e9e9e", "onto the roster" .. (gh and (" · planned: "
        .. tostring(ns.RaidComp:SlotName(gh.c, gh.sp) or gh.name or "?")) or ""))
    return { frame = t.chip or t.box, ok = true, kind = "group", g = t.g, seat = t.seat, label = label }
end

function TV.gridDrop(drag, t)
    if t.kind == "pool" then
        PlanUI:MoveDraftMember(drag.key, nil, nil, nil, teamsView.grid.shown)
    else
        PlanUI:MoveDraftMember(drag.key, t.g, t.target, t.seat, teamsView.grid.shown)
    end
    PlanUI:RefreshTeams()
end

---------------------------------------------------------------------------
-- Teams view: the target comp (1.3.1; Core/RaidComp.lua has the API contract). The card's meter and Needs, the
-- Groups | Comp tabs, the Comp view (a column of slots per role, the bench, the steppers, Start from), the raid-buff
-- strip's three states, the open slots in a raid's Sign-ups and the LF message. The comp is part of the team's draft
-- (dr.cp): one Save for groups and comp, and the unsaved guard covers both.
---------------------------------------------------------------------------

TV.ROLE_LABEL = { tank = "Tanks", healer = "Healers", melee = "Melee", ranged = "Ranged" }
TV.ROLE_ICON = { tank = "tank", healer = "healer", melee = "dps", ranged = "ranged" }
-- the empty Comp card's picture: a meter with some slots open
TV.MINI_COMP = { tank = { "WARRIOR", "PALADIN", false }, healer = { "PALADIN", "PRIEST", "SHAMAN", "SHAMAN", false, false },
                 melee = { "ROGUE", "SHAMAN", "WARRIOR", false }, ranged = { "MAGE", "WARLOCK", "PRIEST", false, false } }

-- A class circle in text.
function TV.classIconText(c, size)
    local tc = c and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[c]
    if not tc then return "" end
    size = size or 14
    local function px(v) return floor(v * 256 + 0.5) end
    return ("|TInterface\\TargetingFrame\\UI-Classes-Circles:%d:%d:0:0:256:256:%d:%d:%d:%d|t"):format(size, size,
        px(tc[1]), px(tc[2]), px(tc[3]), px(tc[4]))
end

-- A spec's icon in text.
function TV.specIconText(c, sp, size)
    local icon = ns.RaidComp:SpecIcon(c, sp)
    if not icon then return "" end
    size = size or 14
    return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(icon, size, size)
end

-- The draft's comp, or nil when it has no slot.
function TV.comp(dr)
    dr = dr or state.draft
    return (dr and type(dr.cp) == "table" and next(dr.cp)) and dr.cp or nil
end

-- Who fills which slot of the draft's comp (RaidPlan:MatchTeam), or nil without a comp.
function TV.match(dr)
    dr = dr or state.draft
    if not TV.comp(dr) then return nil end
    return RP():MatchTeam(TV.ref(dr))
end

-- "a" / "an"
function TV.article(word)
    return tostring(word or ""):match("^[AEIOUaeiou]") and "an" or "a"
end

-- The strip of the Comp view: lit = whose slot is filled, planned = the open slots, off = not in the comp.
function TV.compStates(dr)
    local out = RP():GetTeamBuffStates(TV.ref(dr))
    for _, e in ipairs(out) do
        if e.state == "off" then
            local names = {}
            for i, b in ipairs(e.bringers or {}) do
                if i <= 3 then names[#names + 1] = TV.article(b.name) .. " " .. tostring(b.name) end
            end
            e.offText = #names > 0 and ("Not in the comp: " .. tconcat(names, " or ") .. " brings it.") or nil
        end
    end
    return out
end

-- The strip of the Groups view: lit = who sits in the groups, planned = the comp's open slots.
function TV.groupStates(placed)
    local dr = state.draft
    local open = TV.comp(dr) and (RP():GetTeamOpenSlots(TV.ref(dr))) or {}
    local out = ns.RaidComp:BuffStates(placed, open)
    for _, e in ipairs(out) do
        if e.state == "off" then e.offText = "Nobody in the groups brings it." end
    end
    return out
end

-- How many could fill an open slot of class c, spec sp: the players of that spec among the unassigned, the waitlist,
-- those beyond the comp, the alts and the guild (RaidPlan:CanFill; not other teams' players). Kept per refresh.
function TV.canFillCount(dr, c, sp)
    if not (dr and c and sp) then return nil end
    TV.cur = TV.cur or {}
    local cache = TV.cur.cf or {}
    TV.cur.cf = cache
    local k = c .. ":" .. sp
    if cache[k] == nil then
        local cf = RP():CanFill(TV.ref(dr), c, sp)
        local count = 0
        for _, grp in ipairs({ cf.unassigned, cf.waitlist, cf.extra, cf.alts, cf.guild }) do
            for _, e in ipairs(grp or {}) do
                if not e.other then count = count + 1 end
            end
        end
        cache[k] = count
    end
    return cache[k]
end

-- The comp's open slots as ghosts in the groups' free seats (RaidComp:PlaceOpen, for the grid's opts.getGhosts), each
-- with how many could fill it (TV.canFillCount). nil without a comp.
function TV.ghosts(byGroup, n)
    local dr = state.draft
    if not (dr and TV.comp(dr)) then return nil end
    local m = TV.cur and TV.cur.match or TV.match(dr)
    if not (m and m.open and #m.open > 0) then return nil end
    local list = {}
    for _, o in ipairs(m.open) do
        local count = TV.canFillCount(dr, o.c, o.sp)
        for _ = 1, o.n or 1 do
            list[#list + 1] = { c = o.c, sp = o.sp, name = o.name, role = o.role, canFill = count }
        end
    end
    return ns.RaidComp:PlaceOpen(byGroup, list, n)
end

-- Who could fill an open slot of the team (the Needs line, the Comp view): benched members, members in a group beyond
-- the comp, alts, the guild, other teams (RaidPlan:CanFill), three a group at most.
function TV.canFillTooltip(owner, c, sp, anchor)
    local dr = state.draft
    if not dr then return end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:AddLine(TV.specIconText(c, sp, 16) .. " " .. tostring(ns.RaidComp:SlotName(c, sp) or "?"), 1, 1, 1)
    local brings = {}
    for _, e in ipairs(TV.states or {}) do
        if e.state == "planned" then
            for _, sl in ipairs(e.slots or {}) do
                if sl.c == c and sl.sp == sp then brings[#brings + 1] = e.buff.name end
            end
        end
    end
    GameTooltip:AddLine("Open" .. (#brings > 0 and (" · brings " .. tconcat(brings, ", ")) or ""), 0.62, 0.62, 0.62, true)
    local cf = RP():CanFill(TV.ref(dr), c, sp)
    local any = false
    for _, grp in ipairs({ { "Unassigned", cf.unassigned }, { "Waitlist", cf.waitlist },
                           { "In the groups, beyond the comp", cf.extra }, { "Alts of the team", cf.alts },
                           { "In the guild", cf.guild }, { "In other teams", cf.teams } }) do
        local list = grp[2] or {}
        if #list > 0 then
            any = true
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(grp[1], 1, 0.82, 0)
            for i = 1, min(3, #list) do
                local e = list[i]
                local right = {}
                if e.other then right[#right + 1] = e.sp and ns.RaidComp:SpecLabel(e.c, e.sp) or "spec unknown" end
                if e.of then right[#right + 1] = TV.isMine(e.of) and "your alt" or (shortName(e.of) .. "'s alt") end
                if e.team then right[#right + 1] = e.team end
                if e.n then right[#right + 1] = "#" .. e.n .. " in line" end
                GameTooltip:AddDoubleLine(TV.classIconText(e.c, 14) .. " " .. colored(e.key, e.c), tconcat(right, " · "),
                    1, 1, 1, 0.62, 0.62, 0.62)
            end
            if #list > 3 then GameTooltip:AddLine(("+%d more"):format(#list - 3), 0.5, 0.5, 0.5) end
        end
    end
    if not any then GameTooltip:AddLine("Nobody in the guild plays it yet.", 0.6, 0.6, 0.6, true) end
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- The meter (a square per slot): the empty comp card's picture
---------------------------------------------------------------------------

function TV.createMeter(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(200, 16)
    f.icons, f.sq = {}, {}
    for i, role in ipairs({ "tank", "healer", "dps", "ranged" }) do
        local ic = f:CreateTexture(nil, "ARTWORK")
        ic:SetSize(14, 14)
        UI():SetRoleIcon(ic, role)
        f.icons[i] = ic
    end
    f:EnableMouse(true)
    f:SetScript("OnEnter", TV.meterTooltip)
    f:SetScript("OnLeave", hideTooltip)
    return f
end

-- Square i of a meter: an 8 px square, the class colour of who fills the slot; open = a thin gold square.
function TV.square(f, i)
    local s = f.sq[i]
    if not s then
        s = { o = f:CreateTexture(nil, "ARTWORK", nil, 1), i = f:CreateTexture(nil, "ARTWORK", nil, 2) }
        s.o:SetSize(8, 8)
        s.i:SetSize(6, 6)
        s.i:SetPoint("CENTER", s.o, "CENTER", 0, 0)
        s.i:SetColorTexture(CARD_BG[1], CARD_BG[2], CARD_BG[3], 1)
        f.sq[i] = s
    end
    return s
end

-- m: a MatchComp result (or the picture's { columns = { role = { slot } } }). Tanks, healers, melee, ranged, each
-- behind its icon; a role without slots is left out.
function TV.fillMeter(f, m)
    f.match = m
    local x, n = 0, 0
    for gi, roles in ipairs({ { "tank" }, { "healer" }, { "melee" }, { "ranged" } }) do
        local count = 0
        for _, role in ipairs(roles) do count = count + #(m.columns[role] or {}) end
        local ic = f.icons[gi]
        ic:SetShown(count > 0)
        if count > 0 then
            if x > 0 then x = x + 12 end
            ic:ClearAllPoints()
            ic:SetPoint("LEFT", f, "LEFT", x, 0)
            x = x + 14 + 6
            for ri, role in ipairs(roles) do
                local col = m.columns[role] or {}
                if ri > 1 and #col > 0 and #(m.columns[roles[1]] or {}) > 0 then x = x + 4 end
                -- (who fills first, the open slots after them)
                local order = {}
                for _, slot in ipairs(col) do if slot.member then order[#order + 1] = slot end end
                for _, slot in ipairs(col) do if not slot.member then order[#order + 1] = slot end end
                for _, slot in ipairs(order) do
                    n = n + 1
                    local s = TV.square(f, n)
                    s.o:ClearAllPoints()
                    s.o:SetPoint("LEFT", f, "LEFT", x, 0)
                    local who = slot.member and (slot.member.c or slot.c)
                    if who then
                        local r, g, b = UI():ClassColor(who)
                        s.o:SetColorTexture(r, g, b, 1)
                        s.i:Hide()
                    else
                        s.o:SetColorTexture(1, 0.82, 0, 0.9)
                        s.i:Show()
                    end
                    s.o:Show()
                    x = x + 10
                end
            end
            x = x - 2
        end
    end
    for i = n + 1, #f.sq do
        f.sq[i].o:Hide()
        f.sq[i].i:Hide()
    end
    f:SetWidth(max(1, x))
end

function TV.meterTooltip(self)
    local m = self.match
    if not m or not m.total then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:AddLine("Target comp")
    for _, role in ipairs(ns.RaidComp.COLUMNS) do
        local col = m.columns[role] or {}
        if #col > 0 then
            local f = 0
            for _, sl in ipairs(col) do if sl.member then f = f + 1 end end
            local full = f == #col
            GameTooltip:AddDoubleLine(TV.ROLE_LABEL[role], f .. "/" .. #col, 1, 1, 1, full and 0.56 or 1,
                full and 0.89 or 1, full and 0.62 or 1)
        end
    end
    GameTooltip:AddLine(("%d of %d slots filled"):format(m.filled, m.total), 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- The lineups: tabs on the banner's foot (name, filled, a fill bar along the bottom), the open one lit with a gold top
-- edge; organizers end the row with "+". Too many for the row: the open one keeps its tab, the rest go into "+n".
---------------------------------------------------------------------------

function TV.createLineupTabs(d)
    local row = CreateFrame("Frame", nil, d)
    row:SetSize(TV.W, TV.LT_H)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(TV.LT_BG[1], TV.LT_BG[2], TV.LT_BG[3], 1)
    row.rule = row:CreateTexture(nil, "BORDER")
    row.rule:SetPoint("BOTTOMLEFT", 0, 0)
    row.rule:SetPoint("BOTTOMRIGHT", 0, 0)
    row.rule:SetHeight(1)
    row.rule:SetColorTexture(1, 1, 1, 0.08)
    d.lc = row
    d.lcards = {}
    local function plain(text, onMenu, tip)
        local b = CreateFrame("Button", nil, row)
        b:SetSize(36, TV.LT_H)
        b.hl = b:CreateTexture(nil, "HIGHLIGHT")
        b.hl:SetAllPoints()
        b.hl:SetColorTexture(1, 1, 1, 0.05)
        b.fs = textOf(b, "GameFontHighlight", 15)
        b.fs:SetTextColor(0.55, 0.55, 0.55)
        b.fs:SetPoint("CENTER", 0, 0)
        b.fs:SetText(text)
        b:SetScript("OnClick", function(self) UI():ContextMenu(self, onMenu) end)
        b:SetScript("OnEnter", function(self)
            self.fs:SetTextColor(1, 0.82, 0)
            if tip then
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:AddLine(tip[1])
                GameTooltip:AddLine(tip[2], 1, 1, 1, true)
                GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave", function(self)
            self.fs:SetTextColor(0.55, 0.55, 0.55)
            hideTooltip()
        end)
        return b
    end
    d.lcAdd = plain("+", function(root)
        root:CreateTitle("New lineup")
        root:CreateButton("10-man", function() PlanUI:AddLineup(10) end)
        root:CreateButton("25-man", function() PlanUI:AddLineup(25) end)
    end, { "New lineup", "Another 10- or 25-player setup of this roster (e.g. Kara A and Kara B), with its own groups, "
        .. "specs, target comp and waitlist." })
    d.lcMore = plain("", function(root)
        for _, e in ipairs(d.lcMore.rest or {}) do
            root:CreateButton((e.mine and colorize("ffd100", "• ") or "") .. e.name, function() PlanUI:SelectLineup(e.i) end)
        end
    end)
    d.lcMore.fs:SetFontObject("GameFontHighlightSmall")
    TV.createWaitlist(d)
end

function TV.newLineupTab(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(TV.LT_H)
    c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    c.bg = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    c.bg:SetAllPoints()
    c.bg:SetColorTexture(0.125, 0.125, 0.145, 1)
    c.top = c:CreateTexture(nil, "ARTWORK", nil, 3)
    c.top:SetPoint("TOPLEFT", 0, 0)
    c.top:SetPoint("TOPRIGHT", 0, 0)
    c.top:SetHeight(2)
    c.top:SetColorTexture(1, 0.82, 0, 1)
    c.sep = c:CreateTexture(nil, "BORDER")
    c.sep:SetPoint("TOPRIGHT", 0, 0)
    c.sep:SetPoint("BOTTOMRIGHT", 0, 0)
    c.sep:SetWidth(1)
    c.sep:SetColorTexture(1, 1, 1, 0.06)
    c.hl = c:CreateTexture(nil, "HIGHLIGHT")
    c.hl:SetAllPoints()
    c.hl:SetColorTexture(1, 1, 1, 0.04)
    c.dot = c:CreateTexture(nil, "ARTWORK")
    c.dot:SetSize(6, 6)
    c.dot:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    c.dot:SetVertexColor(1, 0.82, 0)
    c.dot:SetPoint("LEFT", 14, 0)
    c.name = textOf(c, "GameFontHighlight", 13)
    c.size = textOf(c, "GameFontHighlightSmall", 10)
    c.size:SetTextColor(0.55, 0.55, 0.55)
    c.size:SetPoint("LEFT", c.name, "RIGHT", 5, 0)
    c.count = textOf(c, "GameFontHighlight", 12)
    c.count:SetJustifyH("RIGHT")
    c.count:SetPoint("RIGHT", -16, 0)
    c.fill = c:CreateTexture(nil, "ARTWORK", nil, 2)
    c.fill:SetPoint("BOTTOMLEFT", 0, 0)
    c.fill:SetHeight(2)
    c:SetScript("OnClick", function(self, button)
        local i = self.i
        if not i then return end
        local organizer = RP():CanManageTeams()
        if button == "RightButton" or (organizer and i == state.draft.li) then
            if organizer then TV.lineupMenu(self, i) end
        else
            PlanUI:SelectLineup(i)
        end
    end)
    c:SetScript("OnEnter", function(self)
        if not self.tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        for k, line in ipairs(self.tip) do
            GameTooltip:AddLine(line[1], line[2] or 1, line[3] or 1, line[4] or 1, k > 1)
        end
        GameTooltip:Show()
    end)
    c:SetScript("OnLeave", hideTooltip)
    return c
end

-- Lineup i of the draft as RaidPlan reads it (the open one: the draft's working copy).
function TV.lineupRef(dr, i)
    local l = dr.lineups[i]
    if i == dr.li then return TV.ref(dr) end
    return { id = dr.id, ln = l.id, lineupName = TV.lineupName(dr, i), members = dr.members, s = l.s, grp = l.grp,
             sz = l.sz, cp = l.cp }
end

-- What a lineup's tab says: filled / of (its comp's slots, else its groups against its size), its open slots.
function TV.lineupFacts(dr, i, m)
    local l = dr.lineups[i]
    local gc = ns.RaidComp:GroupCount(l.sz)
    local inGroups = 0
    for _, g in pairs(l.grp or {}) do
        if type(g) == "number" and g >= 1 and g <= gc then inGroups = inGroups + 1 end
    end
    if i ~= dr.li then
        m = TV.comp({ cp = l.cp }) and RP():MatchTeam(TV.lineupRef(dr, i)) or nil
    end
    local f = { inGroups = inGroups }
    if m then
        f.have, f.of = m.filled, m.total
        f.open = #m.open > 0 and m.open or nil
    else
        f.have, f.of = inGroups, l.sz
    end
    return f
end

function TV.layoutLineupTabs(dr, organizer, m, y)
    local d = teamsView.detail
    local row = d.lc
    local wl = TV.paintWaitlistIcon(dr, organizer)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, -y)
    local n = #dr.lineups
    local add = organizer and n < TV.MAX_LINEUPS
    local me = TV.myKey(dr.members)
    -- each tab as wide as its words (at least LT_MIN); the open one always shown, the rest while they fit
    local tabs = {}
    for i = 1, n do
        local c = d.lcards[i] or TV.newLineupTab(row)
        d.lcards[i] = c
        local l = dr.lineups[i]
        local f = TV.lineupFacts(dr, i, i == dr.li and m or nil)
        local chosen = i == dr.li
        c.i, c.chosen = i, chosen
        local g = me and l.grp and l.grp[me]
        local mine = type(g) == "number" and g >= 1 and g <= ns.RaidComp:GroupCount(l.sz)
        c.mine = mine
        c.dot:SetShown(mine and true or false)
        c.name:ClearAllPoints()
        c.name:SetPoint("LEFT", c, "LEFT", mine and 27 or 14, 0)
        c.name:SetText(TV.lineupName(dr, i))
        c.name:SetTextColor(chosen and 1 or 0.66, chosen and 1 or 0.66, chosen and 1 or 0.66)
        -- (a named lineup says its size, unless its name already does: "Thursday 25")
        c.size:SetText((l.name and not l.name:find(tostring(l.sz), 1, true)) and tostring(l.sz) or "")
        local full = f.have >= f.of and f.of > 0
        c.count:SetText((full and colorize("8fe39d", f.have) or (chosen and colorize("ffffff", f.have) or colorize("bdbdbd", f.have)))
            .. colorize("808080", "/" .. f.of))
        c.bg:SetShown(chosen)
        c.top:SetShown(chosen)
        local w = (mine and 27 or 14) + (c.name:GetStringWidth() or 40)
            + (c.size:GetText() ~= "" and (5 + (c.size:GetStringWidth() or 12)) or 0)
            + 20 + (c.count:GetStringWidth() or 30) + 16
        w = max(TV.LT_MIN, floor(w + 0.5))
        c:SetWidth(w)
        c.share = f.of > 0 and min(1, f.have / f.of) or 0
        c.fill:SetShown(c.share > 0)
        c.fill:SetWidth(max(1, floor(w * c.share + 0.5)))
        if full then c.fill:SetColorTexture(0.56, 0.89, 0.62, chosen and 1 or 0.5)
        else c.fill:SetColorTexture(1, 0.82, 0, chosen and 1 or 0.35) end
        -- the tooltip: its size, who is in its groups, everything still open
        local tip = { { TV.lineupName(dr, i) }, { l.sz .. "-player lineup · " .. f.inGroups .. " in its groups", 0.8, 0.8, 0.8 } }
        if mine then tip[#tip + 1] = { "You're in its groups.", 1, 0.82, 0 } end
        if l.id == nil and dr.id ~= nil then tip[#tip + 1] = { "New: saved with the team.", 1, 0.6, 0.2 } end
        if f.open then
            tip[#tip + 1] = { "Still open:", 1, 0.82, 0 }
            for _, o in ipairs(f.open) do
                tip[#tip + 1] = { TV.specIconText(o.c, o.sp, 14) .. " " .. o.name .. (o.n > 1 and (" ×" .. o.n) or "") }
            end
        end
        tip[#tip + 1] = { chosen and (organizer and "Open. Click for Rename, Size, Copy or Delete." or "Open below.")
            or (organizer and "Click to open it; right-click for Rename, Size, Copy or Delete." or "Click to open it."),
            0.6, 0.6, 0.6 }
        c.tip = tip
        tabs[i] = w
    end
    local room = TV.W - (add and 36 or 0) - (wl and TV.WL.ICON_W or 0)
    local total = 0
    for i = 1, n do total = total + tabs[i] end
    local shown = {}
    if total <= room then
        for i = 1, n do shown[i] = true end
    else
        local used = tabs[dr.li] + 44
        shown[dr.li] = true
        for i = 1, n do
            if i ~= dr.li and used + tabs[i] <= room then
                shown[i] = true
                used = used + tabs[i]
            end
        end
    end
    local x, rest = 0, {}
    for i = 1, n do
        local c = d.lcards[i]
        if shown[i] then
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", row, "TOPLEFT", x, 0)
            c:Show()
            x = x + tabs[i]
        else
            c:Hide()
            rest[#rest + 1] = { i = i, name = TV.lineupName(dr, i), mine = c.mine }
        end
    end
    for i = n + 1, #d.lcards do d.lcards[i]:Hide() end
    d.lcMore.rest = rest
    d.lcMore:SetShown(#rest > 0)
    if #rest > 0 then
        d.lcMore.fs:SetText("+" .. #rest)
        d.lcMore:SetWidth(44)
        d.lcMore:ClearAllPoints()
        d.lcMore:SetPoint("TOPLEFT", row, "TOPLEFT", x, 0)
        x = x + 44
    end
    d.lcAdd:SetShown(add)
    if add then
        d.lcAdd:ClearAllPoints()
        d.lcAdd:SetPoint("TOPLEFT", row, "TOPLEFT", x, 0)
    end
end

-- The Groups | Comp switch: as wide as its words, Comp only while it shows.
function TV.layoutSeg()
    local d = teamsView.detail
    d.tabGroups:ClearAllPoints()
    d.tabGroups:SetPoint("LEFT", d.seg, "LEFT", 2, 0)
    local w = 2 + d.tabGroups:GetWidth()
    if d.tabComp:IsShown() then
        d.tabComp:ClearAllPoints()
        d.tabComp:SetPoint("LEFT", d.tabGroups, "RIGHT", 0, 0)
        w = w + d.tabComp:GetWidth()
    end
    d.seg:SetWidth(w + 2)
    -- the thumb under the open tab (TV.animateTab slides it there instead while it runs)
    local comp = d.tabComp:IsShown() and d.tabComp.active
    local tx = comp and (2 + d.tabGroups:GetWidth()) or 2
    local tw = comp and d.tabComp:GetWidth() or d.tabGroups:GetWidth()
    d.seg.thumb.tx, d.seg.thumb.tw = tx, tw
    if not TV.anim then TV.placeThumb(tx, tw) end
end

function TV.placeThumb(x, w)
    local th = teamsView.detail.seg.thumb
    th.x, th.w = x, w
    th:ClearAllPoints()
    th:SetPoint("LEFT", th:GetParent(), "LEFT", x, 0)
    th:SetWidth(max(1, w))
end

-- Groups <-> Comp: the thumb slides to the new tab while the new view fades in and glides the last few px into
-- place from the side of its tab (Comp from the right, Groups from the left), with the toolbar's strip and actions
-- fading in with it. Eased out; a switch during the motion starts from where things are.
TV.ANIM = { THUMB = 0.22, VIEW = 0.28, SHIFT = 14 }

-- fx, fw = where the thumb was before the switch (the refresh has already put it under the new tab).
function TV.animateTab(key, fx, fw)
    local d = teamsView and teamsView.detail
    if not (d and d:IsVisible()) then return end
    local th = d.seg.thumb
    local a = { t = 0, fx = fx or th.x, fw = fw or th.w, dir = key == "comp" and 1 or -1, fades = {}, shifts = {} }
    local function fade(f)
        if f and f:IsShown() then a.fades[#a.fades + 1] = f end
    end
    local function shift(f)
        if not (f and f:IsShown()) then return end
        local pts = {}
        for i = 1, (f.GetNumPoints and f:GetNumPoints() or 0) do pts[i] = { f:GetPoint(i) } end
        a.shifts[#a.shifts + 1] = { f = f, pts = pts }
        fade(f)
    end
    if key == "comp" then
        shift(d.compScroll)
        shift(d.compEmpty)
        fade(d.compStrip)
    else
        shift(d.scroll)
        fade(d.buffs)
    end
    fade(d.tool)
    -- (an earlier motion's frames end where they belong)
    if TV.anim then TV.endAnim() end
    TV.anim = a
    TV.stepAnim(0)
    TV.animDriver = TV.animDriver or CreateFrame("Frame")
    TV.animDriver:SetScript("OnUpdate", function(_, elapsed) TV.stepAnim(elapsed) end)
end

function TV.stepAnim(elapsed)
    local a = TV.anim
    if not a then return end
    a.t = a.t + (elapsed or 0)
    local function ease(x) x = min(1, max(0, x)) return 1 - (1 - x) ^ 3 end
    local th = teamsView.detail.seg.thumb
    local e1 = ease(a.t / TV.ANIM.THUMB)
    TV.placeThumb(a.fx + ((th.tx or a.fx) - a.fx) * e1, a.fw + ((th.tw or a.fw) - a.fw) * e1)
    local e2 = ease(a.t / TV.ANIM.VIEW)
    for _, f in ipairs(a.fades) do f:SetAlpha(e2) end
    local dx = a.dir * TV.ANIM.SHIFT * (1 - e2)
    for _, s in ipairs(a.shifts) do
        s.f:ClearAllPoints()
        for _, pt in ipairs(s.pts) do s.f:SetPoint(pt[1], pt[2], pt[3], (pt[4] or 0) + dx, pt[5] or 0) end
    end
    if a.t >= max(TV.ANIM.THUMB, TV.ANIM.VIEW) then TV.endAnim() end
end

function TV.endAnim()
    local a = TV.anim
    if not a then return end
    TV.anim = nil
    if TV.animDriver then TV.animDriver:SetScript("OnUpdate", nil) end
    for _, f in ipairs(a.fades) do f:SetAlpha(1) end
    for _, s in ipairs(a.shifts) do
        s.f:ClearAllPoints()
        for _, pt in ipairs(s.pts) do s.f:SetPoint(pt[1], pt[2], pt[3], pt[4] or 0, pt[5] or 0) end
    end
    local th = teamsView.detail.seg.thumb
    if th.tx then TV.placeThumb(th.tx, th.tw) end
end

---------------------------------------------------------------------------
-- Teams view: raid nights (1.3.5). The nights of the week a team raids (Core/RaidNights.lua), shown in my clock: a
-- RAID NIGHTS block on every banner of the board and on the team's banner (a week strip M T W T F S S, a core night
-- lit gold, an optional one a hollow gold edge, and the hours under it), and in the waitlist panel above Join, so
-- players see what they sign up for. Organizers click the block (or ··· > Raid nights) for the editor: day tiles, the
-- hours of each night, Optional, one note. A draft change like the theme (Save / Undo).
---------------------------------------------------------------------------

TV.N = {
    X = 326,                          -- the block's left edge on a banner (the name stays left of it)
    CELL = 17, CELL_H = 19, CELL_GAP = 3,
    PANEL_W = 420, TILE_H = 34, ROW_H = 38,
    CELL_BG = { 0.08, 0.08, 0.09, 0.95 }, EDGE = { 0.20, 0.20, 0.23, 1 }, PICKED_BG = { 0.17, 0.14, 0.05, 0.95 },
    GOLD = { 0.91, 0.73, 0.14 },
    DEFAULT = { 19 * 60 + 30, 23 * 60 },     -- a team's first night: 19:30 - 23:00
}

local function Nights() return ns.RaidNights end

-- The tooltip: each night with its hours, the optional ones said, the note, the clock.
function TV.nightsTooltip(owner, list, note, editable)
    local RN = Nights()
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Raid nights")
    for _, x in ipairs(RN:LocalList(list)) do
        GameTooltip:AddDoubleLine(RN.DAYS[x.d] .. (x.o and colorize("9e9e9e", "  optional") or ""),
            RN:Clock(x.s) .. " – " .. RN:Clock(x.e), 1, 1, 1, 1, 1, 1)
    end
    if note then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("\"" .. note .. "\"", 0.85, 0.85, 0.85, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("In your clock. Optional nights: come if you can.", 0.6, 0.6, 0.6, true)
    if editable then GameTooltip:AddLine("Click to change them.", 0.6, 0.6, 0.6, true) end
    GameTooltip:Show()
end

-- The week strip: M T W T F S S, a raid night lit (core: gold fill and edge; optional: a hollow gold edge).
function TV.newWeekStrip(parent)
    local N = TV.N
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(7 * N.CELL + 6 * N.CELL_GAP, N.CELL_H)
    f.cells = {}
    for i = 1, 7 do
        local c = CreateFrame("Frame", nil, f)
        c:SetSize(N.CELL, N.CELL_H)
        c:SetPoint("LEFT", f, "LEFT", (i - 1) * (N.CELL + N.CELL_GAP), 0)
        c.bg = c:CreateTexture(nil, "BACKGROUND")
        c.bg:SetAllPoints()
        UI():AddEdges(c, "BORDER")
        c.fs = textOf(c, "GameFontHighlightSmall", 10)
        c.fs:SetJustifyH("CENTER")
        c.fs:SetPoint("CENTER", 1, 0)
        c.fs:SetText(Nights().LETTERS[i])
        f.cells[i] = c
    end
    return f
end

function TV.paintWeekStrip(f, list)
    local by = {}
    for _, x in ipairs(Nights():LocalList(list)) do
        -- (two nights on one day of my week: the core one shows)
        if not by[x.d] or by[x.d].o then by[x.d] = x end
    end
    for i, c in ipairs(f.cells) do
        local x = by[i]
        if x and not x.o then
            c.bg:SetColorTexture(1, 0.82, 0, 0.22)
            UI():SetEdgeColor(c, 1, 0.82, 0, 0.9)
            c.fs:SetTextColor(1, 0.86, 0.2)
        elseif x then
            c.bg:SetColorTexture(1, 0.82, 0, 0.03)
            UI():SetEdgeColor(c, 1, 0.82, 0, 0.42)
            c.fs:SetTextColor(0.86, 0.74, 0.4)
        else
            c.bg:SetColorTexture(0, 0, 0, 0.32)
            UI():SetEdgeColor(c, 1, 1, 1, 0.07)
            c.fs:SetTextColor(0.42, 0.42, 0.45)
        end
    end
end

-- A banner's block: RAID NIGHTS, the strip, the hours. Editable (organizers, on the team's banner): a gold kicker and
-- a pencil on hover, a click opens the editor; without nights "+ Set raid nights".
function TV.newNightsBlock(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(160, 52)
    b.kick = textOf(b, "GameFontNormalSmall", 10)
    b.kick:SetTextColor(0.72, 0.72, 0.72)
    b.kick:SetPoint("TOPLEFT", 0, 0)
    b.kick:SetText("RAID NIGHTS")
    b.pen = b:CreateTexture(nil, "ARTWORK")
    b.pen:SetSize(10, 10)
    b.pen:SetTexture(UI().ICON_ATLAS)
    b.pen:SetTexCoord(unpack(UI():IconCoords(16)))
    b.pen:SetVertexColor(1, 0.82, 0)
    b.pen:SetPoint("LEFT", b.kick, "RIGHT", 5, 0)
    b.pen:Hide()
    b.strip = TV.newWeekStrip(b)
    b.strip:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -15)
    b.times = textOf(b, "GameFontHighlightSmall", 11)
    b.times:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -41)
    b.add = textOf(b, "GameFontHighlight", 13)
    b.add:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -17)
    b.add:SetText(colorize("ffd100", "+") .. "  Set raid nights")
    b.addSub = textOf(b, "GameFontHighlightSmall", 11)
    b.addSub:SetTextColor(0.55, 0.55, 0.57)
    b.addSub:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -38)
    b.addSub:SetText("When the team is expected online")
    b:SetScript("OnEnter", function(self)
        if self.editable then
            self.kick:SetTextColor(1, 0.82, 0)
            self.pen:Show()
        end
        if self.list and #self.list > 0 then TV.nightsTooltip(self, self.list, self.note, self.editable) end
    end)
    b:SetScript("OnLeave", function(self)
        self.kick:SetTextColor(0.72, 0.72, 0.72)
        self.pen:Hide()
        hideTooltip()
    end)
    b:SetScript("OnClick", function(self) if self.editable then TV.openNights(self) end end)
    return b
end

-- Fills a block (list / note: wire nights and the note). Shown with nights, or for organizers ("Set raid nights").
function TV.paintNightsBlock(b, list, note, editable)
    b.list, b.note, b.editable = list, note, editable
    local has = list ~= nil and #list > 0
    b.strip:SetShown(has)
    b.times:SetShown(has)
    b.add:SetShown(not has and editable)
    b.addSub:SetShown(not has and editable)
    b:EnableMouse(has or editable)
    if has then
        TV.paintWeekStrip(b.strip, list)
        local times, opt = Nights():TimesText(list)
        b.times:SetText(colorize("e6e6e6", times) .. (opt and colorize("8c8c8c", "  ·  " .. opt) or ""))
    end
    -- (as wide as what it says: it never reaches under the next raid on its right)
    local w = (b.kick:GetStringWidth() or 70) + 18
    if has then w = max(w, b.strip:GetWidth(), b.times:GetStringWidth() or 0)
    else w = max(w, b.add:GetStringWidth() or 0, b.addSub:GetStringWidth() or 0) end
    b:SetWidth(ceil(w + 2))
    b:SetShown(has or editable)
end

-- A board banner (TV.fillTeamCard): the block at N.X, the name kept left of it.
function TV.paintBoardNights(c, tm)
    c.nights = c.nights or TV.newNightsBlock(c)
    TV.paintNightsBlock(c.nights, tm.nights, tm.note, false)
    c.nights:ClearAllPoints()
    c.nights:SetPoint("TOPLEFT", c, "TOPLEFT", TV.N.X, -18)
    if c.nights:IsShown() and (c.t1:GetStringWidth() or 0) > TV.N.X - 18 - 24 then setSize(c.t1, 16) end
end

-- The team's banner (TV.fillCard): the block with the draft's nights; organizers edit them.
function TV.paintHeroNights(dr, organizer)
    local card = teamsView.card
    card.nights = card.nights or TV.newNightsBlock(card)
    TV.paintNightsBlock(card.nights, dr.nights, dr.note, organizer)
    card.nights:ClearAllPoints()
    card.nights:SetPoint("TOPLEFT", card, "TOPLEFT", TV.N.X, -14)
    if not organizer and card.nights:IsShown() and (card.title:GetStringWidth() or 0) > TV.N.X - 12 - 28 then
        setSize(card.title, 16)
    end
    -- (the next raid's button only as wide as its lines, so the two never overlap)
    local nx = card.next
    if nx:IsShown() then
        local lw = (nx.line:GetStringWidth() or 0) + (nx.lock:IsShown() and 16 or 0)
        local sw = (nx.sub:GetStringWidth() or 0) + (nx.icon:IsShown() and 16 or 0)
            + (nx.extra:IsShown() and (nx.extra:GetWidth() + 6) or 0)
        nx:SetWidth(ceil(max(lw, sw, nx.label:GetStringWidth() or 0) + 2))
    end
    -- (and "No raid invites this team yet" in the room right of the block, on more lines)
    local right = teamsView.detail.moreBtn:IsShown() and 40 or 16
    local room = card.nights:IsShown() and (TV.W - right - (TV.N.X + card.nights:GetWidth() + 24)) or 300
    card.note:SetWidth(floor(max(150, min(300, room))))
    TV.fillNightsPanel()
end

---------------------------------------------------------------------------
-- The editor: drops from the banner's block. Day tiles add or take off a night; each night a row (from, to,
-- Optional); the note; Done. It changes the draft: Save / Undo on the tool row.
---------------------------------------------------------------------------

function TV.flatCell(f)
    local N = TV.N
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    UI():AddEdges(f, "BORDER")
    function f:Paint(picked)
        local bg = picked and N.PICKED_BG or N.CELL_BG
        self.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
        if picked then UI():SetEdgeColor(self, N.GOLD[1], N.GOLD[2], N.GOLD[3], 1)
        else UI():SetEdgeColor(self, N.EDGE[1], N.EDGE[2], N.EDGE[3], 1) end
    end
    f:Paint(false)
    local hl = f:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.05)
    return f
end

-- A time stepper: the arrows (and the mouse wheel) move it a quarter of an hour; onStep(dir).
function TV.newStepper(parent, w, onStep)
    local s = TV.flatCell(CreateFrame("Frame", nil, parent))
    s:SetSize(w, 26)
    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(_, delta) onStep(delta > 0 and 1 or -1) end)
    s.down = UI():CreateArrowButton(s, false, 20, 24, function() onStep(-1) end)
    s.down:SetPoint("LEFT", 1, 0)
    s.up = UI():CreateArrowButton(s, true, 20, 24, function() onStep(1) end)
    s.up:SetPoint("RIGHT", -1, 0)
    s.fs = textOf(s, "GameFontHighlight", 13)
    s.fs:SetJustifyH("CENTER")
    s.fs:SetPoint("CENTER", 0, 0)
    return s
end

function TV.createNightsPanel()
    local N = TV.N
    local p = CreateFrame("Frame", nil, UIParent)
    p:SetFrameStrata("DIALOG")
    p:SetToplevel(true)
    p:SetClampedToScreen(true)
    p:EnableMouse(true)
    p:SetSize(N.PANEL_W, 200)
    for i, o in ipairs({ { 0, -10, 0.35 }, { 0, -3, 0.45 } }) do
        local sh = p:CreateTexture(nil, "BACKGROUND", nil, -8 + i)
        sh:SetPoint("TOPLEFT", -3 - o[1], 1 + o[2] / 3)
        sh:SetPoint("BOTTOMRIGHT", 3 + o[1], o[2])
        sh:SetColorTexture(0, 0, 0, o[3])
    end
    p.bg = p:CreateTexture(nil, "BACKGROUND", nil, 0)
    p.bg:SetAllPoints()
    p.bg:SetColorTexture(0.078, 0.078, 0.09, 1)
    UI():AddEdges(p, "BORDER")
    UI():SetEdgeColor(p, 1, 1, 1, 0.11)
    p.title = textOf(p, "GameFontNormalSmall", 10)
    p.title:SetTextColor(0.69, 0.69, 0.71)
    p.title:SetPoint("LEFT", p, "TOPLEFT", 14, -20)
    p.title:SetText("RAID NIGHTS")
    p.clock = textOf(p, "GameFontHighlightSmall", 11)
    p.clock:SetTextColor(0.5, 0.5, 0.52)
    p.clock:SetJustifyH("RIGHT")
    p.clock:SetPoint("RIGHT", p, "TOPRIGHT", -14, -20)
    p.clock:SetText("Times in your clock")
    -- the days: a tile each, picked = a raid night
    local inner = N.PANEL_W - 28
    local tw = floor((inner - 6 * 3) / 7)
    p.tiles = {}
    for i = 1, 7 do
        local t = TV.flatCell(CreateFrame("Button", nil, p))
        t:SetSize(tw, N.TILE_H)
        t:SetPoint("TOPLEFT", p, "TOPLEFT", 14 + (i - 1) * (tw + 3), -36)
        t.fs = textOf(t, "GameFontHighlight", 12)
        t.fs:SetJustifyH("CENTER")
        t.fs:SetPoint("CENTER", 0, 0)
        t.fs:SetText(Nights().SHORT[i])
        t.d = i
        t:SetScript("OnClick", function(self) PlanUI:ToggleDraftNight(self.d) end)
        p.tiles[i] = t
    end
    p.rows = {}
    p.empty = textOf(p, "GameFontHighlightSmall", 11)
    p.empty:SetTextColor(0.55, 0.55, 0.57)
    p.empty:SetText("Pick the nights the team raids.")
    p.note = UI():CreateSleekEditBox(p, inner, 26, "GameFontHighlightSmall")
    p.note:SetMaxLetters(Nights().MAX_NOTE)
    p.note:SetAutoFocus(false)
    p.note:SetTextColor(0.92, 0.92, 0.92)
    p.note:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    p.note:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    p.note:HookScript("OnTextChanged", function(self, user)
        if not user then return end
        local dr = state.draft
        if not dr then return end
        local text = ns.Util.Trim(self:GetText() or "")
        dr.note = text ~= "" and text or nil
        PlanUI:RefreshTeamButtons()
    end)
    UI():SetEditPlaceholder(p.note, "Note (optional): \"online 15 min before invites\"")
    p.rule = p:CreateTexture(nil, "BORDER")
    p.rule:SetHeight(1)
    p.rule:SetColorTexture(1, 1, 1, 0.06)
    p.foot = textOf(p, "GameFontHighlightSmall", 11)
    p.foot:SetTextColor(0.45, 0.45, 0.48)
    p.foot:SetText("Saved with the team: Save, or Undo")
    p.done = UI():CreateSleekButton(p, "Done", 64, 22, function() p:Hide() end, "primary")
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("DIALOG")
    catcher:SetFrameLevel(max(0, p:GetFrameLevel() - 1))
    catcher:RegisterForClicks("AnyUp")
    catcher:SetScript("OnClick", function() p:Hide() end)
    catcher:Hide()
    p.catcher = catcher
    p:SetScript("OnShow", function() catcher:Show() end)
    p:SetScript("OnHide", function()
        catcher:Hide()
        p.note:ClearFocus()
        -- (the block shows the note in its tooltip; the banner says "changed, not saved")
        if teamsView and teamsView:IsShown() then PlanUI:RefreshTeams() end
    end)
    p:Hide()
    teamsView.nightsPanel = p
    return p
end

function TV.newNightRow(p)
    local N = TV.N
    local r = CreateFrame("Frame", nil, p)
    r:SetSize(N.PANEL_W - 28, N.ROW_H)
    r.rule = r:CreateTexture(nil, "BORDER")
    r.rule:SetPoint("TOPLEFT", 0, 0)
    r.rule:SetPoint("TOPRIGHT", 0, 0)
    r.rule:SetHeight(1)
    r.rule:SetColorTexture(1, 1, 1, 0.05)
    r.day = textOf(r, "GameFontHighlight", 13)
    r.day:SetPoint("LEFT", r, "LEFT", 0, 0)
    r.from = TV.newStepper(r, 84, function(dir) if r.x then PlanUI:StepDraftNight(r.x.d, "s", dir) end end)
    r.from:SetPoint("LEFT", r, "LEFT", 88, 0)
    r.dash = textOf(r, "GameFontHighlight", 13)
    r.dash:SetTextColor(0.5, 0.5, 0.52)
    r.dash:SetText("–")
    r.dash:SetPoint("LEFT", r.from, "RIGHT", 6, 0)
    r.to = TV.newStepper(r, 84, function(dir) if r.x then PlanUI:StepDraftNight(r.x.d, "e", dir) end end)
    r.to:SetPoint("LEFT", r.from, "RIGHT", 20, 0)
    r.opt = UI():CreateSwitch(r, nil, function(on) if r.x then PlanUI:SetDraftNightOptional(r.x.d, on) end end,
        "Optional")
    setSize(r.opt.label, 12)
    r.opt.label:SetTextColor(0.78, 0.78, 0.8)
    r.opt:SetPoint("LEFT", r.to, "RIGHT", 16, 0)
    r.opt:HookScript("OnEnter", function(self)
        UI():SetTextTooltip(self, { "Optional", "A night players come to when they can; the others are core nights." },
            "ANCHOR_TOP")
    end)
    r.opt:HookScript("OnLeave", hideTooltip)
    return r
end

function TV.fillNightsPanel()
    local p = teamsView and teamsView.nightsPanel
    local dr = state.draft
    if not (p and p:IsShown() and dr) then return end
    local N, RN = TV.N, Nights()
    local loc = RN:LocalList(dr.nights)
    local by = {}
    for _, x in ipairs(loc) do by[x.d] = x end
    for i, t in ipairs(p.tiles) do
        local on = by[i] ~= nil
        t:Paint(on)
        t.fs:SetTextColor(on and 1 or 0.62, on and 0.86 or 0.62, on and 0.2 or 0.64)
    end
    local y = 36 + N.TILE_H + 10
    for i, x in ipairs(loc) do
        local r = p.rows[i] or TV.newNightRow(p)
        p.rows[i] = r
        r.x = x
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -y)
        r.day:SetText(RN.DAYS[x.d])
        r.day:SetTextColor(x.o and 0.78 or 1, x.o and 0.78 or 1, x.o and 0.8 or 1)
        r.from.fs:SetText(RN:Clock(x.s))
        r.to.fs:SetText(RN:Clock(x.e))
        r.opt:SetChecked(x.o)
        r:Show()
        y = y + N.ROW_H
    end
    for i = #loc + 1, #p.rows do
        p.rows[i]:Hide()
        p.rows[i].x = nil
    end
    p.empty:SetShown(#loc == 0)
    if #loc == 0 then
        p.empty:ClearAllPoints()
        p.empty:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -(y + 2))
        y = y + 22
    end
    p.note:ClearAllPoints()
    p.note:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -(y + 4))
    if not p.note:HasFocus() and (p.note:GetText() or "") ~= (dr.note or "") then p.note:SetText(dr.note or "") end
    y = y + 4 + 26 + 12
    p.rule:ClearAllPoints()
    p.rule:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -y)
    p.rule:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, -y)
    p.foot:ClearAllPoints()
    p.foot:SetPoint("LEFT", p, "TOPLEFT", 14, -(y + 20))
    p.done:ClearAllPoints()
    p.done:SetPoint("RIGHT", p, "TOPRIGHT", -14, -(y + 20))
    p:SetHeight(y + 40)
end

-- Opens (or closes) the editor under owner (the banner's block).
function TV.openNights(owner)
    if not RP():CanManageTeams() or not state.draft then return end
    local p = (teamsView and teamsView.nightsPanel) or TV.createNightsPanel()
    if p:IsShown() then return p:Hide() end
    p.owner = owner
    p:SetScale((teamsView:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1))
    p:Show()
    TV.fillNightsPanel()
    hideTooltip()
    UI():DropIn(p, function(dx, dy)
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", -14 + dx, -8 + dy)
    end)
end

function TV.closeNights()
    local p = teamsView and teamsView.nightsPanel
    if p and p:IsShown() then p:Hide() end
end

-- The draft's night on day d of my week (its index in dr.nights and its local form), or nil.
function TV.draftNight(d)
    local dr = state.draft
    for _, x in ipairs(Nights():LocalList(dr and dr.nights)) do
        if x.d == d then
            for i, n in ipairs(dr.nights) do
                if n == x.n then return i, x end
            end
        end
    end
    return nil
end

function TV.nightsChanged()
    PlanUI:RefreshTeams()
    TV.fillNightsPanel()
end

-- Day d (1 = Monday, my clock) a raid night or not; a new night takes the hours of the one before it.
function PlanUI:ToggleDraftNight(d)
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return false end
    dr.nights = dr.nights or {}
    local i = TV.draftNight(d)
    if i then
        table.remove(dr.nights, i)
    else
        if #dr.nights >= Nights().MAX then return false end
        local loc = Nights():LocalList(dr.nights)
        local last = loc[#loc]
        local s, e = last and last.s or TV.N.DEFAULT[1], last and last.e or TV.N.DEFAULT[2]
        dr.nights[#dr.nights + 1] = Nights():FromLocal(d, s, e)
    end
    TV.nightsChanged()
    return true
end

-- Moves the start ("s") or the end ("e") of day d's night a quarter of an hour (dir -1 / 1); a night never lasts
-- no time.
function PlanUI:StepDraftNight(d, field, dir)
    local dr = state.draft
    local i, x = TV.draftNight(d)
    if not i or not RP():CanManageTeams() then return false end
    local s, e = x.s, x.e
    if field == "s" then s = (s + dir * 15) % 1440 else e = (e + dir * 15) % 1440 end
    local n = Nights():FromLocal(x.d, s, e, x.o)
    if not n then return false end
    dr.nights[i] = n
    TV.nightsChanged()
    return true
end

function PlanUI:SetDraftNightOptional(d, on)
    local dr = state.draft
    local i = TV.draftNight(d)
    if not i or not RP():CanManageTeams() then return false end
    dr.nights[i].o = on and true or nil
    TV.nightsChanged()
    return true
end

function PlanUI:SetDraftNightsNote(text)
    local dr = state.draft
    if not dr then return end
    text = ns.Util.Trim(text or "")
    dr.note = text ~= "" and text or nil
    PlanUI:RefreshTeams()
end

function PlanUI:OpenNightsEditor()
    local card = teamsView and teamsView.card
    if card and card.nights and card.nights:IsShown() then TV.openNights(card.nights) end
end

function PlanUI:GetNightsEditor() return teamsView and teamsView.nightsPanel end

---------------------------------------------------------------------------
-- The waitlist panel (someone not on the roster): the nights above Join, so they know what they sign up for.
---------------------------------------------------------------------------

function TV.wlNights(p, dr, y)
    local list = dr.nights
    local show = list ~= nil and #list > 0 and TV.notOnRoster(dr)
    if not p.nt then
        local f = CreateFrame("Frame", nil, p)
        f:SetSize(TV.WL.W - 24, 60)
        f.rule = f:CreateTexture(nil, "BORDER")
        f.rule:SetPoint("TOPLEFT", 0, 0)
        f.rule:SetPoint("TOPRIGHT", 0, 0)
        f.rule:SetHeight(1)
        f.rule:SetColorTexture(1, 1, 1, 0.06)
        f.kick = textOf(f, "GameFontNormalSmall", 10)
        f.kick:SetTextColor(0.69, 0.69, 0.71)
        f.kick:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -16)
        f.kick:SetText("RAID NIGHTS")
        f.strip = TV.newWeekStrip(f)
        f.strip:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -11)
        f.days = textOf(f, "GameFontHighlight", 13)
        f.days:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -38)
        f.times = textOf(f, "GameFontHighlightSmall", 11)
        f.times:SetPoint("LEFT", f.days, "RIGHT", 8, -1)
        f.note = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        setSize(f.note, 11)
        f.note:SetWidth(TV.WL.W - 24)
        f.note:SetJustifyH("LEFT")
        f.note:SetWordWrap(true)
        f.note:SetSpacing(2)
        f.note:SetTextColor(0.62, 0.62, 0.64)
        f.note:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -58)
        p.nt = f
    end
    local f = p.nt
    f:SetShown(show)
    if not show then return y end
    TV.paintWeekStrip(f.strip, list)
    f.days:SetText(Nights():DaysText(list))
    local times, opt = Nights():TimesText(list)
    f.times:SetText(colorize("c8c8c8", times) .. (opt and colorize("808080", "  ·  " .. opt) or ""))
    f.note:SetText(dr.note and ("\"" .. dr.note .. "\"") or "")
    local h = 58 + (dr.note and ((f.note:GetStringHeight() or 14) + 4) or 0) + 4
    f:SetHeight(h)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -(y + 2))
    return y + h
end

---------------------------------------------------------------------------
-- The board: every team as a banner of its theme's loading screen (whose team, its name, players and lineups on the
-- left; the next raid and how full it is on the right). Mine first, under "Your teams"; a click opens one.
---------------------------------------------------------------------------

function TV.createBoard(t)
    local b = CreateFrame("Frame", nil, t)
    b:SetAllPoints()
    b:Hide()
    t.board = b
    b.scroll = UI():CreateScrollFrame(b)
    b.scroll:SetPoint("TOPLEFT", b, "TOPLEFT", PAD, 0)
    b.scroll:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -PAD, 0)
    b.content = CreateFrame("Frame", nil, b.scroll)
    b.content:SetSize(TV.W, 10)
    b.scroll:SetScrollChild(b.content)
    b.cards, b.heads = {}, {}
    for i = 1, 2 do
        local h = textOf(b.content, "GameFontNormalSmall", 10)
        h:SetTextColor(0.55, 0.55, 0.55)
        b.heads[i] = h
    end
end

function TV.newTeamCard(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(TV.BANNER_H)
    c.bg = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    c.bg:SetAllPoints()
    c.bg:SetColorTexture(0.055, 0.055, 0.067, 1)
    c.art = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.art:SetAllPoints()
    c.art:SetVertexColor(0.85, 0.85, 0.85)
    local split = floor(TV.W * 0.6)
    c.fadeL = c:CreateTexture(nil, "BACKGROUND", nil, 3)
    c.fadeL:SetPoint("TOPLEFT", 0, 0)
    c.fadeL:SetPoint("BOTTOMLEFT", 0, 0)
    c.fadeL:SetWidth(split)
    gradient(c.fadeL, "HORIZONTAL", 0.055, 0.055, 0.067, 0.96, 0.28)
    c.fadeR = c:CreateTexture(nil, "BACKGROUND", nil, 3)
    c.fadeR:SetPoint("TOPLEFT", c.fadeL, "TOPRIGHT", 0, 0)
    c.fadeR:SetPoint("BOTTOMRIGHT", 0, 0)
    gradient(c.fadeR, "HORIZONTAL", 0.055, 0.055, 0.067, 0.28, 0.72)
    UI():AddEdges(c, "BORDER")
    UI():SetEdgeColor(c, 1, 1, 1, 0.07)
    c.dot = c:CreateTexture(nil, "ARTWORK")
    c.dot:SetSize(6, 6)
    c.dot:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    c.dot:SetVertexColor(1, 0.82, 0)
    c.dot:SetPoint("TOPLEFT", 18, -20)
    c.kick = textOf(c, "GameFontNormalSmall", 10)
    c.kick:SetTextColor(0.72, 0.72, 0.72)
    c.t1 = textOf(c, "GameFontHighlightLarge", 20)
    c.t1:SetPoint("TOPLEFT", 18, -33)
    c.t2 = textOf(c, "GameFontHighlightSmall", 11)
    c.t2:SetTextColor(0.66, 0.66, 0.66)
    c.t2:SetPoint("TOPLEFT", 18, -63)
    -- the next raid, on the right
    c.r1 = textOf(c, "GameFontNormalSmall", 10)
    c.r1:SetTextColor(0.72, 0.72, 0.72)
    c.r1:SetJustifyH("RIGHT")
    c.r1:SetPoint("TOPRIGHT", -18, -18)
    c.r1:SetText("NEXT RAID")
    c.r2 = textOf(c, "GameFontHighlight", 13)
    c.r2:SetJustifyH("RIGHT")
    c.r2:SetPoint("TOPRIGHT", -18, -35)
    c.r3 = textOf(c, "GameFontHighlightSmall", 11)
    c.r3:SetJustifyH("RIGHT")
    c.r3:SetPoint("TOPRIGHT", -18, -58)
    c.track = c:CreateTexture(nil, "ARTWORK")
    c.track:SetSize(110, 3)
    c.track:SetColorTexture(1, 1, 1, 0.14)
    c.fill = c:CreateTexture(nil, "ARTWORK", nil, 1)
    c.fill:SetHeight(3)
    c.fill:SetPoint("LEFT", c.track, "LEFT", 0, 0)
    c:SetScript("OnEnter", function(self) UI():SetEdgeColor(self, 1, 0.82, 0, 0.55) end)
    c:SetScript("OnLeave", function(self) UI():SetEdgeColor(self, 1, 1, 1, 0.07) end)
    c:SetScript("OnClick", function(self) if self.id then PlanUI:SelectTeam(self.id) end end)
    return c
end

function TV.fillTeamCard(c, tm, mine, width)
    c.id = tm.id
    c:SetWidth(width)
    local raids = TV.raids(tm.id)
    local v = raids[1]
    local th = TV.themeOf(tm.theme, v, tm.id)
    c.th = th
    local file, l, r, tt, bb = artCoords(th, width, TV.BANNER_H, 0.95)
    c.art:SetTexture(file)
    c.art:SetTexCoord(l, r, tt, bb)
    c.dot:SetShown(mine)
    c.kick:ClearAllPoints()
    c.kick:SetPoint("LEFT", c, "TOPLEFT", mine and 30 or 18, -20)
    c.kick:SetText(mine and "YOUR TEAM" or "TEAM")
    c.t1:SetText(tm.name)
    setSize(c.t1, 20)
    if (c.t1:GetStringWidth() or 0) > width - 18 - 260 then setSize(c.t1, 16) end
    local n = #tm.members
    local nl = #tm.lineups
    local lineups
    if nl == 1 then
        local dr = { lineups = { { name = tm.lineups[1].name, sz = tm.lineups[1].size } } }
        lineups = TV.lineupName(dr, 1)
    else
        lineups = nl .. " lineups"
    end
    c.t2:SetText((n == 1 and "1 player" or (n .. " players")) .. "   ·   " .. lineups)
    if v then
        local insts = RP():GetRaidInstances(v)
        local inst = RP():GetInstance(v.i)
        local name = #insts > 1 and instNames(v, true) or (inst and inst.name) or "Raid"
        c.r2:SetText(colorize("ffd100", TV.day(v.t):upper()) .. "   " .. name)
        if (c.r2:GetStringWidth() or 0) > 250 and #insts <= 1 and TV.SHORT[v.i] then
            c.r2:SetText(colorize("ffd100", TV.day(v.t):upper()) .. "   " .. TV.SHORT[v.i])
        end
        local acc, of = TV.accepted(v, tm)
        c.r3:SetText(colorize("ffffff", acc) .. colorize("808080", "/" .. of))
        c.track:ClearAllPoints()
        c.track:SetPoint("RIGHT", c.r3, "LEFT", -8, 0)
        c.track:Show()
        local share = of > 0 and min(1, acc / of) or 0
        c.fill:SetShown(share > 0)
        c.fill:SetWidth(max(1, floor(110 * share + 0.5)))
        c.fill:SetColorTexture(0.56, 0.89, 0.62, 1)
    else
        c.r2:SetText(grey("None planned"))
        c.r3:SetText("")
        c.track:Hide()
        c.fill:Hide()
    end
    TV.paintBoardNights(c, tm)
    c:Show()
end

function TV.fillBoard(teams)
    local b = teamsView.board
    local mineList, others = {}, {}
    for _, tm in ipairs(teams) do
        if TV.myKey(tm.members) then mineList[#mineList + 1] = tm else others[#others + 1] = tm end
    end
    local sections = {}
    if #mineList > 0 then sections[#sections + 1] = { "YOUR TEAMS", mineList, true } end
    if #others > 0 then sections[#sections + 1] = { #mineList > 0 and "OTHER TEAMS" or "TEAMS", others, false } end
    local y, k = 0, 0
    for si, sec in ipairs(sections) do
        local h = b.heads[si]
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", b.content, "TOPLEFT", 2, -(y + 8))
        h:SetText(sec[1])
        h:Show()
        y = y + 24
        for _, tm in ipairs(sec[2]) do
            k = k + 1
            local c = b.cards[k] or TV.newTeamCard(b.content)
            b.cards[k] = c
            TV.fillTeamCard(c, tm, sec[3], TV.W)
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", b.content, "TOPLEFT", 0, -y)
            y = y + TV.BANNER_H + GAP
        end
        y = y + 4
    end
    for i = #sections + 1, #b.heads do b.heads[i]:Hide() end
    for i = k + 1, #b.cards do b.cards[i]:Hide() end
    b.content:SetHeight(max(10, y))
end

-- Back to the board (asks first while the open team has unsaved changes).
function PlanUI:ShowTeamBoard()
    TV.closeNights()
    TV.guard(function()
        state.board = true
        if state.newTeam then
            state.newTeam, state.draft = nil, nil
        elseif state.team then
            TV.load(state.team)
        end
        PlanUI:RefreshTeams()
    end)
end

function PlanUI:IsTeamBoard() return teamsView ~= nil and teamsView.board:IsShown() end

---------------------------------------------------------------------------
-- The Comp view: tabs, Start from, the columns, the bench, the steppers, the empty card
---------------------------------------------------------------------------

function TV.setTab(key)
    local prev = state.teamTab == "comp" and "comp" or "groups"
    state.teamTab = key == "comp" and "comp" or "groups"
    if teamsView then teamsView.detail.steps:Hide() end
    -- (a motion still running ends first: the refresh lays the views out where they belong)
    if TV.anim then TV.endAnim() end
    local th = teamsView and teamsView.detail.seg.thumb
    local fx, fw = th and th.x, th and th.w
    PlanUI:RefreshTeams()
    if prev ~= state.teamTab then TV.animateTab(state.teamTab, fx, fw) end
end

-- A "+" or "-" drawn on a small sleek button.
function TV.glyph(b, plus)
    local h = b:CreateTexture(nil, "OVERLAY")
    h:SetSize(8, 2)
    h:SetPoint("CENTER", 0, 0)
    h:SetColorTexture(0.9, 0.9, 0.9, 1)
    if plus then
        local v = b:CreateTexture(nil, "OVERLAY")
        v:SetSize(2, 8)
        v:SetPoint("CENTER", 0, 0)
        v:SetColorTexture(0.9, 0.9, 0.9, 1)
    end
    b:SetScript("OnMouseDown", nil)
    b:SetScript("OnMouseUp", nil)
end

-- Start from: "Standard 25  3 tanks · 6 healers · 7 melee · 9 ranged".
function TV.startSub(s)
    if s.kind == "team" then return ("a slot per spec in the groups (%d)"):format(ns.RaidComp:CompSize(s.cp)) end
    if s.kind == "copy" then return ("its %d slots"):format(ns.RaidComp:CompSize(s.cp)) end
    local rc = ns.RaidComp:RoleCounts(s.cp)
    return ("%d tanks · %d healers · %d melee · %d ranged"):format(rc.tank, rc.healer, rc.melee, rc.ranged)
end

function TV.startName(s)
    return s.kind == "copy" and (s.name .. "'s comp") or s.name
end

function TV.startFrom(s)
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return end
    dr.cp = ns.RaidComp:CopyComp(s.cp) or {}
    PlanUI:RefreshTeams()
end

function TV.startMenu(root)
    local dr = state.draft
    if not dr then return end
    root:CreateTitle("Start from")
    for _, s in ipairs(RP():GetCompStarts(TV.ref(dr))) do
        root:CreateButton(TV.startName(s) .. "  " .. colorize("9e9e9e", TV.startSub(s)), function() TV.startFrom(s) end)
    end
    if TV.comp(dr) then
        if root.CreateDivider then root:CreateDivider() end
        root:CreateButton("No comp", function()
            dr.cp = {}
            PlanUI:RefreshTeams()
        end)
    end
end

-- A slot of a column: who fills it (class circle, name, spec icon), or open (a gold ring with the class faint
-- inside, the spec's name in gold).
function TV.newSlotRow(col)
    local b = CreateFrame("Button", nil, col)
    b:SetHeight(TV.TILE_H)
    b:RegisterForClicks("LeftButtonUp")
    ns.RaidGroupsUI:DecoratePlate(b)
    b.fs = b.pName
    -- (my own slot, for a member: kept for the shared checks; the plate's gold rim shows it)
    b.me = b:CreateTexture(nil, "BACKGROUND")
    b.me:SetAllPoints()
    b.me:SetColorTexture(1, 0.82, 0, 0)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.045)
    b:SetScript("OnEnter", TV.slotTooltip)
    b:SetScript("OnLeave", hideTooltip)
    b:SetScript("OnClick", function(self)
        if RP():CanManageTeams() and self.role then TV.openSteps(self.role, self) end
    end)
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function(self) TV.compDragStart(self) end)
    b:SetScript("OnDragStop", function() ns.RaidGroupsUI:EndCardDrag() end)
    return b
end

-- A slot: taken, the player's plate (my own with a gold rim); open, its ghost (the spec greyed, how many could fill).
function TV.fillSlotRow(b, slot, organizer, mine)
    b.slot, b.role = slot, slot.role
    local m = slot.member
    local G = ns.RaidGroupsUI
    if m then
        G:PaintPlate(b, G:PlayerPlate({ key = m.key, c = m.c, sp = m.sp }, mine and "me" or nil))
    else
        G:PaintPlate(b, G:GhostPlate({ c = slot.c, sp = slot.sp, name = slot.name,
                                       canFill = TV.canFillCount(state.draft, slot.c, slot.sp) }))
    end
    b.me:SetShown(mine == true)
    b:Show()
end

function TV.slotTooltip(self)
    local slot = self.slot
    if not slot then return end
    local organizer = RP():CanManageTeams()
    if not slot.member then
        TV.canFillTooltip(self, slot.c, slot.sp)
    else
        local m = slot.member
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(colored(m.key, m.c) .. (TV.isMine(m.key) and " |cff9e9e9e(you)|r" or ""))
        GameTooltip:AddLine(slot.name, 1, 1, 1)
        local src = m.source == "team" and "Spec set in the team" or m.source == "bis" and "Spec from their BiS list"
            or m.source == "signup" and "Spec from their last sign-up" or nil
        if src then GameTooltip:AddLine(src, 0.6, 0.6, 0.6) end
    end
    if organizer then
        GameTooltip:AddLine(" ")
        if slot.member then
            GameTooltip:AddLine("Drag to Unassigned to take them out of the groups.", 0.6, 0.6, 0.6, true)
        else
            GameTooltip:AddLine("Drag a player from Unassigned here to fill it.", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:AddLine("Click to change this role's slots.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

-- A chip under the comp's columns (chip.kind: "unassigned", "waitlist" or "beyond" the comp): class circle, name,
-- spec icon (the Sign-ups' boxes look).
function TV.newBenchChip(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(TV.TILE_H)
    b:RegisterForClicks("LeftButtonUp")
    ns.RaidGroupsUI:DecoratePlate(b)
    b.fs = b.pName
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.045)
    b:SetScript("OnEnter", function(self)
        local m = self.member
        if not m then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(colored(m.key, m.c) .. (TV.isMine(m.key) and " |cff9e9e9e(you)|r" or ""))
        local label = m.sp and ns.RaidComp:SlotName(m.c, m.sp)
        GameTooltip:AddLine(label or ((ns.RaidComp:ClassName(m.c) or "") .. " · spec unknown"), 1, 1, 1)
        local kind = self.kind
        GameTooltip:AddLine(kind == "unassigned" and "Unassigned: on the roster, in none of this lineup's groups."
            or kind == "waitlist" and ("Waitlist #%d: not on the roster yet."):format(m.n or 0)
            or "In a group, beyond the comp.", 0.6, 0.6, 0.6, true)
        if RP():CanManageTeams() then
            GameTooltip:AddLine(kind == "unassigned" and "Drag onto an open slot to fill it, or click to put them in a "
                .. "group or change the spec."
                or kind == "waitlist" and "Click to move them in line, onto the roster or off the waitlist."
                or "Drag onto an open slot to play its spec, or click to add a slot or change the spec.",
                0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", hideTooltip)
    b:SetScript("OnClick", function(self) TV.benchMenu(self) end)
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function(self) TV.compDragStart(self) end)
    b:SetScript("OnDragStop", function() ns.RaidGroupsUI:EndCardDrag() end)
    return b
end

function TV.benchMenu(chip)
    local m, dr = chip.member, state.draft
    if not m or not dr or not RP():CanManageTeams() then return end
    local key = m.key
    if chip.kind == "waitlist" then
        return UI():ContextMenu(chip, function(root) TV.waitMenu(root, key) end)
    end
    UI():ContextMenu(chip, function(root)
        local label = m.sp and ns.RaidComp:SlotName(m.c, m.sp)
        root:CreateTitle(shortName(key) .. (label and (" " .. colorize("9e9e9e", label)) or ""))
        if chip.kind == "unassigned" then
            for g = 1, ns.RaidComp:GroupCount(dr.sz) do
                root:CreateButton("Move to group " .. g, function()
                    PlanUI:MoveDraftMember(key, g)
                    PlanUI:RefreshTeams()
                end)
            end
        elseif label and ns.RaidComp:CompSize(dr.cp) < dr.sz then
            root:CreateButton("Add " .. TV.article(label) .. " " .. label .. " slot", function()
                ns.RaidComp:SetCount(dr.cp, m.c, m.sp, ns.RaidComp:GetCount(dr.cp, m.c, m.sp) + 1)
                PlanUI:RefreshTeams()
            end)
        end
        local sub = root:CreateButton("Spec in this lineup")
        sub:CreateRadio("Automatic", function() return dr.s[key] == nil end, function() PlanUI:SetDraftSpec(key, nil) end)
        for i, spec in ipairs(m.c and ns.SPECS[m.c] or {}) do
            sub:CreateRadio(spec.label, function() return dr.s[key] == i end, function() PlanUI:SetDraftSpec(key, i) end)
        end
    end)
end

-- The steppers: every spec of a role with − n +, one click per slot; + hides once the comp is as big as the team.
function TV.createSteps(d)
    -- (a top-level frame like a menu: the window's scale is taken on when it opens)
    local p = CreateFrame("Frame", nil, UIParent)
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    p:SetToplevel(true)
    p:SetClampedToScreen(true)
    p:EnableMouse(true)
    p:SetSize(252, 100)
    -- (the panel every dropdown drops, UI.DROP_*)
    local bg, edge = UI().DROP_BG, UI().DROP_EDGE
    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints()
    p.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    UI():AddEdges(p, "BORDER")
    UI():SetEdgeColor(p, edge[1], edge[2], edge[3], edge[4])
    p.role = p:CreateTexture(nil, "ARTWORK")
    p.role:SetSize(14, 14)
    p.role:SetTexture(UI().ROLE_TEX)
    p.role:SetPoint("TOPLEFT", 10, -9)
    p.title = textOf(p, "GameFontNormal", 12)
    p.title:SetPoint("LEFT", p.role, "RIGHT", 6, 0)
    p.rows = {}
    p.line = p:CreateTexture(nil, "BORDER")
    p.line:SetColorTexture(1, 1, 1, 0.08)
    p.line:SetHeight(1)
    p.line:SetPoint("BOTTOMLEFT", 8, 28)
    p.line:SetPoint("BOTTOMRIGHT", -8, 28)
    p.foot = textOf(p, "GameFontHighlightSmall", 11)
    p.foot:SetPoint("BOTTOMLEFT", 10, 9)
    p:Hide()
    -- a click anywhere else closes it
    p:SetScript("OnShow", function(self)
        if not C_EventUtils or not C_EventUtils.IsEventValid or C_EventUtils.IsEventValid("GLOBAL_MOUSE_DOWN") then
            self:RegisterEvent("GLOBAL_MOUSE_DOWN")
        end
    end)
    p:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
    p:SetScript("OnEvent", function(self)
        if not self:IsMouseOver() and not (self.owner and self.owner:IsMouseOver()) then self:Hide() end
    end)
    d.steps = p
end

function TV.newStepRow(p)
    local r = CreateFrame("Frame", nil, p)
    r:SetSize(236, 22)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(16, 16)
    r.icon:SetPoint("LEFT", 2, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.fs = textOf(r, "GameFontHighlight", 12)
    r.fs:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    local function step(delta)
        local dr = state.draft
        if not dr or not RP():CanManageTeams() then return end
        local n = ns.RaidComp:GetCount(dr.cp, r.c, r.sp) + delta
        if delta > 0 and ns.RaidComp:CompSize(dr.cp) >= dr.sz then return end
        ns.RaidComp:SetCount(dr.cp, r.c, r.sp, n)
        PlanUI:RefreshTeams()
    end
    r.plus = UI():CreateSleekButton(r, "", 18, 18, function() step(1) end)
    r.plus:SetPoint("RIGHT", r, "RIGHT", 0, 0)
    TV.glyph(r.plus, true)
    r.n = textOf(r, "GameFontHighlight", 12)
    r.n:SetJustifyH("CENTER")
    r.n:SetWidth(18)
    r.n:SetPoint("RIGHT", r.plus, "LEFT", -4, 0)
    r.minus = UI():CreateSleekButton(r, "", 18, 18, function() step(-1) end)
    r.minus:SetPoint("RIGHT", r.n, "LEFT", -4, 0)
    TV.glyph(r.minus, false)
    return r
end

function TV.openSteps(role, owner)
    local p = teamsView and teamsView.detail.steps
    if not p or not RP():CanManageTeams() then return end
    if p:IsShown() and p.roleKey == role and p.owner == owner then
        p:Hide()
        return
    end
    p.roleKey, p.owner, p.draft = role, owner, state.draft
    p:SetScale((owner:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1))
    p:Show()
    -- it drops in under its chip, like every menu
    UI():DropIn(p, function(dx, dy)
        p:ClearAllPoints()
        p:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", -10 + dx, -UI().DROP_GAP + dy)
    end)
    TV.fillSteps()
end

function TV.fillSteps()
    local p = teamsView and teamsView.detail.steps
    local dr = state.draft
    if not p or not p:IsShown() then return end
    -- (another team, Undo or Save opened another draft: the panel was for the old one)
    if not dr or p.draft ~= dr then return p:Hide() end
    local role = p.roleKey
    UI():SetRoleIcon(p.role, TV.ROLE_ICON[role])
    p.title:SetText(TV.ROLE_LABEL[role])
    local specs = {}
    for _, c in ipairs(ns.CLASSES) do
        for sp = 1, #ns.SPECS[c] do
            if ns.RaidComp:RoleOf(c, sp) == role then specs[#specs + 1] = { c = c, sp = sp } end
        end
    end
    local total = ns.RaidComp:CompSize(dr.cp)
    local full = total >= dr.sz
    for i, s in ipairs(specs) do
        local r = p.rows[i] or TV.newStepRow(p)
        p.rows[i] = r
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", p, "TOPLEFT", 8, -30 - (i - 1) * 22)
        r.c, r.sp = s.c, s.sp
        local n = ns.RaidComp:GetCount(dr.cp, s.c, s.sp)
        r.icon:SetTexture(ns.RaidComp:SpecIcon(s.c, s.sp))
        if r.icon.SetDesaturated then r.icon:SetDesaturated(n == 0) end
        r.icon:SetAlpha(n == 0 and 0.5 or 1)
        local name = ns.RaidComp:SlotName(s.c, s.sp) or "?"
        r.fs:SetText(n == 0 and grey(name) or name)
        r.n:SetText(n == 0 and grey(n) or n)
        r.minus:SetShown(n > 0)
        r.plus:SetShown(not full)
        r:Show()
    end
    for i = #specs + 1, #p.rows do p.rows[i]:Hide() end
    p.foot:SetText(colorize("ffffff", total) .. colorize("9e9e9e", (" of %d slots"):format(dr.sz)
        .. (full and " · take one out to add another" or "")))
    p:SetHeight(30 + #specs * 22 + 8 + 28)
end

-- The frames of the comp (CreateTeams calls it): the tabs, Start from and the strip in the tool row, the members'
-- strip row, the columns, the bench, the steppers, the empty card.
function TV.createComp(t, d)
    -- the switch: Groups | Comp in one dark well, the open one lit
    local seg = CreateFrame("Frame", nil, d.views)
    seg:SetHeight(TV.TB_H)
    seg:SetPoint("LEFT", d.views, "LEFT", 0, 0)
    seg.bg = seg:CreateTexture(nil, "BACKGROUND")
    seg.bg:SetAllPoints()
    seg.bg:SetColorTexture(0, 0, 0, 0.35)
    UI():AddEdges(seg, "BORDER")
    UI():SetEdgeColor(seg, 1, 1, 1, 0.07)
    d.seg = seg
    -- the lit part: one thumb under the tabs that slides to the open one (TV.layoutSeg, TV.animateTab)
    local thumb = CreateFrame("Frame", nil, seg)
    thumb:SetHeight(TV.TB_H - 4)
    thumb:SetFrameLevel(seg:GetFrameLevel() + 1)
    thumb.bg = thumb:CreateTexture(nil, "BACKGROUND")
    thumb.bg:SetAllPoints()
    thumb.bg:SetColorTexture(0.165, 0.165, 0.19, 1)
    UI():AddEdges(thumb, "BORDER")
    UI():SetEdgeColor(thumb, 1, 1, 1, 0.1)
    thumb.x, thumb.w = 2, 60
    seg.thumb = thumb
    local function tab(label, key)
        local b = CreateFrame("Button", nil, seg)
        b:SetHeight(TV.TB_H - 4)
        b.key = key
        b.bg = b:CreateTexture(nil, "BACKGROUND", nil, 1)
        b.bg:SetAllPoints()
        b.bg:SetColorTexture(0.165, 0.165, 0.19, 1)
        UI():AddEdges(b, "BORDER")
        UI():SetEdgeColor(b, 1, 1, 1, 0.1)
        b.hl = b:CreateTexture(nil, "HIGHLIGHT")
        b.hl:SetAllPoints()
        b.hl:SetColorTexture(1, 1, 1, 0.05)
        local fs = textOf(b, "GameFontHighlight", 12)
        fs:SetPoint("CENTER", 0, 0)
        b:SetFontString(fs)
        b.fs = fs
        b:SetScript("OnClick", function() TV.setTab(key) end)
        b:SetFrameLevel(seg:GetFrameLevel() + 3)
        b.bg:Hide()
        for _, e in ipairs(b.edges or {}) do e:Hide() end
        function b:SetActive(on)
            -- (the seg's thumb lights the open one: the tab only brightens its text)
            self.active = on and true or false
            self.fs:SetTextColor(on and 1 or 0.62, on and 1 or 0.62, on and 1 or 0.62)
        end
        function b:SetLabel(text)
            self:SetText(text)
            self:SetWidth(floor((self.fs:GetStringWidth() or 40) + 26 + 0.5))
        end
        b:SetLabel(label)
        b:SetActive(false)
        return b
    end
    d.tabGroups = tab("Groups", "groups")
    tipButton(d.tabGroups, "Groups", "Raids that invite this team start from these groups.")
    d.tabComp = tab("Comp", "comp")
    tipButton(d.tabComp, "Target comp", "The specs this lineup should bring. Its open slots show on its tab and in "
        .. "the Sign-ups of raids that invite the team.")

    d.startBtn = UI():CreateSleekMenuButton(d.tool, "Start from", 104, function(root) TV.startMenu(root) end)
    tipButton(d.startBtn, "Start from", "Begins the comp again: a preset, the team as it is, or another team's comp.")

    -- the comp's raid buffs: in the tool row (organizers) or a row of their own (members)
    d.compBar = CreateFrame("Frame", nil, d)
    d.compBar:SetSize(TV.W, TV.BAR_H)
    d.compStrip = CreateFrame("Frame", nil, d)
    d.compStrip:SetSize(1, 22)
    d.compStrip.icons = {}
    for i = 1, 20 do
        local b = ns.RaidGroupsUI:CreateBuffIcon(d.compStrip, 20)
        if i == 1 then b:SetPoint("LEFT", d.compStrip, "LEFT", 0, 0)
        else b:SetPoint("LEFT", d.compStrip.icons[i - 1], "RIGHT", 2, 0) end
        b:Hide()
        d.compStrip.icons[i] = b
    end

    d.compScroll = UI():CreateScrollFrame(d)
    local cc = CreateFrame("Frame", nil, d.compScroll)
    cc:SetSize(TV.W, 10)
    d.compScroll:SetScrollChild(cc)
    d.compContent = cc
    -- a band per role: the gutter on the left (role, count, a pip per slot), the slots as tiles five a row
    d.cols = {}
    for i, role in ipairs(ns.RaidComp.COLUMNS) do
        local col = CreateFrame("Frame", nil, cc)
        col.roleKey = role
        col.role = col:CreateTexture(nil, "ARTWORK")
        UI():SetRoleIcon(col.role, TV.ROLE_ICON[role])
        col.role:SetSize(15, 15)
        col.role:SetPoint("LEFT", col, "TOPLEFT", 0, -8)
        col.title = textOf(col, "GameFontHighlight", 12)
        col.title:SetPoint("LEFT", col.role, "RIGHT", 6, 0)
        col.title:SetText(TV.ROLE_LABEL[role])
        col.count = textOf(col, "GameFontHighlight", 11)
        col.count:SetJustifyH("RIGHT")
        col.count:SetPoint("RIGHT", col, "TOPLEFT", TV.GUT_W, -8)
        -- (organizers, while the comp has room: + opens the steppers, after the pips)
        col.add = UI():CreateSleekButton(col, "", 16, 16, function(self) TV.openSteps(role, self) end)
        col.add:SetPoint("TOPRIGHT", col, "TOPLEFT", TV.GUT_W, -19)
        TV.glyph(col.add, true)
        tipButton(col.add, TV.ROLE_LABEL[role], "How many of each spec the comp wants.")
        -- (between the bands: a faint rule)
        col.rule = col:CreateTexture(nil, "BORDER")
        col.rule:SetColorTexture(1, 1, 1, 0.055)
        col.rule:SetHeight(1)
        col.rule:SetPoint("BOTTOMLEFT", col, "TOPLEFT", 0, 6)
        col.rule:SetPoint("BOTTOMRIGHT", col, "TOPRIGHT", 0, 6)
        col.pips = {}
        col.pipsH = 0
        col.none = textOf(col, "GameFontDisableSmall", 11)
        col.none:SetPoint("LEFT", col, "TOPLEFT", TV.GUT + 2, -8)
        col.none:SetText("No slots")
        col.rows = {}
        d.cols[i] = col
    end
    -- under the bands: who fills no slot, unassigned (in no group) and beyond the comp (in a group, no slot)
    local function chipPanel(label, tip)
        local p = CreateFrame("Frame", nil, cc)
        p.title = label
        p.label = CreateFrame("Button", nil, p)
        p.label:SetHeight(30)
        p.label:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
        -- (in the gutter: a long label takes two lines)
        p.label.fs = textOf(p.label, "GameFontHighlight", 12)
        p.label.fs:SetTextColor(0.66, 0.66, 0.68)
        p.label.fs:SetPoint("TOPLEFT", 0, -1)
        p.label.fs:SetWidth(TV.GUT_W)
        p.label.fs:SetJustifyH("LEFT")
        p.label.fs:SetWordWrap(true)
        p.label:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(label)
            GameTooltip:AddLine(tip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        p.label:SetScript("OnLeave", hideTooltip)
        p.rule = p:CreateTexture(nil, "BORDER")
        p.rule:SetColorTexture(1, 1, 1, 0.055)
        p.rule:SetHeight(1)
        p.rule:SetPoint("BOTTOMLEFT", p, "TOPLEFT", 0, 6)
        p.rule:SetPoint("BOTTOMRIGHT", p, "TOPRIGHT", 0, 6)
        p.chips = {}
        p:Hide()
        return p
    end
    d.unassigned = chipPanel("Unassigned", "On the roster, in none of this lineup's groups: they don't count for the "
        .. "comp. Put them in a group (Groups tab) to fill a slot.")
    d.bench = chipPanel("Beyond the comp", "In a group, but no slot takes them: more players of a spec than its "
        .. "slots, or a spec the comp doesn't have.")

    TV.createSteps(d)

    -- no comp yet (organizers): one card, three ways to start
    local e = CreateFrame("Frame", nil, d)
    e:SetSize(560, 230)
    panel(e, CARD_BG, { EDGE[1], EDGE[2], EDGE[3], 0.6 })
    d.compEmpty = e
    e.meter = TV.createMeter(e)
    e.meter:EnableMouse(false)
    e.meter:SetPoint("TOP", e, "TOP", 0, -24)
    local pic = { columns = {} }
    for role, list in pairs(TV.MINI_COMP) do
        pic.columns[role] = {}
        for i, c in ipairs(list) do pic.columns[role][i] = { member = c and { c = c } or nil } end
    end
    TV.fillMeter(e.meter, pic)
    e.meter.match = nil
    e.title = textOf(e, "GameFontHighlightLarge", 16)
    e.title:SetJustifyH("CENTER")
    e.title:SetPoint("TOP", e, "TOP", 0, -60)
    e.title:SetText("No target comp yet")
    e.body = e:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    setSize(e.body, 12)
    e.body:SetTextColor(0.62, 0.62, 0.62)
    e.body:SetWidth(500)
    e.body:SetJustifyH("CENTER")
    e.body:SetSpacing(3)
    e.body:SetPoint("TOP", e.title, "BOTTOM", 0, -10)
    e.body:SetText("Draft the specs this team should bring. The spots still open show on the team card, and in the "
        .. "Sign-ups of raids that invite the team.")
    e.from = textOf(e, "GameFontHighlightSmall", 11)
    e.from:SetTextColor(0.62, 0.62, 0.62)
    e.from:SetJustifyH("CENTER")
    e.from:SetPoint("TOP", e.body, "BOTTOM", 0, -18)
    e.from:SetText("Start from")
    e.tiles = {}
    for i = 1, 3 do
        local b = UI():CreateSleekButton(e, "", 164, 46, function(self) if self.start then TV.startFrom(self.start) end end)
        b:SetScript("OnMouseDown", nil)
        b:SetScript("OnMouseUp", nil)
        b.t1 = textOf(b, "GameFontHighlight", 13)
        b.t1:SetJustifyH("CENTER")
        b.t1:SetPoint("TOP", b, "TOP", 0, -9)
        b.t2 = textOf(b, "GameFontHighlightSmall", 10)
        b.t2:SetTextColor(0.62, 0.62, 0.62)
        b.t2:SetJustifyH("CENTER")
        b.t2:SetPoint("TOP", b.t1, "BOTTOM", 0, -4)
        e.tiles[i] = b
    end
end

-- The empty card's tiles: the preset, the team as it is, another team's comp (three at most, centred).
function TV.fillCompEmpty(dr)
    local e = teamsView.detail.compEmpty
    local starts = RP():GetCompStarts(TV.ref(dr))
    local n = min(3, #starts)
    local x0 = floor((560 - (n * 164 + (n - 1) * 8)) / 2 + 0.5)
    for i, b in ipairs(e.tiles) do
        local s = starts[i]
        b.start = s
        b:SetShown(s ~= nil and i <= 3)
        if s then
            b.t1:SetText(TV.startName(s))
            local sub
            if s.kind == "preset" then
                local rc = ns.RaidComp:RoleCounts(s.cp)
                sub = ("%d tanks · %d healers · %d dps"):format(rc.tank, rc.healer, rc.melee + rc.ranged)
            elseif s.kind == "team" then
                sub = "a slot per spec in the groups"
            else
                sub = "copy it, then adjust"
            end
            b.t2:SetText(sub)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", e.from, "BOTTOM", -280 + x0 + (i - 1) * 172, -8)
        end
    end
    e.from:SetShown(n > 0)
    local bodyH = e.body:GetStringHeight() or 0
    if bodyH < 20 then bodyH = 34 end
    e:SetHeight(floor(60 + (e.title:GetStringHeight() or 20) + 10 + bodyH + 18 + 14 + 8 + 46 + 24 + 0.5))
end

-- The bands (a tile per slot, in comp order, five a row) and the players no slot takes under them.
function TV.fillCompView(m, organizer)
    local d = teamsView.detail
    local dr = state.draft
    local cc = d.compContent
    local W = TV.W
    local full = ns.RaidComp:CompSize(dr.cp) >= dr.sz
    local y = 0
    for i, col in ipairs(d.cols) do
        local role = col.roleKey
        local slots = m.columns[role] or {}
        local filled = 0
        for j, slot in ipairs(slots) do
            local r = col.rows[j] or TV.newSlotRow(col)
            col.rows[j] = r
            local c, row = (j - 1) % TV.TILES, floor((j - 1) / TV.TILES)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", col, "TOPLEFT", TV.tileX(c), -row * (TV.TILE_H + TV.TILE_GAP))
            r:SetSize(TV.tileW(c), TV.TILE_H)
            local mine = not organizer and slot.member ~= nil and TV.isMine(slot.member.key)
            TV.fillSlotRow(r, slot, organizer, mine)
            if slot.member then filled = filled + 1 end
        end
        for j = #slots + 1, #col.rows do
            col.rows[j]:Hide()
            col.rows[j].slot = nil
        end
        col.none:SetShown(#slots == 0)
        col.add:SetShown(organizer and not full)
        if #slots == 0 then
            col.count:SetText("")
        elseif filled == #slots then
            col.count:SetText(colorize("8fe39d", filled .. "/" .. #slots))
        else
            col.count:SetText(filled .. colorize("9e9e9e", "/" .. #slots))
        end
        TV.fillPips(col, slots, col.add:IsShown() and (TV.GUT_W - 22) or TV.GUT_W)
        local rows = ceil(#slots / TV.TILES)
        local h = max(rows * (TV.TILE_H + TV.TILE_GAP) - TV.TILE_GAP, 22 + max(col.pipsH, col.add:IsShown() and 16 or 0))
        col:ClearAllPoints()
        col:SetPoint("TOPLEFT", cc, "TOPLEFT", 0, -y)
        col:SetSize(W, h)
        col.rule:SetShown(i > 1)
        y = y + h + TV.BAND_GAP
    end
    -- under the bands, who no slot takes: unassigned, then beyond the comp (the waitlist is on the Groups tab)
    for _, e in ipairs({ { d.unassigned, m.unassigned or {}, "unassigned" }, { d.bench, m.bench or {}, "beyond" } }) do
        local p, list = e[1], e[2]
        p.label.fs:SetText(p.title .. "  " .. colorize("8c8c8c", #list))
        p.label:SetWidth(TV.GUT_W)
        local show = #list > 0 or (organizer and e[3] == "unassigned")
        p:SetShown(show)
        if show then
            y = y + TV.fillChipPanel(p, list, e[3], y) + TV.BAND_GAP
        end
    end
    cc:SetWidth(W)
    cc:SetHeight(max(1, y - TV.BAND_GAP))
end

-- Dragging in Comp (organizers): a player from Unassigned or beyond the comp onto an open slot of their class fills
-- it: they play its spec in this lineup, and from Unassigned they take the seat where the slot waits in the groups
-- (its ghost), else the first free seat. A slot's player (or one beyond the comp) dropped on Unassigned leaves the
-- groups. The lifted card's label says where it lands; a slot it can't fill lights red and says why.
function TV.compDragStart(src)
    if not RP():CanManageTeams() then return end
    local dr = state.draft
    local m = src.slot and src.slot.member or src.member
    if not (dr and m and m.key) then return end
    local from = src.slot and "slot" or src.kind
    if from ~= "slot" and from ~= "unassigned" and from ~= "beyond" and from ~= "waitlist" then return end
    -- (the groups as they are drawn: the seats and where each open slot waits)
    teamsView.grid:Refresh()
    local drag = { key = m.key, c = m.c, sp = m.sp, from = from }
    ns.RaidGroupsUI:StartCardDrag(src, ns.RaidGroupsUI:PlayerPlate({ key = m.key, c = m.c, sp = m.sp }), {
        target = function() return TV.compTarget(drag) end,
        drop = function(t) TV.compDrop(drag, t) end,
    })
end

-- (after any card drag, a Comp slot or a group's title: the refresh that waited for it)
ns.RaidGroupsUI.onCardDragEnd = function()
    if TV.deferred then
        TV.deferred = nil
        PlanUI:RefreshTeams()
    end
end

-- Where an open slot would put the dragged player: beyond the comp, their own group; from Unassigned, the seat where
-- the slot's ghost waits, else the first free seat. Returns group, seat (nil: the group picks), or nil (no room).
function TV.slotSeat(drag, slot)
    local dr = state.draft
    if drag.from == "beyond" and TV.inGroup(dr, drag.key) then return dr.grp[drag.key], nil end
    local grid = teamsView.grid
    local n = ns.RaidComp:GroupCount(dr.sz)
    for pass = 1, 2 do
        for g = 1, n do
            for _, ch in ipairs(grid.boxes[g].chips) do
                if not ch.key and (pass == 2 or (ch.ghost and ch.ghost.c == slot.c and ch.ghost.sp == slot.sp)) then
                    return g, ch.slot
                end
            end
        end
    end
    return nil
end

-- What the cursor is over during a Comp drag: { frame, ok, label, kind = "slot" | "out", slot, g, seat } or nil.
function TV.compTarget(drag)
    local d = teamsView.detail
    for _, col in ipairs(d.cols) do
        for _, r in ipairs(col.rows) do
            if r:IsShown() and r.slot and r:IsMouseOver() then
                local slot = r.slot
                if slot.member then return nil end
                if drag.from == "slot" then
                    return { frame = r, ok = false, label = "Drag to Unassigned to take them out" }
                end
                if slot.c ~= drag.c then
                    return { frame = r, ok = false,
                             label = "Only " .. TV.article(ns.RaidComp:ClassName(slot.c) or "") .. " "
                                 .. tostring(ns.RaidComp:ClassName(slot.c) or "?") .. " can fill this" }
                end
                local g, seat = TV.slotSeat(drag, slot)
                if not g then return { frame = r, ok = false, label = "No group has room" } end
                local label = "Group " .. g .. (seat and (", seat " .. seat) or "")
                if drag.sp ~= slot.sp then label = label .. " · as " .. tostring(ns.RaidComp:SpecLabel(slot.c, slot.sp)) end
                return { frame = r, ok = true, kind = "slot", slot = slot, g = g, seat = seat, label = label }
            end
        end
    end
    local u = d.unassigned
    if drag.from ~= "unassigned" and u:IsShown() and u:IsMouseOver() then
        return { frame = (u.drop and u.drop:IsShown()) and u.drop or u, ok = true, kind = "out",
                 label = drag.from == "waitlist" and "Onto the roster (Unassigned)" or "Out of the groups" }
    end
    return nil
end

function TV.compDrop(drag, t)
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return end
    local shown = teamsView.grid.shown
    if t.kind == "out" then
        PlanUI:MoveDraftMember(drag.key, nil, nil, nil, shown)
    elseif t.kind == "slot" then
        if (drag.from == "unassigned" or drag.from == "waitlist")
            and not PlanUI:MoveDraftMember(drag.key, t.g, nil, t.seat, shown) then
            return PlanUI:RefreshTeams()
        end
        if dr.members[drag.key] and drag.sp ~= t.slot.sp then dr.s[drag.key] = t.slot.sp end
    end
    PlanUI:RefreshTeams()
end

-- The gutter's pips: a square per slot in its class colour, hollow while open, wrapping at width w.
function TV.fillPips(col, slots, w)
    local per = max(1, floor((w + 2) / 8))
    for j, slot in ipairs(slots) do
        local pip = col.pips[j]
        if not pip then
            pip = CreateFrame("Frame", nil, col)
            pip:SetSize(6, 6)
            pip.edge = pip:CreateTexture(nil, "ARTWORK", nil, 1)
            pip.edge:SetAllPoints()
            pip.hole = pip:CreateTexture(nil, "ARTWORK", nil, 2)
            pip.hole:SetPoint("TOPLEFT", 1, -1)
            pip.hole:SetPoint("BOTTOMRIGHT", -1, 1)
            pip.hole:SetColorTexture(0.055, 0.055, 0.065, 1)
            col.pips[j] = pip
        end
        local r, g, b = UI():ClassColor(slot.c)
        pip.edge:SetColorTexture(r, g, b, slot.member and 1 or 0.6)
        pip.hole:SetShown(slot.member == nil)
        pip:ClearAllPoints()
        pip:SetPoint("TOPLEFT", col, "TOPLEFT", ((j - 1) % per) * 8, -22 - floor((j - 1) / per) * 8)
        pip:Show()
    end
    for j = #slots + 1, #col.pips do col.pips[j]:Hide() end
    col.pipsH = #slots > 0 and (ceil(#slots / per) * 8 - 2) or 0
end

-- A tile's x and width in the bands (column c of TV.TILES, after the gutter).
function TV.tileX(c)
    return TV.GUT + floor(c * (TV.W - TV.GUT + TV.TILE_GAPX) / TV.TILES + 0.5)
end

function TV.tileW(c)
    return TV.tileX(c + 1) - TV.TILE_GAPX - TV.tileX(c)
end

-- One band of players under the slots (kind: unassigned or beyond the comp) at y: the label in the gutter, the
-- players as tiles; returns its height.
function TV.fillChipPanel(p, list, kind, y)
    for j, mem in ipairs(list) do
        local chip = p.chips[j] or TV.newBenchChip(p)
        p.chips[j] = chip
        chip.member, chip.kind = mem, kind
        local c, row = (j - 1) % TV.TILES, floor((j - 1) / TV.TILES)
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", p, "TOPLEFT", TV.tileX(c), -row * (TV.TILE_H + TV.TILE_GAP))
        chip:SetSize(TV.tileW(c), TV.TILE_H)
        ns.RaidGroupsUI:PaintPlate(chip, ns.RaidGroupsUI:PlayerPlate({ key = mem.key, c = mem.c, sp = mem.sp,
            prefix = kind == "waitlist" and ((mem.n or "?") .. ". ") or nil }))
        chip:Show()
    end
    for j = #list + 1, #p.chips do p.chips[j]:Hide() end
    -- (nobody there: a well across the tiles, where a player dragged out of the groups lands)
    if #list == 0 and not p.drop then
        local w = CreateFrame("Frame", nil, p)
        ns.RaidGroupsUI:DecoratePlate(w)
        ns.RaidGroupsUI:PaintPlate(w, { kind = "empty" })
        w.fs = textOf(w, "GameFontDisableSmall", 11)
        w.fs:SetPoint("CENTER", 0, 0)
        w.fs:SetText("Drag a player here to take them out of the groups")
        p.drop = w
    end
    if p.drop then
        p.drop:SetShown(#list == 0)
        p.drop:ClearAllPoints()
        p.drop:SetPoint("TOPLEFT", p, "TOPLEFT", TV.GUT, 0)
        p.drop:SetSize(TV.W - TV.GUT, TV.TILE_H)
    end
    local h = max(24, ceil(max(1, #list) / TV.TILES) * (TV.TILE_H + TV.TILE_GAP) - TV.TILE_GAP)
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", teamsView.detail.compContent, "TOPLEFT", 0, -y)
    p:SetSize(TV.W, h)
    return h
end

-- The Comp tab below the tabs: the row on top (organizers: Start from, the strip, Undo / Save; members: the
-- strip), then the columns and the bench, or (no comp yet, organizers) the empty card. Returns nothing.
function TV.layoutComp(y, organizer, dr, m)
    local t, d = teamsView, teamsView.detail
    d.tool:Show()
    t.picker.frame:Hide()
    d.autoBtn:Hide()
    d.compBar:Hide()
    d.startBtn:SetShown(organizer and m ~= nil)
    d.compStrip:SetShown(m ~= nil)
    if m then
        -- the raid buffs the comp brings, after the switch: as large as the room left there allows (18 down to 14)
        TV.layoutTool("comp")
        local room = d.stripRoom or 300
        local states = TV.states or {}
        local size = 18
        while size > 14 and #states * (size + 2) > room do size = size - 2 end
        local n = 0
        for i, b in ipairs(d.compStrip.icons) do
            local e = states[i]
            b:SetSize(size, size)
            if e and i * (size + 2) <= room + 2 then
                ns.RaidGroupsUI:SetBuffIcon(b, e)
                n = i
            else
                b:Hide()
            end
        end
        d.compStrip:SetSize(max(1, n * (size + 2) - 2), size)
    end
    TV.layoutTool("comp")
    d.tool:SetShown(m ~= nil or d.saveBtn:IsShown())
    d.compEmpty:SetShown(organizer and m == nil)
    d.compScroll:SetShown(m ~= nil)
    if not m then
        if organizer then
            TV.fillCompEmpty(dr)
            d.compEmpty:ClearAllPoints()
            d.compEmpty:SetPoint("TOP", d, "TOP", 0, -(y + 6))
        end
        return
    end
    d.compScroll:ClearAllPoints()
    d.compScroll:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, -y)
    d.compScroll:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -PAD, 0)
    TV.fillCompView(m, organizer)
end

-- The LF message: the line in the chat box, ready to send in the channel the player picks (never sent by us).
function TV.openChat(line)
    local util = ChatFrameUtil
    local open = (util and util.OpenChat) or ChatFrame_OpenChat
    if open and line then open(line) end
end

---------------------------------------------------------------------------
-- A raid's Sign-ups: the open slots of the team's comp (GetRaidOpenSlots), gold at the end of each role column
---------------------------------------------------------------------------

function PlanUI:OpenSlotTooltip(row)
    local cell = row.cdlCell
    if not cell then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(TV.specIconText(cell.c, cell.sp, 16) .. " " .. tostring(cell.name or "?"), 1, 1, 1)
    GameTooltip:AddLine("Open in " .. tostring(cell.team or "the team") .. "'s comp", 0.62, 0.62, 0.62)
    local cf = RP():RaidCanFill(cell.occ, cell.c, cell.sp)
    local any = false
    for _, grp in ipairs({ { "Not answered yet", cf.unanswered, "on the team" }, { "In the guild", cf.guild } }) do
        local list = grp[2] or {}
        if #list > 0 then
            any = true
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(grp[1], 1, 0.82, 0)
            for i = 1, min(3, #list) do
                local e = list[i]
                local right = grp[3] or (e.st == "B" and "on the bench") or ""
                GameTooltip:AddDoubleLine(TV.classIconText(e.c, 14) .. " " .. colored(e.key, e.c), right,
                    1, 1, 1, 0.62, 0.62, 0.62)
            end
            if #list > 3 then GameTooltip:AddLine(("+%d more"):format(#list - 3), 0.5, 0.5, 0.5) end
        end
    end
    if not any then GameTooltip:AddLine("Nobody else in the guild plays it yet.", 0.6, 0.6, 0.6, true) end
    if RP():CanManageRaid(cell.occ) or RP():CanManageRoster(cell.occ) then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click to add a player or a guest.", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

-- Who runs the raid: Add players, with the slot's class and spec ready for a guest.
function PlanUI:OpenSlotClick(cell)
    if not cell or not (RP():CanManageRaid(cell.occ) or RP():CanManageRoster(cell.occ)) then return end
    self:OpenInvites(cell.occ, { c = cell.c, sp = cell.sp })
end

-- For tests and the audit: the Teams view's "groups" | "comp" tab.
function PlanUI:SetTeamTab(key) TV.setTab(key) end

function PlanUI:GetTeamTab() return state.teamTab == "comp" and "comp" or "groups" end

-- For tests: the steppers panel (role column `role` opened from its +), or nil.
function PlanUI:GetCompSteps() return teamsView and teamsView.detail.steps end

---------------------------------------------------------------------------
-- New / Edit raid: UI/RaidSheet.lua (a sheet over the Raids tab; PlanUI:OpenEditor / GetEditor)
---------------------------------------------------------------------------

-- A form label of the windows below.
local function row(parent, label, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", 12, y)
    fs:SetText(label)
    return fs
end

---------------------------------------------------------------------------
-- Raid leader window (the GM and the raid leaders): who leads one raid. That leader runs it with the GM and the raid
-- leaders on the list (the leader need not be on it). A weekly raid: this week only, or every week.
---------------------------------------------------------------------------

local leaderWin

-- The guild members, the raid leaders list first, then the guild council, then everyone else.
local function leaderItems()
    local g = ns.Guild
    local lists = { {}, {}, {} }
    for _, key in ipairs(g and g.GetMembers and g:GetMembers() or {}) do
        local listed = g.IsListedRaidLeader and g:IsListedRaidLeader(key)
        local council = not listed and g.IsGuildCouncil and g:IsGuildCouncil(key)
        local e = { key = key, text = shortName(key), classFile = g:GetClass(key), note = g:GetRankName(key),
                    dim = not g:IsOnline(key) }
        local list = listed and lists[1] or (council and lists[2]) or lists[3]
        list[#list + 1] = e
    end
    local out = {}
    for i, title in ipairs({ "Raid leaders", "Guild council", "Everyone else" }) do
        tsort(lists[i], function(a, b) return a.text:lower() < b.text:lower() end)
        if #lists[i] > 0 then out[#out + 1] = { header = title } end
        for _, e in ipairs(lists[i]) do out[#out + 1] = e end
    end
    return out
end

local function refreshLeaderPick()
    local w = leaderWin
    w.pickText:SetText(w.pick and (colored(w.pick) .. " leads this raid.")
        or grey("No raid leader: every raid leader on the list runs it."))
    w.noneBtn:SetEnabled(w.pick ~= false)
    if w.picker.RefreshRows then w.picker:RefreshRows() end
end

local function leaderSave(scope)
    local w = leaderWin
    local ok, err = RP():EditRaid(w.occ, { rl = w.pick or false }, scope)
    if not ok then
        w.err:SetText(err or "Could not change the raid leader.")
        return false
    end
    w:Hide()
    return true
end

local function createLeader()
    local w = UI():CreateWindow("DisasterZoneRaidLeader", "Raid leader", 380, 220)
    leaderWin = w
    local c = w.content
    w.info = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    w.info:SetPoint("TOPLEFT", 12, -10)
    w.info:SetPoint("RIGHT", -12, 0)
    w.info:SetJustifyH("LEFT")
    w.info:SetWordWrap(false)
    w.help = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    w.help:SetPoint("TOPLEFT", 12, -30)
    w.help:SetPoint("RIGHT", -12, 0)
    w.help:SetJustifyH("LEFT")
    w.help:SetText("The raid leader runs this raid with the Guild Master and the raid leaders, even when not on the "
        .. "list. Only they and the Guild Master pick its strategies and assign players.")
    row(c, "Leader", -82)
    w.picker = UI():CreateSearchDropdown(c, 190, {
        placeholder = "Find a guild member...",
        emptyText = "No matching guild members.",
        getItems = leaderItems,
        isChecked = function(key) return w.pick == key end,
        onToggle = function(key)
            w.pick = (w.pick ~= key) and key or false
            w.err:SetText("")
            refreshLeaderPick()
            if w.picker.Close then w.picker:Close() end
        end,
    })
    w.picker.frame:SetPoint("TOPLEFT", 80, -76)
    w.noneBtn = UI():CreateSleekButton(c, "No leader", 76, 22, function()
        w.pick = false
        w.err:SetText("")
        refreshLeaderPick()
    end)
    w.noneBtn:SetPoint("LEFT", w.picker.frame, "RIGHT", 6, 0)
    w.pickText = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.pickText:SetPoint("TOPLEFT", 82, -106)
    w.pickText:SetPoint("RIGHT", -12, 0)
    w.pickText:SetJustifyH("LEFT")
    w.pickText:SetWordWrap(false)

    w.err = c:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    w.err:SetPoint("BOTTOMLEFT", 12, 40)
    w.err:SetPoint("RIGHT", -12, 0)
    w.err:SetJustifyH("LEFT")
    w.saveBtn = UI():CreateSleekButton(c, "Save", 110, 22, function() leaderSave("one") end, "primary")
    w.saveBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    w.saveAllBtn = UI():CreateSleekButton(c, "Every week", 100, 22, function() leaderSave("series") end)
    w.saveAllBtn:SetPoint("RIGHT", w.saveBtn, "LEFT", -6, 0)
    w.closeBtn = UI():CreateSleekButton(c, "Close", 70, 22, function() w:Hide() end)
    w.closeBtn:SetPoint("BOTTOMLEFT", 10, 10)
    w:Hide()
    return w
end

-- Opens the Raid leader window of a raid (the GM and the raid leaders).
function PlanUI:OpenLeader(occId)
    local v = occId and RP():GetRaid(occId)
    if not v then return false end
    if not RP():CanAssignLeader() then
        Print("Only the Guild Master and the raid leaders choose a raid's leader.")
        return false
    end
    if not leaderWin then createLeader() end
    local w = leaderWin
    w.occ, w.pick = v.id, v.rl or false
    w.err:SetText("")
    w.info:SetText(raidTitle(v) .. "  " .. grey(fmtDay(v.t) .. " " .. fmtTime(v.t)))
    w.saveBtn:SetText(v.weekly and "This week only" or "Save")
    w.saveAllBtn:SetShown(v.weekly)
    if w.picker.Close then w.picker:Close() end
    refreshLeaderPick()
    w:Show()
    w:Raise()
    return true
end

function PlanUI:GetLeaderWindow() return leaderWin end

-- The pick in the Raid leader window (key, or false: no leader), then Save ("one") / Every week ("series").
function PlanUI:PickLeader(key)
    if not leaderWin or not leaderWin:IsShown() then return false end
    leaderWin.pick = key or false
    refreshLeaderPick()
    return true
end

function PlanUI:SaveLeader(scope)
    if not leaderWin or not leaderWin:IsShown() then return false end
    return leaderSave(scope == "series" and "series" or "one")
end

---------------------------------------------------------------------------
-- Add players window: the guild members invited on top of a raid's teams (raid planners), and its guests, players
-- outside the guild added by name (roster managers). One list shows both.
---------------------------------------------------------------------------

local inviteWin

local function inviteRaid()
    return inviteWin and inviteWin.occ and RP():GetRaid(inviteWin.occ) or nil
end

local function inviteSet(v)
    local set = {}
    for _, key in ipairs(v and v.inv or {}) do set[key] = true end
    return set
end

local function invitePickerItems()
    local g = ns.Guild
    local v = inviteRaid()
    local inTeam = {}
    for _, id in ipairs(v and v.tm or {}) do
        local t = RP():GetTeam(id)
        for _, key in ipairs(t and t.members or {}) do inTeam[key] = t.name end
    end
    local out, seen = {}, {}
    for _, key in ipairs(g and g.GetMembers and g:GetMembers() or {}) do
        seen[key] = true
        out[#out + 1] = { key = key, text = shortName(key), classFile = g:GetClass(key), note = g:GetRankName(key),
                          dim = not g:IsOnline(key), fixed = inTeam[key] }
    end
    for key in pairs(inviteSet(v)) do
        if not seen[key] then out[#out + 1] = { key = key, text = shortName(key), note = "not in the guild", dim = true } end
    end
    tsort(out, function(a, b) return a.text:lower() < b.text:lower() end)
    return out
end

local function classOptions()
    local out = {}
    for classFile in pairs(ns.SPECS or {}) do
        out[#out + 1] = { value = classFile, text = ns.CLASS_NAMES[classFile] or classFile }
    end
    tsort(out, function(a, b) return a.text < b.text end)
    return out
end

local function guestSpecOptions()
    local out = {}
    for i, spec in ipairs(inviteWin and ns.SPECS[inviteWin.cls] or {}) do out[#out + 1] = { value = i, text = spec.label } end
    return out
end

local function initInviteRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        row.fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.fs:SetPoint("LEFT", 6, 0)
        row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.note:SetPoint("LEFT", 150, 0)
        row.remove = UI():CreateRemoveButton(row, "Take off this raid")
        row.remove:SetPoint("RIGHT", -4, 0)
        row.remove:SetScript("OnClick", function(self)
            local data = self:GetParent().__cdlData
            if not data then return end
            if data.guest then PlanUI:RemoveGuest(data.key) else PlanUI:ToggleInvite(data.key) end
        end)
    end
    row.fs:SetText(UI():ColoredName(d.key, d.c))
    row.note:SetText(d.note or "")
    row.remove:SetShown(d.guest or (inviteWin ~= nil and inviteWin.occ ~= nil and RP():CanManageRaid(inviteWin.occ)))
end

-- One input row at a time: the "Guild member" tab shows the member search, the "Guest" tab the guest's name, class
-- and spec. What each tab is for is in its tooltip, not on the window.
local function createInvites()
    local w = UI():CreateWindow("DisasterZoneRaidInvites", "Add players", 400, 400)
    inviteWin = w
    local c = w.content
    w.mode = "member"
    w.info = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    w.info:SetPoint("TOPLEFT", 10, -8)
    w.info:SetPoint("RIGHT", -10, 0)
    w.info:SetJustifyH("LEFT")
    w.info:SetWordWrap(false)

    local function tab(label, mode)
        return UI():CreateUnderlineTab(c, label, function()
            w.mode = mode
            w.err:SetText("")
            PlanUI:RefreshInvites()
        end)
    end
    w.memberTab = tab("Guild member", "member")
    w.memberTab:SetPoint("TOPLEFT", 4, -32)
    tipButton(w.memberTab, "Guild member", "Invite guild members outside the raid's teams. On a locked raid they are "
        .. "the only ones besides the teams who can sign up and see it.")
    w.guestTab = tab("Guest", "guest")
    w.guestTab:SetPoint("LEFT", w.memberTab, "RIGHT", 4, 0)
    tipButton(w.guestTab, "Guest", "Add a player who is not in the guild by character name. A guest counts as "
        .. "accepted, can be placed in a group and is invited with the raid.")
    -- 1.3: one click for a player we know (the guest book, my group, my target), with their class and spec
    w.knownBtn = UI():CreateSleekMenuButton(c, "Known players", 120, function(root) PlanUI:BuildKnownGuestsMenu(root) end)
    w.knownBtn:SetPoint("TOPRIGHT", -8, -32)
    tipButton(w.knownBtn, "Known players", "Players outside the guild from the guest book, your group and your target. "
        .. "Pick one to add them with the class and spec last seen.")

    -- guild members (raid planners)
    w.picker = UI():CreateSearchDropdown(c, 340, {
        placeholder = "Search guild members...",
        emptyText = "No matching guild members.",
        getItems = invitePickerItems,
        isChecked = function(key) return inviteSet(inviteRaid())[key] and true or false end,
        onToggle = function(key) PlanUI:ToggleInvite(key) end,
    })
    w.picker.frame:SetPoint("TOPLEFT", 6, -60)

    -- guests (roster managers): name, class, spec
    w.nameBox = UI():CreateSleekEditBox(c)
    w.nameBox:SetSize(116, 20)
    w.nameBox:SetAutoFocus(false)
    w.nameBox:SetMaxLetters(48)
    w.nameBox:SetPoint("TOPLEFT", 14, -62)
    w.nameBox:SetScript("OnEnterPressed", function() PlanUI:AddGuest() end)
    w.nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    w.nameHint = w.nameBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    w.nameHint:SetPoint("LEFT", 6, 0)
    w.nameHint:SetText("Character name")
    w.nameBox:SetScript("OnTextChanged", function(self)
        w.nameHint:SetShown(self:GetText() == "")
        PlanUI:GuessGuestClass(self:GetText())
    end)
    w.classDD = UI():CreateSleekDropdown(c, 84, classOptions, function() return w.cls end, function(val)
        w.cls, w.sp = val, nil
        if w.specDD.Refresh then w.specDD:Refresh() end
    end)
    w.classDD:SetPoint("LEFT", w.nameBox, "RIGHT", 6, 0)
    w.classDD:SetDefaultText("Class")
    w.specDD = UI():CreateSleekDropdown(c, 84, guestSpecOptions, function() return w.sp end, function(val) w.sp = val end)
    w.specDD:SetPoint("LEFT", w.classDD, "RIGHT", 3, 0)
    w.specDD:SetDefaultText("Spec")
    w.addBtn = UI():CreateSleekButton(c, "Add", 44, 22, function() PlanUI:AddGuest() end, "primary")
    w.addBtn:SetPoint("LEFT", w.specDD, "RIGHT", 4, 0)

    w.err = c:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    w.err:SetPoint("TOPLEFT", 12, -88)
    w.err:SetPoint("RIGHT", -10, 0)
    w.err:SetJustifyH("LEFT")
    w.status = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    w.status:SetPoint("TOPLEFT", 10, -88)
    w.list = UI():CreateScrollList(c, 22, initInviteRow)
    w.list.frame:SetPoint("TOPLEFT", 4, -104)
    w.list.frame:SetPoint("BOTTOMRIGHT", -4, 8)
    w.list:SetEmptyText("Nobody added yet.")
    w:Hide()
    return w
end

-- Who runs the raid invites guild members (and adds guests); officers add guests.
local function canAddPlayers(occId)
    return RP():CanManageRaid(occId) or RP():CanManageRoster(occId)
end

-- Opens the Add players window of a raid: invites for who runs it, guests for them and the officers.
function PlanUI:OpenInvites(occId, opts)
    if not RP():GetRaid(occId) then return false end
    if not canAddPlayers(occId) then
        Print(RP():GetRaidLeader(occId) and "Only this raid's leader, the Guild Master, the raid leaders and officers can add players to it."
            or "Only the Guild Master, officers and the raid leaders can add players to a raid.")
        return false
    end
    if not inviteWin then createInvites() end
    inviteWin.occ = occId
    inviteWin.err:SetText("")
    inviteWin.mode = RP():CanManageRaid(occId) and "member" or "guest"
    -- (from an open slot of the team's comp: its class and spec ready for a guest)
    if type(opts) == "table" and opts.c then inviteWin.cls, inviteWin.sp = opts.c, opts.sp end
    inviteWin:Show()
    inviteWin:Raise()
    self:RefreshInvites()
    return true
end

function PlanUI:GetInviteWindow() return inviteWin end

-- Invites a player to the raid on top of its teams, or takes the invite back (shared at once; for a weekly raid
-- this week only: Edit > Save every week changes them all).
function PlanUI:ToggleInvite(key)
    local v = inviteRaid()
    if not v or type(key) ~= "string" then return false end
    local set = inviteSet(v)
    set[key] = not set[key] or nil
    local list = {}
    for k in pairs(set) do list[#list + 1] = k end
    tsort(list)
    local ok, err = RP():EditRaid(v.id, { inv = list }, "one")
    if not ok then Print("Could not change the invites: %s", tostring(err)) end
    self:RefreshInvites()
    return ok and true or false
end

-- Adds the guest typed in the window (name, class, spec), or the one given.
function PlanUI:AddGuest(name, classFile, spec)
    local w = inviteWin
    if not w or not w.occ then return false end
    name = name or w.nameBox:GetText()
    local ok, err = RP():AddGuest(w.occ, name, classFile or w.cls, spec or w.sp)
    if not ok then
        w.err:SetText(err or "Could not add the guest.")
        w.status:SetText("")
        return false
    end
    w.err:SetText("")
    w.cls, w.sp = nil, nil      -- (the next name typed fills them in again when it is a known player)
    w.nameBox:SetText("")
    w.nameBox:ClearFocus()
    self:RefreshInvites()
    return true
end

-- Players outside the guild we know, for the Guest tab: { key, c, sp, where = "group" | "target" | "book" }, my
-- group first, then my target, then the guest book (newest first). Guests of the raid and blacklisted players are
-- left out.
local MAX_KNOWN = 15
function PlanUI:GetKnownGuests()
    local v = inviteRaid()
    local out, seen = {}, {}
    local guests = v and RP():GetSignups(v.id) or {}
    local G = ns.Guild
    local function add(key, c, sp, where)
        if type(key) ~= "string" or seen[key] or guests[key] or ns.Util.IsMe(key) or RP():IsBlacklisted(key) then return end
        if not (G and G.IsReady and G:IsReady()) or G:IsInGuild(key, true) then return end
        seen[key] = true
        local gc, gsp = ns.GuestBook and ns.GuestBook:GetSpec(key)
        if gc and (c == nil or gc == c) then c, sp = gc, sp or gsp end
        out[#out + 1] = { key = key, c = c, sp = sp, where = where }
    end
    for i = 1, GetNumGroupMembers() or 0 do
        local unit = IsInRaid() and ("raid" .. i) or ("party" .. i)
        if UnitExists(unit) then add(ns.Util.UnitKey(unit), select(2, UnitClass(unit)), nil, "group") end
    end
    if UnitExists("target") and UnitIsPlayer("target") then
        add(ns.Util.UnitKey("target"), select(2, UnitClass("target")), nil, "target")
    end
    local n = 0
    for _, e in ipairs(ns.GuestBook and ns.GuestBook:GetEntries() or {}) do
        if n >= MAX_KNOWN then break end
        if not e.blacklisted then
            local before = #out
            add(e.key, e.c, e.sp, "book")
            if #out > before then n = n + 1 end
        end
    end
    return out
end

function PlanUI:BuildKnownGuestsMenu(root)
    local list = self:GetKnownGuests()
    if #list == 0 then
        local b = root:CreateButton(grey("Nobody: the guest book is empty and nobody outside the guild is with you"),
            function() end)
        if b and b.SetEnabled then b:SetEnabled(false) end
        return
    end
    local titles = { group = "In your group", target = "Your target", book = "Guest book" }
    local last
    for _, g in ipairs(list) do
        if g.where ~= last then
            root:CreateTitle(titles[g.where])
            last = g.where
        end
        local spec = g.c and g.sp and ns.SPECS[g.c] and ns.SPECS[g.c][g.sp]
        local label = colored(g.key, g.c) .. grey("  " .. ((spec and spec.label .. " ") or "")
            .. (g.c and ns.CLASS_NAMES[g.c] or "class unknown"))
        local key, c, sp = g.key, g.c, g.sp
        root:CreateButton(label, function()
            if c then
                PlanUI:AddGuest(key, c, sp)
            else
                inviteWin.nameBox:SetText(shortName(key))   -- pick the class, then Add
            end
        end)
    end
end

-- A name typed on the Guest tab that the guest book (or my group) knows fills in the class and spec, unless one was
-- picked already.
function PlanUI:GuessGuestClass(text)
    local w = inviteWin
    if not w or w.cls or type(text) ~= "string" then return end
    local name = ns.Util.Trim(text):lower()
    if name == "" then return end
    for _, g in ipairs(self:GetKnownGuests()) do
        if g.c and shortName(g.key):lower() == name then
            w.cls, w.sp = g.c, g.sp
            for _, dd in ipairs({ w.classDD, w.specDD }) do
                if dd.Refresh then dd:Refresh() end
            end
            return
        end
    end
end

function PlanUI:RemoveGuest(key)
    local w = inviteWin
    if not w or not w.occ then return false end
    local ok, err = RP():RemoveGuest(w.occ, key)
    if not ok then Print(err or "Could not remove the guest.") end
    self:RefreshInvites()
    return ok and true or false
end

function PlanUI:RefreshInvites()
    if not inviteWin or not inviteWin:IsShown() then return end
    local v = inviteRaid()
    if not v or not canAddPlayers(v) then
        inviteWin:Hide()
        return
    end
    local planner, manager = RP():CanManageRaid(v), RP():CanManageRoster(v)
    local w = inviteWin
    w.info:SetText(raidTitle(v) .. "  " .. grey(fmtDay(v.t) .. " " .. fmtTime(v.t)))
    -- the tabs only when there is a choice
    if not planner then w.mode = "guest" elseif not manager then w.mode = "member" end
    local guestMode = w.mode == "guest"
    w.memberTab:SetShown(planner and manager)
    w.guestTab:SetShown(planner and manager)
    w.memberTab:SetActive(not guestMode)
    w.guestTab:SetActive(guestMode)
    w.picker.frame:SetShown(not guestMode)
    if guestMode and w.picker.Close then w.picker:Close() end
    for _, region in ipairs({ w.nameBox, w.classDD, w.specDD, w.addBtn, w.knownBtn }) do region:SetShown(guestMode) end
    w.nameHint:SetShown(w.nameBox:GetText() == "")
    local g = ns.Guild
    local rows = {}
    for _, key in ipairs(v.inv or {}) do
        rows[#rows + 1] = { key = key, note = g and g.GetRankName and g:GetRankName(key) or "" }
    end
    tsort(rows, function(a, b) return nameLess(a.key, b.key) end)
    local invited = #rows
    -- guests after the guild members: "Guest · Combat Rogue"
    local guests = {}
    for key, gu in pairs(RP():GetGuests(v)) do
        local spec = ns.SPECS[gu.c] and gu.sp and ns.SPECS[gu.c][gu.sp]
        guests[#guests + 1] = { key = key, c = gu.c, guest = true,
            note = "|cff66ccffGuest|r · " .. ((spec and spec.label .. " ") or "") .. (ns.CLASS_NAMES[gu.c] or "") }
    end
    tsort(guests, function(a, b) return nameLess(a.key, b.key) end)
    for _, d in ipairs(guests) do rows[#rows + 1] = d end
    -- "2 invited · 1 guest" (nothing while the list is empty, or while an error is shown in its place)
    local parts = {}
    if invited > 0 then parts[#parts + 1] = invited .. " invited" end
    if #guests > 0 then parts[#parts + 1] = #guests .. (#guests == 1 and " guest" or " guests") end
    inviteWin.status:SetText((inviteWin.err:GetText() or "") == "" and tconcat(parts, " · ") or "")
    inviteWin.list:SetData(rows)
    for _, dd in ipairs({ inviteWin.classDD, inviteWin.specDD }) do
        if dd.Refresh then dd:Refresh() end
    end
    if inviteWin.picker.IsOpen and inviteWin.picker:IsOpen() then inviteWin.picker:RefreshRows() end
end

---------------------------------------------------------------------------
-- Blacklist (roster managers): 1.3 moved it into the Guests window (UI/GuestBook.lua), next to the guest book.
---------------------------------------------------------------------------

-- Opens the blacklist; key (optional) = a player to put in the name box.
function PlanUI:OpenBlacklist(key) return ns.GuestBookUI:OpenBlacklist(key) end

-- The blacklist page of the Guests window (nameBox, reasonBox, addBtn, err, list), or nil before it was opened.
function PlanUI:GetBlacklistWindow() return ns.GuestBookUI:GetBlacklistPage() end

function PlanUI:AddBlacklist(name, reason) return ns.GuestBookUI:AddBlacklist(name, reason) end

function PlanUI:Unblacklist(key) return ns.GuestBookUI:Unblacklist(key) end

function PlanUI:RefreshBlacklist() ns.GuestBookUI:RequestRefresh() end

---------------------------------------------------------------------------
-- Refresh / lifecycle
---------------------------------------------------------------------------

function PlanUI:Refresh()
    self:RefreshUpcoming()
    self:RefreshTeams()
end

function PlanUI:RequestRefresh()
    ns.Util.Debounce("raidplan-ui", 0.2, function() PlanUI:Refresh() end)
end

-- The login reminder: raids of my teams in the next 7 days that I haven't answered.
local function Remind()
    local list = RP():GetUnanswered(7)
    if #list == 0 then return end
    local parts = {}
    for _, v in ipairs(list) do parts[#parts + 1] = date("%a", v.t) .. " " .. RP():GetRaidName(v) end
    Print("%d raid%s to answer: %s. Type /dz raids to sign up.", #list, #list == 1 and "" or "s", tconcat(parts, ", "))
end

function PlanUI:OnInit()
    for _, msg in ipairs({ "RAIDPLAN_CHANGED", "ROSTER_UPDATED", "CONFIG_UPDATED", "RAIDINVITE_CHANGED" }) do
        ns:On(msg, function() PlanUI:RequestRefresh() end)
    end
    for _, msg in ipairs({ "RAIDPLAN_CHANGED", "CONFIG_UPDATED" }) do
        ns:On(msg, function()
            PlanUI:RefreshInvites()
            PlanUI:RefreshBlacklist()
        end)
    end
    if ns.Popup.dialogs then
        ns.Popup.dialogs["DISASTERZONE_PLAN_DELETE"] = {
            title = "Delete",
            danger = true,
            text = "Delete %s?\n\nIt disappears for everyone, with its sign-ups and groups. This can't be undone.",
            button1 = DELETE or "Delete",
            button2 = CANCEL or "Cancel",
            OnAccept = function(_, data)
                if type(data) == "table" and data.fn then data.fn() end
            end,
            showAlert = true,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        ns.Popup.dialogs["DISASTERZONE_PLAN_CONFIRM"] = {
            text = "%s",
            button1 = YES or "Yes",
            button2 = NO or "No",
            OnAccept = function(_, data)
                if type(data) == "table" and data.fn then data.fn() end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        -- Teams: unsaved changes when leaving the team (Save / Discard / Cancel; Escape = Cancel), and Delete with
        -- what it changes
        ns.Popup.dialogs["DISASTERZONE_TEAM_UNSAVED"] = {
            title = "Unsaved changes",
            text = "|cffffd100%s|r has changes that aren't saved.",
            button1 = "Save",
            button2 = "Discard",
            button3 = CANCEL or "Cancel",
            OnAccept = function(_, data)
                if PlanUI:SaveTeam() and type(data) == "table" and data.fn then data.fn() end
            end,
            OnCancel = function(_, data, reason)
                if reason ~= "clicked" then return end
                PlanUI:DiscardDraft()
                if type(data) == "table" and data.fn then data.fn() end
            end,
            OnAlt = function(_, data)
                if type(data) == "table" and data.stay then data.stay() end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            noCancelOnEscape = true,
            preferredIndex = 3,
        }
        ns.Popup.dialogs["DISASTERZONE_TEAM_COMP_SIZE"] = {
            text = "%s",
            button1 = YES or "Yes",
            button2 = CANCEL or "Cancel",
            OnAccept = function(_, data)
                if type(data) == "table" and data.fn then data.fn() end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        -- Teams: a lineup's name (empty: its default, "25-man")
        local function editBox(popup) return (popup.GetEditBox and popup:GetEditBox()) or popup.editBox end
        local function rename(data, text)
            if type(data) == "table" and data.i then PlanUI:RenameLineup(data.i, text) end
        end
        ns.Popup.dialogs["DISASTERZONE_LINEUP_NAME"] = {
            title = "Lineup name",
            text = "Leave it empty for its size, e.g. \"25-man\".",
            button1 = SAVE or "Save",
            button2 = CANCEL or "Cancel",
            hasEditBox = 1,
            maxLetters = 32,
            OnShow = function(self, data)
                local eb = editBox(self)
                data = data or self.data
                if eb then
                    eb:SetText(type(data) == "table" and data.name or "")
                    eb:SetFocus()
                    eb:HighlightText()
                end
            end,
            OnAccept = function(self, data)
                local eb = editBox(self)
                rename(data or self.data, eb and eb:GetText())
            end,
            EditBoxOnEnterPressed = function(eb)
                local popup = eb:GetParent()
                rename(popup and popup.data, eb:GetText())
                if popup then popup:Hide() end
            end,
            EditBoxOnEscapePressed = function(eb)
                local popup = eb:GetParent()
                if popup then popup:Hide() end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        ns.Popup.dialogs["DISASTERZONE_TEAM_DELETE"] = {
            title = "Delete team",
            danger = true,
            text = "%s",
            button1 = DELETE or "Delete",
            button2 = CANCEL or "Cancel",
            OnAccept = function(_, data)
                if type(data) == "table" and data.fn then data.fn() end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
end

function PlanUI:OnLogin()
    -- After the login sync (HELLO + catch-up) had time to bring the raids in.
    ns.Util.After(45, Remind)
end

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
local EDITOR_DAYS = 60
local MAX_LEVEL = 70                -- a new raid asks for this level unless "Allow characters below level 70" is ticked

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
local upcoming, teamsView, editor

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
-- (plain: without the "Locked" mark).
local function teamNames(v, plain)
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
local function raidRowTooltip(row)
    local d = row.__cdlData
    local v = d and d.v
    if not v then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(raidTitle(v) .. (v.cancelled and "  |cffff5555CANCELLED|r" or ""))
    GameTooltip:AddLine(date("%A %d %B", v.t) .. " · " .. fmtTime(v.t) .. (v.weekly and " · weekly" or ""), 1, 1, 1)
    local inst = RP():GetInstance(v.i)
    if v.ti and inst then GameTooltip:AddLine(inst.name, 0.8, 0.8, 0.8) end
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
    if state.filterRaid ~= "all" and v.i ~= state.filterRaid then return false end
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
local CARD_H = 84
local ART_W, DATE_W = 196, 56
local ANS_W = 214                    -- the card's answer area (Accept / Tentative / ..., or my answer)
local FILTER_ROW = 22
local SECTION_H = 30
local HERO_H = 140                   -- the banner (the way back and the raid's actions in its top row): every tab
local TABS_H = 24
local COL_HEAD_H = 28
local COL_ROW_H = 22
local CHIP_H, CHIP_GAP = 22, 6
local CARD_BG = { 0.10, 0.10, 0.12, 0.92 }
local PANEL_BG = { 0.08, 0.08, 0.095, 0.9 }
local EDGE = { 0.34, 0.34, 0.38, 0.5 }
local PILL = {
    A = { 0.16, 0.43, 0.22, 0.35, 0.35, 0.86, 0.47, "b7f5c3" }, T = { 0.47, 0.39, 0.08, 0.35, 1, 0.82, 0, "ffe680" },
    B = { 0.20, 0.27, 0.45, 0.35, 0.6, 0.73, 1, "c4d6ff" }, X = { 0.45, 0.10, 0.10, 0.35, 1, 0.33, 0.33, "ffb0b0" },
    R = { 0.47, 0.39, 0.08, 0.35, 1, 0.82, 0, "ffe680" }, N = { 0.2, 0.2, 0.22, 0.6, 0.45, 0.45, 0.48, "9e9e9e" },
}

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

-- The answer pill (my answer, my request, cancelled): p:Set(kind, text, sub)
local function newPill(parent)
    local p = CreateFrame("Button", nil, parent)
    p:SetHeight(22)
    local function disc(layer, sub, inset)
        local l = p:CreateTexture(nil, layer, nil, sub)
        l:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        l:SetSize(22 - 2 * inset, 22 - 2 * inset)
        l:SetPoint("LEFT", inset, 0)
        local r = p:CreateTexture(nil, layer, nil, sub)
        r:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        r:SetSize(22 - 2 * inset, 22 - 2 * inset)
        r:SetPoint("RIGHT", -inset, 0)
        local m = p:CreateTexture(nil, layer, nil, sub)
        m:SetColorTexture(1, 1, 1, 1)
        m:SetPoint("TOPLEFT", p, "TOPLEFT", 11, -inset)
        m:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -11, inset)
        return { l, r, m }
    end
    p.edge = disc("BACKGROUND", 1, 0)
    p.fill = disc("BACKGROUND", 2, 1)
    p.icon = p:CreateTexture(nil, "ARTWORK")
    p.icon:SetSize(13, 13)
    p.icon:SetPoint("LEFT", 7, 0)
    p.text = textOf(p, "GameFontHighlight", 12)
    p.text:SetPoint("LEFT", p.icon, "RIGHT", 4, 0)
    p.sub = textOf(parent, "GameFontHighlightSmall", 10)
    p.sub:SetTextColor(0.62, 0.62, 0.62)
    p.sub:SetJustifyH("RIGHT")
    p.sub:SetPoint("TOPRIGHT", p, "BOTTOMRIGHT", -2, -3)
    function p:Set(kind, text, sub, icon)
        local c = PILL[kind] or PILL.N
        for _, t in ipairs(self.fill) do t:SetVertexColor(c[1], c[2], c[3], 0.95) end
        for _, t in ipairs(self.edge) do t:SetVertexColor(c[5], c[6], c[7], c[4] + 0.3) end
        self.text:SetText("|cff" .. c[8] .. text .. "|r")
        self.icon:SetShown(icon ~= nil)
        if icon then self.icon:SetTexture(icon) end
        self:SetWidth(floor((icon and 24 or 10) + (self.text:GetStringWidth() or 40) + 10))
        self.text:ClearAllPoints()
        if icon then self.text:SetPoint("LEFT", self.icon, "RIGHT", 4, 0) else self.text:SetPoint("LEFT", 10, 0) end
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
local PILL_ICON = { A = "Interface\\RaidFrame\\ReadyCheck-Ready", T = "Interface\\RaidFrame\\ReadyCheck-Waiting",
                    X = "Interface\\RaidFrame\\ReadyCheck-NotReady" }

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

local function newRaidCard(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(CARD_H)
    c:RegisterForClicks("LeftButtonUp")
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetAllPoints()
    c.bg:SetColorTexture(CARD_BG[1], CARD_BG[2], CARD_BG[3], CARD_BG[4])
    UI():AddEdges(c, "BORDER")
    c.art = c:CreateTexture(nil, "ARTWORK", nil, 0)
    c.art:SetPoint("TOPLEFT", 1, -1)
    c.art:SetSize(ART_W, CARD_H - 2)
    c.fade = c:CreateTexture(nil, "ARTWORK", nil, 2)
    c.fade:SetPoint("TOPRIGHT", c.art, "TOPRIGHT")
    c.fade:SetPoint("BOTTOMRIGHT", c.art, "BOTTOMRIGHT")
    c.fade:SetWidth(floor(ART_W * 0.45))
    gradient(c.fade, "HORIZONTAL", CARD_BG[1], CARD_BG[2], CARD_BG[3], 0, 1)
    c.shade = c:CreateTexture(nil, "ARTWORK", nil, 1)
    c.shade:SetPoint("BOTTOMLEFT", c.art, "BOTTOMLEFT")
    c.shade:SetPoint("BOTTOMRIGHT", c.art, "BOTTOMRIGHT")
    c.shade:SetHeight(30)
    gradient(c.shade, "VERTICAL", 0, 0, 0, 0.8, 0)
    c.inst = textOf(c, "GameFontNormalSmall", 10)
    c.inst:SetPoint("BOTTOMLEFT", c.art, "BOTTOMLEFT", 10, 9)
    -- the date: weekday, day, time, centred in its column (half over the art's fade)
    c.dn = textOf(c, "GameFontHighlightLarge", 24)
    c.dn:SetJustifyH("CENTER")
    c.dn:SetPoint("CENTER", c, "LEFT", ART_W - 12 + DATE_W / 2, 1)
    c.wd = textOf(c, "GameFontNormalSmall", 10)
    c.wd:SetJustifyH("CENTER")
    c.wd:SetPoint("BOTTOM", c.dn, "TOP", 0, 2)
    c.tm = textOf(c, "GameFontHighlightSmall", 11)
    c.tm:SetTextColor(0.62, 0.62, 0.62)
    c.tm:SetJustifyH("CENTER")
    c.tm:SetPoint("TOP", c.dn, "BOTTOM", 0, -2)
    c.div = c:CreateTexture(nil, "ARTWORK", nil, 3)
    c.div:SetColorTexture(1, 1, 1, 0.08)
    c.div:SetWidth(1)
    c.div:SetPoint("TOPLEFT", ART_W + DATE_W - 10, -16)
    c.div:SetPoint("BOTTOMLEFT", ART_W + DATE_W - 10, 16)
    -- title, who / when, the accepted by role: three lines centred on the card
    local x0 = ART_W + DATE_W + 4
    c.t1 = textOf(c, "GameFontHighlight", 15)
    c.t1:SetPoint("TOPLEFT", x0, -15)
    c.t2 = textOf(c, "GameFontHighlightSmall", 11)
    c.t2:SetTextColor(0.62, 0.62, 0.62)
    c.t2:SetPoint("TOPLEFT", c.t1, "BOTTOMLEFT", 0, -4)
    c.meter = textOf(c, "GameFontHighlightSmall", 11)
    c.meter:SetPoint("TOPLEFT", c.t2, "BOTTOMLEFT", 0, -7)
    -- my answer: Accept / Tentative / ..., or the pill of my answer, or Ask to join, or why I can't
    c.more = UI():CreateTipIconButton(c, 26, UI().ICON.more, "More answers", "Bench or Absent, or open the raid.")
    c.more:SetPoint("RIGHT", c, "RIGHT", -14, 0)
    c.tentative = UI():CreateSleekButton(c, "Tentative", 80, 26, nil)
    c.tentative:SetPoint("RIGHT", c.more, "LEFT", -4, 0)
    c.accept = UI():CreateSleekButton(c, "Accept", 70, 26, nil, "primary")
    c.accept:SetPoint("RIGHT", c.tentative, "LEFT", -4, 0)
    c.ask = UI():CreateSleekButton(c, "Ask to join", 96, 26, nil)
    c.ask:SetPoint("RIGHT", c, "RIGHT", -14, 0)
    c.why = textOf(c, "GameFontHighlightSmall", 11)
    c.why:SetTextColor(0.62, 0.62, 0.62)
    c.why:SetJustifyH("RIGHT")
    c.why:SetPoint("RIGHT", c, "RIGHT", -16, 0)
    c.pill = newPill(c)
    c:SetScript("OnEnter", function(self)
        UI():SetEdgeColor(self, 1, 0.82, 0, 0.55)
        raidRowTooltip(self)
    end)
    c:SetScript("OnLeave", function(self)
        UI():SetEdgeColor(self, EDGE[1], EDGE[2], EDGE[3], 0.6)
        hideTooltip()
    end)
    c:SetScript("OnClick", function(self)
        local d = self.__cdlData
        if d and d.v then PlanUI:SelectRaid(d.v.id) end
    end)
    return c
end

local function fillRaidCard(c, v, width)
    c.__cdlData = { v = v }
    c:SetWidth(width)
    UI():SetEdgeColor(c, EDGE[1], EDGE[2], EDGE[3], 0.6)
    local file, l, r, t, b = artCoords(v.i, ART_W, CARD_H - 2, 0.5)
    c.art:SetTexture(file)
    c.art:SetTexCoord(l, r, t, b)
    local inst = RP():GetInstance(v.i)
    c.inst:SetText(((inst and inst.name or "Raid") .. " · " .. (v.sz or 0)):upper())
    c.wd:SetText(date("%a", v.t):upper())
    c.dn:SetText(tonumber(date("%d", v.t)))
    c.tm:SetText(fmtTime(v.t))
    local past = v.t < Now() - 6 * 3600
    local dim = v.cancelled or past
    c.art:SetDesaturated(dim and true or false)
    c.art:SetAlpha(dim and 0.6 or 1)
    for _, fs in ipairs({ c.t1, c.wd, c.dn, c.meter }) do fs:SetAlpha(dim and 0.55 or 1) end
    c.t1:SetText(RP():GetRaidName(v))
    -- who leads, who it is for, when; and for who runs it, the requests waiting
    local parts = {}
    if v.rl then parts[#parts + 1] = colored(v.rl) .. grey(" leads")
    elseif v.by then parts[#parts + 1] = "by " .. shortName(v.by) end
    local teams = teamNames(v, true)
    if teams ~= "Everyone" then parts[#parts + 1] = teams end
    parts[#parts + 1] = v.cancelled and colorize("ff5555", "cancelled") or relDay(v.t)
    if v.weekly then parts[#parts + 1] = "weekly" end
    local nReq = (v.lk and RP():CanManageRaid(v)) and #RP():GetRequests(v.id) or 0
    if nReq > 0 then parts[#parts + 1] = colorize("ffd100", nReq .. (nReq == 1 and " request" or " requests")) end
    c.t2:SetText(tconcat(parts, " · "))
    -- the accepted by role and how full it is (no targets: the raid has none), or that nobody answered yet
    local rc, tentative = roleCounts(v)
    local cnt = counts(v.id)
    if cnt.A == 0 and tentative == 0 then
        c.meter:SetText(grey("No answers yet"))
    else
        local full = cnt.A >= (v.sz or 0) and (v.sz or 0) > 0
        local meter = ("%s %d    %s %d    %s %d"):format(roleIcon("tank"), rc.tank, roleIcon("healer"), rc.healer,
            roleIcon("dps"), rc.melee + rc.ranged + rc.nospec)
        local total = ("%d of %d"):format(cnt.A, v.sz or 0)
        meter = meter .. "      " .. (full and colorize("8fe39d", total) or grey(total))
        if tentative > 0 then meter = meter .. grey(" · " .. tentative .. " tentative") end
        c.meter:SetText(meter)
    end

    -- the answer area
    local kind, block, canAnswer, canAsk, mine = myState(v)
    for _, w in ipairs({ c.accept, c.tentative, c.more, c.ask }) do w:Hide() end
    c.why:Hide()
    c.pill:SetPillShown(false)
    local id = v.id
    if kind == "C" then
        c.pill:Set("N", "Cancelled")
        c.pill:ClearAllPoints()
        c.pill:SetPoint("RIGHT", c, "RIGHT", -14, 0)
        c.pill:SetPillShown(true)
        c.pill:SetScript("OnClick", nil)
        c.pill:SetAlpha(1)
    elseif STATUS[kind] or kind == "R" then
        local sub = (kind ~= "R" and mine and specLabelOf(mine)) and ("as " .. specLabelOf(mine)) or nil
        if kind == "R" then sub = "a raid leader approves" end
        c.pill:Set(kind, PILL_TEXT[kind], sub, PILL_ICON[kind])
        c.pill:ClearAllPoints()
        c.pill:SetPoint("RIGHT", c, "RIGHT", -14, sub and 8 or 0)
        c.pill:SetPillShown(true)
        local open = not v.cancelled and not past
        c.pill:SetScript("OnClick", open and function(self) answerMenu(self, v, kind) end or nil)
        c.pill:SetScript("OnEnter", function(self)
            if open then UI():SetTextTooltip(self, { "Your answer", "Click to change it." }, "ANCHOR_TOP") end
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
    -- the texts never run under the answer area
    local textW = width - ART_W - DATE_W - 4 - ANS_W
    c.t1:SetWidth(textW)
    c.t2:SetWidth(textW)
    c.meter:SetWidth(textW)
end

-- For other pages (Home): a raid card as the board draws it (a click opens the raid's page on the Raids tab), and a
-- raid's loading screen cropped for a w x h box (file, l, r, t, b; fw = the share of the screen's width shown).
function PlanUI:CreateRaidCard(parent) return newRaidCard(parent) end
function PlanUI:FillRaidCard(card, v, width) fillRaidCard(card, v, width) end
function PlanUI:RaidArt(inst, w, h, fw) return artCoords(inst, w, h, fw) end

---------------------------------------------------------------------------
-- The raid page: Sign-ups as role columns, then the players outside them in labelled boxes
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

-- One player in a column or a box: class circle, name (a guest tag), and on the right a ? for tentative and the
-- spec's icon (its name is in the tooltip). A box shows players as chips.
local function newCellRow(parent, chip)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(chip and CHIP_H or COL_ROW_H)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", cellRowClick)
    b:SetScript("OnEnter", function(self)
        if self.hl then self.hl:Show() end
        cellTooltip(self)
    end)
    b:SetScript("OnLeave", function(self)
        if self.hl then self.hl:Hide() end
        hideTooltip()
    end)
    if chip then panel(b, CARD_BG, { 0.34, 0.34, 0.38, 0.6 }) end
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.06)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(16, 16)
    b.icon:SetPoint("LEFT", chip and 3 or 0, 0)
    b.fs = textOf(b, "GameFontHighlight", 12)
    b.fs:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
    b.tag = textOf(b, "GameFontHighlightSmall", 9)
    b.tag:SetTextColor(0.4, 0.8, 1)
    b.tag:SetPoint("LEFT", b.fs, "RIGHT", 4, 0)
    b.tag:SetText("GUEST")
    b.spec = b:CreateTexture(nil, "ARTWORK")
    b.spec:SetSize(14, 14)
    b.spec:SetPoint("RIGHT", chip and -5 or -1, 0)
    b.spec:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.maybe = b:CreateTexture(nil, "ARTWORK")
    b.maybe:SetSize(12, 12)
    b.maybe:SetTexture("Interface\\RaidFrame\\ReadyCheck-Waiting")
    return b
end

local function fillCellRow(b, cell, chip)
    b.cdlCell = cell
    -- an open slot of the team's comp (1.3.1): a gold ring with the class faint inside, the spec's name in gold
    if cell.open then
        if not b.ring then
            b.ring = b:CreateTexture(nil, "ARTWORK", nil, -2)
            b.ring:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
            b.ring:SetVertexColor(1, 0.82, 0)
            b.ring:SetSize(18, 18)
            b.ring:SetPoint("CENTER", b, "LEFT", 8, 0)
            b.ringIn = b:CreateTexture(nil, "ARTWORK", nil, -1)
            b.ringIn:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
            b.ringIn:SetVertexColor(PANEL_BG[1], PANEL_BG[2], PANEL_BG[3])
            b.ringIn:SetSize(16, 16)
            b.ringIn:SetPoint("CENTER", b.ring, "CENTER", 0, 0)
        end
        b.ring:Show()
        b.ringIn:Show()
        b.icon:ClearAllPoints()
        b.icon:SetSize(12, 12)
        b.icon:SetPoint("CENTER", b.ring, "CENTER", 0, 0)
        UI():ClassIcon(b.icon, cell.c)
        b.icon:SetAlpha(0.35)
        b.fs:SetText(colorize("ffd100", cell.name or "?"))
        b.tag:Hide()
        b.maybe:Hide()
        local icon = ns.RaidComp:SpecIcon(cell.c, cell.sp)
        b.spec:SetShown(icon ~= nil)
        if icon then b.spec:SetTexture(icon) end
        b.spec:SetAlpha(0.35)
        b:SetAlpha(1)
        b:Show()
        return
    end
    if b.ring then
        b.ring:Hide()
        b.ringIn:Hide()
        b.icon:ClearAllPoints()
        b.icon:SetSize(16, 16)
        b.icon:SetPoint("LEFT", chip and 3 or 0, 0)
    end
    b.icon:SetAlpha(1)
    b.spec:SetAlpha(1)
    local s = cell.s
    local cls = classOf(cell.key, s)
    UI():ClassIcon(b.icon, cls)
    if not cls then b.icon:Hide() end
    b.fs:SetText(colored(cell.key, cls) .. ((s and s.n) and grey(" *") or ""))
    b.tag:SetShown(cell.guest and true or false)
    local st = s and s.st
    local icon = not chip and s and s.c and ns.RaidComp:SpecIcon(s.c, s.sp) or nil
    b.spec:SetShown(icon ~= nil)
    if icon then b.spec:SetTexture(icon) end
    b.maybe:SetShown(not chip and st == "T")
    b.maybe:ClearAllPoints()
    b.maybe:SetPoint("RIGHT", icon and b.spec or b, icon and "LEFT" or "RIGHT", -4, 0)
    if chip then
        local w = 3 + 16 + 6 + (b.fs:GetStringWidth() or 60) + (cell.guest and (4 + (b.tag:GetStringWidth() or 28)) or 0) + 9
        b:SetWidth(floor(w + 0.5))
    end
    b:SetAlpha((st == "T" and 0.7) or (cell.dim and 0.6) or 1)
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
    -- 1.3.1: the open slots of the team's target comp, gold at the end of each role column (the counts stay the
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
            cells[#cells + 1] = c
        end
        model.boxes[#model.boxes + 1] = { label = label, color = color, cells = cells, n = #keys }
    end
    -- requests to join first: who runs the raid answers them (a click)
    local requests = RP():GetRequests(v.id)
    if #requests > 0 then
        local cells = {}
        for _, r in ipairs(requests) do
            cells[#cells + 1] = { key = r.key, s = { c = r.c, sp = r.sp, n = r.n }, request = true }
        end
        model.boxes[#model.boxes + 1] = { label = "Requests to join", color = "ffd100", cells = cells, n = #requests,
                                          req = true, hint = RP():CanManageRaid(v) and "click a name to approve or deny" }
    end
    box("Spec not set", STATUS.T.color, other.nospec)
    box("Bench", STATUS.B.color, other.B)
    box("Absent", STATUS.X.color, other.X)
    local out = {}
    for key in pairs(declined) do
        if not signups[key] then out[#out + 1] = key end
    end
    box("Declined", "ff5555", out, nameLess)
    box("No response", "ff9933", noResponse(v, signups), nameLess, true)
    return model
end

-- The Sign-ups view: d.roster = { frame (scroll frame), content, box = { ForEachFrame(fn) } over the columns and boxes
-- (each with .cells, the shown players) }.
local function createRoster(d)
    local sf = UI():CreateScrollFrame(d)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(600, 10)
    sf:SetScrollChild(content)
    local r = { frame = sf, content = content, cols = {}, boxes = {} }
    for i = 1, #COLS do
        local col = CreateFrame("Frame", nil, content)
        panel(col)
        col.role = col:CreateTexture(nil, "ARTWORK")
        col.role:SetTexture(UI().ROLE_TEX)
        col.role:SetSize(16, 16)
        col.role:SetPoint("TOPLEFT", 9, -6)
        col.title = textOf(col, "GameFontNormal", 12)
        col.title:SetPoint("LEFT", col.role, "RIGHT", 6, 0)
        col.count = textOf(col, "GameFontHighlight", 12)
        col.count:SetJustifyH("RIGHT")
        col.count:SetPoint("RIGHT", col, "TOPRIGHT", -10, -14)
        col.rule = col:CreateTexture(nil, "BORDER")
        col.rule:SetColorTexture(1, 1, 1, 0.07)
        col.rule:SetHeight(1)
        col.rule:SetPoint("TOPLEFT", 8, -COL_HEAD_H)
        col.rule:SetPoint("TOPRIGHT", -8, -COL_HEAD_H)
        col.none = textOf(col, "GameFontDisableSmall", 10)
        col.none:SetPoint("TOPLEFT", 10, -COL_HEAD_H - 8)
        col.none:SetText("Nobody yet")
        col.rows = {}
        col.cells = col.rows
        r.cols[i] = col
    end
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

local function refreshRoster(d, v, width)
    local r = d.roster
    local model = rosterModel(v)
    local colW = floor((width - 3 * GAP) / 4)
    local depth = 0
    for i, col in ipairs(r.cols) do
        local m = model.cols[i]
        col:ClearAllPoints()
        -- (the last column takes the rounding, so the right edges line up with the banner's)
        col:SetPoint("TOPLEFT", r.content, "TOPLEFT", (i - 1) * (colW + GAP), 0)
        col:SetWidth(i == #r.cols and (width - 3 * (colW + GAP)) or colW)
        UI():SetRoleIcon(col.role, m.role)
        col.title:SetText(m.label)
        col.count:SetText(m.count .. (m.more > 0 and grey(" +" .. m.more) or ""))
        for j, cell in ipairs(m.cells) do
            local row = col.rows[j] or newCellRow(col)
            col.rows[j] = row
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", col, "TOPLEFT", 9, -COL_HEAD_H - 4 - (j - 1) * COL_ROW_H)
            row:SetPoint("TOPRIGHT", col, "TOPRIGHT", -9, -COL_HEAD_H - 4 - (j - 1) * COL_ROW_H)
            fillCellRow(row, cell, false)
        end
        for j = #m.cells + 1, #col.rows do
            col.rows[j]:Hide()
            col.rows[j].cdlCell = nil
        end
        col.none:SetShown(#m.cells == 0)
        depth = max(depth, #m.cells)
    end
    local colH = COL_HEAD_H + 4 + max(1, depth) * COL_ROW_H + 8
    for _, col in ipairs(r.cols) do col:SetHeight(colH) end
    -- the boxes under the columns, one per kind, the players as chips that wrap
    local y = colH + GAP
    for bi, m in ipairs(model.boxes) do
        local bx = r.boxes[bi]
        if not bx then
            bx = CreateFrame("Frame", nil, r.content)
            panel(bx)
            bx.label = textOf(bx, "GameFontHighlight", 12)
            bx.label:SetPoint("TOPLEFT", 10, -9)
            bx.hint = textOf(bx, "GameFontHighlightSmall", 10)
            bx.hint:SetTextColor(0.55, 0.55, 0.55)
            bx.hint:SetPoint("LEFT", bx.label, "RIGHT", 10, 0)
            bx.rows = {}
            bx.cells = bx.rows
            r.boxes[bi] = bx
        end
        if m.req then
            bx.bg:SetColorTexture(0.13, 0.12, 0.08, 0.94)
            UI():SetEdgeColor(bx, 1, 0.82, 0, 0.55)
        else
            bx.bg:SetColorTexture(PANEL_BG[1], PANEL_BG[2], PANEL_BG[3], PANEL_BG[4])
            UI():SetEdgeColor(bx, EDGE[1], EDGE[2], EDGE[3], EDGE[4])
        end
        bx.label:SetText(colorize(m.color, m.label) .. grey(" (" .. m.n .. ")"))
        bx.hint:SetText(m.hint or "")
        bx:ClearAllPoints()
        bx:SetPoint("TOPLEFT", r.content, "TOPLEFT", 0, -y)
        bx:SetWidth(width)
        local cx, cy = 10, -30
        for j, cell in ipairs(m.cells) do
            local chip = bx.rows[j] or newCellRow(bx, true)
            bx.rows[j] = chip
            fillCellRow(chip, cell, true)
            local w = chip:GetWidth()
            if cx + w > width - 10 and cx > 10 then
                cx, cy = 10, cy - (CHIP_H + CHIP_GAP)
            end
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", bx, "TOPLEFT", cx, cy)
            cx = cx + w + CHIP_GAP
        end
        for j = #m.cells + 1, #bx.rows do
            bx.rows[j]:Hide()
            bx.rows[j].cdlCell = nil
        end
        local h = -cy + CHIP_H + 10
        bx:SetHeight(h)
        bx:Show()
        y = y + h + GAP
    end
    for bi = #model.boxes + 1, #r.boxes do r.boxes[bi]:Hide() end
    r.content:SetWidth(width)
    r.content:SetHeight(max(1, y - GAP))
    -- nobody answered and nobody is waited for: one line instead of four empty columns
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
    StaticPopup_Show("DISASTERZONE_PLAN_DELETE", what, nil, { fn = function()
        local ok, err = RP():DeleteRaid(v.id, scope)
        if not ok then Print(err or "Could not delete the raid.") end
    end })
end

function PlanUI:Confirm(text, fn)
    StaticPopup_Show("DISASTERZONE_PLAN_CONFIRM", text, nil, { fn = fn })
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
        poolLabel = "Not in a group",
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
    board.firstHead = textOf(board, "GameFontNormal", 13)
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

    -- the banner: the raid's art; the way back and the raid's actions on top, its facts bottom left (the countdown
    -- beside the title), my answer bottom right
    local hero = CreateFrame("Frame", nil, d)
    hero:SetPoint("TOPLEFT", PAD, 0)
    hero:SetPoint("TOPRIGHT", -PAD, 0)
    hero:SetHeight(HERO_H)
    d.hero = hero
    hero.art = hero:CreateTexture(nil, "BACKGROUND", nil, 0)
    hero.art:SetPoint("TOPLEFT", 1, -1)
    hero.art:SetPoint("BOTTOMRIGHT", -1, 1)
    hero.shadeB = hero:CreateTexture(nil, "BACKGROUND", nil, 1)
    hero.shadeB:SetAllPoints(hero.art)
    gradient(hero.shadeB, "VERTICAL", 0.035, 0.035, 0.043, 0.92, 0)
    -- (the top row reads on any art)
    hero.shadeT = hero:CreateTexture(nil, "BACKGROUND", nil, 1)
    hero.shadeT:SetPoint("TOPLEFT", hero.art)
    hero.shadeT:SetPoint("TOPRIGHT", hero.art)
    hero.shadeT:SetHeight(48)
    gradient(hero.shadeT, "VERTICAL", 0.035, 0.035, 0.043, 0, 0.7)
    hero.shadeL = hero:CreateTexture(nil, "BACKGROUND", nil, 2)
    hero.shadeL:SetPoint("TOPLEFT", hero.art)
    hero.shadeL:SetPoint("BOTTOMLEFT", hero.art)
    hero.shadeL:SetWidth(460)
    gradient(hero.shadeL, "HORIZONTAL", 0.035, 0.035, 0.043, 0.7, 0)
    hero.shadeR = hero:CreateTexture(nil, "BACKGROUND", nil, 2)
    hero.shadeR:SetPoint("TOPRIGHT", hero.art)
    hero.shadeR:SetPoint("BOTTOMRIGHT", hero.art)
    hero.shadeR:SetWidth(360)
    gradient(hero.shadeR, "HORIZONTAL", 0.035, 0.035, 0.043, 0, 0.6)
    UI():AddEdges(hero, "BORDER")
    UI():SetEdgeColor(hero, EDGE[1], EDGE[2], EDGE[3], 0.7)

    -- its top row: back to the board; the raid's actions (icons, what each does is in its tooltip)
    d.back = CreateFrame("Button", nil, hero)
    d.back:SetHeight(22)
    d.back:SetPoint("TOPLEFT", 10, -8)
    d.back.icon = d.back:CreateTexture(nil, "ARTWORK")
    d.back.icon:SetSize(11, 11)
    d.back.icon:SetPoint("LEFT", 2, 0)
    leftChevron(d.back.icon)
    d.back.text = textOf(d.back, "GameFontHighlight", 12)
    d.back.text:SetPoint("LEFT", d.back.icon, "RIGHT", 5, 0)
    d.back.text:SetText("All raids")
    d.back:SetWidth(floor(2 + 11 + 5 + (d.back.text:GetStringWidth() or 60) + 6))
    local function backColor(self, on)
        if on then self.text:SetTextColor(1, 0.82, 0) else self.text:SetTextColor(0.85, 0.85, 0.85) end
        if on then self.icon:SetVertexColor(1, 0.82, 0) else self.icon:SetVertexColor(0.85, 0.85, 0.85) end
    end
    backColor(d.back, false)
    d.back:SetScript("OnEnter", function(self) backColor(self, true) end)
    d.back:SetScript("OnLeave", function(self) backColor(self, false) end)
    d.back:SetScript("OnClick", function() PlanUI:ShowBoard() end)
    local ACT = 22
    d.cancelBtn = UI():CreateTipIconButton(hero, ACT, 20, "Cancel or delete", "Call the raid off (it stays listed as "
        .. "cancelled), stop a weekly raid from repeating, or delete it.", function(self)
        UI():ContextMenu(self, cancelMenu)
    end)
    function d.cancelBtn:OpenMenu() UI():ContextMenu(self, cancelMenu) end
    d.editBtn = UI():CreateTipIconButton(hero, ACT, 16, "Edit raid", "Change the raid's time, size, teams or note.",
        function()
            if state.selected then PlanUI:OpenEditor(state.selected) end
        end)
    d.inviteBtn = UI():CreateTipIconButton(hero, ACT, 19, "Add players", "Guild members outside the raid's teams (on a "
        .. "locked raid they are the only ones besides the teams), and guests: players who are not in the guild, "
        .. "added by name.", function()
        if state.selected then PlanUI:OpenInvites(state.selected) end
    end)
    d.leaderBtn = UI():CreateTipIconButton(hero, ACT, UI().ICON.crown, "Raid leader", "Choose who leads this raid. "
        .. "They run it with the Guild Master and the raid leaders: edit it, add players, lay out the groups. Its "
        .. "strategies and assignments are theirs and the Guild Master's alone.", function()
        if state.selected then PlanUI:OpenLeader(state.selected) end
    end)
    -- everyone: a link to this raid (and the tab open on it) for the chat, "sign up here" (UI/Share.lua)
    d.shareBtn = ns.Share:CreateButton(hero, ACT, function()
        return state.selected and ns.Share:RaidRef(state.selected, state.detailTab) or nil
    end, "Share this raid")

    d.sub2 = textOf(hero, "GameFontHighlightSmall", 11)
    d.sub2:SetTextColor(0.66, 0.66, 0.66)
    d.sub2:SetPoint("BOTTOMLEFT", 14, 13)
    d.sub = textOf(hero, "GameFontHighlightSmall", 11)
    d.sub:SetTextColor(0.86, 0.86, 0.86)
    d.sub:SetPoint("BOTTOMLEFT", d.sub2, "TOPLEFT", 0, 4)
    d.title = textOf(hero, "GameFontHighlightLarge", 19)
    d.title:SetPoint("BOTTOMLEFT", d.sub, "TOPLEFT", 0, 6)
    d.when = CreateFrame("Frame", nil, hero)
    d.when:SetHeight(18)
    d.when:SetPoint("LEFT", d.title, "RIGHT", 12, 1)
    d.when.bg = d.when:CreateTexture(nil, "BACKGROUND")
    d.when.bg:SetAllPoints()
    d.when.bg:SetColorTexture(0.035, 0.035, 0.043, 0.75)
    UI():AddEdges(d.when)
    UI():SetEdgeColor(d.when, 1, 0.82, 0, 0.4)
    d.when.text = textOf(d.when, "GameFontNormalSmall", 11)
    d.when.text:SetPoint("CENTER", 0, 0)

    -- my answer: the four answers joined; under them my spec, character and note; above them what a request means.
    -- Who can't answer sees why instead (and their answer, on a raid that is over).
    u.statusBtns = {}
    local prev
    for i = #STATUS_ORDER, 1, -1 do
        local st = STATUS_ORDER[i]
        local b = UI():CreateSleekButton(hero, STATUS[st].button, 72, 24, function() PlanUI:Answer(st) end)
        if prev then b:SetPoint("RIGHT", prev, "LEFT", 1, 0) else b:SetPoint("BOTTOMRIGHT", -12, 36) end
        b.st = st
        b:HookScript("OnEnter", function(self)
            if self.chosen and self.since then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine("Your answer")
                GameTooltip:AddLine("Since " .. self.since, 1, 1, 1)
                GameTooltip:Show()
            end
        end)
        b:HookScript("OnLeave", hideTooltip)
        u.statusBtns[st] = b
        prev = b
    end
    d.hint = textOf(hero, "GameFontHighlightSmall", 11)
    d.hint:SetJustifyH("RIGHT")
    d.hint:SetPoint("BOTTOMRIGHT", -12, 36 + 24 + 7)
    d.pill = newPill(hero)
    d.reason = textOf(hero, "GameFontHighlight", 12)
    d.reason:SetJustifyH("RIGHT")

    local mine = CreateFrame("Frame", nil, hero)
    mine:SetHeight(18)
    mine:SetPoint("BOTTOMRIGHT", -12, 11)
    d.mine = mine
    d.asLabel = textOf(mine, "GameFontHighlightSmall", 11)
    d.asLabel:SetTextColor(0.62, 0.62, 0.62)
    d.asLabel:SetText("As")
    u.specDD = linkDropdown(mine, { options = mySpecOptions, selected = function() return mySpec(state.selected) end,
        select = setSpec, title = "Spec", tip = "The spec you come as: it puts you in the right role column." })
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

    -- the raid's own note, under the banner (only when it has one)
    local nl = CreateFrame("Frame", nil, d)
    d.noteLine = nl
    nl.icon = nl:CreateTexture(nil, "ARTWORK")
    nl.icon:SetSize(12, 12)
    nl.icon:SetPoint("TOPLEFT", 2, -1)
    nl.icon:SetTexture(UI().ICON_ATLAS)
    nl.icon:SetTexCoord(unpack(UI():IconCoords(UI().ICON.notes)))
    nl.icon:SetVertexColor(1, 0.82, 0, 0.8)
    nl.fs = nl:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    setSize(nl.fs, 11)
    nl.fs:SetTextColor(0.85, 0.85, 0.85)
    nl.fs:SetJustifyH("LEFT")
    nl.fs:SetPoint("TOPLEFT", nl.icon, "TOPRIGHT", 6, 0)
    nl.fs:SetWordWrap(true)
    nl.fs:SetMaxLines(2)

    -- Sign-ups / Groups / Assignments (Addendum K: the raid's strategy boards, who does what on each boss); the open
    -- tab's context on the right of the same row (the counts, or the Groups actions)
    local tabs = CreateFrame("Frame", nil, d)
    tabs:SetHeight(TABS_H)
    d.tabs = tabs
    local function tab(label, key)
        local b = UI():CreateUnderlineTab(tabs, label, function()
            state.detailTab = key
            PlanUI:RefreshUpcoming()
        end, "small")
        b.key = key
        return b
    end
    d.tabSignups = tab("Sign-ups", "signups")
    d.tabSignups:SetPoint("BOTTOMLEFT", -4, 0)
    d.tabGroups = tab("Groups", "groups")
    d.tabGroups:SetPoint("LEFT", d.tabSignups, "RIGHT", 4, 0)
    d.tabAssign = tab("Assignments", "assign")
    d.tabAssign:SetPoint("LEFT", d.tabGroups, "RIGHT", 4, 0)
    d.tabLine = tabs:CreateTexture(nil, "BORDER")
    d.tabLine:SetPoint("BOTTOMLEFT", 0, 0)
    d.tabLine:SetPoint("BOTTOMRIGHT", 0, 0)
    d.tabLine:SetHeight(1)
    d.tabLine:SetColorTexture(1, 1, 1, 0.1)
    d.counts = textOf(tabs, "GameFontHighlightSmall", 11)
    d.counts:SetJustifyH("RIGHT")
    d.counts:SetPoint("BOTTOMRIGHT", 0, 5)

    createRoster(d)
    createRaidGroups(d)
    d.assign = ns.StrategiesUI:CreateRaidAssignments(d)
    -- its hint is the tab's context, on the right of the tab row
    d.assign.hint:ClearAllPoints()
    d.assign.hint:SetPoint("BOTTOMRIGHT", d.tabs, "BOTTOMRIGHT", 0, 5)
    d.assign.hint:SetJustifyH("RIGHT")
    return u
end

-- The page's parts top to bottom: the crumb, the banner (the same on every tab), the raid's note when it has one,
-- the tab row, the open tab.
local function layoutPage(d, noteH)
    local top = HERO_H + 10
    d.noteLine:ClearAllPoints()
    if noteH > 0 then
        d.noteLine:SetPoint("TOPLEFT", PAD, -top)
        d.noteLine:SetPoint("TOPRIGHT", -PAD, -top)
        d.noteLine:SetHeight(noteH)
        top = top + noteH + 8
    end
    d.noteLine:SetShown(noteH > 0)
    d.tabs:ClearAllPoints()
    d.tabs:SetPoint("TOPLEFT", PAD, -top)
    d.tabs:SetPoint("TOPRIGHT", -PAD, -top)
    top = top + TABS_H + 10
    for _, f in ipairs({ d.roster.frame, d.groups, d.assign }) do
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", PAD, -top)
        f:SetPoint("BOTTOMRIGHT", -PAD, 4)
    end
end

-- The title in the room left of the answers: 19, else 17, else 15 (wrapping to two lines at worst), never cut.
local function fitTitle(fs, text, room)
    fs:SetWordWrap(false)
    fs:SetWidth(0)
    for _, size in ipairs({ 19, 17, 15 }) do
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
    local level = d.hero:GetFrameLevel()
    for st, bt in pairs(upcoming.statusBtns) do
        bt:SetShown(canAnswer)
        bt:SetEnabled(canAnswer)
        -- my saved answer is the lit one (raised, so its coloured edge shows over the shared ones)
        bt.chosen = (mine and mine.st == st) and true or false
        bt.since = bt.chosen and (mine.rev or mine.at) and shortDay(mine.rev or mine.at) or nil
        if bt.chosen then bt:SetTint(hexRGB(STATUS[st].color)) else bt:SetTint(nil) end
        bt:SetFrameLevel(level + (bt.chosen and 3 or 2))
    end
    d.mine:SetShown(canAnswer)
    d.hint:SetText((canAnswer and request and colorize("ffd100", "Request sent: a raid leader will approve it. "
            .. "Absent withdraws it."))
        or (canAnswer and canAsk and colorize("ffd100", "Locked to its teams: pick an answer to ask to join.")) or "")
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
    d.pill:SetPillShown(had and true or false)
    if had then
        local kind = (request and not RP():GetMySignup(v.id)) and "R" or mine.st
        d.pill:Set(kind, PILL_TEXT[kind], nil, PILL_ICON[kind])
        d.pill:ClearAllPoints()
        d.pill:SetPoint("BOTTOMRIGHT", d.hero, "BOTTOMRIGHT", -12, 37)
        d.pill:SetScript("OnClick", nil)
    end
    d.reason:SetText(why or "")
    d.reason:SetShown(why ~= nil)
    d.reason:ClearAllPoints()
    d.reason:SetPoint("BOTTOMRIGHT", d.hero, "BOTTOMRIGHT", -12, had and 14 or 41)
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

local function refreshDetail(v)
    local d = upcoming.detail
    local has = v ~= nil
    local tab = (state.detailTab == "groups" or state.detailTab == "assign") and state.detailTab or "signups"
    for _, region in ipairs({ d.hero, d.tabs, d.back }) do region:SetShown(has) end
    d.empty:SetShown(not has)
    d.roster.frame:SetShown(has and tab == "signups")
    d.groups:SetShown(has and tab == "groups")
    d.assign:SetShown(has and tab == "assign")
    d.counts:SetShown(has and tab == "signups")
    d.tabSignups:SetActive(tab == "signups")
    d.tabGroups:SetActive(tab == "groups")
    d.tabAssign:SetActive(tab == "assign")
    -- who runs this raid: the raid planners (GM, raid leaders) and the raid's own leader
    local organizer = has and RP():CanManageRaid(v)
    d.editBtn:SetShown(organizer)
    d.cancelBtn:SetShown(organizer)
    d.inviteBtn:SetShown(organizer or (has and RP():CanManageRoster(v)))
    d.leaderBtn:SetShown(has and RP():CanAssignLeader())
    d.shareBtn:SetShown(has)
    -- the shown icons sit right to left without gaps (Share at the far right for everyone)
    local prev = nil
    for _, b in ipairs({ d.shareBtn, d.cancelBtn, d.editBtn, d.inviteBtn, d.leaderBtn }) do
        if b:IsShown() then
            b:ClearAllPoints()
            if prev then b:SetPoint("RIGHT", prev, "LEFT", -4, 0) else b:SetPoint("TOPRIGHT", d.hero, "TOPRIGHT", -10, -8) end
            prev = b
        end
    end
    if not has then
        d.noteLine:Hide()
        return
    end

    local width = (d:GetWidth() or 0) - 2 * PAD
    if width < 300 then width = 770 end
    local file, l, r, t, b = artCoords(v.i, width, HERO_H, 0.98)
    d.hero.art:SetTexture(file)
    d.hero.art:SetTexCoord(l, r, t, b)
    d.hero.art:SetDesaturated(v.cancelled and true or false)
    d.when.text:SetText(v.cancelled and "cancelled" or relDay(v.t))
    d.when:SetWidth((d.when.text:GetStringWidth() or 40) + 18)
    fitTitle(d.title, RP():GetRaidName(v) .. (v.cancelled and "  |cffff5555CANCELLED|r" or ""),
        width - 28 - 4 * 72 - 24 - d.when:GetWidth() - 12)
    local inst = RP():GetInstance(v.i)
    d.sub:SetText(("%s · %s · %s%d-player"):format(date("%A ", v.t) .. tonumber(date("%d", v.t)) .. date(" %B", v.t),
        fmtTime(v.t), (inst and inst.key ~= "other") and (inst.name .. " · ") or "", v.sz or 0))
    local who = {}
    if v.rl then who[#who + 1] = colored(v.rl) .. " leads" elseif v.by then who[#who + 1] = "by " .. shortName(v.by) end
    who[#who + 1] = teamNames(v)
    if v.weekly then who[#who + 1] = "every week" end
    d.sub2:SetText(tconcat(who, " · "))
    refreshAnswer(d, v)

    -- the raid's note (two lines at most), then the tabs
    local noteH = 0
    if v.no and v.no ~= "" then
        d.noteLine.fs:SetWidth(width - 20)
        d.noteLine.fs:SetText(v.no)
        noteH = max(14, floor((d.noteLine.fs:GetStringHeight() or 13) + 1.5))
    end
    layoutPage(d, noteH)

    if tab == "groups" then
        refreshGroups(v)
        return
    elseif tab == "assign" then
        ns.StrategiesUI:RefreshRaid(v)
        return
    end
    local c = counts(v.id)
    -- only what the columns don't show at a glance: how full it is, the guests, the maybes
    local accepted = ("%d/%d accepted"):format(c.A, v.sz or 0)
    local parts = { c.A > 0 and colorize(STATUS.A.color, accepted) or grey(accepted) }
    if c.guests > 0 then parts[#parts + 1] = c.guests .. (c.guests == 1 and " guest" or " guests") end
    if c.T > 0 then parts[#parts + 1] = c.T .. " tentative" end
    d.counts:SetText(tconcat(parts, grey(" · ")))
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
                board.firstHead:SetText(d.header)
            else
                hi = hi + 1
                local h = board.heads[hi] or textOf(board.content, "GameFontNormal", 13)
                board.heads[hi] = h
                h:SetText(d.header)
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
    CHIP_H = 22, CARD_H = 88, TOOL_H = 22, BAR_H = 26,
    COL2 = 400,             -- the card's right column (the raids that invite the team): x, and its width 358
    COL2_W = 358,
    NAME_MIN = 140, NAME_MAX = 250,
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
    if t.name ~= ns.Util.Trim(teamsView.nameBox:GetText() or "") then return true end
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
        return next(dr.members) ~= nil or next(dr.cp or {}) ~= nil or #dr.lineups > 1
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
                          prefix = colorize("9e9e9e", w.n .. ". "), noRole = true, n = w.n, waiting = true,
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
    StaticPopup_Show("DISASTERZONE_TEAM_UNSAVED", TV.draftName(), nil, { fn = fn })
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
            local keep = {}
            for _, id in ipairs(v.tm or {}) do
                if id ~= team.id then
                    for _, key in ipairs(RP():GetRaidTeamPlayers(v, id) or {}) do keep[key] = true end
                end
            end
            for _, key in ipairs(v.inv or {}) do keep[key] = true end
            local lose, answers = {}, 0
            for _, key in ipairs(RP():GetRaidTeamPlayers(v, team.id) or {}) do
                if not keep[key] then lose[key] = true end
            end
            if next(lose) then
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
        StaticPopup_Show("DISASTERZONE_TEAM_COMP_SIZE", ("The target comp has %d slots, more than the team's %d.\n\n"
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
        state.team, state.newTeam = nil, true
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
        state.team, state.newTeam = nil, true
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
    local ok, res = RP():SaveTeam(dr.id, teamsView.nameBox:GetText(), dr.members, { lineups = lineups })
    if not ok then
        Print(res or "Could not save the team.")
        return false
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
    if not sure and (next(l.grp) or next(l.cp) or waiting > 0) then
        local parts = {}
        if next(l.grp) then parts[#parts + 1] = "its groups" end
        if next(l.cp) then parts[#parts + 1] = "its target comp" end
        if waiting > 0 then parts[#parts + 1] = ("its waitlist (%d)"):format(waiting) end
        StaticPopup_Show("DISASTERZONE_PLAN_CONFIRM", ("Delete the lineup %s, with %s?\n\nIt goes when you save the "
            .. "team; Undo brings it back until then."):format(colorize("ffd100", TV.lineupName(dr, i)),
            tconcat(parts, ", ")), nil, { fn = function() PlanUI:DeleteLineup(i, true) end })
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
            StaticPopup_Show("DISASTERZONE_LINEUP_NAME", nil, nil, { i = i, name = dr.lineups[i].name or "" })
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
    TV.guard(function()
        state.team, state.newTeam = id, nil
        TV.load(id)
        PlanUI:RefreshTeams()
    end)
end

-- ... > Delete: asks with what it changes, then deletes the team for everyone.
function PlanUI:DeleteTeam()
    local team = state.team and RP():GetTeam(state.team)
    if not team or not RP():CanManageTeams() then return end
    StaticPopup_Show("DISASTERZONE_TEAM_DELETE", TV.deleteText(team), nil, { fn = function()
        local ok, err = RP():DeleteTeam(team.id)
        if not ok then
            Print(err or "Could not delete the team.")
            return
        end
        state.team, state.draft, state.newTeam = nil, nil, nil
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

-- A team chip: [gold dot (mine)] name [size]. The press offset of sleek buttons is left out (the text is laid out).
-- onPick(chip, button) (optional, the lineup chips): the click; else the chip opens its team. entry.tip = the lines
-- of its tooltip (else "You're on this team." on mine).
function TV.newChip(parent, onPick)
    local c = UI():CreateSleekButton(parent, "", 60, TV.CHIP_H, function(self, button)
        if onPick then return onPick(self, button) end
        local e = self.entry
        if e and not e.new then PlanUI:SelectTeam(e.id) end
    end)
    if onPick then c:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    c:SetScript("OnMouseDown", nil)
    c:SetScript("OnMouseUp", nil)
    c.dot = c:CreateTexture(nil, "ARTWORK")
    c.dot:SetSize(6, 6)
    c.dot:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    c.dot:SetVertexColor(1, 0.82, 0)
    c.name = textOf(c, "GameFontHighlight", 12)
    c.size = textOf(c, "GameFontHighlightSmall", 10)
    c.size:SetTextColor(0.62, 0.62, 0.62)
    c:HookScript("OnEnter", function(self)
        local e = self.entry
        if not e or not (e.tip or e.mine) then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(e.name)
        if e.tip then
            for _, line in ipairs(e.tip) do GameTooltip:AddLine(line[1], line[2] or 1, line[3] or 1, line[4] or 1, true) end
        else
            GameTooltip:AddLine("You're on this team.", 1, 0.82, 0)
        end
        GameTooltip:Show()
    end)
    c:HookScript("OnLeave", hideTooltip)
    return c
end

function TV.fillChip(c, e, chosen)
    c.entry = e
    c:SetKind(chosen and "chosen" or "secondary")
    c.dot:SetShown(e.mine and true or false)
    c.name:SetText(e.name)
    c.size:SetText(e.size and tostring(e.size) or "")
    c.size:SetShown(e.size ~= nil)
    local x = 10
    c.dot:ClearAllPoints()
    if e.mine then
        c.dot:SetPoint("LEFT", c, "LEFT", x, 0)
        x = x + 6 + 7
    end
    c.name:ClearAllPoints()
    c.name:SetPoint("LEFT", c, "LEFT", x, 0)
    x = x + (c.name:GetStringWidth() or 40)
    c.size:ClearAllPoints()
    if e.size then
        c.size:SetPoint("LEFT", c.name, "RIGHT", 7, 0)
        x = x + 7 + (c.size:GetStringWidth() or 12)
    end
    c:SetWidth(floor(x + 10 + 0.5))
end

-- The chips: one per team (and the new draft), only with two or more. What doesn't fit 770 px goes into a "+n"
-- menu; the open team always keeps its chip. Returns the height they take (with the GAP under them), or 0.
function TV.layoutChips(teams)
    local t = teamsView
    local list = {}
    -- (the teams I'm on first, then the others; by name within each)
    for pass = 1, 2 do
        for _, tm in ipairs(teams) do
            local mine = TV.myKey(tm.members) ~= nil
            if mine == (pass == 1) then
                list[#list + 1] = { id = tm.id, name = tm.name, mine = mine }
            end
        end
    end
    if state.newTeam then list[#list + 1] = { new = true, name = TV.NEW_NAME } end
    for _, c in ipairs(t.chips) do c:Hide() end
    t.chipMore:Hide()
    if #list < 2 then return 0 end
    local sel = #list
    for i, e in ipairs(list) do
        if (e.new and state.newTeam) or (not e.new and not state.newTeam and e.id == state.team) then sel = i end
    end
    local total = 0
    for i, e in ipairs(list) do
        local c = t.chips[i]
        if not c then
            c = TV.newChip(t.detail)
            t.chips[i] = c
        end
        TV.fillChip(c, e, i == sel)
        e.w = c:GetWidth()
        total = total + e.w + (i > 1 and 6 or 0)
    end
    local shown = {}
    local rest = {}
    if total <= TV.W then
        for i in ipairs(list) do shown[i] = true end
    else
        -- the open chip first, then the others in order while they fit beside "+n"
        local limit, used = TV.W - 52 - 6, list[sel].w
        shown[sel] = true
        for i, e in ipairs(list) do
            if i ~= sel and used + 6 + e.w <= limit then
                shown[i] = true
                used = used + 6 + e.w
            end
        end
        for i, e in ipairs(list) do if not shown[i] then rest[#rest + 1] = e end end
    end
    local x = 0
    for i, c in ipairs(t.chips) do
        if shown[i] then
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", t.detail, "TOPLEFT", PAD + x, 0)
            c:Show()
            x = x + c:GetWidth() + 6
        end
    end
    if #rest > 0 then
        t.chipMore.rest = rest
        t.chipMore:SetText("+" .. #rest)
        t.chipMore:ClearAllPoints()
        t.chipMore:SetPoint("TOPLEFT", t.detail, "TOPLEFT", PAD + x, 0)
        t.chipMore:Show()
    end
    return TV.CHIP_H + 8
end

-- A raid on the card: its loading screen as a thumb, the day, its name (shorter forms when long, never cut), the
-- lock; my answer (members) or how many of the team accepted (organizers). A click opens the raid.
function TV.newRaidRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(22)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.06)
    r.th = CreateFrame("Frame", nil, r)
    r.th:SetSize(36, 22)
    r.th:SetPoint("LEFT", 0, 0)
    r.th.tex = r.th:CreateTexture(nil, "ARTWORK")
    r.th.tex:SetPoint("TOPLEFT", 1, -1)
    r.th.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    UI():AddEdges(r.th, "BORDER")
    UI():SetEdgeColor(r.th, EDGE[1], EDGE[2], EDGE[3], 0.7)
    r.day = textOf(r, "GameFontNormalSmall", 10)
    r.day:SetPoint("LEFT", r.th, "RIGHT", 7, 0)
    r.name = textOf(r, "GameFontHighlight", 12)
    r.name:SetPoint("LEFT", r.th, "RIGHT", 7 + 42, 0)
    r.lock = r:CreateTexture(nil, "ARTWORK")
    r.lock:SetSize(12, 12)
    r.lock:SetTexture(UI().ICON_LOCK)
    r.lock:SetPoint("LEFT", r.name, "RIGHT", 5, 0)
    r.status = textOf(r, "GameFontHighlightSmall", 11)
    r.status:SetJustifyH("RIGHT")
    r.status:SetPoint("RIGHT", r, "RIGHT", 0, 0)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(12, 12)
    r.icon:SetPoint("RIGHT", r.status, "LEFT", -4, 0)
    r:SetScript("OnEnter", function(self)
        raidRowTooltip(self)
        GameTooltip:AddLine("Its groups start from this team's groups.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", hideTooltip)
    r:SetScript("OnClick", function(self)
        local v = self.__cdlData and self.__cdlData.v
        if not v then return end
        TV.guard(function()
            ns.RaidsUI:SetView("upcoming")
            PlanUI:SelectRaid(v.id)
        end)
    end)
    return r
end

TV.ANSWER = { A = { "8fe39d", "Interface\\RaidFrame\\ReadyCheck-Ready" },
                      T = { "ffd100", "Interface\\RaidFrame\\ReadyCheck-Waiting" }, B = { "99bbff" },
                      X = { "ff5555", "Interface\\RaidFrame\\ReadyCheck-NotReady" }, R = { "ffd100" } }

function TV.fillRaidRow(r, v, team, organizer)
    r.__cdlData = { v = v }
    local file, l, rr, t, b = artCoords(v.i, 36, 22, 0.30)
    r.th.tex:SetTexture(file)
    r.th.tex:SetTexCoord(l, rr, t, b)
    r.day:SetText(TV.day(v.t):upper())
    r.lock:SetShown(RP():IsLocked(v))
    -- the answer (members) / the team's acceptances (organizers)
    local icon
    if organizer then
        local n, of = TV.accepted(v, team)
        r.status:SetText(colorize("ffffff", n) .. colorize("c4c4c4", (" of %d accepted"):format(of)))
    else
        local kind, block, canAnswer = myState(v)
        local look = TV.ANSWER[kind]
        if look then
            r.status:SetText(colorize(look[1], PILL_TEXT[kind]))
            icon = look[2]
        elseif kind == "N" and canAnswer then
            r.status:SetText(colorize("ffd100", "Answer"))
        else
            r.status:SetText(grey(blockWords(v, block, false) or ""))
        end
    end
    r.icon:SetShown(icon ~= nil)
    if icon then r.icon:SetTexture(icon) end
    -- the name: the raid's title, else shorter forms, so it never runs under the answer
    local room = TV.COL2_W - 36 - 7 - 42 - (r.lock:IsShown() and 17 or 0) - (r.status:GetStringWidth() or 90)
        - (icon and 16 or 0) - 10
    local inst = RP():GetInstance(v.i)
    for _, text in ipairs({ RP():GetRaidName(v), inst and inst.name, TV.SHORT[v.i] }) do
        if text then
            r.name:SetText(text)
            if (r.name:GetStringWidth() or 0) <= room then break end
        end
    end
    r:Show()
end

-- The card's left column, stacked: line 1 (the name), line 2 (the roster), line 3 (me, who changed it). Rows that
-- hold nothing fold away; the card grows if a row is added.
function TV.layoutCard()
    local card = teamsView.card
    local y, last = 12, 0
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
    for _, size in ipairs({ 15, 13, 11 }) do
        setSize(m, size)
        m:SetText(text)
        local w = (m:GetStringWidth() or 0) + 6 + inset + 2
        if w <= TV.NAME_MAX or size == 11 then
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

    -- the team chips (made on demand) and "+n" for the teams that don't fit
    t.chips = {}
    t.chipMore = UI():CreateSleekMenuButton(d, "", 52, function(root)
        for _, e in ipairs(t.chipMore.rest or {}) do
            root:CreateButton((e.mine and colorize("ffd100", "• ") or "") .. e.name, function()
                if not e.new then PlanUI:SelectTeam(e.id) end
            end)
        end
    end, TV.CHIP_H)

    -- the team card: the next raid's loading screen behind its right part
    local card = CreateFrame("Frame", nil, d)
    card:SetSize(TV.W, TV.CARD_H)
    panel(card, CARD_BG, { EDGE[1], EDGE[2], EDGE[3], 0.6 })
    t.card = card
    card.art = card:CreateTexture(nil, "BACKGROUND", nil, 2)
    card.art:SetPoint("TOPRIGHT", -1, -1)
    card.art:SetPoint("BOTTOMRIGHT", -1, 1)
    card.art:SetWidth(470)
    card.art:SetVertexColor(0.52, 0.52, 0.52)
    card.fade = card:CreateTexture(nil, "BACKGROUND", nil, 3)
    card.fade:SetPoint("TOPLEFT", card.art, "TOPLEFT", 0, 0)
    card.fade:SetPoint("BOTTOMLEFT", card.art, "BOTTOMLEFT", 0, 0)
    card.fade:SetWidth(250)
    gradient(card.fade, "HORIZONTAL", CARD_BG[1], CARD_BG[2], CARD_BG[3], 1, 0)

    local colW = TV.COL2 - 12 - 12
    local l1, l2, l3 = CreateFrame("Frame", nil, card), CreateFrame("Frame", nil, card), CreateFrame("Frame", nil, card)
    l1:SetSize(colW, 24)
    l1.gapBelow = 8
    l2:SetSize(colW, 16)
    l3:SetSize(colW, 14)
    card.l1, card.l2, card.l3 = l1, l2, l3
    card.rows = { l1, l2, l3 }

    -- line 1: the name (a field for organizers, growing with the name; each lineup has its size)
    card.title = textOf(l1, "GameFontHighlightLarge", 16)
    card.title:SetPoint("LEFT", l1, "LEFT", 0, 0)
    t.nameBox = UI():CreateSleekEditBox(l1, TV.NAME_MIN, 24, "GameFontHighlightLarge")
    t.nameBox:SetTextInsets(6, 24, 0, 0)
    t.nameBox:SetMaxLetters(32)
    t.nameBox:SetPoint("LEFT", l1, "LEFT", 0, 0)
    t.nameBox.measure = textOf(l1, "GameFontHighlightLarge", 15)
    t.nameBox.measure:SetPoint("LEFT", l1, "LEFT", 0, 0)
    t.nameBox.measure:Hide()
    t.nameBox.pencil = t.nameBox:CreateTexture(nil, "ARTWORK")
    t.nameBox.pencil:SetSize(12, 12)
    t.nameBox.pencil:SetPoint("RIGHT", -6, 0)
    t.nameBox.pencil:SetTexture(UI().ICON_ATLAS)
    t.nameBox.pencil:SetTexCoord(unpack(UI():IconCoords(16)))
    t.nameBox.pencil:SetVertexColor(0.55, 0.55, 0.55)
    t.nameBox:SetScript("OnTextChanged", function()
        TV.fitName()
        PlanUI:RefreshTeamButtons()
    end)
    t.nameBox:HookScript("OnEditFocusGained", function(self)
        self.pencil:Hide()
        self:SetTextInsets(6, 10, 0, 0)
        TV.fitName()
    end)
    t.nameBox:HookScript("OnEditFocusLost", function(self)
        self.pencil:Show()
        self:SetTextInsets(6, 24, 0, 0)
        TV.fitName()
    end)

    -- line 2: the roster
    card.count = textOf(l2, "GameFontHighlightSmall", 11)
    card.count:SetPoint("LEFT", l2, "LEFT", 0, 0)

    -- under the card: the lineup chips (organizers: "+ Lineup" after them), on the right the open lineup's meter (a
    -- target comp) or its players in groups by role; under them its Needs (the open slots)
    local lrow = CreateFrame("Frame", nil, d)
    lrow:SetSize(TV.W, TV.CHIP_H)
    d.lrow = lrow
    d.lchips = {}
    d.lmore = UI():CreateSleekMenuButton(lrow, "", 52, function(root)
        for _, e in ipairs(d.lmore.rest or {}) do
            root:CreateButton((e.mine and colorize("ffd100", "• ") or "") .. e.name, function() PlanUI:SelectLineup(e.i) end)
        end
    end, TV.CHIP_H)
    d.ladd = UI():CreateSleekMenuButton(lrow, "+ Lineup", 78, function(root)
        root:CreateTitle("New lineup")
        root:CreateButton("10-man", function() PlanUI:AddLineup(10) end)
        root:CreateButton("25-man", function() PlanUI:AddLineup(25) end)
    end, TV.CHIP_H)
    tipButton(d.ladd, "New lineup", "Another 10- or 25-player setup of this roster (e.g. Kara A and Kara B), with its own "
        .. "groups, specs, target comp and waitlist.")
    d.lmeter = TV.createMeter(lrow)
    d.lmeter:SetPoint("RIGHT", lrow, "RIGHT", 0, 0)
    d.lmeter:Hide()
    local lN = CreateFrame("Frame", nil, d)
    lN:SetSize(TV.W, 16)
    lN:Hide()
    d.lneeds = lN
    TV.createNeeds(lN)
    local roles = CreateFrame("Frame", nil, lrow)
    roles:SetSize(150, 16)
    roles:SetPoint("RIGHT", lrow, "RIGHT", 0, 0)
    roles.items = {}
    for i, role in ipairs({ "tank", "healer", "dps" }) do
        local it = { icon = roles:CreateTexture(nil, "ARTWORK"), fs = textOf(roles, "GameFontHighlight", 12) }
        it.icon:SetSize(14, 14)
        it.icon:SetTexture(UI().ROLE_TEX)
        it.icon:SetTexCoord(UI():RoleCoords(role))
        it.fs:SetPoint("LEFT", it.icon, "RIGHT", 4, 0)
        it.role = role
        roles.items[i] = it
    end
    function roles:Set(n)
        local x = 0
        for _, it in ipairs(self.items) do
            it.icon:ClearAllPoints()
            it.icon:SetPoint("LEFT", self, "LEFT", x, 0)
            it.fs:SetText(n[it.role] or 0)
            x = x + 14 + 4 + (it.fs:GetStringWidth() or 8) + 14
        end
        self:SetWidth(max(1, floor(x - 14 + 0.5)))
    end
    roles:EnableMouse(true)
    roles:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("In this lineup's groups")
        GameTooltip:AddLine("Tanks, healers and damage. Unassigned and waitlisted players don't count.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    roles:SetScript("OnLeave", hideTooltip)
    d.lroles = roles

    -- line 3: where I play in it (members on the team), who changed it last
    local you = CreateFrame("Button", nil, l3)
    you:SetHeight(14)
    you:SetPoint("LEFT", l3, "LEFT", 0, 0)
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
    card.changed = textOf(l3, "GameFontHighlightSmall", 11)

    -- the right column: the raids that invite the team (or what a team is for), the team's ... menu
    local right = CreateFrame("Frame", nil, card)
    right:SetPoint("TOPLEFT", TV.COL2, -8)
    right:SetPoint("BOTTOMRIGHT", -12, 8)
    card.right = right
    right.label = textOf(right, "GameFontNormalSmall", 10)
    right.label:SetPoint("LEFT", right, "TOPLEFT", 0, -11)
    right.label:SetText("NEXT RAIDS")
    d.moreBtn = UI():CreateTipIconButton(right, 22, UI().ICON.more, "Team actions",
        "Copy, Clear groups, LF message or Delete.", function(self) TV.moreMenu(self) end)
    d.moreBtn:SetPoint("TOPRIGHT", 0, 0)
    right.extra = CreateFrame("Button", nil, right)
    right.extra:SetHeight(22)
    right.extra.fs = textOf(right.extra, "GameFontHighlightSmall", 11)
    right.extra.fs:SetTextColor(0.62, 0.62, 0.62)
    right.extra.fs:SetPoint("RIGHT", 0, 0)
    right.extra:SetScript("OnEnter", TV.raidsTooltip)
    right.extra:SetScript("OnLeave", hideTooltip)
    right.rows = {}
    for i = 1, 2 do
        local r = TV.newRaidRow(right)
        r:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -26 - (i - 1) * 24)
        r:SetPoint("TOPRIGHT", right, "TOPRIGHT", 0, -26 - (i - 1) * 24)
        right.rows[i] = r
    end
    right.note = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    setSize(right.note, 11)
    right.note:SetWidth(TV.COL2_W)
    right.note:SetJustifyH("LEFT")
    right.note:SetJustifyV("TOP")
    right.note:SetSpacing(3)

    -- the tool row (organizers): Add members and Auto-fill; "Changed, not saved", Undo and Save once something changed
    local tool = CreateFrame("Frame", nil, d)
    tool:SetSize(TV.W, TV.TOOL_H)
    d.tool = tool
    t.picker = UI():CreateSearchDropdown(tool, 236, {
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
    t.picker.frame:SetPoint("TOPLEFT", tool, "TOPLEFT", 0, 0)
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
    d.autoBtn:SetPoint("LEFT", t.picker.frame, "RIGHT", GAP, 0)
    tipButton(d.autoBtn, "Auto-fill groups", "A starting layout: tanks, melee groups with a shaman each, casters, "
        .. "healers. Adjust it by dragging, then Save.")
    d.saveBtn = UI():CreateSleekButton(tool, "Save", 56, 22, function() PlanUI:SaveTeam() end, "primary")
    d.saveBtn:SetPoint("TOPRIGHT", tool, "TOPRIGHT", 0, 0)
    d.revertBtn = UI():CreateSleekButton(tool, "Undo", 56, 22, function() PlanUI:RevertTeam() end)
    d.revertBtn:SetPoint("RIGHT", d.saveBtn, "LEFT", -4, 0)
    d.status = textOf(tool, "GameFontHighlightSmall", 11)
    d.status:SetTextColor(1, 0.6, 0.2)
    d.status:SetPoint("RIGHT", d.revertBtn, "LEFT", -12, 0)

    -- (the Groups | Comp underline tabs of a team's target comp go here, between the card and the tool row; while
    -- d.views is hidden the rows below sit right under the card)
    d.views = CreateFrame("Frame", nil, d)
    d.views:SetSize(TV.W, 24)
    d.views:Hide()

    -- the grid's bar: the raid buffs alone (no label, no caption: less is more)
    local bar = CreateFrame("Frame", nil, d)
    bar:SetSize(TV.W, TV.BAR_H)
    d.bar = bar
    d.buffs = CreateFrame("Frame", nil, bar)
    d.buffs:SetPoint("LEFT", bar, "LEFT", 2, 0)
    d.buffs:SetSize(1, 22)

    d.scroll = UI():CreateScrollFrame(d)
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
        waitlist = {
            label = "Waitlist",
            tip = { "Waitlist", "Not on the roster: players waiting for a spot in this lineup, first in line first. "
                .. "Guild members put themselves on it; they aren't invited to the team's raids and don't count for "
                .. "its comp." },
            getMembers = TV.waitMembers,
            empty = TV.waitEmpty,
        },
        stripParent = d.buffs,
        stripRoom = function() return d.stripRoom end,
        buffStates = function(placed) return TV.groupStates(placed) end,
    })
    t.grid.frame:SetWidth(TV.W)
    d.scroll:SetScrollChild(t.grid.frame)
    -- the waitlist's header: Join / Leave for a guild member who isn't on the roster
    d.joinBtn = UI():CreateSleekButton(t.grid.wait, "Join the waitlist", 128, 20, function(self) TV.joinClick(self) end)
    d.joinBtn:SetPoint("TOPRIGHT", t.grid.wait, "TOPRIGHT", -6, -4)
    setSize(d.joinBtn:GetFontString(), 11)
    d.joinBtn:Hide()
    -- the target comp: the Groups | Comp tabs, the Comp view
    TV.createComp(t, d)

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
        if not TV.unsaved() then return end
        StaticPopup_Show("DISASTERZONE_TEAM_UNSAVED", TV.draftName(), nil, { stay = function()
            if ns.MainFrame and ns.MainFrame.Open then ns.MainFrame:Open("raids") end
            if ns.RaidsUI and ns.RaidsUI.SetView then ns.RaidsUI:SetView("teams") end
        end })
    end)
    return t
end

-- The team's ... menu (organizers, a saved team): Copy, Clear groups (when there are groups), LF message (open
-- slots), Delete.
function TV.moreMenu(owner)
    local dr = state.draft
    if not dr or not dr.id then return end
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

-- Line 1-3 of the card and its right column.
function TV.fillCard(dr, organizer)
    local t = teamsView
    local card = t.card
    local saved = dr.id and RP():GetTeam(dr.id) or nil
    local n = TV.count(dr.members)
    -- line 1
    t.nameBox:SetShown(organizer)
    card.title:SetShown(not organizer)
    if organizer then
        TV.fitName()
    else
        card.title:SetText(dr.name)
        setSize(card.title, 16)
        if (card.title:GetStringWidth() or 0) > TV.COL2 - 24 - 80 then setSize(card.title, 13) end
    end
    -- line 2: the roster
    card.count:SetText(grey(n == 0 and "No members yet" or n == 1 and "1 on the roster" or (n .. " on the roster")))
    -- line 3: "You: Group 5 · Holy" (in the open lineup), "You: #2 on the waitlist", who changed it last
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
    local changed = saved and TV.changed(saved, you:IsShown()) or nil
    card.changed:ClearAllPoints()
    if you:IsShown() then card.changed:SetPoint("LEFT", you.fs, "RIGHT", 6, 0)
    else card.changed:SetPoint("LEFT", card.l3, "LEFT", 0, 0) end
    card.changed:SetText(changed and ((you:IsShown() and grey("· ") or "") .. changed) or "")
    -- (beside my line only while it fits the column: the raids are on the right)
    if you:IsShown() and you:GetWidth() + 6 + (card.changed:GetStringWidth() or 0) > TV.COL2 - 24 then
        card.changed:SetText("")
    end
    card.l3:SetShown(you:IsShown() or changed ~= nil)
    TV.layoutCard()

    -- the right column
    local right = card.right
    local raids = saved and TV.raids(saved.id) or {}
    t.detail.moreBtn:SetShown(organizer and saved ~= nil)
    right.label:SetShown(#raids > 0)
    for i, r in ipairs(right.rows) do
        if raids[i] then TV.fillRaidRow(r, raids[i], saved, organizer) else r:Hide() end
    end
    right.extra.raids = raids
    right.extra:SetShown(#raids > 2)
    if #raids > 2 then
        right.extra.fs:SetText(("+%d more"):format(#raids - 2))
        right.extra:SetWidth(floor((right.extra.fs:GetStringWidth() or 50) + 0.5))
        right.extra:ClearAllPoints()
        if t.detail.moreBtn:IsShown() then right.extra:SetPoint("RIGHT", t.detail.moreBtn, "LEFT", -10, 0)
        else right.extra:SetPoint("TOPRIGHT", right, "TOPRIGHT", 0, 0) end
    end
    local v = raids[1]
    card.art:SetShown(v ~= nil)
    card.fade:SetShown(v ~= nil)
    if v then
        local file, l, r, tt, b = artCoords(v.i, 470, floor(card:GetHeight() - 2 + 0.5), 0.62)
        card.art:SetTexture(file)
        card.art:SetTexCoord(l, r, tt, b)
    end
    if not saved then
        right.note:SetText(colorize("9e9e9e", "Once it is saved, raid leaders can invite it when they plan a raid, and "
            .. "its groups become the raid's starting groups."))
    elseif #raids == 0 then
        right.note:SetText(colorize("d0d0d0", "No raid invites this team yet.") .. "\n" .. colorize("9e9e9e",
            "Raid leaders pick it when they plan a raid" .. (organizer and " (New raid › Teams)." or ".")))
    end
    right.note:SetShown(not saved or #raids == 0)
    -- (centred in the column: its height is the card's less 16)
    local noteH = right.note:GetStringHeight() or 0
    if noteH < 10 then noteH = 30 end
    right.note:ClearAllPoints()
    right.note:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -floor((card:GetHeight() - 16 - noteH) / 2 + 0.5))
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
    d.status:SetShown(dirty)
    d.revertBtn:SetText(new and "Cancel" or "Undo")
    d.revertBtn:SetWidth(new and 64 or 56)
    d.status:SetText(new and "New team, not saved" or "Changed, not saved")
end

function PlanUI:RefreshTeams()
    if not teamsView or not teamsView:IsVisible() then return end
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
    d:SetShown(dr ~= nil)
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

    -- the target comp: who fills which slot (nil without one), the strip's states
    local m = TV.match(dr)
    TV.cur = { match = m }
    TV.states = m and TV.compStates(dr) or nil
    -- the Groups | Comp tabs: organizers always, members once the team has a comp
    local showTabs = organizer or m ~= nil
    if not showTabs then state.teamTab = "groups" end
    local tab = state.teamTab == "comp" and "comp" or "groups"
    d.views:SetShown(showTabs)
    d.tabGroups:SetActive(tab == "groups")
    d.tabComp:SetActive(tab == "comp")
    d.tabComp:SetLabel(m and ("Comp  " .. colorize("9e9e9e", m.filled .. "/" .. m.total)) or "Comp")

    -- top to bottom: chips, card, the lineups (and the open one's Needs), the tabs, then Groups (tool row, the grid's
    -- bar, the grid) or Comp
    local y = TV.layoutChips(teams)
    TV.fillCard(dr, organizer)
    t.card:ClearAllPoints()
    t.card:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, -y)
    y = y + t.card:GetHeight() + GAP
    TV.layoutLineups(dr, organizer, m)
    d.lrow:ClearAllPoints()
    d.lrow:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, -y)
    y = y + TV.CHIP_H + 6
    d.lneeds:SetShown(m ~= nil and #m.open > 0)
    if d.lneeds:IsShown() then
        TV.fillNeeds(d.lneeds, m.open)
        d.lneeds:ClearAllPoints()
        d.lneeds:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, -y)
        y = y + 16 + 6
    end
    y = y + GAP - 6
    if d.views:IsShown() then
        d.views:ClearAllPoints()
        d.views:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, -y)
        y = y + d.views:GetHeight() + GAP
    end
    local groups = tab == "groups"
    d.bar:SetShown(groups)
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
    if organizer then
        d.tool:ClearAllPoints()
        d.tool:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, -y)
        y = y + TV.TOOL_H + GAP
    end
    self:RefreshTeamButtons()
    d.bar:ClearAllPoints()
    d.bar:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, -y)
    y = y + TV.BAR_H + 6
    d.stripRoom = TV.W - 4
    d.scroll:ClearAllPoints()
    d.scroll:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, -y)
    d.scroll:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -PAD, 0)
    t.grid.frame:SetWidth(TV.W)
    TV.fillJoin(dr)
    t.grid:Refresh()
    if t.picker.IsOpen and t.picker:IsOpen() then t.picker:Refresh(true) end
end

-- The lineup chips under the card: "Kara A 10" (a default name says its size: "25-man"), the open one chosen, a gold
-- dot on those I'm in a group of; organizers get "+ Lineup" after them. On the right, the open lineup's meter (m: its
-- comp) or its players in groups by role. Chips that don't fit go into "+n" (the open one always keeps its chip). A
-- click opens a lineup; on the open one (or a right-click) organizers get its menu (TV.lineupMenu).
function TV.layoutLineups(dr, organizer, m)
    local d = teamsView.detail
    local row = d.lrow
    local right = 0
    d.lmeter:SetShown(m ~= nil)
    if m then
        TV.fillMeter(d.lmeter, m)
        right = d.lmeter:GetWidth()
    end
    local placed = {}
    for _, mem in ipairs(TV.members()) do
        if TV.inGroup(dr, mem.key) then placed[#placed + 1] = mem end
    end
    d.lroles:SetShown(m == nil and #placed > 0)
    if d.lroles:IsShown() then
        d.lroles:Set(TV.roleCounts(placed))
        right = d.lroles:GetWidth()
    end
    -- the chips
    local me = TV.myKey(dr.members)
    local list = {}
    for i, l in ipairs(dr.lineups) do
        local g = me and l.grp[me]
        local mine = type(g) == "number" and g >= 1 and g <= ns.RaidComp:GroupCount(l.sz)
        local tip = { { l.sz .. "-player lineup", 0.62, 0.62, 0.62 } }
        if mine then tip[#tip + 1] = { "You're in its groups.", 1, 0.82, 0 } end
        if l.id == nil and dr.id ~= nil then tip[#tip + 1] = { "New: saved with the team.", 1, 0.6, 0.2 } end
        if organizer then
            tip[#tip + 1] = { i == dr.li and "Click for Rename, Size, Copy or Delete." or "Click to open it; right-click "
                .. "for Rename, Size, Copy or Delete.", 0.6, 0.6, 0.6 }
        end
        list[i] = { i = i, name = TV.lineupName(dr, i), size = l.name and l.sz or nil, mine = mine, tip = tip }
    end
    for _, c in ipairs(d.lchips) do c:Hide() end
    d.lmore:Hide()
    local widths, total = {}, 0
    for i, e in ipairs(list) do
        local c = d.lchips[i]
        if not c then
            c = TV.newChip(row, function(self, button)
                local idx = self.entry and self.entry.i
                if not idx then return end
                if RP():CanManageTeams() and (button == "RightButton" or idx == state.draft.li) then
                    TV.lineupMenu(self, idx)
                elseif button ~= "RightButton" then
                    PlanUI:SelectLineup(idx)
                end
            end)
            d.lchips[i] = c
        end
        TV.fillChip(c, e, i == dr.li)
        widths[i] = c:GetWidth()
        total = total + widths[i] + (i > 1 and 6 or 0)
    end
    local addW = organizer and (6 + d.ladd:GetWidth()) or 0
    local room = TV.W - addW - (right > 0 and (right + 16) or 0)
    local shown, rest = {}, {}
    if total <= room then
        for i in ipairs(list) do shown[i] = true end
    else
        local limit, used = room - 52 - 6, widths[dr.li]
        shown[dr.li] = true
        for i in ipairs(list) do
            if i ~= dr.li and used + 6 + widths[i] <= limit then
                shown[i] = true
                used = used + 6 + widths[i]
            end
        end
        for i, e in ipairs(list) do if not shown[i] then rest[#rest + 1] = e end end
    end
    local x = 0
    for i, c in ipairs(d.lchips) do
        if shown[i] and list[i] then
            c:ClearAllPoints()
            c:SetPoint("LEFT", row, "LEFT", x, 0)
            c:Show()
            x = x + widths[i] + 6
        end
    end
    if #rest > 0 then
        d.lmore.rest = rest
        d.lmore:SetText("+" .. #rest)
        d.lmore:ClearAllPoints()
        d.lmore:SetPoint("LEFT", row, "LEFT", x, 0)
        d.lmore:Show()
        x = x + 52 + 6
    end
    d.ladd:SetShown(organizer)
    if organizer then
        d.ladd:ClearAllPoints()
        d.ladd:SetPoint("LEFT", row, "LEFT", x, 0)
    end
end

-- The waitlist's empty line: organizers always see the waitlist (what it is for); players who aren't on the roster
-- see it to join; roster members only once someone waits. nil = hidden while empty.
function TV.waitEmpty()
    local dr = state.draft
    if not dr or not dr.id or not dr.ln then return nil end
    if RP():CanManageTeams() then
        return "Nobody is waiting. Guild members who aren't on the roster put themselves on this lineup's waitlist here."
    end
    if TV.myKey(dr.members) then return nil end
    return "Nobody is waiting for a spot yet."
end

-- The waitlist's Join / Leave button: for me when I'm not on the roster (a saved lineup).
function TV.fillJoin(dr)
    local b = teamsView.detail.joinBtn
    local me = ns.Util.PlayerKey()
    local show = dr.id ~= nil and dr.ln ~= nil and not dr.members[me] and not (dr.base and TV.inMembers(dr.base, me))
    b:SetShown(show)
    if not show then return end
    local on = TV.waiting(me) ~= nil
    b.on = on
    b:SetText(on and "Leave the waitlist" or "Join the waitlist")
    b:SetKind(on and "secondary" or "primary")
end

function TV.inMembers(team, key)
    for _, k in ipairs(team.members or {}) do
        if k == key then return true end
    end
    return false
end

-- Join: pick the spec I'd play (my specs, or as my sign-ups say); Leave: right away.
function TV.joinClick(btn)
    local dr = state.draft
    if not dr or not dr.id or not dr.ln then return end
    local id, ln = dr.id, dr.ln
    if btn.on then
        local ok, err = RP():LeaveWaitlist(id, ln)
        if not ok then Print(err or "Could not leave the waitlist.") end
        return
    end
    local _, cls = UnitClass("player")
    local function join(sp)
        local ok, err = RP():JoinWaitlist(id, ln, sp)
        if not ok then Print(err or "Could not join the waitlist.") end
    end
    UI():ContextMenu(btn, function(root)
        root:CreateTitle("Join as")
        for i, spec in ipairs(cls and ns.SPECS[cls] or {}) do
            root:CreateButton(TV.specIconText(cls, i, 14) .. " " .. spec.label, function() join(i) end)
        end
        local asp, ac = RP():GetMemberSpec(ns.Util.PlayerKey())
        local label = asp and ns.RaidComp:SpecLabel(ac, asp)
        if label then root:CreateButton(colorize("9e9e9e", "As my sign-ups say (" .. label .. ")"), function() join(nil) end) end
    end)
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
-- The card: the meter (a square per slot) and Needs (the open slots by spec)
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

-- Needs: the open slots by spec, in comp order ("×2" when a spec is open twice); past the width "+n more".
function TV.createNeeds(row)
    row.label = textOf(row, "GameFontNormalSmall", 10)
    row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.label:SetText("NEEDS")
    row.btns = {}
    row.more = CreateFrame("Button", nil, row)
    row.more:SetHeight(16)
    row.more.fs = textOf(row.more, "GameFontHighlightSmall", 11)
    row.more.fs:SetTextColor(0.62, 0.62, 0.62)
    row.more.fs:SetPoint("LEFT", 0, 0)
    row.more:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("Also open")
        for _, o in ipairs(self.rest or {}) do
            GameTooltip:AddLine(TV.specIconText(o.c, o.sp, 14) .. " " .. o.name .. (o.n > 1 and (" ×" .. o.n) or ""), 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    row.more:SetScript("OnLeave", hideTooltip)
end

function TV.newNeed(row)
    local b = CreateFrame("Button", nil, row)
    b:SetHeight(16)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetPoint("TOPLEFT", -3, 2)
    b.hl:SetPoint("BOTTOMRIGHT", 3, -2)
    b.hl:SetColorTexture(1, 1, 1, 0.08)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(16, 16)
    b.icon:SetPoint("LEFT", 0, 0)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.fs = textOf(b, "GameFontHighlight", 12)
    b.fs:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
    b:SetScript("OnEnter", function(self) TV.canFillTooltip(self, self.open.c, self.open.sp, "ANCHOR_BOTTOMRIGHT") end)
    b:SetScript("OnLeave", hideTooltip)
    return b
end

function TV.fillNeeds(row, open)
    local W = row:GetWidth() or TV.W
    local x = (row.label:GetStringWidth() or 40) + 10
    local shown = #open
    for i, o in ipairs(open) do
        local b = row.btns[i] or TV.newNeed(row)
        row.btns[i] = b
        b.open = o
        b.icon:SetTexture(ns.RaidComp:SpecIcon(o.c, o.sp))
        b.fs:SetText(o.name .. (o.n > 1 and grey(" ×" .. o.n) or ""))
        local w = floor(16 + 4 + (b.fs:GetStringWidth() or 60) + 0.5)
        -- (the next one must leave room for "+n more" when more follow)
        local reserve = i < #open and 64 or 0
        if i > 1 and x + w > W - reserve then
            shown = i - 1
            break
        end
        b:SetWidth(w)
        b:ClearAllPoints()
        b:SetPoint("LEFT", row, "LEFT", x, 0)
        b:Show()
        x = x + w + 12
    end
    for i = shown + 1, #row.btns do row.btns[i]:Hide() end
    local rest = {}
    for i = shown + 1, #open do rest[#rest + 1] = open[i] end
    row.more.rest = rest
    row.more:SetShown(#rest > 0)
    if #rest > 0 then
        row.more.fs:SetText(("+%d more"):format(#rest))
        row.more:SetWidth(floor((row.more.fs:GetStringWidth() or 50) + 0.5))
        row.more:ClearAllPoints()
        row.more:SetPoint("LEFT", row, "LEFT", x, 0)
    end
end

---------------------------------------------------------------------------
-- The Comp view: tabs, Start from, the columns, the bench, the steppers, the empty card
---------------------------------------------------------------------------

function TV.setTab(key)
    state.teamTab = key == "comp" and "comp" or "groups"
    if teamsView then teamsView.detail.steps:Hide() end
    PlanUI:RefreshTeams()
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
    b:SetHeight(COL_ROW_H)
    b:RegisterForClicks("LeftButtonUp")
    b.me = b:CreateTexture(nil, "BACKGROUND")
    b.me:SetAllPoints()
    b.me:SetColorTexture(1, 0.82, 0, 0.12)
    b.meBar = b:CreateTexture(nil, "BORDER")
    b.meBar:SetPoint("TOPLEFT", b, "TOPLEFT", -4, -2)
    b.meBar:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", -4, 2)
    b.meBar:SetWidth(2)
    b.meBar:SetColorTexture(1, 0.82, 0, 1)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.06)
    b.ring = b:CreateTexture(nil, "ARTWORK", nil, -2)
    b.ring:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    b.ring:SetVertexColor(1, 0.82, 0)
    b.ring:SetSize(18, 18)
    b.ring:SetPoint("CENTER", b, "LEFT", 8, 0)
    b.ringIn = b:CreateTexture(nil, "ARTWORK", nil, -1)
    b.ringIn:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    b.ringIn:SetVertexColor(PANEL_BG[1], PANEL_BG[2], PANEL_BG[3])
    b.ringIn:SetSize(16, 16)
    b.ringIn:SetPoint("CENTER", b.ring, "CENTER", 0, 0)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.fs = textOf(b, "GameFontHighlight", 12)
    b.fs:SetPoint("LEFT", b, "LEFT", 22, 0)
    b.spec = b:CreateTexture(nil, "ARTWORK")
    b.spec:SetSize(14, 14)
    b.spec:SetPoint("RIGHT", -1, 0)
    b.spec:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b:SetScript("OnEnter", TV.slotTooltip)
    b:SetScript("OnLeave", hideTooltip)
    b:SetScript("OnClick", function(self)
        if RP():CanManageTeams() and self.role then TV.openSteps(self.role, self) end
    end)
    return b
end

function TV.fillSlotRow(b, slot, organizer, mine)
    b.slot, b.role = slot, slot.role
    local m = slot.member
    local open = m == nil
    b.ring:SetShown(open)
    b.ringIn:SetShown(open)
    b.icon:ClearAllPoints()
    if open then
        b.icon:SetSize(12, 12)
        b.icon:SetPoint("CENTER", b.ring, "CENTER", 0, 0)
    else
        b.icon:SetSize(16, 16)
        b.icon:SetPoint("LEFT", b, "LEFT", 0, 0)
    end
    UI():ClassIcon(b.icon, (m and m.c) or slot.c)
    b.icon:SetAlpha(open and 0.35 or 1)
    b.fs:SetText(open and colorize("ffd100", slot.name) or colored(m.key, m.c))
    local icon = ns.RaidComp:SpecIcon(slot.c, slot.sp)
    b.spec:SetShown(icon ~= nil)
    if icon then b.spec:SetTexture(icon) end
    b.spec:SetAlpha(open and 0.35 or 1)
    b.me:SetShown(mine == true)
    b.meBar:SetShown(mine == true)
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
        GameTooltip:AddLine("Click to change this column's slots.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

-- A chip under the comp's columns (chip.kind: "unassigned", "waitlist" or "beyond" the comp): class circle, name,
-- spec icon (the Sign-ups' boxes look).
function TV.newBenchChip(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(CHIP_H)
    b:RegisterForClicks("LeftButtonUp")
    panel(b, CARD_BG, { 0.34, 0.34, 0.38, 0.6 })
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.06)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(16, 16)
    b.icon:SetPoint("LEFT", 3, 0)
    b.fs = textOf(b, "GameFontHighlight", 12)
    b.fs:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
    b.spec = b:CreateTexture(nil, "ARTWORK")
    b.spec:SetSize(14, 14)
    b.spec:SetPoint("RIGHT", -5, 0)
    b.spec:SetTexCoord(0.08, 0.92, 0.08, 0.92)
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
            GameTooltip:AddLine(kind == "unassigned" and "Click to put them in a group or change the spec."
                or kind == "waitlist" and "Click to move them in line, onto the roster or off the waitlist."
                or "Click to add a slot or change the spec.", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", hideTooltip)
    b:SetScript("OnClick", function(self) TV.benchMenu(self) end)
    return b
end

-- A chip under the columns clicked (organizers): unassigned, a group to put them in; beyond the comp, a slot for
-- their spec; both, the spec they play in this lineup. A waitlisted player: TV.waitMenu.
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
    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints()
    p.bg:SetColorTexture(0.06, 0.06, 0.07, 1)
    UI():AddEdges(p, "BORDER")
    UI():SetEdgeColor(p, 0.45, 0.45, 0.5, 1)
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
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", -10, -2)
    p:Show()
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
    local v = d.views
    local function tab(label, key)
        local b = UI():CreateUnderlineTab(v, label, function() TV.setTab(key) end, "small")
        b.key = key
        return b
    end
    d.tabGroups = tab("Groups", "groups")
    d.tabGroups:SetPoint("BOTTOMLEFT", -4, 0)
    tipButton(d.tabGroups, "Groups", "Raids that invite this team start from these groups.")
    d.tabComp = tab("Comp", "comp")
    d.tabComp:SetPoint("LEFT", d.tabGroups, "RIGHT", 4, 0)
    tipButton(d.tabComp, "Target comp", "The specs this team should bring. Its open slots show on the team card and "
        .. "in the Sign-ups of raids that invite the team.")
    d.tabLine = v:CreateTexture(nil, "BORDER")
    d.tabLine:SetPoint("BOTTOMLEFT", 0, 0)
    d.tabLine:SetPoint("BOTTOMRIGHT", 0, 0)
    d.tabLine:SetHeight(1)
    d.tabLine:SetColorTexture(1, 1, 1, 0.1)

    d.startBtn = UI():CreateSleekMenuButton(d.tool, "Start from", 104, function(root) TV.startMenu(root) end)
    d.startBtn:SetPoint("TOPLEFT", d.tool, "TOPLEFT", 0, 0)
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
    d.cols = {}
    for i, role in ipairs(ns.RaidComp.COLUMNS) do
        local col = CreateFrame("Frame", nil, cc)
        panel(col)
        col.roleKey = role
        col.role = col:CreateTexture(nil, "ARTWORK")
        UI():SetRoleIcon(col.role, TV.ROLE_ICON[role])
        col.role:SetSize(16, 16)
        col.role:SetPoint("TOPLEFT", 9, -6)
        col.title = textOf(col, "GameFontNormal", 12)
        col.title:SetPoint("LEFT", col.role, "RIGHT", 6, 0)
        col.title:SetText(TV.ROLE_LABEL[role])
        col.add = UI():CreateSleekButton(col, "", 18, 18, function(self) TV.openSteps(role, self) end)
        col.add:SetPoint("TOPRIGHT", col, "TOPRIGHT", -8, -5)
        TV.glyph(col.add, true)
        tipButton(col.add, TV.ROLE_LABEL[role], "How many of each spec the comp wants.")
        col.count = textOf(col, "GameFontHighlight", 12)
        col.count:SetJustifyH("RIGHT")
        col.rule = col:CreateTexture(nil, "BORDER")
        col.rule:SetColorTexture(1, 1, 1, 0.07)
        col.rule:SetHeight(1)
        col.rule:SetPoint("TOPLEFT", 8, -COL_HEAD_H)
        col.rule:SetPoint("TOPRIGHT", -8, -COL_HEAD_H)
        col.none = textOf(col, "GameFontDisableSmall", 10)
        col.none:SetPoint("TOPLEFT", 10, -COL_HEAD_H - 8)
        col.none:SetText("No slots")
        col.rows = {}
        d.cols[i] = col
    end
    -- under the columns: who fills no slot, benched (in no group) and beyond the comp (in a group, no slot)
    local function chipPanel(label, tip)
        local p = CreateFrame("Frame", nil, cc)
        panel(p)
        p.title = label
        p.label = CreateFrame("Button", nil, p)
        p.label:SetHeight(CHIP_H)
        p.label:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -8)
        p.label.fs = textOf(p.label, "GameFontHighlight", 12)
        p.label.fs:SetPoint("LEFT", 0, 0)
        p.label:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(label)
            GameTooltip:AddLine(tip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        p.label:SetScript("OnLeave", hideTooltip)
        p.chips = {}
        p:Hide()
        return p
    end
    d.unassigned = chipPanel("Unassigned", "On the roster, in none of this lineup's groups: they don't count for the "
        .. "comp. Put them in a group (Groups tab) to fill a slot.")
    d.waiting = chipPanel("Waitlist", "Not on the roster: players waiting for a spot in this lineup, first in line "
        .. "first. They don't count for the comp until they are taken onto the roster and into a group.")
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

-- The columns (a slot per row, in comp order) and the bench under them.
function TV.fillCompView(m, organizer)
    local d = teamsView.detail
    local dr = state.draft
    local cc = d.compContent
    local W = TV.W
    local colW = floor((W - 3 * GAP) / 4)
    local full = ns.RaidComp:CompSize(dr.cp) >= dr.sz
    local depth = 0
    for i, col in ipairs(d.cols) do
        local role = col.roleKey
        local slots = m.columns[role] or {}
        col:ClearAllPoints()
        col:SetPoint("TOPLEFT", cc, "TOPLEFT", (i - 1) * (colW + GAP), 0)
        col:SetWidth(i == #d.cols and (W - 3 * (colW + GAP)) or colW)
        local filled = 0
        for j, slot in ipairs(slots) do
            local r = col.rows[j] or TV.newSlotRow(col)
            col.rows[j] = r
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", col, "TOPLEFT", 9, -COL_HEAD_H - 4 - (j - 1) * COL_ROW_H)
            r:SetPoint("TOPRIGHT", col, "TOPRIGHT", -9, -COL_HEAD_H - 4 - (j - 1) * COL_ROW_H)
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
        col.count:ClearAllPoints()
        if col.add:IsShown() then col.count:SetPoint("RIGHT", col.add, "LEFT", -8, 0)
        else col.count:SetPoint("RIGHT", col, "TOPRIGHT", -10, -14) end
        if #slots == 0 then
            col.count:SetText("")
        elseif filled == #slots then
            col.count:SetText(colorize("8fe39d", filled .. "/" .. #slots))
        else
            col.count:SetText(filled .. colorize("9e9e9e", "/" .. #slots))
        end
        depth = max(depth, #slots)
    end
    local colH = COL_HEAD_H + 4 + max(1, depth) * COL_ROW_H + 8
    for _, col in ipairs(d.cols) do col:SetHeight(colH) end
    -- under the columns, who no slot takes, as chips with their spec: benched, then beyond the comp
    local y = colH
    local panels = { { d.unassigned, m.unassigned or {}, "unassigned" }, { d.waiting, TV.waitMembers(), "waitlist" },
                     { d.bench, m.bench or {}, "beyond" } }
    -- (both panels' chips start at the same x, past the longer label)
    local labelW = 0
    for _, e in ipairs(panels) do
        local p, list = e[1], e[2]
        p.label.fs:SetText(p.title .. colorize("9e9e9e", " (" .. #list .. ")"))
        p.label:SetWidth(floor((p.label.fs:GetStringWidth() or 60) + 0.5))
        if #list > 0 then labelW = max(labelW, p.label:GetWidth()) end
    end
    for _, e in ipairs(panels) do
        local p, list = e[1], e[2]
        p:SetShown(#list > 0)
        if #list > 0 then
            y = y + GAP + TV.fillChipPanel(p, list, e[3], y + GAP, 12 + labelW + 14)
        end
    end
    cc:SetWidth(W)
    cc:SetHeight(y)
end

-- One panel of chips under the columns (kind: unassigned, waitlist or beyond the comp) at y, its chips from x0;
-- returns its height.
function TV.fillChipPanel(p, list, kind, y, x0)
    local W = TV.W
    local cx, cy = x0, -8
    for j, mem in ipairs(list) do
        local chip = p.chips[j] or TV.newBenchChip(p)
        p.chips[j] = chip
        chip.member, chip.kind = mem, kind
        UI():ClassIcon(chip.icon, mem.c)
        chip.fs:SetText((kind == "waitlist" and colorize("9e9e9e", mem.n .. ". ") or "") .. colored(mem.key, mem.c))
        local icon = ns.RaidComp:SpecIcon(mem.c, mem.sp)
        chip.spec:SetShown(icon ~= nil)
        if icon then chip.spec:SetTexture(icon) end
        local w = floor(3 + 16 + 6 + (chip.fs:GetStringWidth() or 60) + (icon and (8 + 14 + 5) or 9) + 0.5)
        chip:SetWidth(w)
        if cx + w > W - 12 and cx > x0 then cx, cy = x0, cy - (CHIP_H + CHIP_GAP) end
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", p, "TOPLEFT", cx, cy)
        chip:Show()
        cx = cx + w + CHIP_GAP
    end
    for j = #list + 1, #p.chips do p.chips[j]:Hide() end
    local h = -cy + CHIP_H + 8
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", teamsView.detail.compContent, "TOPLEFT", 0, -y)
    p:SetSize(W, h)
    return h
end

-- The Comp tab below the tabs: the row on top (organizers: Start from, the strip, Undo / Save; members: the
-- strip), then the columns and the bench, or (no comp yet, organizers) the empty card. Returns nothing.
function TV.layoutComp(y, organizer, dr, m)
    local t, d = teamsView, teamsView.detail
    local dirty = organizer and TV.dirty()
    local toolShown = organizer and (m ~= nil or dirty)
    d.tool:SetShown(toolShown)
    t.picker.frame:Hide()
    d.autoBtn:Hide()
    d.startBtn:SetShown(organizer and m ~= nil)
    d.compBar:SetShown(not organizer and m ~= nil)
    d.compStrip:SetShown(m ~= nil)
    if toolShown then
        d.tool:ClearAllPoints()
        d.tool:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, -y)
        y = y + TV.TOOL_H + GAP
    end
    if m then
        local room
        d.compStrip:ClearAllPoints()
        if organizer then
            d.compStrip:SetPoint("LEFT", d.startBtn, "RIGHT", 12, 0)
            local right = 0
            if d.saveBtn:IsShown() then
                right = d.saveBtn:GetWidth() + 4 + d.revertBtn:GetWidth() + 12 + (d.status:GetStringWidth() or 110) + 16
            end
            room = TV.W - d.startBtn:GetWidth() - 12 - right
        else
            d.compBar:ClearAllPoints()
            d.compBar:SetPoint("TOPLEFT", d, "TOPLEFT", PAD, -y)
            d.compStrip:SetPoint("LEFT", d.compBar, "LEFT", 2, 0)
            y = y + TV.BAR_H + 6
            room = TV.W - 4
        end
        local states = TV.states or {}
        local size = 20
        while size > 14 and #states * (size + 2) > room do size = size - 2 end
        for i, b in ipairs(d.compStrip.icons) do
            local e = states[i]
            b:SetSize(size, size)
            if e and i * (size + 2) <= room + 2 then ns.RaidGroupsUI:SetBuffIcon(b, e) else b:Hide() end
        end
    end
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
-- New / Edit raid window
---------------------------------------------------------------------------

-- The date picker's limits: today (or the edited raid's own day, if earlier) .. EDITOR_DAYS ahead.
local function pickerMin()
    local lo = editor and editor.minT or Now()
    local d = date("*t", math.min(lo, Now()))
    return d.year, d.month, d.day
end

local function pickerMax()
    local d = date("*t", Now() + EDITOR_DAYS * DAY)
    return d.year, d.month, d.day
end

-- A dot on days that already have a raid planned: "20:00 Karazhan" lines.
local function pickerMark(y, m, d)
    local from = time({ year = y, month = m, day = d, hour = 0, min = 0, sec = 0 })
    local to = time({ year = y, month = m, day = d + 1, hour = 0, min = 0, sec = 0 }) - 1
    local lines = {}
    for _, v in ipairs(RP():GetRaids(from, to)) do
        if not v.cancelled then lines[#lines + 1] = fmtTime(v.t) .. "  " .. raidTitle(v) end
    end
    return #lines > 0 and tconcat(lines, "\n") or nil
end

local function hourOptions()
    local out = {}
    for h = 0, 23 do out[#out + 1] = { value = h, text = ("%02d"):format(h) } end
    return out
end

local function minuteOptions()
    local out = {}
    for _, m in ipairs({ 0, 15, 30, 45 }) do out[#out + 1] = { value = m, text = (":%02d"):format(m) } end
    return out
end

local function instanceOptions()
    local out = {}
    for _, inst in ipairs(RP():GetInstances()) do out[#out + 1] = { value = inst.key, text = inst.name } end
    return out
end

-- Server time of the editor's day + hour + minute (local wall clock).
local function editorTime()
    local f = editor.f
    return time({ year = f.y, month = f.m, day = f.d, hour = f.hour, min = f.min, sec = 0 })
end

-- A team's lineups of the editor's raid size: { lineup, ... } (a GetTeam table's).
function TV.sizeLineups(t)
    local out = {}
    for _, l in ipairs(t.lineups) do
        if l.size == editor.f.sz then out[#out + 1] = l end
    end
    return out
end

-- The players a team invites to the editor's raid through lineup l (in its groups); the whole roster without a
-- lineup of the raid's size, or when it has nobody in its groups yet (RaidPlan:GetRaidTeamPlayers). Returns the keys
-- and whether they are the roster.
function TV.editorPlayers(t, l)
    local out = {}
    if l then
        local n = ns.RaidComp:GroupCount(editor.f.sz)
        for _, key in ipairs(t.members) do
            local g = l.groups[key]
            if type(g) == "number" and g >= 1 and g <= n then out[#out + 1] = key end
        end
    end
    if #out == 0 then return t.members, true end
    return out, false
end

-- A Teams entry: "Main · Kara A (10)" (a lineup's players), "Main · roster (32)" (no lineup of the raid's size), or
-- "Main (24)" for a team whose one lineup it is.
function TV.editorEntry(t, l)
    local players, roster = TV.editorPlayers(t, l)
    local what = (roster and "roster") or ((#t.lineups > 1) and RP():LineupName(t, l)) or nil
    return ("%s%s (%d)"):format(t.name, what and (" · " .. what) or "", #players)
end

-- The lineup a picked team gives the raid: the one chosen (f.tl), else its first of the raid's size.
function TV.pickedLineup(t)
    local list = TV.sizeLineups(t)
    for _, l in ipairs(list) do
        if l.id == editor.f.tl[t.id] then return l, #list end
    end
    return list[1], #list
end

local function teamSummary()
    local n = 0
    local names = {}
    for _, t in ipairs(RP():GetTeams()) do
        if editor.f.tm[t.id] then
            n = n + 1
            local l, count = TV.pickedLineup(t)
            names[#names + 1] = t.name .. ((l and count > 1) and (" · " .. RP():LineupName(t, l)) or "")
        end
    end
    if n == 0 then return "Everyone (no team)" end
    return tconcat(names, ", ")
end

-- The guild members to invite on top of the teams (the players a picked team invites are in already).
local function inviteItems()
    local g = ns.Guild
    local inTeam = {}
    for _, t in ipairs(RP():GetTeams()) do
        if editor.f.tm[t.id] then
            for _, key in ipairs(TV.editorPlayers(t, TV.pickedLineup(t))) do inTeam[key] = t.name end
        end
    end
    local out, seen = {}, {}
    for _, key in ipairs(g and g.GetMembers and g:GetMembers() or {}) do
        seen[key] = true
        out[#out + 1] = { key = key, text = shortName(key), classFile = g:GetClass(key), note = g:GetRankName(key),
                          dim = not g:IsOnline(key), fixed = inTeam[key] }
    end
    for key in pairs(editor.f.inv) do
        if not seen[key] then out[#out + 1] = { key = key, text = shortName(key), note = "not in the guild", dim = true } end
    end
    tsort(out, function(a, b) return a.text:lower() < b.text:lower() end)
    return out
end

local function inviteList()
    local list = {}
    for key in pairs(editor.f.inv) do list[#list + 1] = key end
    tsort(list)
    return list
end

local function refreshInvites()
    local list = inviteList()
    tsort(list, nameLess)
    local names = {}
    for i, key in ipairs(list) do names[i] = shortName(key) end
    editor.invInfo:SetText(#list == 0 and "Nobody outside the teams is invited."
        or (#list .. " invited: " .. tconcat(names, ", ")))
end

local function editorFields()
    local f = editor.f
    local tm, tl = {}, {}
    for _, t in ipairs(RP():GetTeams()) do
        if f.tm[t.id] then
            tm[#tm + 1] = t.id
            -- (a team with more than one lineup of the raid's size names the one it gives)
            local l, count = TV.pickedLineup(t)
            if l and count > 1 then tl[t.id] = l.id end
        end
    end
    return {
        i = f.i, sz = f.sz, t = editorTime(), tm = tm, tl = tl, lk = f.lk and true or false, inv = inviteList(),
        pv = (f.lk and f.pv) and true or false,
        ml = f.low and 0 or MAX_LEVEL,
        ti = ns.Util.Trim(editor.titleBox:GetText() or "") ~= "" and editor.titleBox:GetText() or false,
        no = ns.Util.Trim(editor.noteBox:GetText() or "") ~= "" and editor.noteBox:GetText() or false,
    }
end

-- An edit sends only what changed: an override of one weekly raid that repeated every field would pin them, and
-- later "every week" edits would no longer reach it.
local function changedFields(fields, v)
    local out = {}
    for _, f in ipairs({ "i", "sz", "t" }) do
        if fields[f] ~= v[f] then out[f] = fields[f] end
    end
    for _, f in ipairs({ "ti", "no" }) do
        if (fields[f] or nil) ~= v[f] then out[f] = fields[f] end
    end
    local a, b = tconcat(fields.tm, ","), tconcat(v.tm or {}, ",")
    local sa, sb = {}, {}
    for _, id in ipairs(fields.tm) do sa[#sa + 1] = id end
    for _, id in ipairs(v.tm or {}) do sb[#sb + 1] = id end
    tsort(sa)
    tsort(sb)
    if a ~= b and tconcat(sa, ",") ~= tconcat(sb, ",") then out.tm = fields.tm end
    local function choice(tl)
        local list = {}
        for id, ln in pairs(tl or {}) do list[#list + 1] = id .. "=" .. ln end
        tsort(list)
        return tconcat(list, ",")
    end
    if choice(fields.tl) ~= choice(v.tl) then out.tl = fields.tl end
    if fields.lk ~= (v.lk and true or false) then out.lk = fields.lk end
    if fields.pv ~= (v.pv and true or false) then out.pv = fields.pv end
    if fields.ml ~= (v.ml or 0) then out.ml = fields.ml end
    local was = {}
    for _, key in ipairs(v.inv or {}) do was[#was + 1] = key end
    tsort(was)
    if tconcat(fields.inv, ",") ~= tconcat(was, ",") then out.inv = fields.inv end
    return out
end

local function editorSave(scope)
    local fields = editorFields()
    local ok, res
    if fields.lk and #fields.tm == 0 and #fields.inv == 0 then
        editor.err:SetText("A locked raid needs a team or invited players.")
        return false
    end
    if editor.occ then
        local v = RP():GetRaid(editor.occ)
        if not v then
            editor.err:SetText("This raid no longer exists.")
            return false
        end
        fields = changedFields(fields, v)
        if not next(fields) then
            editor:Hide()
            return true
        end
        ok, res = RP():EditRaid(editor.occ, fields, scope)
    else
        fields.weekly = editor.weeklyCB:GetChecked() and true or false
        if not fields.ti then fields.ti = nil end
        if not fields.no then fields.no = nil end
        ok, res = RP():CreateRaid(fields)
    end
    if not ok then
        editor.err:SetText(res or "Could not save the raid.")
        return false
    end
    editor:Hide()
    if not editor.occ and res then PlanUI:SelectRaid(res) end
    return true
end

local function row(parent, label, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", 12, y)
    fs:SetText(label)
    return fs
end

local function createEditor()
    local w = UI():CreateWindow("DisasterZoneRaidEditor", "New raid", 400, 452)
    editor = w
    local c = w.content
    w.f = { tm = {}, tl = {}, inv = {} }

    row(c, "Raid", -14)
    w.instDD = UI():CreateDropdown(c, 190, instanceOptions, function() return w.f.i end, function(v)
        w.f.i = v
        local inst = RP():GetInstance(v)
        if inst then w.f.sz = inst.size end
        if w.sizeDD.Refresh then w.sizeDD:Refresh() end
    end)
    w.instDD:SetPoint("TOPLEFT", 80, -8)
    w.sizeDD = UI():CreateDropdown(c, 80, function()
        return { { value = 10, text = "10-man" }, { value = 25, text = "25-man" } }
    end, function() return w.f.sz end, function(v) w.f.sz = v end)
    w.sizeDD:SetPoint("LEFT", w.instDD, "RIGHT", 8, 0)

    row(c, "Title", -46)
    w.titleBox = UI():CreateSleekEditBox(c)
    w.titleBox:SetSize(200, 20)
    w.titleBox:SetAutoFocus(false)
    w.titleBox:SetMaxLetters(32)
    w.titleBox:SetPoint("TOPLEFT", 86, -42)
    local hint = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", w.titleBox, "RIGHT", 8, 0)
    hint:SetText("optional")

    row(c, "Day", -78)
    w.datePicker = UI():CreateDatePicker(c, {
        get = function() return w.f.y, w.f.m, w.f.d end,
        set = function(y, m, d) w.f.y, w.f.m, w.f.d = y, m, d end,
        minDate = pickerMin,
        maxDate = pickerMax,
        mark = pickerMark,
        width = 230,
    })
    w.datePicker:SetPoint("TOPLEFT", 84, -72)
    row(c, "Time", -110)
    w.hourDD = UI():CreateDropdown(c, 70, hourOptions, function() return w.f.hour end, function(v) w.f.hour = v end)
    w.hourDD:SetPoint("TOPLEFT", 80, -104)
    w.minDD = UI():CreateDropdown(c, 70, minuteOptions, function() return w.f.min end, function(v) w.f.min = v end)
    w.minDD:SetPoint("LEFT", w.hourDD, "RIGHT", 4, 0)
    local tz = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    tz:SetPoint("LEFT", w.minDD, "RIGHT", 8, 0)
    tz:SetText("your clock")

    -- (a team with several lineups of the raid's size: one entry per lineup, "Main · Kara A (10)"; picking one picks
    -- the team with that lineup: its groups and comp are the raid's)
    row(c, "Teams", -142)
    w.teamDD = UI():CreateMultiDropdown(c, 270, function()
        local out = {}
        for _, t in ipairs(RP():GetTeams()) do
            local list = TV.sizeLineups(t)
            if #list > 1 then
                for _, l in ipairs(list) do
                    out[#out + 1] = { value = t.id .. ":" .. l.id, text = TV.editorEntry(t, l) }
                end
            else
                out[#out + 1] = { value = t.id, text = TV.editorEntry(t, list[1]) }
            end
        end
        if #out == 0 then out[1] = { value = "", text = "No teams yet (Teams view)", disabled = true } end
        return out
    end, function(value)
        local id, ln = tostring(value):match("^([^:]+):?(.*)$")
        if not w.f.tm[id] then return false end
        if ln == "" then return true end
        local t = RP():GetTeam(id)
        local l = t and TV.pickedLineup(t)
        return l ~= nil and l.id == ln
    end, function(value, on)
        local id, ln = tostring(value):match("^([^:]+):?(.*)$")
        if id and id ~= "" then
            w.f.tm[id] = on or nil
            w.f.tl[id] = (on and ln ~= "") and ln or nil
        end
        if w.teamDD.Refresh then w.teamDD:Refresh() end
    end, teamSummary)
    w.teamDD:SetPoint("TOPLEFT", 80, -136)

    -- players outside the teams who are invited too
    row(c, "Invite", -174)
    w.invPicker = UI():CreateSearchDropdown(c, 270, {
        placeholder = "Players outside the teams...",
        emptyText = "No matching guild members.",
        getItems = inviteItems,
        isChecked = function(key) return w.f.inv[key] and true or false end,
        onToggle = function(key)
            w.f.inv[key] = not w.f.inv[key] or nil
            refreshInvites()
        end,
    })
    w.invPicker.frame:SetPoint("TOPLEFT", 80, -168)
    w.invInfo = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    w.invInfo:SetPoint("TOPLEFT", 86, -194)
    w.invInfo:SetPoint("RIGHT", -12, 0)
    w.invInfo:SetJustifyH("LEFT")
    w.invInfo:SetWordWrap(false)
    w.lockCB = UI():CreateCheckbox(c, "Locked: only the teams and the invited players sign up",
        function() return w.f.lk end, function(on) w.f.lk = on end)
    w.lockCB:SetPoint("TOPLEFT", 80, -208)
    w.lockCB.tooltipText = "Left open, every guild member can sign up and the teams only say who is expected. "
        .. "Locked, the sign-up buttons work only for the members of the picked teams and the players invited here; "
        .. "an answer from anyone else is a request to join, for whoever runs the raid to approve or deny."
    w.privCB = UI():CreateCheckbox(c, "Private: hidden from the rest, no requests",
        function() return w.f.lk and w.f.pv end, function(on) w.f.pv = on end)
    w.privCB:SetPoint("TOPLEFT", 80, -230)
    w.privCB.tooltipText = "A locked raid is still listed for the whole guild, who can ask to join it. Private, "
        .. "only its teams, the invited players and who runs raids see it."
    w.lowCB = UI():CreateCheckbox(c, ("Allow characters below level %d"):format(MAX_LEVEL),
        function() return w.f.low end, function(on) w.f.low = on end)
    w.lowCB:SetPoint("TOPLEFT", 80, -252)
    w.lowCB.tooltipText = ("Unticked, only level %d characters can sign up; the answer of a lower character is not "
        .. "counted. Tick it for a raid that lower characters may join too."):format(MAX_LEVEL)

    row(c, "Note", -290)
    w.noteBox = UI():CreateSleekEditBox(c)
    w.noteBox:SetSize(270, 20)
    w.noteBox:SetAutoFocus(false)
    w.noteBox:SetMaxLetters(120)
    w.noteBox:SetPoint("TOPLEFT", 86, -286)

    w.weeklyCB = UI():CreateCheckbox(c, "Repeat weekly (the next two weeks are always planned)", nil, nil)
    w.weeklyCB:SetPoint("TOPLEFT", 80, -314)
    w.weeklyInfo = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    w.weeklyInfo:SetPoint("TOPLEFT", 84, -320)
    w.weeklyInfo:SetPoint("RIGHT", -12, 0)
    w.weeklyInfo:SetJustifyH("LEFT")
    w.weeklyInfo:SetText("A weekly raid: save the change for this week only, or for every week.")

    w.err = c:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    w.err:SetPoint("BOTTOMLEFT", 12, 40)
    w.err:SetPoint("RIGHT", -12, 0)
    w.err:SetJustifyH("LEFT")

    w.saveBtn = UI():CreateButton(c, "Create raid", 110, 22, function() editorSave("one") end)
    w.saveBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    w.saveAllBtn = UI():CreateButton(c, "Save every week", 120, 22, function() editorSave("series") end)
    w.saveAllBtn:SetPoint("RIGHT", w.saveBtn, "LEFT", -6, 0)
    w.cancelBtn = UI():CreateButton(c, "Close", 70, 22, function() w:Hide() end)
    w.cancelBtn:SetPoint("BOTTOMLEFT", 10, 10)
    w:Hide()
    return w
end

-- occId = nil: a new raid.
function PlanUI:OpenEditor(occId)
    if occId and RP():GetRaid(occId) and not RP():CanManageRaid(occId) then
        Print("Only this raid's leader, the Guild Master and the raid leaders can change it.")
        return
    elseif not occId and not RP():CanOrganize() then
        Print("Only the Guild Master and the raid leaders can plan raids.")
        return
    end
    if not editor then createEditor() end
    local v = occId and RP():GetRaid(occId)
    editor.occ = v and v.id or nil
    editor.err:SetText("")
    local f = { tm = {}, tl = {}, inv = {}, lk = false, low = false }   -- (a new raid is for level 70 characters)
    if v then
        f.low = v.ml == nil
        local d = date("*t", v.t)
        f.i, f.sz, f.hour, f.min = v.i, v.sz, d.hour, d.min - d.min % 15
        f.y, f.m, f.d = d.year, d.month, d.day
        for _, id in ipairs(v.tm or {}) do f.tm[id] = true end
        for id, ln in pairs(v.tl or {}) do f.tl[id] = ln end
        for _, key in ipairs(v.inv or {}) do f.inv[key] = true end
        f.lk = v.lk and true or false
        f.pv = v.pv and true or false
        editor.titleBox:SetText(v.ti or "")
        editor.noteBox:SetText(v.no or "")
    else
        local d = date("*t", Now() + DAY)
        f.i, f.sz, f.hour, f.min = "kara", 10, 20, 0
        f.y, f.m, f.d = d.year, d.month, d.day
        editor.titleBox:SetText("")
        editor.noteBox:SetText("")
    end
    editor.minT = v and v.t or nil
    editor.f = f
    editor:SetWindowTitle(v and ("Edit raid: " .. raidTitle(v)) or "New raid")
    editor.weeklyCB:SetShown(v == nil)
    editor.weeklyCB:SetChecked(false)
    -- every week: who may change the whole weekly raid (not a leader of this week only)
    local series = (v and v.weekly and RP():CanManageSeries(v)) and true or false
    editor.weeklyInfo:SetShown(series)
    editor.saveBtn:SetText(v and (v.weekly and "This week only" or "Save") or "Create raid")
    editor.saveAllBtn:SetShown(series)
    for _, dd in ipairs({ editor.instDD, editor.sizeDD, editor.datePicker, editor.hourDD, editor.minDD, editor.teamDD,
                          editor.lockCB, editor.lowCB }) do
        if dd.Refresh then dd:Refresh() end
    end
    if editor.invPicker.Close then editor.invPicker:Close() end
    refreshInvites()
    editor:Show()
    editor:Raise()
end

function PlanUI:GetEditor() return editor end

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
    if StaticPopupDialogs then
        StaticPopupDialogs["DISASTERZONE_PLAN_DELETE"] = {
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
        StaticPopupDialogs["DISASTERZONE_PLAN_CONFIRM"] = {
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
        StaticPopupDialogs["DISASTERZONE_TEAM_UNSAVED"] = {
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
        StaticPopupDialogs["DISASTERZONE_TEAM_COMP_SIZE"] = {
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
        StaticPopupDialogs["DISASTERZONE_LINEUP_NAME"] = {
            text = "Lineup name (empty: its size, e.g. \"25-man\"):",
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
        StaticPopupDialogs["DISASTERZONE_TEAM_DELETE"] = {
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

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
local LIST_W = 290                  -- the Teams view's team list
local RAID_ROW_H = 36
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
        if t then names[#names + 1] = t.name end
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
    -- (a request opens with either button; the rest of the roster with the right one)
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
        col.role:SetTexCoord(UI():RoleCoords(m.role))
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
-- Teams view (§58-§59): the team list, and for the selected team a draft (name, members, size, each member's spec,
-- group layout) shown in the group grid. Organizers edit the draft and Save; everyone else sees it read-only.
---------------------------------------------------------------------------

local function initTeamRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.5)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, 0.82, 0, 0.12)
        -- two lines, like the raid list: the name, then size and members
        row.l1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.l1:SetPoint("TOPLEFT", 8, -4)
        row.l1:SetPoint("RIGHT", -6, 0)
        row.l1:SetJustifyH("LEFT")
        row.l1:SetWordWrap(false)
        row.l2 = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.l2:SetPoint("TOPLEFT", 8, -20)
        row.l2:SetPoint("RIGHT", -6, 0)
        row.l2:SetJustifyH("LEFT")
        row.l2:SetWordWrap(false)
        row:SetScript("OnClick", function(self)
            local data = self.__cdlData
            if data then PlanUI:SelectTeam(data.id) end
        end)
    end
    row.sel:SetShown(d.id == state.team)
    row.l1:SetText(d.name)
    row.l2:SetText(("%d-man · %d members"):format(d.size or 25, #d.members))
end

local function pickerItems()
    local G = ns.Guild
    local out = {}
    for _, key in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        out[#out + 1] = {
            key = key, text = shortName(key), classFile = G:GetClass(key), note = G:GetRankName(key),
            dim = not G:IsOnline(key),
        }
    end
    tsort(out, function(a, b) return nameLess(a.key, b.key) end)
    return out
end

local function sameMap(a, b)
    a, b = a or {}, b or {}
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

local function draftDirty()
    local dr = state.draft
    if not dr then return false end
    if not dr.id then return true end
    local t = RP():GetTeam(dr.id)
    if not t then return true end
    if t.name ~= ns.Util.Trim(teamsView.nameBox:GetText() or "") then return true end
    local set = {}
    for _, key in ipairs(t.members) do set[key] = true end
    return not (sameMap(dr.members, set) and dr.sz == t.size and sameMap(dr.s, t.specs) and sameMap(dr.grp, t.groups)
        and sameMap(dr.gs, t.seats))
end

local function loadDraft(id)
    local t = id and RP():GetTeam(id)
    local members = {}
    if t then for _, key in ipairs(t.members) do members[key] = true end end
    state.draft = {
        id = t and t.id or nil, name = t and t.name or "New team", members = members, sz = t and t.size or 25,
        s = t and t.specs or {}, grp = t and t.groups or {}, gs = t and t.seats or {},
    }
    if teamsView then teamsView.nameBox:SetText(state.draft.name) end
end

-- The draft's members for the grid: { key, c, sp, auto, source }.
local function draftMembers()
    local dr = state.draft
    local out = {}
    if not dr then return out end
    for key in pairs(dr.members) do
        local sp, c, source = RP():GetMemberSpec(key, { specs = dr.s })
        out[#out + 1] = { key = key, c = c, sp = sp, auto = source ~= "team", source = source }
    end
    return out
end

function PlanUI:ToggleDraftMember(key)
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return end
    if dr.members[key] then
        dr.members[key], dr.s[key], dr.grp[key], dr.gs[key] = nil, nil, nil, nil
    else
        dr.members[key] = true
    end
    self:RefreshTeams()
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
    dr.sz = size == 10 and 10 or 25
    local n = ns.RaidComp:GroupCount(dr.sz)
    for key, g in pairs(dr.grp) do
        if g > n then dr.grp[key], dr.gs[key] = nil, nil end
    end
    self:RefreshTeams()
end

-- The grid's drop: move `key` to group g (nil = out of the groups); dropped onto `target` in a group = swap, onto
-- an empty `seat` = that seat.
function PlanUI:MoveDraftMember(key, g, target, seat, shown)
    local dr = state.draft
    if not dr or not dr.members[key] or not RP():CanManageTeams() then return false end
    return moveInLayout(dr.grp, dr.gs, function(k) return dr.members[k] end, key, g, target, seat, shown)
end

function PlanUI:SwapDraftGroups(a, b)
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return end
    swapGroups(dr.grp, a, b)
    self:RequestRefresh()
end

function PlanUI:AutoFillDraft()
    local dr = state.draft
    if not dr or not RP():CanManageTeams() then return end
    dr.grp, dr.gs = ns.RaidComp:AutoFill(draftMembers(), dr.sz), {}
    self:RefreshTeams()
end

local function memberMenu(root, key)
    local dr = state.draft
    if not dr then return end
    local sp, c = RP():GetMemberSpec(key, { specs = dr.s })
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
    root:CreateButton("Take out of the groups", function()
        PlanUI:MoveDraftMember(key, nil)
        PlanUI:RefreshTeams()
    end)
    if root.CreateDivider then root:CreateDivider() end
    root:CreateButton("Remove from the team", function() PlanUI:ToggleDraftMember(key) end)
end

function PlanUI:NewTeam()
    state.team, state.newTeam = nil, true
    loadDraft(nil)
    self:RefreshTeams()
    if teamsView and teamsView.nameBox:IsVisible() then
        teamsView.nameBox:SetFocus()
        teamsView.nameBox:HighlightText()
    end
end

function PlanUI:SaveTeam()
    local dr = state.draft
    if not dr then return false end
    local ok, res = RP():SaveTeam(dr.id, teamsView.nameBox:GetText(), dr.members,
        { size = dr.sz, specs = dr.s, groups = dr.grp, seats = dr.gs })
    if not ok then
        Print(res or "Could not save the team.")
        return false
    end
    state.team, state.newTeam = res, nil
    loadDraft(res)
    self:RefreshTeams()
    return true
end

function PlanUI:SelectTeam(id)
    state.team, state.newTeam = id, nil
    loadDraft(id)
    self:RefreshTeams()
end

function PlanUI:GetSelectedTeam() return state.team end

function PlanUI:GetTeamGrid() return teamsView and teamsView.grid end

function PlanUI:GetDraft() return state.draft end

-- Upcoming raids that invite a team, soonest first.
local function teamRaids(id)
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

-- The team header's raid line: every upcoming raid that invites the team, one per tooltip line.
local function teamRaidsTooltip(self)
    local raids = self.raids
    if not raids or #raids == 0 then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Invited to")
    for _, v in ipairs(raids) do
        GameTooltip:AddDoubleLine(RP():GetRaidName(v), shortDay(v.t) .. "  " .. fmtTime(v.t), 1, 1, 1, 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

function PlanUI:CreateTeams(parent)
    local t = CreateFrame("Frame", nil, parent)
    teamsView = t

    t.list = UI():CreateScrollList(t, RAID_ROW_H, initTeamRow)
    t.list.frame:SetPoint("TOPLEFT", 0, 0)
    t.list.frame:SetPoint("BOTTOMLEFT", 0, 0)
    t.list.frame:SetWidth(LIST_W)

    local d = CreateFrame("Frame", nil, t)
    d:SetPoint("TOPLEFT", LIST_W + 10, 0)
    d:SetPoint("BOTTOMRIGHT", 0, 0)
    t.detail = d

    d.empty = d:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    d.empty:SetPoint("TOP", 0, -60)
    d.empty:SetWidth(360)

    -- Row 1, the team: its name (a field for organizers, a title for everyone else), size and member count; Undo /
    -- Save and the Delete icon on the right.
    t.nameBox = UI():CreateSleekEditBox(d, 150, 24, "GameFontHighlightLarge")
    t.nameBox:SetTextInsets(6, 20, 0, 0)
    t.nameBox:SetMaxLetters(32)
    t.nameBox:SetPoint("TOPLEFT", 0, 0)
    t.nameBox:SetScript("OnTextChanged", function() PlanUI:RefreshTeamButtons() end)
    t.nameBox.pencil = t.nameBox:CreateTexture(nil, "ARTWORK")
    t.nameBox.pencil:SetSize(12, 12)
    t.nameBox.pencil:SetPoint("RIGHT", -5, 0)
    t.nameBox.pencil:SetTexture(UI().ICON_ATLAS)
    t.nameBox.pencil:SetTexCoord(unpack(UI():IconCoords(16)))
    t.nameBox.pencil:SetVertexColor(0.55, 0.55, 0.55)
    t.nameBox:HookScript("OnEditFocusGained", function(self) self.pencil:Hide() end)
    t.nameBox:HookScript("OnEditFocusLost", function(self) self.pencil:Show() end)
    d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d.title:SetPoint("LEFT", d, "TOPLEFT", 2, -12)

    t.sizeDD = UI():CreateSleekDropdown(d, 80, function()
        return { { value = 10, text = "10-man" }, { value = 25, text = "25-man" } }
    end, function() return state.draft and state.draft.sz or 25 end, function(v) PlanUI:SetDraftSize(v) end)
    t.sizeDD:SetPoint("LEFT", t.nameBox, "RIGHT", 6, 0)

    d.deleteBtn = UI():CreateTipIconButton(d, 22, 12, "Delete team", "Removes the team for everyone. Raids that "
        .. "invited it stay planned.", function()
        local team = state.team and RP():GetTeam(state.team)
        if not team then return end
        PlanUI:Confirm(("Delete the team %s?"):format(team.name), function()
            local ok, err = RP():DeleteTeam(team.id)
            if not ok then Print(err or "Could not delete the team.") end
            state.team, state.draft, state.newTeam = nil, nil, nil
            PlanUI:RefreshTeams()
        end)
    end)
    d.deleteBtn:SetPoint("RIGHT", d, "TOPRIGHT", -2, -12)
    d.saveBtn = UI():CreateSleekButton(d, "Save", 60, 22, function() PlanUI:SaveTeam() end, "primary")
    d.revertBtn = UI():CreateSleekButton(d, "Undo", 54, 22, function() PlanUI:SelectTeam(state.team) end)
    d.revertBtn:SetPoint("RIGHT", d.saveBtn, "LEFT", -3, 0)

    -- "14 members · not saved": after the size (organizers) or the title, cut short before the buttons
    d.count = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.count:SetTextColor(0.6, 0.6, 0.6)
    d.count:SetJustifyH("LEFT")
    d.count:SetWordWrap(false)

    -- Row 2, editing: add members, Auto-fill; the raids that invite the team on the right
    t.picker = UI():CreateSearchDropdown(d, 236, {
        placeholder = "Add guild members...",
        emptyText = "No matching guild members.",
        getItems = pickerItems,
        isChecked = function(key) return state.draft and state.draft.members[key] and true or false end,
        onToggle = function(key) PlanUI:ToggleDraftMember(key) end,
    })
    t.picker.frame:SetPoint("TOPLEFT", 0, -30)
    d.autoBtn = UI():CreateSleekButton(d, "Auto-fill", 72, 22, function() PlanUI:AutoFillDraft() end)
    d.autoBtn:SetPoint("LEFT", t.picker.frame, "RIGHT", 10, 0)
    tipButton(d.autoBtn, "Auto-fill groups", "A starting layout: tanks, melee groups with a shaman each, casters, "
        .. "healers. Adjust it by dragging, then Save.")

    d.raids = CreateFrame("Frame", nil, d)
    d.raids:SetHeight(22)
    d.raids:EnableMouse(true)
    d.raids:SetScript("OnEnter", teamRaidsTooltip)
    d.raids:SetScript("OnLeave", hideTooltip)
    d.raids.fs = d.raids:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.raids.fs:SetAllPoints()
    d.raids.fs:SetWordWrap(false)

    d.rule = d:CreateTexture(nil, "BORDER")
    d.rule:SetPoint("TOPLEFT", 0, -58)
    d.rule:SetPoint("TOPRIGHT", 0, -58)
    d.rule:SetHeight(1)
    d.rule:SetColorTexture(1, 1, 1, 0.08)

    t.grid = ns.RaidGroupsUI:CreateGrid(d, {
        getSize = function() return state.draft and state.draft.sz or 25 end,
        getMembers = draftMembers,
        getGroups = function() return state.draft and state.draft.grp or {} end,
        getSeats = function() return state.draft and state.draft.gs or {} end,
        isEditable = function() return RP():CanManageTeams() end,
        onDrop = function(key, g, target, seat, shown)
            PlanUI:MoveDraftMember(key, g, target, seat, shown)
            PlanUI:RequestRefresh()
        end,
        onSwapGroups = function(a, b) PlanUI:SwapDraftGroups(a, b) end,
        onMenu = memberMenu,
        poolLabel = "Not in a group",
    })
    t.grid.frame:SetPoint("TOPLEFT", 0, -62)
    t.grid.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    return t
end

function PlanUI:RefreshTeamButtons()
    if not teamsView then return end
    local d = teamsView.detail
    local organizer = RP():CanManageTeams()
    local has = state.draft ~= nil and (state.team ~= nil or state.newTeam)
    local dirty = organizer and draftDirty()
    local saved = has and state.draft.id ~= nil
    d.saveBtn:SetShown(organizer and has)
    d.saveBtn:SetEnabled(dirty and true or false)
    -- Save sits at the right edge until the team exists and has a Delete icon
    d.saveBtn:ClearAllPoints()
    if organizer and saved then
        d.saveBtn:SetPoint("RIGHT", d.deleteBtn, "LEFT", -8, 0)
    else
        d.saveBtn:SetPoint("RIGHT", d, "TOPRIGHT", -2, -12)
    end
    d.revertBtn:SetShown(organizer and saved)
    d.revertBtn:SetEnabled(dirty and true or false)

    -- the member count follows the size (organizers) or the title and stops short of the buttons
    d.count:SetShown(has)
    if not has then return end
    local n = 0
    for _ in pairs(state.draft.members) do n = n + 1 end
    d.count:SetText((n == 1 and "1 member" or ("%d members"):format(n))
        .. (dirty and colorize("ff9933", " · not saved") or ""))
    d.count:ClearAllPoints()
    d.count:SetPoint("LEFT", organizer and teamsView.sizeDD or d.title, "RIGHT", 10, 0)
    local stop = (organizer and saved and d.revertBtn) or (organizer and d.saveBtn) or nil
    if stop then d.count:SetPoint("RIGHT", stop, "LEFT", -8, 0) else d.count:SetPoint("RIGHT", d, "TOPRIGHT", -2, -12) end
end

function PlanUI:RefreshTeams()
    if not teamsView or not teamsView:IsVisible() then return end
    local teams = RP():GetTeams()
    local organizer = RP():CanManageTeams()
    if not (state.newTeam and organizer) then
        state.newTeam = nil
        local found = false
        for _, tm in ipairs(teams) do if tm.id == state.team then found = true end end
        if not found then state.team = teams[1] and teams[1].id or nil end
        if not state.draft or state.draft.id ~= state.team then loadDraft(state.team) end
    end
    teamsView.list:SetEmptyText(organizer and "No teams yet.\nClick New team to make one." or "No teams yet.")
    teamsView.list:SetData(teams)

    local d = teamsView.detail
    local dr = (state.team or state.newTeam) and state.draft or nil
    local has = dr ~= nil
    teamsView.nameBox:SetShown(has and organizer)
    d.title:SetShown(has and not organizer)
    teamsView.picker.frame:SetShown(has and organizer)
    teamsView.sizeDD:SetShown(has and organizer)
    d.autoBtn:SetShown(has and organizer)
    d.deleteBtn:SetShown(has and organizer and dr.id ~= nil)
    d.raids:SetShown(has and dr.id ~= nil)
    d.rule:SetShown(has)
    teamsView.grid.frame:SetShown(has)
    d.empty:SetShown(not has)
    d.empty:SetText(organizer and "Make a team with New team, then pick it when you plan a raid."
        or "Teams are made by the Guild Master and the guild council.")
    if has then d.title:SetText(dr.name .. grey(("  %d-man"):format(dr.sz or 25))) end
    self:RefreshTeamButtons()
    if not has then return end
    if teamsView.sizeDD.Refresh then teamsView.sizeDD:Refresh() end
    -- "2 raids · Next Sun 5 Oct  Karazhan": the count first, so a long raid name is what gets cut; the tooltip
    -- lists them all. Organizers have it after Auto-fill, everyone else on its own row.
    local raids = dr.id and teamRaids(dr.id) or {}
    d.raids.raids = raids
    d.raids:ClearAllPoints()
    if organizer then
        d.raids:SetPoint("TOPLEFT", d.autoBtn, "TOPRIGHT", 12, 0)
        d.raids.fs:SetJustifyH("RIGHT")
    else
        d.raids:SetPoint("TOPLEFT", 2, -30)
        d.raids.fs:SetJustifyH("LEFT")
    end
    d.raids:SetPoint("TOPRIGHT", d, "TOPRIGHT", -2, -30)
    if #raids == 0 then
        d.raids.fs:SetText(grey("No upcoming raids"))
    else
        local v = raids[1]
        d.raids.fs:SetText((#raids > 1 and grey(("%d raids · "):format(#raids)) or "") .. colorize("ffd100", "Next ")
            .. shortDay(v.t) .. "  " .. RP():GetRaidName(v))
    end
    teamsView.grid:Refresh()
    if teamsView.picker.IsOpen and teamsView.picker:IsOpen() then teamsView.picker:RefreshRows() end
end

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

local function teamSummary()
    local n = 0
    local names = {}
    for _, t in ipairs(RP():GetTeams()) do
        if editor.f.tm[t.id] then n = n + 1; names[#names + 1] = t.name end
    end
    if n == 0 then return "Everyone (no team)" end
    return tconcat(names, ", ")
end

-- The guild members to invite on top of the teams (members of a picked team are in already).
local function inviteItems()
    local g = ns.Guild
    local inTeam = {}
    for _, t in ipairs(RP():GetTeams()) do
        if editor.f.tm[t.id] then
            for _, key in ipairs(t.members) do inTeam[key] = t.name end
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
    local tm = {}
    for _, t in ipairs(RP():GetTeams()) do
        if f.tm[t.id] then tm[#tm + 1] = t.id end
    end
    return {
        i = f.i, sz = f.sz, t = editorTime(), tm = tm, lk = f.lk and true or false, inv = inviteList(),
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
    w.f = { tm = {}, inv = {} }

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

    row(c, "Teams", -142)
    w.teamDD = UI():CreateMultiDropdown(c, 270, function()
        local out = {}
        for _, t in ipairs(RP():GetTeams()) do
            out[#out + 1] = { value = t.id, text = ("%s (%d)"):format(t.name, #t.members) }
        end
        if #out == 0 then out[1] = { value = "", text = "No teams yet (Teams view)", disabled = true } end
        return out
    end, function(id) return w.f.tm[id] and true or false end, function(id, on)
        if id ~= "" then w.f.tm[id] = on or nil end
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
    local f = { tm = {}, inv = {}, lk = false, low = false }   -- (a new raid is for level 70 characters)
    if v then
        f.low = v.ml == nil
        local d = date("*t", v.t)
        f.i, f.sz, f.hour, f.min = v.i, v.sz, d.hour, d.min - d.min % 15
        f.y, f.m, f.d = d.year, d.month, d.day
        for _, id in ipairs(v.tm or {}) do f.tm[id] = true end
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
function PlanUI:OpenInvites(occId)
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
    end
end

function PlanUI:OnLogin()
    -- After the login sync (HELLO + catch-up) had time to bring the raids in.
    ns.Util.After(45, Remind)
end

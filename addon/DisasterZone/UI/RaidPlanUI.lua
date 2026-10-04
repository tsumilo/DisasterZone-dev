if DisasterZoneBoot and DisasterZoneBoot.Run("UI/RaidPlanUI.lua", ...) then return end -- DisasterZone: UI/RaidPlanUI.lua
-- Raid planning views of the Raids tab (Addendum J §58): "Upcoming" (the raid list with its filters, a raid's sign-up
-- strip and roster) and "Teams" (team lists), plus the New / Edit raid window and the Add players window (invited guild
-- members and guests from outside the guild). The blacklist lives in the Guests window (UI/GuestBook.lua). RaidsTab
-- owns the tab and its toolbar and creates these views inside its panel.
local addonName, ns = ...

local PlanUI = ns:NewModule("RaidPlanUI")

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tsort, tconcat = table.sort, table.concat

local DAY = 86400
local LIST_W = 290
local RAID_ROW_H = 36
local HEADER_ROW_H = 22
local CELL_H = 16
local FILTER_H = 26                 -- the filter row above the raid list
local DETAIL_TOP = 82               -- a raid's title, line, note and tab row; the tab's content starts below
local EDITOR_DAYS = 60
local MAX_LEVEL = 70                -- a new raid asks for this level unless "Allow characters below level 70" is ticked

local ROLE_COLS = {
    { key = "tank", label = "Tanks" },
    { key = "healer", label = "Healers" },
    { key = "melee", label = "Melee" },
    { key = "ranged", label = "Ranged" },
}
local STATUS_ORDER = { "A", "T", "B", "X" }
local STATUS = {
    A = { button = "Accept", label = "Accepted", color = "33ff33" },
    T = { button = "Tentative", label = "Tentative", color = "ffd100" },
    B = { button = "Bench", label = "Bench", color = "99bbff" },
    X = { button = "Absent", label = "Absent", color = "ff5555" },
}
local ICON = {
    A = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12|t",
    T = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:12|t",
    X = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:12|t",
}

local GUEST_TAG = " |cff66ccff(guest)|r"

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
    if state.pendingChar then return state.pendingChar end
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
-- Upcoming: raid list (left)
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
    if block then return grey("not invited"), nil end
    return grey("not answered"), nil
end

-- The list row's short form: my answer as its ready-check icon (Bench in words, it has none); anything else as text.
local LIST_ICON = {
    A = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t",
    T = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14|t",
    X = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t",
}
local function myStatusMark(v)
    local mine = RP():GetMySignup(v.id)
    if mine and LIST_ICON[mine.st] then return LIST_ICON[mine.st], STATUS[mine.st].color end
    return myStatusText(v)
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

local function initRaidRow(row, d)
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
        row.accent = row:CreateTexture(nil, "ARTWORK")
        row.accent:SetPoint("TOPLEFT", 0, -2)
        row.accent:SetPoint("BOTTOMLEFT", 0, 2)
        row.accent:SetWidth(3)
        row.l1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.l1:SetPoint("TOPLEFT", 8, -3)
        row.l1:SetPoint("RIGHT", -4, 0)
        row.l1:SetJustifyH("LEFT")
        row.l1:SetWordWrap(false)
        -- my answer, on the right of the second line (never cut off)
        row.st = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.st:SetPoint("TOPRIGHT", -6, -20)
        row.l2 = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.l2:SetPoint("TOPLEFT", 8, -20)
        row.l2:SetPoint("TOPRIGHT", row.st, "TOPLEFT", -6, 0)
        row.l2:SetJustifyH("LEFT")
        row.l2:SetWordWrap(false)
        row.head = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.head:SetPoint("BOTTOMLEFT", 4, 3)
        row:SetScript("OnClick", function(self)
            local data = self.__cdlData
            if data and data.v then PlanUI:SelectRaid(data.v.id) end
        end)
        row:SetScript("OnEnter", raidRowTooltip)
        row:SetScript("OnLeave", hideTooltip)
    end
    local header = d.header ~= nil
    row.head:SetShown(header)
    row.l1:SetShown(not header)
    row.l2:SetShown(not header)
    row.st:SetShown(not header)
    row.accent:SetShown(not header)
    row:EnableMouse(not header)
    if header then
        row.head:SetText(d.header)
        row.sel:Hide()
        return
    end
    local v = d.v
    row.sel:SetShown(v.id == state.selected)
    -- line 1: the raid; line 2: when, how full, who it is for (unless the name says so), and my answer
    local when = fmtDay(v.t) .. "  " .. fmtTime(v.t)
    local name = raidTitle(v)
    local c = counts(v.id)
    local status, hex = myStatusMark(v)
    local parts = { ("%d/%d accepted"):format(c.A, v.sz or 0) }
    local teams = teamNames(v, true)
    if teams ~= "Everyone" and not name:find(teams, 1, true) then parts[#parts + 1] = teams end
    if v.weekly then parts[#parts + 1] = "weekly" end
    if v.cancelled then
        row.l1:SetText(grey(name))
        row.l2:SetText(when .. " · cancelled")
        row.st:SetText("")
    else
        row.l1:SetText("|cffffd100" .. name .. "|r")
        row.l2:SetText("|cffffffff" .. when .. "|r · " .. tconcat(parts, " · "))
        row.st:SetText(status)
    end
    if hex and not v.cancelled then
        local r, g, b = hexRGB(hex)
        row.accent:SetColorTexture(r, g, b, 0.9)
    else
        row.accent:SetColorTexture(0.4, 0.4, 0.4, 0.5)
    end
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
    for _, v in ipairs(RP():GetRaids()) do
        local b
        if v.t < now - 6 * 3600 then b = 4
        elseif v.t < ws + 7 * DAY then b = 1
        elseif v.t < ws + 14 * DAY then b = 2
        else b = 3
        end
        if passesFilter(v, now, ws) then buckets[b][#buckets[b] + 1] = v end
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
-- Upcoming: roster (right, below the sign-up strip)
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
        GameTooltip:AddLine("Declined by the raid leaders", 1, 0.33, 0.33)
        if s and s.st and STATUS[s.st] then GameTooltip:AddLine("Had answered " .. STATUS[s.st].label, 0.7, 0.7, 0.7) end
    elseif d.guest then
        GameTooltip:AddLine("Guest: not in the guild, added by the raid leaders", 0.4, 0.8, 1, true)
        -- 1.3: what the guest book knows about them (roster managers)
        local summary = RP():CanManageRoster() and ns.GuestBook and ns.GuestBook:Summary(d.key)
        if summary then GameTooltip:AddLine(summary, 0.7, 0.7, 0.7, true) end
    elseif s then
        GameTooltip:AddLine(STATUS[s.st].label, 0.8, 0.8, 0.8)
        if s.n then GameTooltip:AddLine('"' .. s.n .. '"', 1, 0.82, 0, true) end
        for _, line in ipairs(signupLines(s, d.order, d.total)) do GameTooltip:AddLine(line, 0.7, 0.7, 0.7) end
    end
    if RP():CanManageRoster() then GameTooltip:AddLine("Right-click for options", 0.5, 0.5, 0.5) end
    local RL = ns.RaidLog
    if ns.Guild and ns.Guild.AmIRaidLogMember and ns.Guild:AmIRaidLogMember() and RL and RL.GetAttendanceText then
        local att = RL:GetAttendanceText(d.key)
        if att then GameTooltip:AddLine("Attendance " .. att, 0.7, 0.7, 0.7) end
        local rel = RL.GetReliabilityText and RL:GetReliabilityText(d.key)
        if rel then GameTooltip:AddLine("Sign-ups: " .. rel, 0.7, 0.7, 0.7) end
    end
    GameTooltip:Show()
end

-- Right-click on a player of the roster (roster managers): decline, remove the answer, restore, remove a guest,
-- blacklist.
local function rosterMenu(cell)
    local d = cell.cdlCell
    local occ = state.selected
    if not d or not occ or not RP():CanManageRoster() then return end
    local function run(fn, ...)
        local ok, err = fn(RP(), occ, ...)
        if not ok then Print(err or "Could not change the raid.") end
    end
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
        root:CreateDivider()
        root:CreateButton("Blacklist...", function() PlanUI:OpenBlacklist(d.key) end)
        if d.guest then root:CreateButton("Guest book...", function() ns.GuestBookUI:OpenGuest(d.key) end) end
    end)
end

local function initRosterRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        row.cells = {}
        for i = 1, #ROLE_COLS do
            local cell = CreateFrame("Button", nil, row)
            cell:SetHeight(CELL_H)
            cell:RegisterForClicks("RightButtonUp")
            cell:SetScript("OnClick", rosterMenu)
            cell.fs = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            cell.fs:SetPoint("LEFT", 2, 0)
            cell.fs:SetPoint("RIGHT", -2, 0)
            cell.fs:SetJustifyH("LEFT")
            cell.fs:SetWordWrap(false)
            cell:SetScript("OnEnter", cellTooltip)
            cell:SetScript("OnLeave", hideTooltip)
            -- the role headers' underline
            cell.rule = cell:CreateTexture(nil, "BORDER")
            cell.rule:SetPoint("BOTTOMLEFT", 2, 1)
            cell.rule:SetPoint("BOTTOMRIGHT", -8, 1)
            cell.rule:SetHeight(1)
            cell.rule:SetColorTexture(1, 0.82, 0, 0.25)
            row.cells[i] = cell
        end
        -- a section below the role columns (No response, Bench, ...): a divider, then its title
        row.sep = row:CreateTexture(nil, "BORDER")
        row.sep:SetPoint("TOPLEFT", 0, -3)
        row.sep:SetPoint("TOPRIGHT", 0, -3)
        row.sep:SetHeight(1)
        row.sep:SetColorTexture(1, 1, 1, 0.08)
        row.line = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.line:SetPoint("TOPLEFT", 4, -9)
        row.line:SetPoint("RIGHT", -4, 0)
        row.line:SetJustifyH("LEFT")
        row.line:SetJustifyV("TOP")
        row.line:SetWordWrap(true)
    end
    local w = (row:GetWidth() or 460) / #ROLE_COLS
    for i, cell in ipairs(row.cells) do
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", (i - 1) * w, 0)
        cell:SetWidth(w)
        local c = d.cols and d.cols[i]
        cell.cdlCell = type(c) == "table" and c or nil
        cell.rule:SetShown(d.header and true or false)
        cell.fs:SetAlpha(1)
        if type(c) == "string" then
            cell.fs:SetText(c)
            cell:Show()
        elseif type(c) == "table" then
            -- c.s is nil for a player who hasn't answered
            local st = c.s and c.s.st
            local icon = st and ICON[st] or ""
            local spec = c.s and ns.RaidComp:SpecIcon(c.s.c, c.s.sp)
            local text = icon .. (spec and (" |T" .. spec .. ":12:12:0:0:64:64:5:59:5:59|t") or "") .. " "
                .. colored(c.key, classOf(c.key, c.s))
            if c.guest then text = text .. GUEST_TAG end
            if c.s and c.s.n then text = text .. grey(" *") end
            cell.fs:SetText(text)
            -- tentative and not-answered players are drawn fainter
            cell.fs:SetAlpha((d.dim and 0.6) or (st == "T" and 0.7) or 1)
            cell:Show()
        else
            cell:Hide()
        end
    end
    row.line:SetShown(d.line ~= nil)
    row.sep:SetShown(d.line ~= nil)
    row.line:SetText(d.line or "")
end

local function rosterExtent(d)
    if d.line then return 16 * max(1, ceil(#(d.plain or "") / 75)) + 12 end
    if d.header then return 20 end
    return CELL_H
end

-- Rows: a header row per role column, then one row per rank (the i-th tank, healer, ... side by side), then
-- a titled block of name cells each for spec not set, Bench, Absent and No response.
local function rosterRows(v)
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
    local rows = {}
    local header = { header = true, cols = {} }
    local depth = 0
    for i, col in ipairs(ROLE_COLS) do
        local list = byRole[col.key]
        tsort(list, function(a, b)
            local sa, sb = signups[a].st, signups[b].st
            if sa ~= sb then return sa == "A" end
            return (order[a] or 0) < (order[b] or 0)
        end)
        local accepted = 0
        for _, key in ipairs(list) do if signups[key].st == "A" then accepted = accepted + 1 end end
        -- "Ranged 1 +1 tentative": accepted, then the tentative ones (just "+12 (?)" when that would not fit)
        local tentative = #list - accepted
        local more = ""
        if tentative > 0 then
            more = (accepted < 10 and tentative < 10) and grey((" +%d tentative"):format(tentative))
                or (grey(" +" .. tentative) .. " " .. ICON.T)
        end
        header.cols[i] = ("|cffffd100%s|r %d"):format(col.label, accepted) .. more
        depth = max(depth, #list)
    end
    rows[1] = header
    for r = 1, depth do
        local d = { cols = {} }
        for i, col in ipairs(ROLE_COLS) do
            local key = byRole[col.key][r]
            if key then d.cols[i] = cell(key) end
        end
        rows[#rows + 1] = d
    end
    -- players outside the role columns: a header line, then their names as cells (hover shows the order)
    local function cells(label, keys, less, dim)
        if #keys == 0 then return end
        tsort(keys, less or function(a, b) return (order[a] or 0) < (order[b] or 0) end)
        rows[#rows + 1] = { line = label .. " (" .. #keys .. ")", plain = label }
        for i = 1, #keys, #ROLE_COLS do
            local d = { cols = {}, dim = dim }
            for j = 1, #ROLE_COLS do
                if keys[i + j - 1] then d.cols[j] = cell(keys[i + j - 1]) end
            end
            rows[#rows + 1] = d
        end
    end
    cells(colorize(STATUS.T.color, "Spec not set"), other.nospec)
    cells(colorize(STATUS.B.color, "Bench"), other.B)
    cells(colorize(STATUS.X.color, "Absent"), other.X)
    local out = {}
    for key in pairs(declined) do
        if not signups[key] then out[#out + 1] = key end
    end
    cells(colorize("ff5555", "Declined"), out, nameLess)
    cells(colorize("ff9933", "No response"), noResponse(v, signups), nameLess, true)
    return rows
end

---------------------------------------------------------------------------
-- Upcoming: detail (right)
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
    if state.pendingSpec then return state.pendingSpec end
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
        if key == cur or (occ and RP():CanSignUp(occ, key)) then
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

function PlanUI:Answer(status)
    local occ = state.selected
    if not occ then return end
    local note = state.pendingNote
    if note == nil and upcoming then
        local text = ns.Util.Trim(upcoming.noteBox:GetText() or "")
        local mine = RP():GetMySignup(occ)
        if text ~= ((mine and mine.n) or "") then note = text ~= "" and text or false end
    end
    local ok, err = RP():SignUp(occ, status, mySpec(occ), note, myChar(occ))
    if not ok then
        Print(err or "Could not save your answer.")
        return false
    end
    state.pendingSpec, state.pendingNote, state.noteEdited, state.pendingChar = nil, nil, nil, nil
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
    if v.weekly then
        root:CreateButton("Stop repeating after this raid", function() run(RP().StopRepeating, v.id) end)
    end
    -- deleting removes the raid for everyone, with its sign-ups and groups (cancelling keeps it listed)
    root:CreateDivider()
    if v.weekly then
        root:CreateButton("Delete this week's raid...", function() PlanUI:ConfirmDelete(nil) end)
        root:CreateButton("Delete the whole weekly raid...", function() PlanUI:ConfirmDelete("series") end)
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
    if not v or not RP():CanEditGroups() then return false end
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
    if not v or not RP():CanEditGroups() then return end
    local dr = raidDraft(v)
    swapGroups(dr.grp, a, b)
    dr.dirty = true
    self:RequestRefresh()
end

function PlanUI:AutoFillRaid()
    local v = selectedRaid()
    if not v or not RP():CanEditGroups() then return end
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
    if not v or not RP():CanEditGroups() then return end
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
    if RP():CanEditGroups() and (dr.dirty or not dr.saved) and not self:SaveRaidLayout() then return false end
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

local function createRaidGroups(d)
    local g = CreateFrame("Frame", nil, d)
    g:SetPoint("TOPLEFT", 0, -DETAIL_TOP)
    g:SetPoint("BOTTOMRIGHT", 0, 0)
    d.groups = g

    g.autoBtn = UI():CreateSleekButton(g, "Auto-fill", 70, 22, function() PlanUI:AutoFillRaid() end)
    g.autoBtn:SetPoint("TOPLEFT", 0, 0)
    tipButton(g.autoBtn, "Auto-fill", "A fresh layout of everyone who accepted: tanks, melee groups with a shaman each, "
        .. "casters, healers.")
    g.teamBtn = UI():CreateSleekButton(g, "From team", 80, 22, function() PlanUI:ResetRaidLayout() end)
    g.teamBtn:SetPoint("LEFT", g.autoBtn, "RIGHT", 3, 0)
    tipButton(g.teamBtn, "From team", "Start again from the team's group layout: players keep their team seat, others "
        .. "who accepted fill the seats of team members who didn't.")
    g.undoBtn = UI():CreateSleekButton(g, "Undo", 50, 22, function() PlanUI:UndoRaidLayout() end)
    g.undoBtn:SetPoint("LEFT", g.teamBtn, "RIGHT", 3, 0)
    g.saveBtn = UI():CreateSleekButton(g, "Save", 56, 22, function() PlanUI:SaveRaidLayout() end, "primary")
    g.saveBtn:SetPoint("LEFT", g.undoBtn, "RIGHT", 3, 0)

    g.resortBtn = UI():CreateSleekButton(g, "Re-sort", 68, 22, function() PlanUI:ResortRaid() end)
    g.resortBtn:SetPoint("TOPRIGHT", -2, 0)
    tipButton(g.resortBtn, "Re-sort groups", "Moves everyone in your raid to their planned group now, e.g. after late "
        .. "joiners or a change of plan. Players who aren't planned go to groups 6-8.")
    g.inviteBtn = UI():CreateSleekButton(g, "Invite & sort", 100, 22, function() PlanUI:InviteRaid() end)
    g.inviteBtn:SetPoint("RIGHT", g.resortBtn, "LEFT", -4, 0)
    tipButton(g.inviteBtn, "Invite & sort", "Invites everyone placed in a group, guests too (an accepted player "
        .. "without a group is not invited), makes the group a raid and moves each player into their group as they "
        .. "join. Players who join later are sorted too, until the raid ends. Missing shows who has not joined and "
        .. "why. Needs the raid leader or an assistant.")

    g.status = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    g.status:SetPoint("TOPLEFT", 2, -28)
    g.status:SetPoint("RIGHT", -152, 0)
    g.status:SetJustifyH("LEFT")
    g.status:SetWordWrap(false)
    g.stopBtn = UI():CreateSleekButton(g, "Stop", 56, 20, function()
        ns.RaidInvite:Stop()
        PlanUI:RefreshUpcoming()
    end)
    g.stopBtn:SetPoint("TOPRIGHT", -2, -24)
    -- who the run is still waiting for, and who is in the raid without being on its roster
    g.missingBtn = UI():CreateSleekMenuButton(g, "Missing", 84, function(root)
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
    end, 20)
    g.missingBtn:SetPoint("RIGHT", g.stopBtn, "LEFT", -4, 0)

    g.grid = ns.RaidGroupsUI:CreateGrid(g, {
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
        isEditable = function() return RP():CanEditGroups() end,
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
    })
    g.grid.frame:SetPoint("TOPLEFT", 0, -46)
    g.grid.frame:SetPoint("BOTTOMRIGHT", 0, 0)
end

local function refreshGroups(v)
    local g = upcoming.detail.groups
    local organizer = RP():CanEditGroups()
    local dr = raidDraft(v)
    local lead = leadsGroup()
    for _, b in ipairs({ g.autoBtn, g.teamBtn, g.undoBtn, g.saveBtn }) do b:SetShown(organizer) end
    g.undoBtn:SetEnabled(dr.dirty)
    g.saveBtn:SetEnabled(dr.dirty or not dr.saved)
    g.teamBtn:SetEnabled(v.tm ~= nil and #v.tm > 0)
    local canInvite = (organizer or lead) and not v.cancelled
    g.inviteBtn:SetShown(canInvite)
    g.resortBtn:SetShown(canInvite)
    g.resortBtn:SetEnabled(IsInRaid() and lead)
    local st = ns.RaidInvite:IsActive(v.id) and ns.RaidInvite:GetStatus() or nil
    g.stopBtn:SetShown(st ~= nil)
    local missing = st and (#st.offline + #st.declined + #st.grouped + #st.pending + #st.unlisted) or 0
    g.missingBtn:SetShown(missing > 0)
    g.missingBtn:SetText(("Missing (%d)"):format(missing))
    local placed, total = 0, 0
    for _, m in ipairs(raidMembers()) do
        total = total + 1
        if dr.grp[m.key] then placed = placed + 1 end
    end
    local text
    if st then
        text = colorize("33ff33", "Invite & sort: ") .. ("%d/%d in the raid · %d sorted"):format(st.inRaid, st.planned, st.sorted)
        if #st.offline > 0 then
            local names = {}
            for i, key in ipairs(st.offline) do
                if i > 3 then names[#names + 1] = "..." break end
                names[#names + 1] = shortName(key)
            end
            text = text .. colorize("ff9933", (" · %d offline (%s)"):format(#st.offline, tconcat(names, ", ")))
        end
        for _, e in ipairs({ { st.declined, "declined" }, { st.grouped, "in another group" },
                             { st.pending, "not joined yet" }, { st.unlisted, "not on the roster" } }) do
            if #e[1] > 0 then text = text .. colorize("ff9933", (" · %d %s"):format(#e[1], e[2])) end
        end
        if st.waitCombat then text = text .. colorize("ff5555", " · waiting for combat to end") end
        if dr.dirty then text = colorize("ff9933", "Changed, not saved. Save to move players. ") .. text end
    elseif dr.dirty then
        text = colorize("ff9933", "Changed, not saved.") .. grey(("  %d of %d placed"):format(placed, total))
    elseif dr.saved then
        text = grey(("Saved layout · %d of %d placed"):format(placed, total))
    else
        text = grey(("Starting layout (follows the sign-ups until saved) · %d of %d placed"):format(placed, total))
    end
    g.status:SetText(text)
    g.grid:Refresh()
end

function PlanUI:CreateUpcoming(parent)
    local u = CreateFrame("Frame", nil, parent)
    upcoming = u

    -- Filters: which raid, and when
    local half = floor((LIST_W - 3) / 2)
    u.raidDD = UI():CreateSleekDropdown(u, half, raidFilterOptions, function() return state.filterRaid end, function(val)
        state.filterRaid = val
        PlanUI:RefreshUpcoming()
    end)
    u.raidDD:SetPoint("TOPLEFT", 0, 0)
    u.whenDD = UI():CreateSleekDropdown(u, LIST_W - half - 3, function() return WHEN_OPTIONS end,
        function() return state.filterWhen end, function(val)
            state.filterWhen = val
            PlanUI:RefreshUpcoming()
        end)
    u.whenDD:SetPoint("LEFT", u.raidDD, "RIGHT", 3, 0)

    u.list = UI():CreateScrollList(u, RAID_ROW_H, initRaidRow, function(d) return d.header and HEADER_ROW_H or RAID_ROW_H end)
    u.list.frame:SetPoint("TOPLEFT", 0, -FILTER_H)
    u.list.frame:SetPoint("BOTTOMLEFT", 0, 0)
    u.list.frame:SetWidth(LIST_W)
    u.list:SetEmptyText("No raids planned yet.")

    local d = CreateFrame("Frame", nil, u)
    d:SetPoint("TOPLEFT", LIST_W + 10, 0)
    d:SetPoint("BOTTOMRIGHT", 0, 0)
    u.detail = d

    d.empty = d:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    d.empty:SetPoint("TOP", 0, -60)
    d.empty:SetText("Pick a raid on the left.")

    -- Row 1: the raid and the organizer's actions; row 2: when and who; row 3: the raid's note; row 4: the tabs
    d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d.title:SetPoint("TOPLEFT", 2, -2)
    d.title:SetPoint("RIGHT", -90, 0)
    d.title:SetJustifyH("LEFT")
    d.title:SetWordWrap(false)
    d.sub = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.sub:SetPoint("TOPLEFT", 2, -24)
    d.sub:SetPoint("RIGHT", -4, 0)
    d.sub:SetJustifyH("LEFT")
    d.sub:SetWordWrap(false)
    d.note = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    d.note:SetPoint("TOPLEFT", 2, -40)
    d.note:SetPoint("RIGHT", -4, 0)
    d.note:SetJustifyH("LEFT")
    d.note:SetWordWrap(false)

    -- Sign-ups / Groups / Assignments (Addendum K: the raid's strategy boards, who does what on each boss)
    -- small text tabs: views inside the page's Upcoming view
    local function tab(label, key)
        local b = UI():CreateUnderlineTab(d, label, function()
            state.detailTab = key
            PlanUI:RefreshUpcoming()
        end, "small")
        b.key = key
        return b
    end
    d.tabSignups = tab("Sign-ups", "signups")
    d.tabSignups:SetPoint("TOPLEFT", -4, -58)
    d.tabGroups = tab("Groups", "groups")
    d.tabGroups:SetPoint("LEFT", d.tabSignups, "RIGHT", 6, 0)
    d.tabAssign = tab("Assignments", "assign")
    d.tabAssign:SetPoint("LEFT", d.tabGroups, "RIGHT", 6, 0)
    d.tabLine = d:CreateTexture(nil, "BORDER")
    d.tabLine:SetPoint("TOPLEFT", 0, -76)
    d.tabLine:SetPoint("TOPRIGHT", 0, -76)
    d.tabLine:SetHeight(1)
    d.tabLine:SetColorTexture(1, 1, 1, 0.1)

    -- Organizer actions (top right): icons, what each does is in its tooltip
    local ACT = 24
    d.cancelBtn = UI():CreateTipIconButton(d, ACT, 20, "Cancel or delete", "Call the raid off (it stays listed as "
        .. "cancelled), stop a weekly raid from repeating, or delete it.", function(self)
        UI():ContextMenu(self, cancelMenu)
    end)
    d.cancelBtn:SetPoint("TOPRIGHT", -2, 0)
    function d.cancelBtn:OpenMenu() UI():ContextMenu(self, cancelMenu) end
    d.editBtn = UI():CreateTipIconButton(d, ACT, 16, "Edit raid", "Change the raid's time, size, teams or note.",
        function()
            if state.selected then PlanUI:OpenEditor(state.selected) end
        end)
    d.editBtn:SetPoint("RIGHT", d.cancelBtn, "LEFT", -3, 0)
    d.inviteBtn = UI():CreateTipIconButton(d, ACT, 19, "Add players", "Guild members outside the raid's teams (on a "
        .. "locked raid they are the only ones besides the teams), and guests: players who are not in the guild, "
        .. "added by name.", function()
        if state.selected then PlanUI:OpenInvites(state.selected) end
    end)
    d.inviteBtn:SetPoint("RIGHT", d.editBtn, "LEFT", -3, 0)

    -- Sign-up strip, flat: row 1 my answer (one joined control) and why I can't answer or when I did; row 2 my spec,
    -- the character I answer as and my note
    local strip = CreateFrame("Frame", nil, d)
    strip:SetPoint("TOPLEFT", 0, -DETAIL_TOP)
    strip:SetPoint("RIGHT", 0, 0)
    strip:SetHeight(64)
    strip.bg = strip:CreateTexture(nil, "BACKGROUND")
    strip.bg:SetAllPoints()
    strip.bg:SetColorTexture(0.08, 0.08, 0.09, 0.75)
    UI():AddEdges(strip)
    UI():SetEdgeColor(strip, 0.3, 0.3, 0.34, 0.8)
    d.strip = strip
    u.statusBtns = {}
    local prev
    for _, st in ipairs(STATUS_ORDER) do
        local b = UI():CreateSleekButton(strip, STATUS[st].button, 72, 22, function() PlanUI:Answer(st) end)
        -- joined: neighbours share their 1px edge
        if prev then b:SetPoint("LEFT", prev, "RIGHT", -1, 0) else b:SetPoint("TOPLEFT", 8, -8) end
        b.st = st
        u.statusBtns[st] = b
        prev = b
    end
    -- why I can't answer, that I still have to, or when I did: on the answers' row, cut short before them
    strip.closed = strip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    strip.closed:SetPoint("LEFT", prev, "RIGHT", 10, 0)
    strip.closed:SetPoint("RIGHT", strip, "TOPRIGHT", -10, -19)
    strip.closed:SetJustifyH("RIGHT")
    strip.closed:SetWordWrap(false)

    strip.specLabel = strip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    strip.specLabel:SetPoint("LEFT", strip, "TOPLEFT", 10, -45)
    strip.specLabel:SetText("Spec")
    u.specDD = UI():CreateSleekDropdown(strip, 104, mySpecOptions, function() return mySpec(state.selected) end, setSpec)
    u.specDD:SetPoint("LEFT", strip.specLabel, "RIGHT", 6, 0)
    -- which of my characters answers (shown when my account has more than one in the guild)
    strip.charLabel = strip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    strip.charLabel:SetPoint("LEFT", u.specDD, "RIGHT", 10, 0)
    strip.charLabel:SetText("As")
    u.charDD = UI():CreateSleekDropdown(strip, 130, myCharOptions, function() return myChar(state.selected) end, setChar)
    u.charDD:SetPoint("LEFT", strip.charLabel, "RIGHT", 6, 0)
    tipButton(u.charDD, "Sign up as", "Answer with another of your characters in the guild, whichever one you are "
        .. "logged in on. Your characters count as one player: the last answer is the one that counts.")
    -- my note: the rest of the row, after the spec or the "As" picker (placed in refreshDetail)
    u.noteBox = UI():CreateSleekEditBox(strip, 120, 22, "GameFontHighlightSmall")
    u.noteBox:SetMaxLetters(40)
    u.noteBox:SetScript("OnEnterPressed", saveNote)
    -- A typed note is kept through repaints (a spec pick repaints) until it is saved or another raid is picked.
    u.noteBox:SetScript("OnTextChanged", function(_, userInput) if userInput then state.noteEdited = true end end)
    u.noteBox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Note")
        GameTooltip:AddLine("A short note for the organizers, e.g. \"late 20 min\". Press Enter to save.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    u.noteBox:SetScript("OnLeave", hideTooltip)
    UI():SetEditPlaceholder(u.noteBox, "Note for the organizers...")

    -- "6/10 accepted · 1 tentative · 7 no response", after a bar that fills up to the raid's size
    d.fill = CreateFrame("Frame", nil, d)
    d.fill:SetSize(70, 6)
    d.fill:SetPoint("TOPLEFT", 2, -(DETAIL_TOP + 75))
    d.fill.bg = d.fill:CreateTexture(nil, "BACKGROUND")
    d.fill.bg:SetAllPoints()
    d.fill.bg:SetColorTexture(1, 1, 1, 0.1)
    d.fill.bar = d.fill:CreateTexture(nil, "ARTWORK")
    d.fill.bar:SetPoint("TOPLEFT")
    d.fill.bar:SetPoint("BOTTOMLEFT")
    d.fill.bar:SetColorTexture(0.2, 0.8, 0.2, 0.9)
    d.counts = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.counts:SetPoint("LEFT", d.fill, "RIGHT", 8, 0)
    d.counts:SetPoint("RIGHT", d, "TOPRIGHT", -4, -(DETAIL_TOP + 78))
    d.counts:SetJustifyH("LEFT")
    d.counts:SetWordWrap(false)

    d.roster = UI():CreateScrollList(d, CELL_H, initRosterRow, rosterExtent)
    d.roster.frame:SetPoint("TOPLEFT", 0, -(DETAIL_TOP + 90))
    d.roster.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    d.roster:SetEmptyText("")

    createRaidGroups(d)
    d.assign = ns.StrategiesUI:CreateRaidAssignments(d)
    d.assign:SetPoint("TOPLEFT", 0, -DETAIL_TOP)
    d.assign:SetPoint("BOTTOMRIGHT", 0, 0)
    return u
end

local function refreshDetail(v)
    local d = upcoming.detail
    local has = v ~= nil
    local groupsTab = state.detailTab == "groups"
    local assignTab = state.detailTab == "assign"
    for _, region in ipairs({ d.title, d.sub, d.note, d.tabSignups, d.tabGroups, d.tabAssign, d.tabLine }) do
        region:SetShown(has)
    end
    for _, region in ipairs({ d.strip, d.fill, d.counts, d.roster.frame }) do
        region:SetShown(has and not groupsTab and not assignTab)
    end
    d.groups:SetShown(has and groupsTab)
    d.assign:SetShown(has and assignTab)
    d.tabSignups:SetActive(not groupsTab and not assignTab)
    d.tabGroups:SetActive(groupsTab)
    d.tabAssign:SetActive(assignTab)
    d.empty:SetShown(not has)
    local organizer = RP():CanOrganize()
    d.editBtn:SetShown(has and organizer)
    d.cancelBtn:SetShown(has and organizer)
    d.inviteBtn:SetShown(has and (organizer or RP():CanManageRoster()))
    if not has then return end

    d.title:SetText(raidTitle(v) .. (v.cancelled and "  |cffff5555CANCELLED|r" or ""))
    local sub = ("%s · %s · %s"):format(date("%A %d %B", v.t), fmtTime(v.t), teamNames(v))
    if v.weekly then sub = sub .. grey(" · weekly") end
    if v.by then sub = sub .. grey(" · by " .. shortName(v.by)) end
    d.sub:SetText(sub)
    d.note:SetText(v.no or "")
    if groupsTab then
        refreshGroups(v)
        return
    end
    if assignTab then
        ns.StrategiesUI:RefreshRaid(v)
        return
    end

    local mine = RP():GetMySignup(v.id)
    local open = not v.cancelled and v.t >= Now() - 6 * 3600
    -- "lock": locked to its teams and invited players, and I'm not one; "level": the character's level is too low;
    -- "blacklist" / "declined": the organizers keep me out (of every raid / of this one)
    local block = RP():GetSignupBlock(v, myChar(v.id))
    local invited = block == nil
    local several = #RP():GetMyCharacters() > 1
    d.strip.charLabel:SetShown(several)
    upcoming.charDD:SetShown(several)
    if several and upcoming.charDD.Refresh then upcoming.charDD:Refresh() end
    -- the note takes the rest of the row, after the "As" picker or the spec
    upcoming.noteBox:ClearAllPoints()
    upcoming.noteBox:SetPoint("LEFT", several and upcoming.charDD or upcoming.specDD, "RIGHT", 10, 0)
    upcoming.noteBox:SetPoint("RIGHT", d.strip, "TOPRIGHT", -8, -45)
    local level = d.strip:GetFrameLevel()
    for st, b in pairs(upcoming.statusBtns) do
        b:SetEnabled(open and invited)
        -- my saved answer is the lit one (raised, so its coloured edge shows over the shared ones)
        b.chosen = (mine and mine.st == st) and true or false
        if b.chosen then b:SetTint(hexRGB(STATUS[st].color)) else b:SetTint(nil) end
        b:SetFrameLevel(level + (b.chosen and 2 or 1))
    end
    if upcoming.specDD.Refresh then upcoming.specDD:Refresh() end
    if not upcoming.noteBox:HasFocus() and not state.noteEdited then
        local note = state.pendingNote
        if note == nil then note = mine and mine.n or "" end
        upcoming.noteBox:SetText(note or "")
    end
    d.strip.closed:SetText(v.cancelled and "This raid was cancelled." or (not open and "Sign-ups are closed.")
        or (block == "blacklist" and colorize("ff5555", "You can't sign up for raids. Contact an officer."))
        or (block == "declined" and colorize("ff5555", "The raid leaders took you off this raid."))
        or (block == "level" and colorize("ff9933", ("This raid is for level %d characters."):format(v.ml)))
        or (not invited and colorize("ff9933", organizer and "Locked: you are not in this raid (Invite adds you)"
            or "Locked: ask a raid leader for an invite"))
        or (mine and (mine.rev or mine.at) and grey("Answered " .. shortDay(mine.rev or mine.at)))
        or (mine and "" or colorize("ff9933", "Pick an answer")))

    local c = counts(v.id)
    -- only what there is: "3/10 accepted · 1 guest · 1 tentative · 10 no response"; the bar fills up to the size
    local size = max(1, v.sz or 0)
    d.fill.bar:SetWidth(max(1, floor(d.fill:GetWidth() * min(1, c.A / size) + 0.5)))
    d.fill.bar:SetShown(c.A > 0)
    local parts = { colorize(STATUS.A.color, ("%d/%d accepted"):format(c.A, v.sz or 0)) }
    if c.guests > 0 then parts[#parts + 1] = c.guests .. (c.guests == 1 and " guest" or " guests") end
    if c.T > 0 then parts[#parts + 1] = c.T .. " tentative" end
    if c.B > 0 then parts[#parts + 1] = c.B .. " bench" end
    if c.X > 0 then parts[#parts + 1] = c.X .. " absent" end
    local nDeclined = 0
    for _ in pairs(RP():GetDeclined(v)) do nDeclined = nDeclined + 1 end
    if nDeclined > 0 then parts[#parts + 1] = colorize("ff5555", nDeclined .. " declined") end
    local missing = #noResponse(v, RP():GetSignups(v.id))
    if missing > 0 then parts[#parts + 1] = colorize("ff9933", missing .. " no response") end
    d.counts:SetText(tconcat(parts, " · "))
    d.roster:SetData(rosterRows(v))
end

function PlanUI:RefreshUpcoming()
    if not upcoming or not upcoming:IsVisible() then return end
    local rows = raidRows()
    local found = false
    for _, d in ipairs(rows) do
        if d.v and d.v.id == state.selected then found = true end
    end
    if not found then
        state.selected = defaultSelection(rows)
        state.pendingSpec, state.pendingNote, state.noteEdited, state.pendingChar = nil, nil, nil, nil
    end
    if upcoming.raidDD.Refresh then upcoming.raidDD:Refresh() end
    if upcoming.whenDD.Refresh then upcoming.whenDD:Refresh() end
    upcoming.list:SetEmptyText(filtered() and "No raids match the filters."
        or RP():CanOrganize() and "No raids planned yet.\nClick New raid to plan one."
        or "No raids planned yet.\nThe Guild Master and the raid leaders plan raids here.")
    upcoming.list:SetData(rows)
    refreshDetail(state.selected and RP():GetRaid(state.selected) or nil)
end

function PlanUI:SelectRaid(occId)
    if occId ~= state.selected then
        state.pendingSpec, state.pendingNote, state.noteEdited, state.pendingChar = nil, nil, nil, nil
        -- a raid opened from elsewhere (the Home tab, a link) must not be hidden by the list's filters
        local v = RP():GetRaid(occId)
        if v and filtered() and not passesFilter(v, Now(), weekStart(Now())) then
            state.filterRaid, state.filterWhen = "all", "all"
        end
    end
    state.selected = occId
    self:RefreshUpcoming()
end

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
        .. "an answer from anyone else is not counted."
    w.lowCB = UI():CreateCheckbox(c, ("Allow characters below level %d"):format(MAX_LEVEL),
        function() return w.f.low end, function(on) w.f.low = on end)
    w.lowCB:SetPoint("TOPLEFT", 80, -230)
    w.lowCB.tooltipText = ("Unticked, only level %d characters can sign up; the answer of a lower character is not "
        .. "counted. Tick it for a raid that lower characters may join too."):format(MAX_LEVEL)

    row(c, "Note", -268)
    w.noteBox = UI():CreateSleekEditBox(c)
    w.noteBox:SetSize(270, 20)
    w.noteBox:SetAutoFocus(false)
    w.noteBox:SetMaxLetters(120)
    w.noteBox:SetPoint("TOPLEFT", 86, -264)

    w.weeklyCB = UI():CreateCheckbox(c, "Repeat weekly (the next two weeks are always planned)", nil, nil)
    w.weeklyCB:SetPoint("TOPLEFT", 80, -292)
    w.weeklyInfo = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    w.weeklyInfo:SetPoint("TOPLEFT", 84, -298)
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
    if not RP():CanOrganize() then
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
    editor.weeklyInfo:SetShown(v ~= nil and v.weekly)
    editor.saveBtn:SetText(v and (v.weekly and "This week only" or "Save") or "Create raid")
    editor.saveAllBtn:SetShown(v ~= nil and v.weekly)
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
    row.remove:SetShown(d.guest or RP():CanOrganize())
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

local function canAddPlayers()
    return RP():CanOrganize() or RP():CanManageRoster()
end

-- Opens the Add players window of a raid: invites for raid planners, guests for roster managers.
function PlanUI:OpenInvites(occId)
    if not canAddPlayers() then
        Print("Only the Guild Master, officers, the guild council and the raid leaders can add players to a raid.")
        return false
    end
    if not RP():GetRaid(occId) then return false end
    if not inviteWin then createInvites() end
    inviteWin.occ = occId
    inviteWin.err:SetText("")
    inviteWin.mode = RP():CanOrganize() and "member" or "guest"
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
    if not v or not canAddPlayers() then
        inviteWin:Hide()
        return
    end
    local planner, manager = RP():CanOrganize(), RP():CanManageRoster()
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

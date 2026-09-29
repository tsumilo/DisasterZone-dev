-- CDLoot: UI/RaidPlanUI.lua
-- Raid planning views of the Raids tab (Addendum J §58): "Upcoming" (the raid list, a raid's sign-up strip and
-- roster) and "Teams" (team lists), plus the New / Edit raid window. RaidsTab owns the tab and its toolbar and
-- creates these views inside its panel.
local addonName, ns = ...

local PlanUI = ns:NewModule("RaidPlanUI")

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tsort, tconcat = table.sort, table.concat

local DAY = 86400
local LIST_W = 290
local RAID_ROW_H = 36
local HEADER_ROW_H = 22
local CELL_H = 16
local EDITOR_DAYS = 60

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

local state = { selected = nil, team = nil, draft = nil, pendingSpec = nil, pendingNote = nil, detailTab = "signups" }
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

local function raidTitle(v)
    return ("%s (%d)"):format(RP():GetRaidName(v), v.sz or 0)
end

local function teamNames(v)
    if not v.tm or #v.tm == 0 then return "Everyone" end
    local names = {}
    for _, id in ipairs(v.tm) do
        local t = RP():GetTeam(id)
        if t then names[#names + 1] = t.name end
    end
    return #names > 0 and tconcat(names, ", ") or "Everyone"
end

-- Monday 00:00 of the week of `t`.
local function weekStart(t)
    local d = date("*t", t)
    local sinceMonday = (d.wday + 5) % 7
    d.day, d.hour, d.min, d.sec, d.isdst = d.day - sinceMonday, 0, 0, 0, nil
    return time(d)
end

local function hideTooltip() GameTooltip:Hide() end

local function counts(occId)
    local c = { A = 0, T = 0, B = 0, X = 0 }
    for _, s in pairs(RP():GetSignups(occId)) do c[s.st] = (c[s.st] or 0) + 1 end
    return c
end

local function Print(...) ns:Print(...) end

---------------------------------------------------------------------------
-- Upcoming: raid list (left)
---------------------------------------------------------------------------

local function myStatusText(v)
    local mine = RP():GetMySignup(v.id)
    if mine then return colorize(STATUS[mine.st].color, STATUS[mine.st].label), STATUS[mine.st].color end
    local inv = RP():GetInvited(v)
    local me = ns.Util.PlayerKey()
    if inv and me and inv[me] then return colorize("ff9933", "not answered"), "ff9933" end
    return grey("not answered"), nil
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
        row.l2 = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.l2:SetPoint("TOPLEFT", 8, -20)
        row.l2:SetPoint("RIGHT", -4, 0)
        row.l2:SetJustifyH("LEFT")
        row.l2:SetWordWrap(false)
        row.head = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.head:SetPoint("BOTTOMLEFT", 4, 3)
        row:SetScript("OnClick", function(self)
            local data = self.__cdlData
            if data and data.v then PlanUI:SelectRaid(data.v.id) end
        end)
    end
    local header = d.header ~= nil
    row.head:SetShown(header)
    row.l1:SetShown(not header)
    row.l2:SetShown(not header)
    row.accent:SetShown(not header)
    row:EnableMouse(not header)
    if header then
        row.head:SetText(d.header)
        row.sel:Hide()
        return
    end
    local v = d.v
    row.sel:SetShown(v.id == state.selected)
    local when = fmtDay(v.t) .. "  " .. fmtTime(v.t)
    local name = raidTitle(v)
    if v.cancelled then
        row.l1:SetText(grey(when .. "  " .. name .. "  (cancelled)"))
    else
        row.l1:SetText(when .. "  |cffffd100" .. name .. "|r")
    end
    local c = counts(v.id)
    local status, hex = myStatusText(v)
    row.l2:SetText(("%s%s · %d accepted · you: %s"):format(v.weekly and "Weekly · " or "", teamNames(v), c.A, status))
    if hex and not v.cancelled then
        row.accent:SetColorTexture(tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255,
            tonumber(hex:sub(5, 6), 16) / 255, 0.9)
    else
        row.accent:SetColorTexture(0.4, 0.4, 0.4, 0.5)
    end
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
        buckets[b][#buckets[b] + 1] = v
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
    if s then
        GameTooltip:AddLine(STATUS[s.st].label, 0.8, 0.8, 0.8)
        if s.n then GameTooltip:AddLine('"' .. s.n .. '"', 1, 0.82, 0, true) end
        for _, line in ipairs(signupLines(s, d.order, d.total)) do GameTooltip:AddLine(line, 0.7, 0.7, 0.7) end
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

local function initRosterRow(row, d)
    if not row.cdlInit then
        row.cdlInit = true
        row.cells = {}
        for i = 1, #ROLE_COLS do
            local cell = CreateFrame("Button", nil, row)
            cell:SetHeight(CELL_H)
            cell.fs = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            cell.fs:SetPoint("LEFT", 2, 0)
            cell.fs:SetPoint("RIGHT", -2, 0)
            cell.fs:SetJustifyH("LEFT")
            cell.fs:SetWordWrap(false)
            cell:SetScript("OnEnter", cellTooltip)
            cell:SetScript("OnLeave", hideTooltip)
            row.cells[i] = cell
        end
        row.line = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.line:SetPoint("TOPLEFT", 4, -2)
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
        if type(c) == "string" then
            cell.fs:SetText(c)
            cell:Show()
        elseif type(c) == "table" then
            local icon = ICON[c.s.st] or ""
            local spec = ns.RaidComp:SpecIcon(c.s.c, c.s.sp)
            local text = icon .. (spec and (" |T" .. spec .. ":12:12:0:0:64:64:5:59:5:59|t") or "") .. " "
                .. colored(c.key, classOf(c.key, c.s))
            if c.s.n then text = text .. grey(" *") end
            cell.fs:SetText(text)
            cell.fs:SetAlpha(c.s.st == "T" and 0.7 or 1)
            cell:Show()
        else
            cell:Hide()
        end
    end
    row.line:SetShown(d.line ~= nil)
    row.line:SetText(d.line or "")
end

local function rosterExtent(d)
    if d.line then return 16 * max(1, ceil(#(d.plain or "") / 75)) + 4 end
    if d.header then return 20 end
    return CELL_H
end

local function nameList(keys, signups)
    local parts, plain = {}, {}
    for _, key in ipairs(keys) do
        local s = signups and signups[key]
        local text = colored(key, classOf(key, s))
        if s and s.n then text = text .. grey(" (" .. s.n .. ")") end
        parts[#parts + 1] = text
        plain[#plain + 1] = shortName(key) .. (s and s.n and (" (" .. s.n .. ")") or "")
    end
    return tconcat(parts, ", "), tconcat(plain, ", ")
end

-- Rows: a header row per role column, then one row per rank (the i-th tank, healer, ... side by side), then
-- full-width lines for Bench, Absent, spec not set and No response.
local function rosterRows(v)
    local signups = RP():GetSignups(v.id)
    local order, total = RP():GetSignupOrder(v.id)
    local function cell(key) return { key = key, s = signups[key], order = order[key], total = total } end
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
        header.cols[i] = ("|cffffd100%s|r %d"):format(col.label, accepted)
            .. (#list > accepted and grey(" +" .. (#list - accepted)) or "")
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
    local function line(label, keys)
        if #keys == 0 then return end
        tsort(keys, nameLess)
        local text, plain = nameList(keys, signups)
        rows[#rows + 1] = { line = label .. " (" .. #keys .. "): " .. text, plain = label .. plain }
    end
    -- answered players outside the role columns: a header line, then their names as cells (hover shows the order)
    local function cells(label, keys)
        if #keys == 0 then return end
        tsort(keys, function(a, b) return (order[a] or 0) < (order[b] or 0) end)
        rows[#rows + 1] = { line = label .. " (" .. #keys .. ")", plain = label }
        for i = 1, #keys, #ROLE_COLS do
            local d = { cols = {} }
            for j = 1, #ROLE_COLS do
                if keys[i + j - 1] then d.cols[j] = cell(keys[i + j - 1]) end
            end
            rows[#rows + 1] = d
        end
    end
    cells(colorize(STATUS.T.color, "Spec not set"), other.nospec)
    cells(colorize(STATUS.B.color, "Bench"), other.B)
    cells(colorize(STATUS.X.color, "Absent"), other.X)
    local inv = RP():GetInvited(v)
    if inv then
        local missing = {}
        for key in pairs(inv) do
            if not signups[key] then missing[#missing + 1] = key end
        end
        line(colorize("ff9933", "No response"), missing)
    end
    return rows
end

---------------------------------------------------------------------------
-- Upcoming: detail (right)
---------------------------------------------------------------------------

local function mySpecOptions()
    local _, classFile = UnitClass("player")
    local out = {}
    for i, spec in ipairs(ns.SPECS[classFile] or {}) do
        out[#out + 1] = { value = i, text = spec.label }
    end
    return out
end

-- The spec shown in my dropdown: my sign-up's, a pick not sent yet, the one I used last, my BiS list's.
local function mySpec(occId)
    local mine = occId and RP():GetMySignup(occId)
    if state.pendingSpec then return state.pendingSpec end
    if mine and mine.sp then return mine.sp end
    local last = RP():GetLastSpec()
    if last then return last end
    local BiS = ns.BiS
    local label = BiS and BiS.GetSpec and BiS:GetSpec() or ""
    local _, classFile = UnitClass("player")
    for i, spec in ipairs(ns.SPECS[classFile] or {}) do
        if spec.label == label then return i end
    end
    return nil
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
    local ok, err = RP():SignUp(occ, status, mySpec(occ), note)
    if not ok then
        Print(err or "Could not save your answer.")
        return false
    end
    state.pendingSpec, state.pendingNote, state.noteEdited = nil, nil, nil
    return true
end

local function setSpec(i)
    local occ = state.selected
    local mine = occ and RP():GetMySignup(occ)
    if mine then
        local ok, err = RP():SignUp(occ, mine.st, i)
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
            local ok, err = RP():SignUp(occ, mine.st, nil, text ~= "" and text or false)
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
end

-- The trash button: confirm, then delete (a weekly raid asks first: this week, or the whole weekly raid).
function PlanUI:ConfirmDelete(scope)
    local v = state.selected and RP():GetRaid(state.selected)
    if not v then return end
    local what
    if scope == "series" then
        what = ("the weekly raid %s and every week of it"):format(raidTitle(v))
    else
        what = ("%s on %s"):format(raidTitle(v), date("%a %d %b %H:%M", v.t))
    end
    StaticPopup_Show("CDLOOT_PLAN_DELETE", what, nil, { fn = function()
        local ok, err = RP():DeleteRaid(v.id, scope)
        if not ok then Print(err or "Could not delete the raid.") end
    end })
end

local function deleteClick(btn)
    local v = state.selected and RP():GetRaid(state.selected)
    if not v then return end
    if not v.weekly then return PlanUI:ConfirmDelete(nil) end
    UI():ContextMenu(btn, function(root)
        root:CreateTitle("Delete")
        root:CreateButton("This week's raid only", function() PlanUI:ConfirmDelete(nil) end)
        root:CreateButton("The whole weekly raid", function() PlanUI:ConfirmDelete("series") end)
    end)
end

function PlanUI:Confirm(text, fn)
    StaticPopup_Show("CDLOOT_PLAN_CONFIRM", text, nil, { fn = fn })
end

---------------------------------------------------------------------------
-- Upcoming: Groups tab (§60): the raid's group layout in the group grid, Invite & sort and Re-sort
---------------------------------------------------------------------------

local STATUS_EXTRA = { T = "Signed up as Tentative", B = "Signed up as Bench" }

local function leadsGroup()
    if not IsInGroup() then return false end
    return (UnitIsGroupLeader("player") or (IsInRaid() and UnitIsGroupAssistant("player"))) and true or false
end

-- Moves key to group g (nil = out of the groups) in a layout; dropped onto `target` in group g = swap. isMember(k)
-- tells which layout entries still count. Returns ok (false: the group is full).
local function moveInLayout(grp, isMember, key, g, target)
    local old = grp[key]
    if g == nil then
        grp[key] = nil
        return true
    end
    if target and target ~= key and grp[target] == g then
        grp[key], grp[target] = g, old
        return true
    end
    if old == g then return true end
    local n = 0
    for k, x in pairs(grp) do
        if x == g and k ~= key and isMember(k) then n = n + 1 end
    end
    if n >= ns.RaidComp.GROUP_SIZE then
        Print("Group %d is full. Drop onto a player there to swap places.", g)
        return false
    end
    grp[key] = g
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
    local grp, saved = RP():GetLayout(v)
    state.raidDraft = { occ = v.id, grp = grp, saved = saved, dirty = false }
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
                          extra = m.st and STATUS_EXTRA[m.st] or (m.st == nil and "No sign-up" or nil),
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

function PlanUI:MoveRaidMember(key, g, target)
    local v = selectedRaid()
    if not v or not RP():CanEditGroups() then return false end
    local dr = raidDraft(v)
    local valid = {}
    for _, m in ipairs(raidMembers()) do valid[m.key] = true end
    if not valid[key] then return false end
    local ok = moveInLayout(dr.grp, function(k) return valid[k] end, key, g, target)
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
    dr.grp, dr.dirty = ns.RaidComp:AutoFill(accepted, v.sz), true
    self:RefreshUpcoming()
end

-- Back to the starting layout (the teams' layouts adjusted to who accepted).
function PlanUI:ResetRaidLayout()
    local v = selectedRaid()
    if not v or not RP():CanEditGroups() then return end
    local dr = raidDraft(v)
    dr.grp, dr.dirty = RP():BuildLayout(v), true
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
    local ok, err = RP():SetGroups(v.id, dr.grp)
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
    local ok, err = ns.RaidInvite:Start(v.id, dr.grp, raidTitle(v))
    if not ok then Print(err or "Could not invite.") end
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
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(title)
        GameTooltip:AddLine(text, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", hideTooltip)
end

local function createRaidGroups(d)
    local g = CreateFrame("Frame", nil, d)
    g:SetPoint("TOPLEFT", 0, -58)
    g:SetPoint("BOTTOMRIGHT", 0, 0)
    d.groups = g

    g.autoBtn = UI():CreateButton(g, "Auto-fill", 70, 22, function() PlanUI:AutoFillRaid() end)
    g.autoBtn:SetPoint("TOPLEFT", 0, 0)
    tipButton(g.autoBtn, "Auto-fill", "A fresh layout of everyone who accepted: tanks, melee groups with a shaman each, "
        .. "casters, healers.")
    g.teamBtn = UI():CreateButton(g, "From team", 80, 22, function() PlanUI:ResetRaidLayout() end)
    g.teamBtn:SetPoint("LEFT", g.autoBtn, "RIGHT", 3, 0)
    tipButton(g.teamBtn, "From team", "Start again from the team's group layout: players keep their team seat, others "
        .. "who accepted fill the seats of team members who didn't.")
    g.undoBtn = UI():CreateButton(g, "Undo", 50, 22, function() PlanUI:UndoRaidLayout() end)
    g.undoBtn:SetPoint("LEFT", g.teamBtn, "RIGHT", 3, 0)
    g.saveBtn = UI():CreateButton(g, "Save", 56, 22, function() PlanUI:SaveRaidLayout() end)
    g.saveBtn:SetPoint("LEFT", g.undoBtn, "RIGHT", 3, 0)

    g.resortBtn = UI():CreateButton(g, "Re-sort", 68, 22, function() PlanUI:ResortRaid() end)
    g.resortBtn:SetPoint("TOPRIGHT", -2, 0)
    tipButton(g.resortBtn, "Re-sort groups", "Moves everyone in your raid to their planned group now, e.g. after late "
        .. "joiners or a change of plan. Players who aren't planned go to groups 6-8.")
    g.inviteBtn = UI():CreateButton(g, "Invite & sort", 100, 22, function() PlanUI:InviteRaid() end)
    g.inviteBtn:SetPoint("RIGHT", g.resortBtn, "LEFT", -4, 0)
    tipButton(g.inviteBtn, "Invite & sort", "Invites everyone placed in a group who is online, makes the group a raid "
        .. "and moves each player into their group as they join. Players who join later are sorted too, until the "
        .. "raid ends. Needs the raid leader or an assistant.")

    g.status = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    g.status:SetPoint("TOPLEFT", 2, -28)
    g.status:SetPoint("RIGHT", -64, 0)
    g.status:SetJustifyH("LEFT")
    g.status:SetWordWrap(false)
    g.stopBtn = UI():CreateButton(g, "Stop", 56, 20, function()
        ns.RaidInvite:Stop()
        PlanUI:RefreshUpcoming()
    end)
    g.stopBtn:SetPoint("TOPRIGHT", -2, -24)

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
        isEditable = function() return RP():CanEditGroups() end,
        onDrop = function(key, grp, target)
            PlanUI:MoveRaidMember(key, grp, target)
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

    u.list = UI():CreateScrollList(u, RAID_ROW_H, initRaidRow, function(d) return d.header and HEADER_ROW_H or RAID_ROW_H end)
    u.list.frame:SetPoint("TOPLEFT", 0, 0)
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

    d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d.title:SetPoint("TOPLEFT", 2, -2)
    d.title:SetPoint("RIGHT", -230, 0)
    d.title:SetJustifyH("LEFT")
    d.title:SetWordWrap(false)
    d.sub = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.sub:SetPoint("TOPLEFT", 2, -24)
    d.sub:SetPoint("RIGHT", -4, 0)
    d.sub:SetJustifyH("LEFT")
    d.sub:SetWordWrap(false)
    d.note = d:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    d.note:SetPoint("TOPLEFT", 2, -40)
    d.note:SetPoint("RIGHT", -176, 0)

    -- Sign-ups / Groups tabs
    local function tab(label, key)
        local b = UI():CreateButton(d, label, 80, 20, function()
            state.detailTab = key
            PlanUI:RefreshUpcoming()
        end)
        b.key = key
        return b
    end
    d.tabGroups = tab("Groups", "groups")
    d.tabGroups:SetPoint("TOPRIGHT", -2, -34)
    d.tabSignups = tab("Sign-ups", "signups")
    d.tabSignups:SetPoint("RIGHT", d.tabGroups, "LEFT", -4, 0)
    d.note:SetJustifyH("LEFT")
    d.note:SetWordWrap(false)

    -- Organizer actions (top right)
    d.cancelBtn = UI():CreateMenuButton(d, "Cancel...", 100, cancelMenu)
    d.cancelBtn:SetPoint("TOPRIGHT", -2, 0)
    d.editBtn = UI():CreateButton(d, "Edit", 60, 22, function()
        if state.selected then PlanUI:OpenEditor(state.selected) end
    end)
    d.editBtn:SetPoint("RIGHT", d.cancelBtn, "LEFT", -4, 0)
    d.deleteBtn = CreateFrame("Button", nil, d)
    d.deleteBtn:SetSize(22, 22)
    d.deleteBtn:SetPoint("RIGHT", d.editBtn, "LEFT", -6, 0)
    d.deleteBtn:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    d.deleteBtn:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")
    d.deleteBtn:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight", "ADD")
    d.deleteBtn:SetScript("OnClick", deleteClick)
    d.deleteBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Delete raid", 1, 0.3, 0.3)
        GameTooltip:AddLine("Removes the raid for everyone, with its sign-ups and groups. To keep it listed as called "
            .. "off, use Cancel... instead.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    d.deleteBtn:SetScript("OnLeave", hideTooltip)

    -- Sign-up strip
    local strip = CreateFrame("Frame", nil, d, "BackdropTemplate")
    strip:SetPoint("TOPLEFT", 0, -58)
    strip:SetPoint("RIGHT", 0, 0)
    strip:SetHeight(58)
    if strip.SetBackdrop then
        strip:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        strip:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
        strip:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)
    end
    d.strip = strip
    strip.label = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    strip.label:SetPoint("TOPLEFT", 8, -7)
    strip.label:SetText("Your answer")
    u.statusBtns = {}
    local prev
    for _, st in ipairs(STATUS_ORDER) do
        local b = UI():CreateButton(strip, STATUS[st].button, 78, 22, function() PlanUI:Answer(st) end)
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 3, 0) else b:SetPoint("TOPLEFT", 8, -26) end
        b.st = st
        u.statusBtns[st] = b
        prev = b
    end
    u.specDD = UI():CreateDropdown(strip, 118, mySpecOptions, function() return mySpec(state.selected) end, setSpec)
    u.specDD:SetPoint("LEFT", prev, "RIGHT", 8, 0)
    u.noteBox = CreateFrame("EditBox", nil, strip, "InputBoxTemplate")
    u.noteBox:SetSize(110, 20)
    u.noteBox:SetAutoFocus(false)
    u.noteBox:SetMaxLetters(40)
    u.noteBox:SetPoint("TOPRIGHT", -10, -5)
    u.noteBox:SetScript("OnEnterPressed", saveNote)
    u.noteBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- A typed note is kept through repaints (a spec pick repaints) until it is saved or another raid is picked.
    u.noteBox:SetScript("OnTextChanged", function(_, userInput) if userInput then state.noteEdited = true end end)
    u.noteBox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Note")
        GameTooltip:AddLine("A short note for the organizers, e.g. \"late 20 min\". Press Enter to save.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    u.noteBox:SetScript("OnLeave", hideTooltip)
    strip.noteLabel = strip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    strip.noteLabel:SetPoint("RIGHT", u.noteBox, "LEFT", -8, 0)
    strip.noteLabel:SetText("Note")
    strip.closed = strip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    strip.closed:SetPoint("TOPLEFT", 90, -7)

    d.counts = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.counts:SetPoint("TOPLEFT", 2, -122)
    d.counts:SetPoint("RIGHT", -4, 0)
    d.counts:SetJustifyH("LEFT")

    d.roster = UI():CreateScrollList(d, CELL_H, initRosterRow, rosterExtent)
    d.roster.frame:SetPoint("TOPLEFT", 0, -140)
    d.roster.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    d.roster:SetEmptyText("")

    createRaidGroups(d)
    return u
end

local function refreshDetail(v)
    local d = upcoming.detail
    local has = v ~= nil
    local groupsTab = state.detailTab == "groups"
    for _, region in ipairs({ d.title, d.sub, d.note, d.tabSignups, d.tabGroups }) do region:SetShown(has) end
    for _, region in ipairs({ d.strip, d.counts, d.roster.frame }) do region:SetShown(has and not groupsTab) end
    d.groups:SetShown(has and groupsTab)
    d.tabSignups:SetEnabled(groupsTab)
    d.tabGroups:SetEnabled(not groupsTab)
    d.empty:SetShown(not has)
    local organizer = RP():CanOrganize()
    d.editBtn:SetShown(has and organizer)
    d.cancelBtn:SetShown(has and organizer)
    d.deleteBtn:SetShown(has and organizer)
    if not has then return end

    d.title:SetText(raidTitle(v) .. (v.cancelled and "  |cffff5555CANCELLED|r" or ""))
    local sub = ("%s · %s · %s"):format(date("%A %d %B", v.t), fmtTime(v.t), teamNames(v))
    if v.weekly then sub = sub .. grey("  ·  weekly") end
    if v.by then sub = sub .. grey("  ·  by " .. shortName(v.by)) end
    d.sub:SetText(sub)
    d.note:SetText(v.no or "")
    if groupsTab then
        refreshGroups(v)
        return
    end

    local mine = RP():GetMySignup(v.id)
    local open = not v.cancelled and v.t >= Now() - 6 * 3600
    for st, b in pairs(upcoming.statusBtns) do
        b:SetEnabled(open)
        local chosen = mine and mine.st == st
        b:SetText(chosen and colorize(STATUS[st].color, STATUS[st].button) or STATUS[st].button)
        if chosen then b:LockHighlight() else b:UnlockHighlight() end
    end
    if upcoming.specDD.Refresh then upcoming.specDD:Refresh() end
    if not upcoming.noteBox:HasFocus() and not state.noteEdited then
        local note = state.pendingNote
        if note == nil then note = mine and mine.n or "" end
        upcoming.noteBox:SetText(note or "")
    end
    d.strip.closed:SetText(v.cancelled and "This raid was cancelled." or (not open and "Sign-ups are closed.")
        or (mine and grey("Saved: " .. STATUS[mine.st].label) or colorize("ff9933", "Pick an answer")))

    local c = counts(v.id)
    local inv = RP():GetInvited(v)
    local parts = {
        colorize(STATUS.A.color, c.A .. " accepted"), c.T .. " tentative", c.B .. " bench", c.X .. " absent",
    }
    if inv then
        local signups = RP():GetSignups(v.id)
        local missing = 0
        for key in pairs(inv) do if not signups[key] then missing = missing + 1 end end
        parts[#parts + 1] = colorize("ff9933", missing .. " no response")
    end
    d.counts:SetText(tconcat(parts, " · ") .. grey(("   (%d-player raid)"):format(v.sz or 0)))
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
        state.pendingSpec, state.pendingNote, state.noteEdited = nil, nil, nil
    end
    upcoming.list:SetEmptyText(RP():CanOrganize() and "No raids planned yet.\nClick New raid to plan one."
        or "No raids planned yet.\nThe Guild Master and the raid leaders plan raids here.")
    upcoming.list:SetData(rows)
    refreshDetail(state.selected and RP():GetRaid(state.selected) or nil)
end

function PlanUI:SelectRaid(occId)
    if occId ~= state.selected then state.pendingSpec, state.pendingNote, state.noteEdited = nil, nil, nil end
    state.selected = occId
    self:RefreshUpcoming()
end

function PlanUI:GetSelectedRaid() return state.selected end

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
        row.l1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.l1:SetPoint("LEFT", 8, 0)
        row.l1:SetJustifyH("LEFT")
        row.l2 = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.l2:SetPoint("RIGHT", -6, 0)
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
    return not (sameMap(dr.members, set) and dr.sz == t.size and sameMap(dr.s, t.specs) and sameMap(dr.grp, t.groups))
end

local function loadDraft(id)
    local t = id and RP():GetTeam(id)
    local members = {}
    if t then for _, key in ipairs(t.members) do members[key] = true end end
    state.draft = {
        id = t and t.id or nil, name = t and t.name or "New team", members = members, sz = t and t.size or 25,
        s = t and t.specs or {}, grp = t and t.groups or {},
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
        dr.members[key], dr.s[key], dr.grp[key] = nil, nil, nil
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
        if g > n then dr.grp[key] = nil end
    end
    self:RefreshTeams()
end

-- The grid's drop: move `key` to group g (nil = out of the groups); dropped onto `target` in a group = swap.
function PlanUI:MoveDraftMember(key, g, target)
    local dr = state.draft
    if not dr or not dr.members[key] or not RP():CanManageTeams() then return false end
    return moveInLayout(dr.grp, function(k) return dr.members[k] end, key, g, target)
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
    dr.grp = ns.RaidComp:AutoFill(draftMembers(), dr.sz)
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
        { size = dr.sz, specs = dr.s, groups = dr.grp })
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

-- Upcoming raids that invite a team: "Tue Karazhan, Thu Gruul's Lair".
local function teamRaids(id)
    local out = {}
    for _, v in ipairs(RP():GetRaids(Now() - 6 * 3600)) do
        if not v.cancelled then
            for _, tid in ipairs(v.tm or {}) do
                if tid == id then out[#out + 1] = date("%a", v.t) .. " " .. RP():GetRaidName(v) break end
            end
        end
    end
    return out
end

function PlanUI:CreateTeams(parent)
    local t = CreateFrame("Frame", nil, parent)
    teamsView = t

    t.list = UI():CreateScrollList(t, 26, initTeamRow)
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

    -- Row 1: name, Undo / Save / Delete
    d.nameLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    d.nameLabel:SetPoint("TOPLEFT", 2, -6)
    d.nameLabel:SetText("Name")
    t.nameBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    t.nameBox:SetSize(150, 20)
    t.nameBox:SetAutoFocus(false)
    t.nameBox:SetMaxLetters(32)
    t.nameBox:SetPoint("TOPLEFT", 44, -2)
    t.nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    t.nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    t.nameBox:SetScript("OnTextChanged", function() PlanUI:RefreshTeamButtons() end)
    d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d.title:SetPoint("TOPLEFT", 2, -2)

    d.deleteBtn = UI():CreateButton(d, "Delete", 64, 22, function()
        local team = state.team and RP():GetTeam(state.team)
        if not team then return end
        PlanUI:Confirm(("Delete the team %s?"):format(team.name), function()
            local ok, err = RP():DeleteTeam(team.id)
            if not ok then Print(err or "Could not delete the team.") end
            state.team, state.draft, state.newTeam = nil, nil, nil
            PlanUI:RefreshTeams()
        end)
    end)
    d.deleteBtn:SetPoint("TOPRIGHT", -2, 0)
    d.saveBtn = UI():CreateButton(d, "Save", 64, 22, function() PlanUI:SaveTeam() end)
    d.saveBtn:SetPoint("RIGHT", d.deleteBtn, "LEFT", -4, 0)
    d.revertBtn = UI():CreateButton(d, "Undo", 56, 22, function() PlanUI:SelectTeam(state.team) end)
    d.revertBtn:SetPoint("RIGHT", d.saveBtn, "LEFT", -4, 0)

    -- Row 2: add members, size, Auto-fill
    t.picker = UI():CreateSearchDropdown(d, 210, {
        placeholder = "Add guild members...",
        emptyText = "No matching guild members.",
        getItems = pickerItems,
        isChecked = function(key) return state.draft and state.draft.members[key] and true or false end,
        onToggle = function(key) PlanUI:ToggleDraftMember(key) end,
    })
    t.picker.frame:SetPoint("TOPLEFT", 0, -28)
    t.sizeDD = UI():CreateDropdown(d, 86, function()
        return { { value = 10, text = "10-man" }, { value = 25, text = "25-man" } }
    end, function() return state.draft and state.draft.sz or 25 end, function(v) PlanUI:SetDraftSize(v) end)
    t.sizeDD:SetPoint("TOPLEFT", 218, -28)
    d.autoBtn = UI():CreateButton(d, "Auto-fill", 76, 22, function() PlanUI:AutoFillDraft() end)
    d.autoBtn:SetPoint("TOPLEFT", 310, -28)
    d.autoBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Auto-fill groups")
        GameTooltip:AddLine("A starting layout: tanks, melee groups with a shaman each, casters, healers. "
            .. "Adjust it by dragging, then Save.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    d.autoBtn:SetScript("OnLeave", hideTooltip)

    d.info = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.info:SetPoint("TOPLEFT", 2, -54)
    d.info:SetPoint("RIGHT", -4, 0)
    d.info:SetJustifyH("LEFT")
    d.info:SetWordWrap(false)

    t.grid = ns.RaidGroupsUI:CreateGrid(d, {
        getSize = function() return state.draft and state.draft.sz or 25 end,
        getMembers = draftMembers,
        getGroups = function() return state.draft and state.draft.grp or {} end,
        isEditable = function() return RP():CanManageTeams() end,
        onDrop = function(key, g, target)
            PlanUI:MoveDraftMember(key, g, target)
            PlanUI:RequestRefresh()
        end,
        onSwapGroups = function(a, b) PlanUI:SwapDraftGroups(a, b) end,
        onMenu = memberMenu,
        poolLabel = "Not in a group",
    })
    t.grid.frame:SetPoint("TOPLEFT", 0, -68)
    t.grid.frame:SetPoint("BOTTOMRIGHT", 0, 0)
    return t
end

function PlanUI:RefreshTeamButtons()
    if not teamsView then return end
    local d = teamsView.detail
    local organizer = RP():CanManageTeams()
    local has = state.draft ~= nil and (state.team ~= nil or state.newTeam)
    local dirty = organizer and draftDirty()
    d.saveBtn:SetShown(organizer and has)
    d.saveBtn:SetEnabled(dirty and true or false)
    d.revertBtn:SetShown(organizer and has and state.draft.id ~= nil)
    d.revertBtn:SetEnabled(dirty and true or false)
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
    d.nameLabel:SetShown(has and organizer)
    d.title:SetShown(has and not organizer)
    teamsView.picker.frame:SetShown(has and organizer)
    teamsView.sizeDD:SetShown(has and organizer)
    d.autoBtn:SetShown(has and organizer)
    d.deleteBtn:SetShown(has and organizer and dr.id ~= nil)
    d.info:SetShown(has)
    teamsView.grid.frame:SetShown(has)
    d.empty:SetShown(not has)
    d.empty:SetText(organizer and "Make a team with New team, then pick it when you plan a raid."
        or "Teams are made by the Guild Master and the guild council.")
    self:RefreshTeamButtons()
    if not has then return end
    d.title:SetText(dr.name .. grey(("  %d-man"):format(dr.sz or 25)))
    if teamsView.sizeDD.Refresh then teamsView.sizeDD:Refresh() end
    local n = 0
    for _ in pairs(dr.members) do n = n + 1 end
    local raids = dr.id and teamRaids(dr.id) or {}
    d.info:SetText(("%d members"):format(n)
        .. (#raids > 0 and ("  ·  invited to: " .. tconcat(raids, ", ")) or "")
        .. (organizer and draftDirty() and colorize("ff9933", "   (not saved)") or ""))
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

local function editorFields()
    local f = editor.f
    local tm = {}
    for _, t in ipairs(RP():GetTeams()) do
        if f.tm[t.id] then tm[#tm + 1] = t.id end
    end
    return {
        i = f.i, sz = f.sz, t = editorTime(), tm = tm,
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
    return out
end

local function editorSave(scope)
    local fields = editorFields()
    local ok, res
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
    local w = UI():CreateWindow("CDLootRaidEditor", "New raid", 400, 356)
    editor = w
    local c = w.content
    w.f = { tm = {} }

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
    w.titleBox = CreateFrame("EditBox", nil, c, "InputBoxTemplate")
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

    row(c, "Note", -174)
    w.noteBox = CreateFrame("EditBox", nil, c, "InputBoxTemplate")
    w.noteBox:SetSize(270, 20)
    w.noteBox:SetAutoFocus(false)
    w.noteBox:SetMaxLetters(120)
    w.noteBox:SetPoint("TOPLEFT", 86, -170)

    w.weeklyCB = UI():CreateCheckbox(c, "Repeat weekly (the next two weeks are always planned)", nil, nil)
    w.weeklyCB:SetPoint("TOPLEFT", 80, -198)
    w.weeklyInfo = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    w.weeklyInfo:SetPoint("TOPLEFT", 84, -204)
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
    local f = { tm = {} }
    if v then
        local d = date("*t", v.t)
        f.i, f.sz, f.hour, f.min = v.i, v.sz, d.hour, d.min - d.min % 15
        f.y, f.m, f.d = d.year, d.month, d.day
        for _, id in ipairs(v.tm or {}) do f.tm[id] = true end
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
    for _, dd in ipairs({ editor.instDD, editor.sizeDD, editor.datePicker, editor.hourDD, editor.minDD, editor.teamDD }) do
        if dd.Refresh then dd:Refresh() end
    end
    editor:Show()
    editor:Raise()
end

function PlanUI:GetEditor() return editor end

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
    Print("%d raid%s to answer: %s. Type /cdl raids to sign up.", #list, #list == 1 and "" or "s", tconcat(parts, ", "))
end

function PlanUI:OnInit()
    for _, msg in ipairs({ "RAIDPLAN_CHANGED", "ROSTER_UPDATED", "CONFIG_UPDATED", "RAIDINVITE_CHANGED" }) do
        ns:On(msg, function() PlanUI:RequestRefresh() end)
    end
    if StaticPopupDialogs then
        StaticPopupDialogs["CDLOOT_PLAN_DELETE"] = {
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
        StaticPopupDialogs["CDLOOT_PLAN_CONFIRM"] = {
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

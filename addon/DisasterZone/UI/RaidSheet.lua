if DisasterZoneBoot and DisasterZoneBoot.Run("UI/RaidSheet.lua", ...) then return end -- DisasterZone: UI/RaidSheet.lua
-- New raid / Edit raid (1.3.2 makeover, user requests 2026-10-06): a sheet over the Raids tab, like the Dungeons tab's
-- List a run, instead of a separate window. Top to bottom, one label column:
--   the raids as loading-screen tiles: several can be picked, the order they are clicked in is the night's order
--     (Gruul, then Magtheridon); the size follows them (the larger one: Karazhan + Gruul is a 25; "Other" is a 25), an
--     edited raid keeps its own until its raids change
--   When: a week of day cells (a dot on days with a raid), arrows a week back / on, a month tile that opens the
--     calendar for later days; the time as a stepper (15 minutes a step, the mouse wheel too); Every week (new raids)
--   Who: a card per team (per lineup of the raid's size when it has several) with how many it invites, the search
--     for players outside the teams, and the players invited as pills (x takes one off)
--   Sign-ups: Everyone | Teams + invited | Private; Level 70 only beside it
--   Details: Title and Note side by side
--   the preview (the card as the Upcoming board draws it, without the answer buttons), then who can sign up in one
--   line, Cancel and Create raid (a weekly raid being edited: This week only / Every week).
-- What is saved, who may save it and the weekly rules are RaidPlan's, as before.
local addonName, ns = ...

local PlanUI = ns.RaidPlanUI       -- (UI/RaidPlanUI.lua's module: this file adds OpenEditor / GetEditor to it)

local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local PAD = 10                      -- (the Raids pages' grid: PAD 10 at the sides, 790 wide)
local TILE_H, TILE_GAP, TILE_COLS = 46, 6, 5
local LABEL_W = 70
local ROW_GAP = 12
local DAY_W, DAY_H, DAY_GAP, DAYS = 40, 40, 3, 7
local CARD_H, CARD_GAP = 24, 6
local SHEET_BG = { 0.035, 0.035, 0.043, 0.985 }
local CELL_BG = { 0.08, 0.08, 0.09, 0.95 }
local EDGE = { 0.20, 0.20, 0.23, 1 }
local PICKED_BG = { 0.17, 0.14, 0.05, 0.95 }
local GOLD = { 0.91, 0.73, 0.14 }
local EDITOR_DAYS = 60              -- the calendar reaches this far ahead
local MAX_LEVEL = 70                -- a new raid asks for this level unless "Level 70 only" is switched off
local NO_TEX = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local CHECK_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local ACCESS = {
    { key = "open", text = "Everyone", tip = { "Everyone", "Every guild member can sign up; the teams only say who is "
        .. "expected." } },
    { key = "locked", text = "Teams + invited", tip = { "Teams + invited", "Only the players of the picked teams (the "
        .. "lineup's groups) and the players invited here sign up. The rest of the guild still sees the raid and can "
        .. "ask to join; whoever runs it says yes or no." } },
    { key = "private", text = "Private", tip = { "Private", "Like Teams + invited, but hidden from everyone else: no "
        .. "requests to join." } },
}

local sheet                         -- the frame, made on first use
local S = {}                        -- this file's helpers (one table)

local function RP() return ns.RaidPlan end
local function UI() return ns.UI end
local function Now() return (GetServerTime and GetServerTime()) or time() end
local function Print(...) if ns.Print then ns:Print(...) end end
local function hideTip() GameTooltip:Hide() end
local function colorize(hex, text) return "|cff" .. hex .. tostring(text) .. "|r" end
local function grey(text) return colorize("9e9e9e", text) end

local function text(parent, font, size, layer)
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

local function formLabel(parent, label)
    local fs = text(parent, "GameFontHighlightSmall", 11)
    fs:SetTextColor(0.56, 0.56, 0.58)
    fs:SetText(label)
    return fs
end

local function tipOn(frame, lines, anchor)
    frame:HookScript("OnEnter", function(self)
        local l = type(lines) == "function" and lines(self) or lines
        if l then UI():SetTextTooltip(self, l, anchor or "ANCHOR_TOP") end
    end)
    frame:HookScript("OnLeave", hideTip)
end

-- A flat cell: a fill and 1px edges; c:Paint(picked) gives it the picked look (gold edge, warm fill).
local function flatCell(f)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    UI():AddEdges(f, "BORDER")
    function f:Paint(picked, dim)
        local bg = picked and PICKED_BG or CELL_BG
        self.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
        if picked then UI():SetEdgeColor(self, GOLD[1], GOLD[2], GOLD[3], 1)
        else UI():SetEdgeColor(self, EDGE[1], EDGE[2], EDGE[3], dim and 0.6 or 1) end
    end
    f:Paint(false)
    local hl = f:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.05)
    return f
end

-- The atlas chevron (it points down) turned left or right.
local function chevron(tex, right)
    local c = UI():IconCoords(UI().ICON.chevron)
    local l, r, t, b = c[1], c[2], c[3], c[4]
    tex:SetTexture(UI().ICON_ATLAS)
    if right then tex:SetTexCoord(l, t, r, t, l, b, r, b) else tex:SetTexCoord(l, b, r, b, l, t, r, t) end
end

-- A small arrow button (the date strip's, the time stepper's).
local function arrowButton(parent, right, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(12, 12)
    b.icon:SetPoint("CENTER")
    chevron(b.icon, right)
    b.icon:SetVertexColor(0.75, 0.75, 0.78)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnable", function(self) self.icon:SetAlpha(1) end)
    b:SetScript("OnDisable", function(self) self.icon:SetAlpha(0.25) end)
    return b
end

---------------------------------------------------------------------------
-- The fields (sheet.f): list = the instances in the night's order; i / ix = its first / the others (what is saved);
-- sz (szKeep: an edited raid's own size while its raids are unchanged); y, m, d, hour, min; tm / tl = picked teams /
-- their lineup; inv; access ("open" | "locked" | "private") with lk / pv as saved; low = lower characters may sign up.
---------------------------------------------------------------------------

function S.sync()
    local f = sheet.f
    f.i = f.list[1]
    f.ix = {}
    for n = 2, #f.list do f.ix[#f.ix + 1] = f.list[n] end
    f.lk = f.access ~= "open"
    f.pv = f.access == "private"
    -- the size follows the raids picked (the larger one)
    if not f.szKeep and #f.list > 0 then
        local sz = 10
        for _, key in ipairs(f.list) do
            local inst = RP():GetInstance(key)
            if inst and inst.size > sz then sz = inst.size end
        end
        f.sz = sz
    end
end

-- Server time of the picked day + hour + minute (local wall clock).
function S.time()
    local f = sheet.f
    return time({ year = f.y, month = f.m, day = f.d, hour = f.hour, min = f.min, sec = 0 })
end

-- Noon of a day n days from today, and that day's { y, m, d }.
function S.dayAt(n)
    local d = date("*t", Now())
    local t = time({ year = d.year, month = d.month, day = d.day + n, hour = 12, min = 0, sec = 0 })
    local x = date("*t", t)
    return t, x.year, x.month, x.day
end

-- How many days from today the picked day is.
function S.pickedOffset()
    local f = sheet.f
    local d = date("*t", Now())
    local t0 = time({ year = d.year, month = d.month, day = d.day, hour = 12, min = 0, sec = 0 })
    local t1 = time({ year = f.y, month = f.m, day = f.d, hour = 12, min = 0, sec = 0 })
    return floor((t1 - t0) / 86400 + 0.5)
end

-- The days that can be picked: today (or the edited raid's own day, if earlier) .. EDITOR_DAYS ahead.
function S.minOffset()
    if not sheet.minT then return 0 end
    local d = date("*t", Now())
    local t0 = time({ year = d.year, month = d.month, day = d.day, hour = 12, min = 0, sec = 0 })
    local m = date("*t", sheet.minT)
    local t1 = time({ year = m.year, month = m.month, day = m.day, hour = 12, min = 0, sec = 0 })
    return min(0, floor((t1 - t0) / 86400 + 0.5))
end

-- The raids planned on a day ("20:00  Karazhan" lines), the edited one left out; nil for none.
function S.raidsOn(y, m, d)
    local from = time({ year = y, month = m, day = d, hour = 0, min = 0, sec = 0 })
    local to = time({ year = y, month = m, day = d + 1, hour = 0, min = 0, sec = 0 }) - 1
    local lines = {}
    for _, v in ipairs(RP():GetRaids(from, to)) do
        if not v.cancelled and v.id ~= sheet.occ then
            lines[#lines + 1] = date("%H:%M", v.t) .. "  " .. RP():GetRaidName(v)
        end
    end
    return #lines > 0 and lines or nil
end

-- A team's lineups of the raid's size (GetTeam lineups).
function S.sizeLineups(t)
    local out = {}
    for _, l in ipairs(t.lineups) do
        if l.size == sheet.f.sz then out[#out + 1] = l end
    end
    return out
end

-- The lineup a picked team gives the raid: the one chosen (tl), else its first of the raid's size; and how many it has
-- of that size.
function S.pickedLineup(t)
    local list = S.sizeLineups(t)
    for _, l in ipairs(list) do
        if l.id == sheet.f.tl[t.id] then return l, #list end
    end
    return list[1], #list
end

-- The players a team invites through lineup l (those in its groups); the roster without a lineup of the raid's size,
-- or when it has nobody in its groups yet (RaidPlan:GetRaidTeamPlayers). Returns the keys and whether it is the
-- roster.
function S.players(t, l)
    local out = {}
    if l then
        local n = ns.RaidComp:GroupCount(sheet.f.sz)
        for _, key in ipairs(t.members) do
            local g = l.groups[key]
            if type(g) == "number" and g >= 1 and g <= n then out[#out + 1] = key end
        end
    end
    if #out == 0 then return t.members, true end
    return out, false
end

-- The team cards: { value = team id or "team:lineup", name, what (the lineup, or "roster"), n, team, lineup, roster,
-- chosen }. A team with several lineups of the raid's size gets one per lineup; one without any invites its roster.
function S.teamCards()
    local f = sheet.f
    local out = {}
    for _, t in ipairs(RP():GetTeams()) do
        local list = S.sizeLineups(t)
        local function add(l, value)
            local players, roster = S.players(t, l)
            local picked = S.pickedLineup(t)
            out[#out + 1] = { value = value, team = t, lineup = l, roster = roster, n = #players, name = t.name,
                              what = (roster and "roster") or ((#t.lineups > 1) and RP():LineupName(t, l)) or nil,
                              chosen = f.tm[t.id] and (#list < 2 or (picked and l and picked.id == l.id)) or false }
        end
        if #list > 1 then
            for _, l in ipairs(list) do add(l, t.id .. ":" .. l.id) end
        else
            add(list[1], t.id)
        end
    end
    return out
end

-- A card clicked: picks the team (with that lineup) or takes it off.
function S.toggleTeam(value)
    local f = sheet.f
    local id, ln = tostring(value):match("^([^:]+):?(.*)$")
    if not id or id == "" then return end
    local t = RP():GetTeam(id)
    local picked = t and S.pickedLineup(t)
    local on = f.tm[id] and (ln == "" or (picked and picked.id == ln))
    if on then
        f.tm[id], f.tl[id] = nil, nil
    else
        f.tm[id] = true
        f.tl[id] = ln ~= "" and ln or nil
    end
    S.refresh()
end

-- The guild members to invite on top of the teams (the players a picked team invites are in already).
function S.inviteItems()
    local g = ns.Guild
    local inTeam = {}
    for _, t in ipairs(RP():GetTeams()) do
        if sheet.f.tm[t.id] then
            for _, key in ipairs((S.players(t, (S.pickedLineup(t))))) do inTeam[key] = t.name end
        end
    end
    local out, seen = {}, {}
    for _, key in ipairs(g and g.GetMembers and g:GetMembers() or {}) do
        seen[key] = true
        out[#out + 1] = { key = key, text = ns.Util.ShortName(key), classFile = g:GetClass(key), note = g:GetRankName(key),
                          dim = not g:IsOnline(key), fixed = inTeam[key] }
    end
    for key in pairs(sheet.f.inv) do
        if not seen[key] then
            out[#out + 1] = { key = key, text = ns.Util.ShortName(key), note = "not in the guild", dim = true }
        end
    end
    tsort(out, function(a, b) return a.text:lower() < b.text:lower() end)
    return out
end

function S.inviteList()
    local list = {}
    for key in pairs(sheet.f.inv) do list[#list + 1] = key end
    tsort(list)
    return list
end

-- Who can sign up, in one line, and how many players the teams and the invites take.
function S.whoLine()
    local f = sheet.f
    local set, names = {}, {}
    for _, c in ipairs(S.teamCards()) do
        if c.chosen then
            names[#names + 1] = c.name .. (c.what and (" · " .. c.what) or "")
            for _, key in ipairs((S.players(c.team, c.lineup))) do set[key] = true end
        end
    end
    local nInv = 0
    for key in pairs(f.inv) do
        if not set[key] then nInv = nInv + 1 end
        set[key] = true
    end
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    local who = {}
    if #names > 0 then who[#who + 1] = tconcat(names, ", ") end
    if nInv > 0 then who[#who + 1] = nInv .. " invited" end
    local level = f.low and "" or (" Level %d only."):format(MAX_LEVEL)
    if f.access == "open" then
        return (#names > 0 and ("Everyone can sign up; %s %s expected."):format(tconcat(names, ", "),
            #names == 1 and "is" or "are") or "Every guild member can sign up.") .. level, n
    end
    if n == 0 then return colorize("ff9933", "Nobody can sign up yet: pick a team or invite players."), n end
    if f.access == "private" then
        return ("Private: only these %d players see it (%s)."):format(n, tconcat(who, " + ")) .. level, n
    end
    return ("%d can sign up (%s); the rest can ask to join."):format(n, tconcat(who, " + ")) .. level, n
end

-- What the form saves: { i, ix, sz, t, tm, tl, lk, pv, inv, ml, ti, no }.
function S.fields()
    local f = sheet.f
    S.sync()
    local tm, tl = {}, {}
    for _, t in ipairs(RP():GetTeams()) do
        if f.tm[t.id] then
            tm[#tm + 1] = t.id
            -- (a team with more than one lineup of the raid's size names the one it gives)
            local l, count = S.pickedLineup(t)
            if l and count > 1 then tl[t.id] = l.id end
        end
    end
    local function opt(eb)
        local s = ns.Util.Trim(eb:GetText() or "")
        return s ~= "" and s or false
    end
    return {
        i = f.i, ix = f.ix, sz = f.sz, t = S.time(), tm = tm, tl = tl, lk = f.lk and true or false,
        pv = f.pv and true or false, inv = S.inviteList(), ml = f.low and 0 or MAX_LEVEL,
        ti = opt(sheet.titleBox), no = opt(sheet.noteBox),
    }
end

-- An edit sends only what changed: an override of one weekly raid that repeated every field would pin them, and later
-- "every week" edits would no longer reach it.
function S.changed(fields, v)
    local out = {}
    for _, k in ipairs({ "i", "sz", "t" }) do
        if fields[k] ~= v[k] then out[k] = fields[k] end
    end
    for _, k in ipairs({ "ti", "no" }) do
        if (fields[k] or nil) ~= v[k] then out[k] = fields[k] end
    end
    if tconcat(fields.ix, ",") ~= tconcat(v.ix or {}, ",") then out.ix = fields.ix end
    local sa, sb = {}, {}
    for _, id in ipairs(fields.tm) do sa[#sa + 1] = id end
    for _, id in ipairs(v.tm or {}) do sb[#sb + 1] = id end
    tsort(sa)
    tsort(sb)
    if tconcat(sa, ",") ~= tconcat(sb, ",") then out.tm = fields.tm end
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

function S.setError(msg)
    sheet.errText = msg
    S.refreshFooter()
end

-- Create / Save / This week only ("one") / Every week ("series").
function S.save(scope)
    local fields = S.fields()
    if not fields.i then
        S.setError("Pick a raid above.")
        return false
    end
    if fields.lk and #fields.tm == 0 and #fields.inv == 0 then
        S.setError("A raid for its teams needs a team or invited players.")
        return false
    end
    local ok, res
    if sheet.occ then
        local v = RP():GetRaid(sheet.occ)
        if not v then
            S.setError("This raid no longer exists.")
            return false
        end
        fields = S.changed(fields, v)
        if not next(fields) then
            PlanUI:CloseEditor()
            return true
        end
        ok, res = RP():EditRaid(sheet.occ, fields, scope)
    else
        fields.weekly = sheet.weeklyCB:GetChecked() and true or false
        if not fields.ti then fields.ti = nil end
        if not fields.no then fields.no = nil end
        if #fields.ix == 0 then fields.ix = nil end
        if not next(fields.tl) then fields.tl = nil end
        ok, res = RP():CreateRaid(fields)
    end
    if not ok then
        S.setError(res or "Could not save the raid.")
        return false
    end
    local created = not sheet.occ and res
    PlanUI:CloseEditor()
    if created then PlanUI:SelectRaid(created) end
    return true
end

---------------------------------------------------------------------------
-- The frames
---------------------------------------------------------------------------

-- A raid tile: its loading screen, the name, the default size, and (picked, with others) its place in the night.
function S.newTile(parent, inst)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(TILE_H)
    b.key = inst.key
    b.art = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.art:SetPoint("TOPLEFT", 1, -1)
    b.art:SetPoint("BOTTOMRIGHT", -1, 1)
    b.shade = b:CreateTexture(nil, "BACKGROUND", nil, 2)
    b.shade:SetPoint("TOPLEFT", 1, -1)
    b.shade:SetPoint("BOTTOMRIGHT", -1, 1)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetPoint("TOPLEFT", 1, -1)
    b.hl:SetPoint("BOTTOMRIGHT", -1, 1)
    b.hl:SetColorTexture(1, 1, 1, 0.08)
    UI():AddEdges(b, "BORDER")
    b.name = text(b, "GameFontHighlight", 12)
    b.name:SetPoint("BOTTOMLEFT", 8, 6)
    b.name:SetText(inst.key == "other" and "Other" or inst.key == "ssc" and "Serpentshrine" or inst.name)
    b.size = text(b, "GameFontHighlightSmall", 10)
    b.size:SetTextColor(0.75, 0.75, 0.75)
    b.size:SetPoint("BOTTOMRIGHT", -7, 7)
    b.size:SetText(inst.key == "other" and "" or tostring(inst.size))
    b.badge = b:CreateTexture(nil, "OVERLAY", nil, 1)
    b.badge:SetTexture(DISC)
    b.badge:SetSize(16, 16)
    b.badge:SetPoint("TOPLEFT", 5, -5)
    b.badge:SetVertexColor(1, 0.82, 0)
    b.num = text(b, "GameFontHighlightSmall", 10, "OVERLAY")
    b.num:SetJustifyH("CENTER")
    b.num:SetTextColor(0.1, 0.08, 0.02)
    b.num:SetPoint("CENTER", b.badge, "CENTER", 0, 0)
    b:SetScript("OnClick", function(self) PlanUI:ToggleEditorRaid(self.key) end)
    b:SetScript("OnEnter", function(self)
        local f = sheet.f
        local lines = { inst.key == "other" and "Other" or inst.name }
        if inst.key ~= "other" then lines[#lines + 1] = grey(inst.size .. "-player raid") end
        local n = #f.list
        local at
        for i, key in ipairs(f.list) do if key == self.key then at = i end end
        if at then
            lines[#lines + 1] = (n > 1 and ("#%d of the night. "):format(at) or "") .. "Click to take it out."
        else
            lines[#lines + 1] = n > 0 and "Click to add it to the night, after the others." or "Click to pick it."
        end
        UI():SetTextTooltip(self, lines, "ANCHOR_TOP")
    end)
    b:SetScript("OnLeave", hideTip)
    return b
end

function S.fillTile(b, w)
    local f = sheet.f
    local at
    for i, key in ipairs(f.list) do if key == b.key then at = i end end
    local file, l, r, t, bb = PlanUI:RaidArt(b.key, w - 2, TILE_H - 2, 0.5)
    b.art:SetTexture(file)
    b.art:SetTexCoord(l, r, t, bb)
    b.art:SetDesaturated(not at and #f.list > 0)
    b.art:SetAlpha(at and 1 or 0.7)
    b.shade:SetColorTexture(0, 0, 0, at and 0.25 or 0.5)
    if at then UI():SetEdgeColor(b, GOLD[1], GOLD[2], GOLD[3], 1) else UI():SetEdgeColor(b, 0.34, 0.34, 0.38, 0.85) end
    b.name:SetTextColor(1, 1, 1, at and 1 or 0.85)
    local several = #f.list > 1
    b.badge:SetShown(at ~= nil and several)
    b.num:SetShown(at ~= nil and several)
    b.num:SetText(at or "")
end

-- A day of the date strip: the weekday ("TODAY") over the day; a dot when a raid is planned that day.
function S.newDay(parent)
    local c = flatCell(CreateFrame("Button", nil, parent))
    c:SetSize(DAY_W, DAY_H)
    c.wd = text(c, "GameFontHighlightSmall", 9)
    c.wd:SetJustifyH("CENTER")
    c.wd:SetPoint("TOP", 0, -7)
    c.dn = text(c, "GameFontHighlight", 14)
    c.dn:SetJustifyH("CENTER")
    c.dn:SetPoint("TOP", c.wd, "BOTTOM", 0, -2)
    c.dot = c:CreateTexture(nil, "OVERLAY")
    c.dot:SetTexture(DISC)
    c.dot:SetSize(4, 4)
    c.dot:SetPoint("BOTTOM", 0, 3)
    c.dot:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
    c:SetScript("OnClick", function(self)
        local f = sheet.f
        f.y, f.m, f.d = self.y, self.m, self.d
        S.refresh()
    end)
    tipOn(c, function(self)
        local lines = { date("%A %d %B", self.t) }
        for _, l in ipairs(self.raids or {}) do lines[#lines + 1] = l end
        return lines
    end)
    return c
end

-- A team card: [check] name · lineup [count]; picked = gold edge and a check.
function S.newCard(parent)
    local c = flatCell(CreateFrame("Button", nil, parent))
    c:SetHeight(CARD_H)
    c.check = c:CreateTexture(nil, "ARTWORK")
    c.check:SetTexture(CHECK_TEX)
    c.check:SetDesaturated(true)
    c.check:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
    c.check:SetSize(12, 12)
    c.check:SetPoint("LEFT", 8, 0)
    c.name = text(c, "GameFontHighlight", 12)
    c.what = text(c, "GameFontHighlight", 12)
    c.what:SetTextColor(0.6, 0.6, 0.62)
    c.badge = CreateFrame("Frame", nil, c)
    c.badge:SetHeight(16)
    UI():AddPillShape(c.badge, 16)
    c.count = text(c.badge, "GameFontHighlightSmall", 10)
    c.count:SetJustifyH("CENTER")
    c.count:SetPoint("CENTER", 0, 0)
    c:SetScript("OnClick", function(self) S.toggleTeam(self.entry.value) end)
    tipOn(c, function(self)
        local e = self.entry
        if not e then return nil end
        return { e.name .. (e.what and (" · " .. e.what) or ""), e.roster
            and "No lineup of this size with players in its groups: the whole roster is invited."
            or ("The %d players in this lineup's groups are invited; its groups and comp are the raid's."):format(e.n) }
    end)
    return c
end

function S.fillCard(c, e)
    c.entry = e
    c:Paint(e.chosen)
    c.check:SetShown(e.chosen)
    local x = e.chosen and 26 or 10
    c.name:ClearAllPoints()
    c.name:SetPoint("LEFT", c, "LEFT", x, 0)
    c.name:SetText(e.name)
    x = x + (c.name:GetStringWidth() or 60)
    c.what:ClearAllPoints()
    c.what:SetPoint("LEFT", c.name, "RIGHT", 0, 0)
    c.what:SetText(e.what and (" · " .. e.what) or "")
    x = x + (e.what and (c.what:GetStringWidth() or 40) or 0)
    c.count:SetText(e.n)
    local bw = max(20, floor((c.count:GetStringWidth() or 8) + 12 + 0.5))
    c.badge:SetWidth(bw)
    c.badge:ClearAllPoints()
    c.badge:SetPoint("LEFT", c, "LEFT", x + 8, 0)
    if e.chosen then
        c.badge:SetPillColors({ 0.29, 0.24, 0.07, 1 }, { 0.29, 0.24, 0.07, 1 })
        c.count:SetTextColor(1, 0.88, 0.54)
    else
        c.badge:SetPillColors({ 0.15, 0.15, 0.17, 1 }, { 0.15, 0.15, 0.17, 1 })
        c.count:SetTextColor(0.8, 0.8, 0.8)
    end
    c:SetWidth(floor(x + 8 + bw + 8 + 0.5))
end

-- An invited player as a pill: the name in its class colour and an x that takes them off.
function S.newPill(parent)
    local p = CreateFrame("Button", nil, parent)
    p:SetHeight(20)
    UI():AddPillShape(p, 20)
    p:SetPillColors({ 0.11, 0.11, 0.13, 1 }, { 0.22, 0.22, 0.26, 1 })
    p.name = text(p, "GameFontHighlightSmall", 11)
    p.name:SetPoint("LEFT", 10, 0)
    p.x = text(p, "GameFontHighlightSmall", 11)
    p.x:SetTextColor(0.55, 0.55, 0.58)
    p.x:SetText("x")
    p:SetScript("OnClick", function(self)
        sheet.f.inv[self.key] = nil
        S.refresh()
    end)
    p:SetScript("OnEnter", function(self)
        self.x:SetTextColor(1, 0.45, 0.45)
        UI():SetTextTooltip(self, { ns.Util.ShortName(self.key), "Invited on top of the teams. Click to take them off." },
            "ANCHOR_TOP")
    end)
    p:SetScript("OnLeave", function(self)
        self.x:SetTextColor(0.55, 0.55, 0.58)
        hideTip()
    end)
    return p
end

function S.create()
    local p = ns.RaidsUI and ns.RaidsUI.GetPanel and ns.RaidsUI:GetPanel()
    if not p then return nil end
    local sh = CreateFrame("Frame", nil, p)
    sheet = sh
    sh:SetAllPoints(p)
    sh:SetFrameLevel(p:GetFrameLevel() + 30)
    sh:EnableMouse(true)
    sh.bg = sh:CreateTexture(nil, "BACKGROUND")
    sh.bg:SetAllPoints()
    sh.bg:SetColorTexture(SHEET_BG[1], SHEET_BG[2], SHEET_BG[3], SHEET_BG[4])
    sh.f = { list = {}, tm = {}, tl = {}, inv = {}, access = "open" }

    -- the title row: New raid / Edit raid, close
    sh.title = text(sh, "GameFontNormal", 15)
    sh.title:SetPoint("TOPLEFT", PAD, -14)
    sh.close = UI():CreateIconButton(sh, 24, NO_TEX, nil, function() PlanUI:CloseEditor() end)
    sh.close.icon:SetDesaturated(true)
    sh.close:SetPoint("TOPRIGHT", -PAD, -9)
    tipOn(sh.close, { "Close", "Nothing is saved." }, "ANCHOR_LEFT")

    -- the raids
    sh.tiles = {}
    for _, inst in ipairs(RP():GetInstances()) do sh.tiles[#sh.tiles + 1] = S.newTile(sh, inst) end

    local function rowFrame(label, h)
        local r = CreateFrame("Frame", nil, sh)
        r:SetHeight(h)
        r.label = formLabel(r, label)
        return r
    end

    -- When: the week, the month tile (the calendar), the time, Every week
    sh.whenRow = rowFrame("When", DAY_H)
    sh.whenRow.label:SetPoint("LEFT", 0, 0)
    sh.prevWeek = arrowButton(sh.whenRow, false, 18, DAY_H, function() S.moveStrip(-DAYS) end)
    sh.prevWeek:SetPoint("LEFT", sh.whenRow, "LEFT", LABEL_W, 0)
    tipOn(sh.prevWeek, { "A week back" })
    sh.days = {}
    for i = 1, DAYS do
        local c = S.newDay(sh.whenRow)
        c:SetPoint("LEFT", sh.prevWeek, "RIGHT", 2 + (i - 1) * (DAY_W + DAY_GAP), 0)
        sh.days[i] = c
    end
    sh.nextWeek = arrowButton(sh.whenRow, true, 18, DAY_H, function() S.moveStrip(DAYS) end)
    sh.nextWeek:SetPoint("LEFT", sh.days[DAYS], "RIGHT", 2, 0)
    tipOn(sh.nextWeek, { "A week on" })
    -- (the month tile is the date picker's own button: its calendar opens under it)
    sh.datePicker = UI():CreateDatePicker(sh.whenRow, {
        get = function() return sh.f.y, sh.f.m, sh.f.d end,
        set = function(y, m, d)
            sh.f.y, sh.f.m, sh.f.d = y, m, d
            sh.stripStart = nil
            S.refresh()
        end,
        minDate = function()
            local _, y, m, d = S.dayAt(S.minOffset())
            return y, m, d
        end,
        maxDate = function()
            local _, y, m, d = S.dayAt(EDITOR_DAYS)
            return y, m, d
        end,
        mark = function(y, m, d)
            local lines = S.raidsOn(y, m, d)
            return lines and tconcat(lines, "\n") or nil
        end,
        width = 44,
    })
    local dp = sh.datePicker
    dp:SetSize(44, DAY_H)
    dp:SetPoint("LEFT", sh.nextWeek, "RIGHT", 6, 0)
    dp.month = text(dp, "GameFontNormalSmall", 10)
    dp.month:SetJustifyH("CENTER")
    dp.month:SetPoint("TOP", 0, -8)
    dp.chev = dp:CreateTexture(nil, "OVERLAY")
    dp.chev:SetSize(10, 10)
    dp.chev:SetPoint("TOP", dp.month, "BOTTOM", 0, -4)
    dp.chev:SetTexture(UI().ICON_ATLAS)
    dp.chev:SetTexCoord(unpack(UI():IconCoords(UI().ICON.chevron)))
    dp.chev:SetVertexColor(0.75, 0.75, 0.78)
    local dpRefresh = dp.Refresh
    function dp:Refresh()
        dpRefresh(self)
        self:SetText("")
        local f = sh.f
        if f.y then self.month:SetText(date("%b", time({ year = f.y, month = f.m, day = f.d, hour = 12 })):upper()) end
    end
    tipOn(dp, { "Calendar", ("A day further out (up to %d days ahead); a dot marks the days with a raid."):format(
        EDITOR_DAYS) })
    -- the time: a stepper, 15 minutes a step (the mouse wheel too)
    local tm = flatCell(CreateFrame("Frame", nil, sh.whenRow))
    tm:SetSize(104, DAY_H)
    tm:SetPoint("LEFT", dp, "RIGHT", 12, 0)
    tm:EnableMouseWheel(true)
    tm:SetScript("OnMouseWheel", function(_, delta) S.stepTime(delta > 0 and 1 or -1) end)
    tm.down = arrowButton(tm, false, 24, DAY_H - 2, function() S.stepTime(-1) end)
    tm.down:SetPoint("LEFT", 1, 0)
    tm.up = arrowButton(tm, true, 24, DAY_H - 2, function() S.stepTime(1) end)
    tm.up:SetPoint("RIGHT", -1, 0)
    tm.fs = text(tm, "GameFontHighlight", 15)
    tm.fs:SetJustifyH("CENTER")
    tm.fs:SetPoint("CENTER", 0, 0)
    tipOn(tm, { "Time", "Your clock; everybody sees it in theirs. Click the arrows or scroll: 15 minutes a step." })
    sh.timeStep = tm
    sh.weeklyCB = UI():CreateSwitch(sh.whenRow, nil, function(on)
        sh.f.weekly = on
        S.refreshPreview()
    end, "Every week")
    sh.weeklyCB:SetPoint("LEFT", tm, "RIGHT", 16, 0)
    tipOn(sh.weeklyCB, { "Every week", "A weekly raid: the next two weeks are always planned, and each week can be "
        .. "changed or cancelled on its own." })

    -- Who: the team cards, the search for players outside the teams, the invited players
    sh.whoRow = rowFrame("Who", CARD_H)
    sh.whoRow.label:SetPoint("TOPLEFT", 0, -6)
    sh.cards = {}
    sh.pills = {}
    sh.invPicker = UI():CreateSearchDropdown(sh.whoRow, 170, {
        placeholder = "Invite players",
        emptyText = "No matching guild members.",
        panelWidth = 260,
        getItems = S.inviteItems,
        isChecked = function(key) return sh.f.inv[key] and true or false end,
        onToggle = function(key)
            sh.f.inv[key] = not sh.f.inv[key] or nil
            S.refresh()
        end,
    })
    sh.invPicker.frame:SetHeight(CARD_H)
    tipOn(sh.invPicker.frame, { "Invite players", "Players outside the teams who are invited too (guild members)." })

    -- Sign-ups: one choice; Level 70 only beside it
    sh.accessRow = rowFrame("Sign-ups", CARD_H)
    sh.accessRow.label:SetPoint("LEFT", 0, 0)
    sh.access = {}
    for i, a in ipairs(ACCESS) do
        local b = UI():CreateSleekButton(sh.accessRow, a.text, nil, CARD_H, function() PlanUI:SetEditorAccess(a.key) end)
        setSize(b:GetFontString(), 11)
        b:SetWidth(floor((b:GetFontString():GetStringWidth() or 60) + 26 + 0.5))
        b.key = a.key
        if i == 1 then b:SetPoint("LEFT", sh.accessRow, "LEFT", LABEL_W, 0)
        else b:SetPoint("LEFT", sh.access[i - 1], "RIGHT", -1, 0) end
        tipOn(b, a.tip)
        sh.access[i] = b
    end
    sh.levelSW = UI():CreateSwitch(sh.accessRow, function() return not sh.f.low end, function(on)
        sh.f.low = not on
        S.refresh()
    end, ("Level %d only"):format(MAX_LEVEL))
    sh.levelSW:SetPoint("LEFT", sh.access[#sh.access], "RIGHT", 18, 0)
    tipOn(sh.levelSW, { ("Level %d only"):format(MAX_LEVEL), ("On: only level %d characters can sign up (a lower "
        .. "character's answer is not counted). Off: lower characters may join too."):format(MAX_LEVEL) })

    -- Details: Title and Note side by side
    sh.detailRow = rowFrame("Details", 26)
    sh.detailRow.label:SetPoint("LEFT", 0, 0)
    sh.titleBox = UI():CreateSleekEditBox(sh.detailRow, 200, 26, "GameFontHighlightSmall")
    sh.titleBox:SetMaxLetters(32)
    sh.titleBox:SetPoint("LEFT", sh.detailRow, "LEFT", LABEL_W, 0)
    sh.noteBox = UI():CreateSleekEditBox(sh.detailRow, 200, 26, "GameFontHighlightSmall")
    sh.noteBox:SetMaxLetters(120)
    sh.noteBox:SetPoint("LEFT", sh.titleBox, "RIGHT", 8, 0)
    for _, eb in ipairs({ sh.titleBox, sh.noteBox }) do
        eb:SetAutoFocus(false)
        eb:HookScript("OnTextChanged", function() S.refreshPreview() end)
        eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    end
    UI():SetEditPlaceholder(sh.titleBox, "Title (optional): \"T4 farm night\"")
    UI():SetEditPlaceholder(sh.noteBox, "Note (optional): \"bring flasks\"")

    -- the preview and the footer
    sh.preview = PlanUI:CreateRaidCard(sh)
    sh.preview:EnableMouse(false)
    sh.pick = text(sh, "GameFontHighlightSmall", 12)
    sh.pick:SetTextColor(0.62, 0.62, 0.62)
    sh.pick:SetText("Pick a raid above.")
    sh.who = text(sh, "GameFontHighlightSmall", 11)
    sh.who:SetTextColor(0.78, 0.78, 0.78)
    sh.err = text(sh, "GameFontHighlightSmall", 11)
    sh.err:SetTextColor(1, 0.55, 0.1)
    sh.weeklyInfo = text(sh, "GameFontHighlightSmall", 11)
    sh.weeklyInfo:SetTextColor(0.5, 0.5, 0.5)
    sh.weeklyInfo:SetText("A weekly raid: save this week only, or every week.")
    sh.saveBtn = UI():CreateSleekButton(sh, "Create raid", 120, 26, function() S.save("one") end, "primary")
    sh.saveAllBtn = UI():CreateSleekButton(sh, "Every week", 100, 26, function() S.save("series") end)
    sh.cancelBtn = UI():CreateSleekButton(sh, "Cancel", 80, 26, function() PlanUI:CloseEditor() end)
    sh:Hide()
    return sh
end

-- The date strip: a week from sheet.stripStart (days from today), within the days that can be picked.
function S.moveStrip(delta)
    local lo, hi = S.minOffset(), EDITOR_DAYS - DAYS + 1
    sheet.stripStart = max(lo, min(hi, (sheet.stripStart or 0) + delta))
    S.refresh()
end

function S.stepTime(dir)
    local f = sheet.f
    local mins = max(0, min(23 * 60 + 45, f.hour * 60 + f.min + dir * 15))
    f.hour, f.min = floor(mins / 60), mins % 60
    S.refresh()
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

function S.layoutWhen()
    local sh, f = sheet, sheet.f
    local lo, hi = S.minOffset(), EDITOR_DAYS
    local picked = S.pickedOffset()
    -- (the week moves with the arrows on its own; it comes to the picked day only when that day changes, e.g. from
    -- the calendar, and is out of sight: then it starts the day before it)
    local start = sh.stripStart
    if not start or (picked ~= sh.stripPicked and (picked < start or picked >= start + DAYS)) then start = picked - 1 end
    start = max(lo, min(hi - DAYS + 1, start))
    sh.stripStart, sh.stripPicked = start, picked
    for i, c in ipairs(sh.days) do
        local n = start + i - 1
        local t, y, m, d = S.dayAt(n)
        c.t, c.y, c.m, c.d = t, y, m, d
        local on = n == picked
        local ok = n >= lo and n <= hi
        c:Paint(on, not ok)
        c:SetEnabled(ok)
        c.wd:SetText(n == 0 and "TODAY" or date("%a", t):upper())
        if on then c.wd:SetTextColor(GOLD[1], GOLD[2], GOLD[3]) else c.wd:SetTextColor(0.56, 0.56, 0.58) end
        c.dn:SetText(d)
        c.dn:SetAlpha(ok and 1 or 0.35)
        c.raids = S.raidsOn(y, m, d)
        c.dot:SetShown(c.raids ~= nil)
    end
    sh.prevWeek:SetEnabled(start > lo)
    sh.nextWeek:SetEnabled(start + DAYS - 1 < hi)
    sh.timeStep.fs:SetText(("%02d:%02d"):format(f.hour, f.min))
    sh.datePicker:Refresh()
end

-- The Who row: the cards and the invite search, wrapping; the invited players under them. Returns its height.
function S.layoutWho(w)
    local sh = sheet
    local list = S.teamCards()
    for _, c in ipairs(sh.cards) do c:Hide() end
    local x, y = 0, 0
    local function place(f, fw)
        if x > 0 and x + fw > w then x, y = 0, y + CARD_H + CARD_GAP end
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", sh.whoRow, "TOPLEFT", LABEL_W + x, -y)
        x = x + fw + CARD_GAP
    end
    for i, e in ipairs(list) do
        local c = sh.cards[i] or S.newCard(sh.whoRow)
        sh.cards[i] = c
        S.fillCard(c, e)
        place(c, c:GetWidth())
        c:Show()
    end
    place(sh.invPicker.frame, sh.invPicker.frame:GetWidth())
    local h = y + CARD_H
    -- the invited players
    local inv = S.inviteList()
    for _, p in ipairs(sh.pills) do p:Hide() end
    if #inv > 0 then
        local px, py = 0, h + 8
        for i, key in ipairs(inv) do
            local p = sh.pills[i] or S.newPill(sh.whoRow)
            sh.pills[i] = p
            p.key = key
            local g = ns.Guild
            p.name:SetText(UI():ColoredName(key, g and g.GetClass and g:GetClass(key)))
            local pw = floor((p.name:GetStringWidth() or 60) + 10 + 8 + 8 + 10 + 0.5)
            p:SetWidth(pw)
            p.x:ClearAllPoints()
            p.x:SetPoint("RIGHT", -9, 0)
            if px > 0 and px + pw > w then px, py = 0, py + 20 + 5 end
            p:ClearAllPoints()
            p:SetPoint("TOPLEFT", sh.whoRow, "TOPLEFT", LABEL_W + px, -py)
            p:Show()
            px = px + pw + 5
        end
        h = py + 20
    end
    return h
end

function S.refreshPreview()
    local sh = sheet
    if not sh or not sh:IsShown() then return end
    local f = sh.f
    S.sync()
    sh.preview:SetShown(f.i ~= nil)
    sh.pick:SetShown(f.i == nil)
    if not f.i then return end
    local fields = S.fields()
    local v = { id = "preview", t = fields.t, i = f.i, ix = f.ix, sz = f.sz, tm = fields.tm, tl = fields.tl,
                lk = fields.lk, pv = fields.pv, inv = fields.inv, ti = fields.ti or nil, no = fields.no or nil,
                ml = fields.ml > 0 and fields.ml or nil, by = ns.Util.PlayerKey(),
                weekly = sh.occ and sh.weekly or (sh.weeklyCB:GetChecked() and true or false) }
    if sh.occ then
        local cur = RP():GetRaid(sh.occ)
        if cur then v.id, v.rl, v.rlb, v.by, v.cancelled = cur.id, cur.rl, cur.rlb, cur.by, cur.cancelled end
    end
    PlanUI:FillRaidCard(sh.preview, v, sh.previewW or 770)
    -- (no answers in a preview)
    for _, k in ipairs({ "accept", "tentative", "more", "ask", "pill", "why" }) do
        if sh.preview[k] then sh.preview[k]:Hide() end
    end
    if sh.preview.pill and sh.preview.pill.sub then sh.preview.pill.sub:Hide() end
end

function S.refreshFooter()
    local sh = sheet
    local line = S.whoLine()
    sh.err:SetText(sh.errText or "")
    sh.err:SetShown(sh.errText ~= nil)
    sh.who:SetText(line)
    sh.who:SetShown(sh.errText == nil)
end

function S.refresh()
    local sh = sheet
    if not sh or not sh:IsShown() then return end
    local f = sh.f
    sh.errText = nil
    S.sync()
    local p = sh:GetParent()
    local W = p and p:GetWidth() or 0
    if W < 400 or W > 790 then W = 790 end
    local inner = W - 2 * PAD
    sh.title:SetText(sh.occ and "Edit raid" or "New raid")

    -- the tiles: five to a row
    local tw = floor((inner - (TILE_COLS - 1) * TILE_GAP) / TILE_COLS)
    local y = 44
    for i, b in ipairs(sh.tiles) do
        local col, row = (i - 1) % TILE_COLS, floor((i - 1) / TILE_COLS)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD + col * (tw + TILE_GAP), -(y + row * (TILE_H + TILE_GAP)))
        b:SetWidth(tw)
        S.fillTile(b, tw)
    end
    y = y + 2 * TILE_H + TILE_GAP + 18

    -- the rows, one label column
    local function place(r, h)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, -y)
        r:SetSize(inner, h)
        y = y + h + ROW_GAP
    end
    S.layoutWhen()
    sh.weeklyCB:SetShown(sh.occ == nil)
    place(sh.whenRow, DAY_H)
    local whoH = S.layoutWho(inner - LABEL_W)
    place(sh.whoRow, whoH)
    for _, b in ipairs(sh.access) do b:SetKind(f.access == b.key and "chosen" or "secondary") end
    sh.levelSW:SetChecked(not f.low)
    place(sh.accessRow, CARD_H)
    local fw = floor((inner - LABEL_W - 8) / 2)
    sh.titleBox:SetWidth(fw)
    sh.noteBox:SetWidth(inner - LABEL_W - 8 - fw)
    place(sh.detailRow, 26)

    -- the preview: the board's card, full width; the footer under it
    y = y + 4
    sh.preview:ClearAllPoints()
    sh.preview:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, -y)
    sh.pick:ClearAllPoints()
    sh.pick:SetPoint("TOPLEFT", sh, "TOPLEFT", PAD, -(y + 6))
    sh.previewW = inner
    y = y + 84 + 14
    local series = sh.occ and sh.series
    sh.saveAllBtn:SetShown(series and true or false)
    sh.weeklyInfo:SetShown(series and true or false)
    sh.saveBtn:SetText(sh.occ and (sh.weekly and "This week only" or "Save") or "Create raid")
    sh.saveBtn:SetWidth(sh.occ and sh.weekly and 120 or 110)
    sh.saveBtn:ClearAllPoints()
    sh.saveBtn:SetPoint("TOPRIGHT", sh, "TOPRIGHT", -PAD, -y)
    sh.saveAllBtn:ClearAllPoints()
    sh.saveAllBtn:SetPoint("RIGHT", sh.saveBtn, "LEFT", -6, 0)
    sh.cancelBtn:ClearAllPoints()
    sh.cancelBtn:SetPoint("RIGHT", series and sh.saveAllBtn or sh.saveBtn, "LEFT", -6, 0)
    sh.who:ClearAllPoints()
    sh.who:SetPoint("LEFT", sh, "TOPLEFT", PAD, -(y + 13))
    sh.err:ClearAllPoints()
    sh.err:SetPoint("LEFT", sh, "TOPLEFT", PAD, -(y + 13))
    sh.weeklyInfo:ClearAllPoints()
    sh.weeklyInfo:SetPoint("TOPLEFT", sh.who, "BOTTOMLEFT", 0, -6)
    local footW = inner - 120 - 6 - 80 - (series and (100 + 6) or 0) - 16
    sh.who:SetWidth(footW)
    sh.err:SetWidth(footW)
    S.refreshFooter()
    S.refreshPreview()
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

-- Opens the sheet: occId = nil, a new raid; else that raid (who runs it only).
function PlanUI:OpenEditor(occId)
    local RPm = RP()
    if occId and RPm:GetRaid(occId) and not RPm:CanManageRaid(occId) then
        Print("Only this raid's leader, the Guild Master and the raid leaders can change it.")
        return
    elseif not occId and not RPm:CanOrganize() then
        Print("Only the Guild Master and the raid leaders can plan raids.")
        return
    end
    -- (from Home: the Raids tab first)
    if ns.MainFrame and ns.MainFrame.Open and not (ns.RaidsUI and ns.RaidsUI.GetPanel and ns.RaidsUI:GetPanel()
        and ns.RaidsUI:GetPanel():IsVisible()) then
        ns.MainFrame:Open("raids")
    end
    if not sheet and not S.create() then return end
    local v = occId and RPm:GetRaid(occId)
    sheet.occ = v and v.id or nil
    sheet.errText = nil
    local f = { list = {}, tm = {}, tl = {}, inv = {}, access = "open", low = false, weekly = false }
    if v then
        f.list = RPm:GetRaidInstances(v)
        f.sz, f.szKeep = v.sz, true
        local d = date("*t", v.t)
        f.hour, f.min = d.hour, d.min - d.min % 15
        f.y, f.m, f.d = d.year, d.month, d.day
        for _, id in ipairs(v.tm or {}) do f.tm[id] = true end
        for id, ln in pairs(v.tl or {}) do f.tl[id] = ln end
        for _, key in ipairs(v.inv or {}) do f.inv[key] = true end
        f.access = (v.lk and v.pv and "private") or (v.lk and "locked") or "open"
        f.low = v.ml == nil
        sheet.titleBox:SetText(v.ti or "")
        sheet.noteBox:SetText(v.no or "")
    else
        local d = date("*t", Now() + 86400)
        f.list, f.sz = { "kara" }, 10
        f.hour, f.min = 20, 0
        f.y, f.m, f.d = d.year, d.month, d.day
        sheet.titleBox:SetText("")
        sheet.noteBox:SetText("")
    end
    sheet.f = f
    sheet.minT = v and v.t or nil
    sheet.stripStart = nil
    sheet.weekly = v and v.weekly or false
    -- every week: who may change the whole weekly raid (not a leader of this week only)
    sheet.series = (v and v.weekly and RPm:CanManageSeries(v)) and true or false
    sheet.weeklyCB:SetChecked(false)
    if sheet.invPicker.Close then sheet.invPicker:Close() end
    -- the page under the sheet steps aside while it is open (nothing to draw or refresh behind it)
    if not sheet:IsShown() then
        sheet.under = {}
        local p = sheet:GetParent()
        for _, child in ipairs({ p:GetChildren() }) do
            -- (not the Teams view: hiding it asks about unsaved changes)
            if child ~= sheet and child ~= p.teams and child:IsShown() then
                sheet.under[#sheet.under + 1] = child
                child:Hide()
            end
        end
    end
    sheet:Show()
    S.refresh()
end

function PlanUI:CloseEditor()
    if not sheet then return end
    if sheet.invPicker.Close then sheet.invPicker:Close() end
    for _, eb in ipairs({ sheet.titleBox, sheet.noteBox }) do eb:ClearFocus() end
    if sheet.datePicker.Close then sheet.datePicker:Close() end
    if not sheet:IsShown() then return end
    sheet:Hide()
    for _, child in ipairs(sheet.under or {}) do child:Show() end
    sheet.under = nil
    if ns.RaidsUI and ns.RaidsUI.Refresh then ns.RaidsUI:Refresh() end
end

-- The sheet (tests, the audit): its fields are sheet.f.
function PlanUI:GetEditor() return sheet end

function PlanUI:IsEditorOpen() return sheet ~= nil and sheet:IsShown() end

-- A raid tile clicked: adds it to the night (after the others) or takes it out; the size follows the raids again.
function PlanUI:ToggleEditorRaid(key)
    if not sheet or not RP():GetInstance(key) then return end
    local f = sheet.f
    f.szKeep = nil
    for i, k in ipairs(f.list) do
        if k == key then
            table.remove(f.list, i)
            S.refresh()
            return
        end
    end
    f.list[#f.list + 1] = key
    S.refresh()
end

-- "open" | "locked" | "private"
function PlanUI:SetEditorAccess(kind)
    if not sheet then return end
    sheet.f.access = (kind == "locked" or kind == "private") and kind or "open"
    S.refresh()
end

-- A team card by its value (team id, or "team:lineup").
function PlanUI:PickEditorTeam(value) S.toggleTeam(value) end

-- A day of the strip (days from today) / a step of the time (-1 / 1), for tests.
function PlanUI:PickEditorDay(n)
    if not sheet then return end
    local _, y, m, d = S.dayAt(n)
    sheet.f.y, sheet.f.m, sheet.f.d = y, m, d
    S.refresh()
end

function PlanUI:StepEditorTime(dir) if sheet then S.stepTime(dir) end end

function PlanUI:SaveEditor(scope) return S.save(scope or "one") end

-- Keeps the sheet in step with the plans (a team or raid synced in while it is open).
ns:On("RAIDPLAN_CHANGED", function()
    if sheet and sheet:IsShown() then
        if sheet.occ and not RP():GetRaid(sheet.occ) then
            sheet.errText = "This raid no longer exists."
            S.refreshFooter()
            return
        end
        local err = sheet.errText
        S.refresh()
        if err then S.setError(err) end
    end
end)
